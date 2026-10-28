defmodule Nebu.OAuth.Token do
  @moduledoc """
  `POST /oauth2/token` (story oauth-token-endpoint, epic oauth-broker; RFC 6749 3.2 / 4.1.3 / 5 /
  6, RFC 7636 4.6, RFC 9700): `grant_type=authorization_code` and `grant_type=refresh_token` for
  public clients (`token_endpoint_auth_method=none`). Called by `Nebu.OAuth.Http` only while OAuth
  is live (the kill switch, T22, is decided there).

  ## Order (AC2, first failure wins)

    1. a non-empty query string => `400 invalid_request` (credentials never in URLs)
    2. `Content-Type` not `application/x-www-form-urlencoded` (parameters allowed) => 400
    3. body > 16 KiB => `413 invalid_request`; read error => 400 (the raw body is read exactly once
       here; `Nebu.Web.Plugs.JsonBody` skips this path, `body_params` stays `Unfetched`, so
       `RequestLogger` never logs the request body)
    4. malformed form encoding, 5. duplicated parameter, 6. control character / invalid UTF-8 =>
       400; afterwards empty values are dropped (RFC 6749 3.1: empty = omitted)
    7. rate limit (T21), charged BEFORE any DB access: `{"oauth_token", ip}` (10/min, burst 600)
       for `authorization_code`, unknown / missing grant types and every request failing 1-6 =>
       `429 too_many_requests`; `{"oauth_token_refresh", ip}` (100/min, burst 1200) for
       `refresh_token` => `503 {}` — a refresh is NEVER answered 429 (spec 6: 429 logs clients out)
    8. client authentication `none` (T24): `Authorization: Basic` => `401 invalid_client` +
       `WWW-Authenticate: Basic realm="nebu"`; a non-empty `client_secret`, a missing / too long /
       unknown / pending / rejected client => `401 invalid_client` (DB error => 503); then
       `grant_type`: missing => `invalid_request`, other than exactly `authorization_code` /
       `refresh_token` => `unsupported_grant_type`, not in the registered `grant_types` =>
       `unauthorized_client`.

  ## Error mapping (T20, oracle C1)

  Every 4xx body is `{"error": code, "error_description": fixed ASCII}` (never `errcode`, never
  client or IdP text). Every 5xx (503 transient, 500 rescued exception) is `Retry-After` + the body
  `{}` WITHOUT an `error` member: oidc-client-ts turns ANY JSON with `error` into an
  `ErrorResponse`, which matrix-js-sdk treats as a logout. Every response carries
  `Content-Type: application/json`, `Cache-Control: no-store`, `Pragma: no-cache`,
  `Access-Control-Allow-Origin: *` and never `Access-Control-Allow-Credentials` (T32).

  ## Grants

    * authorization_code (AC5/AC6): atomic consume of the story-2 code
      (`Nebu.OAuth.CodeStore.consume/1`, single winner), client / byte-equal redirect_uri / PKCE
      S256 binding (T9: a failed binding check burns the code), T6 (`per_refresh` without an IdP
      refresh token fails closed), the signing key BEFORE the session (no orphan session, Trap 5),
      `Nebu.Matrix.oauth_issue_session/1`. A reused code presented WITH a valid proof revokes the
      session derived from it (T8, `Nebu.Matrix.oauth_revoke_sessions_for_code/1`); always
      `invalid_grant`.
    * refresh_token (AC9-AC11): `Nebu.Matrix.oauth_resolve_refresh_token/1` (reuse => the device's
      OAuth session is revoked, T11), client binding (T12), scope narrowing (T13,
      `Nebu.OAuth.TokenRequest.narrow_scope/2`), `Nebu.Matrix.oauth_refresh_session/4` (IdP
      re-validation + rotation, the Matrix side maps transient failures to 503).
    * id_token (T15/T16): ES256, `Nebu.OAuth.IdToken` + `Nebu.OAuth.SigningKeyStore`, whenever
      `openid` is granted; `nonce` only on the code grant.

  ## Logging (T29)

  INFO: grant type, client id, outcome / error code; after success user id + device id. WARNING:
  reuse revocations, client mismatch, T6 misconfiguration. Never a token, code, verifier, id_token,
  IdP token, key material, redirect URI or scope value. No audit rows.

  Test seam (compiled in only for `MIX_ENV=test`): `:nebu_http, :oauth_token_test_hook`
  (0-arity fun called first, inside the rescue).
  """

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{ClientStore, CodeStore, Config, FormPost, IdToken, SigningKeyStore, TokenRequest}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @max_client_id_bytes 256

  # {"oauth_token", ip}: 600/h per IP; {"oauth_token_refresh", ip}: 6000/h per IP (burst 1200).
  @token_rate_per_min 10
  @token_burst 600
  @refresh_rate_per_min 100
  @refresh_burst 1200

  @retry_after_s 5

  @t6_description "Sign-in cannot be completed: the server is not configured for refreshable sessions."

  @doc "Handles `POST /oauth2/token` for the live `issuer` (already normalized). Never raises."
  @spec handle_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def handle_token(conn, issuer) do
    test_hook()
    dispatch(conn, issuer)
  rescue
    e ->
      Logger.error("OAuth token endpoint: unexpected #{inspect(e.__struct__)}")
      server_error(conn, 500, @retry_after_s)
  catch
    :exit, _ ->
      Logger.error("OAuth token endpoint: unexpected exit")
      server_error(conn, 500, @retry_after_s)
  end

  @doc "405 for a non-POST method (AC1): `invalid_request` + `Allow: POST, OPTIONS`."
  @spec method_not_allowed(Plug.Conn.t()) :: Plug.Conn.t()
  def method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST, OPTIONS")
    |> oauth_error(405, "invalid_request", "Method not allowed.")
  end

  @doc "503 `{}` + `Retry-After` with the token-endpoint headers (T20, e.g. the `:unknown` config, T22)."
  @spec unavailable(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def unavailable(conn, retry_after_s \\ @retry_after_s), do: server_error(conn, 503, retry_after_s)

  # ── request pipeline ────────────────────────────────────────────────────────

  defp dispatch(conn, issuer) do
    case FormPost.parse(conn) do
      {:ok, conn, params} ->
        family = if params["grant_type"] == "refresh_token", do: :refresh, else: :token

        case charge(conn, family) do
          :ok -> authenticate(conn, params, issuer)
          {:deny, retry_after_s} -> limited(conn, family, retry_after_s)
        end

      {:error, conn, status, description} ->
        case charge(conn, :token) do
          :ok -> oauth_error(conn, status, "invalid_request", description)
          {:deny, retry_after_s} -> limited(conn, :token, retry_after_s)
        end
    end
  end

  defp charge(conn, :token), do: RateLimit.take({"oauth_token", ClientIP.bucket(conn)}, @token_rate_per_min, @token_burst)
  defp charge(conn, :refresh), do: RateLimit.take({"oauth_token_refresh", ClientIP.bucket(conn)}, @refresh_rate_per_min, @refresh_burst)

  # T21: the code-grant / junk family answers 429; a refresh is NEVER answered 429 (503 {} instead).
  defp limited(conn, :refresh, retry_after_s), do: server_error(conn, 503, retry_after_s)

  defp limited(conn, :token, retry_after_s) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
    |> oauth_error(429, "too_many_requests", nil)
  end

  # ── client authentication (AC3 / T24) + grant type (AC2 step 8) ─────────────

  defp authenticate(conn, params, issuer) do
    cond do
      basic_auth?(conn) ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="nebu"))
        |> client_error(params, 401, "invalid_client", "Client authentication method not supported.")

      Map.has_key?(params, "client_secret") ->
        client_error(conn, params, 401, "invalid_client", "Public clients must not send a client secret.")

      not is_binary(params["client_id"]) or byte_size(params["client_id"]) > @max_client_id_bytes ->
        client_error(conn, params, 401, "invalid_client", "Client authentication failed.")

      true ->
        case ClientStore.fetch_by_client_id(params["client_id"]) do
          {:ok, %{status: "approved"} = client} ->
            check_grant_type(conn, params, client, issuer)

          {:ok, _unknown_or_undecided} ->
            client_error(conn, params, 401, "invalid_client", "Client authentication failed.")

          {:error, _reason} ->
            Logger.warning("OAuth token: client lookup failed (storage unavailable)")
            server_error(conn, 503, @retry_after_s)
        end
    end
  end

  defp basic_auth?(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.any?(&Regex.match?(~r/\Abasic(\s|\z)/i, String.trim_leading(&1)))
  end

  defp check_grant_type(conn, params, client, issuer) do
    grant_type = params["grant_type"]
    registered = Map.get(client.metadata || %{}, "grant_types", ["authorization_code", "refresh_token"])

    cond do
      is_nil(grant_type) ->
        log_outcome(nil, client.client_id, "invalid_request")
        oauth_error(conn, 400, "invalid_request", "The grant_type parameter is required.")

      grant_type not in ["authorization_code", "refresh_token"] ->
        log_outcome(nil, client.client_id, "unsupported_grant_type")
        oauth_error(conn, 400, "unsupported_grant_type", "The grant type is not supported.")

      not (is_list(registered) and grant_type in registered) ->
        log_outcome(grant_type, client.client_id, "unauthorized_client")
        oauth_error(conn, 400, "unauthorized_client", "The client is not registered for this grant type.")

      grant_type == "authorization_code" ->
        code_grant(conn, params, client.client_id, issuer)

      true ->
        refresh_grant(conn, params, client.client_id, issuer)
    end
  end

  defp client_error(conn, params, status, code, description) do
    log_outcome(known_grant(params["grant_type"]), nil, code)
    oauth_error(conn, status, code, description)
  end

  # ── grant_type=authorization_code (AC5 / AC6) ───────────────────────────────

  defp code_grant(conn, params, client_id, issuer) do
    with {:ok, code} <- required(params, "code"),
         {:ok, redirect_uri} <- required(params, "redirect_uri"),
         {:ok, verifier} <- required(params, "code_verifier") do
      case CodeStore.consume(code) do
        {:ok, row} ->
          redeem(conn, row, client_id, redirect_uri, verifier, issuer)

        {:error, {:reused, row}} ->
          code_reused(row, client_id, redirect_uri, verifier)
          grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

        {:error, :invalid} ->
          grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

        {:error, :storage} ->
          Logger.warning("OAuth token: authorization code store unavailable")
          server_error(conn, 503, @retry_after_s)
      end
    else
      {:missing, name} ->
        log_outcome("authorization_code", client_id, "invalid_request")
        oauth_error(conn, 400, "invalid_request", "The #{name} parameter is required.")
    end
  end

  defp required(params, name) do
    case params[name] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:missing, name}
    end
  end

  # AC5 steps 2-4: client binding, byte-equal redirect URI (after form decoding), PKCE S256.
  defp binding_ok?(row, client_id, redirect_uri, verifier) do
    row.client_id == client_id and row.redirect_uri == redirect_uri and
      TokenRequest.pkce_valid?(verifier, row.code_challenge)
  end

  # T8 / AC6: a reused code revokes the session derived from it ONLY when the presentation proves
  # possession (same checks as a first redemption). Always answered invalid_grant.
  defp code_reused(row, client_id, redirect_uri, verifier) do
    if binding_ok?(row, client_id, redirect_uri, verifier) do
      case Nebu.Matrix.oauth_revoke_sessions_for_code(row.code_hash) do
        {:ok, _devices} ->
          Logger.warning("OAuth token: authorization code reused, session revoked",
            client_id: client_id,
            user_id: row.user_id,
            device_id: row.device_id
          )

        {:error, _} ->
          Logger.warning("OAuth token: authorization code reused, revocation FAILED (storage unavailable)",
            client_id: client_id,
            user_id: row.user_id,
            device_id: row.device_id
          )
      end
    end

    :ok
  end

  defp redeem(conn, row, client_id, redirect_uri, verifier, issuer) do
    settings = Config.token_settings()
    openid? = openid?(row.scope)

    cond do
      not binding_ok?(row, client_id, redirect_uri, verifier) ->
        grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

      settings.idp_revalidation == :per_refresh and is_nil(row.idp_rt_enc) ->
        # T6: fail closed (exactly ONE warning naming the fix).
        Logger.warning(
          "OAuth token: the IdP returned no refresh token but oauth_idp_revalidation is per_refresh; " <>
            "set matrix_oidc_refresh_mode=offline (or oauth_idp_revalidation=off)",
          client_id: client_id
        )

        grant_error(conn, "authorization_code", client_id, @t6_description)

      true ->
        with {:ok, key} <- maybe_key(openid?),
             {:ok, session} <- issue_session(row, client_id, settings) do
          id_token =
            if openid?,
              do: sign_id_token(key, issuer, session, client_id, row.client_nonce),
              else: nil

          _ = ClientStore.touch_last_used(client_id)
          log_success("authorization_code", client_id, session)
          success(conn, session, id_token)
        else
          {:error, :key} ->
            server_error(conn, 503, @retry_after_s)

          {:error, :inactive} ->
            grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

          # L-1: another app took the device id between Allow and the exchange; the code is spent, nothing issued
          {:error, :device_in_use} ->
            Logger.warning("OAuth token: the device is held by another app than at consent, code refused", client_id: client_id)
            grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

          # story oauth-client-revocation CR5/CR6: revoked between the client lookup and the issuance; the code is spent
          {:error, :client_not_approved} ->
            Logger.warning("OAuth token: the client is no longer approved, code refused", client_id: client_id)
            grant_error(conn, "authorization_code", client_id, "The authorization code is invalid or has expired.")

          {:error, :unavailable} ->
            server_error(conn, 503, @retry_after_s)
        end
    end
  end

  defp issue_session(row, client_id, settings) do
    Nebu.Matrix.oauth_issue_session(%{
      user_id: row.user_id,
      device_id: row.device_id,
      client_id: client_id,
      scope: row.scope,
      oauth_code_hash: row.code_hash,
      idp_rt_enc: row.idp_rt_enc,
      auth_time: unix(row.auth_time),
      access_ttl_seconds: settings.access_token_ttl_seconds,
      # story oauth-authorize-freshness L-1: the device holder the user accepted at Allow, re-checked by the
      # Matrix domain under the devices row lock (a code of an older node carries `false`: no re-check)
      device_holder_checked: Map.get(row, :device_holder_checked, false) == true,
      expected_holder_client_id: Map.get(row, :device_holder_client_id)
    })
  end

  # ── grant_type=refresh_token (AC9 - AC11) ───────────────────────────────────

  defp refresh_grant(conn, params, client_id, issuer) do
    case required(params, "refresh_token") do
      {:missing, _} ->
        log_outcome("refresh_token", client_id, "invalid_request")
        oauth_error(conn, 400, "invalid_request", "The refresh_token parameter is required.")

      {:ok, rt} ->
        if TokenRequest.valid_refresh_token_format?(rt),
          do: refresh_with(conn, rt, params, client_id, issuer),
          else: grant_error(conn, "refresh_token", client_id, "The refresh token is invalid.")
    end
  end

  defp refresh_with(conn, rt, params, client_id, issuer) do
    case Nebu.Matrix.oauth_resolve_refresh_token(rt) do
      :error ->
        grant_error(conn, "refresh_token", client_id, "The refresh token is invalid.")

      {:error, :unavailable} ->
        server_error(conn, 503, @retry_after_s)

      {:reused, session} ->
        # T11: the refresh token itself is the secret — independent of the presented client_id.
        case Nebu.Matrix.oauth_revoke_device_session(session.user_id, session.device_id) do
          :ok ->
            Logger.warning("OAuth token: consumed refresh token reused, session revoked",
              client_id: session.client_id,
              user_id: session.user_id,
              device_id: session.device_id
            )

            grant_error(conn, "refresh_token", client_id, "The refresh token is invalid.")

          {:error, :unavailable} ->
            # The session SURVIVES: never a definitive invalid_grant (a 4xx logs the client out)
            # while the revocation did not happen; the retry re-detects the reuse.
            Logger.warning("OAuth token: consumed refresh token reused, revocation failed (storage unavailable)",
              client_id: session.client_id,
              user_id: session.user_id,
              device_id: session.device_id
            )

            server_error(conn, 503, @retry_after_s)
        end

      {:ok, session, mode} ->
        cond do
          session.client_id != client_id ->
            Logger.warning("OAuth token: refresh token presented by another client",
              client_id: client_id,
              user_id: session.user_id,
              device_id: session.device_id
            )

            grant_error(conn, "refresh_token", client_id, "The refresh token is invalid.")

          true ->
            refresh_session(conn, session, mode, rt, params, client_id, issuer)
        end
    end
  end

  defp refresh_session(conn, session, mode, rt, params, client_id, issuer) do
    case TokenRequest.narrow_scope(params["scope"], session.scope) do
      {:error, :invalid_scope} ->
        log_outcome("refresh_token", client_id, "invalid_scope")
        oauth_error(conn, 400, "invalid_scope", "The requested scope exceeds the granted scope.")

      {:ok, scope} ->
        openid? = openid?(scope)
        settings = Config.token_settings()

        with {:ok, key} <- maybe_key(openid?),
             {:ok, refreshed} <-
               Nebu.Matrix.oauth_refresh_session(session, mode, rt, %{
                 scope: scope,
                 idp_revalidation: settings.idp_revalidation,
                 access_ttl_seconds: settings.access_token_ttl_seconds
               }) do
          id_token = if openid?, do: sign_id_token(key, issuer, refreshed, client_id, nil), else: nil
          _ = ClientStore.touch_last_used(client_id)
          log_success("refresh_token", client_id, refreshed)
          success(conn, refreshed, id_token)
        else
          {:error, :key} ->
            server_error(conn, 503, @retry_after_s)

          {:error, :invalid_grant} ->
            grant_error(conn, "refresh_token", client_id, "The refresh token is invalid.")

          {:error, {:unavailable, retry_after_s}} ->
            log_outcome("refresh_token", client_id, "unavailable")
            server_error(conn, 503, retry_after_s)
        end
    end
  end

  # ── id_token (T15 - T17) ────────────────────────────────────────────────────

  # The signing key is ensured BEFORE the session is created / rotated (Trap 5: no orphan session).
  defp maybe_key(false), do: {:ok, nil}

  defp maybe_key(true) do
    case SigningKeyStore.ensure_active_key() do
      {:ok, key} ->
        {:ok, key}

      {:error, reason} ->
        Logger.warning("OAuth token: id_token signing key unavailable (#{reason})")
        {:error, :key}
    end
  end

  defp sign_id_token(key, issuer, session, client_id, nonce) do
    %{issuer: issuer, user_id: session.user_id, client_id: client_id, auth_time: session.auth_time, nonce: nonce}
    |> IdToken.claims(System.system_time(:second))
    |> IdToken.sign(key)
  end

  defp openid?(scope) when is_binary(scope), do: "openid" in String.split(scope, " ", trim: true)
  defp openid?(_scope), do: false

  # ── responses ───────────────────────────────────────────────────────────────

  defp success(conn, session, id_token) do
    body =
      %{
        "access_token" => session.access_token,
        "token_type" => "Bearer",
        "expires_in" => session.expires_in,
        "refresh_token" => session.refresh_token,
        "scope" => session.scope
      }
      |> then(fn b -> if id_token, do: Map.put(b, "id_token", id_token), else: b end)

    json(conn, 200, body)
  end

  defp grant_error(conn, grant_type, client_id, description) do
    log_outcome(grant_type, client_id, "invalid_grant")
    oauth_error(conn, 400, "invalid_grant", description)
  end

  defp oauth_error(conn, status, code, description), do: FormPost.oauth_error(conn, status, code, description)
  defp server_error(conn, status, retry_after_s), do: FormPost.server_error(conn, status, retry_after_s)
  defp json(conn, status, body), do: FormPost.json(conn, status, body)

  # ── logging (T29: never tokens, codes, verifiers, redirect URIs or scope values) ──

  defp log_outcome(grant_type, client_id, outcome) do
    Logger.info("OAuth token: grant_type=#{grant_type || "-"} client_id=#{client_id || "-"} outcome=#{outcome}")
  end

  defp log_success(grant_type, client_id, session) do
    Logger.info("OAuth token: grant_type=#{grant_type} client_id=#{client_id} outcome=ok",
      user_id: session.user_id,
      device_id: session.device_id
    )
  end

  defp known_grant(gt) when gt in ["authorization_code", "refresh_token"], do: gt
  defp known_grant(_gt), do: nil

  # ── helpers ─────────────────────────────────────────────────────────────────

  # `timestamptz` of the code row -> unix seconds (rounded like Postgres' ::bigint cast, Trap 18).
  defp unix(%DateTime{} = dt), do: round(DateTime.to_unix(dt, :microsecond) / 1_000_000)
  defp unix(seconds) when is_integer(seconds), do: seconds
  defp unix(_), do: nil

  # Test-only seam, compile-time guarded (Dev Notes "Test-only seams").
  if Mix.env() == :test do
    defp test_hook do
      case Application.get_env(:nebu_http, :oauth_token_test_hook) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end
  else
    defp test_hook, do: :ok
  end
end
