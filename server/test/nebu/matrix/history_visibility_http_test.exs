defmodule Nebu.Matrix.HistoryVisibilityHttpTest do
  @moduledoc """
  Story `history-visibility-enforcement` (epic oauth-broker, follow-up `es`), the HTTP half: AC1 - AC5 (a) - (e), AC8, AC9, AC12, AC13, AC16 (a), AC18, AC19 and the Oracle
  tests AC22 (1) - (10), (13), (14). Real stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, the real `Room.Server` under Horde, users and legacy sessions as in the
  moderation suites (random localparts, `:server_name` pinned, sessions that expire beyond the `Session.RefreshWorker` lookahead). Every room is an own room. `async: false`.
  The upgrade test (AC22 (11)) lives in `history_visibility_upgrade_http_test.exs`; the fragment itself (segments, ties, JSONB forms, EXPLAIN, the model) in
  `room/history_visibility_db_test.exs`; the race in `history_visibility_concurrency_test.exs`.

  Shared helpers: `Nebu.Matrix.HistoryVisibilityTestSupport` (the decisions of the ATDD step are listed in ITS moduledoc: the binding names, "no `end`" = absent or `""`, what "leak"
  means). A refusal / invisibility test asserts that NOTHING leaks: neither the event id nor the marker of a hidden event appears ANYWHERE in the raw response (also not in
  `unsigned.prev_content`, `unsigned.redacted_because`, search results, `next_batch` / `end` / `prev_batch`), and every negative assertion has a positive control (the same read
  by the room creator, the same read in a `shared` room, the visible neighbour events).

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC1 (d) says B's first backward page "returns m3 and B's join (2 events) and no `end`": the createRoom chain, the preset's hv event and A's hv event lie BEFORE the setting
      took effect and are visible (D3, AC1 (a)), so the page has MORE than two events. The test asserts: the page starts with m3 and B's join, every page is filled with `limit`
      visible events (invisible ones are skipped, never a short page), `end` is present while visible events remain and absent on the last page, the walk equals the single big page.
    * AC5 (a)-(d) use a `public_chat` room (a leaver re-joins without a new invitation, so the gap holds exactly the events the story names); the invite-based re-join is AC22 (1).
    * AC22 (4): `/relations` has no pagination today (`from` is ignored, `next_batch` is always `""`): the test pins "the page is filled from visible children, `limit` counts visible children only,
      `dir=f` starts at the first visible child, `next_batch` stays empty"; the two-pages wording of the story cannot be exercised without a new feature (reported).
    * AC22 (2): the `prev_batch` of an INCREMENTAL `/sync` is the event id of the oldest delivered event (today's behaviour, not a `/messages` token): the test pins "limited true and a
      non-empty `prev_batch` that is the oldest delivered event"; the initial `/sync`'s `prev_batch` is a real token and is used for pagination (AC22 (3)).
    * AC13: the statement counts were MEASURED on the code before this story (`@baseline`), with the fixture of `count_fixture!/0`; the numbers are the contract of "no new statement".
    * AC19: the log capture covers the read paths at DEBUG (the existing request logger redactor is unchanged); the sends of the fixtures are outside the capture.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.HistoryVisibilityTestSupport
  import Nebu.Matrix.MembershipStateTestSupport,
    only: [setup_env!: 0, count_statements: 3, slots: 1, members!: 3, initial_sync!: 2, strip_age: 1, unknown_room: 0]

  alias Nebu.Matrix.HistoryVisibilityTestSupport.Hooks
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  @keys ["prev_content", "prev_sender", "replaces_state"]

  setup do
    setup_env!()
    on_exit(&Hooks.cleanup/0)
    :ok
  end

  # ─── helpers of this suite ───────────────────────────────────────────────────

  # every event id A (the creator, always allowed to see everything of his own rooms) reads in `room`
  defp all_ids(user, room) do
    {chunk, _body, _raw} = msgs!(user, room)
    ids(chunk)
  end

  defp type_in?(chunk, type), do: Enum.any?(chunk, &(&1["type"] == type))

  defp unsigned_keys(ev), do: Map.keys(ev["unsigned"] || %{}) |> Enum.filter(&(&1 in @keys))

  # a public room of `owner` with the setting `value` (a second hv event after the preset's `shared`)
  defp public_hv_room!(owner, value) do
    room = public_room(owner)
    set_hv!(owner, room, value)
    room
  end

  # ═══ AC1: joined ═════════════════════════════════════════════════════════════════════════════════

  describe "AC1 - joined (the later joiner B)" do
    setup do
      {:ok, s: scenario!("joined")}
    end

    test "(a)(c)(14) B's page is A's page minus topic, m1, invite and m2; join, m3, hv event and the createRoom chain are in", %{s: s} do
      {a_chunk, _, a_raw} = msgs!(s.a, s.room)
      a_ids = ids(a_chunk)

      assert_shown!(a_chunk, a_raw, [s.m1, s.m2, s.m3])
      for id <- [s.invite, s.join, s.hv, s.topic_event], do: assert(id in a_ids, "control: A sees every event of the room")

      {b_chunk, b_body, b_raw} = msgs!(s.b, s.room)

      assert ids(b_chunk) == a_ids -- [s.topic_event, s.m1.id, s.invite, s.m2.id], "B's page is exactly A's page without the four invisible events (order kept)"
      assert_shown!(b_chunk, b_raw, [s.m3])
      assert Enum.take(ids(b_chunk), 2) == [s.m3.id, s.join], "newest first: m3, then B's own join"
      assert s.hv in ids(b_chunk), "the hv event lies before the setting took effect (D5 (a)): visible"
      assert type_in?(b_chunk, "m.room.create"), "the createRoom chain before the first hv event is shared (D3): visible"
      assert end_absent?(b_body), "all visible events fit the page: no `end`"
      refute_leak!(b_raw, [s.m1, s.m2, s.invite])
      refute String.contains?(b_raw, s.topic), "the topic text of the invisible topic event is not in the page"
      refute s.topic_event in ids(b_chunk)
    end

    test "(b) B's initial /sync timeline is A's timeline without the same four events, his join and m3 are in, `state` holds the CURRENT state (topic, A, B)", %{s: s} do
      {a_tl, _entry, _raw} = initial_timeline!(s.a, s.room)
      a_ids = ids(a_tl)
      assert length(a_ids) < 20, "fixture: the whole room fits A's 20-event window, nothing is cut"
      for id <- [s.m1.id, s.m2.id, s.invite, s.topic_event], do: assert(id in a_ids, "control: A's timeline has it")

      {b_tl, entry, raw} = initial_timeline!(s.b, s.room)

      assert ids(b_tl) == a_ids -- [s.topic_event, s.m1.id, s.invite, s.m2.id]
      assert s.join in ids(b_tl) and s.m3.id in ids(b_tl)
      refute_leak!(raw, [s.m1, s.m2, s.invite])
      assert entry["timeline"]["limited"] == false, "fewer visible events than the limit: not limited"

      state = entry["state"]["events"]
      assert topic = Enum.find(state, &(&1["type"] == "m.room.topic")), "the current topic is state, not gated (D11 (a))"
      assert topic["content"] == %{"topic" => s.topic} and topic["event_id"] == s.topic_event
      joined = (state ++ b_tl) |> Enum.filter(&(&1["type"] == "m.room.member")) |> Enum.map(& &1["state_key"]) |> Enum.sort()
      assert s.a.uid in joined and s.b.uid in joined, "both members are known to B (state or timeline)"
    end

    test "(d)(14) 30 pre-invite messages, small pages: every backward page is full, `end` while visible events remain, dir=f starts at create", %{} do
      a = user!("HVA")
      b = user!("HVB")
      {room, _hv} = hv_room!(a, "joined")
      pre = for i <- 1..30, do: say_m!(a, room, "p#{i}x")
      invite_ev!(a, room, b)
      join = join_ev!(b, room)
      m3 = say_m!(a, room, "m3x")

      {big, big_body, _raw} = msgs!(b, room)
      visible = ids(big)
      assert length(visible) > 6, "fixture: more visible events than a few pages (the createRoom chain and the hv events)"
      refute Enum.any?(pre, &(&1.id in visible)), "none of the 30 is visible"
      assert Enum.take(visible, 2) == [m3.id, join]
      assert end_absent?(big_body)

      # the story's literal limit: 10 - one page when all visible events fit it, else `end` is there
      {ten, ten_body, _} = msgs!(b, room, "dir=b&limit=10")
      assert Enum.take(ids(ten), 2) == [m3.id, join], "B's first page starts with m3 and B's join"
      assert end_absent?(ten_body) == (length(visible) <= 10)

      limit = 4
      pages = walk!(b, room, "b", limit)
      assert walked_ids(pages) == visible, "the walk equals the single big page (no gaps, no duplicates)"
      assert [first | _] = pages
      assert Enum.take(ids(elem(first, 0)), 2) == [m3.id, join]

      {last, others} = List.pop_at(pages, -1)
      assert end_absent?(elem(last, 1)), "the last page has no `end`"

      for {chunk, body} <- others do
        assert length(chunk) == limit, "a page is FILLED from visible events, never short because of invisible ones"
        refute end_absent?(body), "positive control of the omission rule: `end` is present while visible events remain"
      end

      assert length(pages) == div(length(visible) - 1, limit) + 1, "no extra empty page"

      {fwd, _, fwd_raw} = msgs!(b, room, "dir=f&limit=100")
      assert ids(fwd) == Enum.reverse(visible), "the forward page is the backward page reversed"
      assert hd(fwd)["type"] == "m.room.create", "dir=f without `from` starts at the first VISIBLE event"
      for p <- pre, do: refute_leak!(fwd_raw, p)

      f_pages = walk!(b, room, "f", 3)
      assert walked_ids(f_pages) == Enum.reverse(visible), "paginating forward in small pages gives the same visible events"

      # control: A walks all of it
      a_pages = walk!(a, room, "b", 10)
      assert Enum.all?(pre, &(&1.id in walked_ids(a_pages))), "control: A paginates over all 30"
    end
  end

  # ═══ AC2: invited ════════════════════════════════════════════════════════════════════════════════

  describe "AC2 - invited" do
    test "C sees m2, m3, his invite and join but not m1 and not the topic; the initial /sync timeline is the same subset" do
      s = scenario!("invited")
      {a_chunk, _, _} = msgs!(s.a, s.room)
      a_ids = ids(a_chunk)

      {c_chunk, c_body, c_raw} = msgs!(s.b, s.room)
      assert ids(c_chunk) == a_ids -- [s.topic_event, s.m1.id], "only what lies before the invitation is hidden"
      assert_shown!(c_chunk, c_raw, [s.m2, s.m3])
      assert s.invite in ids(c_chunk) and s.join in ids(c_chunk), "under `invited` his invitation is visible (D5 (b))"
      assert end_absent?(c_body)
      refute_leak!(c_raw, [s.m1])

      {a_tl, _, _} = initial_timeline!(s.a, s.room)
      {c_tl, _entry, raw} = initial_timeline!(s.b, s.room)
      assert ids(c_tl) == ids(a_tl) -- [s.topic_event, s.m1.id]
      refute_leak!(raw, [s.m1])
    end
  end

  # ═══ AC3: shared, no setting, world_readable, unknown values, /send ═══════════════════════════════

  describe "AC3 - shared, world_readable and unreadable values" do
    test "(a) shared: the later joiner D sees m1, m2, m3 (and the topic) - exactly A's page" do
      s = scenario!("shared")
      {a_chunk, _, _} = msgs!(s.a, s.room)
      {d_chunk, _, d_raw} = msgs!(s.b, s.room)
      assert ids(d_chunk) == ids(a_chunk)
      assert_shown!(d_chunk, d_raw, [s.m1, s.m2, s.m3])
      assert s.invite in ids(d_chunk) and s.topic_event in ids(d_chunk)
    end

    test "(a) a room WITHOUT any hv event reads as shared for the later joiner" do
      a = user!("HVA")
      b = user!("HVB")
      room = make_room(a, %{"preset" => "private_chat"})
      assert %{num_rows: 1} = T.privileged_sql!("DELETE FROM events WHERE room_id = $1 AND event_type = $2", [room, hv_type()]), "fixture: the preset wrote exactly ONE hv event"
      m1 = say_m!(a, room, "m1x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      m3 = say_m!(a, room, "m3x")

      {chunk, _, raw} = msgs!(b, room)
      assert_shown!(chunk, raw, [m1, m3])
      assert ids(chunk) == all_ids(a, room), "a room without a setting reads as shared"
    end

    test "(b) world_readable: the later joiner sees everything, like shared" do
      s = scenario!("world_readable")
      {a_chunk, _, _} = msgs!(s.a, s.room)
      {chunk, _, raw} = msgs!(s.b, s.room)
      assert ids(chunk) == ids(a_chunk)
      assert_shown!(chunk, raw, [s.m1, s.m2, s.m3])
    end

    test "(c) unknown / non-string / missing / unparseable values read as shared; valid `joined` in both JSONB forms restricts" do
      variants = [
        {"nonsense value", fn room, a, ts -> put_event!(room, a, hv_type(), %{"history_visibility" => "nonsense"}, ts, "") end},
        {"number", fn room, a, ts -> put_event!(room, a, hv_type(), %{"history_visibility" => 7}, ts, "") end},
        {"empty object", fn room, a, ts -> put_event!(room, a, hv_type(), %{}, ts, "") end},
        {"JSON string content (bare text)", fn room, a, ts -> put_hv_string!(room, a, "joined", ts) end},
        {"JSON string content (a JSON string scalar)", fn room, a, ts -> put_hv_string!(room, a, ~s("joined"), ts) end}
      ]

      for {label, insert} <- variants do
        a = user!("HVA")
        d = user!("HVD")
        room = make_room(a, %{"preset" => "private_chat"})
        tick()
        insert.(room, a, ts_after(room))
        tick()
        m1 = say_m!(a, room, "m1x")
        invite_ev!(a, room, d)
        join_ev!(d, room)
        {chunk, _, raw} = msgs!(d, room)
        assert m1.id in ids(chunk) and String.contains?(raw, m1.marker), "#{label}: read as shared, the later joiner sees m1"
      end

      # controls: the SAME insertions with a valid restrictive value restrict - the technique works and both JSONB forms are read
      controls = [
        {"object", fn room, a, ts -> put_hv_event!(room, a, "joined", ts) end},
        {"double-encoded string", fn room, a, ts -> put_hv_string!(room, a, Jason.encode!(%{"history_visibility" => "joined"}), ts) end}
      ]

      for {label, insert} <- controls do
        a = user!("HVA")
        d = user!("HVD")
        room = make_room(a, %{"preset" => "private_chat"})
        tick()
        insert.(room, a, ts_after(room))
        tick()
        m1 = say_m!(a, room, "m1x")
        invite_ev!(a, room, d)
        join_ev!(d, room)
        {chunk, _, raw} = msgs!(d, room)
        refute m1.id in ids(chunk), "#{label}: a valid `joined` hides m1"
        refute_leak!(raw, m1)
      end
    end

    test "(d) a /send of the hv type (state_key NULL) changes nothing; PUT /state with the same content restricts" do
      a = user!("HVA")
      b = user!("HVB")
      room = make_room(a, %{"preset" => "private_chat"})
      tick()
      conn = T.matrix_request(:put, path(room, "send/#{hv_type()}/#{T.rand(6)}"), a.at, body: %{"history_visibility" => "joined"})
      send_id = ok_event!(conn, "send hv")
      assert [[nil]] = T.sql!("SELECT state_key FROM events WHERE event_id = $1", [send_id]).rows, "fixture: stored as a NON-state event"
      m1 = say_m!(a, room, "m1x")
      invite_ev!(a, room, b)
      join_ev!(b, room)

      {chunk, _, raw} = msgs!(b, room)
      assert_shown!(chunk, raw, [m1])
      assert ids(chunk) == all_ids(a, room), "the /send event is not state: the room stays shared"

      # control
      {room2, _} = hv_room!(a, "joined")
      m1b = say_m!(a, room2, "m1y")
      invite_ev!(a, room2, b)
      join_ev!(b, room2)
      {chunk2, _, raw2} = msgs!(b, room2)
      refute m1b.id in ids(chunk2)
      refute_leak!(raw2, m1b)
    end
  end

  # ═══ AC4: changes of the setting affect later events only ════════════════════════════════════════

  describe "AC4 - the setting at the time of the event decides" do
    test "shared -> joined -> shared: E (joined later) sees m1 and m3 and all three hv events, NOT m2" do
      a = user!("HVA")
      e = user!("HVE")
      room = make_room(a, %{"preset" => "private_chat"})
      [preset_hv] = for [id] <- T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND event_type = $2", [room, hv_type()]).rows, do: id
      m1 = say_m!(a, room, "m1x")
      hv_joined = set_hv!(a, room, "joined")
      m2 = say_m!(a, room, "m2x")
      hv_shared = set_hv!(a, room, "shared")
      m3 = say_m!(a, room, "m3x")
      invite_ev!(a, room, e)
      join_ev!(e, room)

      {chunk, _, raw} = msgs!(e, room)
      assert_shown!(chunk, raw, [m1, m3])
      refute m2.id in ids(chunk)
      refute_leak!(raw, m2)

      for id <- [preset_hv, hv_joined, hv_shared], do: assert(id in ids(chunk), "all three hv events are visible (D5 (a))")
      {a_chunk, _, _} = msgs!(a, room)
      assert ids(chunk) == ids(a_chunk) -- [m2.id], "E's page is A's page without m2"
    end
  end

  # ═══ AC5: leavers, re-joiners, bans ══════════════════════════════════════════════════════════════

  describe "AC5 - the gap of a re-joiner" do
    test "(a) joined: F joins, m1, leaves, m2, re-joins, m3: F sees m1, m3 and his own events, NOT m2; `end` positive control" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join1 = join_ev!(f, room)
      m1 = say_m!(a, room, "m1x")
      leave = leave_ev!(f, room)
      m2 = say_m!(a, room, "m2x")
      join2 = join_ev!(f, room)
      m3 = say_m!(a, room, "m3x")

      a_ids = all_ids(a, room)
      {chunk, body, raw} = msgs!(f, room)
      assert ids(chunk) == a_ids -- [m2.id], "F's page is A's page without the gap"
      assert_shown!(chunk, raw, [m1, m3])
      for id <- [join1, leave, join2], do: assert(id in ids(chunk), "F's own member events are visible (D5 (b))")
      refute_leak!(raw, m2)
      assert end_absent?(body)

      # (14) the omission rule: a smaller page carries `end`, the next page returns the rest and then no `end`
      limit = length(ids(chunk)) - 1
      {first, first_body, _} = msgs!(f, room, "dir=b&limit=#{limit}")
      assert length(first) == limit and not end_absent?(first_body), "`end` is present when visible events remain"
      {rest, rest_body, rest_raw} = msgs!(f, room, "dir=b&limit=#{limit}&from=" <> URI.encode_www_form(first_body["end"]))
      assert ids(first) ++ ids(rest) == ids(chunk), "the two pages are the visible events"
      assert end_absent?(rest_body)
      refute_leak!(rest_raw, m2)
    end

    test "(b) shared: the same sequence, F sees m2 (S3 rule 3: he joined after it was sent)" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "shared")
      join_ev!(f, room)
      say_m!(a, room, "m1x")
      leave_ev!(f, room)
      m2 = say_m!(a, room, "m2x")
      join_ev!(f, room)
      say_m!(a, room, "m3x")

      {chunk, _, raw} = msgs!(f, room)
      assert ids(chunk) == all_ids(a, room)
      assert_shown!(chunk, raw, [m2])
    end

    test "(c) a kick instead of the leave: F sees the kick event (his own), not the gap; a ban + unban: F sees the ban event, not the unban event, not the gap" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join_ev!(f, room)
      m1 = say_m!(a, room, "m1x")
      kick = kick_ev!(a, room, f)
      m2 = say_m!(a, room, "m2x")
      join_ev!(f, room)
      m3 = say_m!(a, room, "m3x")

      {chunk, _, raw} = msgs!(f, room)
      assert ids(chunk) == all_ids(a, room) -- [m2.id]
      assert kick in ids(chunk), "the kick event of F is visible to F (D5 (b))"
      assert_shown!(chunk, raw, [m1, m3])
      refute_leak!(raw, m2)

      # ban + unban
      g = user!("HVG")
      room2 = public_hv_room!(a, "joined")
      join_ev!(g, room2)
      n1 = say_m!(a, room2, "n1x")
      ban = ban_ev!(a, room2, g)
      unban = unban_ev!(a, room2, g)
      n2 = say_m!(a, room2, "n2x")
      join_ev!(g, room2)
      n3 = say_m!(a, room2, "n3x")

      {chunk2, _, raw2} = msgs!(g, room2)
      assert ids(chunk2) == all_ids(a, room2) -- [unban, n2.id], "the ban event is visible, the unban event (ban -> leave) and the gap are not"
      assert ban in ids(chunk2)
      assert_shown!(chunk2, raw2, [n1, n3])
      refute_leak!(raw2, [n2, unban])
    end

    test "(d) the incremental /sync of F after his re-join (his since token from before the leave, joined room): the timeline has m3 and his own events, NOT m2" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join_ev!(f, room)
      say_m!(a, room, "m1x")
      anchor = anchor_room!(f)
      token = snapshot!(f, anchor)
      leave = leave_ev!(f, room)
      m2 = say_m!(a, room, "m2x")
      join2 = join_ev!(f, room)
      m3 = say_m!(a, room, "m3x")

      conn = sync_conn(f, since: token, timeout: 0)
      assert conn.status == 200
      body = T.json(conn)
      assert in_section?(body, "join", room), "F is joined again: the room is in rooms.join"
      tl = ids(join_timeline(body, room))
      assert m3.id in tl and leave in tl and join2 in tl
      refute m2.id in tl
      refute_leak!(conn.resp_body, m2)

      # control: the same delta for A holds m2
      a_conn = sync_conn(a, since: nil, timeout: 0)
      assert T.json(a_conn) |> join_timeline(room) |> ids() |> Enum.member?(m2.id)
    end

    test "(e) a left and a banned user get 403 M_FORBIDDEN on /messages, /event and /relations (unchanged)" do
      a = user!("HVA")
      f = user!("HVF")
      g = user!("HVG")
      room = public_hv_room!(a, "joined")
      join_ev!(f, room)
      join_ev!(g, room)
      m1 = say_m!(a, room, "m1x")
      leave_ev!(f, room)
      ban_ev!(a, room, g)

      for u <- [f, g] do
        assert_err(messages_req(u, room), 403, "M_FORBIDDEN")
        assert_err(event_conn(u, room, m1.id), 403, "M_FORBIDDEN")
        assert_err(relations_conn(u, room, m1.id), 403, "M_FORBIDDEN")
      end

      assert event_conn(a, room, m1.id).status == 200, "control: a member reads the same event"
    end
  end

  # ═══ AC8: /event, /relations, thread roots ═══════════════════════════════════════════════════════

  describe "AC8 - /event, /relations and the incremental thread roots" do
    setup do
      a = user!("HVA")
      b = user!("HVB")
      {room, _hv} = hv_room!(a, "joined")
      m1 = say_m!(a, room, "m1x")
      t1 = relate_m!(a, room, "m.thread", m1.id, "t1x")
      invite_ev!(a, room, b)
      anchor = anchor_room!(b)
      join_ev!(b, room)
      token = snapshot!(b, anchor)
      t2 = relate_m!(a, room, "m.thread", m1.id, "t2x")
      m3 = say_m!(a, room, "m3x")
      r3 = relate_m!(a, room, "m.annotation", m3.id, "r3x", %{"key" => "x"})
      {:ok, a: a, b: b, room: room, m1: m1, t1: t1, t2: t2, m3: m3, r3: r3, token: token}
    end

    test "(a) GET /event: invisible m1 is the fixed 404, byte-identical to unknown and to another room's event; m3 is 200", ctx do
      %{a: a, b: b, room: room, m1: m1, m3: m3} = ctx
      hidden = assert_event_404!(event_conn(b, room, m1.id))
      unknown = assert_event_404!(event_conn(b, room, "$unknown" <> T.rand(8)))
      assert hidden == unknown, "no existence oracle: the two bodies are byte-identical"

      other = make_room(b, %{})
      other_msg = say_m!(b, other, "ox")
      cross = assert_event_404!(event_conn(b, room, other_msg.id))
      assert cross == hidden, "an event that exists in another room answers the same bytes"

      assert_room_404!(event_conn(b, unknown_room(), m1.id))
      refute String.contains?(hidden, m1.id) or String.contains?(hidden, m1.marker)

      ok = event_conn(b, room, m3.id)
      assert ok.status == 200
      assert T.json(ok)["event_id"] == m3.id and T.json(ok)["content"]["body"] == m3.marker
      assert event_conn(a, room, m1.id).status == 200, "control: A reads m1"
    end

    test "(b) GET /relations: invisible parent m1 is the fixed 404 (byte-identical to unknown); m3 is 200 with r3", ctx do
      %{a: a, b: b, room: room, m1: m1, m3: m3, r3: r3, t1: t1} = ctx
      hidden = assert_event_404!(relations_conn(b, room, m1.id))
      unknown = assert_event_404!(relations_conn(b, room, "$unknown" <> T.rand(8)))
      assert hidden == unknown

      conn = relations_conn(b, room, m3.id)
      assert conn.status == 200
      body = T.json(conn)
      assert Enum.map(body["chunk"], & &1["event_id"]) == [r3.id]
      refute_leak!(conn.resp_body, t1)

      a_conn = relations_conn(a, room, m1.id)
      assert a_conn.status == 200, "control: A reads the relations of m1"
      assert T.json(a_conn)["chunk"] |> Enum.map(& &1["event_id"]) |> Enum.sort() == Enum.sort([t1.id, ctx.t2.id])
    end

    test "(c) B's incremental /sync with t2: the invisible root m1 is NOT prepended, t2 is delivered; A gets the root (control)", ctx do
      %{a: a, b: b, room: room, m1: m1, t1: t1, t2: t2, token: token} = ctx
      conn = sync_conn(b, since: token, timeout: 0)
      assert conn.status == 200
      body = T.json(conn)
      tl = join_timeline(body, room)
      assert t2.id in ids(tl), "t2 itself is visible (sent after the join)"
      refute m1.id in ids(tl), "the root of the thread is invisible: not prepended"
      refute String.contains?(conn.resp_body, m1.marker), "no content of m1 anywhere in the response (t2's m.relates_to names the id, which is not content)"
      refute String.contains?(conn.resp_body, "m.relations"), "no bundled aggregation (they would count the hidden replies)"
      refute String.contains?(conn.resp_body, t1.marker)

      # control: A syncs from a token before t2 and gets the root prepended
      anchor = anchor_room!(a)
      a_token = snapshot!(a, anchor)
      t4 = relate_m!(a, room, "m.thread", m1.id, "t4x")
      a_body = sync(a, a_token)
      a_tl = join_timeline(a_body, room)
      assert t4.id in ids(a_tl) and m1.id in ids(a_tl), "control: the visible root of a reply in the delta is prepended"
    end

    test "(d) /relations of a visible parent: only the visible children (hv change between them)", %{} do
      a = user!("HVA")
      b = user!("HVB")
      room = make_room(a, %{"preset" => "private_chat"})
      parent = say_m!(a, room, "px")
      c1 = relate_m!(a, room, "m.thread", parent.id, "c1x")
      set_hv!(a, room, "joined")
      c2 = relate_m!(a, room, "m.thread", parent.id, "c2x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      c3 = relate_m!(a, room, "m.thread", parent.id, "c3x")

      {page, _, page_raw} = msgs!(b, room)
      assert parent.id in ids(page)
      refute String.contains?(page_raw, "m.relations"), "the visible parent carries no aggregation that counts the hidden children"
      for c <- [c2], do: refute_leak!(page_raw, c)

      conn = relations_conn(b, room, parent.id)
      assert conn.status == 200
      assert T.json(conn)["chunk"] |> Enum.map(& &1["event_id"]) == [c3.id, c1.id], "c1 (sent while shared) and c3 are visible, c2 (joined, before B) is not; newest first"
      refute_leak!(conn.resp_body, c2)

      a_conn = relations_conn(a, room, parent.id)
      assert T.json(a_conn)["chunk"] |> Enum.map(& &1["event_id"]) == [c3.id, c2.id, c1.id], "control: A sees all three"
    end
  end

  # ═══ AC9: /search ════════════════════════════════════════════════════════════════════════════════

  describe "AC9 - search results are filtered per result" do
    test "B searches X (before his join): nothing; Y (after): one; A finds X; the room_filter variant likewise" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      x = say_m!(a, room, "searchx")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      y = say_m!(a, room, "searchy")

      {res_x, re_x, raw_x} = search!(b, x.marker)
      assert res_x == [] and re_x["count"] === 0, "the invisible message is not found"
      refute_leak!(raw_x, x)

      {res_y, _, _} = search!(b, y.marker)
      assert Enum.map(res_y, & &1["event_id"]) == [y.id]

      {res_a, _, _} = search!(a, x.marker)
      assert Enum.map(res_a, & &1["event_id"]) == [x.id], "control: A finds X"

      {res_fx, _, raw_fx} = search!(b, x.marker, rooms: [room])
      assert res_fx == []
      refute_leak!(raw_fx, x)
      {res_fy, _, _} = search!(b, y.marker, rooms: [room])
      assert Enum.map(res_fy, & &1["event_id"]) == [y.id]
    end

    test "12 matching events, 5 visible, limit 3: two pages, 5 results, no duplicates, no leak, count = filtered total" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      term = word("term")
      hidden = for i <- 1..7, do: say_t!(a, room, term, "h#{i}x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      visible = for i <- 1..5, do: say_t!(a, room, term, "v#{i}x")

      pages = search_all!(b, term, 3)
      assert length(pages) == 2, "5 results at limit 3 are two pages"
      found = Enum.flat_map(pages, fn {results, _re, _raw} -> Enum.map(results, & &1["event_id"]) end)
      assert length(found) == 5 and found == Enum.uniq(found), "no duplicates"
      assert Enum.sort(found) == Enum.sort(Enum.map(visible, & &1.id)), "exactly the visible events"
      [{p1, re1, _}, {p2, re2, _}] = pages
      assert length(p1) == 3 and length(p2) == 2
      assert re1["next_batch"] not in [nil, ""], "positive control: the first page has a next page"
      assert re1["count"] === 3, "`count` of the first page is the filtered lower bound, never a hidden event"
      assert re2["next_batch"] in [nil, ""], "no next page after the last visible result"
      assert re2["count"] === 5, "`count` over the filtered results"

      for {_results, _re, raw} <- pages, h <- hidden, do: refute_leak!(raw, h)

      a_found = a |> search_all!(term, 3) |> Enum.flat_map(fn {results, _, _} -> Enum.map(results, & &1["event_id"]) end)
      assert length(a_found) == 12, "control: A finds all 12 over four pages"
    end

    test "(22.6) a left room is not searched; one query over a joined and a shared room; order_by rank / recent; count" do
      a = user!("HVA")
      b = user!("HVB")
      term = word("term")
      {r1, _} = hv_room!(a, "joined")
      {r2, _} = hv_room!(a, "shared")
      h1 = say_t!(a, r1, term, "h1x")
      s1 = say_t!(a, r2, term, "s1x")
      invite_ev!(a, r1, b)
      invite_ev!(a, r2, b)
      join_ev!(b, r1)
      join_ev!(b, r2)
      v1 = say_t!(a, r1, term, "v1x")
      s2 = say_t!(a, r2, term, "s2x")

      want = Enum.sort([s1.id, v1.id, s2.id])

      for order <- [nil, "rank", "recent"] do
        {results, re, raw} = search!(b, term, order_by: order)
        assert Enum.sort(Enum.map(results, & &1["event_id"])) == want, "order_by #{inspect(order)}: the visible results of both rooms"
        assert re["count"] === 3, "`count` is computed after filtering"
        refute_leak!(raw, h1)
      end

      {a_results, a_re, _} = search!(a, term)
      assert length(a_results) == 4 and a_re["count"] === 4, "control: A finds all four"

      leave!(b, r2)
      tick()
      {after_leave, _, raw} = search!(b, term)
      assert Enum.map(after_leave, & &1["event_id"]) == [v1.id], "a left room is not searched: search covers currently joined rooms only (spec: also left rooms; `gl`)"
      refute_leak!(raw, [s1, s2, h1])
    end
  end

  # ═══ AC12: the predecessor keys follow the visibility of THE predecessor ══════════════════════════

  describe "AC12 - the predecessor keys" do
    defp put_topic!(user, room, text) do
      tick()
      id = ok_event!(put_state(user, room, "m.room.topic", %{"topic" => text}), "topic")
      tick()
      id
    end

    defp event_in(events, id), do: Enum.find(events, &(&1["event_id"] == id))

    setup do
      a = user!("HVA")
      b = user!("HVB")
      {room, _hv} = hv_room!(a, "joined")
      t1_text = word("topicone")
      t1 = put_topic!(a, room, t1_text)
      invite_ev!(a, room, b)
      join_ev!(b, room)
      t2_text = word("topictwo")
      t2 = put_topic!(a, room, t2_text)
      {:ok, a: a, b: b, room: room, t1: t1, t1_text: t1_text, t2: t2, t2_text: t2_text}
    end

    test "(a) B's initial /sync: the current topic event T2 carries NONE of the three keys and T1 is nowhere; A's T2 carries all three (control)", ctx do
      %{a: a, b: b, room: room, t1: t1, t1_text: t1_text, t2: t2} = ctx
      {b_tl, entry, raw} = initial_timeline!(b, room)
      ev = event_in(b_tl ++ entry["state"]["events"], t2)
      assert ev, "T2 is served to B (timeline or state)"
      assert unsigned_keys(ev) == [], "no predecessor key: T1 is invisible to B"
      refute_leak!(raw, [t1, t1_text])

      {a_tl, a_entry, _} = initial_timeline!(a, room)
      a_ev = event_in(a_tl ++ a_entry["state"]["events"], t2)
      assert Enum.sort(unsigned_keys(a_ev)) == @keys
      assert a_ev["unsigned"]["replaces_state"] == t1 and a_ev["unsigned"]["prev_content"] == %{"topic" => t1_text} and a_ev["unsigned"]["prev_sender"] == a.uid
    end

    test "(b) B's /messages and GET /event/{T2}: no predecessor keys, T1 is not in /messages and its text nowhere; /event/{T1} is the fixed 404", ctx do
      %{b: b, room: room, t1: t1, t1_text: t1_text, t2: t2} = ctx
      {chunk, _, raw} = msgs!(b, room)
      assert unsigned_keys(event_in(chunk, t2)) == []
      refute t1 in ids(chunk)
      refute_leak!(raw, [t1, t1_text])

      conn = event_conn(b, room, t2)
      assert conn.status == 200
      assert unsigned_keys(T.json(conn)) == []
      refute_leak!(conn.resp_body, [t1, t1_text])
      assert_event_404!(event_conn(b, room, t1))
    end

    test "(c) a topic T3 after T2: T3 carries the keys with T2 as the predecessor for B (visible), in /messages and /event", ctx do
      %{a: a, b: b, room: room, t2: t2, t2_text: t2_text} = ctx
      t3 = put_topic!(a, room, word("topicthree"))
      {chunk, _, _} = msgs!(b, room)
      ev = event_in(chunk, t3)
      assert Enum.sort(unsigned_keys(ev)) == @keys
      assert ev["unsigned"]["replaces_state"] == t2 and ev["unsigned"]["prev_content"] == %{"topic" => t2_text} and ev["unsigned"]["prev_sender"] == a.uid

      conn = event_conn(b, room, t3)
      assert T.json(conn)["unsigned"]["replaces_state"] == t2
    end

    test "(d) /members and /initialSync state: an invisible predecessor omits the keys, a visible one keeps them", %{} do
      a = user!("HVA")
      b = user!("HVB")
      c = user!("HVC")
      d = user!("HVD")
      {room, _} = hv_room!(a, "joined")
      c_invite = invite_ev!(a, room, c)
      invite_ev!(a, room, b)
      join_ev!(b, room)
      join_ev!(c, room)
      d_invite = invite_ev!(a, room, d)
      join_ev!(d, room)

      for {label, read} <- [
            {"/members", fn user -> slots(members!(user, room, "")["chunk"]) end},
            {"/initialSync state", fn user -> slots(initial_sync!(user, room)["state"]) end}
          ] do
        by_key = read.(b)
        assert unsigned_keys(by_key[c.uid]) == [], "#{label}: C's invite was sent before B joined (joined): no keys"
        assert Enum.sort(unsigned_keys(by_key[d.uid])) == @keys, "#{label}: D's invite is visible to B: the keys"
        assert by_key[d.uid]["unsigned"]["replaces_state"] == d_invite and by_key[d.uid]["unsigned"]["prev_content"]["membership"] == "invite"
        assert unsigned_keys(by_key[b.uid]) == [], "#{label}: B's own invite is hidden from B under joined"

        a_keys = read.(a)
        assert Enum.sort(unsigned_keys(a_keys[c.uid])) == @keys, "#{label}: control: A sees C's invite as the predecessor"
        assert a_keys[c.uid]["unsigned"]["replaces_state"] == c_invite
      end
    end

    test "(e) under shared everything as before: B's join carries the invite as the predecessor" do
      s = scenario!("shared")
      {chunk, _, _} = msgs!(s.b, s.room)
      join = event_in(chunk, s.join)
      assert Enum.sort(unsigned_keys(join)) == @keys
      assert join["unsigned"]["replaces_state"] == s.invite and join["unsigned"]["prev_content"]["membership"] == "invite"
    end

    test "(f) never a predecessor other than the true one: T0 (visible) -> hv joined -> T1 (invisible) -> T2: T2 has NO keys, not T0's" do
      a = user!("HVA")
      b = user!("HVB")
      room = make_room(a, %{"preset" => "private_chat"})
      t0 = put_topic!(a, room, word("topiczero"))
      set_hv!(a, room, "joined")
      t1_text = word("topicone")
      t1 = put_topic!(a, room, t1_text)
      invite_ev!(a, room, b)
      join_ev!(b, room)
      t2 = put_topic!(a, room, word("topictwo"))

      {chunk, _, raw} = msgs!(b, room)
      assert t0 in ids(chunk), "T0 (before the change) is visible"
      refute t1 in ids(chunk)
      assert unsigned_keys(event_in(chunk, t2)) == [], "T2's true predecessor T1 is invisible: no keys (never T0's)"
      refute_leak!(raw, [t1, t1_text])
      assert unsigned_keys(T.json(event_conn(b, room, t2))) == []

      {tl, entry, _} = initial_timeline!(b, room)
      assert unsigned_keys(event_in(tl ++ entry["state"]["events"], t2)) == []
    end
  end

  defp say_t!(user, room, term, label) do
    tick()
    unique = word(label)
    %{id: say!(user, room, "#{term} #{unique}"), marker: unique}
  end

  # ═══ D12 / AC5 (e): who may NOT read, whatever the setting ═══════════════════════════════════════

  describe "AC5 (e) - who may not read" do
    for value <- ["world_readable", "invited"] do
      test "#{value}: never-joined, leaver, banned and pending invitee: 403 on every event read, nothing in search" do
        value = unquote(value)
        a = user!("HVA")
        b = user!("HVB")
        never = user!("HVN")
        leaver = user!("HVL")
        banned = user!("HVG")
        pending = user!("HVP")
        {room, _} = hv_room!(a, value)
        m1 = say_m!(a, room, "m1x")
        for u <- [b, leaver, banned], do: (invite_ev!(a, room, u); join_ev!(u, room))
        leave_ev!(leaver, room)
        ban_ev!(a, room, banned)
        invite_ev!(a, room, pending)
        m2 = say_m!(a, room, "m2x")

        for u <- [never, leaver, banned, pending] do
          assert_err(messages_req(u, room), 403, "M_FORBIDDEN")
          assert_err(event_conn(u, room, m1.id), 403, "M_FORBIDDEN")
          assert_err(relations_conn(u, room, m1.id), 403, "M_FORBIDDEN")
          assert_err(initial_sync_conn(u, room), 403, "M_FORBIDDEN")
          {results, _, raw} = search!(u, m1.marker)
          assert results == []
          refute_leak!(raw, [m1, m2])
        end

        # controls: a member reads, finds and is served the same
        {chunk, _, raw} = msgs!(b, room)
        assert_shown!(chunk, raw, [m2])
        assert event_conn(b, room, m2.id).status == 200
        {found, _, _} = search!(b, m2.marker)
        assert Enum.map(found, & &1["event_id"]) == [m2.id]
      end
    end
  end

  describe "AC12 (D10) - the leave window's predecessor keys follow the rule" do
    test "joined: F's rooms.leave window: T2 (predecessor T1, before his join) has none of the three keys, T3 (predecessor T2) carries them" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      t1_text = word("topicone")
      t1 = put_topic!(a, room, t1_text)
      join_ev!(f, room)
      anchor = anchor_room!(f)
      token = snapshot!(f, anchor)
      t2_text = word("topictwo")
      t2 = put_topic!(a, room, t2_text)
      t3 = put_topic!(a, room, word("topicthree"))
      leave = leave_ev!(f, room)

      conn = sync_conn(f, since: token, timeout: 0)
      assert conn.status == 200
      body = T.json(conn)
      assert in_section?(body, "leave", room)
      window = leave_timeline(body, room)
      assert Enum.map(window, & &1["event_id"]) == [t2, t3, leave]
      assert unsigned_keys(event_in(window, t2)) == [], "T1 lies before F's join: invisible, no keys"
      ev3 = event_in(window, t3)
      assert Enum.sort(unsigned_keys(ev3)) == @keys
      assert ev3["unsigned"]["replaces_state"] == t2 and ev3["unsigned"]["prev_content"] == %{"topic" => t2_text}
      refute_leak!(conn.resp_body, [t1, t1_text])
    end
  end

  # ═══ AC13: no new statement ══════════════════════════════════════════════════════════════════════

  describe "AC13 - pinned statement counts (security cycle 1: one SET LOCAL per request read)" do
    # MEASURED on the code before the story (HEAD 5c852949, three runs, identical), with the fixture below (a shared room, so that every event is visible and the per-event reads of the
    # timeline - the thread aggregation lookups - are the same before and after). The fragment lives INSIDE the existing statements: not one statement more.
    # `{statements, of them SET LOCAL}` per read path; the SET LOCALs are the strict member reads and the member slice of the sync (all of them existed before)
    # Security cycle 1 (BINDING decision 1 (d), DELIBERATE re-pin, old -> new): the request reads of /messages, /event, /relations,
    # /search and the /initialSync messages run under `SET LOCAL statement_timeout = '2s'`: exactly ONE `SET LOCAL` more each
    # (messages {5, 0} -> {6, 1}, event {4, 0} -> {5, 1}, relations {4, 0} -> {5, 1}, search {3, 0} -> {4, 1}, initial_sync_room
    # {13, 2} -> {14, 3}); the visibility itself still adds no statement, the /sync paths are unchanged.
    @baseline %{
      messages: {6, 1},
      event: {5, 1},
      relations: {5, 1},
      search: {4, 1},
      members: {6, 2},
      initial_sync_room: {14, 3},
      # story sync-token-per-device (DELIBERATE re-pin; old -> new): initial_sync 45 -> 48 and incremental_sync 48 -> 51, +3 each. Initial (no since):
      # get_positions + changed_since? (new, the cross-signing flag was only read with a since) + advance_positions. Incremental: get_positions + pending_since?
      # (the D11 pre-check) + advance_positions, while changed_since? / list_since replace consume_changed_flag / list_changed_and_clear one for one
      # story sync-stream-position (DELIBERATE re-pin, old -> new, MEASURED on the final design): initial_sync 48 -> 50, incremental_sync 51 -> {30, 0}.
      # Initial: `room_heads` + the persist transaction (token upsert, ONE cursor statement) instead of the one upsert. Incremental: the old 51 (and every
      # earlier incremental pin) was the count of a FALLBACK, because the map iteration order ran `initial_sync` first (see `measured` below); now it is a
      # REAL incremental sync of one moved room: `room_heads` + ONE range read + the guarded token UPDATE + ONE cursor statement, no SET LOCAL.
      initial_sync: {50, 2},
      incremental_sync: {30, 0}
    }

    defp count_fixture! do
      s = scenario!("shared")
      anchor = anchor_room!(s.b)
      token = snapshot!(s.b, anchor)
      m4 = say_m!(s.a, s.room, "m4x")
      Map.merge(s, %{token: token, m4: m4})
    end

    test "every read path runs exactly the recorded number of statements (and SET LOCALs)" do
      s = count_fixture!()
      b = s.b
      room = s.room

      # story sync-stream-position (DELIBERATE fix, old -> new): a keyword list instead of a map, so the requests run in THIS order. The map's iteration order
      # is not the key order for atom keys (OTP 26+): `initial_sync` ran before `incremental_sync` and replaced b's token, so the pinned "incremental" count
      # was the count of a FALLBACK (= initial + 3) in every earlier re-pin. The incremental sync now runs while `s.token` is still the device's token.
      measured = [
        messages: fn -> messages_req(b, room) end,
        event: fn -> event_conn(b, room, s.m1.id) end,
        relations: fn -> relations_conn(b, room, s.m3.id) end,
        search: fn -> T.matrix_request(:post, "/_matrix/client/v3/search", b.at, body: %{"search_categories" => %{"room_events" => %{"search_term" => s.m3.marker}}}) end,
        members: fn -> T.matrix_request(:get, path(room, "members"), b.at) end,
        initial_sync_room: fn -> initial_sync_conn(b, room) end,
        incremental_sync: fn -> sync_conn(b, since: s.token, timeout: 0) end,
        initial_sync: fn -> sync_conn(b, since: nil, timeout: 0) end
      ]

      results =
        for {name, request} <- measured, into: %{} do
          {conn, statements} = count_statements(request, [room], [])
          assert conn.status == 200, "#{name}: #{conn.status}"
          {name, statements}
        end

      counts = Map.new(results, fn {name, statements} -> {name, {length(statements), Enum.count(statements, &String.contains?(&1, "SET LOCAL"))}} end)
      assert counts == @baseline, "the statement counts changed: #{inspect(counts)}"
      assert Enum.sum(for {_name, {total, _}} <- @baseline, do: total) > 0, "the baseline was recorded"

      for name <- [:messages, :event, :search] do
        assert Enum.any?(results[name], &String.contains?(&1, "/* history_visibility */")), "#{name}: the fragment is IN a statement of the request"
      end
    end
  end

  describe "AC13 - the same shape in a joined room" do
    test "/messages, /event, /search and /members run the statements of the shared fixture in a joined room (no relations, no thread roots)" do
      s = scenario!("joined")
      shared = @baseline

      measured = %{
        messages: fn -> messages_req(s.b, s.room) end,
        event: fn -> event_conn(s.b, s.room, s.m3.id) end,
        search: fn -> T.matrix_request(:post, "/_matrix/client/v3/search", s.b.at, body: %{"search_categories" => %{"room_events" => %{"search_term" => s.m3.marker}}}) end,
        members: fn -> T.matrix_request(:get, path(s.room, "members"), s.b.at) end
      }

      counts =
        for {name, request} <- measured, into: %{} do
          {conn, statements} = count_statements(request, [s.room], [])
          assert conn.status == 200, "#{name}: #{conn.status}"
          {name, {length(statements), Enum.count(statements, &String.contains?(&1, "SET LOCAL"))}}
        end

      assert counts == Map.take(shared, [:messages, :event, :search, :members]), "a joined room costs the same statements: #{inspect(counts)}"
    end
  end

  # ═══ AC16 (a): fail closed ═══════════════════════════════════════════════════════════════════════

  describe "AC16 (a) - a failing filtered read fails closed" do
    setup do
      Hooks.install!()
      s = scenario!("joined")
      {:ok, s: s}
    end

    # exactly ONE error line, value-free: the room id (or "search") and the error class, nothing of the room's content
    defp assert_one_error_line!(log, needle, s) do
      lines = error_lines(log)
      assert length(lines) == 1, "exactly one ERROR line, got #{length(lines)}"
      [line] = lines
      assert line =~ needle, "the line names #{needle}"
      assert line =~ "atdd_injected", "the line carries the error class"
      refute_leak!(line, [s.m1, s.m2, s.m3, s.invite, s.join, s.topic])
    end

    defp assert_500!(conn) do
      assert conn.status == 500, "expected 500, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn) == %{"errcode" => "M_UNKNOWN", "error" => "Internal server error"}, "the generic body: #{conn.resp_body}"
    end

    test "/messages: 500 generic body, one value-free ERROR line; control: works when not armed", %{s: s} do
      assert messages_req(s.b, s.room).status == 200
      Hooks.arm(:fetch_visible_events, s.room)
      {conn, log} = capture_at(:error, fn -> messages_req(s.b, s.room) end)
      assert_500!(conn)
      refute_leak!(conn.resp_body, [s.m3])
      assert_one_error_line!(log, s.room, s)
      assert Hooks.calls(:fetch_events) == 0, "the unfiltered read is never a fallback of the real path"
    end

    test "/event: 500, one ERROR line", %{s: s} do
      Hooks.arm(:fetch_visible_event, s.room)
      {conn, log} = capture_at(:error, fn -> event_conn(s.b, s.room, s.m3.id) end)
      assert_500!(conn)
      assert_one_error_line!(log, s.room, s)
      assert Hooks.calls(:fetch_event) == 0
    end

    test "/relations: a failing children read and a failing parent read are each a 500 with one ERROR line", %{s: s} do
      anchor = relate_m!(s.a, s.room, "m.annotation", s.m3.id, "rx", %{"key" => "k"})
      assert relations_conn(s.b, s.room, s.m3.id).status == 200, "control"
      assert anchor.id

      Hooks.arm(:fetch_visible_events_by_relation, s.room)
      {conn, log} = capture_at(:error, fn -> relations_conn(s.b, s.room, s.m3.id) end)
      assert_500!(conn)
      assert_one_error_line!(log, s.room, s)
      Hooks.disarm(:fetch_visible_events_by_relation)

      Hooks.arm(:fetch_visible_event, s.room)
      {conn2, log2} = capture_at(:error, fn -> relations_conn(s.b, s.room, s.m3.id) end)
      assert_500!(conn2)
      assert_one_error_line!(log2, s.room, s)
      assert Hooks.calls(:fetch_event) == 0 and Hooks.calls(:fetch_events_by_relation) == 0
    end

    test "/initialSync and the initial /sync: 500, one ERROR line each, no partial 200", %{s: s} do
      Hooks.arm(:fetch_visible_events, s.room)
      {conn, log} = capture_at(:error, fn -> initial_sync_conn(s.b, s.room) end)
      assert_500!(conn)
      assert_one_error_line!(log, s.room, s)

      {conn2, log2} = capture_at(:error, fn -> sync_conn(s.b, since: nil, timeout: 0) end)
      assert_500!(conn2)
      assert_one_error_line!(log2, s.room, s)
      assert Hooks.calls(:fetch_events) == 0
    end

    test "the incremental /sync: 503 M_UNAVAILABLE, since token unchanged, the same token delivers once the read works", %{s: s} do
      anchor = anchor_room!(s.b)
      token = snapshot!(s.b, anchor)
      m4 = say_m!(s.a, s.room, "m4x")
      before = T.legacy_session_state([s.b.uid])

      # DELIBERATE amendment by story sync-stream-position, old -> new: the incremental read is `fetch_visible_events_in_range/5` (by position), not `_since/4` (by timestamp)
      Hooks.arm(:fetch_visible_events_in_range, s.room)
      {conn, log} = capture_at(:error, fn -> sync_conn(s.b, since: token, timeout: 0) end)
      assert conn.status == 503, "got #{conn.status}"
      assert T.json(conn) == %{"errcode" => "M_UNAVAILABLE", "error" => "Core is temporarily unavailable"}
      assert_one_error_line!(log, s.room, s)
      assert T.legacy_session_state([s.b.uid]) == before, "no since token was persisted by the failed sync"
      refute String.contains?(conn.resp_body, m4.marker)

      Hooks.disarm(:fetch_visible_events_in_range)
      body = sync(s.b, token)
      assert m4.id in ids(join_timeline(body, s.room)), "the next sync with the same token delivers the event"
      assert Hooks.calls(:fetch_events_since) == 0
    end

    test "the incremental /sync with a thread reply: a failing root read is a 503 too", %{s: s} do
      anchor = anchor_room!(s.b)
      token = snapshot!(s.b, anchor)
      relate_m!(s.a, s.room, "m.thread", s.m3.id, "t9x")

      Hooks.arm(:fetch_visible_event, s.room)
      {conn, log} = capture_at(:error, fn -> sync_conn(s.b, since: token, timeout: 0) end)
      assert conn.status == 503
      assert_one_error_line!(log, s.room, s)
      assert Hooks.calls(:fetch_event) == 0
    end

    test "/search: 500 `search failed`, one ERROR line naming `search` and the class", %{s: s} do
      Hooks.arm(:search_messages, :any)
      {conn, log} = capture_at(:error, fn -> T.matrix_request(:post, "/_matrix/client/v3/search", s.b.at, body: %{"search_categories" => %{"room_events" => %{"search_term" => s.m3.marker}}}) end)
      assert conn.status == 500
      assert T.json(conn) == %{"errcode" => "M_UNKNOWN", "error" => "Internal server error"}
      assert_one_error_line!(log, "search", s)
      refute String.contains?(log, s.m3.marker), "the search term is never logged"
    end
  end

  # ═══ AC18: crash / restart ═══════════════════════════════════════════════════════════════════════

  describe "AC18 - the rule is read from the database" do
    test "B's /messages, initial timeline, /event/{m1} and /search answers are identical after the restart" do
      s = scenario!("joined")

      read = fn ->
        {chunk, _, _} = msgs!(s.b, s.room)
        {tl, _, _} = initial_timeline!(s.b, s.room)
        event = event_conn(s.b, s.room, s.m1.id)
        {hidden, _, _} = search!(s.b, s.m1.marker)
        {visible, _, _} = search!(s.b, s.m3.marker)
        %{messages: strip_age(chunk), timeline: strip_age(tl), event: {event.status, event.resp_body}, hidden_search: hidden, visible_search: Enum.map(visible, & &1["event_id"])}
      end

      before = read.()
      assert before.event |> elem(0) == 404 and before.hidden_search == [] and before.visible_search == [s.m3.id], "fixture: the rule is in force before the restart"
      kill_and_restart!(s.room)
      assert in_set?(s.room, s.b.uid), "B is a member of the restarted room"

      assert read.() == before
    end
  end

  # ═══ AC19: logs ══════════════════════════════════════════════════════════════════════════════════

  describe "AC19 - nothing of the history is logged" do
    test "across every read path at DEBUG: no message marker, no event id of the room, no hv value or segment appears in any log line" do
      s = scenario!("joined")
      anchor = anchor_room!(s.b)
      token = snapshot!(s.b, anchor)
      m4 = say_m!(s.a, s.room, "m4x")
      # the topic EVENT is part of the current state (D11 (a)): its id may be served; its older siblings (m1, m2, the invite) may not
      hidden = [s.m1, s.m2, s.invite]

      {_result, log} =
        capture_at(:debug, fn ->
          msgs!(s.b, s.room)
          msgs!(s.b, s.room, "dir=f&limit=3")
          event_conn(s.b, s.room, s.m1.id)
          event_conn(s.b, s.room, s.m3.id)
          relations_conn(s.b, s.room, s.m3.id)
          initial_timeline!(s.b, s.room)
          sync(s.b, token)
          initial_sync_conn(s.b, s.room)
          T.matrix_request(:get, path(s.room, "members"), s.b.at)
        end)

      # the existing request logger writes the (content-masked) response body at DEBUG: the ids of the VISIBLE events are in it (unchanged by this story, so
      # asserting their presence proves the capture saw the payload lines); what must never be there is anything of a hidden event, and no message content
      assert String.contains?(log, s.m3.id), "control: the capture saw a payload line with a visible event id"
      for m <- [s.m1, s.m2, s.m3, m4], do: refute(String.contains?(log, m.marker), "a message marker was logged")
      refute String.contains?(log, s.topic), "the topic text was logged"
      for h <- hidden, do: refute(String.contains?(log, if(is_map(h), do: h.id, else: h)), "the id of a hidden event was logged")
      # the TYPE name is in the existing payload lines (their content is masked); a setting VALUE or a visibility verdict is never logged
      refute log =~ ~r/history_visibility["']?\s*[:=]\s*["']?(joined|invited|shared|world_readable)/
      refute log =~ ~r/segment/i

      {_s, search_log} = capture_at(:info, fn -> search!(s.b, s.m3.marker) end)
      refute String.contains?(search_log, s.m3.marker), "the search term is not logged"
    end
  end

  # ═══ AC22: the Oracle tests ══════════════════════════════════════════════════════════════════════

  describe "AC22 (1) - the unban event and the re-invite (D5 (e))" do
    # F joined through an invitation, m1, banned, unbanned, g1, re-invited, g2, re-joins, m3
    defp reinvite_fixture!(value) do
      a = user!("HVA")
      f = user!("HVF")
      {room, _} = hv_room!(a, value)
      invite1 = invite_ev!(a, room, f)
      join1 = join_ev!(f, room)
      m1 = say_m!(a, room, "m1x")
      ban = ban_ev!(a, room, f)
      unban = unban_ev!(a, room, f)
      g1 = say_m!(a, room, "g1x")
      reinvite = invite_ev!(a, room, f)
      g2 = say_m!(a, room, "g2x")
      join2 = join_ev!(f, room)
      m3 = say_m!(a, room, "m3x")
      %{a: a, f: f, room: room, invite1: invite1, join1: join1, m1: m1, ban: ban, unban: unban, g1: g1, reinvite: reinvite, g2: g2, join2: join2, m3: m3}
    end

    test "joined: the unban event and the re-invite are absent and 404 on /event; ban, joins, m1, m3 visible" do
      s = reinvite_fixture!("joined")
      a_ids = all_ids(s.a, s.room)
      {chunk, _, raw} = msgs!(s.f, s.room)

      assert ids(chunk) == a_ids -- [s.invite1, s.unban, s.g1.id, s.reinvite, s.g2.id], "F's own invitations and the unban are hidden under joined, so is everything sent while he was out"
      for id <- [s.join1, s.ban, s.join2], do: assert(id in ids(chunk))
      assert_shown!(chunk, raw, [s.m1, s.m3])
      refute_leak!(raw, [s.unban, s.reinvite, s.g1, s.g2])

      unknown = assert_event_404!(event_conn(s.f, s.room, "$unknown" <> T.rand(8)))
      assert assert_event_404!(event_conn(s.f, s.room, s.unban)) == unknown
      assert assert_event_404!(event_conn(s.f, s.room, s.reinvite)) == unknown
      assert event_conn(s.f, s.room, s.ban).status == 200, "control: his ban event is readable"
    end

    test "invited: the re-invite is visible and F sees the gap events from the re-invite onward (g2), not before (g1)" do
      s = reinvite_fixture!("invited")
      a_ids = all_ids(s.a, s.room)
      {chunk, _, raw} = msgs!(s.f, s.room)

      assert ids(chunk) == a_ids -- [s.unban, s.g1.id]
      for id <- [s.invite1, s.reinvite, s.ban], do: assert(id in ids(chunk))
      assert_shown!(chunk, raw, [s.g2, s.m1, s.m3])
      refute_leak!(raw, [s.unban, s.g1])
      assert event_conn(s.f, s.room, s.reinvite).status == 200
      assert_event_404!(event_conn(s.f, s.room, s.unban))
    end
  end

  describe "AC22 (2) - the incremental /sync reads the oldest VISIBLE events" do
    defp gap_fixture!(gap, after_join) do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join_ev!(f, room)
      say_m!(a, room, "m1x")
      anchor = anchor_room!(f)
      token = snapshot!(f, anchor)
      leave = leave_ev!(f, room)
      hidden = for i <- 1..gap, do: say_m!(a, room, "g#{i}x")
      join2 = join_ev!(f, room)
      visible = for i <- 1..after_join, do: say_m!(a, room, "v#{i}x")
      %{a: a, f: f, room: room, token: token, leave: leave, hidden: hidden, join2: join2, visible: visible}
    end

    test "25 invisible gap events then 3 visible ones: the timeline holds leave, re-join and the 3; not limited" do
      s = gap_fixture!(25, 3)
      conn = sync_conn(s.f, since: s.token, timeout: 0)
      assert conn.status == 200
      body = T.json(conn)
      tl = join_timeline(body, s.room)
      assert ids(tl) == [s.leave, s.join2] ++ Enum.map(s.visible, & &1.id), "the 3 visible events are delivered although 25 invisible ones come first"
      entry = get_in(body, ["rooms", "join", s.room, "timeline"])
      assert entry["limited"] == false
      assert Map.get(entry, "prev_batch") in [nil, ""], "not limited: no prev_batch"
      for h <- s.hidden, do: refute_leak!(conn.resp_body, h)
    end

    # DELIBERATE amendment by story sync-stream-position (D5), old -> new: the incremental timeline of a truncated room is the NEWEST 20 visible events of the range
    # (the gap is at the START, the spec model), no longer the oldest 20, and `prev_batch` is the real `/messages` token (`v1_`) of the oldest DELIVERED event instead of
    # that event's id. Hidden events still do not count towards the 20 and are never delivered.
    test "25 visible events after the re-join: limited true, the NEWEST 20 are delivered, prev_batch is the /messages token of the oldest delivered" do
      s = gap_fixture!(25, 25)
      conn = sync_conn(s.f, since: s.token, timeout: 0)
      assert conn.status == 200
      body = T.json(conn)
      tl = join_timeline(body, s.room)
      assert length(tl) == 20
      assert ids(tl) == ([s.leave, s.join2] ++ Enum.map(s.visible, & &1.id)) |> Enum.take(-20)
      entry = get_in(body, ["rooms", "join", s.room, "timeline"])
      assert entry["limited"] == true
      oldest = hd(tl)
      assert entry["prev_batch"] == "v1_" <> Base.url_encode64("#{oldest["origin_server_ts"]}:#{oldest["event_id"]}", padding: false), "prev_batch is the /messages token of the oldest delivered event"
      for h <- s.hidden, do: refute_leak!(conn.resp_body, h)
    end
  end

  describe "AC22 (3) - limited follows the visible event count" do
    test "initial /sync with fewer than 20 visible and more than 20 invisible events: limited false" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      hidden = for i <- 1..25, do: say_m!(a, room, "h#{i}x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      v1 = say_m!(a, room, "v1x")
      v2 = say_m!(a, room, "v2x")

      {chunk, _, _} = msgs!(b, room)
      assert length(chunk) < 20, "fixture: fewer than 20 visible events"
      {tl, entry, raw} = initial_timeline!(b, room)
      assert ids(tl) == Enum.reverse(ids(chunk)) and v1.id in ids(tl) and v2.id in ids(tl)
      assert entry["timeline"]["limited"] == false, "limited by the limit only: 25 invisible events do not count"
      for h <- hidden, do: refute_leak!(raw, h)
    end

    test "limited: /messages from prev_batch returns the older visible events; a page past the oldest is empty without `end`" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      hidden = for i <- 1..5, do: say_m!(a, room, "h#{i}x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      shown = for i <- 1..25, do: say_m!(a, room, "v#{i}x")

      {tl, entry, _} = initial_timeline!(b, room)
      assert length(tl) == 20 and entry["timeline"]["limited"] == true
      prev = entry["timeline"]["prev_batch"]
      assert is_binary(prev) and prev != ""

      {older, older_body, older_raw} = msgs!(b, room, "dir=b&limit=100&from=" <> URI.encode_www_form(prev))
      {all, _, _} = msgs!(b, room)
      assert ids(older) == Enum.drop(ids(all), 20), "from the sync's prev_batch the walk continues with the older VISIBLE events"
      assert end_absent?(older_body)
      for h <- hidden, do: refute_leak!(older_raw, h)
      assert Enum.take(Enum.reverse(ids(tl)), 20) == Enum.take(ids(all), 20), "control: the sync window is the newest 20 visible events"
      assert Enum.all?(shown, &(&1.id in ids(all))), "control: all 25 shown events are visible"

      oldest = List.last(ids(all))
      {empty, empty_body, _} = msgs!(b, room, "dir=b&limit=10&from=" <> URI.encode_www_form(token(ts_of(oldest), oldest)))
      assert empty == [], "no visible event before the oldest visible one: an empty chunk"
      assert end_absent?(empty_body), "and no `end`"
    end
  end

  describe "AC22 (4) - /relations fills its page from the VISIBLE children" do
    test "6 children, the 3 oldest invisible: limit 2 gives the 2 newest visible, dir=f the 2 oldest visible, no starvation" do
      a = user!("HVA")
      b = user!("HVB")
      room = make_room(a, %{"preset" => "private_chat"})
      parent = say_m!(a, room, "px")
      set_hv!(a, room, "joined")
      hidden = for i <- 1..3, do: relate_m!(a, room, "m.thread", parent.id, "c#{i}x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      [d1, d2, d3] = for i <- 1..3, do: relate_m!(a, room, "m.thread", parent.id, "d#{i}x")

      c2 = relations_conn(b, room, parent.id, "limit=2")
      assert c2.status == 200
      assert T.json(c2)["chunk"] |> Enum.map(& &1["event_id"]) == [d3.id, d2.id]
      # pinned as-is (/relations has no pagination today); flips when /relations pagination ships
      assert T.json(c2)["next_batch"] in [nil, ""]

      f2 = relations_conn(b, room, parent.id, "limit=2&dir=f")
      assert T.json(f2)["chunk"] |> Enum.map(& &1["event_id"]) == [d1.id, d2.id], "the page is filled from visible children, never short"

      all = relations_conn(b, room, parent.id, "limit=100")
      assert T.json(all)["chunk"] |> Enum.map(& &1["event_id"]) == [d3.id, d2.id, d1.id]
      for conn <- [c2, f2, all], h <- hidden, do: refute_leak!(conn.resp_body, h)

      assert T.json(relations_conn(a, room, parent.id, "limit=100"))["chunk"] |> length() == 6, "control: A sees all six"
    end
  end

  describe "AC22 (5) - tokens into an invisible region" do
    test "a `from` token inside the invisible region: dir=b never returns an invisible event, dir=f starts at B's join" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      gap = for i <- 1..6, do: say_m!(a, room, "g#{i}x")
      invite_ev!(a, room, b)
      join = join_ev!(b, room)
      say_m!(a, room, "m3x")
      gap_ids = Enum.map(gap, & &1.id)

      # A's own pagination, 2 events per page: the tokens in the invisible region
      a_pages = walk!(a, room, "b", 2)
      tokens = for {chunk, body} <- a_pages, not end_absent?(body), List.last(ids(chunk)) in gap_ids, do: body["end"]
      assert length(tokens) >= 2, "fixture: A's pagination has tokens inside the gap"

      for t <- tokens do
        {back, _, back_raw} = msgs!(b, room, "dir=b&limit=100&from=" <> URI.encode_www_form(t))
        refute Enum.any?(ids(back), &(&1 in gap_ids))
        for g <- gap, do: refute_leak!(back_raw, g)
        assert type_in?(back, "m.room.create"), "control: the older visible events are returned"

        {fwd, _, fwd_raw} = msgs!(b, room, "dir=f&limit=100&from=" <> URI.encode_www_form(t))
        refute Enum.any?(ids(fwd), &(&1 in gap_ids))
        assert hd(ids(fwd)) == join, "dir=f from the invisible region reaches the first visible event"
        for g <- gap, do: refute_leak!(fwd_raw, g)
      end
    end

    test "B's own token from before his leave, used after the re-join: dir=b and dir=f never return the gap event" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join1 = join_ev!(f, room)
      say_m!(a, room, "m1x")
      say_m!(a, room, "m1bx")
      {_chunk, body, _} = msgs!(f, room, "dir=b&limit=2")
      own_token = body["end"]
      assert own_token not in [nil, ""], "fixture: a token from before the leave"
      leave_ev!(f, room)
      g1 = say_m!(a, room, "g1x")
      join2 = join_ev!(f, room)
      m3 = say_m!(a, room, "m3x")

      {fwd, _, fwd_raw} = msgs!(f, room, "dir=f&limit=100&from=" <> URI.encode_www_form(own_token))
      refute g1.id in ids(fwd)
      refute_leak!(fwd_raw, g1)
      assert join2 in ids(fwd) and m3.id in ids(fwd), "control: the visible events after the token are returned"

      {back, _, back_raw} = msgs!(f, room, "dir=b&limit=100&from=" <> URI.encode_www_form(own_token))
      refute g1.id in ids(back)
      refute_leak!(back_raw, g1)
      assert join1 in ids(back), "control: the page before the token holds F's own join"
    end
  end

  describe "AC22 (7) - /initialSync messages" do
    test "the `messages.chunk` of a later joiner holds no pre-join message and is B's own /messages page; `state` is still the current state" do
      s = scenario!("joined")
      body = initial_sync!(s.b, s.room)
      chunk = body["messages"]["chunk"]
      {page, _, raw} = msgs!(s.b, s.room, "dir=b&limit=20")
      assert ids(chunk) == ids(page)
      refute_leak!(Jason.encode!(body), [s.m1, s.m2, s.invite])
      assert raw =~ s.m3.marker
      assert Enum.any?(body["state"], &(&1["type"] == "m.room.topic" and &1["content"] == %{"topic" => s.topic})), "the current topic is served (D11 (a))"
      assert s.m3.id in ids(chunk)
    end
  end

  describe "AC22 (8) - redactions" do
    test "a visible original redacted while F was out keeps redacted_because (the label); the redaction event is absent" do
      a = user!("HVA")
      f = user!("HVF")
      room = public_hv_room!(a, "joined")
      join_ev!(f, room)
      m = say_m!(a, room, "mx")
      leave_ev!(f, room)
      tick()
      reason = word("reason")
      redaction = Nebu.Matrix.RedactionTestSupport.redact_id!(a, room, m.id, %{"reason" => reason})
      tick()
      join_ev!(f, room)

      {chunk, _, raw} = msgs!(f, room)
      ev = Enum.find(chunk, &(&1["event_id"] == m.id))
      assert ev, "the original was sent while F was joined: visible"
      assert ev["content"] == %{}, "pruned"
      assert ev["unsigned"]["redacted_because"]["event_id"] == redaction, "a redacted event visible to the viewer carries its redacted_because even when the redaction event is outside his visible history: Nebu choice"
      refute redaction in ids(chunk), "the redaction event itself is not in F's visible history"
      refute String.contains?(raw, m.marker)
      assert redaction in all_ids(a, room), "control: A has the redaction in his history"
    end

    test "a redaction sent after B's join that targets an event invisible to B is itself visible, and no content of the target appears in any of B's responses" do
      s = scenario!("joined")
      tick()
      redaction = Nebu.Matrix.RedactionTestSupport.redact_id!(s.a, s.room, s.m1.id, %{"reason" => word("why")})
      tick()

      {chunk, _, raw} = msgs!(s.b, s.room)
      assert redaction in ids(chunk), "the redaction event lies after B's join: ordinary, visible"
      refute s.m1.id in ids(chunk)
      refute String.contains?(raw, s.m1.marker)

      {_tl, _entry, sync_raw} = initial_timeline!(s.b, s.room)
      refute String.contains?(sync_raw, s.m1.marker)
      assert_event_404!(event_conn(s.b, s.room, s.m1.id))
      assert event_conn(s.b, s.room, redaction).status == 200
      {_res, _re, search_raw} = search!(s.b, s.m1.marker)
      refute String.contains?(search_raw, s.m1.marker) or String.contains?(search_raw, s.m1.id)
    end
  end

  describe "AC22 (9) - GET /event on the special events" do
    test "a pre-join hv event is visible (200, D5 (a)); B's own invite under joined is the fixed 404, byte-identical to an unknown event" do
      s = scenario!("joined")
      assert event_conn(s.b, s.room, s.hv).status == 200
      hidden = assert_event_404!(event_conn(s.b, s.room, s.invite))
      assert hidden == assert_event_404!(event_conn(s.b, s.room, "$unknown" <> T.rand(8)))
      assert event_conn(s.b, s.room, s.join).status == 200, "his own join is visible"
    end
  end

  describe "AC22 (10) - world_readable -> joined" do
    test "a later joiner sees the events of the world_readable period and not those of the joined period before his join" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "world_readable")
      w1 = say_m!(a, room, "w1x")
      set_hv!(a, room, "joined")
      j1 = say_m!(a, room, "j1x")
      invite_ev!(a, room, b)
      join_ev!(b, room)

      {chunk, _, raw} = msgs!(b, room)
      assert_shown!(chunk, raw, [w1])
      refute_leak!(raw, j1)
    end
  end

  describe "AC22 (13) - the initial /sync with a filter" do
    test "filter room.timeline.limit 5 is ignored (Nebu): the timeline is exactly B's visible page (more than 5, fewer than 20), no hidden event" do
      a = user!("HVA")
      b = user!("HVB")
      {room, _} = hv_room!(a, "joined")
      hidden = for i <- 1..30, do: say_m!(a, room, "h#{i}x")
      invite_ev!(a, room, b)
      join_ev!(b, room)
      for i <- 1..8, do: say_m!(a, room, "v#{i}x")

      filter = Jason.encode!(%{"room" => %{"timeline" => %{"limit" => 5}}})
      conn = sync_conn(b, since: nil, timeout: 0, filter: filter)
      assert conn.status == 200
      tl = conn |> T.json() |> join_timeline(room)
      {page, _, _} = msgs!(b, room, "dir=b&limit=20")

      # a filter that was honoured would give 5 events, the unfiltered newest 20 would hold 8 of the 30 hidden ones: only the visible page (12 or so) is right
      assert length(page) > 8 and length(page) < 20, "fixture: more visible events than the filter's 5 and than the 8 messages, fewer than the 20-event window"
      assert length(tl) > 5, "the filter is ignored"
      assert ids(tl) == Enum.reverse(ids(page)), "the timeline is exactly the visible page"
      for h <- hidden, do: refute_leak!(conn.resp_body, h)
    end
  end

  # ═══ the `limited` boundary (as-is behaviour, story decision: no look-ahead) ═════════════════════

  describe "AC22 (3) - the limited boundary" do
    # `limited` is `length(events) >= 20` of the visible page: EXACTLY 20 visible events are limited true (no look-ahead, pinned as-is), 19 are not, 21 are
    test "19 visible events: limited false; exactly 20: limited true (no look-ahead); 21: limited true" do
      for {count, limited} <- [{19, false}, {20, true}, {21, true}] do
        a = user!("HVA")
        b = user!("HVB")
        {room, _} = hv_room!(a, "joined")
        for i <- 1..5, do: say_m!(a, room, "h#{i}x")
        invite_ev!(a, room, b)
        join_ev!(b, room)
        {base, _, _} = msgs!(b, room)
        for i <- 1..(count - length(base))//1, do: say_m!(a, room, "v#{i}x")

        {all, _, _} = msgs!(b, room, "dir=b&limit=100")
        assert length(all) == count, "fixture: exactly #{count} visible events"
        {tl, entry, _} = initial_timeline!(b, room)
        assert length(tl) == min(count, 20)
        assert entry["timeline"]["limited"] == limited, "#{count} visible events: limited #{limited}"
      end
    end
  end
end
