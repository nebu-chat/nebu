defmodule Nebu.Matrix.EventDispatcher.AutoJoinJoinRuleTest do
  @moduledoc """
  Story `create-room-presets-power-levels-topic` (AC2(f), D1): the auto-join path (`ensure_auto_join_memberships/1`) calls
  `Room.Server.join/2` DIRECTLY and bypasses the join decision of `join_room/2` by design (admin policy: an operator flags a room
  as auto-join, new users are put into it). The enforcement of the join rule must therefore NOT break it: new users still join auto-join
  rooms whose join rule is `invite`, `private` or whose state cannot be read. The existing auto-join tests never put a join rule into
  their rooms, so they would stay green even if the enforcement leaked into this path: this suite is the guard.

  Ban (DECISION of the pipeline orchestrator, recorded in the Dev Agent Record of the story): the bypass is of the join RULE only. A user
  whose latest membership in the room is `ban` is NOT auto-joined (that is what the F-4 comment in `ensure_auto_join_memberships/1` always
  wanted: "previously-banned users are not re-added"); a membership that cannot be read is skipped as well (fail closed). The log names
  the room id and the error class only, never the user id.

  async: false: Horde, `:pg`, `Application.put_env` are process-global.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.EventDispatcher.Server

  @ets :auto_join_join_rule_test_db
  @user "@newcomer:test.local"

  defmodule FakeDB do
    @ets :auto_join_join_rule_test_db

    def load_members(room_id) do
      case :ets.lookup(@ets, {:room, room_id}) do
        [] -> {:error, :not_found}
        [{_, ms}] -> {:ok, :ets.match(@ets, {{:member, room_id, :"$1"}, :active}) |> Enum.map(fn [u] -> u end), ms, "{}"}
      end
    end

    def insert_room(room_id), do: (:ets.insert(@ets, {{:room, room_id}, System.system_time(:millisecond)}); {:ok, 0})
    def insert_member(room_id, user_id), do: (:ets.insert(@ets, {{:member, room_id, user_id}, :active}); :ok)
    def delete_member(room_id, user_id), do: (:ets.delete(@ets, {:member, room_id, user_id}); :ok)
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _json), do: :ok
    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    # messages_db_module: the auto-join rooms
    def list_auto_join_rooms, do: {:ok, :ets.match(@ets, {{:auto_join, :"$1"}, true}) |> List.flatten()}

    # rooms_db_module / messages_db_module reads the join decision of join_room/2 would use: they must NOT be consulted by auto-join
    def get_generic_state_events(room_id) do
      :ets.insert(@ets, {{:read, make_ref()}, {:state, room_id}})

      case :ets.lookup(@ets, {:rule, room_id}) do
        [{_, content}] -> {:ok, [%{type: "m.room.join_rules", state_key: "", content_json: Jason.encode!(content), sender: "@a:test.local", event_id: "$r", origin_server_ts: 1}]}
        [] -> {:error, :unavailable}
      end
    end

    def get_member_membership(room_id, user_id) do
      :ets.insert(@ets, {{:read, make_ref()}, {:membership, room_id, user_id}})

      case :ets.lookup(@ets, {:membership_error, room_id}) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          case :ets.lookup(@ets, {:membership, room_id, user_id}) do
            [{_, membership}] -> {:ok, membership}
            [] -> {:ok, nil}
          end
      end
    end
  end

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    snapshot =
      for {app, key} <- [{:room_manager, :db_module}, {:event_dispatcher, :messages_db_module}, {:event_dispatcher, :rooms_db_module}],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)

    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    end)

    :ok
  end

  defp auto_join_room(label, rule) do
    room_id = "!auto-#{label}-#{System.unique_integer([:positive])}:test.local"
    FakeDB.insert_room(room_id)
    :ets.insert(@ets, {{:auto_join, room_id}, true})
    if rule, do: :ets.insert(@ets, {{:rule, room_id}, rule})

    on_exit(fn ->
      case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
        {:ok, pid} -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end)
        _ -> :ok
      end
    end)

    room_id
  end

  defp member?(room_id, user_id), do: MapSet.member?(Nebu.Matrix.Room.Server.get_state(room_id).members, user_id)

  test "a new user is auto-joined into rooms whose join rule is invite, private, or whose state cannot be read (the join decision is not applied to the admin policy)" do
    rooms = for {label, rule} <- [invite: %{"join_rule" => "invite"}, private: %{"join_rule" => "private"}, unreadable: nil, public: %{"join_rule" => "public"}], do: {label, auto_join_room(label, rule)}

    assert :ok = Server.ensure_auto_join_memberships(@user)

    for {label, room_id} <- rooms, do: assert(member?(room_id, @user), "#{label}: joined by the auto-join bypass")
  end

  test "the auto-join path does not read the join rule state or the invitations: the only read is the ban check (the user's latest membership)" do
    room_id = auto_join_room("noreads", %{"join_rule" => "invite"})
    assert :ok = Server.ensure_auto_join_memberships(@user)
    assert member?(room_id, @user)

    reads = :ets.match(@ets, {{:read, :_}, :"$1"}) |> List.flatten()
    assert reads != [] and Enum.all?(reads, &(&1 == {:membership, room_id, @user})),
           "no join rule state read, nothing but the membership of the joining user (the auto-join ban check and the atomic check inside Room.Server.join/2): #{inspect(reads)}"
  end

  test "a user whose latest membership is ban is NOT auto-joined (the bypass is of the join rule only); the other rooms still are; the log has the room id and no user id" do
    banned_room = auto_join_room("banned", %{"join_rule" => "invite"})
    open_room = auto_join_room("not-banned", %{"join_rule" => "invite"})
    :ets.insert(@ets, {{:membership, banned_room, @user}, "ban"})
    :ets.insert(@ets, {{:membership, open_room, @user}, "leave"})

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Server.ensure_auto_join_memberships(@user) end)

    refute member?(banned_room, @user), "banned: not re-added by the auto-join"
    assert member?(open_room, @user), "a left (not banned) user is still auto-joined"
    assert log =~ banned_room, "the log names the room id"
    refute log =~ @user, "no user id in the log"
  end

  test "an unreadable membership fails closed: the room is skipped, the log names the room id and the error class only" do
    room_id = auto_join_room("unreadable-membership", %{"join_rule" => "invite"})
    :ets.insert(@ets, {{:membership_error, room_id}, :db_down})

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Server.ensure_auto_join_memberships(@user) end)

    refute member?(room_id, @user)
    assert log =~ room_id
    assert log =~ ":db_down"
    refute log =~ @user
  end
end
