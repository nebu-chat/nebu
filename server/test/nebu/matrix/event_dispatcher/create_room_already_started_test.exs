defmodule Nebu.Matrix.EventDispatcher.CreateRoomAlreadyStartedTest do
  use ExUnit.Case, async: false

  # ─── Kassandra SEC review — LOW-1 ────────────────────────────────────────────
  #
  # create_room/2 generates a fresh random room_id and starts a Room GenServer for
  # it. start_room/1 maps {:already_started, pid} → {:ok, pid}, so a (practically
  # impossible) random-id collision would make create_room proceed against a
  # PRE-EXISTING room — and a later failure's cleanup_orphan_room/1 would hard-delete
  # that room's events+members+row.
  #
  # The fix: create_room/2 now calls room_supervisor_module().start_new_room/1, which
  # returns {:error, :already_started, pid} for an already-running room. create_room
  # must turn that into a clean Nebu.Matrix.Error (already_exists) and NEVER run
  # do_create_room/cleanup_orphan_room — so cleanup can only ever target a room THIS
  # call created.
  #
  # This test injects a FakeRoomSupervisor that reports :already_started and a
  # RecordingRoomsDB that records any delete_room/1 call. We assert:
  #   1. create_room raises Nebu.Matrix.Error (the conflict), and
  #   2. delete_room/1 was NOT called — the pre-existing room is never cleaned up.
  #
  # async: false — Application.put_env is process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @ets :create_room_already_started_test_db

  # FakeRoomSupervisor — simulates a room_id that is already running. start_new_room/1
  # returns {:error, :already_started, pid} exactly as the real RoomSupervisor does for
  # a Horde {:already_started, pid}.
  defmodule FakeRoomSupervisor do
    def start_new_room(_room_id), do: {:error, :already_started, self()}
  end

  # RecordingRoomsDB — records every delete_room/1 call so the test can assert cleanup
  # was NOT triggered for the pre-existing room.
  defmodule RecordingRoomsDB do
    @ets :create_room_already_started_test_db

    def delete_room(room_id) do
      :ets.insert(@ets, {{:delete_room_called, room_id}, true})
      :ok
    end
  end

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  defmodule NoOpUserStore do
    def upsert_user(user_id, _role), do: {:ok, user_id}
  end

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    Application.put_env(:event_dispatcher, :room_supervisor_module, FakeRoomSupervisor)
    Application.put_env(:event_dispatcher, :rooms_db_module, RecordingRoomsDB)
    Application.put_env(:event_dispatcher, :user_store_module, NoOpUserStore)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :room_supervisor_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :user_store_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)
      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    end)

    :ok
  end

  defp build_stream, do: %{http_request_headers: %{}}

  test "create_room raises a conflict and never deletes the pre-existing room (LOW-1)" do
    request = %Core.CreateRoomRequest{
      creator_id: "@kai:test.local",
      name: "general",
      is_direct: false
    }

    err =
      assert_raise Nebu.Matrix.Error, fn ->
        Server.create_room(request, build_stream())
      end

    # Conflict status — not internal, not not_found.
    assert err.status == Nebu.Matrix.Status.already_exists(),
           "expected already_exists conflict, got: #{inspect(err.status)}"

    # The pre-existing room must NEVER be cleaned up: do_create_room/cleanup_orphan_room
    # must not run at all when the room was already started.
    delete_calls = :ets.match(@ets, {{:delete_room_called, :"$1"}, true})

    assert delete_calls == [],
           "delete_room/1 must NOT be called for an already-started room — " <>
             "got cleanup for: #{inspect(delete_calls)}"
  end
end
