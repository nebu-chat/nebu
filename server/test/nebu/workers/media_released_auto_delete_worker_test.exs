defmodule Nebu.Workers.MediaReleasedAutoDeleteWorkerTest do
  use ExUnit.Case, async: false

  # the agents are linked to the test process: when the on_exit callback runs they may already be shutting down (a race that made the unit job flaky)
  defp stop_agent(pid) do
    if Process.alive?(pid), do: Agent.stop(pid)
  catch
    :exit, _ -> :ok
  end
  use Oban.Testing, repo: Nebu.Repo

  # media_released_auto_delete_worker_test.exs — Story
  # media-security-admin-control/8d-released-auto-delete — RED-phase tests.
  #
  # ALL tests in this module are expected to FAIL until
  # Nebu.Workers.MediaReleasedAutoDeleteWorker is implemented — the SAME
  # Oban.Testing.assert_valid_worker/1 RED mechanism documented at the top of
  # media_cleanup_worker_test.exs (Story 8a) and media_archive_worker_test.exs
  # (Story 8c): `perform_job/2` calls `Oban.Testing.build_job/3`, which
  # asserts `Code.ensure_loaded?(Nebu.Workers.MediaReleasedAutoDeleteWorker)`
  # BEFORE ever calling `perform/1` — see `deps/oban/lib/oban/testing.ex`
  # `assert_valid_worker/1`. Since the module does not exist yet, every test
  # below fails with an `ExUnit.AssertionError` ("Expected worker to be a
  # module that implements the Oban.Worker behaviour") raised from inside
  # `perform_job/2` itself — never reaching this test file's own assertions.
  # This requires no live Postgres/Nebu.Repo connection (the failure happens
  # purely via `Code.ensure_loaded?/1`), so this file is exercised correctly
  # by the plain `mix test` unit suite, no docker-compose stack needed.
  #
  # ## Ground truth this file is built against (verified against the live
  # codebase, NOT the story markdown's own stale illustrative SQL/actor
  # strings — see the pipeline's ATDD task brief for the full citation list):
  #
  #   - `Nebu.Media.Config.get().released_delete_after_days` (Story 9a,
  #     ALREADY landed) is the config source — read via `Nebu.Media.Config`'s
  #     own test seam, `Application.get_env(:nebu_http, :media_config_source)`
  #     (a 0-arity fun returning a STRING-keyed override map, merged over
  #     config.exs-matching defaults by `Nebu.Media.Config.get/0` itself — see
  #     `server/lib/nebu/media/config.ex`). No app-env fallback path is
  #     exercised here; 9a already landed.
  #   - There is NO `released_at` column on `media_files` (confirmed against
  #     `server/priv/migrations/000001_init.up.sql` and 8a/8c's own
  #     moduledocs). Eligibility age is derived from the append-only
  #     `media_state_transitions` ledger, exactly mirroring
  #     `Nebu.Workers.MediaCleanupWorker`'s (8a) own
  #     `MAX(inserted_at) WHERE to_state = 'deleted'`/`'infected'` queries
  #     (`server/lib/nebu/workers/media_cleanup_worker.ex` lines ~92-107) —
  #     this file's `FakeRepo`/seed helpers mirror that worker's own
  #     `FakeRepo`/`seed_deleted`/`seed_infected` shape exactly, substituting
  #     `to_state = 'released'`.
  #   - `Nebu.Media.StateMachine.transition/4` signature:
  #     `transition(media_id, to_state, actor, metadata \\ %{})`. The
  #     `:released -> :deleted` edge already exists in the guard table
  #     (`server/lib/nebu/media/state_machine.ex`'s `@transitions` map:
  #     `released: [:admin_blocked, :deleted]`) — no guard-table change or
  #     test needed for that edge itself.
  #   - `Nebu.Compliance.AuditWriter.log/6` — `"media_released_auto_deleted"`
  #     is NOT yet in `@known_actions` (`server/lib/nebu/compliance/
  #     audit_writer.ex`) — adding it is part of THIS story's dev-story
  #     implementation, not this ATDD step. Test 6 below asserts it is
  #     missing today (RED) and will need it present to go GREEN later,
  #     mirroring 8a's/8c's own dedicated allowlist-membership test.
  #
  # ## Seams this file assumes the eventual worker implementation will read
  #
  #   - `Application.get_env(:nebu_http, :media_released_auto_delete_repo_module,
  #     Nebu.Repo)` — a NEW, worker-private seam (mirroring 8a's own
  #     `:media_cleanup_repo_module` convention — a private seam per worker
  #     that owns a single-purpose raw-SQL `query!/2` call, rather than 8c's
  #     shared `:media_db_module` convention, since this worker's eligibility
  #     query is a single ledger-derived `SELECT`, structurally identical to
  #     8a's `:deleted`/`:infected` queries, not 8c's `uploaded_at`-anchored
  #     one). Swapped for `FakeRepo` below. AC3/AC1 require this seam to see
  #     ZERO calls when the worker is disabled/refuses to run — the fake's
  #     own call-log Agent lets this file assert that directly.
  #   - `Application.get_env(:nebu_http, :media_state_machine_module,
  #     Nebu.Media.StateMachine)` — the SAME seam key `Nebu.Media`/8a/8c
  #     already read. Swapped for `FakeStateMachine` below.
  #   - `Application.get_env(:nebu_http, :media_audit_writer_module,
  #     Nebu.Compliance.AuditWriter)` — the SAME seam key `Nebu.Media`'s own
  #     `audit_writer/0` (6a/8a/8c) already reads. Swapped for
  #     `FakeAuditWriter` below.
  #   - `Application.get_env(:nebu_http, :media_config_source)` — `Nebu.Media.
  #     Config`'s OWN existing test seam (not a new one this story adds), a
  #     0-arity fun returning a STRING-keyed override map. Set explicitly per
  #     test below.
  #
  # ## Fakes
  #
  # `FakeRepo`/`FakeStateMachine`/`FakeAuditWriter` share a single mutable
  # Agent-backed bucket (`:media_released_auto_delete_test_bucket`) modeling
  # the live `media_files` rows the worker would see: `%{media_id =>
  # %{state:, storage_key:}}`.
  #
  # A second Agent (`:media_released_auto_delete_test_transition_log`) models
  # the append-only `media_state_transitions` ledger as a plain list of
  # `%{media_id:, from_state:, to_state:, actor:, metadata:, inserted_at:}`
  # maps (`inserted_at` a millisecond integer here, mirroring 8a's own fake's
  # convention) — this is what the released-candidates query derives its age
  # from (`MAX(inserted_at) WHERE to_state = 'released'`), exactly symmetric
  # with 8a's `:deleted`/`:infected` ledger-derived queries.
  #
  # Three more Agents record call logs for assertions:
  #   - `:media_released_auto_delete_test_repo_calls` — every `{sql, params}`
  #     FakeRepo saw (AC1/AC3: proves zero query beyond the config read when
  #     disabled or refusing to run).
  #   - `:media_released_auto_delete_test_transition_calls` — every
  #     `{media_id, to_state, actor, metadata}` FakeStateMachine.transition/4
  #     received.
  #   - `:media_released_auto_delete_test_audit_calls` — every
  #     `{actor_user_id, action, target_type, target_id, metadata, outcome}`
  #     FakeAuditWriter.log/6 received.
  #
  # A final Agent (`:media_released_auto_delete_test_transition_overrides`)
  # lets a test force `FakeStateMachine.transition/4` to return a specific
  # `{:error, reason}` for one particular `media_id`, independent of the
  # bucket's own default "released -> deleted always succeeds" behavior —
  # mirrors 8a's own `:media_cleanup_test_storage_overrides` convention
  # (`seed_storage_override/2` there, `seed_transition_override/2` here),
  # needed by the per-item failure-isolation test below (8a's own test 11
  # counterpart).

  alias Nebu.Workers.MediaReleasedAutoDeleteWorker

  @bucket :media_released_auto_delete_test_bucket
  @transition_log :media_released_auto_delete_test_transition_log
  @repo_calls :media_released_auto_delete_test_repo_calls
  @transition_calls :media_released_auto_delete_test_transition_calls
  @audit_calls :media_released_auto_delete_test_audit_calls
  @transition_overrides :media_released_auto_delete_test_transition_overrides

  @all_agents [
    @bucket,
    @transition_log,
    @repo_calls,
    @transition_calls,
    @audit_calls,
    @transition_overrides
  ]

  @day_ms 24 * 60 * 60 * 1000

  # ─── FakeRepo ──────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc """
    Test-private fake for the worker's own `:media_released_auto_delete_repo_module`
    seam. Test-private.

    Mirrors `Nebu.Workers.MediaCleanupWorkerTest.FakeRepo`'s
    `select_deleted_candidates/1`/`select_infected_candidates/1` shape exactly
    (media-security-admin-control/8a), substituting `to_state = 'released'`:
    every `query!/2` call is logged (so AC1/AC3 can assert zero calls), then
    routed to the released-candidates SELECT based on the SQL text containing
    `state = 'released'`.
    """

    def query!(sql, params) do
      Agent.update(Process.whereis(:media_released_auto_delete_test_repo_calls), fn calls ->
        [{sql, params} | calls]
      end)

      cond do
        String.match?(sql, ~r/state\s*=\s*'released'/i) ->
          [days] = params
          select_released_candidates(days)

        true ->
          raise "FakeRepo (MediaReleasedAutoDeleteWorkerTest): unrecognized SQL: #{sql}"
      end
    end

    defp bucket, do: Process.whereis(:media_released_auto_delete_test_bucket)
    defp transition_log, do: Process.whereis(:media_released_auto_delete_test_transition_log)

    defp select_released_candidates(days) do
      # Mirrors media_cleanup_worker.ex's own comment: Postgres resolves $1's
      # parameter type as `text` for `($1 || ' days')::interval` concatenation,
      # so the real worker binds the retention-days integer as a string — this
      # fake receives a string here too, just like the real Postgrex driver
      # would (see media_cleanup_worker_test.exs's identical convention).
      threshold = now_ms() - days_ms(String.to_integer(days))
      log = Agent.get(transition_log(), & &1)

      Agent.get(bucket(), & &1)
      |> Enum.filter(fn {media_id, row} ->
        row.state == "released" and released_age_ms(log, media_id) < threshold
      end)
      |> Enum.map(fn {media_id, _row} ->
        [media_id, released_inserted_at(log, media_id)]
      end)
      |> then(&%{rows: &1})
    end

    defp released_age_ms(log, media_id) do
      case released_inserted_at(log, media_id) do
        nil -> now_ms()
        ts -> ts
      end
    end

    defp released_inserted_at(log, media_id) do
      log
      |> Enum.filter(&(&1.media_id == media_id and &1.to_state == "released"))
      |> Enum.map(& &1.inserted_at)
      |> case do
        [] -> nil
        timestamps -> Enum.max(timestamps)
      end
    end

    defp now_ms, do: System.system_time(:millisecond)
    defp days_ms(n), do: n * 24 * 60 * 60 * 1000
  end

  # ─── FakeStateMachine ──────────────────────────────────────────────────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine.transition/4. Test-private."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_released_auto_delete_test_transition_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      overrides =
        Agent.get(Process.whereis(:media_released_auto_delete_test_transition_overrides), & &1)

      case Map.fetch(overrides, media_id) do
        {:ok, forced_response} ->
          # A forced failure: the call was logged above (it was attempted),
          # but — mirroring the real StateMachine.transition/4 contract on
          # error — the bucket row is left untouched and no ledger row is
          # appended, so this media_id must produce no state change and no
          # audit entry (see the per-item failure-isolation test below).
          forced_response

        :error ->
          bucket = Process.whereis(:media_released_auto_delete_test_bucket)

          case Agent.get(bucket, &Map.get(&1, media_id)) do
            %{state: "released"} = row when to_state == :deleted ->
              Agent.update(bucket, &Map.put(&1, media_id, %{row | state: "deleted"}))
              {:ok, :deleted}

            %{state: current} ->
              {:error, {:invalid_transition, String.to_existing_atom(current), to_state}}

            nil ->
              {:error, :not_found}
          end
      end
    end
  end

  # ─── FakeAuditWriter ───────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter.log/6. Test-private."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome) do
      Agent.update(Process.whereis(:media_released_auto_delete_test_audit_calls), fn calls ->
        [{actor_user_id, action, target_type, target_id, metadata, outcome} | calls]
      end)

      :ok
    end
  end

  # ─── Setup / Teardown ──────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @bucket)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_log)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @repo_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @transition_overrides)

    Application.put_env(:nebu_http, :media_released_auto_delete_repo_module, FakeRepo)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)
    # Default: disabled (nil), matching the shipped default (AC1/AC3). Tests
    # that need an active window override this explicitly.
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"released_delete_after_days" => nil}
    end)

    on_exit(fn ->
      for name <- @all_agents do
        case Process.whereis(name) do
          nil -> :ok
          pid -> stop_agent(pid)
        end
      end

      Application.delete_env(:nebu_http, :media_released_auto_delete_repo_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Application.delete_env(:nebu_http, :media_config_source)
    end)

    :ok
  end

  # ─── Seed / call-log helpers ───────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)
  defp days_ms(n), do: n * @day_ms

  defp put_config(value) do
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"released_delete_after_days" => value}
    end)
  end

  defp seed_released(media_id, released_at_ms, opts \\ %{}) do
    row = %{
      state: "released",
      storage_key: Map.get(opts, :storage_key, "storage-key-#{media_id}")
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))

    Agent.update(Process.whereis(@transition_log), fn log ->
      [
        %{
          media_id: media_id,
          from_state: "scanning",
          to_state: "released",
          actor: {:system, nil},
          metadata: %{},
          inserted_at: released_at_ms
        }
        | log
      ]
    end)
  end

  defp seed_transition_override(media_id, response) do
    Agent.update(Process.whereis(@transition_overrides), &Map.put(&1, media_id, response))
  end

  defp bucket_row(media_id), do: Agent.get(Process.whereis(@bucket), &Map.get(&1, media_id))
  defp repo_calls, do: Process.whereis(@repo_calls) |> Agent.get(&Enum.reverse/1)
  defp transition_calls, do: Process.whereis(@transition_calls) |> Agent.get(&Enum.reverse/1)
  defp audit_calls, do: Process.whereis(@audit_calls) |> Agent.get(&Enum.reverse/1)

  # ─── Test 1 (AC3) — disabled by default: nil is a total no-op ─────────────

  test "disabled by default: released_delete_after_days = nil is a no-op even with old " <>
         ":released files present" do
    media_id = "media-released-ancient-1"
    seed_released(media_id, now_ms() - days_ms(400))
    # config_source already defaults to nil in setup/0 — asserted explicitly
    # here for readability.
    put_config(nil)

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    assert repo_calls() == [],
           "AC3: a disabled worker must issue no query beyond reading the config value"

    assert transition_calls() == []
    assert audit_calls() == []

    assert bucket_row(media_id).state == "released"
  end

  # ─── Test 2 (AC2) — enabled with a window soft-deletes eligible files ─────

  test "enabled with a window correctly soft-deletes eligible files" do
    put_config(30)
    media_id = "media-released-eligible-1"
    seed_released(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    matching =
      Enum.filter(transition_calls(), fn {mid, to_state, actor, _meta} ->
        mid == media_id and to_state == :deleted and actor == {:system, nil}
      end)

    assert length(matching) == 1,
           "expected exactly one StateMachine.transition/4 call to :deleted for #{media_id}, " <>
             "got #{length(matching)}"

    assert bucket_row(media_id).state == "deleted"

    # This worker only ever soft-deletes (:released -> :deleted) via
    # StateMachine.transition/4 — hard-deletion (hard_deleted_at,
    # storage_key = NULL, state = 'hard_deleted') is exclusively
    # MediaCleanupWorker's (8a) job. Mirrors 8a's own test 14 idiom
    # (asserting directly against the recorded repo_calls() call log, not
    # merely relying on FakeRepo's incidental "unrecognized SQL" raise) —
    # made explicit here rather than left as a side effect of the fake's
    # own SQL-routing raise.
    refute Enum.any?(repo_calls(), fn {sql, _params} ->
             String.match?(sql, ~r/hard_deleted_at/i) or String.match?(sql, ~r/storage_key/i)
           end),
           "this worker must never issue a raw hard-delete write (hard_deleted_at/" <>
             "storage_key) itself, and must never invoke MediaCleanupWorker's own " <>
             "hard-delete logic directly — hard-deletion is exclusively MediaCleanupWorker's " <>
             "(8a) job, reached only via the normal :deleted-candidate query on a later run"
  end

  # ─── Test 2b (AC2, per-item failure isolation, mirrors 8a's own test 11) ──

  test "a StateMachine.transition/4 failure for one eligible file does not prevent " <>
         "another eligible file in the same run from being soft-deleted" do
    put_config(30)
    failing_media_id = "media-released-multi-fail-1"
    ok_media_id = "media-released-multi-ok-1"

    seed_released(failing_media_id, now_ms() - days_ms(31))
    seed_released(ok_media_id, now_ms() - days_ms(31))
    seed_transition_override(failing_media_id, {:error, :simulated_transition_failure})

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    assert Enum.any?(transition_calls(), fn {mid, to_state, _actor, _meta} ->
             mid == failing_media_id and to_state == :deleted
           end),
           "the failing file's transition must still have been attempted"

    assert bucket_row(failing_media_id).state == "released",
           "a failed StateMachine.transition/4 call must not leave the row mutated to " <>
             "deleted — the fake's forced error response never touches the bucket"

    refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == failing_media_id
           end),
           "no audit entry may be written for a file whose transition call failed"

    assert Enum.any?(transition_calls(), fn {mid, to_state, actor, _meta} ->
             mid == ok_media_id and to_state == :deleted and actor == {:system, nil}
           end),
           "the other eligible file's transition must still be attempted and succeed, " <>
             "unaffected by the first file's failure"

    assert bucket_row(ok_media_id).state == "deleted"

    assert Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == ok_media_id
           end),
           "the succeeding file must still produce its own audit entry despite the other " <>
             "file's failure in the same run"
  end

  # ─── Test 3 (AC2/AC3) — files younger than the window are untouched ──────

  test "files younger than the window (29 days old) are left untouched" do
    put_config(30)
    media_id = "media-released-fresh-1"
    seed_released(media_id, now_ms() - days_ms(29))

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end)
    assert bucket_row(media_id).state == "released"
  end

  # ─── Test 4 (AC2/AC3 boundary) — exactly-30-days is untouched (exclusive) ─

  test "a file exactly at the boundary (30 days old) is left untouched — inclusive/exclusive " <>
         "boundary consistent with Story 8a's deleted_days/infected_days semantics" do
    put_config(30)
    media_id = "media-released-boundary-1"
    seed_released(media_id, now_ms() - days_ms(30))

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end),
           "a file that is exactly released_delete_after_days old must not yet be eligible " <>
             "(strict '<' threshold, mirroring 8a's own deleted_days/infected_days boundary)"

    assert bucket_row(media_id).state == "released"
  end

  # ─── Test 5 (AC4) — exactly one audit entry, correct shape ───────────────

  test "each auto-deleted file writes exactly one media_released_auto_deleted audit_log " <>
         "entry with actor system, target_type media, and metadata containing the " <>
         "configured window" do
    put_config(30)
    media_id = "media-released-audit-shape-1"
    seed_released(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

    matching =
      Enum.filter(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
        tid == media_id
      end)

    assert length(matching) == 1,
           "expected exactly one audit entry for #{media_id}, got #{length(matching)}"

    [{actor_user_id, action, target_type, target_id, metadata, outcome}] = matching

    assert actor_user_id == "system:media_released_auto_delete_worker"
    assert action == "media_released_auto_deleted"
    assert target_type == "media"
    assert target_id == media_id
    assert outcome == "success"
    assert Map.get(metadata, :released_delete_after_days) == 30
    assert Map.get(metadata, :released_for_days) != nil
    assert Map.get(metadata, :released_for_days) >= 30
  end

  # ─── Test 6 (AC4, dedicated) — allowlist membership, independent of a run ─

  defmodule KnownActionsFakeRepo do
    @moduledoc "Minimal in-process fake so this standalone allowlist check needs no live DB."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert!(struct, _opts \\ []), do: struct
  end

  test "media_released_auto_deleted is present in AuditWriter.@known_actions" do
    Application.put_env(:compliance, :repo, KnownActionsFakeRepo)
    on_exit(fn -> Application.delete_env(:compliance, :repo) end)

    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_released_auto_delete_worker",
        "media_released_auto_deleted",
        "media",
        "media-known-actions-check-1",
        %{},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_released_auto_deleted" must be in AuditWriter.@known_actions, got #{inspect(result)}|
  end

  # ─── Test 7 (AC1) — a non-nil, non-positive-integer config value refuses to run ─

  # Covers 0, a negative integer, and a non-integer raw value (a float).
  #
  # A numeric STRING (e.g. "30") is deliberately NOT in this list: `put_config/1`
  # goes through `Nebu.Media.Config`'s real `:media_config_source` seam, which
  # still runs every value through `Config`'s own `build_catalog/1` ->
  # `coerce_value/2` (`server/lib/nebu/media/config.ex`) exactly like the real
  # DB-row path does — the test seam only bypasses `validate_value/2` (the
  # write-path guard), never `coerce_value/2` (the read-path coercion). Since
  # `coerce_value("released_delete_after_days", v)` has an `is_binary(v)` clause
  # that runs `String.to_integer/1`, a digit-only string like "30" is coerced to
  # the legitimate integer `30` before this worker ever sees it — it is not a
  # bad value at all, and asserting a no-op for it was testing a false premise.
  # `1.5` (a float) already covers "non-integer, not coerced by Config, must be
  # rejected" — the genuine case AC1 cares about.
  test "a non-nil, non-positive-integer or non-integer config value does not run as an " <>
         "active window — worker logs and no-ops rather than treating it as " <>
         "delete-immediately" do
    for bad_value <- [0, -5, 1.5] do
      put_config(bad_value)

      media_id = "media-released-invalid-config-#{inspect(bad_value)}"
      seed_released(media_id, now_ms() - days_ms(400))

      assert :ok = perform_job(MediaReleasedAutoDeleteWorker, %{})

      assert repo_calls() == [],
             "config value #{inspect(bad_value)} must not be treated as an active window — " <>
               "expected zero query beyond the config read, got #{inspect(repo_calls())}"

      refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end),
             "config value #{inspect(bad_value)} must never cause a StateMachine.transition/4 " <>
               "call — 0/negative must not be read as 'delete immediately'"

      refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
               tid == media_id
             end)

      assert bucket_row(media_id).state == "released"
    end
  end
end
