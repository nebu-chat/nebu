defmodule Nebu.Matrix.SpacesFoundationIntegrationTest do
  @moduledoc """
  Integration tests for Matrix Spaces foundation (epic spaces-elixir, story
  s1-spaces-foundation). Drives the full `Nebu.Web.Router` via `Plug.Test` against
  the real OTP supervision tree + PostgreSQL (mirrors matrix_room_routes_test.exs).

  Tagged `:integration` — excluded from `mix test` (no DB); runs via
  `make test-integration` (sets NEBU_DB_URL, starts Nebu.Repo).

  Covers:
    AC1 — POST /createRoom with creation_content.type=m.space → stored
          m.room.create content.type == "m.space" (verified via /sync, AC3).
    AC2 — rooms.room_type == 'm.space' for the space; NULL for a regular room.
    AC3 — /sync surfaces the space's m.room.create state event with content.type.
    AC4 — backward compat: regular room has no type key in create content and
          rooms.room_type IS NULL.
    AC5 — extra creation_content keys merged into create content; creator/room_version
          remain server-authoritative even if the client tries to override them.
    Migration — rooms.room_type column exists (000004).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "spaces-foundation-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror matrix_room_routes_test.exs) ────────────────────

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

  defp call(method, path, body, headers) do
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

  defp db_room_type(room_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT room_type FROM rooms WHERE room_id = $1", [room_id])

    case rows do
      [[rt]] -> rt
      [] -> :no_row
    end
  end

  # Find the m.room.create state event for room_id in a /sync response.
  defp sync_create_content(sync_body, room_id) do
    get_in(sync_body, ["rooms", "join", room_id, "state", "events"])
    |> Kernel.||([])
    |> Enum.find(fn ev -> ev["type"] == "m.room.create" end)
    |> case do
      nil -> nil
      ev -> ev["content"]
    end
  end

  describe "Spaces foundation — createRoom + room_type" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = bearer_for("kai", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Kai", "kai@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Kai", nil)
      end

      {:ok, user_id: uid, token: token}
    end

    # ─── Migration — rooms.room_type column exists ────────────────────────────
    test "migration 000004 added the rooms.room_type column" do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'rooms' AND column_name = 'room_type'",
          []
        )

      assert rows == [["room_type"]],
             "expected rooms.room_type column to exist after migration 000004"
    end

    # ─── AC1 + AC2 + AC3 — create a Space ─────────────────────────────────────
    test "creating a Space stores content.type=m.space and rooms.room_type='m.space'", %{
      token: token
    } do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{"name" => "My Space", "creation_content" => %{"type" => "m.space"}},
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      # AC2 — denormalised column.
      assert db_room_type(room_id) == "m.space"

      # AC1 + AC3 — /sync surfaces m.room.create with content.type == m.space.
      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert sync.status == 200
      content = sync_create_content(json(sync), room_id)

      assert content != nil, "m.room.create state event must be present in /sync"
      assert content["type"] == "m.space"
      assert content["creator"] == "@kai:test.local"
      assert content["room_version"] == "10"
    end

    # ─── AC4 — backward compatibility (regular room) ──────────────────────────
    test "creating a regular room leaves rooms.room_type NULL and no type key", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => "Plain Room"}, auth(token))
      assert conn.status == 200
      room_id = json(conn)["room_id"]

      # AC2/AC4 — column is NULL for an ordinary room.
      assert db_room_type(room_id) == nil

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      content = sync_create_content(json(sync), room_id)
      assert content != nil
      refute Map.has_key?(content, "type"),
             "a regular room's create content must not have a type key, got: #{inspect(content)}"
    end

    # ─── AC5 — extra keys merged; creator/room_version protected ──────────────
    test "extra creation_content keys are merged; creator/room_version not overridable", %{
      token: token
    } do
      conn =
        call(
          :post,
          "/_matrix/client/v3/createRoom",
          %{
            "name" => "Extra Keys Space",
            "creation_content" => %{
              "type" => "m.space",
              "m.federate" => false,
              "creator" => "@evil:test.local",
              "room_version" => "1"
            }
          },
          auth(token)
        )

      assert conn.status == 200
      room_id = json(conn)["room_id"]

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      content = sync_create_content(json(sync), room_id)

      assert content["type"] == "m.space"
      assert content["m.federate"] == false
      # Server-authoritative: client overrides are ignored.
      assert content["creator"] == "@kai:test.local"
      assert content["room_version"] == "10"
    end
  end
end
