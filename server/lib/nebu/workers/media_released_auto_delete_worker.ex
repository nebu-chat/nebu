defmodule Nebu.Workers.MediaReleasedAutoDeleteWorker do
  @moduledoc """
  Daily Oban-cron data-minimization sweep (media-security-admin-control/
  8d-released-auto-delete) that soft-deletes `media_files` rows sitting in
  `:released` past an OPTIONAL, admin-configured age window
  (`Nebu.Media.Config.get().released_delete_after_days`).

  This is explicitly NOT a security feature (unlike 8a's `MediaCleanupWorker`
  or 4b's scan worker) — it exists purely so an operator can honor a
  data-minimization policy for clean, never-flagged, `:released` attachments
  that have simply been sitting around for a long time. Per the epic
  (Winston-Review 3, Offene-Entscheidung #8), `released_delete_after_days`
  carries the strongest "must default to fully off" contract of any config
  value in this epic: `nil` is the only safe default, and `nil` must mean
  *nothing runs* — not "run with a window of zero."

  ## AC1 — validity gate (load-bearing, never loosen)

  `Nebu.Media.Config.get().released_delete_after_days` is read once per tick.
  `Config`'s OWN validator (`server/lib/nebu/media/config.ex`) is looser than
  this worker needs — it accepts `0` as a storable value. AC1 requires this
  worker to additionally treat `0`, any negative integer, and any non-integer
  value as "not an active window" and refuse to run (log an error, `:ok`
  no-op) rather than guess an interpretation:

    - `nil`                       -> disabled, complete no-op (AC3)
    - positive integer (`> 0`)    -> active window of that many days (AC2)
    - anything else (`0`, `< 0`,
      non-integer)                -> invalid, log + no-op (never "delete
                                      immediately", never "run forever")

  ## No `released_at` column — derive age from the state-transition ledger

  `media_files` has no dedicated "became-released-at" timestamp (verified
  against `server/priv/migrations/000001_init.up.sql`). Age is derived from
  the append-only `media_state_transitions` ledger, exactly mirroring
  `Nebu.Workers.MediaCleanupWorker`'s (8a) own `:deleted`/`:infected`
  eligibility queries: `MAX(inserted_at) WHERE to_state = 'released'`.

  Gotcha carried over from 8a's own moduledoc: the `$1` interval-days
  parameter MUST be bound as a STRING (`Integer.to_string/1`), not a raw
  integer — Postgres resolves the `||`-concatenation's type to `text` for
  `($1 || ' days')::interval`, and a raw integer causes a
  `DBConnection.EncodeError`.

  ## AC2 — soft-delete only, never a direct hard-delete

  Eligible rows are moved `:released -> :deleted` via
  `Nebu.Media.StateMachine.transition/4` with `actor: {:system, nil}` — the
  same edge Story 6a's `admin_delete/2` already uses, no guard-table change
  needed. This worker NEVER writes `storage_key = NULL` / `hard_deleted_at` /
  `state = 'hard_deleted'` itself, and NEVER calls
  `Nebu.Workers.MediaCleanupWorker` (8a) directly — the `:deleted` rows it
  produces simply flow into 8a's own existing `deleted_days`-based
  eligibility query on 8a's next run. This preserves a grace/audit window: an
  admin can still notice and reverse a wrongly-configured window (e.g. by
  lowering it back) before 8a's cron makes the deletion permanent.

  ## AC4 — one audit entry per auto-delete

  On `{:ok, :deleted}`, `Nebu.Compliance.AuditWriter.log/6` writes exactly one
  `media_released_auto_deleted` entry (registered in `AuditWriter.@known_actions`
  in this same commit — the same allowlist gotcha 4c/6a/8a/8c each flag: a
  missing entry doesn't error, it silently drops the compliance record while
  the state transition itself still succeeds).

  ## Per-row isolation

  A single file's `StateMachine.transition/4` failure is logged and does not
  abort the rest of the batch — mirrors 8a's own per-row `rescue`-wrapped
  processing loop. `perform/1` always returns `:ok`.

  ## Seams

  `Application.get_env(:nebu_http, :media_released_auto_delete_repo_module, Nebu.Repo)`,
  `:media_state_machine_module`, `:media_audit_writer_module` — the SAME seam
  keys `Nebu.Media`/8a/8c already read, swappable independently for tests.
  Config itself is read via `Nebu.Media.Config.get/0` directly (Story 9a has
  landed) — no app-env fallback path, no bespoke config-storage mechanism.

  ## Deliberate: no rescue around `Nebu.Media.Config.get/0`

  `validated_window/0` calls `Config.get/0` uncaught. This is intentional, not
  an oversight. `Config.upsert/2` is the ONLY validated write path to
  `media_config` (ADR-020) and its `validate_value/2` rejects any
  `released_delete_after_days` value other than `nil` or a non-negative
  integer — a malformed value (e.g. a non-numeric string) can never reach the
  `media_config` row through that path. `Config`'s own DB-read path
  (`decode_value/2`) additionally special-cases the empty string back to
  `nil` (the same sentinel `encode_value/2` writes for `nil` on write), so
  even that corner case can't produce a `String.to_integer/1` crash from a
  row written the normal way. The only way a genuinely non-numeric string
  could reach `Config.get/0`'s `coerce_value/2` (and raise `ArgumentError`
  there) is a raw SQL write to `media_config` that bypasses `Config` entirely
  — already an out-of-contract, unsupported scenario for this whole table
  (ADR-020's single-write-path guarantee), not something this worker
  arbitrates. Should it ever happen, `perform/1` raising is the CORRECT
  outcome: Oban's `max_attempts: 5` retries and then dead-letters the job
  (fail loud), which is strictly better than this worker silently guessing an
  interpretation for data that should not exist — the exact failure mode AC1
  exists to prevent for values that a caller CAN legitimately produce. No
  `rescue` is added here for that reason.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  require Logger

  @sql_select_released_candidates """
  SELECT mf.media_id,
         (SELECT MAX(t.inserted_at) FROM media_state_transitions t
           WHERE t.media_id = mf.media_id AND t.to_state = 'released') AS released_at
    FROM media_files mf
   WHERE mf.state = 'released'
     AND (SELECT MAX(t.inserted_at) FROM media_state_transitions t
           WHERE t.media_id = mf.media_id AND t.to_state = 'released') < NOW() - ($1 || ' days')::interval
   LIMIT 1000
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case validated_window() do
      {:ok, days} ->
        process_candidates(days)

      :disabled ->
        :ok

      :invalid ->
        Logger.error(
          "MediaReleasedAutoDeleteWorker: released_delete_after_days is set but not a " <>
            "positive integer — refusing to run rather than guessing an interpretation"
        )
    end

    :ok
  end

  # AC1: nil -> :disabled (no query, no side effect at all). A positive
  # integer -> {:ok, days}. Anything else (0, negative, non-integer) ->
  # :invalid (log + no-op, never treated as an active window).
  defp validated_window do
    case Nebu.Media.Config.get().released_delete_after_days do
      nil -> :disabled
      days when is_integer(days) and days > 0 -> {:ok, days}
      _other -> :invalid
    end
  end

  defp process_candidates(days) do
    %{rows: rows} = repo().query!(@sql_select_released_candidates, [Integer.to_string(days)])

    Enum.each(rows, fn [media_id, released_at] ->
      process_row(media_id, days, released_for_days(released_at))
    end)
  end

  # Per-row isolation: rescue-wrapped so one candidate's failure never
  # prevents the next candidate in the same tick from being processed.
  #
  # code-review MINOR fix (cycle 1, finding 1): this comment previously
  # implied this floor gate merely re-enforces the SAME boundary contract as
  # 8a's `MediaCleanupWorker` ("mirrors 8a"). It does not — 8a has NO
  # Elixir-side floor gate at all; its only boundary is the SQL's own
  # sub-day `<` comparison. This worker adds one ON TOP of that same SQL
  # filter, which changes the effective semantic: the SQL WHERE clause above
  # is a coarse, sub-day-precision candidate filter (millisecond-granular
  # `< NOW() - interval`), so a file released `released_delete_after_days`
  # days + a few hours ago is already a SQL match. The floor gate below
  # re-checks that match against `released_for_days` (floored to WHOLE days)
  # and only proceeds once it is confirmed STRICTLY more than `days` whole
  # days old. Net effect: 8d's real, effective deletion boundary is "more
  # than `released_delete_after_days` FULL/whole days old", not the SQL's
  # raw sub-day boundary — in the worst case (a file released just after a
  # tick), this means up to one extra whole day of retention beyond the raw
  # config value before deletion. This is a deliberate, safety-biased
  # choice (errs toward keeping files longer, never shorter — appropriate
  # for the largest-blast-radius worker in this epic), NOT an attempt to
  # reproduce 8a's boundary exactly; 8a's own candidate queries have no
  # equivalent whole-day re-check.
  defp process_row(_media_id, days, released_for_days) when released_for_days <= days, do: :ok

  defp process_row(media_id, days, released_for_days) do
    case state_machine().transition(media_id, :deleted, {:system, nil}, %{
           released_delete_after_days: days
         }) do
      {:ok, :deleted} ->
        audit_writer().log(
          "system:media_released_auto_delete_worker",
          "media_released_auto_deleted",
          "media",
          media_id,
          %{released_delete_after_days: days, released_for_days: released_for_days},
          "success"
        )

      {:error, reason} ->
        Logger.error("MediaReleasedAutoDeleteWorker: StateMachine.transition/4 failed",
          media_id: media_id,
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.error("MediaReleasedAutoDeleteWorker: failed processing candidate row",
        media_id: media_id,
        error: inspect(error)
      )
  end

  # `released_at` (the ledger-derived timestamp column) is a real TIMESTAMPTZ
  # in production — Postgrex decodes it as a %DateTime{} struct here (this
  # worker pulls it into Elixir, unlike 8a's own queries, which never need
  # the timestamp itself beyond a SQL-side comparison). The unit tests'
  # FakeRepo models the same column as a plain integer millisecond epoch
  # (mirroring 8a's own fake convention) rather than a DateTime, so this
  # helper handles both representations.
  defp released_for_days(%DateTime{} = released_at) do
    div(DateTime.diff(DateTime.utc_now(), released_at, :second), 86_400)
  end

  defp released_for_days(%NaiveDateTime{} = released_at) do
    div(NaiveDateTime.diff(NaiveDateTime.utc_now(), released_at), 86_400)
  end

  defp released_for_days(released_at_ms) when is_integer(released_at_ms) do
    div(System.system_time(:millisecond) - released_at_ms, 24 * 60 * 60 * 1000)
  end

  defp repo,
    do: Application.get_env(:nebu_http, :media_released_auto_delete_repo_module, Nebu.Repo)

  defp state_machine,
    do: Application.get_env(:nebu_http, :media_state_machine_module, Nebu.Media.StateMachine)

  defp audit_writer,
    do: Application.get_env(:nebu_http, :media_audit_writer_module, Nebu.Compliance.AuditWriter)
end
