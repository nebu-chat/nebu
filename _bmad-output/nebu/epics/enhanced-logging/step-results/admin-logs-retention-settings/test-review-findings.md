# Test Review Findings — admin-logs-retention-settings

Status: 2 MAJOR + 3 MINOR found by `nebu-test-reviewer`, ALL FIXED DIRECTLY (pure
test-coverage/quality issues, no design tradeoff). Re-verified RED after fixes:
25 tests in `logs_controller_test.exs`, 24 failures, 1 skipped (AT16, `:skip`).

## Fixed MAJOR-1 — AT10 assertion too permissive (accepted literal "0")

`server/test/nebu/admin/logs_controller_test.exs`, `describe "AT10 ..."`. The
original assertion accepted the stored value `"0"` as equivalent to "no
limit". This would have silently passed even if the controller persisted the
literal string `"0"` instead of normalizing to `nil` — and
`Nebu.Web.LogStore.Retention.prune_ttl/2` / `prune_max_count/2` only
short-circuit on `nil` (`Integer.parse("0")` → the integer `0`, which the
`WHERE inserted_at < now() - '0 days'::interval` / `LIMIT 0` prune queries
would treat as "delete everything on the next sweep", the OPPOSITE of "no
limit"). **Dev implication: `save_retention/2`'s normalization MUST convert
blank AND `"0"` to `nil` (or empty string that reads back as nil) before
calling `Nebu.Admin.DB.upsert_server_config/1` — never pass through `"0"`
literally for either `_days` or `_max_entries` fields, for either INFO or
DEBUG.** Test now also covers `info_max_entries`/`debug_max_entries` (was only
checking `debug_days` before).

## Fixed MAJOR-2 — missing Playwright/e2e coverage for client-side interactivity

AC7 (click bubble → reveal/hide retention fields), AC8 (fields pre-fill with
defaults live, before any submit), AC11 (DEBUG warning show/hide live) are all
implemented in client-side JS only (`design-decisions.md` #2/#4c) — no ExUnit
test can observe this. Added:
- `e2e/features/admin/logs-config.feature` (5 scenarios, tagged
  `@pending-feature`, RED phase)
- `e2e/step-definitions/admin/logs-config.steps.ts` (17 step definitions)

Verified via `npx bddgen` (both default-excluded and with
`NEBU_E2E_TAGS` including `@pending-feature`): all steps resolve, no
ambiguous/missing step errors, `tsc --noEmit` clean.

**Data-attribute contract dev-story MUST implement** (pinned down by this
file, reused/extended from the sibling `trace_map_bubble` contract):
- Level bubble: `[data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value="info"|"debug"|"warning"|"error"]`
- Retention fields container: `[data-testid="retention-fields"][data-bubble-value="info"|"debug"]`, containing `input[name="info_days"|"debug_days"]` and `input[name="info_max_entries"|"debug_max_entries"]`
- DEBUG warning: `[data-testid="debug-warning"]`
- Form: `form[data-testid="logs-retention-form"]` with a real `<button type="submit">`
- Nav link on the monitoring page: an `<a>`/`<.link>` matching `getByRole('link', { name: /Sammlung konfigurieren/i })`, `href="/admin/logs/config"`

Once implemented, remove the `@pending-feature` tag from
`logs-config.feature` and add it to the default e2e run (mirrors how
`logs-monitoring.feature` went green for the sibling story).

## Fixed MINOR-1 — `:pending` tag has no real ExUnit skip semantics

AT16 (AC17, Option A/no-PubSub decision) now uses `@tag :skip` (real ExUnit
skip behavior) instead of a bare `:pending` tag that would have just run and
trivially passed.

## Fixed MINOR-2 — AT15's `and`-combined refute could mask a leaked field

Split into two independent `refute` assertions (one for `name="debug_days"`,
one for `name="debug_max_entries"`) so either leaking alone is caught.

## Accepted as-is (no fix needed)

- MINOR-3 (fixed-byte-window substring helpers) — matches existing codebase
  convention (`config_controller_test.exs`/`admin_http_controllers_test.exs`
  style), not a new anti-pattern.
- INFO-1/INFO-2 — informational, no coverage gap.
- INFO-3 — confirmed N/A, no GenServer introduced by this story.

## Design-decisions.md deviations — independently re-verified sound by the reviewer

All 4 documented deviations (403→302 auth-gate reality, real server_config
key names, Controller-not-LiveView, WARN/ERROR hardcoded TTL) were
cross-checked by the reviewer against the actual shipped source
(`auth.ex`, `log_store.ex`, `retention.ex`, `policy_cache.ex`, `db.ex`,
`000017_operational_logs.up.sql`) and confirmed accurate — not re-flagged as
defects.
