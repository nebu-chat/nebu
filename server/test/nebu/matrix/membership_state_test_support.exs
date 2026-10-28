defmodule Nebu.Matrix.MembershipStateTestSupport do
  @moduledoc """
  Shared helpers of the story `membership-state-model` suites (`membership_state_http_test.exs`, `membership_state_upgrade_http_test.exs`,
  `membership_state_concurrency_test.exs`, `room/member_state_slice_db_test.exs`, `membership_state_unit_test.exs`). Loaded once by
  `test/test_helper.exs` (after the moderation / power-level / redaction helpers they build on); every function is `def`, so no suite carries an
  unused private helper (CI compiles with `--warnings-as-errors`).

  Everything talks to the REAL stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, the real `Room.Server` under Horde. The helpers never
  print a token, a reason or a displayname.

  ## Decisions of the ATDD step (ambiguities of the story, recorded for the dev)

    * The db seam of the member slice is `messages_db_module()` (`:event_dispatcher, :messages_db_module`), the module `build_state_events/3` already
      reads its create / name / generic-state / predecessor rows through. The upgrade's `Room.DB.direct_invitees/1` goes through `rooms_db_module()`,
      next to `banned_members/1`.
    * `Room.DB.member_state_slice(room_id, opts)` -> `{:ok, [%{event_id, state_key, sender, content, origin_server_ts, membership}]}`; `opts` =
      `:membership` / `:not_membership` (a membership string or nil: a slot is kept when it matches the first AND does not match the second, both
      compared on the NORMALISED membership) and `:other_cap` (default 10 000, the D4 cap of the non-joined slots: the test seam of the story). The list is
      ordered join, invite, ban, knock, leave, then `state_key` ascending (the D6 order).
    * The statement of the slice carries the leading marker comment `/* member_state_slice */` (as `/* state_predecessors */`): the statement-count
      tests find it by that name.
    * `Room.DB.direct_invitees(old_room_id)` -> `{:ok, MapSet.t()}` of the users whose OWN latest `invite` event had `is_direct: true`.
    * The dispatcher function of `GET /members` is `Nebu.Matrix.EventDispatcher.Server.get_room_members/2` (the story's name).
  """
  import ExUnit.Assertions
  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.OAuth.TestSupport, as: T

  @slice_marker "/* member_state_slice */"
  @pred_marker "/* state_predecessors */"
  @rank %{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}
  @classes %{"join" => 0, "invite" => 1, "ban" => 2, "knock" => 3, "leave" => 4}

  def slice_marker, do: @slice_marker
  def predecessor_marker, do: @pred_marker

  @doc "Limiter off, server name pinned: the `setup` of every suite of the story (the `on_exit` restores the limiter)."
  def setup_env! do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    ExUnit.Callbacks.on_exit(fn -> T.restore_rate_limits() end)

    # the node-wide gate of slice reads (default 3 concurrent) would turn the deliberately concurrent reads of these suites into 503s:
    # every suite lifts it, the gate tests of AC19 (d) / (e) set their own limit (and delete the key to see the default)
    prior = Application.fetch_env(:nebu, :member_slice_max_concurrency)
    Application.put_env(:nebu, :member_slice_max_concurrency, 1_000)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:nebu, :member_slice_max_concurrency, v)
        :error -> Application.delete_env(:nebu, :member_slice_max_concurrency)
      end
    end)

    :ok
  end

  # ─── the scenario of AC1 ─────────────────────────────────────────────────────

  @doc """
  The room R of AC1: `public_chat`, creator A at 100; B joins; C is invited by A; D joins and is banned by A with `reason` (default "spam"); E joins and
  leaves; F joins and is kicked by A with `reason2` (default "off topic"); G is invited and declines. Then A sends `messages` (default 25) messages, so
  every member event lies OUTSIDE the 20-event window of an initial `/sync`. Returns the users, the room and the reasons.
  """
  def scenario!(opts \\ []) do
    reason = Keyword.get(opts, :reason, "spam")
    reason2 = Keyword.get(opts, :reason2, "off topic")
    [a, b, c, d, e, f, g] = for p <- ~w(MSA MSB MSC MSD MSE MSF MSG), do: user!(p)
    room = public_room(a)

    join!(b, room)
    invite!(a, room, c)
    join!(d, room)
    ok!(ban(a, room, d, %{"reason" => reason}), "ban D")
    join!(e, room)
    leave!(e, room)
    join!(f, room)
    ok!(kick(a, room, f, %{"reason" => reason2}), "kick F")
    invite!(a, room, g)
    leave!(g, room)

    for _ <- 1..Keyword.get(opts, :messages, 25)//1, do: say!(a, room, marker("msg"))

    %{room: room, a: a, b: b, c: c, d: d, e: e, f: f, g: g, reason: reason, reason2: reason2}
  end

  @doc "The latest member event row of `uid` in the D3 order (`origin_server_ts DESC`, the most restrictive membership first, `event_id DESC`), computed here."
  def latest_row(room, uid) do
    room
    |> member_events(uid)
    |> Enum.sort_by(fn row -> {-row.ts, Map.get(@rank, row.content["membership"], 1), invert(row.event_id)} end)
    |> List.first()
  end

  # `event_id DESC` as an ascending key
  defp invert(id), do: id |> :binary.bin_to_list() |> Enum.map(&(255 - &1))

  def membership_of_row(row), do: normalise(row.content["membership"])

  def normalise(m) when m in ["ban", "leave", "invite", "knock", "join"], do: m
  def normalise(_other), do: "leave"

  @doc "The D6 order of a slice / chunk: join, invite, ban, knock, leave, then `state_key` ascending."
  def class_of(membership), do: Map.fetch!(@classes, membership)

  # ─── requests ────────────────────────────────────────────────────────────────

  def members_path(room, query \\ ""), do: path(room, "members") <> if(query == "", do: "", else: "?" <> query)
  def members_conn(user, room, query \\ ""), do: T.matrix_request(:get, members_path(room, query), user.at)

  @doc "GET /members (200 asserted): the decoded body."
  def members!(user, room, query \\ "") do
    conn = members_conn(user, room, query)
    assert conn.status == 200, "members?#{query}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    body = T.json(conn)
    assert Map.keys(body) == ["chunk"], "the body is exactly {chunk}: #{String.slice(conn.resp_body, 0, 200)}"
    body
  end

  def chunk!(user, room, query \\ ""), do: members!(user, room, query)["chunk"]

  def initial_sync!(user, room) do
    conn = T.matrix_request(:get, path(room, "initialSync"), user.at)
    assert conn.status == 200, "initialSync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)
  end

  @doc "The member slots of a list of state events, by `state_key`: `%{uid => event}` (a user listed twice fails)."
  def slots(events) do
    members = Enum.filter(events, &(&1["type"] == "m.room.member"))
    keys = Enum.map(members, & &1["state_key"])
    assert keys == Enum.uniq(keys), "every user has at most ONE member slot, got #{inspect(keys -- Enum.uniq(keys))}"
    Map.new(members, &{&1["state_key"], &1})
  end

  def membership_pairs(events) do
    events |> Enum.filter(&(&1["type"] == "m.room.member")) |> Enum.map(&{&1["state_key"], &1["content"]["membership"]}) |> Enum.sort()
  end

  def pairs(list), do: list |> Enum.map(fn {u, m} -> {uid_of(u), m} end) |> Enum.sort()

  @doc "The member events of `rooms.join[room].state.events` of an initial `/sync` of `user`: the whole decoded sync body is returned too."
  def initial_state(user, room) do
    body = sync(user)
    assert in_section?(body, "join", room), "control: the room is in rooms.join"
    {join_state(body, room), body}
  end

  # ─── assertions ──────────────────────────────────────────────────────────────

  @predecessor_keys ["prev_content", "prev_sender", "replaces_state"]

  @doc """
  One served member slot `ev` against the STORED latest row of the user: the real event id, `origin_server_ts`, `sender`, `content` (strict map equality),
  the membership, and `unsigned` = `age` (an integer >= 1) plus, when `predecessor` is given as `{event_id, membership, sender}`, exactly the three
  predecessor keys (the keys together or not at all). `room_id` is asserted only when `room_id:` is given (`/members`, `/initialSync`: ClientEvent).
  """
  def assert_slot!(ev, room, uid, expected_membership, expected_sender, predecessor, room_id? \\ nil) do
    row = latest_row(room, uid)
    assert ev, "the user #{inspect(uid)} has a member slot"
    assert membership_of_row(row) == expected_membership, "fixture: the stored latest membership"
    assert ev["type"] == "m.room.member" and ev["state_key"] == uid
    assert ev["event_id"] == row.event_id, "the REAL event id of the stored row"
    refute String.starts_with?(ev["event_id"], "$synth_")
    assert ev["origin_server_ts"] == row.ts
    assert ev["sender"] == expected_sender and row.sender == expected_sender
    assert ev["content"] == row.content, "the STORED content, nothing synthesized"
    assert ev["content"]["membership"] == expected_membership
    if room_id?, do: assert(ev["room_id"] == room_id?, "room_id of a ClientEvent")

    unsigned = ev["unsigned"]
    assert is_map(unsigned), "the slot carries unsigned"
    assert is_integer(unsigned["age"]) and unsigned["age"] >= 1

    case predecessor do
      nil ->
        assert Map.keys(unsigned) == ["age"], "no predecessor: unsigned is exactly {age}, got #{inspect(Map.keys(unsigned))}"

      {pred_id, pred_membership, pred_sender} ->
        assert Enum.sort(Map.keys(unsigned)) == Enum.sort(["age" | @predecessor_keys]), "unsigned = age + the three predecessor keys, got #{inspect(Map.keys(unsigned))}"
        assert unsigned["replaces_state"] == pred_id
        assert unsigned["prev_content"]["membership"] == pred_membership
        assert unsigned["prev_sender"] == pred_sender
    end

    ev
  end

  @doc "The event id of the member event of `uid` in `room` BEFORE the latest one (the predecessor the ban / kick / decline replaced)."
  def previous_row(room, uid) do
    [_latest, previous | _] = room |> member_events(uid) |> Enum.sort_by(&{-&1.ts, invert(&1.event_id)})
    previous
  end

  @doc "Asserts the seven slots of the scenario (the shape of AC1 (a) / AC2 (a) / AC3): memberships, senders, ids, content, unsigned."
  def assert_scenario_slots!(by_key, s, room_id? \\ nil) do
    room = s.room
    assert Enum.sort(Map.keys(by_key)) == Enum.sort(Enum.map([s.a, s.b, s.c, s.d, s.e, s.f, s.g], & &1.uid)), "exactly one slot per user A-G"

    pred = fn user, membership ->
      prev = previous_row(room, user.uid)
      assert prev.content["membership"] == membership, "fixture: the predecessor of #{membership}"
      {prev.event_id, membership, prev.sender}
    end

    assert_slot!(by_key[s.a.uid], room, s.a.uid, "join", s.a.uid, nil, room_id?)
    assert_slot!(by_key[s.b.uid], room, s.b.uid, "join", s.b.uid, nil, room_id?)
    assert_slot!(by_key[s.c.uid], room, s.c.uid, "invite", s.a.uid, nil, room_id?)
    ban = assert_slot!(by_key[s.d.uid], room, s.d.uid, "ban", s.a.uid, pred.(s.d, "join"), room_id?)
    assert ban["content"]["reason"] == s.reason
    assert_slot!(by_key[s.e.uid], room, s.e.uid, "leave", s.e.uid, pred.(s.e, "join"), room_id?)
    kick = assert_slot!(by_key[s.f.uid], room, s.f.uid, "leave", s.a.uid, pred.(s.f, "join"), room_id?)
    assert kick["content"]["reason"] == s.reason2
    assert_slot!(by_key[s.g.uid], room, s.g.uid, "leave", s.g.uid, pred.(s.g, "invite"), room_id?)
    :ok
  end

  # ─── statement counting (telemetry of the repo), as member_prev_content_http_test.exs ─────────────────────────

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid, allow: allow} = config) do
    mine? = self() == pid or pid in (Process.get(:"$callers") || []) or self() in allow
    keep_tx? = Map.get(config, :keep_tx, false)
    noise? = if keep_tx?, do: String.contains?(query, "operational_logs") or String.contains?(query, "\"audit_log\""), else: noise?(query)
    if mine? and not noise?, do: send(pid, {:ms_statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp noise?(query), do: query in ["begin", "commit", "rollback"] or String.contains?(query, "operational_logs") or String.contains?(query, "\"audit_log\"")

  @doc "Runs `fun`, returns `{result, statements}`: only the statements of the calling process, its tasks and the room processes of `rooms`."
  def count_statements(fun, rooms \\ [], opts \\ []) do
    id = "ms-count-#{T.rand(6)}"
    allow = for room <- rooms, {:ok, pid} <- [Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)], do: pid
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self(), allow: allow, keep_tx: Keyword.get(opts, :keep_tx, false)})

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:ms_statement, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def marker_count(statements, marker), do: Enum.count(statements, &String.contains?(&1, marker))
  def slice_count(statements), do: marker_count(statements, @slice_marker)
  def predecessor_count(statements), do: marker_count(statements, @pred_marker)

  @doc "The statements that touch the room data (`events`, `rooms`, `room_members`), the request authentication (sessions, users, devices) excluded."
  def room_statements(statements), do: Enum.filter(statements, &Regex.match?(~r/\b(events|rooms|room_members)\b/, &1))

  def listing(statements), do: statements |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.slice(0, 120))) |> Enum.join("\n")

  # ─── direct inserts (own rooms only) ─────────────────────────────────────────

  @doc "A member event written WITHOUT the room process, the content a JSONB OBJECT: returns the event id."
  def put_member!(room, uid, membership, sender, ts, extra \\ %{}), do: insert_member_event!(room, uid, membership, sender, ts, extra)

  @doc "A member event with a CHOSEN event id (the tie-order tests need ids whose `event_id DESC` order is the opposite of the rank order): returns the id."
  def put_member_id!(room, uid, membership, sender, ts, id, extra \\ %{}) do
    assert :ok =
             Nebu.Matrix.Room.DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => uid_of(sender),
               "type" => "m.room.member",
               "state_key" => uid_of(uid),
               "content" => Map.put(extra, "membership", membership),
               "origin_server_ts" => ts
             })

    id
  end

  @doc "`chunk` / `events` without `unsigned.age` (the age moves with the clock): everything else must be identical between two reads."
  def strip_age(events) do
    Enum.map(events, fn ev ->
      case ev do
        %{"unsigned" => %{} = unsigned} -> Map.put(ev, "unsigned", Map.delete(unsigned, "age"))
        other -> other
      end
    end)
  end

  @doc "A member event whose content is stored as the double-encoded JSONB STRING form (`to_jsonb(<json text>)`): the event id. `content` may be a map or a raw text."
  def put_string_member!(room, uid, content, sender, ts) do
    id = "$" <> T.rand(12)
    text = if is_binary(content), do: content, else: Jason.encode!(content)

    T.privileged_sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, 'm.room.member', to_jsonb($4::text), $5, $6)",
      [id, room, uid_of(sender), text, ts, uid_of(uid)]
    )

    id
  end

  @doc "Bulk-inserts `count` member events (distinct random users, memberships cycling over `kinds`, strictly distinct timestamps starting at `base_ts`) into `room`: returns `[{uid, membership, ts}]`. One statement."
  def bulk_members!(room, count, kinds, base_ts, sender) do
    rows = for i <- 1..count, do: {"@msb#{i}x#{T.rand(5)}:#{T.server_name()}", Enum.at(kinds, rem(i - 1, length(kinds))), base_ts + i}

    T.privileged_sql!(
      """
      INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key)
      SELECT '$bulk' || md5(u || $1), $2, $3, 'm.room.member', jsonb_build_object('membership', m), t, u
      FROM unnest($4::text[], $5::text[], $6::bigint[]) AS x(u, m, t)
      """,
      [T.rand(6), room, uid_of(sender), Enum.map(rows, &elem(&1, 0)), Enum.map(rows, &elem(&1, 1)), Enum.map(rows, &elem(&1, 2))]
    )

    rows
  end

  @doc "Registers the cleanup of every event of `room` (the DELETE result asserted): a future-stamped or bulk row must not stay in the shared database (follow-up `fj`)."
  def cleanup_room_events_on_exit(room) do
    ExUnit.Callbacks.on_exit(fn ->
      assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room], [])
    end)
  end

  @doc "A member of the member set WITHOUT any member event (a legacy row): the `room_members` row is inserted, then the room process restarted."
  def legacy_member!(room, uid) do
    assert :ok = Nebu.Matrix.Room.DB.insert_member(room, uid_of(uid))
    kill_and_restart!(room)
    assert in_set?(room, uid_of(uid)), "fixture: the legacy member is in the member set after the restart"
    assert member_events(room, uid_of(uid)) == [], "fixture: the legacy member has no member event"
  end

  @doc "The ids of the `rooms` rows named `room` (0 or 1): the refusal tests assert that an unknown room id gets NO row."
  def room_rows(room), do: rooms_row_count(room)

  @doc "An unknown, well-formed room id (never created)."
  def unknown_room, do: "!" <> T.rand(10) <> ":" <> T.server_name()

  @doc "The replay of `events` (state first, then the timeline, in order): `%{state_key => latest membership}` of the member events."
  def replay(events) do
    events |> Enum.filter(&(&1["type"] == "m.room.member")) |> Enum.reduce(%{}, &Map.put(&2, &1["state_key"], &1["content"]["membership"]))
  end

  @doc "`Logger` at `level` for the callback (restored afterwards)."
  def with_logger_level(level, fun) do
    original = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original)
    end
  end
end

defmodule Nebu.Matrix.MembershipStateTestSupport.Hooks do
  @moduledoc """
  Armed db hooks of the story `membership-state-model` tests (node-local, keyed by room / user, restored by the caller's `on_exit`):

    * `SliceDB` (installed as `:event_dispatcher, :messages_db_module`): delegates EVERYTHING to the real `Room.DB`; `member_state_slice/2` of the armed
      room is COUNTED, can FAIL (`{:error, :atdd_injected}`) and can BLOCK right after the real read returned (until the test sends `:go`): the
      read-before-commit gap of the concurrency suite.
    * `DirectDB` (installed as `:event_dispatcher, :rooms_db_module`): delegates everything; `direct_invitees/1` can fail.
    * `StatusDB` (installed as `:event_dispatcher, :rooms_db_module`): delegates everything; `get_room_status/1` of the armed room can fail.
    * `InviteRoomDB` (installed as `:room_manager, :db_module`): delegates everything; `apply_member_change/4` of an INVITE write (`require_pending_invitation`)
      for the armed invitee fails (`mode: :kill`: the room process kills itself in the write).
  """

  def arm(key, spec), do: Application.put_env(:nebu, key, spec)
  def disarm(key), do: Application.delete_env(:nebu, key)
  def disarm_all, do: Enum.each([:atdd_ms_slice, :atdd_ms_direct, :atdd_ms_invite, :atdd_ms_calls, :atdd_ms_status, :atdd_ms_pred], &disarm/1)

  # the real function of a module (a variable name: the files compile before the function exists)
  def real(mod, fun, args), do: apply(mod, String.to_atom(fun), args)

  @doc "Starts counting the `member_state_slice/2` calls of `room` (through `SliceDB`): returns the counter ref (`:counters.get(ref, 1)`)."
  def slice_counter(room) do
    ref = :counters.new(1, [])
    Application.put_env(:nebu, :atdd_ms_calls, Map.put(Application.get_env(:nebu, :atdd_ms_calls, %{}), room, ref))
    ref
  end

  def slice_hook(room, opts, args) do
    spec = Application.get_env(:nebu, :atdd_ms_slice)

    case Map.get(Application.get_env(:nebu, :atdd_ms_calls, %{}), room) do
      nil -> :ok
      ref -> :counters.add(ref, 1, 1)
    end

    case spec do
      %{room: ^room, fail: true} ->
        {:error, :atdd_injected}

      %{room: ^room, fail: :connection} ->
        {:error, %DBConnection.ConnectionError{message: "connection not available and request was dropped from queue after 2000ms", severity: :error, reason: :queue_timeout}}

      %{room: ^room, fail: :connection_raise} ->
        raise DBConnection.ConnectionError, message: "tcp recv: closed", severity: :error, reason: :error

      %{room: ^room, fail: :timeout} ->
        {:error, %Postgrex.Error{postgres: %{code: :query_canceled, pg_code: "57014", severity: "ERROR", message: "canceling statement due to statement timeout"}}}

      %{room: ^room, block: test} when is_pid(test) ->
        result = real(Nebu.Matrix.Room.DB, "member_state_slice", args)
        send(test, {:ms_gap, self(), :slice_read})

        receive do
          :go -> result
        after
          20_000 -> result
        end

      _ ->
        _ = opts
        real(Nebu.Matrix.Room.DB, "member_state_slice", args)
    end
  end

  defmodule SliceDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name not in [:member_state_slice, :fetch_state_predecessors] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def member_state_slice(room, opts \\ []), do: Nebu.Matrix.MembershipStateTestSupport.Hooks.slice_hook(room, opts, [room, opts])

    # security cycle 2 (MINOR 2): the strict predecessor lookup of /members and /initialSync can be forced into a statement timeout; the lenient one (the /sync
    # paths) answers the silent empty map exactly like the real function on an error
    def fetch_state_predecessors(slots, opts \\ []) do
      case {Application.get_env(:nebu, :atdd_ms_pred), Keyword.get(opts, :strict, false)} do
        {%{fail: :timeout}, true} -> {:error, %Postgrex.Error{postgres: %{code: :query_canceled, pg_code: "57014", severity: "ERROR", message: "canceling statement due to statement timeout"}}}
        {%{fail: :timeout}, false} -> %{}
        _ -> Nebu.Matrix.MembershipStateTestSupport.Hooks.real(DB, "fetch_state_predecessors", if(opts == [], do: [slots], else: [slots, opts]))
      end
    end
  end

  defmodule DirectDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :direct_invitees do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def direct_invitees(room) do
      case Application.get_env(:nebu, :atdd_ms_direct) do
        %{room: ^room, fail: true} -> {:error, :atdd_injected}
        _ -> Nebu.Matrix.MembershipStateTestSupport.Hooks.real(DB, "direct_invitees", [room])
      end
    end
  end

  defmodule StatusDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :get_room_status do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def get_room_status(room) do
      case Application.get_env(:nebu, :atdd_ms_status) do
        %{room: ^room, fail: true} -> {:error, :atdd_injected}
        _ -> DB.get_room_status(room)
      end
    end
  end

  defmodule InviteRoomDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :apply_member_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def apply_member_change(room, user, signed, opts) do
      invite_write? = Keyword.get(opts, :require_pending_invitation, false)

      case Application.get_env(:nebu, :atdd_ms_invite) do
        # the FIRST invite write of the armed room process dies (whoever the invitee is): the order of the members is not the test's business
        %{kill_first: ref} when invite_write? ->
          if :counters.get(ref, 1) == 0 do
            :counters.add(ref, 1, 1)
            Process.exit(self(), :kill)
          else
            DB.apply_member_change(room, user, signed, opts)
          end

        %{user: ^user} = spec ->
          cond do
            not invite_write? -> DB.apply_member_change(room, user, signed, opts)
            # the room process dies in the write: the caller's GenServer.call exits (`:room_unavailable`)
            Map.get(spec, :mode) == :kill -> Process.exit(self(), :kill)
            true -> {:error, :atdd_injected}
          end
        _ -> DB.apply_member_change(room, user, signed, opts)
      end
    end
  end
end
