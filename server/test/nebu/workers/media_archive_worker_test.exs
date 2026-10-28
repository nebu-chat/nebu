defmodule Nebu.Workers.MediaArchiveWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  # media_archive_worker_test.exs — Story
  # media-security-admin-control/8c-media-archive-worker — RED-phase tests.
  #
  # ALL tests in this module are expected to FAIL until
  # Nebu.Workers.MediaArchiveWorker is implemented — same
  # Oban.Testing.assert_valid_worker/1 RED mechanism (module not loaded, no
  # live DB needed) documented at the top of
  # media_cleanup_worker_test.exs (Story 8a) and
  # media_reserved_upload_cleanup_worker_test.exs (Story 2e).
  #
  # ## Seams this file assumes the eventual worker implementation will read
  #
  # Unlike 8a/2e (which each own a private `:media_*_repo_module` seam and
  # issue raw SQL directly against a FakeRepo), this worker follows the
  # `media-security-admin-control/4b-media-scan-worker` precedent instead: it
  # reads/writes `media_files` through the EXISTING `:media_db_module` seam
  # (`Nebu.Media.DB`, the same seam `Nebu.Media`'s own HTTP handlers use),
  # via two NEW functions this story adds there —
  # `candidates_for_archive/1` and `commit_archived/1` — per the story's own
  # Technical Requirements ("Nebu.Media.DB gains candidates_for_archive/1
  # ... a separate, additive function"). This test file's `FakeDB` is
  # test-private (not the shared `Nebu.Web.MediaFakes.DB`), mirroring 8a's
  # own test-private `FakeRepo` convention — this worker's candidate/commit
  # shape is specific enough to this story that a shared fake would only
  # accumulate one-off closures other stories don't need.
  #
  #   - `Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)`
  #     — swapped for `FakeDB` below.
  #   - `Application.get_env(:nebu_http, :media_storage_module,
  #     Nebu.Media.Storage)` — swapped for `FakeStorage` below. `delete/1`
  #     already exists on the real `Nebu.Media.Storage` (added by Story 8a) —
  #     this story's own new functions are `archive_bucket/0` and
  #     `put_object_copy/2`.
  #   - `Application.get_env(:nebu_http, :media_audit_writer_module,
  #     Nebu.Compliance.AuditWriter)` — swapped for `FakeAuditWriter` below.
  #   - `Application.get_env(:nebu, :media_archive, released_archive_after_days:
  #     nil, archive_delete_from_primary: false)` — AC1's config seam, set
  #     explicitly per test via `Application.put_env/3`.
  #
  # ## AC7/AC8/ADR-032 note on job-level failure propagation (AT8)
  #
  # Unlike 8a's worker (which rescue-wraps every candidate row so one row's
  # failure never blocks the rest of the tick and `perform/1` always returns
  # `:ok`), AT8 below requires `perform_job/2` to surface `{:error, _}` when a
  # row's S3 copy fails, so Oban actually retries the JOB (not a per-row
  # retry loop invented by this worker). This mirrors
  # `Nebu.Workers.MediaReservedUploadCleanupWorker`'s (Story 2e)
  # `Enum.reduce_while/3` halt-on-real-error convention, not 8a's
  # swallow-and-continue one — the two cited precedents deliberately differ
  # here and this story's own AT8 text picks 2e's shape.
  #
  # ## Fakes
  #
  # `FakeDB`/`FakeStorage`/`FakeAuditWriter` share a single mutable
  # Agent-backed bucket (`:media_archive_test_bucket`) modeling the live
  # `media_files` rows the worker would see:
  # `%{media_id => %{state:, uploaded_at:, archived_at:, storage_key:}}`
  # (`uploaded_at`/`archived_at` are millisecond integers here, not real
  # `DateTime`s — good enough to exercise the age-threshold comparison the
  # fake performs, mirroring `uploaded_at`'s real BIGINT-epoch-ms column
  # type, NOT a Postgres `TIMESTAMPTZ` — see `Nebu.Media.DB.candidates_for_
  # archive/1`'s own moduledoc for why the story's own literal
  # `NOW() - ($1 || ' days')::interval` SQL cannot work against the real
  # schema).
  #
  # Call-log Agents for assertions:
  #   - `:media_archive_test_copy_calls` — every `{storage_key, dest_bucket}`
  #     `FakeStorage.put_object_copy/2` received, in call order.
  #   - `:media_archive_test_delete_calls` — every `storage_key`
  #     `FakeStorage.delete/1` received, in call order.
  #   - `:media_archive_test_commit_calls` — every `media_id`
  #     `FakeDB.commit_archived/1` received, in call order.
  #   - `:media_archive_test_audit_calls` — every `{actor_user_id, action,
  #     target_type, target_id, metadata, outcome}` `FakeAuditWriter.log/6`
  #     received.
  #   - `:media_archive_test_event_log` — a single interleaved, ORDERED list
  #     of `{:copy, storage_key}` / `{:commit, media_id}` / `{:delete,
  #     storage_key}` tags across all three fakes — what AT9 uses to prove
  #     copy-then-commit-then-delete ordering, not just that all three
  #     eventually happened.

  alias Nebu.Workers.MediaArchiveWorker

  @bucket :media_archive_test_bucket
  @copy_calls :media_archive_test_copy_calls
  @delete_calls :media_archive_test_delete_calls
  @commit_calls :media_archive_test_commit_calls
  @audit_calls :media_archive_test_audit_calls
  @event_log :media_archive_test_event_log

  @all_agents [@bucket, @copy_calls, @delete_calls, @commit_calls, @audit_calls, @event_log]

  @archive_bucket "test-archive-bucket"
  @day_ms 24 * 60 * 60 * 1000

  # ─── FakeDB ────────────────────────────────────────────────────────────────

  defmodule FakeDB do
    @moduledoc "Test-private fake for the worker's own :media_db_module seam. Test-private."

    def candidates_for_archive(threshold_ms) do
      Agent.get(Process.whereis(:media_archive_test_bucket), & &1)
      |> Enum.filter(fn {_id, row} ->
        row.state == "released" and row.archived_at == nil and row.uploaded_at < threshold_ms
      end)
      |> Enum.map(fn {media_id, row} -> %{media_id: media_id, storage_key: row.storage_key} end)
    end

    def commit_archived(media_id) do
      Agent.update(Process.whereis(:media_archive_test_commit_calls), &[media_id | &1])

      case Application.get_env(:nebu_http, :media_archive_test_commit_fun) do
        nil ->
          Agent.get_and_update(Process.whereis(:media_archive_test_bucket), fn state ->
            case Map.get(state, media_id) do
              %{state: "released", archived_at: nil} = row ->
                Agent.update(Process.whereis(:media_archive_test_event_log), fn events ->
                  [{:commit, media_id} | events]
                end)

                {{:ok, :committed}, Map.put(state, media_id, %{row | archived_at: now_ms()})}

              _ ->
                {{:ok, :already_archived}, state}
            end
          end)

        fun ->
          fun.(media_id)
      end
    end

    defp now_ms, do: System.system_time(:millisecond)
  end

  # ─── FakeStorage ───────────────────────────────────────────────────────────

  defmodule FakeStorage do
    @moduledoc "Test-private fake for Nebu.Media.Storage's archive-related functions. Test-private."

    def archive_bucket, do: "test-archive-bucket"

    def put_object_copy(storage_key, dest_bucket) do
      Agent.update(Process.whereis(:media_archive_test_copy_calls), &[{storage_key, dest_bucket} | &1])

      Agent.update(Process.whereis(:media_archive_test_event_log), fn events ->
        [{:copy, storage_key} | events]
      end)

      fun = Application.get_env(:nebu_http, :media_archive_test_copy_fun)
      if fun, do: fun.(storage_key, dest_bucket), else: :ok
    end

    def delete(storage_key) do
      Agent.update(Process.whereis(:media_archive_test_delete_calls), &[storage_key | &1])

      Agent.update(Process.whereis(:media_archive_test_event_log), fn events ->
        [{:delete, storage_key} | events]
      end)

      :ok
    end
  end

  # ─── FakeAuditWriter ───────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter.log/6. Test-private."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome) do
      Agent.update(Process.whereis(:media_archive_test_audit_calls), fn calls ->
        [{actor_user_id, action, target_type, target_id, metadata, outcome} | calls]
      end)

      :ok
    end
  end

  # ─── FakeStateMachine (AT14 — never called) ───────────────────────────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake proving this worker never calls StateMachine.transition/3. Test-private."

    def transition(_media_id, _to_state, _actor) do
      raise "MediaArchiveWorker must never call StateMachine.transition/3 (AC9/AT14) — state never changes on archive"
    end
  end

  # ─── Setup / Teardown ──────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @bucket)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @copy_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @delete_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @commit_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @event_log)

    Application.put_env(:nebu_http, :media_db_module, FakeDB)
    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)

    Application.put_env(:nebu, :media_archive,
      released_archive_after_days: 90,
      archive_delete_from_primary: false
    )

    on_exit(fn ->
      for name <- @all_agents do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
        end
      end

      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_archive_test_copy_fun)
      Application.delete_env(:nebu_http, :media_archive_test_commit_fun)
      Application.delete_env(:nebu, :media_archive)
    end)

    :ok
  end

  # ─── Seed helpers ───────────────────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)
  defp days_ms(n), do: n * @day_ms

  defp seed(media_id, opts) do
    row = %{
      state: Map.get(opts, :state, "released"),
      uploaded_at: Map.fetch!(opts, :uploaded_at),
      archived_at: Map.get(opts, :archived_at, nil),
      storage_key: Map.get(opts, :storage_key, "storage-key-#{media_id}")
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))
  end

  defp bucket_row(media_id), do: Agent.get(Process.whereis(@bucket), &Map.get(&1, media_id))
  defp copy_calls, do: Process.whereis(@copy_calls) |> Agent.get(&Enum.reverse/1)
  defp delete_calls, do: Process.whereis(@delete_calls) |> Agent.get(&Enum.reverse/1)
  defp commit_calls, do: Process.whereis(@commit_calls) |> Agent.get(&Enum.reverse/1)
  defp audit_calls, do: Process.whereis(@audit_calls) |> Agent.get(&Enum.reverse/1)
  defp event_log, do: Process.whereis(@event_log) |> Agent.get(&Enum.reverse/1)

  # ─── Test 1 (AC1/AC5/AC7) — eligible :released row is copied and archived ─

  test "eligible :released files older than the threshold with archived_at IS NULL are " <>
         "copied to the archive bucket and archived_at is set" do
    media_id = "media-eligible-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    assert {"storage-key-#{media_id}", @archive_bucket} in copy_calls()
    assert media_id in commit_calls()

    row = bucket_row(media_id)
    assert row.archived_at != nil
  end

  # ─── Test 2 (AC2) — non-:released states are never selected, regardless of age

  test "files in any non-:released state are never selected, regardless of age" do
    non_released = [:infected, :reserved, :quarantined, :scanning, :admin_blocked, :deleted, :hard_deleted]

    for state <- non_released do
      media_id = "media-non-released-#{state}"
      seed(media_id, %{state: Atom.to_string(state), uploaded_at: now_ms() - days_ms(1000)})
    end

    assert :ok = perform_job(MediaArchiveWorker, %{})

    assert copy_calls() == []
    assert commit_calls() == []
  end

  # ─── Test 3 (AC4) — already-archived row is not re-copied ─────────────────

  test "a :released file with archived_at already set is not re-copied" do
    media_id = "media-already-archived-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100), archived_at: now_ms() - days_ms(50)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    refute Enum.any?(copy_calls(), fn {key, _bucket} -> key == "storage-key-#{media_id}" end)
    refute media_id in commit_calls()
  end

  # ─── Test 4 (AC1) — released_archive_after_days = nil disables the worker ─

  test "released_archive_after_days = nil disables the worker entirely" do
    Application.put_env(:nebu, :media_archive,
      released_archive_after_days: nil,
      archive_delete_from_primary: false
    )

    media_id = "media-disabled-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(1000)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    assert copy_calls() == []
    assert commit_calls() == []
    assert audit_calls() == []
  end

  # ─── Test 5 (AC6) — storage_key is unchanged after archiving ──────────────

  test "storage_key is unchanged after archiving; only archived_at changes" do
    media_id = "media-storage-key-stable-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})
    before_key = bucket_row(media_id).storage_key

    assert :ok = perform_job(MediaArchiveWorker, %{})

    after_row = bucket_row(media_id)
    assert after_row.storage_key == before_key
    assert after_row.archived_at != nil
  end

  # ─── Test 8 (AC7/ADR-032) — a failed copy never sets archived_at, job errors

  test "the copy-then-commit ordering never sets archived_at when the S3 copy fails" do
    media_id = "media-copy-fails-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    Application.put_env(:nebu_http, :media_archive_test_copy_fun, fn _key, _bucket ->
      {:error, :some_s3_error}
    end)

    assert {:error, _} = perform_job(MediaArchiveWorker, %{})

    refute media_id in commit_calls()
    row = bucket_row(media_id)
    assert row.archived_at == nil
  end

  # ─── Test 8b (AC7/AC9, security-review fix) — a commit DB failure never audits/deletes,
  # and propagates as a job error exactly like a copy failure ────────────────

  test "a commit_archived/1 DB failure after a successful copy never writes an audit " <>
         "entry or deletes the primary object, and propagates as a job error" do
    media_id = "media-commit-db-fails-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    Application.put_env(:nebu, :media_archive,
      released_archive_after_days: 90,
      archive_delete_from_primary: true
    )

    Application.put_env(:nebu_http, :media_archive_test_commit_fun, fn _media_id ->
      {:error, %{postgres: :simulated_connection_error}}
    end)

    assert {:error, _} = perform_job(MediaArchiveWorker, %{})

    row = bucket_row(media_id)
    assert row.archived_at == nil

    refute Enum.any?(audit_calls(), fn {_a, _act, _t, tid, _m, _o} -> tid == media_id end)
    assert delete_calls() == []
  end

  # ─── Test 9 (AC7 order) — delete only after archived_at commits ───────────

  test "archive_delete_from_primary: true deletes the primary object only after archived_at is committed" do
    Application.put_env(:nebu, :media_archive,
      released_archive_after_days: 90,
      archive_delete_from_primary: true
    )

    media_id = "media-delete-after-commit-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    events = event_log()
    storage_key = "storage-key-#{media_id}"

    copy_index = Enum.find_index(events, &(&1 == {:copy, storage_key}))
    commit_index = Enum.find_index(events, &(&1 == {:commit, media_id}))
    delete_index = Enum.find_index(events, &(&1 == {:delete, storage_key}))

    assert copy_index != nil
    assert commit_index != nil
    assert delete_index != nil
    assert copy_index < commit_index
    assert commit_index < delete_index
  end

  # ─── Test 10 (AC7) — default leaves the primary object in place ──────────

  test "archive_delete_from_primary: false (default) leaves the primary object in place" do
    media_id = "media-no-delete-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    assert delete_calls() == []
  end

  # ─── Test 11 (AC8) — idempotent under repeated runs ───────────────────────

  test "the job is idempotent under repeated runs" do
    media_id = "media-idempotent-repeat-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    assert :ok = perform_job(MediaArchiveWorker, %{})
    first_copy_count = length(copy_calls())
    first_commit_count = length(commit_calls())

    assert :ok = perform_job(MediaArchiveWorker, %{})

    assert length(copy_calls()) == first_copy_count
    assert length(commit_calls()) == first_commit_count
  end

  # ─── Test 12 (AC8) — idempotent when two executions race on the same row ─

  test "the job is idempotent when two executions race on the same row" do
    media_id = "media-race-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    Application.put_env(:nebu, :media_archive,
      released_archive_after_days: 90,
      archive_delete_from_primary: true
    )

    # Simulate a concurrent execution winning the commit race BETWEEN our own
    # candidate SELECT and our own commit_archived/1 call: the copy_fun side
    # effect (which the real worker calls first, per ADR-032 ordering) stands
    # in for "meanwhile, another execution already committed archived_at."
    Application.put_env(:nebu_http, :media_archive_test_copy_fun, fn _key, _bucket ->
      Agent.update(Process.whereis(:media_archive_test_bucket), fn state ->
        Map.update!(state, media_id, &%{&1 | archived_at: now_ms()})
      end)

      :ok
    end)

    assert :ok = perform_job(MediaArchiveWorker, %{})

    refute Enum.any?(audit_calls(), fn {_a, _act, _t, tid, _m, _o} -> tid == media_id end),
           "the losing execution must never emit an audit entry"

    assert delete_calls() == [],
           "the losing execution must never delete the primary object, even with " <>
             "archive_delete_from_primary: true"
  end

  # ─── Test 13 (AC9) — exactly one media_archived audit entry ──────────────

  test "a successful archive writes exactly one media_archived audit entry via " <>
         "Nebu.Compliance.AuditWriter" do
    media_id = "media-audit-shape-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    assert :ok = perform_job(MediaArchiveWorker, %{})

    matching = Enum.filter(audit_calls(), fn {_a, _act, _t, tid, _m, _o} -> tid == media_id end)
    assert length(matching) == 1

    [{actor_user_id, action, target_type, target_id, metadata, outcome}] = matching
    assert actor_user_id == "system:media_archive_worker"
    assert action == "media_archived"
    assert target_type == "media"
    assert target_id == media_id
    assert outcome == "success"
    assert Map.get(metadata, :archive_bucket) == @archive_bucket
  end

  # ─── Test 14 (AC9) — no StateMachine.transition call ──────────────────────

  test "no media_state_transitions row / StateMachine.transition call is issued for an " <>
         "archive action" do
    media_id = "media-no-transition-1"
    seed(media_id, %{uploaded_at: now_ms() - days_ms(100)})

    # FakeStateMachine.transition/3 raises if ever called (see moduledoc) —
    # a clean run proves this worker never reaches it.
    assert :ok = perform_job(MediaArchiveWorker, %{})

    row = bucket_row(media_id)
    assert row.archived_at != nil
  end

  # ─── Test 15 (AC9) — allowlist membership, independent of a real run ─────

  defmodule KnownActionsFakeRepo do
    @moduledoc "Minimal in-process fake so this standalone allowlist check needs no live DB."

    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert!(struct, _opts \\ []), do: struct
  end

  test "media_archived is present in Nebu.Compliance.AuditWriter's known-action allowlist" do
    Application.put_env(:compliance, :repo, KnownActionsFakeRepo)
    on_exit(fn -> Application.delete_env(:compliance, :repo) end)

    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_archive_worker",
        "media_archived",
        "media",
        "media-known-actions-check-1",
        %{},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_archived" must be in AuditWriter.@known_actions, got #{inspect(result)}|
  end

  # ─── Test 16 (AC10) — shared 02:00 UTC cron cadence, disjoint candidates ──

  test "shares the media_cleanup queue with Story 8a (same queue, disjoint candidate " <>
         "populations by construction)" do
    assert MediaArchiveWorker.__opts__()[:queue] == :media_cleanup
  end
end
