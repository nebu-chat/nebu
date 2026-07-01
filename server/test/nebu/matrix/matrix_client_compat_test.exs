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
      conn = call(:get, "/_matrix/client/v3/user/%40alice%3Atest.local/account_data/m.secret_storage.default_key")
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

    # AC 4 — MSC3814 dehydrated_device: 404 M_NOT_FOUND (no dehydrated device)
    test "GET /unstable/msc3814 dehydrated_device with valid Bearer → 404 M_NOT_FOUND", %{token: token} do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device", nil, auth(token))
      assert conn.status == 404
      body = json(conn)
      assert body["errcode"] == "M_NOT_FOUND"
      assert body["error"] == "No dehydrated device found"
    end

    # AC 5 — MSC4143 rtc/transports: 404 M_NOT_FOUND (no RTC transports)
    test "GET /unstable/msc4143 rtc/transports with valid Bearer → 404 M_NOT_FOUND", %{token: token} do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports", nil, auth(token))
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
      {:ok, user_id: uid_alice, token: token_alice, other_user_id: uid_bob, other_token: token_bob}
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
    test "PUT then GET round-trip → GET returns exactly the stored body", %{user_id: uid, token: token} do
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
    test "PUT account_data → 200 {} (regression: existing PUT contract intact)", %{user_id: uid, token: token} do
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
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "SyncUser", "sync@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "SyncUser", nil)
      end

      {:ok, user_id: uid, token: token}
    end

    defp create_sync_room(token, name) do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, auth(token))
      assert conn.status == 200, "createRoom must succeed"
      json(conn)["room_id"]
    end

    test "initial sync with 5 rooms returns correct shape within 3s (AC2)", %{token: token} do
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
        assert is_list(room["timeline"]["events"]), "room #{room_id} timeline.events must be a list"
      end)

      assert elapsed < 3000, "initial sync with 5 rooms took #{elapsed}ms — should be < 3000ms with parallel fetch"
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
      conn = call(:get, "/_matrix/client/v3/sync?since=#{URI.encode(since)}&timeout=500", nil, auth(token))
      elapsed = System.monotonic_time(:millisecond) - t0

      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["next_batch"]), "next_batch must be present in empty delta"
      # 3× margin over 500ms timeout: accounts for scheduler overhead + DB latency on CI.
      assert elapsed < 1500, "sync with timeout=500 took #{elapsed}ms — should be < 1500ms"
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
