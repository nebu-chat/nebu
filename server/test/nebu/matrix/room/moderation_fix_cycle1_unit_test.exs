defmodule Nebu.Matrix.Room.ModerationFixCycle1UnitTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, review cycle 1, UNIT half (no PostgreSQL; fakes through the existing seams):

    * review M1: the decline of a pending invitee whose room process cannot be started falls back to the out-of-process write ONLY for
      an ARCHIVED room; any other start failure (here: a failing read in `init/1`) is 503 and writes nothing.
    * Kassandra L-2 / review M3: `Room.Server.moderate/5` refuses a kick of a member whose latest membership is `ban` (`:target_banned`)
      for a sender with the kick level but not the ban level (kick 10, ban 50), and writes nothing.
    * review M2: `Room.Server.remove_member/2` is gone (no member is removed without its event by a production writer).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.Server

  @table :moderation_fix_cycle1_unit_db

  defmodule FakeDB do
    @moduledoc false
    @table :moderation_fix_cycle1_unit_db

    # the room process: `{:init_fail, room}` makes init/1 fail (a failing read, not an archived room); `{:archived, room}` archives it
    def load_members(room_id) do
      cond do
        :ets.lookup(@table, {:init_fail, room_id}) != [] -> {:error, :db_down}
        :ets.lookup(@table, {:room, room_id}) == [] -> {:error, :not_found}
        true -> {:ok, :ets.match(@table, {{:member, room_id, :"$1"}, :active}) |> List.flatten(), 0, "{}"}
      end
    end

    def insert_room(room_id) do
      :ets.insert(@table, {{:room, room_id}, 0})
      {:ok, 0}
    end

    def get_room_status(room_id), do: if(:ets.lookup(@table, {:archived, room_id}) != [], do: {:ok, "archived"}, else: {:ok, "active"})
    def load_room_settings(_room_id), do: {:ok, 0}
    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(_room_id, _json), do: :ok

    def insert_member(room_id, user_id) do
      :ets.insert(@table, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@table, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ok
    end

    def latest_member_event(room_id, user_id) do
      case :ets.lookup(@table, {:latest, room_id, user_id}) do
        [{_, latest}] -> {:ok, latest}
        [] -> {:ok, nil}
      end
    end

    def get_member_membership(room_id, user_id) do
      case latest_member_event(room_id, user_id) do
        {:ok, %{membership: m}} -> {:ok, m}
        other -> other
      end
    end

    def apply_member_change(room_id, user_id, event, opts) do
      :ets.insert(@table, {{:apply, make_ref()}, {room_id, user_id, event, opts}})
      if Keyword.get(opts, :remove_member, false), do: delete_member(room_id, user_id)
      if is_map(event), do: insert_event(event)
      :ok
    end

    # the dispatcher seams of the decline (messages and rooms seam: the personal-room guard)
    def get_personal_room_id(_user_id), do: {:ok, nil}
  end

  defmodule FakeInviteDB do
    @moduledoc false
    @table :moderation_fix_cycle1_unit_db

    def get_pending_invite_rooms_for_user(user_id), do: {:ok, :ets.match(@table, {{:pending, :"$1", user_id}, true}) |> List.flatten()}

    def reject_invitation(room_id, user_id) do
      :ets.insert(@table, {{:rejected, room_id, user_id}, true})
      :ok
    end
  end

  setup do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    keys = [room_manager: :db_module, event_dispatcher: :rooms_db_module, event_dispatcher: :messages_db_module, event_dispatcher: :invite_db_module, event_dispatcher: :server_name]
    prior = for {app, key} <- keys, do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      for {app, key, value} <- prior do
        case value do
          {:ok, v} -> Application.put_env(app, key, v)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    end)

    :ok
  end

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp events, do: :ets.match(@table, {{:event, :_}, :"$1"}) |> List.flatten()

  defp decline(room, user) do
    Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.leave_room(%Core.LeaveRoomRequest{room_id: room, user_id: user}, %{http_request_headers: %{}}) end)
  end

  defp pending_invitee(room) do
    user = "@inv#{rand()}:test.local"
    :ets.insert(@table, {{:room, room}, 0})
    :ets.insert(@table, {{:pending, room, user}, true})
    :ets.insert(@table, {{:latest, room, user}, %{membership: "invite", origin_server_ts: 1_000, sender: "@x:test.local", event_id: "$inv"}})
    user
  end

  describe "review M1 - the decline when the room process cannot be started" do
    test "a start failure of a room that is NOT archived is 503 and writes nothing (no out-of-process self-leave, no reject)" do
      room = "!m1fail#{rand()}:test.local"
      user = pending_invitee(room)
      :ets.insert(@table, {{:init_fail, room}, true})

      ExUnit.CaptureLog.capture_log(fn -> send(self(), {:result, decline(room, user)}) end)
      assert_received {:result, {:error, {503, _errcode, _text}}}
      assert events() == [], "no self-leave was written past the room process"
      assert :ets.lookup(@table, {:rejected, room, user}) == [], "the invitation stays pending"
    end

    test "an ARCHIVED room keeps the out-of-process decline: 200, the self-leave and the reject are written" do
      room = "!m1arch#{rand()}:test.local"
      user = pending_invitee(room)
      :ets.insert(@table, {{:archived, room}, true})

      assert {:ok, %Core.LeaveRoomResponse{}} = decline(room, user)
      assert [%{"type" => "m.room.member", "sender" => ^user, "content" => %{"membership" => "leave"}}] = events()
      assert :ets.lookup(@table, {:rejected, room, user}) != []
    end
  end

  describe "Kassandra L-2 / review M3 - a kick never lifts a ban" do
    test "kick 10, ban 50, sender at 20: the kick of a member whose latest membership is ban is {:error, :target_banned}, nothing is written" do
      room = "!l2#{rand()}:test.local"
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)
      on_exit(fn -> with {:ok, pid} <- Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), do: Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid) end)
      [owner, mod, target] = for l <- ~w(own mod tgt), do: "@#{l}#{rand()}:test.local"
      for u <- [owner, mod, target], do: assert(:ok = Server.join(room, u))
      levels = Server.default_power_levels() |> Map.merge(%{"kick" => 10, "ban" => 50, "users" => %{owner => 100, mod => 20}})
      assert :ok = Server.set_power_levels(room, owner, levels)
      :ets.insert(@table, {{:latest, room, target}, %{membership: "ban", origin_server_ts: 1_000, sender: owner, event_id: "$ban"}})
      :ets.match_delete(@table, {{:apply, :_}, :_})

      assert {:error, :target_banned} = Server.moderate(room, :kick, mod, target, nil)
      assert {:error, :target_banned} = Server.moderate(room, :kick, owner, target, nil)
      assert :ets.match(@table, {{:apply, :_}, :"$1"}) == [], "nothing is written"
      assert MapSet.member?(Server.get_state(room).members, target), "the member set is unchanged (a repeated ban repairs it)"
    end
  end

  describe "review M2 - no member removal without its event" do
    test "Room.Server.remove_member/2 does not exist any more" do
      Code.ensure_loaded!(Server)
      refute function_exported?(Server, :remove_member, 2)
    end
  end
end
