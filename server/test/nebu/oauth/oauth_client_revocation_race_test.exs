defmodule Nebu.OAuth.OAuthClientRevocationRaceTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `oauth-client-revocation` (P4), AC5: the race between
  `Nebu.OAuth.revoke_client/3` and token issuance / refresh rotation (CR5). The client row is locked `FOR SHARE`
  as the FIRST statement of `OAuthSessionStore.insert_replacing_device/1` and `rotate/1`; it conflicts with the
  revoke's status UPDATE, so either the issuance commits first and the revoke (a new statement, a new snapshot)
  tears the new session down, or the revoke commits first and the issuance re-reads `revoked` and rolls back
  (`:client_not_approved` => `400 invalid_grant`). One lock order (client -> devices -> sessions): no deadlock.

  ## Pinned test seams (compile-guarded for `MIX_ENV=test` like `:oauth_token_test_hook`)

    * `:nebu_http, :oauth_session_lock_hook` — 0-arity fun called by `OAuthSessionStore.insert_replacing_device/1`
      AND `rotate/1` IMMEDIATELY after the client `FOR SHARE` lock (inside the transaction, in the caller's process).
    * `:nebu_http, :oauth_client_revoke_hook` — 0-arity fun called by `ClientStore.revoke/3` inside its transaction
      right after step 1 (the status UPDATE), before the teardown and before the commit.

  Both hooks block the calling process on a message (`receive`), so every interleaving is deterministic and
  sleep-free; "the other side is blocked" is proven by polling `pg_stat_activity` for a backend that waits on a
  lock (bounded), never by a timeout alone.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @admin "@admin:test.local"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_session_lock_hook, :oauth_client_revoke_hook, :oauth_repo, :oauth_session_repo], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "RC" <> String.upcase(T.rand(4))
  defp revoke(cid), do: apply(Nebu.OAuth, :revoke_client, [cid, @admin, [reason: "race"]])

  defp client_sessions(cid), do: T.sql!("SELECT count(*) FROM matrix_sessions WHERE client_id = $1", [cid]).rows |> hd() |> hd()

  # Blocks the calling process until it receives `:release`; tells the test process it got there.
  defp blocking_hook(tag) do
    parent = self()

    fn ->
      send(parent, {tag, self()})

      receive do
        :release -> :ok
      after
        20_000 -> :ok
      end
    end
  end

  # Proves that the OTHER side really waits for the lock held by the hook (not merely that it is slow): some backend
  # of the test database is in a lock wait. Polls every 25 ms, at most 10 s, then the test fails.
  defp assert_blocked_on_lock(task) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    wait_for_lock_wait(deadline)
    assert Task.yield(task, 0) == nil, "the blocked side must still be waiting"
  end

  defp wait_for_lock_wait(deadline) do
    %{rows: [[waiting]]} =
      T.sql!("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()")

    cond do
      waiting > 0 -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("no backend is waiting for a lock: the other side was not blocked by the hook")
      true -> Process.sleep(25) && wait_for_lock_wait(deadline)
    end
  end

  defp device_scope(device_id), do: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}

  describe "AC5.1 — issuance holds the client lock while a revoke starts" do
    test "the revoke blocks; after the release the issuance commits and the revoke then tears that new session and device down", %{cid: cid, priv: priv} do
      d = dev()
      grant = T.flow_code!(cid, @https, priv, authorize: device_scope(d))
      T.put_env_scoped(:oauth_session_lock_hook, blocking_hook(:issuing))

      issue = Task.async(fn -> T.redeem(grant) end)
      assert_receive {:issuing, hook_pid}, 10_000

      rv = Task.async(fn -> revoke(cid) end)
      assert_blocked_on_lock(rv)
      assert T.client_row(cid)["status"] == "approved", "nothing is visible before the revoke's transaction ran"

      send(hook_pid, :release)
      issued = Task.await(issue, 20_000)
      assert issued.status == 200, "the issuance won the race: #{issued.resp_body}"
      at = T.json(issued)["access_token"]

      assert {:ok, %{devices: 1}} = Task.await(rv, 20_000), "the revoke's teardown statement sees the session the issuance committed"
      assert client_sessions(cid) == 0
      assert T.device_gone?(grant.user_id, d)
      assert T.client_row(cid)["status"] == "revoked"
      T.assert_unknown_token(T.whoami(at), false)
    end
  end

  describe "AC5.2 — the revoke holds the client row while a code grant arrives" do
    test "the issuance blocks on FOR SHARE; after the release => 400 invalid_grant, the code stays used, 0 sessions", %{cid: cid, priv: priv} do
      d = dev()
      grant = T.flow_code!(cid, @https, priv, authorize: device_scope(d))
      T.put_env_scoped(:oauth_client_revoke_hook, blocking_hook(:revoking))

      rv = Task.async(fn -> revoke(cid) end)
      assert_receive {:revoking, hook_pid}, 10_000

      # the token endpoint still reads `approved` (the revoke is uncommitted), consumes the code and then waits for the lock
      issue = Task.async(fn -> T.redeem(grant) end)
      assert_blocked_on_lock(issue)

      send(hook_pid, :release)
      assert {:ok, %{devices: 0}} = Task.await(rv, 20_000)
      conn = Task.await(issue, 20_000)
      T.assert_token_error(conn, 400, "invalid_grant")

      assert Enum.all?(T.rows_for("oauth_codes", cid), &(&1["used_at"] != nil)), "the code is used and never redeemable again"
      assert client_sessions(cid) == 0
      assert T.device_gone?(grant.user_id, d)
      assert T.client_row(cid)["status"] == "revoked"
    end
  end

  describe "AC5.3 — the revoke holds the client row while a refresh rotation arrives" do
    test "the rotation blocks; after the release => 400 invalid_grant, 0 sessions, the device is gone", %{cid: cid, priv: priv} do
      d = dev()
      s = T.session!(cid, @https, priv, authorize: device_scope(d))
      T.idp_refresh_for([s])
      T.put_env_scoped(:oauth_client_revoke_hook, blocking_hook(:revoking))

      rv = Task.async(fn -> revoke(cid) end)
      assert_receive {:revoking, hook_pid}, 10_000

      rotate = Task.async(fn -> T.refresh(cid, s.rt) end)
      assert_blocked_on_lock(rotate)

      send(hook_pid, :release)
      assert {:ok, %{devices: 1}} = Task.await(rv, 20_000)
      T.assert_token_error(Task.await(rotate, 20_000), 400, "invalid_grant")

      assert client_sessions(cid) == 0
      assert T.device_gone?(s.user_id, d)
      T.assert_unknown_token(T.whoami(s.at), false)
    end
  end

  describe "AC5.4 — parallel token requests and one revoke (no hook)" do
    test "20 requests (14 code grants + 6 refreshes) + 1 revoke: 0 sessions at the end, only legitimate answers, no deadlock", %{cid: cid, priv: priv} do
      grants = for i <- 1..14, do: T.flow_code!(cid, @https, priv, authorize: device_scope("PG" <> Integer.to_string(i)))
      sessions = for i <- 1..6, do: T.session!(cid, @https, priv, authorize: device_scope("PR" <> Integer.to_string(i)))
      T.idp_refresh_for(sessions)

      tasks =
        Enum.map(grants, fn g -> {:code, Task.async(fn -> T.redeem(g) end)} end) ++
          Enum.map(sessions, fn s -> {:refresh, Task.async(fn -> T.refresh(cid, s.rt) end)} end)

      rv = Task.async(fn -> revoke(cid) end)

      results = Enum.map(tasks, fn {kind, t} -> {kind, Task.await(t, 30_000)} end)
      assert {:ok, %{devices: _}} = Task.await(rv, 30_000), "the revoke completes (no deadlock, no :race)"

      for {kind, conn} <- results do
        case conn.status do
          200 ->
            # issued before the revoke committed: the revoke's teardown must have deleted it
            assert T.json(conn)["access_token"] |> T.whoami() |> Map.fetch!(:status) == 401, "#{kind}: a 200 answer must be dead after the revoke"

          400 ->
            T.assert_token_error(conn, 400, "invalid_grant")

          401 ->
            T.assert_token_error(conn, 401, "invalid_client")

          other ->
            flunk("#{kind}: unexpected answer #{other}: #{String.slice(conn.resp_body || "", 0, 200)}")
        end
      end

      assert client_sessions(cid) == 0, "no session of the revoked client survives, whatever the interleaving"
      assert T.client_row(cid)["status"] == "revoked"

      for %{user_id: uid, device_id: did} <- grants ++ sessions, do: assert(T.device_gone?(uid, did), "device #{did} is gone")
    end
  end

  describe "AC5.5 — a long revoke must not park every token request of the client (review cycle 1, Kassandra M-2)" do
    test "a refresh and a code grant answer 503 + Retry-After within the 2 s lock bound while a revoke holds the row", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv, authorize: device_scope(dev()))
      T.idp_refresh_for([s])
      grant = T.flow_code!(cid, @https, priv, authorize: device_scope(dev()))
      T.put_env_scoped(:oauth_client_revoke_hook, blocking_hook(:revoking))

      rv = Task.async(fn -> revoke(cid) end)
      assert_receive {:revoking, hook_pid}, 10_000

      started = System.monotonic_time(:millisecond)
      refresh = T.refresh(cid, s.rt)
      redeem = T.redeem(grant)
      elapsed = System.monotonic_time(:millisecond) - started

      for {label, conn} <- [refresh: refresh, code: redeem] do
        assert conn.status == 503, "#{label}: expected 503, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 120)}"
        assert T.header(conn, "retry-after") != nil, "#{label}: Retry-After"
        refute Map.has_key?(T.json(conn), "error"), "#{label}: the 503 has no `error` member (the client retries, it does not log out)"
      end

      assert elapsed < 12_000, "bounded by the lock timeout (2 s each), not by the revoke (#{elapsed} ms)"

      send(hook_pid, :release)
      assert {:ok, %{devices: 1}} = Task.await(rv, 20_000)
      assert client_sessions(cid) == 0
    end
  end
end
