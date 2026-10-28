defmodule Nebu.Admin.SpaceEditAuditIntegrationTest do
  @moduledoc """
  Story `space-edit-audit` (follow-up `dj`), integration part (real PostgreSQL, the real `Nebu.Compliance.AuditWriter`, the real Room GenServer):

    * AC7: the Admin UI path end to end. `POST /admin/spaces/:id` (name + topic -> 2 rows), `POST /admin/spaces/:id/children` (1 row), `DELETE /admin/spaces/:id/children/:child_id`
      (1 row): actor = the admin's Matrix id, target_type `room`, target_id = the space, outcome `success`, `event_id` in the metadata and that event exists in `events`.
    * AC3 end to end: a refused state write (admin is not a member) writes no row; unknown room: `{:error, _}`, no row.
    * AC4 end to end: a failing audit writer does not turn the edit into an error (the redirect with the success flash, the event is stored).
    * AC8: the generic client `PUT /_matrix/client/v3/rooms/:id/state/...` writes NO space audit row (negative test, with a positive control: the admin edit of the same
      space afterwards writes exactly its own row, so the query used for "no row" is proven able to see a row).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-space-edit-audit-key-base", 3)
  @actions ~w(space_name_changed space_topic_changed space_child_added space_child_removed)

  # the client part (AC8): a real Matrix bearer token, same helpers as spaces_state_events_integration_test.exs
  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "space-edit-audit-key-1"
  @router_opts Nebu.Web.Router.init([])

  defmodule FailingAudit do
    @moduledoc false
    def log(_actor, _action, _type, _id, _metadata, _outcome, _detail \\ nil), do: {:error, :audit_write_failed}
  end

  setup do
    Application.delete_env(:nebu_http, :admin_spaces_state_writer)
    T.put_env_scoped(:audit_writer, Nebu.Compliance.AuditWriter, :compliance)
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    admin = T.provision_user!()
    assert {:ok, space} = Nebu.Matrix.create_space(admin, "Audit Space")

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      T.privileged_sql!("DELETE FROM audit_log WHERE target_id = $1 AND action = ANY($2)", [space, @actions])
    end)

    {:ok, admin: admin, space: space, child: "!child-#{System.unique_integer([:positive])}:test.local"}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp enc(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp admin_conn(method, path, params, matrix_user_id) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => matrix_user_id})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  # [[action, actor, target_type, outcome, name, topic, child_room_id, event_id]] of the four space actions for `space`, ordered by id (insertion order)
  defp rows(space) do
    T.privileged_sql!(
      "SELECT action, actor_user_id, target_type, outcome, metadata->>'name', metadata->>'topic', metadata->>'child_room_id', metadata->>'event_id' " <>
        "FROM audit_log WHERE target_id = $1 AND action = ANY($2) ORDER BY id",
      [space, @actions]
    ).rows
  end

  defp event_exists?(event_id), do: T.sql!("SELECT 1 FROM events WHERE event_id = $1", [event_id]).rows != []

  defp flash(conn, key) do
    k = to_string(key)
    from_assigns = if is_map(conn.assigns[:flash]), do: conn.assigns[:flash][k]

    from_session =
      case conn.private[:plug_session] do
        %{"phoenix_flash" => m} when is_map(m) -> m[k]
        _ -> nil
      end

    from_assigns || get_in(conn.private, [:phoenix_flash, k]) || from_session
  end

  # ── AC7: the Admin UI path end to end ───────────────────────────────────────

  describe "AC7 - the admin UI edits leave audit rows (real writer)" do
    test "POST /admin/spaces/:id with name + topic writes two rows (space_name_changed, space_topic_changed) with actor, target, outcome and the event ids", %{admin: admin, space: space} do
      conn = admin_conn(:post, "/admin/spaces/" <> enc(space), %{"name" => "Renamed Space", "topic" => "A new topic"}, admin) |> call()
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ "Space saved"

      assert [
               ["space_name_changed", ^admin, "room", "success", "Renamed Space", nil, nil, name_event],
               ["space_topic_changed", ^admin, "room", "success", nil, "A new topic", nil, topic_event]
             ] = rows(space)

      assert name_event != topic_event
      assert event_exists?(name_event) and event_exists?(topic_event), "the audit rows link to the events records"
    end

    test "POST /admin/spaces/:id/children writes one space_child_added row (child_room_id + event_id)", %{admin: admin, space: space, child: child} do
      conn = admin_conn(:post, "/admin/spaces/" <> enc(space) <> "/children", %{"child_room_id" => child}, admin) |> call()
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ "Child added"

      assert [["space_child_added", ^admin, "room", "success", nil, nil, ^child, event_id]] = rows(space)
      assert event_exists?(event_id)
    end

    test "DELETE /admin/spaces/:id/children/:child_id writes one space_child_removed row (after an add: add, then remove, in that order)", %{admin: admin, space: space, child: child} do
      added = admin_conn(:post, "/admin/spaces/" <> enc(space) <> "/children", %{"child_room_id" => child}, admin) |> call()
      assert added.status in [302, 303]

      conn = admin_conn(:delete, "/admin/spaces/" <> enc(space) <> "/children/" <> enc(child), %{}, admin) |> call()
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ "Child removed"

      assert [
               ["space_child_added", ^admin, "room", "success", nil, nil, ^child, _],
               ["space_child_removed", ^admin, "room", "success", nil, nil, ^child, removed_event]
             ] = rows(space)

      assert event_exists?(removed_event)
    end
  end

  # ── AC3 end to end ──────────────────────────────────────────────────────────

  describe "AC3 - a refused write writes no row (real room, real authorization)" do
    test "an admin who is not a member of the space: the save is refused, no row", %{space: space} do
      outsider = T.provision_user!()
      conn = admin_conn(:post, "/admin/spaces/" <> enc(space), %{"name" => "Hijacked", "topic" => "x"}, outsider) |> call()

      assert conn.status == 200, "the error branch re-renders the detail page (no redirect)"
      assert conn.resp_body =~ "Could not save"
      refute to_string(flash(conn, :info)) =~ "Space saved"
      assert rows(space) == []
    end

    test "Nebu.Matrix.set_space_state/5 on an unknown room returns {:error, _} and writes no row", %{admin: admin} do
      ghost = "!ghost-#{System.unique_integer([:positive])}:test.local"
      assert {:error, _} = Nebu.Matrix.set_space_state(ghost, admin, "m.room.name", "", %{"name" => "Nope"})
      assert rows(ghost) == []
    end
  end

  # ── AC4 end to end ──────────────────────────────────────────────────────────

  describe "AC4 - a failing audit write does not fail the admin request (D3: non-atomic by decision)" do
    test "with a failing audit writer POST /admin/spaces/:id still redirects with the success flash, the events are stored, no audit row exists", %{admin: admin, space: space} do
      T.put_env_scoped(:audit_writer, FailingAudit, :compliance)

      capture_log(fn ->
        send(self(), {:conn, admin_conn(:post, "/admin/spaces/" <> enc(space), %{"name" => "Still Saved", "topic" => "Still saved too"}, admin) |> call()})
      end)

      assert_received {:conn, conn}
      assert conn.status in [302, 303]
      assert flash(conn, :info) =~ "Space saved"
      assert [[name]] = T.sql!("SELECT name FROM rooms WHERE room_id = $1", [space]).rows
      assert name == "Still Saved", "the edit is applied (rooms.name is denormalised from the event)"

      # the events stay in the append-only record with sender = the admin (the primary record when the audit row is lost, D3)
      assert [[1]] = T.sql!("SELECT count(*)::int FROM events WHERE room_id = $1 AND event_type = 'm.room.name' AND sender = $2 AND content->>'name' = 'Still Saved'", [space, admin]).rows
      assert [[1]] = T.sql!("SELECT count(*)::int FROM events WHERE room_id = $1 AND event_type = 'm.room.topic' AND sender = $2 AND content->>'topic' = 'Still saved too'", [space, admin]).rows
      assert rows(space) == []
    end
  end

  # ── AC8: the generic client PUT writes no space audit row ───────────────────

  describe "AC8 - the generic client PUT /_matrix/client/v3/rooms/:id/state/... writes NO space audit row" do
    setup do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      {_, priv_map} = JOSE.JWK.to_map(jwk)
      pub_jwk = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1) |> Map.put("kid", @kid) |> Map.put("alg", "RS256") |> Map.put("use", "sig")
      priv_jwk = Map.put(priv_map, "kid", @kid)

      Application.put_env(:nebu_http, :server_name, @server_name)
      Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

      on_exit(fn ->
        Application.delete_env(:nebu_http, :server_name)
        Nebu.Web.OidcTestSupport.clear()
        Application.delete_env(:nebu_http, :oidc_jwks)
      end)

      sub = "space-audit-client-#{System.unique_integer([:positive])}"
      uid = "@" <> sub <> ":" <> @server_name
      {:ok, _} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Client", "client@example.com")

      claims = %{"iss" => @issuer, "aud" => @audience, "sub" => sub, "exp" => System.system_time(:second) + 3600, "iat" => System.system_time(:second)}
      signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), %{"alg" => "RS256", "kid" => @kid}, claims)
      {_, token} = JOSE.JWS.compact(signed)

      {:ok, client_uid: uid, token: token}
    end

    defp client(method, path, body, token) do
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Nebu.Web.Router.call(@router_opts)
    end

    test "client PUTs of name, topic and m.space.child (add, unlink) write no row; a control admin edit of another space writes its own rows",
         %{client_uid: client_uid, token: token, admin: admin, space: space, child: child} do
      # the client creates its own space through the Matrix API and edits it through the generic state endpoint
      created = client(:post, "/_matrix/client/v3/createRoom", %{"name" => "Client Space", "creation_content" => %{"type" => "m.space"}}, token)
      assert created.status == 200
      client_space = Jason.decode!(created.resp_body)["room_id"]
      base = "/_matrix/client/v3/rooms/#{URI.encode_www_form(client_space)}/state"

      for {path, body} <- [
            {"#{base}/m.room.name", %{"name" => "Client Edited"}},
            {"#{base}/m.room.topic", %{"topic" => "Client edited topic"}},
            {"#{base}/m.space.child/#{URI.encode_www_form(child)}", %{"via" => ["test.local"]}},
            {"#{base}/m.space.child/#{URI.encode_www_form(child)}", %{}}
          ] do
        put = client(:put, path, body, token)
        assert put.status == 200, "#{path}: #{put.resp_body}"
      end

      assert rows(client_space) == [], "a Matrix client edit is not an admin action (D1)"
      assert T.privileged_sql!("SELECT 1 FROM audit_log WHERE actor_user_id = $1 AND action = ANY($2)", [client_uid, @actions]).rows == [], "no row for the client as an actor either"

      # positive control: the same kind of edit through the admin entry point of another space DOES write its row (the query above is able to see a row)
      control = admin_conn(:post, "/admin/spaces/" <> enc(space), %{"name" => "Control", "topic" => "Control topic"}, admin) |> call()
      assert control.status in [302, 303]
      assert [["space_name_changed" | _], ["space_topic_changed" | _]] = rows(space)
      assert rows(client_space) == []

      T.privileged_sql!("DELETE FROM audit_log WHERE target_id = $1", [client_space])
    end
  end
end
