defmodule Nebu.Workers.MediaOrphanDetectionWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  import ExUnit.CaptureLog

  # media_orphan_detection_worker_test.exs — Story
  # media-security-admin-control/8b-orphan-detection-gdpr — RED-phase tests.
  #
  # ALL tests in this module are expected to FAIL until
  # Nebu.Workers.MediaOrphanDetectionWorker is implemented. Failing reason:
  # `perform_job/2` (from `Oban.Testing`) builds a job via
  # `Oban.Testing.build_job/3`, which asserts `Code.ensure_loaded?(...)  and
  # implements_worker?(...)` BEFORE ever calling `perform/1` — see
  # `deps/oban/lib/oban/testing.ex` `assert_valid_worker/1`. Since the module
  # does not exist yet, every test below fails with an `ExUnit.AssertionError`
  # ("Expected worker to be a module that implements the Oban.Worker
  # behaviour") raised from inside `perform_job/2` itself — never reaching
  # this test file's own assertions (mirrors the exact established red-phase
  # convention of this epic, see
  # media_reserved_upload_cleanup_worker_test.exs's own moduledoc). This
  # requires no live Postgres/Nebu.Repo connection for the worker-behavior
  # tests themselves (the failure happens purely via `Code.ensure_loaded?/1`),
  # so this file is exercised correctly by the plain `mix test` unit suite.
  # The dedicated allowlist test (Test 9 below) DOES use a live-DB-free fake
  # compliance repo (mirrors media_cleanup_worker_test.exs's own
  # `KnownActionsFakeRepo` precedent) and fails today for the SEPARATE,
  # already-real reason that `media_orphan_detection_run` is not yet in
  # `Nebu.Compliance.AuditWriter.@known_actions` — adding that allowlist
  # entry is dev-story's job, not this ATDD step's (mirrors 8a's own ATDD
  # step, which left `@known_actions` untouched and only added a failing
  # test pinning the gap).
  #
  # ## Story scope reminder (load-bearing, tested nowhere else but worth
  # restating): this worker is DETECTION/REPORTING ONLY. It must never call
  # `Nebu.Media.StateMachine.transition/3` (or `/4`) and must never mutate
  # `media_files.state` — see Test 5. It does not implement, and must never
  # be described anywhere as implementing, DSGVO/GDPR Art. 17 (the epic's own
  # Review 5 retracted that earlier framing; full Art. 17 is Story 13e,
  # out of scope here).
  #
  # ## Corrected story-text assumptions baked into these tests (see the
  # pipeline's own pre-dev codebase-verification notes for this story):
  #   - `media_files.uploaded_at` is a BIGINT millisecond-epoch column (NOT
  #     TIMESTAMPTZ) — confirmed against migration 000001. FakeRepo below
  #     therefore models the anti-join threshold as a plain millisecond
  #     integer comparison (`uploaded_at < threshold_ms`), never a Postgres
  #     `NOW() - interval` expression; the real worker's SQL must bind a
  #     precomputed `System.system_time(:millisecond) - orphaned_hours *
  #     3_600_000` value, mirroring the exact `unused_expires_ms()` pattern
  #     already used by `Nebu.Media`/`MediaReservedUploadCleanupWorker`.
  #   - `Nebu.Media.Config` (Story 9a) already exists with its own
  #     `orphaned_hours` DB-backed default (24) — per 9a's own moduledoc,
  #     this worker must NOT read from it; it keeps its own independent
  #     `config.exs` value (mirrors 8a's own `deleted_days`/`infected_days`
  #     precedent of an intentionally-separate, not-yet-rewired value).
  #   - `actor_user_id` is a REQUIRED `audit_log` field (see
  #     `Nebu.Compliance.AuditLogEntry.@required_fields`) — the story's own
  #     "actor_user_id: nil for a system-initiated run" phrasing is corrected
  #     here to the established `"system:<worker_name>"` convention already
  #     used by every other system-initiated worker in this epic
  #     (`media_cleanup_worker.ex`, `media_scan_worker.ex`, `media/config.ex`,
  #     `media/storage_config.ex`, `compliance/session_expiry_worker.ex`).
  #
  # ## Test-double seams this file assumes the eventual worker implementation
  # will read (mirroring the existing shared app-env-seam convention used by
  # every other worker in this epic, all under the `:nebu_http` namespace):
  #   - `Application.get_env(:nebu_http, :media_orphan_detection_repo_module, Nebu.Repo)`
  #     — resolves the module the worker calls `query!/2` on for its
  #     candidate-row SELECT. Swapped for `FakeRepo` below.
  #   - `Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)`
  #     — the SAME shared seam key every other worker in this epic already
  #     reads. Swapped for `FakeStateMachine` below so Test 5 can assert zero
  #     calls regardless of how many orphan candidates are found.
  #   - `Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)`
  #     — the SAME shared seam key `media_cleanup_worker.ex` already reads.
  #     Swapped for `FakeAuditWriter` below.
  #
  # ## Fakes
  #
  # `FakeRepo` simulates the real anti-join in Elixir over two Agent-backed
  # buckets: `:orphan_test_media_bucket` (the `media_files` fixture rows —
  # `%{media_id => %{state:, uploaded_at:, server_name:}}`) and
  # `:orphan_test_referenced_uris` (a `MapSet` of `"mxc://server/media_id"`
  # strings modeling ANY of `content.url` / `content.avatar_url` /
  # `content.info.thumbnail_url` referencing that file — the real SQL checks
  # these as 3 independent `OR`-ed JSONB containment clauses, but from this
  # unit-test fake's point of view only the observable outcome
  # ("referenced by at least one plaintext-reachable field, or not") matters;
  # the real per-field SQL correctness is a DB-level/integration concern, not
  # this fake's job to re-implement).
  #
  # `FakeAuditWriter` and `FakeStateMachine` each log every call into their
  # own Agent-backed bucket for assertions, mirroring
  # `media_reserved_upload_cleanup_worker_test.exs`'s established pattern.

  alias Nebu.Workers.MediaOrphanDetectionWorker

  @media_bucket :orphan_test_media_bucket
  @referenced_uris_bucket :orphan_test_referenced_uris
  @audit_calls_bucket :orphan_test_audit_calls
  @transition_calls_bucket :orphan_test_transition_calls

  @orphaned_hours 48
  @threshold_ms @orphaned_hours * 60 * 60 * 1000

  # ─── FakeRepo ──────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc """
    Test-private fake for the worker's own repo seam. Simulates the
    anti-join (`state = 'quarantined' AND uploaded_at < $threshold_ms AND NOT
    referenced`) entirely in Elixir over the two Agent-backed buckets set up
    by this test file. Test-private.
    """

    def query!(_sql, [threshold_ms]) do
      media_rows =
        Process.whereis(:orphan_test_media_bucket)
        |> Agent.get(& &1)

      referenced =
        Process.whereis(:orphan_test_referenced_uris)
        |> Agent.get(& &1)

      rows =
        media_rows
        |> Enum.filter(fn {media_id, row} ->
          row.state == "quarantined" and
            row.uploaded_at < threshold_ms and
            not MapSet.member?(referenced, "mxc://#{row.server_name}/#{media_id}")
        end)
        |> Enum.map(fn {media_id, row} -> [media_id, row.server_name, row.uploaded_at] end)

      %{rows: rows}
    end
  end

  # ─── FakeStateMachine ──────────────────────────────────────────────────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine. Test-private."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:orphan_test_transition_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      {:ok, to_state}
    end
  end

  # ─── FakeAuditWriter ────────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter. Test-private."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome, _error_detail \\ nil) do
      call = %{
        actor_user_id: actor_user_id,
        action: action,
        target_type: target_type,
        target_id: target_id,
        metadata: metadata,
        outcome: outcome
      }

      Agent.update(Process.whereis(:orphan_test_audit_calls), fn calls -> [call | calls] end)
      :ok
    end
  end

  # ─── Setup / Teardown ──────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @media_bucket)
    {:ok, _} = Agent.start_link(fn -> MapSet.new() end, name: @referenced_uris_bucket)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls_bucket)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_calls_bucket)

    Application.put_env(:nebu_http, :media_orphan_detection_repo_module, FakeRepo)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)

    on_exit(fn ->
      for name <- [@media_bucket, @referenced_uris_bucket, @audit_calls_bucket, @transition_calls_bucket] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
        end
      end

      Application.delete_env(:nebu_http, :media_orphan_detection_repo_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Logger.reset_metadata()
    end)

    :ok
  end

  defp seed_quarantined(media_id, uploaded_at, server_name \\ "test.local") do
    Agent.update(Process.whereis(@media_bucket), fn state ->
      Map.put(state, media_id, %{state: "quarantined", uploaded_at: uploaded_at, server_name: server_name})
    end)
  end

  defp mark_referenced(media_id, server_name \\ "test.local") do
    Agent.update(Process.whereis(@referenced_uris_bucket), fn set ->
      MapSet.put(set, "mxc://#{server_name}/#{media_id}")
    end)
  end

  defp audit_calls, do: Process.whereis(@audit_calls_bucket) |> Agent.get(&Enum.reverse/1)
  defp transition_calls, do: Process.whereis(@transition_calls_bucket) |> Agent.get(&Enum.reverse/1)

  defp now_ms, do: System.system_time(:millisecond)

  defp with_log_level(level, fun) do
    original_level = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original_level)
    end
  end

  # ─── Test 1 (AC1/AC2, story AT1) — unreferenced expired :quarantined row is
  #     detected and reported as an orphan candidate ──────────────────────────

  test "identifies an unreferenced :quarantined media_files row older than orphaned_hours as an orphan candidate" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-orphan-1", expired_uploaded_at)

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    calls = audit_calls()

    assert length(calls) == 1,
           "expected exactly 1 AuditWriter.log call for this run, got #{length(calls)}"

    [call] = calls

    assert call.action == "media_orphan_detection_run",
           "expected action=media_orphan_detection_run, got #{inspect(call.action)}"

    assert call.metadata["candidate_count"] == 1,
           "expected candidate_count=1, got #{inspect(call.metadata["candidate_count"])}"

    assert "media-orphan-1" in call.metadata["candidate_media_ids"],
           "expected media-orphan-1 to be listed in candidate_media_ids, got " <>
             inspect(call.metadata["candidate_media_ids"])
  end

  # ─── Test 2 (AC1, story AT2) — referenced via content.url is never a
  #     false-positive candidate ────────────────────────────────────────────

  test "excludes media referenced via content.url from candidates (no false positive)" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-referenced-url-1", expired_uploaded_at)
    mark_referenced("media-referenced-url-1")

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    [call] = audit_calls()

    assert call.metadata["candidate_count"] == 0,
           "a referenced row must never be counted as a candidate, got " <>
             inspect(call.metadata["candidate_count"])

    refute "media-referenced-url-1" in call.metadata["candidate_media_ids"],
           "media-referenced-url-1 must never appear in candidate_media_ids"
  end

  # ─── Test 3 (AC1, story AT3) — referenced via avatar_url or
  #     info.thumbnail_url is likewise never a false-positive candidate ──────

  test "excludes media referenced only via content.avatar_url or content.info.thumbnail_url from candidates" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-referenced-avatar-1", expired_uploaded_at)
    seed_quarantined("media-referenced-thumb-1", expired_uploaded_at)
    mark_referenced("media-referenced-avatar-1")
    mark_referenced("media-referenced-thumb-1")

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    [call] = audit_calls()

    assert call.metadata["candidate_count"] == 0,
           "both avatar_url- and thumbnail_url-referenced rows must be excluded, got " <>
             inspect(call.metadata["candidate_count"])

    refute "media-referenced-avatar-1" in call.metadata["candidate_media_ids"]
    refute "media-referenced-thumb-1" in call.metadata["candidate_media_ids"]
  end

  # ─── Test 4 (AC1, story AT4) — rows younger than orphaned_hours are
  #     excluded even when genuinely unreferenced ───────────────────────────

  test "excludes :quarantined rows younger than orphaned_hours even when unreferenced" do
    recent_uploaded_at = now_ms() - 60_000

    seed_quarantined("media-fresh-1", recent_uploaded_at)

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    [call] = audit_calls()

    assert call.metadata["candidate_count"] == 0,
           "a fresh (within-threshold) unreferenced row must never be selected as a candidate"

    refute "media-fresh-1" in call.metadata["candidate_media_ids"]
  end

  # ─── Test 5 (AC3/AC5, story AT5) — the job NEVER calls
  #     StateMachine.transition/3 (or /4), regardless of candidate count ─────

  test "the job never calls Nebu.Media.StateMachine.transition/3" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-no-mutation-1", expired_uploaded_at)
    seed_quarantined("media-no-mutation-2", expired_uploaded_at)
    seed_quarantined("media-no-mutation-3", expired_uploaded_at)

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    assert transition_calls() == [],
           "this detection-only worker must NEVER call StateMachine.transition/3 or /4 — " <>
             "found #{length(transition_calls())} call(s): #{inspect(transition_calls())}"
  end

  # ─── Test 6 (AC2, story AT6) — exactly ONE audit_log entry per run, never
  #     one per candidate ──────────────────────────────────────────────────

  test "writes exactly one audit_log entry per run, not one per candidate" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-batch-1", expired_uploaded_at)
    seed_quarantined("media-batch-2", expired_uploaded_at)
    seed_quarantined("media-batch-3", expired_uploaded_at)

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    calls = audit_calls()

    assert length(calls) == 1,
           "expected exactly ONE audit entry for a 3-candidate run, got #{length(calls)}"

    [call] = calls

    assert call.metadata["candidate_count"] == 3,
           "expected candidate_count=3, got #{inspect(call.metadata["candidate_count"])}"

    for media_id <- ["media-batch-1", "media-batch-2", "media-batch-3"] do
      assert media_id in call.metadata["candidate_media_ids"],
             "expected #{media_id} in candidate_media_ids, got " <>
               inspect(call.metadata["candidate_media_ids"])
    end
  end

  # ─── Test 7 (story AT7) — Logger.metadata(route_template: ...) set +
  #     summary Logger.info/1 call for Trace-Map visibility ─────────────────

  test "logs the run via Logger with route_template metadata for Trace-Map visibility" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-logged-1", expired_uploaded_at)

    log_output =
      with_log_level(:info, fn ->
        capture_log(fn ->
          assert :ok = perform_job(MediaOrphanDetectionWorker, %{})
        end)
      end)

    assert Keyword.get(Logger.metadata(), :route_template) == "cron:media_orphan_detection",
           "expected Logger.metadata/0 to carry route_template: \"cron:media_orphan_detection\" " <>
             "after the run (perform_job/2 runs perform/1 synchronously in-process), got " <>
             inspect(Logger.metadata())

    assert String.contains?(log_output, "candidate_count"),
           "expected a summary Logger.info/1 call mentioning the run's candidate_count, got: " <>
             log_output
  end

  # ─── Test 8 (AC3, story AT8) — idempotent under repeated runs: two
  #     independent audit entries, same candidate_count/candidate_media_ids ─

  test "the job is idempotent under repeated runs (no duplicate/compounding side effects)" do
    expired_uploaded_at = now_ms() - @threshold_ms - 60_000

    seed_quarantined("media-repeat-1", expired_uploaded_at)

    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})
    assert :ok = perform_job(MediaOrphanDetectionWorker, %{})

    calls = audit_calls()

    assert length(calls) == 2,
           "two independent runs must produce two independent audit entries, got #{length(calls)}"

    for call <- calls do
      assert call.metadata["candidate_count"] == 1,
             "each run must independently report candidate_count=1 (never 0, never doubled), got " <>
               inspect(call.metadata["candidate_count"])

      assert "media-repeat-1" in call.metadata["candidate_media_ids"]
    end
  end

  # ─── Test 9 (Technical Requirements, dedicated) — allowlist membership,
  #     independent of the worker's own module existing yet ─────────────────
  #
  # Mirrors media_cleanup_worker_test.exs's own established
  # "media_hard_deleted is present in AuditWriter.@known_actions" pattern.
  # This is the SAME class of gotcha the story itself calls out: skipping the
  # `@known_actions` allowlist entry makes `AuditWriter.log/6` silently return
  # `{:error, :audit_unknown_action}` for every run, breaking the audit trail
  # for this job specifically. This test fails TODAY for that exact reason —
  # adding the allowlist entry is dev-story's job, not this ATDD step's.

  defmodule KnownActionsFakeRepo do
    @moduledoc "Minimal in-process fake so this standalone allowlist check needs no live DB."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert!(struct, _opts \\ []), do: struct
  end

  test "media_orphan_detection_run is present in AuditWriter.@known_actions" do
    Application.put_env(:compliance, :repo, KnownActionsFakeRepo)

    on_exit(fn -> Application.delete_env(:compliance, :repo) end)

    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_orphan_detection_worker",
        "media_orphan_detection_run",
        "media_orphan_detection",
        nil,
        %{},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_orphan_detection_run" must be in AuditWriter.@known_actions, got #{inspect(result)}|
  end
end
