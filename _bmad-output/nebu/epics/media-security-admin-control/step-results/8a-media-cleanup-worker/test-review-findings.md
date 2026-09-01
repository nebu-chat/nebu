---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-quality-evaluation', 'step-04-generate-report']
lastStep: 'step-04-generate-report'
lastSaved: '2026-07-19'
story: 'media-security-admin-control/8a-media-cleanup-worker'
gate: 'pre-dev (RED-phase ATDD review)'
recommendation: 'Approve with comments — no MAJOR blockers'
inputDocuments:
  - '_bmad-output/nebu/epics/media-security-admin-control/step-results/8a-media-cleanup-worker/atdd-input.md'
  - 'docs/stories/media-security-admin-control/8a-media-cleanup-worker.md'
  - 'server/test/nebu/workers/media_cleanup_worker_test.exs'
  - 'server/test/nebu/media/state_machine_test.exs'
  - 'server/test/nebu/compliance/audit_writer_media_actions_test.exs'
  - 'server/lib/nebu/workers/media_reserved_upload_cleanup_worker.ex'
  - 'server/lib/nebu/compliance/session_expiry_worker.ex'
  - 'server/lib/nebu/compliance/audit_writer.ex'
  - 'server/lib/nebu/media/storage.ex'
  - 'server/priv/migrations/000022_media_state_machine_foundation.up.sql'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/test-quality.md'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/data-factories.md'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/test-levels-framework.md'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/timing-debugging.md'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/error-handling.md'
  - '.claude/skills/bmad-testarch-test-review/resources/knowledge/test-healing-patterns.md'
---

# Test Quality Review — Story 8a: Media Cleanup Worker (Pre-Dev TDD Gate)

**Review Date:** 2026-07-19
**Reviewer:** TEA (Test Architect) — Test-Review Mode
**Scope:** RED-phase ATDD tests, pre-implementation gate
**Recommendation:** **Approve with comments** — no MAJOR blockers to dev-story start; two MINOR hardening items and one dev-guidance risk flagged below.

---

## Files Reviewed

| File | Type | Status |
|---|---|---|
| `server/test/nebu/workers/media_cleanup_worker_test.exs` | New, 732 lines, 13 tests (AT1,2,5-15) | RED confirmed (module doesn't exist) |
| `server/test/nebu/media/state_machine_test.exs` | Extended, +1 test (AT3, `infected -> hard_deleted` edge) | RED confirmed (`@transitions` still lacks the edge) |
| `server/test/nebu/compliance/audit_writer_media_actions_test.exs` | Extended, +1 test (AC10 allowlist regression) | RED confirmed (`@known_actions` still lacks `media_hard_deleted`) |

All three RED claims were verified directly against source, not taken on faith:
- `server/lib/nebu/workers/media_cleanup_worker.ex` does not exist.
- `Nebu.Media.Storage` exposes only `get/1`, `put/2`, `compress/1` — no `delete/1`.
- `Nebu.Media.StateMachine`'s `@full_guard_table`/real `@transitions` still reads `infected: [:deleted, :released]` — no `:hard_deleted` edge.
- `Nebu.Compliance.AuditWriter.@known_actions` does not contain `media_hard_deleted`.

---

## Specifically-Requested Verifications

### AC8 candidate-query taxonomy (fresh :deleted / fresh :infected / reaper) — PASS

Tests 5 and 6 correctly cover "left untouched" for fresh `:deleted`/`:infected` rows (asserting zero transition/storage/audit calls). Test 7 (`seed_hard_deleted_complete`) and Test 8 (`seed_hard_deleted_intermediate`) are **correctly distinguished** — this is the exact conflation risk flagged in the review brief, and the test suite gets it right:
- Test 7 proves true idempotency by running `perform_job/2` **twice** against a fully-completed row (`storage_key` already nil) and asserting zero further calls both times — a stronger proof than a single-run check.
- Test 8 seeds a row already in `state = "hard_deleted"` with `storage_key` still populated (the crash-recovery scenario) and asserts `Storage.delete/1` + the null-UPDATE run, while explicitly `refute`-ing that `StateMachine.transition/4` is invoked again.

### AC8/AT9-AT10 call-ORDER assertions — PASS

Test 9 uses a genuine ordered event log (`@event_log`, an `Agent`-backed list of `{:storage_delete, key}` / `{:null_update, media_id}` tags appended by the fakes themselves) and asserts `delete_index < null_index`. This is a real sequence assertion, not merely "both were called" — satisfies the ADR-032 step-ordering requirement precisely.

### AT11 per-row isolation — PASS, with a documentation gap (see MINOR-1)

Test 11 seeds **two distinct** candidate rows (`media-multi-fail-1`, `media-multi-ok-1`), forces `Storage.delete/1` to raise for the first via the `@storage_overrides` fake, and asserts the second row still completes fully (`storage_key`/`uploader_user_id` nulled + an audit entry present). This is not a single-row happy-path test — it is the real two-row isolation test the brief asked to confirm.

### AT14 "never raw SQL on state" — PASS

Test 14 inspects the actual `FakeRepo` call log (`repo_calls()`) and regex-matches the SQL text itself (`~r/SET\s+[^;]*\bstate\s*=/i` must never match), while positively asserting that `hard_deleted_at` and `storage_key` SQL calls do occur. This is a direct SQL-shape assertion against a call log, not a behavioral proxy.

---

## MAJOR Findings

**None that block dev-story start.** One dev-guidance risk is flagged below because it could cause implementation churn against a correctly-written test, not because the test itself is wrong.

### MAJOR-adjacent-1 (dev-guidance, not a test defect): AC8's cited precedent for "per-row isolation" does not actually do per-row isolation

The story's own AC8 text says the worker processes rows "same defensive style as `Nebu.Compliance.SessionExpiryWorker`". Direct inspection of `server/lib/nebu/compliance/session_expiry_worker.ex` shows its `rescue` clause wraps the **entire** `scan_and_audit_expired_sessions/0` function — i.e. rescue is per-**tick**, not per-**row**. If one row in that worker's `Enum.each` raised, the whole tick would abort and every row after it in that pass would be skipped that cycle (not "isolated" — just not-crash-the-BEAM-process).

Test 11 (correctly) requires true per-row isolation: the `ok` candidate must complete even though the `fail` candidate's `Storage.delete/1` raises **in the same run**. If dev-story implements this by literally copying `SessionExpiryWorker`'s function-level-rescue pattern (as the AC8 text's citation invites), test 11 will fail — correctly, but the misleading citation risks a wasted implementation cycle. Flag this explicitly for dev-story: the worker needs a `try/rescue` (or `Enum.each` + per-item rescue) **inside** the per-candidate loop body, not around the whole tick.

Also worth noting: `server/lib/nebu/workers/media_reserved_upload_cleanup_worker.ex` (Story 2e, cited elsewhere in this story's docs as the sibling precedent) uses `Enum.reduce_while` — which **halts the entire enumeration** on the first non-`:invalid_transition` error. That pattern would also fail test 11. Neither of this story's two cited "precedents" actually satisfies AC8's per-row-isolation requirement as written — this is worth a one-line callout in the story's Dev Agent Guardrails before dev-story starts, since it's the kind of gap that's easy to miss when pattern-matching against "the precedent the story cites."

---

## MINOR Findings

### MINOR-1: Test 11's isolation proof relies on undocumented Erlang map key-ordering

`FakeRepo.select_deleted_candidates/1` iterates `Agent.get(bucket(), & &1)` — a plain Elixir `Map`. For small maps (≤32 keys), Erlang enumerates in term-sorted key order, and `"media-multi-fail-1"` sorts before `"media-multi-ok-1"` (`'f' < 'o'` lexically) — so the failing row is deterministically visited before the ok row today. That ordering is exactly what makes the test able to catch a halt-on-first-error implementation (see MAJOR-adjacent-1): if `ok` were visited first, the test would pass even against a broken implementation, because `ok` would already be done before `fail`'s exception fires.

This works, but it is **not documented** anywhere in the test as a load-bearing invariant. A future change (map growing past 32 keys and switching internal representation, or the real production `SELECT` — which has no `ORDER BY` clause in AC3 — returning rows in a different physical order once the fake is swapped for real Postgres) could silently change which row is visited first, without the test noticing that it stopped exercising the intended failure-isolation path.

**Recommendation**: extend the existing `@event_log` (already used by test 9) to also record a `{:candidate_started, media_id}` tag, and have test 11 assert `fail` was attempted before `ok` completed — making the ordering explicit and self-verifying rather than an accidental consequence of map term-ordering.

### MINOR-2: Test 12 proves audit-after-null-update by end-state only, not by call order

AC9 requires the audit entry to be written **only after** AC7 (the storage_key/uploader_user_id null-UPDATE) succeeds. Test 12 asserts `row.storage_key == nil` and that exactly one matching audit entry exists — but since the whole `perform/1` call is synchronous, this proves "both eventually happened," not "audit happened after the null-update." A hypothetical bug where the audit write is issued speculatively before AC7 (but AC7 still happens to complete afterward in the same call) would not be caught.

Test 9 already solved exactly this class of problem for delete-vs-null ordering via the ordered `@event_log`. Recommend applying the same technique to test 12: add an `:audit_log` tag to the event log (appended by `FakeAuditWriter.log/6`) and assert its index comes after the corresponding `:null_update` index, mirroring test 9's `delete_index < null_index` pattern.

### MINOR-3: Test 10's docstring promises reaper-eligibility that the test doesn't itself verify

Test 10's name states the row "remains eligible for the next run's completion sweep," but the test body only asserts the row's post-failure state (still `hard_deleted`, `storage_key` still set, no audit entry) — it does not run a second `perform_job/2` to actually prove the reaper query would pick it up next time. This is not a coverage gap in practice (test 8 already independently proves the reaper query's behavior on an intermediate row with the exact same shape), but the test name overclaims what it verifies. Low-cost fix: either soften the test name, or add a follow-up `perform_job/2` call to close the loop explicitly.

---

## INFO / Notable Observations (no action needed)

- **Deliberate double coverage of AC10 (`media_hard_deleted` in `@known_actions`)**: both `media_cleanup_worker_test.exs` (Test 13, via a self-contained `KnownActionsFakeRepo`) and the dedicated extension in `audit_writer_media_actions_test.exs` assert the same allowlist fact independently. This mirrors the exact precedent set by Story 4c/6a for this same documented repo footgun (a merge silently dropping an audit action from the allowlist) — the redundancy is intentional defense-in-depth for a known regression class, not accidental duplication.
- **Numbering gap (AT4 absent)**: the ATDD input's Acceptance Tests list skips from 3 to 5. This is not a defect — Test 3 (the `infected -> hard_deleted` guard-table edge) is intentionally colocated in `state_machine_test.exs` rather than the worker test file, and there was never an "AT4" as a separate deliverable; it maps to AC4's coverage already folded into Tests 1/2.
- **Seam names verified against the whole codebase, not just this story**: `:media_state_machine_module`, `:media_storage_module`, `:media_audit_writer_module` (all under the `:nebu_http` app-env namespace) match every other media test file exactly (`media_scan_worker_test.exs`, `media_upload_test.exs`, `media_reserved_upload_cleanup_worker_test.exs`, etc.). The new `:media_cleanup_repo_module` seam is appropriately distinct from Story 2e's own `:media_reserved_cleanup_repo_module` (no collision). The retention-config key (`Application.get_env(:nebu, :media_cleanup, [])`, deliberately under the `:nebu` namespace rather than `:nebu_http`) matches the story's own stated Technical Requirements. No naming drift found.
- **Schema claims verified against the actual migration**: AC3's claim that `media_files` has `archived_at`/`deleted_at`/`hard_deleted_at` but no `infected_at` column was checked directly against `priv/migrations/000022_media_state_machine_foundation.up.sql` — accurate.
- **`StateMachine.transition/4` signature verified**: the test's assumed call shape (`transition(media_id, :hard_deleted, {:system, nil}, metadata)`) matches the real function head (`def transition(media_id, to_state, actor, metadata \\ %{})`) exactly.
- **Fully deterministic timing**: all age-threshold logic uses `System.system_time(:millisecond)` integer arithmetic seeded directly into fake state — no `Process.sleep`, no wall-clock waits, no flakiness risk from timing.
- **Isolation discipline is solid**: `async: false` is the correct choice given global named `Agent`s and `Application.put_env/3` global config; `setup`/`on_exit` cleanly starts and tears down all 8 agents and deletes all 5 env keys per test, preventing cross-test bleed.

---

## Decision

**Recommendation: Approve with comments.** No MAJOR defects in the tests themselves. Before dev-story starts, surface MAJOR-adjacent-1 to whoever implements the worker (the two cited "precedent" workers do not actually demonstrate per-row isolation — a genuinely per-candidate `try/rescue` is required, not a copy-paste of either cited pattern). MINOR-1 and MINOR-2 are worth a quick follow-up hardening pass (extending the existing `@event_log` technique from test 9 to tests 11 and 12) either now or immediately after dev-story, since both are cheap, mechanical fixes to an already-well-designed fake harness. MINOR-3 is cosmetic.

**Re-Review Needed?** No re-review required before dev-story begins. A light follow-up review of the two `@event_log` extensions (MINOR-1/2) is reasonable once applied.
