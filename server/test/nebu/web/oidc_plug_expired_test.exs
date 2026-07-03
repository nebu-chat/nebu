defmodule Nebu.Web.OidcPlugExpiredTest do
  @moduledoc """
  Regression/pinning test for the oidc-middleware-migration story, covering the
  bugfix-jwt-soft-logout bug fix.

  AC2 (original): An expired Bearer token → 401 with errcode M_UNKNOWN_TOKEN
       and error "Access token has expired".

  bugfix-jwt-soft-logout AC1: a raw OIDC JWT that fails `call_jwt/2`
  verification specifically because `check_exp/1` returns `{:error, :expired}`
  MUST ALSO receive `"soft_logout" => true` in the 401 body — mirroring
  `call_opaque/1`'s already-correct behavior for expired opaque sessions (see
  `deny_soft_logout/3` in `Nebu.Web.Plugs.OidcPlug`). Per the Matrix
  Client-Server API spec (v1.18, soft logout), the underlying Nebu session
  (device binding, user, device_id) is still intact server-side for a JWT that
  merely expired naturally, so the client should be told it can recover via
  refresh/re-auth instead of wiping all local state (E2EE/device data).

  This pins the fix: `call_jwt/2`'s `{:error, :expired}` branch now calls
  `deny_soft_logout/3` instead of the plain `deny/3` (no `soft_logout` key).

  See `oidc_plug_test.exs` for the JWKS injectability design notes.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://dex.example.com/dex"
  @audience "nebu-gateway"
  @kid "test-key-1"

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})

    {_, priv_map} = JOSE.JWK.to_map(jwk)
    priv_map = Map.put(priv_map, "kid", @kid)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    {:ok, priv_jwk: priv_map}
  end

  defp sign_jwt(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  @opts Nebu.Web.Plugs.OidcPlug.init([])

  test "expired token → 401 M_UNKNOWN_TOKEN with 'Access token has expired' and soft_logout: true",
       %{priv_jwk: priv_jwk} do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => "kai",
      # exp 60 seconds in the past
      "exp" => System.system_time(:second) - 60,
      "iat" => System.system_time(:second) - 3660
    }

    token = sign_jwt(claims, priv_jwk)

    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "expired token must halt"
    assert conn.status == 401

    content_type =
      get_resp_header(conn, "content-type") |> List.first() |> to_string()

    assert String.contains?(content_type, "application/json")

    body = Jason.decode!(conn.resp_body)

    # bugfix-jwt-soft-logout AC1: a naturally-expired JWT is a SOFT logout —
    # the underlying Nebu session is still intact, so the client should be
    # told it can recover (refresh/re-auth) instead of wiping all local state.
    assert body == %{
             "errcode" => "M_UNKNOWN_TOKEN",
             "error" => "Access token has expired",
             "soft_logout" => true
           }
  end
end
