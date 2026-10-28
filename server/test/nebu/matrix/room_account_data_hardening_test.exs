defmodule Nebu.Web.RoomAccountDataHardeningTest do
  @moduledoc """
  Cycle-1 review/security fixes for story `room-account-data-and-read-markers`
  (epic matrix-spec-gaps):

    1. oversized-body handling must only be tolerated on the exact account-data PUT shapes
       and the GLOBAL PUT must answer 413 (never store `{}`);
    2. total-bytes cap + per-user rate limit on the account-data PUT routes;
    3. account-data content is never part of the DEBUG payload capture;
    4. `<core>.<pos>` since-token position is bounded/clamped;
    5. read_markers: m.fully_read is exempt from the caps;
    6. global PUT rejects non-object bodies;
    7. type decoding is consistent between the global and the room scope.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "room-account-data-hardening-key-1"
  @router_opts Nebu.Web.Router.init([])

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

  # Raw request with an explicit (or absent) Content-Type and a verbatim path.
  defp call_raw(method, path, raw, content_type, token) do
    c = conn(method, path, raw)
    c = if content_type, do: put_req_header(c, "content-type", content_type), else: c
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

  defp sync(token, since \\ nil) do
    q = if since, do: "?timeout=0&since=#{enc(since)}", else: "?timeout=0"
    c = call(:get, "/_matrix/client/v3/sync" <> q, nil, token)
    assert c.status == 200, "sync must succeed (got #{c.status}: #{c.resp_body})"
    json(c)
  end

  defp room_ad(body, room) do
    (get_in(body, ["rooms", "join", room, "account_data", "events"]) || [])
    |> Map.new(&{&1["type"], &1["content"]})
  end

  defp new_user(priv, prefix) do
    {uid, token} = bearer_for("#{prefix}-#{:erlang.unique_integer([:positive])}", priv)

    _ =
      Nebu.Matrix.Session.TokenValidator.validate(
        uid,
        "user",
        uid,
        "#{:erlang.unique_integer([:positive])}@example.com"
      )

    {uid, token}
  end

  defp create_room(token, name) do
    c = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, token)
    assert c.status == 200
    json(c)["room_id"]
  end

  defp send_message(token, room, body) do
    txn = "rh-" <> Integer.to_string(System.unique_integer([:positive]))

    c =
      call(
        :put,
        "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/#{txn}",
        %{"msgtype" => "m.text", "body" => body},
        token
      )

    assert c.status == 200
    json(c)["event_id"]
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

  defp with_log_level(level, fun) do
    original = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original)
    end
  end

  # story event-size-limit (DELIBERATE re-pin, AC7 (d); old -> new): a body over 1 MB on a /_matrix route that is NOT an exact account-data / room-tag
  # shape used to RAISE Plug.Parsers.RequestTooLargeError (Plug's default; Bandit renders an EMPTY 413: no body, no errcode, no CORS headers). It is now answered
  # by `JsonBody` with the rendered Matrix envelope `413 {"errcode": "M_TOO_LARGE", "error": "Request body is too large"}` (D7); the intent of the two tests stays:
  # the oversized body never becomes an (empty) event, nothing is written.
  defp assert_matrix_413(method, path, token) do
    c = call(method, path, {:raw, big_json(1_200_000)}, token)
    assert c.status == 413, "expected 413, got #{c.status}: #{String.slice(c.resp_body, 0, 200)}"
    assert json(c) == %{"errcode" => "M_TOO_LARGE", "error" => "Request body is too large"}
    c
  end

  defp events_in(room, type) do
    Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2", [room, type]).rows |> hd() |> hd()
  end

  defp big_json(bytes), do: Jason.encode!(%{"blob" => String.duplicate("a", bytes)})

  setup do
    priv = setup_oidc_keys()
    {uid, token} = new_user(priv, "rad-hard")
    room = create_room(token, "rad-hard-room")
    {:ok, priv: priv, uid: uid, token: token, room: room}
  end

  # ── 1. oversized body handling ──────────────────────────────────────────────

  describe "oversized bodies" do
    @describetag :integration

    test "global PUT > 1 MB → 413 M_TOO_LARGE and the old value is unchanged", %{uid: uid, token: t} do
      assert put_global_ad(uid, t, "m.secret_storage.key.x", %{"v" => 1}).status == 200

      c = put_global_ad(uid, t, "m.secret_storage.key.x", {:raw, big_json(1_200_000)})
      assert c.status == 413, "got #{c.status}: #{String.slice(c.resp_body, 0, 200)}"
      assert json(c)["errcode"] == "M_TOO_LARGE"

      assert json(get_global_ad(uid, t, "m.secret_storage.key.x")) == %{"v" => 1}
    end

    test "room PUT > 64 KiB → 413 M_TOO_LARGE", %{uid: uid, token: t, room: room} do
      c = put_room_ad(uid, t, room, "m.big", {:raw, big_json(70_000)})
      assert c.status == 413
      assert json(c)["errcode"] == "M_TOO_LARGE"
    end

    test "send/{type}/account_data with > 1 MB is the Matrix M_TOO_LARGE envelope (never an empty event)",
         %{token: t, room: room} do
      before = events_in(room, "m.room.message")
      assert_matrix_413(:put, "/_matrix/client/v3/rooms/#{enc(room)}/send/m.room.message/account_data", t)
      assert events_in(room, "m.room.message") == before, "no event was written"
    end

    test "state event with state_key account_data and > 1 MB is the Matrix M_TOO_LARGE envelope (never an empty event)", %{token: t, room: room} do
      before = events_in(room, "m.room.topic")
      assert_matrix_413(:put, "/_matrix/client/v3/rooms/#{enc(room)}/state/m.room.topic/account_data", t)
      assert events_in(room, "m.room.topic") == before, "no event was written"
    end

    test "shape helper matches only PUT on the exact account-data shapes" do
      alias Nebu.Web.Plugs.RawBodyReader, as: R
      base = ["_matrix", "client", "v3"]
      assert R.account_data_shape?(base ++ ["user", "@a:b", "account_data", "t"])
      assert R.account_data_shape?(base ++ ["user", "@a:b", "rooms", "!r", "account_data", "t"])
      refute R.account_data_shape?(base ++ ["rooms", "!r", "send", "m.room.message", "account_data"])
      refute R.account_data_shape?(base ++ ["rooms", "!r", "state", "m.room.topic", "account_data"])
      refute R.account_data_shape?(base ++ ["rooms", "account_data", "send", "t", "x"])
      refute R.account_data_shape?(base ++ ["user", "@a:b", "account_data"])
      assert R.opaque_content_put?(%Plug.Conn{method: "PUT", path_info: base ++ ["user", "u", "account_data", "t"]})
      refute R.opaque_content_put?(%Plug.Conn{method: "GET", path_info: base ++ ["user", "u", "account_data", "t"]})
    end
  end

  # ── 2. total cap + rate limit ───────────────────────────────────────────────

  describe "total bytes cap" do
    @describetag :integration

    test "total cap refuses growth with 403 M_RESOURCE_LIMIT_EXCEEDED; non-growing overwrite still works",
         %{uid: uid, token: t, room: room} do
      body = fn n -> Jason.encode!(%{"p" => String.duplicate("x", n)}) end
      # each body is 8 + n bytes (`{"p":"..."}`): 98 bytes for n = 90
      put_env_restoring(:nebu, :room_account_data_max_total_bytes, 250)

      assert put_room_ad(uid, t, room, "m.t.a", {:raw, body.(90)}).status == 200
      assert put_room_ad(uid, t, room, "m.t.b", {:raw, body.(90)}).status == 200

      refused = put_room_ad(uid, t, room, "m.t.c", {:raw, body.(90)})
      assert refused.status == 403, "got #{refused.status}: #{refused.resp_body}"
      assert json(refused)["errcode"] == "M_RESOURCE_LIMIT_EXCEEDED"
      assert get_room_ad(uid, t, room, "m.t.c").status == 404

      # growth of an existing row beyond the cap is refused, old value stays
      grow = put_room_ad(uid, t, room, "m.t.a", {:raw, body.(250)})
      assert grow.status == 403
      assert get_room_ad(uid, t, room, "m.t.a").resp_body == body.(90)

      # same-size and shrinking overwrites keep working at the cap
      assert put_room_ad(uid, t, room, "m.t.a", {:raw, body.(90)}).status == 200
      assert put_room_ad(uid, t, room, "m.t.a", {:raw, body.(10)}).status == 200
      # and the freed room can be used again
      assert put_room_ad(uid, t, room, "m.t.c", {:raw, body.(90)}).status == 200
    end

    test "default total cap is 4 MiB" do
      assert Nebu.Matrix.RoomAccountDataStore.max_total_bytes() == 4_194_304
    end
  end

  describe "rate limit on account-data PUT" do
    @describetag :integration

    test "31st PUT within the burst window → 429 M_LIMIT_EXCEEDED (room and global share the per-user bucket)",
         %{priv: priv, uid: uid, token: t, room: room} do
      # The integration harness sets NEBU_RATE_LIMIT_DISABLED=true: neutralize the OS env
      # var too (restored in on_exit), like matrix_router_test.exs does.
      prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
      System.delete_env("NEBU_RATE_LIMIT_DISABLED")

      ExUnit.Callbacks.on_exit(fn ->
        if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env)
      end)

      put_env_restoring(:nebu_http, :rate_limit_clock_fn, fn -> 5_000_000 end)
      put_env_restoring(:nebu_http, :rate_limit_disabled, false)

      statuses =
        for i <- 1..31 do
          if rem(i, 2) == 0,
            do: put_room_ad(uid, t, room, "m.rl.t#{i}", %{"i" => i}).status,
            else: put_global_ad(uid, t, "m.rl.g#{i}", %{"i" => i}).status
        end

      assert Enum.take(statuses, 30) |> Enum.all?(&(&1 == 200)), "got #{inspect(statuses)}"
      assert List.last(statuses) == 429

      # another user has an independent bucket
      {uid2, t2} = new_user(priv, "rad-hard-other")
      assert put_global_ad(uid2, t2, "m.rl.x", %{"i" => 1}).status == 200
    end
  end

  # ── 3. logging law ──────────────────────────────────────────────────────────

  describe "DEBUG payload capture" do
    @describetag :integration

    test "account-data request and response bodies are never logged", %{uid: uid, token: t, room: room} do
      marker = "TOPSECRET-MARKER-#{:erlang.unique_integer([:positive])}"
      content = %{"note" => marker}

      log =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            assert put_room_ad(uid, t, room, "m.log.room", content).status == 200
            assert put_global_ad(uid, t, "m.log.global", content).status == 200
            assert get_room_ad(uid, t, room, "m.log.room").status == 200
            assert get_global_ad(uid, t, "m.log.global").status == 200
          end)
        end)

      assert log =~ "account_data", "precondition: the request logger must have run"
      refute log =~ marker
    end
  end

  # ── 4. since token position ─────────────────────────────────────────────────

  describe "since token position" do
    @describetag :integration

    test "oversized position (> int8) is treated as position 0 (everything redelivered)",
         %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.tok.a", %{"v" => 1}).status == 200
      first = sync(t)
      [core, _pos] = String.split(first["next_batch"], ".")

      for suffix <- ["99999999999999999999", "9223372036854775808", "0000000000000000000000001"] do
        body = sync(t, core <> "." <> suffix)
        assert room_ad(body, room)["m.tok.a"] == %{"v" => 1}, "suffix #{suffix}"
      end
    end

    test "position above the user's latest is clamped; later writes are still delivered",
         %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.tok.a", %{"v" => 1}).status == 200
      first = sync(t)
      [core, pos] = String.split(first["next_batch"], ".")
      forged = core <> "." <> Integer.to_string(String.to_integer(pos) + 1_000_000)

      resp = sync(t, forged)
      [_c, echoed] = String.split(resp["next_batch"], ".")
      assert String.to_integer(echoed) == String.to_integer(pos)

      assert put_room_ad(uid, t, room, "m.tok.b", %{"v" => 2}).status == 200
      assert room_ad(sync(t, resp["next_batch"]), room)["m.tok.b"] == %{"v" => 2}
    end

    test "signed / malformed suffixes are not parsed as a position", %{uid: uid, token: t, room: room} do
      assert put_room_ad(uid, t, room, "m.tok.a", %{"v" => 1}).status == 200
      first = sync(t)
      [core, pos] = String.split(first["next_batch"], ".")

      # `+<pos>` used to be accepted as a position (suppressing the row); now the whole
      # token is the (unknown) core → fallback to a full initial sync
      assert room_ad(sync(t, core <> ".+" <> pos), room)["m.tok.a"] == %{"v" => 1}

      for bad <- [core <> ".", core <> ".-1", core <> ".a.b", core <> "..5x"] do
        resp = sync(t, bad)
        assert room_ad(resp, room)["m.tok.a"] == %{"v" => 1}, "token #{bad}"
      end
    end
  end

  # ── 5. read_markers vs caps ─────────────────────────────────────────────────

  describe "read_markers and the caps" do
    @describetag :integration

    test "m.fully_read is exempt from the row and total caps", %{uid: uid, token: t, room: room} do
      ev = send_message(t, room, "marker target")
      put_env_restoring(:nebu, :room_account_data_max_rows_per_user, 2)
      put_env_restoring(:nebu, :room_account_data_max_total_bytes, 40)

      assert put_room_ad(uid, t, room, "m.c.a", %{"v" => 1}).status == 200
      assert put_room_ad(uid, t, room, "m.c.b", %{"v" => 1}).status == 200
      assert put_room_ad(uid, t, room, "m.c.c", %{"v" => 1}).status == 403

      c = call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/read_markers", %{"m.fully_read" => ev, "m.read" => ev}, t)
      assert c.status == 200, "got #{c.status}: #{c.resp_body}"

      ev2 = send_message(t, room, "second")
      c2 = call(:post, "/_matrix/client/v3/rooms/#{enc(room)}/read_markers", %{"m.fully_read" => ev2}, t)
      assert c2.status == 200
      assert json(get_room_ad(uid, t, room, "m.fully_read")) == %{"event_id" => ev2}

      # the exempt row does not consume the user's own budget either
      assert put_room_ad(uid, t, room, "m.c.a", %{"v" => 2}).status == 200
    end
  end

  # ── 6. global body must be an object ────────────────────────────────────────

  describe "global PUT body shape" do
    @describetag :integration

    test "array / scalar bodies → 400 M_BAD_JSON, nothing stored", %{uid: uid, token: t} do
      for {raw, i} <- Enum.with_index(["[1,2]", "42", ~s("str"), "null"]) do
        type = "m.test.nonobj#{i}"
        c = put_global_ad(uid, t, type, {:raw, raw})
        assert c.status == 400, "#{raw}: got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_BAD_JSON"
        assert get_global_ad(uid, t, type).status == 404
      end
    end

    test "an object that happens to contain a `_json` key is still stored", %{uid: uid, token: t} do
      assert put_global_ad(uid, t, "m.test.jsonkey", {:raw, ~s({"_json":[1]})}).status == 200
      assert json(get_global_ad(uid, t, "m.test.jsonkey")) == %{"_json" => [1]}
    end
  end

  # ── 7. type decoding consistency ────────────────────────────────────────────

  describe "type decoding" do
    @describetag :integration

    test "type `a+b` is stored under the same key in the global and the room scope",
         %{uid: uid, token: t, room: room} do
      assert put_global_ad(uid, t, "a+b", %{"s" => "g"}).status == 200
      assert put_room_ad(uid, t, room, "a+b", %{"s" => "r"}).status == 200

      {:ok, %{rows: g}} = Nebu.Repo.query("SELECT type FROM account_data WHERE user_id = $1", [uid])
      {:ok, %{rows: r}} = Nebu.Repo.query("SELECT type FROM user_room_account_data WHERE user_id = $1", [uid])
      assert g == [["a+b"]]
      assert r == [["a+b"]]

      # literal (unencoded) `+` in the path is the same key as the encoded one
      lit = call(:get, "/_matrix/client/v3/user/#{enc(uid)}/account_data/a+b", nil, t)
      assert lit.status == 200
      assert json(lit) == %{"s" => "g"}
    end
  end

  # ── 8. path matcher agrees with the router (cycle 2) ───────────────────────

  describe "account-data path variants are handled like the router routes them" do
    @describetag :integration

    test "room PUT via %61ccount_data / // / trailing slash is cached and stored byte-exact",
         %{uid: uid, token: t, room: room} do
      base = "/_matrix/client/v3/user/#{enc(uid)}/rooms/#{enc(room)}"
      raw = ~s({"b": 1,  "a":2})

      for {path, type} <- [
            {base <> "/%61ccount_data/m.v.enc", "m.v.enc"},
            {"/_matrix//client/v3/user/#{enc(uid)}/rooms/#{enc(room)}/account_data/m.v.dbl", "m.v.dbl"},
            {base <> "/account_data/m.v.trail/", "m.v.trail"}
          ] do
        c = call_raw(:put, path, raw, "application/json", t)
        assert c.status == 200, "#{path}: got #{c.status}: #{c.resp_body}"
        assert get_room_ad(uid, t, room, type).resp_body == raw
      end
    end

    test "global PUT with a non-object body is rejected on every path variant", %{uid: uid, token: t} do
      base = "/_matrix/client/v3/user/#{enc(uid)}"

      for {path, type} <- [
            {base <> "/%61ccount_data/m.v.genc", "m.v.genc"},
            {"/_matrix//client/v3/user/#{enc(uid)}/account_data/m.v.gdbl", "m.v.gdbl"},
            {base <> "/account_data/m.v.gtrail/", "m.v.gtrail"}
          ] do
        c = call_raw(:put, path, "[1,2]", "application/json", t)
        assert c.status == 400, "#{path}: got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_BAD_JSON"
        assert get_global_ad(uid, t, type).status == 404
      end
    end

    test "content is never logged for the path variants", %{uid: uid, token: t, room: room} do
      marker = "TOPSECRET-VARIANT-#{:erlang.unique_integer([:positive])}"
      content = Jason.encode!(%{"note" => marker})
      g = "/_matrix/client/v3/user/#{enc(uid)}"

      paths = [
        g <> "/%61ccount_data/m.v.log1",
        "/_matrix//client/v3/user/#{enc(uid)}/account_data/m.v.log2",
        g <> "/account_data/m.v.log3/",
        g <> "/rooms/#{enc(room)}/%61ccount_data/m.v.log4",
        "/_matrix/client//v3/user/#{enc(uid)}/rooms/#{enc(room)}/account_data/m.v.log5",
        g <> "/rooms/#{enc(room)}/account_data/m.v.log6/"
      ]

      log =
        with_log_level(:debug, fn ->
          capture_log(fn ->
            for path <- paths do
              assert call_raw(:put, path, content, "application/json", t).status == 200
              assert call_raw(:get, path, nil, nil, t).status == 200
            end
          end)
        end)

      assert log =~ "m.v.log" or log =~ "account_data", "precondition: the request logger must have run"
      refute log =~ marker
    end
  end

  # ── 9. global PUT body discipline (cycle 2) ────────────────────────────────

  describe "global PUT without a usable JSON body" do
    @describetag :integration

    test "empty / no content-type / text/plain / urlencoded bodies → 400 M_NOT_JSON, old value kept",
         %{uid: uid, token: t} do
      type = "m.secret_storage.key.cyc2"
      path = global_ad_path(uid, type)
      assert put_global_ad(uid, t, type, %{"v" => 1}).status == 200

      for {raw, ct} <- [
            {"", "application/json"},
            {"", nil},
            {~s({"v":2}), nil},
            {~s({"v":2}), "text/plain"},
            {"v=2&x=3", "application/x-www-form-urlencoded"},
            {"not json at all", "application/json"}
          ] do
        c = call_raw(:put, path, raw, ct, t)
        assert c.status == 400, "#{inspect({raw, ct})}: got #{c.status}: #{c.resp_body}"
        assert json(c)["errcode"] == "M_NOT_JSON"
        assert json(get_global_ad(uid, t, type)) == %{"v" => 1}
      end
    end

    test "oversized non-JSON body → 413 M_TOO_LARGE, old value kept", %{uid: uid, token: t} do
      type = "m.secret_storage.key.cyc2big"
      assert put_global_ad(uid, t, type, %{"v" => 1}).status == 200

      for ct <- ["text/plain", nil] do
        c = call_raw(:put, global_ad_path(uid, type), String.duplicate("a", 1_200_000), ct, t)
        assert c.status == 413, "#{inspect(ct)}: got #{c.status}: #{String.slice(c.resp_body, 0, 200)}"
        assert json(c)["errcode"] == "M_TOO_LARGE"
        assert json(get_global_ad(uid, t, type)) == %{"v" => 1}
      end
    end

    test "a JSON object with Content-Type application/json is still stored (also with charset)",
         %{uid: uid, token: t} do
      type = "m.secret_storage.key.cyc2ok"
      c = call_raw(:put, global_ad_path(uid, type), ~s({"v":3}), "application/json; charset=utf-8", t)
      assert c.status == 200
      assert json(get_global_ad(uid, t, type)) == %{"v" => 3}
    end
  end
end
