defmodule Nebu.Matrix.RoomKeysVersionsHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`, legacy opaque sessions) of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011), the VERSION
  routes of the Matrix CS v1.18 "Server-side key backups" (`/_matrix/client/v3/room_keys/version[/{version}]`).

  Gherkin scenario 1 (create a version and read it back), scenario 5 (another user cannot read my backup; the version half) and the story's "Scope and constraints":
  shapes and status codes of POST / GET / PUT / DELETE, the version number rules (decimal string, strictly increasing, never reused, malformed ones are 404 never 500),
  the "current = newest non-deleted" rule with its fallback, the idempotent DELETE with a soft-delete marker that keeps NO auth_data, `auth_data` / `algorithm`
  validation, the 16 KiB `auth_data` cap, the quota of 10 versions per user (403 `M_FORBIDDEN`, nothing created or deleted, deleted versions do not count) and the per-user isolation.

  The key routes are `room_keys_keys_http_test.exs`, the size / quota / rate-limit pins `room_keys_limits_http_test.exs`, the races `room_keys_concurrency_test.exs`.
  See `Nebu.Matrix.RoomKeysTestSupport` for the error contract of the story (M_MISSING_PARAM vs M_INVALID_PARAM, sizes).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @moduletag :integration

  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    {:ok, u: RK.user!()}
  end

  # ═══ Scenario 1 - create a backup version and read it back ═════════════════════════════════════════════════════════════

  describe "Scenario 1 - create a version and read it back" do
    test "POST /version answers 200 {\"version\": <string>} and GET /version returns that version with etag, count 0, the algorithm and the auth_data", %{u: u} do
      assert RK.get_version(u.at).status == 404, "precondition: no backup version"
      ad = RK.auth_data("s1")

      created = RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => ad})
      assert created.status == 200
      assert (Nebu.OAuth.TestSupport.header(created, "content-type") || "") =~ "application/json"
      assert %{"version" => version} = RK.json(created)
      assert is_binary(version) and version =~ ~r/\A[1-9][0-9]*\z/
      assert RK.json(created) == %{"version" => version}, "exactly the member `version`"

      info = RK.info!(u.at)
      assert Enum.sort(Map.keys(info)) == ["algorithm", "auth_data", "count", "etag", "version"], "exactly the five members of the spec, got #{inspect(Map.keys(info))}"
      assert info["version"] == version
      assert info["algorithm"] == @algo
      assert info["auth_data"] == ad
      assert info["count"] === 0, "count is an integer, 0 for a new backup"
      assert is_binary(info["etag"]) and info["etag"] != ""
    end

    test "GET /version/{version} returns the same document as GET /version for the current version, and an older version by its number", %{u: u} do
      first = RK.create!(u, RK.auth_data("first"))
      second = RK.create!(u, RK.auth_data("second"))

      assert RK.info!(u.at) == RK.info!(u.at, second)
      assert RK.info!(u.at, second)["auth_data"] == RK.auth_data("second")
      older = RK.info!(u.at, first)
      assert older["version"] == first
      assert older["auth_data"] == RK.auth_data("first")
      assert older["count"] === 0
    end

    test "auth_data is stored as opaque JSON: unicode, nesting, numbers, null, booleans and empty containers come back equal", %{u: u} do
      ad = %{
        "public_key" => "pk",
        "signatures" => %{"@u:test.local" => %{"ed25519:A" => "sig", "ed25519:B" => nil}},
        "nested" => %{"list" => [1, 2.5, 12_345_678_901_234_567_890, true, false, nil, "", [], %{}, "é漢😀"], "deep" => %{"a" => %{"b" => %{"c" => "d"}}}},
        "null" => nil
      }

      v = RK.create!(u, ad)
      assert RK.info!(u.at, v)["auth_data"] == ad
    end

    test "a user without any backup: GET /version is 404 M_NOT_FOUND (the answer Element reads as \"no backup\")", %{u: u} do
      body = RK.assert_error(RK.get_version(u.at), 404, "M_NOT_FOUND")
      assert body["error"] == "No backup found"
    end

    test "versions are decimal strings, strictly increasing per user; the newest non-deleted one is the current one", %{u: u} do
      versions = for i <- 1..4, do: RK.create!(u, RK.auth_data("n#{i}"))
      numbers = Enum.map(versions, &String.to_integer/1)
      assert numbers == Enum.sort(numbers) and length(Enum.uniq(numbers)) == 4, "strictly increasing, got #{inspect(versions)}"
      assert RK.info!(u.at)["version"] == List.last(versions)
    end

    test "the version is a spec string, never a number: a numeric JSON `version` in a PUT body is refused (400 M_INVALID_PARAM)", %{u: u} do
      v = RK.create!(u)
      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.auth_data("x"), "version" => String.to_integer(v)}), 400, "M_INVALID_PARAM")
    end

    test "every answer of the version routes is JSON, the error ones carry a Matrix errcode envelope", %{u: u} do
      v = RK.create!(u)

      for {c, status} <- [{RK.get_version(u.at), 200}, {RK.get_version(u.at, v), 200}, {RK.get_version(u.at, "424242"), 404}, {RK.delete_version(u.at, "424242"), 404}, {RK.delete_version(u.at, v), 200}] do
        assert c.status == status
        assert (Nebu.OAuth.TestSupport.header(c, "content-type") || "") =~ "application/json"
        if status != 200, do: assert(is_binary(RK.json(c)["errcode"]) and is_binary(RK.json(c)["error"]))
      end
    end
  end

  # ═══ POST /version: validation ═════════════════════════════════════════════════════════════════════════════════════════

  describe "POST /version validation (nothing is created by a refused request)" do
    defp nothing_created!(u) do
      assert RK.get_version(u.at).status == 404, "a refused POST created a version"
      assert RK.rows(RK.versions_table(), u.uid) == 0, "a refused POST left a row in #{RK.versions_table()}"
    end

    test "an unsupported algorithm is 400 M_INVALID_PARAM (only m.megolm_backup.v1.curve25519-aes-sha2 is accepted)", %{u: u} do
      for algo <- ["m.megolm_backup.v2", "m.megolm_backup.v1.curve25519-aes-sha2 ", "M.MEGOLM_BACKUP.V1.CURVE25519-AES-SHA2", "", "rubbish"] do
        RK.assert_error(RK.post_version(u.at, %{"algorithm" => algo, "auth_data" => RK.auth_data()}), 400, "M_INVALID_PARAM")
      end

      nothing_created!(u)
    end

    test "an algorithm that is not a string is 400 M_INVALID_PARAM", %{u: u} do
      for algo <- [123, nil, ["m.megolm_backup.v1.curve25519-aes-sha2"], %{"a" => 1}, true] do
        RK.assert_error(RK.post_version(u.at, %{"algorithm" => algo, "auth_data" => RK.auth_data()}), 400, "M_INVALID_PARAM")
      end

      nothing_created!(u)
    end

    test "a missing algorithm or auth_data is 400 M_MISSING_PARAM", %{u: u} do
      RK.assert_error(RK.post_version(u.at, %{"auth_data" => RK.auth_data()}), 400, "M_MISSING_PARAM")
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo}), 400, "M_MISSING_PARAM")
      RK.assert_error(RK.post_version(u.at, %{}), 400, "M_MISSING_PARAM")
      RK.assert_error(RK.req(:post, RK.version_path(), u.at), 400, "M_MISSING_PARAM")
      nothing_created!(u)
    end

    test "an auth_data that is not a JSON object (string, number, array, null, boolean) is 400 M_INVALID_PARAM", %{u: u} do
      for ad <- ["a string", 5, 1.5, [1, 2], [], nil, true, false] do
        RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => ad}), 400, "M_INVALID_PARAM")
      end

      nothing_created!(u)
    end

    test "an empty auth_data object is a JSON object and accepted (the server never looks inside)", %{u: u} do
      v = RK.create!(u, %{})
      assert RK.info!(u.at, v)["auth_data"] == %{}
    end

    test "a body that is not JSON is 400 M_NOT_JSON, a JSON value that is not an object is 400 M_BAD_JSON", %{u: u} do
      RK.assert_error(RK.post_version(u.at, {:raw, "{not json"}), 400, "M_NOT_JSON")
      RK.assert_error(RK.post_version(u.at, {:raw, ~s([{"algorithm":"x"}])}), 400, "M_BAD_JSON")
      RK.assert_error(RK.post_version(u.at, {:raw, ~s("a string")}), 400, "M_BAD_JSON")
      nothing_created!(u)
    end

    test "auth_data up to 16 KiB (16 384 canonical bytes) is accepted, one byte more is 413 M_TOO_LARGE and creates nothing", %{u: u} do
      assert RK.canonical_size(RK.sized_data(RK.max_auth_data_bytes())) == 16_384
      v = RK.create!(u, RK.sized_data(RK.max_auth_data_bytes()))
      assert RK.info!(u.at, v)["auth_data"] == RK.sized_data(RK.max_auth_data_bytes())

      u2 = RK.user!()
      RK.assert_error(RK.post_version(u2.at, %{"algorithm" => @algo, "auth_data" => RK.sized_data(RK.max_auth_data_bytes() + 1)}), 413, "M_TOO_LARGE")
      nothing_created!(u2)
    end

    test "the auth_data limit counts BYTES, not characters (8 192 two-byte characters are 16 392 bytes)", %{u: u} do
      data = RK.sized_data_multibyte(8_192)
      assert RK.canonical_size(data) > RK.max_auth_data_bytes()
      assert String.length(data["k"]) < RK.max_auth_data_bytes()
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => data}), 413, "M_TOO_LARGE")
      nothing_created!(u)
    end
  end

  # ═══ the version number rules ══════════════════════════════════════════════════════════════════════════════════════════

  describe "version numbers" do
    # URL-encoded path segments that are NOT the canonical form of any version this server issues
    @malformed ["abc", "01", "+1", " 1", "1 ", "0x1", "1.0", "-1", "0", "1e3", "99999999999999999999999", "٣", "1;2", "!r:x"]

    test "an unknown version answers 404 M_NOT_FOUND on GET, PUT and DELETE (never a 500), a malformed version too", %{u: u} do
      _real = RK.create!(u)
      body = %{"algorithm" => @algo, "auth_data" => RK.auth_data("x")}

      for version <- ["424242" | @malformed] do
        RK.assert_error(RK.get_version(u.at, version), 404, "M_NOT_FOUND")
        RK.assert_error(RK.put_version(u.at, version, body), 404, "M_NOT_FOUND")
        RK.assert_error(RK.delete_version(u.at, version), 404, "M_NOT_FOUND")
      end
    end

    test "a number with a leading zero or a sign does not alias a real version (\"01\" is not \"1\")", %{u: u} do
      v = RK.create!(u, RK.auth_data("real"))
      n = String.to_integer(v)

      for alias_form <- ["0" <> v, "00" <> v, "+" <> v, v <> ".0"] do
        RK.assert_error(RK.get_version(u.at, alias_form), 404, "M_NOT_FOUND")
      end

      assert RK.info!(u.at, Integer.to_string(n))["auth_data"] == RK.auth_data("real")
    end

    test "versions are never reused: after the newest ones are deleted the next one is higher than every number ever issued", %{u: u} do
      v1 = RK.create!(u)
      v2 = RK.create!(u)
      assert RK.delete_version(u.at, v2).status == 200
      v3 = RK.create!(u)
      assert String.to_integer(v3) > String.to_integer(v2), "#{v3} reuses or undercuts the deleted #{v2}"
      assert v3 not in [v1, v2]

      for v <- [v1, v3], do: assert(RK.delete_version(u.at, v).status == 200)
      v4 = RK.create!(u)
      assert String.to_integer(v4) > String.to_integer(v3), "#{v4} must be higher than every deleted version, even when none is left"
      assert RK.get_version(u.at, v2).status == 404, "the deleted number stays unknown"
    end
  end

  # ═══ DELETE /version/{version} ═════════════════════════════════════════════════════════════════════════════════════════

  describe "DELETE /version/{version}" do
    test "answers 200 {} and the version is gone; GET /version falls back to the newest remaining version, then to 404", %{u: u} do
      a = RK.create!(u, RK.auth_data("a"))
      b = RK.create!(u, RK.auth_data("b"))
      c = RK.create!(u, RK.auth_data("c"))
      assert RK.info!(u.at)["version"] == c

      del = RK.delete_version(u.at, c)
      assert del.status == 200 and RK.json(del) == %{}
      RK.assert_error(RK.get_version(u.at, c), 404, "M_NOT_FOUND")
      assert RK.info!(u.at)["version"] == b, "the current version falls back to the newest remaining one"
      assert RK.info!(u.at)["auth_data"] == RK.auth_data("b")

      assert RK.delete_version(u.at, b).status == 200
      assert RK.info!(u.at)["version"] == a
      assert RK.delete_version(u.at, a).status == 200
      RK.assert_error(RK.get_version(u.at), 404, "M_NOT_FOUND")
    end

    test "deleting an OLDER version leaves the current one alone", %{u: u} do
      a = RK.create!(u, RK.auth_data("a"))
      b = RK.create!(u, RK.auth_data("b"))
      assert RK.delete_version(u.at, a).status == 200
      assert RK.info!(u.at)["version"] == b
      RK.assert_error(RK.get_version(u.at, a), 404, "M_NOT_FOUND")
    end

    test "is idempotent: deleting an already deleted version is 200 {} again; a version that never existed is 404 M_NOT_FOUND", %{u: u} do
      a = RK.create!(u)
      b = RK.create!(u, RK.auth_data("keep"))
      assert RK.delete_version(u.at, a).status == 200

      again = RK.delete_version(u.at, a)
      assert again.status == 200 and RK.json(again) == %{}
      assert RK.delete_version(u.at, a).status == 200
      assert RK.info!(u.at, b)["auth_data"] == RK.auth_data("keep"), "the repeated delete touched another version"

      RK.assert_error(RK.delete_version(u.at, "424242"), 404, "M_NOT_FOUND")
    end

    test "deletes the version and ALL its keys: no session row of the user is left, the keys routes answer 404, the other version keeps its keys", %{u: u} do
      canary = "del-canary-" <> Nebu.OAuth.TestSupport.rand(6)
      a = RK.create!(u, RK.auth_data("a"))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, a, "!r:test.local", "sa", RK.kbd(1, 0, false, %{"c" => canary <> "-a"})))
      b = RK.create!(u, RK.auth_data("b"))
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, b, "!r:test.local", %{"sb1" => RK.kbd(1, 0, false, %{"c" => canary <> "-b1"}), "sb2" => RK.kbd(2, 0, false, %{"c" => canary <> "-b2"})}))

      assert RK.delete_version(u.at, b).status == 200
      RK.assert_error(RK.get_keys(u.at, b), 404, "M_NOT_FOUND")
      RK.assert_error(RK.get_keys(u.at, b, "!r:test.local"), 404, "M_NOT_FOUND")
      refute RK.row_text(RK.sessions_table(), u.uid) =~ canary <> "-b", "the deleted version's session blobs are physically gone"
      assert RK.row_text(RK.sessions_table(), u.uid) =~ canary <> "-a", "the older version keeps its session"
      assert RK.rows(RK.sessions_table(), u.uid) == 1

      assert RK.delete_version(u.at, a).status == 200
      assert RK.rows(RK.sessions_table(), u.uid) == 0
    end

    test "the soft-delete marker keeps no auth_data (\"deletes info + all keys\"): the blob is nowhere in the stored rows of the user", %{u: u} do
      canary = "ad-canary-" <> Nebu.OAuth.TestSupport.rand(6)
      v = RK.create!(u, RK.auth_data(canary))
      assert RK.row_text(RK.versions_table(), u.uid) =~ canary, "precondition: the live version stores its auth_data"

      assert RK.delete_version(u.at, v).status == 200
      refute RK.row_text(RK.versions_table(), u.uid) =~ canary
      refute RK.row_text(RK.sessions_table(), u.uid) =~ canary
      assert RK.get_version(u.at, v).status == 404
    end

    test "deleting the current version makes the previous one current: writes to it are accepted afterwards", %{u: u} do
      a = RK.create!(u)
      b = RK.create!(u)
      RK.assert_error(RK.put_session(u.at, a, "!r:test.local", "s", RK.kbd(1, 0, false)), 403, "M_WRONG_ROOM_KEYS_VERSION")
      assert RK.delete_version(u.at, b).status == 200
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, a, "!r:test.local", "s", RK.kbd(1, 0, false)))
    end
  end

  # ═══ PUT /version/{version} ════════════════════════════════════════════════════════════════════════════════════════════

  describe "PUT /version/{version}" do
    test "replaces the auth_data (200 {}); algorithm, version, count and the stored keys are unchanged", %{u: u} do
      v = RK.create!(u, RK.auth_data("old"))
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, "!r:test.local", "s", RK.kbd(1, 0, false)))

      put = RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.auth_data("new")})
      assert put.status == 200 and RK.json(put) == %{}

      info = RK.info!(u.at, v)
      assert info["auth_data"] == RK.auth_data("new")
      assert info["algorithm"] == @algo and info["version"] == v and info["count"] === 1
      assert info["etag"] == etag, "the keys did not change, neither did the etag"
      assert Map.keys(RK.sessions!(u.at, v)) == [{"!r:test.local", "s"}]
    end

    test "the `version` member is optional; when present it must equal the path (400 M_INVALID_PARAM otherwise); an equal one is accepted", %{u: u} do
      v = RK.create!(u, RK.auth_data("old"))
      other = Integer.to_string(String.to_integer(v) + 1)
      base = %{"algorithm" => @algo, "auth_data" => RK.auth_data("new")}

      RK.assert_error(RK.put_version(u.at, v, Map.put(base, "version", other)), 400, "M_INVALID_PARAM")
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("old"), "a refused update changes nothing"

      assert RK.put_version(u.at, v, Map.put(base, "version", v)).status == 200
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("new")
    end

    test "the algorithm must equal the stored one (400 M_INVALID_PARAM), a missing member is 400 M_MISSING_PARAM, a mistyped one 400 M_INVALID_PARAM", %{u: u} do
      v = RK.create!(u, RK.auth_data("old"))
      ad = RK.auth_data("new")

      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => "m.megolm_backup.v2", "auth_data" => ad}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => 1, "auth_data" => ad}), 400, "M_INVALID_PARAM")
      RK.assert_error(RK.put_version(u.at, v, %{"auth_data" => ad}), 400, "M_MISSING_PARAM")
      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => @algo}), 400, "M_MISSING_PARAM")

      for bad <- ["s", 1, [], nil] do
        RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => bad}), 400, "M_INVALID_PARAM")
      end

      RK.assert_error(RK.put_version(u.at, v, {:raw, "{nope"}), 400, "M_NOT_JSON")
      RK.assert_error(RK.put_version(u.at, v, {:raw, "[]"}), 400, "M_BAD_JSON")
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("old"), "nothing was changed by the refused requests"
    end

    test "an unknown, a deleted or a never existing version is 404 M_NOT_FOUND and creates nothing", %{u: u} do
      v = RK.create!(u)
      assert RK.delete_version(u.at, v).status == 200
      body = %{"algorithm" => @algo, "auth_data" => RK.auth_data("x")}

      RK.assert_error(RK.put_version(u.at, v, body), 404, "M_NOT_FOUND")
      RK.assert_error(RK.put_version(u.at, "424242", body), 404, "M_NOT_FOUND")
      assert RK.get_version(u.at).status == 404
    end

    test "an OLDER version can be updated too, and that does not change which version is the current one", %{u: u} do
      a = RK.create!(u, RK.auth_data("a"))
      b = RK.create!(u, RK.auth_data("b"))

      assert RK.put_version(u.at, a, %{"algorithm" => @algo, "auth_data" => RK.auth_data("a2")}).status == 200
      assert RK.info!(u.at)["version"] == b
      assert RK.info!(u.at, a)["auth_data"] == RK.auth_data("a2")
      assert RK.info!(u.at, b)["auth_data"] == RK.auth_data("b")
    end

    test "auth_data is capped at 16 KiB (413 M_TOO_LARGE, unchanged), exactly 16 384 bytes are accepted", %{u: u} do
      v = RK.create!(u, RK.auth_data("old"))
      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(RK.max_auth_data_bytes() + 1)}), 413, "M_TOO_LARGE")
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("old")

      assert RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(RK.max_auth_data_bytes())}).status == 200
    end
  end

  # ═══ quota of 10 versions ══════════════════════════════════════════════════════════════════════════════════════════════

  describe "quota: at most 10 versions per user" do
    test "the 10th version is created, the 11th is 403 M_FORBIDDEN (not M_LIMIT_EXCEEDED): nothing is created, nothing is deleted", %{u: u} do
      versions = for i <- 1..10, do: RK.create!(u, RK.auth_data("q#{i}"))
      assert length(Enum.uniq(versions)) == 10

      refused = RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("11th")})
      body = RK.assert_error(refused, 403, "M_FORBIDDEN")
      refute Map.has_key?(body, "retry_after_ms"), "a quota is not a rate limit: clients must not auto-retry it"
      assert RK.get_version(u.at, hd(versions)).status == 200, "no silent deletion of the oldest backup"
      assert RK.info!(u.at)["version"] == List.last(versions), "the current version is still the 10th"
      assert RK.rows(RK.versions_table(), u.uid) == 10

      # a second refused request changes nothing either
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("again")}), 403, "M_FORBIDDEN")
      assert RK.rows(RK.versions_table(), u.uid) == 10
    end

    test "deleted versions do not count toward the 10, but their numbers are not reused", %{u: u} do
      versions = for i <- 1..10, do: RK.create!(u, RK.auth_data("q#{i}"))
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("x")}), 403, "M_FORBIDDEN")

      [first, second | _] = versions
      assert RK.delete_version(u.at, first).status == 200
      assert RK.delete_version(u.at, second).status == 200
      assert RK.delete_version(u.at, second).status == 200, "an idempotent repeat frees nothing twice"

      new1 = RK.create!(u, RK.auth_data("n1"))
      new2 = RK.create!(u, RK.auth_data("n2"))
      assert new1 not in versions and new2 not in versions, "the numbers of deleted versions are never reused"
      assert String.to_integer(new2) > String.to_integer(new1)
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("again")}), 403, "M_FORBIDDEN")
    end

    test "the quota is per user: another user still creates versions while the first is at the limit", %{u: u} do
      for i <- 1..10, do: RK.create!(u, RK.auth_data("q#{i}"))
      other = RK.user!()
      ov = RK.create!(other, RK.auth_data("other"))
      assert RK.info!(other.at)["version"] == ov and RK.info!(other.at)["auth_data"] == RK.auth_data("other")
    end

    test "an update (PUT) is not a creation: updating an existing version works at the limit and creates no row", %{u: u} do
      versions = for i <- 1..10, do: RK.create!(u, RK.auth_data("q#{i}"))
      assert RK.put_version(u.at, hd(versions), %{"algorithm" => @algo, "auth_data" => RK.auth_data("upd")}).status == 200
      assert RK.rows(RK.versions_table(), u.uid) == 10
    end
  end

  # ═══ Scenario 5 (version half) - isolation ═════════════════════════════════════════════════════════════════════════════

  describe "Scenario 5 - another user cannot read, change or delete my backup" do
    test "user B gets 404 M_NOT_FOUND for A's version and returns no data; A's backup is untouched by B's write and delete attempts" do
      a = RK.user!()
      b = RK.user!()
      canary = "iso-canary-" <> Nebu.OAuth.TestSupport.rand(6)
      va = RK.create!(a, RK.auth_data(canary))
      assert {1, etag} = RK.count_etag!(RK.put_session(a.at, va, "!r:test.local", "s", RK.kbd(1, 0, false, %{"c" => canary})))

      for c <- [RK.get_version(b.at, va), RK.get_version(b.at)] do
        RK.assert_error(c, 404, "M_NOT_FOUND")
        refute c.resp_body =~ canary, "A's data leaked into B's answer"
      end

      RK.assert_error(RK.put_version(b.at, va, %{"algorithm" => @algo, "auth_data" => RK.auth_data("hijack")}), 404, "M_NOT_FOUND")
      RK.assert_error(RK.delete_version(b.at, va), 404, "M_NOT_FOUND")

      info = RK.info!(a.at, va)
      assert info["auth_data"] == RK.auth_data(canary) and info["count"] === 1 and info["etag"] == etag, "A's backup was changed by B"
      assert RK.rows(RK.versions_table(), b.uid) == 0 and RK.rows(RK.sessions_table(), b.uid) == 0
    end

    # per-user version counters: the first version of every user is "1", so the numbers of two users coincide deterministically
    test "COINCIDING version numbers (per-user counters, the first is \"1\"): every user's \"1\" is his own backup, never the other's" do
      a = RK.user!()
      b = RK.user!()
      va = RK.create!(a, RK.auth_data("owned-by-a"))
      vb = RK.create!(b, RK.auth_data("owned-by-b"))
      assert va == "1" and vb == "1", "versions are per-user counters: the first one is \"1\""

      assert RK.info!(b.at, va)["auth_data"] == RK.auth_data("owned-by-b")
      assert RK.info!(a.at, vb)["auth_data"] == RK.auth_data("owned-by-a")
      assert RK.info!(a.at)["auth_data"] == RK.auth_data("owned-by-a") and RK.info!(b.at)["auth_data"] == RK.auth_data("owned-by-b")

      assert RK.put_version(b.at, vb, %{"algorithm" => @algo, "auth_data" => RK.auth_data("b-updated")}).status == 200
      assert RK.info!(a.at, va)["auth_data"] == RK.auth_data("owned-by-a"), "B's PUT changed A's version"

      assert RK.delete_version(b.at, vb).status == 200
      assert RK.info!(a.at, va)["auth_data"] == RK.auth_data("owned-by-a"), "B's delete removed A's version"
      RK.assert_error(RK.get_version(b.at, vb), 404, "M_NOT_FOUND")

      # the second version of A (\"2\") does not exist for B at all
      va2 = RK.create!(a, RK.auth_data("a-second"))
      assert va2 == "2"
      RK.assert_error(RK.get_version(b.at, va2), 404, "M_NOT_FOUND")
      RK.assert_error(RK.put_version(b.at, va2, %{"algorithm" => @algo, "auth_data" => RK.auth_data("x")}), 404, "M_NOT_FOUND")
      RK.assert_error(RK.delete_version(b.at, va2), 404, "M_NOT_FOUND")
      assert RK.info!(a.at, va2)["auth_data"] == RK.auth_data("a-second")
    end

    test "a deleted version of A is 404 for B on DELETE too: idempotence is a property of the owner only" do
      a = RK.user!()
      b = RK.user!()
      va = RK.create!(a)
      assert RK.delete_version(a.at, va).status == 200
      RK.assert_error(RK.delete_version(b.at, va), 404, "M_NOT_FOUND")
    end
  end

  # ═══ authentication ════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "authentication (the no-token half is room_keys_routes_test.exs, without a database)" do
    test "a junk token is 401 M_UNKNOWN_TOKEN on every version route and nothing is stored" do
      owner = RK.user!()
      before_rows = {RK.rows(RK.versions_table(), owner.uid), RK.rows(RK.sessions_table(), owner.uid)}

      for {method, path, body} <- [
            {:post, RK.version_path(), %{"algorithm" => @algo, "auth_data" => RK.auth_data()}},
            {:get, RK.version_path(), nil},
            {:get, RK.version_path("1"), nil},
            {:put, RK.version_path("1"), %{"algorithm" => @algo, "auth_data" => RK.auth_data()}},
            {:delete, RK.version_path("1"), nil}
          ] do
        c = RK.req(method, path, "not-a-real-token", body)
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{path}: #{c.status} #{c.resp_body}"
      end

      # a valid user exists, yet nothing was stored for anybody by the refused requests
      assert {RK.rows(RK.versions_table(), owner.uid), RK.rows(RK.sessions_table(), owner.uid)} == before_rows
      assert RK.get_version(owner.at).status == 404
    end

    test "the raw IdP JWT path (what Element sends) reaches the routes: a JWT-shaped garbage token is 401 M_UNKNOWN_TOKEN" do
      c = RK.req(:post, RK.version_path(), "aaa.bbb.ccc", %{"algorithm" => @algo, "auth_data" => RK.auth_data()})
      assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}
    end
  end
end
