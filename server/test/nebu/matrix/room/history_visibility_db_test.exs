defmodule Nebu.Matrix.Room.HistoryVisibilityDbTest do
  @moduledoc """
  Real-database tests for story `history-visibility-enforcement` (follow-up `es`): AC6 (same-millisecond and boundary rules), AC7 (D4 legacy / fail-open rows), AC10 (the ONE fragment, the
  EXPLAIN pins, the bounded scan), AC5 (f) (the leave window against the fragment), AC22 (12) (the timestamp invariant), plus a MODEL test of the rule over the stored rows. `Room.DB` /
  `Search.DB` directly, direct inserts with chosen timestamps in OWN rooms (`raw_room!/0`), the real `Nebu.Repo`. NO fakes: a fake that returns pre-sorted rows proves nothing about the SQL
  (the segments, the ties, both JSONB forms, the synthetic join, the unknown values are all decided by the statement).

  The same facts are read through THREE shapes of the one rule and must agree: the page (`fetch_visible_events/5`), the single event (`fetch_visible_event/3`) and, for messages, the search
  (`Search.DB.search_messages/5`, which needs the viewer's `room_members` row: the tests that use it insert it).

  ## Decisions of the ATDD step (ambiguities of the story)

    * The binding signatures are in `Nebu.Matrix.HistoryVisibilityTestSupport`'s moduledoc (`fetch_visible_events/5`, `fetch_visible_events_since/4` with the argument order
      `(room_id, viewer, last_event_id, limit)`, `fetch_visible_event/3`, `fetch_visible_events_by_relation/6`, `fetch_state_predecessors(slots, viewer: v)`). Events are maps with the string keys
      of `fetch_event/2` (`content`, `event_id`, `event_type`, `origin_server_ts`, `room_id`, `sender`, `state_key`).
    * AC10 (c) bound: the number of rows read from `events` by the page statement is measured with `EXPLAIN (ANALYZE, FORMAT JSON)` (`(Actual Rows + Rows Removed by Filter) * Actual Loops`
      over every scan node of `events`); the bound is `(segments + 1) * (limit + 1)` plus a small allowance for the state-index reads of the segment inputs. `segments` is the number
      of segments of the fixture (5): the story's "segments" without the distinction of visible and invisible ones, a looser and implementation-neutral bound.
    * AC10 (a): "no second definition of `allow`" is pinned as: `= 'invited'` occurs at most once in `Room.DB` and never in `Search.DB` or the dispatcher.
    * The same-millisecond rule is labelled in the story: "the state at an event is the state before it in the `(origin_server_ts, event_id)` order; ... Nebu rule (no DAG)".
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport, only: [member_events: 2, make_room: 2, user!: 1, uid_of: 1, anchor_room!: 1, snapshot!: 2, sync: 2, in_section?: 3]
  import Nebu.Matrix.HistoryVisibilityTestSupport
  import Nebu.Matrix.MembershipStateTestSupport, only: [count_statements: 1, put_member_id!: 7, put_string_member!: 5]

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Search.DB, as: SearchDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @event_keys ["content", "event_id", "event_type", "origin_server_ts", "room_id", "sender", "state_key"]
  @lib Path.expand("../../../../lib", __DIR__)

  setup do
    Nebu.Matrix.MembershipStateTestSupport.setup_env!()
    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp a_uid, do: "@hva#{T.rand(3)}:#{T.server_name()}"

  # the page the viewer gets (newest first) and the event ids on it
  defp page(room, viewer, limit \\ 1_000, dir \\ "b") do
    assert {:ok, events, _next, _prev} = DB.fetch_visible_events(room, viewer, dir, limit, "")
    events
  end

  defp page_ids(room, viewer), do: room |> page(viewer) |> Enum.map(& &1["event_id"])

  defp single?(room, viewer, id) do
    case DB.fetch_visible_event(id, room, viewer) do
      {:ok, %{"event_id" => ^id}} -> true
      {:error, :not_found} -> false
    end
  end

  # one fact through the page AND the single read: `visible?` for the event `id`
  defp assert_vis!(room, viewer, id, visible?, label) do
    assert (id in page_ids(room, viewer)) == visible?, "#{label}: page read, expected visible=#{visible?}"
    assert single?(room, viewer, id) == visible?, "#{label}: single read, expected visible=#{visible?}"
  end

  defp put_join!(room, who, ts, id \\ nil), do: member!(room, who, "join", ts, id)

  defp member!(room, who, membership, ts, id \\ nil, sender \\ nil) do
    id = id || "$" <> T.rand(12)
    put_member_id!(room, who, membership, sender || who, ts, id, %{})
  end

  defp msg!(room, ts, sender \\ nil), do: put_message!(room, sender || a_uid(), word("m"), ts)

  defp ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # ═══ AC6: same-millisecond and boundary rules ═══════════════════════════════════════════════════

  describe "AC6 - segments and the same-ms rule" do
    test "(a) joined: a message in the SAME millisecond as G's join is invisible, one ms later it is visible, one ms earlier it is not" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "joined", 100)
      before_join = msg!(room, 199)
      same = msg!(room, 200)
      after_join = msg!(room, 201)
      put_join!(room, g, 200)

      assert_vis!(room, g, before_join, false, "before the join")
      assert_vis!(room, g, same, false, "same ms as the join")
      assert_vis!(room, g, after_join, true, "one ms after the join")
      # control: a viewer who joined before everything sees all three
      early = a_uid()
      put_join!(room, early, 50)
      for id <- [before_join, same, after_join], do: assert_vis!(room, early, id, true, "control")
    end

    test "(b) joined: a message in the same ms as G's leave is invisible; the interval is visible, the gap and the ms after the leave are not" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "joined", 100)
      put_join!(room, g, 200)
      inside = msg!(room, 250)
      same_leave = msg!(room, 300)
      after_leave = msg!(room, 301)
      gap = msg!(room, 350)
      member!(room, g, "leave", 300)
      put_join!(room, g, 400)
      after_rejoin = msg!(room, 450)

      assert_vis!(room, g, inside, true, "inside the first interval")
      assert_vis!(room, g, same_leave, false, "same ms as the leave")
      assert_vis!(room, g, after_leave, false, "the ms after the leave")
      assert_vis!(room, g, gap, false, "the gap")
      assert_vis!(room, g, after_rejoin, true, "after the re-join")
    end

    test "(c) a message in the same ms as an hv change is invisible in both directions (shared -> joined, joined -> shared)" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "shared", 100)
      put_hv_event!(room, a, "joined", 200)
      to_joined_before = msg!(room, 199)
      to_joined_same = msg!(room, 200)
      to_joined_after = msg!(room, 201)
      put_hv_event!(room, a, "shared", 300)
      to_shared_before = msg!(room, 299)
      to_shared_same = msg!(room, 300)
      to_shared_after = msg!(room, 301)
      put_join!(room, g, 400)

      assert_vis!(room, g, to_joined_before, true, "shared period")
      assert_vis!(room, g, to_joined_same, false, "same ms as shared -> joined")
      assert_vis!(room, g, to_joined_after, false, "joined period")
      assert_vis!(room, g, to_shared_before, false, "joined period, the ms before joined -> shared")
      assert_vis!(room, g, to_shared_same, false, "same ms as joined -> shared")
      assert_vis!(room, g, to_shared_after, true, "shared again")
    end

    test "(d) G's own invite: visible under invited, invisible under joined; his own leave under joined is visible" do
      for {value, invite_visible?} <- [{"invited", true}, {"joined", false}] do
        room = raw_room!()
        a = a_uid()
        g = a_uid()
        put_hv_event!(room, a, value, 100)
        invite = member!(room, g, "invite", 200, nil, a)
        join = put_join!(room, g, 300)
        leave = member!(room, g, "leave", 400)

        assert_vis!(room, g, invite, invite_visible?, "own invite under #{value}")
        assert_vis!(room, g, join, true, "own join under #{value}")
        assert_vis!(room, g, leave, true, "own leave under #{value} (D5 (b): the membership before it was join)")
      end
    end

    test "(d) other users' member events follow the ordinary rule (H's join before G's join is invisible under joined)" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      h = a_uid()
      put_hv_event!(room, a, "joined", 100)
      h_early = put_join!(room, h, 150)
      put_join!(room, g, 200)
      h_late = member!(room, h, "leave", 250)

      assert_vis!(room, g, h_early, false, "H's join lies before G's join")
      assert_vis!(room, g, h_late, true, "H's leave lies inside G's interval")
    end

    test "(e) joined -> world_readable while G was not a member is visible to G after his join; joined -> invited is invisible" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "joined", 100)
      to_wr = put_hv_event!(room, a, "world_readable", 200)
      put_join!(room, g, 300)
      assert_vis!(room, g, to_wr, true, "joined -> world_readable (S5: the setting after it allows)")

      room2 = raw_room!()
      put_hv_event!(room2, a, "joined", 100)
      to_invited = put_hv_event!(room2, a, "invited", 200)
      put_join!(room2, g, 300)
      assert_vis!(room2, g, to_invited, false, "joined -> invited: neither the setting before nor the one after allows a non-member")
    end

    test "(f) two hv events in the SAME ms: the event_id DESC winner is the value after that ms (deterministic, both orders)" do
      for {low_value, high_value, visible?} <- [{"joined", "shared", true}, {"shared", "joined", false}] do
        room = raw_room!()
        a = a_uid()
        g = a_uid()
        put_hv_event!(room, a, "shared", 100)
        put_hv_event!(room, a, low_value, 200, "$aaaa" <> T.rand(6))
        put_hv_event!(room, a, high_value, 200, "$zzzz" <> T.rand(6))
        after_ms = msg!(room, 201)
        put_join!(room, g, 300)

        assert_vis!(room, g, after_ms, visible?, "winner by event_id DESC: #{high_value} (low #{low_value})")
      end
    end

    test "an hv event with state_key NULL or a non-empty state key never counts; unknown values read as shared; both JSONB forms" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_event!(room, a, hv_type(), %{"history_visibility" => "joined"}, 100, nil)
      put_event!(room, a, hv_type(), %{"history_visibility" => "joined"}, 110, "other-key")
      put_hv_event!(room, a, "nonsense", 120)
      put_event!(room, a, hv_type(), %{"history_visibility" => 7}, 130, "")
      put_event!(room, a, hv_type(), %{}, 140, "")
      m = msg!(room, 150)
      put_join!(room, g, 200)
      assert_vis!(room, g, m, true, "none of them restricts")

      # both JSONB forms: a valid `joined` restricts in the object form AND in the double-encoded string form
      for {label, insert} <- [{"object", &put_hv_event!(&1, &2, "joined", &3)}, {"string", &put_hv_string!(&1, &2, ~s({"history_visibility":"joined"}), &3)}] do
        r = raw_room!()
        insert.(r, a, 100)
        hidden = msg!(r, 150)
        put_join!(r, g, 200)
        assert_vis!(r, g, hidden, false, "#{label} form restricts")
      end

      # a string form that is no JSON, a JSON scalar, an array: read as shared (never an error)
      for {label, text} <- [{"bare text", "joined"}, {"JSON scalar", ~s("joined")}, {"array", ~s(["joined"])}] do
        r = raw_room!()
        put_hv_string!(r, a, text, 100)
        visible = msg!(r, 150)
        put_join!(r, g, 200)
        assert_vis!(r, g, visible, true, "#{label} reads as shared")
      end
    end

    test "unknown / unparseable member contents read as leave: a join with content {} never makes the viewer a member" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "joined", 100)
      before_event = msg!(room, 150)
      put_event!(room, g, "m.room.member", %{}, 200, g)
      put_event!(room, g, "m.room.member", %{"membership" => "weird"}, 210, g)
      after_event = msg!(room, 250)

      assert_vis!(room, g, before_event, false, "no member event of his reads as join")
      assert_vis!(room, g, after_event, false, "a member event without a known membership is leave")
    end
  end

  # ═══ AC7: legacy and fail-open rows (D4) ════════════════════════════════════════════════════════

  describe "AC7 - the synthetic join at room_members.joined_at" do
    test "(a) a member row (left_at NULL, joined_at T0) and NO member event, room joined: he sees what is after T0 and nothing before" do
      room = raw_room!()
      a = a_uid()
      g = T.provision_user!()
      put_hv_event!(room, a, "joined", 100)
      before_t0 = msg!(room, 150)
      same_t0 = msg!(room, 200)
      after_t0 = msg!(room, 250)
      put_row!(room, g, 200)

      assert member_events_of(room, g) == [], "fixture: no member event"
      child = fn ts -> put_event!(room, a, "m.room.message", %{"msgtype" => "m.text", "body" => word("c"), "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => before_t0}}, ts) end
      early_child = child.(160)
      late_child = child.(260)
      assert_vis!(room, g, before_t0, false, "before T0")
      assert_vis!(room, g, same_t0, false, "the same ms as the synthetic join is judged most restrictively like a real one")
      assert_vis!(room, g, after_t0, true, "after T0")

      # the since read and the relation read use the same synthetic join
      assert {:ok, since} = DB.fetch_visible_events_since(room, g, nil, 100)
      since_ids = Enum.map(since, & &1["event_id"])
      assert after_t0 in since_ids and late_child in since_ids
      refute before_t0 in since_ids or early_child in since_ids or same_t0 in since_ids

      assert {:ok, children} = DB.fetch_visible_events_by_relation(room, g, before_t0, "m.thread", 100, %{})
      assert Enum.map(children, & &1["event_id"]) == [late_child], "the child before T0 is hidden, the one after is visible"

      # the search reads the same rule (it needs the row, which exists)
      found = for id <- [before_t0, after_t0], match?({:ok, [%{"event_id" => ^id}]}, search_one(g, room, id)), do: id
      assert found == [after_t0]
    end

    test "(b) the latest member event is leave but the ROW says joined since T1 (a failed re-join write): he sees what is after T1" do
      room = raw_room!()
      a = a_uid()
      g = T.provision_user!()
      put_hv_event!(room, a, "joined", 100)
      put_join!(room, g, 200)
      first_interval = msg!(room, 250)
      member!(room, g, "leave", 300)
      gap = msg!(room, 350)
      after_t1 = msg!(room, 450)
      put_row!(room, g, 400)

      assert_vis!(room, g, first_interval, true, "inside the first interval")
      assert_vis!(room, g, gap, false, "the gap before T1")
      assert_vis!(room, g, after_t1, true, "after T1 (the row is authoritative for joined now)")

      # control: the same room for a viewer whose row is LEFT does not get the synthetic join
      put_row!(room, g, 400, 500)
      assert_vis!(room, g, after_t1, false, "a row with left_at set adds no synthetic join")
    end

    test "(c) a row with left_at set and no join event adds no synthetic join: only world_readable / shared events are visible" do
      for {value, visible?} <- [{"joined", false}, {"invited", false}, {"shared", true}, {"world_readable", true}] do
        room = raw_room!()
        a = a_uid()
        g = T.provision_user!()
        put_hv_event!(room, a, value, 100)
        m = msg!(room, 250)
        put_row!(room, g, 200, 300)
        assert_vis!(room, g, m, visible?, "left row under #{value}")
      end
    end

    test "a viewer with neither a member event nor a row sees only world_readable / shared events; the unfiltered event is not served" do
      room = raw_room!()
      a = a_uid()
      stranger = a_uid()
      shared = msg!(room, 50)
      put_hv_event!(room, a, "joined", 100)
      restricted = msg!(room, 150)
      assert_vis!(room, stranger, shared, true, "before the first hv event: shared")
      assert_vis!(room, stranger, restricted, false, "under joined")
      assert {:error, :not_found} = DB.fetch_visible_event(restricted, room, stranger)
    end
  end

  defp member_events_of(room, who), do: member_events(room, uid_of(who))

  defp search_one(viewer, room, id) do
    [[body]] = T.sql!("SELECT content->>'body' FROM events WHERE event_id = $1", [id]).rows
    SearchDB.search_messages(viewer, body, 10, 0, [room])
  end

  # ═══ the return shapes ══════════════════════════════════════════════════════════════════════════

  describe "the shapes of the viewer-aware reads" do
    test "fetch_visible_events/5: {:ok, events, next_batch, prev_batch}, the keys of fetch_events/4, a token while more remain, none on the last page" do
      room = raw_room!()
      a = a_uid()
      for ts <- 100..109, do: msg!(room, ts, a)

      assert {:ok, events, next_batch, prev_batch} = DB.fetch_visible_events(room, a, "b", 4, "")
      assert length(events) == 4 and Enum.all?(events, &(Enum.sort(Map.keys(&1)) == @event_keys))
      assert Enum.map(events, & &1["origin_server_ts"]) == [109, 108, 107, 106], "newest first"
      assert String.starts_with?(next_batch, "v1_") and String.starts_with?(prev_batch, "v1_")

      assert {:ok, events2, next2, _} = DB.fetch_visible_events(room, a, "b", 4, next_batch)
      assert Enum.map(events2, & &1["origin_server_ts"]) == [105, 104, 103, 102]
      assert {:ok, events3, next3, _} = DB.fetch_visible_events(room, a, "b", 4, next2)
      assert Enum.map(events3, & &1["origin_server_ts"]) == [101, 100] and next3 == "", "the last page has no token"

      assert {:ok, fwd, fwd_next, _} = DB.fetch_visible_events(room, a, "f", 3, "")
      assert Enum.map(fwd, & &1["origin_server_ts"]) == [100, 101, 102] and fwd_next != ""
      assert {:ok, [], "", _} = DB.fetch_visible_events(room, a, "b", 4, token(100, List.last(events3)["event_id"])), "past the oldest: an empty page, no token"
    end

    test "fetch_visible_event/3: {:ok, map} with the keys of fetch_event/2; {:error, :not_found} for unknown, other-room and invisible ids" do
      room = raw_room!()
      other = raw_room!()
      a = a_uid()
      g = a_uid()
      put_join!(room, a, 10)
      put_hv_event!(room, a, "joined", 100)
      hidden = msg!(room, 150)
      put_join!(room, g, 200)
      shown = msg!(room, 250)
      elsewhere = msg!(other, 50, a)

      assert {:ok, ev} = DB.fetch_visible_event(shown, room, g)
      assert Enum.sort(Map.keys(ev)) == @event_keys and ev["event_id"] == shown and ev["room_id"] == room and ev["state_key"] == nil
      assert {:error, :not_found} = DB.fetch_visible_event(hidden, room, g)
      assert {:error, :not_found} = DB.fetch_visible_event("$unknown" <> T.rand(8), room, g)
      assert {:error, :not_found} = DB.fetch_visible_event(elsewhere, room, a), "an event of another room is not found in this one, whoever asks"
      assert {:ok, %{"event_id" => ^hidden}} = DB.fetch_visible_event(hidden, room, a), "control: the creator-side viewer (joined before) reads it"
    end

    test "fetch_visible_events_since/4: the OLDEST visible events after the anchor, in order; invisible ones never starve the page" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_join!(room, a, 10)
      anchor = msg!(room, 50)
      hv = put_hv_event!(room, a, "joined", 100)
      for ts <- 101..130, do: msg!(room, ts)
      join = put_join!(room, g, 200)
      visible = for ts <- 201..203, do: msg!(room, ts)

      assert {:ok, events} = DB.fetch_visible_events_since(room, g, anchor, 20)
      assert Enum.map(events, & &1["event_id"]) == [hv, join] ++ visible, "the hv event (S5), his join and the three: 30 invisible events in front do not starve the page"
      assert Enum.all?(events, &(Enum.sort(Map.keys(&1)) == @event_keys))

      assert {:ok, two} = DB.fetch_visible_events_since(room, g, anchor, 2)
      assert Enum.map(two, & &1["event_id"]) == [hv, join], "the limit counts visible events, the OLDEST first"
      assert {:ok, all} = DB.fetch_visible_events_since(room, a, anchor, 100)
      assert length(all) == 1 + 30 + 1 + 3, "control: the member since before everything gets the hv event, the 30, G's join and the 3"
      assert {:ok, from_start} = DB.fetch_visible_events_since(room, g, nil, 100)
      assert anchor in Enum.map(from_start, & &1["event_id"]), "no anchor: from the start (the anchor message predates the setting: shared, visible)"
    end

    test "fetch_visible_events_by_relation/6: the children filtered by the rule; the relation filter and the limit apply; both directions" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_join!(room, a, 10)
      parent = msg!(room, 50)
      put_hv_event!(room, a, "joined", 100)

      child = fn ts ->
        put_event!(room, a, "m.room.message", %{"msgtype" => "m.text", "body" => word("c"), "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => parent}}, ts)
      end

      hidden = for ts <- [110, 120], do: child.(ts)
      put_join!(room, g, 200)
      shown = for ts <- [210, 220, 230], do: child.(ts)

      assert {:ok, events} = DB.fetch_visible_events_by_relation(room, g, parent, "m.thread", 100, %{})
      assert Enum.map(events, & &1["event_id"]) == Enum.reverse(shown)
      assert {:ok, two} = DB.fetch_visible_events_by_relation(room, g, parent, "", 2, %{dir: "f"})
      assert Enum.map(two, & &1["event_id"]) == Enum.take(shown, 2), "dir=f: the two oldest VISIBLE children"
      assert {:ok, a_events} = DB.fetch_visible_events_by_relation(room, a, parent, "m.thread", 100, %{})
      assert length(a_events) == 5 and Enum.all?(hidden, &(&1 in Enum.map(a_events, fn e -> e["event_id"] end))), "control: the member since before them sees all five"
    end

    test "fetch_state_predecessors(slots, viewer: v): kept only when visible, never a substitute; strict and lenient agree; no option unchanged" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_join!(room, a, 10)
      topic = fn ts, text -> put_event!(room, a, "m.room.topic", %{"topic" => text}, ts, "") end
      t0 = topic.(50, "zero")
      put_hv_event!(room, a, "joined", 100)
      t1 = topic.(150, "one")
      put_join!(room, g, 200)
      t2 = topic.(250, "two")
      t3 = topic.(300, "three")

      slots = for {id, ts} <- [{t2, 250}, {t3, 300}], do: {id, room, "m.room.topic", "", ts}

      lenient = DB.fetch_state_predecessors(slots, viewer: g)
      assert Map.keys(lenient) == [t3], "T2's true predecessor T1 is invisible: no entry (never T0's); T3's predecessor T2 is visible"
      assert %{event_id: ^t2, sender: _, content: %{"topic" => "two"}} = lenient[t3]

      assert {:ok, strict} = DB.fetch_state_predecessors(slots, viewer: g, strict: true)
      assert Map.keys(strict) == [t3]

      unfiltered = DB.fetch_state_predecessors(slots)
      assert unfiltered[t2].event_id == t1 and unfiltered[t3].event_id == t2, "no viewer option: the old behaviour (every predecessor)"
      assert DB.fetch_state_predecessors(slots, viewer: a)[t2].event_id == t1, "control: a viewer who sees T1 gets it"
      assert t0 != t1

      # STORY-5: a viewer that is nil or "" serves NO predecessor (fail closed), never the unfiltered statement
      for none <- [nil, ""] do
        assert DB.fetch_state_predecessors(slots, viewer: none) == %{}
        assert DB.fetch_state_predecessors(slots, viewer: none, strict: true) == {:ok, %{}}
      end
    end
  end

  # ═══ the model ══════════════════════════════════════════════════════════════════════════════════

  describe "the model: the rule re-implemented over the stored rows" do
    # The model is the same two-sided formula as D2 (c) / D5, written a second time over the STORED rows: it catches bugs of the SQL (segments, ties, JSONB forms, indexes of the
    # boundaries), not a shared misconception of the rule; the rule's reading is pinned by the explicit tests of AC6 (a), (c), (f) above.
    test "40 random rooms: page, forward, single, since and relations agree with the model, specials (D5) included" do
      :rand.seed(:exsss, {7, 11, 13})

      for _round <- 1..40 do
        room = raw_room!()
        a = a_uid()
        g = a_uid()
        horizon = 24
        memberships = ["join", "invite", "leave", "ban", "knock", "weird"]
        values = ["world_readable", "shared", "invited", "joined", "nonsense"]

        # ids with random letters: the event_id tie-break is exercised too
        for _ <- 1..Enum.random(0..4)//1 do
          put_hv_event!(room, a, Enum.random(values), 100 + Enum.random(1..horizon), "$" <> Base.encode16(:crypto.strong_rand_bytes(4)))
        end

        for _ <- 1..Enum.random(0..5)//1 do
          put_member_id!(room, g, Enum.random(memberships), a, 100 + Enum.random(1..horizon), "$" <> Base.encode16(:crypto.strong_rand_bytes(4)), %{})
        end

        parent = msg!(room, 99, a)

        msgs =
          for ts <- 100..(100 + horizon + 2), into: %{} do
            content = %{"msgtype" => "m.text", "body" => word("c"), "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => parent}}
            {ts, put_event!(room, a, "m.room.message", content, ts)}
          end

        rows = model_rows(room, g)
        context = "room #{room}, rows #{inspect(rows)}"
        message_ids = Map.values(msgs)
        expected = for {ts, id} <- msgs, model_visible?(rows, ts), do: id
        only = fn ids -> Enum.filter(ids, &(&1 in message_ids)) end

        page_ids = room |> page(g) |> Enum.map(& &1["event_id"])
        assert Enum.sort(only.(page_ids)) == Enum.sort(expected), "page vs model, #{context}"
        {:ok, fwd, _, _} = DB.fetch_visible_events(room, g, "f", 1_000, "")
        assert only.(Enum.map(fwd, & &1["event_id"])) == Enum.reverse(only.(page_ids)), "dir=f is dir=b reversed, #{context}"

        {:ok, since} = DB.fetch_visible_events_since(room, g, nil, 1_000)
        assert only.(Enum.map(since, & &1["event_id"])) == Enum.reverse(only.(page_ids)), "since is ascending and the same set, #{context}"

        # story sync-stream-position (A-1): the reads that now serve /sync, against the SAME model: the incremental range read by position (the messages were inserted in
        # timestamp order, so position order is timestamp order for them) and the page bounded by the head (D12). `apply/3`: the functions are new.
        head = T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
        {:ok, range} = apply(DB, :fetch_visible_events_in_range, [room, g, 0, head, 1_000])
        range_ids = Enum.map(range, & &1["event_id"])
        assert Enum.sort(only.(range_ids)) == Enum.sort(expected), "range vs model, #{context}"
        assert only.(range_ids) == only.(page_ids), "the range read is newest first, the same order as the page for these rows, #{context}"
        {:ok, page6, _, _} = apply(DB, :fetch_visible_events, [room, g, "b", 1_000, "", head])
        assert Enum.map(page6, & &1["event_id"]) == page_ids, "the head-bounded page (head = the room's head) is the page, #{context}"

        {:ok, children_b} = DB.fetch_visible_events_by_relation(room, g, parent, "m.thread", 1_000, %{dir: "b"})
        {:ok, children_f} = DB.fetch_visible_events_by_relation(room, g, parent, "m.thread", 1_000, %{dir: "f"})
        assert Enum.map(children_b, & &1["event_id"]) == only.(page_ids), "relations (newest first) vs the page, #{context}"
        assert Enum.map(children_f, & &1["event_id"]) == Enum.reverse(only.(page_ids)), "relations dir=f, #{context}"
        assert Enum.sort(Enum.map(children_b, & &1["event_id"])) == Enum.sort(expected), "relations vs model, #{context}"

        for {ts, id} <- msgs do
          assert single?(room, g, id) == model_visible?(rows, ts), "single vs model at ts #{ts}, #{context}"
        end

        # the special events: the hv events and the viewer's own member events (D5)
        {hv_rows, member_rows} = rows
        specials = Enum.map(hv_rows, &{:hv, &1}) ++ Enum.map(member_rows, &{:member, &1})

        for {_kind, row} = special <- specials do
          expected_special = model_special_visible?(rows, special)
          assert single?(room, g, row.id) == expected_special, "special #{inspect(special)} (single) vs model, #{context}"
          assert (row.id in page_ids) == expected_special, "special #{inspect(special)} (page) vs model, #{context}"
          assert (row.id in range_ids) == expected_special, "special #{inspect(special)} (range) vs model, #{context}"
        end
      end
    end

    test "the viewer's own join and leave / ban in ONE ms, ids opposite to the rank: the most restrictive wins" do
      for {join_id, other, other_id} <- [{"$zzzz", "leave", "$aaaa"}, {"$aaaa", "leave", "$zzzz"}, {"$zzzz", "ban", "$aaaa"}, {"$aaaa", "ban", "$zzzz"}] do
        room = raw_room!()
        a = a_uid()
        g = a_uid()
        put_hv_event!(room, a, "joined", 100)
        put_join!(room, g, 150)
        inside = msg!(room, 180)
        put_join!(room, g, 200, join_id <> T.rand(4))
        member!(room, g, other, 200, other_id <> T.rand(4))
        after_tie = msg!(room, 250)

        assert_vis!(room, g, inside, true, "inside the first interval (#{other} / join tie)")
        assert_vis!(room, g, after_tie, false, "after a join and #{other} in one ms: the most restrictive membership is the latest, ids #{join_id}/#{other_id}")
      end
    end

    test "the string JSONB form of the viewer's member events: a string join starts, a string leave ends, non-JSON reads as leave" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "joined", 100)
      before_join = msg!(room, 150)
      put_string_member!(room, g, %{"membership" => "join"}, g, 200)
      inside = msg!(room, 250)
      put_string_member!(room, g, %{"membership" => "leave"}, g, 300)
      after_leave = msg!(room, 350)

      assert_vis!(room, g, before_join, false, "before the string-form join")
      assert_vis!(room, g, inside, true, "after a string-form join")
      assert_vis!(room, g, after_leave, false, "after a string-form leave")

      broken = raw_room!()
      put_hv_event!(broken, a, "joined", 100)
      put_join!(broken, g, 150)
      put_string_member!(broken, g, "this is not json", g, 200)
      later = msg!(broken, 250)
      assert_vis!(broken, g, later, false, "a string that is no JSON reads as leave (never an error)")
    end
  end

  # ═══ AC10: the one fragment, EXPLAIN, the bounded scan ══════════════════════════════════════════

  describe "AC10 - one definition, bound parameters, index use, bounded scans" do
    test "(a)(d) history_visibility_sql/0 is ONE constant text with the marker; one allow rule; built from module attributes" do
      assert is_binary(DB.history_visibility_sql())
      sql = DB.history_visibility_sql()
      assert String.contains?(sql, "/* history_visibility */")
      assert DB.history_visibility_sql() == sql, "a constant"

      db_source = File.read!(Path.join(@lib, "nebu/matrix/room/db.ex"))
      search_source = File.read!(Path.join(@lib, "nebu/matrix/search/db.ex"))
      server_source = File.read!(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))

      assert length(Regex.scan(~r/=\s*'invited'/, db_source)) <= 1, "at most one allow rule in Room.DB"
      assert Regex.scan(~r/=\s*'invited'/, search_source) == [] and Regex.scan(~r/'invited'/, search_source) == []
      assert Regex.scan(~r/'invited'/, server_source) == [], "no second definition in the dispatcher"
      assert search_source =~ "Nebu.Matrix.Room.DB.history_visibility_sql()", "Search.DB interpolates the ONE text"
      assert SearchDB.sql_search_messages() =~ "/* history_visibility */"

      # (d) built from module attributes only: every interpolation of the `@sql_history_visibility` definition is a module attribute read
      ast = db_source |> Code.string_to_quoted!()

      {_ast, defs} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{:sql_history_visibility, _, [value]}]} = node, acc -> {node, [value | acc]}
          node, acc -> {node, acc}
        end)

      assert [value] = defs, "exactly one @sql_history_visibility definition"

      {_ast, interpolations} =
        Macro.prewalk(value, [], fn
          {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, {:binary, _, _}]} = node, acc -> {node, [expr | acc]}
          node, acc -> {node, acc}
        end)

      assert interpolations != [], "the fragment reuses the member fragments"
      assert Enum.all?(interpolations, &match?({:@, _, [{name, _, _}]} when is_atom(name), &1)), "only module attributes are interpolated (no value, no function call)"
      names = for {:@, _, [{name, _, _}]} <- interpolations, do: name
      assert :sql_member_rank in names and :sql_member_membership_raw in names, "the EXISTING member fragments, no second rank definition"
    end

    test "(a) every visibility-filtered statement carries the marker and is parameter-bound (no room id or viewer in the text)" do
      room = raw_room!()
      a = T.provision_user!()
      put_hv_event!(room, a, "joined", 100)
      id = msg!(room, 150, a)
      put_join!(room, a, 50)
      put_row!(room, a, 50)

      for {label, fun} <- [
            page: fn -> DB.fetch_visible_events(room, a, "b", 5, "") end,
            since: fn -> DB.fetch_visible_events_since(room, a, nil, 5) end,
            range: fn -> apply(DB, :fetch_visible_events_in_range, [room, a, 0, 100, 5]) end,
            page6: fn -> apply(DB, :fetch_visible_events, [room, a, "b", 5, "", 100]) end,
            single: fn -> DB.fetch_visible_event(id, room, a) end,
            relations: fn -> DB.fetch_visible_events_by_relation(room, a, id, "", 5, %{}) end,
            predecessors: fn -> DB.fetch_state_predecessors([{id, room, "m.room.topic", "", 150}], viewer: a) end,
            search: fn -> SearchDB.search_messages(a, "x", 5, 0, []) end,
            search_room_filter: fn -> SearchDB.search_messages(a, "x", 5, 0, [room]) end
          ] do
        {_result, stmts} = count_statements(fun)
        marked = Enum.filter(stmts, &String.contains?(&1, "/* history_visibility */"))
        assert marked != [], "#{label}: a statement carries the marker"
        for q <- marked, do: refute(String.contains?(q, room) or String.contains?(q, a), "#{label}: no value in the statement text")
      end
    end

    test "(b)(c) EXPLAIN of the real page statement: both story indexes, no seq scan, and a bounded read with 5 000 hidden events" do
      room = raw_room!()
      a = a_uid()
      b = a_uid()
      put_hv_event!(room, a, "joined", 1_000)

      T.privileged_sql!(
        """
        INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
        SELECT '$bulk' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'hidden' || g), 1000 + g, NULL
        FROM generate_series(1, 5000) AS g
        """,
        [room, a]
      )

      put_join!(room, b, 6_001)
      shown = for ts <- 6_002..6_004, do: msg!(room, ts, a)
      T.privileged_sql!("ANALYZE events")

      limit = 10
      captured = capture_marked_statement(fn -> DB.fetch_visible_events(room, b, "b", limit, "") end)
      assert {:ok, events, "", _} = DB.fetch_visible_events(room, b, "b", limit, "")
      assert Enum.map(events, & &1["event_id"]) |> Enum.take(3) == Enum.reverse(shown), "the three messages after the join first"
      assert length(events) == 5, "m3, m2, m1, his join, the hv event (D5 (a)): nothing of the 5 000 hidden events"

      {query, params} = captured
      refute query =~ ~r/SELECT\s+\*/i, "the statement names its columns"

      json = explain!(query, params, "ANALYZE, BUFFERS, FORMAT JSON")
      nodes = plan_nodes(json)
      events_nodes = Enum.filter(nodes, &(&1["Relation Name"] == "events"))
      assert events_nodes != []
      refute Enum.any?(events_nodes, &(&1["Node Type"] == "Seq Scan")), "no sequential scan of events"
      index_names = events_nodes |> Enum.map(& &1["Index Name"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert "events_room_id_ts_idx" in index_names, "the page is read through events_room_id_ts_idx: #{inspect(index_names)}"
      assert "events_room_state_idx" in index_names, "the segment inputs are read through events_room_state_idx: #{inspect(index_names)}"

      read =
        Enum.sum(
          for n <- events_nodes do
            (n["Actual Rows"] + Map.get(n, "Rows Removed by Filter", 0) + Map.get(n, "Rows Removed by Index Recheck", 0)) * n["Actual Loops"]
          end
        )

      segments = 5
      assert read <= (segments + 1) * (limit + 1) + 20, "the page read #{read} rows of events: at most (segments + 1) x (limit + 1) plus the state-index reads (a scan of the hidden 5 000 would be 5 000)"

      # the page comes back in ONE statement
      {_result, stmts} = count_statements(fn -> DB.fetch_visible_events(room, b, "b", limit, "") end)
      assert length(stmts) == 1, "one statement per page, got #{length(stmts)}"

      # story sync-stream-position (A-1): the read that now serves every incremental /sync and the head-bounded initial page
      head = T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

      for {label, fun} <- [
            range_after_the_hidden_bulk: fn -> apply(DB, :fetch_visible_events_in_range, [room, b, head - 4, head, limit]) end,
            page_bounded_by_the_head: fn -> apply(DB, :fetch_visible_events, [room, b, "b", limit, "", head]) end
          ] do
        {q, ps} = capture_marked_statement(fun)
        nodes = q |> explain!(ps, "ANALYZE, BUFFERS, FORMAT JSON") |> plan_nodes() |> Enum.filter(&(&1["Relation Name"] == "events"))
        refute Enum.any?(nodes, &(&1["Node Type"] == "Seq Scan")), "#{label}: no sequential scan of events"
        rows_read = Enum.sum(for n <- nodes, do: (n["Actual Rows"] + Map.get(n, "Rows Removed by Filter", 0)) * n["Actual Loops"])
        assert rows_read <= (segments + 1) * (limit + 1) + 20, "#{label}: read #{rows_read} rows of events, the 5 000 hidden ones are not scanned"
        {_r, stmts} = count_statements(fun)
        assert length(stmts) == 1, "#{label}: one statement"
      end

      # a device that synced BEFORE the hidden bulk reads the whole range: still one statement, bounded by the range, fast, and nothing hidden comes back
      {full_ms, {:ok, full}} = ms(fn -> apply(DB, :fetch_visible_events_in_range, [room, b, 0, head, limit]) end)
      assert Enum.take(Enum.map(full, & &1["event_id"]), 3) == Enum.reverse(shown)
      assert full_ms < 1_500, "the full range read took #{full_ms} ms over 5 000 hidden events"
    end

    test "(b) EXPLAIN of the single-event and the search statements: the segment inputs use events_room_state_idx" do
      room = raw_room!()
      a = T.provision_user!()
      put_hv_event!(room, a, "joined", 100)
      id = msg!(room, 150, a)
      put_join!(room, a, 50)
      put_row!(room, a, 50)

      for {label, fun} <- [single: fn -> DB.fetch_visible_event(id, room, a) end, search: fn -> SearchDB.search_messages(a, "x", 5, 0, []) end] do
        {query, params} = capture_marked_statement(fun)
        json = explain!(query, params, "FORMAT JSON")
        events_nodes = json |> plan_nodes() |> Enum.filter(&(&1["Relation Name"] == "events"))
        assert Enum.any?(events_nodes, &(&1["Index Name"] == "events_room_state_idx")), "#{label}: the hv / member inputs are index-served"
      end
    end
  end

  # EXPLAIN of a captured statement in a ROLLED-BACK privileged transaction: sequential scans off and every other non-unique index of `events` dropped there, so the plan shows whether the
  # two story indexes CAN serve the statement (the planner of a fixture would otherwise prefer a sequential scan or another room-prefixed index)
  defp explain!(query, params, options) do
    result =
      T.with_privileged_conn(fn conn ->
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "SET LOCAL enable_seqscan = off", [])

          %{rows: others} =
            Postgrex.query!(
              tx,
              "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'events'::regclass AND NOT i.indisunique AND c.relname NOT IN ('events_room_state_idx', 'events_room_id_ts_idx')",
              []
            )

          for [name] <- others, do: Postgrex.query!(tx, ~s(DROP INDEX "#{name}"), [])
          %{rows: [[json]]} = Postgrex.query!(tx, "EXPLAIN (#{options}) " <> query, params)
          Postgrex.rollback(tx, json)
        end)
      end)

    assert {:error, json} = result
    json
  end

  defp plan_nodes(json) do
    plan = json |> List.wrap() |> hd() |> Map.fetch!("Plan")
    collect(plan, [])
  end

  defp collect(%{} = node, acc) do
    acc = [node | acc]
    Enum.reduce(Map.get(node, "Plans", []), acc, &collect/2)
  end

  # the real statement of the call that carries the marker, with its parameters: `{query, params}`
  defp capture_marked_statement(fun) do
    id = "hv-explain-#{T.rand(6)}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:nebu, :repo, :query],
        fn _event, _measurements, %{query: query, params: params}, _config ->
          if String.contains?(query, "/* history_visibility */"), do: send(parent, {:hv_statement, query, params})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    assert_received {:hv_statement, query, params}
    {query, params}
  end

  # ═══ AC5 (f): the leave window equals what the fragment deems visible ══════════════════════════

  describe "AC5 (f) - the leave window of an incremental /sync" do
    test "joined, invited, shared: the leave window is exactly the interval, and every event of it is visible to F by the fragment" do
      for value <- ["joined", "invited", "shared"] do
        a = user!("HVA")
        f = user!("HVF")
        room = make_room(a, %{"preset" => "public_chat"})
        set_hv!(a, room, value)
        join_ev!(f, room)
        anchor = anchor_room!(f)
        token = snapshot!(f, anchor)
        before_leave = for i <- 1..3, do: say_m!(a, room, "w#{i}x")
        leave = leave_ev!(f, room)
        after_leave = say_m!(a, room, "after")

        body = sync(f, token)
        assert in_section?(body, "leave", room), "#{value}: the room is in rooms.leave"
        window = get_in(body, ["rooms", "leave", room, "timeline", "events"]) |> Enum.map(& &1["event_id"])

        # the interval of the window: from the first message to his leave
        first_ts = ts_of(hd(before_leave).id)
        leave_ts = ts_of(leave)

        interval =
          T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND origin_server_ts BETWEEN $2 AND $3", [room, first_ts, leave_ts]).rows
          |> Enum.map(&hd/1)

        fragment_visible = for id <- interval, match?({:ok, _}, DB.fetch_visible_event(id, room, f.uid)), do: id

        assert Enum.sort(fragment_visible) == Enum.sort(interval), "#{value}: no event of the interval is invisible to F (it lies inside his joined interval, rule 2)"
        assert Enum.sort(window) == Enum.sort(interval), "#{value}: the window is exactly the interval events (the messages, then his own leave)"
        assert window == Enum.map(before_leave, & &1.id) ++ [leave], "#{value}: in order"

        # after his leave the fragment itself denies outside shared / world_readable (the leave segment); the gates (403) deny it for every value
        assert match?({:ok, _}, DB.fetch_visible_event(after_leave.id, room, f.uid)) == (value == "shared"), "#{value}: the event after the leave"
        refute after_leave.id in window
      end
    end
  end

  # ═══ AC22 (12): the timestamp invariant ═════════════════════════════════════════════════════════

  describe "AC22 (12) - the origin_server_ts invariant (`gk`)" do
    test "a message stamped one ms before the latest hv change (simulated clock skew) is judged under the earlier setting: visible" do
      room = raw_room!()
      a = a_uid()
      g = a_uid()
      put_hv_event!(room, a, "shared", 1_000)
      put_hv_event!(room, a, "joined", 2_000)
      skewed = msg!(room, 1_999)
      same = msg!(room, 2_000)
      later = msg!(room, 2_001)
      put_join!(room, g, 3_000)

      # known Nebu invariant (follow-up `gk`): the message is judged in the `shared` segment
      assert_vis!(room, g, skewed, true, "stamped before the change (clock skew between nodes): visible, the documented outcome")
      assert_vis!(room, g, same, false, "same ms as the change")
      assert_vis!(room, g, later, false, "after the change")
    end

    test "an hv change after a future-dated message is stamped by the clock only, not after the message: no clamp for messages" do
      a = user!("HVA")
      room = make_room(a, %{"preset" => "private_chat"})
      # the future-dated rows are deleted in on_exit (follow-up `fj`: they break tick/0 of other suites); this test never calls tick/0 after inserting them
      Nebu.Matrix.MembershipStateTestSupport.cleanup_room_events_on_exit(room)
      latest_hv = room |> hv_rows() |> List.last()
      future = System.system_time(:millisecond) + 60_000
      future_msg = put_message!(room, uid_of(a), word("future"), future)

      hv_id = ok_event!(put_hv(a, room, "joined"), "hv after a future message")
      hv = Enum.find(hv_rows(room), &(&1.id == hv_id))

      assert hv.ts > latest_hv.ts, "stamped after the latest hv event of its slot (max(now, latest + 1))"
      assert hv.ts < future, "NOT clamped after the future message: no clamp for messages (known invariant, `gk`)"

      # so the future message lies AFTER the change: a viewer who joins after both (direct insert, also in the future) cannot see it
      b = a_uid()
      put_join!(room, b, future + 10)
      assert {:error, :not_found} = DB.fetch_visible_event(future_msg, room, b), "after the hv change, before his join: invisible"
      assert {:ok, _} = DB.fetch_visible_event(hv_id, room, b), "control: the hv event itself is visible (D5 (a): the setting before it allows)"
    end
  end

  defp hv_rows(room) do
    T.sql!("SELECT event_id, origin_server_ts FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = '' ORDER BY origin_server_ts, event_id", [room, hv_type()]).rows
    |> Enum.map(fn [id, ts] -> %{id: id, ts: ts} end)
  end
end
