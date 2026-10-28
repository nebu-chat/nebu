defmodule Nebu.Workers.MediaReservedUploadCleanupWorkerTest do
  use ExUnit.Case, async: false

  # the agents are linked to the test process: when the on_exit callback runs they may already be shutting down (a race that made the unit job flaky)
  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  catch
    :exit, _ -> :ok
  end
  use Oban.Testing, repo: Nebu.Repo

  # media_reserved_upload_cleanup_worker_test.exs — Story
  # media-security-admin-control/2e-reserved-upload-cleanup-cron — RED-phase tests.
  #
  # ALL tests in this module are expected to FAIL until
  # Nebu.Workers.MediaReservedUploadCleanupWorker is implemented.
  # Failing reason: `perform_job/2` (from `Oban.Testing`) builds a job via
  # `Oban.Testing.build_job/3`, which asserts
  # `Code.ensure_loaded?(Nebu.Workers.MediaReservedUploadCleanupWorker) and
  # implements_worker?(...)` BEFORE ever calling `perform/1` — see
  # `deps/oban/lib/oban/testing.ex` `assert_valid_worker/1`. Since the module
  # does not exist yet, every test below fails with an `ExUnit.AssertionError`
  # ("Expected worker to be a module that implements the Oban.Worker behaviour")
  # raised from inside `perform_job/2` itself — never reaching this test file's
  # own assertions. This requires no live Postgres/Nebu.Repo connection (the
  # failure happens purely via `Code.ensure_loaded?/1`), so this file is exercised
  # correctly by the plain `mix test` unit suite, no docker-compose stack needed.
  #
  # ## Corrected story assumptions baked into these tests (see story Dev Notes):
  #   - There is NO persisted `media_files.unused_expires_at` column. Expiry is
  #     derived live as `uploaded_at + unused_expires_ms() < now_ms`, reading the
  #     SAME app-env key `Nebu.Media` itself reads
  #     (`Application.get_env(:nebu_http, :media_unused_expires_ms, 86_400_000)`)
  #     — never a second/duplicate config key, never a SQL `WHERE
  #     unused_expires_at < NOW()` (media.ex:261/364-369/961-962).
  #   - `Nebu.Media.StateMachine.transition/4`'s real signature takes a 2-tuple
  #     actor (`{:system, nil}`), not keyword args — `transition(media_id,
  #     :hard_deleted, {:system, nil})`.
  #
  # ## Test-double seams this file assumes the eventual worker implementation
  # will read (mirroring the existing `Nebu.Media` app-env-seam convention —
  # see `defp db_module`/`defp state_machine_module` in `server/lib/nebu/media.ex`,
  # both under the `:nebu_http` namespace, NOT `:nebu`):
  #   - `Application.get_env(:nebu_http, :media_reserved_cleanup_repo_module, Nebu.Repo)`
  #     — resolves the module the worker calls `query!/2` on for its own
  #     candidate-row SELECT. Swapped for `FakeRepo` below.
  #   - `Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)`
  #     — the SAME seam key `Nebu.Media.state_machine_module/0` already reads, so
  #     a single `Application.put_env/3` call affects every module that needs a
  #     swappable StateMachine, not a second/parallel key. Swapped for
  #     `FakeStateMachine` below.
  #
  # ## Fakes
  #
  # `FakeRepo` and `FakeStateMachine` share a single mutable Agent-backed bucket
  # (registered as `:media_cleanup_test_bucket`) modeling the live
  # `media_files` rows the worker would see: `%{media_id => %{state: "reserved" |
  # "hard_deleted", uploaded_at: ms}}`. `FakeRepo.query!/2` always reflects the
  # CURRENT bucket contents (filtered to `state == "reserved"`) — this is what
  # makes test 3 (idempotent repeated runs) meaningful: once `FakeStateMachine`
  # transitions a row, the very next `query!/2` call genuinely stops returning it,
  # rather than a second in-memory-only guard faking that behavior.
  #
  # A second Agent (`:media_cleanup_test_overrides`) lets a single test force a
  # specific `{media_id, response}` for `FakeStateMachine.transition/4`,
  # independent of the bucket's own derived logic — this is what test 4 (race
  # condition) needs: the row must still look `:reserved` to `FakeRepo`'s SELECT
  # (a stale snapshot from before the race), while the transition call itself
  # gets rejected as if another process already flipped it first.
  #
  # Two more Agents record call logs for assertions:
  #   - `:media_cleanup_test_repo_calls` — every `{sql, params}` FakeRepo.query!/2
  #     received (test 5: only ever a SELECT, never UPDATE/DELETE).
  #   - `:media_cleanup_test_transition_calls` — every `{media_id, to_state, actor,
  #     metadata}` FakeStateMachine.transition/4 received (tests 1/3/4).

  alias Nebu.Workers.MediaReservedUploadCleanupWorker

  @bucket :media_cleanup_test_bucket
  @overrides :media_cleanup_test_overrides
  @repo_calls :media_cleanup_test_repo_calls
  @transition_calls :media_cleanup_test_transition_calls

  # ─── FakeRepo ──────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc """
    Test-private fake for the worker's own repo seam. Test-private.

    Mirrors the REAL SQL's `WHERE state = 'reserved' AND uploaded_at < $1` —
    the expiry threshold bind param is honored here too (code-review MAJOR
    fix: the worker now applies the expiry predicate in SQL, not by filtering
    in Elixir after an unfiltered LIMIT-1000 scan), so this fake stays a
    faithful stand-in for the query it replaces.
    """

    def query!(sql, [expiry_threshold_ms] = params) do
      Agent.update(Process.whereis(:media_cleanup_test_repo_calls), fn calls ->
        [{sql, params} | calls]
      end)

      rows =
        Process.whereis(:media_cleanup_test_bucket)
        |> Agent.get(& &1)
        |> Enum.filter(fn {_media_id, row} ->
          row.state == "reserved" and row.uploaded_at < expiry_threshold_ms
        end)
        |> Enum.map(fn {media_id, _row} -> [media_id] end)

      %{rows: rows}
    end
  end

  # ─── FakeStateMachine ──────────────────────────────────────────────────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine. Test-private."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_cleanup_test_transition_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      overrides = Agent.get(Process.whereis(:media_cleanup_test_overrides), & &1)

      case Map.fetch(overrides, media_id) do
        {:ok, forced_response} ->
          forced_response

        :error ->
          bucket = Process.whereis(:media_cleanup_test_bucket)

          case Agent.get(bucket, &Map.get(&1, media_id)) do
            %{state: "reserved"} = row ->
              Agent.update(bucket, &Map.put(&1, media_id, %{row | state: Atom.to_string(to_state)}))
              {:ok, to_state}

            %{state: current} ->
              {:error, {:invalid_transition, String.to_existing_atom(current), to_state}}

            nil ->
              {:error, :not_found}
          end
      end
    end
  end

  # ─── Setup / Teardown ──────────────────────────────────────────────────────

  # NOTE (fixed a real, empirically-observed flake): the four named Agents below
  # are started fresh per-test but were never explicitly stopped in on_exit.
  # Since Agent.start_link/2 links to the calling (test) process, a test that
  # raises (every RED-phase test here does, via Oban.Testing's
  # assert_valid_worker) crashes its own process non-normally, which DOES
  # propagate to kill the linked Agents — but that kill and the next test's
  # setup's re-registration of the same name are not synchronized, so the next
  # setup can occasionally race the still-terminating old Agent and fail with
  # `{:error, {:already_started, pid}}` (observed directly: 1/7 runs). Stopping
  # each Agent explicitly and synchronously via Agent.stop/1 in on_exit removes
  # the race — on_exit runs (and blocks until each Agent.stop/1 call returns)
  # before ExUnit proceeds to the next test's setup.
  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @bucket)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @overrides)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @repo_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_calls)

    Application.put_env(:nebu_http, :media_reserved_cleanup_repo_module, FakeRepo)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)

    on_exit(fn ->
      for name <- [@bucket, @overrides, @repo_calls, @transition_calls] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> stop_agent(pid)
        end
      end

      Application.delete_env(:nebu_http, :media_reserved_cleanup_repo_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_unused_expires_ms)
    end)

    :ok
  end

  defp seed_reserved(media_id, uploaded_at) do
    Agent.update(Process.whereis(@bucket), fn state ->
      Map.put(state, media_id, %{state: "reserved", uploaded_at: uploaded_at})
    end)
  end

  defp seed_override(media_id, response) do
    Agent.update(Process.whereis(@overrides), fn state ->
      Map.put(state, media_id, response)
    end)
  end

  defp transition_calls, do: Process.whereis(@transition_calls) |> Agent.get(&Enum.reverse/1)
  defp repo_calls, do: Process.whereis(@repo_calls) |> Agent.get(&Enum.reverse/1)

  defp now_ms, do: System.system_time(:millisecond)

  @default_ttl_ms 86_400_000

  # ─── Test 1 (AC3/AC5) — expired :reserved rows are transitioned ───────────

  test "expired :reserved rows are transitioned to :hard_deleted via the state machine" do
    expired_uploaded_at = now_ms() - @default_ttl_ms - 60_000

    seed_reserved("media-expired-1", expired_uploaded_at)
    seed_reserved("media-expired-2", expired_uploaded_at)

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})

    calls = transition_calls()

    assert length(calls) == 2,
           "expected exactly 2 transition/4 calls for 2 expired rows, got #{length(calls)}"

    assert Enum.any?(calls, fn {media_id, to_state, actor, _metadata} ->
             media_id == "media-expired-1" and to_state == :hard_deleted and actor == {:system, nil}
           end)

    assert Enum.any?(calls, fn {media_id, to_state, actor, _metadata} ->
             media_id == "media-expired-2" and to_state == :hard_deleted and actor == {:system, nil}
           end)
  end

  # ─── Test 2 (AC6) — non-expired :reserved rows are left untouched ─────────

  test "non-expired :reserved rows are left untouched" do
    recent_uploaded_at = now_ms() - 60_000

    seed_reserved("media-fresh-1", recent_uploaded_at)

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {media_id, _to, _actor, _meta} ->
             media_id == "media-fresh-1"
           end),
           "a non-expired :reserved row must never reach StateMachine.transition/4"
  end

  # ─── Test 3 (AC5) — idempotent under repeated runs ────────────────────────

  test "the job is idempotent under repeated runs" do
    expired_uploaded_at = now_ms() - @default_ttl_ms - 60_000

    seed_reserved("media-repeat-1", expired_uploaded_at)

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})
    assert length(transition_calls()) == 1

    # Second run: the bucket's row is now "hard_deleted" (FakeStateMachine mutated
    # it on the first run's successful transition), so FakeRepo's SELECT no
    # longer returns it at all — a well-behaved worker issues zero additional
    # transition/4 calls, not a second (redundant) one that would then get
    # rejected by the guard.
    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})

    assert length(transition_calls()) == 1,
           "a second run must not add any further transition/4 calls for an already-cleaned-up row"
  end

  # ─── Test 4 (AC5) — idempotent when two executions race on the same row ───

  test "the job is idempotent when two executions race on the same row" do
    expired_uploaded_at = now_ms() - @default_ttl_ms - 60_000

    seed_reserved("media-race-1", expired_uploaded_at)

    # Simulate: FakeRepo's SELECT still sees the row as :reserved (a snapshot
    # taken before the race), but by the time our transition/4 call actually
    # fires, another process has already won the race and moved it on —
    # FakeStateMachine (which would otherwise derive :ok from the bucket)
    # is forced to return the guard's real rejection shape instead.
    seed_override("media-race-1", {:error, {:invalid_transition, :hard_deleted, :hard_deleted}})

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{}),
           "a rejected transition (lost race) must be treated as a no-op, not surfaced as an error " <>
             "that would trigger an Oban retry"

    assert length(transition_calls()) == 1,
           "the worker must still have attempted the transition exactly once"
  end

  # ─── Test 5 (AC3) — no raw UPDATE/DELETE on media_files.state ─────────────

  test "cleanup never issues a raw UPDATE/DELETE on media_files.state" do
    expired_uploaded_at = now_ms() - @default_ttl_ms - 60_000

    seed_reserved("media-sql-check-1", expired_uploaded_at)

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})

    calls = repo_calls()

    assert length(calls) >= 1, "the worker must issue at least one SELECT via its repo seam"

    refute Enum.any?(calls, fn {sql, _params} -> String.match?(sql, ~r/\bUPDATE\b|\bDELETE\b/i) end),
           "the worker itself must never issue a raw UPDATE/DELETE against media_files — " <>
             "every state change must go through Nebu.Media.StateMachine.transition/4"

    assert Enum.all?(calls, fn {sql, _params} -> String.match?(sql, ~r/\bSELECT\b/i) end),
           "every SQL statement the worker's repo seam executes must be a SELECT"

    assert length(transition_calls()) == 1,
           "the one state change must be attributed to StateMachine.transition/4"
  end

  # ─── Test 6 (AC6, dedicated) — only the expiry formula matters, never cron
  #     cadence / elapsed wall-clock time since the row was created ──────────

  test "a row far older than the job's own cadence is still untouched if the TTL formula says it has not expired" do
    # Configure a TTL far longer than the default 24h (e.g. 30 days) — this
    # models an operator raising :media_unused_expires_ms, NOT a coincidence of
    # this job's own 15-minute cron cadence. The row is 10 days old (i.e. it has
    # survived roughly 960 fifteen-minute cron ticks) yet must still be excluded,
    # because `uploaded_at + unused_expires_ms() < now_ms` is false under this
    # config — proving elapsed ticks/wall-clock alone never drive the decision.
    thirty_days_ms = 30 * 24 * 60 * 60 * 1000
    ten_days_ago = now_ms() - 10 * 24 * 60 * 60 * 1000

    Application.put_env(:nebu_http, :media_unused_expires_ms, thirty_days_ms)

    seed_reserved("media-old-but-not-expired", ten_days_ago)

    assert :ok = perform_job(MediaReservedUploadCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {media_id, _to, _actor, _meta} ->
             media_id == "media-old-but-not-expired"
           end),
           "a row older than several cron cycles must still be left alone when the TTL formula " <>
             "itself says it has not expired — only uploaded_at + unused_expires_ms() < now_ms governs"
  end

  # ─── Test 7 (AC5, MAJOR-2 fix) — an UNEXPECTED transition failure must NOT be
  #     swallowed as a no-op the same way a rejected-race is ───────────────────
  #
  # AC5's no-op carve-out is specific: ONLY a rejected {:reserved -> :hard_deleted}
  # transition because another process already won the race
  # ({:error, {:invalid_transition, _, _}}) is a no-op. Any OTHER failure shape
  # (a genuine seam/DB error, a crash, an unexpected reason) must NOT be silently
  # treated as success — that would hide real failures from Oban's own
  # retry/visibility machinery. This test forces FakeStateMachine to return a
  # deliberately different error shape and asserts the worker does not report
  # blanket success for that row: it must either propagate the error (job-level
  # `{:error, _}`, letting Oban retry) or otherwise clearly not just swallow it
  # into `:ok` the same way test 4's genuine no-op does. A broad
  # `case ... do {:ok, _} -> :ok; _ -> :ok end` or a blanket `rescue _ -> :ok`
  # would pass tests 1-6 but must FAIL this one.

  test "an unexpected (non-invalid_transition) StateMachine failure is not silently swallowed as a no-op" do
    expired_uploaded_at = now_ms() - @default_ttl_ms - 60_000

    seed_reserved("media-unexpected-error-1", expired_uploaded_at)

    # A failure shape that is NOT the documented race no-op
    # ({:error, {:invalid_transition, _, _}}) — e.g. a DB/seam-level error the
    # real StateMachine.transition/4 could plausibly surface (connection error,
    # constraint violation, etc.). This must be treated as a genuine failure,
    # not as "someone else already handled it."
    seed_override("media-unexpected-error-1", {:error, :some_other_reason})

    result = perform_job(MediaReservedUploadCleanupWorker, %{})

    refute result == :ok,
           "an unexpected StateMachine failure (not {:error, {:invalid_transition, _, _}}) " <>
             "must not be reported as a plain :ok success — that would silently hide a real " <>
             "failure from Oban's retry/visibility machinery, indistinguishable from the " <>
             "legitimate race no-op in test 4"

    assert match?({:error, _}, result),
           "expected the job to propagate the unexpected failure as {:error, _} so Oban " <>
             "retries it, got: #{inspect(result)}"

    assert length(transition_calls()) == 1,
           "the worker must still have attempted the transition exactly once for this row"
  end
end
