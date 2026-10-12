defmodule Nebu.Web.RoomAccountDataTest do
  @moduledoc """
  Acceptance tests (RED phase) for story `room-account-data-and-read-markers`
  (epic matrix-spec-gaps) — AC1-AC5 and AC7 (room-scoped account data).

  Today:
    * `PUT/GET /user/{userId}/rooms/{roomId}/account_data/{type}` do not exist
      (catch-all 404 "Unrecognized request");
    * `rooms.join.<id>.account_data.events` in /sync is always `[]`;
    * global `PUT /user/{userId}/account_data/{type}` accepts `m.fully_read` /
      `m.push_rules` and stores `{}` for a malformed body.

  Contract decisions pinned here (see report): no table name, store function or
  token schema is prescribed. Persistence/cap/erasure are observed via HTTP and
  via a SQL table-discovery (any table with columns user_id, room_id, type).

  Layers: pure-unit (no DB) guards, and `:integration` (real Repo + OTP tree).
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "room-account-data-test-key-1"
  @router_opts Nebu.Web.Router.init([])
  @catch_all %{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"}

  # ── helpers ────────────────────────────────────────────────────────────────

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

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    Map.put(priv_map, "kid", @kid)
  end

  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), %{"alg" => "RS256", "kid" => @kid}, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@" <> sub <> ":" <> @server_name, compact}
  end

  # body: nil | map (JSON-encoded) | {:raw, binary}
  defp call(method, path, body, token) do
    c =
      case body do
        nil -> conn(method, path)
        {:raw, raw} -> conn(method, path, raw) |> put_req_header("content-type", "application/json")
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    c = if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    Nebu.Web.Router.call(c, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp enc(s), do: URI.encode_www_form(s)

  defp room_ad_path(uid, room, type),
    do: "/_matrix/client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/account_data/#{enc(type)}"

  defp global_ad_path(uid, type), do: "/_matrix/client/v3/user/#{enc(uid)}/account_data/#{enc(type)}"

  defp put_room_ad(uid, token, room, type, body), do: call(:put, room_ad_path(uid, room, type), body, token)
  defp get_room_ad(uid, token, room, type), do: call(:get, room_ad_path(uid, room, type), nil, token)
  defp put_global_ad(uid, token, type, body), do: call(:put, global_ad_path(uid, type), body, token)
  defp get_global_ad(uid, token, type), do: call(:get, global_ad_path(uid, type), nil, token)

  defp refute_catch_all(conn) do
    refute json(conn) == @catch_all,
           "route is missing — request fell through to the 404 catch-all (status #{conn.status})"
  end

  defp sync(token, since \\ nil) do
    q = if since, do: "?timeout=0&since=#{enc(since)}", else: ""
    c = call(:get, "/_matrix/client/v3/sync" <> q, nil, token)
    assert c.status == 200, "sync must succeed (got #{c.status}: #{c.resp_body})"
    json(c)
  end

  # room account data of a room in rooms.join, as %{type => content}
  defp room_ad(sync_body, room_id) do
    (get_in(sync_body, ["rooms", "join", room_id, "account_data", "events"]) || [])
    |> Map.new(fn ev -> {ev["type"], ev["content"]} end)
  end

  defp room_ad_events(sync_body, room_id),
    do: get_in(sync_body, ["rooms", "join", room_id, "account_data", "events"]) || []

  defp provision(uid, role) do
    if Process.whereis(Nebu.Repo) do
      _ = Nebu.Matrix.Session.TokenValidator.validate(uid, role, uid, "#{:erlang.unique_integer([:positive])}@example.com")
    end
  end

  defp new_user(priv, prefix, role \\ "user") do
    {uid, token} = bearer_for("#{prefix}-#{:erlang.unique_integer([:positive])}", priv)
    provision(uid, role)
    {uid, token}
  end

  defp create_room(token, name) do
    c = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, token)
    assert c.status == 200, "createRoom must succeed to set up the scenario"
    json(c)["room_id"]
  end

  # SQL discovery: every table that has user_id + room_id + type columns.
  defp room_ad_tables do
    {:ok, %{rows: rows}} =
      Nebu.Repo.query(
        """
        SELECT table_name FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name IN ('user_id','room_id','type')
        GROUP BY table_name HAVING COUNT(DISTINCT column_name) = 3
        """,
        []
      )

    List.flatten(rows)
  end

  # rows (as maps column=>value) of the discovered tables for a user, as [{table, [row]}].
  # NOTE: future tables with a `type` column (e.g. room tags) or a change-log table may
  # also match the discovery; assertions therefore select the table by its content.
  defp stored_rows_by_table(uid) do
    Enum.map(room_ad_tables(), fn table ->
      {:ok, res} = Nebu.Repo.query(~s(SELECT * FROM "#{table}" WHERE user_id = $1), [uid])
      {table, Enum.map(res.rows, fn row -> Enum.zip(res.columns, row) |> Map.new() end)}
    end)
  end

  # all rows of all discovered tables flattened
  defp stored_rows(uid), do: stored_rows_by_table(uid) |> Enum.flat_map(fn {_t, rows} -> rows end)

  # rows of the table(s) that hold the exact verbatim `body` for the user
  defp rows_of_table_holding(uid, body) do
    stored_rows_by_table(uid)
    |> Enum.filter(fn {_t, rows} -> Enum.any?(rows, &(body in Map.values(&1))) end)
    |> Enum.flat_map(fn {_t, rows} -> rows end)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1/AC7 — guards that reject before any DB call (no DB)
  # ══════════════════════════════════════════════════════════════════════════

  # Note: the type/authorization/format checks below must fire BEFORE any room or
  # membership lookup (no DB is touched, and no room existence can leak).
  describe "room account data guards (no DB)" do
    setup do
      priv = setup_oidc_keys()
      {alice, alice_token} = bearer_for("rad-alice", priv)
      {bob, _} = bearer_for("rad-bob", priv)
      {:ok, alice: alice, alice_token: alice_token, bob: bob}
    end

    test "AC1: PUT room account data without Bearer → 401 M_MISSING_TOKEN", %{alice: alice} do
      c = put_room_ad(alice, nil, "!r:test.local", "m.marked_unread", %{"unread" => true})
      assert c.status == 401
      assert json(c)["errcode"] == "M_MISSING_TOKEN"
    end

    test "AC1/AC7: PUT another user's room account data → 403 M_FORBIDDEN", %{bob: bob, alice_token: t} do
      c = put_room_ad(bob, t, "!r:test.local", "m.marked_unread", %{"unread" => true})
      assert c.status == 403, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] == "M_FORBIDDEN"
    end

    test "AC1/AC7: GET another user's room account data → 403 M_FORBIDDEN", %{bob: bob, alice_token: t} do
      c = get_room_ad(bob, t, "!r:test.local", "m.marked_unread")
      assert c.status == 403, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] == "M_FORBIDDEN"
    end

    test "AC1: PUT with syntactically invalid roomId → 400 M_INVALID_PARAM", %{alice: a, alice_token: t} do
      c = put_room_ad(a, t, "not-a-room-id", "m.marked_unread", %{"unread" => true})
      assert c.status == 400, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] == "M_INVALID_PARAM"
    end

    test "AC1: GET with syntactically invalid roomId → 400 M_INVALID_PARAM", %{alice: a, alice_token: t} do
      c = get_room_ad(a, t, "not-a-room-id", "m.marked_unread")
      assert c.status == 400, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] == "M_INVALID_PARAM"
    end

    for type <- ["m.fully_read", "m.push_rules"] do
      test "AC1/AC5: PUT room-scoped #{type} → 405 M_BAD_JSON", %{alice: a, alice_token: t} do
        c = put_room_ad(a, t, "!r:test.local", unquote(type), %{"x" => 1})
        assert c.status == 405, "got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_BAD_JSON"
      end

      test "AC5: PUT global #{type} → 405 M_BAD_JSON", %{alice: a, alice_token: t} do
        c = put_global_ad(a, t, unquote(type), %{"x" => 1})
        assert c.status == 405, "got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_BAD_JSON"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 / AC2 / AC5 / AC7 over HTTP (integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "room account data over HTTP (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rad-http")
      room = create_room(token, "rad-room")
      {:ok, priv: priv, uid: uid, token: token, room: room}
    end

    test "AC1: PUT then GET round-trips m.marked_unread byte-exactly", %{uid: uid, token: t, room: room} do
      body = ~s({"unread":true})
      put = put_room_ad(uid, t, room, "m.marked_unread", {:raw, body})
      assert put.status == 200, "got #{put.status}: #{put.resp_body}"
      assert json(put) == %{}

      get = get_room_ad(uid, t, room, "m.marked_unread")
      assert get.status == 200
      assert get.resp_body == body
    end

    test "AC1: second PUT overwrites; GET returns the latest", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => false}).status == 200
      assert json(get_room_ad(uid, t, room, "m.marked_unread")) == %{"unread" => false}
    end

    test "AC1: GET unknown type in a member room → 404 M_NOT_FOUND (wired route)", %{uid: uid, token: t, room: room} do
      c = get_room_ad(uid, t, room, "m.never.stored")
      assert c.status == 404
      refute_catch_all(c)
      assert json(c)["errcode"] == "M_NOT_FOUND"
    end

    test "AC1: no fallback — a GLOBAL value of the same type is not returned for a room", %{uid: uid, token: t, room: room} do
      assert put_global_ad(uid, t, "m.marked_unread", %{"unread" => true}).status == 200
      c = get_room_ad(uid, t, room, "m.marked_unread")
      assert c.status == 404
      refute_catch_all(c)
      assert json(c)["errcode"] == "M_NOT_FOUND"
    end

    test "AC1: a room value does not leak into the global scope", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      assert get_global_ad(uid, t, "m.marked_unread").status == 404
    end

    test "AC1: isolation — another room of the same user does not see the value", %{uid: uid, token: t, room: room} do
      other = create_room(t, "rad-room-2")
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      c = get_room_ad(uid, t, other, "m.marked_unread")
      assert c.status == 404
      refute_catch_all(c)
    end

    test "AC1: isolation — another user's same room/type is independent", %{priv: priv, uid: uid, token: t, room: room} do
      {bob, bob_token} = new_user(priv, "rad-bob")
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      # bob has no value for this (and is not a member): must not see alice's data
      c = get_room_ad(bob, bob_token, room, "m.marked_unread")
      assert c.status in [403, 404]
      refute_catch_all(c)
      refute c.status == 200
    end

    test "AC1: body that is not a JSON object (array) → 400 M_NOT_JSON/M_BAD_JSON, nothing stored",
         %{uid: uid, token: t, room: room} do
      c = put_room_ad(uid, t, room, "m.marked_unread", {:raw, "[1,2,3]"})
      assert c.status == 400, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] in ["M_NOT_JSON", "M_BAD_JSON"]
      assert get_room_ad(uid, t, room, "m.marked_unread").status == 404
    end

    test "AC1: malformed JSON → 400 M_NOT_JSON/M_BAD_JSON, nothing stored", %{uid: uid, token: t, room: room} do
      c = put_room_ad(uid, t, room, "m.marked_unread", {:raw, "{not json"})
      assert c.status == 400, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] in ["M_NOT_JSON", "M_BAD_JSON"]
      assert get_room_ad(uid, t, room, "m.marked_unread").status == 404
    end

    test "AC1/AC7: non-member room and unknown room give the SAME response (no existence leak)",
         %{priv: priv, room: room} do
      {mallory, mtoken} = new_user(priv, "rad-mallory")
      unknown = "!does-not-exist-#{:erlang.unique_integer([:positive])}:test.local"

      put_member_room = put_room_ad(mallory, mtoken, room, "m.marked_unread", %{"unread" => true})
      put_unknown = put_room_ad(mallory, mtoken, unknown, "m.marked_unread", %{"unread" => true})
      refute_catch_all(put_member_room)
      refute_catch_all(put_unknown)
      assert {put_member_room.status, json(put_member_room)["errcode"]} ==
               {put_unknown.status, json(put_unknown)["errcode"]}

      get_member_room = get_room_ad(mallory, mtoken, room, "m.marked_unread")
      get_unknown = get_room_ad(mallory, mtoken, unknown, "m.marked_unread")
      refute_catch_all(get_member_room)
      assert {get_member_room.status, json(get_member_room)["errcode"]} ==
               {get_unknown.status, json(get_unknown)["errcode"]}
    end

    test "AC7: a non-member's write never becomes visible to the room owner", %{priv: priv, uid: uid, token: t, room: room} do
      {mallory, mtoken} = new_user(priv, "rad-mallory")
      _ = put_room_ad(mallory, mtoken, room, "m.marked_unread", %{"unread" => true})
      c = get_room_ad(uid, t, room, "m.marked_unread")
      assert c.status == 404
      refute_catch_all(c)
    end

    test "AC7: instance_admin cannot read or write another user's room account data → 403", %{priv: priv, uid: uid, room: room} do
      {_admin, admin_token} = new_user(priv, "rad-admin", "instance_admin")
      assert put_room_ad(uid, admin_token, room, "m.marked_unread", %{"unread" => true}).status == 403
      assert get_room_ad(uid, admin_token, room, "m.marked_unread").status == 403
    end

    test "AC1: oversized body → 413 M_TOO_LARGE, nothing stored", %{uid: uid, token: t, room: room} do
      big = Jason.encode!(%{"blob" => String.duplicate("a", 2 * 1024 * 1024)})
      c = put_room_ad(uid, t, room, "m.big", {:raw, big})
      assert c.status == 413, "got #{c.status}: #{String.slice(c.resp_body, 0, 200)}"
      assert json(c)["errcode"] == "M_TOO_LARGE"
      assert get_room_ad(uid, t, room, "m.big").status == 404
    end

    test "AC1: GET m.fully_read / m.push_rules is not rejected (reads are allowed; 404 when unset)",
         %{uid: uid, token: t, room: room} do
      for type <- ["m.fully_read", "m.push_rules"] do
        c = get_room_ad(uid, t, room, type)
        assert c.status == 404, "got #{c.status}: #{c.resp_body}"
        refute_catch_all(c)
        assert json(c)["errcode"] == "M_NOT_FOUND"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — global scope (integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "global account data PUT hardening (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rad-global")
      {:ok, uid: uid, token: token}
    end

    test "AC5: malformed JSON → 400 M_NOT_JSON and NOT stored as {}", %{uid: uid, token: t} do
      c = put_global_ad(uid, t, "m.test.malformed", {:raw, "{broken"})
      assert c.status == 400, "got #{c.status}: #{c.resp_body}"
      assert json(c)["errcode"] == "M_NOT_JSON"
      assert get_global_ad(uid, t, "m.test.malformed").status == 404
    end

    test "AC5/AC8: m.fully_read / m.push_rules rejected globally, nothing stored", %{uid: uid, token: t} do
      for type <- ["m.fully_read", "m.push_rules"] do
        c = put_global_ad(uid, t, type, %{"x" => 1})
        assert c.status == 405, "#{type}: got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_BAD_JSON"
        refute get_global_ad(uid, t, type).status == 200
      end
    end

    test "AC5: reading m.fully_read / m.push_rules globally is not rejected", %{uid: uid, token: t} do
      for type <- ["m.fully_read", "m.push_rules"] do
        c = get_global_ad(uid, t, type)
        assert c.status == 404
        assert json(c)["errcode"] == "M_NOT_FOUND"
      end
    end

    test "AC8: other global types still work", %{uid: uid, token: t} do
      for type <- ["m.secret_storage.default_key", "m.cross_signing.master", "im.vector.setting.x"] do
        assert put_global_ad(uid, t, type, %{"v" => 1}).status == 200
        assert json(get_global_ad(uid, t, type)) == %{"v" => 1}
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — persistence, cap (integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "durability and caps (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rad-dur")
      room = create_room(token, "rad-dur-room")
      {:ok, uid: uid, token: token, room: room}
    end

    test "AC2: the value is persisted in PostgreSQL (a table keyed user_id/room_id/type holds it verbatim)",
         %{uid: uid, token: t, room: room} do
      assert room_ad_tables() != [],
             "no PostgreSQL table with columns user_id, room_id, type exists (migration missing)"

      body = ~s({"unread":true})
      assert put_room_ad(uid, t, room, "m.marked_unread", {:raw, body}).status == 200

      rows = rows_of_table_holding(uid, body)
      assert length(rows) == 1, "expected exactly one row holding the verbatim body, got #{inspect(stored_rows(uid))}"
      [row] = rows
      assert row["room_id"] == room
      assert row["type"] == "m.marked_unread"
      assert body in Map.values(row), "content must be stored verbatim as TEXT, row: #{inspect(row)}"
    end

    test "AC2: PUT of the same (user, room, type) upserts a single row", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => false}).status == 200
      body = ~s({"unread":false})
      assert length(rows_of_table_holding(uid, body)) == 1
    end

    test "AC2: read from a fresh process after the PUT still returns the data (no per-request/ETS state)",
         %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200

      get =
        Task.async(fn -> get_room_ad(uid, t, room, "m.marked_unread") end)
        |> Task.await(10_000)

      assert get.status == 200
      assert json(get) == %{"unread" => true}
    end

    @tag timeout: 300_000
    test "AC2: per-user cap — row creation is eventually refused; overwriting existing rows still works",
         %{uid: uid, token: t, room: room} do
      max = 5_000

      # The per-user write rate limit (60/min, burst 30) would throttle this bulk loop.
      prev = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:nebu_http, :rate_limit_disabled),
          else: Application.put_env(:nebu_http, :rate_limit_disabled, prev)
      end)

      results =
        Enum.reduce_while(1..max, [], fn i, acc ->
          c = put_room_ad(uid, t, room, "m.cap.t#{i}", %{"i" => i})

          if c.status == 200 do
            {:cont, acc}
          else
            {:halt, [{i, c} | acc]}
          end
        end)

      assert [{i, refused} | _] = results,
             "no per-user cap enforced after #{max} room-account-data rows"

      assert i > 1, "cap must allow at least one row"
      assert refused.status in [400, 403, 413, 429, 507], "got #{refused.status}: #{refused.resp_body}"
      assert json(refused)["errcode"] in ["M_LIMIT_EXCEEDED", "M_RESOURCE_LIMIT_EXCEEDED", "M_TOO_LARGE", "M_FORBIDDEN"]

      # existing row can still be overwritten at the cap
      assert put_room_ad(uid, t, room, "m.cap.t1", %{"i" => "again"}).status == 200
      assert json(get_room_ad(uid, t, room, "m.cap.t1")) == %{"i" => "again"}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 / AC4 — /sync delivery (integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "/sync delivery of room account data (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rad-sync")
      room = create_room(token, "rad-sync-room")
      {:ok, priv: priv, uid: uid, token: token, room: room}
    end

    test "AC3: initial sync delivers all room account data in rooms.join.<id>.account_data.events",
         %{uid: uid, token: t, room: room} do
      other = create_room(t, "rad-sync-room-2")
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      assert put_room_ad(uid, t, room, "im.vector.custom", %{"a" => [1, 2]}).status == 200

      body = sync(t)
      assert room_ad(body, room) == %{"m.marked_unread" => %{"unread" => true}, "im.vector.custom" => %{"a" => [1, 2]}}
      assert room_ad_events(body, other) == []
      assert Enum.all?(room_ad_events(body, room), &(Map.keys(&1) |> Enum.sort() == ["content", "type"]))
    end

    test "AC3: room data is not delivered into a room the user is not in", %{priv: priv, uid: uid, token: t, room: room} do
      {mallory, mtoken} = new_user(priv, "rad-sync-mallory")
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      _ = put_room_ad(mallory, mtoken, room, "m.marked_unread", %{"unread" => true})
      body = sync(mtoken)
      refute Map.has_key?(get_in(body, ["rooms", "join"]) || %{}, room)
    end

    test "AC4: incremental sync returns ONLY room account data changed after since", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.old", %{"old" => true}).status == 200
      first = sync(t)
      assert room_ad(first, room)["m.old"] == %{"old" => true}

      assert put_room_ad(uid, t, room, "m.new", %{"new" => true}).status == 200
      inc = sync(t, first["next_batch"])
      ad = room_ad(inc, room)
      assert ad["m.new"] == %{"new" => true}
      refute Map.has_key?(ad, "m.old"), "unchanged data must not be re-delivered, got #{inspect(Map.keys(ad))}"
    end

    test "AC4: overwriting an existing type after since is delivered with the new content", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      first = sync(t)
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => false}).status == 200
      assert room_ad(sync(t, first["next_batch"]), room) == %{"m.marked_unread" => %{"unread" => false}}
    end

    test "AC4: a room whose ONLY change is account data appears in rooms.join", %{uid: uid, token: t, room: room} do
      first = sync(t)
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200

      inc = sync(t, first["next_batch"])
      joined = get_in(inc, ["rooms", "join"]) || %{}
      assert Map.has_key?(joined, room), "room with only an account-data change must be in rooms.join"
      assert room_ad(inc, room) == %{"m.marked_unread" => %{"unread" => true}}
      assert (get_in(joined, [room, "timeline", "events"]) || []) == []
    end

    test "AC4: nothing changed → room is not re-delivered with account data", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200
      first = sync(t)
      second = sync(t, first["next_batch"])
      assert room_ad(second, room) == %{}
    end

    test "AC4: TWO DEVICES — both since tokens receive the change, each exactly once", %{uid: uid, token: t, room: room} do
      # Two devices of the same user: each holds its own since token from its own initial sync.
      since_a = sync(t)["next_batch"]
      since_b = sync(t)["next_batch"]

      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200

      # device A syncs first ...
      a1 = sync(t, since_a)
      assert room_ad(a1, room) == %{"m.marked_unread" => %{"unread" => true}}

      # ... and must NOT make device B miss the change
      b1 = sync(t, since_b)
      assert room_ad(b1, room) == %{"m.marked_unread" => %{"unread" => true}},
             "device B missed the change after device A consumed it (per-user consume-once flag)"

      # exactly once per device: the follow-up syncs with the new next_batch are empty
      assert room_ad(sync(t, a1["next_batch"]), room) == %{}
      assert room_ad(sync(t, b1["next_batch"]), room) == %{}
    end

    test "AC4: TWO DEVICES — the change is also delivered to a stale token after another device advanced",
         %{uid: uid, token: t, room: room} do
      since_a = sync(t)["next_batch"]
      since_b = sync(t)["next_batch"]
      assert put_room_ad(uid, t, room, "m.marked_unread", %{"unread" => true}).status == 200

      a1 = sync(t, since_a)
      _a2 = sync(t, a1["next_batch"])
      # a later change must be delivered to B together with the earlier one
      assert put_room_ad(uid, t, room, "m.other", %{"o" => 1}).status == 200
      b1 = sync(t, since_b)

      assert room_ad(b1, room) == %{"m.marked_unread" => %{"unread" => true}, "m.other" => %{"o" => 1}}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7 — GDPR erasure removes (deactivation is reversible and keeps the data) room account data (integration)
  # ══════════════════════════════════════════════════════════════════════════

  describe "erasure and deactivation (integration)" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {uid, token} = new_user(priv, "rad-erase")
      room = create_room(token, "rad-erase-room")
      assert put_room_ad(uid, token, room, "m.marked_unread", %{"unread" => true}).status == 200
      assert stored_rows(uid) != [], "precondition: row stored (store missing?)"
      {:ok, uid: uid, token: token, room: room}
    end

    test "AC7: GDPR erasure (UserDeletion.delete_user_keys) removes the user's room account data", %{uid: uid} do
      assert {:ok, _} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:test.local", uid, "gdpr request")
      assert stored_rows(uid) == []
    end
  end
end
