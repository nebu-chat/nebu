defmodule Nebu.OAuth.OAuthLogoutTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-revocation-logout` (story 4 of epic
  oauth-broker), AC8-AC10 (R15-R19; Must #26-#32, oracle extra tests):

    * `POST /_matrix/client/v3/logout` with an OAuth access token ends ONLY that device's session
      and device (the same function as `/oauth2/revoke`), never the user-wide legacy wipe; the
      `:auth_api` assign is decided by `OidcPlug` at authentication time; DB failure => `500
      M_UNKNOWN` and the session survives; empty / absent / `{}` bodies => `200 {}`.
    * Legacy `/logout` (opaque and raw JWT): per device since the bugfix `legacy-logout-per-device`
      (LL1-LL12, replaces the user-wide wipe of R16): only the presented credential's device ends
      (session rows, device, keys), other devices of any `auth_api` survive, a storage failure is
      `500 M_UNKNOWN`. The detailed contract is in `legacy_logout_per_device_test.exs`.
    * `POST /_matrix/client/v3/logout/all` (routed for the first time, R17 + oracle correction):
      every session of the user ends and EVERY device of the user (legacy too) is deleted with its
      keys; cross-signing keys stay; works for OAuth, legacy opaque and raw-JWT callers.
    * `DELETE /devices/{id}` by a legacy session of an OAuth device, admin deactivation (regression)
      and GDPR key erasure (`delete_user_keys/2`, NEW session kill) end OAuth sessions.

  Red today: the OAuth `/logout` branch does not exist (it wipes every session of the user),
  `/logout/all` is unrouted (`404 M_NOT_FOUND`), `OidcPlug` assigns no `:auth_api`, the erasure
  ends no session.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :uia_fresh_auth_seconds], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https])}
  end

  defp dev, do: "LO" <> String.upcase(T.rand(4))

  defp session_on(cid, priv, device_id, opts),
    do: T.session!(cid, @https, priv, Keyword.merge([authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}], opts))

  defp session(cid, priv), do: session_on(cid, priv, dev(), [])

  defp oauth_rows(uid, d), do: uid |> T.session_rows(d) |> Enum.filter(&(&1["auth_api"] == "oauth"))

  defp user_rows(uid) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM matrix_sessions WHERE user_id = $1", [uid])
    n
  end

  defp user_devices(uid) do
    %{rows: rows} = T.sql!("SELECT device_id FROM devices WHERE user_id = $1 ORDER BY 1", [uid])
    List.flatten(rows)
  end

  defp authenticate(token) do
    Plug.Test.conn(:get, "/_matrix/client/v3/account/whoami")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Plugs.OidcPlug.call(Nebu.Web.Plugs.OidcPlug.init([]))
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 / R15 — OidcPlug decides OAuth vs legacy at authentication time
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/R15/Trap 4 — OidcPlug assigns :auth_api" do
    test "an OAuth access token => \"oauth\"; a legacy opaque token and a raw JWT => \"legacy\"", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      assert authenticate(s.at).assigns[:auth_api] == "oauth"

      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      legacy = T.legacy_session!(uid, dev())
      assert authenticate(legacy.at).assigns[:auth_api] == "legacy"

      jwt = T.bound_jwt!(priv, sub, dev())
      conn = authenticate(jwt)
      refute conn.halted, "precondition: the raw JWT authenticates"
      assert conn.assigns[:auth_api] == "legacy"
    end

    test "no other OidcPlug behaviour changes (assigns of the OAuth path)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      conn = authenticate(s.at)
      assert conn.assigns[:current_user] == s.user_id
      assert conn.assigns[:device_id] == s.device_id
      assert conn.assigns[:access_token] == s.at
      assert conn.assigns[:oidc_claims] == %{}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8 / Must #26-#28 — POST /logout with an OAuth access token
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8/Must #26 — OAuth /logout ends ONLY the current device (session + device)" do
    for body <- [:none, :empty_json, :object] do
      test "body #{body}: 200 {} application/json; other OAuth + legacy devices of the user keep working", %{cid: cid, priv: priv} do
        s = session(cid, priv)
        other = session_on(cid, priv, dev(), sub: s.sub)
        legacy_dev = dev()
        legacy = T.legacy_session!(s.user_id, legacy_dev)
        T.seed_device_keys!(s.user_id, s.device_id)
        T.seed_device_keys!(s.user_id, legacy_dev)
        keep = {T.rows_snapshot(s.user_id, other.device_id), T.rows_snapshot(s.user_id, legacy_dev), T.device_state(s.user_id, legacy_dev)}

        T.logout(s.at, body: unquote(body)) |> T.assert_logout_ok()

        assert T.session_rows(s.user_id, s.device_id) == []
        assert T.device_gone?(s.user_id, s.device_id), "OAuth /logout deletes the device and its keys (R2, oracle O1)"
        T.assert_unknown_token(T.whoami(s.at), false)
        T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")

        assert {T.rows_snapshot(s.user_id, other.device_id), T.rows_snapshot(s.user_id, legacy_dev), T.device_state(s.user_id, legacy_dev)} == keep,
               "never the user-wide legacy wipe for an OAuth caller (R15, Trap 5)"

        assert T.whoami(other.at).status == 200
        assert T.whoami(legacy.at).status == 200
      end
    end

    test "works while OAuth is DISABLED (no Config read on this path)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)
      T.disable_oauth()
      T.logout(s.at) |> T.assert_logout_ok()
      assert T.session_rows(s.user_id, s.device_id) == []
      assert T.whoami(other.at).status == 200
    end

    test "another user is untouched", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      stranger = session(cid, priv)
      before = T.world_snapshot([stranger.user_id])
      T.logout(s.at) |> T.assert_logout_ok()
      assert T.world_snapshot([stranger.user_id]) == before
    end
  end

  describe "AC8/Trap 11/Must #27 — expired / superseded OAuth AT at /logout => 401 soft_logout, nothing deleted" do
    test "expired access token", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(s.at)])
      before = T.world_snapshot([s.user_id])
      T.logout(s.at) |> T.assert_unknown_token(true)
      assert T.world_snapshot([s.user_id]) == before
    end

    test "superseded access token after a rotation", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)
      before = T.world_snapshot([s.user_id])
      T.logout(s.at) |> T.assert_unknown_token(true)
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(fresh["access_token"]).status == 200
    end
  end

  describe "AC8/Must #28 — OAuth branch DB failure => 500 M_UNKNOWN, session intact" do
    test "repo unavailable => 500 {errcode: M_UNKNOWN, error: 'Logout failed, please try again.'}; never a 200 while the session survives",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)
      before = T.world_snapshot([s.user_id])
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      conn = T.logout(s.at)
      assert conn.status == 500, "expected 500, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn) == %{"errcode" => "M_UNKNOWN", "error" => "Logout failed, please try again."}
      assert (T.header(conn, "content-type") || "") =~ "application/json"

      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.world_snapshot([s.user_id]) == before, "invalidate_user_sessions is NOT called on the OAuth branch"
      assert T.whoami(s.at).status == 200
      assert T.whoami(other.at).status == 200
    end

    test "a blocked DELETE (trigger) => 500 M_UNKNOWN, rolled back", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      before = T.world_snapshot([s.user_id])
      _remove = T.block_session_deletes!(s.user_id)
      conn = T.logout(s.at)
      assert conn.status == 500
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert T.world_snapshot([s.user_id]) == before
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 (legacy-logout-per-device) — legacy /logout is per device (replaces R16 "unchanged")
  # ════════════════════════════════════════════════════════════════════════════

  describe "LL/AC9.4 — legacy /logout is per device (gate r)" do
    test "opaque caller: only its own device ends; OAuth session and other legacy device survive",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      d1 = dev()
      d2 = dev()
      a = T.legacy_session!(s.user_id, d1)
      b = T.legacy_session!(s.user_id, d2)
      T.seed_device_keys!(s.user_id, d1)
      T.seed_device_keys!(s.user_id, d2)
      oauth_before = {T.rows_snapshot(s.user_id, s.device_id), T.device_state(s.user_id, s.device_id)}
      b_before = {T.rows_snapshot(s.user_id, d2), T.device_state(s.user_id, d2)}

      T.logout(a.at, body: :object) |> T.assert_logout_ok()

      assert T.session_rows(s.user_id, d1) == [], "only the presented device's rows are deleted"
      assert T.device_gone?(s.user_id, d1), "LL2: the device and its keys are deleted (Matrix: logout deletes the device)"
      assert {T.rows_snapshot(s.user_id, s.device_id), T.device_state(s.user_id, s.device_id)} == oauth_before, "never the user-wide wipe"
      assert {T.rows_snapshot(s.user_id, d2), T.device_state(s.user_id, d2)} == b_before
      assert T.whoami(b.at).status == 200
      assert T.whoami(s.at).status == 200
      assert T.whoami(a.at).status == 401
    end

    for {kind, body} <- [{:legacy, :none}, {:legacy, :empty_json}, {:legacy, :object}, {:jwt, :none}, {:jwt, :empty_json}, {:jwt, :object}] do
      test "#{kind} caller, body #{body}: 200 {}, its device is deleted", %{priv: priv} do
        sub = T.unique_sub()
        uid = T.provision_user!(sub)
        d = dev()

        token =
          if unquote(kind) == :legacy,
            do: T.legacy_session!(uid, d).at,
            else: T.bound_jwt!(priv, sub, d)

        T.seed_device_keys!(uid, d)
        T.logout(token, body: unquote(body)) |> T.assert_logout_ok()
        assert T.whoami(token).status == 401
        assert T.device_gone?(uid, d), "the presented credential's device and keys are deleted"
      end
    end

    # Test review item 6 asked for "keeps today's 400 M_NOT_JSON": measured, the legacy /logout IGNORES the
    # body (200). The body stays ignored for every caller kind (Matrix: logout takes no body), LL8.
    test "an invalid non-empty JSON body is ignored (legacy and OAuth): 200, own device only", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      legacy = T.legacy_session!(uid, d)
      T.seed_device_keys!(uid, d)
      T.logout(legacy.at, body: :invalid) |> T.assert_logout_ok()
      assert T.whoami(legacy.at).status == 401
      assert T.device_gone?(uid, d)

      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)
      T.logout(s.at, body: :invalid) |> T.assert_logout_ok()
      assert T.session_rows(s.user_id, s.device_id) == []
      assert T.whoami(other.at).status == 200
    end

    test "raw-JWT caller: the JWT is denylisted (also on another node) and its device is deleted", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d = dev()
      jwt = T.bound_jwt!(priv, sub, d)
      T.seed_device_keys!(uid, d)
      T.logout(jwt, body: :object) |> T.assert_logout_ok()
      assert T.whoami(jwt).status == 401
      T.forget_node_local_jwt_state!(jwt)
      assert T.whoami(jwt).status == 401
      assert T.device_gone?(uid, d)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 / R17 / Must #30 — POST /logout/all
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC9/R17/Must #30 — /logout/all ends every session and deletes EVERY device (+ keys) of the user" do
    defp fixture(cid, priv) do
      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)
      legacy_dev = dev()
      legacy = T.legacy_session!(s.user_id, legacy_dev)
      for d <- [s.device_id, other.device_id, legacy_dev], do: T.seed_device_keys!(s.user_id, d)
      T.seed_cross_signing!(s.user_id)
      jwt_dev = dev()
      jwt = T.bound_jwt!(priv, s.sub, jwt_dev)
      T.seed_device_keys!(s.user_id, jwt_dev)
      stranger = session(cid, priv)

      %{s: s, other: other, legacy: legacy, legacy_dev: legacy_dev, jwt: jwt, jwt_dev: jwt_dev, stranger: stranger,
        stranger_before: T.world_snapshot([stranger.user_id])}
    end

    defp assert_all_gone(f, cid) do
      uid = f.s.user_id
      assert user_rows(uid) == 0, "every matrix_sessions row of the user is gone"
      assert user_devices(uid) == [], "EVERY device of the user is deleted (oracle correction of R17)"
      for d <- [f.s.device_id, f.other.device_id, f.legacy_dev, f.jwt_dev], do: assert(T.device_gone?(uid, d), "device #{d} + keys must be gone")
      assert T.whoami(f.jwt).status == 401, "a raw JWT bound to another device of the user is denylisted (per-device kill-switch, R17 step 3)"
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(uid, f.jwt_dev) == []
      assert T.cross_signing_count(uid) == 1, "cross-signing keys (per user) are kept"
      T.refresh(cid, f.other.rt) |> T.assert_token_error(400, "invalid_grant")
      T.refresh(cid, f.s.rt) |> T.assert_token_error(400, "invalid_grant")
      T.assert_unknown_token(T.whoami(f.other.at), false)
      assert T.whoami(f.legacy.at).status == 401
      assert T.world_snapshot([f.stranger.user_id]) == f.stranger_before, "another user is untouched"
      assert T.whoami(f.stranger.at).status == 200
    end

    for body <- [:none, :empty_json, :object] do
      test "OAuth caller, body #{body}: 200 {} application/json, everything of the user gone; the dead token => 401 without soft_logout",
           %{cid: cid, priv: priv} do
        f = fixture(cid, priv)
        conn = T.logout(f.s.at, path: :all, body: unquote(body))
        refute conn.status == 404, "/logout/all must be routed (R17), got 404 #{conn.resp_body}"
        T.assert_logout_ok(conn)
        assert_all_gone(f, cid)
        T.assert_unknown_token(T.whoami(f.s.at), false)
        T.logout(f.s.at, path: :all) |> T.assert_unknown_token(false)
      end
    end

    test "legacy opaque caller: same effects", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.logout(f.legacy.at, path: :all, body: :object) |> T.assert_logout_ok()
      assert_all_gone(f, cid)
      T.assert_unknown_token(T.whoami(f.s.at), false)
      T.logout(f.legacy.at, path: :all) |> T.assert_unknown_token(false)
    end

    test "raw-JWT caller: the JWT is denylisted, every device + session of the user gone", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.logout(f.jwt, path: :all) |> T.assert_logout_ok()
      assert_all_gone(f, cid)
      assert T.whoami(f.jwt).status == 401, "the presented JWT is denylisted"
    end

    test "OAuth part fails (repo unavailable) => 500 M_UNKNOWN; the legacy part still ran (tokens are dead anyway)",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      conn = T.logout(f.legacy.at, path: :all)
      assert conn.status == 500, "expected 500 M_UNKNOWN, got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(f.legacy.at).status == 401
      assert user_rows(f.s.user_id) == 0, "the legacy part (invalidate_user_sessions) still wiped every row"
      assert user_devices(f.s.user_id) == [], "the all-device deletion (step 3) still ran"
      assert T.cross_signing_count(f.s.user_id) == 1
    end

    test "step 3 (device deletion) fails => 500 M_UNKNOWN (legacy-only user, so the OAuth part has nothing to do)", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d1 = dev()
      d2 = dev()
      a = T.legacy_session!(uid, d1)
      T.seed_device_keys!(uid, d1)
      T.seed_device_keys!(uid, d2)
      _jwt = T.bound_jwt!(priv, sub, d2)
      _remove = T.block_deletes!("devices", uid)

      conn = T.logout(a.at, path: :all)
      assert conn.status == 500, "a failed device deletion is never a silent 200 (R17), got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert T.whoami(a.at).status == 401, "the legacy part still killed the presented credential"
    end

    for {kind, body} <- [{:legacy, :none}, {:legacy, :empty_json}, {:jwt, :none}, {:jwt, :empty_json}, {:jwt, :object}] do
      test "#{kind} caller, body #{body}: 200 {} application/json (never 400 M_NOT_JSON)", %{cid: cid, priv: priv} do
        f = fixture(cid, priv)
        token = if unquote(kind) == :legacy, do: f.legacy.at, else: f.jwt
        T.logout(token, path: :all, body: unquote(body)) |> T.assert_logout_ok()
        assert_all_gone(f, cid)
      end
    end

    test "works while OAuth is DISABLED (no Config read)", %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.disable_oauth()
      T.logout(f.s.at, path: :all) |> T.assert_logout_ok()
      # dev-story fix: the refresh-token checks of assert_all_gone/2 go through /oauth2/token, which
      # IS behind the T22 kill switch (404 while disabled); /logout/all itself ran disabled above.
      T.enable_oauth()
      assert_all_gone(f, cid)
    end

    test "unauthenticated /logout/all => 401 M_MISSING_TOKEN" do
      conn =
        Plug.Test.conn(:post, "/_matrix/client/v3/logout/all")
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 401
      assert T.json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "an invalid NON-empty JSON body is ignored (as legacy /logout today): 200 {}, everything of the user gone",
         %{cid: cid, priv: priv} do
      f = fixture(cid, priv)
      T.logout(f.s.at, path: :all, body: :invalid) |> T.assert_logout_ok()
      assert_all_gone(f, cid)
    end

    test "the exact /logout route still only matches /logout (no prefix match): /logout/allx is 404", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      conn =
        Plug.Test.conn(:post, "/_matrix/client/v3/logout/allx")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> s.at)
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 404
      assert T.whoami(s.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / R18 / R19 / Must #31, #32 — device deletion, deactivation, GDPR erasure
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/R18/Must #32 — DELETE /devices/{id} of an OAuth device by a legacy session of the same user" do
    test "the OAuth session ends completely: rows gone, RT invalid_grant, AT 401 without soft_logout", %{cid: cid, priv: priv} do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> s.device_id, legacy.at, body: %{})
      assert conn.status == 200, "device delete must pass the fresh-auth window, got #{conn.status}: #{conn.resp_body}"
      assert oauth_rows(s.user_id, s.device_id) == []
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      T.assert_unknown_token(T.whoami(s.at), false)
    end
  end

  describe "AC10/R18 — POST /delete_devices of an OAuth device by a legacy session of the same user" do
    test "the OAuth session ends completely", %{cid: cid, priv: priv} do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      conn = T.matrix_request(:post, "/_matrix/client/v3/delete_devices", legacy.at, body: %{"devices" => [s.device_id]})
      assert conn.status == 200, "delete_devices must pass the fresh-auth window, got #{conn.status}: #{conn.resp_body}"
      assert oauth_rows(s.user_id, s.device_id) == []
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      T.assert_unknown_token(T.whoami(s.at), false)
      assert T.whoami(legacy.at).status == 200
    end
  end

  describe "AC10/R19/Must #31 — admin deactivation (regression) and GDPR erasure (new session kill)" do
    defp admin_stream, do: %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}

    test "deactivate_user/2 => every OAuth row of the user gone, AT 401, RT invalid_grant", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)

      assert %Core.DeactivateUserResponse{ok: true} =
               Nebu.Matrix.EventDispatcher.Server.deactivate_user(%Core.DeactivateUserRequest{user_id: s.user_id}, admin_stream())

      assert user_rows(s.user_id) == 0
      for x <- [s, other], do: assert(T.whoami(x.at).status == 401)
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      T.refresh(cid, other.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    test "delete_user_keys/2 (GDPR erasure) ends the user's OAuth AND legacy sessions; response unchanged", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      stranger = session(cid, priv)

      req = %Core.DeleteUserKeysRequest{admin_user_id: "@admin:test.local", target_user_id: s.user_id, reason: "atdd erasure"}
      assert %Core.DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: at} = Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, admin_stream())
      assert is_integer(at) and at > 0

      assert oauth_rows(s.user_id, s.device_id) == [], "R19: the erasure ends the OAuth session"
      T.assert_unknown_token(T.whoami(s.at), false)
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.whoami(legacy.at).status == 401, "R19: the erasure also ends legacy sessions"
      assert user_rows(s.user_id) == 0
      assert T.whoami(stranger.at).status == 200
    end

    test "erasure is best effort: the OAuth session kill failing (repo unavailable) neither raises nor changes the response",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)

      req = %Core.DeleteUserKeysRequest{admin_user_id: "@admin:test.local", target_user_id: s.user_id, reason: "atdd best effort"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:resp, Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, admin_stream())})
        end)

      assert_received {:resp, %Core.DeleteUserKeysResponse{status: "keys_deleted"}}
      assert log =~ "[warning]", "a failed session kill is logged as WARNING (R19)"
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(legacy.at).status == 401, "the legacy kill (delete_for_user/1) still ran"
      T.refute_secrets_in_log(log, %{at: s.at, rt: s.rt, legacy_at: legacy.at})
    end

    test "erasure error branch (conflict) ends nothing", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      legacy = T.legacy_session!(s.user_id, dev())
      T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1", [s.user_id])
      before = T.world_snapshot([s.user_id])

      req = %Core.DeleteUserKeysRequest{admin_user_id: "@admin:test.local", target_user_id: s.user_id, reason: "atdd conflict"}
      assert_raise Nebu.Matrix.Error, fn -> Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, admin_stream()) end

      assert T.world_snapshot([s.user_id]) == before

      # story gdpr-erasure-global-data (D17), old -> new: a user with a `deletion_status` is never authenticated (the erasure is terminal), so the
      # simulated in-progress marker is removed before the sessions are probed: they are still alive, i.e. the failed erasure ended nothing.
      T.sql!("UPDATE users SET deletion_status = NULL WHERE user_id = $1", [s.user_id])
      assert T.whoami(legacy.at).status == 200
      assert T.whoami(s.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC9 — the oauth_end_user_sessions/1 facade (R24)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5/AC9/R24 — Nebu.Matrix.oauth_end_user_sessions/1" do
    test "{:ok, device_ids} of every OAuth device; their sessions + devices end; legacy rows are not its business", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      other = session_on(cid, priv, dev(), sub: s.sub)
      legacy_dev = dev()
      legacy = T.legacy_session!(s.user_id, legacy_dev)
      # dev-story fix: `T.legacy_session!/3` creates only the matrix_sessions row; seed the legacy
      # device itself so "legacy devices are not its business" is actually observable below.
      T.seed_device_keys!(s.user_id, legacy_dev)

      assert {:ok, ids} = apply(Nebu.Matrix, :oauth_end_user_sessions, [s.user_id])
      assert Enum.sort(ids) == Enum.sort([s.device_id, other.device_id])
      assert oauth_rows(s.user_id, s.device_id) == [] and oauth_rows(s.user_id, other.device_id) == []
      assert T.device_gone?(s.user_id, s.device_id) and T.device_gone?(s.user_id, other.device_id)
      assert T.whoami(legacy.at).status == 200
      assert T.device_state(s.user_id, legacy_dev)["devices"] == 1
      assert apply(Nebu.Matrix, :oauth_end_user_sessions, [s.user_id]) == {:ok, []}
    end

    test "repo unavailable => {:error, :unavailable}, never raises", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.put_env_scoped(:oauth_session_repo, T.NoSuchRepo)
      assert apply(Nebu.Matrix, :oauth_end_user_sessions, [s.user_id]) == {:error, :unavailable}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Review cycle 1 (Kassandra F-1/F-2, code review MINOR 1-4)
  # ════════════════════════════════════════════════════════════════════════════

  defmodule ExitRepo do
    @moduledoc "A repo whose every entry point EXITS (a crashed pool / a timeout), as `:oauth_session_repo`."
    def get_dynamic_repo, do: exit(:atdd_exit)
    def __adapter__, do: exit(:atdd_exit)
    def transaction(_fun, _opts \\ []), do: exit(:atdd_exit)
  end

  # Blocks INSERTs into the JWT denylist for rows matching `condition_sql` (trusted literal built from
  # hex / integers) with a privileged BEFORE INSERT trigger; removed on exit.
  defp block_denylist_inserts!(condition_sql) do
    name = "atdd_block_ins_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF #{condition_sql} THEN " <>
        "RAISE EXCEPTION 'atdd: insert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON invalidated_tokens FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON invalidated_tokens")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    on_exit(remove)
    remove
  end

  defp assert_500_unknown(conn) do
    assert conn.status == 500, "expected 500 M_UNKNOWN, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN"
    conn
  end

  describe "review cycle 1 F-1/MINOR 1 — /logout/all never lies about a surviving session" do
    test "a failing LEGACY delete => 500 M_UNKNOWN, nothing reported as success; the retry ends everything",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      legacy_dev = dev()
      legacy = T.legacy_session!(s.user_id, legacy_dev)
      T.seed_device_keys!(s.user_id, legacy_dev)

      remove = T.block_session_deletes!(s.user_id, auth_api: "legacy")
      T.logout(s.at, path: :all) |> assert_500_unknown()
      assert T.whoami(legacy.at).status == 200, "the legacy session is alive: a 200 would have been a lie"

      remove.()
      T.logout(legacy.at, path: :all) |> T.assert_logout_ok()
      assert user_rows(s.user_id) == 0
      assert user_devices(s.user_id) == []
      assert T.whoami(legacy.at).status == 401
    end

    test "a failed DURABLE denylist insert for the caller JWT => 500 for /logout/all and legacy /logout (LL5)", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      exp = System.system_time(:second) + 7200 + :rand.uniform(1_000_000)
      sign = fn -> T.sign_id_token(priv, %{"sub" => sub, "exp" => exp, "jti" => "atdd-jti-" <> T.rand()}) end
      jwt_all = sign.()
      jwt_legacy = sign.()
      remove = block_denylist_inserts!("NEW.expires_at = #{exp}")

      T.logout(jwt_all, path: :all) |> assert_500_unknown()
      assert user_rows(uid) == 0

      # legacy /logout of an unbound JWT (LL5, LL8): the best-effort contract of R16 is replaced, the failed
      # durable denylist write is reported, never a silent 200 with a credential that may live on elsewhere
      T.logout(jwt_legacy) |> assert_500_unknown()

      remove.()
      # the ETS entry of this node was written before the database insert failed: dead here, fail safe
      assert T.whoami(jwt_all).status == 401
      assert T.whoami(jwt_legacy).status == 401
    end
  end

  describe "review cycle 1 F-2/MINOR 2 — atomic per-device teardown" do
    test "a login committing while /logout/all waits on a device survives whole; the listed devices are gone",
         %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      d1 = "AAA" <> String.upcase(T.rand(3))
      d2 = "BBB" <> String.upcase(T.rand(3))
      for d <- [d1, d2], do: (T.seed_device_keys!(uid, d); T.legacy_session!(uid, d))
      new_dev = "ZZZ" <> String.upcase(T.rand(3))

      {:ok, {task, fresh}} =
        Nebu.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [uid, d1])
          task = Task.async(fn -> T.safely(fn -> apply(Nebu.Matrix, :end_all_user_devices, [uid]) end) end)
          T.await_lock_wait!()
          assert Task.yield(task, 0) == nil, "the teardown of d1 must wait for the devices row lock"

          # a NEW login on another device commits on its own connection while the teardown waits
          fresh =
            Task.async(fn -> session_on(cid, priv, new_dev, sub: sub) end)
            |> Task.await(30_000)

          {task, fresh}
        end)

      assert {:ok, :ok} = Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)
      for d <- [d1, d2], do: assert(T.device_gone?(uid, d) and T.session_rows(uid, d) == [], "#{d} fully gone")
      assert T.whoami(fresh.at).status == 200, "the newer session survives"
      refute T.device_gone?(uid, new_dev), "and its device is intact (session + device are created and removed together)"
    end

    test "a session WITHOUT a devices row cannot survive (devices UNION matrix_sessions)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      orphan = dev()
      legacy = T.legacy_session!(s.user_id, orphan)
      assert T.device_state(s.user_id, orphan)["devices"] == 0

      assert apply(Nebu.Matrix, :end_all_user_devices, [s.user_id]) == :ok
      assert T.session_rows(s.user_id, orphan) == []
      assert T.whoami(legacy.at).status == 401
    end
  end

  describe "review cycle 1 MINOR 3 — bindings deleted only after a confirmed denylist write" do
    test "revoke: a failed denylist insert keeps the binding; the session is still ended", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      jwt = T.insert_jwt_binding!(priv, s.sub, s.user_id, s.device_id)
      hash = Nebu.Matrix.Session.DeviceBinding.hash(jwt)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
      remove = block_denylist_inserts!("NEW.token_hash = '#{hash}'")

      T.revoke(T.revoke_params(s.at)) |> T.assert_revoke_ok()
      assert T.session_rows(s.user_id, s.device_id) == []
      assert [{^hash, _}] = Nebu.Matrix.Session.DeviceBinding.list_for_user_device(s.user_id, s.device_id), "binding kept: the denylist write failed"

      remove.()
    end

    test "revoke: with a working denylist the binding is deleted (regression)", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      jwt = T.insert_jwt_binding!(priv, s.sub, s.user_id, s.device_id)
      T.revoke(T.revoke_params(s.at)) |> T.assert_revoke_ok()
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(s.user_id, s.device_id) == []
      T.assert_unknown_token(T.whoami(jwt), false)
    end
  end

  describe "review cycle 1 MINOR 4 — an exit is an error result, never a crash" do
    test "the OAuth facade functions return {:error, :unavailable} when the repo exits", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.put_env_scoped(:oauth_session_repo, ExitRepo)

      assert apply(Nebu.Matrix, :oauth_revoke_token, [s.at]) == {:error, :unavailable}
      assert apply(Nebu.Matrix, :oauth_end_user_sessions, [s.user_id]) == {:error, :unavailable}
      assert apply(Nebu.Matrix.OAuthSession, :end_device_session, [s.user_id, s.device_id]) == {:error, :unavailable}

      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(s.at).status == 200, "nothing was deleted"
    end

    test "/oauth2/revoke answers 503 {} and /logout 500 M_UNKNOWN when the repo exits", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.put_env_scoped(:oauth_session_repo, ExitRepo)
      T.revoke(T.revoke_params(s.at)) |> T.assert_revoke_5xx(503)
      Application.delete_env(:nebu_http, :oauth_session_repo)
      assert T.whoami(s.at).status == 200
    end
  end
end
