defmodule Nebu.Matrix.RedactionTestSupport do
  @moduledoc """
  Shared helpers of the story `state-writer-redaction` suites (`redaction_http_test.exs`, `state_writer_http_test.exs`,
  `state_writer_redaction_concurrency_test.exs`, `room/redaction_writer_db_test.exs`). Loaded once by `test/test_helper.exs` (after the moderation
  and power-level helpers they build on); every function is `def`, so no suite carries an unused private helper (CI compiles with
  `--warnings-as-errors`).

  Everything talks to the REAL stack: `Nebu.Web.Router` through `Plug.Test`, the real `Nebu.Repo`, the real `Room.Server` under Horde. The helpers
  never print a token, a reason or a message body. Functions of the story that do not exist yet (`Room.DB.apply_redaction/2`, `Room.Server.redact/5`,
  ...) are reached through `call/3` or a variable function name: the files compile without warnings before the dev step.
  """
  import ExUnit.Assertions
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport, only: [ok_event_id!: 2, put_raw: 3]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @redaction "m.room.redaction"

  # ─── words ───────────────────────────────────────────────────────────────────

  @doc "A unique single-token word (letters and digits only: one token of the `simple` text search configuration)."
  def word(label), do: label <> T.rand(8)

  # ─── requests ────────────────────────────────────────────────────────────────

  def redact_path(room, event_id, txn), do: path(room, "redact/#{enc(event_id)}/#{txn}")

  @doc "PUT .../redact/{eventId}/{txnId} with a map body (a fresh txn id unless given)."
  def redact(user, room, event_id, body \\ %{}, txn \\ nil),
    do: T.matrix_request(:put, redact_path(room, event_id, txn || T.rand(6)), user.at, body: body)

  @doc "PUT .../redact/{eventId}/{txnId} with a RAW body."
  def redact_raw(user, room, event_id, raw, txn \\ nil), do: put_raw(user, redact_path(room, event_id, txn || T.rand(6)), raw)

  @doc "Asserts a 200 `{\"event_id\": ..}` of a redaction and returns the id."
  def redact_id!(user, room, event_id, body \\ %{}, label \\ "redact"), do: ok_event_id!(redact(user, room, event_id, body), label)

  @doc "PUT .../send/m.room.redaction/{txnId} with a map content."
  def send_redaction(user, room, content, txn \\ nil),
    do: T.matrix_request(:put, path(room, "send/#{@redaction}/#{txn || T.rand(6)}"), user.at, body: content)

  @doc "A message with `m.relates_to` (a thread reply / edit / annotation) of `user`: the event id."
  def relate!(user, room, rel_type, parent, body, extra \\ %{}) do
    content =
      Map.merge(%{"msgtype" => "m.text", "body" => body, "m.relates_to" => %{"rel_type" => rel_type, "event_id" => parent}}, extra)

    conn = T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: content)
    assert conn.status == 200, "relate: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["event_id"]
  end

  def get_event(user, room, event_id), do: T.matrix_request(:get, path(room, "event/#{enc(event_id)}"), user.at)

  @doc "The JSON of GET .../event/{eventId} (status 200 asserted)."
  def event!(user, room, event_id) do
    conn = get_event(user, room, event_id)
    assert conn.status == 200, "event: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)
  end

  # `limit=100`: the route's default limit is 1 (a pre-existing quirk of `relations_limit/1`)
  def relations_path(room, event_id), do: "/_matrix/client/v1/rooms/#{enc(room)}/relations/#{enc(event_id)}?limit=100"

  @doc "GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}: the decoded `chunk` (status 200 asserted)."
  def relations(user, room, event_id) do
    conn = T.matrix_request(:get, relations_path(room, event_id), user.at)
    assert conn.status == 200, "relations: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["chunk"] || []
  end

  def relation_ids(user, room, event_id), do: user |> relations(room, event_id) |> Enum.map(& &1["event_id"])

  @doc "GET .../messages with `dir` (`\"b\"` or `\"f\"`): the conn."
  def messages_conn(user, room, dir), do: T.matrix_request(:get, path(room, "messages") <> "?dir=#{dir}&limit=100", user.at)

  def initial_sync_conn(user, room), do: T.matrix_request(:get, path(room, "initialSync"), user.at)

  @doc "POST /_matrix/client/v3/search for `term`: the decoded response."
  def search(user, term) do
    body = %{"search_categories" => %{"room_events" => %{"search_term" => term, "filter" => %{"limit" => 20}}}}
    conn = T.matrix_request(:post, "/_matrix/client/v3/search", user.at, body: body)
    assert conn.status == 200, "search: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    {T.json(conn), conn.resp_body}
  end

  def search_ids(user, term) do
    {json, _raw} = search(user, term)
    json |> get_in(["search_categories", "room_events", "results"]) |> List.wrap() |> Enum.map(& &1["result"]["event_id"])
  end

  # ─── the served event, by read path ──────────────────────────────────────────

  @doc """
  The event `event_id` as served to `user` by one of the read paths, with the RAW response body of that request:
  `{event_json | nil, raw_body}`. Paths: `:messages_b`, `:messages_f`, `:event`, `:sync_initial` (the join timeline of a full `/sync`),
  `:initial_sync` (`GET .../initialSync`). The incremental `/sync` and the leave window are tested where they are needed.
  """
  def served(user, room, event_id, how)

  def served(user, room, event_id, how) when how in [:messages_b, :messages_f] do
    conn = messages_conn(user, room, if(how == :messages_b, do: "b", else: "f"))
    assert conn.status == 200, "#{how}: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    {Enum.find(T.json(conn)["chunk"] || [], &(&1["event_id"] == event_id)), conn.resp_body}
  end

  def served(user, room, event_id, :event) do
    conn = get_event(user, room, event_id)
    assert conn.status == 200, "event: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    {T.json(conn), conn.resp_body}
  end

  def served(user, room, event_id, :sync_initial) do
    conn = sync_conn(user, since: nil, timeout: 0)
    assert conn.status == 200, "sync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    {conn |> T.json() |> join_timeline(room) |> Enum.find(&(&1["event_id"] == event_id)), conn.resp_body}
  end

  def served(user, room, event_id, :initial_sync) do
    conn = initial_sync_conn(user, room)
    assert conn.status == 200, "initialSync: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    {Enum.find(get_in(T.json(conn), ["messages", "chunk"]) || [], &(&1["event_id"] == event_id)), conn.resp_body}
  end

  def served_paths, do: [:messages_b, :messages_f, :event, :sync_initial, :initial_sync]

  # ─── the database, as the tests see it ───────────────────────────────────────

  @doc "The stored row of an event incl. the `redacts` column: `%{room_id, sender, type, content, ts, signatures, state_key, redacts}` or nil."
  def row(event_id) do
    case T.sql!("SELECT room_id, sender, event_type, content, origin_server_ts, signatures, state_key, redacts FROM events WHERE event_id = $1", [event_id]).rows do
      [[room_id, sender, type, content, ts, signatures, state_key, redacts]] ->
        %{room_id: room_id, sender: sender, type: type, content: content_of(content), ts: ts, signatures: content_of(signatures), state_key: state_key, redacts: redacts}

      [] ->
        nil
    end
  end

  @doc "The whole stored row without the `redacts` column as text values (a byte comparison before / after)."
  def raw_row(event_id) do
    T.sql!(
      "SELECT event_id, room_id, sender, event_type, content::text, origin_server_ts, signatures::text, state_key FROM events WHERE event_id = $1",
      [event_id]
    ).rows
  end

  @doc "The ids of every `m.room.redaction` event of a room, oldest first (no `redacts` column: usable before the migration)."
  def redaction_ids(room) do
    T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id", [room, @redaction]).rows |> Enum.map(&hd/1)
  end

  @doc "The ids of every redaction row whose `redacts` column is `target`, oldest first."
  def redaction_ids_of(target), do: T.sql!("SELECT event_id FROM events WHERE redacts = $1 ORDER BY origin_server_ts, event_id", [target]).rows |> Enum.map(&hd/1)

  @doc "Every `m.room.redaction` row of a room with its column, oldest first."
  def redaction_rows(room) do
    T.sql!("SELECT event_id FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id", [room, @redaction]).rows
    |> Enum.map(fn [id] -> Map.put(row(id), :event_id, id) end)
  end

  @doc "The `room_event_redacted` audit rows of a room."
  def redact_audit(room) do
    T.sql!(
      "SELECT actor_user_id, action, target_type, target_id, metadata, outcome FROM audit_log WHERE target_id = $1 AND action = 'room_event_redacted' ORDER BY id",
      [room]
    ).rows
    |> Enum.map(fn [actor, action, target_type, target_id, metadata, outcome] ->
      %{actor: actor, action: action, target_type: target_type, target_id: target_id, metadata: content_of(metadata), outcome: outcome}
    end)
  end

  @doc "Everything one redaction can touch: the event count, the redaction ids, the audit rows. A refused request must leave it untouched."
  def rd_footprint(room), do: {event_count(room), redaction_ids(room), redact_audit(room)}

  @doc "Runs `fun`, asserts the footprint is identical before and after (nothing written), returns the result of `fun`."
  def rd_unchanged(room, fun) do
    before = rd_footprint(room)
    result = fun.()
    assert rd_footprint(room) == before, "a refused request must write NOTHING (no event, no redaction row, no audit row)"
    result
  end

  @doc "The txn-dedup entries of `NebuTxnDedup` for a key."
  def dedup_entry(key), do: :ets.lookup(:NebuTxnDedup, key)

  @doc "The ETS idempotency key of a `PUT /send/{type}/{txn}` (Kassandra #5: the event type is part of the key, a txn id is scoped to its HTTP path)."
  def send_key(room, user, type, txn), do: {room, uid_of(user), {:send, type, txn}}

  @doc "The ETS idempotency key of a `PUT /redact` (D7)."
  def redact_key(room, user, event_id, txn), do: {room, uid_of(user), {:redact, event_id, txn}}

  @doc "Every state event of `(type, state_key)` in the room, oldest first: `%{event_id, sender, ts, content}`."
  def slot_events(room, type, state_key \\ "") do
    T.sql!(
      "SELECT event_id, sender, origin_server_ts, content FROM events WHERE room_id = $1 AND event_type = $2 AND state_key = $3 ORDER BY origin_server_ts, event_id",
      [room, type, state_key]
    ).rows
    |> Enum.map(fn [id, sender, ts, content] -> %{event_id: id, sender: sender, ts: ts, content: content_of(content)} end)
  end

  @doc "The transaction id of an event row (every event of the room process is its own transaction: xid order = commit order)."
  def xmin_of(event_id), do: T.sql!("SELECT xmin::text::bigint FROM events WHERE event_id = $1", [event_id]).rows |> hd() |> hd()

  def rooms_name(room), do: T.sql!("SELECT name FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # ─── signature ───────────────────────────────────────────────────────────────

  @doc """
  True when the stored redaction row carries a valid Ed25519 signature of the server key over the canonical JSON of the PDU Nebu signs for
  a message event: the keys `room_id`, `type`, `state_key` (JSON null), `sender`, `content`, `redacts` (top level, v10), `origin_server_ts`;
  and its event id is the content hash of that map.
  """
  def valid_redaction_signature?(event_id) do
    r = row(event_id)

    map = %{
      "room_id" => r.room_id,
      "type" => r.type,
      "state_key" => r.state_key,
      "sender" => r.sender,
      "content" => r.content,
      "redacts" => r.redacts,
      "origin_server_ts" => r.ts
    }

    {pub, _priv} = :persistent_term.get(:nebu_signing_key)
    signature = Base.decode64!(r.signatures["nebu"])
    :crypto.verify(:eddsa, :none, Nebu.Matrix.CanonicalJson.encode!(map), signature, [pub, :ed25519]) and Nebu.Matrix.EventId.generate(map) == event_id
  end

  # ─── rooms and processes ─────────────────────────────────────────────────────

  @doc "Stops the room process (the room stays in the database); waits until the registry no longer knows it."
  def stop_room!(room) do
    {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
    :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
    :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 3_000)
  end

  def running?(room), do: match?({:ok, _pid}, Nebu.Matrix.Room.RoomSupervisor.lookup_room(room))

  @doc "The ids of every running room process (the Horde registry)."
  def running_rooms, do: Horde.Registry.select(Nebu.Matrix.Room.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()

  def room_count, do: T.sql!("SELECT count(*) FROM rooms", []).rows |> hd() |> hd()

  def room_status(room), do: T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows |> hd() |> hd()

  # ─── future-dated events (follow-up fj) ──────────────────────────────────────

  @doc "Registers the `on_exit` that deletes every event of `room` and asserts the DELETE succeeded (a future-stamped event breaks `tick/0` of other suites)."
  def cleanup_events_on_exit(room) do
    ExUnit.Callbacks.on_exit(fn -> assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room]) end)
  end

  @doc "A signed-looking state event row as the room process would build it (the transaction only inserts it)."
  def state_event(room, sender, type, state_key, content, ts) do
    %{
      "event_id" => "$" <> T.rand(16),
      "room_id" => room,
      "sender" => uid_of(sender),
      "type" => type,
      "state_key" => state_key,
      "content" => content,
      "origin_server_ts" => ts,
      "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(64))}
    }
  end

  @doc "A signed-looking redaction event (the shape `Room.Server.redact/5` writes: top-level `redacts`, message event)."
  def redaction_event(room, sender, target, content, ts) do
    %{
      "event_id" => "$" <> T.rand(16),
      "room_id" => room,
      "sender" => uid_of(sender),
      "type" => @redaction,
      "state_key" => nil,
      "content" => content,
      "redacts" => target,
      "origin_server_ts" => ts,
      "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(64))}
    }
  end

  @doc "A LEGACY redaction row (written before the story: through `/send`, `redacts` column NULL, `content.redacts` set), inserted directly."
  def insert_legacy_redaction!(room, sender, target, content_extra, ts) do
    event = redaction_event(room, sender, target, Map.put(content_extra, "redacts", target), ts) |> Map.delete("redacts")
    assert :ok = DB.insert_event(event)
    event["event_id"]
  end

  @doc "An INSERT trigger on `events` that raises for ONE room (dropped in `on_exit`): every event insert of the room fails. Returns the remover."
  def block_events!(room) do
    name = "atdd_rd_block_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.room_id = '#{room}' THEN RAISE EXCEPTION 'atdd: insert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON events")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc """
  Installs the counting / failing `redactions_for/1` hook (`Hooks.MessagesDB`) on BOTH db seams of the dispatcher (`:messages_db_module`, which the
  predecessor batch of the read paths uses, and `:rooms_db_module`), restored in the caller's `on_exit`.
  """
  def install_lookup_hook! do
    for key <- [:messages_db_module, :rooms_db_module],
        do: Nebu.Matrix.PowerLevelsTestSupport.install_env!(:event_dispatcher, key, Nebu.Matrix.RedactionTestSupport.Hooks.MessagesDB)

    :ok
  end

  @doc "Waits (bounded) for the gap message `{:rd_gap, victim_pid, label}` of a hook."
  def await_rd_gap!(label) do
    receive do
      {:rd_gap, victim, ^label} -> victim
    after
      10_000 -> flunk("nobody reached the gap #{inspect(label)}")
    end
  end
end

defmodule Nebu.Matrix.RedactionTestSupport.Hooks do
  @moduledoc """
  Armed hooks of the story `state-writer-redaction` tests, node-local:

    * `RoomDB` is installed as `:room_manager, :db_module`: it delegates EVERYTHING to the real `Room.DB` and has a hook on the two atomic
      writers `apply_redaction/2` and `apply_state_change/3` (armed with `arm_db/1`): `%{kill: room}` (the room process kills itself right before
      the transaction), `%{block: room, test: pid}` (blocks the room process in the call until `:go`, then runs the real transaction; the test is
      told `{:rd_gap, pid, :in_write}`).
    * `ExitingWriter` is installed as `:event_dispatcher, :room_registry_module`: everything is delegated, `write_state/5` exits (a room that does not answer).
    * `MessagesDB` is installed as `:event_dispatcher, :messages_db_module`: it delegates everything and COUNTS the calls of `redactions_for/1`
      (`reset_count/0`, `count/0`); with `fail_lookup/0` armed it answers `{:error, :atdd_injected}`.
  """

  def arm_db(spec), do: Application.put_env(:nebu, :atdd_rd_db, spec)
  def disarm_db, do: Application.delete_env(:nebu, :atdd_rd_db)

  def reset_count, do: Application.put_env(:nebu, :atdd_rd_count, :counters.new(1, []))
  def count, do: :counters.get(Application.fetch_env!(:nebu, :atdd_rd_count), 1)
  def fail_lookup, do: Application.put_env(:nebu, :atdd_rd_fail, true)
  def heal_lookup, do: Application.delete_env(:nebu, :atdd_rd_fail)

  def cleanup do
    Application.delete_env(:nebu, :atdd_rd_db)
    Application.delete_env(:nebu, :atdd_rd_count)
    Application.delete_env(:nebu, :atdd_rd_fail)
  end

  # the real function of the real db module (a variable name: the file compiles before the function exists)
  def real(fun, args), do: apply(Nebu.Matrix.Room.DB, String.to_atom(fun), args)

  def guarded(room, fun, args) do
    case Application.get_env(:nebu, :atdd_rd_db) do
      %{kill: ^room} ->
        Process.exit(self(), :kill)
        :ok

      %{block: ^room, test: test} ->
        send(test, {:rd_gap, self(), :in_write})

        receive do
          :go -> real(fun, args)
        after
          20_000 -> real(fun, args)
        end

      _ ->
        real(fun, args)
    end
  end

  defmodule RoomDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name not in [:apply_redaction, :apply_state_change] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def apply_redaction(room, signed), do: Nebu.Matrix.RedactionTestSupport.Hooks.guarded(room, "apply_redaction", [room, signed])
    def apply_state_change(room, signed, opts), do: Nebu.Matrix.RedactionTestSupport.Hooks.guarded(room, "apply_state_change", [room, signed, opts])
  end

  # the registry seam (`:event_dispatcher, :room_registry_module`) whose `write_state/5` does not answer: the call exits like a timed-out GenServer.call (Kassandra #3)
  defmodule ExitingWriter do
    @moduledoc false
    alias Nebu.Matrix.Room.Server

    for {name, arity} <- Server.__info__(:functions), name not in [:write_state, :child_spec] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Server, unquote(name), unquote(args))
    end

    def write_state(_room, _sender, _slot, _content, _opts), do: exit({:timeout, {GenServer, :call, [:the_room, :write_state, 5000]}})
  end

  defmodule MessagesDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :redactions_for do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def redactions_for(ids) do
      case Application.get_env(:nebu, :atdd_rd_count) do
        nil -> :ok
        ref -> :counters.add(ref, 1, 1)
      end

      if Application.get_env(:nebu, :atdd_rd_fail), do: {:error, :atdd_injected}, else: Nebu.Matrix.RedactionTestSupport.Hooks.real("redactions_for", [ids])
    end
  end
end
