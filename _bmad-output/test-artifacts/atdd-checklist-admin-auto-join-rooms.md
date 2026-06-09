---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-04c-aggregate
lastStep: step-04c-aggregate
lastSaved: '2026-05-28'
storyId: admin-auto-join-rooms
storyKey: admin-auto-join-rooms
storyFile: docs/stories/room-naming-and-default-rooms/admin-auto-join-rooms.md
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-admin-auto-join-rooms.md
generatedTestFiles:
  - gateway/features/auto_join_rooms.feature
  - core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs
  - e2e/features/admin/auto-join-rooms.feature
  - e2e/step-definitions/admin/auto-join-rooms.steps.ts
---

# ATDD Checklist: Admin Auto-Join Rooms

## TDD Red Phase (Current)

All tests are red-phase scaffolds — they FAIL until the feature is implemented.

- Godog integration tests: 6 scenarios (all failing)
- ExUnit unit tests: 3 tests (all failing — `ensure_auto_join_memberships/1` does not exist)
- E2E Playwright+Cucumber tests: 2 scenarios, 4 steps (all throwing "Not implemented")

## Acceptance Criteria Coverage

| AC | Description | Test | Level | Priority |
|----|-------------|------|-------|----------|
| AC1 | Admin enables auto-join toggle → DB updated, UI reflects | `e2e/features/admin/auto-join-rooms.feature` Scenario [AC1] | E2E (Playwright+Cucumber) | P0 |
| AC2 | Admin disables auto-join toggle → DB updated, UI reflects | `e2e/features/admin/auto-join-rooms.feature` Scenario [AC2] | E2E (Playwright+Cucumber) | P1 |
| AC3 | New user joins auto-join room on first login | `gateway/features/auto_join_rooms.feature` Scenario [AC3] | Godog integration | P0 |
| AC4 | Existing user NOT re-joined on re-login | `gateway/features/auto_join_rooms.feature` Scenario [AC4] | Godog integration | P0 |
| AC5 | Already-member join is idempotent (no error) | `gateway/features/auto_join_rooms.feature` Scenario [AC5] + ExUnit `auto_join_rooms_test.exs` | Godog + ExUnit unit | P1 |
| AC6 | Login succeeds even when DB query fails (non-fatal) | `gateway/features/auto_join_rooms.feature` Scenario [AC6] + ExUnit `auto_join_rooms_test.exs` | Godog + ExUnit unit | P0 |

## Oracle Spec Coverage

| Spec Rule | Test |
|-----------|------|
| Joined room appears in GET /sync under rooms.join | Scenario [AC3] + [Oracle edge: m.room.member] |
| m.room.member event has membership="join" | Scenario [Oracle edge: m.room.member] |
| m.room.member has state_key=<user_id> | Scenario [Oracle edge: m.room.member] |
| Unauthenticated /sync → 401 M_UNKNOWN_TOKEN | Scenario [Oracle edge: 401] |
| Login always returns 200 (no 5xx from auto-join failure) | Scenario [AC6] + ExUnit AC6 test |

## Test Files (Red Phase)

| File | Type | Tests | Status |
|------|------|-------|--------|
| `gateway/features/auto_join_rooms.feature` | Godog Gherkin | 6 scenarios | RED — all failing |
| `core/apps/event_dispatcher/test/event_dispatcher/auto_join_rooms_test.exs` | ExUnit | 3 tests | RED — all failing (`ensure_auto_join_memberships/1` undefined) |
| `e2e/features/admin/auto-join-rooms.feature` | Playwright+Cucumber Gherkin | 2 scenarios | RED — steps throw "Not implemented" |
| `e2e/step-definitions/admin/auto-join-rooms.steps.ts` | TypeScript step defs | 9 step definitions | RED — all `throw new Error("[ATDD RED PHASE]...")` |

## Next Steps (Task-by-Task Activation)

During implementation of each task:

1. Remove `throw new Error(...)` from the relevant `.steps.ts` step, or activate the ExUnit test by running `mix test` — verify it FAILS first.
2. Implement the feature code for that step.
3. Verify the test now PASSES (green phase).
4. Commit passing tests alongside the implementation.

### Implementation order (recommended):

1. **Migration**: `gateway/migrations/000003_auto_join_rooms.up.sql` → unlocks DB column
2. **Elixir Core**: `list_auto_join_rooms/0` in `Nebu.Room.DB` → ExUnit tests become runnable
3. **Elixir Core**: `ensure_auto_join_memberships/1` in `Nebu.EventDispatcher.Server` → ExUnit tests go green
4. **Proto**: add `is_auto_join` to `AdminRoomDetailProto` and `UpdateRoomSettingsRequest` → `make proto`
5. **Go Admin**: `StubRoom.IsAutoJoin`, `protoToStubRoom`, `UpdateSettingsHandler` → Godog AC1/AC2 go green
6. **Template**: add auto-join toggle to `rooms.html` → E2E scenarios go green
7. **Godog integration**: Godog AC3/AC4/AC5/AC6 scenarios → go green after Core + migration land
