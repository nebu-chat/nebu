# ATDD Output — trace-map-node-controls (RED phase, 2026-07-07)

> **Revision 2 — after test-review (1 MAJOR + 4 MINOR, all fixed; see
> test-review-findings.md) and the Story Amendments of 2026-07-07:**
> one-click enable CONFIRMED; retention options are **1 d / 7 d / 30 d**
> (dummy's "1 h" dropped, M1); **AC4 errors-always-persist exception** —
> ERROR entries on off endpoints are always persisted and always drive node
> status (m3); keyboard-enable pinned (m2); re-enable path pinned (m4);
> Scenario D/F seed windows widened to 10 s / 14 s (m1).

## Files created
- `server/test/nebu/admin/logs_live/trace_map_node_controls_contract_test.exs` — 20 tests, pure contracts: off-list (`TraceMap.long_polling_endpoints/0`, `off_endpoint?/1`), cascade set (`cascade_targets/2`), expiry comparison (`TemporaryCaptureManager.expired?/2`, `remaining_seconds/2`), duration env (`capture_duration_s/0`, default 300, `:temporary_capture_duration_s`, env restored on_exit), DB-free `active?/1` guard, `Nebu.Web.LogStore.should_persist?/2` (WARN suppressed on off routes / **ERROR always true** per amendment), AC12 audit vocabulary (FakeRepo pattern from audit_writer_test.exs).
- `server/test/nebu/admin/logs_live/trace_map_node_controls_test.exs` — 31 tests: 18 DB-free LiveView (off rendering/propagation, WARN-signal exclusion, **error-on-off state: `data-node-status="error"` + `data-node-off="true"` + ✕ badge + stream/domain/nebu aggregation**, inspector Logging section markup + labels + scope notes, AC3 build-once, off-click-never-filters, AC10 inline-JS guard) + 13 `@describetag :integration` (capture lifecycle click→row→temp→countdown→disable/expiry/reload, **re-enable via the inspector button (m4)**, announcements, configure_logging persistence incl. **"1 d"→"1" mapping**, domain cascade, pre-population).
- `server/test/nebu/admin/temporary_capture_manager_test.exs` — 9 tests, all `@moduletag :integration`: `enable/2`, `disable/1`, `active?/1`/`active_captures/0`, `cleanup_expired/0`, AC12 audit rows, `should_persist?/2` lifecycle flip probed with **WARN** (ERROR is exempt — separate always-true test).
- `e2e/features/admin/logs-trace-map-node-controls.feature` — 7 scenarios: A–F (story AC11) + **C2 (error-on-off, amendment)**, ALL `@pending-feature` (+ `@node-controls-capture`/`@node-controls-config` cleanup tags). Scenario C ends with the **keyboard-enable variant** (Tab to `/admin/keepalive` + Enter, m2); Scenario E ends with the **re-enable tail** (m4).

## Files extended
- `e2e/step-definitions/admin/logs-trace-map.steps.ts` — 21 new step definitions + 6 locator helpers + 2 After cleanup hooks (reuses `awaitLeitstandReady` and the existing tab-to/press-Enter steps; all `/health` steps KIND-scoped `[data-node-kind="satellite"]`).
- `e2e/fixtures/db.ts` — `runSqlQuery` (read-side), `upsertServerConfig`, `queryServerConfigValue`, `insertTemporaryCapture` (about-to-expire seeding, per answered design Q3), `clearTemporaryCaptures`, `clearEndpointLoggingConfig`. NO test-only HTTP routes.

## Red confirmation (post-review re-run)
- `make test-unit-elixir`: see the "Verification after review fixes" line appended below by the review-fix pass — baseline 1498 + 1 deliberately-green guard (AC10 inline-JS, documented in-file; leitstand precedent) stays green; every other new unit test red. Integration-tagged tests (13 + 9) excluded here — red at the CI integration gate (`admin_temporary_captures` table does not exist).
- `npx bddgen`: ok (default tags — pending scenarios excluded); `NEBU_E2E_TAGS='@pending-feature' npx bddgen`: ok, generates 7 tests for the new feature file.

## Contract pinned for the dev agent (full detail in the test moduledocs)
- New module `Nebu.Admin.TemporaryCaptureManager` (WarRoomManager precedent, ADR-018/020); table `admin_temporary_captures` (endpoint TEXT PK, enabled_at/expires_at TIMESTAMPTZ, started_by TEXT); expected migration number **000020**.
- `should_persist?/2 (level, route_template)` — off-list route + no capture ⇒ false for noise levels (probed: WARN); **ERROR ⇒ always true regardless of off/capture state (amendment 2026-07-07)**; capture active ⇒ delegate to level policy; non-off/nil route ⇒ delegate.
- Config keys: `log_min_level_<route>` (lowercase value) / `log_retention_days_<route>` (integer-string days "1"/"7"/"30") via `upsert_server_config/1`; change event `configure_logging` with params `node_key`/`min_level`/`retention_days`; events `enable_capture`/`disable_capture`.
- Node states: `data-node-status="off"|"temp"` for quiet-off/capturing; **error-on-off: `data-node-status="error"` PLUS `data-node-off="true"`** (the dashed-stroke marker CSS keys on) + ✕ badge with count; countdown `[data-testid="trace-map-node-countdown"]` mm:ss with `data-expires-at` (unix s, war-room `data-started-at` precedent). Inspector: `trace-map-inspector-logging`/`-level-select`/`-retention-select` (options **1 d / 7 d / 30 d**)/`-scope-note`/`-logging-form`/`-capture-state`/`-capture-toggle`/`-capture-countdown` testids; dummy copy ("Logging off (long-polling)", "Enable for 5 min", "Capture active", "Disable now").
- Off endpoints are rendered FROM MOUNT (they collect no noise data, so they could never appear by observation); DEBUG/INFO/WARN broadcasts are excluded from status window, stream panel, and nebu aggregation; ERROR broadcasts count fully (node/domain/nebu status + stream line); all-children-off ⇒ domain off.
- AuditWriter `@known_actions` must gain `enable_temporary_capture`/`disable_temporary_capture` (Option B, answered design Q2).

## Deviations / flags for dev + PM
1. ~~One-click vs two-step enable~~ — **RESOLVED by Story Amendment 2026-07-07**: one-click enable confirmed; the inspector "Enable" button exists for the post-early-disable state only (both paths now pinned, incl. re-enable m4).
2. ~~AC4 "not even errors"~~ — **SUPERSEDED by the errors-always-persist amendment** (test-review m3): ERROR is exempt from off-tier suppression everywhere (contract, LiveView, manager, E2E C2).
3. **Cascade count not pinned to "2":** `/admin/keepalive` (always-rendered off endpoint) may legitimately join the `/admin` cascade set; flash asserted as `Updated \d+ endpoints`. Dev decides inclusion.
4. ~~Retention "1 h" ambiguity~~ — **RESOLVED by Story Amendment 2026-07-07** (test-review M1): options are 1 d / 7 d / 30 d, mapping to `log_retention_days_*` values "1"/"7"/"30" (all three mappings pinned).
5. **AC13 already done:** `noise-endpoint-bucketing.md` frontmatter already reads `status: superseded` — no test written for a docs file; the reuse half of AC13 is pinned via `long_polling_endpoints/0`.
6. **Expiry-while-open unit test uses a 1.2 s sleep** with `temporary_capture_duration_s = 1` (env-config path blessed by answered design Q3); every other expiry test seeds already-expired/about-to-expire rows — no 5-minute waits anywhere.
7. **Audit assertions query `audit_log` directly** (integration) — a new but straightforward pattern; existing audit tests only use FakeRepo injection (also used here for the vocabulary pin).

## AC coverage map
| AC | Contract test | LiveView test | E2E |
|----|---------------|---------------|-----|
| 1 | cascade_targets | markup/labels/scope notes; persistence; cascade; pre-population (int.) | A, B |
| 2 | cascade_targets | retention select (1 d/7 d/30 d); persistence incl. "1 d"→"1"; pre-population (int.) | A |
| 3 | — | build-once select-survives-stat-patch | A (authoritative focus check) |
| 4 | off-list, should_persist?/2 (WARN off / ERROR always) | off rendering, propagation, WARN exclusion, error-on-off state | C (off rendering), C2 (error-on-off) |
| 5 | expiry, duration env, active? guard | enable/disable/auto-revert/reload/re-enable (int.) | C (incl. keyboard enable), D, E (incl. re-enable) |
| 6 | remaining_seconds | countdown element + data-expires-at (int.) | C (ticking), D |
| 7 | — | second-click filter + disable-keeps-filter (int.) | F |
| 8 | — | off/temp/error-on-off states, count "off", badges | C, C2, D, E |
| 9 | — | label[for], aria-labels, announcements (int.) | C (keyboard Enter), D, E (announcer) |
| 10 | — | phx-change form; inline-JS guard (deliberately green) | — (CSP enforced stack-wide) |
| 11 | — | — | Scenarios A–F (+C2) |
| 12 | AuditWriter vocabulary | — | manager test: audit rows (int.) |
| 13 | long_polling_endpoints/0 (canonical constant) | — | — (doc already superseded) |
