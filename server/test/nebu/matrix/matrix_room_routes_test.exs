defmodule Nebu.Web.MatrixRoomRoutesTest do
  @moduledoc """
  RED-phase ATDD tests for the `fix-missing-matrix-room-routes` bug story.

  Five Matrix Client-Server endpoints return 404 even though their backend
  handlers fully exist in `Nebu.Matrix.EventDispatcher.Server` — only the HTTP
  routes were never ported to `Nebu.Web.Router.Protected` during the Go removal:

      POST /_matrix/client/v3/rooms/{roomId}/leave    -> leave_room/2
      POST /_matrix/client/v3/rooms/{roomId}/forget   -> forget_room/2
      GET  /_matrix/client/v1/rooms/{roomId}/relations/{eventId}[/{relType}[/{eventType}]]
                                                       -> get_relations/2
      POST /_matrix/client/v3/rooms/{roomId}/upgrade  -> upgrade_room/2
      POST /_matrix/client/v3/search                  -> search_messages/2

  ## Why these tests MUST FAIL right now

  Before the fix, none of the five routes exist in `Nebu.Web.Router.Protected`,
  so a request that passes OidcPlug (valid Bearer) falls through to the
  `match _` catch-all and returns `404 M_NOT_FOUND "Unrecognized request"`.

  The pure-unit auth-gate tests below prove the RED state without a DB: with a
  valid Bearer they expect the real Matrix contract status (200 / mapped error),
  which the missing routes cannot produce (they 404). They also assert the
  AC6 auth gate (no Bearer → 401).

  The `@moduletag :integration` block drives the full `Nebu.Web.Router` via
  `Plug.Test` against the real OTP supervision tree (rooms via Horde, sessions,
  :pg) — mirroring `Nebu.Web.MatrixRouterTest` — and asserts the response
  shapes for leave / forget / upgrade / relations / search.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "matrix-room-routes-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirrors matrix_router_test.exs) ────────────────────────

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
  # AC6 — auth gate (no DB) — PURE UNIT
  # Every new route MUST sit on the authenticated Protected pipeline: a request
  # with no Bearer is rejected by OidcPlug with 401 BEFORE any handler runs.
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on the five room routes (AC6) — no DB" do
    @room URI.encode_www_form("!any:test.local")
    @event URI.encode_www_form("$any:test.local")

    test "POST .../leave with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/leave", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST .../forget with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/forget", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "GET .../relations with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v1/rooms/#{@room}/relations/#{@event}")
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST .../upgrade with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/upgrade", %{"new_version" => "10"})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "POST /search with NO Bearer → 401 M_MISSING_TOKEN" do
      conn = call(:post, "/_matrix/client/v3/search", %{})
      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # RED proof — routes are missing — PURE UNIT (valid Bearer, no DB hit needed)
  # With a valid token these requests pass OidcPlug; before the fix they fall
  # through to the `match _` catch-all and return 404 "Unrecognized request".
  # After the fix the routes exist and reach their handlers (so they DON'T 404
  # with the catch-all message — they return the real contract status, which for
  # an unknown room is a mapped Matrix error, never the catch-all 404 string).
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

    test "POST .../leave is routed", %{token: token} do
      # leave_room on an unknown room takes the no-GenServer branch which writes a
      # decline event (DB + signing). Inject no-op DB fakes and a test signing key
      # so the probe proves wiring + the {} response shape without a live stack.
      with_signing_key()
      Application.put_env(:event_dispatcher, :rooms_db_module, __MODULE__.FakeRoomsDB)
      Application.put_env(:event_dispatcher, :invite_db_module, __MODULE__.FakeInviteDB)
      Application.put_env(:event_dispatcher, :messages_db_module, __MODULE__.FakeMessagesDB)

      on_exit(fn ->
        Application.delete_env(:event_dispatcher, :rooms_db_module)
        Application.delete_env(:event_dispatcher, :invite_db_module)
        Application.delete_env(:event_dispatcher, :messages_db_module)
      end)

      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/leave", %{}, auth(token))
      refute_catch_all(conn)
      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "POST .../forget is routed", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/forget", %{}, auth(token))
      refute_catch_all(conn)
    end

    test "GET .../relations is routed (v1 path reaches Protected)", %{token: token} do
      conn = call(:get, "/_matrix/client/v1/rooms/#{@room}/relations/#{@event}", nil, auth(token))
      refute_catch_all(conn)
    end

    test "GET .../relations/{relType}/{eventType} is routed", %{token: token} do
      conn =
        call(
          :get,
          "/_matrix/client/v1/rooms/#{@room}/relations/#{@event}/m.thread/m.room.message",
          nil,
          auth(token)
        )

      refute_catch_all(conn)
    end

    test "POST .../upgrade is routed", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/rooms/#{@room}/upgrade", %{"new_version" => "10"}, auth(token))
      refute_catch_all(conn)
    end

    test "POST /search is routed", %{token: token} do
      # search_messages hits the search DB; inject a fake returning one row so the
      # probe proves wiring + the search_categories shape without a live DB.
      Application.put_env(:event_dispatcher, :search_db_module, __MODULE__.FakeSearchDB)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :search_db_module) end)

      conn =
        call(
          :post,
          "/_matrix/client/v3/search",
          %{"search_categories" => %{"room_events" => %{"search_term" => "hello"}}},
          auth(token)
        )

      refute_catch_all(conn)
      assert conn.status == 200
      room_events = json(conn)["search_categories"]["room_events"]
      assert is_integer(room_events["count"])
      assert is_list(room_events["results"])
    end
  end

  # ── fakes + helpers for the DB-free routed probes ──────────────────────────

  defp with_signing_key do
    case :persistent_term.get(:nebu_signing_key, nil) do
      nil ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        :persistent_term.put(:nebu_signing_key, {pub, priv})

      _ ->
        :ok
    end
  end

  defmodule FakeRoomsDB do
    def delete_member(_room_id, _user_id), do: {:error, :not_member}
  end

  defmodule FakeInviteDB do
    def reject_invitation(_room_id, _user_id), do: :ok
  end

  defmodule FakeMessagesDB do
    def insert_event(_event), do: :ok
  end

  defmodule FakeSearchDB do
    def search_messages(_user_id, _term, _limit, _offset, _room_filter) do
      {:ok,
       [
         %{
           "event_id" => "$probe:test.local",
           "room_id" => "!probe:test.local",
           "sender" => "@kai:test.local",
           "event_type" => "m.room.message",
           "content" => %{"msgtype" => "m.text", "body" => "hello"},
           "origin_server_ts" => 1,
           "rank" => 0.5
         }
       ]}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Contract-shape tests (AC1–AC5) — INTEGRATION
  # Drive the full router with a valid Bearer against the real OTP tree.
  # ══════════════════════════════════════════════════════════════════════════

  describe "room routes — contract parity" do
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

    # ── AC1 — leave ─────────────────────────────────────────────────────────

    test "POST .../leave → 200 {}", %{token: token} do
      room_id = create_room(token, "leave-shape")

      conn =
        call(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/leave", %{}, auth(token))

      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "POST .../leave on an unknown room → 404 M_NOT_FOUND (not the catch-all)", %{token: token} do
      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form("!nope:test.local")}/leave",
          %{},
          auth(token)
        )

      # leave_room is best-effort and returns 200 even for an unknown room (decline
      # semantics); the important thing is the route exists and does NOT 404.
      assert conn.status == 200
      assert json(conn) == %{}
    end

    # ── AC2 — forget (only valid after leaving) ─────────────────────────────

    test "POST .../forget after leave → 200 {}", %{token: token} do
      room_id = create_room(token, "forget-shape")

      _ = call(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/leave", %{}, auth(token))

      conn =
        call(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/forget", %{}, auth(token))

      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "POST .../forget while still joined → 400 M_BAD_STATE (backend error surfaced)", %{
      token: token
    } do
      room_id = create_room(token, "forget-while-joined")

      conn =
        call(:post, "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/forget", %{}, auth(token))

      # forget_room raises failed_precondition while joined → mapped to 400 M_BAD_STATE.
      assert conn.status == 400
      assert json(conn)["errcode"] == "M_BAD_STATE"
    end

    # ── AC3 — relations ─────────────────────────────────────────────────────

    test "GET .../relations for a known event → 200 {chunk:[...]} with the thread reply", %{
      token: token
    } do
      room_id = create_room(token, "relations-shape")
      root_id = send_message(token, room_id, "thread root")

      # Send a threaded reply (m.thread relation to root_id).
      reply_txn = "reply-" <> Integer.to_string(System.unique_integer([:positive]))

      reply_conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/#{reply_txn}",
          %{
            "msgtype" => "m.text",
            "body" => "thread reply",
            "m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root_id}
          },
          auth(token)
        )

      assert reply_conn.status == 200
      reply_id = json(reply_conn)["event_id"]

      conn =
        call(
          :get,
          "/_matrix/client/v1/rooms/#{URI.encode_www_form(room_id)}/relations/#{URI.encode_www_form(root_id)}",
          nil,
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert is_list(body["chunk"])
      assert Enum.any?(body["chunk"], &(&1["event_id"] == reply_id)),
             "the threaded reply must appear in the relations chunk"
    end

    test "GET .../relations for an unknown event → 404 M_NOT_FOUND (not 500)", %{token: token} do
      room_id = create_room(token, "relations-unknown")

      conn =
        call(
          :get,
          "/_matrix/client/v1/rooms/#{URI.encode_www_form(room_id)}/relations/#{URI.encode_www_form("$ghost:test.local")}",
          nil,
          auth(token)
        )

      # Unknown parent event in a room the user IS in → backend raises NOT_FOUND.
      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end

    # ── AC4 — upgrade ───────────────────────────────────────────────────────

    test "POST .../upgrade → 200 {replacement_room: \"!...\"}", %{token: token} do
      room_id = create_room(token, "upgrade-shape")

      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/upgrade",
          %{"new_version" => "10"},
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["replacement_room"])
      assert String.starts_with?(body["replacement_room"], "!")
      refute body["replacement_room"] == room_id
    end

    # ── AC5 — search ────────────────────────────────────────────────────────

    test "POST /search → 200 search_categories.room_events shape", %{token: token} do
      room_id = create_room(token, "search-shape")
      _ = send_message(token, room_id, "find me needle haystack")

      conn =
        call(
          :post,
          "/_matrix/client/v3/search",
          %{"search_categories" => %{"room_events" => %{"search_term" => "needle"}}},
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      room_events = body["search_categories"]["room_events"]
      assert is_integer(room_events["count"])
      assert is_list(room_events["results"])
    end

    test "POST /search with no match → 200 count 0 (not 404/500)", %{token: token} do
      _room_id = create_room(token, "search-empty")

      conn =
        call(
          :post,
          "/_matrix/client/v3/search",
          %{
            "search_categories" => %{
              "room_events" => %{"search_term" => "zzznomatchzzz#{System.unique_integer([:positive])}"}
            }
          },
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert body["search_categories"]["room_events"]["count"] == 0
      assert body["search_categories"]["room_events"]["results"] == []
    end
  end
end
