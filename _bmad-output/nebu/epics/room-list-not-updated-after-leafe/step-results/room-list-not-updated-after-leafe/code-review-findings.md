## Code Review — cycle 0 — 0 MAJOR, 4 MINOR, 3 INFO

### MINOR Findings

**M1 — `delete_member` DB error silently swallowed on both fallback paths**
`server.ex` lines ~356 and ~385: return value of `rooms_db_module().delete_member(room_id, user_id)` is discarded.
`{:error, :not_member}` is safe to ignore, but any genuine DB error (connection error, timeout, Postgrex error) is also silently dropped and the handler returns 200 OK even when `left_at` was never persisted. This re-creates the bug under DB failures.
Fix: pattern-match explicitly — log a warning for `{:error, reason}` when `reason != :not_member`.

**M2 — Gherkin Scenario 3 title implies a restart that never happens**
`room_leave.feature:51` title says "after core restart" but no restart step exists. Rename to remove the misleading claim, e.g. "Leave succeeds and removes room from initial sync (AC3 observable contract)".

**M3 — Pre-leave sync token capture races with join broadcast**
`room_leave_steps_test.go` `alexCapturesSyncTokenBeforeLeaving`: token is captured immediately after alex joins; Core might not have persisted the join yet. Consider adding an assertion that the room appears in `rooms.join` before capturing the token.

**M4 — `theRoomsLeaveEntryContainsMemberLeaveEvent` does not check `state_key`**
`room_leave_steps_test.go:245-298`: finds ANY `m.room.member` with `membership:"leave"` — doesn't verify it's for `alexUserID`. Fix: decode `state_key` and assert it equals `alexUserID`.

### INFO Findings
- I1: Fallback paths don't broadcast `{:new_leave, room_id}` — 30s poll timeout is acceptable fallback
- I2: FakeRoomsDB correctly returns :not_member when no :active row — correct idempotency test
- I3: FakeRoomsDB vs FakeRoomManagerDB naming could be clearer
