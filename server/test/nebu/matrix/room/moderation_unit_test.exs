defmodule Nebu.Matrix.Room.ModerationUnitTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, UNIT half (no PostgreSQL; the real `Room.Server` / Horde / `:pg` run on a fake db module through the existing
  `:room_manager, :db_module` seam): AC5 (b), (c), AC8 (a), AC10 (a), AC11 (unit part) and the source pins of AC16. Everything the real SQL decides is in
  the real-database suites (`moderation_atomic_db_test.exs`, `moderation_concurrency_test.exs`, `moderation_routes_http_test.exs`).

  The fake models the real thing (lesson of the earlier stories): a join writes its own event, the optional reads exist as in `Nebu.Matrix.Room.DB`
  (`latest_member_event/2` with `event_id`, `pending_invitation/2`) and `apply_member_change/4` applies what the real transaction applies (delete the
  member, insert the event) and RECORDS every call.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The functions of the story that do not exist yet (`Room.Server.moderate/5`, `write_invite/5`, `write_decline/2`, `join/3`) are reached through
      `apply/3` with a variable name: the file compiles without warnings before the dev step.
    * The refusal shapes are `{:error, atom}` UNIFORMLY (like the existing join refusals): `:banned`, `:already_member`, `:membership_changed`, `:unsupported_db_module`,
      `:event_too_large`; `write_invite/5` answers `{:ok, event_id, ts}`, `moderate/5` exactly `:ok` (test review M-11 / M-12).
    * AC5 (c) pins the timeout case (a suspended room process, the 5 s call timeout of the story); the `:noproc` case is the same `catch :exit` branch.
    * AC16 (b): the four named suites are pinned by name, the dev records the full list of the 44 suites in the Completion Notes.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.Server

  @table :moderation_unit_test_db
  @lib Path.expand("../../../../lib", __DIR__)
  @test_dir Path.expand("../../..", __DIR__)

  # ─── the fake ────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc false
    @table :moderation_unit_test_db

    def load_members(room_id) do
      case :ets.lookup(@table, {:room, room_id}) do
        [] ->
          {:error, :not_found}

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
      count(:insert_member)
      :ets.insert(@table, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      count(:delete_member)
      :ets.delete(@table, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      count(:insert_event)
      :ets.insert(@table, {{:event, event["event_id"]}, event})
      :ok
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, json) do
      :ets.insert(@table, {{:power_levels, room_id}, json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}

    def latest_member_event(room_id, user_id) do
      case :ets.lookup(@table, {:latest, room_id, user_id}) do
        [{_, scripted}] -> scripted
        [] -> {:ok, nil}
      end
    end

    def get_member_membership(room_id, user_id) do
      case latest_member_event(room_id, user_id) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %{membership: m}} -> {:ok, m}
        other -> other
      end
    end

    def pending_invitation(room_id, user_id) do
      case :ets.lookup(@table, {:pending, room_id, user_id}) do
        [{_, invited_at}] -> {:ok, invited_at}
        [] -> {:ok, nil}
      end
    end

    def apply_member_change(room_id, user_id, event, opts) do
      count(:apply_member_change)
      :ets.insert(@table, {{:apply, make_ref()}, {room_id, user_id, event, opts}})

      case :ets.lookup(@table, :apply_fail) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          if Keyword.get(opts, :remove_member, false), do: :ets.delete(@table, {:member, room_id, user_id})
          if Keyword.get(opts, :reject_invitation, false), do: :ets.delete(@table, {:pending, room_id, user_id})
          if is_map(event), do: :ets.insert(@table, {{:event, event["event_id"]}, event})
          :ok
      end
    end

    defp count(name), do: :ets.update_counter(@table, {:calls, name}, 1, {{:calls, name}, 0})
  end

  # the db module of a suite that predates this story: everything but apply_member_change/4
  defmodule OldDB do
    @moduledoc false
    for {name, arity} <- FakeDB.__info__(:functions), name != :apply_member_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(FakeDB, unquote(name), unquote(args))
    end
  end

  # ─── setup / helpers ─────────────────────────────────────────────────────────

  setup do
    if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    :ets.new(@table, [:named_table, :public, :set])

    prior_db = Application.fetch_env(:room_manager, :db_module)
    prior_server = Application.fetch_env(:event_dispatcher, :server_name)
    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      restore(:room_manager, :db_module, prior_db)
      restore(:event_dispatcher, :server_name, prior_server)
      if :ets.info(@table) != :undefined, do: :ets.delete(@table)
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp user(label), do: "@#{label}#{rand()}:test.local"

  # fun may not exist yet: never a compile warning
  defp call(fun, args), do: apply(Server, fun, args)

  defp start_room do
    room = "!modu#{rand()}:test.local"
    {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)

    on_exit(fn ->
      if Process.whereis(Nebu.Matrix.Room.HordeSupervisor) != nil do
        case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
          {:ok, pid} ->
            if Process.alive?(pid), do: :sys.resume(pid)
            Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

          _ ->
            :ok
        end
      end
    end)

    room
  end

  # a room with `moderator` at 100 and the given joined `members`; `levels` are merged over the defaults
  defp room_with(moderator, members, levels \\ %{}) do
    room = start_room()
    assert :ok = Server.join(room, moderator)
    for m <- members, do: assert(:ok = Server.join(room, m))
    pl = Server.default_power_levels() |> put_in(["users", moderator], 100) |> Map.merge(levels)
    assert :ok = Server.set_power_levels(room, moderator, pl)
    reset_calls()
    room
  end

  defp reset_calls, do: :ets.match_delete(@table, {{:calls, :_}, :_})
  defp calls(name), do: :ets.lookup(@table, {:calls, name}) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  defp applies(room), do: :ets.match_object(@table, {{:apply, :_}, :_}) |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(elem(&1, 0) == room))

  defp script_latest(room, uid, membership, ts, event_id) do
    :ets.insert(@table, {{:latest, room, uid}, {:ok, %{membership: membership, origin_server_ts: ts, sender: "@x:test.local", event_id: event_id}}})
  end

  # moderate/5 answers exactly :ok on success and {:error, atom} on every refusal (the same shape as the existing join refusals)
  defp ok?(:ok), do: true
  defp ok?(_), do: false

  defp refused?({:error, atom}, atom), do: true
  defp refused?(_other, _atom), do: false

  # true when the source defines `def apply_member_change/4` (any patterns, guards allowed): found in the AST, not by a regex
  defp defines_apply_member_change_4?(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:def, _, [{:when, _, [{:apply_member_change, _, args}, _guard]} | _]} = node, acc when is_list(args) -> {node, acc or length(args) == 4}
        {:def, _, [{:apply_member_change, _, args} | _]} = node, acc when is_list(args) -> {node, acc or length(args) == 4}
        node, acc -> {node, acc}
      end)

    found?
  end

  # ═══ AC5 (b): no fallback to separate statements ═══════════════════════════════

  describe "AC5 (b) - a db module without apply_member_change/4" do
    test "moderate/5 answers {:error, :unsupported_db_module} for kick, ban and unban, writes nothing and NEVER falls back to separate statements" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      Application.put_env(:room_manager, :db_module, OldDB)

      for action <- [:kick, :ban, :unban] do
        # a valid decision for every action (an unban needs a banned target), so that only the missing function can refuse
        script_latest(room, t, if(action == :unban, do: "ban", else: "join"), System.system_time(:millisecond) - 1_000, "$latest")
        assert {:error, :unsupported_db_module} = call(:moderate, [room, action, mod, t, nil])
      end

      assert calls(:delete_member) == 0 and calls(:insert_event) == 0 and calls(:insert_member) == 0, "no sequential fallback"
      assert MapSet.member?(Server.get_state(room).members, t), "the in-memory state is unchanged"
    end

    test "the dispatcher answers 500 for it (the route maps the room's {:error, ...} to an internal error, never to a success)" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      Application.put_env(:room_manager, :db_module, OldDB)
      req = %Core.BanUserRequest{room_id: room, caller_id: mod, target_id: t, reason: ""}

      assert {:error, {500, _errcode, _text}} =
               Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(mod)) end)

      assert MapSet.member?(Server.get_state(room).members, t)
      assert calls(:delete_member) == 0 and calls(:insert_event) == 0
    end

    test "a failing apply_member_change/4 leaves the in-memory member set and the db state untouched and is {:error, _}" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      script_latest(room, t, "join", System.system_time(:millisecond) - 1_000, "$join")
      :ets.insert(@table, {:apply_fail, :boom})

      assert {:error, _reason} = call(:moderate, [room, :kick, mod, t, nil])
      assert MapSet.member?(Server.get_state(room).members, t)
      assert calls(:apply_member_change) == 1

      :ets.delete(@table, :apply_fail)
      assert ok?(call(:moderate, [room, :kick, mod, t, nil])), "a retry starts from the unchanged state"
      refute MapSet.member?(Server.get_state(room).members, t)
    end
  end

  # ═══ AC5 (c): a room process that does not answer ═══════════════════════════════

  describe "AC5 (c) - a room process that does not answer" do
    test "the dispatcher answers 503 M_UNAVAILABLE with the fixed text (the outcome is ambiguous only for the caller)" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = :sys.suspend(pid)

      request = %Core.BanUserRequest{room_id: room, caller_id: mod, target_id: t, reason: ""}
      result = Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ban_user(request, Nebu.Matrix.Http.stream(mod)) end)
      assert {:error, {503, "M_UNAVAILABLE", "The room did not answer, the change may or may not have been applied"}} = result

      # the call that timed out is still in the mailbox: when the room wakes up it is committed (or rolled back) there, never half applied
      :ok = :sys.resume(pid)
    end
  end

  # ═══ AC8 (a): the invite writer ═════════════════════════════════════════════════

  describe "AC8 (a) - Room.Server.write_invite/5 decides and writes the invite event" do
    test "a banned invitee: refused as banned, the row is rejected THROUGH apply_member_change/4 (no event), nothing else is written" do
      inviter = user("inv")
      t = user("t")
      room = room_with(inviter, [])
      script_latest(room, t, "ban", System.system_time(:millisecond) - 1_000, "$ban")
      :ets.insert(@table, {{:pending, room, t}, System.system_time(:millisecond)})

      assert refused?(call(:write_invite, [room, inviter, t, %{"membership" => "invite"}, 0]), :banned)

      assert [{^t, nil, opts}] = applies(room) |> Enum.map(fn {_room, uid, event, opts} -> {uid, event, opts} end)
      assert Keyword.get(opts, :reject_invitation) == true
      assert :ets.lookup(@table, {:pending, room, t}) == [], "the pending row is gone"
      assert calls(:insert_event) == 0
    end

    test "an invitee who is a member: refused as already_member, nothing written" do
      inviter = user("inv")
      t = user("t")
      room = room_with(inviter, [t])
      assert refused?(call(:write_invite, [room, inviter, t, %{"membership" => "invite"}, 0]), :already_member)
      assert applies(room) == [] and calls(:insert_event) == 0
    end

    test "an inviter who is not joined, and one below the invite level: refused, nothing written" do
      owner = user("own")
      stranger = user("str")
      low = user("low")
      t = user("t")
      room = room_with(owner, [low], %{"invite" => 50})

      for inviter <- [stranger, low] do
        assert {:error, reason} = call(:write_invite, [room, inviter, t, %{"membership" => "invite"}, 0])
        assert reason not in [:banned, :already_member]
      end

      assert applies(room) == []
    end

    test "the happy path returns {:ok, event_id, ts}, ts = max(now, not_before, latest + 1), written through apply_member_change/4" do
      inviter = user("inv")
      t = user("t")
      room = room_with(inviter, [])
      far = System.system_time(:millisecond) + 60_000
      script_latest(room, t, "leave", far, "$old")

      assert {:ok, event_id, ts} = call(:write_invite, [room, inviter, t, %{"membership" => "invite"}, 0])
      assert ts == far + 1
      assert [{^t, event, _opts}] = applies(room) |> Enum.map(fn {_room, uid, event, opts} -> {uid, event, opts} end)
      assert event["event_id"] == event_id
      assert event["sender"] == inviter and event["state_key"] == t and event["origin_server_ts"] == ts
      assert event["content"] == %{"membership" => "invite"}

      # not_before wins over a past latest
      t2 = user("t")
      assert {:ok, _id, ts2} = call(:write_invite, [room, inviter, t2, %{"membership" => "invite"}, far + 5_000])
      assert ts2 == far + 5_000
    end
  end

  describe "AC8 (a) - the old inline invite writer is gone from the dispatcher (source pin)" do
    test "do_invite! no longer builds the invite event itself: no emit_state_event_at call with \"m.room.member\"" do
      source = File.read!(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))
      refute Regex.match?(~r/emit_state_event_at\([^)]*"m\.room\.member"/, source), "the invite event is still built through emit_state_event_at"
      assert String.contains?(source, "Room.Server.write_invite("), "the invite path does not call Room.Server.write_invite/5"
    end
  end

  # ═══ AC10 (a): the join basis ═══════════════════════════════════════════════════

  describe "AC10 (a) - Room.Server.join/3 with the basis of the caller's decision" do
    test "a basis whose event id differs from the current latest member event is {:error, :membership_changed} and writes nothing" do
      owner = user("own")
      t = user("t")
      room = room_with(owner, [])
      script_latest(room, t, "invite", System.system_time(:millisecond) - 1_000, "$current")

      assert refused?(call(:join, [room, t, {:invited, "$stale"}]), :membership_changed)
      assert calls(:insert_member) == 0 and calls(:insert_event) == 0
      refute MapSet.member?(Server.get_state(room).members, t)
    end

    test "a matching basis joins; :any behaves as today; a row-only basis {:invited, nil} matches only while there is no member event" do
      owner = user("own")
      [t1, t2, t3, t4] = for _ <- 1..4, do: user("t")
      room = room_with(owner, [])

      script_latest(room, t1, "invite", System.system_time(:millisecond) - 1_000, "$e1")
      assert :ok = call(:join, [room, t1, {:invited, "$e1"}])

      assert :ok = call(:join, [room, t2, :any])

      assert :ok = call(:join, [room, t3, {:invited, nil}]), "no member event, row-only basis"

      script_latest(room, t4, "invite", System.system_time(:millisecond) - 1_000, "$e4")
      assert refused?(call(:join, [room, t4, {:invited, nil}]), :membership_changed), "an event appeared since the decision"

      members = Server.get_state(room).members
      assert MapSet.member?(members, t1) and MapSet.member?(members, t2) and MapSet.member?(members, t3)
      refute MapSet.member?(members, t4)
    end

    test "a ban between the decision and the join is still {:error, :banned} (the ban check precedes the basis)" do
      owner = user("own")
      t = user("t")
      room = room_with(owner, [])
      script_latest(room, t, "ban", System.system_time(:millisecond) - 1_000, "$ban")
      assert refused?(call(:join, [room, t, {:invited, "$stale"}]), :banned)
    end

    test "the internal joins (join/2: creator, upgrade, auto-join, Admin force-add) still work without a basis" do
      owner = user("own")
      t = user("t")
      room = room_with(owner, [])
      assert :ok = Server.join(room, t)
      assert MapSet.member?(Server.get_state(room).members, t)
    end
  end

  # ═══ AC11 (unit part): the size backstop ═════════════════════════════════════════

  describe "AC11 (unit) - Room.Server.moderate/5 called directly with a reason the router would have refused" do
    test "a 70 000-byte reason is {:error, :event_too_large}: nothing is written and the member stays" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      script_latest(room, t, "join", System.system_time(:millisecond) - 1_000, "$join")

      for action <- [:kick, :ban] do
        assert {:error, :event_too_large} = call(:moderate, [room, action, mod, t, String.duplicate("r", 70_000)])
      end

      assert calls(:apply_member_change) == 0 and calls(:insert_event) == 0
      assert MapSet.member?(Server.get_state(room).members, t)
    end

    test "the unban event carries the reason (and none for nil)" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [])
      script_latest(room, t, "ban", System.system_time(:millisecond) - 1_000, "$ban")

      assert ok?(call(:moderate, [room, :unban, mod, t, "welcome back"]))
      assert [{^t, event, _}] = applies(room) |> Enum.map(fn {_r, uid, event, opts} -> {uid, event, opts} end)
      assert event["content"] == %{"membership" => "leave", "reason" => "welcome back"}
      assert event["sender"] == mod and event["state_key"] == t
    end

    test "the member events are stamped max(now, latest + 1): a latest 60 s ahead of the clock gives exactly latest + 1" do
      mod = user("mod")
      t = user("t")
      room = room_with(mod, [t])
      far = System.system_time(:millisecond) + 60_000
      script_latest(room, t, "join", far, "$join")

      assert ok?(call(:moderate, [room, :ban, mod, t, nil]))
      assert [{^t, event, opts}] = applies(room) |> Enum.map(fn {_r, uid, event, opts} -> {uid, event, opts} end)
      assert event["origin_server_ts"] == far + 1
      assert event["content"] == %{"membership" => "ban"}
      assert Keyword.get(opts, :remove_member) == true, "a ban of a member is ONE transaction: remove + event"
    end
  end

  # ═══ AC16: source pins and seams ═════════════════════════════════════════════════

  describe "AC16 (a) - the member events are written by the room process only" do
    test "the dispatcher builds at most two m.room.member event maps (create_personal_room, archived decline); the old inline writers are gone" do
      dispatcher = File.read!(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))
      maps = Regex.scan(~r/^\s*"type"\s*=>\s*"m\.room\.member",\s*$/m, dispatcher)
      assert length(maps) <= 2, "event maps built with \"type\" => \"m.room.member\" in the dispatcher: #{length(maps)}"
      refute String.contains?(dispatcher, "remove_member_for_ban!"), "remove_member_for_ban!/2 is still there"
    end

    test "no other file of server/lib (outside Room.Server and the dispatcher) writes a member event map" do
      files = Path.wildcard(Path.join(@lib, "**/*.ex"))
      allowed = [Path.join(@lib, "nebu/matrix/room/server.ex"), Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex")]

      offenders =
        for f <- files, f not in allowed, File.read!(f) =~ ~r/^\s*"type"\s*=>\s*"m\.room\.member",\s*$/m, do: Path.relative_to(f, @lib)

      assert offenders == []
    end
  end

  describe "AC16 (b) - the fakes of the suites that reach kick / ban / unban / invite / decline implement apply_member_change/4" do
    for suite <- ~w(join_room_test invite_user_test create_room_invites_test server_moderation_metadata_test) do
      test "#{suite}.exs defines apply_member_change/4 in its fake db module" do
        path = Path.join(@test_dir, "nebu/matrix/event_dispatcher/#{unquote(suite)}.exs")
        assert defines_apply_member_change_4?(path), "#{unquote(suite)}.exs has no apply_member_change/4 in its fake"
      end
    end
  end

  describe "AC16 (c) - kick_user/2, ban_user/2, unban_user/2 keep their signatures and are thin" do
    test "the three functions are exported with arity 2 and delegate to Room.Server.moderate/5 (no event built or inserted there)" do
      Code.ensure_loaded!(Nebu.Matrix.EventDispatcher.Server)
      for fun <- [:kick_user, :ban_user, :unban_user], do: assert(function_exported?(Nebu.Matrix.EventDispatcher.Server, fun, 2))

      source = File.read!(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))
      start = :binary.match(source, "def kick_user(") |> elem(0)
      stop = :binary.match(source, "Handles POST /_matrix/client/v3/rooms/{roomId}/forget.") |> elem(0)
      region = binary_part(source, start, stop - start)

      assert String.contains?(region, "Room.Server.moderate("), "kick / ban / unban do not call Room.Server.moderate/5"
      refute String.contains?(region, "insert_event("), "the moderation region still inserts events itself"
      refute String.contains?(region, "EventId.generate("), "the moderation region still builds events itself"
      refute String.contains?(region, "persistent_term.get(:nebu_signing_key)"), "the moderation region still signs events itself"
    end
  end
end
