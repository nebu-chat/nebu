defmodule Nebu.OAuth.OAuthBindingCookieTest do
  @moduledoc """
  Acceptance tests (integration) for story `oauth-hardening-hygiene`, AC8 (HY9, HY15,
  follow-ups j / ah): the per-flow binding cookies are origin-locked `__Host-` cookies on https.

    * https request (`Nebu.Web.RequestScheme.https?/1`, e.g. `X-Forwarded-Proto: https`):
      authorize `__Host-nebu_oa_<16 hex of the state hash>`, account login `__Host-nebu_acct_<16 hex>`,
      both `Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`, never a `Domain`.
    * plain http (dev / test): today's names and attributes (`Path=` the shared callback path, no `Secure`).
    * The callback reads ONLY the name of its own scheme: no fallback to the other name (a fallback
      would re-open sibling-subdomain cookie tossing). A scheme mismatch between authorize and callback
      is a `400 invalid_state` (fail closed). Clearing uses the same name / path / secure.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @proxy [{"x-forwarded-proto", "https"}]
  @cb_path "/_matrix/client/v3/login/sso/redirect/oidc"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https]), sub: T.unique_sub()}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp cleared?(conn, name) do
    Enum.find(T.set_cookies(conn), &String.starts_with?(&1, name <> "="))
  end

  defp assert_cleared_secure_root(conn, name) do
    raw = cleared?(conn, name) || flunk("#{name} was not cleared: #{inspect(T.set_cookies(conn))}")
    assert raw =~ ~r/max-age=0(;|\z)/i, "cleared with Max-Age=0: #{raw}"
    assert raw =~ ~r/path=\/(;|\z)/i, "cleared on Path=/ (same path as it was set): #{raw}"
    assert raw =~ ~r/secure/i, "cleared with Secure: #{raw}"
    refute raw =~ ~r/domain=/i
  end

  defp legacy_name(%{state: state}), do: T.binding_cookie_name(state, false)
  defp host_name(%{state: state}), do: T.binding_cookie_name(state, true)

  defp cb_pairs(flow), do: [{"code", "idp-code-" <> T.rand()}, {"state", flow.state}]

  defp stub_ok(flow, priv, sub, extra \\ %{}) do
    claims = Map.merge(%{"sub" => sub, "nonce" => flow.nonce, "auth_time" => System.system_time(:second)}, extra)
    T.stub_idp_exchange({:ok, T.sign_id_token(priv, claims), "idp-rt-" <> T.rand(8)})
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.1 — authorize, https
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.1 — authorize on https" do
    test "set-cookie is __Host-nebu_oa_<16 hex>; path=/; max-age=600; secure; HttpOnly; SameSite=Lax; no Domain", %{cid: cid} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      {name, value, raw} = T.binding_cookie(flow.conn)

      assert name == host_name(flow)
      assert name =~ ~r/\A__Host-nebu_oa_[0-9a-f]{16}\z/
      assert value =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert raw =~ ~r/;\s*path=\/(;|\z)/i
      assert raw =~ ~r/;\s*max-age=600(;|\z)/i
      assert raw =~ ~r/;\s*secure/i
      assert raw =~ ~r/;\s*HttpOnly/i
      assert raw =~ ~r/;\s*SameSite=Lax/i
      refute raw =~ ~r/domain=/i, "__Host- forbids a Domain attribute"
      refute raw =~ ~r/path=\/_matrix/i, "no callback-path scoping on https (the __Host- prefix requires Path=/)"
    end

    test "X-Forwarded-Proto: https,http counts as https (first value, RequestScheme)", %{cid: cid} do
      flow = T.start_flow(cid, @https, %{}, headers: [{"x-forwarded-proto", "https,http"}])
      assert elem(flow.cookie, 0) == host_name(flow)
    end

    test "a connection that is itself https (no header) gets the __Host- cookie too", %{cid: cid} do
      pairs = T.authorize_params(cid, @https)
      conn = Plug.Test.conn(:get, T.authorize_url(pairs)) |> Map.merge(%{scheme: :https, port: 443, remote_ip: T.unique_ip()})
      conn = Nebu.Web.Router.call(conn, Nebu.Web.Router.init([]))
      assert conn.status == 302
      {name, _value, raw} = T.binding_cookie(conn)
      assert name =~ ~r/\A__Host-nebu_oa_[0-9a-f]{16}\z/
      assert raw =~ ~r/secure/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.2 — callback, https
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.2 — callback on https reads only the __Host- name" do
    test "the __Host- cookie completes the flow (303 to the consent screen) and is cleared (max-age=0, path=/, secure)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      conn = T.finish_flow(flow, priv, headers: @proxy)

      assert conn.status == 303, "expected 303 to the consent screen, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
      assert_cleared_secure_root(conn, host_name(flow))
    end

    test "a request carrying ONLY the legacy name nebu_oa_<16 hex> => 400 invalid_state (no fallback), the __Host- name is cleared", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      {_name, value} = flow.cookie
      stub_ok(flow, priv, T.unique_sub())

      conn = T.callback(cb_pairs(flow), [{legacy_name(flow), value}], headers: @proxy)

      T.assert_page(conn, 400, "invalid_state")
      assert_cleared_secure_root(conn, host_name(flow))
    end

    test "a tossed sibling-domain cookie of the legacy name cannot complete a flow whose real cookie is __Host-", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      stub_ok(flow, priv, T.unique_sub())

      # attacker-chosen value under the legacy name, real __Host- cookie missing
      conn = T.callback(cb_pairs(flow), [{legacy_name(flow), "attacker-chosen-" <> T.rand()}], headers: @proxy)
      T.assert_page(conn, 400, "invalid_state")
    end

    test "an unknown / expired state on https clears the __Host- cookie too (every outcome that cleared before)", %{cid: _cid} do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conn = T.callback([{"code", "c"}, {"state", state}], [{T.binding_cookie_name(state, true), "x"}], headers: @proxy)
      T.assert_page(conn, 400, "invalid_state")
      assert_cleared_secure_root(conn, T.binding_cookie_name(state, true))
    end

    test "an IdP error redirect (error=access_denied) clears the __Host- cookie", %{cid: cid} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      conn = T.callback([{"error", "access_denied"}, {"state", flow.state}], [flow.cookie], headers: @proxy)
      assert conn.status == 302
      assert_cleared_secure_root(conn, host_name(flow))
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.3 — plain http is unchanged
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.3 — plain http: today's name and attributes" do
    test "nebu_oa_<16 hex>; Path = the shared callback path; no Secure; HttpOnly; SameSite=Lax; Max-Age=600", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      {name, _value, raw} = T.binding_cookie(flow.conn)

      assert name == legacy_name(flow)
      assert name =~ ~r/\Anebu_oa_[0-9a-f]{16}\z/
      assert raw =~ ~r/;\s*path=#{Regex.escape(@cb_path)}(;|\z)/i
      assert raw =~ ~r/;\s*max-age=600(;|\z)/i
      assert raw =~ ~r/;\s*HttpOnly/i
      assert raw =~ ~r/;\s*SameSite=Lax/i
      refute raw =~ ~r/;\s*secure/i
    end

    test "the callback on http completes with the legacy name and clears it on the callback path, not Secure", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      conn = T.finish_flow(flow, priv)
      assert conn.status == 303

      raw = cleared?(conn, legacy_name(flow)) || flunk("legacy cookie not cleared: #{inspect(T.set_cookies(conn))}")
      assert raw =~ ~r/max-age=0(;|\z)/i
      assert raw =~ ~r/path=#{Regex.escape(@cb_path)}(;|\z)/i
      refute raw =~ ~r/secure/i
    end

    test "on http the __Host- name is NOT read either (each scheme reads only its own name) => 400 invalid_state", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      {_n, value} = flow.cookie
      stub_ok(flow, priv, T.unique_sub())

      conn = T.callback(cb_pairs(flow), [{host_name(flow), value}])
      T.assert_page(conn, 400, "invalid_state")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.5 — scheme mismatch
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.5 — a scheme mismatch between authorize and callback => 400 invalid_state" do
    test "authorize https, callback http (inconsistent X-Forwarded-Proto)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      conn = T.finish_flow(flow, priv)
      T.assert_page(conn, 400, "invalid_state")
    end

    test "authorize http, callback https (a flow in flight across the deploy)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      conn = T.finish_flow(flow, priv, headers: @proxy)
      T.assert_page(conn, 400, "invalid_state")
    end

    test "the failed callback consumed the request row (single use): the right-scheme retry is invalid_state too", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{}, headers: @proxy)
      T.finish_flow(flow, priv) |> T.assert_page(400, "invalid_state")
      T.finish_flow(flow, priv, headers: @proxy) |> T.assert_page(400, "invalid_state")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.4 — the same for the account login binding cookie
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.4 — account login binding cookie (__Host-nebu_acct_)" do
    test "https: __Host-nebu_acct_<16 hex>; path=/; max-age=600; secure; HttpOnly; SameSite=Lax; no Domain" do
      flow = T.account_start!("/account", headers: @proxy)
      {name, value} = flow.binding
      raw = T.raw_set_cookie(flow.conn, name)

      assert name == T.account_binding_cookie_name(flow.state, true)
      assert name =~ ~r/\A__Host-nebu_acct_[0-9a-f]{16}\z/
      assert value != ""
      assert raw =~ ~r/;\s*path=\/(;|\z)/i
      assert raw =~ ~r/;\s*max-age=600(;|\z)/i
      assert raw =~ ~r/;\s*secure/i and raw =~ ~r/;\s*HttpOnly/i and raw =~ ~r/;\s*SameSite=Lax/i
      refute raw =~ ~r/domain=/i
    end

    test "https callback with the __Host- cookie signs in; the binding cookie is cleared (max-age=0, path=/, secure)", %{priv: priv} do
      sub = T.unique_sub()
      _uid = T.provision_user!(sub)
      flow = T.account_start!("/account", headers: @proxy)
      cb = T.account_finish(flow, priv, sub, headers: @proxy)

      assert cb.status == 303
      {name, _} = flow.binding
      assert_cleared_secure_root(cb, name)
    end

    test "https callback with ONLY the legacy name nebu_acct_<16 hex> => 400 invalid_state, no session", %{priv: priv} do
      sub = T.unique_sub()
      _uid = T.provision_user!(sub)
      flow = T.account_start!("/account", headers: @proxy)
      {_n, value} = flow.binding
      legacy = T.account_binding_cookie_name(flow.state, false)

      cb = T.account_finish(flow, priv, sub, headers: @proxy, cookies: [{legacy, value}])
      T.assert_account_error(cb, 400, "invalid_state")
      assert T.account_cookie_from(cb, "__Host-nebu_account") == nil, "no session cookie"
      assert_cleared_secure_root(cb, T.account_binding_cookie_name(flow.state, true))
    end

    test "plain http: today's name nebu_acct_<16 hex> with Path = the shared callback path and no Secure" do
      flow = T.account_start!("/account")
      {name, _} = flow.binding
      raw = T.raw_set_cookie(flow.conn, name)

      assert name == T.account_binding_cookie_name(flow.state, false)
      assert raw =~ ~r/;\s*path=#{Regex.escape(@cb_path)}(;|\z)/i
      assert raw =~ ~r/;\s*max-age=600(;|\z)/i
      refute raw =~ ~r/;\s*secure/i
    end

    test "plain http callback with the legacy name signs in (unchanged)", %{priv: priv} do
      sub = T.unique_sub()
      _uid = T.provision_user!(sub)
      flow = T.account_start!("/account")
      cb = T.account_finish(flow, priv, sub)
      assert cb.status == 303
    end

    test "AC8.5: authorize-side https, callback http => 400 invalid_state (and the reverse)", %{priv: priv} do
      sub = T.unique_sub()
      _uid = T.provision_user!(sub)

      flow = T.account_start!("/account", headers: @proxy)
      T.account_finish(flow, priv, sub) |> T.assert_account_error(400, "invalid_state")

      flow2 = T.account_start!("/account")
      T.account_finish(flow2, priv, sub, headers: @proxy) |> T.assert_account_error(400, "invalid_state")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # logging law
  # ════════════════════════════════════════════════════════════════════════════

  describe "logging law (AC14)" do
    test "a binding cookie value is never logged, on either scheme", %{cid: cid, priv: priv} do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      log =
        capture_log([level: :debug], fn ->
          for headers <- [@proxy, []] do
            flow = T.start_flow(cid, @https, %{}, headers: headers)
            {_name, value} = flow.cookie
            Process.put(:cookie_value, [value | Process.get(:cookie_value, [])])
            T.finish_flow(flow, priv, headers: headers)
            # a mismatching replay
            T.finish_flow(flow, priv, headers: headers)
          end
        end)

      for value <- Process.get(:cookie_value, []), do: refute(log =~ value, "a binding cookie value leaked into the log")
    end
  end
end
