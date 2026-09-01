## Security Review — 4a-scan-failed-enum-migration

**Diff scope:** Additive-only ENUM value migration (`ALTER TYPE media_state ADD VALUE
'scan_failed'`, migration `000028`, renumbered from the story's stale `000023` reference)
plus a `Nebu.Media.StateMachine` guard-table extension (`@type state` + `@transitions`
gain the `:scan_failed` key and 6 edges). Test-only changes elsewhere (new/extended
ExUnit files). No new table, no new HTTP endpoint, no new caller of `transition/4` with
`:scan_failed` as a target (that lands in Story 4b, out of scope here).
**Date:** 2026-07-14

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No security issues found | — |

### Detail

No CRITICAL/HIGH/MEDIUM/LOW findings. Notes for the record:

- **Pattern #83 ("default-deny state gate, not enumerated allow-list pairs") re-verified
  against the LIVE enum, not just assumed.** `download_gate/1` (`server/lib/nebu/media.ex`)
  remains an allowlist-of-success (`:released -> :serve`, everything else denies via the
  catch-all tail) — exactly the shape pattern #83 prescribed when it was recorded during
  the pre-implementation review of this same epic. This story's own new regression test
  (`media_download_gate_test.exs`, real `Nebu.Repo`-backed row with `state = 'scan_failed'`)
  is the first test in the codebase to prove this against an actual committed ENUM value
  rather than a bare Elixir atom fixture — closing the loop pattern #83 opened. No code
  change was needed in `download_gate/1` or `parse_state/1`, confirmed not assumed.
- **Rolling-deploy / atom-interning safety confirmed, not just theorized.** `parse_state/1`
  (`server/lib/nebu/media/db.ex`) converts the raw ENUM string via
  `String.to_existing_atom/1`, rescuing `ArgumentError` to a sentinel atom that no
  `download_gate/1` clause matches (fails closed to 451). Because `:scan_failed` is now
  interned by `state_machine.ex`'s own `@transitions` map (compiled into every release that
  includes this story's code), a genuinely mixed-version rolling deploy where migration
  `000028` has already run but an OLD app node (pre-4a build) reads a `scan_failed` row
  would hit the rescue branch on that old node (the atom was never interned in a
  pre-4a release build, since it appeared only in `1c`'s test fixtures, and `test/` is not
  compiled into a release) — and still deny via the catch-all. Fails closed either way.
- **No new attacker-reachable surface.** This story adds no HTTP endpoint, no new
  `transition/4` caller, and no admin-facing action. The new guard-table edges are latent
  capability only — nothing in this diff can actually drive a `media_files` row into or out
  of `:scan_failed` in production yet (that requires Story 4b's `MediaScanWorker.discard/2`,
  not yet implemented). Authorization for the admin-driven edges
  (`:scan_failed -> :released` / `:admin_blocked`) is therefore a Story 4b/admin-UI concern,
  not this one — flagged forward, not as a gap here.
- **Migration is injection-inert.** `000028_media_scan_failed_state.up.sql` is one static,
  non-parameterized `ALTER TYPE ... ADD VALUE 'scan_failed';` statement with no
  user/request-controlled input anywhere in it. The down migration is comments-only (no
  executable SQL). No secrets, credentials, or PII in either file or in any new/changed test
  file (grepped clean).
- **Migration renumbering (000023→000028)** is a pure filename/sequence correction (5 other
  stories claimed 000023-000027 first) — no security implication; already covered in
  code-review.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED — no security issues found.
