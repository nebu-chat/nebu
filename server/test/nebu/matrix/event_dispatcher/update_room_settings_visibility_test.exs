defmodule Nebu.Matrix.EventDispatcher.UpdateRoomSettingsVisibilityTest do
  use ExUnit.Case, async: false

  # ─── Story rm1-room-visibility — update_room_settings/2 visibility paths ───────
  #
  # ATDD — written FIRST (before the visibility branch existed in server.ex).
  #
  # Verifies the visibility handling of the in-process update_room_settings/2 command:
  #   AC2 — visibility: "public" → admin_db_module().update_room_visibility(id, "public")
  #         is invoked AND an audit_log row (action="room_visibility_changed") is emitted.
  #   AC5 — visibility: ""      → update_room_visibility is NOT called (legacy = no change).
  #   AC5 — visibility: "bogus" → update_room_visibility is NOT called (default-deny);
  #         the handler still returns ok for the rest of the request.
  #
  # Also covers the in-process Admin entry point set_room_visibility/3:
  #   "public"/"private" → audited write; any other value → {:error, :invalid_visibility}
  #   without touching the DB.
  #
  # async: false — Application.put_env/3, Horde, :NebuTxnDedup and :pg are process-global.
  #
  # DB injection: a function-free FakeAdminDB records update_room_visibility/2 calls into
  # the test process mailbox (no live Postgres). FakeAuditWriter mirrors the established
  # audit-spy pattern (audit_room_ops_test.exs).

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeAdminDB ───────────────────────────────────────────────────────────────
  # Records every update_room_visibility/2 call so tests can assert it was (or was NOT)
  # invoked. update_room_auto_join/2 is a no-op (visibility tests do not set is_auto_join).

  defmodule FakeAdminDB do
    def update_room_visibility(room_id, visibility) do
      pid = Application.get_env(:event_dispatcher, :__visibility_test_pid__)
      if pid && Process.alive?(pid), do: send(pid, {:update_room_visibility_called, room_id, visibility})
      :ok
    end

    def update_room_auto_join(_room_id, _value), do: :ok
  end

  # ─── FakeAuditWriter ─────────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      pid = Application.get_env(:compliance, :__audit_test_pid__)

      if pid && Process.alive?(pid) do
        send(pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      end

      :ok
    end
  end

  # ─── Setup ───────────────────────────────────────────────────────────────────

  setup do
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:event_dispatcher, :__visibility_test_pid__, self())
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter)
    Application.put_env(:compliance, :__audit_test_pid__, self())

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :admin_db_module)
      Application.delete_env(:event_dispatcher, :__visibility_test_pid__)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:compliance, :__audit_test_pid__)

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  # The room GenServer is NOT running for these room ids, so update_room_settings/2 takes
  # the best-effort :not_found branch (no GenServer state to touch) — exactly what we want
  # to isolate the visibility persistence + audit behaviour.
  defp build_stream do
    %{
      http_request_headers: %{
        "x-user-id" => "@admin:nebu.local",
        "x-system-role" => "instance_admin"
      }
    }
  end

  # ─── AC2: visibility "public" → DB write + audit ──────────────────────────────

  describe "update_room_settings/2 — visibility persistence" do
    test "visibility=public invokes update_room_visibility and emits an audit log" do
      room_id = "!vis-public:test.local"

      req = %Core.UpdateRoomSettingsRequest{room_id: room_id, max_members: 0, visibility: "public"}

      assert %Core.UpdateRoomSettingsResponse{ok: true} = Server.update_room_settings(req, build_stream())

      assert_receive {:update_room_visibility_called, ^room_id, "public"}, 500

      assert_receive {:audit_log, "@admin:nebu.local", "room_visibility_changed", "room", ^room_id,
                      %{"visibility" => "public"}, "success", _},
                     500
    end

    test "visibility=private invokes update_room_visibility with private" do
      room_id = "!vis-private:test.local"

      req = %Core.UpdateRoomSettingsRequest{room_id: room_id, max_members: 0, visibility: "private"}

      assert %Core.UpdateRoomSettingsResponse{ok: true} = Server.update_room_settings(req, build_stream())

      assert_receive {:update_room_visibility_called, ^room_id, "private"}, 500
    end

    # ─── AC5: empty visibility = no change ─────────────────────────────────────

    test "visibility=\"\" does NOT call update_room_visibility (legacy = no change)" do
      room_id = "!vis-empty:test.local"

      req = %Core.UpdateRoomSettingsRequest{room_id: room_id, max_members: 0, visibility: ""}

      assert %Core.UpdateRoomSettingsResponse{ok: true} = Server.update_room_settings(req, build_stream())

      refute_receive {:update_room_visibility_called, _, _}, 200
      refute_receive {:audit_log, _, "room_visibility_changed", _, _, _, _, _}, 100
    end

    # ─── AC5: invalid visibility = default-deny, never written ─────────────────

    test "visibility=\"bogus\" is rejected — update_room_visibility NOT called, response still ok" do
      room_id = "!vis-bogus:test.local"

      req = %Core.UpdateRoomSettingsRequest{room_id: room_id, max_members: 0, visibility: "bogus"}

      assert %Core.UpdateRoomSettingsResponse{ok: true} = Server.update_room_settings(req, build_stream())

      refute_receive {:update_room_visibility_called, _, _}, 200
      refute_receive {:audit_log, _, "room_visibility_changed", _, _, _, _, _}, 100
    end
  end

  # ─── set_room_visibility/3 — the Admin UI entry point (ADR-020 via Nebu.Matrix) ─

  describe "set_room_visibility/3" do
    test "public → audited DB write, returns :ok" do
      room_id = "!srv-public:test.local"

      assert :ok = Server.set_room_visibility("@admin:nebu.local", room_id, "public")

      assert_receive {:update_room_visibility_called, ^room_id, "public"}, 500

      assert_receive {:audit_log, "@admin:nebu.local", "room_visibility_changed", "room", ^room_id,
                      %{"visibility" => "public"}, "success", _},
                     500
    end

    test "invalid value → {:error, :invalid_visibility}, no DB write, no audit" do
      assert {:error, :invalid_visibility} =
               Server.set_room_visibility("@admin:nebu.local", "!srv-bad:test.local", "bogus")

      refute_receive {:update_room_visibility_called, _, _}, 200
      refute_receive {:audit_log, _, "room_visibility_changed", _, _, _, _, _}, 100
    end
  end
end
