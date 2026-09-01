defmodule Nebu.Workers.MediaScanStatsRollupWorker do
  @moduledoc """
  Hourly Oban-cron rollup (media-security-admin-control/10a-scan-stats-rollup)
  that aggregates the just-completed hour's `media_state_transitions` rows
  (Story 1a/4b) into `media_scan_stats` — a derived, re-computable table the
  admin dashboard (`Nebu.Admin.MediaHealthLive`) reads instead of querying the
  append-only compliance ledger live on every page load.

  Plain Elixir module, no Ecto schema (ADR-018) — every query below is inline
  SQL via `Ecto.Adapters.SQL.query!/3` against `Nebu.Repo`, following the same
  `repo()`-seam convention `Nebu.Workers.MediaCleanupWorker` (Story 8a)
  established.

  ## Bug found and fixed vs. the story's own illustrative SQL (dev-story, not a
  ## design decision — verified empirically against a real Postgres before
  ## trusting the draft, per this epic's own recurring gotcha pattern)

  The story's Technical Requirements sketch this shape for the duration CTE:

  ```sql
  SELECT media_id, inserted_at AS started_at,
         LEAD(inserted_at) OVER (PARTITION BY media_id ORDER BY inserted_at) AS ended_at,
         LEAD(to_state)    OVER (PARTITION BY media_id ORDER BY inserted_at) AS ended_state
    FROM media_state_transitions
   WHERE to_state = 'scanning'
  ```

  This is broken: SQL evaluates `WHERE` (and therefore narrows the FROM-clause
  row set) BEFORE any window function runs. Filtering to `to_state = 'scanning'`
  first means `LEAD(...) OVER (PARTITION BY media_id ORDER BY inserted_at)` only
  ever sees OTHER `:scanning` rows for that `media_id` in the (already-filtered)
  partition — for the common case of a single scan attempt with no retries,
  there is exactly one such row, so `LEAD` always returns `NULL`, and every
  duration sample is silently dropped (`ended_state IN ('released', 'infected')`
  never matches a `NULL`). Confirmed empirically: seeding a normal
  `:quarantined -> :scanning -> :released` sequence and running this draft
  query against a live Postgres returns `sample_count = 0` for every fixture,
  regardless of how many real scans occurred.

  Fixed by computing `LEAD` over the FULL, unfiltered per-`media_id` transition
  sequence first (so it always sees the TRUE next transition, whatever it is —
  a retry back to `:quarantined`, or a terminal outcome), and filtering to
  `to_state = 'scanning'` starts / `next_to_state IN ('released', 'infected')`
  ends only in an outer step. This also correctly excludes `:scan_failed`
  sequences from the duration stats without any special-casing (AC/AT3): a
  `:scanning` entry immediately followed by a retry-`:quarantined` transition
  has `next_to_state = 'quarantined'`, which the outer filter already rejects.

  ## `scans_released`/`scans_infected` are keyed on `from_state = 'scanning'`

  Per the story's own Technical Requirements and confirmed against the real
  `Nebu.Workers.MediaScanWorker` (Story 4b): `release/2`/`infect/2` only ever
  transition FROM `:scanning`. Filtering on `from_state = 'scanning' AND
  to_state = 'released'/'infected'` (not just `to_state = '...'` alone)
  deliberately EXCLUDES non-scan-driven `:released` transitions — Story 6c's
  `:infected -> :released` admin override, Story 6a's `:admin_blocked ->
  :released` unblock — from this scan-throughput rollup; those are admin
  actions, not scan outcomes. `scans_failed` is keyed on `from_state =
  'quarantined' AND to_state = 'scan_failed'`, matching `scan_error/4`'s real
  final-attempt transition exactly (the entry-transition-rejected / immediate
  `:quarantined -> :scan_failed` edge the guard table also allows has no real
  caller in `MediaScanWorker` today).
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @sql_scans_released_infected """
  SELECT COUNT(*) FROM media_state_transitions
   WHERE from_state = 'scanning' AND to_state = $1
     AND inserted_at >= $2 AND inserted_at < $2 + INTERVAL '1 hour'
  """

  @sql_scans_failed """
  SELECT COUNT(*) FROM media_state_transitions
   WHERE from_state = 'quarantined' AND to_state = 'scan_failed'
     AND inserted_at >= $1 AND inserted_at < $1 + INTERVAL '1 hour'
  """

  # See moduledoc "Bug found and fixed" — LEAD is computed over the FULL
  # per-media_id transition sequence (the `ordered` CTE has no WHERE at all,
  # only an optional media_id narrowing to bound cost), and only THEN
  # filtered to `to_state = 'scanning'` starts / terminal ends in `durations`.
  @sql_duration_stats """
  WITH candidate_media_ids AS (
      SELECT DISTINCT media_id FROM media_state_transitions
       WHERE to_state = 'scanning'
         AND inserted_at >= $1 AND inserted_at < $1 + INTERVAL '1 hour'
  ),
  ordered AS (
      SELECT
          media_id,
          inserted_at,
          to_state,
          LEAD(inserted_at) OVER (PARTITION BY media_id ORDER BY inserted_at) AS next_inserted_at,
          LEAD(to_state)    OVER (PARTITION BY media_id ORDER BY inserted_at) AS next_to_state
        FROM media_state_transitions
       WHERE media_id IN (SELECT media_id FROM candidate_media_ids)
  ),
  durations AS (
      SELECT EXTRACT(EPOCH FROM (next_inserted_at - inserted_at)) * 1000 AS duration_ms
        FROM ordered
       WHERE to_state = 'scanning'
         AND next_to_state IN ('released', 'infected')
         AND inserted_at >= $1 AND inserted_at < $1 + INTERVAL '1 hour'
  )
  SELECT
      ROUND(AVG(duration_ms))::INTEGER AS avg_scan_duration_ms,
      ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms))::INTEGER AS p95_scan_duration_ms
    FROM durations
  """

  # AC1/Technical Requirements: a live, non-windowed snapshot — never filtered
  # by inserted_at/window_start, unlike every other query above.
  @sql_backlog_depth """
  SELECT COUNT(*) FROM media_files WHERE state IN ('quarantined', 'scanning')
  """

  @sql_upsert """
  INSERT INTO media_scan_stats
    (window_start, scans_released, scans_infected, scans_failed,
     avg_scan_duration_ms, p95_scan_duration_ms, backlog_depth)
  VALUES ($1, $2, $3, $4, $5, $6, $7)
  ON CONFLICT (window_start) DO UPDATE SET
    scans_released = EXCLUDED.scans_released,
    scans_infected = EXCLUDED.scans_infected,
    scans_failed = EXCLUDED.scans_failed,
    avg_scan_duration_ms = EXCLUDED.avg_scan_duration_ms,
    p95_scan_duration_ms = EXCLUDED.p95_scan_duration_ms,
    backlog_depth = EXCLUDED.backlog_depth
  """

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    window_start = target_hour(args)
    stats = aggregate_hour(window_start)
    upsert(window_start, stats)
    :ok
  end

  @doc """
  The most recently *fully elapsed* hour relative to now — never the current,
  still-accumulating hour. This is what the cron entry (`args: %{}`) always
  uses in production.
  """
  @spec current_target_hour() :: DateTime.t()
  def current_target_hour do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> then(&%{&1 | minute: 0, second: 0})
    |> DateTime.add(-1, :hour)
  end

  # Test-only override seam (found necessary empirically, not part of the
  # story's own draft): every acceptance test that seeds
  # media_state_transitions fixtures and asserts EXACT counts was flaky when
  # anchored to `current_target_hour/0` — a real-clock "previous complete
  # hour" is NOT actually isolated from the rest of this codebase's ~2500-test
  # suite, which takes several minutes to run end-to-end and routinely
  # straddles a real hour boundary; unrelated tests elsewhere that drive the
  # REAL Nebu.Workers.MediaScanWorker/StateMachine with default `NOW()`
  # timestamps can retroactively land inside whatever this worker later
  # computes as "the previous hour" once the wall clock has moved on.
  # Accepting an optional `"window_start"` (ISO8601 string) job arg lets tests
  # target a fixed, arbitrary historical hour that can never collide with
  # real production data OR with any other concurrently-running test — while
  # the cron entry (`{"5 * * * *", ...}`, always `args: %{}`) is completely
  # unaffected and keeps using `current_target_hour/0` exactly as designed.
  defp target_hour(%{"window_start" => iso}) when is_binary(iso) do
    {:ok, dt, _offset} = DateTime.from_iso8601(iso)
    dt
  end

  defp target_hour(_args), do: current_target_hour()

  defp aggregate_hour(window_start) do
    %{rows: [[released]]} =
      repo().query!(@sql_scans_released_infected, ["released", window_start])

    %{rows: [[infected]]} =
      repo().query!(@sql_scans_released_infected, ["infected", window_start])

    %{rows: [[failed]]} = repo().query!(@sql_scans_failed, [window_start])

    %{rows: [[avg_ms, p95_ms]]} = repo().query!(@sql_duration_stats, [window_start])

    %{rows: [[backlog]]} = repo().query!(@sql_backlog_depth, [])

    %{
      scans_released: released,
      scans_infected: infected,
      scans_failed: failed,
      avg_scan_duration_ms: avg_ms,
      p95_scan_duration_ms: p95_ms,
      backlog_depth: backlog
    }
  end

  defp upsert(window_start, stats) do
    repo().query!(@sql_upsert, [
      window_start,
      stats.scans_released,
      stats.scans_infected,
      stats.scans_failed,
      stats.avg_scan_duration_ms,
      stats.p95_scan_duration_ms,
      stats.backlog_depth
    ])
  end

  defp repo, do: Application.get_env(:nebu_http, :media_scan_stats_repo_module, Nebu.Repo)
end
