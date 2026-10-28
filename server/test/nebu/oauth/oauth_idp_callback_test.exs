defmodule Nebu.OAuth.OAuthIdpCallbackTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC7 + AC8 (+ D1-D4,
  D16-D18, D20, D22, AC13, AC14, AC15): the OAuth branch of the SHARED IdP callback
  `GET /_matrix/client/v3/login/sso/redirect/oidc` and the Nebu authorization code issuance.

  Full in-process flow: authorize (302 to the IdP stub) -> the test reads the IdP-leg `state` and
  `nonce` from the IdP `Location` and the D4 cookie from `set-cookie` -> `:matrix_sso_token_override`
  returns an id_token signed with the `:oidc_jwks` key -> callback -> 302 to the client.

  Story oauth-authorize-freshness (P3, FR1/FR5): a SUCCESSFUL callback no longer mints a code. It answers
  `303 /oauth2/consent` + the consent cookie, and the client redirect with the code follows the user's
  Allow (`T.finish_allow/3` = `T.finish_flow/3` + `T.consent!(:allow)`). Tests that used to read the
  code from the callback response therefore go through the consent step; the error redirects of the
  callback (IdP errors, verification failures, deactivated user, gate l) are unchanged (302). The
  consent screen itself is covered in `oauth_consent_*_test.exs`.

  Cluster safety: single use is ONE atomic SQL statement (proven with N parallel callbacks for the
  same state: exactly one code); no node-local state is consulted (the SsoStore never sees the
  state). Crash/restart: a restarted node completes a pending flow because everything lives in the
  `oauth_authz_requests` row (the second request in "disabled at callback" proves the row is still
  consumable by a later request).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @loop "http://localhost:53682/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https, "http://localhost/cb"])}
  end

  defp consume(code), do: apply(Nebu.OAuth, :consume_authorization_code, [code])

  defp authz_count(state) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_authz_requests WHERE state_hash = $1", [T.sha256_hex(state)])
    n
  end

  # the client redirect of an ALLOW (story oauth-authorize-freshness: 303 See Other, after the consent POST)
  defp assert_success(conn, redirect_uri, mode, state) do
    assert conn.status == 303,
           "expected a success redirect to the client (Allow, 303), got #{conn.status} Location=#{inspect(T.location(conn))} body=#{String.slice(conn.resp_body || "", 0, 300)}"

    {base, got_mode, params, order} = T.client_redirect(conn)
    assert base == redirect_uri
    assert got_mode == mode
    assert params["code"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/, "code = base64url(32 random bytes), got #{inspect(params["code"])}"
    assert params["iss"] == T.issuer()
    if state, do: assert(params["state"] == state), else: refute(Map.has_key?(params, "state"))
    refute Map.has_key?(params, "error")
    refute Map.has_key?(params, "errcode")
    assert order == Enum.filter(~w(code state iss), &(&1 in order))
    params
  end

  defp code_row(code) do
    case T.sql!("SELECT * FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(code)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  # Bounded wait (no sleep) until the supervisor has re-registered `name` with a new pid.
  defp wait_for_restart(name, old, n \\ 2_000_000)
  defp wait_for_restart(name, _old, 0), do: flunk("#{inspect(name)} was not restarted by its supervisor")

  defp wait_for_restart(name, old, n) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old -> :ok
      _ -> :erlang.yield() && wait_for_restart(name, old, n - 1)
    end
  end

  defp cookie_cleared?(conn, name) do
    Enum.any?(T.set_cookies(conn), fn c -> String.starts_with?(c, name <> "=") and c =~ ~r/max-age=0(;|\z)/i end)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7/AC8 — happy path
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7/AC8 — happy path: code, state, iss (must-test 11 + 18)" do
    test "default https request: code in the fragment; code row bound to everything; authz row consumed; cookie cleared", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      sub = T.unique_sub()
      cb = T.finish_flow(flow, priv, claims: %{"sub" => sub})
      T.assert_consent_redirect(cb)
      assert T.count_for("oauth_codes", cid) == 0, "no code before the user's Allow"
      assert cookie_cleared?(cb, elem(flow.cookie, 0)), "the D4 cookie is deleted (Max-Age=0) at the callback"
      conn = T.consent!(cb, :allow)
      params = assert_success(conn, @https, "fragment", T.param(flow.pairs, "state"))

      row = code_row(params["code"])
      assert row, "oauth_codes row keyed by sha256_hex(code)"
      assert row["client_id"] == cid
      assert row["redirect_uri"] == @https
      assert row["code_challenge"] == T.param(flow.pairs, "code_challenge")
      assert row["device_id"] == "AbCdEfGhIj"
      assert row["user_id"] == T.user_id_for(%{"sub" => sub})
      assert row["scope"] == "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"
      assert row["scope_prefix"] == "urn:matrix:client:"
      assert row["response_mode"] == "fragment"
      assert row["openid_requested"] == false
      assert row["client_nonce"] == nil
      assert row["used_at"] == nil

      for {col, v} <- row, is_binary(v), do: refute(v == params["code"], "plaintext code in column #{col}")

      %{rows: [[ttl]]} =
        T.sql!("SELECT extract(epoch FROM expires_at - created_at)::float8 FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(params["code"])])

      assert ttl > 0 and ttl <= 60, "code TTL <= 60 s, got #{inspect(ttl)}"

      assert authz_count(flow.state) == 0, "the authorization request is single use"
      assert Nebu.Matrix.SsoStore.peek_state(flow.state) == :error
    end

    test "Element-Web shape: https redirect + response_mode=query + js-sdk scope + nonce => code in the QUERY (must-test 7 + 27)", %{cid: cid, priv: priv} do
      nonce = "js-nonce-" <> T.rand()
      flow = T.start_flow(cid, @https, %{"response_mode" => "query", "scope" => T.js_sdk_scope(), "nonce" => nonce})
      params = assert_success(T.finish_allow(flow, priv), @https, "query", T.param(flow.pairs, "state"))

      row = code_row(params["code"])
      assert row["response_mode"] == "query"
      assert row["openid_requested"] == true
      assert row["client_nonce"] == nonce
      assert row["scope"] == T.js_sdk_scope(), "the REQUEST's (unstable) prefix is echoed"
      assert row["scope_prefix"] == "urn:matrix:org.matrix.msc2967.client:"
    end

    test "Dart SDK shape (unstable prefix, no openid) on a loopback port: query, port stored", %{cid: cid, priv: priv} do
      scope = T.matrix_scope(T.unstable_prefix(), "ABCDEFGHIJ")
      flow = T.start_flow(cid, @loop, %{"scope" => scope})
      params = assert_success(T.finish_allow(flow, priv), @loop, "query", T.param(flow.pairs, "state"))
      row = code_row(params["code"])
      assert row["redirect_uri"] == @loop
      assert row["scope"] == scope
      assert row["openid_requested"] == false
    end

    test "explicit fragment on loopback is honoured; absent client state => no state in the success redirect", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @loop, %{"response_mode" => "fragment", "state" => nil})
      assert_success(T.finish_allow(flow, priv), @loop, "fragment", nil)
    end

    test "IdP refresh token stored ONLY SecretBox-encrypted in the code row (must-test 19)", %{cid: cid, priv: priv} do
      rt = "idp-refresh-token-" <> T.rand(12)
      flow = T.start_flow(cid, @https)
      params = assert_success(T.finish_allow(flow, priv, idp_rt: rt), @https, "fragment", T.param(flow.pairs, "state"))
      row = code_row(params["code"])

      refute row["idp_rt_enc"] == rt
      assert {:ok, ^rt} = Nebu.Web.SecretBox.decrypt(row["idp_rt_enc"])
      for {col, v} <- row, is_binary(v), do: refute(v =~ rt, "plaintext IdP RT in #{col}")
    end

    test "no IdP refresh token (oauth_idp_revalidation = off) => idp_rt_enc NULL (with per_refresh it is refused, AC10)", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      flow = T.start_flow(cid, @https)
      params = assert_success(T.finish_allow(flow, priv, idp_rt: nil), @https, "fragment", T.param(flow.pairs, "state"))
      assert code_row(params["code"])["idp_rt_enc"] == nil
    end

    # story oauth-authorize-freshness (FR4) supersedes D16: the stored auth_time is the raw `auth_time`
    # claim (clamped) or NULL. `iat` is NEVER a substitute (it proves issuance, not login).
    test "auth_time = the id_token auth_time claim; WITHOUT the claim it is NULL, never iat (FR4, supersedes D16)", %{cid: cid, priv: priv} do
      at = System.system_time(:second) - 120
      flow = T.start_flow(cid, @https)
      params = assert_success(T.finish_allow(flow, priv, claims: %{"auth_time" => at}), @https, "fragment", T.param(flow.pairs, "state"))
      %{rows: [[epoch]]} = T.sql!("SELECT extract(epoch FROM auth_time)::bigint FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(params["code"])])
      assert epoch == at

      iat = System.system_time(:second) - 30
      flow2 = T.start_flow(cid, @https)
      p2 = assert_success(T.finish_allow(flow2, priv, claims: %{"iat" => iat}), @https, "fragment", T.param(flow2.pairs, "state"))
      assert [[nil]] = T.sql!("SELECT auth_time FROM oauth_codes WHERE code_hash = $1", [T.sha256_hex(p2["code"])]).rows
    end

    test "the issued code is consumable ONCE through Nebu.OAuth (AC9), reuse is detected", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      params = assert_success(T.finish_allow(flow, priv), @https, "fragment", T.param(flow.pairs, "state"))
      assert {:ok, %{client_id: ^cid, redirect_uri: @https}} = consume(params["code"])
      assert {:error, {:reused, %{client_id: ^cid}}} = consume(params["code"])
    end

    test "user provisioning ran (D18): the users row exists after the callback", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      flow = T.start_flow(cid, @https)
      assert_success(T.finish_allow(flow, priv, claims: %{"sub" => sub}), @https, "fragment", T.param(flow.pairs, "state"))
      %{rows: [[n]]} = T.sql!("SELECT count(*) FROM users WHERE user_id = $1", [T.user_id_for(%{"sub" => sub})])
      assert n == 1
    end

    test "D3 crash/restart: the node-local SsoStore dying between authorize and callback does not matter", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      pid = Process.whereis(Nebu.Matrix.SsoStore)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      assert_success(T.finish_allow(flow, priv), @https, "fragment", T.param(flow.pairs, "state"))
      wait_for_restart(Nebu.Matrix.SsoStore, pid)
    end

    test "success iss is byte-equal to the issuer served by auth_metadata (trailing-slash config, must-test 28)", %{cid: cid, priv: priv} do
      T.enable_oauth("https://nebu.example.com/")
      issuer = T.get_metadata() |> T.json() |> Map.fetch!("issuer")
      flow = T.start_flow(cid, @https)
      conn = T.finish_allow(flow, priv)
      assert conn.status == 303
      {_base, _mode, params, _} = T.client_redirect(conn)
      assert params["iss"] == issuer
      assert issuer == "https://nebu.example.com"
    end

    test "D18: the user row provisioned at the OAuth callback has the same shape as one from legacy POST /login", %{cid: cid, priv: priv} do
      # The user id derives from the configured claim / preferred_username / name (UserId.from_claims/2),
      # so every identity claim is unique per user (users persist across runs) and the ids are
      # derived from the FULL claims.
      sub_oauth = T.unique_sub()
      sub_legacy = T.unique_sub()
      shape_claims = fn sub -> %{"sub" => sub, "preferred_username" => sub, "name" => "Shape " <> sub, "email" => sub <> "@example.com"} end
      oauth_claims = shape_claims.(sub_oauth)
      legacy_claims = shape_claims.(sub_legacy)

      flow = T.start_flow(cid, @https)
      # the user is provisioned at the callback, BEFORE the consent decision (FR5 (b)): no Allow needed here
      T.assert_consent_redirect(T.finish_flow(flow, priv, claims: oauth_claims))

      init = T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("http://localhost:7070/#/home"))
      idp = T.idp_params(init)
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, Map.put(legacy_claims, "nonce", idp["nonce"])), nil})
      cb = T.callback([{"code", "c"}, {"state", idp["state"]}])
      token = cb |> T.location() |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.fetch!("loginToken")

      login =
        Plug.Test.conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => token}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert login.status == 200

      shape = fn uid ->
        %{rows: [row]} =
          T.sql!(
            "SELECT system_role, is_active, display_name_encrypted IS NULL, email_encrypted IS NULL, deletion_status, " <>
              "media_admin_override FROM users WHERE user_id = $1",
            [uid]
          )

        row
      end

      assert shape.(T.user_id_for(oauth_claims)) == shape.(T.user_id_for(legacy_claims))
    end

    test "oauth_clients.last_used_at is NOT touched in story 2", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      assert_success(T.finish_allow(flow, priv), @https, "fragment", T.param(flow.pairs, "state"))
      assert T.client_row(cid)["last_used_at"] == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — IdP state: single use, expiry, forgery, binding cookie (must-test 13)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7 — state single use, expiry, forgery (never a redirect)" do
    test "replaying the same callback => 400 invalid_state page", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      assert T.finish_flow(flow, priv).status == 303
      T.finish_flow(flow, priv) |> T.assert_page(400, "invalid_state")
    end

    test "N parallel callbacks for the SAME state: exactly ONE code (atomic consume, cluster safe)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      claims = %{"sub" => T.unique_sub(), "nonce" => flow.nonce}
      # with an IdP refresh token: per_refresh without one is refused at the callback (gate l, AC10)
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, claims), "idp-rt-" <> T.rand(8)})

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn -> T.callback([{"code", "idp-code-#{i}"}, {"state", flow.state}], [flow.cookie]) end)
        end)
        |> Task.await_many(30_000)

      {ok, rest} = Enum.split_with(results, &(&1.status == 303))
      assert length(ok) == 1, "exactly one winner, got statuses #{inspect(Enum.map(results, & &1.status))}"
      for c <- rest, do: T.assert_page(c, 400, "invalid_state")
      assert T.count_for("oauth_consent_requests", cid) == 1, "one consent row (the winner's), no code before the Allow"
      assert T.count_for("oauth_codes", cid) == 0
    end

    test "an expired request (live = false) => invalid_state page, and the row is consumed", %{cid: cid} do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      cookie = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      T.sql!(
        "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
          "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, created_at, expires_at) " <>
          "VALUES ($1, $2, $3, $4, 'D', 's', 'urn:matrix:client:', 'fragment', $5, 'n', $6, now() - interval '11 minutes', now() - interval '1 minute')",
        [T.sha256_hex(state), cid, @https, String.duplicate("a", 43), Nebu.Web.SecretBox.encrypt("verifier"), T.sha256_hex(cookie)]
      )

      conn =
        T.callback([{"code", "c"}, {"state", state}], [{T.binding_cookie_name(state), cookie}])
        |> T.assert_page(400, "invalid_state")

      assert authz_count(state) == 0
      assert cookie_cleared?(conn, T.binding_cookie_name(state)), "the D4 cookie is deleted on the expired path too"
    end

    test "an unknown but well-formed o2. state => invalid_state page" do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      T.callback([{"code", "c"}, {"state", state}], [{T.binding_cookie_name(state), "x"}]) |> T.assert_page(400, "invalid_state")
    end

    test "a malformed o2. state => invalid_state page, never the legacy path (D2)" do
      for state <- ["o2.", "o2.short", "o2." <> String.duplicate("+", 43), "o2." <> String.duplicate("a", 44)] do
        conn = T.callback([{"code", "c"}, {"state", state}])
        T.assert_page(conn, 400, "invalid_state")
        refute conn.resp_body =~ "M_UNKNOWN"
      end
    end

    test "an o2. state with an IdP error but no stored request is NOT the legacy 403 JSON (Trap 1)" do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conn = T.callback([{"error", "access_denied"}, {"state", state}])
      T.assert_page(conn, 400, "invalid_state")
      refute conn.resp_body =~ "M_FORBIDDEN"
    end

    test "an o2. state without code and error does not fall into the legacy redirect (no M_MISSING_PARAM)" do
      state = "o2." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conn = T.callback([{"state", state}])
      T.assert_page(conn, 400, "invalid_state")
      refute conn.resp_body =~ "M_MISSING_PARAM"
    end
  end

  describe "D4 — browser binding cookie (RFC 9700 4.7, login CSRF)" do
    test "missing cookie => invalid_state page; the row is consumed anyway", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      T.finish_flow(flow, priv, cookies: []) |> T.assert_page(400, "invalid_state")
      assert authz_count(flow.state) == 0
      T.finish_flow(flow, priv) |> T.assert_page(400, "invalid_state")
    end

    test "the cookie of ANOTHER browser/flow => invalid_state", %{cid: cid, priv: priv} do
      victim = T.start_flow(cid, @https)
      attacker = T.start_flow(cid, @https)
      conn = T.finish_flow(victim, priv, cookies: [attacker.cookie]) |> T.assert_page(400, "invalid_state")
      assert T.count_for("oauth_codes", cid) == 0
      assert cookie_cleared?(conn, elem(victim.cookie, 0)), "the flow's own cookie name is cleared on a mismatch"
    end

    test "right cookie name, wrong value => invalid_state", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      {name, _} = flow.cookie
      conn =
        T.finish_flow(flow, priv, cookies: [{name, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}])
        |> T.assert_page(400, "invalid_state")

      assert cookie_cleared?(conn, name)
    end

    test "two tabs: each flow completes with its own cookie, in any order", %{cid: cid, priv: priv} do
      a = T.start_flow(cid, @https)
      b = T.start_flow(cid, @https)
      assert_success(T.finish_allow(b, priv, cookies: [b.cookie, a.cookie]), @https, "fragment", T.param(b.pairs, "state"))
      assert_success(T.finish_allow(a, priv, cookies: [a.cookie]), @https, "fragment", T.param(a.pairs, "state"))
    end
  end

  describe "AC7.6 — open-redirect safety (must-test 14)" do
    test "callback parameters never become the redirect target", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)

      extra = [
        {"redirect_uri", "https://evil.example.com/cb"},
        {"redirect_url", "https://evil.example.com/cb"},
        {"redirectUrl", "https://evil.example.com/cb"},
        {"response_mode", "query"},
        {"iss", "https://evil.example.com"}
      ]

      cb = T.finish_flow(flow, priv, extra_params: extra)
      T.assert_consent_redirect(cb)
      refute T.location(cb) =~ "evil.example.com"
      conn = T.consent!(cb, :allow)
      params = assert_success(conn, @https, "fragment", T.param(flow.pairs, "state"))
      refute T.location(conn) =~ "evil.example.com"
      assert params["iss"] == T.issuer()
    end

    test "a client deleted meanwhile (cascade) => invalid_state page, never a redirect", %{priv: priv} do
      cid = T.oauth_client!([@https])
      flow = T.start_flow(cid, @https)
      T.cleanup_clients([cid])
      T.finish_flow(flow, priv) |> T.assert_page(400, "invalid_state")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7.8-11 — IdP / verification / provisioning errors => error redirect to the client
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7.8 — IdP error responses are mapped, never forwarded (must-test 15 + 26)" do
    for mode <- ["query", "fragment"],
        {idp_error, ours} <- [
          {"access_denied", "access_denied"},
          {"temporarily_unavailable", "temporarily_unavailable"},
          {"login_required", "server_error"},
          {"invalid_scope", "server_error"},
          {"weird<script>", "server_error"}
        ] do
      test "IdP #{idp_error} => client #{ours} (#{mode}) with state + iss, IdP description not forwarded", %{cid: cid} do
        flow = T.start_flow(cid, @https, %{"response_mode" => unquote(mode)})

        log =
          capture_log(fn ->
            conn =
              T.callback(
                [
                  {"error", unquote(idp_error)},
                  {"error_description", "IDP-SECRET-DESCRIPTION"},
                  {"error_uri", "https://idp.example.com/IDP-ERROR-URI"},
                  {"state", flow.state}
                ],
                [flow.cookie]
              )

            T.assert_error_redirect(conn, @https, unquote(ours), unquote(mode), T.param(flow.pairs, "state"))
            assert cookie_cleared?(conn, elem(flow.cookie, 0)), "the D4 cookie is deleted on IdP error redirects too"
            refute T.location(conn) =~ "IDP-SECRET-DESCRIPTION"
            refute T.location(conn) =~ "IDP-ERROR-URI"
          end)

        refute log =~ "IDP-SECRET-DESCRIPTION"
        refute log =~ "IDP-ERROR-URI"
        assert authz_count(flow.state) == 0
        assert T.count_for("oauth_codes", cid) == 0
      end
    end

    test "missing code and no error => server_error redirect", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      conn = T.callback([{"state", flow.state}], [flow.cookie])
      T.assert_error_redirect(conn, @https, "server_error", "fragment", T.param(flow.pairs, "state"))
    end
  end

  describe "AC7.10 — code exchange / id_token verification (must-test 16)" do
    test "IdP token endpoint unreachable / 5xx => temporarily_unavailable", %{cid: cid} do
      for result <- [{:error, {:token_endpoint_unreachable, :econnrefused}}, {:error, {:token_endpoint_status, 502}}] do
        flow = T.start_flow(cid, @https)
        T.stub_idp_exchange(result)
        conn = T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie])
        T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(flow.pairs, "state"))
      end
    end

    test "id_token signed by an unknown key => access_denied", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      other = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", "oauth-authz-test-key-1")
      T.stub_idp_exchange({:ok, T.sign_id_token(other, %{"nonce" => flow.nonce}), nil})
      conn = T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie])
      T.assert_error_redirect(conn, @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
      assert T.count_for("oauth_codes", cid) == 0
    end

    test "nonce mismatch / missing nonce / expired id_token / wrong audience => access_denied", %{cid: cid, priv: priv} do
      for claims <- [
            %{"nonce" => "not-the-idp-nonce"},
            %{"nonce" => nil},
            %{"exp" => System.system_time(:second) - 600},
            %{"aud" => "some-other-client"}
          ] do
        flow = T.start_flow(cid, @https)
        claims = Map.merge(%{"nonce" => flow.nonce}, claims) |> Enum.reject(fn {_, v} -> v == nil end) |> Map.new()
        T.stub_idp_exchange({:ok, T.sign_id_token(priv, claims), nil})
        conn = T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie])
        T.assert_error_redirect(conn, @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
      end

      assert T.count_for("oauth_codes", cid) == 0
    end

    test "the CLIENT nonce is not accepted as IdP nonce (separate legs, D23)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https, %{"scope" => T.js_sdk_scope(), "nonce" => "client-side-nonce"})
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"nonce" => "client-side-nonce"}), nil})
      conn = T.callback([{"code", "c"}, {"state", flow.state}], [flow.cookie])
      T.assert_error_redirect(conn, @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
    end

    test "SecretBox key gone at the callback (verifier undecryptable) => server_error, no 500, no code", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      saved = for k <- ~w(NEBU_INTERNAL_SECRET NEBU_INTERNAL_SECRET_FILE), do: {k, System.get_env(k)}
      for {k, _} <- saved, do: System.delete_env(k)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)
      on_exit(fn -> for {k, v} <- saved, v != nil, do: System.put_env(k, v) end)

      conn = T.finish_flow(flow, priv, idp_rt: "rt-" <> T.rand())
      T.assert_error_redirect(conn, @https, "server_error", "fragment", T.param(flow.pairs, "state"))
      assert T.count_for("oauth_codes", cid) == 0
    end
  end

  describe "AC7.11 — provisioning (D18)" do
    test "deactivated user => access_denied with the fixed description, no code row (must-test 17)", %{cid: cid, priv: priv} do
      Application.put_env(:session_manager, :validator_module, T.DeactivatedValidator)
      flow = T.start_flow(cid, @https)
      params = T.assert_error_redirect(T.finish_flow(flow, priv), @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
      assert params["error_description"] == "This account has been deactivated."
      assert T.count_for("oauth_codes", cid) == 0
    end

    test "a provisioning failure other than deactivation => server_error, no code row", %{cid: cid, priv: priv} do
      Application.put_env(:session_manager, :validator_module, T.FailingValidator)
      flow = T.start_flow(cid, @https)
      T.assert_error_redirect(T.finish_flow(flow, priv), @https, "server_error", "fragment", T.param(flow.pairs, "state"))
      assert T.count_for("oauth_codes", cid) == 0
    end
  end

  describe "AC7.2 — OAuth disabled / invalid issuer at the callback" do
    test "disabled => 404 HTML page unavailable; the request row is NOT consumed (a later callback can finish)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      T.disable_oauth()
      T.finish_flow(flow, priv) |> T.assert_page(404, "unavailable")
      assert authz_count(flow.state) == 1

      T.enable_oauth()
      assert_success(T.finish_allow(flow, priv), @https, "fragment", T.param(flow.pairs, "state"))
    end

    test "invalid issuer => 404 page unavailable", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      T.enable_oauth("http://not-https.example.com")
      T.finish_flow(flow, priv) |> T.assert_page(404, "unavailable")
    end
  end

  describe "AC14/D19 — callback bucket {\"oauth_callback\", ip}" do
    test "an exhausted bucket => 429 page + Retry-After BEFORE the consume (the row survives)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      ip = T.unique_ip()
      {a, b, c, d} = ip
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_callback", "#{a}.#{b}.#{c}.#{d}"}, 10, 600)

      conn = T.finish_flow(flow, priv, ip: ip)
      T.assert_page(conn, 429, "rate_limited")
      assert T.header(conn, "retry-after")
      assert authz_count(flow.state) == 1

      assert_success(T.finish_allow(flow, priv), @https, "fragment", T.param(flow.pairs, "state"))
    end

    test "legacy callbacks are not charged to the OAuth callback bucket", %{} do
      ip = T.unique_ip()
      {a, b, c, d} = ip
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_callback", "#{a}.#{b}.#{c}.#{d}"}, 10, 600)
      conn = T.callback([{"code", "c"}, {"state", String.duplicate("a", 32)}], [], ip: ip)
      refute conn.status == 429
    end
  end

  describe "AC13 — callback response headers" do
    test "the 303 to the consent page and the pages: no-store, no-referrer, nosniff, no CORS with an Origin header", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      ok = T.finish_flow(flow, priv, headers: [{"origin", "https://client.example.com"}])
      replay = T.finish_flow(flow, priv, headers: [{"origin", "https://client.example.com"}])

      for conn <- [ok, replay] do
        assert T.header(conn, "cache-control") =~ "no-store"
        assert T.header(conn, "pragma") == "no-cache"
        assert T.header(conn, "referrer-policy") == "no-referrer"
        assert T.header(conn, "x-content-type-options") == "nosniff"
        for {k, _} <- conn.resp_headers, do: refute(String.starts_with?(k, "access-control-"))
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # story oauth-authorize-freshness — AC10 (gate l, FR13), AC1.3, FR5 order
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/FR13 — gate l: per_refresh and the IdP returned no refresh token" do
    @gate_l_description "The server encountered an unexpected error."

    for {label, rt} <- [{"nil", nil}, {"empty string", ""}] do
      test "IdP RT #{label} => server_error redirect (state, iss, fixed description, no config words); NOTHING persisted", %{cid: cid, priv: priv} do
        sub = T.unique_sub()
        flow = T.start_flow(cid, @https)
        conn = T.finish_flow(flow, priv, claims: %{"sub" => sub}, idp_rt: unquote(rt))
        params = T.assert_error_redirect(conn, @https, "server_error", "fragment", T.param(flow.pairs, "state"))

        assert params["error_description"] == @gate_l_description
        for word <- ["per_refresh", "revalidation", "refresh_token", "refresh token", "offline", "config", "idp", "IdP"],
            do: refute(params["error_description"] =~ word, "the description must not name #{word}")

        assert %{rows: []} = T.sql!("SELECT 1 FROM users WHERE user_id = $1", [T.user_id_for(%{"sub" => sub})]), "gate l runs BEFORE provisioning: no users row for a new sub"
        assert T.count_for("oauth_consent_requests", cid) == 0
        assert T.count_for("oauth_codes", cid) == 0
        assert authz_count(flow.state) == 0, "the request is consumed (single use) like every other failure"
        assert T.consent_set_cookies(conn) |> Enum.reject(&(&1 =~ ~r/max-age=0/i)) == [], "no live consent cookie"
      end
    end

    test "an unknown / unreadable idp_revalidation value is fail closed (= per_refresh)", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "bogus"})
      flow = T.start_flow(cid, @https)
      T.finish_flow(flow, priv, idp_rt: nil) |> T.assert_error_redirect(@https, "server_error", "fragment", T.param(flow.pairs, "state"))
    end

    test "ONE WARNING per node per 10 min, naming the fix, with no token / claim / sub", %{cid: cid, priv: priv} do
      sub = T.unique_sub()

      log =
        capture_log(fn ->
          for _ <- 1..2 do
            flow = T.start_flow(cid, @https)
            T.finish_flow(flow, priv, claims: %{"sub" => sub, "email" => "gate-l@example.com"}, idp_rt: nil)
          end
        end)

      warnings = log |> String.split("\n") |> Enum.filter(&(&1 =~ "oauth_idp_revalidation is per_refresh but the IdP returned no refresh token"))
      assert warnings != [], "the operator must see the cause in the admin log viewer"
      if System.get_env("NEBU_RATE_LIMIT_DISABLED") not in ["true", "1"], do: assert(length(warnings) == 1, "throttled: two callbacks, one WARNING, got #{inspect(warnings)}")
      assert log =~ "matrix_oidc_refresh_mode=offline"
      assert log =~ "oauth_idp_revalidation=off"
      assert log =~ "[warning]"
      refute log =~ sub
      refute log =~ "gate-l@example.com"
      refute log =~ T.user_id_for(%{"sub" => sub}), "no claims, no ids of the user"
    end

    test "with oauth_idp_revalidation = off the same flow reaches consent", %{cid: cid, priv: priv} do
      T.enable_oauth(T.issuer(), %{idp_revalidation: "off"})
      flow = T.start_flow(cid, @https)
      T.finish_flow(flow, priv, idp_rt: nil) |> T.assert_consent_redirect()
    end

    test "per_refresh with a refresh token reaches consent (the common case)", %{cid: cid, priv: priv} do
      flow = T.start_flow(cid, @https)
      T.finish_flow(flow, priv, idp_rt: "idp-rt-" <> T.rand()) |> T.assert_consent_redirect()
    end
  end

  describe "AC1.3/FR5 — failures before the consent step behave as in story 2" do
    test "a deactivated user is access_denied (fixed description), no consent row, no code", %{cid: cid, priv: priv} do
      Application.put_env(:session_manager, :validator_module, T.DeactivatedValidator)
      flow = T.start_flow(cid, @https)
      params = T.assert_error_redirect(T.finish_flow(flow, priv), @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
      assert params["error_description"] == "This account has been deactivated."
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "an IdP error / a missing code never create a consent row", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      T.assert_error_redirect(T.callback([{"error", "access_denied"}, {"state", flow.state}], [flow.cookie]), @https, "access_denied", "fragment", T.param(flow.pairs, "state"))
      flow2 = T.start_flow(cid, @https)
      T.assert_error_redirect(T.callback([{"state", flow2.state}], [flow2.cookie]), @https, "server_error", "fragment", T.param(flow2.pairs, "state"))
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "the client is re-checked at the callback: a client no longer approved => 403 client_rejected page, no consent row", %{priv: priv} do
      cid = T.oauth_client!([@https])
      flow = T.start_flow(cid, @https)
      :ok = T.reject_approved_client!(cid)
      T.finish_flow(flow, priv) |> T.assert_page(403, "client_rejected")
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "prompt=none is answered login_required BEFORE the IdP and before consent (D11)", %{cid: cid} do
      pairs = T.authorize_params(cid, @https, %{"prompt" => "none", "response_mode" => "query"})
      T.assert_error_redirect(T.authorize(pairs), @https, "login_required", "query", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0
      assert T.count_for("oauth_consent_requests", cid) == 0
    end

    test "a client max_age is ignored (D12, FR3): the callback still reaches consent, and the id_token has NO auth_time when the IdP sent none", %{cid: cid, priv: priv} do
      nonce = "n-" <> T.rand()
      {verifier, challenge} = T.pkce_pair()

      flow =
        T.start_flow(cid, @https, %{"max_age" => "0", "scope" => T.js_sdk_scope(), "nonce" => nonce, "response_mode" => "query", "code_challenge" => challenge})

      assert flow.idp["state"], "max_age=0 from the client does not stop the flow"

      cb = T.finish_flow(flow, priv)
      T.assert_consent_redirect(cb)
      params = assert_success(T.consent!(cb, :allow), @https, "query", T.param(flow.pairs, "state"))
      body = T.redeem!(%{code: params["code"], verifier: verifier, client_id: cid, redirect_uri: @https})
      {_header, claims} = T.verify_id_token!(body["id_token"])
      refute Map.has_key?(claims, "auth_time"), "no auth_time claim from the IdP => none in the id_token (never invented)"
      assert claims["nonce"] == nonce
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC15/D20 — no secrets in logs (must-test 21)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15 — log capture over a full flow at DEBUG" do
    test "code, both states, nonces, verifier, challenge, cookie, id_token and IdP RT never reach the log", %{priv: priv} do
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      client_nonce = "client-nonce-" <> T.rand()
      idp_rt = "idp-rt-" <> T.rand(10)
      sub = T.unique_sub()

      {secrets, log} =
        with_log(fn ->
          redirect = "https://app.example.com/cb-log-" <> T.rand()
          log_cid = T.oauth_client!([redirect])
          flow = T.start_flow(log_cid, redirect, %{"scope" => T.js_sdk_scope(), "nonce" => client_nonce, "response_mode" => "query"})

          %{rows: [[enc]]} =
            T.sql!("SELECT idp_code_verifier_enc FROM oauth_authz_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)])

          {:ok, verifier} = Nebu.Web.SecretBox.decrypt(enc)
          id_token = T.sign_id_token(priv, %{"sub" => sub, "nonce" => flow.nonce})
          T.stub_idp_exchange({:ok, id_token, idp_rt})
          idp_code = "idp-auth-code-" <> T.rand()
          conn = T.callback([{"code", idp_code}, {"state", flow.state}], [flow.cookie])
          T.assert_consent_redirect(conn)
          page = T.consent_get(conn)
          csrf = T.csrf_from(page)
          params = assert_success(T.consent!(conn, :allow), redirect, "query", T.param(flow.pairs, "state"))

          [
            params["code"],
            idp_code,
            redirect,
            flow.state,
            T.param(flow.pairs, "state"),
            T.param(flow.pairs, "code_challenge"),
            flow.idp["code_challenge"],
            flow.nonce,
            client_nonce,
            verifier,
            elem(flow.cookie, 1),
            id_token,
            idp_rt,
            enc,
            elem(T.consent_cookie(conn), 1),
            csrf
          ]
        end)

      assert log =~ "query_string", "sanity: the DEBUG payload capture ran (RequestLogger)"

      for s <- secrets do
        refute log =~ s, "secret #{String.slice(s, 0, 12)}... leaked into the log"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 / must-test 24 — legacy and UIA callbacks unchanged
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7 — legacy callbacks keep their Matrix JSON behaviour" do
    test "unknown legacy (hex) state => 400 JSON M_UNKNOWN" do
      conn = T.callback([{"code", "c"}, {"state", String.duplicate("a", 32)}])
      assert conn.status == 400
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
    end

    test "legacy IdP error => 403 JSON M_FORBIDDEN" do
      conn = T.callback([{"error", "access_denied"}, {"state", String.duplicate("b", 32)}])
      assert conn.status == 403
      assert T.json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "UIA fallback (must-test 24, Trap 2): IdP URL keeps max_age=0 + prompt=login; the UIA-tagged SsoStore state completes the UIA stage", %{priv: priv} do
      sub = T.unique_sub()
      user_id = T.user_id_for(%{"sub" => sub})
      session = Nebu.Matrix.Uia.mint_session(user_id, "delete_devices", "{}")

      init = T.get("/_matrix/client/v3/auth/m.login.sso/fallback/web?session=" <> URI.encode_www_form(session))
      assert init.status == 302
      idp = T.idp_params(init)
      assert idp["max_age"] == "0"
      assert idp["prompt"] == "login"
      assert idp["state"] =~ ~r/\A[0-9a-f]{32}\z/, "UIA keeps the legacy (SsoStore) state, never o2."
      assert {:ok, %{uia_session: ^session}} = Nebu.Matrix.SsoStore.peek_state(idp["state"])

      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"sub" => sub, "nonce" => idp["nonce"]}), nil})
      cb = T.callback([{"code", "c"}, {"state", idp["state"]}])
      assert cb.status == 200
      assert cb.resp_body =~ "Authentication complete"
      refute cb.resp_body =~ "oauth-error"

      assert %{rows: [[true]]} = T.sql!("SELECT stage_complete FROM uia_sessions WHERE session_id = $1", [session])
    end

    test "a full legacy round trip still mints a loginToken (no OAuth code)", %{priv: priv} do
      init = T.get("/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("http://localhost:7070/#/home"))
      assert init.status == 302
      idp = T.idp_params(init)
      T.stub_idp_exchange({:ok, T.sign_id_token(priv, %{"sub" => T.unique_sub(), "nonce" => idp["nonce"]}), nil})
      conn = T.callback([{"code", "c"}, {"state", idp["state"]}])
      assert conn.status == 302
      assert T.location(conn) =~ "loginToken="
      refute T.location(conn) =~ "iss="
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # D22 — module boundaries (ADR-020), static
  # ════════════════════════════════════════════════════════════════════════════

  describe "D22/ADR-020 — public API boundaries" do
    @lib Path.expand("../../../lib/nebu", __DIR__)

    test "Nebu.OAuth exposes the story-2 public functions; Nebu.Matrix the three IdP wrappers" do
      Code.ensure_loaded!(Nebu.OAuth)
      Code.ensure_loaded!(Nebu.Matrix)

      for {f, a} <- [oauth_idp_state?: 1, handle_idp_callback: 1, consume_authorization_code: 1, purge_expired_flow_state: 0],
          do: assert(function_exported?(Nebu.OAuth, f, a), "Nebu.OAuth.#{f}/#{a} missing")

      for {f, a} <- [idp_authorize_location: 2, idp_complete_login: 4, provision_login_user: 1],
          do: assert(function_exported?(Nebu.Matrix, f, a), "Nebu.Matrix.#{f}/#{a} missing")
    end

    test "oauth_idp_state?/1 is a pure o2. prefix check" do
      check = fn s -> apply(Nebu.OAuth, :oauth_idp_state?, [s]) end
      assert check.("o2.anything")
      assert check.("o2.")
      refute check.("O2.abc")
      refute check.(String.duplicate("a", 32))
      refute check.("")
      refute check.(nil)
      refute check.(["o2.x"])
    end

    test "the OAuth domain never calls Matrix internals; SsoLogin calls only the Nebu.OAuth facade" do
      oauth_src = Path.wildcard(Path.join(@lib, "oauth/*.ex")) |> Enum.map_join("\n", &File.read!/1)
      assert File.exists?(Path.join(@lib, "oauth/authorize.ex")), "Nebu.OAuth.Authorize (lib/nebu/oauth/authorize.ex) missing"

      for internal <- ~w(SsoLogin SsoStore TokenValidator OidcPlug Profile.DB EventDispatcher UserId) do
        refute oauth_src =~ ~r/Nebu\.Matrix\.#{Regex.escape(internal)}\b/, "lib/nebu/oauth must not call Nebu.Matrix.#{internal}"
      end

      sso = File.read!(Path.join(@lib, "matrix/sso_login.ex"))
      assert sso =~ "Nebu.OAuth.oauth_idp_state?"
      assert sso =~ "Nebu.OAuth.handle_idp_callback"
      refute sso =~ ~r/Nebu\.OAuth\.(Authorize|AuthzStore|CodeStore|Pages|Scope|AuthorizeRequest|ClientStore)\b/
    end
  end
end
