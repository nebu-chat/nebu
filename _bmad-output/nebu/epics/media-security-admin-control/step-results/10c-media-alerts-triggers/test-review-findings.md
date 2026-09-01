# Test Review Findings — Story 10c: media-alerts-triggers (FINAL, post-fix, CLEAN)

Original pass found 1 MAJOR (AC2 RLS-retune real-DB coverage gap, same class as 9a's F1)
+ 1 MINOR (AC1 schema shape not independently DDL-asserted) + 2 INFO. Both fixed:

- MAJOR-1 fixed: `server/test/nebu/media/config_test.exs` new "F2" describe block
  `"AC2 (story 10c): media_config_update_mutable RLS policy covers the four new
  alert-threshold keys"` — real-DB double-upsert (INSERT then UPDATE) for
  `clamav_down_alert_minutes`, `signature_stale_alert_hours`,
  `backlog_depth_alert_threshold`, `scan_failed_rate_alert_pct`, mirroring F1 exactly.
- MINOR-1 fixed: `server/test/nebu/matrix/migrations_grant_test.exs`'s 000033 describe
  block extended with 4 DDL-assertion tests (CHECK list, ENUM, FK, partial unique index).

Re-review verdict: **CLEAN**. Both fixes verified genuine (not superficial) — F2 correctly
exercises the UPDATE path (the actual RLS gate), no key overlap with F1, values distinct
enough to catch a stuck-value bug; the 4 DDL regexes verified by hand against the story's
own SQL text. `mix compile --warnings-as-errors` shows only the pre-existing unrelated
warning at `lib/nebu/admin/media_live.ex:654` (confirmed via `git stash` to predate this
story). No new issues.

Carried forward, non-blocking:
- INFO-1: `signature_stale_alert_hours` default (48, story's own flagged placeholder) never
  tested as a bare default.
- INFO-2: no test touches `AuditWriter.@known_actions` — correct per story's own guardrail
  (no audit action should be added for this table).

CLEAR TO PROCEED to dev-story.
