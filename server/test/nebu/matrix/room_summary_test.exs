defmodule Nebu.Matrix.RoomSummaryTest do
  @moduledoc """
  Unit acceptance tests for story `oauth-room-summary-unrecognized` (epic oauth-broker,
  gate ac): `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` (Matrix v1.15 core, local only).
  Covers AC2.1/2.3/2.6 (the pure builder), AC1.2/1.3, AC4.1/4.3, AC5.3, AC6, AC7 and AC15 at the
  HTTP level with INJECTED seams (no DB, no Room process), plus the OPTIONS rule of AC10.3 for this
  route. Visibility, aliases against a real DB and the full 200 shapes live in
  `room_summary_integration_test.exs`.

  ## Contracts pinned here (the implementation MUST honour them)

    * `Nebu.Matrix.RoomSummary.build(room_id, state_events, %{num_joined_members: n, membership: m})`
      is PURE (no DB, no process) and returns the JSON-ready, string-keyed map of RU5. `state_events`
      is the list `Nebu.Matrix.EventDispatcher.Server.build_state_events/3` produces
      (`%Core.SyncRoomStateEvent{type, state_key, content (JSON string)}`).
    * `Nebu.Matrix.EventDispatcher.Server.get_room_summary/2` resolves an alias through the injectable
      `:event_dispatcher, :alias_db_module` (`lookup_alias/1`), checks `get_room_status/1` of the
      injectable `:rooms_db_module` BEFORE it touches the injectable `:room_registry_module`
      (`get_state/1`, RU3 trap 1) and raises `Nebu.Matrix.Error` (not_found) for an unknown, archived or
      hidden room: the router answers the byte-identical `404 M_NOT_FOUND "Room not found"`.
    * The route is `get "/client/v1/room_summary/:room_id_or_alias"` in `Nebu.Web.Router.Protected`
      with a per-user `Nebu.Web.Plugs.RateLimit` (tier `room_summary`, 300/min, burst 60, `key: :user`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "room-summary-unit-key-1"
  @router_opts Nebu.Web.Router.init([])
  @bucket_table :nebu_http_rate_limit_buckets

  @not_found_body %{"errcode" => "M_NOT_FOUND", "error" => "Room not found"}

  # ── injected fakes ────────────────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc false
    # Plays rooms_db_module AND alias_db_module (get_room_status/1 + lookup_alias/1), and the
    # invite / messages seams, recording every call in the test process.
    defp note(msg), do: if(pid = Application.get_env(:room_summary_atdd, :pid), do: send(pid, msg))

    def get_room_status(room_id) do
      note({:db, :get_room_status, room_id})
      Application.get_env(:room_summary_atdd, :room_status, {:error, :not_found})
    end

    def lookup_alias(alias_str) do
      note({:db, :lookup_alias, alias_str})
      Application.get_env(:room_summary_atdd, :alias_result, {:error, :not_found})
    end

    def pending_invite?(room_id, user_id) do
      note({:db, :pending_invite?, room_id, user_id})
      {:ok, false}
    end

    def get_room_creator(room_id) do
      note({:db, :get_room_creator, room_id})
      {:error, :not_found}
    end

    def get_room_create_event(room_id) do
      note({:db, :get_room_create_event, room_id})
      {:error, :not_found}
    end
  end

  defmodule FakeRegistry do
    @moduledoc false
    # `get_state/1` is the first thing that may lazy-start a Room (and insert a `rooms` row): it
    # must NEVER be reached for an unknown / archived room or an unresolvable alias.
    def get_state(room_id) do
      if pid = Application.get_env(:room_summary_atdd, :pid), do: send(pid, {:registry, :get_state, room_id})
      exit({:noproc, {GenServer, :call, [room_id, :get_state, 5000]}})
    end
  end

  defp tag_db_error(error) do
    Application.put_env(:room_summary_atdd, :room_status, {:error, error})
  end

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => @kid, "alg" => "RS256", "use" => "sig"})

    Application.put_env(:nebu_http, :server_name, @server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    Application.put_env(:room_summary_atdd, :pid, self())
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :room_registry_module, FakeRegistry)

    T.reset_rate_limits()

    on_exit(fn ->
      for k <- [:server_name, :oidc_jwks], do: Application.delete_env(:nebu_http, k)
      Nebu.Web.OidcTestSupport.clear()

      for k <- [:rooms_db_module, :alias_db_module, :invite_db_module, :messages_db_module, :room_registry_module],
          do: Application.delete_env(:event_dispatcher, k)

      Application.delete_env(:room_summary_atdd, :pid)
      Application.delete_env(:room_summary_atdd, :room_status)
      Application.delete_env(:room_summary_atdd, :alias_result)
      T.restore_rate_limits()
    end)

    {:ok, priv: priv_map |> Map.put("kid", @kid)}
  end

  defp token_for(sub, priv) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second)
    }

    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv), %{"alg" => "RS256", "kid" => @kid}, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    {"@#{sub}:#{@server_name}", compact}
  end

  defp req(method, path, token \\ nil, opts \\ []) do
    conn(method, path)
    |> put_req_header("origin", "https://app.example.com")
    |> then(fn c -> if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c end)
    |> Map.put(:remote_ip, Keyword.get(opts, :ip, T.unique_ip()))
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp summary_path(raw), do: "/_matrix/client/v1/room_summary/" <> raw
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp ctype(conn), do: conn |> get_resp_header("content-type") |> List.first() |> to_string()

  defp ev(type, state_key, content) do
    %Core.SyncRoomStateEvent{
      type: type,
      state_key: state_key,
      content: Jason.encode!(content),
      sender: "@creator:#{@server_name}",
      event_id: "$" <> type,
      origin_server_ts: 1
    }
  end

  defp create_ev(extra \\ %{}), do: ev("m.room.create", "", Map.merge(%{"creator" => "@creator:#{@server_name}"}, extra))

  defp build(events, ctx \\ %{}) do
    ctx = Map.merge(%{num_joined_members: 1, membership: "join"}, ctx)
    Nebu.Matrix.RoomSummary.build("!r:#{@server_name}", events, ctx)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 / RU5 — the pure builder
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2.1/RU5 — Nebu.Matrix.RoomSummary.build/3 shape" do
    test "a fully described public room has exactly the RU5 keys with their spec types" do
      events = [
        create_ev(%{"room_version" => "10"}),
        ev("m.room.name", "", %{"name" => "Lobby"}),
        ev("m.room.topic", "", %{"topic" => "Hello"}),
        ev("m.room.avatar", "", %{"url" => "mxc://test.local/abc"}),
        ev("m.room.canonical_alias", "", %{"alias" => "#lobby:test.local"}),
        ev("m.room.join_rules", "", %{"join_rule" => "public"})
      ]

      s = build(events, %{num_joined_members: 3})

      assert s |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(room_id num_joined_members guest_can_join world_readable join_rule room_version membership name topic avatar_url canonical_alias))

      assert s["room_id"] == "!r:#{@server_name}"
      assert s["num_joined_members"] == 3
      assert s["guest_can_join"] === false
      assert s["world_readable"] === false
      assert s["join_rule"] == "public"
      assert s["room_version"] == "10"
      assert s["membership"] == "join"
      assert {s["name"], s["topic"], s["avatar_url"], s["canonical_alias"]} == {"Lobby", "Hello", "mxc://test.local/abc", "#lobby:test.local"}
    end

    test "a bare room: optional keys are ABSENT (never null, never empty), join_rule defaults to invite, room_version to \"1\"" do
      s = build([create_ev()])

      assert s |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(room_id num_joined_members guest_can_join world_readable join_rule room_version membership))

      assert s["join_rule"] == "invite"
      assert s["room_version"] == "1"
      refute Enum.any?(s, fn {_k, v} -> v in [nil, ""] end), "no null / empty value anywhere: #{inspect(s)}"
    end

    test "empty name / avatar / canonical alias events are omitted, not echoed as empty strings" do
      events = [
        create_ev(),
        ev("m.room.name", "", %{"name" => ""}),
        ev("m.room.avatar", "", %{}),
        ev("m.room.canonical_alias", "", %{"alias" => ""})
      ]

      s = build(events)
      refute Map.has_key?(s, "name")
      refute Map.has_key?(s, "avatar_url")
      refute Map.has_key?(s, "canonical_alias")
    end

    test "AC2.2: a space adds room_type m.space (from the create content)" do
      assert build([create_ev(%{"type" => "m.space"})])["room_type"] == "m.space"
      refute Map.has_key?(build([create_ev()]), "room_type")
    end

    test "guest_can_join / world_readable come from m.room.guest_access / m.room.history_visibility" do
      s = build([create_ev(), ev("m.room.guest_access", "", %{"guest_access" => "can_join"}), ev("m.room.history_visibility", "", %{"history_visibility" => "world_readable"})])
      assert s["guest_can_join"] === true
      assert s["world_readable"] === true
    end

    test "num_joined_members and membership are taken from the context, whatever its value" do
      for m <- ["join", "invite", "leave", "ban", "knock"] do
        s = build([create_ev()], %{num_joined_members: 7, membership: m})
        assert {s["num_joined_members"], s["membership"]} == {7, m}
      end
    end

    test "never carries children_state, aliases or im.nheko.summary.* keys, even for a space with children" do
      events = [create_ev(%{"type" => "m.space"}), ev("m.space.child", "!c:test.local", %{"via" => ["test.local"]})]
      keys = build(events) |> Map.keys()
      refute "children_state" in keys
      refute "aliases" in keys
      refute Enum.any?(keys, &String.starts_with?(&1, "im.nheko.summary"))
    end

    test "encryption only for the megolm algorithm; every other algorithm is omitted" do
      assert build([create_ev(), ev("m.room.encryption", "", %{"algorithm" => "m.megolm.v1.aes-sha2"})])["encryption"] == "m.megolm.v1.aes-sha2"
      refute Map.has_key?(build([create_ev(), ev("m.room.encryption", "", %{"algorithm" => "other"})]), "encryption")
      refute Map.has_key?(build([create_ev()]), "encryption")
    end
  end

  describe "AC2.5/RU5 — allowed_room_ids only for restricted / knock_restricted" do
    defp restricted(rule, allow), do: [create_ev(), ev("m.room.join_rules", "", %{"join_rule" => rule, "allow" => allow})]

    test "restricted and knock_restricted list the room_id of the m.room_membership allow entries" do
      allow = [%{"type" => "m.room_membership", "room_id" => "!space:test.local"}, %{"type" => "other", "room_id" => "!ignored:test.local"}]

      for rule <- ["restricted", "knock_restricted"] do
        s = build(restricted(rule, allow))
        assert s["join_rule"] == rule
        assert s["allowed_room_ids"] == ["!space:test.local"], rule
      end
    end

    test "public, invite and knock rooms never carry allowed_room_ids, even with a stray allow list" do
      for rule <- ["public", "invite", "knock"] do
        refute Map.has_key?(build(restricted(rule, [%{"type" => "m.room_membership", "room_id" => "!s:test.local"}])), "allowed_room_ids"), rule
      end
    end
  end

  describe "AC2.3/RU5 — topic comes from the text/plain m.topic block, else the legacy topic" do
    defp topic_events(legacy, blocks) do
      content = %{"topic" => legacy}
      content = if blocks == :none, do: content, else: Map.put(content, "m.topic", %{"m.text" => blocks})
      [create_ev(), ev("m.room.topic", "", content)]
    end

    test "text/plain block wins over the html block and over the legacy topic" do
      blocks = [%{"mimetype" => "text/html", "body" => "<b>H</b>"}, %{"mimetype" => "text/plain", "body" => "P"}]
      assert build(topic_events("L", blocks))["topic"] == "P"
    end

    test "a block without a mimetype counts as text/plain (m.topic default)" do
      assert build(topic_events("L", [%{"body" => "NoMime"}]))["topic"] == "NoMime"
    end

    test "only an html block: the legacy topic is used, never the html body" do
      s = build(topic_events("L", [%{"mimetype" => "text/html", "body" => "<b>H</b>"}]))
      assert s["topic"] == "L"
    end

    test "empty legacy topic and no text/plain block: topic is omitted" do
      refute Map.has_key?(build(topic_events("", [%{"mimetype" => "text/html", "body" => "<b>H</b>"}])), "topic")
      refute Map.has_key?(build(topic_events("", :none)), "topic")
    end

    test "legacy topic alone is returned" do
      assert build(topic_events("Legacy", :none))["topic"] == "Legacy"
    end
  end

  describe "AC2.6/RU5 — room_version" do
    test "equals the create content value; \"1\" when the create content carries none" do
      assert build([create_ev(%{"room_version" => "11"})])["room_version"] == "11"
      assert build([create_ev(%{"room_version" => "12"})])["room_version"] == "12"
      assert build([create_ev()])["room_version"] == "1"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — route and auth (RU2)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/RU2 — authentication and methods" do
    test "AC1.2: no token => 401 M_MISSING_TOKEN, junk token => 401 M_UNKNOWN_TOKEN; the handler is never reached" do
      none = req(:get, summary_path("!r:test.local"))
      assert {none.status, json(none)["errcode"]} == {401, "M_MISSING_TOKEN"}
      junk = req(:get, summary_path("!r:test.local"), "junk")
      assert {junk.status, json(junk)["errcode"]} == {401, "M_UNKNOWN_TOKEN"}
      refute_received {:db, _, _}
      refute_received {:registry, _, _}
    end

    test "AC1.3: PUT / POST / DELETE / PATCH answer 405 M_UNRECOGNIZED + Allow: GET, OPTIONS, with and without a token", %{priv: priv} do
      {_uid, tok} = token_for("rs-methods", priv)

      for method <- [:put, :post, :delete, :patch], token <- [nil, tok] do
        c = req(method, summary_path("!r:test.local"), token)
        assert c.status == 405, "#{method} token?=#{token != nil}"
        assert json(c) == %{"errcode" => "M_UNRECOGNIZED", "error" => "Unsupported method"}
        assert allow_set(c) == MapSet.new(["GET", "OPTIONS"])
      end
    end

    test "AC10.3: a non-preflight OPTIONS => 204 + Allow, no auth, no DB, no rate-limit token, CORS header" do
      c = req(:options, summary_path("!r:test.local"))
      assert c.status == 204
      assert allow_set(c) == MapSet.new(["GET", "OPTIONS"])
      assert get_resp_header(c, "access-control-allow-origin") != []
      refute_received {:db, _, _}
      refute_received {:registry, _, _}
      assert bucket_rows() == []
    end
  end

  # The OidcPlug logs a provisioning WARNING for a JWT whose claims carry no email / name while a Repo runs
  # (integration environment); that is not the room_summary's own output. Everything else is.
  defp own_log(log), do: log |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ "OIDC:" or String.trim(&1) == ""))

  defp allow_set(conn) do
    conn |> get_resp_header("allow") |> List.first() |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  end

  defp bucket_rows, do: if(:ets.whereis(@bucket_table) == :undefined, do: [], else: :ets.tab2list(@bucket_table))

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — validation (RU8) and AC4 — existence before state (RU3)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/RU8 — validation answers 400 M_INVALID_PARAM before any DB access" do
    test "a value that is neither a !room id nor a #alias, an alias without a colon and a 256 byte value", %{priv: priv} do
      {_uid, tok} = token_for("rs-validate", priv)

      # control characters and invalid UTF-8 are 400 too, never a Postgres 22021 => 500 (review cycle 1, MINOR 2)
      for raw <- ["abc", "%24event:test.local", "%23x", "%23", "%40user:test.local", "!" <> String.duplicate("a", 255), "!%00x:test.local", "%23a%FFb:test.local", "!a%0Ab:test.local"] do
        c = req(:get, summary_path(raw), tok)
        assert c.status == 400, "#{raw} => #{c.status}"
        assert json(c)["errcode"] == "M_INVALID_PARAM"
      end

      refute_received {:db, _, _}
      refute_received {:registry, _, _}
    end

    test "a 255 byte room id is accepted (it goes on to the DB) and the RU3 404 follows", %{priv: priv} do
      {_uid, tok} = token_for("rs-validate-edge", priv)
      raw = "!" <> String.duplicate("a", 254)
      c = req(:get, summary_path(raw), tok)
      assert {c.status, json(c)} == {404, @not_found_body}
      assert_received {:db, :get_room_status, ^raw}
    end

    test "a well-formed !id without a colon (room v12) is no 400: it goes through RU3 and answers the 404", %{priv: priv} do
      {_uid, tok} = token_for("rs-v12", priv)
      c = req(:get, summary_path("!opaqueid"), tok)
      assert {c.status, json(c)} == {404, @not_found_body}
      assert_received {:db, :get_room_status, "!opaqueid"}
    end
  end

  describe "AC4/RU3 — an unknown, archived or unresolvable room never reaches the Room registry" do
    test "unknown, foreign-server and archived ids: byte-identical 404, registry untouched", %{priv: priv} do
      {_uid, tok} = token_for("rs-hidden", priv)

      answers =
        for {raw, status} <- [{"!doesnotexist:test.local", {:error, :not_found}}, {"!x:other.example", {:error, :not_found}}, {"!archived:test.local", {:ok, "archived"}}] do
          Application.put_env(:room_summary_atdd, :room_status, status)
          c = req(:get, summary_path(raw), tok)
          {c.status, c.resp_body, ctype(c)}
        end

      assert [{404, body, ct}] = Enum.uniq(answers)
      assert Jason.decode!(body) == @not_found_body
      assert ct =~ "application/json"
      refute_received {:registry, :get_state, _}
    end

    test "AC5.2: an unknown alias answers the same 404 and the room status is never asked", %{priv: priv} do
      {_uid, tok} = token_for("rs-alias-404", priv)

      for raw <- ["%23x:other.example", "%23nope:test.local"] do
        c = req(:get, summary_path(raw), tok)
        assert {c.status, json(c)} == {404, @not_found_body}, raw
      end

      assert_received {:db, :lookup_alias, "#x:other.example"}
      assert_received {:db, :lookup_alias, "#nope:test.local"}
      refute_received {:db, :get_room_status, _}
      refute_received {:registry, :get_state, _}
    end

    test "AC5.1: a resolved alias continues with the room id of the alias store", %{priv: priv} do
      {_uid, tok} = token_for("rs-alias-ok", priv)
      Application.put_env(:room_summary_atdd, :alias_result, {:ok, "!resolved:test.local"})
      c = req(:get, summary_path("%23lobby%3Atest.local"), tok)
      assert {c.status, json(c)} == {404, @not_found_body}, "the fake room store has no such room"
      assert_received {:db, :lookup_alias, "#lobby:test.local"}
      assert_received {:db, :get_room_status, "!resolved:test.local"}
    end
  end

  describe "AC6.2/AC5.3 — the path parameter is used as Plug decoded it; via is ignored" do
    test "+ and %25 resolve literally (no second www-form decoding)", %{priv: priv} do
      {_uid, tok} = token_for("rs-literal", priv)
      assert req(:get, summary_path("%23a+b%2525c:test.local"), tok).status == 404
      assert_received {:db, :lookup_alias, "#a+b%25c:test.local"}
      assert req(:get, summary_path("%23a%2Bb%3Atest.local"), tok).status == 404
      assert_received {:db, :lookup_alias, "#a+b:test.local"}
    end

    test "?via=... does not change what the handler asks the stores and does not change the answer", %{priv: priv} do
      {_uid, tok} = token_for("rs-via", priv)
      plain = req(:get, summary_path("!v:test.local"), tok)
      assert_received {:db, :get_room_status, "!v:test.local"}
      with_via = req(:get, summary_path("!v:test.local") <> "?via=matrix.org&via=other.example", tok)
      assert_received {:db, :get_room_status, "!v:test.local"}
      refute_received {:db, _, _}, "a via parameter must never cause a lookup (local only, RU1)"
      assert {plain.status, plain.resp_body} == {with_via.status, with_via.resp_body}
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC7 — rate limit (RU7)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC7/RU7 — per-user rate limit (tier room_summary, 300/min, burst 60)" do
    test "request 61 answers 429 + retry_after_ms + Retry-After; a second user on the same IP is unaffected", %{priv: priv} do
      {_uid_a, a} = token_for("rs-rl-a", priv)
      {_uid_b, b} = token_for("rs-rl-b", priv)
      ip = {10, 77, 1, 1}

      statuses = for _ <- 1..60, do: req(:get, summary_path("!rl:test.local"), a, ip: ip).status
      assert Enum.all?(statuses, &(&1 == 404)), "the first 60 requests pass the limiter (fake store: unknown room)"

      limited = req(:get, summary_path("!rl:test.local"), a, ip: ip)
      assert limited.status == 429
      assert %{"errcode" => "M_LIMIT_EXCEEDED", "retry_after_ms" => ms} = json(limited)
      assert is_integer(ms) and ms > 0
      assert limited |> get_resp_header("retry-after") |> List.first() |> String.to_integer() >= 1

      assert req(:get, summary_path("!rl:test.local"), b, ip: ip).status == 404, "the bucket is per user, not per IP"
      # the bucket key shape is deliberately NOT pinned (review m8): "second user unaffected" + Retry-After above
    end

    test "under rate_limit_disabled the limit is a no-op", %{priv: priv} do
      {_uid, tok} = token_for("rs-rl-off", priv)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)
      assert for(_ <- 1..70, do: req(:get, summary_path("!rl:test.local"), tok).status) |> Enum.all?(&(&1 == 404))
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC15 — logging law
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC15 — room_summary logs nothing of its own" do
    test "404 (unknown id, unknown alias) and 405 write no log line", %{priv: priv} do
      {_uid, tok} = token_for("rs-log-quiet", priv)

      log =
        capture_log(fn ->
          req(:get, summary_path("!logquiet:test.local"), tok)
          req(:get, summary_path("%23logquietalias:test.local"), tok)
          req(:put, summary_path("!logquiet:test.local"), tok)
        end)

      assert own_log(log) == []
    end

    test "a DB error answers 500 M_UNKNOWN and logs no alias / room name / error detail", %{priv: priv} do
      {_uid, tok} = token_for("rs-log-dberr", priv)
      Application.put_env(:room_summary_atdd, :alias_result, {:ok, "!secretroomid:test.local"})
      tag_db_error(%RuntimeError{message: "secret-db-detail-4711"})

      {conn, log} =
        with_log(fn -> req(:get, summary_path("%23secretalias%3Atest.local"), tok) end)

      assert {conn.status, json(conn)["errcode"]} == {500, "M_UNKNOWN"}
      refute log =~ "secretalias"
      refute log =~ "secretroomid"
      refute log =~ "secret-db-detail-4711", "only the error CLASS may be logged"
    end
  end
end
