defmodule Nebu.OAuth.OAuthRefreshLeaseTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3), AC12 / FR15 (gate n): the
  per-device IdP refresh LEASE that serializes the `per_refresh` re-validation of one device, so that
  two parallel `POST /oauth2/token` refreshes of one Nebu refresh token never redeem one IdP refresh
  token twice (a rotating IdP with reuse detection would revoke the grant and log the user out).

  ## Contract pinned here

    * table `oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until)`, PK
      `(user_id, device_id)` (migration 000045; `T.lease_rows/2`, `T.hold_lease!/3`, `T.expire_lease!/2`);
      the holder is a 128-bit hex value (32 chars), the TTL is at least 20 s and at most 120 s (60 s in the server); the lease
      is released (row DELETEd by holder) when the refresh finishes, on every path incl. a raising IdP call.
    * a follower polls every 100 ms for at most `:oauth_idp_lease_wait_ms` (app `:nebu_http`, test seam,
      default 5000) re-resolving the refresh token: a CHANGED active row => replay WITHOUT an IdP call;
      `{:reused, _}` while waiting => `503 {}` + `Retry-After: 2`, NEVER a revocation; budget exhausted =>
      `503 {}` + `Retry-After: 2`; a lease SQL error => `503 {}` + `Retry-After: 5`, the IdP is not called.
    * `oauth_idp_revalidation = off` takes no lease. An EXPIRED lease (a crashed holder) does not block:
      T28 (the IdP-400 race guard) remains for exactly that case.

  The IdP is the rotating stub with a barrier (`T.rotating_idp_with_barrier/3`): the first call with the
  stored IdP refresh token X blocks until the test releases it, then returns the rotated Y; every later
  call with X answers `{:token_endpoint_status, 400}` (what a rotating IdP says to the loser).

  No sleeps decide an outcome: a follower announces that it found the lease held (test seam
  `:oauth_idp_lease_wait_notify` = the test pid, message `{:lease_wait, follower_pid}`), and the test
  releases / changes the world only AFTER that message, so a test can neither pass vacuously (no lease was
  ever contended) nor fail under load (the follower started late).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    secret = Application.get_env(:nebu_http, :admin_secret_at_rest)

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_idp_lease_wait_ms)
      if secret, do: Application.put_env(:nebu_http, :admin_secret_at_rest, secret)
    end)

    cid = T.oauth_client!([@https], client_uri: "https://app.example.com")
    {:ok, priv: priv, cid: cid}
  end

  defp session(ctx, opts \\ []), do: T.session!(ctx.cid, @https, ctx.priv, opts)

  defp x_calls(idp, s), do: Enum.count(idp.calls.(), &(&1 == s.idp_rt))

  # Starts a FOLLOWER and returns its task once it has found the lease HELD (it announces itself, see the moduledoc).
  defp start_follower(ctx, s) do
    T.put_env_scoped(:oauth_idp_lease_wait_notify, self())
    t = Task.async(fn -> T.refresh(ctx.cid, s.rt) end)
    assert_receive {:lease_wait, _follower}, 10_000
    t
  end

  # Starts the HOLDER (blocked inside the IdP stub) and returns its task and the blocked process.
  defp start_holder(ctx, s) do
    t = Task.async(fn -> T.refresh(ctx.cid, s.rt) end)
    assert_receive {:idp_blocked, pid}, 10_000
    {t, pid}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12.1 — two parallel refreshes => ONE IdP call
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12.1 — two parallel refreshes of one Nebu refresh token" do
    test "ONE IdP redemption, both 200, the session alive, the final AT works, a later refresh succeeds", ctx do
      s = session(ctx)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)

      {t1, holder} = start_holder(ctx, s)
      t2 = start_follower(ctx, s)
      idp.release.(holder)
      [r1, r2] = Task.await_many([t1, t2], 30_000)

      assert [r1.status, r2.status] == [200, 200], "got #{r1.status} #{r1.resp_body} / #{r2.status} #{r2.resp_body}"
      assert x_calls(idp, s) == 1, "the IdP never sees two redemptions of one refresh token, calls: #{inspect(idp.calls.())}"

      b1 = T.assert_token_success(r1)
      b2 = T.assert_token_success(r2)
      assert [active] = T.active_rows(s.user_id, s.device_id), "exactly one active row per device"

      finals = Enum.filter([b1, b2], &(T.token_hash(&1["access_token"]) == active["access_token_hash"]))
      assert [final] = finals, "exactly one of the two responses is the active pair"
      assert T.whoami(final["access_token"]).status == 200

      # a later refresh through the NEW pair still works (the IdP was told the rotated token, not X)
      T.refresh!(ctx.cid, final["refresh_token"])
      refute s.idp_rt in tl(idp.calls.()), "no later call presented the rotated-away token X"
    end

    test "three parallel refreshes: never a 4xx, the IdP token X is redeemed once, the session survives", ctx do
      s = session(ctx)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)

      {t1, holder} = start_holder(ctx, s)
      followers = for _ <- 1..2, do: start_follower(ctx, s)
      idp.release.(holder)
      results = Task.await_many([t1 | followers], 30_000)

      for r <- results, do: assert(r.status in [200, 503], "a contended refresh is 200 or 503 {}, never #{r.status}: #{r.resp_body}")
      assert Enum.any?(results, &(&1.status == 200))
      assert x_calls(idp, s) == 1
      assert [_active] = T.active_rows(s.user_id, s.device_id), "the session is alive"
    end

    test "the lease is per DEVICE: a refresh of another device of the same user is not blocked", ctx do
      sub = T.unique_sub()
      a = session(ctx, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "LEASEDEVA1")})
      b = session(ctx, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "LEASEDEVB1")})
      idp = T.rotating_idp_with_barrier(sub, a.idp_rt)

      {t1, holder} = start_holder(ctx, a)
      other = T.refresh(ctx.cid, b.rt)
      assert other.status == 200, "device B must not wait for device A's lease (got #{other.status})"
      idp.release.(holder)
      assert Task.await(t1, 30_000).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12.2 — the bounded wait
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12.2 — a follower that cannot get the lease in time" do
    test "503 {} + Retry-After: 2 (never 429, never invalid_grant); the session survives; the retry after the release succeeds without a second redemption of X", ctx do
      T.put_env_scoped(:oauth_idp_lease_wait_ms, 200)
      s = session(ctx)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)

      {t1, holder} = start_holder(ctx, s)
      snap = T.rows_snapshot(s.user_id, s.device_id)

      conn = T.refresh(ctx.cid, s.rt)
      T.assert_token_5xx(conn)
      assert T.header(conn, "retry-after") == "2"
      assert conn.resp_body |> Jason.decode!() == %{}, "body exactly {} (an `error` member would log oidc-client-ts out)"
      refute conn.status == 429
      assert T.rows_snapshot(s.user_id, s.device_id) == snap, "the session is untouched by the timed-out follower"

      idp.release.(holder)
      assert Task.await(t1, 30_000).status == 200

      retry = T.refresh(ctx.cid, s.rt)
      assert retry.status == 200, "the retry after the release is served (replay of the pending token), got #{retry.status}: #{retry.resp_body}"
      assert x_calls(idp, s) == 1, "the retry never presents the rotated-away X to the IdP"
    end

    test "a follower that sees {:reused, _} while waiting (a third refresh used the successor) gets 503 and the session SURVIVES (never revocation)", ctx do
      T.put_env_scoped(:oauth_idp_lease_wait_ms, 3_000)
      s = session(ctx)
      T.idp_refresh_ok(s.sub)
      a = T.refresh!(ctx.cid, s.rt)
      # s.rt is now PENDING (rotated away, NOT yet consumed: the successor has not been used; its first use
      # on a protected endpoint, e.g. /whoami, would consume it)
      :ok = T.hold_lease!(s.user_id, s.device_id, 60)

      follower = start_follower(ctx, s)
      # the successor's use consumes the pending token: from now on s.rt is REUSED
      T.sql!("UPDATE matrix_sessions SET grace_until = now() WHERE refresh_token_hash = $1", [T.token_hash(s.rt)])

      conn = Task.await(follower, 30_000)
      T.assert_token_5xx(conn)
      assert T.header(conn, "retry-after") == "2"
      assert [_active] = T.active_rows(s.user_id, s.device_id), "the session must NOT be revoked by a waiting follower (oracle correction 5)"
      assert T.whoami(a["access_token"]).status == 200
    end

    test "a foreign LIVE lease and the wait budget exhausted => 503 {} + Retry-After: 2, no IdP call, nothing revoked", ctx do
      T.put_env_scoped(:oauth_idp_lease_wait_ms, 250)
      s = session(ctx)
      T.idp_refresh_ok(s.sub)
      :ok = T.hold_lease!(s.user_id, s.device_id, 60)
      snap = T.rows_snapshot(s.user_id, s.device_id)

      conn = T.refresh(ctx.cid, s.rt)
      T.assert_token_5xx(conn)
      assert T.header(conn, "retry-after") == "2"
      refute_received {:idp_refresh, _}
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      assert [%{"holder" => "atdd-foreign-" <> _}] = T.lease_rows(s.user_id, s.device_id), "the foreign lease is not touched by a timed-out follower"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12.3 — lease life cycle
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12.3 — the lease row" do
    test "while the holder is in the IdP call: ONE row, a 128-bit hex holder, 20 s <= TTL <= 120 s; released afterwards", ctx do
      s = session(ctx)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)
      {t1, holder} = start_holder(ctx, s)

      assert [row] = T.lease_rows(s.user_id, s.device_id)
      assert row["holder"] =~ ~r/\A[0-9a-f]{32}\z/
      %{rows: [[ttl]]} =
        T.sql!("SELECT extract(epoch FROM lease_until - acquired_at)::float8 FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2", [s.user_id, s.device_id])

      assert ttl >= 20 and ttl <= 120, "TTL = IdP HTTP timeout + 5 s, >= 20 s, CHECK <= 120 s, got #{ttl}"

      idp.release.(holder)
      assert Task.await(t1, 30_000).status == 200
      assert T.lease_rows(s.user_id, s.device_id) == [], "released when the refresh finished"
    end

    test "released on EVERY path: IdP 400 (revocation), transient IdP error, a raising IdP call", ctx do
      for {label, stub} <- [
            {"genuine rejection", fn -> T.idp_refresh_error({:token_endpoint_status, 400}) end},
            {"transient error", fn -> T.idp_refresh_error({:token_endpoint_unreachable, :econnrefused}) end},
            {"raising stub", fn -> T.stub_idp_refresh(fn _ -> raise "atdd injected IdP fault" end) end}
          ] do
        s = session(ctx)
        stub.()
        _ = capture_log(fn -> T.refresh(ctx.cid, s.rt) end)
        assert T.lease_rows(s.user_id, s.device_id) == [], "#{label}: the lease must be released"
      end
    end

    test "a genuine single IdP rejection still revokes (invalid_grant, every row gone)", ctx do
      s = session(ctx)
      T.idp_refresh_error({:token_endpoint_status, 400})
      T.refresh(ctx.cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "a transient IdP failure keeps the session and answers 503 {} (unchanged)", ctx do
      s = session(ctx)
      T.idp_refresh_error({:token_endpoint_status, 502})
      conn = T.refresh(ctx.cid, s.rt)
      T.assert_token_5xx(conn)
      assert [_] = T.active_rows(s.user_id, s.device_id)
    end

    test "an EXPIRED lease (a crashed holder) does not block: the refresh claims it and is served", ctx do
      s = session(ctx)
      T.idp_refresh_ok(s.sub)
      :ok = T.hold_lease!(s.user_id, s.device_id, 30)
      :ok = T.expire_lease!(s.user_id, s.device_id)

      assert T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      assert_received {:idp_refresh, rt}
      assert rt == s.idp_rt
      assert T.lease_rows(s.user_id, s.device_id) == [], "claimed and released"
    end

    test "a LIVE foreign lease is never taken over (the claim only replaces an expired lease)", ctx do
      T.put_env_scoped(:oauth_idp_lease_wait_ms, 200)
      s = session(ctx)
      T.idp_refresh_ok(s.sub)
      :ok = T.hold_lease!(s.user_id, s.device_id, 60)
      T.refresh(ctx.cid, s.rt) |> T.assert_token_5xx()
      assert [%{"holder" => "atdd-foreign-" <> _}] = T.lease_rows(s.user_id, s.device_id)
    end

    test "oauth_idp_revalidation = off takes NO lease: a foreign live lease does not block it", ctx do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      s = T.session!(ctx.cid, @https, ctx.priv)
      :ok = T.hold_lease!(s.user_id, s.device_id, 60)

      T.refresh(ctx.cid, s.rt) |> T.assert_token_success()
      assert [%{"holder" => "atdd-foreign-" <> _}] = T.lease_rows(s.user_id, s.device_id), "off never touches the lease table"
    end

    test "a device delete cascades the lease (FK ON DELETE CASCADE)", ctx do
      s = session(ctx)
      :ok = T.hold_lease!(s.user_id, s.device_id, 60)
      assert [_] = T.lease_rows(s.user_id, s.device_id)
      # the whole device goes (devices row, keys, sessions): `oauth_revoke_device_session/2` (T11) only deletes the
      # OAuth session rows and keeps the device, so the cascade is proven through the full teardown
      assert {:ok, :revoked, _} = Nebu.Matrix.oauth_revoke_token(s.rt)
      assert T.lease_rows(s.user_id, s.device_id) == []
    end

    test "a lease SQL error => 503 {} + Retry-After: 5, the IdP is NOT called, the session is intact", ctx do
      s = session(ctx)
      T.idp_refresh_ok(s.sub)
      _remove = T.block_lease_writes!(s.user_id)
      snap = T.rows_snapshot(s.user_id, s.device_id)

      log = capture_log(fn -> send(self(), {:resp, T.refresh(ctx.cid, s.rt)}) end)
      assert_received {:resp, conn}
      T.assert_token_5xx(conn)
      assert T.header(conn, "retry-after") == "5"
      refute_received {:idp_refresh, _}
      assert T.rows_snapshot(s.user_id, s.device_id) == snap
      refute log =~ s.rt
    end
  end

  describe "FR15 — no pool connection / transaction is held across the IdP call" do
    test "while the holder waits in the IdP call, a write to the device row is not blocked (no transaction is open across the IdP call)", ctx do
      s = session(ctx)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)
      {t1, holder} = start_holder(ctx, s)

      # no transaction is open on the device: a write to its devices row is not blocked
      assert %{num_rows: 1} = T.sql!("UPDATE devices SET updated_at = updated_at WHERE user_id = $1 AND device_id = $2", [s.user_id, s.device_id])
      assert [row] = T.lease_rows(s.user_id, s.device_id), "the lease is a plain table row (not an advisory / transaction lock)"
      assert row["holder"] =~ ~r/\A[0-9a-f]{32}\z/

      idp.release.(holder)
      assert Task.await(t1, 30_000).status == 200
    end
  end
end
