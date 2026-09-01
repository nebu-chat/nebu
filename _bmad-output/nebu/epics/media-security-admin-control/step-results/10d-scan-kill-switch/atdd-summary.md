# ATDD — 10d-scan-kill-switch

## Stack: backend (Elixir/Phoenix). Not a Matrix feature (oracle-gate skipped).

## Files created/updated

- NEW `server/test/nebu/workers/media_scan_worker_kill_switch_test.exs` — 5 tests
  (Acceptance Tests 1-5: fail-open+audit, fail-closed+retry, fail-closed+exhaust+audit,
  normal-scanning-unaffected parameterized fail_open/fail_closed, live-policy-change
  via the REAL Nebu.Media.Config).
- UPDATE `server/test/nebu/compliance/audit_writer_media_actions_test.exs` — Acceptance
  Test 6 (media_unscanned_release allowlist regression).
- UPDATE `server/test/nebu/media/config_test.exs` — Acceptance Tests 7-8
  (invalid-value rejection, fresh-table default), plus:
  - `scan_kill_switch: "fail_closed"` added to the shared `@default_catalog` fixture
    (mirrors 10c's own precedent) — intentionally turns 3 pre-existing
    exact-equality tests RED until dev-story adds the key to `@defaults`.
  - A dedicated `media_config_update_mutable` RLS-allowlist integration test for
    `scan_kill_switch` (mirrors 10c's own AC2 describe block / F1 gotcha:
    first upsert is always an INSERT, only the SECOND upsert (UPDATE) actually
    exercises the migration's allowlist).

## RED verification (mix test, unit suite, --warnings-as-errors)

Full suite: 1938/1948 passed, 2 skipped, 614 excluded (integration), **10 failed**
— all 10 are this story's own new/modified RED tests, all failing for the
CORRECT reason (no unrelated regressions):

1. `Nebu.Media.ConfigTest` "fresh media_config table ... defaults to fail_closed"
   — KeyError, `scan_kill_switch` not yet in `@defaults`.
2. `Nebu.Media.ConfigTest` "upsert/1 accepts both fail_open and fail_closed"
   — `{:error, :unknown_config_key}` (key not yet known).
3-5. `Nebu.Media.ConfigTest` three pre-existing `Config.get() == @default_catalog`
   equality tests — RED because the map now expects `scan_kill_switch` (cascading
   RED, exactly mirrors how 10c's own ATDD extended this same fixture before it).
6. `Nebu.Compliance.AuditWriterMediaActionsTest` "media_unscanned_release ..."
   — `{:error, :audit_unknown_action}` (not yet in `@known_actions`).
7-10. `Nebu.Workers.MediaScanWorkerKillSwitchTest` — all 4 kill-switch-branch
   tests fail because `MediaScanWorker.scan_and_transition/3` has no health-check
   branch yet: the worker falls through to the real `scan_binary/1` call, which
   the test's `FakeClamAV` answers with `{:error, :no_fun_configured}` (no
   `set_scan_result/1` was configured for these scenarios, deliberately, since
   the kill-switch path must never reach `scan_binary/1` at all) instead of the
   expected `:clamav_unavailable` health-check-derived reason.

`@tag :integration` tests (the 10c-precedent-mirroring RLS allowlist test for
`scan_kill_switch`, plus the pre-existing 9a/10c ones) are excluded from a plain
`mix test` run (no `NEBU_DB_URL`) — verified separately against a real Postgres
as part of ci-gate (Step 5), same discipline 9a/10c's own ATDD already documents.

## Corrected assumptions vs. story's illustrative pseudocode (grounded against
current code, not story prose — flagged per pipeline instructions)

- `Nebu.Media.ClamAV.health_check/0` returns `%{healthy: boolean(), changed_at:
  DateTime.t()}` (Story 3, extended by 10b's `changed_at`) — NOT a bare
  `:healthy`/`:unhealthy` atom as the story's `clamav_healthy?/0` sketch shows.
  Dev-story must pattern-match `%{healthy: bool}`.
- The config seam is `Application.get_env(:nebu_http, :media_config_module,
  Nebu.Media.Config)` — `:nebu_http` namespace, not `:nebu` — confirmed against
  10c's `MediaAlertsCheckerWorker`, which already establishes this exact
  `media_config()` private-function convention.
- `scan_and_transition/3` is confirmed still the correct current function name
  in `media_scan_worker.ex` (unchanged since 4b; 4c/10a/10b/10c did not touch it).
- 10d's own migration (planned `000034_media_config_scan_kill_switch`, next
  after 10c's `000033_media_alerts`) extends `media_config_update_mutable` via
  `ALTER POLICY` (10c's own established idiom), not `DROP POLICY; CREATE POLICY`
  as the story's illustrative SQL shows.
- No new table is created by this story (config-key + migration extension +
  worker branch + audit allowlist entry only) — the CRITICAL "new table needs
  GRANT + MigrationsGrantTest extension" gotcha from Story 9a does NOT apply
  here; confirmed `MigrationsGrantTest` is a fixed, per-migration-filename
  suite (not a dynamic scan), so no test update is needed for a migration that
  only ALTERs an existing policy.
- Story frontmatter says `ui: true`, but this story's own File List has zero
  Admin UI files in scope (the `scan_kill_switch` value is exposed through
  Story 9b's EXISTING `/admin/media/settings` screen — no new UI this story
  adds). ExUnit (not Gherkin/Playwright) is therefore the correct ATDD choice
  per this project's own persistent-fact convention ("For Elixir GenServer
  stories: generate ExUnit tests, not Gherkin" / Gherkin only applies when an
  AC involves actual browser interaction, which none of AC1-AC9 do). Flagging
  this ui:true/no-UI-files mismatch for the caller, not silently overriding
  the frontmatter.
