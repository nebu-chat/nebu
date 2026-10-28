defmodule Nebu.Matrix.MembershipStateConcurrencyTest do
  @moduledoc """
  Story `membership-state-model`, AC8: the member slice is read from the database OUTSIDE the room process (no cache, a snapshot of committed events): a ban of D by A
  races ten concurrent `GET /members` calls of B and concurrent initial `/sync`s of B. REAL database, real `Room.Server` under Horde, the full router;
  `async: false`, tagged `:concurrency` (included in the integration run).

  Every scenario runs `@rounds` (default 30, the story's minimum; `NEBU_MEMBERSHIP_RACE_ROUNDS` can only RAISE it) rounds with a FRESH room; the racing
  requests start together behind a barrier (`ModerationTestSupport.race/1`); the INVARIANTS are asserted after each round, never a particular interleaving.
  A failing round prints its member-event sequence (membership and timestamps only, no reason text). The users are fresh per round (the sessions expire
  beyond the lookahead of `Session.RefreshWorker`, `ModerationTestSupport.user!/1`). The per-user rate limits are disabled (a round makes dozens of requests).

  The deterministic gap test (`SliceDB`) blocks ONE `/members` call right after its slice read returned: the ban commits inside the gap, the call is released and
  answers the snapshot it read (D as `join`, exactly once, `200`); the next call lists `ban`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * "every call STARTED after the ban's reply lists ban" is checked with monotonic timestamps around every request (the ban's reply time against the start of each
      read), plus one probe after the race. A `/sync` answer is read as the replay of its state and timeline (a slot inside the 20-event window is delivered in the
      timeline, never in both); the room has 21 messages after the setup so that D's join is outside the window.
    * "never twice": the member slots of D in `state` / in the `/members` chunk are at most / exactly ONE.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.MembershipStateTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport, only: [install_env!: 3]

  alias Nebu.Matrix.MembershipStateTestSupport.Hooks
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :concurrency
  @moduletag timeout: 900_000

  @rounds max(30, String.to_integer(System.get_env("NEBU_MEMBERSHIP_RACE_ROUNDS", "30")))

  setup do
    setup_env!()
    on_exit(&Hooks.disarm_all/0)
    :ok
  end

  defp seq(room, uid), do: room |> member_events(uid) |> Enum.map_join(" ", &"#{&1.content["membership"]}@#{&1.ts}")

  defp expect!(condition, round, room, uid, what) do
    if condition, do: :ok, else: flunk("round #{round}: #{what} (member events of D: #{seq(room, uid)})")
  end

  # runs `fun`, returns {result, started, finished} (monotonic microseconds)
  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, started, System.monotonic_time(:microsecond)}
  end

  # the membership of D in a /members answer: exactly ONE slot, else the problem is returned
  defp members_view(conn, d_uid) do
    with 200 <- conn.status,
         %{"chunk" => chunk} <- T.json(conn),
         [slot] <- Enum.filter(chunk, &(&1["state_key"] == d_uid)) do
      {:ok, slot["content"]["membership"]}
    else
      status when is_integer(status) -> {:error, {:status, status}}
      slots when is_list(slots) -> {:error, {:slots, length(slots)}}
      other -> {:error, other}
    end
  end

  # the membership of D at the end of an initial /sync answer: the replay of state, then timeline; at most one STATE slot of D
  defp sync_view(conn, room, d_uid) do
    with 200 <- conn.status,
         body = T.json(conn),
         state = join_state(body, room),
         true <- Enum.count(state, &(&1["type"] == "m.room.member" and &1["state_key"] == d_uid)) <= 1 do
      {:ok, replay(state ++ join_timeline(body, room))[d_uid]}
    else
      status when is_integer(status) -> {:error, {:status, status}}
      other -> {:error, other}
    end
  end

  defp fresh_round! do
    a = user!("MCA")
    b = user!("MCB")
    d = user!("MCD")
    room = public_room(a)
    join_now!(b, room)
    join_now!(d, room)
    # 21 messages: D's join leaves the 20-event window of an initial /sync
    for _ <- 1..21, do: say!(a, room, marker("race"))
    %{a: a, b: b, d: d, room: room}
  end

  describe "AC8 - a ban of D races concurrent /members calls and initial /syncs of B" do
    test "the sequential CONTROL: before the ban every read lists D as join, after it as ban (the invariants of the rounds are not vacuous)" do
      r = fresh_round!()

      assert members_view(members_conn(r.b, r.room), r.d.uid) == {:ok, "join"}
      assert sync_view(sync_conn(r.b, since: nil, timeout: 0), r.room, r.d.uid) == {:ok, "join"}
      ok!(ban(r.a, r.room, r.d, %{"reason" => "control"}), "ban")
      assert members_view(members_conn(r.b, r.room), r.d.uid) == {:ok, "ban"}
      assert sync_view(sync_conn(r.b, since: nil, timeout: 0), r.room, r.d.uid) == {:ok, "ban"}
    end

    test "every answer is 200 and lists D's slot exactly once as join (read before the commit) or ban (after); reads started after the ban's reply list ban" do
      tally = :counters.new(2, [])

      for round <- 1..@rounds do
        r = fresh_round!()
        read_members = fn -> timed(fn -> members_conn(r.b, r.room) end) end
        read_sync = fn -> timed(fn -> sync_conn(r.b, since: nil, timeout: 0) end) end

        results = race([fn -> timed(fn -> ban(r.a, r.room, r.d, %{"reason" => "race"}) end) end | List.duplicate(read_members, 10) ++ List.duplicate(read_sync, 4)])
        [{ban_conn, _ban_started, ban_finished} | reads] = results
        {member_reads, sync_reads} = Enum.split(reads, 10)

        expect!(ban_conn.status == 200, round, r.room, r.d.uid, "the ban answered #{ban_conn.status}")

        for {conn, started, _finished} <- member_reads do
          view = members_view(conn, r.d.uid)
          expect!(match?({:ok, m} when m in ["join", "ban"], view), round, r.room, r.d.uid, "/members: #{inspect(view)}")
          if started > ban_finished, do: expect!(view == {:ok, "ban"}, round, r.room, r.d.uid, "a /members call started after the ban's reply lists #{inspect(view)}")
          :counters.add(tally, if(view == {:ok, "ban"}, do: 2, else: 1), 1)
        end

        for {conn, started, _finished} <- sync_reads do
          view = sync_view(conn, r.room, r.d.uid)
          expect!(match?({:ok, m} when m in ["join", "ban"], view), round, r.room, r.d.uid, "initial /sync: #{inspect(view)}")
          if started > ban_finished, do: expect!(view == {:ok, "ban"}, round, r.room, r.d.uid, "an initial /sync started after the ban's reply lists #{inspect(view)}")
        end

        # the probe: a call that surely starts after the ban's reply
        expect!(members_view(members_conn(r.b, r.room), r.d.uid) == {:ok, "ban"}, round, r.room, r.d.uid, "the probe after the race")
        expect!(memberships(r.room, r.d.uid) == ["join", "ban"], round, r.room, r.d.uid, "D has exactly the join and the ban")
      end

      IO.puts("[AC8] /members answers over #{@rounds} rounds: join #{:counters.get(tally, 1)}, ban #{:counters.get(tally, 2)}")
    end
  end

  describe "AC8 - the deterministic gap: the slice is read BEFORE the commit" do
    test "a /members call blocked right after its slice read answers the snapshot (D as join, once, 200) although the ban commits meanwhile; the next call lists ban" do
      r = fresh_round!()
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: r.room, block: self()})
      reader = Task.async(fn -> members_conn(r.b, r.room) end)

      assert_receive {:ms_gap, victim, :slice_read}, 10_000

      # the ban commits while the reader sits between its slice read and its answer (the hook is disarmed first: later reads are plain)
      Hooks.disarm(:atdd_ms_slice)
      ok!(ban(r.a, r.room, r.d, %{"reason" => "gap"}), "ban in the gap")
      send(victim, :go)
      blocked = Task.await(reader, 20_000)

      assert members_view(blocked, r.d.uid) == {:ok, "join"}, "the answer is the snapshot read before the commit"
      assert members_view(members_conn(r.b, r.room), r.d.uid) == {:ok, "ban"}, "the next call lists the ban"
    end
  end
end
