# Code Review — 4a-scan-failed-enum-migration

Status: CLEAN (0 MAJOR/CRITICAL, 0 MINOR)

## Scope check against File List / Dev Agent Guardrails

- `server/priv/migrations/000022_media_state_machine_foundation.*` — untouched. ✓
- `server/lib/nebu/media/state_machine.ex` — ONLY `@type state`, `@transitions`,
  and moduledoc comments changed. `transition/4`, `allowed?/2`,
  `allowed_transitions/1`, `write_transition/6`, `create/1`,
  `create_quarantined/1` byte-for-byte unchanged. ✓
- `server/lib/nebu/media.ex` / `server/lib/nebu/media/db.ex` — untouched
  (download_gate/1, parse_state/1, @sql_lookup). ✓
- No data migration / backfill / `UPDATE media_files` anywhere in the new
  migration. ✓
- No new table created → no new `GRANT` required (confirmed: only
  `ALTER TYPE ... ADD VALUE`, verified against the CLI-supplied gotcha about
  new-table migrations needing an explicit GRANT — does not apply here).

## Migration renumbering (000023 → 000028)

The story's Technical Requirements hardcode `000023`. That number was already
claimed by 5 other stories that landed first on this branch
(`000023_media_config` … `000027_media_files_uploader_user_id_nullable`).
Used `000028` instead — pure filename/number correction, documented in both
migration files' header comments, in `media_scan_failed_migration_test.exs`'s
moduledoc, and in `release_test.exs`'s migration-list comment (mirrors the
existing precedent in that same file: "000014/000015 renumbered on rebase").
Not a design/scope change — no escalation warranted.

## Pre-existing test regression found and fixed (self-review, before CI gate)

`state_machine_test.exs`'s pre-existing test `"allowed_transitions/1 returns
the full guard-table edge list for a given from_state"` hardcoded
`:quarantined`'s OLD edge list (`[:scanning, :admin_blocked, :deleted]`)
without `:scan_failed`. AC3 legitimately extends `:quarantined`'s edges, so
this test's expectation needed updating — fixed pre-CI-gate, confirmed by a
full `make test-integration` run showing zero `Nebu.Media.*` failures on
re-verification.

## CI-gate diff-against-baseline (full detail)

Baseline (pre-change): 2286 tests / 30 failures / 5 skipped.
First CI-gate run (post dev-story, pre-fix): 2311 tests / 35 failures / 5
skipped — 1 attributable to this story (the `:quarantined` edge-list test
above, fixed), 4 unrelated new failures (`Nebu.Web.AdminOidcLoginTest` x3 —
`GET /admin/users` pagination-sensitive assertions failing against a DB
polluted by thousands of `@ad-http-*`/`@ad-incsync-*` users left behind by
the load-generating `RegressionSyncLoadTest`/`SyncConcurrentTest` suite
sharing the same non-sandboxed DB; `Nebu.Web.LogStoreTest` AC9 — a
`unique_violation` race on `war_room_sessions_single_active_idx`, the same
shared-DB-state flakiness category as the already-baseline `WarRoomTest`/
`TraceMapNodeControlsTest` failures), plus normal fluctuation (+3/-1/-1)
within the already-flaky `TraceMapNodeControlsTest`/`TraceMapTest`/
`TemporaryCaptureManagerTest` files.

Re-verification run (post-fix): 2311 tests / 31 failures / 5 skipped, **zero**
`Nebu.Media.*` failures, zero `scan_failed`-related failures. The 31
failures are entirely within the same already-established flaky categories
(`TraceMapNodeControlsTest` 10, `WarRoomTest` 4, `AdminOidcLoginTest` 3,
`TraceMapTest` 3, `LogStore.RetentionTest` 2, `TemporaryCaptureManagerTest` 2,
`SyncConcurrentTest`/`RegressionSyncLoadTest` 1 each, plus 4 lone-failure
modules also present in the original baseline) — within the epic's
established ~18-42 pre-existing/non-deterministic range, none touching media.

Unit suite: 1837 passed / 0 failed, `mix compile --warnings-as-errors` and
`mix test --warnings-as-errors` both exit 0.

## AC-by-AC verification

- AC1/AC2/AC6 — `media_scan_failed_migration_test.exs` (12 tests, all green).
- AC3/AC4 — `state_machine_test.exs` (10 new + 1 fixed + full-guard-table
  sweep, all green).
- AC5 — new real-DB regression test in `media_download_gate_test.exs`,
  green; confirms zero code change was needed in `download_gate/1`/
  `parse_state/1`, exactly as the story's own claim required verifying (not
  assuming).
