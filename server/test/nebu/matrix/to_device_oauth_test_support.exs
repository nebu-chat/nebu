defmodule Nebu.Matrix.ToDeviceTestSupport do
  @moduledoc """
  Shared helpers of the suites of story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): Matrix CS v1.18 "Send-to-Device messaging"
  (`PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}` and `to_device.events` of `GET /sync`), a per-device queue of OPAQUE event contents.

  Loaded once from `test_helper.exs` (like the other support modules); every function is `def`. The FILE NAME ends with `oauth_test_support.exs` on purpose:
  `mix.exs` already ignores that suffix (`test_ignore_filters`), so no mix.exs edit is needed.

  ## The contract the suites pin (decisions of the ATDD step; the oracle context of the story is the spec side)

    * Tables (names are pinned: the erasure inventory, the device teardown and the migration test name them): `to_device_messages` (queue, `user_id` = the recipient,
      `device_id`, `sender`, `created_at`) and `to_device_txns` (idempotency records, `user_id` = the SENDER, `device_id` = the sending device, `event_type`, `txn_id`,
      `created_at`). A device is KNOWN when it has a `devices` row.
    * Limits (all seams `Application.get_env(:nebu, :to_device_<name>)`, read at request time, defaults from `Nebu.Matrix.ToDeviceStore.limits/0`): see `defaults/0`.
    * Errors: `400 M_NOT_JSON`, `400 M_BAD_JSON` (`messages` missing / not an object, an entry that is not an object), `400 M_INVALID_PARAM` (event type, txn id),
      `413 M_TOO_LARGE` (body above 64 KiB, more than 50 recipient entries), `429 M_LIMIT_EXCEEDED` (the sender's rate limit or a transaction that is in flight),
      `500 M_UNKNOWN` (generic text). Everything about WHO can be reached is a silent `200 {}`.
  """
  import ExUnit.Assertions
  import Plug.Conn
  import Plug.Test

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @router_opts Nebu.Web.Router.init([])
  @prefix "/_matrix/client/v3/sendToDevice"
  @messages "to_device_messages"
  @txns "to_device_txns"

  def prefix, do: @prefix
  def messages_table, do: @messages
  def txns_table, do: @txns

  @doc "The pinned default limits (the story: 64 KiB body, 50 entries, 500 per device, 7 days; the orchestrator decisions and this step: the rest)."
  def defaults do
    %{
      max_body_bytes: 65_536,
      max_entries_per_request: 50,
      max_per_device: 500,
      max_bytes_per_device: 8 * 1024 * 1024,
      max_per_user: 2000,
      max_bytes_per_user: 32 * 1024 * 1024,
      max_per_sender_device: 100,
      max_bytes_per_sender_device: 1024 * 1024,
      max_per_sender_total: 4000,
      max_bytes_per_sender_total: 16 * 1024 * 1024,
      rate_bytes_per_min: 4 * 1024 * 1024,
      rate_bytes_burst: 8 * 1024 * 1024,
      statement_timeout_ms: 2000,
      max_per_sender_user: 200,
      max_bytes_per_sender_user: 4 * 1024 * 1024,
      max_targets_per_request: 100,
      max_fanout_bytes_per_request: 1024 * 1024,
      max_concurrent_sends_per_user: 4,
      max_concurrent_sends_per_node: 6,
      max_txns_per_device: 1000,
      sync_batch_size: 100,
      sync_batch_bytes: 1024 * 1024,
      ttl_seconds: 7 * 24 * 3600,
      txn_ttl_seconds: 24 * 3600,
      row_overhead: 128
    }
  end

  @doc "What one queued message costs the byte budgets: the canonical JSON bytes of its content plus the fixed row overhead of 128."
  def cost(content), do: byte_size(Jason.encode!(content)) + defaults().row_overhead

  # ── users and devices ───────────────────────────────────────────────────────

  @doc "A provisioned user with ONE device (a legacy session and a `devices` row). Returns `%{uid, dev, at}`."
  def user!(prefix \\ "TD") do
    uid = T.provision_user!()
    device!(%{uid: uid}, prefix)
  end

  @doc "A provisioned user whose ONE device has the given (client-chosen) device id: the id of a victim's device can be chosen by an attacker."
  def user_with_device!(dev) do
    uid = T.provision_user!()
    at = T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev)
    %{uid: uid, dev: dev, at: at}
  end

  @doc "An additional device of the user (own session, own `devices` row). Returns `%{uid, dev, at}`."
  def device!(%{uid: uid}, prefix \\ "TDX") do
    dev = prefix <> String.upcase(T.rand(3))
    at = T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev)
    %{uid: uid, dev: dev, at: at}
  end

  @doc "A new session (new access token) of an existing device: the device stays, the token changes."
  def new_token!(%{uid: uid, dev: dev} = device), do: %{device | at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}

  @doc "An invite-only room of `a` that `b` joined: the two share a room (`join` / `join`)."
  def share!(a, b), do: S.invite_room(a, [b])

  @doc "A room of `a` with `b` INVITED (not joined): the membership classes are join / invite."
  def invite_only!(a, b) do
    room = S.make_room(a, %{"preset" => "private_chat"})
    S.invite!(a, room, b)
    room
  end

  # ── requests ────────────────────────────────────────────────────────────────

  @doc """
  One request through the full `Nebu.Web.Router`. `token` nil = no Authorization header, `{:header, v}` = the header verbatim. `body`: nil | a term (JSON-encoded) |
  `{:raw, binary}` (verbatim bytes, `application/json`). Every request has its own peer address (no shared per-IP bucket).
  """
  def req(method, path, token, body \\ nil) do
    c =
      case body do
        nil -> conn(method, path)
        {:raw, raw} -> conn(method, path, raw) |> put_req_header("content-type", "application/json")
        term -> conn(method, path, Jason.encode!(term)) |> put_req_header("content-type", "application/json")
      end

    c = put_auth(c, token)
    Nebu.Web.Router.call(%{c | remote_ip: T.unique_ip()}, @router_opts)
  end

  defp put_auth(c, nil), do: c
  defp put_auth(c, {:header, value}), do: put_req_header(c, "authorization", value)
  defp put_auth(c, token), do: put_req_header(c, "authorization", "Bearer " <> token)

  def json(conn), do: T.json(conn)
  def seg(s), do: URI.encode(s, &URI.char_unreserved?/1)
  def send_path(type, txn), do: "#{@prefix}/#{seg(type)}/#{seg(txn)}"
  def txn, do: "txn-" <> T.rand(6)

  @doc "`PUT /sendToDevice/{type}/{txn}`. `body` is a `messages` map (wrapped) or `{:raw, bytes}` / any other term sent as the body verbatim via `{:body, term}`."
  def put_send(sender, type, txn_id, {:raw, _} = raw), do: req(:put, send_path(type, txn_id), sender.at, raw)
  def put_send(sender, type, txn_id, {:body, term}), do: req(:put, send_path(type, txn_id), sender.at, term)
  def put_send(sender, type, txn_id, messages) when is_map(messages), do: req(:put, send_path(type, txn_id), sender.at, %{"messages" => messages})

  @doc "Sends and asserts `200 {}`; returns the conn."
  def send!(sender, type, txn_id, messages) do
    c = put_send(sender, type, txn_id, messages)
    assert c.status == 200, "sendToDevice: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    assert json(c) == %{}, "the answer is exactly {}: #{c.resp_body}"
    c
  end

  @doc "Sends one message of type `type` with a fresh txn id to the (user, device); returns the conn asserted 200."
  def tell!(sender, to, type, content), do: send!(sender, type, txn(), msg(to, content))

  @doc "`%{uid => %{device => content}}` for one recipient (`to` is a device map, a user map with `dev` = \"*\", or `{uid, dev}`)."
  def msg(%{uid: uid, dev: dev}, content), do: %{uid => %{dev => content}}
  def msg({uid, dev}, content), do: %{uid => %{dev => content}}
  def star(%{uid: uid}, content), do: %{uid => %{"*" => content}}

  @doc "Merges `messages` maps (user level and device level)."
  def merge(maps), do: Enum.reduce(maps, %{}, fn m, acc -> Map.merge(acc, m, fn _u, d1, d2 -> Map.merge(d1, d2) end) end)

  @doc "Everything that could tell two answers apart: status, body and every header except the per-request ones."
  def shape(conn) do
    headers = for {k, v} <- conn.resp_headers, k not in ["x-request-id", "date", "content-length"], do: {k, v}
    {conn.status, conn.resp_body, Enum.sort(headers)}
  end

  # ── the sync client ─────────────────────────────────────────────────────────

  def sync(device, since \\ nil, params \\ []), do: S.sync(device, since, params)
  def sync_conn(device, params), do: S.sync_conn(device, params)
  def next(body), do: body["next_batch"]
  def events(body), do: get_in(body, ["to_device", "events"])

  @doc "An expected event as the sync delivers it (exactly these three members)."
  def ev(sender, type, content), do: %{"sender" => sender.uid, "type" => type, "content" => content}

  @doc """
  A privileged DEFERRED constraint trigger that makes the COMMIT of every message whose content contains `marker` last `seconds` (a send that stays in flight, with its row
  already inserted, without any row lock). Each sleeping backend first takes a transaction advisory lock `(key, backend pid)` that `wait_sleeping/1` counts, so a test only
  waits for ITS OWN sends (never for the backends of another test). Removed by `on_exit`. Returns `remove/0`; the key is kept in the test process.
  """
  def slow_commit_trigger!(marker, seconds) do
    name = "atdd_td_slow_" <> T.rand(4)
    key = :erlang.unique_integer([:positive]) |> rem(2_000_000_000)
    Process.put(:td_slow_key, key)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN PERFORM pg_advisory_xact_lock(#{key}, pg_backend_pid()); PERFORM pg_sleep(#{seconds}); RETURN NULL; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!(
      "CREATE CONSTRAINT TRIGGER #{name} AFTER INSERT ON #{@messages} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.content LIKE '%#{marker}%') EXECUTE FUNCTION #{name}()"
    )

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{@messages}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc "Waits (bounded poll) until `n` sends of THIS test (the trigger of `slow_commit_trigger!/2`) are sleeping in their commit."
  def wait_sleeping(n) do
    key = Process.get(:td_slow_key) || raise "wait_sleeping/1 needs slow_commit_trigger!/2 in the same test"

    assert :ok =
             S.wait_until(
               fn -> T.sql!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = $1 AND granted", [key]).rows |> hd() |> hd() >= n end,
               10_000
             ),
           "the #{n} sends are not in flight"
  end

  @doc """
  A privileged trigger that makes the STATEMENT that inserts (`:insert`, BEFORE INSERT) or stamps / acknowledges (`:update`, BEFORE UPDATE) or deletes (`:delete`, BEFORE DELETE: an eviction, an acknowledgement, a purge) a message whose content contains
  `marker` last `seconds` (the transaction stays open inside the statement, holding the locks it took before: the key share on the target devices). Like
  `slow_commit_trigger!/2` each sleeping backend takes the advisory lock `(key, backend pid)` that `wait_sleeping/1` counts. Removed by `on_exit`. Returns `remove/0`.
  """
  def slow_statement_trigger!(marker, seconds, event \\ :insert) when event in [:insert, :update, :delete] do
    name = "atdd_td_slowst_" <> T.rand(4)
    key = :erlang.unique_integer([:positive]) |> rem(2_000_000_000)
    Process.put(:td_slow_key, key)
    {sql_event, row} = %{insert: {"INSERT", "NEW"}, update: {"UPDATE", "NEW"}, delete: {"DELETE", "OLD"}}[event]

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN PERFORM pg_advisory_xact_lock(#{key}, pg_backend_pid()); PERFORM pg_sleep(#{seconds}); RETURN #{row}; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE #{sql_event} ON #{@messages} FOR EACH ROW WHEN (#{row}.content LIKE '%#{marker}%') EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{@messages}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  @doc "The backend pids of the sends that sleep inside the trigger of this test (the advisory lock `(key, pid)` of `slow_*_trigger!`)."
  def sleeping_pids do
    key = Process.get(:td_slow_key) || raise "needs slow_*_trigger! in the same test"
    T.sql!("SELECT objid::bigint FROM pg_locks WHERE locktype = 'advisory' AND classid = $1 AND granted", [key]).rows |> List.flatten()
  end

  @doc "Row-locks the oldest `limit` (default: all) queued messages of one device (`FOR UPDATE`) in a transaction of its own that stays open (`E.hold/1`-style): what an eviction or an ack of another request holds."
  def lock_rows!(uid, dev, limit \\ 1_000_000) do
    # (apply/3: the module is loaded after this file by test_helper.exs; a literal call would warn at compile time, warnings are errors in the unit job)
    apply(Nebu.Compliance.UserDeletionTestSupport, :hold, [
      fn -> T.sql!("SELECT stream_pos FROM #{@messages} WHERE user_id = $1 AND device_id = $2 ORDER BY stream_pos LIMIT $3 FOR UPDATE", [uid, dev, limit]) end
    ])
  end

  @doc "Waits (bounded poll) until a /sync process of the user joined its `:pg` group, i.e. the long poll is really waiting."
  def wait_polling(uid, count \\ 1) do
    assert :ok = S.wait_until(fn -> length(:pg.get_local_members("user:#{uid}")) >= count end, 10_000), "the sync never started polling"
  end

  @doc "The delivered events of a device in order, the token chain applied: syncs with `since` until nothing new comes (at most 10 rounds). Returns `{events, last_token}`."
  def drain(device, since, rounds \\ 10) do
    Enum.reduce_while(1..rounds, {[], since}, fn _, {acc, token} ->
      body = sync(device, token)
      evs = events(body)
      if evs == [] and token != nil, do: {:halt, {acc, next(body)}}, else: {:cont, {acc ++ evs, next(body)}}
    end)
  end

  @doc """
  Runs the request `fun` like a well-behaved client: a `429 M_LIMIT_EXCEEDED` (a transaction in flight, a busy row) is retried after a short pause until another answer comes, at
  most `attempts` times. The same txn id is reused by the caller, so a retry is idempotent.
  """
  def retrying(fun, attempts \\ 400) do
    conn = fun.()

    if attempts > 1 and conn.status == 429 and json(conn)["errcode"] == "M_LIMIT_EXCEEDED" do
      Process.sleep(Enum.random(2..15))
      retrying(fun, attempts - 1)
    else
      conn
    end
  end

  @doc "The statements (SQL text) the calling process issues while `fun` runs, restricted to those that mention `needle` (default `to_device`). Returns `{result, statements}`."
  def statements(fun, needle \\ "to_device") do
    # (apply/3: the module is loaded after this file by test_helper.exs; a literal call would warn at compile time, warnings are errors in the unit job)
    {result, all} = apply(Nebu.Matrix.MembershipStateTestSupport, :count_statements, [fun])
    {result, Enum.filter(all, &String.contains?(&1, needle))}
  end

  # ── database probes (runtime role) ──────────────────────────────────────────

  def queue_count(uid, dev), do: T.sql!("SELECT count(*) FROM #{@messages} WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows |> hd() |> hd()
  def queue_count(uid), do: T.sql!("SELECT count(*) FROM #{@messages} WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  def txn_count(uid, dev), do: T.sql!("SELECT count(*) FROM #{@txns} WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows |> hd() |> hd()
  def txn_count(uid), do: T.sql!("SELECT count(*) FROM #{@txns} WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  def sent_count(sender_uid), do: T.sql!("SELECT count(*) FROM #{@messages} WHERE sender = $1", [sender_uid]).rows |> hd() |> hd()

  @doc "Moves every queued message of the device `days` into the past (a TTL test)."
  def age_queue!(uid, dev, seconds), do: T.sql!("UPDATE #{@messages} SET created_at = created_at - make_interval(secs => $3) WHERE user_id = $1 AND device_id = $2", [uid, dev, seconds * 1.0])

  def age_user_queue!(uid, seconds), do: T.sql!("UPDATE #{@messages} SET created_at = created_at - make_interval(secs => $2) WHERE user_id = $1", [uid, seconds * 1.0])

  def age_txns!(uid, dev, seconds), do: T.sql!("UPDATE #{@txns} SET created_at = created_at - make_interval(secs => $3) WHERE user_id = $1 AND device_id = $2", [uid, dev, seconds * 1.0])

  # ── assertions ──────────────────────────────────────────────────────────────

  def assert_error(conn, status, errcode) do
    assert conn.status == status, "expected #{status} #{errcode}, got #{conn.status} #{String.slice(conn.resp_body || "", 0, 300)}"
    body = json(conn)
    assert body["errcode"] == errcode, "expected errcode #{errcode}, got #{inspect(body)}"
    assert is_binary(body["error"]) and body["error"] != "", "a Matrix error carries a human readable `error`"
    assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}
    body
  end

  @doc "The 429 envelope: exactly errcode, error, retry_after_ms; `Retry-After` is an integer number of seconds and agrees with the body."
  def assert_429(conn, label \\ "request"), do: S.assert_429(conn, label)

  # ── environment ─────────────────────────────────────────────────────────────

  def put_env_restoring(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  @doc "Sets the `:nebu, :to_device_<name>` seam for the rest of the test."
  def seam(name, value), do: put_env_restoring(:nebu, String.to_atom("to_device_#{name}"), value)

  def disable_rate_limit, do: put_env_restoring(:nebu_http, :rate_limit_disabled, true)

  @doc "The real limiter with a frozen clock (no refill: a burst is deterministic); the harness OS variable is neutralised and restored."
  def enable_rate_limit do
    prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
    System.delete_env("NEBU_RATE_LIMIT_DISABLED")
    ExUnit.Callbacks.on_exit(fn -> if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env) end)
    # bugfix integration-test-flakes-fix (B): `on_exit` callbacks run in REVERSE order of registration. `T.reset_rate_limits/0` (frozen clock
    # `fn -> 1_000_000 end`) used to run BEFORE the two `put_env_restoring` calls, so `put_env_restoring` captured that frozen clock as "the old value"
    # and its callback (the last one to run) put it BACK after `restore_rate_limits/0` had removed it: no per-IP bucket refilled for the rest of the
    # run (429 `M_LIMIT_EXCEEDED` in RoomAccountDataTest, SyncConcurrentTest, MatrixSsoTest, ForgetRoomMembershipPurgeTest). The seams are captured
    # first and `reset_rate_limits/0` last, as in `RoomKeysTestSupport.enable_rate_limit/0`: the cleanup then runs `restore_rate_limits/0` first and
    # the seam restores after it.
    put_env_restoring(:nebu_http, :rate_limit_clock_fn, fn -> 5_000_000 end)
    put_env_restoring(:nebu_http, :rate_limit_disabled, false)
    T.reset_rate_limits()
    # the helpers of the suites are written against this base instant (`reset_rate_limits/0` froze the clock at 1_000_000): the clock of the test
    # stays 5_000_000, as it was when the seams were installed in the opposite order. Restored by the `put_env_restoring` above (it runs after
    # `restore_rate_limits/0`, which puts back the 5_000_000 clock captured by `reset_rate_limits/0`).
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 5_000_000 end)
    ExUnit.Callbacks.on_exit(&T.restore_rate_limits/0)
  end

  @doc "Freezes the rate-limit clock at `ms`."
  def set_clock(ms), do: Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> ms end)

  def with_log_level(level, fun) do
    original = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original)
    end
  end

  @doc "The text of a log capture of `fun` at `:debug`."
  def debug_log(fun), do: ExUnit.CaptureLog.capture_log([level: :debug], fn -> with_log_level(:debug, fun) end)

  # ── seeding for the GDPR erasure inventory ──────────────────────────────────

  @doc """
  Seeds the to-device state of `uid` (a user whose device `dev` has a `devices` row) through the REAL route, without any room: the user sends two messages from `dev`
  to a second device of its own (`dev` + "B"), so `to_device_messages` has two rows of `uid` as recipient AND as sender and `to_device_txns` two records of `uid`.
  Every content carries `canary`. The temporary session is removed again, so the teardown tables of the erasure inventory are exactly as before.
  Returns `%{second: dev2, queued_for: 2, sent_by: 2}`.
  """
  def seed_to_device!(uid, dev, canary) do
    prev_disabled = Application.fetch_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    me = %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
    second = dev <> "B"
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev)
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, second)

    try do
      tell!(me, {uid, second}, "m.key.verification.request", %{"canary" => "td-1-#{canary}"})
      tell!(me, {uid, second}, "m.room_key_request", %{"canary" => "td-2-#{canary}"})
      %{second: second, queued_for: 2, sent_by: 2}
    rescue
      e in ExUnit.AssertionError ->
        msg = "ToDeviceTestSupport.seed_to_device! (called by UserDeletionTestSupport.seed_user!/2: every erasure suite seeds the to-device state through the sendToDevice route of story to-device-messaging) failed: "
        reraise %{e | message: msg <> e.message}, __STACKTRACE__
    after
      case prev_disabled do
        {:ok, v} -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        :error -> Application.delete_env(:nebu_http, :rate_limit_disabled)
      end

      T.sql!("DELETE FROM matrix_sessions WHERE access_token_hash = $1", [T.token_hash(me.at)])
    end
  end
end
