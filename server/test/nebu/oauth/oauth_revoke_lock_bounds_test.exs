defmodule Nebu.OAuth.OAuthRevokeLockBoundsTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for bugfix story `revoke-lock-bounds` (epic SEC gate 3, finding
  G3-1), AC1-AC4: a long `Nebu.OAuth.revoke_client/3` holds every torn-down `devices` row (`FOR UPDATE`, then
  `DELETE`) until commit. Two request paths used to wait on those rows WITHOUT a bound, each holding a pool
  connection (pool 10): (1) the `per_refresh` IdP lease claim (INSERT into `oauth_idp_refresh_leases`, whose FK
  check takes KEY SHARE on the `devices` row) and (2) `/sync` -> `DeviceKeyStore.touch_last_seen/3` (UPDATE of the
  `devices` row, Ecto's 15 s query timeout).

  ## How the revoke is made to hold the devices rows (no new lib seam)

  The existing compile-guarded seam `:nebu_http, :oauth_client_revoke_hook` (0-arity, runs inside the revoke's
  transaction, in the revoke's process, right after the status UPDATE and BEFORE the teardown) is used, and the hook
  itself takes `SELECT ... FROM devices ... FOR UPDATE` on every device of the client through the transaction's own
  connection, tells the test, and blocks on a message. That is exactly the state the teardown reaches a moment later
  (it locks the same rows FOR UPDATE before its DELETE), only deterministic and sleep-free. "The other side really
  waits for a lock" is proven by polling `pg_stat_activity` (after `pg_stat_clear_snapshot()`), never by a timeout.

  ## Contract pinned here (what the implementation has to provide)

    * `OAuthSessionStore.claim_lease/4`: the claim runs in a short transaction with `SET LOCAL lock_timeout = '300ms'` (review cycle 1, Kassandra L-1)
      (reset afterwards); a lock timeout returns `{:error, :lock_timeout}` (new, distinct from the generic
      `{:error, reason}`); `Nebu.Matrix.OAuthSession.refresh/4` maps it to `{:error, {:unavailable, 5}}` =>
      `503 {}` + `Retry-After: 5`, no `error` member, never 429 / `invalid_grant`. The lease row is not left behind
      (the transaction rolled back), nothing is consumed, the IdP is not called.
    * `DeviceKeyStore.touch_last_seen/3` skips a locked row (`FOR NO KEY UPDATE SKIP LOCKED`): it returns
      `:ok` immediately, never raises, does not update the locked row; unlocked rows are still updated.

  Every potentially blocking call of a test runs in a Task with a short test-level bound (`bounded/3`, then
  `Task.shutdown(:brutal_kill)`), and the revoke is ALWAYS released in an `after`, so a red run costs seconds, not
  the 15 s DB timeout times the number of waiters.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Matrix.DeviceKeyStore
  alias Nebu.Matrix.Session.MatrixSessionStore
  alias Nebu.Matrix.Session.OAuthSessionStore
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @other "https://other.example.com/cb"
  @admin "@admin:test.local"
  # the lock bound of the fix is 300 ms; the margin is for a loaded CI node, the bound is far below the 15 s DB timeout
  @bound_ms 8_000
  @fast_ms 3_000

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_client_revoke_hook, :oauth_repo, :oauth_session_repo], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "LB" <> String.upcase(T.rand(4))
  defp session(cid, priv), do: T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
  defp revoke(cid), do: apply(Nebu.OAuth, :revoke_client, [cid, @admin, [reason: "lock-bounds"]])

  # The hook: lock every device of the client FOR UPDATE through the revoke transaction's connection, announce, block.
  defp hold_hook(cid) do
    parent = self()

    fn ->
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT 1 FROM devices d WHERE (d.user_id, d.device_id) IN " <>
          "(SELECT user_id, device_id FROM matrix_sessions WHERE client_id = $1) FOR UPDATE",
        [cid]
      )

      send(parent, {:revoke_holding, self()})

      receive do
        :release -> :ok
      after
        60_000 -> :ok
      end
    end
  end

  # Starts a revoke that holds the devices rows, runs `fun`, ALWAYS releases (also when `fun` fails an assertion) and
  # returns `{fun_result, revoke_result}`.
  defp with_revoke_hold(cid, fun) do
    T.put_env_scoped(:oauth_client_revoke_hook, hold_hook(cid))
    rv = Task.async(fn -> revoke(cid) end)
    assert_receive {:revoke_holding, hook_pid}, 10_000

    result =
      try do
        fun.()
      after
        send(hook_pid, :release)
      end

    {result, Task.await(rv, 30_000)}
  end

  # Runs `fun` in a Task; a blocked call fails the test after `ms` (and kills the Task) instead of waiting for the DB timeout.
  defp bounded(label, fun, ms \\ @bound_ms) do
    task = Task.async(fn -> timed(fun) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {elapsed, value}} -> {elapsed, value}
      _ -> flunk("#{label}: still blocked after #{ms} ms: it waits for the row locks of the revoke (G3-1)")
    end
  end

  # A request that RAISES (e.g. a dropped pool checkout) must not take the test process down through the Task link:
  # it becomes a 599 answer, so the assertion on the status reports it.
  defp timed(fun) do
    started = System.monotonic_time(:millisecond)

    value =
      try do
        fun.()
      rescue
        e -> %Plug.Conn{status: 599, resp_body: "raised #{inspect(e.__struct__)}", resp_headers: []}
      end

    {System.monotonic_time(:millisecond) - started, value}
  end

  # Polls (<= 10 s, every 25 ms) until a backend of the test database waits for a lock.
  defp wait_for_lock_wait(deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    T.sql!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[waiting]]} =
      T.sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()")

    cond do
      waiting > 0 -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("no backend waits for a lock: the request was not blocked by the held rows")
      true -> Process.sleep(25) && wait_for_lock_wait(deadline)
    end
  end

  # Like `wait_for_lock_wait/1` but waits for `n` waiting backends and polls over a raw (non-pool) connection, so the
  # poll itself works while the pool is exhausted (the situation AC3 provokes).
  defp wait_for_lock_waits(n, deadline \\ System.monotonic_time(:millisecond) + 15_000) do
    %{rows: [[waiting]]} =
      raw_app_sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()")

    cond do
      waiting >= n -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("only #{waiting} of the expected #{n} backends wait for a lock")
      true -> Process.sleep(50) && wait_for_lock_waits(n, deadline)
    end
  end

  # One short-lived connection as the RUNTIME role (it only sees the activity of its own role, which is what the waiters
  # are), outside `Nebu.Repo`'s pool.
  defp raw_app_sql!(sql) do
    uri = URI.parse(System.get_env("NEBU_DB_URL") || raise("NEBU_DB_URL is not set"))
    [user, pass] = String.split(uri.userinfo, ":", parts: 2)

    {:ok, conn} =
      Postgrex.start_link(
        [hostname: uri.host, port: uri.port || 5432, username: user, password: pass, database: String.trim_leading(uri.path, "/"), pool_size: 1] ++
          Nebu.Release.postgres_ssl_opts(uri.host)
      )

    try do
      Postgrex.query!(conn, sql, [])
    after
      GenServer.stop(conn)
    end
  end

  defp assert_503_retry(conn, label, retry_after) do
    assert conn.status == 503, "#{label}: expected 503, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 160)}"
    assert T.header(conn, "retry-after") == retry_after, "#{label}: Retry-After #{retry_after}, got #{inspect(T.header(conn, "retry-after"))}"
    refute Map.has_key?(T.json(conn), "error"), "#{label}: the 503 has no `error` member (the client retries, it does not log out)"
  end

  defp last_seen(user_id, device_id) do
    T.sql!("SELECT last_seen_ts, last_seen_ip FROM devices WHERE user_id = $1 AND device_id = $2", [user_id, device_id]).rows |> List.first()
  end

  defp reset_last_seen!(%{user_id: u, device_id: d}),
    do: T.sql!("UPDATE devices SET last_seen_ts = NULL, last_seen_ip = NULL WHERE user_id = $1 AND device_id = $2", [u, d])

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — per_refresh refresh with a revoke holding the devices rows
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — a per_refresh refresh while a revoke holds the devices rows (the DEFAULT mode)" do
    test "503 {} + Retry-After: 5 within the lock bound, nothing consumed, the IdP not called, no lease row left, then invalid_grant after the commit", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      before = T.rows_snapshot(s.user_id, s.device_id)

      # the state is read while the revoke still holds the rows (after its commit the sessions are torn down, which
      # would make "nothing is consumed" meaningless)
      {{{elapsed, conn}, lease_rows, rows_during}, {:ok, %{devices: 1}}} =
        with_revoke_hold(cid, fn ->
          waiter = Task.async(fn -> timed(fn -> T.refresh(cid, s.rt) end) end)
          wait_for_lock_wait()

          answer =
            case Task.yield(waiter, @bound_ms) || Task.shutdown(waiter, :brutal_kill) do
              {:ok, result} -> result
              _ -> flunk("the refresh is still blocked after #{@bound_ms} ms: the lease claim waits for the revoke's devices lock without a bound (G3-1)")
            end

          {answer, T.lease_rows(s.user_id, s.device_id), T.rows_snapshot(s.user_id, s.device_id)}
        end)

      assert_503_retry(conn, "refresh", "5")
      assert elapsed < @bound_ms, "bounded by the 300 ms lock timeout, not by the revoke (#{elapsed} ms)"
      refute_received {:idp_refresh, _}
      assert lease_rows == [], "the lease row must not be left behind"
      assert rows_during == before, "nothing is consumed: the refresh token stays valid"

      # the revoke has committed now: the same refresh answers the normal rejection of a revoked client
      after_commit = T.refresh(cid, s.rt)
      assert after_commit.status in [400, 401], "revoked client => invalid_grant / invalid_client, got #{after_commit.status} #{after_commit.resp_body}"
      assert T.json(after_commit)["error"] in ["invalid_grant", "invalid_client"]
    end

    test "the refresh token stays usable when the revoke is withdrawn: with the rows free again the same refresh token is served (200)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)

      # a blocker that holds the devices row and then ROLLS BACK (no revoke): the 503 must not have burnt the token
      parent = self()

      holder =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [s.user_id, s.device_id])
            send(parent, {:row_held, self()})

            receive do
              :release -> Nebu.Repo.rollback(:withdrawn)
            after
              60_000 -> Nebu.Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:row_held, holder_pid}, 10_000

      try do
        {_elapsed, blocked} = bounded("refresh behind a held device row", fn -> T.refresh(cid, s.rt) end)
        assert_503_retry(blocked, "refresh", "5")
      after
        send(holder_pid, :release)
        Task.await(holder, 10_000)
      end

      assert T.refresh!(cid, s.rt)["access_token"], "the refresh token was not consumed by the 503: it still rotates"
      assert T.lease_rows(s.user_id, s.device_id) == [], "the lease is released after the refresh"
    end

    test "OAuthSessionStore.claim_lease/4 returns {:error, :lock_timeout} within the bound and leaves no lease row", %{cid: cid, priv: priv} do
      s = session(cid, priv)

      {{elapsed, claim}, {:ok, _}} =
        with_revoke_hold(cid, fn ->
          bounded("claim_lease", fn -> OAuthSessionStore.claim_lease(s.user_id, s.device_id, "atdd-holder-" <> T.rand(8), 60) end)
        end)

      assert claim == {:error, :lock_timeout}, "the claim's lock timeout is a distinct, mapped outcome, got #{inspect(claim)}"
      assert elapsed < @bound_ms
      assert T.lease_rows(s.user_id, s.device_id) == []
    end
  end

  describe "AC1/AC6 — the lease release (D3 audit: a revoke cascade-deletes the lease row)" do
    test "release_lease/3 behind a held lease row returns {:error, :lock_timeout} within the bound; once free it releases", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      holder = "atdd-release-" <> T.rand(8)
      assert OAuthSessionStore.claim_lease(s.user_id, s.device_id, holder, 60) == :claimed
      parent = self()

      blocker =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [s.user_id, s.device_id])
            send(parent, {:lease_held, self()})

            receive do
              :release -> :ok
            after
              60_000 -> :ok
            end
          end)
        end)

      assert_receive {:lease_held, blocker_pid}, 10_000

      try do
        {elapsed, result} = bounded("release_lease", fn -> OAuthSessionStore.release_lease(s.user_id, s.device_id, holder) end)
        assert result == {:error, :lock_timeout}
        assert elapsed < @bound_ms
      after
        send(blocker_pid, :release)
        Task.await(blocker, 10_000)
      end

      assert OAuthSessionStore.release_lease(s.user_id, s.device_id, holder) == :ok
      assert T.lease_rows(s.user_id, s.device_id) == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — touch_last_seen and /sync never wait for the revoke
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — touch_last_seen / /sync while a revoke holds the devices rows" do
    test "touch_last_seen returns :ok at once without raising and without updating the locked row", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      reset_last_seen!(s)
      assert last_seen(s.user_id, s.device_id) == [nil, nil]

      {{elapsed, result}, {:ok, _}} =
        with_revoke_hold(cid, fn ->
          bounded("touch_last_seen", fn -> DeviceKeyStore.touch_last_seen(s.user_id, s.device_id, "203.0.113.7") end)
        end)

      assert result == :ok
      assert elapsed < @fast_ms, "a skipped update is immediate, not a lock-timeout or 15 s wait (#{elapsed} ms)"
    end

    test "the locked row is not updated by the skipped touch (last_seen_ts stays NULL while the rows are held)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      reset_last_seen!(s)

      {state, {:ok, _}} =
        with_revoke_hold(cid, fn ->
          {_elapsed, :ok} = bounded("touch_last_seen", fn -> DeviceKeyStore.touch_last_seen(s.user_id, s.device_id, "203.0.113.8") end)
          # the holder has NOT committed, so an update that WAITED would not be visible either: prove via the wait set
          T.sql!("SELECT pg_stat_clear_snapshot()")

          %{rows: [[waiting]]} =
            T.sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()")

          {last_seen(s.user_id, s.device_id), waiting}
        end)

      assert {[nil, nil], 0} = state, "no UPDATE may be parked on the locked row (no backend in a lock wait), the row is unchanged"
    end

    test "/sync of a device whose row is held answers 200 within its normal time (no 15 s wait)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      reset_last_seen!(s)

      {{elapsed, conn}, {:ok, _}} = with_revoke_hold(cid, fn -> bounded("/sync", fn -> T.sync(s.at) end) end)

      assert conn.status == 200, "/sync must not fail or wait for the revoke: #{conn.status} #{String.slice(conn.resp_body || "", 0, 160)}"
      assert elapsed < @fast_ms, "/sync took #{elapsed} ms behind the revoke (best-effort last-seen write must be skipped)"
    end

    test "an UNLOCKED device is still updated (the skip must not disable the throttled last-seen write)", %{cid: cid, priv: priv} do
      held = session(cid, priv)
      other_cid = T.oauth_client!([@other], client_uri: "https://other.example.com")
      free = T.session!(other_cid, @other, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      reset_last_seen!(free)

      {result, {:ok, _}} =
        with_revoke_hold(cid, fn ->
          assert held.user_id != free.user_id
          bounded("touch of an unlocked device", fn -> DeviceKeyStore.touch_last_seen(free.user_id, free.device_id, "203.0.113.9") end)
        end)

      assert {_elapsed, :ok} = result
      assert [ts, "203.0.113.9"] = last_seen(free.user_id, free.device_id)
      assert is_integer(ts), "last_seen_ts is written for a row nobody holds"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — pool health
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — pool health: more waiters than pool connections must not brown out the node" do
    test "12 parallel refreshes + /syncs of the held client (> pool size 10): an unrelated request still answers, all waiters end bounded, all connections return", %{cid: cid, priv: priv} do
      refreshers = for _ <- 1..6, do: session(cid, priv)
      syncers = for _ <- 1..6, do: session(cid, priv)
      Enum.each(syncers, &reset_last_seen!/1)
      T.idp_refresh_for(refreshers ++ syncers)

      other_cid = T.oauth_client!([@other], client_uri: "https://other.example.com")
      unrelated = T.session!(other_cid, @other, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})

      assert T.whoami(unrelated.at).status == 200, "precondition: the unrelated session works while nothing is held"

      {{who, waiters}, {:ok, %{devices: 12}}} =
        with_revoke_hold(cid, fn ->
          tasks =
            Enum.map(refreshers, fn s -> {:refresh, Task.async(fn -> timed(fn -> T.refresh(cid, s.rt) end) end)} end) ++
              Enum.map(syncers, fn s -> {:sync, Task.async(fn -> timed(fn -> T.sync(s.at) end) end)} end)

          # at least the 6 refreshes wait on the held rows (without the bound each would park a pool connection for the revoke's duration)
          wait_for_lock_waits(6)

          # while the waiters are bounded: an unrelated user is not starved (5 probes)
          probes = for i <- 1..5, do: bounded("unrelated /whoami probe #{i}", fn -> T.whoami(unrelated.at) end, 6_000)
          who = probes |> Enum.map(fn {e, c} -> {e, c.status} end)

          yielded = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), 12_000)

          results =
            Enum.zip(tasks, yielded)
            |> Enum.map(fn {{kind, t}, {_task, res}} ->
              case res || Task.shutdown(t, :brutal_kill) do
                {:ok, {elapsed, conn}} -> {kind, elapsed, conn}
                _ -> {kind, :still_blocked, nil}
              end
            end)

          {who, results}
        end)

      for {elapsed, status} <- who do
        assert status == 200, "an unrelated user's /whoami must answer 200 while the pool is under pressure, got #{status}"
        assert elapsed < 5_000, "an unrelated request answered only after #{elapsed} ms (pool exhausted by lock waiters)"
      end

      blocked = Enum.filter(waiters, fn {_kind, elapsed, _} -> elapsed == :still_blocked end)
      assert blocked == [], "#{length(blocked)} of 12 waiters were still blocked after 12 s (they wait for the revoke instead of failing fast)"

      for {kind, elapsed, conn} <- waiters do
        case kind do
          :refresh -> assert_503_retry(conn, "refresh (#{elapsed} ms)", "5")
          :sync -> assert conn.status == 200, "sync: #{conn.status}"
        end
      end

      # after the commit every connection is back: 20 parallel queries (> pool size) succeed, nothing idles in a transaction
      results = Task.async_stream(1..20, fn _ -> T.sql!("SELECT 1").num_rows end, max_concurrency: 20, timeout: 10_000) |> Enum.to_list()
      assert Enum.all?(results, &match?({:ok, 1}, &1)), "the pool serves 20 parallel queries after the revoke committed"

      T.sql!("SELECT pg_stat_clear_snapshot()")

      %{rows: [[stuck]]} =
        T.sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND (state LIKE 'idle in transaction%' OR wait_event_type = 'Lock')")

      assert stuck == 0, "no backend is left in a transaction or a lock wait"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Review cycle 1 (Kassandra M-1, L-2, L-3)
  # ════════════════════════════════════════════════════════════════════════════

  describe "M-1 — request-path teardowns behind a held revoke" do
    test "12 parallel revoke, logout and logout-all calls (> pool size) end bounded; the pool survives, the revoke completes", %{cid: cid, priv: priv} do
      revokers = for _ <- 1..5, do: session(cid, priv)
      loggers = for _ <- 1..4, do: session(cid, priv)
      alllog = for _ <- 1..3, do: session(cid, priv)

      other_cid = T.oauth_client!([@other], client_uri: "https://other.example.com")
      unrelated = T.session!(other_cid, @other, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      assert T.whoami(unrelated.at).status == 200

      {{who, results}, revoke_result} =
        with_revoke_hold(cid, fn ->
          tasks =
            Enum.map(revokers, fn s -> {:revoke, Task.async(fn -> timed(fn -> T.revoke(T.revoke_params(s.at)) end) end)} end) ++
              Enum.map(loggers, fn s -> {:logout, Task.async(fn -> timed(fn -> T.logout(s.at) end) end)} end) ++
              Enum.map(alllog, fn s -> {:logout_all, Task.async(fn -> timed(fn -> T.logout(s.at, path: :all) end) end)} end)

          wait_for_lock_waits(2)
          probes = for i <- 1..5, do: bounded("unrelated /whoami probe #{i}", fn -> T.whoami(unrelated.at) end, 6_000)
          who = Enum.map(probes, fn {e, c} -> {e, c.status} end)

          yielded = Task.yield_many(Enum.map(tasks, &elem(&1, 1)), 12_000)

          results =
            Enum.zip(tasks, yielded)
            |> Enum.map(fn {{kind, t}, {_task, res}} ->
              case res || Task.shutdown(t, :brutal_kill) do
                {:ok, {elapsed, conn}} -> {kind, elapsed, conn}
                _ -> {kind, :still_blocked, nil}
              end
            end)

          {who, results}
        end)

      # /logout/all also wipes the user's session rows (not device-locked) before it fails on the device lock, so the revoke may find fewer
      assert {:ok, %{devices: n}} = revoke_result, "the revoke's own unbounded teardown completes"
      assert n in 9..12

      for {elapsed, status} <- who do
        assert status == 200, "an unrelated user's /whoami must answer 200, got #{status}"
        assert elapsed < 5_000, "an unrelated request answered only after #{elapsed} ms (pool exhausted by teardown waiters)"
      end

      blocked = Enum.filter(results, fn {_k, elapsed, _} -> elapsed == :still_blocked end)
      assert blocked == [], "#{length(blocked)} of 12 teardown requests were still blocked after 12 s (they wait for the revoke)"

      for {kind, elapsed, conn} <- results do
        case kind do
          :revoke ->
            T.assert_revoke_5xx(conn, 503)
            assert T.header(conn, "retry-after") == "5", "/oauth2/revoke: Retry-After 5 (#{elapsed} ms)"

          _ ->
            assert conn.status in [500, 503], "#{kind}: a bounded failure, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 120)}"
        end
      end

      # the revoke's own teardown stayed unbounded and finished (devices: 12 above); the pool is whole again
      assert Task.async_stream(1..20, fn _ -> T.sql!("SELECT 1").num_rows end, max_concurrency: 20, timeout: 10_000) |> Enum.all?(&match?({:ok, 1}, &1))
    end

    test "end_device/4 behind a held row is bounded by default: {:error, :lock_timeout} within the bound, nothing deleted", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      before = T.rows_snapshot(s.user_id, s.device_id)

      {{elapsed, result, rows_during}, {:ok, _}} =
        with_revoke_hold(cid, fn ->
          {elapsed, result} = bounded("end_device", fn -> OAuthSessionStore.end_device(s.user_id, s.device_id) end)
          {elapsed, result, T.rows_snapshot(s.user_id, s.device_id)}
        end)

      assert result == {:error, :lock_timeout}
      assert elapsed < @bound_ms
      assert rows_during == before
    end
  end

  describe "L-2 / L-3 — skip locked siblings, no KEY SHARE conflict" do
    test "mark_access_token_used/1 returns :ok at once while a pending sibling is locked and expires it once free", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      new_at = T.refresh!(cid, s.rt)["access_token"]
      pending = fn -> T.sql!("SELECT count(*) FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NOT NULL AND grace_until IS NULL", [s.user_id, s.device_id]).rows end
      assert pending.() == [[1]], "precondition: the rotated-away row is pending"
      parent = self()

      holder =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NOT NULL FOR UPDATE", [s.user_id, s.device_id])
            send(parent, {:rows_held, self()})

            receive do
              :release -> :ok
            after
              60_000 -> :ok
            end
          end)
        end)

      assert_receive {:rows_held, holder_pid}, 10_000

      try do
        {elapsed, result} = bounded("mark_access_token_used", fn -> MatrixSessionStore.mark_access_token_used(new_at) end)
        assert result == :ok
        assert elapsed < @fast_ms, "skipping a locked sibling is immediate (#{elapsed} ms)"
      after
        send(holder_pid, :release)
        Task.await(holder, 10_000)
      end

      assert pending.() == [[1]], "the skipped sibling keeps its pending state"
      assert MatrixSessionStore.mark_access_token_used(new_at) == :ok
      assert pending.() == [[0]], "once the row is free the next request expires the grace window"
    end

    test "touch_last_seen/3 still updates a device row that only holds a KEY SHARE (a lease claim does not block it)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      reset_last_seen!(s)
      parent = self()

      holder =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR KEY SHARE", [s.user_id, s.device_id])
            send(parent, {:share_held, self()})

            receive do
              :release -> :ok
            after
              60_000 -> :ok
            end
          end)
        end)

      assert_receive {:share_held, holder_pid}, 10_000

      try do
        {_elapsed, :ok} = bounded("touch_last_seen", fn -> DeviceKeyStore.touch_last_seen(s.user_id, s.device_id, "203.0.113.11") end)
        assert [ts, "203.0.113.11"] = last_seen(s.user_id, s.device_id)
        assert is_integer(ts)
      after
        send(holder_pid, :release)
        Task.await(holder, 10_000)
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — unchanged behaviour (regression)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — off revalidation, a client without devices, an undisturbed per_refresh refresh" do
    test "oauth_idp_revalidation = off takes no lease and answers 503 + a Retry-After within the 300 ms bound of the client lock", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: :off})
      s = session(cid, priv)

      {{elapsed, conn}, {:ok, %{devices: 1}}} = with_revoke_hold(cid, fn -> bounded("refresh (off)", fn -> T.refresh(cid, s.rt) end) end)

      # unchanged behaviour: the client lock's own mapping (503 + a Retry-After, no `error` member)
      assert conn.status == 503, "refresh (off): expected 503, got #{conn.status}"
      assert T.header(conn, "retry-after") != nil
      refute Map.has_key?(T.json(conn), "error")
      assert elapsed < @bound_ms
      assert T.lease_rows(s.user_id, s.device_id) == [], "off never takes a lease"
    end

    test "a client without devices is revoked as before: {:ok, %{devices: 0}} and the status is revoked", %{priv: _priv} do
      empty = T.oauth_client!([@https])
      assert {:ok, %{devices: 0}} = revoke(empty)
      assert T.client_row(empty)["status"] == "revoked"
    end

    test "per_refresh without any revoke in flight: 200, the IdP is called once, the lease row is gone afterwards", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)

      body = T.refresh!(cid, s.rt)
      assert body["access_token"] && body["refresh_token"]
      assert_received {:idp_refresh, _}
      refute_received {:idp_refresh, _}
      assert T.lease_rows(s.user_id, s.device_id) == []
    end
  end
end
