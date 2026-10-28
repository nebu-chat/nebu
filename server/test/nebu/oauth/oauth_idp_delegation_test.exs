defmodule Nebu.OAuth.OAuthIdpDelegationTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC6 (+ D2-D4, D11,
  D12, D19, D23, AC10 row contents, AC13): a fully valid authorize request is persisted in
  `oauth_authz_requests` (DB, cluster safe, NOT `SsoStore`) and the browser is sent to the ONE IdP
  client through the shared SsoLogin IdP-URL builder (`Nebu.Matrix.idp_authorize_location/2`).

  IdP stub: the existing SsoLogin seams (`:oidc_metadata_override`, `:sso_bootstrap_reader`,
  `:oidc_jwks`, scope readers) — see `Nebu.OAuth.TestSupport.setup_idp!/1`.

  Cluster safety / crash-restart: the flow state lives ONLY in the database row (the test asserts
  that the SsoStore does not know the OAuth state), so any node can complete the callback and a
  node restart loses nothing; single use is proven in `oauth_idp_callback_test.exs`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @loop "http://localhost:53682/cb"
  @legacy_keys ~w(response_type client_id redirect_uri scope state nonce code_challenge code_challenge_method prompt)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, priv: priv, cid: T.oauth_client!([@https, "http://localhost/cb"])}
  end

  defp legacy_idp_params(headers \\ []) do
    conn =
      Plug.Test.conn(:get, "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("https://app.example.com/#/home"))
      |> T.put_headers(headers)
      |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

    assert conn.status == 302
    T.idp_params(conn)
  end

  defp authz_row(state) do
    case T.sql!("SELECT * FROM oauth_authz_requests WHERE state_hash = $1", [T.sha256_hex(state)]) do
      %{rows: [row], columns: cols} -> cols |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end

  describe "AC6 — the IdP authorize URL (one builder for legacy and OAuth)" do
    test "302 to the IdP authorization_endpoint with the legacy parameter set", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      idp = flow.idp

      # Deliberate update (review cycle 2, Kassandra F-2): the OAuth leg is the legacy parameter set PLUS
      # max_age=0 (`prompt=login` alone is advisory; max_age=0 forces a genuinely fresh IdP login).
      assert idp |> Map.keys() |> Enum.sort() == Enum.sort(["max_age" | @legacy_keys]),
             "the OAuth IdP request must be the legacy parameter set plus max_age, got #{inspect(Map.keys(idp))}"

      assert idp["response_type"] == "code"
      assert idp["client_id"] == "nebu-client", "the ONE IdP client (ADR-022)"
      assert idp["code_challenge_method"] == "S256"
      assert idp["code_challenge"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert idp["prompt"] == "login", "legacy parity (D11)"
      assert idp["max_age"] == "0", "F-2: force a fresh IdP authentication"
      assert idp["redirect_uri"] == legacy_idp_params()["redirect_uri"], "the SHARED registered callback (D1)"
      assert String.ends_with?(idp["redirect_uri"], "/_matrix/client/v3/login/sso/redirect/oidc")
    end

    test "D2: the IdP-leg state is o2. + 43 base64url chars (46 chars); nonce random", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      assert flow.state =~ ~r/\Ao2\.[A-Za-z0-9_-]{43}\z/
      assert byte_size(flow.state) == 46
      assert is_binary(flow.nonce) and byte_size(flow.nonce) >= 32

      other = T.start_flow(cid, @https)
      refute other.state == flow.state
      refute other.nonce == flow.nonce
    end

    test "the IdP code_challenge is NOT the client's code_challenge (separate PKCE legs)", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      refute flow.idp["code_challenge"] == T.param(flow.pairs, "code_challenge")
    end

    test "the request's Host / X-Forwarded-Proto decide the callback URL exactly like legacy", %{cid: cid} do
      headers = [{"host", "nebu.example.com"}, {"x-forwarded-proto", "https"}]
      flow = T.start_flow(cid, @https, %{}, headers: headers)
      assert flow.idp["redirect_uri"] == "https://nebu.example.com/_matrix/client/v3/login/sso/redirect/oidc"
      assert flow.idp["redirect_uri"] == legacy_idp_params(headers)["redirect_uri"]
    end

    test "unknown parameters are not forwarded to the IdP (D12)", %{cid: cid} do
      extra = %{
        "action" => "register",
        "login_hint" => "alice",
        "max_age" => "0",
        "ui_locales" => "de",
        "claims" => "{}",
        "request" => "eyJ",
        "request_uri" => "https://evil.example.com/r"
      }

      flow = T.start_flow(cid, @https, extra)
      # max_age: the CLIENT's value is ignored; Nebu's own max_age=0 (F-2) is always present
      for k <- Map.keys(extra) -- ["max_age"], do: refute(Map.has_key?(flow.idp, k), "#{k} must not reach the IdP")
      assert flow.idp["max_age"] == "0"
      refute T.location(flow.conn) =~ "evil.example.com"
      refute T.location(flow.conn) =~ "alice"
    end
  end

  describe "AC6 — OIDC Scopes Law for the IdP leg (must-test 20)" do
    test "default: scope is ONLY openid (== OidcScopes.resolve_scope(:matrix))", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      assert flow.idp["scope"] == "openid"
      assert flow.idp["scope"] == Nebu.Web.OidcScopes.resolve_scope(:matrix)
    end

    test "configured extras are appended, nothing hardcoded", %{cid: cid} do
      Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> "profile email groups" end)
      flow = T.start_flow(cid, @https)
      assert String.split(flow.idp["scope"]) == ~w(openid profile email groups)
      assert flow.idp["scope"] == legacy_idp_params()["scope"]
    end

    test "offline_access iff matrix_oidc_refresh_mode is offline", %{cid: cid} do
      Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "offline" end)
      assert "offline_access" in String.split(T.start_flow(cid, @https).idp["scope"])

      Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)
      refute "offline_access" in String.split(T.start_flow(cid, @https).idp["scope"])
    end

    test "the CLIENT's Matrix scope and openid never reach the IdP scope", %{cid: cid} do
      flow = T.start_flow(cid, @https, %{"scope" => T.js_sdk_scope()})
      refute flow.idp["scope"] =~ "urn:matrix"
    end
  end

  describe "D11 — prompt toward the IdP" do
    test "client prompt=create is forwarded ONLY when the IdP lists create in prompt_values_supported", %{cid: cid} do
      assert T.start_flow(cid, @https, %{"prompt" => "create"}).idp["prompt"] == "login"

      Application.put_env(
        :nebu_http,
        :oidc_metadata_override,
        Map.put(Application.get_env(:nebu_http, :oidc_metadata_override), "prompt_values_supported", ["none", "login", "create"])
      )

      create = T.start_flow(cid, @https, %{"prompt" => "create"}).idp
      assert create["prompt"] == "create"
      assert create["max_age"] == "0", "F-2: max_age=0 also when prompt=create replaces prompt=login"
      assert T.start_flow(cid, @https, %{"prompt" => "consent"}).idp["prompt"] == "login"
      assert T.start_flow(cid, @https).idp["prompt"] == "login"
    end
  end

  describe "AC6/AC10/D2/D3 — the persisted oauth_authz_requests row" do
    test "keyed by sha256(state); the plaintext state and cookie value appear in no column", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      row = authz_row(flow.state)
      assert row, "a row keyed by state_hash = sha256_hex(state) must exist"
      {_name, cookie_value} = flow.cookie

      for {col, v} <- row, is_binary(v) do
        refute v == flow.state, "column #{col} holds the plaintext IdP state"
        refute v =~ flow.state
        refute v == cookie_value, "column #{col} holds the plaintext binding cookie"
      end

      assert row["browser_binding_hash"] == T.sha256_hex(cookie_value)
    end

    test "stores the client request: client_id, exact redirect URI, client challenge, device, scope, prefix, mode, state", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      row = authz_row(flow.state)
      assert row["client_id"] == cid
      assert row["redirect_uri"] == @https
      assert row["code_challenge"] == T.param(flow.pairs, "code_challenge")
      assert row["device_id"] == "AbCdEfGhIj"
      assert row["scope"] == "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"
      assert row["scope_prefix"] == "urn:matrix:client:"
      assert row["response_mode"] == "fragment"
      assert row["client_state"] == T.param(flow.pairs, "state")
      assert row["client_nonce"] == nil
      assert row["openid_requested"] == false
    end

    test "the IdP verifier is stored ONLY SecretBox-encrypted and matches the IdP challenge; the IdP nonce in plain", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      row = authz_row(flow.state)
      assert row["idp_nonce"] == flow.nonce

      enc = row["idp_code_verifier_enc"]
      assert {:ok, verifier} = Nebu.Web.SecretBox.decrypt(enc)
      refute enc == verifier
      assert :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false) == flow.idp["code_challenge"]
    end

    test "expires_at = created_at + 600 s (D3 TTL)", %{cid: cid} do
      flow = T.start_flow(cid, @https)

      %{rows: [[secs]]} =
        T.sql!("SELECT extract(epoch FROM expires_at - created_at)::int FROM oauth_authz_requests WHERE state_hash = $1", [
          T.sha256_hex(flow.state)
        ])

      assert secs in 595..600
    end

    test "js-sdk 41.3.0 request: openid_requested + client_nonce stored, nonce NEVER sent to the IdP (D23, must-test 27)", %{cid: cid} do
      client_nonce = "js-sdk-client-nonce-" <> T.rand()
      flow = T.start_flow(cid, @https, %{"scope" => T.js_sdk_scope(), "nonce" => client_nonce, "response_mode" => "query"})
      row = authz_row(flow.state)

      assert row["openid_requested"] == true
      assert row["client_nonce"] == client_nonce
      assert row["scope"] == T.js_sdk_scope()
      assert row["scope_prefix"] == "urn:matrix:org.matrix.msc2967.client:"
      assert row["response_mode"] == "query", "explicit query honoured for https (D10)"
      refute flow.idp["nonce"] == client_nonce
      refute T.location(flow.conn) =~ client_nonce
    end

    test "absent state => client_state NULL; loopback URI stored WITH its port; default mode query", %{cid: cid} do
      flow = T.start_flow(cid, @loop, %{"state" => nil})
      row = authz_row(flow.state)
      assert row["client_state"] == nil
      assert row["redirect_uri"] == @loop
      assert row["response_mode"] == "query"
    end

    test "D3: NOTHING of the OAuth flow is kept in the node-local SsoStore", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      assert Nebu.Matrix.SsoStore.peek_state(flow.state) == :error
    end
  end

  describe "D4 — browser binding cookie" do
    test "per-flow name nebu_oa_<16 hex of state_hash>, 32 random bytes, HttpOnly, SameSite=Lax, callback path, Max-Age=600", %{cid: cid} do
      flow = T.start_flow(cid, @https)
      {name, value, raw} = T.binding_cookie(flow.conn)

      assert name == T.binding_cookie_name(flow.state)
      assert value =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert raw =~ ~r/;\s*HttpOnly/i
      assert raw =~ ~r/;\s*SameSite=Lax/i
      assert raw =~ ~r/;\s*path=\/_matrix\/client\/v3\/login\/sso\/redirect\/oidc(;|\z)/i
      assert raw =~ ~r/;\s*max-age=600(;|\z)/i
      refute raw =~ ~r/;\s*secure/i, "plain http request => no Secure attribute"
    end

    test "https request (X-Forwarded-Proto, like callback_url/1): __Host-nebu_oa_<16 hex>, Path=/, Secure, no Domain (HY9)", %{cid: cid} do
      # story oauth-hardening-hygiene HY9: changed by design (was: same name + callback path + Secure)
      flow = T.start_flow(cid, @https, %{}, headers: [{"x-forwarded-proto", "https"}])
      {name, _value, raw} = T.binding_cookie(flow.conn)
      assert name == T.binding_cookie_name(flow.state, true)
      assert name =~ ~r/\A__Host-nebu_oa_[0-9a-f]{16}\z/
      assert raw =~ ~r/;\s*secure/i
      assert raw =~ ~r/;\s*path=\/(;|\z)/i
      refute raw =~ ~r/domain=/i
    end

    test "two parallel logins (two tabs) get two different cookie names", %{cid: cid} do
      a = T.start_flow(cid, @https)
      b = T.start_flow(cid, @https)
      refute elem(a.cookie, 0) == elem(b.cookie, 0)
      refute elem(a.cookie, 1) == elem(b.cookie, 1)
    end
  end

  describe "AC13 — headers of the 302 to the IdP" do
    test "no-store, no-referrer, nosniff, no CORS even with an Origin header", %{cid: cid} do
      flow = T.start_flow(cid, @https, %{}, origin: "https://client.example.com")
      conn = flow.conn
      assert T.header(conn, "cache-control") =~ "no-store"
      assert T.header(conn, "pragma") == "no-cache"
      assert T.header(conn, "referrer-policy") == "no-referrer"
      assert T.header(conn, "x-content-type-options") == "nosniff"
      for {k, _} <- conn.resp_headers, do: refute(String.starts_with?(k, "access-control-"))
    end
  end

  describe "AC6/D19 — failures before the IdP redirect => temporarily_unavailable, nothing persisted" do
    test "IdP discovery failure", %{cid: cid} do
      Application.put_env(:nebu_http, :oidc_metadata_override, %{"issuer" => T.idp_issuer()})
      pairs = T.authorize_params(cid, @https)
      T.assert_error_redirect(T.authorize(pairs), @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0
    end

    test "IdP client not configured (no oidc_client_id in server_config)", %{cid: cid} do
      Application.put_env(:nebu_http, :sso_bootstrap_reader, fn _ -> nil end)
      pairs = T.authorize_params(cid, @https)
      T.assert_error_redirect(T.authorize(pairs), @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0
    end

    test "SecretBox without an internal secret => server_error redirect, no row, never a 500 (AC6, Trap 9)", %{cid: cid} do
      saved = for k <- ~w(NEBU_INTERNAL_SECRET NEBU_INTERNAL_SECRET_FILE), do: {k, System.get_env(k)}
      for {k, _} <- saved, do: System.delete_env(k)
      Application.delete_env(:nebu_http, :admin_secret_at_rest)

      on_exit(fn ->
        for {k, v} <- saved, v != nil, do: System.put_env(k, v)
      end)

      pairs = T.authorize_params(cid, @https)
      conn = T.authorize(pairs)
      assert conn.status == 302
      T.assert_error_redirect(conn, @https, "server_error", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0
    end

    test "live-request cap (10 000) reached => temporarily_unavailable, no new row", %{cid: cid} do
      filler = T.oauth_client!([@https])
      %{rows: [[live]]} = T.sql!("SELECT count(*) FROM oauth_authz_requests WHERE expires_at > now()")
      missing = max(10_000 - live, 0)

      T.sql!(
        "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, " <>
          "scope_prefix, response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, expires_at) " <>
          "SELECT 'atdd-cap-' || $1::text || '-' || g, $2, 'https://app.example.com/cb', 'c', 'D', 's', " <>
          "'urn:matrix:client:', 'fragment', 'enc', 'n', 'b', now() + interval '5 minutes' FROM generate_series(1, $3::int) g",
        [T.rand(), filler, missing]
      )

      pairs = T.authorize_params(cid, @https)
      T.assert_error_redirect(T.authorize(pairs), @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0

      # once the filler rows are gone (FK cascade) the next request is accepted again
      T.cleanup_clients([filler])
      assert T.authorize(T.authorize_params(cid, @https)).status == 302
      assert T.count_for("oauth_authz_requests", cid) == 1
    end
  end

  describe "D19 — the cap counts only LIVE requests" do
    test "10 000 expired rows do not block a new request", %{cid: cid} do
      filler = T.oauth_client!([@https])
      %{rows: [[live]]} = T.sql!("SELECT count(*) FROM oauth_authz_requests WHERE expires_at > now()")
      assert live < 10_000

      T.sql!(
        "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, " <>
          "scope_prefix, response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, created_at, expires_at) " <>
          "SELECT 'atdd-exp-' || $1::text || '-' || g, $2, 'https://app.example.com/cb', 'c', 'D', 's', " <>
          "'urn:matrix:client:', 'fragment', 'enc', 'n', 'b', now() - interval '11 minutes', now() - interval '1 minute' " <>
          "FROM generate_series(1, 10000) g",
        [T.rand(), filler]
      )

      assert T.authorize(T.authorize_params(cid, @https)).status == 302
      assert T.count_for("oauth_authz_requests", cid) == 1
    end
  end

  describe "D11/must-test 31 — prompt=none never contacts the IdP" do
    test "with a broken IdP discovery prompt=none still answers login_required (no discovery, no row)", %{cid: cid} do
      Application.put_env(:nebu_http, :oidc_metadata_override, %{"issuer" => T.idp_issuer()})
      Application.put_env(:nebu_http, :sso_bootstrap_reader, fn _ -> nil end)
      pairs = T.authorize_params(cid, @https, %{"prompt" => "none"})
      T.assert_error_redirect(T.authorize(pairs), @https, "login_required", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0
    end
  end

  describe "AC6/AC24 — legacy /sso/redirect output stays identical (must-test 24)" do
    test "legacy IdP URL: exactly the legacy keys, prompt=login, no max_age, 32-hex state in the SsoStore" do
      idp = legacy_idp_params()
      assert idp |> Map.keys() |> Enum.sort() == Enum.sort(@legacy_keys)
      assert idp["prompt"] == "login"
      refute Map.has_key?(idp, "max_age")
      assert idp["state"] =~ ~r/\A[0-9a-f]{32}\z/
      assert {:ok, %{redirect_url: "https://app.example.com/#/home"}} = Nebu.Matrix.SsoStore.peek_state(idp["state"])
    end

    test "legacy flow is unaffected by OAuth being enabled or disabled" do
      T.disable_oauth()
      disabled = legacy_idp_params() |> Map.drop(~w(state nonce code_challenge))
      T.enable_oauth()
      enabled = legacy_idp_params() |> Map.drop(~w(state nonce code_challenge))
      assert disabled == enabled
    end
  end
end
