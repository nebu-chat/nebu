defmodule Nebu.Web.OidcPlugExpiredTest do
  @moduledoc """
  RED-phase ATDD test for the oidc-middleware-migration story.

  AC2: An expired Bearer token → 401 with
       {"errcode":"M_UNKNOWN_TOKEN","error":"Access token has expired"}.

  References `Nebu.Web.Plugs.OidcPlug` / `Nebu.Web.JwksCache`, which do not
  exist yet — this test MUST FAIL until the dev phase implements them.

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

  test "expired token → 401 M_UNKNOWN_TOKEN with 'Access token has expired'", %{priv_jwk: priv_jwk} do
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

    assert body == %{
             "errcode" => "M_UNKNOWN_TOKEN",
             "error" => "Access token has expired"
           }
  end
end
