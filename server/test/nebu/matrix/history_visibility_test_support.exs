defmodule Nebu.Matrix.HistoryVisibilityTestSupport do
  @moduledoc """
  Shared helpers of the story `history-visibility-enforcement` suites (`history_visibility_http_test.exs`, `history_visibility_upgrade_http_test.exs`,
  `history_visibility_concurrency_test.exs`, `room/history_visibility_db_test.exs`, `history_visibility_unit_test.exs`). Loaded once by `test/test_helper.exs`
  (after the moderation / membership-state helpers it builds on); every function is `def`, so no suite carries an unused private helper (CI compiles
  with `--warnings-as-errors`).

  Everything talks to the REAL stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, the real `Room.Server` under Horde. The helpers never print
  a token, a message body or an event id list (a failing assertion names ids, markers are never printed).

  ## Decisions of the ATDD step (ambiguities of the story, recorded for the dev; the suites' moduledocs are binding like those of the earlier stories)

    * Binding signatures: `Room.DB.fetch_visible_events(room_id, viewer, direction, limit, from_token)` -> `{:ok, events, next_batch, prev_batch}`;
      `Room.DB.fetch_visible_events_since(room_id, viewer, last_event_id, limit)` -> `{:ok, events}`; `Room.DB.fetch_visible_event(event_id, room_id, viewer)` ->
      `{:ok, map} | {:error, :not_found} | {:error, reason}`; `Room.DB.fetch_visible_events_by_relation(room_id, viewer, event_id, rel_type, limit, opts)`
      -> `{:ok, events}`; `Room.DB.fetch_state_predecessors(slots, viewer: user_id)` (combinable with `strict: true`). A TEST db module reaches them through
      `:event_dispatcher, :messages_db_module`; a module that does not export one falls back to its unfiltered function. `Search.DB.search_messages/5`
      keeps its signature (its first argument IS the viewer).
    * "`end` is omitted" is asserted as "the key is absent OR the empty string" (`end_absent?/1`): today's router renders `next_batch` as `"end": ""`
      (Element stops on both); the dev may omit the key, `matrix_router_test.exs` l.737 and `matrix_client_compat_test.exs` l.2828 pin the KEY today.
    * "no event data anywhere" (`refute_leak!/2`): neither the event id NOR the marker of a hidden event appears in the raw response body. Where a response
      legitimately names a hidden event id (the `m.relates_to` of a visible reply) the test says so and checks the marker and the event list instead.
    * The `m.room.history_visibility` events of a fixture are written through `PUT /state/m.room.history_visibility/` by the room creator (level 100);
      `tick/0` separates every hv change, member change and message of a fixture whose visibility depends on the millisecond order (`fj`).
  """
  import ExUnit.Assertions
  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @hv "m.room.history_visibility"
  @values ["world_readable", "shared", "invited", "joined"]

  @doc "A unique single-token word (letters and digits only: one token of the `simple` text search configuration, so a marker is also a search term)."
  def word(label), do: label <> T.rand(8)

  def hv_type, do: @hv
  def hv_values, do: @values
  def marker_of(%{marker: m}), do: m

  # ─── fixtures through the HTTP API ───────────────────────────────────────────

  @doc "PUT /state/m.room.history_visibility/ with `value` (a map is sent as the content): the conn."
  def put_hv(user, room, value) when is_binary(value), do: put_state(user, room, @hv, %{"history_visibility" => value})
  def put_hv(user, room, content) when is_map(content), do: put_state(user, room, @hv, content)

  @doc "Writes the setting (clock-separated before and after) and returns the event id."
  def set_hv!(user, room, value) do
    tick()
    conn = put_hv(user, room, value)
    assert conn.status == 200, "set hv #{inspect(value)}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    id = T.json(conn)["event_id"]
    assert is_binary(id) and String.starts_with?(id, "$")
    tick()
    id
  end

  @doc "A private_chat room of `owner` with the setting `value` (a second hv event after the preset's `shared`): `{room, hv_event_id}`."
  def hv_room!(owner, value) do
    room = make_room(owner, %{"preset" => "private_chat"})
    {room, set_hv!(owner, room, value)}
  end

  @doc "A message of `user` with a random marker: `%{id, marker}` (clock-separated before)."
  def say_m!(user, room, label) do
    tick()
    m = word(label)
    %{id: say!(user, room, m), marker: m}
  end

  @doc "A thread reply / reaction / edit (`relate!`) with a random marker: `%{id, marker}`."
  def relate_m!(user, room, rel_type, parent_id, label, extra \\ %{}) do
    tick()
    m = word(label)
    %{id: Nebu.Matrix.RedactionTestSupport.relate!(user, room, rel_type, parent_id, m, extra), marker: m}
  end

  @doc "An invite of `target` by `owner` (clock-separated): the event id of the invite."
  def invite_ev!(owner, room, target) do
    tick()
    invite!(owner, room, target)
    tick()
    latest_member_event_id!(room, target)
  end

  @doc "A join (clock-separated by `join!/2`, and after): the event id of the join."
  def join_ev!(user, room) do
    join!(user, room)
    tick()
    latest_member_event_id!(room, user)
  end

  def leave_ev!(user, room) do
    leave!(user, room)
    tick()
    latest_member_event_id!(room, user)
  end

  def kick_ev!(owner, room, target) do
    tick()
    ok!(kick(owner, room, target), "kick")
    tick()
    latest_member_event_id!(room, target)
  end

  def ban_ev!(owner, room, target) do
    tick()
    ok!(ban(owner, room, target), "ban")
    tick()
    latest_member_event_id!(room, target)
  end

  def unban_ev!(owner, room, target) do
    tick()
    ok!(unban(owner, room, target), "unban")
    tick()
    latest_member_event_id!(room, target)
  end

  def latest_member_event_id!(room, target) do
    row = room |> member_events(uid_of(target)) |> Enum.max_by(&{&1.ts, &1.event_id})
    row.event_id
  end

  @doc """
  The fixture of AC1 / AC2: A creates a private room, writes the setting `value`, sends a TOPIC, m1; invites B; sends m2; B joins; A sends m3.
  Returns the users, the room and the ids / markers of every step.
  """
  def scenario!(value, opts \\ []) do
    a = user!("HVA")
    b = user!("HVB")
    {room, hv} = hv_room!(a, value)
    topic = Keyword.get(opts, :topic, word("topic"))
    topic_event = ok_event!(put_state(a, room, "m.room.topic", %{"topic" => topic}), "topic")
    tick()
    m1 = say_m!(a, room, "m1")
    invite = invite_ev!(a, room, b)
    m2 = say_m!(a, room, "m2")
    join = join_ev!(b, room)
    m3 = say_m!(a, room, "m3")
    %{a: a, b: b, room: room, hv: hv, topic: topic, topic_event: topic_event, m1: m1, invite: invite, m2: m2, join: join, m3: m3}
  end

  def ok_event!(conn, label) do
    assert conn.status == 200, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    id = T.json(conn)["event_id"]
    assert is_binary(id)
    id
  end

  # ─── reads ───────────────────────────────────────────────────────────────────

  def messages_req(user, room, query \\ "dir=b&limit=100"), do: T.matrix_request(:get, path(room, "messages") <> "?" <> query, user.at)

  @doc "GET /messages (200 asserted): `{chunk, body, raw}`."
  def msgs!(user, room, query \\ "dir=b&limit=100") do
    conn = messages_req(user, room, query)
    assert conn.status == 200, "messages?#{query}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert is_list(body["chunk"])
    {body["chunk"], body, conn.resp_body}
  end

  def ids(chunk), do: Enum.map(chunk, & &1["event_id"])

  @doc "`end` absent (or the empty string, see the moduledoc) in a /messages body."
  def end_absent?(body), do: Map.get(body, "end") in [nil, ""]

  @doc "Every page of a backward (`dir=b`) or forward (`dir=f`) walk with `limit`: `[{chunk, body}]` (bounded at 60 pages)."
  def walk!(user, room, dir, limit, from \\ nil) do
    do_walk(user, room, dir, limit, from, [], 0)
  end

  defp do_walk(_user, _room, _dir, _limit, _from, acc, 60), do: Enum.reverse(acc)

  defp do_walk(user, room, dir, limit, from, acc, n) do
    query = "dir=#{dir}&limit=#{limit}" <> if(from, do: "&from=" <> URI.encode_www_form(from), else: "")
    {chunk, body, _raw} = msgs!(user, room, query)
    acc = [{chunk, body} | acc]

    if end_absent?(body) do
      Enum.reverse(acc)
    else
      do_walk(user, room, dir, limit, body["end"], acc, n + 1)
    end
  end

  def walked_ids(pages), do: pages |> Enum.flat_map(fn {chunk, _} -> ids(chunk) end)

  def event_conn(user, room, event_id), do: T.matrix_request(:get, path(room, "event/#{enc(event_id)}"), user.at)

  def relations_conn(user, room, event_id, query \\ "limit=100"),
    do: T.matrix_request(:get, "/_matrix/client/v1/rooms/#{enc(room)}/relations/#{enc(event_id)}?#{query}", user.at)

  def initial_sync_conn(user, room), do: T.matrix_request(:get, path(room, "initialSync"), user.at)

  @doc "The timeline of an INITIAL /sync of `user` for `room`: `{events, join_entry, raw}` (the room must be in rooms.join)."
  def initial_timeline!(user, room) do
    conn = sync_conn(user, since: nil, timeout: 0)
    assert conn.status == 200, "sync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert in_section?(body, "join", room), "control: the room is in rooms.join"
    entry = get_in(body, ["rooms", "join", room])
    {join_timeline(body, room), entry, conn.resp_body}
  end

  @doc "POST /search (200 asserted): `{results (event maps), body, raw}`. `opts`: `:limit`, `:rooms`, `:order_by`, `:next_batch`."
  def search!(user, term, opts \\ []) do
    filter = %{"limit" => Keyword.get(opts, :limit, 50)}
    filter = if rooms = Keyword.get(opts, :rooms), do: Map.put(filter, "rooms", rooms), else: filter
    room_events = %{"search_term" => term, "filter" => filter}
    room_events = if ob = Keyword.get(opts, :order_by), do: Map.put(room_events, "order_by", ob), else: room_events
    query = if nb = Keyword.get(opts, :next_batch), do: "?next_batch=" <> URI.encode_www_form(nb), else: ""
    conn = T.matrix_request(:post, "/_matrix/client/v3/search" <> query, user.at, body: %{"search_categories" => %{"room_events" => room_events}})
    assert conn.status == 200, "search: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    re = body["search_categories"]["room_events"]
    {Enum.map(re["results"], & &1["result"]), re, conn.resp_body}
  end

  @doc "Every page of a search: `[{results, room_events, raw}]` (bounded at 20 pages)."
  def search_all!(user, term, limit) do
    do_search_all(user, term, limit, nil, [], 0)
  end

  defp do_search_all(_user, _term, _limit, _nb, acc, 20), do: Enum.reverse(acc)

  defp do_search_all(user, term, limit, nb, acc, n) do
    {results, re, raw} = search!(user, term, limit: limit, next_batch: nb)
    acc = [{results, re, raw} | acc]
    if re["next_batch"] in [nil, ""], do: Enum.reverse(acc), else: do_search_all(user, term, limit, re["next_batch"], acc, n + 1)
  end

  @doc "The token format of the pagination (`Room.DB`, documented): an arbitrary position `(ts, event_id)` as a `from` token."
  def token(ts, event_id), do: "v1_" <> Base.url_encode64("#{ts}:#{event_id}", padding: false)

  def ts_of(event_id), do: T.sql!("SELECT origin_server_ts FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()

  # ─── assertions ──────────────────────────────────────────────────────────────

  @doc "`raw` names neither the id NOR the marker of any of `hidden` (`%{id, marker}` maps, plain ids / markers as strings)."
  def refute_leak!(raw, hidden) do
    for h <- List.wrap(hidden) do
      case h do
        %{id: id, marker: marker} ->
          refute String.contains?(raw, id), "the response names a hidden event id"
          refute String.contains?(raw, marker), "the response carries the content of a hidden event"

        text when is_binary(text) ->
          refute String.contains?(raw, text), "the response carries a hidden value"
      end
    end

    :ok
  end

  @doc "Every one of `shown` is in `chunk` (by event id) AND its marker is in the raw body."
  def assert_shown!(chunk, raw, shown) do
    for s <- List.wrap(shown) do
      assert s.id in ids(chunk), "an expected event is missing from the page"
      assert String.contains?(raw, s.marker), "an expected event has no content in the response"
    end

    :ok
  end

  @doc "`/event` or `/relations` refusal of an unseen event: `404 M_NOT_FOUND`, the fixed `Event not found`, exactly `{errcode, error}`; the raw body."
  def assert_event_404!(conn) do
    assert conn.status == 404, "expected 404, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert body == %{"errcode" => "M_NOT_FOUND", "error" => "Event not found"}, "the 404 body is exactly the fixed text: #{conn.resp_body}"
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    conn.resp_body
  end

  def assert_room_404!(conn) do
    assert conn.status == 404
    assert T.json(conn) == %{"errcode" => "M_NOT_FOUND", "error" => "Room not found"}
    conn.resp_body
  end

  # ─── direct inserts (own rooms only; the cleanup is registered) ──────────────

  @doc "An own room row for direct inserts (the `rooms` row, no process): the room id; its events are deleted in `on_exit` (DELETE result asserted)."
  def raw_room! do
    room = "!hv#{T.rand(6)}:#{T.server_name()}"
    assert {:ok, _} = DB.insert_room(room)
    Nebu.Matrix.MembershipStateTestSupport.cleanup_room_events_on_exit(room)
    room
  end

  @doc "An event inserted WITHOUT the room process; `state_key` nil for a non-state event; returns the event id (`id:` chooses it)."
  def put_event!(room, sender, type, content, ts, state_key \\ nil, id \\ nil) do
    id = id || "$" <> T.rand(12)

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => uid_of(sender),
               "type" => type,
               "state_key" => state_key,
               "content" => content,
               "origin_server_ts" => ts
             })

    id
  end

  def put_message!(room, sender, body, ts, id \\ nil), do: put_event!(room, sender, "m.room.message", %{"msgtype" => "m.text", "body" => body}, ts, nil, id)

  def put_hv_event!(room, sender, value, ts, id \\ nil), do: put_event!(room, sender, @hv, %{"history_visibility" => value}, ts, "", id)

  @doc "A state event of the hv type whose content is the double-encoded JSONB STRING form (`to_jsonb(<text>)`): the event id."
  def put_hv_string!(room, sender, text, ts) do
    id = "$" <> T.rand(12)

    T.privileged_sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, $4, to_jsonb($5::text), $6, '')",
      [id, room, uid_of(sender), @hv, text, ts]
    )

    id
  end

  @doc "A `room_members` row with chosen `joined_at` / `left_at` (a legacy or a fail-open row; no member event)."
  def put_row!(room, user, joined_at, left_at \\ nil) do
    T.privileged_sql!(
      "INSERT INTO room_members (room_id, user_id, joined_at, left_at) VALUES ($1, $2, $3, $4) ON CONFLICT (room_id, user_id) DO UPDATE SET joined_at = EXCLUDED.joined_at, left_at = EXCLUDED.left_at",
      [room, uid_of(user), joined_at, left_at]
    )

    :ok
  end

  def uid(label), do: "@#{label}#{T.rand(4)}:#{T.server_name()}"

  # ─── the model (an independent re-implementation of the rule over the STORED rows; used by the model tests, never by the code under test) ──────────

  @doc """
  The stored hv events and the viewer's member events of `room` as the model reads them: `{hv_rows, member_rows}`, each `%{ts, id, ...}`.
  `value` is normalised (unknown -> shared), `m` is the normalised membership.
  """
  def model_rows(room, viewer) do
    hv =
      T.sql!("SELECT origin_server_ts, event_id, content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = ''", [room, @hv]).rows
      |> Enum.map(fn [ts, id, content] -> %{ts: ts, id: id, value: normalise_value(content_of(content))} end)

    mem =
      room
      |> member_events(uid_of(viewer))
      |> Enum.map(fn r -> %{ts: r.ts, id: r.event_id, m: Nebu.Matrix.MembershipStateTestSupport.normalise(r.content["membership"])} end)

    {hv, mem}
  end

  defp normalise_value(%{"history_visibility" => v}) when v in @values, do: v
  defp normalise_value(_), do: "shared"

  def allow?(h, m), do: h in ["world_readable", "shared"] or m == "join" or (m == "invite" and h == "invited")

  @rank %{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}

  @doc "The viewer's state AFTER millisecond `t` (`<= t`): `{h, m}`, ties as the D3 order (most restrictive latest, then event_id DESC)."
  def state_at({hv, mem}, t) do
    h = hv |> Enum.filter(&(&1.ts <= t)) |> Enum.sort_by(&{-&1.ts, invert(&1.id)}) |> List.first() |> then(&if(&1, do: &1.value, else: "shared"))

    m =
      mem
      |> Enum.filter(&(&1.ts <= t))
      |> Enum.sort_by(&{-&1.ts, Map.get(@rank, &1.m, 1), invert(&1.id)})
      |> List.first()
      |> then(&if(&1, do: &1.m, else: "none"))

    {h, m}
  end

  defp invert(id), do: id |> :binary.bin_to_list() |> Enum.map(&(255 - &1))

  @doc "An ORDINARY event at `ts` is visible iff the state just before AND just after that millisecond allow it (D2 (c))."
  def model_visible?(rows, ts) do
    {h1, m1} = state_at(rows, ts - 1)
    {h2, m2} = state_at(rows, ts)
    allow?(h1, m1) and allow?(h2, m2)
  end

  @doc """
  The D5 verdict of a SPECIAL event over the model rows, a second independent definition (not the SQL's formula): an hv event `{:hv, row}` is visible iff for BOTH sides of its
  millisecond (the viewer's membership before and after it) the setting before it OR its own value allows; a member event of the viewer `{:member, row}` is visible iff for BOTH
  sides of its millisecond (the setting before and after) the membership before it (D3 order, strictly) OR its own membership allows.
  """
  def model_special_visible?({_hv, _mem} = rows, {:hv, x}) do
    {h_lt, m_lt} = state_at(rows, x.ts - 1)
    {_h_le, m_le} = state_at(rows, x.ts)
    Enum.all?([m_lt, m_le], fn m -> allow?(h_lt, m) or allow?(x.value, m) end)
  end

  def model_special_visible?({_hv, mem} = rows, {:member, x}) do
    {h_lt, _} = state_at(rows, x.ts - 1)
    {h_le, _} = state_at(rows, x.ts)

    prev =
      mem
      |> Enum.filter(fn y -> y.ts < x.ts or (y.ts == x.ts and (Map.get(@rank, y.m, 1) > Map.get(@rank, x.m, 1) or (Map.get(@rank, y.m, 1) == Map.get(@rank, x.m, 1) and y.id < x.id))) end)
      |> Enum.sort_by(&{-&1.ts, Map.get(@rank, &1.m, 1), invert(&1.id)})
      |> List.first()
      |> then(&if(&1, do: &1.m, else: "none"))

    Enum.all?([h_lt, h_le], fn h -> allow?(h, prev) or allow?(h, x.m) end)
  end

  # ─── logs ────────────────────────────────────────────────────────────────────

  @doc "`fun` with the Logger at `level`, capturing every line it writes: `{result, log}`."
  def capture_at(level, fun) do
    {result, log} =
      ExUnit.CaptureLog.with_log([level: level], fn ->
        Nebu.Matrix.MembershipStateTestSupport.with_logger_level(level, fun)
      end)

    {result, log}
  end

  def error_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[error]"))
end

defmodule Nebu.Matrix.HistoryVisibilityTestSupport.Hooks do
  @moduledoc """
  Armed db hooks of the story `history-visibility-enforcement` tests (node-local, keyed by room, restored by the caller's `on_exit` through `cleanup/0`):

    * `MessagesDB` (installed as `:event_dispatcher, :messages_db_module`): delegates EVERYTHING to the real `Room.DB`; the viewer-aware reads
      (`fetch_visible_events/5`, `fetch_visible_events_since/4`, `fetch_visible_event/3`, `fetch_visible_events_by_relation/6`) of the ARMED room can FAIL
      (`{:error, :atdd_injected}`); every call of them is COUNTED per function. The unfiltered reads are counted too (`fetch_events/4`, ...): a call of an
      unfiltered read by a client-serving path would be visible there.
    * `SearchDB` (installed as `:event_dispatcher, :search_db_module`): `search_messages/5` fails for the armed viewer.
  """
  @armed :atdd_hv_armed
  @calls :atdd_hv_calls

  @doc "`fun` (one of the hooked function names) fails for `room` (`room: :any` = every room)."
  def arm(fun, room), do: Application.put_env(:nebu, @armed, Map.put(Application.get_env(:nebu, @armed, %{}), fun, room))
  def disarm(fun), do: Application.put_env(:nebu, @armed, Map.delete(Application.get_env(:nebu, @armed, %{}), fun))

  def cleanup do
    Application.delete_env(:nebu, @armed)
    Application.delete_env(:nebu, @calls)
  end

  @doc "Installs both modules (restored in the caller's on_exit)."
  def install! do
    for {app, key, mod} <- [
          {:event_dispatcher, :messages_db_module, __MODULE__.MessagesDB},
          {:event_dispatcher, :search_db_module, __MODULE__.SearchDB}
        ] do
      prior = Application.fetch_env(app, key)
      Application.put_env(app, key, mod)

      ExUnit.Callbacks.on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    ExUnit.Callbacks.on_exit(&cleanup/0)
    :ok
  end

  @doc "How often the hooked function `fun` was called since `cleanup/0` (all rooms)."
  def calls(fun), do: Map.get(Application.get_env(:nebu, @calls, %{}), fun, 0)

  @doc false
  def hook(fun, room, args, real_mod) do
    Application.put_env(:nebu, @calls, Map.update(Application.get_env(:nebu, @calls, %{}), fun, 1, &(&1 + 1)))

    case Map.get(Application.get_env(:nebu, @armed, %{}), fun) do
      armed when armed == :any or armed == room -> {:error, :atdd_injected}
      _ -> apply(real_mod, fun, args)
    end
  end

  defmodule MessagesDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB
    alias Nebu.Matrix.HistoryVisibilityTestSupport.Hooks

    # story sync-stream-position (DELIBERATE amendment, old -> new): `fetch_visible_events_in_range/5` (the incremental /sync read by position) and the bounded page
    # `fetch_visible_events/6` (the initial /sync read, bounded by the head) are hooked like their timestamp / unbounded twins
    @explicit [:fetch_visible_events, :fetch_visible_events_since, :fetch_visible_events_in_range, :fetch_visible_event, :fetch_visible_events_by_relation, :fetch_events, :fetch_events_since, :fetch_event, :fetch_events_by_relation]

    for {name, arity} <- DB.__info__(:functions), name not in @explicit do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    # the unfiltered reads: counted (a client-serving path must not call them), never failed
    def fetch_events(r, d, l, f), do: counted(:fetch_events, [r, d, l, f])
    def fetch_events_since(r, a, l), do: counted(:fetch_events_since, [r, a, l])
    def fetch_event(e, r), do: counted(:fetch_event, [e, r])
    def fetch_events_by_relation(r, e, t, l, o \\ %{}), do: counted(:fetch_events_by_relation, [r, e, t, l, o])

    # the viewer-aware reads: armed by room; defined by NAME (the real functions may not exist yet: dynamic `apply/3`)
    def fetch_visible_events(room, viewer, dir, limit, from), do: Hooks.hook(:fetch_visible_events, room, [room, viewer, dir, limit, from], DB)
    def fetch_visible_events(room, viewer, dir, limit, from, head), do: Hooks.hook(:fetch_visible_events, room, [room, viewer, dir, limit, from, head], DB)
    def fetch_visible_events_since(room, viewer, last, limit), do: Hooks.hook(:fetch_visible_events_since, room, [room, viewer, last, limit], DB)
    def fetch_visible_events_in_range(room, viewer, after_pos, head, limit), do: Hooks.hook(:fetch_visible_events_in_range, room, [room, viewer, after_pos, head, limit], DB)
    def fetch_visible_event(event_id, room, viewer), do: Hooks.hook(:fetch_visible_event, room, [event_id, room, viewer], DB)

    def fetch_visible_events_by_relation(room, viewer, event_id, rel_type, limit, opts \\ %{}),
      do: Hooks.hook(:fetch_visible_events_by_relation, room, [room, viewer, event_id, rel_type, limit, opts], DB)

    defp counted(fun, args) do
      Application.put_env(:nebu, :atdd_hv_calls, Map.update(Application.get_env(:nebu, :atdd_hv_calls, %{}), fun, 1, &(&1 + 1)))
      apply(DB, fun, args)
    end
  end

  defmodule SearchDB do
    @moduledoc false
    alias Nebu.Matrix.Search.DB
    alias Nebu.Matrix.HistoryVisibilityTestSupport.Hooks

    for {name, arity} <- DB.__info__(:functions), name not in [:search_messages] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def search_messages(user, term, limit, offset, room_filter \\ []), do: Hooks.hook(:search_messages, :any_room, [user, term, limit, offset, room_filter], DB)
  end
end
