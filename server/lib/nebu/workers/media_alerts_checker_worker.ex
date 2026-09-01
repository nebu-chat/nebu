defmodule Nebu.Workers.MediaAlertsCheckerWorker do
  @moduledoc """
  Per-minute Oban-cron checker (media-security-admin-control/10c-media-alerts-triggers)
  that evaluates four scan-pipeline operational conditions — ClamAV
  connectivity, freshclam signature staleness, `media_scan_stats` backlog
  depth, and rolling scan-failure rate — against `Nebu.Media.Config.get/0`-backed
  thresholds (AC2), opening a `media_alerts` row the moment a condition first
  crosses its threshold and auto-resolving that same row the moment the
  checker observes the condition has cleared (AC3) — no admin-facing
  dismiss/acknowledge action exists (Dev Agent Guardrails).

  Runs on `:media_cleanup` (the shared housekeeping queue Story 2e/8a already
  established, per ADR-025 — not a new queue), on a `"* * * * *"` (every
  minute) cron cadence: tighter than 8a's daily/2e's 15-minute cadence
  because the default `clamav_down_alert_minutes` threshold is 5 minutes and
  a coarser cadence would materially delay detection (AC2).

  ## Reconciled facts this module bakes in (see
  `_bmad-output/nebu/epics/media-security-admin-control/step-results/
  10c-media-alerts-triggers/reconciliation-notes.md` — authoritative over
  this story's own illustrative Technical Requirements code):

    * `Nebu.Media.Config.get/0` (9a) is ATOM-keyed
      (`config.clamav_down_alert_minutes`), not string-keyed.
    * `Nebu.Media.ClamAV.health_check/0` (10b) returns `%{healthy: boolean(),
      changed_at: DateTime.t()}` — NOT a `{:down, down_since}`/`:up` tuple.
      `healthy: false` is translated to "down"; `changed_at` is the "down
      since" timestamp. `Nebu.Media.ClamAV.signature_info/0` returns
      `{:ok, DateTime.t()} | {:error, term()}` (the signature DB's build
      date) — this worker computes the age delta itself.
    * Seam convention: `Application.get_env(:nebu_http, :media_clamav_module,
      Nebu.Media.ClamAV)` — the EXACT existing key
      `Nebu.Workers.MediaScanWorker` already uses, reused here rather than
      inventing a new seam name. One fake module backs both
      `health_check/0` and `signature_info/0` in tests.
    * There is no reusable public reader for `media_scan_stats` backlog
      depth / rolling scan-failed rate (10a only ships a rollup WRITER). This
      worker owns its own inline SQL (ADR-018) against `media_scan_stats`,
      mirroring `Nebu.Admin.MediaHealthLive`'s existing query shape
      (`fetch_latest_row/0`/`fetch_rolling_sums/1`) rather than calling into
      a nonexistent public function. Both `backlog_depth` and
      `scan_failed_rate` read the single most recent `media_scan_stats` row
      (`ORDER BY window_start DESC LIMIT 1`) — 10a's rollup only ever
      produces one row per hour, so this naturally satisfies AC2's "rolling
      1h" language without duplicating 10a's own separately-rendered 24h/7d
      dashboard aggregates.

  ## Idempotent check-and-open under real concurrency (AC5/AT8)

  `open_alert/5`'s `INSERT ... SELECT ... WHERE NOT EXISTS` makes a second
  call while the condition is still active a no-op in the common (sequential)
  case. Under genuine concurrency (two overlapping checker runs under READ
  COMMITTED), both transactions can pass the `NOT EXISTS` check before either
  commits — the `ON CONFLICT (...) WHERE resolved_at IS NULL DO NOTHING`
  clause (inferring the migration's own partial unique index) is the
  belt-and-suspenders guard that makes the loser of that race a no-op rather
  than a unique-violation error.
  """

  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  alias Nebu.Repo

  # media_id is TEXT (matching media_files.media_id — see the migration's own
  # note: the story's illustrative UUID type does not match reality), so the
  # sentinel here is a plain string that can never collide with a real
  # media_id, mirroring the migration's own partial unique index expression.
  @sentinel_media_id "__pipeline_level__"

  @sql_open_alert """
  INSERT INTO media_alerts (alert_type, severity, message, media_id, condition_metadata)
  SELECT $1, $2, $3, $4, $5
  WHERE NOT EXISTS (
      SELECT 1 FROM media_alerts
      WHERE alert_type = $1
        AND media_id IS NOT DISTINCT FROM $4
        AND resolved_at IS NULL
  )
  ON CONFLICT (alert_type, COALESCE(media_id, '#{@sentinel_media_id}'))
  WHERE resolved_at IS NULL
  DO NOTHING
  """

  @sql_resolve_alert """
  UPDATE media_alerts
     SET resolved_at = now()
   WHERE alert_type = $1
     AND media_id IS NOT DISTINCT FROM $2
     AND resolved_at IS NULL
  """

  @sql_latest_scan_stats """
  SELECT scans_total, scans_failed, backlog_depth
    FROM media_scan_stats
   ORDER BY window_start DESC
   LIMIT 1
  """

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    config = media_config().get()
    latest_scan_stats = fetch_latest_scan_stats()

    check_clamav_disconnected(config)
    check_signature_stale(config)
    check_backlog_depth(config, latest_scan_stats)
    check_scan_failed_rate(config, latest_scan_stats)

    :ok
  end

  # ── ClamAV disconnected (critical) ──────────────────────────────────────

  defp check_clamav_disconnected(config) do
    %{healthy: healthy, changed_at: changed_at} = clamav().health_check()

    if healthy do
      resolve_alert("clamav_disconnected", nil)
    else
      minutes_down = DateTime.diff(DateTime.utc_now(), changed_at, :second) / 60

      if minutes_down > config.clamav_down_alert_minutes do
        open_alert(
          "clamav_disconnected",
          :critical,
          nil,
          "ClamAV unreachable for #{trunc(minutes_down)} minutes",
          %{
            "down_since" => DateTime.to_iso8601(changed_at),
            "threshold_minutes" => config.clamav_down_alert_minutes
          }
        )
      else
        :ok
      end
    end
  end

  # ── Signature stale (warning) ───────────────────────────────────────────

  defp check_signature_stale(config) do
    case clamav().signature_info() do
      {:ok, built_at} ->
        age_hours = DateTime.diff(DateTime.utc_now(), built_at, :second) / 3600

        if age_hours > config.signature_stale_alert_hours do
          open_alert(
            "signature_stale",
            :warning,
            nil,
            "Signature database is #{trunc(age_hours)} hours old",
            %{
              "signature_built_at" => DateTime.to_iso8601(built_at),
              "threshold_hours" => config.signature_stale_alert_hours
            }
          )
        else
          resolve_alert("signature_stale", nil)
        end

      {:error, _reason} ->
        # Unknown signature age (connection error, timeout, unparseable
        # reply) is not itself evidence the condition has cleared — leave
        # any existing open alert as-is rather than guessing.
        :ok
    end
  end

  # ── Backlog depth (warning) ─────────────────────────────────────────────

  defp check_backlog_depth(_config, nil), do: :ok

  defp check_backlog_depth(config, %{backlog_depth: backlog_depth}) do
    if backlog_depth > config.backlog_depth_alert_threshold do
      open_alert(
        "backlog_depth",
        :warning,
        nil,
        "Scan backlog depth is #{backlog_depth}",
        %{"backlog_depth" => backlog_depth, "threshold" => config.backlog_depth_alert_threshold}
      )
    else
      resolve_alert("backlog_depth", nil)
    end
  end

  # ── Scan failure rate (warning) ──────────────────────────────────────────

  defp check_scan_failed_rate(_config, nil), do: :ok

  defp check_scan_failed_rate(config, %{scans_total: scans_total, scans_failed: scans_failed}) do
    rate_pct = failure_rate_pct(scans_failed, scans_total)

    if not is_nil(rate_pct) and rate_pct > config.scan_failed_rate_alert_pct do
      open_alert(
        "scan_failed_rate",
        :warning,
        nil,
        "Scan failure rate is #{Float.round(rate_pct, 1)}%",
        %{"rate_pct" => rate_pct, "threshold_pct" => config.scan_failed_rate_alert_pct}
      )
    else
      resolve_alert("scan_failed_rate", nil)
    end
  end

  # AC7-style guard (never a literal NaN/Infinity from an unguarded
  # division) — nil (not 0.0) when the denominator is 0, mirroring
  # Nebu.Admin.MediaHealthLive.error_rate_pct/2.
  defp failure_rate_pct(_failed, 0), do: nil
  defp failure_rate_pct(failed, total), do: failed / total * 100

  defp fetch_latest_scan_stats do
    case Ecto.Adapters.SQL.query!(Repo, @sql_latest_scan_stats, []) do
      %{rows: [[scans_total, scans_failed, backlog_depth]]} ->
        %{scans_total: scans_total, scans_failed: scans_failed, backlog_depth: backlog_depth}

      %{rows: []} ->
        nil
    end
  end

  # Idempotent check-and-open (AC5) — inline SQL per ADR-018, no domain
  # model / repository layer. See moduledoc "Idempotent check-and-open under
  # real concurrency" for why both the WHERE NOT EXISTS and the ON CONFLICT
  # DO NOTHING are needed.
  defp open_alert(alert_type, severity, media_id, message, condition_metadata) do
    Ecto.Adapters.SQL.query!(Repo, @sql_open_alert, [
      alert_type,
      Atom.to_string(severity),
      message,
      media_id,
      condition_metadata
    ])

    :ok
  end

  # Auto-resolve (AC3) — sets resolved_at the moment the condition clears; no
  # admin action.
  defp resolve_alert(alert_type, media_id) do
    Ecto.Adapters.SQL.query!(Repo, @sql_resolve_alert, [alert_type, media_id])
    :ok
  end

  defp media_config, do: Application.get_env(:nebu_http, :media_config_module, Nebu.Media.Config)
  defp clamav, do: Application.get_env(:nebu_http, :media_clamav_module, Nebu.Media.ClamAV)
end
