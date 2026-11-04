defmodule Nebu.Matrix.RoomKeysLockTimeoutTest do
  @moduledoc """
  Acceptance tests (REAL database) of the PER-USER LOCK of the room_keys writers (story `server-side-key-backup`; cycle 1: Kassandra MEDIUM finding 2, cycle 2: the delta review of it):
  every writer takes the per-user `sync_global` advisory lock, and a request that WAITS for a lock holds a pooled database connection (pool of 10, shared by every user). One user's
  burst of writes - or a stuck transaction holding the lock - must not be able to exhaust the pool for everybody.

  Cycle 2 contract (supersedes cycle 1, which WAITED up to `SET LOCAL lock_timeout`, default 2000 ms - the tests "a wait, not a try-lock", "the DEFAULT timeout is 2 seconds" and
  "11 writers, all 429 after the timeout" and their mutant L05 are replaced by the tests below, deliberately): all NINE writers (`POST /version`, `PUT` and `DELETE /version/{v}`,
  `PUT` and `DELETE` of keys at every granularity) take the lock with `pg_try_advisory_xact_lock`. A lock that is busy is `429 M_LIMIT_EXCEEDED` with `retry_after_ms` AT ONCE (a client
  may retry: it is a transient condition), the request stores nothing, and no waiter ever holds a pool connection. Reads take no lock and never wait for one.

  The `lock_timeout` seam (`config :nebu, :room_keys_lock_timeout_ms`, read at request time, default 2000) stays ONLY as a safety net for ROW locks (a writer that needs a row another
  transaction holds, SQLSTATE 55P03 -> 429 as before): the second describe holds a row lock instead of the advisory lock.

  The lock is held by ANOTHER transaction of the test (`UserDeletionTestSupport.hold/1` + `lock_user_sql/0`, the key of `AccountDataStore.put/3` and of the erasure).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.RoomKeysTestSupport, as: RK
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @room "!lock:test.local"
  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    u = RK.user!()
    v = RK.create!(u)
    assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => "stored"})))
    {:ok, u: u, v: v}
  end

  # the nine writers; each returns the response conn
  defp writers(u, v) do
    [
      {:post_version, fn -> RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("lock")}) end},
      {:put_version, fn -> RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.auth_data("lock2")}) end},
      {:delete_version, fn -> RK.delete_version(u.at, v) end},
      {:put_rooms, fn -> RK.put_rooms(u.at, v, %{@room => %{"n1" => RK.kbd(1, 0, false)}}) end},
      {:put_room, fn -> RK.put_room(u.at, v, @room, %{"n2" => RK.kbd(1, 0, false)}) end},
      {:put_session, fn -> RK.put_session(u.at, v, @room, "n3", RK.kbd(1, 0, false)) end},
      {:delete_session, fn -> RK.delete_keys(u.at, v, @room, "s") end},
      {:delete_room, fn -> RK.delete_keys(u.at, v, @room) end},
      {:delete_all, fn -> RK.delete_keys(u.at, v) end}
    ]
  end

  # runs `fun` in a task; when it does not answer within `ms` the lock holder is released (so nothing hangs) and the test fails
  defp answer_within!(holder, fun, ms) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fun)

    case Task.yield(task, ms) do
      {:ok, conn} ->
        {conn, System.monotonic_time(:millisecond) - started}

      nil ->
        E.finish(holder, :rollback)
        Task.shutdown(task, :brutal_kill)
        flunk("the request still waited after #{ms} ms: a busy per-user lock must be answered 429 at once (try-lock), not waited for")
    end
  end

  describe "a writer that finds the per-user lock busy: 429 M_LIMIT_EXCEEDED at once (try-lock)" do
    test "each of the nine writers: 429 with retry_after_ms in under a second although the lock_timeout seam says 5 s", %{u: u, v: v} do
      RK.put_env_restoring(:nebu, :room_keys_lock_timeout_ms, 5_000)
      before = {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)}
      info = RK.info!(u.at, v)
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)

      for {name, request} <- writers(u, v) do
        {conn, elapsed} = answer_within!(holder, request, 1_500)
        body = RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
        assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "#{name}: retry_after_ms #{inspect(body)}"
        assert elapsed < 1_000, "#{name}: answered after #{elapsed} ms: a busy lock is a 429 at once"
      end

      E.finish(holder, :rollback)
      assert {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)} == before, "a refused writer stored or deleted something"
      assert RK.info!(u.at, v) == info
    end

    test "with NO seam (the defaults) the answer is just as immediate: the default 2 s wait of cycle 1 is gone", %{u: u, v: v} do
      refute Application.get_env(:nebu, :room_keys_lock_timeout_ms), "precondition: no seam override, the default is under test"
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)

      for {name, request} <- writers(u, v) do
        {conn, elapsed} = answer_within!(holder, request, 1_500)
        RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
        assert elapsed < 1_000, "#{name}: answered after #{elapsed} ms (cycle 1 waited about 2000 ms)"
      end

      E.finish(holder, :rollback)
    end

    test "after the holder is gone the same writers succeed (nothing is left locked or half done)", %{u: u, v: v} do
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)
      {conn, _} = answer_within!(holder, fn -> RK.put_session(u.at, v, @room, "n", RK.kbd(1, 0, false)) end, 1_500)
      RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
      E.finish(holder, :rollback)

      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "n", RK.kbd(1, 0, false)))
      assert RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("after")}).status == 200
    end

    test "25 concurrent writers behind a held lock ALL answer 429 within 2 s in total and the pool stays usable", %{u: u, v: v} do
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)
      started = System.monotonic_time(:millisecond)

      tasks = for i <- 1..25, do: Task.async(fn -> RK.put_session(u.at, v, @room, "w#{i}", RK.kbd(i, 0, false)) end)

      results =
        Enum.map(tasks, fn task ->
          case Task.yield(task, 4_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, conn} -> conn
            _ -> nil
          end
        end)

      elapsed = System.monotonic_time(:millisecond) - started
      if Enum.any?(results, &is_nil/1), do: E.finish(holder, :rollback)
      refute Enum.any?(results, &is_nil/1), "a writer was still waiting for the lock after 4 s: waiters hold the pool"
      assert Enum.all?(results, &(&1.status == 429)), "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert Enum.all?(results, fn c -> is_integer(RK.json(c)["retry_after_ms"]) end)
      assert elapsed < 2_000, "25 writers took #{elapsed} ms behind a held lock: they must be answered at once"

      # the pool works while the lock is STILL held: a read of this user and a write of another user are answered at once
      other = RK.user!()
      ov = RK.create!(other)
      assert {1, _} = RK.count_etag!(RK.put_session(other.at, ov, @room, "o", RK.kbd(1, 0, false)))
      assert RK.get_version(u.at).status == 200

      E.finish(holder, :rollback)
      assert RK.rows(RK.sessions_table(), u.uid) == 1
      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "after", RK.kbd(1, 0, false)))
    end

    test "the lock of ANOTHER user does not matter: a writer of user B is served while A's lock is held", %{u: u} do
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)
      other = RK.user!()
      ov = RK.create!(other)
      assert {1, _} = RK.count_etag!(RK.put_session(other.at, ov, @room, "o", RK.kbd(1, 0, false)))
      E.finish(holder, :rollback)
    end
  end

  describe "reads never wait for the lock" do
    test "GET /version, /version/{v}, /keys, /keys/{room}, /keys/{room}/{session} while another transaction holds the user lock: 200 at once", %{u: u, v: v} do
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [u.uid]) end)

      for {label, read} <- [
            {:version, fn -> RK.get_version(u.at) end},
            {:version_n, fn -> RK.get_version(u.at, v) end},
            {:all, fn -> RK.get_keys(u.at, v) end},
            {:room, fn -> RK.get_keys(u.at, v, @room) end},
            {:session, fn -> RK.get_keys(u.at, v, @room, "s") end}
          ] do
        {conn, elapsed} = answer_within!(holder, read, 1_500)
        assert conn.status == 200, "#{label}: #{conn.status}"
        assert elapsed < 1_000, "#{label}: a read waited #{elapsed} ms"
      end

      E.finish(holder, :rollback)
    end
  end

  # the safety net: the advisory lock is free, but another transaction holds the ROW of the version (a stuck erasure, an operator's SELECT ... FOR UPDATE)
  describe "the lock_timeout seam stays as the safety net of ROW locks: 55P03 is 429 M_LIMIT_EXCEEDED after about the timeout" do
    defp hold_version_row(u, v) do
      E.hold(fn -> T.sql!("SELECT 1 FROM room_key_backup_versions WHERE user_id = $1 AND version = $2 FOR UPDATE", [u.uid, String.to_integer(v)]) end)
    end

    # the writers that need the version row (UPDATE / FOR UPDATE); `POST` inserts a new row and the other writes of a stored set bump the etag of this row
    defp row_writers(u, v) do
      [
        {:put_version, fn -> RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => RK.auth_data("row")}) end},
        {:delete_version, fn -> RK.delete_version(u.at, v) end},
        {:put_session, fn -> RK.put_session(u.at, v, @room, "n3", RK.kbd(1, 0, false)) end},
        {:delete_session, fn -> RK.delete_keys(u.at, v, @room, "s") end}
      ]
    end

    test "a writer that needs a locked row waits up to the seam (300 ms), then 429 with retry_after_ms; nothing stored", %{u: u, v: v} do
      RK.put_env_restoring(:nebu, :room_keys_lock_timeout_ms, 300)
      before = {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)}
      holder = hold_version_row(u, v)

      for {name, request} <- row_writers(u, v) do
        {conn, elapsed} = answer_within_row!(holder, request, 5_000)
        body = RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
        assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "#{name}: retry_after_ms #{inspect(body)}"
        assert elapsed >= 250, "#{name}: answered after #{elapsed} ms: a ROW lock is waited for up to the lock_timeout seam"
        assert elapsed < 3_000, "#{name}: answered after #{elapsed} ms"
      end

      E.finish(holder, :rollback)
      assert {RK.rows(RK.versions_table(), u.uid), RK.rows(RK.sessions_table(), u.uid)} == before, "a timed-out writer stored or deleted something"
    end

    test "the default row-lock timeout is 2 seconds (no seam): the answer comes after about 2000 ms", %{u: u, v: v} do
      refute Application.get_env(:nebu, :room_keys_lock_timeout_ms), "precondition: no seam override, the default is under test"
      holder = hold_version_row(u, v)
      {conn, elapsed} = answer_within_row!(holder, fn -> RK.put_session(u.at, v, @room, "n", RK.kbd(1, 0, false)) end, 6_000)
      E.finish(holder, :rollback)

      RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
      assert elapsed >= 1_800 and elapsed < 4_500, "answered after #{elapsed} ms, the default lock timeout is 2000 ms"
    end

    test "after the row lock is gone the writers succeed", %{u: u, v: v} do
      RK.put_env_restoring(:nebu, :room_keys_lock_timeout_ms, 200)
      holder = hold_version_row(u, v)
      {conn, _} = answer_within_row!(holder, fn -> RK.put_session(u.at, v, @room, "n", RK.kbd(1, 0, false)) end, 5_000)
      RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
      E.finish(holder, :rollback)

      assert {2, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "n", RK.kbd(1, 0, false)))
    end

    defp answer_within_row!(holder, fun, ms) do
      started = System.monotonic_time(:millisecond)
      task = Task.async(fun)

      case Task.yield(task, ms) do
        {:ok, conn} ->
          {conn, System.monotonic_time(:millisecond) - started}

        nil ->
          E.finish(holder, :rollback)
          Task.shutdown(task, :brutal_kill)
          flunk("the request still waited for the row lock after #{ms} ms: no lock_timeout")
      end
    end
  end
end
