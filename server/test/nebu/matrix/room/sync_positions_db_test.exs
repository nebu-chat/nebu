defmodule Nebu.Matrix.Room.SyncPositionsDbTest do
  @moduledoc """
  Real-database tests for story `sync-stream-position` (epic oauth-broker, follow-up `fc`, story 2 of 2), the DB reads of D4 / D5 / D10 / D12: `Room.DB` directly, events written with
  the real `Room.DB.insert_event/1` (the position trigger of story events-room-position stamps them) in OWN rooms with chosen timestamps, the real `Nebu.Repo`, NO fakes (a fake that
  returns pre-sorted rows proves nothing about the SQL). `async: false`.

  ## Contract choices of the ATDD step (the story names only some of these; the others are the smallest signature that fits it; the dev may not rename them)

    * `Room.DB.room_heads(room_ids, user_id, device_id)` (named by the story) -> `{:ok, %{room_id => %{head: integer, cursor: nil | %{gen, pos, class, invite_marker, prev_pos,
      prev_class, prev_invite_marker}}}}`: ONE statement for all rooms, a room without a `rooms` row is absent, `[]` costs no statement, only the cursor row of `(user_id, device_id)`.
    * `Room.DB.fetch_visible_events_in_range(room_id, viewer, after_pos, head, limit)` (named by the story) -> `{:ok, events}` of `after_pos < room_pos <= head`, the NEWEST
      `limit + 1` visible rows, newest first (by position, never by timestamp), a row without a position is never part of a range; the maps carry the string keys of `fetch_event/2`.
    * `Room.DB.leave_window_events(room_id, after_pos, before_pos, after_ts, before_ts)` (D10: the story says "by positions" and names no arity) -> `{:ok, events}`: `after_pos <
      room_pos < before_pos` AND `after_ts < origin_server_ts < before_ts` (all four strict; pass `0` and `9_223_372_036_854_775_807` for "unset"), the newest `21` rows, newest first
      (the caller keeps 20 and reads the 21st as `limited`, exactly like `fetch_visible_events_in_range/5`).
    * `Room.DB.fetch_visible_events(room_id, viewer, direction, limit, from_token, head)` (D12: "each initial room page is bounded by `room_pos <= head OR room_pos IS NULL`") -> the answer of
      the 5-argument read, bounded.

  The new functions are called through `apply/3` (`Room.DB` has none of them in the red state: a missing function is a runtime failure of the test, never a compile warning that
  `--warnings-as-errors` turns into a failed build). Positions and the cursor table are reached through SQL strings only.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.HistoryVisibilityTestSupport, only: [raw_room!: 0, put_message!: 4, put_hv_event!: 4, word: 1]
  import Nebu.Matrix.MembershipStateTestSupport, only: [count_statements: 1, put_member_id!: 7]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @max_ts 9_223_372_036_854_775_807
  @event_keys ["content", "event_id", "event_type", "origin_server_ts", "room_id", "sender", "state_key"]

  setup do
    Nebu.Matrix.MembershipStateTestSupport.setup_env!()
    :ok
  end

  # ─── the reads under test, through apply/3 ───────────────────────────────────

  defp heads(room_ids, user, device), do: apply(DB, :room_heads, [room_ids, user, device])
  defp range(room, viewer, after_pos, head, limit), do: apply(DB, :fetch_visible_events_in_range, [room, viewer, after_pos, head, limit])
  defp window(room, after_pos, before_pos, after_ts \\ 0, before_ts \\ @max_ts), do: apply(DB, :leave_window_events, [room, after_pos, before_pos, after_ts, before_ts])
  defp initial_page(room, viewer, head, limit \\ 20, from \\ "", dir \\ "b"), do: apply(DB, :fetch_visible_events, [room, viewer, dir, limit, from, head])

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp a_uid, do: "@spd#{T.rand(3)}:#{T.server_name()}"

  # n messages with strictly increasing timestamps (base + i); returns their ids in insertion (= position) order
  defp messages!(room, n, base \\ 1_000, sender \\ nil) do
    sender = sender || a_uid()
    for i <- 1..n, do: put_message!(room, sender, word("m"), base + i)
  end

  defp pos_of(id), do: T.sql!("SELECT room_pos FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd()
  defp head_of(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # a stored event of the story-1 era: no position (the trigger only fires on INSERT, so the update is allowed)
  defp unstamp!(ids), do: T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE event_id = ANY($1)", [ids])

  defp ids(events), do: Enum.map(events, & &1["event_id"])

  # a token row of a device (the cursor table references it)
  defp device!(uid, device) do
    T.sql!("INSERT INTO sync_tokens (user_id, device_id, since_token, updated_at) VALUES ($1, $2, 's2_atdd', $3) ON CONFLICT (user_id, device_id) DO NOTHING", [uid, device, System.system_time(:millisecond)])
    on_exit(fn -> T.sql!("DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, device]) end)
  end

  defp cursor!(uid, device, room, fields) do
    f = Map.merge(%{gen: 1, pos: 0, class: "join", invite_marker: nil, prev_pos: nil, prev_class: nil, prev_invite_marker: nil}, Map.new(fields))

    T.sql!(
      "INSERT INTO sync_room_cursors (user_id, device_id, room_id, gen, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
      [uid, device, room, f.gen, f.pos, f.class, f.invite_marker, f.prev_pos, f.prev_class, f.prev_invite_marker]
    )
  end

  # ═══ room_heads/3 (D4) ═════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "room_heads/3" do
    test "the head of each room is its rooms.event_pos (the highest position handed out), a room without events is 0, a cursor-less device has no cursor" do
      {r1, r2, r3} = {raw_room!(), raw_room!(), raw_room!()}
      messages!(r1, 3)
      messages!(r3, 5)
      uid = T.provision_user!()
      device!(uid, "D1")

      assert {:ok, map} = heads([r1, r2, r3], uid, "D1")
      assert map == %{r1 => %{head: 3, cursor: nil}, r2 => %{head: 0, cursor: nil}, r3 => %{head: 5, cursor: nil}}
      assert Enum.all?([r1, r2, r3], &(map[&1].head == head_of(&1)))
    end

    test "a room without a rooms row is absent from the answer (never a head of 0 for an unknown room)" do
      r1 = raw_room!()
      messages!(r1, 2)
      uid = T.provision_user!()

      assert {:ok, map} = heads([r1, "!nosuchroom#{T.rand(6)}:test.local"], uid, "")
      assert Map.keys(map) == [r1]
    end

    test "the cursor row carries all seven values: gen, pos, class, invite_marker and the three previous-generation values" do
      r1 = raw_room!()
      messages!(r1, 4)
      uid = T.provision_user!()
      device!(uid, "D1")
      cursor!(uid, "D1", r1, gen: 7, pos: 3, class: "invite", invite_marker: 1_234, prev_pos: 2, prev_class: "leave", prev_invite_marker: 99)

      assert {:ok, %{^r1 => %{head: 4, cursor: cursor}}} = heads([r1], uid, "D1")
      assert cursor == %{gen: 7, pos: 3, class: "invite", invite_marker: 1_234, prev_pos: 2, prev_class: "leave", prev_invite_marker: 99}
    end

    test "only the cursor of the asked (user, device) is returned: another device, another user and the device-less '' row never leak into the answer" do
      r1 = raw_room!()
      messages!(r1, 6)
      {u1, u2} = {T.provision_user!(), T.provision_user!()}
      for {u, d} <- [{u1, "D1"}, {u1, "D2"}, {u1, ""}, {u2, "D1"}], do: device!(u, d)
      cursor!(u1, "D1", r1, pos: 1)
      cursor!(u1, "D2", r1, pos: 2)
      cursor!(u1, "", r1, pos: 3)
      cursor!(u2, "D1", r1, pos: 4)

      for {u, d, expected} <- [{u1, "D1", 1}, {u1, "D2", 2}, {u1, "", 3}, {u2, "D1", 4}] do
        assert {:ok, %{^r1 => %{cursor: %{pos: ^expected}}}} = heads([r1], u, d)
      end

      assert {:ok, %{^r1 => %{cursor: nil}}} = heads([r1], u2, "D2"), "a (user, device) without a row has none, whatever the other keys hold"
      assert {:ok, %{^r1 => %{cursor: nil}}} = heads([r1], T.provision_user!(), "D1")
    end

    test "ONE statement for 1, 5 and 40 rooms; an empty room list costs none" do
      rooms = for _ <- 1..40, do: raw_room!()
      uid = T.provision_user!()
      device!(uid, "D1")

      for n <- [1, 5, 40] do
        {result, statements} = count_statements(fn -> heads(Enum.take(rooms, n), uid, "D1") end)
        assert {:ok, map} = result
        assert map_size(map) == n
        assert length(statements) == 1, "#{n} rooms ran #{length(statements)} statements:\n#{Enum.join(statements, "\n")}"
      end

      {result, statements} = count_statements(fn -> heads([], uid, "D1") end)
      assert result == {:ok, %{}}
      assert statements == [], "no rooms, no statement"
    end

    test "it is a read: calling it twice changes nothing (no cursor is created, no head moves)" do
      r1 = raw_room!()
      messages!(r1, 2)
      uid = T.provision_user!()
      device!(uid, "D1")
      assert {:ok, first} = heads([r1], uid, "D1")
      assert {:ok, ^first} = heads([r1], uid, "D1")
      assert T.sql!("SELECT count(*) FROM sync_room_cursors WHERE user_id = $1", [uid]).rows == [[0]]
    end
  end

  # ═══ fetch_visible_events_in_range/5 (D4, D5) ══════════════════════════════════════════════════════════════════════════════

  describe "fetch_visible_events_in_range/5" do
    test "the lower bound is exclusive and the head inclusive: positions 6..20 of 25 events, newest first" do
      room = raw_room!()
      evs = messages!(room, 25)

      assert {:ok, events} = range(room, a_uid(), 5, 20, 100)
      assert ids(events) == evs |> Enum.slice(5..19//1) |> Enum.reverse()
      assert Enum.map(ids(events), &pos_of/1) == Enum.to_list(20..6//-1)
    end

    test "limit + 1 rows: limit 20 over 30 events answers the NEWEST 21 (the caller keeps 20 and reads the 21st as limited), limit 5 over 3 events answers 3" do
      room = raw_room!()
      evs = messages!(room, 30)

      assert {:ok, events} = range(room, a_uid(), 0, 30, 20)
      assert length(events) == 21
      assert ids(events) == evs |> Enum.take(-21) |> Enum.reverse()

      room2 = raw_room!()
      evs2 = messages!(room2, 3)
      assert {:ok, events2} = range(room2, a_uid(), 0, 3, 5)
      assert ids(events2) == Enum.reverse(evs2)

      assert {:ok, exact} = range(room, a_uid(), 10, 30, 20)
      assert length(exact) == 20, "exactly 20 events in the range: no 21st row, not limited"
    end

    test "the order is the position (commit order), never the timestamp: a later position with an OLDER timestamp comes first" do
      room = raw_room!()
      sender = a_uid()
      first = put_message!(room, sender, word("a"), 3_000)
      second = put_message!(room, sender, word("b"), 2_000)
      third = put_message!(room, sender, word("c"), 1_000)

      assert {:ok, events} = range(room, a_uid(), 0, 3, 10)
      assert ids(events) == [third, second, first]
      assert Enum.map(events, & &1["origin_server_ts"]) == [1_000, 2_000, 3_000]
    end

    test "two events in the SAME millisecond are both returned, in position order" do
      room = raw_room!()
      sender = a_uid()
      a = put_message!(room, sender, word("a"), 5_000)
      b = put_message!(room, sender, word("b"), 5_000)

      assert {:ok, events} = range(room, a_uid(), 0, 2, 10)
      assert ids(events) == [b, a]
      assert {:ok, [only_b]} = range(room, a_uid(), 1, 2, 10)
      assert only_b["event_id"] == b
    end

    test "rows without a position (stored before story events-room-position) are never part of a range, whatever the bounds" do
      room = raw_room!()
      old = messages!(room, 3, 100)
      unstamp!(old)
      fresh = messages!(room, 2, 900)

      assert {:ok, events} = range(room, a_uid(), 0, 1_000, 100)
      assert ids(events) == Enum.reverse(fresh)
      assert Enum.all?(old, &(&1 not in ids(events)))
    end

    test "an empty range answers [] (head not above the lower bound), and the answer maps carry the string keys of fetch_event/2" do
      room = raw_room!()
      [e1, _e2] = messages!(room, 2)

      assert {:ok, []} = range(room, a_uid(), 2, 2, 10)
      assert {:ok, []} = range(room, a_uid(), 5, 2, 10)
      assert {:ok, [event]} = range(room, a_uid(), 0, 1, 10)
      assert event["event_id"] == e1
      for key <- @event_keys, do: assert(Map.has_key?(event, key), "the event map has #{key}")
      assert event["room_id"] == room and event["event_type"] == "m.room.message"
    end

    test "an event committed above the head read is NOT returned (the upper bound is the head that was read)" do
      room = raw_room!()
      evs = messages!(room, 3)
      head = head_of(room)
      late = put_message!(room, a_uid(), word("late"), 9_999)

      assert {:ok, events} = range(room, a_uid(), 0, head, 10)
      assert ids(events) == Enum.reverse(evs)
      assert {:ok, [only_late]} = range(room, a_uid(), head, head_of(room), 10)
      assert only_late["event_id"] == late
    end

    test "history visibility judges every candidate row by its timestamp; hidden rows do not count towards the limit" do
      room = raw_room!()
      owner = a_uid()
      viewer = a_uid()
      put_hv_event!(room, owner, "joined", 100)
      put_member_id!(room, owner, "join", owner, 50, "$" <> T.rand(12), %{})
      hidden1 = put_message!(room, owner, word("h1"), 150)
      visible1 = put_message!(room, owner, word("v1"), 250)
      put_member_id!(room, viewer, "join", viewer, 200, "$" <> T.rand(12), %{})
      hidden2 = put_message!(room, owner, word("h2"), 160)
      visible2 = put_message!(room, owner, word("v2"), 300)
      hidden3 = put_message!(room, owner, word("h3"), 170)
      head = head_of(room)

      assert {:ok, for_viewer} = range(room, viewer, 0, head, 100)
      viewer_ids = ids(for_viewer)
      assert visible2 in viewer_ids and visible1 in viewer_ids
      assert Enum.all?([hidden1, hidden2, hidden3], &(&1 not in viewer_ids)), "events from before the viewer's join are hidden under joined"
      assert Enum.find_index(viewer_ids, &(&1 == visible2)) < Enum.find_index(viewer_ids, &(&1 == visible1)), "still newest position first"

      # the hidden rows sit between the visible ones by position (hidden3 is the newest row of all): with limit 1 the answer is the newest TWO VISIBLE rows
      assert {:ok, two} = range(room, viewer, 0, head, 1)
      assert length(two) == 2, "limit 1 + 1 look-ahead row, hidden rows are not counted"
      assert ids(two) == Enum.take(viewer_ids, 2)
      assert hd(ids(two)) == visible2
      assert Enum.all?([hidden1, hidden2, hidden3], &(&1 not in ids(two)))

      # the owner (joined before everything) sees all of them
      assert {:ok, for_owner} = range(room, owner, 0, head, 100)
      assert Enum.all?([hidden1, hidden2, hidden3, visible1, visible2], &(&1 in ids(for_owner)))
    end
  end

  # ═══ leave_window_events by positions (D10) ════════════════════════════════════════════════════════════════════════════════

  describe "leave_window_events/5" do
    test "both position bounds are strict: (3, 20) of 25 events answers positions 19 down to 4, nothing at or after the leave position" do
      room = raw_room!()
      evs = messages!(room, 25)

      assert {:ok, events} = window(room, 3, 20)
      assert ids(events) == evs |> Enum.slice(3..18//1) |> Enum.reverse()
      assert Enum.map(ids(events), &pos_of/1) == Enum.to_list(19..4//-1)
      refute Enum.at(evs, 19) in ids(events), "the event AT the leave position is not part of the window"
      refute Enum.at(evs, 20) in ids(events)
    end

    test "the NEWEST 21 rows: a window of 40 events answers positions 39..19 (the caller keeps 20 and reads the 21st as limited)" do
      room = raw_room!()
      messages!(room, 40)
      assert {:ok, events} = window(room, 0, 41)
      assert Enum.map(ids(events), &pos_of/1) == Enum.to_list(40..20//-1)
      assert length(events) == 21

      assert {:ok, exactly} = window(room, 20, 41)
      assert length(exactly) == 20
    end

    test "the clock bounds are strict and only SHRINK the window: an event inside the positions but at / beyond a bound is excluded, never the reverse" do
      room = raw_room!()
      evs = messages!(room, 10, 1_000)
      # timestamps 1001..1010 at positions 1..10
      assert {:ok, plain} = window(room, 0, 11)
      assert length(plain) == 10

      assert {:ok, after_clock} = window(room, 0, 11, 1_003, @max_ts)
      assert Enum.map(ids(after_clock), &pos_of/1) == Enum.to_list(10..4//-1), "origin_server_ts > joined_at, strict: 1003 itself is excluded"

      assert {:ok, before_clock} = window(room, 0, 11, 0, 1_008)
      assert Enum.map(ids(before_clock), &pos_of/1) == Enum.to_list(7..1//-1), "origin_server_ts < left_at, strict: 1008 itself is excluded"

      assert {:ok, both} = window(room, 2, 9, 1_003, 1_008)
      assert Enum.map(ids(both), &pos_of/1) == [7, 6, 5, 4]
      assert Enum.at(evs, 0) not in ids(both)
    end

    test "under skew a timestamp beyond left_at stays out, a timestamp below it never brings back an event at or after the leave position" do
      room = raw_room!()
      sender = a_uid()
      before_leave = put_message!(room, sender, word("b"), 5_000)
      skewed = put_message!(room, sender, word("s"), 1_000)
      leave_pos_event = put_message!(room, sender, word("l"), 6_000)
      after_leave_old_ts = put_message!(room, sender, word("a"), 500)
      leave_pos = pos_of(leave_pos_event)

      assert {:ok, events} = window(room, 0, leave_pos, 0, 4_000)
      assert ids(events) == [skewed], "left_at 4000: the event stamped 5000 is outside, the skewed 1000 inside"
      assert {:ok, wide} = window(room, 0, leave_pos, 0, @max_ts)
      assert ids(wide) == [skewed, before_leave]
      refute after_leave_old_ts in ids(wide), "an event AFTER the leave position is never read, however old its timestamp"
      refute leave_pos_event in ids(wide)
    end

    test "rows without a position are never part of a window, and the answer maps carry the string keys of fetch_event/2" do
      room = raw_room!()
      old = messages!(room, 3, 100)
      unstamp!(old)
      fresh = messages!(room, 3, 900)

      assert {:ok, events} = window(room, 0, 10)
      assert ids(events) == Enum.reverse(fresh)
      for key <- @event_keys, do: assert(Map.has_key?(hd(events), key))
    end

    test "an empty window answers [] and a window of another room never leaks in" do
      room = raw_room!()
      other = raw_room!()
      messages!(room, 3)
      messages!(other, 3)
      assert {:ok, []} = window(room, 3, 4)
      assert {:ok, []} = window(room, 1, 2)
      assert {:ok, events} = window(room, 0, 4)
      assert Enum.all?(events, &(&1["room_id"] == room))
    end
  end

  # ═══ the partition read carries positions (D9, D10) ═══════════════════════════════════════════════════════════════════════════

  describe "latest_member_events/2 - L and P carry the room_pos of their events" do
    test "L and P have their positions; an event stored before story events-room-position has room_pos nil" do
      room = raw_room!()
      user = a_uid()
      p_id = put_member_id!(room, user, "join", user, 100, "$p" <> T.rand(8), %{})
      messages!(room, 2, 150)
      l_id = put_member_id!(room, user, "leave", user, 300, "$l" <> T.rand(8), %{})

      assert {:ok, %{^room => [l, p]}} = DB.latest_member_events([room], user)
      assert {l.event_id, l.membership, l.room_pos} == {l_id, "leave", pos_of(l_id)}
      assert {p.event_id, p.membership, p.room_pos} == {p_id, "join", pos_of(p_id)}
      assert l.room_pos > p.room_pos

      unstamp!([l_id])
      assert {:ok, %{^room => [l2, _p2]}} = DB.latest_member_events([room], user)
      assert l2.event_id == l_id and l2.room_pos == nil, "a legacy event has no position (it is never a NEW leave, D9)"
    end
  end

  # ═══ the initial page bound (D12) ══════════════════════════════════════════════════════════════════════════════════════════

  describe "fetch_visible_events/6 (initial page bound)" do
    test "an event above the head is not on the page (it comes with the next delta), the events up to the head are" do
      room = raw_room!()
      evs = messages!(room, 10)

      assert {:ok, events, _next, _prev} = initial_page(room, a_uid(), 6)
      assert ids(events) == evs |> Enum.take(6) |> Enum.reverse()
      assert Enum.map(ids(events), &pos_of/1) == Enum.to_list(6..1//-1)
    end

    test "events without a position (stored before story events-room-position) stay on the page; stamped ones above the head do not" do
      room = raw_room!()
      old = messages!(room, 3, 100)
      unstamp!(old)
      fresh = messages!(room, 4, 900)

      head = pos_of(Enum.at(fresh, 1))
      assert head > 3, "the counter of the room did not restart after the positions were removed: the new events continue above it"
      assert {:ok, events, _next, _prev} = initial_page(room, a_uid(), head)
      assert ids(events) == Enum.reverse(old ++ Enum.take(fresh, 2))
    end

    test "the bound holds on later pages of a backward read as well (from_token), and a limit still pages normally" do
      room = raw_room!()
      evs = messages!(room, 10)

      assert {:ok, page1, next, _prev} = initial_page(room, a_uid(), 8, 5)
      assert ids(page1) == evs |> Enum.slice(3..7//1) |> Enum.reverse()
      assert next != ""
      assert {:ok, page2, _next2, _} = initial_page(room, a_uid(), 8, 5, next)
      assert ids(page2) == evs |> Enum.take(3) |> Enum.reverse()
    end

    test "a head at or above the room's head changes nothing; the 5-argument read is still the unbounded one" do
      room = raw_room!()
      evs = messages!(room, 4)
      assert {:ok, bounded, _, _} = initial_page(room, a_uid(), 4)
      assert {:ok, unbounded, _, _} = DB.fetch_visible_events(room, a_uid(), "b", 20, "")
      assert ids(bounded) == ids(unbounded)
      assert ids(bounded) == Enum.reverse(evs)
    end
  end
end
