defmodule Nebu.Matrix.Room.PowerLevelsWriterDbTest do
  @moduledoc """
  Story `power-levels-enforcement`, REAL database, `Room.Server` and `Room.DB` directly: AC4 (d) (the deterministic gap test of the membership
  re-check of `/send`), AC6 (a), (c) - (f) (one transaction, the stamp, the four sources, the archived room, `set_power_levels/3` through the
  same transaction) and AC8 (crash / restart). `async: false`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The failing write INSIDE the transaction is a real database failure, not a fake: a `BEFORE INSERT` trigger on `events` that raises for ONE
      room (created through the privileged connection, dropped in `on_exit`; the precedent of `moderation_atomic_db_test.exs`). The column
      `UPDATE` has then really run inside the transaction when the insert fails, so an unchanged column proves the rollback. The story's
      alternative (pre-insert the identical signed event) is pinned as its own test of `Room.DB.apply_power_levels_change/3`.
    * `Room.DB.apply_power_levels_change/3` is reached through `call/3` with a variable name, so the file compiles before the function exists
      (CI compiles with `--warnings-as-errors`); the shape pinned is the story's: `(room_id, content_json, signed_event)` -> `:ok | {:error, reason}`,
      an archived room is exactly `{:error, :room_archived}`.
    * The internal writer `Room.Server.set_power_levels/3` answers `:ok` and, for a failing write, `{:error, :write_failed}` (the atom of D10).
    * AC6 (c): the PL event 250 ms ahead of the clock is inserted directly into an own room and the room process is RESTARTED, so the identity
      the process uses is the one loaded from the database (story: "the identity in `state.power_levels_event`, re-read ... when it is nil");
      every event of the room is deleted in `on_exit` (follow-up `fj`, the DELETE result is asserted).
    * AC8 "killed DURING a change": the db hook kills the room process right BEFORE the transaction (the hook cannot reach into the transaction);
      the call answers `503 M_UNAVAILABLE`, the database is exactly as before and a restarted process reloads that state.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport

  alias Nebu.Matrix.PowerLevelsTestSupport.Hooks
  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.Server
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @pl "m.room.power_levels"

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    # config/test.exs runs a NoOp audit writer: the audit assertions need the real one. The PRIOR value is snapshotted BEFORE it is replaced.
    prior_audit = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()

      case prior_audit do
        {:ok, value} -> Application.put_env(:compliance, :audit_writer, value)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    {:ok, a: user!("PWA"), b: user!("PWB"), c: user!("PWC")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # an INSERT trigger on `events` that raises for ONE room: the insert of every event of the room fails (dropped in on_exit)
  defp block_events!(room) do
    name = "atdd_pl_block_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.room_id = '#{room}' THEN RAISE EXCEPTION 'atdd: insert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON events")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    on_exit(remove)
    remove
  end

  # a signed-looking levels event as the room process would build it (the transaction only inserts it)
  defp levels_event(room, sender, content, ts) do
    %{
      "event_id" => "$" <> T.rand(16),
      "room_id" => room,
      "sender" => uid_of(sender),
      "type" => @pl,
      "state_key" => "",
      "content" => content,
      "origin_server_ts" => ts,
      "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(64))}
    }
  end

  defp apply_change(room, content, event), do: call(DB, :apply_power_levels_change, [room, Jason.encode!(content), event])

  defp event_rows(room, event_id), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_id = $2", [room, event_id]).rows |> hd() |> hd()

  defp restart!(room) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
      {:ok, _pid} -> kill_and_restart!(room)
      {:error, :not_found} -> Nebu.Matrix.Room.RoomSupervisor.start_room(room)
    end
  end

  defp changed(room, changes), do: Map.merge(column(room), changes)

  # ═══ AC4 (d): the membership re-check of /send, decided in the room process ═══════════

  describe "AC4 (d) - a kick committed between the dispatcher's membership check and the room call" do
    test "/send is 403 (the existing text) and no message is written; without the gap the same sender sends (positive control)", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      assert text_message(b, room).status == 200, "positive control: a member sends"

      install_env!(:event_dispatcher, :room_registry_module, Hooks.RegistryGap)
      on_exit(&Hooks.disarm_gap/0)
      Hooks.arm_gap(room, b.uid, self())
      messages_before = T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND sender = $2 AND event_type = 'm.room.message'", [room, b.uid]).rows

      task =
        Task.async(fn ->
          Process.put(:atdd_pl_gap_victim, true)
          text_message(b, room)
        end)

      victim = await_gap!(:snapshot)
      ok!(kick(a, room, b), "the kick commits inside the gap")
      send(victim, :go)
      conn = Task.await(task, 30_000)

      assert_err(conn, 403, "M_FORBIDDEN", "You are not a member of this room")
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND sender = $2 AND event_type = 'm.room.message'", [room, b.uid]).rows == messages_before
      refute in_set?(room, b.uid)
    end

    test "the same gap with a BAN committed inside it: 403 and nothing written", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      install_env!(:event_dispatcher, :room_registry_module, Hooks.RegistryGap)
      on_exit(&Hooks.disarm_gap/0)
      Hooks.arm_gap(room, b.uid, self())
      before = event_count(room)

      task =
        Task.async(fn ->
          Process.put(:atdd_pl_gap_victim, true)
          text_message(b, room)
        end)

      victim = await_gap!(:snapshot)
      ok!(ban(a, room, b), "the ban commits inside the gap")
      send(victim, :go)

      assert_err(Task.await(task, 30_000), 403, "M_FORBIDDEN", "You are not a member of this room")
      assert event_count(room) == before + 1, "only the ban event was written"
    end
  end

  # ═══ AC6 (a): atomicity ═════════════════════════════════════════════════════════

  describe "AC6 (a) - apply_power_levels_change/3 is ONE transaction" do
    test "healthy: the column and the event are written together (positive control)", %{a: a} do
      room = public_room(a)
      new = changed(room, %{"events_default" => 10})
      event = levels_event(room, a, new, ts_after(room))

      assert :ok = apply_change(room, new, event)

      assert column(room) == new
      assert event_rows(room, event["event_id"]) == 1
    end

    test "an event insert that fails INSIDE the transaction rolls back the column: unchanged column, no event; a retry succeeds", %{a: a} do
      room = public_room(a)
      old = column(room)
      events_before = event_count(room)
      new = changed(room, %{"events_default" => 10})
      event = levels_event(room, a, new, ts_after(room))
      remove = block_events!(room)

      assert {:error, _reason} = apply_change(room, new, event)

      assert column(room) == old, "the column UPDATE was rolled back"
      assert event_count(room) == events_before
      assert event_rows(room, event["event_id"]) == 0

      remove.()
      assert :ok = apply_change(room, new, event)
      assert column(room) == new
    end

    test "a pre-inserted identical event (unique violation inside the transaction) leaves the column unchanged", %{a: a} do
      room = public_room(a)
      old = column(room)
      new = changed(room, %{"events_default" => 10})
      event = levels_event(room, a, new, ts_after(room))
      assert :ok = DB.insert_event(event)

      assert {:error, _reason} = apply_change(room, new, event)

      assert column(room) == old, "the column UPDATE was rolled back with the failed insert"
      assert event_rows(room, event["event_id"]) == 1, "only the pre-inserted row exists"
    end

    test "an archived room answers {:error, :room_archived}: nothing is written", %{a: a} do
      room = public_room(a)
      old = column(room)
      events_before = event_count(room)
      new = changed(room, %{"events_default" => 10})
      event = levels_event(room, a, new, ts_after(room))
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)

      assert {:error, :room_archived} = apply_change(room, new, event)

      assert column(room) == old
      assert event_count(room) == events_before
    end

    @tag timeout: 60_000
    test "a row lock held by another transaction: the change fails after the 1 s lock_timeout ({:error, _}), column and events unchanged, a retry after the release succeeds", %{a: a} do
      room = public_room(a)
      old = column(room)
      events_before = event_count(room)
      new = changed(room, %{"events_default" => 10})
      event = levels_event(room, a, new, ts_after(room))
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
      # the writer's `FOR NO KEY UPDATE` (fix cycle 1, review I7; was `FOR SHARE`) waits on the held row lock; without `SET LOCAL lock_timeout` it would wait for the release (up to 30 s) and then succeed
      result = apply_change(room, new, event)
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 10_000)

      assert {:error, _reason} = result, "the lock wait is bounded: the change failed instead of waiting for the release"
      assert column(room) == old
      assert event_count(room) == events_before
      assert :ok = apply_change(room, new, event)
      assert column(room) == new
    end

    test "through the route: 500 with the fixed text, nothing changed, no broadcast, no audit row, value-free ERROR log (room, SQLSTATE class); a retry works", %{a: a} do
      room = public_room(a)
      :ok = :pg.join("room:#{room}", self())
      marker = marker("secret")
      new = changed(room, %{"events_default" => 10, "x_custom" => marker})
      remove = block_events!(room)
      before = pl_footprint(room)

      log = capture_log(fn -> send(self(), {:conn, put_pl(a, room, new)}) end)

      assert_received {:conn, conn}
      body = assert_err(conn, 500, "M_UNKNOWN", "The power levels could not be changed")
      refute String.contains?(conn.resp_body, marker)
      assert Map.keys(body) |> Enum.sort() == ["errcode", "error"]
      assert pl_footprint(room) == before, "nothing changed: no column, event, in-memory level, audit row"
      refute_receive {:new_event, _}, 100

      assert log =~ room, "the log names the room id"
      assert log =~ "P0", "the log names the SQLSTATE class"
      refute log =~ marker, "no content in the log"
      refute log =~ "atdd: insert blocked", "the database error text is not logged"

      remove.()
      id = ok_event_id!(put_pl(a, room, new), "retry")
      assert_receive {:new_event, %{"type" => @pl, "event_id" => ^id}}, 2_000
      assert_agree(room)
    end
  end

  # ═══ AC6 (c): the stamp ═════════════════════════════════════════════════════════

  describe "AC6 (c) - the stamp is max(now, latest levels ts + 1)" do
    test "a levels event 250 ms ahead of the clock: the next PUT is stamped previous + 1, is the latest levels event, /sync shows it", %{a: a} do
      room = public_room(a)
      on_exit(fn -> assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room]) end)
      current = column(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(levels_event(room, a, current, future))
      restart!(room)
      assert {_id, ^future, _sender} = memory_identity(room), "the restarted process knows the identity of the future event"
      new = changed(room, %{"events_default" => 11})

      id = ok_event_id!(put_pl(a, room, new))
      clock_after = System.system_time(:millisecond)

      latest = latest_pl(room)
      assert latest.event_id == id
      # always: strictly after the (future) previous event. The exact +1 is pinned only while the clock is still behind it (a slow box may
      # pass the 250 ms window, then the stamp is the clock); the unit test (60 s ahead, fake db) pins the exact +1 unconditionally.
      assert latest.ts > future, "stamped after the previous levels event"
      if clock_after < future, do: assert(latest.ts == future + 1, "stamped previous + 1, not the (earlier) clock")
      assert identity_row(room) == {id, latest.ts, a.uid}, "it is the latest event of @sql_power_levels_identity"
      assert sync_pl(a, room)["content"] == new
      assert_agree(room)
    end

    test "eight changes in a row without a clock wait: the stamps are strictly increasing, no tie in the slot", %{a: a} do
      room = public_room(a)

      for n <- 1..8, do: ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => n})))

      stamps = room |> pl_events() |> Enum.map(& &1.ts)
      assert stamps == Enum.sort(Enum.uniq(stamps)), "strictly increasing: #{inspect(stamps)}"
      assert_agree(room)
    end
  end

  # ═══ AC6 (d): the four sources agree ═══════════════════════════════════════════

  describe "AC6 (d) - after a committed change the four sources agree" do
    test "after a PUT: the same content in all four places and the same event id in /sync, the latest event and the identity", %{a: a} do
      room = public_room(a)
      new = changed(room, %{"events_default" => 5, "users_default" => 1})

      id = ok_event_id!(put_pl(a, room, new))

      assert assert_agree(room) == new
      ev = sync_pl(a, room)
      assert ev["content"] == new
      assert ev["event_id"] == id
      assert ev["sender"] == a.uid
    end

    test "after an internal seed (set_power_levels/3) too, and after a no-op nothing moved", %{a: a} do
      room = public_room(a)
      seed!(room, a, levels(%{a.uid => 100}, %{"events_default" => 3}))
      assert assert_agree(room)["events_default"] == 3

      before = pl_footprint(room)
      ok_event_id!(put_pl(a, room, column(room)))
      assert pl_footprint(room) == before
      assert sync_pl(a, room)["event_id"] == latest_pl(room).event_id
    end
  end

  # ═══ AC6 (e): the archived room ═════════════════════════════════════════════════

  describe "AC6 (e) - an archived room (status set, the process still running)" do
    test "a PUT is 404 \"Room not found\" and nothing is written", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), "the process still runs"

      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"events_default" => 5})) end)

      assert_err(conn, 404, "M_NOT_FOUND", "Room not found")
    end
  end

  # ═══ AC6 (f): the internal writer ═══════════════════════════════════════════════

  describe "AC6 (f) - set_power_levels/3 (:internal) writes through the same transaction" do
    test "a failing event insert leaves the column, the event and the in-memory levels untouched: {:error, :write_failed}", %{a: a} do
      room = public_room(a)
      remove = block_events!(room)
      before = pl_footprint(room)

      assert {:error, :write_failed} = Server.set_power_levels(room, a.uid, levels(%{a.uid => 100}, %{"events_default" => 9}))

      assert pl_footprint(room) == before, "no half state: the column does not change without the event"
      remove.()
      assert :ok = Server.set_power_levels(room, a.uid, levels(%{a.uid => 100}, %{"events_default" => 9}))
      assert assert_agree(room)["events_default"] == 9
    end

    test "an unauthorised internal caller keeps the existing refusal {:error, :forbidden} and writes nothing", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      before = pl_footprint(room)
      assert {:error, :forbidden} = Server.set_power_levels(room, b.uid, levels(%{a.uid => 100, b.uid => 100}))
      assert pl_footprint(room) == before
    end
  end

  # ═══ D1: the unrouted dispatcher writer is the client mode ═══════════════════════

  describe "D1 - EventDispatcher.Server.set_power_levels/2 (unrouted) runs in mode: :client" do
    defp dispatcher_set(user, room, content) do
      req = %Core.SetPowerLevelsRequest{room_id: room, power_levels_json: Jason.encode!(content)}
      Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_power_levels(req, Nebu.Matrix.Http.stream(user.uid)) end)
    end

    test "a member at 50 cannot grant 51 (the v10 change rules apply, nothing written); the creator's valid change is written through the one writer", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      before = pl_footprint(room)

      assert {:error, {403, "M_FORBIDDEN", "You cannot grant a power level above your own"}} = dispatcher_set(b, room, Map.put(column(room), "ban", 51))
      assert pl_footprint(room) == before

      assert {:ok, %Core.SetPowerLevelsResponse{}} = dispatcher_set(a, room, Map.put(column(room), "events_default", 3))
      assert assert_agree(room)["events_default"] == 3
    end
  end

  # ═══ AC8: crash / restart ═══════════════════════════════════════════════════════

  describe "AC8 - crash / restart (.claude/rules/matrix-conventions.md)" do
    test "after a committed change a killed and restarted room process reloads the content AND the identity; enforcement uses the new levels", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join_now!(u, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      third = user!("PWD")
      join_now!(third, room)
      ok!(kick(b, room, third), "positive control: b at 50 may kick")

      demoted = update_in(column(room), ["users"], &Map.put(&1, b.uid, 0))
      id = ok_event_id!(put_pl(a, room, demoted))
      {_id, ts, sender} = identity_row(room)

      kill_and_restart!(room)

      assert memory(room) == demoted, "the reloaded levels equal the new content"
      assert memory_identity(room) == {id, ts, sender}, "the reloaded identity is the event of the change"
      assert_err(kick(b, room, c), 403, "M_FORBIDDEN", "You do not have a high enough power level to kick from this room.")
      assert in_set?(room, c.uid)
    end

    test "a process killed DURING a change (killed by a db hook before the commit) leaves the column and the events exactly as before", %{a: a} do
      room = public_room(a)
      install_room_db!(Hooks.RoomDB)
      on_exit(&Hooks.disarm_db/0)
      old = column(room)
      column_before = column_text(room)
      ids_before = Enum.map(pl_events(room), & &1.event_id)
      events_before = event_count(room)
      Hooks.arm_db(%{kill: room})

      conn = put_pl(a, room, changed(room, %{"events_default" => 10}))

      assert_err(conn, 503, "M_UNAVAILABLE", "The room did not answer, the change may or may not have been applied")
      Hooks.disarm_db()
      assert column_text(room) == column_before
      assert Enum.map(pl_events(room), & &1.event_id) == ids_before
      assert event_count(room) == events_before
      assert pl_audit(room) == []

      restart!(room)
      assert memory(room) == old, "a restarted process reloads the state exactly as before"
      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 10})), "the room works again")
    end
  end
end
