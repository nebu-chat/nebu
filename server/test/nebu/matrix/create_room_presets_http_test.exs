defmodule Nebu.Matrix.CreateRoomPresetsHttpTest do
  @moduledoc """
  Integration tests for story `create-room-presets-power-levels-topic` (epic oauth-broker, follow-ups `ec`, `ef`, `ea`): over HTTP against
  the real supervision tree + PostgreSQL (users and sessions as in `create_room_input_validation_http_test.exs`).

  What only the real stack decides and this file pins:

    * `POST /join` enforces the join rule and bans (the security fix `ec`): who may join a room created with a preset, a legacy room
      without an `m.room.join_rules` event, explicit `invite` / `knock` / `private` / unknown / malformed rules, `restricted` /
      `knock_restricted`, banned / kicked / self-left / rejected-invite users, the fixed 403 body, the 404 of an unknown room.
    * the real InviteDB: a re-invite after an accepted invitation is pending again (the row is unique per (room, user)).
    * the preset events as persisted, `rooms.visibility` + its audit row, the topic as persisted and in `room_summary`, the power levels
      as enforced (events_default / invite) and as stored (`rooms.power_levels_json`).

  Conventions:

    * ban / unban / kick have NO HTTP route in Nebu (verified, `matrix_client_compat_test.exs`): they are driven through
      `Nebu.Matrix.EventDispatcher.Server` with the real Room.Server / Postgres, as the compat suite does.
    * `m.room.member` events carry `origin_server_ts` in milliseconds and the latest membership is read by that timestamp: membership
      changes of the SAME user in one test are separated by `tick/0` (3 ms), which keeps the scenarios deterministic without changing
      what is asserted. (The strict timestamp chain of createRoom itself is asserted in the unit suite with an insertion sequence.)
    * Every rejected createRoom must leave NO room behind (`assert_rejected/5`; it compares the global room count, so this file is
      `async: false` and, like its sibling, depends on no other test creating rooms concurrently).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"
  @forbidden_keys ["errcode", "error"]
  # D1: two fixed texts (story decision, via the opt-in errcode override of Http.map_error for permission_denied): one for a ban, one for
  # EVERY rule refusal (absent / invite / knock / private / unknown / malformed / restricted without a grant); neither names a room, a user or a rule
  @ban_text "You are banned from this room"
  @rule_text "You are not invited to this room"

  setup do
    T.reset_rate_limits()
    prior_writer = Application.fetch_env(:compliance, :audit_writer)
    # config/test.exs installs the no-op audit writer suite-wide; the room_visibility_changed rows are asserted here
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    # many older suites DELETE :server_name on exit: without it the room ids get the "nebu.local" default while the provisioned users are
    # "@...:test.local", and the local-domain check of the Admin force-add refuses them (:foreign_domain). Pin it to the users' domain.
    prior_server_name = Application.fetch_env(:event_dispatcher, :server_name)
    Application.put_env(:event_dispatcher, :server_name, T.server_name())

    on_exit(fn ->
      T.restore_rate_limits()

      case prior_server_name do
        {:ok, name} -> Application.put_env(:event_dispatcher, :server_name, name)
        :error -> Application.delete_env(:event_dispatcher, :server_name)
      end

      case prior_writer do
        {:ok, writer} -> Application.put_env(:compliance, :audit_writer, writer)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end
    end)

    uid = T.provision_user!()
    other_uid = T.provision_user!()
    third_uid = T.provision_user!()

    {:ok,
     user: %{uid: uid, at: T.legacy_session!(uid, "CRPA" <> String.upcase(T.rand(3))).at},
     other: %{uid: other_uid, at: T.legacy_session!(other_uid, "CRPB" <> String.upcase(T.rand(3))).at},
     third: %{uid: third_uid, at: T.legacy_session!(third_uid, "CRPC" <> String.upcase(T.rand(3))).at}}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp server_name, do: Application.get_env(:event_dispatcher, :server_name, "nebu.local")
  defp alias_for(localpart), do: "#" <> localpart <> ":" <> server_name()
  defp enc(room_id), do: URI.encode_www_form(room_id)
  # Waits until the millisecond clock has advanced (at most 50 ms): member events and state PUTs are stamped with the millisecond clock and the
  # latest slot value is read by origin_server_ts, so two writes of one slot in ONE millisecond tie (see the Dev Notes of the story: follow-up
  # row about the tie). This is the smallest wait that makes the scenarios deterministic; it replaces a fixed sleep.
  defp tick do
    start = System.system_time(:millisecond)
    wait_until(fn -> System.system_time(:millisecond) > start end, 50)
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

  defp room_count, do: T.sql!("SELECT count(*) FROM rooms").rows |> hd() |> hd()

  defp assert_rejected(user, body, status, errcode, label) do
    before_rooms = room_count()
    conn = create(user, body)
    assert conn.status == status, "#{label}: expected #{status}, got #{conn.status} #{conn.resp_body}"
    assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
    assert room_count() == before_rooms, "#{label}: a rejected createRoom must not leave a room behind"
    conn
  end

  defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  defp leave(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room)}/leave", user.at)
  defp invite(owner, room, target), do: T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room)}/invite", owner.at, body: %{"user_id" => target.uid})
  defp put_state(user, room, type, body), do: T.matrix_request(:put, "/_matrix/client/v3/rooms/#{enc(room)}/state/#{type}", user.at, body: body)
  defp summary(user, room), do: T.matrix_request(:get, "/_matrix/client/v1/room_summary/" <> enc(room), user.at)

  defp invite!(owner, room, target) do
    c = invite(owner, room, target)
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
  end

  defp join!(user, room) do
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
  end

  # the 403 of a refused join: EXACTLY {"errcode": "M_FORBIDDEN", "error": <fixed text>}, no state in it; `kind` picks the fixed text:
  # :rule (not invited, every rule refusal) or :ban
  defp assert_refused(conn, label, room, kind \\ :rule) do
    assert conn.status == 403, "#{label}: expected 403, got #{conn.status} #{conn.resp_body}"
    body = T.json(conn)
    assert Enum.sort(Map.keys(body)) == @forbidden_keys, "#{label}: exactly errcode + error, got #{inspect(Map.keys(body))}"
    assert body["errcode"] == "M_FORBIDDEN", label
    expected = if kind == :ban, do: @ban_text, else: @rule_text
    assert body["error"] == expected, "#{label}: the fixed #{kind} text, got #{inspect(body["error"])}"
    refute body["error"] =~ room, "#{label}: no room id in the text"
    body["error"]
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

  defp state_events(room_id, type) do
    T.sql!("SELECT state_key, content FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts", [room_id, type]).rows
    |> Enum.map(fn [key, content] -> {key, content_of(content)} end)
  end

  defp contents(room_id, type), do: room_id |> state_events(type) |> Enum.map(&elem(&1, 1))
  defp event_count(room_id, type), do: length(state_events(room_id, type))

  # the ONE event of a type (state_key ""): fails when there is none or several
  defp only(room_id, type) do
    assert [content] = contents(room_id, type), "exactly one #{type} event expected"
    content
  end

  defp senders(room_id, type), do: T.sql!("SELECT sender FROM events WHERE room_id = $1 AND event_type = $2", [room_id, type]).rows |> List.flatten()

  defp member?(room_id, uid), do: T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room_id, uid]).rows == [[1]]

  defp join_event_count(room_id, uid),
    do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 AND content->>'membership' = 'join'", [room_id, uid]).rows |> hd() |> hd()

  # `:pending` | `:accepted` | `:rejected` | `:none` for the (single) invitation row of (room, user)
  defp invitation(room_id, uid) do
    case T.sql!("SELECT accepted_at, rejected_at FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room_id, uid]).rows do
      [] -> :none
      [[nil, nil]] -> :pending
      [[_accepted, nil]] -> :accepted
      [[nil, _rejected]] -> :rejected
    end
  end

  defp room_visibility(room_id), do: T.sql!("SELECT visibility FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd()
  defp stored_power_levels(room_id), do: T.sql!("SELECT power_levels_json FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd() |> content_of()
  defp visibility_audit(room_id), do: T.sql!("SELECT actor_user_id, metadata FROM audit_log WHERE action = 'room_visibility_changed' AND target_id = $1", [room_id]).rows

  defp alias_owner(alias_str) do
    case T.sql!("SELECT room_id FROM room_aliases WHERE alias = $1", [alias_str]).rows do
      [[room_id]] -> room_id
      [] -> nil
    end
  end

  defp rule_entry(content), do: %{"type" => "m.room.join_rules", "state_key" => "", "content" => content}
  defp space_body(extra \\ %{}), do: Map.merge(%{"name" => "Space #{T.rand(3)}", "preset" => "public_chat", "creation_content" => %{"type" => "m.space"}}, extra)
  defp allow_space(space), do: [%{"type" => "m.room_membership", "room_id" => space}]

  # ═══ AC1: the join rule is enforced ═══════════════════════════════════════════

  describe "AC1(a)/(c) - rooms without a preset or with a private preset are invite-only" do
    test "no preset, no visibility: B's join is 403, no join event; after A invites B the join is 200 and the invitation accepted", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Private #{T.rand(3)}"})

      assert_refused(join(b, room), "without an invite", room)
      refute member?(room, b.uid)
      assert join_event_count(room, b.uid) == 0

      invite!(a, room, b)
      assert invitation(room, b.uid) == :pending

      conn = join(b, room)
      assert conn.status == 200, conn.resp_body
      assert T.json(conn)["room_id"] == room
      assert member?(room, b.uid)
      assert invitation(room, b.uid) == :accepted
    end

    test "trusted_private_chat, private_chat and visibility private are 403 without an invite", %{user: a, other: b} do
      for {label, body} <- [
            trusted: %{"preset" => "trusted_private_chat"},
            private_chat: %{"preset" => "private_chat"},
            visibility_private: %{"visibility" => "private"},
            visibility_public_but_private_chat: %{"visibility" => "public", "preset" => "private_chat"},
            visibility_public_but_trusted: %{"visibility" => "public", "preset" => "trusted_private_chat"}
          ] do
        room = make_room(a, Map.put(body, "name", "R #{label}"))
        assert_refused(join(b, room), to_string(label), room)
        refute member?(room, b.uid), "#{label}: not a member"
      end
    end
  end

  describe "AC1(b) - public rooms are open" do
    test "preset public_chat and visibility public without a preset: B joins without an invite", %{user: a, other: b, third: c} do
      public_chat = make_room(a, %{"name" => "Public chat", "preset" => "public_chat"})
      assert join(b, public_chat).status == 200
      assert member?(public_chat, b.uid)

      by_visibility = make_room(a, %{"name" => "By visibility", "visibility" => "public"})
      assert join(c, by_visibility).status == 200
      assert member?(by_visibility, c.uid)
    end

    test "a public_chat room is previewable by a non-member (room_summary 200, join_rule public); a private room is not (404 M_NOT_FOUND)", %{user: a, other: b} do
      public_chat = make_room(a, %{"name" => "Previewable", "preset" => "public_chat"})
      private = make_room(a, %{"name" => "Hidden"})

      conn = summary(b, public_chat)
      assert conn.status == 200, conn.resp_body
      assert T.json(conn)["join_rule"] == "public"

      conn = summary(b, private)
      assert conn.status == 404, conn.resp_body
      assert T.json(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  describe "AC1(d) - a LEGACY room without any m.room.join_rules event is invite-only" do
    test "the state of a room created before this story (join_rules rows deleted): 403 without an invite, 200 with one", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Legacy #{T.rand(3)}"})

      # Every room created after this story HAS a join_rules event, so the legacy state is set up like the story says: delete the rows.
      # The join path reads the state from the database, not from the GenServer, so no restart is needed.
      T.sql!("DELETE FROM events WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [room])
      assert event_count(room, "m.room.join_rules") == 0

      assert_refused(join(b, room), "legacy, no invite", room)
      refute member?(room, b.uid)

      invite!(a, room, b)
      assert join(b, room).status == 200
      assert member?(room, b.uid)
    end
  end

  describe "AC1(e) - explicit rules" do
    test "invite and knock: 403 without an invite, 200 with a pending invite", %{user: a, other: b, third: c} do
      for {rule, user} <- [{"invite", b}, {"knock", c}] do
        room = make_room(a, %{"name" => "Rule #{rule}", "initial_state" => [rule_entry(%{"join_rule" => rule})]})
        assert_refused(join(user, room), "#{rule} without an invite", room)
        refute member?(room, user.uid)

        invite!(a, room, user)
        assert join(user, room).status == 200, "#{rule} with an invite"
        assert member?(room, user.uid)
      end
    end

    test "private, \"foo\", \"\", 5 and content {}: 403 WITHOUT and WITH a pending invite (strict room v10)", %{user: a, other: b} do
      for {label, content} <- [private: %{"join_rule" => "private"}, unknown: %{"join_rule" => "foo"}, empty: %{"join_rule" => ""}, number: %{"join_rule" => 5}, empty_content: %{}] do
        room = make_room(a, %{"name" => "Deny #{label}", "initial_state" => [rule_entry(content)]})

        assert_refused(join(b, room), "#{label} without an invite", room)
        invite!(a, room, b)
        assert_refused(join(b, room), "#{label} WITH a pending invite", room)

        refute member?(room, b.uid), "#{label}: not a member"
        assert invitation(room, b.uid) == :pending, "#{label}: the invitation was not consumed"
      end
    end

    test "an undecodable m.room.join_rules content (a JSON string in the database): 403 WITHOUT and WITH a pending invite", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Undecodable", "initial_state" => [rule_entry(%{"join_rule" => "public"})]})
      T.sql!("UPDATE events SET content = to_jsonb($2::text) WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [room, "this is not json"])

      assert_refused(join(b, room), "undecodable without an invite", room)
      invite!(a, room, b)
      assert_refused(join(b, room), "undecodable with an invite", room)
      refute member?(room, b.uid)
    end

    test "a member of an invite-only room joining again is 200 and writes no second join event", %{user: a} do
      room = make_room(a, %{"name" => "Own room"})
      before_joins = join_event_count(room, a.uid)

      conn = join(a, room)
      assert conn.status == 200, conn.resp_body
      assert T.json(conn)["room_id"] == room
      assert join_event_count(room, a.uid) == before_joins
    end
  end

  describe "AC1(e) - restricted / knock_restricted" do
    test "knock_restricted: a member of the allow-room joins (200), a stranger without an invite does not (403); an invite always works", %{user: a, other: b, third: c} do
      space = make_room(a, space_body())
      join!(b, space)

      room =
        make_room(a, %{
          "name" => "Knock restricted",
          "initial_state" => [rule_entry(%{"join_rule" => "knock_restricted", "allow" => allow_space(space)})]
        })

      assert join(b, room).status == 200, "member of the allow-room"
      assert member?(room, b.uid)

      assert_refused(join(c, room), "stranger", room)
      refute member?(room, c.uid)

      invite!(a, room, c)
      assert join(c, room).status == 200, "a pending invite overrides"
    end
  end

  describe "AC1(g) - the refusal reveals no state" do
    test "the 403 body of a rule refusal and of a ban refusal is exactly {errcode, error} (fixed text); a rule refusal says the same for invite / private / unknown rules", %{user: a, other: b, third: c} do
      texts =
        for {label, content} <- [invite: %{"join_rule" => "invite"}, private: %{"join_rule" => "private"}, unknown: %{"join_rule" => "secret-rule-#{T.rand(3)}"}] do
          room = make_room(a, %{"name" => "Body #{label}", "initial_state" => [rule_entry(content)]})
          assert_refused(join(b, room), to_string(label), room)
        end

      assert Enum.uniq(texts) |> length() == 1, "one fixed text for every rule refusal: #{inspect(texts)}"
      refute hd(texts) =~ "secret-rule"

      # ban
      room = make_room(a, %{"name" => "Body ban", "preset" => "public_chat"})
      join!(c, room)
      moderate(:ban, room, a, c)
      text = assert_refused(join(c, room), "banned", room, :ban)
      refute text =~ c.uid
      refute text == hd(texts), "the ban text differs from the rule text"
    end

    test "an unknown room id stays 404 M_NOT_FOUND", %{other: b} do
      conn = join(b, "!doesnotexist#{T.rand(4)}:#{server_name()}")
      assert conn.status == 404, conn.resp_body
      assert T.json(conn)["errcode"] == "M_NOT_FOUND"
    end
  end

  # ═══ AC2: bans, kicks, leaves, rejected invites ═══════════════════════════════

  describe "AC2(a) - a banned user cannot join" do
    test "public_chat: join, ban, join again is 403; after unban 200", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Ban public", "preset" => "public_chat"})
      join!(b, room)
      tick()
      moderate(:ban, room, a, b)
      refute member?(room, b.uid)
      tick()

      assert_refused(join(b, room), "banned in a public room", room, :ban)
      refute member?(room, b.uid)

      tick()
      moderate(:unban, room, a, b)
      tick()
      assert join(b, room).status == 200, "after unban a public room is open again"
    end

    test "invite room: invite, join, ban, join is 403 (and a banned user cannot be re-invited); after unban still 403 without a NEW invite, 200 with one", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Ban invite"})
      invite!(a, room, b)
      join!(b, room)
      tick()
      moderate(:ban, room, a, b)
      tick()

      assert_refused(join(b, room), "banned in an invite room", room, :ban)

      tick()
      moderate(:unban, room, a, b)
      tick()
      assert_refused(join(b, room), "unbanned WITHOUT a new invite", room)
      refute member?(room, b.uid)

      invite!(a, room, b)
      assert invitation(room, b.uid) == :pending, "a new invite creates a pending invitation again"
      assert join(b, room).status == 200, "unbanned AND invited again"
      assert member?(room, b.uid)
    end

    test "restricted and knock_restricted rooms: a banned user who is still a member of the allow-room is refused", %{user: a, other: b} do
      space = make_room(a, space_body())
      join!(b, space)

      for rule <- ["restricted", "knock_restricted"] do
        room = make_room(a, %{"name" => "Ban #{rule}", "initial_state" => [rule_entry(%{"join_rule" => rule, "allow" => allow_space(space)})]})
        assert join(b, room).status == 200, "#{rule}: member of the allow-room joins"
        tick()
        moderate(:ban, room, a, b)
        tick()

        assert_refused(join(b, room), "#{rule} + ban + allow-room member", room, :ban)
        refute member?(room, b.uid)
      end
    end

    test "inviting a banned user is 403 M_FORBIDDEN, writes no invitation row, and the user's join stays 403", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Invite banned", "preset" => "public_chat"})
      join!(b, room)
      tick()
      moderate(:ban, room, a, b)
      tick()

      conn = invite(a, room, b)
      assert conn.status == 403, conn.resp_body
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      refute T.json(conn)["error"] =~ b.uid
      assert invitation(room, b.uid) in [:none, :rejected], "no pending invitation for a banned user"

      assert_refused(join(b, room), "still banned", room, :ban)
    end
  end

  describe "AC2(b) - kicked, self-left and rejected-invite users" do
    test "kicked: 403 in an invite room without a new invite, 200 in a public room", %{user: a, other: b} do
      invite_room = make_room(a, %{"name" => "Kick invite"})
      invite!(a, invite_room, b)
      join!(b, invite_room)
      tick()
      moderate(:kick, invite_room, a, b)
      tick()
      assert_refused(join(b, invite_room), "kicked from an invite room", invite_room)

      public = make_room(a, %{"name" => "Kick public", "preset" => "public_chat"})
      join!(b, public)
      tick()
      moderate(:kick, public, a, b)
      tick()
      assert join(b, public).status == 200, "kicked from a public room may come back"
    end

    test "self-left: 403 in an invite room (200 after a new invite), 200 in a public room", %{user: a, other: b} do
      invite_room = make_room(a, %{"name" => "Left invite"})
      invite!(a, invite_room, b)
      join!(b, invite_room)
      tick()
      assert leave(b, invite_room).status == 200
      tick()
      assert_refused(join(b, invite_room), "self-left without a new invite", invite_room)

      invite!(a, invite_room, b)
      assert join(b, invite_room).status == 200, "a new invite after a leave works (the InviteDB row is pending again)"
      assert member?(invite_room, b.uid)

      public = make_room(a, %{"name" => "Left public", "preset" => "public_chat"})
      join!(b, public)
      tick()
      assert leave(b, public).status == 200
      tick()
      assert join(b, public).status == 200
    end

    test "a REJECTED invite: join is 403 in an invite room, 200 in a public room", %{user: a, other: b} do
      invite_room = make_room(a, %{"name" => "Rejected invite"})
      invite!(a, invite_room, b)
      assert leave(b, invite_room).status == 200, "declining the invite"
      assert invitation(invite_room, b.uid) == :rejected
      tick()
      assert_refused(join(b, invite_room), "rejected invite", invite_room)
      refute member?(invite_room, b.uid)

      public = make_room(a, %{"name" => "Rejected public", "preset" => "public_chat"})
      invite!(a, public, b)
      assert leave(b, public).status == 200
      tick()
      assert join(b, public).status == 200
    end

    test "invite -> join -> leave -> invite again: the second invitation is PENDING again (the row must be re-armed)", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Re-invite"})
      invite!(a, room, b)
      join!(b, room)
      assert invitation(room, b.uid) == :accepted
      tick()
      assert leave(b, room).status == 200
      tick()

      invite!(a, room, b)
      assert invitation(room, b.uid) == :pending
    end
  end

  # ═══ AC2 + the real InviteDB: a new invite re-arms an accepted / rejected invitation ═══════════════════════════════

  describe "AC2 - the real InviteDB re-arms an existing invitation row (one row per room and user)" do
    alias Nebu.Matrix.Room.InviteDB

    test "insert, accept, insert again: pending_invite? is true again and the room is in get_pending_invite_rooms_for_user", %{user: a, other: b} do
      room = make_room(a, %{"name" => "InviteDB accepted"})

      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)
      assert {:ok, true} = InviteDB.pending_invite?(room, b.uid)
      assert :ok = InviteDB.accept_invitation(room, b.uid)
      assert {:ok, false} = InviteDB.pending_invite?(room, b.uid)
      assert {:ok, rooms} = InviteDB.get_pending_invite_rooms_for_user(b.uid)
      refute room in rooms

      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)
      assert {:ok, true} = InviteDB.pending_invite?(room, b.uid), "the accepted invitation is pending again"
      assert {:ok, rooms} = InviteDB.get_pending_invite_rooms_for_user(b.uid)
      assert room in rooms
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room, b.uid]).rows == [[1]], "still one row per (room, user)"
    end

    test "insert, reject, insert again (by another inviter): pending again, the inviter is the new one", %{user: a, other: b, third: c} do
      room = make_room(a, %{"name" => "InviteDB rejected"})
      invite!(a, room, c)
      join!(c, room)

      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)
      assert :ok = InviteDB.reject_invitation(room, b.uid)
      assert {:ok, false} = InviteDB.pending_invite?(room, b.uid)

      assert :ok = InviteDB.insert_invitation(room, c.uid, b.uid)
      assert {:ok, true} = InviteDB.pending_invite?(room, b.uid)
      assert T.sql!("SELECT inviter_id FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room, b.uid]).rows == [[c.uid]]
    end

    test "insert twice while pending: still one pending row, no error", %{user: a, other: b} do
      room = make_room(a, %{"name" => "InviteDB twice"})
      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)
      assert :ok = InviteDB.insert_invitation(room, a.uid, b.uid)
      assert {:ok, true} = InviteDB.pending_invite?(room, b.uid)
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room, b.uid]).rows == [[1]]
    end

    test "kick -> a NEW invite -> join is 200 in an invite-only room", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Kick then re-invite"})
      invite!(a, room, b)
      join!(b, room)
      tick()
      moderate(:kick, room, a, b)
      tick()
      assert_refused(join(b, room), "kicked, no new invite", room)

      invite!(a, room, b)
      assert join(b, room).status == 200
      assert member?(room, b.uid)
    end

    # story sync-membership-partition (AC16, DELIBERATE rewrite of the DEV NOTE of story create-room-presets-power-levels-topic): that note said
    # the HTTP /sync did NOT serve a `rooms.invite` section at all (`Nebu.Matrix.Http.sync_response/3` always emitted `"invite" => %{}`, the
    # documented deferred gap MINOR-2), so the re-arm could only be asserted on the data the sync reads (the pending-invite rooms). The gap
    # is closed: the real `rooms.invite` section exists, and the re-armed invitation is asserted there as well (the assertions on the
    # pending-invite rooms stay).
    test "a re-invited user has the room in the pending-invite rooms the sync reads (invite -> join -> leave -> invite)", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Sync re-invite"})
      invite!(a, room, b)
      join!(b, room)
      tick()
      assert leave(b, room).status == 200
      tick()

      assert {:ok, rooms} = Nebu.Matrix.Room.InviteDB.get_pending_invite_rooms_for_user(b.uid)
      refute room in rooms, "after the leave the accepted invitation is not pending"

      invite!(a, room, b)
      assert {:ok, rooms} = Nebu.Matrix.Room.InviteDB.get_pending_invite_rooms_for_user(b.uid)
      assert room in rooms, "the new invitation is pending again (re-armed row)"

      # the section itself (story sync-membership-partition): a fresh initial sync of B lists the re-armed invitation in rooms.invite
      conn = T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0", b.at)
      assert conn.status == 200, conn.resp_body
      assert Map.has_key?(T.json(conn)["rooms"]["invite"] || %{}, room), "the re-armed invitation is in rooms.invite"
    end

    test "admin force-add of a FORMER member of a private room: invite -> join -> admin remove -> admin force-add works", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Admin re-add"})
      invite!(a, room, b)
      join!(b, room)
      assert member?(room, b.uid)

      assert :ok = Nebu.Matrix.admin_remove_room_member(room, b.uid, a.uid)
      refute member?(room, b.uid)
      tick()

      assert {:ok, ^room} = Nebu.Matrix.admin_add_room_member(room, b.uid, a.uid)
      assert member?(room, b.uid)
    end
  end

  # ═══ AC3: presets, Element shapes ═════════════════════════════════════════════

  describe "AC3 - preset events as persisted" do
    test "each preset: exactly the D2 events, sender = creator", %{user: a} do
      for {label, body, {rule, history, guest}} <- [
            {"default", %{}, {"invite", "shared", "can_join"}},
            {"private_chat", %{"preset" => "private_chat"}, {"invite", "shared", "can_join"}},
            {"trusted_private_chat", %{"preset" => "trusted_private_chat"}, {"invite", "shared", "can_join"}},
            {"public_chat", %{"preset" => "public_chat"}, {"public", "shared", "forbidden"}},
            {"visibility public", %{"visibility" => "public"}, {"public", "shared", "forbidden"}},
            {"visibility private", %{"visibility" => "private"}, {"invite", "shared", "can_join"}}
          ] do
        room = make_room(a, Map.put(body, "name", "Preset #{label}"))
        assert only(room, "m.room.join_rules") == %{"join_rule" => rule}, label
        assert only(room, "m.room.history_visibility") == %{"history_visibility" => history}, label
        assert only(room, "m.room.guest_access") == %{"guest_access" => guest}, label

        for type <- ["m.room.join_rules", "m.room.history_visibility", "m.room.guest_access"] do
          assert senders(room, type) == [a.uid], "#{label}: #{type} sender"
          assert [{"", _}] = state_events(room, type), "#{label}: #{type} state_key"
        end
      end
    end

    test "Element's private-room request (guest_access can_join, history_visibility invited, encryption): invite, the entries win, one event of each type, no m.room.encryption", %{user: a} do
      room =
        make_room(a, %{
          "name" => "Element private",
          "preset" => "private_chat",
          "visibility" => "private",
          "initial_state" => [
            %{"type" => "m.room.guest_access", "state_key" => "", "content" => %{"guest_access" => "can_join"}},
            %{"type" => "m.room.history_visibility", "state_key" => "", "content" => %{"history_visibility" => "invited"}},
            %{"type" => "m.room.encryption", "state_key" => "", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}}
          ]
        })

      assert only(room, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert only(room, "m.room.history_visibility") == %{"history_visibility" => "invited"}
      assert only(room, "m.room.guest_access") == %{"guest_access" => "can_join"}
      assert event_count(room, "m.room.encryption") == 0
    end

    test "Element's public-room request (preset public_chat, visibility public, room_alias_name): public / shared / forbidden, the alias as before, rooms.visibility public", %{user: a} do
      localpart = "elem-public-" <> T.rand(4)
      room = make_room(a, %{"name" => "Element public", "preset" => "public_chat", "visibility" => "public", "room_alias_name" => localpart})

      assert only(room, "m.room.join_rules") == %{"join_rule" => "public"}
      assert only(room, "m.room.history_visibility") == %{"history_visibility" => "shared"}
      assert only(room, "m.room.guest_access") == %{"guest_access" => "forbidden"}
      assert contents(room, "m.room.canonical_alias") == [%{"alias" => alias_for(localpart)}]
      assert alias_owner(alias_for(localpart)) == room
      assert room_visibility(room) == "public"
    end

    test "an initial_state join_rules entry with a NON-EMPTY state_key does not suppress the preset join rule; an entry with state_key \"\" replaces it", %{user: a, other: b} do
      room =
        make_room(a, %{
          "name" => "Keyed entry",
          "preset" => "private_chat",
          "initial_state" => [%{"type" => "m.room.join_rules", "state_key" => "some-key", "content" => %{"join_rule" => "public"}}]
        })

      assert {"", %{"join_rule" => "invite"}} in state_events(room, "m.room.join_rules")
      assert {"some-key", %{"join_rule" => "public"}} in state_events(room, "m.room.join_rules")
      assert_refused(join(b, room), "the room is still invite-only", room)

      replaced = make_room(a, %{"name" => "Replaced", "preset" => "private_chat", "initial_state" => [rule_entry(%{"join_rule" => "public"})]})
      assert contents(replaced, "m.room.join_rules") == [%{"join_rule" => "public"}]
      assert join(b, replaced).status == 200
    end

    test "the personal self-room has no join_rules event and is invite-only: another user's join is 403", %{user: a, other: b} do
      # the personal room is written straight to the database at the first login (no createRoom); it has no join_rules event
      :ok = Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning(a.uid, false)
      room = await_personal_room(a.uid)

      assert event_count(room, "m.room.join_rules") == 0, "the personal room is unchanged: no preset events"

      # the room GenServer starts on the owner's first sync; the join of another user must not get in
      assert T.sync(a.at).status == 200
      assert_refused(join(b, room), "personal room", room)
      refute member?(room, b.uid)
    end
  end

  defp await_personal_room(user_id) do
    lookup = fn -> T.sql!("SELECT personal_room_id FROM users WHERE user_id = $1", [user_id]).rows end
    assert wait_until(fn -> match?([[room_id]] when is_binary(room_id), lookup.()) end, 200) == :ok, "the personal room of #{user_id} was not created"
    [[room_id]] = lookup.()
    room_id
  end

  # ═══ AC4 (HTTP side, non-strict) ══════════════════════════════════════════════

  describe "AC4 - what a client sees" do
    # origin_server_ts is millisecond-granular, so the HTTP test can only show the outcome, not the strict order (the unit suite
    # create_room_presets_test.exs pins the strict chain with an insertion sequence). Before the timestamp chain (D3) an initial_state
    # topic emitted in the SAME millisecond as the top-level one could be the one /sync shows.
    # SMOKE test only: it can pass by luck of the millisecond before D3; the unit chain tests are the guard.
    test "smoke: the top-level topic is the m.room.topic /sync shows, also when an initial_state topic entry exists", %{user: a} do
      room =
        make_room(a, %{
          "name" => "Topic wins",
          "topic" => "Top level topic",
          "initial_state" => [%{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "Entry topic"}}]
        })

      state_events = get_in(T.json(T.sync(a.at)), ["rooms", "join", room, "state", "events"]) || []
      assert [event] = Enum.filter(state_events, &(&1["type"] == "m.room.topic"))
      assert event["content"]["topic"] == "Top level topic"
      assert (T.json(summary(a, room)))["topic"] == "Top level topic"
    end
  end

  # ═══ AC5 ══════════════════════════════════════════════════════════════════════

  describe "AC5 - preset / visibility validation over HTTP" do
    test "unknown strings are 400 M_INVALID_PARAM, wrong types 400 M_BAD_JSON, null is the default; no room in the 4xx cases", %{user: a} do
      for {key, value} <- [{"preset", "private"}, {"preset", "Public_Chat"}, {"preset", ""}, {"visibility", "hidden"}, {"visibility", ""}] do
        assert_rejected(a, %{key => value}, 400, "M_INVALID_PARAM", "#{key} #{inspect(value)}")
      end

      for {key, value} <- [{"preset", 5}, {"preset", true}, {"preset", %{}}, {"visibility", 1}, {"visibility", []}] do
        assert_rejected(a, %{key => value}, 400, "M_BAD_JSON", "#{key} #{inspect(value)}")
      end

      for key <- ["preset", "visibility"] do
        room = make_room(a, %{key => nil, "name" => "null #{key}"})
        assert only(room, "m.room.join_rules") == %{"join_rule" => "invite"}
      end
    end

    test "D11 first failure: an invalid preset with a taken room_alias_name is M_INVALID_PARAM", %{user: a} do
      localpart = "d11-" <> T.rand(4)
      first = make_room(a, %{"room_alias_name" => localpart})
      assert alias_owner(alias_for(localpart)) == first

      assert_rejected(a, %{"preset" => "bogus", "room_alias_name" => localpart}, 400, "M_INVALID_PARAM", "invalid preset + taken alias")
      assert_rejected(a, %{"room_alias_name" => localpart}, 400, "M_ROOM_IN_USE", "taken alias alone")
    end
  end

  # ═══ AC6 ══════════════════════════════════════════════════════════════════════

  describe "AC6 - visibility is stored through the audited path" do
    test "visibility public: rooms.visibility 'public' and ONE room_visibility_changed row with the creator as actor; private / absent: 'private', no row", %{user: a} do
      public = make_room(a, %{"name" => "Listed", "visibility" => "public"})
      assert room_visibility(public) == "public"
      assert [[actor, metadata]] = visibility_audit(public)
      assert actor == a.uid
      assert content_of(metadata) == %{"visibility" => "public"}

      for body <- [%{"visibility" => "private"}, %{}] do
        room = make_room(a, Map.put(body, "name", "Unlisted"))
        assert room_visibility(room) == "private"
        assert visibility_audit(room) == []
      end
    end

    test "visibility public + private_chat: the flag is public, the join rule stays invite", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Listed but private", "visibility" => "public", "preset" => "private_chat"})
      assert room_visibility(room) == "public"
      assert only(room, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert_refused(join(b, room), "listed but invite-only", room)
    end

    test "the Admin path: create_room visibility public is a public room with ONE audit row; private / default / create_space are invite", %{user: a, other: b} do
      assert {:ok, room} = Nebu.Matrix.create_room(a.uid, name: "Admin public #{T.rand(3)}", visibility: "public")
      assert only(room, "m.room.join_rules") == %{"join_rule" => "public"}
      assert room_visibility(room) == "public"
      assert [[actor, _metadata]] = visibility_audit(room)
      assert actor == a.uid
      assert join(b, room).status == 200, "an Admin 'Public' room is really public now"

      for opts <- [[visibility: "private"], []] do
        assert {:ok, private} = Nebu.Matrix.create_room(a.uid, [name: "Admin private #{T.rand(3)}"] ++ opts)
        assert only(private, "m.room.join_rules") == %{"join_rule" => "invite"}
        assert room_visibility(private) == "private"
        assert visibility_audit(private) == []
      end

      before_rooms = room_count()
      assert {:error, :invalid_visibility} = Nebu.Matrix.create_room(a.uid, name: "Bogus", visibility: "bogus")
      assert room_count() == before_rooms

      assert {:ok, space} = Nebu.Matrix.create_space(a.uid, "Admin space #{T.rand(3)}")
      assert only(space, "m.room.join_rules") == %{"join_rule" => "invite"}
    end
  end

  # ═══ AC7 / AC8: topic ═════════════════════════════════════════════════════════

  describe "AC7 - the top-level topic over HTTP" do
    test "topic \"Weekly sync\": m.room.topic content exactly, sender the creator, room_summary shows it; rooms.topic stays untouched", %{user: a} do
      room = make_room(a, %{"name" => "Weekly", "topic" => "Weekly sync"})

      assert only(room, "m.room.topic") == %{"topic" => "Weekly sync", "m.topic" => %{"m.text" => [%{"body" => "Weekly sync", "mimetype" => "text/plain"}]}}
      assert senders(room, "m.room.topic") == [a.uid]
      assert T.json(summary(a, room))["topic"] == "Weekly sync"
      assert T.sql!("SELECT topic FROM rooms WHERE room_id = $1", [room]).rows == [[""]], "D9: rooms.topic is not written"
    end

    test "topic \"\" overrides an initial_state topic entry: the current topic is {\"topic\": \"\"}, the summary shows none; topic absent keeps the entry", %{user: a} do
      entry = %{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "Entry topic"}}

      cleared = make_room(a, %{"name" => "Cleared", "topic" => "", "initial_state" => [entry]})
      assert {"", %{"topic" => ""}} in state_events(cleared, "m.room.topic")
      refute Map.has_key?(T.json(summary(a, cleared)), "topic")

      kept = make_room(a, %{"name" => "Kept", "initial_state" => [entry]})
      assert contents(kept, "m.room.topic") == [%{"topic" => "Entry topic"}]
      assert T.json(summary(a, kept))["topic"] == "Entry topic"
    end

    test "topic null is 400 M_BAD_JSON (unlike name), as are \"a\\u0000b\", 42, true and {}; 1025 code points are 400 M_INVALID_PARAM, 1024 are 200; no room in any 4xx", %{user: a} do
      assert_rejected(a, %{"topic" => nil}, 400, "M_BAD_JSON", "topic null")

      for {label, topic} <- [nul: "a\u0000b", number: 42, boolean: true, object: %{}] do
        assert_rejected(a, %{"topic" => topic}, 400, "M_BAD_JSON", "topic #{label}")
      end

      assert_rejected(a, %{"topic" => String.duplicate("t", 1025)}, 400, "M_INVALID_PARAM", "1025 code points")

      room = make_room(a, %{"topic" => String.duplicate("ä", 1024)})
      assert only(room, "m.room.topic")["topic"] == String.duplicate("ä", 1024)
    end
  end

  describe "AC8 - the topic content rule over HTTP (initial_state and PUT)" do
    test "PUT m.room.topic: {\"topic\": \"\"}, {} and {\"topic\": null} are 200", %{user: a} do
      room = make_room(a, %{"name" => "PUT topic"})

      for content <- [%{"topic" => ""}, %{}, %{"topic" => nil}] do
        conn = put_state(a, room, "m.room.topic", content)
        assert conn.status == 200, "#{inspect(content)}: #{conn.status} #{conn.resp_body}"
      end
    end

    test "PUT m.room.topic: bad topic / m.topic types are 400 M_BAD_JSON, 1025 / 4097 code points 400 M_INVALID_PARAM; nothing persisted", %{user: a} do
      room = make_room(a, %{"name" => "PUT topic rejected"})
      before_events = event_count(room, "m.room.topic")

      for {label, body, errcode} <- [
            {"number", %{"topic" => 42}, "M_BAD_JSON"},
            {"1025", %{"topic" => String.duplicate("t", 1025)}, "M_INVALID_PARAM"},
            {"m.topic string", %{"topic" => "t", "m.topic" => "x"}, "M_BAD_JSON"},
            {"m.text string", %{"topic" => "t", "m.topic" => %{"m.text" => "x"}}, "M_BAD_JSON"},
            {"m.text [5]", %{"topic" => "t", "m.topic" => %{"m.text" => [5]}}, "M_BAD_JSON"},
            {"body 5", %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => 5}]}}, "M_BAD_JSON"},
            {"mimetype 5", %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => "a", "mimetype" => 5}]}}, "M_BAD_JSON"},
            {"body 4097", %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => String.duplicate("b", 4097)}]}}, "M_INVALID_PARAM"}
          ] do
        conn = put_state(a, room, "m.room.topic", body)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
        assert event_count(room, "m.room.topic") == before_events, "#{label}: no new event"
      end
    end

    test "PUT m.room.topic: 4096 code points, {\"m.text\": []} and an m.topic that differs from topic are 200 (stored as sent)", %{user: a} do
      room = make_room(a, %{"name" => "PUT topic ok"})

      for body <- [
            %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => String.duplicate("b", 4096)}]}},
            %{"topic" => "t", "m.topic" => %{"m.text" => []}},
            %{"topic" => "plain", "m.topic" => %{"m.text" => [%{"body" => "different", "mimetype" => "text/plain"}]}}
          ] do
        conn = put_state(a, room, "m.room.topic", body)
        assert conn.status == 200
        # looked up by the event id the PUT returned (two PUTs in one millisecond tie on origin_server_ts: "the last" is not defined)
        event_id = T.json(conn)["event_id"]
        assert [[content]] = T.sql!("SELECT content FROM events WHERE event_id = $1", [event_id]).rows
        assert content_of(content) == body
      end
    end

    test "authorisation runs first on PUT: a non-member gets 403 whatever the content", %{user: a, other: b} do
      room = make_room(a, %{"name" => "PUT authz"})

      for content <- [%{"topic" => "fine"}, %{"topic" => 42}, %{"topic" => String.duplicate("t", 1025)}, %{"topic" => "t", "m.topic" => "x"}] do
        conn = put_state(b, room, "m.room.topic", content)
        assert conn.status == 403, "#{inspect(content)}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      end
    end

    test "initial_state m.room.topic entries follow the same rule: 400 and no room, accepted shapes are 200", %{user: a} do
      entry = fn content -> %{"type" => "m.room.topic", "state_key" => "", "content" => content} end

      assert_rejected(a, %{"initial_state" => [entry.(%{"topic" => 42})]}, 400, "M_BAD_JSON", "topic 42")
      assert_rejected(a, %{"initial_state" => [entry.(%{"topic" => String.duplicate("t", 1025)})]}, 400, "M_INVALID_PARAM", "1025")
      assert_rejected(a, %{"initial_state" => [entry.(%{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => 5}]}})]}, 400, "M_BAD_JSON", "body 5")

      for content <- [%{"topic" => ""}, %{}, %{"topic" => nil}, %{"topic" => "t", "m.topic" => %{"m.text" => []}}] do
        room = make_room(a, %{"initial_state" => [entry.(content)]})
        assert contents(room, "m.room.topic") == [content]
      end
    end
  end

  # ═══ AC9 - AC12: power_level_content_override ═════════════════════════════════

  describe "AC9 - the override is merged and enforced" do
    test "Element's Space request: merged levels (event and rooms.power_levels_json); a PL 0 member can neither post nor invite, the creator can", %{user: a, other: b, third: c} do
      room =
        make_room(a, %{
          "name" => "Element Space",
          "preset" => "private_chat",
          "creation_content" => %{"type" => "m.space"},
          "power_level_content_override" => %{"events_default" => 100, "invite" => 50}
        })

      expected = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{a.uid => 100}) |> Map.merge(%{"events_default" => 100, "invite" => 50})
      assert only(room, "m.room.power_levels") == expected
      assert stored_power_levels(room) == expected

      invite!(a, room, b)
      join!(b, room)

      send = fn user, txn -> T.matrix_request(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/#{txn}", user.at, body: %{"msgtype" => "m.text", "body" => "hi"}) end
      assert send.(b, "t1-" <> T.rand(3)).status == 403, "a PL 0 member cannot post in a Space (events_default 100)"
      assert invite(b, room, c).status == 403, "a PL 0 member cannot invite in a private Space (invite 50)"

      assert send.(a, "t2-" <> T.rand(3)).status == 200, "the creator can post"
      assert invite(a, room, c).status == 200, "the creator can invite"
    end

    test "users override: exactly the map sent (shallow); the creator listed again keeps her level; the creator missing is a lock-out (AC11)", %{user: a} do
      other = "@someone:#{server_name()}"

      room = make_room(a, %{"name" => "Users override", "power_level_content_override" => %{"users" => %{a.uid => 100, other => 50}}})
      assert only(room, "m.room.power_levels")["users"] == %{a.uid => 100, other => 50}

      assert_rejected(a, %{"name" => "Missing creator", "power_level_content_override" => %{"users" => %{other => 50}}}, 400, "M_INVALID_ROOM_STATE", "creator not listed")
    end

    test "events override is stored as sent; an unknown top-level key is kept; absent / null / {} equal today's content", %{user: a} do
      room = make_room(a, %{"name" => "Events", "power_level_content_override" => %{"events" => %{"m.room.name" => 100}, "org.example.x" => 1}})
      content = only(room, "m.room.power_levels")
      assert content["events"] == %{"m.room.name" => 100}
      assert content["org.example.x"] == 1

      default = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{a.uid => 100})

      for body <- [%{}, %{"power_level_content_override" => nil}, %{"power_level_content_override" => %{}}] do
        room = make_room(a, Map.put(body, "name", "Default levels"))
        assert only(room, "m.room.power_levels") == default
        assert stored_power_levels(room) == default
      end
    end
  end

  describe "AC9 - the merged levels survive a restart of the room process" do
    test "after the Room.Server is stopped and started again the PL 0 member is still refused (levels come from rooms.power_levels_json)", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Restart", "power_level_content_override" => %{"events_default" => 100}})
      invite!(a, room, b)
      join!(b, room)

      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = GenServer.stop(pid, :normal, 5_000)
      assert wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) != {:ok, pid} end, 200) == :ok
      _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room)

      send = fn user, txn -> T.matrix_request(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/#{txn}", user.at, body: %{"msgtype" => "m.text", "body" => "hi"}) end
      assert send.(b, "r1-" <> T.rand(3)).status == 403, "the override survived the restart"
      assert send.(a, "r2-" <> T.rand(3)).status == 200
    end
  end

  describe "AC10 - override validation over HTTP" do
    test "\"x\", [] and 5 as override are 400 M_BAD_JSON", %{user: a} do
      for value <- ["x", [], 5] do
        assert_rejected(a, %{"power_level_content_override" => value}, 400, "M_BAD_JSON", "override #{inspect(value)}")
      end
    end

    test "strings, floats, booleans, nulls, out-of-range values and non-user keys are 400 M_BAD_JSON, no room", %{user: a} do
      for {label, override} <- [
            ban_string: %{"ban" => "50"},
            ban_float: %{"ban" => 50.5},
            ban_bool: %{"ban" => true},
            kick_out_of_range: %{"kick" => 9_007_199_254_740_992},
            events_list: %{"events" => []},
            events_empty_key: %{"events" => %{"" => 50}},
            events_string_value: %{"events" => %{"m.room.name" => "50"}},
            users_bad_key: %{"users" => %{"not-a-user" => 50}},
            users_string_value: %{"users" => %{"@a:#{server_name()}" => "100"}},
            users_list: %{"users" => []},
            users_float_value: %{"users" => %{"@a:#{server_name()}" => 1.0}},
            notifications_string_value: %{"notifications" => %{"room" => "50"}},
            notifications_number: %{"notifications" => 5},
            ban_null: %{"ban" => nil},
            users_null: %{"users" => nil},
            events_inner_null: %{"events" => %{"m.room.name" => nil}},
            users_default_below_range: %{"users_default" => -9_007_199_254_740_992}
          ] do
        assert_rejected(a, %{"power_level_content_override" => override}, 400, "M_BAD_JSON", "override #{label}")
      end
    end

    test "9007199254740991 and -9007199254740991 are 200", %{user: a} do
      for value <- [9_007_199_254_740_991, -9_007_199_254_740_991] do
        room = make_room(a, %{"name" => "Range", "power_level_content_override" => %{"ban" => value}})
        assert only(room, "m.room.power_levels")["ban"] == value
      end
    end

    test "the message is fixed text: no client value is echoed", %{user: a} do
      marker = "zzmark" <> T.rand(4)
      conn = assert_rejected(a, %{"power_level_content_override" => %{"ban" => marker}}, 400, "M_BAD_JSON", "marker value")
      refute conn.resp_body =~ marker
      conn = assert_rejected(a, %{"power_level_content_override" => %{"users" => %{"@#{marker}:x.y" => "x"}}}, 400, "M_BAD_JSON", "marker user")
      refute conn.resp_body =~ marker
    end
  end

  describe "AC11 - the creator lock-out over HTTP" do
    test "a demoted creator, state_default 101 and users {} are 400 M_INVALID_ROOM_STATE, no room", %{user: a} do
      for {label, override} <- [demoted: %{"users" => %{a.uid => 0}}, state_default: %{"state_default" => 101}, empty_users: %{"users_default" => 0, "users" => %{}}] do
        assert_rejected(a, %{"power_level_content_override" => override}, 400, "M_INVALID_ROOM_STATE", to_string(label))
      end
    end

    test "events m.room.topic 101: 400 with a top-level topic, 200 without; m.room.canonical_alias 101: 400 with room_alias_name and with a derived alias", %{user: a} do
      topic_override = %{"events" => %{"m.room.topic" => 101}}
      assert_rejected(a, %{"topic" => "x", "power_level_content_override" => topic_override}, 400, "M_INVALID_ROOM_STATE", "topic written")
      make_room(a, %{"power_level_content_override" => topic_override})

      alias_override = %{"events" => %{"m.room.canonical_alias" => 101}}
      assert_rejected(a, %{"room_alias_name" => "lo-" <> T.rand(4), "power_level_content_override" => alias_override}, 400, "M_INVALID_ROOM_STATE", "explicit alias")
      assert_rejected(a, %{"name" => "Derived " <> T.rand(4), "power_level_content_override" => alias_override}, 400, "M_INVALID_ROOM_STATE", "derived alias")
    end

    test "events m.room.join_rules / m.room.history_visibility 101 are 400 M_INVALID_ROOM_STATE, also when an initial_state entry replaces the preset event", %{user: a} do
      for {type, entry_content} <- [{"m.room.join_rules", %{"join_rule" => "public"}}, {"m.room.history_visibility", %{"history_visibility" => "shared"}}] do
        override = %{"events" => %{type => 101}}
        assert_rejected(a, %{"power_level_content_override" => override}, 400, "M_INVALID_ROOM_STATE", "#{type} preset")

        assert_rejected(
          a,
          %{"power_level_content_override" => override, "initial_state" => [%{"type" => type, "state_key" => "", "content" => entry_content}]},
          400,
          "M_INVALID_ROOM_STATE",
          "#{type} replaced by an entry"
        )
      end
    end

    test "later actions only (kick 101, invite 100, users_default 100) are 200", %{user: a} do
      for override <- [%{"kick" => 101}, %{"invite" => 100}, %{"users_default" => 100}] do
        make_room(a, %{"name" => "Later", "power_level_content_override" => override})
      end
    end
  end

  # story power-levels-enforcement (D7, follow-up `er`, AC16 re-pin; was "AC12 - ... is still skipped": the levels stayed the default
  # / the override's merge): the entry is APPLIED at step 6 as a full replacement (a second levels event after the step-3 one)
  describe "AC12 - initial_state m.room.power_levels is applied (story power-levels-enforcement)" do
    test "200, the room's levels are the entry's EXACTLY (no merge with the default or the override); the step-3 event stays the default (or the override's merge)", %{user: a} do
      entry = %{"type" => "m.room.power_levels", "state_key" => "", "content" => %{"users_default" => 100}}
      default = Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{a.uid => 100})

      room = make_room(a, %{"name" => "Applied PL", "initial_state" => [entry]})
      assert contents(room, "m.room.power_levels") == [default, %{"users_default" => 100}]

      merged = make_room(a, %{"name" => "Applied PL + override", "initial_state" => [entry], "power_level_content_override" => %{"events_default" => 100}})
      assert contents(merged, "m.room.power_levels") == [Map.put(default, "events_default", 100), %{"users_default" => 100}]
    end
  end

  # ═══ Review cycle 1: a leave never lifts a ban (Kassandra F-1, HIGH), a member holds no invitation (M-2), moderation levels (F-3) ═══

  # the membership of the LATEST m.room.member event of the user (by origin_server_ts, then the insertion order does not matter: tick/0 separates the steps)
  defp latest_membership(room_id, uid) do
    T.sql!(
      "SELECT content->>'membership' FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 ORDER BY origin_server_ts DESC LIMIT 1",
      [room_id, uid]
    ).rows
    |> case do
      [[membership]] -> membership
      [] -> nil
    end
  end

  defp member_event_count(room_id, uid),
    do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2", [room_id, uid]).rows |> hd() |> hd()

  # moderation that is expected to be REFUSED: the {http_status, errcode, message} of the public mapping
  defp moderate_refused(kind, room, caller, target) do
    Nebu.Matrix.Http.call_core(fn ->
      stream = Nebu.Matrix.Http.stream(caller.uid)

      case kind do
        :ban -> Nebu.Matrix.EventDispatcher.Server.ban_user(%Core.BanUserRequest{room_id: room, target_id: target.uid, reason: ""}, stream)
        :kick -> Nebu.Matrix.EventDispatcher.Server.kick_user(%Core.KickUserRequest{room_id: room, target_id: target.uid, reason: ""}, stream)
        :unban -> Nebu.Matrix.EventDispatcher.Server.unban_user(%Core.UnbanUserRequest{room_id: room, target_id: target.uid}, stream)
      end
    end)
  end

  describe "F-1 - ban -> /leave -> /join: a banned user cannot lift the ban by leaving" do
    test "a public room: the leave of a banned user is 403 M_FORBIDDEN and writes NOTHING, the ban stays the latest membership, the join stays 403", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Leave banned public", "preset" => "public_chat"})
      join!(b, room)
      tick()
      moderate(:ban, room, a, b)
      tick()
      assert latest_membership(room, b.uid) == "ban"
      events_before = member_event_count(room, b.uid)

      conn = leave(b, room)
      assert conn.status == 403, conn.resp_body
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert T.json(conn)["error"] == @ban_text
      tick()

      assert latest_membership(room, b.uid) == "ban", "the leave did not lift the ban"
      assert member_event_count(room, b.uid) == events_before, "no member event was written by the refused leave"
      assert_refused(join(b, room), "banned, after the refused leave", room, :ban)
      refute member?(room, b.uid)
    end

    test "restricted and knock_restricted rooms with the user still in the allow-room: ban -> leave -> join stays 403", %{user: a, other: b} do
      space = make_room(a, space_body())
      join!(b, space)

      for rule <- ["restricted", "knock_restricted"] do
        room = make_room(a, %{"name" => "Leave banned #{rule}", "initial_state" => [rule_entry(%{"join_rule" => rule, "allow" => allow_space(space)})]})
        join!(b, room)
        tick()
        moderate(:ban, room, a, b)
        tick()

        assert leave(b, room).status == 403
        tick()
        assert latest_membership(room, b.uid) == "ban", rule
        assert_refused(join(b, room), "#{rule}: ban -> leave -> join", room, :ban)
      end
    end

    test "ban -> leave -> invite: the invite of the banned user is still 403 (a PL-0 member cannot re-invite a banned user through the leave either)", %{user: a, other: b, third: c} do
      room = make_room(a, %{"name" => "Leave banned invite", "preset" => "public_chat"})
      join!(b, room)
      join!(c, room)
      tick()
      moderate(:ban, room, a, b)
      tick()
      assert leave(b, room).status == 403
      tick()

      conn = invite(c, room, b)
      assert conn.status == 403, conn.resp_body
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert invitation(room, b.uid) in [:none, :rejected]
      assert latest_membership(room, b.uid) == "ban"
    end

    test "the decline of a REAL invitation still works: 200, the invitation is rejected, the latest membership is leave; a leave without any invitation writes no event", %{user: a, other: b, third: c} do
      room = make_room(a, %{"name" => "Decline"})
      invite!(a, room, b)
      assert invitation(room, b.uid) == :pending
      tick()

      assert leave(b, room).status == 200
      assert invitation(room, b.uid) == :rejected
      assert latest_membership(room, b.uid) == "leave"

      before = member_event_count(room, c.uid)
      assert leave(c, room).status == 200
      assert member_event_count(room, c.uid) == before, "nothing to leave: no member event"
    end
  end

  describe "M-2 - a member holds no invitation: no pre-arming, nothing survives a leave or a kick" do
    test "inviting a member (and oneself) is 403 M_FORBIDDEN and arms nothing", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Invite member", "preset" => "public_chat"})
      join!(b, room)

      conn = invite(a, room, b)
      assert conn.status == 403, conn.resp_body
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert invitation(room, b.uid) == :none

      assert invite(b, room, b).status == 403
      assert invitation(room, b.uid) == :none
    end

    test "a pre-armed invitation (written directly) of a member does not survive a kick: kick -> /join is 403 in an invite-only room", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Prearm kick"})
      invite!(a, room, b)
      join!(b, room)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, b.uid, b.uid)
      assert invitation(room, b.uid) == :pending
      tick()

      moderate(:kick, room, a, b)
      assert invitation(room, b.uid) == :rejected, "the kick rejects the pending invitation"
      assert_refused(join(b, room), "kicked member with a pre-armed invitation", room)
    end

    test "a pre-armed invitation of a member does not survive an Admin remove or his own leave", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Prearm remove"})
      invite!(a, room, b)
      join!(b, room)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, b.uid, b.uid)
      tick()
      assert :ok = Nebu.Matrix.admin_remove_room_member(room, b.uid, a.uid)
      assert invitation(room, b.uid) == :rejected
      assert_refused(join(b, room), "admin-removed member with a pre-armed invitation", room)

      invite!(a, room, b)
      join!(b, room)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, b.uid, b.uid)
      tick()
      assert leave(b, room).status == 200
      assert invitation(room, b.uid) == :rejected
      assert_refused(join(b, room), "self-left member with a pre-armed invitation", room)
    end

    test "a /join of a member closes a pending invitation (the :already_member branch)", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Already member accepts"})
      invite!(a, room, b)
      join!(b, room)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, b.uid, b.uid)
      assert invitation(room, b.uid) == :pending

      join!(b, room)
      assert invitation(room, b.uid) == :accepted
    end

    test "an Admin force-add of an existing member is a no-op (no invitation re-armed), of a banned target is refused before anything is written", %{user: a, other: b, third: c} do
      room = make_room(a, %{"name" => "Admin add member / banned"})
      invite!(a, room, b)
      join!(b, room)
      assert invitation(room, b.uid) == :accepted

      assert {:ok, ^room} = Nebu.Matrix.admin_add_room_member(room, b.uid, a.uid)
      assert invitation(room, b.uid) == :accepted, "no re-armed invitation for a member"

      invite!(a, room, c)
      join!(c, room)
      tick()
      moderate(:ban, room, a, c)
      tick()
      assert invitation(room, c.uid) == :accepted

      assert {:error, _} = Nebu.Matrix.admin_add_room_member(room, c.uid, a.uid)
      assert invitation(room, c.uid) == :accepted, "the refused force-add re-armed nothing"
      assert latest_membership(room, c.uid) == "ban"
    end
  end

  describe "F-3 / F-5 - moderation needs a higher level than the target, an unban rejects a pending invitation" do
    test "a PL-50 member can neither ban, kick nor unban the PL-100 creator, nor a PL-50 peer (403 M_FORBIDDEN); the creator can act on both", %{user: a, other: b, third: c} do
      override = %{"users" => %{a.uid => 100, b.uid => 50, c.uid => 50}}
      room = make_room(a, %{"name" => "Moderation levels", "preset" => "public_chat", "power_level_content_override" => override})
      join!(b, room)
      join!(c, room)
      tick()

      for kind <- [:ban, :kick, :unban] do
        assert {:error, {403, "M_FORBIDDEN", _}} = moderate_refused(kind, room, b, a), "#{kind} of the creator"
        assert {:error, {403, "M_FORBIDDEN", _}} = moderate_refused(kind, room, b, c), "#{kind} of an equal"
      end

      assert member?(room, a.uid) and member?(room, c.uid)

      moderate(:kick, room, a, c)
      refute member?(room, c.uid)
      moderate(:ban, room, a, b)
      assert latest_membership(room, b.uid) == "ban"
    end

    test "unban rejects a pending invitation of the target: after the unban the user is still not admitted without a fresh invitation", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Unban rejects invite"})
      invite!(a, room, b)
      join!(b, room)
      tick()
      moderate(:ban, room, a, b)
      tick()
      # an invitation that survived the ban (the read-before-insert race of invite_user, written directly here)
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, a.uid, b.uid)
      assert invitation(room, b.uid) == :pending

      moderate(:unban, room, a, b)
      tick()
      assert invitation(room, b.uid) == :rejected
      assert_refused(join(b, room), "unbanned with a stale invitation", room)
    end
  end

  describe "F-7 / F-10 - a double-encoded join rule, the m.text list cap" do
    test "a legacy join_rules event whose content is a JSON STRING holding the JSON is read as that rule (public), not as malformed", %{user: a, other: b} do
      room = make_room(a, %{"name" => "Double encoded", "preset" => "public_chat"})
      # the state of a room written by the old double-encoding path: the content column holds the JSON as a JSONB string
      T.sql!("UPDATE events SET content = to_jsonb(content::text) WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [room])
      assert T.sql!("SELECT jsonb_typeof(content) FROM events WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [room]).rows == [["string"]]

      assert join(b, room).status == 200
    end

    test "an m.topic with more than 8 m.text entries is 400 M_INVALID_PARAM (createRoom topic entry and PUT), 8 are accepted", %{user: a} do
      entries = fn n -> for i <- 1..n, do: %{"body" => "t#{i}", "mimetype" => "text/plain"} end
      content = fn n -> %{"topic" => "t", "m.topic" => %{"m.text" => entries.(n)}} end

      assert_rejected(a, %{"initial_state" => [%{"type" => "m.room.topic", "state_key" => "", "content" => content.(9)}]}, 400, "M_INVALID_PARAM", "9 texts")
      room = make_room(a, %{"name" => "Eight texts", "initial_state" => [%{"type" => "m.room.topic", "state_key" => "", "content" => content.(8)}]})

      assert put_state(a, room, "m.room.topic", content.(9)).status == 400
      assert put_state(a, room, "m.room.topic", content.(8)).status == 200
    end
  end
end
