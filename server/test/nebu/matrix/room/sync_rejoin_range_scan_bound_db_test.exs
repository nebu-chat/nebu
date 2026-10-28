defmodule Nebu.Matrix.Room.SyncRejoinRangeScanBoundDbTest do
  @moduledoc """
  Real-database tests for story `sync-rejoin-range-scan-bound` (epic oauth-broker, follow-up `cq` (f), Kassandra MEDIUM-1b, REQ-2026-006), the SQL half: D1 / D2 (the segmented range read
  `Room.DB.fetch_visible_events_in_range_segmented/5`), D7 (1) (the row probe), D7 (3) (the skew-boundary pair) and the differential test of D10 (1). `Room.DB` directly, events written
  with the real `Room.DB.insert_event/1` (the position trigger of story events-room-position stamps them) in OWN rooms with chosen timestamps, the real `Nebu.Repo`, NO fakes (a fake that
  returns pre-sorted rows proves nothing about the SQL). `async: false`.

  ## Contract (the story names the function; the rest is what these tests need and pin)

    * `Room.DB.fetch_visible_events_in_range_segmented(room_id, viewer, after_pos, head, limit)` -> `{:ok, newest_first}` with EXACTLY the answer of `fetch_visible_events_in_range/5` (the
      NEWEST `limit + 1` visible events with `after_pos < room_pos <= head`, newest first by POSITION, the seven string keys of the plain read), ONE statement carrying the history-visibility
      marker, every value a bound parameter. It is not a `DBBehaviour` callback. Called through `apply/3` (the function is looked up at runtime, so the file compiles without warnings whatever the module exports).
    * `after_pos = 0` has no event to anchor the time floor: the read is the plain range `(0, head]` (no floor, never a legacy event).
    * The time floor is `min(origin_server_ts)` of the 64 events with the HIGHEST `room_pos <= after_pos` (any event, visible or not), applied to ORDINARY events as `origin_server_ts >= floor`
      (inclusive); a special event (an hv state event, a member event of the viewer) is not floored. The skew-boundary pair pins the 64 and the inclusive bound from both sides.
    * Ordinary events of one millisecond are cut in POSITION order (the plain read orders by position, so a pile of events stamped in one millisecond must not be cut by `event_id`).

  ## Test design

    * The row probe sets `SET LOCAL enable_seqscan = off` and pins `plan_cache_mode` (custom / generic) inside its transaction, and runs with stale and with fresh table statistics: on a
      fixture-sized `events` table the planner flaps between index and sequential scans, and the statement is a named prepared statement that PostgreSQL may re-plan generically after five
      executions on a connection. Measured: the N = 600 read counted 850 rows in one run and 138 in the next (sequential scan), and an unfenced draft read 4 293 / 2 843 / 603 rows in
      single regimes. The probe asks "does the statement NEED to touch the hidden rows" under every plan the planner can pick. With the settings pinned the counters are exactly reproducible.
    * The differential test compares with the plain read as the oracle on fixtures WITHOUT skew (strictly increasing timestamps in position order, plus fixtures where hv changes, joins,
      leaves and messages share ONE millisecond); skew fixtures document the residuals.
    * Accepted residuals, pinned as fixtures: (1) the D2 (iv) floor residual (a late commit older than all events of the floor window is not read);
      (2) the segment-order residual: when a visible segment holds at least `limit + 1` events that are NEWER BY TIMESTAMP, a late commit with the highest position but an old timestamp
      (inside the lookback) is not read: the cut inside a segment is by timestamp, the final cut by position; it happens only in a `limited` window and the event stays reachable through
      `/messages` (timestamp order), same class as follow-up `cq` (b); (3) a gap in the floor window (a legacy event without a position, or a deleted event) leaves FEWER rows in the window
      and therefore a HIGHER floor; nothing is lost without skew (the floor is a window of POSITIONS, `after_pos - 63 .. after_pos`); an EMPTY window falls back to the oldest timestamp of the
      next 64 events above the base, so the floor never disappears (the walk over the delivered history stays bounded).
    * The row probes run `ANALYZE events` (stale / fresh statistics regimes): a global, harmless side effect on the shared test database; every probe is run to completion in one test.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.HistoryVisibilityTestSupport, only: [raw_room!: 0, put_message!: 4, put_message!: 5, put_hv_event!: 4, word: 1]
  import Nebu.Matrix.MembershipStateTestSupport, only: [count_statements: 1, put_member_id!: 7]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 600_000

  @event_keys ["content", "event_id", "event_type", "origin_server_ts", "room_id", "sender", "state_key"]

  setup do
    Nebu.Matrix.MembershipStateTestSupport.setup_env!()
    :ok
  end

  # ─── the reads under test ────────────────────────────────────────────────────

  defp seg(room, viewer, after_pos, head, limit), do: apply(DB, :fetch_visible_events_in_range_segmented, [room, viewer, after_pos, head, limit])
  defp plain(room, viewer, after_pos, head, limit), do: apply(DB, :fetch_visible_events_in_range, [room, viewer, after_pos, head, limit])

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp uid(label), do: "@#{label}#{T.rand(4)}:#{T.server_name()}"
  defp pos_of(id), do: T.sql!("SELECT room_pos FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd()
  defp ts_of(id), do: T.sql!("SELECT origin_server_ts FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd()
  defp head_of(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp ids(events), do: Enum.map(events, & &1["event_id"])
  defp ids_at(room, lo, hi), do: T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, lo, hi]).rows |> Enum.map(&hd/1)
  defp unstamp!(ids), do: T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE event_id = ANY($1)", [ids])

  defp member!(room, who, membership, sender, ts), do: put_member_id!(room, who, membership, sender, ts, "$" <> T.rand(12), %{})

  # A scripted room: steps in order, every event stamped with a strictly increasing timestamp (10 ms apart), so position order == timestamp order (no skew).
  #   {:hv, value} {:join, who} {:leave, who} {:invite, who} {:msgs, n}    who is :a (the creator, joined first) or :b (the viewer) or :c
  #   {:same_ms, [step, ...]}  the steps are written in order with ONE timestamp (an hv change, a membership change and a message in the same millisecond)
  # Returns %{room, a, b, c, head, msgs: [event ids written by {:msgs, _} in order], steps: [{step, [event ids]}]}.
  defp build!(steps) do
    room = raw_room!()
    users = %{a: uid("rja"), b: uid("rjb"), c: uid("rjc")}

    write = fn
      {:hv, v}, ts, _gap -> [put_hv_event!(room, users.a, v, ts)]
      {:join, who}, ts, _gap -> [member!(room, users[who], "join", users[who], ts)]
      {:leave, who}, ts, _gap -> [member!(room, users[who], "leave", users[who], ts)]
      {:invite, who}, ts, _gap -> [member!(room, users[who], "invite", users.a, ts)]
      {:msgs, n}, ts, gap -> for(i <- 0..(n - 1)//1, do: put_message!(room, users.a, word("m"), ts + i * gap))
    end

    {_ts, logs} =
      Enum.reduce(steps, {1_000, []}, fn step, {ts, acc} ->
        {ids, ts2} =
          case step do
            {:msgs, n} -> {write.(step, ts, 10), ts + n * 10}
            {:same_ms, subs} -> {Enum.flat_map(subs, &write.(&1, ts, 0)), ts + 10}
            _ -> {write.(step, ts, 10), ts + 10}
          end

        {ts2, [{step, ids} | acc]}
      end)

    steps = Enum.reverse(logs)
    msgs = for {{:msgs, _}, ids} <- steps, id <- ids, do: id
    Map.merge(users, %{room: room, head: head_of(room), msgs: msgs, steps: steps})
  end

  defp event_id_of(%{steps: steps}, index), do: steps |> Enum.at(index) |> elem(1) |> hd()

  # `seq_tup_read + idx_tup_fetch` of `events` for the statement(s) `fun` runs, measured in ONE transaction of the pool (per-transaction counters, updated immediately), sequential scans
  # off and the plan cache mode pinned (see the moduledoc); `no_bitmap: true` also switches bitmap scans off: `{result, rows}`
  defp measured(fun, plan_cache_mode, no_bitmap \\ false) do
    {:ok, out} =
      Nebu.Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_seqscan = off", [])
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL plan_cache_mode = #{plan_cache_mode}", [])
        if no_bitmap, do: Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_bitmapscan = off", [])
        before = rows_read()
        result = fun.()
        {result, rows_read() - before}
      end)

    out
  end

  defp rows_read do
    %{rows: [[n]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT COALESCE(sum(seq_tup_read + idx_tup_fetch), 0)::bigint FROM pg_stat_xact_user_tables WHERE relname = 'events'", [])
    n
  end

  # the hidden-stretch fixture of D7 (1): hv `joined`; `b` joined, the SAME 70 messages, `b` leaves, `n` events are written while `b` is away, `b` re-joins, `visible` messages follow.
  # base = the position of the leave event (the cursor of a device that synced the leave)
  defp away!(n, visible \\ 3) do
    room = raw_room!()
    {a, b} = {uid("rja"), uid("rjb")}
    put_hv_event!(room, a, "joined", 100)
    member!(room, a, "join", a, 105)
    member!(room, b, "join", b, 110)
    for i <- 1..70, do: put_message!(room, a, word("m"), 1_000 + i)
    leave = member!(room, b, "leave", b, 2_000)
    base = pos_of(leave)

    T.privileged_sql!(
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
      SELECT '$away' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'hidden' || g), 3000 + g, NULL
      FROM generate_series(1, $3::int) AS g
      """,
      [room, a, n]
    )

    join = member!(room, b, "join", b, 100_000)
    shown = for i <- 1..visible, do: put_message!(room, a, word("v"), 100_010 + i)
    %{room: room, a: a, b: b, base: base, head: head_of(room), join: join, shown: shown}
  end

  # ═══ contract ══════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "the function (D1, D5)" do
    test "Room.DB exports fetch_visible_events_in_range_segmented/5 and it is NOT a DBBehaviour callback (as the other position reads)" do
      assert function_exported?(DB, :fetch_visible_events_in_range_segmented, 5)
      callbacks = Nebu.Matrix.Room.DBBehaviour.behaviour_info(:callbacks)
      refute {:fetch_visible_events_in_range_segmented, 5} in callbacks
      refute {:fetch_visible_events_in_range, 5} in callbacks
    end

    test "the answer has the shape of the plain read: {:ok, newest first by position}, the seven string keys, at most limit + 1 events" do
      f = build!([{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 10}])
      assert {:ok, events} = seg(f.room, f.b, 0, f.head, 4)
      assert length(events) == 5, "limit + 1 rows: the caller delivers limit and reads the extra one as `limited`"
      assert Enum.all?(events, &(Enum.sort(Map.keys(&1)) == @event_keys)), "the keys of the plain read, no extra column"
      assert events |> ids() |> Enum.map(&pos_of/1) == events |> ids() |> Enum.map(&pos_of/1) |> Enum.sort(:desc), "newest first by position"
      assert {:ok, ^events} = plain(f.room, f.b, 0, f.head, 4)
    end

    test "one statement, with the history-visibility marker, and neither the room id nor the viewer in the statement text" do
      f = away!(5)
      {result, statements} = count_statements(fn -> seg(f.room, f.b, f.base, f.head, 20) end)
      assert {:ok, [_ | _]} = result
      assert length(statements) == 1, "ONE statement (the floor probe and the specials are inside it), got #{length(statements)}"
      [sql] = statements
      assert sql =~ "/* history_visibility */", "the same fragment as every viewer-aware read"
      refute String.contains?(sql, f.room) or String.contains?(sql, f.b), "no value in the statement text"
    end

    test "after_pos at or above head answers {:ok, []}, below it the events" do
      f = away!(5)
      assert {:ok, []} = seg(f.room, f.b, f.head, f.head, 20)
      assert {:ok, []} = seg(f.room, f.b, f.head + 5, f.head, 20)
      assert {:ok, [_ | _]} = seg(f.room, f.b, f.base, f.head, 20)
    end
  end

  # ═══ D2: the bounds ═════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D2 (i) (ii): the position bounds of BOTH branches" do
    test "the lower bound is exclusive and the upper bound inclusive, for ordinary events" do
      f = build!([{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 12}])
      [_m1, m2, m3, m4, m5 | _] = f.msgs
      {low, high} = {pos_of(m2), pos_of(m5)}

      assert {:ok, events} = seg(f.room, f.b, low, high, 50)
      assert ids(events) == [m5, m4, m3], "(low, high]: m2 (the base) is out, m5 (the head) is in"
    end

    test "an event above the head is not returned (D12 exactness: it comes with the next sync), however visible" do
      f = build!([{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 6}])
      head = pos_of(Enum.at(f.msgs, 3))
      assert {:ok, events} = seg(f.room, f.b, 0, head, 50)
      assert hd(ids(events)) == Enum.at(f.msgs, 3)
      assert Enum.all?(ids(events), &(pos_of(&1) <= head))
    end

    test "the viewer's own member events and the hv state events (the SPECIAL branch) obey the same two bounds" do
      f =
        build!([{:join, :a}, {:join, :b}, {:hv, "shared"}, {:msgs, 2}, {:hv, "joined"}, {:msgs, 2}, {:leave, :b}, {:msgs, 2}, {:join, :b}, {:msgs, 2}, {:leave, :b}, {:join, :b}, {:msgs, 1}])

      [_ja, jb1, hv1, _m, hv2, _m2, lv1, _m3, jb2, _m4, lv2, jb3, _m5] = Enum.map(f.steps, fn {_step, step_ids} -> hd(step_ids) end)

      # base = lv1, head = lv2: the specials strictly inside are jb2 and lv2 (the viewer's own events, visible by D5); jb1, hv1, hv2 and lv1 are at or below the base, jb3 above the head
      assert {:ok, events} = seg(f.room, f.b, pos_of(lv1), pos_of(lv2), 50)
      assert jb2 in ids(events) and lv2 in ids(events), "both specials inside (base, head] are returned"
      refute Enum.any?([jb1, hv1, hv2, lv1], &(&1 in ids(events))), "a member / hv event at or below the base is not returned (delivered, or hidden when the cursor was written)"
      refute jb3 in ids(events), "a member event above the head is not returned"
      assert {:ok, ^events} = plain(f.room, f.b, pos_of(lv1), pos_of(lv2), 50)

      # the hv state event is bounded on both sides as well: base just below it returns it, base AT it does not, a head below it does not
      assert {:ok, with_hv} = seg(f.room, f.b, pos_of(hv2) - 1, pos_of(hv2) + 1, 50)
      assert hv2 in ids(with_hv)
      assert {:ok, at_hv} = seg(f.room, f.b, pos_of(hv2), pos_of(hv2) + 1, 50)
      refute hv2 in ids(at_hv)
      assert {:ok, below_hv} = seg(f.room, f.b, 0, pos_of(hv2) - 1, 50)
      refute hv2 in ids(below_hv)

      for {base, head} <- [{pos_of(hv2) - 1, pos_of(hv2) + 1}, {pos_of(hv2), pos_of(hv2) + 1}, {0, pos_of(hv2) - 1}] do
        assert seg(f.room, f.b, base, head, 50) == plain(f.room, f.b, base, head, 50)
      end
    end

    test "a legacy event without a position is never part of a position range (no `OR room_pos IS NULL`)" do
      f = build!([{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 8}])
      [m1, m2, m3 | _] = f.msgs
      unstamp!([m2])

      assert {:ok, events} = seg(f.room, f.b, 0, f.head, 50)
      refute m2 in ids(events), "an unpositioned event is not returned, whatever its timestamp"
      assert m1 in ids(events) and m3 in ids(events)
      assert {:ok, ^events} = plain(f.room, f.b, 0, f.head, 50)
    end
  end

  describe "D2 (iii): LIMIT limit + 1, per segment and at the end, cut in POSITION order" do
    test "several visible segments, more than limit + 1 events: the newest limit + 1 by position, as the plain read" do
      f = build!([{:hv, "joined"}, {:join, :a}, {:join, :b}, {:msgs, 7}, {:leave, :b}, {:msgs, 5}, {:join, :b}, {:msgs, 6}, {:leave, :b}, {:msgs, 4}, {:join, :b}, {:msgs, 7}])
      for limit <- [1, 2, 3, 5, 20] do
        assert {:ok, events} = seg(f.room, f.b, 0, f.head, limit)
        assert length(events) == limit + 1
        assert {:ok, ^events} = plain(f.room, f.b, 0, f.head, limit)
      end
    end

    test "30 events of one millisecond are cut by position, not by event id (ids opposite to the positions)" do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      # position order p1 < p2 < ...; the event ids are in the REVERSE order ("...29" is written first and has the highest id, "...00" last and has the lowest; a per-run infix keeps the global event ids unique)
      infix = T.rand(6)
      written = for i <- 0..29, do: put_message!(room, a, word("t"), 5_000, "$tie" <> infix <> String.pad_leading(Integer.to_string(29 - i), 2, "0"))
      head = head_of(room)

      assert {:ok, events} = seg(room, b, 0, head, 10)
      assert ids(events) == written |> Enum.reverse() |> Enum.take(11), "the newest 11 by POSITION (the last written first), not the 11 highest event ids"
      assert {:ok, ^events} = plain(room, b, 0, head, 10)
    end
  end

  # ═══ D10 (1): the differential test against the plain range read ═════════════════════════════════════════════════════════════

  @fixtures [
    {"joined, one re-join", [{:hv, "joined"}, {:join, :a}, {:join, :b}, {:msgs, 5}, {:leave, :b}, {:msgs, 7}, {:join, :b}, {:msgs, 4}]},
    {"shared, one re-join", [{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 5}, {:leave, :b}, {:msgs, 7}, {:join, :b}, {:msgs, 4}]},
    {"world_readable, one re-join", [{:hv, "world_readable"}, {:join, :a}, {:join, :b}, {:msgs, 5}, {:leave, :b}, {:msgs, 7}, {:join, :b}, {:msgs, 4}]},
    {"invited: invite -> join -> leave -> invite -> join",
     [{:hv, "invited"}, {:join, :a}, {:msgs, 2}, {:invite, :b}, {:msgs, 3}, {:join, :b}, {:msgs, 2}, {:leave, :b}, {:msgs, 3}, {:invite, :b}, {:msgs, 2}, {:join, :b}, {:msgs, 2}]},
    {"joined: invite -> join -> leave -> invite -> join",
     [{:hv, "joined"}, {:join, :a}, {:msgs, 2}, {:invite, :b}, {:msgs, 3}, {:join, :b}, {:msgs, 2}, {:leave, :b}, {:msgs, 3}, {:invite, :b}, {:msgs, 2}, {:join, :b}, {:msgs, 2}]},
    {"joined, three re-joins",
     [{:hv, "joined"}, {:join, :a}, {:join, :b}, {:msgs, 2}, {:leave, :b}, {:msgs, 2}, {:join, :b}, {:msgs, 2}, {:leave, :b}, {:msgs, 3}, {:join, :b}, {:msgs, 1}, {:leave, :b}, {:msgs, 2}, {:join, :b}, {:msgs, 2}]},
    {"mixed: the setting changes under the viewer",
     [
       {:hv, "shared"}, {:join, :a}, {:msgs, 3}, {:join, :b}, {:msgs, 2}, {:hv, "joined"}, {:msgs, 3}, {:leave, :b}, {:msgs, 3}, {:hv, "invited"}, {:msgs, 2}, {:invite, :b}, {:msgs, 2},
       {:hv, "shared"}, {:msgs, 2}, {:join, :b}, {:hv, "joined"}, {:msgs, 3}
     ]},
    {"same ms, joined (leave + message, message + join)",
     [{:hv, "joined"}, {:join, :a}, {:join, :b}, {:msgs, 3}, {:same_ms, [{:leave, :b}, {:msgs, 1}]}, {:msgs, 3}, {:same_ms, [{:msgs, 1}, {:join, :b}]}, {:msgs, 2}]},
    {"same ms, invited (invite / join / leave + message)",
     [
       {:hv, "invited"}, {:join, :a}, {:msgs, 2}, {:same_ms, [{:msgs, 1}, {:invite, :b}]}, {:msgs, 2}, {:same_ms, [{:join, :b}, {:msgs, 1}]}, {:same_ms, [{:leave, :b}, {:msgs, 1}]}, {:msgs, 2},
       {:same_ms, [{:invite, :b}, {:msgs, 1}]}, {:msgs, 1}, {:join, :b}, {:msgs, 2}
     ]},
    {"same ms, shared (hv change + message + leave / join)",
     [{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 2}, {:same_ms, [{:hv, "joined"}, {:msgs, 1}, {:leave, :b}]}, {:msgs, 2}, {:same_ms, [{:join, :b}, {:hv, "shared"}, {:msgs, 1}]}, {:msgs, 2}]},
    {"joined, a long history (170 events, bases above 64)",
     [{:hv, "joined"}, {:join, :a}, {:join, :b}, {:msgs, 80}, {:leave, :b}, {:msgs, 90}, {:join, :b}, {:msgs, 6}, {:leave, :b}, {:msgs, 4}, {:invite, :b}, {:msgs, 3}, {:join, :b}, {:msgs, 5}]}
  ]

  describe "D10 (1) differential vs the plain range read (the oracle), no skew" do
    for {label, steps} <- @fixtures do
      test "#{label}: viewers a, b, c; limits 3 and 20; every base" do
        f = build!(unquote(Macro.escape(steps)))
        bases = if f.head > 60, do: Enum.uniq([0, 1, 2, 3, f.head - 1, f.head] ++ Enum.to_list(63..f.head//9)), else: Enum.to_list(0..f.head)

        for viewer <- [f.a, f.b, f.c], base <- bases, limit <- [3, 20] do
          assert {:ok, expected} = plain(f.room, viewer, base, f.head, limit)
          assert {:ok, actual} = seg(f.room, viewer, base, f.head, limit)
          assert actual == expected, "#{unquote(label)}: viewer #{String.slice(viewer, 0, 5)}, base #{base}, head #{f.head}, limit #{limit}: the segmented read differs from the plain read"
        end

        # an inner head too (the head READ is the bound): every head above a mid base
        mid = div(f.head, 2)
        for head <- [mid + 1, mid + 3, f.head - 1], head > mid do
          assert seg(f.room, f.b, mid, head, 20) == plain(f.room, f.b, mid, head, 20)
        end
      end
    end

    test "teeth: on the re-join fixture the answer is neither empty nor everything (hidden rows are skipped)" do
      f = build!(Enum.at(@fixtures, 0) |> elem(1))
      lv = f.steps |> Enum.find(&match?({{:leave, :b}, _}, &1)) |> elem(1) |> hd()
      assert {:ok, events} = seg(f.room, f.b, pos_of(lv), f.head, 50)
      total = f.head - pos_of(lv)
      assert length(events) == 5 and total == 12, "the re-join event and the 4 later messages of the 12 events above the base (the 7 written while away are hidden): #{length(events)} of #{total}"
    end
  end

  # ═══ D2 (iv): the time floor — the skew-boundary pair ═══════════════════════════════════════════════════════════════════════

  describe "D2 (iv) the time floor: min ts of the 64 newest events at the base" do
    # 80 positioned messages 1 s apart (ts(i) = 1_000_000 + 1_000 * i, i = 1..80) in a shared room; the viewer is joined; base = the position of message 80, so the 64 newest events at the base are
    # messages 17..80 (the floor is ts(17)); the events are written, then LATE events are committed after the base with chosen timestamps
    defp skew_room! do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      msgs = for i <- 1..80, do: put_message!(room, a, word("m"), 1_000_000 + 1_000 * i)
      # the room has hv + 2 joins + 80 messages: the 64 newest events at the base are exactly messages 17..80
      %{room: room, a: a, b: b, msgs: msgs, base: pos_of(List.last(msgs)), floor_ts: 1_000_000 + 1_000 * 17}
    end

    defp late!(f, ts), do: put_message!(f.room, f.a, word("late"), ts)

    test "a late commit stamped 1 s BEFORE the base event (inside the lookback) is delivered" do
      f = skew_room!()
      late = late!(f, ts_of(List.last(f.msgs)) - 1_000)
      new = put_message!(f.room, f.a, word("new"), 2_000_000)
      head = head_of(f.room)

      assert {:ok, events} = seg(f.room, f.b, f.base, head, 20)
      assert ids(events) == [new, late], "the late commit (a lower timestamp, a higher position) and the new event, newest position first"
    end

    test "the floor is inclusive, the lookback exactly 64: ts(17) is delivered, ts(17) - 1 is not (residual)" do
      f = skew_room!()
      at_floor = late!(f, f.floor_ts)
      below = late!(f, f.floor_ts - 1)
      head = head_of(f.room)

      assert {:ok, events} = seg(f.room, f.b, f.base, head, 20)
      assert at_floor in ids(events), "origin_server_ts >= floor (inclusive)"
      refute below in ids(events), "older than the oldest of the 64 newest events at the cursor: the documented residual of cq (b) (reachable by /messages)"
    end

    test "the lookback counts the 64 newest POSITIONS at the base: an old-stamped one lowers the floor" do
      f = skew_room!()
      # an OLD-stamped event (ts 1) that already existed BEFORE the base, but with a position among the 64 newest at the base, moves the floor down to its timestamp
      old_at_base = put_message!(f.room, f.a, word("old"), 1)
      base = pos_of(old_at_base)
      late = late!(f, 500)
      head = head_of(f.room)

      assert {:ok, events} = seg(f.room, f.b, base, head, 20)
      assert ids(events) == [late], "the floor is min ts over the 64 newest POSITIONS (here ts 1): a late event stamped 500 is inside"
    end

    test "a base of 0 has no anchor: no floor, the whole (0, head], equal to the plain read" do
      f = skew_room!()
      late!(f, 5)
      head = head_of(f.room)
      assert {:ok, events} = seg(f.room, f.b, 0, head, 20)
      assert seg(f.room, f.b, 0, head, 20) == plain(f.room, f.b, 0, head, 20)
      assert length(events) == 21
    end

    test "a SPECIAL event is not floored: the viewer's own member event below the floor is returned, an ordinary one is not" do
      f = skew_room!()
      old_ts = f.floor_ts - 5_000
      late_join = member!(f.room, f.b, "join", f.b, old_ts)
      late_msg = late!(f, old_ts)
      head = head_of(f.room)

      assert {:ok, events} = seg(f.room, f.b, f.base, head, 20)
      assert late_join in ids(events), "a member event of the viewer (D5 special) is read without the time floor"
      refute late_msg in ids(events), "an ordinary event of the same timestamp is below the floor"
    end

    test "fewer than 64 events at the base: a late event stamped like the oldest of them is delivered" do
      f = build!([{:hv, "shared"}, {:join, :a}, {:join, :b}, {:msgs, 10}])
      base = pos_of(List.last(f.msgs))
      oldest_ts = ts_of(event_id_of(f, 0))
      late = put_message!(f.room, f.a, word("late"), oldest_ts)
      head = head_of(f.room)
      assert {:ok, events} = seg(f.room, f.b, base, head, 20)
      assert ids(events) == [late]
    end
  end

  # ═══ D7 (1): the cost probes ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "D7 (1) the row probe: rows of `events` touched by ONE call" do
    # The bound must hold in EVERY planner regime, because the statement runs as a named prepared statement of the pool (Postgrex): PostgreSQL plans the first executions per connection
    # with the parameter values (a custom plan) and may switch to ONE generic plan afterwards. The regimes: statistics stale (right after the bulk write: the table statistics do not know
    # the room) or fresh (after `ANALYZE events`), each with `plan_cache_mode` forced to custom and to generic: four regimes, all deterministic. A shape whose bound depends on the plan
    # fails one of them (measured on earlier drafts of the statement: the position bounds as plain index conditions, 4 293 rows for N = 600; `room_id` as an index condition of the specials
    # join, 2 843; the floor as `ORDER BY room_pos DESC LIMIT 64`, which the planner turned into a bitmap scan of the whole room, 603 rows for 600 delivered events). Every fixture is
    # measured stale in both modes first, then once more in both modes after ONE `ANALYZE events`.
    @plan_modes ["force_custom_plan", "force_generic_plan"]

    defp probe_rows(fixtures, fun) do
      stale = for mode <- @plan_modes, do: {"stale statistics, #{mode}", Enum.map(fixtures, &fun.(&1, mode))}
      T.privileged_sql!("ANALYZE events")
      fresh = for mode <- @plan_modes, do: {"fresh statistics, #{mode}", Enum.map(fixtures, &fun.(&1, mode))}
      stale ++ fresh
    end

    defp seg_rows(f, mode, no_bitmap \\ false) do
      {{:ok, events}, rows} = measured(fn -> seg(f.room, f.b, f.base, f.head, 20) end, mode, no_bitmap)
      {rows, events}
    end

    test "N = 600 hidden events touch at most 10 rows more than N = 20 and under 300, all four planner regimes" do
      {small, big} = {away!(20), away!(600)}

      for {regime, [{small_rows, small_events}, {big_rows, big_events}]} <- probe_rows([small, big], &seg_rows/2) do
        assert length(small_events) == 4 and length(big_events) == 4, "#{regime}: the re-join event and the three visible messages, nothing of the hidden events"
        assert ids(big_events) == Enum.reverse([big.join | big.shown])
        assert big_rows - small_rows <= 10, "#{regime}: N = 600 read #{big_rows} rows, N = 20 read #{small_rows}: the cost depends on the hidden history"
        assert big_rows < 300, "#{regime}: N = 600 read #{big_rows} rows of events (a walk over the hidden stretch reads at least 600)"
      end
    end

    test "guard: the plain range read touches at least N rows (it walks the hidden stretch)" do
      big = away!(600)

      for {regime, [{rows, events}]} <- probe_rows([big], fn f, mode -> {{:ok, events}, rows} = measured(fn -> plain(f.room, f.b, f.base, f.head, 20) end, mode); {rows, events} end) do
        assert length(events) == 4
        assert rows >= 600, "#{regime}: the plain read of N = 600 hidden events read #{rows} rows"
      end
    end

    # the segmented statement as the real read sends it (text and parameters), captured from the repo telemetry
    defp captured_statement!(f) do
      parent = self()
      id = "rj-shape-#{T.rand(6)}"

      :ok =
        :telemetry.attach(id, [:nebu, :repo, :query], fn _e, _m, %{query: q, params: p}, _c -> if String.contains?(q, "/* history_visibility */") and q =~ "room_pos", do: send(parent, {:stmt, q, p}) end, nil)

      try do
        assert {:ok, [_ | _]} = seg(f.room, f.b, f.base, f.head, 20)
      after
        :telemetry.detach(id)
      end

      assert_received {:stmt, query, params}
      {query, params}
    end

    # the nodes of `EXPLAIN (FORMAT JSON)` of the statement in a rolled-back privileged transaction with sequential scans off (and the timestamp index dropped when `drop_ts_index?`)
    defp explain_nodes!({query, params}, drop_ts_index?) do
      assert {:error, json} =
               T.with_privileged_conn(fn conn ->
                 Postgrex.transaction(conn, fn tx ->
                   Postgrex.query!(tx, "SET LOCAL enable_seqscan = off", [])
                   if drop_ts_index?, do: Postgrex.query!(tx, "DROP INDEX events_room_id_ts_idx", [])
                   %{rows: [[json]]} = Postgrex.query!(tx, "EXPLAIN (FORMAT JSON) " <> query, params)
                   Postgrex.rollback(tx, json)
                 end)
               end)

      json |> List.wrap() |> hd() |> Map.fetch!("Plan") |> plan_nodes_of([])
    end

    test "plan shape: without the timestamp index the position index serves at most TWO scans (the floor window and its empty-window fallback)" do
      stmt = captured_statement!(away!(300))

      # sequential scans off and events_room_id_ts_idx dropped, so the only index that could serve a scan with `room_pos` bounds is events_room_pos_idx. A statement whose position bounds
      # are plain index conditions (the bare `room_pos > $3 AND room_pos <= $4` of the unfenced draft, measured: 4 293 rows) walks it over the hidden stretch; the fenced statement uses it for
      # the floor window (`BETWEEN $3 - 63 AND $3`) and for the fallback of an empty window (`room_pos > $3 AND room_pos <= $4 ORDER BY room_pos LIMIT 64`), nothing else. Plan-dependent
      # mutants are caught here deterministically, not by the planner's mood.
      nodes = explain_nodes!(stmt, true)
      pos_scans = for n <- nodes, n["Relation Name"] == "events", n["Index Name"] == "events_room_pos_idx", do: n
      assert length(pos_scans) <= 2, "#{length(pos_scans)} scans of events_room_pos_idx: #{inspect(Enum.map(pos_scans, &Map.take(&1, ["Index Cond", "Node Type"])))}"

      # and each of them is one of the two position RANGES of at most 64 positions (`room_pos >= lo AND room_pos <= hi`, the values folded into the plan): the window below the base
      # (`base - 63 .. base`) and the fallback above it (`base + 1 .. min(base + 64, head)`); a scan with an open or a longer range is a walk
      {_query, params} = stmt
      [_room, _viewer, base, head, _limit] = params

      ranges =
        for n <- pos_scans do
          cond = n["Index Cond"] || ""
          assert [_, lo] = Regex.run(~r/room_pos >= '(\d+)'/, cond), "an open range (no lower bound >=): #{cond}"
          assert [_, hi] = Regex.run(~r/room_pos <= '(\d+)'/, cond), "an open range (no upper bound <=): #{cond}"
          {String.to_integer(lo), String.to_integer(hi)}
        end

      for {lo, hi} <- ranges, do: assert(hi - lo + 1 <= 64, "a range of #{hi - lo + 1} positions: #{inspect(ranges)}")
      assert Enum.all?(ranges, &(&1 in [{base - 63, base}, {base + 1, min(base + 64, head)}])), "unexpected ranges #{inspect(ranges)} (base #{base}, head #{head})"
    end

    test "plan shape: the OFFSET 0 fence keeps the floor probe a position-range scan, never a walk of the timestamp index (timestamp index kept, fresh statistics)" do
      {query, _params} = stmt = captured_statement!(away!(300))
      assert query =~ "OFFSET 0", "the fence of the floor probe is part of the statement"

      # Without the fence the planner may rewrite `min(origin_server_ts)` into `ORDER BY origin_server_ts LIMIT 1` over events_room_id_ts_idx (`origin_server_ts IS NOT NULL`, the room's position
      # window as a filter): a read of the room's history below the window, O(delivered history). It happens under fresh statistics with the timestamp index present, which the test above
      # (index dropped) cannot see; measured on the unfenced statement.
      T.privileged_sql!("ANALYZE events")
      nodes = explain_nodes!(stmt, false)
      walks = for n <- nodes, n["Index Name"] == "events_room_id_ts_idx", (n["Index Cond"] || "") =~ "origin_server_ts IS NOT NULL", do: n
      assert walks == [], "the floor probe walks the timestamp index (min() rewritten into an ordered scan): #{inspect(Enum.map(walks, &Map.take(&1, ["Index Cond", "Filter"])))}"
    end

    defp plan_nodes_of(%{} = node, acc), do: Enum.reduce(Map.get(node, "Plans", []), [node | acc], &plan_nodes_of/2)

    test "the probe is deterministic: the same call twice counts the same rows" do
      f = away!(50)
      {first, _} = seg_rows(f, "force_custom_plan")
      {second, _} = seg_rows(f, "force_custom_plan")
      assert first == second
    end

    test "many NEW visible events: the walk stops after limit + 1 rows: 600 read no more than 100 (index plans, all four regimes)" do
      new_room = fn count ->
        room = raw_room!()
        {a, b} = {uid("rja"), uid("rjb")}
        put_hv_event!(room, a, "shared", 100)
        member!(room, a, "join", a, 105)
        member!(room, b, "join", b, 110)
        for i <- 1..70, do: put_message!(room, a, word("m"), 1_000 + i)
        base = head_of(room)

        T.privileged_sql!(
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
          SELECT '$new' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'new' || g), 1000000 + g, NULL
          FROM generate_series(1, $3::int) AS g
          """,
          [room, a, count]
        )

        %{room: room, b: b, base: base, head: head_of(room)}
      end

      {small, big} = {new_room.(100), new_room.(600)}

      # With bitmap scans left on, the planner may read the visible segment's whole timestamp range through a bitmap scan and sort it (measured: 678 rows for 600 new events under
      # freshly analysed statistics, a different outcome from run to run because `ANALYZE` samples): the cost of the visible NEW events is then plan dependent (an accepted residual, documented in 06-runtime and the closure of `cq` (f)).
      # What this test pins is the structure: the LATERAL of a visible segment carries the LIMIT, so the index plan (bitmap scans off) stops after limit + 1 rows.

      for {regime, [{small_rows, small_events}, {big_rows, big_events}]} <- probe_rows([small, big], fn f, mode -> seg_rows(f, mode, true) end) do
        assert length(small_events) == 21 and length(big_events) == 21, "#{regime}: limit + 1 events"
        assert big_rows - small_rows <= 10, "#{regime}: 600 new events read #{big_rows} rows, 100 read #{small_rows}: the per-segment LIMIT must stop the walk"
        assert big_rows < 300
      end
    end

    test "the time floor keeps the walk off the delivered history: 600 delivered events read no more rows than 100, all four planner regimes" do
      delivered_room = fn delivered ->
        room = raw_room!()
        {a, b} = {uid("rja"), uid("rjb")}
        put_hv_event!(room, a, "shared", 100)
        member!(room, a, "join", a, 105)
        member!(room, b, "join", b, 110)

        T.privileged_sql!(
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
          SELECT '$old' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'old' || g), 1000 + g, NULL
          FROM generate_series(1, $3::int) AS g
          """,
          [room, a, delivered]
        )

        base = head_of(room)
        new = for i <- 1..2, do: put_message!(room, a, word("n"), 1_000_000 + i)
        %{room: room, b: b, base: base, head: head_of(room), new: new}
      end

      {small, big} = {delivered_room.(100), delivered_room.(600)}

      for {regime, [{small_rows, small_events}, {big_rows, big_events}]} <- probe_rows([small, big], &seg_rows/2) do
        assert ids(small_events) == Enum.reverse(small.new) and ids(big_events) == Enum.reverse(big.new)
        assert big_rows - small_rows <= 10, "#{regime}: 600 delivered events read #{big_rows} rows, 100 read #{small_rows}: a plain position filter on the segment-driven read scans the delivered history (Premise 2)"
        assert big_rows < 300
      end
    end

    # An EMPTY floor window (all 64 positions at the base gone, `after_pos > 0`): `min()` over no row is NULL and `GREATEST` ignores NULL, so without a fallback the floor disappears and the
    # segment walk covers the whole delivered history. The floor then is the oldest timestamp of the next 64 events above the base.
    for variant <- [:deleted, :unstamped] do
      test "an empty floor window (#{variant}) keeps the floor: 600 delivered events read no more rows than 100, the plain read's answer, four regimes" do
        gapped_room = fn delivered ->
          room = raw_room!()
          {a, b} = {uid("rja"), uid("rjb")}
          put_hv_event!(room, a, "shared", 100)
          member!(room, a, "join", a, 105)
          member!(room, b, "join", b, 110)

          T.privileged_sql!(
            """
            INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
            SELECT '$gap' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'old' || g), 1000 + g, NULL
            FROM generate_series(1, $3::int) AS g
            """,
            [room, a, delivered]
          )

          base = head_of(room)

          # a decoy room with events at the positions ABOVE the base and tiny timestamps: a fallback probe without the room filter would lower the floor to them
          decoy = raw_room!()

          T.privileged_sql!(
            """
            INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
            SELECT '$decoy' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'decoy' || g), g, NULL
            FROM generate_series(1, $3::int) AS g
            """,
            [decoy, a, delivered + 20]
          )

          case unquote(variant) do
            :deleted -> T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])
            :unstamped -> T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])
          end

          new = for i <- 1..2, do: put_message!(room, a, word("n"), 1_000_000 + i)
          %{room: room, b: b, base: base, head: head_of(room), new: new}
        end

        {small, big} = {gapped_room.(100), gapped_room.(600)}
        assert seg(big.room, big.b, big.base, big.head, 20) == plain(big.room, big.b, big.base, big.head, 20), "no skew: nothing is lost by the fallback floor"

        for {regime, [{small_rows, small_events}, {big_rows, big_events}]} <- probe_rows([small, big], &seg_rows/2) do
          assert ids(small_events) == Enum.reverse(small.new) and ids(big_events) == Enum.reverse(big.new)
          assert big_rows - small_rows <= 10, "#{regime}: 600 delivered events read #{big_rows} rows, 100 read #{small_rows}: the floor disappeared with the empty window"
          assert big_rows < 300
        end
      end
    end

    test "an empty floor window: the fallback floor is the oldest of the next 64 events, so a late commit inside them is read" do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      for i <- 1..100, do: put_message!(room, a, word("m"), 1_000 + i)
      base = head_of(room)
      T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])

      first = put_message!(room, a, word("n"), 1_000_000)
      late = put_message!(room, a, word("late"), 999_990)
      head = head_of(room)

      assert {:ok, events} = seg(room, b, base, head, 20)
      assert ids(events) == [late, first], "the floor is the oldest timestamp of the events above the base, not the timestamp of the first one"
      assert {:ok, ^events} = plain(room, b, base, head, 20)
    end

    test "an empty floor window and no event above the base: the answer is empty (no floor then; cost only, and not reachable from /sync: head <= base reads nothing)" do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      for i <- 1..200, do: put_message!(room, a, word("m"), 1_000 + i)
      base = head_of(room)
      T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])

      assert {:ok, []} = seg(room, b, base, base, 20)
    end

    test "both floor ranges empty by gaps, events further up: they are read as by the plain read (no floor, never an emptied answer)" do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      for i <- 1..100, do: put_message!(room, a, word("m"), 1_000 + i)
      base = head_of(room)
      new = for i <- 1..70, do: put_message!(room, a, word("n"), 1_000_000 + i)
      head = head_of(room)
      unstamp!(ids_at(room, base - 63, base + 64))

      assert {:ok, events} = seg(room, b, base, head, 20)
      assert ids(events) == new |> Enum.take(-6) |> Enum.reverse(), "the 6 positioned events above the gap"
      assert {:ok, ^events} = plain(room, b, base, head, 20)
    end

    test "an empty floor window, more than 64 events above the base: the answer does not depend on the heap order (bitmap scans, rows moved)" do
      room = raw_room!()
      {a, b} = {uid("rja"), uid("rjb")}
      put_hv_event!(room, a, "shared", 100)
      member!(room, a, "join", a, 105)
      member!(room, b, "join", b, 110)
      for i <- 1..100, do: put_message!(room, a, word("m"), 1_000 + i)
      base = head_of(room)
      T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])
      new = for i <- 1..100, do: put_message!(room, a, word("n"), 1_000_000 + i)
      head = head_of(room)
      # the new versions of the first 40 events lie behind all the others: a probe that takes ANY 64 rows of a bitmap heap scan would see the later ones first
      T.privileged_sql!("UPDATE events SET content = content WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base + 1, base + 40])

      assert {:ok, plain_events} = plain(room, b, base, head, 100)
      assert length(plain_events) == 100

      {:ok, seg_result} =
        Nebu.Repo.transaction(fn ->
          for setting <- ["enable_indexscan", "enable_indexonlyscan", "enable_seqscan"], do: Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL #{setting} = off", [])
          seg(room, b, base, head, 100)
        end)

      assert seg_result == {:ok, plain_events}
      assert ids(plain_events) == Enum.reverse(new)
    end

    # hv `joined`: N events written while the viewer was away lie ABOVE the base, the window below the base is empty. The fallback probe reads the 64 positions above the base (hidden rows, only
    # their timestamp), so N >= 64 reads the same number of rows whatever N is.
    test "an empty floor window above a hidden stretch: 70 and 600 hidden events above the base read the same rows (four planner regimes)" do
      hidden_room = fn hidden ->
        room = raw_room!()
        {a, b} = {uid("rja"), uid("rjb")}
        put_hv_event!(room, a, "joined", 100)
        member!(room, a, "join", a, 105)
        member!(room, b, "join", b, 110)

        T.privileged_sql!(
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
          SELECT '$dl' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'old' || g), 1000 + g, NULL
          FROM generate_series(1, 150) AS g
          """,
          [room, a]
        )

        member!(room, b, "leave", b, 2_000)

        T.privileged_sql!(
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
          SELECT '$fl' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'fill' || g), 2_000 + g, NULL
          FROM generate_series(1, 64) AS g
          """,
          [room, a]
        )

        base = head_of(room)
        T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND room_pos BETWEEN $2 AND $3", [room, base - 63, base])

        T.privileged_sql!(
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
          SELECT '$hd' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'hidden' || g), 3_000 + g, NULL
          FROM generate_series(1, $3::int) AS g
          """,
          [room, a, hidden]
        )

        join = member!(room, b, "join", b, 100_000)
        shown = for i <- 1..3, do: put_message!(room, a, word("v"), 100_010 + i)
        %{room: room, b: b, base: base, head: head_of(room), join: join, shown: shown}
      end

      {small, big} = {hidden_room.(70), hidden_room.(600)}

      for {regime, [{small_rows, small_events}, {big_rows, big_events}]} <- probe_rows([small, big], &seg_rows/2) do
        assert ids(small_events) == Enum.reverse([small.join | small.shown]) and ids(big_events) == Enum.reverse([big.join | big.shown])
        assert big_rows - small_rows <= 10, "#{regime}: 600 hidden events read #{big_rows} rows, 70 read #{small_rows}: the hidden stretch is walked"
        assert big_rows < 300
      end
    end
  end

  # ═══ the documented residual, as a fixture ════════════════════════════════════════════════════════════════════════════════════

  describe "skew fixture (documents the D2 residual, never asserts equality with the oracle)" do
    test "a late commit older than all 64 newest events is the one difference to the plain read" do
      f = skew_room!()
      below = late!(f, f.floor_ts - 1)
      inside = late!(f, f.floor_ts + 5_000)
      head = head_of(f.room)

      assert {:ok, plain_events} = plain(f.room, f.b, f.base, head, 20)
      assert {:ok, seg_events} = seg(f.room, f.b, f.base, head, 20)
      assert below in ids(plain_events) and inside in ids(plain_events)
      assert ids(seg_events) == [inside]
    end
  end

  # ═══ cross-room isolation, the segment-order residual, gaps in the floor window ═══════════════════════════════════════════════

  describe "isolation and accepted residuals" do
    test "a decoy room with the same positions and other timestamps changes neither the answer nor the floor" do
      f = skew_room!()
      decoy = raw_room!()
      put_hv_event!(decoy, f.a, "shared", 100)
      member!(decoy, f.a, "join", f.a, 105)
      member!(decoy, f.b, "join", f.b, 110)
      # positions 4 .. 83 like the 80 messages of the room under test, but timestamps 1 .. 80: a floor probe without the room filter would drop the floor to 1
      for i <- 1..80, do: put_message!(decoy, f.a, word("y"), i)
      inside = late!(f, f.floor_ts + 5_000)
      below = late!(f, f.floor_ts - 1)
      # positions 84 .. 86 with timestamps inside the room's own range: a lateral without the room filter would return them
      decoy_new = for i <- 1..3, do: put_message!(decoy, f.a, word("yy"), 3_000_000 + i)
      head = head_of(f.room)

      assert {:ok, events} = seg(f.room, f.b, f.base, head, 20)
      assert Enum.all?(events, &(&1["room_id"] == f.room)), "every returned event belongs to the room that was asked for"
      assert Enum.all?(decoy_new, &(&1 not in ids(events)))
      assert ids(events) == [inside], "the floor of the room under test is not lowered by the decoy's old timestamps (`below` stays out)"
      refute below in ids(events)
    end

    test "accepted residual (cq (b)): with limit + 1 newer-by-ts events in a segment a late commit is not read, the page read has it" do
      f = skew_room!()
      newer = for i <- 1..25, do: put_message!(f.room, f.a, word("n"), 2_000_000 + i)
      late = late!(f, f.floor_ts + 5_000)
      head = head_of(f.room)

      assert {:ok, seg_events} = seg(f.room, f.b, f.base, head, 20)
      assert {:ok, plain_events} = plain(f.room, f.b, f.base, head, 20)
      assert hd(ids(plain_events)) == late, "the plain read (cut by position) returns the late commit first"
      assert length(seg_events) == 21
      refute late in ids(seg_events), "the cut inside the visible segment is by timestamp: the late commit (old timestamp, highest position) is not read"
      assert ids(seg_events) == newer |> Enum.reverse() |> Enum.take(21)

      # reachable by /messages (timestamp order): the page read of the same viewer
      assert {:ok, page, _next, _prev} = DB.fetch_visible_events(f.room, f.b, "b", 200, "")
      assert late in ids(page)
    end

    for variant <- [:unstamped, :deleted] do
      test "gap in the floor window (#{variant}): a HIGHER floor, nothing lost without skew (D-A3)" do
        f = skew_room!()
        # messages 17 .. 80 hold the positions 20 .. 83: the window of the 64 positions at the base. Message 17 leaves the window's rows, so the floor becomes ts(18).
        gone = Enum.at(f.msgs, 16)

        case unquote(variant) do
          :unstamped -> unstamp!([gone])
          :deleted -> T.privileged_sql!("DELETE FROM events WHERE event_id = $1", [gone])
        end

        at_old_floor = late!(f, f.floor_ts)
        at_new_floor = late!(f, f.floor_ts + 1_000)
        head = head_of(f.room)

        assert {:ok, events} = seg(f.room, f.b, f.base, head, 20)
        assert at_new_floor in ids(events), "the new floor ts(18) is inclusive"
        refute at_old_floor in ids(events), "the window holds 63 events now: the floor is ts(18), a late event stamped ts(17) is below it (documented, a gap only raises the floor)"
        assert {:ok, plain_events} = plain(f.room, f.b, f.base, head, 20)
        assert at_old_floor in ids(plain_events), "the plain read has no floor"

        # nothing is lost without skew: events written in timestamp order after the base are all read, as by the plain read
        g = skew_room!()

        case unquote(variant) do
          :unstamped -> unstamp!([Enum.at(g.msgs, 16)])
          :deleted -> T.privileged_sql!("DELETE FROM events WHERE event_id = $1", [Enum.at(g.msgs, 16)])
        end

        for i <- 1..5, do: put_message!(g.room, g.a, word("n"), 2_000_000 + i)
        g_head = head_of(g.room)
        assert seg(g.room, g.b, g.base, g_head, 20) == plain(g.room, g.b, g.base, g_head, 20)
      end
    end
  end
end
