defmodule Nebu.Matrix.EventDispatcher.AutoJoinOptOutTest do
  use ExUnit.Case, async: false

  # ─── Story rm5-personal-guards-optout — AC4 + AC5 + AC6 ─────────────────────
  #
  # ATDD — written FIRST (before the opt-out implementation).
  #
  # AC4: a successful leave_room/2 of an is_auto_join room writes an opt-out row
  #      for (room_id, user_id) (idempotent upsert).
  # AC5: ensure_auto_join_memberships/1 and ensure_auto_join_space_memberships/1
  #      SKIP any (room_id, user_id) present in the opt-out table — the left room
  #      is NOT re-joined.
  # AC6 (regression): a user who has NOT opted out IS still re-joined.
  #
  # async: false — Application.put_env/3 + :pg are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  # Distinctive room ids so this suite never collides with rooms started by other
  # suites in the shared Horde registry (e.g. auto_join_rooms_test's !general).
  @user_id "@rm5optout-alice:nebu.local"
  @auto_join_room "!rm5optout-autojoin:nebu.local"
  @normal_room "!rm5optout-normal:nebu.local"

  # ─── Fake rooms DB: records opt-out writes + reports auto-join + opt-outs ────
  #
  # ETS keys:
  #   {:auto_join, room_id} → bool   (auto_join_room?/1 source)
  #   {:opt_out, room_id, user_id} → ts   (insert_auto_join_opt_out writes this)
  defmodule FakeRoomsDB do
    def auto_join_room?(room_id) do
      case :ets.lookup(:opt_out_test, {:auto_join, room_id}) do
        [{_, v}] -> {:ok, v}
        [] -> {:ok, false}
      end
    end

    def insert_auto_join_opt_out(room_id, user_id, ts) do
      :ets.insert(:opt_out_test, {{:opt_out, room_id, user_id}, ts})
      :ok
    end

    def opted_out?(room_id, user_id) do
      case :ets.lookup(:opt_out_test, {:opt_out, room_id, user_id}) do
        [{_, _ts}] -> {:ok, true}
        [] -> {:ok, false}
      end
    end

    def delete_member(_room_id, _user_id), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
  end

  # ─── Fake messages DB: source of the auto-join list + opt-out read (AC5) ─────
  # ensure_auto_join_memberships/1 reads list_auto_join_rooms/0 and (rm5) opted_out?/2
  # from messages_db_module(). Backed by the same ETS table as FakeRoomsDB so a write
  # via the leave path is visible to the ensure path.
  defmodule FakeMessagesDB do
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def insert_event(_event), do: :ok

    # NOTE: nested module does not inherit @auto_join_room — keep this literal in
    # sync with @auto_join_room above.
    def list_auto_join_rooms, do: {:ok, ["!rm5optout-autojoin:nebu.local"]}
    def list_auto_join_spaces, do: {:ok, []}

    def opted_out?(room_id, user_id) do
      case :ets.lookup(:opt_out_test, {:opt_out, room_id, user_id}) do
        [{_, _ts}] -> {:ok, true}
        [] -> {:ok, false}
      end
    end
  end

  defmodule FakeInviteDB do
    def reject_invitation(_room_id, _user_id), do: :ok
  end

  # ─── Fake room_manager DB so a started Room.Server stays alive ──────────────
  # ensure_auto_join_memberships/1 calls RoomSupervisor.start_room/1 which starts a
  # real Room.Server. Its init/1 calls db_module().load_members/1; with this fake the
  # GenServer starts cleanly so registry assertions are deterministic (no init crash).
  defmodule FakeRoomManagerDB do
    # Intentionally NOT @behaviour DBBehaviour — this is a minimal room_manager fake
    # used only so a started Room.Server survives init; it does not implement the
    # auto-join list callbacks (those go through messages_db_module() / FakeMessagesDB).
    def load_members(_room_id), do: {:ok, [], System.system_time(:millisecond), "{}"}
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def delete_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _json), do: :ok
    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: true
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
  end

  setup do
    if :ets.info(:opt_out_test) != :undefined, do: :ets.delete(:opt_out_test)
    :ets.new(:opt_out_test, [:named_table, :public, :set])
    # @auto_join_room is an auto-join room; @normal_room is not.
    :ets.insert(:opt_out_test, {{:auto_join, @auto_join_room}, true})

    Application.put_env(:event_dispatcher, :rooms_db_module, FakeRoomsDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:room_manager, :db_module, FakeRoomManagerDB)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :invite_db_module)
      Application.delete_env(:room_manager, :db_module)
      # Terminate any room started during the test.
      for rid <- [@auto_join_room, @normal_room] do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(rid) do
          {:ok, pid} ->
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

          _ ->
            :ok
        end
      end
      if :ets.info(:opt_out_test) != :undefined, do: :ets.delete(:opt_out_test)
    end)

    :ok
  end

  # Poll the Horde registry until the room appears (async propagation) or timeout.
  defp wait_for_room(room_id, retries \\ 30) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ when retries > 0 ->
        Process.sleep(10)
        wait_for_room(room_id, retries - 1)
      _ -> {:error, :not_found}
    end
  end

  defp leave_req(room_id, user_id),
    do: %Core.LeaveRoomRequest{room_id: room_id, user_id: user_id}

  # ─── AC4: leaving an auto-join room records an opt-out ──────────────────────
  test "AC4: successful leave of an auto-join room writes an opt-out row" do
    # Room GenServer not running → {:error, :not_found} fallback path: still a
    # successful leave (returns LeaveRoomResponse) and must record the opt-out.
    resp = Server.leave_room(leave_req(@auto_join_room, @user_id), %{http_request_headers: %{}})
    assert %Core.LeaveRoomResponse{room_id: @auto_join_room} = resp

    assert :ets.lookup(:opt_out_test, {:opt_out, @auto_join_room, @user_id}) != [],
           "expected an opt-out row for the left auto-join room"
  end

  # ─── AC6: leaving a NON-auto-join room records NO opt-out ────────────────────
  test "AC6: leaving a normal (non-auto-join) room records no opt-out" do
    resp = Server.leave_room(leave_req(@normal_room, @user_id), %{http_request_headers: %{}})
    assert %Core.LeaveRoomResponse{room_id: @normal_room} = resp

    assert :ets.lookup(:opt_out_test, {:opt_out, @normal_room, @user_id}) == []
  end

  # Deterministic clean slate: terminate any residual room and poll for absence so
  # a leaked Horde registry entry from a prior test cannot make the assertion flaky.
  defp ensure_room_absent(room_id, retries \\ 50) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        :ok

      {:ok, pid} when retries > 0 ->
        Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
        Process.sleep(10)
        ensure_room_absent(room_id, retries - 1)

      _ ->
        :ok
    end
  end

  # ─── AC5: ensure_auto_join_memberships/1 skips opted-out rooms ──────────────
  test "AC5: an opted-out auto-join room is NOT re-joined on next login" do
    # Clean slate (defend against registry residue from a prior test in the suite).
    ensure_room_absent(@auto_join_room)

    # Pre-seed an opt-out for the auto-join room.
    :ets.insert(:opt_out_test, {{:opt_out, @auto_join_room, @user_id}, 123})

    # ensure_auto_join_memberships must filter out the opted-out room BEFORE
    # start_room/join — so the room GenServer is never started for it.
    assert :ok = Server.ensure_auto_join_memberships(@user_id)

    # Give any (erroneous) async start a chance, then assert it never happened.
    Process.sleep(100)

    assert {:error, :not_found} =
             Nebu.Matrix.Room.RoomSupervisor.lookup_room(@auto_join_room),
           "opted-out auto-join room must not be started/joined"
  end

  # ─── AC6: a non-opted-out auto-join room IS still re-joined ──────────────────
  test "AC6: a non-opted-out auto-join room IS processed on next login" do
    # No opt-out seeded → ensure_auto_join_memberships should process the room:
    # start_room/1 starts the Room.Server (kept alive by FakeRoomManagerDB).
    assert :ok = Server.ensure_auto_join_memberships(@user_id)

    assert {:ok, _pid} = wait_for_room(@auto_join_room),
           "non-opted-out auto-join room must be started/joined"
  end
end
