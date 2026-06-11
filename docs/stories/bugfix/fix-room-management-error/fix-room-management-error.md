---
story_id: bugfix-fix-room-management-error
title: "Bug: Admin Room Management Fails + Rooms Not Found After Core Restart (Stackit)"
type: bug
severity: high
epic: fix-room-management-error
status: review
security_review: not-needed
created: 2026-06-10
branch: bugfix/fix-room-managemet-error
---

## Summary

Two bugs observed on the Stackit production instance after deploying the squashed migration (Story 13.14):

**Bug 1 — Missing DB schema (root cause):**
The squashed migration `000001_init.up.sql` merged migrations 1–49. The Stackit DB already had `schema_migrations` version 1 applied (from the old pre-squash migration 1). golang-migrate sees version 1 as applied and returns `ErrNoChange` → logs "migrations complete" but never runs the new schema from migrations 2–49. This leaves the Stackit DB missing:
- `rooms.is_auto_join` column → `GetAdminRoom` gRPC throws `column r.is_auto_join does not exist` → 500 Internal Server Error in Admin Room Management UI
- `users.personal_room_id` column → `ensure_personal_room` fails at login
- `matrix_sessions` table → PostLogin cannot persist sessions (fallback to JWT)
- Several other tables and columns that were added in migrations 2–49

**Bug 2 — Room GenServer not restarted after Core restart:**
`GetRoomState` gRPC handler does not attempt lazy restart of the Room GenServer when it's not in the Horde registry (`:noproc`). After a Core restart, all Room GenServers are gone. Every call to `GetRoomState` for rooms that haven't been touched yet returns `not_found`, causing the gateway to log errors and Matrix sync to fail for those rooms.

**Bug 3 — Missing `core/.dockerignore`:**
`COPY . .` in `core/Dockerfile` copied the local `deps/` and `_build/` directories into the Docker build context, overwriting the freshly downloaded dependencies from `mix deps.get --only prod`. This caused `mix release` to fail with "lock mismatch: the dependency is out of date" errors on local builds.

## Story

As a Nebu instance operator (Stackit deployment),
I want the gateway migration system to correctly bring pre-squash database instances up to the current schema,
so that the Admin Room Management UI works, sessions are persisted, and rooms are accessible after a Core restart.

## Root Cause Analysis

- **Schema gap:** golang-migrate's version-based tracking means "version 1 already applied" even though the squash replaced the old version 1 with a much larger one. The pre-squash instances never got the content of migrations 2–49.
- **Room restart gap:** `GetRoomState` was the only read-path gRPC handler that didn't attempt lazy `start_room` on `:noproc`. All write-path handlers (`join_room`, `send_event`, `unarchive_room`) already call `Nebu.Room.RoomSupervisor.start_room/1` before operating.
- **Build gap:** No `.dockerignore` in `core/`, so stale local build artifacts polluted the Docker build context.

## Acceptance Criteria

**AC1 — Migration 000002 adds missing columns and tables idempotently:**
After running all migrations on a pre-squash Stackit-style DB (schema_migrations = version 1 only):
- `rooms.is_auto_join` BOOLEAN column exists
- `users.personal_room_id` TEXT column exists
- `matrix_sessions` TABLE exists with all columns and indexes
- `audit_log` TABLE exists
- All other tables added in migrations 2–49 exist
- Applying migration 000002 a second time does not error (idempotent)

**AC2 — GetRoomState lazy-restarts the Room GenServer after Core restart:**
When `GetRoomState` is called for a room whose GenServer is not running (`:noproc`), the handler attempts `Nebu.Room.RoomSupervisor.start_room/1`. If the room is in the DB, it loads successfully and the state is returned. Only if `start_room` fails (room not in DB) does the handler return `not_found`.

**AC3 — GetRoomState still returns not_found for truly non-existent rooms:**
When `GetRoomState` is called for a room that genuinely does not exist in the DB, the handler returns gRPC `NOT_FOUND` (not an internal server error).

**AC4 — core/.dockerignore prevents build pollution:**
The `core/Dockerfile` build succeeds without lock-mismatch errors when `deps/` and `_build/` exist locally.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **TestMigration002_RoomsIsAutoJoin** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only (pre-squash state)
   - When: migration 000002 is applied
   - Then: `rooms.is_auto_join` BOOLEAN column and `rooms_auto_join_idx` index exist

2. **TestMigration002_UsersPersonalRoomID** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only
   - When: migration 000002 is applied
   - Then: `users.personal_room_id` TEXT column exists

3. **TestMigration002_MatrixSessions** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only
   - When: migration 000002 is applied
   - Then: `matrix_sessions` table exists with all required columns and three indexes

4. **TestMigration002_AuditLog** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only
   - When: migration 000002 is applied
   - Then: `audit_log` table exists with required columns

5. **TestMigration002_AdditionalTables** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only
   - When: migration 000002 is applied
   - Then: `compliance_requests`, `compliance_sessions`, `room_account_data`, `notifications`, `push_rules`, `pushers`, `role_overrides`, `room_defaults`, `forgotten_rooms` all exist

6. **TestMigration002_Idempotency** — Integration (golang-migrate)
   - Given: DB with migration 000002 already applied
   - When: migration 000002 is applied again
   - Then: returns `ErrNoChange`, no error

7. **TestMigration002_AlteredTableColumns** — Integration (golang-migrate)
   - Given: DB with schema_migrations version 1 only
   - When: migration 000002 is applied
   - Then: `admin_sessions.refresh_token` TEXT and `media_files.deleted` BOOLEAN columns exist

8. **TestMigration002_RoomDefaultsSeedRow** — Integration (golang-migrate)
   - Given: fresh DB after migration 000002
   - When: `SELECT COUNT(*) FROM room_defaults`
   - Then: count >= 1 (seed row present)

9. **GetRoomState lazy-restart test** — ExUnit (Elixir)
   - Given: Room GenServer is not running in Horde (simulated post-restart state)
   - When: `get_room_state` gRPC is called for a room that exists in the DB
   - Then: `start_room/1` is called, room state is returned successfully (no `:noproc` error propagated)

10. **GetRoomState not_found for non-existent room** — ExUnit (Elixir)
    - Given: Room GenServer is not running and room does NOT exist in DB
    - When: `get_room_state` gRPC is called
    - Then: gRPC `NOT_FOUND` is returned

## Dev Notes

### Files changed

**New:**
- `gateway/migrations/000002_add_missing_structures.up.sql` — idempotent migration adding all missing schema
- `gateway/migrations/000002_add_missing_structures.down.sql` — reversal migration
- `core/.dockerignore` — excludes `deps/`, `_build/`, `.git/` from build context

**Modified:**
- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — `get_room_state/2`: lazy `start_room` on `:noproc` (mirrors join_room pattern, line ~1043–1060)

### Migration design

Migration 000002 uses `ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, and `DROP POLICY IF EXISTS` + `CREATE POLICY` to make every statement safe to run on both:
- **Stackit (pre-squash) instances**: tables/columns missing → statements create them
- **Fresh (post-squash) instances**: everything exists → statements are no-ops

### GetRoomState fix

The fix mirrors the exact pattern used by `join_room` (server.ex line ~739):
```elixir
case Nebu.Room.RoomSupervisor.start_room(room_id) do
  {:error, _reason} -> raise GRPC.RPCError, status: GRPC.Status.not_found(), ...
  {:ok, _pid} -> retry get_state with same :noproc guard
end
```

The Room GenServer's `init/1` loads state from DB on start. If the room is in the DB, it recovers correctly. If not (truly non-existent), `start_room` returns an error and `not_found` is raised.

## File List

- `gateway/migrations/000002_add_missing_structures.up.sql` — new: idempotent migration
- `gateway/migrations/000002_add_missing_structures.down.sql` — new: reversal migration
- `gateway/migrations/migrations_002_integration_test.go` — new: Go integration tests
- `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex` — modified: lazy restart patch
- `core/apps/event_dispatcher/test/nebu/event_dispatcher/get_room_state_lazy_restart_test.exs` — new: Elixir ExUnit tests
- `core/.dockerignore` — new: prevents build context pollution

## Dev Agent Record

### Completion Notes (2026-06-10)

All test-review findings addressed:

- **M1 (MAJOR — FIXED)**: Added `TestMigration002_PreSquashBaseline` to `migrations_002_integration_test.go`. Uses `m.Down()` + `m.Steps(1)` to apply only migration 000001, then asserts `rooms.is_auto_join` and `matrix_sessions` do NOT exist — proving those structures are genuinely 000002's responsibility.
- **m1 (on_exit cleanup — ALREADY CORRECT)**: `start_and_track_room/1` already used `Nebu.Room.RoomSupervisor.lookup_room(room_id)` in the `on_exit` callback to find the current (possibly restarted) pid rather than the stale initial pid. No change needed.
- **m2 (FakeRoomDB inline — NOTED)**: `core/apps/event_dispatcher/test/support/` does not exist in this project. Inline `FakeRoomDB` follows the same pattern as `server_receipts_test.exs`. Added a comment in the FakeRoomDB section documenting this decision and suggesting future consolidation.
- **m3 (audit_log type assertions — FIXED)**: Changed `wantType = ""` to explicit PostgreSQL udt_names: `id → "int8"`, `event_time → "timestamptz"`, `actor_user_id → "text"`, `action → "text"`, `outcome → "text"`.
- **m4 (try/catch rationale — FIXED)**: Added a 2-line comment before each `try` block in AC3 tests explaining why `assert_raise` is insufficient (cannot catch `:exit` signals, only rescues exceptions).

### Change Log

- 2026-06-10: Addressed test-review findings M1, m3, m4 (code changes); documented m1 (already correct) and m2 (no test/support/ directory — inline pattern correct).
