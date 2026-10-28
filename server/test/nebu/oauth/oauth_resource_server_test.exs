defmodule Nebu.OAuth.OAuthResourceServerTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3 of epic oauth-broker):
  Nebu as RESOURCE server for OAuth sessions (AC16, T3, T25) and the legacy isolation /
  regressions (AC17, T26, T27). Must-test #12, #13, #28, #29.

  Every OAuth session is created through the REAL flow (authorize -> IdP stub -> callback ->
  `POST /oauth2/token`), so all tests are red today for the right reason: `/oauth2/token` is the
  router's plain 404 (no token endpoint, no `auth_api` column, no `OAuthSessionStore`). The
  pinned new API used here is `Nebu.Matrix.Session.DeviceBinding.lookup/1 :: {:ok, device_id | nil,
  oauth_device? :: boolean}` (called via `apply/3`).

  Deterministic: expiry is set via SQL on `matrix_sessions` (no sleeps); the RefreshWorker runs
  exactly one forced cycle (`send(pid, :refresh)` + `:sys.get_state/1`).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @https "https://app.example.com/cb"
  @worker Nebu.Matrix.Session.RefreshWorker

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_user_active_override, :matrix_refresh_worker_lookahead_seconds],
          do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https, "http://localhost/cb"])}
  end

  defp dev, do: "DEV" <> String.upcase(T.rand(4))

  defp session_on(cid, priv, device_id, opts \\ []) do
    T.session!(cid, @https, priv, Keyword.merge([authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), device_id)}], opts))
  end

  defp assert_unknown_token(conn, soft_logout?) do
    assert conn.status == 401, "expected 401, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
    body = T.json(conn)
    assert body["errcode"] == "M_UNKNOWN_TOKEN"

    if soft_logout?,
      do: assert(body["soft_logout"] == true, "expected soft_logout: true, got #{inspect(body)}"),
      else: refute(body["soft_logout"] == true, "a destroyed/unknown session must NOT be soft_logout: #{inspect(body)}")

    body
  end

  defp oauth_rows(uid, device_id), do: uid |> T.session_rows(device_id) |> Enum.filter(&(&1["auth_api"] == "oauth"))

  defp binding_count(jwt) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM jwt_device_bindings WHERE token_hash = $1", [Nebu.Matrix.Session.DeviceBinding.hash(jwt)])
    n
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC16 — OAuth access tokens authenticate Matrix requests (OidcPlug opaque path)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC16/AC8 — whoami and /sync with an OAuth access token (must-test 12)" do
    test "whoami returns user_id, device_id and is_guest false", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)
      conn = T.whoami(s.at)
      assert conn.status == 200, "whoami must accept the OAuth AT, got #{conn.status}"
      assert T.json(conn) == %{"user_id" => s.user_id, "device_id" => d, "is_guest" => false}
    end

    test "/sync works with the OAuth access token", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      assert T.sync(s.at).status == 200
    end

    test "the OAuth access token is opaque 64 hex (no dot => OidcPlug opaque path, Trap 1)", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      assert s.at =~ ~r/\A[0-9a-f]{64}\z/
      refute String.contains?(s.at, ".")
    end
  end

  describe "AC16 — expiry and token states (must-test 13, oracle extra tests)" do
    test "an expired OAuth access token => 401 M_UNKNOWN_TOKEN soft_logout: true", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      T.sql!("UPDATE matrix_sessions SET expires_at = now() - interval '1 second' WHERE access_token_hash = $1", [T.token_hash(s.at)])
      assert_unknown_token(T.whoami(s.at), true)
    end

    test "a superseded (rotated-away) OAuth access token => 401 soft_logout: true", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)
      refute fresh["access_token"] == s.at
      assert_unknown_token(T.whoami(s.at), true)
      assert T.whoami(fresh["access_token"]).status == 200
    end

    test "an unknown 64-hex token => 401 M_UNKNOWN_TOKEN WITHOUT soft_logout" do
      assert_unknown_token(T.whoami(Store.generate_opaque_token()), false)
    end

    test "a refresh token presented as Bearer => 401 M_UNKNOWN_TOKEN WITHOUT soft_logout, session intact", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      before = T.rows_snapshot(s.user_id, s.device_id)
      assert_unknown_token(T.whoami(s.rt), false)
      assert T.rows_snapshot(s.user_id, s.device_id) == before
      assert T.whoami(s.at).status == 200
    end

    test "a deactivated user => 401 M_UNKNOWN_TOKEN soft_logout (existing deactivation branch)", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      T.sql!("UPDATE users SET is_active = false WHERE user_id = $1", [s.user_id])
      assert_unknown_token(T.whoami(s.at), true)
    end
  end

  describe "AC16/T10 — the first request with the new AT consumes the pending old RT (end to end, must-test 15)" do
    test "old RT works until the new AT is used; afterwards it is reuse => invalid_grant and the session is revoked", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      T.idp_refresh_ok(s.sub)
      fresh = T.refresh!(cid, s.rt)

      [pending] = s.user_id |> T.session_rows(s.device_id) |> Enum.filter(&(&1["refresh_token_hash"] == T.token_hash(s.rt)))
      assert pending["revoked_at"] != nil and pending["grace_until"] == nil, "old row is PENDING after the rotation"

      assert T.whoami(fresh["access_token"]).status == 200
      consumed = T.row_by_rt(s.rt)
      assert consumed["grace_until"] != nil, "the first request with the new AT consumes the old RT"

      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
      assert oauth_rows(s.user_id, s.device_id) == [], "reuse revokes every OAuth row of the device"
      assert_unknown_token(T.whoami(fresh["access_token"]), false)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T25 — no IdP JWT for OAuth devices (spec 2)
  # ════════════════════════════════════════════════════════════════════════════

  describe "T25 (a) — a legacy raw JWT bound to the device is killed at issuance (must-test 10, 29)" do
    test "JWT works before, 401 'Access token has been revoked' after the OAuth session took the device", %{cid: cid, priv: priv} do
      d = dev()
      sub = T.unique_sub()
      T.provision_user!(sub)
      jwt = T.bound_jwt!(priv, sub, d)
      before = T.whoami(jwt)
      assert before.status == 200
      assert T.json(before)["device_id"] == d

      _s = session_on(cid, priv, d, sub: sub)

      body = assert_unknown_token(T.whoami(jwt), false)
      assert body["error"] =~ "Access token has been revoked"
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(T.user_id_for(%{"sub" => sub}), d) == []
    end
  end

  describe "T25 (b) — DeviceBinding.put/4 refuses to bind a JWT to an OAuth device" do
    test "put/4 for an OAuth device stores no row (and no cache entry)", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)
      exp = System.system_time(:second) + 3600
      jwt = T.sign_id_token(priv, %{"sub" => s.sub, "exp" => exp})

      _ = apply(Nebu.Matrix.Session.DeviceBinding, :put, [jwt, s.user_id, d, exp])

      assert binding_count(jwt) == 0, "no jwt_device_bindings row for an OAuth device"
      assert Nebu.Matrix.Session.DeviceBinding.list_for_user_device(s.user_id, d) == []
      refute Nebu.Matrix.Session.DeviceBinding.get_device(jwt) == d, "the refused binding must not be primed into the cache"
    end

    test "the legacy lazy /keys/upload binding does not bind a JWT to an OAuth device", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)
      jwt = T.sign_id_token(priv, %{"sub" => s.sub, "exp" => System.system_time(:second) + 3600})

      device_keys = %{
        "user_id" => s.user_id,
        "device_id" => d,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
        "keys" => %{"ed25519:#{d}" => "atdd-ed25519-key"},
        "signatures" => %{}
      }

      _ = T.matrix_request(:post, "/_matrix/client/v3/keys/upload", jwt, body: %{"device_keys" => device_keys})
      assert binding_count(jwt) == 0
      assert T.whoami(s.at).status == 200, "the OAuth session is unaffected"
    end

    test "a normal (non-OAuth) device still binds (regression)", %{priv: priv} do
      sub = T.unique_sub()
      T.provision_user!(sub)
      jwt = T.bound_jwt!(priv, sub, dev())
      assert binding_count(jwt) == 1
    end
  end

  describe "T25 (c) — OidcPlug.call_jwt/2 refuses a JWT whose binding points at an OAuth device" do
    test "binding row inserted directly => 401 M_UNKNOWN_TOKEN 'Access token has been revoked', no soft_logout", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)
      exp = System.system_time(:second) + 3600
      jwt = T.sign_id_token(priv, %{"sub" => s.sub, "exp" => exp})

      T.sql!(
        "INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at) VALUES ($1, $2, $3, $4, $5)",
        [Nebu.Matrix.Session.DeviceBinding.hash(jwt), s.user_id, d, exp, System.system_time(:millisecond)]
      )

      body = assert_unknown_token(T.whoami(jwt), false)
      assert body["error"] =~ "Access token has been revoked"
      assert apply(Nebu.Matrix.Session.DeviceBinding, :lookup, [jwt]) == {:ok, d, true}
    end

    test "lookup/1 of a normal binding => {:ok, device, false}; get_device/1 contract unchanged", %{priv: priv} do
      d = dev()
      sub = T.unique_sub()
      T.provision_user!(sub)
      jwt = T.bound_jwt!(priv, sub, d)
      assert apply(Nebu.Matrix.Session.DeviceBinding, :lookup, [jwt]) == {:ok, d, false}
      assert Nebu.Matrix.Session.DeviceBinding.get_device(jwt) == d
      # dev-story fix: a distinct jti, otherwise this JWT is byte-identical to the bound one when both
      # are signed within the same second (same claims, deterministic RS256 signature).
      unbound = T.sign_id_token(priv, %{"sub" => sub, "exp" => System.system_time(:second) + 3600, "jti" => "unbound-" <> T.rand()})
      assert Nebu.Matrix.Session.DeviceBinding.get_device(unbound) == nil
      assert apply(Nebu.Matrix.Session.DeviceBinding, :lookup, [unbound]) == {:ok, nil, false}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC17 / T27 — legacy isolation
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC17/T27 — legacy /refresh and the OAuth token endpoint never cross (must-test 28)" do
    test "legacy POST /refresh with an OAuth refresh token => 401 M_UNKNOWN_TOKEN, no row touched", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      before = T.rows_snapshot(s.user_id, s.device_id)

      conn =
        Plug.Test.conn(:post, "/_matrix/client/v3/refresh", Jason.encode!(%{"refresh_token" => s.rt}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 401
      assert T.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
      assert T.rows_snapshot(s.user_id, s.device_id) == before
      assert T.whoami(s.at).status == 200
    end

    test "/oauth2/token with a LEGACY refresh token => invalid_grant, legacy row unchanged", %{cid: cid} do
      uid = T.provision_user!()
      d = dev()
      legacy = T.legacy_session!(uid, d)
      before = T.rows_snapshot(uid, d)
      T.refresh(cid, legacy.rt) |> T.assert_token_error(400, "invalid_grant")
      assert T.rows_snapshot(uid, d) == before
      assert T.whoami(legacy.at).status == 200
    end

    test "MatrixSessionStore.resolve_refresh_token/1 does not know OAuth refresh tokens", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      assert Store.resolve_refresh_token(s.rt) == :error
    end

    test "legacy mark_access_token_used/has_open_grace_window? never consume a pending OAuth sibling", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      T.idp_refresh_ok(s.sub)
      _fresh = T.refresh!(cid, s.rt)
      # a legacy row on the SAME device (constructed directly; T7/T26 normally prevent it)
      legacy = T.legacy_session!(s.user_id, s.device_id)

      refute Store.has_open_grace_window?(legacy.at), "the pending sibling is an OAuth row: not a legacy grace window"
      :ok = Store.mark_access_token_used(legacy.at)
      assert T.row_by_rt(s.rt)["grace_until"] == nil, "the pending OAuth RT must stay pending (same-auth_api siblings only)"
    end

    test "cleanup_expired/0 keeps an OAuth row whose AT expired > 7 days ago while the session is alive", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())

      T.sql!(
        "UPDATE matrix_sessions SET expires_at = now() - interval '8 days', session_expires_at = now() + interval '1 hour' " <>
          "WHERE access_token_hash = $1",
        [T.token_hash(s.at)]
      )

      _ = Store.cleanup_expired()
      assert T.row_by_at(s.at) != nil, "cleanup_expired uses COALESCE(session_expires_at, expires_at)"
    end
  end

  describe "AC17/T27 — the RefreshWorker never touches OAuth rows (spec 6: no background worker)" do
    defp run_one_refresh_cycle do
      Application.put_env(:nebu_http, :matrix_refresh_worker_lookahead_seconds, 3600)
      _ = stop_supervised(@worker)
      pid = start_supervised!(@worker)
      send(pid, :refresh)
      :sys.get_state(pid)
      pid
    end

    test "an OAuth row inside the lookahead window is not a candidate; a legacy row still is", %{cid: cid, priv: priv} do
      oauth_idp_rt = "oauth-idp-rt-" <> T.rand(8)
      s = session_on(cid, priv, dev(), idp_rt: oauth_idp_rt)
      T.sql!("UPDATE matrix_sessions SET expires_at = now() + interval '60 seconds' WHERE access_token_hash = $1", [T.token_hash(s.at)])
      before = T.row_by_at(s.at)

      legacy_uid = T.provision_user!()
      legacy_rt = "legacy-rt-" <> T.rand(8)

      _legacy =
        T.legacy_session!(legacy_uid, dev(),
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
          oidc_refresh_token: Nebu.Web.SecretBox.encrypt(legacy_rt)
        )

      T.idp_refresh_error({:token_endpoint_status, 400})
      run_one_refresh_cycle()

      assert_received {:idp_refresh, ^legacy_rt}, "legacy rows behave exactly as before"
      refute_received {:idp_refresh, ^oauth_idp_rt}, "the worker must never redeem an OAuth session's IdP RT"

      after_row = T.row_by_at(s.at)
      assert after_row, "the worker must never delete an OAuth row"
      assert after_row["expires_at"] == before["expires_at"], "never extended in place"
      assert after_row["oidc_refresh_token"] == before["oidc_refresh_token"]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T26 — legacy login on an OAuth device = take-over
  # ════════════════════════════════════════════════════════════════════════════

  describe "T26 — legacy POST /login with the device_id of an OAuth device (must-test 29)" do
    defp legacy_login(priv, sub, device_id) do
      init = T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("http://localhost:7070/#/home"))
      idp = T.idp_params(init)
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"sub" => sub, "nonce" => idp["nonce"]}), nil})
      cb = T.callback([{"code", "c-" <> T.rand()}, {"state", idp["state"]}])
      token = cb |> T.location() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("loginToken")

      Plug.Test.conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => token, "device_id" => device_id}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Map.put(:remote_ip, T.unique_ip())
      |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
    end

    test "the OAuth rows of the device are deleted first; the legacy login then succeeds on that device", %{cid: cid, priv: priv} do
      d = dev()
      s = session_on(cid, priv, d)

      login = legacy_login(priv, s.sub, d)
      assert login.status == 200, "legacy login must succeed, got #{login.status}: #{login.resp_body}"
      assert T.json(login)["device_id"] == d

      assert oauth_rows(s.user_id, d) == []
      assert_unknown_token(T.whoami(s.at), false)
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")

      legacy_at = T.json(login)["access_token"]
      who = T.whoami(legacy_at)
      assert who.status == 200
      assert T.json(who)["device_id"] == d
    end

    test "a legacy login on ANOTHER device leaves the user's OAuth session untouched", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      before = T.rows_snapshot(s.user_id, s.device_id)
      assert legacy_login(priv, s.sub, dev()).status == 200
      assert T.rows_snapshot(s.user_id, s.device_id) == before
      assert T.whoami(s.at).status == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC17 — logout, device deletion and admin deactivation remove OAuth rows (regressions)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC17 — existing delete paths also remove OAuth rows" do
    test "POST /logout with the OAuth access token removes every row of the device", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", s.at, body: %{}).status == 200
      assert T.session_rows(s.user_id, s.device_id) == []
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
    end

    # story 5 (oauth-legacy-coexistence, C7 / Trap 6): changed deliberately. The OAuth caller deleting
    # its own device is refused with 403 M_FORBIDDEN from story 5 on (nothing deleted); the deletion by
    # a legacy session of the same user is covered by story 4's oauth_logout_test.exs (AC10).
    test "DELETE /devices/{id} by the OAuth session itself (fresh-auth window) => 403, the OAuth rows stay", %{cid: cid, priv: priv} do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      s = session_on(cid, priv, dev())
      before = T.rows_snapshot(s.user_id, s.device_id)
      conn = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> s.device_id, s.at, body: %{})
      assert conn.status == 403, "an OAuth caller must be refused, got #{conn.status}: #{conn.resp_body}"
      assert T.rows_snapshot(s.user_id, s.device_id) == before
      assert T.whoami(s.at).status == 200
    end

    test "admin device deletion (Nebu.Matrix.delete_user_device/2) removes the OAuth rows", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      _ = Nebu.Matrix.delete_user_device(s.user_id, s.device_id)
      assert oauth_rows(s.user_id, s.device_id) == []
      assert_unknown_token(T.whoami(s.at), false)
    end

    test "admin deactivation (MatrixSessionStore.delete_for_user/1) removes the OAuth rows", %{cid: cid, priv: priv} do
      s = session_on(cid, priv, dev())
      :ok = Store.delete_for_user(s.user_id)
      assert T.session_rows(s.user_id, s.device_id) == []
      T.refresh(cid, s.rt) |> T.assert_token_error(400, "invalid_grant")
    end
  end
end
