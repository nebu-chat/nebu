# Code Review — 10d-scan-kill-switch

## Focused adversarial review (6 points requested)

1. **Default fail_closed, cannot silently regress** — CONFIRMED. `@defaults`
   sets `"scan_kill_switch" => "fail_closed"`; the shared `@default_catalog`
   fixture in `config_test.exs` (used by 7+ equality assertions across the
   file) pins the same value — any regression to a different default breaks
   the unit suite immediately, not just this story's own tests.
2. **AC7 audit non-negotiable, no silent-skip path** — CONFIRMED. `write_audit/4`
   is called unconditionally in the `"fail_open"` branch, after the state
   transition/broadcast, mirroring the exact ordering `infect/2` and
   `scan_error/4`'s exhausted branch already use elsewhere in this file
   (broadcast, then audit). `AuditWriter.log/6` itself never raises (existing
   contract) so a downstream audit-write failure cannot crash the job, but
   it's always attempted.
3. **`clamav_healthy?/0` pattern match vs the real `health_check/0` shape** —
   CONFIRMED correct: `match?(%{healthy: true}, clamav().health_check())`
   matches the real `%{healthy: boolean(), changed_at: DateTime.t()}` return
   shape (Story 3, extended by 10b), NOT the story's stale bare-atom sketch.
4. **`fail_closed` reuses `scan_error/4` unmodified** — CONFIRMED. Diffed
   `scan_error/4` — zero lines changed; `handle_kill_switch/3`'s `"fail_closed"`
   branch is a bare, unmodified call passing `:clamav_unavailable` as the
   reason atom.
5. **Migration safety (`ALTER POLICY` vs `DROP`+`CREATE`)** — CONFIRMED safe.
   `ALTER POLICY ... USING (...)` is a single DDL statement updating the
   USING expression in place (same policy OID) — no window where the policy
   doesn't exist, unlike a `DROP POLICY; CREATE POLICY` sequence. Same
   pattern 10c's own `000033` migration already used in this same table.
6. **`Config.get/0` read-fresh race/edge case** — no new risk beyond what
   9a/10c already accept for every other `media_config` value: read is a
   single ETS lookup per call, no worker-side caching. Not a regression.

## Additional finding — self-fixed during this review (MINOR, defensive hardening)

`handle_kill_switch/3`'s `case` had no catch-all clause: an unexpected
`scan_kill_switch` value (only reachable via a corrupted row / manual DB edit
bypassing `Nebu.Media.Config.upsert/1`'s validation — not reachable through
any application code path) would raise an uncontrolled `CaseClauseError`
instead of failing safe. Given the story's own central safety philosophy
("never silently fail_open"), fixed inline: added an `other ->` clause that
logs a warning and calls `scan_error/4` (fails CLOSED), consistent with the
"when in doubt, fail closed" posture the rest of this story establishes.
Re-verified: full unit suite still 1948/1948 passed after the fix.

## Verdict: CLEAN (0 MAJOR/CRITICAL, 1 MINOR self-fixed inline).
