defmodule Nebu.Matrix.MatrixSsoTest do
  @moduledoc """
  RED-phase ATDD tests for `bugfix-fix-matrix-sso-redirect-missing`.

  The Matrix client SSO leg (`GET /_matrix/client/v3/login/sso/redirect[/{idpId}]`
  and its OIDC callback `.../sso/redirect/oidc`) was deleted with the Go stack
  (`c1231ac6`, `gateway/internal/matrix/sso.go`) and never ported to Elixir. The
  `m.login.sso` flow advertised by `GET /login` therefore dead-ends in a 404 and no
  Matrix client (Element Web, …) can initiate SSO login.

  These tests encode the 4 in-process ACs (AC5 is the Element Playwright E2E,
  verified later). They MUST FAIL initially: the routes do not exist yet, so the
  forward `/_matrix/client/v3/login` → `HttpPublic` falls through to its
  `match _ -> 404` clause.

  ## Design under test (Option A — opaque single-use loginToken)

    * `GET /sso/redirect?redirectUrl=<allowed>` validates the redirectUrl against a
      scheme allowlist (open-redirect protection), generates state+nonce+PKCE,
      persists them in the cluster-aware SSO state store, and 302s to the IdP
      authorize endpoint.
    * The callback exchanges the code, verifies the id_token + nonce, mints a
      short-lived single-use opaque `loginToken` mapped to the verified id_token in
      the cluster-aware login-token store, then 302s back to redirectUrl with
      `?loginToken=<opaque>`.
    * `POST /login {type:m.login.token, token:<opaque>}` resolves the opaque token
      to the stored id_token, verifies it via the SAME `OidcPlug.verify_token` path,
      and returns `access_token`/`user_id`/`device_id`. Single-use: the second
      redemption fails.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "matrix-sso-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  # Generate an in-test RSA keypair; inject the public JWK so OidcPlug verifies
  # without a network call; return the private JWK for signing the id_token.
  defp setup_oidc do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    # oidc-bootstrap-only-config (ADR-022): issuer/audience via OidcConfig, the single
    # SSO OIDC client via the :sso_bootstrap_reader seam. No env config path.
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "matrix-sso-test-key")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("shhh")
      _ -> nil
    end)

    # Discovery seam: OidcMetadata.fetch returns this document (no network).
    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :server_name,
            :oidc_jwks,
            :admin_secret_at_rest,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_sso_token_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    priv_jwk
  end

  defp sign_id_token(priv_jwk, claims_overrides) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => "alex",
          "exp" => future_exp(),
          "iat" => System.system_time(:second)
        },
        claims_overrides
      )

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  setup do
    # The cluster-aware SSO store is a supervised GenServer owning an ETS table.
    # It is started by the application tree when :nebu boots; in a bare unit run it
    # may not be, so start it only when absent (and let the app-owned one stand).
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 1 (AC1) — GET /sso/redirect → 302 to the IdP authorize endpoint
  # ════════════════════════════════════════════════════════════════════════════

  describe "GET /_matrix/client/v3/login/sso/redirect (AC1)" do
    test "302s to the issuer authorize endpoint carrying state + nonce + PKCE" do
      _priv = setup_oidc()
      redirect_url = "http://localhost:7070"

      conn =
        call(:get, "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(redirect_url))

      assert conn.status == 302
      loc = location(conn)
      assert is_binary(loc)
      assert String.starts_with?(loc, @authorize)

      %URI{query: q} = URI.parse(loc)
      params = URI.decode_query(q)
      assert params["response_type"] == "code"
      assert params["client_id"] == "nebu-client"
      assert is_binary(params["state"]) and params["state"] != ""
      assert is_binary(params["nonce"]) and params["nonce"] != ""
      assert params["code_challenge_method"] == "S256"
      assert is_binary(params["code_challenge"]) and params["code_challenge"] != ""

      # The state must be persisted so the callback can resolve it.
      assert {:ok, entry} = SsoStore.peek_state(params["state"])
      assert entry.redirect_url == redirect_url
    end

    test "/sso/redirect/{idpId} also 302s to the authorize endpoint" do
      _priv = setup_oidc()

      conn =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect/oidc?redirectUrl=" <>
            URI.encode_www_form("http://localhost:7070")
        )

      assert conn.status == 302
      assert String.starts_with?(location(conn), @authorize)
    end

    test "missing redirectUrl → 400 M_MISSING_PARAM (no redirect)" do
      _priv = setup_oidc()
      conn = call(:get, "/_matrix/client/v3/login/sso/redirect")
      assert conn.status == 400
      assert json(conn)["errcode"] in ["M_MISSING_PARAM", "M_INVALID_PARAM"]
      assert location(conn) == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 2 (AC2) — open-redirect protection
  # ════════════════════════════════════════════════════════════════════════════

  describe "open-redirect protection (AC2)" do
    test "javascript: scheme is rejected with 400 and no redirect" do
      _priv = setup_oidc()

      conn =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("javascript:alert(1)")
        )

      assert conn.status == 400
      assert location(conn) == nil
    end

    test "off-host http:// (non-loopback) is rejected with 400" do
      _priv = setup_oidc()

      conn =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("http://evil.example.com/steal")
        )

      assert conn.status == 400
      assert location(conn) == nil
    end

    test "data: scheme is rejected with 400" do
      _priv = setup_oidc()

      conn =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("data:text/html,<script>1</script>")
        )

      assert conn.status == 400
      assert location(conn) == nil
    end

    test "https:// (any host) is allowed" do
      _priv = setup_oidc()

      conn =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("https://app.example.com/#/home")
        )

      assert conn.status == 302
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 3 (AC3) — callback with a bad/forged state is rejected fail-closed (CSRF)
  # ════════════════════════════════════════════════════════════════════════════

  describe "callback CSRF state check (AC3)" do
    test "callback with an unknown state → rejected, no token minted" do
      _priv = setup_oidc()

      conn =
        call(:get, "/_matrix/client/v3/login/sso/redirect/oidc?code=somecode&state=bogus-unknown-state")

      # Fail-closed: anything but a 302-with-loginToken back to a client is a reject.
      assert conn.status in [400, 403]
      loc = location(conn)
      refute is_binary(loc) and String.contains?(to_string(loc), "loginToken=")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 4 (AC3+AC4) — full callback → loginToken → POST /login → access_token,
  # and the loginToken is single-use.
  # ════════════════════════════════════════════════════════════════════════════

  describe "callback mints loginToken; POST /login completes (AC3, AC4)" do
    @describetag :integration

    setup do
      priv = setup_oidc()

      # Provision the user up-front so TokenValidator.validate finds the row
      # (mirrors the matrix_router_test integration fixture).
      uid = "@alex:" <> @server_name

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Alex", "alex@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Alex", nil)
      end

      {:ok, priv_jwk: priv, user_id: uid}
    end

    test "valid callback 302s back with loginToken; POST /login → 200; single-use", %{
      priv_jwk: priv,
      user_id: uid
    } do
      redirect_url = "http://localhost:7070/#/home"

      # 1) Initiate to obtain a real, persisted state + nonce.
      init =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(redirect_url)
        )

      assert init.status == 302
      params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      state = params["state"]
      nonce = params["nonce"]
      assert is_binary(state) and is_binary(nonce)

      # 2) Stub the IdP code-exchange to return an id_token carrying the SSO nonce.
      id_token = sign_id_token(priv, %{"sub" => "alex", "nonce" => nonce})
      Application.put_env(:nebu_http, :matrix_sso_token_override, fn -> {:ok, id_token} end)

      # 3) Callback with the valid state + code.
      cb =
        call(
          :get,
          "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <> URI.encode_www_form(state)
        )

      assert cb.status == 302
      loc = location(cb)
      assert String.starts_with?(loc, "http://localhost:7070/")

      cb_query =
        case URI.parse(loc) do
          %URI{query: q} when is_binary(q) -> URI.decode_query(q)
          _ -> %{}
        end

      login_token = cb_query["loginToken"]
      assert is_binary(login_token) and login_token != ""
      # The opaque loginToken must NOT be the raw id_token JWT.
      refute login_token == id_token
      refute String.contains?(login_token, ".")

      # 4) POST /login with the opaque loginToken → 200 with the session fields.
      resp = call(:post, "/_matrix/client/v3/login", %{"type" => "m.login.token", "token" => login_token})
      assert resp.status == 200
      body = json(resp)
      assert body["user_id"] == uid
      assert is_binary(body["access_token"])
      assert is_binary(body["device_id"])
      assert body["token_type"] == "Bearer"

      # 5) Single-use: a second redemption of the same loginToken fails.
      resp2 = call(:post, "/_matrix/client/v3/login", %{"type" => "m.login.token", "token" => login_token})
      assert resp2.status in [400, 403]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Store-level unit tests: TTL + single-use + cluster-aware shape
  # ════════════════════════════════════════════════════════════════════════════

  describe "SsoStore (cluster-aware, single-use, TTL)" do
    test "login token is single-use (pop removes it)" do
      SsoStore.put_login_token("tok-1", "the-id-token", 30)
      # oidc-session-refresh: pop now returns a 3-tuple {id_token, oidc_refresh_token};
      # the OIDC RT is nil when none was supplied at put time.
      assert {:ok, "the-id-token", nil} = SsoStore.pop_login_token("tok-1")
      assert :error = SsoStore.pop_login_token("tok-1")
    end

    test "login token carries the OIDC refresh token when supplied" do
      SsoStore.put_login_token("tok-rt", "id-tok", 30, oidc_refresh_token: "oidc-rt")
      assert {:ok, "id-tok", "oidc-rt"} = SsoStore.pop_login_token("tok-rt")
    end

    test "an expired login token is treated as absent" do
      SsoStore.put_login_token("tok-2", "id", -1)
      assert :error = SsoStore.pop_login_token("tok-2")
    end

    test "state is single-use (pop removes it)" do
      SsoStore.put_state("st-1", %{verifier: "v", nonce: "n", redirect_url: "http://localhost"}, 600)
      assert {:ok, entry} = SsoStore.pop_state("st-1")
      assert entry.nonce == "n"
      assert :error = SsoStore.pop_state("st-1")
    end
  end
end
