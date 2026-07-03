defmodule Nebu.Admin.AdminKeepaliveTest do
  @moduledoc """
  ATDD tests for AC4 of `admin-liveview-session-refresh`.

  ## What is tested

  The story's recommended (AC3) fix mechanism: a minimal `GET /admin/keepalive`
  endpoint that a client-side heartbeat (JS hook) polls periodically while any admin
  LiveView tab is open. Because Phoenix session cookies cannot be set over a
  WebSocket, the only way to re-trigger the existing `fetch_current_user/2` silent
  OIDC-refresh leg (`Nebu.Admin.Auth`, `:browser` pipeline) for an otherwise-idle
  LiveView socket is a genuine HTTP round-trip — this endpoint IS that round-trip.

  AC4 requires the endpoint to:
    1. Live behind the SAME admin auth gate as every other `:browser`-pipeline route
       (no bypass of `fetch_current_user/2` / the admin session check).
    2. Return a minimal response — no sensitive payload, no PII.
    3. Trigger NO business logic beyond the already-existing
       `fetch_current_user/2` refresh-plug behaviour (no new refresh/business logic
       introduced specifically for this endpoint).
    4. Reject unauthenticated callers exactly like any other protected admin route
       (no new anonymous surface).

  ## What these tests verify (shipped behavior)

  `Nebu.Admin.Router` routes `GET /admin/keepalive` through the `:browser` pipeline
  to `Nebu.Admin.KeepaliveController`, a minimal controller that returns a bare
  success response once `fetch_current_user/2` (and its existing silent-refresh leg)
  has run. The tests below verify this end-to-end via the real endpoint/router.

  ## Auth strategy

  Mirrors `Nebu.Admin.HttpControllersTest.build_admin_conn/2` (the established pattern
  for exercising the real `Nebu.Admin.Endpoint` + `:browser` pipeline end-to-end,
  including the real session cookie plug) rather than calling a controller module
  directly — AC4 is specifically about the endpoint sitting behind the pipeline, so the
  test must go through the real router.

  ## Crash/restart — NOT APPLICABLE

  The keepalive endpoint is stateless: it reads the existing signed session cookie and
  (at most) triggers the pre-existing, already-covered `fetch_current_user/2` refresh
  leg. No new GenServer / process state is introduced.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.SecretBox

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)
  @at_rest_key "admin-keepalive-test-internal-secret"

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    # SecretBox derives its AES key from this seam (mirrors admin_token_refresh_test.exs) —
    # needed here because [AC4] business-logic tests encrypt a stored refresh token.
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)
      Application.delete_env(:nebu_http, :admin_oidc_refresh_override)
    end)

    :ok
  end

  # ── Session helpers (mirrors Nebu.Admin.HttpControllersTest) ──────────────────────

  defp build_admin_conn(session_exp) do
    user = %{
      "admin" => true,
      "sub" => "admin-1",
      "email" => "admin@example.com",
      "matrix_user_id" => "@admin:test.local",
      "session_exp" => session_exp
    }

    %{conn(:get, "/admin/keepalive") | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", user)
  end

  defp build_anon_conn do
    %{conn(:get, "/admin/keepalive") | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn) do
    @endpoint.call(conn, @endpoint.init([]))
  end

  # ── [AC4] authenticated keepalive: minimal 2xx/204, no sensitive payload ──────────

  test "[AC4] GET /admin/keepalive as an authenticated admin returns a minimal success response" do
    out =
      build_admin_conn(System.system_time(:second) + 3600)
      |> endpoint_call()

    refute out.status == 404,
           "AC4: GET /admin/keepalive must be a real, routed endpoint"

    assert out.status in [200, 204],
           "AC4: the keepalive endpoint must return a minimal success response (200/204), got #{out.status}"

    # No sensitive payload / PII: the body must not echo back the operator's sub,
    # email, matrix_user_id, or any session/token material.
    body = out.resp_body || ""

    refute body =~ "admin-1"
    refute body =~ "admin@example.com"
    refute body =~ "@admin:test.local"
    refute body =~ "session_exp"

    # A 204 has no body by definition; a 200 must still stay minimal (e.g. "ok" or "").
    assert byte_size(body) < 32,
           "AC4: the keepalive response body must be minimal — no business payload"
  end

  # ── [AC4] same admin auth gate as every other :browser route ──────────────────────

  test "[AC4] GET /admin/keepalive without an admin session is rejected exactly like any other admin route" do
    out = build_anon_conn() |> endpoint_call()

    refute out.status == 404,
           "AC4: the route itself must exist (a 404 here would mean no route, not an auth rejection)"

    # Same gate as every other protected admin route: either a 302 to /admin/login
    # (require_admin's redirect) or a 401/403 — but NEVER a 200/204 success. There must
    # be no bypass of the admin auth gate for this new endpoint.
    refute out.status in [200, 204],
           "AC4: an unauthenticated caller must NOT receive a success response from " <>
             "/admin/keepalive — this endpoint must sit behind the same admin auth gate as " <>
             "every other :browser-pipeline route (no bypass)"

    if out.status in [301, 302] do
      assert get_resp_header(out, "location") == ["/admin/login"],
             "AC4: an unauthenticated keepalive request must redirect to /admin/login, " <>
               "same as require_admin on every other admin route"
    else
      assert out.status in [401, 403]
    end
  end

  test "[AC4] a non-admin authenticated session is rejected the same way as any other admin route" do
    non_admin_user = %{
      "admin" => false,
      "sub" => "user-1",
      "email" => "user@example.com"
    }

    conn =
      %{conn(:get, "/admin/keepalive") | secret_key_base: @secret_key_base}
      |> Nebu.Admin.Endpoint.admin_session([])
      |> fetch_session()
      |> put_session("current_user", non_admin_user)

    out = endpoint_call(conn)

    refute out.status in [200, 204],
           "AC4: a non-admin operator must be rejected by the same require_admin gate as " <>
             "every other admin route — the keepalive endpoint creates no separate, weaker gate"
  end

  # ── [AC4] triggers no business logic beyond the existing fetch_current_user/2 leg ──

  test "[AC4] keepalive triggers the EXISTING silent-refresh leg (no new business logic) when inside the pre-expiry window" do
    test_pid = self()
    now = System.system_time(:second)

    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn rt ->
      send(test_pid, {:refresh_invoked, rt})

      {:ok,
       %{
         "sub" => "admin-1",
         "email" => "admin@example.com",
         "exp" => now + 8 * 3600,
         "groups" => ["instance_admin"]
       }, "rotated-refresh-token"}
    end)

    conn =
      build_admin_conn(now + 30)
      |> put_session("admin_oidc_rt", SecretBox.encrypt("a-valid-non-expired-refresh-token"))

    out = endpoint_call(conn)

    assert_received {:refresh_invoked, "a-valid-non-expired-refresh-token"},
                     "AC4: the keepalive request must run through the SAME :browser pipeline " <>
                       "so the EXISTING fetch_current_user/2 pre-expiry refresh leg fires — " <>
                       "no separate/new refresh mechanism should be introduced for this endpoint"

    refute out.status == 404
  end

  test "[AC4] keepalive with admin_oidc_refresh_mode = online (no refresh token) does not error or attempt a refresh" do
    test_pid = self()
    now = System.system_time(:second)

    # AC "online path unaffected": inside the pre-expiry window but no RT was ever
    # stored (online mode grants no offline_access). The keepalive call must behave
    # exactly like any other admin request in this situation: no crash, no refresh
    # attempt, normal graceful expiry behaviour preserved.
    Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn rt ->
      send(test_pid, {:unexpected_refresh, rt})
      {:error, :should_not_be_called}
    end)

    conn = build_admin_conn(now + 30)

    out = endpoint_call(conn)

    refute_received {:unexpected_refresh, _},
                     "AC4/online-path: keepalive must not attempt a refresh when no refresh " <>
                       "token is stored (admin_oidc_refresh_mode = online) — must degrade " <>
                       "identically to the existing fetch_current_user/2 behaviour"

    refute out.status == 404
  end
end
