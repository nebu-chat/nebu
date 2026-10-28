defmodule Nebu.OAuth.OAuthDeviceTeardownTest do
  @moduledoc """
  Acceptance tests for story `oauth-legacy-coexistence` (story 5 of epic oauth-broker),
  AC6-AC8 (C11-C13, oracle O4; Must #17-#22, #24, #25, #35, #36) and the review-cycle-1 hardening
  (Kassandra L-1: a revoked raw JWT cannot log in again, an existing binding is never re-pointed;
  the post-TTL outcome of the preserved own-device path):

    * AC6 an UNBOUND raw JWT never writes keys of an OAuth device (bind FIRST, refused => 403, no
      write); `DeviceBinding.put/4 :: :ok | {:error, :oauth_device}`; the legacy raw-JWT `POST /login`
      answers `500 M_UNKNOWN "Login failed, please try again."` for a refused binding AND for a failed
      `register_device/4`.
    * AC7 atomic device teardown (`Nebu.Matrix.end_device_session/2`) for legacy `DELETE /devices`,
      `/delete_devices` and admin `delete_user_device/2`: deterministic lock test vs a concurrent OAuth
      rotation, storage failure => 500, legacy `sessions` / `sync_tokens` rows removed.
    * AC8 the JWT kill-switch keeps a binding whose denylist DB write failed; a JWT bound to a device
      without a `devices` row is refused (`lookup/1` third element = "refused"), also on another node.

  Pinned (via `apply/3`): `Nebu.Matrix.end_device_session/2 :: :ok | {:error, :unavailable}`,
  `DeviceBinding.kill_device_jwts/3 :: :ok | {:error, :partial}`, `TokenDenylist.revoke_by_hash/2 ::
  :ok | {:error, term}`. Seam NEW: `:nebu_http, :device_binding_put_override` (4-arity).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.Matrix.Session.DeviceBinding

  @https "https://app.example.com/cb"
  @g1 %{"errcode" => "M_FORBIDDEN", "error" => "device_keys device_id does not match the authenticated device"}
  @login_failed %{"errcode" => "M_UNKNOWN", "error" => "Login failed, please try again."}
  @delete_failed %{"errcode" => "M_UNKNOWN", "error" => "Device deletion failed, please try again."}

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :uia_fresh_auth_seconds, :device_binding_put_override],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "TD" <> String.upcase(T.rand(4))

  defp session_on(cid, priv, device_id, opts),
    do: T.session!(cid, @https, priv, Keyword.merge([authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}], opts))

  defp key_rows(uid, d) do
    for t <- ~w(device_keys device_one_time_keys device_fallback_keys jwt_device_bindings), into: %{} do
      {t, T.sql!("SELECT * FROM #{t} WHERE user_id = $1 AND device_id = $2 ORDER BY 1, 2", [uid, d]).rows}
    end
  end

  defp upload_body(uid, d) do
    %{
      "device_keys" => %{
        "user_id" => uid,
        "device_id" => d,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
        "keys" => %{"curve25519:#{d}" => "attacker-curve-" <> T.rand(4), "ed25519:#{d}" => "attacker-ed-" <> T.rand(4)},
        "signatures" => %{}
      },
      "one_time_keys" => %{"signed_curve25519:EVIL" <> T.rand(2) => %{"key" => "evil-otk"}},
      "fallback_keys" => %{"signed_curve25519:EVILF" <> T.rand(2) => %{"key" => "evil-fbk", "fallback" => true}}
    }
  end

  defp apply_revoke(h, exp), do: apply(Nebu.Web.TokenDenylist, :revoke_by_hash, [h, exp])

  defp upload(token, body), do: T.matrix_request(:post, "/_matrix/client/v3/keys/upload", token, body: body)

  defp rotate_by_sql!(row, new_at, new_rt) do
    T.sql!("UPDATE matrix_sessions SET revoked_at = now(), grace_until = NULL WHERE access_token_hash = $1 AND revoked_at IS NULL", [row["access_token_hash"]])

    T.sql!(
      "INSERT INTO matrix_sessions (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, " <>
        "session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at) " <>
        "VALUES ($1, $2, $3, $4, $5, LEAST(now() + interval '900 seconds', $6::timestamptz), $6::timestamptz, $7, 'oauth', $8, $9, $10, now())",
      [T.token_hash(new_at), T.token_hash(new_rt), row["oidc_refresh_token"], row["user_id"], row["device_id"],
       row["session_expires_at"], row["auth_time"], row["client_id"], row["scope"], row["oauth_code_hash"]]
    )
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 / C11 — raw JWT never writes keys of an OAuth device
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/C11/Must #17, #18 — POST /keys/upload with an UNBOUND raw JWT" do
    test "naming the user's OAuth device => 403 (G1 text), no key / binding row changed", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d, [])
      T.seed_device_keys!(s.user_id, d)
      before = key_rows(s.user_id, d)
      jwt = T.unbound_jwt!(priv, s.sub)

      conn = upload(jwt, upload_body(s.user_id, d))
      assert conn.status == 403, "a raw JWT must never write keys of an OAuth device, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @g1
      assert key_rows(s.user_id, d) == before, "the OAuth device's keys are byte-identical afterwards"
      assert T.whoami(s.at).status == 200
    end

    test "naming a legacy device of the user or a new id => unchanged (binds + writes, 200)", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev(), [])

      for target <- [:legacy, :new] do
        d = dev()
        if target == :legacy, do: T.legacy_session!(s.user_id, d)
        jwt = T.unbound_jwt!(priv, s.sub)
        conn = upload(jwt, upload_body(s.user_id, d))
        assert conn.status == 200, "#{target}: got #{conn.status}: #{conn.resp_body}"
        assert T.binding_rows(s.user_id, d) == 1
        assert key_rows(s.user_id, d)["device_keys"] != []
      end
    end
  end

  describe "AC6/C11 — DeviceBinding.put/4 result" do
    test "a refused bind (OAuth device) => {:error, :oauth_device}, no row, no cache entry; a normal bind => :ok", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d, [])
      jwt = T.unbound_jwt!(priv, s.sub)
      assert apply(DeviceBinding, :put, [jwt, s.user_id, d, System.system_time(:second) + 3600]) == {:error, :oauth_device}
      assert T.binding_rows(s.user_id, d) == 0
      assert DeviceBinding.get_device(jwt) == nil

      ld = dev()
      Nebu.Matrix.DeviceKeyStore.upsert_device(s.user_id, ld)
      assert apply(DeviceBinding, :put, [T.unbound_jwt!(priv, s.sub), s.user_id, ld, System.system_time(:second) + 3600]) == :ok
    end
  end

  describe "AC6/C11/O4/Must #19, #35 — legacy POST /login raw-JWT branch" do
    test "regression: the raw-JWT login still returns the JWT and binds it", %{priv: priv} do
      sub = T.unique_sub()
      conn = T.legacy_login(priv, sub)
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      body = T.json(conn)
      assert String.contains?(body["access_token"], ".")
      assert T.binding_rows(body["user_id"], body["device_id"]) == 1
      assert T.whoami(body["access_token"]).status == 200
    end

    test "a refused binding (OAuth issuance won the device) => 500 M_UNKNOWN 'Login failed, please try again.', no JWT", %{priv: priv} do
      sub = T.unique_sub()
      pid = self()
      T.put_env_scoped(:device_binding_put_override, fn jwt, _uid, _d, _exp -> send(pid, {:jwt, jwt}); {:error, :oauth_device} end)
      log = capture_log(fn -> send(self(), {:conn, T.legacy_login(priv, sub, dev())}) end)
      assert_received {:conn, conn}
      assert conn.status == 500, "a refused binding must not hand out an unusable JWT, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @login_failed
      refute conn.resp_body =~ "access_token"
      assert_received {:jwt, jwt}
      T.refute_secrets_in_log(log, %{jwt: jwt, jwt_hash: DeviceBinding.hash(jwt)})
    end

    test "O4: a FAILING register_device/4 (devices upsert refused) => the same 500, no JWT, no binding row", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      _remove = T.block_device_upserts!(uid)

      log = capture_log(fn -> send(self(), {:conn, T.safely(fn -> T.legacy_login(priv, sub, d) end)}) end)
      assert_received {:conn, conn}
      assert %Plug.Conn{} = conn, "the failed device upsert must be answered, not raised: #{inspect(conn)}"
      assert conn.status == 500
      assert T.json(conn) == @login_failed
      refute conn.resp_body =~ "access_token"
      assert T.binding_rows(uid, d) == 0
      refute log =~ ~r/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\./, "no JWT in any log line of the 500 path"
    end

    test "O4: the OPAQUE branch keeps ignoring a failed register_device/4 (200, opaque tokens)", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      _remove = T.block_device_upserts!(uid)
      conn = T.safely(fn -> T.legacy_login(priv, sub, dev(), refresh_token: true, idp_rt: "legacy-idp-rt-" <> T.rand(4)) end)
      assert %Plug.Conn{} = conn, "the opaque branch must not raise: #{inspect(conn)}"
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      refute String.contains?(T.json(conn)["access_token"], ".")
    end

    test "C11: a DB error in put/4 stays best effort (:ok), the raw-JWT login is unchanged", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, d)
      _remove = T.block_binding_inserts!(uid)
      assert apply(DeviceBinding, :put, [T.unbound_jwt!(priv, sub), uid, d, System.system_time(:second) + 3600]) == :ok
      assert T.binding_rows(uid, d) == 0
    end

    test "the opaque branch (refresh_token: true + IdP RT) is unchanged", %{priv: priv} do
      conn = T.legacy_login(priv, T.unique_sub(), dev(), refresh_token: true, idp_rt: "legacy-idp-rt-" <> T.rand(4))
      assert conn.status == 200
      refute String.contains?(T.json(conn)["access_token"], ".")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 / C12 — atomic device teardown
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7/C12 — Nebu.Matrix.end_device_session/2" do
    test "ends every row of the device + device tables; {:error, :unavailable} with NoSuchRepo; never raises", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d, [])
      T.seed_device_keys!(s.user_id, d)
      assert apply(Nebu.Matrix, :end_device_session, [s.user_id, d]) == :ok
      assert T.session_rows(s.user_id, d) == []
      assert T.device_gone?(s.user_id, d)

      s2 = session_on(cid, priv, dev(), [])
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert apply(Nebu.Matrix, :end_device_session, [s2.user_id, s2.device_id]) == {:error, :unavailable}
    end
  end

  describe "AC7/C12/Must #20 — deletion vs a concurrent OAuth rotation (devices-row lock, story-4 idiom)" do
    for via <- [:legacy_delete, :admin_delete] do
      test "#{via}: the deletion waits for the lock; the rotated-in row dies too; its AT 401, RT invalid_grant", %{cid: cid, priv: priv} do
        T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
        d = dev()
        s = session_on(cid, priv, d, [])
        legacy = T.legacy_session!(s.user_id, dev())
        row = T.row_by_at(s.at)
        new_at = T.rand(32)
        new_rt = T.rand(32)

        run = fn ->
          case unquote(via) do
            :legacy_delete -> T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> d, legacy.at, body: %{}).status
            :admin_delete -> Nebu.Matrix.delete_user_device(s.user_id, d)
          end
        end

        {:ok, task} =
          Nebu.Repo.transaction(fn ->
            T.sql!("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [s.user_id, d])
            task = Task.async(fn -> T.safely(run) end)
            T.await_lock_wait!()
            assert Task.yield(task, 0) == nil, "the deletion must wait for the devices row lock"
            rotate_by_sql!(row, new_at, new_rt)
            task
          end)

        result = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
        assert result in [{:ok, 200}, {:ok, :ok}], "deletion result #{inspect(result)}"
        assert T.session_rows(s.user_id, d) == [], "no row of the deleted device may survive the concurrent rotation (C12)"
        T.assert_unknown_token(T.whoami(new_at), false)
        T.refresh(cid, new_rt) |> T.assert_token_error(400, "invalid_grant")
      end
    end
  end

  describe "AC7/C12/Must #21 — storage failure => 500, session intact" do
    setup do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      :ok
    end

    test "DELETE /devices/{oauth_device} by a legacy session with the session repo unavailable => 500, AT works", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev(), [])
      legacy = T.legacy_session!(s.user_id, dev())
      before = T.world_snapshot([s.user_id])
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      log = capture_log(fn -> send(self(), {:conn, T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> s.device_id, legacy.at, body: %{})}) end)
      assert_received {:conn, conn}
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @delete_failed
      T.refute_secrets_in_log(log, %{at: s.at, rt: s.rt, legacy: legacy.at, at_hash: T.token_hash(s.at)})
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(s.at).status == 200
    end

    test "POST /delete_devices with a blocked DELETE => 500 after attempting every id; sessions intact", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev(), [])
      other = session_on(cid, priv, dev(), sub: s.sub)
      legacy = T.legacy_session!(s.user_id, dev())
      before = T.world_snapshot([s.user_id])
      _remove = T.block_session_deletes!(s.user_id)

      conn = T.matrix_request(:post, "/_matrix/client/v3/delete_devices", legacy.at, body: %{"devices" => [s.device_id, other.device_id]})
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @delete_failed
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(s.at).status == 200 and T.whoami(other.at).status == 200
    end

    test "POST /delete_devices attempts EVERY id: OAuth device blocked => 500, the legacy device is still gone, the OAuth device intact",
         %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev(), [])
      legacy_dev = dev()
      _legacy_target = T.legacy_session!(s.user_id, legacy_dev)
      T.seed_device_keys!(s.user_id, legacy_dev)
      caller = T.legacy_session!(s.user_id, dev())
      oauth_before = {T.rows_snapshot(s.user_id, s.device_id), T.device_state(s.user_id, s.device_id)}
      _remove = T.block_session_deletes!(s.user_id, auth_api: "oauth")

      log =
        capture_log(fn ->
          send(self(), {:conn, T.matrix_request(:post, "/_matrix/client/v3/delete_devices", caller.at, body: %{"devices" => [s.device_id, legacy_dev]})})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == @delete_failed
      assert T.session_rows(s.user_id, legacy_dev) == [] and T.device_gone?(s.user_id, legacy_dev), "the other id was still attempted and deleted"
      assert {T.rows_snapshot(s.user_id, s.device_id), T.device_state(s.user_id, s.device_id)} == oauth_before, "the failed device is intact (rolled back)"
      assert T.whoami(s.at).status == 200
      T.refute_secrets_in_log(log, %{at: s.at, rt: s.rt, caller: caller.at})
    end

    test "admin delete_user_device/2 with the repo unavailable => {:error, :unavailable}, session intact", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev(), [])
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert apply(Nebu.Matrix, :delete_user_device, [s.user_id, s.device_id]) == {:error, :unavailable}
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(s.at).status == 200
    end
  end

  describe "AC7/C12/Must #22 — a deleted legacy device loses its legacy sessions / sync_tokens rows" do
    test "legacy DELETE /devices/{legacy_device} removes the device's sessions + sync_tokens rows" do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      uid = T.provision_user!()
      d = dev()
      _target = T.legacy_session!(uid, d)
      caller = T.legacy_session!(uid, dev())
      now = System.system_time(:millisecond)
      T.sql!("INSERT INTO sessions (session_id, user_id, device_id, last_active_at, created_at) VALUES ($1, $2, $3, $4, $4)", ["atdd-" <> T.rand(6), uid, d, now])
      T.sql!("INSERT INTO sync_tokens (user_id, since_token, updated_at, device_id) VALUES ($1, 's1', $2, $3)", [uid, now, d])

      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> d, caller.at, body: %{}).status == 200
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM sessions WHERE user_id = $1 AND device_id = $2", [uid, d])
      assert %{rows: [[0]]} = T.sql!("SELECT count(*) FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, d])
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 / C13 — kill-switch keeps failed bindings; bound-to-missing-device JWT refused
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/C13 (a) — TokenDenylist.revoke_by_hash/2 result" do
    test ":ok on success, {:error, _} when the DB write fails (still revoked on this node), {:error, :no_exp} without exp" do
      ok_token = "atdd-ok-" <> T.rand()
      assert apply_revoke(T.sha256_hex(ok_token), System.system_time(:second) + 600) == :ok
      assert Nebu.Web.TokenDenylist.revoked?(nil, ok_token)

      bad_token = "atdd-bad-" <> T.rand()
      bad_hash = T.sha256_hex(bad_token)
      _remove = T.fail_denylist_db!(bad_hash)
      assert {:error, _} = apply_revoke(bad_hash, System.system_time(:second) + 600)
      assert Nebu.Web.TokenDenylist.revoked?(nil, bad_token), "the node-local insert always happens"

      assert apply_revoke(T.sha256_hex("atdd-noexp-" <> T.rand()), nil) == {:error, :no_exp}
    end
  end

  describe "AC8/C13 (b) — DeviceBinding.kill_device_jwts/3" do
    test ":ok deletes denylisted bindings; a failed denylist write keeps that row => {:error, :partial} + WARNING without token/hash", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      good = T.bound_jwt!(priv, sub, d)
      bad = T.bound_jwt!(priv, sub, d)
      _remove = T.fail_denylist_db!(DeviceBinding.hash(bad))

      log = capture_log(fn -> send(self(), {:r, apply(DeviceBinding, :kill_device_jwts, [uid, d, []])}) end)
      assert_received {:r, {:error, :partial}}
      assert log =~ "[warning]", "a kept binding is logged as WARNING"
      assert T.binding_rows(uid, d) == 1, "only the successfully denylisted binding is deleted"
      assert Nebu.Web.TokenDenylist.revoked?(nil, good)
      T.refute_secrets_in_log(log, %{good: good, bad: bad, bad_hash: DeviceBinding.hash(bad), good_hash: DeviceBinding.hash(good)})

      d2 = dev()
      only = T.bound_jwt!(priv, sub, d2)
      assert apply(DeviceBinding, :kill_device_jwts, [uid, d2, []]) == :ok
      assert T.binding_rows(uid, d2) == 0
      assert Nebu.Web.TokenDenylist.revoked?(nil, only)
    end

    test "except_hash: the preserved credential keeps its row and is not denylisted; the others are killed", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      keep = T.bound_jwt!(priv, sub, d)
      other = T.bound_jwt!(priv, sub, d)
      assert apply(DeviceBinding, :kill_device_jwts, [uid, d, [except_hash: DeviceBinding.hash(keep)]]) == :ok
      refute Nebu.Web.TokenDenylist.revoked?(nil, keep)
      assert T.binding_exists?(keep), "the preserved row stays"
      refute T.binding_exists?(other)
      assert Nebu.Web.TokenDenylist.revoked?(nil, other)
    end

    test "a binding with exp = nil is KEPT => {:error, :partial} (revoke_by_hash/2 => {:error, :no_exp}); refused via the binding", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      jwt = T.unbound_jwt!(priv, sub)

      T.sql!(
        "INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at) VALUES ($1, $2, $3, NULL, $4)",
        [DeviceBinding.hash(jwt), uid, d, System.system_time(:millisecond)]
      )

      assert apply(DeviceBinding, :kill_device_jwts, [uid, d, []]) == {:error, :partial}
      assert T.binding_exists?(jwt), "fail closed: a binding that cannot be denylisted is kept"
      Nebu.Matrix.DeviceKeyStore.delete_device(uid, d)
      T.forget_node_local_jwt_state!(jwt)
      body = T.whoami(jwt) |> T.assert_unknown_token(false)
      assert body["error"] =~ "Access token has been revoked", "refused through the binding to a missing device"
    end

    test "failing denylist in the PRESERVED own-device branch (raw-JWT caller after a fresh UIA): the other binding is kept", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      caller = T.bound_jwt!(priv, sub, d)
      victim = T.bound_jwt!(priv, sub, d)
      _remove = T.fail_denylist_db!(DeviceBinding.hash(victim))
      sid = T.uia_session!(uid, Nebu.Matrix.Uia.canonical_params([d]), complete: true)

      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> d, caller, body: %{"auth" => %{"type" => "m.login.sso", "session" => sid}})
      assert conn.status == 200, "fresh UIA self-delete of a raw-JWT caller, got #{conn.status}: #{conn.resp_body}"
      assert T.binding_exists?(victim), "the binding whose denylist write failed is kept"
      T.forget_node_local_jwt_state!(victim)
      T.whoami(victim) |> T.assert_unknown_token(false)
    end

    test "failing denylist during POST /delete_devices (legacy caller, fresh window): the binding is kept and refused", %{priv: priv} do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      jwt = T.bound_jwt!(priv, sub, d)
      caller = T.legacy_session!(uid, dev())
      _remove = T.fail_denylist_db!(DeviceBinding.hash(jwt))

      assert T.matrix_request(:post, "/_matrix/client/v3/delete_devices", caller.at, body: %{"devices" => [d]}).status == 200
      assert T.binding_exists?(jwt)
      T.forget_node_local_jwt_state!(jwt)
      body = T.whoami(jwt) |> T.assert_unknown_token(false)
      assert body["error"] =~ "Access token has been revoked"
    end
  end

  describe "AC8/C13 (c)/Must #24, #25, #36 — refused bindings and another node" do
    test "lookup/1: a binding to a device WITHOUT a devices row => {:ok, device, true}; OidcPlug 401 'revoked', no soft_logout", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      jwt = T.unbound_jwt!(priv, sub)

      T.sql!(
        "INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at) VALUES ($1, $2, $3, $4, $5)",
        [DeviceBinding.hash(jwt), uid, d, System.system_time(:second) + 3600, System.system_time(:millisecond)]
      )

      T.forget_node_local_jwt_state!(jwt)
      assert DeviceBinding.lookup(jwt) == {:ok, d, true}
      body = T.whoami(jwt) |> T.assert_unknown_token(false)
      assert body["error"] =~ "Access token has been revoked"
    end

    test "regression: a normal binding with a devices row => {:ok, device, false}", %{priv: priv} do
      sub = T.unique_sub()
      T.provision_user!(sub)
      d = dev()
      jwt = T.bound_jwt!(priv, sub, d)
      T.forget_node_local_jwt_state!(jwt)
      assert DeviceBinding.lookup(jwt) == {:ok, d, false}
      assert T.whoami(jwt).status == 200
    end

    for via <- [:legacy_delete, :admin_delete] do
      test "Must #24 (#{via}): failing denylist write => binding KEPT; the JWT is refused on another node (ETS cleared)", %{priv: priv} do
        T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
        sub = T.unique_sub()
        uid = T.provision_user!(sub)
        d = dev()
        jwt = T.bound_jwt!(priv, sub, d)
        caller = T.legacy_session!(uid, dev())
        _remove = T.fail_denylist_db!(DeviceBinding.hash(jwt))

        case unquote(via) do
          :legacy_delete -> assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> d, caller.at, body: %{}).status == 200
          :admin_delete -> assert Nebu.Matrix.delete_user_device(uid, d) == :ok
        end

        assert T.binding_rows(uid, d) == 1, "the binding whose denylist DB write failed is kept (C13 b)"
        T.forget_node_local_jwt_state!(jwt)
        body = T.whoami(jwt) |> T.assert_unknown_token(false)
        assert body["error"] =~ "Access token has been revoked", "refused through the binding to a deleted device (C13 c)"
      end
    end

    # Green today by design: story 4 already made OAuthSession.kill_bound_jwts/2 keep the bindings when a
    # denylist write fails (through the shared `kill_device_jwts/3` / `revoke_by_hash/2`); story 5 keeps that (regression guard).
    test "Must #24: T7 issuance on a device with a bound JWT and a failing denylist write => the JWT stays refused", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      T.provision_user!(sub)
      d = dev()
      jwt = T.bound_jwt!(priv, sub, d)
      _remove = T.fail_denylist_db!(DeviceBinding.hash(jwt))
      _s = session_on(cid, priv, d, sub: sub)

      T.forget_node_local_jwt_state!(jwt)
      body = T.whoami(jwt) |> T.assert_unknown_token(false)
      assert body["error"] =~ "Access token has been revoked", "binding kept => T25 c refuses the JWT on every node"
    end

    test "Must #25/#36: JWT bound to an admin-deleted device + /keys/upload for that id => 401 revoked, no lazy re-bind", %{priv: priv} do
      for fail_denylist? <- [false, true] do
        sub = T.unique_sub()
        uid = T.provision_user!(sub)
        d = dev()
        jwt = T.bound_jwt!(priv, sub, d)
        remove = if fail_denylist?, do: T.fail_denylist_db!(DeviceBinding.hash(jwt))
        assert Nebu.Matrix.delete_user_device(uid, d) == :ok, "HTTP/admin callers keep their success answer (C13 b)"
        T.forget_node_local_jwt_state!(jwt)

        conn = upload(jwt, upload_body(uid, d))
        body = T.assert_unknown_token(conn, false)
        assert body["error"] =~ "Access token has been revoked", "fail_denylist?=#{fail_denylist?}"
        assert key_rows(uid, d)["device_keys"] == [], "no fresh lazy bind / key write"
        if remove, do: remove.()
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Review cycle 1 — Kassandra L-1 and MINOR 3
  # ════════════════════════════════════════════════════════════════════════════

  describe "Kassandra L-1 — a kept refusal binding cannot be revived through POST /login" do
    defp raw_login(jwt, device_id) do
      Plug.Test.conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => jwt, "device_id" => device_id}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, T.unique_ip())
      |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
    end

    test "(1) a raw JWT on the denylist cannot log in again: 403 M_FORBIDDEN, no device registered, no binding", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      jwt = T.unbound_jwt!(priv, sub)
      exp = System.system_time(:second) + 3600
      :ok = Nebu.Web.TokenDenylist.revoke(nil, jwt, exp)
      d = dev()

      conn = raw_login(jwt, d)
      assert conn.status == 403, "got #{conn.status}: #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_FORBIDDEN"
      assert T.device_gone?(uid, d), "a refused login registers no device"
      assert T.binding_rows(uid, d) == 0
    end

    test "(2) put/4 never re-points an EXISTING binding to another device: refused, the row keeps its device", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d1 = dev()
      d2 = dev()
      jwt = T.bound_jwt!(priv, sub, d1)
      exp = System.system_time(:second) + 3600

      assert apply(DeviceBinding, :put, [jwt, uid, d2, exp]) == {:error, :oauth_device}
      assert T.binding_rows(uid, d1) == 1 and T.binding_rows(uid, d2) == 0

      # the same (user, device) stays idempotent and refreshes exp
      assert apply(DeviceBinding, :put, [jwt, uid, d1, exp + 60]) == :ok
      assert T.binding_rows(uid, d1) == 1
    end

    test "(2) a kept binding survives a recreated device id: login with the same JWT for ANOTHER device => 500, binding not re-pointed", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d1 = dev()
      d2 = dev()
      jwt = T.bound_jwt!(priv, sub, d1)

      conn = raw_login(jwt, d2)
      assert conn.status == 500 and Jason.decode!(conn.resp_body) == @login_failed
      assert T.binding_rows(uid, d1) == 1 and T.binding_rows(uid, d2) == 0
    end
  end

  describe "MINOR 3 — the preserved own-device path is fail closed after the lookup-cache TTL" do
    test "a raw-JWT caller that deleted its OWN device after a fresh UIA finishes the request, then its JWT is refused (401 revoked, no soft_logout)", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      caller = T.bound_jwt!(priv, sub, d)
      sid = T.uia_session!(uid, Nebu.Matrix.Uia.canonical_params([d]), complete: true)

      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> d, caller, body: %{"auth" => %{"type" => "m.login.sso", "session" => sid}})
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      assert T.binding_exists?(caller), "the preserved credential keeps its binding row (not denylisted)"
      assert T.device_gone?(uid, d)

      # simulate the end of the node's 60 s binding-lookup cache: the binding now points at a missing device
      T.forget_node_local_jwt_state!(caller)
      body = T.whoami(caller) |> T.assert_unknown_token(false)
      assert body["error"] =~ "Access token has been revoked"
    end
  end
end
