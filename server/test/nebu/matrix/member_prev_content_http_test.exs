defmodule Nebu.Matrix.MemberPrevContentHttpTest do
  @moduledoc """
  Story `member-event-prev-content` (epic oauth-broker, follow-up `ff`, e2e known failure K10), HTTP half, AC2 (b), AC4 - AC7: state events carry
  `unsigned.prev_content` / `unsigned.prev_sender` next to `unsigned.replaces_state`, so that Element marks an accepted DM invitation as a direct
  chat (`RoomMember.getDMInviter()` reads the invitee's own JOIN event: `unsigned.prev_content == {"membership": "invite", "is_direct": true}`
  and `unsigned.prev_sender == <inviter>`). Real stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg, users
  and sessions as in `sync_membership_partition_http_test.exs`, random localparts, `:server_name` pinned). Everything the real SQL decides is
  pinned here against the real database; the statement itself is pinned in `room/state_predecessors_db_test.exs`.

  Conventions (copied from `sync_membership_partition_http_test.exs`, the helpers are `defp`s):

    * `T` is `Nebu.OAuth.TestSupport`. Ban / kick have no HTTP route: the dispatcher is called directly (real Room.Server / Postgres). A
      revocation has no route either (follow-up `fb`): the leave event is written through `Room.DB.insert_event/1`.
    * `tick/0` separates writes whose ORDER matters (the incremental sync reads `origin_server_ts > anchor`, the latest membership is read by
      timestamp) EXCEPT where a test deliberately builds the no-tick case (AC2 (b)) or a same-millisecond tie (the DB suite).
    * The anchor of a user's sync token is the newest event the user's previous response delivered: `snapshot!/2` makes the user's anchor room
      the newest thing before the token is taken, so every later event of the scenario is NEW (follow-up `fc`).
    * Every negative assertion has a POSITIVE control in the same test (the room / the event DID arrive).
    * Follow-up `fj`: a future-stamped event in the shared database breaks `tick/0` of other suites. The two clock-ahead tests (AC2 (b)) write
      ONE member event 1500 ms ahead of the clock into a room they own and DELETE the room's events afterwards (`on_exit`).

  ## Decisions of the ATDD step (ambiguities of the story)

    * The SQL statement carries the marker comment `/* state_predecessors */` (AC6 counts the statements that contain it).
    * AC6 (b) / (c) pin the statement counts of an initial sync (3 joined rooms) and of `POST /join` with `==` against constants recorded from the
      code BEFORE this story (HEAD 54ecc9ed): see `@baseline_*` below (the story's "baseline before the change").
    * `unsigned` of `/messages` and `/event` is EXACTLY the three keys for a state event with a predecessor (no `age`: follow-up `fl` (b)).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"
  @marker "/* state_predecessors */"
  @triple ["prev_content", "prev_sender", "replaces_state"]

  # statement counts of the CODE BEFORE the story (HEAD 54ecc9ed), measured with the same data as the tests build (AC6 (b), (c))
  # (measured repeatedly on the unchanged code of HEAD 54ecc9ed with the calibrated test forms below, also in full-suite runs)
  # story state-writer-redaction (DELIBERATE re-pin, test review MAJOR-2; old -> new): 45 -> 48. The prune of redacted events adds ONE batched `redactions_for/1`
  # statement per `event_maps_to_core_events/1` call, i.e. one per joined room (3 rooms here); the other statements are unchanged (see the multi-room pins of
  # redaction_http_test.exs AC5 (f))
  # story membership-state-model (DELIBERATE re-pin, AC15 (c); old -> new): 48 -> 51. The member slice of an initial /sync is read from the member events: ONE more
  # `member_state_slice` statement per joined room (3 rooms here); the other statements are unchanged (the batched predecessor lookup now also covers the non-joined slots)
  # security cycle 1 (Kassandra M-1, DELIBERATE re-pin; old -> new): 51 -> 54. The member slice now runs in a transaction behind `SET LOCAL statement_timeout = '2s'`:
  # ONE more statement per joined room (3 rooms here; begin / commit are not counted)
  # story sync-token-per-device (DELIBERATE re-pin; old -> new): 54 -> 57. A device-bound INITIAL /sync (no since) runs THREE more statements, independent of the
  # number of rooms: `get_positions` (the positions of the device's row), `changed_since?` (the cross-signing position, new: it was never read without a since) and
  # `advance_positions`; `list_since` takes the place of `list_all_and_clear` one for one
  # story sync-stream-position (DELIBERATE re-pin, old -> new, MEASURED on the final design): 57 -> 59: + ONE head statement (`room_heads`, D12), and the
  # persist is a transaction of TWO statements (the token upsert and ONE cursor statement, whatever the number of rooms) instead of the one token upsert.
  @baseline_initial_sync_statements 59
  @baseline_join_statements 11

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)

    {:ok, a: user!("MPA"), b: user!("MPB"), c: user!("MPC"), d: user!("MPD")}
  end

  # ─── helpers (copied from sync_membership_partition_http_test.exs) ─────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp enc(room_id), do: URI.encode_www_form(room_id)
  defp path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"
  defp marker(label), do: "#{label}-#{T.rand(8)}"

  # waits until the millisecond clock is PAST the newest event of the last seconds (createRoom stamps its chain and the invite events up to
  # about 70 ms AHEAD of the clock, follow-up eu F-4): the smallest wait that makes the scenarios deterministic
  defp tick do
    horizon = System.system_time(:millisecond) - 10_000
    newest = T.sql!("SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE origin_server_ts > $1", [horizon]).rows |> hd() |> hd()
    :ok = wait_until(fn -> System.system_time(:millisecond) > newest end, 300)
  end

  defp ts_after(room) do
    newest = T.sql!("SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
    max(System.system_time(:millisecond), newest) + 1
  end

  defp wait_until(fun, attempts) when is_integer(attempts) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> :timeout
      true -> (Process.sleep(1); wait_until(fun, attempts - 1))
    end
  end

  defp make_room(user, body) do
    conn = T.matrix_request(:post, @create, user.at, body: body)
    assert conn.status == 200, "createRoom #{inspect(body)}: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  defp leave(user, room), do: T.matrix_request(:post, path(room, "leave"), user.at)
  defp invite(owner, room, target), do: T.matrix_request(:post, path(room, "invite"), owner.at, body: %{"user_id" => target.uid})
  defp put_state(user, room, type, body), do: T.matrix_request(:put, path(room, "state/#{type}"), user.at, body: body)

  defp invite!(owner, room, target) do
    c = invite(owner, room, target)
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
  end

  defp join!(user, room) do
    tick()
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
  end

  defp leave!(user, room) do
    tick()
    c = leave(user, room)
    assert c.status == 200, "leave: #{c.status} #{c.resp_body}"
  end

  # a state event of the room's slot, written AFTER the clock passed the previous write of that slot (same-millisecond writes tie)
  defp put_state!(user, room, type, body) do
    tick()
    c = put_state(user, room, type, body)
    assert c.status == 200, "put state #{type}: #{c.status} #{c.resp_body}"
    T.json(c)["event_id"]
  end

  defp topic!(user, room, text), do: put_state!(user, room, "m.room.topic", %{"topic" => text})

  defp say!(user, room, body) do
    c = T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: %{"msgtype" => "m.text", "body" => body})
    assert c.status == 200, "send: #{c.status} #{c.resp_body}"
    T.json(c)["event_id"]
  end

  defp moderate(:kick, room, caller, target) do
    req = %Core.KickUserRequest{room_id: room, target_id: target.uid, reason: ""}
    assert %Core.KickUserResponse{} = Nebu.Matrix.EventDispatcher.Server.kick_user(req, Nebu.Matrix.Http.stream(caller.uid))
  end

  defp content_of(c) when is_map(c), do: c

  defp content_of(c) when is_binary(c) do
    case Jason.decode!(c) do
      decoded when is_binary(decoded) -> content_of(decoded)
      decoded -> decoded
    end
  end

  # every m.room.member event of `uid` in the room, oldest first: %{sender, content, ts, event_id}
  defp member_events(room_id, uid) do
    T.sql!(
      "SELECT sender, content, origin_server_ts, event_id FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 ORDER BY origin_server_ts, event_id",
      [room_id, uid]
    ).rows
    |> Enum.map(fn [sender, content, ts, id] -> %{sender: sender, content: content_of(content), ts: ts, event_id: id} end)
  end

  defp only(room_id, type) do
    rows = T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = ''", [room_id, type]).rows
    assert [[content]] = rows, "exactly one #{type} event expected"
    content_of(content)
  end

  # a member event written WITHOUT touching the invitation row / the member set (the revocation: no route, follow-up fb)
  defp write_member_event!(room, user, membership, sender, ts \\ nil) do
    id = "$" <> T.rand(12)

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => sender,
               "type" => "m.room.member",
               "state_key" => user,
               "content" => %{"membership" => membership},
               "origin_server_ts" => ts || ts_after(room)
             })

    id
  end

  # Element's exact DM body (history_visibility invited)
  defp element_dm(partner_uid) do
    %{
      "preset" => "trusted_private_chat",
      "visibility" => "private",
      "invite" => [partner_uid],
      "is_direct" => true,
      "initial_state" => [
        %{"type" => "m.room.guest_access", "state_key" => "", "content" => %{"guest_access" => "can_join"}},
        %{"type" => "m.room.encryption", "state_key" => "", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}},
        %{"type" => "m.room.history_visibility", "state_key" => "", "content" => %{"history_visibility" => "invited"}}
      ]
    }
  end

  # ─── the sync client ───────────────────────────────────────────────────────────

  defp sync_conn(user, params) do
    query = params |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end) |> URI.encode_query()
    T.matrix_request(:get, "/_matrix/client/v3/sync" <> if(query == "", do: "", else: "?" <> query), user.at)
  end

  defp sync(user, since \\ nil, params \\ []) do
    conn = sync_conn(user, [since: since, timeout: Keyword.get(params, :timeout, 0)] ++ Keyword.delete(params, :timeout))
    assert conn.status == 200, "sync: #{conn.status} #{conn.resp_body}"
    T.json(conn)
  end

  defp section(body, name), do: get_in(body, ["rooms", name]) || %{}
  defp joined(body), do: section(body, "join")
  defp in_section?(body, name, room), do: Map.has_key?(section(body, name), room)
  defp next(body), do: body["next_batch"]
  defp invite_events(body, room), do: get_in(body, ["rooms", "invite", room, "invite_state", "events"]) || []
  defp leave_timeline(body, room), do: get_in(body, ["rooms", "leave", room, "timeline", "events"]) || []
  defp join_timeline(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "events"]) || []
  defp join_state(body, room), do: get_in(body, ["rooms", "join", room, "state", "events"]) || []
  defp join_events(body, room), do: join_state(body, room) ++ join_timeline(body, room)

  defp anchor_room!(user), do: make_room(user, %{})

  defp snapshot!(user, anchor) do
    tick()
    say!(user, anchor, marker("anchor"))
    body = sync(user)
    tick()
    next(body)
  end

  defp room_with!(owner, members, body \\ %{}) do
    room = make_room(owner, Map.merge(%{"preset" => "private_chat"}, body))

    for m <- members do
      invite!(owner, room, m)
      join!(m, room)
    end

    room
  end

  # ─── event finders and the one assertion of this suite ─────────────────────────────

  defp member_ev(events, uid, membership) do
    Enum.find(events, &(&1["type"] == "m.room.member" and &1["state_key"] == uid and get_in(&1, ["content", "membership"]) == membership))
  end

  defp event_with_id(events, id), do: Enum.find(events, &(&1["event_id"] == id))

  # `ev["unsigned"]` carries replaces_state / prev_content / prev_sender with exactly these values, and nothing else but `age` (sync renderers)
  defp assert_triple(ev, replaces_id, prev_content, prev_sender, opts \\ []) do
    assert is_map(ev), "the event must be delivered"
    unsigned = ev["unsigned"]
    assert is_map(unsigned), "#{ev["type"]}/#{inspect(ev["state_key"])} must carry unsigned, got #{inspect(ev)}"

    assert Map.take(unsigned, @triple) == %{"replaces_state" => replaces_id, "prev_content" => prev_content, "prev_sender" => prev_sender},
           "unsigned of #{ev["type"]}/#{inspect(ev["state_key"])}: #{inspect(unsigned)}"

    if Keyword.get(opts, :age, true) do
      assert is_integer(unsigned["age"]), "age is rendered by the sync: #{inspect(unsigned)}"
      assert Enum.sort(Map.keys(unsigned)) == Enum.sort(["age" | @triple]), "no other unsigned key: #{inspect(unsigned)}"
    else
      assert Enum.sort(Map.keys(unsigned)) == @triple, "no age on /messages and /event (follow-up fl (b)), no other key: #{inspect(unsigned)}"
    end
  end

  defp refute_triple(ev) do
    assert is_map(ev), "the event must be delivered"
    unsigned = ev["unsigned"] || %{}
    for key <- @triple, do: refute(Map.has_key?(unsigned, key), "#{ev["type"]}/#{inspect(ev["state_key"])} must carry no #{key}, got #{inspect(unsigned)}")
  end

  defp stripped_keys_ok!(events) do
    assert events != [], "positive control: the invitation has stripped events"

    for ev <- events do
      assert Enum.sort(Map.keys(ev)) == ["content", "sender", "state_key", "type"], "stripped state has exactly four keys, no unsigned: #{inspect(ev)}"
    end
  end

  # ─── statement counting (telemetry of the repo) ───
  #
  # ONLY the statements of the request under test are counted, so that the count does not depend on what else a full `mix test` run has going on
  # (a background job, the log-store writer): the test process, the Tasks it spawned (the sync fetches rooms in tasks: `$callers`) and the
  # Room.Server processes of the rooms involved (`allow`).

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid, allow: allow}) do
    mine? = self() == pid or pid in (Process.get(:"$callers") || []) or self() in allow
    if mine? and not noise?(query), do: send(pid, {:statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  # whether the compliance audit writer writes a real `audit_log` row (inside its own transaction: begin / insert / commit) or a no-op depends on
  # what earlier suites of the run configured; the log-store writer likewise: neither belongs to the request under test
  defp noise?(query), do: query in ["begin", "commit", "rollback"] or String.contains?(query, "operational_logs") or String.contains?(query, "\"audit_log\"")

  defp room_pids(rooms) do
    for room <- rooms, {:ok, pid} <- [Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)], do: pid
  end

  defp count_statements(fun, rooms \\ []) do
    id = "mp-http-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self(), allow: room_pids(rooms)})

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:statement, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp listing(statements), do: statements |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.slice(0, 110))) |> Enum.join("\n")

  defp marker_count(statements), do: Enum.count(statements, &String.contains?(&1, @marker))

  # ═══ AC4 (a): THE DM CASE ═════════════════════════════════════════════════════════

  describe "AC4 (a) - the DM case" do
    test "A creates Element's DM for B, B joins: B's next sync, his fresh initial sync and A's sync show B's join with the invite as prev_content, A as prev_sender", %{a: a, b: b} do
      anchor_b = anchor_room!(b)
      anchor_a = anchor_room!(a)
      token_b = snapshot!(b, anchor_b)
      token_a = snapshot!(a, anchor_a)

      dm = make_room(a, element_dm(b.uid))
      invitation_body = sync(b, token_b)
      assert in_section?(invitation_body, "invite", dm), "control: B sees the invitation"
      stripped_keys_ok!(invite_events(invitation_body, dm))
      assert [invite_row] = member_events(dm, b.uid)
      assert invite_row.content == %{"membership" => "invite", "is_direct" => true} and invite_row.sender == a.uid

      join!(b, dm)
      assert [^invite_row, join_row] = member_events(dm, b.uid)
      invite_content = %{"membership" => "invite", "is_direct" => true}

      joined_body = sync(b, next(invitation_body))
      assert in_section?(joined_body, "join", dm), "control: the room moved to rooms.join"
      assert_triple(member_ev(join_timeline(joined_body, dm), b.uid, "join"), invite_row.event_id, invite_content, a.uid)

      fresh = sync(b)
      join_in_fresh = Enum.filter(join_events(fresh, dm), &(&1["event_id"] == join_row.event_id))
      assert join_in_fresh != [], "B's own join event is in his initial sync (state or timeline)"
      for ev <- join_in_fresh, do: assert_triple(ev, invite_row.event_id, invite_content, a.uid)

      a_body = sync(a, token_a)
      assert_triple(member_ev(join_events(a_body, dm), b.uid, "join"), invite_row.event_id, invite_content, a.uid)
    end

    test "full_state=true: the synthesized join state of B carries the predecessor of the REAL join event", %{a: a, b: b} do
      anchor_b = anchor_room!(b)
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)
      token_b = snapshot!(b, anchor_b)
      [invite_row, join_row] = member_events(dm, b.uid)

      body = sync(b, token_b, full_state: true)

      own = Enum.filter(join_state(body, dm), &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert [%{"event_id" => id} = ev] = own
      assert id == join_row.event_id, "the state entry anchors on the persisted join identity"
      assert_triple(ev, invite_row.event_id, %{"membership" => "invite", "is_direct" => true}, a.uid)
    end

    test "the DM under history_visibility invited is conformant (AC7 (c)): the join's predecessor is the invite the invitee may see", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)

      assert only(dm, "m.room.history_visibility") == %{"history_visibility" => "invited"}
      assert [invite_row, join_row] = member_events(dm, b.uid)
      conn = T.matrix_request(:get, path(dm, "event/#{enc(join_row.event_id)}"), b.at)
      assert conn.status == 200

      assert_triple(T.json(conn), invite_row.event_id, %{"membership" => "invite", "is_direct" => true}, a.uid, age: false)
    end
  end

  # ═══ AC4 (b)-(d), (i): leave, re-invite, decline, revocation ════════════════════════

  describe "AC4 (b) - leave" do
    test "B leaves: his rooms.leave timeline has the leave with prev_content {membership: join}, prev_sender B, replaces_state = his join id = the partition's previous; a message keeps unsigned [age]", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      in_window = marker("window")
      say!(a, room, in_window)
      leave!(b, room)

      body = sync(b, token)
      events = leave_timeline(body, room)
      leave_ev = member_ev(events, b.uid, "leave")
      assert [_invite, join_row, _leave_row] = member_events(room, b.uid)

      assert {:ok, %{^room => [latest, previous]}} = DB.latest_member_events([room], b.uid)
      assert leave_ev["event_id"] == latest.event_id
      assert previous.event_id == join_row.event_id, "the partition's P"
      assert_triple(leave_ev, previous.event_id, %{"membership" => "join"}, b.uid)

      message = Enum.find(events, &(&1["type"] == "m.room.message" and &1["content"]["body"] == in_window))
      assert message, "control: A's message is in the window"
      assert Map.keys(message["unsigned"]) == ["age"], "a message never carries the predecessor keys"
    end
  end

  describe "AC4 (c) - re-invite" do
    test "A re-invites B after he left: B's invite_state stays four keys; A's timeline shows the invite with prev_content {membership: leave}, prev_sender B", %{a: a, b: b} do
      anchor_a = anchor_room!(a)
      room = room_with!(a, [b])
      leave!(b, room)
      token_a = snapshot!(a, anchor_a)

      invite!(a, room, b)

      assert [_invite1, _join, leave_row, invite2] = member_events(room, b.uid)
      a_body = sync(a, token_a)
      assert_triple(member_ev(join_events(a_body, room), b.uid, "invite"), leave_row.event_id, %{"membership" => "leave"}, b.uid)
      assert invite2.sender == a.uid

      stripped_keys_ok!(invite_events(sync(b), room))
    end
  end

  describe "AC4 (d) - decline of a DM invitation" do
    test "B declines: A's view and B's rooms.leave carry the invite content with is_direct and prev_sender A", %{a: a, b: b} do
      anchor_a = anchor_room!(a)
      anchor_b = anchor_room!(b)
      token_a = snapshot!(a, anchor_a)
      token_b = snapshot!(b, anchor_b)
      dm = make_room(a, element_dm(b.uid))
      tick()
      assert leave(b, dm).status == 200
      assert [invite_row, decline_row] = member_events(dm, b.uid)
      assert decline_row.content == %{"membership" => "leave"} and decline_row.sender == b.uid
      invite_content = %{"membership" => "invite", "is_direct" => true}

      a_body = sync(a, token_a)
      assert_triple(member_ev(join_events(a_body, dm), b.uid, "leave"), invite_row.event_id, invite_content, a.uid)

      b_body = sync(b, token_b)
      assert in_section?(b_body, "leave", dm), "control: B's declined invitation is a rooms.leave entry"
      assert [leave_ev] = leave_timeline(b_body, dm)
      assert_triple(leave_ev, invite_row.event_id, invite_content, a.uid)
    end
  end

  describe "AC4 (i) / D5 - revocation and re-join after a kick" do
    test "A invites C, then a leave by A (revocation, sender != state_key): the leave carries prev_content {membership: invite}, prev_sender A", %{a: a, c: c} do
      anchor_a = anchor_room!(a)
      room = make_room(a, %{"preset" => "private_chat"})
      token_a = snapshot!(a, anchor_a)
      invite!(a, room, c)
      tick()
      revoke_id = write_member_event!(room, c.uid, "leave", a.uid)
      assert [invite_row, _revoke_row] = member_events(room, c.uid)

      a_body = sync(a, token_a)

      revoke = event_with_id(join_events(a_body, room), revoke_id)
      assert revoke["sender"] == a.uid and revoke["sender"] != revoke["state_key"], "a revocation, not a self-leave"
      assert_triple(revoke, invite_row.event_id, %{"membership" => "invite"}, a.uid)
    end

    test "B is kicked by A and joins again (public room): the re-join carries the kick's content and the KICKER as prev_sender", %{a: a, b: b} do
      anchor_a = anchor_room!(a)
      room = make_room(a, %{"preset" => "public_chat"})
      join!(b, room)
      tick()
      moderate(:kick, room, a, b)
      token_a = snapshot!(a, anchor_a)
      join!(b, room)
      assert [_join1, kick_row, _join2] = member_events(room, b.uid)
      assert kick_row.sender == a.uid

      a_body = sync(a, token_a)
      rejoin = member_ev(join_events(a_body, room), b.uid, "join")
      assert_triple(rejoin, kick_row.event_id, kick_row.content, a.uid)
    end
  end

  # ═══ AC4 (e): generic state ═════════════════════════════════════════════════════

  describe "AC4 (e) - generic state" do
    test "the second topic carries the first topic's content and sender (initial state, incremental timeline); the first topic, m.room.create and a message carry none", %{a: a} do
      anchor_a = anchor_room!(a)
      room = make_room(a, %{"preset" => "private_chat"})
      token_a = snapshot!(a, anchor_a)
      first_text = marker("first")
      second_text = marker("second")
      first = topic!(a, room, first_text)
      second = topic!(a, room, second_text)
      msg = say!(a, room, marker("plain"))

      delta = sync(a, token_a)
      timeline = join_timeline(delta, room)
      refute_triple(event_with_id(timeline, first))
      assert_triple(event_with_id(timeline, second), first, %{"topic" => first_text}, a.uid)
      refute_triple(event_with_id(timeline, msg))

      # an initial sync: pad the room so that the topic leaves the 20-event timeline window and lands in `state`
      for n <- 1..22, do: say!(a, room, "pad #{n}")
      initial = sync(a)
      state = join_state(initial, room)
      assert Enum.any?(state, &(&1["event_id"] == second)), "control: the current topic is in the state block"
      assert_triple(event_with_id(state, second), first, %{"topic" => first_text}, a.uid)
      refute_triple(Enum.find(state, &(&1["type"] == "m.room.create")))
    end
  end

  # ═══ AC4 (f): the oracle ════════════════════════════════════════════════════════

  # the D3 key, written independently of the production SQL fragments: (origin_server_ts, r, event_id) with r = 4 - rank(membership) for
  # m.room.member (ban 0 < leave 1 < invite 2 < knock 3 < join 4, anything else = leave) and 0 for every other type
  defp d3_rank(type, content) do
    if type == "m.room.member" do
      membership =
        case safe_content(content) do
          %{"membership" => m} -> m
          _ -> nil
        end

      4 - Map.get(%{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}, membership, 1)
    else
      0
    end
  end

  defp oracle_predecessor(event_id) do
    [[room, type, key, ts, content]] = T.sql!("SELECT room_id, event_type, state_key, origin_server_ts, content FROM events WHERE event_id = $1", [event_id]).rows
    own = {ts, d3_rank(type, content), event_id}

    T.sql!("SELECT event_id, origin_server_ts, content, sender FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3", [room, type, key]).rows
    |> Enum.map(fn [id, t, c, sender] -> {{t, d3_rank(type, c), id}, %{event_id: id, content: safe_content(c), sender: sender}} end)
    |> Enum.filter(fn {k, _} -> k < own end)
    |> Enum.max_by(fn {k, _} -> k end, fn -> nil end)
    |> case do
      nil -> nil
      {_k, pred} -> pred
    end
  end

  defp safe_content(c) do
    content_of(c)
  rescue
    _ -> %{}
  end

  describe "AC4 (f) - the oracle" do
    test "every state event of every room of A's initial sync has the three keys iff the independent D3 oracle finds a predecessor, and then they equal its id / content / sender", %{a: a, b: b, c: c} do
      room1 = room_with!(a, [b])
      topic!(a, room1, marker("t1"))
      topic!(a, room1, marker("t2"))
      put_state!(a, room1, "m.room.name", %{"name" => marker("n1")})
      put_state!(a, room1, "m.room.name", %{"name" => marker("n2")})
      leave!(b, room1)
      tick()
      invite!(a, room1, b)
      join!(b, room1)
      dm = make_room(a, element_dm(c.uid))
      join!(c, dm)
      _plain = make_room(a, %{})
      say!(a, room1, marker("closing"))

      body = sync(a)

      checked =
        for {room, _entry} <- joined(body), ev <- join_events(body, room), ev["event_id"] not in [nil, ""] do
          if Map.has_key?(ev, "state_key") do
            case oracle_predecessor(ev["event_id"]) do
              nil ->
                refute_triple(ev)
                :none

              pred ->
                assert_triple(ev, pred.event_id, pred.content, pred.sender)
                :with_predecessor
            end
          else
            refute_triple(ev)
            :non_state
          end
        end

      assert length(checked) >= 12, "the scenario delivers a real set of events, got #{length(checked)}"
      assert Enum.count(checked, &(&1 == :with_predecessor)) >= 4, "control: several state events HAVE a predecessor (topic, name, B's rejoin, C's join)"
      assert Enum.count(checked, &(&1 == :none)) >= 2, "control: several state events have none (create, the first writes)"
      assert Enum.count(checked, &(&1 == :non_state)) >= 1
    end
  end

  # ═══ AC4 (g): stripped state ═══════════════════════════════════════════════════

  describe "AC4 (g) - stripped state never carries unsigned" do
    test "B left and was re-invited: every event of his invite_state (also his own invite, whose source row HAS a predecessor) has exactly four keys", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat", "topic" => marker("stripped-topic")})
      invite!(a, room, b)
      join!(b, room)
      leave!(b, room)
      tick()
      invite!(a, room, b)
      assert [_invite1, _join, leave_row, invite2] = member_events(room, b.uid)
      assert leave_row.content == %{"membership" => "leave"}, "control: the source row of B's own invite event has a predecessor"
      assert invite2.sender == a.uid

      body = sync(b)

      assert in_section?(body, "invite", room)
      events = invite_events(body, room)
      stripped_keys_ok!(events)
      own = member_ev(events, b.uid, "invite")
      assert own["sender"] == a.uid, "control: B's own invite event is among them"
    end
  end

  # ═══ AC4 (h): two events of one slot in one leave window ═══════════════════════════

  describe "AC4 (h) - rooms.leave: the predecessors of one response come from ONE batch" do
    test "A changes the topic twice inside B's leave window: the second's predecessor is the first (same response), the first's the earlier topic", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      before_text = marker("before")
      first_text = marker("first")
      second_text = marker("second")
      before_id = topic!(a, room, before_text)
      token = snapshot!(b, anchor)
      first = topic!(a, room, first_text)
      second = topic!(a, room, second_text)
      leave!(b, room)

      body = sync(b, token)

      events = leave_timeline(body, room)
      assert_triple(event_with_id(events, second), first, %{"topic" => first_text}, a.uid)
      assert_triple(event_with_id(events, first), before_id, %{"topic" => before_text}, a.uid)
    end
  end

  # ═══ AC5: /messages and /event ═════════════════════════════════════════════════

  describe "AC5 - /messages and /event/{id}" do
    test "B's join (DM) and the second topic carry unsigned == exactly the three keys (no age); the invite, the first topic and messages carry no unsigned", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)
      assert [invite_row, join_row] = member_events(dm, b.uid)
      first_text = marker("first")
      first = topic!(a, dm, first_text)
      second = topic!(a, dm, marker("second"))
      msg = say!(a, dm, marker("plain"))
      invite_content = %{"membership" => "invite", "is_direct" => true}

      messages = T.matrix_request(:get, path(dm, "messages") <> "?dir=b&limit=100", a.at)
      assert messages.status == 200
      chunk = T.json(messages)["chunk"]

      assert_triple(event_with_id(chunk, join_row.event_id), invite_row.event_id, invite_content, a.uid, age: false)
      assert_triple(event_with_id(chunk, second), first, %{"topic" => first_text}, a.uid, age: false)
      refute Map.has_key?(event_with_id(chunk, first), "unsigned"), "the first topic has no predecessor: no unsigned (as today)"
      refute Map.has_key?(event_with_id(chunk, invite_row.event_id), "unsigned"), "the invite is the first event of its slot: no unsigned"
      refute Map.has_key?(event_with_id(chunk, msg), "unsigned"), "a message has no unsigned on /messages (follow-up fl (b))"

      for {id, expected} <- [{join_row.event_id, {invite_row.event_id, invite_content, a.uid}}, {second, {first, %{"topic" => first_text}, a.uid}}] do
        conn = T.matrix_request(:get, path(dm, "event/#{enc(id)}"), b.at)
        assert conn.status == 200
        {replaces, content, sender} = expected
        assert_triple(T.json(conn), replaces, content, sender, age: false)
      end

      for id <- [first, msg] do
        conn = T.matrix_request(:get, path(dm, "event/#{enc(id)}"), b.at)
        assert conn.status == 200
        refute Map.has_key?(T.json(conn), "unsigned")
      end
    end
  end

  describe "D1 / D11 - /members, /initialSync, /relations" do
    # story membership-state-model (DELIBERATE re-pin, AC15 (b); old -> new): `fl` (c) is closed. The `/members` and `/initialSync` state events now CARRY the three
    # predecessor keys (and `unsigned.age`) where a predecessor exists (this DM: B's join has the invite as predecessor, the second topic the first) and
    # `/members` runs exactly ONE predecessor statement (was: none, zero statements) and `/initialSync` one for its `state` plus the one of its `messages.chunk` page
    # (was: at most the one of the page). The events without a predecessor (A's join) carry `unsigned.age` only.
    test "/members and /initialSync: their state events CARRY the three keys where a predecessor exists; /members runs ONE predecessor statement, /initialSync one more than before", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)
      assert [invite_row, _join_row] = member_events(dm, b.uid)
      first_text = marker("first")
      first = topic!(a, dm, first_text)
      topic!(a, dm, marker("second"))
      invite_content = %{"membership" => "invite", "is_direct" => true}

      {members, member_statements} = count_statements(fn -> T.matrix_request(:get, path(dm, "members"), a.at) end, [dm])
      {initial, initial_statements} = count_statements(fn -> T.matrix_request(:get, path(dm, "initialSync"), a.at) end, [dm])

      assert members.status == 200 and initial.status == 200
      member_chunk = T.json(members)["chunk"]
      b_slot = Enum.find(member_chunk, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert_triple(b_slot, invite_row.event_id, invite_content, a.uid)
      a_slot = Enum.find(member_chunk, &(&1["type"] == "m.room.member" and &1["state_key"] == a.uid))
      refute_triple(a_slot)
      assert Map.keys(a_slot["unsigned"]) == ["age"], "A's join has no predecessor: age only"

      state = get_in(T.json(initial), ["state"]) || []
      assert_triple(Enum.find(state, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid)), invite_row.event_id, invite_content, a.uid)
      topic_slot = Enum.find(state, &(&1["type"] == "m.room.topic"))
      assert_triple(topic_slot, first, %{"topic" => first_text}, a.uid)

      assert marker_count(member_statements) == 1, "/members runs ONE predecessor statement for its slots, got #{marker_count(member_statements)}"
      assert marker_count(initial_statements) == 2, "/initialSync: one statement for its state, one for its messages.chunk page, got #{marker_count(initial_statements)}"
    end

    test "/relations: a thread reply is listed and no entry of the response carries the three keys", %{a: a} do
      room = make_room(a, %{"preset" => "private_chat"})
      root = say!(a, room, marker("root"))
      reply = T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), a.at, body: %{"msgtype" => "m.text", "body" => marker("reply"), "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root}})
      assert reply.status == 200
      reply_id = T.json(reply)["event_id"]

      conn = T.matrix_request(:get, "/_matrix/client/v1/rooms/#{enc(room)}/relations/#{enc(root)}/m.thread", a.at)

      assert conn.status == 200, "relations: #{conn.status} #{conn.resp_body}"
      chunk = T.json(conn)["chunk"]
      assert event_with_id(chunk, reply_id), "control: the thread reply is listed"
      for ev <- chunk, do: refute_triple(ev)
    end
  end

  # ═══ AC2 (b): the stamps over the real database ════════════════════════════════════

  # a member event of `user` (any membership: the content says) 1500 ms AHEAD of the clock, in a room the test owns; the room's events are deleted
  # afterwards (follow-up fj). The lead is large so that the HTTP request that follows is far inside it even on a loaded CI box.
  defp write_ahead_member_event!(room, sender, user, content) do
    ts = System.system_time(:millisecond) + 1_500
    id = "$future" <> T.rand(8)

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => sender,
               "type" => "m.room.member",
               "state_key" => user,
               "content" => content,
               "origin_server_ts" => ts
             })

    on_exit(fn -> T.privileged_sql!("DELETE FROM events WHERE room_id = $1", [room]) end)
    %{event_id: id, ts: ts}
  end

  # D4: strictly newer than the event it follows, and never further ahead than `max(clock, latest + 1)`. The EXACT `latest + 1` is pinned in the
  # unit suite (server_member_stamp_test.exs, a +60 s fake): over HTTP a slow box may let the clock pass `latest + 1` before the write.
  defp assert_stamped_after!(row, ahead, what) do
    assert row.ts > ahead.ts, "#{what}: #{row.ts} must be newer than the event it follows (#{ahead.ts})"
    assert row.ts <= max(System.system_time(:millisecond), ahead.ts + 1), "#{what}: #{row.ts} is stamped max(now, latest + 1), not further ahead (#{ahead.ts})"
  end

  describe "AC2 (b) - member stamps strictly increase (D4)" do
    test "createRoom DM invite [B], then B joins IMMEDIATELY (no tick): the join is newer than the invite, B reads join, its predecessor is the invite", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))

      conn = join(b, dm)
      assert conn.status == 200, "join: #{conn.status} #{conn.resp_body}"

      assert [invite_row, join_row] = member_events(dm, b.uid)
      assert join_row.ts > invite_row.ts, "the join (#{join_row.ts}) must be newer than the invite (#{invite_row.ts}) although no tick separated them"
      assert {:ok, "join"} = DB.get_member_membership(dm, b.uid)

      event = T.matrix_request(:get, path(dm, "event/#{enc(join_row.event_id)}"), b.at)
      assert event.status == 200
      assert_triple(T.json(event), invite_row.event_id, %{"membership" => "invite", "is_direct" => true}, a.uid, age: false)
    end

    test "the invite is 1500 ms AHEAD and B joins at once: the join is stamped just after it, reads join, its predecessor is that invite", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      invite_content = %{"membership" => "invite", "is_direct" => true}
      future = write_ahead_member_event!(room, a.uid, b.uid, invite_content)

      conn = join(b, room)
      assert conn.status == 200, "join: #{conn.status} #{conn.resp_body}"

      join_row = member_events(room, b.uid) |> Enum.find(&(&1.content["membership"] == "join"))
      assert join_row, "B's join event exists"
      assert_stamped_after!(join_row, future, "D4 (a) join")
      assert {:ok, "join"} = DB.get_member_membership(room, b.uid), "the join is the latest membership (an older-than-invite join would read invite)"

      event = T.matrix_request(:get, path(room, "event/#{enc(join_row.event_id)}"), b.at)
      assert event.status == 200
      assert_triple(T.json(event), future.event_id, invite_content, a.uid, age: false)
    end

    test "a decline right after a createRoom invitation (no tick) is newer than the invite and carries the invite as its predecessor", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))

      conn = leave(b, dm)
      assert conn.status == 200, "decline: #{conn.status} #{conn.resp_body}"

      assert [invite_row, decline_row] = member_events(dm, b.uid)
      assert decline_row.ts > invite_row.ts, "the decline (#{decline_row.ts}) must be newer than the invite (#{invite_row.ts})"

      event = T.matrix_request(:get, path(dm, "event/#{enc(decline_row.event_id)}"), a.at)
      assert event.status == 200
      assert_triple(T.json(event), invite_row.event_id, %{"membership" => "invite", "is_direct" => true}, a.uid, age: false)
    end

    test "the invite is 1500 ms AHEAD and B declines at once: the decline is stamped just after it and carries it as predecessor", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      future = write_ahead_member_event!(room, a.uid, b.uid, %{"membership" => "invite"})

      conn = leave(b, room)
      assert conn.status == 200, "decline: #{conn.status} #{conn.resp_body}"

      decline_row = member_events(room, b.uid) |> Enum.find(&(&1.content["membership"] == "leave"))
      assert decline_row, "B's decline event exists"
      assert_stamped_after!(decline_row, future, "D4 (c) decline")
      assert {:ok, "leave"} = DB.get_member_membership(room, b.uid)

      event = T.matrix_request(:get, path(room, "event/#{enc(decline_row.event_id)}"), a.at)
      assert_triple(T.json(event), future.event_id, %{"membership" => "invite"}, a.uid, age: false)
    end

    test "B leaves a room whose latest member event of his is ahead of the clock: the leave is stamped just after it and is the latest membership", %{a: a, b: b} do
      room = room_with!(a, [b])
      future = write_ahead_member_event!(room, b.uid, b.uid, %{"membership" => "join"})

      conn = leave(b, room)
      assert conn.status == 200, "leave: #{conn.status} #{conn.resp_body}"

      leave_row = member_events(room, b.uid) |> Enum.find(&(&1.content["membership"] == "leave"))
      assert leave_row, "B's leave event exists"
      assert_stamped_after!(leave_row, future, "D4 (b) leave")
      assert {:ok, "leave"} = DB.get_member_membership(room, b.uid)
    end
  end

  # ═══ AC6: statement counts ═════════════════════════════════════════════════════

  describe "AC6 (a) - the rooms.leave section runs ONE predecessor statement per response" do
    for {label, n} <- [{"1 new leave entry", 1}, {"5 new leave entries", 5}] do
      test "#{label}: the predecessor statement runs exactly once; an empty leave section runs it zero times", %{a: a, b: b} do
        n = unquote(n)
        anchor = anchor_room!(b)
        rooms = for _ <- 1..n, do: room_with!(a, [b])
        token = snapshot!(b, anchor)
        for room <- rooms, do: leave!(b, room)

        {body, statements} = count_statements(fn -> sync(b, token) end)

        for room <- rooms do
          assert in_section?(body, "leave", room), "control: #{room} is a leave entry"
          leave_ev = member_ev(leave_timeline(body, room), b.uid, "leave")
          assert_triple(leave_ev, member_events(room, b.uid) |> Enum.at(1) |> Map.fetch!(:event_id), %{"membership" => "join"}, b.uid)
        end

        assert marker_count(statements) == 1, "ONE batched predecessor statement for #{n} leave entries, got #{marker_count(statements)}"

        {empty, none} = count_statements(fn -> sync(b, next(body)) end)
        assert Map.keys(section(empty, "leave")) == [], "control: no leave entry any more"
        assert marker_count(none) == 0, "no leave entry, no predecessor statement"
      end
    end
  end

  describe "AC6 (b) / (c) - statement counts" do
    test "an initial sync (3 joined rooms) runs EXACTLY the statements it ran before; two identical syncs run the same count", %{a: a, b: b} do
      anchor = anchor_room!(b)
      r1 = room_with!(a, [b])
      r2 = room_with!(a, [b])
      topic!(a, r1, marker("t1"))
      topic!(a, r1, marker("t2"))
      topic!(a, r2, marker("t3"))
      tick()
      say!(b, anchor, marker("last"))
      _warm = sync(b)

      {body, statements} = count_statements(fn -> sync(b) end, [anchor, r1, r2])
      {_body2, statements2} = count_statements(fn -> sync(b) end, [anchor, r1, r2])

      assert Map.keys(joined(body)) |> Enum.sort() == Enum.sort([anchor, r1, r2]), "control: 3 joined rooms"
      assert length(statements) == length(statements2), "calibration: two identical initial syncs run the same statements, so the count is not noise\n#{listing(statements)}\n--\n#{listing(statements2)}"

      # the recorded baseline, computed on the code before the story (HEAD 54ecc9ed): the statements of one initial sync of this user (his
      # session / token / user reads, the partition reads, and per joined room the member, state and timeline reads); `noise?/1` drops what
      # other suites of the run switch on (audit log, log store)
      assert length(statements) == @baseline_initial_sync_statements,
             "the statement count of an initial sync (3 rooms) is the pinned count (code before the story: 54, re-pinned by story sync-token-per-device to 57 and by story sync-stream-position to 59): #{@baseline_initial_sync_statements}, got #{length(statements)}\n#{listing(statements)}"

      # control (red before the story: the statement does not exist yet): the widened lookup runs, once per room and block
      assert marker_count(statements) >= 3, "control: the predecessor lookup must run for the 3 rooms, got #{marker_count(statements)}"
    end

    test "POST /join runs EXACTLY the statements it ran before; two identical joins into fresh rooms run the same count", %{a: a, b: b, c: c} do
      room1 = make_room(a, %{"preset" => "private_chat"})
      room2 = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room1, b)
      invite!(a, room2, c)
      # the FIRST authenticated request of a user does bookkeeping (profile / session reads) that is not part of the join: warm both users up
      assert T.whoami(b.at).status == 200
      assert T.whoami(c.at).status == 200
      tick()

      {conn1, statements1} = count_statements(fn -> join(b, room1) end, [room1])
      tick()
      {conn2, statements2} = count_statements(fn -> join(c, room2) end, [room2])

      assert conn1.status == 200 and conn2.status == 200
      assert length(statements1) == length(statements2), "calibration: two identical joins run the same statements, so the count is not noise\n#{listing(statements1)}\n--\n#{listing(statements2)}"

      # the recorded baseline (HEAD 54ecc9ed), one join of a warmed-up pending invitee, exactly these 11 statements: (1) the session lookup,
      # (2) the session-still-valid check, (3) the decision's ban read (get_member_membership), (4) the join rule state, (5) the pending invitation,
      # (6) the latest member events of the invitee, (7) Room.Server's ban read (get_member_membership; after the story ONE latest_member_event read
      # that also yields the stamp), (8) INSERT room_members, (9) INSERT the join event, (10) DELETE forgotten_rooms, (11) UPDATE the invitation
      # (accepted). `noise?/1` drops what other suites of the run switch on (audit_log with its begin / commit, the log store).
      assert length(statements1) == @baseline_join_statements,
             "the statement count of a join is the baseline of the code before the story: #{@baseline_join_statements}, got #{length(statements1)}\n#{listing(statements1)}"
    end
  end

  # ═══ AC7: visibility (D8) ═══════════════════════════════════════════════════════

  describe "AC7 - history visibility (D8)" do
    test "history_visibility SHARED (set explicitly): a topic change BEFORE C joins: C's initial sync carries the three keys of the current topic (spec-allowed)", %{a: a, c: c} do
      room = make_room(a, %{"preset" => "private_chat"})
      put_state!(a, room, "m.room.history_visibility", %{"history_visibility" => "shared"})
      old_text = marker("old")
      old = topic!(a, room, old_text)
      current = topic!(a, room, marker("current"))
      invite!(a, room, c)
      join!(c, room)

      body = sync(c)

      topics = Enum.filter(join_events(body, room), &(&1["event_id"] == current))
      assert topics != [], "control: the current topic is delivered to C"
      for ev <- topics, do: assert_triple(ev, old, %{"topic" => old_text}, a.uid)
    end

    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (b); old -> new): was "history_visibility JOINED, pins known deviation es: C still gets prev_content AND
    # /messages returns the old topic (MUST flip when es ships)"; `es` ships now (D10): the predecessor of the current topic lies before C's join and is invisible to him, so the
    # three keys are omitted and the old topic is not in /messages. The assertions are the INVERSE of the old ones (control kept: the current topic is delivered).
    test "history_visibility JOINED (es enforced): C gets no prev_content and /messages does not return the old topic", %{a: a, c: c} do
      room = make_room(a, %{"preset" => "private_chat"})
      put_state!(a, room, "m.room.history_visibility", %{"history_visibility" => "joined"})
      old_text = marker("old-hidden")
      old = topic!(a, room, old_text)
      current = topic!(a, room, marker("current"))
      invite!(a, room, c)
      join!(c, room)

      body = sync(c)
      topics = Enum.filter(join_events(body, room), &(&1["event_id"] == current))
      assert topics != [], "control: the current topic is delivered to C (the current state is not gated, D11 (a))"

      # `es` (D10): the predecessor is invisible to C, so NONE of the three keys is delivered
      for ev <- topics, do: assert(Map.take(ev["unsigned"] || %{}, @triple) == %{}, "no predecessor key of the current topic: #{inspect(ev["unsigned"])}")
      refute String.contains?(Jason.encode!(body), old_text), "the old topic text is nowhere in C's sync"

      messages = T.matrix_request(:get, path(room, "messages") <> "?dir=b&limit=100", c.at)
      assert messages.status == 200
      refute event_with_id(T.json(messages)["chunk"], old), "es enforced: /messages no longer returns the pre-join topic to C"
      refute String.contains?(messages.resp_body, old_text)
    end

    test "a user who is NOT a member gets 403 from /messages and the room is not in his /sync: nothing new reaches a non-member", %{a: a, d: d} do
      room = make_room(a, %{"preset" => "private_chat"})
      secret = marker("secret-topic")
      topic!(a, room, secret)
      topic!(a, room, marker("secret-topic-2"))

      forbidden = T.matrix_request(:get, path(room, "messages") <> "?dir=b&limit=50", d.at)
      assert forbidden.status == 403
      assert T.json(forbidden)["errcode"] == "M_FORBIDDEN"
      d_body = sync(d)
      refute in_section?(d_body, "join", room) or in_section?(d_body, "invite", room) or in_section?(d_body, "leave", room)
      refute Jason.encode!(d_body) =~ secret
      assert in_section?(sync(a), "join", room), "positive control: A's sync has the room"
    end
  end
end
