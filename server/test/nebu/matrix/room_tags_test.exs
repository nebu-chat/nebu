defmodule Nebu.Web.RoomTagsTest do
  @moduledoc """
  Acceptance tests (RED phase) for story `room-tags` (epic matrix-spec-gaps), AC1-AC6.

  Today `GET/PUT/DELETE /user/{userId}/rooms/{roomId}/tags[/{tag}]` do not exist
  (catch-all 404 `M_NOT_FOUND` "Unrecognized request").

  Contract decisions pinned here (no table/function names are prescribed; persistence is
  observed over HTTP and via a SQL table discovery, columns user_id/room_id/type):

    * tags are stored in the room account data event `m.tag` (`{"tags": {...}}`);
    * tag names are limited to 255 BYTES after URL-decoding (not characters);
    * oversize body -> 413 `M_TOO_LARGE`; cap -> 403 `M_RESOURCE_LIMIT_EXCEEDED`;
    * the request logger never captures tag bodies (orders / extra fields); the tag NAME is
      part of the request path, which the generic request logger prints for every route
      (like `m.v.log1` in the room_account_data hardening test) and is therefore not asserted.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @moduletag :integration

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "room-tags-test-key-1"
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

  defp call_raw(method, path, raw, content_type, token) do
    c = conn(method, path, raw)
    c = if content_type, do: put_req_header(c, "content-type", content_type), else: c
    c = if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    Nebu.Web.Router.call(c, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp enc(s), do: URI.encode_www_form(s)
  # path-segment encoding (space -> %20, "/" -> %2F)
  defp seg(s), do: URI.encode(s, &URI.char_unreserved?/1)

  defp user_path(uid), do: "/_matrix/client/v3/user/#{enc(uid)}"
  defp tags_path(uid, room), do: "#{user_path(uid)}/rooms/#{enc(room)}/tags"
  defp tag_path(uid, room, name), do: tags_path(uid, room) <> "/" <> seg(name)
  defp room_ad_path(uid, room, type), do: "#{user_path(uid)}/rooms/#{enc(room)}/account_data/#{enc(type)}"

  defp get_tags(uid, t, room), do: call(:get, tags_path(uid, room), nil, t)
  defp put_tag(uid, t, room, name, body), do: call(:put, tag_path(uid, room, name), body, t)
  defp del_tag(uid, t, room, name), do: call(:delete, tag_path(uid, room, name), nil, t)
  defp put_room_ad(uid, t, room, type, body), do: call(:put, room_ad_path(uid, room, type), body, t)
  defp get_room_ad(uid, t, room, type), do: call(:get, room_ad_path(uid, room, type), nil, t)

  defp tags_of(uid, t, room) do
    c = get_tags(uid, t, room)
    assert c.status == 200, "GET tags: got #{c.status}: #{c.resp_body}"
    json(c)["tags"]
  end

  defp refute_catch_all(conn) do
    refute json(conn) == @catch_all,
           "route is missing — request fell through to the 404 catch-all (status #{conn.status})"
  end

  defp assert_error(conn, status, errcode) do
    assert conn.status == status, "expected #{status} #{errcode}, got #{conn.status}: #{conn.resp_body}"
    assert json(conn)["errcode"] == errcode
  end

  defp sync(token, since \\ nil) do
    q = if since, do: "?timeout=0&since=#{enc(since)}", else: "?timeout=0"
    c = call(:get, "/_matrix/client/v3/sync" <> q, nil, token)
    assert c.status == 200, "sync must succeed (got #{c.status}: #{c.resp_body})"
    json(c)
  end

  defp tag_events(sync_body, room) do
    (get_in(sync_body, ["rooms", "join", room, "account_data", "events"]) || [])
    |> Enum.filter(&(&1["type"] == "m.tag"))
  end

  defp new_user(priv, prefix, role \\ "user") do
    {uid, token} = bearer_for("#{prefix}-#{:erlang.unique_integer([:positive])}", priv)

    _ =
      Nebu.Matrix.Session.TokenValidator.validate(
        uid,
        role,
        uid,
        "#{:erlang.unique_integer([:positive])}@example.com"
      )

    {uid, token}
  end

  defp create_room(token, name) do
    c = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, token)
    assert c.status == 200, "createRoom must succeed to set up the scenario"
    json(c)["room_id"]
  end

  defp put_env_restoring(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp disable_rate_limit do
    put_env_restoring(:nebu_http, :rate_limit_disabled, true)
  end

  # Enable the real limiter: neutralize the harness OS env var (restored in on_exit).
  defp enable_rate_limit do
    prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
    System.delete_env("NEBU_RATE_LIMIT_DISABLED")

    ExUnit.Callbacks.on_exit(fn ->
      if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env)
    end)

    put_env_restoring(:nebu_http, :rate_limit_clock_fn, fn -> 5_000_000 end)
    put_env_restoring(:nebu_http, :rate_limit_disabled, false)
  end

  defp with_log_level(level, fun) do
    original = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original)
    end
  end

  # SQL discovery: tables with user_id + room_id + type columns.
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

  defp stored_rows_by_table(uid) do
    Enum.map(room_ad_tables(), fn table ->
      {:ok, res} = Nebu.Repo.query(~s(SELECT * FROM "#{table}" WHERE user_id = $1), [uid])
      {table, Enum.map(res.rows, fn row -> Enum.zip(res.columns, row) |> Map.new() end)}
    end)
  end

  defp stored_rows(uid), do: stored_rows_by_table(uid) |> Enum.flat_map(fn {_t, rows} -> rows end)

  defp capped_row_count(uid) do
    {:ok, %{rows: [[n]]}} =
      Nebu.Repo.query(
        "SELECT count(*) FROM user_room_account_data WHERE user_id = $1 AND type <> 'm.fully_read'",
        [uid]
      )

    n
  end

  # Deterministic wait point for the long-poll tests: `notify_sync` sends to the members of the
  # `:pg` group "user:<id>", which the long-polling /sync joins. Wait (bounded) until the member
  # count exceeds the count taken before the poll was started.
  defp pg_members(uid), do: length(:pg.get_members("user:#{uid}"))

  defp await_poller(uid, members_before, tries \\ 200) do
    cond do
      pg_members(uid) > members_before ->
        :ok

      tries == 0 ->
        flunk("the long-poll /sync never subscribed to the user's :pg group")

      true ->
        Process.sleep(25)
        await_poller(uid, members_before, tries - 1)
    end
  end

  setup do
    priv = setup_oidc_keys()
    {uid, token} = new_user(priv, "tags")
    room = create_room(token, "tags-room")
    {:ok, priv: priv, uid: uid, token: token, room: room}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — endpoints and shapes
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1 endpoints and shapes" do
    test "GET with nothing stored → 200 {\"tags\":{}} (never 404)", %{uid: uid, token: t, room: room} do
      c = get_tags(uid, t, room)
      refute_catch_all(c)
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"
      assert json(c) == %{"tags" => %{}}
    end

    test "PUT m.favourite then GET → 200 {} and the tag round-trips", %{uid: uid, token: t, room: room} do
      put = put_tag(uid, t, room, "m.favourite", %{"order" => 0.25})
      refute_catch_all(put)
      assert put.status == 200, "got #{put.status}: #{put.resp_body}"
      assert json(put) == %{}

      assert json(get_tags(uid, t, room)) == %{"tags" => %{"m.favourite" => %{"order" => 0.25}}}
    end

    test "order 0.25 round-trips numerically equal; integer orders stay numeric", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert put_tag(uid, t, room, "u.zero", %{"order" => 0}).status == 200
      assert put_tag(uid, t, room, "u.one", %{"order" => 1}).status == 200

      tags = tags_of(uid, t, room)
      assert tags["m.favourite"]["order"] == 0.25
      assert is_number(tags["u.zero"]["order"]) and tags["u.zero"]["order"] == 0
      assert is_number(tags["u.one"]["order"]) and tags["u.one"]["order"] == 1
    end

    test "PUT with {} body is allowed; two tags coexist", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert put_tag(uid, t, room, "u.work", %{}).status == 200

      assert tags_of(uid, t, room) == %{"m.favourite" => %{"order" => 0.25}, "u.work" => %{}}
    end

    test "PUT overwrites the tag object (no merge into the old tag object); other tags untouched",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25, "old" => true}).status == 200
      assert put_tag(uid, t, room, "u.other", %{"order" => 0.9}).status == 200
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.5}).status == 200

      assert tags_of(uid, t, room) == %{"m.favourite" => %{"order" => 0.5}, "u.other" => %{"order" => 0.9}}
    end

    test "other fields in the tag body are preserved verbatim", %{uid: uid, token: t, room: room} do
      body = %{"order" => 0.5, "x.custom" => %{"y" => [1, 2, %{"z" => nil}]}, "label" => "é ü 日本"}
      assert put_tag(uid, t, room, "u.rich", body).status == 200
      assert tags_of(uid, t, room)["u.rich"] == body
    end

    test "DELETE removes only that tag → 200 {}", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert put_tag(uid, t, room, "u.work", %{}).status == 200

      del = del_tag(uid, t, room, "u.work")
      refute_catch_all(del)
      assert del.status == 200, "got #{del.status}: #{del.resp_body}"
      assert json(del) == %{}
      assert tags_of(uid, t, room) == %{"m.favourite" => %{"order" => 0.25}}
    end

    test "DELETE of an unknown tag is idempotent → 200 {} (also on a room with no m.tag at all)",
         %{uid: uid, token: t, room: room} do
      c = del_tag(uid, t, room, "u.never.set")
      refute_catch_all(c)
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"
      assert json(c) == %{}

      assert put_tag(uid, t, room, "m.favourite", %{}).status == 200
      assert del_tag(uid, t, room, "u.never.set").status == 200
      assert del_tag(uid, t, room, "m.favourite").status == 200
      assert del_tag(uid, t, room, "m.favourite").status == 200
    end

    test "DELETE of the last tag leaves {\"tags\":{}} (GET and account_data/m.tag) and an m.tag sync event",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      first = sync(t)
      assert [%{"content" => %{"tags" => %{"m.favourite" => _}}}] = tag_events(first, room)

      assert del_tag(uid, t, room, "m.favourite").status == 200
      assert json(get_tags(uid, t, room)) == %{"tags" => %{}}

      c = get_room_ad(uid, t, room, "m.tag")
      assert c.status == 200, "m.tag must still exist as {\"tags\":{}}, got #{c.status}: #{c.resp_body}"
      assert json(c) == %{"tags" => %{}}

      inc = sync(t, first["next_batch"])
      assert [%{"content" => %{"tags" => tags}}] = tag_events(inc, room)
      assert tags == %{}
    end

    test "tags are per room and per user", %{priv: priv, uid: uid, token: t, room: room} do
      other = create_room(t, "tags-room-2")
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.1}).status == 200
      assert tags_of(uid, t, other) == %{}

      {bob, bob_t} = new_user(priv, "tags-bob")
      assert tags_of(bob, bob_t, create_room(bob_t, "bob-room")) == %{}
    end

    test "persistence: exactly ONE m.tag row for the room holds all tags (no row per tag)",
         %{uid: uid, token: t, room: room} do
      for n <- ["m.favourite", "u.a", "u.b"], do: assert(put_tag(uid, t, room, n, %{}).status == 200)

      per_table =
        stored_rows_by_table(uid)
        |> Enum.map(fn {_tbl, rows} ->
          Enum.count(rows, &(&1["type"] == "m.tag" and &1["room_id"] == room))
        end)

      assert Enum.max(per_table, fn -> 0 end) == 1, "expected exactly one m.tag row, got #{inspect(per_table)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — validation / error matrix
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2 auth / authorization / ids" do
    test "no Bearer → 401 M_MISSING_TOKEN on all three methods", %{uid: uid, room: room} do
      for c <- [
            call(:get, tags_path(uid, room), nil, nil),
            call(:put, tag_path(uid, room, "m.favourite"), %{}, nil),
            call(:delete, tag_path(uid, room, "m.favourite"), nil, nil)
          ] do
        assert_error(c, 401, "M_MISSING_TOKEN")
      end
    end

    test "an invalid bearer token → 401 M_UNKNOWN_TOKEN on all three methods", %{uid: uid, room: room} do
      for c <- [
            call(:get, tags_path(uid, room), nil, "not-a-valid-token"),
            call(:put, tag_path(uid, room, "m.favourite"), %{}, "not-a-valid-token"),
            call(:delete, tag_path(uid, room, "m.favourite"), nil, "not-a-valid-token")
          ] do
        assert_error(c, 401, "M_UNKNOWN_TOKEN")
      end
    end

    test "another user's tags → 403 M_FORBIDDEN on all three methods", %{priv: priv, token: t, room: room} do
      {bob, _} = new_user(priv, "tags-bob")

      for c <- [
            get_tags(bob, t, room),
            put_tag(bob, t, room, "m.favourite", %{}),
            del_tag(bob, t, room, "m.favourite")
          ] do
        assert_error(c, 403, "M_FORBIDDEN")
      end
    end

    test "an admin may not touch another user's tags either → 403 M_FORBIDDEN", %{priv: priv, uid: uid, room: room} do
      {_admin, admin_t} = new_user(priv, "tags-admin", "instance_admin")

      for c <- [
            get_tags(uid, admin_t, room),
            put_tag(uid, admin_t, room, "m.favourite", %{}),
            del_tag(uid, admin_t, room, "m.favourite")
          ] do
        assert_error(c, 403, "M_FORBIDDEN")
      end
    end

    test "syntactically invalid roomId → 400 M_INVALID_PARAM on all three methods", %{uid: uid, token: t} do
      for c <- [
            get_tags(uid, t, "not-a-room-id"),
            put_tag(uid, t, "not-a-room-id", "m.favourite", %{}),
            del_tag(uid, t, "not-a-room-id", "m.favourite")
          ] do
        assert_error(c, 400, "M_INVALID_PARAM")
      end
    end

    test "non-member and unknown room answer identically with 403 M_FORBIDDEN (no existence leak)",
         %{priv: priv, room: room} do
      {mallory, mt} = new_user(priv, "tags-mallory")
      unknown = "!does-not-exist-#{:erlang.unique_integer([:positive])}:test.local"

      for fun <- [
            fn r -> get_tags(mallory, mt, r) end,
            fn r -> put_tag(mallory, mt, r, "m.favourite", %{"order" => 0.5}) end,
            fn r -> del_tag(mallory, mt, r, "m.favourite") end
          ] do
        member_room = fun.(room)
        unknown_room = fun.(unknown)
        assert_error(member_room, 403, "M_FORBIDDEN")
        assert_error(unknown_room, 403, "M_FORBIDDEN")
        assert json(member_room) == json(unknown_room)
      end
    end

    test "a non-member PUT stores nothing (sync of the member shows no tag)", %{priv: priv, uid: uid, token: t, room: room} do
      {mallory, mt} = new_user(priv, "tags-mallory")
      assert put_tag(mallory, mt, room, "m.favourite", %{}).status == 403
      assert tags_of(uid, t, room) == %{}
      assert stored_rows(mallory) == []
    end
  end

  # Nebu decision, not in spec: the spec only limits the name to 255 bytes; empty names, UTF-8/NUL
  # validity and the 400 M_INVALID_PARAM code are Nebu choices.
  describe "AC2 tag name validation" do
    test "255 ASCII bytes OK, 256 → 400 M_INVALID_PARAM", %{uid: uid, token: t, room: room} do
      ok = String.duplicate("a", 255)
      assert put_tag(uid, t, room, ok, %{}).status == 200
      assert Map.has_key?(tags_of(uid, t, room), ok)
      assert del_tag(uid, t, room, ok).status == 200

      too_long = String.duplicate("a", 256)
      assert_error(put_tag(uid, t, room, too_long, %{}), 400, "M_INVALID_PARAM")
      assert_error(del_tag(uid, t, room, too_long), 400, "M_INVALID_PARAM")
      assert tags_of(uid, t, room) == %{}
    end

    test "multibyte names are measured in BYTES after URL-decoding (2/3/4-byte chars)", %{uid: uid, token: t, room: room} do
      # 2-byte "ä": 127 chars = 254 B ok; 127 + "a" = 255 B ok; 128 chars = 256 B too long
      two_ok = String.duplicate("ä", 127)
      two_255 = two_ok <> "a"
      two_256 = String.duplicate("ä", 128)
      # 3-byte "日": 85 chars = 255 B ok; 86 = 258 B too long; 85 + "a" = 256 B too long
      three_255 = String.duplicate("日", 85)
      three_256 = three_255 <> "a"
      # 4-byte emoji: 63 = 252 B ok; 64 = 256 B too long
      four_ok = String.duplicate("😀", 63)
      four_256 = String.duplicate("😀", 64)

      for name <- [two_ok, two_255, three_255, four_ok] do
        c = put_tag(uid, t, room, name, %{})
        assert c.status == 200, "#{byte_size(name)} bytes must be accepted, got #{c.status}: #{c.resp_body}"
        assert Map.has_key?(tags_of(uid, t, room), name)
      end

      for name <- [two_256, three_256, String.duplicate("日", 86), four_256] do
        assert_error(put_tag(uid, t, room, name, %{}), 400, "M_INVALID_PARAM")
      end

      refute Enum.any?(Map.keys(tags_of(uid, t, room)), &(byte_size(&1) > 255))
    end

    test "empty tag name (route shape tags/ and tags//) → 400 M_INVALID_PARAM", %{uid: uid, token: t, room: room} do
      base = tags_path(uid, room)

      for {method, body} <- [{:put, %{}}, {:delete, nil}], path <- [base <> "/", base <> "//"] do
        c = call(method, path, body, t)
        assert_error(c, 400, "M_INVALID_PARAM")
      end

      assert tags_of(uid, t, room) == %{}
    end

    test "an encoded empty-ish name (%20-only is a real name, not empty)", %{uid: uid, token: t, room: room} do
      # a single space is a legal 1-byte name per spec (no namespace rules)
      assert put_tag(uid, t, room, " ", %{}).status == 200
      assert Map.has_key?(tags_of(uid, t, room), " ")
    end

    test "%2F in the name is handled consistently: never 500/404-catch-all, no phantom tag",
         %{uid: uid, token: t, room: room} do
      path = tags_path(uid, room) <> "/u.a%2Fb"
      c = call(:put, path, %{}, t)
      refute_catch_all(c)
      assert c.status in [200, 400], "got #{c.status}: #{c.resp_body}"

      case c.status do
        200 ->
          assert Map.keys(tags_of(uid, t, room)) == ["u.a/b"]
          assert call(:delete, path, nil, t).status == 200
          assert tags_of(uid, t, room) == %{}

        400 ->
          assert json(c)["errcode"] == "M_INVALID_PARAM"
          assert tags_of(uid, t, room) == %{}
      end
    end

    test "invalid UTF-8 (%FF) and NUL (%00) in the name → 400 M_INVALID_PARAM, never 500, nothing stored",
         %{uid: uid, token: t, room: room} do
      for name <- ["u.bad%FFx", "%FF", "u.nul%00x", "%00"] do
        path = tags_path(uid, room) <> "/" <> name
        assert_error(call(:put, path, %{}, t), 400, "M_INVALID_PARAM")
        assert_error(call(:delete, path, nil, t), 400, "M_INVALID_PARAM")
      end

      assert tags_of(uid, t, room) == %{}
      assert Enum.all?(stored_rows(uid), &(not (&1["type"] == "m.tag" and &1["room_id"] == room)))
    end

    test "percent-encoded name is decoded before storing (u.caf%C3%A9 → \"u.café\")", %{uid: uid, token: t, room: room} do
      c = call(:put, tags_path(uid, room) <> "/u.caf%C3%A9", %{"order" => 0.3}, t)
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"
      assert tags_of(uid, t, room) == %{"u.café" => %{"order" => 0.3}}
      assert call(:delete, tags_path(uid, room) <> "/u.caf%C3%A9", nil, t).status == 200
      assert tags_of(uid, t, room) == %{}
    end
  end

  # Nebu decision, not in spec: the error codes (M_NOT_JSON / M_BAD_JSON) mirror room account data.
  describe "AC2 body validation" do
    test "PUT body not a JSON object → 400 M_NOT_JSON, nothing stored", %{uid: uid, token: t, room: room} do
      for raw <- ["[1,2,3]", ~s("str"), "5", "true", "null", "{not json", "", "not json at all"] do
        c = call(:put, tag_path(uid, room, "m.favourite"), {:raw, raw}, t)
        assert_error(c, 400, "M_NOT_JSON")
      end

      assert tags_of(uid, t, room) == %{}
    end

    test "PUT with non-JSON content type → 400 M_NOT_JSON", %{uid: uid, token: t, room: room} do
      path = tag_path(uid, room, "m.favourite")

      for {raw, ct} <- [{~s({"order":0.5}), "text/plain"}, {~s({"order":0.5}), nil}, {"order=0.5", "application/x-www-form-urlencoded"}] do
        assert_error(call_raw(:put, path, raw, ct, t), 400, "M_NOT_JSON")
      end

      assert tags_of(uid, t, room) == %{}
    end

    test "order present but not a JSON number → 400 M_BAD_JSON, old tag kept", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200

      for bad <- ["0.5", nil, true, false, [0.5], %{"a" => 1}] do
        c = put_tag(uid, t, room, "m.favourite", %{"order" => bad})
        assert_error(c, 400, "M_BAD_JSON")
      end

      assert tags_of(uid, t, room) == %{"m.favourite" => %{"order" => 0.25}}
    end

    test "order outside [0,1] is accepted and round-trips", %{uid: uid, token: t, room: room} do
      for {name, order} <- [{"u.neg", -1}, {"u.big", 2}, {"u.huge", 1.5e10}, {"u.negf", -0.5}] do
        c = put_tag(uid, t, room, name, %{"order" => order})
        assert c.status == 200, "#{name}: got #{c.status}: #{c.resp_body}"
      end

      tags = tags_of(uid, t, room)
      assert tags["u.neg"]["order"] == -1
      assert tags["u.big"]["order"] == 2
      assert tags["u.huge"]["order"] == 1.5e10
      assert tags["u.negf"]["order"] == -0.5
    end

    test "unknown/extra fields without order are fine", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "u.x", %{"foo" => "bar"}).status == 200
      assert tags_of(uid, t, room) == %{"u.x" => %{"foo" => "bar"}}
    end
  end

  # Nebu decision, not in spec: 413 / caps are inherited from room account data.
  describe "AC2 size limits" do
    test "PUT body above the account-data body cap (64 KiB) → 413 M_TOO_LARGE, nothing stored",
         %{uid: uid, token: t, room: room} do
      big = Jason.encode!(%{"blob" => String.duplicate("a", 70_000)})
      assert_error(call(:put, tag_path(uid, room, "u.big"), {:raw, big}, t), 413, "M_TOO_LARGE")
      assert tags_of(uid, t, room) == %{}
    end

    test "PUT body above the generic 1 MB parser limit → 413 (raised or rendered)", %{uid: uid, token: t, room: room} do
      big = Jason.encode!(%{"blob" => String.duplicate("a", 1_200_000)})

      result =
        try do
          {:conn, call(:put, tag_path(uid, room, "u.big"), {:raw, big}, t)}
        rescue
          e in Plug.Parsers.RequestTooLargeError -> {:raised, Plug.Exception.status(e)}
        end

      case result do
        {:raised, status} -> assert status == 413
        {:conn, c} -> assert_error(c, 413, "M_TOO_LARGE")
      end

      assert tags_of(uid, t, room) == %{}
    end

    # Nebu decision (spec names no code): a single oversized BODY is 413 (asserted above); an event
    # that only grows beyond the per-value cap through accumulation answers 413 M_TOO_LARGE, and
    # 403 M_RESOURCE_LIMIT_EXCEEDED would be an equally defensible choice, so either is accepted.
    test "a tag PUT that would push the whole m.tag event above the body cap → 413 (or 403 limit), old value kept",
         %{uid: uid, token: t, room: room} do
      put_env_restoring(:nebu, :room_account_data_max_bytes, 300)
      assert put_tag(uid, t, room, "u.a", %{"p" => String.duplicate("x", 150)}).status == 200

      c = put_tag(uid, t, room, "u.b", %{"p" => String.duplicate("y", 200)})
      assert {c.status, json(c)["errcode"]} in [{413, "M_TOO_LARGE"}, {403, "M_RESOURCE_LIMIT_EXCEEDED"}],
             "got #{c.status}: #{c.resp_body}"

      assert tags_of(uid, t, room) == %{"u.a" => %{"p" => String.duplicate("x", 150)}}
    end
  end

  describe "AC2 shrinking an oversize event (operator lowered the per-event cap)" do
    test "DELETE of a tag still works when the remaining event exceeds the lowered max_bytes",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "u.a", %{"p" => String.duplicate("x", 150)}).status == 200
      assert put_tag(uid, t, room, "u.b", %{"p" => String.duplicate("y", 150)}).status == 200

      # cap lowered below even the remaining one-tag event
      put_env_restoring(:nebu, :room_account_data_max_bytes, 100)

      assert del_tag(uid, t, room, "u.b").status == 200
      assert tags_of(uid, t, room) == %{"u.a" => %{"p" => String.duplicate("x", 150)}}
    end
  end

  # Nebu decision, not in spec: the caps of room account data apply to the m.tag row.
  describe "AC2 caps (row count / total bytes)" do
    test "row cap only counts NEW room rows: tag add to an existing m.tag row is allowed at the cap, a new room is refused",
         %{uid: uid, token: t, room: room} do
      other = create_room(t, "tags-cap-room")
      # relative cap: current row count + 1, so a createRoom that starts writing account data
      # rows in the future does not break this test
      put_env_restoring(:nebu, :room_account_data_max_rows_per_user, capped_row_count(uid) + 1)

      assert put_tag(uid, t, room, "m.favourite", %{}).status == 200
      # row exists -> adding tags never grows the row count
      assert put_tag(uid, t, room, "u.second", %{}).status == 200
      assert put_tag(uid, t, room, "u.third", %{}).status == 200
      assert Map.keys(tags_of(uid, t, room)) |> Enum.sort() == ["m.favourite", "u.second", "u.third"]

      # a NEW room row would exceed the cap
      assert_error(put_tag(uid, t, other, "m.favourite", %{}), 403, "M_RESOURCE_LIMIT_EXCEEDED")
      assert tags_of(uid, t, other) == %{}

      # DELETE on a room without a row never creates one and never errors
      assert del_tag(uid, t, other, "m.favourite").status == 200
    end

    test "total-bytes cap: growth beyond the cap → 403 M_RESOURCE_LIMIT_EXCEEDED, old value kept; shrink works",
         %{uid: uid, token: t, room: room} do
      put_env_restoring(:nebu, :room_account_data_max_total_bytes, 200)
      assert put_tag(uid, t, room, "u.a", %{"p" => String.duplicate("x", 20)}).status == 200
      before = tags_of(uid, t, room)

      assert_error(
        put_tag(uid, t, room, "u.b", %{"p" => String.duplicate("y", 400)}),
        403,
        "M_RESOURCE_LIMIT_EXCEEDED"
      )

      assert tags_of(uid, t, room) == before
      assert del_tag(uid, t, room, "u.a").status == 200
    end
  end

  # Nebu decision, not in spec: the spec says "Rate-limited: No"; Nebu applies the account_data tier
  # to the WRITES (PUT/DELETE). GET is not rate limited.
  describe "AC2 rate limit (tier account_data, 60/min, burst 30/user)" do
    test "31st tag write within the burst window → 429 M_LIMIT_EXCEEDED; bucket shared with account data; other user independent",
         %{priv: priv, uid: uid, token: t, room: room} do
      enable_rate_limit()

      statuses =
        for i <- 1..31 do
          cond do
            rem(i, 3) == 0 -> del_tag(uid, t, room, "u.rl#{i}").status
            rem(i, 3) == 1 -> put_tag(uid, t, room, "u.rl#{i}", %{"order" => 0.5}).status
            true -> put_room_ad(uid, t, room, "m.rl.t#{i}", %{"i" => i}).status
          end
        end

      assert Enum.take(statuses, 30) |> Enum.all?(&(&1 == 200)), "got #{inspect(statuses)}"
      assert List.last(statuses) == 429

      limited = put_tag(uid, t, room, "u.rl.last", %{})
      assert_error(limited, 429, "M_LIMIT_EXCEEDED")
      assert [ra] = get_resp_header(limited, "retry-after")
      assert String.to_integer(ra) >= 1

      {uid2, t2} = new_user(priv, "tags-rl-other")
      room2 = create_room(t2, "tags-rl-room")
      assert put_tag(uid2, t2, room2, "m.favourite", %{}).status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — atomic read-modify-write
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3 concurrency" do
    setup do
      disable_rate_limit()
      :ok
    end

    test "20 parallel PUTs of 20 distinct tags → all 20 tags are present", %{uid: uid, token: t, room: room} do
      names = for i <- 1..20, do: "u.par#{i}"

      statuses =
        names
        |> Task.async_stream(fn n -> put_tag(uid, t, room, n, %{"order" => 0.5}).status end,
          max_concurrency: 20,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, s} -> s end)

      assert Enum.all?(statuses, &(&1 == 200)), "got #{inspect(statuses)}"
      assert tags_of(uid, t, room) |> Map.keys() |> Enum.sort() == Enum.sort(names)
    end

    test "parallel PUT of new tags and DELETE of old tags: neither is lost", %{uid: uid, token: t, room: room} do
      old = for i <- 1..10, do: "u.old#{i}"
      new = for i <- 1..10, do: "u.new#{i}"
      keep = "u.keep"
      for n <- [keep | old], do: assert(put_tag(uid, t, room, n, %{}).status == 200)

      jobs = Enum.map(new, &{:put, &1}) ++ Enum.map(old, &{:del, &1})

      statuses =
        jobs
        |> Task.async_stream(
          fn
            {:put, n} -> put_tag(uid, t, room, n, %{"order" => 0.1}).status
            {:del, n} -> del_tag(uid, t, room, n).status
          end,
          max_concurrency: 20,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, s} -> s end)

      assert Enum.all?(statuses, &(&1 == 200)), "got #{inspect(statuses)}"
      assert tags_of(uid, t, room) |> Map.keys() |> Enum.sort() == Enum.sort([keep | new])
    end

    test "parallel PUT and DELETE of the SAME tag ends in a valid state (present or absent), never corrupt",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "u.base", %{}).status == 200

      statuses =
        1..20
        |> Task.async_stream(
          fn i ->
            if rem(i, 2) == 0,
              do: put_tag(uid, t, room, "u.flip", %{"order" => 0.5}).status,
              else: del_tag(uid, t, room, "u.flip").status
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, s} -> s end)

      assert Enum.all?(statuses, &(&1 == 200))
      tags = tags_of(uid, t, room)
      assert tags["u.base"] == %{}
      assert tags["u.flip"] in [nil, %{"order" => 0.5}]
    end

    test "tag PUTs racing a direct PUT account_data/m.tag never leave a corrupted event (last-writer-wins)",
         %{uid: uid, token: t, room: room} do
      names = for i <- 1..10, do: "u.race#{i}"

      jobs = Enum.map(names, &{:tag, &1}) ++ for(i <- 1..5, do: {:direct, i})

      statuses =
        jobs
        |> Task.async_stream(
          fn
            {:tag, n} -> put_tag(uid, t, room, n, %{"order" => 0.2}).status
            {:direct, i} -> put_room_ad(uid, t, room, "m.tag", %{"tags" => %{"u.direct#{i}" => %{"order" => 0.7}}}).status
          end,
          max_concurrency: 15,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, s} -> s end)

      assert Enum.all?(statuses, &(&1 == 200)), "got #{inspect(statuses)}"

      ad = get_room_ad(uid, t, room, "m.tag")
      assert ad.status == 200
      assert %{"tags" => tags} = json(ad)
      assert is_map(tags)
      allowed = names ++ for(i <- 1..5, do: "u.direct#{i}")
      assert Enum.all?(Map.keys(tags), &(&1 in allowed)), "unexpected tags #{inspect(Map.keys(tags))}"
      assert json(get_tags(uid, t, room)) == %{"tags" => tags}

      # the event stays fully usable afterwards
      assert put_tag(uid, t, room, "u.after", %{}).status == 200
      assert Map.has_key?(tags_of(uid, t, room), "u.after")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC4 — interop with direct room account data
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC4 interop with account_data/m.tag" do
    test "direct PUT account_data/m.tag is allowed (no 405) and visible through GET tags",
         %{uid: uid, token: t, room: room} do
      c = put_room_ad(uid, t, room, "m.tag", %{"tags" => %{"m.favourite" => %{"order" => 0.25}, "u.x" => %{}}})
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"
      assert json(c) == %{}

      get = get_tags(uid, t, room)
      refute_catch_all(get)
      assert json(get) == %{"tags" => %{"m.favourite" => %{"order" => 0.25}, "u.x" => %{}}}
    end

    test "tag PUT is visible through GET account_data/m.tag (exact event content) and a later tag PUT keeps direct data",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      ad = get_room_ad(uid, t, room, "m.tag")
      assert ad.status == 200
      assert json(ad) == %{"tags" => %{"m.favourite" => %{"order" => 0.25}}}

      assert put_room_ad(uid, t, room, "m.tag", %{"tags" => %{"u.direct" => %{}}}).status == 200
      assert put_tag(uid, t, room, "u.more", %{"order" => 0.5}).status == 200

      assert tags_of(uid, t, room) == %{"u.direct" => %{}, "u.more" => %{"order" => 0.5}}
      assert json(get_room_ad(uid, t, room, "m.tag")) == %{"tags" => %{"u.direct" => %{}, "u.more" => %{"order" => 0.5}}}
    end

    test "direct PUT replaces the whole event (tags set by tag endpoints are gone)", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "u.old", %{}).status == 200
      assert put_room_ad(uid, t, room, "m.tag", %{"tags" => %{"u.new" => %{}}}).status == 200
      assert tags_of(uid, t, room) == %{"u.new" => %{}}
    end

    test "stored m.tag without `tags` + tag PUT → no 500, valid result, unknown top-level keys preserved",
         %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.tag", %{"x.keep" => [1, 2], "other" => "v"}).status == 200

      c = put_tag(uid, t, room, "m.favourite", %{"order" => 0.5})
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"

      ad = json(get_room_ad(uid, t, room, "m.tag"))
      assert ad["tags"] == %{"m.favourite" => %{"order" => 0.5}}
      assert ad["x.keep"] == [1, 2]
      assert ad["other"] == "v"
      assert tags_of(uid, t, room) == %{"m.favourite" => %{"order" => 0.5}}
    end

    test "stored m.tag with non-object `tags` (string/array/null/number) + tag PUT → no 500, treated as {}",
         %{uid: uid, token: t, room: room} do
      for bad <- ["oops", [1, 2], nil, 7, true] do
        assert put_room_ad(uid, t, room, "m.tag", %{"tags" => bad, "x.keep" => 1}).status == 200

        c = put_tag(uid, t, room, "u.fixed", %{})
        assert c.status == 200, "tags=#{inspect(bad)}: got #{c.status}: #{c.resp_body}"

        ad = json(get_room_ad(uid, t, room, "m.tag"))
        assert ad["tags"] == %{"u.fixed" => %{}}, "tags=#{inspect(bad)}"
        assert ad["x.keep"] == 1
      end
    end

    test "GET tags / DELETE on a malformed stored m.tag never 500", %{uid: uid, token: t, room: room} do
      for stored <- [%{"tags" => "oops"}, %{"foo" => 1}, %{}, %{"tags" => [1]}] do
        assert put_room_ad(uid, t, room, "m.tag", stored).status == 200

        get = get_tags(uid, t, room)
        assert get.status == 200, "#{inspect(stored)}: got #{get.status}: #{get.resp_body}"
        assert is_map(json(get)["tags"])

        del = del_tag(uid, t, room, "m.favourite")
        assert del.status == 200, "#{inspect(stored)}: got #{del.status}: #{del.resp_body}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — /sync
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5 /sync delivery" do
    test "initial sync: exactly ONE m.tag event per room holding the current state",
         %{uid: uid, token: t, room: room} do
      other = create_room(t, "tags-sync-room-2")
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert put_tag(uid, t, room, "u.work", %{}).status == 200
      assert put_tag(uid, t, room, "u.work2", %{}).status == 200
      assert del_tag(uid, t, room, "u.work2").status == 200

      body = sync(t)
      assert [ev] = tag_events(body, room)
      assert ev["content"] == %{"tags" => %{"m.favourite" => %{"order" => 0.25}, "u.work" => %{}}}
      assert Map.keys(ev) |> Enum.sort() == ["content", "type"]
      assert tag_events(body, other) == []
    end

    test "incremental sync delivers only after a change, as ONE event with the full current tags",
         %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      first = sync(t)
      assert [_] = tag_events(first, room)

      # unchanged -> nothing
      assert tag_events(sync(t, first["next_batch"]), room) == []

      assert put_tag(uid, t, room, "u.a", %{}).status == 200
      assert put_tag(uid, t, room, "u.b", %{}).status == 200
      assert del_tag(uid, t, room, "u.a").status == 200

      inc = sync(t, first["next_batch"])
      assert [ev] = tag_events(inc, room)
      assert ev["content"]["tags"] |> Map.keys() |> Enum.sort() == ["m.favourite", "u.b"]

      joined = get_in(inc, ["rooms", "join"]) || %{}
      assert Map.has_key?(joined, room), "a room whose only change is a tag must be in rooms.join"

      assert tag_events(sync(t, inc["next_batch"]), room) == []
    end

    test "direct PUT account_data/m.tag also yields exactly one m.tag event", %{uid: uid, token: t, room: room} do
      first = sync(t)
      assert put_room_ad(uid, t, room, "m.tag", %{"tags" => %{"u.d" => %{}}}).status == 200
      assert put_tag(uid, t, room, "u.e", %{}).status == 200
      assert [ev] = tag_events(sync(t, first["next_batch"]), room)
      assert ev["content"]["tags"] |> Map.keys() |> Enum.sort() == ["u.d", "u.e"]
    end

    test "TWO DEVICES: both since tokens get the change, each exactly once", %{uid: uid, token: t, room: room} do
      since_a = sync(t)["next_batch"]
      since_b = sync(t)["next_batch"]

      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200

      a1 = sync(t, since_a)
      assert [%{"content" => %{"tags" => %{"m.favourite" => _}}}] = tag_events(a1, room)

      b1 = sync(t, since_b)
      assert [%{"content" => %{"tags" => %{"m.favourite" => _}}}] = tag_events(b1, room)

      assert tag_events(sync(t, a1["next_batch"]), room) == []
      assert tag_events(sync(t, b1["next_batch"]), room) == []
    end

    test "TWO DEVICES: a stale token gets the latest state once after another device advanced",
         %{uid: uid, token: t, room: room} do
      since_a = sync(t)["next_batch"]
      since_b = sync(t)["next_batch"]

      assert put_tag(uid, t, room, "u.one", %{}).status == 200
      a1 = sync(t, since_a)
      _ = sync(t, a1["next_batch"])
      assert put_tag(uid, t, room, "u.two", %{}).status == 200

      assert [ev] = tag_events(sync(t, since_b), room)
      assert ev["content"]["tags"] |> Map.keys() |> Enum.sort() == ["u.one", "u.two"]
    end

    test "long-poll /sync is woken by a tag change", %{uid: uid, token: t, room: room} do
      since = sync(t)["next_batch"]
      members_before = pg_members(uid)

      task =
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          c = call(:get, "/_matrix/client/v3/sync?timeout=15000&since=#{enc(since)}", nil, t)
          {c, System.monotonic_time(:millisecond) - started}
        end)

      await_poller(uid, members_before)
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200

      {c, elapsed} = Task.await(task, 20_000)
      assert c.status == 200
      assert [%{"content" => %{"tags" => %{"m.favourite" => _}}}] = tag_events(json(c), room)
      assert elapsed < 8_000, "long-poll was not woken by the tag change (took #{elapsed} ms)"
    end

    test "a tag DELETE wakes the long-poll too", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{}).status == 200
      since = sync(t)["next_batch"]
      members_before = pg_members(uid)

      task =
        Task.async(fn ->
          call(:get, "/_matrix/client/v3/sync?timeout=15000&since=#{enc(since)}", nil, t)
        end)

      await_poller(uid, members_before)
      assert del_tag(uid, t, room, "m.favourite").status == 200

      c = Task.await(task, 20_000)
      assert [%{"content" => %{"tags" => tags}}] = tag_events(json(c), room)
      assert tags == %{}
    end

    test "DELETE on a room without an m.tag row creates no row and no sync event", %{uid: uid, token: t, room: room} do
      first = sync(t)
      assert del_tag(uid, t, room, "u.never").status == 200

      assert Enum.all?(stored_rows(uid), &(not (&1["type"] == "m.tag" and &1["room_id"] == room)))
      assert tag_events(sync(t, first["next_batch"]), room) == []
    end

    test "a room the user has left delivers no m.tag", %{priv: priv, token: t, room: room} do
      {bob, bob_t} = new_user(priv, "tags-leaver")
      # One fixed way into the room: the owner invites, bob joins.
      assert call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/invite", %{"user_id" => bob}, t).status == 200
      assert call(:post, "/_matrix/client/v3/join/#{enc(room)}", %{}, bob_t).status == 200

      assert put_tag(bob, bob_t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert [_] = tag_events(sync(bob_t), room)

      assert call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/leave", %{}, bob_t).status == 200

      body = sync(bob_t)
      assert tag_events(body, room) == []

      left =
        (get_in(body, ["rooms", "leave", room, "account_data", "events"]) || [])
        |> Enum.filter(&(&1["type"] == "m.tag"))

      assert left == []

      # a left room can no longer be tagged and does not leak the old tags
      assert_error(put_tag(bob, bob_t, room, "u.late", %{}), 403, "M_FORBIDDEN")
      assert_error(get_tags(bob, bob_t, room), 403, "M_FORBIDDEN")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — privacy / lifecycle
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6 lifecycle" do
    test "GDPR erasure (delete_user_keys) removes the user's tags", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{"order" => 0.25}).status == 200
      assert Enum.any?(stored_rows(uid), &(&1["type"] == "m.tag")), "precondition: tag row stored"

      assert {:ok, _} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:test.local", uid, "gdpr request")
      assert stored_rows(uid) == []
    end

    test "another user's tags survive erasure of this user", %{priv: priv, uid: uid, token: t, room: room} do
      {bob, bob_t} = new_user(priv, "tags-bob-keep")
      bob_room = create_room(bob_t, "bob-keep-room")
      assert put_tag(uid, t, room, "m.favourite", %{}).status == 200
      assert put_tag(bob, bob_t, bob_room, "m.favourite", %{"order" => 0.4}).status == 200

      assert {:ok, _} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:test.local", uid, "gdpr request")
      assert tags_of(bob, bob_t, bob_room) == %{"m.favourite" => %{"order" => 0.4}}
    end
  end

  describe "AC6 cascade" do
    # Rows reference users and rooms with ON DELETE CASCADE (migration 000039): no new deletion
    # path is needed, this verifies it for the m.tag row.
    defp tag_row_count(uid, room) do
      {:ok, %{rows: [[n]]}} =
        Nebu.Repo.query(
          "SELECT count(*) FROM user_room_account_data WHERE user_id = $1 AND room_id = $2 AND type = 'm.tag'",
          [uid, room]
        )

      n
    end

    # Other tables also reference users/rooms (room_members, user_keys, ...), so a real DELETE of
    # the parent row is blocked by unrelated FKs; the cascade of THIS table is verified in the
    # catalog (confdeltype 'c' = ON DELETE CASCADE) and the row itself is proven to exist.
    defp cascades_from?(parent) do
      {:ok, %{rows: [[n]]}} =
        Nebu.Repo.query(
          """
          SELECT count(*) FROM pg_constraint
          WHERE conrelid = 'user_room_account_data'::regclass AND contype = 'f'
            AND confrelid = $1::text::regclass AND confdeltype = 'c'
          """,
          [parent]
        )

      n >= 1
    end

    test "the FK to rooms and to users is declared ON DELETE CASCADE in the catalog (no real deletion performed)", %{uid: uid, token: t, room: room} do
      assert put_tag(uid, t, room, "m.favourite", %{}).status == 200
      assert tag_row_count(uid, room) == 1

      assert cascades_from?("rooms"), "user_room_account_data.room_id must cascade on room deletion"
      assert cascades_from?("users"), "user_room_account_data.user_id must cascade on user deletion"
    end
  end

  describe "AC6 logging law" do
    test "tag bodies (orders/extra fields) and GET responses are never logged — also for path variants",
         %{uid: uid, token: t, room: room} do
      order_marker = "0.8675309"
      field_marker = "TOPSECRET-TAG-#{:erlang.unique_integer([:positive])}"
      body = ~s({"order":#{order_marker},"note":"#{field_marker}"})
      rooms = "#{user_path(uid)}/rooms/#{enc(room)}"

      put_paths = [
        rooms <> "/tags/u.log1",
        user_path(uid) <> "/rooms/#{enc(room)}/%74ags/u.log2",
        "/_matrix//client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/tags/u.log3",
        "/_matrix/client//v3/user/#{enc(uid)}/rooms/#{enc(room)}//tags/u.log4",
        rooms <> "/tags//u.log5",
        rooms <> "/tags/u.log6/",
        rooms <> "/%74ags/u.log7%2Fx"
      ]

      get_paths = [
        rooms <> "/tags",
        rooms <> "/%74ags",
        "/_matrix//client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/tags",
        rooms <> "/tags/"
      ]

      log =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            for path <- put_paths do
              c = call_raw(:put, path, body, "application/json", t)
              # `%2F` in the name: 200 (stored as "u.log7/x") or 400 M_INVALID_PARAM are both
              # acceptable (see the AC2 `%2F` test); the marker assertions below hold regardless.
              allowed = if String.contains?(path, "%2F"), do: [200, 400], else: [200]
              assert c.status in allowed, "PUT #{path}: got #{c.status}: #{c.resp_body}"
            end

            for path <- get_paths do
              c = call_raw(:get, path, nil, nil, t)
              assert c.status == 200, "GET #{path}: got #{c.status}: #{c.resp_body}"
              assert c.resp_body =~ field_marker, "precondition: response carries the tag content"
            end

            for path <- ["#{rooms}/tags/u.log1", rooms <> "/%74ags/u.log2"] do
              assert call_raw(:delete, path, nil, nil, t).status == 200
            end
          end)
        end)

      # Precondition: the request logger really ran and logged these requests (the tag NAME is
      # part of the logged request path), so the refutes below cannot pass on a silent logger.
      assert log =~ "/tags/:tag", "precondition: the request logger must have logged the normalized tag paths"
      assert log =~ "/user/:user_id/rooms/:room_id/tags/:tag"
      # Tag names are user content (AC6): never in the request log (path / route_template).
      for n <- 1..7, do: refute(log =~ "u.log#{n}", "tag name u.log#{n} leaked into the request log")
      refute log =~ field_marker
      refute log =~ "8675309"
    end
  end
end
