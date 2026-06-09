# Code Review Findings — test-coverage-gaps — Cycle 0

## MAJOR-1 — Duplicate Godog step registrations (ErrAmbiguous under Strict: true)

**Location:** Steps registered twice across init functions:
1. `^alice calls GET /sync with timeout 0$` — registered in BOTH `initializePersonalSelfRoomSteps` (personal_self_room_steps_test.go:431) AND `initializeDirectRoomHeroesSteps` (direct_room_heroes_steps_test.go:810)
2. `^charlie calls GET /sync with timeout 0$` — registered in BOTH `initializeDirectRoomHeroesSteps` (direct_room_heroes_steps_test.go:802) AND `initializeAutoJoinRoomsSteps` (auto_join_rooms_steps_test.go:586)

**Impact:** Godog `Strict: true` returns `ErrAmbiguous` and fails every scenario using these steps — personal_self_room, direct_room_heroes, and auto_join_rooms features all break.

**Fix required:**

For `alice calls GET /sync with timeout 0`:
- In `personal_self_room_steps_test.go`, modify `aliceCallsGetSyncTimeout0` to ALSO write to `heroesSyncBody` after writing to `aliceSyncBody`
- In `direct_room_heroes_steps_test.go`, REMOVE the `alice calls GET /sync with timeout 0` registration from `initializeDirectRoomHeroesSteps` (ownership stays with personal_self_room)
- The function `aliceCallsGetSyncTimeout0ForHeroes` becomes unreachable for this step — remove or repurpose it

For `charlie calls GET /sync with timeout 0`:
- In `direct_room_heroes_steps_test.go`, modify `charlieCallsGetSyncTimeout0` to ALSO write to `charlieAutoJoinSyncBody` after writing to its current state variable
- In `auto_join_rooms_steps_test.go`, REMOVE the `charlie calls GET /sync with timeout 0` registration from `initializeAutoJoinRoomsSteps` (ownership stays with direct_room_heroes)

Do NOT modify the feature files. Only the step definition Go files need updating.

## MINOR-1 — Dead function `aliceAutoJoinLogsInAgainViaOIDC`
**Location:** `auto_join_rooms_steps_test.go:235`
Defined but never registered or called. Delete it.

## MINOR-2 — Dead state variables `autoJoinLastLoginStatus` / `autoJoinLastLoginBody`
**Location:** `auto_join_rooms_steps_test.go:52-53`
Assigned but never read. Delete them (and their assignments at lines 212-213, 243-244).

## MINOR-3 — Fragile Playwright locator: `getByText(roomName, {exact:false}).first()`
**Location:** `auto-join-rooms.steps.ts:39, 58`
Non-exact text match + `.first()` is brittle. Prefer scoped locator.

## MINOR-4 — `gateway/internal/admin/static/admin.css` included
Incidental Tailwind regeneration not in story scope. Exclude from commit (add to .gitignore if not already, or reset file).
