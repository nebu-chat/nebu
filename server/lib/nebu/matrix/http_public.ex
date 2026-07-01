defmodule Nebu.Matrix.HttpPublic do
  @moduledoc """
  UNAUTHENTICATED Matrix Client-Server API routes (matrix-api-migration).

  These endpoints are reachable WITHOUT a Bearer token, matching the Go gateway:

    * `POST /_matrix/client/v3/login`            — authentication attempt itself
    * `GET  /_matrix/client/v3/profile/{userId}` — public profile read (+ subfields)
    * `GET  .../auth_issuer` / `.../auth_metadata` (MSC2965) — OIDC discovery

  The top-level `Nebu.Web.Router` forwards each public path to this module with
  an `init_opts: [action: ...]` tag, BEFORE the catch-all `/_matrix` forward to
  the OIDC-protected router. This module therefore deliberately does NOT run
  `Nebu.Web.Plugs.OidcPlug` in its pipeline.

  `PUT /_matrix/client/v3/profile/{userId}/...` IS authenticated; because the
  whole `/profile` subtree is forwarded here, those PUT routes run `OidcPlug`
  inline (see `authenticate/1`) so they cannot be reached without a valid token.
  """
  use Plug.Router

  require Logger

  import Nebu.Matrix.Http

  alias Nebu.Web.SessionConfig

  plug :fetch_query_params
  plug :match
  plug :dispatch

  # ── MSC2965 OIDC discovery (AC5) ──────────────────────────────────────────
  # Parent strips the matched prefix, so the request arrives here as "/".

  # All public paths are forwarded here with their matched prefix stripped, so
  # several distinct endpoints (auth_issuer, auth_metadata, and GET /login —
  # MAJOR-1) all arrive as GET "/". Plug.Router allows only ONE `get "/"`
  # clause, so we disambiguate on the original request path.
  get "/" do
    cond do
      String.ends_with?(conn.request_path, "auth_issuer") ->
        auth_issuer(conn)

      String.ends_with?(conn.request_path, "auth_metadata") ->
        auth_metadata(conn)

      # GET /_matrix/client/v3/login — advertise the supported login flows
      # (MAJOR-1). The Go gateway registers BOTH GET and POST on /login; GetLogin
      # (login.go) returns the flow list so Element Web 1.12+ can discover SSO
      # and the m.login.token flow. Without it a GET falls through to 404
      # M_NOT_FOUND, breaking SSO discovery. Unauthenticated, static (no DB).
      String.ends_with?(conn.request_path, "/login") ->
        login_flows(conn)

      true ->
        error(conn, 404, "M_NOT_FOUND", "Not found")
    end
  end

  # ── Matrix client SSO leg (bugfix-fix-matrix-sso-redirect-missing) ─────────
  # Parent forwards "/_matrix/client/v3/login", so these arrive with the prefix
  # stripped: path_info ["sso","redirect"], ["sso","redirect", idpId], and the
  # OIDC callback ["sso","redirect","oidc"]. They are UNAUTHENTICATED (they ARE
  # the login) — no OidcPlug on this router. Mirrors the removed Go sso.go
  # GetSSORedirect/GetSSOCallback. The callback route is listed FIRST so the
  # literal "oidc" segment wins over the `:idp` wildcard.

  # GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id> (S3 UIA).
  # The parent forwards "/_matrix/client/v3/auth", so this arrives with the prefix
  # stripped: path_info ["m.login.sso", "fallback", "web"]. UNAUTHENTICATED — it IS
  # the auth step. Drives the SAME SSO machinery as /sso/redirect, tagged so the
  # shared OIDC callback completes the UIA session instead of minting a loginToken.
  get "/m.login.sso/fallback/web" do
    conn |> Plug.Conn.fetch_query_params() |> Nebu.Matrix.SsoLogin.uia_fallback()
  end

  # GET /sso/redirect/oidc — OIDC callback (?code=&state= → mint loginToken).
  get "/sso/redirect/oidc" do
    conn |> Plug.Conn.fetch_query_params() |> Nebu.Matrix.SsoLogin.callback()
  end

  # GET /sso/redirect — initiate SSO (302 to the IdP authorize endpoint).
  get "/sso/redirect" do
    conn |> Plug.Conn.fetch_query_params() |> Nebu.Matrix.SsoLogin.redirect()
  end

  # GET /sso/redirect/{idpId} — initiate SSO for a named IdP (same flow).
  get "/sso/redirect/:_idp" do
    conn |> Plug.Conn.fetch_query_params() |> Nebu.Matrix.SsoLogin.redirect()
  end

  # ── POST /_matrix/client/v3/login ─────────────────────────────────────────
  # Parent forwards "/_matrix/client/v3/login" → path_info here is [].

  # F-3: per-IP rate limit on the login path (Go parity: strictRL 30 req/min,
  # burst 10 — "real brute-force risk"). The login handler verifies an
  # attacker-supplied token against JWKS on every call (CPU), so it must be
  # throttled now that no Go gateway fronts core:4000. RateLimit halts with
  # 429 M_LIMIT_EXCEEDED when the per-IP bucket is empty.
  @login_rate_limit Nebu.Web.Plugs.RateLimit.init(rate_per_min: 30, burst: 10, tier: "login")

  # oidc-session-refresh: /_matrix/client/v3/refresh is forwarded here with its
  # prefix stripped, so it also arrives as POST "/". Disambiguate on the original
  # request path (same technique GET "/" uses for auth_issuer/auth_metadata/login).
  # /refresh is UNAUTHENTICATED (spec MUST) and rate-limited like /login.
  @refresh_rate_limit Nebu.Web.Plugs.RateLimit.init(rate_per_min: 30, burst: 10, tier: "refresh")

  post "/" do
    if String.ends_with?(conn.request_path, "/refresh") do
      conn = Nebu.Web.Plugs.RateLimit.call(conn, @refresh_rate_limit)
      if conn.halted, do: conn, else: do_refresh(conn)
    else
      conn = Nebu.Web.Plugs.RateLimit.call(conn, @login_rate_limit)
      if conn.halted, do: conn, else: do_login(conn)
    end
  end

  # ── Profile (GET unauthenticated, PUT authenticated) ──────────────────────
  # Parent forwards "/_matrix/client/v3/profile" → path_info is the trailing
  # segments: [userId] or [userId, "displayname"] / [userId, "avatar_url"].

  get "/:user_id" do
    get_profile(conn, user_id, :full)
  end

  get "/:user_id/displayname" do
    get_profile(conn, user_id, :displayname)
  end

  get "/:user_id/avatar_url" do
    get_profile(conn, user_id, :avatar_url)
  end

  put "/:user_id/displayname" do
    with {:ok, conn, current_user} <- authenticate(conn) do
      put_profile(conn, user_id, current_user, :displayname)
    end
  end

  put "/:user_id/avatar_url" do
    with {:ok, conn, current_user} <- authenticate(conn) do
      put_profile(conn, user_id, current_user, :avatar_url)
    end
  end

  match _ do
    error(conn, 404, "M_NOT_FOUND", "Not found")
  end

  # ── Discovery handlers ────────────────────────────────────────────────────

  defp auth_issuer(conn) do
    # oidc-bootstrap-only-config (ADR-022): the issuer comes solely from server_config
    # via the OidcConfig cache — fail closed (503) until the wizard configures it.
    case Nebu.Web.OidcConfig.get().issuer do
      nil -> error(conn, 503, "M_UNAVAILABLE", "OIDC issuer not configured")
      issuer -> send_json(conn, 200, %{"issuer" => issuer})
    end
  end

  # Proxies (and caches) the OIDC provider's /.well-known/openid-configuration,
  # mirroring gateway/internal/matrix/oidc_discovery.go AuthMetadataHandler.
  #
  # MINOR-4: on fetch failure we return 503 M_UNAVAILABLE — exactly what the Go
  # handler does (oidc_discovery.go writes 503 + M_UNAVAILABLE when the provider
  # is unreachable or returns 5xx). We do NOT synthesise a fallback metadata
  # document: the previous Keycloak-shaped paths are WRONG for Dex (the project's
  # dev IdP), and serving incorrect endpoint URLs is worse than failing closed.
  defp auth_metadata(conn) do
    # oidc-bootstrap-only-config (ADR-022): issuer from server_config (OidcConfig cache).
    case Nebu.Web.OidcConfig.get().issuer do
      nil ->
        error(conn, 503, "M_UNAVAILABLE", "OIDC issuer not configured")

      issuer ->
        case Nebu.Matrix.OidcMetadata.fetch(issuer) do
          {:ok, body} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {:error, _} ->
            error(conn, 503, "M_UNAVAILABLE", "OIDC provider is currently unavailable")
        end
    end
  end

  # ── GET /_matrix/client/v3/login (login flows) ────────────────────────────
  #
  # Mirrors gateway/internal/matrix/login.go GetLogin exactly: advertise
  # m.login.sso (with the configured IdP under identity_providers) AND
  # m.login.token. Element Web 1.12+ requires m.login.token alongside
  # m.login.sso so it uses the loginToken from the SSO redirect instead of
  # re-initiating a fresh SSO flow.
  defp login_flows(conn) do
    display_name = Application.get_env(:nebu_http, :oidc_display_name, "SSO")

    send_json(conn, 200, %{
      "flows" => [
        %{
          "type" => "m.login.sso",
          "identity_providers" => [
            %{"id" => "oidc", "name" => display_name, "icon" => nil}
          ]
        },
        %{"type" => "m.login.token"}
      ]
    })
  end

  # ── Login (POST /_matrix/client/v3/login) ─────────────────────────────────
  #
  # Nebu uses OIDC. The Go gateway (login.go) verifies the supplied id_token,
  # extracts claims, builds the Matrix user id, and calls ValidateToken to
  # provision the user. We reproduce that here:
  #   1. body MUST be valid JSON {type, token}; malformed → 400 M_NOT_JSON.
  #   2. type MUST be "m.login.token"; otherwise → 400 M_UNKNOWN.
  #   3. verify the OIDC token via the SAME OidcPlug.verify_token path
  #      (alg allowlist + iss/aud/exp/sub) → 403 M_FORBIDDEN on failure.
  #   4. provision via Nebu.Matrix.Session.TokenValidator.validate/4.
  #   5. return {user_id, access_token, device_id, token_type:"Bearer"}.
  defp do_login(conn) do
    # Nebu.Web.Plugs.JsonBody tags a malformed body with :json_parse_error and
    # leaves body_params = %{} (it never raises). Surface the Matrix 400 here.
    cond do
      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      is_map(conn.body_params) ->
        do_login_with(conn, conn.body_params)

      true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")
    end
  end

  defp do_login_with(conn, params) do
    type = params["type"]
    token = params["token"]
    # Matrix CS API v1.3: a client opts into refreshable opaque sessions by sending
    # refresh_token: true on /login. Anything other than the boolean true keeps the
    # legacy raw-JWT response (AC7).
    refresh_requested = params["refresh_token"] == true

    # S2 AC2: honour a client-supplied device_id (Matrix allows reuse "provided the
    # user remains the same") so a returning client keeps the SAME device row instead
    # of spawning a new one each login. Absent/blank → server generates one.
    client_device_id =
      case params["device_id"] do
        d when is_binary(d) and d != "" -> d
        _ -> nil
      end

    # S2 AC1: initial_device_display_name names the device on FIRST creation only.
    initial_display_name =
      case params["initial_device_display_name"] do
        d when is_binary(d) and d != "" -> d
        _ -> nil
      end

    cond do
      type != "m.login.token" ->
        error(conn, 400, "M_UNKNOWN", "Unsupported login type")

      not is_binary(token) or token == "" ->
        error(conn, 400, "M_UNKNOWN", "Missing login token")

      # S3 F-2: a client-supplied device_id that is oversized (>255 bytes) or carries
      # control characters is rejected at the ingress boundary, BEFORE the token is
      # verified or the user provisioned. An absent/blank device_id (server-generated)
      # is fine — only a PRESENT-but-invalid value is rejected.
      is_present_invalid_device_id?(params["device_id"]) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid device_id")

      true ->
        # bugfix-fix-matrix-sso-redirect-missing: the m.login.token value can be
        # EITHER an opaque single-use loginToken minted by the SSO callback (the
        # Element/SSO path) OR a raw OIDC id_token (direct callers). Resolve the
        # opaque form to the stored id_token FIRST (single-use — popped here, so a
        # second redemption fails), then run the SAME OidcPlug.verify_token path on
        # whichever id_token we end up with. There is exactly one verification path.
        # oidc-session-refresh: resolution also yields the OIDC refresh token (or
        # nil) captured during SSO, threaded into the opaque-session login path.
        {id_token, oidc_refresh_token} = resolve_login_token(token)

        case Nebu.Web.Plugs.OidcPlug.verify_token(id_token) do
          {:error, _reason} ->
            # Do NOT log the token (defense-in-depth, SEC directive).
            error(conn, 403, "M_FORBIDDEN", "Invalid or expired token")

          {:ok, claims} ->
            provision_and_respond(conn, claims, id_token, refresh_requested, oidc_refresh_token,
              client_device_id: client_device_id,
              initial_display_name: initial_display_name
            )
        end
    end
  end

  # S3 F-2: only a PRESENT device_id that fails validation is rejected; an absent /
  # blank value (server will generate one) is not "invalid".
  defp is_present_invalid_device_id?(d) when is_binary(d) and d != "", do: not Nebu.Matrix.DeviceId.valid?(d)
  defp is_present_invalid_device_id?(_), do: false

  # An opaque loginToken (32-byte hex, no JWT dots) is redeemed single-use from the
  # SSO store and replaced with the verified id_token it maps to (plus any OIDC
  # refresh token captured during SSO). A value that is not a known opaque token
  # (e.g. a raw JWT, or an already-redeemed/expired opaque token) is passed through
  # unchanged with no OIDC RT, so OidcPlug.verify_token makes the final call — an
  # expired/already-used opaque token then fails verification (single-use).
  defp resolve_login_token(token) do
    case Nebu.Matrix.SsoStore.pop_login_token(token) do
      {:ok, id_token, oidc_refresh_token} -> {id_token, oidc_refresh_token}
      :error -> {token, nil}
    end
  end

  # Nebu-controlled session lifetime: bounded at min(oidc_exp, now + ceiling). The
  # ceiling keeps sessions short even when Keycloak issues long-lived tokens; the
  # oidc_exp floor means a Nebu session never outlives the OIDC token's own expiry.
  # The Nebu session ceiling (default 8h) is read via
  # Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0 so it can be shortened for tests
  # (NEBU_MATRIX_SESSION_TTL_SECONDS, validated in runtime.exs). Both the login and the
  # /v3/refresh re-mint paths read it through the accessor — no hardcoded ceiling remains.
  defp provision_and_respond(conn, claims, token, refresh_requested, oidc_refresh_token, opts) do
    server = Application.get_env(:nebu_http, :server_name, "localhost")
    user_id = Nebu.Matrix.UserId.from_claims(claims, server)

    display_name = claims["preferred_username"] || claims["name"] || ""
    email = claims["email"] || ""

    case Nebu.Matrix.Session.TokenValidator.validate(user_id, "user", display_name, email) do
      {:ok, user} ->
        # Mirror Go login (Server.validate_token): upsert the profile row so
        # GET /profile/{userId} returns 200 for OIDC-provisioned users.
        dn = if display_name == "", do: nil, else: display_name
        _ = Nebu.Matrix.Profile.DB.upsert_profile(user.user_id, dn, nil)

        # bugfix-autojoin-real-login-path: THIS is the real Matrix client login path
        # (Element Web, FluffyChat, any client hitting POST /_matrix/client/v3/login).
        # Nebu.Matrix.EventDispatcher.Server.validate_token/2 — the ONLY place this
        # provisioning used to run — has no production caller; without this call a
        # brand-new user's first login never got a personal room or auto-join
        # room/space memberships. is_new defaults to false when the TokenValidator
        # implementation omits the key (existing-user re-logins never auto-join).
        is_new = Map.get(user, :is_new, false)
        Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning(user.user_id, is_new)

        # S2 AC2: reuse the client-supplied device_id (keeps the same device row), else
        # generate a fresh one. S2 AC1: login OWNS device creation — register the device
        # in `devices` now (created_at on first sight via S1's COALESCE upsert).
        device_id = opts[:client_device_id] || generate_device_id()
        register_device(user.user_id, device_id, opts[:initial_display_name], conn)

        respond_login(
          conn,
          user.user_id,
          device_id,
          token,
          claims,
          refresh_requested,
          oidc_refresh_token
        )

      {:error, :deactivated} ->
        error(conn, 403, "M_USER_DEACTIVATED", "This account has been deactivated")

      {:error, _reason} ->
        error(conn, 500, "M_UNKNOWN", "Internal server error")
    end
  end

  # AC1: refresh_token: true AND an OIDC refresh token is available → mint an opaque
  # Nebu session (opaque AT+RT, encrypted OIDC RT at rest) and return the v1.3
  # fields. Otherwise (AC7) fall back to the unchanged raw-JWT response.
  defp respond_login(conn, user_id, device_id, _jwt, claims, true, oidc_refresh_token)
       when is_binary(oidc_refresh_token) and oidc_refresh_token != "" do
    access_token = Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()
    refresh_token = Nebu.Matrix.Session.MatrixSessionStore.generate_opaque_token()
    expires_at = session_expires_at(claims)

    :ok =
      Nebu.Matrix.Session.MatrixSessionStore.create(%{
        access_token: access_token,
        refresh_token: refresh_token,
        user_id: user_id,
        device_id: device_id,
        expires_at: expires_at,
        # S3: persist the fresh-auth time for the UIA window. Prefer the id_token's
        # auth_time claim (the IdP's real authentication time); fall back to iat
        # (issued-at) when the IdP does not emit auth_time. A token refresh copies
        # this verbatim (rotate_tokens) — only a fresh login sets it.
        auth_time: login_auth_time(claims),
        oidc_refresh_token: Nebu.Web.SecretBox.encrypt(oidc_refresh_token)
      })

    Logger.info("matrix session created", user_id: user_id, device_id: device_id)

    send_json(conn, 200, %{
      "user_id" => user_id,
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_in_ms" => expires_in_ms(expires_at),
      "device_id" => device_id,
      "token_type" => "Bearer"
    })
  end

  defp respond_login(conn, user_id, device_id, jwt, claims, refresh_requested, _oidc_refresh_token) do
    # AC7 fallback: no refresh requested, or refresh requested but no OIDC RT
    # available (e.g. the IdP did not grant offline_access). Return the verified
    # OIDC JWT verbatim, exactly as before — no opaque session row.
    if refresh_requested do
      # MINOR-3 (Go parity): the client asked for a refreshable session but we
      # could not provide one. Warn (no token values) and degrade to the JWT path.
      Logger.warning(
        "matrix login: refresh_token requested but no OIDC refresh token available — " <>
          "returning JWT (verify the IdP grants offline_access)",
        user_id: user_id
      )
    end

    # S2 AC3 / SECURITY G1: a raw OIDC JWT carries no Nebu device_id, so bind this
    # token to the device SERVER-SIDE. OidcPlug.call_jwt reads the device back from
    # this binding on every authenticated request — the device a request acts as is
    # never taken from attacker-controllable request input.
    # S3 F-1: persist the verified token's exp so the device-delete kill-switch can
    # denylist exactly this token until its own expiry.
    _ = Nebu.Matrix.Session.DeviceBinding.put(jwt, user_id, device_id, claims["exp"])

    send_json(conn, 200, %{
      "user_id" => user_id,
      # No opaque session: return the verified OIDC token as the access_token (the
      # existing JWT verification path in OidcPlug continues to accept it).
      "access_token" => jwt,
      "device_id" => device_id,
      "token_type" => "Bearer"
    })
  end

  # S2 AC1: login registers the device in `devices` (S1 device-registry-model).
  # display_name is passed ONLY when the device is first created — on reuse (AC2) we
  # pass nil so S1's COALESCE keeps the original name (initial_device_display_name is
  # ignored on reuse, per the spec). last_seen_ts/last_seen_ip are refreshed on every
  # login. Best-effort: never block login on the device registry.
  defp register_device(user_id, device_id, initial_display_name, conn) do
    existing = Nebu.Matrix.DeviceKeyStore.get_device(user_id, device_id)
    display_name = if is_nil(existing), do: initial_display_name, else: nil

    _ =
      Nebu.Matrix.DeviceKeyStore.upsert_device(user_id, device_id,
        display_name: display_name,
        last_seen_ts: System.system_time(:millisecond),
        last_seen_ip: client_ip(conn)
      )

    :ok
  end

  defp client_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end

  # Nebu session expiry = min(oidc_exp, now + 8h). oidc_exp is the verified `exp`
  # claim (always an integer post-verification — OidcPlug.check_exp rejects a
  # missing/non-integer exp); the 8h ceiling is the hard upper bound.
  defp session_expires_at(claims) do
    now = System.system_time(:second)
    ceiling = now + SessionConfig.matrix_session_ttl_seconds()

    bound =
      case claims["exp"] do
        exp when is_integer(exp) and exp < ceiling -> exp
        _ -> ceiling
      end

    DateTime.from_unix!(bound)
  end

  defp expires_in_ms(%DateTime{} = expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) |> max(0)
  end

  # S3: the fresh-auth time (unix seconds) for the UIA window. Prefer the OIDC
  # auth_time claim (real IdP authentication time); fall back to iat. nil only if
  # the token carries neither (then the session reads as "stale" → always challenge).
  defp login_auth_time(claims) do
    case claims["auth_time"] do
      t when is_integer(t) ->
        t

      _ ->
        case claims["iat"] do
          t when is_integer(t) -> t
          _ -> nil
        end
    end
  end

  # ── POST /_matrix/client/v3/refresh (oidc-session-refresh, Matrix CS v1.3) ────
  #
  # Mirrors the Go gateway refresh.go PostRefresh:
  #   * UNAUTHENTICATED (spec MUST — registered before the OidcPlug catch-all).
  #   * body {refresh_token}: empty/missing → 400 M_MISSING_PARAM; malformed JSON →
  #     400 M_NOT_JSON.
  #   * unknown / revoked / grace-expired RT → 401 M_UNKNOWN_TOKEN (AC6).
  #   * otherwise: mint a new opaque AT+RT, rotate_tokens/1 (soft-revoke old +
  #     60s grace, carry the encrypted OIDC RT), respond {access_token,
  #     refresh_token, expires_in_ms}.
  defp do_refresh(conn) do
    cond do
      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      not is_map(conn.body_params) ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      true ->
        do_refresh_with(conn, conn.body_params["refresh_token"])
    end
  end

  defp do_refresh_with(conn, refresh_token)
       when not is_binary(refresh_token) or refresh_token == "" do
    error(conn, 400, "M_MISSING_PARAM", "refresh_token is required")
  end

  defp do_refresh_with(conn, refresh_token) do
    alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

    case Store.get_by_refresh_token(refresh_token) do
      :error ->
        error(conn, 401, "M_UNKNOWN_TOKEN", "Unknown or expired refresh token")

      {:ok, sess} ->
        new_at = Store.generate_opaque_token()
        new_rt = Store.generate_opaque_token()
        # Nebu controls the refreshed lifetime independently of the OIDC token
        # (the encrypted OIDC RT is carried over for a possible future Keycloak
        # round-trip). Same configurable ceiling as the login path (default 8h) so the
        # refreshed session honors NEBU_MATRIX_SESSION_TTL_SECONDS too — otherwise a
        # refreshed e2e session would silently revert to 8h. Trade-off documented in
        # the story — a Keycloak-side logout does not immediately invalidate the session.
        new_expires_at =
          DateTime.add(DateTime.utc_now(), SessionConfig.matrix_session_ttl_seconds(), :second)

        case Store.rotate_tokens(%{
               old_access_token: sess.access_token,
               new_access_token: new_at,
               new_refresh_token: new_rt,
               new_expires_at: new_expires_at
             }) do
          :ok ->
            Logger.info("matrix session refreshed",
              user_id: sess.user_id,
              device_id: sess.device_id
            )

            send_json(conn, 200, %{
              "access_token" => new_at,
              "refresh_token" => new_rt,
              "expires_in_ms" => expires_in_ms(new_expires_at)
            })

          :error ->
            # Race: the session was revoked between lookup and rotate.
            error(conn, 401, "M_UNKNOWN_TOKEN", "Refresh token no longer valid")
        end
    end
  end

  # Matrix device IDs: a UUIDv4-shaped opaque string (matches login.go).
  defp generate_device_id do
    bin = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, _c1::4, c2::12, _d1::2, d2::14, e::48>> = bin
    # version 4 + variant bits
    c = Bitwise.bor(0x4000, c2)
    d = Bitwise.bor(0x8000, d2)

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> List.to_string()
  end

  # ── Profile handlers ──────────────────────────────────────────────────────

  defp get_profile(conn, raw_user_id, field) do
    user_id = URI.decode_www_form(raw_user_id)

    case Nebu.Matrix.Profile.DB.get_profile(user_id) do
      {:ok, %{displayname: displayname, avatar_url: avatar_url}} ->
        body =
          case field do
            :displayname -> %{"displayname" => displayname || ""}
            :avatar_url -> %{"avatar_url" => avatar_url}
            :full -> build_profile_body(displayname, avatar_url)
          end

        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> send_json(200, body)

      {:error, :not_found} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=60")
        |> error(404, "M_NOT_FOUND", "Profile not found")

      {:error, _reason} ->
        error(conn, 500, "M_UNKNOWN", "Internal server error")
    end
  end

  # The full profile object omits absent fields (Go emits both keys but with
  # empty/null; the contract test only requires that present keys are strings).
  defp build_profile_body(displayname, avatar_url) do
    %{}
    |> maybe_put("displayname", displayname)
    |> maybe_put("avatar_url", avatar_url)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_profile(conn, raw_user_id, current_user, field) do
    path_user_id = URI.decode_www_form(raw_user_id)

    if path_user_id != current_user do
      error(conn, 403, "M_FORBIDDEN", "You can only update your own profile")
    else
      params = conn.body_params

      {displayname, avatar_url} =
        case field do
          :displayname -> {params["displayname"], nil}
          :avatar_url -> {nil, params["avatar_url"]}
        end

      req = %Core.UpdateProfileRequest{
        user_id: current_user,
        displayname: displayname || "",
        avatar_url: avatar_url || ""
      }

      case call_core(fn ->
             Nebu.Matrix.EventDispatcher.Server.update_profile(req, stream(current_user))
           end) do
        {:ok, _resp} -> send_json(conn, 200, %{})
        {:error, err} -> send_error(conn, err)
      end
    end
  end

  # ── Inline auth for PUT profile (the only authed route in this router) ─────
  #
  # OidcPlug halts the conn on failure (sends 401 + halt). When it does NOT halt,
  # it assigns :current_user. We return {:ok, conn, user} only when not halted.
  defp authenticate(conn) do
    conn = Nebu.Web.Plugs.OidcPlug.call(conn, Nebu.Web.Plugs.OidcPlug.init([]))

    if conn.halted do
      conn
    else
      {:ok, conn, conn.assigns[:current_user]}
    end
  end
end
