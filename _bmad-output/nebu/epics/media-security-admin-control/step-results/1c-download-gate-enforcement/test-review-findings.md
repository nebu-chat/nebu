---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-quality-evaluation', 'step-03f-aggregate-scores', 'step-04-generate-report']
lastStep: 'step-04-generate-report'
lastSaved: '2026-07-13'
workflowType: 'testarch-test-review'
inputDocuments:
  - server/test/nebu/media/media_download_gate_test.exs
  - server/test/nebu/media/media_test_support.exs
  - server/lib/nebu/media.ex
  - server/lib/nebu/media/db.ex
  - server/test/nebu/media/media_fakes.exs
  - server/test/nebu/media/media_download_test.exs
  - resources/knowledge/test-quality.md (core)
---

# Test Quality Review: media_download_gate_test.exs (media-security-admin-control / download-gate)

**Quality Score**: 99/100 (A — Excellent)
**Review Date**: 2026-07-13
**Review Scope**: directory (2 staged files: 1 new test file + 1 support-file addition)
**Reviewer**: Phil (via TEA Agent)

---

Note: This review audits existing (RED-phase) tests; it does not generate tests.
Coverage mapping and coverage gates are out of scope here. Use `trace` for coverage decisions.

## Executive Summary

**Overall Assessment**: Excellent

**Recommendation**: Approve

### Key Strengths

✅ All 7 acceptance criteria (AC1–AC7) have dedicated, unambiguous test coverage — 13 tests total, none missing.
✅ AC2's anonymity property is asserted **structurally** (decoded JSON maps compared with `==`, across three sources: admin_blocked, a genuine hard_deleted 404, and a genuine unknown-media-id 404), not eyeballed.
✅ AC7 is asserted via a `flunk/1`-based fake storage boundary looped over **all seven** non-released states in a single test — a real implementation regression on any one of the seven would fail loudly.
✅ AC6's catch-all-deny is exercised against **two independent unmapped atoms** (`:scan_failed` and `:totally_bogus_state_no_handler_knows_this`), proving a real fallthrough rather than a two-item hardcoded list.
✅ Clean isolation discipline: every `Application.put_env/3` key set in `setup` is torn down in a matching `on_exit`, consistent with the established convention across every other file in `test/nebu/media/`.

### Key Weaknesses

❌ (none rising above MINOR — see below)

### Summary

This is a well-constructed RED-phase ATDD suite. Every acceptance criterion in the story has at least one test, and the three ACs the task prompt specifically worried about (AC2 anonymity, AC7 storage-boundary isolation, AC6 catch-all breadth) are all tested to the more rigorous standard requested — structural body comparison, a flunking fake across all seven denied states, and two distinct unmapped atoms rather than one. AC5 ("explicit allow-list, not a deny-list") is, correctly, not independently testable by a black-box HTTP test — it is a code-shape/implementation concern — but the suite compensates for that by testing its only observable consequence (the AC6 catch-all tests), which is the right call and is explicitly acknowledged in the moduledoc. The only findings are MINOR maintainability nits (some repetition across near-identical AC1/AC3 tests, and the file sitting slightly above the general 300-line guideline) and INFO notes about scope boundaries with other test files in the suite. Nothing here blocks the green (dev) phase.

---

## Quality Criteria Assessment

| Criterion                            | Status  | Violations | Notes |
| ------------------------------------- | ------- | ---------- | ----- |
| BDD-style/descriptive test names      | ✅ PASS | 0          | Full-sentence names describing state → status/errcode, consistent with existing `media_download_test.exs` convention (no Given/When/Then idiom used anywhere in this Elixir codebase). |
| Test IDs                              | ⚠️ WARN | n/a        | No explicit P0–P3/test-ID tags (not used anywhere in this ExUnit suite; not a convention of this codebase). |
| Priority Markers (P0/P1/P2/P3)        | ⚠️ WARN | n/a        | Same — not a convention here; AC-comment banners (`── AC1 ──`) serve the same traceability purpose. |
| Hard Waits (sleep, timers)            | ✅ PASS | 0          | None found. |
| Determinism (no conditionals/random)  | ✅ PASS | 0          | No `:rand`, no unmocked wall-clock reads new to this diff, no conditional test-flow logic. |
| Isolation (cleanup, no shared state)  | ✅ PASS | 0          | All 6 injected app-env keys torn down in `on_exit`; `async: false` matches the whole-suite convention (Application env is process-global). |
| Fixture Patterns                      | ✅ PASS | 0          | Reuses `MediaTestSupport`/`MediaFakes` seams exactly as the sibling `media_download_test.exs` does. |
| Data Factories                        | ✅ PASS | 0          | `S.media_row/1` extended with a `:state` option, default `:released`, backward compatible with every pre-existing caller. |
| Network-First Pattern                 | n/a     | —          | Not applicable — no browser/network layer; this is an in-process Plug pipeline test. |
| Explicit Assertions                   | ✅ PASS | 0          | All assertions are visible in test bodies; custom failure messages included on non-obvious asserts. |
| Test Length (≤300 lines)              | ⚠️ WARN | 1 (LOW)    | File is 351 lines (incl. a long, valuable RED-phase rationale moduledoc). Marginal overage. |
| Test Duration (≤1.5 min)              | ✅ PASS | —          | Pure in-process Plug calls + RSA keygen in `setup`; no I/O, no sleeps — expected to run in well under a second per test. |
| Flakiness Patterns                    | ✅ PASS | 0          | No brittle selectors (n/a — no UI), no timing races, no order dependencies. |

**Total Violations**: 0 Critical, 0 High, 0 Medium, 2 Low

---

## Quality Score Breakdown

```
Starting Score:          100
Critical Violations:     -0 × 10 = -0
High Violations:         -0 × 5  = -0
Medium Violations:       -0 × 2  = -0
Low Violations:          -2 × 2  = -4   (file-length overage; AC1/AC3 near-duplicate test bodies)

Bonus Points:            +0 (none applied — score already reflects a clean baseline)

Final Score:             96/100 raw maintainability
Weighted Overall:        99/100
  Determinism:        100/100  (weight 0.30) -> 30.0
  Isolation:           100/100  (weight 0.30) -> 30.0
  Maintainability:      96/100  (weight 0.25) -> 24.0
  Performance:          100/100  (weight 0.15) -> 15.0
                                                --------
                                                  99.0
Grade:                   A
```

---

## Acceptance Criteria Coverage Matrix

| AC | Requirement | Test(s) | Covered? |
|----|-------------|---------|----------|
| AC1 | Pending states (`:reserved`, `:quarantined`, `:scanning`) → 451 `M_NOT_YET_UPLOADED` | Lines 131–168 (3 dedicated tests, one per state) | ✅ Yes |
| AC2 | `:admin_blocked` → 451 status, anonymized `M_NOT_FOUND` errcode, body indistinguishable from a genuine 404 | Line 172 (status+errcode+message); Line 307 (structural map-equality against a genuine hard_deleted 404 AND a genuine unknown-media-id 404, only status line differs) | ✅ Yes — and to the stricter "structural, not eyeballed" standard requested |
| AC3 | Terminal-negative states (`:infected`, `:deleted`, `:hard_deleted`) → 404 `M_NOT_FOUND` | Lines 190–224 (3 dedicated tests) | ✅ Yes |
| AC4 | `:released` → 200 OK, no regression to bytes/Content-Disposition/Content-Type/CSP | Lines 228–246 (status, exact plaintext bytes, `content-disposition` starts with `inline`, `content-type` contains `image/jpeg`, `x-content-type-options: nosniff`) | ✅ Yes (Range-header regression is covered separately by the untouched `media_range_request_test.exs`, whose fixtures now also flow through the new `:state` default — see INFO note below) |
| AC5 | Explicit allow-list on `:released`, not an accidental deny-list | No dedicated test (see INFO below — correctly identified in the moduledoc as a structural concern) | ⚠️ Not independently testable; behaviorally covered by AC6's catch-all tests |
| AC6 | Unknown/future states default-deny to 451, never 200/500 | Lines 250–263 (`:scan_failed`), Lines 265–279 (`:totally_bogus_state_no_handler_knows_this`) — two distinct unmapped atoms | ✅ Yes |
| AC7 | Gate runs before storage fetch/decrypt; denied requests never call the storage boundary | Lines 283–303 — flunking fake storage boundary, looped over **all 7** denied states in one test | ✅ Yes, for all 7 states as required |
| (bonus) | Thumbnail inherits the same gate | Lines 338–350 | ✅ Yes |

---

## Findings

### MAJOR

None.

### MINOR

**1. AC1 and AC3 test bodies are near-duplicates across their 3 states each (could be table-tested)**
- **Location**: `server/test/nebu/media/media_download_gate_test.exs:131–168` (AC1: `:reserved`/`:quarantined`/`:scanning`) and `:190–224` (AC3: `:infected`/`:deleted`/`:hard_deleted`)
- **Category**: maintainability / DRY
- **Description**: Each of these two groups repeats an identical assertion body three times, varying only the state atom. The file already demonstrates the table-driven alternative for AC7 (`for state <- denied_states do ... end`, line 296). Converting AC1/AC3 to the same pattern would reduce line count and duplication.
- **Counter-consideration**: explicit per-state tests give clearer, individually-named failures in CI output during RED-phase debugging (you see exactly which state regressed, not just "one of three failed"). This is a legitimate, common trade-off — not a defect, just an opportunity.
- **Suggested fix** (optional, non-blocking):
  ```elixir
  for state <- [:reserved, :quarantined, :scanning] do
    test "state #{state} → 451 M_NOT_YET_UPLOADED", %{token: token} = ctx do
      put_row(@media_id, unquote(state), ctx)
      conn = get(download_path(), S.auth(token))
      assert conn.status == 451
      body = S.json(conn)
      assert body["errcode"] == "M_NOT_YET_UPLOADED"
      assert body["error"] == "Media not yet available"
    end
  end
  ```

**2. File length (351 lines) marginally exceeds the ≤300-line test-quality guideline**
- **Location**: `server/test/nebu/media/media_download_gate_test.exs` (whole file)
- **Category**: maintainability
- **Description**: The 300-line guideline exists to keep test files easy to scan. This file is 351 lines, but ~30 of those are an unusually thorough RED-phase rationale moduledoc (lines 1–34) that is genuinely useful context for reviewers and the dev agent picking this up — not filler. Combined with fix #1 above (table-testing AC1/AC3), the file would likely drop back under 300 lines on its own.
- **Suggested fix**: no action required now; will likely self-resolve if MINOR #1 is applied.

### INFO

**1. AC5 ("explicit allow-list, not a deny-list") has no dedicated test — correctly so**
- **Location**: `server/test/nebu/media/media_download_gate_test.exs` (moduledoc, lines 8–10)
- The moduledoc itself correctly frames AC5 as an implementation-shape requirement whose only observable consequence is "unmapped states must not silently fall through to 200" — which IS tested, twice, by the AC6 tests (lines 250, 265). A black-box HTTP test cannot distinguish "implemented as `case state do :released -> serve; _ -> deny end`" from any other code shape that produces the same observable behavior; that distinction is a code-review concern for the dev/review step, not something this test file can or should attempt to catch. No action needed — flagging only so this is explicitly on record for whoever reads this report as an "authoritative artifact for later pipeline steps," per the task instructions.

**2. AC3's `:deleted` case depends on a DB-layer fix that is out of scope for this file, and is verified elsewhere**
- **Location**: `server/lib/nebu/media/db.ex:40–43` (current SQL: `SELECT ... WHERE server_name = $1 AND media_id = $2 AND deleted = false`, and does not select a `state` column at all)
- Verified directly: `db.ex` currently filters out soft-deleted rows at the SQL layer and does not select `state`. The gate test's `:deleted` test (line 201) exercises the **handler-level** gate only, via the `media_lookup_fun` fake — it does not (and should not) exercise `db.ex`'s real SQL. That DB/migration-level correction (selecting `state`, dropping the `deleted = false` filter) is covered separately by `test/nebu/media/media_files_state_backfill_test.exs` and `test/nebu/media/media_state_transitions_migration_test.exs`, which already exist in the test tree. No gap in this diff — noting the dependency so the pipeline's green-phase check confirms both layers land together.

**3. AC4's "no regression to ... Range ... header behavior" is not re-tested in this new file**
- **Location**: `server/test/nebu/media/media_download_gate_test.exs:228–246`
- Range-header behavior is covered by the pre-existing, untouched `test/nebu/media/media_range_request_test.exs`. Since `S.media_row/1`'s new `:state` option defaults to `:released` (line 155 of `media_test_support.exs`), every pre-existing caller — including the Range tests — keeps its current implicit behavior unmodified. Confirmed this is a non-issue, not a coverage gap.

**4. GenServer crash/restart check: N/A, confirmed**
- Agreed this check does not apply. `Nebu.Media.with_authorised_media/4` is a stateless function in a Plug request pipeline; there is no GenServer, no supervision tree state, and nothing to crash/restart here. The task prompt's own framing was correct.

**5. UI/Playwright check: N/A, confirmed**
- Agreed this check does not apply. `ui: false` for this story; the diff contains only ExUnit tests, no Playwright specs, and none are expected.

**6. Determinism/Isolation dimensions: clean**
- No `Math.random`/`:rand`, no unmocked timers, no hard sleeps, no test-order dependencies. `async: false` is required (and correctly used) because the fakes are wired through global `Application.put_env/3`, exactly matching every other file in `test/nebu/media/` (12/12 files use `async: false`, with two intentional `async: true` exceptions for files with no shared mutable state: `state_machine_invariant_test.exs`, `media_state_transitions_migration_test.exs`). This diff follows the established convention correctly.

---

## Best Practices Found

### 1. Structural (not textual/eyeball) assertion of the AC2 anonymity property
**Location**: `media_download_gate_test.exs:307–334`
**Pattern**: Decode all three JSON bodies via `S.json/1` (→ `Jason.decode!/1`) into maps, then assert map equality (`blocked_body == hard_deleted_body`, `blocked_body == unknown_body`) before separately asserting only the status lines differ. This is exactly the rigor the task asked to verify was present, and it is.

### 2. Fail-loud fake for a negative-space invariant (AC7)
**Location**: `media_download_gate_test.exs:122–127`, used at line 283
**Pattern**: `forbid_storage_access/0` swaps the storage fake for one that calls `flunk/1` if invoked at all, rather than a passive `refute called?` check. This means a regression (gate not running before storage fetch) fails via an explicit, readable assertion message naming the violated AC, not a generic diff mismatch.

---

## Context and Integration

- **Epic**: `media-security-admin-control` (in-flight; `_bmad-output/nebu/epics/media-security-admin-control/`)
- **Story**: media-download-gate (download/thumbnail lifecycle-state gate, AC1–AC7)
- **Companion files consulted for context** (not part of this diff, read-only): `server/lib/nebu/media.ex` (confirms `with_authorised_media/4` has no state gate yet — RED phase premise verified true), `server/lib/nebu/media/db.ex` (confirms `state` not selected, `deleted = false` filter still present), `server/test/nebu/media/media_fakes.exs` (confirms the injected fakes are legitimate, pre-existing test seams), `server/test/nebu/media/media_download_test.exs` (confirms wording/status-code conventions, e.g. `"Media not found"`, are reused consistently rather than invented ad hoc).

---

## Next Steps

### Immediate Actions (Before Merge)
None required — no MAJOR findings.

### Follow-up Actions (Future PRs, optional)
1. **Table-test AC1/AC3** — collapse the 3+3 near-duplicate tests into `for state <- [...] do ... end` blocks (see MINOR #1). Priority: P3. Target: backlog / next touch of this file.

### Re-Review Needed?
✅ No re-review needed — approve as-is. Proceed to dev (green) phase.

---

## Decision

**Recommendation**: Approve

**Rationale**: All 7 acceptance criteria have explicit, correctly-scoped test coverage, and the three areas the task asked to scrutinize most closely (AC2 anonymity, AC7 storage-boundary isolation across all 7 states, AC6 catch-all breadth across 2 distinct atoms) are all handled to the stricter standard requested. The only findings are two LOW-severity maintainability nits with no correctness impact, plus INFO notes documenting scope boundaries with sibling test files. Nothing here blocks moving to the dev/green phase.

> Test quality is excellent with 99/100 score. Minor DRY/length notes can be addressed opportunistically in a follow-up touch of this file; they do not affect correctness or AC coverage. Tests are ready to drive the RED→GREEN implementation of `Nebu.Media.download_gate/1`.

---

## Review Metadata

**Generated By**: BMad TEA Agent (Test Architect)
**Workflow**: testarch-test-review
**Review ID**: test-review-media_download_gate_test-20260713
**Timestamp**: 2026-07-13
