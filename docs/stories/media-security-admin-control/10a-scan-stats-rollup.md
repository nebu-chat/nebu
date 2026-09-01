---
story_id: 10a-scan-stats-rollup
title: "Scan Health & Alerts Dashboard: media_scan_stats Rollup + Metrics Section"
epic: media-security-admin-control
status: done
security_review: optional
ui: true
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 4b makes every scan outcome (`:released`, `:infected`, `scan_failed`) a
`media_state_transitions` row, written through `Nebu.Media.StateMachine.transition/4`. That
table is the epic's compliance ledger (ADR-031, append-only), not an operations dashboard —
querying its full history live, on every dashboard page load, would mean scanning a
continuously-growing table for a number an admin wants to see in under a second.

This story adds the first slice of Story 10 ("Scan Health & Alerts Dashboard"): a new hourly
rollup table `media_scan_stats`, an Oban-cron worker that aggregates the just-completed hour's
`media_state_transitions` rows into it, and a metrics section on a new admin dashboard route
(`/admin/media/health`) that reads only the rollup table — never the raw transition history.
Story 10b (ClamAV connection/freshclam status) and Story 10c (`media_alerts` + auto-resolve)
attach further sections to this same page in later stories; this story's job is exactly the
rollup mechanism, the table, and the metrics section, nothing else.

**Why a new route, not a section bolted onto `/admin/media` (Story 5a):** the epic's own Review 9
already treats `/admin/media/health` as the page Story 10e's War-Room deep-link points at
("`/admin/media/health` bei einem ungelösten `critical`-Alert direkt in eine ... War-Room-Session"
— i.e. that link target is assumed to already exist), and Story 10b/10c's scope bullets say
"im Dashboard" without redefining where that dashboard lives, i.e. they build on whatever this
story establishes. Since Story 5a's `/admin/media` is explicitly scoped as a read-only *file*
table (filter/paginate/select — no room for a metrics/health section without scope-creeping that
story), `/admin/media/health` is this story's own new route, matching the "Health" child link the
epic's Review 9 IA diagram already lists under the nested "Medien" nav item.

**Why a LiveView, not a static controller+template:** this story's own data (hourly rollups) does
not itself need push updates — it is computed once per `mount`/`handle_params` and would render
identically from a plain controller. The deciding factor is what gets attached to the *same page*
next: Story 10b's ClamAV up/down status is explicitly "via PubSub or periodischem Poll" and Story
10c's alert list is explicitly designed to auto-resolve and surface new `critical` alerts without
a manual refresh. Every other admin dashboard-style page in this codebase that combines several
live-ish sections (`Nebu.Admin.LogsLive`, `Nebu.Admin.AuditLogLive`, `Nebu.Admin.MediaLive` from
Story 5a) is already a LiveView, not a controller+template pair — there is no static-controller
precedent for this class of page in the Admin UI. Standing this page up as a plain controller now
and converting it to a LiveView when 10b/10c land would mean redoing the page shell mid-epic for
no benefit; building it as `Nebu.Admin.MediaHealthLive` from the start avoids that throwaway work,
at the cost of zero extra complexity for this story's own read-once metrics (a LiveView's
`mount/3` computing static assigns once is not more expensive than a controller action doing the
same query).

## User Story

As an admin, I want to see hourly-rolled-up scan throughput, average/p95 scan duration, current
backlog depth, and scan-failure rate on a dedicated media health page, so that I can judge the
scan pipeline's operational health at a glance without querying the raw compliance ledger myself.

## Acceptance Criteria

1. **New table `media_scan_stats` — one row per completed hour.** Columns: `id BIGSERIAL PRIMARY
   KEY`, `window_start TIMESTAMPTZ NOT NULL` (the hour's start, UTC, `date_trunc('hour', ...)`),
   `scans_released INTEGER NOT NULL DEFAULT 0`, `scans_infected INTEGER NOT NULL DEFAULT 0`,
   `scans_failed INTEGER NOT NULL DEFAULT 0`, `scans_total INTEGER GENERATED ALWAYS AS
   (scans_released + scans_infected + scans_failed) STORED` (a generated column, not a
   separately-written value — it can never drift out of sync with the three counts that define
   it), `avg_scan_duration_ms INTEGER` (nullable — `NULL` when `scans_total = 0` for that hour),
   `p95_scan_duration_ms INTEGER` (nullable, same rule), `backlog_depth INTEGER NOT NULL DEFAULT
   0` (a **point-in-time snapshot** of `COUNT(*) WHERE state IN ('quarantined', 'scanning')` taken
   when the rollup runs — not a windowed aggregate, see Technical Requirements), `inserted_at
   TIMESTAMPTZ NOT NULL DEFAULT NOW()`. A `UNIQUE` constraint on `window_start` makes the table
   upsert-safe (AC3).
2. **Hourly aggregation window, sourced from `media_state_transitions` (Story 1a/4b).**
   "Scan-Durchsatz", "Ø-/p95-Scan-Dauer", and the released/infected/failed counts are all computed
   over exactly one clock hour — `[window_start, window_start + interval '1 hour')` — per the
   epic's own Story 10a scope ("stündliche Rollups"). Scan duration is measured per `media_id` as
   the time between its most recent entry into `:scanning` (`to_state = 'scanning'`) and the next
   transition for that same `media_id` into a terminal state (`to_state IN ('released',
   'infected')`) — **not** wall-clock time since upload, and not the `scan_failed` path (a
   `scan_failed` outcome has no single well-defined "scan duration" since it may span several
   retried attempts; it is counted in `scans_failed`/`scans_total` but excluded from the
   duration statistics).
3. **Oban-cron rollup worker, on the shared housekeeping queue (ADR-025 convention).**
   `Nebu.Workers.MediaScanStatsRollupWorker` runs on an `Oban.Plugins.Cron` schedule (once per
   hour, a few minutes after the hour boundary so the just-completed hour's transitions have
   fully committed — see Technical Requirements for the exact cron expression), `queue:
   :media_cleanup` (the same shared housekeeping queue Story 2e's cleanup cron and Story 8a's
   retention crons use — this is a periodic aggregation job, not a per-upload scan job, so it does
   not belong on `:media_scan`), `max_attempts: 5`. It aggregates the single most recently
   completed hour and **upserts** (`INSERT ... ON CONFLICT (window_start) DO UPDATE`) the
   corresponding `media_scan_stats` row.
4. **Idempotent / re-runnable.** Running the worker twice for the same hour (a retried job, an
   operator manually re-triggering a backfill) produces exactly one row for that `window_start`
   with identical values, never a duplicate row and never a value that changes between runs
   (given the same underlying `media_state_transitions` data — which is itself append-only and
   therefore stable for a fully-elapsed hour).
5. **Metrics section on a new route `/admin/media/health`, served by `Nebu.Admin.MediaHealthLive`
   (LiveView, see Summary for why), inside the existing `live_session :admin` block**
   (`on_mount: {Nebu.Admin.Auth, :require_admin}`, the same gate every other admin LiveView uses —
   no bespoke authorization logic). The section reads **only** `media_scan_stats` — never a live
   query over `media_state_transitions`' full history (this is the epic's own explicit
   requirement for Story 10a: "liest die Rollup-Tabelle (kein Live-Query über die volle
   Historie)").
6. **Metrics rendered, computed from the rollup table:**
   - **Scan-Durchsatz:** the most recent complete hour's `scans_total`, plus a rolling 24h sum
     (`SUM(scans_total)` over the last 24 `media_scan_stats` rows).
   - **Ø-/p95-Scan-Dauer:** the most recent complete hour's `avg_scan_duration_ms` /
     `p95_scan_duration_ms` — displayed per-hour, **not** naively averaged across a rolling
     window (averaging a column of hourly averages without weighting by that hour's `scans_total`
     produces a statistically wrong number when hourly volumes differ; see Dev Agent Guardrails).
   - **Backlog-Tiefe:** the most recent row's `backlog_depth` (this is a snapshot, not something
     that can be usefully "rolled up" across hours — it is a live count of what's currently stuck
     in `:quarantined`/`:scanning`, refreshed each time the cron ticks).
   - **Fehlerrate:** `SUM(scans_failed) / NULLIF(SUM(scans_total), 0)` over the last 24 rows
     (rolling 24h) and over the last 168 rows (rolling 7d), each rendered as a percentage.
7. **Empty-state handling.** Before the first cron tick has ever run (`media_scan_stats` has zero
   rows) — or, more generally, whenever the query above returns no rows — the section renders an
   explicit "Noch keine Scan-Daten — wartet auf den ersten stündlichen Rollup." message (mirrors
   `EXPERIENCE.md`'s State-Patterns-B empty-state convention, the same pattern Story 5a's table
   uses for "Noch keine Medien hochgeladen."), never a crash, a blank section, or a literal `NaN`/
   `Infinity` from an unguarded division.
8. **Numbers are accurate against a fixture with known scan outcomes.** Seeding a known set of
   `media_state_transitions` rows (a mix of clean/infected/`scan_failed` outcomes with known
   `:scanning`-entry-to-terminal timestamps, all within one target hour) and running the rollup
   worker produces a `media_scan_stats` row whose `scans_released`/`scans_infected`/
   `scans_failed`/`scans_total`/`avg_scan_duration_ms`/`p95_scan_duration_ms` exactly match
   hand-computed expected values for that fixture.

## Acceptance Tests

Test files: `server/test/nebu/workers/media_scan_stats_rollup_worker_test.exs` (`use Oban.Testing,
repo: Nebu.Repo`, `Oban.Testing.perform_job/3`, matching Story 4b/2e's convention for Oban worker
tests) and `server/test/nebu/admin/media_health_live_test.exs` (`Phoenix.LiveViewTest`, mirroring
`server/test/nebu/admin/media_live_test.exs`'s shape from Story 5a).

1. `test "rollup aggregates scans_released/scans_infected/scans_failed correctly for a fixture
   with known outcomes"` — seeds `media_state_transitions` with 5 `:scanning → :released`, 2
   `:scanning → :infected`, and 1 `:quarantined → :scan_failed` transition, all with
   `inserted_at` inside the target hour; runs `perform_job(MediaScanStatsRollupWorker, %{})`;
   asserts the resulting `media_scan_stats` row has `scans_released: 5, scans_infected: 2,
   scans_failed: 1, scans_total: 8`.
2. `test "rollup computes avg_scan_duration_ms and p95_scan_duration_ms from paired :scanning-entry
   to terminal-transition timestamps"` — seeds transition pairs with known, hand-picked duration
   deltas (e.g. 1000ms, 2000ms, ..., 10 samples); asserts the computed average matches the
   arithmetic mean and the p95 matches the expected percentile for that fixture.
3. `test "scan_failed transitions are excluded from duration statistics but included in
   scans_total"` — a `scan_failed` outcome with no paired terminal `:scanning`-exit timestamp
   does not distort `avg_scan_duration_ms`/`p95_scan_duration_ms`, but is counted in
   `scans_failed` and `scans_total`.
4. `test "backlog_depth is a point-in-time snapshot of quarantined + scanning media_files rows at
   rollup time"` — seeds 3 `:quarantined` and 2 `:scanning` `media_files` rows (regardless of
   which hour their last transition happened in) plus some `:released` rows; asserts
   `backlog_depth == 5`.
5. `test "transitions outside the target hour window are excluded (boundary test)"` — seeds one
   transition exactly 1 second before `window_start` and one exactly at `window_start + 1 hour`;
   asserts neither is counted in the rolled-up hour.
6. `test "rollup is idempotent: running the worker twice for the same hour produces exactly one
   media_scan_stats row with identical values, not a duplicate"` — calls `perform_job/3` twice for
   the same target hour; asserts `SELECT COUNT(*) FROM media_scan_stats WHERE window_start = $1`
   is `1` both times and the row's values are unchanged.
7. `test "an hour with zero scan activity produces a row with all counts 0 and NULL duration
   stats, not an error"` — asserts `scans_total: 0, avg_scan_duration_ms: nil,
   p95_scan_duration_ms: nil` rather than a crash or a `0/0` artifact.
8. `test "mount renders the metrics section with correct rolling 24h throughput and error rate from
   24 seeded media_scan_stats rows"` — seeds 24 hourly rows with known `scans_total`/
   `scans_failed` values; asserts the rendered rolling-24h throughput and error-rate percentages
   match the hand-computed expected sums.
9. `test "mount renders the empty state when media_scan_stats has zero rows"` — asserts the "Noch
   keine Scan-Daten" copy renders, not a blank section or a rendering error.
10. `test "non-admin access control: a session without the admin role is redirected away from
    /admin/media/health (or receives a 403), never rendering the metrics section"` — mirrors
    Story 5a's `require_admin` on_mount test pattern.

## Technical Requirements

Follows ADR-018 (inline SQL, no Ecto schema/service layer) and ADR-025 (Oban for all async/
scheduled work in this epic).

### 1. Migration — `media_scan_stats` table

`server/priv/migrations/0000XX_media_scan_stats.up.sql` (number TBD at implementation time —
verify the actual HEAD migration under `server/priv/migrations/` before assigning a number; do not
collide with 4a's `scan_failed` ENUM migration or 4b's Oban-schema migration if either has not
landed yet — this migration only depends on `media_files`/`media_state_transitions` existing,
i.e. on Story 1a, not on 4a/4b's own migrations):

```sql
CREATE TABLE media_scan_stats (
    id                    BIGSERIAL     PRIMARY KEY,
    window_start          TIMESTAMPTZ   NOT NULL,
    scans_released        INTEGER       NOT NULL DEFAULT 0,
    scans_infected        INTEGER       NOT NULL DEFAULT 0,
    scans_failed          INTEGER       NOT NULL DEFAULT 0,
    scans_total           INTEGER       GENERATED ALWAYS AS
                                         (scans_released + scans_infected + scans_failed) STORED,
    avg_scan_duration_ms  INTEGER,
    p95_scan_duration_ms  INTEGER,
    backlog_depth         INTEGER       NOT NULL DEFAULT 0,
    inserted_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX media_scan_stats_window_start_idx ON media_scan_stats (window_start);

GRANT SELECT, INSERT, UPDATE, DELETE ON media_scan_stats TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_scan_stats_id_seq TO nebu_app;
```

Unlike `media_state_transitions` (Story 1a, ADR-031), this table is a **derived, re-computable
rollup**, not a compliance ledger — it needs no append-only trigger, no RLS, and `UPDATE` is
expected (that's exactly what the upsert in AC3/AC4 does). Add the corresponding `describe
"AC1/AC2: 0000XX_media_scan_stats.up.sql grants"` block to `Nebu.Matrix.MigrationsGrantTest`
(same convention Story 1a's own migration used) and the down-migration filename to that test's
`@down_migrations` list.

`down.sql`: `DROP TABLE IF EXISTS media_scan_stats;` (no `GRANT` statement, matching the existing
down-migration convention).

### 2. Rollup worker

`server/lib/nebu/workers/media_scan_stats_rollup_worker.ex`:

```elixir
defmodule Nebu.Workers.MediaScanStatsRollupWorker do
  use Oban.Worker, queue: :media_cleanup, max_attempts: 5

  @impl Oban.Worker
  def perform(_job) do
    window_start = current_target_hour()
    stats = aggregate_hour(window_start)
    upsert(window_start, stats)
    :ok
  end

  # The most recently *fully elapsed* hour relative to now — never the current,
  # still-accumulating hour.
  defp current_target_hour do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
    |> DateTime.add(-1, :hour)
  end
end
```

(Illustrative — adapt to the exact `Nebu.Media.DB`/`Nebu.Repo` query seam already established by
prior stories; the load-bearing points are: target the last *completed* hour, one upsert per run,
never a raw `UPDATE` outside this worker's own table.)

**Duration aggregation sketch** (illustrative SQL — the dev agent should verify the exact query
shape against the real `media_state_transitions` column names from Story 1a during
implementation):

```sql
WITH scan_windows AS (
    SELECT
        media_id,
        inserted_at AS started_at,
        LEAD(inserted_at) OVER (PARTITION BY media_id ORDER BY inserted_at) AS ended_at,
        LEAD(to_state)    OVER (PARTITION BY media_id ORDER BY inserted_at) AS ended_state
    FROM media_state_transitions
    WHERE to_state = 'scanning'
),
durations AS (
    SELECT EXTRACT(MILLISECONDS FROM (ended_at - started_at))::INTEGER AS duration_ms
    FROM scan_windows
    WHERE ended_state IN ('released', 'infected')
      AND started_at >= $1 AND started_at < $1 + INTERVAL '1 hour'
)
SELECT
    COUNT(*)                                                    AS sample_count,
    AVG(duration_ms)::INTEGER                                   AS avg_scan_duration_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms)::INTEGER AS p95_scan_duration_ms
FROM durations;
```

`scans_released`/`scans_infected`/`scans_failed` are simple `COUNT(*) ... WHERE to_state = '...'
AND inserted_at >= $1 AND inserted_at < $1 + INTERVAL '1 hour'` queries against
`media_state_transitions` (released/infected keyed on `from_state = 'scanning'`, `scan_failed`
keyed on `from_state = 'quarantined'`, per Story 4b's exact transition shapes). `backlog_depth` is
a separate, non-windowed query: `SELECT COUNT(*) FROM media_files WHERE state IN ('quarantined',
'scanning')`, run at the moment the worker executes (a snapshot, not filtered by
`window_start`/`inserted_at` at all).

### 3. Cron schedule

`server/config/config.exs`, appended to the existing `crontab:` list (alongside whatever entries
Story 2e/4b/8a already registered):

```elixir
{"5 * * * *", Nebu.Workers.MediaScanStatsRollupWorker}
```

Five minutes past the hour — enough buffer that the just-completed hour's `media_state_
transitions` writes (all synchronous DB inserts from Story 4b's worker) have committed before the
rollup queries them, without meaningfully delaying visibility of the new hour's numbers.

### 4. Dashboard LiveView

`server/lib/nebu/admin/media_health_live.ex` — `Nebu.Admin.MediaHealthLive`, `use
Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}` (same shape as `Nebu.Admin.MediaLive`,
Story 5a). Router wiring in `server/lib/nebu/admin/router.ex`, inside the existing `live_session
:admin` block:

```elixir
live "/media/health", MediaHealthLive, :index
```

`mount/3`/`handle_params/3` run three inline-SQL reads (per ADR-018 — no Ecto schema): the latest
row (for "current hour" throughput/duration/backlog), the last-24-rows aggregate (rolling 24h
throughput/error-rate), and the last-168-rows aggregate (rolling 7d error-rate). This story's own
content needs no PubSub subscription and no `handle_info/2` — it is computed once per navigation,
exactly like a controller action would, but lives in a LiveView module so Story 10b/10c can add
`Phoenix.PubSub.subscribe/2` calls and `handle_info/2` clauses onto this same `mount/3` without
having to first convert the page from a controller.

Empty state (AC7): when the latest-row query returns no rows, assign a flag the template checks
before attempting any arithmetic on `nil` — never call `Float.round/2`, division, or percentage
formatting against a `nil`/absent value.

**Nav wiring:** the epic's Review 9 IA note describes a "Health" child link under a nested
"Medien" parent nav item (alongside "Übersicht"/"Settings"/"Approvals"). If the UX-Foundation
story that introduces that nested parent/children nav structure has not landed by the time this
story is implemented, add `/admin/media/health` as a plain leaf `nav_item` for now — do not
speculatively invent the nested parent/children markup here (same guardrail Story 5a already
applied to its own `/admin/media` entry).

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/priv/migrations/0000XX_media_scan_stats.up.sql` (number TBD) | NEW | `media_scan_stats` table, unique index on `window_start`, grants |
| `server/priv/migrations/0000XX_media_scan_stats.down.sql` | NEW | `DROP TABLE IF EXISTS media_scan_stats;` |
| `server/lib/nebu/workers/media_scan_stats_rollup_worker.ex` | NEW | `Nebu.Workers.MediaScanStatsRollupWorker` |
| `server/config/config.exs` | UPDATE | Add the hourly cron entry to the existing `crontab:` list |
| `server/lib/nebu/admin/media_health_live.ex` | NEW | `Nebu.Admin.MediaHealthLive` — mount/handle_params, inline SQL reads, metrics section rendering |
| `server/lib/nebu/admin/router.ex` | UPDATE | Add `live "/media/health", MediaHealthLive, :index` inside the existing `live_session :admin` block |
| `server/test/nebu/workers/media_scan_stats_rollup_worker_test.exs` | NEW | Acceptance Tests 1–7 |
| `server/test/nebu/admin/media_health_live_test.exs` | NEW | Acceptance Tests 8–10 |
| `server/test/nebu/matrix/migrations_grant_test.exs` | UPDATE | Add a describe block for the new migration's grants; add its down-migration filename to `@down_migrations` |

## Dev Agent Guardrails

### Do Not Change

- **Do not add an append-only trigger, RLS, or `SECURITY DEFINER` function to
  `media_scan_stats`.** Unlike `media_state_transitions` (ADR-031), this table is a derived,
  re-computable rollup that this story's own worker is expected to `UPDATE` via upsert — treating
  it like the compliance ledger would make the idempotent-rerun requirement (AC4) impossible to
  satisfy.
- **Never query `media_state_transitions`' full history live from the dashboard.** The epic's own
  Story 10a scope is explicit: "liest die Rollup-Tabelle (kein Live-Query über die volle
  Historie)". If a metric this story needs cannot be derived from `media_scan_stats` alone, the
  fix is to add a column to the rollup table and have the cron worker compute it — not to have
  `MediaHealthLive` query `media_state_transitions` directly.
- **Do not average a column of hourly averages without weighting.** `avg_scan_duration_ms` is
  displayed per-hour (the most recent completed hour), not blended across a rolling window — a
  naive `AVG(avg_scan_duration_ms)` over 24 rows would silently under- or over-weight hours with
  different `scans_total` volumes. If a rolling-window duration figure is wanted later, it must be
  a `scans_total`-weighted average (or computed by widening the duration query's own window, not
  by averaging already-averaged rows) — flag this to Product/UX rather than adding a
  statistically-wrong number under time pressure.
- **Do not implement Story 10b (ClamAV status/freshclam age) or Story 10c (`media_alerts`
  table/auto-resolve/nav badges) in this story.** This story's page renders exactly one section —
  the rollup metrics. The two other sections are separate stories that attach to the same
  `Nebu.Admin.MediaHealthLive` module later; do not pre-build their query logic or table schemas
  here on the assumption it saves work later.
- **Do not touch `media_state_transitions`'s schema, trigger, or RLS policies** (Story 1a,
  ADR-031) — this worker only ever issues `SELECT` statements against that table.
- **Do not add a bespoke retry/backoff mechanism to the rollup worker** — Oban's default
  `backoff/1` (exponential) is sufficient, per ADR-025, same as every other worker in this epic.
- **Do not invent the nested "Medien" parent/children nav markup speculatively** if the
  UX-Foundation story that owns it has not landed — add a plain leaf `nav_item` instead (mirrors
  Story 5a's own guardrail for its `/admin/media` entry).
- `server/priv/migrations/` is pipeline-protected per `CLAUDE.md` — do not hand-apply this
  migration outside an active `nebu-pipeline` run.

## Dependencies

- **Depends on:**
  - **4b — `Nebu.Workers.MediaScanWorker`** — the source of every `media_state_transitions` row
    this rollup aggregates (`:scanning → :released/:infected`, `:quarantined → :scan_failed`);
    also the story that first introduces the Oban dependency, Postgres-backed job tables, and the
    app's Oban supervisor entry this worker's cron entry builds on.
  - **1a — `media_files`/`media_state_transitions` schema** — the tables and columns
    (`state`, `inserted_at`, `to_state`, `from_state`) this rollup's queries read.
  - **1b — `Nebu.Media.StateMachine`** — not called directly by this story (the rollup worker only
    reads, it never transitions state), but the authority for which `from_state`/`to_state` pairs
    are valid, which this story's aggregation queries rely on being accurate.
- **Enables:**
  - **10b — ClamAV-Status + Freshclam-Alter** — attaches a further section to the
    `Nebu.Admin.MediaHealthLive` page this story creates.
  - **10c — `media_alerts`-Tabelle + Trigger + Auto-Resolve** — surfaces unresolved alerts at the
    top of the same dashboard page, and its configurable thresholds (backlog depth, error rate)
    read the same `media_scan_stats` metrics this story computes.
  - **10e — Trace-Map-/War-Room-Integration** — links into `/admin/media/health` on an unresolved
    `critical` alert, i.e. assumes this route already exists.
