defmodule Nebu.Matrix.CreateRoomInitialStateHttpTest do
  @moduledoc """
  Integration tests for story `create-room-initial-state-conformance` (epic oauth-broker, follow-up `dx`):
  `POST /_matrix/client/v3/createRoom` and its `initial_state` over HTTP against the real supervision tree + PostgreSQL
  (users and sessions as in `room_summary_integration_test.exs`).

  The server honours `initial_state` (the unit suite `create_room_initial_state_test.exs` drives the Core); this file pins what only
  the HTTP layer decides: a structurally invalid `initial_state` (or a body that is not JSON) answers `400 M_BAD_JSON` BEFORE a room
  exists (nothing is created), `null` / missing / `[]` stay no-ops, the cap answers `400 M_INVALID_PARAM`, and the m.space.parent link
  of a room created inside the creator's Space is persisted with the Space id as `state_key` (the contract of K8).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @path "/_matrix/client/v3/createRoom"

  setup do
    T.reset_rate_limits()
    on_exit(fn -> T.restore_rate_limits() end)

    uid = T.provision_user!()
    {:ok, user: %{uid: uid, at: T.legacy_session!(uid, "CRIS" <> String.upcase(T.rand(3))).at}}
  end

  defp create(user, body), do: T.matrix_request(:post, @path, user.at, body: body)

  defp room_count, do: T.sql!("SELECT count(*) FROM rooms").rows |> hd() |> hd()

  # A request whose body is NOT valid JSON (T.matrix_request always encodes a map).
  defp create_raw(user, raw) do
    conn(:post, @path, raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.at)
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  defp assert_rejected(user, body, status, errcode, label) do
    before_rooms = room_count()
    conn = create(user, body)
    assert conn.status == status, "#{label}: expected #{status}, got #{conn.status} #{conn.resp_body}"
    assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
    assert room_count() == before_rooms, "#{label}: a rejected createRoom must not leave a room behind"
  end

  defp state_events(room_id, type) do
    T.sql!("SELECT state_key, content FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts", [room_id, type]).rows
  end

  defp content_of(c) when is_map(c), do: c
  defp content_of(c) when is_binary(c), do: Jason.decode!(c)

  describe "AC1 — the m.space.parent link of a room created inside the creator's Space is persisted" do
    test "m.space.parent + restricted join_rules in initial_state: the child room carries the parent edge, the Space id is the state_key",
         %{user: u} do
      space = create(u, %{"name" => "K8 Space #{T.rand(4)}", "creation_content" => %{"type" => "m.space"}})
      assert space.status == 200, space.resp_body
      space_id = T.json(space)["room_id"]

      child =
        create(u, %{
          "name" => "K8 Child #{T.rand(4)}",
          "initial_state" => [
            %{"type" => "m.space.parent", "state_key" => space_id, "content" => %{"via" => ["localhost"], "canonical" => true}},
            %{"type" => "m.room.join_rules", "content" => %{"join_rule" => "restricted", "allow" => [%{"type" => "m.room_membership", "room_id" => space_id}]}}
          ]
        })

      assert child.status == 200, child.resp_body
      child_id = T.json(child)["room_id"]

      parents = state_events(child_id, "m.space.parent")
      assert Enum.map(parents, &hd/1) == [space_id]
      assert parents |> hd() |> List.last() |> content_of() |> Map.get("canonical") == true

      join_rules = state_events(child_id, "m.room.join_rules")
      assert join_rules |> hd() |> List.last() |> content_of() |> Map.get("join_rule") == "restricted"
    end
  end

  describe "AC2 — a structurally invalid initial_state is a 400 M_BAD_JSON and creates nothing" do
    test "initial_state that is not an array (object, string, number, boolean)", %{user: u} do
      for {label, value} <- [object: %{"type" => "m.room.topic"}, string: "m.room.topic", number: 7, boolean: true] do
        assert_rejected(u, %{"name" => "bad #{label}", "initial_state" => value}, 400, "M_BAD_JSON", "initial_state as #{label}")
      end
    end

    test "an entry that is not an object (string, number, null, array)", %{user: u} do
      for {label, entry} <- [string: "x", number: 1, null: nil, array: [1]] do
        assert_rejected(u, %{"name" => "bad entry #{label}", "initial_state" => [entry]}, 400, "M_BAD_JSON", "entry as #{label}")
      end
    end

    test "an entry without a string type (missing, 123, empty string, null)", %{user: u} do
      for {label, entry} <- [
            missing: %{"content" => %{}},
            number: %{"type" => 123, "content" => %{}},
            empty: %{"type" => "", "content" => %{}},
            null: %{"type" => nil, "content" => %{}}
          ] do
        assert_rejected(u, %{"name" => "bad type #{label}", "initial_state" => [entry]}, 400, "M_BAD_JSON", "type #{label}")
      end
    end

    test "an entry with a state_key that is not a string (5, null, array, object)", %{user: u} do
      for {label, key} <- [number: 5, null: nil, array: ["a"], object: %{"a" => 1}] do
        entry = %{"type" => "m.room.topic", "state_key" => key, "content" => %{"topic" => "t"}}
        assert_rejected(u, %{"name" => "bad key #{label}", "initial_state" => [entry]}, 400, "M_BAD_JSON", "state_key #{label}")
      end
    end

    test "an entry whose content is missing, null or not an object (string, array, number)", %{user: u} do
      for {label, entry} <- [
            missing: %{"type" => "m.room.topic"},
            null: %{"type" => "m.room.topic", "content" => nil},
            string: %{"type" => "m.room.topic", "content" => "x"},
            array: %{"type" => "m.room.topic", "content" => [1]},
            number: %{"type" => "m.room.topic", "content" => 3}
          ] do
        assert_rejected(u, %{"name" => "bad content #{label}", "initial_state" => [entry]}, 400, "M_BAD_JSON", "content #{label}")
      end
    end

    test "a NUL character (\\u0000) in the type, the state_key or the content is a 400 M_BAD_JSON, not a 500 after the room was created", %{user: u} do
      for {label, entry} <- [
            type: %{"type" => "m.test.\u0000", "content" => %{}},
            state_key: %{"type" => "m.test", "state_key" => "a\u0000b", "content" => %{}},
            content: %{"type" => "m.room.topic", "content" => %{"topic" => "x\u0000y"}},
            nested: %{"type" => "m.test", "content" => %{"a" => [%{"b" => "\u0000"}]}}
          ] do
        assert_rejected(u, %{"name" => "nul #{label}", "initial_state" => [entry]}, 400, "M_BAD_JSON", "NUL in #{label}")
      end
    end

    test "one bad entry among valid ones rejects the whole request, nothing is created", %{user: u} do
      good = %{"type" => "m.room.topic", "content" => %{"topic" => "t"}}
      assert_rejected(u, %{"name" => "mixed", "initial_state" => [good, %{"type" => "m.room.guest_access"}, good]}, 400, "M_BAD_JSON", "mixed")
    end

    test "65 entries answer 400 M_INVALID_PARAM (the cap), 64 are accepted", %{user: u} do
      entry = fn i -> %{"type" => "m.test.entry", "state_key" => "k#{i}", "content" => %{"i" => i}} end
      assert_rejected(u, %{"name" => "cap 65", "initial_state" => Enum.map(1..65, entry)}, 400, "M_INVALID_PARAM", "65 entries")

      ok = create(u, %{"name" => "cap 64", "initial_state" => Enum.map(1..64, entry)})
      assert ok.status == 200, ok.resp_body
    end

    test "null, a missing field and an empty array stay no-ops (200)", %{user: u} do
      for {label, body} <- [
            null: %{"name" => "is null", "initial_state" => nil},
            missing: %{"name" => "is missing"},
            empty: %{"name" => "is empty", "initial_state" => []}
          ] do
        conn = create(u, body)
        assert conn.status == 200, "#{label}: #{conn.status} #{conn.resp_body}"
        assert String.starts_with?(T.json(conn)["room_id"], "!")
      end
    end

    test "an entry without state_key is a valid entry (state_key defaults to the empty string)", %{user: u} do
      conn = create(u, %{"name" => "no key", "initial_state" => [%{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}}]})
      assert conn.status == 200, conn.resp_body
      assert [[key, _content]] = state_events(T.json(conn)["room_id"], "m.room.guest_access")
      assert key == ""
    end
  end

  describe "AC3 — a body that is not JSON is 400 M_NOT_JSON, JSON that is not an object 400 M_BAD_JSON, nothing is created" do
    test "truncated JSON and plain text are M_NOT_JSON; a JSON array, number and string are M_BAD_JSON", %{user: u} do
      for {label, raw, errcode} <- [
            {:truncated, ~s({"name": "x", "initial_state": [), "M_NOT_JSON"},
            {:text, "not json at all", "M_NOT_JSON"},
            {:array, "[1]", "M_BAD_JSON"},
            {:number, "42", "M_BAD_JSON"},
            {:string, ~s("x"), "M_BAD_JSON"}
          ] do
        before_rooms = room_count()
        conn = create_raw(u, raw)
        assert conn.status == 400, "#{label}: #{conn.status} #{conn.resp_body}"
        assert T.json(conn)["errcode"] == errcode, "#{label}: #{conn.resp_body}"
        assert room_count() == before_rooms, "#{label}: no room"
      end
    end

    test "an empty object and an empty body are still a valid createRoom (a nameless room, 200)", %{user: u} do
      assert create(u, %{}).status == 200
      assert create_raw(u, "").status == 200
    end
  end

  describe "AC4 — the privileged types stay unpersisted over HTTP (the room is still created)" do
    # story power-levels-enforcement (D7, AC16 re-pin): m.room.power_levels left the skipped list (an entry is APPLIED as a v10 change
    # by the creator); its escalation guard is the change rule, pinned by the next test
    # story state-writer-redaction (D10 (b), AC15 (e) re-pin; old -> new): a FOREIGN m.room.member entry was skipped here (200); it is refused now
    # (400, the next test: the stricter Nebu `@` rule on every entry). The skipped member entry of this test is the creator's OWN one (still skipped);
    # every other assertion is unchanged.
    test "m.room.encryption, m.room.tombstone, m.room.third_party_invite and the creator's own m.room.member are skipped; a plain entry applies", %{user: u} do
      conn =
        create(u, %{
          "name" => "guarded #{T.rand(3)}",
          "initial_state" => [
            %{"type" => "m.room.encryption", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}},
            %{"type" => "m.room.tombstone", "content" => %{"body" => "x", "replacement_room" => "!other:localhost"}},
            %{"type" => "m.room.third_party_invite", "state_key" => "tok", "content" => %{"display_name" => "x"}},
            %{"type" => "m.room.member", "state_key" => u.uid, "content" => %{"membership" => "leave"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "kept"}}
          ]
        })

      assert conn.status == 200, conn.resp_body
      room = T.json(conn)["room_id"]

      for type <- ["m.room.encryption", "m.room.tombstone", "m.room.third_party_invite"] do
        assert state_events(room, type) == [], "#{type} must not be persisted via initial_state"
      end

      assert state_events(room, "m.room.member") |> Enum.map(&hd/1) == [u.uid], "only the creator is a member"
      assert [[_, member]] = state_events(room, "m.room.member")
      assert content_of(member)["membership"] == "join", "the creator's own member entry is skipped (no leave written)"
      assert [[_, _]] = state_events(room, "m.room.topic")
      assert length(state_events(room, "m.room.create")) == 1, "exactly one (the server's) m.room.create"

      for [_key, content] <- state_events(room, "m.room.power_levels") do
        refute inspect(content_of(content)) =~ "@evil:localhost", "initial_state must not escalate a foreign user"
      end
    end

    # story state-writer-redaction (D10 (b), AC15 (e)): the foreign m.room.member entry of the previous test (formerly skipped, 200) is refused
    test "a foreign m.room.member entry is 400 M_INVALID_ROOM_STATE and no room is created (it was skipped)", %{user: u} do
      before_rooms = room_count()

      conn =
        create(u, %{
          "name" => "guarded #{T.rand(3)}",
          "initial_state" => [
            %{"type" => "m.room.member", "state_key" => "@evil:localhost", "content" => %{"membership" => "join"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "kept"}}
          ]
        })

      assert conn.status == 400, conn.resp_body
      assert T.json(conn) == %{"errcode" => "M_INVALID_ROOM_STATE", "error" => "The initial state contains a state key of another user"}
      assert room_count() == before_rooms, "no room"
    end

    test "an m.room.power_levels entry granting a foreign user more than the creator has is 400 M_INVALID_ROOM_STATE and no room is created", %{user: u} do
      before_rooms = room_count()

      conn =
        create(u, %{
          "name" => "guarded #{T.rand(3)}",
          "initial_state" => [%{"type" => "m.room.power_levels", "content" => %{"users" => %{u.uid => 100, "@evil:localhost" => 101}}}]
        })

      assert conn.status == 400, conn.resp_body
      assert T.json(conn) == %{"errcode" => "M_INVALID_ROOM_STATE", "error" => "The initial power levels cannot grant more than the room creator has"}
      assert room_count() == before_rooms, "no room"
    end
  end

  describe "AC5 — m.room.name in initial_state and the real rooms.name column" do
    defp room_name(room_id), do: T.sql!("SELECT name FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd()

    test "without a top-level name the entry sets rooms.name; with a top-level name that one wins; a non-empty state_key does not touch it", %{user: u} do
      entry = fn name, key -> %{"type" => "m.room.name", "state_key" => key, "content" => %{"name" => name}} end

      c1 = create(u, %{"initial_state" => [entry.("From entry", "")]})
      assert c1.status == 200, c1.resp_body
      assert room_name(T.json(c1)["room_id"]) == "From entry"

      c2 = create(u, %{"name" => "Top level", "initial_state" => [entry.("From entry", "")]})
      assert c2.status == 200, c2.resp_body
      assert room_name(T.json(c2)["room_id"]) == "Top level"

      c3 = create(u, %{"initial_state" => [entry.("Not the room name", "x")]})
      assert c3.status == 200, c3.resp_body
      assert room_name(T.json(c3)["room_id"]) in [nil, ""]
    end
  end
end
