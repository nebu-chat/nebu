defmodule Nebu.OAuth.Authorize do
  @moduledoc """
  The browser half of the OAuth 2.0 authorization code grant with Nebu as authorization server in
  front of the corporate IdP (epic oauth-broker, story oauth-authorize-idp-delegation-code,
  ADR-033 "Authorization endpoint, IdP delegation and codes (story 2)").

  ## `GET /oauth2/authorize` (`handle_authorize/2`, via `Nebu.OAuth.Http`)

  Only live while `Nebu.OAuth.Config` is `:enabled` AND the issuer normalizes (`live_issuer/0`;
  otherwise `Nebu.OAuth.Http` answers `404 M_UNRECOGNIZED` without a rate-limit token or DB
  access). Then, in this order:

    1. method other than GET => 405 page (`Allow: GET`)
    2. per-IP bucket `{"oauth_authorize", ip}` (600/h, D19) => 429 page + `Retry-After`
    3. RAW query parse (D13): malformed encoding, duplicated / array-shaped `client_id` or
       `redirect_uri` => 400 page `invalid_request`
    4. `client_id` missing / > 256 bytes / unknown => 400 page `unknown_client`; DB unreadable =>
       503 page `unavailable`
    5. `redirect_uri` missing / > 2048 bytes / not matching (exact, loopback port exception) =>
       400 page `invalid_redirect_uri` (the requested URI is never rendered)
    6. client `pending` / `rejected` => 403 page (only the escaped `client_uri` host)
    7. from here on the redirect URI is trusted: every failure is an RFC 6749 4.1.2.1 error
       REDIRECT (`error`, fixed `error_description`, `state`, `iss`; never `errcode`):
       registered `response_types` / `grant_types` lacking code => `unauthorized_client`, then
       `Nebu.OAuth.AuthorizeRequest.validate/2` (AC4 order)
    8. delegation (AC6): IdP URL via `Nebu.Matrix.idp_authorize_location/2` (one IdP client, the
       shared callback, OIDC Scopes Law), IdP verifier SecretBox-encrypted, the request persisted
       in `oauth_authz_requests` (`Nebu.OAuth.AuthzStore`, capped, 10 min), the D4 binding cookie,
       302 to the IdP.

  ## IdP callback (`handle_idp_callback/1`, via `Nebu.OAuth.handle_idp_callback/1`)

  The SHARED IdP-registered callback `/_matrix/client/v3/login/sso/redirect/oidc` hands every
  `o2.`-tagged state here (D1/D2). Bucket `{"oauth_callback", ip}` (D19); OAuth not live => 404
  page; malformed state, unknown / expired / replayed request (one atomic DELETE, D3) or a missing
  / mismatching binding cookie (D4) => 400 page `invalid_state`. After that the client redirect URI
  comes ONLY from the consumed row (open-redirect safe): IdP errors, verification failures,
  deactivated users and storage failures are error redirects (`302`).

  A successful IdP login does NOT issue a code (story oauth-authorize-freshness, FR1, FR5): after gate l
  (`per_refresh` without an IdP refresh token is a `server_error`, BEFORE provisioning), provisioning, the
  freshness verdict (`Nebu.OAuth.Freshness`, FR2-FR4), the device-holder check (a device used by another app
  is the `403 device_in_use` page, FR11) and the encryption of the IdP refresh token, it persists a consent
  row (`Nebu.OAuth.ConsentStore`, 5 min) and answers `303 Location: /oauth2/consent` with the consent cookie.
  The authorization code (`Nebu.OAuth.CodeStore`, 60 s, hash only) is minted by `Nebu.OAuth.Consent` only
  after the user clicks Allow, and the client redirect follows from there (`code`, `state`, `iss`).

  ## Headers, logging

  Every response (pages and redirects) carries `Cache-Control: no-store`, `Pragma: no-cache`,
  `Referrer-Policy: no-referrer` and no CORS headers (`Nebu.OAuth.Pages.put_flow_headers/1`). INFO
  logs carry only `client_id`, the outcome and (after the callback) `user_id` / `device_id`; never
  a code, state, nonce, verifier, challenge, cookie value, redirect URI or IdP token (D20).
  """

  import Plug.Conn
  require Logger

  alias Nebu.OAuth.{AuthorizeRequest, AuthzStore, ClientStore, Config, Consent, ConsentStore, Freshness, Pages, SourceKey}
  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.RateLimit

  @callback_path "/_matrix/client/v3/login/sso/redirect/oidc"
  @cookie_prefix "nebu_oa_"
  @host_cookie_prefix "__Host-nebu_oa_"
  @cookie_max_age 600

  @per_ip_per_hour 600
  @max_client_id_bytes 256
  @max_redirect_uri_bytes 2048

  @state_regex ~r/\Ao2\.[A-Za-z0-9_-]{43}\z/

  # Fixed ASCII descriptions (never client- or IdP-supplied text).
  @descriptions %{
    "invalid_request" => "The authorization request is invalid.",
    "unsupported_response_type" => "Only response_type=code is supported.",
    "invalid_scope" => "The requested scope is invalid.",
    "login_required" => "An interactive login is required.",
    "access_denied" => "The authorization request was denied.",
    "unauthorized_client" => "The client is not allowed to use the authorization code grant.",
    "temporarily_unavailable" => "The server is temporarily unable to handle the request.",
    "server_error" => "The server encountered an unexpected error."
  }

  @deactivated "This account has been deactivated."

  @doc false
  # The fixed ASCII `error_description` of an error redirect (also the consent step's `access_denied`).
  @spec error_description(String.t()) :: String.t()
  def error_description(error), do: Map.fetch!(@descriptions, error)

  @doc """
  `{:ok, issuer}` when OAuth is enabled (`Nebu.OAuth.Config` state `:enabled`) and the configured
  issuer is a valid https issuer (the SAME normalization as the metadata, so `iss` is byte-equal to
  the advertised `issuer`); `:error` otherwise (fail closed).
  """
  @spec live_issuer() :: {:ok, String.t()} | :error
  def live_issuer do
    # story oauth-versions-switch V2: the ONE liveness predicate (`Config.live_state/0`), no second copy
    case Config.live_state() do
      {:live, issuer} -> {:ok, issuer}
      _ -> :error
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # GET /oauth2/authorize
  # ════════════════════════════════════════════════════════════════════════════

  @doc "Handles `/oauth2/authorize` while OAuth is live (`issuer` from `live_issuer/0`)."
  @spec handle_authorize(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def handle_authorize(%Plug.Conn{method: "GET"} = conn, issuer) do
    case RateLimit.take({"oauth_authorize", ClientIP.bucket(conn)}, @per_ip_per_hour / 60, @per_ip_per_hour) do
      :ok -> authorize(conn, issuer)
      {:deny, retry_after_s} -> Pages.send_page(conn, 429, "rate_limited", retry_after: retry_after_s)
    end
  end

  def handle_authorize(conn, _issuer), do: Pages.send_page(conn, 405, "method_not_allowed", allow: "GET")

  defp authorize(conn, issuer) do
    with {:ok, pairs} <- parse(conn),
         {:ok, client_id} <- client_id(pairs),
         {:ok, client} <- lookup_client(client_id),
         {:ok, redirect_uri} <- redirect_uri(pairs, client),
         :ok <- client_status(client),
         :ok <- client_grants(client, pairs, redirect_uri),
         {:ok, request} <- validate(pairs, redirect_uri) do
      delegate(conn, issuer, client, redirect_uri, request)
    else
      {:page, status, code, opts} ->
        Pages.send_page(conn, status, code, opts)

      {:redirect_error, redirect_uri, ctx, error} ->
        Logger.info("OAuth authorize: request refused error=#{error}")
        error_redirect(conn, issuer, redirect_uri, ctx.response_mode, ctx.state, error)
    end
  end

  # D13: the RAW query string, never conn.query_params (last-wins, `x[]=` lists).
  defp parse(conn) do
    with {:ok, pairs} <- AuthorizeRequest.parse_query(conn.query_string),
         :ok <- unique_identity_params(pairs) do
      {:ok, pairs}
    else
      _ -> {:page, 400, "invalid_request", []}
    end
  end

  defp unique_identity_params(pairs) do
    names = Enum.map(pairs, &elem(&1, 0))
    array_shaped = Enum.any?(names, &Regex.match?(~r/\A(client_id|redirect_uri)\[/, &1))

    if array_shaped or Enum.count(names, &(&1 == "client_id")) > 1 or Enum.count(names, &(&1 == "redirect_uri")) > 1,
      do: :error,
      else: :ok
  end

  defp client_id(pairs) do
    case List.keyfind(pairs, "client_id", 0) do
      {_, id} when byte_size(id) in 1..@max_client_id_bytes ->
        # a NUL / control character can never be a client_id (and PostgreSQL text cannot store it)
        if String.valid?(id) and not Regex.match?(~r/\p{Cc}/u, id),
          do: {:ok, id},
          else: {:page, 400, "unknown_client", []}

      _ ->
        {:page, 400, "unknown_client", []}
    end
  end

  defp lookup_client(client_id) do
    case ClientStore.fetch_by_client_id(client_id) do
      {:ok, %{} = client} ->
        {:ok, client}

      {:ok, nil} ->
        {:page, 400, "unknown_client", []}

      {:error, reason} ->
        Logger.error("OAuth authorize: could not look up the client: #{log_reason(reason)}")
        {:page, 503, "unavailable", []}
    end
  end

  defp redirect_uri(pairs, client) do
    registered = List.wrap(client.metadata["redirect_uris"])

    with {_, uri} when byte_size(uri) in 1..@max_redirect_uri_bytes <- List.keyfind(pairs, "redirect_uri", 0),
         {:ok, uri} <- AuthorizeRequest.match_redirect_uri(uri, registered) do
      {:ok, uri}
    else
      _ -> {:page, 400, "invalid_redirect_uri", []}
    end
  end

  defp client_status(%{status: "approved"}), do: :ok
  defp client_status(%{status: "pending"} = client), do: {:page, 403, "client_pending", client_host: client_host(client)}
  defp client_status(client), do: {:page, 403, "client_rejected", client_host: client_host(client)}

  # Defensive (registration only admits code + authorization_code today): RFC 7591 defaults apply
  # when a field is absent.
  defp client_grants(client, pairs, redirect_uri) do
    response_types = Map.get(client.metadata, "response_types") || ["code"]
    grant_types = Map.get(client.metadata, "grant_types") || ["authorization_code"]

    if "code" in List.wrap(response_types) and "authorization_code" in List.wrap(grant_types) do
      :ok
    else
      {:redirect_error, redirect_uri, AuthorizeRequest.error_context(pairs, redirect_uri), "unauthorized_client"}
    end
  end

  defp validate(pairs, redirect_uri) do
    case AuthorizeRequest.validate(pairs, redirect_uri) do
      {:ok, request} -> {:ok, request}
      {:error, code, ctx} -> {:redirect_error, redirect_uri, ctx, code}
    end
  end

  # AC6: IdP URL first (discovery / config failure => nothing persisted), then the encrypted
  # verifier, then the capped INSERT, then the 302 with the D4 binding cookie.
  defp delegate(conn, issuer, client, redirect_uri, request) do
    state = "o2." <> random_b64(32)
    state_hash = AuthzStore.hash(state)
    binding = random_b64(32)
    fail = &error_redirect(conn, issuer, redirect_uri, request.response_mode, request.state, &1)
    source_key = SourceKey.for_conn(conn)

    with {:idp, {:ok, idp}} <- {:idp, Nebu.Matrix.idp_authorize_location(conn, %{state: state, prompt: request.prompt})},
         {:encrypt, {:ok, verifier_enc}} <- {:encrypt, encrypt(idp.verifier)},
         {:insert, :ok} <-
           {:insert,
            AuthzStore.insert(%{
              state_hash: state_hash,
              client_id: client.client_id,
              redirect_uri: redirect_uri,
              code_challenge: request.code_challenge,
              device_id: request.device_id,
              scope: request.scope,
              scope_prefix: request.scope_prefix,
              response_mode: request.response_mode,
              client_state: request.state,
              client_nonce: request.nonce,
              openid_requested: request.openid_requested,
              idp_code_verifier_enc: verifier_enc,
              idp_nonce: idp.nonce,
              browser_binding_hash: AuthzStore.hash(binding),
              # per-source cap of live requests (AH10); the source is the resolved client address
              source_key: source_key
            })} do
      Logger.info("OAuth authorize: request delegated to the IdP client_id=#{client.client_id}")

      conn
      |> put_resp_cookie(cookie_name(conn, state_hash), binding,
        path: cookie_path(conn),
        max_age: @cookie_max_age,
        http_only: true,
        same_site: "Lax",
        secure: https?(conn)
      )
      |> redirect(idp.location)
    else
      {:idp, {:error, reason}} ->
        Logger.warning("OAuth authorize: IdP unavailable client_id=#{client.client_id} reason=#{log_reason(reason)}")
        fail.("temporarily_unavailable")

      {:encrypt, :error} ->
        Logger.error("OAuth authorize: cannot encrypt the IdP verifier (no internal secret?) client_id=#{client.client_id}")
        fail.("server_error")

      {:insert, {:error, :capacity}} ->
        log_capacity(source_key, client.client_id)
        fail.("temporarily_unavailable")

      {:insert, {:error, :invalid}} ->
        fail.("invalid_request")

      {:insert, {:error, reason}} ->
        Logger.error("OAuth authorize: could not persist the request client_id=#{client.client_id}: #{log_reason(reason)}")
        fail.("temporarily_unavailable")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # OAuth branch of the shared IdP callback
  # ════════════════════════════════════════════════════════════════════════════

  @doc "Completes an OAuth-broker flow at the shared IdP callback (`conn.query_params` fetched)."
  @spec handle_idp_callback(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_idp_callback(conn) do
    conn = fetch_cookies(conn)
    params = conn.query_params

    case RateLimit.take({"oauth_callback", ClientIP.bucket(conn)}, @per_ip_per_hour / 60, @per_ip_per_hour) do
      {:deny, retry_after_s} ->
        # nothing consumed: the cookie stays so the same browser can retry
        Pages.send_page(conn, 429, "rate_limited", retry_after: retry_after_s)

      :ok ->
        state = params["state"]
        conn = clear_binding_cookie(conn, state)

        case live_issuer() do
          {:ok, issuer} -> callback(conn, params, state, issuer)
          # nothing consumed (the request row survives)
          :error -> Pages.send_page(conn, 404, "unavailable")
        end
    end
  end

  defp callback(conn, params, state, issuer) do
    with true <- is_binary(state) and Regex.match?(@state_regex, state),
         {:ok, row} <- AuthzStore.consume(state),
         :ok <- check_binding(conn, state, row.browser_binding_hash),
         :ok <- recheck_client(row.client_id) do
      complete(conn, params, row, issuer)
    else
      {:page, status, code} ->
        Pages.send_page(conn, status, code)

      {:error, :storage} ->
        Logger.error("OAuth callback: authorization request store unavailable")
        Pages.send_page(conn, 503, "unavailable")

      _invalid ->
        Logger.info("OAuth callback: invalid, expired or replayed sign-in state")
        Pages.send_page(conn, 400, "invalid_state")
    end
  end

  # D4: the per-flow cookie must be present and match (constant time on the hashes).
  defp check_binding(conn, state, stored_hash) do
    case conn.req_cookies[cookie_name(conn, AuthzStore.hash(state))] do
      value when is_binary(value) and value != "" ->
        if Plug.Crypto.secure_compare(AuthzStore.hash(value), stored_hash), do: :ok, else: :mismatch

      _ ->
        :missing
    end
  end

  # AC7.7: a deleted client is normally already handled by the FK cascade (=> invalid_state); a
  # client that is not approved is a defensive branch (000040 makes a decision final).
  defp recheck_client(client_id) do
    case ClientStore.fetch_by_client_id(client_id) do
      {:ok, %{status: "approved"}} -> :ok
      {:ok, nil} -> :gone
      {:ok, _not_approved} -> {:page, 403, "client_rejected"}
      {:error, _} -> {:error, :storage}
    end
  end

  defp complete(conn, params, row, issuer) do
    fail = fn error, description ->
      Logger.info("OAuth callback: flow failed client_id=#{row.client_id} error=#{error}")
      error_redirect(conn, issuer, row.redirect_uri, row.response_mode, row.client_state, error, description)
    end

    idp_error = params["error"]
    code = params["code"]

    cond do
      is_binary(idp_error) and idp_error != "" ->
        # IdP authorization error: mapped, the IdP's error_description / error_uri never forwarded
        fail.(map_idp_error(idp_error), nil)

      not is_binary(code) or code == "" ->
        fail.("server_error", nil)

      true ->
        request_consent(conn, code, row, fail)
    end
  end

  defp map_idp_error("access_denied"), do: "access_denied"
  defp map_idp_error("temporarily_unavailable"), do: "temporarily_unavailable"
  defp map_idp_error(_other), do: "server_error"

  # FR5 order after the IdP login: (a) gate l, (b) provisioning, (c) freshness, (d) device holder, (e) encrypt
  # the IdP refresh token, (f) the consent row, (g) 303 to the consent page. The code is minted by
  # `Nebu.OAuth.Consent` after the user's Allow, never here.
  defp request_consent(conn, idp_code, row, fail) do
    with {:verifier, {:ok, verifier}} <- {:verifier, decrypt(row.idp_code_verifier_enc)},
         {:idp, {:ok, %{claims: claims, idp_refresh_token: idp_rt}}} <-
           {:idp, Nebu.Matrix.idp_complete_login(conn, idp_code, verifier, row.idp_nonce)},
         {:gate_l, :ok} <- {:gate_l, check_idp_refresh_token(idp_rt)},
         {:user, {:ok, %{user_id: user_id}}} <- {:user, Nebu.Matrix.provision_login_user(claims)},
         {login_fresh, auth_time} = freshness(claims, row.created_at),
         {:device, {:ok, device}} <- {:device, Consent.device_check(user_id, row.device_id, row.client_id)},
         {:rt, {:ok, idp_rt_enc}} <- {:rt, encrypt_optional(idp_rt)},
         cookie = Consent.new_cookie_value(),
         {:consent, :ok} <-
           {:consent,
            ConsentStore.insert(%{
              binding_hash: ConsentStore.hash(cookie),
              client_id: row.client_id,
              redirect_uri: row.redirect_uri,
              code_challenge: row.code_challenge,
              device_id: row.device_id,
              user_id: user_id,
              scope: row.scope,
              scope_prefix: row.scope_prefix,
              response_mode: row.response_mode,
              client_state: row.client_state,
              client_nonce: row.client_nonce,
              openid_requested: row.openid_requested,
              idp_rt_enc: idp_rt_enc,
              auth_time: auth_time,
              login_fresh: login_fresh,
              # L-2: per-source live cap (the callback's resolved client address)
              source_key: SourceKey.for_conn(conn)
            })} do
      Logger.info(
        "OAuth callback: consent requested client_id=#{row.client_id} user_id=#{user_id} device_id=#{row.device_id} " <>
          "fresh=#{login_fresh} device=#{device_kind(device)}"
      )

      conn
      |> Consent.put_cookie(cookie)
      |> Pages.put_flow_headers()
      |> put_resp_header("location", "/oauth2/consent")
      |> send_resp(303, "")
    else
      {:verifier, _} -> fail.("server_error", nil)
      {:idp, {:error, :idp_unavailable}} -> fail.("temporarily_unavailable", nil)
      {:idp, _} -> fail.("access_denied", nil)
      {:gate_l, :refused} -> fail.("server_error", nil)
      {:user, {:error, :deactivated}} -> fail.("access_denied", @deactivated)
      {:user, _} -> fail.("server_error", nil)
      {:device, :refused} -> refuse_device(conn, row)
      {:device, :unavailable} -> fail.("temporarily_unavailable", nil)
      {:rt, _} -> fail.("server_error", nil)
      {:consent, {:error, :capacity}} ->
        log_consent_capacity(row.client_id)
        fail.("temporarily_unavailable", nil)

      {:consent, _} -> fail.("server_error", nil)
    end
  end

  # FR13, gate l: with `oauth_idp_revalidation = per_refresh` (also the fail-closed reading of an unknown value
  # or an unreadable config) every refresh redeems the stored IdP refresh token, so a login WITHOUT one could
  # never be refreshed (T6 would refuse the code later anyway): refuse it HERE, before anything is persisted,
  # with a fixed description that names no configuration. The operator gets ONE throttled WARNING.
  defp check_idp_refresh_token(idp_rt) do
    if idp_rt in [nil, ""] and Config.token_settings().idp_revalidation == :per_refresh do
      if RateLimit.take({"oauth_config_warning", :no_idp_rt}, 0.1, 1) == :ok do
        Logger.warning(
          "OAuth: oauth_idp_revalidation is per_refresh but the IdP returned no refresh token; OAuth logins are refused. " <>
            "Set matrix_oidc_refresh_mode=offline and let the IdP issue refresh tokens, or set oauth_idp_revalidation=off."
        )
      end

      :refused
    else
      :ok
    end
  end

  # FR2-FR4: `{login_fresh?, stored_auth_time}`. The stored value is the RAW `auth_time` claim (clamped to now
  # when it is fresh) or nil; NEVER `iat`, never the consent time. A missing / stale value does not end the
  # flow (no `login_required`): the consent screen is the guard and shows a notice.
  defp freshness(claims, requested_at) do
    claim = Freshness.auth_time(claims)

    case Freshness.evaluate(claim, requested_at) do
      {:fresh, t} -> {true, t}
      {:stale, t} -> {false, t}
      :absent -> {false, nil}
    end
  end

  defp device_kind(:new), do: "new"
  defp device_kind({:same_client, _holder}), do: "same_client"
  defp device_kind({:replace, _holder}), do: "replace"

  # FR11: a device id held by another app. A user page, never a redirect (the client learns nothing about the
  # holder, FR18); no consent row, no cookie, no code.
  defp refuse_device(conn, row) do
    Logger.info("OAuth callback: device in use by another app, refused client_id=#{row.client_id} device_id=#{row.device_id}")
    Pages.send_page(conn, 403, "device_in_use")
  end

  defp log_consent_capacity(client_id) do
    Logger.warning("OAuth callback: live consent request cap reached (global, per user or per source) client_id=#{client_id}")
  end

  # ════════════════════════════════════════════════════════════════════════════
  # helpers
  # ════════════════════════════════════════════════════════════════════════════

  # A refusal by the PER-SOURCE cap (one client or one shared address at its limit) is told apart from
  # the global cap: it gets ONE throttled line per node and minute (it can be repeated by one client at
  # will) that carries no client address, source key or host. Behind a proxy list that is wrong all
  # clients share one source, so this line is also the operator's hint to check NEBU_TRUSTED_PROXY_CIDRS.
  defp log_capacity(source_key, client_id) do
    if AuthzStore.source_capped?(source_key) do
      if RateLimit.take({"oauth_cap_warning", :authorize}, 1, 1) == :ok do
        Logger.warning(
          "OAuth authorize: per-source live authorization request cap reached " <>
            "(one client address is at its limit; if all clients hit it, check NEBU_TRUSTED_PROXY_CIDRS)"
        )
      end
    else
      Logger.warning("OAuth authorize: global live authorization request cap reached client_id=#{client_id}")
    end
  end

  defp error_redirect(conn, issuer, redirect_uri, mode, state, error, description \\ nil) do
    params =
      [{"error", error}, {"error_description", description || Map.fetch!(@descriptions, error)}] ++
        state_param(state) ++ [{"iss", issuer}]

    redirect(conn, AuthorizeRequest.redirect_location(redirect_uri, mode, params))
  end

  defp state_param(state) when is_binary(state) and state != "", do: [{"state", state}]
  defp state_param(_state), do: []

  defp redirect(conn, location) do
    conn
    |> Pages.put_flow_headers()
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  # D4: cleared (Max-Age=0) on every callback outcome except the rate-limited one.
  defp clear_binding_cookie(conn, state) when is_binary(state) do
    delete_resp_cookie(conn, cookie_name(conn, AuthzStore.hash(state)),
      path: cookie_path(conn),
      http_only: true,
      same_site: "Lax",
      secure: https?(conn)
    )
  end

  defp clear_binding_cookie(conn, _state), do: conn

  # story oauth-hardening-hygiene (HY9, j / ah): on an https request the per-flow binding cookie is a `__Host-`
  # cookie (`Path=/; Secure`, no `Domain`: a sibling subdomain can neither set nor overwrite it); on plain http
  # (dev / test) the pre-existing name with `Path=<callback path>` and no `Secure` (a `__Host-` cookie cannot exist
  # there). The callback reads ONLY the name of its own scheme: a fallback to the legacy name would re-open
  # cookie tossing; a scheme mismatch between authorize and callback is `400 invalid_state` (fail closed).
  defp cookie_name(conn, state_hash) do
    prefix = if https?(conn), do: @host_cookie_prefix, else: @cookie_prefix
    prefix <> binary_part(state_hash, 0, 16)
  end

  defp cookie_path(conn), do: if(https?(conn), do: "/", else: @callback_path)

  # Same rule as the IdP callback URL (`Nebu.Web.RequestScheme`).
  defp https?(conn), do: Nebu.Web.RequestScheme.https?(conn)

  # SecretBox raises without an internal secret (Trap 9): never a 500.
  defp encrypt(plaintext) do
    {:ok, Nebu.Web.SecretBox.encrypt(plaintext)}
  rescue
    _ -> :error
  end

  defp encrypt_optional(nil), do: {:ok, nil}
  defp encrypt_optional(""), do: {:ok, nil}
  defp encrypt_optional(plaintext), do: encrypt(plaintext)

  defp decrypt(blob) do
    Nebu.Web.SecretBox.decrypt(blob)
  rescue
    _ -> {:error, :decrypt_failed}
  end

  defp client_host(%{metadata: %{"client_uri" => uri}}) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp client_host(_client), do: nil

  defp random_b64(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)


  # Never `inspect/1` a store or IdP error (may carry row data or IdP-supplied text).
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason({tag, _detail}) when is_atom(tag), do: inspect(tag)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason(_other), do: "unexpected error"
end
