defmodule Nebu.Workers.MediaCleanupWorker do
  @moduledoc """
  Daily Oban-cron retention purge (media-security-admin-control/
  8a-media-cleanup-worker) that permanently hard-deletes `media_files` rows
  that have sat in a soft-deleted state (`:deleted` — Story 6a's
  `admin_delete/2`, or `:infected` — Story 4b's scan worker) past a
  per-state retention window.

  This story's own scope note (see the story's Summary section) — this is
  the SIMPLE, originally-scoped hard-delete cron, later superseded by Story
  13's `MediaLifecycleWorker`/Two-Eyes-Delete design (out of scope for this
  epic pass). No `legal_hold`/`two_eyes_delete_required` gating here — this
  worker unconditionally hard-deletes every row past its retention window.

  ## ADR-032 three-step ordering (load-bearing, never reorder)

  For each fresh candidate:
    1. `Nebu.Media.StateMachine.transition/4` to `:hard_deleted` (the only
       legal writer of `media_files.state`), then this worker's own direct
       `UPDATE ... SET hard_deleted_at = NOW() WHERE hard_deleted_at IS NULL`
       (a non-`state` column write, never touching `state` itself).
    2. `Nebu.Media.Storage.delete/1` against the row's `storage_key` — a 404
       is treated as `:ok` (already gone, safe no-op).
    3. Only on that call's success, this worker's own direct
       `UPDATE ... SET storage_key = NULL WHERE storage_key IS NOT NULL`.
       (`uploader_user_id` is NOT nulled here — `StateMachine.transition/4`
       already nulled it inside step 1, for both fresh and reaper
       candidates; see `@sql_update_null_storage_key`.)
    4. Only if that `UPDATE` actually affected a row, an audit entry via
       `Nebu.Compliance.AuditWriter.log/6` (`"media_hard_deleted"`).

  A `Storage.delete/1` failure (any reason other than the 404 the module
  itself already treats as `:ok`) leaves the row exactly as-is — state
  already `:hard_deleted`, `hard_deleted_at` already set, `storage_key`
  still populated — for the next tick's completion/"reaper" query to retry.
  No audit entry, no null-`UPDATE`, and this never aborts the whole tick.

  ## Three candidate queries, each read-only, `LIMIT 1000`

  1. `:deleted` candidates — **no `deleted_at` column read** (security-review
     fix, cycle 2, F-1/MEDIUM: `media_files.deleted_at` is never populated by
     any code path — `Nebu.Media.admin_delete/2`'s `StateMachine.transition/4`
     call never stamps it, so `deleted_at < NOW() - interval` matched zero
     rows forever in production). Age is instead derived from the append-only
     `media_state_transitions` ledger, exactly symmetric with the `:infected`
     query below: `MAX(inserted_at) WHERE to_state = 'deleted'`.
  2. `:infected` candidates — no `infected_at` column exists on
     `media_files` either; age is derived from the same append-only
     `media_state_transitions` ledger's `MAX(inserted_at) WHERE to_state =
     'infected'`.
  3. Completion/"reaper" candidates — `state = 'hard_deleted' AND storage_key
     IS NOT NULL`, rows left in the intermediate state by a crashed or
     partially-failed prior run. These are carried straight through the
     `Storage.delete`/null-`UPDATE`/audit steps WITHOUT re-invoking
     `StateMachine.transition/4` — the state is already correct, and
     `:hard_deleted` has no outgoing guard-table edges anyway.

  ## Per-row isolation

  Each candidate row is processed inside its own `rescue`-wrapped block,
  logging via `Logger.error` and continuing to the next row on failure, so
  `perform/1` always returns `:ok` regardless of individual row failures —
  one row's S3/DB error can't block every other row's cleanup for a day.
  (Note: neither `Nebu.Compliance.SessionExpiryWorker`'s tick-level `rescue`
  nor `Nebu.Workers.MediaReservedUploadCleanupWorker`'s `reduce_while` — both
  cited elsewhere as "precedent" — actually provide genuine per-row
  isolation; this worker deliberately does not copy either pattern.)

  ## Seams

  `Application.get_env(:nebu_http, :media_cleanup_repo_module, Nebu.Repo)`,
  `:media_state_machine_module`, `:media_storage_module`,
  `:media_audit_writer_module` — the SAME seam keys `Nebu.Media`/Story 2e
  already read, swappable independently for tests. Retention config is a
  SEPARATE, `:nebu`-namespaced key: `Application.get_env(:nebu, :media_cleanup,
  [])`, with `deleted_days: 30` / `infected_days: 7` fallbacks.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  require Logger

  # security-review fix (cycle 2, F-1/MEDIUM): the original predicate here was
  # `deleted_at < NOW() - interval` — but `media_files.deleted_at` is never
  # written by any code path (Nebu.Media.admin_delete/2's StateMachine.transition/4
  # call never stamps it; only the :hard_deleted target has a column-stamping SQL
  # variant). That made this query match zero rows forever in production. Fixed
  # to derive age from the append-only media_state_transitions ledger instead,
  # mirroring @sql_select_infected_candidates below exactly (same shape, same
  # $1-bound interval-days parameter, same LIMIT 1000) — no shared StateMachine
  # change, confined entirely to this worker's own query.
  @sql_select_deleted_candidates """
  SELECT mf.media_id, mf.file_hash, mf.file_size, mf.uploader_user_id, mf.storage_key
    FROM media_files mf
   WHERE mf.state = 'deleted'
     AND (SELECT MAX(t.inserted_at) FROM media_state_transitions t
           WHERE t.media_id = mf.media_id AND t.to_state = 'deleted') < NOW() - ($1 || ' days')::interval
   LIMIT 1000
  """

  @sql_select_infected_candidates """
  SELECT mf.media_id, mf.file_hash, mf.file_size, mf.uploader_user_id, mf.storage_key
    FROM media_files mf
   WHERE mf.state = 'infected'
     AND (SELECT MAX(t.inserted_at) FROM media_state_transitions t
           WHERE t.media_id = mf.media_id AND t.to_state = 'infected') < NOW() - ($1 || ' days')::interval
   LIMIT 1000
  """

  @sql_select_completion_candidates """
  SELECT media_id, file_hash, file_size, uploader_user_id, storage_key
    FROM media_files
   WHERE state = 'hard_deleted'
     AND storage_key IS NOT NULL
   LIMIT 1000
  """

  @sql_update_hard_deleted_at """
  UPDATE media_files SET hard_deleted_at = NOW()
   WHERE media_id = $1 AND hard_deleted_at IS NULL
  """

  # Note: uploader_user_id is nulled by Nebu.Media.StateMachine.transition/4
  # as part of entering :hard_deleted (state_machine.ex's
  # @sql_update_state_hard_deleted sets it inside the transition itself, for
  # both the deleted-> and infected->hard_deleted edges) — not by this
  # worker. By the time this UPDATE runs, uploader_user_id is already NULL
  # for every row this worker ever processes (fresh candidates: nulled by
  # step 1's transition, before this UPDATE runs; reaper candidates: nulled
  # by the PRIOR tick's transition, already gone by the time the reaper
  # query selects the row). Only storage_key — the actual blob reference —
  # is this worker's own responsibility to null, and only after Storage.delete/1
  # confirms the object is gone (ADR-032 step 3).
  @sql_update_null_storage_key """
  UPDATE media_files SET storage_key = NULL
   WHERE media_id = $1 AND storage_key IS NOT NULL
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    process_fresh_candidates(@sql_select_deleted_candidates, "deleted", deleted_days())
    process_fresh_candidates(@sql_select_infected_candidates, "infected", infected_days())
    process_completion_candidates()

    :ok
  end

  defp process_fresh_candidates(sql, from_state, retention_days) do
    # Found + fixed while verifying the F-1 fix against a real Postgres (previously
    # only ever exercised via FakeRepo, which never round-trips real SQL): both
    # @sql_select_deleted_candidates and @sql_select_infected_candidates bind $1
    # inside `($1 || ' days')::interval` — Postgres resolves $1's parameter type as
    # `text` for that `||` concatenation (to match the `' days'` literal), so
    # Postgrex requires a binary for it. Binding the raw Elixir integer
    # `retention_days` crashed every real invocation of this worker with
    # `DBConnection.EncodeError` (a worse, silent-in-CI bug than F-1: nothing ever
    # ran this SELECT against a live DB before). Fixed by binding the string form —
    # the SQL text itself is unchanged.
    %{rows: rows} = repo().query!(sql, [Integer.to_string(retention_days)])

    Enum.each(rows, fn [media_id, file_hash, file_size, uploader_user_id, storage_key] ->
      process_row(
        media_id,
        true,
        from_state,
        retention_days,
        file_hash,
        file_size,
        uploader_user_id,
        storage_key
      )
    end)
  end

  defp process_completion_candidates do
    %{rows: rows} = repo().query!(@sql_select_completion_candidates, [])

    Enum.each(rows, fn [media_id, file_hash, file_size, uploader_user_id, storage_key] ->
      process_row(media_id, false, nil, nil, file_hash, file_size, uploader_user_id, storage_key)
    end)
  end

  # Per-row isolation: this whole block (transition -> hard_deleted_at UPDATE
  # -> Storage.delete -> null UPDATE -> audit) is rescue-wrapped so one
  # candidate's failure (raised exception or otherwise) never prevents the
  # next candidate in the same tick from being processed. perform/1 always
  # returns :ok regardless of what happens here.
  defp process_row(
         media_id,
         need_transition?,
         from_state,
         retention_days,
         file_hash,
         file_size,
         uploader_user_id,
         storage_key
       ) do
    if need_transition? do
      case state_machine().transition(media_id, :hard_deleted, {:system, nil}, %{
             reason: "retention_expired",
             from_state: from_state,
             retention_days: retention_days
           }) do
        {:ok, :hard_deleted} ->
          finish_hard_delete(
            media_id,
            from_state,
            retention_days,
            file_hash,
            file_size,
            uploader_user_id,
            storage_key
          )

        {:error, {:invalid_transition, _from, _to}} ->
          # Lost a race against another path that already moved this row past
          # :deleted/:infected between the candidate SELECT and this call —
          # nothing to do, matching Story 2e's own race-handling convention.
          :ok

        {:error, reason} ->
          Logger.error("MediaCleanupWorker: StateMachine.transition/4 failed",
            media_id: media_id,
            reason: inspect(reason)
          )
      end
    else
      # Completion/"reaper" candidate: state is already :hard_deleted (no
      # outgoing guard-table edges from there), so we jump straight to the
      # Storage.delete + null-UPDATE + audit steps without re-invoking
      # transition/4.
      finish_hard_delete(
        media_id,
        from_state,
        retention_days,
        file_hash,
        file_size,
        uploader_user_id,
        storage_key
      )
    end
  rescue
    error ->
      Logger.error("MediaCleanupWorker: failed processing candidate row",
        media_id: media_id,
        error: inspect(error)
      )
  end

  defp finish_hard_delete(
         media_id,
         from_state,
         retention_days,
         file_hash,
         file_size,
         uploader_user_id,
         storage_key
       ) do
    repo().query!(@sql_update_hard_deleted_at, [media_id])

    case storage().delete(storage_key) do
      :ok ->
        %{num_rows: num_rows} = repo().query!(@sql_update_null_storage_key, [media_id])

        if num_rows > 0 do
          audit_writer().log(
            "system:media_cleanup_worker",
            "media_hard_deleted",
            "media",
            media_id,
            %{
              from_state: from_state,
              file_hash: file_hash,
              bytes_freed: file_size,
              uploader_user_id: uploader_user_id,
              retention_days: retention_days
            },
            "success"
          )
        end

      {:error, reason} ->
        # ADR-032: never null storage_key/uploader_user_id before the S3
        # delete is confirmed done. The row stays exactly as-is (state
        # already :hard_deleted, hard_deleted_at already set, storage_key
        # still populated) for the next tick's completion sweep to retry.
        Logger.error(
          "MediaCleanupWorker: Storage.delete/1 failed, row left in intermediate state for next sweep",
          media_id: media_id,
          storage_key: storage_key,
          reason: inspect(reason)
        )
    end
  end

  defp repo, do: Application.get_env(:nebu_http, :media_cleanup_repo_module, Nebu.Repo)

  defp state_machine,
    do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)

  defp storage, do: Application.get_env(:nebu_http, :media_storage_module, Nebu.Media.Storage)

  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)

  defp deleted_days, do: media_cleanup_config() |> Keyword.get(:deleted_days, 30)
  defp infected_days, do: media_cleanup_config() |> Keyword.get(:infected_days, 7)

  defp media_cleanup_config, do: Application.get_env(:nebu, :media_cleanup, [])
end
