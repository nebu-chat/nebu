defmodule Nebu.Workers.MediaCleanupWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  # media_cleanup_worker_test.exs — Story
  # media-security-admin-control/8a-media-cleanup-worker — RED-phase tests.
  #
  # ALL tests in this module are expected to FAIL until
  # Nebu.Workers.MediaCleanupWorker is implemented. Failing reason:
  # `perform_job/2` (from `Oban.Testing`) builds a job via
  # `Oban.Testing.build_job/3`, which asserts
  # `Code.ensure_loaded?(Nebu.Workers.MediaCleanupWorker) and
  # implements_worker?(...)` BEFORE ever calling `perform/1` — see
  # `deps/oban/lib/oban/testing.ex` `assert_valid_worker/1`. Since the module
  # does not exist yet, every test below fails with an `ExUnit.AssertionError`
  # ("Expected worker to be a module that implements the Oban.Worker behaviour")
  # raised from inside `perform_job/2` itself — never reaching this test
  # file's own assertions. This requires no live Postgres/Nebu.Repo connection
  # (the failure happens purely via `Code.ensure_loaded?/1`), matching the
  # precedent this file follows exactly:
  # `server/test/nebu/workers/media_reserved_upload_cleanup_worker_test.exs`
  # (Story 2e). So this file is exercised correctly by the plain `mix test`
  # unit suite, no docker-compose stack needed.
  #
  # ## Seams this file assumes the eventual worker implementation will read
  # (mirroring the existing `Nebu.Media`/2e app-env-seam convention — all
  # under the `:nebu_http` namespace):
  #   - `Application.get_env(:nebu_http, :media_cleanup_repo_module, Nebu.Repo)`
  #     — resolves the module the worker calls `repo().query!(sql, params)` on
  #     for its own SELECTs (deleted candidates / infected candidates /
  #     completion-reaper candidates) AND its two direct non-`state` `UPDATE`s
  #     (AC5/AC7). A single seam, same 2-arg `query!/2` shape 2e's own
  #     `MediaReservedUploadCleanupWorker` already uses against its repo seam.
  #     Swapped for `FakeRepo` below.
  #   - `Application.get_env(:nebu_http, :media_state_machine_module,
  #     Nebu.Media.StateMachine)` — the SAME seam key `Nebu.Media`/2e already
  #     read, so a single `Application.put_env/3` affects every module that
  #     needs a swappable StateMachine. Swapped for `FakeStateMachine` below.
  #   - `Application.get_env(:nebu_http, :media_storage_module,
  #     Nebu.Media.Storage)` — the SAME seam key `Nebu.Media` itself reads for
  #     `get/1`/`put/2`; this story's new `delete/1` is called through the
  #     same seam. Swapped for `FakeStorage` below.
  #   - `Application.get_env(:nebu_http, :media_audit_writer_module,
  #     Nebu.Compliance.AuditWriter)` — the SAME seam key `Nebu.Media`'s own
  #     `audit_writer/0` (6a) already reads. Swapped for `FakeAuditWriter`
  #     below.
  #   - Retention config: since story media-cleanup-reads-media-config (follow-up
  #     du) `Nebu.Media.Config.retention_days/0` (the `media_config` table; the
  #     `:media_config_loader` seam below), NOT `Application.get_env(:nebu,
  #     :media_cleanup)` any more (that key is dead; a test pins that).
  #
  # ## Fakes
  #
  # `FakeRepo`/`FakeStateMachine`/`FakeStorage`/`FakeAuditWriter` share a
  # single mutable Agent-backed bucket (`:media_cleanup_test_bucket`) modeling
  # the live `media_files` rows the worker would see:
  # `%{media_id => %{state:, deleted_at:, storage_key:, uploader_user_id:,
  # hard_deleted_at:, file_hash:, file_size:}}` (`deleted_at`/`hard_deleted_at`
  # are millisecond integers here, not real `DateTime`s — good enough to
  # exercise the age-threshold comparisons the fake performs).
  #
  # A second Agent (`:media_cleanup_test_transition_log`) models the
  # append-only `media_state_transitions` ledger as a plain list of
  # `%{media_id:, from_state:, to_state:, actor:, metadata:, inserted_at:}`
  # maps — this is what the `:infected` candidate query derives its age from
  # (`MAX(inserted_at) WHERE to_state = 'infected'`), and what test 15 asserts
  # is never mutated except by `FakeStateMachine.transition/4`'s own append.
  #
  # A third Agent (`:media_cleanup_test_storage_overrides`) lets a test force
  # a specific `{storage_key, response}` for `FakeStorage.delete/1`
  # (`:ok` | `{:error, reason}` | `:raise`), independent of the bucket's own
  # default "always succeeds" behavior — needed by tests 10/11 (S3 failure
  # handling / per-row isolation).
  #
  # Four more Agents record call logs for assertions:
  #   - `:media_cleanup_test_repo_calls` — every `{sql, params}` FakeRepo saw
  #     (tests 14/15: SQL-shape invariants).
  #   - `:media_cleanup_test_transition_calls` — every `{media_id, to_state,
  #     actor, metadata}` FakeStateMachine.transition/4 received (tests 1/2/8).
  #   - `:media_cleanup_test_storage_calls` — every storage_key
  #     FakeStorage.delete/1 received, in call order (tests 1/2/8/11).
  #   - `:media_cleanup_test_audit_calls` — every `{actor_user_id, action,
  #     target_type, target_id, metadata, outcome}` FakeAuditWriter.log/6
  #     received (tests 12/5/6/7/10).
  #
  # A final Agent (`:media_cleanup_test_event_log`) records a single
  # interleaved, ORDERED list of `{:storage_delete, storage_key}` /
  # `{:null_update, media_id}` tags across FakeStorage and FakeRepo's
  # null-columns branch — this is what test 9 uses to prove delete-then-null
  # ordering (ADR-032), not just that both eventually happened.

  import ExUnit.CaptureLog

  alias Nebu.Workers.MediaCleanupWorker

  @bucket :media_cleanup_test_bucket
  @transition_log :media_cleanup_test_transition_log
  @storage_overrides :media_cleanup_test_storage_overrides
  @repo_calls :media_cleanup_test_repo_calls
  @transition_calls :media_cleanup_test_transition_calls
  @storage_calls :media_cleanup_test_storage_calls
  @audit_calls :media_cleanup_test_audit_calls
  @event_log :media_cleanup_test_event_log

  @all_agents [
    @bucket,
    @transition_log,
    @storage_overrides,
    @repo_calls,
    @transition_calls,
    @storage_calls,
    @audit_calls,
    @event_log
  ]

  # ─── FakeRepo ──────────────────────────────────────────────────────────────

  defmodule FakeRepo do
    @moduledoc """
    Test-private fake for the worker's own `:media_cleanup_repo_module` seam.
    Test-private.

    Routes on the SQL text itself (mirroring the loose-but-faithful matching
    2e's own `FakeRepo` already established) into one of five branches:
    non-state-columns UPDATE (AC7, matched first: contains `storage_key` AND
    `UPDATE`), the `hard_deleted_at` UPDATE (AC5), the `:infected` candidates
    SELECT (contains `to_state = 'infected'`), the `:deleted` candidates
    SELECT (contains `to_state = 'deleted'` — security-review fix, cycle 2:
    both the `:deleted` and `:infected` candidate queries now reference
    `media_state_transitions`, so routing must key off the `to_state` literal,
    not merely the table name), or — falling through — the completion/"reaper"
    candidates SELECT (`state = 'hard_deleted' AND storage_key IS NOT NULL`,
    AC8).
    """

    def query!(sql, params) do
      Agent.update(Process.whereis(:media_cleanup_test_repo_calls), fn calls ->
        [{sql, params} | calls]
      end)

      cond do
        String.match?(sql, ~r/^\s*UPDATE/i) and String.match?(sql, ~r/storage_key/i) ->
          [media_id] = params
          null_storage_columns(media_id)

        String.match?(sql, ~r/^\s*UPDATE/i) ->
          [media_id] = params
          set_hard_deleted_at(media_id)

        String.match?(sql, ~r/to_state\s*=\s*'infected'/i) ->
          [infected_days] = params
          select_infected_candidates(infected_days)

        String.match?(sql, ~r/to_state\s*=\s*'deleted'/i) ->
          [deleted_days] = params
          select_deleted_candidates(deleted_days)

        true ->
          select_completion_candidates()
      end
    end

    defp bucket, do: Process.whereis(:media_cleanup_test_bucket)
    defp transition_log, do: Process.whereis(:media_cleanup_test_transition_log)

    # security-review fix (cycle 2, F-1/MEDIUM): mirrors select_infected_candidates/1
    # below exactly — the real production query no longer reads deleted_at (never
    # populated by any code path; see media_cleanup_worker.ex's own comment), it
    # derives age from the media_state_transitions ledger's MAX(inserted_at)
    # WHERE to_state = 'deleted' instead. row.deleted_at is kept in the fake's
    # schema for shape-fidelity with the real (untouched, still-NULL-forever)
    # column, but is no longer read by this filter.
    defp select_deleted_candidates(deleted_days) do
      # Post-F-1-verification fix: the real worker now binds retention_days as a
      # string (Postgres resolves $1's type as `text` for the `($1 || ' days')`
      # concatenation — see media_cleanup_worker.ex's own comment), so this fake
      # receives a string here too, just like the real Postgrex driver would.
      threshold = now_ms() - days_ms(String.to_integer(deleted_days))
      log = Agent.get(transition_log(), & &1)

      rows =
        Agent.get(bucket(), & &1)
        |> Enum.filter(fn {media_id, row} ->
          row.state == "deleted" and deleted_age_ms(log, media_id) < threshold
        end)
        |> Enum.map(&to_select_row/1)

      %{rows: rows}
    end

    defp select_infected_candidates(infected_days) do
      # Post-F-1-verification fix: same string-bound parameter as
      # select_deleted_candidates/1 above — see that function's comment.
      threshold = now_ms() - days_ms(String.to_integer(infected_days))
      log = Agent.get(transition_log(), & &1)

      rows =
        Agent.get(bucket(), & &1)
        |> Enum.filter(fn {media_id, row} ->
          row.state == "infected" and infected_age_ms(log, media_id) < threshold
        end)
        |> Enum.map(&to_select_row/1)

      %{rows: rows}
    end

    defp select_completion_candidates do
      rows =
        Agent.get(bucket(), & &1)
        |> Enum.filter(fn {_id, row} ->
          row.state == "hard_deleted" and row.storage_key != nil
        end)
        |> Enum.map(&to_select_row/1)

      %{rows: rows}
    end

    defp set_hard_deleted_at(media_id) do
      num_rows =
        Agent.get_and_update(bucket(), fn state ->
          case Map.get(state, media_id) do
            %{hard_deleted_at: nil} = row ->
              {1, Map.put(state, media_id, %{row | hard_deleted_at: now_ms()})}

            _ ->
              {0, state}
          end
        end)

      %{num_rows: num_rows}
    end

    defp null_storage_columns(media_id) do
      num_rows =
        Agent.get_and_update(bucket(), fn state ->
          case Map.get(state, media_id) do
            %{storage_key: key} = row when not is_nil(key) ->
              Agent.update(Process.whereis(:media_cleanup_test_event_log), fn events ->
                [{:null_update, media_id} | events]
              end)

              {1, Map.put(state, media_id, %{row | storage_key: nil, uploader_user_id: nil})}

            _ ->
              {0, state}
          end
        end)

      %{num_rows: num_rows}
    end

    defp to_select_row({media_id, row}) do
      [media_id, row.file_hash, row.file_size, row.uploader_user_id, row.storage_key]
    end

    defp infected_age_ms(log, media_id) do
      log
      |> Enum.filter(&(&1.media_id == media_id and &1.to_state == "infected"))
      |> Enum.map(& &1.inserted_at)
      |> case do
        [] -> now_ms()
        timestamps -> Enum.max(timestamps)
      end
    end

    # security-review fix (cycle 2, F-1/MEDIUM): the :deleted-side twin of
    # infected_age_ms/2 above, same shape, just filtering on to_state == "deleted".
    defp deleted_age_ms(log, media_id) do
      log
      |> Enum.filter(&(&1.media_id == media_id and &1.to_state == "deleted"))
      |> Enum.map(& &1.inserted_at)
      |> case do
        [] -> now_ms()
        timestamps -> Enum.max(timestamps)
      end
    end

    defp now_ms, do: System.system_time(:millisecond)
    defp days_ms(n), do: n * 24 * 60 * 60 * 1000
  end

  # ─── FakeStateMachine ──────────────────────────────────────────────────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private fake for Nebu.Media.StateMachine. Test-private."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_cleanup_test_transition_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      bucket = Process.whereis(:media_cleanup_test_bucket)

      case Agent.get(bucket, &Map.get(&1, media_id)) do
        %{state: current} = row
        when current in ["deleted", "infected"] and to_state == :hard_deleted ->
          Agent.update(bucket, &Map.put(&1, media_id, %{row | state: "hard_deleted"}))

          Agent.update(Process.whereis(:media_cleanup_test_transition_log), fn log ->
            [
              %{
                media_id: media_id,
                from_state: current,
                to_state: "hard_deleted",
                actor: actor,
                metadata: metadata,
                inserted_at: System.system_time(:millisecond)
              }
              | log
            ]
          end)

          {:ok, :hard_deleted}

        %{state: current} ->
          {:error, {:invalid_transition, String.to_existing_atom(current), to_state}}

        nil ->
          {:error, :not_found}
      end
    end
  end

  # ─── FakeStorage ───────────────────────────────────────────────────────────

  defmodule FakeStorage do
    @moduledoc "Test-private fake for Nebu.Media.Storage.delete/1. Test-private."

    def delete(storage_key) do
      Agent.update(Process.whereis(:media_cleanup_test_storage_calls), fn calls ->
        [storage_key | calls]
      end)

      Agent.update(Process.whereis(:media_cleanup_test_event_log), fn events ->
        [{:storage_delete, storage_key} | events]
      end)

      overrides = Agent.get(Process.whereis(:media_cleanup_test_storage_overrides), & &1)

      case Map.fetch(overrides, storage_key) do
        {:ok, :raise} -> raise "simulated S3 failure for #{storage_key}"
        {:ok, response} -> response
        :error -> :ok
      end
    end
  end

  # ─── FakeAuditWriter ───────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    @moduledoc "Test-private fake for Nebu.Compliance.AuditWriter.log/6. Test-private."

    def log(actor_user_id, action, target_type, target_id, metadata, outcome) do
      Agent.update(Process.whereis(:media_cleanup_test_audit_calls), fn calls ->
        [{actor_user_id, action, target_type, target_id, metadata, outcome} | calls]
      end)

      :ok
    end
  end

  # ─── Setup / Teardown ──────────────────────────────────────────────────────

  setup do
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @bucket)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_log)
    {:ok, _} = Agent.start_link(fn -> %{} end, name: @storage_overrides)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @repo_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @transition_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @storage_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @audit_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @event_log)

    Application.put_env(:nebu_http, :media_cleanup_repo_module, FakeRepo)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_storage_module, FakeStorage)
    Application.put_env(:nebu_http, :media_audit_writer_module, FakeAuditWriter)
    # story media-cleanup-reads-media-config (follow-up du): the retention windows come from
    # Nebu.Media.Config.retention_days/0 (media_config); an empty table = the effective defaults 30 / 7.
    Application.put_env(:nebu_http, :media_config_loader, fn -> %{} end)

    on_exit(fn ->
      for name <- @all_agents do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
        end
      end

      Application.delete_env(:nebu_http, :media_cleanup_repo_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_storage_module)
      Application.delete_env(:nebu_http, :media_audit_writer_module)
      Application.delete_env(:nebu_http, :media_config_loader)
      Application.delete_env(:nebu, :media_cleanup)
    end)

    :ok
  end

  # ─── Seed helpers ───────────────────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)
  defp days_ms(n), do: n * 24 * 60 * 60 * 1000

  defp seed_deleted(media_id, deleted_at_ms, opts \\ %{}) do
    row = %{
      # deleted_at is kept in the fake row's schema for shape-fidelity with the
      # real (always-NULL, security-review F-1) column, but is no longer read
      # by FakeRepo.select_deleted_candidates/1 — see deleted_age_ms/2.
      state: "deleted",
      deleted_at: deleted_at_ms,
      storage_key: Map.get(opts, :storage_key, "storage-key-#{media_id}"),
      uploader_user_id: Map.get(opts, :uploader_user_id, "@uploader:test.local"),
      hard_deleted_at: nil,
      file_hash: Map.get(opts, :file_hash, "hash-#{media_id}"),
      file_size: Map.get(opts, :file_size, 1024)
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))

    # security-review fix (cycle 2, F-1/MEDIUM): the :deleted candidate query's
    # age is now ledger-derived, exactly like :infected's — so this fake must
    # seed a matching media_state_transitions row (mirrors seed_infected/3
    # below) for select_deleted_candidates/1's deleted_age_ms/2 lookup to see.
    Agent.update(Process.whereis(@transition_log), fn log ->
      [
        %{
          media_id: media_id,
          from_state: "quarantined",
          to_state: "deleted",
          actor: {:admin, "@admin:test.local"},
          metadata: %{},
          inserted_at: deleted_at_ms
        }
        | log
      ]
    end)
  end

  defp seed_infected(media_id, infected_at_ms, opts \\ %{}) do
    row = %{
      state: "infected",
      deleted_at: nil,
      storage_key: Map.get(opts, :storage_key, "storage-key-#{media_id}"),
      uploader_user_id: Map.get(opts, :uploader_user_id, "@uploader:test.local"),
      hard_deleted_at: nil,
      file_hash: Map.get(opts, :file_hash, "hash-#{media_id}"),
      file_size: Map.get(opts, :file_size, 2048)
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))

    Agent.update(Process.whereis(@transition_log), fn log ->
      [
        %{
          media_id: media_id,
          from_state: "scanning",
          to_state: "infected",
          actor: {:system, nil},
          metadata: %{},
          inserted_at: infected_at_ms
        }
        | log
      ]
    end)
  end

  defp seed_hard_deleted_intermediate(media_id, opts) do
    row = %{
      state: "hard_deleted",
      deleted_at: Map.get(opts, :deleted_at, nil),
      storage_key: Map.get(opts, :storage_key, "storage-key-#{media_id}"),
      uploader_user_id: Map.get(opts, :uploader_user_id, "@uploader:test.local"),
      hard_deleted_at: Map.get(opts, :hard_deleted_at, now_ms()),
      file_hash: Map.get(opts, :file_hash, "hash-#{media_id}"),
      file_size: Map.get(opts, :file_size, 4096)
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))
  end

  defp seed_hard_deleted_complete(media_id) do
    row = %{
      state: "hard_deleted",
      deleted_at: nil,
      storage_key: nil,
      uploader_user_id: nil,
      hard_deleted_at: now_ms(),
      file_hash: "hash-#{media_id}",
      file_size: 512
    }

    Agent.update(Process.whereis(@bucket), &Map.put(&1, media_id, row))
  end

  defp seed_storage_override(storage_key, response) do
    Agent.update(Process.whereis(@storage_overrides), &Map.put(&1, storage_key, response))
  end

  defp bucket_row(media_id), do: Agent.get(Process.whereis(@bucket), &Map.get(&1, media_id))
  defp transition_calls, do: Process.whereis(@transition_calls) |> Agent.get(&Enum.reverse/1)
  defp repo_calls, do: Process.whereis(@repo_calls) |> Agent.get(&Enum.reverse/1)
  defp storage_calls, do: Process.whereis(@storage_calls) |> Agent.get(&Enum.reverse/1)
  defp audit_calls, do: Process.whereis(@audit_calls) |> Agent.get(&Enum.reverse/1)
  defp event_log, do: Process.whereis(@event_log) |> Agent.get(&Enum.reverse/1)

  # ─── Test 1 (AC3/AC4/AC5/AC6/AC7) — expired :deleted row is hard-deleted ───

  test "a :deleted row past deleted_days is hard-deleted, S3 object removed, " <>
         "storage_key/uploader_user_id nulled" do
    media_id = "media-deleted-expired-1"
    seed_deleted(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    assert Enum.any?(transition_calls(), fn {mid, to_state, actor, _meta} ->
             mid == media_id and to_state == :hard_deleted and actor == {:system, nil}
           end)

    assert "storage-key-#{media_id}" in storage_calls()

    row = bucket_row(media_id)
    assert row.storage_key == nil
    assert row.uploader_user_id == nil
    assert row.hard_deleted_at != nil
  end

  # ─── Test 2 (AC3/AC4/AC5/AC6/AC7) — expired :infected row is hard-deleted ──

  test "an :infected row past infected_days (per media_state_transitions.inserted_at " <>
         "for to_state = infected) is hard-deleted" do
    media_id = "media-infected-expired-1"
    seed_infected(media_id, now_ms() - days_ms(8))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    assert Enum.any?(transition_calls(), fn {mid, to_state, actor, _meta} ->
             mid == media_id and to_state == :hard_deleted and actor == {:system, nil}
           end)

    assert "storage-key-#{media_id}" in storage_calls()

    row = bucket_row(media_id)
    assert row.storage_key == nil
    assert row.uploader_user_id == nil
    assert row.hard_deleted_at != nil
  end

  # ─── Test 5 (AC3) — :deleted rows within the retention window are untouched

  test ":deleted rows within the retention window are left untouched" do
    media_id = "media-deleted-fresh-1"
    seed_deleted(media_id, now_ms() - days_ms(5))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end)
    refute "storage-key-#{media_id}" in storage_calls()

    refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == media_id
           end)
  end

  # ─── Test 6 (AC3) — :infected rows within the retention window are untouched

  test ":infected rows within the retention window are left untouched" do
    media_id = "media-infected-fresh-1"
    seed_infected(media_id, now_ms() - days_ms(2))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end)
    refute "storage-key-#{media_id}" in storage_calls()

    refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == media_id
           end)
  end

  # ─── Test 7 (AC8) — idempotent: a fully-completed row is never reselected ──

  test "idempotent under repeated runs: an already fully hard-deleted row is not " <>
         "reselected and produces zero further calls" do
    media_id = "media-already-done-1"
    seed_hard_deleted_complete(media_id)

    assert :ok = perform_job(MediaCleanupWorker, %{})
    assert :ok = perform_job(MediaCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end)
    refute Enum.any?(storage_calls(), &(&1 == "storage-key-#{media_id}"))

    refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == media_id
           end)
  end

  # ─── Test 8 (AC8) — reaper/completion sweep for a crashed prior run ────────

  test "a row left intermediate by a crashed prior run is completed by the " <>
         "reaper/completion sweep, without re-invoking transition/4" do
    media_id = "media-crashed-prior-run-1"
    seed_hard_deleted_intermediate(media_id, %{storage_key: "storage-key-#{media_id}"})

    assert :ok = perform_job(MediaCleanupWorker, %{})

    refute Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end),
           "the completion sweep must not re-attempt StateMachine.transition/4 — the row's " <>
             "state is already correct"

    assert "storage-key-#{media_id}" in storage_calls()

    row = bucket_row(media_id)
    assert row.storage_key == nil
    assert row.uploader_user_id == nil
  end

  # ─── Test 9 (ADR-032 ordering) — delete-then-null, never the reverse ──────

  test "Storage.delete/1 is called, and only on success does the storage_key/ " <>
         "uploader_user_id UPDATE run (delete-then-null ordering)" do
    media_id = "media-order-check-1"
    seed_deleted(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    events = event_log()
    storage_key = "storage-key-#{media_id}"

    delete_index = Enum.find_index(events, &(&1 == {:storage_delete, storage_key}))
    null_index = Enum.find_index(events, &(&1 == {:null_update, media_id}))

    assert delete_index != nil, "expected a Storage.delete/1 call for #{storage_key}"

    assert null_index != nil,
           "expected a storage_key/uploader_user_id null UPDATE for #{media_id}"

    assert delete_index < null_index,
           "expected Storage.delete/1 (index #{delete_index}) to happen BEFORE the " <>
             "storage_key/uploader_user_id null UPDATE (index #{null_index}), per ADR-032"
  end

  # ─── Test 10 (AC6/AC8/AC9) — a Storage.delete/1 failure leaves intermediate

  test "a Storage.delete/1 failure leaves the row intermediate: no audit entry, no " <>
         "storage_key/uploader_user_id null, eligible for the next sweep" do
    media_id = "media-storage-failure-1"
    storage_key = "storage-key-#{media_id}"
    seed_deleted(media_id, now_ms() - days_ms(31), %{storage_key: storage_key})
    seed_storage_override(storage_key, {:error, :simulated_s3_error})

    assert :ok = perform_job(MediaCleanupWorker, %{})

    assert storage_key in storage_calls()

    row = bucket_row(media_id)
    assert row.state == "hard_deleted", "AC4/AC5 must still have happened before the S3 call"
    assert row.storage_key == storage_key, "AC7 must NOT run when AC6 fails"
    assert row.uploader_user_id != nil, "AC7 must NOT run when AC6 fails"

    refute Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == media_id
           end),
           "no audit entry may be written for a hard-delete that never completed AC7"
  end

  # ─── Test 11 (AC8) — one row's failure does not block other rows ──────────

  test "a failure processing one candidate row does not prevent other candidate rows in " <>
         "the same run from being hard-deleted" do
    failing_media_id = "media-multi-fail-1"
    ok_media_id = "media-multi-ok-1"
    failing_key = "storage-key-#{failing_media_id}"
    ok_key = "storage-key-#{ok_media_id}"

    seed_deleted(failing_media_id, now_ms() - days_ms(31), %{storage_key: failing_key})
    seed_deleted(ok_media_id, now_ms() - days_ms(31), %{storage_key: ok_key})
    seed_storage_override(failing_key, :raise)

    assert :ok = perform_job(MediaCleanupWorker, %{})

    ok_row = bucket_row(ok_media_id)
    assert ok_row.storage_key == nil
    assert ok_row.uploader_user_id == nil

    assert Enum.any?(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
             tid == ok_media_id
           end)
  end

  # ─── Test 12 (AC9/AC10) — exactly one audit entry, correct shape ──────────

  test "writes exactly one audit_log entry via AuditWriter with action " <>
         "\"media_hard_deleted\", actor_user_id \"system:media_cleanup_worker\", " <>
         "target_type \"media\", target_id = media_id, only after the S3 delete and " <>
         "column-null both succeeded" do
    media_id = "media-audit-shape-1"
    seed_deleted(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    matching =
      Enum.filter(audit_calls(), fn {_actor, _action, _type, tid, _meta, _outcome} ->
        tid == media_id
      end)

    assert length(matching) == 1,
           "expected exactly one audit entry for #{media_id}, got #{length(matching)}"

    [{actor_user_id, action, target_type, target_id, _metadata, _outcome}] = matching

    assert actor_user_id == "system:media_cleanup_worker"
    assert action == "media_hard_deleted"
    assert target_type == "media"
    assert target_id == media_id

    row = bucket_row(media_id)

    assert row.storage_key == nil,
           "the audit entry must only be written after AC7 nulls storage_key"
  end

  # ─── Test 13 (AC10, dedicated) — allowlist membership, independent of the

  defmodule KnownActionsFakeRepo do
    @moduledoc "Minimal in-process fake so this standalone allowlist check needs no live DB."

    def transaction(fun) when is_function(fun, 0) do
      {:ok, fun.()}
    end

    def insert!(struct, _opts \\ []), do: struct
  end

  test "media_hard_deleted is present in AuditWriter.@known_actions" do
    Application.put_env(:compliance, :repo, KnownActionsFakeRepo)

    on_exit(fn -> Application.delete_env(:compliance, :repo) end)

    result =
      Nebu.Compliance.AuditWriter.log(
        "system:media_cleanup_worker",
        "media_hard_deleted",
        "media",
        "media-known-actions-check-1",
        %{},
        "success"
      )

    refute result == {:error, :audit_unknown_action},
           ~s|"media_hard_deleted" must be in AuditWriter.@known_actions, got #{inspect(result)}|
  end

  # ─── Test 14 (AC5/AC7 boundary) — never a raw SQL write on .state ─────────

  test "never issues a raw SQL UPDATE/DELETE against media_files.state — every " <>
         "state change goes through StateMachine.transition/4" do
    media_id = "media-sql-state-check-1"
    seed_deleted(media_id, now_ms() - days_ms(31))

    assert :ok = perform_job(MediaCleanupWorker, %{})

    calls = repo_calls()
    assert length(calls) > 0, "the worker must issue at least one SQL statement via its repo seam"

    refute Enum.any?(calls, fn {sql, _params} ->
             String.match?(sql, ~r/SET\s+[^;]*\bstate\s*=/i)
           end),
           "the worker itself must never issue a raw UPDATE against media_files.state — " <>
             "every state change must go through Nebu.Media.StateMachine.transition/4"

    assert Enum.any?(calls, fn {sql, _params} -> String.match?(sql, ~r/hard_deleted_at/i) end)
    assert Enum.any?(calls, fn {sql, _params} -> String.match?(sql, ~r/storage_key/i) end)

    assert Enum.any?(transition_calls(), fn {mid, _to, _actor, _meta} -> mid == media_id end),
           "the one state change for #{media_id} must be attributed to StateMachine.transition/4"
  end

  # ─── Test 15 (AC11) — media_state_transitions rows exempt from all of this

  test "media_state_transitions rows are never modified or deleted by this worker" do
    media_id = "media-transitions-immutable-1"
    seed_deleted(media_id, now_ms() - days_ms(31))

    log_before = Process.whereis(@transition_log) |> Agent.get(& &1)

    assert :ok = perform_job(MediaCleanupWorker, %{})

    log_after = Process.whereis(@transition_log) |> Agent.get(& &1)

    # The only permitted change: exactly one NEW row appended by
    # FakeStateMachine.transition/4 itself for this media_id's
    # deleted -> hard_deleted transition. No pre-existing row may be
    # altered or removed, and the worker's own repo seam must never issue a
    # raw UPDATE/DELETE against media_state_transitions.
    assert length(log_after) == length(log_before) + 1

    assert Enum.all?(log_before, fn row -> row in log_after end),
           "no pre-existing media_state_transitions row may be modified or removed"

    refute Enum.any?(repo_calls(), fn {sql, _params} ->
             String.match?(sql, ~r/media_state_transitions/i) and
               String.match?(sql, ~r/^\s*(UPDATE|DELETE)/i)
           end),
           "the worker's own repo seam must never issue an UPDATE/DELETE against " <>
             "media_state_transitions — the only legal write is transition/4's own INSERT"
  end

  # ─── story media-cleanup-reads-media-config (follow-up du): the windows come from media_config ──

  # the media_config rows the loader seam of Nebu.Media.Config returns (string keys, as the default loader does)
  defp stored_config(map), do: Application.put_env(:nebu_http, :media_config_loader, fn -> map end)

  defp hard_deleted?(media_id), do: Enum.any?(transition_calls(), fn {mid, to, _a, _m} -> mid == media_id and to == :hard_deleted end)

  describe "retention from media_config" do
    test "AC1 no stored rows: the effective defaults are unchanged, :deleted after 30 days, :infected after 7 (younger rows stay)" do
      seed_deleted("d-31", now_ms() - days_ms(31))
      seed_deleted("d-29", now_ms() - days_ms(29))
      seed_infected("i-8", now_ms() - days_ms(8))
      seed_infected("i-6", now_ms() - days_ms(6))

      assert :ok = perform_job(MediaCleanupWorker, %{})

      assert hard_deleted?("d-31") and hard_deleted?("i-8")
      refute hard_deleted?("d-29")
      refute hard_deleted?("i-6")
    end

    test "AC2 stored windows (deleted 10, infected 3) decide: older rows are hard-deleted, younger ones stay, the audit names the window" do
      stored_config(%{"deleted_days" => 10, "infected_days" => 3})
      seed_deleted("d-11", now_ms() - days_ms(11))
      seed_deleted("d-9", now_ms() - days_ms(9))
      seed_infected("i-4", now_ms() - days_ms(4))
      seed_infected("i-2", now_ms() - days_ms(2))

      assert :ok = perform_job(MediaCleanupWorker, %{})

      assert hard_deleted?("d-11") and hard_deleted?("i-4")
      refute hard_deleted?("d-9")
      refute hard_deleted?("i-2")

      windows = for {_a, "media_hard_deleted", "media", id, meta, "success"} <- audit_calls(), into: %{}, do: {id, meta.retention_days}
      assert windows == %{"d-11" => 10, "i-4" => 3}
    end

    test "AC2 a longer stored window keeps what the old default would have deleted (deleted 90, infected 90: 31 / 8 days old stay)" do
      stored_config(%{"deleted_days" => 90, "infected_days" => 90})
      seed_deleted("d-31", now_ms() - days_ms(31))
      seed_infected("i-8", now_ms() - days_ms(8))

      assert :ok = perform_job(MediaCleanupWorker, %{})

      refute hard_deleted?("d-31")
      refute hard_deleted?("i-8")
      assert storage_calls() == []
    end

    test "AC2 the two windows are independent: the SQL gets the string of each integer (days, never seconds or hours)" do
      stored_config(%{"deleted_days" => 12, "infected_days" => 5})

      assert :ok = perform_job(MediaCleanupWorker, %{})

      params = for {sql, [p]} <- repo_calls(), sql =~ "media_state_transitions", do: {String.contains?(sql, "'infected'"), p}
      assert {true, "5"} in params and {false, "12"} in params
    end

    test "AC3 a LENGTHENING takes effect at the next run too: after 15 -> 365 a 20 day old row is kept (the destructive direction of a stale value)" do
      stored_config(%{"deleted_days" => 15})
      seed_deleted("d-10", now_ms() - days_ms(10))
      assert :ok = perform_job(MediaCleanupWorker, %{})
      refute hard_deleted?("d-10")

      seed_deleted("d-20", now_ms() - days_ms(20))
      stored_config(%{"deleted_days" => 365})
      assert :ok = perform_job(MediaCleanupWorker, %{})
      refute hard_deleted?("d-20"), "the admin lengthened the window to 365: no stale 15 day value may delete it"
    end

    test "AC3 a change of the stored value takes effect at the next run, in the same process, without a restart" do
      seed_deleted("d-20", now_ms() - days_ms(20))

      assert :ok = perform_job(MediaCleanupWorker, %{})
      refute hard_deleted?("d-20"), "20 days old, window 30: kept"

      stored_config(%{"deleted_days" => 15})
      assert :ok = perform_job(MediaCleanupWorker, %{})
      assert hard_deleted?("d-20"), "the admin shortened the window to 15: the next run deletes it"
    end

    test "AC5 a window of 0 days deletes every row of that state whose ledger time is in the past (the documented shortest retention)" do
      stored_config(%{"deleted_days" => 0, "infected_days" => 0})
      seed_deleted("d-1h", now_ms() - 3_600_000)
      seed_infected("i-1h", now_ms() - 3_600_000)

      assert :ok = perform_job(MediaCleanupWorker, %{})

      assert hard_deleted?("d-1h") and hard_deleted?("i-1h")
    end

    test "AC5 the upper bound 3650 days is accepted: a 3649 day old row stays, a 3651 day old one is hard-deleted" do
      stored_config(%{"deleted_days" => 3650, "infected_days" => 3650})
      seed_deleted("d-3649", now_ms() - days_ms(3649))
      seed_deleted("d-3651", now_ms() - days_ms(3651))

      assert :ok = perform_job(MediaCleanupWorker, %{})

      refute hard_deleted?("d-3649")
      assert hard_deleted?("d-3651"), "3650 is a valid window, not a fail-safe skip"
    end

    test "AC2 the unit is DAYS: both candidate queries bind the window as ($1 || ' days')::interval (never hours / seconds)" do
      stored_config(%{"deleted_days" => 12, "infected_days" => 5})

      assert :ok = perform_job(MediaCleanupWorker, %{})

      window_queries = for {sql, [_p]} <- repo_calls(), sql =~ "media_state_transitions", do: sql
      assert length(window_queries) == 2
      for sql <- window_queries, do: assert(sql =~ ~r/\(\$1 \|\| ' days'\)::interval/, "the unit of the window is days")
    end

    test "AC6 the dead application key :media_cleanup is not read any more (a window of 1 day there changes nothing)" do
      Application.put_env(:nebu, :media_cleanup, deleted_days: 1, infected_days: 1)
      seed_deleted("d-5", now_ms() - days_ms(5))
      seed_infected("i-3", now_ms() - days_ms(3))

      assert :ok = perform_job(MediaCleanupWorker, %{})

      refute hard_deleted?("d-5")
      refute hard_deleted?("i-3")
    end
  end

  describe "AC4 retention config that cannot be trusted: nothing is deleted (fail-safe)" do
    defp seed_everything_ancient do
      seed_deleted("d-ancient", now_ms() - days_ms(3000))
      seed_infected("i-ancient", now_ms() - days_ms(3000))
      seed_hard_deleted_intermediate("h-crashed", %{storage_key: "storage-key-h-crashed"})
    end

    defp assert_nothing_new_deleted do
      refute hard_deleted?("d-ancient")
      refute hard_deleted?("i-ancient")
      assert bucket_row("d-ancient").storage_key != nil
      assert bucket_row("i-ancient").storage_key != nil
    end

    test "an unreadable media_config (the loader raises, exits, answers an error) deletes nothing from :deleted / :infected, the job is still :ok" do
      for {label, fun} <- [raise: fn -> raise "db down" end, exit: fn -> exit(:noproc) end, error: fn -> {:error, :timeout} end, nil: fn -> nil end] do
        Application.put_env(:nebu_http, :media_config_loader, fun)
        seed_everything_ancient()

        log = capture_log([level: :error], fn -> send(self(), {:result, perform_job(MediaCleanupWorker, %{})}) end)

        assert_received {:result, :ok}
        assert_nothing_new_deleted()
        assert log =~ "retention config unavailable", "#{label}: one ERROR line explains why nothing was deleted"
        assert transition_calls() == [], "#{label}"
      end
    end

    test "an invalid stored value (negative, 3651, huge, not a number, empty, nil) deletes nothing, for either key" do
      for key <- ["deleted_days", "infected_days"], bad <- [-1, 3651, 1_000_000_000_000, "abc", "", nil, 2.5] do
        stored_config(%{key => bad})
        seed_everything_ancient()

        log = capture_log([level: :error], fn -> send(self(), {:result, perform_job(MediaCleanupWorker, %{})}) end)

        assert_received {:result, :ok}
        assert_nothing_new_deleted()
        assert log =~ "retention config unavailable", "#{key} = #{inspect(bad)}"
      end
    end

    test "the log line names no value (a stored value is never echoed)" do
      stored_config(%{"deleted_days" => "secret-ish-9999999", "infected_days" => 5})
      seed_everything_ancient()

      log = capture_log([level: :error], fn -> send(self(), {:result, perform_job(MediaCleanupWorker, %{})}) end)

      assert log =~ "retention config unavailable", "the log is not empty: the refutes below are meaningful"
      refute log =~ "secret-ish"
      refute log =~ "9999999"
      refute log =~ "deleted_days="
    end

    test "the completion sweep still finishes a row that is ALREADY :hard_deleted (it deletes nothing new) when the config is unreadable or invalid" do
      for loader <- [fn -> raise "db down" end, fn -> %{"deleted_days" => -1} end, fn -> %{"infected_days" => "abc"} end] do
        Application.put_env(:nebu_http, :media_config_loader, loader)
        id = "h-crashed-#{System.unique_integer([:positive])}"
        seed_hard_deleted_intermediate(id, %{storage_key: "storage-key-#{id}"})
        seed_deleted("d-ancient-#{id}", now_ms() - days_ms(3000))

        capture_log(fn -> assert :ok = perform_job(MediaCleanupWorker, %{}) end)

        assert "storage-key-#{id}" in storage_calls()
        assert bucket_row(id).storage_key == nil
        refute hard_deleted?("d-ancient-#{id}")
      end
    end

    test "the effective windows are logged at INFO on a normal run (operators can see what a run used)" do
      stored_config(%{"deleted_days" => 21, "infected_days" => 6})
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> perform_job(MediaCleanupWorker, %{}) end)

      assert log =~ "deleted_days=21"
      assert log =~ "infected_days=6"
    end
  end
end
