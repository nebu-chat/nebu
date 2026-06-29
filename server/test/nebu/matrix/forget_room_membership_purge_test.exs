defmodule Nebu.Matrix.ForgetRoomMembershipPurgeTest do
  @moduledoc """
  RED-phase ATDD tests for the `forget-room-membership-purge` bug story.

  `POST /_matrix/client/v3/rooms/{roomId}/forget` (`forget_room/2` in
  `Nebu.Matrix.EventDispatcher.Server`) is an MVP stub: it verifies the room
  exists and rejects forgetting a still-joined room (`M_BAD_STATE`), but on
  success it returns an empty body **without persisting anything**. The
  `forgotten_rooms (user_id, room_id, forgotten_at_ms)` table already exists in
  `000001_init.up.sql` but is never written to or read from.

  These integration tests drive the full `Nebu.Web.Router` via `Plug.Test`
  against the real OTP supervision tree (rooms via Horde, sessions, :pg) and
  assert the seven acceptance criteria of the story:

    AC1  forget after leave persists a `forgotten_rooms` row + 200 {}
    AC2  forget while still joined → 400 M_BAD_STATE, writes nothing (regression)
    AC3  forgotten room excluded from initial /sync (join/invite/leave)
    AC4  forgotten room excluded from incremental /sync (leave path)
    AC5  per-user isolation — A's forget does not affect B's sync
    AC6  re-join clears the forget (row removed, room reappears)
    AC7  idempotent forget — second POST → 200 {}, still exactly one row

  Persistence Strategy (story): Option B — PostgreSQL. There is no GenServer
  state; AC3/AC4 are proven across a fresh sync query (durable in PG, not
  volatile memory). No Horde crash/restart test is required.

  ## Why these tests FAIL before the fix

  `forget_room/2` returns `%Core.ForgetRoomResponse{}` without inserting into
  `forgotten_rooms`, and the two sync builders (`get_initial_sync`,
  `do_incremental_sync`) have no notion of forgotten rooms — so the
  forgotten-row assertion (AC1/AC7), the sync-exclusion assertions (AC3/AC4),
  and the re-join clear assertion (AC6) all fail until the fix lands.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "forget-room-purge-key-1"

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
    uid = "@" <> sub <> ":" <> @server_name
    {uid, compact}
  end

  defp call(method, path, body, headers) do
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
  defp enc(room_id), do: URI.encode_www_form(room_id)

  # ── flow helpers (drive the router itself — no DB seeding shortcuts) ───────

  defp provision(uid, name) do
    _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", name, "#{name}@example.com")
    _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, name, nil)
    :ok
  end

  defp create_room(token, name) do
    conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, auth(token))
    assert conn.status == 200, "createRoom must succeed to set up the scenario"
    json(conn)["room_id"]
  end

  defp leave_room(token, room_id) do
    conn = call(:post, "/_matrix/client/v3/rooms/#{enc(room_id)}/leave", %{}, auth(token))
    assert conn.status == 200, "leave must succeed to set up the scenario"
    conn
  end

  defp forget_room(token, room_id) do
    call(:post, "/_matrix/client/v3/rooms/#{enc(room_id)}/forget", %{}, auth(token))
  end

  defp join_room(token, room_id) do
    call(:post, "/_matrix/client/v3/join/#{enc(room_id)}", %{}, auth(token))
  end

  defp sync(token, query \\ "") do
    path = "/_matrix/client/v3/sync" <> if(query == "", do: "", else: "?" <> query)
    conn = call(:get, path, nil, auth(token))
    assert conn.status == 200, "sync must return 200"
    json(conn)
  end

  # Returns true if `room_id` appears in ANY section of the sync rooms map.
  defp room_in_sync?(sync_body, room_id) do
    rooms = sync_body["rooms"] || %{}

    ["join", "invite", "leave"]
    |> Enum.any?(fn section ->
      Map.has_key?(rooms[section] || %{}, room_id)
    end)
  end

  defp forgotten_row_count(user_id, room_id) do
    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT count(*) FROM forgotten_rooms WHERE user_id = $1 AND room_id = $2",
        [user_id, room_id]
      )

    count
  end

  setup do
    priv = setup_oidc_keys()
    {uid, token} = bearer_for("kai", priv)
    if Process.whereis(Nebu.Repo), do: provision(uid, "Kai")
    {:ok, priv_jwk: priv, user_id: uid, token: token}
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC1 — forget-after-leave persists + 200
  # ════════════════════════════════════════════════════════════════════════

  describe "AC1 — forget after leave persists" do
    test "200 {} and a forgotten_rooms row exists for (user, room)", %{user_id: uid, token: token} do
      room_id = create_room(token, "ac1-forget")
      leave_room(token, room_id)

      conn = forget_room(token, room_id)

      assert conn.status == 200
      assert json(conn) == %{}
      assert forgotten_row_count(uid, room_id) == 1
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC2 — join-guard unchanged (regression) — 400 M_BAD_STATE, no write
  # ════════════════════════════════════════════════════════════════════════

  describe "AC2 — forget while still joined" do
    test "400 M_BAD_STATE and writes nothing to forgotten_rooms", %{user_id: uid, token: token} do
      room_id = create_room(token, "ac2-joined")

      conn = forget_room(token, room_id)

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_BAD_STATE"
      assert forgotten_row_count(uid, room_id) == 0
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC3 — excluded from initial /sync
  # ════════════════════════════════════════════════════════════════════════

  describe "AC3 — initial sync exclusion" do
    test "a forgotten room is absent from join/invite/leave of a fresh full /sync", %{token: token} do
      room_id = create_room(token, "ac3-initial")
      leave_room(token, room_id)
      assert forget_room(token, room_id).status == 200

      # Fresh full sync (no since token) — a brand-new query against PostgreSQL.
      body = sync(token)
      refute room_in_sync?(body, room_id),
             "forgotten room must not appear in any section of initial sync"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC4 — excluded from incremental /sync (the recently-left re-surfacing path)
  #
  # NOTE on sections: the current HTTP sync renderer (Nebu.Matrix.Http) hardcodes
  # rooms.invite and rooms.leave to {} (a documented deferred gap), so a recently-left
  # room is actually surfaced via the recently-left → fetch_delta_rooms path into
  # rooms.JOIN, not rooms.leave. `room_in_sync?/2` checks join+invite+leave together, so
  # the assertions are correct regardless of which section the room would appear in —
  # the AC is "absent from ANY section", which is what the fix guarantees.
  # ════════════════════════════════════════════════════════════════════════

  describe "AC4 — incremental sync exclusion" do
    test "a forgotten room is absent from every section of an incremental /sync", %{
      token: token
    } do
      room_id = create_room(token, "ac4-incremental")

      # Establish a since token from an initial sync taken WHILE still joined.
      initial = sync(token)
      since = initial["next_batch"]
      assert is_binary(since)

      # Control: a left-but-NOT-yet-forgotten room DOES re-surface in incremental
      # sync (via the recently-left → join-section path) — this proves the test
      # actually exercises the recently-left code path the fix targets, so the AC4
      # assertion below is a real regression check, not a vacuous pass.
      leave_room(token, room_id)
      control = sync(token, "since=#{URI.encode_www_form(since)}&timeout=0")

      assert room_in_sync?(control, room_id),
             "a left (not yet forgotten) room must appear in incremental sync — " <>
               "if it does not, AC4's exclusion assertion would pass vacuously"

      # Now forget it and re-issue the SAME incremental sync.
      assert forget_room(token, room_id).status == 200

      # Incremental sync (timeout=0 so it returns immediately, no long-poll).
      body = sync(token, "since=#{URI.encode_www_form(since)}&timeout=0")
      refute room_in_sync?(body, room_id),
             "forgotten room must not re-surface in any section of incremental sync"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC5 — per-user isolation
  # ════════════════════════════════════════════════════════════════════════

  describe "AC5 — per-user isolation" do
    test "A forgetting room R does not exclude R from B's sync", %{
      priv_jwk: priv,
      token: token_a
    } do
      {uid_b, token_b} = bearer_for("mara", priv)
      provision(uid_b, "Mara")

      # A creates R and invites B; B joins so B is a member of R.
      room_id = create_room(token_a, "ac5-shared")

      inv =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{enc(room_id)}/invite",
          %{"user_id" => uid_b},
          auth(token_a)
        )

      assert inv.status == 200, "invite B must succeed"
      assert join_room(token_b, room_id).status == 200, "B must join R"

      # A leaves and forgets R.
      leave_room(token_a, room_id)
      assert forget_room(token_a, room_id).status == 200

      # R must still appear (join) for B — forget is keyed on (user_id, room_id).
      body_b = sync(token_b)
      assert Map.has_key?(body_b["rooms"]["join"] || %{}, room_id),
             "room must still be present (join) for user B after A forgets it"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC6 — re-join clears forget
  # ════════════════════════════════════════════════════════════════════════

  describe "AC6 — re-join clears forget" do
    test "re-joining a forgotten room removes the row and the room reappears in sync", %{
      user_id: uid,
      token: token
    } do
      room_id = create_room(token, "ac6-rejoin")
      leave_room(token, room_id)
      assert forget_room(token, room_id).status == 200
      assert forgotten_row_count(uid, room_id) == 1

      # Re-join the forgotten room.
      assert join_room(token, room_id).status == 200

      # The forgotten_rooms row must be gone …
      assert forgotten_row_count(uid, room_id) == 0,
             "re-joining a forgotten room must remove the forgotten_rooms row"

      # … and the room must reappear in the join section of sync.
      body = sync(token)
      assert Map.has_key?(body["rooms"]["join"] || %{}, room_id),
             "re-joined room must reappear in rooms.join"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC7 — idempotent forget (ON CONFLICT DO NOTHING)
  # ════════════════════════════════════════════════════════════════════════

  describe "AC7 — idempotent forget" do
    test "second forget → 200 {}, still exactly one forgotten_rooms row", %{
      user_id: uid,
      token: token
    } do
      room_id = create_room(token, "ac7-idempotent")
      leave_room(token, room_id)

      assert forget_room(token, room_id).status == 200
      assert forgotten_row_count(uid, room_id) == 1

      conn2 = forget_room(token, room_id)
      assert conn2.status == 200
      assert json(conn2) == %{}
      assert forgotten_row_count(uid, room_id) == 1,
             "repeated forget must not create a duplicate row (ON CONFLICT DO NOTHING)"
    end
  end
end
