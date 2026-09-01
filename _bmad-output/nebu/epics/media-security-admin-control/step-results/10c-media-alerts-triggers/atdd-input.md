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

## Acceptance Tests

Test file: `server/test/nebu/workers/media_alerts_checker_worker_test.exs` (`use
Oban.Testing, repo: Nebu.Repo`, `Oban.Testing.perform_job/3` — matching Story 4b's/2e's
established Oban worker test convention), with the ClamAV-status/signature-age/scan-stats
readers swapped for injectable fakes via the same `Application.get_env(:nebu,
:media_..._module, ...)` seam pattern `Nebu.Media.Config`/`MediaScanWorker` already use.

1. `test "clamav_disconnected alert opens once ClamAV has been down longer than the
   configured threshold"` — fake ClamAV-status reader reports `down_since: 6 minutes ago`,
   threshold `5`; `perform_job/3` inserts exactly one `media_alerts` row with `alert_type:
   "clamav_disconnected"`, `severity: :critical`, `media_id: nil`, `resolved_at: nil`.
2. `test "clamav_disconnected alert does not open while ClamAV has been down for less than
   the threshold"` — `down_since: 2 minutes ago`, threshold `5`; no row inserted.
3. `test "signature_stale alert opens once signature age exceeds the configured threshold"`
   — analogous to (1) for the freshclam-age reader / `signature_stale_alert_hours`.
4. `test "backlog_depth alert opens once the quarantined+scanning backlog exceeds the
   configured threshold"` — analogous to (1), reading the fake 10a-rollup-backed backlog count.
5. `test "scan_failed_rate alert opens once the rolling 1h scan_failed rate exceeds the
   configured threshold"` — analogous to (1), reading the fake 10a rolling error-rate value.
6. `test "an open alert auto-resolves on the next checker run once its condition clears"` —
   table-driven over all four alert types: seed an open `media_alerts` row for the type, run
   the checker with the fake reader now reporting a healthy value, assert `resolved_at` is set
   (non-nil) on exactly that row and no new row is inserted.
7. `test "no duplicate open alerts for a still-ongoing condition across two consecutive
   checker runs"` — condition stays active across two sequential `perform_job/3` calls; asserts
   exactly one open `media_alerts` row exists after both runs (not two), for each of the four
   alert types.
8. `test "two concurrent checker runs racing on the same still-ongoing condition still leave
   exactly one open alert row"` — spawns two overlapping `perform_job/3` calls against a real
   (non-faked) `Nebu.Repo` connection with the condition held constant; asserts the partial
   unique index (Technical Requirements) causes the loser of the race to no-op rather than
   error or duplicate, and exactly one open row remains. Regression guard for AC5 under real
   concurrency, not just sequential idempotency.
9. `test "a resolved alert does not block a new alert from opening if the same condition
   recurs later"` — seed a *resolved* `media_alerts` row for `clamav_disconnected`, then run
   the checker with the condition active again; asserts a **new** row is opened (the
   `WHERE resolved_at IS NULL` scope means a past resolution never suppresses a fresh
   occurrence).
10. `test "dashboard LiveView renders open alerts above the metrics sections, critical before
    warning, most-recent first"` — LiveView test (Floki-assertable HTML, matching Story
    5a/5b's established LiveView test conventions) seeding a mix of open/resolved,
    critical/warning rows; asserts only open rows render, in the documented order, and that
    resolved rows are absent from the prominent alert list.

## Technical Requirements

### Migration

`server/priv/migrations/0000XX_media_alerts.up.sql` (number **TBD at merge time** — Story 9a
claims `000024`; if Story 10a's own `media_scan_stats` migration lands first it will claim the
next number, so this migration is whatever is next available after 10a's — verify the actual
HEAD file under `server/priv/migrations/` before assigning a number, per the same collision-risk
convention 4a/4b/9a already document):

```sql
-- ─── media_alerts ───────────────────────────────────────────────────────────
-- Operational/monitoring alerts for the scan pipeline (backlog, ClamAV connectivity,
-- signature freshness, scan-failure rate). Distinct from media_state_transitions (1a,
-- ADR-031): this table is NOT an append-only compliance ledger — rows are opened and later
-- updated in place (resolved_at) by the periodic checker. No immutability trigger, no
-- RLS insert-only/update-mutable split.
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

-- Belt-and-suspenders for AC5's idempotent check-and-open: at most one OPEN alert per
-- (alert_type, media_id) at a time. COALESCE folds the pipeline-level alerts' NULL media_id
-- to a fixed sentinel so Postgres's "two NULLs are never equal" default unique-index
-- semantics don't silently allow duplicate pipeline-level open rows.
CREATE UNIQUE INDEX media_alerts_open_unique_idx
    ON media_alerts (alert_type, COALESCE(media_id, '00000000-0000-0000-0000-000000000000'::uuid))
    WHERE resolved_at IS NULL;

CREATE INDEX media_alerts_open_idx ON media_alerts (severity, opened_at DESC)
    WHERE resolved_at IS NULL;

GRANT SELECT, INSERT, UPDATE ON media_alerts TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_alerts_id_seq TO nebu_app;

-- Extend media_config's mutable-key allowlist (ADR-027, Story 9a) with this story's own
-- threshold keys — same incremental-extension precedent 9a's own migration documents for
-- 10c/10d, and the one server_config's 000007/000013/000016/000018 already established.
ALTER POLICY media_config_update_mutable ON media_config
    USING (key IN (
        'max_upload_size_bytes',
        'max_file_size_bytes',
        'max_pending_per_user',
        'max_stall_ms',
        'deleted_days',
        'infected_days',
        'orphaned_hours',
        'webhook_url',
        'released_delete_after_days',
        'mime_denylist',
        'clamav_down_alert_minutes',
        'signature_stale_alert_hours',
        'backlog_depth_alert_threshold',
        'scan_failed_rate_alert_pct'
    ));
```

`.down.sql`: `DROP INDEX media_alerts_open_unique_idx, media_alerts_open_idx; DROP TABLE
media_alerts; DROP TYPE media_alert_severity;` and revert the `media_config_update_mutable`
policy back to 9a's original key list.

**`signature_stale_alert_hours`'s default of `48` is this story's own judgment call, not a
number the epic document specifies** (the epic's Story 10c scope only gives explicit defaults
for the ClamAV-down (5 min) and backlog-depth (500) thresholds, and a scan-failure-rate default
of 10%/1h — it does not name a signature-staleness default because Story 10b, which owns the
freshclam-age *reading*, had not been written when this story was authored). Confirm this
default against 10b's story file/ADR once it lands; treat `48` as a placeholder the dev agent
should double check, not a hard requirement.

### `Nebu.Workers.MediaAlertsCheckerWorker`

`server/lib/nebu/workers/media_alerts_checker_worker.ex`:

```elixir
defmodule Nebu.Workers.MediaAlertsCheckerWorker do
  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @impl Oban.Worker
  def perform(_job) do
    config = media_config().get()

    check_clamav_disconnected(config)
    check_signature_stale(config)
    check_backlog_depth(config)
    check_scan_failed_rate(config)

    :ok
  end

  defp check_clamav_disconnected(config) do
    case clamav_status().status() do
      {:down, down_since} ->
        minutes_down = DateTime.diff(DateTime.utc_now(), down_since, :second) / 60

        if minutes_down > config["clamav_down_alert_minutes"] do
          open_alert("clamav_disconnected", :critical, nil,
            "ClamAV unreachable for #{trunc(minutes_down)} minutes",
            %{down_since: down_since, threshold_minutes: config["clamav_down_alert_minutes"]})
        end

      :up ->
        resolve_alert("clamav_disconnected", nil)
    end
  end

  # check_signature_stale/1, check_backlog_depth/1, check_scan_failed_rate/1 follow the
  # identical open-if-over-threshold / resolve-if-under-threshold shape, reading their
  # respective source (10b's signature-age reader, 10a's rollup-backed backlog count and
  # rolling scan_failed rate) instead of clamav_status().status/0.

  # Idempotent check-and-open (AC5) — inline SQL per ADR-018, no domain model / repository
  # layer. The WHERE NOT EXISTS makes a second call while the condition is still active a
  # no-op; the partial unique index (migration) is the belt-and-suspenders guard against a
  # concurrent second insert racing between the NOT EXISTS check and the INSERT.
  defp open_alert(alert_type, severity, media_id, message, condition_metadata) do
    Nebu.Repo.query!(
      """
      INSERT INTO media_alerts (alert_type, severity, message, media_id, condition_metadata)
      SELECT $1, $2, $3, $4, $5
      WHERE NOT EXISTS (
          SELECT 1 FROM media_alerts
          WHERE alert_type = $1
            AND media_id IS NOT DISTINCT FROM $4
            AND resolved_at IS NULL
      )
      """,
      [alert_type, Atom.to_string(severity), message, media_id, condition_metadata]
    )
  end

  # Auto-resolve (AC3) — sets resolved_at the moment the condition clears; no admin action.
  defp resolve_alert(alert_type, media_id) do
    Nebu.Repo.query!(
      """
      UPDATE media_alerts
      SET resolved_at = now()
      WHERE alert_type = $1
        AND media_id IS NOT DISTINCT FROM $2
        AND resolved_at IS NULL
      """,
      [alert_type, media_id]
    )
  end

  defp media_config, do: Application.get_env(:nebu, :media_config_module, Nebu.Media.Config)
  defp clamav_status, do: Application.get_env(:nebu, :media_clamav_status_module, Nebu.Media.ClamAV)
  # scan_stats(), analogous seam for Story 10a's rollup reader
end
```

(Illustrative — adapt exact reader function names/return shapes to whatever 10a/10b actually
land with; the load-bearing points are: thresholds always read from `Nebu.Media.Config.get/0`,
the `WHERE NOT EXISTS` idempotent open, the plain `UPDATE ... SET resolved_at = now()`
auto-resolve, and no admin-facing write path to this table at all.)

### Cron registration

`server/config/config.exs`, added to the existing `crontab:` list alongside 2e's/8a's entries:

```elixir
{"* * * * *", Nebu.Workers.MediaAlertsCheckerWorker}
```

### Dashboard integration

The open-alerts list is read via a plain `SELECT * FROM media_alerts WHERE resolved_at IS NULL
ORDER BY severity, opened_at DESC` (severity ordering via a `CASE severity WHEN 'critical' THEN
0 ELSE 1 END`, since `ENUM` alphabetical order does not match "critical before warning"),
exposed through a small `Nebu.Media.Alerts.list_open/0` read function (public API, ADR-020) the
10a/10b dashboard LiveView calls — the LiveView does not query `media_alerts` directly, mirroring
`Nebu.Media.Config.get/0`'s "one seam, no raw queries from callers" precedent.

## Dev Agent Guardrails

### `media_alerts` is operational data, not a compliance ledger — do not copy 1a/ADR-031's pattern

`media_state_transitions` (Story 1a) is a **DB-enforced append-only** table: a `BEFORE UPDATE
OR DELETE` trigger raises `SQLSTATE 23001` for every role including the owner, because it is a
compliance ledger where retroactive edits would be a tamper risk. **`media_alerts` is the
opposite kind of table on purpose.** It is operational/monitoring state: the same periodic
checker that opens a row is expected to come back a minute later and `UPDATE` that exact row's
`resolved_at`. Do **not**:
- add a `BEFORE UPDATE` trigger blocking updates to `media_alerts`,
- model its RLS policies on `audit_log`'s insert-only/update-mutable-allowlist split,
- treat "an alert row got updated" as a finding in a future security review of this story —
  updating `resolved_at` in place is the entire mechanism, not a bug.

### Do Not Change

- `media_state_transitions` / its `BEFORE UPDATE OR DELETE` trigger (1a, ADR-031) — do not
  touch, do not reuse its trigger function for `media_alerts`.
- `media_config`'s existing key catalog/defaults (9a) — this story only **adds** four new keys
  to the `media_config_update_mutable` allowlist via its own migration; it does not change any
  of 9a's original ten keys or `Nebu.Media.Config`'s validation logic for them.
- `Nebu.Compliance.AuditWriter` / `@known_actions` — opening or resolving a `media_alerts` row
  is **not** an audit-log event (it is system-internal operational monitoring, not an
  admin-attributable action or a compliance-relevant file-state change per ADR-028's scope).
  Do not add a `media_alert_opened`/`media_alert_resolved` audit action.
- The Story 5b/7 nav attention-badge logic — those badges count individual `:infected`/
  `scan_failed` **files**; this story's alerts are pipeline-level and additive, not a
  replacement or a merge of the two mechanisms.
- Do not add a manual "dismiss"/"acknowledge" admin action in this story — AC3 is explicit that
  auto-resolve-only is the full scope here; a manual override (if ever wanted) is a separate,
  unscoped future story, since it would need its own audit trail and role-gating decision this
  story's ACs do not cover.
- Do not implement the ClamAV status reader, the freshclam signature-age reader, or the
  `media_scan_stats` rollup query themselves — those are Story 10b's and Story 10a's scope
  respectively. This story only *consumes* whatever read function each of those stories
  exposes.
