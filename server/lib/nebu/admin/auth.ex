defmodule Nebu.Admin.Auth do
  @moduledoc """
  Admin authentication for the Phoenix LiveView Admin UI (admin-ui-migration).

  Mirrors the Go admin backend's auth model (gateway/internal/admin/auth.go):

    * A signed admin session cookie carries the authenticated operator's identity
      (`sub`, `email`) plus the resolved `admin` flag.
    * The admin gate = "is the configured admin group claim present anywhere in the
      operator's OIDC claims" (parity with `auth.MatchesAdminGroupClaim`). The default
      claim value is `instance_admin`; an operator-configured value is read from the
      `server_config.admin_group_claim` row (ADR-018 inline SQL).

  ## Two entry points

    * `fetch_current_user/2` — a Plug placed in the router's `:browser` pipeline. It
      verifies the signed session cookie and assigns `conn.assigns.current_user`
      (a string-keyed map with at least `"admin" => boolean`, plus `"sub"`/`"email"`),
      then stores it in the session so the LiveView socket can read it on connect.

    * `on_mount/4` — a LiveView lifecycle hook (`{Nebu.Admin.Auth, :require_admin}`)
      that halts a non-admin mount with a redirect to `/admin/login` (AC3). It reads
      `current_user` from the LiveView session (populated either by the plug above on
      the static render, or by the unit test's `session:` opts).

  ## ADR-018

  The admin-group-claim lookup is inline SQL against `server_config` executed through
  `Ecto.Adapters.SQL.query/3` — no schema, no repository. Falls back to the default
  `instance_admin` when `Nebu.Repo` is not running (unit tests) or the row is absent.
  """
  import Plug.Conn
  import Phoenix.LiveView, only: [redirect: 2]

  alias Nebu.Web.SecretBox
  alias Nebu.Web.SessionConfig

  require Logger

  @default_admin_group_claim "instance_admin"

  # Key under which the in-flight OIDC login state (state/verifier/nonce/exp) is held
  # in the (signed, http_only, SameSite=Lax) Phoenix admin session. Parity with the
  # Go gateway's signed `admin_oidc_state` cookie — here the Phoenix session itself is
  # the signed envelope (see Nebu.Admin.Endpoint @session_options), so we do not mint
  # a second HMAC cookie. SameSite=Lax is required (not Strict): the callback arrives
  # via a cross-site redirect from the IdP.
  @oidc_login_session_key "admin_oidc_login"

  # Login flow lifetime: the authorization-code round-trip (user typing credentials at
  # the IdP) must complete within this window. Mirrors the Go cookie MaxAge (600s).
  @login_ttl_seconds 600

  # Admin session lifetime cap (default 8h, mirroring the Go gateway's maxSessionDuration)
  # is read via Nebu.Web.SessionConfig.admin_session_ttl_seconds/0 so it can be shortened
  # for tests (NEBU_ADMIN_SESSION_TTL_SECONDS, validated in runtime.exs).

  # Session key under which the AES-256-GCM-encrypted OIDC refresh token is stored in
  # the signed admin session (parity with the Go gateway's encrypted RT). Never plaintext.
  @oidc_rt_session_key "admin_oidc_rt"

  # Pre-expiry refresh window: when an authenticated admin HTTP request arrives within
  # this many seconds of `session_exp`, fetch_current_user/2 silently refreshes the
  # session via the stored OIDC refresh token (AC3). 120s per the story.
  @refresh_window 120

  # SECURITY (admin-liveview-session-refresh, HIGH finding — Kassandra security review
  # 2026-07-01): independent, non-bypassable outer bound on `refreshable?/2`.
  #
  # `refreshable?/1` (single-arity, now removed) used to grant the LiveView `on_mount`
  # gate a grace window purely because the stored OIDC refresh-token blob still
  # DECRYPTED — decryptability has no time component (SecretBox/AES-256-GCM never
  # expires), so that check alone let a de-provisioned admin whose heartbeat is severed
  # (JS disabled, `/admin/keepalive` blocked, backgrounded/throttled tab) keep an open
  # LiveView socket (Dashboard, AuditLog) alive INDEFINITELY across reconnects,
  # bypassing the only other server-side bound (`session_exp` via `session_live?/1`).
  #
  # `refresh_grace_exp` closes that gap: a second, independently-tracked timestamp,
  # written alongside `session_exp` at login and re-written on every SUCCESSFUL
  # HTTP-path refresh (`put_current_user/2`, shared by both write sites). It is a
  # FIXED, bounded grace — `session_exp + @refresh_grace_seconds` — NOT tied to RT-blob
  # decryptability and NOT extended merely by a socket reconnect (reconnects only ever
  # READ this value via `refreshable?/2`, they never write it).
  #
  # `refreshable?/2` now requires BOTH: the RT blob decrypts AND `now <= refresh_grace_exp`.
  # RT-blob decryptability is necessary but no longer SUFFICIENT. Once
  # `refresh_grace_exp` passes — which only happens when the heartbeat has not
  # successfully refreshed the session in a while — `refreshable?/2` returns false
  # regardless of decryptability, and `on_mount` halts + redirects exactly like the
  # pre-fix `session_live?`-only path did.
  #
  # Sizing: the keepalive heartbeat (AC3/AC4) fires every 60s and re-writes
  # `refresh_grace_exp` forward on every successful refresh, so a HEALTHY heartbeat
  # keeps the bound extending in small increments — the idle-tab UX goal (AC2) is
  # unaffected. A grace of 180s (3 minutes) gives a healthy heartbeat ~3 missed/delayed
  # beats of slack (well above @refresh_window=120s, proportionate to it) before the
  # bound lapses, while still keeping the severed-heartbeat exposure window to low
  # single-digit minutes instead of unbounded.
  @refresh_grace_seconds 180

  @behaviour Plug

  # ── Plug: establish current_user from the signed admin session cookie ──────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, :fetch_current_user), do: fetch_current_user(conn, [])
  def call(conn, :require_admin), do: require_admin(conn, [])
  def call(conn, :bootstrap_gate), do: bootstrap_gate(conn, [])
  def call(conn, _opts), do: fetch_current_user(conn, [])

  @doc """
  Plug for HTTP controllers: checks that `current_user` is an authenticated admin.
  Redirects to `/admin/login` if not. Must run AFTER `:fetch_current_user` (which is
  placed in the `:browser` pipeline and runs for all routes).
  """
  def require_admin(conn, _opts) do
    case conn.assigns[:current_user] do
      %{"admin" => true} ->
        conn

      _ ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Admin access required")
        |> Phoenix.Controller.redirect(to: "/admin/login")
        |> halt()
    end
  end

  @doc """
  Plug for the Bootstrap Wizard controller: allows access when bootstrap is NOT complete,
  redirects to `/admin/login` when it IS complete (the wizard would allow re-configuration
  of OIDC + admin-group claim, so it must be locked after setup). Must run AFTER
  `:fetch_current_user` (which is placed in the `:browser` pipeline and runs for all routes).
  """
  def bootstrap_gate(conn, _opts) do
    if bootstrap_completed?() do
      conn
      |> Phoenix.Controller.redirect(to: "/admin/login")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Reads the verified admin session from the session store and assigns `current_user`
  (a map) onto the conn. Never halts here — the per-route admin requirement is enforced
  by the LiveView `on_mount` hook so the whole `/admin` subtree shares one gate.
  """
  def fetch_current_user(conn, _opts) do
    case get_session(conn, "current_user") do
      %{} = user ->
        conn
        |> assign(:current_user, user)
        |> maybe_refresh_session(user)

      _ ->
        assign(conn, :current_user, nil)
    end
  end

  # ── AC3/AC5/AC6: silent pre-expiry OIDC refresh (HTTP plug ONLY) ───────────────
  #
  # Cookies cannot be set over the LiveView websocket, so refresh MUST happen here on
  # HTTP round-trips (dead renders, navigation, page loads). A pure long-open LiveView
  # page with zero HTTP round-trips relies on the `session_exp` cap + the `on_mount`
  # re-check at the next mount — the websocket-only idle edge is an accepted MVP limit.
  defp maybe_refresh_session(conn, user) do
    now = System.system_time(:second)
    exp = user["session_exp"]

    cond do
      # Comfortably inside the session lifetime → nothing to do (AC3 outside-window).
      not (is_integer(exp) and exp - now <= @refresh_window) ->
        conn

      # Inside the window but no RT was stored (provider granted no offline_access).
      # AC6: leave the session as-is, warn once, do NOT attempt a refresh.
      is_nil(get_session(conn, @oidc_rt_session_key)) ->
        Logger.warning(
          "admin session near expiry but no OIDC refresh token present — operator will be " <>
            "logged out at session_exp; ensure the IdP grants offline_access to the admin client"
        )

        conn

      # Inside the window with a stored RT → attempt a silent refresh (AC3/AC5).
      true ->
        refresh_admin_session(conn)
    end
  end

  defp refresh_admin_session(conn) do
    enc_rt = get_session(conn, @oidc_rt_session_key)

    with {:ok, plaintext_rt} <- SecretBox.decrypt(enc_rt),
         {:ok, claims, new_rt} <- exchange_refresh_token(plaintext_rt),
         :ok <- check_admin(claims) do
      # Successful refresh: recompute session_exp + renew the session, then rotate the
      # stored RT (or keep the old encrypted blob if the provider returned no new one).
      conn
      |> put_current_user(claims)
      |> rotate_refresh_token(enc_rt, new_rt)
    else
      _ ->
        # AC5: failed refresh (network/provider rejection/revoked RT) OR the refreshed
        # claims lost the admin-group gate → clear the admin session and redirect to
        # /admin/login cleanly. No raise, no half-authenticated state.
        Logger.warning("admin session refresh failed — clearing session and redirecting to login")

        conn
        # Drop the whole signed session at response time (defence-in-depth: nothing the
        # half-authenticated request carried is replayed)...
        |> configure_session(drop: true)
        # ...and explicitly remove the auth keys NOW so no later code in this same request
        # (and the AC5 assertion) can observe a half-authenticated session.
        |> delete_session("current_user")
        |> delete_session(@oidc_rt_session_key)
        |> assign(:current_user, nil)
        |> Phoenix.Controller.redirect(to: "/admin/login")
        |> halt()
    end
  end

  # Re-encrypt + store the provider-rotated refresh token; keep the existing encrypted
  # blob when the provider returned no new RT (some IdPs do not rotate on refresh).
  defp rotate_refresh_token(conn, _old_enc_rt, new_rt) when is_binary(new_rt) and new_rt != "" do
    put_session(conn, @oidc_rt_session_key, SecretBox.encrypt(new_rt))
  end

  defp rotate_refresh_token(conn, old_enc_rt, _no_new_rt) do
    put_session(conn, @oidc_rt_session_key, old_enc_rt)
  end

  # Performs the `grant_type=refresh_token` exchange + ID-token re-verify, returning
  # `{:ok, refreshed_claims, new_rt | nil}` | `{:error, reason}`. A test seam
  # (`:admin_oidc_refresh_override`, a 1-arity fun receiving the DECRYPTED RT)
  # short-circuits the HTTP+JWT-verify leg, mirroring `:admin_oidc_token_override` for
  # the login leg.
  #
  # matrix-refresh-revalidates-with-idp (AC5): the HTTP-POST + response-parse +
  # verify_token leg itself now lives in the shared `Nebu.Web.OidcTokenExchange`,
  # reused verbatim by the Matrix refresh path — this function is now a thin
  # wrapper (seam check + this domain's own config resolution) around it,
  # structurally identical to how it worked before extraction.
  defp exchange_refresh_token(refresh_token) do
    case Application.get_env(:nebu_http, :admin_oidc_refresh_override) do
      fun when is_function(fun, 1) ->
        fun.(refresh_token)

      _ ->
        with {:ok, cfg} <- oidc_config(nil) do
          Nebu.Web.OidcTokenExchange.refresh(refresh_token, %{
            issuer: cfg.issuer,
            client_id: cfg.client_id,
            client_secret: cfg.client_secret
          })
        end
    end
  end

  @doc """
  Stores the authenticated operator into the session after a successful OIDC login.
  `claims` is the verified ID-token claims map. The `admin` flag is derived from the
  configured admin group claim (server_config) just like the Go backend.

  `"matrix_user_id"` is derived via `Nebu.Matrix.UserId.from_claims/2`, which resolves
  differently depending on which claims are present in `claims`. Historical note
  (bugfix-unify-admin-matrix-oidc-identity): `admin_oidc_scope/0` used to fold in the
  Matrix flow's extra scopes so both flows requested the same claim superset — that
  fold was REMOVED by story `centralize-scope-resolution` (it was the root cause of an
  `offline_access` cross-client leak, AC3). `admin_oidc_scope/0` now resolves each
  client's scopes independently via `Nebu.Web.OidcScopes.resolve_scope/1`; an operator
  who configures different `matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes`
  values can once again see divergent claim sets (and therefore divergent
  `matrix_user_id` resolution) between the two flows — this is an accepted,
  documented trade-off (see `docs/architecture/08-concepts.md`), not a regression.
  """
  def put_current_user(conn, claims) when is_map(claims) do
    exp = session_expiry(claims)

    user = %{
      "sub" => claims["sub"],
      "email" => claims["email"],
      "admin" => admin_claim?(claims),
      # Spaces S5: the operator's Matrix user_id, derived from the SAME claims the
      # public /login + OidcPlug use (Nebu.Matrix.UserId — single source of truth), so
      # admin-initiated Space create/edit/child writes are attributed to the operator's
      # real Matrix identity. The admin acts as a Matrix user (creator → power level 100)
      # so the S2 set_room_state authorization (membership + power level) passes.
      "matrix_user_id" => Nebu.Matrix.UserId.from_claims(claims, server_name()),
      # Parity with the Go gateway maxSessionDuration: cap the admin session at
      # min(idToken.exp, now+8h) so a session never outlives its ID token and is
      # always bounded even if the cookie itself is replayed. on_mount enforces it.
      "session_exp" => exp,
      # SECURITY (admin-liveview-session-refresh HIGH fix): the independent, bounded
      # outer bound consumed by `refreshable?/2` — see the `@refresh_grace_seconds`
      # doc above. Written here (at login AND at every successful HTTP-path refresh,
      # since both call sites share `put_current_user/2`) so it always tracks
      # `session_exp + @refresh_grace_seconds` at the moment the session was last
      # legitimately (re-)established — never extended by a mere socket reconnect.
      "refresh_grace_exp" => exp + @refresh_grace_seconds
    }

    conn
    # configure_session(renew: true) rotates the session id on privilege elevation —
    # defence against session fixation (an attacker-planted pre-login session id cannot
    # be reused post-authentication).
    |> configure_session(renew: true)
    |> put_session("current_user", user)
    |> assign(:current_user, user)
  end

  # provision-matrix-identity-on-admin-login (AC1): called from BOTH
  # normal_callback/2 and bootstrap_confirm_claim/2 — the two admin-login
  # completion points that mint a session via put_current_user/2 for a freshly
  # verified OIDC login (as opposed to the silent pre-expiry HTTP refresh path,
  # `refresh_admin_session/1`, which also calls put_current_user/2 but is
  # deliberately NOT wired here — it is not a new login, and re-provisioning on
  # every refreshed HTTP request would be needless work for no behavioural
  # gain since the identity was already provisioned at the original login).
  #
  # Provisions the SAME `users`-row the real Matrix `/login` path provisions,
  # for the SAME matrix_user_id `put_current_user/2` derives from these claims
  # (Nebu.Matrix.UserId.from_claims/2, single source of truth) — via the
  # Nebu.Matrix facade only (ADR-020). AC2 (this architecture's decision, see
  # the story's "Implementation Decision" note): deliberately does NOT trigger
  # auto-join — Nebu.Matrix.provision_identity/2 only performs the `users`-row
  # + profile upsert.
  #
  # Best-effort: swallows a provisioning failure (logged) rather than blocking
  # the admin session mint that follows — the Phoenix admin session, not
  # Matrix-domain provisioning, is this function's primary contract.
  defp provision_matrix_identity(claims) when is_map(claims) do
    matrix_user_id = Nebu.Matrix.UserId.from_claims(claims, server_name())
    display_name = claims["preferred_username"] || claims["name"] || ""
    email = claims["email"] || ""

    case Nebu.Matrix.provision_identity(matrix_user_id,
           display_name: display_name,
           email: email
         ) do
      {:ok, _user_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "admin login: Matrix identity provisioning failed for #{matrix_user_id}: " <>
            "#{inspect(reason)} — admin session will still be minted"
        )

        :ok
    end
  end

  # AC1+AC2: encrypt the OIDC refresh token (AES-256-GCM via Nebu.Web.SecretBox) and
  # stash it in the signed admin session. Never plaintext, never logged. A nil RT (the
  # provider granted no offline_access) leaves the session untouched and logs a warning
  # so operators can spot the misconfiguration (AC6).
  defp store_refresh_token(conn, refresh_token)
       when is_binary(refresh_token) and refresh_token != "" do
    put_session(conn, @oidc_rt_session_key, SecretBox.encrypt(refresh_token))
  end

  defp store_refresh_token(conn, _no_rt) do
    Logger.warning(
      "admin login: no OIDC refresh token returned — session cannot be silently refreshed; " <>
        "ensure the IdP grants offline_access to the admin client"
    )

    conn
  end

  defp session_expiry(claims) do
    cap = System.system_time(:second) + SessionConfig.admin_session_ttl_seconds()

    case claims["exp"] do
      exp when is_integer(exp) and exp < cap -> exp
      _ -> cap
    end
  end

  # ── OIDC Authorization-Code + PKCE login (go-removal-cleanup) ──────────────────
  #
  # Replaces the deleted Go gateway admin login (gateway/internal/admin/auth.go:
  # LoginStartHandler + CallbackHandler). The hardened ID-token validation is reused
  # verbatim from Nebu.Web.Plugs.OidcPlug.verify_token/1 (alg allowlist, JWKS signature,
  # fail-closed iss/aud, exp, sub) so there is exactly one token-verification code path.

  @doc """
  GET /admin/login/start — begins the OIDC Authorization-Code + PKCE flow.

  Generates a PKCE verifier + S256 challenge, a CSRF `state`, and an OIDC `nonce`,
  stashes `{state, verifier, nonce, exp}` in the signed Phoenix session, and 302-redirects
  the browser to the provider's `authorization_endpoint`.

  Returns the conn with a redirect, or a 5xx when OIDC config / discovery is unavailable.
  """
  def login_start(conn, params) do
    mode = params["mode"]

    # AC5 (security): the bootstrap-mode login leg is INERT once bootstrap is complete.
    # It exists only so the first operator can mint an admin session before any
    # admin-group claim is configured; after setup it must NOT let an unauthenticated
    # party re-run OIDC against the draft creds.
    if mode == "bootstrap" and bootstrap_completed?() do
      conn
      |> Phoenix.Controller.redirect(to: "/admin/login")
      |> halt()
    else
      do_login_start(conn, mode)
    end
  end

  defp do_login_start(conn, mode) do
    with {:ok, cfg} <- oidc_config(mode),
         {:ok, authorization_endpoint} <- discover(cfg.issuer, "authorization_endpoint") do
      verifier = pkce_verifier()
      challenge = pkce_challenge(verifier)
      state = random_token(16)
      nonce = random_token(32)

      login_state = %{
        "state" => state,
        "verifier" => verifier,
        "nonce" => nonce,
        # The mode is bound into the (signed) login state so the callback knows whether
        # to enforce the admin gate (normal) or render claim selection (bootstrap). It
        # cannot be tampered with via the query string on the callback.
        "mode" => mode,
        "exp" => System.system_time(:second) + @login_ttl_seconds
      }

      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => cfg.client_id,
          "redirect_uri" => redirect_uri(),
          "scope" => cfg.scope,
          "state" => state,
          "nonce" => nonce,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "prompt" => "login"
        })

      authorize_url = authorization_endpoint <> "?" <> query

      conn
      |> put_session(@oidc_login_session_key, login_state)
      |> Phoenix.Controller.redirect(external: authorize_url)
      |> halt()
    else
      {:error, reason} ->
        Logger.error("admin login_start failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Admin OIDC login is not available. #{describe(reason)}")
        |> halt()
    end
  end

  @doc """
  GET /admin/callback — completes the OIDC Authorization-Code + PKCE flow.

    1. Validate `state` (constant-time) against the value stashed at login_start (CSRF).
    2. Exchange the `code` for tokens at the provider `token_endpoint` (with PKCE verifier).
    3. Verify the ID token via `OidcPlug.verify_token/1` (signature/alg/iss/aud/exp/sub).
    4. Verify the `nonce` claim equals the stashed nonce (replay protection).
    5. Enforce the admin-group-claim gate.
    6. Mint the Phoenix admin session (`put_current_user`) and redirect to /admin/rooms.

  Any failure clears the login state from the session and bounces to /admin/login?error=…
  (or 400 for a missing/forged state — there is nothing to bounce back to).
  """
  def callback(conn, params) do
    login_state = get_session(conn, @oidc_login_session_key)

    case validate_state(login_state, params["state"]) do
      :ok ->
        do_callback(conn, params, login_state)

      {:error, reason} ->
        Logger.warning("admin callback state rejected: #{inspect(reason)}")

        conn
        |> delete_session(@oidc_login_session_key)
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Invalid login state")
        |> halt()
    end
  end

  defp do_callback(conn, params, login_state) do
    conn = delete_session(conn, @oidc_login_session_key)
    mode = login_state["mode"]

    with {:ok, code} <- require_code(params),
         {:ok, cfg} <- oidc_config(mode),
         {:ok, claims, refresh_token} <- exchange_and_verify(code, login_state, cfg),
         :ok <- check_nonce(claims, login_state["nonce"]) do
      if mode == "bootstrap" do
        bootstrap_callback(conn, claims)
      else
        normal_callback(conn, claims, refresh_token)
      end
    else
      {:error, reason} ->
        Logger.warning("admin callback failed: #{inspect(reason)}")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()
    end
  end

  # Exchanges the code and verifies the ID token. Returns `{:ok, claims, refresh_token}`
  # where `refresh_token` is the OIDC RT (or nil when the provider granted none). A test
  # seam (`:admin_oidc_token_override`, a 0-arity fun) short-circuits the HTTP+JWT-verify
  # leg only — every surrounding check (state, nonce, mode branch) still runs. Mirrors the
  # existing `:oidc_metadata_override` seam. The seam may return either the legacy
  # `{:ok, claims}` (no RT) or the extended `{:ok, claims, refresh_token}` 3-tuple.
  defp exchange_and_verify(code, login_state, cfg) do
    case Application.get_env(:nebu_http, :admin_oidc_token_override) do
      fun when is_function(fun, 0) ->
        normalize_token_result(fun.())

      _ ->
        with {:ok, token_endpoint} <- discover(cfg.issuer, "token_endpoint"),
             {:ok, id_token, refresh_token} <-
               exchange_code(token_endpoint, code, login_state["verifier"], cfg),
             {:ok, claims} <- verify_id_token(id_token, login_state["mode"], cfg) do
          {:ok, claims, refresh_token}
        end
    end
  end

  # Verify the operator ID token. NORMAL mode uses the global caches (post-bootstrap they
  # ARE warm: issuer from OidcConfig, keys from JwksCache); only the aud is overridden to
  # the single client_id. Every other check (signature/alg/iss/exp/sub) is identical to
  # the Matrix bearer path.
  defp verify_id_token(id_token, "bootstrap", cfg) do
    # oidc-bootstrap-only-e2e-regressions (AC1/AC2): mid-bootstrap the global
    # JwksCache/OidcConfig are EMPTY (config still lives in bootstrap_draft). Fetch the
    # signing keys LOCALLY from the draft's JWKS URI (or discover from the draft issuer)
    # using the SAME TLS-verifying fetcher JwksCache uses, and verify with the draft
    # issuer + keys passed as overrides — WITHOUT warming the global caches (the Matrix
    # API must stay fail-closed until bootstrap completes). A fetch failure is a clean
    # tagged error so the callback logs + bounces rather than crashing the request.
    case Nebu.Web.JwksCache.fetch_keys_for(cfg.jwks_uri, cfg.issuer) do
      {:ok, keys} ->
        Nebu.Web.Plugs.OidcPlug.verify_token(id_token,
          issuer: cfg.issuer,
          audience: cfg.client_id,
          jwks: keys
        )

      :error ->
        {:error, :bootstrap_jwks_unavailable}
    end
  end

  defp verify_id_token(id_token, _mode, cfg) do
    Nebu.Web.Plugs.OidcPlug.verify_token(id_token, audience: cfg.client_id)
  end

  # Accept both the legacy 2-tuple and the extended 3-tuple from the override seam.
  defp normalize_token_result({:ok, claims}), do: {:ok, claims, nil}
  defp normalize_token_result({:ok, claims, refresh_token}), do: {:ok, claims, refresh_token}
  defp normalize_token_result({:error, _} = err), do: err

  # Normal admin login: enforce the admin-group gate, mint the session, land on the
  # dashboard (consistent with the bootstrap-completion landing; the AC "reaches
  # dashboard" expects this). The sidebar lets the operator reach rooms/users from there.
  defp normal_callback(conn, claims, refresh_token) do
    case check_admin(claims) do
      :ok ->
        provision_matrix_identity(claims)

        conn
        |> put_current_user(claims)
        |> store_refresh_token(refresh_token)
        |> Phoenix.Controller.redirect(to: "/admin/dashboard")
        |> halt()

      {:error, :not_admin} ->
        Logger.warning("admin callback denied: admin group claim absent")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Access denied: admin group claim not present in token.")
        |> halt()
    end
  end

  # Bootstrap-mode callback (Go parity: CallbackHandler sc.Mode == "bootstrap"). The ID
  # token is verified but the admin-group gate is SKIPPED — no admin exists yet. The
  # authenticated sub/email are stashed in the draft (consumed by bootstrap_confirm_claim/2)
  # and the discovered claims are rendered as a selectable list. AC5: refuse if bootstrap
  # is already complete (defence-in-depth; login_start also refuses).
  defp bootstrap_callback(conn, claims) do
    cond do
      bootstrap_completed?() ->
        conn
        |> Phoenix.Controller.redirect(to: "/admin/login")
        |> halt()

      not is_binary(claims["sub"]) or claims["sub"] == "" ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "invalid token: missing sub claim")
        |> halt()

      true ->
        put_draft("bootstrap_sub", claims["sub"])
        put_draft("bootstrap_email", claims["email"] || "")
        # SEC (Kassandra C1, claim-value injection): stash the verified token's discovered
        # claim VALUES server-side so bootstrap_confirm_claim/2 can reject any POSTed
        # admin_group_claim that is NOT one of them. This is exactly the set rendered on the
        # select-claim page (extract_discovered_claims/1) — the operator may only pick a
        # value that actually appeared in the token they authenticated with, so the org-wide
        # admin gate can never be decoupled from that token by a forged/free-form POST body.
        put_draft("bootstrap_claims", encode_discovered_claims(claims))
        # fix-bootstrap-admin-session-identity AC2: also stash the FULL verified claims map
        # (not the flattened bootstrap_claims list above, which dot-paths nested objects for
        # the claim-picker UI and is NOT usable as input to Nebu.Matrix.UserId.from_claims/2,
        # which does direct flat-key lookups like claims["preferred_username"]). This is what
        # lets bootstrap_confirm_claim/2 mint the session via the SAME put_current_user/2 path
        # normal_callback/2 uses, so matrix_user_id is derived identically to a subsequent
        # normal re-login of the same person. Draft storage is already server-side (no new
        # attack surface — same trust boundary as bootstrap_claims above).
        put_draft("bootstrap_full_claims", Jason.encode!(claims))

        conn
        |> Phoenix.Controller.redirect(to: "/admin/bootstrap/select-claim")
        |> halt()
    end
  end

  # Serialize the discovered {key, value} pairs as a JSON list of [key, value] lists
  # (tuples are not JSON-encodable). Decoded back into a value-set by confirm.
  defp encode_discovered_claims(claims) do
    claims
    |> extract_discovered_claims()
    |> Enum.map(fn {k, v} -> [k, v] end)
    |> Jason.encode!()
  end

  # scope-admin-claim-to-path (AC2, code-review MINOR m1 fix): the set of {path, value}
  # PAIRS the operator was actually shown, reconstructed from the server-side stash
  # written by bootstrap_callback/2. An absent or malformed stash yields the empty set,
  # so confirm fails CLOSED (rejects everything). The single source of truth for
  # decoding "bootstrap_claims" -- discovered_claim_values/1 below derives from this
  # rather than re-decoding independently, so the two can never drift on parsing rules.
  defp discovered_claim_pairs(draft) do
    case draft["bootstrap_claims"] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, pairs} when is_list(pairs) ->
            for [k, v] <- pairs, is_binary(v), into: MapSet.new(), do: {k, v}

          _ ->
            MapSet.new()
        end

      _ ->
        MapSet.new()
    end
  end

  # The set of claim VALUES the operator was actually shown (and is allowed to choose),
  # ignoring which path each value appeared under -- used by the legacy value-only
  # membership check in bootstrap_confirm_claim/2. Derived from discovered_claim_pairs/1
  # rather than re-decoding "bootstrap_claims" independently (code-review MINOR m1).
  defp discovered_claim_values(draft) do
    draft |> discovered_claim_pairs() |> Enum.map(fn {_k, v} -> v end) |> MapSet.new()
  end

  # scope-admin-claim-to-path (AC2, code-review MAJOR M1 fix): the select-claim form now
  # submits a single JSON-encoded "admin_group_claim_choice" param carrying BOTH the
  # chosen value and its dot-path (see select_claim_html/1). A bare legacy
  # "admin_group_claim" param (no path) OR a malformed/undecodable
  # "admin_group_claim_choice" both resolve to `{nil, nil}` here -- deliberately NOT a
  # legacy value paired with a nil path, since bootstrap_confirm_claim/2's `cond` REJECTS
  # a nil `selected_path` unconditionally (path is mandatory on every fresh bootstrap
  # completion, closing the M1 gap where a legacy-shaped or malformed submission could
  # otherwise silently complete bootstrap with no path and permanently pin the instance
  # on admin_claim?/1's any-key-scan fallback) -- resolving a "selected value" in that
  # case would be dead work, since the request is rejected before it's ever used.
  # This function only DECODES the submission; it deliberately does not itself decide
  # accept/reject -- that stays in bootstrap_confirm_claim/2 alongside the other
  # discovered-claim validations, so all rejection reasons are visible in one place.
  defp resolve_selection(params) do
    case params["admin_group_claim_choice"] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, %{"value" => value, "path" => path}}
          when is_binary(value) and value != "" and is_binary(path) and path != "" ->
            {value, path}

          _ ->
            {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  # fix-bootstrap-admin-session-identity (AC2): decode the full verified claims map stashed
  # by bootstrap_callback/2 under "bootstrap_full_claims" (Jason-encoded, NOT the flattened
  # "bootstrap_claims" list — that one is dot-path-flattened for the claim-picker UI and is
  # not usable as input to Nebu.Matrix.UserId.from_claims/2's flat-key lookups).
  #
  # A legacy in-flight bootstrap (started before this fix shipped) has no
  # "bootstrap_full_claims" key at all — falls back to reconstructing a flat claims map
  # from "bootstrap_claims" (the dot-path-flattened discovered-claims list) plus
  # "bootstrap_sub"/"bootstrap_email", which is exactly what every prior bootstrap_callback/2
  # run already stashed. Only BARE (non-dot-path) keys are restored — a nested claim (e.g.
  # "realm_access.roles") cannot be losslessly reconstructed from its flattened form, but
  # `Nebu.Matrix.UserId.from_claims/2` only ever does flat top-level lookups
  # (configured claim / preferred_username / name / sub), so this is sufficient for its
  # purposes. Repeated bare keys (multi-valued claims, e.g. "groups") are folded into a list.
  # Fails closed (:error) only when NEITHER stash is present/decodable, so
  # bootstrap_confirm_claim/2 never mints a session from incomplete or untrusted data.
  defp bootstrap_claims(draft) do
    case draft["bootstrap_full_claims"] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, %{} = claims} -> {:ok, claims}
          _ -> reconstruct_claims_from_flattened(draft)
        end

      _ ->
        reconstruct_claims_from_flattened(draft)
    end
  end

  defp reconstruct_claims_from_flattened(draft) do
    case draft["bootstrap_claims"] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, pairs} when is_list(pairs) ->
            claims =
              for [k, v] <- pairs, is_binary(k), not String.contains?(k, "."), is_binary(v), reduce: %{} do
                acc ->
                  Map.update(acc, k, v, fn
                    existing when is_list(existing) -> existing ++ [v]
                    existing -> [existing, v]
                  end)
              end
              |> Map.put_new_lazy("sub", fn -> draft["bootstrap_sub"] end)
              |> Map.put_new_lazy("email", fn -> draft["bootstrap_email"] end)

            {:ok, claims}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc """
  POST /admin/bootstrap/select-claim — completes bootstrap after the operator selects the
  admin-group claim value (Go parity: ClaimSelectionHandler).

  In a single logical transaction (Go saveBootstrapConfigTx + completeBootstrapTx): promote
  the draft OIDC config into `server_config`, write the chosen `admin_group_claim`, set
  `bootstrap_completed = "true"`, clear the draft, then mint the admin session and redirect
  to `/admin/dashboard`.

  AC5 (security): refuses with a redirect to `/admin/login` if bootstrap is ALREADY
  complete — an unauthenticated party must not be able to re-pick the admin claim or
  overwrite OIDC config after setup. Also refuses if the bootstrap identity (sub) is
  absent from the draft (no prior bootstrap-mode callback).
  """
  def bootstrap_confirm_claim(conn, params) do
    {selected, selected_path} = resolve_selection(params)
    draft = load_draft()

    cond do
      bootstrap_completed?() ->
        Logger.warning("bootstrap claim selection refused: bootstrap already completed")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login")
        |> halt()

      not is_binary(draft["bootstrap_sub"]) or draft["bootstrap_sub"] == "" ->
        Logger.warning("bootstrap claim selection refused: no authenticated bootstrap identity")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()

      # scope-admin-claim-to-path (AC2/AC3, code-review MAJOR M1 fix): a path is now
      # MANDATORY on every bootstrap completion, not merely accepted-when-present. AC3.2's
      # any-key-scan fallback exists ONLY for deployments that completed bootstrap BEFORE
      # this story shipped (their server_config genuinely has no admin_group_claim_path
      # row and never will, short of a manual re-run) — it must NOT be reachable via a
      # FRESH bootstrap simply by POSTing the pre-story param shape. Bootstrap completes
      # exactly once (guarded by bootstrap_completed?/0 above), so once this check is in
      # place there is no legitimate way for a new instance to end up path-less: every
      # first-time completion is forced through the path-carrying form field. The shipped
      # select_claim_html/1 template only ever emits "admin_group_claim_choice" going
      # forward, so a well-behaved client submission always has selected_path set; a
      # bare/legacy "admin_group_claim" param (old cached page, forged/replayed request,
      # browser devtools) is refused here rather than silently succeeding path-less.
      #
      # Checked BEFORE the discovered-value/pair checks below: resolve_selection/1 always
      # returns `{nil, nil}` together (never a non-nil value paired with a nil path), so
      # this is the correct, most-specific diagnostic for every legacy/malformed
      # submission — checking value-membership first would instead misreport them all as
      # "claim value not in verified token", masking the real (missing-path) reason.
      is_nil(selected_path) ->
        Logger.warning("bootstrap claim selection refused: no claim path submitted (path is mandatory on bootstrap completion)")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()

      # SEC (Kassandra C1, claim-value injection): the chosen value MUST be one of the
      # claim VALUES discovered in the verified ID token (stashed by bootstrap_callback/2,
      # identical to the set rendered on the select-claim page). A free-form / forged value
      # would let an operator — or anyone able to drive this POST while bootstrap is
      # incomplete — decouple the org-wide admin gate from the token they authenticated
      # with. Reject (no config write, no completion, no session) and bounce to login.
      not MapSet.member?(discovered_claim_values(draft), selected) ->
        Logger.warning("bootstrap claim selection refused: claim value not in verified token")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()

      # SEC (unchanged from before M1 fix): the submitted {path, value} pair MUST be one
      # of the discovered PAIRS, not just an independently-valid path and an
      # independently-valid value from two different discovered entries. Without this, an
      # attacker who can drive this POST mid-bootstrap could pair a real discovered value
      # with an unrelated real discovered path, decoupling the persisted path from the
      # value it actually appeared under.
      not MapSet.member?(discovered_claim_pairs(draft), {selected_path, selected}) ->
        Logger.warning("bootstrap claim selection refused: claim path/value pair not in verified token")

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()

      # fix-bootstrap-admin-session-identity (AC2 edge case): checked BEFORE
      # complete_bootstrap/2 runs — a legacy in-flight bootstrap (started before this fix
      # shipped) has no "bootstrap_full_claims" stash. Reject up front so bootstrap_completed
      # is never set to "true" and no session is minted from incomplete/untrusted data; the
      # operator re-runs the (cheap, idempotent) bootstrap callback to get a fresh draft.
      match?(:error, bootstrap_claims(draft)) ->
        Logger.warning(
          "bootstrap claim selection refused: bootstrap_full_claims missing/invalid in draft"
        )

        conn
        |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
        |> halt()

      true ->
        {:ok, claims} = bootstrap_claims(draft)

        case complete_bootstrap(draft, selected, selected_path) do
          :ok ->
            # fix-bootstrap-admin-session-identity (AC1/AC2): mint the session via the SAME
            # builder normal_callback/2 uses — put_current_user/2 — instead of a second,
            # separate map construction. That is what previously left "matrix_user_id" out of
            # the bootstrap-completion session entirely (RoomsController/UsersController's
            # actor_id/1 then fell back to the raw OIDC sub for any admin-initiated write in
            # this session). put_current_user/2 needs the FULL verified claims map (not just
            # sub/email) to derive matrix_user_id identically to how a subsequent normal
            # re-login of the same person would — bootstrap_callback/2 now stashes that map
            # under "bootstrap_full_claims" for exactly this purpose.
            #
            # No RT is captured on the bootstrap-completion leg (bootstrap-mode never runs the
            # refresh-token exchange normal_callback/2's OIDC round-trip does), so
            # put_current_user/2 sets "refresh_grace_exp" from session_exp as usual but
            # refreshable?/2 will still correctly return false regardless — no store_refresh_
            # token/2 call follows, same as the old hand-rolled path.
            #
            # provision-matrix-identity-on-admin-login (AC1): bootstrap completion is a
            # login too — provision the SAME matrix_user_id's `users`-row here, exactly
            # as normal_callback/2 does.
            provision_matrix_identity(claims)

            conn
            |> put_current_user(claims)
            |> Phoenix.Controller.redirect(to: "/admin/dashboard")
            |> halt()

          {:error, reason} ->
            # MINOR-1 (cycle-2): guard in do_complete_bootstrap/2 rejected the
            # completion (e.g. missing audience). Do NOT set bootstrap_completed or
            # mint a session. Log the reason and bounce back to login so the operator
            # can re-enter the wizard with the correct configuration.
            Logger.warning("bootstrap_confirm_claim rejected by do_complete_bootstrap: #{inspect(reason)}")

            conn
            |> Phoenix.Controller.redirect(to: "/admin/login?error=auth_failed")
            |> halt()
        end
    end
  end

  @doc """
  GET /admin/bootstrap/select-claim — direct navigation to the claim-selection page.

  This page is only meaningful immediately after a bootstrap-mode OIDC callback (which
  renders it inline, having stashed the verified token's discovered claims). On a direct
  GET we have no freshly-verified token claims, so we send the operator back into the
  wizard. AC5: once bootstrap is complete this route is itself inert — it redirects to
  `/admin/login` here (and `bootstrap_confirm_claim/2` independently re-checks
  `bootstrap_completed?()`), so a completed instance can never re-render or re-submit the
  claim picker.
  """
  def select_claim_page(conn, _params) do
    if bootstrap_completed?() do
      conn |> Phoenix.Controller.redirect(to: "/admin/login") |> halt()
    else
      draft = load_draft()
      case Jason.decode(draft["bootstrap_claims"] || "") do
        {:ok, pairs} when is_list(pairs) and pairs != [] ->
          # Reconstruct a claims map from stashed pairs so select_claim_html/1
          # can call extract_discovered_claims/1 on it and produce the same options.
          claims =
            pairs
            |> Enum.group_by(fn [k, _v] -> k end, fn [_k, v] -> v end)
            |> Enum.map(fn
              {k, [v]} -> {k, v}
              {k, vs} -> {k, vs}
            end)
            |> Map.new()

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, select_claim_html(claims))
          |> halt()

        _ ->
          conn |> Phoenix.Controller.redirect(to: "/admin/bootstrap") |> halt()
      end
    end
  end

  @doc """
  GET /admin/logout — clears the admin session (drops `current_user`) and returns to login.
  """
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> Phoenix.Controller.redirect(to: "/admin/login")
    |> halt()
  end

  # ── PKCE + CSRF helpers ────────────────────────────────────────────────────────

  # RFC 7636 §4.1: code_verifier = 43–128 chars from the unreserved set. 32 random
  # bytes → 43 base64url chars (no padding), the recommended high-entropy verifier.
  defp pkce_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # RFC 7636 §4.2: code_challenge = BASE64URL(SHA256(ASCII(verifier))). S256 only —
  # the plain method is never offered (it provides no protection against a leaked code).
  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp random_token(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  # Constant-time state comparison + expiry check. A missing session state (no prior
  # login_start, e.g. a forged callback) fails CLOSED.
  defp validate_state(nil, _query_state), do: {:error, :missing_login_state}
  defp validate_state(_login_state, nil), do: {:error, :missing_query_state}
  defp validate_state(_login_state, ""), do: {:error, :missing_query_state}

  defp validate_state(%{"state" => stored, "exp" => exp}, query_state)
       when is_binary(stored) and is_binary(query_state) do
    cond do
      System.system_time(:second) > exp -> {:error, :login_expired}
      secure_compare(stored, query_state) -> :ok
      true -> {:error, :state_mismatch}
    end
  end

  defp validate_state(_, _), do: {:error, :malformed_login_state}

  defp secure_compare(a, b), do: Plug.Crypto.secure_compare(a, b)

  defp require_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp require_code(_), do: {:error, :missing_code}

  # OIDC nonce binding (RFC OpenID Connect Core §3.1.3.7). The cookie/session nonce was
  # generated at login_start; the ID token MUST echo it back. An absent stored nonce
  # (legacy/corrupt session) fails CLOSED so it cannot match an absent token nonce.
  defp check_nonce(_claims, stored) when not is_binary(stored) or stored == "",
    do: {:error, :missing_nonce}

  defp check_nonce(claims, stored) do
    case claims["nonce"] do
      n when is_binary(n) and n != "" ->
        if secure_compare(n, stored), do: :ok, else: {:error, :nonce_mismatch}

      _ ->
        {:error, :missing_token_nonce}
    end
  end

  defp check_admin(claims) do
    if admin_claim?(claims), do: :ok, else: {:error, :not_admin}
  end

  # ── Token exchange ──────────────────────────────────────────────────────────────

  # Exchanges the authorization code at the token endpoint using PKCE (code_verifier)
  # and HTTP Basic client authentication. Returns `{:ok, id_token, refresh_token}` (the
  # raw id_token string for the caller to verify with OidcPlug.verify_token/1, plus the
  # OIDC refresh token or nil). TLS peer verification mirrors JwksCache.http_opts_for/1
  # (https endpoints only; http:// is the dev-internal Dex).
  defp exchange_code(token_endpoint, code, verifier, cfg) when is_binary(verifier) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri(),
        "code_verifier" => verifier,
        "client_id" => cfg.client_id
      })

    case token_endpoint_post(token_endpoint, body, cfg) do
      {:ok, resp_body} -> extract_tokens(resp_body)
      {:error, _} = err -> err
    end
  end

  defp exchange_code(_endpoint, _code, _verifier, _cfg), do: {:error, :missing_verifier}

  # Shared token-endpoint POST (HTTP Basic client auth + TLS peer verification + 5s
  # timeout, fail-closed) used by both the authorization-code exchange and the
  # refresh-token exchange. Returns the raw 2xx response body or a tagged error.
  defp token_endpoint_post(token_endpoint, body, cfg) do
    basic = Base.encode64("#{cfg.client_id}:#{cfg.client_secret}")

    headers = [
      {~c"content-type", ~c"application/x-www-form-urlencoded"},
      {~c"accept", ~c"application/json"},
      {~c"authorization", String.to_charlist("Basic " <> basic)}
    ]

    request = {String.to_charlist(token_endpoint), headers, ~c"application/x-www-form-urlencoded", body}
    http_opts = [timeout: 5_000, connect_timeout: 5_000] ++ tls_opts_for(token_endpoint)

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, {{_http, status, _reason}, _headers, _resp_body}} ->
        {:error, {:token_endpoint_status, status}}

      {:error, reason} ->
        {:error, {:token_endpoint_unreachable, reason}}
    end
  end

  # Parses the token-endpoint JSON into `{:ok, id_token, refresh_token}`. The
  # `refresh_token` is optional (nil when the provider granted no offline_access — AC6).
  defp extract_tokens(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"id_token" => id_token} = body} when is_binary(id_token) and id_token != "" ->
        {:ok, id_token, refresh_token_from(body)}

      {:ok, _} ->
        {:error, :no_id_token}

      {:error, _} ->
        {:error, :malformed_token_response}
    end
  end

  defp refresh_token_from(%{"refresh_token" => rt}) when is_binary(rt) and rt != "", do: rt
  defp refresh_token_from(_), do: nil

  # ── OIDC config + discovery ──────────────────────────────────────────────────────

  @doc false
  # Test-only seam for the oidc-bootstrap-only-config ATDD suite: exposes the private
  # oidc_config/1 resolution so a unit test can assert DB-only resolution without
  # driving the full OIDC HTTP flow. Not used in production code paths.
  def oidc_config_for_test(mode), do: oidc_config(mode)

  # oidc-bootstrap-only-config (ADR-022): the admin operator login uses the SINGLE
  # wizard-configured OIDC client — the same client that validates Matrix Bearer
  # tokens. There is no separate admin client and no NEBU_ADMIN_OIDC_* / NEBU_OIDC_*
  # env config. The /admin/callback redirect_uri is registered on that one client.
  #
  # In bootstrap mode the config has NOT yet been promoted into server_config, so the
  # issuer + client are read from the bootstrap_draft (Go parity: loadOIDCConfigFromDraft),
  # decrypting the at-rest secret. In normal mode they come from server_config.
  # Fails CLOSED when issuer or client_id is absent.
  defp oidc_config("bootstrap") do
    draft = load_draft()
    issuer = draft["oidc_issuer"]
    {client_id, client_secret} = bootstrap_operator_client(draft)
    scope = admin_oidc_scope()
    # oidc-bootstrap-only-e2e-regressions (AC1): surface the draft's explicit JWKS URI so
    # exchange_and_verify can fetch the operator-token signing keys from the DRAFT (the
    # global JwksCache is empty mid-bootstrap). May be nil — then keys are discovered from
    # the draft issuer's well-known document instead.
    jwks_uri = draft["oidc_jwks_uri"]

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :bootstrap_draft_incomplete}
      not is_binary(client_id) or client_id == "" -> {:error, :bootstrap_draft_incomplete}
      true ->
        {:ok,
         %{
           issuer: issuer,
           client_id: client_id,
           client_secret: client_secret,
           scope: scope,
           jwks_uri: jwks_uri
         }}
    end
  end

  defp oidc_config(_mode) do
    # oidc-bootstrap-only-config (ADR-022): issuer + the single client are resolved
    # SOLELY from server_config (issuer via OidcConfig cache, client via
    # admin_config_value/1, mirroring SsoLogin.resolve_client_credentials/0). No env path.
    issuer = Nebu.Web.OidcConfig.get().issuer
    client_id = admin_config_value("oidc_client_id")
    encrypted = admin_config_value("oidc_client_secret") || ""
    client_secret = Nebu.Admin.BootstrapLive.decrypt_secret(encrypted)
    scope = admin_oidc_scope()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :issuer_not_configured}
      not is_binary(client_id) or client_id == "" -> {:error, :client_id_not_configured}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret, scope: scope}}
    end
  end

  @sql_admin_oidc_config "SELECT value FROM server_config WHERE key = $1 LIMIT 1"

  # Test seam: :admin_oidc_config_reader is a 1-arity fun `fn(key) -> value | nil`.
  # When set, it replaces the live Repo query for server_config lookups — lets tests
  # inject OIDC config (client_id, client_secret) without a live PostgreSQL connection.
  # Mirrors the :sso_bootstrap_reader seam in Nebu.Matrix.SsoLogin.
  defp admin_config_value(key) do
    case Application.get_env(:nebu_http, :admin_oidc_config_reader) do
      fun when is_function(fun, 1) ->
        fun.(key)

      _ ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_admin_oidc_config, [key]) do
            {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
            _ -> nil
          end
        else
          nil
        end
    end
  end

  # oidc-bootstrap-only-config (ADR-022): the operator-login OIDC client in bootstrap
  # mode is the SINGLE wizard-configured (draft) client — there is no separate admin
  # client and no NEBU_ADMIN_OIDC_* env. The /admin/callback redirect_uri is registered
  # on that one client (eliminating the env-vs-draft mismatch that caused the
  # "Unregistered redirect_uri" bug class). The at-rest secret is decrypted here.
  defp bootstrap_operator_client(draft) do
    draft_secret = Nebu.Admin.BootstrapLive.decrypt_secret(draft["oidc_client_secret"] || "")
    {draft["oidc_client_id"], draft_secret}
  end

  # The admin authorization scope. Story centralize-scope-resolution: scope
  # resolution (extra-scopes read, refresh-mode read, "openid" base, OIDC Scopes
  # Law default) is now centralized in Nebu.Web.OidcScopes — the SINGLE source of
  # OIDC scope resolution for both Matrix and Admin. This is a thin delegate
  # (AC4); admin/auth.ex no longer runs its own server_config SQL reads for
  # scopes, defines no local scope-validation regex, and no longer reaches into
  # the Matrix domain (directly or via any facade) to fold that flow's extra
  # scopes into the admin request — each client resolves its OWN extra scopes /
  # refresh mode only (AC3: this also fixes the `offline_access` cross-client
  # leak the old cross-client scope fold could cause). The pre-existing
  # :admin_oidc_extra_scopes_reader / :admin_oidc_refresh_mode_reader test seams
  # are honoured by OidcScopes itself, unchanged in name/shape, so existing tests
  # keep passing.
  #
  # Note: this intentionally reverses the pre-story
  # bugfix-unify-admin-matrix-oidc-identity fold (Matrix extra scopes were folded
  # into the admin scope so both ID tokens carried the same claim superset). That
  # fold was the root cause of the AC3 `offline_access` leak (Kassandra LOW) and is
  # removed per this story's Implementation Map; identity/claim unification across
  # independently-scoped flows is tracked separately (see story Non-Goals: "Kein
  # Claim-Mapping").
  defp admin_oidc_scope, do: Nebu.Web.OidcScopes.resolve_scope(:admin)

  # The redirect_uri MUST be a fixed, server-controlled value registered with the IdP —
  # it is NOT derived from request headers (Host/X-Forwarded-*), which an attacker could
  # spoof to redirect the auth code elsewhere. oidc-bootstrap-only-config (ADR-022):
  # there is no NEBU_ADMIN_OIDC_REDIRECT_URI env; it is always derived from :server_name
  # + :admin_session_secure app config and registered on the single OIDC client.
  defp redirect_uri, do: derive_admin_redirect_uri()

  defp derive_admin_redirect_uri do
    server_name = Application.get_env(:nebu_http, :server_name, "localhost")
    secure = Application.get_env(:nebu_http, :admin_session_secure, true)
    scheme = if secure, do: "https", else: "http"
    host = if server_name == "localhost", do: "localhost:8008", else: server_name
    "#{scheme}://#{host}/admin/callback"
  end

  # Resolves one endpoint from the provider discovery document via the existing
  # TLS-verifying Nebu.Matrix.OidcMetadata fetcher (which honours the :oidc_metadata_override
  # test seam). Returns {:error, ...} when the field is absent or discovery fails.
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

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)

  # SEC NOTE (RESOLVED by story scope-admin-claim-to-path, 2026-07-02 — was an accepted
  # MEDIUM risk from bugfix-unify-admin-matrix-oidc-identity + bugfix-nested-oidc-claim-
  # support, both 2026-07-01):
  # `admin_oidc_scope/0` folds the Matrix flow's extra scopes (e.g. `profile`) into the
  # admin OIDC request, so claims like `name`/`preferred_username` can appear in the
  # admin session's claims map where they never did before. The OLD `admin_claim?/1`
  # scanned ALL claim values regardless of key/path — a non-admin who could self-set such
  # a claim at the IdP (common on some connectors) could set it (or a NESTED sub-value,
  # e.g. under `resource_access.<client>.*` or a nested profile/address claim) to the
  # admin marker value and be misclassified as admin.
  #
  # FIX: the Bootstrap Wizard now persists the admin-group claim's dot-PATH
  # (`admin_group_claim_path`, e.g. `"realm_access.roles"` or a flat `"groups"`)
  # alongside its VALUE (`admin_group_claim`). When a path is configured, the gate
  # resolves ONLY that path via `Nebu.Web.OidcClaims.claim_at_path_matches?/3` — a hit
  # anywhere else in the claims tree no longer counts. This is NOT a claim-key denylist
  # (which code-review cycle 2 MAJOR M2, bugfix-unify-admin-matrix-oidc-identity,
  # rejected as unsafe): it is an allowlist of exactly the ONE path the operator
  # themselves selected during bootstrap, so a legitimately-configured admin_group_claim
  # can never be silently broken by it.
  #
  # FALLBACK (AC3.2): a deployment bootstrapped BEFORE this story shipped has no
  # `admin_group_claim_path` in `server_config` — falling back to the old any-key scan
  # for those deployments is not a regression (it is exactly today's behavior, unchanged)
  # and avoids locking out an existing admin whose config predates path tracking. This
  # fallback is UNREACHABLE for any bootstrap completed AFTER this story shipped:
  # `bootstrap_confirm_claim/2` now REJECTS a bootstrap-completion POST that omits a
  # verified claim path (code-review MAJOR M1 fix, 2026-07-02) instead of silently
  # persisting a path-less config — bootstrap runs exactly once, so a fresh instance can
  # never end up on this branch. AC3.3: the fallback branch logs at INFO (no PII) so
  # operators of a genuinely pre-story deployment can see that a re-bootstrap / claim
  # re-selection would harden the gate.
  @doc """
  True when the configured admin group claim is present in the OIDC claims.

  When `admin_group_claim_path` is configured (bootstrapped by this story or later), the
  check is PATH-scoped: `target` must appear at that exact dot-path, not anywhere else in
  the claims tree (closes the any-key-value-scan risk, see SEC NOTE above).

  When no path is configured (pre-existing deployment bootstrapped before this story),
  falls back to the legacy any-key recursive scan across the whole claims tree — parity
  with `auth.MatchesAdminGroupClaim` (Go) and unchanged pre-story behavior.
  """
  def admin_claim?(claims) when is_map(claims) do
    target = admin_group_claim()

    case admin_group_claim_path() do
      path when is_binary(path) and path != "" ->
        Nebu.Web.OidcClaims.claim_at_path_matches?(claims, path, target)

      _ ->
        Logger.info(
          "admin gate: admin_group_claim_path not configured — falling back to any-key " <>
            "claim-value scan; re-run the bootstrap claim selection to harden this check"
        )

        Nebu.Web.OidcClaims.claim_value_matches?(claims, target)
    end
  end

  def admin_claim?(_), do: false

  # A session with no recorded expiry (legacy/pre-go-removal session) is treated as
  # live for backward-compat; a recorded expiry is enforced.
  defp session_live?(%{"session_exp" => exp}) when is_integer(exp),
    do: System.system_time(:second) < exp

  defp session_live?(_), do: true

  # ── LiveView on_mount admin gate (AC3) ─────────────────────────────────────────

  @doc """
  LiveView `on_mount` hook. `{Nebu.Admin.Auth, :require_admin}` halts a mount when
  the session has no admin operator, redirecting to `/admin/login`. An authenticated
  admin proceeds with `current_user` assigned to the socket.

  ## admin-liveview-session-refresh (AC1/AC2)

  `on_mount` runs on every LiveView mount/reconnect but is NOT itself the place that
  performs the actual OIDC token-endpoint refresh: it has no HTTP response to attach
  a refreshed `Set-Cookie` to (a LiveView socket handshake predates any writable
  response), so calling the token-endpoint exchange here would refresh the IdP-side
  token without ever being able to persist the rotated refresh token back into the
  signed session cookie — the next real HTTP round-trip would silently discard it.
  That HTTP round-trip (the client-side keepalive heartbeat hitting `GET
  /admin/keepalive`, AC3/AC4) is what actually drives `fetch_current_user/2`'s
  existing refresh leg and persists the result.

  What `on_mount` DOES do differently now: when the stored `session_exp` has already
  elapsed but the session is still `refreshable?/2` — a DECRYPTABLE (decryptable is
  NOT the same as still-valid/unrevoked at the IdP) OIDC refresh token is present
  AND the independent `refresh_grace_exp` bound has not yet passed — it treats the
  operator as still-refreshable rather than immediately logged-out — the mount
  proceeds (`{:cont, socket}`) instead of halting, so an operator who has been idling
  on an open LiveView tab is not force-logged-out purely because `id_token.exp`
  elapsed while no HTTP request happened to run in between. This relies on the
  keepalive heartbeat (AC3/AC4) to keep actually refreshing the underlying HTTP
  session (and advancing `refresh_grace_exp`) before/around this point; `on_mount`
  itself never talks to the token endpoint and never rotates/persists the refresh
  token or writes `refresh_grace_exp`. See the SECURITY note on `refreshable?/2` for
  the exact bound this enforces (admin-liveview-session-refresh HIGH fix,
  2026-07-01): decryptability alone is no longer sufficient — a severed heartbeat
  causes `refresh_grace_exp` to lapse within `@refresh_grace_seconds` of the last
  successful refresh, at which point `refreshable?/2` returns false and this branch
  falls through to the halt+redirect below, same as the pre-fix `session_live?`-only
  path.
  """
  def on_mount(:require_admin, _params, session, socket) do
    completed = bootstrap_completed?()

    case session["current_user"] do
      %{"admin" => true} = user ->
        if session_live?(user) or refreshable?(session, user) do
          mount_admin(socket, user, completed)
        else
          # Session past its capped expiry, no usable refresh token → treat as
          # logged out (re-auth required).
          {:halt, redirect(socket, to: "/admin/login")}
        end

      _ ->
        # Unauthenticated (or non-admin) mount.
        #
        # The bootstrap wizard is now a plain HTTP controller (BootstrapController,
        # fix-bootstrap-wizard-liveview-bugs) — it is not a LiveView anymore.
        # All LiveViews require authentication:
        #   * bootstrap incomplete → funnel to /admin/bootstrap (plain HTTP, no gate)
        #   * bootstrap complete   → funnel to /admin/login
        if completed do
          {:halt, redirect(socket, to: "/admin/login")}
        else
          {:halt, redirect(socket, to: "/admin/bootstrap")}
        end
    end
  end

  defp mount_admin(socket, user, completed) do
    socket =
      Phoenix.Component.assign(socket,
        current_user: user,
        bootstrap_completed: completed
      )

    # Bootstrap gate (Go parity): an instance that has not finished the bootstrap
    # wizard funnels EVERY LiveView into /admin/bootstrap until setup is done.
    # The wizard itself is now a plain HTTP controller (BootstrapController) and
    # is no longer a LiveView — so all LiveViews here require a completed bootstrap.
    if not completed do
      {:halt, redirect(socket, to: "/admin/bootstrap")}
    else
      {:cont, socket}
    end
  end

  # AC1/AC2: true when the session carries a stored OIDC refresh token that at least
  # decrypts cleanly (i.e. was legitimately written by this server, not corrupt/
  # forged) AND the independent `refresh_grace_exp` bound has not yet passed.
  # Deliberately does NOT call the token endpoint here — see the on_mount doc: this
  # LiveView lifecycle path has no HTTP response to persist a rotated refresh token
  # into, so the actual refresh stays exclusively on the HTTP path
  # (`fetch_current_user/2`, triggered by the keepalive heartbeat AC3/AC4). This only
  # grants the mount a grace window on the assumption that the keepalive heartbeat is
  # (or was recently) doing the real refresh work on the underlying HTTP session.
  #
  # SECURITY (admin-liveview-session-refresh HIGH fix, Kassandra security review
  # 2026-07-01 — supersedes the code-review cycle 1 MINOR-1 SEC NOTE below):
  # decryptability is NECESSARY but NO LONGER SUFFICIENT. Both conditions are
  # required:
  #
  #   1. `SecretBox.decrypt(enc_rt)` succeeds (was legitimately written by this
  #      server, not corrupt/forged) — as before.
  #   2. `now <= refresh_grace_exp` — a FIXED, bounded timestamp written into the
  #      session at login and on every successful HTTP-path refresh (see
  #      `put_current_user/2` and `@refresh_grace_seconds`). This is the
  #      INDEPENDENT, non-bypassable outer bound: it is NOT tied to RT-blob
  #      decryptability (which never expires — SecretBox/AES-256-GCM has no time
  #      component) and it is NOT extended just because the LiveView socket
  #      reconnects (a reconnect only ever READS `refresh_grace_exp`, on_mount never
  #      writes it).
  #
  # Previously (pre-fix) condition 1 ALONE was treated as sufficient, which meant a
  # revoked-but-still-logged-in admin whose heartbeat was severed (JS disabled,
  # `/admin/keepalive` blocked, throttled/backgrounded tab) could keep an open
  # LiveView socket (Dashboard/AuditLog) alive INDEFINITELY across reconnects — the
  # RT blob decrypts forever, so `refreshable?/1` never flipped to false, bypassing
  # the only other server-side bound (`session_exp` via `session_live?/1`). Requiring
  # `now <= refresh_grace_exp` closes that gap: once the heartbeat stops successfully
  # refreshing the session, `refresh_grace_exp` stops advancing and lapses within
  # `@refresh_grace_seconds` of the last successful refresh — `refreshable?/2` then
  # returns false regardless of whether the RT blob still decrypts, and `on_mount`
  # halts + redirects exactly like the pre-fix `session_live?`-only path did.
  #
  # A HEALTHY heartbeat (the intended, documented use case — AC2) keeps
  # `refresh_grace_exp` extending forward in small increments on every successful
  # refresh, so an idle-but-open LiveView tab still survives past `id_token.exp`
  # indefinitely as designed; only a SEVERED heartbeat lets the bound lapse.
  #
  # Real IdP-side validity is (still) enforced by the separate keepalive-heartbeat-
  # driven HTTP path: `app.js` `SessionKeepalive` polls `GET /admin/keepalive` every
  # 60s → `fetch_current_user/2` → `maybe_refresh_session/2` →
  # `refresh_admin_session/1`, which performs the actual `grant_type=refresh_token`
  # exchange against the IdP and DOES log the operator out on failure (expired/
  # revoked RT, admin-gate lost, etc.). `refresh_grace_exp` does not replace that
  # check — it bounds how long `on_mount` may proceed WITHOUT it having run recently.
  defp refreshable?(session, user) do
    now = System.system_time(:second)

    grace_exp = user["refresh_grace_exp"]
    within_grace = is_integer(grace_exp) and now <= grace_exp

    case session[@oidc_rt_session_key] do
      enc_rt when is_binary(enc_rt) and enc_rt != "" ->
        within_grace and match?({:ok, _}, SecretBox.decrypt(enc_rt))

      _ ->
        false
    end
  end

  # ── bootstrap completion gate (ADR-018 inline SQL) ─────────────────────────────

  @sql_bootstrap_completed """
  SELECT value FROM server_config WHERE key = 'bootstrap_completed' LIMIT 1
  """

  @doc false
  # True once the bootstrap wizard has finished (server_config.bootstrap_completed = "true").
  #
  # Honours the SAME injectable `:admin_bootstrap_store` seam that
  # `Nebu.Admin.BootstrapLive` uses (`{:bootstrap_completed?, []}` → `{:ok, bool}`), so
  # the on_mount gate is deterministically testable in the unit suite (where `Nebu.Repo`
  # is not started). When no seam is installed it falls back to the real inline SQL read,
  # which is the production default; with neither seam nor Repo it defaults to true so the
  # gate never spuriously redirects in pure-unit LiveView tests.
  def bootstrap_completed? do
    case bootstrap_store(:bootstrap_completed?, []) do
      {:ok, bool} when is_boolean(bool) ->
        bool

      :default ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_bootstrap_completed, []) do
            # Bootstrapped: the wizard's finish step wrote "true".
            {:ok, %{rows: [["true"]]}} ->
              true

            # Query succeeded but there is no `bootstrap_completed` row (or it is not
            # "true") → a genuinely fresh instance. The wizard MUST be reachable.
            {:ok, _} ->
              false

            # SEC (Kassandra HIGH-1, fix-bootstrap-wizard-unreachable): a DB *error* must
            # NOT be collapsed into "not bootstrapped". Since this fix makes the wizard
            # world-reachable whenever this returns false, a transient query error on a
            # completed instance would otherwise re-open the unauthenticated wizard
            # (→ takeover of OIDC config + admin-group claim). Fail CLOSED: on error
            # assume completed so the gate keeps redirecting unauthenticated mounts to
            # /admin/login. A genuinely fresh instance reaches the {:ok, _} arm above,
            # so this never strands a real bootstrap.
            {:error, _} ->
              true
          end
        else
          true
        end
    end
  end

  # Injectable persistence seam shared with Nebu.Admin.BootstrapLive. Returns the fake's
  # result tuple when a 2-arity function is installed, or `:default` otherwise.
  defp bootstrap_store(op, args) do
    case Application.get_env(:nebu_http, :admin_bootstrap_store) do
      fun when is_function(fun, 2) -> fun.(op, args)
      _ -> :default
    end
  end

  # ── server_config.admin_group_claim (ADR-018 inline SQL) ───────────────────────

  @sql_admin_group_claim """
  SELECT value FROM server_config WHERE key = 'admin_group_claim' LIMIT 1
  """

  defp admin_group_claim do
    # MINOR-2: no defensive `rescue _ ->`. The `running?(Nebu.Repo)` guard covers the
    # Repo-not-started unit path; a real DB error must surface (let-it-crash per
    # CLAUDE.md) rather than be silently masked into the default claim.
    if running?(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_admin_group_claim, []) do
        {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
        _ -> @default_admin_group_claim
      end
    else
      @default_admin_group_claim
    end
  end

  # Story scope-admin-claim-to-path (AC3): the dot-path (e.g. "realm_access.roles", or a
  # flat "groups") the operator selected during bootstrap, persisted alongside the
  # existing admin_group_claim VALUE. `nil` means either an absent config (fresh instance
  # that hasn't completed bootstrap) or a pre-existing deployment bootstrapped before
  # this story shipped -- both are handled by admin_claim?/1's fallback branch (AC3.2).
  #
  # Reuses the SAME :admin_oidc_config_reader test seam admin_config_value/1 (OIDC
  # issuer/client lookups) already honours, rather than inventing a second seam name --
  # one seam covers every server_config key tests need to inject.
  defp admin_group_claim_path, do: admin_config_value("admin_group_claim_path")

  defp running?(name), do: Process.whereis(name) != nil

  # The Matrix server_name (`@localpart:server_name`). Mirrors DashboardLive.server_name/0.
  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  # ── bootstrap draft + config promotion (ADR-018 inline SQL, Go ClaimSelectionHandler) ─
  #
  # Honours the SAME injectable `:admin_bootstrap_store` seam BootstrapLive uses, so the
  # bootstrap OIDC flow is testable without a live Postgres. When no seam is installed the
  # real inline SQL runs against Nebu.Repo. SQL duplication across modules is intentional
  # under ADR-018 (no shared repository layer).

  @sql_load_draft "SELECT key, value FROM bootstrap_draft"
  @sql_put_draft """
  INSERT INTO bootstrap_draft (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """
  @sql_clear_draft "DELETE FROM bootstrap_draft"
  @sql_put_config """
  INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """

  defp load_draft do
    case bootstrap_store(:load_draft, []) do
      {:ok, %{} = draft} ->
        draft

      :default ->
        if running?(Nebu.Repo) do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_draft, []) do
            {:ok, %{rows: rows}} -> Map.new(rows, fn [k, v] -> {k, v} end)
            _ -> %{}
          end
        else
          %{}
        end
    end
  end

  defp put_draft(key, value) do
    case bootstrap_store(:put_draft, [key, value]) do
      :default ->
        if running?(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, @sql_put_draft, [key, value, now_ms()])
        end

      _ ->
        :ok
    end

    :ok
  end

  defp put_config(key, value) do
    case bootstrap_store(:put_config, [key, value]) do
      :default ->
        if running?(Nebu.Repo) do
          Ecto.Adapters.SQL.query(Nebu.Repo, @sql_put_config, [key, value, now_ms()])
        end

      _ ->
        :ok
    end

    :ok
  end

  defp clear_draft do
    case bootstrap_store(:clear_draft, []) do
      :default ->
        if running?(Nebu.Repo), do: Ecto.Adapters.SQL.query(Nebu.Repo, @sql_clear_draft, [])

      _ ->
        :ok
    end

    :ok
  end

  # Promote the draft into server_config + write the chosen admin_group_claim + set
  # bootstrap_completed, then clear the draft. Mirrors Go saveBootstrapConfigTx +
  # saveAdminGroupClaimTx + saveClaimMappingTx + clearDraftTx + completeBootstrapTx.
  # The encrypted oidc_client_secret blob is carried forward unchanged (never decrypted).
  #
  # M1 (atomicity): when the real Repo is running the upserts run inside a single
  # `Ecto.Adapters.SQL.transaction/2` so a mid-flight crash cannot leave a half-promoted
  # config (e.g. bootstrap_completed = "true" but no admin_group_claim, which would brick
  # the gate). The seam/no-Repo path (unit tests) has no transaction boundary and runs the
  # same sequential upserts.
  defp complete_bootstrap(draft, admin_group_claim, admin_group_claim_path) do
    result =
      if not seam_installed?() and running?(Nebu.Repo) do
        # Ecto.Repo.transaction/1 (NOT Ecto.Adapters.SQL.transaction/2, which does not
        # exist) — wrap the sequential upserts so a mid-flight crash cannot leave a
        # half-promoted config. The inline Ecto.Adapters.SQL.query calls inside
        # do_complete_bootstrap run on the transaction's checked-out connection.
        case Nebu.Repo.transaction(fn ->
               case do_complete_bootstrap(draft, admin_group_claim, admin_group_claim_path) do
                 {:error, reason} ->
                   # Roll back the transaction and surface the error to the caller.
                   Nebu.Repo.rollback(reason)

                 :ok ->
                   :ok
               end
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        do_complete_bootstrap(draft, admin_group_claim, admin_group_claim_path)
      end

    # Only trigger cache refresh when the bootstrap actually completed successfully.
    # C-1 (oidc-env-optional-bootstrap cycle-1): after the config is written,
    # refresh OidcConfig and JwksCache so the newly-written OIDC values (issuer,
    # audience, jwks_uri) are immediately visible to OidcPlug on this node. Without
    # this, OidcConfig's ETS cache retains nil values until the next TTL-based
    # refresh, causing every Matrix Bearer token to be rejected with 401 until a
    # process restart.
    #
    # Refresh OidcConfig first (makes issuer/audience/jwks_uri warm in ETS) and
    # then JwksCache (reads the newly-warm jwks_uri to fetch signing keys).
    # Errors in either call are non-fatal for bootstrap completion — they are
    # already logged inside each module and the TTL-based refresh will recover.
    #
    # Test seam: `:bootstrap_cache_refresh_hook` (0-arity fun) is invoked instead
    # when installed; this lets unit tests verify the C-1 refresh path without a
    # live Repo or real OidcConfig/JwksCache GenServers. In production the seam is
    # absent and the Process.whereis guards below run directly.
    if result == :ok do
      case Application.get_env(:nebu_http, :bootstrap_cache_refresh_hook) do
        hook when is_function(hook, 0) ->
          hook.()

        _ ->
          if Process.whereis(Nebu.Web.OidcConfig) != nil do
            Nebu.Web.OidcConfig.refresh()
          end

          if Process.whereis(Nebu.Web.JwksCache) != nil do
            Nebu.Web.JwksCache.refresh()
          end
      end
    end

    result
  end

  # True when the injectable bootstrap store seam is installed (unit tests). The seam owns
  # its own (non-transactional) persistence, so the real-Repo transaction wrapper is skipped.
  defp seam_installed? do
    is_function(Application.get_env(:nebu_http, :admin_bootstrap_store), 2)
  end

  defp do_complete_bootstrap(draft, admin_group_claim, admin_group_claim_path) do
    # MINOR-1 (cycle-2): guard against completing bootstrap without an OIDC audience.
    # A missing audience means OidcPlug fails closed permanently (all Bearer tokens
    # rejected with 401 M_UNKNOWN_TOKEN). Fail here rather than silently creating a
    # broken instance. oidc-bootstrap-only-config (ADR-022): the audience comes solely
    # from the wizard draft — there is no NEBU_OIDC_AUDIENCE env fallback.
    audience_in_draft = is_binary(draft["oidc_audience"]) and draft["oidc_audience"] != ""

    if not audience_in_draft do
      {:error, :audience_required}
    else
      # ADR-022: promote the wizard-configured OIDC fields (issuer, single client
      # id/secret, audience, jwks_uri, claim mappings) into server_config — the single
      # source of truth read by OidcPlug / SsoLogin / Admin.Auth.
      keys = ~w(instance_name oidc_issuer oidc_client_id oidc_client_secret
                oidc_audience oidc_jwks_uri
                oidc_user_id_claim oidc_displayname_claim oidc_email_claim)

      # Only promote keys with a non-empty draft value. An empty string is truthy in
      # Elixir, so a bare `if draft[key]` would overwrite a sensibly-seeded default (e.g.
      # the migration's oidc_user_id_claim='name') with "", which then makes login fall
      # back to the opaque `sub` localpart.
      Enum.each(keys, fn key ->
        case draft[key] do
          v when is_binary(v) and v != "" -> put_config(key, v)
          _ -> :ok
        end
      end)

      # Story oidc-refresh-mode-config (AC4): promote the operator's chosen refresh modes.
      # SECURITY: validate to the offline|online enum before writing — an empty/invalid
      # draft value must NOT overwrite the client's default (no scope injection via
      # server_config). An out-of-enum value is simply not promoted (the live default
      # then applies: Matrix=offline / Admin=online).
      Enum.each(~w(matrix_oidc_refresh_mode admin_oidc_refresh_mode), fn key ->
        case draft[key] do
          v when v in ["offline", "online"] -> put_config(key, v)
          _ -> :ok
        end
      end)

      # Story configurable-oidc-scopes (AC6): promote the operator's chosen OIDC extra scopes.
      # SECURITY: validate via the ONE scope validator (story centralize-scope-resolution,
      # AC1/AC5 — Nebu.Web.OidcScopes.validate_scope_string/1) before writing. An invalid
      # draft value is silently skipped (not promoted) so injection via a tampered draft
      # cannot reach server_config.
      Enum.each(~w(matrix_oidc_extra_scopes admin_oidc_extra_scopes), fn key ->
        case draft[key] do
          v when is_binary(v) and v != "" ->
            case Nebu.Web.OidcScopes.validate_scope_string(v) do
              :ok ->
                put_config(key, v)

              {:error, _msg} ->
                Logger.warning("configurable-oidc-scopes: skipping #{key} promotion — invalid scope token in draft value: #{inspect(v)}")
            end

          _ ->
            :ok
        end
      end)

      put_config("admin_group_claim", admin_group_claim)

      # scope-admin-claim-to-path (AC2/AC3): persist the claim's dot-PATH alongside its
      # value. `bootstrap_confirm_claim/2` (code-review MAJOR M1 fix) now REJECTS the
      # request before this function is ever called when no path was submitted, so
      # `admin_group_claim_path` is guaranteed non-nil/non-empty on every call reached
      # from that guarded path. This guard is defensive belt-and-suspenders for any other
      # (e.g. future or test-only) caller of do_complete_bootstrap/3 that might not go
      # through that gate — it must never silently persist an empty-string path.
      if is_binary(admin_group_claim_path) and admin_group_claim_path != "" do
        put_config("admin_group_claim_path", admin_group_claim_path)
      end

      put_config("bootstrap_completed", "true")
      clear_draft()
      :ok
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  # ── claim-selection page (Go parity: extractDiscoveredClaims + bootstrap-claims tmpl) ─
  #
  # Renders the verified token's string / string-list claim VALUES as radio options the
  # operator picks from. SEC: every claim key/value is HTML-escaped (Phoenix.HTML) — the
  # token is attacker-influenceable (it comes from the IdP), so an unescaped value could
  # inject markup into this server-rendered page.

  @doc """
  Flattens an OIDC claims map into `{key, value}` pairs selectable in the Bootstrap
  Wizard's claim-picker UI (`select_claim_html/1`). Descends recursively through
  arbitrary nesting so IdP-shaped claims such as Keycloak's `realm_access.roles` or
  `resource_access.<client>.roles` are surfaced too, not just flat Dex-style claims.
  Nested entries use a dot-path key (e.g. `"realm_access.roles"`) so the operator can
  see where each discovered value came from; flat claims keep their original bare key
  exactly as before (backward compatible with existing callers/tests).
  """
  def extract_discovered_claims(claims) when is_map(claims) do
    claims
    |> Nebu.Web.OidcClaims.flatten_discovered_claims(nil)
    |> Enum.uniq()
  end

  # HTML-escape a value (the token is attacker-influenceable — escape every interpolation).
  defp esc(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp select_claim_html(claims) do
    options =
      claims
      |> extract_discovered_claims()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{key, value}, idx} ->
        id = "claim-#{idx}"

        # scope-admin-claim-to-path (AC2): each radio submits BOTH the claim value
        # (existing "admin_group_claim" param, unchanged) and its dot-path key (new
        # "admin_group_claim_path" param) via a single JSON-encoded value, decoded by
        # the form-submit handler below into two POST params. Plain HTML has no way
        # to bind two independently-named radio groups to one click without JS, so
        # encoding both pieces of data into the ONE value the browser submits is the
        # standard no-JS-required technique. `key` is `nil` for a top-level bare claim
        # with no discoverable dot-path (extract_discovered_claims/1 never produces a
        # nil key today, but the encoding tolerates it defensively).
        encoded = Jason.encode!(%{"value" => value, "path" => key})

        """
        <li>
          <label for="#{esc(id)}" class="cursor-pointer flex items-center gap-2">
            <input type="radio" id="#{esc(id)}" name="admin_group_claim_choice" value="#{esc(encoded)}" class="radio" />
            <span><code>#{esc(key)}</code>: #{esc(value)}</span>
          </label>
        </li>
        """
      end)

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="nebu">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Select admin group claim · Nebu Admin</title>
        <link rel="stylesheet" href="/admin/static/assets/app.css" />
      </head>
      <body class="bg-base-100 text-base-content" data-page="bootstrap-select-claim">
        <main role="main" class="min-h-screen flex items-center justify-center p-6">
          <form method="post" action="/admin/bootstrap/select-claim" class="card bg-base-200 shadow p-8 max-w-lg w-full">
            <input type="hidden" name="_csrf_token" value="#{esc(Plug.CSRFProtection.get_csrf_token())}" />
            <h1 class="text-xl font-bold mb-2">Bootstrap Setup</h1>
            <p class="mb-4 text-base-content/70">
              Select the claim value that identifies an instance administrator.
              These are the discovered OIDC claims from your account.
            </p>
            <ul class="mb-6 space-y-2">
              #{options}
            </ul>
            <button type="submit" class="btn btn-primary w-full" role="button">Confirm Admin Claim</button>
          </form>
        </main>
      </body>
    </html>
    """
  end
end
