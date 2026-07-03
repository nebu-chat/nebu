defmodule Nebu.Admin.AdminTokenRefreshTest do
  @moduledoc """
  ATDD tests for `admin-oidc-session-refresh` (epic: fix-short-oidc-sessions).

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

  ## What these tests verify (shipped behavior)

    * `normal_callback/2` captures the OIDC refresh token and stores it AES-GCM
      encrypted under `admin_oidc_rt` in the session (AC1+AC2).
    * `login_start/2`'s default scope is mode-driven: `openid` is always present;
      `offline_access` is added only when `admin_oidc_refresh_mode = "offline"`
      (AC1).
    * `fetch_current_user/2` reads `current_user`, and — within the pre-expiry
      window — performs a silent refresh: it makes a token-endpoint call, rotates
      the stored refresh token, and clears the session + redirects to
      `/admin/login` on a failed refresh (AC3, AC5, AC6).

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

  ## Extension: `admin-liveview-session-refresh` (AC1/AC2/AC5)

  Adds tests for the follow-up bug where the silent-refresh mechanism above used to
  never run for an operator who stays on an open admin LiveView (Dashboard/AuditLog —
  Bootstrap is now a plain HTTP controller, not a LiveView) without triggering a new
  HTTP request — `fetch_current_user/2` is an HTTP-only plug, so a persistent WebSocket
  session used to die at `id_token.exp` even with a valid stored refresh token
  (`admin_oidc_refresh_mode = "offline"`). These tests verify the shipped fix. See:

    * `[AC1] ...` — exercises the real `on_mount {Nebu.Admin.Auth, :require_admin}` gate
      and verifies the fix: an idle-LiveView session whose `id_token.exp` has elapsed
      survives (`{:cont, socket}`) as long as a decryptable OIDC refresh token is still
      present in the session (`refreshable?/2`), instead of being force-expired.
    * `[AC2] idle LiveView-only session survives ...` — asserts a LiveView-reachable
      trigger (the story's recommended `GET /admin/keepalive`) drives the EXISTING
      `fetch_current_user/2` refresh leg so the session survives past `id_token.exp`.
    * AC5 (regression) is the untouched pre-existing test suite above/below this
      section — none of it was modified, only extended.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Nebu.Admin.Auth
  alias Nebu.Web.SecretBox

  @endpoint Nebu.Admin.Endpoint

  @issuer "https://keycloak.example.com/realms/nebu"
  @authorization_endpoint "https://keycloak.example.com/realms/nebu/auth"
  @token_endpoint "https://keycloak.example.com/realms/nebu/token"
  @client_id "nebu-admin"
  @at_rest_key "admin-token-refresh-test-internal-secret"

  # The window (seconds) within which fetch_current_user/2 should refresh.
  # The story suggests 120s; the tests place session_exp well inside / outside it.
  @refresh_window 120

  setup do
    # oidc-bootstrap-only-config (ADR-022): issuer via OidcConfig, the single admin
    # OIDC client via the :admin_oidc_config_reader seam, redirect_uri DERIVED from
    # :server_name + :admin_session_secure (no env path).
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    # SecretBox + at-rest client-secret encryption derive their key from this secret.
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override,
            :admin_oidc_token_override,
            :admin_oidc_refresh_override,
            # Belt-and-suspenders: never let the refresh-mode seam bleed to other files.
            :admin_oidc_refresh_mode_reader
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
    # "Default online" must be DETERMINISTIC. In the integration container Nebu.Repo is
    # running and the shared DB may carry a real admin_oidc_refresh_mode row (or a
    # sibling test / file wrote 'offline'), so a live DB read here is racy — that was the
    # AdminTokenRefreshTest:160 flake (expected online, got offline_access). Model the
    # default via the documented reader seam returning nil: admin_refresh_mode/0
    # collapses nil → "online", so offline_access must NOT be added. No DB read, no race;
    # the live config row is never touched. Restore the prior seam in on_exit.
    prev = Application.get_env(:nebu_http, :admin_oidc_refresh_mode_reader)
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> nil end)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:nebu_http, :admin_oidc_refresh_mode_reader)
        v -> Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, v)
      end
    end)

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

  # ── [AC1/AC2] admin-liveview-session-refresh: idle LiveView socket + short-lived ──
  # ── ID token (Keycloak-class IdP) ──────────────────────────────────────────────────
  #
  # Bug (admin-liveview-session-refresh): `maybe_refresh_session/2` lives ONLY in the
  # `fetch_current_user/2` HTTP plug (`:browser` pipeline). The two remaining admin
  # LiveViews (Dashboard/AuditLog — Bootstrap is now a plain HTTP controller, not a
  # LiveView) run over a persistent WebSocket — once `on_mount` has captured
  # `session["current_user"]` at connect time, NOTHING re-runs
  # the refresh leg for the lifetime of that socket. `on_mount`'s only check is
  # `session_live?/1` (`now < session_exp`), which is a pure read — it never attempts a
  # refresh, so an operator who never triggers a fresh HTTP request (no reload, stays on
  # /admin/dashboard) is logged out the instant `session_exp` (== id_token.exp on a
  # short-lived-IdP-token instance) passes, REGARDLESS of `admin_oidc_refresh_mode` or
  # whether a valid refresh token sits in the session.
  #
  # These tests use `Phoenix.LiveViewTest.live_isolated/3` against the REAL
  # `Nebu.Admin.DashboardLive` + its REAL `on_mount {Nebu.Admin.Auth, :require_admin}`
  # hook (no test double for the gate) to reproduce the reported behaviour without a
  # live Keycloak: the "short ID-token lifetime" is simulated purely via the
  # `session_exp` fixture value (test seam per AC1 — no real IdP round-trip).
  describe "[AC1] idle LiveView session survives id_token.exp when a valid RT is stored" do
    test "an open Dashboard LiveView remains mounted past session_exp when a live RT is present" do
      now = System.system_time(:second)

      # Simulates a Keycloak-class IdP: id_token.exp only 90s out (the story's exact
      # test seam), admin_oidc_refresh_mode = "offline", and a VALID (non-expired,
      # non-revoked) OIDC refresh token already stored in the session — exactly the
      # configuration under which the story claims silent refresh should keep the
      # operator logged in.
      # admin-liveview-session-refresh HIGH fix: `refreshable?/2` now ALSO requires
      # `now <= refresh_grace_exp` (an independent, non-bypassable outer bound written
      # at login/refresh time, session_exp + a few minutes — see @refresh_grace_seconds
      # in auth.ex). This fixture models a session that was legitimately established
      # (or last successfully heartbeat-refreshed) recently, so the grace bound is
      # still comfortably in the future at the point on_mount re-checks it below —
      # exactly the HEALTHY-heartbeat case AC1/AC2 cover.
      session = %{
        "current_user" => %{
          "sub" => "kai",
          "email" => "kai@example.com",
          "admin" => true,
          "session_exp" => now + 90,
          "refresh_grace_exp" => now + 90 + 180
        },
        "admin_oidc_rt" => SecretBox.encrypt("a-valid-non-expired-refresh-token")
      }

      # If the refresh override were ever invoked, that would mean SOME refresh path
      # fired on the LiveView socket — it must NOT, because no HTTP round-trip happens
      # for the remainder of this test (that is the whole point of AC1).
      test_pid = self()

      Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn rt ->
        send(test_pid, {:unexpected_refresh_on_socket, rt})
        {:ok, %{"sub" => "kai", "exp" => now + 8 * 3600, "groups" => ["instance_admin"]}, nil}
      end)

      {:ok, view, html} =
        live_isolated(Plug.Test.conn(:get, "/admin/dashboard"), Nebu.Admin.DashboardLive,
          session: session
        )

      # The operator opened the LiveView while the session was still live.
      assert html =~ "Dashboard"

      # The operator "keeps the tab open" for longer than id_token.exp (90s) — model
      # this by advancing the LiveView's own liveness check the same way `on_mount`
      # would on any subsequent socket lifecycle event: re-run the identical
      # `on_mount` gate with a session whose exp has now elapsed relative to "now".
      # (A live_isolated view has no ticking clock of its own inside a unit test, so we
      # drive `on_mount` directly with the SAME session map — this is exactly what a
      # reconnect / any lifecycle re-check does on the shipped implementation.)
      expired_session = put_in(session, ["current_user", "session_exp"], now - 1)

      result =
        Nebu.Admin.Auth.on_mount(
          :require_admin,
          %{},
          expired_session,
          %Phoenix.LiveView.Socket{endpoint: Nebu.Admin.Endpoint}
        )

      # The fix: even though id_token.exp has passed, `on_mount` does NOT immediately
      # treat the operator as logged out. `refreshable?/2` sees the decryptable OIDC
      # refresh token still sitting in the session (admin_oidc_refresh_mode = "offline")
      # and grants the mount a grace window, so the socket stays alive
      # (`{:cont, socket}`) instead of halting/redirecting. `on_mount` itself never talks
      # to the token endpoint or rotates the refresh token — it only decides whether the
      # mount may proceed; the actual token-endpoint refresh is performed by the
      # keepalive-heartbeat-driven HTTP path (AC2/AC3), which is why the override below
      # must NOT be invoked here.
      refute_received {:unexpected_refresh_on_socket, _},
                       "AC1: on_mount must never itself call the refresh override — it has no HTTP " <>
                         "response to persist a rotated refresh token into, so the actual " <>
                         "token-endpoint refresh stays exclusively on the keepalive-heartbeat-driven " <>
                         "HTTP path (fetch_current_user/2); on_mount only grants a grace window based " <>
                         "on refreshable?/2"

      assert match?({:cont, _socket}, result),
             "AC1: the operator's Dashboard LiveView must remain valid after id_token.exp " <>
               "elapses as long as a valid refresh token is present (admin_oidc_refresh_mode = " <>
               "\"offline\") — on_mount grants a grace window via refreshable?/2 instead of " <>
               "unconditionally halting+redirecting to /admin/login, so the operator is not " <>
               "force-logged-out purely because no HTTP round-trip happened to run in between."

      _ = view
    end
  end

  describe "[AC2] idle LiveView-only session survives id_token expiry while a valid RT is present" do
    test "a LiveView-reachable keepalive trigger refreshes the session before session_exp" do
      now = System.system_time(:second)

      # Operator has been sitting on /admin/dashboard (LiveView-only, no reload) since
      # login. The stored id_token/session_exp is about to lapse; a valid RT is present.
      user = %{
        "sub" => "kai",
        "email" => "kai@example.com",
        "admin" => true,
        "session_exp" => now + 5
      }

      conn =
        conn(:get, "/admin/keepalive")
        |> init_test_session(%{})
        |> put_session("current_user", user)
        |> put_session("admin_oidc_rt", SecretBox.encrypt("a-valid-non-expired-refresh-token"))

      test_pid = self()

      Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn rt ->
        send(test_pid, {:refresh_invoked, rt})
        {:ok,
         %{
           "sub" => "kai",
           "email" => "kai@example.com",
           "exp" => now + 8 * 3600,
           "groups" => ["instance_admin"]
         }, "rotated-refresh-token"}
      end)

      # AC3's recommended mechanism: a lightweight, auth-gated GET the browser polls
      # periodically while any admin LiveView tab is open, routed through the SAME
      # :browser pipeline as every other admin route so fetch_current_user/2's existing
      # silent-refresh leg runs unmodified. Nebu.Admin.Router routes "/admin/keepalive"
      # to this pipeline.
      out = Nebu.Admin.Endpoint.call(conn, Nebu.Admin.Endpoint.init([]))

      assert_received {:refresh_invoked, "a-valid-non-expired-refresh-token"},
                       "AC2: an idle-LiveView-reachable keepalive/heartbeat request must trigger " <>
                         "the EXISTING silent-refresh leg (fetch_current_user/2) so the session " <>
                         "survives id_token expiry while the operator never issued a manual " <>
                         "reload"

      refute out.status == 404,
             "AC2: a LiveView-reachable keepalive endpoint must exist and be routed through the " <>
               "admin :browser pipeline"

      refute out.status in [301, 302] and get_resp_header(out, "location") == ["/admin/login"],
             "AC2: the operator must NOT be bounced to /admin/login while a valid refresh token " <>
               "is present and the keepalive fires before session_exp"
    end
  end

  # ── [SEC-HIGH] severed heartbeat + expired refresh_grace_exp → on_mount denies ────
  #
  # Regression test for the HIGH finding from Kassandra's security review
  # (admin-liveview-session-refresh-security-review-2026-07-01, Finding #1): pre-fix,
  # `refreshable?/1` granted `on_mount` an UNBOUNDED grace window purely because the
  # stored OIDC refresh-token blob still decrypted — decryptability never expires
  # (SecretBox/AES-256-GCM has no time component), so a de-provisioned admin whose
  # heartbeat is severed (JS disabled, `/admin/keepalive` blocked, throttled/
  # backgrounded tab) could keep an open LiveView socket (Dashboard/AuditLog) alive
  # INDEFINITELY across reconnects, bypassing the only other server-side bound
  # (`session_exp` via `session_live?/1`).
  #
  # This test drives the SAME `on_mount {Nebu.Admin.Auth, :require_admin}` gate as the
  # AC1 test above, but with the session frozen in the "heartbeat has been severed for
  # a while" state: `session_exp` has elapsed AND the independent `refresh_grace_exp`
  # bound has ALSO already elapsed (no successful HTTP-path refresh happened in the
  # meantime to push it forward) — while the RT blob still decrypts cleanly. Per the
  # fix, decryptability alone must no longer be sufficient: `on_mount` must halt +
  # redirect to /admin/login, exactly like the pre-fix `session_live?`-only path did.
  describe "[SEC-HIGH] on_mount denies access once refresh_grace_exp has elapsed, even with a decryptable RT" do
    test "a severed heartbeat (session_exp AND refresh_grace_exp both elapsed) is denied LiveView access" do
      now = System.system_time(:second)

      # The heartbeat stopped succeeding a while ago: both the id_token-derived
      # session_exp AND the independent refresh_grace_exp bound are already in the
      # past — modelling "the last successful refresh was long enough ago that even
      # the few-minutes grace has run out." The RT blob still decrypts cleanly (it is
      # a legitimately-encrypted blob from this server, exactly like the AC1 fixture)
      # — that is the whole point: decryptability alone must NOT be enough anymore.
      session = %{
        "current_user" => %{
          "sub" => "kai",
          "email" => "kai@example.com",
          "admin" => true,
          "session_exp" => now - 200,
          "refresh_grace_exp" => now - 1
        },
        "admin_oidc_rt" => SecretBox.encrypt("a-decryptable-but-stale-refresh-token")
      }

      # If refreshable?/2 (or anything downstream) ever triggered a real refresh
      # attempt here, that would be a DIFFERENT bug (on_mount performing IdP calls) —
      # it must not fire, and is asserted purely as a sanity guard mirroring the AC1
      # test's own assertion.
      test_pid = self()

      Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn rt ->
        send(test_pid, {:unexpected_refresh_on_socket, rt})
        {:ok, %{"sub" => "kai", "exp" => now + 8 * 3600, "groups" => ["instance_admin"]}, nil}
      end)

      result =
        Nebu.Admin.Auth.on_mount(
          :require_admin,
          %{},
          session,
          %Phoenix.LiveView.Socket{endpoint: Nebu.Admin.Endpoint}
        )

      refute_received {:unexpected_refresh_on_socket, _}

      assert match?({:halt, _socket}, result),
             "SEC-HIGH: once refresh_grace_exp has elapsed (heartbeat severed, no successful " <>
               "HTTP-path refresh in a while), on_mount MUST deny the mount and redirect to " <>
               "/admin/login — decryptability of the stored RT blob alone must NOT be sufficient " <>
               "to grant LiveView access, otherwise a revoked/de-provisioned admin retains " <>
               "indefinite read access to Dashboard/AuditLog merely by not letting the heartbeat run."

      {:halt, socket} = result
      assert {:redirect, %{to: "/admin/login"}} = socket.redirected
    end
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
