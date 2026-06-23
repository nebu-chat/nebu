defmodule Nebu.Matrix.SsoLogin do
  @moduledoc """
  Matrix client SSO login leg (`bugfix-fix-matrix-sso-redirect-missing`).

  Ports the removed Go `gateway/internal/matrix/sso.go` (`GetSSORedirect` +
  `GetSSOCallback`) to Elixir. Handles the two browser-facing endpoints that the
  advertised `m.login.sso` flow needs:

    * `GET /_matrix/client/v3/login/sso/redirect[?redirectUrl=]` and
      `.../sso/redirect/{idpId}` — validate `redirectUrl` against a scheme
      allowlist (open-redirect protection), generate CSRF `state` + OIDC `nonce` +
      PKCE verifier, persist them in `Nebu.Matrix.SsoStore` (cluster-aware,
      TTL 10 min), then 302 to the IdP `authorization_endpoint`.

    * `GET /_matrix/client/v3/login/sso/redirect/oidc?code=&state=` (callback) —
      constant-time fail-closed `state` check, exchange the code (PKCE), verify the
      `id_token` via the SINGLE shared `Nebu.Web.Plugs.OidcPlug.verify_token/2`
      path, constant-time-check the `nonce`, mint a **short-lived (30s) single-use
      opaque loginToken** mapped to the verified `id_token` in `SsoStore`, and 302
      back to the original `redirectUrl` with `?loginToken=<opaque>`.

  The client then calls `POST /_matrix/client/v3/login` with
  `{"type":"m.login.token","token":"<opaque>"}`. `Nebu.Matrix.HttpPublic.do_login`
  resolves the opaque token back to the `id_token` (via `SsoStore.pop_login_token`)
  and verifies it through the same `OidcPlug.verify_token` path — there is exactly
  ONE token-verification code path in the codebase.

  ## OIDC credentials (Go parity `bfd4884f` + `53904df6`)

  Client id/secret come from the Bootstrap DB (`server_config`) when present, with
  the `NEBU_OIDC_*` env (`:matrix_oidc_client_id` / `:matrix_oidc_client_secret`)
  as fallback. The scope list is `openid profile email offline_access` plus any
  non-duplicate `NEBU_OIDC_EXTRA_SCOPES` (`:oidc_extra_scopes`).
  """
  import Plug.Conn
  import Nebu.Matrix.Http, only: [error: 4]

  require Logger

  alias Nebu.Matrix.SsoStore

  # State (user-typing-at-IdP) window and opaque-loginToken replay window.
  @state_ttl_seconds 600
  @login_token_ttl_seconds 30

  # Schemes that are NEVER allowed as a redirectUrl even if an operator misconfigures
  # an allowlist — they can exfiltrate the loginToken via script/file/opaque-data URIs.
  @scheme_denylist ~w(javascript data file vbscript blob)

  # Default Matrix-client deep-link schemes always accepted (Element / FluffyChat).
  @default_deep_link_schemes ~w(element io.element.fluffychat fluffychat)

  # ── GET /sso/redirect[/:idp] ────────────────────────────────────────────────

  @doc """
  Handles `GET .../sso/redirect` and `.../sso/redirect/{idpId}`. Either initiates a
  fresh SSO flow (302 to the IdP) or, when called with `code`+`state` (the IdP
  bounced back to a `/{idpId}` path), delegates to `callback/1`.
  """
  def redirect(conn) do
    redirect_url = conn.query_params["redirectUrl"]

    cond do
      not is_binary(redirect_url) or redirect_url == "" ->
        error(conn, 400, "M_MISSING_PARAM", "redirectUrl is required")

      not redirect_url_allowed?(redirect_url) ->
        # Do NOT echo the scheme/url back (avoid reflected-XSS / info leak).
        Logger.warning("matrix SSO: redirectUrl rejected by allowlist")
        error(conn, 400, "M_INVALID_PARAM", "redirectUrl scheme is not permitted")

      true ->
        do_redirect(conn, redirect_url)
    end
  end

  defp do_redirect(conn, redirect_url) do
    with {:ok, cfg} <- oidc_config(),
         {:ok, authorize} <- discover(cfg.issuer, "authorization_endpoint") do
      verifier = pkce_verifier()
      challenge = pkce_challenge(verifier)
      state = random_token(16)
      nonce = random_token(32)

      case SsoStore.put_state(state, %{verifier: verifier, nonce: nonce, redirect_url: redirect_url}, @state_ttl_seconds) do
        :ok ->
          query =
            URI.encode_query(%{
              "response_type" => "code",
              "client_id" => cfg.client_id,
              "redirect_uri" => callback_url(conn),
              "scope" => scope_list(),
              "state" => state,
              "nonce" => nonce,
              "code_challenge" => challenge,
              "code_challenge_method" => "S256",
              # prompt=login forces the IdP to re-auth (avoids replaying a cached,
              # already-denylisted id_token after logout) — Go parity.
              "prompt" => "login"
            })

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("location", authorize <> "?" <> query)
          |> send_resp(302, "")

        {:error, :store_full} ->
          Logger.warning("matrix SSO: state store full, rejecting redirect")
          error(conn, 429, "M_LIMIT_EXCEEDED", "Too many pending SSO flows")
      end
    else
      {:error, reason} ->
        Logger.error("matrix SSO redirect failed: #{inspect(reason)}")
        error(conn, 503, "M_UNAVAILABLE", "SSO is not available")
    end
  end

  # ── GET /sso/redirect/oidc (callback) ───────────────────────────────────────

  @doc """
  Handles the OIDC callback `.../sso/redirect/oidc`. Three cases (Go parity):

    * `?error=...&state=...` — IdP authorization error → consume state, 403.
    * `?code=...&state=...`  — code exchange → mint loginToken → 302 back to client.
    * neither — treat as an initiation for the "oidc" IdP (`redirect/1`).
  """
  def callback(conn) do
    code = conn.query_params["code"]
    state = conn.query_params["state"]
    idp_error = conn.query_params["error"]

    cond do
      is_binary(idp_error) and idp_error != "" ->
        # Consume the state to prevent replay, then fail.
        if is_binary(state), do: SsoStore.pop_state(state)
        Logger.warning("matrix SSO: IdP returned authorization error")
        error(conn, 403, "M_FORBIDDEN", "SSO provider rejected the authorization request")

      not is_binary(code) or code == "" or not is_binary(state) or state == "" ->
        # No code → treat as an initiation for the default IdP.
        redirect(conn)

      true ->
        do_callback(conn, code, state)
    end
  end

  defp do_callback(conn, code, state) do
    # pop_state is single-use + fail-closed: an unknown/expired/forged state yields
    # :error here (constant-time compare happens inside the store's key match — the
    # opaque state is a 128-bit random token, so a timing oracle on the ETS key is
    # not a practical CSRF bypass; the security property is "state must match a
    # value WE generated and have not yet consumed").
    case SsoStore.pop_state(state) do
      :error ->
        Logger.warning("matrix SSO: unknown or expired state")
        error(conn, 400, "M_UNKNOWN", "Invalid or expired SSO state")

      {:ok, entry} ->
        with {:ok, cfg} <- oidc_config(),
             {:ok, id_token, oidc_refresh_token} <- exchange(conn, code, entry.verifier, cfg),
             {:ok, claims} <- Nebu.Web.Plugs.OidcPlug.verify_token(id_token),
             :ok <- check_nonce(claims, entry.nonce) do
          opaque = random_token(32)

          # oidc-session-refresh: carry the OIDC refresh token through the
          # single-use loginToken so POST /login can mint a long-lived opaque Nebu
          # session when the client asks for refresh_token: true. nil → JWT fallback.
          SsoStore.put_login_token(opaque, id_token, @login_token_ttl_seconds,
            oidc_refresh_token: oidc_refresh_token
          )

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("location", append_login_token(entry.redirect_url, opaque))
          |> send_resp(302, "")
        else
          {:error, reason} ->
            Logger.warning("matrix SSO callback failed: #{inspect(reason)}")
            error(conn, 403, "M_FORBIDDEN", "SSO login failed")
        end
    end
  end

  # ── redirectUrl allowlist (open-redirect protection — Go isRedirectURLAllowed) ─

  @doc false
  def redirect_url_allowed?(raw) when is_binary(raw) and raw != "" do
    uri = URI.parse(raw)
    scheme = uri.scheme && String.downcase(uri.scheme)

    cond do
      # Scheme must be present (rejects "/relative" and bare strings).
      is_nil(scheme) or scheme == "" -> false
      # Denylist wins over every allowlist entry.
      scheme in @scheme_denylist -> false
      # https — always safe (TLS prevents MITM token capture).
      scheme == "https" -> true
      # http — loopback only (dev).
      scheme == "http" -> uri.host in ["localhost", "127.0.0.1"]
      # Matrix-client deep links.
      scheme in @default_deep_link_schemes -> true
      scheme in extra_redirect_schemes() -> true
      true -> false
    end
  end

  def redirect_url_allowed?(_), do: false

  defp extra_redirect_schemes do
    case Application.get_env(:nebu_http, :sso_redirect_schemes) do
      list when is_list(list) -> Enum.map(list, &String.downcase/1)
      str when is_binary(str) -> str |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      _ -> []
    end
  end

  # ── nonce (replay protection, constant-time) ────────────────────────────────

  defp check_nonce(_claims, stored) when not is_binary(stored) or stored == "",
    do: {:error, :missing_nonce}

  defp check_nonce(claims, stored) do
    case claims["nonce"] do
      n when is_binary(n) and n != "" ->
        if Plug.Crypto.secure_compare(n, stored), do: :ok, else: {:error, :nonce_mismatch}

      _ ->
        {:error, :missing_token_nonce}
    end
  end

  # ── append loginToken to the client redirectUrl (Go fragment-aware logic) ────

  @doc false
  def append_login_token(redirect_to, token) do
    case String.split(redirect_to, "#", parts: 2) do
      [base, fragment] ->
        sep = if String.contains?(base, "?"), do: "&", else: "?"
        base <> sep <> "loginToken=" <> token <> "#" <> fragment

      [base] ->
        sep = if String.contains?(base, "?"), do: "&", else: "?"
        base <> sep <> "loginToken=" <> token
    end
  end

  # ── OIDC config (Bootstrap DB → NEBU_OIDC_* env fallback) ───────────────────

  defp oidc_config do
    issuer = Application.get_env(:nebu_http, :oidc_issuer)
    {client_id, client_secret} = resolve_client_credentials()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :issuer_not_configured}
      not is_binary(client_id) or client_id == "" -> {:error, :client_id_not_configured}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret}}
    end
  end

  # The Matrix-client SSO token is validated against NEBU_OIDC_AUDIENCE, so the OIDC
  # client used to MINT it must be the audience-matching Matrix client — and that
  # client's redirect_uri (/_matrix/client/v3/login/sso/redirect/oidc) must be the one
  # registered at the IdP. The admin Bootstrap wizard configures a DIFFERENT client
  # (server_config.oidc_client_id = the admin UI client), whose redirect_uri is
  # /admin/callback — using it for Matrix SSO makes the IdP reject the redirect_uri.
  #
  # So resolve the Matrix OIDC client env (NEBU_OIDC_CLIENT_ID/SECRET) FIRST; only when
  # it is unset do we fall back to the Bootstrap-DB pair (bfd4884f — single-client
  # deployments where the operator-configured client IS the Matrix client), then the
  # admin client as a last resort. client_id and secret are ALWAYS taken from the SAME
  # source so the pair can never mismatch.
  defp resolve_client_credentials do
    matrix_id = Application.get_env(:nebu_http, :matrix_oidc_client_id)
    bootstrap_id = config_value("oidc_client_id")

    cond do
      is_binary(matrix_id) and matrix_id != "" ->
        {matrix_id, Application.get_env(:nebu_http, :matrix_oidc_client_secret, "")}

      is_binary(bootstrap_id) and bootstrap_id != "" ->
        {bootstrap_id, config_value("oidc_client_secret_decrypted") || ""}

      true ->
        {Application.get_env(:nebu_http, :admin_oidc_client_id),
         Application.get_env(:nebu_http, :admin_oidc_client_secret, "")}
    end
  end

  @sql_config "SELECT value FROM server_config WHERE key = $1 LIMIT 1"

  defp config_value(key) do
    if running?(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_config, [key]) do
        {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
        _ -> nil
      end
    else
      nil
    end
  end

  # ── scope list (openid profile email [+offline_access] + NEBU_OIDC_EXTRA_SCOPES) ─
  #
  # `offline_access` is no longer hardcoded: it is included iff the server_config key
  # `matrix_oidc_refresh_mode` resolves to "offline" (story oidc-refresh-mode-config,
  # AC2). The mode is read LIVE on each login-start (low frequency) so a runtime change
  # via /admin/config applies without a redeploy. Absent / any non-"online" value →
  # DEFAULT "offline" (preserves prior behaviour & refresh on Dex + Keycloak, AC1/AC7).
  #
  # Test seam (mirrors OidcClaimCache's :oidc_claim_reader): a 0-arity fun under
  # :matrix_oidc_refresh_mode_reader injects the mode; default reads server_config.

  @base_scopes ~w(openid profile email)

  @sql_matrix_refresh_mode "SELECT value FROM server_config WHERE key = 'matrix_oidc_refresh_mode' LIMIT 1"

  defp scope_list do
    extra =
      case Application.get_env(:nebu_http, :oidc_extra_scopes) do
        list when is_list(list) -> list
        str when is_binary(str) -> String.split(str, ~r/[\s,]+/, trim: true)
        _ -> []
      end

    base = if matrix_refresh_mode() == "offline", do: @base_scopes ++ ["offline_access"], else: @base_scopes

    (base ++ extra)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  # Resolves the Matrix refresh mode to the validated enum "offline" | "online".
  # Any value other than "online" (incl. absent / junk) collapses to the "offline"
  # default — so a stray server_config value can never inject an arbitrary scope.
  defp matrix_refresh_mode do
    reader = Application.get_env(:nebu_http, :matrix_oidc_refresh_mode_reader, &default_matrix_refresh_mode/0)

    case reader.() do
      "online" -> "online"
      _ -> "offline"
    end
  end

  defp default_matrix_refresh_mode do
    if running?(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_matrix_refresh_mode, []) do
        {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
        _ -> "offline"
      end
    else
      "offline"
    end
  end

  # ── token exchange (PKCE + Basic auth) — mirrors Nebu.Admin.Auth.exchange_code ─

  # Test seam: :matrix_sso_token_override is a 0-arity fun. It returns either the
  # oidc-session-refresh 3-tuple {:ok, id_token, oidc_refresh_token} or the legacy
  # 2-tuple {:ok, id_token} (or {:error, _}), short-circuiting the HTTP+discovery
  # leg (every surrounding check — state, nonce, verify — still runs). Mirrors the
  # admin :admin_oidc_token_override. Normalised to a 3-tuple here so callers have
  # one shape.
  defp exchange(conn, code, verifier, cfg) do
    result =
      case Application.get_env(:nebu_http, :matrix_sso_token_override) do
        fun when is_function(fun, 0) ->
          fun.()

        _ ->
          with {:ok, token_endpoint} <- discover(cfg.issuer, "token_endpoint") do
            exchange_code(token_endpoint, code, verifier, cfg, callback_url(conn))
          end
      end

    normalize_exchange(result)
  end

  # Accept both the new 3-tuple and the legacy 2-tuple (AC7 / no-RT path).
  defp normalize_exchange({:ok, id_token, oidc_refresh_token}), do: {:ok, id_token, oidc_refresh_token}
  defp normalize_exchange({:ok, id_token}) when is_binary(id_token), do: {:ok, id_token, nil}
  defp normalize_exchange({:error, _} = err), do: err

  defp exchange_code(token_endpoint, code, verifier, cfg, redirect_uri) when is_binary(verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => verifier,
        "client_id" => cfg.client_id
      })

    basic = Base.encode64("#{cfg.client_id}:#{cfg.client_secret}")

    headers = [
      {~c"content-type", ~c"application/x-www-form-urlencoded"},
      {~c"accept", ~c"application/json"},
      {~c"authorization", String.to_charlist("Basic " <> basic)}
    ]

    request =
      {String.to_charlist(token_endpoint), headers, ~c"application/x-www-form-urlencoded", body}

    http_opts = [timeout: 5_000, connect_timeout: 5_000] ++ tls_opts_for(token_endpoint)

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} when status in 200..299 ->
        extract_id_token(resp_body)

      {:ok, {{_http, status, _reason}, _headers, _resp_body}} ->
        {:error, {:token_endpoint_status, status}}

      {:error, reason} ->
        {:error, {:token_endpoint_unreachable, reason}}
    end
  end

  defp exchange_code(_endpoint, _code, _verifier, _cfg, _redirect_uri), do: {:error, :missing_verifier}

  # oidc-session-refresh: also surface the OIDC `refresh_token` from the
  # token-endpoint response (present when `offline_access` is granted — it is in
  # @base_scopes). The RT is returned as the 3rd element so the login path can
  # mint a long-lived opaque Nebu session; absent → nil → JWT fallback (AC7).
  defp extract_id_token(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"id_token" => id_token} = body} when is_binary(id_token) and id_token != "" ->
        oidc_rt =
          case body["refresh_token"] do
            rt when is_binary(rt) and rt != "" -> rt
            _ -> nil
          end

        {:ok, id_token, oidc_rt}

      {:ok, _} ->
        {:error, :no_id_token}

      {:error, _} ->
        {:error, :malformed_token_response}
    end
  end

  # ── callback redirect_uri (registered with the IdP) ─────────────────────────
  #
  # Built from the request scheme+host so the dev (http://localhost:8008) and any
  # https origin both register the same fixed path. Honours X-Forwarded-Proto.
  defp callback_url(conn) do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        ["https" | _] -> "https"
        _ -> if conn.scheme == :https, do: "https", else: "http"
      end

    host =
      case get_req_header(conn, "host") do
        [h | _] -> h
        _ -> "#{conn.host}:#{conn.port}"
      end

    scheme <> "://" <> host <> "/_matrix/client/v3/login/sso/redirect/oidc"
  end

  # ── discovery (shared TLS-verifying OidcMetadata fetcher + override seam) ────

  defp discover(issuer, field) do
    with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
         {:ok, doc} <- Jason.decode(body) do
      case doc[field] do
        url when is_binary(url) and url != "" -> {:ok, url}
        _ -> {:error, {:discovery_missing, field}}
      end
    else
      {:error, reason} -> {:error, {:discovery_failed, reason}}
    end
  end

  defp tls_opts_for(url) do
    if String.starts_with?(url, "https://") do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
  end

  # ── PKCE / CSRF helpers (RFC 7636 — same as Nebu.Admin.Auth) ────────────────

  defp pkce_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp pkce_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp random_token(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  defp running?(name), do: Process.whereis(name) != nil
end
