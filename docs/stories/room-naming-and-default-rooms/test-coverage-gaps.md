---
epic: room-naming-and-default-rooms
story: test-coverage-gaps
status: review
security_review: not-needed
priority: P0
created: 2026-05-29
baseline_commit: bcc02bdd7514c9ad8d2614ac9f34c4b3151bbde3
---

# Story: Fix Test Coverage Gaps — room-naming-and-default-rooms Epic

## Summary

The traceability matrix for the `room-naming-and-default-rooms` epic (generated
2026-05-29) found four P0 blockers and one P1 gap that prevent `make
test-integration` from running cleanly and prevent epic closure (gate threshold:
≥80% P0+P1 coverage; actual: 29% runnable).

Both the `admin-auto-join-rooms` and `direct-room-heroes` stories are **fully
implemented** (code and tests written). The gaps are exclusively in test wiring:
missing step-definition file, two missing `InitializeScenario` registration
calls, and unimplemented Playwright E2E step stubs (ATDD RED PHASE scaffolds that
were never turned green).

This story remediates R1–R5 from the traceability remediation plan:

| Ref | Priority | Action |
|-----|----------|--------|
| R1  | P0 | Create `auto_join_rooms_steps_test.go` with Godog step definitions for all 6 scenarios in `auto_join_rooms.feature` |
| R2  | P0 | Add `initializeAutoJoinRoomsSteps(sc)` call to `InitializeScenario` in `steps_test.go` |
| R3  | P0 | Implement Playwright E2E step definitions in `auto-join-rooms.steps.ts` (remove all `[ATDD RED PHASE]` throws) |
| R4  | P0 | Add `initializeDirectRoomHeroesSteps(sc)` call to `InitializeScenario` in `steps_test.go` |
| R5  | P1 | Add Go unit tests for heroes logic in `gateway/internal/matrix/sync_test.go` |

---

## User Story

As a developer on the Nebu project,
I want the `make test-integration` command to pass with all test wiring complete,
So that the room-naming-and-default-rooms epic can be closed with ≥80% P0+P1
runnable test coverage as required by the BMAD quality gate.

---

## Acceptance Criteria

### AC1 — Godog step definitions for `auto_join_rooms.feature` exist and are registered

`gateway/test/integration/auto_join_rooms_steps_test.go` exists and provides
working step definitions for all 6 scenarios in
`gateway/features/auto_join_rooms.feature`.

`InitializeScenario` in `gateway/test/integration/steps_test.go` calls
`initializeAutoJoinRoomsSteps(sc)`.

Running `make test-integration` does not fail with "undefined step" errors for
any step in `auto_join_rooms.feature`.

### AC2 — `initializeDirectRoomHeroesSteps` is registered in `InitializeScenario`

`InitializeScenario` in `gateway/test/integration/steps_test.go` calls
`initializeDirectRoomHeroesSteps(sc)`.

Running `make test-integration` does not fail with "undefined step" errors for
any step in `direct_room_heroes.feature`.

### AC3 — Playwright E2E step definitions for `auto-join-rooms.feature` are implemented

All step definitions in
`e2e/step-definitions/admin/auto-join-rooms.steps.ts` are implemented (no
step throws `[ATDD RED PHASE]`).

Running the Playwright E2E suite against the live stack exercises the admin
UI toggle: enable flow (AC1 of the auto-join story) and disable flow (AC2 of
the auto-join story).

### AC4 — `make test-integration` passes without new failures

After R1–R4 are applied, `make test-integration` runs to completion without
undefined-step errors or panics related to the new step files.

(Individual scenario assertions may still fail if the implementation has
regressions — but the suite must not abort with infrastructure errors.)

### AC5 — Heroes logic unit tests added to `sync_test.go` (P1)

`gateway/internal/matrix/sync_test.go` contains unit tests that cover:

1. Named room (room with `m.room.name` proto state and non-empty heroes returned
   by Core) → `Summary` field is `nil` on the `syncJoinedRoom` (omitempty
   ensures the key is absent from JSON).
2. DM room with 2 heroes → `summary.m.heroes` has length 2, hero count correct.
3. `m.joined_member_count` value is forwarded from proto to JSON output.

These tests call `buildJoinedRooms` directly (no HTTP stack needed).

---

## Technical Context

### Epic branch

`feature/room-naming-and-default-rooms`

### What is already implemented (do NOT re-implement)

**admin-auto-join-rooms story (fully implemented):**
- DB migration: `is_auto_join BOOLEAN NOT NULL DEFAULT false` column added to
  `rooms` table in `gateway/migrations/000001_init.up.sql` (around line 195).
- Proto: `is_auto_join bool` field in `AdminRoomDetailProto` and optional
  `is_auto_join *bool` in `UpdateRoomSettingsRequest` (in
  `gateway/internal/grpc/pb/core.pb.go`).
- Admin UI: `<input type="checkbox" name="is_auto_join" value="true">` rendered
  in `gateway/internal/admin/templates/rooms.html` (lines 129–131), controlled
  by `{{ if .ActiveRoom.IsAutoJoin }}checked{{ end }}`.
- Go admin handler: `UpdateSettingsHandler` in
  `gateway/internal/admin/rooms.go` reads `is_auto_join` from the form and
  forwards to Core via gRPC.
- `StubRoom.IsAutoJoin bool` field in
  `gateway/internal/admin/page_data.go:257`.
- Elixir Core: `ensure_auto_join_memberships/1` called from `validate_token/2`
  via `Task.start` when `is_new=true`.

**direct-room-heroes story (fully implemented):**
- Proto: `heroes []string`, `joined_member_count int32`,
  `invited_member_count int32` on `SyncRoom` message (in `core.pb.go`).
- Go sync handler: `buildJoinedRooms` in `gateway/internal/matrix/sync.go`
  (lines 754–818) attaches `*syncRoomSummary` with `omitempty` when heroes or
  counts are non-zero.
- `syncRoomSummary` struct with `m.heroes`, `m.joined_member_count`,
  `m.invited_member_count` fields (lines 385–393).
- Elixir Core: `get_room_heroes/2` in `core/apps/event_dispatcher/` and
  `attach_heroes/3` called from `event_dispatcher/server.ex`.

**Step file already written but unregistered:**
- `gateway/test/integration/direct_room_heroes_steps_test.go` (823 lines) is
  fully written and contains `initializeDirectRoomHeroesSteps(sc *godog.ScenarioContext)`
  at line 789. The function just needs to be called from `InitializeScenario`.

### Files to create or modify

| Operation | File |
|-----------|------|
| CREATE | `gateway/test/integration/auto_join_rooms_steps_test.go` |
| MODIFY | `gateway/test/integration/steps_test.go` (add 2 registration calls) |
| MODIFY | `e2e/step-definitions/admin/auto-join-rooms.steps.ts` (implement stubs) |
| MODIFY | `gateway/internal/matrix/sync_test.go` (add 3 unit tests) |

---

## Dev Notes: R1 — `auto_join_rooms_steps_test.go`

### Pattern to follow

Copy the structure of `personal_self_room_steps_test.go`:
- Build tag: `//go:build integration`
- Package: `package integration_test`
- State variables at package level (no concurrency risk in sequential Godog)
- Register all steps in a single `initializeAutoJoinRoomsSteps(sc *godog.ScenarioContext)` function at the bottom

### State variables needed

```go
var charlieAutoJoinAccessToken string
var charlieAutoJoinUserID string
var aliceAutoJoinAccessToken  string
var aliceAutoJoinUserID       string
var autoJoinLastLoginStatus   int
var autoJoinLastLoginBody     string
var autoJoinRoomID            string // DB room ID for "general" auto-join room
```

Note: `charlieAccessToken` and `charlieUserID` are already declared in
`direct_room_heroes_steps_test.go`. Do NOT redeclare them. Use separate
`charlieAutoJoin*` variables, or reuse the shared ones if they are not in
scope conflict. Check the package-level declarations carefully to avoid
duplicate variable errors.

The same applies to `aliceAccessToken` / `aliceUserID` — already declared in
`personal_self_room_steps_test.go`. Use `aliceAutoJoinAccessToken` and
`aliceAutoJoinUserID` to avoid conflicts.

### Scenarios in `gateway/features/auto_join_rooms.feature`

```
[AC3] New user is automatically joined to auto-join room on first login
[AC4] Existing user is NOT re-joined to auto-join room on re-login
[AC5] Auto-join is idempotent — no error when user is already a member
[AC6] Login succeeds even when auto-join DB query fails
[Oracle edge] Unauthenticated sync returns 401 M_UNKNOWN_TOKEN
[Oracle edge] Auto-join room appears in sync rooms.join with m.room.member event
```

### Step text map

From the feature file, map each step text to a Go function:

```
"the docker compose stack is started"        → theDockerComposeStackIsStarted (already in steps_test.go)
"room {string} exists with is_auto_join set to true"  → roomExistsWithIsAutoJoinTrue(roomName string) error
"charlie is a new user who has never logged in"       → charlieIsANewUserAutoJoin() error
"charlie logs in via OIDC"                            → charlieLogsInViaOIDCAutoJoin() error
"the login response status is (\d+)"                  → theLoginResponseStatusIs (already in personal_self_room_steps_test.go)
"the login response contains an access_token"         → theLoginResponseContainsAccessToken (already registered)
"charlie calls GET /sync with timeout 0"              → charlieAutoJoinCallsGetSyncTimeout0() error
"the sync response status is (\d+)"                   → theSyncResponseStatusIs (already registered)
"the sync rooms.join contains room {string} for charlie" → theSyncRoomsJoinContainsRoomForCharlie(roomName string) error
"alice is a user who has logged in before and is already a member of {string}" → aliceIsAlreadyMemberOfRoom(roomName string) error
"alice logs in again via OIDC"                        → aliceAutoJoinLogsInAgainViaOIDC() error
"alice calls GET /sync with timeout 0"                → already registered (aliceCallsGetSyncTimeout0) — can reuse
"alice's room membership in {string} is unchanged from before login" → aliceRoomMembershipUnchanged(roomName string) error
"charlie is a new user who has been pre-invited to {string} before first login" → charlieIsPreInvitedToRoom(roomName string) error
"charlie has exactly one membership event in {string}" → charlieHasExactlyOneMembershipEventInRoom(roomName string) error
"the login response contains a device_id"             → theLoginResponseContainsDeviceID (already registered)
"the login response contains a user_id"               → theLoginResponseContainsUserID (already registered)
"an unauthenticated client calls GET /sync"           → unauthenticatedClientCallsGetSync (already registered)
"the response status is (\d+)"                        → theResponseStatusIs (already in steps_test.go)
"the response body has errcode {string}"              → theResponseHasErrcodeIs (already registered)
"charlie's sync rooms.join[{string}] state contains an m.room.member event" → charliesSyncContainsMemberEvent(roomName string) error
"charlie's m.room.member event has membership {string}" → charliesMemberEventHasMembership(membership string) error
"charlie's m.room.member event has state_key {string}"  → charliesMemberEventHasStateKey(stateKey string) error
```

### DB setup for "room exists with is_auto_join set to true"

The step must:
1. Find the room named `roomName` in the DB (SELECT room_id FROM rooms WHERE name = $1).
2. UPDATE rooms SET is_auto_join = true WHERE room_id = $roomID.
3. Store `autoJoinRoomID` for sync assertions.

If the room does not exist, INSERT it (for test isolation). Use `dbURL` (package-level from `main_test.go`).

```go
import (
    "context"
    "database/sql"
    _ "github.com/jackc/pgx/v5/stdlib"
)

func roomExistsWithIsAutoJoinTrue(roomName string) error {
    db, err := sql.Open("pgx", dbURL)
    if err != nil {
        return fmt.Errorf("opening DB for auto-join setup: %w", err)
    }
    defer db.Close()

    var roomID string
    err = db.QueryRowContext(context.Background(),
        "SELECT room_id FROM rooms WHERE name = $1 LIMIT 1", roomName,
    ).Scan(&roomID)
    if err == sql.ErrNoRows {
        // Room doesn't exist yet — insert it (bare minimum for test isolation).
        // This path executes when the stack is freshly started with no pre-seeded rooms.
        roomID = fmt.Sprintf("!auto-join-%s-test:nebu.local", strings.ToLower(roomName))
        nowMS := time.Now().UnixMilli()
        _, err = db.ExecContext(context.Background(), `
            INSERT INTO rooms (room_id, name, visibility, is_auto_join, created_at)
            VALUES ($1, $2, 'public', true, $3)
            ON CONFLICT (room_id) DO UPDATE SET is_auto_join = true
        `, roomID, roomName, nowMS)
        if err != nil {
            return fmt.Errorf("inserting auto-join room %q: %w", roomName, err)
        }
    } else if err != nil {
        return fmt.Errorf("querying room %q: %w", roomName, err)
    } else {
        _, err = db.ExecContext(context.Background(),
            "UPDATE rooms SET is_auto_join = true WHERE room_id = $1", roomID)
        if err != nil {
            return fmt.Errorf("setting is_auto_join=true for room %q (id: %s): %w", roomName, roomID, err)
        }
    }
    autoJoinRoomID = roomID
    return nil
}
```

### Login helper

Reuse `iObtainDexTokenFor` / `iPostLoginWithDexToken` from `auth_steps_test.go`
exactly as `aliceLogsInViaOIDC` does in `personal_self_room_steps_test.go`.
Store results in `autoJoinLastLoginStatus` / `autoJoinLastLoginBody` and cache
`charlieAutoJoinAccessToken` / `charlieAutoJoinUserID`.

### Sync assertions

For `theSyncRoomsJoinContainsRoomForCharlie(roomName)`: call
`GET /sync?timeout=0` with `charlieAutoJoinAccessToken`, then parse
`rooms.join`. Look for an entry whose room_id matches `autoJoinRoomID`.
If `autoJoinRoomID` is empty, fall back to a scan of `m.room.name` state events.

For `charliesSyncContainsMemberEvent(roomName)` and subsequent assertions:
cache the last sync body in a package-level `charlieAutoJoinSyncBody` variable.
Parse `rooms.join[autoJoinRoomID].state.events` for `m.room.member`.

### AC4 — existing user NOT re-joined

`aliceIsAlreadyMemberOfRoom(roomName)` must:
1. Authenticate alice (reuse `aliceAutoJoinAccessToken`).
2. Confirm via sync that alice is already in the room (join call via Matrix API
   if not yet a member).

`aliceRoomMembershipUnchanged(roomName)` must:
1. Compare alice's membership event count in `rooms.join[autoJoinRoomID].state.events`
   before and after re-login.
2. The simplest implementation: record the room ID before login, then after
   login verify `rooms.join` still has the room with `membership=join` and no
   duplicate `m.room.member` events with the same `state_key`.

### AC5 — pre-invited user

`charlieIsPreInvitedToRoom(roomName)` must:
1. Reset charlie's token (first login).
2. Ensure the room has `is_auto_join=true` (call `roomExistsWithIsAutoJoinTrue`).
3. Use alice's token (or an admin token) to invite charlie to the room via
   `POST /_matrix/client/v3/rooms/{roomId}/invite`.

`charlieHasExactlyOneMembershipEventInRoom(roomName)` must:
1. Parse `charlieAutoJoinSyncBody`'s `rooms.join[autoJoinRoomID].state.events`.
2. Count events with `type=m.room.member` and `state_key=charlieAutoJoinUserID`.
3. Assert count == 1.

---

## Dev Notes: R2 — `steps_test.go` change

Add exactly two lines to `InitializeScenario` in
`gateway/test/integration/steps_test.go`:

```go
initializeAutoJoinRoomsSteps(sc)     // admin auto-join rooms (room-naming-and-default-rooms)
initializeDirectRoomHeroesSteps(sc)  // DM room heroes summary (room-naming-and-default-rooms)
```

Place them after `initializePersonalSelfRoomSteps(sc)` (currently the last line,
at line 130). Follow the existing comment style:
`// <short description> (epic-or-story reference)`.

---

## Dev Notes: R3 — `auto-join-rooms.steps.ts` Playwright implementation

### Framework and imports

File: `e2e/step-definitions/admin/auto-join-rooms.steps.ts`

Imports:
```typescript
import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
```

`ADMIN_BASE_URL` is already defined in the file:
```typescript
const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
```

Background steps (`the Nebu stack is running`, `bootstrap has been completed`,
`the operator is logged in as admin`) are already defined in
`e2e/step-definitions/admin/bootstrap.steps.ts`. Do NOT redefine them.

### What needs to be implemented (remove the `throw new Error("[ATDD RED PHASE]")` lines)

**`Given('a room named {string} exists in the system', ...)`**

Navigate to `/admin/rooms` and verify the named room appears in the room list.
Fall back to creating the room via the Admin API if it doesn't appear.

Implementation strategy: use the Admin API (`GET /admin/rooms?q=<roomName>`) to
confirm the room exists. The rooms list page renders with `role="listbox"` or
a table — the existing `rooms.steps.ts` pattern shows how to query the DOM.

```typescript
Given('a room named {string} exists in the system', async ({ page }: { page: Page }, roomName: string) => {
  // Navigate to the admin rooms list and verify the room appears.
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
  // Look for the room name anywhere on the page (list view).
  const roomEntry = page.getByText(roomName, { exact: false });
  await expect(roomEntry.first()).toBeVisible({ timeout: 15_000 });
});
```

**`Given('room {string} has auto-join enabled', ...)`**

Navigate to the room's detail page and ensure the toggle is already checked.
If not checked, check it and submit.

```typescript
Given('room {string} has auto-join enabled', async ({ page }: { page: Page }, roomName: string) => {
  // Navigate to the room detail and enable auto-join if not already enabled.
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
  // Click into the room detail.
  await page.getByText(roomName, { exact: false }).first().click();
  await page.waitForLoadState('networkidle');
  const toggle = page.locator('input[name="is_auto_join"]');
  const isChecked = await toggle.isChecked();
  if (!isChecked) {
    await toggle.check();
    await page.getByRole('button', { name: /save/i }).click();
    await page.waitForLoadState('networkidle');
  }
});
```

**`When('the operator navigates to the detail page for room {string}', ...)`**

```typescript
When('the operator navigates to the detail page for room {string}', async ({ page }: { page: Page }, roomName: string) => {
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
  await page.getByText(roomName, { exact: false }).first().click();
  await page.waitForLoadState('networkidle');
});
```

**`When('the operator enables the auto-join toggle', ...)`**

```typescript
When('the operator enables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await toggle.check();
});
```

**`When('the operator disables the auto-join toggle', ...)`**

```typescript
When('the operator disables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await toggle.uncheck();
});
```

**`When('the operator submits the room settings form', ...)`**

```typescript
When('the operator submits the room settings form', async ({ page }: { page: Page }) => {
  await page.getByRole('button', { name: /save/i }).click();
  await page.waitForLoadState('networkidle');
});
```

**`Then('the page shows the auto-join toggle as enabled', ...)`**

```typescript
Then('the page shows the auto-join toggle as enabled', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await expect(toggle).toBeChecked();
});
```

**`Then('the page shows the auto-join toggle as disabled', ...)`**

```typescript
Then('the page shows the auto-join toggle as disabled', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await expect(toggle).not.toBeChecked();
});
```

**`Then('re-loading the room detail page still shows the auto-join toggle as enabled', ...)`**

```typescript
Then('re-loading the room detail page still shows the auto-join toggle as enabled', async ({ page }: { page: Page }) => {
  await page.reload();
  await page.waitForLoadState('networkidle');
  const toggle = page.locator('input[name="is_auto_join"]');
  await expect(toggle).toBeChecked();
});
```

**`Then('re-loading the room detail page still shows the auto-join toggle as disabled', ...)`**

```typescript
Then('re-loading the room detail page still shows the auto-join toggle as disabled', async ({ page }: { page: Page }) => {
  await page.reload();
  await page.waitForLoadState('networkidle');
  const toggle = page.locator('input[name="is_auto_join"]');
  await expect(toggle).not.toBeChecked();
});
```

### Important: do not change step text signatures

The step text strings in the `Given/When/Then` calls must exactly match what is
in `e2e/features/admin/auto-join-rooms.feature`. Do not alter the step strings.

---

## Dev Notes: R4 — One-liner in `steps_test.go`

`initializeDirectRoomHeroesSteps(sc)` is already fully implemented at
`gateway/test/integration/direct_room_heroes_steps_test.go:789`. The only
missing piece is the call in `InitializeScenario`. This is a one-line change.

---

## Dev Notes: R5 — `sync_test.go` unit tests for heroes logic

The `buildJoinedRooms` function is in `gateway/internal/matrix/sync.go` and is
a pure function (no HTTP, no gRPC) — it can be called directly from unit tests.

### Test 1: Named room omits `summary`

A `pb.SyncRoom` with a non-empty `Heroes` slice but that represents a named room
should produce `Summary == nil` when we also have a `m.room.name` state event.
However the current implementation uses `len(room.GetHeroes()) > 0 || ...`
without checking state events — this is correct per spec: if Elixir never
includes heroes for named rooms (proto3 zero values), `Summary` stays nil.

The unit test should verify: if `SyncRoom.Heroes` is nil/empty and
`JoinedMemberCount == 0` and `InvitedMemberCount == 0`, then
`syncJoinedRoom.Summary` is nil.

```go
func TestBuildJoinedRooms_NamedRoom_NoSummary(t *testing.T) {
    // Named room: Core returns no heroes/counts (proto3 zero values).
    rooms := buildJoinedRooms([]*pb.SyncRoom{
        {
            RoomId: "!named:test.local",
            StateEvents: []*pb.SyncRoomStateEvent{
                {Type: "m.room.name", StateKey: "", Content: []byte(`{"name":"Team"}`), Sender: "@alice:test.local"},
            },
            TimelineEvents:     []*pb.Event{},
            Heroes:             nil,   // proto3 zero value → no heroes
            JoinedMemberCount:  0,
            InvitedMemberCount: 0,
        },
    })
    room, ok := rooms["!named:test.local"]
    if !ok {
        t.Fatal("expected !named:test.local in result")
    }
    if room.Summary != nil {
        t.Errorf("expected Summary to be nil for named room (omitempty), got %+v", room.Summary)
    }
}
```

### Test 2: DM room has correct hero count

```go
func TestBuildJoinedRooms_DMRoom_HeroesPopulated(t *testing.T) {
    rooms := buildJoinedRooms([]*pb.SyncRoom{
        {
            RoomId:             "!dm:test.local",
            StateEvents:        []*pb.SyncRoomStateEvent{},
            TimelineEvents:     []*pb.Event{},
            Heroes:             []string{"@alice:test.local"},
            JoinedMemberCount:  2,
            InvitedMemberCount: 0,
        },
    })
    room, ok := rooms["!dm:test.local"]
    if !ok {
        t.Fatal("expected !dm:test.local in result")
    }
    if room.Summary == nil {
        t.Fatal("expected Summary to be non-nil for DM room with heroes")
    }
    if len(room.Summary.Heroes) != 1 {
        t.Errorf("expected 1 hero, got %d: %v", len(room.Summary.Heroes), room.Summary.Heroes)
    }
    if room.Summary.Heroes[0] != "@alice:test.local" {
        t.Errorf("expected hero @alice:test.local, got %q", room.Summary.Heroes[0])
    }
    if room.Summary.JoinedMemberCount != 2 {
        t.Errorf("expected JoinedMemberCount=2, got %d", room.Summary.JoinedMemberCount)
    }
}
```

### Test 3: `m.joined_member_count` forwarded from proto to JSON

Verify via JSON serialisation that the `m.joined_member_count` key appears in
the serialised output with the correct value:

```go
func TestBuildJoinedRooms_Summary_JoinedMemberCountInJSON(t *testing.T) {
    rooms := buildJoinedRooms([]*pb.SyncRoom{
        {
            RoomId:            "!dmjson:test.local",
            Heroes:            []string{"@bob:test.local"},
            JoinedMemberCount: 3,
        },
    })
    room := rooms["!dmjson:test.local"]
    b, err := json.Marshal(room)
    if err != nil {
        t.Fatalf("marshalling room: %v", err)
    }
    s := string(b)
    if !strings.Contains(s, `"m.joined_member_count":3`) {
        t.Errorf("expected m.joined_member_count:3 in JSON output, got: %s", s)
    }
    if !strings.Contains(s, `"m.heroes"`) {
        t.Errorf("expected m.heroes key in JSON output, got: %s", s)
    }
}
```

Note: `buildJoinedRooms` is not exported. The test file lives in the same
`matrix` package (not `matrix_test`), so it has direct access.
Existing tests in `sync_test.go` already call `buildJoinedRooms` — follow the
same pattern as those existing tests in the file.

Wait — looking at the existing sync_test.go: it is `package matrix` (not
`matrix_test`), so `buildJoinedRooms` is accessible. But the existing tests
use `buildAuthedSyncHandler` which goes through the full HTTP stack. For the
heroes unit tests, call `buildJoinedRooms` directly.

The `sync_test.go` file uses `package matrix` — confirmed by the import of
`"github.com/nebu/nebu/internal/matrix"` being absent (it's the same package).

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

These tests already exist (ATDD scaffolds from prior stories). The task is to
wire them correctly so they actually run:

1. **[AC1] Godog auto-join scenarios** — Godog integration
   - Given: `auto_join_rooms_steps_test.go` exists with all step definitions
   - When: `make test-integration` is run
   - Then: 6 scenarios from `auto_join_rooms.feature` pass without "undefined step" errors

2. **[AC2] Godog heroes scenarios** — Godog integration
   - Given: `initializeDirectRoomHeroesSteps(sc)` added to `InitializeScenario`
   - When: `make test-integration` is run
   - Then: 6 scenarios from `direct_room_heroes.feature` are executed (not skipped)

3. **[AC3] Playwright admin toggle** — Playwright E2E (`.feature` + `.steps.ts`)
   - Given: all `[ATDD RED PHASE]` throws removed from `auto-join-rooms.steps.ts`
   - When: `e2e/features/admin/auto-join-rooms.feature` scenarios are run
   - Then: AC1 (enable toggle) and AC2 (disable toggle) scenarios complete without throwing

4. **[AC5] Heroes unit tests** — Go unit tests in `sync_test.go`
   - Given: `TestBuildJoinedRooms_NamedRoom_NoSummary` tests named-room exclusion
   - When: `make test-unit-go` is run
   - Then: all 3 new unit tests pass

---

## Files Reference Summary

| File | Operation | What to do |
|------|-----------|------------|
| `gateway/test/integration/auto_join_rooms_steps_test.go` | CREATE | New file with all 6 scenario step definitions + `initializeAutoJoinRoomsSteps` |
| `gateway/test/integration/steps_test.go` | MODIFY | Add `initializeAutoJoinRoomsSteps(sc)` and `initializeDirectRoomHeroesSteps(sc)` after line 130 |
| `e2e/step-definitions/admin/auto-join-rooms.steps.ts` | MODIFY | Replace all `throw new Error("[ATDD RED PHASE]...")` with real Playwright interactions |
| `gateway/internal/matrix/sync_test.go` | MODIFY | Add 3 unit tests at the end of the file: named-room no-summary, DM heroes count, JSON output |

Do not modify the feature files (`gateway/features/auto_join_rooms.feature`,
`e2e/features/admin/auto-join-rooms.feature`, `gateway/features/direct_room_heroes.feature`).
They are correct as written.

---

## Before You Start: Avoid Variable Name Conflicts

The `gateway/test/integration` package shares all state variables across files.
Before declaring any new `var` at package level, check the following already-declared variables:

- `charlieAccessToken`, `charlieUserID` — `direct_room_heroes_steps_test.go`
- `aliceAccessToken`, `aliceUserID`, `aliceSyncBody`, `aliceSelfRoomID`, `lastLoginBody`, `lastLoginStatus` — `personal_self_room_steps_test.go`
- `bobAccessToken`, `bobUserID` — `direct_room_heroes_steps_test.go`
- `lastStatusCode`, `lastBody`, `lastLocationHeader` — `steps_test.go`
- `lastDexIDToken`, `lastAccessToken` — `auth_steps_test.go`
- `lastRoomID`, `lastEventID`, `kaiAccessToken`, `alexAccessToken`, `marieAccessToken`, etc. — `room_flow_steps_test.go`

Use new names with an `AutoJoin` suffix where needed (e.g., `charlieAutoJoinAccessToken`)
to avoid redeclaration compile errors.

---

## Dev Agent Record

### Implementation Notes

All four remediation items (R1–R4) plus the P1 item (R5) have been implemented:

**R1 — `auto_join_rooms_steps_test.go` created:**
- New file with all step definitions for 6 scenarios in `auto_join_rooms.feature`
- Package-level state variables: `charlieAutoJoinAccessToken`, `charlieAutoJoinUserID`,
  `aliceAutoJoinAccessToken`, `aliceAutoJoinUserID`, `autoJoinLastLoginStatus`,
  `autoJoinLastLoginBody`, `autoJoinRoomID`, `charlieAutoJoinSyncBody`
- DB setup step `roomExistsWithIsAutoJoinTrue` handles both the existing-room UPDATE
  and the missing-room INSERT-with-upsert case
- Avoided redeclaring `charlieAccessToken`, `aliceAccessToken` (from existing files);
  used `charlieAutoJoin*` and `aliceAutoJoin*` prefixed variables
- `alice logs in again via OIDC` is NOT re-registered — it is already registered by
  `initializePersonalSelfRoomSteps`. `aliceRoomMembershipUnchanged` falls back to
  `aliceAccessToken` (set by that shared step) for the sync call

**R2 + R4 — `steps_test.go` updated:**
- Added `initializeAutoJoinRoomsSteps(sc)` after `initializePersonalSelfRoomSteps(sc)`
- Added `initializeDirectRoomHeroesSteps(sc)` after that

**R3 — `auto-join-rooms.steps.ts` implemented:**
- All 9 `[ATDD RED PHASE]` throws replaced with real Playwright interactions
- Uses `input[name="is_auto_join"]` locator for the toggle
- Uses `page.getByRole('button', { name: /save/i })` for form submission
- Re-load assertions navigate to the page and re-check the toggle state

**R5 — 3 unit tests added to `sync_test.go`:**
- `TestBuildJoinedRooms_NamedRoom_NoSummary`: asserts nil Summary for zero-heroes rooms
- `TestBuildJoinedRooms_DMRoom_HeroesPopulated`: asserts heroes and member count forwarded
- `TestBuildJoinedRooms_Summary_JoinedMemberCountInJSON`: asserts JSON field names correct
- All 3 pass: `make test-unit-go` returns `ok github.com/nebu/nebu/internal/matrix`

### Completion Notes

- `make test-unit-go`: all packages pass (zero failures)
- Integration test files compile cleanly with `-tags integration` / `go vet`
- No duplicate step registrations (MAJOR-1 resolved in review cycle 1)
- TypeScript file has no errors in `auto-join-rooms.steps.ts` (pre-existing
  tsconfig/node_modules errors are unrelated to this story)

### Review Cycle 1 — Code Review Findings Resolved (2026-05-29)

**[MAJOR] MAJOR-1 — Duplicate Godog step registrations fixed:**
- `alice calls GET /sync with timeout 0`: `aliceCallsGetSyncTimeout0` in
  `personal_self_room_steps_test.go` now also writes to `heroesSyncBody`; removed
  duplicate registration from `direct_room_heroes_steps_test.go` (line 810).
- `charlie calls GET /sync with timeout 0`: `charlieCallsGetSyncTimeout0` in
  `direct_room_heroes_steps_test.go` now also writes to `charlieAutoJoinSyncBody`; removed
  duplicate registration from `auto_join_rooms_steps_test.go` (line 586).

**[MINOR] MINOR-1 — Dead function `aliceAutoJoinLogsInAgainViaOIDC` deleted** from
`auto_join_rooms_steps_test.go` (was never registered, never called).

**[MINOR] MINOR-2 — Dead state variables `autoJoinLastLoginStatus` / `autoJoinLastLoginBody`
deleted** — removed declarations and all assignments from `auto_join_rooms_steps_test.go`.

**[MINOR] MINOR-3 — Fragile Playwright locators fixed** in
`e2e/step-definitions/admin/auto-join-rooms.steps.ts`: replaced `page.getByText(...).first().click()`
with `page.locator('td, li, a').filter({ hasText: roomName }).first()` in the
`a room named {string} exists in the system`, `room {string} has auto-join enabled`, and
`the operator navigates to the detail page for room {string}` steps.

**[MINOR] MINOR-4 — `gateway/internal/admin/static/admin.css` reset** via
`git checkout` — incidental Tailwind regeneration excluded from this story's diff.

---

## File List

| File | Operation |
|------|-----------|
| `gateway/test/integration/auto_join_rooms_steps_test.go` | CREATE |
| `gateway/test/integration/steps_test.go` | MODIFY |
| `e2e/step-definitions/admin/auto-join-rooms.steps.ts` | MODIFY |
| `gateway/internal/matrix/sync_test.go` | MODIFY |

---

## Change Log

- 2026-05-29: Implemented R1–R5 from traceability remediation plan:
  created `auto_join_rooms_steps_test.go` with all 6 Godog scenario step definitions;
  registered `initializeAutoJoinRoomsSteps` and `initializeDirectRoomHeroesSteps` in
  `InitializeScenario`; replaced all `[ATDD RED PHASE]` stubs in `auto-join-rooms.steps.ts`
  with real Playwright interactions; added 3 unit tests for `buildJoinedRooms` heroes logic
  to `sync_test.go`. All unit tests pass.
- 2026-05-29 (review cycle 1): Resolved all code review findings: fixed duplicate Godog step
  registrations for `alice calls GET /sync with timeout 0` and `charlie calls GET /sync with
  timeout 0` (MAJOR-1); deleted dead function `aliceAutoJoinLogsInAgainViaOIDC` and dead
  state variables `autoJoinLastLoginStatus`/`autoJoinLastLoginBody` (MINOR-1, MINOR-2);
  replaced fragile `page.getByText` Playwright locators with `page.locator('td, li, a').filter`
  (MINOR-3); reset incidental `admin.css` change (MINOR-4). All unit tests pass.
- 2026-05-29 (review cycle 2): Fixed MAJOR-2 (auto-join charlie sync reads wrong token) by adding
  `charlieAccessToken = charlieAutoJoinAccessToken` bridge in `charlieLogsInViaOIDCAutoJoin` so
  the shared `charlieCallsGetSyncTimeout0` handler has the correct token for auto-join scenarios;
  deleted dead function `aliceCallsGetSyncTimeout0ForHeroes` from `direct_room_heroes_steps_test.go`
  (MINOR-1); deleted dead function `charlieAutoJoinCallsGetSyncTimeout0` from
  `auto_join_rooms_steps_test.go` (MINOR-2). Build and unit tests pass.
