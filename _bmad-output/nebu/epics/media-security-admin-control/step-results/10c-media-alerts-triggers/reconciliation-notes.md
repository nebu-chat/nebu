# 10c Reconciliation Notes — 10a/10b actual landed shapes vs. story draft

Researched 2026-07-20 before ATDD. Story text's illustrative worker code is
**illustrative only** (story says so explicitly) — these are the concrete facts
dev-story and ATDD must use instead.

## Migration number
Highest existing migration: `000032_media_scan_stats`. New migration for
`media_alerts` MUST be `000033_media_alerts`.

## 9a — Nebu.Media.Config (server/lib/nebu/media/config.ex)
- `Nebu.Media.Config.get/0` returns **ATOM-keyed** map (e.g. `config.max_upload_size_bytes`),
  NOT string-keyed. Story draft's `config["clamav_down_alert_minutes"]` is WRONG — must be
  `config.clamav_down_alert_minutes`.
- Adding the 4 new keys to the `media_config_update_mutable` RLS policy allowlist (migration)
  is NOT sufficient by itself. `Nebu.Media.Config`'s own `@defaults`, `@key_to_atom`, and
  validation (e.g. `@nonneg_int_keys`/`validate_value/2`) must ALSO be extended with:
  `clamav_down_alert_minutes` (default 5), `signature_stale_alert_hours` (default 48),
  `backlog_depth_alert_threshold` (default 500), `scan_failed_rate_alert_pct` (default 10).
  `build_catalog/1` does `Map.take(override, Map.keys(@defaults))` — any DB key not also in
  `@defaults` is silently dropped by `get/0`.
- Existing catalog (10 keys, do not touch): `max_upload_size_bytes, max_file_size_bytes,
  max_pending_per_user, max_stall_ms, deleted_days, infected_days, orphaned_hours,
  webhook_url, released_delete_after_days, mime_denylist`.

## 10b — ClamAV status / signature age (server/lib/nebu/media/clamav.ex)
- `Nebu.Media.ClamAV.health_check/0` → `%{healthy: boolean(), changed_at: DateTime.t()}`.
  NOT a `{:down, down_since}`/`:up` tuple as the story's illustrative code assumed.
  Translate: `healthy: false` → alert-candidate, `changed_at` is the "down since" timestamp.
  Known caveat (moduledoc ~line 299): `changed_at` only moves when `healthy` actually flips —
  documented churn risk on peer-closed reconnects, already discussed/fixed in 10b's own
  code-review cycle. Treat as authoritative "down since" per 10b's landed behavior.
- `Nebu.Media.ClamAV.signature_info/0` → `{:ok, DateTime.t()} | {:error, term()}` — signature DB
  BUILD DATE, not an hours-since number. Caller computes the age delta itself
  (`DateTime.diff(DateTime.utc_now(), build_date, :hour)`).
- `Nebu.Admin.ClamAVStatusIndicator.status/0` (server/lib/nebu/admin/clamav_status_indicator.ex)
  bundles both: `%{healthy: boolean(), changed_at: DateTime.t(), signature_age: {:ok, DateTime.t()} | {:error, term()}}`.
  Its own staleness threshold read is via `Application.get_env(:nebu, Nebu.Media.ClamAV, [])`
  (NOT `Nebu.Media.Config`) — 10c must NOT reuse that read path; 10c reads its own threshold
  via `Nebu.Media.Config.get/0` per AC2 (config-driven, no hardcode).
- Seam convention actually used codebase-wide (confirmed in `Nebu.Workers.MediaScanWorker`):
  app atom **`:nebu_http`** (not `:nebu`), key **`:media_clamav_module`** (default
  `Nebu.Media.ClamAV`) — reuse this exact existing key rather than inventing
  `:media_clamav_status_module`.

## 10a — media_scan_stats (server/priv/migrations/000032_media_scan_stats.up.sql)
- No public reader module exists. `Nebu.Workers.MediaScanStatsRollupWorker` only writes
  the rollup. All reads (backlog depth, rolling error rate) are PRIVATE inline-SQL functions
  inside `Nebu.Admin.MediaHealthLive` (server/lib/nebu/admin/media_health_live.ex):
  `fetch_latest_row/0` → `%{window_start, scans_total, avg_scan_duration_ms,
  p95_scan_duration_ms, backlog_depth}` (backlog_depth is an integer from the latest row, or
  the whole map is absent/nil if table empty); `fetch_rolling_sums(limit)` →
  `%{scans_total_sum: integer, scans_failed_sum: integer, error_rate_pct: float | nil}`
  (nil when denominator 0).
- 10c must write its OWN inline SQL against `media_scan_stats` for backlog/error-rate
  (mirroring `MediaHealthLive`'s existing SQL shape), not call into a nonexistent public
  function. Per ADR-018 (no domain model, inline SQL is normal) this is consistent with
  existing convention, not a shortcut.
- Dashboard LiveView confirmed at `server/lib/nebu/admin/media_health_live.ex`,
  module `Nebu.Admin.MediaHealthLive`, route `/admin/media/health`.

## Oban / cron (server/config/config.exs)
- `:media_cleanup` queue already registered (`queues: [media_cleanup: [limit: 10], ...]`).
  Story's choice of `queue: :media_cleanup` for `MediaAlertsCheckerWorker` is correct.
- NOTE: a **different**, pre-existing `:media_alerts` QUEUE (not table) already exists from
  Story 7 (`Nebu.Workers.MediaAlertWebhookWorker`, webhook delivery). No collision — 10c's
  worker targets `:media_cleanup` per its own story text, and the new `media_alerts` TABLE is
  a distinct concept from that pre-existing queue name. Do not confuse the two in code review.
- Current crontab tail (insert new entry after `MediaScanStatsRollupWorker`):
  ```elixir
  {"*/15 * * * *", Nebu.Workers.MediaReservedUploadCleanupWorker},
  {"0 2 * * *", Nebu.Workers.MediaCleanupWorker},
  {"0 2 * * *", Nebu.Workers.MediaArchiveWorker},
  {"0 * * * *", Nebu.Workers.MediaOrphanDetectionWorker},
  {"0 2 * * *", Nebu.Workers.MediaReleasedAutoDeleteWorker},
  {"5 * * * *", Nebu.Workers.MediaScanStatsRollupWorker}
  ```

## Grants / migrations_grant_test.exs
- Path: `server/test/nebu/matrix/migrations_grant_test.exs`.
- 000032 pattern: `describe "AC1/AC2: 000032_media_scan_stats.up.sql grants"` block asserting
  table creation + `GRANT SELECT, INSERT, UPDATE, DELETE ... TO nebu_app` regex +
  `GRANT USAGE, SELECT ON SEQUENCE ... TO nebu_app` regex, plus `.down.sql` appended to
  `@down_migrations` list (asserts no GRANT statements in down migration).
- **CRITICAL — mirror exactly for 000033_media_alerts**: story's own grant is narrower —
  `GRANT SELECT, INSERT, UPDATE ON media_alerts TO nebu_app` (three verbs, no DELETE, since
  alerts are opened/updated but never deleted by app code) — the grant-regex assertion in the
  new test block MUST match this narrower 3-verb set, not copy 000032's 4-verb grant literally.
  Also assert `GRANT USAGE, SELECT ON SEQUENCE media_alerts_id_seq TO nebu_app`.
  This is the exact epic gotcha called out for this story (cf. 9a/8a's stale-grant misses) —
  double-check the migration AND its grant-test block both land with matching verb lists.

## Audit guardrail
- `Nebu.Compliance.AuditWriter.@known_actions` (server/lib/nebu/compliance/audit_writer.ex,
  lines ~91-139) does NOT need to change for this story — confirmed no `media_alert_*` action
  exists and story's guardrail explicitly forbids adding one. No action needed here, but
  worth a final grep before commit to be sure dev-story didn't add one by habit (this epic's
  documented gotcha is usually about a NEW table needing NEW actions — 10c is the deliberate
  exception, confirm this stays true).

## Test conventions
- `server/test/nebu/workers/media_scan_stats_rollup_worker_test.exs` pattern:
  `use ExUnit.Case, async: false` + `use Oban.Testing, repo: Nebu.Repo`,
  `@moduletag :integration`, `perform_job(Worker, args)`.
