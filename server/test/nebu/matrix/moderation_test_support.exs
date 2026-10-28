defmodule Nebu.Matrix.ModerationTestSupport do
  @moduledoc """
  Shared helpers of the story `moderation-routes-atomic-ban` suites (`moderation_routes_http_test.exs`, `moderation_concurrency_test.exs`,
  `room/moderation_atomic_db_test.exs`). Loaded once by `test/test_helper.exs` (like `oauth_test_support.exs`); every function is `def`
  so that no suite carries an unused private helper (CI compiles with `--warnings-as-errors`).

  Everything here talks to the REAL stack: `Nebu.Web.Router` through `Plug.Test` (users and legacy sessions as in
  `sync_membership_partition_http_test.exs`, random localparts, `:server_name` pinned by the suites), the real `Nebu.Repo`, the real
  `Room.Server` under Horde. The helpers never print a token, a reason or a message body.

  Conventions (copied from the sibling suites):

    * `tick/0` separates writes of the SAME user whose order a SYNC token depends on, only in rooms the test owns. It waits until the clock is
      past the newest event of the last seconds (createRoom stamps its chain up to about 70 ms AHEAD of the clock).
    * Follow-up `fj`: a future-stamped event in the shared database breaks `tick/0` of other suites. A suite that writes one (the AC6 gate
      test) deletes the room's events in `on_exit`.
  """
  import ExUnit.Assertions

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @create "/_matrix/client/v3/createRoom"
  @table :nebu_http_rate_limit_buckets

  # ─── users, paths ────────────────────────────────────────────────────────────

  def user!(device_prefix \\ "MOD") do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3)), expires_at: session_expiry()).at}
  end

  # story power-levels-enforcement fix cycle 3 (the CI flake of the 50-round races, `join: 401 M_UNKNOWN_TOKEN` mid-test): a test
  # session expiring within the lookahead of `Nebu.Matrix.Session.RefreshWorker` (default 1 h = the default expiry of
  # `legacy_session!/3`) is one of its candidates; it has no upstream refresh token, so the worker's next tick answers "confirmed
  # upstream rejection" and hard-invalidates it while the test still uses it. These sessions expire beyond the lookahead (+ 1 h).
  def session_expiry do
    lookahead = Application.get_env(:nebu_http, :matrix_refresh_worker_lookahead_seconds, 3600)
    DateTime.add(DateTime.utc_now(), lookahead + 3600, :second)
  end

  # a user whose id has exactly `total` bytes (a session minted before the user ids were bounded, event-size-limit D2 (d))
  def long_user!(total) do
    lp = String.duplicate("l", total - 2 - byte_size(T.server_name()) - 4) <> T.rand(2)
    uid = "@" <> lp <> ":" <> T.server_name()
    true = byte_size(uid) == total
    {:ok, _} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "ATDD long id", T.rand(4) <> "@example.com")
    %{uid: uid, at: T.legacy_session!(uid, "MLU" <> String.upcase(T.rand(3)), expires_at: session_expiry()).at}
  end

  def uid_of(%{uid: uid}), do: uid
  def uid_of(uid) when is_binary(uid), do: uid

  def enc(room_id), do: URI.encode_www_form(room_id)
  def path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"
  def marker(label), do: "#{label}-#{T.rand(8)}"

  # ─── clock ───────────────────────────────────────────────────────────────────

  def tick do
    horizon = System.system_time(:millisecond) - 10_000
    newest = T.sql!("SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE origin_server_ts > $1", [horizon]).rows |> hd() |> hd()
    :ok = wait_until(fn -> System.system_time(:millisecond) > newest end, 300)
  end

  def wait_until(fun, attempts) when is_integer(attempts) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        :timeout

      true ->
        Process.sleep(1)
        wait_until(fun, attempts - 1)
    end
  end

  # ─── requests ────────────────────────────────────────────────────────────────

  def create(user, body, opts \\ []), do: T.matrix_request(:post, @create, user.at, [body: body] ++ opts)

  def make_room(user, body \\ %{}) do
    conn = create(user, body)
    assert conn.status == 200, "createRoom: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["room_id"]
  end

  def public_room(user), do: make_room(user, %{"preset" => "public_chat"})

  # a public room whose `users` levels are given (the owner is added at 100); `extra` are further top-level override keys
  def level_room(owner, users, extra \\ %{}) do
    override = Map.merge(%{"users" => Map.put(users, owner.uid, 100)}, extra)
    make_room(owner, %{"preset" => "public_chat", "power_level_content_override" => override})
  end

  # an invite-only room (private_chat) of `owner` whose `members` were invited at creation and joined
  def invite_room(owner, members, extra \\ %{}) do
    room = make_room(owner, Map.merge(%{"preset" => "private_chat", "invite" => Enum.map(members, & &1.uid)}, extra))
    for m <- members, do: join!(m, room)
    room
  end

  def join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  def leave(user, room), do: T.matrix_request(:post, path(room, "leave"), user.at)
  def forget(user, room), do: T.matrix_request(:post, path(room, "forget"), user.at)
  def invite(owner, room, target), do: T.matrix_request(:post, path(room, "invite"), owner.at, body: %{"user_id" => uid_of(target)})
  def put_state(user, room, type, body), do: T.matrix_request(:put, path(room, "state/#{type}"), user.at, body: body)

  def invite!(owner, room, target) do
    c = invite(owner, room, target)
    assert c.status == 200, "invite: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
  end

  def join!(user, room) do
    tick()
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
  end

  # a join without the clock wait (the many-round race suites; the server stamps the member events strictly after each other anyway)
  def join_now!(user, room) do
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
  end

  def leave!(user, room) do
    tick()
    c = leave(user, room)
    assert c.status == 200, "leave: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
  end

  def say!(user, room, body) do
    c = T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: %{"msgtype" => "m.text", "body" => body})
    assert c.status == 200, "send: #{c.status} #{String.slice(c.resp_body, 0, 200)}"
    T.json(c)["event_id"]
  end

  # POST /rooms/{roomId}/kick | ban | unban with a map body
  def act(action, user, room, body), do: T.matrix_request(:post, path(room, to_string(action)), user.at, body: body)

  def act_raw(action, user, room_path_segment, raw) do
    Plug.Test.conn(:post, "/_matrix/client/v3/rooms/#{room_path_segment}/#{action}", raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user.at)
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  # a request with a RAW body (not necessarily JSON) through the real router
  def raw_post(user, request_path, raw) do
    Plug.Test.conn(:post, request_path, raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user.at)
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  def kick(user, room, target, extra \\ %{}), do: act(:kick, user, room, Map.put(extra, "user_id", uid_of(target)))
  def ban(user, room, target, extra \\ %{}), do: act(:ban, user, room, Map.put(extra, "user_id", uid_of(target)))
  def unban(user, room, target, extra \\ %{}), do: act(:unban, user, room, Map.put(extra, "user_id", uid_of(target)))

  def ok!(conn, label) do
    assert conn.status == 200, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    assert T.json(conn) == %{}, "#{label}: the body is exactly {}"
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    conn
  end

  # ─── barrier race ────────────────────────────────────────────────────────────

  @doc "Runs the zero-arity `funs` in tasks that all wait for one `:go`, returns their results in order."
  def race(funs) do
    parent = self()

    tasks =
      for f <- funs do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> f.()
          end
        end)
      end

    for _ <- tasks do
      receive do
        {:ready, _pid} -> :ok
      after
        10_000 -> flunk("a racing task did not start")
      end
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 60_000))
  end

  # ─── the database, as the tests see it ───────────────────────────────────────

  def content_of(c) when is_map(c), do: c

  def content_of(c) when is_binary(c) do
    case Jason.decode!(c) do
      decoded when is_binary(decoded) -> content_of(decoded)
      decoded -> decoded
    end
  end

  # every m.room.member event of `uid` in the room, oldest first: %{sender, content, ts, event_id}
  def member_events(room_id, uid) do
    T.sql!(
      "SELECT sender, content, origin_server_ts, event_id FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 ORDER BY origin_server_ts, event_id",
      [room_id, uid]
    ).rows
    |> Enum.map(fn [sender, content, ts, id] -> %{sender: sender, content: content_of(content), ts: ts, event_id: id} end)
  end

  def memberships(room_id, uid), do: room_id |> member_events(uid) |> Enum.map(& &1.content["membership"])

  def event_count(room_id), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [room_id]).rows |> hd() |> hd()

  def latest(room_id, uid) do
    {:ok, latest} = DB.latest_member_event(room_id, uid)
    latest
  end

  def membership(room_id, uid) do
    case latest(room_id, uid) do
      nil -> nil
      %{membership: m} -> m
    end
  end

  def in_set?(room_id, uid), do: MapSet.member?(Nebu.Matrix.Room.Server.get_state(room_id).members, uid)

  def active_row?(room_id, uid),
    do: T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room_id, uid]).rows == [[1]]

  # :pending | :accepted | :rejected | :none for the row of (room, invitee)
  def invitation_state(room_id, uid) do
    case T.sql!("SELECT accepted_at, rejected_at FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room_id, uid]).rows do
      [] -> :none
      [[nil, nil]] -> :pending
      [[_accepted, nil]] -> :accepted
      [[nil, _rejected]] -> :rejected
    end
  end

  def rooms_row_count(room_id), do: T.sql!("SELECT count(*) FROM rooms WHERE room_id = $1", [room_id]).rows |> hd() |> hd()

  # the audit rows of the three moderation actions of a room: [%{actor, action, target_type, target_id, metadata, outcome}]
  def audit_rows(room_id) do
    T.sql!(
      "SELECT actor_user_id, action, target_type, target_id, metadata, outcome FROM audit_log WHERE target_id = $1 AND action LIKE 'room_member_%' ORDER BY id",
      [room_id]
    ).rows
    |> Enum.map(fn [actor, action, target_type, target_id, metadata, outcome] ->
      %{actor: actor, action: action, target_type: target_type, target_id: target_id, metadata: content_of(metadata), outcome: outcome}
    end)
  end

  @doc """
  Everything one moderation can change for one target in one room: the event count of the room, the target's member events, the
  active `room_members` row, the invitation row and the audit rows. A refused request must leave it untouched.
  """
  def footprint(room_id, uid) do
    {event_count(room_id), member_events(room_id, uid), active_row?(room_id, uid), invitation_state(room_id, uid), audit_rows(room_id),
     in_set?(room_id, uid)}
  end

  @doc "A member event written WITHOUT touching the member set / the invitation row (a legacy or half state): the event_id."
  def insert_member_event!(room, uid, membership, sender, ts, extra_content \\ %{}) do
    id = "$" <> T.rand(12)

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => uid_of(sender),
               "type" => "m.room.member",
               "state_key" => uid_of(uid),
               "content" => Map.put(extra_content, "membership", membership),
               "origin_server_ts" => ts
             })

    id
  end

  @doc "The clock, but never older than the newest event of the room (+ 1)."
  def ts_after(room) do
    newest = T.sql!("SELECT coalesce(max(origin_server_ts), 0) FROM events WHERE room_id = $1", [room]).rows |> hd() |> hd()
    max(System.system_time(:millisecond), newest) + 1
  end

  @doc "Kills the room process (Process.exit :kill) and restarts it through the supervisor: the member set is reloaded from the database."
  def kill_and_restart!(room) do
    {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("the room process did not die")
    end

    :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) != {:ok, pid} end, 3_000)
    {:ok, new_pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)
    assert new_pid != pid
    new_pid
  end

  @doc "A row-only invitation (as `upgrade_room` writes them): the pending row, no member event."
  def row_only_invitation!(room_id, inviter, invitee) do
    assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room_id, uid_of(inviter), uid_of(invitee))
  end

  # ─── error assertions ────────────────────────────────────────────────────────

  @doc "`status` and EXACTLY `{errcode, error}`; `text` (when given) is the exact fixed text. Returns the decoded body."
  def assert_err(conn, status, errcode, text \\ nil) do
    assert conn.status == status, "expected #{status} #{errcode}, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert Enum.sort(Map.keys(body)) == ["errcode", "error"], "the error body is exactly {errcode, error}: #{conn.resp_body}"
    assert body["errcode"] == errcode, "errcode: #{conn.resp_body}"
    if text, do: assert(body["error"] == text, "text: #{conn.resp_body}")
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    body
  end

  @doc "No client-controlled value (the target id, the reason, the room id) is echoed in the response body."
  def refute_echo(conn, values) do
    for v <- values, is_binary(v), v != "", do: refute(String.contains?(conn.resp_body, v), "the response echoes a client value")
    conn
  end

  # a 429: exact envelope, Retry-After an integer >= 1, retry_after_ms == Retry-After * 1000
  def assert_429(conn, label) do
    assert conn.status == 429, "#{label}: expected 429, got #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert Enum.sort(Map.keys(body)) == ["errcode", "error", "retry_after_ms"], "#{label}: #{conn.resp_body}"
    assert body["errcode"] == "M_LIMIT_EXCEEDED"
    ms = body["retry_after_ms"]
    assert is_integer(ms) and ms > 0, "#{label}: retry_after_ms #{inspect(ms)}"
    assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || ""), "#{label}: Retry-After must be an integer"
    assert secs >= 1
    assert ms == secs * 1000, "#{label}: body (#{ms}) and header (#{secs}) agree"
    conn
  end

  # ─── the limiter buckets (ETS rows {{tier, user_id}, tokens, last_ms}) ───────

  def now, do: Application.get_env(:nebu_http, :rate_limit_clock_fn).()

  def seed(tier, user, tokens) do
    Nebu.Web.Plugs.RateLimit.init_table()
    :ets.insert(@table, {{tier, user.uid}, tokens * 1.0, now()})
  end

  def tokens(tier, user, burst) do
    with true <- :ets.whereis(@table) != :undefined,
         [{_key, tokens, _last}] <- :ets.lookup(@table, {tier, user.uid}) do
      tokens
    else
      _ -> burst * 1.0
    end
  end

  # ─── the sync client (as member_prev_content_http_test.exs) ──────────────────

  def sync_conn(user, params) do
    query = params |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end) |> URI.encode_query()
    T.matrix_request(:get, "/_matrix/client/v3/sync" <> if(query == "", do: "", else: "?" <> query), user.at)
  end

  def sync(user, since \\ nil, params \\ []) do
    conn = sync_conn(user, [since: since, timeout: Keyword.get(params, :timeout, 0)] ++ Keyword.delete(params, :timeout))
    assert conn.status == 200, "sync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)
  end

  def section(body, name), do: get_in(body, ["rooms", name]) || %{}
  def in_section?(body, name, room), do: Map.has_key?(section(body, name), room)
  def next(body), do: body["next_batch"]
  def leave_timeline(body, room), do: get_in(body, ["rooms", "leave", room, "timeline", "events"]) || []
  def join_timeline(body, room), do: get_in(body, ["rooms", "join", room, "timeline", "events"]) || []
  def join_state(body, room), do: get_in(body, ["rooms", "join", room, "state", "events"]) || []

  def anchor_room!(user), do: make_room(user, %{})

  # the user's anchor room is the newest thing before the token is taken, so every later event of the scenario is NEW
  def snapshot!(user, anchor) do
    tick()
    say!(user, anchor, marker("anchor"))
    body = sync(user)
    tick()
    next(body)
  end

  def member_ev(events, uid, membership) do
    Enum.find(events, &(&1["type"] == "m.room.member" and &1["state_key"] == uid and get_in(&1, ["content", "membership"]) == membership))
  end

  def unsigned_of(ev), do: ev["unsigned"] || %{}

  # GET /rooms/{roomId}/messages?dir=b : the chunk
  def messages(user, room, limit \\ 100) do
    conn = T.matrix_request(:get, path(room, "messages") <> "?dir=b&limit=#{limit}", user.at)
    assert conn.status == 200, "messages: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["chunk"] || []
  end
end

defmodule Nebu.Matrix.ModerationTestSupport.Gap do
  @moduledoc """
  Deterministic interleavings (AC8 (c), AC9 (c), AC10 (b)): two db modules that delegate EVERYTHING to the real `Room.DB` / `InviteDB` and, for ONE
  armed call of the VICTIM process (the process that did `Process.put(:atdd_gap_victim, true)`), block right AFTER the real call returned until the
  test sends `:go`. The test uses the gap to commit a moderation, then releases the victim.

    * `RoomsDB` is installed as `:event_dispatcher, :rooms_db_module`; armed on `:delete_member` (the call between the decision and the write of the decline), `:get_member_membership` or
      `:latest_member_event` (the last read of the join decision).
    * `InviteDB` is installed as `:event_dispatcher, :invite_db_module`; armed on `:insert_invitation_capped` or `:insert_invitation` (the row
      write of the invite path, which comes after all outside checks and before the room call).

  The victim notifies the test with `{:gap, victim_pid, fun}`; an unarmed call, a call of another process or an exhausted counter is a plain delegation.
  """

  def arm(fun, room, user, test_pid, count \\ 1) do
    ref = :counters.new(1, [])
    :counters.put(ref, 1, count)
    Application.put_env(:nebu, :atdd_mod_gap, %{fun: fun, room: room, user: user, test: test_pid, ref: ref})
    :ok
  end

  def disarm, do: Application.delete_env(:nebu, :atdd_mod_gap)

  @doc "Installs both gap modules into the dispatcher seams (restored in the caller's on_exit)."
  def install! do
    for {key, mod} <- [rooms_db_module: __MODULE__.RoomsDB, invite_db_module: __MODULE__.InviteDB] do
      prior = Application.fetch_env(:event_dispatcher, key)
      Application.put_env(:event_dispatcher, key, mod)

      ExUnit.Callbacks.on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:event_dispatcher, key, value)
          :error -> Application.delete_env(:event_dispatcher, key)
        end
      end)
    end

    ExUnit.Callbacks.on_exit(&disarm/0)
    :ok
  end

  def maybe_block(fun, room, user) do
    with true <- Process.get(:atdd_gap_victim) == true,
         %{fun: ^fun, room: ^room, user: ^user, test: test, ref: ref} <- Application.get_env(:nebu, :atdd_mod_gap),
         n when n > 0 <- :counters.get(ref, 1) do
      :counters.sub(ref, 1, 1)
      send(test, {:gap, self(), fun})

      receive do
        :go -> :ok
      after
        20_000 -> :ok
      end
    else
      _ -> :ok
    end
  end

  defmodule RoomsDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name not in [:get_member_membership, :latest_member_event, :delete_member] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def get_member_membership(room, user) do
      result = apply(DB, :get_member_membership, [room, user])
      Nebu.Matrix.ModerationTestSupport.Gap.maybe_block(:get_member_membership, room, user)
      result
    end

    # the call of `leave_without_room_process/3` that sits between the decision (pending invitation / latest join) and the decline write
    def delete_member(room, user) do
      result = apply(DB, :delete_member, [room, user])
      Nebu.Matrix.ModerationTestSupport.Gap.maybe_block(:delete_member, room, user)
      result
    end

    def latest_member_event(room, user) do
      result = apply(DB, :latest_member_event, [room, user])
      Nebu.Matrix.ModerationTestSupport.Gap.maybe_block(:latest_member_event, room, user)
      result
    end
  end

  defmodule InviteDB do
    @moduledoc false
    alias Nebu.Matrix.Room.InviteDB, as: Real

    for {name, arity} <- Real.__info__(:functions), name not in [:insert_invitation_capped, :insert_invitation] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Real, unquote(name), unquote(args))
    end

    def insert_invitation_capped(room, inviter, invitee, caps) do
      result = apply(Real, :insert_invitation_capped, [room, inviter, invitee, caps])
      Nebu.Matrix.ModerationTestSupport.Gap.maybe_block(:insert_invitation_capped, room, invitee)
      result
    end

    def insert_invitation(room, inviter, invitee) do
      result = apply(Real, :insert_invitation, [room, inviter, invitee])
      Nebu.Matrix.ModerationTestSupport.Gap.maybe_block(:insert_invitation, room, invitee)
      result
    end
  end
end

# ─── story sync-stream-position: the shared fakes of the DB-free dispatcher unit suites ───────────────────────────────────────────────────────────
# (appended here, with the other shared `Nebu.Matrix.*` test support modules, because `mix.exs` lists every `*_support.exs` file in `test_ignore_filters`: a NEW support file would
# make the 1.20 test runner warn, and `mix.exs` is outside the ATDD step's remit. The dev may move it to its own file and add one line to `test_ignore_filters`.)

defmodule Nebu.Matrix.SyncPositionsFake do
  @moduledoc """
  Shared fakes of the story `sync-stream-position` for the unit suites that drive `get_initial_sync/2` / `get_sync_delta/2` WITHOUT a database (`event_dispatcher/sync_test.exs`,
  `event_dispatcher/sync_membership_partition_test.exs`, `event_dispatcher/server_dedup_test.exs`). Part of `moderation_test_support.exs`, loaded once by `test/test_helper.exs`; every function is `def` (CI compiles with
  `--warnings-as-errors`).

  DELIBERATE amendment of those suites (story D4, "the dispatcher test fakes get them"): the core now reads the committed head and the device's cursor of every candidate room
  with ONE call (`room_heads/3`), reads a moved room by the range `(base, head]` (`fetch_visible_events_in_range/5`), the leave window by positions (`leave_window_events/5`)
  and writes the token row and the cursor rows through ONE guarded persist (`persist_sync_position/3`). The fakes model them over THEIR OWN world, which the real SQL pins on the
  real database in `room/sync_positions_db_test.exs`:

    * **Positions.** An event map may carry `"room_pos"` (the fake that stamps events with a per-room insertion counter); an event without one gets its RANK by
      `(origin_server_ts, event_id)` within its room, which is the order the old timestamp reads used (the suites seed strictly increasing timestamps). `head` = the highest position.
    * **Cursors.** `cursor_fun.(room_id)` answers `nil` or `%{gen, pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker}`; `Store` keeps them in an ETS table like the real
      `sync_room_cursors`.
    * **`Store`** is the ETS twin of `PgStore.Postgres.persist_sync_position/3` / `get_since_token/2` (the guard on the base token, the generations and previous values, the rows to
      write, the rows of rooms that left the partition deleted): the SAME contract the dev's store must satisfy, over a map instead of two tables.

  The fakes pin nothing the story does not say: the names `room_heads/3`, `fetch_visible_events_in_range/5`, `leave_window_events/5` (positions + clocks) and `persist_sync_position/3` are
  the contract choices recorded in the ATDD report (the dev may rename them: only these fakes and `room/sync_positions_db_test.exs` change).
  """

  # ─── positions over a list of event maps ─────────────────────────────────────

  @doc "The events of ONE room with a `\"room_pos\"` each (kept when present, else the rank by `(origin_server_ts, event_id)`), ascending."
  def positioned(events) do
    {with_pos, without} = Enum.split_with(events, &Map.has_key?(&1, "room_pos"))

    ranked =
      without
      |> Enum.sort_by(&{&1["origin_server_ts"], &1["event_id"]})
      |> Enum.with_index(1)
      |> Enum.map(fn {ev, i} -> Map.put(ev, "room_pos", i) end)

    Enum.sort_by(with_pos ++ ranked, & &1["room_pos"])
  end

  def head(events), do: events |> positioned() |> Enum.map(& &1["room_pos"]) |> Enum.max(fn -> 0 end)

  @doc "`{:ok, %{room_id => %{head, cursor}}}` for every room of the list (a fake world has a row for each room)."
  def room_heads(events_fun, cursor_fun, room_ids) do
    {:ok, Map.new(room_ids, fn room -> {room, %{head: head(events_fun.(room)), cursor: cursor_fun.(room)}} end)}
  end

  @doc "The newest `limit + 1` events with `after_pos < room_pos <= head`, newest first (events with a `\"state_key\"` or `\"event_type\"` only: what the old fakes read)."
  def in_range(events, after_pos, head, limit) do
    events
    |> positioned()
    |> Enum.filter(&(&1["room_pos"] > after_pos and &1["room_pos"] <= head and Map.has_key?(&1, "event_type")))
    |> Enum.sort_by(& &1["room_pos"], :desc)
    |> Enum.take(limit + 1)
  end

  @doc "The window between two positions AND two clocks (all four strict), the newest 21, newest first."
  def leave_window(events, after_pos, before_pos, after_ts, before_ts) do
    events
    |> positioned()
    |> Enum.filter(&(&1["room_pos"] > after_pos and &1["room_pos"] < before_pos and &1["origin_server_ts"] > after_ts and &1["origin_server_ts"] < before_ts))
    |> Enum.sort_by(& &1["room_pos"], :desc)
    |> Enum.take(21)
  end

  @doc "`latest_member_events/2` entries (`%{event_id, origin_server_ts, sender, membership, content}`) with the `room_pos` of their event (for the two newest member events of a room)."
  def put_member_positions(by_room, events_fun) do
    Map.new(by_room, fn {room, entries} ->
      pos_by_id = events_fun.(room) |> positioned() |> Map.new(&{&1["event_id"], &1["room_pos"]})
      {room, Enum.map(entries, &Map.put(&1, :room_pos, Map.get(pos_by_id, &1.event_id)))}
    end)
  end

  # ─── the ETS twin of the guarded persist (D7, D8, D12) ───────────────────────

  defmodule Store do
    @moduledoc false

    # the token row of a (user, device) as the real `get_since_token/2` answers it
    def get_since_token(table, user, device) do
      case :ets.lookup(table, {:token, user, device}) do
        [{_, stored}] -> {:ok, Map.merge(%{stream_version: 1, generation: 1, prev_since_token: nil, last_event_id: nil}, stored)}
        [] -> {:error, :not_found}
      end
    end

    def cursor(table, user, device, room) do
      case :ets.lookup(table, {:cursor, user, device, room}) do
        [{_, row}] -> row
        [] -> nil
      end
    end

    def cursor_rows(table, user, device), do: :ets.match(table, {{:cursor, user, device, :"$1"}, :"$2"}) |> Map.new(fn [room, row] -> {room, row} end)

    @doc "Same contract as `PgStore.Postgres.persist_sync_position/3`: `:ok | :stale`."
    def persist(table, user, device, %{mode: :initial} = spec) do
      for room <- Map.keys(cursor_rows(table, user, device)), do: :ets.delete(table, {:cursor, user, device, room})

      :ets.insert(table, {{:token, user, device}, %{since_token: spec.new_token, last_event_id: spec.last_event_id, stream_version: 1, generation: 1, prev_since_token: nil}})
      write_rows(table, user, device, 1, spec.rows)
      :ok
    end

    def persist(table, user, device, %{mode: :delta} = spec) do
      case :ets.lookup(table, {:token, user, device}) do
        [{_, stored}] ->
          generation = Map.get(stored, :generation, 1)

          # DELIBERATE amendment by the dev step (code review cycle 0, MAJOR-1), old -> new: the guard also compares the generation the request was built
          # from (`expected_generation`, compare-and-set); a spec without the key is checked by the token only, as before
          expected = Map.get(spec, :expected_generation)
          base_ok? = spec.base_token == stored.since_token or (is_binary(Map.get(stored, :prev_since_token)) and spec.base_token == stored.prev_since_token)

          if base_ok? and (expected == nil or expected == generation) do
            next = generation + 1

            :ets.insert(
              table,
              {{:token, user, device},
               %{since_token: spec.new_token, last_event_id: spec.last_event_id, stream_version: 1, generation: next, prev_since_token: spec.base_token}}
            )

            for room <- Map.keys(cursor_rows(table, user, device)), room not in spec.keep, do: :ets.delete(table, {:cursor, user, device, room})
            write_rows(table, user, device, next, spec.rows)
            :ok
          else
            :stale
          end

        [] ->
          :stale
      end
    end

    defp write_rows(table, user, device, gen, rows) do
      for row <- rows do
        base = row.base

        :ets.insert(
          table,
          {{:cursor, user, device, row.room_id},
           %{
             gen: gen,
             pos: row.pos,
             class: row.class,
             invite_marker: row.invite_marker,
             prev_pos: base && base.pos,
             prev_class: base && base.class,
             prev_invite_marker: base && base.invite_marker
           }}
        )
      end

      :ok
    end
  end
end
