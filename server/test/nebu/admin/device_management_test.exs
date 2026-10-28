defmodule Nebu.Admin.DeviceManagementTest do
  @moduledoc """
  RED-phase ATDD acceptance tests for the `device-management` epic, story
  **S4 — Admin UI: per-user device management**.

  Story: operators view / rename / revoke a user's devices from the Phoenix
  LiveView Admin UI. The implementation will add a per-user detail page
  (`GET /admin/users/:user_id`) plus two state-changing POSTs:

    * POST /admin/users/:user_id/devices/:device_id/rename   (rename display name)
    * POST /admin/users/:user_id/devices/:device_id           + _method=DELETE
      (revoke the device: kill its bound session + delete its keys)

  All of these go through the `Nebu.Admin.DevicesController` (does NOT exist yet)
  and the `Nebu.Matrix` facade (ADR-020) — the Admin domain must NOT call
  `Nebu.Matrix.DeviceKeyStore` / `Session.DeviceBinding` directly.

  ## Why these MUST FAIL NOW (RED)

  There is no per-user detail page and no devices controller yet. The router only
  has `get "/users", UsersController, :index`. A request to
  `GET /admin/users/:user_id` (or the rename / delete POSTs) returns 404 (no
  matching route) until the dev step adds the routes + controller + template +
  the `Nebu.Matrix` facade delegations.

  ## Auth strategy / CSRF (mirrors admin_http_controllers_test.exs)

  We build a signed admin-session conn via `build_admin_conn/2` (real endpoint
  session plug) and call `Nebu.Admin.Endpoint.call/2`. CSRF is bypassed for the
  happy-path mutation tests via `:admin_csrf_bypass` (the established Plug.Test
  pattern — see Nebu.Admin.Router.maybe_skip_csrf/2). The dedicated CSRF test
  switches the bypass OFF so it exercises real `protect_from_forgery`.

  ## Test seams (app-env injectable boundaries — ADR-018)

  Following the `:admin_member_adder` / `:admin_member_remover` pattern, every
  device-domain call goes through an injectable seam so no live Postgres / Matrix
  stack is required in the unit suite:

    * :admin_device_lister   — fn(user_id) :: [map()]
    * :admin_device_renamer  — fn(user_id, device_id, display_name) :: :ok | :error
    * :admin_device_deleter  — fn(user_id, device_id) :: :ok

  The dev step wires the controller's default (no-seam) path to
  `Nebu.Matrix.list_user_devices/1` / `Nebu.Matrix.rename_user_device/3` /
  `Nebu.Matrix.delete_user_device/2` (the ADR-020 facade names — adjust to match
  whatever the dev exposes, but it MUST be the facade, not DeviceKeyStore).

  ## Crash/restart — NOT APPLICABLE

  HTTP controllers are stateless (Persistenz Option C — request-scoped, DB-backed).
  No GenServer state to recover.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Compliance.AuditWriter

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-test-secret-key-base!", 2)

  @admin "@admin:test.local"
  @target_user "@alice:test.local"
  @other_user "@bob:test.local"
  @device_id "DEVICEALICE01"
  @other_device "DEVICEBOB99"

  # FakeAuditWriter spies on log/7 by forwarding to the test pid (mirrors
  # admin_member_management_test.exs). Whether the controller calls AuditWriter
  # directly or via a facade, this only fires if the audit row is actually written.
  #
  # NOTE: this nested module MUST be declared BEFORE the `setup` block — Elixir only
  # establishes the lexical alias for a nested `defmodule` at its definition point, so
  # `Application.put_env(:compliance, :audit_writer, FakeAuditWriter)` resolves to this
  # module only when the defmodule precedes the reference (mirrors the ordering in
  # admin_member_management_test.exs). Defined after `setup`, the bare `FakeAuditWriter`
  # would resolve to a non-existent top-level atom and the spy would never fire.
  defmodule FakeAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      test_pid = Application.get_env(:compliance, :__audit_test_pid__)

      if test_pid && Process.alive?(test_pid) do
        send(test_pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      end

      :ok
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    # Allow building admin conns directly without a real browser CSRF token for the
    # happy-path tests. The dedicated CSRF test flips this OFF for its own conn.
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter)
    Application.put_env(:compliance, :__audit_test_pid__, self())

    on_exit(fn ->
      # Restore the global test.exs default (true) rather than deleting it — a bare
      # delete would leave the router's `Application.get_env(..., false)` default in
      # force, leaking `admin_csrf_bypass = false` into every later admin test
      # (e.g. Nebu.Admin.HttpControllersTest), which relies on the global bypass.
      Application.put_env(:nebu_http, :admin_csrf_bypass, true)
      Application.delete_env(:nebu_http, :admin_device_lister)
      Application.delete_env(:nebu_http, :admin_device_renamer)
      Application.delete_env(:nebu_http, :admin_device_deleter)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:compliance, :__audit_test_pid__)
    end)

    :ok
  end

  # ── Session helpers (mirror admin_http_controllers_test.exs) ─────────────────

  defp restore_csrf_bypass(nil), do: Application.delete_env(:nebu_http, :admin_csrf_bypass)
  defp restore_csrf_bypass(val), do: Application.put_env(:nebu_http, :admin_csrf_bypass, val)

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => @admin
    })
    # story admin-forms-gate-sweep: every admin form post needs the strict fetch metadata of a user-clicked submit
    |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
  end

  defp build_anon_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> Nebu.Admin.Endpoint.admin_session([])
    |> fetch_session()
  end

  defp endpoint_call(conn) do
    @endpoint.call(conn, @endpoint.init([]))
  end

  defp enc(id), do: URI.encode(id, &URI.char_unreserved?(&1))

  # ── AC1: device list per user (metadata) ─────────────────────────────────────

  test "AC1 — GET /admin/users/:user_id lists each device with id, display name, last-seen, created" do
    Application.put_env(:nebu_http, :admin_device_lister, fn @target_user ->
      [
        %{
          "device_id" => @device_id,
          "display_name" => "Alice's Laptop",
          "last_seen_ts" => 1_700_000_000_000,
          "last_seen_ip" => "203.0.113.7",
          "created_ts" => 1_699_000_000_000
        }
      ]
    end)

    conn = build_admin_conn(:get, "/admin/users/#{enc(@target_user)}") |> endpoint_call()

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"

    body = conn.resp_body
    # Each AC1 field must be rendered somewhere on the page.
    assert body =~ @device_id, "device_id must be rendered"
    assert body =~ "Alice&#39;s Laptop" or body =~ "Alice's Laptop", "display name must be rendered"
    assert body =~ "203.0.113.7", "last-seen IP must be rendered"

    # The "Created" and "Last seen" cells render via format_ts/1 (UsersHTML),
    # which truncates the BIGINT epoch-millis to seconds and emits an ISO-8601
    # UTC token. Assert the stable date portion of each fixture epoch so the
    # rendered timestamp — not just the IP — is covered:
    #   created_ts 1_699_000_000_000 → "2023-11-03T08:26:40Z" (date: 2023-11-03)
    #   last_seen_ts 1_700_000_000_000 → "2023-11-14T22:13:20Z" (date: 2023-11-14)
    assert body =~ "2023-11-03", "the created timestamp (created_ts) must be rendered as a formatted date"
    assert body =~ "2023-11-14", "a formatted last-seen timestamp (last_seen_ts) must be rendered"
  end

  # ── AC1: empty state ─────────────────────────────────────────────────────────

  test "AC1 — GET /admin/users/:user_id renders an empty state when the user has no devices" do
    Application.put_env(:nebu_http, :admin_device_lister, fn @target_user -> [] end)

    conn = build_admin_conn(:get, "/admin/users/#{enc(@target_user)}") |> endpoint_call()

    assert conn.status == 200
    assert conn.resp_body =~ ~r/no devices|No devices/i
  end

  # ── AC2: rename persists + reflected on reload ───────────────────────────────

  test "AC2 — POST rename calls the (facade) renamer with the route's user_id + device, then redirects" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_device_renamer, fn user_id, device_id, display_name ->
      send(test_pid, {:rename_called, user_id, device_id, display_name})
      :ok
    end)

    conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}/rename")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"display_name" => "Renamed Laptop"})
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/users/#{enc(@target_user)}"]
    # The renamer MUST be called with the user_id FROM THE ROUTE (no IDOR — AC4/sec-2).
    assert_received {:rename_called, @target_user, @device_id, "Renamed Laptop"}
  end

  # ── AC3: revoke/delete → revokes session + removes keys, after confirmation ───

  test "AC3 — DELETE device calls the (facade) deleter with the route's user_id + device, then redirects" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_device_deleter, fn user_id, device_id ->
      send(test_pid, {:delete_called, user_id, device_id})
      :ok
    end)

    # Phoenix dead-view destructive action: POST + _method=DELETE (Plug.MethodOverride).
    conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"_method" => "DELETE"})
      |> endpoint_call()

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/admin/users/#{enc(@target_user)}"]
    assert_received {:delete_called, @target_user, @device_id}
  end

  # AC3: a confirmation step must precede deletion. This page is a DEAD controller
  # render (no LiveView socket), so Phoenix `data-confirm` is NOT honored at runtime.
  #
  # The admin CSP is `script-src 'self'` with NO `'unsafe-inline'` (see
  # Nebu.Admin.Router @csp), so an inline `onsubmit="return confirm(...)"` handler is
  # BLOCKED by the browser and never fires — the form would silently submit without a
  # confirmation (the AC3 E2E regression this story fixes). The CSP-compliant,
  # keyboard-operable confirmation is a `submit`-event listener in the external
  # /admin/static/assets/app.js (allowed by `script-src 'self'`) that calls confirm()
  # using the form's `data-confirm` message. The form therefore MUST:
  #   * NOT carry an inline `onsubmit=` (would be a dead, CSP-blocked handler), and
  #   * carry the `data-form="revoke-device"` + `data-confirm="…"` hooks app.js keys on.
  # Asserting the actual mechanism (not a CSP-blocked inline handler) prevents the
  # previously-shipped unwired affordance from recurring.
  test "AC3 — the revoke form wires a CSP-compliant confirmation hook (no inline onsubmit)" do
    Application.put_env(:nebu_http, :admin_device_lister, fn @target_user ->
      [%{"device_id" => @device_id, "display_name" => "Laptop", "last_seen_ts" => nil, "last_seen_ip" => nil}]
    end)

    conn = build_admin_conn(:get, "/admin/users/#{enc(@target_user)}") |> endpoint_call()

    assert conn.status == 200
    body = conn.resp_body

    # Isolate the revoke <form> markup.
    [_, revoke_form_onward] = String.split(body, ~s(data-form="revoke-device"), parts: 2)
    [revoke_form, _] = String.split(revoke_form_onward, "</form>", parts: 2)

    # The inline handler is CSP-blocked (script-src 'self' w/o 'unsafe-inline') and so
    # never fires — it MUST NOT be used as the confirmation mechanism.
    refute revoke_form =~ ~r/onsubmit=/i,
           "revoke <form> must NOT use an inline onsubmit (blocked by CSP script-src 'self') — confirmation must come from external app.js"

    # The form MUST carry the data-confirm message + a per-row device id so the external
    # app.js submit-listener can present a real, keyboard-operable confirmation.
    assert revoke_form =~ ~r/data-confirm=/i,
           "revoke <form> must carry a data-confirm message that the external app.js confirmation hook reads (AC3)"

    assert revoke_form =~ ~r/data-device-id=/i,
           "revoke <form> must carry data-device-id so the confirmation/audit can identify the device"
  end

  # ── AC4: audit — rename writes an audit row ──────────────────────────────────

  test "AC4 — a successful rename writes a device_renamed audit row (admin actor)" do
    Application.put_env(:nebu_http, :admin_device_renamer, fn _u, _d, _n -> :ok end)

    _conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}/rename")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"display_name" => "Renamed Laptop"})
      |> endpoint_call()

    assert_receive {:audit_log, @admin, "device_renamed", "device", @device_id, _meta, "success", _},
                   500,
                   "expected a device_renamed audit row with the admin as actor and target_id = device_id"
  end

  # ── AC4: audit — delete writes an audit row ──────────────────────────────────

  test "AC4 — a successful delete writes a device_deleted audit row (admin actor)" do
    Application.put_env(:nebu_http, :admin_device_deleter, fn _u, _d -> :ok end)

    _conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"_method" => "DELETE"})
      |> endpoint_call()

    assert_receive {:audit_log, @admin, "device_deleted", "device", @device_id, _meta, "success", _},
                   500,
                   "expected a device_deleted audit row with the admin as actor and target_id = device_id"
  end

  # ── story 5 (oauth-legacy-coexistence, C12 / AC7): a failed atomic teardown ───────
  # `Nebu.Matrix.delete_user_device/2` returns `{:error, :unavailable}` when the atomic teardown
  # fails; the controller maps it to a flash error and a FAILURE audit row (`delete_failed`) instead
  # of crashing on `:ok = do_delete_device(...)`. RED today: MatchError.

  test "story 5 C12 — a failed delete => redirect with a flash error + device_deleted audit row with outcome failure" do
    Application.put_env(:nebu_http, :admin_device_deleter, fn _u, _d -> {:error, :unavailable} end)

    conn =
      try do
        build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"_method" => "DELETE"})
        |> endpoint_call()
      rescue
        e -> flunk("a failed device deletion must not crash the admin controller: #{inspect(e.__struct__)}")
      end

    assert conn.status == 302
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/admin/users/"
    assert is_binary(Phoenix.Flash.get(conn.assigns[:flash] || %{}, :error)), "a flash ERROR is shown"

    assert_receive {:audit_log, @admin, "device_deleted", "device", @device_id, _meta, "failure", "delete_failed"},
                   500,
                   "expected a device_deleted audit row with outcome failure and error_detail delete_failed"

    refute_received {:audit_log, @admin, "device_deleted", "device", @device_id, _meta, "success", _}
  end

  # ── AC4 / SECURITY-2: authz — non-admin is redirected, not served ────────────

  describe "authz (AC4, SECURITY-2)" do
    test "unauthenticated GET /admin/users/:user_id redirects to /admin/login (not served)" do
      conn = build_anon_conn(:get, "/admin/users/#{enc(@target_user)}") |> endpoint_call()

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "/admin/login"
    end

    test "unauthenticated rename POST redirects to /admin/login and does NOT call the renamer" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_device_renamer, fn _u, _d, _n ->
        send(test_pid, :rename_should_not_run)
        :ok
      end)

      conn =
        build_anon_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}/rename")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"display_name" => "Hijacked"})
        |> endpoint_call()

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "/admin/login"
      refute_received :rename_should_not_run
    end

    test "unauthenticated DELETE redirects to /admin/login and does NOT call the deleter" do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_device_deleter, fn _u, _d ->
        send(test_pid, :delete_should_not_run)
        :ok
      end)

      conn =
        build_anon_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"_method" => "DELETE"})
        |> endpoint_call()

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "/admin/login"
      refute_received :delete_should_not_run
    end
  end

  # ── SECURITY-2: IDOR — endpoints pass the ROUTE user_id, not another user's ──

  test "SECURITY-2 (IDOR) — rename is scoped to the route's user_id, never a foreign user" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_device_renamer, fn user_id, device_id, _name ->
      send(test_pid, {:rename_scope, user_id, device_id})
      # Domain API is user-scoped: a device that does not belong to @target_user is :error.
      if user_id == @target_user, do: :ok, else: :error
    end)

    # Even though we pass @other_device in the path, the controller MUST pass the
    # route user_id (@target_user) to the user-scoped facade — so @other_user's device
    # can never be affected through @target_user's page.
    _conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@other_device)}/rename")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"display_name" => "x"})
      |> endpoint_call()

    assert_received {:rename_scope, @target_user, @other_device}
    refute_received {:rename_scope, @other_user, _}
  end

  test "SECURITY-2 (IDOR) — delete is scoped to the route's user_id, never a foreign user" do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_device_deleter, fn user_id, device_id ->
      send(test_pid, {:delete_scope, user_id, device_id})
      :ok
    end)

    _conn =
      build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@other_device)}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:body_params, %{"_method" => "DELETE"})
      |> endpoint_call()

    assert_received {:delete_scope, @target_user, @other_device}
    refute_received {:delete_scope, @other_user, _}
  end

  # ── SECURITY-1: XSS escaping of device_id + display_name ─────────────────────

  test "SECURITY-1 (XSS) — device_id and display_name are HTML-escaped on the detail page" do
    xss_name = "<script>alert(1)</script>"
    xss_device = "<img src=x onerror=alert(2)>"

    Application.put_env(:nebu_http, :admin_device_lister, fn @target_user ->
      [
        %{
          "device_id" => xss_device,
          "display_name" => xss_name,
          "last_seen_ts" => nil,
          "last_seen_ip" => nil
        }
      ]
    end)

    conn = build_admin_conn(:get, "/admin/users/#{enc(@target_user)}") |> endpoint_call()

    assert conn.status == 200
    body = conn.resp_body

    # The raw attacker markup must NEVER appear unescaped.
    refute body =~ "<script>alert(1)</script>",
           "display_name must be HTML-escaped, not rendered as raw markup"
    refute body =~ "<img src=x onerror=alert(2)>",
           "device_id must be HTML-escaped, not rendered as raw markup"

    # The escaped form must be present (HEEx auto-escaping — locked in here).
    assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt;",
           "display_name must appear in its HTML-escaped form"
    assert body =~ "&lt;img src=x onerror=alert(2)&gt;",
           "device_id must appear in its HTML-escaped form"
  end

  # ── SECURITY-3: CSRF — state-changing POSTs require a valid CSRF token ───────

  describe "CSRF (SECURITY-3)" do
    setup do
      # Turn the test bypass OFF so real protect_from_forgery runs for these conns.
      # MUST restore the prior value in on_exit — without it, `admin_csrf_bypass = false`
      # leaks into every admin test that runs LATER in the full suite (order/seed-dependent
      # → spurious InvalidCSRFTokenError in admin_http_controllers_test etc.).
      prior_csrf = Application.get_env(:nebu_http, :admin_csrf_bypass)
      Application.put_env(:nebu_http, :admin_csrf_bypass, false)
      on_exit(fn -> restore_csrf_bypass(prior_csrf) end)
      :ok
    end

    test "rename POST without a CSRF token is rejected (not processed)" do
      Application.put_env(:nebu_http, :admin_device_renamer, fn _u, _d, _n -> :ok end)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}/rename")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"display_name" => "no-csrf"})
        |> endpoint_call()
      end
    end

    test "delete POST without a CSRF token is rejected (not processed)" do
      Application.put_env(:nebu_http, :admin_device_deleter, fn _u, _d -> :ok end)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        build_admin_conn(:post, "/admin/users/#{enc(@target_user)}/devices/#{enc(@device_id)}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Map.put(:body_params, %{"_method" => "DELETE"})
        |> endpoint_call()
      end
    end
  end

  # ── SECURITY-4 / AC4: audit actions registered in AuditWriter.@known_actions ─
  #
  # Guards the merge-gotcha (project_audit_allowlist_merge_gotcha): a new audit
  # action silently breaks the trail if it is not added to @known_actions. These
  # assert the actions ARE registered — i.e. AuditWriter.log/7 does NOT reject
  # them with {:error, :audit_unknown_action}.

  describe "audit action registration (SECURITY-4, AC4)" do
    test "device_renamed is a known audit action" do
      refute AuditWriter.log(@admin, "device_renamed", "device", @device_id, %{}, "success") ==
               {:error, :audit_unknown_action},
             "device_renamed must be added to AuditWriter.@known_actions"
    end

    test "device_deleted is a known audit action" do
      refute AuditWriter.log(@admin, "device_deleted", "device", @device_id, %{}, "success") ==
               {:error, :audit_unknown_action},
             "device_deleted must be added to AuditWriter.@known_actions"
    end
  end
end
