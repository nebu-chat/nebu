defmodule Nebu.Matrix.StateWriterRedactionConcurrencyTest do
  @moduledoc """
  Story `state-writer-redaction`, AC9: the redaction writer and the generic state writer are serialised with power-level changes and kicks. REAL database,
  real `Room.Server` under Horde, the full router; `async: false`, tagged `:concurrency` (included in the integration run).

  Every scenario runs `@rounds` (default 50, the story's minimum; `NEBU_STATE_WRITER_RACE_ROUNDS` can only RAISE it) rounds with a FRESH room; the racing
  requests start together behind a barrier (`ModerationTestSupport.race/1`); the INVARIANTS are asserted after each round, never a particular interleaving. A
  failing round prints the event sequence of the slot it races on (event ids shortened, timestamps, no message content or reason). The users are provisioned
  once per scenario and reused across rounds (every round has its own room); their sessions expire beyond the lookahead of `Session.RefreshWorker`
  (`ModerationTestSupport.user!/1`), so a long run never answers `401 M_UNKNOWN_TOKEN`.

  The per-user rate limits are disabled for the races (the `moderation` tier would charge the levels changes and kicks of 50 rounds; the tiers have their
  own tests).

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC9 (a): "a demotion of a moderator (100 -> 0 by a creator seeded at 150)". The ten messages are written by a third user, the moderator redacts them
      concurrently with his demotion. "Every redaction STARTED after the demotion's reply is 403" is checked with monotonic timestamps around every request, plus
      one probe request after the race. The commit-order invariant of the story ("each 200 has its row; each refusal wrote nothing") is strengthened: every
      ACCEPTED redaction row precedes the demotion event in commit order (the transaction id of the row, `xmin`).
    * AC9 (b): the member at 50 sets topics while the creator raises `events["m.room.topic"]` to 100; the topic events of the member are counted against the
      answers 200 and every one precedes the levels event in commit order.
    * AC9 (c): the kick removes the member who concurrently PUTs topics (he is at 50) and redacts his own messages; none STARTED after the kick's reply succeeds
      and every accepted event precedes the kick's member event in commit order.
    * AC9 (d): the second writer of the slot is a user at 50 (`state_default`); "the `prev_content` chain is linear" is read from the `unsigned` of the latest
      event in `/sync` (`replaces_state`, `prev_content`) and the commit order (`xmin`) must equal the timestamp order.
    * AC9 (e) (rewritten by Kassandra #1): the second redactor is a moderator at 50; a redaction of an already redacted target is idempotent, so both racing requests answer the SAME event id and exactly one row exists (also with ten requests of one user).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport
  import Nebu.Matrix.RedactionTestSupport

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :concurrency
  @moduletag timeout: 900_000

  @topic "m.room.topic"
  @rounds max(50, String.to_integer(System.get_env("NEBU_STATE_WRITER_RACE_ROUNDS", "50")))

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── round helpers ───────────────────────────────────────────────────────────

  # the event sequence of one slot for the failure message only: "ab12@1700000000000 cd34@1700000000001"
  defp seq(room, type), do: room |> slot_events(type) |> Enum.map_join(" ", &"#{String.slice(&1.event_id, 1, 4)}@#{&1.ts}")
  defp seq_redactions(room), do: room |> redaction_rows() |> Enum.map_join(" ", &"#{String.slice(&1.event_id, 1, 4)}@#{&1.ts}")

  # `trace` is a zero-arity function, evaluated only for a failure message (it reads the database)
  defp expect!(condition, round, what, trace) do
    if condition, do: :ok, else: flunk("round #{round}: #{what} (#{trace.()})")
  end

  # runs `fun` and returns {result, started, finished} (monotonic microseconds)
  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {result, started, System.monotonic_time(:microsecond)}
  end

  defp status_of({conn, _started, _finished}), do: conn.status

  # per-scenario tally of the answers of the racing requests (printed at the end of a scenario: how often the race went each way; no mix is REQUIRED)
  defp tally(scenario, results) do
    counts = Process.get({:tally, scenario}, %{})
    Process.put({:tally, scenario}, Enum.reduce(results, counts, fn r, acc -> Map.update(acc, status_of(r), 1, &(&1 + 1)) end))
  end

  defp report(scenario), do: IO.puts("[#{scenario}] answers of the racing requests over #{@rounds} rounds: #{inspect(Process.get({:tally, scenario}, %{}))}")

  # the sequential CONTROL of a scenario (no race, no change): every request must be accepted, otherwise the invariants of the rounds would be vacuous
  defp control!(answers, what), do: assert(Enum.all?(answers, &(&1 == 200)), "control: #{what} must all be 200 without a competing change, got #{inspect(answers)}")

  defp only_statuses!(results, allowed, round, what, trace) do
    bad = results |> Enum.reject(&(status_of(&1) in allowed)) |> Enum.map(fn {conn, _, _} -> {conn.status, String.slice(conn.resp_body, 0, 80)} end)
    expect!(bad == [], round, "#{what}: unexpected answers #{inspect(bad)}", trace)
  end

  # the redaction rows of ONE target of a room, as `[{event_id, sender}]`
  defp redactions_of(room, target) do
    T.sql!("SELECT event_id, sender FROM events WHERE room_id = $1 AND event_type = 'm.room.redaction' AND redacts = $2 ORDER BY origin_server_ts, event_id", [room, target]).rows
    |> Enum.map(&List.to_tuple/1)
  end

  # ═══ AC9 (a): a demotion against ten concurrent redactions by the demoted moderator ═══

  describe "AC9 (a) - a demotion (100 -> 0) against 10 concurrent redactions by the moderator" do
    test "no 500 / 503; one started after the reply is 403; each 200 has its row before the demotion in commit order, each refusal wrote nothing", %{} do
      owner = user!("RCO")
      mod = user!("RCM")
      poster = user!("RCP")

      control_room = public_room(owner)
      for u <- [mod, poster], do: join_now!(u, control_room)
      seed!(control_room, owner, levels(%{owner.uid => 150, mod.uid => 100}))
      control_targets = for i <- 1..10, do: say!(poster, control_room, "c#{i}")
      control!(for(t <- control_targets, do: redact(mod, control_room, t).status), "10 redactions of other users' messages by the moderator")
      assert length(redaction_ids(control_room)) == 10, "control: each 200 has its row"

      for round <- 1..@rounds do
        room = public_room(owner)
        for u <- [mod, poster], do: join_now!(u, room)
        seed!(room, owner, levels(%{owner.uid => 150, mod.uid => 100}))
        targets = for i <- 1..10, do: say!(poster, room, "m#{i}")
        demoted = update_in(column(room), ["users"], &Map.put(&1, mod.uid, 0))

        funs = [fn -> timed(fn -> put_pl(owner, room, demoted) end) end] ++ for(t <- targets, do: fn -> timed(fn -> redact(mod, room, t) end) end)
        [{demotion, _d_started, d_finished} | redactions] = race(funs)

        trace = fn -> seq_redactions(room) end
        expect!(demotion.status == 200, round, "the demotion answered #{demotion.status} #{String.slice(demotion.resp_body, 0, 80)}", trace)
        only_statuses!(redactions, [200, 403], round, "redactions", trace)
        tally(:a, redactions)

        for {conn, started, _finished} <- redactions, started > d_finished do
          expect!(conn.status == 403, round, "a redaction started after the demotion's reply was #{conn.status}", trace)
        end

        expect!(redact(mod, room, hd(targets)).status == 403, round, "a redaction after the demotion's reply is not 403", trace)

        demotion_xmin = xmin_of(latest_pl(room).event_id)

        for {{conn, _, _}, target} <- Enum.zip(redactions, targets) do
          rows = redactions_of(room, target)

          if conn.status == 200 do
            id = T.json(conn)["event_id"]
            expect!(rows == [{id, mod.uid}], round, "a 200 redaction has no row of the moderator (#{inspect(rows)})", trace)
            # the security invariant for EVERY accepted redaction, not only those started after the reply: it was decided on the levels BEFORE the demotion
            expect!(xmin_of(id) < demotion_xmin, round, "an accepted redaction was committed AFTER the demotion", trace)
          else
            expect!(rows == [], round, "a refused redaction wrote a row", trace)
          end
        end

        accepted = Enum.count(redactions, &(status_of(&1) == 200))
        expect!(length(redaction_ids(room)) == accepted, round, "#{length(redaction_ids(room))} redaction rows for #{accepted} answers 200", trace)
        expect!(assert_agree(room)["users"][mod.uid] == 0, round, "the stored levels do not show the demotion", trace)
      end

      report(:a)
    end
  end

  # ═══ AC9 (b): raising events[m.room.topic] against ten concurrent topic PUTs ═══════════

  describe "AC9 (b) - raising events[m.room.topic] to 100 against 10 concurrent topic PUTs at 50" do
    test "no 500 / 503; a PUT started after the reply is 403; each 200 has its event before the raise in commit order, each refusal wrote nothing", %{} do
      owner = user!("RTO")
      member = user!("RTM")

      control_room = public_room(owner)
      join_now!(member, control_room)
      seed!(control_room, owner, levels(%{owner.uid => 100, member.uid => 50}))
      control!(for(i <- 1..10, do: put_state(member, control_room, @topic, %{"topic" => "c#{i}"}).status), "10 topic PUTs by the member at 50")
      assert length(slot_events(control_room, @topic)) == 10, "control: each 200 has its event"

      for round <- 1..@rounds do
        room = public_room(owner)
        join_now!(member, room)
        seed!(room, owner, levels(%{owner.uid => 100, member.uid => 50}))
        raised = update_in(column(room), ["events"], &Map.put(&1, @topic, 100))

        funs =
          [fn -> timed(fn -> put_pl(owner, room, raised) end) end] ++
            for(i <- 1..10, do: fn -> timed(fn -> put_state(member, room, @topic, %{"topic" => "t#{i}"}) end) end)

        [{change, _c_started, c_finished} | puts] = race(funs)

        trace = fn -> seq(room, @topic) end
        expect!(change.status == 200, round, "the change answered #{change.status} #{String.slice(change.resp_body, 0, 80)}", trace)
        only_statuses!(puts, [200, 403], round, "topic PUTs", trace)
        tally(:b, puts)

        for {conn, started, _finished} <- puts, started > c_finished do
          expect!(conn.status == 403, round, "a PUT started after the change's reply was #{conn.status}", trace)
        end

        expect!(put_state(member, room, @topic, %{"topic" => "probe"}).status == 403, round, "a PUT after the change's reply is not 403", trace)

        written = room |> slot_events(@topic) |> Enum.filter(&(&1.sender == member.uid))
        accepted = for {conn, _, _} = r <- puts, status_of(r) == 200, do: T.json(conn)["event_id"]
        expect!(Enum.sort(Enum.map(written, & &1.event_id)) == Enum.sort(accepted), round, "#{length(written)} topic events for #{length(accepted)} answers 200", trace)

        raise_xmin = xmin_of(latest_pl(room).event_id)
        expect!(Enum.all?(accepted, &(xmin_of(&1) < raise_xmin)), round, "an accepted PUT was committed AFTER the raise", trace)
        expect!(assert_agree(room)["events"][@topic] == 100, round, "the stored levels do not show the change", trace)
      end

      report(:b)
    end
  end

  # ═══ AC9 (c): a kick against the kicked member's topic PUTs and own-message redactions ═══

  describe "AC9 (c) - a kick against the member's concurrent topic PUTs and own-message redactions" do
    test "none started after the kick's reply succeeds; every accepted event precedes the kick in commit order; each refusal wrote nothing", %{} do
      owner = user!("RKO")
      member = user!("RKM")

      control_room = public_room(owner)
      join_now!(member, control_room)
      seed!(control_room, owner, levels(%{owner.uid => 100, member.uid => 50}))
      control_own = for i <- 1..5, do: say!(member, control_room, "c#{i}")
      control!(for(i <- 1..5, do: put_state(member, control_room, @topic, %{"topic" => "c#{i}"}).status), "5 topic PUTs by the member")
      control!(for(m <- control_own, do: redact(member, control_room, m).status), "5 own-message redactions by the member")

      for round <- 1..@rounds do
        room = public_room(owner)
        join_now!(member, room)
        seed!(room, owner, levels(%{owner.uid => 100, member.uid => 50}))
        own = for i <- 1..5, do: say!(member, room, "own#{i}")

        funs =
          [fn -> timed(fn -> kick(owner, room, member) end) end] ++
            for(i <- 1..5, do: fn -> timed(fn -> put_state(member, room, @topic, %{"topic" => "t#{i}"}) end) end) ++
            for(m <- own, do: fn -> timed(fn -> redact(member, room, m) end) end)

        [{kick, _k_started, k_finished} | member_requests] = race(funs)

        trace = fn -> seq(room, @topic) <> " | " <> seq_redactions(room) end
        expect!(kick.status == 200, round, "the kick answered #{kick.status} #{String.slice(kick.resp_body, 0, 80)}", trace)
        only_statuses!(member_requests, [200, 403], round, "the member's requests", trace)
        tally(:c, member_requests)

        for {conn, started, _finished} <- member_requests, started > k_finished do
          expect!(conn.status == 403, round, "a request started after the kick's reply was #{conn.status}", trace)
        end

        expect!(put_state(member, room, @topic, %{"topic" => "probe"}).status == 403, round, "a PUT after the kick's reply is not 403", trace)
        expect!(redact(member, room, hd(own)).status == 403, round, "a redaction after the kick's reply is not 403", trace)

        kick_event = room |> member_events(member.uid) |> List.last()
        expect!(kick_event.content["membership"] == "leave" and kick_event.sender == owner.uid, round, "the member's last member event is the kick", trace)
        kick_xmin = xmin_of(kick_event.event_id)

        {put_results, redaction_results} = Enum.split(member_requests, 5)
        topics = room |> slot_events(@topic) |> Enum.filter(&(&1.sender == member.uid)) |> Enum.map(& &1.event_id)
        accepted_puts = for {conn, _, _} = r <- put_results, status_of(r) == 200, do: T.json(conn)["event_id"]
        accepted_redactions = for {conn, _, _} = r <- redaction_results, status_of(r) == 200, do: T.json(conn)["event_id"]

        expect!(Enum.sort(topics) == Enum.sort(accepted_puts), round, "#{length(topics)} topic events for #{length(accepted_puts)} answers 200", trace)
        expect!(Enum.sort(redaction_ids(room)) == Enum.sort(accepted_redactions), round, "the redaction rows are not the accepted ones", trace)
        expect!(Enum.all?(accepted_puts ++ accepted_redactions, &(xmin_of(&1) < kick_xmin)), round, "an accepted event was committed AFTER the kick", trace)
        expect!(not in_set?(room, member.uid), round, "the kicked member is still in the member set", trace)
      end

      report(:c)
    end
  end

  # ═══ AC9 (d): two concurrent PUTs of one slot ════════════════════════════════════════

  describe "AC9 (d) - two concurrent PUTs of one state slot" do
    test "both 200, distinct strictly increasing stamps, the commit order is the stamp order, the prev_content chain is linear", %{} do
      one = user!("RSA")
      two = user!("RSB")

      for round <- 1..@rounds do
        room = public_room(one)
        join_now!(two, room)
        seed!(room, one, levels(%{one.uid => 100, two.uid => 50}))
        initial = slot_events(room, @topic) |> Enum.map(& &1.event_id)

        [c1, c2] =
          race([
            fn -> put_state(one, room, @topic, %{"topic" => "from one"}) end,
            fn -> put_state(two, room, @topic, %{"topic" => "from two"}) end
          ])

        trace = fn -> seq(room, @topic) end
        expect!(c1.status == 200 and c2.status == 200, round, "answers #{c1.status} / #{c2.status}: #{String.slice(c1.resp_body <> c2.resp_body, 0, 120)}", trace)

        events = slot_events(room, @topic)
        expect!(length(events) == length(initial) + 2, round, "expected two new topic events", trace)
        [first, last] = Enum.take(events, -2)
        expect!(Enum.sort([first.event_id, last.event_id]) == Enum.sort([T.json(c1)["event_id"], T.json(c2)["event_id"]]), round, "the new events are not the answered ids", trace)
        expect!(first.ts < last.ts, round, "the stamps are not strictly increasing", trace)
        expect!(xmin_of(first.event_id) < xmin_of(last.event_id), round, "the commit order differs from the stamp order", trace)

        ev = sync(one) |> then(&(join_state(&1, room) ++ join_timeline(&1, room))) |> Enum.filter(&(&1["type"] == @topic)) |> List.last()
        expect!(ev["event_id"] == last.event_id, round, "/sync shows another event than the last committed", trace)
        expect!(get_in(ev, ["unsigned", "replaces_state"]) == first.event_id, round, "the predecessor of the last event is not the one committed before it", trace)
        expect!(get_in(ev, ["unsigned", "prev_content"]) == first.content, round, "the prev_content is not the content of the predecessor", trace)
      end
    end
  end

  # ═══ AC9 (e): two concurrent redactions of one target ════════════════════════════════

  describe "AC9 (e) - two concurrent redactions of one target (idempotent: Kassandra #1)" do
    test "both 200 with the SAME event id, exactly ONE redaction row, one audit-free replay; the target is served pruned by that redaction", %{} do
      owner = user!("RDO")
      mod = user!("RDM")
      author = user!("RDA")

      for round <- 1..@rounds do
        room = public_room(owner)
        for u <- [mod, author], do: join_now!(u, room)
        seed!(room, owner, levels(%{owner.uid => 100, mod.uid => 50}))
        target = say!(author, room, "target")

        [c1, c2] = race([fn -> redact(owner, room, target) end, fn -> redact(mod, room, target) end])

        trace = fn -> seq_redactions(room) end
        expect!(c1.status == 200 and c2.status == 200, round, "answers #{c1.status} / #{c2.status}: #{String.slice(c1.resp_body <> c2.resp_body, 0, 120)}", trace)
        id1 = T.json(c1)["event_id"]
        id2 = T.json(c2)["event_id"]
        expect!(id1 == id2, round, "the two answers are different events", trace)
        expect!(redactions_of(room, target) == [{id1, owner.uid}] or redactions_of(room, target) == [{id1, mod.uid}], round, "not exactly one redaction row", trace)
        expect!(length(redaction_ids(room)) == 1, round, "more than one redaction row in the room", trace)
        served = event!(author, room, target)
        expect!(served["content"] == %{}, round, "the target is not served pruned", trace)
        expect!(served["unsigned"]["redacted_because"]["event_id"] == id1, round, "redacted_because is not the one redaction", trace)
        expect!(length(redact_audit(room)) <= 1, round, "more than one audit row for one redaction", trace)
      end
    end

    test "ten concurrent redactions of one target by one user leave exactly one row", %{} do
      owner = user!("RDQ")
      author = user!("RDR")

      for round <- 1..@rounds do
        room = public_room(owner)
        join_now!(author, room)
        target = say!(author, room, "target")

        results = race(for _ <- 1..10, do: fn -> redact(author, room, target) end)

        trace = fn -> seq_redactions(room) end
        expect!(Enum.all?(results, &(&1.status == 200)), round, "an answer is not 200", trace)
        expect!(results |> Enum.map(&T.json(&1)["event_id"]) |> Enum.uniq() |> length() == 1, round, "more than one event id answered", trace)
        expect!(length(redaction_ids(room)) == 1, round, "more than one redaction row", trace)
      end
    end
  end
end
