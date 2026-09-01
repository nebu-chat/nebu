defmodule Nebu.Workers.MediaReservedUploadCleanupWorker do
  @moduledoc """
  Oban-cron housekeeping worker (media-security-admin-control/
  2e-reserved-upload-cleanup-cron) that retires abandoned `:reserved`
  `media_files` rows whose upload-reservation TTL has passed.

  `POST /_matrix/media/v1/create` (Story 2a) reserves a `media_id` and hands
  the client an `unused_expires_at` deadline, but nothing reclaims the row if
  the client never follows up with `PUT /_matrix/media/v3/upload/...`
  (Story 2b). Left alone, these rows accumulate and count against the
  per-user pending-upload limit (`max_pending_per_user`) forever. This worker
  runs on a 15-minute `Oban.Plugins.Cron` schedule (see `config/config.exs`)
  and transitions each expired row to `:hard_deleted` via
  `Nebu.Media.StateMachine.transition/4` — never a raw SQL UPDATE/DELETE,
  never a physical row delete (the epic's DB-Record-Invariante: the row
  always stays, only `state`/`hard_deleted_at`/`uploader_user_id` change).

  ## TTL — no persisted `unused_expires_at` column

  There is no `media_files.unused_expires_at` column (confirmed absent from
  the schema). Expiry is derived LIVE, exactly like `Nebu.Media`'s own
  private `reservation_expired?/1` (`uploaded_at + unused_expires_ms() <
  now_ms`), reading the SAME `Application.get_env(:nebu_http,
  :media_unused_expires_ms, 86_400_000)` key `Nebu.Media.create/1` already
  uses — no second/duplicate TTL config value is introduced here.

  ## Best-effort housekeeping, not the authoritative expiry check

  The PUT handler's (Story 2b) own live expiry check remains the sole
  authoritative enforcement path and is untouched by this worker — a request
  arriving 1ms after expiry, before this cron's next tick, still correctly
  sees a 404. This worker only exists so abandoned reservations don't
  accumulate between PUT attempts; it never needs to touch S3/MinIO since no
  bytes were ever written for a `:reserved` row (`storage_key` is `NULL`
  since creation).

  ## Idempotency

  A `LIMIT 1000`-bounded `SELECT` (mirrors `Nebu.Compliance.SessionExpiryWorker`'s
  scan query, so a single tick can't unboundedly scan the table) only ever
  returns rows still in `:reserved` — once a row is transitioned to
  `:hard_deleted`, the next tick's `WHERE state = 'reserved'` filter
  naturally excludes it. If two executions race on the same row, the loser's
  `StateMachine.transition/4` call is rejected with
  `{:error, {:invalid_transition, _, _}}` (the guard's real current-state
  check, re-verified under a row-level lock) — treated as a no-op, not a
  crash or an Oban-triggered retry. Any OTHER failure shape is NOT swallowed
  the same way — it propagates as `{:error, reason}` so Oban retries the job,
  since that would indicate a genuine seam/DB problem worth surfacing.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @default_unused_expires_ms 86_400_000

  # code-review MAJOR fix: the expiry predicate (uploaded_at < $1, i.e.
  # uploaded_at + unused_expires_ms() < now_ms rearranged into a single bind
  # param) is applied IN SQL, not filtered in Elixir after the fact — the
  # LIMIT 1000 must cap already-expired candidate rows, not an arbitrary mix
  # of expired and fresh :reserved rows. Filtering only in Elixir after a
  # LIMIT-1000 SQL scan of ALL :reserved rows (expired or not) could starve
  # genuinely expired rows behind fresh ones under sustained upload churn —
  # this now mirrors Nebu.Compliance.SessionExpiryWorker's own pattern
  # (`WHERE expires_at <= NOW() ... LIMIT 1000`) exactly, applying the
  # predicate before the cap.
  @sql_select_expired_reserved """
  SELECT media_id FROM media_files
   WHERE state = 'reserved' AND uploaded_at < $1
   LIMIT 1000
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now_ms = System.system_time(:millisecond)
    ttl_ms = unused_expires_ms()
    expiry_threshold_ms = now_ms - ttl_ms

    %{rows: rows} = repo().query!(@sql_select_expired_reserved, [expiry_threshold_ms])

    rows
    |> Enum.reduce_while(:ok, fn [media_id], _acc ->
      case state_machine().transition(media_id, :hard_deleted, {:system, nil}) do
        {:ok, :hard_deleted} ->
          {:cont, :ok}

        {:error, {:invalid_transition, _from, _to}} ->
          # Lost a race against another process/tick that already moved this
          # row past :reserved — the row is already cleaned up, nothing to do.
          {:cont, :ok}

        {:error, reason} ->
          # A genuine, unexpected failure (not the documented race no-op) —
          # do NOT swallow this as success. Halt and let Oban retry the job.
          {:halt, {:error, reason}}
      end
    end)
  end

  defp repo,
    do: Application.get_env(:nebu_http, :media_reserved_cleanup_repo_module, Nebu.Repo)

  defp state_machine,
    do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)

  defp unused_expires_ms,
    do: Application.get_env(:nebu_http, :media_unused_expires_ms, @default_unused_expires_ms)
end
