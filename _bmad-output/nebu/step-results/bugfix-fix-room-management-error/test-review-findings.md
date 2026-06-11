# Test Review Findings — bugfix-fix-room-management-error
Date: 2026-06-10

## MAJOR Findings

**M1 — Go Migration Tests Do Not Isolate Migration 000002 Effect**
File: `gateway/migrations/migrations_002_integration_test.go`
AC: AC1 (all sub-criteria)

`openMigratedDB` calls `m.Up()` which applies all pending migrations. On a fresh CI DB,
this applies 000001 and 000002 together. The tests cannot determine whether the structures
came from 000001 or 000002. A `TestMigration002_PreSquashBaseline` test must be added to
verify that after applying 000001 ONLY, the key structures do NOT yet exist.

Fix: Add TestMigration002_PreSquashBaseline using m.Steps(1) then asserting non-existence.

## MINOR Findings

m1: Leaked restarted GenServer pid in AC2 on_exit — start_and_track_room uses initial pid,
    not the restarted one. Use lookup_room in on_exit instead.

m2: FakeRoomDB (155 lines) inlined in get_room_state_lazy_restart_test.exs (413 total).
    Consider moving to test/support/ for reuse and to stay under 300 lines.

m3: TestMigration002_AuditLog passes "" for wantType — add explicit type assertions
    (int8, timestamptz, text).

m4: try/catch rationale not documented in AC3 tests — add comment explaining why
    assert_raise is insufficient for distinguishing GRPC.RPCError from :noproc exit.

## INFO

i1: wait_for_exit uses sleep polling — consider Process.monitor + receive. Not a defect.
i2: AC4 (.dockerignore) exemption from ATDD not documented in test files.
