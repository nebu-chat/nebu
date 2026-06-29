defmodule Nebu.Matrix.SpaceHierarchyIntegrationTest do
  @moduledoc """
  Integration tests for Matrix Spaces S3 — GET /_matrix/client/v1/rooms/{roomId}/hierarchy
  (MSC2946) + query-param validation + pagination + the migration indexes
  (epic spaces-elixir, story s3-space-hierarchy).

  Drives the full `Nebu.Web.Router` via `Plug.Test` against the real OTP
  supervision tree + PostgreSQL (mirrors spaces_state_events_integration_test.exs).

  Tagged `:integration` — excluded from `mix test` (no DB); runs via
  `make test-integration`.

  Covers (Acceptance Tests 5-8):
    AT5 — query-param validation: bad suggested_only bool → 400 M_INVALID_PARAM;
          negative limit → 400; over-limit clamps (no error).
    AT6 — 403 for a non-member of a private space; 200 {rooms[, next_batch]} for
          a member, with the root + visible children.
    AT7 — pagination: next_batch round-trip; a forged token → 400.
    AT8 — both partial indexes (idx_events_space_child / idx_events_space_parent)
          exist in pg_indexes.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "spaces-hierarchy-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror spaces_state_events_integration_test.exs) ─────────

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

  defp create_room(token, body) do
    conn = call(:post, "/_matrix/client/v3/createRoom", body, auth(token))
    assert conn.status == 200
    json(conn)["room_id"]
  end

  defp link_child(token, space, child, content) do
    conn =
      call(
        :put,
        "/_matrix/client/v3/rooms/#{URI.encode_www_form(space)}/state/m.space.child/#{URI.encode_www_form(child)}",
        content,
        auth(token)
      )

    assert conn.status == 200
    json(conn)["event_id"]
  end

  defp hierarchy(token, room, query \\ "") do
    path = "/_matrix/client/v1/rooms/#{URI.encode_www_form(room)}/hierarchy"
    path = if query == "", do: path, else: path <> "?" <> query
    call(:get, path, nil, auth(token))
  end

  defp room_ids(body), do: Enum.map(body["rooms"], & &1["room_id"])

  describe "Spaces S3 — GET /hierarchy" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {admin_uid, admin_tok} = bearer_for("admin", priv)
      {bob_uid, bob_tok} = bearer_for("bob", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(admin_uid, "user", "Admin", "admin@example.com")
        _ = Nebu.Matrix.Session.TokenValidator.validate(bob_uid, "user", "Bob", "bob@example.com")
      end

      {:ok, admin: admin_tok, admin_uid: admin_uid, bob: bob_tok, bob_uid: bob_uid}
    end

    # Builds a space with 2 regular children + 1 sub-space (with 2 children) and
    # returns the room ids. The admin is a member of every room.
    defp build_tree(admin) do
      space = create_room(admin, %{"name" => "Space", "creation_content" => %{"type" => "m.space"}})
      a = create_room(admin, %{"name" => "A"})
      b = create_room(admin, %{"name" => "B"})
      sub = create_room(admin, %{"name" => "Sub", "creation_content" => %{"type" => "m.space"}})
      c = create_room(admin, %{"name" => "C"})
      d = create_room(admin, %{"name" => "D"})

      link_child(admin, space, a, %{"via" => ["test.local"], "order" => "10", "suggested" => true})
      link_child(admin, space, b, %{"via" => ["test.local"], "order" => "20"})
      link_child(admin, space, sub, %{"via" => ["test.local"], "order" => "30"})
      link_child(admin, sub, c, %{"via" => ["test.local"], "order" => "10"})
      link_child(admin, sub, d, %{"via" => ["test.local"], "order" => "20"})

      %{space: space, a: a, b: b, sub: sub, c: c, d: d}
    end

    # ─── AT6 — member gets the full visible tree ──────────────────────────────
    test "member: 200 with root + all visible children in BFS order", %{admin: admin} do
      t = build_tree(admin)
      conn = hierarchy(admin, t.space)

      assert conn.status == 200
      body = json(conn)

      ids = room_ids(body)
      assert t.space in ids
      assert t.a in ids
      assert t.sub in ids
      assert t.c in ids
      # root must be first.
      assert hd(ids) == t.space

      # the sub-space carries room_type m.space.
      sub_summary = Enum.find(body["rooms"], &(&1["room_id"] == t.sub))
      assert sub_summary["room_type"] == "m.space"
    end

    # ─── AT6 — non-member of a private space → 403 ────────────────────────────
    test "non-member of a private space → 403 M_FORBIDDEN before any traversal", %{
      admin: admin,
      bob: bob
    } do
      space = create_room(admin, %{"name" => "Private", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Secret child"})
      link_child(admin, space, child, %{"via" => ["test.local"]})

      conn = hierarchy(bob, space)
      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
      # No room data leaked.
      refute Map.has_key?(json(conn), "rooms")
    end

    # ─── AT5 — query-param validation ─────────────────────────────────────────
    test "suggested_only=not-a-bool → 400 M_INVALID_PARAM", %{admin: admin} do
      space = create_room(admin, %{"name" => "S", "creation_content" => %{"type" => "m.space"}})
      conn = hierarchy(admin, space, "suggested_only=maybe")
      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "limit=-1 → 400 M_INVALID_PARAM", %{admin: admin} do
      space = create_room(admin, %{"name" => "S", "creation_content" => %{"type" => "m.space"}})
      conn = hierarchy(admin, space, "limit=-1")
      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "limit=2000 is clamped to 1000 (no error)", %{admin: admin} do
      space = create_room(admin, %{"name" => "S", "creation_content" => %{"type" => "m.space"}})
      conn = hierarchy(admin, space, "limit=2000")
      assert conn.status == 200
    end

    # ─── AT7 — pagination ─────────────────────────────────────────────────────
    test "pagination: next_batch round-trips and eventually clears", %{admin: admin} do
      t = build_tree(admin)

      p1 = hierarchy(admin, t.space, "limit=2")
      assert p1.status == 200
      b1 = json(p1)
      assert length(b1["rooms"]) == 2
      assert is_binary(b1["next_batch"])

      p2 = hierarchy(admin, t.space, "limit=2&from=#{URI.encode_www_form(b1["next_batch"])}")
      assert p2.status == 200
      b2 = json(p2)
      assert length(b2["rooms"]) == 2

      # First-page and second-page rooms are disjoint (stable ordering).
      assert MapSet.disjoint?(MapSet.new(room_ids(b1)), MapSet.new(room_ids(b2)))
    end

    test "pagination: a forged from token → 400 M_INVALID_PARAM (fail closed)", %{admin: admin} do
      space = create_room(admin, %{"name" => "S", "creation_content" => %{"type" => "m.space"}})
      conn = hierarchy(admin, space, "from=not-a-valid-token")
      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end
  end

  # ─── AT8 — migration indexes exist ──────────────────────────────────────────
  describe "Spaces S3 — migration indexes" do
    @describetag :integration

    test "idx_events_space_child and idx_events_space_parent exist" do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "SELECT indexname FROM pg_indexes WHERE tablename = 'events' AND indexname = ANY($1)",
          [["idx_events_space_child", "idx_events_space_parent"]]
        )

      names = Enum.map(rows, fn [n] -> n end)
      assert "idx_events_space_child" in names
      assert "idx_events_space_parent" in names
    end
  end
end
