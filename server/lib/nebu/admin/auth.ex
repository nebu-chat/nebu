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

  @behaviour Plug

  # ── Plug: establish current_user from the signed admin session cookie ──────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, :fetch_current_user), do: fetch_current_user(conn, [])
  def call(conn, _opts), do: fetch_current_user(conn, [])

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
  defp exchange_refresh_token(refresh_token) do
    case Application.get_env(:nebu_http, :admin_oidc_refresh_override) do
      fun when is_function(fun, 1) ->
        fun.(refresh_token)

      _ ->
        with {:ok, cfg} <- oidc_config(nil),
             {:ok, token_endpoint} <- discover(cfg.issuer, "token_endpoint"),
             body =
               URI.encode_query(%{
                 "grant_type" => "refresh_token",
                 "refresh_token" => refresh_token,
                 "client_id" => cfg.client_id
               }),
             {:ok, resp_body} <- token_endpoint_post(token_endpoint, body, cfg),
             {:ok, id_token, new_rt} <- extract_tokens(resp_body),
             {:ok, claims} <- Nebu.Web.Plugs.OidcPlug.verify_token(id_token, audience: cfg.client_id) do
          {:ok, claims, new_rt}
        end
    end
  end

  @doc """
  Stores the authenticated operator into the session after a successful OIDC login.
  `claims` is the verified ID-token claims map. The `admin` flag is derived from the
  configured admin group claim (server_config) just like the Go backend.
  """
  def put_current_user(conn, claims) when is_map(claims) do
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
      "session_exp" => session_expiry(claims)
    }

    conn
    # configure_session(renew: true) rotates the session id on privilege elevation —
    # defence against session fixation (an attacker-planted pre-login session id cannot
    # be reused post-authentication).
    |> configure_session(renew: true)
    |> put_session("current_user", user)
    |> assign(:current_user, user)
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
             # The admin ID token's `aud` is the admin OAuth client_id (not the Matrix
             # audience), so verification overrides the expected aud — every other check
             # (signature/alg/iss/exp/sub) is identical to the Matrix bearer path.
             {:ok, claims} <- Nebu.Web.Plugs.OidcPlug.verify_token(id_token, audience: cfg.client_id) do
          {:ok, claims, refresh_token}
        end
    end
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

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, select_claim_html(claims))
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

  # The set of claim VALUES the operator was actually shown (and is allowed to choose),
  # reconstructed from the server-side stash written by bootstrap_callback/2. An absent or
  # malformed stash yields the empty set, so confirm fails CLOSED (rejects everything).
  defp discovered_claim_values(draft) do
    case draft["bootstrap_claims"] do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, pairs} when is_list(pairs) ->
            for [_k, v] <- pairs, is_binary(v), into: MapSet.new(), do: v

          _ ->
            MapSet.new()
        end

      _ ->
        MapSet.new()
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
    selected = params["admin_group_claim"] || @default_admin_group_claim
    selected = if selected == "", do: @default_admin_group_claim, else: selected
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

      true ->
        case complete_bootstrap(draft, selected) do
          :ok ->
            # Mint the admin session for the just-authenticated operator. The chosen claim
            # is now in server_config, so put_current_user resolves admin == true.
            user = %{
              "sub" => draft["bootstrap_sub"],
              "email" => draft["bootstrap_email"],
              "admin" => true,
              "session_exp" => System.system_time(:second) + SessionConfig.admin_session_ttl_seconds()
            }

            conn
            |> configure_session(renew: true)
            |> put_session("current_user", user)
            |> assign(:current_user, user)
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
      conn |> Phoenix.Controller.redirect(to: "/admin/bootstrap") |> halt()
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

  # Reads the admin OIDC client config. In normal mode it comes from Application env
  # (set in runtime.exs from NEBU_OIDC_* / file-based client-secret). In bootstrap mode
  # the OIDC config has NOT yet been promoted into server_config, so it is read from the
  # bootstrap_draft (Go parity: loadOIDCConfigFromDraft), decrypting the at-rest secret.
  # issuer is shared with OidcPlug. Fails CLOSED when issuer or client_id is absent.
  defp oidc_config("bootstrap") do
    draft = load_draft()
    issuer = draft["oidc_issuer"]
    client_id = draft["oidc_client_id"]
    client_secret = Nebu.Admin.BootstrapLive.decrypt_secret(draft["oidc_client_secret"] || "")
    scope = admin_oidc_scope()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :bootstrap_draft_incomplete}
      not is_binary(client_id) or client_id == "" -> {:error, :bootstrap_draft_incomplete}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret, scope: scope}}
    end
  end

  defp oidc_config(_mode) do
    issuer = Application.get_env(:nebu_http, :oidc_issuer)
    client_id = Application.get_env(:nebu_http, :admin_oidc_client_id)
    client_secret = Application.get_env(:nebu_http, :admin_oidc_client_secret, "")
    scope = admin_oidc_scope()

    cond do
      not is_binary(issuer) or issuer == "" -> {:error, :issuer_not_configured}
      not is_binary(client_id) or client_id == "" -> {:error, :client_id_not_configured}
      true -> {:ok, %{issuer: issuer, client_id: client_id, client_secret: client_secret, scope: scope}}
    end
  end

  # The admin authorization scope. `offline_access` is NO LONGER force-added (story
  # oidc-refresh-mode-config, AC3): it is requested iff the server_config key
  # `admin_oidc_refresh_mode` resolves to "offline". DEFAULT is "online" (no forced
  # offline_access → no special IdP approval needed; on Keycloak a session-bound RT
  # still enables silent refresh). `openid` stays MANDATORY in every mode, and any
  # operator-configured `:admin_oidc_scope` is honoured. The mode is read LIVE so a
  # runtime change via /admin/config applies without a redeploy.
  #
  # Test seam (mirrors OidcClaimCache's :oidc_claim_reader): a 0-arity fun under
  # :admin_oidc_refresh_mode_reader injects the mode; default reads server_config.
  defp admin_oidc_scope do
    configured = Application.get_env(:nebu_http, :admin_oidc_scope, "openid profile email")
    prefix = if admin_refresh_mode() == "offline", do: ["openid", "offline_access"], else: ["openid"]

    configured
    |> String.split(" ", trim: true)
    |> then(&(prefix ++ &1))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  @sql_admin_refresh_mode "SELECT value FROM server_config WHERE key = 'admin_oidc_refresh_mode' LIMIT 1"

  # Resolves the admin refresh mode to the validated enum "offline" | "online".
  # Any value other than "offline" (incl. absent / junk) collapses to the "online"
  # default — so a stray server_config value can never inject an arbitrary scope.
  defp admin_refresh_mode do
    reader = Application.get_env(:nebu_http, :admin_oidc_refresh_mode_reader, &default_admin_refresh_mode/0)

    case reader.() do
      "offline" -> "offline"
      _ -> "online"
    end
  end

  defp default_admin_refresh_mode do
    if running?(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_admin_refresh_mode, []) do
        {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> value
        _ -> "online"
      end
    else
      "online"
    end
  end

  # The redirect_uri MUST be a fixed, server-controlled value registered with the IdP —
  # it is NOT derived from request headers (Host/X-Forwarded-*), which an attacker could
  # spoof to redirect the auth code elsewhere. Configured via NEBU_ADMIN_OIDC_REDIRECT_URI.
  defp redirect_uri do
    Application.get_env(:nebu_http, :admin_oidc_redirect_uri, "http://localhost:8008/admin/callback")
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

  @doc """
  True when the configured admin group claim is present anywhere in the OIDC claims.
  Parity with `auth.MatchesAdminGroupClaim` (Go): checks string and string-list claims.
  """
  def admin_claim?(claims) when is_map(claims) do
    target = admin_group_claim()

    Enum.any?(claims, fn {_k, v} ->
      case v do
        ^target when is_binary(target) -> true
        list when is_list(list) -> target in list
        _ -> false
      end
    end)
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
  """
  def on_mount(:require_admin, _params, session, socket) do
    completed = bootstrap_completed?()

    case session["current_user"] do
      %{"admin" => true} = user ->
        if session_live?(user) do
          socket =
            Phoenix.Component.assign(socket,
              current_user: user,
              bootstrap_completed: completed
            )

          # Bootstrap gate (Go parity): an instance that has not finished the bootstrap
          # wizard funnels EVERY admin page into /admin/bootstrap until setup is done.
          if not completed and socket.view != Nebu.Admin.BootstrapLive do
            {:halt, redirect(socket, to: "/admin/bootstrap")}
          else
            {:cont, socket}
          end
        else
          # Session past its capped expiry → treat as logged out (re-auth required).
          {:halt, redirect(socket, to: "/admin/login")}
        end

      _ ->
        # Unauthenticated (or non-admin) mount. The bootstrap deadlock fix
        # (fix-bootstrap-wizard-unreachable):
        #
        #   * While bootstrap is INCOMPLETE the operator has no way to mint an admin
        #     session yet (OIDC + admin-group claim are written BY the wizard), so the
        #     wizard must be reachable unauthenticated:
        #       - BootstrapLive       → {:cont, _} (AC1, wizard renders unauthenticated)
        #       - any other admin view → funnel to /admin/bootstrap (AC2, not /login)
        #
        #   * Once bootstrap is COMPLETE the wizard is admin-gated again — it can
        #     re-write OIDC/admin-claim config, so it must NOT stay world-reachable
        #     (AC3). Every unauthenticated mount then redirects to /admin/login.
        cond do
          completed ->
            {:halt, redirect(socket, to: "/admin/login")}

          socket.view == Nebu.Admin.BootstrapLive ->
            {:cont,
             Phoenix.Component.assign(socket, current_user: nil, bootstrap_completed: false)}

          true ->
            {:halt, redirect(socket, to: "/admin/bootstrap")}
        end
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
  defp complete_bootstrap(draft, admin_group_claim) do
    result =
      if not seam_installed?() and running?(Nebu.Repo) do
        # Ecto.Repo.transaction/1 (NOT Ecto.Adapters.SQL.transaction/2, which does not
        # exist) — wrap the sequential upserts so a mid-flight crash cannot leave a
        # half-promoted config. The inline Ecto.Adapters.SQL.query calls inside
        # do_complete_bootstrap run on the transaction's checked-out connection.
        case Nebu.Repo.transaction(fn ->
               case do_complete_bootstrap(draft, admin_group_claim) do
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
        do_complete_bootstrap(draft, admin_group_claim)
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

  defp do_complete_bootstrap(draft, admin_group_claim) do
    # MINOR-1 (cycle-2): guard against completing bootstrap without an OIDC audience.
    # A missing audience means OidcPlug fails closed permanently (all Bearer tokens
    # rejected with 401 M_UNKNOWN_TOKEN). Fail here rather than silently creating a
    # broken instance. The audience is valid if either the draft or the NEBU_OIDC_AUDIENCE
    # env var (via Application env, set by runtime.exs from NEBU_OIDC_AUDIENCE) provides
    # a non-empty value.
    audience_in_draft = is_binary(draft["oidc_audience"]) and draft["oidc_audience"] != ""
    env_audience = Application.get_env(:nebu_http, :oidc_audience)
    audience_in_env = is_binary(env_audience) and env_audience != ""

    if not audience_in_draft and not audience_in_env do
      {:error, :audience_required}
    else
      # oidc-env-optional-bootstrap (AC4): include oidc_audience and oidc_jwks_uri
      # in the promoted keys so the Bootstrap Wizard can configure them alongside
      # the other OIDC fields. oidc_jwks_uri is needed for C-2 (bootstrap-wizard
      # deployments where NEBU_OIDC_JWKS_URI is not set as an env var).
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

      put_config("admin_group_claim", admin_group_claim)
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

  @doc false
  def extract_discovered_claims(claims) when is_map(claims) do
    claims
    |> Enum.flat_map(fn {k, v} ->
      case v do
        s when is_binary(s) and s != "" -> [{k, s}]
        list when is_list(list) -> for item <- list, is_binary(item) and item != "", do: {k, item}
        _ -> []
      end
    end)
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

        """
        <li>
          <label for="#{esc(id)}" class="cursor-pointer flex items-center gap-2">
            <input type="radio" id="#{esc(id)}" name="admin_group_claim" value="#{esc(value)}" class="radio" />
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
