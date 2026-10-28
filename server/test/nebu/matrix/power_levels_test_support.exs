defmodule Nebu.Matrix.PowerLevelsTestSupport do
  @moduledoc """
  Shared helpers of the story `power-levels-enforcement` suites (`power_levels_http_test.exs`, `power_levels_concurrency_test.exs`,
  `room/power_levels_writer_db_test.exs`). Loaded once by `test/test_helper.exs` (like `moderation_test_support.exs`, whose users, rooms,
  clock, race and footprint helpers they build on); every function is `def`, so no suite carries an unused private helper (CI compiles
  with `--warnings-as-errors`).

  Everything talks to the REAL stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, the real `Room.Server` under Horde. The
  helpers never print a token or the content of a levels event.

  Functions that do not exist yet (`Room.DB.apply_power_levels_change/3`, `Room.Server.change_power_levels/4`) are reached through
  `call/3` with a variable function name: the files compile without warnings before the dev step.
  """
  import ExUnit.Assertions
  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.Room.Server
  alias Nebu.OAuth.TestSupport, as: T

  @pl "m.room.power_levels"

  # a function that may not exist yet: never a compile warning
  def call(mod, fun, args), do: apply(mod, fun, args)

  # ─── content builders ────────────────────────────────────────────────────────

  @doc "A COMPLETE, strictly valid levels content with the spec defaults, `users` as given and `events` = only the levels event at 50; `extra` replaces top-level keys."
  def levels(users, extra \\ %{}) do
    Map.merge(
      %{
        "ban" => 50,
        "kick" => 50,
        "invite" => 0,
        "redact" => 50,
        "state_default" => 50,
        "events_default" => 0,
        "users_default" => 0,
        "users" => users,
        "events" => %{@pl => 50}
      },
      extra
    )
  end

  # ─── requests ────────────────────────────────────────────────────────────────

  def pl_path(room), do: path(room, "state/#{@pl}")
  def pl_path_slash(room), do: path(room, "state/#{@pl}/")

  @doc "PUT .../state/m.room.power_levels with a map body (no trailing slash)."
  def put_pl(user, room, content), do: T.matrix_request(:put, pl_path(room), user.at, body: content)

  @doc "PUT .../state/m.room.power_levels/ (the empty state key written out: what Element's `setPowerLevel` sends)."
  def put_pl_slash(user, room, content), do: T.matrix_request(:put, pl_path_slash(room), user.at, body: content)

  @doc "PUT .../state/m.room.power_levels/<state key> (the key is percent-encoded)."
  def put_pl_key(user, room, state_key, content), do: T.matrix_request(:put, path(room, "state/#{@pl}/#{enc(state_key)}"), user.at, body: content)

  @doc "A PUT with a RAW (not necessarily JSON) body through the real router."
  def put_raw(user, request_path, raw) do
    Plug.Test.conn(:put, request_path, raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user.at)
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  @doc "PUT .../state/<type>/<state key> with a map body."
  def put_state_key(user, room, type, state_key, content),
    do: T.matrix_request(:put, path(room, "state/#{type}/#{enc(state_key)}"), user.at, body: content)

  @doc "PUT .../send/<type>/<txn> with a map body."
  def send_event(user, room, type, content), do: T.matrix_request(:put, path(room, "send/#{type}/#{T.rand(6)}"), user.at, body: content)

  def text_message(user, room), do: send_event(user, room, "m.room.message", %{"msgtype" => "m.text", "body" => marker("pl")})

  @doc "Asserts a 200 `{\"event_id\": ..}` and returns the event id."
  def ok_event_id!(conn, label \\ "PUT") do
    assert conn.status == 200, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    body = T.json(conn)
    assert Map.keys(body) == ["event_id"], "#{label}: the body is exactly {event_id}: #{conn.resp_body}"
    assert is_binary(body["event_id"]) and String.starts_with?(body["event_id"], "$")
    body["event_id"]
  end

  # ─── rooms ───────────────────────────────────────────────────────────────────

  @doc "Seeds the levels of a room through `Room.Server.set_power_levels/3` (the `:internal` writer), by `caller` (must reach the required level)."
  def seed!(room, caller, content), do: assert(:ok = Server.set_power_levels(room, uid_of(caller), content))

  @doc """
  A public room owned by `owner` whose `members` joined, with the levels `content` seeded (build it with `levels/2`). The owner is added to
  `users` at 100 when the content does not list him.
  """
  def room_with_levels(owner, members, content) do
    room = public_room(owner)
    for m <- members, do: join_now!(m, room)
    seeded = update_in(content, ["users"], &Map.put_new(&1, owner.uid, 100))
    seed!(room, owner, seeded)
    room
  end

  # ─── the database, as the tests see it ───────────────────────────────────────

  @doc "The stored `rooms.power_levels_json` of the room, decoded."
  def column(room) do
    [[json]] = T.sql!("SELECT power_levels_json FROM rooms WHERE room_id = $1", [room]).rows
    Jason.decode!(json)
  end

  def column_text(room), do: T.sql!("SELECT power_levels_json FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  def set_column!(room, json), do: T.sql!("UPDATE rooms SET power_levels_json = $2 WHERE room_id = $1", [room, json])

  @doc "Every `m.room.power_levels` event of the room, oldest first: `%{event_id, sender, ts, content, state_key}`."
  def pl_events(room) do
    T.sql!(
      "SELECT event_id, sender, origin_server_ts, content, state_key FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id",
      [room, @pl]
    ).rows
    |> Enum.map(fn [id, sender, ts, content, key] -> %{event_id: id, sender: sender, ts: ts, content: content_of(content), state_key: key} end)
  end

  def latest_pl(room), do: room |> pl_events() |> List.last()

  @doc "The identity statement of the room process (`@sql_power_levels_identity`): `{event_id, origin_server_ts, sender}`."
  def identity_row(room) do
    [[id, ts, sender]] =
      T.sql!(
        "SELECT event_id, origin_server_ts, sender FROM events WHERE room_id = $1 AND event_type = 'm.room.power_levels' AND state_key = '' ORDER BY origin_server_ts DESC LIMIT 1",
        [room]
      ).rows

    {id, ts, sender}
  end

  @doc "The in-memory levels of the room process (the raw stored content)."
  def memory(room), do: Server.get_state(room).power_levels

  def memory_identity(room), do: Server.get_state(room).power_levels_event

  @doc "The audit rows `room_power_levels_changed` of a room: `[%{actor, action, target_type, target_id, metadata, outcome}]`."
  def pl_audit(room) do
    T.sql!(
      "SELECT actor_user_id, action, target_type, target_id, metadata, outcome FROM audit_log WHERE target_id = $1 AND action = 'room_power_levels_changed' ORDER BY id",
      [room]
    ).rows
    |> Enum.map(fn [actor, action, target_type, target_id, metadata, outcome] ->
      %{actor: actor, action: action, target_type: target_type, target_id: target_id, metadata: content_of(metadata), outcome: outcome}
    end)
  end

  @doc "The audit rows `room_upgraded` of an (old) room."
  def upgrade_audit(room) do
    T.sql!("SELECT actor_user_id, metadata, outcome FROM audit_log WHERE target_id = $1 AND action = 'room_upgraded' ORDER BY id", [room]).rows
    |> Enum.map(fn [actor, metadata, outcome] -> %{actor: actor, metadata: content_of(metadata), outcome: outcome} end)
  end

  @doc """
  Everything one power-level change can touch: the event count of the room, its levels events, the stored column, the in-memory levels and
  identity, the member set and the audit rows. A refused request must leave it untouched.
  """
  def pl_footprint(room) do
    state = Server.get_state(room)

    {event_count(room), Enum.map(pl_events(room), & &1.event_id), column_text(room), state.power_levels, state.power_levels_event, state.members,
     pl_audit(room)}
  end

  @doc "Runs `fun` and asserts that NOTHING changed (the footprint is identical before and after); returns the result of `fun`."
  def unchanged(room, fun) do
    before = pl_footprint(room)
    result = fun.()
    assert pl_footprint(room) == before, "a refused request must write NOTHING (no event, column, in-memory levels, member, audit row)"
    result
  end

  @doc "The four sources of the levels of a room, for the agreement checks: `{column, latest event content, in-memory levels}`."
  def sources(room), do: {column(room), latest_pl(room).content, memory(room)}

  def assert_agree(room) do
    {col, event_content, mem} = sources(room)
    assert col == event_content, "the column and the latest levels event agree"
    assert col == mem, "the column and the in-memory levels agree"
    {id, ts, sender} = identity_row(room)
    assert memory_identity(room) == {id, ts, sender}, "the in-memory identity is the latest levels event"
    col
  end

  # ─── /sync ───────────────────────────────────────────────────────────────────

  @doc "The m.room.power_levels state event of a room in a FULL /sync of `user` (state block first, then the timeline), or nil."
  def sync_pl(user, room) do
    body = sync(user)
    events = join_state(body, room) ++ join_timeline(body, room)
    events |> Enum.filter(&(&1["type"] == @pl and &1["state_key"] == "")) |> List.last()
  end

  # ─── error assertions ────────────────────────────────────────────────────────

  @doc "`status` and EXACTLY `{errcode, error}` with the given fixed text; no client value in the body. Returns the decoded body."
  def assert_refused(conn, status, errcode, text, echoed \\ []) do
    body = assert_err(conn, status, errcode, text)
    refute_echo(conn, echoed)
    body
  end

  # ─── db modules for the gap / hook tests ─────────────────────────────────────

  @doc "Installs `mod` as the room process' db module for the test (restored in the caller's on_exit)."
  def install_room_db!(mod) do
    prior = Application.fetch_env(:room_manager, :db_module)
    Application.put_env(:room_manager, :db_module, mod)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:room_manager, :db_module, value)
        :error -> Application.delete_env(:room_manager, :db_module)
      end
    end)

    :ok
  end

  @doc "Installs `mod` under `{app, key}` for the test (restored in the caller's on_exit)."
  def install_env!(app, key, mod) do
    prior = Application.fetch_env(app, key)
    Application.put_env(app, key, mod)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)

    :ok
  end

  @doc "Waits (bounded) for the gap message of the victim."
  def await_gap!(label) do
    receive do
      {:pl_gap, victim, ^label} -> victim
    after
      10_000 -> flunk("the victim did not reach the gap #{inspect(label)}")
    end
  end
end

defmodule Nebu.Matrix.PowerLevelsTestSupport.Hooks do
  @moduledoc """
  Armed hooks of the story `power-levels-enforcement` tests, all node-local and keyed by room:

    * `RegistryGap` is installed as `:event_dispatcher, :room_registry_module`: for the ARMED victim process (the process that did
      `Process.put(:atdd_pl_gap_victim, true)`) the `get_state/1` of the armed room blocks right AFTER the real call returned (the
      dispatcher's membership snapshot of `send_event/2`) until the test sends `:go`.
    * `RoomDB` is installed as `:room_manager, :db_module`: it delegates EVERYTHING to the real `Room.DB` and has a hook on
      `apply_power_levels_change/3`: `:kill` (the room process kills itself right before the transaction), `{:fail_after, n}` (the n-th call
      of every room but the armed old room fails: the copy of an upgrade), `{:block, test_pid}` (blocks the room process in the call until
      `:go`, then runs the real transaction).
    * `AdminDB` is installed as `:event_dispatcher, :admin_db_module`: `archive_room_atomic/1` of the armed room first runs the armed
      function (a change committed between the snapshot and the freeze of an upgrade).
  """

  # ─── the registry gap ────────────────────────────────────────────────────────

  def arm_gap(room, user, test_pid) do
    Application.put_env(:nebu, :atdd_pl_gap, %{room: room, user: user, test: test_pid, ref: :counters.new(1, [])})
    :ok
  end

  def disarm_gap, do: Application.delete_env(:nebu, :atdd_pl_gap)

  def maybe_block(room) do
    with true <- Process.get(:atdd_pl_gap_victim) == true,
         %{room: ^room, test: test, ref: ref} <- Application.get_env(:nebu, :atdd_pl_gap),
         0 <- :counters.get(ref, 1) do
      :counters.add(ref, 1, 1)
      send(test, {:pl_gap, self(), :snapshot})

      receive do
        :go -> :ok
      after
        20_000 -> :ok
      end
    else
      _ -> :ok
    end
  end

  defmodule RegistryGap do
    @moduledoc false
    alias Nebu.Matrix.Room.Server

    for {name, arity} <- Server.__info__(:functions), name not in [:get_state, :child_spec] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Server, unquote(name), unquote(args))
    end

    def get_state(room) do
      state = Server.get_state(room)
      Nebu.Matrix.PowerLevelsTestSupport.Hooks.maybe_block(room)
      state
    end
  end

  # ─── the db hook ─────────────────────────────────────────────────────────────

  def arm_db(spec), do: Application.put_env(:nebu, :atdd_pl_db, spec)
  def disarm_db, do: Application.delete_env(:nebu, :atdd_pl_db)

  def next_call(ref) do
    :counters.add(ref, 1, 1)
    :counters.get(ref, 1)
  end

  defmodule RoomDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :apply_power_levels_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    # the real function (a variable name: the file compiles before the function exists)
    defp real(room, json, event), do: apply(DB, String.to_atom("apply_power_levels_change"), [room, json, event])

    def apply_power_levels_change(room, json, event) do
      case Application.get_env(:nebu, :atdd_pl_db) do
        %{kill: ^room} ->
          # the room process itself dies right before the transaction (nothing is committed)
          Process.exit(self(), :kill)
          :ok

        %{block: ^room, test: test} ->
          send(test, {:pl_gap, self(), :in_write})

          receive do
            :go -> real(room, json, event)
          after
            20_000 -> real(room, json, event)
          end

        %{fail_after: n, except: old, ref: ref} when room != old ->
          if Nebu.Matrix.PowerLevelsTestSupport.Hooks.next_call(ref) > n, do: {:error, :atdd_injected}, else: real(room, json, event)

        _ ->
          real(room, json, event)
      end
    end
  end

  defmodule AdminDB do
    @moduledoc false

    # `Nebu.Admin.DB` has many functions: delegate each but the armed one
    for {name, arity} <- Nebu.Admin.DB.__info__(:functions), name != :archive_room_atomic do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Nebu.Admin.DB, unquote(name), unquote(args))
    end

    def archive_room_atomic(room) do
      case Application.get_env(:nebu, :atdd_pl_before_archive) do
        %{room: ^room, fun: fun} -> fun.()
        _ -> :ok
      end

      Nebu.Admin.DB.archive_room_atomic(room)
    end
  end

  def arm_before_archive(room, fun), do: Application.put_env(:nebu, :atdd_pl_before_archive, %{room: room, fun: fun})
  def disarm_before_archive, do: Application.delete_env(:nebu, :atdd_pl_before_archive)
end

defmodule Nebu.Matrix.PowerLevelsTestSupport.FailingAudit do
  @moduledoc "An audit writer whose `log/6` fails (a raise): the change it audits must still be answered 200."
  def log(_actor, _action, _target_type, _target_id, _metadata, _outcome), do: raise("atdd: audit writer down")
end
