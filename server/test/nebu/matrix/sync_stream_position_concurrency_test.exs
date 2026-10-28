defmodule Nebu.Matrix.SyncStreamPositionConcurrencyTest do
  @moduledoc """
  Real-concurrency acceptance tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2): the scenarios whose point is a transaction that is open while a
  device syncs. Every "transaction" below is a `Nebu.Repo.transaction/1` of its own Task (its own pooled connection of the RUNTIME role, really committed or rolled back, no sandbox);
  the sync is the real `GET /_matrix/client/v3/sync` through `Plug.Test` (Router, Horde, Room.Server). `async: false`.

  Covered: Scenario (b) (an event committed after a sync read, older timestamp than a delivered event, is delivered exactly once by the next sync), "two writers of one room interleave
  with a reader" (a direct writer holds position N, the room process waits for N+1, the device syncs during the wait, after the first commit and after the second), and D7 (the persist
  step is ONE transaction guarded by the base token: while it waits for the token row's lock, the row changes; the response is sent, nothing is written, the cursors stay byte-identical).

  ## Decisions of the ATDD step (ambiguities of the story)

    * "the second waits" is proved structurally (a backend that waits for a lock held by the first transaction's backend: `pg_stat_activity.wait_event_type = 'Lock'` and
      `pg_blocking_pids/1`, polled up to 10 s) and a request that COMPLETES while the transaction is open fails the test at once (bounded `Task.yield`); never a sleep as the assertion.
    * The guarded persist (D7) is observed at its natural seam: the persist step starts with `SELECT ... FROM sync_tokens WHERE user_id = $1 AND device_id = $2 FOR UPDATE`. The test
      holds that row lock on a second connection, lets the sync build its response (the build reads the token row without a lock, so it starts and finishes up to the persist), changes
      the row while the persist waits (the "concurrent request of the same device committed first") and releases it. The names of the store functions are NOT pinned: only the lock on
      the token row (any transaction that locks it serialises with the persist) and the rule "write only while the row still holds the base token".
    * "nothing is written" = the token row of the device and all its cursor rows are byte-identical to what the concurrent request left. A cursor write outside the token transaction or
      before the guard, a token upsert that ignores the guard and a re-created row for a device that was deleted meanwhile all fail it.
    * Scenario "two writers" cannot hold the room PROCESS in the middle of a write, so the second writer is a real `PUT .../send` through the router: it reaches the `rooms` row lock of
      the position trigger and waits behind the first transaction (the first transaction is a direct writer: `Room.DB.insert_event/1`, like the createRoom state chain).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── fixtures and probes ─────────────────────────────────────────────────────

  defp device!(uid, prefix) do
    dev = prefix <> String.upcase(T.rand(3))
    %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
  end

  defp shared! do
    uid = T.provision_user!()
    a = device!(uid, "SQA")
    o = S.user!("SQO")
    room = S.invite_room(o, [a])
    room2 = S.invite_room(o, [a])
    anchor = S.anchor_room!(a)
    ta = S.snapshot!(a, anchor)
    %{uid: uid, a: a, o: o, room: room, room2: room2, anchor: anchor, ta: ta}
  end

  defp next(body), do: body["next_batch"]
  defp bodies(body, room), do: for(ev <- S.join_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])
  defp snapshot?(body, room), do: Enum.any?(S.join_timeline(body, room), &(&1["type"] == "m.room.create"))

  defp cursor_pos(uid, dev, room) do
    case T.sql!("SELECT pos FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [uid, dev, room]).rows do
      [[pos]] -> pos
      [] -> nil
    end
  end

  defp head(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp pos_of(event_id), do: T.sql!("SELECT room_pos FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()

  # the whole token row and all cursor rows of ONE device, as JSON text (byte-identical checks)
  defp device_rows(uid, dev) do
    {T.sql!("SELECT to_jsonb(t)::text FROM sync_tokens t WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows,
     T.sql!("SELECT to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1 AND device_id = $2 ORDER BY room_id", [uid, dev]).rows}
  end

  defp raw_message(room, sender, body, ts) do
    %{
      "event_id" => "$sq" <> T.rand(12),
      "room_id" => room,
      "sender" => sender,
      "type" => "m.room.message",
      "state_key" => nil,
      "content" => %{"msgtype" => "m.text", "body" => body},
      "origin_server_ts" => ts
    }
  end

  # a transaction of its own (Task + Nebu.Repo.transaction/1, its own connection) that runs `fun`, reports `{:held, pid, backend_pid, result}` and then stays OPEN until
  # `finish/2`. A transaction that is still open at the end of the test is rolled back in on_exit.
  defp hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Nebu.Repo.transaction(fn ->
          %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
          result = fun.()
          send(parent, {:held, self(), backend, result})

          receive do
            :commit -> :committed
            :rollback -> Nebu.Repo.rollback(:atdd_rollback)
          after
            60_000 -> Nebu.Repo.rollback(:atdd_timeout)
          end
        end)
      end)

    assert_receive {:held, pid, backend, result}, 15_000
    on_exit(fn -> send(pid, :rollback) end)
    %{task: task, pid: pid, backend: backend, result: result}
  end

  defp finish(%{task: task, pid: pid}, :commit) do
    send(pid, :commit)
    assert {:ok, :committed} = Task.await(task, 15_000)
  end

  # `task` must be BLOCKED by the transaction of `backend`: a backend that waits for a lock held by it appears within 10 s; a task that completes first fails the test
  defp await_blocked!(task, backend, what), do: await_blocked!(task, backend, what, System.monotonic_time(:millisecond) + 10_000)

  defp await_blocked!(task, backend, what, deadline) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        flunk("#{what} completed (#{inspect(result)}) while the other transaction was open: it did not wait for it")

      {:exit, reason} ->
        flunk("#{what} crashed: #{inspect(reason)}")

      nil ->
        %{rows: [[waiting]]} = T.sql!("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND $1 = ANY(pg_blocking_pids(pid))", [backend])

        cond do
          waiting >= 1 -> :ok
          System.monotonic_time(:millisecond) > deadline -> flunk("#{what} neither completed nor waits for a lock of the other transaction (backend #{backend}) within 10 s")
          true -> Process.sleep(20) && await_blocked!(task, backend, what, deadline)
        end
    end
  end

  # ═══ (b) an event committed after a sync read ═══════════════════════════════════════════════════════════════════════════════

  describe "(b) late commit, older timestamp" do
    test "an uncommitted event of A (older ts), a newer committed one in B: the sync delivers B only, after the commit A's event arrives once" do
      f = shared!()
      old_ts = System.system_time(:millisecond) - 20_000
      held = hold(fn -> assert :ok = DB.insert_event(raw_message(f.room, f.o.uid, "late-commit", old_ts)) end)

      S.tick()
      newer = S.marker("newer-in-b")
      S.say!(f.o, f.room2, newer)

      s1 = S.sync(f.a, f.ta)
      assert bodies(s1, f.room2) == [newer]
      assert bodies(s1, f.room) == [], "the uncommitted event is not visible"
      assert cursor_pos(f.uid, f.a.dev, f.room) == head(f.room), "the cursor of room A is the COMMITTED head: it never passes the uncommitted position"

      finish(held, :commit)
      s2 = S.sync(f.a, next(s1))
      assert bodies(s2, f.room) == ["late-commit"], "delivered although a newer event of another room was delivered before"
      refute snapshot?(s2, f.room)
      assert bodies(s2, f.room2) == []

      s3 = S.sync(f.a, next(s2))
      assert bodies(s3, f.room) == [] and bodies(s3, f.room2) == [], "exactly once"
    end

    test "a ROLLED BACK transaction delivers nothing, its position is handed out again and the next event of the room is delivered" do
      f = shared!()
      held = hold(fn -> assert :ok = DB.insert_event(raw_message(f.room, f.o.uid, "never-committed", System.system_time(:millisecond) - 1_000)) end)

      s1 = S.sync(f.a, f.ta)
      assert bodies(s1, f.room) == []

      send(held.pid, :rollback)
      assert {:error, :atdd_rollback} = Task.await(held.task, 15_000)

      S.tick()
      m = S.marker("after-rollback")
      S.say!(f.o, f.room, m)
      s2 = S.sync(f.a, next(s1))
      assert bodies(s2, f.room) == [m], "no gap in the positions, no loss"
      assert cursor_pos(f.uid, f.a.dev, f.room) == head(f.room)
    end
  end

  # ═══ two writers and a reader ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "two writers and a reader" do
    test "a direct writer holds N, the room process waits for N+1: never N+1 before N, the cursor stays below N, both delivered exactly once" do
      f = shared!()
      first_body = "direct-writer-N"
      second_body = S.marker("room-process-N1")
      before_head = head(f.room)

      held = hold(fn -> assert :ok = DB.insert_event(raw_message(f.room, f.o.uid, first_body, System.system_time(:millisecond))) end)
      second = Task.async(fn -> S.say!(f.o, f.room, second_body) end)
      await_blocked!(second, held.backend, "the write of the room process")

      during = S.sync(f.a, f.ta)
      assert bodies(during, f.room) == [], "neither event is delivered while position N is uncommitted"
      assert cursor_pos(f.uid, f.a.dev, f.room) == before_head, "the cursor stays at the committed head"
      assert head(f.room) == before_head

      finish(held, :commit)
      # a sync right after the first commit: the second writer may or may not have committed yet, but never N+1 without N
      after_first = S.sync(f.a, next(during))
      event_id = Task.await(second, 15_000)
      after_second = S.sync(f.a, next(after_first))

      delivered = bodies(after_first, f.room) ++ bodies(after_second, f.room)
      assert delivered == [first_body, second_body], "both exactly once and in position order: #{inspect(delivered)}"
      refute second_body in bodies(after_first, f.room) and first_body not in bodies(after_first, f.room), "N+1 before N"
      first_id = T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND content->>'body' = $2", [f.room, first_body]).rows |> hd() |> hd()
      assert pos_of(event_id) == pos_of(first_id) + 1, "the waiting writer drew N+1 only after N committed"
      assert cursor_pos(f.uid, f.a.dev, f.room) == head(f.room)

      assert bodies(S.sync(f.a, next(after_second)), f.room) == []
    end

    test "a reader polling while three writers (two room-process sends, one direct writer) commit never sees a gap, and nothing is delivered twice or lost" do
      f = shared!()
      direct = Task.async(fn -> for i <- 1..5, do: DB.insert_event(raw_message(f.room, f.o.uid, "d#{i}", System.system_time(:millisecond))) end)
      senders = for n <- 1..2, do: Task.async(fn -> for i <- 1..5, do: S.say!(f.o, f.room, "s#{n}-#{i}") end)

      poll = fn poll, token, seen, rounds ->
        body = S.sync(f.a, token)
        seen = seen ++ bodies(body, f.room)

        if rounds > 0 and length(seen) < 15 do
          Process.sleep(10)
          poll.(poll, next(body), seen, rounds - 1)
        else
          {next(body), seen}
        end
      end

      {token, seen} = poll.(poll, f.ta, [], 60)
      Task.await(direct, 30_000)
      for t <- senders, do: Task.await(t, 30_000)
      final = S.sync(f.a, token)
      seen = seen ++ bodies(final, f.room)

      expected = for(i <- 1..5, do: "d#{i}") ++ for(n <- 1..2, i <- 1..5, do: "s#{n}-#{i}")
      assert Enum.sort(seen) == Enum.sort(expected), "every event exactly once: #{inspect(seen -- expected)} extra, #{inspect(expected -- seen)} missing"
      positions = Enum.map(seen, fn body -> T.sql!("SELECT room_pos FROM events WHERE room_id = $1 AND content->>'body' = $2", [f.room, body]).rows |> hd() |> hd() end)
      assert positions == Enum.sort(positions), "delivered in position (commit) order across the responses"
    end
  end

  # ═══ D7: the persist is ONE transaction guarded by the base token ═══════════════════════════════════════════════════════════

  describe "D7 - guarded atomic persist" do
    test "a concurrent request committed first (the token row changed while the persist waited): the response is sent, NOTHING is written, its next_batch is unknown" do
      f = shared!()
      m = S.marker("m")
      S.say!(f.o, f.room, m)

      # "the other request": generations moved on, neither the current nor the previous token is the base of the waiting request any more
      holder =
        hold(fn ->
          T.sql!("SELECT 1 FROM sync_tokens WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [f.uid, f.a.dev])

          T.sql!(
            "UPDATE sync_tokens SET since_token = 's2_concurrent_current', prev_since_token = 's2_concurrent_previous', generation = generation + 2, stream_version = 1 WHERE user_id = $1 AND device_id = $2",
            [f.uid, f.a.dev]
          )
        end)

      sync = Task.async(fn -> S.sync(f.a, f.ta) end)
      await_blocked!(sync, holder.backend, "the persist step of the sync (it must lock the token row)")
      finish(holder, :commit)

      resp = Task.await(sync, 15_000)
      assert m in bodies(resp, f.room), "the response is still sent and carries what was built"
      assert is_binary(next(resp))

      {[[token_json]], cursor_rows} = device_rows(f.uid, f.a.dev)
      token = Jason.decode!(token_json)
      assert token["since_token"] == "s2_concurrent_current" and token["prev_since_token"] == "s2_concurrent_previous", "the token row is what the concurrent request left"
      assert token["generation"] >= 2

      assert Enum.all?(cursor_rows, fn [json] -> Jason.decode!(json)["gen"] <= 1 end), "no cursor row was written by the stale request (no row of a newer generation)"
      assert cursor_pos(f.uid, f.a.dev, f.room) < head(f.room), "the cursor of the room did not advance: a cursor ahead of a token that is not valid would lose events"
      refute next(resp) |> String.split(".") |> hd() == token["since_token"]

      fallback = S.sync(f.a, next(resp))
      assert snapshot?(fallback, f.room), "the unknown next_batch falls back (today's behaviour for concurrent requests)"
    end

    test "control: an uncontended request (its base is still current) writes the new token row and moves the cursor to the head in the same step" do
      f = shared!()
      S.say!(f.o, f.room, S.marker("x"))
      before = device_rows(f.uid, f.a.dev)

      ok = S.sync(f.a, f.ta)
      assert device_rows(f.uid, f.a.dev) != before
      assert cursor_pos(f.uid, f.a.dev, f.room) == head(f.room)
      assert String.split(next(ok), ".") |> hd() == T.sql!("SELECT since_token FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev]).rows |> hd() |> hd()
    end

    test "a device deleted while its sync waits for the token row's lock: nothing is re-created (no token row, no cursor row)" do
      f = shared!()
      S.say!(f.o, f.room, S.marker("m"))
      holder = hold(fn -> T.sql!("DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev]) end)

      sync = Task.async(fn -> S.sync(f.a, f.ta) end)
      await_blocked!(sync, holder.backend, "the persist step of the sync")
      finish(holder, :commit)
      resp = Task.await(sync, 15_000)

      assert is_binary(next(resp))
      assert device_rows(f.uid, f.a.dev) == {[], []}, "a request that lost its row writes no orphan row and no orphan cursor"
    end

    # DELIBERATE amendment by the dev step (code review cycle 0, MINOR-4 / MAJOR-1), old -> new: the old test sent two requests with the same token at once and
    # asserted that BOTH carry the news; that holds only when both read the cursor rows before either commits (racy), and it never checked that nothing is lost
    # between the two responses. Now the sequence is forced: R2 is built from the token T (its long-poll is waiting) BEFORE R1 commits, and reads the cursor rows
    # AFTER R1 committed (the event of R1 is inserted without a wake-up, R2 is woken only after R1's commit). Without the generation compare-and-set R2 would
    # store its token over R1's and continue from cursors R1 advanced past `c-m1` (a silent loss); with it R2 is `:stale` and the stored token is R1's.
    test "two requests built from the SAME token, the second reading the cursors after the first committed: the stored token's response and its next sync carry every event (no loss)" do
      f = shared!()
      group = "user:#{f.uid}"

      r2 = Task.async(fn -> S.sync(f.a, f.ta, timeout: 15_000) end)

      # R2 has read its base (T) and finished its first build without news: its sync task (the member of the user's wake-up group) sits in the long-poll wait.
      # (The group is joined BEFORE the first build, so membership alone is not enough: the probe looks at the function the task is waiting in.)
      waiting? = fn ->
        Enum.any?(:pg.get_members(group), fn pid ->
          match?({:current_function, {Nebu.Matrix.EventDispatcher.Server, :wait_loop, _}}, Process.info(pid, :current_function))
        end)
      end

      assert :ok == S.wait_until(waiting?, 5_000), "R2 is long-polling with the token T"

      # the news of R1, without a wake-up of R2 (a direct insert, as a writer outside the room process)
      assert :ok = DB.insert_event(raw_message(f.room, f.o.uid, "c-m1", System.system_time(:millisecond)))
      r1 = S.sync(f.a, f.ta)
      assert bodies(r1, f.room) == ["c-m1"], "R1 delivers the news and commits"

      # now wake R2: its rebuild reads the cursor rows R1 advanced
      m2 = S.marker("c-m2")
      S.say!(f.o, f.room, m2)
      r2 = Task.await(r2, 30_000)

      stored = T.sql!("SELECT since_token FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev]).rows |> hd() |> hd()
      core = fn r -> next(r) |> String.split(".") |> hd() end
      valid = Enum.filter([r1, r2], &(core.(&1) == stored))
      assert length(valid) >= 1, "the token of one of the requests is stored"
      assert valid == [r1], "the second writer (built from T, its cursors read after R1's commit) stored nothing: it is stale"

      for r <- valid do
        follow = S.sync(f.a, next(r))
        refute snapshot?(follow, f.room), "the stored token continues incrementally"
        seen = bodies(r, f.room) ++ bodies(follow, f.room)
        assert "c-m1" in seen and m2 in seen, "the stored token's response and the next sync carry every event: #{inspect(seen)}"
      end

      fallback = S.sync(f.a, next(r2))
      assert snapshot?(fallback, f.room), "the stale response's next_batch is the one-time fallback (never a misread)"
    end
  end
end
