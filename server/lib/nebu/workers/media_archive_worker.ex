defmodule Nebu.Workers.MediaArchiveWorker do
  @moduledoc """
  Daily Oban-cron job (media-security-admin-control/8c-media-archive-worker)
  that copies aged `:released` `media_files` objects into a cheaper,
  separately-configured archive bucket via a server-side S3 `PUT Object
  Copy` — never a download/decrypt/re-encrypt/re-upload round trip (ADR-029:
  bytes are already AES-256-GCM encrypted; the copy moves the same
  ciphertext under the SAME `storage_key`) — and records the move as
  `archived_at` on the row. `state` is never touched: archiving is a
  storage-location change, not a lifecycle transition (ADR-029, "No new
  state for archival"; contrast with `Nebu.Workers.MediaCleanupWorker`/8a and
  `Nebu.Workers.MediaReservedUploadCleanupWorker`/2e, both of which DO drive
  `Nebu.Media.StateMachine.transition/4`). This worker never calls
  `StateMachine.transition/3` — see AC9/the acceptance tests' own dedicated
  regression test for that invariant.

  ## Eligibility (AC1-AC4)

  `released_archive_after_days` (`nil` disables the worker — a pure no-op,
  never raises) and `archive_delete_from_primary` gate the worker, read via
  `Application.get_env(:nebu, :media_archive, ...)` — a config seam, not a
  hardcoded literal, mirroring Story 8a's own `:media_cleanup` config
  pattern (both pre-date Story 9a's `Nebu.Media.Config` DB-backed source and
  are deliberately not yet rewired to it, same posture 8a/8b's own
  config.exs entries already document).

  The sole eligibility filter is `state = 'released' AND archived_at IS
  NULL AND uploaded_at < threshold` (`Nebu.Media.DB.candidates_for_archive/1`)
  — an explicit ALLOW-list (AC2), never a deny-list: `:infected`,
  `:reserved`, `:quarantined`, `:scanning`, `:admin_blocked`, `:deleted`, and
  `:hard_deleted` files are never selected regardless of age, including a
  file that WAS archived while `:released` and later transitioned away (its
  earlier `archived_at` is left untouched, but no new archive run may touch
  it while `state != 'released'`).

  ## Age anchor — `uploaded_at`, not a derived `released_at` (AC3)

  `media_files` has no dedicated "became-released-at" column (Story 1a's
  migration added `archived_at`/`deleted_at`/`hard_deleted_at`, deliberately
  not a `released_at`), so the age threshold anchors on `uploaded_at` — a
  documented simplification versus the exact release timestamp, accepted
  because the vast majority of `:released` files clear `:quarantined` within
  minutes of upload (Story 4b's scan turnaround). `uploaded_at` is a `BIGINT`
  millisecond-epoch column (`Nebu.Media.StateMachine.create/1`'s own
  `System.system_time(:millisecond)` writer, confirmed against
  `server/priv/migrations/000001_init.up.sql`), NOT a Postgres `TIMESTAMPTZ`
  — the threshold is computed here as an already-resolved millisecond epoch
  integer (`System.system_time(:millisecond) - days * 86_400_000`, mirroring
  `Nebu.Workers.MediaReservedUploadCleanupWorker`'s own `now_ms - ttl_ms`
  convention) and bound directly against it in
  `Nebu.Media.DB.candidates_for_archive/1` — NOT the story's own illustrative
  `NOW() - ($1 || ' days')::interval` SQL, which cannot type-check against a
  `BIGINT` column (confirmed empirically against the live schema, not
  assumed from the story text).

  ## ADR-032 copy-then-verify-then-commit ordering (AC7/AC8)

  Per candidate row:
    1. `Nebu.Media.Storage.put_object_copy/2` (server-side S3 copy into the
       archive bucket, under the same `storage_key` — ADR-029, never
       recomputed). A non-`:ok` result aborts this row: no DB write happens,
       and this function's own `{:error, reason}` return propagates all the
       way out of `perform/1` so Oban retries the whole job (AC7 step 1;
       AT8 requires job-level failure here, so `Enum.reduce_while/3` is used
       below rather than `Enum.each/2` — this deliberately mirrors Story
       2e's own halt-on-real-error convention, not 8a's per-row
       rescue-and-always-return-:ok one; the two cited precedents differ
       here on purpose and this story's own acceptance test picks 2e's
       shape).
    2. Only after the copy succeeds: `Nebu.Media.DB.commit_archived/1`
       (`UPDATE ... SET archived_at = NOW() WHERE media_id = $1 AND state =
       'released' AND archived_at IS NULL`) — the SAME `archived_at IS
       NULL` guard as the candidate query, which is what makes a
       second/concurrent attempt on an already-archived row a safe no-op
       (AC8) without any additional locking.
    3. Only if that commit actually won the race (`{:ok, :committed}`, not
       `{:ok, :already_archived}`): write the `"media_archived"` audit entry
       (AC9), then, only if `archive_delete_from_primary` is `true`, delete
       the primary-bucket object (`Nebu.Media.Storage.delete/1`, already
       added by Story 8a). A losing execution (`{:ok, :already_archived}`)
       never reaches either step — no audit entry, no primary delete.

  Never delete the primary object before `archived_at` is durably
  committed, even with `archive_delete_from_primary: true` — that would
  create the "S3 blob gone, DB row doesn't know it" failure mode ADR-032
  rejects.

  ## Shared cron cadence with Story 8a (AC10)

  Runs on the same `"0 2 * * *"` (02:00 UTC) `Oban.Plugins.Cron` schedule
  and the same `:media_cleanup` queue as `Nebu.Workers.MediaCleanupWorker`
  (`config/config.exs`) — the two jobs operate on disjoint candidate
  populations (8a: `state IN ('deleted', 'infected')`; this worker: `state =
  'released' AND archived_at IS NULL`), so no row-level contention exists
  between them.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @ms_per_day 24 * 60 * 60 * 1000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case archive_after_days() do
      nil ->
        :ok

      days ->
        threshold_ms = System.system_time(:millisecond) - days * @ms_per_day

        db().candidates_for_archive(threshold_ms)
        |> Enum.reduce_while(:ok, fn candidate, _acc ->
          case archive_one(candidate) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp archive_one(%{media_id: media_id, storage_key: storage_key}) do
    case storage().put_object_copy(storage_key, archive_bucket()) do
      :ok ->
        case db().commit_archived(media_id) do
          {:ok, :committed} ->
            audit_writer().log(
              "system:media_archive_worker",
              "media_archived",
              "media",
              media_id,
              %{
                archive_bucket: archive_bucket(),
                archive_delete_from_primary: delete_from_primary?()
              },
              "success"
            )

            if delete_from_primary?(), do: storage().delete(storage_key)

            :ok

          {:ok, :already_archived} ->
            # Lost the race against another execution that already committed
            # archived_at for this row between our own candidate SELECT and
            # our own commit attempt — a safe no-op (AC8), never an audit
            # entry, never a primary delete.
            :ok

          {:error, _reason} = error ->
            # Security-review fix (Kassandra, cycle 0, self-caught before
            # commit): commit_archived/1 can genuinely return {:error, _}
            # (Ecto.Adapters.SQL.query/3 does not only ever return {:ok, _}
            # or raise — real Postgrex error tuples, e.g. constraint
            # violations, surface here too). A copy has already landed in the
            # archive bucket at this point (harmless — it is byte-identical
            # and will simply be re-copied on retry, an idempotent PUT), but
            # this row's own archived_at is NOT set — no audit entry, no
            # primary delete, propagated exactly like a copy failure so Oban
            # retries the job.
            error
        end

      {:error, _reason} = error ->
        # ADR-032: archived_at is never touched on a failed copy. Propagated
        # all the way out of perform/1 (via the reduce_while halt above) so
        # Oban retries the whole job.
        error
    end
  end

  defp archive_after_days, do: config()[:released_archive_after_days]
  defp delete_from_primary?, do: config()[:archive_delete_from_primary] || false
  defp archive_bucket, do: storage().archive_bucket()

  defp config,
    do:
      Application.get_env(:nebu, :media_archive,
        released_archive_after_days: nil,
        archive_delete_from_primary: false
      )

  defp db, do: Application.get_env(:nebu_http, :media_db_module, Nebu.Media.DB)
  defp storage, do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)

  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)
end
