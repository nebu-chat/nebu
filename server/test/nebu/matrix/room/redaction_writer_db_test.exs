defmodule Nebu.Matrix.Room.RedactionWriterDbTest do
  @moduledoc """
  Story `state-writer-redaction`, REAL database, `Room.Server` and `Room.DB` directly: AC6 (atomicity, archived, crash / restart of the redaction writer),
  AC13 (migration 000051) and the database halves of AC7 (`Room.DB.apply_state_change/3`, `latest_state_identity/3`) and AC6 / D6 (`redactions_for/1`).
  `async: false`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The interfaces below are pinned here because the story names only their arities. `Room.DB.apply_redaction(room_id, signed_event)` and
      `Room.DB.apply_state_change(room_id, signed_event, opts)` answer `:ok | {:error, :room_archived} | {:error, reason}` and never raise (the contract of
      `apply_power_levels_change/3`); `opts` carries `room_name: name` (a binary) when `rooms.name` follows the event in the SAME transaction.
      `Room.DB.latest_state_identity(room_id, type, state_key)` answers `{:ok, {event_id, origin_server_ts, sender} | nil}`. `Room.DB.redactions_for(ids)` answers
      `{:ok, rows}`: one string-keyed map `event_id`, `room_id`, `sender`, `origin_server_ts`, `content`, `redacts` per writer-made redaction OF one of the ids or
      AMONG them, oldest first by `(origin_server_ts, event_id)`; a legacy row (column NULL) is never returned.
    * `Room.Server.redact(room_id, sender, target, content, txn_key)` answers `{:ok, event_id, outcome}` with `outcome` matching `%{replayed: boolean, target_sender:
      binary}` (the dispatcher needs both for the audit row: a replay and an own-event redaction are not audited), `{:error, atom}` otherwise with the atoms of D2:
      `:sender_not_joined`, `:forbidden`, `:target_not_found`, `:not_redactable`, `:insufficient_redact_level`, `:room_archived`, `:event_too_large`, `:write_failed`,
      `:unsupported_db_module`. `Room.Server.write_state(room_id, sender, {type, state_key}, content, opts)` answers `{:ok, event_id}` or `{:error, atom}`:
      `:sender_not_joined`, `:insufficient_level`, `:foreign_user_key`, `:event_too_large`, `:room_archived`, `:write_failed`, `:unsupported_db_module`.
    * The failing write INSIDE the transaction is a real database failure (a `BEFORE INSERT` trigger on `events` that raises for ONE room, the precedent of
      `power_levels_writer_db_test.exs`); the story's alternative (pre-insert the identical signed event) is pinned as its own test of `apply_redaction/2`.
    * AC6 (c) / (d) "killed DURING a redaction": the db hook kills the room process right BEFORE the transaction (the hook cannot reach into the transaction); the
      call answers `503 M_UNAVAILABLE`, the database is exactly as before and a restarted process works.
    * The migration test runs the migration files inside ONE rolled-back transaction of the privileged role (the 000041 .. 000050 precedent); the files are read at
      RUN time, so a missing file fails the test (red) and does not stop the suite from compiling.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport
  import Nebu.Matrix.RedactionTestSupport

  alias Nebu.Matrix.RedactionTestSupport.Hooks
  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.Server
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @dir Path.expand("../../../../priv/migrations", __DIR__)
  @up "000051_events_redacts.up.sql"
  @down "000051_events_redacts.down.sql"

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    # the PRIOR audit writer is snapshotted BEFORE the real one is put in place (the test environment runs a NoOp writer)
    prior_audit = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()
      Hooks.cleanup()

      case prior_audit do
        {:ok, value} -> Application.put_env(:compliance, :audit_writer, value)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    {:ok, a: user!("RWA"), b: user!("RWB"), c: user!("RWC")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp room_of(a, members) do
    room = public_room(a)
    for m <- members, do: join_now!(m, room)
    room
  end

  defp apply_redaction(room, event), do: call(DB, :apply_redaction, [room, event])
  defp apply_state_change(room, event, opts \\ []), do: call(DB, :apply_state_change, [room, event, opts])

  defp event_rows(room, event_id), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_id = $2", [room, event_id]).rows |> hd() |> hd()

  defp redact_direct(room, sender, target, txn \\ nil),
    do: call(Server, :redact, [room, uid_of(sender), target, %{}, {room, uid_of(sender), txn || T.rand(6)}])

  # the pending row lock of ONE test: another transaction holds `FOR UPDATE` on the rooms row until `:release`
  defp hold_room_lock!(room) do
    parent = self()

    holder =
      Task.async(fn ->
        Nebu.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM rooms WHERE room_id = $1 FOR UPDATE", [room])
          send(parent, :locked)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive :locked, 10_000
    holder
  end

  defp release!(holder) do
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)
  end

  # ═══ AC6 (a): atomicity of apply_redaction/2 ═══════════════════════════════════════

  describe "AC6 (a) - apply_redaction/2 is ONE transaction" do
    test "healthy: the signed redaction is written with its redacts column (positive control)", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      event = redaction_event(room, b, m, %{"reason" => "r"}, ts_after(room))

      assert :ok = apply_redaction(room, event)

      assert event_rows(room, event["event_id"]) == 1
      assert row(event["event_id"]).redacts == m
      assert row(event["event_id"]).content == %{"reason" => "r"}
    end

    test "a pre-inserted identical event (unique violation inside the transaction): {:error, _}, only the pre-inserted row exists", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      event = redaction_event(room, b, m, %{}, ts_after(room))
      assert :ok = DB.insert_event(Map.delete(event, "redacts"))
      before = event_count(room)

      assert {:error, _reason} = apply_redaction(room, event)

      assert event_count(room) == before
      assert event_rows(room, event["event_id"]) == 1
      assert row(event["event_id"]).redacts == nil, "the pre-inserted (legacy shaped) row is untouched"
    end

    test "an archived room answers {:error, :room_archived}: nothing is written", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      before = event_count(room)

      assert {:error, :room_archived} = apply_redaction(room, redaction_event(room, b, m, %{}, ts_after(room)))

      assert event_count(room) == before
    end

    @tag timeout: 60_000
    test "a row lock held by another transaction: the write fails after the 1 s lock_timeout ({:error, _}), nothing written, a retry after the release succeeds", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      before = event_count(room)
      event = redaction_event(room, b, m, %{}, ts_after(room))
      holder = hold_room_lock!(room)

      result = apply_redaction(room, event)
      release!(holder)

      assert {:error, _reason} = result, "the lock wait is bounded: the write failed instead of waiting for the release"
      assert event_count(room) == before
      assert :ok = apply_redaction(room, event)
      assert event_rows(room, event["event_id"]) == 1
    end

    test "through the route: a failing insert is a 500 (generic body), nothing written (row, ETS, broadcast, audit), a value-free ERROR log; a retry with a new txn succeeds", %{a: a, b: b} do
      room = room_of(a, [b])
      reason = word("rs")
      m = say!(b, room, "target")
      :ok = :pg.join("room:#{room}", self())
      remove = block_events!(room)
      before = rd_footprint(room)

      log = capture_log(fn -> send(self(), {:conn, redact(a, room, m, %{"reason" => reason}, "txn-one")}) end)

      assert_received {:conn, conn}
      body = assert_err(conn, 500, "M_UNKNOWN", "Internal server error")
      assert Map.keys(body) |> Enum.sort() == ["errcode", "error"]
      assert rd_footprint(room) == before, "nothing written: no event, no redaction row, no audit row"
      assert dedup_entry(redact_key(room, a, m, "txn-one")) == [], "no ETS entry"
      refute_receive {:new_event, _}, 100
      assert log =~ room, "the log names the room id"
      assert log =~ "P0", "the log names the SQLSTATE class"
      refute log =~ reason, "no reason in the log"
      refute log =~ "atdd: insert blocked", "the database error text is not logged"
      refute String.contains?(conn.resp_body, reason)

      remove.()
      id = ok_event_id!(redact(a, room, m, %{"reason" => reason}, "txn-two"), "retry")
      assert_receive {:new_event, %{"type" => "m.room.redaction", "event_id" => ^id}}, 2_000
    end
  end

  describe "AC6 (a) / D9 - the archived check lives INSIDE the transaction (an archive committed while the write is in flight)" do
    # the db hook blocks the room process right BEFORE the real transaction; the Admin archives the room (it needs the room row lock, free at that moment);
    # the released transaction then sees the archived status
    defp archive_during_write(room, request) do
      install_room_db!(Hooks.RoomDB)
      on_exit(&Hooks.disarm_db/0)
      Hooks.arm_db(%{block: room, test: self()})
      task = Task.async(request)
      victim = await_rd_gap!(:in_write)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      send(victim, :go)
      conn = Task.await(task, 30_000)
      Hooks.disarm_db()
      conn
    end

    test "a redaction in flight while the room is archived: 400 M_BAD_STATE, nothing written, nothing remembered", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      before = rd_footprint(room)

      conn = archive_during_write(room, fn -> redact(b, room, m, %{}, "txn-t") end)

      assert_err(conn, 400, "M_BAD_STATE", "M_ROOM_ARCHIVED: room is archived")
      assert rd_footprint(room) == before
      assert dedup_entry(redact_key(room, b, m, "txn-t")) == []
    end

    test "a state write in flight while the room is archived: 404 M_NOT_FOUND, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)

      conn = archive_during_write(room, fn -> put_state(a, room, "m.room.topic", %{"topic" => "in flight"}) end)

      assert_err(conn, 404, "M_NOT_FOUND", "Room not found")
      assert event_count(room) == before
    end
  end

  # ═══ Room.Server.redact/5 directly ══════════════════════════════════════════════════

  describe "Room.Server.redact/5 (real database): the answers" do
    test "another user's event: {:ok, id, %{replayed: false, target_sender: that user}}; the same key again: the same id, replayed: true, no second row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      key = {room, a.uid, "k1"}

      assert {:ok, id, %{replayed: false, target_sender: sender}} = call(Server, :redact, [room, a.uid, m, %{"reason" => "r"}, key])
      assert sender == b.uid
      assert {:ok, ^id, %{replayed: true}} = call(Server, :redact, [room, a.uid, m, %{"reason" => "r"}, key])

      assert redaction_ids(room) == [id]
      assert dedup_entry(key) == [{key, id}]
    end

    test "a target that is already redacted: {:ok, existing_id, %{replayed: true}} under ANOTHER key, nothing written, nothing remembered under the new key", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      assert {:ok, first, %{replayed: false}} = call(Server, :redact, [room, b.uid, m, %{}, {room, b.uid, "k1"}])
      new_key = {room, a.uid, "k2"}
      before = rd_footprint(room)

      assert {:ok, ^first, %{replayed: true}} = call(Server, :redact, [room, a.uid, m, %{"reason" => "x"}, new_key])

      assert rd_footprint(room) == before
      assert dedup_entry(new_key) == []
    end

    test "refusal :sender_not_joined (a user who never joined)", %{a: a, b: b, c: c} do
      {room, m} = rd_room(a, b, c)
      assert {:error, :sender_not_joined} = rd_unchanged(room, fn -> redact_direct(room, user!("RWN"), m) end)
    end

    test "refusal :forbidden (below events[m.room.redaction])", %{a: a, b: b, c: c} do
      {room, m} = rd_room(a, b, c)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 20, c.uid => 5}, %{"events" => %{"m.room.power_levels" => 50, "m.room.redaction" => 10}}))
      assert {:error, :forbidden} = rd_unchanged(room, fn -> redact_direct(room, c, m) end)
    end

    test "refusal :target_not_found (an unknown event id)", %{a: a, b: b, c: c} do
      {room, _m} = rd_room(a, b, c)
      assert {:error, :target_not_found} = rd_unchanged(room, fn -> redact_direct(room, b, "$ghost" <> T.rand(8)) end)
    end

    test "refusal :not_redactable (a state event)", %{a: a, b: b, c: c} do
      {room, _m} = rd_room(a, b, c)
      assert {:error, :not_redactable} = rd_unchanged(room, fn -> redact_direct(room, a, latest_pl(room).event_id) end)
    end

    test "refusal :insufficient_redact_level (at the redaction level but below redact, another user's event)", %{a: a, b: b, c: c} do
      {room, m} = rd_room(a, b, c)
      assert {:error, :insufficient_redact_level} = rd_unchanged(room, fn -> redact_direct(room, b, m) end)
    end

    test "an archived room (process running): {:error, :room_archived}, nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)

      assert {:error, :room_archived} = rd_unchanged(room, fn -> redact_direct(room, b, m) end)
    end

    test "a failing insert: {:error, :write_failed}; the room works again afterwards", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      remove = block_events!(room)

      assert {:error, :write_failed} = rd_unchanged(room, fn -> redact_direct(room, b, m) end)

      remove.()
      assert {:ok, _id, %{replayed: false}} = redact_direct(room, b, m)
    end

    test "Room.Server.send_event/6 refuses the type m.room.redaction: {:error, :forbidden}, nothing written (no second writer)", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")

      result = rd_unchanged(room, fn -> Server.send_event(room, b.uid, "m.room.redaction", %{"redacts" => m}, "t1") end)

      assert result == {:error, :forbidden}
      assert dedup_entry(send_key(room, b, "m.room.redaction", "t1")) == []
    end
  end

  # a room with events[m.room.redaction] 10 and redact 50: a at 100, b at 20 (at the redaction level, below redact), c at 5 (below the redaction level);
  # `m` is a message of c
  defp rd_room(a, b, c) do
    room = room_of(a, [b, c])
    seed!(room, a, levels(%{a.uid => 100, b.uid => 20, c.uid => 20}, %{"events" => %{"m.room.power_levels" => 50, "m.room.redaction" => 10}}))
    {room, say!(c, room, "target")}
  end

  # ═══ AC6 (c), (d): the room process dies or does not answer ═══════════════════════

  describe "AC6 (c) / (d) - crash / restart (.claude/rules/matrix-conventions.md)" do
    test "a room process that does not answer (killed right before the transaction): 503 M_UNAVAILABLE, the database as before, a restarted process works", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      install_room_db!(Hooks.RoomDB)
      on_exit(&Hooks.disarm_db/0)
      before = rd_footprint(room)
      Hooks.arm_db(%{kill: room})

      conn = redact(b, room, m, %{}, "txn-t")

      assert_err(conn, 503, "M_UNAVAILABLE", "The room did not answer, the redaction may or may not have been applied")
      Hooks.disarm_db()
      assert rd_footprint(room) == before, "a process killed DURING a redaction leaves no row"
      assert dedup_entry(redact_key(room, b, m, "txn-t")) == []

      restart_room!(room)
      assert in_set?(room, b.uid), "the restarted process reloads the member set"
      id = ok_event_id!(redact(b, room, m, %{}, "txn-t"), "the same txn id after the restart")
      assert redaction_ids(room) == [id]
    end

    test "after a committed redaction a killed and restarted room process: the target is still served redacted, a new redaction works", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "first target")
      second = say!(b, room, "second target")
      id = redact_id!(b, room, m)

      kill_and_restart!(room)

      assert event!(a, room, m)["content"] == %{}, "redacted is derived from the database, not from process state"
      assert event!(a, room, m)["unsigned"]["redacted_because"]["event_id"] == id
      assert row(redact_id!(b, room, second)).redacts == second
    end
  end

  defp restart_room!(room) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
      {:ok, _pid} -> kill_and_restart!(room)
      {:error, :not_found} -> Nebu.Matrix.Room.RoomSupervisor.start_room(room)
    end
  end

  # ═══ the redaction lookup of the read paths (D6) ══════════════════════════════════

  describe "Room.DB.redactions_for/1 (D6)" do
    test "at most ONE row per target: the EARLIEST (origin_server_ts, event_id), however many redaction rows exist; the redaction events AMONG the ids by id; exactly six string keys; a legacy row never", %{a: a, b: b} do
      room = room_of(a, [b])
      m1 = say!(b, room, "one")
      m2 = say!(b, room, "two")
      legacy_target = say!(b, room, "legacy target")
      first = redact_id!(b, room, m1, %{"reason" => "r1"})
      third = redact_id!(b, room, m2)
      base = row(first).ts
      # extra rows inserted directly (duplicates the writer no longer produces, or written by an older node): a later and an EARLIER one for m1
      later = redaction_event(room, a, m1, %{"reason" => "later"}, base + 5)
      earlier = redaction_event(room, a, m1, %{"reason" => "earlier"}, base - 5)
      for e <- [later, earlier], do: assert(:ok = DB.insert_event(e))
      legacy = insert_legacy_redaction!(room, b, legacy_target, %{"reason" => "old"}, base + 1)

      assert {:ok, rows} = call(DB, :redactions_for, [[m1, m2, legacy_target]])

      assert Enum.sort(Enum.map(rows, & &1["event_id"])) == Enum.sort([earlier["event_id"], third]), "one row per target: m1 -> the earliest, m2 -> its only one; the legacy target none"
      assert Enum.all?(rows, &(Enum.sort(Map.keys(&1)) == ["content", "event_id", "origin_server_ts", "redacts", "room_id", "sender"]))
      r1 = Enum.find(rows, &(&1["redacts"] == m1))
      assert r1["room_id"] == room and r1["sender"] == a.uid and r1["content"] == %{"reason" => "earlier"} and r1["origin_server_ts"] == base - 5
      # the redaction events AMONG the ids come by their own id (each at most once), also the later duplicate
      assert {:ok, by_id} = call(DB, :redactions_for, [[first, later["event_id"], legacy]])
      assert Enum.map(by_id, & &1["event_id"]) == Enum.sort_by([first, later["event_id"]], &{row(&1).ts, &1}), "by id: both writer rows, never the legacy one"
      assert {:ok, []} = call(DB, :redactions_for, [[]])
      assert {:ok, []} = call(DB, :redactions_for, [[legacy_target]])
    end

    test "a target with 30 redaction rows reads as ONE row (the read amplification of Kassandra #1 is bounded)", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "flooded")
      base = System.system_time(:millisecond)
      for n <- 1..30, do: assert(:ok = DB.insert_event(redaction_event(room, b, m, %{"reason" => "r#{n}", "x_pad" => String.duplicate("p", 2_000)}, base + n)))

      assert {:ok, [only]} = call(DB, :redactions_for, [[m]])

      assert only["content"]["reason"] == "r1"
    end
  end

  # ═══ AC7: the state writer's database half ═════════════════════════════════════════

  describe "Room.DB.latest_state_identity/3 (D8 (4))" do
    test "the newest event of the slot (ts, then event id), nil for an empty slot, other slots do not interfere", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      assert {:ok, nil} = call(DB, :latest_state_identity, [room, "m.room.topic", ""])
      ts = System.system_time(:millisecond)
      older = state_event(room, a, "m.room.topic", "", %{"topic" => "old"}, ts)
      newer = state_event(room, a, "m.room.topic", "", %{"topic" => "new"}, ts + 5)
      other = state_event(room, a, "m.room.topic", "x", %{"topic" => "other slot"}, ts + 99)
      for e <- [older, newer, other], do: assert(:ok = DB.insert_event(e))
      newer_ts = ts + 5
      other_ts = ts + 99
      newer_id = newer["event_id"]
      other_id = other["event_id"]
      sender = a.uid

      assert {:ok, {^newer_id, ^newer_ts, ^sender}} = call(DB, :latest_state_identity, [room, "m.room.topic", ""])
      assert {:ok, {^other_id, ^other_ts, ^sender}} = call(DB, :latest_state_identity, [room, "m.room.topic", "x"])
    end
  end

  describe "Room.DB.apply_state_change/3 (D8 (6), D9): ONE transaction, rooms.name in the same transaction" do
    test "healthy: the event is written; with room_name the denormalised rooms.name follows in the same transaction (positive control)", %{a: a} do
      room = public_room(a)
      event = state_event(room, a, "m.room.name", "", %{"name" => "Renamed"}, ts_after(room))

      assert :ok = apply_state_change(room, event, room_name: "Renamed")

      assert event_rows(room, event["event_id"]) == 1
      assert rooms_name(room) == "Renamed"
    end

    test "without room_name the rooms.name column is not touched", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      event = state_event(room, a, "m.room.topic", "", %{"topic" => "t"}, ts_after(room))

      assert :ok = apply_state_change(room, event)

      assert rooms_name(room) == "Original"
    end

    test "an insert that fails inside the transaction rolls rooms.name back: unchanged name, no event; a retry succeeds", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      events_before = event_count(room)
      event = state_event(room, a, "m.room.name", "", %{"name" => "Renamed"}, ts_after(room))
      remove = block_events!(room)

      assert {:error, _reason} = apply_state_change(room, event, room_name: "Renamed")

      assert rooms_name(room) == "Original", "the rooms.name UPDATE was rolled back with the failed insert"
      assert event_count(room) == events_before
      remove.()
      assert :ok = apply_state_change(room, event, room_name: "Renamed")
      assert rooms_name(room) == "Renamed"
    end

    test "an archived room answers {:error, :room_archived}: no event, rooms.name unchanged", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      events_before = event_count(room)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)

      assert {:error, :room_archived} = apply_state_change(room, state_event(room, a, "m.room.name", "", %{"name" => "X"}, ts_after(room)), room_name: "X")

      assert rooms_name(room) == "Original"
      assert event_count(room) == events_before
    end

    @tag timeout: 60_000
    test "a row lock held elsewhere: the change fails after the 1 s lock_timeout, nothing written, a retry after the release works", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      event = state_event(room, a, "m.room.topic", "", %{"topic" => "t"}, ts_after(room))
      holder = hold_room_lock!(room)

      result = apply_state_change(room, event)
      release!(holder)

      assert {:error, _reason} = result
      assert event_count(room) == before
      assert :ok = apply_state_change(room, event)
    end
  end

  describe "Room.Server.write_state/5 (real database): the answers" do
    test "client mode: {:ok, event_id}; the event is stamped, written and broadcast after the commit; a second write chains after the first", %{a: a} do
      room = public_room(a)
      :ok = :pg.join("room:#{room}", self())

      assert {:ok, first} = call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "one"}, []])
      assert_receive {:new_event, %{"event_id" => ^first, "type" => "m.room.topic"}}, 2_000
      assert {:ok, second} = call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "two"}, []])

      assert Enum.map(slot_events(room, "m.room.topic"), & &1.event_id) == [first, second]
      [one, two] = slot_events(room, "m.room.topic")
      assert two.ts > one.ts, "strictly after the previous event of the slot"
    end

    test "refusals: :sender_not_joined, :insufficient_level, :foreign_user_key, nothing written", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)

      assert {:error, :sender_not_joined} = rd_unchanged(room, fn -> call(Server, :write_state, [room, user!("RWN").uid, {"m.room.topic", ""}, %{"topic" => "x"}, []]) end)
      assert {:error, :insufficient_level} = rd_unchanged(room, fn -> call(Server, :write_state, [room, b.uid, {"m.room.topic", ""}, %{"topic" => "x"}, []]) end)
      assert {:error, :foreign_user_key} = rd_unchanged(room, fn -> call(Server, :write_state, [room, a.uid, {"m.room.topic", b.uid}, %{"topic" => "x"}, []]) end)
      assert {:ok, _id} = call(Server, :write_state, [room, a.uid, {"m.room.topic", a.uid}, %{"topic" => "own key"}, []]), "the own @id key is allowed"
    end

    test "a failing insert: {:error, :write_failed}, nothing written; an archived room: {:error, :room_archived}", %{a: a} do
      room = public_room(a)
      remove = block_events!(room)

      assert {:error, :write_failed} = rd_unchanged(room, fn -> call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "x"}, []]) end)

      remove.()
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert {:error, :room_archived} = rd_unchanged(room, fn -> call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "x"}, []]) end)
    end

    test "tombstone mode: the level is max(events[m.room.tombstone] else state_default, 100): a user at 60 with the tombstone level 50 is refused, at 100 allowed", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 60}, %{"events" => %{"m.room.power_levels" => 50, "m.room.tombstone" => 50}}))
      content = %{"body" => "This room has been replaced", "replacement_room" => "!x:test.local"}

      assert {:error, :insufficient_level} = rd_unchanged(room, fn -> call(Server, :write_state, [room, b.uid, {"m.room.tombstone", ""}, content, [mode: :tombstone]]) end)
      assert {:ok, id} = call(Server, :write_state, [room, a.uid, {"m.room.tombstone", ""}, content, [mode: :tombstone]])
      assert Enum.map(slot_events(room, "m.room.tombstone"), & &1.event_id) == [id]
    end

    test "tombstone mode: an archived room is refused, nothing written", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)

      assert {:error, :room_archived} = rd_unchanged(room, fn -> call(Server, :write_state, [room, a.uid, {"m.room.tombstone", ""}, %{"replacement_room" => "!x:test.local"}, [mode: :tombstone]]) end)

      assert slot_events(room, "m.room.tombstone") == []
    end

    test "the stamp follows the latest event of the slot (read from the database on every call): 250 ms ahead, never a tie, and a restarted process does the same", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.topic", "", %{"topic" => "future"}, future))

      assert {:ok, id} = call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "now"}, []])
      clock_after = System.system_time(:millisecond)

      written = Enum.find(slot_events(room, "m.room.topic"), &(&1.event_id == id))
      assert written.ts > future, "stamped after the (future) latest event of the slot"
      if clock_after < future, do: assert(written.ts == future + 1, "stamped previous + 1, not the (earlier) clock")

      kill_and_restart!(room)
      assert {:ok, id2} = call(Server, :write_state, [room, a.uid, {"m.room.topic", ""}, %{"topic" => "after restart"}, []])
      assert Enum.find(slot_events(room, "m.room.topic"), &(&1.event_id == id2)).ts > written.ts, "no cached stamp: a restarted process reads the database"
    end
  end

  # ═══ AC13: migration 000051 ═══════════════════════════════════════════════════════

  describe "AC13 - migration 000051 (events.redacts + the partial index)" do
    defp probe(tx) do
      %{rows: [[column]]} =
        Postgrex.query!(
          tx,
          "SELECT count(*) FROM information_schema.columns WHERE table_name = 'events' AND column_name = 'redacts' AND table_schema = current_schema()",
          []
        )

      %{rows: [[index]]} = Postgrex.query!(tx, "SELECT count(*) FROM pg_indexes WHERE tablename = 'events' AND indexname = 'events_redacts_idx'", [])
      {column, index}
    end

    test "the files exist: 000051 is the next free number after 000050", _ctx do
      assert File.exists?(Path.join(@dir, @up)), "#{@up} missing"
      assert File.exists?(Path.join(@dir, @down)), "#{@down} missing"
      assert Path.wildcard(Path.join(@dir, "000051_*.up.sql")) == [Path.join(@dir, @up)]
      assert File.exists?(Path.join(@dir, "000050_room_invitations_pending_inviter_idx.up.sql"))
    end

    test "up is idempotent DDL without CONCURRENTLY and without transaction management; the column is TEXT, nullable, no default", _ctx do
      sql = @dir |> Path.join(@up) |> File.read!() |> String.replace(~r/--[^\n]*/, "")
      assert sql =~ ~r/ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+redacts\s+TEXT\s*;/i
      refute sql =~ ~r/redacts\s+TEXT\s+(NOT\s+NULL|DEFAULT)/i, "nullable, no default, no backfill"
      assert sql =~ ~r/CREATE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+events_redacts_idx/i
      refute sql =~ ~r/CONCURRENTLY/i
      refute sql =~ ~r/^\s*(BEGIN|COMMIT)\s*;/im
      refute sql =~ ~r/\bUPDATE\b|\bDELETE\b/i, "no data change"
    end

    test "up: the column and the partial index exist as specified (the migrated database)", _ctx do
      assert {1, 1} = T.with_privileged_conn(&probe/1)

      %{rows: [[type, nullable, default]]} =
        T.sql!("SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_name = 'events' AND column_name = 'redacts'")

      assert {type, nullable, default} == {"text", "YES", nil}
      [[definition]] = T.sql!("SELECT indexdef FROM pg_indexes WHERE tablename = 'events' AND indexname = 'events_redacts_idx'").rows
      assert definition =~ "(redacts, origin_server_ts, event_id)", "the index serves the earliest-per-target lookup: the D6 lookup has no room_id predicate (target ids are global hashes)"
      refute definition =~ "room_id"
      assert definition =~ ~r/WHERE \(?redacts IS NOT NULL\)?/
      refute definition =~ "UNIQUE"
    end

    test "down removes both, up restores both, up twice is a no-op (everything inside a rolled-back transaction)", _ctx do
      up = File.read!(Path.join(@dir, @up))
      down = File.read!(Path.join(@dir, @down))

      result =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, down, [], query_type: :text)
            after_down = probe(tx)
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up = probe(tx)
            Postgrex.query!(tx, up, [], query_type: :text)
            after_up_twice = probe(tx)
            Postgrex.rollback(tx, {:round_trip, after_down, after_up, after_up_twice})
          end)
        end)

      assert {:error, {:round_trip, after_down, after_up, after_up_twice}} = result
      assert after_down == {0, 0}, "down: the column and the index are gone"
      assert after_up == {1, 1}
      assert after_up_twice == {1, 1}, "up is idempotent"
      assert {1, 1} = T.with_privileged_conn(&probe/1), "the rollback left the migrated database untouched"
    end

    test "a redacts value is written only for writer-made redactions: every other insert leaves NULL", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "message")
      ok_event_id!(put_state(a, room, "m.room.topic", %{"topic" => "t"}), "topic")
      legacy = insert_legacy_redaction!(room, b, m, %{}, System.system_time(:millisecond))
      count = fn -> T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND redacts IS NOT NULL", [room]).rows |> hd() |> hd() end

      assert count.() == 0, "messages, state events, member events and a legacy redaction leave the column NULL"
      assert row(legacy).redacts == nil

      id = redact_id!(b, room, m)

      assert count.() == 1
      assert T.sql!("SELECT event_id, event_type FROM events WHERE room_id = $1 AND redacts IS NOT NULL", [room]).rows == [[id, "m.room.redaction"]]
    end

    # (security cycle 2, review M7) the statement of Room.DB itself is pinned from its source: it is bounded in SQL (DISTINCT ON per target, the
    # earliest by (origin_server_ts, event_id)), never "load every redaction, keep one"
    test "Room.DB's redactions_for/1 statement is the DISTINCT ON (redacts) ... ORDER BY redacts, origin_server_ts, event_id lookup (source pin)", _ctx do
      source = File.read!(Path.expand("../../../../lib/nebu/matrix/room/db.ex", __DIR__))
      [_, sql] = Regex.run(~r/@sql_redactions_for """(.*?)"""/s, source)

      assert sql =~ "DISTINCT ON (redacts)"
      assert sql =~ ~r/ORDER BY redacts, origin_server_ts, event_id\b/
      assert sql =~ ~r/WHERE redacts IS NOT NULL AND redacts = ANY\(\$1\)/
    end

    # story decision STORY-4 / security cycle 1: the D6 lookup has no room_id predicate (target ids are global content hashes), so the partial index leads with
    # redacts, followed by (origin_server_ts, event_id) for the earliest per target; the plan is checked on the DISTINCT ON part of the pinned statement above
    test "the earliest-per-target lookup (DISTINCT ON redacts ORDER BY redacts, origin_server_ts, event_id) uses the partial index events_redacts_idx", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "message")
      redact_id!(b, room, m)

      plan =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "SET LOCAL enable_seqscan = off", [])

            %{rows: rows} =
              Postgrex.query!(
                tx,
                "EXPLAIN SELECT DISTINCT ON (redacts) event_id, room_id, sender, origin_server_ts, content, redacts FROM events WHERE redacts IS NOT NULL AND redacts = ANY($1) ORDER BY redacts, origin_server_ts, event_id",
                [[m]]
              )

            Postgrex.rollback(tx, Enum.map_join(rows, "\n", &hd/1))
          end)
        end)

      assert {:error, text} = plan
      assert text =~ "events_redacts_idx", "the partial index serves the lookup: #{text}"
    end
  end
end
