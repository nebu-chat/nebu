defmodule Nebu.Media.StateMachineTest do
  @moduledoc """
  RED-phase acceptance tests for `Nebu.Media.StateMachine`
  (media-security-admin-control/1b-state-machine-module, AC1-AC5, AC7).

  `Nebu.Media.StateMachine` does not exist yet — every test below is
  expected to fail with `** (UndefinedFunctionError)` (calling an
  undefined `Nebu.Media.StateMachine.transition/4`, `.allowed?/2`, or
  `.allowed_transitions/1`) until the dev-story implements
  `server/lib/nebu/media/state_machine.ex`. This is the valid RED state for
  this story.

  Requires a live `Nebu.Repo` connection against a database migrated with
  Story 1a's `000022_media_state_machine_foundation` (the `media_state`
  ENUM, `media_files.state`, and the append-only `media_state_transitions`
  table must already exist) — run via `make test-integration` /
  `mix test --include integration`. Follows the SAME no-Sandbox convention
  already established by `media_state_transitions_immutability_test.exs`
  and `media_files_state_backfill_test.exs`: a real connection, unique
  per-run media ids, manual `on_exit` cleanup, `async: false`.

  `media_state_transitions` is append-only (ADR-031 — the
  `media_state_transitions_no_mutate` BEFORE UPDATE OR DELETE trigger,
  SQLSTATE 23001) even for the table owner, so cleanup here reuses the same
  `nebu_migrate`-role DISABLE/ENABLE TRIGGER dance documented in
  `media_state_transitions_immutability_test.exs`'s moduledoc, rather than a
  plain DELETE (which the trigger would reject).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.StateMachine
  alias Nebu.Repo

  # code-review MAJOR fix (M1, test-review-findings.md): the full 15-edge
  # guard table from the story's "Guard table" section (and the epic's
  # State Machine diagram), used to table-drive allowed_transitions/1 and
  # allowed?/2 coverage across all 8 states — not just :quarantined and
  # :hard_deleted as originally staged. :scanning's 4 outgoing edges are
  # the safety-critical malware-scan gate (a wrong edge here could let an
  # unscanned/infected file reach :released) and previously had zero
  # coverage.
  #
  # test-review MAJOR-1 fix (media-security-admin-control/
  # 2e-reserved-upload-cleanup-cron): added the `:reserved -> :hard_deleted`
  # edge AC4 introduces (the reserved-upload cleanup cron's own transition,
  # distinct from the regular `:reserved -> :quarantined` edge the PUT
  # handler/2b uses). `server/lib/nebu/media/state_machine.ex`'s real
  # `@transitions` map does NOT have this edge yet (still `reserved:
  # [:quarantined]` only, 2e's own scope, not yet implemented) — so this
  # table-driven test is now RED for the `:reserved` case specifically until
  # dev-story adds it there, at which point it goes GREEN. Every other state's
  # edges are untouched and must stay green throughout.
  # media-security-admin-control/4a-scan-failed-enum-migration (AC3/AC4): adds
  # the :scan_failed key plus the :quarantined -> :scan_failed and
  # :scanning -> :scan_failed edges. `server/lib/nebu/media/state_machine.ex`'s
  # real `@transitions` map does NOT have :scan_failed yet (this story's own
  # scope, not yet implemented) — so this table-driven test is RED for
  # :quarantined, :scanning, and the new :scan_failed key specifically until
  # dev-story adds them, at which point it goes GREEN. Every other state's
  # edges are untouched and must stay green throughout.
  #
  # media-security-admin-control/6c-infected-override (AC1, Acceptance Test
  # 10): adds the :infected -> :released edge (the deliberate, narrowly-gated
  # false-positive override). `server/lib/nebu/media/state_machine.ex`'s real
  # `@transitions` map still has `infected: [:deleted]` only — so this
  # table-driven test is RED for the :infected key specifically (both the
  # allowed_transitions/1 equality check and the `allowed?(:infected,
  # :released)` positive-edge check below) until dev-story extends it to
  # `infected: [:deleted, :released]`. The pre-existing `infected -> deleted`
  # edge must stay green throughout — this story is additive only.
  # media-security-admin-control/8a-media-cleanup-worker (AC4, Acceptance Test
  # 3): adds the infected -> :hard_deleted edge (the retention cron's own
  # terminal transition for aged :infected rows) to this shared table so the
  # exhaustive table-driven test below stays in sync with the real
  # @transitions map -- mirrors the same table-maintenance discipline every
  # prior edge addition above already followed. The pre-existing
  # infected -> :deleted / infected -> :released edges are unchanged.
  @full_guard_table %{
    reserved: [:quarantined, :hard_deleted],
    quarantined: [:scanning, :admin_blocked, :deleted, :scan_failed],
    scanning: [:released, :infected, :quarantined, :admin_blocked, :scan_failed],
    released: [:admin_blocked, :deleted],
    infected: [:deleted, :released, :hard_deleted],
    admin_blocked: [:released, :deleted],
    deleted: [:hard_deleted],
    hard_deleted: [],
    scan_failed: [:scanning, :released, :admin_blocked, :deleted]
  }

  @all_states Map.keys(@full_guard_table)

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "sm_#{@run_id}_#{suffix}"

  defp insert_media_file!(media_id, state) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state)
      VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
              '@tester:test.local', $2, false, $3)
      """,
      [media_id, System.system_time(:millisecond), Atom.to_string(state)]
    )
  end

  defp fetch_state!(media_id) do
    %Postgrex.Result{rows: [[state]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT state FROM media_files WHERE media_id = $1",
        [media_id]
      )

    String.to_existing_atom(state)
  end

  defp fetch_transitions!(media_id) do
    %Postgrex.Result{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT from_state, to_state, actor_type, actor_id, metadata, inserted_at
        FROM media_state_transitions
        WHERE media_id = $1
        ORDER BY id
        """,
        [media_id]
      )

    rows
  end

  # nebu_migrate is the actual table owner in this project's dual-role
  # docker-compose deployment (see media_state_transitions_immutability_test.exs's
  # moduledoc) — only the owner can DISABLE/ENABLE the append-only trigger
  # without full Postgres superuser, which is needed here purely for test
  # teardown (the trigger otherwise rejects the DELETE with SQLSTATE 23001
  # for every role, including the owner, per ADR-031).
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
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    :ok
  end

  # --- AC3: valid transition writes state + exactly one audit row ---------

  test "transition/4 with a valid edge (quarantined -> scanning) updates media_files.state" do
    mid = media_id("valid_edge")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scanning} = StateMachine.transition(mid, :scanning, {:system, nil}, %{})
    assert fetch_state!(mid) == :scanning
  end

  test "transition/4 with a valid edge writes exactly one media_state_transitions row " <>
         "with from_state, to_state, actor_type, actor_id, metadata, inserted_at" do
    mid = media_id("valid_edge_row")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scanning} =
             StateMachine.transition(mid, :scanning, {:system, nil}, %{"note" => "picked up"})

    assert [[from_state, to_state, actor_type, actor_id, metadata, inserted_at]] =
             fetch_transitions!(mid)

    assert from_state == "quarantined"
    assert to_state == "scanning"
    assert actor_type == "system"
    assert actor_id == nil
    assert metadata == %{"note" => "picked up"}
    assert %DateTime{} = inserted_at
  end

  # media-security-admin-control/2e-reserved-upload-cleanup-cron (code-review
  # CRITICAL fix, 2026-07-14): a real-DB round trip for the reserved ->
  # hard_deleted edge. This is the ONE thing the worker's own unit tests
  # (which swap in a hand-rolled FakeStateMachine) structurally cannot cover
  # — they never touch the real write_transition/6 SQL at all. Without this
  # test, a NOT NULL violation on media_files.uploader_user_id (the column
  # was TEXT NOT NULL since 000001_init.up.sql; migration 000027 drops that
  # constraint specifically so this transition can NULL it) went completely
  # undetected by the full test suite despite the worker "working" against
  # every fake. This test seeds a genuine :reserved row via the same
  # insert_media_file!/2 helper the rest of this file uses, transitions it
  # for real, and asserts both the epic's DB-Record-Invariante columns AND
  # that the row itself still exists (never physically deleted).
  test "transition/4 (reserved -> hard_deleted) nulls uploader_user_id and " <>
         "stamps hard_deleted_at, without deleting the row" do
    mid = media_id("reserved_hard_deleted")
    insert_media_file!(mid, :reserved)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :hard_deleted} = StateMachine.transition(mid, :hard_deleted, {:system, nil})
    assert fetch_state!(mid) == :hard_deleted

    %Postgrex.Result{rows: [[uploader_user_id, hard_deleted_at]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT uploader_user_id, hard_deleted_at FROM media_files WHERE media_id = $1",
        [mid]
      )

    assert uploader_user_id == nil,
           "hard_deleted must NULL uploader_user_id (epic DB-Record-Invariante)"

    assert %DateTime{} = hard_deleted_at,
           "hard_deleted must stamp hard_deleted_at"

    # The row itself is never physically deleted — only state and the two
    # columns above change.
    %Postgrex.Result{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM media_files WHERE media_id = $1",
        [mid]
      )

    assert count == 1, "the media_files row must still exist after hard_deleted"
  end

  # code-review MAJOR fix (M2, test-review-findings.md): fault-injection test
  # proving the UPDATE + INSERT pair is genuinely atomic (one
  # `Repo.transaction/1`), not just "both happen to succeed together" in
  # every scenario the other tests exercise. Postgres JSONB cannot store a
  # NUL byte (`<<0>>`) inside text — passing `metadata: %{"bad" => <<0>>}`
  # on an otherwise-valid edge (quarantined -> scanning) is guaranteed to
  # fail specifically the `media_state_transitions` INSERT (the second
  # write), which per the Technical Requirements flow runs AFTER the
  # `media_files.state` UPDATE (the first write) inside the same
  # `Repo.transaction/1` call. A naive non-atomic implementation (separate
  # UPDATE then separate INSERT, no real transaction) would leave the
  # UPDATE committed even though the INSERT failed; a true
  # `Repo.transaction/1` rolls both back. The assertion on
  # `fetch_state!(mid) == :quarantined` afterward is the crux: it is the
  # one thing that can distinguish "atomic" from "sequential".
  #
  # Contract choice (documented per the task's request): we do not assume
  # whether `transition/4` surfaces this failure as a raised exception or
  # as an `{:error, reason}` return — `Repo.transaction/1` re-raises
  # whatever the fun raised inside it unless the implementation explicitly
  # rescues and converts it, and the story's Technical Requirements only
  # promise conversion for the DOCUMENTED reasons
  # (`:not_found`/`:invalid_transition`), not for an underlying Postgrex
  # error. So this test treats EITHER a raised exception OR any non-`{:ok,
  # _}` return as acceptable "the call did not succeed" evidence, and
  # relies on the DB-state assertions (not the return shape) as the actual
  # proof of atomicity.
  test "transition/4 rolls back the media_files.state UPDATE when the audit-row " <>
         "INSERT fails mid-transaction (AC3 atomicity fault-injection)" do
    mid = media_id("atomicity_fault")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    bad_metadata = %{"bad" => <<0>>}

    # Deliberately does NOT swallow UndefinedFunctionError: while
    # `Nebu.Media.StateMachine` doesn't exist yet, this call must fail the
    # same way every other test in this file does (loud RED,
    # UndefinedFunctionError), not pass vacuously just because *some*
    # exception was raised. Once implemented, the induced NUL-byte failure
    # is expected to surface as a genuine DB-layer error (e.g.
    # `Postgrex.Error`/`DBConnection` encode error, or a `MatchError` if the
    # implementation pattern-matches `{:ok, _}` on the INSERT result) —
    # that is the exception this rescue clause is actually meant to catch.
    result =
      try do
        StateMachine.transition(mid, :scanning, {:system, nil}, bad_metadata)
      rescue
        error in [UndefinedFunctionError] -> reraise(error, __STACKTRACE__)
        error -> {:raised, error}
      end

    refute match?({:ok, _}, result)

    # The crux of this test: if the UPDATE and INSERT were NOT wrapped in a
    # real transaction, the UPDATE (state -> :scanning) would have already
    # committed before the doomed INSERT ran. Asserting the state is still
    # :quarantined proves the UPDATE was rolled back alongside the INSERT
    # failure, not just "both usually succeed together".
    assert fetch_state!(mid) == :quarantined
    assert fetch_transitions!(mid) == []
  end

  # --- AC4: invalid transitions rejected before any write ------------------

  test "transition/4 with an invalid edge (reserved -> released) returns " <>
         "{:error, {:invalid_transition, :reserved, :released}}" do
    mid = media_id("invalid_edge")
    insert_media_file!(mid, :reserved)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :reserved, :released}} =
             StateMachine.transition(mid, :released, {:system, nil}, %{})
  end

  test "transition/4 with an invalid edge leaves media_files.state unchanged" do
    mid = media_id("invalid_edge_unchanged")
    insert_media_file!(mid, :reserved)
    on_exit(fn -> cleanup!(mid) end)

    _ = StateMachine.transition(mid, :released, {:system, nil}, %{})

    assert fetch_state!(mid) == :reserved
  end

  test "transition/4 with an invalid edge writes no media_state_transitions row" do
    mid = media_id("invalid_edge_no_row")
    insert_media_file!(mid, :reserved)
    on_exit(fn -> cleanup!(mid) end)

    _ = StateMachine.transition(mid, :released, {:system, nil}, %{})

    assert fetch_transitions!(mid) == []
  end

  # --- AC5: actor_id NULL for system, rejected for spurious system actor ---

  test "transition/4 with actor {:system, nil} persists actor_id as SQL NULL" do
    mid = media_id("actor_system")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scanning} = StateMachine.transition(mid, :scanning, {:system, nil}, %{})

    assert [[_from_state, _to_state, "system", nil, _metadata, _inserted_at]] =
             fetch_transitions!(mid)
  end

  test "transition/4 with actor {:system, <non-nil id>} is rejected with " <>
         "{:error, :invalid_actor} and writes nothing" do
    mid = media_id("actor_system_invalid")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    bogus_id = Ecto.UUID.generate()

    assert {:error, :invalid_actor} =
             StateMachine.transition(mid, :scanning, {:system, bogus_id}, %{})

    assert fetch_state!(mid) == :quarantined
    assert fetch_transitions!(mid) == []
  end

  test "transition/4 with actor {:admin, nil} is rejected with " <>
         "{:error, :invalid_actor} and writes nothing" do
    mid = media_id("actor_admin_invalid")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, :invalid_actor} =
             StateMachine.transition(mid, :scanning, {:admin, nil}, %{})

    assert fetch_state!(mid) == :quarantined
    assert fetch_transitions!(mid) == []
  end

  test "transition/4 with actor {:admin, admin_user_id} persists actor_id as the given admin_user_id" do
    mid = media_id("actor_admin")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    # media-security-admin-control/6a-routine-state-actions (migration 000029):
    # actor_id is a plain TEXT column, the same Matrix-ID identity shape as
    # users.user_id/audit_log.actor_user_id — NOT a UUID. This app has no
    # UUID-shaped admin identity; a real admin session's id looks like this.
    admin_id = "@kai:test.local"

    assert {:ok, :scanning} = StateMachine.transition(mid, :scanning, {:admin, admin_id}, %{})

    assert [[_from_state, _to_state, "admin", actor_id, _metadata, _inserted_at]] =
             fetch_transitions!(mid)

    # actor_id is a plain TEXT column read via bare Ecto.Adapters.SQL.query (no
    # schema/cast per ADR-018) — comes back as the exact string that was
    # persisted, no UUID dump/load round-trip (migration 000029).
    assert actor_id == admin_id
  end

  # --- AC1/AC2: read-only guard-table helpers -------------------------------

  test "allowed_transitions/1 returns the full guard-table edge list for a given from_state" do
    # media-security-admin-control/4a-scan-failed-enum-migration (AC3): extends
    # :quarantined's edge list with :scan_failed (Oban discard/2 firing before
    # scanning truly started) — this test's expected list is updated to match,
    # the same maintenance the release_test.exs migration-count list needed.
    assert MapSet.new(StateMachine.allowed_transitions(:quarantined)) ==
             MapSet.new([:scanning, :admin_blocked, :deleted, :scan_failed])
  end

  # code-review MAJOR fix (M1, test-review-findings.md): table-driven test
  # over the FULL 14-edge guard table (all 8 states), not just :quarantined.
  # Asserts allowed_transitions/1 returns exactly the documented edge list
  # per state (no missing edge, no extra/typo'd edge) and that allowed?/2
  # agrees both for every documented edge (true) and for every non-edge
  # (false) — a typo in the guard map (e.g. an accidental
  # `scanning -> released` without going through the scan result, or a
  # dropped `scanning -> infected` edge) would fail this test.
  test "allowed_transitions/1 and allowed?/2 match the full guard table for every state" do
    for {from, expected_tos} <- @full_guard_table do
      actual_tos = StateMachine.allowed_transitions(from)

      assert MapSet.new(actual_tos) == MapSet.new(expected_tos),
             "allowed_transitions(#{inspect(from)}) was #{inspect(actual_tos)}, " <>
               "expected exactly #{inspect(expected_tos)}"

      for to <- expected_tos do
        assert StateMachine.allowed?(from, to),
               "expected allowed?(#{inspect(from)}, #{inspect(to)}) to be true (documented edge)"
      end

      for to <- @all_states -- expected_tos do
        refute StateMachine.allowed?(from, to),
               "expected allowed?(#{inspect(from)}, #{inspect(to)}) to be false (non-adjacent pair)"
      end
    end
  end

  # :scanning is the safety-critical malware-scan gate (4 outgoing edges
  # governing whether a possibly-malicious file can ever reach :released)
  # and previously had zero dedicated coverage — call out its edges
  # explicitly in addition to the table-driven test above so a regression
  # here fails with an obvious, scanning-specific message.
  test "allowed?/2 exercises all 4 :scanning edges (released, infected, quarantined retry, admin_blocked)" do
    assert StateMachine.allowed?(:scanning, :released)
    assert StateMachine.allowed?(:scanning, :infected)
    assert StateMachine.allowed?(:scanning, :quarantined)
    assert StateMachine.allowed?(:scanning, :admin_blocked)

    # :scanning must never be allowed to transition directly to :reserved,
    # :deleted, or :hard_deleted — those are not documented edges.
    refute StateMachine.allowed?(:scanning, :reserved)
    refute StateMachine.allowed?(:scanning, :deleted)
    refute StateMachine.allowed?(:scanning, :hard_deleted)
  end

  test "allowed?/2 returns false for hard_deleted -> anything (terminal state, no outgoing edges)" do
    for to_state <- @all_states do
      refute StateMachine.allowed?(:hard_deleted, to_state)
    end

    assert StateMachine.allowed_transitions(:hard_deleted) == []
  end

  # --- media-security-admin-control/4a-scan-failed-enum-migration (AC3/AC4) --
  #
  # `:scan_failed` is the 9th media_state value (this story's own migration,
  # server/priv/migrations/000028_media_scan_failed_state.up.sql) and these
  # tests exercise the guard-table edges into/out of it, both positive
  # (allowed) and negative (rejected). Requires the migration to have run
  # (real ENUM value) since transition/4 round-trips through the actual
  # `media_files.state` column.

  test "transition/4 allows quarantined -> scan_failed" do
    mid = media_id("scan_failed_from_quarantined")
    insert_media_file!(mid, :quarantined)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scan_failed} = StateMachine.transition(mid, :scan_failed, {:system, nil}, %{})
    assert fetch_state!(mid) == :scan_failed
  end

  test "transition/4 allows scanning -> scan_failed" do
    mid = media_id("scan_failed_from_scanning")
    insert_media_file!(mid, :scanning)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scan_failed} = StateMachine.transition(mid, :scan_failed, {:system, nil}, %{})
    assert fetch_state!(mid) == :scan_failed
  end

  test "transition/4 allows scan_failed -> scanning (retry)" do
    mid = media_id("scan_failed_retry_to_scanning")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :scanning} = StateMachine.transition(mid, :scanning, {:system, nil}, %{})
    assert fetch_state!(mid) == :scanning
  end

  test "transition/4 allows scan_failed -> released (admin manual clear)" do
    mid = media_id("scan_failed_to_released")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    admin_id = Ecto.UUID.generate()

    assert {:ok, :released} = StateMachine.transition(mid, :released, {:admin, admin_id}, %{})
    assert fetch_state!(mid) == :released
  end

  test "transition/4 allows scan_failed -> admin_blocked (admin manual block)" do
    mid = media_id("scan_failed_to_admin_blocked")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    admin_id = Ecto.UUID.generate()

    assert {:ok, :admin_blocked} =
             StateMachine.transition(mid, :admin_blocked, {:admin, admin_id}, %{})

    assert fetch_state!(mid) == :admin_blocked
  end

  test "transition/4 allows scan_failed -> deleted (retention/lifecycle parity)" do
    mid = media_id("scan_failed_to_deleted")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, :deleted} = StateMachine.transition(mid, :deleted, {:system, nil}, %{})
    assert fetch_state!(mid) == :deleted
  end

  test "transition/4 rejects released -> scan_failed as {:error, {:invalid_transition, :released, :scan_failed}}" do
    mid = media_id("scan_failed_rejects_from_released")
    insert_media_file!(mid, :released)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :released, :scan_failed}} =
             StateMachine.transition(mid, :scan_failed, {:system, nil}, %{})

    assert fetch_state!(mid) == :released
  end

  test "transition/4 rejects scan_failed -> infected as {:error, {:invalid_transition, :scan_failed, :infected}}" do
    mid = media_id("scan_failed_rejects_to_infected")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :scan_failed, :infected}} =
             StateMachine.transition(mid, :infected, {:system, nil}, %{})

    assert fetch_state!(mid) == :scan_failed
  end

  test "transition/4 rejects scan_failed -> hard_deleted directly as {:error, {:invalid_transition, :scan_failed, :hard_deleted}}" do
    mid = media_id("scan_failed_rejects_to_hard_deleted")
    insert_media_file!(mid, :scan_failed)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, {:invalid_transition, :scan_failed, :hard_deleted}} =
             StateMachine.transition(mid, :hard_deleted, {:system, nil}, %{})

    assert fetch_state!(mid) == :scan_failed
  end

  test "allowed_transitions(:scan_failed) returns exactly [:scanning, :released, :admin_blocked, :deleted]" do
    assert MapSet.new(StateMachine.allowed_transitions(:scan_failed)) ==
             MapSet.new([:scanning, :released, :admin_blocked, :deleted])
  end

  # --- not_found -------------------------------------------------------------

  test "transition/4 on a media_id that does not exist returns {:error, :not_found} and writes nothing" do
    mid = media_id("not_found")
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, :not_found} = StateMachine.transition(mid, :scanning, {:system, nil}, %{})
    assert fetch_transitions!(mid) == []
  end

  # --- genesis: create/1 (media-security-admin-control/2a-post-media-create) -
  #
  # `create/1` does not exist yet on this branch — every test below is
  # expected to fail with `** (UndefinedFunctionError)` until story 2a's
  # dev-story adds it. Unlike `transition/4` (already merged, Story 1b), this
  # is a NEW genesis entry point: it INSERTs a brand-new `media_files` row
  # (state: :reserved) plus its `media_state_transitions` audit row
  # (`from_state: NULL, to_state: 'reserved', actor_type: 'system', actor_id:
  # NULL`) in one `Repo.transaction/1`, rather than transitioning an
  # already-existing row. Story 2a's own handler test
  # (`media_create_test.exs`) only asserts that its HTTP handler invokes this
  # seam correctly; the actual transition-row shape written by `create/1` is
  # this module's contract, asserted here.

  test "create/1 inserts a fresh media_files row in :reserved and writes a genesis " <>
         "media_state_transitions row (from_state: nil, to_state: :reserved, " <>
         "actor_type: :system, actor_id: nil)" do
    mid = media_id("genesis")
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, ^mid} =
             StateMachine.create(%{
               media_id: mid,
               server_name: "test.local",
               uploader_user_id: "@tester:test.local"
             })

    assert fetch_state!(mid) == :reserved

    assert [[from_state, to_state, actor_type, actor_id, _metadata, _inserted_at]] =
             fetch_transitions!(mid)

    assert from_state == nil
    assert to_state == "reserved"
    assert actor_type == "system"
    assert actor_id == nil
  end

  test "create/1 persists uploader_user_id on the media_files row (NOT as a " <>
         "media_state_transitions actor_id — that column stays admin-UUID-or-NULL only)" do
    mid = media_id("genesis_uploader")
    on_exit(fn -> cleanup!(mid) end)

    assert {:ok, ^mid} =
             StateMachine.create(%{
               media_id: mid,
               server_name: "test.local",
               uploader_user_id: "@tester:test.local"
             })

    %Postgrex.Result{rows: [[uploader_user_id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT uploader_user_id FROM media_files WHERE media_id = $1",
        [mid]
      )

    assert uploader_user_id == "@tester:test.local"

    assert [[_from_state, _to_state, _actor_type, actor_id, _metadata, _inserted_at]] =
             fetch_transitions!(mid)

    assert actor_id == nil
  end

  test "create/1 on a media_id that already exists returns {:error, :media_id_taken} " <>
         "and writes no additional media_state_transitions row" do
    mid = media_id("genesis_collision")
    insert_media_file!(mid, :reserved)
    on_exit(fn -> cleanup!(mid) end)

    assert {:error, :media_id_taken} =
             StateMachine.create(%{
               media_id: mid,
               server_name: "test.local",
               uploader_user_id: "@tester:test.local"
             })

    assert fetch_transitions!(mid) == []
  end

  # --- media-security-admin-control/8a-media-cleanup-worker (AC4, Acceptance
  # Test 3) — the new `infected -> hard_deleted` guard-table edge -----------
  #
  # A direct, standalone test of the new guard-table edge Story 8a adds,
  # independent of whether `Nebu.Workers.MediaCleanupWorker` itself is ever
  # exercised — proves the edge exists even if a future refactor of the
  # worker stops calling it directly. Confirmed via direct inspection of the
  # current `server/lib/nebu/media/state_machine.ex` `@transitions` map: it
  # still reads `infected: [:deleted, :released]` (the `:released` edge was
  # added by 6c-infected-override) — there is NO `:hard_deleted` entry yet, so
  # both assertions below are expected to FAIL (RED) until 8a's dev-story
  # extends the map to `infected: [:deleted, :released, :hard_deleted]`. Per
  # this story's own Dev Agent Guardrails, do NOT add the edge as part of
  # this ATDD step — the test failing now is exactly the point.
  test "allowed?(:infected, :hard_deleted) is true and allowed_transitions(:infected) " <>
         "includes :hard_deleted (media-security-admin-control/8a-media-cleanup-worker)" do
    assert StateMachine.allowed?(:infected, :hard_deleted),
           "expected allowed?(:infected, :hard_deleted) to be true — 8a's retention cron " <>
             "needs this edge to hard-delete aged :infected rows"

    assert :hard_deleted in StateMachine.allowed_transitions(:infected),
           "expected allowed_transitions(:infected) to include :hard_deleted, got " <>
             "#{inspect(StateMachine.allowed_transitions(:infected))}"
  end
end
