defmodule Nebu.Matrix.RoomKeysConcurrencyTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`, real pool connections) of the RACES of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011):
  "state lives only in the DB, cluster-safe" means that the decisions (merge, count, quota, version number) are made in the database under a per-user serialisation, never from a
  read-then-write in the request process.

    * Two or many concurrent uploads of the SAME session never double count and never lose the best one: the final stored session is the best of all (the merge rule is a total
      order on verified / first_message_index / forwarded_count), whatever the order of the commits.
    * Concurrent uploads of distinct sessions all count.
    * Concurrent `POST /version` at the quota boundary never exceed 10 versions (the rest are 403 M_FORBIDDEN) and never hand out the same version number twice.
    * A concurrent `DELETE /version` and key uploads leave no orphan session rows (no row of a deleted version), and never answer 5xx.
    * `count` of the backup is always the number of stored sessions after any mix of concurrent writes and deletes.

  The rate limiter is switched off (the tests send tens of writes). Cycle 2: a writer that finds the per-user lock busy is answered `429 M_LIMIT_EXCEEDED` AT ONCE (a try-lock,
  `room_keys_lock_timeout_test.exs`), so every concurrent request here is RETRIED while it is a 429, like a client does: the assertions are about the state the requests leave
  and the answers they get once they have been served, exactly as before.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @moduletag :integration

  @room "!race:test.local"
  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    u = RK.user!()
    {:ok, u: u, v: RK.create!(u)}
  end

  # at most 8 requests in flight: the repo pool has 10 connections, a larger burst only queues in the pool and makes timing tests flaky
  defp parallel(items, fun, max \\ 8) do
    items
    |> Task.async_stream(fn item -> settle(fun, item) end, max_concurrency: max, ordered: false, timeout: 120_000)
    |> Enum.map(fn {:ok, r} -> r end)
  end

  defp limited?(%Plug.Conn{status: 429} = c), do: RK.json(c)["errcode"] == "M_LIMIT_EXCEEDED"
  defp limited?({_tag, %Plug.Conn{} = c}), do: limited?(c)
  defp limited?(_), do: false

  # retries a request answered 429 (the per-user lock was busy) until it is served
  defp settle(fun, item, attempts \\ 400) do
    result = fun.(item)

    if attempts > 1 and limited?(result) do
      Process.sleep(Enum.random(2..15))
      settle(fun, item, attempts - 1)
    else
      result
    end
  end

  # the order of the merge rule as a sort key: bigger = better (verified, then LOWER index, then LOWER forwarded count)
  defp rank({fmi, fwd, verified?}), do: {verified?, -fmi, -fwd}

  describe "the same session uploaded concurrently" do
    test "20 concurrent uploads of ONE new session: all 200, count 1, one row, the stored one is the best (lowest first_message_index)", %{u: u, v: v} do
      uploads = for fmi <- 1..20, do: RK.kbd(fmi, 0, false, %{"c" => "d#{fmi}"})

      results = parallel(uploads, fn kbd -> RK.put_session(u.at, v, @room, "same", kbd) end)

      assert Enum.all?(results, &(&1.status == 200)), "statuses #{inspect(Enum.map(results, & &1.status))}: #{inspect(Enum.find(results, &(&1.status != 200)) |> then(&(&1 && &1.resp_body)))}"
      assert Enum.all?(results, fn c -> RK.json(c)["count"] == 1 end), "every answer counts the session once"
      assert RK.info!(u.at, v)["count"] === 1
      assert RK.rows(RK.sessions_table(), u.uid) == 1
      assert RK.sessions!(u.at, v)[{@room, "same"}] == Enum.at(uploads, 0), "the best upload wins whatever the commit order"
    end

    test "24 concurrent uploads of one session with distinct (verified, index, forwarded_count): the stored one is the best by the spec order, repeated 5 times", %{u: u, v: v} do
      for round <- 1..5 do
        sid = "round-#{round}"

        tuples =
          for fmi <- [3, 5, 8, 13], fwd <- [0, 2, 4], verified? <- [false, true] do
            {fmi, fwd, verified?}
          end

        # the shuffle is seeded and the seed is part of every failure message (a failure can be replayed)
        seed = {round, :erlang.unique_integer([:positive]), 17}
        :rand.seed(:exsss, seed)
        uploads = tuples |> Enum.shuffle() |> Enum.map(fn {fmi, fwd, ver} = t -> {t, RK.kbd(fmi, fwd, ver, %{"c" => inspect(t)})} end)

        results = parallel(uploads, fn {_t, kbd} -> RK.put_session(u.at, v, @room, sid, kbd) end)
        assert Enum.all?(results, &(&1.status == 200))

        best = Enum.max_by(tuples, &rank/1)
        {fmi, fwd, ver} = best
        stored = RK.sessions!(u.at, v)[{@room, sid}]
        assert {stored["first_message_index"], stored["forwarded_count"], stored["is_verified"]} == {fmi, fwd, ver}, "round #{round} (shuffle seed #{inspect(seed)}): best is #{inspect(best)}, stored #{inspect(stored)}"
        assert stored["session_data"] == %{"c" => inspect(best)}, "the WHOLE record is the best upload's, not a mix of two"
      end

      assert RK.info!(u.at, v)["count"] === 5
      assert RK.rows(RK.sessions_table(), u.uid) == 5
    end

    test "concurrent replacements of an already stored session: final = best, count stays 1", %{u: u, v: v} do
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(100, 0, false, %{"c" => "start"})))
      uploads = for fmi <- 0..30, do: RK.kbd(fmi, 0, false, %{"c" => "d#{fmi}"})

      results = parallel(uploads, fn kbd -> RK.put_room(u.at, v, @room, %{"s" => kbd}) end)
      assert Enum.all?(results, &(&1.status == 200))
      assert Enum.all?(results, fn c -> RK.json(c)["count"] == 1 end)
      assert RK.sessions!(u.at, v)[{@room, "s"}]["session_data"] == %{"c" => "d0"}
      assert RK.rows(RK.sessions_table(), u.uid) == 1
    end
  end

  describe "distinct sessions uploaded concurrently" do
    test "20 concurrent uploads through the three shapes: all stored, count 20, every answer count within 1..20", %{u: u, v: v} do
      ids = for i <- 1..20, do: "s#{i}"

      results =
        parallel(ids, fn sid ->
          i = String.to_integer(String.trim_leading(sid, "s"))
          kbd = RK.kbd(i, 0, false)

          case rem(i, 3) do
            0 -> RK.put_session(u.at, v, @room, sid, kbd)
            1 -> RK.put_room(u.at, v, @room, %{sid => kbd})
            2 -> RK.put_rooms(u.at, v, %{@room => %{sid => kbd}})
          end
        end)

      assert Enum.all?(results, &(&1.status == 200))
      assert Enum.all?(results, fn c -> RK.json(c)["count"] in 1..20 end)
      assert RK.info!(u.at, v)["count"] === 20
      assert RK.sessions!(u.at, v) |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.sort() == Enum.sort(ids)
    end

    test "after any mix of concurrent uploads and deletes the count equals the number of stored sessions", %{u: u, v: v} do
      ops =
        for i <- 1..60 do
          sid = "s#{rem(i, 12)}"
          if rem(i, 4) == 0, do: {:delete, sid}, else: {:put, sid, RK.kbd(rem(i * 7, 23), 0, false, %{"c" => "i#{i}"})}
        end

      results =
        parallel(ops, fn
          {:put, sid, kbd} -> RK.put_session(u.at, v, @room, sid, kbd)
          {:delete, sid} -> RK.delete_keys(u.at, v, @room, sid)
        end)

      assert Enum.all?(results, &(&1.status == 200)), "statuses #{inspect(Enum.map(results, & &1.status) |> Enum.uniq())}"
      stored = RK.sessions!(u.at, v)
      assert RK.info!(u.at, v)["count"] === map_size(stored)
      assert RK.rows(RK.sessions_table(), u.uid) == map_size(stored)
    end
  end

  describe "concurrent uploads at the session cap (seam :nebu, :room_keys_max_sessions_per_version)" do
    test "12 concurrent uploads of distinct new sessions with a cap of 5: exactly 5 are stored (200), 7 are 403 M_FORBIDDEN, never more than the cap", %{u: u, v: v} do
      RK.put_env_restoring(:nebu, :room_keys_max_sessions_per_version, 5)

      results = parallel(1..12, fn i -> RK.put_session(u.at, v, @room, "cap#{i}", RK.kbd(i, 0, false)) end)

      assert Enum.count(results, &(&1.status == 200)) == 5, "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert Enum.count(results, &(&1.status == 403)) == 7 and Enum.all?(results, &(&1.status in [200, 403]))
      assert RK.info!(u.at, v)["count"] === 5
      assert RK.rows(RK.sessions_table(), u.uid) == 5
    end

    test "concurrent batches that would each fit alone but not together: at most the cap is stored", %{u: u, v: v} do
      RK.put_env_restoring(:nebu, :room_keys_max_sessions_per_version, 6)

      results = parallel(1..4, fn i -> RK.put_room(u.at, v, @room, for(j <- 1..3, into: %{}, do: {"b#{i}-#{j}", RK.kbd(j, 0, false)})) end)

      assert Enum.count(results, &(&1.status == 200)) == 2, "two batches of 3 fit into a cap of 6, got #{inspect(Enum.map(results, & &1.status))}"
      assert RK.rows(RK.sessions_table(), u.uid) == 6
    end
  end

  describe "concurrent POST /version at the quota boundary" do
    test "15 concurrent creates from an empty backup: exactly 10 succeed with distinct versions, 5 are 403 M_FORBIDDEN, 10 rows" do
      u = RK.user!()

      results = parallel(1..15, fn i -> RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("c#{i}")}) end)

      {ok, refused} = Enum.split_with(results, &(&1.status == 200))
      assert length(ok) == 10, "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert length(refused) == 5 and Enum.all?(refused, fn c -> RK.json(c)["errcode"] == "M_FORBIDDEN" end)

      versions = Enum.map(ok, fn c -> RK.json(c)["version"] end)
      assert length(Enum.uniq(versions)) == 10, "a version number was handed out twice: #{inspect(Enum.sort(versions))}"
      assert RK.rows(RK.versions_table(), u.uid) == 10
      assert RK.info!(u.at)["version"] == Enum.max_by(versions, &String.to_integer/1)
    end

    test "from 9 existing versions: 6 concurrent creates give exactly one new version" do
      u = RK.user!()
      for i <- 1..9, do: RK.create!(u, RK.auth_data("pre#{i}"))

      results = parallel(1..6, fn i -> RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("c#{i}")}) end)
      assert Enum.count(results, &(&1.status == 200)) == 1, "statuses #{inspect(Enum.map(results, & &1.status))}"
      assert Enum.count(results, &(&1.status == 403)) == 5
      assert RK.rows(RK.versions_table(), u.uid) == 10
    end

    test "concurrent creates and deletes: the number of live versions never exceeds 10 and numbers are never reused" do
      u = RK.user!()
      first = for i <- 1..10, do: RK.create!(u, RK.auth_data("pre#{i}"))

      ops = Enum.map(first, &{:delete, &1}) ++ for(i <- 1..10, do: {:create, i})

      results =
        parallel(ops, fn
          {:delete, v} -> {:delete, RK.delete_version(u.at, v)}
          {:create, i} -> {:create, RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("n#{i}")})}
        end)

      assert Enum.all?(results, fn {_, c} -> c.status in [200, 403] end), "no 5xx and no other answer"
      created = for {:create, %{status: 200} = c} <- results, do: RK.json(c)["version"]
      assert length(Enum.uniq(created)) == length(created)
      assert Enum.all?(created, &(&1 not in first)), "a number of an earlier version was reused"

      live = Enum.count(created ++ first, fn v -> RK.get_version(u.at, v).status == 200 end)
      assert live <= 10, "#{live} live versions"
      for v <- first, do: assert(RK.get_version(u.at, v).status == 404, "the 10 first versions were all deleted")
    end
  end

  describe "a version deleted while keys are uploaded" do
    test "10 rounds of 5 concurrent uploads and a concurrent DELETE of the version: no 5xx, no orphan session rows", %{u: u} do
      for round <- 1..10 do
        v = RK.create!(u, RK.auth_data("round#{round}"))

        ops = [:delete | for(i <- 1..5, do: {:put, i})]

        results =
          parallel(ops, fn
            :delete -> RK.delete_version(u.at, v)
            {:put, i} -> RK.put_session(u.at, v, @room, "s#{i}", RK.kbd(i, 0, false))
          end)

        assert Enum.all?(results, &(&1.status in [200, 403, 404])), "round #{round}: statuses #{inspect(Enum.map(results, & &1.status))}"
        assert RK.get_version(u.at, v).status == 404
        assert RK.rows(RK.sessions_table(), u.uid) == 0, "round #{round}: session rows of a deleted version are left"
      end
    end
  end
end
