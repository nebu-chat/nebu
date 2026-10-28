defmodule Nebu.Matrix.RedactionHttpTest do
  @moduledoc """
  Story `state-writer-redaction` (epic oauth-broker, follow-ups `fw`, `fv`, `fz`, `fx`), the redaction half over HTTP: AC1, AC2, AC3, AC4 (a) - (d), AC5, AC11
  and the Oracle tests AC17 (a) - (h), (i) (the `/redact` half), (j), (p) - (r). Real stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, real
  `Room.Server` / Horde / `:pg`, users and legacy sessions as in the moderation suites (random localparts, `:server_name` pinned). Everything the real SQL
  decides (the stored rows, the `redacts` column, the prune-on-read lookup, the relation / search exclusions) is asserted against the real database; the
  writer's atomicity and crash claims are in `room/redaction_writer_db_test.exs`, the races in `state_writer_redaction_concurrency_test.exs`.

  Shared helpers: `Nebu.Matrix.RedactionTestSupport` (built on `ModerationTestSupport` and `PowerLevelsTestSupport`).

  ## Decisions of the ATDD step (ambiguities of the story, listed in the report)

    * The levels of a room are seeded with `Room.Server.set_power_levels/3` by the room creator (`levels/2` builds a COMPLETE valid content), so a test never
      depends on the default `events` map of the code under test. Default rooms (public_chat): the owner at 100, everybody else at 0, `redact` 50,
      `events_default` 0, no `events["m.room.redaction"]` entry.
    * The stored redaction is the v10 PDU Nebu signs for a message event: the keys `room_id`, `type`, `state_key` (JSON null), `sender`, `content`, `redacts`
      (top level) and `origin_server_ts`; `valid_redaction_signature?/1` rebuilds exactly that map (the story says "a valid signature" without naming the keys).
    * "a refusal writes nothing": no event, no redaction row, no audit row (`rd_footprint/1`) and no `NebuTxnDedup` entry of the request (`dedup_entry/1`).
    * The `/send` router checks are untouched (the story: "no new ones"); AC4 (b) checks `content.redacts` BEFORE the room lookup (an unknown room with a bad
      `redacts` is not tested: the story does not order the two).
    * The order inside the core for an unknown ROOM id is not tested against the body checks of D13 beyond what AC3 lists (the body is validated first).
    * AC5 (g): the failing batched lookup is requested in an isolated process (`isolated/1`): a request that crashes its process (a task of the initial `/sync`
      that raises) would otherwise kill the test; the AC asks for `500`, so a crash is a failure of the test, not of the harness.
    * AC17 (p): Nebu ignores `filter` on `/messages` and `/sync` (follow-up `fg` (a)): the tests pin the PRUNED result under a `types` / `not_types` filter
      and record that filters are ignored; `contains_url` is not supported and therefore not applicable.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport
  import Nebu.Matrix.RedactionTestSupport

  alias Nebu.Matrix.PowerLevelsTestSupport.FailingAudit
  alias Nebu.Matrix.RedactionTestSupport.Hooks
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @pl "m.room.power_levels"
  @redaction "m.room.redaction"

  @not_member "You are not a member of this room"
  @send_text "You do not have a high enough power level to send this event"
  @redact_text "You do not have a high enough power level to redact other users' events"
  @state_text "This event cannot be redacted on this server"
  @archived_text "M_ROOM_ARCHIVED: room is archived"

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

    {:ok, a: user!("RDA"), b: user!("RDB"), c: user!("RDC"), d: user!("RDD")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # a public room owned by `a` (100) whose `members` joined; every other user at 0
  defp room_of(a, members) do
    room = public_room(a)
    for m <- members, do: join_now!(m, room)
    room
  end

  # the levels content with `users` and top-level `extra` (the owner stays at 100)
  defp seeded(a, members, users, extra \\ %{}), do: room_with_levels(a, members, levels(Map.put_new(users, a.uid, 100), extra))

  # puts `c` into the membership state of the scenario
  defp become!(:never_joined, _a, _room, _c), do: :ok

  defp become!(:left, _a, room, c) do
    join_now!(c, room)
    leave!(c, room)
  end

  defp become!(:kicked, a, room, c) do
    join_now!(c, room)
    ok!(kick(a, room, c), "kick")
  end

  defp become!(:banned, a, room, c), do: ok!(ban(a, room, c), "ban")
  defp become!(:invited, a, room, c), do: invite!(a, room, c)

  # the event id of a state event / redaction to be used as a (refused) target
  defp target_of(:topic, a, _b, room, _m), do: ok_event_id!(put_state(a, room, "m.room.topic", %{"topic" => "t"}), "topic")
  defp target_of(:member, _a, b, room, _m), do: b.uid |> then(&member_events(room, &1)) |> List.last() |> Map.fetch!(:event_id)
  defp target_of(:power_levels, _a, _b, room, _m), do: latest_pl(room).event_id
  defp target_of(:redaction, _a, b, room, m), do: redact_id!(b, room, m, %{}, "first redaction")

  # the redaction event exactly as a client receives it as `unsigned.redacted_because`
  defp served_redaction(id, room, sender, ts, target, content) do
    %{
      "event_id" => id,
      "type" => @redaction,
      "room_id" => room,
      "sender" => uid_of(sender),
      "origin_server_ts" => ts,
      "content" => Map.put(content, "redacts", target),
      "redacts" => target
    }
  end

  # runs `fun` in an UNLINKED process: `{:ok, result}` or `{:crashed, reason}` (a task of the initial /sync that raises kills its request process)
  defp isolated(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:isolated, self(), fun.()}) end)

    receive do
      {:isolated, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:crashed, reason}
    after
      60_000 -> flunk("the isolated request did not answer")
    end
  end

  # ═══ AC1: the redaction route ═══════════════════════════════════════════════════════

  describe "AC1 (a) - PUT /redact of an own message" do
    test "with a reason: 200 {event_id}; the stored row has redacts = the target, content exactly the reason (no redacts), a valid signature", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "hello")
      t0 = System.system_time(:millisecond)

      id = redact_id!(b, room, m, %{"reason" => "typo"})

      t1 = System.system_time(:millisecond)
      r = row(id)
      assert r.type == @redaction and r.sender == b.uid and r.room_id == room
      assert r.redacts == m, "the column holds the target"
      assert r.content == %{"reason" => "typo"}, "the stored content is the body without redacts"
      assert r.state_key == nil, "a redaction is a message event"
      assert r.ts >= t0 and r.ts <= t1
      assert Map.keys(r.signatures) == ["nebu"]
      assert valid_redaction_signature?(id), "the stored event is signed by the server key (v10 PDU shape)"
    end

    test "with a {} body and with an empty reason: 200, the stored content is exactly {} (no reason key)", %{a: a, b: b} do
      room = room_of(a, [b])

      for body <- [%{}, %{"reason" => ""}] do
        id = redact_id!(b, room, say!(b, room, "x"), body, "empty body")
        assert row(id).content == %{}, "body #{inspect(body)}"
      end
    end
  end

  describe "AC1 (b) - the redaction event in every member's next /sync timeline" do
    test "carries the top-level redacts AND content.redacts = the target and the reason", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      m = say!(b, room, "to be removed")
      tokens = for u <- [a, b, c], do: {u, next(sync(u))}
      tick()

      id = redact_id!(b, room, m, %{"reason" => "typo"})

      for {u, since} <- tokens do
        ev = u |> sync(since) |> join_timeline(room) |> Enum.find(&(&1["event_id"] == id))
        assert ev != nil, "#{u.uid} receives the redaction"
        assert ev["type"] == @redaction and ev["sender"] == b.uid and ev["room_id"] == room
        assert ev["redacts"] == m, "top-level redacts (Element reads only this)"
        assert ev["content"] == %{"redacts" => m, "reason" => "typo"}, "content.redacts for v11 clients, and the reason"
        refute Map.has_key?(ev, "state_key"), "a redaction is no state event"
        assert is_integer(ev["unsigned"]["age"])
      end
    end
  end

  describe "AC1 (c) - the target afterwards, on every read path" do
    for how <- [:messages_b, :messages_f, :event, :sync_initial, :initial_sync] do
      test "#{how}: content {} and unsigned.redacted_because (the full redaction event); every other served key unchanged; the stored row byte-identical", %{a: a, b: b, c: c} do
        room = room_of(a, [b, c])
        word = word("mk")
        m = say!(b, room, "secret " <> word)
        {before, _raw} = served(c, room, m, unquote(how))
        assert get_in(before, ["content", "body"]) == "secret " <> word, "positive control: the target is served unredacted before"
        stored_before = raw_row(m)

        id = redact_id!(b, room, m, %{"reason" => "typo"})
        {after_ev, raw} = served(c, room, m, unquote(how))

        assert after_ev["content"] == %{}
        r = row(id)

        assert after_ev["unsigned"]["redacted_because"] == served_redaction(id, room, b, r.ts, m, %{"reason" => "typo"}),
               "the full served redaction: event_id, type, sender, room_id, origin_server_ts, content incl. redacts, top-level redacts; no unsigned"

        assert Map.drop(after_ev["unsigned"], ["redacted_because", "age"]) == %{}, "no other unsigned key appears"
        assert Map.drop(after_ev, ["content", "unsigned"]) == Map.drop(before, ["content", "unsigned"]), "every other served key is unchanged"
        refute raw =~ word, "the original content is in no byte of the response"
        assert raw_row(m) == stored_before, "the stored target row (content, signatures) is byte-identical"
        assert row(m).content["body"] == "secret " <> word
      end
    end
  end

  describe "AC1 (d) - idempotency (D7)" do
    test "the same txn id again: 200 with the SAME event id, one row only, one ETS entry", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "once")

      id = ok_event_id!(redact(b, room, m, %{}, "txn-one"), "first")
      again = ok_event_id!(redact(b, room, m, %{}, "txn-one"), "again")

      assert again == id
      assert redaction_ids(room) == [id]
      assert dedup_entry(redact_key(room, b, m, "txn-one")) == [{redact_key(room, b, m, "txn-one"), id}]
    end

    test "the same txn id for ANOTHER target is a new redaction (the txn id is scoped to its path)", %{a: a, b: b} do
      room = room_of(a, [b])
      m1 = say!(b, room, "one")
      m2 = say!(b, room, "two")

      id1 = ok_event_id!(redact(b, room, m1, %{}, "shared"), "first")
      id2 = ok_event_id!(redact(b, room, m2, %{}, "shared"), "second target")

      assert id1 != id2
      assert [row(id1).redacts, row(id2).redacts] == [m1, m2]
      assert length(redaction_ids(room)) == 2
    end

    test "a /send txn with the same id string is unaffected, both ways", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "scoped")
      send_path = path(room, "send/m.room.message/shared")
      send_id = ok_event_id!(T.matrix_request(:put, send_path, b.at, body: %{"msgtype" => "m.text", "body" => "hi"}), "send")

      rid = ok_event_id!(redact(b, room, m, %{}, "shared"), "redact with the /send txn id")

      assert rid != send_id, "the /redact txn id string does not collide with the /send txn of the same string"
      assert ok_event_id!(T.matrix_request(:put, send_path, b.at, body: %{"msgtype" => "m.text", "body" => "hi"}), "send again") == send_id
      assert ok_event_id!(redact(b, room, m, %{}, "shared"), "redact again") == rid
      assert redaction_ids(room) == [rid]
    end
  end

  describe "D7 - redactions are not rate-limited (spec: Rate-limited: No)" do
    test "65 redactions in a row with the limiter ENABLED are all 200 and no tier bucket of the user was charged", %{a: a, b: b} do
      refute Application.get_env(:nebu_http, :rate_limit_disabled), "this test requires the limiter ENABLED (T.reset_rate_limits/0 re-enabled it)"
      room = room_of(a, [b])
      ids = for n <- 1..65, do: say!(b, room, "m#{n}")

      tiers = [
        {"moderation", Nebu.Web.RateLimitTiers.moderation()},
        {"invite", Nebu.Web.RateLimitTiers.invite()},
        {"join", Nebu.Web.RateLimitTiers.join()},
        {"create_room", Nebu.Web.RateLimitTiers.create_room()}
      ]

      buckets_before = for {tier, {_rate, burst}} <- tiers, do: tokens(tier, b, burst)

      statuses = for m <- ids, do: redact(b, room, m).status

      assert Enum.uniq(statuses) == [200], "no 429 from any tier: #{inspect(Enum.frequencies(statuses))}"
      assert length(redaction_ids(room)) == 65
      assert for({tier, {_rate, burst}} <- tiers, do: tokens(tier, b, burst)) == buckets_before, "no tier bucket of the redacting user was charged"
    end
  end

  # ═══ AC2: the decision ═════════════════════════════════════════════════════════════

  describe "AC2 - the decision, one test per rule (levels seeded with set_power_levels/3)" do
    test "(a) an own event at events_default (0, no events entry for the redaction): 200", %{a: a, b: b} do
      room = seeded(a, [b], %{})
      refute Map.has_key?(column(room)["events"], @redaction)
      m = say!(b, room, "mine")

      id = redact_id!(b, room, m)

      assert row(id).redacts == m
    end

    test "(b) another user's event by a member at 0 (redact 50): 403 with the fixed text, the target unchanged, nothing written", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{})
      m = say!(b, room, "not yours")
      txn = "refused-txn"

      conn = rd_unchanged(room, fn -> redact(c, room, m, %{"reason" => "mine now"}, txn) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @redact_text, [m, "mine now"])
      assert event!(a, room, m)["content"]["body"] == "not yours", "the target is unchanged"
      assert dedup_entry(redact_key(room, c, m, txn)) == [], "a refusal is not remembered"
    end

    test "(c) another user's event by a member at 50: 200", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{c.uid => 50})
      m = say!(b, room, "moderated")

      id = redact_id!(c, room, m)

      assert row(id).redacts == m and row(id).sender == c.uid
      assert event!(a, room, m)["content"] == %{}
    end

    test "(d) events[m.room.redaction] 50: a member at 0 cannot redact even his OWN event (403, the send text)", %{a: a, b: b} do
      room = seeded(a, [b], %{}, %{"events" => %{@pl => 50, @redaction => 50}})
      m = say!(b, room, "own but forbidden")

      conn = rd_unchanged(room, fn -> redact(b, room, m) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @send_text, [m])
      assert event!(a, room, m)["content"]["body"] == "own but forbidden"
    end

    test "(e) redact 0 with events[m.room.redaction] 0: anyone may redact anyone's message (200)", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{}, %{"redact" => 0, "events" => %{@pl => 50, @redaction => 0}})
      m = say!(b, room, "open season")

      id = redact_id!(c, room, m)

      assert row(id).sender == c.uid and row(id).redacts == m
    end

    for state <- [:never_joined, :left, :kicked, :banned, :invited] do
      test "(f) a #{state} user: 403 #{@not_member}, nothing written", %{a: a, b: b, c: c} do
        room = room_of(a, [b])
        m = say!(b, room, "target")

        become!(unquote(state), a, room, c)

        conn = rd_unchanged(room, fn -> redact(c, room, m) end)

        assert_refused(conn, 403, "M_FORBIDDEN", @not_member, [m])
        assert event!(a, room, m)["content"]["body"] == "target"
      end
    end

    test "(g) an unknown event id: 404 M_NOT_FOUND \"Event not found\", nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      ghost = "$ghost" <> T.rand(8)

      conn = rd_unchanged(room, fn -> redact(b, room, ghost) end)

      assert_refused(conn, 404, "M_NOT_FOUND", "Event not found", [ghost])
    end

    test "(g) an event of ANOTHER room: 404, the other room's event stays unchanged", %{a: a, b: b} do
      room = room_of(a, [b])
      other = room_of(a, [b])
      foreign = say!(b, other, "in the other room")

      conn = rd_unchanged(room, fn -> redact(b, room, foreign) end)

      assert_refused(conn, 404, "M_NOT_FOUND", "Event not found", [foreign])
      assert event!(a, other, foreign)["content"]["body"] == "in the other room"
      assert redaction_ids(other) == []
    end

    for kind <- [:topic, :member, :power_levels, :redaction] do
      test "(h) a #{kind} event as the target: 403 \"#{@state_text}\", nothing written", %{a: a, b: b} do
        room = room_of(a, [b])
        m = say!(b, room, "x")

        target = target_of(unquote(kind), a, b, room, m)

        conn = rd_unchanged(room, fn -> redact(a, room, target) end)

        assert_refused(conn, 403, "M_FORBIDDEN", @state_text, [target])
      end
    end

    test "(i) an archived room (status set, the process running): 400 M_BAD_STATE, nothing written", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "frozen")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert running?(room), "the process still runs"

      conn = rd_unchanged(room, fn -> redact(b, room, m) end)

      assert_refused(conn, 400, "M_BAD_STATE", @archived_text, [m])
    end

    test "(j) first failure wins: a non-member with an unknown target is 403, not 404", %{a: a, b: b, c: c} do
      room = room_of(a, [b])
      conn = rd_unchanged(room, fn -> redact(c, room, "$ghost" <> T.rand(8)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "(j) a member below the redaction level with an unknown target is 403 (the send text), not 404", %{a: a, b: b} do
      room = seeded(a, [b], %{}, %{"events" => %{@pl => 50, @redaction => 50}})
      conn = rd_unchanged(room, fn -> redact(b, room, "$ghost" <> T.rand(8)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @send_text)
    end

    test "(j) a member at the level with an unknown target is 404", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = rd_unchanged(room, fn -> redact(b, room, "$ghost" <> T.rand(8)) end)
      assert_refused(conn, 404, "M_NOT_FOUND", "Event not found")
    end

    test "(k) an already redacted event redacted again by another user: 200 with the id of the EXISTING redaction, NO new row, NO audit row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "twice")
      first = redact_id!(b, room, m, %{"reason" => "first"})
      before = rd_footprint(room)

      second = ok_event_id!(redact(a, room, m, %{"reason" => "second"}), "again")

      assert second == first, "idempotent: the id of the existing redaction"
      assert rd_footprint(room) == before, "no new row, no audit row"
      assert redaction_ids(room) == [first]
      because = event!(a, room, m)["unsigned"]["redacted_because"]
      assert because["event_id"] == first and because["content"]["reason"] == "first"
    end

    test "(k) the same user, a fresh txn id each time, five times: one row, always the same id (a repeated /redact is no write amplification)", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "again and again")
      first = redact_id!(b, room, m, %{"reason" => "first"})

      ids = for n <- 1..5, do: ok_event_id!(redact(b, room, m, %{"reason" => "again #{n}", "x_pad" => String.duplicate("p", 1000)}), "again #{n}")

      assert Enum.uniq(ids) == [first]
      assert redaction_ids(room) == [first]
      assert length(redaction_ids_of(m)) == 1
    end

    test "(k) the checks come FIRST: a member below redact who re-redacts ANOTHER user's already redacted event is 403, nobody learns the existing id", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{})
      m = say!(b, room, "target")
      first = redact_id!(a, room, m)

      conn = rd_unchanged(room, fn -> redact(c, room, m) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @redact_text, [first])
    end

    test "(k) a LEGACY unchecked row does not count as a redaction: the first real redaction writes its own row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "legacy target")
      legacy = insert_legacy_redaction!(room, b, m, %{"reason" => "legacy"}, ts_after(room))

      id = redact_id!(b, room, m)

      assert id != legacy
      assert row(id).redacts == m
      assert redaction_ids_of(m) == [id]
    end

    test "(k) /send of a redaction of an already redacted target answers the existing redaction's id too", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      first = redact_id!(b, room, m)

      again = ok_event_id!(send_redaction(a, room, %{"redacts" => m}), "send")

      assert again == first
      assert redaction_ids(room) == [first]
      assert redact_audit(room) == []
    end

    test "(l) an unknown room id: 404 M_NOT_FOUND as /send, NO rooms row, no room process", %{a: a} do
      ghost = "!ghost" <> T.rand(8) <> ":" <> T.server_name()

      conn = redact(a, ghost, "$any" <> T.rand(8))

      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found", [ghost])
      assert rooms_row_count(ghost) == 0, "no lazily created rooms row"
      refute running?(ghost), "no room process was started"
    end

    test "(l) a known room whose process is stopped: 404 M_NOT_FOUND as /send, the rooms row unchanged, no lazy start", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "stopped")
      stop_room!(room)
      row_before = T.sql!("SELECT * FROM rooms WHERE room_id = $1", [room]).rows

      conn = redact(b, room, m)

      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found", [room, m])
      refute running?(room), "the room process was not started by the redaction"
      assert T.sql!("SELECT * FROM rooms WHERE room_id = $1", [room]).rows == row_before
      assert redaction_ids(room) == []
    end
  end

  # ═══ AC3: request validation (D13) ═════════════════════════════════════════════════

  describe "AC3 - request validation of /redact (D13): fixed errcodes and texts, nothing written" do
    setup %{a: a, b: b} do
      room = room_of(a, [b])
      {:ok, room: room, m: say!(b, room, "the target")}
    end

    defp nested(1), do: %{}
    defp nested(levels), do: Enum.reduce(2..levels, %{}, fn _, acc -> %{"a" => acc} end)

    test "invalid JSON: 400 M_NOT_JSON", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact_raw(b, room, m, ~s({"reason":)) end)
      assert_refused(conn, 400, "M_NOT_JSON", "Request body is not valid JSON", [m])
    end

    test "a JSON array body: 400 M_BAD_JSON \"Request body must be a JSON object\"", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact_raw(b, room, m, "[1, 2]") end)
      assert_refused(conn, 400, "M_BAD_JSON", "Request body must be a JSON object", [m])
    end

    test "reason: 5 (not a string): 400 M_BAD_JSON \"reason must be a string\"", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact(b, room, m, %{"reason" => 5}) end)
      assert_refused(conn, 400, "M_BAD_JSON", "reason must be a string", [m])
    end

    test "reason: null is absent: 200, the stored content is exactly {}", %{b: b, room: room, m: m} do
      id = redact_id!(b, room, m, %{"reason" => nil})
      assert row(id).content == %{}
    end

    test "a 1025-byte reason: 400 M_INVALID_PARAM \"reason exceeds 1024 bytes\" (the reason is not echoed)", %{b: b, room: room, m: m} do
      reason = String.duplicate("r", 1025)
      conn = rd_unchanged(room, fn -> redact(b, room, m, %{"reason" => reason}) end)
      assert_refused(conn, 400, "M_INVALID_PARAM", "reason exceeds 1024 bytes", [reason, m])
    end

    test "a 1024-byte reason is accepted: 200, stored unchanged", %{b: b, room: room, m: m} do
      reason = String.duplicate("é", 512)
      assert byte_size(reason) == 1024
      id = redact_id!(b, room, m, %{"reason" => reason})
      assert row(id).content == %{"reason" => reason}
    end

    test "a NUL in the reason: 400 M_BAD_JSON, nothing written", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact(b, room, m, %{"reason" => "a\u0000b"}) end)
      assert_refused(conn, 400, "M_BAD_JSON", "State event content must not contain NUL characters", [m])
    end

    test "a body nested 33 levels: 400 M_BAD_JSON; 32 levels is accepted and stored as content", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact(b, room, m, nested(33)) end)
      assert_refused(conn, 400, "M_BAD_JSON", "State event content is nested too deeply", [m])

      id = redact_id!(b, room, m, nested(32))
      assert row(id).content == nested(32)
    end

    test "a body of 70 000 bytes: 413 M_TOO_LARGE with the fixed text", %{b: b, room: room, m: m} do
      conn = rd_unchanged(room, fn -> redact(b, room, m, %{"x" => String.duplicate("a", 70_000)}) end)
      assert_refused(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:event_too_large), [m])
    end

    test "other body keys are kept in the stored content", %{b: b, room: room, m: m} do
      body = %{"reason" => "r", "x_note" => "kept", "nested" => %{"y" => [1, 2]}}
      id = redact_id!(b, room, m, body)
      assert row(id).content == body
    end

    test "a body redacts key that differs from the path is dropped: the path wins", %{b: b, room: room, m: m} do
      id = redact_id!(b, room, m, %{"redacts" => "$other", "reason" => "r"})
      r = row(id)
      assert r.redacts == m
      assert r.content == %{"reason" => "r"}
    end

    test "a NUL in the event id of the path: 400 M_BAD_JSON, nothing written", %{b: b, room: room} do
      conn = rd_unchanged(room, fn -> redact(b, room, "$a\u0000b") end)
      assert_err(conn, 400, "M_BAD_JSON")
    end

    test "a percent-encoded event id that is not UTF-8: 400 M_BAD_JSON, nothing written", %{b: b, room: room} do
      conn = rd_unchanged(room, fn -> put_raw(b, path(room, "redact/%FF/t1"), "{}") end)
      assert_err(conn, 400, "M_BAD_JSON")
    end

    test "a sender id above 255 bytes: 403 M_FORBIDDEN with the fixed text (before the core)", %{room: room, m: m} do
      long = long_user!(300)
      conn = rd_unchanged(room, fn -> redact(long, room, m) end)
      assert_refused(conn, 403, "M_FORBIDDEN", Nebu.Matrix.EventSize.message(:sender_too_long), [m, long.uid])
    end

    test "the body is validated BEFORE the room is looked up: invalid JSON to an unknown room is 400, not 404", %{b: b, m: m} do
      ghost = "!ghost" <> T.rand(8) <> ":" <> T.server_name()
      assert_refused(redact_raw(b, ghost, m, "{"), 400, "M_NOT_JSON", "Request body is not valid JSON")
    end
  end

  # ═══ AC4: m.room.redaction on /send goes through the same writer ═════════════════════

  describe "AC4 (a) - /send of m.room.redaction is authorised by the redact level and applied" do
    test "content.redacts = another user's event by a member at 0: 403 (was 200 stored as-is), nothing written, the target intact", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{})
      m = say!(b, room, "not yours")

      conn = rd_unchanged(room, fn -> send_redaction(c, room, %{"redacts" => m, "reason" => "x"}, "t1") end)

      assert_refused(conn, 403, "M_FORBIDDEN", @redact_text, [m])
      assert event!(a, room, m)["content"]["body"] == "not yours"
      assert dedup_entry(send_key(room, c, @redaction, "t1")) == []
    end

    test "by a member at 50: 200; the stored row has the top-level redacts (column) and NO content.redacts; served as AC1 (b) / (c)", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{c.uid => 50})
      m = say!(b, room, "moderated")
      since = next(sync(b))
      tick()

      id = ok_event_id!(send_redaction(c, room, %{"redacts" => m}), "send")

      r = row(id)
      assert r.redacts == m and r.type == @redaction and r.sender == c.uid and r.state_key == nil
      assert r.content == %{}, "content.redacts was MOVED to the top level, the stored content has no redacts"
      assert valid_redaction_signature?(id)
      ev = b |> sync(since) |> join_timeline(room) |> Enum.find(&(&1["event_id"] == id))
      assert ev["redacts"] == m and ev["content"] == %{"redacts" => m}
      assert event!(b, room, m)["content"] == %{}
      assert event!(b, room, m)["unsigned"]["redacted_because"]["event_id"] == id
    end

    test "(d) the own event at events_default: 200", %{a: a, b: b} do
      room = seeded(a, [b], %{})
      m = say!(b, room, "mine")
      id = ok_event_id!(send_redaction(b, room, %{"redacts" => m}), "send")
      assert row(id).redacts == m
      assert event!(a, room, m)["content"] == %{}
    end
  end

  describe "AC4 (b) - content.redacts is required" do
    for {label, content} <- [missing: %{}, number: %{"redacts" => 5}, empty: %{"redacts" => ""}, null: %{"redacts" => nil}] do
      test "#{label}: 400 M_BAD_JSON \"m.room.redaction requires content.redacts\", nothing written", %{a: a, b: b} do
        room = room_of(a, [b])
        conn = rd_unchanged(room, fn -> send_redaction(b, room, unquote(Macro.escape(content)), "t1") end)
        assert_refused(conn, 400, "M_BAD_JSON", "m.room.redaction requires content.redacts")
        assert dedup_entry(send_key(room, b, @redaction, "t1")) == []
      end
    end
  end

  describe "AC4 (c) - idempotency with the /send key" do
    test "the same txn id again: 200 with the SAME event id, one row, the ETS entry is the /send key", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "once")

      first = ok_event_id!(send_redaction(b, room, %{"redacts" => m}, "same"), "first")
      again = ok_event_id!(send_redaction(b, room, %{"redacts" => m}, "same"), "again")

      assert again == first
      assert redaction_ids(room) == [first]
      assert dedup_entry(send_key(room, b, @redaction, "same")) == [{send_key(room, b, @redaction, "same"), first}]
    end
  end

  describe "AC4 (g) - the /send txn key includes the event type (Kassandra #5): a txn id is scoped to its path" do
    test "/send message T, then /send redaction T: independent (the redaction is written, not answered as a replay of the message)", %{a: a, b: b} do
      room = room_of(a, [b])
      target = say!(b, room, "target")
      message_path = path(room, "send/m.room.message/T")
      message = ok_event_id!(T.matrix_request(:put, message_path, b.at, body: %{"msgtype" => "m.text", "body" => "hi"}), "message")

      redaction = ok_event_id!(send_redaction(b, room, %{"redacts" => target}, "T"), "redaction")

      assert redaction != message
      assert row(redaction).redacts == target
      assert dedup_entry(send_key(room, b, "m.room.message", "T")) == [{send_key(room, b, "m.room.message", "T"), message}]
      assert dedup_entry(send_key(room, b, @redaction, "T")) == [{send_key(room, b, @redaction, "T"), redaction}]
    end

    test "/send redaction T, then /send message T: independent; the replays are per type", %{a: a, b: b} do
      room = room_of(a, [b])
      target = say!(b, room, "target")
      redaction = ok_event_id!(send_redaction(b, room, %{"redacts" => target}, "T"), "redaction")
      message_path = path(room, "send/m.room.message/T")
      body = %{"msgtype" => "m.text", "body" => "hi"}

      message = ok_event_id!(T.matrix_request(:put, message_path, b.at, body: body), "message")

      assert message != redaction
      assert row(message).type == "m.room.message"
      assert ok_event_id!(T.matrix_request(:put, message_path, b.at, body: body), "message replay") == message
      assert ok_event_id!(send_redaction(b, room, %{"redacts" => target}, "T"), "redaction replay") == redaction
    end

    test "two message types with the same txn id are independent too (m.room.message and m.custom)", %{a: a, b: b} do
      room = room_of(a, [b])
      one = ok_event_id!(T.matrix_request(:put, path(room, "send/m.room.message/T"), b.at, body: %{"msgtype" => "m.text", "body" => "one"}), "one")
      two = ok_event_id!(T.matrix_request(:put, path(room, "send/m.custom/T"), b.at, body: %{"x" => 1}), "two")
      assert one != two
    end

    test "a /send redaction whose content.redacts contains a NUL: 400 M_BAD_JSON, nothing written, no ERROR log, the value is not echoed", %{a: a, b: b} do
      room = room_of(a, [b])
      bad = "$a\u0000b"

      log = capture_log(fn -> send(self(), {:conn, rd_unchanged(room, fn -> send_redaction(b, room, %{"redacts" => bad}, "t1") end)}) end)

      assert_received {:conn, conn}
      assert_err(conn, 400, "M_BAD_JSON")
      refute conn.resp_body =~ "\u0000", "the value is not echoed"
      refute log =~ "[error]", "a client value triggers no ERROR log"
    end
  end

  # ═══ AC5: every read path is pruned ═══════════════════════════════════════════════════

  describe "AC5 (a) - the original content is in no response body on any read path" do
    test "the marker word of the redacted message appears in no body of /messages (both directions), /event, /sync, /initialSync (positive control before)", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      m = say!(b, room, "secret " <> word)

      for how <- served_paths() do
        {_ev, raw} = served(c, room, m, how)
        assert raw =~ word, "positive control #{how}: the marker is served before the redaction"
      end

      id = redact_id!(b, room, m, %{"reason" => "typo"})

      for how <- served_paths() do
        {ev, raw} = served(c, room, m, how)
        refute raw =~ word, "#{how}: the marker must not be in the response"
        assert ev["content"] == %{} and ev["unsigned"]["redacted_because"]["event_id"] == id, "#{how}: pruned"
        {red, _raw} = served(c, room, id, how)
        assert red["redacts"] == m and red["content"]["redacts"] == m, "#{how}: the redaction event carries both redacts"
      end
    end

    test "the incremental /sync: M and R in ONE delta are served pruned (a sync token is used once per user)", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      since = next(sync(c))
      tick()
      m = say!(b, room, "secret " <> word)
      tick()
      id = redact_id!(b, room, m)

      together = sync_conn(c, since: since, timeout: 0)

      assert together.status == 200
      events = together |> T.json() |> join_timeline(room)
      assert Enum.map(events, & &1["event_id"]) == [m, id], "an incremental delta of exactly M and R"
      pruned = Enum.find(events, &(&1["event_id"] == m))
      assert pruned["content"] == %{} and pruned["unsigned"]["redacted_because"]["event_id"] == id
      refute together.resp_body =~ word
      assert Enum.find(events, &(&1["event_id"] == id))["redacts"] == m
    end

    test "the incremental /sync: R alone (M delivered earlier) carries the top-level redacts the client applies", %{a: a, b: b} do
      room = room_of(a, [b])
      since = next(sync(b))
      tick()
      m = say!(b, room, "to be removed")
      middle = next(sync(b, since))
      tick()
      id = redact_id!(b, room, m)

      only = b |> sync(middle) |> join_timeline(room)

      assert Enum.map(only, & &1["event_id"]) == [id], "only the redaction is new: #{inspect(Enum.map(only, &{&1["type"], &1["event_id"]}))}"
      assert hd(only)["redacts"] == m and hd(only)["content"]["redacts"] == m
    end

    test "the /sync LEAVE window of a member who left after the redaction serves the target pruned", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      since = next(sync(c))
      tick()
      m = say!(b, room, "secret " <> word)
      tick()
      id = redact_id!(b, room, m)
      tick()
      leave!(c, room)

      conn = sync_conn(c, since: since, timeout: 0)

      assert conn.status == 200
      refute conn.resp_body =~ word, "the original content is not in the leave window"
      events = conn |> T.json() |> leave_timeline(room)
      assert Enum.find(events, &(&1["event_id"] == m))["content"] == %{}
      assert Enum.find(events, &(&1["event_id"] == m))["unsigned"]["redacted_because"]["event_id"] == id
      assert Enum.find(events, &(&1["event_id"] == id))["redacts"] == m
    end

    test "the thread-root prepend of the delta /sync: a redacted thread root M is prepended pruned when a new reply follows the redaction", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      root = say!(b, room, "root " <> word)
      since = next(sync(c))
      tick()
      id = redact_id!(b, room, root)
      tick()
      reply = relate!(c, room, "m.thread", root, "a reply")

      conn = sync_conn(c, since: since, timeout: 0)

      assert conn.status == 200
      refute conn.resp_body =~ word, "the original content of the root is not in the delta"
      events = conn |> T.json() |> join_timeline(room)
      prepended = Enum.find(events, &(&1["event_id"] == root))
      assert prepended != nil, "the thread root is prepended to the delta (it is not part of it)"
      assert prepended["content"] == %{} and prepended["unsigned"]["redacted_because"]["event_id"] == id
      assert Enum.find(events, &(&1["event_id"] == reply))["content"]["body"] == "a reply"
    end
  end

  describe "AC5 (b) - search never returns a redacted event" do
    test "POST /search for the marker word: one result before the redaction, none after; an unrelated message is still found", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      other = word("ok")
      m = say!(b, room, "secret " <> word)
      keep = say!(b, room, "unrelated " <> other)
      assert search_ids(c, word) == [m], "positive control: found before the redaction"

      redact_id!(b, room, m)

      assert search_ids(c, word) == []
      {_json, raw} = search(c, word)
      refute raw =~ word
      assert search_ids(c, other) == [keep], "an unrelated message of the same room is still found"
    end
  end

  describe "Kassandra #2 - search excludes an m.replace edit whose original is redacted" do
    test "found before the redaction of its original, not after; an edit of an unredacted original is still found; /messages still serves the edit", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      old_word = word("ow")
      new_word = word("nw")
      kept_word = word("kw")
      original = say!(b, room, "original " <> old_word)
      edit = relate!(b, room, "m.replace", original, "* edited " <> new_word, %{"m.new_content" => %{"msgtype" => "m.text", "body" => "edited " <> new_word}})
      other = say!(b, room, "other " <> kept_word)
      other_edit = relate!(b, room, "m.replace", other, "* kept " <> kept_word)
      assert search_ids(c, new_word) == [edit], "positive control: the edit is found"

      redact_id!(b, room, original)

      assert search_ids(c, new_word) == [], "the edit of a redacted original is not found any more"
      assert search_ids(c, old_word) == []
      assert other_edit in search_ids(c, kept_word), "an edit of an unredacted original is still found"
      served = c |> messages(room) |> Enum.find(&(&1["event_id"] == edit))
      assert served["content"]["m.new_content"]["body"] == "edited " <> new_word, "documented residual: the edit stays served in /messages (spec: edits are not redacted)"
    end
  end

  describe "AC5 (c) - relations: a redacted child leaves the aggregation, a redacted parent keeps its children" do
    test "/relations/{parent} omits a redacted reaction and a redacted thread reply; the thread count excludes the thread reply", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      parent = say!(b, room, "parent")
      reaction = relate!(c, room, "m.annotation", parent, "x", %{"key" => "+1"})
      reply1 = relate!(c, room, "m.thread", parent, "reply one")
      reply2 = relate!(c, room, "m.thread", parent, "reply two")
      assert Enum.sort(relation_ids(b, room, parent)) == Enum.sort([reaction, reply1, reply2]), "positive control: #{inspect(relations(b, room, parent))}"
      assert {:ok, 2} = DB.count_thread_children(room, parent)

      redact_id!(c, room, reaction)
      redact_id!(c, room, reply1)

      assert relation_ids(b, room, parent) == [reply2]
      assert {:ok, 1} = DB.count_thread_children(room, parent), "the thread count excludes the redacted reply"
    end

    test "a redacted PARENT still lists its children (not redacted: their own content is served)", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      parent = say!(b, room, "parent")
      reply = relate!(c, room, "m.thread", parent, "child reply")

      redact_id!(b, room, parent)

      assert [child] = relations(c, room, parent)
      assert child["event_id"] == reply
      assert child["content"]["body"] == "child reply"
      assert {:ok, 1} = DB.count_thread_children(room, parent)
    end
  end

  describe "AC5 (d) - an edit of a redacted original stays served" do
    test "the m.replace edit keeps its own content on /event and in /relations of the (redacted) original", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      original = say!(b, room, "original")
      edit = relate!(b, room, "m.replace", original, "* edited", %{"m.new_content" => %{"msgtype" => "m.text", "body" => "edited"}})

      redact_id!(b, room, original)

      assert event!(c, room, original)["content"] == %{}
      served_edit = event!(c, room, edit)
      assert served_edit["content"]["body"] == "* edited", "the edit is not redacted by the redaction of its original (spec)"
      refute Map.has_key?(served_edit["unsigned"] || %{}, "redacted_because")
      assert edit in relation_ids(c, room, original)
    end
  end

  describe "AC5 (e) - a LEGACY redaction row (column NULL) is never applied" do
    test "M2 stays served everywhere; the legacy row is served without a top-level redacts and without content.redacts; the stored row keeps the key", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      m2 = say!(b, room, "stays visible")
      legacy = insert_legacy_redaction!(room, b, m2, %{"reason" => "legacy reason", "x_other" => 1}, ts_after(room))

      for how <- served_paths() do
        {ev, _raw} = served(c, room, m2, how)
        assert ev["content"]["body"] == "stays visible", "#{how}: a legacy redaction does not redact"
        refute Map.has_key?(ev["unsigned"] || %{}, "redacted_because"), "#{how}: no redacted_because"
        {red, _raw} = served(c, room, legacy, how)
        refute Map.has_key?(red, "redacts"), "#{how}: no top-level redacts"
        assert red["content"] == %{"reason" => "legacy reason", "x_other" => 1}, "#{how}: no content.redacts, the other keys unchanged"
      end

      stored = row(legacy)
      assert stored.redacts == nil, "the column stays NULL"
      assert stored.content["redacts"] == m2, "the stored row is not changed: the client's key is still in it"
    end
  end

  describe "AC5 (f) - the batched lookup is ONE statement per response" do
    setup do
      install_lookup_hook!()
      :ok
    end

    test "one redactions_for/1 call per /messages, /event, /relations, /initialSync, per initial and per incremental /sync (positive control: the counter counts)", %{a: a, b: b} do
      room = room_of(a, [b])
      parent = say!(b, room, "parent")
      relate!(b, room, "m.thread", parent, "child")
      since = next(sync(b))
      tick()
      say!(b, room, "newer")
      Hooks.reset_count()
      assert Hooks.count() == 0

      sync(b, since)
      assert Hooks.count() == 1, "an incremental /sync with ONE joined room and no thread root to prepend"
      Hooks.reset_count()

      assert messages_conn(b, room, "b").status == 200
      assert Hooks.count() == 1, "/messages"
      Hooks.reset_count()
      assert get_event(b, room, parent).status == 200
      assert Hooks.count() == 1, "/event"
      Hooks.reset_count()
      relations(b, room, parent)
      assert Hooks.count() == 1, "/relations"
      Hooks.reset_count()
      assert initial_sync_conn(b, room).status == 200
      assert Hooks.count() == 1, "/initialSync"
      Hooks.reset_count()
      sync(b)
      assert Hooks.count() == 1, "an initial /sync with ONE joined room"
    end

    test "three joined rooms: ONE call per joined room for the initial and for the incremental /sync (3 and 3), none extra", %{a: a, b: b} do
      rooms = for _ <- 1..3, do: room_of(a, [b])
      since = next(sync(b))
      tick()
      for r <- rooms, do: say!(a, r, "new")
      Hooks.reset_count()

      sync(b, since)
      assert Hooks.count() == 3, "incremental /sync: one batched lookup per room with new events"
      Hooks.reset_count()
      sync(b)
      assert Hooks.count() == 3, "initial /sync: one batched lookup per joined room"
    end

    test "ONE call for ALL leave entries of one /sync response (a user who left two rooms)", %{a: a, b: b} do
      first = room_of(a, [b])
      second = room_of(a, [b])
      since = next(sync(b))
      tick()
      say!(a, first, "in first")
      say!(a, second, "in second")
      tick()
      leave!(b, first)
      leave!(b, second)
      Hooks.reset_count()

      body = sync(b, since)

      assert Map.keys(section(body, "leave")) |> Enum.sort() == Enum.sort([first, second])
      assert section(body, "join") == %{}
      assert Hooks.count() == 1, "one batched lookup for the whole leave section"
    end
  end

  describe "AC5 (g) - a failing lookup fails CLOSED" do
    test "redactions_for/1 failing: 500 on /messages, /event, /relations, /initialSync, the initial and the incremental /sync and the leave window; healed: 200", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      m = say!(b, room, "secret " <> word)
      relate!(b, room, "m.thread", m, "child")
      id = redact_id!(b, room, m)
      since = next(sync(c))
      tick()
      say!(b, room, "newer")
      install_lookup_hook!()

      requests = [
        {"/messages", fn -> messages_conn(c, room, "b") end},
        {"/event", fn -> get_event(c, room, m) end},
        {"/relations", fn -> T.matrix_request(:get, relations_path(room, m), c.at) end},
        {"/initialSync", fn -> initial_sync_conn(c, room) end},
        {"incremental /sync", fn -> sync_conn(c, since: since, timeout: 0) end},
        {"initial /sync", fn -> sync_conn(c, since: nil, timeout: 0) end}
      ]

      Hooks.fail_lookup()

      for {label, request} <- requests do
        assert {:ok, conn} = isolated(request), "#{label}: the request process must not crash"
        assert conn.status == 500, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
        refute conn.resp_body =~ word, "#{label}: never an unpruned page"
        assert Map.keys(T.json(conn)) |> Enum.sort() == ["errcode", "error"], "#{label}: the generic envelope"
      end

      Hooks.heal_lookup()

      for {label, request} <- requests do
        conn = request.()
        assert conn.status == 200, "#{label} healed: #{conn.status}"
        refute conn.resp_body =~ word, "#{label} healed: pruned"
      end

      assert event!(c, room, m)["unsigned"]["redacted_because"]["event_id"] == id
    end

    test "the leave window fails closed too", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      word = word("mk")
      since = next(sync(c))
      tick()
      m = say!(b, room, "secret " <> word)
      tick()
      redact_id!(b, room, m)
      tick()
      leave!(c, room)
      install_lookup_hook!()
      Hooks.fail_lookup()

      assert {:ok, conn} = isolated(fn -> sync_conn(c, since: since, timeout: 0) end)

      assert conn.status == 500
      refute conn.resp_body =~ word
    end
  end

  # ═══ the /send path of the D2 order (test review M-5, M-6) ═════════════════════════════

  describe "AC4 (f) - /send of m.room.redaction: the refusals of D2, nothing written" do
    test "a non-member: 403 \"You are not a member of this room\"", %{a: a, b: b, c: c} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      conn = rd_unchanged(room, fn -> send_redaction(c, room, %{"redacts" => m}, "t1") end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member, [m])
      assert dedup_entry(send_key(room, c, @redaction, "t1")) == []
    end

    test "an archived room (process running): 400 M_BAD_STATE", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "target")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      conn = rd_unchanged(room, fn -> send_redaction(b, room, %{"redacts" => m}) end)
      assert_refused(conn, 400, "M_BAD_STATE", @archived_text, [m])
    end

    test "an unknown room: 404 M_NOT_FOUND \"Room not found\", no rooms row", %{a: a} do
      ghost = "!ghost" <> T.rand(8) <> ":" <> T.server_name()
      conn = send_redaction(a, ghost, %{"redacts" => "$any" <> T.rand(8)})
      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found", [ghost])
      assert rooms_row_count(ghost) == 0
    end

    test "a state event as the target: 403 \"This event cannot be redacted on this server\"", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = rd_unchanged(room, fn -> send_redaction(a, room, %{"redacts" => latest_pl(room).event_id}) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
    end

    test "another user's event redacted through /send writes the audit row room_event_redacted (like /redact)", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "to be moderated")

      send_id = ok_event_id!(send_redaction(a, room, %{"redacts" => m}), "send")

      assert row(send_id).redacts == m
      assert [%{actor: actor, metadata: metadata, outcome: "success"}] = redact_audit(room)
      assert actor == a.uid and metadata == %{"event_id" => m, "target_sender" => b.uid}
    end
  end

  describe "D2 (4) before (5) and the >= boundary of the redact level (test review M-6)" do
    test "a member at 0 whose target is a STATE event gets \"cannot be redacted\", not the redact-level text", %{a: a, b: b} do
      room = seeded(a, [b], %{})
      conn = rd_unchanged(room, fn -> redact(b, room, latest_pl(room).event_id) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @state_text)
    end

    test "a user at 50 with redact 51 is refused for another user's event (the other side of the >= boundary); at 51 he may", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{c.uid => 50}, %{"redact" => 51})
      m = say!(b, room, "target")
      conn = rd_unchanged(room, fn -> redact(c, room, m) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @redact_text, [m])
      ok_event_id!(put_pl(a, room, put_in(column(room), ["users", c.uid], 51)), "promotion to 51")
      assert row(redact_id!(c, room, m)).redacts == m
    end
  end

  # ═══ AC11: audit ═══════════════════════════════════════════════════════════════════

  describe "AC11 - the audit row of a redaction of ANOTHER user's event (D12)" do
    test "a committed redaction of another user's event writes exactly one room_event_redacted row with exactly event_id + target_sender", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "to be moderated")

      id = redact_id!(a, room, m, %{"reason" => "spam"})

      assert [audit] = redact_audit(room)
      assert audit == %{actor: a.uid, action: "room_event_redacted", target_type: "room", target_id: room, metadata: %{"event_id" => m, "target_sender" => b.uid}, outcome: "success"}
      assert row(id).redacts == m
    end

    test "an own redaction writes no row (the signed event is the record)", %{a: a, b: b} do
      room = room_of(a, [b])
      redact_id!(b, room, say!(b, room, "own"))
      assert redact_audit(room) == []
    end

    test "the idempotent replay writes no second row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "once")
      first = ok_event_id!(redact(a, room, m, %{}, "same"), "first")
      assert length(redact_audit(room)) == 1

      assert ok_event_id!(redact(a, room, m, %{}, "same"), "replay") == first

      assert length(redact_audit(room)) == 1, "the replay is not audited again"
    end

    test "every refusal writes no row", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      m = say!(b, room, "target")

      assert redact(c, room, m).status == 403
      assert redact(a, room, "$ghost" <> T.rand(8)).status == 404
      assert redact(a, room, latest_pl(room).event_id).status == 403

      assert redact_audit(room) == []
    end

    test "AuditWriter.log/6 accepts the action", %{a: a} do
      room = public_room(a)
      assert :ok = Nebu.Compliance.AuditWriter.log(a.uid, "room_event_redacted", "room", room, %{"event_id" => "$x", "target_sender" => a.uid}, "success")
      assert [%{metadata: %{"event_id" => "$x"}}] = redact_audit(room)
    end

    test "a failing audit writer does not fail the redaction: 200, the event is written, a value-free ERROR is logged", %{a: a, b: b} do
      room = room_of(a, [b])
      reason = word("rs")
      body = word("bd")
      m = say!(b, room, body)
      Application.put_env(:compliance, :audit_writer, FailingAudit)

      log = capture_log(fn -> send(self(), {:conn, redact(a, room, m, %{"reason" => reason})}) end)

      assert_received {:conn, conn}
      id = ok_event_id!(conn, "redact")
      assert row(id).redacts == m
      assert log =~ "[error]", "the failure is logged as an ERROR"
      assert log =~ room, "the log names the room id"
      refute log =~ reason, "no reason in the log"
      refute log =~ body, "no message content in the log"
    end

    test "neither the reason nor the message content appears in a log line of a moderator redaction, nor in the audit row", %{a: a, b: b} do
      room = room_of(a, [b])
      reason = word("rs")
      body = word("bd")
      m = say!(b, room, body)

      log = capture_log(fn -> send(self(), {:conn, redact(a, room, m, %{"reason" => reason})}) end)

      assert_received {:conn, conn}
      ok_event_id!(conn, "redact")
      refute log =~ reason
      refute log =~ body
      refute inspect(redact_audit(room)) =~ reason
      refute inspect(redact_audit(room)) =~ body
    end
  end

  # ═══ AC17: the Oracle tests ═════════════════════════════════════════════════════════

  describe "AC17 (a) - the redaction level is checked before redact" do
    test "events[m.room.redaction] 75, redact 50: a user at 60 redacts another user's event: 403 with the SEND text; a user at 80 may", %{a: a, b: b, c: c, d: d} do
      room = seeded(a, [b, c, d], %{c.uid => 60, d.uid => 80}, %{"redact" => 50, "events" => %{@pl => 50, @redaction => 75}})
      m = say!(b, room, "target")

      conn = rd_unchanged(room, fn -> redact(c, room, m) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @send_text, [m])
      assert event!(a, room, m)["content"]["body"] == "target"
      assert row(redact_id!(d, room, m)).redacts == m, "positive control: a user at 80 may"
    end
  end

  describe "AC17 (b) - a retry after the user lost the right is 403 (authorisation is re-evaluated before idempotency)" do
    test "a redaction succeeds with txn T; the user is demoted below the redaction level; T retried: 403, no second row", %{a: a, b: b} do
      room = seeded(a, [b], %{b.uid => 20}, %{"events" => %{@pl => 50, @redaction => 10}})
      m = say!(b, room, "mine")
      first = ok_event_id!(redact(b, room, m, %{}, "txn-t"), "first")
      ok_event_id!(put_pl(a, room, put_in(column(room), ["users", b.uid], 0)), "demotion")

      conn = rd_unchanged(room, fn -> redact(b, room, m, %{}, "txn-t") end)

      assert_refused(conn, 403, "M_FORBIDDEN", @send_text, [m])
      assert redaction_ids(room) == [first], "no second row"
    end

    test "a redaction succeeds with txn T; the user is kicked; T retried: 403 (not a member), no second row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "mine")
      first = ok_event_id!(redact(b, room, m, %{}, "txn-t"), "first")
      ok!(kick(a, room, b), "kick")

      conn = rd_unchanged(room, fn -> redact(b, room, m, %{}, "txn-t") end)

      assert_refused(conn, 403, "M_FORBIDDEN", @not_member, [m])
      assert redaction_ids(room) == [first]
    end
  end

  describe "AC17 (c) - the txn scope is per user, not per device (bd)" do
    test "the same user with a second session, the same /redact path and txn id: 200 with the FIRST event id, one row", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "mine")
      second = %{uid: b.uid, at: T.legacy_session!(b.uid, "RDS" <> String.upcase(T.rand(3)), expires_at: session_expiry()).at}

      first = ok_event_id!(redact(b, room, m, %{}, "same-txn"), "device one")
      other = ok_event_id!(redact(second, room, m, %{}, "same-txn"), "device two")

      assert other == first, "per-user scope: the second device gets the first event id"
      assert redaction_ids(room) == [first]
    end
  end

  describe "AC17 (d) - a refusal is never cached" do
    test "a refused redaction (below redact) with txn T; the user is promoted; T retried: 200 with a NEW event", %{a: a, b: b, c: c} do
      room = seeded(a, [b, c], %{})
      m = say!(b, room, "target")
      assert_refused(redact(c, room, m, %{}, "txn-t"), 403, "M_FORBIDDEN", @redact_text)
      ok_event_id!(put_pl(a, room, put_in(column(room), ["users", c.uid], 50)), "promotion")

      id = ok_event_id!(redact(c, room, m, %{}, "txn-t"), "retry")

      assert row(id).redacts == m and row(id).sender == c.uid
      assert redaction_ids(room) == [id]
    end
  end

  describe "AC17 (e) - /send of m.room.redaction: shape rules" do
    test "content.redacts \"\" is 400 M_BAD_JSON", %{a: a, b: b} do
      room = room_of(a, [b])
      conn = rd_unchanged(room, fn -> send_redaction(b, room, %{"redacts" => ""}) end)
      assert_refused(conn, 400, "M_BAD_JSON", "m.room.redaction requires content.redacts")
    end

    test "a target of ANOTHER room is 404 M_NOT_FOUND \"Event not found\"", %{a: a, b: b} do
      room = room_of(a, [b])
      other = room_of(a, [b])
      foreign = say!(b, other, "elsewhere")
      conn = rd_unchanged(room, fn -> send_redaction(b, room, %{"redacts" => foreign}) end)
      assert_refused(conn, 404, "M_NOT_FOUND", "Event not found", [foreign])
      assert event!(a, other, foreign)["content"]["body"] == "elsewhere"
    end

    test "{redacts, reason, x_extra}: 200, the stored content keeps reason and x_extra, redacts is top-level only", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "mine")

      id = ok_event_id!(send_redaction(b, room, %{"redacts" => m, "reason" => "typo", "x_extra" => %{"k" => 1}}), "send")

      r = row(id)
      assert r.redacts == m
      assert r.content == %{"reason" => "typo", "x_extra" => %{"k" => 1}}
    end
  end

  describe "AC17 (f) - redacting an m.replace edit" do
    test "the edit is served pruned, the original keeps its content, /relations/{original} no longer lists the edit", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      original = say!(b, room, "original text")
      edit = relate!(b, room, "m.replace", original, "* edited", %{"m.new_content" => %{"msgtype" => "m.text", "body" => "edited"}})
      assert edit in relation_ids(c, room, original), "positive control"

      id = redact_id!(b, room, edit)

      served_edit = event!(c, room, edit)
      assert served_edit["content"] == %{} and served_edit["unsigned"]["redacted_because"]["event_id"] == id
      assert event!(c, room, original)["content"]["body"] == "original text"
      refute edit in relation_ids(c, room, original)
    end
  end

  describe "AC17 (g) - redacting a reply and a thread reply" do
    test "a message with an m.reference relation is served content {} and is gone from /relations", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      parent = say!(b, room, "parent")
      reply = relate!(c, room, "m.reference", parent, "a reply")
      assert reply in relation_ids(b, room, parent)

      redact_id!(c, room, reply)

      assert event!(b, room, reply)["content"] == %{}
      refute reply in relation_ids(b, room, parent)
    end

    test "a plain reply (m.in_reply_to, no rel_type) is served content {} and redacted_because", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      parent = say!(b, room, "parent")
      content = %{"msgtype" => "m.text", "body" => "a plain reply", "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => parent}}}
      conn = T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), c.at, body: content)
      reply = ok_event_id!(conn, "reply")
      assert event!(b, room, reply)["content"]["body"] == "a plain reply"

      id = redact_id!(c, room, reply)

      served_reply = event!(b, room, reply)
      assert served_reply["content"] == %{} and served_reply["unsigned"]["redacted_because"]["event_id"] == id
      assert event!(b, room, parent)["content"]["body"] == "parent", "the parent is untouched"
    end

    test "a thread reply is served content {} and is gone from /relations and from the thread count; a redacted thread ROOT still lists its replies", %{a: a, b: b, c: c} do
      room = room_of(a, [b, c])
      root = say!(b, room, "root")
      keep = relate!(c, room, "m.thread", root, "kept reply")
      gone = relate!(c, room, "m.thread", root, "removed reply")
      assert {:ok, 2} = DB.count_thread_children(room, root)

      redact_id!(c, room, gone)

      assert event!(b, room, gone)["content"] == %{}
      assert relation_ids(b, room, root) == [keep]
      assert {:ok, 1} = DB.count_thread_children(room, root)

      redact_id!(b, room, root)

      assert event!(c, room, root)["content"] == %{}
      assert relation_ids(c, room, root) == [keep], "the redacted root still lists its remaining replies"
    end
  end

  describe "AC17 (h) - the sender of the target has left or was banned since" do
    test "an event whose sender has since LEFT is redacted by a moderator: 200", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "from a leaver")
      leave!(b, room)

      id = redact_id!(a, room, m)

      assert row(id).redacts == m
      assert event!(a, room, m)["content"] == %{}
    end

    test "an event whose sender has since been BANNED is redacted by a moderator: 200", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "from a banned user")
      ok!(ban(a, room, b), "ban")

      id = redact_id!(a, room, m)

      assert row(id).redacts == m
      assert event!(a, room, m)["content"] == %{}
    end
  end

  describe "AC17 (j) - the room process of a known room is not running" do
    test "/redact answers 404 M_NOT_FOUND, no lazy start, no new rooms row, no process", %{a: a, b: b} do
      room = room_of(a, [b])
      m = say!(b, room, "x")
      stop_room!(room)
      rows_before = rooms_row_count(room)

      conn = redact(b, room, m)

      assert_refused(conn, 404, "M_NOT_FOUND", "Room not found")
      refute running?(room)
      assert rooms_row_count(room) == rows_before
    end
  end

  describe "AC17 (p) - filters never match on the stored original content (Nebu ignores filters: follow-up fg (a))" do
    test "/messages with a types filter and a not_types filter: the redacted message is still served pruned", %{a: a, b: b} do
      room = room_of(a, [b])
      word = word("mk")
      m = say!(b, room, "secret " <> word)
      id = redact_id!(b, room, m)

      for filter <- [%{"types" => ["m.room.message"]}, %{"not_types" => ["m.room.member"]}, %{"contains_url" => false}] do
        conn = T.matrix_request(:get, path(room, "messages") <> "?dir=b&limit=100&filter=" <> URI.encode_www_form(Jason.encode!(filter)), b.at)
        assert conn.status == 200
        refute conn.resp_body =~ word, "filter #{inspect(filter)}: the original content is not in the response"
        served_m = Enum.find(T.json(conn)["chunk"], &(&1["event_id"] == m))
        assert served_m["content"] == %{} and served_m["unsigned"]["redacted_because"]["event_id"] == id
      end
    end

    test "/sync with a types filter: the redacted message is still served pruned", %{a: a, b: b} do
      room = room_of(a, [b])
      word = word("mk")
      m = say!(b, room, "secret " <> word)
      redact_id!(b, room, m)
      filter = URI.encode_www_form(Jason.encode!(%{"room" => %{"timeline" => %{"types" => ["m.room.message"], "not_types" => ["m.room.member"]}}}))

      conn = T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0&filter=" <> filter, b.at)

      assert conn.status == 200
      refute conn.resp_body =~ word
      assert Enum.find(conn |> T.json() |> join_timeline(room), &(&1["event_id"] == m))["content"] == %{}
    end
  end

  describe "AC17 (q) - search and the reason of a redaction" do
    test "a word of the redaction's reason finds nothing; an unrelated message of the room is still found after the redaction", %{a: a, b: b} do
      room = room_of(a, [b])
      reason_word = word("rs")
      other = word("ok")
      m = say!(b, room, "target " <> word("tg"))
      keep = say!(b, room, "unrelated " <> other)

      redact_id!(b, room, m, %{"reason" => "because " <> reason_word})

      assert search_ids(b, reason_word) == [], "the reason lives in a redaction event, which is no m.room.message"
      assert search_ids(b, other) == [keep]
    end
  end

  describe "AC17 (r) - the redacted_because copy" do
    test "contains no unsigned and none of the target's content: exactly the served redaction keys", %{a: a, b: b} do
      room = room_of(a, [b])
      word = word("mk")
      m = say!(b, room, "secret " <> word)
      id = redact_id!(a, room, m, %{"reason" => "moderated"})

      conn = get_event(b, room, m)

      because = T.json(conn)["unsigned"]["redacted_because"]
      assert Enum.sort(Map.keys(because)) == ["content", "event_id", "origin_server_ts", "redacts", "room_id", "sender", "type"], "no unsigned, no state_key"
      assert because["event_id"] == id and because["content"] == %{"reason" => "moderated", "redacts" => m}
      refute conn.resp_body =~ word
    end
  end
end
