defmodule Nebu.Matrix.HistoryVisibilitySecurityCycle1Test do
  @moduledoc """
  Story `history-visibility-enforcement`, security cycle 1 (the BINDING decisions of
  `_bmad-output/nebu/epics/oauth-broker/step-results/history-visibility-enforcement/code-review-findings.md` and the Kassandra report
  `docs/stories/oauth-broker/security-reports/history-visibility-enforcement-security-review-2026-10-26.md`), real stack (`:integration`):

    * HIGH #1 (a): the per-room cap on `m.room.history_visibility` state events (test seam `:nebu, :hv_event_cap`, default 256): the write
      that would exceed it is `429 M_LIMIT_EXCEEDED` with a fixed text, nothing is written, EXCEPT a strictly more restrictive change
      (security cycle 2, Kassandra N1: the cap never blocks tightening; at most 3 rows above the cap); other state types and a non-empty
      state key are not capped;
    * HIGH #1 (b): a PUT of `m.room.history_visibility`, `m.room.guest_access` and `m.room.join_rules` costs one `moderation` token;
    * HIGH #1 (c): with 3 000 hv events in one room the page, the since read, the single-event read and the search stay far below the
      timeout (the linear fragment; the measured times are printed, value-free);
    * HIGH #1 (d): the request reads (`/messages`, `/event`, `/relations`, `/search`) blocked longer than 2 s answer the generic `500` with ONE
      value-free ERROR line, never a page (`/initialSync`: a handled error); the `/sync` is not under the timeout (it waits and answers `200`);
    * MINOR-1: the since read of a room without new events reads no visibility input (EXPLAIN ANALYZE);
    * MINOR-3: a NUL in an event id, a relation type, an event type or a `from` token is the unknown-event `404`, no ERROR line;
    * LOW #4: `POST /read_markers` refuses a hidden `m.fully_read` event exactly like an unknown one;
    * LOW #5 (`gj`): `400 M_BAD_JSON` for a `history_visibility` / `guest_access` value outside the enum (PUT state with the empty state key,
      createRoom `initial_state`); a non-empty state key is not validated, the upgrade copy stays tolerant.

  The ids, markers and timings printed by a failing assertion name no content.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.HistoryVisibilityTestSupport
  import Nebu.Matrix.MembershipStateTestSupport, only: [setup_env!: 0]

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Search.DB, as: SearchDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 300_000

  setup do
    setup_env!()
    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp put_env!(app, key, value) do
    prior = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp hv_count(room) do
    [[count]] = T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = ''", [room, hv_type()]).rows
    count
  end

  defp private_room!(owner), do: make_room(owner, %{"preset" => "private_chat"})

  defp bad_json!(conn, text) do
    assert conn.status == 400, "expected 400, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    assert T.json(conn) == %{"errcode" => "M_BAD_JSON", "error" => text}
  end

  # holds an ACCESS EXCLUSIVE lock on `table` in a privileged connection until `release_lock!/1` (at most `ms`); returns the task once
  # the lock is taken
  defp hold_lock!(table, ms) do
    parent = self()

    task =
      Task.async(fn ->
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE", [])
            send(parent, :hv_locked)

            receive do
              :hv_release -> :ok
            after
              ms -> :ok
            end
          end)
        end)
      end)

    assert_receive :hv_locked, 5_000
    task
  end

  defp release_lock!(task) do
    send(task.pid, :hv_release)
    Task.await(task, 15_000)
  end

  # the real statement of `fun` that carries the fragment marker, with its parameters
  defp capture_marked_statement(fun) do
    id = "hv-cycle1-#{T.rand(6)}"
    parent = self()

    :ok =
      :telemetry.attach(id, [:nebu, :repo, :query], fn _event, _m, %{query: query, params: params}, _c ->
        if String.contains?(query, "/* history_visibility */"), do: send(parent, {:hv_statement, query, params})
      end, nil)

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    assert_received {:hv_statement, query, params}
    {query, params}
  end

  defp explain_analyze!(query, params) do
    %{rows: [[json]]} = T.sql!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)
    json |> List.wrap() |> hd()
  end

  defp plan_nodes(%{} = node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]

  defp ms(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  # ═══ HIGH #1 (a): the cap ═══════════════════════════════════════════════════════════════════════

  describe "HIGH #1 (a) - the per-room cap on history visibility events" do
    setup do
      put_env!(:nebu, :hv_event_cap, 3)
      :ok
    end

    test "the write above the cap is 429 M_LIMIT_EXCEEDED, nothing written; other types and a non-empty state key are not capped" do
      a = user!("HVC")
      room = private_room!(a)
      assert hv_count(room) == 1, "control: the preset wrote one hv event"

      for value <- ["joined", "shared"], do: assert(put_hv(a, room, value).status == 200)
      assert hv_count(room) == 3

      # the current setting is shared: world_readable is weaker (the tightening exemption of N1 does not apply)
      conn = put_hv(a, room, "world_readable")
      assert conn.status == 429, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn) == %{"errcode" => "M_LIMIT_EXCEEDED", "error" => "This room has too many history visibility changes"}
      assert hv_count(room) == 3, "nothing was written"

      assert put_state(a, room, "m.room.topic", %{"topic" => word("t")}).status == 200
      assert put_state(a, room, "m.room.guest_access", %{"guest_access" => "can_join"}).status == 200
      assert put_state(a, room, hv_type() <> "/other", %{"history_visibility" => "shared"}).status == 200, "a non-empty state key is no setting"
      assert hv_count(room) == 3

      other_room = private_room!(a)
      assert put_hv(a, other_room, "joined").status == 200, "the cap is per room"
    end

    # security cycle 2 (Kassandra N1): the cap never blocks tightening
    test "(N1 a) at the cap with world_readable: joined passes (tighter); then shared and joined again are 429" do
      a = user!("HVN")
      room = private_room!(a)
      for value <- ["shared", "world_readable"], do: assert(put_hv(a, room, value).status == 200)
      assert hv_count(room) == 3, "at the cap"

      assert put_hv(a, room, "joined").status == 200, "tighter than world_readable"
      assert put_hv(a, room, "shared").status == 429, "weaker than joined"
      assert put_hv(a, room, "joined").status == 429, "equal is no tightening"
      assert hv_count(room) == 4
    end

    test "(N1 d) the bound: from world_readable at the cap at most 3 more rows (shared, invited, joined), then every write is 429" do
      a = user!("HVN")
      room = private_room!(a)
      for value <- ["shared", "world_readable"], do: assert(put_hv(a, room, value).status == 200)

      for value <- ["shared", "invited", "joined"], do: assert(put_hv(a, room, value).status == 200, value)
      for value <- hv_values(), do: assert(put_hv(a, room, value).status == 429, value)
      assert hv_count(room) == 3 + 3
    end

    test "(N1 b) at the cap with the current setting joined: shared and invited are 429" do
      a = user!("HVN")
      room = private_room!(a)
      for value <- ["shared", "joined"], do: assert(put_hv(a, room, value).status == 200)
      assert hv_count(room) == 3

      for value <- ["shared", "invited", "world_readable"], do: assert(put_hv(a, room, value).status == 429, value)
      assert hv_count(room) == 3
    end

    test "(N1 c) at the cap with an unknown stored value (reads as shared): invited is tighter and passes" do
      a = user!("HVN")
      room = private_room!(a)
      assert put_hv(a, room, "joined").status == 200
      tick()
      put_hv_event!(room, a, "nonsense", System.system_time(:millisecond) + 5)
      Process.sleep(10)
      assert hv_count(room) == 3

      assert put_hv(a, room, "invited").status == 200
      assert put_hv(a, room, "shared").status == 429
    end

    test "the default cap is 256 (source pin of the room process)" do
      source = File.read!(Path.expand("../../../lib/nebu/matrix/room/server.ex", __DIR__))
      assert source =~ "Application.get_env(:nebu, :hv_event_cap, 256)"
    end
  end

  # ═══ HIGH #1 (b): the moderation tier ════════════════════════════════════════════════════════════

  describe "HIGH #1 (b) - the access state types are charged to the moderation tier" do
    setup do
      Application.delete_env(:nebu_http, :rate_limit_disabled)
      put_env!(:nebu_http, :rate_limit_moderation_per_min, 1)
      put_env!(:nebu_http, :rate_limit_moderation_burst, 2)
      :ok
    end

    for {type, content} <- [
          {"m.room.history_visibility", %{"history_visibility" => "joined"}},
          {"m.room.guest_access", %{"guest_access" => "can_join"}},
          {"m.room.join_rules", %{"join_rule" => "invite"}}
        ] do
      test "a PUT of #{type} costs one moderation token: the third is 429" do
        a = user!("HVT")
        room = private_room!(a)
        assert tokens("moderation", a, 2) == 2.0

        for _ <- 1..2, do: assert(put_state(a, room, unquote(type), unquote(Macro.escape(content))).status == 200)
        assert tokens("moderation", a, 2) == 0.0

        conn = put_state(a, room, unquote(type), unquote(Macro.escape(content)))
        assert conn.status == 429 and T.json(conn)["errcode"] == "M_LIMIT_EXCEEDED"
      end
    end

    test "a PUT of m.room.topic stays uncharged" do
      a = user!("HVT")
      room = private_room!(a)
      seed("moderation", a, 0)
      assert put_state(a, room, "m.room.topic", %{"topic" => word("t")}).status == 200
    end
  end

  # ═══ HIGH #1 (c): the linear cost ════════════════════════════════════════════════════════════════

  describe "HIGH #1 (c) - 3 000 hv events in one room" do
    test "page, since, single event and search stay far below the 2 s timeout (O(B log B), times printed value-free)" do
      room = raw_room!()
      a = T.provision_user!()
      b = T.provision_user!()

      T.privileged_sql!(
        """
        INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
        SELECT '$hvbulk' || md5(g::text || $1), $1, $2, 'm.room.history_visibility',
               jsonb_build_object('history_visibility', CASE WHEN g % 2 = 0 THEN 'joined' ELSE 'shared' END), 1000 + 2 * g, ''
        FROM generate_series(1, 3000) AS g
        """,
        [room, a]
      )

      join = put_event!(room, b, "m.room.member", %{"membership" => "join"}, 10_000, b)
      put_row!(room, b, 10_000)
      term = word("cost")
      shown = for ts <- 10_001..10_003, do: put_message!(room, a, term, ts)
      T.privileged_sql!("ANALYZE events")

      {page_ms, {:ok, page, _, _}} = ms(fn -> DB.fetch_visible_events(room, b, "b", 10, "") end)
      {since_ms, {:ok, since}} = ms(fn -> DB.fetch_visible_events_since(room, b, join, 20) end)
      {single_ms, {:ok, _}} = ms(fn -> DB.fetch_visible_event(List.last(shown), room, b) end)
      {search_ms, {:ok, found}} = ms(fn -> SearchDB.search_messages(b, term, 10, 0, []) end)

      # story sync-stream-position (A-1): the range read of the incremental /sync and the head-bounded page, same 3 000-hv-event room
      head = T.sql!("SELECT event_pos FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()
      {range_ms, {:ok, range}} = ms(fn -> apply(DB, :fetch_visible_events_in_range, [room, b, 0, head, 20]) end)
      {page6_ms, {:ok, page6, _, _}} = ms(fn -> apply(DB, :fetch_visible_events, [room, b, "b", 10, "", head]) end)
      assert Enum.take(Enum.map(range, & &1["event_id"]), 3) == Enum.reverse(shown), "the range read: the three messages newest first"
      assert Enum.map(page6, & &1["event_id"]) == Enum.map(page, & &1["event_id"]), "the head-bounded page is the page"

      ids = Enum.map(page, & &1["event_id"])
      assert Enum.take(ids, 3) == Enum.reverse(shown)
      assert Enum.map(since, & &1["event_id"]) == shown, "the since read from the join: the three messages"
      assert Enum.sort(Enum.map(found, & &1["event_id"])) == Enum.sort(shown)

      {query, params} = capture_marked_statement(fn -> DB.fetch_visible_events(room, b, "b", 10, "") end)
      plan = explain_analyze!(query, params)
      exec_ms = plan["Execution Time"]

      IO.puts(
        "hv-cost 3000 hv events: page #{page_ms} ms, since #{since_ms} ms, single #{single_ms} ms, search #{search_ms} ms; " <>
          "EXPLAIN ANALYZE page: planning #{plan["Planning Time"]} ms, execution #{exec_ms} ms"
      )

      for {label, t} <- [page: page_ms, since: since_ms, single: single_ms, search: search_ms, range: range_ms, page6: page6_ms] do
        assert t < 1_500, "#{label} took #{t} ms with 3000 hv events (quadratic?)"
      end

      assert exec_ms < 1_000, "the page statement executed in #{exec_ms} ms"
      refute plan |> plan_nodes() |> Enum.any?(&(&1["Relation Name"] == "events" and &1["Node Type"] == "Seq Scan" and &1["Actual Loops"] > 1))
    end
  end

  # ═══ HIGH #1 (d): the request statement timeout ══════════════════════════════════════════════════

  describe "HIGH #1 (d) - the 2 s statement timeout of the request reads" do
    test "blocked /messages, /event, /relations and /search answer the generic 500 with one value-free ERROR line; the /sync waits, 200" do
      s = scenario!("joined")
      token = snapshot!(s.b, anchor_room!(s.b))
      lock = hold_lock!("room_members", 30_000)

      for {label, request} <- [
            messages: fn -> messages_req(s.b, s.room) end,
            event: fn -> event_conn(s.b, s.room, s.m3.id) end,
            relations: fn -> relations_conn(s.b, s.room, s.m3.id) end,
            search: fn -> search_conn(s.b, s.m3.marker) end
          ] do
        {conn, log} = capture_at(:info, request)
        assert conn.status == 500, "#{label}: #{conn.status}"
        assert T.json(conn) == %{"errcode" => "M_UNKNOWN", "error" => "Internal server error"}
        refute_leak!(conn.resp_body, [s.m1, s.m3])
        assert [line] = error_lines(log), "#{label}: exactly one ERROR line"
        assert line =~ "57014", "#{label}: the error class"
        refute line =~ s.m3.marker or line =~ s.m3.id
      end

      # /initialSync: its messages read is under the timeout; its state reads have their own handled answers: never a 200 page
      initial = initial_sync_conn(s.b, s.room)
      assert initial.status in [500, 503], "/initialSync: #{initial.status}"
      refute_leak!(initial.resp_body, [s.m1, s.m3])

      sync = Task.async(fn -> sync_conn(s.b, since: token, timeout: 0) end)
      Process.sleep(2_500)
      release_lock!(lock)
      assert Task.await(sync, 20_000).status == 200, "the /sync is not under the request timeout: it waited for the lock"
    end
  end

  defp search_conn(user, term),
    do: T.matrix_request(:post, "/_matrix/client/v3/search", user.at, body: %{"search_categories" => %{"room_events" => %{"search_term" => term}}})

  # ═══ MINOR-1: the since read of a quiet room ═════════════════════════════════════════════════════

  describe "MINOR-1 - the since read reads no visibility input without new events" do
    test "EXPLAIN ANALYZE of an empty delta: no events row is read beyond the one existence probe (times printed)" do
      room = raw_room!()
      a = T.provision_user!()

      for i <- 1..50, do: put_hv_event!(room, a, if(rem(i, 2) == 0, do: "joined", else: "shared"), 1_000 + i)
      put_event!(room, a, "m.room.member", %{"membership" => "join"}, 2_000, a)
      put_row!(room, a, 2_000)
      anchor = put_message!(room, a, word("anchor"), 3_000)

      assert {:ok, []} = DB.fetch_visible_events_since(room, a, anchor, 20)
      {query, params} = capture_marked_statement(fn -> DB.fetch_visible_events_since(room, a, anchor, 20) end)
      plan = explain_analyze!(query, params)

      read =
        plan
        |> plan_nodes()
        |> Enum.filter(&(&1["Relation Name"] == "events"))
        |> Enum.map(&(&1["Actual Rows"] * &1["Actual Loops"]))
        |> Enum.sum()

      IO.puts("hv-since empty delta: planning #{plan["Planning Time"]} ms, execution #{plan["Execution Time"]} ms, events rows #{read}")
      assert read == 0, "a room without new events reads no hv / member rows (read #{read})"
    end
  end

  # ═══ MINOR-3: NUL ════════════════════════════════════════════════════════════════════════════════

  describe "MINOR-3 - NUL ids" do
    test "/event, /relations (event id, rel type, event type) and a /messages token with a NUL: the unknown-event 404, no ERROR line" do
      s = scenario!("shared")
      unknown = assert_event_404!(event_conn(s.b, s.room, "$unknown" <> T.rand(6)))

      {conns, log} =
        capture_at(:info, fn ->
          [
            event_conn(s.b, s.room, "$a" <> <<0>>),
            relations_conn(s.b, s.room, "$a" <> <<0>>),
            T.matrix_request(:get, "/_matrix/client/v1/rooms/#{enc(s.room)}/relations/#{enc(s.m3.id)}/#{enc("m.thread" <> <<0>>)}", s.b.at),
            T.matrix_request(:get, "/_matrix/client/v1/rooms/#{enc(s.room)}/relations/#{enc(s.m3.id)}/m.thread/#{enc("m.room.message" <> <<0>>)}", s.b.at),
            messages_req(s.b, s.room, "dir=b&limit=10&from=" <> URI.encode_www_form(token(100, "$a" <> <<0>>)))
          ]
        end)

      for conn <- conns, do: assert(assert_event_404!(conn) == unknown)
      assert error_lines(log) == []
    end
  end

  # ═══ LOW #4: read markers ═══════════════════════════════════════════════════════════════════════

  describe "LOW #4 - POST /read_markers m.fully_read" do
    test "a hidden event is refused exactly like an unknown one; a visible one is stored" do
      s = scenario!("joined")
      post = fn id -> T.matrix_request(:post, path(s.room, "read_markers"), s.b.at, body: %{"m.fully_read" => id}) end

      hidden = post.(s.m1.id)
      unknown = post.("$unknown" <> T.rand(6))
      assert hidden.status == 400 and unknown.status == 400
      assert hidden.resp_body == unknown.resp_body, "no existence oracle"
      refute_leak!(hidden.resp_body, s.m1)
      assert post.(s.m3.id).status == 200, "control: a visible event"
    end
  end

  # ═══ LOW #5 / gj: the values are validated on write ═════════════════════════════════════════════

  describe "LOW #5 (gj) - history_visibility and guest_access values" do
    @hv_text "history_visibility must be one of invited, joined, shared, world_readable"
    @ga_text "guest_access must be can_join or forbidden"

    test "PUT state: a value outside the enum is 400 M_BAD_JSON (fixed text), nothing is written; the four values pass" do
      a = user!("HVG")
      room = private_room!(a)
      before = hv_count(room)

      for content <- [%{"history_visibility" => "Joined"}, %{"history_visibility" => 7}, %{}, %{"history_visibility" => ["joined"]}] do
        bad_json!(put_hv(a, room, content), @hv_text)
      end

      assert hv_count(room) == before
      for value <- hv_values(), do: assert(put_hv(a, room, value).status == 200)

      for content <- [%{"guest_access" => "open"}, %{}] do
        bad_json!(put_state(a, room, "m.room.guest_access", content), @ga_text)
      end

      for value <- ["can_join", "forbidden"], do: assert(put_state(a, room, "m.room.guest_access", %{"guest_access" => value}).status == 200)

      # a non-empty state key is no setting: not validated (INFO-7)
      assert put_state(a, room, "m.room.guest_access/other", %{"guest_access" => "open"}).status == 200
    end

    test "the upgrade copy stays tolerant: a room whose stored setting is unknown is upgraded (200), the new room has a setting" do
      a = user!("HVG")
      room = private_room!(a)
      tick()
      put_hv_event!(room, a, "nonsense", System.system_time(:millisecond) + 5)
      Process.sleep(10)

      conn = T.matrix_request(:post, path(room, "upgrade"), a.at, body: %{"new_version" => "10"})
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      assert hv_count(new_room) >= 1
    end

    test "createRoom initial_state: an hv or guest_access entry outside the enum is 400 M_BAD_JSON; a valid one passes" do
      a = user!("HVG")
      create = fn entries -> T.matrix_request(:post, "/_matrix/client/v3/createRoom", a.at, body: %{"preset" => "private_chat", "initial_state" => entries}) end

      bad_json!(create.([%{"type" => hv_type(), "state_key" => "", "content" => %{"history_visibility" => "nonsense"}}]), @hv_text)
      bad_json!(create.([%{"type" => "m.room.guest_access", "content" => %{"guest_access" => "open"}}]), @ga_text)
      assert create.([%{"type" => hv_type(), "state_key" => "", "content" => %{"history_visibility" => "joined"}}]).status == 200
    end
  end
end
