defmodule Nebu.Admin.AdminTokenRefreshTest do
  @moduledoc """
  RED-phase ATDD tests for `admin-oidc-session-refresh`
  (epic: fix-short-oidc-sessions).

  ## The bug

  Operators on the Phoenix LiveView Admin UI are force-logged-out within minutes
  against a Keycloak-backed Nebu instance. Root cause in the current Elixir stack:

    * `Nebu.Admin.Auth.exchange_code/4` → `extract_id_token/1` reads only the
      `id_token`; the OIDC `refresh_token` is discarded (auth.ex:519/554).
    * `Nebu.Admin.Auth.session_expiry/1` caps the admin session at
      `min(id_token.exp, now + 8h)` (auth.ex:111-118). With Keycloak's default
      5-min access-token lifetime, `claims["exp"]` < the 8h cap, so the session
      dies after ~5 min — the 8h cap is dead code and there is **no refresh**.

  The Go Admin UI (Story `9-14-admin-ui-oidc-token-refresh`) solved this: request
  `offline_access`, store the encrypted OIDC refresh token, and silently refresh
  before expiry. This story ports that to the Elixir admin flow.

  ## Why these MUST FAIL before the dev step (RED)

    * `normal_callback/2` does not capture/encrypt the OIDC refresh token — nothing
      writes `admin_oidc_rt` to the session (AC1+AC2).
    * `login_start/2`'s default scope is `"openid profile email"` — no
      `offline_access` (AC1).
    * `fetch_current_user/2` only reads `current_user` and assigns it — it performs
      NO pre-expiry refresh, makes no token-endpoint call, never rotates the RT, and
      never clears/redirects on a failed refresh (AC3, AC5, AC6).

  ## Seams (no live Repo / no network in the unit suite)

    * `:admin_oidc_token_override` — the EXISTING code→token exchange + ID-token
      verify short-circuit (auth.ex:260). This story extends it so it may ALSO yield
      an OIDC refresh token: a 3-tuple `{:ok, claims, refresh_token}` in addition to
      the legacy `{:ok, claims}` (mirrors the Matrix `:matrix_sso_token_override`
      3-tuple extension in `oidc-session-refresh`).
    * `:admin_oidc_refresh_override` — NEW. A 1-arity fun the dev wires into the
      pre-expiry refresh leg of `fetch_current_user/2`. Called with the *decrypted*
      OIDC refresh token, it short-circuits the `grant_type=refresh_token`
      token-endpoint POST + ID-token re-verify, returning
      `{:ok, refreshed_claims, new_refresh_token | nil}` | `{:error, reason}`.
      Mirrors `:admin_oidc_token_override`'s role for the login leg. (Documented in
      the dev report — the dev must add this seam.)
    * `:oidc_metadata_override` — discovery doc (authorization/token endpoints).
    * `:admin_secret_at_rest` — the at-rest key SecretBox derives the AES key from.

  ## Crash/restart — NOT APPLICABLE (Persistenz Option C)

  The login/callback/fetch_current_user legs are stateless request handlers over the
  signed session cookie. The encrypted RT lives in the signed session, not in a
  GenServer. No process state to recover on restart.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.Web.SecretBox

  @issuer "https://keycloak.example.com/realms/nebu"
  @authorization_endpoint "https://keycloak.example.com/realms/nebu/auth"
  @token_endpoint "https://keycloak.example.com/realms/nebu/token"
  @client_id "nebu-admin"
  @at_rest_key "admin-token-refresh-test-internal-secret"

  # The window (seconds) within which fetch_current_user/2 should refresh.
  # The story suggests 120s; the tests place session_exp well inside / outside it.
  @refresh_window 120

  setup do
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :admin_oidc_client_id, @client_id)
    Application.put_env(:nebu_http, :admin_oidc_client_secret, "client-secret")
    Application.put_env(:nebu_http, :admin_oidc_redirect_uri, "http://localhost:8008/admin/callback")
    # SecretBox derives its AES-256 key from this at-rest secret.
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :admin_oidc_client_id,
            :admin_oidc_client_secret,
            :admin_oidc_redirect_uri,
            :admin_secret_at_rest,
            :admin_oidc_scope,
            :oidc_metadata_override,
            :admin_oidc_token_override,
            :admin_oidc_refresh_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  # Pre-fills a valid (normal-mode) login state so the callback's state/nonce checks
  # pass; mirrors what login_start/2 would have written.
  defp with_login_state(conn) do
    put_session(conn, "admin_oidc_login", %{
      "state" => "the-state",
      "verifier" => "the-verifier",
      "nonce" => "the-nonce",
      "exp" => System.system_time(:second) + 600,
      "mode" => nil
    })
  end

  # An admin token (carries the default instance_admin group claim) with the supplied exp.
  defp admin_claims(exp) do
    %{
      "sub" => "kai",
      "email" => "kai@example.com",
      "nonce" => "the-nonce",
      "exp" => exp,
      "groups" => ["instance_admin"]
    }
  end

  # Builds a conn carrying an authenticated admin `current_user` (as put_current_user
  # would have written) plus the encrypted OIDC refresh token under "admin_oidc_rt"
  # (as the callback is expected to store it). No cookie forging — this is the
  # legitimate signed-session helper the other admin tests use.
  defp authed_conn(session_exp, plaintext_rt) do
    user = %{
      "sub" => "kai",
      "email" => "kai@example.com",
      "admin" => true,
      "session_exp" => session_exp
    }

    conn = session_conn(:get, "/admin/dashboard") |> put_session("current_user", user)

    case plaintext_rt do
      nil -> conn
      rt -> put_session(conn, "admin_oidc_rt", SecretBox.encrypt(rt))
    end
  end

  # ── [AC1] admin authorization scope: openid mandatory, offline_access now opt-in ──
  #
  # SUPERSEDED by story oidc-refresh-mode-config (AC3): admin no longer FORCE-adds
  # offline_access. The default refresh mode is now `online` (openid profile email, no
  # offline_access → no special IdP approval; Keycloak's session-bound RT still drives
  # silent refresh). `offline_access` is requested only when admin_oidc_refresh_mode =
  # offline. The mode-driven behaviour is covered by admin_scope_mode_test.exs; here we
  # pin the new DEFAULT (no reader seam / no server_config row → online → no offline_access,
  # openid present).
  test "[AC1] login_start requests openid (default online mode → NO forced offline_access)" do
    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    params = URI.parse(location).query |> URI.decode_query()

    scopes = String.split(params["scope"] || "", " ", trim: true)
    assert "openid" in scopes
    refute "offline_access" in scopes,
           "oidc-refresh-mode-config AC3: admin default is online → offline_access must NOT be force-added (got scope=#{inspect(params["scope"])})"
  end

  # ── [AC1+AC2] callback captures + ENCRYPTS the OIDC refresh token ─────────────────

  test "[AC1+AC2] callback stores the OIDC refresh token AES-GCM-encrypted in the session (round-trips, not plaintext)" do
    plaintext_rt = "keycloak-refresh-token-value-abc123"

    # The dev extends the existing exchange seam to ALSO surface the refresh token:
    # a 3-tuple {:ok, claims, refresh_token}.
    Application.put_env(:nebu_http, :admin_oidc_token_override, fn ->
      {:ok, admin_claims(System.system_time(:second) + 60), plaintext_rt}
    end)

    conn =
      session_conn(:get, "/admin/callback")
      |> with_login_state()
      |> Auth.callback(%{"code" => "auth-code", "state" => "the-state"})

    # Successful normal-mode login lands on the dashboard.
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/dashboard"]

    stored = get_session(conn, "admin_oidc_rt")
    assert is_binary(stored) and stored != "",
           "AC1: the callback MUST capture the OIDC refresh token into the session (admin_oidc_rt)"

    # NEVER plaintext — it must be an encrypted blob that SecretBox round-trips.
    refute stored == plaintext_rt, "AC2: the refresh token MUST NOT be stored in plaintext"
    assert {:ok, ^plaintext_rt} = SecretBox.decrypt(stored),
           "AC2: the stored blob MUST decrypt back to the original refresh token via SecretBox"
  end

  # ── [AC3] fetch_current_user refreshes WITHIN the pre-expiry window ───────────────

  test "[AC3] fetch_current_user silently refreshes when session_exp is inside the window" do
    now = System.system_time(:second)
    # Inside the window: expires in 30s (< @refresh_window). Guard the fixture choice so
    # this test stays meaningful if the window constant is ever re-tuned.
    assert 30 < @refresh_window, "fixture must place session_exp INSIDE the refresh window"
    conn_in = authed_conn(now + 30, "old-refresh-token")

    test_pid = self()

    # The NEW refresh seam: called with the DECRYPTED refresh token, returns fresh
    # claims (advanced exp) + a rotated refresh token.
    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn decrypted_rt ->
      send(test_pid, {:refresh_called, decrypted_rt})
      {:ok, admin_claims(now + 8 * 3600), "rotated-refresh-token"}
    end)

    out = Auth.fetch_current_user(conn_in, [])

    # The decrypted RT (not the encrypted blob) was handed to the exchange.
    assert_received {:refresh_called, "old-refresh-token"}

    # current_user survives and session_exp advanced past the original.
    user = out.assigns.current_user
    assert is_map(user)
    assert user["session_exp"] > now + 30,
           "AC3: session_exp must advance after a successful refresh"
    refute out.halted, "AC3: a successful refresh must NOT redirect the operator"

    # The rotated refresh token replaced the old one (still encrypted, round-trips).
    rotated = get_session(out, "admin_oidc_rt")
    assert {:ok, "rotated-refresh-token"} = SecretBox.decrypt(rotated),
           "AC3: a provider-rotated refresh token must replace the stored one (encrypted)"
  end

  test "[AC3] fetch_current_user does NOT refresh when session_exp is OUTSIDE the window" do
    now = System.system_time(:second)
    # Outside the window: expires in 1h (≫ @refresh_window).
    assert 3600 > @refresh_window, "fixture must place session_exp OUTSIDE the refresh window"
    conn_out = authed_conn(now + 3600, "fresh-refresh-token")

    test_pid = self()

    # If the refresh leg fires unnecessarily, this flags it.
    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _decrypted_rt ->
      send(test_pid, :unexpected_refresh)
      {:ok, admin_claims(now + 8 * 3600), nil}
    end)

    out = Auth.fetch_current_user(conn_out, [])

    refute_received :unexpected_refresh
    assert out.assigns.current_user["session_exp"] == now + 3600,
           "AC3: a session comfortably inside its lifetime must not be refreshed"
    refute out.halted
  end

  # ── [AC5] refresh failure → session cleared + redirect /admin/login (no raise) ─────

  test "[AC5] a failed refresh clears the session and redirects to /admin/login (no raise)" do
    now = System.system_time(:second)
    conn_in = authed_conn(now + 30, "revoked-refresh-token")

    # Provider rejects the RT (revoked / expired / network) → {:error, _}.
    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _rt ->
      {:error, {:token_endpoint_status, 400}}
    end)

    out = Auth.fetch_current_user(conn_in, [])

    assert out.halted, "AC5: a failed refresh must halt the request"
    assert out.status == 302
    assert [loc] = get_resp_header(out, "location")
    assert loc == "/admin/login", "AC5: a failed refresh must redirect to /admin/login"

    # Session cleared — no half-authenticated state left behind.
    assert get_session(out, "current_user") == nil,
           "AC5: the admin session must be cleared on refresh failure"
  end

  test "[AC5] refreshed claims missing the admin-group claim are DENIED" do
    now = System.system_time(:second)
    conn_in = authed_conn(now + 30, "downgraded-refresh-token")

    # The refresh succeeds at the IdP but the operator lost the admin group claim
    # (deactivated / downgraded). The admin gate must be re-evaluated → deny.
    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _rt ->
      refreshed = %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "nonce" => "the-nonce",
        "exp" => now + 8 * 3600,
        "groups" => ["users"]
      }

      {:ok, refreshed, nil}
    end)

    out = Auth.fetch_current_user(conn_in, [])

    assert out.halted
    assert out.status == 302
    assert get_resp_header(out, "location") == ["/admin/login"],
           "AC5: an operator who lost the admin-group claim on refresh must be denied"
    assert get_session(out, "current_user") == nil
  end

  # ── [AC6] no refresh token → unchanged behavior + Logger.warning, no refresh ──────

  test "[AC6] no stored refresh token inside the window → no refresh attempt, session unchanged, warning logged" do
    now = System.system_time(:second)
    # Inside the window but NO refresh token was stored (provider granted no offline_access).
    conn_in = authed_conn(now + 30, nil)

    test_pid = self()

    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _rt ->
      send(test_pid, :unexpected_refresh)
      {:ok, admin_claims(now + 8 * 3600), nil}
    end)

    log =
      capture_log(fn ->
        out = Auth.fetch_current_user(conn_in, [])
        # Unchanged behavior: session preserved, not halted, no redirect.
        refute out.halted, "AC6: with no RT the session lives until exp, no forced logout"
        assert out.assigns.current_user["session_exp"] == now + 30
        send(test_pid, {:result, out})
      end)

    refute_received :unexpected_refresh
    assert_received {:result, _out}

    # Operator-misconfiguration signal.
    assert log =~ "warning" or log =~ "refresh",
           "AC6: a missing refresh token must emit a Logger.warning (operator misconfiguration signal)"
  end

  test "[AC6] backward compat: a session with no RT and no expiry pressure is left untouched" do
    now = System.system_time(:second)
    conn = authed_conn(now + 3600, nil)

    out = Auth.fetch_current_user(conn, [])

    assert out.assigns.current_user["sub"] == "kai"
    refute out.halted
    assert get_session(out, "admin_oidc_rt") == nil
  end

  # ── unauthenticated request — no refresh, no crash (regression guard) ─────────────

  test "fetch_current_user with no current_user assigns nil and does not attempt a refresh" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _rt ->
      send(test_pid, :unexpected_refresh)
      {:ok, %{}, nil}
    end)

    out = session_conn(:get, "/admin/dashboard") |> Auth.fetch_current_user([])

    refute_received :unexpected_refresh
    assert out.assigns.current_user == nil
    refute out.halted
  end
end
