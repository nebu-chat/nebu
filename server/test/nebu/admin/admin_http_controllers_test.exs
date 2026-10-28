defmodule Nebu.Admin.HttpControllersTest do
  @moduledoc """
  RED-phase ATDD acceptance tests for the `admin-liveview-to-http` story.

  Story: Convert all pure CRUD admin LiveViews to plain HTTP GET/POST controllers
  so that corporate firewalls that block WebSockets can still administer a Nebu instance.

  ## What is tested here

  All 12 acceptance tests from the story's "Acceptance Tests" section, mapped 1:1
  to ExUnit test cases using Phoenix.ConnTest / Plug.Test against Nebu.Admin.Endpoint.

  NO Phoenix.LiveViewTest is used — the converted routes are dead-controller routes
  and must not require a WebSocket upgrade.

  ## Why these MUST FAIL NOW (RED)

  Every admin CRUD route is currently wired as a `live/3` inside `live_session :admin`.
  The corresponding controller modules do NOT exist:

    * Nebu.Admin.UsersController
    * Nebu.Admin.RoomsController
    * Nebu.Admin.SpacesController
    * Nebu.Admin.ComplianceController
    * Nebu.Admin.ClaimMappingController
    * Nebu.Admin.RoleMappingController

  A GET/POST to any of the converted URLs will return 404 (no matching route) until
  the dev step replaces the `live/3` entries with `get/3` + `post/3` + `delete/3` routes
  and creates the controller modules.

  ## Auth strategy

  All protected routes require an admin session. The pattern mirrors
  `Nebu.Admin.BootstrapConfirmHttpTest` (the only other Plug.Test-level admin test):
  we build a signed session cookie via `build_admin_conn/0` that goes through the real
  endpoint session plug, then call Nebu.Admin.Endpoint.call/2 directly.

  For simplicity in the red phase we bypass CSRF on mutation tests (the :admin router's
  `protect_from_forgery` uses `:except` or we call via the same conn that saw the CSRF
  token). The story AC7 note says Plug.MethodOverride is already present — `_method=DELETE`
  is tested directly.

  ## Test seams (app-env injectable boundaries — ADR-018)

  Following the established project pattern (see rooms_live_visibility_test.exs,
  rooms_live_create_archive_test.exs, rooms_live_member_management_test.exs), every DB
  write goes through an injectable seam so no live Postgres is required:

    * :admin_auto_join_writer      — fn(actor, room_id, value) — auto-join toggle
    * :admin_room_visibility_writer — fn(actor, room_id, visibility)
    * :admin_room_archiver          — fn(actor, room_id)
    * :admin_room_unarchiver        — fn(actor, room_id)
    * :admin_member_adder           — fn(room_id, user_id, actor)
    * :admin_member_remover         — fn(room_id, user_id, actor)
    * :admin_bootstrap_store        — see admin_bootstrap_live_test.exs for shape

  GET routes with inline SQL degrade gracefully when Nebu.Repo is not running
  (they return an empty list). No seam needed for reads.

  ## Crash/restart — NOT APPLICABLE

  HTTP controllers are stateless. Persistenz Option C (request-scoped, DB-backed).
  No GenServer state to recover.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  setup do
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    on_exit(fn -> Application.delete_env(:nebu_http, :admin_csrf_bypass) end)
    :ok
  end

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

  @room_id "!general:test.local"
  @space_id "!engineering:test.local"
  @alice "@alice:test.local"
  @admin "@admin:test.local"

  # ── Session helpers ────────────────────────────────────────────────────────────

  # Build a Plug.Conn that carries a signed admin session cookie through the real
  # Nebu.Admin.Endpoint session plug (mirrors BootstrapConfirmHttpTest.conn_with_admin/0).
  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => @admin
    })
    # story admin-config-privileged-forms-sweep: the config POSTs (refresh mode, claim and role mapping) need the strict fetch metadata of a
    # user-clicked submit; the two mapping pages additionally a fresh sign-in marker bound to their page
    |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
    |> put_session("admin_reauth", Nebu.OAuth.TestSupport.fresh_marker("admin-1", 0, "auth_time", mapping_marker_path(method, path)))
  end

  defp mapping_marker_path(_method, path) when path in ["/admin/config/claim-mapping", "/admin/config/role-mapping"], do: path
  defp mapping_marker_path(_method, _path), do: "/admin/config"

  defp build_anon_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn) do
    @endpoint.call(conn, @endpoint.init([]))
  end

  # ── AC1 + AC2: Users page GET renders HTML without WebSocket ──────────────────

  test "AC1/AC2 — GET /admin/users returns 200 HTML with data-page=users, no WS upgrade" do
    # RED: Nebu.Admin.UsersController does not exist yet.
    # The router only has: live "/users", UsersLive, :index
    # A get/3 route to UsersController must replace it for this test to pass.
    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    assert conn.resp_body =~ ~s(data-page="users")

    # No WebSocket upgrade header — confirms pure HTTP response.
    refute get_resp_header(conn, "upgrade") |> List.first() =~ "websocket"
  end

  # ── AC3: Rooms list with status filter ────────────────────────────────────────

  test "AC3 — GET /admin/rooms?status=active returns 200 HTML" do
    # RED: Nebu.Admin.RoomsController does not exist yet.
    conn = build_admin_conn(:get, "/admin/rooms?status=active") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    # The page must render the status filter as a GET query param (no LiveView event).
    assert conn.resp_body =~ "status"
  end

  # ── AC4: Auto-join toggle POST → redirect ─────────────────────────────────────

  test "AC4 — POST /admin/rooms/:id/auto-join calls writer and redirects to /admin/rooms" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_auto_join_writer, fn actor, room_id, _value ->
      send(test_pid, {:auto_join_called, actor, room_id})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_auto_join_writer) end)

    # RED: no POST route /admin/rooms/:room_id/auto-join exists yet.
    conn =
      build_admin_conn(:post, "/admin/rooms/#{URI.encode(@room_id, &URI.char_unreserved?(&1))}/auto-join")
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/rooms"]
    assert_received {:auto_join_called, @admin, _}
  end

  # ── AC5: Visibility save POST → redirect with flash ───────────────────────────

  test "AC5 — POST /admin/rooms/:id/settings with visibility=public redirects with flash" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_room_visibility_writer, fn actor, room_id, visibility ->
      send(test_pid, {:visibility_called, actor, room_id, visibility})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_room_visibility_writer) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    # RED: no POST route /admin/rooms/:room_id/settings exists yet.
    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/settings")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"visibility" => "public"})
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/rooms/#{encoded_id}"]
    assert_received {:visibility_called, @admin, @room_id, "public"}

    # Flash must be populated.
    flash = Phoenix.Flash.get(conn.assigns[:flash] || get_session(conn, "_flash") || %{}, :info)
    refute is_nil(flash)
  end

  # ── AC6: Archive POST → redirect with flash ───────────────────────────────────

  test "AC6 — POST /admin/rooms/:id/archive redirects with 'Room archived' flash" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_room_archiver, fn actor, room_id ->
      send(test_pid, {:archive_called, actor, room_id})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_room_archiver) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    # RED: no POST route /admin/rooms/:room_id/archive exists yet.
    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/archive")
      |> endpoint_call()

    assert conn.status == 302
    assert_received {:archive_called, @admin, @room_id}
  end

  # ── AC7: Add member POST — invalid user_id → 200 re-render with error ─────────

  test "AC7 add-member — invalid Matrix user_id returns 200 with error, no member added" do
    # RED: no POST route /admin/rooms/:room_id/members exists yet.
    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/members")
      |> Map.put(:body_params, %{"user_id" => "not-a-matrix-id"})
      |> endpoint_call()

    # Must re-render the detail page with a validation error (not redirect).
    assert conn.status == 200
    assert conn.resp_body =~ ~r/invalid|Invalid|not a valid/i
  end

  test "AC7 add-member — valid user_id redirects back to room detail" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_member_adder, fn room_id, user_id, actor ->
      send(test_pid, {:add_member_called, room_id, user_id, actor})
      {:ok, "$evt"}
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_member_adder) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    # RED: no POST route /admin/rooms/:room_id/members exists yet.
    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/members")
      |> Map.put(:body_params, %{"user_id" => @alice})
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/rooms/#{encoded_id}"]
    assert_received {:add_member_called, @room_id, @alice, @admin}
  end

  test "AC7 remove-member — DELETE via _method override redirects back to room detail" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_member_remover, fn room_id, user_id, actor ->
      send(test_pid, {:remove_member_called, room_id, user_id, actor})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_member_remover) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))
    encoded_user = URI.encode(@alice, &URI.char_unreserved?(&1))

    # Plug.MethodOverride turns POST + _method=DELETE into a DELETE dispatch.
    # RED: no DELETE route /admin/rooms/:room_id/members/:user_id exists yet.
    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/members/#{encoded_user}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"_method" => "DELETE"})
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/rooms/#{encoded_id}"]
    assert_received {:remove_member_called, @room_id, @alice, @admin}
  end

  # ── AC9: Config page GET ───────────────────────────────────────────────────────

  test "AC9 — GET /admin/config returns 200 HTML (no WS)" do
    # ConfigLive stays as a LiveView in the current design, but the story also
    # requires testing POST /admin/config/refresh-mode as a plain HTTP action.
    # For the GET we verify the page renders over HTTP (the existing ConfigLive does
    # this already, but we assert it here for the story's AC9 coverage).
    # RED: if ConfigLive is converted, Nebu.Admin.ConfigController must exist.
    conn = build_admin_conn(:get, "/admin/config") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
  end

  # ── AC10: Claim Mapping GET renders current values ────────────────────────────

  test "AC10 — GET /admin/config/claim-mapping returns 200 with claim name inputs" do
    # RED: Nebu.Admin.ClaimMappingController does not exist yet.
    # The router only has: live "/config/claim-mapping", ClaimMappingLive, :index
    conn = build_admin_conn(:get, "/admin/config/claim-mapping") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    # Form must contain the three claim name inputs.
    assert conn.resp_body =~ "oidc_user_id_claim"
    assert conn.resp_body =~ "oidc_displayname_claim"
    assert conn.resp_body =~ "oidc_email_claim"
  end

  test "AC10 — POST /admin/config/claim-mapping with empty oidc_user_id_claim shows inline error" do
    # RED: no POST route /admin/config/claim-mapping exists yet.
    conn =
      build_admin_conn(:post, "/admin/config/claim-mapping")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{
        "oidc_user_id_claim" => "",
        "oidc_displayname_claim" => "name",
        "oidc_email_claim" => "email"
      })
      |> endpoint_call()

    # Must re-render (200) with an inline validation error — NOT redirect.
    assert conn.status == 200
    # Role="alert" per AC10 story requirement.
    assert conn.resp_body =~ ~r/role="alert"/
    assert conn.resp_body =~ ~r/must not be empty|empty/i
  end

  # ── AC11: Compliance page GET ──────────────────────────────────────────────────

  test "AC11 — GET /admin/compliance returns 200 HTML with requests table" do
    # RED: Nebu.Admin.ComplianceController does not exist yet.
    # The router only has: live "/compliance", ComplianceLive, :index
    conn = build_admin_conn(:get, "/admin/compliance") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    # Page must contain the compliance requests table structure
    # (empty table renders the "No compliance requests" message per ComplianceLive).
    assert conn.resp_body =~ ~r/compliance|Compliance/
  end

  # ── AC13: Auth gate — non-admin GET redirects to /admin/login ─────────────────

  test "AC13 — unauthenticated GET /admin/users redirects to /admin/login" do
    # RED: currently the route is live/3 which redirects in on_mount.
    # The HTTP controller must implement the same redirect via :require_admin_plug.
    conn = build_anon_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/admin/login"
  end

  test "AC13 — unauthenticated GET /admin/rooms redirects to /admin/login" do
    conn = build_anon_conn(:get, "/admin/rooms") |> endpoint_call()

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/admin/login"
  end

  test "AC13 — unauthenticated GET /admin/compliance redirects to /admin/login" do
    conn = build_anon_conn(:get, "/admin/compliance") |> endpoint_call()

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/admin/login"
  end

  # ── AC14: DashboardLive still mounts over longpoll (LiveView transport intact) ─

  test "AC14 — Endpoint has longpoll transport declared on the admin socket" do
    # Verify that Nebu.Admin.Endpoint exports the socket declaration with longpoll.
    # The socket/3 macro in Phoenix.Endpoint stores transports in the module's
    # __sockets__/0 or via the endpoint config depending on version — we inspect
    # the compiled module attribute to confirm longpoll is wired.
    #
    # This test does NOT require a live WebSocket connection; it validates the
    # compile-time transport registration so the remaining LiveViews (Dashboard,
    # AuditLog, Bootstrap) can fall back to longpoll when WS is blocked.
    #
    # Phoenix.Endpoint.socket/3 stores transports under the :phoenix attribute.
    # We check the endpoint's __socket__/0 or __transports__/0 list.
    #
    # RED: If the endpoint is missing the longpoll key, this assertion fails.
    # The fix is adding `longpoll: [connect_info: [session: @session_options]]`
    # alongside the existing websocket: key on the socket declaration.

    # Confirm Nebu.Admin.Endpoint is loaded.
    assert Code.ensure_loaded?(Nebu.Admin.Endpoint)

    # The endpoint is configured in config/test.exs — we check it compiles cleanly
    # and the longpoll transport option is present in the endpoint's socket config.
    # Phoenix stores socket transports in module attributes set by socket/3 macro.

    # If the endpoint opts don't expose transports directly, we check
    # that the compiled module's endpoint declaration contains longpoll
    # by verifying the socket/3 call emitted the longpoll handler module.
    # This is verified via Phoenix.Socket.Transport.default_transport/2 or by
    # checking the endpoint's __sockets__/0:
    sockets =
      if function_exported?(Nebu.Admin.Endpoint, :__sockets__, 0) do
        Nebu.Admin.Endpoint.__sockets__()
      else
        []
      end

    # Phoenix.Endpoint stores each socket declaration as a tuple:
    # {path, module, [websocket: opts], [longpoll: opts]}
    # OR as a map depending on version. We just assert the keyword
    # list for the admin live socket contains a :longpoll key.
    longpoll_present =
      Enum.any?(sockets, fn
        {"/admin/live", _mod, _ws, lp} when is_list(lp) -> true
        {"/admin/live", _mod, opts} when is_list(opts) -> Keyword.has_key?(opts, :longpoll)
        _ -> false
      end)

    assert longpoll_present,
           "Expected Nebu.Admin.Endpoint to declare longpoll transport on /admin/live socket. " <>
             "Add `longpoll: [connect_info: [session: @session_options]]` to the socket declaration."
  end

  # ── AC8: Spaces analogous to Rooms (spot-check GET) ───────────────────────────

  test "AC8 — GET /admin/spaces returns 200 HTML (analogous to rooms)" do
    # RED: Nebu.Admin.SpacesController does not exist yet.
    conn = build_admin_conn(:get, "/admin/spaces") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
  end

  test "AC8 — GET /admin/spaces/:space_id returns 200 HTML detail page" do
    encoded_id = URI.encode(@space_id, &URI.char_unreserved?(&1))

    # RED: Nebu.Admin.SpacesController.detail/2 does not exist yet.
    conn = build_admin_conn(:get, "/admin/spaces/#{encoded_id}") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
  end

  # ── AC5/Rooms detail: GET /admin/rooms/:id renders visibility form ─────────────

  test "AC5 — GET /admin/rooms/:id returns 200 HTML with visibility form" do
    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    # RED: Nebu.Admin.RoomsController.detail/2 does not exist yet.
    conn = build_admin_conn(:get, "/admin/rooms/#{encoded_id}") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
    # Must contain visibility form controls.
    assert conn.resp_body =~ "visibility"
  end

  # ── AC16: Flash on POST-redirect-GET cycle ─────────────────────────────────────

  test "AC16 — flash is set via put_flash/3 before redirect (not via socket assigns)" do
    # Verify that the archive POST sets a flash message accessible via
    # Phoenix.Flash.get on the redirect response.
    test_pid = self()

    Application.put_env(:nebu_http, :admin_room_archiver, fn _actor, _room_id ->
      send(test_pid, :archive_ok)
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_room_archiver) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/archive")
      |> endpoint_call()

    # The redirect response must carry flash in the session (for GET to display it).
    # Phoenix puts flash into the session before the redirect response is sent.
    assert conn.status == 302
    assert_received :archive_ok

    # Flash in session (standard Phoenix PRG pattern).
    # Phoenix 1.7+ stores flash in the session under "phoenix_flash".
    session = get_session(conn)
    flash = session["phoenix_flash"] || session["_flash"] || %{}
    assert flash != %{}, "Expected flash to be set in session before redirect"
  end

  # ── AC17: Add-member input is plain <input type=text>, no phx-change typeahead ──

  test "AC17 — room detail add-member form uses plain text input, no phx-change" do
    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    conn = build_admin_conn(:get, "/admin/rooms/#{encoded_id}") |> endpoint_call()

    assert conn.status == 200
    # The add-member input MUST be a plain <input type="text"> — no phx-change.
    # Presence of phx-change on the user_id input would fail this assertion.
    refute conn.resp_body =~ ~r/name="user_id"[^>]*phx-change|phx-change[^>]*name="user_id"/
    # The input itself should be present as a plain text input.
    assert conn.resp_body =~ ~r/name="user_id"/
  end

  # ── MAJOR-1 / AC9: POST /admin/config/refresh-mode ────────────────────────────

  test "AC9 — POST /admin/config/refresh-mode with valid value calls writer and redirects" do
    # The writer seam now receives a map of validated server_config changes (the
    # config page persists BOTH matrix_oidc_refresh_mode and admin_oidc_refresh_mode
    # — restored to the bootstrap-wizard contract, oidc-refresh-mode AC5/AC6).
    test_pid = self()

    Application.put_env(:nebu_http, :admin_config_refresh_mode_writer, fn changes ->
      send(test_pid, {:refresh_mode_changes, changes})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_refresh_mode_writer) end)

    conn =
      build_admin_conn(:post, "/admin/config/refresh-mode")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"matrix_oidc_refresh_mode" => "offline"})
      |> endpoint_call()

    assert conn.status == 302
    assert_received {:refresh_mode_changes, %{"matrix_oidc_refresh_mode" => "offline"}}
  end

  test "AC9 — POST /admin/config/refresh-mode with invalid value does NOT persist it" do
    # The guard rejects unknown values per key. A request with only a garbage value
    # produces no valid change, so the writer is never called.
    test_pid = self()

    Application.put_env(:nebu_http, :admin_config_refresh_mode_writer, fn changes ->
      send(test_pid, {:refresh_mode_changes, changes})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_refresh_mode_writer) end)

    conn =
      build_admin_conn(:post, "/admin/config/refresh-mode")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"matrix_oidc_refresh_mode" => "garbage"})
      |> endpoint_call()

    # No valid change → writer not called. Re-render (200) or redirect (302) is fine.
    refute_received {:refresh_mode_changes, _}
    assert conn.status in [200, 302, 400]
  end

  # ── Regression (oidc-refresh-mode AC5/AC6): /admin/config must keep the FULL ──
  # two-selector contract the bootstrap wizard has. The admin-http-refactor
  # (ConfigLive → ConfigController) regressed the page: it dropped the
  # admin_oidc_refresh_mode <select>, renamed the matrix <select> to "refresh_mode",
  # and lost the Dex caveat hint. The e2e admin-config scenario in
  # oidc-refresh-mode.feature asserts the wizard contract on /admin/config, so it
  # broke. These tests pin the restored contract.

  test "REGRESSION — GET /admin/config renders BOTH refresh-mode selects with offline/online options" do
    conn = build_admin_conn(:get, "/admin/config") |> endpoint_call()

    assert conn.status == 200
    body = conn.resp_body

    # Both named selects must exist (e2e selects by name).
    assert body =~ ~s(name="matrix_oidc_refresh_mode"),
           "Matrix refresh-mode <select> missing from /admin/config"
    assert body =~ ~s(name="admin_oidc_refresh_mode"),
           "Admin refresh-mode <select> missing from /admin/config"

    # Each must offer offline + online options.
    assert body =~ ~s(value="offline")
    assert body =~ ~s(value="online")

    # Dex caveat hint must be present (AC6).
    assert body =~ ~r/Dex issues a refresh token only (when|with).*offline_access/i,
           "Dex offline_access caveat hint missing from /admin/config"
  end

  test "REGRESSION — POST /admin/config/refresh-mode persists admin_oidc_refresh_mode" do
    # AC5: the admin client refresh mode must be changeable at runtime via the
    # config page, not only matrix. Pin that the admin key is written.
    test_pid = self()

    Application.put_env(:nebu_http, :admin_config_refresh_mode_writer, fn changes ->
      send(test_pid, {:refresh_mode_changes, changes})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_refresh_mode_writer) end)

    conn =
      build_admin_conn(:post, "/admin/config/refresh-mode")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{
        "matrix_oidc_refresh_mode" => "offline",
        "admin_oidc_refresh_mode" => "offline"
      })
      |> endpoint_call()

    assert conn.status == 302

    assert_received {:refresh_mode_changes, changes}
    assert changes["admin_oidc_refresh_mode"] == "offline"
    assert changes["matrix_oidc_refresh_mode"] == "offline"
  end

  test "REGRESSION — POST /admin/config/refresh-mode rejects garbage values per key" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_config_refresh_mode_writer, fn changes ->
      send(test_pid, {:refresh_mode_changes, changes})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_refresh_mode_writer) end)

    conn =
      build_admin_conn(:post, "/admin/config/refresh-mode")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{
        "matrix_oidc_refresh_mode" => "garbage",
        "admin_oidc_refresh_mode" => "online"
      })
      |> endpoint_call()

    # No valid change to matrix; admin is valid. The writer, if called, must NOT
    # carry the garbage value. Re-render (200) or redirect (302) are both fine as
    # long as garbage never reaches the writer.
    receive do
      {:refresh_mode_changes, changes} ->
        refute Map.has_key?(changes, "matrix_oidc_refresh_mode"),
               "garbage matrix value must not be persisted"
        assert changes["admin_oidc_refresh_mode"] == "online"
    after
      0 -> :ok
    end

    assert conn.status in [200, 302]
  end

  # ── MAJOR-2 / AC12: Converted paths are not served as live/3 routes ────────────

  test "AC12 — converted paths are not served as live/3 routes" do
    # RED: all paths below are currently wired as live/3 inside live_session :admin.
    # After the controller migration they must be plain get/3 / post/3 routes.
    # This test inspects Nebu.Admin.Router.__routes__/0 at compile time.
    # It will fail (compile error or assertion failure) until the router is updated.

    live_paths =
      Nebu.Admin.Router.__routes__()
      |> Enum.filter(fn r -> r.kind == :live end)
      |> Enum.map(& &1.path)

    refute "/users" in live_paths,
           "Expected /users to be a plain HTTP route, not a live/3 route"

    refute "/rooms" in live_paths,
           "Expected /rooms to be a plain HTTP route, not a live/3 route"

    refute "/rooms/:room_id" in live_paths,
           "Expected /rooms/:room_id to be a plain HTTP route, not a live/3 route"

    refute "/spaces" in live_paths,
           "Expected /spaces to be a plain HTTP route, not a live/3 route"

    refute "/spaces/:space_id" in live_paths,
           "Expected /spaces/:space_id to be a plain HTTP route, not a live/3 route"

    refute "/compliance" in live_paths,
           "Expected /compliance to be a plain HTTP route, not a live/3 route"

    refute "/config" in live_paths,
           "Expected /config to be a plain HTTP route, not a live/3 route"

    refute "/config/claim-mapping" in live_paths,
           "Expected /config/claim-mapping to be a plain HTTP route, not a live/3 route"

    refute "/config/role-mapping" in live_paths,
           "Expected /config/role-mapping to be a plain HTTP route, not a live/3 route"
  end

  # ── MAJOR-3 / AC19: CSP header present on admin HTML responses ────────────────

  test "AC19 — GET /admin/users response includes content-security-policy header with connect-src" do
    # RED: the CSP header must be added by a plug in the admin pipeline.
    # At minimum the header must be present and include `connect-src` (value not
    # asserted here — ws: tightening is deferred).
    conn = build_admin_conn(:get, "/admin/users") |> endpoint_call()

    assert conn.status == 200

    csp = get_resp_header(conn, "content-security-policy") |> List.first()

    assert csp != nil,
           "Expected content-security-policy header to be present on /admin/users response"

    assert csp =~ "connect-src",
           "Expected content-security-policy to contain connect-src directive, got: #{inspect(csp)}"
  end

  # ── INFO-3 / AC10: Role Mapping GET ───────────────────────────────────────────

  test "AC10 — GET /admin/config/role-mapping returns 200 HTML" do
    # RED: Nebu.Admin.RoleMappingController does not exist yet.
    # The router only has: live "/config/role-mapping", RoleMappingLive, :index
    conn = build_admin_conn(:get, "/admin/config/role-mapping") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"
  end

  test "AC10 — Role Mapping POST with empty admin_group_claim shows inline error" do
    conn =
      build_admin_conn(:post, "/admin/config/role-mapping")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"admin_group_claim" => ""})
      |> endpoint_call()

    assert conn.status == 200
    assert conn.resp_body =~ ~r/role="alert"/
  end

  # ── INFO-4 / AC6: Unarchive POST mirrors archive ──────────────────────────────

  test "AC6 — POST /admin/rooms/:id/unarchive calls unarchiver and redirects" do
    # RED: no POST route /admin/rooms/:room_id/unarchive exists yet.
    test_pid = self()

    Application.put_env(:nebu_http, :admin_room_unarchiver, fn actor, room_id ->
      send(test_pid, {:unarchive_called, actor, room_id})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_room_unarchiver) end)

    encoded_id = URI.encode(@room_id, &URI.char_unreserved?(&1))

    conn =
      build_admin_conn(:post, "/admin/rooms/#{encoded_id}/unarchive")
      |> endpoint_call()

    assert conn.status == 302
    assert_received {:unarchive_called, @admin, @room_id}
  end
end
