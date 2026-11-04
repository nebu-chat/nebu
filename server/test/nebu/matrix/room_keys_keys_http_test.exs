defmodule Nebu.Matrix.RoomKeysKeysHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`, legacy opaque sessions) of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011), the KEY routes
  of the Matrix CS v1.18 "Server-side key backups": `PUT|GET|DELETE /_matrix/client/v3/room_keys/keys`, `/keys/{roomId}` and `/keys/{roomId}/{sessionId}`, all with `?version=`.

  Gherkin scenario 2 (store session keys, read them back with count and etag), 3 (a better session replaces the stored one), 4 (writing to a version that is not the current one
  is refused) and 5 (another user cannot read my backup; the key half), plus the story's constraints:

    * the three body shapes and the three read / delete granularities, `{count, etag}` answers, `{"rooms":{}}` / `{"sessions":{}}` for empty reads, the bare KeyBackupData of the
      single-session read, the exact KeyBackupData members, opaque session_data fidelity;
    * the MERGE RULE in the spec order (verified differs: keep the verified one; else lower first_message_index; if equal, lower forwarded_count; a full tie keeps the stored
      session), the count that does not change on a replace, the etag that changes whenever the stored set changes (and is the one GET /version reports);
    * the version resolution: `version` is required (400 M_MISSING_PARAM), a write to a version that is not the current one is 403 M_WRONG_ROOM_KEYS_VERSION with the top-level
      `current_version` (404 M_NOT_FOUND when the user has no backup at all), reads and deletes work on every own non-deleted version and answer 404 for anything else;
    * body validation (M_MISSING_PARAM / M_INVALID_PARAM / M_NOT_JSON / M_BAD_JSON, all or nothing: one invalid entry stores nothing), integer bounds of the megolm indexes (u32), id
      lengths, awkward room / session ids (percent-encoding is decoded exactly once);
    * per-user isolation (also when two users' version numbers coincide).

  Sizes, quotas and the rate limit are `room_keys_limits_http_test.exs`, the races `room_keys_concurrency_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @moduletag :integration

  @room "!room1:test.local"
  @room2 "!room2:test.local"

  setup do
    RK.disable_rate_limit()
    u = RK.user!()
    {:ok, u: u, v: RK.create!(u)}
  end

  # the three body shapes of a key write
  defp put_via(:rooms, at, v, room, sid, kbd), do: RK.put_rooms(at, v, %{room => %{sid => kbd}})
  defp put_via(:room, at, v, room, sid, kbd), do: RK.put_room(at, v, room, %{sid => kbd})
  defp put_via(:session, at, v, room, sid, kbd), do: RK.put_session(at, v, room, sid, kbd)

  @shapes [:rooms, :room, :session]

  defp stored(u, v), do: RK.sessions!(u.at, v)

  # ═══ Scenario 2 - store session keys and read them back with count and etag ════════════════════════════════════════════

  describe "Scenario 2 - store and read back" do
    test "PUT /keys answers 200 {count: 1, etag}, GET /keys returns the same session_data, GET /version carries the same count and etag", %{u: u, v: v} do
      kbd = RK.kbd(10, 2, false)
      put = RK.put_rooms(u.at, v, %{@room => %{"sess1" => kbd}})
      assert {1, etag} = RK.count_etag!(put)
      assert (Nebu.OAuth.TestSupport.header(put, "content-type") || "") =~ "application/json"

      get = RK.get_keys(u.at, v)
      assert get.status == 200
      assert RK.json(get) == %{"rooms" => %{@room => %{"sessions" => %{"sess1" => kbd}}}}, "exactly the stored session, wrapped as the spec says"

      info = RK.info!(u.at, v)
      assert info["count"] === 1 and info["etag"] == etag, "the etag of the write answer is the etag of the backup"
      assert RK.info!(u.at)["etag"] == etag
    end

    test "a fresh version reads as {\"rooms\":{}}, {\"sessions\":{}} (not 404) for a room and 404 for a single session", %{u: u, v: v} do
      assert RK.json(RK.get_keys(u.at, v)) == %{"rooms" => %{}}
      assert RK.get_keys(u.at, v, @room).status == 200
      assert RK.json(RK.get_keys(u.at, v, @room)) == %{"sessions" => %{}}
      RK.assert_error(RK.get_keys(u.at, v, @room, "nope"), 404, "M_NOT_FOUND")
    end

    test "the three body shapes store the same thing; the three read granularities return the right slice; count follows", %{u: u, v: v} do
      k1 = RK.kbd(1, 0, false)
      k2 = RK.kbd(2, 0, true)
      k3 = RK.kbd(3, 1, false)
      k4 = RK.kbd(4, 2, true)

      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s1", k1))
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, v, @room, %{"s2" => k2}))
      assert {4, _} = RK.count_etag!(RK.put_rooms(u.at, v, %{@room => %{"s3" => k3}, @room2 => %{"s4" => k4}}))

      assert RK.json(RK.get_keys(u.at, v)) == %{"rooms" => %{@room => %{"sessions" => %{"s1" => k1, "s2" => k2, "s3" => k3}}, @room2 => %{"sessions" => %{"s4" => k4}}}}
      assert RK.json(RK.get_keys(u.at, v, @room)) == %{"sessions" => %{"s1" => k1, "s2" => k2, "s3" => k3}}
      assert RK.json(RK.get_keys(u.at, v, @room2)) == %{"sessions" => %{"s4" => k4}}
      assert RK.json(RK.get_keys(u.at, v, @room, "s2")) == k2, "the single read is the BARE KeyBackupData (no wrapper)"
      RK.assert_error(RK.get_keys(u.at, v, @room2, "s1"), 404, "M_NOT_FOUND")
      RK.assert_error(RK.get_keys(u.at, v, "!never:test.local", "s1"), 404, "M_NOT_FOUND")
      assert RK.json(RK.get_keys(u.at, v, "!never:test.local")) == %{"sessions" => %{}}
    end

    test "the same session id in two rooms is two sessions", %{u: u, v: v} do
      assert {2, _} = RK.count_etag!(RK.put_rooms(u.at, v, %{@room => %{"same" => RK.kbd(1, 0, false)}, @room2 => %{"same" => RK.kbd(2, 0, false)}}))
      assert stored(u, v)[{@room, "same"}]["first_message_index"] == 1
      assert stored(u, v)[{@room2, "same"}]["first_message_index"] == 2
    end

    test "a KeyBackupData has exactly first_message_index, forwarded_count, is_verified and session_data - no server-side members leak", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(7, 3, true)))
      one = RK.json(RK.get_keys(u.at, v, @room, "s"))
      assert Enum.sort(Map.keys(one)) == ["first_message_index", "forwarded_count", "is_verified", "session_data"]
      assert one["first_message_index"] === 7 and one["forwarded_count"] === 3 and one["is_verified"] === true and is_map(one["session_data"])
    end

    test "session_data is opaque JSON: unicode, nesting, numbers, null, booleans, empty containers and a NUL escape come back equal", %{u: u, v: v} do
      data = %{
        "ephemeral" => "eph",
        "ciphertext" => "ct+/=",
        "mac" => "mac",
        "extra" => %{"list" => [1, 2.5, 12_345_678_901_234_567_890, true, false, nil, "", [], %{}, "é漢😀", "a\u0000b", "line\nbreak \"quoted\" back\\slash"], "deep" => %{"a" => %{"b" => [%{"c" => nil}]}}},
        "null" => nil
      }

      kbd = RK.kbd(0, 0, false, data)
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", kbd))
      assert RK.json(RK.get_keys(u.at, v, @room, "s")) == kbd
      assert RK.sessions!(u.at, v)[{@room, "s"}] == kbd
    end

    test "an older (non-current) version is readable and holds its own keys; the current one starts empty", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "old", RK.kbd(1, 0, false)))
      newer = RK.create!(u, RK.auth_data("newer"))

      assert Map.keys(stored(u, v)) == [{@room, "old"}], "the older version is still readable"
      assert RK.json(RK.get_keys(u.at, newer)) == %{"rooms" => %{}}
      assert RK.info!(u.at, v)["count"] === 1 and RK.info!(u.at, newer)["count"] === 0
      assert RK.info!(u.at)["version"] == newer
    end

    test "a write reaches only its version: the same room and session id in two versions are independent", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => "in-old"})))
      newer = RK.create!(u, RK.auth_data("newer"))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, newer, @room, "s", RK.kbd(9, 0, false, %{"c" => "in-new"})))

      assert stored(u, v)[{@room, "s"}]["session_data"] == %{"c" => "in-old"}
      assert stored(u, newer)[{@room, "s"}]["session_data"] == %{"c" => "in-new"}
    end
  end

  # ═══ Scenario 3 - the merge rule ═══════════════════════════════════════════════════════════════════════════════════════

  # {label, stored {first_message_index, forwarded_count, is_verified}, incoming {...}, :replace | :keep}
  @merge_cases [
    {"story scenario: stored index 10 unverified, incoming index 5 verified", {10, 0, false}, {5, 0, true}, :replace},
    {"verified differs, the incoming one is verified: replaced although its index is HIGHER", {1, 0, false}, {100, 9, true}, :replace},
    {"verified differs, the stored one is verified: kept although the incoming index is LOWER", {5, 3, true}, {1, 0, false}, :keep},
    {"both unverified, lower first_message_index: replaced although forwarded_count is higher", {10, 0, false}, {5, 9, false}, :replace},
    {"both unverified, higher first_message_index: kept although forwarded_count is lower", {5, 9, false}, {10, 0, false}, :keep},
    {"both unverified, equal index, lower forwarded_count: replaced", {5, 4, false}, {5, 1, false}, :replace},
    {"both unverified, equal index, higher forwarded_count: kept", {5, 1, false}, {5, 4, false}, :keep},
    {"both unverified, full tie: the stored session is kept", {5, 1, false}, {5, 1, false}, :keep},
    {"both verified, lower first_message_index: replaced", {10, 0, true}, {5, 9, true}, :replace},
    {"both verified, higher first_message_index: kept", {5, 9, true}, {10, 0, true}, :keep},
    {"both verified, equal index, lower forwarded_count: replaced", {5, 4, true}, {5, 1, true}, :replace},
    {"both verified, equal index, higher forwarded_count: kept", {5, 1, true}, {5, 4, true}, :keep},
    {"both verified, full tie: the stored session is kept", {5, 1, true}, {5, 1, true}, :keep}
  ]

  describe "Scenario 3 - the merge rule of a re-uploaded session (spec order)" do
    for {{label, existing, incoming, expect}, i} <- Enum.with_index(@merge_cases) do
      test "#{label} (#{i})", %{u: u, v: v} do
        {efmi, efwd, ever} = unquote(Macro.escape(existing))
        {ifmi, ifwd, iver} = unquote(Macro.escape(incoming))
        old = RK.kbd(efmi, efwd, ever, %{"c" => "OLD"})
        new = RK.kbd(ifmi, ifwd, iver, %{"c" => "NEW"})

        assert {1, etag_before} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", old))
        {count, etag_after} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", new))
        assert count == 1, "a re-uploaded session is never counted twice"
        got = RK.json(RK.get_keys(u.at, v, @room, "s"))

        case unquote(expect) do
          :replace ->
            assert got == new, "the incoming session replaces the stored one (the WHOLE record), got #{inspect(got)}"
            assert etag_after != etag_before, "a replace changes the stored set: the etag changes"

          :keep ->
            assert got == old, "the stored session is kept, got #{inspect(got)}"
        end

        assert RK.info!(u.at, v)["count"] === 1
      end
    end

    test "the rule applies through every body shape (rooms / room / session), against a session stored through another shape", %{u: u, v: v} do
      for {shape, i} <- Enum.with_index(@shapes) do
        sid = "shape-#{i}"
        assert {_, _} = RK.count_etag!(put_via(:session, u.at, v, @room, sid, RK.kbd(10, 0, false, %{"c" => "OLD"})))
        assert {_, _} = RK.count_etag!(put_via(shape, u.at, v, @room, sid, RK.kbd(5, 0, true, %{"c" => "NEW"})))
        assert stored(u, v)[{@room, sid}]["session_data"] == %{"c" => "NEW"}, "#{shape}: a better session replaces"

        assert {_, _} = RK.count_etag!(put_via(shape, u.at, v, @room, sid, RK.kbd(20, 0, false, %{"c" => "WORSE"})))
        assert stored(u, v)[{@room, sid}]["session_data"] == %{"c" => "NEW"}, "#{shape}: a worse (unverified, higher index) session is ignored"
      end

      assert RK.info!(u.at, v)["count"] === 3
    end

    test "a batch mixing a new session, a replacement and a kept one counts only the new one", %{u: u, v: v} do
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, v, @room, %{"replace" => RK.kbd(9, 0, false, %{"c" => "OLD"}), "keep" => RK.kbd(1, 0, true, %{"c" => "OLD"})}))

      assert {3, _} =
               RK.count_etag!(
                 RK.put_room(u.at, v, @room, %{
                   "replace" => RK.kbd(2, 0, false, %{"c" => "NEW"}),
                   "keep" => RK.kbd(1, 0, false, %{"c" => "NEW"}),
                   "fresh" => RK.kbd(4, 0, false, %{"c" => "NEW"})
                 })
               )

      assert Map.new(stored(u, v), fn {k, kbd} -> {k, kbd["session_data"]["c"]} end) == %{{@room, "replace"} => "NEW", {@room, "keep"} => "OLD", {@room, "fresh"} => "NEW"}
    end

    test "the count is the number of distinct sessions however often they are re-uploaded", %{u: u, v: v} do
      for i <- 1..5, do: RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(100 - i, 0, false)))
      for i <- 1..3, do: RK.count_etag!(RK.put_session(u.at, v, @room, "t", RK.kbd(100 - i, 0, false)))
      assert RK.info!(u.at, v)["count"] === 2
      assert stored(u, v)[{@room, "s"}]["first_message_index"] == 95
    end
  end

  # ═══ etag and count ════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "etag and count" do
    test "the etag changes with every change of the stored set (insert, replace, delete) and is stable across reads; count follows", %{u: u, v: v} do
      e0 = RK.info!(u.at, v)["etag"]
      assert RK.info!(u.at, v)["etag"] == e0 and RK.info!(u.at)["etag"] == e0, "reads do not change the etag"

      assert {1, e1} = RK.count_etag!(RK.put_session(u.at, v, @room, "a", RK.kbd(10, 0, false)))
      assert {2, e2} = RK.count_etag!(RK.put_session(u.at, v, @room, "b", RK.kbd(10, 0, false)))
      assert {2, e3} = RK.count_etag!(RK.put_session(u.at, v, @room, "a", RK.kbd(5, 0, false, %{"c" => "better"})))
      assert {1, e4} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "b"))
      assert {0, e5} = RK.count_etag!(RK.delete_keys(u.at, v))

      for {before, after_} <- [{e0, e1}, {e1, e2}, {e2, e3}, {e3, e4}, {e4, e5}], do: assert(before != after_, "the stored set changed, the etag must change")
      assert RK.info!(u.at, v)["etag"] == e5
      assert RK.info!(u.at, v)["count"] === 0
    end

    test "two versions of a user have their own count and etag", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "a", RK.kbd(1, 0, false)))
      newer = RK.create!(u)
      assert RK.info!(u.at, newer)["count"] === 0
      assert RK.info!(u.at, v)["count"] === 1
    end

    test "count is an integer and etag a string in every answer of the three write shapes and the three deletes", %{u: u, v: v} do
      for shape <- @shapes, do: RK.count_etag!(put_via(shape, u.at, v, @room, "x-#{shape}", RK.kbd(1, 0, false)))
      RK.count_etag!(RK.delete_keys(u.at, v, @room, "x-room"))
      RK.count_etag!(RK.delete_keys(u.at, v, @room))
      RK.count_etag!(RK.delete_keys(u.at, v))
    end
  end

  # ═══ DELETE /keys ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "DELETE /keys, /keys/{room}, /keys/{room}/{session}" do
    setup %{u: u, v: v} do
      assert {4, _} =
               RK.count_etag!(
                 RK.put_rooms(u.at, v, %{@room => %{"s1" => RK.kbd(1, 0, false), "s2" => RK.kbd(2, 0, false), "s3" => RK.kbd(3, 0, false)}, @room2 => %{"s4" => RK.kbd(4, 0, false)}})
               )

      :ok
    end

    test "one session: 200 {count: remaining, etag}; the others stay; deleting a session that is not there is 200 with the same count", %{u: u, v: v} do
      assert {3, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s2"))
      assert Enum.sort(Map.keys(stored(u, v))) == Enum.sort([{@room, "s1"}, {@room, "s3"}, {@room2, "s4"}])
      assert {3, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s2")), "an already deleted session: 200, count unchanged"
      assert {3, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "never-there"))
      RK.assert_error(RK.get_keys(u.at, v, @room, "s2"), 404, "M_NOT_FOUND")
    end

    test "one room: all its sessions go, the other room stays", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room))
      assert Map.keys(stored(u, v)) == [{@room2, "s4"}]
      assert RK.json(RK.get_keys(u.at, v, @room)) == %{"sessions" => %{}}
      assert {1, _} = RK.count_etag!(RK.delete_keys(u.at, v, "!never:test.local"))
    end

    test "all keys of the version: count 0, {\"rooms\":{}}; the version itself stays and can be written again", %{u: u, v: v} do
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v))
      assert RK.json(RK.get_keys(u.at, v)) == %{"rooms" => %{}}
      assert RK.info!(u.at, v)["count"] === 0
      assert RK.rows(RK.sessions_table(), u.uid) == 0
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s1", RK.kbd(1, 0, false))), "a deleted key can be uploaded again"
    end

    test "deleting keys of an older, non-current version is allowed (not restricted to the current one)", %{u: u, v: v} do
      newer = RK.create!(u)
      assert {3, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room2, "s4"))
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v))
      assert RK.info!(u.at)["version"] == newer
    end

    test "an unknown, deleted or malformed version is 404 M_NOT_FOUND on all three deletes and changes nothing", %{u: u, v: v} do
      gone = RK.create!(u)
      assert RK.delete_version(u.at, gone).status == 200

      for version <- ["424242", gone, "abc", "01", "-1"], {room, sid} <- [{nil, nil}, {@room, nil}, {@room, "s1"}] do
        RK.assert_error(RK.delete_keys(u.at, version, room, sid), 404, "M_NOT_FOUND")
      end

      assert RK.info!(u.at, v)["count"] === 4
    end
  end

  # ═══ Scenario 4 - the version resolution of key writes ═════════════════════════════════════════════════════════════════

  describe "Scenario 4 - writing to a version that is not the current one" do
    test "current version 2, version 1 exists: PUT ?version=1 is 403 M_WRONG_ROOM_KEYS_VERSION with current_version \"2\" and stores nothing (all three shapes)", %{u: u, v: v1} do
      v2 = RK.create!(u, RK.auth_data("second"))
      assert String.to_integer(v2) > String.to_integer(v1)

      for shape <- @shapes do
        body = RK.assert_error(put_via(shape, u.at, v1, @room, "s", RK.kbd(1, 0, false)), 403, "M_WRONG_ROOM_KEYS_VERSION")
        assert body["current_version"] == v2, "the top-level `current_version` names the current version (a string), #{shape}"
        assert Enum.sort(Map.keys(body)) == ["current_version", "errcode", "error"]
      end

      assert RK.info!(u.at, v1)["count"] === 0 and RK.info!(u.at, v2)["count"] === 0
      assert RK.rows(RK.sessions_table(), u.uid) == 0
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v2, @room, "s", RK.kbd(1, 0, false))), "the current version accepts the write"
    end

    test "a deleted, a never issued and a malformed version are 403 M_WRONG_ROOM_KEYS_VERSION as well (the user HAS a current version)", %{u: u, v: v} do
      gone = RK.create!(u)
      assert RK.delete_version(u.at, gone).status == 200
      # the current version is `v` again (the newest remaining one)

      for version <- [gone, "424242", "abc", "01", "99999999999999999999999"], shape <- @shapes do
        body = RK.assert_error(put_via(shape, u.at, version, @room, "s", RK.kbd(1, 0, false)), 403, "M_WRONG_ROOM_KEYS_VERSION")
        assert body["current_version"] == v
      end

      assert RK.rows(RK.sessions_table(), u.uid) == 0
    end

    test "after a new version is created the old current one is refused, with the new one named", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)))
      newer = RK.create!(u)
      body = RK.assert_error(RK.put_session(u.at, v, @room, "s2", RK.kbd(1, 0, false)), 403, "M_WRONG_ROOM_KEYS_VERSION")
      assert body["current_version"] == newer
      assert RK.info!(u.at, v)["count"] === 1
    end

    test "a user without any backup version gets 404 M_NOT_FOUND on a key write (no current version to name), also after deleting the last one" do
      u = RK.user!()
      for shape <- @shapes, do: RK.assert_error(put_via(shape, u.at, "1", @room, "s", RK.kbd(1, 0, false)), 404, "M_NOT_FOUND")

      v = RK.create!(u)
      assert RK.delete_version(u.at, v).status == 200
      for shape <- @shapes, do: RK.assert_error(put_via(shape, u.at, v, @room, "s", RK.kbd(1, 0, false)), 404, "M_NOT_FOUND")
      assert RK.rows(RK.sessions_table(), u.uid) == 0
    end
  end

  describe "the `version` query parameter" do
    test "is required on every key route: 400 M_MISSING_PARAM (also when empty)", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)))
      body = RK.kbd(1, 0, false)

      for version <- [nil, ""] do
        RK.assert_error(RK.put_rooms(u.at, version, %{@room => %{"s2" => body}}), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.put_room(u.at, version, @room, %{"s2" => body}), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.put_session(u.at, version, @room, "s2", body), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.get_keys(u.at, version), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.get_keys(u.at, version, @room), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.get_keys(u.at, version, @room, "s"), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.delete_keys(u.at, version), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.delete_keys(u.at, version, @room), 400, "M_MISSING_PARAM")
        RK.assert_error(RK.delete_keys(u.at, version, @room, "s"), 400, "M_MISSING_PARAM")
      end

      assert RK.info!(u.at, v)["count"] === 1, "nothing was written or deleted by the refused requests"
    end

    test "an unknown, a deleted or a malformed version is 404 M_NOT_FOUND on every read", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)))
      gone = RK.create!(u)
      assert RK.delete_version(u.at, gone).status == 200

      for version <- ["424242", gone, "abc", "01", "-1", "99999999999999999999999", "٣"] do
        RK.assert_error(RK.get_keys(u.at, version), 404, "M_NOT_FOUND")
        RK.assert_error(RK.get_keys(u.at, version, @room), 404, "M_NOT_FOUND")
        RK.assert_error(RK.get_keys(u.at, version, @room, "s"), 404, "M_NOT_FOUND")
      end
    end

    test "the version query value is read as given: a version with surrounding blanks or a plus is not the number it contains", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)))

      for version <- [" " <> v, v <> " ", "+" <> v, "0" <> v] do
        RK.assert_error(RK.get_keys(u.at, version), 404, "M_NOT_FOUND")
      end
    end
  end

  # ═══ body validation ═══════════════════════════════════════════════════════════════════════════════════════════════════

  describe "key write validation (all or nothing)" do
    defp base, do: RK.kbd(5, 1, false)

    defp assert_untouched(u, v, count) do
      assert RK.info!(u.at, v)["count"] === count, "a refused write changed the stored set"
      assert RK.rows(RK.sessions_table(), u.uid) == count
    end

    test "every KeyBackupData member is required (400 M_MISSING_PARAM), through every shape", %{u: u, v: v} do
      for shape <- @shapes, field <- ["first_message_index", "forwarded_count", "is_verified", "session_data"] do
        RK.assert_error(put_via(shape, u.at, v, @room, "s", Map.delete(base(), field)), 400, "M_MISSING_PARAM")
      end

      assert_untouched(u, v, 0)
    end

    test "a mistyped member is 400 M_INVALID_PARAM, through every shape", %{u: u, v: v} do
      invalid = [
        {"first_message_index", ["1", 1.5, nil, true, [], %{}, -1, 4_294_967_296, 99_999_999_999_999_999_999]},
        {"forwarded_count", ["1", 1.5, nil, true, [], %{}, -1, 4_294_967_296, 99_999_999_999_999_999_999]},
        {"is_verified", ["true", 1, 0, nil, [], %{}]},
        {"session_data", ["text", 5, [], nil, true]}
      ]

      for shape <- @shapes, {field, values} <- invalid, value <- values do
        c = put_via(shape, u.at, v, @room, "s", Map.put(base(), field, value))
        assert c.status == 400, "#{shape} #{field}=#{inspect(value)}: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
        assert RK.json(c)["errcode"] == "M_INVALID_PARAM", "#{shape} #{field}=#{inspect(value)}: #{c.resp_body}"
      end

      assert_untouched(u, v, 0)
    end

    test "the megolm indexes are unsigned 32 bit numbers: 0 and 4 294 967 295 are accepted", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "lo", RK.kbd(0, 0, false)))
      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "hi", RK.kbd(4_294_967_295, 4_294_967_295, false)))
      hi = RK.json(RK.get_keys(u.at, v, @room, "hi"))
      assert hi["first_message_index"] === 4_294_967_295 and hi["forwarded_count"] === 4_294_967_295
    end

    test "a wrapper of the wrong shape: missing `rooms` / `sessions` is 400 M_MISSING_PARAM, a non-object one 400 M_INVALID_PARAM", %{u: u, v: v} do
      put = fn path_v, room, sid, body -> RK.req(:put, RK.keys_path(path_v, room, sid), u.at, body) end

      RK.assert_error(put.(v, nil, nil, %{}), 400, "M_MISSING_PARAM")
      RK.assert_error(put.(v, nil, nil, %{"rooms" => %{@room => %{}}}), 400, "M_MISSING_PARAM")
      RK.assert_error(put.(v, @room, nil, %{}), 400, "M_MISSING_PARAM")
      RK.assert_error(put.(v, @room, "s", %{}), 400, "M_MISSING_PARAM")

      for bad <- [[], "x", 5, nil, true] do
        RK.assert_error(put.(v, nil, nil, %{"rooms" => bad}), 400, "M_INVALID_PARAM")
        RK.assert_error(put.(v, @room, nil, %{"sessions" => bad}), 400, "M_INVALID_PARAM")
        RK.assert_error(put.(v, nil, nil, %{"rooms" => %{@room => bad}}), 400, "M_INVALID_PARAM")
        RK.assert_error(put.(v, nil, nil, %{"rooms" => %{@room => %{"sessions" => bad}}}), 400, "M_INVALID_PARAM")
        RK.assert_error(put.(v, nil, nil, %{"rooms" => %{@room => %{"sessions" => %{"s" => bad}}}}), 400, "M_INVALID_PARAM")
        RK.assert_error(put.(v, @room, nil, %{"sessions" => %{"s" => bad}}), 400, "M_INVALID_PARAM")
      end

      assert_untouched(u, v, 0)
    end

    test "a body that is not JSON is 400 M_NOT_JSON, JSON that is not an object 400 M_BAD_JSON", %{u: u, v: v} do
      for path <- [RK.keys_path(v), RK.keys_path(v, @room), RK.keys_path(v, @room, "s")] do
        RK.assert_error(RK.req(:put, path, u.at, {:raw, "{nope"}), 400, "M_NOT_JSON")
        RK.assert_error(RK.req(:put, path, u.at, {:raw, "[1,2]"}), 400, "M_BAD_JSON")
        RK.assert_error(RK.req(:put, path, u.at, {:raw, ~s("text")}), 400, "M_BAD_JSON")
      end

      assert_untouched(u, v, 0)
    end

    test "an id that is not valid text (invalid UTF-8, a NUL byte in the path) is 400 M_INVALID_PARAM on every route, never a 500", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "keep", base()))
      room = "%21room1%3Atest.local"

      for bad <- ["s%FF", "%FFs", "s%00x", "%00"] do
        for {method, path, body} <- [
              {:put, "#{RK.prefix()}/keys/#{room}/#{bad}?version=#{v}", base()},
              {:get, "#{RK.prefix()}/keys/#{room}/#{bad}?version=#{v}", nil},
              {:delete, "#{RK.prefix()}/keys/#{room}/#{bad}?version=#{v}", nil},
              {:put, "#{RK.prefix()}/keys/#{bad}?version=#{v}", %{"sessions" => %{"s" => base()}}},
              {:get, "#{RK.prefix()}/keys/#{bad}?version=#{v}", nil},
              {:delete, "#{RK.prefix()}/keys/#{bad}?version=#{v}", nil}
            ] do
          c = RK.req(method, path, u.at, body)
          assert {c.status, RK.json(c)["errcode"]} == {400, "M_INVALID_PARAM"}, "#{method} #{path}: #{c.status} #{String.slice(c.resp_body, 0, 160)}"
        end
      end

      assert_untouched(u, v, 1)
    end

    test "a version value with a NUL byte or invalid UTF-8 (path) is an unknown version: 404 on reads and deletes, 403 on writes, never a 500", %{u: u, v: v} do
      # (invalid UTF-8 in the QUERY string is refused by Plug itself before any route runs: the NUL byte is the query-side case)
      for bad <- ["%00", "1%00", v <> "%00"] do
        base_path = "#{RK.prefix()}/keys?version=#{bad}"
        RK.assert_error(RK.req(:get, base_path, u.at), 404, "M_NOT_FOUND")
        RK.assert_error(RK.req(:delete, base_path, u.at), 404, "M_NOT_FOUND")
        RK.assert_error(RK.req(:put, base_path, u.at, %{"rooms" => %{}}), 403, "M_WRONG_ROOM_KEYS_VERSION")
      end

      for bad <- ["%FF", "%00", "1%00", v <> "%FF"] do
        RK.assert_error(RK.req(:get, "#{RK.prefix()}/version/#{bad}", u.at), 404, "M_NOT_FOUND")
        RK.assert_error(RK.req(:put, "#{RK.prefix()}/version/#{bad}", u.at, %{"algorithm" => RK.algorithm(), "auth_data" => %{}}), 404, "M_NOT_FOUND")
        RK.assert_error(RK.req(:delete, "#{RK.prefix()}/version/#{bad}", u.at), 404, "M_NOT_FOUND")
      end
    end

    test "one invalid session in a batch stores NOTHING of the batch (all or nothing), also a valid replacement in it", %{u: u, v: v} do
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "keep", RK.kbd(10, 0, false, %{"c" => "OLD"})))

      c =
        RK.put_rooms(u.at, v, %{
          @room => %{"keep" => RK.kbd(1, 0, true, %{"c" => "WOULD-REPLACE"}), "good" => base(), "bad" => Map.put(base(), "is_verified", "yes")},
          @room2 => %{"also-good" => base()}
        })

      RK.assert_error(c, 400, "M_INVALID_PARAM")
      assert Map.keys(stored(u, v)) == [{@room, "keep"}]
      assert stored(u, v)[{@room, "keep"}]["session_data"] == %{"c" => "OLD"}
      assert RK.info!(u.at, v)["etag"] == etag
    end

    test "room and session ids: 1..255 bytes; an empty or longer one is 400 M_INVALID_PARAM (key in the body or path segment)", %{u: u, v: v} do
      room255 = "!" <> String.duplicate("r", 254)
      sid255 = String.duplicate("s", 255)
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, room255, sid255, base()))
      assert RK.json(RK.get_keys(u.at, v, room255, sid255)) == base()

      for shape <- @shapes do
        RK.assert_error(put_via(shape, u.at, v, room255 <> "x", "s", base()), 400, "M_INVALID_PARAM")
        RK.assert_error(put_via(shape, u.at, v, @room, sid255 <> "x", base()), 400, "M_INVALID_PARAM")
      end

      RK.assert_error(RK.put_rooms(u.at, v, %{@room => %{"" => base()}}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_rooms(u.at, v, %{"" => %{"s" => base()}}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_room(u.at, v, @room, %{"" => base()}), 400, "M_INVALID_PARAM")
      assert_untouched(u, v, 1)
    end

    test "an id of 128 two-byte characters is 256 bytes: the limit is in bytes, not characters", %{u: u, v: v} do
      wide = String.duplicate("é", 128)
      assert byte_size(wide) == 256
      RK.assert_error(RK.put_session(u.at, v, @room, wide, base()), 400, "M_INVALID_PARAM")
      assert_untouched(u, v, 0)
    end
  end

  # ═══ awkward ids ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "edge cases of the body and of the query" do
    test "a NUL (JSON escape) in a room or session id of the BODY is 400 M_INVALID_PARAM and stores nothing; in auth_data / session_data it is just content and round-trips", %{u: u, v: v} do
      RK.assert_error(RK.put_rooms(u.at, v, %{"!a\u0000b:test.local" => %{"s" => base()}}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_rooms(u.at, v, %{@room => %{"s\u0000x" => base()}}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_room(u.at, v, @room, %{"s\u0000x" => base()}), 400, "M_INVALID_PARAM")
      assert_untouched(u, v, 0)

      data = %{"k" => "a\u0000b", "n" => ["\u0000", "x\u0000"]}
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "nul-data", RK.kbd(1, 0, false, data)))
      assert RK.json(RK.get_keys(u.at, v, @room, "nul-data"))["session_data"] == data

      u2 = RK.user!()
      v2 = RK.create!(u2, %{"k" => "a\u0000b"})
      assert RK.info!(u2.at, v2)["auth_data"] == %{"k" => "a\u0000b"}
    end

    test "ids with SQL metacharacters are plain data (parameterised SQL): they round-trip through every shape and read / delete, and the tables are intact", %{u: u, v: v} do
      ids = ["x'); DROP TABLE room_key_backup_sessions; --", "\"quoted\"", "--", "%s %d $1 $2", "a\\b", "'; DELETE FROM room_key_backup_versions; --"]

      for {id, i} <- Enum.with_index(ids), shape <- @shapes do
        sid = "#{id}#{i}#{shape}"
        assert {_, _} = RK.count_etag!(put_via(shape, u.at, v, id, sid, base()))
        assert RK.json(RK.get_keys(u.at, v, id, sid)) == base(), "#{shape}: #{inspect(id)}"
      end

      assert RK.info!(u.at, v)["count"] === length(ids) * 3
      assert RK.rows(RK.versions_table(), u.uid) == 1 and RK.rows(RK.sessions_table(), u.uid) == length(ids) * 3
      for id <- ids, do: assert({_, _} = RK.count_etag!(RK.delete_keys(u.at, v, id)))
      assert RK.info!(u.at, v)["count"] === 0
    end

    test "valid EMPTY batches are 200 {count, etag} and change nothing: {\"rooms\":{}}, {\"sessions\":{}}, a room with no sessions", %{u: u, v: v} do
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", base()))

      assert {1, ^etag} = RK.count_etag!(RK.req(:put, RK.keys_path(v), u.at, %{"rooms" => %{}}))
      assert {1, ^etag} = RK.count_etag!(RK.req(:put, RK.keys_path(v, @room), u.at, %{"sessions" => %{}}))
      assert {1, ^etag} = RK.count_etag!(RK.req(:put, RK.keys_path(v), u.at, %{"rooms" => %{@room => %{"sessions" => %{}}}}))
      assert RK.info!(u.at, v)["etag"] == etag
    end

    test "an index written as a float (5.0) is 400 M_INVALID_PARAM (integers only)", %{u: u, v: v} do
      raw = ~s({"first_message_index":5.0,"forwarded_count":0,"is_verified":false,"session_data":{}})
      RK.assert_error(RK.req(:put, RK.keys_path(v, @room, "s"), u.at, {:raw, raw}), 400, "M_INVALID_PARAM")
      raw = ~s({"first_message_index":5,"forwarded_count":1e0,"is_verified":false,"session_data":{}})
      RK.assert_error(RK.req(:put, RK.keys_path(v, @room, "s"), u.at, {:raw, raw}), 400, "M_INVALID_PARAM")
      assert_untouched(u, v, 0)
    end

    test "a body with a non-JSON content type or without a body is a 400 (never stored, never a 5xx)", %{u: u, v: v} do
      json = Jason.encode!(base())

      for ct <- ["text/plain", "application/x-www-form-urlencoded", nil] do
        c = RK.req_ct(:put, RK.keys_path(v, @room, "s"), u.at, json, ct)
        assert c.status == 400 and RK.json(c)["errcode"] in ["M_NOT_JSON", "M_MISSING_PARAM"], "content type #{inspect(ct)}: #{c.status} #{String.slice(c.resp_body, 0, 120)}"
      end

      c = RK.req(:put, RK.version_path(v), u.at)
      assert c.status == 400 and RK.json(c)["errcode"] in ["M_NOT_JSON", "M_MISSING_PARAM"]
      assert_untouched(u, v, 0)
    end

    test "an array `version` query (version[]=1) is 400 M_MISSING_PARAM, a duplicated one never a 5xx", %{u: u, v: v} do
      RK.assert_error(RK.req(:get, "#{RK.prefix()}/keys?version[]=#{v}", u.at), 400, "M_MISSING_PARAM")
      RK.assert_error(RK.req(:put, "#{RK.prefix()}/keys?version[]=#{v}", u.at, %{"rooms" => %{}}), 400, "M_MISSING_PARAM")
      assert RK.req(:get, "#{RK.prefix()}/keys?version=#{v}&version=#{v}", u.at).status < 500
      assert RK.req(:get, "#{RK.prefix()}/keys?version=#{v}&version=999", u.at).status < 500
    end

    # cycle 1 (the response of the bulk reads is spliced from the stored JSON text, no decode / re-encode of each blob): the CONTRACT is structural equality; how the
    # response is built is not observable and not pinned (a memory test would be brittle)
    test "a big GET /keys (about 4 MB, 5 rooms, odd JSON values) and GET /keys/{room} return every session structurally equal to what was stored", %{u: u, v: v} do
      odd = fn i ->
        %{
          "ciphertext" => String.duplicate("é漢😀+/=", 150) <> "#{i}",
          "n" => [1, 2.5, -0.5, 12_345_678_901_234_567_890, true, false, nil, "", [], %{}, "a\u0000b", "q\"uo\\te\n"],
          "deep" => %{"a" => %{"b" => [%{"c" => nil, "d" => i}]}},
          "pad" => String.duplicate("x", 5_000)
        }
      end

      all =
        for room_n <- 1..5, into: %{} do
          sessions = for i <- 1..120, into: %{}, do: {"s#{i}", RK.kbd(i, rem(i, 7), rem(i, 2) == 0, odd.(room_n * 1000 + i))}
          {"!big#{room_n}:test.local", sessions}
        end

      assert {600, _} = RK.count_etag!(RK.put_rooms(u.at, v, all))

      c = RK.get_keys(u.at, v)
      assert c.status == 200 and byte_size(c.resp_body) > 4_000_000, "response of #{byte_size(c.resp_body)} bytes"
      assert (Nebu.OAuth.TestSupport.header(c, "content-type") || "") =~ "application/json"
      assert RK.json(c) == %{"rooms" => Map.new(all, fn {room, sessions} -> {room, %{"sessions" => sessions}} end)}

      for {room, sessions} <- all do
        assert RK.json(RK.get_keys(u.at, v, room)) == %{"sessions" => sessions}
      end
    end

    test "the DATABASE is the state: rows deleted behind the server's back are gone from count and keys at once (no cache, cluster-safe)", %{u: u, v: v} do
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, v, @room, %{"a" => base(), "b" => base()}))
      assert RK.info!(u.at, v)["count"] === 2

      Nebu.OAuth.TestSupport.sql!("DELETE FROM #{RK.sessions_table()} WHERE user_id = $1 AND session_id = 'a'", [u.uid])
      assert RK.info!(u.at, v)["count"] === 1
      assert Map.keys(RK.sessions!(u.at, v)) == [{@room, "b"}]
      RK.assert_error(RK.get_keys(u.at, v, @room, "a"), 404, "M_NOT_FOUND")

      Nebu.OAuth.TestSupport.sql!("DELETE FROM #{RK.sessions_table()} WHERE user_id = $1", [u.uid])
      assert RK.info!(u.at, v)["count"] === 0
      assert RK.json(RK.get_keys(u.at, v)) == %{"rooms" => %{}}
      assert RK.info!(u.at)["count"] === 0
    end
  end

  describe "room and session ids are arbitrary strings, percent-decoded exactly once" do
    @awkward_room "!a/b c:test.local"
    @awkward_sid "s+/=%41#?&;é"

    test "round trip through every shape and every read / delete granularity", %{u: u, v: v} do
      for shape <- @shapes do
        sid = @awkward_sid <> Atom.to_string(shape)
        assert {_, _} = RK.count_etag!(put_via(shape, u.at, v, @awkward_room, sid, base()))
        assert RK.json(RK.get_keys(u.at, v, @awkward_room, sid)) == base(), "#{shape}: read by room and session"
        assert Map.has_key?(RK.json(RK.get_keys(u.at, v, @awkward_room))["sessions"], sid), "#{shape}: read by room"
        assert Map.has_key?(stored(u, v), {@awkward_room, sid}), "#{shape}: read all"
      end

      assert RK.info!(u.at, v)["count"] === 3
      first = @awkward_sid <> "rooms"
      assert {2, _} = RK.count_etag!(RK.delete_keys(u.at, v, @awkward_room, first))
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v, @awkward_room))
    end

    test "a literal percent sequence in an id is not decoded a second time (%41 stays %41, + stays +)", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, "!x%41+y:test.local", "s%42+", base()))
      assert [{"!x%41+y:test.local", "s%42+"}] == Map.keys(stored(u, v))
      RK.assert_error(RK.get_keys(u.at, v, "!xA y:test.local", "sB "), 404, "M_NOT_FOUND")
    end
  end

  # ═══ Scenario 5 - isolation (key half) ═════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 5 - another user cannot read, write or delete my keys" do
    setup %{u: a, v: va} do
      canary = "key-canary-" <> Nebu.OAuth.TestSupport.rand(6)
      assert {1, etag} = RK.count_etag!(RK.put_session(a.at, va, @room, "s", RK.kbd(1, 0, false, %{"c" => canary})))
      {:ok, a: a, va: va, canary: canary, etag: etag, b: RK.user!()}
    end

    test "B, with no backup, gets 404 M_NOT_FOUND on every read, write and delete of A's version, and no data", %{a: a, va: va, b: b, canary: canary, etag: etag} do
      reads = [RK.get_keys(b.at, va), RK.get_keys(b.at, va, @room), RK.get_keys(b.at, va, @room, "s")]

      for c <- reads do
        RK.assert_error(c, 404, "M_NOT_FOUND")
        refute c.resp_body =~ canary
      end

      for shape <- @shapes, do: RK.assert_error(put_via(shape, b.at, va, @room, "s", RK.kbd(0, 0, true, %{"c" => "hijack"})), 404, "M_NOT_FOUND")
      for {room, sid} <- [{nil, nil}, {@room, nil}, {@room, "s"}], do: RK.assert_error(RK.delete_keys(b.at, va, room, sid), 404, "M_NOT_FOUND")

      assert RK.info!(a.at, va)["etag"] == etag and RK.info!(a.at, va)["count"] === 1
      assert RK.sessions!(a.at, va)[{@room, "s"}]["session_data"] == %{"c" => canary}
      assert RK.rows(RK.sessions_table(), b.uid) == 0
    end

    test "B, WITH a backup of his own, cannot write A's NEWER version (403 with HIS current version); reads and deletes of it stay 404; A is untouched", %{a: a, va: va, b: b, canary: canary} do
      vb = RK.create!(b, RK.auth_data("b-own"))
      va2 = RK.create!(a, RK.auth_data("a-second"))
      assert String.to_integer(va2) > String.to_integer(vb), "precondition: A's second version number is one B does not have"

      for shape <- @shapes do
        body = RK.assert_error(put_via(shape, b.at, va2, @room, "s", RK.kbd(0, 0, true, %{"c" => "hijack"})), 403, "M_WRONG_ROOM_KEYS_VERSION")
        assert body["current_version"] == vb, "B is told about HIS current version, never about A's"
      end

      for c <- [RK.get_keys(b.at, va2), RK.get_keys(b.at, va2, @room), RK.get_keys(b.at, va2, @room, "s")], do: RK.assert_error(c, 404, "M_NOT_FOUND")
      for {room, sid} <- [{nil, nil}, {@room, nil}, {@room, "s"}], do: RK.assert_error(RK.delete_keys(b.at, va2, room, sid), 404, "M_NOT_FOUND")

      assert RK.sessions!(a.at, va)[{@room, "s"}]["session_data"] == %{"c" => canary}, "A's key was changed by B"
      assert RK.info!(a.at, va)["count"] === 1 and RK.info!(a.at, va2)["count"] === 0
    end

    # per-user version counters: the first version of every user is "1", so A's and B's numbers COINCIDE (deterministically). The number never crosses users:
    # every read, write and delete at every granularity of B's "1" touches B's rows only (this is what a missing `user_id` in the room / session level SQL would break).
    test "COINCIDING version numbers: B's reads, writes and deletes at every granularity never see or touch A's sessions, counts or etags", %{a: a, va: va, b: b, canary: canary} do
      assert {2, etag_a} = RK.count_etag!(RK.put_session(a.at, va, @room2, "t", RK.kbd(2, 0, false, %{"c" => canary <> "-t"})))
      a_before = RK.sessions!(a.at, va)
      assert map_size(a_before) == 2

      vb = RK.create!(b, RK.auth_data("b-own"))
      assert vb == va, "per-user counters: the first version of every user is #{va}"

      # reads: B's backup is empty at every granularity
      assert RK.json(RK.get_keys(b.at, vb)) == %{"rooms" => %{}}
      assert RK.json(RK.get_keys(b.at, vb, @room)) == %{"sessions" => %{}}
      assert RK.json(RK.get_keys(b.at, vb, @room2)) == %{"sessions" => %{}}
      RK.assert_error(RK.get_keys(b.at, vb, @room, "s"), 404, "M_NOT_FOUND")
      RK.assert_error(RK.get_keys(b.at, vb, @room2, "t"), 404, "M_NOT_FOUND")
      assert RK.info!(b.at, vb)["count"] === 0 and RK.info!(b.at, vb)["auth_data"] == RK.auth_data("b-own")

      # deletes of B at every granularity (B has nothing there): 200 with count 0, A untouched
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb, @room, "s"))
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb, @room2))
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb))
      assert RK.sessions!(a.at, va) == a_before, "B's deletes removed or changed A's sessions"
      assert RK.info!(a.at, va)["count"] === 2 and RK.info!(a.at, va)["etag"] == etag_a

      # writes of B with the SAME room / session ids through all three shapes: separate rows, A's data and A's count stay
      assert {1, _} = RK.count_etag!(put_via(:session, b.at, vb, @room, "s", RK.kbd(9, 0, false, %{"c" => "b-1"})))
      assert {2, _} = RK.count_etag!(put_via(:room, b.at, vb, @room2, "t", RK.kbd(0, 0, true, %{"c" => "b-2"})))
      assert {3, _} = RK.count_etag!(put_via(:rooms, b.at, vb, @room2, "u", RK.kbd(0, 0, true, %{"c" => "b-3"})))
      assert RK.sessions!(a.at, va) == a_before, "B's writes replaced or added to A's sessions"
      assert RK.info!(a.at, va)["count"] === 2 and RK.info!(a.at, va)["etag"] == etag_a
      assert Enum.sort(Map.keys(RK.sessions!(b.at, vb))) == [{@room, "s"}, {@room2, "t"}, {@room2, "u"}]
      assert RK.json(RK.get_keys(b.at, vb, @room, "s"))["session_data"] == %{"c" => "b-1"}
      assert map_size(RK.json(RK.get_keys(b.at, vb, @room2))["sessions"]) == 2

      # B's deletes now remove B's rows only
      assert {2, _} = RK.count_etag!(RK.delete_keys(b.at, vb, @room, "s"))
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb, @room2))
      assert RK.sessions!(a.at, va) == a_before and RK.info!(a.at, va)["count"] === 2
      assert {1, _} = RK.count_etag!(put_via(:rooms, b.at, vb, @room, "z", RK.kbd(1, 0, false)))
      assert {2, _} = RK.count_etag!(put_via(:room, b.at, vb, @room2, "u2", RK.kbd(1, 0, false)))
      assert {3, _} = RK.count_etag!(put_via(:session, b.at, vb, @room2, "u3", RK.kbd(1, 0, false)))
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb))
      assert RK.sessions!(a.at, va) == a_before and RK.info!(a.at, va)["count"] === 2, "B's delete of all keys removed A's sessions"
    end

    test "COINCIDING version numbers: B deleting or updating version \"1\" touches B's version only; A's version, auth_data and keys stay", %{a: a, va: va, b: b, canary: canary} do
      vb = RK.create!(b, RK.auth_data("b-own"))
      assert vb == va
      assert {1, _} = RK.count_etag!(put_via(:session, b.at, vb, @room, "bs", RK.kbd(1, 0, false)))

      assert RK.put_version(b.at, vb, %{"algorithm" => RK.algorithm(), "auth_data" => RK.auth_data("b-new")}).status == 200
      assert RK.info!(a.at, va)["auth_data"] == RK.auth_data("ad"), "B's PUT /version changed A's auth_data"
      assert RK.delete_version(b.at, vb).status == 200
      assert RK.info!(a.at, va)["count"] === 1, "B's DELETE /version removed A's version or keys"
      assert RK.sessions!(a.at, va)[{@room, "s"}]["session_data"] == %{"c" => canary}
      RK.assert_error(RK.get_version(b.at, vb), 404, "M_NOT_FOUND")
    end

    test "the same room and session id of two users are two sessions: B's upload neither replaces nor counts into A's", %{a: a, va: va, b: b, canary: canary} do
      vb = RK.create!(b)
      assert {1, _} = RK.count_etag!(RK.put_session(b.at, vb, @room, "s", RK.kbd(0, 0, true, %{"c" => "b-data"})))
      assert RK.sessions!(a.at, va)[{@room, "s"}]["session_data"] == %{"c" => canary}
      assert RK.sessions!(b.at, vb)[{@room, "s"}]["session_data"] == %{"c" => "b-data"}
      assert RK.info!(a.at, va)["count"] === 1 and RK.info!(b.at, vb)["count"] === 1
      assert {0, _} = RK.count_etag!(RK.delete_keys(b.at, vb))
      assert RK.info!(a.at, va)["count"] === 1, "B's delete removed A's session"
    end
  end
end
