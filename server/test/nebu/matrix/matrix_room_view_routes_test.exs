defmodule Nebu.Web.MatrixRoomViewRoutesTest do
  @moduledoc """
  RED-phase ATDD tests for the `fix-room-view-endpoints` bug story.

  Three more Matrix Client-Server endpoints — called by a real client (Element
  Web) while rendering a room — return 404 because their HTTP routes were never
  ported to `Nebu.Web.Router.Protected` during the Go removal:

      GET  /_matrix/client/v3/rooms/{roomId}/members          -> get_room_state/2 (filter m.room.member)
      GET  /_matrix/client/v3/rooms/{roomId}/event/{eventId}  -> get_event/2
      POST /_matrix/client/v3/rooms/{roomId}/read_markers     -> no backend (200 {} no-op)

  ## Why these tests MUST FAIL right now

  Before the fix none of the three routes exist in `Nebu.Web.Router.Protected`,
  so a request that passes OidcPlug (valid Bearer) falls through to the
  `match _` catch-all and returns `404 M_NOT_FOUND "Unrecognized request"`.

  The pure-unit auth-gate tests prove every route sits on the authenticated
  Protected pipeline (no Bearer → 401 before any handler). The `:integration`
  block drives the full `Nebu.Web.Router` via `Plug.Test` against the real OTP
  supervision tree (rooms via Horde, sessions, :pg) — mirroring
  `Nebu.Web.MatrixRoomRoutesTest` — and asserts the response shapes for
  members / event / read_markers, plus the AC4 relations-403 triage.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "matrix-room-view-routes-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirrors matrix_room_routes_test.exs) ───────────────────

  defp future_exp, do: System.system_time(:second) + 3600

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

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    priv_jwk
  end

  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => future_exp(),
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    "@" <> sub <> ":" <> @server_name |> then(fn uid -> {uid, compact} end)
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — auth gate (no DB) — PURE UNIT
  # Each new route MUST sit on the authenticated Protected pipeline: a request
  # with no Bearer is rejected by OidcPlug with 401 BEFORE any handler runs.
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on the room-view routes (AC5) — no DB" do
    @room URI.encode_www_form("!any:test.local")
    @event URI.encode_www_form("$any:test.local")

    test "GET .../members with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/rooms/#{@room}/members")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET .../event/{eventId} with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/rooms/#{@room}/event/#{@event}")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST .../read_markers with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/read_markers", %{"m.fully_read" => "$x"})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # RED proof — routes are missing — PURE UNIT (valid Bearer, no DB hit needed)
  # With a valid token these requests pass OidcPlug; before the fix they fall
  # through to the `match _` catch-all and return 404 "Unrecognized request".
  # After the fix the routes exist and reach their handlers.
  # ══════════════════════════════════════════════════════════════════════════

  describe "routes are wired (not the 404 catch-all) — valid Bearer, no DB" do
    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("router-probe", priv)
      {:ok, token: token}
    end

    @room URI.encode_www_form("!unknown:test.local")
    @event URI.encode_www_form("$unknown:test.local")

    # The catch-all returns exactly {"errcode":"M_NOT_FOUND","error":"Unrecognized request"}.
    # A wired route, even when it fails (unknown room), never returns that exact body.
    defp refute_catch_all(conn) do
      body = json(conn)

      refute body == %{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"},
             "route is missing — request fell through to the 404 catch-all (status #{conn.status})"
    end

    test "GET .../members is routed", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/rooms/#{@room}/members", nil, auth(token))
      refute_catch_all(conn)
    end

    test "GET .../event/{eventId} is routed", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/rooms/#{@room}/event/#{@event}", nil, auth(token))
      refute_catch_all(conn)
    end

    # room-account-data-and-read-markers (AC6): read_markers is no longer a no-op. For an
    # unknown room/event it is refused like /receipt (no longer 200 {}); the success
    # contract lives in read_markers_test.exs and the member case below.
    test "POST .../read_markers is routed (not the catch-all)", %{token: token} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{@room}/read_markers",
          %{"m.fully_read" => "$x:test.local", "m.read" => "$x:test.local"},
          auth(token)
        )

      refute_catch_all(conn)
      assert conn.status in [400, 403, 404], "got #{conn.status}: #{conn.resp_body}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Contract-shape tests (AC1–AC4) — INTEGRATION
  # Drive the full router with a valid Bearer against the real OTP tree.
  # ══════════════════════════════════════════════════════════════════════════

  describe "room-view routes — contract parity" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = bearer_for("kai", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Kai", "kai@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Kai", nil)
      end

      {:ok, priv_jwk: priv, user_id: uid, token: token}
    end

    # ── flow helpers (drive the router itself) ──────────────────────────────

    defp create_room(token, name) do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, auth(token))
      assert conn.status == 200, "createRoom must succeed to set up the scenario"
      json(conn)["room_id"]
    end

    defp send_message(token, room_id, body) do
      txn = "setup-" <> Integer.to_string(System.unique_integer([:positive]))

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/#{txn}",
          %{"msgtype" => "m.text", "body" => body},
          auth(token)
        )

      assert conn.status == 200, "send must succeed to set up the scenario"
      json(conn)["event_id"]
    end

    # ── AC1 — members ───────────────────────────────────────────────────────

    test "GET .../members → 200 {chunk:[m.room.member events]} for a member", %{token: token, user_id: uid} do
      room_id = create_room(token, "members-shape")

      conn =
        call(:get, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/members", nil, auth(token))

      assert conn.status == 200
      body = json(conn)
      assert is_list(body["chunk"])

      # Every returned event is an m.room.member event …
      assert Enum.all?(body["chunk"], &(&1["type"] == "m.room.member"))
      # … and the creator (kai) appears as a member with a state_key for himself.
      assert Enum.any?(body["chunk"], &(&1["state_key"] == uid)),
             "the room creator must appear as an m.room.member event in /members"
    end

    test "GET .../members on an unknown room → not the catch-all (mapped error)", %{token: token} do
      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form("!nope:test.local")}/members",
          nil,
          auth(token)
        )

      refute_catch_all(conn)
      assert conn.status in [403, 404]
    end

    test "GET .../members for a NON-member → 403 M_FORBIDDEN (no cross-room leak)", %{priv_jwk: priv} do
      # kai creates a private room; mallory (a non-member) must not read its members.
      {kai_uid, kai_token} = bearer_for("kai", priv)
      {mallory_uid, mallory_token} = bearer_for("mallory", priv)

      _ = Nebu.Matrix.Session.TokenValidator.validate(kai_uid, "user", "Kai", "kai@example.com")
      _ = Nebu.Matrix.Session.TokenValidator.validate(mallory_uid, "user", "Mallory", "m@example.com")

      room_id = create_room(kai_token, "members-private")

      conn =
        call(:get, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/members", nil, auth(mallory_token))

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    # ── AC2 — single event ──────────────────────────────────────────────────

    test "GET .../event/{eventId} → 200 <event JSON> for a known event (member)", %{token: token} do
      room_id = create_room(token, "event-shape")
      event_id = send_message(token, room_id, "fetch me by id")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(event_id)}",
          nil,
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert body["event_id"] == event_id
      assert body["type"] == "m.room.message"
      assert body["content"]["body"] == "fetch me by id"
    end

    test "GET .../event/{eventId} for an unknown event → 404 M_NOT_FOUND", %{token: token} do
      room_id = create_room(token, "event-unknown")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form("$ghost:test.local")}",
          nil,
          auth(token)
        )

      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "GET .../event/{eventId} for a NON-member → 403 M_FORBIDDEN", %{priv_jwk: priv} do
      {kai_uid, kai_token} = bearer_for("kai", priv)
      {mallory_uid, mallory_token} = bearer_for("mallory", priv)

      _ = Nebu.Matrix.Session.TokenValidator.validate(kai_uid, "user", "Kai", "kai@example.com")
      _ = Nebu.Matrix.Session.TokenValidator.validate(mallory_uid, "user", "Mallory", "m@example.com")

      room_id = create_room(kai_token, "event-private")
      event_id = send_message(kai_token, room_id, "secret")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(event_id)}",
          nil,
          auth(mallory_token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    # ── AC3 — read_markers (no-op) ──────────────────────────────────────────

    test "POST .../read_markers → 200 {} for a member with a real event", %{token: token} do
      room_id = create_room(token, "read-markers-shape")
      event_id = send_message(token, room_id, "marker target")

      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/read_markers",
          %{"m.fully_read" => event_id, "m.read" => event_id},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end

    # ── AC4 — relations-403 triage ──────────────────────────────────────────
    # A SECOND user (marie) is invited AND joins the room, then calls
    # get_relations. As a joined member she must NOT be rejected with 403. If
    # this passes, the E2E 403 was test-timing (room not yet synced), not a
    # product membership-state bug.

    test "invited+joined second user's get_relations does NOT 403", %{priv_jwk: priv} do
      {kai_uid, kai_token} = bearer_for("kai", priv)
      {marie_uid, marie_token} = bearer_for("marie", priv)

      _ = Nebu.Matrix.Session.TokenValidator.validate(kai_uid, "user", "Kai", "kai@example.com")
      _ = Nebu.Matrix.Session.TokenValidator.validate(marie_uid, "user", "Marie", "marie@example.com")

      room_id = create_room(kai_token, "relations-membership")
      root_id = send_message(kai_token, room_id, "thread root for marie")

      # Invite marie …
      inv =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/invite",
          %{"user_id" => marie_uid},
          auth(kai_token)
        )

      assert inv.status == 200, "invite must succeed to set up the scenario"

      # … and marie joins.
      join =
        call(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room_id)}", %{}, auth(marie_token))

      assert join.status == 200, "join must succeed to set up the scenario"

      # marie (now a joined member) reads relations of the root event.
      conn =
        call(
          :get,
          "/_matrix/client/v1/rooms/#{URI.encode_www_form(room_id)}/relations/#{URI.encode_www_form(root_id)}",
          nil,
          auth(marie_token)
        )

      # The membership check must pass: a joined member is never 403'd.
      refute conn.status == 403,
             "a joined member must not be rejected by get_relations (got #{conn.status}: #{conn.resp_body})"

      assert conn.status == 200
      assert is_list(json(conn)["chunk"])
    end
  end
end
