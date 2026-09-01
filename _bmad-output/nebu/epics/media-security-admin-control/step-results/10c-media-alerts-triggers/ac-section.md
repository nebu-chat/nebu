## User Story

As an admin, I want the scan pipeline's own operational health (ClamAV connectivity, signature
freshness, scan backlog, and scan failure rate) to raise a visible, self-clearing alert the
moment something goes wrong — without me having to notice a degrading number on a dashboard —
so that I find out about an incident promptly and don't have to remember to manually dismiss
the alert once it's fixed.

## Acceptance Criteria

1. **AC1 — `media_alerts` table schema.** A new migration creates:
   ```sql
   CREATE TYPE media_alert_severity AS ENUM ('warning', 'critical');

   CREATE TABLE media_alerts (
       id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
       alert_type         TEXT NOT NULL CHECK (alert_type IN (
                               'clamav_disconnected',
                               'signature_stale',
                               'backlog_depth',
                               'scan_failed_rate'
                           )),
       severity           media_alert_severity NOT NULL,
       message            TEXT NOT NULL,
       media_id           UUID NULL REFERENCES media_files (media_id),
       condition_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
       opened_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
       resolved_at        TIMESTAMPTZ NULL
   );
   ```
   `alert_type` is a `TEXT` + `CHECK` list, not an `ENUM`, deliberately — unlike
   `media_state`/`media_transition_actor_type` (1a), this list is expected to grow as new
   operational conditions are added (per Dev Agent Guardrails, extending a `CHECK` constraint
   is a single-migration, no-ceremony change; growing a Postgres `ENUM` mid-transaction has the
   well-known `ALTER TYPE ... ADD VALUE` restrictions 4a's story file already had to work around
   for `scan_failed`). `severity` stays a genuine `ENUM` — matching the epic's own schema sketch
   verbatim — since its two-value domain is stable. `media_id` is nullable: three of the four
   alert types (`clamav_disconnected`, `signature_stale`, `backlog_depth`, `scan_failed_rate`)
   are pipeline-level, not tied to one file, and always carry `media_id = NULL`;
   `condition_metadata` (e.g. `{"down_since": "...", "threshold_minutes": 5}`) carries the
   numbers an admin needs to judge severity without re-querying 10a/10b's live metrics.
2. **AC2 — Periodic checker (Oban cron) evaluates all four conditions and opens/updates
   alerts.** A new `Nebu.Workers.MediaAlertsCheckerWorker` (`use Oban.Worker, queue:
   :media_cleanup, max_attempts: 5` — reusing the shared housekeeping queue Story 2e/8a already
   established per ADR-025, not a new queue) runs on an `Oban.Plugins.Cron` schedule of
   `"* * * * *"` (every minute — tighter than 8a's daily/2e's 15-minute cadence, because the
   default `clamav_down_alert_minutes` threshold is 5 minutes and a coarser cron cadence would
   materially delay detection). Each run evaluates, independently:
   - **ClamAV disconnected** (`critical`): Story 3/10b's ClamAV connection status reports
     down, and has been down for longer than the configurable `clamav_down_alert_minutes`
     threshold (`media_config` key, default `5`).
   - **Signature stale** (`warning`): Story 10b's freshclam/signature-age reading exceeds the
     configurable `signature_stale_alert_hours` threshold (`media_config` key, default `48`).
   - **Backlog depth** (`warning`): Story 10a's rollup-derived `:quarantined` + `:scanning`
     backlog count exceeds the configurable `backlog_depth_alert_threshold` (`media_config`
     key, default `500`).
   - **Scan failure rate spike** (`warning`): Story 10a's rolling 1h `scan_failed`-rate exceeds
     the configurable `scan_failed_rate_alert_pct` (`media_config` key, default `10`).

   Each threshold is read via `Nebu.Media.Config.get/0` (Story 9a) — never hardcoded — so an
   admin can retune sensitivity without a deploy.
3. **AC3 — Alerts auto-resolve without manual admin action.** On every checker run, for each
   of the four condition types: if an open alert of that type exists (`resolved_at IS NULL`)
   and the underlying condition no longer holds, the checker sets `resolved_at = now()` on that
   row. There is no admin-facing "dismiss"/"acknowledge" action in this story's scope — the
   *only* way an alert's `resolved_at` gets set is the checker observing the condition has
   cleared. (A manual override/dismiss action, if ever wanted, is out of scope here — see Dev
   Agent Guardrails.)
4. **AC4 — Dashboard shows open alerts prominently.** The 10a/10b dashboard section (expected
   at `/admin/media/health`, per the epic's Story 10a scope — exact LiveView module name to be
   confirmed against 10a's landed code) renders all rows where `resolved_at IS NULL`, ordered
   `critical` before `warning`, most-recently-opened first within each severity, above the
   throughput/backlog/ClamAV-status metrics sections 10a/10b already render. This is additive to
   — does not replace — the Story 5b/7 nav attention-badges, which flag individual
   `:infected`/`scan_failed` *files*, a different concern from this story's pipeline-level
   operational alerts.
5. **AC5 — No duplicate open alerts for the same ongoing condition (idempotent
   check-and-open).** Running the checker twice in a row while a condition is still active
   (e.g. ClamAV is still down on both runs) opens exactly one `media_alerts` row for that
   condition, not two. The check for "does an open alert of this type already exist" and the
   `INSERT` of a new one happen atomically enough that two back-to-back (or, in a
   multi-node cluster, concurrent) checker runs cannot both insert a duplicate — see Technical
   Requirements for the exact `INSERT ... WHERE NOT EXISTS` + partial-unique-index
   belt-and-suspenders approach.
