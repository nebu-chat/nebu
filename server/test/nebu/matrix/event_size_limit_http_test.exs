defmodule Nebu.Matrix.EventSizeLimitHttpTest do
  @moduledoc """
  Story `event-size-limit` (epic oauth-broker, follow-up `ep`), HTTP half: AC2 (`PUT .../state`), AC3 (`PUT .../send`), AC4 (`POST /createRoom`), AC8 (a)
  (legacy rows), AC11 (c), (d) (aliases in bytes, the sender guard) and the room id length of AC1 (g), over the REAL stack (`Nebu.Web.Router` +
  `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg; users and sessions as in `member_prev_content_http_test.exs`, random users and rooms,
  `:server_name` pinned, the rate limiter reset per test).

  The story's rule (D1): an event is refused with `413 M_TOO_LARGE` BEFORE anything is persisted when `byte_size(CanonicalJson.encode!(stored_event))` is
  greater than 65 536 (the stored event: the six signed keys, `state_key` as JSON `null` for a message event, plus `event_id` and `signatures`), or when
  `type` / `state_key` (decoded, in bytes) exceed 255.

  Conventions of this suite:

    * The tests size their bodies with an INDEPENDENT helper (`stored_size/5`): it builds the stored map (a dummy 44-byte event id, a dummy 88-byte
      signature, the real room id, sender, type, state key, a 13-digit timestamp) and encodes it. Every 200 at a boundary is CONFIRMED on the STORED row
      (`stored_bytes/1`: read from `events`, both JSONB forms handled, re-encoded as D1): a pre-check that is off by the length of the event id or by
      `"state_key":null` cannot pass a test that compares the code with itself.
    * "No broadcast": the test process joins the `:pg` group `room:<id>` that every write site broadcasts to. A refused write delivers NO
      `{:new_event, _}` (`refute_receive`), the following accepted write DOES (positive control). (The story says "a long-polling /sync of another
      member does not wake": the same fact without a timed long poll.)
    * "No SQL beyond the authentication": the `[:nebu, :repo, :query]` statements of the request process are counted (`count_statements/1`) and compared
      with a malformed-body request (`400`) of the same user on the same route; none of them touches `events`, `rooms` or `room_members`.
    * Rate limits: a refused createRoom still spends a `create_room` token (burst 20 per user): no test creates more than 20 rooms per user, the limiter is
      reset per test. Random markers; no fixed sleeps.

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC1 (g) (the room id length) is pinned here through a real createRoom for two server names (`generate_room_id/0` is private).
    * AC5 (d): `Nebu.Matrix.create_room/2` and `create_space/2` cannot carry a client `initial_state` / `creation_content` (their content is fixed), so the
      createRoom refusal of the Admin path is pinned at the core (`event_size_backstop_test.exs`).
    * AC11 (c) "a derived alias from a 300-character name": a `name` is capped at 255 code points, so the test uses a 255-character name.
    * AC4 (j) "the refused createRoom still spent one `create_room` token" is pinned with the bucket level of the user.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Nebu.Matrix.CanonicalJson
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @router_opts Nebu.Web.Router.init([])
  @create "/_matrix/client/v3/createRoom"
  @table :nebu_http_rate_limit_buckets
  @origin "https://client.example.com"

  @t_event "Event exceeds the maximum size of 65536 bytes"
  @t_type "Event type exceeds 255 bytes"
  @t_key "State key exceeds 255 bytes"
  @t_is_type "An initial_state event type exceeds 255 bytes"
  @t_is_key "An initial_state state key exceeds 255 bytes"
  @t_is_event "An initial_state event exceeds the maximum size of 65536 bytes"
  @t_create "creation_content makes the m.room.create event exceed the maximum size of 65536 bytes"
  @t_levels "power_level_content_override makes the m.room.power_levels event exceed the maximum size of 65536 bytes"
  @t_sender "Your user id exceeds 255 bytes: sign in again"

  @euro "€"

  # the audit writer of the test environment is a no-op: a spy makes "no room_created audit row" a real assertion (createRoom runs in the test process)
  defmodule AuditSpy do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      pid = Application.get_env(:compliance, :__event_size_audit_pid__)
      if pid && Process.alive?(pid), do: send(pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    prior = for key <- [:audit_writer, :__event_size_audit_pid__], do: {key, Application.fetch_env(:compliance, key)}
    Application.put_env(:compliance, :audit_writer, AuditSpy)
    Application.put_env(:compliance, :__event_size_audit_pid__, self())

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- prior do
        case previous do
          {:ok, value} -> Application.put_env(:compliance, key, value)
          :error -> Application.delete_env(:compliance, key)
        end
      end
    end)

    {:ok, a: user!("ESA"), c: user!("ESC")}
  end

  # ─── users, requests ──────────────────────────────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp server, do: Application.get_env(:event_dispatcher, :server_name, "nebu.local")
  defp enc(s), do: URI.encode_www_form(s)

  defp req(method, path, raw_body, user, opts) do
    c =
      conn(method, path, raw_body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> user.at)

    c = if origin = opts[:origin], do: put_req_header(c, "origin", origin), else: c
    Nebu.Web.Router.call(%{c | remote_ip: T.unique_ip()}, @router_opts)
  end

  defp state_path(room, type, key), do: "/_matrix/client/v3/rooms/#{enc(room)}/state/#{type}" <> if(key == :none, do: "", else: "/" <> key)
  defp send_path(room, type, txn), do: "/_matrix/client/v3/rooms/#{enc(room)}/send/#{type}/#{txn}"

  # `type` and `key` are PATH segments: pass them already percent-encoded where it matters
  defp put_state(user, room, type, key, content, opts \\ []), do: req(:put, state_path(room, type, key), body(content), user, opts)
  defp put_send(user, room, type, txn, content, opts \\ []), do: req(:put, send_path(room, type, txn), body(content), user, opts)
  defp create(user, body, opts \\ []), do: req(:post, @create, body(body), user, opts)

  defp body(raw) when is_binary(raw), do: raw
  defp body(map), do: Jason.encode!(map)

  defp make_room(user, body \\ %{"preset" => "private_chat"}) do
    conn = create(user, body)
    assert conn.status == 200, "createRoom: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp sync(user) do
    conn = T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0", user.at)
    assert conn.status == 200, "sync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)
  end

  # the CURRENT content of a state slot as the user's initial /sync delivers it (nil when absent)
  defp synced_state(user, room, type, key) do
    events = get_in(sync(user), ["rooms", "join", room, "state", "events"]) || []

    case Enum.find(events, &(&1["type"] == type and &1["state_key"] == key)) do
      nil -> nil
      ev -> ev
    end
  end

  # ─── the independent size accounting of the tests ────────────────────────────────────────

  @dummy_event_id "$" <> String.duplicate("A", 43)
  @dummy_signature String.duplicate("B", 88)
  @ts13 1_700_000_000_000

  # the size of the STORED event: the six signed keys + event_id + signatures, in canonical JSON (D1), computed here
  defp stored_size(room, sender, type, state_key, content) do
    %{
      "room_id" => room,
      "type" => type,
      "state_key" => state_key,
      "sender" => sender,
      "content" => content,
      "origin_server_ts" => @ts13,
      "event_id" => @dummy_event_id,
      "signatures" => %{"nebu" => @dummy_signature}
    }
    |> CanonicalJson.encode!()
    |> byte_size()
  end

  # `base` plus a pad string (key "pad", or `pad_key`) so that the stored event is EXACTLY `target` bytes; :ascii | :euro (3-byte characters) | :eacute
  # (2-byte characters), then ASCII for the rest
  defp padded(room, sender, type, state_key, base, target, kind \\ :ascii), do: padded_with("pad", room, sender, type, state_key, base, target, kind)

  defp padded_with(pad_key, room, sender, type, state_key, base, target, kind) do
    needed = target - stored_size(room, sender, type, state_key, Map.put(base, pad_key, ""))
    assert needed >= 0, "target #{target} is below the empty event"

    pad =
      case kind do
        :ascii -> String.duplicate("a", needed)
        :euro -> String.duplicate(@euro, div(needed, 3)) <> String.duplicate("a", rem(needed, 3))
        :eacute -> String.duplicate("é", div(needed, 2)) <> String.duplicate("a", rem(needed, 2))
      end

    content = Map.put(base, pad_key, pad)
    assert stored_size(room, sender, type, state_key, content) == target
    content
  end

  defp child_base, do: %{"via" => [server()]}

  defp content_of(c) when is_map(c), do: c

  defp content_of(c) when is_binary(c) do
    case Jason.decode!(c) do
      decoded when is_binary(decoded) -> content_of(decoded)
      decoded -> decoded
    end
  end

  defp stored_map([event_id, room_id, sender, type, content, ts, signatures, state_key]) do
    %{
      "event_id" => event_id,
      "room_id" => room_id,
      "sender" => sender,
      "type" => type,
      "content" => content_of(content),
      "origin_server_ts" => ts,
      "signatures" => content_of(signatures),
      "state_key" => state_key
    }
  end

  @columns "event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key"

  # the STORED row re-encoded as D1, in bytes
  defp stored_bytes(event_id) do
    [row] = T.sql!("SELECT #{@columns} FROM events WHERE event_id = $1", [event_id]).rows
    row |> stored_map() |> CanonicalJson.encode!() |> byte_size()
  end

  defp stored_bytes_in(room, type, key) do
    [row] = T.sql!("SELECT #{@columns} FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3", [room, type, key]).rows
    row |> stored_map() |> CanonicalJson.encode!() |> byte_size()
  end

  defp stored_content(event_id), do: T.sql!("SELECT content FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd() |> content_of()

  defp event_count(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
  defp slot_count(room, type, key), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3", [room, type, key]).rows |> hd() |> hd()
  defp room_row_count(room), do: T.sql!("SELECT count(*) FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # rooms created by `uid` (the m.room.create events of the user's rooms): createRoom must not leave one behind when refused
  defp created_rooms(uid), do: T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [uid]).rows |> hd() |> hd()

  # ─── the 413 assertion (AC2 (j): status, content type, exactly errcode + error) ────────────────

  defp assert_413(conn, text, marker \\ nil) do
    assert conn.status == 413, "expected 413 #{inspect(text)}, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 300)}"
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}, "content-type #{inspect(T.header(conn, "content-type"))}"
    body = Jason.decode!(conn.resp_body)
    assert Enum.sort(Map.keys(body)) == ["errcode", "error"], "exactly errcode and error: #{conn.resp_body}"
    assert body["errcode"] == "M_TOO_LARGE"
    assert body["error"] == text
    if marker, do: refute(conn.resp_body =~ marker, "the 413 must not echo a client value (#{marker})")
    conn
  end

  defp cors_headers(conn), do: conn.resp_headers |> Enum.filter(fn {k, _} -> String.starts_with?(k, "access-control-") end) |> Enum.sort()

  # ─── statement counting (as in member_prev_content_http_test.exs) ──────────────────────────────

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid}) do
    mine? = self() == pid or pid in (Process.get(:"$callers") || [])
    if mine? and not noise?(query), do: send(pid, {:statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp noise?(query), do: query in ["begin", "commit", "rollback"] or String.contains?(query, "operational_logs") or String.contains?(query, "\"audit_log\"")

  defp count_statements(fun) do
    id = "es-http-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:statement, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp listing(statements), do: statements |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.slice(0, 120))) |> Enum.join("\n")

  # a refused request runs exactly the statements of a malformed-body request of the same user on the same route
  # (the authentication), and none of them touches the room tables
  defp assert_no_room_work(statements, baseline, label) do
    assert length(statements) == length(baseline),
           "#{label}: #{length(statements)} statements, the malformed-body baseline runs #{length(baseline)}:\n#{listing(statements)}\n--- baseline ---\n#{listing(baseline)}"

    for s <- statements do
      refute Regex.match?(~r/\b(events|rooms|room_members)\b/, s), "#{label}: a statement touches the room tables: #{String.slice(s, 0, 160)}"
    end
  end

  defp watch_room!(room), do: :ok = :pg.join("room:" <> room, self())

  # ═══ AC2 (a): the boundary ══════════════════════════════════════════════════════════════════

  describe "AC2 (a) - PUT state boundary: 65 536 bytes of the STORED event" do
    test "m.space.child of exactly 65 536 -> 200 (stored row 65 536); one byte more -> 413, fixed text, nothing written, nothing broadcast, slot unchanged", %{a: a} do
      room = make_room(a)
      key = "!child:" <> server()
      watch_room!(room)

      small = put_state(a, room, "m.space.child", enc(key), %{"via" => [server()], "pad" => "before"})
      assert small.status == 200, small.resp_body
      assert_receive {:new_event, %{"event_id" => _}}, 2_000

      exact = padded(room, a.uid, "m.space.child", key, child_base(), 65_536)
      ok = put_state(a, room, "m.space.child", enc(key), exact)
      assert ok.status == 200, "exactly 65 536 bytes must be accepted: #{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      id = T.json(ok)["event_id"]
      assert stored_bytes(id) == 65_536, "the STORED row re-encoded as D1 is exactly the limit"
      assert_receive {:new_event, %{"event_id" => ^id}}, 2_000

      events = event_count(room)
      slots = slot_count(room, "m.space.child", key)
      one_more = padded(room, a.uid, "m.space.child", key, child_base(), 65_537)
      assert_413(put_state(a, room, "m.space.child", enc(key), one_more), @t_event)

      assert event_count(room) == events, "no events row"
      assert slot_count(room, "m.space.child", key) == slots
      refute_receive {:new_event, _}, 200
      assert synced_state(a, room, "m.space.child", key)["event_id"] == id, "the slot's current event is unchanged"
    end

    test "65 535 bytes is accepted too (the limit is not off by one in the other direction)", %{a: a} do
      room = make_room(a)
      key = "!child:" <> server()
      content = padded(room, a.uid, "m.space.child", key, child_base(), 65_535)
      ok = put_state(a, room, "m.space.child", enc(key), content)
      assert ok.status == 200, ok.resp_body
      assert stored_bytes(T.json(ok)["event_id"]) == 65_535
    end
  end

  describe "AC2 (b) - multi-byte boundary" do
    test "padding of 3-byte characters at exactly 65 536 bytes (far fewer code points than bytes) -> 200 and stored 65 536; one byte more -> 413", %{a: a} do
      room = make_room(a)
      key = "!euro:" <> server()

      exact = padded(room, a.uid, "m.space.child", key, child_base(), 65_536, :euro)
      assert String.length(exact["pad"]) < 30_000, "far fewer code points than bytes"
      ok = put_state(a, room, "m.space.child", enc(key), exact)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes(T.json(ok)["event_id"]) == 65_536

      one_more = padded(room, a.uid, "m.space.child", key, child_base(), 65_537, :euro)
      assert_413(put_state(a, room, "m.space.child", enc(key), one_more), @t_event)
    end

    test "a content that would fit as CODE POINTS (65 536 characters) but not as bytes is refused", %{a: a} do
      room = make_room(a)
      content = %{"via" => [server()], "pad" => String.duplicate("é", 40_000)}
      assert_413(put_state(a, room, "m.space.child", enc("!cp:" <> server()), content), @t_event)
    end
  end

  # ═══ AC2 (c): canonical, not body ═══════════════════════════════════════════════════════════

  describe "AC2 (c) - the size is the CANONICAL form, not the request body" do
    test "a body above 65 536 bytes whose padding is written as \\u00e9 escapes (6 body bytes, 2 canonical) and whose canonical size is exactly 65 536 -> 200", %{a: a} do
      room = make_room(a)
      key = "!esc:" <> server()
      exact = padded(room, a.uid, "m.space.child", key, child_base(), 65_536, :eacute)

      # the same content, every e-acute written as a \\u00e9 escape (6 body bytes, 2 canonical bytes) and the ASCII rest as is
      raw = ~s({"via":["#{server()}"],"pad":") <> String.replace(exact["pad"], "é", "\\u00e9") <> ~s("})
      assert byte_size(raw) > 65_536 + 20_000, "the body is far above the limit"

      ok = put_state(a, room, "m.space.child", enc(key), raw)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes(T.json(ok)["event_id"]) == 65_536
    end

    test "a body with 10 KB of insignificant whitespace and a canonical size of exactly 65 536 -> 200", %{a: a} do
      room = make_room(a)
      key = "!ws:" <> server()
      exact = padded(room, a.uid, "m.space.child", key, child_base(), 65_536)
      raw = String.duplicate(" ", 5_000) <> Jason.encode!(exact) <> String.duplicate("\n", 5_000)
      assert byte_size(raw) > 65_536 + 9_000

      ok = put_state(a, room, "m.space.child", enc(key), raw)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes(T.json(ok)["event_id"]) == 65_536
    end

    # Premise check of the ATDD step: the story says "first value 70 000 bytes, second x -> 200, stored x" (last one wins). Jason (the parser of
    # Plug.Parsers) keeps the FIRST value of a duplicate key (verified: Jason.decode!(~s({"a":"1","a":"2"})) == %{"a" => "1"}). The intent of the story
    # ("the size is measured after the decode, not on the body") is pinned with BOTH orders.
    test "a duplicate key is measured after the decode (Jason keeps the FIRST value): first x, second 70 000 bytes -> 200 and stored x; the other order -> 413", %{a: a} do
      room = make_room(a)
      key = "!dup:" <> server()
      raw = ~s({"via":["#{server()}"],"pad":"x","pad":"#{String.duplicate("a", 70_000)}"})
      assert byte_size(raw) > 70_000

      ok = put_state(a, room, "m.space.child", enc(key), raw)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_content(T.json(ok)["event_id"]) == %{"via" => [server()], "pad" => "x"}

      reversed = ~s({"via":["#{server()}"],"pad":"#{String.duplicate("a", 70_000)}","pad":"x"})
      assert_413(put_state(a, room, "m.space.child", enc("!dup2:" <> server()), reversed), @t_event)
    end

    test "a body below 65 536 bytes that exceeds it through floats (1e2 becomes 100.0) is 413, with fewer floats 200 (pins the float rendering, follow-up fn)", %{a: a} do
      room = make_room(a)
      many = ~s({"via":["#{server()}"],"floats":[) <> Enum.map_join(1..14_000, ",", fn _ -> "1e2" end) <> "]}"
      assert byte_size(many) < 65_536
      assert_413(put_state(a, room, "m.space.child", enc("!f1:" <> server()), many), @t_event)

      fewer = ~s({"via":["#{server()}"],"floats":[) <> Enum.map_join(1..9_000, ",", fn _ -> "1e2" end) <> "]}"
      ok = put_state(a, room, "m.space.child", enc("!f2:" <> server()), fewer)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes(T.json(ok)["event_id"]) < 65_536
    end

    test "a content of C0 control characters below 65 536 code points whose canonical form (6 bytes each) exceeds the limit is 413; fewer characters are 200", %{a: a} do
      room = make_room(a)
      too_many = ~s({"via":["#{server()}"],"pad":") <> String.duplicate("\\u0001", 12_000) <> ~s("})
      assert_413(put_state(a, room, "m.space.child", enc("!c1:" <> server()), too_many), @t_event)

      fits = ~s({"via":["#{server()}"],"pad":") <> String.duplicate("\\u0001", 9_000) <> ~s("})
      ok = put_state(a, room, "m.space.child", enc("!c2:" <> server()), fits)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes(T.json(ok)["event_id"]) > 54_000
    end
  end

  # ═══ AC2 (d), (e): topic caps do not bound bytes; the keys ══════════════════════════════════

  describe "AC2 (d) - m.room.topic within the code-point caps is still refused by bytes" do
    test "topic of 1024 C0 controls plus m.topic of 8 bodies of 4096 C0 controls (196 608 escaped bytes) -> 413; a small topic is 200", %{a: a} do
      room = make_room(a)
      c0 = fn n -> String.duplicate("\\u0001", n) end

      bodies = Enum.map_join(1..8, ",", fn _ -> ~s({"body":"#{c0.(4096)}","mimetype":"text/plain"}) end)
      raw = ~s({"topic":"#{c0.(1024)}","m.topic":{"m.text":[#{bodies}]}})
      assert byte_size(raw) < 1_000_000

      assert_413(put_state(a, room, "m.room.topic", :none, raw), @t_event)

      ok = put_state(a, room, "m.room.topic", :none, %{"topic" => "a small topic"})
      assert ok.status == 200, ok.resp_body
    end
  end

  describe "AC2 (e) - type and state_key are limited to 255 BYTES" do
    test "a state_key of 255 bytes (85 x euro) -> 200 and stored; 256 bytes -> 413 \"State key exceeds 255 bytes\"", %{a: a} do
      room = make_room(a)
      key255 = String.duplicate(@euro, 85)
      assert byte_size(key255) == 255

      ok = put_state(a, room, "m.space.child", enc(key255), child_base())
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      id = T.json(ok)["event_id"]
      assert T.sql!("SELECT state_key FROM events WHERE event_id = $1", [id]).rows == [[key255]]

      events = event_count(room)
      assert_413(put_state(a, room, "m.space.child", enc(key255 <> "a"), child_base()), @t_key)
      assert event_count(room) == events
    end

    test "a type of 256 bytes -> 413 BEFORE the allowlist 403 (pinned order); a type of 255 bytes passes the size check and meets the allowlist", %{a: a} do
      room = make_room(a)
      type255 = "org.example.long." <> String.duplicate("t", 255 - 17)
      assert byte_size(type255) == 255

      assert_413(put_state(a, room, type255 <> "x", "k", %{"a" => 1}), @t_type)

      allowlist = put_state(a, room, type255, "k", %{"a" => 1})
      assert allowlist.status == 403, "255 bytes is within the limit: the allowlist answers (403), not a 413: #{allowlist.status}"
      assert T.json(allowlist)["errcode"] == "M_FORBIDDEN"
    end

    test "the 413 messages are fixed texts: a marker in the type, the state key and the content never comes back", %{a: a} do
      room = make_room(a)
      marker = "MARK" <> T.rand(6)

      long_type = marker <> String.duplicate("t", 260)
      long_key = marker <> String.duplicate("k", 260)

      assert_413(put_state(a, room, long_type, "k", %{"m" => marker}), @t_type, marker)
      assert_413(put_state(a, room, "m.space.child", enc(long_key), %{"via" => [server()], "m" => marker}), @t_key, marker)
      assert_413(put_state(a, room, "m.space.child", enc("!m:" <> server()), %{"via" => [server()], "m" => marker, "pad" => String.duplicate("p", 70_000)}), @t_event, marker)
    end
  end

  # ═══ AC2 (f): the order ═════════════════════════════════════════════════════════════════════

  describe "AC2 (f) - order: first failure wins" do
    test "order: encryption 403 first, NUL in the path key 400, 33-deep content 400, NUL in the content 400, each before the size 413", %{a: a} do
      room = make_room(a)
      big = String.duplicate("p", 70_000)

      enc_conn = put_state(a, room, "m.room.encryption", :none, %{"algorithm" => "m.megolm.v1.aes-sha2", "pad" => big})
      assert enc_conn.status == 403, "#{enc_conn.status} #{String.slice(enc_conn.resp_body, 0, 200)}"

      nul = put_state(a, room, "m.space.child", String.duplicate("a", 255) <> "%00", child_base())
      assert nul.status == 400, "#{nul.status} #{nul.resp_body}"
      assert T.json(nul)["errcode"] == "M_BAD_JSON"

      deep = Enum.reduce(1..33, %{}, fn _, acc -> %{"a" => acc} end)
      too_deep = put_state(a, room, "m.space.child", enc("!d:" <> server()), Map.put(deep, "pad", big))
      assert too_deep.status == 400, "#{too_deep.status} #{String.slice(too_deep.resp_body, 0, 200)}"
      assert T.json(too_deep)["errcode"] == "M_BAD_JSON"

      nul_content = put_state(a, room, "m.space.child", enc("!n:" <> server()), ~s({"via":["x"],"nul":"a\\u0000b","pad":"#{big}"}))
      assert nul_content.status == 400, "#{nul_content.status} #{String.slice(nul_content.resp_body, 0, 200)}"
      assert T.json(nul_content)["errcode"] == "M_BAD_JSON"
    end

    test "the type / state_key 413 comes before the depth 400 and the non-member 403 (256-byte keys with a 33-deep content, from a non-member)", %{a: a, c: c} do
      room = make_room(a)
      deep = Enum.reduce(1..33, %{}, fn _, acc -> %{"a" => acc} end)

      assert_413(put_state(a, room, "m.space.child", enc(String.duplicate("k", 256)), deep), @t_key)
      assert_413(put_state(a, room, String.duplicate("t", 256), "k", deep), @t_type)
      assert_413(put_state(c, room, String.duplicate("t", 256), "k", %{"a" => 1}), @t_type)
      assert_413(put_state(c, room, "m.space.child", enc(String.duplicate("k", 256)), child_base()), @t_key)
      assert_413(put_send(c, room, String.duplicate("t", 256), "nm1", %{"body" => "x"}), @t_type)
    end

    test "an oversized body from a NON-member is 413; a small body from the same non-member is 403 (positive control)", %{a: a, c: c} do
      room = make_room(a)
      big = padded(room, c.uid, "m.space.child", "!x:" <> server(), child_base(), 65_537)

      assert_413(put_state(c, room, "m.space.child", enc("!x:" <> server()), big), @t_event)

      small = put_state(c, room, "m.space.child", enc("!x:" <> server()), child_base())
      assert small.status == 403, "#{small.status} #{small.resp_body}"
    end

    test "an oversized body to an UNKNOWN room id is 413 and NO rooms row exists for that id afterwards (the pre-check runs before the lazy start of a Room)", %{a: a} do
      unknown = "!unknown" <> T.rand(6) <> ":" <> server()
      big = padded(unknown, a.uid, "m.space.child", "!x:" <> server(), child_base(), 65_537)

      assert_413(put_state(a, unknown, "m.space.child", enc("!x:" <> server()), big), @t_event)
      assert room_row_count(unknown) == 0, "no rooms row was created for the unknown id"
      assert event_count(unknown) == 0
      # (no positive control with a small body here: that request WOULD lazy-start a Room and leave a stale 0-member rooms row behind in the shared database)
    end
  end

  # ═══ AC2 (g): no room work on refusal ═══════════════════════════════════════════════════════

  describe "AC2 (g) / AC3 (e) - a 413 runs no statement beyond the authentication" do
    test "PUT state: size, key, type, non-member and unknown-room 413s run exactly the statements of a malformed-body 400, none on the room tables", %{a: a, c: c} do
      room = make_room(a)
      unknown = "!unknown" <> T.rand(6) <> ":" <> server()
      key = "!k:" <> server()
      big = fn r, u -> padded(r, u.uid, "m.space.child", key, child_base(), 65_537) end

      # warm-up: the first request of a session may fill caches
      assert put_state(a, room, "m.space.child", enc(key), child_base()).status == 200
      assert put_state(c, room, "m.space.child", enc(key), child_base()).status == 403

      {baseline_a, base_a} = count_statements(fn -> put_state(a, room, "m.space.child", enc(key), "{") end)
      assert baseline_a.status == 400
      {baseline_c, base_c} = count_statements(fn -> put_state(c, room, "m.space.child", enc(key), "{") end)
      assert baseline_c.status == 400
      assert base_a != [], "positive control: the authentication runs statements (the baseline is not trivially empty)"

      cases = [
        {"size", a, base_a, fn -> put_state(a, room, "m.space.child", enc(key), big.(room, a)) end},
        {"state key", a, base_a, fn -> put_state(a, room, "m.space.child", enc(String.duplicate("k", 256)), child_base()) end},
        {"type", a, base_a, fn -> put_state(a, room, String.duplicate("t", 256), "k", %{}) end},
        {"non-member", c, base_c, fn -> put_state(c, room, "m.space.child", enc(key), big.(room, c)) end},
        {"unknown room", a, base_a, fn -> put_state(a, unknown, "m.space.child", enc(key), big.(unknown, a)) end}
      ]

      for {label, _user, baseline, fun} <- cases do
        {conn, statements} = count_statements(fun)
        assert conn.status == 413, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert_no_room_work(statements, baseline, "state #{label}")
      end
    end

    test "PUT /send: the size 413 and the type 413 run exactly the statements of a malformed-body 400, none on events, rooms or room_members", %{a: a} do
      room = make_room(a)
      big = %{"msgtype" => "m.text", "body" => String.duplicate("a", 66_000)}

      assert put_send(a, room, "m.room.message", "warm1", %{"msgtype" => "m.text", "body" => "warm"}).status == 200

      {baseline, base} = count_statements(fn -> put_send(a, room, "m.room.message", "bad1", "{") end)
      assert baseline.status == 400
      assert base != []

      cases = [
        {"size", fn -> put_send(a, room, "m.room.message", "big1", big) end},
        {"type", fn -> put_send(a, room, String.duplicate("t", 256), "long1", %{"body" => "x"}) end}
      ]

      for {label, fun} <- cases do
        {conn, statements} = count_statements(fun)
        assert conn.status == 413, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert_no_room_work(statements, base, "send #{label}")
      end
    end
  end

  # ═══ AC2 (h), (i): percent-encoded paths, state_key "", surrogates ════════════════════════════

  describe "AC2 (h) - percent-encoded path values are counted DECODED" do
    test "a state_key of 85 x %E2%82%AC (255 bytes after decoding, 765 in the path) -> 200, 86 x -> 413", %{a: a} do
      room = make_room(a)
      path_key = fn n -> String.duplicate("%E2%82%AC", n) end

      ok = put_state(a, room, "m.space.child", path_key.(85), child_base())
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      assert T.sql!("SELECT state_key FROM events WHERE event_id = $1", [T.json(ok)["event_id"]]).rows == [[String.duplicate(@euro, 85)]], "the DECODED value is stored"

      assert_413(put_state(a, room, "m.space.child", path_key.(86), child_base()), @t_key)
    end

    test "the same for a /send type: 85 x %E2%82%AC -> 200, 86 x -> 413", %{a: a} do
      room = make_room(a)
      path_type = fn n -> String.duplicate("%E2%82%AC", n) end

      ok = put_send(a, room, path_type.(85), "enc1", %{"body" => "x"})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      assert T.sql!("SELECT event_type FROM events WHERE event_id = $1", [T.json(ok)["event_id"]]).rows == [[String.duplicate(@euro, 85)]]

      assert_413(put_send(a, room, path_type.(86), "enc2", %{"body" => "x"}), @t_type)
    end

    test "the state_key \"\" is accepted on both forms (PUT .../state/m.room.topic and PUT .../state/m.room.topic/) and the stored row has state_key = ''", %{a: a} do
      room = make_room(a)

      one = put_state(a, room, "m.room.topic", :none, %{"topic" => "without slash " <> T.rand(3)})
      two = put_state(a, room, "m.room.topic", "", %{"topic" => "with slash " <> T.rand(3)})

      for conn <- [one, two] do
        assert conn.status == 200, "#{conn.status} #{conn.resp_body}"
        assert T.sql!("SELECT state_key FROM events WHERE event_id = $1", [T.json(conn)["event_id"]]).rows == [[""]]
      end
    end
  end

  describe "AC2 (i) - a lone surrogate escape is a defined 400, never a 200 or a 500" do
    test "\"\\ud800\" in the content and in a key of PUT state and /send is 400 M_BAD_JSON (Jason refuses the escape: no router walk was needed)", %{a: a} do
      room = make_room(a)
      events = event_count(room)

      for raw <- [~s({"via":["x"],"v":"\\ud800"}), ~s({"via":["x"],"\\ud800":1}), ~s({"v":"\\udc00"})] do
        conn = put_state(a, room, "m.space.child", enc("!s:" <> server()), raw)
        assert conn.status == 400, "state #{raw}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON"

        conn = put_send(a, room, "m.room.message", "sur" <> T.rand(3), raw)
        assert conn.status == 400, "send #{raw}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON"
      end

      assert event_count(room) == events
    end
  end

  describe "code review cycle 1 (M1) - a path value that is not valid UTF-8 is a defined 400, never a 500" do
    test "%FF in the room id, the event type or the state key of PUT state and in the room id or type of /send is 400 M_BAD_JSON; nothing is written", %{a: a} do
      room = make_room(a)
      events = event_count(room)

      for {label, r, type, key} <- [
            {"state key", room, "m.space.child", "%FF"},
            {"state key (half sequence)", room, "m.space.child", "%E2%82"},
            {"event type", room, "m.space.%FFchild", enc("!s:" <> server())},
            {"room id", "%FF", "m.space.child", enc("!s:" <> server())}
          ] do
        path = "/_matrix/client/v3/rooms/" <> (if r == room, do: enc(r), else: r) <> "/state/" <> type <> "/" <> key
        conn = req(:put, path, body(child_base()), a, [])
        assert conn.status == 400, "state #{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON"
      end

      for {label, r, type} <- [{"event type", enc(room), "m.room.%FF"}, {"room id", "%FF", "m.room.message"}] do
        conn = req(:put, "/_matrix/client/v3/rooms/#{r}/send/#{type}/utf" <> T.rand(3), body(%{"body" => "x"}), a, [])
        assert conn.status == 400, "send #{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert T.json(conn)["errcode"] == "M_BAD_JSON"
      end

      assert event_count(room) == events
    end
  end

  # ═══ AC2 (j): the response shape of EVERY 413 ═══════════════════════════════════════════════

  describe "AC2 (j) - the response shape of every 413 of this story" do
    test "every 413 (state, send, createRoom: all five texts) has the content type of other Nebu errors, errcode + error only, and the CORS headers of a 200", %{a: a} do
      room = make_room(a)
      key = "!j:" <> server()
      malformed = put_state(a, room, "m.space.child", enc(key), "{")
      assert malformed.status == 400
      error_content_type = T.header(malformed, "content-type")

      ok_state = put_state(a, room, "m.space.child", enc(key), child_base(), origin: @origin)
      ok_send = put_send(a, room, "m.room.message", "j-ok", %{"msgtype" => "m.text", "body" => "ok"}, origin: @origin)
      ok_create = create(a, %{"preset" => "private_chat"}, origin: @origin)
      assert Enum.all?([ok_state, ok_send, ok_create], &(&1.status == 200))
      assert T.header(ok_state, "access-control-allow-origin"), "positive control: the 200 carries CORS headers"

      big_state = padded(room, a.uid, "m.space.child", key, child_base(), 65_537)
      big_pad = String.duplicate("a", 66_000)
      big_entry = %{"type" => "m.space.child", "state_key" => "!e:" <> server(), "content" => %{"via" => [server()], "pad" => big_pad}}
      big_levels = %{"x.pad" => big_pad}

      refused = [
        {put_state(a, room, "m.space.child", enc(key), big_state, origin: @origin), ok_state, @t_event},
        {put_state(a, room, "m.space.child", enc(String.duplicate("k", 256)), child_base(), origin: @origin), ok_state, @t_key},
        {put_state(a, room, String.duplicate("t", 256), "k", %{}, origin: @origin), ok_state, @t_type},
        {put_send(a, room, "m.room.message", "j-big", %{"msgtype" => "m.text", "body" => big_pad}, origin: @origin), ok_send, @t_event},
        {put_send(a, room, String.duplicate("t", 256), "j-type", %{"body" => "x"}, origin: @origin), ok_send, @t_type},
        {create(a, %{"initial_state" => [big_entry]}, origin: @origin), ok_create, @t_is_event},
        {create(a, %{"initial_state" => [%{big_entry | "type" => String.duplicate("t", 256), "content" => %{}}]}, origin: @origin), ok_create, @t_is_type},
        {create(a, %{"initial_state" => [%{big_entry | "state_key" => String.duplicate("k", 256), "content" => %{}}]}, origin: @origin), ok_create, @t_is_key},
        {create(a, %{"creation_content" => %{"x.pad" => big_pad}}, origin: @origin), ok_create, @t_create},
        {create(a, %{"power_level_content_override" => big_levels}, origin: @origin), ok_create, @t_levels}
      ]

      for {conn, ok, text} <- refused do
        assert_413(conn, text)
        assert T.header(conn, "content-type") == error_content_type, "the content type of the other Nebu errors: #{inspect(error_content_type)}, got #{inspect(T.header(conn, "content-type"))}"
        assert cors_headers(conn) == cors_headers(ok), "CORS headers of the 413 #{inspect(text)}: #{inspect(cors_headers(conn))} vs the 200 #{inspect(cors_headers(ok))}"
        assert T.header(conn, "access-control-allow-origin") != nil
      end
    end
  end

  # ═══ AC3: /send ═══════════════════════════════════════════════════════════════════════════════

  describe "AC3 (a) - PUT /send: the boundary with \"state_key\": null accounted" do
    test "m.room.message of exactly 65 536 -> 200 (stored with state_key null: 65 536); +1 -> 413; the same txn_id then works and is idempotent", %{a: a} do
      room = make_room(a)
      base = %{"msgtype" => "m.text", "body" => "hello"}

      exact = padded(room, a.uid, "m.room.message", nil, base, 65_536)
      ok = put_send(a, room, "m.room.message", "exact", exact)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      id = T.json(ok)["event_id"]
      assert stored_bytes(id) == 65_536, "the stored row with state_key null re-encoded as D1"
      assert T.sql!("SELECT state_key IS NULL FROM events WHERE event_id = $1", [id]).rows == [[true]]

      events = event_count(room)
      watch_room!(room)
      one_more = padded(room, a.uid, "m.room.message", nil, base, 65_537)
      assert_413(put_send(a, room, "m.room.message", "retry", one_more), @t_event)
      assert event_count(room) == events, "no events row"
      refute_receive {:new_event, _}, 200

      small = put_send(a, room, "m.room.message", "retry", %{"msgtype" => "m.text", "body" => "small now"})
      assert small.status == 200, small.resp_body
      small_id = T.json(small)["event_id"]
      refute small_id == id
      assert T.sql!("SELECT count(*) FROM events WHERE event_id = $1", [small_id]).rows == [[1]], "a NEW event, no cached id of the refused attempt"
      assert_receive {:new_event, %{"event_id" => ^small_id}}, 2_000

      again = put_send(a, room, "m.room.message", "retry", %{"msgtype" => "m.text", "body" => "small now"})
      assert again.status == 200 and T.json(again)["event_id"] == small_id, "idempotency unchanged"
    end
  end

  describe "AC3 (b) - the type of a message event" do
    test "a type of 255 bytes -> 200 (any type is accepted on /send), 256 bytes -> 413", %{a: a} do
      room = make_room(a)
      type255 = "org.example.long." <> String.duplicate("t", 255 - 17)
      assert byte_size(type255) == 255

      ok = put_send(a, room, type255, "t255", %{"body" => "x"})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      assert T.sql!("SELECT event_type FROM events WHERE event_id = $1", [T.json(ok)["event_id"]]).rows == [[type255]]

      events = event_count(room)
      assert_413(put_send(a, room, type255 <> "x", "t256", %{"body" => "x"}), @t_type)
      assert event_count(room) == events
    end
  end

  describe "AC3 (c), (d) - unknown rooms and positive controls" do
    test "an oversized body to an unknown room is 413 (before the 404), a small one is 404 as before", %{a: a} do
      unknown = "!unknown" <> T.rand(6) <> ":" <> server()
      big = %{"msgtype" => "m.text", "body" => String.duplicate("a", 66_000)}

      assert_413(put_send(a, unknown, "m.room.message", "u1", big), @t_event)
      small = put_send(a, unknown, "m.room.message", "u2", %{"msgtype" => "m.text", "body" => "x"})
      assert small.status == 404, "#{small.status} #{small.resp_body}"
      assert room_row_count(unknown) == 0
    end

    test "a small m.room.message, an m.reaction and an m.room.message with m.relates_to are 200 (positive controls)", %{a: a} do
      room = make_room(a)
      first = put_send(a, room, "m.room.message", "p1", %{"msgtype" => "m.text", "body" => "hello"})
      assert first.status == 200, first.resp_body
      target = T.json(first)["event_id"]

      reaction = put_send(a, room, "m.reaction", "p2", %{"m.relates_to" => %{"rel_type" => "m.annotation", "event_id" => target, "key" => "👍"}})
      assert reaction.status == 200, reaction.resp_body

      reply = put_send(a, room, "m.room.message", "p3", %{"msgtype" => "m.text", "body" => "reply", "m.relates_to" => %{"m.in_reply_to" => %{"event_id" => target}}})
      assert reply.status == 200, reply.resp_body
    end
  end

  # ═══ AC4: createRoom ══════════════════════════════════════════════════════════════════════════

  # nothing exists afterwards: no room of the creator, no new rooms row, no new alias row for `alias`, no new invitation rows for `invitees`, no
  # room_created audit entry (a spy replaces the no-op audit writer of the test environment, see setup), and (when `baseline` is given) no statement
  # beyond the authentication
  defp assert_refused_create(user, body, text, opts \\ []) do
    rooms = created_rooms(user.uid)
    all_rooms = T.sql!("SELECT count(*) FROM rooms").rows |> hd() |> hd()
    alias_name = opts[:alias]
    invitees = opts[:invitees] || []
    alias_rows = fn -> T.sql!("SELECT count(*) FROM room_aliases WHERE alias = $1", [alias_name]).rows |> hd() |> hd() end
    invitation_rows = fn invitee -> T.sql!("SELECT count(*) FROM room_invitations WHERE invitee_id = $1", [invitee]).rows |> hd() |> hd() end
    aliases_before = if alias_name, do: alias_rows.()
    invitations_before = Map.new(invitees, &{&1, invitation_rows.(&1)})
    flush_audit()

    {conn, statements} = count_statements(fn -> create(user, body) end)
    assert_413(conn, text, opts[:marker])

    assert created_rooms(user.uid) == rooms, "no room of the creator (no m.room.create)"
    assert (T.sql!("SELECT count(*) FROM rooms").rows |> hd() |> hd()) == all_rooms, "no rooms row"
    if alias_name, do: assert(alias_rows.() == aliases_before, "no alias row")
    for invitee <- invitees, do: assert(invitation_rows.(invitee) == invitations_before[invitee], "no invitation row for #{invitee}")
    refute_received {:audit_log, _, "room_created", _, _, _, _, _}

    if baseline = opts[:baseline], do: assert_no_room_work(statements, baseline, "createRoom #{text}")
    conn
  end

  defp flush_audit do
    receive do
      {:audit_log, _, _, _, _, _, _, _} -> flush_audit()
    after
      0 -> :ok
    end
  end

  defp create_baseline(user) do
    # warm-up: the first request of a session pays statements (the session / device bookkeeping) that later requests do not
    assert create(user, "{").status == 400
    {conn, statements} = count_statements(fn -> create(user, "{") end)
    assert conn.status == 400, "baseline: #{conn.status} #{conn.resp_body}"
    statements
  end

  defp create_entry(type, key, content), do: %{"type" => type, "state_key" => key, "content" => content}

  defp placeholder_room, do: "!" <> String.duplicate("0", 16) <> ":" <> server()

  describe "AC4 (a), (b) - an initial_state entry" do
    test "an m.space.child entry sized to exactly 65 536 as STORED -> 200 and the created room's row re-encodes to 65 536; one byte more -> 413 and nothing is created", %{a: a} do
      key = "!entry:" <> server()
      exact = padded(placeholder_room(), a.uid, "m.space.child", key, child_base(), 65_536)

      ok = create(a, %{"initial_state" => [create_entry("m.space.child", key, exact)]})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      room = T.json(ok)["room_id"]
      assert_received {:audit_log, _, "room_created", _, ^room, _, _, _}
      assert byte_size(room) == byte_size(placeholder_room()), "the placeholder has the exact length of a generated room id"
      assert stored_bytes_in(room, "m.space.child", key) == 65_536

      one_more = padded(placeholder_room(), a.uid, "m.space.child", key, child_base(), 65_537)
      assert_refused_create(a, %{"initial_state" => [create_entry("m.space.child", key, one_more)]}, @t_is_event, baseline: create_baseline(a))
    end

    test "the entry is the 3rd of 3 and the first two are valid: 413 and nothing is created (no partial room)", %{a: a} do
      big = %{"via" => [server()], "pad" => String.duplicate("a", 66_000)}

      body = %{
        "name" => "Partial " <> T.rand(3),
        "initial_state" => [
          create_entry("m.room.topic", "", %{"topic" => "first"}),
          create_entry("m.space.child", "!one:" <> server(), %{"via" => [server()]}),
          create_entry("m.space.child", "!two:" <> server(), big)
        ]
      }

      assert_refused_create(a, body, @t_is_event, baseline: create_baseline(a))
    end

    test "a topic entry with a padded x.pad key at exactly 65 536 -> 200 (stored 65 536), +1 -> 413", %{a: a} do
      content = padded_with("x.pad", placeholder_room(), a.uid, "m.room.topic", "", %{"topic" => "t"}, 65_536, :ascii)

      ok = create(a, %{"initial_state" => [create_entry("m.room.topic", "", content)]})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes_in(T.json(ok)["room_id"], "m.room.topic", "") == 65_536

      over = Map.put(content, "x.pad", content["x.pad"] <> "a")
      assert_refused_create(a, %{"initial_state" => [create_entry("m.room.topic", "", over)]}, @t_is_event)
    end
  end

  describe "AC4 (c), (d) - entry keys and skipped types" do
    test "an entry type of 256 bytes -> 413 \"An initial_state event type exceeds 255 bytes\", a state_key of 256 bytes -> \"... state key ...\"; 255 bytes each -> 200", %{a: a} do
      type255 = "org.example.long." <> String.duplicate("t", 255 - 17)
      key255 = String.duplicate(@euro, 85)
      baseline = create_baseline(a)

      assert_refused_create(a, %{"initial_state" => [create_entry(type255 <> "x", "", %{})]}, @t_is_type, baseline: baseline)
      assert_refused_create(a, %{"initial_state" => [create_entry("m.space.child", key255 <> "a", child_base())]}, @t_is_key, baseline: baseline)

      ok = create(a, %{"initial_state" => [create_entry(type255, key255, %{"v" => 1})]})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      room = T.json(ok)["room_id"]
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3", [room, type255, key255]).rows == [[1]]
    end

    test "an oversized m.room.member entry (a type that is SKIPPED when applied) is 413 too: one rule, no run-time dependency", %{a: a, c: c} do
      big = %{"membership" => "join", "x.pad" => String.duplicate("a", 66_000)}
      assert_refused_create(a, %{"initial_state" => [create_entry("m.room.member", c.uid, big)]}, @t_is_event, baseline: create_baseline(a))
    end
  end

  describe "AC4 (e) - creation_content" do
    test "creation_content making the create event exactly 65 536 bytes (creator and room_version are counted) -> 200 and the stored create row is 65 536; 65 537 -> 413 \"creation_content ...\"", %{a: a} do
      # the m.room.create content the server writes: the client's keys + creator + room_version "10"
      server_added = %{"creator" => a.uid, "room_version" => "10"}
      sized = fn target ->
        base = Map.merge(%{"x.pad" => ""}, server_added)
        needed = target - stored_size(placeholder_room(), a.uid, "m.room.create", "", base)
        assert needed >= 0
        %{"x.pad" => String.duplicate("a", needed)}
      end

      exact = sized.(65_536)
      assert stored_size(placeholder_room(), a.uid, "m.room.create", "", Map.merge(exact, server_added)) == 65_536

      ok = create(a, %{"creation_content" => exact})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes_in(T.json(ok)["room_id"], "m.room.create", "") == 65_536

      assert_refused_create(a, %{"creation_content" => sized.(65_537)}, @t_create, baseline: create_baseline(a))
    end
  end

  describe "AC4 (f) - power_level_content_override" do
    # the levels the server writes: the default levels with the creator at 100 (+ invitees at 100 for trusted_private_chat), the override on top
    defp merged_levels(creator, override, invitees) do
      base = put_in(Nebu.Matrix.Room.Server.default_power_levels(), ["users", creator], 100)
      with_invitees = Enum.reduce(invitees, base, fn i, acc -> put_in(acc, ["users", i], 100) end)
      Map.merge(with_invitees, override)
    end

    defp levels_size(creator, override, invitees \\ []), do: stored_size(placeholder_room(), creator, "m.room.power_levels", "", merged_levels(creator, override, invitees))

    defp pad_override(creator, target, invitees \\ []) do
      needed = target - levels_size(creator, %{"x.pad" => ""}, invitees)
      assert needed >= 0
      %{"x.pad" => String.duplicate("a", needed)}
    end

    test "an override making the levels event exactly 65 536 bytes -> 200 (stored 65 536); 65 537 -> 413; an unknown top-level key of 70 KB -> 413", %{a: a} do
      exact = pad_override(a.uid, 65_536)
      assert levels_size(a.uid, exact) == 65_536

      ok = create(a, %{"power_level_content_override" => exact})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
      assert stored_bytes_in(T.json(ok)["room_id"], "m.room.power_levels", "") == 65_536

      baseline = create_baseline(a)
      assert_refused_create(a, %{"power_level_content_override" => pad_override(a.uid, 65_537)}, @t_levels, baseline: baseline)
      assert_refused_create(a, %{"power_level_content_override" => %{"x.unknown" => String.duplicate("u", 70_000)}}, @t_levels, baseline: baseline)
    end

    test "a users map of valid ids that makes the levels event exceed the limit -> 413; the same map with fewer ids -> 200", %{a: a} do
      ids = fn n -> for i <- 1..n, into: %{}, do: {"@" <> String.pad_leading(Integer.to_string(i), 6, "0") <> String.duplicate("u", 200) <> ":" <> server(), 10} end
      users = fn n -> Map.put(ids.(n), a.uid, 100) end

      assert levels_size(a.uid, %{"users" => users.(300)}) > 65_536, "premise: 300 ids of about 215 bytes exceed the limit"
      assert levels_size(a.uid, %{"users" => users.(200)}) < 65_536, "premise: 200 do not"

      assert_refused_create(a, %{"power_level_content_override" => %{"users" => users.(300)}}, @t_levels, baseline: create_baseline(a))

      ok = create(a, %{"power_level_content_override" => %{"users" => users.(200)}})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
    end

    test "an override that fits without invitees but exceeds with trusted_private_chat and 3 invitees (their level-100 entries count) -> 413; private_chat -> 200", %{a: a} do
      invitees = for _ <- 1..3, do: user!("ESI")
      uids = Enum.map(invitees, & &1.uid)
      override = pad_override(a.uid, 65_536)

      assert levels_size(a.uid, override) == 65_536, "without invitees the event is exactly at the limit"
      assert levels_size(a.uid, override, uids) > 65_536, "with their level-100 entries it exceeds it"

      ok = create(a, %{"preset" => "private_chat", "invite" => uids, "power_level_content_override" => override})
      assert ok.status == 200, "private_chat does not give the invitees level 100: #{ok.status} #{String.slice(ok.resp_body, 0, 200)}"

      b = user!("ESB")
      override_b = pad_override(b.uid, 65_536)
      assert levels_size(b.uid, override_b, uids) > 65_536

      assert_refused_create(b, %{"preset" => "trusted_private_chat", "invite" => uids, "power_level_content_override" => override_b}, @t_levels, invitees: uids)
    end
  end

  describe "AC4 (g) - order: 5g is after the pure steps, before the DB reads" do
    test "an oversized entry plus room_version \"9\" is 400 M_UNSUPPORTED_ROOM_VERSION; plus a 33-deep creation_content is 400 M_BAD_JSON", %{a: a} do
      big = create_entry("m.space.child", "!o:" <> server(), %{"via" => [server()], "pad" => String.duplicate("a", 66_000)})

      version = create(a, %{"initial_state" => [big], "room_version" => "9"})
      assert version.status == 400, "#{version.status} #{String.slice(version.resp_body, 0, 200)}"
      assert T.json(version)["errcode"] == "M_UNSUPPORTED_ROOM_VERSION"

      deep = Enum.reduce(1..33, %{}, fn _, acc -> %{"a" => acc} end)
      bad = create(a, %{"initial_state" => [big], "creation_content" => deep})
      assert bad.status == 400, "#{bad.status} #{String.slice(bad.resp_body, 0, 200)}"
      assert T.json(bad)["errcode"] == "M_BAD_JSON"
    end

    test "an oversized entry plus a TAKEN room_alias_name is 413 (5g before 6: no alias read); plus an unknown invitee is 413 (before 7)", %{a: a, c: c} do
      localpart = "taken" <> T.rand(5)
      taken = make_room(c, %{"room_alias_name" => localpart})
      assert room_row_count(taken) == 1

      big = create_entry("m.space.child", "!o:" <> server(), %{"via" => [server()], "pad" => String.duplicate("a", 66_000)})
      baseline = create_baseline(a)

      assert_refused_create(a, %{"initial_state" => [big], "room_alias_name" => localpart}, @t_is_event, baseline: baseline, alias: "#" <> localpart <> ":" <> server())

      ghost = "@nobody" <> T.rand(5) <> ":" <> server()
      assert_refused_create(a, %{"initial_state" => [big], "invite" => [ghost]}, @t_is_event, baseline: baseline, invitees: [ghost])
    end
  end

  describe "AC4 (g) - a fresh alias is not registered by a refusal" do
    test "an oversized entry plus a fresh room_alias_name is 413 and room_aliases has no row for it; the same alias with a small request is registered", %{a: a} do
      localpart = "fresh" <> T.rand(5)
      alias_name = "#" <> localpart <> ":" <> server()
      assert T.sql!("SELECT count(*) FROM room_aliases WHERE alias = $1", [alias_name]).rows == [[0]], "premise: the alias is free"
      big = create_entry("m.space.child", "!o:" <> server(), %{"via" => [server()], "pad" => String.duplicate("a", 66_000)})

      assert_refused_create(a, %{"initial_state" => [big], "room_alias_name" => localpart}, @t_is_event, baseline: create_baseline(a), alias: alias_name)
      assert T.sql!("SELECT count(*) FROM room_aliases WHERE alias = $1", [alias_name]).rows == [[0]], "no alias row"

      # positive control: the same alias with a small request is registered
      ok = create(a, %{"room_alias_name" => localpart})
      assert ok.status == 200, ok.resp_body
      assert T.sql!("SELECT count(*) FROM room_aliases WHERE alias = $1", [alias_name]).rows == [[1]]
    end
  end

  describe "AC4 (h), (i), (j) - bounded by construction, body cap, charge" do
    test "a top-level topic of 1024 U+0001 characters and a name of 255 U+0001 characters -> 200 (the topic event is about 12.3 KB: the D6 bound holds)", %{a: a} do
      topic = String.duplicate("\u0001", 1024)
      name = String.duplicate("\u0001", 255)

      ok = create(a, %{"topic" => topic, "name" => name})
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 300)}"
      room = T.json(ok)["room_id"]
      topic_bytes = stored_bytes_in(room, "m.room.topic", "")
      assert topic_bytes > 12_000 and topic_bytes < 13_000, "the bound of the story: #{topic_bytes}"
      assert stored_bytes_in(room, "m.room.name", "") < 2_000
    end

    test "a createRoom body of 999 000 bytes of mostly whitespace around a small valid request -> 200 (body cap and event limit differ)", %{a: a} do
      small = Jason.encode!(%{"name" => "padded " <> T.rand(3), "preset" => "private_chat"})
      raw = small <> String.duplicate(" ", 999_000 - byte_size(small))
      assert byte_size(raw) == 999_000

      ok = create(a, raw)
      assert ok.status == 200, "#{ok.status} #{String.slice(ok.resp_body, 0, 300)}"
    end

    test "the refused createRoom still spent one create_room token (rate-limits D2: the charge comes first)", %{a: a} do
      Nebu.Web.Plugs.RateLimit.init_table()
      tokens = fn -> case :ets.lookup(@table, {"create_room", a.uid}) do [{_k, t, _}] -> t; [] -> 20.0 end end
      before = tokens.()
      assert before == 20.0

      assert_413(create(a, %{"creation_content" => %{"x.pad" => String.duplicate("a", 70_000)}}), @t_create)
      assert tokens.() == before - 1, "one create_room unit was spent by the refused request"
    end

    test "a marker in the creation_content, the initial_state type and key and the override never comes back in a 413", %{a: a} do
      marker = "MARK" <> T.rand(6)
      pad = String.duplicate("a", 70_000)

      assert_413(create(a, %{"creation_content" => %{"m" => marker, "x.pad" => pad}}), @t_create, marker)
      assert_413(create(a, %{"power_level_content_override" => %{"m" => marker, "x.pad" => pad}}), @t_levels, marker)
      assert_413(create(a, %{"initial_state" => [create_entry(marker <> String.duplicate("t", 260), "", %{})]}), @t_is_type, marker)
      assert_413(create(a, %{"initial_state" => [create_entry("m.space.child", marker <> String.duplicate("k", 260), %{})]}), @t_is_key, marker)
      assert_413(create(a, %{"initial_state" => [create_entry("m.space.child", "!m:" <> server(), %{"m" => marker, "pad" => pad})]}), @t_is_event, marker)
    end
  end

  # ═══ AC1 (g): the room id length the 5g placeholder relies on ═══════════════════════════════════

  describe "AC1 (g) - a generated room id has the length of the 5g placeholder (D6)" do
    test "byte_size(room_id) == 1 + 16 + 1 + byte_size(server_name) for two server names", %{a: a} do
      for name <- ["test.local", "a-longer-server-name.chat.example.org"] do
        Nebu.Test.ServerName.pin!(name)
        room = make_room(a)
        assert byte_size(room) == 1 + 16 + 1 + byte_size(name), "server #{name}: #{room}"
        assert room =~ ~r/\A![0-9a-f]{16}:/
      end
    end
  end

  # ═══ AC8 (a): legacy rows are delivered as before, then the slot is clean after two writes ═══════

  describe "AC8 (a) - a legacy oversized state event" do
    test "an 80 KB legacy topic is still delivered by /sync; a new small topic is 200 with the legacy content as prev_content; the second one is clean", %{a: a} do
      room = make_room(a)
      legacy = %{"topic" => String.duplicate("t", 80_000)}
      Nebu.Test.EventSizeSupport.legacy_event!(room, a.uid, "m.room.topic", "", legacy)

      delivered = synced_state(a, room, "m.room.topic", "")
      assert delivered["content"] == legacy, "the legacy content is delivered as before (the read side is unchanged)"

      first = %{"topic" => "first small " <> T.rand(3)}
      ok = put_state(a, room, "m.room.topic", :none, first)
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      first_id = T.json(ok)["event_id"]
      after_first = synced_state(a, room, "m.room.topic", "")
      assert after_first["event_id"] == first_id
      assert get_in(after_first, ["unsigned", "prev_content"]) == legacy, "the legacy content travels as the prev_content of its slot's next event (D8, documented)"

      Nebu.Test.EventSizeSupport.wait_clock_past(System.system_time(:millisecond))
      second = %{"topic" => "second small " <> T.rand(3)}
      ok2 = put_state(a, room, "m.room.topic", :none, second)
      assert ok2.status == 200, "#{ok2.status} #{ok2.resp_body}"
      after_second = synced_state(a, room, "m.room.topic", "")
      assert after_second["event_id"] == T.json(ok2)["event_id"]
      assert get_in(after_second, ["unsigned", "prev_content"]) == first, "the slot is clean after two new writes"
      assert byte_size(Jason.encode!(after_second)) < 10_000
    end
  end

  # ═══ AC11 (c): aliases in BYTES (incl. # and the domain) ════════════════════════════════════════

  describe "AC11 (c) - aliases are limited in bytes" do
    # a localpart so that "#" <> localpart <> ":" <> server is exactly `total` BYTES, with `multibyte` 2-byte "é" inside
    defp localpart_for_total(total, multibyte) do
      random = T.rand(5)
      mb = String.duplicate("é", multibyte)
      pad = total - 2 - byte_size(server()) - byte_size(random) - byte_size(mb)
      lp = random <> mb <> String.duplicate("a", pad)
      assert byte_size("#" <> lp <> ":" <> server()) == total
      lp
    end

    test "a room_alias_name whose full alias is 255 bytes with a multi-byte localpart -> 200, 256 bytes -> 400 M_INVALID_PARAM (the existing rule, re-asserted)", %{a: a} do
      ok = create(a, %{"room_alias_name" => localpart_for_total(255, 20)})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"

      too_long = create(a, %{"room_alias_name" => localpart_for_total(256, 20)})
      assert too_long.status == 400, "#{too_long.status} #{too_long.resp_body}"
      assert T.json(too_long)["errcode"] == "M_INVALID_PARAM"
    end

    test "canonical_alias through PUT state: an own 255-byte multi-byte alt_alias is accepted (200 once it maps to the room), 256 bytes -> 400 M_INVALID_PARAM", %{a: a} do
      lp = localpart_for_total(255, 20)
      alias255 = "#" <> lp <> ":" <> server()
      room = make_room(a, %{"room_alias_name" => lp})

      ok = put_state(a, room, "m.room.canonical_alias", :none, %{"alt_aliases" => [alias255]})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"

      alias256 = "#" <> localpart_for_total(256, 20) <> ":" <> server()
      too_long = put_state(a, room, "m.room.canonical_alias", :none, %{"alt_aliases" => [alias256]})
      assert too_long.status == 400, "#{too_long.status} #{too_long.resp_body}"
      assert T.json(too_long)["errcode"] == "M_INVALID_PARAM"
    end

    test "canonical_alias through PUT state, the `alias` field: an own alias of 255 bytes (multi-byte) -> 200, 256 bytes -> 400 M_INVALID_PARAM (test review MINOR-3)", %{a: a} do
      lp = localpart_for_total(255, 20)
      room = make_room(a, %{"room_alias_name" => lp})

      ok = put_state(a, room, "m.room.canonical_alias", :none, %{"alias" => "#" <> lp <> ":" <> server()})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"

      too_long = put_state(a, room, "m.room.canonical_alias", :none, %{"alias" => "#" <> localpart_for_total(256, 20) <> ":" <> server()})
      assert too_long.status == 400, "#{too_long.status} #{too_long.resp_body}"
      assert T.json(too_long)["errcode"] == "M_INVALID_PARAM"
    end

    test "an initial_state canonical_alias entry: the `alias` of 255 bytes (with the same room_alias_name) -> 200, of 256 bytes -> 400 M_INVALID_PARAM (test review MINOR-3)", %{a: a} do
      lp = localpart_for_total(255, 20)
      entry = fn alias_str -> create_entry("m.room.canonical_alias", "", %{"alias" => alias_str}) end

      ok = create(a, %{"room_alias_name" => lp, "initial_state" => [entry.("#" <> lp <> ":" <> server())]})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"

      too_long = create(a, %{"initial_state" => [entry.("#" <> localpart_for_total(256, 20) <> ":" <> server())]})
      assert too_long.status == 400, "#{too_long.status} #{too_long.resp_body}"
      assert T.json(too_long)["errcode"] == "M_INVALID_PARAM"
    end

    test "a derived alias from the longest name (255 characters) stays within 255 bytes", %{a: a} do
      ok = create(a, %{"name" => String.duplicate("n", 255)})
      assert ok.status == 200, "#{ok.status} #{ok.resp_body}"
      room = T.json(ok)["room_id"]
      aliases = T.sql!("SELECT alias FROM room_aliases WHERE room_id = $1", [room]).rows |> List.flatten()
      assert aliases != [], "positive control: an alias was derived"
      assert Enum.all?(aliases, &(byte_size(&1) <= 255)), "aliases: #{inspect(Enum.map(aliases, &byte_size/1))}"
    end
  end

  # ═══ AC11 (d): the sender guard ═══════════════════════════════════════════════════════════════

  describe "AC11 (d) - a user id above 255 bytes: 403, nothing written" do
    # a fixture account with an id of exactly `total` bytes (the shape every account had before the id bound existed)
    defp long_user!(total) do
      lp = String.duplicate("l", total - 2 - byte_size(server()) - 4) <> T.rand(2)
      uid = "@" <> lp <> ":" <> server()
      assert byte_size(uid) == total
      {:ok, _} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "ATDD long id", T.rand(4) <> "@example.com")
      %{uid: uid, at: T.legacy_session!(uid, "ESL" <> String.upcase(T.rand(3))).at}
    end

    test "a 256-byte user id: PUT state, /send and createRoom answer 403 M_FORBIDDEN with the sign-in-again text; nothing is written", %{a: a} do
      long = long_user!(256)
      room = make_room(a)
      events = event_count(room)
      rooms = created_rooms(long.uid)

      for {label, conn} <- [
            {"state", put_state(long, room, "m.room.topic", :none, %{"topic" => "x"})},
            {"send", put_send(long, room, "m.room.message", "long1", %{"msgtype" => "m.text", "body" => "x"})},
            {"createRoom", create(long, %{})}
          ] do
        assert conn.status == 403, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
        assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => @t_sender}, "#{label}: #{conn.resp_body}"
      end

      assert event_count(room) == events
      assert created_rooms(long.uid) == rooms
    end

    test "a 255-byte user id works on all three routes (positive control)", %{a: _a} do
      ok = long_user!(255)
      room = make_room(ok)
      assert put_state(ok, room, "m.room.topic", :none, %{"topic" => "x"}).status == 200
      assert put_send(ok, room, "m.room.message", "ok1", %{"msgtype" => "m.text", "body" => "x"}).status == 200
    end
  end
end
