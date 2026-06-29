defmodule Nebu.Matrix.SpacesRestrictedJoinIntegrationTest do
  @moduledoc """
  Integration tests for Matrix Spaces S4 — MSC3083 `restricted` join-rule
  enforcement (epic spaces-elixir, story s4-restricted-join).

  Drives the full `Nebu.Web.Router` via `Plug.Test` against the real OTP
  supervision tree + PostgreSQL (mirrors spaces_state_events_integration_test.exs).
  The restricted room is set up through the real S2 generic state PUT
  (`PUT /rooms/{roomId}/state/m.room.join_rules`), exactly as a client would.

  Tagged `:integration` — excluded from `mix test` (no DB); runs via
  `make test-integration`.

  Covers (Acceptance Tests 1, 2, 3):
    AT1 — restricted + joining user is a member of an allow[]-space → POST /join 200.
    AT2 — restricted + non-member, no invite → POST /join 403 M_FORBIDDEN.
    AT3 — restricted + pending invite (no space membership) → POST /join 200.
    Plus AC5 regression: a public room is still joinable by a non-member.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "spaces-restricted-key-1"

  @router_opts Nebu.Web.Router.init([])

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

  defp set_restricted(token, room, allow_room) do
    conn =
      call(
        :put,
        "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/state/m.room.join_rules",
        %{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => allow_room}]
        },
        auth(token)
      )

    assert conn.status == 200
    conn
  end

  defp join(token, room) do
    call(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room)}", %{}, auth(token))
  end

  describe "Spaces S4 — MSC3083 restricted join enforcement" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {admin_uid, admin_tok} = bearer_for("admin", priv)
      {bob_uid, bob_tok} = bearer_for("bob", priv)
      {carol_uid, carol_tok} = bearer_for("carol", priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(admin_uid, "user", "Admin", "admin@example.com")
        _ = Nebu.Matrix.Session.TokenValidator.validate(bob_uid, "user", "Bob", "bob@example.com")
        _ = Nebu.Matrix.Session.TokenValidator.validate(carol_uid, "user", "Carol", "carol@example.com")
      end

      {:ok,
       admin: admin_tok,
       admin_uid: admin_uid,
       bob: bob_tok,
       bob_uid: bob_uid,
       carol: carol_tok,
       carol_uid: carol_uid}
    end

    # ─── AT1 — member of the allow-space can self-join the restricted room ──────
    test "restricted room: a member of the allow-space joins → 200", %{
      admin: admin,
      bob: bob,
      bob_uid: bob_uid
    } do
      space = create_room(admin, %{"name" => "Eng Space", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Eng Child"})

      # bob becomes a member of the space (admin invites, bob joins).
      inv =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(space)}/invite",
          %{"user_id" => bob_uid},
          auth(admin)
        )

      assert inv.status == 200
      assert join(bob, space).status == 200

      # Make the child room restricted to members of the space.
      set_restricted(admin, child, space)

      # bob is a member of the allow-space → he may self-join the restricted child.
      assert join(bob, child).status == 200
    end

    # ─── AT2 — non-member with no invite is rejected ────────────────────────────
    test "restricted room: non-member of the allow-space and no invite → 403 M_FORBIDDEN", %{
      admin: admin,
      carol: carol
    } do
      space = create_room(admin, %{"name" => "Closed Space", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Closed Child"})

      set_restricted(admin, child, space)

      # carol is NOT a member of the space and has no invite to the child.
      conn = join(carol, child)
      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    # ─── AT3 — pending invite overrides restricted ──────────────────────────────
    test "restricted room: a pending invite lets a non-space-member join → 200", %{
      admin: admin,
      carol: carol,
      carol_uid: carol_uid
    } do
      space = create_room(admin, %{"name" => "Invite Space", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Invite Child"})

      set_restricted(admin, child, space)

      # carol is not in the space, but admin invites her directly to the child.
      inv =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(child)}/invite",
          %{"user_id" => carol_uid},
          auth(admin)
        )

      assert inv.status == 200

      # The pending invite overrides the restricted rule.
      assert join(carol, child).status == 200
    end

    # ─── AC5 regression — public rooms remain open ──────────────────────────────
    test "public room: a non-member can still join (no S4 regression)", %{
      admin: admin,
      carol: carol
    } do
      room = create_room(admin, %{"name" => "Public Room", "preset" => "public_chat"})

      # Ensure it is public via the join_rules state (preset may already do this).
      _ =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/state/m.room.join_rules",
          %{"join_rule" => "public"},
          auth(admin)
        )

      assert join(carol, room).status == 200
    end
  end
end
