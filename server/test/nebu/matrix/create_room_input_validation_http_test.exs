defmodule Nebu.Matrix.CreateRoomInputValidationHttpTest do
  @moduledoc """
  Integration tests for story `create-room-input-validation` (epic oauth-broker, follow-ups `ed`, `ee`, `eg`, `ei`):
  `GET /capabilities`, `POST /createRoom`, `PUT /rooms/{id}/state/...` and `POST /rooms/{id}/upgrade` over HTTP against the real
  supervision tree + PostgreSQL (users and sessions as in `create_room_initial_state_http_test.exs`).

  The unit suites (`create_room_input_validation_test.exs`, `set_room_state_test.exs`, `upgrade_room_test.exs`) drive the Core with fakes;
  this file pins what only the real stack decides: the router guards (`M_BAD_JSON` / `M_NOT_JSON` / `M_MISSING_PARAM`), the D6 errcode
  mapping on the wire, the real `room_aliases` primary key (`M_ROOM_IN_USE` is real now: random localparts, no run collides), the
  persisted events and the denormalised `rooms.name`.

  Every rejected createRoom must leave NO room behind (`assert_rejected/5`).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"

  setup do
    T.reset_rate_limits()
    # story create-room-invites-direct (DATA adaptation): POST /invite refuses foreign-domain invitees (the key is deleted by older suites)
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)

    uid = T.provision_user!()
    other_uid = T.provision_user!()

    {:ok,
     user: %{uid: uid, at: T.legacy_session!(uid, "CRIV" <> String.upcase(T.rand(3))).at},
     other: %{uid: other_uid, at: T.legacy_session!(other_uid, "CRIW" <> String.upcase(T.rand(3))).at}}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp server_name, do: Application.get_env(:event_dispatcher, :server_name, "nebu.local")
  defp alias_for(localpart), do: "#" <> localpart <> ":" <> server_name()
  defp enc(room_id), do: URI.encode_www_form(room_id)

  defp create(user, body), do: T.matrix_request(:post, @create, user.at, body: body)

  defp create_raw(user, raw) do
    conn(:post, @create, raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.at)
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

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

  defp put_state(user, room_id, type, body) do
    T.matrix_request(:put, "/_matrix/client/v3/rooms/#{enc(room_id)}/state/#{type}", user.at, body: body)
  end

  defp upgrade(user, room_id, body), do: T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room_id)}/upgrade", user.at, body: body)

  defp invite_and_join!(owner, guest, room_id) do
    c = T.matrix_request(:post, "/_matrix/client/v3/rooms/#{enc(room_id)}/invite", owner.at, body: %{"user_id" => guest.uid})
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
    c = T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room_id)}", guest.at)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
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
  defp room_name(room_id), do: T.sql!("SELECT name FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd()
  defp alias_rows(room_id), do: T.sql!("SELECT alias FROM room_aliases WHERE room_id = $1 ORDER BY alias", [room_id]).rows |> List.flatten()

  defp alias_owner(alias_str) do
    case T.sql!("SELECT room_id FROM room_aliases WHERE alias = $1", [alias_str]).rows do
      [[room_id]] -> room_id
      [] -> nil
    end
  end

  defp room_version_of(room_id), do: room_id |> contents("m.room.create") |> hd() |> Map.get("room_version")

  defp nested(1), do: %{}
  defp nested(levels), do: Enum.reduce(2..levels, %{}, fn _, acc -> %{"a" => acc} end)

  # a localpart so that "#" <> localpart <> ":" <> server_name is exactly `total` BYTES, with `multibyte` times the 2-byte "ä" inside
  defp localpart_for_total_bytes(total, multibyte) do
    random = T.rand(5)
    mb = String.duplicate("ä", multibyte)
    pad = total - 2 - byte_size(server_name()) - byte_size(random) - byte_size(mb)
    lp = random <> mb <> String.duplicate("a", pad)
    assert byte_size(alias_for(lp)) == total
    lp
  end

  defp canonical_entry(content, key \\ ""), do: %{"type" => "m.room.canonical_alias", "state_key" => key, "content" => content}

  # ─── AC1 ─────────────────────────────────────────────────────────────────────

  describe "AC1 - GET /capabilities advertises exactly the room version the server can create" do
    test "m.room_versions is {default: 10, available: {10: stable}} and the default is one of the available versions", %{user: u} do
      conn = T.matrix_request(:get, "/_matrix/client/v3/capabilities", u.at)
      assert conn.status == 200, conn.resp_body

      versions = T.json(conn)["capabilities"]["m.room_versions"]
      assert versions == %{"default" => "10", "available" => %{"10" => "stable"}}
      assert Map.has_key?(versions["available"], versions["default"])
    end
  end

  # ─── AC2 ─────────────────────────────────────────────────────────────────────

  describe "AC2 - createRoom room_version" do
    test "absent, null and \"10\" are 200 with room_version \"10\"; a creation_content room_version stays overwritten", %{user: u} do
      for {label, body} <- [
            absent: %{"name" => "v absent"},
            null: %{"name" => "v null", "room_version" => nil},
            ten: %{"name" => "v ten", "room_version" => "10"},
            creation_content: %{"name" => "v cc", "creation_content" => %{"room_version" => "9"}}
          ] do
        room = make_room(u, body)
        assert room_version_of(room) == "10", "#{label}: m.room.create room_version"
      end
    end

    test "\"11\", \"1\", \"9\", \"12\", \"\" and \"foo\" are 400 M_UNSUPPORTED_ROOM_VERSION, no room", %{user: u} do
      for version <- ["11", "1", "9", "12", "", "foo"] do
        assert_rejected(u, %{"name" => "bad version", "room_version" => version}, 400, "M_UNSUPPORTED_ROOM_VERSION", "room_version #{inspect(version)}")
      end
    end

    test "10 (number), true and [\"10\"] are 400 M_BAD_JSON, no room", %{user: u} do
      for {label, version} <- [number: 10, boolean: true, list: ["10"]] do
        assert_rejected(u, %{"name" => "bad version type", "room_version" => version}, 400, "M_BAD_JSON", "room_version #{label}")
      end
    end

    test "D7 first failure: a valid but TAKEN room_alias_name with room_version \"11\" is M_UNSUPPORTED_ROOM_VERSION, with the version absent M_ROOM_IN_USE", %{user: u} do
      localpart = "d7-" <> T.rand(5)
      first = make_room(u, %{"room_alias_name" => localpart})
      assert alias_owner(alias_for(localpart)) == first

      assert_rejected(u, %{"room_alias_name" => localpart, "room_version" => "11"}, 400, "M_UNSUPPORTED_ROOM_VERSION", "taken + 11")
      assert_rejected(u, %{"room_alias_name" => localpart}, 400, "M_ROOM_IN_USE", "taken, no version")
    end
  end

  # ─── AC3 ─────────────────────────────────────────────────────────────────────

  describe "AC3 - upgrade new_version" do
    test "\"11\", \"9\" and \"\" are 400 M_UNSUPPORTED_ROOM_VERSION; absent and null M_MISSING_PARAM; 10 and true M_BAD_JSON; nothing is tombstoned, no new room", %{user: u} do
      room = make_room(u, %{"name" => "Upgrade guard"})

      for {label, body, errcode} <- [
            {"11", %{"new_version" => "11"}, "M_UNSUPPORTED_ROOM_VERSION"},
            {"9", %{"new_version" => "9"}, "M_UNSUPPORTED_ROOM_VERSION"},
            {"empty", %{"new_version" => ""}, "M_UNSUPPORTED_ROOM_VERSION"},
            {"absent", %{}, "M_MISSING_PARAM"},
            {"null", %{"new_version" => nil}, "M_MISSING_PARAM"},
            {"number", %{"new_version" => 10}, "M_BAD_JSON"},
            {"boolean", %{"new_version" => true}, "M_BAD_JSON"}
          ] do
        before_rooms = room_count()
        conn = upgrade(u, room, body)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
        assert event_count(room, "m.room.tombstone") == 0, "#{label}: the old room must not be tombstoned"
        assert room_count() == before_rooms, "#{label}: no new room"
      end
    end

    test "\"10\" (a same-version upgrade) is 200 with a replacement_room that is a v10 room", %{user: u} do
      room = make_room(u, %{"name" => "Upgrade ok"})
      conn = upgrade(u, room, %{"new_version" => "10"})
      assert conn.status == 200, conn.resp_body

      replacement = T.json(conn)["replacement_room"]
      assert String.starts_with?(replacement, "!")
      assert room_version_of(replacement) == "10"
      assert event_count(room, "m.room.tombstone") == 1
    end

    test "a member WITHOUT the tombstone power level sending \"10\" is 403 M_FORBIDDEN (unchanged)", %{user: u, other: o} do
      room = make_room(u, %{"name" => "Upgrade forbidden"})
      invite_and_join!(u, o, room)

      conn = upgrade(o, room, %{"new_version" => "10"})
      assert conn.status == 403, conn.resp_body
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      assert event_count(room, "m.room.tombstone") == 0
    end
  end

  # ─── AC4 / AC5 ───────────────────────────────────────────────────────────────

  describe "AC4 - an explicit room_alias_name is honoured" do
    test "name \"Something Else\" + room_alias_name: the alias maps to the room, ONE canonical_alias event, no name-derived alias", %{user: u} do
      localpart = "my-room-" <> T.rand(5)
      room = make_room(u, %{"name" => "Something Else", "room_alias_name" => localpart})

      assert alias_owner(alias_for(localpart)) == room
      assert alias_rows(room) == [alias_for(localpart)], "no #something-else... row for the room"
      assert contents(room, "m.room.canonical_alias") == [%{"alias" => alias_for(localpart)}]
      assert room_name(room) == "Something Else"
    end

    # origin_server_ts is millisecond-granular: events emitted in the same millisecond tie, so this HTTP test can only show
    # "not later than"; the STRICT order (power_levels < canonical_alias < preset slot < initial_state < name) is pinned by the
    # unit test "emit order: power_levels < canonical_alias < initial_state entries < m.room.name" in
    # event_dispatcher/create_room_input_validation_test.exs, which uses a monotonic insertion sequence.
    test "Element's public-room request (visibility, preset, room_alias_name, initial_state): the alias event is not later than join_rules / history_visibility / guest_access", %{user: u} do
      localpart = "public-" <> T.rand(5)

      room =
        make_room(u, %{
          "name" => "Public Room",
          "visibility" => "public",
          "preset" => "public_chat",
          "room_alias_name" => localpart,
          "initial_state" => [
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "public"}},
            %{"type" => "m.room.history_visibility", "content" => %{"history_visibility" => "shared"}},
            %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}}
          ]
        })

      assert contents(room, "m.room.canonical_alias") == [%{"alias" => alias_for(localpart)}]

      ts = fn type -> T.sql!("SELECT origin_server_ts FROM events WHERE room_id = $1 AND event_type = $2", [room, type]).rows |> Enum.map(&hd/1) end
      [alias_ts] = ts.("m.room.canonical_alias")
      assert [_ | _] = ts.("m.room.power_levels")

      for type <- ["m.room.join_rules", "m.room.history_visibility", "m.room.guest_access"] do
        assert [_ | _] = ts.(type)
        assert alias_ts <= Enum.min(ts.(type)), "m.room.canonical_alias must not be emitted after #{type} (spec order: step 4 before steps 5-6)"
      end

      assert Enum.max(ts.("m.room.power_levels")) <= alias_ts, "not before the default power levels (step 3)"
    end
  end

  describe "AC5 - a taken alias is 400 M_ROOM_IN_USE" do
    test "a second createRoom with the same room_alias_name (any user) creates no room and leaves the first mapping unchanged", %{user: u, other: o} do
      localpart = "taken-" <> T.rand(5)
      first = make_room(u, %{"name" => "First", "room_alias_name" => localpart})

      assert_rejected(o, %{"name" => "Second", "room_alias_name" => localpart}, 400, "M_ROOM_IN_USE", "other user")
      assert_rejected(u, %{"name" => "Third", "room_alias_name" => localpart}, 400, "M_ROOM_IN_USE", "same user")

      assert alias_owner(alias_for(localpart)) == first
      assert contents(first, "m.room.canonical_alias") == [%{"alias" => alias_for(localpart)}]
    end
  end

  # ─── AC6 ─────────────────────────────────────────────────────────────────────

  describe "AC6 - room_alias_name syntax" do
    test "empty, ':', space, tab, NUL, C0 control, DEL and an alias of 256 bytes are 400 M_INVALID_PARAM, no room", %{user: u} do
      too_long = localpart_for_total_bytes(255, 0) <> "a"

      for {label, localpart} <- [
            empty: "",
            colon: "a:b",
            space: "a b",
            tab: "a\tb",
            nul: "a\u0000b",
            c0: "a\u0007b",
            del: "a\u007fb",
            over_255_bytes: too_long
          ] do
        assert_rejected(u, %{"name" => "bad alias", "room_alias_name" => localpart}, 400, "M_INVALID_PARAM", "room_alias_name #{label}")
      end
    end

    test "5, true and {} are 400 M_BAD_JSON, no room", %{user: u} do
      for {label, value} <- [number: 5, boolean: true, object: %{}] do
        assert_rejected(u, %{"name" => "bad alias type", "room_alias_name" => value}, 400, "M_BAD_JSON", "room_alias_name #{label}")
      end
    end

    test "a lone surrogate (\\ud800) never reaches the handler: the body is 400 M_NOT_JSON, no room", %{user: u} do
      before_rooms = room_count()
      conn = create_raw(u, ~S({"name": "surrogate", "room_alias_name": "a\ud800b"}))
      assert conn.status == 400, conn.resp_body
      assert T.json(conn)["errcode"] == "M_NOT_JSON"
      assert room_count() == before_rooms
    end

    test "BYTES are counted: an alias of exactly 255 bytes (ASCII, and with multibyte) is 200, 256 bytes with fewer than 255 code points is 400", %{user: u} do
      ascii = localpart_for_total_bytes(255, 0)
      multibyte = localpart_for_total_bytes(255, 10)
      multibyte_too_long = localpart_for_total_bytes(256, 10)
      assert String.length(multibyte_too_long) < 255

      for localpart <- [ascii, multibyte] do
        room = make_room(u, %{"room_alias_name" => localpart})
        assert alias_owner(alias_for(localpart)) == room
      end

      assert_rejected(u, %{"room_alias_name" => multibyte_too_long}, 400, "M_INVALID_PARAM", "256 bytes, multibyte")
    end

    test "Räume-x, a/b-x and MixedCase-x are accepted and registered verbatim (case preserved, no slug)", %{user: u} do
      for localpart <- ["Räume-" <> T.rand(4), "a/b-" <> T.rand(4), "MixedCase-" <> T.rand(4)] do
        room = make_room(u, %{"name" => "Verbatim", "room_alias_name" => localpart})
        assert alias_owner(alias_for(localpart)) == room, localpart
        assert contents(room, "m.room.canonical_alias") == [%{"alias" => alias_for(localpart)}], localpart
      end
    end
  end

  describe "AC7 - without room_alias_name the name-derived alias is unchanged" do
    test "absent and null room_alias_name register the slug of the name; a nameless room gets no alias", %{user: u} do
      for {label, extra} <- [absent: %{}, null: %{"room_alias_name" => nil}] do
        slug = "derived-" <> String.downcase(T.rand(5)) <> "-" <> Atom.to_string(label)
        room = make_room(u, Map.merge(%{"name" => slug}, extra))
        assert alias_owner(alias_for(slug)) == room, "#{label}: the derived alias #{alias_for(slug)}"
        assert contents(room, "m.room.canonical_alias") == [%{"alias" => alias_for(slug)}]

        nameless = make_room(u, extra)
        assert alias_rows(nameless) == []
      end
    end
  end

  # ─── AC8 ─────────────────────────────────────────────────────────────────────

  describe "AC8 - m.room.canonical_alias in initial_state" do
    test "an entry naming the own alias (alias, alt_aliases, both, empty alias + alt_aliases, null alias) is 200 and applied", %{user: u} do
      for content_fun <- [
            fn own -> %{"alias" => own} end,
            fn own -> %{"alt_aliases" => [own]} end,
            fn own -> %{"alias" => own, "alt_aliases" => [own]} end,
            fn own -> %{"alias" => "", "alt_aliases" => [own]} end,
            fn _own -> %{"alias" => nil} end
          ] do
        localpart = "x-" <> T.rand(5)
        content = content_fun.(alias_for(localpart))

        room = make_room(u, %{"room_alias_name" => localpart, "initial_state" => [canonical_entry(content)]})
        assert alias_owner(alias_for(localpart)) == room, "the explicit alias is registered for the room"
        assert content in contents(room, "m.room.canonical_alias"), "the entry's content is a state of the room: #{inspect(content)}"
      end
    end

    # The state a client sees (/sync state.events) must be the ENTRY, not the earlier explicit alias event. Hazard for the implementer:
    # Room.DB.get_generic_state_events/1 picks the latest event per (type, state_key) by `ORDER BY origin_server_ts DESC` only, so the
    # explicit alias event (step 4) and the initial_state entry (step 6) emitted in the same millisecond tie and the read is arbitrary.
    test "the entry wins over the explicit alias event in the state a client sees (/sync): {\"alias\": \"\", \"alt_aliases\": [own]}", %{user: u} do
      localpart = "x-" <> T.rand(5)
      own = alias_for(localpart)
      content = %{"alias" => "", "alt_aliases" => [own]}

      room = make_room(u, %{"room_alias_name" => localpart, "initial_state" => [canonical_entry(content)]})
      assert alias_owner(own) == room

      state_events = get_in(T.json(T.sync(u.at)), ["rooms", "join", room, "state", "events"]) || []
      assert [event] = Enum.filter(state_events, &(&1["type"] == "m.room.canonical_alias"))
      assert event["content"] == content
    end

    test "an alias that is not the one of room_alias_name (unregistered, registered to another room) is 400 M_BAD_ALIAS, no room", %{user: u} do
      localpart = "x-" <> T.rand(5)
      other_localpart = "other-" <> T.rand(5)
      _other_room = make_room(u, %{"room_alias_name" => other_localpart})

      for {label, content} <- [
            unregistered: %{"alias" => alias_for("nobody-" <> T.rand(5))},
            registered_to_another_room: %{"alias" => alias_for(other_localpart)},
            alt_aliases: %{"alt_aliases" => [alias_for(localpart), alias_for(other_localpart)]},
            foreign_server: %{"alias" => "#x:other.example"}
          ] do
        assert_rejected(u, %{"room_alias_name" => localpart, "initial_state" => [canonical_entry(content)]}, 400, "M_BAD_ALIAS", label |> to_string())
      end
    end

    test "bad syntax or wrong types are 400 M_INVALID_PARAM, never M_INVALID_ROOM_STATE, no room", %{user: u} do
      localpart = "x-" <> T.rand(5)

      for {label, content} <- [
            not_an_alias: %{"alias" => "not-an-alias"},
            no_local: %{"alias" => "#nolocal"},
            empty_local: %{"alias" => "#:server"},
            empty_domain: %{"alias" => "#a:"},
            alias_number: %{"alias" => 5},
            alt_not_a_list: %{"alt_aliases" => "x"},
            alt_number_entry: %{"alt_aliases" => [5]}
          ] do
        assert_rejected(u, %{"room_alias_name" => localpart, "initial_state" => [canonical_entry(content)]}, 400, "M_INVALID_PARAM", to_string(label))
      end
    end

    test "without room_alias_name: {} and {\"alias\": \"\"} are 200 (the derived alias wins with a name), any non-empty alias is 400 M_BAD_ALIAS", %{user: u} do
      for content <- [%{}, %{"alias" => ""}] do
        name = "entry-" <> String.downcase(T.rand(5))
        room = make_room(u, %{"name" => name, "initial_state" => [canonical_entry(content)]})
        assert %{"alias" => alias_for(name)} in contents(room, "m.room.canonical_alias")
      end

      assert_rejected(u, %{"name" => "x", "initial_state" => [canonical_entry(%{"alias" => alias_for("nobody-" <> T.rand(5))})]}, 400, "M_BAD_ALIAS", "alias without room_alias_name")
    end
  end

  # ─── AC9 ─────────────────────────────────────────────────────────────────────

  describe "AC9 - PUT m.room.canonical_alias" do
    defp put_alias(user, room, content), do: put_state(user, room, "m.room.canonical_alias", content)

    test "the room's own registered alias is 200 (also after the alias was removed first, so it is NEW), {\"alias\": \"\"} and {\"alias\": null} are 200", %{user: u} do
      localpart = "own-" <> T.rand(5)
      own = alias_for(localpart)
      room = make_room(u, %{"room_alias_name" => localpart})

      assert put_alias(u, room, %{"alias" => ""}).status == 200
      assert put_alias(u, room, %{"alias" => own}).status == 200
      assert put_alias(u, room, %{"alias" => nil}).status == 200
      assert put_alias(u, room, %{"alias" => "", "alt_aliases" => [own]}).status == 200
      assert put_alias(u, room, %{}).status == 200
    end

    test "an alias of another room, an unregistered alias and #x:other.example are 400 M_BAD_ALIAS and nothing is persisted", %{user: u} do
      room = make_room(u, %{"name" => "PUT target"})
      other_localpart = "elsewhere-" <> T.rand(5)
      _other = make_room(u, %{"room_alias_name" => other_localpart})
      before_events = event_count(room, "m.room.canonical_alias")

      for {label, content} <- [
            another_room: %{"alias" => alias_for(other_localpart)},
            unregistered: %{"alias" => alias_for("nobody-" <> T.rand(5))},
            foreign_server: %{"alias" => "#x:other.example"},
            invalid_new_alt_alias: %{"alias" => "", "alt_aliases" => [alias_for("nobody-" <> T.rand(5))]}
          ] do
        conn = put_alias(u, room, content)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_BAD_ALIAS", "#{label}: #{conn.resp_body}"
        assert event_count(room, "m.room.canonical_alias") == before_events, "#{label}: nothing is persisted"
      end
    end

    test "bad syntax and wrong types are 400 M_INVALID_PARAM and nothing is persisted", %{user: u} do
      room = make_room(u, %{"name" => "PUT syntax"})
      before_events = event_count(room, "m.room.canonical_alias")

      for {label, content} <- [
            not_an_alias: %{"alias" => "not-an-alias"},
            no_local: %{"alias" => "#nolocal"},
            empty_local: %{"alias" => "#:server"},
            empty_domain: %{"alias" => "#a:"},
            alias_number: %{"alias" => 5},
            alt_not_a_list: %{"alt_aliases" => "x"},
            alt_number_entry: %{"alt_aliases" => [5]}
          ] do
        conn = put_alias(u, room, content)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_INVALID_PARAM", "#{label}: #{conn.resp_body}"
        assert event_count(room, "m.room.canonical_alias") == before_events, "#{label}: nothing is persisted"
      end
    end

    test "a non-member is 403 whatever the alias (no alias-mapping oracle)", %{user: u, other: o} do
      localpart = "own-" <> T.rand(5)
      room = make_room(u, %{"room_alias_name" => localpart})

      for content <- [%{"alias" => alias_for(localpart)}, %{"alias" => alias_for("nobody-" <> T.rand(5))}, %{"alias" => "not-an-alias"}, %{"alias" => 5}] do
        conn = put_alias(o, room, content)
        assert conn.status == 403, "#{inspect(content)}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_FORBIDDEN"
      end
    end
  end

  # ─── AC10 ────────────────────────────────────────────────────────────────────

  describe "AC10 - content depth cap (32)" do
    test "an initial_state entry nesting 32 levels is 200, 33 levels is 400 M_BAD_JSON and creates no room", %{user: u} do
      entry = fn levels -> %{"type" => "m.test.depth", "content" => nested(levels)} end

      room = make_room(u, %{"name" => "depth 32", "initial_state" => [entry.(32)]})
      assert event_count(room, "m.test.depth") == 1

      assert_rejected(u, %{"name" => "depth 33", "initial_state" => [entry.(33)]}, 400, "M_BAD_JSON", "33 levels")
    end

    test "a PUT state body nesting 32 levels is 200, 33 levels is 400 M_BAD_JSON and persists nothing", %{user: u} do
      room = make_room(u, %{"name" => "PUT depth"})

      assert put_state(u, room, "m.room.topic", nested(32)).status == 200
      before_events = event_count(room, "m.room.topic")

      conn = put_state(u, room, "m.room.topic", nested(33))
      assert conn.status == 400, conn.resp_body
      assert T.json(conn)["errcode"] == "M_BAD_JSON"
      assert event_count(room, "m.room.topic") == before_events
    end

    test "a PUT state body with a NUL in a key or a value is 400 M_BAD_JSON (was a 500), nothing is persisted", %{user: u} do
      room = make_room(u, %{"name" => "PUT NUL"})
      before_events = event_count(room, "m.room.topic")

      for {label, body} <- [value: %{"topic" => "a\u0000b"}, key: %{"a\u0000b" => "x"}, nested: %{"topic" => "ok", "x" => [%{"y" => "\u0000"}]}] do
        conn = put_state(u, room, "m.room.topic", body)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON", "#{label}: #{conn.resp_body}"
      end

      assert event_count(room, "m.room.topic") == before_events
    end
  end

  # ─── AC11 ────────────────────────────────────────────────────────────────────

  describe "AC11 - the name" do
    test "255 code points are 200 and rooms.name equals the name; 256 are 400 M_INVALID_PARAM and create no room", %{user: u} do
      name = String.duplicate("n", 255)
      room = make_room(u, %{"name" => name})
      assert room_name(room) == name

      assert_rejected(u, %{"name" => name <> "n"}, 400, "M_INVALID_PARAM", "256 code points")
      assert_rejected(u, %{"name" => String.duplicate("ä", 256)}, 400, "M_INVALID_PARAM", "256 multibyte code points")
    end

    test "a name with a NUL, 42, true and {} are 400 M_BAD_JSON and create no room", %{user: u} do
      for {label, name} <- [nul: "a\u0000b", number: 42, boolean: true, object: %{}] do
        assert_rejected(u, %{"name" => name}, 400, "M_BAD_JSON", "name #{label}")
      end
    end

    test "null, \"\" and an absent name are a nameless room (200, unchanged)", %{user: u} do
      for {label, body} <- [null: %{"name" => nil}, empty: %{"name" => ""}, absent: %{}] do
        room = make_room(u, body)
        assert event_count(room, "m.room.name") == 0, "name #{label}"
        assert room_name(room) in [nil, ""], "name #{label}"
      end
    end

    test "an initial_state m.room.name of 256 is 400 M_INVALID_PARAM, of 42 is 400 M_BAD_JSON, \"\" / {} / null are 200", %{user: u} do
      entry = fn content -> %{"type" => "m.room.name", "content" => content} end

      assert_rejected(u, %{"initial_state" => [entry.(%{"name" => String.duplicate("a", 256)})]}, 400, "M_INVALID_PARAM", "initial_state name 256")
      assert_rejected(u, %{"initial_state" => [entry.(%{"name" => 42})]}, 400, "M_BAD_JSON", "initial_state name 42")

      for content <- [%{"name" => ""}, %{}, %{"name" => nil}] do
        room = make_room(u, %{"initial_state" => [entry.(content)]})
        assert event_count(room, "m.room.name") == 1
      end
    end

    test "PUT m.room.name with 256 code points is 400 M_INVALID_PARAM: no new event, rooms.name unchanged; 255 is 200", %{user: u} do
      room = make_room(u, %{"name" => "Original"})
      before_events = event_count(room, "m.room.name")

      conn = put_state(u, room, "m.room.name", %{"name" => String.duplicate("a", 256)})
      assert conn.status == 400, conn.resp_body
      assert T.json(conn)["errcode"] == "M_INVALID_PARAM"
      assert event_count(room, "m.room.name") == before_events
      assert room_name(room) == "Original"

      assert put_state(u, room, "m.room.name", %{"name" => String.duplicate("a", 255)}).status == 200
      assert room_name(room) == String.duplicate("a", 255)
    end

    test "PUT m.room.name with {\"name\": \"\"}, {} and {\"name\": null} is 200 and rooms.name is the empty string", %{user: u} do
      for content <- [%{"name" => ""}, %{}, %{"name" => nil}] do
        room = make_room(u, %{"name" => "Before"})
        conn = put_state(u, room, "m.room.name", content)
        assert conn.status == 200, "#{inspect(content)}: #{conn.status} #{conn.resp_body}"
        assert room_name(room) == "", inspect(content)
      end
    end

    test "PUT m.room.name with {\"name\": 42} (and a name containing a NUL) is 400 M_BAD_JSON and persists nothing", %{user: u} do
      room = make_room(u, %{"name" => "Original"})
      before_events = event_count(room, "m.room.name")

      for {label, body} <- [number: %{"name" => 42}, nul: %{"name" => "a\u0000b"}] do
        conn = put_state(u, room, "m.room.name", body)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON", "#{label}: #{conn.resp_body}"
      end

      assert event_count(room, "m.room.name") == before_events
      assert room_name(room) == "Original"
    end
  end
end
