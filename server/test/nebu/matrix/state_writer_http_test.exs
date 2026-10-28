defmodule Nebu.Matrix.StateWriterHttpTest do
  @moduledoc """
  Story `state-writer-redaction` (follow-ups `fv`, `fz`, `fx`, the PUT-state part of `eu`), the state-writer half over HTTP: AC7, AC8, AC10 and the Oracle tests
  AC17 (i) (the PUT-state half, side by side with the `/redact` half), (k) - (o). Real stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, real
  `Room.Server` / Horde / `:pg`. The writer's own database claims (atomicity, the lock timeout, the stamp, the tombstone mode) are in
  `room/redaction_writer_db_test.exs`, the races in `state_writer_redaction_concurrency_test.exs`, the fake-database half (AC7 (f)) in
  `room/state_writer_redaction_unit_test.exs`.

  ## Decisions of the ATDD step (ambiguities of the story, listed in the report)

    * AC7 (g): the text of the refusal of a type that is not on the allowlist stays today's generic `403 M_FORBIDDEN` "You are not a member of this room" (the
      story: "the answers and their order stay"); only the RAISED error gets the explicit errcode, which is asserted on `EventDispatcher.Server.set_room_state/2`
      directly (the four refusals), since `Http.map_error/1` already turns an errcode-less `permission_denied` into `M_FORBIDDEN`.
    * AC10 (e): an upgrade of an ARCHIVED old room (the process still running) is refused with the answer of the state writer for an archived room,
      `404 M_NOT_FOUND "Room not found"` (D8, the power-level branch), nothing written, no new room left behind; the story only says "refused".
    * AC10 (d): the deterministic gap is the registry seam of the upgrade's snapshot (`:event_dispatcher, :room_registry_module`, `Hooks.RegistryGap` of the
      power-level story): the victim blocks right AFTER the snapshot read, the demotion is committed through the internal writer by ANOTHER admin at 100 (a
      creator at 150 above the upgrader would already fail the D8 pre-check "no level above the upgrader's"), then the victim is released. "No new room left
      behind" is the set of running room processes and the row count of `rooms` before and after.
    * AC7 (h): the audit row of the Admin Space form is `space_name_changed` (story space-edit-audit); "through the same writer" is proven by the slot stamp
      (a future-dated slot event is followed, which the former caller-side insert did not do).
    * AC17 (m) is today's behaviour (the creator lock-out of story power-levels-enforcement D7): a pin that is GREEN before the dev step, like the creator-key
      half of AC17 (n).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport
  import Nebu.Matrix.RedactionTestSupport

  alias Nebu.Matrix.PowerLevelsTestSupport.Hooks, as: PlHooks
  alias Nebu.Matrix.RedactionTestSupport.Hooks, as: RdHooks
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @pl "m.room.power_levels"
  @not_member "You are not a member of this room"
  @state_text "You do not have a high enough power level to set this state"
  @at_text "You cannot set a state event whose state key is another user's id"
  @upgrade_text "You do not have a high enough power level to upgrade this room"

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    # the PRIOR audit writer is snapshotted BEFORE the real one is put in place (the test environment runs a NoOp writer)
    prior_audit = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()
      PlHooks.disarm_gap()
      PlHooks.disarm_before_archive()

      case prior_audit do
        {:ok, value} -> Application.put_env(:compliance, :audit_writer, value)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    {:ok, a: user!("SWA"), b: user!("SWB"), c: user!("SWC")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp room_of(a, members) do
    room = public_room(a)
    for m <- members, do: join_now!(m, room)
    room
  end

  defp topic_body(text), do: %{"topic" => text}

  defp alias_for(localpart), do: "##{localpart}:#{T.server_name()}"

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  # the raised error of EventDispatcher.Server.set_room_state/2 (no HTTP mapping in between)
  defp raised(user, room, type, key, content) do
    req = %Core.SetRoomStateRequest{room_id: room, sender_id: uid_of(user), event_type: type, state_key: key, content_json: Jason.encode!(content)}

    try do
      Nebu.Matrix.EventDispatcher.Server.set_room_state(req, nil)
      flunk("expected a Nebu.Matrix.Error")
    rescue
      e in Nebu.Matrix.Error -> e
    end
  end

  # the full footprint of a state write: the event count of the room, the topic slot, rooms.name
  defp state_footprint(room), do: {event_count(room), Enum.map(slot_events(room, "m.room.topic"), & &1.event_id), rooms_name(room)}

  defp unchanged_state(room, fun) do
    before = state_footprint(room)
    result = fun.()
    assert state_footprint(room) == before, "a refused request must write NOTHING"
    result
  end

  # the latest event of `type` ("") of a room in a FULL /sync of `user`: the state block first, then the timeline
  defp sync_state_event(user, room, type) do
    body = sync(user)
    (join_state(body, room) ++ join_timeline(body, room)) |> Enum.filter(&(&1["type"] == type)) |> List.last()
  end

  # ═══ AC7: the generic state writer ═══════════════════════════════════════════════════

  describe "AC7 (a) - a topic PUT is decided and written by the room process" do
    test "200 {event_id}; /sync shows the event with unsigned.replaces_state / prev_content of the previous topic and the sender", %{a: a} do
      room = public_room(a)
      first = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("one")), "first")
      second = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("two")), "second")

      ev = sync_state_event(a, room, "m.room.topic")

      assert ev["event_id"] == second and ev["sender"] == a.uid and ev["content"] == topic_body("two")
      assert ev["unsigned"]["replaces_state"] == first
      assert ev["unsigned"]["prev_content"] == topic_body("one")
      assert Enum.map(slot_events(room, "m.room.topic"), & &1.event_id) == [first, second]
    end
  end

  describe "AC7 (b) - the slot stamp (the PUT-state part of follow-up eu)" do
    test "a topic event 250 ms AHEAD of the clock: a PUT at once is stamped after it (previous + 1 while the clock is behind it) and is the latest topic in /sync", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.topic", "", topic_body("future"), future))

      id = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("now")), "PUT")
      clock_after = System.system_time(:millisecond)

      written = Enum.find(slot_events(room, "m.room.topic"), &(&1.event_id == id))
      assert written.ts > future, "stamped strictly after the (future) latest event of the slot"
      if clock_after < future, do: assert(written.ts == future + 1, "stamped previous + 1, not the (earlier) clock")
      assert sync_state_event(a, room, "m.room.topic")["event_id"] == id, "it is the latest topic in /sync"
    end

    test "eight PUTs of one slot in a row without a clock wait: strictly increasing stamps, no tie", %{a: a} do
      room = public_room(a)

      for n <- 1..8, do: ok_event_id!(put_state(a, room, "m.room.topic", topic_body("t#{n}")), "PUT #{n}")

      stamps = room |> slot_events("m.room.topic") |> Enum.map(& &1.ts)
      assert length(stamps) == 8
      assert stamps == Enum.sort(Enum.uniq(stamps)), "strictly increasing: #{inspect(stamps)}"
    end

    test "a PUT after a room process restart stamps after the latest slot event (read from the database, no cached stamp)", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      first = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("before")), "before")
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.topic", "", topic_body("future"), future))
      kill_and_restart!(room)

      id = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("after the restart")), "after")

      events = slot_events(room, "m.room.topic")
      assert Enum.map(events, & &1.event_id) |> List.first() == first
      assert Enum.find(events, &(&1.event_id == id)).ts > future
    end
  end

  describe "AC7 (c) - rooms.name follows an m.room.name event with the empty state key in the SAME transaction" do
    test "PUT m.room.name with state key \"\" updates rooms.name", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      ok_event_id!(put_state(a, room, "m.room.name", %{"name" => "Renamed"}), "PUT")
      assert rooms_name(room) == "Renamed"
    end

    test "an insert failure leaves rooms.name unchanged (500, no event)", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      before = event_count(room)
      remove = block_events!(room)

      conn = put_state(a, room, "m.room.name", %{"name" => "Renamed"})

      assert conn.status == 500
      assert rooms_name(room) == "Original", "the denormalisation is atomic with the event"
      assert event_count(room) == before
      remove.()
      ok_event_id!(put_state(a, room, "m.room.name", %{"name" => "Renamed"}), "retry")
      assert rooms_name(room) == "Renamed"
    end

    test "m.room.name with state key \"x\" does NOT touch rooms.name (200, the event is written)", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      before = event_count(room)

      ok_event_id!(put_state_key(a, room, "m.room.name", "x", %{"name" => "Other slot"}), "PUT")

      assert rooms_name(room) == "Original"
      assert event_count(room) == before + 1
    end
  end

  describe "AC7 (d) / (e) - archived room, failing write" do
    test "an archived room (the process still running): 404 M_NOT_FOUND \"Room not found\" (errcode asserted), nothing written", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert running?(room), "the process still runs"

      conn = unchanged_state(room, fn -> put_state(a, room, "m.room.topic", topic_body("x")) end)

      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found", ["x"])
    end

    test "a failing write: 500 with the generic body; the ERROR log names the room id and the SQLSTATE class only (no content, no inspect)", %{a: a} do
      room = public_room(a)
      marker = word("mk")
      remove = block_events!(room)
      before = state_footprint(room)

      log = capture_log(fn -> send(self(), {:conn, put_state(a, room, "m.room.topic", topic_body(marker))}) end)

      assert_received {:conn, conn}
      body = assert_err(conn, 500, "M_UNKNOWN", "Internal server error")
      assert Map.keys(body) |> Enum.sort() == ["errcode", "error"]
      refute conn.resp_body =~ marker
      assert state_footprint(room) == before
      assert log =~ room, "the log names the room id"
      assert log =~ "P0", "the log names the SQLSTATE class"
      refute log =~ marker, "no content in the log"
      refute log =~ "atdd: insert blocked", "the database error text is not logged"
      refute log =~ "%Postgrex.Error", "no inspect of the error"
      refute log =~ "set_room_state failed:", "the former `en` text of this path is gone"
      remove.()
    end
  end

  describe "AC7 (g) - the answers and their order stay, each now with an explicit M_FORBIDDEN" do
    test "a type that is not writable (m.room.member): 403 M_FORBIDDEN, nothing written; the raised error carries the errcode", %{a: a} do
      room = public_room(a)
      conn = unchanged_state(room, fn -> put_state_key(a, room, "m.room.member", a.uid, %{"membership" => "join"}) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      assert raised(a, room, "m.room.member", a.uid, %{"membership" => "join"}).errcode == "M_FORBIDDEN"
    end

    test "a non-member: 403 \"You are not a member of this room\", nothing written; explicit errcode", %{a: a, b: b} do
      room = public_room(a)
      conn = unchanged_state(room, fn -> put_state(b, room, "m.room.topic", topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      assert raised(b, room, "m.room.topic", "", topic_body("x")).errcode == "M_FORBIDDEN"
    end

    test "below the level of the type: 403 \"You do not have a high enough power level to set this state\", nothing written; explicit errcode", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = unchanged_state(room, fn -> put_state(b, room, "m.room.topic", topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
      assert raised(b, room, "m.room.topic", "", topic_body("x")).errcode == "M_FORBIDDEN"
    end

    test "a state key that is another user's id: 403 with the fixed text, nothing written; explicit errcode", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = unchanged_state(room, fn -> put_state_key(a, room, "m.room.topic", b.uid, topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @at_text, [b.uid])
      assert raised(a, room, "m.room.topic", b.uid, topic_body("x")).errcode == "M_FORBIDDEN"
    end

    test "content rule: an alias of ANOTHER room is 400 M_BAD_ALIAS, nothing written", %{a: a} do
      room = public_room(a)
      lp = "elsewhere-" <> T.rand(5)
      _other = make_room(a, %{"room_alias_name" => lp})
      before = event_count(room)
      assert_err(put_state(a, room, "m.room.canonical_alias", %{"alias" => alias_for(lp)}), 400, "M_BAD_ALIAS")
      assert event_count(room) == before
    end

    test "content rule: a bad alias syntax is 400 M_INVALID_PARAM, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      assert_err(put_state(a, room, "m.room.canonical_alias", %{"alias" => "not-an-alias"}), 400, "M_INVALID_PARAM")
      assert event_count(room) == before
    end

    test "content rule: a name that is not a string is 400 M_BAD_JSON, nothing written, rooms.name unchanged", %{a: a} do
      room = make_room(a, %{"name" => "Original"})
      before = event_count(room)
      assert_err(put_state(a, room, "m.room.name", %{"name" => 42}), 400, "M_BAD_JSON")
      assert event_count(room) == before
      assert rooms_name(room) == "Original"
    end

    test "content rule: a topic that is not a string is 400 M_BAD_JSON, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      assert_err(put_state(a, room, "m.room.topic", %{"topic" => 42}), 400, "M_BAD_JSON")
      assert event_count(room) == before
    end

    test "content rule: an m.space.parent whose parent space does not exist is 404, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      ghost = "!ghost" <> T.rand(8) <> ":" <> T.server_name()
      conn = put_state_key(a, room, "m.space.parent", ghost, %{"via" => [T.server_name()]})
      assert_err(conn, 404, "M_NOT_FOUND")
      assert event_count(room) == before
    end

    test "content rule: an m.space.parent whose parent the sender is not a member of is 403, nothing written", %{a: a, b: b} do
      room = public_room(a)
      parent = public_room(b)
      before = event_count(room)
      conn = put_state_key(a, room, "m.space.parent", parent, %{"via" => [T.server_name()]})
      assert_err(conn, 403, "M_FORBIDDEN")
      assert event_count(room) == before
    end

    test "the order: a non-member with a bad alias / name / topic is 403, never 400 (a refused sender learns nothing about the alias store)", %{a: a, b: b} do
      room = public_room(a)
      lp = "elsewhere-" <> T.rand(5)
      _other = make_room(a, %{"room_alias_name" => lp})

      for {type, content} <- [{"m.room.canonical_alias", %{"alias" => alias_for(lp)}}, {"m.room.name", %{"name" => 42}}, {"m.room.topic", %{"topic" => 42}}] do
        assert_refused(put_state(b, room, type, content), 403, "M_FORBIDDEN", @not_member)
      end
    end

    test "the order: a member below the level with a bad name is 403, never 400", %{a: a, b: b} do
      room = room_of(a, [b])
      assert_refused(put_state(b, room, "m.room.topic", %{"topic" => 42}), 403, "M_FORBIDDEN", @state_text)
    end

    test "the order of the four snapshot refusals: a forbidden type by a member BELOW the level is the type refusal (allowlist first), not the level text", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = unchanged_state(room, fn -> put_state_key(b, room, "m.room.member", b.uid, %{"membership" => "join"}) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      refute conn.resp_body =~ "set this state"
    end

    test "the order: a non-member with another user's @ key is refused as a non-member (membership before the @ rule)", %{a: a, b: b} do
      room = public_room(a)
      conn = unchanged_state(room, fn -> put_state_key(b, room, "m.room.topic", a.uid, topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member, [a.uid])
    end

    test "the order: a member below the level with another user's @ key gets the LEVEL text (level before the @ rule)", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = unchanged_state(room, fn -> put_state_key(b, room, "m.room.topic", a.uid, topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @state_text, [a.uid])
    end

    test "a positive control: a member at the level writes a name through the same path (200)", %{a: a} do
      room = public_room(a)
      assert row(ok_event_id!(put_state(a, room, "m.room.name", %{"name" => "Ok"}), "PUT")).sender == a.uid
    end
  end

  describe "AC7 (g) / D8 (fv) - a change committed after the dispatcher's snapshot refuses the write (gap)" do
    # the victim PUT blocks right AFTER the dispatcher's membership / level snapshot of `fetch_room_state/1` (the registry seam of the power-level story); the change
    # commits inside the gap; then the victim is released and the ROOM PROCESS decides on the new state
    defp put_in_gap(room, user, change) do
      install_env!(:event_dispatcher, :room_registry_module, PlHooks.RegistryGap)
      PlHooks.arm_gap(room, user.uid, self())

      task =
        Task.async(fn ->
          Process.put(:atdd_pl_gap_victim, true)
          put_state(user, room, "m.room.topic", topic_body("decided in the gap"))
        end)

      victim = await_gap!(:snapshot)
      change.()
      send(victim, :go)
      Task.await(task, 30_000)
    end

    test "a KICK inside the gap: 403 \"You are not a member of this room\", nothing written (positive control: the sender writes without it)", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      ok_event_id!(put_state(b, room, "m.room.topic", topic_body("positive control")), "positive control")
      topics = Enum.map(slot_events(room, "m.room.topic"), & &1.event_id)

      conn = put_in_gap(room, b, fn -> ok!(kick(a, room, b), "the kick commits inside the gap") end)

      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      assert Enum.map(slot_events(room, "m.room.topic"), & &1.event_id) == topics, "nothing was written"
      refute in_set?(room, b.uid)
    end

    test "a DEMOTION inside the gap: 403 \"...to set this state\", nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      ok_event_id!(put_state(b, room, "m.room.topic", topic_body("positive control")), "positive control")
      topics = Enum.map(slot_events(room, "m.room.topic"), & &1.event_id)

      conn = put_in_gap(room, b, fn -> seed!(room, a, levels(%{a.uid => 100, b.uid => 0})) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
      assert Enum.map(slot_events(room, "m.room.topic"), & &1.event_id) == topics
    end

    test "a RAISE of events[m.room.topic] inside the gap: 403 \"...to set this state\", nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      ok_event_id!(put_state(b, room, "m.room.topic", topic_body("positive control")), "positive control")
      topics = Enum.map(slot_events(room, "m.room.topic"), & &1.event_id)

      raised = levels(%{a.uid => 100, b.uid => 50}, %{"events" => %{@pl => 50, "m.room.topic" => 100}})
      conn = put_in_gap(room, b, fn -> seed!(room, a, raised) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
      assert Enum.map(slot_events(room, "m.room.topic"), & &1.event_id) == topics
    end
  end

  describe "AC7 (h) - the Admin Space form writes through the same writer and keeps its one audit row" do
    test "set_space_state/5 follows the slot stamp (a future-dated topic) and writes exactly one space_topic_changed row", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.topic", "", topic_body("future"), future))

      assert {:ok, id} = Nebu.Matrix.set_space_state(room, a.uid, "m.room.topic", "", topic_body("from the form"))

      assert Enum.find(slot_events(room, "m.room.topic"), &(&1.event_id == id)).ts > future, "stamped by the room-process writer"
      rows = T.sql!("SELECT actor_user_id, action FROM audit_log WHERE target_id = $1 AND action LIKE 'space_%'", [room]).rows
      assert rows == [[a.uid, "space_topic_changed"]], "the audit row stays, exactly one"
    end

    test "a refusal of the writer (a member below the level) writes no event and no audit row", %{a: a, b: b} do
      room = room_of(a, [b])
      before = event_count(room)

      assert {:error, _text} = Nebu.Matrix.set_space_state(room, b.uid, "m.room.topic", "", topic_body("x"))

      assert event_count(room) == before
      assert T.sql!("SELECT count(*) FROM audit_log WHERE target_id = $1 AND action LIKE 'space_%'", [room]).rows == [[0]]
    end
  end

  # ═══ AC8: fz and the @ rule on initial_state ═══════════════════════════════════════════

  describe "AC8 (a) / (b) - PUT state into an unknown or a stopped room (follow-up fz)" do
    test "an unknown room id: 403 M_FORBIDDEN \"You are not a member of this room\", NO rooms row, NO room process (Horde lookup)", %{a: a} do
      ghost = "!ghost" <> T.rand(8) <> ":" <> T.server_name()

      conn = put_state(a, ghost, "m.room.topic", topic_body("x"))

      assert_refused(conn, 403, "M_FORBIDDEN", @not_member, [ghost])
      assert rooms_row_count(ghost) == 0, "no lazily created rooms row"
      refute running?(ghost), "no room process was started"
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [ghost]).rows == [[0]]
    end

    test "a known room whose process is stopped: the PUT starts it from the database and succeeds", %{a: a} do
      room = public_room(a)
      stop_room!(room)
      refute running?(room)

      id = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("after the stop")), "PUT")

      assert running?(room), "the room process was started"
      assert row(id).type == "m.room.topic" and rooms_row_count(room) == 1
    end
  end

  describe "AC8 (c) / AC17 (n) - the @ rule on every initial_state entry (D10 (b))" do
    test "an m.room.name entry with another user's state key: 400 M_INVALID_ROOM_STATE with the fixed text, no room", %{a: a} do
      other = "@other:" <> T.server_name()
      rooms_before = room_count()

      conn = create(a, %{"initial_state" => [%{"type" => "m.room.name", "state_key" => other, "content" => %{"name" => "x"}}]})

      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", "The initial state contains a state key of another user", [other])
      assert room_count() == rooms_before, "no room was created"
    end

    test "the same entry with the creator's OWN id as state key: 200, the event is written under that key", %{a: a} do
      room = make_room(a, %{"initial_state" => [%{"type" => "m.room.name", "state_key" => a.uid, "content" => %{"name" => "own key"}}]})
      assert [%{content: %{"name" => "own key"}}] = slot_events(room, "m.room.name", a.uid)
    end

    test "an m.room.member entry for ANOTHER user: 400 M_INVALID_ROOM_STATE (a stricter Nebu rule; it was skipped), no room", %{a: a, b: b} do
      rooms_before = room_count()

      conn = create(a, %{"initial_state" => [%{"type" => "m.room.member", "state_key" => b.uid, "content" => %{"membership" => "join"}}]})

      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", "The initial state contains a state key of another user", [b.uid])
      assert room_count() == rooms_before
    end

    test "an m.room.member entry with the creator's own key stays skipped: 200 and no extra member event", %{a: a} do
      room = make_room(a, %{"initial_state" => [%{"type" => "m.room.member", "state_key" => a.uid, "content" => %{"membership" => "leave"}}]})
      assert memberships(room, a.uid) == ["join"], "only the creator's join: the entry was skipped as today"
    end
  end

  describe "AC17 (m) - the creator lock-out of createRoom (today's behaviour: a pin)" do
    test "power_level_content_override.users[creator] 0 plus a name: 400 M_INVALID_ROOM_STATE, no room", %{a: a} do
      rooms_before = room_count()
      conn = create(a, %{"name" => "Locked out", "power_level_content_override" => %{"users" => %{a.uid => 0}}})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", "The power levels do not allow the room creator to set the initial room state")
      assert room_count() == rooms_before
    end

    test "the same override plus an initial_state m.room.topic: 400 M_INVALID_ROOM_STATE, no room", %{a: a} do
      rooms_before = room_count()
      entry = %{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "t"}}
      conn = create(a, %{"initial_state" => [entry], "power_level_content_override" => %{"users" => %{a.uid => 0}}})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", "The power levels do not allow the room creator to set the initial room state")
      assert room_count() == rooms_before
    end
  end

  # ═══ AC17 (i), (k), (l): PUT state paths ═══════════════════════════════════════════════

  describe "AC17 (i) - an archived room, side by side" do
    test "/redact answers 400 M_BAD_STATE, PUT state answers 404 M_NOT_FOUND (both errcodes asserted), nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "frozen")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      before = {state_footprint(room), redaction_ids(room)}

      assert_err(redact(b, room, m), 400, "M_BAD_STATE", "M_ROOM_ARCHIVED: room is archived")
      assert_err(put_state(a, room, "m.room.topic", topic_body("x")), 404, "M_NOT_FOUND", "Room not found")

      assert {state_footprint(room), redaction_ids(room)} == before
    end
  end

  describe "AC17 (k) - PUT /rooms/{r}/state/{type} (the route without a state key) goes through the writer too" do
    test "a non-member is 403, nothing written", %{a: a, b: b} do
      room = public_room(a)
      conn = unchanged_state(room, fn -> put_state(b, room, "m.room.topic", topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "a member below the level is 403, nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = unchanged_state(room, fn -> put_state(b, room, "m.room.topic", topic_body("x")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
    end

    test "an archived room is 404 M_NOT_FOUND, nothing written", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      conn = unchanged_state(room, fn -> put_state(a, room, "m.room.topic", topic_body("x")) end)
      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found")
    end

    test "the slot stamp follows a future-dated event of the slot", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.topic", "", topic_body("future"), future))

      id = ok_event_id!(put_state(a, room, "m.room.topic", topic_body("now")), "PUT")

      assert Enum.find(slot_events(room, "m.room.topic"), &(&1.event_id == id)).ts > future
    end
  end

  describe "AC17 (l) - the @ rule, the positive case" do
    test "a state key equal to the sender's own @id on an allowlisted type: 200 (the event is written under that key)", %{a: a} do
      room = public_room(a)
      id = ok_event_id!(put_state_key(a, room, "m.room.topic", a.uid, topic_body("own key")), "PUT")
      assert [%{event_id: ^id}] = slot_events(room, "m.room.topic", a.uid)
    end
  end

  # ═══ AC10: the upgrade (fx) ════════════════════════════════════════════════════════════

  describe "AC10 (a) - the upgrade needs the tombstone level" do
    test "events[m.room.tombstone] 150, the requester at 100: 403 M_FORBIDDEN with the new text; no tombstone, no new room, the old room not archived", %{a: a} do
      room = public_room(a)
      seed!(room, a, levels(%{a.uid => 100}, %{"events" => %{@pl => 50, "m.room.tombstone" => 150}}))
      rooms_before = {room_count(), running_rooms(), event_count(room)}

      conn = upgrade(a, room)

      assert_refused(conn, 403, "M_FORBIDDEN", @upgrade_text)
      assert {room_count(), running_rooms(), event_count(room)} == rooms_before, "no new room, no event in the old room"
      assert slot_events(room, "m.room.tombstone") == []
      assert room_status(room) == "active", "the old room was not archived"
    end

    test "(b) the requester at 150 with every level at most 150: 200, the tombstone is in the old room", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 150, b.uid => 100}, %{"events" => %{@pl => 50, "m.room.tombstone" => 150}}))

      conn = upgrade(a, room)

      assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
      new_room = T.json(conn)["replacement_room"]
      assert [%{content: %{"replacement_room" => ^new_room}, sender: sender}] = slot_events(room, "m.room.tombstone")
      assert sender == a.uid
    end

    test "(c) events[m.room.tombstone] 50, the requester at 60: 403 (the floor of 100, a labelled Nebu restriction); at 100 the same configuration is 200", %{a: a} do
      room = public_room(a)
      seed!(room, a, levels(%{a.uid => 60}, %{"events" => %{@pl => 50, "m.room.tombstone" => 50}}))
      before = {room_count(), event_count(room)}

      assert_refused(upgrade(a, room), 403, "M_FORBIDDEN", @upgrade_text)
      assert {room_count(), event_count(room)} == before
      assert slot_events(room, "m.room.tombstone") == []

      allowed = public_room(a)
      seed!(allowed, a, levels(%{a.uid => 100}, %{"events" => %{@pl => 50, "m.room.tombstone" => 50}}))
      assert upgrade(a, allowed).status == 200, "positive control: at 100 the tombstone level 50 is enough"
    end
  end

  describe "AC10 (d) - a demotion committed between the pre-check and the tombstone" do
    test "403 M_FORBIDDEN, no tombstone, no freeze, no new room left behind (its row and its process are gone)", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 100, b.uid => 100}))
      install_env!(:event_dispatcher, :room_registry_module, PlHooks.RegistryGap)
      PlHooks.arm_gap(room, a.uid, self())
      before = {room_count(), running_rooms(), event_count(room)}

      task =
        Task.async(fn ->
          Process.put(:atdd_pl_gap_victim, true)
          upgrade(a, room)
        end)

      victim = await_gap!(:snapshot)
      seed!(room, b, levels(%{a.uid => 50, b.uid => 100}))
      send(victim, :go)
      conn = Task.await(task, 30_000)

      assert_refused(conn, 403, "M_FORBIDDEN", @upgrade_text)
      assert slot_events(room, "m.room.tombstone") == [], "nothing was tombstoned"
      assert room_status(room) == "active", "the old room was not frozen"
      assert running?(room)
      assert {room_count(), running_rooms()} == {elem(before, 0), elem(before, 1)}, "the new room's row and process were cleaned up"
      assert event_count(room) == elem(before, 2) + 1, "only the demotion's levels event was written to the old room"
    end
  end

  describe "AC10 (g) / Kassandra #3 - a room that does not answer the tombstone write" do
    test "503 M_UNAVAILABLE \"may or may not have been applied\": the new room is KEPT (the tombstone may still commit), the old room is not frozen", %{a: a} do
      room = public_room(a)
      install_env!(:event_dispatcher, :room_registry_module, RdHooks.ExitingWriter)
      rooms_before = room_count()
      running_before = running_rooms()

      conn = upgrade(a, room)

      assert_refused(conn, 503, "M_UNAVAILABLE", "The room did not answer, the change may or may not have been applied")
      assert room_count() == rooms_before + 1, "the new room's row was NOT deleted"
      assert [_orphan] = running_rooms() -- running_before, "the new room's process was NOT stopped"
      assert room_status(room) == "active", "the old room was not frozen"
    end
  end

  describe "AC10 (e) - the tombstone is stamped after the latest tombstone event and written in one transaction" do
    test "a future-dated earlier tombstone event: the upgrade's tombstone is stamped after it", %{a: a} do
      room = public_room(a)
      cleanup_events_on_exit(room)
      future = System.system_time(:millisecond) + 250
      assert :ok = DB.insert_event(state_event(room, a, "m.room.tombstone", "", %{"replacement_room" => "!old:#{T.server_name()}"}, future))

      conn = upgrade(a, room)

      assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
      [_older, newest] = slot_events(room, "m.room.tombstone")
      assert newest.ts > future
      assert newest.content["replacement_room"] == T.json(conn)["replacement_room"]
    end

    test "an ARCHIVED old room (the process still running) is refused with 404 M_NOT_FOUND: no tombstone, no new room left behind", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert running?(room)
      before = {room_count(), running_rooms(), event_count(room)}

      conn = upgrade(a, room)

      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found")
      assert {room_count(), running_rooms(), event_count(room)} == before
      assert slot_events(room, "m.room.tombstone") == []
    end
  end

  describe "AC17 (o) - the floor of 100 without an events entry for the tombstone" do
    test "no events[m.room.tombstone], state_default 50: a requester at 50 is 403 (the floor), at 100 is 200", %{a: a, b: b} do
      room = room_of(a, [b])
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      refute Map.has_key?(column(room)["events"], "m.room.tombstone")
      assert column(room)["state_default"] == 50
      before = {room_count(), event_count(room)}

      assert_refused(upgrade(b, room), 403, "M_FORBIDDEN", @upgrade_text)
      assert {room_count(), event_count(room)} == before

      assert upgrade(a, room).status == 200, "positive control: at 100 the same room upgrades"
    end

    test "a non-member requester listed at 100: 403 M_FORBIDDEN \"You are not a member of this room\", nothing written", %{a: a, c: c} do
      room = public_room(a)
      seed!(room, a, levels(%{a.uid => 100, c.uid => 100}))
      before = {room_count(), running_rooms(), event_count(room)}

      conn = upgrade(c, room)

      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      assert {room_count(), running_rooms(), event_count(room)} == before
      assert slot_events(room, "m.room.tombstone") == []
    end
  end
end
