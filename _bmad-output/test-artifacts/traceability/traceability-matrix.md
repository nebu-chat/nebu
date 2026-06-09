---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-matrix', 'step-04-gate']
lastStep: 'step-04-gate'
lastSaved: '2026-05-31'
coverageBasis: acceptance_criteria
oracleConfidence: high
oracleResolutionMode: formal_requirements
oracleSources:
  - 'docs/stories/room-naming-and-default-rooms/personal-self-room.md'
  - 'docs/stories/room-naming-and-default-rooms/admin-auto-join-rooms.md'
  - 'docs/stories/room-naming-and-default-rooms/direct-room-heroes.md'
  - 'docs/stories/room-naming-and-default-rooms/auto-join-on-user-import.md'
  - 'docs/stories/room-naming-and-default-rooms/test-coverage-gaps.md'
  - 'docs/stories/room-naming-and-default-rooms/rate-limit-isolation.md'
  - 'docs/stories/room-naming-and-default-rooms/bootstrap-integration-steps.md'
externalPointerStatus: not_used
gateDecision: PASS
previousGateDecision: FAIL
previousGateDate: '2026-05-29'
---

# Traceability Matrix — Epic: room-naming-and-default-rooms

**Generated:** 2026-05-31 (updated — previous run: 2026-05-29)  
**Branch:** `feature/room-naming-and-default-rooms`  
**Stories (product features):** personal-self-room · admin-auto-join-rooms · direct-room-heroes · auto-join-on-user-import  
**Stories (test-infra):** test-coverage-gaps · rate-limit-isolation · bootstrap-integration-steps  
**Oracle:** Formal acceptance criteria (story files)  
**Oracle confidence:** High

---

## Executive Summary

**Quality Gate: ✅ PASS** _(was: ❌ FAIL on 2026-05-29)_

All four P0 blockers from the previous FAIL verdict have been resolved by the
`test-coverage-gaps` story (committed 2026-05-29). Three additional test-infra
stories (`rate-limit-isolation`, `bootstrap-integration-steps`) and one new product
story (`auto-join-on-user-import`) were committed on 2026-05-30.

All 21 product-feature ACs across four stories are now covered by runnable tests.
P0+P1 coverage: **100%** (threshold: ≥80%).

| Story | ACs | Fully Covered | Partial | No Coverage | Gate |
|---|---|---|---|---|---|
| personal-self-room | 4 | 4 | 0 | 0 | ✅ PASS |
| admin-auto-join-rooms | 6 | 6 | 0 | 0 | ✅ PASS |
| direct-room-heroes | 5 | 5 | 0 | 0 | ✅ PASS |
| auto-join-on-user-import | 6 | 6 | 0 | 0 | ✅ PASS |
| **Epic total** | **21** | **21** | **0** | **0** | **✅ PASS** |

Two optional recommendations (R6, R7) remain open and are documented below.

---

## Resolved Blockers (was: FAIL on 2026-05-29)

All four P0 gaps from the previous verdict are now closed:

| Was | Fix | Status |
|---|---|---|
| GAP-1: `auto_join_rooms_steps_test.go` missing | Created (597 lines, `initializeAutoJoinRoomsSteps` at line 572) | ✅ Closed |
| GAP-2: `initializeAutoJoinRoomsSteps(sc)` not registered | Added to `steps_test.go` line 131 | ✅ Closed |
| GAP-3: Playwright steps all `[ATDD RED PHASE]` throws | All steps implemented in `auto-join-rooms.steps.ts` (4.4 KB) | ✅ Closed |
| GAP-4: `initializeDirectRoomHeroesSteps(sc)` not registered | Added to `steps_test.go` line 132 | ✅ Closed |

Additional fixes from test-infra stories:

| Fix | Story | Status |
|---|---|---|
| `NEBU_RATE_LIMIT_DISABLED=true` added to `make test-integration` | rate-limit-isolation | ✅ Done |
| carol/anna Dex users added to avoid rate-limit cross-contamination | rate-limit-isolation | ✅ Done |
| Bootstrap step 2+3 step defs fixed; session cookie uses DB-backed sessions | bootstrap-integration-steps | ✅ Done |
| R5: heroes unit tests in `sync_test.go` (lines 3792+) | test-coverage-gaps | ✅ Done |

---

## Story 1: personal-self-room

**Overall: ✅ PASS — all 4 ACs covered, all tests runnable (unchanged since 2026-05-29)**

| AC | Description | Test artifact | Layer | Runnable? | Coverage |
|---|---|---|---|---|---|
| AC1 | Self-room created on first login | `gateway/features/personal_self_room.feature` Scenario [AC1] | Godog integration | ✅ Registered | ✅ FULL |
| AC2 | Idempotent on re-login (no duplicate) | Scenario [AC2] + `personal_room_test.exs` (idempotent test) | Godog + ExUnit | ✅ Yes | ✅ FULL |
| AC3 | Sync shows room with `m.room.name` (state_key `""`, name = localpart) | Scenario [AC3] with `state_key` + `content.name` assertions | Godog integration | ✅ Yes | ✅ FULL |
| AC4 | Login succeeds when self-room DB fails (non-fatal) | Scenario [AC4] + `personal_room_test.exs` | Godog + ExUnit | ✅ Yes | ✅ FULL |

**Test files:**
- `gateway/features/personal_self_room.feature` — 5 scenarios (4 ACs + 1 Oracle edge)
- `gateway/test/integration/personal_self_room_steps_test.go` — 17.5 KB, registered ✅
- `core/apps/event_dispatcher/test/event_dispatcher/personal_room_test.exs` — 3 tests

---

## Story 2: admin-auto-join-rooms

**Overall: ✅ PASS — all 6 ACs covered (upgraded from ❌ FAIL)**

| AC | Description | Test artifact | Layer | Runnable? | Coverage |
|---|---|---|---|---|---|
| AC1 | Admin enables auto-join toggle; DB updated; UI re-renders enabled | `e2e/features/admin/auto-join-rooms.feature` @ac1 | Playwright E2E | ✅ Steps fully implemented | ✅ FULL |
| AC2 | Admin disables toggle; DB updated; UI re-renders disabled | `e2e/features/admin/auto-join-rooms.feature` @ac2 | Playwright E2E | ✅ Steps fully implemented | ✅ FULL |
| AC3 | New user auto-joined to auto-join rooms on first login | `gateway/features/auto_join_rooms.feature` Scenario [AC3] | Godog integration | ✅ Step file created + registered | ✅ FULL |
| AC4 | Existing user NOT re-joined on re-login (idempotent) | Scenario [AC4] | Godog integration | ✅ Registered | ✅ FULL |
| AC5 | Idempotent — no error when user already a member | Scenario [AC5] + `auto_join_rooms_test.exs` | Godog + ExUnit | ✅ Both runnable | ✅ FULL |
| AC6 | Login succeeds when auto-join DB query fails (non-fatal) | Scenario [AC6] + `auto_join_rooms_test.exs` | Godog + ExUnit | ✅ Both runnable | ✅ FULL |

**Test files:**
- `gateway/features/auto_join_rooms.feature` — 6 scenarios (AC3–AC6 + 2 Oracle edges)
- `gateway/test/integration/auto_join_rooms_steps_test.go` — 597 lines ✅ (NEW — was missing)
  - `initializeAutoJoinRoomsSteps` registered at `steps_test.go:131` ✅ (NEW)
  - Uses carol/anna Dex users to avoid rate-limit cross-contamination
- `e2e/features/admin/auto-join-rooms.feature` — 2 scenarios ✅
- `e2e/step-definitions/admin/auto-join-rooms.steps.ts` — 4.4 KB, all steps real implementations ✅ (was: all RED PHASE)
- `core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs` — 8 ExUnit tests ✅

---

## Story 3: direct-room-heroes

**Overall: ✅ PASS — all 5 ACs covered (upgraded from ❌ FAIL)**

| AC | Description | Test artifact | Layer | Runnable? | Coverage |
|---|---|---|---|---|---|
| AC1 | 1-on-1 DM shows other participant in `summary["m.heroes"]` | `gateway/features/direct_room_heroes.feature` Scenario [AC1] | Godog integration | ✅ Registered at `steps_test.go:132` | ✅ FULL |
| AC2 | 3-person DM shows both other participants (up to 5) | Scenario [AC2] | Godog integration | ✅ Registered | ✅ FULL |
| AC3 | Named room (`m.room.name` non-empty) has no `summary.heroes` | Scenario [AC3] | Godog integration | ✅ Registered | ✅ FULL |
| AC4 | Initial sync (`since` absent) populates heroes for all unnamed DM rooms | Scenario [AC4] | Godog integration | ✅ Registered | ✅ FULL |
| AC5 | Delta sync omits summary when heroes unchanged (Oracle-edge) | Scenario [Oracle edge] in feature file | Godog integration | ✅ Registered | ✅ FULL |

**Test files:**
- `gateway/features/direct_room_heroes.feature` — 6 scenarios (AC1–AC4 + AC5-as-Oracle + 1 auth Oracle edge)
- `gateway/test/integration/direct_room_heroes_steps_test.go` — 803 lines ✅
  - `initializeDirectRoomHeroesSteps` registered at `steps_test.go:132` ✅ (was: dead code)
- `gateway/internal/matrix/sync_test.go` — heroes unit tests at lines 3792–3895 ✅ (R5 implemented)
  - Named room → Summary nil (omitempty) ✅
  - DM room with heroes → Summary non-nil ✅
  - JSON marshal correctness (`"m.heroes"`, `"m.joined_member_count"`) ✅

---

## Story 4: auto-join-on-user-import

**Overall: ✅ PASS — all 6 ACs covered (NEW story, not in previous matrix)**

| AC | Description | Test artifact | Layer | Runnable? | Coverage |
|---|---|---|---|---|---|
| AC1 | Bulk-imported user auto-joined to auto-join rooms | `auto_join_rooms_test.exs` "AC1: bulk_import_users triggers ensure_auto_join_memberships" | ExUnit | ✅ Yes | ✅ FULL |
| AC2 | Bulk-imported user receives personal self-room | `auto_join_rooms_test.exs` "AC2: bulk_import_users triggers ensure_personal_room" | ExUnit | ✅ Yes | ✅ FULL |
| AC3 | Already-existing user skipped — no auto-join tasks spawned | `auto_join_rooms_test.exs` "AC3 (via Server): skipped user does not trigger" + `bulk_importer_test.exs` AT-2 | ExUnit (2 tests) | ✅ Yes | ✅ FULL |
| AC4 | `{:error, :already_member}` treated as :ok (idempotent, no crash) | `auto_join_rooms_test.exs` "AC5 (bulk path): bulk_import_users succeeds even when auto-join room join fails" | ExUnit | ✅ Yes | ✅ FULL |
| AC5 | `import_users/1` return value includes `imported_user_ids` list | `bulk_importer_test.exs` AT-1 "returns imported_user_ids with newly provisioned user IDs" | ExUnit | ✅ Yes | ✅ FULL |
| AC6 | 2 new + 1 existing → `imported_user_ids` contains exactly 2 | `bulk_importer_test.exs` AT-2 "omits skipped user IDs from imported_user_ids (mixed)" + AT-3 "empty when all skipped" | ExUnit (2 tests) | ✅ Yes | ✅ FULL |

**Test files:**
- `core/apps/session_manager/test/nebu/session/bulk_importer_test.exs` — 3 AT-level tests (AT-1, AT-2, AT-3)
- `core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs` — bulk_import section (AC1, AC2, AC3, AC5-bulk, AC6-bulk) covering lines 287+

---

## P0+P1 Coverage Summary

| Story | P0 ACs | P0 Covered | P1 ACs | P1 Covered | Total | Coverage % |
|---|---|---|---|---|---|---|
| personal-self-room | 4 | 4 | 0 | 0 | 4/4 | **100%** |
| admin-auto-join-rooms | 5 | 5 | 1 | 1 | 6/6 | **100%** |
| direct-room-heroes | 4 | 4 | 1 | 1 | 5/5 | **100%** |
| auto-join-on-user-import | 5 | 5 | 1 | 1 | 6/6 | **100%** |
| **Epic total** | **18** | **18** | **3** | **3** | **21/21** | **100%** |

**Threshold: 80% P0+P1 coverage required. Actual: 100% runnable. Gate: PASS.**

---

## Open Recommendations (non-blocking)

| # | Priority | Action | Location | Story | Status |
|---|---|---|---|---|---|
| R6 | **P1** | Element Web test: new user auto-join room visible in Element sidebar | `e2e/features/element/room/auto-join.feature` | admin-auto-join-rooms | ⚠️ OPEN |
| R7 | **P2** | Element Web test: DM room shows participant name instead of "Empty Room" | `e2e/features/element/room/dm-heroes.feature` | direct-room-heroes | ⚠️ OPEN |

R6 and R7 test the user-visible outcome in Element Web — the protocol is verified at the
Godog/Playwright layer, but the end-user rendering is unconfirmed at the browser level.
Neither blocks epic closure (P1/P2 under the 80% threshold with 100% P0+P1 coverage already
achieved). They are recommended as follow-up stories in the next sprint.

---

## Note on Integration Test Execution

The test-infra stories confirm code correctness (unit tests pass, step files compile clean).
`make test-integration` now includes `NEBU_RATE_LIMIT_DISABLED=true` (Makefile line 203) and
uses dedicated carol/anna Dex users for auto-join scenarios to prevent rate-limit
cross-contamination. Full integration test suite execution against a running stack has not been
recorded in the CI gate log (which runs unit tests only). Recommend running
`make test-integration` against the dev stack before epic retrospective to produce a final
green-run artifact.

---

## Gate Decision

**VERDICT: ✅ PASS**

All four previous P0 blockers are resolved. All 21 product-feature ACs across four stories
are covered by runnable tests. The 80% P0+P1 threshold is met at 100%.

The epic may proceed to the retrospective (`/bmad-retrospective`) and mandatory epic-end
security review (`/bmad-code-review` against full `git diff <epic-base>..HEAD`).

Two optional recommendations (R6, R7) should become follow-up stories rather than blocking
epic closure.
