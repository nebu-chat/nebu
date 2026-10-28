defmodule Nebu.Matrix.CreateRoomInvitesHttpTest do
  @moduledoc """
  Integration tests for story `create-room-invites-direct` (epic oauth-broker, follow-up `eb`): over HTTP against the real supervision
  tree + PostgreSQL (users and sessions as in `create_room_presets_http_test.exs`, random localparts, `:server_name` pinned to the
  users' domain for the run).

  What only the real stack decides and this file pins:

    * Element's exact DM request end to end: the invitation row, the ONE signed `m.room.member` invite event with `is_direct`, the join
      of the partner with the (real) invitation, both can write and read, the creator's incremental `/sync` carries the invite event.
    * the real SQL: `Room.DB.delete_room/1` with an invitation row (FK `room_invitations.room_id`), the re-armed `room_invitations` row,
      the latest-membership read after an invite event (already invited / banned / declined), the existence read of the invitees
      (`users.is_active`), the fatal step 8 with its cleanup (a privileged trigger makes the invite row / event write fail).
    * the wire format: errcodes, fixed texts, BYTE-identical 404 / 403 bodies without an echoed id, the body checks of
      `POST /rooms/{roomId}/invite` (before the room checks), the `is_direct` type check of the router.
    * the invitee's `/sync` (story sync-membership-partition replaced the interim guard D11 of this story): the invite room is delivered in
      `rooms.invite` (never in `rooms.join`) and, after the join, in `rooms.join` as before; a re-invited former member gets `rooms.invite`
      only. The full partition is pinned in `sync_membership_partition_http_test.exs`.

  Conventions (as the sibling presets suite):

    * `m.room.member` events carry `origin_server_ts` in milliseconds and the latest membership is read by that timestamp: membership
      changes of the SAME user in one test are separated by `tick/0`, which keeps the scenarios deterministic. Orders WITHIN one createRoom
      (the strictly increasing chain of step 8) are asserted in the unit suite with an insertion sequence, never with ties here.
    * ban / kick have NO HTTP route: they are driven through `Nebu.Matrix.EventDispatcher.Server` with the real Room.Server / Postgres.
    * Every rejected createRoom must leave NO room and NO invitation row behind (`assert_rejected/5`, global counts: `async: false`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"
  @well_shaped_3pid %{"id_server" => "matrix.org", "id_access_token" => "t", "medium" => "email", "address" => "a@b.c"}
  @not_found_text "The user to invite does not exist on this server"
  @foreign_text "Users of other servers cannot be invited: this server does not federate"
  @threepid_text "Third-party invites are not supported on this server"

  setup do
    T.reset_rate_limits()

    # many older suites DELETE :server_name on exit: without it the invite path (D3: local invitees only) would see every
    # "@...:test.local" user as foreign. Pin it to the users' domain (restored by on_exit, never a bare delete).
    Nebu.Test.ServerName.pin!(T.server_name())

    on_exit(fn -> T.restore_rate_limits() end)

    {:ok, user: user!("CRIA"), other: user!("CRIB"), third: user!("CRIC"), fourth: user!("CRID")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp server_name, do: T.server_name()
  defp enc(room_id), do: URI.encode_www_form(room_id)
  defp path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"

  # Waits until the millisecond clock has advanced (at most 50 ms): member events are stamped with the millisecond clock and the latest
  # membership is read by origin_server_ts, so two membership changes of one user in ONE millisecond would tie.
  defp tick do
    start = System.system_time(:millisecond)
    :ok = wait_until(fn -> System.system_time(:millisecond) > start end, 50)
  end

  defp wait_until(fun, attempts) do
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

  # What a creator has in the database: the rooms whose m.room.create event he sent (a cleaned-up room leaves none) and the invitation rows
  # he issued. Per CREATOR (not a global count), so a concurrently running test of another suite cannot disturb the comparison.
  defp footprint(uid) do
    {T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [uid]).rows,
     T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1", [uid]).rows}
  end

  # `status` + `errcode`, no room and no invitation row left behind (not even a created-then-cleaned-up one)
  defp assert_rejected(user, body, status, errcode, label) do
    before = footprint(user.uid)
    conn = create(user, body)
    assert conn.status == status, "#{label}: expected #{status}, got #{conn.status} #{conn.resp_body}"
    assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
    assert footprint(user.uid) == before, "#{label}: a rejected createRoom must not leave a room or an invitation row behind"
    conn
  end

  defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  defp leave(user, room), do: T.matrix_request(:post, path(room, "leave"), user.at)
  defp send_invite(owner, room, body), do: T.matrix_request(:post, path(room, "invite"), owner.at, body: body)
  defp invite(owner, room, target), do: send_invite(owner, room, %{"user_id" => target.uid})
  defp put_state(user, room, type, body), do: T.matrix_request(:put, path(room, "state/#{type}"), user.at, body: body)

  defp invite!(owner, room, target) do
    c = invite(owner, room, target)
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
  end

  # a join follows an invite / leave of the same user: separate the two events by a millisecond (the latest membership is read by timestamp)
  defp join!(user, room) do
    tick()
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
  end

  defp send_message(user, room, body) do
    T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: %{"msgtype" => "m.text", "body" => body})
  end

  defp message_bodies(user, room) do
    conn = T.matrix_request(:get, path(room, "messages?dir=b&limit=100"), user.at)
    assert conn.status == 200, conn.resp_body

    for ev <- T.json(conn)["chunk"], ev["type"] == "m.room.message", do: ev["content"]["body"]
  end

  # ban / kick: no HTTP route, the dispatcher with the caller's identity (real Room.Server / Postgres)
  defp ban(room, caller, target) do
    req = %Core.BanUserRequest{room_id: room, target_id: target.uid, reason: ""}
    assert %Core.BanUserResponse{} = Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(caller.uid))
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

  defp invite_events(room_id, uid), do: Enum.filter(member_events(room_id, uid), &(&1.content["membership"] == "invite"))
  defp membership_events(room_id, uid, membership), do: Enum.filter(member_events(room_id, uid), &(&1.content["membership"] == membership))
  defp latest_membership(room_id, uid), do: Nebu.Matrix.Room.DB.get_member_membership(room_id, uid)

  defp state_events(room_id, type) do
    T.sql!("SELECT state_key, content FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts", [room_id, type]).rows
    |> Enum.map(fn [key, content] -> {key, content_of(content)} end)
  end

  defp only(room_id, type) do
    assert [{_key, content}] = state_events(room_id, type), "exactly one #{type} event expected"
    content
  end

  defp stored_power_levels(room_id), do: T.sql!("SELECT power_levels_json FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd() |> content_of()
  defp member?(room_id, uid), do: T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room_id, uid]).rows == [[1]]

  # %{state: :pending | :accepted | :rejected, invited_at: ms, inviter: id} | nil for the (single) invitation row of (room, user)
  defp invitation(room_id, uid) do
    case T.sql!("SELECT accepted_at, rejected_at, invited_at, inviter_id FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room_id, uid]).rows do
      [] -> nil
      [[nil, nil, at, inviter]] -> %{state: :pending, invited_at: at, inviter: inviter}
      [[_accepted, nil, at, inviter]] -> %{state: :accepted, invited_at: at, inviter: inviter}
      [[nil, _rejected, at, inviter]] -> %{state: :rejected, invited_at: at, inviter: inviter}
    end
  end

  defp invitation_state(room_id, uid) do
    case invitation(room_id, uid) do
      nil -> :none
      %{state: state} -> state
    end
  end

  defp invitation_rows(room_id), do: T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [room_id]).rows |> hd() |> hd()

  # Element's exact DM body (AC1): trusted_private_chat, private, invite [partner], is_direct, guest_access / encryption / history_visibility
  defp element_dm(partner_uid, extra \\ %{}) do
    Map.merge(
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
      },
      extra
    )
  end

  defp sync(user, since \\ nil) do
    suffix = if since, do: "?since=#{URI.encode_www_form(since)}&timeout=0", else: "?timeout=0"
    conn = T.matrix_request(:get, "/_matrix/client/v3/sync" <> suffix, user.at)
    assert conn.status == 200, "sync: #{conn.status} #{conn.resp_body}"
    T.json(conn)
  end

  # a privileged trigger that makes the INSERT of the matching rows fail (the runtime role cannot create triggers); removed by on_exit
  defp block_writes!(table, condition) do
    name = "atdd_inv_" <> T.rand(5)

    # registered BEFORE the DDL: if the second statement fails the first one is still cleaned up (both DROPs are IF EXISTS)
    ExUnit.Callbacks.on_exit(fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF #{condition} THEN RAISE EXCEPTION 'atdd: write blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")
  end

  defp safe_uid!(uid) do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, uid)
    uid
  end

  # ═══ AC1: Element's DM request ════════════════════════════════════════════════

  describe "AC1 - Element's DM request works server-side" do
    test "200, B holds a pending invitation, ONE invite event {invite, is_direct true} from A, join rule invite (C is refused), heroes joined 1 / invited 1", %{user: a, other: b, third: c} do
      since_a = sync(a)["next_batch"]
      room = make_room(a, element_dm(b.uid))

      assert {:ok, true} = Nebu.Matrix.Room.InviteDB.pending_invite?(room, b.uid)
      assert [%{sender: sender, content: content}] = member_events(room, b.uid), "exactly ONE m.room.member event with state_key B"
      assert sender == a.uid
      assert content == %{"membership" => "invite", "is_direct" => true}
      assert {:ok, %{joined: 1, invited: 1}} = Nebu.Matrix.Room.DB.get_room_heroes(room, a.uid)

      assert only(room, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert only(room, "m.room.history_visibility") == %{"history_visibility" => "invited"}
      assert only(room, "m.room.guest_access") == %{"guest_access" => "can_join"}
      assert state_events(room, "m.room.encryption") == [], "ADR-011: encryption stays skipped"
      assert join(c, room).status == 403, "a third user without an invitation cannot join"

      # A's incremental /sync carries the invite event in the timeline
      timeline = get_in(sync(a, since_a), ["rooms", "join", room, "timeline", "events"]) || []

      assert Enum.any?(timeline, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid and &1["content"]["membership"] == "invite")),
             "the creator's timeline has the invite event, got #{inspect(Enum.map(timeline, &{&1["type"], &1["state_key"]}))}"
    end

    test "B joins with the invitation (200): member, invitation accepted, latest membership join; A and B both send and read each other's messages", %{user: a, other: b} do
      room = make_room(a, element_dm(b.uid))
      tick()
      join!(b, room)

      assert member?(room, b.uid)
      assert invitation_state(room, b.uid) == :accepted
      assert {:ok, "join"} = latest_membership(room, b.uid)
      assert {:ok, %{joined: 2, invited: 0}} = Nebu.Matrix.Room.DB.get_room_heroes(room, a.uid)

      assert send_message(a, room, "hello from A").status == 200
      assert send_message(b, room, "hello from B").status == 200

      for reader <- [a, b] do
        bodies = message_bodies(reader, room)
        assert "hello from A" in bodies and "hello from B" in bodies, "#{reader.uid} reads both messages, got #{inspect(bodies)}"
      end
    end

    test "after the join B can change state (level 100: PUT m.room.name) and invite a fourth user (D9, trusted_private_chat)", %{user: a, other: b, fourth: d} do
      room = make_room(a, element_dm(b.uid))
      join!(b, room)

      assert put_state(b, room, "m.room.name", %{"name" => "Renamed by B"}).status == 200
      assert invite(b, room, d).status == 200
      assert invitation_state(room, d.uid) == :pending
    end
  end

  # ═══ AC2 ═══════════════════════════════════════════════════════════════════════

  describe "AC2 - group DM / private room with several invitees" do
    test "invite [B, C], invite_3pid [], private_chat, no is_direct: two pending invitations, two events with content exactly membership invite", %{user: a, other: b, third: c} do
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid, c.uid], "invite_3pid" => []})

      for u <- [b, c] do
        assert invitation_state(room, u.uid) == :pending
        assert [%{sender: sender, content: %{"membership" => "invite"} = content}] = invite_events(room, u.uid)
        assert sender == a.uid
        assert content == %{"membership" => "invite"}, "no is_direct key"
      end
    end

    test "invite [B, B, C, B]: exactly one invitation row and ONE invite event per user", %{user: a, other: b, third: c} do
      room = make_room(a, %{"invite" => [b.uid, b.uid, c.uid, b.uid]})

      assert invitation_rows(room) == 2
      assert length(invite_events(room, b.uid)) == 1
      assert length(invite_events(room, c.uid)) == 1
    end

    test "invite [], null and absent write no invitation and no invite event; is_direct true without invite is a 200 without an invite event", %{user: a} do
      for {label, body} <- [absent: %{}, null: %{"invite" => nil}, empty: %{"invite" => []}, direct_without_invite: %{"is_direct" => true}, direct_empty: %{"is_direct" => true, "invite" => []}] do
        room = make_room(a, body)
        assert invitation_rows(room) == 0, to_string(label)

        invites =
          T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND content::text LIKE '%invite%'", [room]).rows

        assert invites == [[0]], "#{label}: no invite event"
      end
    end

    test "is_direct false and null put NO is_direct key on the invite event; true puts it on every one", %{user: a, other: b, third: c} do
      for flag <- [false, nil] do
        room = make_room(a, %{"invite" => [b.uid], "is_direct" => flag})
        assert [%{content: content}] = invite_events(room, b.uid)
        assert content == %{"membership" => "invite"}, "is_direct #{inspect(flag)}"
      end

      room = make_room(a, %{"invite" => [b.uid, c.uid], "is_direct" => true})
      for u <- [b, c], do: assert([%{content: %{"membership" => "invite", "is_direct" => true}}] = invite_events(room, u.uid))
    end
  end

  # ═══ AC3: invite validation ═════════════════════════════════════════════════════

  describe "AC3 - invite validation over the wire (no room, no invitation row in every 4xx case)" do
    test "a non-list invite (string, object, number) and a non-string element ([5], [null], [[id]]) are 400 M_BAD_JSON", %{user: a, other: b} do
      for {label, invite} <- [string: b.uid, object: %{}, number: 5, int_element: [5], null_element: [nil], nested: [[b.uid]], true_element: [true]] do
        assert_rejected(a, %{"invite" => invite}, 400, "M_BAD_JSON", "invite #{label}")
      end
    end

    test "51 distinct valid ids and 51 times the same id are 400 M_INVALID_PARAM (raw count), before any existence read", %{user: a, other: b} do
      distinct = for n <- 1..51, do: "@cap#{n}-#{T.rand(3)}:#{server_name()}"
      assert_rejected(a, %{"invite" => distinct}, 400, "M_INVALID_PARAM", "51 distinct")
      assert_rejected(a, %{"invite" => List.duplicate(b.uid, 51)}, 400, "M_INVALID_PARAM", "51 duplicates")
    end

    test "exactly 50 provisioned invitees are 200 (50 invitations, 50 invite events)", %{user: a} do
      invitees = for _ <- 1..50, do: T.provision_user!()
      room = make_room(a, %{"invite" => invitees, "preset" => "private_chat"})

      assert invitation_rows(room) == 50
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND content::text LIKE '%invite%'", [room]).rows == [[50]]
    end

    test "malformed ids (bob, @Bob:srv, @b, empty) and the creator's own id are 400 M_INVALID_PARAM", %{user: a, other: b} do
      for invite <- [["bob"], ["@Bob:#{server_name()}"], ["@b"], [""], [a.uid], [b.uid, a.uid]] do
        assert_rejected(a, %{"invite" => invite}, 400, "M_INVALID_PARAM", "invite #{inspect(invite)}")
      end
    end

    test "a foreign domain is 403 M_FORBIDDEN; two different foreign ids give BYTE-identical bodies without an echoed id", %{user: a} do
      one = assert_rejected(a, %{"invite" => ["@marker1#{T.rand(3)}:other.example"]}, 403, "M_FORBIDDEN", "foreign 1")
      two = assert_rejected(a, %{"invite" => ["@marker2#{T.rand(3)}:elsewhere.example"]}, 403, "M_FORBIDDEN", "foreign 2")

      assert one.resp_body == two.resp_body, "byte-identical bodies"
      assert T.json(one) == %{"errcode" => "M_FORBIDDEN", "error" => @foreign_text}
      refute one.resp_body =~ "marker"
    end

    test "an unknown and a DEACTIVATED local user are the same 404 M_NOT_FOUND, byte-identical body, no user id echoed", %{user: a, other: b} do
      unknown_uid = "@ghost-#{T.rand(4)}:#{server_name()}"
      # the users of every test are random (T.provision_user!/0), so the deactivated row of this test never leaks into another one
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [safe_uid!(b.uid)])

      unknown = assert_rejected(a, %{"invite" => [unknown_uid]}, 404, "M_NOT_FOUND", "unknown")
      deactivated = assert_rejected(a, %{"invite" => [b.uid]}, 404, "M_NOT_FOUND", "deactivated")

      assert unknown.resp_body == deactivated.resp_body, "no distinction between an unknown and a deactivated account"
      assert T.json(unknown) == %{"errcode" => "M_NOT_FOUND", "error" => @not_found_text}
      refute unknown.resp_body =~ "ghost"
      refute deactivated.resp_body =~ String.slice(b.uid, 1, 12)

      body = T.json(unknown)
      refute body["errcode"] in ["M_FORBIDDEN", "M_USER_NOT_FOUND", "M_USER_DEACTIVATED"]
    end

    test "all-or-nothing: a valid invitee plus a foreign (or unknown) one refuses the whole request, B holds no invitation", %{user: a, other: b} do
      assert_rejected(a, %{"invite" => [b.uid, "@x:other.example"]}, 403, "M_FORBIDDEN", "valid + foreign")
      assert_rejected(a, %{"invite" => [b.uid, "@ghost-#{T.rand(4)}:#{server_name()}"]}, 404, "M_NOT_FOUND", "valid + unknown")
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE invitee_id = $1", [b.uid]).rows == [[0]]
    end

    test "createRoom never provisions a users row for an unknown invitee (the request is refused, no row appears)", %{user: a} do
      ghost = "@ghost-#{T.rand(4)}:#{server_name()}"
      assert_rejected(a, %{"invite" => [ghost]}, 404, "M_NOT_FOUND", "ghost")
      assert T.sql!("SELECT count(*) FROM users WHERE user_id = $1", [ghost]).rows == [[0]]
    end
  end

  # ═══ AC4 / AC5 ═════════════════════════════════════════════════════════════════

  describe "AC4 - invite_3pid over the wire" do
    test "[], null and absent are 200", %{user: a} do
      for body <- [%{"invite_3pid" => []}, %{"invite_3pid" => nil}, %{}], do: make_room(a, body)
    end

    test "a non-list and malformed items are 400 M_BAD_JSON; a missing or non-string required key too", %{user: a} do
      for {label, value} <- [
            string: "x",
            object: %{},
            number: 5,
            int_item: [5],
            null_item: [nil],
            only_medium: [%{"medium" => "email"}],
            no_token: [Map.delete(@well_shaped_3pid, "id_access_token")],
            server_number: [%{@well_shaped_3pid | "id_server" => 5}],
            well_shaped_plus_number: [@well_shaped_3pid, 5]
          ] do
        assert_rejected(a, %{"invite_3pid" => value}, 400, "M_BAD_JSON", "invite_3pid #{label}")
      end
    end

    test "a list of well-shaped items is 403 M_THREEPID_DENIED with the fixed text, no room", %{user: a} do
      conn = assert_rejected(a, %{"invite_3pid" => [@well_shaped_3pid]}, 403, "M_THREEPID_DENIED", "well-shaped")
      assert T.json(conn) == %{"errcode" => "M_THREEPID_DENIED", "error" => @threepid_text}
    end
  end

  describe "AC5 - is_direct (router type check)" do
    test "true, false, null and absent are 200", %{user: a} do
      for body <- [%{"is_direct" => true}, %{"is_direct" => false}, %{"is_direct" => nil}, %{}], do: make_room(a, body)
    end

    test "\"true\", 1, {} and [] are 400 M_BAD_JSON, no room", %{user: a, other: b} do
      for value <- ["true", 1, 0, %{}, [], "false"] do
        assert_rejected(a, %{"is_direct" => value}, 400, "M_BAD_JSON", "is_direct #{inspect(value)}")
        assert_rejected(a, %{"is_direct" => value, "invite" => [b.uid]}, 400, "M_BAD_JSON", "is_direct #{inspect(value)} with invite")
      end
    end
  end

  # ═══ AC7 / AC8 ═════════════════════════════════════════════════════════════════

  describe "AC7 - trusted_private_chat power levels (stored and as enforced)" do
    test "trusted_private_chat + invite [B, C]: users exactly {A, B, C at 100}, one event, rooms.power_levels_json equal", %{user: a, other: b, third: c} do
      room = make_room(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid, c.uid]})
      expected = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{a.uid => 100, b.uid => 100, c.uid => 100})

      assert only(room, "m.room.power_levels") == expected
      assert stored_power_levels(room) == expected
    end

    test "private_chat with the same invites and trusted_private_chat without invite keep users {A: 100}", %{user: a, other: b, third: c} do
      for body <- [%{"preset" => "private_chat", "invite" => [b.uid, c.uid]}, %{"preset" => "trusted_private_chat"}] do
        room = make_room(a, body)
        assert only(room, "m.room.power_levels")["users"] == %{a.uid => 100}
        assert stored_power_levels(room)["users"] == %{a.uid => 100}
      end
    end

    test "an override users map replaces the generated one; events_default 50 keeps the invitees at 100", %{user: a, other: b, third: c} do
      override_users = make_room(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid, c.uid], "power_level_content_override" => %{"users" => %{a.uid => 100}}})
      assert only(override_users, "m.room.power_levels")["users"] == %{a.uid => 100}
      assert invitation_state(override_users, b.uid) == :pending and invitation_state(override_users, c.uid) == :pending

      other = "@x:#{server_name()}"
      with_other = make_room(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid], "power_level_content_override" => %{"users" => %{a.uid => 100, other => 50}}})
      assert only(with_other, "m.room.power_levels")["users"] == %{a.uid => 100, other => 50}, "the invitee is ABSENT"

      events_default = make_room(a, %{"preset" => "trusted_private_chat", "invite" => [b.uid, c.uid], "power_level_content_override" => %{"events_default" => 50}})
      content = only(events_default, "m.room.power_levels")
      assert content["users"] == %{a.uid => 100, b.uid => 100, c.uid => 100}
      assert content["events_default"] == 50
    end
  end

  describe "AC8 - the invite level is part of the creator lock-out (HTTP)" do
    test "override invite 101 + invite is 400 M_INVALID_ROOM_STATE, no room; without invite it is a 200; users 0 + invite 0 + invite is refused", %{user: a, other: b} do
      assert_rejected(a, %{"invite" => [b.uid], "power_level_content_override" => %{"invite" => 101}}, 400, "M_INVALID_ROOM_STATE", "invite 101")
      assert_rejected(a, %{"invite" => [b.uid], "power_level_content_override" => %{"users" => %{a.uid => 0}, "invite" => 0}}, 400, "M_INVALID_ROOM_STATE", "users 0")

      room = make_room(a, %{"power_level_content_override" => %{"invite" => 101}})
      assert only(room, "m.room.power_levels")["invite"] == 101
    end
  end

  # ═══ AC9 ═══════════════════════════════════════════════════════════════════════

  describe "AC9 - first failure (D14 order) over the wire" do
    test "malformed invitee + taken alias is M_INVALID_PARAM; unknown local invitee + taken alias is M_ROOM_IN_USE; foreign + invite 101 is 403", %{user: a, other: b} do
      localpart = "taken-" <> T.rand(4)
      make_room(a, %{"room_alias_name" => localpart})

      assert_rejected(a, %{"room_alias_name" => localpart, "invite" => ["bob"]}, 400, "M_INVALID_PARAM", "malformed + taken alias")
      assert_rejected(a, %{"room_alias_name" => localpart, "invite" => ["@ghost-#{T.rand(4)}:#{server_name()}"]}, 400, "M_ROOM_IN_USE", "unknown + taken alias")
      assert_rejected(a, %{"invite" => ["@x:other.example"], "power_level_content_override" => %{"invite" => 101}}, 403, "M_FORBIDDEN", "foreign + invite 101")
      assert_rejected(a, %{"invite" => ["bob"], "invite_3pid" => [@well_shaped_3pid]}, 400, "M_INVALID_PARAM", "3pid + malformed invite")
      assert_rejected(a, %{"preset" => "bogus", "invite" => ["bob"]}, 400, "M_INVALID_PARAM", "invalid preset + malformed invitee")
      assert_rejected(a, %{"invite" => [b.uid], "invite_3pid" => [@well_shaped_3pid]}, 403, "M_THREEPID_DENIED", "invite + well-shaped 3pid")
    end
  end

  # ═══ AC10: step 8 is fatal, the cleanup works (real DB) ═══════════════════════════

  describe "AC10 - Room.DB.delete_room/1 and the fatal step 8 against the real database" do
    test "delete_room/1 on a room that holds an invitation row returns :ok and removes the row, the events, the members and the room", %{user: a, other: b} do
      room = make_room(a, %{})
      invite!(a, room, b)
      assert invitation_rows(room) == 1

      # what cleanup_orphan_room/1 does first: stop the room process, then delete
      assert {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      GenServer.stop(pid, :normal, 5_000)

      assert :ok = Nebu.Matrix.Room.DB.delete_room(room)

      assert invitation_rows(room) == 0, "the invitation row is deleted with the room (FK room_invitations.room_id)"
      assert T.sql!("SELECT count(*) FROM rooms WHERE room_id = $1", [room]).rows == [[0]]
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room]).rows == [[0]]
      assert T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1", [room]).rows == [[0]]
    end

    test "delete_room/1 also removes accepted and rejected invitation rows, an alias row and a Space (every row kind of a room)", %{user: a, other: b, third: c} do
      alias_localpart = "dr-" <> T.rand(4)

      for {label, body} <- [plain: %{}, aliased: %{"room_alias_name" => alias_localpart}, space: %{"creation_content" => %{"type" => "m.space"}, "preset" => "private_chat"}] do
        room = make_room(a, body)
        invite!(a, room, b)
        join!(b, room)
        assert invitation_state(room, b.uid) == :accepted, "#{label}: an ACCEPTED row"
        invite!(a, room, c)
        tick()
        assert leave(c, room).status == 200
        assert invitation_state(room, c.uid) == :rejected, "#{label}: a REJECTED row"

        assert {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
        GenServer.stop(pid, :normal, 5_000)
        assert :ok = Nebu.Matrix.Room.DB.delete_room(room), "#{label}: delete_room/1 must succeed with accepted + rejected rows"

        for table <- ["room_invitations", "events", "room_members", "rooms"] do
          assert T.sql!("SELECT count(*) FROM #{table} WHERE room_id = $1", [room]).rows == [[0]], "#{label}: #{table} is empty for the room"
        end
      end

      assert T.sql!("SELECT count(*) FROM room_aliases WHERE alias = $1", ["#" <> alias_localpart <> ":" <> server_name()]).rows == [[0]], "the alias row is gone"
    end

    test "delete_room/1 of a room that does not exist is :ok (idempotent), also with the new invitation delete" do
      assert :ok = Nebu.Matrix.Room.DB.delete_room("!never-existed#{T.rand(4)}:#{server_name()}")
    end

    test "a failing invite EVENT write for the second invitee (privileged trigger): 500, no room, NO invitation row for the first invitee", %{user: a, other: b, third: c} do
      block_writes!("events", "NEW.event_type = 'm.room.member' AND NEW.state_key = '#{safe_uid!(c.uid)}' AND position('invite' in NEW.content::text) > 0")
      before = footprint(a.uid)

      conn = create(a, %{"invite" => [b.uid, c.uid], "preset" => "private_chat"})

      assert conn.status == 500, conn.resp_body
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert footprint(a.uid) == before, "the orphan room was cleaned up and no invitation row of the failed request is left (the cleanup deletes room_invitations)"
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE invitee_id IN ($1, $2)", [b.uid, c.uid]).rows == [[0]]
    end

    test "a failing invitation ROW write for the second invitee (privileged trigger): 500, no room, no row for the first invitee", %{user: a, other: b, third: c} do
      block_writes!("room_invitations", "NEW.invitee_id = '#{safe_uid!(c.uid)}'")
      before = footprint(a.uid)

      conn = create(a, %{"invite" => [b.uid, c.uid]})

      assert conn.status == 500, conn.resp_body
      assert footprint(a.uid) == before
    end
  end

  # ═══ AC11: POST /rooms/{roomId}/invite ════════════════════════════════════════════

  describe "AC11 (a)/(b) - a valid invite and the already-invited no-op" do
    test "a valid invite is 200 {} with a pending row and ONE invite event (sender inviter, content exactly membership invite)", %{user: a, other: b} do
      room = make_room(a, %{})
      conn = invite(a, room, b)

      assert conn.status == 200 and conn.resp_body == "{}"
      assert invitation_state(room, b.uid) == :pending
      assert [%{sender: sender, content: content}] = invite_events(room, b.uid)
      assert sender == a.uid
      assert content == %{"membership" => "invite"}
      assert {:ok, "invite"} = latest_membership(room, b.uid), "the latest membership of B is now invite"
    end

    test "the same invite again while pending is 200 {}: no second event, the row's invited_at is unchanged", %{user: a, other: b} do
      room = make_room(a, %{})
      invite!(a, room, b)
      first_row = invitation(room, b.uid)
      tick()

      conn = invite(a, room, b)
      assert conn.status == 200 and conn.resp_body == "{}"
      assert length(invite_events(room, b.uid)) == 1, "no second invite event"
      assert invitation(room, b.uid) == first_row, "no refreshed row (invited_at unchanged)"
    end

    test "a pending row WITHOUT an invite event (an older invitation) is not 'already invited': the invite writes the event now", %{user: a, other: b} do
      room = make_room(a, %{})
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, a.uid, b.uid)
      assert invite_events(room, b.uid) == []

      invite!(a, room, b)
      assert length(invite_events(room, b.uid)) == 1
      assert invitation_state(room, b.uid) == :pending
      assert {:ok, "invite"} = latest_membership(room, b.uid)
    end

    test "after B declined (POST /leave) a new invite is 200: a NEW invite event after the leave event, the row re-armed, B can join", %{user: a, other: b} do
      room = make_room(a, %{})
      invite!(a, room, b)
      tick()
      assert leave(b, room).status == 200
      assert invitation_state(room, b.uid) == :rejected
      tick()

      invite!(a, room, b)

      assert invitation_state(room, b.uid) == :pending, "the row is re-armed"
      assert [first, second] = invite_events(room, b.uid)
      assert second.ts > first.ts
      assert [leave_event] = membership_events(room, b.uid, "leave")
      assert second.ts > leave_event.ts, "the new invite event is newer than the leave event"
      assert {:ok, "invite"} = latest_membership(room, b.uid)
      assert join(b, room).status == 200
    end
  end

  describe "AC11 (c)/(e)/(h) - the body checks of the route, the order of the checks and the Oracle-gate cases" do
    test "(c) the body checks: M_NOT_JSON, M_BAD_JSON, M_MISSING_PARAM and M_INVALID_PARAM (all 400)", %{user: a} do
      room = make_room(a, %{})

      conn = T.raw_request(:post, path(room, "invite"), a.at, "this is not json", "application/json")
      assert conn.status == 400 and T.json(conn)["errcode"] == "M_NOT_JSON", conn.resp_body

      for {label, body, errcode} <- [
            {:empty_list, [], "M_BAD_JSON"},
            {:string, "x", "M_BAD_JSON"},
            {:number, 5, "M_BAD_JSON"},
            {:empty_object, %{}, "M_MISSING_PARAM"},
            {:null_user_id, %{"user_id" => nil}, "M_MISSING_PARAM"},
            {:number_user_id, %{"user_id" => 5}, "M_BAD_JSON"},
            {:list_user_id, %{"user_id" => ["@b:x"]}, "M_BAD_JSON"},
            {:bad_id, %{"user_id" => "bob"}, "M_INVALID_PARAM"},
            {:uppercase_id, %{"user_id" => "@Bob:#{server_name()}"}, "M_INVALID_PARAM"},
            {:empty_user_id, %{"user_id" => ""}, "M_INVALID_PARAM"}
          ] do
        conn = send_invite(a, room, body)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
      end

      assert invitation_rows(room) == 0
    end

    test "the well-shaped 3pid form is 403 M_THREEPID_DENIED; a partial or non-string 3pid body is 400 M_BAD_JSON", %{user: a} do
      room = make_room(a, %{})

      conn = send_invite(a, room, @well_shaped_3pid)
      assert conn.status == 403 and T.json(conn) == %{"errcode" => "M_THREEPID_DENIED", "error" => @threepid_text}

      # a user_id that is null does not select the user-id form: the well-shaped 3pid keys do
      conn = send_invite(a, room, Map.put(@well_shaped_3pid, "user_id", nil))
      assert conn.status == 403 and T.json(conn)["errcode"] == "M_THREEPID_DENIED", conn.resp_body

      for {label, body} <- [
            medium_only: %{"medium" => "email"},
            medium_address: %{"medium" => "email", "address" => "a@b.c"},
            address_number: %{"medium" => "email", "address" => 5, "id_server" => "x", "id_access_token" => "t"},
            token_null_with_rest: %{"medium" => "email", "address" => "a@b.c", "id_server" => "x", "id_access_token" => nil}
          ] do
        conn = send_invite(a, room, body)
        assert conn.status == 400 and T.json(conn)["errcode"] == "M_BAD_JSON", "#{label}: #{conn.status} #{conn.resp_body}"
      end

      assert invitation_rows(room) == 0
    end

    test "the body checks run BEFORE the room checks: a bad body on an unknown room is 400, a good one the room 404", %{user: a, other: b} do
      unknown_room = "!nope#{T.rand(4)}:#{server_name()}"

      assert send_invite(a, unknown_room, %{"user_id" => "bob"}).status == 400
      assert send_invite(a, unknown_room, %{}).status == 400
      conn = invite(a, unknown_room, b)
      assert conn.status == 404
      assert T.json(conn) == %{"errcode" => "M_NOT_FOUND", "error" => "Room not found"}
    end

    test "(e) a NON-member inviting an unknown user gets the inviter 403 (not a member of this room), not the 404", %{user: a, other: b, third: c} do
      room = make_room(a, %{})

      conn = send_invite(b, room, %{"user_id" => "@ghost-#{T.rand(4)}:#{server_name()}"})
      assert conn.status == 403
      assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "You are not a member of this room"}

      assert send_invite(b, room, %{"user_id" => c.uid}).status == 403
      assert invitation_rows(room) == 0
    end

    test "(d) a foreign user is 403, an unknown and a deactivated local user the same 404 body; nothing is written", %{user: a, other: b, third: c} do
      room = make_room(a, %{})
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [safe_uid!(c.uid)])

      foreign = send_invite(a, room, %{"user_id" => "@marker#{T.rand(3)}:other.example"})
      unknown = send_invite(a, room, %{"user_id" => "@ghost-#{T.rand(4)}:#{server_name()}"})
      deactivated = invite(a, room, c)

      assert foreign.status == 403 and T.json(foreign) == %{"errcode" => "M_FORBIDDEN", "error" => @foreign_text}
      refute foreign.resp_body =~ "marker"
      assert unknown.status == 404 and deactivated.status == 404
      assert unknown.resp_body == deactivated.resp_body, "byte-identical"
      assert T.json(unknown) == %{"errcode" => "M_NOT_FOUND", "error" => @not_found_text}
      refute unknown.resp_body =~ "ghost"

      assert invitation_rows(room) == 0
      assert invite_events(room, c.uid) == [] and invite_events(room, b.uid) == []
    end

    test "(l) an unknown user is NEVER M_FORBIDDEN (Element's MultiInviter treats it as fatal for the whole batch)", %{user: a} do
      room = make_room(a, %{})
      conn = send_invite(a, room, %{"user_id" => "@ghost-#{T.rand(4)}:#{server_name()}"})
      assert T.json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "(h) a reason (string or number) is ignored: 200, the invite event content is exactly membership invite", %{user: a, other: b, third: c} do
      room = make_room(a, %{})

      assert send_invite(a, room, %{"user_id" => b.uid, "reason" => "welcome"}).status == 200
      assert send_invite(a, room, %{"user_id" => c.uid, "reason" => 5}).status == 200

      for u <- [b, c] do
        assert [%{content: content}] = invite_events(room, u.uid)
        assert content == %{"membership" => "invite"}
      end
    end

    test "(h) user_id together with the 3pid keys is the user-id form: 200, B is invited", %{user: a, other: b} do
      room = make_room(a, %{})
      body = Map.put(@well_shaped_3pid, "user_id", b.uid)

      assert send_invite(a, room, body).status == 200
      assert invitation_state(room, b.uid) == :pending
      assert length(invite_events(room, b.uid)) == 1
    end
  end

  describe "AC11 (f)/(i)/(j)/(k) - the existing rules, the invite level, re-invites and the decline" do
    test "(f) a member (and a self-invite) is 403 M_FORBIDDEN; a banned target is 403 M_FORBIDDEN, no row and no event", %{user: a, other: b, third: c} do
      room = make_room(a, %{})
      invite!(a, room, b)
      join!(b, room)

      assert invite(a, room, b).status == 403, "a member"
      assert invite(a, room, a).status == 403, "a self-invite"

      ban(room, a, c)
      conn = invite(a, room, c)
      assert conn.status == 403 and T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert invitation(room, c.uid) == nil
      assert invite_events(room, c.uid) == []
    end

    test "(i) an inviter below the invite level (override invite 50, member at level 0) is 403: no row, no event", %{user: a, other: b, third: c} do
      room = make_room(a, %{"preset" => "private_chat", "power_level_content_override" => %{"invite" => 50}})
      invite!(a, room, b)
      join!(b, room)

      conn = invite(b, room, c)
      assert conn.status == 403 and T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert invitation(room, c.uid) == nil
      assert invite_events(room, c.uid) == []
    end

    test "(j) re-invite after a VOLUNTARY leave: 200, a NEW invite event after B's leave event, the row re-armed, B's join is 200", %{user: a, other: b} do
      room = make_room(a, %{})
      invite!(a, room, b)
      tick()
      join!(b, room)
      tick()
      assert leave(b, room).status == 200
      tick()

      invite!(a, room, b)

      assert invitation_state(room, b.uid) == :pending
      assert [first_invite, second_invite] = invite_events(room, b.uid)
      assert [leave_event] = membership_events(room, b.uid, "leave")
      assert first_invite.ts < leave_event.ts and leave_event.ts < second_invite.ts, "invite < leave < new invite"
      assert join(b, room).status == 200
      assert member?(room, b.uid)
    end

    test "(g) a failing invite EVENT write after the row (trigger): 500, the row is rejected again, the invitee's join is 403", %{user: a, third: c} do
      room = make_room(a, %{})
      block_writes!("events", "NEW.event_type = 'm.room.member' AND NEW.state_key = '#{safe_uid!(c.uid)}' AND position('invite' in NEW.content::text) > 0")

      conn = invite(a, room, c)

      assert conn.status == 500, conn.resp_body
      assert invitation_state(room, c.uid) == :rejected, "no half invitation that is joinable but invisible"
      assert invite_events(room, c.uid) == []

      conn = join(c, room)
      assert conn.status == 403
      assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "You are not invited to this room"}
    end

    test "(g) a legacy pending row (no invite event) survives a failing event write: 500, stays pending, joinable", %{user: a, third: c} do
      room = make_room(a, %{})
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, a.uid, c.uid)
      block_writes!("events", "NEW.event_type = 'm.room.member' AND NEW.state_key = '#{safe_uid!(c.uid)}' AND position('invite' in NEW.content::text) > 0")

      conn = invite(a, room, c)

      assert conn.status == 500, conn.resp_body
      assert invitation_state(room, c.uid) == :pending, "an invitation this call did not create is not this call's to reject"
      assert invite_events(room, c.uid) == []
      assert join(c, room).status == 200
    end

    test "(k) the invitee declines (POST /leave): leave event sender == state_key == B after the invite, row rejected, join 403", %{user: a, other: b} do
      room = make_room(a, %{})
      invite!(a, room, b)
      tick()

      assert leave(b, room).status == 200

      assert invitation_state(room, b.uid) == :rejected
      assert [invite_event] = invite_events(room, b.uid)
      assert [%{sender: sender} = leave_event] = membership_events(room, b.uid, "leave")
      assert sender == b.uid, "the leave event is authored by the invitee (sender == state_key)"
      assert leave_event.ts > invite_event.ts

      conn = join(b, room)
      assert conn.status == 403
      assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "You are not invited to this room"}
    end
  end

  # ═══ AC12: the interim sync guard over HTTP ═══════════════════════════════════════

  # story sync-membership-partition (AC16, DELIBERATE re-pin; old -> new per test, below): the interim guard D11 is replaced by the real
  # `rooms.invite` section. The describe is renamed.
  describe "AC12 - the invitee's /sync (rooms.invite)" do
    # old: "no rooms.join and no rooms.invite" (refute both) -> new: rooms.invite present, rooms.join absent
    test "A creates a DM with B: B's incremental sync has rooms.invite.<dm>, not rooms.join.<dm>; after B's join the next sync has it in rooms.join", %{user: a, other: b} do
      since_b = sync(b)["next_batch"]
      room = make_room(a, element_dm(b.uid))

      body = sync(b, since_b)
      refute Map.has_key?(body["rooms"]["join"] || %{}, room), "the invited-only room must not be delivered in rooms.join (it would show as a joined room Element cannot write to)"
      assert Map.has_key?(body["rooms"]["invite"] || %{}, room), "rooms.invite carries the invitation (follow-up ev)"

      tick()
      join!(b, room)

      after_join = sync(b, body["next_batch"])
      timeline = get_in(after_join, ["rooms", "join", room, "timeline", "events"]) || []

      assert Enum.any?(timeline, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid and &1["content"]["membership"] == "join")),
             "after the join the room arrives with B's join event, got #{inspect(Enum.map(timeline, &{&1["type"], &1["state_key"]}))}"

      refute Map.has_key?(after_join["rooms"]["invite"] || %{}, room), "and the invitation is gone"
    end

    # old: "the INITIAL sync does not list the pending room either" -> new: the initial sync lists it in rooms.invite (never in rooms.join)
    test "the invitee's INITIAL sync lists the pending room in rooms.invite (and not in rooms.join)", %{user: a, other: b} do
      room = make_room(a, element_dm(b.uid))

      body = sync(b)
      refute Map.has_key?(body["rooms"]["join"] || %{}, room)
      assert Map.has_key?(body["rooms"]["invite"] || %{}, room)
    end

    # old: "pinned (follow-up ez): a re-invited former member (pending AND left) still gets the room in rooms.join" -> new: rooms.invite ONLY
    test "a re-invited former member (pending AND left) gets rooms.invite only: not rooms.join, not rooms.leave (ez residual closed)", %{user: a, other: b} do
      since_b = sync(b)["next_batch"]
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      join!(b, room)
      tick()
      assert leave(b, room).status == 200
      tick()
      invite!(a, room, b)
      assert invitation_state(room, b.uid) == :pending

      body = sync(b, since_b)

      assert Map.has_key?(body["rooms"]["invite"] || %{}, room), "left + pending: the new invitation"
      refute Map.has_key?(body["rooms"]["join"] || %{}, room), "not in rooms.join any more (the ez pin of the interim state is gone)"
      refute Map.has_key?(body["rooms"]["leave"] || %{}, room), "the leave is superseded by the newer invitation"
    end

    test "the creator's own sync is unchanged: A's incremental sync delivers the room it created, with the invite event", %{user: a, other: b} do
      since_a = sync(a)["next_batch"]
      room = make_room(a, %{"invite" => [b.uid], "preset" => "private_chat"})

      timeline = get_in(sync(a, since_a), ["rooms", "join", room, "timeline", "events"]) || []
      assert Enum.any?(timeline, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid and &1["content"]["membership"] == "invite"))
    end
  end

  # ═══ AC15: Space with invite ═════════════════════════════════════════════════════

  describe "AC15 - the createRoom path works for a Space with invite" do
    test "a Space created with Element's request shape and invite [B]: B is invited into the Space, the Space type is preserved", %{user: a, other: b} do
      room =
        make_room(a, %{
          "name" => "Space #{T.rand(3)}",
          "preset" => "private_chat",
          "creation_content" => %{"type" => "m.space"},
          "power_level_content_override" => %{"events_default" => 100, "invite" => 50},
          "invite" => [b.uid]
        })

      assert invitation_state(room, b.uid) == :pending
      assert [%{content: %{"membership" => "invite"}}] = invite_events(room, b.uid)
      assert only(room, "m.room.create")["type"] == "m.space"
      assert T.sql!("SELECT room_type FROM rooms WHERE room_id = $1", [room]).rows == [["m.space"]]
      assert join(b, room).status == 200
    end
  end
end
