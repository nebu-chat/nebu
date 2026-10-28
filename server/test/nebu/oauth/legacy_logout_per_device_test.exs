defmodule Nebu.OAuth.LegacyLogoutPerDeviceTest do
  @moduledoc """
  Acceptance tests for the bugfix `legacy-logout-per-device` (epic oauth-broker, gate item r,
  follow-up x), AC1-AC8 and AC10 (LL1-LL12):

    * legacy `POST /_matrix/client/v3/logout` (opaque token, raw IdP JWT bound or unbound) ends ONLY the
      presented credential's device (every session row, the device, device / one-time / fallback keys,
      the JWT bindings) with the locked teardown of `/oauth2/revoke` and the OAuth `/logout`; it never
      touches another device (of ANY `auth_api`) and never runs the user-wide `invalidate_user_sessions`;
    * a storage failure is `500 M_UNKNOWN` with nothing half-done (the old best-effort `200` is gone);
    * under the devices-row lock the presented credential is RE-CHECKED (an OAuth take-over or a
      concurrent logout wins: nothing is deleted, `200 {}`), a bound JWT is denylisted CHECKED also then;
    * legacy `/refresh` (`MatrixSessionStore.rotate_tokens/1`) takes the devices lock first (gate x);
    * log hygiene: one INFO `legacy logout` line per call (`kind=`, `outcome=`), no secret.

  `/logout/all`, deactivation, device deletion and the OAuth `/logout` stay as they are (AC9: the
  existing tests in `oauth_logout_test.exs` and `oauth_device_teardown_test.exs`).

  Contracts pinned here (the implementation MUST honour them, story Decisions LL1-LL12):

    * facade `Nebu.Matrix.legacy_logout_device/1` taking `%{kind: :opaque | :jwt, token:, user_id:,
      device_id:}` and returning `{:ok, :ended} | {:ok, :unknown} | {:error, :unavailable}`, never raising;
      it honours the `:oauth_session_repo` seam (NoSuchRepo => `{:error, :unavailable}`);
    * answers: `200 {}` for `:ended` / `:unknown`, `500 M_UNKNOWN` (opaque: "Logout failed, please try
      again.") otherwise; INFO line `legacy logout ... kind=opaque|jwt_bound|jwt_unbound
      outcome=ended|unknown|failed` with `user_id=` / `device_id=`.

  Before the fix the legacy `/logout` was the user-wide wipe (OAuth devices of the user orphaned, the caller's own
  device and keys kept, a storage failure a silent `200`), and `rotate_tokens/1` took no devices lock.
  Review cycle 1 (Kassandra L1-L3): a device-less session is locked by its rows, the unbound JWT path re-reads the
  binding uncached and fails closed, the log line is a static message with Logger metadata.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  @env_keys [:oauth_repo, :oauth_session_repo, :uia_fresh_auth_seconds]

  setup do
    prior = for k <- @env_keys, into: %{}, do: {k, Application.fetch_env(:nebu_http, k)}
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()

      for {k, v} <- prior do
        case v do
          {:ok, value} -> Application.put_env(:nebu_http, k, value)
          :error -> Application.delete_env(:nebu_http, k)
        end
      end
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  # ── fixtures and helpers ────────────────────────────────────────────────────

  defp dev, do: "LL" <> String.upcase(T.rand(4))

  defp oauth_on(cid, priv, device_id, opts),
    do: T.session!(cid, @https, priv, Keyword.merge([authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}], opts))

  # A legacy opaque session WITH an (encrypted) IdP refresh token so `POST /refresh` can re-validate.
  defp legacy_on(uid, device_id),
    do: T.legacy_session!(uid, device_id, oidc_refresh_token: Nebu.Web.SecretBox.encrypt("legacy-idp-rt-" <> T.rand(6)))

  # User U with an OAuth device O and a legacy opaque device L (keys seeded for both, cross-signing key,
  # a stranger with a legacy session to query keys / devices).
  defp fixture(cid, priv) do
    o = oauth_on(cid, priv, dev(), [])
    uid = o.user_id
    l_dev = dev()
    l = legacy_on(uid, l_dev)
    for d <- [o.device_id, l_dev], do: T.seed_device_keys!(uid, d)
    # the per-device legacy `sessions` / `sync_tokens` rows the OLD user-wide wipe removed for EVERY device (review M1)
    for d <- [o.device_id, l_dev], do: T.seed_legacy_session_rows!(uid, d)
    T.seed_cross_signing!(uid)
    s_uid = T.provision_user!()
    stranger = s_uid |> T.legacy_session!(dev()) |> Map.put(:uid, s_uid)
    %{uid: uid, sub: o.sub, o: o, l: l, l_dev: l_dev, stranger: stranger}
  end

  # Everything a logout may touch for `uids`: sessions, device tables, bindings AND the legacy `sessions` /
  # `sync_tokens` rows (an implementation that also runs the user-wide `destroy_session(user)` must fail).
  defp world(uids), do: {T.world_snapshot(uids), T.legacy_session_state(uids)}

  defp legacy_rows(uid, d), do: T.legacy_session_state([uid]) |> Map.new(fn {k, rows} -> {k, Enum.filter(rows, &(Enum.at(&1, 1) == d))} end)

  defp o_state(f),
    do: {T.rows_snapshot(f.uid, f.o.device_id), T.device_state(f.uid, f.o.device_id), T.device_fingerprint(f.uid, f.o.device_id), legacy_rows(f.uid, f.o.device_id)}

  defp keys_query(token, uid) do
    conn = T.matrix_request(:post, "/_matrix/client/v3/keys/query", token, body: %{"device_keys" => %{uid => []}})
    assert conn.status == 200
    get_in(T.json(conn), ["device_keys", uid]) || %{}
  end

  defp listed_devices(token) do
    conn = T.matrix_request(:get, "/_matrix/client/v3/devices", token)
    assert conn.status == 200
    for d <- T.json(conn)["devices"], do: d["device_id"]
  end

  # 401 M_UNKNOWN_TOKEN and NO `soft_logout: true` (oracle O4: absent or false).
  defp assert_dead(conn) do
    assert conn.status == 401, "expected 401 M_UNKNOWN_TOKEN, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    body = T.json(conn)
    assert body["errcode"] == "M_UNKNOWN_TOKEN", "got #{inspect(body)}"
    refute body["soft_logout"] == true, "a destroyed session never asks for a soft logout: #{inspect(body)}"
    conn
  end

  defp assert_500_unknown(conn) do
    assert conn.status == 500, "expected 500 M_UNKNOWN, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    body = T.json(conn)
    assert body["errcode"] == "M_UNKNOWN"
    assert is_binary(body["error"]) and body["error"] != ""
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}i
    conn
  end

  defp facade(map), do: apply(Nebu.Matrix, :legacy_logout_device, [map])

  # Holds the devices-row lock of (uid, d) in a transaction, runs every fun of `funs` in its own Task, proves that
  # EVERY one of them waits for that lock (bounded poll of `pg_stat_activity` for as many backends in a lock wait on
  # a `FROM devices` statement, then none has finished: review M2), runs `in_txn` (still holding the lock) and
  # returns the Task results after the commit.
  defp hold_lock(uid, d, funs, in_txn \\ fn -> :ok end) do
    {:ok, tasks} =
      Nebu.Repo.transaction(fn ->
        T.sql!("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [uid, d])
        tasks = Enum.map(funs, fn f -> Task.async(fn -> T.safely(f) end) end)

        wait_for_lock_waiters(length(tasks), System.monotonic_time(:millisecond) + 10_000)

        for t <- tasks do
          early = Task.yield(t, 100)
          assert early == nil, "the call must wait for the devices row lock, got #{inspect(early)}"
        end

        in_txn.()
        tasks
      end)

    Enum.map(tasks, fn t ->
      case Task.yield(t, 10_000) || Task.shutdown(t, :brutal_kill) do
        {:ok, result} -> result
        other -> {:no_result, other}
      end
    end)
  end

  # `pg_stat_activity` is snapshotted per transaction (stats_fetch_consistency): this poll runs INSIDE the lock-holding
  # transaction, so the snapshot is cleared before every read.
  defp wait_for_lock_waiters(n, deadline, pattern \\ "%FROM devices%") do
    T.sql!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[waiting]]} =
      T.sql!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' " <>
          "AND pid <> pg_backend_pid() AND query LIKE '#{pattern}'"
      )

    cond do
      waiting >= n -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("expected #{n} backend(s) waiting for the devices-row lock, saw #{waiting}")
      true -> Process.sleep(25) && wait_for_lock_waiters(n, deadline, pattern)
    end
  end

  # A Task result that is not a conn (`{:raised, mod}`, `{:exit, _}`, `{:no_result, _}`) fails HERE with its reason
  # instead of a KeyError in the next assertion (review m9).
  defp conn!(result) do
    assert %Plug.Conn{} = result, "the request did not complete: #{inspect(result)}"
    result
  end

  # The effect of `insert_replacing_device/1` (T7 take-over) done by SQL INSIDE the lock-holding transaction:
  # the OAuth row for device `d` is inserted as a copy of `template` (an OAuth row of the same user); `replace?`
  # first deletes every existing row of the device (a legacy device taken over), otherwise they are left in place
  # (the bound-JWT device has no session row; the binding row stays, like after a best-effort kill-switch failure).
  defp take_over!(template, uid, d, new_at, new_rt, replace? \\ true) do
    if replace?, do: T.sql!("DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [uid, d])

    T.sql!(
      "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, " <>
        "session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at) " <>
        "VALUES ($1, $2, $3, $4, $5, LEAST(now() + interval '900 seconds', $6::timestamptz), $6::timestamptz, $7, 'oauth', $8, $9, $10, now())",
      [T.token_hash(new_at), T.token_hash(new_rt), template["oidc_refresh_token"], uid, d, template["session_expires_at"],
       template["auth_time"], template["client_id"], template["scope"], template["oauth_code_hash"]]
    )

    :ok
  end

  # Runs `fun` with the Logger at :debug (restored afterwards) and returns `{log, result}` (captured lines of every
  # process, e.g. the Tasks of `hold_lock/4`).
  defp logged(fun) do
    original = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        capture_log([level: :debug, format: "[$level] $message $metadata\n", metadata: [:user_id, :device_id, :kind, :outcome]], fn ->
          send(self(), {:result, fun.()})
        end)

      assert_received {:result, result}
      {log, result}
    after
      Logger.configure(level: original)
    end
  end

  # Only the INFO lines: a WARNING on a storage failure may contain the phrase as well (review m3).
  defp logout_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[info]" and &1 =~ "legacy logout"))

  defp assert_one_line(log, kind, outcome, uid, did) do
    assert [line] = logout_lines(log), "exactly one INFO `legacy logout` line expected, got: #{inspect(logout_lines(log))}"
    assert line =~ ~r/^.*\[info\] legacy logout user_id=/, "a STATIC message followed by the metadata (Kassandra L3)"
    assert line =~ "kind=#{kind} "
    assert line =~ "outcome=#{outcome}"
    assert line =~ "user_id=#{uid}"
    if did, do: assert(line =~ "device_id=#{did} ")
    line
  end

  defp bound_fixture(cid, priv) do
    sub = T.unique_sub()
    uid = T.provision_user!(sub)
    o = oauth_on(cid, priv, dev(), sub: sub)
    j_dev = dev()
    jwt = T.bound_jwt!(priv, sub, j_dev)
    for d <- [o.device_id, j_dev], do: T.seed_device_keys!(uid, d)
    for d <- [o.device_id, j_dev], do: T.seed_legacy_session_rows!(uid, d)
    T.seed_cross_signing!(uid)
    %{sub: sub, uid: uid, o: o, j_dev: j_dev, jwt: jwt}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 / LL1, LL2 — two devices: the legacy one logs out, the OAuth one survives
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — legacy opaque logout ends ONLY its own device (gate r core)" do
    test "200 {}; session rows, device and ALL keys of L gone; O untouched and still refreshing", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      o_before = o_state(f)
      assert Map.has_key?(keys_query(f.stranger.at, f.uid), f.l_dev), "precondition: L is visible to a peer"
      assert f.l_dev in listed_devices(f.o.at), "precondition: L is listed"

      T.logout(f.l.at) |> T.assert_logout_ok()

      assert T.session_rows(f.uid, f.l_dev) == []
      assert T.device_gone?(f.uid, f.l_dev), "device + device / one-time / fallback keys of L: #{inspect(T.device_state(f.uid, f.l_dev))}"
      assert legacy_rows(f.uid, f.l_dev) == %{sessions: [], sync_tokens: []}, "the per-device legacy sessions / sync_tokens rows of L go after the commit"
      refute Map.has_key?(keys_query(f.stranger.at, f.uid), f.l_dev), "a peer's /keys/query no longer returns L"
      refute f.l_dev in listed_devices(f.o.at), "GET /devices (with O's token) no longer lists L"

      assert o_state(f) == o_before, "O's rows and device state are untouched (never the user-wide wipe)"
      who = T.whoami(f.o.at)
      assert who.status == 200
      assert T.json(who)["device_id"] == f.o.device_id
      T.idp_refresh_ok(f.sub)
      assert %{"access_token" => _} = T.refresh!(cid, f.o.rt)

      assert T.cross_signing_count(f.uid) == 1, "cross-signing keys (per user) stay"
      assert T.whoami(f.stranger.at).status == 200
    end

    test "LL1: a body / query naming ANOTHER device or user is ignored (opaque): only the credential's own device ends", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      o_before = o_state(f)
      stranger_before = T.world_snapshot([f.stranger.uid])

      body = %{"device_id" => f.o.device_id, "user_id" => f.stranger.uid}
      path = "/_matrix/client/v3/logout?device_id=#{f.o.device_id}&user_id=#{URI.encode_www_form(f.stranger.uid)}"
      T.matrix_request(:post, path, f.l.at, body: body) |> T.assert_logout_ok()

      assert T.device_gone?(f.uid, f.l_dev)
      assert o_state(f) == o_before, "the device named in the request is not touched"
      assert T.world_snapshot([f.stranger.uid]) == stranger_before
      assert T.whoami(f.o.at).status == 200
    end

    test "every row of the device goes: pending sibling and a second legacy row",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)
      rotated = T.legacy_refresh(f.l.rt)
      assert rotated.status == 200, "precondition: legacy refresh works, got #{rotated.status}: #{rotated.resp_body}"
      fresh = T.json(rotated)
      extra = legacy_on(f.uid, f.l_dev)
      assert length(T.session_rows(f.uid, f.l_dev)) >= 3

      T.logout(fresh["access_token"]) |> T.assert_logout_ok()

      assert T.session_rows(f.uid, f.l_dev) == [], "LL2: pending / consumed siblings and any other legacy row of the device die too"
      for t <- [f.l.at, extra.at, fresh["access_token"]], do: assert_dead(T.whoami(t))
      assert T.device_gone?(f.uid, f.l_dev)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — OAuth logs out, legacy survives (story-4 regression, must stay green)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — OAuth logout ends ONLY its own device; the legacy device keeps working" do
    test "O gone (R15); L rows, device, keys unchanged; L's token works and L's legacy /refresh succeeds", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      l_before = {T.rows_snapshot(f.uid, f.l_dev), T.device_state(f.uid, f.l_dev), T.device_fingerprint(f.uid, f.l_dev), legacy_rows(f.uid, f.l_dev)}

      T.logout(f.o.at) |> T.assert_logout_ok()

      assert T.session_rows(f.uid, f.o.device_id) == []
      assert T.device_gone?(f.uid, f.o.device_id)
      assert {T.rows_snapshot(f.uid, f.l_dev), T.device_state(f.uid, f.l_dev), T.device_fingerprint(f.uid, f.l_dev), legacy_rows(f.uid, f.l_dev)} == l_before
      assert T.whoami(f.l.at).status == 200
      T.idp_refresh_ok(f.sub)
      refresh = T.legacy_refresh(f.l.rt)
      assert refresh.status == 200, "legacy /refresh still works, got #{refresh.status}: #{refresh.resp_body}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — replay and refresh after the logout
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — replay and refresh after the logout" do
    test "after the legacy logout: AT on whoami and /logout, the RT on /refresh => 401 M_UNKNOWN_TOKEN (no soft_logout)",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.logout(f.l.at) |> T.assert_logout_ok()

      assert_dead(T.whoami(f.l.at))
      assert_dead(T.logout(f.l.at))
      T.idp_refresh_ok(f.sub)
      assert_dead(T.legacy_refresh(f.l.rt))
    end

    test "a pending (rotated-away) refresh token from before the logout is dead too", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)
      rotated = T.legacy_refresh(f.l.rt)
      assert rotated.status == 200
      fresh = T.json(rotated)

      T.logout(fresh["access_token"]) |> T.assert_logout_ok()

      assert_dead(T.legacy_refresh(f.l.rt))
      assert_dead(T.legacy_refresh(fresh["refresh_token"]))
      assert_dead(T.whoami(f.l.at))
    end

    test "after the OAuth logout (R20): AT 401 without soft_logout, /oauth2/token invalid_grant", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.logout(f.o.at) |> T.assert_logout_ok()

      assert_dead(T.whoami(f.o.at))
      T.refresh(cid, f.o.rt) |> T.assert_token_error(400, "invalid_grant")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — two legacy devices of one user + an unrelated user
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — two legacy devices" do
    test "logout of L1 ends only (U, L1); L2 of the same user and the device of another user are unchanged" do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      [d1, d2, dv] = [dev(), dev(), dev()]
      l1 = legacy_on(uid, d1)
      l2 = legacy_on(uid, d2)
      v_uid = T.provision_user!()
      v = T.legacy_session!(v_uid, dv)
      for d <- [d1, d2], do: T.seed_device_keys!(uid, d)
      for d <- [d1, d2], do: T.seed_legacy_session_rows!(uid, d)
      T.seed_device_keys!(v_uid, dv)
      T.seed_legacy_session_rows!(v_uid, dv)
      keep = {T.rows_snapshot(uid, d2), T.device_state(uid, d2), T.device_fingerprint(uid, d2), legacy_rows(uid, d2)}
      v_before = world([v_uid])

      T.logout(l1.at) |> T.assert_logout_ok()

      assert T.session_rows(uid, d1) == []
      assert T.device_gone?(uid, d1)
      assert legacy_rows(uid, d1) == %{sessions: [], sync_tokens: []}
      assert {T.rows_snapshot(uid, d2), T.device_state(uid, d2), T.device_fingerprint(uid, d2), legacy_rows(uid, d2)} == keep
      assert T.whoami(l2.at).status == 200
      assert world([v_uid]) == v_before
      assert T.whoami(v.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — raw IdP JWT bound to a device (LL4)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5 — bound raw IdP JWT" do
    test "200 {}; device and bindings of J gone; both JWTs dead cluster-wide; O untouched",
         %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      jwt2 = T.bound_jwt!(priv, f.sub, f.j_dev)
      o_before = o_state(f)
      assert T.whoami(f.jwt).status == 200
      assert T.binding_exists?(f.jwt)

      T.logout(f.jwt) |> T.assert_logout_ok()

      assert T.device_gone?(f.uid, f.j_dev)
      assert legacy_rows(f.uid, f.j_dev) == %{sessions: [], sync_tokens: []}
      assert T.binding_rows(f.uid, f.j_dev) == 0
      assert_dead(T.whoami(f.jwt))
      T.forget_node_local_jwt_state!(f.jwt)
      assert_dead(T.whoami(f.jwt))

      T.forget_node_local_jwt_state!(jwt2)
      assert_dead(T.whoami(jwt2))

      assert o_state(f) == o_before
      assert T.whoami(f.o.at).status == 200
      assert T.cross_signing_count(f.uid) == 1
    end

    test "LL1: a body / query naming ANOTHER device is ignored (bound JWT): only the bound device ends", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      o_before = o_state(f)

      path = "/_matrix/client/v3/logout?device_id=#{f.o.device_id}"
      T.matrix_request(:post, path, f.jwt, body: %{"device_id" => f.o.device_id, "user_id" => f.uid}) |> T.assert_logout_ok()

      assert T.device_gone?(f.uid, f.j_dev)
      assert o_state(f) == o_before
      assert T.whoami(f.o.at).status == 200
    end

    test "the JWT is on the DATABASE denylist (jti key) after the logout", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      T.logout(f.jwt) |> T.assert_logout_ok()
      assert T.denylist_db_count("jti:" <> T.jwt_jti(f.jwt)) == 1, "LL4: the explicit CHECKED denylist write (cluster wide)"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — unbound raw IdP JWT (LL5): only the JWT is denylisted
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6 — unbound raw IdP JWT" do
    test "200 {}; the JWT is dead everywhere; every row and device of U is unchanged", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      o = oauth_on(cid, priv, dev(), sub: sub)
      l_dev = dev()
      l = T.legacy_session!(uid, l_dev)
      for d <- [o.device_id, l_dev], do: T.seed_device_keys!(uid, d)
      for d <- [o.device_id, l_dev], do: T.seed_legacy_session_rows!(uid, d)
      unbound = T.unbound_jwt!(priv, sub)
      assert T.whoami(unbound).status == 200, "precondition: the unbound JWT authenticates (C14)"
      before = world([uid])

      {log, conn} = logged(fn -> T.logout(unbound) end)
      T.assert_logout_ok(conn)
      assert_one_line(log, "jwt_unbound", "ended", uid, nil)

      assert_dead(T.whoami(unbound))
      T.forget_node_local_jwt_state!(unbound)
      assert_dead(T.whoami(unbound))
      assert world([uid]) == before, "LL5: no other device, no user-wide wipe"
      assert T.whoami(o.at).status == 200
      assert T.whoami(l.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — failures are reported, nothing half-done (LL4-LL6, LL8)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7.1 — opaque legacy: a storage failure => 500 M_UNKNOWN, rolled back, the retry works" do
    for mode <- [:repo, :session_delete, :device_delete, :key_delete, :otk_delete, :fallback_delete] do
      test "failure #{mode}", %{cid: cid, priv: priv} do
        f = fixture(cid, priv)
        before = world([f.uid])

        remove =
          case unquote(mode) do
            :repo ->
              T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
              fn -> Application.delete_env(:nebu_http, :oauth_session_repo) end

            :session_delete ->
              T.block_session_deletes!(f.uid, auth_api: "legacy")

            :device_delete ->
              T.block_deletes!("devices", f.uid)

            :key_delete ->
              T.block_deletes!("device_keys", f.uid)

            :otk_delete ->
              T.block_deletes!("device_one_time_keys", f.uid)

            :fallback_delete ->
              T.block_deletes!("device_fallback_keys", f.uid)
          end

        {log, conn} = logged(fn -> T.logout(f.l.at) end)
        assert_500_unknown(conn)
        assert T.json(conn)["error"] == "Logout failed, please try again."
        assert_one_line(log, "opaque", "failed", f.uid, f.l_dev)

        remove.()
        assert world([f.uid]) == before, "rolled back: session row, device and keys are all still there"
        assert T.whoami(f.l.at).status == 200, "the token still works"
        assert T.whoami(f.o.at).status == 200

        T.logout(f.l.at) |> T.assert_logout_ok()
        assert T.device_gone?(f.uid, f.l_dev)
        assert T.session_rows(f.uid, f.l_dev) == []
      end
    end
  end

  describe "AC7.2 — bound JWT" do
    for table <- ["device_keys", "devices", "device_one_time_keys", "device_fallback_keys"] do
      test "teardown blocked on #{table} => 500, all intact, JWT works and is not denylisted; retry 200",
           %{cid: cid, priv: priv} do
        f = bound_fixture(cid, priv)
        before = world([f.uid])
        remove = T.block_deletes!(unquote(table), f.uid)

        {log, conn} = logged(fn -> T.logout(f.jwt) end)
        assert_500_unknown(conn)
        assert_one_line(log, "jwt_bound", "failed", f.uid, f.j_dev)

        assert world([f.uid]) == before
        assert T.binding_exists?(f.jwt)
        assert T.whoami(f.jwt).status == 200, "LL4: the teardown runs BEFORE the denylist, a failure leaves the JWT alive"
        assert T.denylist_db_count("jti:" <> T.jwt_jti(f.jwt)) == 0, "LL4: no explicit denylist write after a failed teardown"
        assert T.denylist_db_count(Nebu.Matrix.Session.DeviceBinding.hash(f.jwt)) == 0

        remove.()
        T.logout(f.jwt) |> T.assert_logout_ok()
        assert T.device_gone?(f.uid, f.j_dev)
        assert_dead(T.whoami(f.jwt))
      end
    end

    test "denylist write blocked after the teardown => 500, device gone, JWT dead here", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      _remove = T.fail_denylist_key!("jti:" <> T.jwt_jti(f.jwt))

      {log, conn} = logged(fn -> T.logout(f.jwt) end)
      assert_500_unknown(conn)
      assert_one_line(log, "jwt_bound", "failed", f.uid, f.j_dev)

      assert T.device_gone?(f.uid, f.j_dev), "the teardown committed"
      assert_dead(T.whoami(f.jwt))
      assert T.whoami(f.o.at).status == 200
    end

    test "the post-commit kill-switch fails (hash key blocked): the committed teardown and the jti key still answer 200, the JWT is dead everywhere",
         %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      _remove = T.fail_denylist_db!(Nebu.Matrix.Session.DeviceBinding.hash(f.jwt))

      T.logout(f.jwt) |> T.assert_logout_ok()

      assert T.device_gone?(f.uid, f.j_dev)
      assert T.denylist_db_count("jti:" <> T.jwt_jti(f.jwt)) == 1
      assert_dead(T.whoami(f.jwt))
      T.forget_node_local_jwt_state!(f.jwt)
      assert_dead(T.whoami(f.jwt))
    end
  end

  describe "L2 — a database error on the binding lookup is never cached and never turns a bound JWT into an unbound one" do
    test "DeviceBinding.lookup/1: the error is not cached, the next call sees the binding", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      T.forget_node_local_jwt_state!(f.jwt)
      restore = T.revoke_select!("jwt_device_bindings")

      assert {:ok, nil, false} = Nebu.Matrix.Session.DeviceBinding.lookup(f.jwt), "a failing read degrades to unbound (unchanged)"
      assert {:error, :unavailable} = Nebu.Matrix.Session.DeviceBinding.lookup_fresh(f.jwt)

      restore.()
      assert {:ok, j_dev, false} = Nebu.Matrix.Session.DeviceBinding.lookup(f.jwt)
      assert j_dev == f.j_dev, "the error was not cached for the TTL"
    end

    test "the logout of a JWT whose binding read fails is 500 (fail closed): nothing deleted, nothing denylisted; the retry ends the device",
         %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      before = world([f.uid])
      T.forget_node_local_jwt_state!(f.jwt)
      restore = T.revoke_select!("jwt_device_bindings")

      {log, conn} = logged(fn -> T.logout(f.jwt) end)
      assert_500_unknown(conn)
      assert_one_line(log, "jwt_unbound", "failed", f.uid, nil)

      restore.()
      assert world([f.uid]) == before, "no device, key or binding was touched"
      assert T.denylist_db_count("jti:" <> T.jwt_jti(f.jwt)) == 0, "no denylist write after a failed binding read"
      assert T.whoami(f.jwt).status == 200, "the JWT still works"

      T.logout(f.jwt) |> T.assert_logout_ok()
      assert T.device_gone?(f.uid, f.j_dev), "the retry resolves the binding and ends the device"
      assert_dead(T.whoami(f.jwt))
    end
  end

  describe "AC7.3 — unbound JWT" do
    test "denylist write blocked => 500; JWT dead on this node; nothing else changed", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      o = oauth_on(cid, priv, dev(), sub: sub)
      l_dev = dev()
      l = T.legacy_session!(uid, l_dev)
      T.seed_device_keys!(uid, l_dev)
      T.seed_legacy_session_rows!(uid, l_dev)
      unbound = T.unbound_jwt!(priv, sub)
      before = world([uid])
      _remove = T.fail_denylist_key!("jti:" <> T.jwt_jti(unbound))

      {log, conn} = logged(fn -> T.logout(unbound) end)
      assert_500_unknown(conn)
      assert_one_line(log, "jwt_unbound", "failed", uid, nil)

      assert_dead(T.whoami(unbound))
      assert world([uid]) == before
      assert T.whoami(o.at).status == 200 and T.whoami(l.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 — concurrency under the devices-row lock (LL3, LL9)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.1 — the logout waits for the devices lock" do
    test "it does not finish while the lock is held; afterwards 200 and (U, L) is gone", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      [conn] = hold_lock(f.uid, f.l_dev, [fn -> T.logout(f.l.at) end])
      conn |> conn!() |> T.assert_logout_ok()
      assert T.session_rows(f.uid, f.l_dev) == []
      assert T.device_gone?(f.uid, f.l_dev)
    end
  end

  describe "AC8.2 — an OAuth take-over while the logout waits (re-check under the lock): nothing is deleted" do
    test "opaque: 200, nothing deleted, the OAuth row and device of L are intact", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      template = T.row_by_at(f.o.at)
      new_at = T.rand(32)
      new_rt = T.rand(32)
      keys_before = {T.device_state(f.uid, f.l_dev), T.device_fingerprint(f.uid, f.l_dev), legacy_rows(f.uid, f.l_dev)}

      {log, [conn]} =
        logged(fn -> hold_lock(f.uid, f.l_dev, [fn -> T.logout(f.l.at) end], fn -> take_over!(template, f.uid, f.l_dev, new_at, new_rt) end) end)

      conn |> conn!() |> T.assert_logout_ok()
      assert_one_line(log, "opaque", "unknown", f.uid, f.l_dev)
      assert [%{"auth_api" => "oauth"} = row] = T.session_rows(f.uid, f.l_dev), "LL3: the taken-over device keeps its OAuth row, nothing else"
      assert row["access_token_hash"] == T.token_hash(new_at)
      assert {T.device_state(f.uid, f.l_dev), T.device_fingerprint(f.uid, f.l_dev), legacy_rows(f.uid, f.l_dev)} == keys_before, "device and keys of L are intact"
      assert T.whoami(new_at).status == 200, "the NEWER (OAuth) session survives"
    end

    test "bound JWT (O1): 200, nothing deleted, the JWT is denylisted in the DB", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      template = T.row_by_at(f.o.at)
      new_at = T.rand(32)
      keys_before = {T.device_state(f.uid, f.j_dev), T.device_fingerprint(f.uid, f.j_dev)}

      # the binding row stays in place (an OAuth issuance deletes bindings only after its commit, best effort)
      take_over = fn -> take_over!(template, f.uid, f.j_dev, new_at, T.rand(32), false) end

      {log, [conn]} = logged(fn -> hold_lock(f.uid, f.j_dev, [fn -> T.logout(f.jwt) end], take_over) end)

      conn |> conn!() |> T.assert_logout_ok()
      assert_one_line(log, "jwt_bound", "unknown", f.uid, f.j_dev)
      assert [%{"auth_api" => "oauth"}] = T.session_rows(f.uid, f.j_dev)
      assert {T.device_state(f.uid, f.j_dev), T.device_fingerprint(f.uid, f.j_dev)} == keys_before
      assert T.whoami(new_at).status == 200
      assert T.denylist_db_count("jti:" <> T.jwt_jti(f.jwt)) == 1, "LL4: denylisted also on {:ok, :unknown}"
      assert_dead(T.whoami(f.jwt))
      T.forget_node_local_jwt_state!(f.jwt)
      assert_dead(T.whoami(f.jwt))
    end
  end

  describe "AC8.3-AC8.5 — legacy /refresh takes the devices lock (gate x)" do
    test "AC8.3: the refresh waits while the lock is held, then rotates", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)
      [conn] = hold_lock(f.uid, f.l_dev, [fn -> T.legacy_refresh(f.l.rt) end])
      conn = conn!(conn)
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      assert is_binary(T.json(conn)["access_token"])
    end

    test "AC8.4: the teardown (the real end_legacy_device) wins: the waiting refresh answers 401, no row survives",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)

      # the REAL teardown on the lock-holding connection (the nested transaction joins it; the lock is re-entrant)
      teardown = fn ->
        assert {:ok, :ended} == Nebu.Matrix.Session.OAuthSessionStore.end_legacy_device(:opaque, f.l.at, f.uid, f.l_dev, Nebu.Repo)
      end

      [conn] = hold_lock(f.uid, f.l_dev, [fn -> T.legacy_refresh(f.l.rt) end], teardown)

      conn |> conn!() |> assert_dead()
      assert T.session_rows(f.uid, f.l_dev) == [], "before LL9 the rotated-in row survived the deletion"
      assert T.device_gone?(f.uid, f.l_dev)
    end

    test "AC8.5: the refresh wins: a logout with the OLD access token ends the device, new tokens 401",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)
      rotated = T.legacy_refresh(f.l.rt)
      assert rotated.status == 200
      fresh = T.json(rotated)

      assert facade(%{kind: :opaque, token: f.l.at, user_id: f.uid, device_id: f.l_dev}) == {:ok, :ended},
             "the presented (soft-revoked, pending) row still belongs to the device (LL3: any state)"

      assert T.session_rows(f.uid, f.l_dev) == []
      assert_dead(T.whoami(fresh["access_token"]))
      assert_dead(T.legacy_refresh(fresh["refresh_token"]))
      assert T.device_gone?(f.uid, f.l_dev)
    end

    test "AC8.5b: a REAL race, logout and refresh queued on the lock: whatever the order, no credential of the device survives",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.idp_refresh_ok(f.sub)

      [logout, refresh] = hold_lock(f.uid, f.l_dev, [fn -> T.logout(f.l.at) end, fn -> T.legacy_refresh(f.l.rt) end])

      logout |> conn!() |> T.assert_logout_ok()
      refresh = conn!(refresh)
      assert refresh.status in [200, 401], "the refresh either rotated before the teardown or lost to it, got #{refresh.status}: #{refresh.resp_body}"

      assert T.session_rows(f.uid, f.l_dev) == [], "no matrix_sessions row of (U, L) survives, in either order"
      assert T.device_gone?(f.uid, f.l_dev)
      assert_dead(T.whoami(f.l.at))
      T.idp_refresh_ok(f.sub)
      assert_dead(T.legacy_refresh(f.l.rt))

      if refresh.status == 200 do
        fresh = T.json(refresh)
        assert_dead(T.whoami(fresh["access_token"]))
        assert_dead(T.legacy_refresh(fresh["refresh_token"]))
      end
    end
  end

  describe "AC8.6 — two concurrent logouts with the same credential" do
    test "both answer 200 {}; exactly one tears down (one `ended`, one `unknown`); no deadlock, no exception", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      run = fn -> T.logout(f.l.at) end

      {log, results} = logged(fn -> hold_lock(f.uid, f.l_dev, [run, run]) end)

      for conn <- results, do: conn |> conn!() |> T.assert_logout_ok()
      lines = logout_lines(log)
      assert length(lines) == 2, "one INFO line per call, got #{inspect(lines)}"
      assert Enum.count(lines, &(&1 =~ "outcome=ended")) == 1, "exactly one teardown: #{inspect(lines)}"
      assert Enum.count(lines, &(&1 =~ "outcome=unknown")) == 1, "the other re-check misses: #{inspect(lines)}"
      assert T.session_rows(f.uid, f.l_dev) == []
      assert T.device_gone?(f.uid, f.l_dev)
      assert T.whoami(f.o.at).status == 200
    end
  end

  describe "AC8.7 — a device-less legacy session (no devices row) racing a refresh (Kassandra L1)" do
    test "the teardown locks the session rows: a rotation that commits first has its NEW row deleted too" do
      uid = T.provision_user!()
      d = dev()
      l = legacy_on(uid, d)
      assert T.device_state(uid, d)["devices"] == 0, "precondition: the legacy session has no devices row"
      new_at = T.rand(32)
      new_rt = T.rand(32)

      # What a legacy rotation does (soft-revoke the old row, insert the new one) inside a transaction that commits AFTER
      # the logout started waiting for the row lock.
      rotate_in_txn = fn ->
        T.sql!("UPDATE matrix_sessions SET revoked_at = now() WHERE access_token_hash = $1", [T.token_hash(l.at)])
        :ok
      end

      {:ok, task} =
        Nebu.Repo.transaction(fn ->
          rotate_in_txn.()
          task = Task.async(fn -> T.safely(fn -> facade(%{kind: :opaque, token: l.at, user_id: uid, device_id: d}) end) end)
          wait_for_lock_waiters(1, System.monotonic_time(:millisecond) + 10_000, "%FROM matrix_sessions%")
          assert Task.yield(task, 100) == nil, "the teardown waits for the rotation's row lock"

          T.sql!(
            "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, user_id, device_id, expires_at, auth_time, created_at) " <>
              "SELECT $1, $2, user_id, device_id, expires_at, auth_time, now() FROM matrix_sessions WHERE access_token_hash = $3",
            [T.token_hash(new_at), T.token_hash(new_rt), T.token_hash(l.at)]
          )

          task
        end)

      assert Task.yield(task, 10_000) == {:ok, {:ok, :ended}}
      assert T.session_rows(uid, d) == [], "before the fix the DELETE saw only the old row and the new one survived"
      assert T.row_by_at(new_at) == nil
    end
  end

  describe "AC8.8 — the legacy logout does not wait for the devices lock forever (lock_timeout 2 s)" do
    test "a lock held longer than that => {:error, :unavailable} (500), rolled back; the retry works", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      before = world([f.uid])

      [result] = hold_lock(f.uid, f.l_dev, [fn -> T.logout(f.l.at) end], fn -> Process.sleep(2_600) end)

      result |> conn!() |> assert_500_unknown()
      assert world([f.uid]) == before
      assert T.whoami(f.l.at).status == 200
      T.logout(f.l.at) |> T.assert_logout_ok()
      assert T.device_gone?(f.uid, f.l_dev)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # The facade Nebu.Matrix.legacy_logout_device/1 (LL10)
  # ════════════════════════════════════════════════════════════════════════════

  describe "LL10 — Nebu.Matrix.legacy_logout_device/1" do
    test ":ended for the presented device, :unknown for a credential of another device",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      other = legacy_on(f.uid, dev())

      assert facade(%{kind: :opaque, token: other.at, user_id: f.uid, device_id: f.l_dev}) == {:ok, :unknown},
             "a token of ANOTHER device (wrong device id) must not end this device"

      assert T.session_rows(f.uid, f.l_dev) != []
      assert facade(%{kind: :opaque, token: f.l.at, user_id: f.uid, device_id: f.l_dev}) == {:ok, :ended}
      assert facade(%{kind: :opaque, token: f.l.at, user_id: f.uid, device_id: f.l_dev}) == {:ok, :unknown}
      assert T.whoami(other.at).status == 200
      assert T.whoami(f.o.at).status == 200
    end

    test "an OAuth access token is not a legacy credential: :unknown, the OAuth session is untouched", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      before = o_state(f)
      assert facade(%{kind: :opaque, token: f.o.at, user_id: f.uid, device_id: f.o.device_id}) == {:ok, :unknown}
      assert o_state(f) == before
      assert T.whoami(f.o.at).status == 200
    end

    test "a bound JWT whose device holds an OAuth row is :unknown (nothing deleted)", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      o = oauth_on(cid, priv, dev(), sub: sub)
      jwt = T.insert_jwt_binding!(priv, sub, uid, o.device_id)
      before = {T.rows_snapshot(uid, o.device_id), T.device_state(uid, o.device_id)}

      assert facade(%{kind: :jwt, token: jwt, user_id: uid, device_id: o.device_id}) == {:ok, :unknown}
      assert {T.rows_snapshot(uid, o.device_id), T.device_state(uid, o.device_id)} == before
    end

    test "opaque re-check: a credential of ANOTHER user for this (user, device) is :unknown, nothing deleted", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      before = world([f.uid])

      assert facade(%{kind: :opaque, token: f.l.at, user_id: f.stranger.uid, device_id: f.l_dev}) == {:ok, :unknown}
      assert facade(%{kind: :opaque, token: f.stranger.at, user_id: f.uid, device_id: f.l_dev}) == {:ok, :unknown}
      assert world([f.uid]) == before
      assert T.whoami(f.l.at).status == 200
      assert T.whoami(f.stranger.at).status == 200
    end

    test "a binding whose devices row is MISSING is :unknown (LL3 JWT re-check), and no row is touched", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      ghost = dev()
      jwt = T.insert_jwt_binding!(priv, sub, uid, ghost)
      assert T.device_state(uid, ghost)["devices"] == 0, "precondition: no devices row"

      assert facade(%{kind: :jwt, token: jwt, user_id: uid, device_id: ghost}) == {:ok, :unknown}
      assert T.binding_rows(uid, ghost) == 1, "the binding row is not ours to delete without the device"
    end

    test "a JWT without a binding for the device is :unknown (the device of another credential survives)", %{cid: cid, priv: priv} do
      f = bound_fixture(cid, priv)
      other_jwt = T.unbound_jwt!(priv, f.sub)
      before = world([f.uid])

      assert facade(%{kind: :jwt, token: other_jwt, user_id: f.uid, device_id: f.j_dev}) == {:ok, :unknown}
      assert world([f.uid]) == before
    end

    test "repo unavailable (NoSuchRepo) => {:error, :unavailable}, never raises, nothing deleted", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      before = world([f.uid])
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert facade(%{kind: :opaque, token: f.l.at, user_id: f.uid, device_id: f.l_dev}) == {:error, :unavailable}
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert world([f.uid]) == before
    end

    test "an opaque row with an EMPTY device id deletes only that row, no device (LL6)" do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      keep_dev = dev()
      keep = T.legacy_session!(uid, keep_dev)
      T.seed_device_keys!(uid, keep_dev)
      empty = T.legacy_session!(uid, "")
      keep_before = {T.rows_snapshot(uid, keep_dev), T.device_state(uid, keep_dev)}

      assert facade(%{kind: :opaque, token: empty.at, user_id: uid, device_id: ""}) == {:ok, :ended}

      assert T.row_by_at(empty.at) == nil
      assert {T.rows_snapshot(uid, keep_dev), T.device_state(uid, keep_dev)} == keep_before
      assert T.whoami(keep.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 — log hygiene (law: no sensitive data in logs)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10 — exactly one INFO `legacy logout` line per call, no secret in the log" do
    test "opaque, bound JWT, unbound JWT and a failure: one line each, no secret", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      secrets = %{at: f.l.at, rt: f.l.rt, at_hash: T.token_hash(f.l.at), rt_hash: T.token_hash(f.l.rt), o_at: f.o.at}

      {log, conn} = logged(fn -> T.logout(f.l.at) end)
      assert conn.status == 200
      assert_one_line(log, "opaque", "ended", f.uid, f.l_dev)
      T.refute_secrets_in_log(log, secrets)

      b = bound_fixture(cid, priv)
      jwt_secrets = %{jwt: b.jwt, jwt_hash: Nebu.Matrix.Session.DeviceBinding.hash(b.jwt), jti: T.jwt_jti(b.jwt)}
      {log, conn} = logged(fn -> T.logout(b.jwt) end)
      assert conn.status == 200
      assert_one_line(log, "jwt_bound", "ended", b.uid, b.j_dev)
      T.refute_secrets_in_log(log, jwt_secrets)

      unbound = T.unbound_jwt!(priv, b.sub)
      u_secrets = %{jwt: unbound, jwt_hash: Nebu.Matrix.Session.DeviceBinding.hash(unbound), jti: T.jwt_jti(unbound)}
      {log, conn} = logged(fn -> T.logout(unbound) end)
      assert conn.status == 200
      assert_one_line(log, "jwt_unbound", "ended", b.uid, nil)
      T.refute_secrets_in_log(log, u_secrets)

      g = fixture(cid, priv)
      g_secrets = %{at: g.l.at, rt: g.l.rt, at_hash: T.token_hash(g.l.at), rt_hash: T.token_hash(g.l.rt)}
      remove = T.block_deletes!("device_keys", g.uid)
      {log, conn} = logged(fn -> T.logout(g.l.at) end)
      assert conn.status == 500
      assert_one_line(log, "opaque", "failed", g.uid, g.l_dev)
      T.refute_secrets_in_log(log, g_secrets)
      remove.()
    end
  end
end
