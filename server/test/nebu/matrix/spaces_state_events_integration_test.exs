defmodule Nebu.Matrix.SpacesStateEventsIntegrationTest do
  @moduledoc """
  Integration tests for Matrix Spaces S2 — generic state-event PUT +
  m.space.child / m.space.parent (epic spaces-elixir, story s2-space-state-events).

  Drives the full `Nebu.Web.Router` via `Plug.Test` against the real OTP
  supervision tree + PostgreSQL (mirrors spaces_foundation_integration_test.exs).

  Tagged `:integration` — excluded from `mix test` (no DB); runs via
  `make test-integration`.

  Covers (Acceptance Tests 1-5):
    AT1 — PUT m.space.child by an authorized member → 200 + appears in /sync;
          empty content (unlink) → 200.
    AT2 — PUT by a non-member / under-PL sender → 403.
    AT3 — PUT a non-allowlisted type (m.room.member / m.room.power_levels /
          m.room.create) → 403 (SECURITY boundary).
    AT4 — PUT m.space.parent: member of parent → 200; non-member of parent → 403;
          non-existent parent → 404.
    AT5 — PUT m.room.name via the generic PUT → rooms.name updated.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "spaces-state-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirror spaces_foundation_integration_test.exs) ─────────

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

  defp db_room_name(room_id) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT name FROM rooms WHERE room_id = $1", [room_id])

    case rows do
      [[name]] -> name
      [] -> :no_row
    end
  end

  # Find the state events of a given type in a /sync response for room_id.
  defp sync_state_events(sync_body, room_id, type) do
    get_in(sync_body, ["rooms", "join", room_id, "state", "events"])
    |> Kernel.||([])
    |> Enum.filter(fn ev -> ev["type"] == type end)
  end

  defp create_room(token, body) do
    conn = call(:post, "/_matrix/client/v3/createRoom", body, auth(token))
    assert conn.status == 200
    json(conn)["room_id"]
  end

  describe "Spaces S2 — generic state PUT + m.space.child/parent" do
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

    # ─── AT1 — m.space.child by authorized member + unlink ────────────────────
    test "PUT m.space.child by the space creator → 200 and appears in /sync; unlink → 200", %{
      admin: admin
    } do
      space = create_room(admin, %{"name" => "My Space", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Child Room"})

      put =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(space)}/state/m.space.child/#{URI.encode_www_form(child)}",
          %{"via" => ["nebu.local"], "suggested" => false},
          auth(admin)
        )

      assert put.status == 200
      assert is_binary(json(put)["event_id"])

      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(admin))
      children = sync_state_events(json(sync), space, "m.space.child")

      assert Enum.any?(children, fn ev ->
               ev["state_key"] == child and ev["content"]["via"] == ["nebu.local"]
             end),
             "m.space.child must surface in /sync state, got: #{inspect(children)}"

      # Empty content (unlink) → still 200 with an event_id.
      unlink =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(space)}/state/m.space.child/#{URI.encode_www_form(child)}",
          %{},
          auth(admin)
        )

      assert unlink.status == 200
      assert is_binary(json(unlink)["event_id"])
    end

    # ─── AT2 — non-member / under-PL sender → 403 ─────────────────────────────
    test "PUT m.space.child by a non-member → 403", %{admin: admin, bob: bob} do
      space = create_room(admin, %{"name" => "Closed Space", "creation_content" => %{"type" => "m.space"}})

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(space)}/state/m.space.child/!child:test.local",
          %{"via" => ["nebu.local"]},
          auth(bob)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    # ─── AT3 — non-allowlisted types → 403 (SECURITY) ─────────────────────────
    for forbidden <- ["m.room.member", "m.room.power_levels", "m.room.create"] do
      test "PUT #{forbidden} via generic state PUT → 403 (security boundary)", %{admin: admin} do
        room = create_room(admin, %{"name" => "Room"})

        conn =
          call(
            :put,
            "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/state/#{unquote(forbidden)}/x",
            %{"membership" => "join"},
            auth(admin)
          )

        assert conn.status == 403
        assert json(conn)["errcode"] == "M_FORBIDDEN"
      end
    end

    # ─── AT4 — m.space.parent membership-of-parent security check ─────────────
    test "PUT m.space.parent: member of parent → 200; non-member → 403; missing parent → 404", %{
      admin: admin,
      bob: bob
    } do
      parent = create_room(admin, %{"name" => "Parent Space", "creation_content" => %{"type" => "m.space"}})
      child = create_room(admin, %{"name" => "Child"})

      # admin is a member of the parent → 200.
      ok =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(child)}/state/m.space.parent/#{URI.encode_www_form(parent)}",
          %{"via" => ["nebu.local"]},
          auth(admin)
        )

      assert ok.status == 200

      # bob creates his own child room and is NOT a member of admin's parent space → 403.
      bob_child = create_room(bob, %{"name" => "Bob Child"})

      forbidden =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(bob_child)}/state/m.space.parent/#{URI.encode_www_form(parent)}",
          %{"via" => ["nebu.local"]},
          auth(bob)
        )

      assert forbidden.status == 403
      assert json(forbidden)["errcode"] == "M_FORBIDDEN"

      # Non-existent parent → 404.
      missing =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(child)}/state/m.space.parent/!ghost:test.local",
          %{"via" => ["nebu.local"]},
          auth(admin)
        )

      assert missing.status == 404
      assert json(missing)["errcode"] == "M_NOT_FOUND"
    end

    # ─── AT5 — m.room.name via generic PUT denormalises rooms.name ────────────
    test "PUT m.room.name via generic state endpoint updates rooms.name", %{admin: admin} do
      room = create_room(admin, %{"name" => "Original"})

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room)}/state/m.room.name",
          %{"name" => "Renamed Via State"},
          auth(admin)
        )

      assert conn.status == 200
      assert db_room_name(room) == "Renamed Via State"
    end
  end
end
