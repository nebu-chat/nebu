defmodule Nebu.Matrix.SyncRejoinRangeScanBoundDispatcherTest do
  @moduledoc """
  Dispatcher-level acceptance tests for story `sync-rejoin-range-scan-bound` (epic oauth-broker, follow-up `cq` (f), REQ-2026-006): `Nebu.Matrix.EventDispatcher.Server.get_initial_sync/2` and
  `get_sync_delta/2` called DIRECTLY on the real stack (real `Nebu.Repo`, real Room.Server / Horde, users and rooms through the HTTP helpers, the since token and the cursors in the real
  tables), with a SPY db module installed as both db seams. D3 (the gate), D2 (the base-0 rule), D5 (the seam, the 503), D6 (the replay, the previous base), D4 (the answer contract).
  `async: false`.

  ## Test design

    * The story's "dispatcher unit tests with the fake modules" are driven with the REAL modules and a spy (as `sync_stream_position_dispatcher_test.exs` decided): a fake that stamps positions
      and answers `latest_member_events/2` would be a second implementation of the gate. The shared unit fakes (`Nebu.Matrix.SyncPositionsFake` and the `FakeDB`s of `sync_test.exs`,
      `sync_membership_partition_test.exs`, `server_dedup_test.exs`) do NOT export the new function: for every gated room of those suites the seam of D5 answers through their plain range read, so
      they stay green UNCHANGED (only `SyncMembershipPartitionTest.FakeDB` reaches a gated room, five reads).
    * The spy (`GateSpy`) delegates every function of `Room.DB`, records `{name, args}` of the three reads that serve a joined room (`fetch_visible_events_in_range/5`,
      `fetch_visible_events_in_range_segmented/5`, `fetch_visible_events/6`), and can make the segmented read fail. `NoSegSpy` is the same WITHOUT the segmented function (a double that does not
      export it: `function_exported?/3` is false). They are installed as `:messages_db_module` and `:rooms_db_module`.
    * The segmented read is reached by name through the spy only (`apply/3`): the function is looked up at runtime, so the file compiles without warnings whatever the module exports.
    * A cursor row is moved with SQL (`sync_room_cursors`) where the scenario needs a position the writers cannot produce (base 0, the member position exactly at the base).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.HistoryVisibilityTestSupport, as: HV
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @stream %{http_request_headers: %{}}
  @table :rj_gate_spy

  # ─── the spies ───────────────────────────────────────────────────────────────

  defmodule GateSpy do
    @moduledoc false
    alias Nebu.Matrix.Room.DB
    @table :rj_gate_spy
    @explicit [:fetch_visible_events_in_range, :fetch_visible_events_in_range_segmented, :fetch_visible_events, :with_read_timeout]

    for {name, arity} <- DB.__info__(:functions), name not in @explicit do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    # the statement timeout wrapper of the request reads: counted, because the /sync reads have NO statement timeout (follow-up `gk` (4), D1 (3))
    def with_read_timeout(fun) do
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), :with_read_timeout, []})
      DB.with_read_timeout(fun)
    end

    # fetch_visible_events/5 is not a joined-room read of /sync (the /messages read): delegated and not recorded
    def fetch_visible_events(room, viewer, dir, limit, from), do: DB.fetch_visible_events(room, viewer, dir, limit, from)
    def fetch_visible_events(room, viewer, dir, limit, from, head), do: record(:fetch_visible_events, [room, viewer, dir, limit, from, head])
    def fetch_visible_events_in_range(room, viewer, after_pos, head, limit), do: record(:fetch_visible_events_in_range, [room, viewer, after_pos, head, limit])

    def fetch_visible_events_in_range_segmented(room, viewer, after_pos, head, limit) do
      if Application.get_env(:nebu, :rj_fail_segmented, false) do
        :ets.insert(@table, {:erlang.unique_integer([:monotonic]), :fetch_visible_events_in_range_segmented, [room, viewer, after_pos, head, limit]})
        {:error, :injected_failure}
      else
        record(:fetch_visible_events_in_range_segmented, [room, viewer, after_pos, head, limit])
      end
    end

    defp record(name, args) do
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), name, args})
      apply(DB, name, args)
    end

    def reset, do: :ets.delete_all_objects(@table)
    def calls(name), do: for({_, ^name, args} <- Enum.sort(:ets.tab2list(@table)), do: args)
    def all, do: :ets.tab2list(@table) |> Enum.sort() |> Enum.map(fn {_, name, args} -> {name, args} end)
  end

  # the same double WITHOUT the segmented read (what the shared unit fakes are)
  defmodule NoSegSpy do
    @moduledoc false
    alias Nebu.Matrix.Room.DB
    @table :rj_gate_spy
    @explicit [:fetch_visible_events_in_range, :fetch_visible_events_in_range_segmented, :fetch_visible_events]

    for {name, arity} <- DB.__info__(:functions), name not in @explicit do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def fetch_visible_events(room, viewer, dir, limit, from), do: DB.fetch_visible_events(room, viewer, dir, limit, from)

    def fetch_visible_events(room, viewer, dir, limit, from, head) do
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), :fetch_visible_events, [room, viewer, dir, limit, from, head]})
      DB.fetch_visible_events(room, viewer, dir, limit, from, head)
    end

    def fetch_visible_events_in_range(room, viewer, after_pos, head, limit) do
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), :fetch_visible_events_in_range, [room, viewer, after_pos, head, limit]})
      DB.fetch_visible_events_in_range(room, viewer, after_pos, head, limit)
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)
    on_exit(fn -> Application.delete_env(:nebu, :rj_fail_segmented) end)
    :ok
  end

  defp install!(mod) do
    if :ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set])
    GateSpy.reset()

    for key <- [:messages_db_module, :rooms_db_module] do
      prior = Application.fetch_env(:event_dispatcher, key)
      Application.put_env(:event_dispatcher, key, mod)

      on_exit(fn ->
        case prior do
          {:ok, v} -> Application.put_env(:event_dispatcher, key, v)
          :error -> Application.delete_env(:event_dispatcher, key)
        end
      end)
    end
  end

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp initial(uid, dev), do: Server.get_initial_sync(%Core.GetInitialSyncRequest{user_id: uid, device_id: dev}, @stream)
  defp delta(uid, dev, token), do: Server.get_sync_delta(%Core.GetSyncDeltaRequest{user_id: uid, device_id: dev, since_token: token, timeout_ms: 0, full_state: false}, @stream)

  # user `a` with one device joined to a private_chat room of `o` (hv `hv`), the device synced
  defp world!(hv \\ "shared") do
    a = S.user!("RDA")
    o = S.user!("RDO")
    dev = "RJD" <> T.rand(3)
    room = S.invite_room(o, [a])
    if hv != "shared", do: HV.set_hv!(o, room, hv)
    S.tick()
    %{a: a, o: o, room: room, dev: dev, t0: initial(a.uid, dev).since_token}
  end

  defp room_of(resp, room), do: Enum.find(resp.rooms, &(&1.room_id == room))
  defp event_ids(resp, room), do: if(r = room_of(resp, room), do: Enum.map(r.timeline_events, & &1.event_id), else: [])
  defp bodies(resp, room), do: if(r = room_of(resp, room), do: for(ev <- r.timeline_events, ev.event_type == "m.room.message", do: Jason.decode!(ev.content)["body"]), else: [])
  defp newly(resp), do: Map.get(resp, :newly_joined_room_ids)
  defp say!(o, room, label), do: (S.tick(); m = S.marker(label); S.say!(o, room, m); m)

  defp cursor(uid, dev, room) do
    case T.sql!("SELECT pos, class, prev_pos, prev_class FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [uid, dev, room]).rows do
      [[pos, class, prev_pos, prev_class]] -> %{pos: pos, class: class, prev_pos: prev_pos, prev_class: prev_class}
      [] -> nil
    end
  end

  defp set_cursor!(w, fields) do
    for {col, value} <- fields do
      T.sql!("UPDATE sync_room_cursors SET #{col} = $4 WHERE user_id = $1 AND device_id = $2 AND room_id = $3", [w.a.uid, w.dev, w.room, value])
    end
  end

  defp head(room), do: T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp pos_of(id), do: T.sql!("SELECT room_pos FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd()

  # `n` messages at ONE timestamp just after the newest event of the room, written with SQL (the invisible stretch of an hv = joined room while the viewer is away)
  defp bulk!(room, sender, n, label) do
    Nebu.Matrix.MembershipStateTestSupport.cleanup_room_events_on_exit(room)
    %{rows: [[newest]]} = T.sql!("SELECT max(origin_server_ts) FROM events WHERE room_id = $1", [room])

    T.privileged_sql!(
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
      SELECT '$rjd' || md5(g::text || $1 || $4), $1, $2, 'm.room.message', jsonb_build_object('msgtype', 'm.text', 'body', $4 || g), $3, NULL
      FROM generate_series(1, $5::int) AS g
      """,
      [room, sender, newest + 1, label, n]
    )

    label
  end

  defp segmented(), do: GateSpy.calls(:fetch_visible_events_in_range_segmented)
  defp plain(), do: GateSpy.calls(:fetch_visible_events_in_range)
  defp paged(), do: GateSpy.calls(:fetch_visible_events)

  # the device synced a LEAVE, then (`n` hidden events written while away) the user was re-invited and joined (the base is a leave, the partition says join): the response that delivered the leave
  defp rejoined!(w, n \\ 0) do
    S.leave!(w.a, w.room)
    d1 = delta(w.a.uid, w.dev, w.t0)
    assert cursor(w.a.uid, w.dev, w.room).class == "leave"
    hidden = if n > 0, do: bulk!(w.room, w.o.uid, n, S.marker("hid"))
    S.tick()
    S.invite!(w.o, w.room, w.a)
    S.join!(w.a, w.room)
    {d1, hidden}
  end

  # ═══ D3: the gate ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D3 the gate" do
    @describetag :integration

    test "base class join, own membership unchanged since: the PLAIN range read, never the segmented one" do
      w = world!()
      m = say!(w.o, w.room, "plain")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, w.t0)
      assert bodies(resp, w.room) == [m]
      assert [[room, uid, after_pos, head_read, 20]] = plain()
      assert {room, uid, head_read} == {w.room, w.a.uid, head(w.room)} and after_pos < head_read
      assert segmented() == [] and paged() == []
    end

    test "base class leave, then re-joined: the SEGMENTED read once with (room, user, base, head, 20), not the plain one" do
      w = world!()
      {d1, _} = rejoined!(w)
      base = cursor(w.a.uid, w.dev, w.room)
      m = say!(w.o, w.room, "after")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, d1.since_token)
      assert m in bodies(resp, w.room)
      assert segmented() == [[w.room, w.a.uid, base.pos, head(w.room), 20]]
      assert plain() == [] and paged() == []
      assert GateSpy.calls(:with_read_timeout) == [], "no statement timeout on /sync reads (follow-up gk (4), story D1 (3))"
      assert cursor(w.a.uid, w.dev, w.room) == %{pos: head(w.room), class: "join", prev_pos: base.pos, prev_class: "leave"}, "the cursor moves to the head exactly as before"
      assert newly(resp) == [w.room], "newly_joined_room_ids is untouched: the base class was not join"
    end

    test "base class invite, then joined: the SEGMENTED read" do
      uid = T.provision_user!()
      a = %{uid: uid, at: T.legacy_session!(uid, "RDI", expires_at: S.session_expiry()).at}
      o = S.user!("RDO")
      room = S.make_room(o, %{"preset" => "private_chat"})
      t0 = initial(uid, "RDI").since_token
      S.tick()
      S.invite!(o, room, a)
      d1 = delta(uid, "RDI", t0)
      assert cursor(uid, "RDI", room).class == "invite"
      S.join!(a, room)
      m = say!(o, room, "post")
      install!(GateSpy)

      resp = delta(uid, "RDI", d1.since_token)
      assert m in bodies(resp, room)
      assert [[^room, ^uid, _after, _head, 20]] = segmented()
      assert plain() == [] and paged() == []
      assert newly(resp) == [room]
    end

    test "base class join, left and re-joined since without a sync: the SEGMENTED read, not newly joined" do
      w = world!()
      before_leave = say!(w.o, w.room, "pre")
      S.leave!(w.a, w.room)
      S.tick()
      S.invite!(w.o, w.room, w.a)
      S.join!(w.a, w.room)
      assert cursor(w.a.uid, w.dev, w.room).class == "join"
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, w.t0)
      assert before_leave in bodies(resp, w.room)
      assert [[_, _, _, _, 20]] = segmented()
      assert plain() == []
      assert newly(resp) == [], "a join base is not newly joined (D4)"
    end

    test "base class join, only a PROFILE change since: the SEGMENTED read (the gate is deliberately broad, OQ2)" do
      w = world!()
      S.insert_member_event!(w.room, w.a.uid, "join", w.a.uid, S.ts_after(w.room), %{"displayname" => "Renamed"})
      m = say!(w.o, w.room, "after-rename")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, w.t0)
      assert m in bodies(resp, w.room)
      assert [[_, _, _, _, 20]] = segmented()
      assert plain() == []
    end

    test "member position AT the base is no change (plain), one below it is a change (segmented)" do
      for {offset, expected} <- [{0, :plain}, {-1, :segmented}] do
        w = world!()
        latest = T.sql!("SELECT max(room_pos) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2", [w.room, w.a.uid]).rows |> hd() |> hd()
        assert is_integer(latest)
        m = say!(w.o, w.room, "boundary")
        set_cursor!(w, pos: latest + offset, class: "join")
        install!(GateSpy)

        resp = delta(w.a.uid, w.dev, w.t0)
        assert m in bodies(resp, w.room)
        {used, unused} = if expected == :plain, do: {plain(), segmented()}, else: {segmented(), plain()}
        assert length(used) == 1 and unused == [], "base position #{latest + offset}, the viewer's newest member event at #{latest}: expected the #{expected} read, got #{inspect(GateSpy.all())}"
      end
    end

    test "base class leave / invite with the base position AT the viewer's newest member event (cq (a): the head was read after the join): the gate keys on the CLASS, SEGMENTED" do
      for class <- ["leave", "invite"] do
        w = world!()
        latest = T.sql!("SELECT max(room_pos) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2", [w.room, w.a.uid]).rows |> hd() |> hd()
        m = say!(w.o, w.room, "cq-a")
        set_cursor!(w, pos: latest, class: class)
        install!(GateSpy)

        resp = delta(w.a.uid, w.dev, w.t0)
        assert m in bodies(resp, w.room)
        assert length(segmented()) == 1 and plain() == [], "class #{class}, base AT the member position: #{inspect(GateSpy.all())}"
      end
    end

    test "D-A5 skew: the newest member event BY TIMESTAMP is at or below the base, the second newest (older timestamp, higher position) is above it: ONE segmented read, no plain read" do
      for variant <- [:position_below_base, :position_missing] do
        w = world!()

        [f_id, f_pos, f_ts] =
          T.sql!("SELECT event_id, room_pos, origin_server_ts FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 ORDER BY origin_server_ts DESC LIMIT 1", [w.room, w.a.uid]).rows |> hd()

        base = cursor(w.a.uid, w.dev, w.room).pos
        n_id = S.insert_member_event!(w.room, w.a.uid, "join", w.a.uid, f_ts - 1, %{"displayname" => "Skewed"})
        if variant == :position_missing, do: T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE event_id = $1", [f_id])
        m = say!(w.o, w.room, "skew")

        # self-checks: the fixture is what it claims to be (the partition orders by TIMESTAMP, the gate must look at positions)
        assert f_pos <= base and base < pos_of(n_id), "fixture: F at or below the base, N above it"
        assert {:ok, %{} = by_room} = Nebu.Matrix.Room.DB.latest_member_events([w.room], w.a.uid)
        assert [first, second | _] = by_room[w.room]
        assert {first.event_id, second.event_id} == {f_id, n_id}, "fixture: latest = F (newest timestamp), previous = N"

        install!(GateSpy)
        resp = delta(w.a.uid, w.dev, w.t0)
        assert m in bodies(resp, w.room)
        assert length(segmented()) == 1 and plain() == [], "#{variant}: a gate that reads only `latest` takes the unbounded plain walk here: #{inspect(GateSpy.all())}"
      end
    end

    test "the newest member event has NO position (legacy): no change since the base, the PLAIN read" do
      w = world!()
      T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2", [w.room, w.a.uid])
      m = say!(w.o, w.room, "legacy-member")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, w.t0)
      assert m in bodies(resp, w.room)
      assert length(plain()) == 1 and segmented() == [] and paged() == []
    end

    test "a room that did not move reads nothing, whatever its base class (head <= base)" do
      w = world!()
      {d1, _} = rejoined!(w)
      d2 = delta(w.a.uid, w.dev, d1.since_token)
      assert cursor(w.a.uid, w.dev, w.room).pos == head(w.room)
      set_cursor!(w, class: "leave")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, d2.since_token)
      assert resp.rooms == []
      assert GateSpy.all() == [], "no statement for a quiet room, gated or not: #{inspect(GateSpy.all())}"
    end
  end

  # ═══ D2: base position 0 ═══════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D2 base position 0 has no event to anchor the floor: read as an ABSENT base" do
    @describetag :integration

    test "a gated room with base 0 is read by the head-bounded page read (legacy events included)" do
      w = world!()
      msgs = for i <- 1..3, do: say!(w.o, w.room, "legacy#{i}")
      T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1 AND event_type = 'm.room.message'", [w.room])
      t1 = initial(w.a.uid, w.dev).since_token
      set_cursor!(w, pos: 0, class: "leave")
      fresh = say!(w.o, w.room, "positioned")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, t1)
      assert [[room, uid, "b", 20, "", head_read]] = paged()
      assert {room, uid, head_read} == {w.room, w.a.uid, head(w.room)}
      assert segmented() == [] and plain() == []
      assert Enum.take(bodies(resp, w.room), -4) == msgs ++ [fresh], "the newest 20 visible events up to the head, legacy events (no position) included: the absent-base read"
    end

    test "a gated JOIN-class room with base 0 re-sends what the device already has (absent-base read, documented)" do
      w = world!()
      old = say!(w.o, w.room, "delivered-before")
      t1 = initial(w.a.uid, w.dev).since_token
      set_cursor!(w, pos: 0, class: "join")
      fresh = say!(w.o, w.room, "new")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, t1)
      assert [[_, _, "b", 20, "", _]] = paged()
      assert segmented() == [] and plain() == []
      assert bodies(resp, w.room) == [old, fresh], "the absent-base read has no base to cut at: the message delivered earlier is sent again (a join cursor at position 0 only exists for a room that had no positioned event)"
    end

    test "an UNGATED room with base 0 keeps the plain range: legacy events are no part of a position range" do
      w = world!()
      msgs = for i <- 1..2, do: say!(w.o, w.room, "legacy#{i}")
      T.privileged_sql!("UPDATE events SET room_pos = NULL WHERE room_id = $1", [w.room])
      t1 = initial(w.a.uid, w.dev).since_token
      set_cursor!(w, pos: 0, class: "join")
      fresh = say!(w.o, w.room, "positioned")
      install!(GateSpy)

      resp = delta(w.a.uid, w.dev, t1)
      assert bodies(resp, w.room) == [fresh], "(0, head]: the unpositioned events are not delivered"
      assert Enum.all?(msgs, &(&1 not in bodies(resp, w.room)))
      assert length(plain()) == 1 and segmented() == [] and paged() == []
    end
  end

  # ═══ D5: the seam ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D5 the seam: a db module without the segmented read answers a gated room through its plain range read" do
    @describetag :integration

    test "the double does not export the function (premise), the real Room.DB does" do
      refute function_exported?(NoSegSpy, :fetch_visible_events_in_range_segmented, 5)
      assert function_exported?(Nebu.Matrix.Room.DB, :fetch_visible_events_in_range_segmented, 5)
    end

    test "a gated room is delivered through the double plain range read: same events, same cursor" do
      w = world!()
      {d1, _} = rejoined!(w)
      base = cursor(w.a.uid, w.dev, w.room)
      m = say!(w.o, w.room, "seam")
      install!(NoSegSpy)

      resp = delta(w.a.uid, w.dev, d1.since_token)
      assert m in bodies(resp, w.room)
      assert [[room, uid, after_pos, head_read, 20]] = GateSpy.calls(:fetch_visible_events_in_range)
      assert {room, uid, after_pos, head_read} == {w.room, w.a.uid, base.pos, head(w.room)}
      assert cursor(w.a.uid, w.dev, w.room).pos == head(w.room)
    end
  end

  # ═══ D5: a failed read is the handled 503, nothing persisted ═════════════════════════════════════════════════════════════════

  defp state_rows(uid) do
    {T.sql!("SELECT device_id, to_jsonb(t)::text FROM sync_tokens t WHERE user_id = $1 ORDER BY 1", [uid]).rows,
     T.sql!("SELECT device_id || '|' || room_id, to_jsonb(c)::text FROM sync_room_cursors c WHERE user_id = $1 ORDER BY 1", [uid]).rows}
  end

  describe "D5 a failing segmented read" do
    @describetag :integration

    test "is a handled 503 with one value-free ERROR line, nothing persisted, and the same token delivers later" do
      uid = T.provision_user!()
      dev = "RJF" <> String.upcase(T.rand(3))
      a = %{uid: uid, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
      o = S.user!("RDO")
      room = S.invite_room(o, [a])
      ta = S.snapshot!(a, S.anchor_room!(a))
      S.leave!(a, room)
      lw = S.sync(a, ta)
      assert S.in_section?(lw, "leave", room)
      S.tick()
      S.invite!(o, room, a)
      S.join!(a, room)
      m = say!(o, room, "must-not-leak")
      install!(GateSpy)
      before = state_rows(uid)

      Application.put_env(:nebu, :rj_fail_segmented, true)

      log =
        capture_log([level: :error], fn ->
          conn = S.sync_conn(a, since: lw["next_batch"], timeout: 0)
          assert conn.status == 503, "got #{conn.status}"
          assert T.json(conn) == %{"errcode" => "M_UNAVAILABLE", "error" => "Core is temporarily unavailable"}
          refute String.contains?(conn.resp_body, m)
        end)

      assert [_] = Regex.scan(~r/history visibility: the events of .* could not be read/, log), "one value-free ERROR line, got: #{log}"
      refute String.contains?(log, m), "no message content in the log"
      assert state_rows(uid) == before, "no token and no cursor was persisted by the failed sync"
      assert [[^room, ^uid, _, _, 20]] = segmented(), "the failure was the segmented read"

      Application.put_env(:nebu, :rj_fail_segmented, false)
      resp = S.sync(a, lw["next_batch"])
      assert m in bodies_of_http(resp, room), "the next sync with the same token delivers the event"
    end

    test "does not fail a room that is not gated (the plain read is not the segmented one)" do
      w = world!()
      m = say!(w.o, w.room, "control")
      install!(GateSpy)
      Application.put_env(:nebu, :rj_fail_segmented, true)

      resp = delta(w.a.uid, w.dev, w.t0)
      assert m in bodies(resp, w.room)
      assert segmented() == []
    end
  end

  defp bodies_of_http(body, room), do: for(ev <- S.join_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])

  # ═══ D6: the replay ═════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "D6 the replay selects the previous base; the gate and the read depend only on that base and the head" do
    @describetag :integration

    test "no event in between: the replay equals the first and reads with the SAME arguments" do
      w = world!("joined")
      {d1, hidden} = rejoined!(w, 12)
      base = cursor(w.a.uid, w.dev, w.room)
      shown = for i <- 1..2, do: say!(w.o, w.room, "vis#{i}")
      install!(GateSpy)

      first = delta(w.a.uid, w.dev, d1.since_token)
      replay = delta(w.a.uid, w.dev, d1.since_token)
      assert replay.fallback_to_initial == false
      assert bodies(first, w.room) == shown
      assert Enum.all?(bodies(first, w.room), &(not String.starts_with?(&1, hidden)))
      assert length(event_ids(first, w.room)) == 3, "the join event and the two visible messages"

      assert event_ids(replay, w.room) == event_ids(first, w.room)
      assert room_of(replay, w.room).limited == room_of(first, w.room).limited
      assert room_of(replay, w.room).prev_batch == room_of(first, w.room).prev_batch
      assert newly(replay) == newly(first) and newly(first) == [w.room]

      assert [one, two] = segmented()
      assert one == two, "the replay reads the same base and head: (#{inspect(one)}) vs (#{inspect(two)})"
      assert [_room, _uid, after_pos, head_read, 20] = one
      assert after_pos == base.pos and head_read == head(w.room)
      assert plain() == [] and paged() == []
    end

    test "events in between: the replay equals the first plus those events, `limited` recomputed" do
      w = world!("shared")
      {d1, _} = rejoined!(w)
      first_msgs = for i <- 1..17, do: say!(w.o, w.room, "a#{i}")
      install!(GateSpy)

      first = delta(w.a.uid, w.dev, d1.since_token)
      assert length(event_ids(first, w.room)) == 19, "the invitation, the join and 17 messages"
      refute room_of(first, w.room).limited

      extra = for i <- 1..3, do: say!(w.o, w.room, "b#{i}")
      replay = delta(w.a.uid, w.dev, d1.since_token)
      assert room_of(replay, w.room).limited, "22 events since the cursor: the newest 20 and limited"
      assert bodies(replay, w.room) == first_msgs ++ extra, "the invitation and the join (the two oldest) fell out of the newest 20, nothing else changed"
      assert room_of(replay, w.room).prev_batch =~ ~r/\Av1_/
    end
  end

  # ═══ D4: the answer contract (limited / prev_batch / order) through the real dispatcher ═══════════════════════════════════════

  describe "D4 limited / prev_batch / order of a gated room" do
    @describetag :integration

    test "20 visible events are not limited, 21 are: newest 20 by position, prev_batch of the oldest delivered" do
      w = world!("shared")
      {d1, _} = rejoined!(w)
      msgs = for i <- 1..18, do: say!(w.o, w.room, "c#{i}")
      install!(GateSpy)

      exactly = delta(w.a.uid, w.dev, d1.since_token)
      assert length(event_ids(exactly, w.room)) == 20, "the invitation, the join and 18 messages are exactly 20 events"
      refute room_of(exactly, w.room).limited
      assert room_of(exactly, w.room).prev_batch == "", "no prev_batch when not limited"

      more = say!(w.o, w.room, "c19")
      over = delta(w.a.uid, w.dev, d1.since_token)
      ids = event_ids(over, w.room)
      assert length(ids) == 20 and room_of(over, w.room).limited, "21 events since the cursor: the newest 20, limited"
      assert bodies(over, w.room) == msgs ++ [more]
      positions = Enum.map(ids, &pos_of/1)
      assert positions == Enum.sort(positions), "ascending by position (stream order)"
      oldest = hd(ids)
      assert room_of(over, w.room).prev_batch == Nebu.Matrix.Room.DB.pagination_token(%{"origin_server_ts" => ts_of(oldest), "event_id" => oldest})
    end
  end

  defp ts_of(id), do: T.sql!("SELECT origin_server_ts FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd()
end
