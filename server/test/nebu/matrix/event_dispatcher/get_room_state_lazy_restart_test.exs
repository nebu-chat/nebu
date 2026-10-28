defmodule Nebu.Matrix.EventDispatcher.GetRoomStateLazyRestartTest do
  use ExUnit.Case, async: false

  # ─── bugfix/fix-room-management-error: GetRoomState lazy-restart tests ────────
  #
  # AC2 — GetRoomState lazy-restarts the Room GenServer after Core restart:
  #   When get_room_state is called for a room whose GenServer is not running
  #   (:noproc exit), the handler calls RoomSupervisor.start_room/1. If the room
  #   is in the DB, it loads successfully and the state is returned. (Story membership-state-model: the room status is read first, through
  #   rooms_db_module().get_room_status/1; a user caller is started only when his latest member event is `join`, the system role always.)
  #
  # AC3 — GetRoomState answers 403 for truly non-existent rooms (story membership-state-model, D6 (a); was NOT_FOUND):
  #   When get_room_state is called for a room that genuinely does not exist in
  #   the DB, the handler raises permission_denied / M_FORBIDDEN "You are not a member of this room" (also for the system caller): no `rooms` row, no room
  #   process, never an internal server error.
  #
  # These tests are written FIRST (ATDD red-phase gate), before the fix is applied.
  #
  # Red-phase summary:
  #   - AC2 (lazy-restart) FAILS before fix: pre-fix code calls lookup_room and
  #     raises NOT_FOUND immediately on :noproc without attempting start_room.
  #     The test expects get_room_state to succeed after the kill.
  #   - AC3 (ghost room): was "NOT_FOUND must be raised"; now the fixed 403 (see above).
  #
  # async: false — Horde.Registry, Horde.DynamicSupervisor, Application.put_env,
  # and ETS tables are all process-global resources.
  #
  # Test strategy:
  #   - Tests call Nebu.Matrix.EventDispatcher.Server.get_room_state/2 directly.
  #   - room_registry_module is set to Nebu.Matrix.Room.Server (the real module) so
  #     get_state/1 performs a real GenServer.call — which exits with :noproc
  #     when the process is dead, matching the production scenario.
  #   - FakeRoomDB is injected for Room.Server.init/1 so no PostgreSQL is needed.
  #     pre_seed_room/2 marks a room+member combo as known so insert_room fails
  #     for genuinely unknown rooms (mirrors server_receipts_test.exs pattern).
  #   - messages_db_module is overridden to avoid Ecto calls in build_state_events.
  #   - Fake stream: system caller (x-system-role=system) so membership check is
  #     bypassed — the tests focus on the lazy-restart path, not the IDOR check.

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeRoomDB ──────────────────────────────────────────────────────────────
  #
  # ETS-backed fake satisfying Nebu.Matrix.Room.DBBehaviour.
  # Injected via Application.put_env(:room_manager, :db_module, FakeRoomDB).
  #
  # NOTE (m2): This fake is defined inline rather than in test/support/ because
  # core/apps/event_dispatcher/test/support/ does not exist in this project.
  # Each test file in event_dispatcher/test/nebu/event_dispatcher/ defines its
  # own FakeRoomDB (same pattern as server_receipts_test.exs). If a shared
  # test/support/ directory is created in the future, consolidate all FakeRoomDB
  # definitions there.
  #
  # Key design for AC2 vs AC3:
  #   - Rooms pre-seeded with pre_seed_room/2 (table: :grs_lazy_test_db):
  #       load_members → {:ok, members, ts, "{}"}   (room exists in DB)
  #   - Rooms NOT pre-seeded:
  #       load_members → {:error, :not_found}        (room unknown to DB)
  #       insert_room  → {:error, :not_found}        (cannot create — no row)
  #       → Room.init returns {:stop, :not_found}
  #       → Horde.start_child returns {:error, _}
  #       → start_room returns {:error, _}
  #       → (membership-state-model) get_room_state raises the fixed 403 instead
  #
  # This mirrors the pre_seed_room pattern established in server_receipts_test.exs.

  defmodule FakeRoomDB do
    @behaviour Nebu.Matrix.Room.DBBehaviour

    def load_members(room_id) do
      case :ets.lookup(:grs_lazy_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:grs_lazy_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:grs_lazy_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    # insert_room only succeeds for rooms pre-seeded via pre_seed_room/1.
    # Rooms not pre-seeded return {:error, :not_found} so Room.init stops with :not_found.
    def insert_room(room_id) do
      case :ets.lookup(:grs_lazy_test_db, {:pre_seeded, room_id}) do
        [{_, true}] ->
          now_ms = System.system_time(:millisecond)
          :ets.insert(:grs_lazy_test_db, {{:room, room_id}, now_ms})
          {:ok, now_ms}

        [] ->
          {:error, :not_found}
      end
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:grs_lazy_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:grs_lazy_test_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:grs_lazy_test_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, json) do
      :ets.insert(:grs_lazy_test_db, {{:power_levels, room_id}, json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _last_event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: true
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    def list_auto_join_rooms(), do: {:ok, []}
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}

    # ─── Test helper: pre-seed a room so load_members returns {:ok, ...} ─────
    def pre_seed_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:grs_lazy_test_db, {{:pre_seeded, room_id}, true})
      :ets.insert(:grs_lazy_test_db, {{:room, room_id}, now_ms})
    end

    def pre_seed_room_with_member(room_id, user_id) do
      pre_seed_room(room_id)
      insert_member(room_id, user_id)
    end
  end

  # ─── FakeMessagesDB ──────────────────────────────────────────────────────────
  #
  # Prevents Ecto calls in build_state_events/2 (called after state is loaded).
  # Injected via Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB).

  defmodule FakeMessagesDB do
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # story membership-state-model (DELIBERATE re-pin, AC15 (f); old -> new): a room whose process is not running is resolved by
  # `ensure_room_without_lazy_create!/2`, which reads the room status through `rooms_db_module()`: a pre-seeded room is "active" (it is started from the
  # database: AC2 unchanged), every other id is unknown and answers 403 M_FORBIDDEN "You are not a member of this room" (AC3: was NOT_FOUND), no row, no process.
  defmodule FakeRoomsDB do
    def get_room_status(room_id) do
      case :ets.lookup(:grs_lazy_test_db, {:room, room_id}) do
        [] -> {:error, :not_found}
        [_row] -> {:ok, "active"}
      end
    end
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    # Guard against stale ETS table from --watch reruns.
    if :ets.info(:grs_lazy_test_db) != :undefined do
      :ets.delete(:grs_lazy_test_db)
    end

    :ets.new(:grs_lazy_test_db, [:named_table, :public, :set])

    # Inject FakeRoomDB for Room.Server.init/1 (Room GenServer uses db_module).
    Application.put_env(:room_manager, :db_module, FakeRoomDB)

    # Use the REAL Nebu.Matrix.Room.Server.get_state/1 so GenServer.call raises :noproc
    # when the process is dead — exactly as in production after a Core restart.
    Application.put_env(:event_dispatcher, :room_registry_module, Nebu.Matrix.Room.Server)

    # Inject fake messages DB so build_state_events/2 does not hit Ecto.
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeRoomsDB)

    Application.put_env(:event_dispatcher, :server_name, "test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :room_registry_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :server_name)

      if :ets.info(:grs_lazy_test_db) != :undefined do
        :ets.delete(:grs_lazy_test_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  # ─── Fake gRPC stream (system caller) ─────────────────────────────────────────
  #
  # System caller — no x-user-id, x-system-role="system".
  # Nebu.Matrix.Grpc.Metadata.trusted_identity/1 returns {nil, "system"}.
  # The membership check is bypassed for system callers (Story 7-33).
  # This isolates the lazy-restart path from the IDOR / membership logic.

  defp build_system_stream do
    %{http_request_headers: %{"x-system-role" => "system"}}
  end

  # ─── Helper: start a room and register on_exit cleanup ───────────────────────

  defp start_and_track_room(room_id) do
    {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
          {:ok, p} ->
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, p)

          _ ->
            :ok
        end
      end
    end)

    {:ok, pid}
  end

  # ─── AC2 — Lazy restart: room in DB but GenServer not running ─────────────────
  #
  # (The original red-phase note is gone: the lazy restart has been in place for a long time. Story membership-state-model: the room status is read first
  #  and a user caller is started only when his latest member event is `join`; the system caller of this suite always is.)
  #
  # SCENARIO:
  #   1. Pre-seed room + member in FakeRoomDB (simulates DB row from before restart).
  #   2. Start the Room GenServer (mimics the room being alive before restart).
  #   3. Kill the Room GenServer (mimics Core restart — process is gone).
  #   4. Call get_room_state → Room.Server.get_state raises :noproc.
  #   5. Handler catches :noproc, calls start_room → Room.init loads from FakeRoomDB.
  #   6. Handler calls get_state again → returns state with members.
  #   7. get_room_state returns %Core.GetRoomStateResponse{} with the expected member.

  describe "get_room_state/2 — AC2: lazy restart after Core restart" do
    test "returns GetRoomStateResponse when GenServer is dead but room exists in DB" do
      room_id = "!lazy-restart-ac2:test.local"
      member_id = "@alice:test.local"

      # 1. Pre-seed the room in FakeRoomDB so Room.init loads it successfully.
      FakeRoomDB.pre_seed_room_with_member(room_id, member_id)

      # 2. Start the Room GenServer (room is alive before simulated restart).
      {:ok, pid} = start_and_track_room(room_id)

      # 3. Kill the process to simulate Core restart (process gone, DB row intact).
      Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

      # Wait for the process to actually die before calling get_room_state.
      wait_for_exit(pid)

      # 4–7. get_room_state must succeed via lazy restart.
      #   Before fix: raises or returns NOT_FOUND (depends on pre-fix code path).
      #   After fix: catches :noproc, calls start_room, returns GetRoomStateResponse.
      request = %Core.GetRoomStateRequest{room_id: room_id}
      response = Server.get_room_state(request, build_system_stream())

      assert %Core.GetRoomStateResponse{} = response,
             "expected %Core.GetRoomStateResponse{} after lazy restart, " <>
               "but got: #{inspect(response)}. " <>
               "This means the handler did not attempt start_room on :noproc exit."

      assert member_id in response.members,
             "expected #{member_id} in response.members after lazy restart, " <>
               "got: #{inspect(response.members)}"
    end

    test "returns GetRoomStateResponse with all members after lazy restart with multiple members" do
      room_id = "!lazy-restart-multi:test.local"
      alice = "@alice-multi:test.local"
      bob = "@bob-multi:test.local"

      FakeRoomDB.pre_seed_room(room_id)
      FakeRoomDB.insert_member(room_id, alice)
      FakeRoomDB.insert_member(room_id, bob)

      {:ok, pid} = start_and_track_room(room_id)

      Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      wait_for_exit(pid)

      request = %Core.GetRoomStateRequest{room_id: room_id}
      response = Server.get_room_state(request, build_system_stream())

      assert %Core.GetRoomStateResponse{} = response
      assert alice in response.members
      assert bob in response.members
    end
  end

  # ─── AC3 — 403 M_FORBIDDEN for rooms that genuinely do not exist in the DB ────
  #
  # Verifies that the lazy-restart path does not introduce a regression where non-existent
  # rooms return an internal server error or create a room (story membership-state-model: 403).
  #
  # SCENARIO:
  #   1. Room NOT pre-seeded in FakeRoomDB (simulates room_id not in DB at all).
  #   2. Room GenServer NOT started (no `:noproc` shortcut needed — Room.Server
  #      get_state/1 will raise :noproc immediately for unknown rooms).
  #   3. Call get_room_state.
  #   4. The handler catches :noproc and reads the room status (rooms_db_module().get_room_status/1): the id is unknown.
  #   5. It raises Nebu.Matrix.Error permission_denied / M_FORBIDDEN "You are not a member of this room"; start_room is never called.
  #   6. No room process exists afterwards.

  describe "get_room_state/2 — AC3: 403 M_FORBIDDEN for non-existent rooms" do
    test "raises Nebu.Matrix.Error with permission_denied / M_FORBIDDEN for a room not in DB (also for the system caller)" do
      room_id = "!ghost-room-ac3:test.local"

      # Room is NOT pre-seeded — FakeRoomDB.insert_room will return {:error, :not_found}.
      # Room GenServer is also NOT running.

      request = %Core.GetRoomStateRequest{room_id: room_id}

      # We use try/rescue/catch instead of assert_raise because we need to distinguish
      # two different failure modes: a Nebu.Matrix.Error (correct) versus a raw :exit signal
      # with reason :noproc (pre-fix regression). assert_raise cannot catch :exit signals —
      # it only rescues exceptions — so an unhandled :noproc exit would bubble up and
      # crash the test with an unhelpful "exited" message rather than the clear flunk below.
      error =
        try do
          Server.get_room_state(request, build_system_stream())
          nil
        rescue
          e in Nebu.Matrix.Error -> e
        catch
          :exit, _ ->
            # Pre-fix: unhandled :noproc exit may escape — test catches it and fails.
            flunk(
              "Unhandled :exit escaped from get_room_state for non-existent room #{room_id}. " <>
                "The handler must catch :noproc and raise the fixed 403, not let exits propagate."
            )
        end

      refute is_nil(error),
             "expected Nebu.Matrix.Error to be raised for ghost room #{room_id}, " <>
               "but the handler returned nil (no exception raised). " <>
               "The handler must raise the fixed 403 for an unknown room."

      assert error.status == Nebu.Matrix.Status.permission_denied(),
             "expected permission_denied for a ghost room, got status #{error.status} (message: #{error.message})"

      assert error.errcode == "M_FORBIDDEN"
      assert {:error, :not_found} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id), "no room process was started"
    end

    test "the refusal text is fixed: it names neither the room id nor a caller" do
      room_id = "!ghost-room-msg:test.local"

      # We use try/rescue/catch instead of assert_raise for the same reason as the test above:
      # assert_raise only catches exceptions, not :exit signals. A pre-fix :noproc exit
      # would escape silently as a test crash rather than the explicit flunk message below.
      error =
        try do
          Server.get_room_state(
            %Core.GetRoomStateRequest{room_id: room_id},
            build_system_stream()
          )

          nil
        rescue
          e in Nebu.Matrix.Error -> e
        catch
          :exit, _ ->
            flunk("Unhandled :exit escaped — handler must catch :noproc and raise the fixed 403.")
        end

      refute is_nil(error)

      assert error.message == "You are not a member of this room"
      refute String.contains?(error.message, room_id)
    end
  end

  # ─── Deterministic exit-wait helper ──────────────────────────────────────────

  defp wait_for_exit(pid, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_exit(pid, deadline)
  end

  defp do_wait_for_exit(pid, deadline) do
    if Process.alive?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Process #{inspect(pid)} did not exit within timeout")
      else
        Process.sleep(5)
        do_wait_for_exit(pid, deadline)
      end
    else
      :ok
    end
  end
end
