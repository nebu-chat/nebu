defmodule Nebu.OAuth.OAuthConsentLoggingTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3), AC14 (FR17, No Sensitive Data
  in Logs law): `CaptureLog` at DEBUG over the whole consent flow (authorize, callback, `GET`, Allow and
  Deny, the refusals) contains no consent cookie, CSRF token, code, state, nonce, verifier, display
  name, client name, redirect URI, IdP refresh token or Nebu token. The INFO lines name ids only:

      OAuth callback: consent requested client_id=<id> user_id=<id> device_id=<id> fresh=<bool> device=<new|same_client|replace>
      OAuth consent: allowed|denied|refused client_id=<id> ...

  (the exact key list after `client_id=` beyond `client_id`, `user_id`, `device_id` is not pinned).
  `RequestLogger` masking of `/oauth2/consent` is in `oauth_request_logger_redaction_test.exs`.
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
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, priv: priv}
  end

  defp assert_no_secrets(log, secrets) do
    for {name, value} <- secrets, is_binary(value), byte_size(value) >= 6 do
      refute String.contains?(log, value), "secret #{name} leaked into the log"
    end
  end

  describe "AC14 — a full flow at DEBUG: Allow" do
    test "no cookie, CSRF token, code, state, nonce, verifier, names, redirect URI or IdP RT in the log; INFO lines carry ids", %{priv: priv} do
      client_name = "LogSecretApp-" <> T.rand(6)
      display_name = "LogSecretDevice-" <> T.rand(6)
      redirect = "https://app.example.com/cb-log-" <> T.rand(4)
      cid = T.oauth_client!([redirect], client_name: client_name, client_uri: "https://app.example.com", metadata: %{"tos_uri" => "https://app.example.com/tos-" <> T.rand(4)})
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      dev = "LOGDEV" <> String.upcase(T.rand(3))
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: display_name, last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)

      client_nonce = "client-nonce-" <> T.rand()
      idp_rt = "idp-rt-" <> T.rand(10)
      {verifier, challenge} = T.pkce_pair()

      {secrets, log} =
        with_log(fn ->
          flow =
            T.start_flow(cid, redirect, %{
              "scope" => T.js_sdk_scope(dev),
              "nonce" => client_nonce,
              "response_mode" => "query",
              "code_challenge" => challenge
            })

          cb = T.finish_flow(flow, priv, claims: %{"sub" => sub, "auth_time" => System.system_time(:second)}, idp_rt: idp_rt)
          T.assert_consent_redirect(cb)
          {_name, cookie_value, _raw} = T.consent_cookie(cb)
          page = T.consent_get(cb)
          assert page.status == 200
          csrf = T.csrf_from(page)
          allow = T.consent!(cb, :allow)
          params = T.assert_allow_redirect(allow, redirect, "query", T.param(flow.pairs, "state"))
          _ = T.redeem!(%{code: params["code"], verifier: verifier, client_id: cid, redirect_uri: redirect})

          [
            {"consent cookie", cookie_value},
            {"csrf token", csrf},
            {"code", params["code"]},
            {"client state", T.param(flow.pairs, "state")},
            {"idp state", flow.state},
            {"idp nonce", flow.nonce},
            {"client nonce", client_nonce},
            {"challenge", challenge},
            {"verifier", verifier},
            {"idp challenge", flow.idp["code_challenge"]},
            {"binding cookie", elem(flow.cookie, 1)},
            {"client name", client_name},
            {"display name", display_name},
            {"redirect uri", redirect},
            {"idp refresh token", idp_rt},
            {"consent row hash", T.sha256_hex(cookie_value)}
          ]
        end)

      assert_no_secrets(log, secrets)
      assert log =~ "OAuth callback: consent requested", "the callback logs one INFO line"
      assert log =~ "client_id=#{cid}"
      assert log =~ "user_id=#{uid}"
      assert log =~ "device_id=#{dev}"
      assert log =~ ~r/OAuth consent: allowed/
    end
  end

  describe "AC14 — Deny and every refusal" do
    test "Deny logs `denied`; refusals (CSRF, expired, device_in_use) log values-free WARNING/INFO lines", %{priv: priv} do
      client_name = "LogDenyApp-" <> T.rand(6)
      cid = T.oauth_client!([@https], client_name: client_name, client_uri: "https://app.example.com")

      {secrets, log} =
        with_log(fn ->
          flow = T.start_flow(cid, @https)
          cb = T.finish_flow(flow, priv, claims: %{"sub" => T.unique_sub()}, idp_rt: "idp-rt-" <> T.rand(10))
          T.assert_consent_redirect(cb)
          {_n, value, _} = T.consent_cookie(cb)

          # a refused POST (cross-site), then the Deny
          bad = T.consent_post([{"csrf_token", T.consent_csrf(value)}, {"decision", "allow"}], cookie: cb, headers: [{"sec-fetch-site", "cross-site"}], origin: "https://evil-log.example.org")
          T.assert_page(bad, 403, "forbidden")
          deny = T.consent!(cb, :deny)
          T.assert_deny_redirect(deny, @https, "fragment", T.param(flow.pairs, "state"))

          # an expired row
          exp = T.insert_consent!(cid, user_id: T.provision_user!(), created_sql: "now() - interval '6 minutes'", expires_sql: "now() - interval '1 minute'")
          T.consent!(exp.cookie, :allow, get: false) |> T.assert_page(400, "invalid_state")

          [
            {"consent cookie", value},
            {"csrf token", T.consent_csrf(value)},
            {"client state", T.param(flow.pairs, "state")},
            {"client name", client_name},
            {"origin", "evil-log.example.org"},
            {"expired cookie", exp.value},
            {"expired csrf", exp.csrf}
          ]
        end)

      assert_no_secrets(log, secrets)
      assert log =~ ~r/OAuth consent: denied/
      assert log =~ "[warning] OAuth consent: request refused", "the refused (cross-site) POST logs one value-free WARNING"
      assert log =~ "OAuth consent: refused reason=invalid_state", "the expired row logs an INFO refusal with no values"
    end

    test "device_in_use at the callback logs ids only", %{priv: priv} do
      cid = T.oauth_client!([@https], client_uri: "https://app.example.com")
      sub = T.unique_sub()
      _holder = T.session!(cid, @https, priv, sub: sub)
      other_name = "LogOtherApp-" <> T.rand(6)
      other = T.oauth_client!(["https://other.example.org/cb"], client_name: other_name, client_uri: "https://other.example.org")

      log =
        capture_log(fn ->
          flow = T.start_flow(other, "https://other.example.org/cb")
          T.finish_flow(flow, priv, claims: %{"sub" => sub}) |> T.assert_page(403, "device_in_use")
        end)

      refute log =~ other_name
      refute log =~ "other.example.org/cb"
    end
  end

  describe "AC14 — the refresh race (gate n) never logs a token" do
    test "the follower's wait and the replay log neither the Nebu refresh token, the IdP RT nor the rotated IdP RT", %{priv: priv} do
      cid = T.oauth_client!([@https], client_uri: "https://app.example.com")
      s = T.session!(cid, @https, priv)
      idp = T.rotating_idp_with_barrier(s.sub, s.idp_rt)

      log =
        capture_log(fn ->
          T.put_env_scoped(:oauth_idp_lease_wait_notify, self())
          t1 = Task.async(fn -> T.refresh(cid, s.rt) end)
          assert_receive {:idp_blocked, holder}, 10_000
          t2 = Task.async(fn -> T.refresh(cid, s.rt) end)
          # the follower announces that it waits on the lease; only then release the holder
          assert_receive {:lease_wait, _follower}, 10_000
          idp.release.(holder)
          r1 = Task.await(t1, 30_000)
          r2 = Task.await(t2, 30_000)
          send(self(), {:statuses, [r1.status, r2.status]})
        end)

      assert_received {:statuses, statuses}
      assert statuses == [200, 200]
      assert_no_secrets(log, [{"nebu refresh token", s.rt}, {"nebu access token", s.at}, {"idp refresh token", s.idp_rt}, {"rotated idp refresh token", idp.rotated}])
    end
  end
end
