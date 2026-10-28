defmodule Nebu.Matrix.Room.EventsRoomPositionDbTest do
  @moduledoc """
  Story `events-room-position` (epic oauth-broker, follow-up `fc`, story 1 of 2), Scenarios 2 - 4 and the trigger semantics (D1 - D4, D8), REAL PostgreSQL
  with REAL concurrency: every "transaction" below is a `Nebu.Repo.transaction/1` of its own Task, i.e. its own pooled connection of the RUNTIME role, committed or
  rolled back for real (no sandbox, no transaction around the test). `async: false`.

  Migration `000053_events_room_position` adds `rooms.event_pos`, `events.room_pos` and a `BEFORE INSERT` trigger on `events` that draws `room_pos` under the
  `rooms` row lock. The new columns are reached through SQL strings only, so a missing migration is a RUNTIME failure of the test (`column ... does not exist`),
  never a compile error (CI compiles with `--warnings-as-errors`). After adding the migration reset the throwaway database (`docker rm -f nebu-oauth-pg`, or
  `.oauth-ci/cleanup.sh`) so that it is migrated.

  ## Decisions of the ATDD step (ambiguities of the story)

    * Rooms are created with `Room.DB.insert_room/1` (a bare `rooms` row; the story's DB scenarios need no members, no HTTP): the writers are called through the REAL
      `Room.DB` functions (`insert_event/1`, `apply_member_change/4`, `apply_power_levels_change/3`, `apply_state_change/3`, `apply_redaction/2`).
    * "waited" is proved structurally, not with a sleep: the second writer is observed as a backend that WAITS FOR A LOCK held by the first transaction's backend
      (`pg_stat_activity.wait_event_type = 'Lock'` and `pg_blocking_pids/1`), polled up to 10 s; a writer that COMPLETES while the first transaction is open fails
      the test at once (bounded `Task.yield/2`, never a fixed `Process.sleep` as the assertion). "never sees N+1 before N" is a read of the committed positions of the
      room in ONE statement (a snapshot) at each stage: it must be the gapless prefix `1..k`.
    * Scenario 4 needs two member changes that are both past their archived check when they reach the `INSERT`: a stimulus trigger `a00_atdd_hold_*` (created through
      the privileged role, dropped in `on_exit`; trigger names fire alphabetically, so it fires BEFORE the position trigger whatever the implementation calls it) makes
      a change that reaches its insert wait (at most 150 ms, shorter when the other change has arrived too) until both are there. With `FOR SHARE` both pass the check
      and both then UPGRADE to the exclusive row lock in the position trigger: a real deadlock (or the 1 s `lock_timeout`), reported as `{:error, _}`. With `FOR NO KEY
      UPDATE` the second change waits at its check, so the barrier simply times out for the first one and both commit. The 150 ms stay far below the 1 s `lock_timeout`
      of `apply_member_change/4`.
    * "an archived room still refuses both" runs twice: the room archived before (both refuse) and the archive path's `FOR UPDATE` held while the change starts (the
      change waits for it, then refuses): that the check reads the row UNDER the lock is what keeps the refusal after the lock change of D2.
    * `rooms.event_pos` is read as the highest handed-out position; an event inserted for a room that has no row stays refused by the foreign key (nothing stamped).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @db_ex Path.expand("../../../../lib/nebu/matrix/room/db.ex", __DIR__)

  # ─── static (no database: runs in the unit job) ──────────────────────────────

  describe "Room.DB source (static)" do
    test "no rooms row is locked FOR SHARE in Room.DB any more (D2)" do
      src = File.read!(@db_ex)
      refute src =~ ~r/FROM rooms[^"]*FOR (KEY )?SHARE/, "a rooms row is locked FOR SHARE in Room.DB (D2)"
    end
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # a bare room row (deleted with its events in on_exit)
  defp new_room! do
    room = "!epos#{T.rand(8)}:test.local"
    assert {:ok, _} = DB.insert_room(room)

    on_exit(fn ->
      T.sql!("DELETE FROM events WHERE room_id = $1", [room])
      T.sql!("DELETE FROM rooms WHERE room_id = $1", [room])
    end)

    room
  end

  defp event(room, type \\ "m.room.message", state_key \\ nil) do
    %{
      "event_id" => "$epos" <> T.rand(12),
      "room_id" => room,
      "sender" => "@epos:test.local",
      "type" => type,
      "state_key" => state_key,
      "content" => %{"msgtype" => "m.text", "body" => "epos"},
      "origin_server_ts" => System.system_time(:millisecond),
      "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(32))}
    }
  end

  defp insert!(room), do: insert!(room, event(room))

  defp insert!(_room, event) do
    assert :ok = DB.insert_event(event)
    event["event_id"]
  end

  # the stamped positions of a room, ascending (a committed snapshot: ONE statement)
  defp visible(room),
    do: T.sql!("SELECT coalesce(array_agg(room_pos ORDER BY room_pos), '{}'::bigint[]) FROM events WHERE room_id = $1 AND room_pos IS NOT NULL", [room]).rows |> hd() |> hd()

  defp pos_of(event_id), do: T.sql!("SELECT room_pos FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()
  defp counter(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp event_rows(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()

  defp gapless?(positions), do: positions == Enum.to_list(1..length(positions)//1)

  defp assert_prefix!(positions, what), do: assert(gapless?(positions), "#{what}: a reader saw #{inspect(positions)}, not the gapless prefix 1..#{length(positions)}")

  # a transaction of its own (Task + Nebu.Repo.transaction/1, its own connection) that runs `fun`, reports `{:held, pid, backend_pid, result}` and then stays OPEN until
  # `finish/2`. The remaining open transaction is rolled back in on_exit (registered after the room's cleanup, so it runs BEFORE it).
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

  defp finish(%{task: task, pid: pid}, :rollback) do
    send(pid, :rollback)
    assert {:error, :atdd_rollback} = Task.await(task, 15_000)
  end

  # `task` must be BLOCKED by the transaction of `backend`: a backend that waits for a lock held by it appears within 10 s; a task that completes first fails the test
  defp await_blocked!(task, backend, what), do: await_blocked!(task, backend, what, System.monotonic_time(:millisecond) + 10_000)

  defp await_blocked!(task, backend, what, deadline) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        flunk("#{what} completed (#{inspect(result)}) while the other transaction held the room: it did not wait for it")

      {:exit, reason} ->
        flunk("#{what} crashed: #{inspect(reason)}")

      nil ->
        %{rows: [[waiting]]} =
          T.sql!("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND $1 = ANY(pg_blocking_pids(pid))", [backend])

        cond do
          waiting >= 1 -> :ok
          System.monotonic_time(:millisecond) > deadline -> flunk("#{what} neither completed nor waits for a lock of the other transaction (backend #{backend}) within 10 s")
          true -> Process.sleep(20) && await_blocked!(task, backend, what, deadline)
        end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # the trigger, as the runtime role (D1, D4, D8)
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "the position trigger (runtime role, autocommit)" do
    @describetag :integration

    test "the events of a room get 1, 2, 3 in insert order and rooms.event_pos is the highest; insert_event/1 still returns :ok (D8)" do
      room = new_room!()
      assert counter(room) == 0
      ids = for _ <- 1..3, do: insert!(room)

      assert Enum.map(ids, &pos_of/1) == [1, 2, 3]
      assert counter(room) == 3
      assert visible(room) == [1, 2, 3]
    end

    test "a plain INSERT without room_pos (what an OLD node writes during a rolling deploy) is stamped as well" do
      room = new_room!()
      now = System.system_time(:millisecond)

      for i <- 1..2 do
        T.sql!("INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts) VALUES ($1, $2, '@old:test.local', 'm.room.message', '{}', $3)", [
          "$old#{i}" <> T.rand(8),
          room,
          now
        ])
      end

      assert visible(room) == [1, 2]
      assert counter(room) == 2
    end

    test "a room_pos supplied by the INSERT is overwritten (the writer cannot choose a position)" do
      room = new_room!()
      now = System.system_time(:millisecond)

      for supplied <- [999, 0, -5, 1] do
        id = "$sup#{T.rand(8)}"
        T.sql!("INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, room_pos) VALUES ($1, $2, '@s:test.local', 'm.room.message', '{}', $3, $4)", [id, room, now, supplied])
      end

      assert visible(room) == [1, 2, 3, 4]
      assert counter(room) == 4
    end

    test "rooms count independently: two rooms, interleaved inserts, each starts at 1" do
      a = new_room!()
      b = new_room!()
      for room <- [a, b, a, a, b], do: insert!(room)

      assert visible(a) == [1, 2, 3]
      assert visible(b) == [1, 2]
      assert {counter(a), counter(b)} == {3, 2}
    end

    test "one multi-row INSERT ... SELECT draws consecutive positions (the trigger fires per row)" do
      room = new_room!()
      now = System.system_time(:millisecond)

      T.sql!("INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts) SELECT '$bulk' || g || $1::text, $2::text, '@b:test.local', 'm.room.message', '{}', $3::bigint FROM generate_series(1, 5) g", [
        T.rand(6),
        room,
        now
      ])

      assert visible(room) == [1, 2, 3, 4, 5]
      assert counter(room) == 5
    end

    test "an UPDATE never re-stamps an event (the trigger is BEFORE INSERT only)" do
      room = new_room!()
      [first, second] = [insert!(room), insert!(room)]

      T.sql!("UPDATE events SET content = '{\"edited\":true}' WHERE event_id = $1", [first])
      assert {pos_of(first), pos_of(second)} == {1, 2}
      assert counter(room) == 2
    end

    test "the unique index rejects a duplicate (room_id, room_pos) (D4)" do
      room = new_room!()
      [_first, second] = [insert!(room), insert!(room)]

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Ecto.Adapters.SQL.query(Nebu.Repo, "UPDATE events SET room_pos = 1 WHERE event_id = $1", [second])
    end

    test "unstamped rows (room_pos NULL, pre-migration events) never collide; the next insert gets counter + 1 (D3)" do
      room = new_room!()
      ids = for _ <- 1..3, do: insert!(room)

      # the world before the migration: the rows exist, unstamped, and the room's counter is 0
      T.sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1", [room])
      T.sql!("UPDATE rooms SET event_pos = 0 WHERE room_id = $1", [room])
      assert visible(room) == []
      assert Enum.map(ids, &pos_of/1) == [nil, nil, nil]

      fresh = insert!(room)
      assert pos_of(fresh) == 1
      assert counter(room) == 1
      assert Enum.map(ids, &pos_of/1) == [nil, nil, nil], "the old rows stay NULL"
    end

    test "an unknown room stays refused by the foreign key; a duplicate event id fails its statement and takes no position" do
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = DB.insert_event(event("!nosuch#{T.rand(6)}:test.local"))

      room = new_room!()
      e = event(room)
      assert :ok = DB.insert_event(e)
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} = DB.insert_event(e)

      assert counter(room) == 1, "the failed statement rolled the trigger's UPDATE back with it"
      assert insert!(room) |> pos_of() == 2
      assert visible(room) == [1, 2]
    end
  end

  describe "every Room.DB writer stamps" do
    @describetag :integration

    test "insert_event, power levels, state change, redaction and member change draw 1..5 in call order" do
      room = new_room!()
      target = insert!(room)
      levels = Jason.encode!(%{"users" => %{"@epos:test.local" => 100}, "events_default" => 0})

      pl = event(room, "m.room.power_levels", "")
      assert :ok = DB.apply_power_levels_change(room, levels, pl)

      name = event(room, "m.room.name", "")
      assert :ok = DB.apply_state_change(room, name, room_name: "epos")

      redaction = event(room, "m.room.redaction") |> Map.put("redacts", target)
      assert :ok = DB.apply_redaction(room, redaction)

      member = event(room, "m.room.member", "@kicked:test.local")
      assert :ok = DB.apply_member_change(room, "@kicked:test.local", member, remove_member: true)

      assert [target, pl["event_id"], name["event_id"], redaction["event_id"], member["event_id"]] |> Enum.map(&pos_of/1) == [1, 2, 3, 4, 5]
      assert visible(room) == [1, 2, 3, 4, 5]
      assert counter(room) == 5
    end

    test "a writer transaction failing after its event insert (duplicate id) rolls the position back" do
      room = new_room!()
      insert!(room)

      # the event is already there: apply_member_change/4 inserts it (position drawn), the unique violation rolls the WHOLE transaction back, trigger UPDATE included
      dup = event(room, "m.room.member", "@dup:test.local")
      insert!(room, dup)
      assert counter(room) == 2

      assert {:error, _} = DB.apply_member_change(room, "@dup:test.local", dup, remove_member: true)
      assert counter(room) == 2, "no position was consumed by the failed transaction"
      assert insert!(room) |> pos_of() == 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # Scenario 2: a second writer of the same room waits, a reader never sees N+1 before N
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 2 - the second writer of a room waits" do
    @describetag :integration

    test "T2 waits for the open T1 (position N), then gets N+1; the reader never sees N+1 without N" do
      room = new_room!()
      for _ <- 1..2, do: insert!(room)
      assert counter(room) == 2

      e1 = event(room)
      e2 = event(room)
      t1 = hold(fn -> DB.insert_event(e1) end)
      assert t1.result == :ok

      t2 = Task.async(fn -> DB.insert_event(e2) end)
      await_blocked!(t2, t1.backend, "the second writer (T2)")

      stage_1 = visible(room)
      assert stage_1 == [1, 2], "while T1 is open the reader sees only the committed 1, 2"

      finish(t1, :commit)
      stage_2 = visible(room)
      assert_prefix!(stage_2, "after T1 committed (T2 may or may not be through)")
      assert length(stage_2) in [3, 4]

      assert :ok = Task.await(t2, 15_000)
      stage_3 = visible(room)

      assert stage_3 == [1, 2, 3, 4]
      assert {pos_of(e1["event_id"]), pos_of(e2["event_id"])} == {3, 4}, "T1 drew N = 3, T2 waited and drew N + 1 = 4"
      assert counter(room) == 4
    end

    test "T2 as a member change transaction waits at its row lock, then commits with N+1" do
      room = new_room!()
      insert!(room)
      e1 = event(room)
      e2 = event(room, "m.room.member", "@w:test.local")
      t1 = hold(fn -> DB.insert_event(e1) end)

      t2 = Task.async(fn -> DB.apply_member_change(room, "@w:test.local", e2, remove_member: true) end)
      await_blocked!(t2, t1.backend, "the member change (T2)")

      finish(t1, :commit)
      assert :ok = Task.await(t2, 15_000)
      assert {pos_of(e1["event_id"]), pos_of(e2["event_id"])} == {2, 3}
      assert visible(room) == [1, 2, 3]
    end

    test "a polling reader against six writers only sees the gapless prefix 1..k; final 1..n" do
      room = new_room!()
      parent = self()

      reader =
        Task.async(fn ->
          poll = fn poll, seen, bad ->
            receive do
              :stop -> {seen, bad}
            after
              0 ->
                positions = visible(room)
                poll.(poll, seen + 1, if(gapless?(positions), do: bad, else: [positions | bad]))
            end
          end

          send(parent, :reader_up)
          poll.(poll, 0, [])
        end)

      assert_receive :reader_up, 5_000

      writers =
        for w <- 1..6 do
          Task.async(fn ->
            for _ <- 1..10 do
              if rem(w, 2) == 0 do
                :ok = DB.insert_event(event(room))
              else
                {:ok, :ok} =
                  Nebu.Repo.transaction(fn ->
                    :ok = DB.insert_event(event(room))
                    Process.sleep(2)
                    :ok = DB.insert_event(event(room))
                  end)
              end
            end
          end)
        end

      Enum.each(writers, &Task.await(&1, 60_000))
      send(reader.pid, :stop)
      {seen, bad} = Task.await(reader, 15_000)

      assert bad == [], "the reader saw a position before its predecessor (#{length(bad)} of #{seen} reads), first: #{inspect(List.last(bad))}"
      assert seen > 0
      assert visible(room) == Enum.to_list(1..90)
      assert counter(room) == 90
      assert event_rows(room) == 90
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # Scenario 3: a rolled-back insert leaves no gap, other rooms are not blocked
  # ═══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 3 - rollback and other rooms" do
    @describetag :integration

    test "room S is not blocked by T1 in room R; after the rollback the next event of R gets the position T1 drew" do
      r = new_room!()
      s = new_room!()
      insert!(r)
      insert!(s)

      e_r1 = event(r)
      t1 = hold(fn -> DB.insert_event(e_r1) end)
      assert t1.result == :ok

      other = Task.async(fn -> DB.insert_event(event(s)) end)
      assert {:ok, :ok} = Task.yield(other, 3_000) || flunk("the insert into room S is blocked by a transaction that holds ROOM R (rooms must not block each other)")
      assert visible(s) == [1, 2]
      assert visible(r) == [1], "T1's event (position 2) is not committed"

      finish(t1, :rollback)
      assert visible(r) == [1]
      assert counter(r) == 1, "the rollback took the counter back with it (no gap)"
      assert event_rows(r) == 1

      e_r2 = event(r)
      assert :ok = DB.insert_event(e_r2)
      assert pos_of(e_r2["event_id"]) == 2, "the new event of R gets the position the rolled-back transaction had drawn"
      assert visible(r) == [1, 2]
    end

    test "a rolled-back insert behind a WAITING writer: T2 waits for T1, T1 rolls back, T2 then draws the position T1 had drawn" do
      room = new_room!()
      insert!(room)
      e1 = event(room)
      e2 = event(room)
      t1 = hold(fn -> DB.insert_event(e1) end)
      t2 = Task.async(fn -> DB.insert_event(e2) end)
      await_blocked!(t2, t1.backend, "the second writer")

      finish(t1, :rollback)
      assert :ok = Task.await(t2, 15_000)
      assert pos_of(e2["event_id"]) == 2
      assert T.sql!("SELECT count(*) FROM events WHERE event_id = $1", [e1["event_id"]]).rows == [[0]], "the rolled-back event does not exist"
      assert visible(room) == [1, 2]
      assert counter(room) == 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════════
  # Scenario 4: concurrent member changes of one room do not deadlock (D2)
  # ═══════════════════════════════════════════════════════════════════════════════

  # a killed earlier run may have left its stimulus trigger / function in the shared database: drop them (privileged role, by prefix)
  defp drop_stale_barriers!() do
    for [name] <- T.privileged_sql!("SELECT tgname FROM pg_trigger WHERE tgrelid = 'events'::regclass AND tgname LIKE 'a00\\_atdd\\_hold\\_%'").rows,
        do: T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON events")

    for [name] <- T.privileged_sql!("SELECT proname FROM pg_proc WHERE proname LIKE 'a00\\_atdd\\_hold\\_%'").rows,
        do: T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
  end

  # the stimulus trigger (see the moduledoc): makes an insert into `room` wait until two transactions are at their insert (max 150 ms)
  defp install_barrier!(room) do
    drop_stale_barriers!()
    name = "a00_atdd_hold_" <> T.rand(4)
    key = :rand.uniform(1_000_000_000)

    T.privileged_sql!("""
    CREATE FUNCTION #{name}() RETURNS trigger AS $$
    DECLARE deadline timestamptz := clock_timestamp() + interval '150 ms';
    BEGIN
      IF NEW.room_id = '#{room}' THEN
        PERFORM pg_advisory_xact_lock_shared(7, #{key});
        WHILE clock_timestamp() < deadline
              AND (SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = 7 AND objid = #{key} AND granted) < 2 LOOP
          PERFORM pg_sleep(0.005);
        END LOOP;
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION #{name}()")

    on_exit(fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON events")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    name
  end

  describe "Scenario 4 - concurrent member changes of one room" do
    @describetag :integration

    test "both commit, serialised, consecutive positions: no deadlock (FOR SHARE deadlocks)" do
      room = new_room!()
      insert!(room)
      install_barrier!(room)
      e1 = event(room, "m.room.member", "@m1:test.local")
      e2 = event(room, "m.room.member", "@m2:test.local")

      tasks = [
        Task.async(fn -> DB.apply_member_change(room, "@m1:test.local", e1, remove_member: true) end),
        Task.async(fn -> DB.apply_member_change(room, "@m2:test.local", e2, remove_member: true) end)
      ]

      results = Enum.map(tasks, &Task.await(&1, 30_000))
      assert results == [:ok, :ok], "both member changes must commit; a deadlock (40P01) or the 1 s lock timeout (55P03) is a failure: #{inspect(results)}"

      assert Enum.sort([pos_of(e1["event_id"]), pos_of(e2["event_id"])]) == [2, 3], "serialised: consecutive positions"
      assert visible(room) == [1, 2, 3]
      assert counter(room) == 3
    end

    test "an ARCHIVED room refuses both changes (:room_archived), no event, no position" do
      room = new_room!()
      insert!(room)
      T.sql!("UPDATE rooms SET status = 'archived' WHERE room_id = $1", [room])
      install_barrier!(room)
      e1 = event(room, "m.room.member", "@m1:test.local")
      e2 = event(room, "m.room.member", "@m2:test.local")

      results =
        [
          Task.async(fn -> DB.apply_member_change(room, "@m1:test.local", e1, remove_member: true) end),
          Task.async(fn -> DB.apply_member_change(room, "@m2:test.local", e2, remove_member: true) end)
        ]
        |> Enum.map(&Task.await(&1, 30_000))

      assert results == [{:error, :room_archived}, {:error, :room_archived}]
      assert event_rows(room) == 1
      assert counter(room) == 1
    end

    test "the archive path's FOR UPDATE is respected: a member change waits for it, then refuses" do
      room = new_room!()
      insert!(room)

      archive =
        hold(fn ->
          T.sql!("SELECT status FROM rooms WHERE room_id = $1 FOR UPDATE", [room])
          T.sql!("UPDATE rooms SET status = 'archived' WHERE room_id = $1", [room])
          :locked
        end)

      e = event(room, "m.room.member", "@late:test.local")
      change = Task.async(fn -> DB.apply_member_change(room, "@late:test.local", e, remove_member: true) end)
      await_blocked!(change, archive.backend, "the member change")

      finish(archive, :commit)
      assert {:error, :room_archived} = Task.await(change, 15_000)
      assert event_rows(room) == 1
      assert counter(room) == 1
    end
  end
end
