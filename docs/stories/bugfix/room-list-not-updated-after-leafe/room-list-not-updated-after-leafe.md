---
story_id: room-list-not-updated-after-leafe
title: "Bug: Room list not updated after leaving a room"
type: bug
severity: high
epic: room-list-not-updated-after-leafe
status: review
security_review: not-needed
created: 2026-05-28
branch: bugfix/room-list-not-updated-after-leafe
---

## Summary

When a user leaves a room, the room still appears in their joined room list on the next login (initial sync). Element Client displays stale rooms that the user has already left.

**Root cause (Oracle-verified, Matrix CS API v1.18 §Syncing):**

Per spec, `rooms.join` MUST only contain rooms where the user currently has `membership = join`. The initial sync fetches joined rooms via `get_rooms_for_user` which correctly filters `WHERE left_at IS NULL` — but two fallback paths in `leave_room` (Core `server.ex`) fail to call `delete_member`, leaving `left_at = NULL` in `room_members`.

### Bug 1 — Room GenServer not running (`server.ex:351`)

```elixir
{:error, :not_found} ->
  # Only rejects invitation — never sets room_members.left_at!
  db_module_invite().reject_invitation(room_id, user_id)
  emit_decline_event(room_id, user_id)
  %Core.LeaveRoomResponse{room_id: room_id}
```

Triggered when: user calls `/leave` before `/sync` starts the Room GenServer on demand (e.g., after a Core restart).

### Bug 2 — GenServer running but user absent from in-memory state (`server.ex:375`)

```elixir
{:error, :not_member} ->
  # Only rejects invitation — never sets room_members.left_at!
  db_module_invite().reject_invitation(room_id, user_id)
  emit_decline_event(room_id, user_id)
  %Core.LeaveRoomResponse{room_id: room_id}
```

Triggered when: GenServer in-memory state is inconsistent with DB (state desync after restart + race).

In both cases, `room_members.left_at` stays `NULL`, so `get_rooms_for_user` returns the room on the next login and it lands in `rooms.join`.

## Story

As a Matrix chat user,
I want rooms I have left to disappear from my room list immediately and permanently,
so that my room list always reflects my actual current memberships.

## Acceptance Criteria

**AC1 — Leaving a room removes it from the joined room list on next login:**
After `POST /leave`, the next initial sync (`GET /sync` without `since`) MUST NOT return the left room in `rooms.join`.

**AC2 — Room appears in `rooms.leave` on first incremental sync after leave:**
The first `GET /sync?since=<token>` after `POST /leave` MUST include the room in `rooms.leave` with an `m.room.member` event (`membership: "leave"`).

**AC3 — Leave succeeds even when Room GenServer is not running:**
`POST /leave` on a room whose GenServer is not running → HTTP 200, `room_members.left_at` is set in DB.

**AC4 — Leave succeeds even when GenServer doesn't know the user:**
`POST /leave` where GenServer returns `{:error, :not_member}` but user IS in `room_members` (left_at IS NULL) → HTTP 200, `room_members.left_at` is set in DB.

**AC5 — Leave for invited-but-not-joined user still works (no regression):**
`POST /leave` for a user who was only invited (no `room_members` row, only `room_invitations`) → HTTP 200, `room_invitations.rejected_at` is set, no error from `delete_member`.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1+AC3] ExUnit: leave_room with GenServer not running sets left_at in DB** — `core/apps/event_dispatcher/test/nebu/event_dispatcher/leave_room_test.exs`
   - Given: User is in `room_members` (left_at IS NULL), Room GenServer is NOT running
   - When: `Server.leave_room(%{room_id: room_id, user_id: user_id}, stream)`
   - Then: `room_members.left_at IS NOT NULL` for that user/room

2. **[AC4] ExUnit: leave_room when GenServer running but user absent from in-memory state sets left_at** — same file
   - Given: User IS in `room_members` (left_at IS NULL), GenServer IS running but `members` MapSet does NOT contain user
   - When: `Server.leave_room(%{room_id: room_id, user_id: user_id}, stream)`
   - Then: `room_members.left_at IS NOT NULL` for that user/room

3. **[AC5] ExUnit: leave_room for invited-only user sets rejected_at, no error** — same file
   - Given: User has pending invitation in `room_invitations`, no row in `room_members`
   - When: `Server.leave_room(%{room_id: room_id, user_id: user_id}, stream)`
   - Then: `room_invitations.rejected_at IS NOT NULL`, no exception raised

4. **[AC1+AC2] Godog: leaving a room removes it from initial sync, appears in incremental sync leave section** — `gateway/features/room_leave.feature`
   - Given: User is a member of a room
   - When: `POST /_matrix/client/v3/rooms/{roomId}/leave`
   - Then: HTTP 200
   - And: `GET /sync` (initial, no since) → room NOT in `rooms.join`
   - And: `GET /sync?since=<before-leave-token>` → room IS in `rooms.leave` with `m.room.member` `membership: "leave"`

## Technical Notes

### Fix Location

`core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — `leave_room/2` function.

**Both fallback paths need `delete_member` added before `reject_invitation`:**

```elixir
# Path 1: GenServer not running (line ~351)
{:error, :not_found} ->
  rooms_db_module().delete_member(room_id, user_id)  # ← ADD
  db_module_invite().reject_invitation(room_id, user_id)
  emit_decline_event(room_id, user_id)
  %Core.LeaveRoomResponse{room_id: room_id}

# Path 2: GenServer running, user not in-memory (line ~375)
{:error, :not_member} ->
  rooms_db_module().delete_member(room_id, user_id)  # ← ADD
  db_module_invite().reject_invitation(room_id, user_id)
  emit_decline_event(room_id, user_id)
  %Core.LeaveRoomResponse{room_id: room_id}
```

`delete_member` is idempotent: updates only rows where `left_at IS NULL`. Returns `{:error, :not_member}` (= no row updated) for invite-only users — this is safe and expected.

### Affected Files

- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — `leave_room/2`
- `core/apps/event_dispatcher/test/nebu/event_dispatcher/leave_room_test.exs` — new test file
- `gateway/features/room_leave.feature` — new Godog feature (AC1+AC2)
- `gateway/features/steps/room_leave_steps_test.go` — Godog step definitions

### No Gateway Changes Required

The Go Gateway's `buildJoinedRooms` and `buildLeaveRooms` logic is correct. The bug is purely in the Core's `leave_room` persistence.

## Dev Agent Record

### Implementation Notes

**Date:** 2026-05-28

**Fix applied to:** `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — `leave_room/2`

**Bug 1 fix (line ~351, `{:error, :not_found}` path):**
Added `rooms_db_module().delete_member(room_id, user_id)` before `db_module_invite().reject_invitation/2`. This ensures `room_members.left_at` is set when the Room GenServer is not running.

**Bug 2 fix (line ~380, `{:error, :not_member}` path):**
Added `rooms_db_module().delete_member(room_id, user_id)` before `db_module_invite().reject_invitation/2`. This ensures `room_members.left_at` is set when the GenServer is running but the user is absent from its in-memory state.

Both calls use the existing `rooms_db_module()` injectable — no new dependencies. `delete_member` is idempotent and safely returns `{:error, :not_member}` for invite-only users (no `room_members` row), which is discarded.

`Nebu.Room.DBBehaviour` already had `delete_member/2` callback defined — no behaviour changes needed.

**Test results:**
- ExUnit leave_room tests: 6 tests, 0 failures (AT1/AC3, AT2/AC4, AT3/AC5 all pass)
- Full Elixir test suite: 0 failures (exit code 0)
- Go unit tests: 0 failures (all packages pass)

**Review cycle 1 — fixes applied (2026-05-28):**

- M1: Both `delete_member` calls now pattern-matched with `case`; `{:error, :not_member}` treated as `:ok` (expected for invite-only users); any other `{:error, reason}` logged as `Logger.warning` but leave still returns success (best-effort semantics).
- M2: Scenario 3 title in `room_leave.feature` updated from "...after core restart..." to "Leave succeeds and removes room from initial sync (AC3 observable contract)".
- M3: `alexCapturesSyncTokenBeforeLeaving` now retries up to 5 × 300ms, only capturing `next_batch` after `lastRoomID` appears in `rooms.join`, preventing a join-broadcast race.
- M4: `theRoomsLeaveEntryContainsMemberLeaveEvent` now also asserts `state_key == alexUserID`; event struct extended with `StateKey string` field.

### File List

- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — modified: both `delete_member` calls wrapped in `case` with warning log on unexpected errors
- `gateway/features/room_leave.feature` — modified: Scenario 3 title corrected (M2)
- `gateway/test/integration/room_leave_steps_test.go` — modified: retry loop in token capture (M3), `state_key` assertion + struct field (M4)

### Change Log

- 2026-05-28: Fixed Bug 1 (`{:error, :not_found}` path) and Bug 2 (`{:error, :not_member}` path) in `leave_room/2` to call `rooms_db_module().delete_member/2` before `reject_invitation/2`, ensuring `room_members.left_at` is always set on leave regardless of GenServer state.
- 2026-05-28: Review cycle 1 — addressed 4 MINOR findings: M1 (DB error logging), M2 (scenario title), M3 (sync token capture race guard), M4 (state_key assertion).
