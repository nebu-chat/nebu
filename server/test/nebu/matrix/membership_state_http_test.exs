defmodule Nebu.Matrix.MembershipStateHttpTest do
  @moduledoc """
  Story `membership-state-model` (epic oauth-broker, follow-ups `fb`, `fl` (c)), the HTTP half over the REAL stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`,
  real `Room.Server` under Horde): AC1 (the initial `/sync` state lists every member slot), AC2 (`GET /rooms/{roomId}/members`), AC3 (`/initialSync`),
  AC5 (c) - (e) (the legacy fallbacks, the half state, the fail-closed read), AC7 (Element's replay), AC10 (logs), AC12 (crash / restart) and the Oracle
  tests of AC16 (a), (c), (d), (h) - (n). The upgrade half is `membership_state_upgrade_http_test.exs`, the SQL half `room/member_state_slice_db_test.exs`,
  the race `membership_state_concurrency_test.exs`.

  The room R of AC1 (users A - G, 25 messages after the last member event) is built ONCE per module (`setup_all`, `MembershipStateTestSupport.scenario!/1`);
  every test of this file that only READS it shares it. Tests that change the room (a restart that writes, direct inserts) build their own room.

  Conventions (copied from the sibling suites): `tick/0` only where a sync token follows; every refusal also asserts that NOTHING was written (the events of the
  room, the `rooms` row of an unknown id, the room process); every negative assertion has a positive control; no sleeps (bounded polls only); a future-stamped
  or bulk row is deleted in `on_exit` (the DELETE result is asserted).

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC10 (story decision S-3): at INFO and above nothing sensitive is logged (the request line of `RequestLogger` carries the route template only; the ERROR lines
      of the failing reads name the room id and the error class); at DEBUG the existing redactor masks `reason`, `displayname` and `content` (pinned over `/members`,
      `/initialSync` and `/sync`, with the payload line itself as the positive control). User ids and the query string are logged at DEBUG as for `/sync` (no mask).
    * AC16 (d): `fetch_events_since/3` delivers the OLDEST 20 events after the anchor, so "the lost part of the gap" is its tail: the ban is written AFTER the
      25 messages. DELIBERATE amendment by story sync-stream-position (D5), old -> new: the incremental timeline is the NEWEST 20 of the range, so the tail is no longer lost:
      the ban (the newest event) IS in the limited delta's timeline; the gap is at the START (`prev_batch`). The NEXT initial /sync still repairs the view in its state.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.MembershipStateTestSupport
  import Nebu.Matrix.RedactionTestSupport, only: [stop_room!: 1, running?: 1, room_count: 0]
  import Nebu.Matrix.PowerLevelsTestSupport, only: [install_env!: 3]

  alias Nebu.Matrix.MembershipStateTestSupport.Hooks
  alias Nebu.Matrix.Room.RoomSupervisor
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @not_member "You are not a member of this room"
  @internal "Internal server error"

  setup_all do
    setup_env!()
    {:ok, s: scenario!()}
  end

  setup do
    setup_env!()
    on_exit(&Hooks.disarm_all/0)
    :ok
  end

  # a small public room (every event inside one 20-event window): A creates it, B and D join, D is banned with `reason`
  defp small_room!(reason \\ "spam") do
    a = user!("MSX")
    b = user!("MSY")
    d = user!("MSZ")
    room = public_room(a)
    join!(b, room)
    join!(d, room)
    ok!(ban(a, room, d, %{"reason" => reason}), "ban D")
    %{room: room, a: a, b: b, d: d}
  end

  defp seven(s), do: [{s.a, "join"}, {s.b, "join"}, {s.c, "invite"}, {s.d, "ban"}, {s.e, "leave"}, {s.f, "leave"}, {s.g, "leave"}]

  defp d6_order(s) do
    joins = [s.a.uid, s.b.uid] |> Enum.sort()
    leaves = [s.e.uid, s.f.uid, s.g.uid] |> Enum.sort()
    joins ++ [s.c.uid, s.d.uid] ++ leaves
  end

  # ═══ AC1: the initial /sync state ═══════════════════════════════════════════════════════════════

  describe "AC1 - the initial /sync state lists every member slot (D1 - D3, D11)" do
    test "(a) B's initial /sync: exactly ONE member slot per user A - G with the membership of the latest member event; the member events are outside the window", %{s: s} do
      {state, body} = initial_state(s.b, s.room)

      assert membership_pairs(state) == pairs(seven(s))

      timeline = join_timeline(body, s.room)
      assert length(timeline) == 20 and Enum.all?(timeline, &(&1["type"] == "m.room.message")), "control: the 20-event window holds messages only"
      assert get_in(body, ["rooms", "join", s.room, "timeline", "limited"]) == true
    end

    test "(a) every slot is the stored event: real id, ts, sender, content (the ban / kick reasons) and unsigned (age, the predecessor keys of ban / leave)", %{s: s} do
      {state, _body} = initial_state(s.b, s.room)

      assert_scenario_slots!(slots(state), s)
    end

    test "(a) a /sync state event is a ClientEventWithoutRoomID (no room_id) and no $synth_ id is served anywhere", %{s: s} do
      conn = sync_conn(s.b, since: nil, timeout: 0)
      assert conn.status == 200
      state = conn |> T.json() |> join_state(s.room)

      assert Enum.count(state, &(&1["type"] == "m.room.member")) == 7
      for ev <- state, do: refute(Map.has_key?(ev, "room_id"), "a /sync state event has no room_id: #{ev["type"]}")
      refute conn.resp_body =~ "$synth_"
    end

    test "(a) the slot of /sync and the chunk of /members agree on id, content and sender for every user (the js-sdk lets the /sync slot win)", %{s: s} do
      {state, _} = initial_state(s.b, s.room)
      from_sync = slots(state)
      from_members = slots(chunk!(s.b, s.room))

      assert Map.keys(from_sync) |> Enum.sort() == Map.keys(from_members) |> Enum.sort()

      for {uid, ev} <- from_sync do
        other = from_members[uid]
        assert {ev["event_id"], ev["sender"], ev["content"], ev["origin_server_ts"]} == {other["event_id"], other["sender"], other["content"], other["origin_server_ts"]}
      end
    end

    test "(b) with the member events INSIDE the 20-event window each slot appears in the timeline and none in state; the replay ends in the same final state", _ctx do
      r = small_room!()
      c = user!("MSW")
      invite!(r.a, r.room, c)

      body = sync(r.b)
      timeline = join_timeline(body, r.room)
      state = join_state(body, r.room)

      assert get_in(body, ["rooms", "join", r.room, "timeline", "limited"]) == false, "control: the whole room lies inside the window"

      for u <- [r.a, r.b, r.d, c] do
        assert Enum.any?(timeline, &(&1["type"] == "m.room.member" and &1["state_key"] == u.uid)), "the member event of #{u.uid} is in the timeline"
        refute Enum.any?(state, &(&1["type"] == "m.room.member" and &1["state_key"] == u.uid)), "no state slot for #{u.uid}: it is in the timeline"
      end

      assert replay(state ++ timeline) == %{r.a.uid => "join", r.b.uid => "join", r.d.uid => "ban", c.uid => "invite"}
    end

    test "(c) an incremental /sync of B after a new message keeps the joined slice: the non-joined slots are NOT in the delta state (labelled D3 (d))", %{s: s} do
      first = sync(s.b)
      token = next(first)
      tick()
      id = say!(s.a, s.room, marker("delta"))

      {delta, statements} = count_statements(fn -> sync(s.b, token) end, [s.room])

      assert Enum.any?(join_timeline(delta, s.room), &(&1["event_id"] == id)), "control: the new message is delivered"
      state_slots = join_state(delta, s.room) |> Enum.filter(&(&1["type"] == "m.room.member"))
      assert membership_pairs(state_slots) == pairs([{s.a, "join"}, {s.b, "join"}]), "only the joined slots of the room process"
      for ev <- state_slots, do: assert(ev["content"] == %{"membership" => "join"}, "the synthesized joined slot of today")
      assert slice_count(statements) == 0, "the incremental /sync pays no slice statement: #{listing(statements)}"
    end

    test "(d) the D3 tie: a join and a ban of one user with the SAME origin_server_ts: the slot is the ban, whatever the insertion order and the event ids", _ctx do
      a = user!("MST")
      room = public_room(a)
      cleanup_room_events_on_exit(room)
      ts = ts_after(room)
      x1 = user!("MSU")
      x2 = user!("MSV")

      # the join has the GREATER event id: `event_id DESC` alone would pick it, the rank (ban before join) must decide
      put_member_id!(room, x1.uid, "join", x1, ts, "$zz" <> T.rand(8))
      ban1 = put_member_id!(room, x1.uid, "ban", a, ts, "$aa" <> T.rand(8))
      ban2 = put_member_id!(room, x2.uid, "ban", a, ts, "$aa" <> T.rand(8))
      put_member_id!(room, x2.uid, "join", x2, ts, "$zz" <> T.rand(8))
      tick()
      for _ <- 1..25, do: say!(a, room, marker("fill"))

      {state, _} = initial_state(a, room)
      from_sync = slots(state)
      from_members = slots(chunk!(a, room))

      for {x, ban_id} <- [{x1, ban1}, {x2, ban2}], source <- [from_sync, from_members] do
        assert source[x.uid]["content"]["membership"] == "ban"
        assert source[x.uid]["event_id"] == ban_id
      end

      assert chunk!(a, room, "membership=ban") |> Enum.map(& &1["state_key"]) |> Enum.sort() == Enum.sort([x1.uid, x2.uid])
      refute Enum.any?(chunk!(a, room, "membership=join"), &(&1["state_key"] in [x1.uid, x2.uid]))
    end

    test "(e) the room summary and the hierarchy run no member-slice statement; a /members call does (control)", %{s: s} do
      {summary, st1} = count_statements(fn -> T.matrix_request(:get, "/_matrix/client/v1/room_summary/#{enc(s.room)}", s.b.at) end, [s.room])
      {hierarchy, st2} = count_statements(fn -> T.matrix_request(:get, "/_matrix/client/v1/rooms/#{enc(s.room)}/hierarchy", s.b.at) end, [s.room])
      {members, st3} = count_statements(fn -> members_conn(s.b, s.room) end, [s.room])

      assert summary.status == 200 and hierarchy.status == 200 and members.status == 200
      assert slice_count(st1) == 0, "summary: #{listing(st1)}"
      assert slice_count(st2) == 0, "hierarchy: #{listing(st2)}"
      assert slice_count(st3) == 1, "control: /members runs the slice once"
    end

    test "an initial /sync runs ONE slice statement per joined room (2 rooms: 2)", _ctx do
      owner = user!("MSA")
      guest = user!("MSB")
      r1 = public_room(owner)
      r2 = public_room(owner)
      join!(guest, r1)
      join!(guest, r2)

      {conn, statements} = count_statements(fn -> sync_conn(guest, since: nil, timeout: 0) end, [r1, r2])

      assert conn.status == 200
      body = T.json(conn)
      assert in_section?(body, "join", r1) and in_section?(body, "join", r2), "control: both rooms are delivered"
      assert slice_count(statements) == 2, "one slice per joined room: #{listing(statements)}"
    end
  end

  # ═══ AC2: GET /rooms/{roomId}/members ═══════════════════════════════════════════════════════════

  describe "AC2 - GET /rooms/{roomId}/members (D5, D6)" do
    test "(a) B without parameters: all seven slots in the D6 order, every one a ClientEvent with room_id, real ids and unsigned; no $synth_ id", %{s: s} do
      conn = members_conn(s.b, s.room)
      assert conn.status == 200
      refute conn.resp_body =~ "$synth_"
      chunk = T.json(conn)["chunk"]

      assert Enum.map(chunk, & &1["state_key"]) == d6_order(s)
      assert_scenario_slots!(slots(chunk), s, s.room)
    end

    test "(b) ?not_membership=leave (Element's call): A, B (join), C (invite), D (ban)", %{s: s} do
      chunk = chunk!(s.b, s.room, "not_membership=leave")

      assert membership_pairs(chunk) == pairs([{s.a, "join"}, {s.b, "join"}, {s.c, "invite"}, {s.d, "ban"}])
      assert Enum.map(chunk, & &1["state_key"]) == [s.a.uid, s.b.uid] |> Enum.sort() |> Kernel.++([s.c.uid, s.d.uid])
    end

    test "(c) ?membership=ban -> D only; ?membership=invite -> C only; ?membership=knock -> []; ?membership=join -> A, B; ?membership=leave -> E, F, G", %{s: s} do
      assert membership_pairs(chunk!(s.b, s.room, "membership=ban")) == pairs([{s.d, "ban"}])
      assert membership_pairs(chunk!(s.b, s.room, "membership=invite")) == pairs([{s.c, "invite"}])
      assert chunk!(s.b, s.room, "membership=knock") == []
      assert membership_pairs(chunk!(s.b, s.room, "membership=join")) == pairs([{s.a, "join"}, {s.b, "join"}])
      assert membership_pairs(chunk!(s.b, s.room, "membership=leave")) == pairs([{s.e, "leave"}, {s.f, "leave"}, {s.g, "leave"}])
    end

    test "(d) membership and not_membership combine as AND: join + not leave -> A, B; ban + not ban -> []; invite + not join -> C", %{s: s} do
      assert membership_pairs(chunk!(s.b, s.room, "membership=join&not_membership=leave")) == pairs([{s.a, "join"}, {s.b, "join"}])
      assert chunk!(s.b, s.room, "membership=ban&not_membership=ban") == [], "the Oracle-Q3 pin: an event must match membership AND not match not_membership"
      assert membership_pairs(chunk!(s.b, s.room, "membership=invite&not_membership=join")) == pairs([{s.c, "invite"}])
      assert chunk!(s.b, s.room, "membership=leave&not_membership=leave") == []
    end

    test "(e) ?at=<B's next_batch>, ?at=garbage and ?at= (empty) answer exactly what no at answers (only unsigned.age moves)", %{s: s} do
      base = s.b |> chunk!(s.room) |> strip_age()
      token = next(sync(s.b))

      for at <- [token, "garbage", "", "s0_0_0", "$not-a-token"] do
        assert s.b |> chunk!(s.room, "at=" <> URI.encode_www_form(at)) |> strip_age() == base, "at=#{inspect(at)} is ignored"
      end
    end

    test "(m) ?at=<the prev_batch of the limited room of an initial /sync> is ignored as well", %{s: s} do
      body = sync(s.b)
      prev = get_in(body, ["rooms", "join", s.room, "timeline", "prev_batch"])
      assert is_binary(prev) and prev != "", "control: the limited room has a prev_batch"

      assert s.b |> chunk!(s.room, "at=" <> URI.encode_www_form(prev)) |> strip_age() == s.b |> chunk!(s.room) |> strip_age()
    end

    test "(f) invalid membership / not_membership: 400 M_INVALID_PARAM with the fixed text, exactly {errcode, error}, no value echoed", %{s: s} do
      membership_text = "membership must be one of join, invite, knock, leave, ban"
      not_membership_text = "not_membership must be one of join, invite, knock, leave, ban"

      for {query, text, echoed} <- [
            {"membership=joined", membership_text, ["joined"]},
            {"membership=", membership_text, []},
            {"membership=JOIN", membership_text, ["JOIN"]},
            {"not_membership=JOIN", not_membership_text, ["JOIN"]},
            {"not_membership=", not_membership_text, []},
            {"not_membership=left", not_membership_text, ["left"]},
            # first failure wins: membership is validated first
            {"membership=bogus1&not_membership=bogus2", membership_text, ["bogus1", "bogus2"]},
            {"membership=join&not_membership=bogus3", not_membership_text, ["bogus3"]}
          ] do
        before = event_count(s.room)
        conn = members_conn(s.b, s.room, query)
        assert_err(conn, 400, "M_INVALID_PARAM", text)
        refute_echo(conn, echoed)
        assert event_count(s.room) == before
      end
    end

    test "(f) the validation happens BEFORE the room lookup: a never-member and an unknown room id get the 400, not the 403; nothing is created", %{s: s} do
      stranger = user!("MSN")
      unknown = unknown_room()

      assert_err(members_conn(stranger, s.room, "membership=joined"), 400, "M_INVALID_PARAM")
      assert_err(members_conn(s.b, unknown, "membership=joined"), 400, "M_INVALID_PARAM")
      assert room_rows(unknown) == 0
      assert RoomSupervisor.lookup_room(unknown) == {:error, :not_found}
    end

    test "(g) C (invited), D (banned), E (left), F (kicked), G (declined), a never-member: 403 M_FORBIDDEN, fixed text, no caller / room id in the body, nothing written", %{s: s} do
      stranger = user!("MSN")

      for {who, user} <- [invited: s.c, banned: s.d, left: s.e, kicked: s.f, declined: s.g, never_member: stranger] do
        before = event_count(s.room)
        conn = members_conn(user, s.room)

        assert_err(conn, 403, "M_FORBIDDEN", @not_member)
        refute_echo(conn, [user.uid, s.room])
        assert event_count(s.room) == before, "#{who}: nothing written"
        refute in_set?(s.room, user.uid), "#{who}: still not a member"
      end

      # positive control: a joined member of the same room gets the slice
      assert members_conn(s.b, s.room).status == 200
    end

    test "(h) an unknown room id: 403 M_FORBIDDEN, NO rooms row, NO room process", %{s: s} do
      unknown = unknown_room()

      conn = members_conn(s.b, unknown)

      assert_err(conn, 403, "M_FORBIDDEN", @not_member)
      refute_echo(conn, [unknown, s.b.uid])
      assert room_rows(unknown) == 0, "no rooms row"
      assert RoomSupervisor.lookup_room(unknown) == {:error, :not_found}, "no room process"
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [unknown]).rows == [[0]]
    end

    test "(h) a known room whose process is stopped is started from the database: 200 and the full chunk", _ctx do
      s = scenario!(messages: 0)
      stop_room!(s.room)
      refute running?(s.room)

      conn = members_conn(s.b, s.room)

      assert conn.status == 200
      assert running?(s.room), "the room was started"
      assert conn |> T.json() |> Map.fetch!("chunk") |> membership_pairs() == pairs(seven(s))
      assert room_rows(s.room) == 1
    end

    test "(i) /members runs exactly the slice and ONE predecessor statement over the room data: no create / name / generic-state read", %{s: s} do
      {conn, statements} = count_statements(fn -> members_conn(s.b, s.room) end, [s.room])

      assert conn.status == 200
      assert slice_count(statements) == 1 and predecessor_count(statements) == 1, listing(statements)
      assert length(room_statements(statements)) == 2, "only the slice and the predecessor lookup touch room data:\n#{listing(statements)}"
    end

    # security cycle 1 (L-1; old -> new): 3 -> 4 statements over the room data: the room status read AND the caller's latest-membership lookup come BEFORE the start
    test "(i) with a stopped room process the status read and the caller's membership lookup are the TWO extra statements (4 over the room data)", %{s: s} do
      stop_room!(s.room)

      {conn, statements} = count_statements(fn -> members_conn(s.b, s.room) end, [])

      assert conn.status == 200
      assert slice_count(statements) == 1 and predecessor_count(statements) == 1, listing(statements)
      assert Enum.count(statements, &String.contains?(&1, "FROM rooms")) == 1, "the room status read:\n#{listing(statements)}"
      assert length(room_statements(statements)) == 4, listing(statements)
    end

    test "(j) a repeated parameter: the last value applies (?membership=ban&membership=join -> A, B); ?membership=ban&membership=bogus -> 400", %{s: s} do
      assert membership_pairs(chunk!(s.b, s.room, "membership=ban&membership=join")) == pairs([{s.a, "join"}, {s.b, "join"}])
      assert_err(members_conn(s.b, s.room, "membership=ban&membership=bogus"), 400, "M_INVALID_PARAM", "membership must be one of join, invite, knock, leave, ban")
    end

    test "(h) AC16: a never-member on an EXISTING room and any user on an UNKNOWN room get byte-identical 403 bodies (no existence oracle)", %{s: s} do
      stranger = user!("MSN")
      existing = members_conn(stranger, s.room)
      unknown = members_conn(stranger, unknown_room())

      assert existing.status == 403 and unknown.status == 403
      assert existing.resp_body == unknown.resp_body, "the two answers are byte-identical"
      assert initial_sync_body(stranger, s.room) == initial_sync_body(stranger, unknown_room()), "and so are the two /initialSync answers"
    end

    test "(i) every chunk item carries event_id, type, state_key, sender, origin_server_ts, content and room_id", %{s: s} do
      chunk = chunk!(s.b, s.room)

      assert length(chunk) == 7
      for ev <- chunk do
        for key <- ~w(event_id type state_key sender origin_server_ts content room_id), do: assert(Map.has_key?(ev, key), "#{key} in #{ev["state_key"]}")
        assert ev["room_id"] == s.room and ev["type"] == "m.room.member"
      end
    end

    test "(f) array, map and empty-last parameters: 400 M_INVALID_PARAM with the fixed text, never a 500, no value echoed", %{s: s} do
      membership_text = "membership must be one of join, invite, knock, leave, ban"
      not_membership_text = "not_membership must be one of join, invite, knock, leave, ban"

      for {query, text, echoed} <- [
            {"membership[]=zz1", membership_text, ["zz1"]},
            {"membership[]=join", membership_text, []},
            {"membership[a]=zz2", membership_text, ["zz2"]},
            {"not_membership[]=zz3", not_membership_text, ["zz3"]},
            {"not_membership[a][b]=zz4", not_membership_text, ["zz4"]},
            {"membership=join&not_membership", not_membership_text, []}
          ] do
        conn = members_conn(s.b, s.room, query)
        assert_err(conn, 400, "M_INVALID_PARAM", text)
        refute_echo(conn, echoed)
      end
    end

    test "(f) a room that is world_readable gives a non-member NO peek: /members and /initialSync answer 403 (follow-up gf)", _ctx do
      r = small_room!()
      stranger = user!("MSN")
      assert put_state(r.a, r.room, "m.room.history_visibility", %{"history_visibility" => "world_readable"}).status == 200

      assert_err(members_conn(stranger, r.room), 403, "M_FORBIDDEN", @not_member)
      assert_err(T.matrix_request(:get, path(r.room, "initialSync"), stranger.at), 403, "M_FORBIDDEN", @not_member)
      assert members_conn(r.b, r.room).status == 200, "control: a member reads it"
    end

    # security cycle 1 (Kassandra L-1; DELIBERATE re-pin, old -> new): a never-member of a known STOPPED room used to START the process (pinned "as labelled");
    # now the caller's latest member event is read BEFORE the start: the fixed 403 and NO process; a joined member still starts it (lazily)
    test "(h) L-1: /members and /initialSync of a STOPPED room by a never-member, an invitee or a banned user: 403, the process is NOT started; a member starts it", _ctx do
      r = small_room!()
      stranger = user!("MSN")
      invitee = user!("MSI")
      invite!(r.a, r.room, invitee)
      stop_room!(r.room)
      refute running?(r.room)

      for {who, user} <- [never_member: stranger, invitee: invitee, banned: r.d] do
        assert_err(members_conn(user, r.room), 403, "M_FORBIDDEN", @not_member)
        assert_err(T.matrix_request(:get, path(r.room, "initialSync"), user.at), 403, "M_FORBIDDEN", @not_member)
        refute running?(r.room), "#{who}: no room process was started"
      end

      assert room_rows(r.room) == 1
      assert members_conn(r.b, r.room).status == 200, "a joined member reads it"
      assert running?(r.room), "and lazily starts it"
    end

    test "(h) a failing room-status read (stopped room) is a handled 500 on /members and /initialSync: generic body, value-free ERROR log, no process, no row", _ctx do
      r = small_room!()
      stop_room!(r.room)
      install_env!(:event_dispatcher, :rooms_db_module, Hooks.StatusDB)
      Hooks.arm(:atdd_ms_status, %{room: r.room, fail: true})
      rows_before = room_rows(r.room)

      for {name, fun} <- [members: fn -> members_conn(r.b, r.room) end, initial_sync: fn -> T.matrix_request(:get, path(r.room, "initialSync"), r.b.at) end] do
        {conn, log} = with_log(fun)

        assert_err(conn, 500, "M_UNKNOWN", @internal)
        # db_error_class(atom) is inspect(atom): the injected error shows as its atom
        assert log =~ r.room and log =~ "atdd_injected", "#{name}: #{log}"
        refute log =~ r.b.uid or log =~ r.d.uid
        refute running?(r.room), "#{name}: a failed status read starts no room process"
      end

      assert room_rows(r.room) == rows_before
    end

    test "(k) a slot whose latest content is unparseable or has an unknown membership is read as leave: under ?membership=leave, not under ?membership=join, listed in the leave class", _ctx do
      a = user!("MSA")
      room = public_room(a)
      cleanup_room_events_on_exit(room)
      x1 = user!("MSB")
      x2 = user!("MSC")
      x3 = user!("MSD")
      put_member!(room, x1.uid, "join", x1, ts_after(room), %{})
      # x1: a later event with a NON-string membership; x2: an unparseable string-form content; x3: an unknown membership value
      put_member!(room, x1.uid, 42, x1, ts_after(room) + 1)
      put_string_member!(room, x2.uid, "{not json", x2, ts_after(room))
      put_member!(room, x3.uid, "banished", a, ts_after(room))

      leave = chunk!(a, room, "membership=leave")
      join = chunk!(a, room, "membership=join")
      all = chunk!(a, room)

      for x <- [x1, x2, x3] do
        assert x.uid in Enum.map(leave, & &1["state_key"]), "#{x.uid} is a leave slot"
        refute x.uid in Enum.map(join, & &1["state_key"]), "#{x.uid} is not a join slot"
        assert x.uid in Enum.map(all, & &1["state_key"]), "listed without a filter"
      end

      assert Enum.map(join, & &1["state_key"]) == [a.uid], "control: the creator is the only join"
      leave_class = all |> Enum.drop(1) |> Enum.map(& &1["state_key"]) |> Enum.sort()
      assert leave_class == Enum.sort([x1.uid, x2.uid, x3.uid]), "the three corrupt slots form the leave class, after the join of A"
    end
  end

  defp initial_sync_body(user, room), do: T.matrix_request(:get, path(room, "initialSync"), user.at).resp_body

  # ═══ AC3: GET /rooms/{roomId}/initialSync ═══════════════════════════════════════════════════════

  describe "AC3 - GET /rooms/{roomId}/initialSync (D7, D10)" do
    test "B: the state has the seven member slots with real ids and unsigned, room_id on every entry, and the non-member state with real identity; no $synth_ id", %{s: s} do
      conn = T.matrix_request(:get, path(s.room, "initialSync"), s.b.at)
      assert conn.status == 200
      refute conn.resp_body =~ "$synth_"
      body = T.json(conn)

      state = body["state"]
      assert_scenario_slots!(slots(state), s, s.room)

      types = state |> Enum.map(& &1["type"]) |> Enum.uniq()
      for type <- ["m.room.create", "m.room.power_levels", "m.room.join_rules"], do: assert(type in types, "the state has #{type}")

      for ev <- state do
        assert ev["room_id"] == s.room
        assert is_binary(ev["event_id"]) and String.starts_with?(ev["event_id"], "$"), "a real event id: #{ev["type"]}"
        assert is_integer(ev["origin_server_ts"]) and is_integer(get_in(ev, ["unsigned", "age"])), "unsigned.age on #{ev["type"]}"
      end
    end

    test "B: membership, visibility, presence and account_data are unchanged and messages.chunk is a /messages page (real ids, 20 events)", %{s: s} do
      body = initial_sync!(s.b, s.room)

      assert body["room_id"] == s.room and body["membership"] == "join" and body["visibility"] == "private"
      assert body["presence"] == [] and body["account_data"] == []
      page = messages(s.b, s.room, 20)
      assert Enum.map(body["messages"]["chunk"], & &1["event_id"]) == Enum.map(page, & &1["event_id"])
      assert length(body["messages"]["chunk"]) == 20
      assert is_binary(body["messages"]["start"]) and is_binary(body["messages"]["end"])
    end

    test "non-members (C - G and a never-member): 403 M_FORBIDDEN with the fixed text, nothing written; an unknown room: 403, no rooms row, no room process", %{s: s} do
      stranger = user!("MSN")

      for user <- [s.c, s.d, s.e, s.f, s.g, stranger] do
        before = event_count(s.room)
        conn = T.matrix_request(:get, path(s.room, "initialSync"), user.at)
        assert_err(conn, 403, "M_FORBIDDEN", @not_member)
        refute_echo(conn, [user.uid, s.room])
        assert event_count(s.room) == before
      end

      unknown = unknown_room()
      conn = T.matrix_request(:get, path(unknown, "initialSync"), s.b.at)
      assert_err(conn, 403, "M_FORBIDDEN", @not_member)
      assert room_rows(unknown) == 0
      assert RoomSupervisor.lookup_room(unknown) == {:error, :not_found}
    end

    test "(l) a member slot whose event is also in messages.chunk appears in BOTH (the full-state label of D7: not deduplicated)", _ctx do
      r = small_room!()

      body = initial_sync!(r.a, r.room)

      slot = slots(body["state"])[r.b.uid]
      assert slot["content"]["membership"] == "join"
      assert Enum.any?(body["messages"]["chunk"], &(&1["event_id"] == slot["event_id"])), "B's join is in messages.chunk and in state"
    end

    test "/initialSync runs the slice once and ONE predecessor statement for its state (its messages page of plain messages needs none)", %{s: s} do
      {conn, statements} = count_statements(fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end, [s.room])

      assert conn.status == 200
      assert slice_count(statements) == 1, listing(statements)
      assert predecessor_count(statements) == 1, "one for the state:\n#{listing(statements)}"
    end
  end

  # ═══ AC5 (c) - (e): the legacy fallbacks, the half state, the fail-closed read ══════════════════

  describe "AC5 - the fallbacks and the fail-closed read (D1, D8)" do
    test "(c) a member of the member set WITHOUT any member event: a synthesized join in /sync (no unsigned) and a $synth_ id without unsigned in /members and /initialSync", _ctx do
      a = user!("MSA")
      x = user!("MSB")
      room = public_room(a)
      legacy_member!(room, x)
      before = System.system_time(:millisecond)

      {state, _} = initial_state(a, room)
      sync_slot = slots(state)[x.uid]
      assert sync_slot["content"] == %{"membership" => "join"} and sync_slot["sender"] == x.uid
      refute Map.has_key?(sync_slot, "unsigned"), "/sync: no unsigned for a member without identity"
      assert sync_slot["event_id"] == "", "/sync keeps the empty identity of today, never a $synth_ id"
      assert sync_slot["origin_server_ts"] == 0, "and the timestamp 0 (as today, D8 (a))"

      synth = "$synth_" <> Base.url_encode64("m.room.member|" <> x.uid, padding: false)

      for {name, slot} <- [members: slots(chunk!(a, room))[x.uid], initial_sync: slots(initial_sync!(a, room)["state"])[x.uid]] do
        assert slot["event_id"] == synth, "#{name}: the deterministic $synth_ id"
        assert slot["content"] == %{"membership" => "join"} and slot["sender"] == x.uid and slot["room_id"] == room
        assert slot["origin_server_ts"] >= before
        refute Map.has_key?(slot, "unsigned"), "#{name}: no unsigned"
      end

      assert slots(chunk!(a, room))[a.uid]["event_id"] != synth and Map.has_key?(slots(chunk!(a, room))[a.uid], "unsigned"), "control: the creator has his real event"
      assert membership_pairs(chunk!(a, room, "membership=join")) == pairs([{a, "join"}, {x, "join"}]), "the legacy entry matches the filters of a join"
      assert chunk!(a, room, "not_membership=join") == []
    end

    test "(d) a latest join of a user NOT in the member set is served as join in /members and /sync, while his own /members is 403 (state is event-based)", _ctx do
      a = user!("MSA")
      x = user!("MSB")
      room = public_room(a)
      cleanup_room_events_on_exit(room)
      id = put_member_id!(room, x.uid, "join", x, ts_after(room), "$half" <> T.rand(8))
      refute in_set?(room, x.uid), "fixture: x is not in the member set"

      assert slots(chunk!(a, room))[x.uid]["event_id"] == id
      assert slots(chunk!(a, room))[x.uid]["content"]["membership"] == "join"
      tick()
      for _ <- 1..25, do: say!(a, room, marker("fill"))
      {state, _} = initial_state(a, room)
      assert slots(state)[x.uid]["event_id"] == id

      before = event_count(room)
      assert_err(members_conn(x, room), 403, "M_FORBIDDEN", @not_member)
      assert event_count(room) == before
    end

    test "(e) a failing slice read: the initial /sync answers a handled 500 with the generic body and a value-free ERROR log, never a joined-only answer", %{s: s} do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: true})

      {conn, log} = with_log(fn -> sync_conn(s.b, since: nil, timeout: 0) end)

      assert_err(conn, 500, "M_UNKNOWN", @internal)
      assert log =~ s.room and log =~ "atdd_injected", "the ERROR names the room id and the error class: #{log}"
      refute log =~ s.reason or log =~ s.reason2
      for u <- [s.a, s.b, s.c, s.d], do: refute(log =~ u.uid, "the log names no user")

      Hooks.disarm(:atdd_ms_slice)
      assert sync_conn(s.b, since: nil, timeout: 0).status == 200, "control: healed"
    end

    test "(e) a failing slice read: /members and /initialSync answer a handled 500 (generic body, value-free ERROR log), never the joined members", %{s: s} do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: true})

      for {name, fun} <- [members: fn -> members_conn(s.b, s.room) end, initial_sync: fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end] do
        {conn, log} = with_log(fun)

        assert_err(conn, 500, "M_UNKNOWN", @internal)
        refute conn.resp_body =~ "chunk" or conn.resp_body =~ "state_key", "#{name}: no member list in the error"
        assert log =~ s.room and log =~ "atdd_injected", "#{name}: #{log}"
        refute log =~ s.reason or log =~ s.reason2
      end
    end
  end

  # ═══ AC7: Element's replay ══════════════════════════════════════════════════════════════════════

  describe "AC7 - Element after a reload" do
    test "A's initial /sync, then GET /members?not_membership=leave&at=<that next_batch>: C is listed as invite and D as ban with reason and sender A, although every member event is outside the timeline", %{s: s} do
      body = sync(s.a)
      assert Enum.all?(join_timeline(body, s.room), &(&1["type"] == "m.room.message")), "control: no member event in the timeline"

      chunk = chunk!(s.a, s.room, "not_membership=leave&at=" <> URI.encode_www_form(next(body)))

      assert membership_pairs(chunk) == pairs([{s.a, "join"}, {s.b, "join"}, {s.c, "invite"}, {s.d, "ban"}])
      invite = slots(chunk)[s.c.uid]
      assert invite["sender"] == s.a.uid and invite["content"]["membership"] == "invite"
      ban = slots(chunk)[s.d.uid]
      assert ban["sender"] == s.a.uid and ban["content"]["reason"] == s.reason
      assert ban["unsigned"]["prev_content"]["membership"] == "join"
    end
  end

  # ═══ AC10: logs ═════════════════════════════════════════════════════════════════════════════════

  describe "AC10 - nothing sensitive is logged" do
    test "the reads of the member state log no reason, no displayname, no query value and no member list (the request line carries the route template only)", _ctx do
      r = small_room!("rsn-" <> T.rand(6))
      name_marker = "dn" <> T.rand(8)
      at_marker = "at" <> T.rand(8)
      x = user!("MSQ")
      cleanup_room_events_on_exit(r.room)
      put_member!(r.room, x.uid, "join", x, ts_after(r.room), %{"displayname" => name_marker})
      reason = r.room |> member_events(r.d.uid) |> List.last() |> then(& &1.content["reason"])
      assert is_binary(reason) and String.starts_with?(reason, "rsn-"), "fixture: the ban carries the reason"

      log =
        with_logger_level(:info, fn ->
          capture_log(fn ->
            assert sync_conn(r.a, since: nil, timeout: 0).status == 200
            assert members_conn(r.a, r.room, "membership=ban&at=" <> at_marker).status == 200
            assert members_conn(r.a, r.room, "not_membership=leave&at=" <> at_marker).status == 200
            assert T.matrix_request(:get, path(r.room, "initialSync"), r.a.at).status == 200
          end)
        end)

      assert log =~ "members", "positive control: the requests are logged"
      for secret <- [reason, name_marker, at_marker], do: refute(log =~ secret, "the log carries no #{String.slice(secret, 0, 3)}... value")
      refute log =~ r.d.uid, "no member list"
    end
  end

  describe "security - what an invitee, a banned user and the log never see" do
    test "an invitee's initial /sync holds no member slot of others and no ban reason; a banned user's initial /sync has no rooms.join entry of the room", %{s: s} do
      invited = sync_conn(s.c, since: nil, timeout: 0)
      assert invited.status == 200
      body = T.json(invited)

      assert in_section?(body, "invite", s.room), "control: the invitation is delivered"
      refute in_section?(body, "join", s.room)
      events = get_in(body, ["rooms", "invite", s.room, "invite_state", "events"])
      for ev <- events, do: refute(ev["state_key"] in [s.b.uid, s.d.uid, s.e.uid, s.f.uid, s.g.uid], "no member slot of another user in invite_state: #{ev["type"]}")
      refute invited.resp_body =~ s.reason or invited.resp_body =~ s.reason2, "no ban / kick reason"

      banned = sync_conn(s.d, since: nil, timeout: 0)
      assert banned.status == 200
      refute in_section?(T.json(banned), "join", s.room)
      refute banned.resp_body =~ s.room, "the banned user's initial /sync does not mention the room at all"
      refute banned.resp_body =~ s.reason2 or banned.resp_body =~ s.b.uid, "and carries no member list or foreign reason"
    end
  end

  describe "AC10 (S-3) - the DEBUG payload line masks reason and displayname" do
    test "at DEBUG the payload line of /members, /initialSync and /sync appears (positive control) and the ban reason and the displayname never appear in any log line", _ctx do
      r = small_room!("rsn-" <> T.rand(6))
      name_marker = "dn" <> T.rand(8)
      x = user!("MSQ")
      cleanup_room_events_on_exit(r.room)
      put_member!(r.room, x.uid, "join", x, ts_after(r.room), %{"displayname" => name_marker, "reason" => "rx" <> T.rand(6)})
      reason = r.room |> member_events(r.d.uid) |> List.last() |> then(& &1.content["reason"])
      stored_reason = r.room |> member_events(x.uid) |> List.last() |> then(& &1.content["reason"])
      assert String.starts_with?(reason, "rsn-") and String.starts_with?(stored_reason, "rx")

      log =
        with_logger_level(:debug, fn ->
          capture_log([level: :debug], fn ->
            assert members_conn(r.a, r.room, "membership=ban").status == 200
            assert T.matrix_request(:get, path(r.room, "initialSync"), r.a.at).status == 200
            assert sync_conn(r.a, since: nil, timeout: 0).status == 200
          end)
        end)

      assert log =~ "response_body", "positive control: the DEBUG payload lines are logged"
      assert log =~ "***MESSAGE_CONTENT***", "and the content is masked in them"
      for secret <- [reason, stored_reason, name_marker], do: refute(log =~ secret, "no #{String.slice(secret, 0, 3)}... value in any log line")
    end
  end

  # ═══ security cycle 1 (Kassandra M-1): the members_read tier, the statement timeout, NUL room ids ═══════════════════

  describe "security cycle 1 - the members_read tier (60 / min, burst 30 by default; a tiny tier here)" do
    setup do
      keys = [:rate_limit_members_read_per_min, :rate_limit_members_read_burst]
      prior = for key <- keys, do: {key, Application.fetch_env(:nebu_http, key)}
      # the limiter is ON again (the module setup switched it off) with a frozen clock: no refill, so the budget is exactly `burst`
      T.reset_rate_limits()
      Application.put_env(:nebu_http, :rate_limit_members_read_per_min, 1)
      Application.put_env(:nebu_http, :rate_limit_members_read_burst, 2)

      on_exit(fn ->
        for {key, value} <- prior do
          case value do
            {:ok, v} -> Application.put_env(:nebu_http, key, v)
            :error -> Application.delete_env(:nebu_http, key)
          end
        end
      end)

      :ok
    end

    test "the 3rd /members request is 429 with Retry-After; another user and the moderation / join / invite buckets are untouched", _ctx do
      r = small_room!()
      T.reset_rate_limits()

      for _ <- 1..2, do: assert(members_conn(r.b, r.room).status == 200)
      assert_429(members_conn(r.b, r.room), "the 3rd /members")
      assert members_conn(r.a, r.room).status == 200, "another user has his own bucket"
      {moderation, join, invite} = {Nebu.Web.RateLimitTiers.moderation(), Nebu.Web.RateLimitTiers.join(), Nebu.Web.RateLimitTiers.invite()}
      assert {tokens("moderation", r.b, elem(moderation, 1)), tokens("join", r.b, elem(join, 1)), tokens("invite", r.b, elem(invite, 1))} ==
               {elem(moderation, 1) * 1.0, elem(join, 1) * 1.0, elem(invite, 1) * 1.0},
             "the other tiers of the same user were not charged"
    end

    test "/members and /initialSync draw from ONE bucket: one of each uses the budget of 2, the 3rd request of either route is 429", _ctx do
      r = small_room!()
      T.reset_rate_limits()
      initial = fn -> T.matrix_request(:get, path(r.room, "initialSync"), r.b.at) end

      assert members_conn(r.b, r.room).status == 200
      assert initial.().status == 200
      assert_429(initial.(), "the 3rd request is an /initialSync")
      assert_429(members_conn(r.b, r.room), "and a /members")
    end

    test "the charge comes FIRST: two requests for an UNKNOWN room cost two tokens (403 each), the 3rd is 429", _ctx do
      user = user!("MSR")
      T.reset_rate_limits()
      unknown = unknown_room()

      for _ <- 1..2, do: assert_err(members_conn(user, unknown), 403, "M_FORBIDDEN", @not_member)
      assert_429(members_conn(user, unknown), "the 3rd unknown-room request")
      assert room_rows(unknown) == 0
    end

    test "AC18 (c) / AC19 (i): an exhausted bucket answers 429 also for an invalid value, an unknown room, a non-member; no room statement ran", _ctx do
      r = small_room!()
      stranger = user!("MSN")
      T.reset_rate_limits()
      stop_room!(r.room)
      for _ <- 1..2, do: assert(members_conn(stranger, unknown_room()).status == 403)

      {answers, statements} =
        count_statements(
          fn ->
            [
              members_conn(stranger, r.room, "membership=bogus"),
              members_conn(stranger, unknown_room()),
              members_conn(stranger, r.room),
              T.matrix_request(:get, path(r.room, "initialSync"), stranger.at)
            ]
          end,
          []
        )

      for {conn, what} <- Enum.zip(answers, ["an invalid value", "an unknown room", "a non-member of a stopped room", "/initialSync"]), do: assert_429(conn, what)
      refute running?(r.room), "no process start"
      assert room_statements(statements) == [], "after the 429 no statement over room data ran (no slice, no status, no membership read): #{listing(statements)}"
    end

    test "the initial /sync is NOT charged to the tier: ten initial syncs, then the full budget of /members is still there", _ctx do
      r = small_room!()
      T.reset_rate_limits()

      for _ <- 1..10, do: assert(sync_conn(r.b, since: nil, timeout: 0).status == 200)
      for _ <- 1..2, do: assert(members_conn(r.b, r.room).status == 200)
      assert_429(members_conn(r.b, r.room), "only the member reads drew from the bucket")
      assert sync_conn(r.b, since: nil, timeout: 0).status == 200, "and an initial /sync at the exhausted bucket stays 200"
    end

    test "the DISABLED switch (the application key of NEBU_RATE_LIMIT_DISABLED) turns the tier off: ten requests all answer 200", _ctx do
      r = small_room!()
      T.reset_rate_limits()
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      for _ <- 1..6, do: assert(members_conn(r.b, r.room).status == 200)
      for _ <- 1..3, do: assert(T.matrix_request(:get, path(r.room, "initialSync"), r.b.at).status == 200)
    end
  end

  describe "security cycle 1 - the statement timeout of the slice (M-1) and NUL room ids (MINOR-3)" do
    test "AC19 (c): a slice timeout or lost connection: value-free 503 M_UNAVAILABLE on /members and /initialSync, never joined-only", %{s: s} do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: :timeout})

      for {name, fun} <- [
            members: fn -> members_conn(s.b, s.room) end,
            initial_sync: fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end
          ] do
        {conn, log} = with_log(fun)

        assert_err(conn, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")
        refute conn.resp_body =~ "chunk" or conn.resp_body =~ "state_key", "#{name}: no member list in the error"
        assert log =~ s.room and log =~ "57014", "#{name}: the WARNING names the room id and the SQLSTATE class: #{log}"
        refute log =~ s.reason or log =~ s.b.uid, "#{name}: value-free"
      end

      # security cycle 2 (M-2, MINOR 3; the /sync paths degrade instead, see below): a pool checkout that failed is the same 503, returned or raised
      for kind <- [:connection, :connection_raise], {name, fun} <- [members: fn -> members_conn(s.b, s.room) end, initial_sync: fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end] do
        Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: kind})
        {conn, log} = with_log(fun)
        assert_err(conn, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")
        assert log =~ s.room and log =~ "DBConnection.ConnectionError", "#{name} #{kind}: the class is named: #{log}"
        refute log =~ s.b.uid
      end

      Hooks.disarm(:atdd_ms_slice)
      assert members_conn(s.b, s.room).status == 200, "control: healed"
    end

    test "a NUL room id (/rooms/%00/...) is no room: the fixed 403 on /members and /initialSync, no ERROR log, no 500, no new rooms row", %{s: s} do
      rooms_before = room_count()

      for suffix <- ["members", "initialSync"] do
        {{conn, statements}, log} = with_log(fn -> count_statements(fn -> T.matrix_request(:get, "/_matrix/client/v3/rooms/%00/#{suffix}", s.b.at) end, []) end)

        assert_err(conn, 403, "M_FORBIDDEN", @not_member)
        refute log =~ "[error]", "#{suffix}: no ERROR log: #{log}"
        assert room_statements(statements) == [], "#{suffix}: no statement over room data (the id is never sent to the database): #{listing(statements)}"
      end

      assert room_count() == rooms_before
    end
  end

  # ═══ security cycle 2 (Kassandra M-2, M-1R, MINOR 2): degradation on /sync, the node-wide gate, the predecessor timeout ═══

  defp other_room_for!(user) do
    other = scenario!(messages: 0)
    join!(user, other.room)
    for _ <- 1..25, do: say!(other.a, other.room, marker("after"))
    other
  end

  defp warning_lines(log, needle), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ needle))

  describe "cycle 2: a slice failure degrades ONE room of a /sync (M-2)" do
    for {kind, class} <- [timeout: "57014", connection: "DBConnection.ConnectionError", connection_raise: "DBConnection.ConnectionError"] do
      test "AC19 (a) #{kind}: initial /sync 200, the failing room joined-only, the other room complete, ONE value-free warning", %{s: s} do
        other = other_room_for!(s.b)
        install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
        Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: unquote(kind)})

        {conn, log} = with_log(fn -> sync_conn(s.b, since: nil, timeout: 0) end)

        assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        body = T.json(conn)
        assert membership_pairs(join_state(body, s.room)) == pairs([{s.a, "join"}, {s.b, "join"}]), "the failing room: the joined slice only (no invite / ban / leave slot)"
        full = Enum.sort(pairs(seven(other) ++ [{s.b, "join"}]))
        assert membership_pairs(join_state(body, other.room)) == full, "the other room keeps its full member state"

        assert [line] = warning_lines(log, s.room), "exactly ONE warning names the failing room: #{log}"
        assert line =~ unquote(class)
        assert warning_lines(log, other.room) == []
        for u <- [s.a, s.b, s.c, s.d], do: refute(log =~ u.uid, "no user id in the log")
        refute log =~ s.reason
      end
    end

    test "AC19 (a): the same for a garbage since and for since + full_state=true (full_state_rooms); 200, others stay complete", %{s: s} do
      other = other_room_for!(s.b)
      token = next(sync(s.b))
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: :timeout})

      for {name, params} <- [garbage_since: [since: "garbage", timeout: 0], full_state: [since: token, full_state: true, timeout: 0]] do
        {conn, log} = with_log(fn -> sync_conn(s.b, params) end)

        assert conn.status == 200, "#{name}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        body = T.json(conn)
        assert membership_pairs(join_state(body, s.room)) == pairs([{s.a, "join"}, {s.b, "join"}]), "#{name}: joined-only"
        assert membership_pairs(join_state(body, other.room)) == Enum.sort(pairs(seven(other) ++ [{s.b, "join"}])), "#{name}: the other room is complete"
        assert [_one] = warning_lines(log, s.room), "#{name}: ONE warning"
      end
    end

    test "AC19 (b): every OTHER slice error class still fails the whole initial /sync with the handled 500 (fail-closed), value-free", %{s: s} do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: true})

      {conn, log} = with_log(fn -> sync_conn(s.b, since: nil, timeout: 0) end)

      assert_err(conn, 500, "M_UNKNOWN", @internal)
      assert log =~ s.room and log =~ "atdd_injected"
    end
  end

  describe "cycle 2: the node-wide gate of slice reads (M-1R)" do
    setup do
      # setup_env! lifted the gate for the whole suite (and restores it): these tests set their own limit, the default one sees the key deleted
      Application.delete_env(:nebu, :member_slice_max_concurrency)
      :ok
    end

    # `n` readers of /members, all blocked inside the slice read of the hook: the slots are held
    defp hold_readers!(s, n) do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_slice, %{room: s.room, block: self()})
      tasks = for _ <- 1..n, do: Task.async(fn -> members_conn(s.b, s.room) end)
      victims = for _ <- 1..n, do: (receive do {:ms_gap, pid, :slice_read} -> pid after 10_000 -> flunk("a reader did not reach the slice read") end)
      {tasks, victims}
    end

    test "AC19 (d): limit 2 and two blocked readers: the 3rd read does not start (503 / degraded room), after they finish a new read runs", %{s: s} do
      Application.put_env(:nebu, :member_slice_max_concurrency, 2)
      {holders, victims} = hold_readers!(s, 2)

      # the overflow readers run in tasks: a started read would BLOCK in the hook, so a missing gate shows as a timeout, not a hang
      overflow = fn fun -> fun |> Task.async() |> Task.yield(8_000) end
      {:ok, members} = overflow.(fn -> members_conn(s.b, s.room) end)
      {:ok, initial} = overflow.(fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end)
      {:ok, {sync, log}} = overflow.(fn -> with_log(fn -> sync_conn(s.b, since: nil, timeout: 0) end) end)

      assert_err(members, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")
      assert_err(initial, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")
      assert sync.status == 200
      assert membership_pairs(join_state(T.json(sync), s.room)) == pairs([{s.a, "join"}, {s.b, "join"}]), "the /sync room is joined-only while the gate is full"
      assert [line] = warning_lines(log, s.room)
      assert line =~ "overflow"
      refute_receive {:ms_gap, _pid, :slice_read}, 300

      for v <- victims, do: send(v, :go)
      for task <- holders, do: assert(Task.await(task, 20_000).status == 200)
      Hooks.disarm(:atdd_ms_slice)
      assert members_conn(s.b, s.room).status == 200, "after the release a new read runs"
    end

    test "AC19 (d): the default limit is 3 concurrent reads per node: three blocked readers hold it, the 4th /members answers 503 at once", %{s: s} do
      {holders, victims} = hold_readers!(s, 3)

      assert {:ok, fourth} = Task.yield(Task.async(fn -> members_conn(s.b, s.room) end), 8_000)
      assert_err(fourth, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")

      for v <- victims, do: send(v, :go)
      for task <- holders, do: assert(Task.await(task, 20_000).status == 200)
    end

    test "AC19 (e): the slot is released after a success, a timeout, another error and a KILLED reading process: at the limit 1 the next read is never refused", %{s: s} do
      Application.put_env(:nebu, :member_slice_max_concurrency, 1)
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)

      assert members_conn(s.b, s.room).status == 200, "a single reader at the limit 1 is never refused"
      assert members_conn(s.b, s.room).status == 200, "after a success"

      for {fail, expected} <- [{:timeout, 503}, {:connection, 503}, {true, 500}] do
        Hooks.arm(:atdd_ms_slice, %{room: s.room, fail: fail})
        assert members_conn(s.b, s.room).status == expected
        Hooks.disarm(:atdd_ms_slice)
        assert members_conn(s.b, s.room).status == 200, "after a failing read (#{inspect(fail)}) the slot is free"
      end

      # a reader that is KILLED inside the slice read never runs an `after`: its slot must still be reclaimed
      Hooks.arm(:atdd_ms_slice, %{room: s.room, block: self()})
      victim = Task.async(fn -> members_conn(s.b, s.room) end)
      assert_receive {:ms_gap, _blocked, :slice_read}, 10_000
      {:ok, busy} = Task.yield(Task.async(fn -> members_conn(s.b, s.room) end), 8_000)
      assert_err(busy, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")

      Process.unlink(victim.pid)
      Process.exit(victim.pid, :kill)
      Hooks.disarm(:atdd_ms_slice)

      assert members_conn(s.b, s.room).status == 200, "no leak: the slot of the killed reader was reclaimed"
      assert members_conn(s.b, s.room).status == 200
    end

    test "AC19 (d): a single reader is never blocked: ten sequential reads at the default limit are all 200", %{s: s} do
      for _ <- 1..10, do: assert(members_conn(s.b, s.room).status == 200)
    end
  end

  describe "cycle 2: the predecessor pass has its own timeout (MINOR 2)" do
    test "AC19 (f): a predecessor lookup timeout is the fixed 503 on /members and /initialSync; /sync keeps its lenient lookup (200)", %{s: s} do
      install_env!(:event_dispatcher, :messages_db_module, Hooks.SliceDB)
      Hooks.arm(:atdd_ms_pred, %{fail: :timeout})

      for {name, fun} <- [members: fn -> members_conn(s.b, s.room) end, initial_sync: fn -> T.matrix_request(:get, path(s.room, "initialSync"), s.b.at) end] do
        {conn, log} = with_log(fun)
        assert_err(conn, 503, "M_UNAVAILABLE", "The member list is temporarily unavailable, try again")
        assert log =~ s.room and log =~ "57014", "#{name}: #{log}"
        refute conn.resp_body =~ "state_key"
      end

      assert sync_conn(s.b, since: nil, timeout: 0).status == 200, "control: the lenient /sync lookup is unchanged"
    end
  end

  # ═══ AC12: crash / restart ══════════════════════════════════════════════════════════════════════

  describe "AC12 - crash / restart (the slice is read from the database)" do
    test "the room process is killed and restarted: the initial /sync, /members and /initialSync answer the same; a member event written after the restart appears", _ctx do
      s = scenario!()
      before = {s.b |> sync() |> join_state(s.room) |> strip_age() |> sort_events(), s.b |> chunk!(s.room) |> strip_age(), s.b |> initial_sync!(s.room) |> Map.fetch!("state") |> strip_age() |> sort_events()}

      kill_and_restart!(s.room)

      after_restart = {s.b |> sync() |> join_state(s.room) |> strip_age() |> sort_events(), s.b |> chunk!(s.room) |> strip_age(), s.b |> initial_sync!(s.room) |> Map.fetch!("state") |> strip_age() |> sort_events()}
      assert after_restart == before, "the three answers are identical after the restart"

      h = user!("MSH")
      invite!(s.a, s.room, h)
      assert slots(chunk!(s.b, s.room))[h.uid]["content"]["membership"] == "invite", "a member event written after the restart appears"
      body = sync(s.b)
      assert member_ev(join_state(body, s.room) ++ join_timeline(body, s.room), h.uid, "invite"), "the initial /sync delivers it (the newest event is inside the window)"
    end
  end

  defp sort_events(events), do: Enum.sort_by(events, &{&1["type"], &1["state_key"]})

  # ═══ AC16: the Oracle's missing tests ═══════════════════════════════════════════════════════════

  describe "AC16 - the Oracle tests" do
    test "(a) D's ban INSIDE the 20-event timeline of A's initial /sync: the ban is in the timeline, the state has NO slot for D (no prior join is served), the replay ends with ban", _ctx do
      r = small_room!()

      body = sync(r.a)
      timeline = join_timeline(body, r.room)
      state = join_state(body, r.room)

      assert ban = member_ev(timeline, r.d.uid, "ban"), "the ban is in the timeline"
      assert ban["sender"] == r.a.uid
      refute Map.has_key?(slots(state), r.d.uid), "no state slot for D: no prior join is served (the D11 label)"
      assert replay(state ++ timeline)[r.d.uid] == "ban"
    end

    test "(c) a join with a displayname (direct insert) is delivered by the initial /sync with the real content; the incremental /sync re-sends the synthesized joined slot (the `gg` risk), never a 500", _ctx do
      a = user!("MSA")
      b = user!("MSB")
      room = public_room(a)
      cleanup_room_events_on_exit(room)
      join!(b, room)
      join_row = room |> member_events(b.uid) |> List.last()
      name = "dn" <> T.rand(6)
      named = put_member_id!(room, b.uid, "join", b, ts_after(room), "$named" <> T.rand(8), %{"displayname" => name})
      tick()
      for _ <- 1..25, do: say!(a, room, marker("fill"))

      first = sync(a)
      assert slots(join_state(first, room))[b.uid]["event_id"] == named, "the initial /sync delivers the latest join with its displayname"
      assert slots(join_state(first, room))[b.uid]["content"]["displayname"] == name

      token = next(first)
      tick()
      say!(a, room, marker("later"))
      conn = sync_conn(a, since: token, timeout: 0)

      assert conn.status == 200
      slot = conn |> T.json() |> join_state(room) |> slots() |> Map.get(b.uid)
      # `gg`: the delta re-sends the joined slice of the room process: {"membership": "join"} with the JOIN-TIME id, which can overwrite the real content
      assert slot["content"] == %{"membership" => "join"}
      assert slot["event_id"] == join_row.event_id
    end

    test "(d) a limited incremental /sync (25 new events, then a ban of C): the NEWEST 20 carry the ban (`fc` closed, the tail is delivered); the NEXT initial /sync lists C as ban", _ctx do
      a = user!("MSA")
      b = user!("MSB")
      c = user!("MSC")
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      token = next(sync(a))
      tick()
      for _ <- 1..25, do: say!(a, room, marker("gap"))
      ok!(ban(a, room, c, %{"reason" => "lost"}), "ban C")

      delta = sync(a, token)

      assert get_in(delta, ["rooms", "join", room, "timeline", "limited"]) == true
      timeline = join_timeline(delta, room)
      assert length(timeline) == 20 and Enum.count(timeline, &(&1["type"] == "m.room.message")) == 19, "control: the window is the newest 20: 19 messages and the ban"
      assert member_ev(timeline, c.uid, "ban"), "the ban is the newest event: it is in the timeline of the limited delta (the tail is no longer lost)"
      assert List.last(timeline)["type"] == "m.room.member"
      state = join_state(delta, room)
      refute Map.has_key?(slots(state), c.uid), "and not in the joined slice of its state (C is banned; the member event is in the timeline)"
      assert Map.has_key?(slots(state), b.uid), "control: the joined slots are re-sent"

      # 25 more messages push the ban out of the 20-event window of the next initial /sync: only the STATE can then carry it
      for _ <- 1..25, do: say!(a, room, marker("after"))
      fresh = sync(a)
      refute member_ev(join_timeline(fresh, room), c.uid, "ban"), "control: the ban is outside the window now"
      assert slots(join_state(fresh, room))[c.uid]["content"]["membership"] == "ban", "the next initial /sync repairs the view in its state"
    end

    test "(n) GET /rooms/{r}/state, /state/m.room.member and /state/m.room.member/{D}: 404 M_NOT_FOUND Unrecognized request, unchanged, no slice statement (`bf`)", %{s: s} do
      for suffix <- ["state", "state/m.room.member", "state/m.room.member/" <> enc(s.d.uid)] do
        {conn, statements} = count_statements(fn -> T.matrix_request(:get, path(s.room, suffix), s.a.at) end, [s.room])

        assert_err(conn, 404, "M_NOT_FOUND", "Unrecognized request")
        assert slice_count(statements) == 0, "#{suffix}: no slice statement"
      end
    end
  end

  # ═══ AC4 (HTTP half): the bound ═════════════════════════════════════════════════════════════════

  describe "AC4 - the bound of the non-joined slots (D4)" do
    @tag timeout: 300_000
    test "3 joined + EXACTLY 10 000 of 10 010 non-joined slots (invite > ban > leave, newest first) in /sync and /members; the filters apply BEFORE the cap", _ctx do
      a = user!("MSA")
      b = user!("MSB")
      c = user!("MSC")
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      cleanup_room_events_on_exit(room)
      base = System.system_time(:millisecond) - 200_000

      # 3 invites (oldest), 2 bans, 10 005 leaves: the timestamps are all in the past and distinct (no future-dated row, follow-up `fj`)
      invites = bulk_members!(room, 3, ["invite"], base - 100_000, a)
      bans = bulk_members!(room, 2, ["ban"], base - 90_000, a)
      leaves = bulk_members!(room, 10_005, ["leave"], base, a)
      # the 20-event window of the initial /sync must hold messages only (a slot inside the window would be in the timeline, not in state)
      for _ <- 1..25, do: say!(a, room, marker("fill"))
      newest_leaves = leaves |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.take(9_995) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      expected = (Enum.map(invites, &elem(&1, 0)) ++ Enum.map(bans, &elem(&1, 0))) |> MapSet.new() |> MapSet.union(newest_leaves)

      {conn, statements} = count_statements(fn -> members_conn(b, room) end, [room])
      assert conn.status == 200
      assert slice_count(statements) == 1 and predecessor_count(statements) == 1, "10 000 slots are still ONE slice and ONE predecessor statement: #{listing(statements)}"

      first = chunk!(b, room)
      second = chunk!(b, room)
      joined = Enum.filter(first, &(&1["content"]["membership"] == "join"))
      others = Enum.reject(first, &(&1["content"]["membership"] == "join"))

      assert length(joined) == 3
      assert length(others) == 10_000
      assert MapSet.new(others, & &1["state_key"]) == expected, "invites and bans first, then the NEWEST leaves"
      assert strip_age(first) == strip_age(second), "deterministic across two calls"

      {state, _} = initial_state(b, room)
      sync_others = state |> Enum.filter(&(&1["type"] == "m.room.member")) |> Enum.reject(&(&1["content"]["membership"] == "join"))
      assert length(sync_others) == 10_000, "the initial /sync lists exactly 10 000 non-joined slots, got #{length(sync_others)}"
      assert MapSet.new(sync_others, & &1["state_key"]) == expected, "the initial /sync lists the same slots"
      assert Enum.count(state, &(&1["type"] == "m.room.member" and &1["content"]["membership"] == "join")) == 3

      assert membership_pairs(chunk!(b, room, "membership=ban")) == Enum.sort(Enum.map(bans, fn {u, _m, _t} -> {u, "ban"} end)), "every ban is listed"
      assert length(chunk!(b, room, "membership=leave")) == 10_000, "filter first, then cap: 10 005 leaves, 10 000 listed"
      assert length(chunk!(b, room, "not_membership=invite")) == 3 + 10_000, "3 joined slots (uncapped) + 10 000 of the 2 bans and the leaves"
    end
  end
end
