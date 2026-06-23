defmodule Nebu.Matrix.EventDispatcher.LeaveRoomTest do
  use ExUnit.Case, async: false

  # ─── Bugfix: leave_room fallback paths fail to persist left_at ───────────────
  #
  # RED PHASE — all three test groups are written BEFORE the fix is applied.
  # They must FAIL with the current implementation and pass after the fix.
  #
  # Bug summary: two code paths in Server.leave_room/2 never call
  # rooms_db_module().delete_member/2, so room_members.left_at stays NULL:
  #
  #   Path 1 (AC3): {:error, :not_found} — GenServer not running.
  #     Current code: calls only db_module_invite().reject_invitation/2 + emit_decline_event/2.
  #     Missing: rooms_db_module().delete_member(room_id, user_id)
  #
  #   Path 2 (AC4): GenServer running but returns {:error, :not_member}.
  #     Current code: calls only db_module_invite().reject_invitation/2 + emit_decline_event/2.
  #     Missing: rooms_db_module().delete_member(room_id, user_id)
  #
  # AC5 (invited-only user): reject_invitation path — verified to NOT call delete_member
  # (no room_members row exists), which must not raise an error.
  #
  # Coverage:
  #   AT1: AC3 — GenServer not running, user in room_members → left_at set after leave
  #   AT2: AC4 — GenServer running but user absent from in-memory members → left_at set
  #   AT3: AC5 — invited-only user (no room_members row) → rejected_at set, no error
  #
  # async: false — Horde.Registry, Horde.DynamicSupervisor, Application.put_env,
  # and ETS tables are all process-global resources.

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeRoomsDB ────────────────────────────────────────────────────────────
  #
  # Tracks calls to delete_member/2.
  # Key {:member, room_id, user_id} → :active means the member row with left_at NULL.
  # delete_member/2 removes the :active entry and writes {:left_at, room_id, user_id}
  # to signal that left_at was set, mirroring the DB soft-delete semantic.

  defmodule FakeRoomsDB do
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}

    def delete_member(room_id, user_id) do
      case :ets.lookup(:leave_room_test_db, {:member, room_id, user_id}) do
        [] ->
          {:error, :not_member}

        [{_, :active}] ->
          :ets.delete(:leave_room_test_db, {:member, room_id, user_id})
          :ets.insert(:leave_room_test_db, {{:left_at, room_id, user_id}, System.system_time(:millisecond)})
          :ok
      end
    end

    # Stubs for callbacks required but not exercised by these tests.
    def load_members(_room_id), do: {:error, :not_found}
    def insert_room(_room_id), do: {:ok, 0}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _json), do: :ok
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: false
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
  end

  # ─── FakeInviteDB ────────────────────────────────────────────────────────────
  #
  # Tracks reject_invitation/2 calls via ETS.
  # Key {:invitation, room_id, user_id} → pending means an open invitation.
  # reject_invitation writes {:rejected_at, room_id, user_id} → timestamp.

  defmodule FakeInviteDB do
    def reject_invitation(room_id, user_id) do
      :ets.insert(
        :leave_room_test_invitations,
        {{:rejected_at, room_id, user_id}, System.system_time(:millisecond)}
      )
      :ok
    end

    def insert_invitation(room_id, inviter_id, invitee_id) do
      :ets.insert(:leave_room_test_invitations, {{:invitation, room_id, invitee_id}, inviter_id})
      :ok
    end

    def accept_invitation(_room_id, _invitee_id), do: :ok
    def get_pending_invite_rooms_for_user(_user_id), do: {:ok, []}
    def get_declined_invite_rooms_for_user(_user_id), do: {:ok, []}
  end

  # ─── FakeDB (room_manager) ───────────────────────────────────────────────────
  #
  # Used to satisfy Room.Server.init/1 which requires a :room_manager db_module.
  # When a Room GenServer is started, it calls load_members/1 on this module.

  defmodule FakeRoomManagerDB do
    def load_members(room_id) do
      case :ets.lookup(:leave_room_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:leave_room_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:leave_room_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:leave_room_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:leave_room_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:leave_room_test_db, {:member, room_id, user_id})
      :ets.insert(:leave_room_test_db, {{:left_at, room_id, user_id}, System.system_time(:millisecond)})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:leave_room_test_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:leave_room_test_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
  end

  # ─── NoOpAuditWriter ─────────────────────────────────────────────────────────

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ─── FakeMessagesDB ──────────────────────────────────────────────────────────
  #
  # Needed because emit_decline_event/2 calls messages_db_module().insert_event/1.

  defmodule FakeMessagesDB do
    def insert_event(_event), do: :ok
    # Story rm5: leave_room/2 now reads get_personal_room_id/1 for the personal-room
    # leave guard. These tests use non-personal rooms, so nil disables the guard.
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: false
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    # Create the ETS tables. Guard against stale tables from --watch reruns.
    if :ets.info(:leave_room_test_db) != :undefined do
      :ets.delete(:leave_room_test_db)
    end
    :ets.new(:leave_room_test_db, [:named_table, :public, :set])

    if :ets.info(:leave_room_test_invitations) != :undefined do
      :ets.delete(:leave_room_test_invitations)
    end
    :ets.new(:leave_room_test_invitations, [:named_table, :public, :set])

    # Inject fake modules.
    Application.put_env(:room_manager, :db_module, FakeRoomManagerDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeRoomsDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB)
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    # Initialise :pg (built-in OTP, idempotent).
    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Clear :NebuTxnDedup between tests to prevent idempotency state leakage.
    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :invite_db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:compliance, :audit_writer)

      if :ets.info(:leave_room_test_db) != :undefined do
        :ets.delete(:leave_room_test_db)
      end

      if :ets.info(:leave_room_test_invitations) != :undefined do
        :ets.delete(:leave_room_test_invitations)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp build_stream, do: %{http_request_headers: %{}}

  # Horde.Registry can propagate asynchronously even on a single node.
  # Retry the lookup until the entry appears or we time out.
  defp wait_for_registry(room_id, retries \\ 20) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      _ when retries > 0 ->
        Process.sleep(10)
        wait_for_registry(room_id, retries - 1)

      _ ->
        raise "Horde.Registry did not register #{room_id} within timeout"
    end
  end

  # Register an on_exit callback to stop the Room GenServer (prevents Horde pollution).
  defp track_room(room_id) do
    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
          {:ok, pid} ->
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
          _ ->
            :ok
        end
      end
    end)
  end

  # ─── AT1 (AC3): leave_room when GenServer NOT running sets left_at ────────────
  #
  # Bug: The {:error, :not_found} branch in leave_room/2 only calls
  # reject_invitation/2 + emit_decline_event/2. It never calls
  # rooms_db_module().delete_member/2, so room_members.left_at stays NULL.
  #
  # This test FAILS with the current implementation because FakeRoomsDB.delete_member/2
  # is never called, so the {:left_at, room_id, user_id} ETS entry is never written.
  # After the fix, delete_member/2 is called and the assertion passes.
  #
  # Given: User IS in room_members (FakeRoomsDB has an :active entry), GenServer NOT running
  # When:  Server.leave_room/2 is called
  # Then:  FakeRoomsDB records left_at set (delete_member was called)
  #        Response is %Core.LeaveRoomResponse{room_id: room_id}

  describe "AC3: leave_room when GenServer not running" do
    test "sets left_at in room_members (calls rooms_db_module().delete_member)" do
      room_id = "!leave-ac3-#{System.unique_integer([:positive])}:test.local"
      user_id = "@alice:test.local"

      # Pre-condition: User IS in room_members (left_at NULL = :active entry in ETS).
      :ets.insert(:leave_room_test_db, {{:member, room_id, user_id}, :active})

      # Pre-condition: Room GenServer is NOT running (no start_room call).
      # Verify the precondition holds.
      assert {:error, :not_found} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id),
             "precondition failed: Room GenServer should NOT be running for #{room_id}"

      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}
      response = Server.leave_room(request, build_stream())

      # Response must be success.
      assert %Core.LeaveRoomResponse{room_id: ^room_id} = response

      # THE CRITICAL ASSERTION: left_at must have been set.
      # With the bug, FakeRoomsDB.delete_member is never called, so this key is absent.
      # After the fix, delete_member/2 is called and the key exists.
      assert :ets.lookup(:leave_room_test_db, {:left_at, room_id, user_id}) != [],
             "Expected left_at to be set in room_members for #{user_id}/#{room_id}, " <>
               "but rooms_db_module().delete_member/2 was never called. " <>
               "This is the AC3 bug: the {:error, :not_found} branch in leave_room/2 " <>
               "must call rooms_db_module().delete_member/2 before returning."
    end

    test "returns LeaveRoomResponse with room_id even when GenServer not running" do
      room_id = "!leave-ac3-resp-#{System.unique_integer([:positive])}:test.local"
      user_id = "@bob:test.local"

      :ets.insert(:leave_room_test_db, {{:member, room_id, user_id}, :active})

      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

      # Must not raise — GenServer not found is a handled case.
      response = Server.leave_room(request, build_stream())

      assert %Core.LeaveRoomResponse{} = response
      assert response.room_id == room_id
    end
  end

  # ─── AT2 (AC4): leave_room when GenServer running but user absent from in-memory state
  #
  # Bug: The {:error, :not_member} branch inside the {:ok, _pid} case only calls
  # reject_invitation/2 + emit_decline_event/2. It never calls
  # rooms_db_module().delete_member/2.
  #
  # This test sets up a room with NO in-memory members (the GenServer loads from ETS
  # but the :active key for the user is present in FakeRoomsDB, simulating a stale
  # in-memory state after a crash or cross-node reconciliation gap).
  #
  # Strategy: start a fresh Room GenServer (no members in room_manager DB), but add
  # an :active entry for the user directly in the FakeRoomsDB ETS table. This causes
  # Room.Server.leave/2 to return {:error, :not_member} (not in GenServer state),
  # while FakeRoomsDB records whether delete_member was called.
  #
  # Given: User IS in room_members (:active in FakeRoomsDB ETS),
  #        Room GenServer IS running but its in-memory `members` MapSet does NOT contain user
  # When:  Server.leave_room/2 is called
  # Then:  FakeRoomsDB records left_at set (delete_member was called)

  describe "AC4: leave_room when GenServer running but user absent from in-memory state" do
    test "sets left_at in room_members (calls rooms_db_module().delete_member)" do
      room_id = "!leave-ac4-#{System.unique_integer([:positive])}:test.local"
      user_id = "@carol:test.local"

      # Pre-condition: Room GenServer IS running, but user is NOT in its in-memory members.
      # We start the room without any members so the GenServer's MapSet is empty.
      :ets.insert(:leave_room_test_db, {{:room, room_id}, System.system_time(:millisecond)})
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      :ok = wait_for_registry(room_id)
      track_room(room_id)

      # Verify precondition: user NOT in GenServer in-memory state.
      state = Nebu.Matrix.Room.Server.get_state(room_id)

      refute MapSet.member?(state.members, user_id),
             "precondition failed: #{user_id} must NOT be in in-memory GenServer members"

      # Pre-condition: User IS in room_members DB (left_at NULL).
      :ets.insert(:leave_room_test_db, {{:member, room_id, user_id}, :active})

      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}
      response = Server.leave_room(request, build_stream())

      # Response must be success.
      assert %Core.LeaveRoomResponse{room_id: ^room_id} = response

      # THE CRITICAL ASSERTION: left_at must have been set.
      # With the bug, FakeRoomsDB.delete_member is never called on this path.
      # After the fix, delete_member/2 is called and the key exists.
      assert :ets.lookup(:leave_room_test_db, {:left_at, room_id, user_id}) != [],
             "Expected left_at to be set in room_members for #{user_id}/#{room_id}, " <>
               "but rooms_db_module().delete_member/2 was never called. " <>
               "This is the AC4 bug: the {:error, :not_member} branch in leave_room/2 " <>
               "must call rooms_db_module().delete_member/2 before returning."
    end

    test "returns LeaveRoomResponse with room_id on :not_member path" do
      room_id = "!leave-ac4-resp-#{System.unique_integer([:positive])}:test.local"
      user_id = "@dave:test.local"

      :ets.insert(:leave_room_test_db, {{:room, room_id}, System.system_time(:millisecond)})
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      :ok = wait_for_registry(room_id)
      track_room(room_id)

      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

      # Must not raise — :not_member is a handled case.
      response = Server.leave_room(request, build_stream())

      assert %Core.LeaveRoomResponse{} = response
      assert response.room_id == room_id
    end
  end

  # ─── AT3 (AC5): leave_room for invited-only user sets rejected_at, no error ───
  #
  # This test verifies the existing invite-decline path still works correctly.
  # An invited-only user has no room_members row — only a room_invitations row.
  # FakeRoomsDB.delete_member/2 would return {:error, :not_member} for this user.
  # The handler must NOT fail: it calls reject_invitation (FakeInviteDB) and returns 200.
  #
  # The test also verifies that FakeRoomsDB.delete_member is NOT called for this case
  # with the current code (no room_members row exists → no need to call delete_member).
  # After the fix, delete_member may be called but must handle :not_member gracefully.
  #
  # Given: User has a pending invitation (in FakeInviteDB), no room_members row
  # When:  Server.leave_room/2 is called (GenServer NOT running scenario)
  # Then:  FakeInviteDB records rejected_at IS set
  #        Response is %Core.LeaveRoomResponse{room_id: room_id}
  #        No exception is raised

  describe "AC5: leave_room for invited-only user" do
    test "sets rejected_at in room_invitations and does not raise" do
      room_id = "!leave-ac5-#{System.unique_integer([:positive])}:test.local"
      user_id = "@eve:test.local"

      # Pre-condition: User has a pending invitation (FakeInviteDB ETS).
      :ets.insert(
        :leave_room_test_invitations,
        {{:invitation, room_id, user_id}, "@inviter:test.local"}
      )

      # Pre-condition: NO room_members row (no :active entry in FakeRoomsDB ETS).
      # Pre-condition: GenServer is NOT running.
      assert {:error, :not_found} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id)

      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

      # Must not raise.
      response = Server.leave_room(request, build_stream())

      assert %Core.LeaveRoomResponse{room_id: ^room_id} = response

      # rejected_at must be set in FakeInviteDB.
      assert :ets.lookup(:leave_room_test_invitations, {:rejected_at, room_id, user_id}) != [],
             "Expected rejected_at to be set in room_invitations for #{user_id}/#{room_id}, " <>
               "but FakeInviteDB.reject_invitation/2 was never called."
    end

    test "does not raise even when both GenServer not running and no room_members row exist" do
      room_id = "!leave-ac5-clean-#{System.unique_integer([:positive])}:test.local"
      user_id = "@frank:test.local"

      # No ETS entries at all — completely absent user.
      request = %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

      # Must not raise for an unknown user with no GenServer.
      assert %Core.LeaveRoomResponse{room_id: ^room_id} = Server.leave_room(request, build_stream())
    end
  end
end
