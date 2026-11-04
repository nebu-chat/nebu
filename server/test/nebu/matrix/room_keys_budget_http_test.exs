defmodule Nebu.Matrix.RoomKeysBudgetHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of the STORAGE QUOTAS of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011;
  cycle 1: Kassandra HIGH finding 1 and LOW finding 4, code review M1; cycle 2: HIGH memory finding, MEDIUM finding 3 "the budget ignores ids and row overhead"):

    * a per-user AGGREGATE BYTE BUDGET over all LIVE versions of the user. Cycle 2 accounting: for EVERY stored session row `octet_length(room_id) + octet_length(session_id) + 128`
      (a fixed cost per row) plus the canonical (compact JSON) bytes of its `session_data`, plus the `auth_data` bytes of every live version; the default is 64 MiB (cycle 1: 256 MiB
      counted `session_data` only; `config :nebu, :room_keys_max_bytes_per_user`, read at request time). It is decided under the per-user advisory lock like the other quotas,
      NET of replacements (a replaced session counts only the size DELTA, never old + new), it is freed by deleting a session or a version, an exceeded budget is
      `403 M_FORBIDDEN` (the same code as the other quotas: never `M_LIMIT_EXCEEDED`, which clients retry) and the request stores NOTHING (a batch is whole or nothing);
    * a cap on the TOTAL version rows per user INCLUDING the soft-delete markers (default 1000, `:room_keys_max_version_rows_per_user`): creating beyond it is `403 M_FORBIDDEN`
      even when no live version is left (a create / delete loop must not grow the table without limit); deleting and reading stay possible.

  The byte sizes are exact: `RK.sized_data(n)` is a session_data / auth_data object of exactly `n` canonical bytes; `cost/2` below is the cost of one stored session in the
  fixture room (`RK.session_cost/3`). Rate limits are off. The writers of one user answer 429 at once while the per-user lock is busy (try-lock), so the concurrent tests retry.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @moduletag :integration

  @room "!budget:test.local"
  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    :ok
  end

  # a session whose session_data is exactly `bytes` canonical bytes; `fmi` decides the merge (lower wins)
  defp kb(fmi, bytes), do: RK.kbd(fmi, 0, false, RK.sized_data(bytes))
  defp auth_bytes, do: RK.canonical_size(RK.auth_data())
  # what the session `sid` with `bytes` of session_data costs in the fixture room (ids and the fixed 128 bytes of the row included)
  defp cost(sid, bytes, room \\ @room), do: RK.session_cost(room, sid, bytes)
  defp pad2(i), do: String.pad_leading(Integer.to_string(i), 2, "0")

  defp new_user_with_version(auth \\ nil) do
    u = RK.user!()
    {u, RK.create!(u, auth)}
  end

  # ═══ the byte budget ═══════════════════════════════════════════════════════════════════════════════════════════════════

  describe "per-user byte budget (seam :nebu, :room_keys_max_bytes_per_user)" do
    test "the budget fits EXACTLY (session_data + auth_data bytes): one byte more is 403 M_FORBIDDEN and stores nothing" do
      # auth_data + 3 sessions of 3000 + the session "fits" of 8 data bytes (each with its ids and 128 bytes of row cost): the 4th fits exactly, a 5th does not
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 3 * cost("s1", 3_000) + cost("fits", 8))
      {u, v} = new_user_with_version()

      for i <- 1..3, do: assert({_, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s#{i}", kb(i, 3_000))))
      assert {4, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "fits", kb(1, 8)))

      body = RK.assert_error(RK.put_session(u.at, v, @room, "one-too-many", kb(1, 8)), 403, "M_FORBIDDEN")
      refute Map.has_key?(body, "retry_after_ms"), "a quota is not a rate limit: clients must not auto-retry it"
      assert RK.info!(u.at, v)["count"] === 4 and RK.info!(u.at, v)["etag"] == etag
      assert RK.rows(RK.sessions_table(), u.uid) == 4
      RK.assert_error(RK.get_keys(u.at, v, @room, "one-too-many"), 404, "M_NOT_FOUND")
    end

    test "the auth_data bytes count: with the budget of exactly one auth_data a second version is 403, a deleted version frees its bytes" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes())
      u = RK.user!()
      v1 = RK.create!(u)

      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
      assert RK.rows(RK.versions_table(), u.uid) == 1, "a refused POST created a version row"

      assert RK.delete_version(u.at, v1).status == 200
      v2 = RK.create!(u)
      assert String.to_integer(v2) > String.to_integer(v1), "the number is still never reused"
    end

    test "a replacement counts only the size DELTA (net, never gross): at a full budget a same-size replace is accepted, a bigger one is refused, a smaller one frees room" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 3 * cost("s1", 3_000))
      {u, v} = new_user_with_version()
      for i <- 1..3, do: RK.count_etag!(RK.put_session(u.at, v, @room, "s#{i}", kb(10, 3_000)))
      RK.assert_error(RK.put_session(u.at, v, @room, "extra", kb(1, 8)), 403, "M_FORBIDDEN")

      # same size, better index: replaced (delta 0)
      assert {3, etag_before} = RK.count_etag!(RK.put_session(u.at, v, @room, "s1", kb(5, 3_000)))
      assert RK.json(RK.get_keys(u.at, v, @room, "s1"))["first_message_index"] == 5

      # one byte bigger: delta +1 over the budget: refused, the stored session and the etag are unchanged
      RK.assert_error(RK.put_session(u.at, v, @room, "s2", kb(1, 3_001)), 403, "M_FORBIDDEN")
      assert RK.json(RK.get_keys(u.at, v, @room, "s2"))["first_message_index"] == 10
      assert RK.info!(u.at, v)["etag"] == etag_before

      # 1000 bytes smaller: delta -1000, and the freed room is usable at once: the new session "fresh" costs its ids + 128 + its data, so it fits EXACTLY with
      # data = 1000 - octet_length(room) - octet_length("fresh") - 128
      assert {3, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s2", kb(1, 2_000)))
      fresh_bytes = 1_000 - byte_size(@room) - byte_size("fresh") - RK.row_overhead()
      assert cost("fresh", fresh_bytes) == 1_000
      assert {4, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "fresh", kb(1, fresh_bytes)))
      RK.assert_error(RK.put_session(u.at, v, @room, "fresher", kb(1, 8)), 403, "M_FORBIDDEN")
    end

    test "a batch over the budget is refused as a whole: its replacement of a stored session and its new sessions are not stored" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 3 * cost("s1", 3_000))
      {u, v} = new_user_with_version()
      for i <- 1..3, do: RK.count_etag!(RK.put_session(u.at, v, @room, "s#{i}", kb(10, 3_000)))
      assert {3, etag} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "none"))
      before = RK.sessions!(u.at, v)

      c = RK.put_room(u.at, v, @room, %{"s1" => kb(1, 3_000), "new" => kb(1, 3_000)})
      RK.assert_error(c, 403, "M_FORBIDDEN")
      assert RK.sessions!(u.at, v) == before, "the refused batch changed the stored set"
      assert RK.info!(u.at, v)["etag"] == etag
    end

    test "the budget spans ALL live versions of the user (an older version's bytes count) and a version delete frees them all" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, 2 * auth_bytes() + 4 * cost("a1", 3_000))
      u = RK.user!()
      v1 = RK.create!(u)
      for i <- 1..3, do: RK.count_etag!(RK.put_session(u.at, v1, @room, "a#{i}", kb(1, 3_000)))
      v2 = RK.create!(u)

      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v2, @room, "b1", kb(1, 3_000)))
      RK.assert_error(RK.put_session(u.at, v2, @room, "b2", kb(1, 8)), 403, "M_FORBIDDEN")

      assert RK.delete_version(u.at, v1).status == 200
      for i <- 2..4, do: assert({_, _} = RK.count_etag!(RK.put_session(u.at, v2, @room, "b#{i}", kb(1, 3_000))))
      RK.assert_error(RK.put_session(u.at, v2, @room, "b5", kb(1, 3_000)), 403, "M_FORBIDDEN")
    end

    test "deleting sessions (one, a room, all keys) frees their bytes" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 2 * cost("s1", 3_000))
      {u, v} = new_user_with_version()
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, v, @room, %{"s1" => kb(1, 3_000), "s2" => kb(1, 3_000)}))
      RK.assert_error(RK.put_session(u.at, v, @room, "s3", kb(1, 8)), 403, "M_FORBIDDEN")

      assert {1, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s1"))
      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s3", kb(1, 3_000)))
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v))
      assert {2, _} = RK.count_etag!(RK.put_room(u.at, v, @room, %{"t1" => kb(1, 3_000), "t2" => kb(1, 3_000)}))
    end

    test "PUT /version counts the delta of auth_data too: a bigger auth_data over the budget is 403 and unchanged, an equal or smaller one is accepted" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, 100)
      u = RK.user!()
      v = RK.create!(u, RK.sized_data(100))

      RK.assert_error(RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(101)}), 403, "M_FORBIDDEN")
      assert RK.info!(u.at, v)["auth_data"] == RK.sized_data(100)
      assert RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(100)}).status == 200
      assert RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(50)}).status == 200
      assert RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.sized_data(100)}).status == 200
    end

    test "the budget is per USER: a full user does not block another one, and the other user's bytes do not count" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("s", 3_000))
      {a, va} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(a.at, va, @room, "s", kb(1, 3_000)))
      RK.assert_error(RK.put_session(a.at, va, @room, "t", kb(1, 8)), 403, "M_FORBIDDEN")

      {b, vb} = new_user_with_version()
      assert va == vb, "per-user counters: the same version number"
      assert {1, _} = RK.count_etag!(RK.put_session(b.at, vb, @room, "s", kb(1, 3_000)))
      assert RK.info!(a.at, va)["count"] === 1
    end

    test "the budget counts BYTES, not characters: 1 500 two-byte characters are 3 000 bytes" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("wide", 3_008))
      {u, v} = new_user_with_version()
      wide = RK.sized_data_multibyte(1_500)
      assert RK.canonical_size(wide) == 3_008 and String.length(wide["k"]) == 1_500

      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "wide", RK.kbd(1, 0, false, wide)))
      RK.assert_error(RK.put_session(u.at, v, @room, "one", kb(1, 8)), 403, "M_FORBIDDEN")
    end

    test "a refused request answers the standard envelope and the backup stays fully usable (reads, deletes, smaller writes)" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("s", 3_000))
      {u, v} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", kb(1, 3_000)))
      RK.assert_error(RK.put_session(u.at, v, @room, "t", kb(1, 100)), 403, "M_FORBIDDEN")

      assert RK.get_version(u.at).status == 200 and RK.get_keys(u.at, v).status == 200
      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s"))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "t", kb(1, 100)))
    end

    test "concurrent uploads at the budget: 12 distinct 3 000-byte sessions (equal ids widths) for room for exactly 5 store exactly 5 (decided under the lock)" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 5 * cost("c01", 3_000))
      {u, v} = new_user_with_version()

      results =
        1..12
        |> Task.async_stream(fn i -> RK.retrying(fn -> RK.put_session(u.at, v, @room, "c#{pad2(i)}", kb(i, 3_000)) end) end, max_concurrency: 8, ordered: false, timeout: 60_000)
        |> Enum.map(fn {:ok, c} -> c end)

      assert Enum.count(results, &(&1.status == 200)) == 5, "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert Enum.count(results, &(&1.status == 403)) == 7 and Enum.all?(results, &(&1.status in [200, 403]))
      assert RK.rows(RK.sessions_table(), u.uid) == 5 and RK.info!(u.at, v)["count"] === 5
    end

    test "concurrent version creations at a budget of two auth_data: exactly two are created" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, 2 * auth_bytes())
      u = RK.user!()

      results =
        1..8
        |> Task.async_stream(fn _ -> RK.retrying(fn -> RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}) end) end, max_concurrency: 8, ordered: false, timeout: 60_000)
        |> Enum.map(fn {:ok, c} -> c end)

      assert Enum.count(results, &(&1.status == 200)) == 2, "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert RK.rows(RK.versions_table(), u.uid) == 2
    end

    # cycle 2 (deliberate, supersedes "the DEFAULT budget is 256 MiB: 32 767 sessions of 8 192 bytes fit ..."): the default is 64 MiB and every row costs its ids + 128 bytes
    @tag :slow
    @tag timeout: 600_000
    test "the DEFAULT budget is 64 MiB: sessions of 8 192 bytes (row cost included) fill it, then exactly the remaining bytes fit and one byte more does not" do
      refute Application.get_env(:nebu, :room_keys_max_bytes_per_user), "precondition: no seam override, the default is under test"
      assert RK.default_max_bytes() == 64 * 1024 * 1024
      {u, v} = new_user_with_version()
      budget = RK.default_max_bytes()

      # as many "sN" sessions of 8 192 data bytes as still fit (each costs its ids and the 128 bytes of the row besides the data)
      {n, stored} =
        Enum.reduce_while(Stream.iterate(1, &(&1 + 1)), {0, auth_bytes()}, fn i, {n, used} ->
          c = cost("s#{i}", 8_192)
          if used + c <= budget, do: {:cont, {i, used + c}}, else: {:halt, {n, used}}
        end)

      assert n > 8_000 and n < 8_100, "about 64 MiB / 8 342 bytes of sessions, got #{n}: the default budget is not 64 MiB"

      for chunk <- Enum.chunk_every(1..n, 600) do
        sessions = for i <- chunk, into: %{}, do: {"s#{i}", RK.kbd(i, 0, false, RK.sized_data(8_192))}
        c = RK.put_room(u.at, v, @room, sessions)
        assert c.status == 200, "chunk starting at #{hd(chunk)}: #{c.status} #{String.slice(c.resp_body, 0, 160)}"
      end

      remaining = budget - stored
      # (the two ids below have the SAME length: "overs" is one byte over what "exact" fills to the byte)
      exact_bytes = remaining - byte_size(@room) - byte_size("exact") - RK.row_overhead()
      assert exact_bytes >= 8 and exact_bytes <= 8_192, "the fixture must leave room for one exact session, got #{exact_bytes}"

      RK.assert_error(RK.put_session(u.at, v, @room, "overs", RK.kbd(1, 0, false, RK.sized_data(exact_bytes + 1))), 403, "M_FORBIDDEN")
      assert {count, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "exact", RK.kbd(1, 0, false, RK.sized_data(exact_bytes))))
      assert count == n + 1
      RK.assert_error(RK.put_session(u.at, v, @room, "none-left", RK.kbd(1, 0, false, RK.sized_data(8))), 403, "M_FORBIDDEN")
    end
  end

  # ═══ cycle 2: the accounting counts ids and a fixed cost per row ════════════════════════════════════════════════════════════

  describe "a stored session costs octet_length(room_id) + octet_length(session_id) + 128 + its session_data (cycle 2)" do
    test "every part counts in BYTES: a budget of exactly one multi-byte-id session accepts it, one data byte more is 403" do
      room = "!ré-numéro:test.local"
      sid = "sèssion-ß"
      assert byte_size(room) > String.length(room) and byte_size(sid) > String.length(sid), "the ids must be multi-byte"
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost(sid, 2_000, room))

      {a, va} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(a.at, va, room, sid, kb(1, 2_000))), "exactly the budget: accepted"

      {b, vb} = new_user_with_version()
      RK.assert_error(RK.put_session(b.at, vb, room, sid, kb(1, 2_001)), 403, "M_FORBIDDEN")
      assert RK.rows(RK.sessions_table(), b.uid) == 0 and RK.info!(b.at, vb)["count"] === 0
    end

    test "the room_id counts: the same session in a room id 10 bytes longer than the budgeted one is refused" do
      short = "!r:t"
      long = short <> String.duplicate("x", 10)
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("s", 1_000, short))

      {a, va} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(a.at, va, short, "s", kb(1, 1_000)))
      {b, vb} = new_user_with_version()
      RK.assert_error(RK.put_session(b.at, vb, long, "s", kb(1, 1_000)), 403, "M_FORBIDDEN")
    end

    test "the session_id counts: the same session under an id 10 bytes longer than the budgeted one is refused" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("s", 1_000))

      {a, va} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(a.at, va, @room, "s", kb(1, 1_000)))
      {b, vb} = new_user_with_version()
      RK.assert_error(RK.put_session(b.at, vb, @room, "s" <> String.duplicate("x", 10), kb(1, 1_000)), 403, "M_FORBIDDEN")
    end

    test "the fixed 128 bytes per row count: exactly 5 tiny sessions fit, a 6th does not" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + 5 * cost("t1", 8))
      {u, v} = new_user_with_version()

      for i <- 1..5, do: assert({^i, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "t#{i}", kb(1, 8))))
      RK.assert_error(RK.put_session(u.at, v, @room, "t6", kb(1, 8)), 403, "M_FORBIDDEN")
      assert RK.rows(RK.sessions_table(), u.uid) == 5
    end

    test "the cost is per ROW: a batch of 4 sessions in two rooms costs the sum, one byte less refuses the batch" do
      r2 = "!second-room:test.local"
      batch = %{@room => %{"a1" => kb(1, 500), "a2" => kb(1, 500)}, r2 => %{"b1" => kb(1, 500), "b2" => kb(1, 500)}}
      total = 2 * cost("a1", 500) + 2 * cost("b1", 500, r2)

      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + total)
      {a, va} = new_user_with_version()
      assert {4, _} = RK.count_etag!(RK.put_rooms(a.at, va, batch))

      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + total - 1)
      {b, vb} = new_user_with_version()
      RK.assert_error(RK.put_rooms(b.at, vb, batch), 403, "M_FORBIDDEN")
      assert RK.rows(RK.sessions_table(), b.uid) == 0, "the refused batch stored nothing"
    end

    test "a replacement at a full budget costs no second row; deleting a row frees its ids and the 128 bytes" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, auth_bytes() + cost("s", 1_000))
      {u, v} = new_user_with_version()
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", kb(5, 1_000)))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", kb(1, 1_000))), "a better replacement of the same size: delta 0"
      RK.assert_error(RK.put_session(u.at, v, @room, "s2", kb(1, 8)), 403, "M_FORBIDDEN")

      assert {0, _} = RK.count_etag!(RK.delete_keys(u.at, v, @room, "s"))
      # "s2" has one id byte more than "s": 999 data bytes cost exactly what the deleted row did
      assert cost("s2", 999) == cost("s", 1_000)
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s2", kb(1, 999)))
      RK.assert_error(RK.put_session(u.at, v, @room, "s3", kb(1, 8)), 403, "M_FORBIDDEN")
    end

    test "deleting a whole version frees the ids and row costs of its sessions as well" do
      RK.put_env_restoring(:nebu, :room_keys_max_bytes_per_user, 2 * auth_bytes() + 3 * cost("a1", 2_000))
      u = RK.user!()
      v1 = RK.create!(u)
      assert {3, _} = RK.count_etag!(RK.put_room(u.at, v1, @room, %{"a1" => kb(1, 2_000), "a2" => kb(1, 2_000), "a3" => kb(1, 2_000)}))
      v2 = RK.create!(u)
      RK.assert_error(RK.put_session(u.at, v2, @room, "b1", kb(1, 8)), 403, "M_FORBIDDEN")

      assert RK.delete_version(u.at, v1).status == 200
      assert {3, _} = RK.count_etag!(RK.put_room(u.at, v2, @room, %{"b1" => kb(1, 2_000), "b2" => kb(1, 2_000), "b3" => kb(1, 2_000)}))
    end
  end

  # ═══ rows of versions, markers included ═════════════════════════════════════════════════════════════════════════════════

  describe "cap on the version rows of a user, soft-delete markers included (seam :nebu, :room_keys_max_version_rows_per_user)" do
    test "a create / delete loop is stopped at the cap although NO live version is left: the next create is 403 M_FORBIDDEN" do
      RK.put_env_restoring(:nebu, :room_keys_max_version_rows_per_user, 12)
      u = RK.user!()

      for _ <- 1..12 do
        v = RK.create!(u)
        assert RK.delete_version(u.at, v).status == 200
      end

      assert RK.rows(RK.versions_table(), u.uid) == 12, "twelve rows: all of them soft-delete markers"
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
      assert RK.rows(RK.versions_table(), u.uid) == 12, "a refused create left a row"
      RK.assert_error(RK.get_version(u.at), 404, "M_NOT_FOUND")
    end

    test "live versions and markers count together: 4 markers + 8 live versions fill a cap of 12" do
      RK.put_env_restoring(:nebu, :room_keys_max_version_rows_per_user, 12)
      u = RK.user!()
      for _ <- 1..4, do: RK.delete_version(u.at, RK.create!(u))
      live = for _ <- 1..8, do: RK.create!(u)

      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
      # deleting a live version turns it into a marker: the row stays, so it frees nothing
      assert RK.delete_version(u.at, hd(live)).status == 200
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
    end

    test "at the cap everything else still works: reads, key writes to the current version, PUT /version, repeated deletes" do
      RK.put_env_restoring(:nebu, :room_keys_max_version_rows_per_user, 3)
      u = RK.user!()
      v1 = RK.create!(u)
      _ = RK.create!(u)
      v3 = RK.create!(u)
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")

      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v3, @room, "s", kb(1, 100)))
      assert RK.put_version(u.at, v1, %{"algorithm" => @algo, "auth_data" => RK.auth_data("new")}).status == 200
      assert RK.delete_version(u.at, v1).status == 200
      assert RK.delete_version(u.at, v1).status == 200
      assert RK.get_version(u.at).status == 200
    end

    test "the cap is per user" do
      RK.put_env_restoring(:nebu, :room_keys_max_version_rows_per_user, 2)
      a = RK.user!()
      RK.delete_version(a.at, RK.create!(a))
      RK.delete_version(a.at, RK.create!(a))
      RK.assert_error(RK.post_version(a.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")

      b = RK.user!()
      assert RK.create!(b) =~ ~r/\A[1-9][0-9]*\z/
    end

    @tag :slow
    @tag timeout: 600_000
    test "the DEFAULT cap is 1000 rows: 1000 create / delete rounds are accepted, the 1001st create is 403 M_FORBIDDEN" do
      refute Application.get_env(:nebu, :room_keys_max_version_rows_per_user), "precondition: no seam override, the default is under test"
      u = RK.user!()

      for _ <- 1..1_000 do
        v = RK.create!(u)
        assert RK.delete_version(u.at, v).status == 200
      end

      assert RK.rows(RK.versions_table(), u.uid) == 1_000
      RK.assert_error(RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data()}), 403, "M_FORBIDDEN")
    end
  end

  # ═══ the partial index of the live versions is a migration fact (000058_room_key_backup_test.exs) ═════════════════════════
end
