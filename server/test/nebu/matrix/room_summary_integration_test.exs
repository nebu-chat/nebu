defmodule Nebu.Matrix.RoomSummaryIntegrationTest do
  @moduledoc """
  Integration acceptance tests for story `oauth-room-summary-unrecognized` (epic
  oauth-broker, gate ac): `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` against the real
  supervision tree + PostgreSQL (model: `space_hierarchy_integration_test.exs`).

  Covers AC1.2 (legacy AND OAuth tokens reach the handler), AC2 (shapes on real rooms), AC3 (the whole
  visibility table, one row per test case), AC4 (unknown rooms leave no trace, one byte-identical 404),
  AC5 (aliases, `via`). The no-DB parts (builder, validation, injected stores, rate limit, logging) are
  `room_summary_test.exs`.

  Users and rooms are created over HTTP with legacy session tokens (`T.legacy_session!`, no IdP JWT
  needed); only the AC1.2 OAuth variant mints an OAuth session. Rooms are configured through the
  `initial_state` of `POST /createRoom` (the server derives the canonical alias from the room name).
  `m.room.member` ban events cannot be produced over HTTP (no ban route): they are inserted into the
  append-only `events` table directly, with a timestamp newer than every other member event.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @https "https://app.example.com/cb"
  @not_found_body %{"errcode" => "M_NOT_FOUND", "error" => "Room not found"}

  setup do
    T.reset_rate_limits()
    # story create-room-invites-direct (DATA adaptation): POST /invite refuses foreign-domain invitees (the key is deleted by older suites)
    Nebu.Test.ServerName.pin!(T.server_name())

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp dev, do: "RS" <> String.upcase(T.rand(4))

  defp user! do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, dev()).at}
  end

  defp api(method, path, u, body \\ nil), do: T.matrix_request(method, path, u.at, if(body, do: [body: body], else: []))

  defp json(conn), do: T.json(conn)

  defp state(type, content, key \\ ""), do: %{"type" => type, "state_key" => key, "content" => content}
  defp join_rule(rule, extra \\ %{}), do: state("m.room.join_rules", Map.merge(%{"join_rule" => rule}, extra))
  defp history(v), do: state("m.room.history_visibility", %{"history_visibility" => v})

  defp create_room!(u, label, initial_state \\ [], extra \\ %{}) do
    body = Map.merge(%{"name" => "#{label} #{T.rand(5)}", "initial_state" => initial_state}, extra)
    conn = api(:post, "/_matrix/client/v3/createRoom", u, body)
    assert conn.status == 200, "createRoom #{label}: #{conn.status} #{conn.resp_body}"
    json(conn)["room_id"]
  end

  defp invite!(inviter, room, invitee) do
    c = api(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/invite", inviter, %{"user_id" => invitee.uid})
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
  end

  defp join!(u, room) do
    c = api(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room)}", u)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
  end

  defp leave!(u, room) do
    c = api(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/leave", u)
    assert c.status == 200, "leave: #{c.status} #{c.resp_body}"
  end

  defp ban!(room, user, sender) do
    event_id = "$ban" <> T.rand(8)

    T.sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, 'm.room.member', $4, $5, $6)",
      [event_id, room, sender.uid, %{"membership" => "ban"}, System.system_time(:millisecond) + 60_000, user.uid]
    )

    # The ban is stamped 60 s AHEAD of the clock. Left in the table it moves the `tick()` horizon of every later suite that waits for the
    # clock to pass the newest event (follow-up fj: sync_membership_partition_http_test, member_prev_content_http_test): delete it again.
    ExUnit.Callbacks.on_exit(fn ->
      T.sql!("DELETE FROM events WHERE event_id = $1", [event_id])
    end)

    :ok
  end

  defp summary(u, raw), do: T.matrix_request(:get, "/_matrix/client/v1/room_summary/" <> URI.encode_www_form(raw), u.at)

  defp alias_of(room) do
    %{rows: [[a]]} = T.sql!("SELECT alias FROM room_aliases WHERE room_id = $1 LIMIT 1", [room])
    a
  end

  defp assert_hidden(conn, label) do
    assert conn.status == 404, "#{label}: expected the RU3 404, got #{conn.status} #{conn.resp_body}"
    assert json(conn) == @not_found_body, label
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1.2 — legacy and OAuth tokens both reach the handler
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1.2/RU2 — legacy and OAuth tokens" do
    test "a legacy session token and an OAuth session token both reach the handler (200 for a public room)" do
      alice = user!()
      room = create_room!(alice, "TokenRoom", [join_rule("public")])

      legacy = user!()
      c = summary(legacy, room)
      assert c.status == 200, "legacy token: #{c.status} #{c.resp_body}"
      assert json(c)["room_id"] == room

      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      c = T.matrix_request(:get, "/_matrix/client/v1/room_summary/" <> URI.encode_www_form(room), s.at)
      assert c.status == 200, "OAuth token: #{c.status} #{c.resp_body}"
      assert json(c)["room_id"] == room
      assert json(c)["membership"] == "leave"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — shapes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/RU5 — a joined member's summary" do
    test "AC2.1: a described public room answers exactly the RU5 key set with spec types; absent optionals are missing, never null" do
      alice = user!()

      room =
        create_room!(
          alice,
          "Described",
          [
            join_rule("public"),
            state("m.room.topic", %{"topic" => "A legacy topic"}),
            state("m.room.avatar", %{"url" => "mxc://test.local/avatar1"})
          ],
          # Story create-room-presets-power-levels-topic (AC16, DATA adaptation): a room created without a preset is private_chat now and
          # writes `guest_access: can_join`, which would make `guest_can_join` true. This room is the described PUBLIC one: public_chat
          # (guest_access forbidden), so `guest_can_join === false` below stays as asserted.
          %{"preset" => "public_chat"}
        )

      c = summary(alice, room)
      assert c.status == 200, c.resp_body
      body = json(c)

      assert body |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(room_id num_joined_members guest_can_join world_readable join_rule room_version membership name topic avatar_url canonical_alias))

      assert body["room_id"] == room
      assert body["num_joined_members"] == 1
      assert body["guest_can_join"] === false
      assert body["world_readable"] === false
      assert body["join_rule"] == "public"
      assert is_binary(body["room_version"])
      assert body["membership"] == "join"
      assert body["topic"] == "A legacy topic"
      assert body["avatar_url"] == "mxc://test.local/avatar1"
      assert body["canonical_alias"] == alias_of(room)
      assert String.starts_with?(body["name"], "Described ")
      refute Enum.any?(body, fn {_k, v} -> v in [nil, ""] end)

      %{rows: [[create_version]]} = T.sql!("SELECT content->>'room_version' FROM events WHERE room_id = $1 AND event_type = 'm.room.create' LIMIT 1", [room])
      assert body["room_version"] == (create_version || "1"), "AC2.6: the create content value"
    end

    test "AC2.1: a bare room has no name-less optional keys at all" do
      alice = user!()
      # no name => no name / canonical_alias events; no topic, no avatar
      c = api(:post, "/_matrix/client/v3/createRoom", alice, %{})
      assert c.status == 200
      room = json(c)["room_id"]
      body = summary(alice, room) |> json()

      assert body |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(room_id num_joined_members guest_can_join world_readable join_rule room_version membership))

      assert body["join_rule"] == "invite"
    end

    test "AC2.2: a space adds room_type m.space" do
      alice = user!()
      room = create_room!(alice, "Space", [], %{"creation_content" => %{"type" => "m.space"}})
      assert (summary(alice, room) |> json())["room_type"] == "m.space"
    end

    test "AC2.3: the text/plain m.topic block wins over html and over the legacy topic; an empty legacy topic without text/plain omits topic" do
      alice = user!()

      content = %{
        "topic" => "L",
        "m.topic" => %{"m.text" => [%{"mimetype" => "text/html", "body" => "<b>H</b>"}, %{"mimetype" => "text/plain", "body" => "P"}]}
      }

      room = create_room!(alice, "Topic", [state("m.room.topic", content)])
      assert (summary(alice, room) |> json())["topic"] == "P"

      html_only = %{"topic" => "", "m.topic" => %{"m.text" => [%{"mimetype" => "text/html", "body" => "<b>H</b>"}]}}
      room2 = create_room!(alice, "TopicHtml", [state("m.room.topic", html_only)])
      refute Map.has_key?(summary(alice, room2) |> json(), "topic")
    end

    test "AC2.4: an invited user does not count in num_joined_members" do
      alice = user!()
      bob = user!()
      room = create_room!(alice, "Count", [join_rule("public")])
      invite!(alice, room, bob)
      assert (summary(alice, room) |> json())["num_joined_members"] == 1
      join!(bob, room)
      assert (summary(alice, room) |> json())["num_joined_members"] == 2
    end

    test "AC2.5: a restricted room answers allowed_room_ids; a public room has none" do
      alice = user!()
      space = create_room!(alice, "AllowSpace", [join_rule("public")], %{"creation_content" => %{"type" => "m.space"}})
      restricted = create_room!(alice, "Restricted", [join_rule("restricted", %{"allow" => [%{"type" => "m.room_membership", "room_id" => space}]})])
      body = summary(alice, restricted) |> json()
      assert body["join_rule"] == "restricted"
      assert body["allowed_room_ids"] == [space]
      refute Map.has_key?(summary(alice, space) |> json(), "allowed_room_ids")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — visibility table (RU4)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/RU4 — visibility; every hidden row answers the RU3 404 body" do
    setup do
      alice = user!()
      invite_only = create_room!(alice, "InviteOnly")
      public = create_room!(alice, "PublicRoom", [join_rule("public")])
      knock = create_room!(alice, "KnockRoom", [join_rule("knock")])
      world = create_room!(alice, "WorldRoom", [history("world_readable")])
      space = create_room!(alice, "TheSpace", [join_rule("public")], %{"creation_content" => %{"type" => "m.space"}})
      restricted = create_room!(alice, "RestrictedRoom", [join_rule("restricted", %{"allow" => [%{"type" => "m.room_membership", "room_id" => space}]})])
      knock_restricted = create_room!(alice, "KnockRestrictedRoom", [join_rule("knock_restricted", %{"allow" => [%{"type" => "m.room_membership", "room_id" => space}]})])
      restricted_no_allow = create_room!(alice, "RestrictedNoAllow", [join_rule("restricted", %{"allow" => []})])
      # invite / shared join rule + world_readable history: visible to everybody (RU4)
      invite_world = create_room!(alice, "InviteWorld", [history("world_readable")])

      {:ok,
       alice: alice,
       invite_only: invite_only,
       public: public,
       knock: knock,
       world: world,
       space: space,
       restricted: restricted,
       knock_restricted: knock_restricted,
       restricted_no_allow: restricted_no_allow,
       invite_world: invite_world}
    end

    test "joined => 200 membership join (invite / shared room)", c do
      r = summary(c.alice, c.invite_only)
      assert r.status == 200
      assert json(r)["membership"] == "join"
    end

    test "pending invite => 200 membership invite (invite / shared room)", c do
      bob = user!()
      invite!(c.alice, c.invite_only, bob)
      r = summary(bob, c.invite_only)
      assert r.status == 200, r.resp_body
      assert json(r)["membership"] == "invite"
      assert json(r)["room_id"] == c.invite_only
    end

    test "declined invite => 404", c do
      bob = user!()
      invite!(c.alice, c.invite_only, bob)
      assert summary(bob, c.invite_only).status == 200
      leave!(bob, c.invite_only)
      assert_hidden(summary(bob, c.invite_only), "declined invite")
    end

    test "never member: public, knock and world_readable rooms => 200 membership leave; invite / shared => 404", c do
      carol = user!()

      for {label, room} <- [public: c.public, knock: c.knock, world: c.world] do
        r = summary(carol, room)
        assert r.status == 200, "#{label}: #{r.status} #{r.resp_body}"
        assert json(r)["membership"] == "leave", "#{label}: a never member sees `leave` (Nebu choice, RU5)"
      end

      assert_hidden(summary(carol, c.invite_only), "never member of an invite / shared room")
    end

    test "a member of the allowed space does NOT see a restricted room through allow (RU4) => 404", c do
      dave = user!()
      join!(dave, c.space)
      assert summary(dave, c.space).status == 200
      assert_hidden(summary(dave, c.restricted), "restricted via allow")
    end

    test "left: invite / shared => 404; public => 200 membership leave", c do
      erin = user!()
      join!(erin, c.public)
      leave!(erin, c.public)
      r = summary(erin, c.public)
      assert r.status == 200
      assert json(r)["membership"] == "leave"

      invite!(c.alice, c.invite_only, erin)
      join!(erin, c.invite_only)
      leave!(erin, c.invite_only)
      assert_hidden(summary(erin, c.invite_only), "left an invite / shared room")
    end

    test "never member: knock_restricted => 200 membership leave (review m1)", c do
      carol = user!()
      r = summary(carol, c.knock_restricted)
      assert r.status == 200, r.resp_body
      assert json(r)["membership"] == "leave"
      assert json(r)["join_rule"] == "knock_restricted"
      assert json(r)["allowed_room_ids"] == [c.space]
    end

    test "never member: restricted without any allow entry => 404 (review m1)", c do
      carol = user!()
      assert_hidden(summary(carol, c.restricted_no_allow), "restricted without allow")
    end

    # Kassandra M-1 (review cycle 1): a ban ends a still pending invitation. `ban_user/2` is not routed over HTTP,
    # so it is called in process (it needs the room process, which `create_room!` started).
    defp ban_in_process!(room, target, sender) do
      # story create-room-invites-direct (DATA adaptation): an invite now writes an `m.room.member` invite event, and the latest
      # membership is read by origin_server_ts with no tie-break (follow-up `eu`): a ban in the SAME millisecond as the invite would
      # tie with it. Wait for the next millisecond, as the sibling suites do (`tick/0`).
      start = System.system_time(:millisecond)
      wait = fn wait -> if System.system_time(:millisecond) <= start, do: (Process.sleep(1); wait.(wait)), else: :ok end
      wait.(wait)

      req = %Core.BanUserRequest{room_id: room, caller_id: sender.uid, target_id: target.uid, reason: ""}
      Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(sender.uid))
    end

    test "invite -> ban in an invite-only room => 404; the pending invitation row is gone (M-1)", c do
      bob = user!()
      invite!(c.alice, c.invite_only, bob)
      assert summary(bob, c.invite_only).status == 200

      ban_in_process!(c.invite_only, bob, c.alice)

      assert_hidden(summary(bob, c.invite_only), "banned former invitee")
      assert Nebu.Matrix.Room.InviteDB.pending_invite?(c.invite_only, bob.uid) == {:ok, false}
      # /sync shares the invitation table: the banned user no longer sees the invite there either
      assert Nebu.Matrix.Room.InviteDB.get_pending_invite_rooms_for_user(bob.uid) == {:ok, []}
    end

    test "invite -> ban in a public room => 200 membership ban (M-1)", c do
      bob = user!()
      invite!(c.alice, c.public, bob)
      ban_in_process!(c.public, bob, c.alice)

      r = summary(bob, c.public)
      assert r.status == 200, r.resp_body
      assert json(r)["membership"] == "ban"
    end

    test "defence in depth: a STALE pending invitation row of a banned user does not grant access (M-1)", c do
      bob = user!()
      invite!(c.alice, c.invite_only, bob)
      # the ban event arrives WITHOUT the invitation being rejected (e.g. a ban path that does not reject)
      ban!(c.invite_only, bob, c.alice)
      assert Nebu.Matrix.Room.InviteDB.pending_invite?(c.invite_only, bob.uid) == {:ok, true}

      assert_hidden(summary(bob, c.invite_only), "stale invite of a banned user")
    end

    test "banned user in a world_readable room => 200 membership ban (review m1)", c do
      frank = user!()
      ban!(c.invite_world, frank, c.alice)
      r = summary(frank, c.invite_world)
      assert r.status == 200, r.resp_body
      assert json(r)["membership"] == "ban"
      assert json(r)["world_readable"] === true
    end

    test "banned: public => 200 membership ban; invite / shared => 404", c do
      frank = user!()
      ban!(c.public, frank, c.alice)
      ban!(c.invite_only, frank, c.alice)

      r = summary(frank, c.public)
      assert r.status == 200, r.resp_body
      assert json(r)["membership"] == "ban"
      assert_hidden(summary(frank, c.invite_only), "banned from an invite / shared room")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC15 (m2) / lazy start (m3)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15 / RU3 — logging on a 200 and a room without a running process" do
    test "a 200 writes no room name, topic, alias or avatar to the log (review m2)" do
      alice = user!()

      room =
        create_room!(alice, "LogSecretName", [
          join_rule("public"),
          state("m.room.topic", %{"topic" => "log-secret-topic-4711"}),
          state("m.room.avatar", %{"url" => "mxc://test.local/log-secret-avatar"})
        ])

      a = alias_of(room)

      {c, log} = with_log(fn -> summary(alice, room) end)
      assert c.status == 200
      assert json(c)["topic"] == "log-secret-topic-4711"
      refute log =~ "LogSecretName"
      refute log =~ "log-secret-topic-4711"
      refute log =~ "log-secret-avatar"
      refute log =~ a

      {via_alias, log} = with_log(fn -> summary(alice, a) end)
      assert via_alias.status == 200
      refute log =~ "LogSecretName"
      refute log =~ a
    end

    test "an active room whose process is gone is lazy-started and answers the same body (review m3)" do
      alice = user!()
      room = create_room!(alice, "NoProcess", [join_rule("public")])
      before = summary(alice, room)
      assert before.status == 200

      case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) do
        {:ok, pid} -> Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
        _ -> :ok
      end

      eventually(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end)

      after_restart = summary(alice, room)
      assert after_restart.status == 200, after_restart.resp_body
      assert after_restart.resp_body == before.resp_body
    end
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — unknown rooms leave no trace (RU3)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/RU3 — unknown, archived and hidden rooms" do
    test "unknown ids and an archived room answer the RU3 404; no rooms row, no Room process is created for the unknown ids" do
      alice = user!()
      server = alice.uid |> String.split(":") |> List.last()
      unknown = ["!doesnotexist#{T.rand(6)}:#{server}", "!x#{T.rand(6)}:other.example", "!opaque" <> T.rand(10)]

      for id <- unknown, do: assert_hidden(summary(alice, id), id)

      %{rows: [[n]]} = T.sql!("SELECT count(*) FROM rooms WHERE room_id = ANY($1)", [unknown])
      assert n == 0, "an unchecked state lookup would have inserted a rooms row per attacker-chosen id"

      for id <- unknown do
        assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(id) == {:error, :not_found}, "no Room process for #{id}"
      end

      archived = create_room!(alice, "Archived", [join_rule("public")])
      assert summary(alice, archived).status == 200
      T.privileged_sql!("UPDATE rooms SET status = 'archived' WHERE room_id = $1", [archived])
      assert_hidden(summary(alice, archived), "archived")
    end

    test "the hidden 404 and the unknown 404 are byte-identical: status, body and content type" do
      alice = user!()
      carol = user!()
      server = alice.uid |> String.split(":") |> List.last()
      hidden = create_room!(alice, "Hidden")

      unknown = summary(carol, "!nothere#{T.rand(6)}:#{server}")
      hid = summary(carol, hidden)

      assert {hid.status, hid.resp_body, T.header(hid, "content-type")} == {unknown.status, unknown.resp_body, T.header(unknown, "content-type")}
      assert unknown.status == 404
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — aliases (RU1)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/RU1 — aliases and via" do
    test "AC5.1: a percent-encoded #alias:server of a visible room answers 200 with its room_id" do
      alice = user!()
      carol = user!()
      room = create_room!(alice, "AliasRoom", [join_rule("public")])
      a = alias_of(room)

      r = summary(carol, a)
      assert r.status == 200, "#{a}: #{r.status} #{r.resp_body}"
      assert json(r)["room_id"] == room
      assert json(r)["canonical_alias"] == a
    end

    test "AC5.2: an unknown local alias, a foreign-server alias and the alias of a hidden room answer the RU3 404" do
      alice = user!()
      carol = user!()
      hidden = create_room!(alice, "HiddenAlias")
      server = alias_of(hidden) |> String.split(":", parts: 2) |> List.last()

      assert_hidden(summary(carol, "#nope#{T.rand(6)}:#{server}"), "unknown local alias")
      assert_hidden(summary(carol, "#x#{T.rand(6)}:other.example"), "foreign alias")
      assert_hidden(summary(carol, alias_of(hidden)), "alias of a hidden room")
    end

    test "AC5.3: ?via=... gives an identical body and no outbound lookup (local only)" do
      alice = user!()
      room = create_room!(alice, "ViaRoom", [join_rule("public")])
      base = "/_matrix/client/v1/room_summary/" <> URI.encode_www_form(room)

      plain = T.matrix_request(:get, base, alice.at)
      via = T.matrix_request(:get, base <> "?via=matrix.org&via=other.example", alice.at)
      assert plain.status == 200
      assert {via.status, via.resp_body} == {plain.status, plain.resp_body}

      foreign = T.matrix_request(:get, "/_matrix/client/v1/room_summary/" <> URI.encode_www_form("!remote:other.example") <> "?via=other.example", alice.at)
      assert_hidden(foreign, "a foreign room id with via is still just a local miss")
    end
  end
end
