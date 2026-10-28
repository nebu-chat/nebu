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
    # story create-room-invites-direct (DATA adaptation): POST /invite refuses foreign-domain invitees, the domain is :event_dispatcher's server_name
    Nebu.Test.ServerName.pin!(@server_name)
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
    ("@" <> sub <> ":" <> @server_name) |> then(fn uid -> {uid, compact} end)
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

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  # ══════════════════════════════════════════════════════════════════════════
  # Auth gate (no DB) — every compat endpoint sits on the Protected pipeline:
  # a request with no Bearer is rejected by OidcPlug with 401 BEFORE any handler.
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on the client-compat endpoints — no DB" do
    @room URI.encode_www_form("!any:test.local")

    # ── NEW: Element startup-phase endpoints (AC 1–6) ─────────────────────
    # These six endpoints are not yet implemented (routes missing in Protected).
    # The auth gate tests verify OidcPlug rejects unauthenticated requests with
    # 401 M_MISSING_TOKEN BEFORE any route handler runs. They will pass only
    # once the routes exist in the Protected router and OidcPlug is wired up.

    # AC 1 — thirdparty/protocols
    test "GET /thirdparty/protocols with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/thirdparty/protocols")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    # AC 2 — voip/turnServer
    test "GET /voip/turnServer with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/voip/turnServer")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    # AC 3 — room_keys/version
    test "GET /room_keys/version with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v3/room_keys/version")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    # story room-keys-version-post-stub AC2 — the creation stub is behind the same gate as the GET
    test "POST /room_keys/version with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/room_keys/version", %{"algorithm" => "x"})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST /room_keys/version with a bad token → 401 M_UNKNOWN_TOKEN" do
      conn =
        call(:post, "/_matrix/client/v3/room_keys/version", %{"algorithm" => "x"}, auth("not-a-token"))

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "POST /room_keys/version with a JWT-shaped garbage token → 401 (the path Element's JWT takes)" do
      conn =
        call(:post, "/_matrix/client/v3/room_keys/version", %{"algorithm" => "x"}, auth("aaa.bbb.ccc"))

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    # AC 4 — MSC3814 dehydrated_device
    test "GET /unstable/org.matrix.msc3814.v1/dehydrated_device with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    # AC 5 — MSC4143 rtc/transports
    test "GET /unstable/org.matrix.msc4143/rtc/transports with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    # AC 6 — keys/device_signing/upload
    test "POST /keys/device_signing/upload with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/keys/device_signing/upload", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

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

    # AC4 (auth gate) — GET account_data also sits on the Protected pipeline
    test "GET /user/{userId}/account_data/{type} with NO Bearer → 401 M_MISSING_TOKEN" do
      conn =
        call(
          :get,
          "/_matrix/client/v3/user/%40alice%3Atest.local/account_data/m.secret_storage.default_key"
        )

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

    # Story create-room-input-validation (AC1, D1): Nebu implements ONE rule set and answers createRoom / upgrade
    # M_UNSUPPORTED_ROOM_VERSION for everything else, so /capabilities must not advertise anything else.
    test "GET /capabilities → m.room_versions is exactly {default: 10, available: {10: stable}} and the default is one of the available versions", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/capabilities", nil, auth(token))
      assert conn.status == 200

      versions = json(conn)["capabilities"]["m.room_versions"]
      assert versions == %{"default" => "10", "available" => %{"10" => "stable"}}
      assert Map.has_key?(versions["available"], versions["default"]), "m.room_versions.default MUST be one of the available versions"
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

    # NOTE: the "PUT account_data → 200 {}" no-DB contract test was removed in the
    # account-data-durability story — PUT now persists to PostgreSQL, so its happy
    # path needs the live Repo and lives in the `:integration` block below
    # ("account_data store — PostgreSQL") and in Nebu.Web.AccountDataTest.

    # ── NEW: Element startup-phase endpoints (AC 1–6) ─────────────────────
    # These six tests will FAIL until the routes are added to Protected and
    # the handlers return the spec-mandated bodies. Each test describes the
    # exact contract the implementation must satisfy.

    # AC 1 — thirdparty/protocols: 200 with empty object (no protocols)
    test "GET /thirdparty/protocols with valid Bearer → 200 {}", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/thirdparty/protocols", nil, auth(token))
      assert conn.status == 200
      assert json(conn) == %{}
    end

    # AC 2 — voip/turnServer: 404 M_NOT_FOUND (no TURN server configured)
    test "GET /voip/turnServer with valid Bearer → 404 M_NOT_FOUND", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/voip/turnServer", nil, auth(token))
      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "No TURN server configured"
    end

    # AC 3 — room_keys/version: 404 M_NOT_FOUND (no backup found)
    test "GET /room_keys/version with valid Bearer → 404 M_NOT_FOUND", %{token: token} do
      conn = call(:get, "/_matrix/client/v3/room_keys/version", nil, auth(token))
      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "No backup found"
    end

    # story room-keys-version-post-stub (AC1, AC3, AC4): Element Web creates a key backup right after
    # the cross-signing bootstrap of a first login; without a 2xx it shows "Unable to set up keys".
    # The Go gateway had this stub (dropped by the Elixir migration): accept, store nothing.
    # D1 "nothing stored": proven by the DB-free environment (no Nebu.Repo process: a handler that touched the
    # database would fail here); the handler is one `send_json` line (no DB, no body read).
    @tag :no_repo
    test "POST /room_keys/version with valid Bearer → 200 {version: \"1\"} (stub, nothing stored)", %{token: token} do
      assert Process.whereis(Nebu.Repo) == nil
      body = %{
        "algorithm" => "m.megolm_backup.v1.curve25519-aes-sha2",
        "auth_data" => %{"public_key" => "AAAA", "signatures" => %{}}
      }

      conn = call(:post, "/_matrix/client/v3/room_keys/version", body, auth(token))
      assert conn.status == 200
      assert json(conn) == %{"version" => "1"}
      assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "POST /room_keys/version is idempotent and GET still says no backup afterwards", %{token: token} do
      for _ <- 1..2 do
        conn = call(:post, "/_matrix/client/v3/room_keys/version", %{"algorithm" => "x"}, auth(token))
        assert conn.status == 200
        assert json(conn) == %{"version" => "1"}
      end

      # D5: the stub ignores the body entirely (nothing is stored): an empty and a malformed body are a 200 too
      conn = call(:post, "/_matrix/client/v3/room_keys/version", nil, auth(token))
      assert {conn.status, json(conn)} == {200, %{"version" => "1"}}

      bad =
        conn(:post, "/_matrix/client/v3/room_keys/version", "{not json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Nebu.Web.Router.call(@router_opts)

      assert {bad.status, json(bad)} == {200, %{"version" => "1"}}

      conn = call(:get, "/_matrix/client/v3/room_keys/version", nil, auth(token))
      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
      assert json(conn)["error"] == "No backup found"
    end

    test "only the creation stub exists: room_keys/keys and room_keys/version/{v} stay M_UNRECOGNIZED", %{token: token} do
      for {method, path} <- [
            {:put, "/_matrix/client/v3/room_keys/keys"},
            {:get, "/_matrix/client/v3/room_keys/keys"},
            {:delete, "/_matrix/client/v3/room_keys/version/1"},
            {:get, "/_matrix/client/v3/room_keys/version/1"}
          ] do
        conn = call(method, path, nil, auth(token))
        assert json(conn)["errcode"] == "M_UNRECOGNIZED", "#{method} #{path}: #{conn.status} #{conn.resp_body}"
        assert conn.status in [404, 405], "#{method} #{path}: #{conn.status}"

        # the fall-through is the same without a token (RU10: the catch-all runs before authentication)
        anon = call(method, path)
        assert json(anon)["errcode"] == "M_UNRECOGNIZED", "anonymous #{method} #{path}: #{anon.status}"
      end
    end

    # AC 4 — MSC3814 dehydrated_device: 404 M_NOT_FOUND (no dehydrated device)
    test "GET /unstable/msc3814 dehydrated_device with valid Bearer → 404 M_NOT_FOUND", %{
      token: token
    } do
      conn =
        call(
          :get,
          "/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device",
          nil,
          auth(token)
        )

      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "No dehydrated device found"
    end

    # AC 5 — MSC4143 rtc/transports: 404 M_NOT_FOUND (no RTC transports)
    test "GET /unstable/msc4143 rtc/transports with valid Bearer → 404 M_NOT_FOUND", %{
      token: token
    } do
      conn =
        call(:get, "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports", nil, auth(token))

      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "No RTC transports"
    end

    # AC 6 — keys/device_signing/upload: 200 {} contract.
    #
    # The former static no-DB stub test was removed in the `cross-signing-readback`
    # story: device_signing/upload is now DB-backed (CrossSigningKeyStore.put_keys →
    # Nebu.Repo), so it can no longer be asserted at the DB-less unit layer. The
    # plain 200 {} contract is now covered against a real DB by the integration
    # suite in cross_signing_test.exs (AC2 "first upload (no existing MSK) →
    # plain 200 {} (no UIA)").
  end

  # ══════════════════════════════════════════════════════════════════════════
  # account_data store (PostgreSQL-backed — integration)
  #
  # These tests cover the PUT+GET round-trip + IDOR guards for
  # /user/{userId}/account_data/{type}. As of the account-data-durability story,
  # Nebu.Matrix.AccountDataStore is PostgreSQL-backed (durable, read-on-start)
  # rather than volatile ETS, so the round-trip + 404 cases need the live Repo
  # and run as `:integration` (mirrors cross_signing_test.exs). The
  # reject-before-DB IDOR cases would pass without a DB too, but the block is
  # tagged uniformly for simplicity.
  #
  #   AC1 — PUT stores body and returns 200 {}
  #   AC2 — GET reads it back and returns 200 <stored body>
  #   AC3 — GET returns 404 M_NOT_FOUND when no data was stored
  #   AC4 — user==auth guard: 403 on cross-user read/write (IDOR)
  #   AC5 — second PUT overwrites the first
  #   AC6 — regression: PUT still returns 200 {}
  #
  # Durability across a process boundary, opacity, and /sync delivery live in
  # Nebu.Web.AccountDataTest.
  # ══════════════════════════════════════════════════════════════════════════

  describe "account_data store — PostgreSQL (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid_alice, token_alice} = bearer_for("alice", priv)
      {uid_bob, token_bob} = bearer_for("bob", priv)

      {:ok,
       user_id: uid_alice, token: token_alice, other_user_id: uid_bob, other_token: token_bob}
    end

    # AC3 — GET returns 404 M_NOT_FOUND when no data was stored for the type
    test "GET account_data for unseen type → 404 M_NOT_FOUND", %{user_id: uid, token: token} do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"

      conn =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          nil,
          auth(token)
        )

      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "Account data not found"
    end

    # AC2 — PUT stores body in ETS; GET reads it back unchanged (round-trip)
    test "PUT then GET round-trip → GET returns exactly the stored body", %{
      user_id: uid,
      token: token
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      stored_body = %{"algorithm" => "m.secret_storage.v1.aes-hmac-sha2", "iv" => "abc123"}

      put_conn =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          stored_body,
          auth(token)
        )

      assert put_conn.status == 200
      assert json(put_conn) == %{}

      get_conn =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          nil,
          auth(token)
        )

      assert get_conn.status == 200
      assert json(get_conn) == stored_body
    end

    # AC4 (Oracle) — user isolation / IDOR guard: Alice's data is NOT readable by Bob
    test "GET another user's account_data → 403 M_FORBIDDEN", %{
      user_id: uid_alice,
      token: token_alice,
      other_user_id: _uid_bob,
      other_token: token_bob
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      alice_body = %{"keys" => %{"ed25519:abc" => "ALICEKEY"}}

      # Alice stores her own data
      put_conn =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid_alice)}/account_data/#{type}",
          alice_body,
          auth(token_alice)
        )

      assert put_conn.status == 200

      # Bob attempts to read Alice's account_data → must be rejected
      get_conn =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid_alice)}/account_data/#{type}",
          nil,
          auth(token_bob)
        )

      assert get_conn.status == 403
      assert json(get_conn)["errcode"] == "M_FORBIDDEN"

      # Alice CAN read her own data (same type she just stored)
      own_get =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid_alice)}/account_data/#{type}",
          nil,
          auth(token_alice)
        )

      assert own_get.status == 200
      assert json(own_get) == alice_body
    end

    # AC4 (Oracle) — user isolation / IDOR guard: Alice CANNOT write Bob's account_data (PUT IDOR)
    test "PUT another user's account_data → 403 M_FORBIDDEN", %{
      user_id: _uid_alice,
      token: token_alice,
      other_user_id: uid_bob,
      other_token: _token_bob
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      malicious_body = %{"injected" => "by_alice"}

      # Alice attempts to write to Bob's account_data path → must be rejected
      put_conn =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid_bob)}/account_data/#{type}",
          malicious_body,
          auth(token_alice)
        )

      assert put_conn.status == 403
      assert json(put_conn)["errcode"] == "M_FORBIDDEN"
    end

    # AC5 — data survives multiple PUT-then-GET round trips; second PUT overwrites first
    test "second PUT overwrites first; GET returns latest body", %{user_id: uid, token: token} do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"
      body_v1 = %{"recent_rooms" => ["!roomA:test.local"]}
      body_v2 = %{"recent_rooms" => ["!roomB:test.local", "!roomA:test.local"]}

      # First PUT
      put1 =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          body_v1,
          auth(token)
        )

      assert put1.status == 200

      # Second PUT (overwrite)
      put2 =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          body_v2,
          auth(token)
        )

      assert put2.status == 200

      # GET returns the most recently stored body
      get_conn =
        call(
          :get,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          nil,
          auth(token)
        )

      assert get_conn.status == 200
      assert json(get_conn) == body_v2
    end

    # AC6 — regression: PUT still returns 200 {} (existing behaviour must not break)
    test "PUT account_data → 200 {} (regression: existing PUT contract intact)", %{
      user_id: uid,
      token: token
    } do
      type = "m.test.account.data.#{:erlang.unique_integer([:positive])}"

      conn =
        call(
          :put,
          "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}",
          %{"recent_rooms" => []},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sync timeout — AC4: parse_timeout/1 must cap at 25_000ms, not 30_000ms.
  # These are pure unit tests — no DB, no auth, just the parser function.
  # RED until parse_timeout is promoted from defp to def AND the cap changes
  # from min(30_000) to min(25_000) in protected.ex.
  # Note: server.ex line ~2365 also has min(30_000) — both must be changed to
  # min(25_000). The server.ex clamp is defense-in-depth for internal callers;
  # HTTP path always goes through parse_timeout first, so the protected.ex cap
  # is what governs client requests. Both changes verified in code review diff.
  # ══════════════════════════════════════════════════════════════════════════

  describe "parse_timeout/1 — server-enforced cap at 25_000ms (AC4)" do
    # parse_timeout/1 must be promoted from defp to def for these to compile.
    # This visibility promotion is itself part of the AC4 implementation.

    test "values at or above 25_000 are clamped to 25_000" do
      alias Nebu.Web.Router.Protected

      assert Protected.parse_timeout("25000") == 25_000
      assert Protected.parse_timeout("30000") == 25_000
      assert Protected.parse_timeout("60000") == 25_000
      assert Protected.parse_timeout("999999") == 25_000
    end

    test "values below 25_000 are passed through" do
      alias Nebu.Web.Router.Protected

      assert Protected.parse_timeout("0") == 0
      assert Protected.parse_timeout("100") == 100
      assert Protected.parse_timeout("10000") == 10_000
      assert Protected.parse_timeout("24999") == 24_999
    end

    test "nil returns 0" do
      assert Nebu.Web.Router.Protected.parse_timeout(nil) == 0
    end

    test "non-integer string returns 0" do
      assert Nebu.Web.Router.Protected.parse_timeout("abc") == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # sync timeout — AC3: short-timeout long-poll returns promptly (exercises
  # both the protected.ex parse_timeout cap AND the server.ex clamp, since
  # get_sync_delta is the code path activated by a ?since= request).
  # AC2: initial sync with 5 rooms must complete quickly (Task.async_stream
  # parallelism). The 5-room test with a 3s timing bound can only pass if
  # the fetch is concurrent; sequential fetching at typical GenServer latency
  # would breach the bound.
  # INTEGRATION — requires live OTP tree + DB.
  # ══════════════════════════════════════════════════════════════════════════

  describe "GET /sync — timeout behaviour and initial snapshot (AC2, AC3)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      uid_suffix = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("sync-timeout-user-#{uid_suffix}", priv)

      if Process.whereis(Nebu.Repo) do
        _ =
          Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "SyncUser", "sync@example.com")

        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "SyncUser", nil)
      end

      {:ok, user_id: uid, token: token}
    end

    defp create_sync_room(token, name, extra \\ %{}) do
      conn = call(:post, "/_matrix/client/v3/createRoom", Map.merge(%{"name" => name}, extra), auth(token))
      assert conn.status == 200, "createRoom must succeed"
      json(conn)["room_id"]
    end

    # Bugfix sync-state-events-missing-fields: query the REAL persisted
    # (event_id, origin_server_ts) for a {room, type, state_key} directly from
    # the events table — the source of truth build_state_events/2 must
    # eventually read from. Mirrors existing db_room_name/db_room_type-style
    # direct-SQL test helpers used elsewhere in this suite.
    #
    # Code-review cycle 1 (MINOR): tie-broken by `event_id DESC` in addition
    # to `origin_server_ts DESC` — a kick/rejoin or ban/unban scenario can
    # legitimately land two writes in the SAME millisecond, and without this
    # tie-break this helper's "which one is current" answer could flap
    # between runs, same class of flakiness the production
    # Room.DB.fetch_state_predecessors/1 query already guards against via its own
    # `(origin_server_ts, event_id)` tuple ordering.
    defp db_event_identity(room_id, type, state_key) do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          """
          SELECT event_id, origin_server_ts FROM events
          WHERE room_id = $1 AND event_type = $2 AND state_key = $3
          ORDER BY origin_server_ts DESC, event_id DESC LIMIT 1
          """,
          [room_id, type, state_key]
        )

      case rows do
        [[event_id, ts]] -> {event_id, ts}
        [] -> :no_row
      end
    end

    test "initial sync with 5 rooms returns correct shape within 3s (AC2)", %{
      token: token,
      user_id: user_id
    } do
      # 5 rooms to expose sequential-vs-parallel difference: sequential at ~200ms/room
      # would take ~1s; parallel should complete in ~200ms regardless of room count.
      # The 3s bound is generous enough to avoid flap on slow CI, tight enough to
      # catch a regression back to sequential fetching.
      for i <- 1..5, do: create_sync_room(token, "sync-par-room-#{i}")

      t0 = System.monotonic_time(:millisecond)
      conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      elapsed = System.monotonic_time(:millisecond) - t0

      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["next_batch"]), "next_batch must be a binary token"
      assert is_map(body["rooms"]), "rooms must be a map"
      assert is_map(body["rooms"]["join"]), "rooms.join must be a map"
      joined_ids = Map.keys(body["rooms"]["join"])
      assert length(joined_ids) >= 5, "all 5 created rooms must appear in joined rooms"

      Enum.each(joined_ids, fn room_id ->
        room = body["rooms"]["join"][room_id]
        # Actual shape from Nebu.Matrix.Http.sync_response/2: state and timeline
        # are maps with an "events" list, not plain lists (INFO-1 fix).
        assert is_list(room["state"]["events"]), "room #{room_id} state.events must be a list"

        assert is_list(room["timeline"]["events"]),
               "room #{room_id} timeline.events must be a list"

        # ── Bugfix sync-state-events-missing-fields (AC1/AC2/AC3/AC5) ───────────
        # rooms.join.<room_id>.state.events entries are typed ClientEventWithoutRoomID,
        # exactly like timeline.events — event_id (string) and origin_server_ts
        # (int, epoch ms) are REQUIRED, non-nullable fields regardless of whether
        # the event is surfaced in state or timeline (Oracle-confirmed spec rule).
        # Today Nebu.Matrix.Http.build_joined_rooms/1 (http.ex:139-149) drops both
        # (plus `unsigned`) when serializing Core.SyncRoomStateEvent, which has no
        # such fields (proto/core.proto:381-386). Values asserted here must be the
        # REAL persisted values, not synthesized/fake ones (AC1 rationale).
        state_events = room["state"]["events"]

        assert state_events != [],
               "room #{room_id} must have state events (m.room.create/member/power_levels at minimum)"

        Enum.each(state_events, fn ev ->
          assert is_binary(ev["event_id"]) and ev["event_id"] != "",
                 "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing " <>
                   "a REAL event_id, got: #{inspect(ev["event_id"])}"

          assert is_integer(ev["origin_server_ts"]) and ev["origin_server_ts"] > 0,
                 "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing " <>
                   "a REAL origin_server_ts (int epoch ms), got: #{inspect(ev["origin_server_ts"])}"

          {db_event_id, db_ts} = db_event_identity(room_id, ev["type"], ev["state_key"] || "")

          assert ev["event_id"] == db_event_id,
                 "state event #{ev["type"]} event_id must be the REAL persisted event_id (AC1 — not " <>
                   "synthesized), got #{inspect(ev["event_id"])}, expected #{inspect(db_event_id)}"

          assert ev["origin_server_ts"] == db_ts,
                 "state event #{ev["type"]} origin_server_ts must be the REAL persisted timestamp " <>
                   "(AC1 — not a fake \"now\"), got #{inspect(ev["origin_server_ts"])}, expected " <>
                   "#{inspect(db_ts)}"

          # AC3 (parity, non-blocking but implement regardless): unsigned.age mirrors
          # timeline.events' shape once origin_server_ts is real.
          assert is_map(ev["unsigned"]),
                 "state event #{ev["type"]} must carry unsigned (AC3), got: #{inspect(ev["unsigned"])}"

          assert is_integer(ev["unsigned"]["age"]) and ev["unsigned"]["age"] >= 0,
                 "state event #{ev["type"]} unsigned.age must be a non-negative integer, got: " <>
                   "#{inspect(ev["unsigned"])}"

          # Code-review cycle 1 (MINOR-2): see the matching check in
          # assert_real_state_event_fields/4 above for rationale.
          if ev["type"] in ["m.room.power_levels", "m.room.name"] do
            assert is_binary(ev["sender"]) and ev["sender"] != "",
                   "state event #{ev["type"]} in room #{room_id} must carry the real sender " <>
                     "(MINOR-2, code-review cycle 1), got: #{inspect(ev["sender"])}"
          end
        end)

        # ── AC1 exception (Oracle-confirmed): dedup_member_state_events/2 strips the
        # user's own m.room.member entry from state.events whenever that same join
        # event already falls inside timeline.events (true for a fresh small room's
        # very first sync). Assert the CONDITIONAL placement, not unconditional
        # state.events presence — "present somewhere, state OR timeline" would mask
        # a regression where the event wrongly appears in both (Oracle guidance).
        timeline_events = room["timeline"]["events"]

        own_member_in_timeline =
          Enum.any?(timeline_events, fn ev ->
            ev["type"] == "m.room.member" && ev["state_key"] == user_id
          end)

        if own_member_in_timeline do
          refute Enum.any?(state_events, fn ev ->
                   ev["type"] == "m.room.member" && ev["state_key"] == user_id
                 end),
                 "room #{room_id}: own m.room.member join event is present in timeline.events, so it " <>
                   "must be ABSENT from state.events (dedup_member_state_events/2) — found it in both"

          member_in_timeline =
            Enum.find(timeline_events, fn ev ->
              ev["type"] == "m.room.member" && ev["state_key"] == user_id
            end)

          assert is_binary(member_in_timeline["event_id"]) and
                   member_in_timeline["event_id"] != "",
                 "room #{room_id}: own m.room.member in timeline.events is missing a REAL event_id, " <>
                   "got: #{inspect(member_in_timeline["event_id"])}"

          assert is_integer(member_in_timeline["origin_server_ts"]) and
                   member_in_timeline["origin_server_ts"] > 0,
                 "room #{room_id}: own m.room.member in timeline.events is missing a REAL " <>
                   "origin_server_ts, got: #{inspect(member_in_timeline["origin_server_ts"])}"

          {db_event_id, db_ts} = db_event_identity(room_id, "m.room.member", user_id)

          assert member_in_timeline["event_id"] == db_event_id,
                 "room #{room_id}: own m.room.member in timeline.events event_id must be the REAL " <>
                   "persisted event_id, got #{inspect(member_in_timeline["event_id"])}, expected " <>
                   "#{inspect(db_event_id)}"

          assert member_in_timeline["origin_server_ts"] == db_ts,
                 "room #{room_id}: own m.room.member in timeline.events origin_server_ts must be the " <>
                   "REAL persisted timestamp, got #{inspect(member_in_timeline["origin_server_ts"])}, " <>
                   "expected #{inspect(db_ts)}"
        end

        # create_sync_room/2 creates a NAMED room → m.room.create, m.room.member
        # (creator), m.room.power_levels, m.room.name, and (auto-derived from the
        # name) m.room.canonical_alias must all be present — m.room.member either in
        # state.events (if not deduped) or timeline.events (if deduped, asserted above).
        present_types = state_events |> Enum.map(& &1["type"]) |> MapSet.new()

        expected_state_types =
          if own_member_in_timeline do
            ~w(m.room.create m.room.power_levels m.room.name m.room.canonical_alias)
          else
            ~w(m.room.create m.room.member m.room.power_levels m.room.name m.room.canonical_alias)
          end

        for expected_type <- expected_state_types do
          assert MapSet.member?(present_types, expected_type),
                 "expected #{expected_type} in state.events for room #{room_id}, got types: " <>
                   "#{inspect(MapSet.to_list(present_types))}"
        end
      end)

      assert elapsed < 3000,
             "initial sync with 5 rooms took #{elapsed}ms — should be < 3000ms with parallel fetch"
    end

    test "incremental sync with timeout=500 returns within 1500ms (AC3)", %{token: token} do
      # This test exercises the server.ex get_sync_delta code path (activated by ?since=).
      # With the cap change, ?since + ?timeout=500 → server.ex clamp(500, 25_000) = 500
      # → long-poll returns after 500ms. Margin: 3× (1500ms bound) allows for scheduler
      # latency on slow CI machines. async: false ensures no parallel test pollution.
      initial = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert initial.status == 200
      since = json(initial)["next_batch"]
      assert is_binary(since)

      t0 = System.monotonic_time(:millisecond)

      conn =
        call(
          :get,
          "/_matrix/client/v3/sync?since=#{URI.encode(since)}&timeout=500",
          nil,
          auth(token)
        )

      elapsed = System.monotonic_time(:millisecond) - t0

      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["next_batch"]), "next_batch must be present in empty delta"
      # 3× margin over 500ms timeout: accounts for scheduler overhead + DB latency on CI.
      assert elapsed < 1500, "sync with timeout=500 took #{elapsed}ms — should be < 1500ms"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bugfix sync-state-events-missing-fields — AC1/AC2/AC3/AC4/AC5.
  #
  # Covers INCREMENTAL/delta sync (?since=) for the same bug the describe block
  # above covers for initial sync: rooms.join.<room_id>.state.events entries must
  # carry the REAL event_id/origin_server_ts, not synthesized/fake ones, and this
  # must hold for the one shared code path used by BOTH initial and incremental
  # sync (build_state_events/2 + build_joined_rooms/1). AC4 is exercised directly:
  # sending an unrelated m.room.message timeline event between the initial sync
  # and the delta sync must NOT change the m.room.create state event's identity —
  # state.events reflects state at the START of the timeline window, and the
  # values must be the real persisted ones (not re-synthesized to "now" per sync).
  # ══════════════════════════════════════════════════════════════════════════

  describe "GET /sync — state.events carry real event_id/origin_server_ts (bugfix sync-state-events-missing-fields)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      uid_suffix = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("sync-fields-user-#{uid_suffix}", priv)

      if Process.whereis(Nebu.Repo) do
        _ =
          Nebu.Matrix.Session.TokenValidator.validate(
            uid,
            "user",
            "SyncFieldsUser",
            "sync-fields@example.com"
          )

        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "SyncFieldsUser", nil)
      end

      {:ok, user_id: uid, token: token}
    end

    # All 5 state-event producers wired through build_state_events/2 (AC1/AC2):
    # m.room.create, m.room.member, m.room.power_levels — plus m.room.name and
    # m.room.canonical_alias (auto-derived from the room name on create), all
    # emitted for free by creating a single named room.
    @sync_fields_expected_types ~w(m.room.create m.room.member m.room.power_levels m.room.name m.room.canonical_alias)

    defp assert_real_state_event_fields(state_events, timeline_events, user_id, room_id) do
      assert state_events != [],
             "room #{room_id} must have state events (m.room.create/member/power_levels at minimum)"

      Enum.each(state_events, fn ev ->
        assert is_binary(ev["event_id"]) and ev["event_id"] != "",
               "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing a " <>
                 "REAL event_id, got: #{inspect(ev["event_id"])}"

        assert is_integer(ev["origin_server_ts"]) and ev["origin_server_ts"] > 0,
               "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing a " <>
                 "REAL origin_server_ts (int epoch ms), got: #{inspect(ev["origin_server_ts"])}"

        {db_event_id, db_ts} = db_event_identity(room_id, ev["type"], ev["state_key"] || "")

        assert ev["event_id"] == db_event_id,
               "state event #{ev["type"]} event_id must be the REAL persisted event_id (AC1 — not " <>
                 "synthesized), got #{inspect(ev["event_id"])}, expected #{inspect(db_event_id)}"

        assert ev["origin_server_ts"] == db_ts,
               "state event #{ev["type"]} origin_server_ts must be the REAL persisted timestamp (AC1 — " <>
                 "not a fake \"now\"), got #{inspect(ev["origin_server_ts"])}, expected #{inspect(db_ts)}"

        assert is_map(ev["unsigned"]),
               "state event #{ev["type"]} must carry unsigned (AC3), got: #{inspect(ev["unsigned"])}"

        assert is_integer(ev["unsigned"]["age"]) and ev["unsigned"]["age"] >= 0,
               "state event #{ev["type"]} unsigned.age must be a non-negative integer, got: " <>
                 "#{inspect(ev["unsigned"])}"

        # Code-review cycle 1 (MINOR-2): m.room.power_levels/m.room.name now carry
        # a real event_id pointing at a persisted event with a real sender — sender
        # must no longer be left as "" (would be inconsistent with GET
        # /rooms/{roomId}/event/{eventId} for the same event).
        if ev["type"] in ["m.room.power_levels", "m.room.name"] do
          assert is_binary(ev["sender"]) and ev["sender"] != "",
                 "state event #{ev["type"]} in room #{room_id} must carry the real sender " <>
                   "(MINOR-2, code-review cycle 1), got: #{inspect(ev["sender"])}"
        end
      end)

      # ── AC1 exception (Oracle-confirmed): dedup_member_state_events/2 strips the
      # user's own m.room.member entry from state.events whenever that same join
      # event already falls inside timeline.events (true for a fresh small room's
      # very first sync). Assert the CONDITIONAL placement, not unconditional
      # state.events presence — "present somewhere, state OR timeline" would mask
      # a regression where the event wrongly appears in both (Oracle guidance).
      own_member_in_timeline =
        Enum.any?(timeline_events, fn ev ->
          ev["type"] == "m.room.member" && ev["state_key"] == user_id
        end)

      if own_member_in_timeline do
        refute Enum.any?(state_events, fn ev ->
                 ev["type"] == "m.room.member" && ev["state_key"] == user_id
               end),
               "room #{room_id}: own m.room.member join event is present in timeline.events, so it " <>
                 "must be ABSENT from state.events (dedup_member_state_events/2) — found it in both"

        member_in_timeline =
          Enum.find(timeline_events, fn ev ->
            ev["type"] == "m.room.member" && ev["state_key"] == user_id
          end)

        assert is_binary(member_in_timeline["event_id"]) and member_in_timeline["event_id"] != "",
               "room #{room_id}: own m.room.member in timeline.events is missing a REAL event_id, " <>
                 "got: #{inspect(member_in_timeline["event_id"])}"

        assert is_integer(member_in_timeline["origin_server_ts"]) and
                 member_in_timeline["origin_server_ts"] > 0,
               "room #{room_id}: own m.room.member in timeline.events is missing a REAL " <>
                 "origin_server_ts, got: #{inspect(member_in_timeline["origin_server_ts"])}"

        {db_event_id, db_ts} = db_event_identity(room_id, "m.room.member", user_id)

        assert member_in_timeline["event_id"] == db_event_id,
               "room #{room_id}: own m.room.member in timeline.events event_id must be the REAL " <>
                 "persisted event_id, got #{inspect(member_in_timeline["event_id"])}, expected " <>
                 "#{inspect(db_event_id)}"

        assert member_in_timeline["origin_server_ts"] == db_ts,
               "room #{room_id}: own m.room.member in timeline.events origin_server_ts must be the " <>
                 "REAL persisted timestamp, got #{inspect(member_in_timeline["origin_server_ts"])}, " <>
                 "expected #{inspect(db_ts)}"
      end

      present_types = state_events |> Enum.map(& &1["type"]) |> MapSet.new()

      expected_types =
        if own_member_in_timeline do
          @sync_fields_expected_types -- ["m.room.member"]
        else
          @sync_fields_expected_types
        end

      for expected_type <- expected_types do
        assert MapSet.member?(present_types, expected_type),
               "expected #{expected_type} in state.events for room #{room_id}, got types: " <>
                 "#{inspect(MapSet.to_list(present_types))}"
      end
    end

    test "initial sync (no since): every state.events entry has a real event_id/origin_server_ts",
         %{
           token: token,
           user_id: user_id
         } do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{"name" => "sync-fields-initial-room"},
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      room_sync = get_in(json(sync), ["rooms", "join", room_id])
      state_events = get_in(room_sync, ["state", "events"]) || []
      timeline_events = get_in(room_sync, ["timeline", "events"]) || []

      assert_real_state_event_fields(state_events, timeline_events, user_id, room_id)
    end

    test "incremental sync (?since=): state.events still carry the real, UNCHANGED event_id/origin_server_ts (AC4)",
         %{token: token, user_id: user_id} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{"name" => "sync-fields-incremental-room"},
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      initial = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert initial.status == 200
      since = json(initial)["next_batch"]
      assert is_binary(since)

      # Capture the create event's real identity BEFORE sending an unrelated
      # timeline event, so we can assert it is unchanged by the delta (AC4 —
      # state.events reflects state at the START of the timeline window).
      {create_event_id_before, create_ts_before} = db_event_identity(room_id, "m.room.create", "")

      # An unrelated m.room.message timeline event — does NOT touch any
      # {type, state_key} already in state (create/member/power_levels/name/
      # canonical_alias), so per fetch_delta_rooms/3 (server.ex:2657-2725) none
      # of them get excluded from state.events in the delta.
      send_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/sync-fields-txn-1",
          %{"msgtype" => "m.text", "body" => "hello"},
          auth(token)
        )

      assert send_conn.status == 200

      delta = call(:get, "/_matrix/client/v3/sync?since=#{URI.encode(since)}", nil, auth(token))
      assert delta.status == 200
      delta_body = json(delta)

      assert is_map(delta_body["rooms"]["join"][room_id]),
             "room #{room_id} must appear in the incremental sync delta (it has a new timeline event)"

      state_events = get_in(delta_body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(delta_body, ["rooms", "join", room_id, "timeline", "events"]) || []

      assert_real_state_event_fields(state_events, timeline_events, user_id, room_id)

      create_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.create" end)

      assert create_event["event_id"] == create_event_id_before,
             "m.room.create event_id must stay the real, original event_id across an incremental " <>
               "sync that doesn't touch m.room.create — got #{inspect(create_event["event_id"])}, " <>
               "expected #{inspect(create_event_id_before)}"

      assert create_event["origin_server_ts"] == create_ts_before,
             "m.room.create origin_server_ts must stay the real, original timestamp (not " <>
               "re-synthesized to \"now\" on each sync) — got " <>
               "#{inspect(create_event["origin_server_ts"])}, expected #{inspect(create_ts_before)}"
    end

    # ── Test-review gap closure (pre-dev-story) ──────────────────────────────
    # test-review-findings.md found 2 MAJOR coverage gaps in the tests above before
    # dev-story could start. The two tests below close them. Neither touches/weakens
    # the tests above.

    # Shared by both gap-closure tests below: identical per-event identity assertion
    # to assert_real_state_event_fields/2 above, EXCEPT it does not require every
    # expected type to be present (MAJOR-2 needs to assert a type's ABSENCE) and it
    # guards the DB lookup with a `case` instead of a bare pattern match. m.room.
    # power_levels today has NO persisted events-table row at all — Room.Server's
    # handle_call({:set_power_levels, ...}) (room/server.ex:330-348) only writes
    # rooms.power_levels_json via db_module().set_power_levels/2 and never calls
    # insert_event, unlike handle_call({:join, ...})'s emit_membership_event/3. A bare
    # `{db_event_id, db_ts} = db_event_identity(...)` would raise a MatchError
    # (:no_row) in that case — a crash, not a clean assertion failure. We flunk with
    # a clear message instead. (In practice this branch is not reached today: the
    # is_binary(event_id) assertion below already fails first, for the baseline
    # missing-field reason, for every state event type including power_levels.)
    defp assert_state_event_identity_real_and_db_matching(ev, room_id) do
      assert is_binary(ev["event_id"]) and ev["event_id"] != "",
             "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing a " <>
               "REAL event_id, got: #{inspect(ev["event_id"])}"

      assert is_integer(ev["origin_server_ts"]) and ev["origin_server_ts"] > 0,
             "state event #{ev["type"]}/#{inspect(ev["state_key"])} in room #{room_id} is missing a " <>
               "REAL origin_server_ts (int epoch ms), got: #{inspect(ev["origin_server_ts"])}"

      case db_event_identity(room_id, ev["type"], ev["state_key"] || "") do
        {db_event_id, db_ts} ->
          assert ev["event_id"] == db_event_id,
                 "state event #{ev["type"]} event_id must be the REAL persisted event_id, got " <>
                   "#{inspect(ev["event_id"])}, expected #{inspect(db_event_id)}"

          assert ev["origin_server_ts"] == db_ts,
                 "state event #{ev["type"]} origin_server_ts must be the REAL persisted timestamp, " <>
                   "got #{inspect(ev["origin_server_ts"])}, expected #{inspect(db_ts)}"

        :no_row ->
          flunk(
            "no persisted #{ev["type"]}/#{inspect(ev["state_key"])} event found in the events table " <>
              "for room #{room_id} — cannot verify the state.events identity is REAL (not synthesized)"
          )
      end
    end

    # MAJOR-1 (test-review-findings.md): cluster-safety is a hard constraint for this
    # project. do_init/1 (room/server.ex:211-259) rebuilds members/power_levels from
    # scratch on every Room GenServer restart via db_module().load_members/1, whose
    # current contract (db.ex:66-89) returns only {user_ids, created_at_ms,
    # power_levels_json} — no per-member event identity. If the fix for this bug only
    # threads real event_id/origin_server_ts through the LIVE handle_call mutation
    # path (join / set_power_levels) without ALSO widening load_members/1 + do_init/1
    # to re-derive identity from the DB on restart, it will silently regress these
    # fields back to nil after any Room GenServer restart (crash, Horde rebalance,
    # deploy) — exactly the scenario this test forces via Process.exit(pid, :kill).
    #
    # Uses an INCREMENTAL sync (not initial) to observe the post-restart state —
    # deliberately, not incidentally. dedup_member_state_events/2 (server.ex:2736-
    # 2749), called from BOTH get_initial_sync and fetch_delta_rooms, strips
    # m.room.member from state.events whenever that membership's own join event is
    # still inside the fetched timeline window — which is ALWAYS true for a
    # freshly created room on an initial (no-`since`) sync (its whole history is
    # under 20 events). An initial-sync-based version of this test would therefore
    # fail on "member state event must be present" for that reason alone, before
    # ever reaching the MAJOR-1 identity assertion — confirmed empirically while
    # writing this test. Doing one sync BEFORE the crash (to get `since`) means the
    # creator's join event is OUTSIDE the next delta's timeline window, so
    # dedup_member_state_events is a no-op there and m.room.member legitimately
    # surfaces in state.events — this is a pre-existing, correct, and unrelated
    # mechanism (see the MAJOR-2 test below), not something this fix changes.
    test "Room GenServer crash+restart keeps real member/power_levels event identity (MAJOR-1, cluster-safety)",
         %{token: token} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{"name" => "sync-fields-crash-restart-room"},
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      initial = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert initial.status == 200
      since = json(initial)["next_batch"]
      assert is_binary(since)

      # Kill the live Room GenServer and let it restart under its supervisor — mirrors
      # room_server_clustering_test.exs's AT-CLUSTER-1 idiom exactly: terminate the
      # Horde child entry BEFORE Process.exit(:kill) (prevents Horde's async CRDT
      # reconciliation from queuing an extra restart), then explicitly start_room to
      # recover — same pattern, same modules, same sleep.
      assert [{pid, _}] = Horde.Registry.lookup(Nebu.Matrix.Room.Registry, room_id)
      assert is_pid(pid)
      assert Process.alive?(pid)

      Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      Process.exit(pid, :kill)
      Process.sleep(100)

      assert {:ok, new_pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      assert new_pid != pid, "expected a new pid after crash/restart; original pid was reused"
      assert Process.alive?(new_pid)

      on_exit(fn ->
        if Process.alive?(new_pid),
          do: Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, new_pid)
      end)

      # Send one unrelated event through the RESTARTED GenServer, both so the room
      # has a new event to appear in the incremental delta (same requirement as the
      # existing AC4 test) and as a functional sanity check that the restart
      # actually recovered a working Room GenServer (AT-CLUSTER-2 style).
      send_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/crash-restart-txn-1",
          %{"msgtype" => "m.text", "body" => "hello after restart"},
          auth(token)
        )

      assert send_conn.status == 200

      # Sync AFTER the restart — do_init/1 just rebuilt members/power_levels from the
      # DB from scratch via load_members/1. This is the actual MAJOR-1 assertion.
      delta = call(:get, "/_matrix/client/v3/sync?since=#{URI.encode(since)}", nil, auth(token))
      assert delta.status == 200
      state_events = get_in(json(delta), ["rooms", "join", room_id, "state", "events"]) || []

      post_member_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.member" end)

      assert post_member_event != nil,
             "m.room.member state event must still be present in state.events after GenServer restart"

      assert_state_event_identity_real_and_db_matching(post_member_event, room_id)

      # Code-review cycle 1 (MINOR-3): the synthesized m.room.member content must
      # match EXACTLY what is actually persisted (room/server.ex:557-567 —
      # %{"membership" => "join"}, no "displayname" key at all) — this is the one
      # scenario in this test suite where m.room.member legitimately lands in
      # state.events (see the moduledoc comment above), so it is the right place
      # to lock this in.
      assert post_member_event["content"] == %{"membership" => "join"},
             "m.room.member state event content must match the real persisted event content " <>
               "exactly (MINOR-3, code-review cycle 1), got: #{inspect(post_member_event["content"])}"

      post_pl_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.power_levels" end)

      assert post_pl_event != nil,
             "m.room.power_levels state event must still be present in state.events after GenServer restart"

      assert_state_event_identity_real_and_db_matching(post_pl_event, room_id)

      # Code-review cycle 1 (MINOR-2): sender must be real, not "", once event_id
      # is real.
      assert is_binary(post_pl_event["sender"]) and post_pl_event["sender"] != "",
             "m.room.power_levels state event must carry the real sender (MINOR-2, " <>
               "code-review cycle 1), got: #{inspect(post_pl_event["sender"])}"
    end

    # MAJOR-2 (test-review-findings.md): build_state_events/2 (event_dispatcher/
    # server.ex:2783-2864) is stateless/always-current by construction — it has no
    # notion of "the timeline window". The incremental-sync test above only sends an
    # UNRELATED m.room.message between initial and delta sync, so it cannot
    # distinguish "current" from "start-of-window" (nothing TRACKED actually
    # changes). This test actually changes a tracked state key (m.room.name) between
    # initial sync and the next incremental sync.
    #
    # Investigation of fetch_delta_rooms/3 (event_dispatcher/server.ex:2657-2725,
    # spec §6.3.3 comment at 2675-2690) shows current, correct /sync semantics are
    # NOT "pre-change identity in state.events" — they are EXCLUSION: any
    # {type, state_key} whose change event is already delivered in THIS delta's
    # timeline.events is stripped from state.events entirely via
    # `Enum.reject(..., fn ev -> MapSet.member?(timeline_state_keys, {ev.type,
    # ev.state_key}) end)`. This is correct per the Matrix /sync contract: the client
    # already knows the PRE-change value from its previous sync, and the transition
    # to the new value is fully conveyed by the timeline event — repeating either
    # value in `state` would be a redundant no-op delta. This is pre-existing logic,
    # independent of (and unaffected by) this bug's event_id/origin_server_ts fix.
    # No second bug was found here: build_state_events/2's statelessness is
    # harmless for any change that is itself persisted as a timeline event, because
    # the reject step above removes it from state.events before the client ever sees
    # a stale/live-current value where a pre-window value was expected.
    test "mid-window state change excluded from state.events; untouched keys keep real identity (MAJOR-2)",
         %{token: token} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{"name" => "sync-fields-midwindow-room"},
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      initial = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert initial.status == 200
      since = json(initial)["next_batch"]
      assert is_binary(since)

      # Baseline identity for an UNTOUCHED tracked key, captured BEFORE the
      # mid-window change, so we can assert it is unaffected by a DIFFERENT tracked
      # key changing in the same window.
      {create_event_id_before, create_ts_before} = db_event_identity(room_id, "m.room.create", "")

      # Change a TRACKED state key WITHIN the window: m.room.name, via the generic
      # PUT /rooms/{roomId}/state/{eventType} endpoint (EventDispatcher.Server.
      # set_room_state, server.ex:1939) — persisted through the real events-table +
      # emit_state_event/5 path (unlike m.room.member/power_levels), so it also shows
      # up as a genuine timeline event with real identity.
      rename_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.name",
          %{"name" => "renamed-mid-window"},
          auth(token)
        )

      assert rename_conn.status == 200
      rename_event_id = json(rename_conn)["event_id"]
      assert is_binary(rename_event_id) and rename_event_id != ""

      delta = call(:get, "/_matrix/client/v3/sync?since=#{URI.encode(since)}", nil, auth(token))
      assert delta.status == 200
      delta_body = json(delta)

      assert is_map(delta_body["rooms"]["join"][room_id]),
             "room #{room_id} must appear in the incremental sync delta (it has a new timeline event)"

      timeline_events = get_in(delta_body, ["rooms", "join", room_id, "timeline", "events"]) || []
      state_events = get_in(delta_body, ["rooms", "join", room_id, "state", "events"]) || []

      # ── timeline.events: carries the POST-change m.room.name event, real identity ──
      timeline_name_event = Enum.find(timeline_events, fn ev -> ev["type"] == "m.room.name" end)

      assert timeline_name_event != nil,
             "the m.room.name change must appear in timeline.events for this incremental sync, got " <>
               "types: #{inspect(Enum.map(timeline_events, & &1["type"]))}"

      assert timeline_name_event["event_id"] == rename_event_id,
             "timeline m.room.name event_id must be the REAL event_id returned by the PUT, got " <>
               "#{inspect(timeline_name_event["event_id"])}, expected #{inspect(rename_event_id)}"

      assert is_integer(timeline_name_event["origin_server_ts"]) and
               timeline_name_event["origin_server_ts"] > 0,
             "timeline m.room.name event must carry a REAL origin_server_ts, got: " <>
               "#{inspect(timeline_name_event["origin_server_ts"])}"

      # ── state.events: current /sync semantics exclude a {type, state_key} already
      # delivered via timeline.events in THIS delta (see module note above) — so
      # m.room.name must be ABSENT here. A regressed implementation that instead
      # leaked the NEW/current name into state.events would be exactly the "state
      # reflects END, not START, of the window" bug this test guards against.
      state_name_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.name" end)

      assert state_name_event == nil,
             "m.room.name changed WITHIN this sync's timeline window must be excluded from " <>
               "state.events (already fully conveyed via timeline.events) — got: " <>
               "#{inspect(state_name_event)}"

      # ── every REMAINING state.events entry still carries a REAL, DB-matching
      # identity — proves the m.room.name change elsewhere did not corrupt/refresh
      # unrelated entries that build_state_events/2 re-derives on every call.
      Enum.each(state_events, &assert_state_event_identity_real_and_db_matching(&1, room_id))

      present_types = state_events |> Enum.map(& &1["type"]) |> MapSet.new()

      for expected_type <-
            ~w(m.room.create m.room.member m.room.power_levels m.room.canonical_alias) do
        assert MapSet.member?(present_types, expected_type),
               "expected #{expected_type} to remain in state.events (untouched by the m.room.name " <>
                 "change), got types: #{inspect(MapSet.to_list(present_types))}"
      end

      # ── the actual MAJOR-2 proof: m.room.create's identity is the ORIGINAL,
      # pre-window value — unchanged by an unrelated mid-window state change.
      create_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.create" end)

      assert create_event["event_id"] == create_event_id_before,
             "m.room.create event_id must stay the real, original event_id across an incremental " <>
               "sync where a DIFFERENT tracked key changed — got #{inspect(create_event["event_id"])}, " <>
               "expected #{inspect(create_event_id_before)}"

      assert create_event["origin_server_ts"] == create_ts_before,
             "m.room.create origin_server_ts must stay the real, original timestamp — got " <>
               "#{inspect(create_event["origin_server_ts"])}, expected #{inspect(create_ts_before)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Bugfix unsigned-replaces-state — AC1-AC5, AC7 (Matrix CS API v1.19).
  #
  # Matrix CS API v1.19 added a homeserver MUST: every state event (state_key
  # non-nil) returned to a client must carry `unsigned.replaces_state` set to
  # the event_id of the state event previously current at the same
  # (room_id, type, state_key) slot — absent (never null) when no such prior
  # event exists. MUST be included regardless of history_visibility (unlike
  # `prev_content`, which Nebu does not implement at all). Nebu emits this
  # field nowhere today — RED phase, no implementation exists yet.
  #
  # Mirrors the describe block above (same bug class, prior fix b27ef809):
  # reuses db_event_identity/3, extends it with a tuple-aware sibling
  # (db_replaces_state/5) for ground-truth "what did this event replace"
  # verification, and follows the same create-room-via-HTTP /
  # assert-against-direct-SQL pattern.
  # ══════════════════════════════════════════════════════════════════════════

  describe "unsigned.replaces_state (bugfix unsigned-replaces-state)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      uid_suffix = :erlang.unique_integer([:positive])
      {uid, token} = bearer_for("replaces-state-owner-#{uid_suffix}", priv)

      if Process.whereis(Nebu.Repo) do
        _ =
          Nebu.Matrix.Session.TokenValidator.validate(
            uid,
            "user",
            "ReplacesStateOwner",
            "replaces-state-owner@example.com"
          )

        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "ReplacesStateOwner", nil)
      end

      {:ok, user_id: uid, token: token, priv: priv}
    end

    # ── setup helpers ──────────────────────────────────────────────────────

    defp bootstrap_secondary_user(sub, priv) do
      {uid, token} = bearer_for(sub, priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", sub, sub <> "@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, sub, nil)
      end

      {uid, token}
    end

    defp invite_user(token, room_id, user_id) do
      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/invite",
          %{"user_id" => user_id},
          auth(token)
        )

      assert conn.status == 200, "invite must succeed to set up the scenario"
      conn
    end

    defp join_room(token, room_id) do
      conn =
        call(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room_id)}", %{}, auth(token))

      assert conn.status == 200, "join must succeed to set up the scenario"
      conn
    end

    # kick_user/ban_user/unban_user have NO HTTP route in Nebu today (verified:
    # no matching route in protected.ex) — EventDispatcher.Server's functions are
    # called directly, exactly like server_moderation_metadata_test.exs's own
    # unit-test idiom, just against the REAL Room.Server/Postgres here (room
    # created via the live HTTP router above) instead of a FakeDB.
    defp kick_user_direct(room_id, caller_id, target_id, reason \\ "") do
      req = %Core.KickUserRequest{room_id: room_id, target_id: target_id, reason: reason}

      assert %Core.KickUserResponse{} =
               Nebu.Matrix.EventDispatcher.Server.kick_user(
                 req,
                 Nebu.Matrix.Http.stream(caller_id)
               )

      :ok
    end

    defp ban_user_direct(room_id, caller_id, target_id, reason \\ "") do
      req = %Core.BanUserRequest{room_id: room_id, target_id: target_id, reason: reason}

      assert %Core.BanUserResponse{} =
               Nebu.Matrix.EventDispatcher.Server.ban_user(
                 req,
                 Nebu.Matrix.Http.stream(caller_id)
               )

      :ok
    end

    defp unban_user_direct(room_id, caller_id, target_id) do
      req = %Core.UnbanUserRequest{room_id: room_id, target_id: target_id}

      assert %Core.UnbanUserResponse{} =
               Nebu.Matrix.EventDispatcher.Server.unban_user(
                 req,
                 Nebu.Matrix.Http.stream(caller_id)
               )

      :ok
    end

    # m.room.power_levels HAS an HTTP route since story power-levels-enforcement (PUT /state/
    # m.room.power_levels through the room-process writer, v10 change rules); this helper keeps
    # the direct dispatcher call (the same client-mode writer) — same direct-call pattern.
    defp set_power_levels_direct(room_id, caller_id, new_levels) do
      req = %Core.SetPowerLevelsRequest{
        room_id: room_id,
        power_levels_json: Jason.encode!(new_levels)
      }

      assert %Core.SetPowerLevelsResponse{} =
               Nebu.Matrix.EventDispatcher.Server.set_power_levels(
                 req,
                 Nebu.Matrix.Http.stream(caller_id)
               )

      :ok
    end

    # ── ground-truth oracle + shared assertions ────────────────────────────

    # Dev Notes' suggested production lookup shape, reproduced here as the
    # independent ground-truth oracle: "what event, if any, was the state event
    # previously current at (room_id, type, state_key) immediately before THIS
    # (origin_server_ts, event_id)" — using a (ts, event_id) TUPLE comparison
    # (not origin_server_ts alone) so this oracle is also the correctness
    # reference for the same-millisecond tie-break test below (AC5/AC7).
    #
    # story member-event-prev-content (DELIBERATE re-pin of the oracle, AC5): an `m.room.member` slot is ordered with the D3 key
    # `(origin_server_ts, r, event_id)`, `r = 4 - rank(membership)` (ban 0 < leave 1 < invite 2 < knock 3 < join 4, unknown = leave), exactly the
    # sync partition's order; every other slot keeps `(origin_server_ts, event_id)` (r = 0). The scenarios of this describe block write their
    # member events `tick`-separated, so their expectations are unchanged; the oracle is computed in Elixir, independent of the SQL fragments.
    defp db_replaces_state(room_id, type, state_key, origin_server_ts, event_id) do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT event_id, origin_server_ts, content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3",
          [room_id, type, state_key]
        )

      rank = fn content ->
        membership =
          case content do
            %{"membership" => m} -> m
            text when is_binary(text) -> with {:ok, %{"membership" => m}} <- Jason.decode(text), do: m, else: (_ -> nil)
            _ -> nil
          end

        if type == "m.room.member", do: 4 - Map.get(%{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}, membership, 1), else: 0
      end

      own_content = Enum.find_value(rows, fn [id, _ts, content] -> if id == event_id, do: content end)
      own_key = {origin_server_ts, rank.(own_content), event_id}

      rows
      |> Enum.map(fn [id, ts, content] -> {ts, rank.(content), id} end)
      |> Enum.filter(&(&1 < own_key))
      |> Enum.max(fn -> nil end)
      |> case do
        {_ts, _r, prev_event_id} -> prev_event_id
        nil -> :none
      end
    end

    defp db_replaces_state_for(ev, room_id) do
      db_replaces_state(
        room_id,
        ev["type"],
        ev["state_key"] || "",
        ev["origin_server_ts"],
        ev["event_id"]
      )
    end

    # Single shared assertion covering AC1 (correct predecessor), AC3 (absent,
    # never null, when no predecessor exists) for any state/timeline event.
    defp assert_replaces_state(ev, room_id) do
      assert is_map(ev["unsigned"]),
             "event #{ev["type"]}/#{inspect(ev["state_key"])} must carry an unsigned object, got: " <>
               "#{inspect(ev["unsigned"])}"

      case db_replaces_state_for(ev, room_id) do
        :none ->
          refute Map.has_key?(ev["unsigned"], "replaces_state"),
                 "event #{ev["type"]}/#{inspect(ev["state_key"])} is first-ever at its " <>
                   "(room_id, type, state_key) slot — unsigned.replaces_state must be ABSENT " <>
                   "entirely (AC3 — never null/empty-string), got: " <>
                   "#{inspect(Map.get(ev["unsigned"], "replaces_state"))}"

        prev_event_id ->
          assert ev["unsigned"]["replaces_state"] == prev_event_id,
                 "event #{ev["type"]}/#{inspect(ev["state_key"])} unsigned.replaces_state must be " <>
                   "the REAL event_id of the state event it replaced (AC1), got " <>
                   "#{inspect(ev["unsigned"]["replaces_state"])}, expected #{inspect(prev_event_id)}"
      end
    end

    # Searches BOTH state.events and timeline.events for every event matching
    # (type, state_key), then returns the LATEST one (highest
    # origin_server_ts, tie-broken by event_id) — never just the first match
    # found.
    #
    # Code-review cycle 1 (MAJOR-1 fix-forward): a state change landing inside
    # the timeline window is excluded from state.events by (pre-existing,
    # unrelated) dedup/exclusion logic, and AC2 requires replaces_state there
    # too, so tests should not have to care which list it ended up in — that
    # part is unchanged. What changed: m.room.member's raw timeline window can
    # legitimately contain SEVERAL historical transitions for the SAME
    # state_key within one response (e.g. join -> kick -> rejoin, all inside
    # the last-20-events window) now that the real, undeduped timeline is
    # returned (the previous `dedup_timeline_member_events/1` production
    # helper that collapsed these down to one entry has been reverted — see
    # that bugfix's MAJOR-1 decision). Picking merely the FIRST match (the old
    # `Enum.find` behavior) could land on a stale, superseded transition
    # instead of the current one; picking the latest by (origin_server_ts,
    # event_id) always finds the real current state event, exactly like the
    # production `fetch_state_predecessors` query's own tie-break.
    defp find_event(state_events, timeline_events, type, state_key) do
      (state_events ++ timeline_events)
      |> Enum.filter(fn ev -> ev["type"] == type and (ev["state_key"] || "") == state_key end)
      |> Enum.max_by(
        fn ev -> {ev["origin_server_ts"] || 0, ev["event_id"] || ""} end,
        fn -> nil end
      )
    end

    # AC5 instrumentation: counts [:nebu, :repo, :query] telemetry events (the
    # SAME event Nebu.Repo.QueryTelemetry already attaches to for sanitized
    # debug logging, config/config.exs) fired while `fun` runs.
    defp count_repo_queries(fun) do
      handler_id = "replaces-state-query-count-#{System.unique_integer([:positive])}"
      counter = :counters.new(1, [])

      :ok =
        :telemetry.attach(
          handler_id,
          [:nebu, :repo, :query],
          fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
          nil
        )

      result = fun.()
      :telemetry.detach(handler_id)

      {result, :counters.get(counter, 1)}
    end

    # Seeds `count` distinct synthetic generic-state (type, state_key="") slots,
    # each written TWICE, directly via Nebu.Matrix.Room.DB.insert_event/1 — the
    # SAME module/function production code uses, bypassing only the HTTP
    # generic-state endpoint's small fixed @writable_state_types allowlist (8
    # types), which is far too narrow to seed a large N for the AC5 N+1 test.
    # get_generic_state_events/1 has no type allowlist of its own (it only
    # EXCLUDES member/power_levels/create/name), so synthetic types surface in
    # state.events exactly like a real m.room.topic would.
    defp seed_synthetic_state_slots(room_id, count) do
      for i <- 1..count do
        type = "m.nebu.replaces-state-n1-test.#{i}"
        base_ts = System.system_time(:millisecond)

        :ok =
          Nebu.Matrix.Room.DB.insert_event(%{
            "event_id" => "$n1-test-#{room_id}-#{i}-a-#{System.unique_integer([:positive])}",
            "room_id" => room_id,
            "sender" => "@n1-test:test.local",
            "type" => type,
            "content" => %{"v" => 1},
            "origin_server_ts" => base_ts,
            "state_key" => ""
          })

        :ok =
          Nebu.Matrix.Room.DB.insert_event(%{
            "event_id" => "$n1-test-#{room_id}-#{i}-b-#{System.unique_integer([:positive])}",
            "room_id" => room_id,
            "sender" => "@n1-test:test.local",
            "type" => type,
            "content" => %{"v" => 2},
            "origin_server_ts" => base_ts + 10,
            "state_key" => ""
          })
      end

      :ok
    end

    # ── AC1 / AC3 ───────────────────────────────────────────────────────────

    test "initial sync: absent for untouched slots, correct after a 2nd m.room.name write (AC1, AC3)",
         %{token: token, user_id: user_id} do
      room_id = create_sync_room(token, "replaces-state-first-ever-room")

      {first_name_id, _first_name_ts} = db_event_identity(room_id, "m.room.name", "")
      assert is_binary(first_name_id) and first_name_id != ""

      rename_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.name",
          %{"name" => "replaces-state-room-renamed"},
          auth(token)
        )

      assert rename_conn.status == 200

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      body = json(sync)
      room_sync = get_in(body, ["rooms", "join", room_id])
      state_events = get_in(room_sync, ["state", "events"]) || []
      timeline_events = get_in(room_sync, ["timeline", "events"]) || []

      assert state_events != [],
             "room #{room_id} must have state events (m.room.create/member/power_levels at minimum)"

      # Every OTHER state event in this response (create/member/power_levels/
      # canonical_alias) is still first-ever at its slot — deliberately checked
      # side-by-side with the one write that DOES have a predecessor below, so
      # this test cannot pass vacuously (an implementation that always omits
      # replaces_state, or always adds it unconditionally, both fail here).
      Enum.each(state_events, &assert_replaces_state(&1, room_id))

      own_member_event = find_event(state_events, timeline_events, "m.room.member", user_id)

      assert own_member_event != nil,
             "the owner's own m.room.member event must be in state or timeline"

      assert_replaces_state(own_member_event, room_id)

      name_event = find_event(state_events, timeline_events, "m.room.name", "")
      assert name_event != nil, "the renamed m.room.name event must be in state or timeline"

      assert name_event["unsigned"]["replaces_state"] == first_name_id,
             "second m.room.name write's replaces_state must be the first name event's id, got " <>
               "#{inspect(name_event["unsigned"]["replaces_state"])}, expected #{inspect(first_name_id)}"
    end

    test "generic state (m.room.topic): 2nd write sets replaces_state (AC1)",
         %{token: token} do
      room_id = create_sync_room(token, "replaces-state-topic-room")

      topic1_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v1"},
          auth(token)
        )

      assert topic1_conn.status == 200
      topic1_id = json(topic1_conn)["event_id"]
      assert is_binary(topic1_id) and topic1_id != ""

      topic2_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v2"},
          auth(token)
        )

      assert topic2_conn.status == 200
      topic2_id = json(topic2_conn)["event_id"]
      assert topic2_id != topic1_id

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      body = json(sync)
      state_events = get_in(body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(body, ["rooms", "join", room_id, "timeline", "events"]) || []

      topic_event = find_event(state_events, timeline_events, "m.room.topic", "")
      assert topic_event != nil
      assert topic_event["event_id"] == topic2_id

      assert topic_event["unsigned"]["replaces_state"] == topic1_id,
             "second m.room.topic write's replaces_state must be the first topic event's id, got " <>
               "#{inspect(topic_event["unsigned"]["replaces_state"])}, expected #{inspect(topic1_id)}"
    end

    test "m.room.power_levels: 2nd change sets replaces_state (AC1)",
         %{token: token, user_id: user_id} do
      room_id = create_sync_room(token, "replaces-state-power-levels-room")

      {first_pl_id, _first_pl_ts} = db_event_identity(room_id, "m.room.power_levels", "")

      assert is_binary(first_pl_id) and first_pl_id != "",
             "room creation must persist a real m.room.power_levels event (prior bugfix b27ef809)"

      new_levels = %{
        "ban" => 50,
        "kick" => 50,
        "redact" => 50,
        "invite" => 0,
        "state_default" => 0,
        "events_default" => 0,
        "users_default" => 0,
        "users" => %{user_id => 100},
        "events" => %{}
      }

      :ok = set_power_levels_direct(room_id, user_id, new_levels)

      {second_pl_id, _second_pl_ts} = db_event_identity(room_id, "m.room.power_levels", "")
      assert second_pl_id != first_pl_id

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      body = json(sync)
      state_events = get_in(body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(body, ["rooms", "join", room_id, "timeline", "events"]) || []

      pl_event = find_event(state_events, timeline_events, "m.room.power_levels", "")
      assert pl_event != nil
      assert pl_event["event_id"] == second_pl_id

      assert pl_event["unsigned"]["replaces_state"] == first_pl_id,
             "second m.room.power_levels write's replaces_state must be the creation-time event's " <>
               "id, got #{inspect(pl_event["unsigned"]["replaces_state"])}, expected " <>
               "#{inspect(first_pl_id)}"
    end

    # ── AC1 — incremental/delta sync (test-review gap closure, cycle 2) ────
    #
    # All AC1/AC3 tests above exercise /sync WITHOUT ?since= — they only hit
    # EventDispatcher.Server.get_initial_sync/2. Incremental sync uses a
    # structurally separate path, fetch_delta_rooms/3 (server.ex:2798-2866),
    # with its own call to build_state_events/2. This test proves AC1 holds
    # there too — mirroring the pre-existing sibling pattern at lines ~1079-
    # 1134 ("incremental sync (?since=): state.events still carry the real,
    # UNCHANGED event_id/origin_server_ts (AC4)") in the describe block above.
    #
    # Routing (verified by reading fetch_delta_rooms/3, not assumed): a 2nd
    # write to an EXISTING (type, state_key) slot made AFTER the `since`
    # cursor becomes part of that cursor's raw event batch
    # (messages_db_module().fetch_events_since/3). fetch_delta_rooms/3 builds
    # `timeline_state_keys` from every raw event carrying a "state_key" field
    # (server.ex:2822-2825) and REJECTS any build_state_events/2 entry whose
    # {type, state_key} is in that set from state.events (server.ex:2827-
    # 2831) — this is the §6.3.3 "state.events = room state BEFORE the
    # timeline window" rule, avoiding a no-op delta. So the 2nd write itself
    # is EXCLUDED from state.events and instead surfaces via
    # event_map_to_core_event/1 in timeline.events (included unconditionally
    # in `events`, server.ex:2804-2810). Unlike the sibling AC4 test's
    # "unrelated m.room.message" (which touches no existing slot and so stays
    # fully out of the exclusion set), this test's 2nd m.room.topic write DOES
    # touch an existing slot — so, unlike that sibling test, the event under
    # test here routes through timeline.events, not state.events.
    test "incremental sync (?since=): unsigned.replaces_state correctly populated on a 2nd m.room.topic write within the delta (AC1)",
         %{token: token} do
      room_id = create_sync_room(token, "replaces-state-incremental-topic-room")

      topic1_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v1"},
          auth(token)
        )

      assert topic1_conn.status == 200
      topic1_id = json(topic1_conn)["event_id"]
      assert is_binary(topic1_id) and topic1_id != ""

      initial = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert initial.status == 200
      since = json(initial)["next_batch"]
      assert is_binary(since)

      topic2_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v2"},
          auth(token)
        )

      assert topic2_conn.status == 200
      topic2_id = json(topic2_conn)["event_id"]
      assert topic2_id != topic1_id

      delta = call(:get, "/_matrix/client/v3/sync?since=#{URI.encode(since)}", nil, auth(token))
      assert delta.status == 200
      delta_body = json(delta)

      assert is_map(delta_body["rooms"]["join"][room_id]),
             "room #{room_id} must appear in the incremental sync delta (it has a new state write)"

      state_events = get_in(delta_body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(delta_body, ["rooms", "join", room_id, "timeline", "events"]) || []

      refute Enum.any?(state_events, fn ev -> ev["event_id"] == topic2_id end),
             "the 2nd m.room.topic write must be EXCLUDED from state.events in the delta " <>
               "(fetch_delta_rooms/3's timeline_state_keys exclusion, server.ex:2822-2831) — " <>
               "found it there instead of timeline.events"

      topic2_event = Enum.find(timeline_events, fn ev -> ev["event_id"] == topic2_id end)

      assert topic2_event != nil,
             "the 2nd m.room.topic write must appear in the incremental sync's timeline.events " <>
               "(event_map_to_core_event/1, server.ex:2804-2810)"

      assert_replaces_state(topic2_event, room_id)

      assert topic2_event["unsigned"]["replaces_state"] == topic1_id,
             "incremental sync's 2nd m.room.topic write must carry replaces_state pointing at " <>
               "the first topic event's id (AC1, incremental/delta path via fetch_delta_rooms/3), " <>
               "got #{inspect(topic2_event["unsigned"]["replaces_state"])}, expected " <>
               "#{inspect(topic1_id)}"
    end

    # ── AC1 / AC2 / AC7 — member transitions that bypass Room.Server's in-memory map ──

    test "m.room.member: kick then rejoin sets replaces_state via DB lookup (AC1, AC2, AC7)",
         %{token: owner_token, user_id: owner_id, priv: priv} do
      # Story create-room-presets-power-levels-topic (AC16, DATA adaptation): the KICKED user comes back without a new invite, which is only
      # possible in a public room (a default room is invite-only now and the kick ends the invitation). The test is about replaces_state.
      room_id = create_sync_room(owner_token, "replaces-state-kick-rejoin-room", %{"preset" => "public_chat"})

      {bob_id, bob_token} =
        bootstrap_secondary_user(
          "replaces-state-bob-#{:erlang.unique_integer([:positive])}",
          priv
        )

      invite_user(owner_token, room_id, bob_id)
      join_room(bob_token, room_id)
      {join1_id, _join1_ts} = db_event_identity(room_id, "m.room.member", bob_id)
      assert is_binary(join1_id) and join1_id != ""

      :ok = kick_user_direct(room_id, owner_id, bob_id)
      {kick_id, _kick_ts} = db_event_identity(room_id, "m.room.member", bob_id)
      assert is_binary(kick_id) and kick_id != "" and kick_id != join1_id

      # AC2: the kick event is a normal persisted m.room.member event, fully
      # reachable via GET /event/{eventId} (shares message_event/1 with /messages).
      kick_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(kick_id)}",
          nil,
          auth(owner_token)
        )

      assert kick_conn.status == 200

      assert json(kick_conn)["unsigned"]["replaces_state"] == join1_id,
             "the kick (m.room.member leave) event's replaces_state must be the ORIGINAL join " <>
               "event's id — got #{inspect(json(kick_conn)["unsigned"]["replaces_state"])}, " <>
               "expected #{inspect(join1_id)}"

      join_room(bob_token, room_id)
      {join2_id, _join2_ts} = db_event_identity(room_id, "m.room.member", bob_id)
      assert join2_id != kick_id

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(owner_token))
      assert sync.status == 200
      body = json(sync)
      state_events = get_in(body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(body, ["rooms", "join", room_id, "timeline", "events"]) || []

      bob_member_event = find_event(state_events, timeline_events, "m.room.member", bob_id)
      assert bob_member_event != nil

      assert bob_member_event["event_id"] == join2_id,
             "sanity: the member event found must be the REJOIN, not a stale snapshot"

      assert bob_member_event["unsigned"]["replaces_state"] == kick_id,
             "rejoin's replaces_state must be the KICK event's id — got " <>
               "#{inspect(bob_member_event["unsigned"]["replaces_state"])}, expected " <>
               "#{inspect(kick_id)}"
    end

    test "m.room.member: ban then unban sets replaces_state via DB lookup (AC1, AC7)",
         %{token: owner_token, user_id: owner_id, priv: priv} do
      room_id = create_sync_room(owner_token, "replaces-state-ban-unban-room")

      {carol_id, carol_token} =
        bootstrap_secondary_user(
          "replaces-state-carol-#{:erlang.unique_integer([:positive])}",
          priv
        )

      invite_user(owner_token, room_id, carol_id)
      join_room(carol_token, room_id)
      {join1_id, _join1_ts} = db_event_identity(room_id, "m.room.member", carol_id)
      assert is_binary(join1_id) and join1_id != ""

      :ok = ban_user_direct(room_id, owner_id, carol_id)
      {ban_id, _ban_ts} = db_event_identity(room_id, "m.room.member", carol_id)
      assert ban_id != join1_id

      ban_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(ban_id)}",
          nil,
          auth(owner_token)
        )

      assert ban_conn.status == 200

      assert json(ban_conn)["unsigned"]["replaces_state"] == join1_id,
             "the ban event's replaces_state must be the original join event's id — got " <>
               "#{inspect(json(ban_conn)["unsigned"]["replaces_state"])}, expected #{inspect(join1_id)}"

      :ok = unban_user_direct(room_id, owner_id, carol_id)
      {unban_id, _unban_ts} = db_event_identity(room_id, "m.room.member", carol_id)
      assert unban_id != ban_id

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(owner_token))
      assert sync.status == 200
      body = json(sync)
      state_events = get_in(body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(body, ["rooms", "join", room_id, "timeline", "events"]) || []

      carol_member_event = find_event(state_events, timeline_events, "m.room.member", carol_id)
      assert carol_member_event != nil
      assert carol_member_event["event_id"] == unban_id

      assert carol_member_event["unsigned"]["replaces_state"] == ban_id,
             "unban (leave) event's replaces_state must be the BAN event's id — got " <>
               "#{inspect(carol_member_event["unsigned"]["replaces_state"])}, expected " <>
               "#{inspect(ban_id)}"
    end

    # ── AC2 — /messages + GET /event/{eventId} ─────────────────────────────

    test "GET /messages and GET /event carry replaces_state for state entries only (AC2)",
         %{token: token, user_id: user_id} do
      room_id = create_sync_room(token, "replaces-state-messages-room")

      topic1_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v1"},
          auth(token)
        )

      assert topic1_conn.status == 200
      topic1_id = json(topic1_conn)["event_id"]

      topic2_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v2"},
          auth(token)
        )

      assert topic2_conn.status == 200
      topic2_id = json(topic2_conn)["event_id"]

      msg_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/replaces-state-txn-1",
          %{"msgtype" => "m.text", "body" => "hello"},
          auth(token)
        )

      assert msg_conn.status == 200

      messages_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/messages?dir=b&limit=20",
          nil,
          auth(token)
        )

      assert messages_conn.status == 200
      chunk = json(messages_conn)["chunk"]

      topic2_chunk_entry = Enum.find(chunk, fn ev -> ev["event_id"] == topic2_id end)

      assert topic2_chunk_entry != nil,
             "the second topic event must appear in the /messages chunk"

      # story member-event-prev-content (DELIBERATE re-pin; old -> new): the unsigned of a state event with a predecessor is exactly the three keys
      # replaces_state + prev_content + prev_sender (still no age — follow-up fl (b)); it was `%{"replaces_state" => topic1_id}` before.
      assert topic2_chunk_entry["unsigned"] == %{"replaces_state" => topic1_id, "prev_content" => %{"topic" => "v1"}, "prev_sender" => user_id},
             "a /messages chunk entry for a state event must carry exactly unsigned.replaces_state + prev_content + prev_sender " <>
               "(no age — separate, pre-existing, out-of-scope gap), got: " <>
               "#{inspect(topic2_chunk_entry["unsigned"])}"

      message_chunk_entry = Enum.find(chunk, fn ev -> ev["type"] == "m.room.message" end)
      assert message_chunk_entry != nil

      refute Map.has_key?(message_chunk_entry, "unsigned"),
             "a plain (non-state) /messages chunk entry must still carry NO unsigned object at all " <>
               "(pre-existing gap, explicitly out of scope for this story) — got: " <>
               "#{inspect(message_chunk_entry["unsigned"])}"

      event_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(topic2_id)}",
          nil,
          auth(token)
        )

      assert event_conn.status == 200

      # story member-event-prev-content (DELIBERATE re-pin; old -> new): the same three keys through the shared mapper
      assert json(event_conn)["unsigned"] == %{"replaces_state" => topic1_id, "prev_content" => %{"topic" => "v1"}, "prev_sender" => user_id},
             "GET /event/{eventId} must carry the same unsigned.replaces_state + prev_content + prev_sender via the shared mapper"
    end

    # Code-review cycle 2 regression guard: the test gap that let the cycle-1
    # MAJOR through. Every prior test in this describe block sends at most ONE
    # plain m.room.message per room, so a non-state event never had a
    # predecessor at its (type, state_key) slot to produce a bogus
    # replaces_state from — the exact condition the pre-existing
    # `do_send_event/7` `state_key || ""` writer bug needed to manifest
    # (events.state_key is '' instead of NULL for every non-state event, so
    # from the 2nd one onward the batched lookup treats (event_type, "") as a
    # real state slot and wrongly resolves a "predecessor"). This test sends
    # >= 2 m.room.message events and asserts the 2ND one carries neither
    # state_key nor a replaces_state anywhere, across /sync timeline.events,
    # /messages chunk, and GET /event/{eventId}.
    test "a 2nd plain m.room.message carries no state_key and no replaces_state anywhere (regression guard)",
         %{token: token} do
      room_id = create_sync_room(token, "replaces-state-plain-messages-room")

      msg1_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/plain-msg-txn-1",
          %{"msgtype" => "m.text", "body" => "first"},
          auth(token)
        )

      assert msg1_conn.status == 200

      msg2_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/plain-msg-txn-2",
          %{"msgtype" => "m.text", "body" => "second"},
          auth(token)
        )

      assert msg2_conn.status == 200
      msg2_id = json(msg2_conn)["event_id"]

      # ── /sync — timeline.events ───────────────────────────────────────────
      # Unlike /messages / /event, /sync timeline entries always carry an
      # "unsigned" object (it always has "age") — so the correct assertion
      # here is "no replaces_state INSIDE unsigned", not "no unsigned key".
      sync_conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync_conn.status == 200

      timeline_events =
        get_in(json(sync_conn), ["rooms", "join", room_id, "timeline", "events"]) || []

      msg2_timeline_entry = Enum.find(timeline_events, fn ev -> ev["event_id"] == msg2_id end)

      assert msg2_timeline_entry != nil,
             "the 2nd plain message must appear in /sync timeline.events"

      refute Map.has_key?(msg2_timeline_entry, "state_key"),
             "a plain (non-state) /sync timeline.events entry must carry NO state_key, got: " <>
               inspect(msg2_timeline_entry["state_key"])

      refute Map.has_key?(msg2_timeline_entry["unsigned"] || %{}, "replaces_state"),
             "a plain (non-state) /sync timeline.events entry must carry NO " <>
               "unsigned.replaces_state, got: #{inspect(msg2_timeline_entry["unsigned"])}"

      # ── GET /messages chunk ────────────────────────────────────────────────
      messages_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/messages?dir=b&limit=20",
          nil,
          auth(token)
        )

      assert messages_conn.status == 200
      chunk = json(messages_conn)["chunk"]
      msg2_chunk_entry = Enum.find(chunk, fn ev -> ev["event_id"] == msg2_id end)

      assert msg2_chunk_entry != nil,
             "the 2nd plain message must appear in the /messages chunk"

      refute Map.has_key?(msg2_chunk_entry, "state_key"),
             "a plain (non-state) /messages chunk entry must carry NO state_key, got: " <>
               inspect(msg2_chunk_entry["state_key"])

      refute Map.has_key?(msg2_chunk_entry, "unsigned"),
             "a plain (non-state) /messages chunk entry must carry NO unsigned object at all " <>
               "(no replaces_state, no age — pre-existing, out-of-scope gap for this endpoint), " <>
               "got: #{inspect(msg2_chunk_entry["unsigned"])}"

      # ── GET /event/{eventId} (shares message_event/1 with /messages) ──────
      event_conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/event/#{URI.encode_www_form(msg2_id)}",
          nil,
          auth(token)
        )

      assert event_conn.status == 200
      event_body = json(event_conn)

      refute Map.has_key?(event_body, "state_key"),
             "GET /event/{eventId} for a plain message must carry NO state_key, got: " <>
               inspect(event_body["state_key"])

      refute Map.has_key?(event_body, "unsigned"),
             "GET /event/{eventId} for a plain message must carry NO unsigned object at all, " <>
               "got: #{inspect(event_body["unsigned"])}"
    end

    # ── AC4 — visibility non-gating ────────────────────────────────────────

    test "replaces_state present despite most-restrictive history_visibility (AC4)",
         %{token: token} do
      room_id = create_sync_room(token, "replaces-state-visibility-room")

      # Story create-room-presets-power-levels-topic (AC16, DATA adaptation): createRoom writes a preset history_visibility (`shared`) into the
      # slot this test overwrites with `invited`; the latest value is read by origin_server_ts (ms), so a PUT in the SAME millisecond would tie.
      start_ms = System.system_time(:millisecond)
      Stream.repeatedly(fn -> Process.sleep(1) end) |> Enum.take_while(fn _ -> System.system_time(:millisecond) <= start_ms end)

      hv_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.history_visibility",
          %{"history_visibility" => "invited"},
          auth(token)
        )

      assert hv_conn.status == 200, "setting the most restrictive history_visibility must succeed"

      topic1_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v1"},
          auth(token)
        )

      assert topic1_conn.status == 200
      topic1_id = json(topic1_conn)["event_id"]

      topic2_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state/m.room.topic",
          %{"topic" => "v2"},
          auth(token)
        )

      assert topic2_conn.status == 200

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      body = json(sync)
      state_events = get_in(body, ["rooms", "join", room_id, "state", "events"]) || []
      timeline_events = get_in(body, ["rooms", "join", room_id, "timeline", "events"]) || []

      hv_event = find_event(state_events, timeline_events, "m.room.history_visibility", "")
      assert hv_event != nil

      assert get_in(hv_event, ["content", "history_visibility"]) == "invited",
             "sanity: the room's current history_visibility must actually be the restrictive " <>
               "value under test"

      topic_event = find_event(state_events, timeline_events, "m.room.topic", "")
      assert topic_event != nil

      assert topic_event["unsigned"]["replaces_state"] == topic1_id,
             "unsigned.replaces_state must be present and correct even though the room is " <>
               "configured with the most restrictive history_visibility Nebu supports (AC4 — " <>
               "unlike prev_content, which IS visibility-gated and which Nebu does not implement " <>
               "at all) — got #{inspect(topic_event["unsigned"]["replaces_state"])}, expected " <>
               "#{inspect(topic1_id)}"
    end

    # ── AC5 — N+1 avoidance (MANDATORY) + same-millisecond tie-break ───────

    test "N+1 avoidance: query count does not scale with state-event count (AC5, MANDATORY)",
         %{priv: priv} do
      # Design rationale: AC5 explicitly allows a per-ROOM (or per-RESPONSE)
      # batched query (Dev Notes: "one query per response ... or per-room ...
      # either is acceptable as long as it is not per-event"). Varying ROOM
      # COUNT alone cannot distinguish an allowed per-room implementation from
      # a forbidden per-event one, since more rooms legitimately means more
      # per-room queries either way. This test instead holds room count FIXED
      # AT ONE (per measurement — two separate single-room users, so each
      # sync response reflects exactly one room) and varies ONLY the number of
      # state events needing a previous-lookup within that one room — the one
      # dimension AC5 forbids scaling with.
      {_small_uid, small_token} =
        bootstrap_secondary_user(
          "replaces-state-n1-small-#{:erlang.unique_integer([:positive])}",
          priv
        )

      {_large_uid, large_token} =
        bootstrap_secondary_user(
          "replaces-state-n1-large-#{:erlang.unique_integer([:positive])}",
          priv
        )

      small_room_id = create_sync_room(small_token, "replaces-state-n1-small-room")
      large_room_id = create_sync_room(large_token, "replaces-state-n1-large-room")

      seed_synthetic_state_slots(small_room_id, 3)
      seed_synthetic_state_slots(large_room_id, 15)

      {small_sync, small_query_count} =
        count_repo_queries(fn ->
          call(:get, "/_matrix/client/v3/sync", nil, auth(small_token))
        end)

      {large_sync, large_query_count} =
        count_repo_queries(fn ->
          call(:get, "/_matrix/client/v3/sync", nil, auth(large_token))
        end)

      assert small_sync.status == 200
      assert large_sync.status == 200

      # Correctness FIRST — this is this test's actual RED-phase failure point
      # today. Pre-implementation there is no lookup at all, so the query-count
      # assertion below would trivially (and meaninglessly) hold; these
      # per-field checks are what must drive this test red until the fix lands.
      large_state_events =
        get_in(json(large_sync), ["rooms", "join", large_room_id, "state", "events"]) || []

      synthetic_events =
        Enum.filter(large_state_events, fn ev ->
          String.starts_with?(ev["type"] || "", "m.nebu.replaces-state-n1-test.")
        end)

      assert length(synthetic_events) == 15,
             "expected all 15 synthetic second-write state events in the large room's state.events, " <>
               "got #{length(synthetic_events)}"

      Enum.each(synthetic_events, &assert_replaces_state(&1, large_room_id))

      # AC5: query count must NOT scale with the 5x growth in state-event count
      # (3 -> 15) while room count stays fixed at 1 for both measurements. A
      # per-event implementation would add ~12 extra queries (one per extra
      # event needing a lookup); a per-room or per-response batched
      # implementation adds zero or a small constant. Budget of 3 allows a
      # small constant while rejecting anything resembling linear growth.
      assert large_query_count <= small_query_count + 3,
             "previous-state-event lookup query count grew from #{small_query_count} (3 state " <>
               "events) to #{large_query_count} (15 state events) with room count held at 1 — " <>
               "looks like a per-event N+1 query, not the mandated single batched lookup (AC5)"
    end

    # ── AC5 — N+1 avoidance via incremental/delta sync (test-review gap closure, cycle 2) ──
    #
    # The N+1 guard above only measures get_initial_sync/2's query behavior.
    # build_state_events/2 (server.ex:2929-3082) — the function the Dev Notes'
    # batched replaces_state lookup is expected to live in — is SHARED between
    # get_initial_sync/2 AND fetch_delta_rooms/3 (server.ex:2828, same call
    # shape as get_initial_sync/2's own call at server.ex:2465). A dev who
    # wires the batched lookup into one call site but not the other would pass
    # the guard above while leaving the incremental path's lookup un-batched —
    # this test closes that gap by taking the SAME query-count-flatness
    # measurement across the SAME 3→15 state-event growth, but via an
    # incremental ?since= sync instead of an initial one.
    #
    # The synthetic slots are seeded BEFORE the `since` cursor is captured (not
    # after, unlike the AC1 incremental test above) so they are NOT part of
    # the delta's own raw event batch — fetch_delta_rooms/3's
    # timeline_state_keys exclusion (server.ex:2822-2831) therefore does not
    # remove them from state.events, keeping this test's correctness
    # assertions a direct parallel of the initial-sync test above (same
    # assert_replaces_state/2 helper, same state.events list). A separate,
    # unrelated m.room.message AFTER the cursor is required in each room —
    # otherwise fetch_events_since/3 would return `{:ok, []}`, the room would
    # be dropped entirely from the delta ({:ok, []} -> [], server.ex:2801-
    # 2802), build_state_events/2 would never run, and the query-count
    # assertion would hold vacuously (0 <= 0 + 3) regardless of whether the
    # fix is wired in at all.
    test "N+1 avoidance (incremental sync): query count does not scale with state-event count via fetch_delta_rooms/3 (AC5, MANDATORY)",
         %{priv: priv} do
      {_small_uid, small_token} =
        bootstrap_secondary_user(
          "replaces-state-n1-delta-small-#{:erlang.unique_integer([:positive])}",
          priv
        )

      {_large_uid, large_token} =
        bootstrap_secondary_user(
          "replaces-state-n1-delta-large-#{:erlang.unique_integer([:positive])}",
          priv
        )

      small_room_id = create_sync_room(small_token, "replaces-state-n1-delta-small-room")
      large_room_id = create_sync_room(large_token, "replaces-state-n1-delta-large-room")

      seed_synthetic_state_slots(small_room_id, 3)
      seed_synthetic_state_slots(large_room_id, 15)

      small_initial = call(:get, "/_matrix/client/v3/sync", nil, auth(small_token))
      assert small_initial.status == 200
      small_since = json(small_initial)["next_batch"]
      assert is_binary(small_since)

      large_initial = call(:get, "/_matrix/client/v3/sync", nil, auth(large_token))
      assert large_initial.status == 200
      large_since = json(large_initial)["next_batch"]
      assert is_binary(large_since)

      small_send =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(small_room_id)}/send/m.room.message/n1-delta-small-txn-1",
          %{"msgtype" => "m.text", "body" => "hello"},
          auth(small_token)
        )

      assert small_send.status == 200

      large_send =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(large_room_id)}/send/m.room.message/n1-delta-large-txn-1",
          %{"msgtype" => "m.text", "body" => "hello"},
          auth(large_token)
        )

      assert large_send.status == 200

      {small_delta, small_query_count} =
        count_repo_queries(fn ->
          call(
            :get,
            "/_matrix/client/v3/sync?since=#{URI.encode(small_since)}",
            nil,
            auth(small_token)
          )
        end)

      {large_delta, large_query_count} =
        count_repo_queries(fn ->
          call(
            :get,
            "/_matrix/client/v3/sync?since=#{URI.encode(large_since)}",
            nil,
            auth(large_token)
          )
        end)

      assert small_delta.status == 200
      assert large_delta.status == 200

      # Correctness FIRST — same rationale as the initial-sync sibling test
      # above: pre-fix there is no lookup at all, so the query-count
      # assertion below would trivially (and meaninglessly) hold. These
      # per-field checks are what must drive this test red until the fix
      # lands in BOTH call sites of build_state_events/2.
      large_state_events =
        get_in(json(large_delta), ["rooms", "join", large_room_id, "state", "events"]) || []

      synthetic_events =
        Enum.filter(large_state_events, fn ev ->
          String.starts_with?(ev["type"] || "", "m.nebu.replaces-state-n1-test.")
        end)

      assert length(synthetic_events) == 15,
             "expected all 15 synthetic second-write state events in the large room's " <>
               "incremental sync state.events (fetch_delta_rooms/3), got " <>
               "#{length(synthetic_events)}"

      Enum.each(synthetic_events, &assert_replaces_state(&1, large_room_id))

      assert large_query_count <= small_query_count + 3,
             "previous-state-event lookup query count (incremental sync, fetch_delta_rooms/3) " <>
               "grew from #{small_query_count} (3 state events) to #{large_query_count} (15 " <>
               "state events) with room count held at 1 — looks like a per-event N+1 query, not " <>
               "the mandated single batched lookup (AC5)"
    end

    test "same-millisecond tie-break uses (origin_server_ts, event_id) (AC5, AC7)",
         %{token: token} do
      room_id = create_sync_room(token, "replaces-state-tiebreak-room")

      tied_ts = System.system_time(:millisecond)
      type = "m.nebu.replaces-state-tiebreak-test"

      # write1/write2 TIE on origin_server_ts (identical) — write2's event_id is
      # deliberately the lexically LARGER string. write3 is unambiguously
      # CURRENT (strictly later timestamp — no tie involved in selecting it as
      # current). Per the Dev Notes' suggested tie-break
      # (`ORDER BY origin_server_ts DESC, event_id DESC`), the correct
      # predecessor of write3 is whichever of write1/write2 has the LARGER
      # (origin_server_ts, event_id) tuple — here, write2 (same ts, larger id)
      # — NOT write1, and NOT :none (a naive "origin_server_ts strictly less
      # than" comparison risks returning either non-deterministically for a
      # tied pair, since Postgres does not guarantee ORDER BY stability across
      # ties without a secondary sort key).
      write1_id = "$n1-tiebreak-#{room_id}-a"
      write2_id = "$n1-tiebreak-#{room_id}-z"

      :ok =
        Nebu.Matrix.Room.DB.insert_event(%{
          "event_id" => write1_id,
          "room_id" => room_id,
          "sender" => "@tiebreak:test.local",
          "type" => type,
          "content" => %{"v" => 1},
          "origin_server_ts" => tied_ts,
          "state_key" => ""
        })

      :ok =
        Nebu.Matrix.Room.DB.insert_event(%{
          "event_id" => write2_id,
          "room_id" => room_id,
          "sender" => "@tiebreak:test.local",
          "type" => type,
          "content" => %{"v" => 2},
          "origin_server_ts" => tied_ts,
          "state_key" => ""
        })

      :ok =
        Nebu.Matrix.Room.DB.insert_event(%{
          "event_id" => "$n1-tiebreak-#{room_id}-current",
          "room_id" => room_id,
          "sender" => "@tiebreak:test.local",
          "type" => type,
          "content" => %{"v" => 3},
          "origin_server_ts" => tied_ts + 10_000,
          "state_key" => ""
        })

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      state_events = get_in(json(sync), ["rooms", "join", room_id, "state", "events"]) || []

      current_event = Enum.find(state_events, fn ev -> ev["type"] == type end)

      assert current_event != nil,
             "the synthetic tie-break state type must appear in state.events"

      assert current_event["origin_server_ts"] == tied_ts + 10_000

      assert current_event["unsigned"]["replaces_state"] == write2_id,
             "same-millisecond tie must be broken by event_id (the tied pair's LARGER id, write2), " <>
               "not origin_server_ts alone — got " <>
               "#{inspect(current_event["unsigned"]["replaces_state"])}, expected #{inspect(write2_id)}"
    end

    # ── Code-review cycle 3 (MAJOR-2 regression guard): room-rename
    # authorization bypass closed ───────────────────────────────────────────
    #
    # get_room_name/1's WHERE clause was briefly `COALESCE(state_key, '') = ''`
    # (code-review cycle 2), which re-admitted a row written via the
    # NON-state `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.name/
    # {txnId}` path. Every event sent through that endpoint has
    # is_state_event: false, so `do_send_event/7` always persists it with
    # `state_key = NULL` (never `""`), and the power-level check on that path
    # is `:send_event` (events_default, 0 by default) — NOT
    # `set_room_state/2`'s `:change_state` check (state_default, 50 by
    # default). With the COALESCE in place, ANY joined member — even one with
    # default (0) power — could rename the room for everyone by hitting that
    # endpoint instead of the power-level-gated `PUT /state/m.room.name`
    # endpoint. This test pins that bypass closed: a non-power-user member's
    # bogus `m.room.name` sent via the generic non-state send path must NOT
    # become the room's name.
    test "a joined non-power-user member cannot rename the room via the non-state send path (MAJOR-2 regression guard)",
         %{token: owner_token, priv: priv} do
      room_id = create_sync_room(owner_token, "original-legit-name")

      {member_id, member_token} = bootstrap_secondary_user("rename-bypass-member", priv)
      invite_user(owner_token, room_id, member_id)
      join_room(member_token, room_id)

      # Confirm the bypass endpoint is actually reachable for this
      # non-power-user member (cycle-2 review's claim) — a joined member with
      # default power levels (events_default = 0) hitting the generic
      # non-state send path.
      bypass_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.name/rename-bypass-txn-1",
          %{"name" => "HACKED BY NON-POWER MEMBER"},
          auth(member_token)
        )

      # story power-levels-enforcement (D12 + D5 (a), AC16 re-pin; was: `200`): new rooms carry `events["m.room.name"]: 50`
      # and `/send` now enforces `events[type]` for message events too, so the non-power member is refused outright
      assert bypass_conn.status == 403,
             "the non-state send path of m.room.name is gated by events[m.room.name] (50) for a non-power member " <>
               "— got #{bypass_conn.status}, body: #{inspect(json(bypass_conn))}"

      assert json(bypass_conn) == %{"errcode" => "M_FORBIDDEN", "error" => "You do not have a high enough power level to send this event"}

      # the COALESCE regression guard itself (the subject of this test): a message event of type m.room.name that IS
      # accepted (the owner reaches events[m.room.name]) must still not become the room's name
      owner_bypass_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.name/rename-bypass-txn-2",
          %{"name" => "NOT A RENAME (a message event)"},
          auth(owner_token)
        )

      assert owner_bypass_conn.status == 200,
             "the non-state send path must be reachable for a sender at events[m.room.name] — got #{owner_bypass_conn.status}"

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(owner_token))
      assert sync.status == 200
      state_events = get_in(json(sync), ["rooms", "join", room_id, "state", "events"]) || []

      name_event = Enum.find(state_events, fn ev -> ev["type"] == "m.room.name" end)

      assert name_event != nil,
             "the room's m.room.name state event must still be present in state.events"

      assert name_event["content"]["name"] == "original-legit-name",
             "a joined non-power-user member must NOT be able to rename the room via the " <>
               "non-state send path — got #{inspect(name_event["content"]["name"])}, expected " <>
               "the original legitimately-set name. This is the room-rename authorization " <>
               "bypass (MAJOR-2, code-review cycle 2 -> 3) get_room_name/1's COALESCE revert " <>
               "closes."
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
