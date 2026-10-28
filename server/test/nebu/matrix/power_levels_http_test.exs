defmodule Nebu.Matrix.PowerLevelsHttpTest do
  @moduledoc """
  Story `power-levels-enforcement` (epic oauth-broker, follow-ups `eq`, `er`, `fr`), HTTP half: AC1, AC2, AC3, AC4 (a) - (c), (e), AC5 (b), (c), AC9, AC10, AC11, AC12,
  AC13 (HTTP part) and the sixteen Oracle tests AC17 (a) - (p). Real stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, real `Room.Server` /
  Horde / `:pg`, users and legacy sessions as in the moderation suites (random localparts, `:server_name` pinned). Everything the real SQL decides is asserted
  against the real database (the stored column, the levels events, the in-memory levels, the audit rows); the writer's atomicity, stamp and crash / restart claims
  are in `room/power_levels_writer_db_test.exs`, the races in `power_levels_concurrency_test.exs`, the pure rules in `room/power_levels_unit_test.exs`.

  The shared helpers are `Nebu.Matrix.PowerLevelsTestSupport` (built on `Nebu.Matrix.ModerationTestSupport`).

  ## Decisions of the ATDD step (ambiguities of the story, listed in the report)

    * Levels are set up with `Room.Server.set_power_levels/3` seeds by the room creator (the `:internal` writer, no change rules), as the story says. `levels/2` builds a
      COMPLETE, strictly valid content so a seed never depends on the default `events` map of the code under test.
    * `state.power_levels` of the room process is the RAW stored content (what `/sync` delivers), compared with the stored column; the normalised view is a separate
      field the tests never read.
    * The fixed 400 texts are the override texts of `create-room-presets-power-levels-topic` (the story says the validator keeps them); the text of a top-level `null` is
      NOT pinned (status and errcode only). The 500 of a failed write is asserted with the story's text "The power levels could not be changed" and errcode `M_UNKNOWN`.
    * AC1 (b) "an unknown room id": the answer is the one PUT state gives today (`403 M_FORBIDDEN` "You are not a member of this room"); the story's "no rooms row
      created" is pinned for THIS route (today a state PUT into an unknown room lazily creates a rooms row: a pre-existing defect, not touched here).
    * AC9 (d): the story says an `initial_state` entry that omits a `trusted_private_chat` invitee leaves him at 0, but D7 / D2 (7) apply the v10 change rules with the
      creator as sender, and removing an entry whose current value (100) is not below the sender's (100) is refused: pinned as the rule says (`400
      M_INVALID_ROOM_STATE`); the entry that REPEATS the invitee is the passing case.
    * The no-op of D2 (6) is asserted by the CURRENT event id, the event count, the audit rows and a `:pg` listener (positive control: a real change IS delivered).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport

  alias Nebu.Matrix.PowerLevelsTestSupport.FailingAudit
  alias Nebu.Matrix.PowerLevelsTestSupport.Hooks
  alias Nebu.Matrix.Room.PowerLevels
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @pl "m.room.power_levels"
  @max_level 9_007_199_254_740_991

  @not_member "You are not a member of this room"
  @low_level "You do not have a high enough power level to change the power levels"
  @above_own "You cannot change a power level above your own"
  @grant_above "You cannot grant a power level above your own"
  @target_not_lower "You cannot change the power level of a user whose level is not lower than yours"
  @empty_key "m.room.power_levels requires an empty state key"
  @int_text "power level values must be integers within +-(2^53 - 1)"
  @send_text "You do not have a high enough power level to send this event"
  @state_text "You do not have a high enough power level to set this state"
  @at_text "You cannot set a state event whose state key is another user's id"
  @lock_out_text "The power levels do not allow the room creator to set the initial room state"
  @grant_initial_text "The initial power levels cannot grant more than the room creator has"
  @upgrade_above_text "The room has power levels above yours: a user with the highest level must upgrade it"

  @d12_events %{
    "m.room.power_levels" => 100,
    "m.room.history_visibility" => 100,
    "m.room.tombstone" => 100,
    "m.room.server_acl" => 100,
    "m.room.encryption" => 100,
    "m.room.name" => 50,
    "m.room.avatar" => 50,
    "m.room.canonical_alias" => 50
  }

  setup do
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "this suite requires the limiter ENABLED: NEBU_RATE_LIMIT_DISABLED must not be \"true\" in the test harness"

    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    tier_keys = [:rate_limit_moderation_per_min, :rate_limit_moderation_burst]
    saved = for key <- tier_keys, do: {key, Application.fetch_env(:nebu_http, key)}
    # the PRIOR audit writer is snapshotted BEFORE the real one is put in place (the test environment runs a NoOp writer)
    prior_audit = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    # the clock of the limiter is frozen (no refill): a big budget, so that the many PUTs of a test are not the subject (AC11 sets its own)
    Application.put_env(:nebu_http, :rate_limit_moderation_per_min, 1_000_000)
    Application.put_env(:nebu_http, :rate_limit_moderation_burst, 1_000_000)

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- saved do
        case previous do
          {:ok, value} -> Application.put_env(:nebu_http, key, value)
          :error -> Application.delete_env(:nebu_http, key)
        end
      end

      case prior_audit do
        {:ok, value} -> Application.put_env(:compliance, :audit_writer, value)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    {:ok, a: user!("PLA"), b: user!("PLB"), c: user!("PLC"), d: user!("PLD")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # a public room: owner `a` at 100, `b` at 50 (the levels event needs 50), c and d joined at 0; `extra` replaces top-level keys of `levels/2`
  defp fifty_room(a, b, c, d, users \\ %{}, extra \\ %{}) do
    room_with_levels(a, [b, c, d], levels(Map.merge(%{a.uid => 100, b.uid => 50}, users), extra))
  end

  # the stored content with `changes` merged over it (what Element does: the full current content with one change)
  defp changed(room, changes), do: Map.merge(column(room), changes)

  defp with_user(room, uid, level), do: update_in(column(room), ["users"], &Map.put(&1, uid, level))

  defp ghost(label), do: "@#{label}#{T.rand(4)}:#{T.server_name()}"

  defp limited_conn!(conn, label) do
    assert conn.status == 429, "#{label}: expected 429, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert body["errcode"] == "M_LIMIT_EXCEEDED", "#{label}: #{conn.resp_body}"
    assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || ""), "#{label}: Retry-After must be an integer"
    assert secs >= 1
    # `retry_after_ms` is optional (the spec says SHOULD): when it is there it agrees with the header, it is never the only signal
    if Map.has_key?(body, "retry_after_ms"), do: assert(body["retry_after_ms"] == secs * 1000)
    conn
  end

  defp tight_tier!(rate, burst) do
    Application.put_env(:nebu_http, :rate_limit_moderation_per_min, rate)
    Application.put_env(:nebu_http, :rate_limit_moderation_burst, burst)
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp upgrade!(user, room) do
    conn = upgrade(user, room)
    assert conn.status == 200, "upgrade: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["replacement_room"]
  end

  defp events_of(room, type) do
    T.sql!("SELECT event_id, sender, state_key, content, origin_server_ts FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id", [room, type]).rows
    |> Enum.map(fn [id, sender, key, content, ts] -> %{event_id: id, sender: sender, state_key: key, content: content_of(content), ts: ts} end)
  end

  # the events of a room in INSERTION order (the transaction id of the row: every event is its own transaction): `[{type, state_key, membership | nil}]`
  defp insertion_order(room) do
    T.sql!("SELECT event_type, state_key, content FROM events WHERE room_id = $1 ORDER BY xmin::text::bigint, ctid", [room]).rows
    |> Enum.map(fn [type, key, content] -> {type, key, content_of(content)["membership"]} end)
  end

  defp creates_by(user), do: T.sql!("SELECT count(*) FROM events WHERE sender = $1 AND event_type = 'm.room.create'", [user.uid]).rows |> hd() |> hd()

  defp room_of_create(conn), do: T.json(conn)["room_id"]

  defp pl_entry(content), do: %{"type" => @pl, "state_key" => "", "content" => content}

  defp new_room!(owner, body) do
    conn = create(owner, body)
    assert conn.status == 200, "createRoom: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"
    room_of_create(conn)
  end

  # ═══ AC1 (a): the route ════════════════════════════════════════════════════════

  describe "AC1 (a) - PUT .../state/m.room.power_levels by a member with the required level" do
    test "answers 200 {event_id}; /sync carries the new content, the sender, the new event id, prev_content and replaces_state", %{a: a} do
      room = public_room(a)
      before = latest_pl(room)
      new = changed(room, %{"events_default" => 10})

      id = ok_event_id!(put_pl(a, room, new))

      assert latest_pl(room).event_id == id
      assert latest_pl(room).content == new
      ev = sync_pl(a, room)
      assert ev["content"] == new
      assert ev["sender"] == a.uid
      assert ev["event_id"] == id
      assert get_in(ev, ["unsigned", "prev_content"]) == before.content, "unsigned.prev_content is the previous content"
      assert get_in(ev, ["unsigned", "replaces_state"]) == before.event_id, "unsigned.replaces_state is the previous event id"
      assert_agree(room)
    end

    test "the empty key written out (.../m.room.power_levels/, what Element sends) answers 200 with the same effect", %{a: a} do
      room = public_room(a)
      new = changed(room, %{"events_default" => 20})

      id = ok_event_id!(put_pl_slash(a, room, new))

      assert latest_pl(room).event_id == id
      assert column(room) == new
      assert memory(room) == new
    end
  end

  # ═══ AC1 (b): the order, first failure wins, nothing written ═══════════════════════

  describe "AC1 (b) - first failure wins, each case writes nothing" do
    test "an empty `moderation` bucket answers 429 with Retry-After even for a malformed body", %{a: a} do
      room = public_room(a)
      tight_tier!(1, 2)
      seed("moderation", a, 0)

      conn = unchanged(room, fn -> put_raw(a, pl_path(room), "{bad json") end)

      limited_conn!(conn, "PUT with an empty bucket")
    end

    test "a non-JSON body keeps its answer: 400 M_BAD_JSON, text of the existing PUT state path", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_raw(a, pl_path(room), "{bad json") end)
      assert_refused(conn, 400, "M_BAD_JSON", "Request body is not valid JSON")
    end

    test "a NUL in the content keeps its answer: 400 M_BAD_JSON", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_raw(a, pl_path(room), ~s({"x_custom": "a\\u0000b"})) end)
      assert_refused(conn, 400, "M_BAD_JSON", "State event content must not contain NUL characters")
    end

    test "a content nested more than 32 levels keeps its answer: 400 M_BAD_JSON", %{a: a} do
      room = public_room(a)
      deep = Enum.reduce(1..40, %{}, fn _, acc -> %{"n" => acc} end)
      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"x_deep" => deep})) end)
      assert_refused(conn, 400, "M_BAD_JSON", "State event content is nested too deeply")
    end

    test "a state key above 255 bytes keeps its answer: 413 M_TOO_LARGE (before the state key rule)", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl_key(a, room, String.duplicate("k", 256), column(room)) end)
      assert_refused(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:state_key_too_long))
    end

    test "an event above 65 536 canonical bytes keeps its answer: 413 M_TOO_LARGE", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"x_big" => String.duplicate("z", 70_000)})) end)
      assert_refused(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:event_too_large))
    end

    test "a non-empty state key answers 400 M_BAD_JSON \"m.room.power_levels requires an empty state key\"", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl_key(a, room, "x", column(room)) end)
      assert_refused(conn, 400, "M_BAD_JSON", @empty_key, ["x"])
    end

    shape_cases = [
      {"ban is the string 50", %{"ban" => "50"}, @int_text},
      {"kick is the float 50.0", %{"kick" => 50.0}, @int_text},
      {"invite is a boolean", %{"invite" => true}, @int_text},
      {"redact is null", %{"redact" => nil}, nil},
      {"state_default is 2^53", %{"state_default" => @max_level + 1}, @int_text},
      {"events_default is minus 2^53", %{"events_default" => -@max_level - 1}, @int_text},
      {"users_default is a list", %{"users_default" => [1]}, @int_text},
      {"events is not an object", %{"events" => "x"}, "events must be an object"},
      {"an events value is the string \"0\"", %{"events" => %{"m.room.name" => "0"}}, @int_text},
      {"an events key is empty", %{"events" => %{"" => 5}}, "events keys must be non-empty event types of at most 255 bytes"},
      {"an events key has 256 bytes", %{"events" => %{String.duplicate("e", 256) => 5}}, "events keys must be non-empty event types of at most 255 bytes"},
      {"users is not an object", %{"users" => "x"}, "users must be an object"},
      {"a users key is \"alice\"", %{"users" => %{"alice" => 5}}, "users keys must be valid user ids"},
      {"a users key is \"@bad id\"", %{"users" => %{"@bad id" => 5}}, "users keys must be valid user ids"},
      {"a users key has 256 bytes", %{"users" => %{("@" <> String.duplicate("u", 250) <> ":" <> "test.local") => 5}}, "users keys must be valid user ids"},
      {"a users value is the string \"100\"", %{"users" => %{"@x:test.local" => "100"}}, @int_text},
      {"notifications.room is the string \"50\"", %{"notifications" => %{"room" => "50"}}, @int_text}
    ]

    for {label, change, text} <- shape_cases do
      test "D3 shape: #{label} is 400 M_BAD_JSON with a fixed text, nothing written", %{a: a} do
        room = public_room(a)
        conn = unchanged(room, fn -> put_pl(a, room, changed(room, unquote(Macro.escape(change)))) end)
        body = assert_err(conn, 400, "M_BAD_JSON", unquote(text))
        assert is_binary(body["error"])
        refute_echo(conn, ["alice", "@bad id", String.duplicate("u", 250), String.duplicate("e", 256)])
      end
    end

    test "a user who never joined the room is 403 M_FORBIDDEN \"You are not a member of this room\"", %{a: a, d: d} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(d, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "a user who left the room is 403 \"You are not a member of this room\"", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      assert leave(b, room).status == 200
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "a banned user is 403 \"You are not a member of this room\"", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      ok!(ban(a, room, b), "setup ban")
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "an invited (not joined) user is 403 \"You are not a member of this room\"", %{a: a, c: c} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, c)
      conn = unchanged(room, fn -> put_pl(c, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "a member below the required level is 403 \"You do not have a high enough power level to change the power levels\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(c, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
    end

    test "D2 order: a non-member with an INVALID body gets the membership refusal (403), not the shape error (400)", %{a: a, d: d} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(d, room, changed(room, %{"ban" => "x"})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "D2 order: a member below the required level with an INVALID body gets the level refusal (403), not the shape error (400)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(c, room, changed(room, %{"ban" => "x", "users" => %{"alice" => 1}})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
    end

    test "an unknown room id answers what PUT state answers today (403 M_FORBIDDEN, the generic text) and creates no rooms row, no room process", %{a: a} do
      unknown = "!pl#{T.rand(6)}:#{T.server_name()}"
      conn = put_pl(a, unknown, %{"events_default" => 5})
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
      assert rooms_row_count(unknown) == 0, "no rooms row is created for an unknown room"
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(unknown) == {:error, :not_found}, "no room process is started"
    end
  end

  describe "AC1 (c) - the error bodies" do
    test "are exactly {errcode, error}, the texts are fixed and no client value (room id, user id, event type, marker) is echoed", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      marker = marker("echo")
      target = ghost("echo")
      unknown_type = "m.pl.#{T.rand(5)}"

      refusals = [
        {put_pl(b, room, changed(room, %{"x_custom" => marker, "ban" => 51})), 403},
        {put_pl(b, room, changed(room, %{"users" => Map.put(column(room)["users"], target, 51)})), 403},
        {put_pl(c, room, changed(room, %{"x_custom" => marker})), 403},
        {put_pl(b, room, changed(room, %{"events" => %{unknown_type => "x"}})), 400},
        {put_pl(b, room, changed(room, %{"users" => %{(target <> " x") => 5}})), 400}
      ]

      for {conn, status} <- refusals do
        assert conn.status == status, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert Enum.sort(Map.keys(T.json(conn))) == ["errcode", "error"]
        refute_echo(conn, [room, a.uid, b.uid, c.uid, marker, target, unknown_type])
      end
    end
  end

  # ═══ AC2: the v10 change rules, each case its own test ════════════════════════════

  describe "AC2 (a) - the seven integer keys (sender b at 50, the levels event needs 50)" do
    test "raising `ban` from 50 to 51 is 403 \"You cannot grant a power level above your own\", nothing written", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"ban" => 51})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
    end

    test "lowering `kick` from 50 to 0 is 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(b, room, changed(room, %{"kick" => 0})))
      assert column(room)["kick"] == 0
      assert_agree(room)
    end

    test "changing `state_default` whose CURRENT value is 75 is 403 \"You cannot change a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"state_default" => 75})
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"state_default" => 60})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @above_own)
    end

    test "removing a key whose current value is 75 is 403 \"You cannot change a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"kick" => 75})
      conn = unchanged(room, fn -> put_pl(b, room, Map.delete(column(room), "kick")) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @above_own)
    end

    test "adding a key that was absent with the default value (`redact`: 50) is 200 (an alteration within the level)", %{a: a, b: b, c: c, d: d} do
      room = room_with_levels(a, [b, c, d], Map.delete(levels(%{a.uid => 100, b.uid => 50}), "redact"))
      refute Map.has_key?(column(room), "redact")
      ok_event_id!(put_pl(b, room, changed(room, %{"redact" => 50})))
      assert column(room)["redact"] == 50
    end
  end

  describe "AC2 (b) - the `events` map" do
    test "adding \"m.room.topic\": 50 is 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(b, room, update_in(column(room), ["events"], &Map.put(&1, "m.room.topic", 50))))
      assert column(room)["events"]["m.room.topic"] == 50
    end

    test "adding \"m.room.topic\": 51 is 403 \"You cannot grant a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(b, room, update_in(column(room), ["events"], &Map.put(&1, "m.room.topic", 51))) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
    end

    test "changing an entry whose current value is 100 is 403 \"You cannot change a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.history_visibility" => 100}})
      conn = unchanged(room, fn -> put_pl(b, room, update_in(column(room), ["events"], &Map.put(&1, "m.room.history_visibility", 50))) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @above_own)
    end
  end

  describe "AC2 (c) - the `users` map (b at 50, c and d at 50 and 49)" do
    setup %{a: a, b: b, c: c, d: d} do
      {:ok, room: fifty_room(a, b, c, d, %{c.uid => 50, d.uid => 49})}
    end

    test "adding a user at 50 is 200", %{b: b, room: room} do
      ok_event_id!(put_pl(b, room, with_user(room, ghost("new"), 50)))
    end

    test "adding a user at 51 is 403 \"You cannot grant a power level above your own\"", %{b: b, room: room} do
      conn = unchanged(room, fn -> put_pl(b, room, with_user(room, ghost("new"), 51)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
    end

    test "changing a user whose level equals the sender's (50) is 403 \"...whose level is not lower than yours\"", %{b: b, c: c, room: room} do
      conn = unchanged(room, fn -> put_pl(b, room, with_user(room, c.uid, 10)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end

    test "removing a user whose level equals the sender's (50) is 403 \"...whose level is not lower than yours\"", %{b: b, c: c, room: room} do
      conn = unchanged(room, fn -> put_pl(b, room, update_in(column(room), ["users"], &Map.delete(&1, c.uid))) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end

    test "changing a user at 49 (below the sender) is 200", %{b: b, d: d, room: room} do
      ok_event_id!(put_pl(b, room, with_user(room, d.uid, 10)))
      assert column(room)["users"][d.uid] == 10
    end
  end

  describe "AC2 (c) (HTTP) - rule 7 against a user ABOVE the sender (b at 50, c at 75)" do
    test "changing the user at 75 is 403 \"...whose level is not lower than yours\", nothing written", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 75})
      conn = unchanged(room, fn -> put_pl(b, room, with_user(room, c.uid, 10)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end

    test "removing the user at 75 is 403 \"...whose level is not lower than yours\", nothing written", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 75})
      conn = unchanged(room, fn -> put_pl(b, room, update_in(column(room), ["users"], &Map.delete(&1, c.uid))) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end
  end

  describe "AC2 (d) - the sender's own entry" do
    test "lowering his own 50 to 10 is 200, and his next change is refused (he is below the level)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(b, room, with_user(room, b.uid, 10)))
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"events_default" => 5})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
    end

    test "removing his own entry is 200 (he falls to users_default)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(b, room, update_in(column(room), ["users"], &Map.delete(&1, b.uid))))
      refute Map.has_key?(column(room)["users"], b.uid)
      assert call(PowerLevels, :get_user_level, [memory(room), b.uid]) == 0
    end

    test "raising his own entry to 51 is 403 \"You cannot grant a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(b, room, with_user(room, b.uid, 51)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
    end
  end

  describe "AC2 (e) - notifications are treated like events" do
    test "adding notifications.room 50 is 200, 51 is 403 \"...grant...\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"notifications" => %{"room" => 51}})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
      ok_event_id!(put_pl(b, room, changed(room, %{"notifications" => %{"room" => 50}})))
      assert column(room)["notifications"] == %{"room" => 50}
    end

    test "changing a notifications entry whose current value is 100 is 403 \"You cannot change a power level above your own\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"notifications" => %{"room" => 100}})
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"notifications" => %{"room" => 50}})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @above_own)
    end
  end

  describe "AC2 (f) - replacing the whole content with {} (sender a at 100)" do
    test "while another user is at 100 it is 403 \"...whose level is not lower than yours\" (removing the other's entry)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 100})
      conn = unchanged(room, fn -> put_pl(a, room, %{}) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end

    test "with only lower users it is 200: the content is {}, readers see the defaults and EVERY further PUT is 403 (locked, spec-conformant)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(a, room, %{}))

      assert column(room) == %{}
      assert memory(room) == %{}
      assert call(PowerLevels, :get_user_level, [memory(room), a.uid]) == 0, "everybody is at the default level"
      refute PowerLevels.can?(memory(room), a.uid, :change_state), "nobody reaches state_default 50"

      for sender <- [a, b, c, d], content <- [%{}, %{"events_default" => 5}] do
        conn = unchanged(room, fn -> put_pl(sender, room, content) end)
        assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
      end

      assert_agree(room)
    end
  end

  describe "AC2 (g) - trusted_private_chat: both partners are at 100" do
    test "partner A cannot change partner B's entry (403) but can change events_default to 100 (200)", %{a: a, b: b} do
      # fix cycle 2 (review MINOR-3): no `invite_room/3` (its join!/2 waits in the global tick/0, a flake under a full run; this test
      # needs no sync token): createRoom invites b, b joins (the server stamps the member events strictly after each other)
      room = make_room(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid]})
      join_now!(b, room)
      assert column(room)["users"][b.uid] == 100

      conn = unchanged(room, fn -> put_pl(a, room, with_user(room, b.uid, 50)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)

      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 100})))
      assert column(room)["events_default"] == 100
      assert column(room)["users"][b.uid] == 100
    end
  end

  describe "AC2 (h) - the boundaries of the integer range" do
    test "2^53 - 1 passes the shape check and is then refused by the grant rule for a sender below it (403, not 400)", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"users_default" => @max_level})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
    end

    test "-(2^53 - 1) passes the shape check and is accepted (a negative value is never above the sender)", %{a: a} do
      room = public_room(a)
      ok_event_id!(put_pl(a, room, changed(room, %{"users_default" => -@max_level})))
      assert column(room)["users_default"] == -@max_level
    end

    test "2^53 - 1 is accepted from a sender who stands at 2^53 - 1", %{a: a} do
      room = public_room(a)
      seed!(room, a, levels(%{a.uid => @max_level}))
      ok_event_id!(put_pl(a, room, changed(room, %{"users_default" => @max_level})))
      assert column(room)["users_default"] == @max_level
    end
  end

  # ═══ AC3: the idempotent no-op ═════════════════════════════════════════════════

  describe "AC3 - PUT of the current content is an idempotent 200 with the CURRENT event id" do
    test "no new event, no audit row, no broadcast; a real change IS delivered (positive control)", %{a: a} do
      room = public_room(a)
      :ok = :pg.join("room:#{room}", self())
      current_id = latest_pl(room).event_id
      before = pl_footprint(room)
      flush_events()

      id = ok_event_id!(put_pl(a, room, column(room)), "identical content")

      assert id == current_id, "the CURRENT event id is answered"
      assert pl_footprint(room) == before
      refute_receive {:new_event, _}, 100

      real_id = ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 7})), "positive control")
      assert real_id != current_id
      assert_receive {:new_event, %{"type" => @pl, "event_id" => ^real_id}}, 2_000
    end

    test "content equal up to key order counts as identical (the reversed JSON text)", %{a: a} do
      room = public_room(a)
      current_id = latest_pl(room).event_id
      before = pl_footprint(room)

      body = "{" <> (column(room) |> Map.to_list() |> Enum.reverse() |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> Jason.encode!(v) end)) <> "}"

      assert ok_event_id!(put_raw(a, pl_path(room), body)) == current_id
      assert pl_footprint(room) == before
    end

    test "a content that differs only by an absent key vs. a key at its default is NOT identical: a new event and an audit row", %{a: a} do
      room = public_room(a)
      seed!(room, a, Map.delete(levels(%{a.uid => 100}), "redact"))
      before_id = latest_pl(room).event_id
      before_events = event_count(room)

      id = ok_event_id!(put_pl(a, room, changed(room, %{"redact" => 50})))

      assert id != before_id
      assert event_count(room) == before_events + 1
      assert [%{metadata: %{"changed_keys" => ["redact"]}}] = pl_audit(room)
    end
  end

  # ═══ AC4: enforcement of `events` ═══════════════════════════════════════════════

  describe "AC4 (a) - /send follows events[type] / events_default" do
    test "events[m.room.message]: 50: a user at 0 is 403 (nothing written), at 50 it is 200; another message type stays at events_default", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.message" => 50}})
      before = event_count(room)

      conn = text_message(c, room)
      assert_refused(conn, 403, "M_FORBIDDEN", @send_text)
      assert event_count(room) == before, "the refused send wrote nothing"

      assert conn_ok?(text_message(b, room))
      assert conn_ok?(send_event(c, room, "m.custom", %{"x" => 1})), "another message type stays at events_default"
    end

    test "with events_default 10 and events[m.custom]: 0 a user at 0 sends m.custom (200) but not m.room.message (403)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events_default" => 10, "events" => %{@pl => 50, "m.custom" => 0}})
      before = event_count(room)

      assert conn_ok?(send_event(c, room, "m.custom", %{"x" => 1}))
      assert_refused(text_message(c, room), 403, "M_FORBIDDEN", @send_text)
      assert event_count(room) == before + 1
    end

    test "/send of m.room.redaction follows events[m.room.redaction] (50: a user at 0 is 403, a user at 50 is 200)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.redaction" => 50}})
      target = say!(a, room, marker("target"))

      before = event_count(room)
      assert_refused(send_event(c, room, "m.room.redaction", %{"redacts" => target}), 403, "M_FORBIDDEN", @send_text)
      assert event_count(room) == before, "the refused redaction wrote nothing"
      assert conn_ok?(send_event(b, room, "m.room.redaction", %{"redacts" => target}))
    end

    test "/send of m.room.redaction without an entry follows events_default (10: a user at 0 is 403)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events_default" => 10})
      target = say!(a, room, marker("target"))
      before = event_count(room)
      assert_refused(send_event(c, room, "m.room.redaction", %{"redacts" => target}), 403, "M_FORBIDDEN", @send_text)
      assert event_count(room) == before, "the refused redaction wrote nothing"
      assert conn_ok?(send_event(b, room, "m.room.redaction", %{"redacts" => target}))
    end
  end

  describe "AC4 (b) - PUT state follows events[type], else state_default" do
    test "with events[m.room.topic]: 100 a user at 50 (= state_default) is 403 \"...to set this state\" (nothing written), the owner at 100 is 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.topic" => 100}})
      before = event_count(room)

      assert_refused(put_state(b, room, "m.room.topic", %{"topic" => "t"}), 403, "M_FORBIDDEN", @state_text)
      assert event_count(room) == before

      assert conn_ok?(put_state(a, room, "m.room.topic", %{"topic" => "t"}))
    end

    test "with events[m.room.name]: 0 a user at 0 is 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.name" => 0}})
      assert conn_ok?(put_state(c, room, "m.room.name", %{"name" => "by c"}))
    end

    test "a type without an entry needs state_default: a user at 0 is 403, a user at 50 is 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      assert_refused(put_state(c, room, "m.room.topic", %{"topic" => "t"}), 403, "M_FORBIDDEN", @state_text)
      assert conn_ok?(put_state(b, room, "m.room.topic", %{"topic" => "t"}))
    end
  end

  describe "AC4 (c) - the generic rule: a state key that starts with @ must be the sender's own id" do
    test "PUT m.room.name with another user's id as state key is 403 (the D5 (c) text), nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      conn = put_state_key(a, room, "m.room.name", "@other:" <> T.server_name(), %{"name" => "x"})
      assert_refused(conn, 403, "M_FORBIDDEN", @at_text)
      assert event_count(room) == before
    end

    test "with the sender's own id the request passes this rule (200)", %{a: a} do
      room = public_room(a)
      assert conn_ok?(put_state_key(a, room, "m.room.name", a.uid, %{"name" => "own key"}))
    end
  end

  describe "AC4 (e) - member events are not governed by events" do
    test "events[m.room.member]: 100 blocks neither a join, nor an invite, nor a kick decided by the membership rules", %{a: a, b: b, c: c} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}, %{"events" => %{@pl => 50, "m.room.member" => 100}}))

      assert join(c, room).status == 200, "a join"
      invitee = user!("PLE")
      assert invite(b, room, invitee).status == 200, "an invite by a user at the invite level"
      ok!(kick(b, room, c), "a kick by a user at the kick level")
    end
  end

  # ═══ AC5 (b), (c): integers, tolerant read, real DB ═════════════════════════════

  describe "AC5 (b) - legacy content in the column (strings): the normalised view decides" do
    setup %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      for u <- [b, c, d], do: join_now!(u, room)

      legacy = %{
        "ban" => "0",
        "kick" => 50,
        "invite" => 0,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => "5",
        "users" => %{a.uid => 100, b.uid => "100", c.uid => 70},
        "events" => %{"m.room.name" => "0"}
      }

      set_column!(room, Jason.encode!(legacy))
      kill_and_restart!(room)
      {:ok, room: room, legacy: legacy}
    end

    test "a user whose stored level is the string \"100\" cannot kick, ban, change state or upgrade (403), and nothing is written", %{a: a, b: b, d: d, room: room} do
      footprint_before = {event_count(room), memberships(room, d.uid)}

      unchanged(room, fn ->
        assert_refused(kick(b, room, d), 403, "M_FORBIDDEN", "You do not have a high enough power level to kick from this room.")
        assert_refused(ban(b, room, d), 403, "M_FORBIDDEN", "You do not have a high enough power level to ban from this room.")
        assert_refused(put_state(b, room, "m.room.topic", %{"topic" => "t"}), 403, "M_FORBIDDEN", @state_text)
        assert upgrade(b, room).status == 403
      end)

      assert {event_count(room), memberships(room, d.uid)} == footprint_before, "no ban / kick / topic event"
      assert in_set?(room, d.uid), "d is still a member"
      assert events_of(room, "m.room.tombstone") == [], "the refused upgrade left no tombstone"
      assert T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows == [["active"]], "the room stays active"
      assert memory(room)["users"][a.uid] == 100
    end

    test "the room keeps working with the spec defaults: d (no entry, a string users_default) cannot set state, c (a valid 70) bans", %{c: c, d: d, room: room} do
      assert_refused(put_state(d, room, "m.room.topic", %{"topic" => "t"}), 403, "M_FORBIDDEN", @state_text)
      ok!(ban(c, room, d), "ban by a user whose stored level is valid")
    end

    test "a valid PUT by a user who reaches the normalised levels replaces the content: afterwards the stored content is strictly valid", %{a: a, legacy: legacy, room: room} do
      new = levels(%{a.uid => 100})
      ok_event_id!(put_pl(a, room, new))
      assert column(room) == new
      assert call(PowerLevels, :validate_content, [column(room)]) == :ok
      assert column(room) != legacy
    end
  end

  describe "AC5 (c) - a room whose content is {}" do
    test "every PUT is 403 (nobody reaches state_default 50: D4 (c))", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      set_column!(room, "{}")
      kill_and_restart!(room)

      for sender <- [a, b] do
        conn = unchanged(room, fn -> put_pl(sender, room, levels(%{a.uid => 100})) end)
        assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
      end
    end
  end

  # ═══ AC9: createRoom initial_state ═════════════════════════════════════════════

  describe "AC9 (a) - an initial_state m.room.power_levels entry is applied at step 6" do
    test "the room's levels equal the entry EXACTLY, the event comes after the step-3 event and the preset events and before m.room.name", %{a: a} do
      content = levels(%{a.uid => 100}, %{"events_default" => 10, "events" => %{@pl => 100}})

      log =
        capture_log(fn ->
          room = new_room!(a, %{"preset" => "public_chat", "name" => "pl-order", "initial_state" => [pl_entry(content)]})
          send(self(), {:room, room})
        end)

      assert_received {:room, room}
      assert column(room) == content, "no merge with the defaults or the override"
      assert memory(room) == content
      assert latest_pl(room).content == content

      assert [step3, entry] = pl_events(room)
      assert step3.ts < entry.ts, "the entry is a NEW event after the step-3 event"

      ts_of = fn type -> room |> events_of(type) |> List.last() |> Map.fetch!(:ts) end
      for type <- ~w(m.room.join_rules m.room.history_visibility m.room.guest_access), do: assert(ts_of.(type) < entry.ts, "#{type} precedes the entry")
      assert entry.ts < ts_of.("m.room.name"), "the entry precedes m.room.name"
      refute log =~ ~s(forbidden type "m.room.power_levels"), "the 'skipped' warning is gone for this type"
    end

    test "the warning for the five other skipped types stays (positive control of the log check)", %{a: a} do
      log =
        capture_log(fn ->
          new_room!(a, %{"preset" => "public_chat", "initial_state" => [%{"type" => "m.room.create", "state_key" => "", "content" => %{}}]})
        end)

      assert log =~ ~s(forbidden type "m.room.create")
    end
  end

  describe "AC9 (b) - two entries" do
    test "the later wins, each is a separate event in list order", %{a: a} do
      c1 = levels(%{a.uid => 100}, %{"events_default" => 10})
      c2 = levels(%{a.uid => 100}, %{"events_default" => 20})
      room = new_room!(a, %{"preset" => "public_chat", "initial_state" => [pl_entry(c1), pl_entry(c2)]})

      assert [_step3, first, second] = pl_events(room)
      assert first.content == c1 and second.content == c2
      assert first.ts < second.ts
      assert column(room) == c2
    end
  end

  describe "AC9 (c) - validation and the creator" do
    test "an entry granting a user 101 (the creator at 100) is 400 M_INVALID_ROOM_STATE \"The initial power levels cannot grant more than the room creator has\" and no room exists", %{a: a} do
      entry = pl_entry(levels(%{a.uid => 100, ghost("hi") => 101}))
      conn = create(a, %{"preset" => "public_chat", "initial_state" => [entry]})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", @grant_initial_text)
      assert creates_by(a) == 0, "no room exists"
    end

    test "an entry that drops the creator to 0 while a name is given is 400 M_INVALID_ROOM_STATE (the lock-out text), no room", %{a: a} do
      entry = pl_entry(%{"users" => %{a.uid => 0}})
      conn = create(a, %{"preset" => "public_chat", "name" => "locked", "initial_state" => [entry]})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", @lock_out_text)
      assert creates_by(a) == 0
    end

    test "an entry without the creator but with users_default 100 is 200 and applied exactly", %{a: a} do
      room = new_room!(a, %{"preset" => "public_chat", "initial_state" => [pl_entry(%{"users_default" => 100})]})
      assert column(room) == %{"users_default" => 100}
    end

    test "an entry with a string level is 400 M_BAD_JSON, no room", %{a: a} do
      conn = create(a, %{"preset" => "public_chat", "initial_state" => [pl_entry(%{"users_default" => "100"})]})
      assert_refused(conn, 400, "M_BAD_JSON", @int_text)
      assert creates_by(a) == 0
    end

    test "an entry with the state key \"x\" is 400 M_BAD_JSON \"m.room.power_levels requires an empty state key\", no room", %{a: a} do
      entry = %{"type" => @pl, "state_key" => "x", "content" => levels(%{a.uid => 100})}
      conn = create(a, %{"preset" => "public_chat", "initial_state" => [entry]})
      assert_refused(conn, 400, "M_BAD_JSON", @empty_key)
      assert creates_by(a) == 0
    end
  end

  describe "AC9 (d) - trusted_private_chat" do
    test "an entry that repeats the invitee at 100 is applied exactly, and the invite events of step 8 still pass", %{a: a, b: b} do
      content = levels(%{a.uid => 100, b.uid => 100}, %{"events_default" => 10})
      room = new_room!(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid], "initial_state" => [pl_entry(content)]})
      assert column(room) == content
      assert memberships(room, b.uid) == ["invite"], "the invite event of step 8 was written"
    end

    test "an entry that omits the invitee (his step-3 level 100 is not below the creator's 100) is 400 M_INVALID_ROOM_STATE by the v10 change rules, no room", %{a: a, b: b} do
      entry = pl_entry(levels(%{a.uid => 100}))
      conn = create(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid], "initial_state" => [entry]})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", @grant_initial_text)
      assert creates_by(a) == 0
    end
  end

  describe "AC9 (e), (f) - the entry wins over the override and does not suppress a preset event" do
    test "an entry plus power_level_content_override: the entry wins (step 6 after step 3)", %{a: a} do
      override = %{"users" => %{a.uid => 100, ghost("ov") => 50}, "events_default" => 30}
      entry = levels(%{a.uid => 100}, %{"events_default" => 10})
      room = new_room!(a, %{"preset" => "public_chat", "power_level_content_override" => override, "initial_state" => [pl_entry(entry)]})
      assert column(room) == entry
      assert [step3, _entry] = pl_events(room)
      assert step3.content["events_default"] == 30
    end

    test "the entry does not suppress a preset event: join_rules, history_visibility and guest_access are written", %{a: a} do
      room = new_room!(a, %{"preset" => "public_chat", "initial_state" => [pl_entry(levels(%{a.uid => 100}))]})
      for type <- ~w(m.room.join_rules m.room.history_visibility m.room.guest_access), do: assert(length(events_of(room, type)) == 1, "#{type} was written")
    end
  end

  # ═══ AC10: the upgrade carries the levels ═══════════════════════════════════════

  describe "AC10 (a) - the levels are carried, the bans first" do
    test "bans of two users (one listed at 100) before the copied levels and the join rule, final levels equal the old content, banned users cannot join", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      for u <- [b, c, d], do: join_now!(u, room)
      ok!(ban(a, room, c), "ban c")
      ok!(ban(a, room, d), "ban d")
      # legacy: a banned user listed at 100 (set by a seed AFTER the ban: a ban of a user at 100 is refused)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50, c.uid => 100}, %{"events" => %{@pl => 100, "m.room.topic" => 75}}))
      old = column(room)

      new_room = upgrade!(a, room)

      final = column(new_room)
      assert final["users"] == old["users"]
      assert final["events"] == old["events"]
      assert call(PowerLevels, :normalize, [final]) == call(PowerLevels, :normalize, [old])
      assert memory(new_room) == final
      assert_agree(new_room)

      order = insertion_order(new_room)
      idx = fn pred -> Enum.find_index(order, pred) end
      create_at = idx.(&match?({"m.room.create", _, _}, &1))
      join_at = idx.(&match?({"m.room.member", _, "join"}, &1))
      first_pl = idx.(&match?({@pl, _, _}, &1))
      ban_ats = for {{"m.room.member", _, "ban"}, i} <- Enum.with_index(order), do: i
      last_pl = order |> Enum.with_index() |> Enum.filter(&match?({{@pl, _, _}, _}, &1)) |> List.last() |> elem(1)
      rules_at = idx.(&match?({"m.room.join_rules", _, _}, &1))

      assert length(ban_ats) == 2
      assert create_at < join_at and join_at < first_pl, "create, creator join, initial levels"
      assert Enum.all?(ban_ats, &(&1 > first_pl)), "the bans follow the creator join and the initial levels event"
      assert Enum.all?(ban_ats, &(&1 < last_pl)), "the bans are written BEFORE the copied levels event"
      assert last_pl < rules_at, "the copied levels precede the copied join rule"

      assert_err(join(c, new_room), 403, "M_FORBIDDEN", "You are banned from this room")
      assert_err(join(d, new_room), 403, "M_FORBIDDEN", "You are banned from this room")
    end
  end

  describe "AC10 (b) - a level above the upgrader's" do
    test "a user at 150 (upgrader at 100) is 403 \"The room has power levels above yours\" BEFORE the tombstone: no tombstone, no new room, old room active", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 150}, %{"events" => %{@pl => 100}}))
      creates = creates_by(a)

      conn = unchanged(room, fn -> upgrade(a, room) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @upgrade_above_text)
      assert events_of(room, "m.room.tombstone") == [], "no tombstone"
      assert creates_by(a) == creates, "no new room"
      assert T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows == [["active"]], "the old room is not archived"
    end
  end

  describe "AC10 (c), (d), (e) - the authoritative read, legacy content, a failing copy" do
    test "a change committed between the snapshot and the freeze (a deterministic hook) is the one carried", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      install_env!(:event_dispatcher, :admin_db_module, Hooks.AdminDB)
      on_exit(&Hooks.disarm_before_archive/0)
      Hooks.arm_before_archive(room, fn -> ok_event_id!(put_pl(a, room, with_user(room, b.uid, 75)), "the change in the gap") end)

      new_room = upgrade!(a, room)

      assert column(room)["users"][b.uid] == 75
      assert column(new_room)["users"][b.uid] == 75, "the change committed before the freeze is carried"
    end

    test "a level above the upgrader's committed before the freeze is 500 (post-freeze): old room archived, nothing above 100 carried, audited", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      install_env!(:event_dispatcher, :admin_db_module, Hooks.AdminDB)
      on_exit(&Hooks.disarm_before_archive/0)
      Hooks.arm_before_archive(room, fn -> seed!(room, a, levels(%{a.uid => 100, b.uid => 150}, %{"events" => %{@pl => 100}})) end)

      conn = upgrade(a, room)

      assert_err(conn, 500, "M_UNKNOWN")
      refute conn.resp_body =~ b.uid, "no user id in the answer"
      assert length(events_of(room, "m.room.tombstone")) == 1, "the tombstone was written before the freeze"
      assert T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows == [["archived"]], "the old room is frozen"
      assert [%{metadata: metadata, outcome: "failure"}] = upgrade_audit(room)
      new_room = metadata["new_room_id"]
      assert is_binary(new_room)
      # the check runs right after the freeze, before the new room is filled: its stored levels hold no level above 100 (an empty content is fine)
      levels_in_new_room = new_room |> column() |> Map.get("users", %{}) |> Map.values()
      assert Enum.all?(levels_in_new_room, &(&1 <= 100)), "the new room never holds a level above the upgrader's: #{inspect(levels_in_new_room)}"
      assert Enum.all?(pl_events(new_room), fn ev -> Enum.all?(Map.values(ev.content["users"] || %{}), &(&1 <= 100)) end)
      assert events_of(new_room, "m.room.join_rules") == [], "nothing was copied into the new room"
    end

    test "legacy odd content is carried normalised: a string users value is dropped, a string ban reads as its default, the copy passes the shape check", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join_now!(u, room)

      legacy = %{
        "ban" => "0",
        "kick" => 50,
        "invite" => 0,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => 0,
        "users" => %{a.uid => 100, b.uid => "100", c.uid => 40},
        "events" => %{@pl => 100}
      }

      set_column!(room, Jason.encode!(legacy))
      kill_and_restart!(room)

      new_room = upgrade!(a, room)

      final = column(new_room)
      assert call(PowerLevels, :validate_content, [final]) == :ok
      refute Map.has_key?(final["users"], b.uid), "the string level is not carried"
      assert final["users"][c.uid] == 40
      assert final["ban"] in [nil, 50], "a string ban reads as its default"
      assert Enum.all?(Map.values(final["users"]), &is_integer/1)
    end

    test "a failing copy fails the upgrade with 500: the new room has no join rule and no invitation, the failure is audited", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      # a content that differs from the initial levels of the new room, so that the copy is a real write (identical content is a no-op)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 50}))
      install_room_db!(Hooks.RoomDB)
      on_exit(&Hooks.disarm_db/0)
      # the first write in the new room (the initial levels) passes, the second one (the copy) fails
      Hooks.arm_db(%{fail_after: 1, except: room, ref: :counters.new(1, [])})

      conn = upgrade(a, room)

      assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert [%{metadata: metadata, outcome: "failure"}] = upgrade_audit(room)
      new_room = metadata["new_room_id"]
      assert is_binary(new_room)
      assert events_of(new_room, "m.room.join_rules") == [], "the new room has no join rule: nobody can join"
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [new_room]).rows == [[0]]
    end
  end

  describe "AC10 (f), (g) - the audit row and the old room" do
    test "the room_upgraded success row carries \"power_levels_carried\" => true; the old room's levels are unchanged (not lowered: archived)", %{a: a, b: b} do
      room = fifty_room(a, b, user!("PLX"), user!("PLY"))
      old_before = column(room)
      old_events = pl_events(room)

      new_room = upgrade!(a, room)

      assert [%{metadata: metadata, outcome: "success"}] = upgrade_audit(room)
      assert metadata["power_levels_carried"] == true
      assert metadata["new_room_id"] == new_room
      assert column(room) == old_before, "the old room's levels are not lowered"
      assert pl_events(room) == old_events, "no levels event was written into the old room"
      assert pl_audit(new_room) == [], "the copy is not audited as room_power_levels_changed"
      assert pl_audit(room) == []
    end
  end

  # ═══ AC11: the rate limit ═══════════════════════════════════════════════════════

  describe "AC11 - the `moderation` tier (rate_per_min 1, burst 2)" do
    setup do
      tight_tier!(1, 2)
      :ok
    end

    test "the third PUT of m.room.power_levels by the same user is 429; the first two are 200", %{a: a} do
      room = public_room(a)
      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 1})))
      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 2})))
      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"events_default" => 3})) end)
      limited_conn!(conn, "third PUT")
    end

    test "a /kick draws from the same bucket: one PUT and one kick, then the next PUT is 429", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 1})))
      ok!(kick(a, room, b), "kick")
      limited_conn!(put_pl(a, room, changed(room, %{"events_default" => 2})), "PUT after PUT + kick")
    end

    test "the bucket key is {\"moderation\", user}: one PUT costs exactly one token", %{a: a} do
      room = public_room(a)
      assert tokens("moderation", a, 2) == 2.0
      ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => 1})))
      assert tokens("moderation", a, 2) == 1.0
    end

    test "a PUT of m.room.topic is not charged: any number passes the tier", %{a: a} do
      room = public_room(a)
      seed("moderation", a, 0)
      for n <- 1..6, do: assert(conn_ok?(put_state(a, room, "m.room.topic", %{"topic" => "t#{n}"})))
      assert tokens("moderation", a, 2) == 0.0
    end

    test "another user is unaffected by an empty bucket", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 100, b.uid => 100}))
      seed("moderation", a, 0)
      limited_conn!(put_pl(a, room, changed(room, %{"events_default" => 1})), "the empty bucket")
      ok_event_id!(put_pl(b, room, changed(room, %{"events_default" => 1})), "the other user")
    end

    test "NEBU_RATE_LIMIT_DISABLED=true disables the charge", %{a: a} do
      room = public_room(a)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)
      for n <- 1..5, do: ok_event_id!(put_pl(a, room, changed(room, %{"events_default" => n})))
    end
  end

  # ═══ AC12: the audit ═══════════════════════════════════════════════════════════

  describe "AC12 - room_power_levels_changed" do
    test "a committed PUT writes exactly one row: actor, resource room, room id, success, metadata exactly changed_keys / users_changed / users_changed_count", %{a: a, c: c} do
      room = public_room(a)
      join_now!(c, room)

      ok_event_id!(put_pl(a, room, update_in(changed(room, %{"events_default" => 10}), ["users"], &Map.put(&1, c.uid, 50))))

      assert [row] = pl_audit(room)
      assert row.actor == a.uid
      assert row.action == "room_power_levels_changed"
      assert row.target_type == "room"
      assert row.target_id == room
      assert row.outcome == "success"
      assert row.metadata == %{"changed_keys" => ["events_default", "users"], "users_changed" => [c.uid], "users_changed_count" => 1}
    end

    test "60 changed users: 50 sorted ids are listed, the count is 60", %{a: a} do
      room = public_room(a)
      ids = for n <- 1..60, do: "@plmass#{String.pad_leading(Integer.to_string(n), 3, "0")}:#{T.server_name()}"
      new = update_in(column(room), ["users"], fn users -> Enum.reduce(ids, users, &Map.put(&2, &1, 10)) end)

      ok_event_id!(put_pl(a, room, new))

      assert [%{metadata: metadata}] = pl_audit(room)
      assert metadata["users_changed_count"] == 60
      assert metadata["users_changed"] == ids |> Enum.sort() |> Enum.take(50)
      assert metadata["changed_keys"] == ["users"]
    end

    test "no row for the no-op, for a refusal, for the createRoom entries and for the upgrade copy", %{a: a, c: c} do
      room = public_room(a)
      join_now!(c, room)
      ok_event_id!(put_pl(a, room, column(room)), "no-op")
      assert_refused(put_pl(c, room, changed(room, %{"events_default" => 9})), 403, "M_FORBIDDEN", @low_level)
      assert pl_audit(room) == []

      created = new_room!(a, %{"preset" => "public_chat", "initial_state" => [pl_entry(levels(%{a.uid => 100}))]})
      assert pl_audit(created) == []

      upgraded = upgrade!(a, room)
      assert pl_audit(upgraded) == []
      assert pl_audit(room) == []
    end

    test "AuditWriter.log/6 accepts the action", %{a: a} do
      assert :ok = Nebu.Compliance.AuditWriter.log(a.uid, "room_power_levels_changed", "room", "!atdd#{T.rand(4)}:#{T.server_name()}", %{"changed_keys" => []}, "success")
    end

    test "a failing audit writer does not fail the change: 200, the event is written, one value-free ERROR log that names the room only", %{a: a} do
      room = public_room(a)
      install_env!(:compliance, :audit_writer, FailingAudit)
      marker = marker("secret")

      log = capture_log(fn -> send(self(), {:id, ok_event_id!(put_pl(a, room, changed(room, %{"x_custom" => marker, "events_default" => 4})))}) end)

      assert_received {:id, id}
      assert latest_pl(room).event_id == id
      assert log =~ room, "the log line names the room"
      refute log =~ marker, "no content of the levels event in the log"
      refute log =~ "atdd: audit writer down"
    end

    test "no content of the levels event appears in any log line of a change, a refusal and a no-op", %{a: a, c: c} do
      room = public_room(a)
      join_now!(c, room)
      marker = marker("content")

      log =
        capture_log(fn ->
          ok_event_id!(put_pl(a, room, changed(room, %{"x_custom" => marker})))
          assert put_pl(c, room, changed(room, %{"x_custom" => marker <> "2"})).status == 403
          ok_event_id!(put_pl(a, room, column(room)))
          assert put_pl(a, room, changed(room, %{"users" => %{"alice" => 1}, "x_custom" => marker <> "3"})).status == 400
        end)

      refute log =~ marker
    end
  end

  # ═══ AC13: the default events map ═══════════════════════════════════════════════

  describe "AC13 (HTTP part) - the default events map of new rooms (D12, NON-SPEC, Synapse-derived)" do
    test "a new room (no override) has the eight entries in its levels event", %{a: a} do
      room = public_room(a)
      assert latest_pl(room).content["events"] == @d12_events
      assert column(room)["events"] == @d12_events
    end

    test "an override with \"events\": {} replaces them (shallow merge)", %{a: a} do
      room = new_room!(a, %{"preset" => "public_chat", "power_level_content_override" => %{"events" => %{}}})
      assert column(room)["events"] == %{}
      assert column(room)["users"][a.uid] == 100
    end

    test "a moderator at 50 in a new room cannot PUT the levels (403) nor history_visibility (403) but can PUT m.room.name (200)", %{a: a, b: b} do
      room = new_room!(a, %{"preset" => "public_chat", "power_level_content_override" => %{"users" => %{a.uid => 100, b.uid => 50}}})
      join_now!(b, room)

      assert_refused(put_pl(b, room, changed(room, %{"events_default" => 5})), 403, "M_FORBIDDEN", @low_level)
      assert_refused(put_state(b, room, "m.room.history_visibility", %{"history_visibility" => "shared"}), 403, "M_FORBIDDEN", @state_text)
      assert conn_ok?(put_state(b, room, "m.room.name", %{"name" => "renamed"}))
    end

    test "the lock-out with an override users: {creator: 50} and a preset is 400 M_INVALID_ROOM_STATE (history_visibility needs 100), no room", %{a: a} do
      conn = create(a, %{"preset" => "public_chat", "power_level_content_override" => %{"users" => %{a.uid => 50}}})
      assert_refused(conn, 400, "M_INVALID_ROOM_STATE", @lock_out_text)
      assert creates_by(a) == 0
    end
  end

  # ═══ AC17: the Oracle tests ═════════════════════════════════════════════════════

  describe "AC17 (a) - createRoom: override users {creator: 50} plus an initial_state power-levels entry" do
    test "is 400 M_INVALID_ROOM_STATE and no room exists (D7, the generic required-level rule)", %{a: a} do
      body = %{
        "preset" => "public_chat",
        "power_level_content_override" => %{"users" => %{a.uid => 50}},
        "initial_state" => [pl_entry(levels(%{a.uid => 50}))]
      }

      assert_refused(create(a, body), 400, "M_INVALID_ROOM_STATE", @lock_out_text)
      assert creates_by(a) == 0
    end

    test "the step-6 rule alone (preset events pass at 50, the entry needs events[PL] = 100) is 400 M_INVALID_ROOM_STATE, no room", %{a: a} do
      body = %{
        "preset" => "public_chat",
        "power_level_content_override" => %{"users" => %{a.uid => 50}, "events" => %{@pl => 100}},
        "initial_state" => [pl_entry(levels(%{a.uid => 50}, %{"events" => %{@pl => 100}}))]
      }

      assert_refused(create(a, body), 400, "M_INVALID_ROOM_STATE", @lock_out_text)
      assert creates_by(a) == 0
    end
  end

  describe "AC17 (b) - equality boundaries (sender b at 50)" do
    test "`kick` 40 -> 50 is 200 (the new value equals the sender's level)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"kick" => 40})
      ok_event_id!(put_pl(b, room, changed(room, %{"kick" => 50})))
      assert column(room)["kick"] == 50
    end

    test "an `events` entry whose current value is 50 changed to 0 is 200 (strictly greater rejects)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{}, %{"events" => %{@pl => 50, "m.room.topic" => 50}})
      ok_event_id!(put_pl(b, room, update_in(column(room), ["events"], &Map.put(&1, "m.room.topic", 0))))
      assert column(room)["events"]["m.room.topic"] == 0
    end

    test "a `users` entry at 50 changed is 403 (greater or equal rejects)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 50})
      conn = unchanged(room, fn -> put_pl(b, room, with_user(room, c.uid, 10)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end
  end

  describe "AC17 (c) - negative levels" do
    test "users_default -10, a user at -5, a sender at 0 (required level lowered to 0 by a seed) changes that user: 200", %{a: a, b: b, c: c, d: d} do
      content = levels(%{a.uid => 100, b.uid => 0, c.uid => -5}, %{"users_default" => -10, "events" => %{@pl => 0}})
      room = room_with_levels(a, [b, c, d], content)
      ok_event_id!(put_pl(b, room, with_user(room, c.uid, -7)))
      assert column(room)["users"][c.uid] == -7
    end

    test "a sender at -1 cannot change anything (403 below the required level 0)", %{a: a, b: b, c: c, d: d} do
      content = levels(%{a.uid => 100, b.uid => 0, d.uid => -1}, %{"users_default" => -10, "events" => %{@pl => 0}})
      room = room_with_levels(a, [b, c, d], content)
      conn = unchanged(room, fn -> put_pl(d, room, changed(room, %{"events_default" => 1})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
    end
  end

  describe "AC17 (d) - users entries for non-members" do
    test "valid user ids that are not members (also of another server) are accepted (200)", %{a: a} do
      room = public_room(a)
      other = "@visitor#{T.rand(3)}:other.example"
      nobody = ghost("nobody")
      ok_event_id!(put_pl(a, room, update_in(column(room), ["users"], &(&1 |> Map.put(other, 10) |> Map.put(nobody, 10)))))
      assert column(room)["users"][other] == 10 and column(room)["users"][nobody] == 10
    end
  end

  describe "AC17 (e) - the body must be an object with object / list shapes in the right places" do
    for {label, raw} <- [{"a JSON array", "[1, 2]"}, {"a JSON string", ~s("text")}, {"a JSON number", "12"}] do
      test "a body that is #{label} is 400 M_BAD_JSON, nothing written", %{a: a} do
        room = public_room(a)
        conn = unchanged(room, fn -> put_raw(a, pl_path(room), unquote(raw)) end)
        assert_err(conn, 400, "M_BAD_JSON")
      end
    end

    for {label, change} <- [{"users: []", %{"users" => []}}, {"users: null", %{"users" => nil}}, {"notifications: []", %{"notifications" => []}}, {"events: null", %{"events" => nil}}] do
      test "#{label} is 400 M_BAD_JSON, nothing written", %{a: a} do
        room = public_room(a)
        conn = unchanged(room, fn -> put_pl(a, room, changed(room, unquote(Macro.escape(change)))) end)
        assert_err(conn, 400, "M_BAD_JSON")
      end
    end
  end

  describe "AC17 (f) - exponent / float forms are not integers" do
    forms = ["1e2", "5.0E1", "-0.0"]

    locations =
      for(key <- ~w(ban kick invite redact state_default events_default users_default), do: {key, ~s({"#{key}": FORM})}) ++
        [
          {"an events value", ~s({"events": {"m.room.name": FORM}})},
          {"a users value", ~s({"users": {"@someone:test.local": FORM}})},
          {"a notifications value", ~s({"notifications": {"room": FORM}})}
        ]

    for {where, template} <- locations do
      test "1e2, 5.0E1 and -0.0 in #{where} are 400 M_BAD_JSON, nothing written", %{a: a} do
        room = public_room(a)

        for form <- unquote(forms) do
          raw = String.replace(unquote(template), "FORM", form)
          conn = unchanged(room, fn -> put_raw(a, pl_path(room), raw) end)
          assert conn.status == 400, "#{raw}: #{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
          assert T.json(conn)["errcode"] == "M_BAD_JSON"
        end
      end
    end
  end

  describe "AC17 (g) - notifications with a key other than room" do
    test "an integer is accepted and subject to the change rules (51 by a sender at 50 is 403, 50 is 200)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(b, room, changed(room, %{"notifications" => %{"room" => 50, "x_custom" => 51}})) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @grant_above)
      ok_event_id!(put_pl(b, room, changed(room, %{"notifications" => %{"room" => 50, "x_custom" => 50}})))
      assert column(room)["notifications"]["x_custom"] == 50
    end

    test "a string value is 400 M_BAD_JSON", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(a, room, changed(room, %{"notifications" => %{"x_custom" => "50"}})) end)
      assert_refused(conn, 400, "M_BAD_JSON", @int_text)
    end
  end

  describe "AC17 (h) - an unknown top-level key" do
    test "\"x_custom\": 999 is preserved in the stored content and in /sync and is NOT subject to the change rules (sender at the required level 50: 200)", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      ok_event_id!(put_pl(b, room, changed(room, %{"x_custom" => 999})))
      assert column(room)["x_custom"] == 999
      assert sync_pl(a, room)["content"]["x_custom"] == 999
      assert_agree(room)
    end
  end

  describe "AC17 (i) - the no-op is checked LAST" do
    test "identical content by a non-member is 403 \"You are not a member of this room\"", %{a: a, d: d} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl(d, room, column(room)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @not_member)
    end

    test "identical content by a member below the required level is 403 \"...to change the power levels\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      conn = unchanged(room, fn -> put_pl(c, room, column(room)) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @low_level)
    end

    test "identical content by another authorised sender than the current event's is 200 with the CURRENT event id and no new event", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d)
      current = latest_pl(room)
      assert current.sender == a.uid
      before = pl_footprint(room)

      assert ok_event_id!(put_pl(b, room, column(room))) == current.event_id
      assert pl_footprint(room) == before
    end
  end

  describe "AC17 (j) - the self-exemption at an equal level (a and c both at 100)" do
    test "a sender at 100 lowers his OWN entry while another user is at 100: 200", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 100})
      ok_event_id!(put_pl(a, room, with_user(room, a.uid, 50)))
      assert column(room)["users"][a.uid] == 50
    end

    test "removing the other user's entry is 403 \"...whose level is not lower than yours\"", %{a: a, b: b, c: c, d: d} do
      room = fifty_room(a, b, c, d, %{c.uid => 100})
      conn = unchanged(room, fn -> put_pl(a, room, update_in(column(room), ["users"], &Map.delete(&1, c.uid))) end)
      assert_refused(conn, 403, "M_FORBIDDEN", @target_not_lower)
    end
  end

  describe "AC17 (k) - @ rule variants on an allowlisted type (m.room.name)" do
    test "the state key \"@\" alone is 403 with the D5 (c) text, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      assert_refused(put_state_key(a, room, "m.room.name", "@", %{"name" => "x"}), 403, "M_FORBIDDEN", @at_text)
      assert event_count(room) == before
    end

    test "the sender's id with a different case is 403 with the D5 (c) text, nothing written", %{a: a} do
      room = public_room(a)
      before = event_count(room)
      assert_refused(put_state_key(a, room, "m.room.name", String.upcase(a.uid), %{"name" => "x"}), 403, "M_FORBIDDEN", @at_text)
      assert event_count(room) == before
    end

    test "a state key that merely contains an @ (\"x@y\") passes the rule (200)", %{a: a} do
      room = public_room(a)
      assert conn_ok?(put_state_key(a, room, "m.room.name", "x@y", %{"name" => "x"}))
    end
  end

  describe "AC17 (l) - the upgrader at L = 150" do
    test "a content with values up to 150 is carried (200)", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 150, b.uid => 150}, %{"events" => %{@pl => 100, "m.room.topic" => 150}, "state_default" => 150}))
      old = column(room)

      new_room = upgrade!(a, room)

      assert call(PowerLevels, :normalize, [column(new_room)]) == call(PowerLevels, :normalize, [old])
      assert column(new_room)["users"][a.uid] == 150
    end

    test "a users entry at 151 is 403 \"The room has power levels above yours\" BEFORE the tombstone: no tombstone, no new room", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      seed!(room, a, levels(%{a.uid => 150, b.uid => 151}))
      creates = creates_by(a)

      conn = unchanged(room, fn -> upgrade(a, room) end)

      assert_refused(conn, 403, "M_FORBIDDEN", @upgrade_above_text)
      assert events_of(room, "m.room.tombstone") == []
      assert creates_by(a) == creates, "no new room"
      assert T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows == [["active"]], "the old room is not archived"
    end
  end

  describe "AC17 (m) - the empty-key rule wins over the @ rule" do
    test "PUT m.room.power_levels with the sender's own id as state key is 400 M_BAD_JSON \"m.room.power_levels requires an empty state key\"", %{a: a} do
      room = public_room(a)
      conn = unchanged(room, fn -> put_pl_key(a, room, a.uid, column(room)) end)
      assert_refused(conn, 400, "M_BAD_JSON", @empty_key, [a.uid])
    end
  end

  # story state-writer-redaction (DELIBERATE re-pin, AC15 (c) / AC4 (a); old -> new): below the `redact` level a `/send` redaction of ANOTHER user's event is `403` and nothing
  # is stored or delivered (before: `200`, stored as sent, delivered in the others' /sync, the risk of S2 until `fw`). The assertions about the unchanged target stay.
  describe "AC17 (n) - /send of m.room.redaction below the redact level (closed by story state-writer-redaction)" do
    test "is 403 (the redact text), nothing is stored or delivered, the target is unchanged in /messages and /event", %{a: a, b: b} do
      room = public_room(a)
      join_now!(b, room)
      body = marker("victim")
      target = say!(a, room, body)
      content = %{"redacts" => target, "reason" => "pinned"}
      before = event_count(room)

      conn = send_event(b, room, "m.room.redaction", content)

      assert_refused(conn, 403, "M_FORBIDDEN", "You do not have a high enough power level to redact other users' events", [target])
      assert event_count(room) == before, "nothing is stored"
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.redaction'", [room]).rows == [[0]]

      original = Enum.find(messages(a, room), &(&1["event_id"] == target))
      assert original["content"]["body"] == body, "the target is unchanged in /messages"
      event_conn = T.matrix_request(:get, path(room, "event/#{enc(target)}"), a.at)
      assert event_conn.status == 200
      assert T.json(event_conn)["content"]["body"] == body, "the target is unchanged in /event"

      refute Enum.any?(join_timeline(sync(a), room), &(&1["type"] == "m.room.redaction")), "no redaction is delivered in the other members' /sync"
    end
  end

  describe "AC17 (o) - 429 of the tier" do
    test "carries errcode M_LIMIT_EXCEEDED and the Retry-After header (retry_after_ms is optional, never the only signal)", %{a: a} do
      room = public_room(a)
      tight_tier!(1, 2)
      seed("moderation", a, 0)
      limited_conn!(unchanged(room, fn -> put_pl(a, room, changed(room, %{"events_default" => 1})) end), "empty bucket")
    end
  end

  describe "AC17 (p) - createRoom initial_state entries that cannot be applied" do
    test "an entry with an @ state key is 400 M_BAD_JSON (the empty-key text), no room", %{a: a} do
      entry = %{"type" => @pl, "state_key" => a.uid, "content" => levels(%{a.uid => 100})}
      conn = create(a, %{"preset" => "public_chat", "initial_state" => [entry]})
      assert_refused(conn, 400, "M_BAD_JSON", @empty_key)
      assert creates_by(a) == 0
    end

    for {label, content} <- [{"a string", "x"}, {"a list", []}, {"null", nil}] do
      test "an entry whose content is #{label} is 400 M_BAD_JSON, no room", %{a: a} do
        entry = %{"type" => @pl, "state_key" => "", "content" => unquote(Macro.escape(content))}
        conn = create(a, %{"preset" => "public_chat", "initial_state" => [entry]})
        assert_err(conn, 400, "M_BAD_JSON")
        assert creates_by(a) == 0
      end
    end
  end

  # ─── small private helpers (kept at the end) ─────────────────────────────────

  defp conn_ok?(conn) do
    assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    true
  end

  defp flush_events do
    receive do
      {:new_event, _} -> flush_events()
    after
      0 -> :ok
    end
  end
end
