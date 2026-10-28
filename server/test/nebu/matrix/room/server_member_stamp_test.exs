defmodule Nebu.Matrix.Room.ServerMemberStampTest do
  @moduledoc """
  Story `member-event-prev-content` (epic oauth-broker, follow-up `ff`), AC2 (a), D4: the member events written by the user's OWN
  transitions are stamped strictly increasingly: `max(now_ms, latest member event ts of that slot + 1)`, so that an invitee who joins inside
  the clock lead of a createRoom invite (`eu` F-4: up to about 70 ms AHEAD of the clock) still gets a join event that is NEWER than the invite
  and therefore has the invite as its predecessor.

  Pure unit: a fake db module through the existing `:room_manager, :db_module` seam (the real `Room.Server`, Horde and :pg run; no
  PostgreSQL). The `+ 60_000` case is a FAKE on purpose (follow-up `fj`: a future-stamped event in the shared database breaks the `tick/0`
  of the HTTP suites); the real-database half of AC2 is in `member_prev_content_http_test.exs`.

  The fake models the real thing (lesson of the earlier stories): a join writes its OWN event through `insert_event/1`, and the db module
  offers the optional reads exactly as `Nebu.Matrix.Room.DB` does: `latest_member_event/2` -> `{:ok, %{membership, origin_server_ts, sender} |
  nil}` | `{:error, reason}` and `get_member_membership/2`. A second fake WITHOUT `latest_member_event/2` pins the fallback (unit fakes of
  the older suites).

  Decisions pinned here (ambiguities of the story text):

    * the join reads the latest member event with `latest_member_event/2` INSTEAD OF `get_member_membership/2` (one read, no extra query:
      the fake counts the calls, `get_member_membership/2` is NOT called when `latest_member_event/2` exists);
    * the ban refusal (`{:error, :banned}`) and the fail-closed refusal (`{:error, :membership_unavailable}`) are unchanged for both reads;
    * the join's `member_identity` keeps the REAL stamped timestamp (`{event_id, origin_server_ts}`).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.Server

  @table :member_stamp_test_db

  # ─── fakes ───────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc false
    @table :member_stamp_test_db

    def load_members(room_id) do
      case :ets.lookup(@table, {:room, room_id}) do
        [] -> {:error, :not_found}
        [{_, created_at_ms}] ->
          members = :ets.match(@table, {{:member, room_id, :"$1"}, :active})
          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, "{}"}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@table, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

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

    def set_power_levels(room_id, json) do
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}

    # the optional reads, scripted per (room, user); every call is counted
    def latest_member_event(room_id, user_id) do
      count(:latest_member_event)

      case :ets.lookup(@table, {:latest, room_id, user_id}) do
        [{_, scripted}] -> scripted
        [] -> {:ok, nil}
      end
    end

    def get_member_membership(room_id, user_id) do
      count(:get_member_membership)

      case :ets.lookup(@table, {:membership, room_id, user_id}) do
        [{_, scripted}] -> scripted
        [] -> {:ok, nil}
      end
    end

    defp count(name), do: :ets.update_counter(@table, {:calls, name}, 1, {{:calls, name}, 0})
  end

  # the db module of an older unit suite: no latest_member_event/2, only get_member_membership/2
  defmodule FakeDBWithoutLatest do
    @moduledoc false
    defdelegate load_members(room_id), to: FakeDB
    defdelegate insert_room(room_id), to: FakeDB
    defdelegate insert_member(room_id, user_id), to: FakeDB
    defdelegate delete_member(room_id, user_id), to: FakeDB
    defdelegate insert_event(event), to: FakeDB
    defdelegate set_power_levels(room_id, json), to: FakeDB
    defdelegate load_room_settings(room_id), to: FakeDB
    defdelegate get_room_status(room_id), to: FakeDB
    defdelegate get_member_membership(room_id, user_id), to: FakeDB
  end

  # ─── setup ───────────────────────────────────────────────────────────────────

  setup do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    # snapshot / restore (config/runtime.exs may set the key): never a bare delete
    prior = Application.fetch_env(:room_manager, :db_module)
    Application.put_env(:room_manager, :db_module, FakeDB)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:room_manager, :db_module, value)
        :error -> Application.delete_env(:room_manager, :db_module)
      end

      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    end)

    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp start_room do
    room_id = "!stamp#{rand()}:test.local"
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
          {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
          _ -> :ok
        end
      end
    end)

    room_id
  end

  defp user, do: "@stamp#{rand()}:test.local"

  defp script_latest(room_id, user_id, ts, membership \\ "invite") do
    :ets.insert(@table, {{:latest, room_id, user_id}, {:ok, %{membership: membership, origin_server_ts: ts, sender: "@inviter:test.local"}}})
  end

  defp calls(name), do: :ets.lookup(@table, {:calls, name}) |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  # the member events of `user_id` the room wrote, as {membership, origin_server_ts, event_id}
  defp member_events(room_id, user_id) do
    :ets.match_object(@table, {{:event, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1["room_id"] == room_id and &1["type"] == "m.room.member" and &1["state_key"] == user_id))
    |> Enum.map(&{&1["content"]["membership"], &1["origin_server_ts"], &1["event_id"]})
  end

  defp clock, do: System.system_time(:millisecond)

  # ═══ the join ═════════════════════════════════════════════════════════════════

  describe "AC2 (a) - the join is stamped max(now, latest + 1)" do
    test "a latest member event 60 s AHEAD of the clock: the join event is stamped exactly latest + 1, and member_identity keeps the real stamp" do
      room = start_room()
      u = user()
      latest = clock() + 60_000
      script_latest(room, u, latest)

      assert :ok = Server.join(room, u)

      assert [{"join", ts, event_id}] = member_events(room, u)
      assert ts == latest + 1, "the join must be strictly newer than the invite it follows: #{ts} vs #{latest}"
      assert Server.get_state(room).member_identity[u] == {event_id, latest + 1}, "the synthesized member state anchors on the persisted identity"
    end

    test "a latest member event in the PAST: the join is stamped with the clock (never older than the clock, newer than the latest)" do
      room = start_room()
      u = user()
      latest = clock() - 30_000
      script_latest(room, u, latest)

      before = clock()
      assert :ok = Server.join(room, u)
      after_ms = clock()

      assert [{"join", ts, _}] = member_events(room, u)
      assert ts >= before and ts <= after_ms, "stamped with now_ms, got #{ts} outside [#{before}, #{after_ms}]"
      assert ts > latest
    end

    test "no latest member event at all ({:ok, nil}): the join is stamped with the clock" do
      room = start_room()
      u = user()

      before = clock()
      assert :ok = Server.join(room, u)
      after_ms = clock()

      assert [{"join", ts, _}] = member_events(room, u)
      assert ts >= before and ts <= after_ms
    end

    test "the ban check and the stamp share ONE read: latest_member_event/2 once, get_member_membership/2 not at all (no extra query per join)" do
      room = start_room()
      u = user()

      assert :ok = Server.join(room, u)

      assert calls(:latest_member_event) == 1
      assert calls(:get_member_membership) == 0, "the join reads the latest member event INSTEAD of the bare membership"
    end

    test "a banned user (latest member event is a ban) is refused, no join event is written, the member set is unchanged" do
      room = start_room()
      u = user()
      script_latest(room, u, clock() - 1_000, "ban")

      assert {:error, :banned} = Server.join(room, u)

      assert member_events(room, u) == []
      refute MapSet.member?(Server.get_state(room).members, u)
    end

    test "a failing read refuses the join (fail closed, :membership_unavailable), no event, no member" do
      room = start_room()
      u = user()
      :ets.insert(@table, {{:latest, room, u}, {:error, :db_down}})

      assert {:error, :membership_unavailable} = Server.join(room, u)

      assert member_events(room, u) == []
      refute MapSet.member?(Server.get_state(room).members, u)
    end
  end

  describe "AC2 (a) - a db module WITHOUT latest_member_event/2 falls back to get_member_membership/2 and now" do
    setup do
      Application.put_env(:room_manager, :db_module, FakeDBWithoutLatest)
      :ok
    end

    test "a ban still refuses the join, an error still refuses it (fail closed), a leave joins with the clock stamp" do
      banned_room = start_room()
      banned = user()
      :ets.insert(@table, {{:membership, banned_room, banned}, {:ok, "ban"}})
      assert {:error, :banned} = Server.join(banned_room, banned)
      assert member_events(banned_room, banned) == []

      error_room = start_room()
      erroring = user()
      :ets.insert(@table, {{:membership, error_room, erroring}, {:error, :db_down}})
      assert {:error, :membership_unavailable} = Server.join(error_room, erroring)
      assert member_events(error_room, erroring) == []

      ok_room = start_room()
      fine = user()
      :ets.insert(@table, {{:membership, ok_room, fine}, {:ok, "leave"}})
      before = clock()
      assert :ok = Server.join(ok_room, fine)
      after_ms = clock()

      assert [{"join", ts, _}] = member_events(ok_room, fine)
      assert ts >= before and ts <= after_ms, "no latest_member_event/2: the stamp falls back to now_ms"
      assert calls(:get_member_membership) == 3
    end
  end

  describe "the production db module never takes the fallback of Room.Server.check_not_banned/2" do
    test "Nebu.Matrix.Room.DB exports latest_member_event/2 (ban check + stamp in one read) and get_member_membership/2" do
      # review cycle 1, MINOR-2: check_not_banned/2 picks the reader with function_exported?/3; if the real module ever lost latest_member_event/2
      # the join would silently fall back to get_member_membership/2 and now_ms (no stamp), and a fake-only suite would not notice
      assert Code.ensure_loaded?(Nebu.Matrix.Room.DB)
      assert function_exported?(Nebu.Matrix.Room.DB, :latest_member_event, 2)
      assert function_exported?(Nebu.Matrix.Room.DB, :get_member_membership, 2)
    end
  end

  # ═══ the leave ════════════════════════════════════════════════════════════════

  describe "AC2 (a) - the leave is stamped max(now, latest + 1)" do
    test "a latest member event 60 s ahead of the clock: the leave event is stamped exactly latest + 1" do
      room = start_room()
      u = user()
      assert :ok = Server.join(room, u)

      latest = clock() + 60_000
      script_latest(room, u, latest, "join")
      assert :ok = Server.leave(room, u)

      assert [{"leave", ts, _}] = for {"leave", _, _} = e <- member_events(room, u), do: e
      assert ts == latest + 1
      refute MapSet.member?(Server.get_state(room).members, u)
    end

    test "a latest member event in the past or none: the leave is stamped with the clock" do
      room = start_room()
      u = user()
      assert :ok = Server.join(room, u)
      script_latest(room, u, clock() - 30_000, "join")

      before = clock()
      assert :ok = Server.leave(room, u)
      after_ms = clock()

      assert [{"leave", ts, _}] = for {"leave", _, _} = e <- member_events(room, u), do: e
      assert ts >= before and ts <= after_ms
    end

    test "a FAILING read stamps the clock and the leave itself still succeeds (it was never gated by that read)" do
      room = start_room()
      u = user()
      assert :ok = Server.join(room, u)
      :ets.insert(@table, {{:latest, room, u}, {:error, :db_down}})

      before = clock()
      assert :ok = Server.leave(room, u)
      after_ms = clock()

      assert [{"leave", ts, _}] = for {"leave", _, _} = e <- member_events(room, u), do: e
      assert ts >= before and ts <= after_ms
      refute MapSet.member?(Server.get_state(room).members, u), "the member is removed although the read failed"
    end

    test "a db module without latest_member_event/2: the leave is stamped with the clock and succeeds" do
      Application.put_env(:room_manager, :db_module, FakeDBWithoutLatest)
      room = start_room()
      u = user()
      assert :ok = Server.join(room, u)

      before = clock()
      assert :ok = Server.leave(room, u)
      after_ms = clock()

      assert [{"leave", ts, _}] = for {"leave", _, _} = e <- member_events(room, u), do: e
      assert ts >= before and ts <= after_ms
    end
  end
end
