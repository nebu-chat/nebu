# Session 2026-07-20 — 10d-scan-kill-switch security review

**Scope:** health-check branch in `Nebu.Workers.MediaScanWorker.scan_and_transition/3`
(`clamav_healthy?/0`, `handle_kill_switch/3`), new `scan_kill_switch` key in
`Nebu.Media.Config` (default `"fail_closed"`), migration `000034` (`ALTER POLICY`
extension of `media_config_update_mutable`, no new table), `media_unscanned_release`
added to `AuditWriter.@known_actions`.

**Verdict: CLEAN (APPROVED).** 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW (already
self-fixed before this review began; independently re-verified rather than trusted).

## Key checks (verified against real code, not dev/code-review summaries)

- **AC7 audit-completeness is linear, no silent-skip.** `handle_kill_switch/3`'s
  `"fail_open"` clause: hard-match transition → broadcast → unconditional `write_audit/4`.
  A transition failure never reaches the audit call (raises first, no partial-success
  state) — there is no branch that releases the file while skipping the audit.
- **Default-`fail_closed` defended at 3 independent layers**, all re-verified: compile-time
  `@defaults`, DB-absent-row behavior, and the shared `@default_catalog` test fixture (breaks
  7+ unrelated assertions on any silent regression — the strongest of the three, since it's
  enforced by the CI gate itself, not just this story's own tests).
- **`health_check/0` shape correctly matched.** Read `Nebu.Media.ClamAV` directly — confirmed
  `%{healthy: boolean(), changed_at: DateTime.t()}` (Story 3 + 10b), NOT the story's own
  stale bare-atom pseudocode. `clamav_healthy?/0`'s `match?(%{healthy: true}, ...)` is correct.
- **No new-table GRANT gap** (9a's own HIGH-class pattern #86 — checked explicitly, does not
  recur): migration 000034 is `ALTER POLICY` only, no `CREATE TABLE`; `nebu_app` already had
  full DML on `media_config` since 000023.
- **Migration DDL safety confirmed** — `ALTER POLICY ... USING (...)` is a single atomic
  statement (same policy OID throughout), no window where the policy is absent, unlike
  `DROP POLICY; CREATE POLICY`.
- **`scan_error/4` reuse for `fail_closed` confirmed genuinely verbatim** (diffed the function
  — zero lines changed) — no duplicated retry/discard logic introduced.
- **Chain-risk noted, not a new/blocking finding:** Story 3's own F-4 (unauthenticated clamd
  TCP control plane) was already remediated in `docker-compose.yml` (no host port published,
  compose-network-only). Combined with THIS story's opt-in `fail_open`, an attacker who has
  ALREADY breached the docker network boundary could force a "release unscanned" primitive
  by killing clamd — but that requires both an admin's explicit opt-in AND a pre-existing
  network compromise, not a new remotely-exploitable surface this story introduces on its
  own. Flagged for epic-end holistic re-review per pattern #35 (per-story CLEAN reviews can
  stack into combined risk at epic-end).
- **1 LOW, already fixed by the time I reviewed it** — independently re-verified rather than
  trusted: `handle_kill_switch/3`'s `case` originally had no catch-all for an unexpected/
  corrupted `scan_kill_switch` value (only reachable via a manual DB edit bypassing the
  validated `upsert/1` path) — would have raised `CaseClauseError`. Confirmed the fix (an
  `other ->` clause that logs + fails CLOSED) is present in the current file and the full
  unit suite (1948/1948) passes with it.

## New pattern candidate (not yet promoted to numbered MEMORY pattern — low confidence, only
one instance so far)

Config-driven `case` dispatches on an admin-only-writable-via-validated-seam value (like
`scan_kill_switch`) are a softer instance of the "default-deny state gate, not enumerated
allow-list pairs" pattern (#83) — that pattern was written for HTTP/state-machine gates;
worth watching whether it recurs on other admin-config-driven branches (e.g. any future
story reading a similarly-validated enum config key and branching on it) before promoting to
its own numbered entry.

## Time spent: efficient — this story's diff is small and well-isolated (one worker function,
one config key, one RLS-only migration, one allowlist entry); most of the session was spent
confirming the story's own illustrative pseudocode had NOT been faithfully-but-incorrectly
copied (the health_check shape and the `:nebu_http` vs `:nebu` app-env namespace — both
correctly caught and fixed by the dev/code-review steps already, independently re-verified
here rather than trusted).
