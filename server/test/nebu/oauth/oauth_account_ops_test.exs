defmodule Nebu.OAuth.OAuthAccountOpsTest do
  @moduledoc """
  Acceptance tests for story `oauth-account-management` (story 6 of epic oauth-broker),
  AC12 purge (A23; Must #37) and AC13 logging / redaction (A21, A22; Must #38, No Sensitive Data law).

  Pinned: `Nebu.OAuth.purge_expired_account_state/0 :: {:ok, %{login_requests: n, sessions: m}} |
  {:error, term}`, `Nebu.Matrix.purge_expired_uia_sessions/0 :: {:ok, n} | non_neg_integer` (the
  delegated `Uia.cleanup_expired/0` count), `Nebu.OAuth.purge_expired_flow_state/0` shape unchanged,
  `Nebu.Workers.OAuthFlowPurgeWorker.perform/1` runs all three.

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
    end)

    {:ok, priv: priv}
  end

  defp now, do: System.system_time(:second)

  describe "AC12/A23/Must #37 — purge" do
    test "deletes only expired login requests, sessions and UIA rows; live rows kept; flow-state shape unchanged" do
      uid = T.provision_user!()
      live = T.account_session!(uid)
      dead = T.account_session!(uid, created_sql: "now() - interval '2 hours'", idle_sql: "now() - interval '1 hour' - interval '2 seconds'", expires_sql: "now() - interval '1 hour' - interval '1 second'")

      live_flow = T.account_start!()
      dead_flow = T.account_start!()
      T.privileged_sql!(
        "UPDATE oauth_account_login_requests SET created_at = now() - interval '20 minutes', expires_at = now() - interval '11 minutes' WHERE state_hash = $1",
        [T.sha256_hex(dead_flow.state)]
      )

      live_uia = Nebu.Matrix.Uia.mint_session(uid, "cross_signing_reset", "{}")
      dead_uia = Nebu.Matrix.Uia.mint_session(uid, "delete_devices", "{}")
      T.sql!("UPDATE uia_sessions SET expires_at = $2 WHERE session_id = $1", [dead_uia, now() - 10])

      assert {:ok, %{login_requests: lr, sessions: ss}} = apply(Nebu.OAuth, :purge_expired_account_state, [])
      assert lr >= 1 and ss >= 1
      _ = apply(Nebu.Matrix, :purge_expired_uia_sessions, [])

      assert T.account_session_row(live.cookie)
      assert T.account_session_row(dead.cookie) == nil
      exists = fn st -> T.sql!("SELECT 1 FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(st)]).num_rows == 1 end
      assert exists.(live_flow.state)
      refute exists.(dead_flow.state)
      assert T.uia_row(live_uia)
      assert T.uia_row(dead_uia) == nil

      assert {:ok, %{authz_requests: _, codes: _}} = Nebu.OAuth.purge_expired_flow_state()
    end

    test "the worker runs all purges (one perform)" do
      uid = T.provision_user!()
      dead = T.account_session!(uid, created_sql: "now() - interval '2 hours'", idle_sql: "now() - interval '1 hour' - interval '2 seconds'", expires_sql: "now() - interval '1 hour' - interval '1 second'")
      dead_uia = Nebu.Matrix.Uia.mint_session(uid, "delete_devices", "{}")
      T.sql!("UPDATE uia_sessions SET expires_at = $2 WHERE session_id = $1", [dead_uia, now() - 10])

      assert :ok = Nebu.Workers.OAuthFlowPurgeWorker.perform(%Oban.Job{})
      assert T.account_session_row(dead.cookie) == nil
      assert T.uia_row(dead_uia) == nil
    end
  end

  describe "AC13/A21/A22/Must #38 — no secret in any log line over the account flows" do
    test "sign-in, device deletion, reset approval, logout at :debug: no cookie, CSRF, state, code, IdP token, UIA session id or hash", %{priv: priv} do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      cid = T.oauth_client!([@https])
      sub = T.unique_sub()
      s = T.oauth_device!(cid, @https, priv, sub, "LOGD" <> String.upcase(T.rand(3)))
      d2 = T.oauth_device!(cid, @https, priv, sub, "LOGE" <> String.upcase(T.rand(3)))
      assert T.device_signing_upload(s.at, T.cross_signing_keys(s.user_id, "L1")).status == 200
      holder = self()

      log =
        capture_log([level: :debug], fn ->
          flow = T.account_start!()
          cb = T.account_finish(flow, priv, sub)
          cookie = T.account_cookie_from(cb)
          page = T.account_get(T.location(cb), cookie: cookie)
          csrf = T.csrf_from(page)
          _ = T.account_post("/account/devices/delete", [{"device_id", d2.device_id}, {"csrf_token", csrf}], cookie: cookie)
          ch = T.device_signing_upload(s.at, T.cross_signing_keys(s.user_id, "L2"))
          sid = T.json(ch)["session"]
          _ = T.account_post("/account/cross_signing_reset/approve", [{"session_id", sid}, {"csrf_token", csrf}], cookie: cookie, headers: T.strict_fetch_headers())
          _ = T.account_post("/account/logout", [{"csrf_token", csrf}], cookie: cookie)
          send(holder, {:secrets, %{state: flow.state, nonce: flow.nonce, binding: elem(flow.binding, 1), cookie: cookie, csrf: csrf, sid: sid,
                                    cookie_hash: T.sha256_hex(cookie || ""), state_hash: T.sha256_hex(flow.state)}})
        end)

      assert_received {:secrets, secrets}
      T.refute_secrets_in_log(log, Map.merge(secrets, %{at: s.at, rt: s.rt, at2: d2.at}))
      refute log =~ "idp-rt-acct-", "the IdP refresh token is discarded, never logged"
      refute log =~ "acct-code-", "the IdP code is never logged"
      assert log =~ "OAuth account: signed in"
    end
  end
end
