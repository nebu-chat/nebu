defmodule Nebu.Matrix.RoomKeysLimitsHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of the LIMITS of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): the story's "Quotas (decided
  here)" and "Rate limits follow the sibling client write endpoints". (The 10-version quota and the 16 KiB `auth_data` cap are in `room_keys_versions_http_test.exs`.)

    * `session_data` <= 8 KiB (canonical bytes; 8 192 pass, 8 193 are `413 M_TOO_LARGE`, bytes not characters); one oversize blob refuses the WHOLE request, nothing is stored.
    * Request body <= 5 MiB on every `room_keys` route: 5 242 880 bytes pass, 5 242 881 are `413 M_TOO_LARGE` with the standard envelope; bodies far above the 1 MB cap of the other
      routes (1.6 MB, 4.9 MB) are accepted; every OTHER Matrix route keeps its 1 MB cap. Cycle 1: the body is read ONLY for an authenticated request, after the write rate limit
      (an unauthenticated / junk-bearer request is 401 without the body being read, an exhausted bucket is 429 before it).
    * Sessions per version <= 100 000 (the seam `:nebu, :room_keys_max_sessions_per_version`, read at request time): a batch that would pass the cap is `403 M_FORBIDDEN` as a whole,
      replacing a stored session at the cap is fine (the count does not change), the cap is per version and per user. One test fills the REAL default (100 000).
    * Rate limit: every WRITE (POST / PUT / DELETE of versions and keys) is charged to a per-user bucket of its own (tier `room_keys`, 60 / min, cycle 2: burst 5 - cycle 1 had 30): the
      6th write in the burst is `429 M_LIMIT_EXCEEDED` (envelope with `retry_after_ms` and `Retry-After`) and changes nothing. READS: the single-session GET is not limited
      (a divergence from the spec's "rate-limited": a client restoring a backup reads one session per undecryptable event); the two BULK reads (`GET /keys`, `GET /keys/{room}`)
      have a bucket of their own (30 / min, cycle 2: burst 3 - cycle 1 had 10 per user); cycle 2: `GET /version` and `GET /version/{v}` (a `count(*)` over up to 100 000 rows) have a LIGHT bucket
      of their own (120 / min, burst 30) shared by the two routes; the three buckets are independent of each other, per user and of the other tiers. The refill rates are pinned with a hand-advanced clock.
      (The byte budget and the version-row cap are `room_keys_budget_http_test.exs`, the per-user lock `room_keys_lock_timeout_test.exs`, the bulk-read slots `room_keys_bulk_flight_test.exs`.)

  The error code of a quota (403 M_FORBIDDEN) follows the story's decision for the 11th version; the size refusals are 413 M_TOO_LARGE like the sibling size limits (event size,
  account data, request body).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @room "!limits:test.local"
  @algo RK.algorithm()
  @too_large %{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}

  defp fresh do
    u = RK.user!()
    {u, RK.create!(u)}
  end

  # ═══ session_data <= 8 KiB ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "session_data is capped at 8 KiB" do
    setup do
      RK.disable_rate_limit()
      :ok
    end

    test "8 192 canonical bytes are accepted and read back, 8 193 are 413 M_TOO_LARGE and store nothing (all three shapes)" do
      {u, v} = fresh()
      assert RK.canonical_size(RK.sized_data(8_192)) == 8_192 and RK.canonical_size(RK.sized_data(8_193)) == 8_193

      ok = RK.kbd(1, 0, false, RK.sized_data(8_192))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "fits", ok))
      assert RK.json(RK.get_keys(u.at, v, @room, "fits")) == ok

      big = RK.kbd(1, 0, false, RK.sized_data(8_193))
      RK.assert_error(RK.put_session(u.at, v, @room, "big", big), 413, "M_TOO_LARGE")
      RK.assert_error(RK.put_room(u.at, v, @room, %{"big" => big}), 413, "M_TOO_LARGE")
      RK.assert_error(RK.put_rooms(u.at, v, %{@room => %{"big" => big}}), 413, "M_TOO_LARGE")

      assert Map.keys(RK.sessions!(u.at, v)) == [{@room, "fits"}]
      assert RK.info!(u.at, v)["count"] === 1
    end

    test "the limit counts BYTES: 4 096 two-byte characters are 8 200 bytes and refused although they are only 4 096 characters" do
      {u, v} = fresh()
      data = RK.sized_data_multibyte(4_096)
      assert RK.canonical_size(data) == 8_200 and String.length(data["k"]) == 4_096
      RK.assert_error(RK.put_session(u.at, v, @room, "wide", RK.kbd(1, 0, false, data)), 413, "M_TOO_LARGE")
      assert RK.rows(RK.sessions_table(), u.uid) == 0
    end

    test "one oversize blob refuses the WHOLE batch: its valid siblings and a valid replacement are not stored either" do
      {u, v} = fresh()
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "old", RK.kbd(10, 0, false, %{"c" => "OLD"})))

      c =
        RK.put_rooms(u.at, v, %{
          @room => %{"old" => RK.kbd(1, 0, true, %{"c" => "WOULD-REPLACE"}), "good" => RK.kbd(1, 0, false), "big" => RK.kbd(1, 0, false, RK.sized_data(9_000))}
        })

      RK.assert_error(c, 413, "M_TOO_LARGE")
      assert Map.keys(RK.sessions!(u.at, v)) == [{@room, "old"}]
      assert RK.sessions!(u.at, v)[{@room, "old"}]["session_data"] == %{"c" => "OLD"}
      assert RK.info!(u.at, v)["etag"] == etag
    end
  end

  # ═══ request body <= 5 MiB ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "request bodies are capped at 5 MiB on room_keys routes (and stay 1 MB elsewhere)" do
    setup do
      RK.disable_rate_limit()
      :ok
    end

    # a batch of `n` sessions of `bytes` canonical session_data bytes each, as the exact request body
    defp batch_body(n, bytes, prefix \\ "s") do
      sessions = for i <- 1..n, into: %{}, do: {"#{prefix}#{i}", RK.kbd(i, 0, false, RK.sized_data(bytes))}
      Jason.encode!(%{"rooms" => %{@room => %{"sessions" => sessions}}})
    end

    defp pad_to(json, total), do: json <> String.duplicate(" ", total - byte_size(json))

    test "a 1.6 MB batch (200 sessions of 8 000 bytes) is far above the 1 MB cap of other routes and is accepted: count 200" do
      {u, v} = fresh()
      body = batch_body(200, 8_000)
      assert byte_size(body) > 1_600_000

      assert {200, _} = RK.count_etag!(RK.put_keys_raw(u.at, v, body))
      assert RK.info!(u.at, v)["count"] === 200
    end

    test "a 5.1 MB batch (630 sessions) just below the 5 MiB cap is accepted" do
      {u, v} = fresh()
      body = batch_body(630, 8_000)
      assert byte_size(body) > 5_000_000 and byte_size(body) < RK.max_body_bytes()

      assert {630, _} = RK.count_etag!(RK.put_keys_raw(u.at, v, body))
      assert RK.info!(u.at, v)["count"] === 630
    end

    test "exactly 5 242 880 bytes are accepted, 5 242 881 are 413 M_TOO_LARGE with the standard envelope and nothing is stored (PUT /keys)" do
      {u, v} = fresh()
      json = Jason.encode!(%{"rooms" => %{@room => %{"sessions" => %{"s" => RK.kbd(1, 0, false)}}}})

      ok = RK.put_keys_raw(u.at, v, pad_to(json, RK.max_body_bytes()))
      assert {1, _} = RK.count_etag!(ok)

      too_big = RK.put_keys_raw(u.at, v, pad_to(Jason.encode!(%{"rooms" => %{@room => %{"sessions" => %{"s2" => RK.kbd(1, 0, false)}}}}), RK.max_body_bytes() + 1))
      assert too_big.status == 413
      assert RK.json(too_big) == @too_large
      assert (T.header(too_big, "content-type") || "") =~ "application/json"
      # (cycle 1, deliberate: `conn.halted` is no longer pinned. The 413 is produced inside the authenticated route, after the authentication and the write rate limit,
      # no longer by the pre-router `JsonBody` plug that halts; the observable contract is the status, the envelope and that nothing was stored)
      assert RK.info!(u.at, v)["count"] === 1, "the refused body stored nothing"
    end

    test "the cap applies to the other two key shapes and to POST / PUT /version as well" do
      {u, v} = fresh()
      over = fn json -> pad_to(json, RK.max_body_bytes() + 1) end
      at_cap = fn json -> pad_to(json, RK.max_body_bytes()) end

      for {method, path, json} <- [
            {:put, RK.keys_path(v, @room), Jason.encode!(%{"sessions" => %{"a" => RK.kbd(1, 0, false)}})},
            {:put, RK.keys_path(v, @room, "a"), Jason.encode!(RK.kbd(1, 0, false))},
            {:put, RK.version_path(v), Jason.encode!(%{"algorithm" => @algo, "auth_data" => RK.auth_data("x")})}
          ] do
        c = RK.req(method, path, u.at, {:raw, over.(json)})
        assert {c.status, RK.json(c)} == {413, @too_large}, "#{method} #{path}: #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert RK.req(method, path, u.at, {:raw, at_cap.(json)}).status == 200, "#{method} #{path} at exactly the cap"
      end

      c = RK.req(:post, RK.version_path(), u.at, {:raw, over.(Jason.encode!(%{"algorithm" => @algo, "auth_data" => RK.auth_data("y")}))})
      assert {c.status, RK.json(c)} == {413, @too_large}
      assert RK.req(:post, RK.version_path(), u.at, {:raw, at_cap.(Jason.encode!(%{"algorithm" => @algo, "auth_data" => RK.auth_data("y")}))}).status == 200
    end

    test "a refused oversize POST creates no version and a refused oversize PUT keys leaves the backup untouched" do
      {u, v} = fresh()
      before = RK.rows(RK.versions_table(), u.uid)
      huge = Jason.encode!(%{"algorithm" => @algo, "auth_data" => RK.auth_data("z")})
      assert RK.req(:post, RK.version_path(), u.at, {:raw, pad_to(huge, RK.max_body_bytes() + 10)}).status == 413
      assert RK.rows(RK.versions_table(), u.uid) == before
      assert RK.info!(u.at)["version"] == v
    end

    test "every OTHER Matrix route keeps its 1 MB cap (the room_keys cap is not global)" do
      {u, _v} = fresh()
      c = RK.req(:post, "/_matrix/client/v3/createRoom", u.at, {:raw, pad_to(~s({"name":"x"}), 1_000_001)})
      assert {c.status, RK.json(c)} == {413, @too_large}

      c = RK.req(:put, "/_matrix/client/v3/rooms/%21r%3Atest.local/send/m.room.message/t1", u.at, {:raw, pad_to(~s({"msgtype":"m.text","body":"x"}), 1_500_000)})
      assert {c.status, RK.json(c)} == {413, @too_large}
    end

    test "a path that merely CONTAINS room_keys elsewhere does not get the room_keys cap" do
      {u, _v} = fresh()
      c = RK.req(:post, "/_matrix/client/v3/rooms/%21room_keys%3Atest.local/invite", u.at, {:raw, pad_to(~s({"user_id":"@x:test.local"}), 1_000_001)})
      assert {c.status, RK.json(c)} == {413, @too_large}
    end
  end

  # ═══ sessions per version ══════════════════════════════════════════════════════════════════════════════════════════════

  describe "the session cap of a version (seam :nebu, :room_keys_max_sessions_per_version)" do
    setup do
      RK.disable_rate_limit()
      RK.put_env_restoring(:nebu, :room_keys_max_sessions_per_version, 5)
      :ok
    end

    defp sessions(prefix, range, fmi \\ 10), do: for(i <- range, into: %{}, do: {"#{prefix}#{i}", RK.kbd(fmi, 0, false, %{"c" => "#{prefix}#{i}"})})

    test "a version holds up to the cap; the next NEW session is 403 M_FORBIDDEN, count and etag unchanged" do
      {u, v} = fresh()
      assert {3, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..3)))
      assert {5, etag} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("b", 1..2))), "a batch that exactly fills the cap is accepted"

      body = RK.assert_error(RK.put_session(u.at, v, @room, "one-too-many", RK.kbd(1, 0, false)), 403, "M_FORBIDDEN")
      refute Map.has_key?(body, "retry_after_ms")
      assert RK.info!(u.at, v)["count"] === 5 and RK.info!(u.at, v)["etag"] == etag
      assert RK.rows(RK.sessions_table(), u.uid) == 5
      RK.assert_error(RK.get_keys(u.at, v, @room, "one-too-many"), 404, "M_NOT_FOUND")
    end

    test "replacing a stored session at the cap is fine (the count does not change), a new session in the same batch is not" do
      {u, v} = fresh()
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..5)))

      better = RK.kbd(1, 0, true, %{"c" => "better"})
      assert {5, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "a1", better))
      assert RK.json(RK.get_keys(u.at, v, @room, "a1")) == better

      worse = RK.kbd(99, 0, false, %{"c" => "worse"})
      assert {5, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "a2", worse)), "a kept (worse) session at the cap is no error either"
    end

    test "a batch with ONE new session beyond the cap is refused as a whole: its replacement of a stored session is not applied either" do
      {u, v} = fresh()
      assert {5, etag} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..5)))

      c = RK.put_room(u.at, v, @room, %{"a1" => RK.kbd(1, 0, true, %{"c" => "WOULD-REPLACE"}), "new" => RK.kbd(1, 0, false)})
      RK.assert_error(c, 403, "M_FORBIDDEN")
      assert RK.sessions!(u.at, v)[{@room, "a1"}]["session_data"] == %{"c" => "a1"}
      assert RK.info!(u.at, v)["etag"] == etag and RK.info!(u.at, v)["count"] === 5
    end

    test "a batch that would pass the cap stores none of its sessions (3 stored + 3 new > 5: all three new ones are refused)" do
      {u, v} = fresh()
      assert {3, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..3)))
      RK.assert_error(RK.put_rooms(u.at, v, %{@room => sessions("n", 1..2), "!other:test.local" => sessions("m", 1..1)}), 403, "M_FORBIDDEN")
      assert RK.info!(u.at, v)["count"] === 3
      assert RK.rows(RK.sessions_table(), u.uid) == 3
    end

    test "deleting a session frees a slot; deleting the version's keys frees them all" do
      {u, v} = fresh()
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..5)))
      assert {4, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "a1"))
      RK.assert_error(RK.put_room(u.at, v, @room, sessions("n", 1..2)), 403, "M_FORBIDDEN")
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("n", 1..1)))
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v))
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("z", 1..5)))
    end

    test "the cap is per VERSION (a newer version starts empty) and per USER (another user is unaffected)" do
      {u, v} = fresh()
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..5)))
      newer = RK.create!(u)
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, newer, @room, sessions("a", 1..5)))
      assert RK.info!(u.at, v)["count"] === 5

      {other, ov} = fresh()
      assert {5, _} = RK.count_etag!(RK.put_room(other.at, ov, @room, sessions("a", 1..5)))
    end

    # per-user version counters: both users are in version "1", with the SAME room and session ids. Another user's rows must neither fill nor free a slot.
    test "COINCIDING version numbers and ids: another user's sessions with the same ids neither fill nor free a slot of mine" do
      {a, va} = fresh()
      {b, vb} = fresh()
      assert va == vb
      assert {5, _} = RK.count_etag!(RK.put_room(a.at, va, @room, sessions("x", 1..5)))

      # B has nothing yet: A's five sessions do not count against B's cap, and B's "x1".."x5" are NEW sessions of B
      assert {5, _} = RK.count_etag!(RK.put_room(b.at, vb, @room, sessions("x", 1..5)))
      # B is at the cap with five sessions: one more NEW id is refused, although A holds that id in the same version number
      RK.assert_error(RK.put_session(b.at, vb, @room, "y1", RK.kbd(1, 0, false)), 403, "M_FORBIDDEN")
      assert RK.info!(b.at, vb)["count"] === 5 and RK.info!(a.at, va)["count"] === 5

      # A frees nothing for B, and B's delete frees nothing for A
      assert {4, _} = RK.count_etag!(RK.delete_keys(a.at, va, @room, "x1"))
      RK.assert_error(RK.put_session(b.at, vb, @room, "y2", RK.kbd(1, 0, false)), 403, "M_FORBIDDEN")
      assert {4, _} = RK.count_etag!(RK.delete_keys(b.at, vb, @room, "x2"))
      assert {5, _} = RK.count_etag!(RK.put_session(a.at, va, @room, "y3", RK.kbd(1, 0, false)))
      RK.assert_error(RK.put_session(a.at, va, @room, "y4", RK.kbd(1, 0, false)), 403, "M_FORBIDDEN")
      assert {5, _} = RK.count_etag!(RK.put_session(b.at, vb, @room, "y5", RK.kbd(1, 0, false)))
    end

    test "a refused write is never counted as a stored one: the sessions of the refused batch are not readable" do
      {u, v} = fresh()
      assert {5, _} = RK.count_etag!(RK.put_room(u.at, v, @room, sessions("a", 1..5)))
      RK.assert_error(RK.put_room(u.at, v, @room, sessions("n", 1..3)), 403, "M_FORBIDDEN")
      assert RK.json(RK.get_keys(u.at, v, @room))["sessions"] |> Map.keys() |> Enum.sort() == ["a1", "a2", "a3", "a4", "a5"]
    end
  end

  describe "the REAL cap: 100 000 sessions per version" do
    setup do
      RK.disable_rate_limit()
      :ok
    end

    # slow (fills 100 000 rows through 4 requests; the measured runtime is in atdd-report.md): tagged `:slow` so a local run may `--exclude slow`; CI runs it
    @tag :slow
    @tag timeout: 600_000
    test "100 000 sessions are stored, the 100 001st is 403 M_FORBIDDEN, a replacement at the cap is accepted, a deleted one frees a slot" do
      assert RK.max_sessions_per_version() == 100_000
      refute Application.get_env(:nebu, :room_keys_max_sessions_per_version), "precondition: no seam override is active, the default is under test"
      {u, v} = fresh()

      for chunk <- Enum.chunk_every(1..100_000, 25_000) do
        sessions = for i <- chunk, into: %{}, do: {"s#{i}", RK.kbd(i, 0, false, %{})}
        c = RK.put_room(u.at, v, @room, sessions)
        assert c.status == 200, "chunk #{inspect(List.first(chunk))}: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
      end

      assert RK.info!(u.at, v)["count"] === 100_000
      RK.assert_error(RK.put_session(u.at, v, @room, "s100001", RK.kbd(1, 0, false)), 403, "M_FORBIDDEN")
      assert RK.info!(u.at, v)["count"] === 100_000

      assert {100_000, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s50000", RK.kbd(1, 0, true, %{"c" => "better"})))
      assert RK.json(RK.get_keys(u.at, v, @room, "s50000"))["session_data"] == %{"c" => "better"}

      assert {99_999, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s1"))
      assert {100_000, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s100001", RK.kbd(1, 0, false)))
    end
  end

  # ═══ rate limit ════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "rate limit of the writes (per user, 60 / min, burst 5; reads free)" do
    setup do
      RK.enable_rate_limit()
      :ok
    end

    # the nine kinds of write of the story; `i` makes the request unique and valid
    defp write(kind, u, v, i) do
      case kind do
        :post_version -> RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("rl#{i}")})
        :put_version -> RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.auth_data("rl#{i}")})
        :delete_version -> RK.delete_version(u.at, "424242")
        :put_rooms -> RK.put_rooms(u.at, v, %{@room => %{"r#{i}" => RK.kbd(i, 0, false)}})
        :put_room -> RK.put_room(u.at, v, @room, %{"m#{i}" => RK.kbd(i, 0, false)})
        :put_session -> RK.put_session(u.at, v, @room, "s#{i}", RK.kbd(i, 0, false))
        :delete_session -> RK.delete_keys(u.at, v, @room, "s#{i}")
        :delete_room -> RK.delete_keys(u.at, v, "!none#{i}:test.local")
        :delete_all -> RK.delete_keys(u.at, v)
      end
    end

    @kinds [:put_version, :put_rooms, :put_room, :put_session, :delete_session, :delete_room, :delete_all]

    # five writes of a user (the POST of its version and four puts): the bucket is empty
    defp exhaust_writes(u, v) do
      for i <- 1..4, do: assert(RK.put_session(u.at, v, @room, "s#{i}", RK.kbd(i, 0, false)).status == 200, "write #{i + 1} is inside the burst of 5")
      :ok
    end

    # cycle 2 (deliberate, supersedes "the 31st write is 429": the burst of the write bucket is 5, not 30)
    test "the 6th write is 429 M_LIMIT_EXCEEDED (retry_after_ms, Retry-After) for every kind of write and changes nothing" do
      u = RK.user!()
      v = RK.create!(u)

      statuses = for i <- 1..4, do: write(Enum.at(@kinds, rem(i, length(@kinds))), u, v, i).status
      assert Enum.all?(statuses, &(&1 == 200)), "5 writes (the POST + these 4) are inside the burst, got #{inspect(statuses)}"

      before_info = RK.info!(u.at, v)
      before_rows = {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)}

      for kind <- [:post_version | @kinds] ++ [:delete_version] do
        c = write(kind, u, v, 100)
        body = RK.assert_error(c, 429, "M_LIMIT_EXCEEDED")
        assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "#{kind}: retry_after_ms #{inspect(body)}"
        assert {ra, ""} = Integer.parse(T.header(c, "retry-after") || ""), "#{kind}: Retry-After header"
        assert ra >= 1
      end

      assert RK.info!(u.at, v) == before_info, "a 429 changed the backup"
      assert {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)} == before_rows
      assert RK.get_version(u.at, v).status == 200, "the refused DELETE of a version did not run"
    end

    # cycle 1 (deliberate, supersedes "reads are not limited: 40 reads of every kind") and cycle 2: only the single-session GET is free now (the version GETs have the light bucket)
    test "single-session reads are not limited: 40 rounds while the write bucket is empty" do
      u = RK.user!()
      v = RK.create!(u)
      exhaust_writes(u, v)
      assert RK.put_session(u.at, v, @room, "s30", RK.kbd(1, 0, false)).status == 429, "precondition: the write bucket is empty"

      for _ <- 1..40 do
        assert RK.get_keys(u.at, v, @room, "s1").status == 200
        assert RK.get_keys(u.at, v, @room, "none").status == 404
      end
    end

    # cycle 2 (deliberate, supersedes "own bucket 30 / min, burst 10 per user; the 11th is 429")
    test "bulk reads (GET /keys, GET /keys/{room}): own bucket 30 / min, burst 3 per user; the 4th is 429 with retry_after_ms and Retry-After" do
      u = RK.user!()
      v = RK.create!(u)
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s1", RK.kbd(1, 0, false)))

      statuses = for i <- 1..3, do: (if rem(i, 2) == 0, do: RK.get_keys(u.at, v), else: RK.get_keys(u.at, v, @room)).status
      assert statuses == List.duplicate(200, 3), "the first 3 bulk reads (all and room mixed) are inside the burst, got #{inspect(statuses)}"

      for c <- [RK.get_keys(u.at, v), RK.get_keys(u.at, v, @room), RK.get_keys(u.at, v, "!other:test.local")] do
        body = RK.assert_error(c, 429, "M_LIMIT_EXCEEDED")
        assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "retry_after_ms #{inspect(body)}"
        assert {ra, ""} = Integer.parse(T.header(c, "retry-after") || ""), "Retry-After header"
        assert ra >= 1
      end

      # everything else is untouched by the exhausted bulk bucket
      assert RK.get_version(u.at).status == 200 and RK.get_version(u.at, v).status == 200
      assert RK.get_keys(u.at, v, @room, "s1").status == 200 and RK.get_keys(u.at, v, @room, "nope").status == 404
      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s2", RK.kbd(1, 0, false))), "a write is not charged to the bulk bucket"
    end

    test "the bulk bucket and the write bucket are independent: 5 writes do not use up the bulk reads, 3 bulk reads do not use up the writes" do
      u = RK.user!()
      v = RK.create!(u)
      exhaust_writes(u, v)
      assert RK.put_session(u.at, v, @room, "s30", RK.kbd(1, 0, false)).status == 429, "precondition: the write bucket is empty"
      for _ <- 1..3, do: assert(RK.get_keys(u.at, v).status == 200, "the bulk bucket is full although the writes are used up")
      assert RK.get_keys(u.at, v).status == 429

      other = RK.user!()
      ov = RK.create!(other)
      assert RK.put_session(other.at, ov, @room, "s", RK.kbd(1, 0, false)).status == 200
      for _ <- 1..3, do: assert(RK.get_keys(other.at, ov).status == 200, "another user has a bulk bucket of his own")

      fresh_user = RK.user!()
      fv = RK.create!(fresh_user)
      for _ <- 1..3, do: assert(RK.get_keys(fresh_user.at, fv).status == 200)
      for i <- 1..4, do: assert(RK.put_session(fresh_user.at, fv, @room, "w#{i}", RK.kbd(i, 0, false)).status == 200, "3 bulk reads used up write tokens")
    end

    test "the bucket is per user and its own tier: another user writes, and this user's account-data writes are not charged to it" do
      u = RK.user!()
      v = RK.create!(u)
      exhaust_writes(u, v)
      assert RK.put_session(u.at, v, @room, "s30", RK.kbd(1, 0, false)).status == 429

      other = RK.user!()
      ov = RK.create!(other)
      assert RK.put_session(other.at, ov, @room, "s", RK.kbd(1, 0, false)).status == 200

      path = "/_matrix/client/v3/user/#{URI.encode_www_form(u.uid)}/account_data/m.rk.test"
      assert RK.req(:put, path, u.at, %{"a" => 1}).status == 200, "an exhausted room_keys bucket does not block account data"
    end

    test "account-data writes do not use up the room_keys bucket" do
      u = RK.user!()
      path = "/_matrix/client/v3/user/#{URI.encode_www_form(u.uid)}/account_data/m.rk.test"
      for i <- 1..30, do: assert(RK.req(:put, path, u.at, %{"i" => i}).status == 200)
      v = RK.create!(u)
      assert RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false)).status == 200
    end

    # cycle 1 (deliberate, supersedes "answered before the body is VALIDATED ... an oversize one is still 413"): since the body is no longer parsed by `JsonBody` before the
    # router but by the authenticated route AFTER the write rate limit, the 429 comes before the body is READ at all: an oversize body on an exhausted bucket is 429 too
    test "a 429 comes before the body is read: a malformed, invalid or OVERSIZE body on an exhausted bucket is 429, body never fetched" do
      u = RK.user!()
      v = RK.create!(u)
      exhaust_writes(u, v)
      RK.assert_error(RK.req(:put, RK.keys_path(v), u.at, {:raw, "{nope"}), 429, "M_LIMIT_EXCEEDED")
      RK.assert_error(RK.put_session(u.at, v, @room, "bad", %{"first_message_index" => "x"}), 429, "M_LIMIT_EXCEEDED")
      RK.assert_error(RK.put_session(u.at, "424242", @room, "s", RK.kbd(1, 0, false)), 429, "M_LIMIT_EXCEEDED")

      for size <- [RK.max_body_bytes() + 1, 6 * 1024 * 1024] do
        big = Jason.encode!(%{"rooms" => %{}}) <> String.duplicate(" ", size)
        c = RK.put_keys_raw(u.at, v, big)
        RK.assert_error(c, 429, "M_LIMIT_EXCEEDED")
        assert match?(%Plug.Conn.Unfetched{}, c.body_params), "the body of a rate-limited request was read / parsed"
      end

      for c <- [RK.post_version(u.at, {:raw, String.duplicate("x", 2_000_000)}), RK.put_version(u.at, v, {:raw, String.duplicate("x", 2_000_000)})] do
        RK.assert_error(c, 429, "M_LIMIT_EXCEEDED")
        assert match?(%Plug.Conn.Unfetched{}, c.body_params)
      end
    end
  end

  # ═══ cycle 2: the light bucket of the version reads ═══════════════════════════════════════════════════════════════════════

  describe "the version reads (GET /version, GET /version/{v}): own light bucket, 120 / min, burst 30 per user (cycle 2)" do
    setup do
      RK.enable_rate_limit()
      :ok
    end

    test "30 mixed reads of the two routes are inside the burst, the 31st of either route is 429 with retry_after_ms and Retry-After" do
      u = RK.user!()
      v = RK.create!(u)

      statuses = for i <- 1..30, do: (if rem(i, 2) == 0, do: RK.get_version(u.at), else: RK.get_version(u.at, v)).status
      assert statuses == List.duplicate(200, 30), "got #{inspect(Enum.uniq(statuses))}: the first 30 version reads are inside the burst"

      for c <- [RK.get_version(u.at), RK.get_version(u.at, v), RK.get_version(u.at, "424242")] do
        body = RK.assert_error(c, 429, "M_LIMIT_EXCEEDED")
        assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "retry_after_ms #{inspect(body)}"
        assert {ra, ""} = Integer.parse(T.header(c, "retry-after") || ""), "Retry-After header"
        assert ra >= 1
      end
    end

    test "an exhausted version bucket leaves the single-session GET, bulk reads and writes alone, and they do not use it up" do
      u = RK.user!()
      v = RK.create!(u)
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s1", RK.kbd(1, 0, false)))
      for _ <- 1..30, do: assert(RK.get_version(u.at).status == 200)
      assert RK.get_version(u.at).status == 429, "precondition: the version bucket is empty"

      assert RK.get_keys(u.at, v, @room, "s1").status == 200
      for _ <- 1..3, do: assert(RK.get_keys(u.at, v).status == 200, "the bulk bucket is its own")
      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s2", RK.kbd(1, 0, false))), "the write bucket is its own"

      fresh = RK.user!()
      fv = RK.create!(fresh)
      for _ <- 1..3, do: assert(RK.get_keys(fresh.at, fv).status == 200)
      exhaust = for i <- 1..4, do: RK.put_session(fresh.at, fv, @room, "w#{i}", RK.kbd(i, 0, false)).status
      assert exhaust == [200, 200, 200, 200]
      assert RK.put_session(fresh.at, fv, @room, "w5", RK.kbd(1, 0, false)).status == 429, "precondition: bulk reads and writes of this user are used up"
      for i <- 1..30, do: assert(RK.get_version(fresh.at).status == 200, "version read #{i}: bulk reads and writes do not use the version bucket")
      assert RK.get_version(fresh.at).status == 429

      other = RK.user!()
      _ = RK.create!(other)
      assert RK.get_version(other.at).status == 200, "another user has a version bucket of his own"
    end

    test "every answer is charged, 404 included: 30 reads of an unknown version or without a backup fill the bucket" do
      u = RK.user!()
      for _ <- 1..30, do: assert(RK.get_version(u.at).status == 404, "a user without a backup")
      RK.assert_error(RK.get_version(u.at), 429, "M_LIMIT_EXCEEDED")

      w = RK.user!()
      _ = RK.create!(w)
      for _ <- 1..30, do: assert(RK.get_version(w.at, "424242").status == 404)
      RK.assert_error(RK.get_version(w.at, "424242"), 429, "M_LIMIT_EXCEEDED")
    end
  end

  # ═══ cycle 2: the refill rates ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "refill rates (the clock is frozen at an instant and advanced by hand)" do
    setup do
      RK.enable_rate_limit()
      # the instant the clock is frozen at (`T.reset_rate_limits/0` decides it): read it back instead of assuming a number
      {:ok, t0: Application.fetch_env!(:nebu_http, :rate_limit_clock_fn).()}
    end

    test "writes: 60 / min, one token per second after the burst (999 ms: still 429, 1 001 ms: one more write, then 429 again)", %{t0: t0} do
      u = RK.user!()
      v = RK.create!(u)
      for i <- 1..4, do: assert(RK.put_session(u.at, v, @room, "s#{i}", RK.kbd(i, 0, false)).status == 200)
      RK.assert_error(RK.put_session(u.at, v, @room, "late", RK.kbd(1, 0, false)), 429, "M_LIMIT_EXCEEDED")

      RK.set_clock(t0 + 999)
      RK.assert_error(RK.put_session(u.at, v, @room, "late", RK.kbd(1, 0, false)), 429, "M_LIMIT_EXCEEDED")
      RK.set_clock(t0 + 1_001)
      assert {5, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "late", RK.kbd(1, 0, false)))
      RK.assert_error(RK.put_session(u.at, v, @room, "later", RK.kbd(1, 0, false)), 429, "M_LIMIT_EXCEEDED")
    end

    test "bulk reads: 30 / min, one token per 2 seconds after the burst of 3 (1 999 ms: still 429, 2 001 ms: one more read)", %{t0: t0} do
      u = RK.user!()
      v = RK.create!(u)
      for _ <- 1..3, do: assert(RK.get_keys(u.at, v).status == 200)
      RK.assert_error(RK.get_keys(u.at, v), 429, "M_LIMIT_EXCEEDED")

      RK.set_clock(t0 + 1_999)
      RK.assert_error(RK.get_keys(u.at, v), 429, "M_LIMIT_EXCEEDED")
      RK.set_clock(t0 + 2_001)
      assert RK.get_keys(u.at, v).status == 200
      RK.assert_error(RK.get_keys(u.at, v, @room), 429, "M_LIMIT_EXCEEDED")
    end

    test "version reads: 120 / min, one token per 500 ms after the burst of 30 (499 ms: still 429, 501 ms: one more read)", %{t0: t0} do
      u = RK.user!()
      v = RK.create!(u)
      for _ <- 1..30, do: assert(RK.get_version(u.at, v).status == 200)
      RK.assert_error(RK.get_version(u.at, v), 429, "M_LIMIT_EXCEEDED")

      RK.set_clock(t0 + 499)
      RK.assert_error(RK.get_version(u.at), 429, "M_LIMIT_EXCEEDED")
      RK.set_clock(t0 + 501)
      assert RK.get_version(u.at).status == 200
      RK.assert_error(RK.get_version(u.at, v), 429, "M_LIMIT_EXCEEDED")
    end
  end

  # ═══ authentication before the body (no pre-auth parse) ═══════════════════════════════════════════════════════════════════

  describe "the body is read only after authentication (cycle 1)" do
    setup do
      RK.disable_rate_limit()
      :ok
    end

    test "a junk bearer + 1 000 001 bytes or 6 MiB on every write route is 401 M_UNKNOWN_TOKEN, body never fetched, nothing stored" do
      {u, v} = fresh()
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "keep", RK.kbd(1, 0, false)))
      before = {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)}

      for size <- [1_000_001, 6 * 1024 * 1024],
          {method, path} <- [
            {:put, RK.keys_path(v)},
            {:put, RK.keys_path(v, @room)},
            {:put, RK.keys_path(v, @room, "keep")},
            {:post, RK.version_path()},
            {:put, RK.version_path(v)}
          ] do
        raw = Jason.encode!(%{"rooms" => %{}}) <> String.duplicate(" ", size)
        c = RK.req(method, path, "junk-token-#{size}", {:raw, raw})
        assert {c.status, RK.json(c)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}, "#{method} #{path} (#{size} bytes): #{c.status} #{String.slice(c.resp_body, 0, 100)}"
        assert match?(%Plug.Conn.Unfetched{}, c.body_params), "the body of an unauthenticated request was read / parsed (#{method} #{path})"
      end

      assert {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)} == before
      assert RK.info!(u.at, v)["etag"] == etag
    end

    test "a valid token with exactly 5 MiB is accepted, one byte more is 413 (version routes too)" do
      {u, v} = fresh()
      json = Jason.encode!(%{"algorithm" => @algo, "auth_data" => RK.auth_data("cap")})
      pad = fn json, total -> json <> String.duplicate(" ", total - byte_size(json)) end

      assert RK.put_version(u.at, v, {:raw, pad.(json, RK.max_body_bytes())}).status == 200
      c = RK.put_version(u.at, v, {:raw, pad.(json, RK.max_body_bytes() + 1)})
      assert {c.status, RK.json(c)} == {413, @too_large}
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("cap")
    end

    # cycle 2 (INFO-5): `Plug.Router` decodes the path segments, so `room%5Fkeys` IS the room_keys route; it must get the room_keys treatment (no pre-router parse, 5 MiB cap) too
    test "an ENCODED path (room%5Fkeys, v%33) is the same route: a 1.6 MB batch is accepted, 5 MiB + 1 is 413" do
      {u, v} = fresh()
      sessions = for i <- 1..200, into: %{}, do: {"e#{i}", RK.kbd(i, 0, false, RK.sized_data(8_000))}
      body = Jason.encode!(%{"rooms" => %{@room => %{"sessions" => sessions}}})
      assert byte_size(body) > 1_600_000

      for prefix <- ["/_matrix/client/v3/room%5Fkeys", "/_matrix/client/v%33/%72oom_keys"] do
        c = RK.req(:put, "#{prefix}/keys?version=#{v}", u.at, {:raw, body})
        assert c.status == 200, "PUT #{prefix}/keys: #{c.status} #{String.slice(c.resp_body, 0, 120)}"
        assert {200, _} = RK.count_etag!(c)

        too_big = RK.req(:put, "#{prefix}/keys?version=#{v}", u.at, {:raw, body <> String.duplicate(" ", RK.max_body_bytes() + 1 - byte_size(body))})
        assert {too_big.status, RK.json(too_big)} == {413, @too_large}
      end
    end

    test "an authenticated request with malformed JSON is still 400 M_NOT_JSON" do
      {u, v} = fresh()
      RK.assert_error(RK.req(:put, RK.keys_path(v), u.at, {:raw, "{nope"}), 400, "M_NOT_JSON")
      RK.assert_error(RK.req(:post, RK.version_path(), u.at, {:raw, "[1]"}), 400, "M_BAD_JSON")
    end
  end
end
