# Test Quality Review: media_released_auto_delete_worker_test.exs (pre-dev, Step 3)

## AC Coverage Map

| AC | Tests | Status |
|---|---|---|
| AC1 (nil disables; only positive int enables; 0/neg/non-int refuse) | Test 1 (nil), Test 7 (0, -5) | Partial — non-integer case untested |
| AC2 (transition via StateMachine, actor {:system, nil}, ledger-derived eligibility) | Test 2, Test 3, Test 4 | Covered |
| AC3 (nil = complete no-op, zero query/transition/audit) | Test 1 | Covered |
| AC4 (audit shape: action/actor/target/metadata/outcome) | Test 5, Test 6 (allowlist) | Covered |

## Findings

**MAJOR — Per-file failure isolation entirely untested.** Story's Technical Requirements mandate
that one file's `StateMachine.transition/4` error must not abort the batch. Sibling worker 8a has a
dedicated test for exactly this (`media_cleanup_worker_test.exs` Test 11, lines 669-689: one failing
row + one succeeding row, asserts the succeeding row still completes). This file has no equivalent —
none of the 7 tests seed more than one eligible file. If a dev implementation uses
`Enum.each`/`Enum.map` without a rescue per item, a regression that aborts the whole batch on the
first error would pass all 7 current tests.

**MAJOR — AC1's "non-integer" case has zero test coverage.** Test 7 loops over `[0, -5]` — both
integers. AC1 explicitly lists three invalid-config categories: "0, negative, non-integer." The
worker's config-read test seam bypasses `Nebu.Media.Config`'s own validate/coerce path entirely and
hands the raw override value straight through, so a float, string, or boolean is a realistic runtime
shape the worker must defensively reject — not just theoretical. No such value is exercised, so a
worker that only guards `value <= 0` (integer check omitted) would pass all tests while crashing or
misbehaving on e.g. `"30"` or `1.5`.

**MINOR — No test with teeth against the worker directly hard-deleting or invoking
`MediaCleanupWorker`.** Sibling 8a has a test asserting `repo_calls()` never contains a raw
`SET state =` write. This file has no analogous assertion excluding `hard_deleted_at`/`storage_key`
writes, nor a check that `MediaCleanupWorker` was never invoked directly.

**INFO — 464 lines / 7 tests.** Matches this codebase's established convention for Oban-worker ATDD
suites (8a's file is 809 lines with equivalent Fake-Agent scaffolding) — not a real defect.

**Other checks — clean.** No hard waits/Process.sleep; timing is deterministic (relative offsets).
Boundary test (exactly-30-days) uses strict `<`, directionally consistent with 8a's own filter
logic. `nil`-vs-`0` conflation is separately asserted (Test 1 vs Test 7), not just implied. Audit
metadata assertions are explicit.

## Verdict

**2 MAJOR found.** Per orchestrator instructions, pre-dev test-review MAJOR gaps are a caller
decision point — pipeline paused here, not auto-cycled.

---

## Re-review (post-fix, cycle 1) — CLEAN

Both MAJOR findings verified fixed:
- Per-item failure isolation: new Test 2b seeds two distinct :released files, forces one to fail via
  @transition_overrides, asserts the OTHER file's transition still succeeds independently (not a
  shallow "didn't crash" check).
- AC1 non-integer: Test 7's bad-value loop now covers [0, -5, "30", 1.5] with identical full
  no-op assertions across all four.

MINOR (hard-delete assertion) present but noted as low marginal value: FakeRepo.query!/2 raises on
any unrecognized SQL before the new refute is reached, so the refute mostly documents intent rather
than adding independent detection power beyond the pre-existing incidental raise. Not blocking —
carried forward as INFO, not re-opened as MAJOR since the raise-based protection is real (just
implicit rather than the requested explicit form). No new issues introduced by the edit (atom-length
description shortening verified cosmetic-only, no dropped assertions; Agent-seam scoping clean,
fresh start_link + on_exit per test).

**Verdict: CLEAN (0 MAJOR).** Proceeding to dev-story.
