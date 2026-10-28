defmodule Nebu.Matrix.EventDispatcher.HandlerTest do
  use ExUnit.Case, async: false

  # ─── Story 4-8: GetRoomState Unary + send_event state_key ───────────────────
  #
  # async: false — Horde.Registry, :pg groups, and Application env are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeDB (room_manager injection) ────────────────────────────────────────
  # event_dispatcher does not currently depend on room_manager, but Story 4-8
  # adds that dependency so get_room_state/2 can call Nebu.Matrix.Room.Server.get_state/1.
  # FakeRoomRegistry below simulates the Room.Server response.

  defmodule FakeRoomRegistry do
    @moduledoc """
    Replaces the room_manager lookup used by get_room_state/2.
    Inject via Application.put_env(:event_dispatcher, :room_registry_module, FakeRoomRegistry).
    """

    def get_state("!room1:nebu.local") do
      %{
        room_id: "!room1:nebu.local",
        members: MapSet.new(["@kai:nebu.local"]),
        power_levels: %{},
        created_at: ~U[2025-01-01 00:00:00Z]
      }
    end

    def get_state(room_id) do
      # Simulate GenServer.call to an unregistered process — exits with {:noproc, _}
      # just like the real Nebu.Matrix.Room.Server.get_state/1 would.
      exit({:noproc, {GenServer, :call, [{:via, Horde.Registry, {Nebu.Matrix.Room.Registry, room_id}}, :get_state, 5000]}})
    end
  end

  # ─── FakeMessagesDB ──────────────────────────────────────────────────────────
  # Prevents Ecto dependency in get_room_state tests.
  # build_state_events/2 calls messages_db_module().get_room_name/1 — this stub
  # returns :not_found so no m.room.name state event is emitted (Story 7-33 fix).

  defmodule FakeMessagesDB do
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    # Story 9-7: returns empty list (no generic state events in unit tests).
    def get_generic_state_events(_room_id), do: {:ok, []}
    # MAJOR-2 fix: no persisted create event in these unit tests; synthesized fallback used.
    def get_room_create_event(_room_id), do: {:error, :not_found}
  end

  # story membership-state-model (DELIBERATE re-pin, AC15 (f); old -> new): the room resolution of get_room_state/2 for a room whose process is not running is
  # `ensure_room_without_lazy_create!/2`, which reads the room status through `rooms_db_module()`: this fake answers "no such room" for every id.
  defmodule FakeRoomsDB do
    def get_room_status(_room_id), do: {:error, :not_found}
  end

  # ─── Build a minimal fake stream (request-context map) ──────────────────────
  # Carries x-user-id in http_request_headers so Nebu.Matrix.RequestMetadata.trusted_identity/1
  # returns the correct caller identity. x-system-role is omitted — defaults to "user".

  defp build_fake_stream(_test_pid) do
    %{
      # x-user-id matches the member in FakeRoomRegistry so the Story 7-19 membership
      # check passes. x-system-role is omitted — trusted_identity/1 defaults to "user".
      http_request_headers: %{"x-user-id" => "@kai:nebu.local"}
    }
  end

  # ─── Setup ──────────────────────────────────────────────────────────────────

  setup do
    # Ensure :pg is started (it is an OTP built-in, normally started by BEAM)
    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Inject fake room registry for get_room_state tests
    Application.put_env(:event_dispatcher, :room_registry_module, FakeRoomRegistry)

    # Inject fake messages DB so build_state_events/2 does not hit Ecto (Story 7-33)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeRoomsDB)

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :room_registry_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
    end)

    :ok
  end

  # ─── AC #3 — get_room_state/2: happy path ────────────────────────────────────

  describe "Server.get_room_state/2 — unary handler" do
    test "returns GetRoomStateResponse with members list for an existing room" do
      # Given: FakeRoomRegistry knows !room1:nebu.local with @kai as member
      request = %Core.GetRoomStateRequest{room_id: "!room1:nebu.local"}
      stream = build_fake_stream(self())

      response = Server.get_room_state(request, stream)

      assert %Core.GetRoomStateResponse{} = response
      assert "@kai:nebu.local" in response.members
      assert response.power_levels_json == "{}"
      assert response.room_name == ""
    end

    test "returns exactly the members from the Room GenServer state" do
      request = %Core.GetRoomStateRequest{room_id: "!room1:nebu.local"}
      stream = build_fake_stream(self())

      response = Server.get_room_state(request, stream)

      assert length(response.members) == 1
      assert hd(response.members) == "@kai:nebu.local"
    end
  end

  # ─── AC #3 — get_room_state/2: NOT_FOUND for non-existent room ───────────────

  # story membership-state-model (DELIBERATE re-pin, AC15 (f); old -> new): an UNKNOWN room id answers 403 M_FORBIDDEN "You are not a member of this room"
  # (was: NOT_FOUND "room not found: <id>"), with no `rooms` row and no room process (D6 (a)); the system-role caller gets the same answer.
  describe "Server.get_room_state/2 — unknown room: 403 M_FORBIDDEN" do
    test "raises Nebu.Matrix.Error when room does not exist" do
      # Given: FakeRoomRegistry raises for !ghost:nebu.local
      request = %Core.GetRoomStateRequest{room_id: "!ghost:nebu.local"}
      stream = build_fake_stream(self())

      assert_raise Nebu.Matrix.Error, fn ->
        Server.get_room_state(request, stream)
      end
    end

    test "the raised Nebu.Matrix.Error is permission_denied with the explicit M_FORBIDDEN and the fixed text (no room id)" do
      request = %Core.GetRoomStateRequest{room_id: "!ghost:nebu.local"}
      stream = build_fake_stream(self())

      error =
        try do
          Server.get_room_state(request, stream)
          nil
        rescue
          e in Nebu.Matrix.Error -> e
        end

      refute is_nil(error), "expected Nebu.Matrix.Error to be raised but got nil"
      assert error.status == Nebu.Matrix.Status.permission_denied()
      assert error.errcode == "M_FORBIDDEN"
      assert Exception.message(error) == "You are not a member of this room"
    end

    test "the system-role caller of an unknown room gets the same 403 (the internal fanout never lazily creates a room)" do
      request = %Core.GetRoomStateRequest{room_id: "!ghost:nebu.local"}
      stream = %{http_request_headers: %{"x-system-role" => "system"}}

      error = assert_raise Nebu.Matrix.Error, fn -> Server.get_room_state(request, stream) end

      assert error.status == Nebu.Matrix.Status.permission_denied() and error.errcode == "M_FORBIDDEN"
      assert Exception.message(error) == "You are not a member of this room"
    end
  end

  # ─── Story 9-7: state_key propagation in send_event handler ─────────────────
  #
  # AC: When Server.send_event/2 receives a SendEventRequest with a non-empty
  # state_key, it must pass state_key through to Nebu.Matrix.Room.Server.send_event/6
  # and the resulting persisted event must carry that state_key.
  #
  # Strategy: call Server.send_event/2 with a real Room GenServer running
  # (via the room_manager Application already started), inject FakeDB via
  # Application.put_env so no PostgreSQL is needed, then assert the stored
  # event in the FakeDB ETS table has the correct state_key value.
  #
  # Note: this describe block depends on the room_manager Application being
  # started as part of the umbrella test run. Room GenServer and :NebuTxnDedup
  # ETS table are available.

  describe "Server.send_event/2 — state_key propagation (Story 9-7)" do
    # Module-level FakeDB for this describe block (same pattern as send_event_test.exs).
    defmodule FakeRoomDB do
      def load_members(room_id) do
        case :ets.lookup(:grpc_handler_state_key_db, {:room, room_id}) do
          [] ->
            {:error, :not_found}

          [{_, created_at_ms}] ->
            members = :ets.match(:grpc_handler_state_key_db, {{:member, room_id, :"$1"}, :active})
            # SEC Gate 1 fix: load power levels from ETS if set, otherwise return empty "{}".
            pl_json =
              case :ets.lookup(:grpc_handler_state_key_db, {:power_levels, room_id}) do
                [{_, json}] -> json
                [] -> "{}"
              end
            {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
        end
      end

      def insert_room(room_id) do
        now_ms = System.system_time(:millisecond)
        :ets.insert(:grpc_handler_state_key_db, {{:room, room_id}, now_ms})
        {:ok, now_ms}
      end

      def insert_member(room_id, user_id) do
        :ets.insert(:grpc_handler_state_key_db, {{:member, room_id, user_id}, :active})
        :ok
      end

      def delete_member(_room_id, _user_id), do: :ok

      def insert_event(event) do
        :ets.insert(:grpc_handler_state_key_db, {{:event, event["event_id"]}, event})
        :ok
      end

      # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
      # transaction with its own column write AND event insert (a failure of either is the change's failure)
      def apply_power_levels_change(room_id, json, event) do
        with :ok <- set_power_levels(room_id, json), do: insert_event(event)
      end

      def set_power_levels(room_id, json) do
        :ets.insert(:grpc_handler_state_key_db, {{:power_levels, room_id}, json})
        :ok
      end
      def load_room_settings(_room_id), do: {:ok, 0}
      def get_room_status(_room_id), do: {:ok, "active"}
      # Story 9-9: TOCTOU fix — returns {:ok, "active"} for normal rooms.
      def check_room_status_for_update(_room_id), do: {:ok, "active"}
      # Remaining callbacks required by @behaviour Nebu.Matrix.Room.DBBehaviour:
      def get_rooms_for_user(_user_id), do: {:ok, []}
      def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
      def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
      def fetch_events_since(_room_id, _last_event_id, _limit), do: {:ok, []}
      def get_event_timestamp(_event_id), do: {:error, :not_found}
      def get_room_name(_room_id), do: {:error, :not_found}
      def get_room_creator(_room_id), do: {:error, :not_found}
      def get_generic_state_events(_room_id), do: {:ok, []}
      def get_room_create_event(_room_id), do: {:error, :not_found}
      # Story 9-28: no thread relations in grpc handler tests.
      def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
      def count_thread_children(_room_id, _event_id), do: {:ok, 0}
      def event_in_room?(_event_id, _room_id), do: true
      # Story personal-self-room: personal room callbacks.
      def get_personal_room_id(_user_id), do: {:ok, nil}
      def set_personal_room_id(_user_id, _room_id), do: :ok
      # Story direct-room-heroes + admin-auto-join-rooms: required stubs.
      def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
      def list_auto_join_rooms(), do: {:ok, []}
    end

    setup do
      # Create a fresh ETS table for this test group.
      if :ets.info(:grpc_handler_state_key_db) != :undefined do
        :ets.delete(:grpc_handler_state_key_db)
      end

      :ets.new(:grpc_handler_state_key_db, [:named_table, :public, :set])

      Application.put_env(:room_manager, :db_module, FakeRoomDB)
      Application.put_env(:event_dispatcher, :server_name, "test.local")

      # Override room_registry_module to use the REAL Nebu.Matrix.Room.Server.get_state/1
      # so the membership check in Server.send_event/2 uses the actual running GenServer
      # (not the FakeRoomRegistry defined in the outer setup which only knows !room1:nebu.local).
      Application.put_env(:event_dispatcher, :room_registry_module, Nebu.Matrix.Room.Server)

      case :pg.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end

      on_exit(fn ->
        Application.delete_env(:room_manager, :db_module)
        Application.delete_env(:event_dispatcher, :server_name)
        Application.delete_env(:event_dispatcher, :room_registry_module)

        if :ets.info(:grpc_handler_state_key_db) != :undefined do
          :ets.delete(:grpc_handler_state_key_db)
        end

        if :ets.whereis(:NebuTxnDedup) != :undefined do
          :ets.delete_all_objects(:NebuTxnDedup)
        end
      end)

      :ok
    end

    test "SendEventRequest with state_key is passed through to Room.Server and stored in event" do
      # Given: a Room GenServer running with the sender as a member AND admin power level.
      # SEC Gate 1 fix: state events require :change_state power (state_default=50).
      # The sender must have power >= 50 to change state events.
      room_id = "!state-key-test:test.local"
      sender_id = "@kai:test.local"

      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

      on_exit(fn ->
        if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
          case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
            {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
            _ -> :ok
          end
        end
      end)

      :ok = Nebu.Matrix.Room.Server.join(room_id, sender_id)

      # Grant sender admin power (100 >= state_default 50) so the :change_state check passes.
      admin_power_levels = Nebu.Matrix.Room.PowerLevels.default_levels()
        |> Map.put("users", %{sender_id => 100})
      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, sender_id, admin_power_levels)

      content_bytes = Jason.encode!(%{"name" => "State Key Room"})

      # When: Server.send_event/2 is called with state_key = "custom-key" and is_state_event=true.
      # SEC Gate 1: is_state_event=true signals the event dispatcher to pass state_key as-is
      # (not nil), which triggers the :change_state power check in Room.Server.
      request = %Core.SendEventRequest{
        room_id: room_id,
        sender_id: sender_id,
        event_type: "m.room.name",
        state_key: "custom-key",
        is_state_event: true,
        txn_id: "txn-state-key-grpc-1",
        content: content_bytes,
        origin_ts: System.system_time(:millisecond)
      }

      stream = build_fake_stream(self())
      response = Server.send_event(request, stream)

      assert %Core.SendEventResponse{} = response
      assert String.starts_with?(response.event_id, "$"),
             "expected event_id to start with '$', got: #{response.event_id}"

      # Then: the persisted event must contain state_key = "custom-key"
      [{_, stored_event}] = :ets.lookup(:grpc_handler_state_key_db, {:event, response.event_id})
      assert stored_event["state_key"] == "custom-key",
             "expected state_key \"custom-key\" in stored event, got: #{inspect(stored_event["state_key"])}"
      assert stored_event["type"] == "m.room.name",
             "expected event type \"m.room.name\", got: #{inspect(stored_event["type"])}"
    end

    test "SendEventRequest with empty state_key stores empty string in event" do
      # Given: a Room GenServer running with the sender as a member AND admin power level.
      # SEC Gate 1 fix: even state events with state_key="" (like m.room.name) require
      # :change_state power. The sender must be an admin to change state events.
      room_id = "!state-key-empty:test.local"
      sender_id = "@kai:test.local"

      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

      on_exit(fn ->
        if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
          case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
            {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
            _ -> :ok
          end
        end
      end)

      :ok = Nebu.Matrix.Room.Server.join(room_id, sender_id)

      # Grant sender admin power (100 >= state_default 50).
      admin_power_levels = Nebu.Matrix.Room.PowerLevels.default_levels()
        |> Map.put("users", %{sender_id => 100})
      :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, sender_id, admin_power_levels)

      content_bytes = Jason.encode!(%{"name" => "Default State Key"})

      # When: Server.send_event/2 is called with state_key = "" (m.room.name uses empty state_key)
      # is_state_event=true signals this is a state event even though state_key="".
      request = %Core.SendEventRequest{
        room_id: room_id,
        sender_id: sender_id,
        event_type: "m.room.name",
        state_key: "",
        is_state_event: true,
        txn_id: "txn-state-key-grpc-2",
        content: content_bytes,
        origin_ts: System.system_time(:millisecond)
      }

      stream = build_fake_stream(self())
      response = Server.send_event(request, stream)

      assert %Core.SendEventResponse{} = response

      # Then: the persisted event must contain state_key = ""
      [{_, stored_event}] = :ets.lookup(:grpc_handler_state_key_db, {:event, response.event_id})
      assert stored_event["state_key"] == "",
             "expected state_key \"\" (empty) in stored event, got: #{inspect(stored_event["state_key"])}"
    end
  end
end
