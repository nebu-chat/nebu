---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-quality-evaluation', 'step-03f-aggregate-scores', 'step-04-generate-report']
lastStep: 'step-04-generate-report'
lastSaved: '2026-05-28'
story: direct-room-heroes
mode: pre-dev
verdict: PASS
inputDocuments:
  - docs/stories/room-naming-and-default-rooms/direct-room-heroes.md
  - gateway/features/direct_room_heroes.feature
  - gateway/test/integration/direct_room_heroes_steps_test.go
---

# Test Review Report — direct-room-heroes (pre-dev)

**Story:** DM Room Names: Populate Matrix Sync Heroes
**Epic:** room-naming-and-default-rooms
**Mode:** Pre-dev ATDD checklist audit
**Date:** 2026-05-28
**Reviewer:** TEA (Master Test Architect)

---

## Overall Quality Score: 97/100 — Grade A

| Dimension       | Score | Grade | Weight | Weighted |
|-----------------|-------|-------|--------|----------|
| Determinism     | 100   | A     | 30%    | 30.0     |
| Isolation       | 93    | A     | 30%    | 27.9     |
| Maintainability | 96    | A     | 25%    | 24.0     |
| Performance     | 98    | A     | 15%    | 14.7     |
| **Overall**     | **97**| **A** |        |          |

---

## AC Coverage Gate

| Acceptance Criterion | Priority | Scenario(s) | Status |
|---|---|---|---|
| AC1: 1-on-1 DM shows alice as hero | P0 | [AC1] 1-on-1 DM room shows the other participant as hero | COVERED |
| AC2: 3-person DM shows alice+bob as heroes | P0 | [AC2] 3-person DM room shows both other participants as heroes | COVERED |
| AC3: Named room has no heroes | P1 | [AC3] Named room has no summary heroes in sync | COVERED |
| AC4: Initial sync populates heroes for all unnamed DMs | P0 | [AC4] Initial sync populates heroes for all unnamed DM rooms | COVERED |
| AC5: Delta sync omits summary when unchanged | P2 | [Oracle edge] Delta sync omits summary when heroes unchanged | COVERED |

**Gate result: ALL 5 ACs COVERED — no MAJOR gaps.**

---

## Violations

### MEDIUM (1)

- **Isolation — shared `dmRoomID` across scenarios**
  - File: `gateway/test/integration/direct_room_heroes_steps_test.go`
  - `dmRoomID` is set in [AC1] (`aliceCreatesDMRoomWithBob`) and then checked again in [AC4] (`aliceFirstDMRoomHasSummaryMHeroesPopulated`). If scenarios ever run out of order, [AC4] checks whatever room was created last, not necessarily the alice↔bob DM.
  - **Suggestion:** The scenarios must run in declaration order (sequential Godog). Add a comment to `initializeDirectRoomHeroesSteps` making this explicit, or reset `dmRoomID = ""` at the start of [AC4].
  - **Impact:** LOW in sequential Godog — only becomes HIGH if scenario order changes.

### LOW (4)

1. **Credentials hardcoded inline** (`"bob@example.com"`, `"charlie@example.com"`, `"changeme"`) — consistent with other step files; acceptable but worth noting.
2. **`heroesSyncBody` naming** is slightly ambiguous (used for both alice and bob sync bodies); a brief comment on the variable declaration would help.
3. **`aliceCallsGetSyncTimeout0ForHeroes` duplicates** the GET /sync call setup from `personal_self_room_steps_test.go`'s `aliceCallsGetSyncTimeout0`. Consider extracting a generic `callSyncAs(token *string, body *string) error` helper in a shared file.
4. **No state reset between scenarios** for `bobAccessToken`, `charlieAccessToken`, etc. Acceptable for sequential Godog but fragile if tests are ever parallelized.

---

## Test Quality Highlights

- **Excellent ATDD documentation:** Every assertion function includes a comment explaining which implementation step causes it to fail — ideal for TDD-first workflow.
- **Correct `timeout=0` usage:** All sync calls use `?timeout=0` — no hard waits, no flakiness.
- **Deterministic ordering:** Hero SQL uses `ORDER BY joined_at ASC` — test assertions correctly handle set semantics for group DM (checks each MXID independently, not list order).
- **Syncing-user exclusion explicitly tested:** Both [AC1] and [AC2] assert that the syncing user's own MXID does NOT appear in heroes — spec §11.2.2.5 compliance verified.
- **Named-room negative test:** [AC3] correctly tests that named rooms have `summary == nil` or `heroes == []` — covers both valid spec outcomes.
- **Helper function extraction:** `createRoomAs`, `inviteUserToRoom`, `joinRoom`, `parseHeroSyncJoinRooms` are clean, reusable helpers.
- **Unauthenticated baseline test:** The 401 oracle edge scenario ensures the heroes feature does not accidentally disable auth.

---

## Verdict: PASS — No MAJOR findings. Ready for dev-story (Step 4).

**The 1 MEDIUM finding** (shared `dmRoomID`) is acceptable for sequential Godog and does not block implementation. A comment clarifying sequential dependency is recommended but not required before dev starts.

**Next step:** bmad-dev-story — implement proto changes, Elixir hero computation, and Go sync.go Summary attachment.
