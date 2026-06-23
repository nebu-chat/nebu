defmodule Nebu.Web.OidcPlugMissingTokenTest do
  @moduledoc """
  RED-phase ATDD test for the oidc-middleware-migration story.

  AC4: No Authorization header → 401 with
       {"errcode":"M_MISSING_TOKEN","error":"Missing access token"}.

  References `Nebu.Web.Plugs.OidcPlug`, which does not exist yet — this test
  MUST FAIL until the dev phase implements it.

  Note: this path requires NO JWKS at all (the plug rejects before any
  signature verification), so no key injection is needed here.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Nebu.Web.Plugs.OidcPlug.init([])

  test "no Authorization header → 401 M_MISSING_TOKEN with 'Missing access token'" do
    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted, "missing token must halt"
    assert conn.status == 401

    content_type =
      get_resp_header(conn, "content-type") |> List.first() |> to_string()

    assert String.contains?(content_type, "application/json")

    body = Jason.decode!(conn.resp_body)

    assert body == %{
             "errcode" => "M_MISSING_TOKEN",
             "error" => "Missing access token"
           }
  end

  test "Authorization header without Bearer scheme → 401 M_MISSING_TOKEN" do
    conn =
      conn(:get, "/_matrix/client/v3/sync")
      |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> Nebu.Web.Plugs.OidcPlug.call(@opts)

    assert conn.halted
    assert conn.status == 401

    body = Jason.decode!(conn.resp_body)
    assert body["errcode"] == "M_MISSING_TOKEN"
  end
end
