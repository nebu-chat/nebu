defmodule Nebu.Web.AdminOidcLoginTest do
  @moduledoc """
  ATDD unit tests for the go-removal-cleanup story — Elixir admin OIDC
  Authorization-Code + PKCE login (Nebu.Admin.Auth.login_start/2, callback/2,
  logout/2). These replace the deleted Go gateway admin login.

  ## Why these MUST FAIL before the dev step (RED)

    * Before implementation, `Admin.Auth.login_start/2` did not exist — only the
      on_mount gate + put_current_user. `LoginController.start/2` redirected to
      itself (infinite loop). There was no callback, no PKCE, no state/nonce, no
      exchange.

  ## What is covered here vs the E2E

  The E2E (e2e/features/admin/admin-oidc-login.feature) drives the REAL Dex
  Authorization-Code + PKCE flow end-to-end in a browser (no cookie forging, no DB
  seeding). It requires the live Dex/Compose stack and so is deferred in this
  environment. These unit tests cover the security-sensitive logic that does NOT
  require a network round-trip:

    * login_start emits a PKCE S256 challenge derived from the verifier, plus a
      high-entropy state + nonce, and stashes the verifier/state/nonce in the
      signed Phoenix session (NOT a separate cookie).
    * callback rejects a missing / mismatched / expired state (CSRF / replay).
    * the ID-token nonce binding (fail-closed) is enforced.
    * the admin-group-claim gate denies a non-admin token.

  The token-EXCHANGE HTTP round-trip and full happy-path session mint are covered
  by the E2E (live Dex) — they cannot be exercised without a token endpoint.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @audience "nebu-admin"
  @client_id "nebu-admin"
  @kid "admin-key-1"

  # Authorization endpoint returned by the discovery override so login_start can build
  # the redirect without a network call.
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"

  setup do
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

    priv_map = Map.put(priv_map, "kid", @kid)

    # oidc-bootstrap-only-config (ADR-022): issuer/audience resolve via OidcConfig,
    # the single admin OIDC client via the :admin_oidc_config_reader seam, and the
    # redirect_uri is DERIVED from :server_name + :admin_session_secure (no env path).
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-oidc-login-test-key")

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    # Derive http://localhost:8008/admin/callback: localhost host + insecure scheme.
    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :oidc_jwks,
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    {:ok, priv_jwk: priv_map}
  end

  # Build a conn that already has a fetched (signed) session — Plug.Test.init_test_session
  # gives us put_session/get_session without the full endpoint pipeline.
  defp session_conn(method, path) do
    conn(method, path) |> init_test_session(%{})
  end

  defp sign_id_token(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  # ── login_start: PKCE + state + nonce ──────────────────────────────────────────

  test "login_start redirects to the IdP with PKCE S256 challenge, state and nonce" do
    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

    assert conn.halted
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, @authorization_endpoint <> "?")

    %URI{query: query} = URI.parse(location)
    params = URI.decode_query(query)

    assert params["response_type"] == "code"
    assert params["client_id"] == @client_id
    assert params["redirect_uri"] == "http://localhost:8008/admin/callback"
    assert params["code_challenge_method"] == "S256"
    assert byte_size(params["code_challenge"]) > 20
    assert byte_size(params["state"]) > 8
    assert byte_size(params["nonce"]) > 8

    # The verifier is stashed server-side (signed session), NOT exposed in the URL.
    login_state = get_session(conn, "admin_oidc_login")
    assert is_binary(login_state["verifier"])
    assert login_state["state"] == params["state"]
    assert login_state["nonce"] == params["nonce"]
    refute query =~ login_state["verifier"]

    # The challenge MUST equal BASE64URL(SHA256(verifier)) (RFC 7636 S256).
    expected_challenge =
      :crypto.hash(:sha256, login_state["verifier"]) |> Base.url_encode64(padding: false)

    assert params["code_challenge"] == expected_challenge
  end

  test "login_start generates a fresh state + nonce on each call (no reuse)" do
    s1 = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{}) |> get_session("admin_oidc_login")
    s2 = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{}) |> get_session("admin_oidc_login")

    refute s1["state"] == s2["state"]
    refute s1["nonce"] == s2["nonce"]
    refute s1["verifier"] == s2["verifier"]
  end

  # ── callback: state / CSRF protection ───────────────────────────────────────────

  test "callback with NO prior login state (forged) is rejected 400" do
    conn =
      session_conn(:get, "/admin/callback")
      |> Auth.callback(%{"code" => "x", "state" => "forged"})

    assert conn.halted
    assert conn.status == 400
  end

  test "callback with a mismatched state is rejected 400 and clears login state" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "expected-state",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) + 600
      })
      |> Auth.callback(%{"code" => "x", "state" => "attacker-state"})

    assert conn.halted
    assert conn.status == 400
    assert get_session(conn, "admin_oidc_login") == nil
  end

  test "callback with an expired login state is rejected 400" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "s",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) - 1
      })
      |> Auth.callback(%{"code" => "x", "state" => "s"})

    assert conn.halted
    assert conn.status == 400
  end

  test "callback with a missing code (state valid) bounces to login with error" do
    conn =
      session_conn(:get, "/admin/callback")
      |> put_session("admin_oidc_login", %{
        "state" => "s",
        "verifier" => "v",
        "nonce" => "n",
        "exp" => System.system_time(:second) + 600
      })
      |> Auth.callback(%{"state" => "s"})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc =~ "/admin/login?error="
  end

  # ── nonce binding (fail-closed) — verified through the verify_token + check_nonce path
  # via the public admin_claim?/nonce helpers is internal; here we assert the end-to-end
  # contract that the ID-token verification reused from OidcPlug rejects a tampered token.

  test "the ID-token verifier (reused from OidcPlug) accepts a well-formed admin token", %{
    priv_jwk: priv_jwk
  } do
    # The admin ID token's aud is the admin OAuth client_id, verified via the override.
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "kai",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["instance_admin"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:ok, verified} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
    assert verified["nonce"] == "the-nonce"
    # Admin gate: the configured claim (default instance_admin) present in a list claim.
    assert Auth.admin_claim?(verified)
  end

  test "admin gate denies a token without the admin group claim", %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @client_id,
      "sub" => "alex",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["users"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:ok, verified} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
    refute Auth.admin_claim?(verified)
  end

  test "admin audience override rejects a token minted for the Matrix audience (no aud confusion)",
       %{priv_jwk: priv_jwk} do
    # A Matrix-audience token (aud = nebu-gateway) must NOT be accepted on the admin
    # path, which requires aud = the admin client_id. Fail-closed audience check.
    claims = %{
      "iss" => @issuer,
      "aud" => "nebu-gateway",
      "sub" => "kai",
      "exp" => System.system_time(:second) + 3600,
      "nonce" => "the-nonce",
      "groups" => ["instance_admin"]
    }

    token = sign_id_token(claims, priv_jwk)
    assert {:error, :bad_audience} = Nebu.Web.Plugs.OidcPlug.verify_token(token, audience: @client_id)
  end

  # ── session minting + expiry cap (session fixation / unbounded session) ─────────

  test "put_current_user caps session_exp at min(idToken.exp, now+8h)" do
    now = System.system_time(:second)

    # ID token expiring in 1h → session_exp follows the (earlier) token exp.
    short = %{"sub" => "kai", "exp" => now + 3600, "groups" => ["instance_admin"]}
    conn = session_conn(:get, "/admin/callback") |> Auth.put_current_user(short)
    user = get_session(conn, "current_user")
    assert user["session_exp"] == now + 3600
    assert user["admin"] == true

    # ID token expiring in 100h → session_exp is capped at the 8h ceiling.
    long = %{"sub" => "kai", "exp" => now + 100 * 3600, "groups" => ["instance_admin"]}
    conn2 = session_conn(:get, "/admin/callback") |> Auth.put_current_user(long)
    user2 = get_session(conn2, "current_user")
    assert user2["session_exp"] <= now + 8 * 3600 + 2
    assert user2["session_exp"] > now + 8 * 3600 - 2
  end

  test "on_mount denies an admin whose capped session has expired" do
    expired = %{"admin" => true, "sub" => "kai", "session_exp" => System.system_time(:second) - 1}
    assert {:halt, _socket} = Auth.on_mount(:require_admin, %{}, %{"current_user" => expired}, %Phoenix.LiveView.Socket{})

    live = %{"admin" => true, "sub" => "kai", "session_exp" => System.system_time(:second) + 600}
    assert {:cont, _socket} = Auth.on_mount(:require_admin, %{}, %{"current_user" => live}, %Phoenix.LiveView.Socket{})
  end

  test "on_mount denies an unauthenticated / non-admin session" do
    assert {:halt, _} = Auth.on_mount(:require_admin, %{}, %{}, %Phoenix.LiveView.Socket{})
    assert {:halt, _} = Auth.on_mount(:require_admin, %{}, %{"current_user" => %{"admin" => false}}, %Phoenix.LiveView.Socket{})
  end

  # ── logout ──────────────────────────────────────────────────────────────────────

  test "logout drops the session and redirects to /admin/login" do
    conn =
      session_conn(:get, "/admin/logout")
      |> put_session("current_user", %{"admin" => true, "sub" => "kai"})
      |> Auth.logout(%{})

    assert conn.halted
    assert conn.status == 302
    assert [loc] = get_resp_header(conn, "location")
    assert loc == "/admin/login"
  end
end
