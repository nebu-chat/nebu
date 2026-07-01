defmodule Nebu.Web.WellknownClientE2eeTest do
  @moduledoc """
  RED-phase ATDD test for story `wellknown-e2ee-default`
  (epic `client-crypto-setup`).

  Story: advertise Element's E2EE-disabled hint via `/.well-known/matrix/client`
  so Element-family clients do not offer per-room encryption (which the server
  rejects anyway — ADR-011, unchanged).

  `io.element.e2ee` is an Element-proprietary well-known extension, NOT part of
  the Matrix spec. This is a static client hint only; real enforcement remains
  the server rejecting `m.room.encryption`.

  These tests drive `Nebu.Web.Router` directly via `Plug.Test` (no running stack)
  and MUST fail until the dev phase adds the `io.element.e2ee.force_disable` key
  to the JSON body of `get "/.well-known/matrix/client"`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Nebu.Web.Router.init([])

  # AC1 + AC4: well-known carries m.homeserver.base_url AND
  # io.element.e2ee.force_disable == true; status 200; valid JSON; unauthenticated.
  test "GET /.well-known/matrix/client returns m.homeserver and io.element.e2ee.force_disable" do
    conn =
      conn(:get, "/.well-known/matrix/client")
      |> Nebu.Web.Router.call(@opts)

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    # Existing m.homeserver.base_url remains (AC2) and non-empty (AC1).
    base_url = get_in(body, ["m.homeserver", "base_url"])
    assert is_binary(base_url) and base_url != ""

    # New Element-proprietary hint (AC1).
    assert get_in(body, ["io.element.e2ee", "force_disable"]) == true
  end

  # AC4: served unauthenticated — no Bearer token present, still 200.
  test "GET /.well-known/matrix/client requires no Authorization header" do
    conn =
      conn(:get, "/.well-known/matrix/client")
      |> Nebu.Web.Router.call(@opts)

    assert conn.status == 200
    assert get_req_header(conn, "authorization") == []
  end

  # AC2: base_url derivation behind a proxy is unchanged — uses x-forwarded-proto
  # and host headers to produce https://<host>.
  test "base_url derivation uses x-forwarded-proto and host (unchanged behind proxy)" do
    # Plug.Test reserves the "host" header (it maps to conn.host), so set it
    # directly on req_headers the way a real proxy/Bandit request would deliver
    # it — the router reads it via get_req_header(conn, "host").
    base = conn(:get, "/.well-known/matrix/client")

    conn =
      %{base | req_headers: [{"host", "matrix.example.org"} | base.req_headers]}
      |> put_req_header("x-forwarded-proto", "https")
      |> Nebu.Web.Router.call(@opts)

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    base_url = get_in(body, ["m.homeserver", "base_url"])

    assert base_url == "https://matrix.example.org"

    # The new key must coexist with the proxy-derived base_url.
    assert get_in(body, ["io.element.e2ee", "force_disable"]) == true
  end

  # AC3: CORS wildcard origin header and application/json content type are unchanged.
  test "response keeps access-control-allow-origin: * and application/json content type" do
    conn =
      conn(:get, "/.well-known/matrix/client")
      |> Nebu.Web.Router.call(@opts)

    assert "*" in get_resp_header(conn, "access-control-allow-origin")

    content_type =
      conn
      |> get_resp_header("content-type")
      |> List.first()
      |> to_string()

    assert content_type =~ "application/json"
  end
end
