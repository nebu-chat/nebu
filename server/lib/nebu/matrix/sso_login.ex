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

  ## OIDC credentials (ADR-022 — bootstrap-only, single client)

  The SINGLE OIDC client's id/secret come SOLELY from the Bootstrap DB
  (`server_config`); the secret is stored AES-256-GCM encrypted at rest and decrypted
  on use. There is no `NEBU_OIDC_*` env config path.

  OIDC Scopes Law (bugfix-remove-default-scopes): the base scope is always `openid`;
  extra scopes come exclusively from `server_config.matrix_oidc_extra_scopes`.
  When that key is absent or empty, the scope is `openid` only (no profile/email
  defaults). `offline_access` is added when `matrix_oidc_refresh_mode` is "offline".
  Scope resolution itself is centralized in `Nebu.Web.OidcScopes.resolve_scope/1`
  (story `centralize-scope-resolution`) — this module only calls it.
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

  defp do_redirect(conn, redirect_url, uia_session \\ nil) do
    with {:ok, cfg} <- oidc_config(),
         {:ok, authorize} <- discover(cfg.issuer, "authorization_endpoint") do
      verifier = pkce_verifier()
      challenge = pkce_challenge(verifier)
      state = random_token(16)
      nonce = random_token(32)

      case SsoStore.put_state(
             state,
             %{verifier: verifier, nonce: nonce, redirect_url: redirect_url, uia_session: uia_session},
             @state_ttl_seconds
           ) do
        :ok ->
          base_params = %{
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
          }

          # M-1: the UIA step-up fallback (uia_session set) must force a GENUINELY fresh
          # IdP authentication, not silently reuse an existing IdP SSO-session cookie.
          # `prompt=login` is advisory; several IdPs honour an existing session. Adding
          # `max_age=0` forces the IdP to re-authenticate the user (or refuse) so the
          # returned auth_time is trustworthy. ONLY on the UIA-fallback path — the normal
          # login redirect keeps `prompt=login` alone so login UX is not degraded.
          params_map =
            if is_binary(uia_session) and uia_session != "" do
              Map.put(base_params, "max_age", "0")
            else
              base_params
            end

          query = URI.encode_query(params_map)

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

  # ── GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id> ────────

  @doc """
  The UIA `m.login.sso` auth FALLBACK (story s3-matrix-device-endpoints, CS v1.18
  §"Fallback"). The client opens this in a browser for an in-flight UIA `session`;
  it behaves exactly like `GET /sso/redirect` (302 → IdP authorize) EXCEPT the SSO
  state is tagged with the UIA session id, so the shared OIDC callback completes
  THAT UIA session (marks its `m.login.sso` stage complete + refreshes auth_time)
  instead of minting a normal loginToken. UNAUTHENTICATED (it IS the auth step).

  An unknown/expired UIA session → 400. The `redirect_url` is irrelevant to the
  re-submit (the client re-submits the original request itself), so a fixed internal
  marker is used; the callback renders a completion page rather than redirecting back.
  """
  def uia_fallback(conn) do
    session_id = conn.query_params["session"]

    cond do
      not is_binary(session_id) or session_id == "" ->
        error(conn, 400, "M_MISSING_PARAM", "session is required")

      match?(:error, Nebu.Matrix.Uia.load(session_id)) ->
        error(conn, 400, "M_UNKNOWN", "Unknown or expired UIA session")

      true ->
        # redirect_url is unused for a UIA completion (the callback renders a page),
        # but do_redirect requires one for the state entry; use an internal marker.
        do_redirect(conn, "https://uia.local/complete", session_id)
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
          if is_binary(entry.uia_session) and entry.uia_session != "" do
            # S3: this was a UIA m.login.sso completion, not a normal login. Complete
            # the UIA session ONLY when the freshly-authenticated identity matches the
            # session's bound user (H-1), then render a terminal page; on mismatch
            # render a failure page WITHOUT marking the stage complete.
            complete_uia(conn, entry.uia_session, claims)
          else
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
          end
        else
          {:error, reason} ->
            Logger.warning("matrix SSO callback failed: #{inspect(reason)}")
            error(conn, 403, "M_FORBIDDEN", "SSO login failed")
        end
    end
  end

  # S3 (H-1): terminal completion of a UIA m.login.sso stage, IDENTITY-BOUND. The fresh
  # OIDC login has been verified by the shared verify_token path above; derive the Matrix
  # user_id from the verified claims THE SAME WAY login does (UserId.from_claims/2 with
  # the configured server_name — identical derivation incl. sub normalisation) and only
  # complete the UIA session when that identity matches the session's bound user. On a
  # match, Uia.complete/2 marks the stage complete + refreshes auth_time → render the
  # terminal page (status 200; the page runs onAuthDone()); the client then re-submits
  # the original request with auth: {"session": id}.
  #
  # On a mismatch (a DIFFERENT IdP account completing a victim's pending fallback) the
  # UPDATE matches 0 rows → :error → the stage is NOT marked complete and auth_time is
  # NOT refreshed. We render an explicit failure page (403) and never call onAuthDone(),
  # so the step-up cannot be satisfied by an unrelated identity.
  defp complete_uia(conn, uia_session, claims) do
    server = Application.get_env(:nebu_http, :server_name, "localhost")
    authenticated_user = Nebu.Matrix.UserId.from_claims(claims, server)

    case Nebu.Matrix.Uia.complete(uia_session, authenticated_user) do
      {:ok, _user_id} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(200, """
        <!doctype html><html><head><meta charset="utf-8"><title>Authentication complete</title></head>
        <body><p>Authentication complete. You may return to your client.</p>
        <script>if (window.onAuthDone) { window.onAuthDone(); }
        if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }</script>
        </body></html>
        """)

      :error ->
        # Identity mismatch (or unknown/expired/consumed session). Do NOT mark the
        # stage complete, do NOT refresh auth_time, do NOT run onAuthDone(). Log a
        # warning with NO PII / token / session id.
        Logger.warning("matrix UIA SSO: completion identity did not match the pending request")

        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/html")
        |> send_resp(403, """
        <!doctype html><html><head><meta charset="utf-8"><title>Authentication did not match</title></head>
        <body><p>This authentication did not match the request that started it. The operation was not authorised.</p></body></html>
        """)
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

  # ── OIDC config (server_config only — ADR-022) ──────────────────────────────

  @doc false
  # matrix-refresh-revalidates-with-idp: exposes the Matrix-side OIDC config
  # resolution (issuer + the single client's id/secret, ADR-022) so
  # `Nebu.Matrix.HttpPublic.do_refresh_with/2` can resolve the SAME config this
  # module's own login/SSO flow uses when calling the shared
  # `Nebu.Web.OidcTokenExchange.refresh/2`. Honours the `:sso_bootstrap_reader`
  # test seam (unchanged).
  def oidc_config_for_refresh, do: oidc_config()

  defp oidc_config do
    # oidc-bootstrap-only-config (ADR-022): the issuer is resolved SOLELY from
    # server_config via the OidcConfig DB-backed cache. No env-var config path.
    issuer = Nebu.Web.OidcConfig.get().issuer

    {client_id, client_secret} = resolve_client_credentials()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :issuer_not_configured}
      not is_binary(client_id) or client_id == "" -> {:error, :client_id_not_configured}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret}}
    end
  end

  # oidc-bootstrap-only-config (ADR-022): a SINGLE OIDC client serves both Matrix
  # Bearer validation and admin operator login. Its id/secret come solely from
  # server_config (set by the bootstrap wizard); the secret is stored AES-256-GCM
  # encrypted at rest and decrypted here. There is no NEBU_OIDC_CLIENT_ID env path
  # and no separate admin client. client_id and secret are always read from the SAME
  # source so the pair can never mismatch. Fails closed (empty client) when unset.
  defp resolve_client_credentials do
    client_id = config_value("oidc_client_id")

    if is_binary(client_id) and client_id != "" do
      encrypted = config_value("oidc_client_secret") || ""
      {client_id, Nebu.Admin.BootstrapLive.decrypt_secret(encrypted)}
    else
      {nil, ""}
    end
  end

  @sql_config "SELECT value FROM server_config WHERE key = $1 LIMIT 1"

  # Test seam: :sso_bootstrap_reader is a 1-arity fun `fn(key) -> value | nil`.
  # When set, it replaces the live Repo query for server_config lookups — allows
  # tests to inject Bootstrap DB values (encrypted oidc_client_secret, oidc_client_id)
  # without a live PostgreSQL connection. Mirrors the :admin_bootstrap_store seam.
  defp config_value(key) do
    case Application.get_env(:nebu_http, :sso_bootstrap_reader) do
      fun when is_function(fun, 1) ->
        fun.(key)

      _ ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_config, [key]) do
            {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
            _ -> nil
          end
        else
          nil
        end
    end
  end

  # ── scope list (openid [+extra_scopes] [+offline_access]) ───────────────────
  #
  # Story centralize-scope-resolution: scope resolution (validation, extra-scopes
  # read, refresh-mode read) is now centralized in Nebu.Web.OidcScopes — the SINGLE
  # source of OIDC scope resolution for both Matrix and Admin. This is a thin
  # delegate (AC4); SsoLogin no longer runs its own server_config SQL reads or
  # scope-validation regex. The pre-existing :matrix_oidc_extra_scopes_reader /
  # :matrix_oidc_refresh_mode_reader test seams are honoured by OidcScopes itself,
  # unchanged in name/shape, so existing tests keep passing.
  defp scope_list, do: Nebu.Web.OidcScopes.resolve_scope(:matrix)

  # ── token exchange (PKCE + Basic auth) — mirrors Nebu.Admin.Auth.exchange_code ─

  # Test seam: :matrix_sso_token_override accepts two forms:
  #
  #   - 0-arity `fn()` — legacy form. Returns {:ok, id_token[, oidc_refresh_token]}
  #     or {:error, _}, short-circuiting the HTTP+discovery leg. Existing tests use
  #     this form. Mirrors :admin_oidc_token_override.
  #
  #   - 1-arity `fn(cfg)` — credential-spy form (bugfix/oidc-login-keycloak). Receives
  #     the resolved OIDC config map (contains :client_id, :client_secret) so tests can
  #     assert on what credentials were actually resolved from the Bootstrap DB path.
  #     Returns the same shape as the 0-arity form.
  #
  # Every surrounding check — state, nonce, verify — still runs in both forms.
  # Normalised to a 3-tuple by normalize_exchange/1.
  defp exchange(conn, code, verifier, cfg) do
    result =
      case Application.get_env(:nebu_http, :matrix_sso_token_override) do
        fun when is_function(fun, 0) ->
          fun.()

        fun when is_function(fun, 1) ->
          fun.(cfg)

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
  # token-endpoint response (present when `offline_access` is granted —
  # appended by scope_list/0 when mode is "offline"). The RT is returned as the
  # 3rd element so the login path can mint a long-lived opaque Nebu session;
  # absent → nil → JWT fallback (AC7).
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
