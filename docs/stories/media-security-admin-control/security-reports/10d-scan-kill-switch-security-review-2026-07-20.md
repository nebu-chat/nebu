# Security Review — media-security-admin-control / 10d-scan-kill-switch

**Reviewer:** Kassandra (nebu-agent-kassandra, adversarial security review)
**Diff scope:** `git diff --staged` — health-check branch in
`Nebu.Workers.MediaScanWorker.scan_and_transition/3`
(`server/lib/nebu/workers/media_scan_worker.ex`), new `scan_kill_switch` key in
`Nebu.Media.Config` (`server/lib/nebu/media/config.ex`), migration `000034`
(RLS-policy extension only, no new table), `+ media_unscanned_release` in
`Nebu.Compliance.AuditWriter.@known_actions`, and test files.
**Date:** 2026-07-20
**Verdict:** **APPROVED — CLEAN** (0 CRITICAL, 0 HIGH, 0 MEDIUM; 1 LOW advisory)

---

## Method

This story is explicitly an availability-vs-safety tradeoff on the malware-scanning
pipeline — the highest-stakes kind of feature in this epic (a misconfigured or bypassed
kill-switch lets unscanned, potentially malicious files reach other room members). Every
claim was re-derived against live source:

- Read `Nebu.Workers.MediaScanWorker` end-to-end (not just the diff hunk) — the full
  `perform/1` → `scan_and_transition/3` → `clamav_healthy?/0` → `handle_kill_switch/3` call
  graph, and confirmed `do_scan_and_transition/3` (the renamed pre-existing body) is
  byte-for-byte unchanged from Story 4b except for the rename.
- Read `Nebu.Media.ClamAV.health_check/0` (Story 3, extended by 10b) directly — confirmed
  its real return shape `%{healthy: boolean(), changed_at: DateTime.t()}` and that
  `clamav_healthy?/0`'s `match?(%{healthy: true}, ...)` is the correct pattern (the story's
  own illustrative pseudocode used a stale bare-atom shape — dev-story correctly deviated
  from it, code-review already caught and confirmed this independently).
- Read `Nebu.Media.Config`'s `@defaults`, `validate_value/2`, and the shared
  `@default_catalog` test fixture — confirmed the `"fail_closed"` default is defended at
  three independent layers (compile-time default, DB-absent-row behavior, and a hard test
  fixture that breaks 7+ unrelated assertions if the default ever silently changes).
- Read `Nebu.Compliance.AuditWriter.@known_actions` and confirmed `media_unscanned_release`
  is present in the same commit as the code that emits it (the 4c/6a/8a/8c/9a allowlist
  gotcha this project's own MEMORY records repeatedly — checked, not assumed).
- Read migration `000034` and its `.down.sql` — confirmed `ALTER POLICY` (not
  `DROP POLICY; CREATE POLICY`), and confirmed against `000023_media_config.up.sql` that
  `GRANT SELECT, INSERT, UPDATE, DELETE ON media_config TO nebu_app` was already granted at
  table-creation time (9a's own HIGH finding, already fixed) — this migration adds no new
  table, so that HIGH-finding class does not recur here.
- Read `docker-compose.yml`'s `clamav` service definition — confirmed Story 3's own F-4
  finding (unauthenticated clamd TCP control plane, including a `SHUTDOWN` verb) was already
  remediated: no `ports:` mapping is published for `clamav`, reachable only from other
  containers on the compose network by service name.
- Cross-checked my own MEMORY.md for recurring epic patterns: the audit-allowlist-merge
  gotcha (present, closed), the new-table-missing-GRANT class (N/A — no new table), the
  default-deny-not-enumerated-allowlist pattern (`handle_kill_switch/3`'s two-clause `case`
  — checked for a silent fall-through, see Findings).

---

## Findings

| # | Severity | Location | Finding | Remediation |
|---|----------|----------|---------|-------------|
| 1 | LOW | `media_scan_worker.ex:158` (`handle_kill_switch/3`) | Prior to this review's own fix, the `case` on `scan_kill_switch` had exactly two clauses (`"fail_open"`, `"fail_closed"`) with no catch-all — an unexpected/corrupted config value (only reachable via a manual DB edit bypassing `Nebu.Media.Config.upsert/1`'s validated write path; not reachable through any application code path) would raise an uncontrolled `CaseClauseError` instead of failing safe. **Already self-fixed during code-review** (same commit): a catch-all `other ->` clause now logs a warning and calls `scan_error/4` (fails CLOSED), consistent with the story's own "never silently fail_open" posture. Verified the fix is present in the current file and the full unit suite (1948/1948) still passes. | None — already remediated. Recorded per this project's "default-deny state gate" pattern (MEMORY #83) for the institutional record. |

No CRITICAL, HIGH, or MEDIUM findings.

---

## Detail — the specific attack surfaces this story's own design flags

### 1. Can `fail_open` release a file WITHOUT the audit entry (silent compliance bypass)?

No. `handle_kill_switch/3`'s `"fail_open"` clause is a linear 4-step sequence with no
branch that skips the last step: `{:ok, :released} = state_machine().transition(...)` (hard
match — any non-`{:ok, :released}` return raises, which means the file was NOT released and
`write_audit/4` is never reached either; there is no partial-success state), then
`broadcast/2` (a `Phoenix.PubSub.broadcast/3` call, effectively cannot fail), then
`write_audit(media_id, "media_unscanned_release", "success", metadata)` unconditionally.
There is no early return, no conditional guard, and no code path between the transition and
the audit call that could short-circuit. `AuditWriter.log/6` itself never raises (existing,
independently-tested contract) so a downstream DB failure degrades to a logged error, not a
crash — but the CALL is always made; the only way to lose the audit event is the pre-existing,
project-wide-accepted "audit write itself fails after a committed state change" pattern
(identical to `Config.upsert/2`'s own accepted m3, `session_expiry_worker`,
`media_released_auto_delete_worker`, etc.) — not a new or 10d-specific gap.

### 2. Can an under-privileged/unauthenticated actor influence `scan_kill_switch`?

No new surface. `Nebu.Media.Config.upsert/1` is the sole write path (ADR-020) and does its
own authz-free validation (`upsert/1`'s `actor` parameter is caller-attributed, exactly as
9a's own security review already noted and accepted — "audit attribution is caller's (9b)
responsibility"); the actual admin-authentication/authorization gate lives at Story 9b's
`/admin/media/settings` route (`live_session :admin, on_mount {Auth, :require_admin}`,
pattern #67 in my memory), which is unchanged by this diff. The migration's RLS policy
(`media_config_update_mutable`) only extends the mutable-KEY allowlist by one string
literal — it does not touch role grants, and the runtime role (`nebu_app`) already had full
DML on this table since 9a's own migration. No RLS gap: the `ALTER POLICY` statement is a
single atomic DDL operation updating the `USING` expression in place (same policy OID
throughout) — there is no window during which the policy is absent or the table is
unprotected, unlike a `DROP POLICY; CREATE POLICY` sequence.

### 3. Can the health-check be tricked into a false unhealthy/healthy report?

`clamav_healthy?/0` calls the REAL `Nebu.Media.ClamAV.health_check/0` (Story 3's GenServer,
its own on-demand TCP probe) — this worker introduces no new network path, no new trust
boundary, and no way to forge the health result short of actually controlling clamd's TCP
connection. That requires network access to the `clamav` compose service, which (per Story
3's own F-4 finding, already remediated) publishes no host port and is reachable only from
other containers on the compose network — i.e. an attacker would need to already have
compromised another container on that network, a materially higher bar than "malware
scanner is briefly down." Noted for institutional record (not a new finding): if an operator
has explicitly opted into `fail_open` (an audited, deliberate admin choice) AND an attacker
who has already breached the docker network can additionally reach clamd's unauthenticated
`SHUTDOWN` verb, that attacker could force the kill-switch to fire. This is a *combination*
of two already-reviewed, already-accepted risk decisions (Story 3's F-4 network
segmentation + this story's opt-in fail_open), not a new vulnerability this story
introduces — flagged here for future epic-end holistic review, per the "per-story CLEAN can
stack" pattern (MEMORY #35), but does not block this story on its own.

### 4. TOCTOU between health-check and scan/release decision?

None with security consequence. The health-check and the subsequent branch execute
synchronously within the same `perform/1` call, on the same GenServer-serialized
`Nebu.Media.ClamAV` process (only one scan/health-check call is in flight against clamd at a
time, per Story 3's single-named-GenServer design) — there is no window between "checked
healthy" and "used healthy" where an external actor could flip the state to gain anything: if
clamd goes down in the few milliseconds between the health-check reply and the subsequent
`scan_binary/1` call on the healthy path, that call simply fails with a transport error and
falls into the pre-existing (Story 4b) `scan_error/4` retry path — exactly the intended
"scanner failed mid-attempt" handling, not a kill-switch bypass. There is no reverse race
(healthy → treated as unhealthy) with any exploitable effect, since "unhealthy" only ever
produces MORE conservative behavior for `fail_closed` (hold/retry) and an explicitly
admin-accepted, audited outcome for `fail_open`.

### 5. Does default-fail_closed hold on every code path, including errors/exceptions?

Yes, verified end-to-end:
- **Normal path:** `@defaults` ships `"fail_closed"`; absent a row, `build_catalog/1` never
  overrides it.
- **Unexpected/corrupted value:** now fails closed via the catch-all clause (Finding 1,
  already fixed).
- **`media_config()` seam misconfiguration:** if the seam's `get/0` implementation ever
  raised, the worker's `perform/1` would raise too — Oban's own retry/dead-letter handling
  takes over (fail loud, not fail open) — no code path silently defaults to `"fail_open"` on
  an exception. This mirrors the accepted reasoning in 8d's own review for `Config.get/0`
  raising ("strictly safer than guessing an active window").
- **Live-policy-change race:** `Nebu.Media.Config.get/0` is read fresh (ETS-backed, no
  worker-side caching) on every `perform/1` invocation — there is no stale-cache path that
  could serve a previously-fetched `"fail_open"` after an admin has reverted to
  `"fail_closed"`, or vice versa; each job sees the current value at the moment it checks.

---

## Summary

- **CRITICAL:** 0
- **HIGH:** 0
- **MEDIUM:** 0
- **LOW:** 1 (already self-remediated during code-review; recorded for the audit trail)

**Classification: CLEAN.** The default-`fail_closed` guarantee, AC7's non-negotiable audit
requirement, and the health-check-branch's correctness against the real `ClamAV.health_check/0`
shape all hold under adversarial inspection, backed by direct reads of the live source and
migration files — not the story's own (partially stale) illustrative pseudocode.

No code was modified during this review — Finding 1 was already fixed in the same commit
before this review began; this report independently re-verified that fix rather than
trusting the dev/code-review summary.
