defmodule Nebu.Web.ReadMarkersTest do
  @moduledoc """
  Acceptance tests (RED phase) for story `room-account-data-and-read-markers`
  (epic matrix-spec-gaps) — AC6 (POST /rooms/{roomId}/read_markers).

  Today read_markers is a no-op `200 {}`: `m.fully_read` is never stored and
  `m.read` / `m.read.private` are never forwarded to the receipts path.

  Contract pinned: `m.fully_read` becomes the user's room account data event
  `m.fully_read` with content `{"event_id": ...}`; `m.read`/`m.read.private`
  behave exactly like `POST /receipt/{type}/{eventId}` (observed through the
  `read_receipts` table and through status parity with /receipt).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "read-markers-test-key-1"
  @router_opts Nebu.Web.Router.init([])

  defp setup_oidc_keys do
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

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    Map.put(priv_map, "kid", @kid)
  end

  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), %{"alg" => "RS256", "kid" => @kid}, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@" <> sub <> ":" <> @server_name, compact}
  end

  defp call(method, path, body, token) do
    c =
      case body do
        nil -> conn(method, path)
        {:raw, raw} -> conn(method, path, raw) |> put_req_header("content-type", "application/json")
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    c = if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    Nebu.Web.Router.call(c, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp enc(s), do: URI.encode_www_form(s)

  defp new_user(priv, prefix) do
    {uid, token} = bearer_for("#{prefix}-#{:erlang.unique_integer([:positive])}", priv)

    _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", uid, "#{:erlang.unique_integer([:positive])}@example.com")

    {uid, token}
  end

  defp create_room(token, name) do
    c = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, token)
    assert c.status == 200
    json(c)["room_id"]
  end

  defp send_message(token, room, body) do
    txn = "rm-" <> Integer.to_string(System.unique_integer([:positive]))

    c =
      call(
        :put,
        "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/#{txn}",
        %{"msgtype" => "m.text", "body" => body},
        token
      )

    assert c.status == 200
    json(c)["event_id"]
  end

  defp read_markers(token, room, body), do: call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/read_markers", body, token)

  defp receipt(token, room, type, event),
    do: call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/receipt/#{type}/#{enc(event)}", %{}, token)

  defp room_ad_path(uid, room, type),
    do: "/_matrix/client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/account_data/#{enc(type)}"

  defp sync(token, since \\ nil) do
    q = if since, do: "?timeout=0&since=#{enc(since)}", else: ""
    c = call(:get, "/_matrix/client/v3/sync" <> q, nil, token)
    assert c.status == 200
    json(c)
  end

  defp room_ad(body, room) do
    (get_in(body, ["rooms", "join", room, "account_data", "events"]) || [])
    |> Map.new(&{&1["type"], &1["content"]})
  end

  defp receipt_event(room, uid, type) do
    {:ok, res} =
      Nebu.Repo.query(
        "SELECT event_id FROM read_receipts WHERE room_id = $1 AND user_id = $2 AND receipt_type = $3",
        [room, uid, type]
      )

    case res.rows do
      [[ev]] -> ev
      [] -> nil
    end
  end

  describe "read_markers auth (no DB)" do
    test "POST read_markers without Bearer → 401 M_MISSING_TOKEN" do
      c = read_markers(nil, "!r:test.local", %{"m.fully_read" => "$x"})
      assert c.status == 401
      assert json(c)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  describe "read_markers (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rm-alice")
      room = create_room(token, "rm-room")
      event = send_message(token, room, "marker target")
      {:ok, priv: priv, uid: uid, token: token, room: room, event: event}
    end

    test "AC6: m.fully_read is stored; GET returns {\"event_id\": ...}", %{uid: uid, token: t, room: room, event: ev} do
      assert read_markers(t, room, %{"m.fully_read" => ev}).status == 200
      get = call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t)
      assert get.status == 200, "got #{get.status}: #{get.resp_body}"
      assert json(get) == %{"event_id" => ev}
    end

    test "AC6: a later m.fully_read replaces the earlier one", %{uid: uid, token: t, room: room, event: ev} do
      ev2 = send_message(t, room, "second")
      assert read_markers(t, room, %{"m.fully_read" => ev}).status == 200
      assert read_markers(t, room, %{"m.fully_read" => ev2}).status == 200
      assert json(call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t)) == %{"event_id" => ev2}
    end

    test "AC6: m.fully_read is delivered via /sync (initial)", %{token: t, room: room, event: ev} do
      assert read_markers(t, room, %{"m.fully_read" => ev}).status == 200
      assert room_ad(sync(t), room)["m.fully_read"] == %{"event_id" => ev}
    end

    test "AC6: m.fully_read update is delivered via incremental /sync, per device", %{token: t, room: room, event: ev} do
      since_a = sync(t)["next_batch"]
      since_b = sync(t)["next_batch"]
      assert read_markers(t, room, %{"m.fully_read" => ev}).status == 200
      assert room_ad(sync(t, since_a), room)["m.fully_read"] == %{"event_id" => ev}
      assert room_ad(sync(t, since_b), room)["m.fully_read"] == %{"event_id" => ev}
    end

    test "AC6: m.fully_read cannot be PUT directly (405 M_BAD_JSON) and is not altered", %{uid: uid, token: t, room: room, event: ev} do
      assert read_markers(t, room, %{"m.fully_read" => ev}).status == 200
      put = call(:put, room_ad_path(uid, room, "m.fully_read"), %{"event_id" => "$forged"}, t)
      assert put.status == 405, "got #{put.status}: #{put.resp_body}"
      assert json(put)["errcode"] == "M_BAD_JSON"
      assert json(call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t)) == %{"event_id" => ev}
    end

    test "AC6: m.fully_read for an event of ANOTHER room → 400 M_INVALID_PARAM (or 404), nothing stored",
         %{uid: uid, token: t, room: room} do
      other = create_room(t, "rm-other")
      foreign = send_message(t, other, "elsewhere")
      c = read_markers(t, room, %{"m.fully_read" => foreign})
      assert c.status in [400, 404], "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] in ["M_INVALID_PARAM", "M_NOT_FOUND"]
      assert call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t).status == 404
    end

    test "AC6: m.fully_read for an unknown event → 400/404, nothing stored", %{uid: uid, token: t, room: room} do
      c = read_markers(t, room, %{"m.fully_read" => "$ghost:test.local"})
      assert c.status in [400, 404], "got #{c.status}: #{c.resp_body}"
      assert call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t).status == 404
    end

    test "AC6: m.read through read_markers creates the same receipt as /receipt", %{uid: uid, token: t, room: room, event: ev} do
      # reference: the receipt row /receipt produces for a second event
      ev2 = send_message(t, room, "reference")
      assert receipt(t, room, "m.read", ev2).status == 200
      assert receipt_event(room, uid, "m.read") == ev2

      # read_markers must move the very same (room, user, m.read) row
      assert read_markers(t, room, %{"m.read" => ev}).status == 200
      assert receipt_event(room, uid, "m.read") == ev
    end

    test "AC6: m.read.private through read_markers creates the m.read.private receipt", %{uid: uid, token: t, room: room, event: ev} do
      assert read_markers(t, room, %{"m.read.private" => ev}).status == 200
      assert receipt_event(room, uid, "m.read.private") == ev
    end

    test "AC6: all three markers in one call", %{uid: uid, token: t, room: room, event: ev} do
      assert read_markers(t, room, %{"m.fully_read" => ev, "m.read" => ev, "m.read.private" => ev}).status == 200
      assert receipt_event(room, uid, "m.read") == ev
      assert receipt_event(room, uid, "m.read.private") == ev
      assert json(call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t)) == %{"event_id" => ev}
    end

    test "AC6: empty body → 200 {} and nothing stored", %{uid: uid, token: t, room: room} do
      c = read_markers(t, room, %{})
      assert c.status == 200
      assert json(c) == %{}
      assert call(:get, room_ad_path(uid, room, "m.fully_read"), nil, t).status == 404
    end

    test "AC6: non-member gets the same status/errcode as /receipt and stores nothing", %{priv: priv, room: room, event: ev} do
      {mallory, mtoken} = new_user(priv, "rm-mallory")

      expected = receipt(mtoken, room, "m.read", ev)
      refute expected.status == 200, "precondition: /receipt must refuse a non-member"

      for marker <- ["m.read", "m.read.private", "m.fully_read"] do
        c = read_markers(mtoken, room, %{marker => ev})
        assert {c.status, json(c)["errcode"]} == {expected.status, json(expected)["errcode"]}, "#{marker}: got #{c.status} #{c.resp_body}"
      end

      assert receipt_event(room, mallory, "m.read") == nil
      assert call(:get, room_ad_path(mallory, room, "m.fully_read"), nil, mtoken).status in [403, 404]
    end

    test "AC6: unknown room gets the same status/errcode as /receipt", %{token: t, event: ev} do
      unknown = "!ghost-#{:erlang.unique_integer([:positive])}:test.local"
      expected = receipt(t, unknown, "m.read", ev)
      refute expected.status == 200
      c = read_markers(t, unknown, %{"m.read" => ev})
      assert {c.status, json(c)["errcode"]} == {expected.status, json(expected)["errcode"]}
    end
  end
end
