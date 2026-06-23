defmodule Nebu.Web.MatrixClientCompatTest do
  @moduledoc """
  RETROACTIVE regression tests for the Matrix client-compatibility endpoints
  added so a full Matrix client (Element Web) can complete startup and render a
  room. These handlers live in `Nebu.Web.Router.Protected` and were originally
  validated only through Element E2E; these ExUnit tests lock in their contract
  so they can't silently regress.

  Endpoints covered here:

      GET  /_matrix/client/v3/account/whoami        -> {user_id, is_guest:false}
      GET  /_matrix/client/v3/capabilities          -> m.room_versions.default "10"
      GET  /_matrix/client/v3/pushrules/  AND  .../pushrules
                                                    -> empty-but-valid global ruleset
      POST /_matrix/client/v3/keys/query            -> {device_keys, master_keys, …}
      POST /_matrix/client/v3/keys/upload           -> {one_time_key_counts: {}}
      POST /_matrix/client/v3/user/{userId}/filter  -> {filter_id: "0"}
      GET  /_matrix/client/v3/user/{userId}/filter/{id} -> {}
      PUT  /_matrix/client/v3/user/{userId}/account_data/{type} -> {}
      GET  /_matrix/client/v3/rooms/{roomId}/initialSync (integration)

  Two layers, mirroring `Nebu.Web.MatrixRoomRoutesTest`:

  * PURE UNIT (no DB): the auth gate (no Bearer → 401 M_MISSING_TOKEN) and the
    static/echo responses that need only a valid token — these run in the
    DB-less container under `--warnings-as-errors`.
  * `@moduletag :integration`: the `initialSync` contract-shape test, which
    creates a real room and drives the full router against the live OTP tree.

  The serializer regression (`Nebu.Matrix.Http.message_event/1` carrying
  `state_key` for state events) lives in
  `Nebu.Matrix.HttpStateKeyTest`.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "matrix-client-compat-key-1"

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
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :oidc_audience, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_audience)
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
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  # ══════════════════════════════════════════════════════════════════════════
  # Auth gate (no DB) — every compat endpoint sits on the Protected pipeline:
  # a request with no Bearer is rejected by OidcPlug with 401 BEFORE any handler.
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on the client-compat endpoints — no DB" do
    @room URI.encode_www_form("!any:test.local")

    test "GET /account/whoami with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/account/whoami")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET /capabilities with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/capabilities")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET /pushrules/ with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/pushrules/")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET /pushrules with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/pushrules")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST /keys/query with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/keys/query", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST /keys/upload with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/keys/upload", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST /user/{userId}/filter with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/user/@x:test.local/filter", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET /user/{userId}/filter/{id} with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/user/@x:test.local/filter/0")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "PUT /user/{userId}/account_data/{type} with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:put, "/_matrix/client/v3/user/@x:test.local/account_data/m.breadcrumbs", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET .../initialSync with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/rooms/#{@room}/initialSync")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Static / echo contract (valid Bearer, no DB) — these handlers return a
  # constant or echo the authenticated identity and never touch the database.
  # ══════════════════════════════════════════════════════════════════════════

  describe "static contract responses — valid Bearer, no DB" do
    setup do
      priv = setup_oidc_keys()
      {uid, token} = bearer_for("compat-probe", priv)
      {:ok, user_id: uid, token: token}
    end

    test "GET /account/whoami → 200 {user_id, is_guest:false}", %{user_id: uid, token: token} do
      conn = call(:get, "/_matrix/client/v3/account/whoami", nil, auth(token))
      assert conn.status == 200
      assert json(conn) == %{"user_id" => uid, "is_guest" => false}
    end

    test "GET /capabilities → 200 default room version 10 + available map", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/capabilities", nil, auth(token))
      assert conn.status == 200

      versions = json(conn)["capabilities"]["m.room_versions"]
      assert versions["default"] == "10"
      assert is_map(versions["available"])
      # the configured default MUST appear in the available map
      assert versions["available"]["10"] == "stable"
    end

    test "GET /pushrules/ → 200 empty-but-valid global ruleset", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/pushrules/", nil, auth(token))
      assert conn.status == 200
      global = json(conn)["global"]

      for cat <- ~w(content override room sender underride) do
        assert global[cat] == [], "global.#{cat} must be an (empty) list"
      end
    end

    test "GET /pushrules → 200 same empty global ruleset (no trailing slash)", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/pushrules", nil, auth(token))
      assert conn.status == 200
      global = json(conn)["global"]

      for cat <- ~w(content override room sender underride) do
        assert global[cat] == []
      end
    end

    test "POST /keys/query → 200 with all five E2EE maps present", %{token: token} do
      conn =
        call(:post, "/_matrix/client/v3/keys/query", %{"device_keys" => %{}}, auth(token))

      assert conn.status == 200
      body = json(conn)

      for key <- ~w(device_keys master_keys self_signing_keys user_signing_keys failures) do
        assert is_map(body[key]), "#{key} must be a map"
      end
    end

    test "POST /keys/upload → 200 {one_time_key_counts: {}}", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/keys/upload", %{}, auth(token))
      assert conn.status == 200
      assert json(conn) == %{"one_time_key_counts" => %{}}
    end

    test "POST /user/{userId}/filter → 200 {filter_id: \"0\"}", %{user_id: uid, token: token} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/filter",
          %{"room" => %{"timeline" => %{"limit" => 20}}},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{"filter_id" => "0"}
    end

    test "GET /user/{userId}/filter/{id} → 200 {}", %{user_id: uid, token: token} do
      conn =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/filter/0",
          nil,
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "PUT /user/{userId}/account_data/{type} → 200 {}", %{user_id: uid, token: token} do
      conn =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/m.breadcrumbs",
          %{"recent_rooms" => []},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # initialSync — INTEGRATION (needs the live OTP tree + DB)
  # Create a room, then assert the legacy room-load contract Element relies on.
  # ══════════════════════════════════════════════════════════════════════════

  describe "GET .../initialSync — contract shape" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = bearer_for("compat-kai", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Kai", "kai@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Kai", nil)
      end

      {:ok, user_id: uid, token: token}
    end

    defp create_room(token, name) do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, auth(token))
      assert conn.status == 200, "createRoom must succeed to set up the scenario"
      json(conn)["room_id"]
    end

    test "for a room the user is in → 200 with the initialSync shape", %{token: token} do
      room_id = create_room(token, "initial-sync-shape")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/initialSync",
          nil,
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)

      assert body["room_id"] == room_id
      assert body["membership"] == "join"
      assert is_list(body["state"])
      assert is_map(body["messages"])
      assert is_list(body["messages"]["chunk"])
      assert Map.has_key?(body["messages"], "start")
      assert Map.has_key?(body["messages"], "end")
    end
  end
end
