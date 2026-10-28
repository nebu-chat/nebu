defmodule Nebu.Matrix.SyncMembershipPartitionHttpTest do
  @moduledoc """
  Story `sync-membership-partition` (epic oauth-broker, follow-ups `ev` + `ez`), HTTP half: `GET /_matrix/client/v3/sync` over the real
  stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg, users and sessions as in
  `create_room_invites_http_test.exs`, random localparts, `:server_name` pinned). What only the real stack decides and this file pins:
  the wire shape of `rooms.invite` / `rooms.leave`, the stripped `invite_state` produced by the REAL SQL, the leave window bounded at the
  real leave / kick / ban event, the long-poll wake-ups through the real writers, ignored users (the real `AccountDataStore`), `full_state`,
  the 503 body, the forget / re-invite interplay (D7), the join decision for a taken-back invitation (D13) and the Element DM flow.

  Conventions (as the sibling suites):

    * `T` is `Nebu.OAuth.TestSupport`; ban / kick / unban / Admin removal have no HTTP route: they are driven through
      `Nebu.Matrix.EventDispatcher.Server` / `Nebu.Matrix.admin_remove_room_member/3` with the real Room.Server / Postgres.
    * `m.room.member` events carry a millisecond clock: `tick/0` separates writes whose ORDER matters (the incremental sync reads
      `origin_server_ts > anchor`, the latest membership is read by timestamp). A deliberate same-millisecond tie is written with explicit
      timestamps through `Room.DB.insert_event/1` / `T.privileged_sql!/2`.
    * Every negative assertion ("the room is in no section", "A's message appears nowhere") has a POSITIVE control in the same test (the
      section / the message DID arrive earlier) and the raw response body is searched for random markers: no short substrings.
    * The anchor of a user's sync token is the newest event the user's previous response delivered: `snapshot!/2` makes the user's own anchor
      room the newest thing before the token is taken, so every later event of the scenario is NEW (events in the same millisecond as the
      anchor are skipped by the timestamp anchor, follow-up `fc`).
    * Long-poll tests start the sync in a `Task` and wait (bounded poll) until its process joined the user's `:pg` group; no fixed sleeps.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.InviteDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"

  # a rooms DB module whose candidates read fails and that delegates everything else to the real one
  defmodule FailingCandidatesDB do
    for {name, arity} <- Nebu.Matrix.Room.DB.__info__(:functions), {name, arity} != {:membership_candidates, 1} do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Nebu.Matrix.Room.DB, unquote(name), [unquote_splicing(args)])
    end

    def membership_candidates(_user_id), do: {:error, :simulated}
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)

    {:ok, a: user!("SMA"), b: user!("SMB"), c: user!("SMC"), d: user!("SMD")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp enc(room_id), do: URI.encode_www_form(room_id)
  defp path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"
  defp marker(label), do: "#{label}-#{T.rand(8)}"

  # Waits until the millisecond clock is PAST the newest event of the last seconds (test review m4): createRoom stamps its chain (and the
  # invite events, which become the invitee's anchor) max(now, previous + 1), i.e. up to several ms AHEAD of the clock (follow-up eu F-4),
  # and the incremental sync reads `origin_server_ts > anchor`: an event stamped with the plain clock right after such a response could be
  # older than the anchor and never be delivered. A 1 ms tick is not enough; this is the smallest wait that makes the scenarios deterministic.
  defp tick do
    horizon = System.system_time(:millisecond) - 10_000
    newest = T.sql!("SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE origin_server_ts > $1", [horizon]).rows |> hd() |> hd()
    :ok = wait_until(fn -> System.system_time(:millisecond) > newest end, 300)
  end

  # an explicit timestamp strictly newer than everything in the room (and than the clock)
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

  defp create(user, body), do: T.matrix_request(:post, @create, user.at, body: body)

  defp make_room(user, body) do
    conn = create(user, body)
    assert conn.status == 200, "createRoom #{inspect(body)}: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  defp leave(user, room), do: T.matrix_request(:post, path(room, "leave"), user.at)
  defp forget(user, room), do: T.matrix_request(:post, path(room, "forget"), user.at, body: %{})
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

  defp send_message(user, room, body) do
    T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: %{"msgtype" => "m.text", "body" => body})
  end

  defp say!(user, room, body) do
    c = send_message(user, room, body)
    assert c.status == 200, "send: #{c.status} #{c.resp_body}"
    T.json(c)["event_id"]
  end

  # ban / unban / kick: no HTTP route, the dispatcher with the caller's identity (real Room.Server / Postgres)
  defp moderate(:ban, room, caller, target) do
    req = %Core.BanUserRequest{room_id: room, target_id: target.uid, reason: ""}
    assert %Core.BanUserResponse{} = Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(caller.uid))
  end

  defp moderate(:unban, room, caller, target) do
    req = %Core.UnbanUserRequest{room_id: room, target_id: target.uid}
    assert %Core.UnbanUserResponse{} = Nebu.Matrix.EventDispatcher.Server.unban_user(req, Nebu.Matrix.Http.stream(caller.uid))
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

  defp latest_member_event(room_id, uid), do: room_id |> member_events(uid) |> List.last()

  defp only(room_id, type) do
    rows = T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = ''", [room_id, type]).rows
    assert [[content]] = rows, "exactly one #{type} event expected"
    content_of(content)
  end

  defp invitation(room_id, uid) do
    case T.sql!("SELECT accepted_at, rejected_at, invited_at, inviter_id FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room_id, uid]).rows do
      [] -> nil
      [[nil, nil, at, inviter]] -> %{state: :pending, invited_at: at, inviter: inviter}
      [[_accepted, nil, at, inviter]] -> %{state: :accepted, invited_at: at, inviter: inviter}
      [[nil, _rejected, at, inviter]] -> %{state: :rejected, invited_at: at, inviter: inviter}
    end
  end

  defp forgotten_rows(uid, room), do: T.sql!("SELECT count(*) FROM forgotten_rooms WHERE user_id = $1 AND room_id = $2", [uid, room]).rows |> hd() |> hd()

  # a member event written WITHOUT touching the invitation row / the member set (the failed-reject and half-state cases)
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

  # Element's exact DM body
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

  # `sync(user)` = initial (timeout 0); `sync(user, token)` = incremental, timeout 0; extra query params as a keyword list
  defp sync(user, since \\ nil, params \\ []) do
    conn = sync_conn(user, [since: since, timeout: Keyword.get(params, :timeout, 0)] ++ Keyword.delete(params, :timeout))
    assert conn.status == 200, "sync: #{conn.status} #{conn.resp_body}"
    T.json(conn)
  end

  defp timed_sync(user, since, params) do
    started = System.monotonic_time(:millisecond)
    body = sync(user, since, params)
    {body, System.monotonic_time(:millisecond) - started}
  end

  defp section(body, name), do: get_in(body, ["rooms", name]) || %{}
  defp joined(body), do: section(body, "join")
  defp invited(body), do: section(body, "invite")
  defp left(body), do: section(body, "leave")
  defp in_section?(body, name, room), do: Map.has_key?(section(body, name), room)
  defp nowhere?(body, room), do: not (in_section?(body, "join", room) or in_section?(body, "invite", room) or in_section?(body, "leave", room))
  defp next(body), do: body["next_batch"]

  # the stripped events of an invitation as {type, state_key} pairs, and their decoded form
  defp invite_events(body, room), do: get_in(body, ["rooms", "invite", room, "invite_state", "events"]) || []
  defp leave_timeline(body, room), do: get_in(body, ["rooms", "leave", room, "timeline", "events"]) || []
  defp join_timeline(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "events"]) || []
  defp bodies(events), do: for(ev <- events, ev["type"] == "m.room.message", do: ev["content"]["body"])
  defp event_ids(events), do: Enum.map(events, & &1["event_id"])

  # the user's own anchor room: its newest message is the anchor of the first token
  defp anchor_room!(user), do: make_room(user, %{})

  defp snapshot!(user, anchor) do
    tick()
    say!(user, anchor, marker("anchor"))
    body = sync(user)
    tick()
    next(body)
  end

  # a private room with `members` joined through invite + join
  defp room_with!(owner, members, body \\ %{}) do
    room = make_room(owner, Map.merge(%{"preset" => "private_chat"}, body))

    for m <- members do
      invite!(owner, room, m)
      join!(m, room)
    end

    room
  end

  # the fake-free "the sync is long-polling" signal: the sync process joined the user's :pg group
  defp wait_polling(user), do: assert(:ok = wait_until(fn -> :pg.get_local_members("user:#{user.uid}") != [] end, 3_000), "the sync never started polling")

  # the four ways a member ends up out of a room
  defp remove!(:leave, room, _a, b), do: assert(leave(b, room).status == 200)
  defp remove!(:kick, room, a, b), do: moderate(:kick, room, a, b)
  defp remove!(:ban, room, a, b), do: moderate(:ban, room, a, b)
  defp remove!(:admin, room, a, b), do: assert(:ok = Nebu.Matrix.admin_remove_room_member(room, b.uid, a.uid))

  defp put_ignored!(user, ignored_users) do
    conn = T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(user.uid)}/account_data/m.ignored_user_list", user.at, body: %{"ignored_users" => ignored_users})
    assert conn.status == 200, conn.resp_body
  end

  # all assertions of "the leave entry is a clean window ending at L"
  defp assert_leave_shape(body, room) do
    entry = left(body)[room]
    assert entry, "rooms.leave has the room"
    assert Enum.sort(Map.keys(entry)) == ["account_data", "state", "timeline"]
    assert entry["state"] == %{"events" => []}
    assert entry["account_data"] == %{"events" => []}
    entry
  end

  # ═══ AC2: initial sync over the real stack ════════════════════════════════════════

  describe "AC2 - initial sync" do
    test "joined J, event-backed I1, row-only I2 are delivered; left, declined, forgotten, ignored-inviter and ban-override rooms are in NO section; the token waits", %{a: a, b: b, c: c} do
      anchor = anchor_room!(b)

      # an ignored inviter (the list is written BEFORE the invitation)
      assert T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(b.uid)}/account_data/m.ignored_user_list", b.at, body: %{"ignored_users" => %{c.uid => %{}}}).status == 200

      j = room_with!(a, [b])
      i1 = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      i2 = make_room(a, %{"preset" => "private_chat"})
      assert :ok = InviteDB.insert_invitation(i2, a.uid, b.uid)
      l1 = room_with!(a, [b])
      leave!(b, l1)
      d1 = make_room(a, %{"preset" => "private_chat"})
      invite!(a, d1, b)
      tick()
      assert leave(b, d1).status == 200
      f1 = room_with!(a, [b])
      leave!(b, f1)
      assert forget(b, f1).status == 200
      i3 = make_room(c, %{"preset" => "private_chat", "invite" => [b.uid]})
      k = room_with!(a, [b])
      tick()
      write_member_event!(k, b.uid, "ban", a.uid)
      assert T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [k, b.uid]).rows == [[1]], "K: the row stays active"

      tick()
      say!(b, anchor, marker("final"))
      body = sync(b)

      assert Map.keys(joined(body)) |> Enum.sort() == Enum.sort([anchor, j]), "rooms.join = exactly the joined rooms (K is NOT in it), got #{inspect(Map.keys(joined(body)))}"
      assert Map.keys(invited(body)) |> Enum.sort() == Enum.sort([i1, i2]), "rooms.invite = the event-backed and the row-only invitation"
      assert left(body) == %{}, "no include_leave: an initial sync never has rooms.leave"

      all = Map.keys(joined(body)) ++ Map.keys(invited(body)) ++ Map.keys(left(body))
      assert all == Enum.uniq(all), "no room id in two sections"
      for hidden <- [l1, d1, f1, i3, k], do: assert(nowhere?(body, hidden), "#{hidden} must be in no section")

      {incremental, ms} = timed_sync(b, next(body), timeout: 200)
      assert ms >= 150, "nothing happened: the next sync waits (no hot loop), took #{ms} ms"
      assert nowhere?(incremental, i1) and nowhere?(incremental, i2)
    end

    test "next_batch keeps the <core>.<pos> shape; a user without rooms gets three empty sections", %{a: a} do
      body = sync(a)
      assert next(body) =~ ~r/\A[^.]+\.\d+\z/
      assert joined(body) == %{} and invited(body) == %{} and left(body) == %{}
    end
  end

  # ═══ AC3: invite_state content from the real SQL ═══════════════════════════════════

  describe "AC3 - invite_state" do
    test "name, topic, alias, avatar, is_direct, invite [B]: the stripped events in order, B's own invite event with is_direct, nothing else", %{a: a, b: b} do
      alias_local = "smp#{T.rand(4)}"

      room =
        make_room(a, %{
          "name" => "Invited name",
          "topic" => "Invited topic",
          "preset" => "private_chat",
          "room_alias_name" => alias_local,
          "is_direct" => true,
          "invite" => [b.uid],
          "initial_state" => [%{"type" => "m.room.avatar", "state_key" => "", "content" => %{"url" => "mxc://test.local/avatar#{T.rand(3)}"}}]
        })

      msg = marker("history")
      say!(a, room, msg)
      body = sync(b)
      events = invite_events(body, room)

      assert Enum.map(events, &{&1["type"], &1["state_key"]}) == [
               {"m.room.create", ""},
               {"m.room.name", ""},
               {"m.room.avatar", ""},
               {"m.room.topic", ""},
               {"m.room.canonical_alias", ""},
               {"m.room.join_rules", ""},
               {"m.room.member", a.uid},
               {"m.room.member", b.uid}
             ]

      for ev <- events, do: assert(Enum.sort(Map.keys(ev)) == ["content", "sender", "state_key", "type"], "exactly four keys, got #{inspect(Map.keys(ev))}")
      by = Map.new(events, &{{&1["type"], &1["state_key"]}, &1})

      assert by[{"m.room.create", ""}]["content"] == only(room, "m.room.create"), "the stored create content"
      assert by[{"m.room.name", ""}]["content"] == %{"name" => "Invited name"}
      assert by[{"m.room.join_rules", ""}]["content"] == %{"join_rule" => "invite"}
      assert by[{"m.room.member", a.uid}]["content"] == %{"membership" => "join"} and by[{"m.room.member", a.uid}]["sender"] == a.uid
      assert by[{"m.room.member", b.uid}]["content"] == %{"membership" => "invite", "is_direct" => true}
      assert by[{"m.room.member", b.uid}]["sender"] == a.uid
      refute Jason.encode!(body["rooms"]["invite"][room]) =~ msg, "no history in an invitation"
      refute Enum.any?(events, &(&1["type"] in ["m.room.power_levels", "m.room.history_visibility", "m.room.guest_access", "m.room.message"]))
      assert Map.keys(invited(body)[room]) == ["invite_state"] and Map.keys(invited(body)[room]["invite_state"]) == ["events"]
    end

    test "a room renamed after the invitation shows the CURRENT name in the next view of the invitation", %{a: a, b: b} do
      room = make_room(a, %{"name" => "Before", "preset" => "private_chat", "invite" => [b.uid]})
      tick()
      assert put_state(a, room, "m.room.name", %{"name" => "After the invite"}).status == 200

      names = for ev <- invite_events(sync(b), room), ev["type"] == "m.room.name", do: ev["content"]["name"]
      assert names == ["After the invite"]
    end

    test "a row-only invitation: B's own member event is synthesized from the row (sender = inviter_id); every event has four keys", %{a: a, b: b, c: c} do
      room = make_room(a, %{"preset" => "private_chat"})
      assert :ok = InviteDB.insert_invitation(room, c.uid, b.uid)

      events = invite_events(sync(b), room)

      for ev <- events, do: assert(Enum.sort(Map.keys(ev)) == ["content", "sender", "state_key", "type"])
      assert hd(events)["type"] == "m.room.create"
      assert List.last(events) == %{"type" => "m.room.member", "state_key" => b.uid, "sender" => c.uid, "content" => %{"membership" => "invite"}}
    end

    test "an invitation to a private Space: the stripped m.room.create carries type m.space unchanged", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat", "creation_content" => %{"type" => "m.space"}, "invite" => [b.uid]})

      assert [create | _] = invite_events(sync(b), room)
      assert create["type"] == "m.room.create" and create["content"]["type"] == "m.space"
    end
  end

  # ═══ AC4: incremental invite delivery ═════════════════════════════════════════════

  describe "AC4 - incremental invite delivery" do
    test "A creates Element's DM with B: B's incremental sync has rooms.invite.<dm> with B's own invite event (is_direct), no rooms.join.<dm>; the next sync waits", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      dm = make_room(a, element_dm(b.uid))

      {first, ms} = timed_sync(b, token, timeout: 5_000)

      assert in_section?(first, "invite", dm) and not in_section?(first, "join", dm) and not in_section?(first, "leave", dm)
      assert ms < 1_000, "an available invitation ends the wait at once, took #{ms} ms"
      own = Enum.find(invite_events(first, dm), &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert own["content"] == %{"membership" => "invite", "is_direct" => true} and own["sender"] == a.uid

      {second, ms2} = timed_sync(b, next(first), timeout: 200)
      assert nowhere?(second, dm)
      assert ms2 >= 150, "delivered once: the sync after it waits, took #{ms2} ms"
    end

    test "a long-poll started BEFORE POST /rooms/{id}/invite returns early WITH rooms.invite.<id> in that response", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "private_chat"})
      token = snapshot!(b, anchor)

      started = System.monotonic_time(:millisecond)
      task = Task.async(fn -> sync(b, token, timeout: 5_000) end)
      wait_polling(b)
      # subscribed to its anchor room = the first build is finished and the sync waits: the invite is NEW to the wait
      assert :ok = wait_until(fn -> :pg.get_local_members("room:#{anchor}") != [] end, 3_000)
      invite!(a, room, b)
      body = Task.await(task, 10_000)
      ms = System.monotonic_time(:millisecond) - started

      assert in_section?(body, "invite", room)
      assert ms < 2_500, "the invite woke the poll, took #{ms} ms of 5000"
    end

    test "an invitation older than the token is not re-delivered by an incremental sync (a fresh initial sync shows it)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      token = snapshot!(b, anchor)

      {body, ms} = timed_sync(b, token, timeout: 200)

      assert nowhere?(body, room) and ms >= 150
      assert in_section?(sync(b), "invite", room)
    end

    test "a row-only invitation newer than the token is delivered but does not end a wait by itself", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "private_chat"})
      token = snapshot!(b, anchor)
      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)

      {body, ms} = timed_sync(b, token, timeout: 200)

      assert in_section?(body, "invite", room), "delivered while newer than the anchor"
      assert ms >= 150, "no event to anchor on and no wake-up: the wait runs its course, took #{ms} ms"
    end

    test "messages A posts in the DM while B is only invited are in NO section and do NOT wake B's long-poll (the D11 L-3 pin, kept)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      dm = make_room(a, element_dm(b.uid))
      first = sync(b, token)
      assert in_section?(first, "invite", dm), "control: the invitation arrived"

      secret = marker("dm-secret")

      task =
        Task.async(fn ->
          wait_polling(b)
          # the sync subscribes to the user group first and to its rooms right after: give it the chance (bounded), never fail here
          wait_until(fn -> :pg.get_local_members("room:#{dm}") != [] end, 500)
          for n <- 1..3, do: say!(a, dm, "#{secret} #{n}")
          :posted
        end)

      {body, ms} = timed_sync(b, next(first), timeout: 500)

      assert Task.await(task, 5_000) == :posted
      assert ms >= 450, "the DM's messages must not end the wait early, took #{ms} ms of 500"
      assert nowhere?(body, dm)
      refute Jason.encode!(body) =~ secret
    end
  end

  # ═══ AC5: leave delivery, the ez fix ══════════════════════════════════════════════

  describe "AC5 - leave delivery" do
    for {label, remover, sender, membership} <- [
          {:leave, :leave, :b, "leave"},
          {:kick, :kick, :a, "leave"},
          {:ban, :ban, :a, "ban"},
          {:admin_removal, :admin, :b, "leave"}
        ] do
      test "B joined before the token and #{label}: A's messages, the member event LAST, nothing after it, then silence", ctx do
        %{a: a, b: b} = ctx
        sender = Map.fetch!(ctx, unquote(sender))
        anchor = anchor_room!(b)
        room = room_with!(a, [b])
        token = snapshot!(b, anchor)
        before_leave = [marker("m1"), marker("m2")]
        for m <- before_leave, do: say!(a, room, m)
        tick()

        remove!(unquote(remover), room, a, b)

        tick()
        after_leave = marker("after")
        say!(a, room, after_leave)

        body = sync(b, token)
        entry = assert_leave_shape(body, room)
        events = entry["timeline"]["events"]
        last = List.last(events)

        assert not in_section?(body, "join", room) and not in_section?(body, "invite", room), "not in rooms.join / rooms.invite"
        assert before_leave -- bodies(events) == [], "A's messages before the leave are in the window"
        assert {last["type"], last["state_key"], last["sender"], last["content"]["membership"]} == {"m.room.member", b.uid, sender.uid, unquote(membership)}
        refute Jason.encode!(body) =~ after_leave, "NO event after the leave"
        assert entry["timeline"]["limited"] == false and not Map.has_key?(entry["timeline"], "prev_batch")

        # silence: nothing of the room in the next two syncs, and A's messages never wake the poll
        secret = marker("later")
        for n <- 1..3, do: say!(a, room, "#{secret} #{n}")
        assert put_state(a, room, "m.room.name", %{"name" => "renamed #{secret}"}).status == 200

        second = sync(b, next(body))
        third = sync(b, next(second))
        assert nowhere?(second, room) and nowhere?(third, room)
        refute Jason.encode!(second) =~ secret
        refute Jason.encode!(third) =~ secret

        task =
          Task.async(fn ->
            wait_polling(b)
            say!(a, room, "#{secret} while polling")
          end)

        {fourth, ms} = timed_sync(b, next(third), timeout: 500)
        Task.await(task, 5_000)
        assert nowhere?(fourth, room) and ms >= 450, "a left room does not wake the poll, took #{ms} ms of 500"
        refute Jason.encode!(fourth) =~ secret
      end
    end

    test "B declines a pending invitation: the timeline is exactly B's leave event (no message of the room), then silence", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "private_chat"})
      before_invite = marker("pre")
      say!(a, room, before_invite)
      token = snapshot!(b, anchor)
      invite!(a, room, b)
      tick()
      after_invite = marker("post")
      say!(a, room, after_invite)
      tick()
      assert leave(b, room).status == 200
      tick()
      say!(a, room, marker("after-decline"))

      body = sync(b, token)
      entry = assert_leave_shape(body, room)

      assert [only_event] = entry["timeline"]["events"]
      assert {only_event["type"], only_event["state_key"], only_event["sender"], only_event["content"]["membership"]} == {"m.room.member", b.uid, b.uid, "leave"}
      assert entry["timeline"]["limited"] == false
      refute Jason.encode!(body) =~ before_invite
      refute Jason.encode!(body) =~ after_invite
      assert not in_section?(body, "invite", room) and not in_section?(body, "join", room)

      second = sync(b, next(body))
      assert nowhere?(second, room)
    end

    test "B, a pending invitee, is banned: the timeline is exactly the ban event; A's later messages appear nowhere and do not wake the poll", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "private_chat"})
      token = snapshot!(b, anchor)
      invite!(a, room, b)
      tick()
      moderate(:ban, room, a, b)

      body = sync(b, token)
      entry = assert_leave_shape(body, room)

      assert [ban] = entry["timeline"]["events"]
      assert {ban["state_key"], ban["sender"], ban["content"]["membership"]} == {b.uid, a.uid, "ban"}
      assert not in_section?(body, "invite", room)

      secret = marker("banned-secret")
      tick()
      for n <- 1..3, do: say!(a, room, "#{secret} #{n}")
      {later, ms} = timed_sync(b, next(body), timeout: 500)
      assert nowhere?(later, room) and ms >= 450, "took #{ms} ms"
      refute Jason.encode!(later) =~ secret
    end

    test "a room B left BEFORE the token: A's messages appear nowhere and do not wake the poll", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      leave!(b, room)
      token = snapshot!(b, anchor)
      secret = marker("old-leave")
      say!(a, room, secret)

      {body, ms} = timed_sync(b, token, timeout: 500)

      assert nowhere?(body, room) and ms >= 450
      refute Jason.encode!(body) =~ secret
    end

    test "a rename right after the kick is not in the leave entry (state stays empty) and not in any later sync", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      moderate(:kick, room, a, b)
      new_name = marker("renamed-after-kick")
      assert put_state(a, room, "m.room.name", %{"name" => new_name}).status == 200

      body = sync(b, token)
      entry = assert_leave_shape(body, room)

      assert List.last(entry["timeline"]["events"])["content"]["membership"] == "leave"
      refute Jason.encode!(body) =~ new_name
      refute Jason.encode!(sync(b, next(body))) =~ new_name
    end
  end

  # ═══ AC6: the starred transitions over HTTP ═══════════════════════════════════════

  describe "AC6 - transitions within one window" do
    test "invited, then joined: rooms.join with the invite and the join event in the timeline, no rooms.invite", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      join!(b, room)

      body = sync(b, token)
      memberships = for ev <- join_timeline(body, room), ev["type"] == "m.room.member" and ev["state_key"] == b.uid, do: ev["content"]["membership"]

      assert in_section?(body, "join", room) and not in_section?(body, "invite", room) and not in_section?(body, "leave", room)
      assert memberships == ["invite", "join"]
    end

    test "joined AFTER the token, then left: the join event, the events between and the leave event, nothing before the join", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      join!(b, room)
      between = marker("between")
      tick()
      say!(a, room, between)
      leave!(b, room)

      body = sync(b, token)
      events = leave_timeline(body, room)

      assert Enum.map(events, &{&1["type"], &1["content"]["membership"] || &1["content"]["body"]}) == [
               {"m.room.member", "join"},
               {"m.room.message", between},
               {"m.room.member", "leave"}
             ]
    end

    test "joined before the token, left, re-invited: rooms.invite only (the leave is superseded, not in rooms.join / rooms.leave)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      leave!(b, room)
      tick()
      invite!(a, room, b)

      body = sync(b, token)

      assert in_section?(body, "invite", room) and not in_section?(body, "join", room) and not in_section?(body, "leave", room)
      own = List.last(invite_events(body, room))
      assert {own["state_key"], own["sender"], own["content"]["membership"]} == {b.uid, a.uid, "invite"}
    end

    test "left, forgot, re-invited: the invitation clears the forget (the forgotten_rooms row is gone) and rooms.invite has the room (D7)", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      leave!(b, room)
      assert forget(b, room).status == 200
      assert forgotten_rows(b.uid, room) == 1
      tick()

      invite!(a, room, b)

      assert forgotten_rows(b.uid, room) == 0, "the invitation clears the forget"
      body = sync(b, token)
      assert in_section?(body, "invite", room)
      assert in_section?(sync(b), "invite", room), "and a fresh initial sync shows it"
    end

    test "a failing unforget (DELETE blocked by a trigger) does not fail the invite (best effort); a room without the trigger IS unforgotten", %{a: a, b: b} do
      anchor = anchor_room!(b)
      blocked = room_with!(a, [b])
      control = room_with!(a, [b])
      _token = snapshot!(b, anchor)
      for room <- [blocked, control], do: leave!(b, room)
      for room <- [blocked, control], do: assert(forget(b, room).status == 200)
      tick()
      block_deletes!("forgotten_rooms", "OLD.user_id = '#{safe_uid!(b.uid)}' AND OLD.room_id = '#{blocked}'")

      invite!(a, control, b)
      assert forgotten_rows(b.uid, control) == 0, "control: without the trigger the invitation clears the forget"

      conn = invite(a, blocked, b)

      assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
      assert %{state: :pending} = invitation(blocked, b.uid)
      assert latest_member_event(blocked, b.uid).content["membership"] == "invite"
      assert forgotten_rows(b.uid, blocked) == 1, "the forget could not be cleared"
    end

    test "joined before the token, left, re-joined (a public room): rooms.join with the events of the gap, not rooms.leave", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = make_room(a, %{"preset" => "public_chat"})
      join!(b, room)
      token = snapshot!(b, anchor)
      leave!(b, room)
      gap = marker("while-away")
      tick()
      say!(a, room, gap)
      join!(b, room)

      body = sync(b, token)

      assert in_section?(body, "join", room) and not in_section?(body, "leave", room)
      assert gap in bodies(join_timeline(body, room))
    end
  end

  # ═══ AC9: ban override ════════════════════════════════════════════════════════════

  describe "AC9 - ban override" do
    test "an active row whose latest member event is a ban: rooms.leave once (when the ban is new), never rooms.join, also not as an account-data-only room", %{a: a, b: b} do
      anchor = anchor_room!(b)
      k = room_with!(a, [b])
      normal = room_with!(a, [b])
      token = snapshot!(b, anchor)
      tick()
      write_member_event!(k, b.uid, "ban", a.uid)

      first = sync(b, token)
      assert in_section?(first, "leave", k) and not in_section?(first, "join", k)
      assert List.last(leave_timeline(first, k))["content"]["membership"] == "ban"

      # a room account data write for K (the route refuses non-members; the row is still active, write through the store)
      assert :ok = Nebu.Matrix.RoomAccountDataStore.put(b.uid, k, "org.example.pin", Jason.encode!(%{"k" => "v"}))
      assert :ok = Nebu.Matrix.RoomAccountDataStore.put(b.uid, normal, "org.example.pin", Jason.encode!(%{"k" => "v"}))

      second = sync(b, next(first))

      assert not in_section?(second, "join", k) and not in_section?(second, "leave", k) and not in_section?(second, "invite", k), "K never comes back as an empty joined room"
      assert in_section?(second, "join", normal), "regression: an account-data-only change of a joined room still produces the empty join entry"
      assert [%{"type" => "org.example.pin"}] = second["rooms"]["join"][normal]["account_data"]["events"]
    end

    test "a ban-override room is not in rooms.join of a fresh initial sync either", %{a: a, b: b} do
      k = room_with!(a, [b])
      tick()
      write_member_event!(k, b.uid, "ban", a.uid)

      body = sync(b)

      assert nowhere?(body, k)
    end
  end

  # ═══ AC10 / AC22 (c): ignored users ═══════════════════════════════════════════════

  describe "AC10 - ignored users" do
    test "A is ignored: A's invitation is in no section (initial, incremental), C's is in rooms.invite; B can still POST /join", %{a: a, b: b, c: c} do
      anchor = anchor_room!(b)
      put_ignored!(b, %{a.uid => %{}})
      token = snapshot!(b, anchor)
      r = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      r2 = make_room(c, %{"preset" => "private_chat", "invite" => [b.uid]})

      incremental = sync(b, token)
      assert nowhere?(incremental, r) and in_section?(incremental, "invite", r2)

      initial = sync(b)
      assert nowhere?(initial, r) and in_section?(initial, "invite", r2)

      assert join(b, r).status == 200, "the ignore list hides the invitation, it does not revoke it"
    end

    test "the inviter that counts is the invite EVENT's sender (D8): the row says C, the event says A: ignoring A hides the invitation, ignoring only C does not", %{a: a, b: b, c: c} do
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      T.privileged_sql!("UPDATE room_invitations SET inviter_id = $1 WHERE room_id = $2 AND invitee_id = $3", [c.uid, room, b.uid])

      put_ignored!(b, %{c.uid => %{}})
      assert in_section?(sync(b), "invite", room), "ignoring the row's inviter does not hide an invitation whose event was sent by A"

      put_ignored!(b, %{a.uid => %{}})
      assert nowhere?(sync(b), room), "ignoring the event's sender hides it"
    end

    test "a malformed list ({\"ignored_users\": []}) suppresses nothing", %{a: a, b: b} do
      assert T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(b.uid)}/account_data/m.ignored_user_list", b.at, body: %{"ignored_users" => []}).status == 200
      r = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})

      assert in_section?(sync(b), "invite", r)
    end

    test "the list changes while an invitation is pending: no re-send, no leave; after un-ignoring it re-enters the partition and is delivered once", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      r = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      first = sync(b, token)
      assert in_section?(first, "invite", r), "control: the invitation was delivered"

      put_ignored!(b, %{a.uid => %{}})
      # story sync-token-per-device (D11, DELIBERATE amendment): the PUT of the ignore list is GLOBAL account data that is pending for this device, so
      # the next sync returns at once (it carries m.ignored_user_list) instead of waiting out the timeout
      # (a large timeout against a generous bound: the point is that the wait is skipped, not how fast a loaded runner answers)
      {second, ms} = timed_sync(b, next(first), timeout: 5_000)
      assert nowhere?(second, r), "neither re-sent nor a leave entry"
      assert ms < 2_500, "pending global account data ends the wait at once (took #{ms} ms of 5000)"

      put_ignored!(b, %{})
      third = sync(b, next(second))
      # DELIBERATE amendment by story sync-stream-position (D9 / D3), old -> new: "missed events are not re-sent after un-ignoring" was the anchor passing the invitation. While
      # the inviter is ignored the room is no partition room of the device (its cursor row is deleted); after un-ignoring it ENTERS the partition: no base row = a NEW invitation,
      # delivered ONCE and not again. (This device HAD the invitation before the ignore, so it receives a duplicate: harmless for clients and endorsed by D20 (2); the case of an
      # invitation that arrives while the inviter is ignored is the next test.)
      assert in_section?(third, "invite", r), "an invitation that enters the partition is new (D9): delivered once after un-ignoring"
      assert nowhere?(sync(b, next(third)), r), "and not repeated"
      assert in_section?(sync(b), "invite", r)
    end

    # B-2 (test review): the case the rationale describes: an invitation sent WHILE the inviter is ignored is never delivered, and appears exactly once after un-ignoring
    test "an invitation sent while the inviter is ignored is never delivered; after un-ignoring it appears exactly once", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      put_ignored!(b, %{a.uid => %{}})
      r = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})

      ignored = sync(b, token)
      assert nowhere?(ignored, r), "an ignored inviter's invitation is in no section"
      again = sync(b, next(ignored))
      assert nowhere?(again, r)

      put_ignored!(b, %{})
      once = sync(b, next(again))
      assert in_section?(once, "invite", r), "re-entering the partition: delivered once"
      assert nowhere?(sync(b, next(once)), r), "and not repeated"
    end
  end

  # ═══ AC12: the HTTP shape ═════════════════════════════════════════════════════════

  describe "AC12 - the wire shape of the new sections" do
    test "rooms.leave.<id> has exactly state / timeline / account_data; its events have the join timeline shape; a non-limited window has NO prev_batch key", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      say!(a, room, marker("shape"))
      leave!(b, room)

      body = sync(b, token)
      entry = assert_leave_shape(body, room)
      timeline = entry["timeline"]

      assert Enum.sort(Map.keys(timeline)) == ["events", "limited"], "no prev_batch key, never an empty string"
      assert timeline["limited"] == false

      message = Enum.find(timeline["events"], &(&1["type"] == "m.room.message"))
      member = Enum.find(timeline["events"], &(&1["type"] == "m.room.member"))
      assert Enum.sort(Map.keys(message)) == ["content", "event_id", "origin_server_ts", "room_id", "sender", "type", "unsigned"]
      assert Enum.sort(Map.keys(member)) == ["content", "event_id", "origin_server_ts", "room_id", "sender", "state_key", "type", "unsigned"]
      assert is_integer(message["unsigned"]["age"]) and message["room_id"] == room
      # story member-event-prev-content (DELIBERATE re-pin of D6; old -> new): the leave window now carries the predecessor of a state event (one batched
      # lookup per response). A message keeps exactly `age`; the leave event (B joined before it) has age + the three predecessor keys.
      assert Map.keys(message["unsigned"]) == ["age"], "a message never carries predecessor keys"
      assert Enum.sort(Map.keys(member["unsigned"])) == ["age", "prev_content", "prev_sender", "replaces_state"], "the leave event of a joined member has its predecessor (the join)"
      assert next(body) =~ ~r/\A[^.]+\.\d+\z/
    end

    test "a limited leave window (more than 20 events) has limited true and a non-empty prev_batch; the join event is not prepended", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      ids = for n <- 1..22, do: say!(a, room, "limited #{n}")
      leave!(b, room)

      body = sync(b, token)
      entry = assert_leave_shape(body, room)
      events = entry["timeline"]["events"]

      assert entry["timeline"]["limited"] == true
      assert is_binary(entry["timeline"]["prev_batch"]) and entry["timeline"]["prev_batch"] != ""
      assert length(events) == 21
      assert hd(events)["event_id"] == Enum.at(ids, 2), "the newest 20 messages, oldest first"
      assert List.last(events)["content"]["membership"] == "leave"
    end

    test "rooms.invite.<id> is exactly {invite_state: {events: [...]}} and rooms.join keeps its shape for joined rooms", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      invited_room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      tick()
      say!(b, anchor, marker("joined-news"))

      body = sync(b, token)

      assert Map.keys(invited(body)[invited_room]) == ["invite_state"]
      entry = joined(body)[anchor]
      assert Enum.sort(Map.keys(entry)) == ["account_data", "state", "timeline"]
      assert Enum.sort(Map.keys(entry["timeline"])) == ["events", "limited", "prev_batch"]
    end
  end

  # ═══ AC13: the Element DM flow ════════════════════════════════════════════════════

  describe "AC13 - the Element DM flow over HTTP" do
    test "A creates the DM, B sees the invitation (is_direct, sender A), joins, receives hello, leaves; after the leave B receives nothing", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      dm = make_room(a, element_dm(b.uid))

      invite_body = sync(b, token)
      own = Enum.find(invite_events(invite_body, dm), &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert own["content"] == %{"membership" => "invite", "is_direct" => true} and own["sender"] == a.uid

      join!(b, dm)
      joined_body = sync(b, next(invite_body))
      assert in_section?(joined_body, "join", dm) and not in_section?(joined_body, "invite", dm)
      assert Enum.any?(join_timeline(joined_body, dm), &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid and &1["content"]["membership"] == "join"))

      hello = marker("hello")
      tick()
      say!(a, dm, hello)
      hello_body = sync(b, next(joined_body))
      assert hello in bodies(join_timeline(hello_body, dm))

      leave!(b, dm)
      leave_body = sync(b, next(hello_body))
      assert List.last(leave_timeline(leave_body, dm))["content"]["membership"] == "leave"
      assert List.last(leave_timeline(leave_body, dm))["sender"] == b.uid

      after_leave = marker("after")
      tick()
      say!(a, dm, after_leave)
      later = sync(b, next(leave_body))
      assert nowhere?(later, dm)
      refute Jason.encode!(later) =~ after_leave
    end
  end

  # ═══ AC19: taken-back invitations ═════════════════════════════════════════════════

  describe "AC19 - taken-back invitation" do
    for {label, taker} <- [removal_by_the_inviter: :a, decline_by_the_invitee: :b] do
      test "#{label}: rooms.leave [L] once, never rooms.invite, then nothing, not in the initial sync, POST /join is 403", ctx do
        %{a: a, b: b} = ctx
        sender = Map.fetch!(ctx, unquote(taker))
        anchor = anchor_room!(b)
        token = snapshot!(b, anchor)
        room = make_room(a, %{"preset" => "private_chat"})
        invite!(a, room, b)
        tick()
        leave_id = write_member_event!(room, b.uid, "leave", sender.uid)
        assert %{state: :pending} = invitation(room, b.uid), "the row is still pending: the failed-reject state"

        body = sync(b, token)
        entry = assert_leave_shape(body, room)

        assert event_ids(entry["timeline"]["events"]) == [leave_id]
        assert hd(entry["timeline"]["events"])["sender"] == sender.uid
        assert not in_section?(body, "invite", room) and not in_section?(body, "join", room)
        assert nowhere?(sync(b, next(body)), room)
        assert nowhere?(sync(b), room), "the initial sync does not list it"

        conn = join(b, room)
        assert conn.status == 403
        assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "You are not invited to this room"}
      end
    end

    test "a leave OLDER than invited_at (legacy row-only re-invite of a former member) is a valid invitation: rooms.invite, join 200", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)
      leave!(b, room)
      tick()
      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)

      body = sync(b, token)

      assert in_section?(body, "invite", room)
      assert not in_section?(body, "leave", room) and not in_section?(body, "join", room)
      assert join(b, room).status == 200
    end

    test "after a fresh POST /invite B sees rooms.invite again and can join", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      tick()
      write_member_event!(room, b.uid, "leave", a.uid)
      first = sync(b, token)
      assert in_section?(first, "leave", room), "control: taken back"

      tick()
      invite!(a, room, b)
      second = sync(b, next(first))

      assert in_section?(second, "invite", room)
      assert join(b, room).status == 200
    end

    test "invited, banned, then unbanned: one leave entry per new latest event ([ban], then [unban leave]), never join or invite", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      tick()
      moderate(:ban, room, a, b)

      first = sync(b, token)
      assert [ban] = leave_timeline(first, room)
      assert ban["content"]["membership"] == "ban"

      tick()
      moderate(:unban, room, a, b)
      second = sync(b, next(first))

      assert [unban] = leave_timeline(second, room)
      assert unban["content"]["membership"] == "leave" and unban["sender"] == a.uid
      assert not in_section?(second, "join", room) and not in_section?(second, "invite", room)
      assert nowhere?(sync(b, next(second)), room)
    end
  end

  # ═══ AC1 / D3: the tie order reaches the join decision ════════════════════════════

  describe "D3 - join + ban tie at POST /join" do
    test "POST /join of a pending invitee whose join and ban events tie in one millisecond is 403 banned, in every insertion order", %{a: a, b: b} do
      for n <- 1..6 do
        room = make_room(a, %{"preset" => "private_chat"})
        invite!(a, room, b)
        tick()
        t = ts_after(room)
        {first, second} = if rem(n, 2) == 0, do: {"join", "ban"}, else: {"ban", "join"}

        for membership <- [first, second] do
          T.privileged_sql!(
            "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, 'm.room.member', $4, $5, $6)",
            ["$" <> (if membership == "ban", do: "aaa", else: "zzz") <> T.rand(8), room, a.uid, %{"membership" => membership}, t, b.uid]
          )
        end

        conn = join(b, room)
        assert conn.status == 403, "room #{n} (#{first} first): #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["error"] == "You are banned from this room", "room #{n}"
      end
    end
  end

  # ═══ AC20: full_state ═════════════════════════════════════════════════════════════

  describe "AC20 - full_state=true with since" do
    test "returns at once: joined rooms with full state, the new message, invitation and leave; left rooms never in rooms.join", %{a: a, b: b} do
      anchor = anchor_room!(b)
      name_l1 = marker("L1name")
      name_l2 = marker("L2name")
      j = room_with!(a, [b], %{"name" => "J #{T.rand(3)}"})
      j2 = room_with!(a, [b])
      l1 = room_with!(a, [b], %{"name" => name_l1})
      leave!(b, l1)
      l2 = room_with!(a, [b], %{"name" => name_l2})
      token = snapshot!(b, anchor)

      news = marker("j2-news")
      say!(a, j2, news)
      invited_room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      tick()
      leave!(b, l2)

      {body, ms} = timed_sync(b, token, timeout: 5_000, full_state: true)

      assert ms < 1_000, "full_state returns at once, took #{ms} ms"
      for room <- [j, j2] do
        assert Map.has_key?(joined(body), room), "#{room} is in rooms.join (every joined room, full_state)"
        state_types = for ev <- joined(body)[room]["state"]["events"] ++ join_timeline(body, room), do: ev["type"]
        assert "m.room.create" in state_types, "#{room}: the full current state"
        assert "m.room.power_levels" in state_types, "#{room}: power levels in the state"
      end

      assert news in bodies(join_timeline(body, j2))
      assert join_timeline(body, j) == [] and joined(body)[j]["timeline"]["limited"] == false
      assert Enum.any?(joined(body)[j]["state"]["events"], &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert in_section?(body, "invite", invited_room) and in_section?(body, "leave", l2)
      assert not in_section?(body, "join", l1) and not in_section?(body, "join", l2) and not in_section?(body, "leave", l1) and not in_section?(body, "invite", l1)
      refute Jason.encode!(body) =~ name_l1
      refute Jason.encode!(body) =~ name_l2
    end

    test "full_state absent, false or \"1\" long-polls like any incremental sync; full_state=true WITHOUT since equals an initial sync", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)

      Enum.reduce([nil, "false", "1"], token, fn value, since ->
        {body, ms} = timed_sync(b, since, timeout: 250, full_state: value)
        assert ms >= 200, "full_state=#{inspect(value)} is not the full_state mode, took #{ms} ms"
        next(body)
      end)

      plain = sync(b)
      forced = sync(b, nil, full_state: true)
      assert Map.keys(joined(plain)) |> Enum.sort() == Map.keys(joined(forced)) |> Enum.sort()
      assert Map.keys(invited(plain)) == Map.keys(invited(forced)) and left(forced) == %{} and left(plain) == %{}
      assert room in Map.keys(joined(forced))
    end
  end

  # ═══ AC21: unsupported parameters pinned ══════════════════════════════════════════

  describe "AC21 - unsupported parameters" do
    test "/versions lists no version >= v1.16 (both OAuth states); use_state_after=true yields no state_after in join or leave rooms", %{a: a, b: b} do
      for oauth? <- [true, false] do
        versions = Nebu.Matrix.HttpPublic.versions_body(oauth?)["versions"]
        minors = for "v1." <> minor <- versions, do: String.to_integer(minor)
        assert minors != [] and Enum.max(minors) <= 15, "advertised: #{inspect(versions)}; a version >= v1.16 means use_state_after / state_after must be implemented (D15)"
      end

      anchor = anchor_room!(b)
      joined_room = room_with!(a, [b])
      leaving = room_with!(a, [b])
      initial = sync(b, nil, use_state_after: true)
      token = snapshot!(b, anchor)
      say!(a, joined_room, marker("news"))
      leave!(b, leaving)

      incremental = sync(b, token, use_state_after: true)

      for body <- [initial, incremental], name <- ["join", "leave"], {room, entry} <- section(body, name) do
        refute Map.has_key?(entry, "state_after"), "#{room}: no state_after"
        refute Map.has_key?(entry, "org.matrix.msc4222.state_after"), "#{room}: no unstable state_after"
        assert Map.has_key?(entry, "state"), "#{room}: state stays"
      end

      assert in_section?(incremental, "leave", leaving) and in_section?(incremental, "join", joined_room), "control: both sections were exercised"
    end

    test "an initial sync with filter {room: {include_leave: true}} still has rooms.leave = {} (known deviation, follow-up fg (a))", %{a: a, b: b} do
      room = room_with!(a, [b])
      leave!(b, room)
      filter = Jason.encode!(%{"room" => %{"include_leave" => true}})

      body = sync(b, nil, filter: filter)

      assert left(body) == %{}
      assert nowhere?(body, room)
    end

    test "POST /forget by a PENDING invitee answers 200 {} (known deviation, spec 400, follow-up fg (c)) and the invitation is then hidden", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      assert in_section?(sync(b), "invite", room), "control: visible before"

      conn = forget(b, room)

      assert conn.status == 200 and T.json(conn) == %{}
      assert nowhere?(sync(b), room), "a forgotten invitation is hidden (rule 1)"
    end
  end

  # ═══ AC22: robustness ═════════════════════════════════════════════════════════════

  describe "AC22 - fail closed, fallback" do
    test "an invalid since and another user's token fall back to an initial sync: 200, rooms.leave = {}, joined rooms and pending invitations present, no error", %{a: a, b: b} do
      anchor = anchor_room!(b)
      joined_room = room_with!(a, [b])
      invited_room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      left_room = room_with!(a, [b])
      leave!(b, left_room)
      _ = snapshot!(b, anchor)
      others_token = next(sync(a))

      for since <- [marker("garbage"), others_token] do
        body = sync(b, since)

        assert left(body) == %{}, "no rooms.leave in a fallback"
        assert in_section?(body, "join", joined_room) and in_section?(body, "invite", invited_room)
        assert nowhere?(body, left_room)
      end
    end

    test "a failing membership read answers 503 with errcode M_UNAVAILABLE AND error, persists NO token, and a retry with the SAME since is incremental", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid]})
      # story sync-token-per-device: the token of this device-bound session lives under its DEVICE key, so read by user only (the user has exactly one row)
      stored = fn -> T.sql!("SELECT since_token, last_event_id FROM sync_tokens WHERE user_id = $1", [b.uid]).rows end
      before = stored.()
      assert [_] = before, "precondition: the snapshot stored exactly one token row (otherwise the assertion below would be vacuous)"

      prior_rooms_db = Application.fetch_env(:event_dispatcher, :rooms_db_module)
      prior_messages_db = Application.fetch_env(:event_dispatcher, :messages_db_module)
      Application.put_env(:event_dispatcher, :rooms_db_module, FailingCandidatesDB)
      Application.put_env(:event_dispatcher, :messages_db_module, FailingCandidatesDB)

      restore = fn ->
        for {key, prior} <- [rooms_db_module: prior_rooms_db, messages_db_module: prior_messages_db] do
          case prior do
            {:ok, value} -> Application.put_env(:event_dispatcher, key, value)
            :error -> Application.delete_env(:event_dispatcher, key)
          end
        end
      end

      on_exit(restore)

      conn = sync_conn(b, since: token, timeout: 0)
      restore.()

      assert conn.status == 503, "#{conn.status} #{conn.resp_body}"
      body = T.json(conn)
      assert body["errcode"] == "M_UNAVAILABLE" and is_binary(body["error"]) and body["error"] != ""
      assert stored.() == before, "no token persisted on failure"

      {retry, ms} = timed_sync(b, token, timeout: 200)
      assert in_section?(retry, "invite", room), "the SAME since works again"
      refute in_section?(retry, "join", anchor), "and it is INCREMENTAL: an initial-sync fallback would list B's anchor room in rooms.join"
      assert ms < 3_000
    end
  end

  defp safe_uid!(uid) do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, uid)
    uid
  end

  # a privileged trigger that makes the DELETE of the matching rows fail; removed by on_exit
  defp block_deletes!(table, condition) do
    name = "atdd_smp_" <> T.rand(5)

    ExUnit.Callbacks.on_exit(fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF #{condition} THEN RAISE EXCEPTION 'atdd: delete blocked'; END IF; RETURN OLD; END $$ LANGUAGE plpgsql")
    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")
  end
  # ═══ code review cycle 1 ═════════════════════════════════════════════════════════════════════════════════

  describe "review cycle 1 M-1 - the leave window ends at the end of the membership row" do
    test "a left row WITHOUT a leave event (failed write), messages after it, then a ban event: no message after left_at is in rooms.leave", %{a: a, b: b} do
      anchor = anchor_room!(b)
      room = room_with!(a, [b])
      token = snapshot!(b, anchor)

      before_marker = marker("before-removal")
      tick()
      say!(a, room, before_marker)
      tick()
      Process.sleep(3)

      # the row ends, the leave event write "failed": nothing is written but the row
      assert :ok = DB.delete_member(room, b.uid)
      [[left_at]] = T.sql!("SELECT left_at FROM room_members WHERE room_id = $1 AND user_id = $2", [room, b.uid]).rows
      tick()
      Process.sleep(3)

      after_markers = for n <- 1..3, do: marker("after-removal-#{n}")
      for m <- after_markers, do: (say!(a, room, m); Process.sleep(2))

      # a moderator bans the already removed user (a retry of a 500 ban): L = ban, P = the old join
      tick()
      ban_id = write_member_event!(room, b.uid, "ban", a.uid)

      body = sync(b, token)
      entry = assert_leave_shape(body, room)
      timeline = entry["timeline"]["events"]

      assert before_marker in bodies(timeline), "the message sent while b was a member is in the window"
      assert List.last(timeline)["event_id"] == ban_id, "the ban event is last"
      assert Enum.all?(timeline, fn ev -> ev["origin_server_ts"] <= left_at or ev["event_id"] == ban_id end), "no event after left_at except L itself"

      raw = Jason.encode!(body)
      for m <- after_markers, do: refute(raw =~ m, "#{m} must appear nowhere in the response")
      assert room not in Map.keys(joined(body))
    end
  end

  # DELIBERATE amendment by story sync-stream-position (D6, premise "fc (f) moot"), old -> new: the token has no anchor EVENT any more, so an anchor event that no longer
  # exists is no reason for a fallback. What the L-2 test guarded stays pinned: the old leave is NOT delivered again and the sync is not "a delivery of everything".
  describe "review cycle 1 L-2 - the (informational) last_event_id event" do
    test "a last_event_id event that no longer exists changes nothing: still an incremental answer, the old leave is not delivered again, nothing of the rooms is repeated", %{a: a, b: b} do
      anchor = anchor_room!(b)
      old = room_with!(a, [b])
      leave!(b, old)
      token = snapshot!(b, anchor)
      # story sync-token-per-device (D1, DELIBERATE amendment): the token of this device-bound session is stored under its device key, no longer under ''
      [[anchor_event]] = T.sql!("SELECT last_event_id FROM sync_tokens WHERE user_id = $1", [b.uid]).rows
      T.privileged_sql!("DELETE FROM events WHERE event_id = $1", [anchor_event])

      body = sync(b, token)

      assert left(body) == %{}, "the old leave is not delivered again"
      refute in_section?(body, "join", anchor), "an incremental answer: the quiet room is not repeated (the old fallback delivered every joined room)"
      assert is_binary(next(body))
    end
  end
end
