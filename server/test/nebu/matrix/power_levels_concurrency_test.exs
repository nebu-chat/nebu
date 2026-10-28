defmodule Nebu.Matrix.PowerLevelsConcurrencyTest do
  @moduledoc """
  Story `power-levels-enforcement` (follow-up `eq`), the gate evidence AC7: the power-level writer is serialised with kick / ban / send. REAL database,
  real `Room.Server` under Horde, the full router; `async: false`, tagged `:concurrency` (included in the integration run).

  Every scenario runs `@rounds` (default 50, the story's minimum; `NEBU_POWER_LEVELS_RACE_ROUNDS` can only RAISE it) rounds with a FRESH room and the
  racing requests start together behind a barrier (`ModerationTestSupport.race/1`); the INVARIANTS are asserted after each round, never a particular
  interleaving. A failing round prints its levels-event sequence (event ids shortened, timestamps, no content). The users are provisioned once per
  scenario and reused across the rounds (every round has its own room).

  The per-user rate limits are disabled for the races (a round makes dozens of requests; the tier has its own tests).

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC7 (a): "a demotion of a moderator (100 -> 0 by the creator)": under the v10 rule 7 a user at 100 cannot change another user at 100, so the
      creator stands at 150 (a seed) and the moderator at 100. "Every moderation STARTED after the demotion's reply is 403" is checked with
      monotonic timestamps taken around every request, plus one probe request after the race.
    * AC7 (d): "A at 100 demotes B (100 -> 50) while B tries to demote A" cannot be a race under rule 7 (equal levels: BOTH are refused, in every
      interleaving). It is pinned as exactly that (both 403, nothing written, 50 rounds) and the satisfiable analogue is raced: A (100) demotes B
      (60 -> 0) while B concurrently demotes C (50 -> 0): the outcome is one of the two serial orders, never B's change after A's demotion.
    * AC7 (c): "the latest event is the one committed last": the commit order is the transaction id of the event row, the chain is read from
      the `unsigned` of `/sync`.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :concurrency
  @moduletag timeout: 900_000

  @pl "m.room.power_levels"
  @rounds max(50, String.to_integer(System.get_env("NEBU_POWER_LEVELS_RACE_ROUNDS", "50")))

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── round helpers ───────────────────────────────────────────────────────────

  # the levels-event sequence of a round, for the failure message only: "ab12@1700000000000 cd34@1700000000001"
  defp seq(room), do: room |> pl_events() |> Enum.map_join(" ", &"#{String.slice(&1.event_id, 1, 4)}@#{&1.ts}")

  defp expect!(condition, round, room, what), do: assert(condition, "round #{round}: #{what} (levels events: #{seq(room)})")

  # runs `fun` and returns {result, started, finished} (monotonic microseconds)
  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, started, System.monotonic_time(:microsecond)}
  end

  defp status_of({conn, _started, _finished}), do: conn.status

  defp only_statuses!(results, allowed, round, room, what) do
    bad = results |> Enum.reject(&(status_of(&1) in allowed)) |> Enum.map(fn {conn, _, _} -> {conn.status, String.slice(conn.resp_body, 0, 80)} end)
    expect!(bad == [], round, room, "#{what}: unexpected answers #{inspect(bad)}")
  end

  # even targets are kicked, odd ones banned
  defp moderate(mod, room, target, i), do: if(rem(i, 2) == 0, do: kick(mod, room, target), else: ban(mod, room, target))

  # the transaction id of an event row (every event of the room process is its own transaction, serialised by the process: xid order = commit order)
  defp xmin_of(event_id), do: T.sql!("SELECT xmin::text::bigint FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()

  # the commit order of the levels events (the transaction id of the row; every event is its own transaction)
  defp commit_order(room) do
    T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY xmin::text::bigint, ctid", [room, @pl]).rows |> Enum.map(&hd/1)
  end

  defp agree!(room, round) do
    {col, event_content, mem} = sources(room)
    expect!(col == event_content, round, room, "the column and the latest levels event differ")
    expect!(col == mem, round, room, "the column and the in-memory levels differ")
    {id, ts, sender} = identity_row(room)
    expect!(memory_identity(room) == {id, ts, sender}, round, room, "the in-memory identity is not the latest levels event")
    col
  end

  # ═══ AC7 (a): a demotion against ten concurrent kicks / bans by the demoted moderator ═══

  describe "AC7 (a) - a demotion (100 -> 0) against 10 concurrent kicks / bans by the moderator" do
    test "no 500 / 503; a moderation started after the demotion's reply is 403; each 200 has its event, each refusal wrote nothing; sources agree" do
      owner = user!("RLO")
      mod = user!("RLM")
      targets = for _ <- 1..10, do: user!("RLT")

      for round <- 1..@rounds do
        room = public_room(owner)
        for u <- [mod | targets], do: join_now!(u, room)
        seed!(room, owner, levels(%{owner.uid => 150, mod.uid => 100}))
        demoted = update_in(column(room), ["users"], &Map.put(&1, mod.uid, 0))

        funs =
          [fn -> timed(fn -> put_pl(owner, room, demoted) end) end] ++
            for {t, i} <- Enum.with_index(targets), do: fn -> timed(fn -> moderate(mod, room, t, i) end) end

        [{demotion, _d_started, d_finished} | moderations] = race(funs)

        expect!(demotion.status == 200, round, room, "the demotion answered #{demotion.status} #{String.slice(demotion.resp_body, 0, 80)}")
        only_statuses!(moderations, [200, 403], round, room, "moderations")

        for {conn, started, _finished} <- moderations, started > d_finished do
          expect!(conn.status == 403, round, room, "a moderation started after the demotion's reply was #{conn.status}")
        end

        # one probe after the race: the demotion is committed, the moderator can do nothing any more
        probe = user!("RLP")
        join_now!(probe, room)
        expect!(kick(mod, room, probe).status == 403, round, room, "a kick after the demotion's reply is not 403")

        for {{conn, _, _}, t} <- Enum.zip(moderations, targets) do
          events = member_events(room, t.uid)
          memberships = Enum.map(events, & &1.content["membership"])

          if conn.status == 200 do
            last = List.last(events)
            expect!(events != [] and last.sender == mod.uid and List.last(memberships) in ["leave", "ban"], round, room, "a 200 moderation has no event written by the moderator")
            # the security invariant for EVERY accepted moderation, not only those started after the reply: it was decided on the levels BEFORE the demotion
            expect!(xmin_of(last.event_id) < xmin_of(latest_pl(room).event_id), round, room, "an accepted moderation was committed AFTER the demotion")
          else
            expect!(memberships == ["join"], round, room, "a refused moderation changed the target (#{inspect(memberships)})")
            expect!(in_set?(room, t.uid), round, room, "a refused moderation removed the target from the member set")
          end
        end

        expect!(agree!(room, round)["users"][mod.uid] == 0, round, room, "the stored levels do not show the demotion")
      end
    end
  end

  # ═══ AC7 (b): a raise of events[m.room.message] against ten concurrent sends ═══════════

  describe "AC7 (b) - raising events[m.room.message] to 50 against 10 concurrent sends by a user at 0" do
    test "no 500 / 503; a send started after the change's reply is 403; each 200 has its event, each refusal wrote nothing; sources agree" do
      owner = user!("RMO")
      sender = user!("RMS")

      for round <- 1..@rounds do
        room = public_room(owner)
        join_now!(sender, room)
        raised = update_in(column(room), ["events"], &Map.put(&1, "m.room.message", 50))

        funs = [fn -> timed(fn -> put_pl(owner, room, raised) end) end] ++ for(_ <- 1..10, do: fn -> timed(fn -> text_message(sender, room) end) end)
        [{change, _c_started, c_finished} | sends] = race(funs)

        expect!(change.status == 200, round, room, "the change answered #{change.status} #{String.slice(change.resp_body, 0, 80)}")
        only_statuses!(sends, [200, 403], round, room, "sends")

        for {conn, started, _finished} <- sends, started > c_finished do
          expect!(conn.status == 403, round, room, "a send started after the change's reply was #{conn.status}")
        end

        expect!(text_message(sender, room).status == 403, round, room, "a send after the change's reply is not 403")

        written = T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND sender = $2 AND event_type = 'm.room.message'", [room, sender.uid]).rows |> hd() |> hd()
        accepted = Enum.count(sends, &(status_of(&1) == 200))
        expect!(written == accepted, round, room, "#{written} message events for #{accepted} answers 200")

        # every accepted send (started before or after the reply) was committed BEFORE the raise: it was decided on the old level
        raise_xmin = xmin_of(latest_pl(room).event_id)
        late = T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND sender = $2 AND event_type = 'm.room.message'", [room, sender.uid]).rows |> Enum.map(&hd/1)
        expect!(Enum.all?(late, &(xmin_of(&1) < raise_xmin)), round, room, "an accepted send was committed AFTER the raise")

        expect!(agree!(room, round)["events"]["m.room.message"] == 50, round, room, "the stored levels do not show the change")
      end
    end
  end

  # ═══ AC7 (c): two admins write different contents ═══════════════════════════════════

  describe "AC7 (c) - two admins at 100 PUT different contents concurrently" do
    test "both 200 (serialised), the latest event is the one committed last, the column equals it, the chain is linear" do
      one = user!("RCA")
      two = user!("RCB")

      for round <- 1..@rounds do
        room = public_room(one)
        join_now!(two, room)
        seed!(room, one, levels(%{one.uid => 100, two.uid => 100}))
        base = column(room)
        initial = commit_order(room)

        [c1, c2] =
          race([
            fn -> put_pl(one, room, Map.put(base, "events_default", 11)) end,
            fn -> put_pl(two, room, Map.put(base, "events_default", 22)) end
          ])

        expect!(c1.status == 200 and c2.status == 200, round, room, "answers #{c1.status} / #{c2.status}: #{String.slice(c1.resp_body <> c2.resp_body, 0, 120)}")

        order = commit_order(room)
        expect!(length(order) == length(initial) + 2, round, room, "expected two new levels events")
        [first, last] = Enum.take(order, -2)
        expect!(Enum.sort([first, last]) == Enum.sort([T.json(c1)["event_id"], T.json(c2)["event_id"]]), round, room, "the new events are not the answered ids")

        by_ts = room |> pl_events() |> Enum.map(& &1.event_id)
        expect!(by_ts == order, round, room, "the timestamp order differs from the commit order")
        stamps = room |> pl_events() |> Enum.map(& &1.ts)
        expect!(stamps == Enum.sort(Enum.uniq(stamps)), round, room, "a timestamp tie in the slot")

        newest = latest_pl(room)
        expect!(newest.event_id == last, round, room, "the latest event is not the one committed last")
        expect!(agree!(room, round) == newest.content, round, room, "the column is not the latest content")

        ev = sync_pl(one, room)
        expect!(ev["event_id"] == last, round, room, "/sync shows another event than the last committed")
        expect!(get_in(ev, ["unsigned", "replaces_state"]) == first, round, room, "the predecessor of the last event is not the one committed before it")
      end
    end
  end

  # ═══ AC7 (d): mutual demotion ════════════════════════════════════════════════════════

  describe "AC7 (d) - A demotes B while B demotes A" do
    test "at equal levels (both 100) BOTH are refused in every interleaving (rule 7: a user at the sender's level cannot be changed): nothing written" do
      one = user!("RDA")
      two = user!("RDB")

      for round <- 1..@rounds do
        room = public_room(one)
        join_now!(two, room)
        seed!(room, one, levels(%{one.uid => 100, two.uid => 100}))
        base = column(room)
        before = pl_footprint(room)

        [c1, c2] =
          race([
            fn -> put_pl(one, room, put_in(base, ["users", two.uid], 50)) end,
            fn -> put_pl(two, room, put_in(base, ["users", one.uid], 50)) end
          ])

        expect!(c1.status == 403 and c2.status == 403, round, room, "answers #{c1.status} / #{c2.status}, both must be 403")
        expect!(pl_footprint(room) == before, round, room, "a refused change wrote something")
      end
    end

    test "A (100) demotes B (60 -> 0) while B demotes C (50 -> 0): the outcome is one of the two serial orders, never B's change after A's demotion" do
      a = user!("RDA")
      b = user!("RDB")
      c = user!("RDC")

      for round <- 1..@rounds do
        room = public_room(a)
        for u <- [b, c], do: join_now!(u, room)
        seed!(room, a, levels(%{a.uid => 100, b.uid => 60, c.uid => 50}))
        base = column(room)
        initial = commit_order(room)

        [ca, cb] =
          race([
            fn -> put_pl(a, room, put_in(base, ["users", b.uid], 0)) end,
            fn -> put_pl(b, room, put_in(base, ["users", c.uid], 0)) end
          ])

        expect!(ca.status == 200, round, room, "A's demotion answered #{ca.status} #{String.slice(ca.resp_body, 0, 80)}")
        expect!(cb.status in [200, 403], round, room, "B's change answered #{cb.status} #{String.slice(cb.resp_body, 0, 80)}")

        order = commit_order(room)
        final = agree!(room, round)
        expect!(final["users"][b.uid] == 0, round, room, "A's demotion is not in the stored levels")

        if cb.status == 200 do
          # B committed first: his event precedes A's demotion; B's change was made on B's level at that time (60 -> 0 applies to C only)
          expect!(length(order) == length(initial) + 2, round, room, "two new events expected")
          expect!(List.last(order) == T.json(ca)["event_id"], round, room, "B's change was committed after A's demotion")
        else
          expect!(length(order) == length(initial) + 1, round, room, "one new event expected")
          expect!(final["users"][c.uid] == 50, round, room, "a refused change altered C")
        end
      end
    end
  end
end
