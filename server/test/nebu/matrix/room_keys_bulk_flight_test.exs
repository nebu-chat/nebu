defmodule Nebu.Matrix.RoomKeysBulkFlightTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of the BULK-READ SLOTS of story `server-side-key-backup` (cycle 2, orchestrator decision 1b; Kassandra HIGH memory finding):
  a bulk read (`GET /keys`, `GET /keys/{room}`) materialises up to the whole byte budget of a user (~300-350 MiB peak per request before the lower budget), so the number of bulk
  reads IN FLIGHT is capped, independent of the rate limit:

    * at most ONE bulk read in flight per user, and at most TWO per node (seam `config :nebu, :room_keys_max_concurrent_bulk_reads_per_node`, default 2, read at request time);
    * the excess is answered `429 M_LIMIT_EXCEEDED` with `retry_after_ms` AT ONCE, before any database work (the proof here: the database is blocked, the answer still comes);
    * the slot is MONITOR based (a Registry / GenServer with `Process.monitor`): a request process that is killed while it reads frees its slots when it goes DOWN (not only
      `try / after` of a request that finishes normally), and a finished request - 200, 404, 400 - frees them;
    * the single-session GET and the version GETs take no slot (they are small reads).

  How a read is held in flight: another transaction takes `LOCK TABLE room_key_backup_sessions IN ACCESS EXCLUSIVE MODE`, so every read of the table waits (`E.await_blocked!/3` proves the
  request is inside the database). The rate limiter is OFF: the slots are a resource guard and must hold without it.
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.RoomKeysTestSupport, as: RK
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @room "!flight:test.local"

  setup do
    RK.disable_rate_limit()
    :ok
  end

  # a user with a current version and one stored session (a bulk read has something to read)
  defp prepared do
    u = RK.user!()
    v = RK.create!(u)
    assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => "flight"})))
    {u, v}
  end

  defp hold_reads, do: E.hold(fn -> T.sql!("LOCK TABLE room_key_backup_sessions IN ACCESS EXCLUSIVE MODE") end)

  defp bulk(u, v, :all), do: Task.async(fn -> RK.get_keys(u.at, v) end)
  defp bulk(u, v, :room), do: Task.async(fn -> RK.get_keys(u.at, v, @room) end)

  # a request that must be answered at once (before any database work): the database is blocked, so a request that does work waits
  defp at_once!(holder, fun) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fun)

    case Task.yield(task, 1_500) do
      {:ok, conn} ->
        {conn, System.monotonic_time(:millisecond) - started}

      nil ->
        E.finish(holder, :rollback)
        Task.shutdown(task, :brutal_kill)
        flunk("the request was not answered within 1.5 s while the database was blocked: it was admitted (or did database work) instead of a 429 before any DB work")
    end
  end

  defp assert_limited!(conn) do
    body = RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
    assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0, "retry_after_ms #{inspect(body)}"
  end

  # polls until a bulk read of `u` is ADMITTED (blocked in the database, not answered 429): the slot of a killed request is freed when its DOWN is processed
  defp admitted_soon!(holder, u, v, what, tries \\ 60) do
    task = bulk(u, v, :all)

    case Task.yield(task, 250) do
      nil ->
        task

      {:ok, conn} when tries > 1 ->
        assert conn.status == 429, "#{what}: expected an admitted (blocked) read or a 429, got #{conn.status}"
        Process.sleep(50)
        admitted_soon!(holder, u, v, what, tries - 1)

      {:ok, conn} ->
        E.finish(holder, :rollback)
        flunk("#{what}: the slot was not freed within 3 s (still #{conn.status})")
    end
  end

  describe "at most ONE bulk read in flight per user" do
    test "a second bulk read of the same user (GET /keys or GET /keys/{room}) is 429 M_LIMIT_EXCEEDED at once while the first is in the database; afterwards the slot is free" do
      RK.put_env_restoring(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 5)
      {u, v} = prepared()
      holder = hold_reads()
      first = bulk(u, v, :all)
      E.await_blocked!(first, holder.backend, "the first bulk read")

      for fun <- [fn -> RK.get_keys(u.at, v) end, fn -> RK.get_keys(u.at, v, @room) end, fn -> RK.get_keys(u.at, v, "!other:test.local") end] do
        {conn, elapsed} = at_once!(holder, fun)
        assert_limited!(conn)
        assert elapsed < 1_000, "answered after #{elapsed} ms"
      end

      E.finish(holder, :rollback)
      assert Task.await(first, 15_000).status == 200
      assert RK.get_keys(u.at, v).status == 200, "the slot is free after the first read finished"
      assert RK.get_keys(u.at, v, @room).status == 200
    end

    test "the slot is per USER: while user A's read is in flight, user B's bulk read is admitted (not 429)" do
      RK.put_env_restoring(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 5)
      {a, av} = prepared()
      {b, bv} = prepared()
      holder = hold_reads()
      ta = bulk(a, av, :all)
      E.await_blocked!(ta, holder.backend, "A's bulk read")

      tb = bulk(b, bv, :room)
      E.await_blocked!([ta, tb], holder.backend, "B's bulk read (admitted: it reached the database, a 429 would have completed)")

      E.finish(holder, :rollback)
      assert Task.await(ta, 15_000).status == 200 and Task.await(tb, 15_000).status == 200
    end

    test "the single-session GET and the version GETs take no slot: they are admitted while the user's bulk read is in flight" do
      RK.put_env_restoring(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 5)
      {u, v} = prepared()
      holder = hold_reads()
      first = bulk(u, v, :all)
      E.await_blocked!(first, holder.backend, "the bulk read")

      small = [
        Task.async(fn -> RK.get_keys(u.at, v, @room, "s") end),
        Task.async(fn -> RK.get_version(u.at) end),
        Task.async(fn -> RK.get_version(u.at, v) end)
      ]

      E.await_blocked!([first | small], holder.backend, "the small reads (admitted: they reached the database)")
      E.finish(holder, :rollback)
      assert Task.await(first, 15_000).status == 200
      assert Enum.all?(small, fn t -> Task.await(t, 15_000).status == 200 end)
    end
  end

  describe "at most TWO bulk reads in flight per node (seam :nebu, :room_keys_max_concurrent_bulk_reads_per_node)" do
    test "the default is 2: users A and B read, user C's bulk read is 429 at once; when one finishes C is admitted" do
      refute Application.get_env(:nebu, :room_keys_max_concurrent_bulk_reads_per_node), "precondition: no seam override, the default is under test"
      assert RK.default_bulk_reads_per_node() == 2
      {a, av} = prepared()
      {b, bv} = prepared()
      {c, cv} = prepared()
      holder = hold_reads()
      ta = bulk(a, av, :all)
      tb = bulk(b, bv, :room)
      E.await_blocked!([ta, tb], holder.backend, "the two reads in flight")

      for fun <- [fn -> RK.get_keys(c.at, cv) end, fn -> RK.get_keys(c.at, cv, @room) end] do
        {conn, elapsed} = at_once!(holder, fun)
        assert_limited!(conn)
        assert elapsed < 1_000, "answered after #{elapsed} ms"
      end

      E.finish(holder, :rollback)
      assert Task.await(ta, 15_000).status == 200 and Task.await(tb, 15_000).status == 200
      assert RK.get_keys(c.at, cv).status == 200, "with the two slots free again, C is admitted"
    end

    test "the cap is read at request time: seam 3 admits three users and refuses the fourth, seam 1 refuses the second" do
      RK.put_env_restoring(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 3)
      users = for _ <- 1..4, do: prepared()
      [{a, av}, {b, bv}, {c, cv}, {d, dv}] = users
      holder = hold_reads()
      tasks = [bulk(a, av, :all), bulk(b, bv, :all), bulk(c, cv, :room)]
      E.await_blocked!(tasks, holder.backend, "three reads in flight")

      {conn, _} = at_once!(holder, fn -> RK.get_keys(d.at, dv) end)
      assert_limited!(conn)
      E.finish(holder, :rollback)
      for t <- tasks, do: assert(Task.await(t, 15_000).status == 200)

      Application.put_env(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 1)
      holder = hold_reads()
      first = bulk(a, av, :all)
      E.await_blocked!(first, holder.backend, "one read in flight")
      {conn, _} = at_once!(holder, fn -> RK.get_keys(b.at, bv) end)
      assert_limited!(conn)
      E.finish(holder, :rollback)
      assert Task.await(first, 15_000).status == 200
    end
  end

  describe "the slots are monitor based and are freed by every way a request ends" do
    test "a request process that is KILLED while it reads frees the user's slot (not only a request that finishes normally)" do
      RK.put_env_restoring(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, 5)
      {u, v} = prepared()
      holder = hold_reads()
      first = bulk(u, v, :all)
      E.await_blocked!(first, holder.backend, "the read to be killed")

      {conn, _} = at_once!(holder, fn -> RK.get_keys(u.at, v) end)
      assert_limited!(conn)

      Process.unlink(first.pid)
      Process.exit(first.pid, :kill)

      second = admitted_soon!(holder, u, v, "the user's slot after the kill")
      E.finish(holder, :rollback)
      assert Task.await(second, 15_000).status == 200
    end

    test "a killed request frees the NODE slot as well: with two reads in flight, killing one admits a third user" do
      {a, av} = prepared()
      {b, bv} = prepared()
      {c, cv} = prepared()
      holder = hold_reads()
      ta = bulk(a, av, :all)
      tb = bulk(b, bv, :all)
      E.await_blocked!([ta, tb], holder.backend, "two reads in flight")
      {conn, _} = at_once!(holder, fn -> RK.get_keys(c.at, cv) end)
      assert_limited!(conn)

      Process.unlink(ta.pid)
      Process.exit(ta.pid, :kill)

      third = admitted_soon!(holder, c, cv, "the node slot after the kill")
      E.finish(holder, :rollback)
      assert Task.await(third, 15_000).status == 200
      assert Task.await(tb, 15_000).status == 200
    end

    test "a finished request frees its slot whatever the answer (200, 404, 400): 12 sequential reads are never 429" do
      {u, v} = prepared()
      empty = RK.create!(u)

      answers =
        for i <- 1..12 do
          conn =
            case rem(i, 4) do
              0 -> RK.get_keys(u.at, v)
              1 -> RK.get_keys(u.at, "424242")
              2 -> RK.get_keys(u.at, nil, @room)
              3 -> RK.get_keys(u.at, empty, @room)
            end

          conn.status
        end

      refute 429 in answers, "a slot stayed taken after a request ended: #{inspect(answers)}"
      assert Enum.sort(Enum.uniq(answers)) == [200, 400, 404]
    end
  end
end
