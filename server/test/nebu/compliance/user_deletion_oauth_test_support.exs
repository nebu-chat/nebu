defmodule Nebu.Compliance.UserDeletionTestSupport do
  @moduledoc """
  Shared helpers of the real-database suites of story `gdpr-erasure-global-data` (epic oauth-broker, follow-up `ck`, REQ-2026-005): the
  seeded "world" of an erasure test (a user with a row in every table of the story's inventory, written through the REAL writers where
  one exists), snapshots of the rows of a user, the generic privileged "fault" trigger, the audit counters and the contract lists.

  Loaded once from `test_helper.exs` (like the other support modules); every function is `def` (no unused private helper per suite). The FILE NAME ends with
  `oauth_test_support.exs` on purpose: `mix.exs` already ignores that suffix (`test_ignore_filters`); a support file the filters do not know makes
  `mix test --warnings-as-errors` exit 1 ("files do not match any of the configured :test_load_filters"), so a differently named file would need a mix.exs edit.

  `setup_env!/0` writes the process-global `:compliance` / `:audit_writer` Application env key (the real writer instead of the no-op one): every suite that
  calls it MUST be `async: false` (shared global :compliance env key; the guard `AuditWriterSeamRaceRegressionTest` scans this file for that text too).

  ## The contract lists (the story's inventory, D2)

    * `expected_erased/0`: the tables whose rows of the erased user the erasure TRANSACTION must delete (inventory rows "DELETE"; the
      dev agent may EXTEND `Nebu.Compliance.UserDeletion.erased_tables/0` after verifying the inventory, never shrink it).
    * `teardown_tables/0`: the tables the POST-COMMIT session teardown of the dispatcher already empties for the user (inventory rows
      "unchanged"): deleted outside the transaction, best effort.
    * `retained_reasons/0`: the tables with a per-user column that the erasure keeps ON PURPOSE, each with its reason (D2, D3).
  """
  import ExUnit.Assertions

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  @expected_erased ~w(
    account_data cross_signing_keys device_keys device_one_time_keys device_fallback_keys user_room_account_data
    forgotten_rooms auto_join_opt_outs read_receipts uia_sessions oauth_account_sessions oauth_consent_requests oauth_codes
  )

  @teardown_tables ~w(devices matrix_sessions jwt_device_bindings sessions oauth_idp_refresh_leases sync_tokens sync_room_cursors)

  @retained_reasons %{
    "user_keys" => "public keys stay: they keep the signatures of retained events verifiable (private key NULL, deleted_at set)",
    "users" => "the pseudonymous identity row referenced by events, membership and foreign keys (the PII columns are set to NULL, is_active false)",
    "profiles" => "the row stays and is ANONYMISED by the erasure (displayname 'Deleted User', avatar_url NULL)",
    "room_members" => "mirror of retained membership events (room history preservation, recital 65); the user id is the pseudonym",
    "room_invitations" => "mirror of retained invite events; inviter_id / invitee_id are pseudonymous user ids",
    "rooms" => "creator_user_id of a room whose signed events are retained",
    "events" => "retained signed event log, sender is the pseudonym (room history preservation)",
    "media_files" => "uploader_user_id of media referenced by retained events; lifecycle per ADR-030",
    "media_state_transitions" => "actor_id of media lifecycle transitions: accountability record, ADR-030",
    "audit_log" => "accountability: append-only, retained 7 years",
    "compliance_requests" => "requester / approver of compliance accesses: legal obligation",
    "oauth_clients" => "approved_by / rejected_by / revoked_by of the admin decisions on a client registration: admin accountability record, not data of the erased user",
    "war_room_sessions" => "started_by of admin war-room sessions: admin accountability record",
    "admin_temporary_captures" => "started_by of admin captures: admin accountability record",
    "role_overrides" => "dormant table (no writer in server/lib); user_id / granted_by of admin role overrides",
    "push_rules" => "dormant: FORCE RLS table without a writer in server/lib, no row can exist",
    "pushers" => "dormant: FORCE RLS table without a writer in server/lib, no row can exist",
    "notifications" => "dormant: FORCE RLS table without a writer in server/lib, no row can exist",
    "room_account_data" => "dormant legacy table without a writer in server/lib (superseded by user_room_account_data)",
    "admin_sessions" => "dormant: no writer in server/lib, no row can exist",
    "message_buffer" => "dormant: no writer in server/lib (sender column), no row can exist"
  }

  # the `users` columns that hold personal data ciphertexts: NULLed by the erasure and the sweep (D16)
  @users_pii_columns ~w(display_name_encrypted display_name_nonce avatar_url_encrypted avatar_url_nonce email_encrypted email_nonce email_ephemeral_pub)

  # cycle 2: a behavioural timestamp and admin free text, NULLed by the erasure and the sweep as well
  @users_free_text_columns ~w(last_seen_at deactivation_reason)

  def users_pii_columns, do: @users_pii_columns
  def users_free_text_columns, do: @users_free_text_columns
  def expected_erased, do: @expected_erased
  def teardown_tables, do: @teardown_tables
  def retained_reasons, do: @retained_reasons
  def admin, do: "@admin:test.local"
  def admin_stream, do: %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}

  # ── environment ────────────────────────────────────────────────────────────

  @doc """
  The OAuth switch + IdP stub (an OAuth client and codes need them), and the REAL `AuditWriter` (the test config uses the no-op
  writer). Everything is restored by `on_exit`. Returns `%{priv, cid}`.
  """
  def setup_env! do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    cid = T.oauth_client!([@https])
    prior = Application.fetch_env(:compliance, :audit_writer)
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:compliance, :audit_writer, v)
        :error -> Application.delete_env(:compliance, :audit_writer)
      end

      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :uia_fresh_auth_seconds], do: Application.delete_env(:nebu_http, k)
    end)

    %{priv: priv, cid: cid}
  end

  # ── the seeded world ───────────────────────────────────────────────────────

  @doc """
  A user with data in EVERY table of the inventory. Written through the real writers where one exists (`Profile.DB`, `AccountDataStore.put/3`,
  `CrossSigningKeyStore.put_keys/2`, `DeviceKeyStore`, `Room.DB`, `Uia.mint_session/3`, the OAuth fixtures of `TestSupport`), plain SQL for
  the rest. Every secret-looking value carries `canary`: a unique marker that must never reach a log or an audit row.

  Returns `%{uid, dev, ghost, room, canary, secrets, grant}`: `dev` has a `devices` row, `ghost` has device key rows WITHOUT a `devices`
  row (what the post-commit teardown cannot find), `secrets` is every canary string seeded, `grant` the seeded authorization code.
  """
  def seed_user!(cid, label) do
    canary = "ck#{label}#{T.rand(5)}"
    uid = T.provision_user!()
    dev = "CKD" <> String.upcase(T.rand(3))
    ghost = "CKG" <> String.upcase(T.rand(3))
    room = "!#{canary}:test.local"
    partner = "@dm-#{canary}:test.local"
    now = System.system_time(:millisecond)

    display = "Display-#{canary}"
    avatar = "mxc://test.local/avatar-#{canary}"
    :ok = Nebu.Matrix.Profile.DB.upsert_profile(uid, display, avatar)
    # the avatar ciphertext columns of `users` (the provisioning writes none): placeholders, so that "NULLed by the erasure" is observable (D16)
    T.sql!("UPDATE users SET avatar_url_encrypted = $2, avatar_url_nonce = $3 WHERE user_id = $1", [uid, <<1, 2, 3, 4>>, <<5, 6, 7, 8>>])
    # the behavioural timestamp and the admin free text of the users row (cycle 2): NULLed by the erasure and the sweep
    T.sql!("UPDATE users SET last_seen_at = 1234567, deactivation_reason = $2 WHERE user_id = $1", [uid, "reason-#{canary}"])

    account_data = [
      {"m.secret_storage.default_key", %{"key" => "defkey-#{canary}"}},
      {"m.secret_storage.key.KEY#{canary}", %{"algorithm" => "m.secret_storage.v1.aes-hmac-sha2", "iv" => "iv-#{canary}", "mac" => "mac-#{canary}"}},
      {"m.cross_signing.master", %{"encrypted" => %{"KEY#{canary}" => %{"ciphertext" => "ct-master-#{canary}"}}}},
      {"m.push_rules", %{"global" => %{"override" => [%{"rule_id" => "rule-#{canary}", "enabled" => true}]}}},
      {"m.direct", %{partner => ["!dm-#{canary}:test.local"]}},
      {"m.ignored_user_list", %{"ignored_users" => %{"@ignored-#{canary}:test.local" => %{}}}}
    ]

    for {type, content} <- account_data, do: :ok = Nebu.Matrix.AccountDataStore.put(uid, type, Jason.encode!(content))
    :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(uid, T.cross_signing_keys(uid, canary))

    T.seed_device_keys!(uid, dev)
    # the legacy device row the teardown must remove: a display name and the last IP address are personal data
    device_name = "Phone-#{canary}"
    device_ip = "10.#{:rand.uniform(250)}.#{:rand.uniform(250)}.#{:rand.uniform(250)}"
    :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: device_name, last_seen_ip: device_ip, last_seen_ts: now)
    T.seed_device_keys!(uid, ghost)
    T.sql!("DELETE FROM devices WHERE user_id = $1 AND device_id = $2", [uid, ghost])
    assert T.sql!("SELECT count(*) FROM device_keys WHERE user_id = $1 AND device_id = $2", [uid, ghost]).rows == [[1]], "seed: the ghost device keeps its key row"

    {:ok, _} = Nebu.Matrix.Room.DB.insert_room(room)
    T.sql!("UPDATE users SET personal_room_id = $2 WHERE user_id = $1", [uid, room])
    T.sql!("INSERT INTO room_members (room_id, user_id, joined_at) VALUES ($1, $2, $3)", [room, uid, now])

    T.sql!(
      "INSERT INTO user_room_account_data (user_id, room_id, type, content_json, created_at, updated_at) VALUES ($1, $2, 'm.fully_read', $3, $4, $4)",
      [uid, room, Jason.encode!(%{"event_id" => "$fr-#{canary}"}), now]
    )

    T.sql!("INSERT INTO forgotten_rooms (user_id, room_id) VALUES ($1, $2)", [uid, "!forgot-#{canary}:test.local"])
    T.sql!("INSERT INTO read_receipts (room_id, user_id, event_id, receipt_type, received_at) VALUES ($1, $2, $3, 'm.read', $4)", [room, uid, "$rr-#{canary}", now])
    T.sql!("INSERT INTO auto_join_opt_outs (room_id, user_id, opted_out_at) VALUES ($1, $2, $3)", [room, uid, now])

    :ok =
      Nebu.Matrix.Room.DB.insert_event(%{
        "event_id" => "$ev-#{canary}",
        "room_id" => room,
        "sender" => uid,
        "type" => "m.room.message",
        "state_key" => nil,
        "content" => %{"msgtype" => "m.text", "body" => "message of #{canary}"},
        "origin_server_ts" => now,
        "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(32))}
      })

    _sid = T.uia_session!(uid)
    _acc = T.account_session!(uid)
    _consent = T.insert_consent!(cid, user_id: uid, idp_rt: "idp-rt-consent-#{canary}")
    grant = T.insert_code!(cid, user_id: uid, device_id: dev, idp_rt: "idp-rt-code-#{canary}")

    :ok = Nebu.Compliance.AuditWriter.log(admin(), "user_deactivated", "user", uid, %{"reason" => "seed-#{canary}"}, "success")

    secrets = %{
      display: display,
      avatar: avatar,
      default_key: "defkey-#{canary}",
      ciphertext: "ct-master-#{canary}",
      iv: "iv-#{canary}",
      mac: "mac-#{canary}",
      rule: "rule-#{canary}",
      partner: partner,
      ignored: "@ignored-#{canary}:test.local",
      cross_signing: "MSK#{canary}",
      idp_rt_consent: "idp-rt-consent-#{canary}",
      idp_rt_code: "idp-rt-code-#{canary}",
      message: "message of #{canary}",
      device_name: device_name,
      device_ip: device_ip
    }

    %{uid: uid, dev: dev, ghost: ghost, room: room, canary: canary, secrets: secrets, grant: grant, partner: partner}
  end

  @doc """
  Legacy session + a row in EVERY table of `teardown_tables/0` for the user (what the post-commit teardown ends): the `sessions` / `sync_tokens` rows, a cursor row
  of the initial-sync persist, a raw-JWT binding, an IdP refresh lease (cascades from `devices`) and the `matrix_sessions` row. Every teardown table has a
  precondition here, so a table listed there without a seed fails (`>= 1`) instead of passing a vacuous zero check. Returns the session `%{at, rt}`.
  """
  def seed_sessions!(w) do
    T.seed_legacy_session_rows!(w.uid, w.dev)
    session = T.legacy_session!(w.uid, w.dev)

    :ok =
      Nebu.Matrix.Session.PgStore.Postgres.persist_sync_position(w.uid, w.dev, %{
        mode: :initial,
        new_token: "s2_" <> T.rand(11),
        last_event_id: nil,
        keep: [],
        rows: [%{room_id: w.room, pos: 1, class: "join", invite_marker: nil, base: nil}]
      })

    T.sql!(
      "INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at) VALUES ($1, $2, $3, $4, $5)",
      [T.sha256_hex("jwt-" <> T.rand(12)), w.uid, w.dev, System.system_time(:second) + 3600, System.system_time(:millisecond)]
    )

    :ok = T.hold_lease!(w.uid, w.dev, 60)

    for t <- @teardown_tables, do: assert(count(t, w.uid) >= 1, "seed_sessions!: no row in the teardown table #{t}")
    session
  end

  # ── snapshots and counters ─────────────────────────────────────────────────

  @doc "md5 over the whole rows of `table` of the user (column `col`), ordered: a changed, replaced or deleted row changes it."
  def fp(table, uid, col \\ "user_id") do
    true = Regex.match?(~r/\A[a-z_]+\z/, table) and Regex.match?(~r/\A[a-z_]+\z/, col)

    %{rows: [[h]]} =
      T.sql!("SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) FROM #{table} t WHERE t.#{col} = $1", [uid])

    h
  end

  def count(table, uid, col \\ "user_id") do
    true = Regex.match?(~r/\A[a-z_]+\z/, table) and Regex.match?(~r/\A[a-z_]+\z/, col)
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM #{table} WHERE #{col} = $1", [uid])
    n
  end

  @doc "`%{table => fingerprint}` of the user over the erased, teardown and a few retained tables."
  def snapshot(uid, tables \\ nil) do
    tables = tables || (@expected_erased ++ @teardown_tables ++ ~w(users profiles user_keys room_members))
    Map.new(tables, fn t -> {t, fp(t, uid)} end)
  end

  @doc "Row counts of the user over the same tables."
  def counts(uid, tables \\ nil) do
    tables = tables || (@expected_erased ++ @teardown_tables ++ ~w(users profiles user_keys room_members))
    Map.new(tables, fn t -> {t, count(t, uid)} end)
  end

  def user_row(uid) do
    %{rows: [row], columns: cols} = T.sql!("SELECT * FROM users WHERE user_id = $1", [uid])
    cols |> Enum.zip(row) |> Map.new()
  end

  def profile(uid) do
    case T.sql!("SELECT displayname, avatar_url FROM profiles WHERE user_id = $1", [uid]).rows do
      [[d, a]] -> %{displayname: d, avatar_url: a}
      [] -> nil
    end
  end

  def audit_count(uid, action) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM audit_log WHERE target_id = $1 AND action = $2", [uid, action])
    n
  end

  def audit_rows(uid, action) do
    T.sql!("SELECT actor_user_id, outcome, metadata::text, error_detail FROM audit_log WHERE target_id = $1 AND action = $2 ORDER BY id", [uid, action]).rows
  end

  def events_of(uid), do: count("events", uid, "sender")

  # ── the generic fault ──────────────────────────────────────────────────────

  @doc """
  Every `event` (`"DELETE"` | `"UPDATE"`) of a row of `user_id` in `table` fails (privileged BEFORE trigger raising a fixed text that carries
  nothing of the data). Removed by `on_exit`; returns a 0-arity fun that removes it early.
  """
  def block!(table, event, user_id) when event in ["DELETE", "UPDATE"] do
    true = Regex.match?(~r/\A[a-z_]+\z/, table)
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)
    name = "atdd_ck_fault_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF OLD.user_id = '#{user_id}' THEN " <>
        "RAISE EXCEPTION 'atdd: forced failure'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  # ── concurrency helpers (own pooled connection per Task, no sandbox) ───────

  @doc """
  A transaction of its own (Task + `Nebu.Repo.transaction/1`) that runs `fun`, reports `{:held, pid, backend_pid, result}` and stays OPEN until
  `finish/2`. A remaining open transaction is rolled back by `on_exit`. MUST be called from the test process.
  """
  def hold(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Nebu.Repo.transaction(fn ->
          %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
          result = fun.()
          send(parent, {:held, self(), backend, result})

          receive do
            :commit -> :committed
            :rollback -> Nebu.Repo.rollback(:atdd_rollback)
          after
            60_000 -> Nebu.Repo.rollback(:atdd_timeout)
          end
        end)
      end)

    assert_receive {:held, pid, backend, result}, 15_000
    ExUnit.Callbacks.on_exit(fn -> send(pid, :rollback) end)
    %{task: task, pid: pid, backend: backend, result: result}
  end

  def finish(%{task: task, pid: pid}, :commit) do
    send(pid, :commit)
    assert {:ok, :committed} = Task.await(task, 15_000)
  end

  def finish(%{task: task, pid: pid}, :rollback) do
    send(pid, :rollback)
    assert {:error, :atdd_rollback} = Task.await(task, 15_000)
  end

  @doc """
  `tasks` (a list of Tasks) must ALL be blocked by a lock of the transaction of `backend`: this many backends wait for a lock held by it
  (polled up to 10 s); a task that completes first fails the test (it did not wait).
  """
  def await_blocked!(tasks, backend, what), do: await_blocked!(List.wrap(tasks), backend, what, System.monotonic_time(:millisecond) + 10_000)

  defp await_blocked!(tasks, backend, what, deadline) do
    for task <- tasks do
      case Task.yield(task, 0) do
        {:ok, result} -> flunk("#{what} completed (#{inspect(result, limit: 5)}) while the other transaction held the lock: it did not wait for it")
        {:exit, reason} -> flunk("#{what} crashed: #{inspect(reason, limit: 5)}")
        nil -> :ok
      end
    end

    # a waiter is blocked by the holder directly, or (a second updater of the same row queues behind the first waiter) through another waiter
    %{rows: [[waiting]]} =
      T.sql!(
        "SELECT count(*) FROM pg_stat_activity w WHERE w.wait_event_type = 'Lock' AND ($1 = ANY(pg_blocking_pids(w.pid)) OR " <>
          "EXISTS (SELECT 1 FROM unnest(pg_blocking_pids(w.pid)) b(pid) WHERE $1 = ANY(pg_blocking_pids(b.pid))))",
        [backend]
      )

    cond do
      waiting >= length(tasks) -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("#{what}: only #{waiting} of #{length(tasks)} backends wait for a lock of the other transaction within 10 s")
      true -> Process.sleep(20) && await_blocked!(tasks, backend, what, deadline)
    end
  end

  @doc "The user advisory lock key of the story: the SAME key as `AccountDataStore.put/3` and `CrossSigningKeyStore.put_keys/2`."
  def lock_user_sql, do: "SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))"
end
