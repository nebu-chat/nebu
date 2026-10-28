defmodule Nebu.Matrix.SyncRejoinRangeScanBoundHttpTest do
  @moduledoc """
  Acceptance tests for story `sync-rejoin-range-scan-bound` (epic oauth-broker, follow-up `cq` (f), REQ-2026-006), HTTP half: `GET /_matrix/client/v3/sync` over the real stack (`Nebu.Web.Router`
  + `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg; users and sessions through `Nebu.OAuth.TestSupport` and `Nebu.Matrix.ModerationTestSupport` (`S`), random localparts, the
  `:server_name` pinned). The six Gherkin scenarios of the story, the replay equality (D6) and the statement probe (D7 (2)). The SQL half (differential, bounds, floor, row probes) is
  `room/sync_rejoin_range_scan_bound_db_test.exs`, the dispatcher half (the gate, the seam, the 503, rows read through the real read) `sync_rejoin_range_scan_bound_dispatcher_test.exs`.

  ## Test design

    * A NEW file instead of additions to `sync_stream_position_http_test.exs` (D10 (3) names that file): the existing suite is not amended; the fixtures it needs are re-declared here.
    * Hidden events are written in BULK with SQL (`INSERT ... generate_series`; the position trigger of story events-room-position stamps them in order) at the timestamp just after the leave
      event, so they lie in the invisible segment of an `hv = joined` room; the events that matter to the scenario (invite, join, leave, the visible messages) go through the REAL writers.
    * "equals" for a replayed response compares `rooms` after dropping `unsigned.age` (it moves with the clock) and nothing else; `next_batch` differs by design (a new generation).
    * Scenario 6 pads the room with 70 events stamped just before the cursor (`created` rooms are younger than a second: without the pad the 64-event floor would be the creation time).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.MembershipStateTestSupport, only: [count_statements: 2, listing: 1]

  alias Nebu.Matrix.HistoryVisibilityTestSupport, as: HV
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 600_000

  # A db module that delegates EVERY function of `Room.DB` and measures the two incremental range reads: each call runs inside ONE transaction (sequential scans off and the plan cache mode
  # pinned, as the DB suite explains) and records `{kind, rows of events touched}` in a public ETS table. It is installed as both db seams, so the real /sync request is observed from inside.
  defmodule RowSpy do
    @moduledoc false
    alias Nebu.Matrix.Room.DB
    @table :rj_row_spy

    for {name, arity} <- DB.__info__(:functions), name not in [:fetch_visible_events_in_range, :fetch_visible_events_in_range_segmented] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def fetch_visible_events_in_range(r, v, a, h, l), do: measured(:fetch_visible_events_in_range, [r, v, a, h, l])
    def fetch_visible_events_in_range_segmented(r, v, a, h, l), do: measured(:fetch_visible_events_in_range_segmented, [r, v, a, h, l])

    # the read runs once per plan cache mode (custom and generic, the two ways the pool's named prepared statement can be planned): the rows recorded are the WORSE of the two
    defp measured(fun, args) do
      runs =
        for mode <- ["force_custom_plan", "force_generic_plan"] do
          {:ok, {result, rows}} =
            Nebu.Repo.transaction(fn ->
              Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_seqscan = off", [])
              Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL plan_cache_mode = #{mode}", [])
              before = rows_read()
              result = apply(DB, fun, args)
              {result, rows_read() - before}
            end)

          {result, rows}
        end

      [{result, _} | _] = runs
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), fun, runs |> Enum.map(&elem(&1, 1)) |> Enum.max()})
      result
    end

    defp rows_read do
      %{rows: [[n]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT COALESCE(sum(seq_tup_read + idx_tup_fetch), 0)::bigint FROM pg_stat_xact_user_tables WHERE relname = 'events'", [])
      n
    end

    def table, do: @table
    def reset, do: :ets.delete_all_objects(@table)
    def reads, do: :ets.tab2list(@table) |> Enum.sort() |> Enum.map(fn {_, fun, rows} -> {fun, rows} end)
  end

  # one measurement: ANALYZE first (the statistics of every measurement are as fresh as the worlds built before it), then the spy is armed and `fun` runs: `{result, [{read, rows}]}`
  defp measured_sync(fun) do
    T.privileged_sql!("ANALYZE events")
    install_row_spy!()
    result = fun.()
    {result, RowSpy.reads()}
  end

  defp install_row_spy! do
    if :ets.whereis(RowSpy.table()) == :undefined, do: :ets.new(RowSpy.table(), [:named_table, :public, :set])
    RowSpy.reset()

    for key <- [:messages_db_module, :rooms_db_module] do
      prior = Application.fetch_env(:event_dispatcher, key)
      Application.put_env(:event_dispatcher, key, RowSpy)

      on_exit(fn ->
        case prior do
          {:ok, v} -> Application.put_env(:event_dispatcher, key, v)
          :error -> Application.delete_env(:event_dispatcher, key)
        end
      end)
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp device!(uid, prefix) do
    dev = prefix <> String.upcase(T.rand(3))
    %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
  end

  # the syncing user `a` (one device), the owner `o`, a private_chat room of `o` with `a` joined and the history visibility `hv`, and the device's first token `ta` (an initial sync after an
  # event of the user's anchor room, so every later event of the scenario is NEW)
  defp world!(hv) do
    uid = T.provision_user!()
    a = device!(uid, "RJA")
    o = S.user!("RJO")
    room = S.invite_room(o, [a])
    if hv != "shared", do: HV.set_hv!(o, room, hv)
    ta = S.snapshot!(a, S.anchor_room!(a))
    %{uid: uid, a: a, o: o, room: room, ta: ta}
  end

  # `n` messages at ONE timestamp just after the newest event of the room, in position order, written with SQL: the hidden stretch of an `hv = joined` room while the viewer is away
  defp bulk!(room, sender, n, label) do
    Nebu.Matrix.MembershipStateTestSupport.cleanup_room_events_on_exit(room)
    %{rows: [[newest]]} = T.sql!("SELECT max(origin_server_ts) FROM events WHERE room_id = $1", [room])

    T.privileged_sql!(
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
      SELECT '$rj' || md5(g::text || $1 || $4), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', $4 || g), $3, NULL
      FROM generate_series(1, $5::int) AS g
      """,
      [room, sender, newest + 1, label, n]
    )

    label
  end

  defp put_account_data!(f, type, content) do
    conn = T.matrix_request(:put, "/_matrix/client/v3/user/#{S.enc(f.uid)}/rooms/#{S.enc(f.room)}/account_data/#{type}", f.a.at, body: content)
    assert conn.status == 200, "account data: #{conn.status}"
  end

  defp room_account_types(body, room), do: for(ev <- get_in(body, ["rooms", "join", room, "account_data", "events"]) || [], do: ev["type"])

  # ─── probes ──────────────────────────────────────────────────────────────────

  defp cursor(uid, dev, room) do
    case T.sql!("SELECT pos, class FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [uid, dev, room]).rows do
      [[pos, class]] -> %{pos: pos, class: class}
      [] -> nil
    end
  end

  defp event_ids_above(room, pos), do: T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND room_pos > $2 ORDER BY room_pos", [room, pos]).rows |> List.flatten()
  defp event_ids_upto(room, pos), do: T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND room_pos <= $2 ORDER BY room_pos", [room, pos]).rows |> List.flatten()
  defp newest_ts(room), do: T.sql!("SELECT max(origin_server_ts) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # ─── the sync client ─────────────────────────────────────────────────────────

  defp next(body), do: body["next_batch"]
  defp core(token), do: token |> String.split(".") |> hd()
  defp event_ids(body, room), do: for(ev <- S.join_timeline(body, room), do: ev["event_id"])
  defp bodies(body, room), do: for(ev <- S.join_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])
  defp limited?(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "limited"]) == true
  defp prev_batch(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "prev_batch"])
  defp raw(body), do: Jason.encode!(body)

  defp message!(o, room, label) do
    S.tick()
    m = S.marker(label)
    S.say!(o, room, m)
    m
  end

  defp strip_age(v) when is_map(v), do: v |> Map.delete("age") |> Map.new(fn {k, x} -> {k, strip_age(x)} end)
  defp strip_age(v) when is_list(v), do: Enum.map(v, &strip_age/1)
  defp strip_age(v), do: v

  defp rooms_of(body), do: strip_age(body["rooms"])

  defp reinvite_join!(f) do
    S.tick()
    S.invite!(f.o, f.room, f.a)
    S.join!(f.a, f.room)
    S.tick()
  end

  # the device's cursor is a LEAVE (delivered), `n` hidden events are written while away, the user re-joins, `visible` messages follow: `{f, token_before}`
  defp leave_world!(n, visible) do
    f = world!("joined")
    S.leave!(f.a, f.room)
    lw = S.sync(f.a, f.ta)
    assert cursor(f.uid, f.a.dev, f.room).class == "leave"
    hidden = bulk!(f.room, f.o.uid, n, S.marker("hid"))
    reinvite_join!(f)
    shown = for i <- 1..visible, do: message!(f.o, f.room, "vis#{i}")
    {Map.merge(f, %{hidden: hidden, shown: shown}), next(lw)}
  end

  # ═══ Scenario 1: a re-join after a long hidden absence ══════════════════════════════════════════════════════════════════════

  describe "scenario 1: a re-join after a hidden absence" do
    test "hv joined, cursor = leave, 30 hidden events, re-join, 2 visible: the join and the 2 messages, not limited, newly joined" do
      f = world!("joined")
      put_account_data!(f, "org.rj.old", %{"v" => 1})
      ta = S.snapshot!(f.a, S.anchor_room!(f.a))
      assert ta != f.ta

      S.leave!(f.a, f.room)
      lw = S.sync(f.a, ta)
      assert S.in_section?(lw, "leave", f.room)
      assert cursor(f.uid, f.a.dev, f.room).class == "leave"

      hidden = bulk!(f.room, f.o.uid, 30, S.marker("hid"))
      reinvite_join!(f)
      visible = for i <- 1..2, do: message!(f.o, f.room, "vis#{i}")

      body = S.sync(f.a, next(lw))
      assert bodies(body, f.room) == visible, "only the two messages written after the re-join"
      events = S.join_timeline(body, f.room)
      assert length(events) == 3, "the two messages and the viewer's own join event, nothing else: #{inspect(Enum.map(events, & &1["type"]))}"
      assert S.member_ev(events, f.uid, "join"), "the re-join event is in the timeline"
      refute Enum.any?(["invite", "leave"], &S.member_ev(events, f.uid, &1)), "the invitation is hidden, the leave was delivered before"
      refute limited?(body, f.room), "hidden events do not count towards the 20, two visible events are not limited"
      refute String.contains?(raw(body), hidden), "no hidden event anywhere in the response"
      assert "org.rj.old" in room_account_types(body, f.room), "the room is newly joined: ALL its room account data (also the row below the device's position)"

      again = S.sync(f.a, next(body))
      assert bodies(again, f.room) == [] and event_ids(again, f.room) == [], "exactly once"
    end

    test "the read of the re-joined room touches the same number of rows for 20 and for 400 hidden events" do
      # both worlds first, then the two measurements back to back
      worlds = for n <- [20, 400], do: leave_world!(n, 2)

      reads =
        for {f, token} <- worlds do
          {body, reads} = measured_sync(fn -> S.sync(f.a, token) end)
          assert bodies(body, f.room) == f.shown
          refute limited?(body, f.room)
          reads
        end

      [[{_, small}], [{_, big}]] = reads
      assert big - small <= 10, "400 hidden events: the room read touched #{big} rows, 20 hidden events: #{small}"
      assert big < 300, "the room read touched #{big} rows of events (a walk over 400 hidden events reads at least 400)"
    end

    test "hv invited, the same flow: events from the invitation on are visible, the 30 written before it are not" do
      f = world!("invited")
      S.leave!(f.a, f.room)
      lw = S.sync(f.a, f.ta)
      hidden = bulk!(f.room, f.o.uid, 30, S.marker("hid"))
      S.tick()
      S.invite!(f.o, f.room, f.a)
      seen_by_invitee = message!(f.o, f.room, "inv")
      S.join!(f.a, f.room)
      after_join = message!(f.o, f.room, "post")

      body = S.sync(f.a, next(lw))
      assert bodies(body, f.room) == [seen_by_invitee, after_join], "hv invited: events written from the invitation on are visible, those before it are not"
      refute String.contains?(raw(body), hidden)
      assert S.member_ev(S.join_timeline(body, f.room), f.uid, "invite"), "the invitation event itself"
    end
  end

  # ═══ Scenario 2: replay ══════════════════════════════════════════════════════════════════════════════════════════════════════

  # a device whose cursor is an INVITATION (delivered), `n` hidden events between the invitation and the join, `visible` messages after the join: `{f, t_before}` where t_before is the
  # token the device presents (its cursor class is `invite`)
  defp invite_world!(n, visible) do
    uid = T.provision_user!()
    a = device!(uid, "RJA")
    o = S.user!("RJO")
    room = S.make_room(o, %{"preset" => "private_chat"})
    HV.set_hv!(o, room, "joined")
    ta = S.snapshot!(a, S.anchor_room!(a))
    f = %{uid: uid, a: a, o: o, room: room}

    S.tick()
    S.invite!(o, room, a)
    inv = S.sync(a, ta)
    assert S.in_section?(inv, "invite", room)
    assert cursor(uid, a.dev, room).class == "invite"

    hidden = bulk!(room, o.uid, n, S.marker("hid"))
    S.tick()
    S.join!(a, room)
    S.tick()
    shown = for i <- 1..visible, do: message!(o, room, "vis#{i}")
    {Map.merge(f, %{hidden: hidden, shown: shown}), next(inv)}
  end

  describe "scenario 2 / D6: replaying the previous next_batch" do
    test "invite -> join with 30 hidden events: the replay of the presented next_batch returns the identical rooms section, again and again" do
      {f, t1} = invite_world!(30, 2)

      first = S.sync(f.a, t1)
      assert bodies(first, f.room) == f.shown
      assert length(S.join_timeline(first, f.room)) == 3, "the join event and the two visible messages"
      refute limited?(first, f.room)
      refute String.contains?(raw(first), f.hidden)

      second = S.sync(f.a, t1)
      assert next(second) != next(first), "a replay writes a new generation"
      assert rooms_of(second) == rooms_of(first), "the replayed response equals the first one"
      third = S.sync(f.a, t1)
      assert rooms_of(third) == rooms_of(first), "and again (the previous token stays the previous token)"
    end

    test "events committed before the replay: the replay equals the first plus those, `limited` recomputed (20 -> 21)" do
      {f, t1} = invite_world!(30, 19)

      first = S.sync(f.a, t1)
      first_ids = event_ids(first, f.room)
      assert length(first_ids) == 20, "the join event and 19 messages: exactly 20 visible events, not limited"
      refute limited?(first, f.room)

      extra = message!(f.o, f.room, "extra")
      replay = S.sync(f.a, t1)
      replay_ids = event_ids(replay, f.room)
      assert length(replay_ids) == 20 and limited?(replay, f.room), "21 visible events since the cursor: the newest 20 and limited"
      assert Enum.drop(replay_ids, -1) == tl(first_ids), "the oldest of the first response (the join event) fell out, nothing else changed"
      assert extra in bodies(replay, f.room) and prev_batch(replay, f.room) =~ ~r/\Av1_/
    end

    test "the replay runs the same statements for 20 and for 400 hidden events, with ONE visibility read" do
      runs =
        for n <- [20, 400] do
          {f, t1} = invite_world!(n, 2)
          first = S.sync(f.a, t1)
          assert bodies(first, f.room) == f.shown

          {replay, statements} = count_statements(fn -> S.sync(f.a, t1) end, [f.room])
          assert rooms_of(replay) == rooms_of(first)
          {n, statements}
        end

      [{20, small}, {400, big}] = runs
      # the room read of the replay: the statements judged by the visibility fragment, the batched predecessor lookup (`/* state_predecessors */`, one per delivered state event class) excluded
      marked = fn statements -> Enum.filter(statements, &(String.contains?(&1, "/* history_visibility */") and not String.contains?(&1, "/* state_predecessors */"))) end
      assert length(marked.(small)) == 1 and length(marked.(big)) == 1, "exactly one visibility-judged room read per moved room\n#{listing(marked.(small))}\n---\n#{listing(small)}"
      assert length(small) == length(big), "20 hidden events: #{length(small)} statements, 400: #{length(big)}\n--- 20 ---\n#{listing(small)}\n--- 400 ---\n#{listing(big)}"
      refute Enum.any?(small ++ big, &(&1 =~ "statement_timeout")), "the /sync reads have NO statement timeout (follow-up gk (4), story D1 (3))"
      norm = fn statements -> statements |> Enum.map(&String.replace(&1, ~r/\s+/, " ")) |> Enum.sort() end
      assert norm.(small) == norm.(big), "the same statements (texts), whatever the number of hidden events"
    end
  end

  describe "scenario 2 / D6: the rows of the replay" do
    test "the replay's room read touches the same number of rows for 20 and for 400 hidden events" do
      worlds =
        for n <- [20, 400] do
          {f, t1} = invite_world!(n, 2)
          first = S.sync(f.a, t1)
          assert bodies(first, f.room) == f.shown
          {f, t1, first}
        end

      reads =
        for {f, t1, first} <- worlds do
          {replay, reads} = measured_sync(fn -> S.sync(f.a, t1) end)
          assert rooms_of(replay) == rooms_of(first)
          assert [{_fun, rows}] = reads, "ONE room read in the replay"
          rows
        end

      [small, big] = reads
      assert big - small <= 10, "the replay's room read touched #{big} rows for 400 hidden events, #{small} for 20"
      assert big < 300
    end
  end

  # ═══ Scenario 3: a shared room ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "scenario 3: a shared room delivers the newest 20 since the cursor with a usable prev_batch" do
    test "cursor = leave, 25 visible events: newest 20, limited, prev_batch pages back, nothing twice" do
      f = world!("shared")
      S.leave!(f.a, f.room)
      lw = S.sync(f.a, f.ta)
      base = cursor(f.uid, f.a.dev, f.room)
      assert base.class == "leave"

      msgs = for i <- 1..25, do: message!(f.o, f.room, "sh#{i}")
      reinvite_join!(f)

      since_cursor = event_ids_above(f.room, base.pos)
      assert length(since_cursor) == 27, "fixture: 25 messages, the invitation and the join"
      below = event_ids_upto(f.room, base.pos)

      body = S.sync(f.a, next(lw))
      delivered = event_ids(body, f.room)
      assert delivered == Enum.take(since_cursor, -20), "the newest 20 events since the cursor, oldest first"
      assert limited?(body, f.room)
      refute Enum.any?(delivered, &(&1 in below)), "no event at or below the cursor is delivered again"
      prev = prev_batch(body, f.room)
      assert prev =~ ~r/\Av1_/, "a real /messages token"

      conn = T.matrix_request(:get, S.path(f.room, "messages") <> "?" <> URI.encode_query(%{"dir" => "b", "from" => prev, "limit" => 100}), f.a.at)
      assert conn.status == 200
      older = for ev <- T.json(conn)["chunk"], ev["type"] == "m.room.message", do: ev["content"]["body"]
      assert Enum.take(older, 7) == msgs |> Enum.take(7) |> Enum.reverse(), "the seven older visible messages, newest first, without a hole"
      assert Enum.all?(Enum.drop(msgs, 7), &(&1 not in older)), "no delivered message comes back"

      assert event_ids(S.sync(f.a, next(body)), f.room) == [], "the cursor reached the head: nothing twice"
    end

    test "20 visible events since the cursor are not limited and all delivered" do
      f = world!("shared")
      S.leave!(f.a, f.room)
      lw = S.sync(f.a, f.ta)
      for i <- 1..18, do: message!(f.o, f.room, "n#{i}")
      reinvite_join!(f)

      body = S.sync(f.a, next(lw))
      assert length(S.join_timeline(body, f.room)) == 20, "18 messages, the invitation and the join"
      refute limited?(body, f.room)
      assert prev_batch(body, f.room) in [nil, ""]
    end
  end

  # ═══ Scenario 4: a leave and a re-join between two syncs ═════════════════════════════════════════════════════════════════════════

  describe "scenario 4: a leave and a re-join between two syncs is read like a re-join" do
    test "cursor = join, then leave and re-join: the visible events since the cursor exactly once, not newly joined" do
      f = world!("joined")
      put_account_data!(f, "org.rj.old", %{"v" => 1})
      ta = S.snapshot!(f.a, S.anchor_room!(f.a))
      assert cursor(f.uid, f.a.dev, f.room).class == "join"

      before_leave = message!(f.o, f.room, "pre")
      S.leave!(f.a, f.room)
      hidden = bulk!(f.room, f.o.uid, 30, S.marker("hid"))
      reinvite_join!(f)
      visible = for i <- 1..2, do: message!(f.o, f.room, "vis#{i}")
      put_account_data!(f, "org.rj.new", %{"v" => 2})

      body = S.sync(f.a, ta)
      assert bodies(body, f.room) == [before_leave | visible], "the message written while still joined, then the two after the re-join (never the hidden 30)"
      events = S.join_timeline(body, f.room)
      member_events = for ev <- events, ev["type"] == "m.room.member" and ev["state_key"] == f.uid, do: get_in(ev, ["content", "membership"])
      assert member_events == ["leave", "join"], "the viewer's own leave and join (visible by the before-or-after rule), the invitation is hidden: #{inspect(member_events)}"
      assert length(events) == 5
      refute limited?(body, f.room)
      refute String.contains?(raw(body), hidden)
      assert room_account_types(body, f.room) == ["org.rj.new"], "base class join: NOT newly joined, only the account data that changed"

      assert event_ids(S.sync(f.a, next(body)), f.room) == [], "exactly once"
    end
  end

  describe "scenario 4: the read does not scan the hidden stretch" do
    test "cursor = join, leave and re-join without a sync: the room read touches the same number of rows for 20 and for 400 hidden events" do
      worlds =
        for n <- [20, 400] do
          f = world!("joined")
          S.leave!(f.a, f.room)
          bulk!(f.room, f.o.uid, n, S.marker("hid"))
          reinvite_join!(f)
          {f, message!(f.o, f.room, "vis")}
        end

      reads =
        for {f, shown} <- worlds do
          {body, reads} = measured_sync(fn -> S.sync(f.a, f.ta) end)
          assert shown in bodies(body, f.room)
          assert [{_fun, rows}] = reads, "ONE room read"
          rows
        end

      [small, big] = reads
      assert big - small <= 10, "400 hidden events: the room read touched #{big} rows, 20 hidden events: #{small}"
      assert big < 300
    end
  end

  # ═══ Scenario 5: invite, join, leave, invite, join ═══════════════════════════════════════════════════════════════════════════

  describe "scenario 5: invite, join, leave, a second invite and a second join of the same room" do
    test "each visible message exactly once, no hidden one, the replay after the last step equals the original" do
      uid = T.provision_user!()
      a = device!(uid, "RJA")
      o = S.user!("RJO")
      room = S.make_room(o, %{"preset" => "private_chat"})
      HV.set_hv!(o, room, "joined")
      t0 = S.snapshot!(a, S.anchor_room!(a))

      S.tick()
      S.invite!(o, room, a)
      s1 = S.sync(a, t0)
      assert S.in_section?(s1, "invite", room)

      h1 = message!(o, room, "h1")
      S.join!(a, room)
      s2 = S.sync(a, next(s1))
      assert S.in_section?(s2, "join", room) and bodies(s2, room) == [], "joined: the join event, nothing written while only invited (hv joined)"

      v1 = message!(o, room, "v1")
      s3 = S.sync(a, next(s2))
      assert bodies(s3, room) == [v1]

      S.leave!(a, room)
      s4 = S.sync(a, next(s3))
      assert S.in_section?(s4, "leave", room)

      h2 = message!(o, room, "h2")
      S.invite!(o, room, a)
      s5 = S.sync(a, next(s4))
      assert S.in_section?(s5, "invite", room)

      h3 = message!(o, room, "h3")
      S.join!(a, room)
      v2 = message!(o, room, "v2")
      last_token = next(s5)
      s6 = S.sync(a, last_token)
      assert bodies(s6, room) == [v2]

      responses = [s1, s2, s3, s4, s5, s6]
      delivered = for body <- responses, ev <- S.join_timeline(body, room) ++ S.leave_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"]
      assert delivered == [v1, v2], "every visible message exactly once in total"
      for hidden <- [h1, h2, h3], body <- responses, do: refute(String.contains?(raw(body), hidden), "a hidden message was delivered")

      replay = S.sync(a, last_token)
      assert rooms_of(replay) == rooms_of(s6), "replaying the previous next_batch after the last step equals the original response"
      assert S.sync(a, next(replay)) |> bodies(room) == [], "and the next sync repeats nothing"
    end
  end

  # ═══ Scenario 6: a late commit inside the lookback ═══════════════════════════════════════════════════════════════════════════

  describe "scenario 6: a late commit inside the 64-position lookback" do
    test "a message committed after the cursor, stamped 1 s before the cursor's newest event, is delivered once" do
      f = world!("shared")

      # 70 events stamped just before now (older than everything the scenario writes): the 64 newest positions at the cursor start after the creation of the room
      now = System.system_time(:millisecond)

      T.privileged_sql!(
        """
        INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
        SELECT '$pad' || md5(g::text || $1), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', 'pad' || g), $3::bigint - 3000 + g, NULL
        FROM generate_series(1, 70) AS g
        """,
        [f.room, f.o.uid, now]
      )

      S.leave!(f.a, f.room)
      lw = S.sync(f.a, f.ta)
      assert cursor(f.uid, f.a.dev, f.room).class == "leave"

      late_ts = newest_ts(f.room) - 1_000
      body_text = S.marker("late")

      assert :ok =
               DB.insert_event(%{
                 "event_id" => "$late" <> T.rand(12),
                 "room_id" => f.room,
                 "sender" => f.o.uid,
                 "type" => "m.room.message",
                 "state_key" => nil,
                 "content" => %{"msgtype" => "m.text", "body" => body_text},
                 "origin_server_ts" => late_ts
               })

      reinvite_join!(f)

      body = S.sync(f.a, next(lw))
      assert bodies(body, f.room) == [body_text], "the late commit is delivered, once"
      assert S.member_ev(S.join_timeline(body, f.room), f.uid, "join")
      assert bodies(S.sync(f.a, next(body)), f.room) == [], "and not again"
    end
  end

  # ═══ D5 / D9: no new log line ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "logs" do
    test "a gated re-join sync and its replay add no line of their own at debug level: no token, no content, no positions, nothing about the segmented read" do
      {f, t1} = invite_world!(15, 2)
      marker = S.marker("secret-body")

      # the test config logs at :warning: lower the level for the request (restored afterwards), or a debug line could never be seen
      original = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug, format: "$metadata| $message\n", metadata: [:mfa]], fn ->
            visible = message!(f.o, f.room, "log")
            first = S.sync(f.a, t1)
            assert visible in bodies(first, f.room)
            S.sync(f.a, t1)
            Logger.flush()
            S.say!(f.o, f.room, marker)
          end)
        after
          Logger.configure(level: original)
        end

      # the capture really ran at debug level and saw the sync requests (the request logger prints one line per request)
      assert log =~ "/_matrix/client/v3/sync", "the debug capture saw no sync request: the test would prove nothing"

      # only the lines of the modules this story changes (the dispatcher and Room.DB): the HTTP request logger prints the whole exchange (query string and response body) at debug,
      # a behaviour that is independent of this story and not judged here. The list may be empty (the read logs nothing of its own): then the assertion below holds trivially and the
      # test pins "adds no line of its own that names a value or the new read".
      own = log |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/mfa=Nebu\.Matrix\.(EventDispatcher\.Server|Room\.DB)\./))

      violations =
        for line <- own,
            {pattern, what} <- [
              {core(t1), "a since token was logged"},
              {f.hidden, "hidden message content was logged"},
              {marker, "message content was logged"},
              {~r/sync_room_cursors|prev_pos|invite_marker|room_pos/, "cursor or position internals were logged"},
              {~r/segmented|re-?join read/i, "a new line about the segmented read (D5: no new log line)"}
            ],
            line =~ pattern,
            do: {what, line}

      assert violations == []
    end
  end
end
