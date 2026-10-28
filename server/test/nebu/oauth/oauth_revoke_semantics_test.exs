defmodule Nebu.OAuth.OAuthRevokeSemanticsTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-revocation-logout` (story 4 of epic
  oauth-broker), AC4 / AC5 / AC7 (R2, R3, R4, R5, R10, R11, R20, R24; Must #6, #8-#16, #20-#25)
  through the REAL story-2/3 flow (authorize -> IdP stub -> callback -> `POST /oauth2/token`):

    * every token kind of AC4 ends the WHOLE session of the device (all `matrix_sessions` rows, the
      `devices` row and its key tables, bound raw JWTs), the hint / `client_id` matrix is
      irrelevant, unknown / legacy / code / purged tokens change NOTHING (row snapshots);
    * after a revocation the AT is `401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout`, the RT is
      `invalid_grant`, other devices / users are untouched, other users' `/keys/query` no longer
      returns the device, cross-signing keys stay;
    * the three AC5 concurrency invariants (revoke vs rotation, parallel revokes, revoke of an old
      token vs a re-login on the same device id), ordered deterministically with a held `devices`
      row lock (`Task.yield/2` only proves the revocation WAITS for the lock; no sleeps).

  Pinned facade (R24, via `apply/3`): `Nebu.Matrix.oauth_revoke_token(token) :: {:ok, :revoked,
  %{user_id:, device_id:, client_id:}} | {:ok, :unknown} | {:error, :unavailable}`.

  Red today: `/oauth2/revoke` is not routed (router plain 404) and the facade does not exist.
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

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_revoke_test_hook, :uia_fresh_auth_seconds],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "RS" <> String.upcase(T.rand(4))
  defp m(fun, args), do: apply(Nebu.Matrix, fun, args)

  defp session_on(cid, priv, device_id, opts \\ []),
    do: T.session!(cid, @https, priv, Keyword.merge([authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}], opts))

  defp session(cid, priv, opts \\ []), do: session_on(cid, priv, dev(), opts)

  defp revoke_ok!(token, hint \\ nil, client_id \\ nil), do: T.revoke(T.revoke_params(token, hint, client_id)) |> T.assert_revoke_ok()

  # AC4 / AC7 / R20: the whole session of the device is gone.
  defp assert_session_ended(s, cid) do
    assert T.session_rows(s.user_id, s.device_id) == [], "no matrix_sessions row of the device may survive (any auth_api, R2)"
    assert T.device_gone?(s.user_id, s.device_id), "devices + key tables of the device are deleted (R2): #{inspect(T.device_state(s.user_id, s.device_id))}"
    T.assert_unknown_token(T.whoami(s.at), false)
    T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
  end

  # the T10 rotation done by hand (inside the caller's transaction when there is one)
  defp rotate_by_sql!(old_at, new_at, new_rt) do
    T.sql!("UPDATE matrix_sessions SET revoked_at = now(), grace_until = NULL WHERE access_token_hash = $1 AND revoked_at IS NULL", [T.token_hash(old_at)])
    insert_like!(old_at, new_at, new_rt)
  end

  defp insert_like!(template_at, new_at, new_rt, row \\ nil) do
    row = row || T.row_by_at(template_at)

    T.sql!(
      "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, " <>
        "session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at) " <>
        "VALUES ($1, $2, $3, $4, $5, LEAST(now() + interval '900 seconds', $6::timestamptz), $6::timestamptz, $7, 'oauth', $8, $9, $10, now())",
      [T.token_hash(new_at), T.token_hash(new_rt), row["oidc_refresh_token"], row["user_id"], row["device_id"],
       row["session_expires_at"], row["auth_time"], row["client_id"], row["scope"], row["oauth_code_hash"]]
    )
  end

  defp lock_device!(uid, d),
    do: T.sql!("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [uid, d])

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 / R3 / Must #9-#14 — every token kind ends the whole session
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/R3 — every OAuth token kind (any state) ends the session + device" do
    test "Must #9: active access token", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      revoke_ok!(s.at)
      assert_session_ended(s, cid)
    end

    test "Must #10: active refresh token (MUST revoke access AND refresh token)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      revoke_ok!(s.rt)
      assert_session_ended(s, cid)
    end

    test "Must #11: an EXPIRED access token (Dart SDK) still revokes", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(s.at)])
      T.assert_unknown_token(T.whoami(s.at), true)
      revoke_ok!(s.at, "access_token", cid)
      assert_session_ended(s, cid)
    end

    test "Must #12: the superseded access token after a rotation ends the whole session incl. the NEW active row", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)
      revoke_ok!(s.at)
      assert T.session_rows(s.user_id, s.device_id) == []
      T.assert_unknown_token(T.whoami(fresh["access_token"]), false)
      T.refresh(cid, fresh["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")
      assert T.device_gone?(s.user_id, s.device_id)
    end

    test "Must #12: the PENDING refresh token after a rotation ends the whole session", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)
      assert T.row_by_rt(s.rt)["grace_until"] == nil, "precondition: the old RT is PENDING"
      revoke_ok!(s.rt, "refresh_token")
      assert T.session_rows(s.user_id, s.device_id) == []
      T.assert_unknown_token(T.whoami(fresh["access_token"]), false)
    end

    test "Must #13: a CONSUMED refresh token ends the whole session (no T11 path, no 'reuse' WARNING)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)
      assert T.whoami(fresh["access_token"]).status == 200
      assert T.row_by_rt(s.rt)["grace_until"] != nil, "precondition: the old RT is CONSUMED"

      log = capture_log(fn -> revoke_ok!(s.rt) end)
      refute log =~ ~r/reuse/i, "revocation of a consumed RT is a logout, not the T11 reuse reaction"
      assert T.session_rows(s.user_id, s.device_id) == []
      T.assert_unknown_token(T.whoami(fresh["access_token"]), false)
      T.refresh(cid, fresh["refresh_token"]) |> T.assert_token_error(400, "invalid_grant")
    end

    test "Must #14: a token of an EXPIRED session (session_expires_at in the past) => rows + device deleted, 200", %{cid: cid, priv: priv} do
      s = session(cid, priv)

      T.sql!(
        "UPDATE matrix_sessions SET expires_at = now() - interval '2 seconds', session_expires_at = now() - interval '1 second' WHERE user_id = $1 AND device_id = $2",
        [s.user_id, s.device_id]
      )

      revoke_ok!(s.rt)
      assert T.session_rows(s.user_id, s.device_id) == []
      assert T.device_gone?(s.user_id, s.device_id)
    end

    test "R8: a percent-encoded REAL token is form-decoded first and then revoked", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      encoded = s.rt |> String.graphemes() |> Enum.map_join(fn c -> "%" <> Base.encode16(c, case: :upper) end)
      T.revoke("token=" <> encoded <> "&token_type_hint=refresh_token") |> T.assert_revoke_ok()
      assert_session_ended(s, cid)
    end

    test "Must #20: revoking the same token twice => 200 twice; AT then RT in sequence => one teardown", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      revoke_ok!(s.at)
      revoke_ok!(s.at)
      revoke_ok!(s.rt)
      assert_session_ended(s, cid)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 / R3 / R4 / Must #15, #16 — hint and client_id never matter
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/R3/R4/Must #15, #16 — token_type_hint and client_id are advisory" do
    for hint <- [nil, "access_token", "refresh_token", "id_token", "junk-hint"], token_kind <- [:at, :rt] do
      test "hint #{inspect(hint)} with the #{token_kind} => revoked", %{cid: cid, priv: priv} do
        s = session(cid, priv)
        revoke_ok!(Map.fetch!(s, unquote(token_kind)), unquote(hint))
        assert_session_ended(s, cid)
      end
    end

    test "client_id absent, the session's client, ANOTHER approved client, an unknown string => revoked in every case",
         %{cid: cid, priv: priv} do
      other = T.oauth_client!(["https://other.example.com/cb"])

      for client <- [nil, cid, other, "no-such-client-" <> T.rand(), String.duplicate("c", 2000)] do
        s = session(cid, priv)
        revoke_ok!(s.at, nil, client)
        assert T.session_rows(s.user_id, s.device_id) == [], "client_id #{inspect(String.slice(client || "nil", 0, 30))} must not prevent the revocation"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 / R5 / Must #6, #8 — no hit => 200, NOTHING changes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/R5/Must #6, #8 — no hit => 200 {} and no row of any table changes" do
    test "Must #6: an unknown well-formed token", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      before = T.world_snapshot([s.user_id])
      revoke_ok!(T.rand(32))
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(s.at).status == 200
    end

    test "Must #8: a LEGACY opaque access token and a LEGACY refresh token => 200, the legacy session keeps working" do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      legacy = T.legacy_session!(uid, d, oidc_refresh_token: Nebu.Web.SecretBox.encrypt("legacy-idp-rt-" <> T.rand(6)))
      T.seed_device_keys!(uid, d)
      before = T.world_snapshot([uid])

      revoke_ok!(legacy.at, "access_token")
      revoke_ok!(legacy.rt, "refresh_token")

      assert T.world_snapshot([uid]) == before, "OAuth revocation never acts on legacy sessions (spec 8, R5)"
      assert T.whoami(legacy.at).status == 200

      T.idp_refresh_ok(sub)
      refresh = T.legacy_refresh(legacy.rt)
      assert refresh.status == 200, "legacy /refresh still works, got #{refresh.status}: #{refresh.resp_body}"
    end

    test "an authorization code value => 200, nothing changes, the code is still redeemable", %{cid: cid, priv: priv} do
      grant = T.flow_code!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev())})
      revoke_ok!(grant.code)
      revoke_ok!(T.sha256_hex(grant.code))
      assert T.count_for("oauth_codes", cid) >= 1
      T.redeem!(grant)
    end

    test "a raw IdP JWT => 200, nothing changes", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      jwt = T.bound_jwt!(priv, sub, d)
      before = T.world_snapshot([uid])
      revoke_ok!(jwt)
      assert T.world_snapshot([uid]) == before
      assert T.whoami(jwt).status == 200
    end

    test "the access token of a PURGED session (rows gone, device kept) => 200 no-op", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      T.sql!("DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [s.user_id, s.device_id])
      before = T.world_snapshot([s.user_id])
      revoke_ok!(s.at)
      assert T.world_snapshot([s.user_id]) == before, "no hit => the device is NOT deleted"
    end

    test "Must #23: revoke after DELETE /devices/{id} of that device => 200 no-op", %{cid: cid, priv: priv} do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> s.device_id, legacy.at, body: %{})
      assert conn.status == 200, "precondition: device delete by the legacy session, got #{conn.status}: #{conn.resp_body}"
      before = T.world_snapshot([s.user_id])
      revoke_ok!(s.at)
      revoke_ok!(s.rt)
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(legacy.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 / AC7 / R2 / Must #23-#25 — device teardown, other devices / users untouched
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/AC7/R2/Must #23-#25 — device teardown and isolation" do
    test "only this device ends: the user's other OAuth device, legacy device and another user keep working",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      other_oauth = session_on(cid, priv, dev(), sub: s.sub)
      legacy_dev = dev()
      legacy = T.legacy_session!(s.user_id, legacy_dev)
      stranger = session(cid, priv)

      for {u, d} <- [{s.user_id, s.device_id}, {s.user_id, other_oauth.device_id}, {s.user_id, legacy_dev}, {stranger.user_id, stranger.device_id}],
          do: T.seed_device_keys!(u, d)

      keep = %{
        other: {T.rows_snapshot(s.user_id, other_oauth.device_id), T.device_state(s.user_id, other_oauth.device_id)},
        legacy: {T.rows_snapshot(s.user_id, legacy_dev), T.device_state(s.user_id, legacy_dev)},
        stranger: T.world_snapshot([stranger.user_id])
      }

      revoke_ok!(s.at)
      assert_session_ended(s, cid)

      assert {T.rows_snapshot(s.user_id, other_oauth.device_id), T.device_state(s.user_id, other_oauth.device_id)} == keep.other
      assert {T.rows_snapshot(s.user_id, legacy_dev), T.device_state(s.user_id, legacy_dev)} == keep.legacy
      assert T.world_snapshot([stranger.user_id]) == keep.stranger
      assert T.whoami(other_oauth.at).status == 200
      assert T.whoami(legacy.at).status == 200
      assert T.whoami(stranger.at).status == 200
      T.idp_refresh_ok(s.sub)
      T.refresh(cid, other_oauth.rt) |> T.assert_token_success()
    end

    test "cross-user isolation with the SAME device_id: another user's session + device with that id survive", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)
      twin = session_on(cid, priv, d)
      legacy_uid = T.provision_user!()
      legacy_twin = T.legacy_session!(legacy_uid, d)
      refute twin.user_id == s.user_id
      for u <- [s.user_id, twin.user_id, legacy_uid], do: T.seed_device_keys!(u, d)
      keep = T.world_snapshot([twin.user_id, legacy_uid])

      revoke_ok!(s.at)
      assert_session_ended(s, cid)
      assert T.world_snapshot([twin.user_id, legacy_uid]) == keep, "a revocation is scoped to (user_id, device_id), never device_id alone"
      assert T.whoami(twin.at).status == 200
      assert T.whoami(legacy_twin.at).status == 200
    end

    test "GET /devices of the user's other session no longer lists the device; peers' /keys/query no longer returns its keys; cross-signing kept",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      T.seed_cross_signing!(s.user_id)
      legacy = T.legacy_session!(s.user_id, dev())
      peer_uid = T.provision_user!()
      peer = T.legacy_session!(peer_uid, dev())

      query = fn ->
        conn = T.matrix_request(:post, "/_matrix/client/v3/keys/query", peer.at, body: %{"device_keys" => %{s.user_id => []}})
        assert conn.status == 200
        T.json(conn)
      end

      listed = fn ->
        conn = T.matrix_request(:get, "/_matrix/client/v3/devices", legacy.at)
        assert conn.status == 200
        T.json(conn)["devices"] |> Enum.map(& &1["device_id"])
      end

      assert get_in(query.(), ["device_keys", s.user_id, s.device_id]), "precondition: the peer sees the device keys"
      assert s.device_id in listed.()

      revoke_ok!(s.rt)

      refute get_in(query.(), ["device_keys", s.user_id, s.device_id]), "the revoked device's keys must vanish from peers' /keys/query"
      assert query.()["master_keys"][s.user_id], "cross-signing keys (per user) are untouched"
      assert T.cross_signing_count(s.user_id) == 1
      refute s.device_id in listed.()
    end

    test "a raw JWT bound to the device is denylisted and its binding deleted (S3 kill-switch, R2)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      jwt = T.insert_jwt_binding!(priv, s.sub, s.user_id, s.device_id)
      revoke_ok!(s.at)
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(s.user_id, s.device_id) == []
      claims = jwt |> String.split(".") |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert Nebu.Web.TokenDenylist.revoked?(claims["jti"], jwt)
      body = T.assert_unknown_token(T.whoami(jwt), false)
      assert body["error"] =~ "revoked"
    end

    test "AC7: the revoked session's RT (active, pending, consumed) => invalid_grant with no side effect on other sessions",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      mid = T.refresh!(cid, s.rt)
      assert T.whoami(mid["access_token"]).status == 200
      last = T.refresh!(cid, mid["refresh_token"])
      other = session_on(cid, priv, dev(), sub: s.sub)
      keep = T.rows_snapshot(s.user_id, other.device_id)

      revoke_ok!(last["access_token"])

      for rt <- [s.rt, mid["refresh_token"], last["refresh_token"]] do
        T.refresh(cid, rt) |> T.assert_token_error(400, "invalid_grant")
      end

      assert T.rows_snapshot(s.user_id, other.device_id) == keep, "no reuse revocation fires on another device"
      assert T.whoami(other.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 / R11 / R24 — the facade function, concurrency invariants
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/R24 — Nebu.Matrix.oauth_revoke_token/1 contract" do
    test "{:ok, :revoked, %{user_id, device_id, client_id}} for a hit, {:ok, :unknown} afterwards and for junk", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      assert m(:oauth_revoke_token, [s.rt]) == {:ok, :revoked, %{user_id: s.user_id, device_id: s.device_id, client_id: cid}}
      assert m(:oauth_revoke_token, [s.at]) == {:ok, :unknown}
      assert m(:oauth_revoke_token, [T.rand(32)]) == {:ok, :unknown}
    end

    test "defence in depth: a non-64-hex value is {:ok, :unknown} WITHOUT DB access (NoSuchRepo)" do
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      for v <- ["short", String.duplicate("A", 64), "a.b.c", ""], do: assert(m(:oauth_revoke_token, [v]) == {:ok, :unknown})
    end

    test "repo unavailable => {:error, :unavailable}; never raises", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert m(:oauth_revoke_token, [s.at]) == {:error, :unavailable}
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(s.at).status == 200
    end
  end

  describe "AC5 (a)/R11/Trap 1/Must #21 — revoke vs a rotation that commits while the revoke waits for the devices lock" do
    test "the revoke waits for the lock; its DELETE sees the rotated-in row: no surviving row, the new tokens are dead",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      new_at = T.rand(32)
      new_rt = T.rand(32)

      {:ok, task} =
        Nebu.Repo.transaction(fn ->
          lock_device!(s.user_id, s.device_id)
          task = Task.async(fn -> T.safely(fn -> m(:oauth_revoke_token, [s.at]) end) end)
          T.await_lock_wait!()
          assert Task.yield(task, 0) == nil, "the revocation must wait for the devices row lock held by the rotation"
          rotate_by_sql!(s.at, new_at, new_rt)
          task
        end)

      assert {:ok, {:ok, :revoked, %{device_id: d}}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert d == s.device_id
      assert T.session_rows(s.user_id, s.device_id) == [], "READ COMMITTED: the DELETE runs after the lock, so the rotated-in row dies too"
      T.assert_unknown_token(T.whoami(new_at), false)
      T.refresh(cid, new_rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "stress: concurrent refreshes + one revoke => no live row, every returned access token is dead, no 500", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)

      refreshers = for _ <- 1..8, do: Task.async(fn -> T.refresh(cid, s.rt) end)
      revoker = Task.async(fn -> T.revoke(T.revoke_params(s.rt)) end)
      conns = Enum.map(refreshers, &Task.await(&1, 30_000))
      T.assert_revoke_ok(Task.await(revoker, 30_000))

      for c <- conns, do: assert(c.status in [200, 400, 503], "a losing refresh answers invalid_grant or 503, never #{c.status}")
      assert T.session_rows(s.user_id, s.device_id) == []
      assert T.device_gone?(s.user_id, s.device_id)

      for c <- conns, c.status == 200 do
        T.assert_unknown_token(T.whoami(T.json(c)["access_token"]), false)
      end
    end
  end

  describe "AC5 (b)/Trap 17/Must #20 — parallel revocation of AT and RT (Element)" do
    test "both 200, the session ends once, no WARNING / error log", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)

      log =
        capture_log(fn ->
          tasks = for t <- [s.at, s.rt], do: Task.async(fn -> T.revoke(T.revoke_params(t)) end)
          send(self(), {:conns, Enum.map(tasks, &Task.await(&1, 30_000))})
        end)

      assert_received {:conns, conns}
      Enum.each(conns, &T.assert_revoke_ok/1)
      refute log =~ "[warning]" or log =~ "[error]", "the second revocation is a silent 200 (Trap 17): #{log}"
      assert_session_ended(s, cid)
    end
  end

  describe "AC5 (b)/R11 — deterministic: two revocations queued on the held devices lock" do
    test "both wait for the lock; exactly one {:ok, :revoked, _}, the other {:ok, :unknown}; session ended once", %{cid: cid, priv: priv} do
      s = session(cid, priv)

      {:ok, tasks} =
        Nebu.Repo.transaction(fn ->
          lock_device!(s.user_id, s.device_id)
          tasks = for t <- [s.at, s.rt], do: Task.async(fn -> T.safely(fn -> m(:oauth_revoke_token, [t]) end) end)

          T.await_lock_wait!(2)
          for task <- tasks, do: assert(Task.yield(task, 0) == nil, "every revocation must wait for the devices row lock")

          tasks
        end)

      results = Enum.map(tasks, fn task -> Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) end)
      assert Enum.count(results, &match?({:ok, {:ok, :revoked, %{device_id: _}}}, &1)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:ok, {:ok, :unknown}})) == 1, inspect(results)
      assert_session_ended(s, cid)
    end
  end

  describe "AC5 (c)/R11/Trap 2/Must #22 — revoke of an OLD token vs a re-login on the same device id" do
    test "the re-login commits between the revoke's lookup and its lock: the NEW session and device survive",
         %{cid: cid, priv: priv} do
      d = dev()
      old = session_on(cid, priv, d)
      T.seed_device_keys!(old.user_id, d)
      new_at = T.rand(32)
      new_rt = T.rand(32)

      {:ok, task} =
        Nebu.Repo.transaction(fn ->
          # T7 issuance: lock the devices row first, then replace every row of the device
          lock_device!(old.user_id, d)
          task = Task.async(fn -> T.safely(fn -> m(:oauth_revoke_token, [old.at]) end) end)
          T.await_lock_wait!()
          assert Task.yield(task, 0) == nil, "the revocation must wait for the devices row lock held by the re-login"
          row = T.row_by_at(old.at)
          T.sql!("DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [old.user_id, d])
          insert_like!(old.at, new_at, new_rt, row)
          task
        end)

      assert {:ok, {:ok, :unknown}} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      assert [row] = T.session_rows(old.user_id, d)
      assert row["access_token_hash"] == T.token_hash(new_at), "an older token never deletes a newer session (re-check after the lock)"
      assert T.device_state(old.user_id, d)["devices"] == 1, "the device of the new session survives"
      assert T.whoami(new_at).status == 200
      T.assert_unknown_token(T.whoami(old.at), false)
    end
  end
end
