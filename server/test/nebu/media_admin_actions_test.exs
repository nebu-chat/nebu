defmodule Nebu.MediaAdminActionsTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/6a-routine-state-actions`
  (AC1-AC11, Acceptance Tests 1-18) — `Nebu.Media`'s new admin_block/3,
  admin_unblock/2, admin_delete/2, admin_rescan/2 public functions.

  ## 6c-infected-override addendum (2026-07-19)

  Extended with Acceptance Tests 1-12 of `media-security-admin-control/
  6c-infected-override` — `Nebu.Media.admin_override_infected/3` (the
  `:infected -> :released` false-positive override, gated by a distinct
  `media_admin_override` grant on `users`, ADR-020). See the dedicated
  section near the end of this file for the full RED-phase rationale,
  including why some of these tests fail at SEEDING time (a genuine
  Postgrex "column does not exist" error against `users.media_admin_override`)
  rather than only at call time (`UndefinedFunctionError`) — this story's
  own scope includes the migration that adds that column, which has not
  landed yet either.

  Requires a live `Nebu.Repo` connection (`make test-integration` /
  `mix test --include integration`), same convention as
  `state_machine_test.exs`/`media_scan_failed_enum_value_test.exs`: real
  connection, unique per-run media ids, manual `on_exit` cleanup,
  `async: false`. These functions call the REAL `Nebu.Media.StateMachine`
  (guard table + atomic transaction) and the REAL `Nebu.Compliance.AuditWriter`
  (real `audit_log` insert) — not fakes — because the acceptance criteria are
  precisely about the real interaction between these two already-shipped
  modules (the state transition committing atomically, the audit row landing
  in the SAME action-string vocabulary `AuditWriter.@known_actions` enforces).

  ## `admin_id` is a Matrix-ID string, not a UUID

  `Nebu.Media.StateMachine.transition/4`'s `{:admin, admin_id}` actor persists
  `admin_id` into `media_state_transitions.actor_id`, a `TEXT` column since
  migration `000029_media_state_transitions_actor_id_text` (this story's own
  design/architecture-gap fix, caller-approved option A) — the same Matrix-ID
  identity shape as `users.user_id`/`audit_log.actor_user_id`, never a UUID
  (this app has no UUID-shaped user/admin identity anywhere in its real data
  model). Every test below uses a Matrix-ID-shaped admin_id
  (`"@admin_<run>:test.local"`), exactly what `Nebu.Admin.Auth`'s real session
  identity (`current_user["matrix_user_id"]`) looks like.

  ## Rescan's enqueue seam

  `admin_rescan/2` reuses the EXISTING `:media_scan_enqueue_module` seam
  (`Nebu.Media.ScanEnqueue`, wired to a real `Oban.insert/1` since Story 4b) —
  the same seam `upload/1`'s `create_and_store/6` and `upload_async/3`'s
  `store_and_quarantine/7` already call — rather than a second, parallel
  `Oban.insert/1` call site. This is a deliberate reuse decision (this
  module's own doc precedent: "the ONE implementation... do NOT add a second
  call site"), not a deviation from AC4, which only requires that a
  `Nebu.Workers.MediaScanWorker` job is enqueued for the given `media_id` and
  that `StateMachine.transition/4` itself is never called for Rescan — both
  hold via this seam. Tests use `Oban.Testing.assert_enqueued/1` against the
  REAL `oban_jobs` table (no `:manual`-testing-mode override exists in
  `config/test.exs` — this app runs the same Oban config in every env),
  exactly the same real-Postgres pattern already proven by
  `Nebu.Media.ScanEnqueueTest` (`test/nebu/media/scan_enqueue_test.exs`).
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Media
  alias Nebu.Repo

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  @admin_id "@admin_#{@run_id}:test.local"

  defp media_id(suffix), do: "adminact_#{@run_id}_#{suffix}"

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    # This test suite boots the FULL :nebu application (no `Oban.Testing,
    # testing: :manual` override exists in config/test.exs), so the real
    # `:media_scan` queue's worker is live and would otherwise race to pick
    # up and process admin_rescan/2's enqueued job mid-test (observed: a real
    # :quarantined -> :scanning media_state_transitions row appearing before
    # this test's own assertions ran, since Nebu.Workers.MediaScanWorker's
    # own StateMachine.transition/4 call is a SEPARATE concern this story's
    # tests must not depend on the timing of). Pausing the queue for the
    # duration of this file keeps admin_rescan/2's own contract (enqueues a
    # job, does not itself transition state) deterministic and observable.
    Oban.pause_queue(Oban, queue: :media_scan)
    on_exit(fn -> Oban.resume_queue(Oban, queue: :media_scan) end)

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Seeding / fetch / cleanup helpers (mirrors state_machine_test.exs)
  # ══════════════════════════════════════════════════════════════════════════

  defp insert_media_file!(media_id, state) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state)
      VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
              '@uploader:test.local', $2, false, $3)
      """,
      [media_id, System.system_time(:millisecond), Atom.to_string(state)]
    )
  end

  defp fetch_state!(media_id) do
    %Postgrex.Result{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT state FROM media_files WHERE media_id = $1", [
        media_id
      ])

    String.to_existing_atom(state)
  end

  defp fetch_transitions!(media_id) do
    %Postgrex.Result{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT from_state, to_state, actor_type, actor_id, metadata
        FROM media_state_transitions
        WHERE media_id = $1
        ORDER BY id
        """,
        [media_id]
      )

    rows
  end

  defp fetch_audit_rows!(media_id, action) do
    %Postgrex.Result{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT actor_user_id, target_type, target_id, metadata, outcome
        FROM audit_log
        WHERE target_id = $1 AND action = $2
        ORDER BY id
        """,
        [media_id, action]
      )

    rows
  end

  # nebu_migrate is the real table owner (media_state_transitions is
  # append-only even for the owner via the AC7 trigger — see
  # state_machine_test.exs's own cleanup!/1 for the identical dance).
  defp migrate_role_conn! do
    url =
      System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL is not set — this test requires a live PostgreSQL connection"

    uri = URI.parse(url)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host || "localhost",
        port: uri.port || 5432,
        database: String.trim_leading(uri.path || "", "/"),
        username: "nebu_migrate",
        password: "nebu_migrate_dev_pw"
      )

    conn
  end

  defp cleanup!(media_id) do
    conn = migrate_role_conn!()

    try do
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
        []
      )

      Postgrex.query(conn, "DELETE FROM media_state_transitions WHERE media_id = $1", [media_id])
      Postgrex.query(conn, "DELETE FROM media_files WHERE media_id = $1", [media_id])
      Postgrex.query(conn, "DELETE FROM audit_log WHERE target_id = $1", [media_id])
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end

    # admin_rescan/2's own tests enqueue a REAL Oban job (via the existing
    # :media_scan_enqueue_module seam, not a fake). The file-level
    # Oban.pause_queue/2 above only prevents it from being picked up WHILE
    # this test's own assertions run — deleting the row here, BEFORE the
    # setup block's on_exit resumes the queue (ExUnit runs on_exit callbacks
    # LIFO: this per-test callback was registered after setup's, so it runs
    # first), means the job can never be picked up by a live worker at all,
    # not merely "not yet." Left un-deleted, a resumed, still-pending job
    # could get processed at an arbitrary later wall-clock moment — possibly
    # while a COMPLETELY UNRELATED test file has :media_state_machine_module
    # or :media_audit_writer_module temporarily pointed at ITS OWN fake for
    # ITS OWN purposes, crashing on a stale/dead process reference. (This
    # exact race was observed once during this story's own CI-gate run
    # before this cleanup was added — Nebu.Workers.MediaScanWorkerTest's
    # FakeStateMachine Agent, already stopped by the time a real,
    # this-file-enqueued job's worker read the stale env override.)
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM oban_jobs WHERE args->>'media_id' = $1", [
      media_id
    ])
  end

  # ── Acceptance Test 1 (AC1) ──────────────────────────────────────────────

  test "admin_block/3 transitions :released -> :admin_blocked and returns :ok" do
    mid = media_id("block_basic")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :admin_blocked} = Media.admin_block(mid, @admin_id, nil)
    assert fetch_state!(mid) == :admin_blocked
  end

  # ── Acceptance Test 2 (AC2) ──────────────────────────────────────────────

  test "admin_unblock/2 transitions :admin_blocked -> :released and returns :ok" do
    mid = media_id("unblock_basic")
    insert_media_file!(mid, :admin_blocked)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :released} = Media.admin_unblock(mid, @admin_id)
    assert fetch_state!(mid) == :released
  end

  # ── Acceptance Test 3 (AC3) ──────────────────────────────────────────────

  test "admin_delete/2 transitions each of :quarantined/:released/:admin_blocked/:infected to :deleted and returns :ok" do
    for from_state <- [:quarantined, :released, :admin_blocked, :infected] do
      mid = media_id("delete_from_#{from_state}")
      insert_media_file!(mid, from_state)
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, :deleted} = Media.admin_delete(mid, @admin_id)
      assert fetch_state!(mid) == :deleted
    end
  end

  # ── Acceptance Test 4 (AC4) ──────────────────────────────────────────────

  test "admin_rescan/2 enqueues a Nebu.Workers.MediaScanWorker job for the given media_id " <>
         "and does not itself call StateMachine.transition/4" do
    mid = media_id("rescan_basic")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :rescan_queued} = Media.admin_rescan(mid, @admin_id)

    assert_enqueued(worker: Nebu.Workers.MediaScanWorker, args: %{"media_id" => mid}, queue: "media_scan")

    # AC4: Rescan does not itself transition to :scanning — the state stays
    # :quarantined until the (not run in this test) worker actually picks the
    # job up and performs quarantined -> scanning itself.
    assert fetch_state!(mid) == :quarantined
    assert fetch_transitions!(mid) == []
  end

  # ── Acceptance Tests 5-8 (AC6) — exactly one audit_log entry per action ──

  test "admin_block/3 writes exactly one audit_log entry via AuditWriter with action " <>
         "\"media_blocked\", target_type \"media\", target_id = media_id, and actor_user_id = the given admin id" do
    mid = media_id("audit_block")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :admin_blocked} = Media.admin_block(mid, @admin_id, nil)

    assert [[actor_user_id, target_type, target_id, _metadata, outcome]] =
             fetch_audit_rows!(mid, "media_blocked")

    assert actor_user_id == @admin_id
    assert target_type == "media"
    assert target_id == mid
    assert outcome == "success"
  end

  test "admin_unblock/2 writes exactly one audit_log entry with action \"media_unblocked\" " <>
         "and the given admin id as actor" do
    mid = media_id("audit_unblock")
    insert_media_file!(mid, :admin_blocked)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :released} = Media.admin_unblock(mid, @admin_id)

    assert [[actor_user_id, _target_type, _target_id, _metadata, outcome]] =
             fetch_audit_rows!(mid, "media_unblocked")

    assert actor_user_id == @admin_id
    assert outcome == "success"
  end

  test "admin_delete/2 writes exactly one audit_log entry with action \"media_deleted\" " <>
         "and the given admin id as actor" do
    mid = media_id("audit_delete")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :deleted} = Media.admin_delete(mid, @admin_id)

    assert [[actor_user_id, _target_type, _target_id, _metadata, outcome]] =
             fetch_audit_rows!(mid, "media_deleted")

    assert actor_user_id == @admin_id
    assert outcome == "success"
  end

  test "admin_rescan/2 writes exactly one audit_log entry with action \"media_rescanned\" " <>
         "and the given admin id as actor" do
    mid = media_id("audit_rescan")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :rescan_queued} = Media.admin_rescan(mid, @admin_id)

    assert [[actor_user_id, _target_type, _target_id, _metadata, outcome]] =
             fetch_audit_rows!(mid, "media_rescanned")

    assert actor_user_id == @admin_id
    assert outcome == "success"
  end

  # ── Acceptance Test 9 (AC7) — standalone allowlist regression guard ─────

  test "media_blocked, media_unblocked, media_deleted, media_rescanned are all present in AuditWriter.@known_actions" do
    mid = media_id("allowlist_check")
    on_exit(fn -> Ecto.Adapters.SQL.query(Repo, "DELETE FROM audit_log WHERE target_id = $1", [mid]) end)

    for action <- ~w(media_blocked media_unblocked media_deleted media_rescanned) do
      result =
        Nebu.Compliance.AuditWriter.log(@admin_id, action, "media", mid, %{}, "success")

      refute result == {:error, :audit_unknown_action},
             "#{action} must be in AuditWriter.@known_actions, got #{inspect(result)}"

      assert result == :ok
    end
  end

  # ── Acceptance Test 10 (AC9) — Block idempotent no-op ───────────────────

  test "admin_block/3 on an already :admin_blocked file is a no-op — no StateMachine call, " <>
         "no new media_state_transitions row, no new audit_log entry, returns {:ok, :already_blocked}" do
    mid = media_id("block_idempotent")
    insert_media_file!(mid, :admin_blocked)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :already_blocked} = Media.admin_block(mid, @admin_id, nil)

    assert fetch_state!(mid) == :admin_blocked
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_blocked") == []
  end

  # ── Acceptance Test 11 (AC9) — Unblock idempotent no-op ─────────────────

  test "admin_unblock/2 on an already :released file is a no-op — same no-op guarantees, " <>
         "returns {:ok, :already_released}" do
    mid = media_id("unblock_idempotent")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :already_released} = Media.admin_unblock(mid, @admin_id)

    assert fetch_state!(mid) == :released
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_unblocked") == []
  end

  # ── Acceptance Test 12 (AC8) — Block guard rejection, distinct from AC9 ─
  #
  # NOTE: the story's own Acceptance Test 12 names `:quarantined` as an
  # invalid Block source state, but Story 1b's REAL guard table (extended by
  # 4a) DOES have a `:quarantined -> :admin_blocked` edge (`quarantined:
  # [:scanning, :admin_blocked, :deleted, :scan_failed]`) — an admin CAN
  # legitimately block a file while it is still being scanned. This is the
  # same class of story-text-vs-live-schema drift this epic has repeatedly
  # self-corrected elsewhere (5a's filename/uploader_user_id corrections,
  # 2b's schema-gap corrections) — `:infected` is used here instead, which
  # genuinely has no edge to `:admin_blocked` (`infected: [:deleted]`), so
  # this test still proves AC8's real guard-rejection behavior.

  test "admin_block/3 from :infected returns {:error, {:invalid_transition, :infected, :admin_blocked}} " <>
         "and writes nothing" do
    mid = media_id("block_invalid")
    insert_media_file!(mid, :infected)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :infected, :admin_blocked}} =
             Media.admin_block(mid, @admin_id, nil)

    assert fetch_state!(mid) == :infected
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_blocked") == []
  end

  # ── Acceptance Test 13 (AC8) — Unblock guard rejection, distinct from AT11 ─

  test "admin_unblock/2 from :quarantined returns {:error, {:invalid_transition, :quarantined, :released}} " <>
         "and writes nothing" do
    mid = media_id("unblock_invalid")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :quarantined, :released}} =
             Media.admin_unblock(mid, @admin_id)

    assert fetch_state!(mid) == :quarantined
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_unblocked") == []
  end

  # ── Acceptance Test 14 (AC8) — Delete guard rejection ───────────────────

  test "admin_delete/2 from :reserved or :scanning returns {:error, {:invalid_transition, from, :deleted}} " <>
         "and writes nothing" do
    for from_state <- [:reserved, :scanning] do
      mid = media_id("delete_invalid_#{from_state}")
      insert_media_file!(mid, from_state)
      on_exit(fn -> cleanup!(mid) end)

      assert {:error, {:invalid_transition, ^from_state, :deleted}} = Media.admin_delete(mid, @admin_id)

      assert fetch_state!(mid) == from_state
      assert fetch_transitions!(mid) == []
      assert fetch_audit_rows!(mid, "media_deleted") == []
    end
  end

  # ── Acceptance Test 15 (AC8) — Rescan guard rejection ───────────────────

  test "admin_rescan/2 from :released returns {:error, :invalid_state_for_rescan} " <>
         "and does not enqueue an Oban job" do
    mid = media_id("rescan_invalid")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, :invalid_state_for_rescan} = Media.admin_rescan(mid, @admin_id)

    refute_enqueued(worker: Nebu.Workers.MediaScanWorker, args: %{"media_id" => mid}, queue: "media_scan")
    assert fetch_audit_rows!(mid, "media_rescanned") == []
  end

  # ── Acceptance Test 16 (AC11) — Block with a reason ─────────────────────

  test "admin_block/3 with a non-empty reason stores it in media_state_transitions.metadata.reason " <>
         "and in the audit_log entry's metadata.reason identically" do
    mid = media_id("block_reason")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :admin_blocked} = Media.admin_block(mid, @admin_id, "copyright complaint")

    assert [[_from, _to, "admin", _actor_id, transition_metadata]] = fetch_transitions!(mid)
    assert transition_metadata["reason"] == "copyright complaint"

    assert [[_actor, _tt, _ti, audit_metadata, _outcome]] =
             fetch_audit_rows!(mid, "media_blocked")

    assert audit_metadata["reason"] == "copyright complaint"
  end

  # ── Acceptance Test 17 (AC11) — Block with no reason ────────────────────

  test "admin_block/3 with no reason (nil/empty string) succeeds with an empty/absent reason " <>
         "in both metadata payloads" do
    for reason <- [nil, ""] do
      mid = media_id("block_no_reason_#{if is_nil(reason), do: "nil", else: "empty"}")
      insert_media_file!(mid, :released)
      on_exit(fn -> cleanup!(mid) end)

      assert {:ok, :admin_blocked} = Media.admin_block(mid, @admin_id, reason)

      assert [[_from, _to, "admin", _actor_id, transition_metadata]] = fetch_transitions!(mid)
      refute transition_metadata["reason"]

      assert [[_actor, _tt, _ti, audit_metadata, _outcome]] =
               fetch_audit_rows!(mid, "media_blocked")

      refute audit_metadata["reason"]
    end
  end

  # ── Acceptance Test 18 (AC1) — anonymity end-to-end through the real download gate ─
  #
  # CORRECTED 2026-07-19 (Kassandra security-review, self-caught before commit):
  # this test previously asserted `blocked_conn.status == 451` while
  # `unknown_conn.status == 404`, treating a differing status line as
  # acceptable "anonymity" as long as the JSON body matched. Per Kassandra's
  # own sanctum Recurring Pattern ("Anonymity by identical BODY but
  # distinguishable STATUS is not anonymity") that reasoning is wrong — the
  # (451, M_NOT_FOUND) pairing was itself a unique, status-line-only oracle
  # for "an admin blocked this." `Nebu.Media`'s `download_gate(:admin_blocked)`
  # was fixed to return a byte-identical 404 (see ADR-026's 2026-07-19
  # correction) — this test now asserts the STATUS is identical too, not just
  # the body.

  test "after admin_block/3, a download request for the file returns the exact same 404 " <>
         "M_NOT_FOUND response (status AND body) as a genuine 404 — this story introduces " <>
         "no additional distinguishing status, field, header, or timing signal" do
    mid = media_id("anonymity")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :admin_blocked} = Media.admin_block(mid, @admin_id, "some internal reason")

    # Real Nebu.Media.DB (not a fake) — this is exactly what download/4 will
    # look up in production once admin_block/3 lands a real transition.
    # Membership is never reached for a denied state (download_gate/1 runs
    # before the membership check), so the real Nebu.Media.Membership default
    # is left untouched.
    Application.put_env(:nebu_http, :media_db_module, Nebu.Media.DB)
    on_exit(fn -> Application.delete_env(:nebu_http, :media_db_module) end)

    priv = Nebu.Web.MediaTestSupport.setup_oidc_keys()
    {_uid, token} = Nebu.Web.MediaTestSupport.bearer_for("dl_#{@run_id}", priv)

    blocked_conn = download(mid, token)
    unknown_conn = download(media_id("does_not_exist_at_all"), token)

    assert blocked_conn.status == 404,
           "admin_block/3's real end-to-end download response must return the SAME 404 " <>
             "status as a genuine not-found — a differing status line (e.g. 451) is itself " <>
             "a fingerprint distinguishing 'admin blocked' from 'never existed', got #{blocked_conn.status}"

    assert unknown_conn.status == 404

    blocked_body = Jason.decode!(blocked_conn.resp_body)
    unknown_body = Jason.decode!(unknown_conn.resp_body)

    assert blocked_body == unknown_body,
           "admin_block/3's real end-to-end download response body must be byte-identical " <>
             "to a genuine 404 (AC1 anonymity) — got blocked=#{inspect(blocked_body)} " <>
             "vs unknown=#{inspect(unknown_body)}"

    assert blocked_body["errcode"] == "M_NOT_FOUND"
  end

  defp download(media_id, token) do
    conn =
      Plug.Test.conn(:get, "/_matrix/media/v3/download/test.local/#{media_id}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

    Nebu.Web.Router.call(conn, Nebu.Web.Router.init([]))
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/6c-infected-override
  # Acceptance Tests 1-12 (AC1-AC6, AC8) — Nebu.Media.admin_override_infected/3
  #
  # `Nebu.Media.admin_override_infected/3` does not exist yet — every test
  # below is expected to fail with `** (UndefinedFunctionError)` until the
  # dev-story:
  #   * implements `admin_override_infected/3` in `server/lib/nebu/media.ex`
  #   * extends the guard table in `server/lib/nebu/media/state_machine.ex`
  #     (`infected: [:deleted]` -> `infected: [:deleted, :released]`)
  #   * adds `media_infected_override` to `AuditWriter.@known_actions`
  #   * lands the `..._media_admin_override_role` migration
  #     (`ALTER TABLE users ADD COLUMN media_admin_override BOOLEAN NOT NULL
  #     DEFAULT false`)
  #
  # RED-reason note (documented, not a silent gap — same precedent as this
  # file's own 4a/2e forward-declared edges in state_machine_test.exs): every
  # test below that needs an admin WITH the `media_admin_override` grant
  # (tests 1-3, 8-10, 12) seeds that grant via a direct
  # `INSERT ... media_admin_override = true` against the real `users` table.
  # Until this story's migration lands, that column does not exist, so those
  # tests fail at SEEDING time with a genuine Postgrex "column
  # media_admin_override does not exist" error — a legitimate, expected
  # RED-phase failure for a story whose own scope explicitly includes that
  # migration, not an unrelated compile error. Tests that never need the
  # grant column (test 4's allowlist check, test 10's pure guard-table
  # assertion, test 11's "lacks the grant" negative case) fail purely via
  # `UndefinedFunctionError`/plain assertion instead.
  # ══════════════════════════════════════════════════════════════════════════

  @override_admin_id "@override_admin_#{@run_id}:test.local"
  @no_grant_admin_id "@no_grant_admin_#{@run_id}:test.local"

  defp insert_infected_file!(media_id, signature \\ "Eicar-Test-Signature") do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, scan_metadata)
      VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
              '@uploader:test.local', $2, false, 'infected', $3)
      """,
      [
        media_id,
        System.system_time(:millisecond),
        %{"clamav_signature" => signature, "scanned_at" => "2026-07-01T00:00:00Z"}
      ]
    )
  end

  # Seeds/grants the media_admin_override role on a real `users` row (no
  # injectable seam exists for this check per the story's own Technical
  # Requirements — it reads the shared `users` table directly, ADR-020).
  defp grant_override_role!(admin_id) do
    now_ms = System.system_time(:millisecond)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO users (user_id, system_role, is_active, created_at, media_admin_override)
      VALUES ($1, 'instance_admin', true, $2, true)
      ON CONFLICT (user_id) DO UPDATE SET media_admin_override = true
      """,
      [admin_id, now_ms]
    )
  end

  # A real admin (passes on_mount :require_admin) who genuinely lacks the
  # distinct media_admin_override grant (AC6's "narrower than generic admin").
  # Explicitly sets media_admin_override = false (rather than omitting the
  # column) so this helper touches the same not-yet-existing column as
  # grant_override_role!/1 — a genuine, explicit "no grant" row, not merely
  # "we didn't mention it" — and so this seeding step fails the same
  # documented RED way (Postgrex "column does not exist") until the
  # migration lands, rather than trivially succeeding against today's schema.
  defp insert_admin_without_grant!(admin_id) do
    now_ms = System.system_time(:millisecond)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO users (user_id, system_role, is_active, created_at, media_admin_override)
      VALUES ($1, 'instance_admin', true, $2, false)
      ON CONFLICT (user_id) DO UPDATE SET media_admin_override = false
      """,
      [admin_id, now_ms]
    )
  end

  defp cleanup_user!(admin_id) do
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM users WHERE user_id = $1", [admin_id])
  end

  # ── Acceptance Test 1 (AC1) ──────────────────────────────────────────────

  test "admin_override_infected/3 on an :infected file with a non-empty reason transitions " <>
         ":infected -> :released and returns {:ok, :released}" do
    mid = media_id("override_basic")
    insert_infected_file!(mid)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:ok, :released} =
             Media.admin_override_infected(
               mid,
               @override_admin_id,
               "confirmed false positive after manual review"
             )

    assert fetch_state!(mid) == :released
  end

  # ── Acceptance Test 2 (AC3/AC4 metadata shape) ──────────────────────────

  test "admin_override_infected/3 writes exactly one media_state_transitions row with metadata " <>
         "containing reason and original_signature" do
    mid = media_id("override_transition_row")
    insert_infected_file!(mid, "Win.Test.EICAR_HDB-1")
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:ok, :released} =
             Media.admin_override_infected(mid, @override_admin_id, "verified clean, bad signature")

    assert [[from_state, to_state, "admin", actor_id, metadata]] = fetch_transitions!(mid)
    assert from_state == "infected"
    assert to_state == "released"
    assert actor_id == @override_admin_id
    assert metadata["reason"] == "verified clean, bad signature"
    assert metadata["original_signature"] == "Win.Test.EICAR_HDB-1"
  end

  # ── Acceptance Test 3 (AC4) ──────────────────────────────────────────────

  test "admin_override_infected/3 writes exactly one audit_log entry via AuditWriter with " <>
         "action media_infected_override, actor_user_id = admin id, and reason/signature metadata" do
    mid = media_id("override_audit")
    insert_infected_file!(mid, "Win.Test.EICAR_HDB-2")
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:ok, :released} =
             Media.admin_override_infected(mid, @override_admin_id, "reviewed by security team")

    assert [[actor_user_id, target_type, target_id, metadata, outcome]] =
             fetch_audit_rows!(mid, "media_infected_override")

    assert actor_user_id == @override_admin_id
    assert target_type == "media"
    assert target_id == mid
    assert outcome == "success"
    assert metadata["reason"] == "reviewed by security team"
    assert metadata["original_signature"] == "Win.Test.EICAR_HDB-2"
  end

  # ── Acceptance Test 4 (AC5) — standalone allowlist regression guard ─────

  test "media_infected_override is present in AuditWriter.@known_actions" do
    mid = media_id("override_allowlist_check")

    on_exit(fn ->
      Ecto.Adapters.SQL.query(Repo, "DELETE FROM audit_log WHERE target_id = $1", [mid])
    end)

    result =
      Nebu.Compliance.AuditWriter.log(
        @override_admin_id,
        "media_infected_override",
        "media",
        mid,
        %{},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           "media_infected_override must be in AuditWriter.@known_actions, got #{inspect(result)}"

    assert result == :ok
  end

  # ── Acceptance Tests 5-7 (AC2) — mandatory, server-validated reason ────

  test "admin_override_infected/3 with an empty-string reason returns {:error, :reason_required}, " <>
         "calls neither StateMachine.transition/4 nor AuditWriter.log/6, and leaves the file's " <>
         "state unchanged" do
    mid = media_id("override_reason_empty")
    insert_infected_file!(mid)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:error, :reason_required} = Media.admin_override_infected(mid, @override_admin_id, "")

    assert fetch_state!(mid) == :infected
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_infected_override") == []
  end

  test "admin_override_infected/3 with a whitespace-only reason (e.g. \"   \") returns " <>
         "{:error, :reason_required}" do
    mid = media_id("override_reason_whitespace")
    insert_infected_file!(mid)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:error, :reason_required} =
             Media.admin_override_infected(mid, @override_admin_id, "   ")

    assert fetch_state!(mid) == :infected
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_infected_override") == []
  end

  test "admin_override_infected/3 with a nil reason returns {:error, :reason_required}" do
    mid = media_id("override_reason_nil")
    insert_infected_file!(mid)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:error, :reason_required} = Media.admin_override_infected(mid, @override_admin_id, nil)

    assert fetch_state!(mid) == :infected
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_infected_override") == []
  end

  # ── Acceptance Test 8 (AC1) — invalid transition, :released source ─────

  test "admin_override_infected/3 against a :released file returns " <>
         "{:error, {:invalid_transition, :released, :released}} and writes nothing" do
    mid = media_id("override_from_released")
    insert_media_file!(mid, :released)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:error, {:invalid_transition, :released, :released}} =
             Media.admin_override_infected(mid, @override_admin_id, "attempted override")

    assert fetch_state!(mid) == :released
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_infected_override") == []
  end

  # ── Acceptance Test 9 (AC1) — table-driven over every non-infected state ─

  test "admin_override_infected/3 against a :quarantined, :scanning, :admin_blocked, :deleted, " <>
         ":scan_failed, :reserved, or :hard_deleted file returns " <>
         "{:error, {:invalid_transition, from, :released}} for each and writes nothing" do
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    for from_state <- [
          :quarantined,
          :scanning,
          :admin_blocked,
          :deleted,
          :scan_failed,
          :reserved,
          :hard_deleted
        ] do
      mid = media_id("override_invalid_from_#{from_state}")
      insert_media_file!(mid, from_state)
      on_exit(fn -> cleanup!(mid) end)

      assert {:error, {:invalid_transition, ^from_state, :released}} =
               Media.admin_override_infected(mid, @override_admin_id, "attempted override")

      assert fetch_state!(mid) == from_state
      assert fetch_transitions!(mid) == []
      assert fetch_audit_rows!(mid, "media_infected_override") == []
    end
  end

  # ── Acceptance Test 10 (AC1) — direct guard-table assertion ─────────────
  #
  # See also state_machine_test.exs's own @full_guard_table update for this
  # story — the generic table-driven allowed?/2/allowed_transitions/1 test
  # there now covers this edge too. This standalone assertion is kept in
  # addition, per the story's own Acceptance Tests list, as an obvious,
  # narrowly-scoped regression guard.

  test "Nebu.Media.StateMachine.allowed?(:infected, :released) is true and " <>
         "allowed?(:infected, :deleted) remains true" do
    assert Nebu.Media.StateMachine.allowed?(:infected, :released)
    assert Nebu.Media.StateMachine.allowed?(:infected, :deleted)
  end

  # ── Acceptance Test 11 (AC6) — forbidden without the grant ──────────────

  test "admin_override_infected/3 called by an admin lacking the media_admin_override grant " <>
         "returns {:error, :forbidden} and writes nothing, even against a genuinely :infected " <>
         "file with a valid reason" do
    mid = media_id("override_forbidden")
    insert_infected_file!(mid)
    insert_admin_without_grant!(@no_grant_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@no_grant_admin_id) end)

    assert {:error, :forbidden} =
             Media.admin_override_infected(mid, @no_grant_admin_id, "a perfectly valid reason")

    assert fetch_state!(mid) == :infected
    assert fetch_transitions!(mid) == []
    assert fetch_audit_rows!(mid, "media_infected_override") == []
  end

  # ── Acceptance Test 12 (AC6) — positive control, paired with test 11 ────

  test "admin_override_infected/3 called by an admin holding the media_admin_override grant " <>
         "succeeds under otherwise-identical conditions" do
    mid = media_id("override_granted")
    insert_infected_file!(mid)
    grant_override_role!(@override_admin_id)
    on_exit(fn -> cleanup!(mid) end)
    on_exit(fn -> cleanup_user!(@override_admin_id) end)

    assert {:ok, :released} =
             Media.admin_override_infected(mid, @override_admin_id, "a perfectly valid reason")

    assert fetch_state!(mid) == :released
  end
end
