---
story_id: events-room-position
title: "Every event gets a per-room stream position allocated in commit order: migration 000053 adds rooms.event_pos and events.room_pos, a BEFORE INSERT trigger draws the position under the rooms row lock for every writer, no backfill, no read change (story 1 of 2 for fc; story 2 is sync-stream-position)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: optional
matrix: false
ui: false
traceability_id: REQ-2026-004
created: 2026-10-26
branch: feature/migrate-to-oauth2
blocks: sync-stream-position
sizing: small-medium
---

# Story: per-room event positions in commit order (prerequisite of `sync-stream-position`, follow-up `fc`)

## Story

**As** the `/sync` delivery (story `sync-stream-position`), **I want** every stored event to carry a position that is unique within its
room and whose order equals the commit order of the room's events, whatever process, node or code path wrote it, **so that** a reader
that has seen position N+1 of a room has also seen N and can continue from a per-room cursor without losing events.

This file is **story 1 of 2** (D1 of `docs/stories/oauth-broker/sync-stream-position.md`; the design rationale, the rejected schemes and
the premise check are there and in `_bmad-output/nebu/epics/oauth-broker/step-results/sync-stream-position/premise-check.md`). It
changes the WRITE path only: no read, no response and no token changes. It must be merged before story 2.

## Decisions

- **D1 Allocation in the database, under the `rooms` row lock, by a trigger.** Migration `000053_events_room_position` adds
  `rooms.event_pos BIGINT NOT NULL DEFAULT 0`, `events.room_pos BIGINT` (nullable) and a `BEFORE INSERT ON events FOR EACH ROW` trigger
  whose function does `UPDATE rooms SET event_pos = event_pos + 1 WHERE room_id = NEW.room_id RETURNING event_pos INTO NEW.room_pos`
  (any value supplied by the INSERT is overwritten). The row lock taken by that `UPDATE` lives until the inserting transaction ends, so
  a second insert into the same room (any writer, any node) waits and draws N+1 only after N committed; a rollback also rolls the counter
  back (no gaps; "no gaps" holds for failed or rolled-back statements, a conflicting row skipped by `ON CONFLICT DO NOTHING` would still
  consume a position, and no writer does that). An event of a room without a `rooms` row stays refused by the foreign key; the trigger
  must not change that error. Function and trigger names are the implementer's choice. Rooms do not block each other. **Why a trigger:** the room process is not the only writer (premise check §3: the
  `m.room.create` event, `emit_state_event_at/6`, `create_personal_room/2`, `emit_decline_event/2` write directly, and a Horde handover
  can briefly run two room processes); the trigger covers every present and future `INSERT INTO events`, also from an OLD node during a
  rolling deploy (mixed-version safe), with no change to the nine call sites. **Rejected:** stamping in `@sql_insert_event` (a CTE
  `UPDATE rooms ... RETURNING` + `INSERT ... SELECT`): same semantics, but a writer that bypasses `insert_event/1` (a migration, an old
  node) would write NULL positions that story 2 never delivers. Owner may prefer the explicit SQL (Open Questions).
- **D2 `apply_member_change/4` locks the `rooms` row `FOR NO KEY UPDATE` instead of `FOR SHARE`.** With the trigger, its insert upgrades a
  share lock to an exclusive one; two transactions holding `FOR SHARE` on one room and both inserting would deadlock. `FOR NO KEY UPDATE`
  (as `room_write_transaction/2` and `apply_power_levels_change/3` already do) takes the strong lock first; it still conflicts with the
  archive path's `FOR UPDATE` (`Nebu.Admin.DB.archive_room_atomic/1`), so the archived refusal (review cycle 2, Kassandra L-5) is unchanged.
- **D3 No backfill.** Existing rows keep `room_pos = NULL`; `rooms.event_pos` starts at 0, so the first new event of an existing room gets
  1. A backfill would rewrite every `events` row (JSONB content, GIN, `search_vector`, four indexes) under an ACCESS EXCLUSIVE lock or a
  long batched job; story 2 never needs positions of pre-migration events (every client does one full sync after story 2's deploy, so
  every cursor starts after them). Recorded as residual `cq` (c) by story 2. **Contract for story 2:** `rooms.event_pos` is NOT the number
  of events of a pre-existing room (older unstamped events exist); every read must use `room_pos IS NOT NULL` ranges (the D4 index is partial).
- **D4 Index.** `CREATE UNIQUE INDEX events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL`: empty at creation,
  serves story 2's range reads (`room_id = $1 AND room_pos > $2 AND room_pos <= $3 ORDER BY room_pos DESC`) and pins uniqueness. The
  build scans the whole table even though it indexes no row.
- **D5 Migration cost and operator note (as 000051).** The two `ADD COLUMN`s are catalog-only (no rewrite: nullable / constant default).
  Inside the migration transaction the `ALTER TABLE events` holds ACCESS EXCLUSIVE until the commit, which covers the full-table scan of
  the index build: reads and writes of `events` wait for the scan. Operator note in the file and in `07-deployment.md`: run in a
  maintenance window, or pre-create by hand outside a transaction (`ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT;`
  `ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0;` `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS
  events_room_pos_idx ...;`), then the file is a no-op except the trigger (a brief lock); the file is idempotent (`IF NOT EXISTS`, `OR REPLACE`, `DROP TRIGGER IF EXISTS`).
  After a `CREATE UNIQUE INDEX CONCURRENTLY` that failed midway an INVALID index is left and `IF NOT EXISTS` skips it silently: check
  `pg_index.indisvalid`, drop and retry if false (note in the file and in `07-deployment.md`). Down: drop the trigger, the function, the index
  and both columns (story 2 must be reverted first).
- **D6 Runtime cost.** One extra row update of `rooms` per inserted event inside the same statement (no extra client statement: the
  statement-count pins are unaffected); `event_pos` is not indexed, so the update is HOT-eligible. Writes of one room are serialised at
  the database level; the room process serialises them already, so the added wait concerns only the direct writers and handovers. A
  standalone insert (the message path) now waits for any transaction holding the room's row (the archive / unarchive path, a room write
  transaction); their hold time is short but not bounded by `lock_timeout`, which only bounds their own waits (review R2). The standalone
  insert itself has no `lock_timeout` and waits as long as the holder keeps the row (it fails only at the 15 s query timeout). Lock-order inventory: the only transactions that insert events
  (`apply_member_change/4`, `apply_power_levels_change/3`, `apply_redaction/2`, `apply_state_change/3`) take the rooms row first and insert
  last; the archive path locks `FOR UPDATE` first. No lock-order inversion. The other `FOR UPDATE` locks of a `rooms` row,
  `Nebu.Admin.DB.unarchive_room_atomic/1` and `Room.DB.check_room_status_for_update/1` (a short read transaction per cache-miss send),
  insert no event inside their transaction: no inversion either (they conflicted with the FK check of an insert before this story too).
  **Bulk inserts (dev cycle 0, review R1):** repeated UPDATEs of ONE `rooms` row inside ONE transaction cannot be pruned before the
  commit, so each UPDATE walks the row's whole version chain: a bulk insert of many events of ONE room in ONE transaction or statement
  is O(n^2) (about 11 s for 10 000, measured). No current writer does it; a future importer must insert in batches of at most about
  1 000 events per room per transaction, committing between batches, and must NOT disable the trigger table-wide (live writers would
  store NULL positions that story 2 never delivers); a session-scoped `session_replication_role = replica` plus explicit stamping is the
  only safe variant (superuser only). **Write amplification (review I7):** `rooms` is updated once per event; HOT needs free space on
  the page and a moving xmin horizon: watch `n_dead_tup` / `n_tup_hot_upd` of `rooms` and consider `ALTER TABLE rooms SET (fillfactor
  = 70-80)` if the xmin horizon is held back (long transactions, replication slots).
- **D7 Grants and security.** The trigger function runs with the invoker's rights; `nebu_app` already updates `rooms`
  (`set_power_levels/2`). No new trust boundary: positions are not exposed by any API in this story. Security review optional (the
  archived-room lock change D2 keeps its semantics; the reviewer may check D2).
- **D8 Out of scope.** Every read (`/sync`, `/messages`, the partition) and the since token: story 2. `insert_event/1` keeps returning
  `:ok` (story 2 reads positions from the database, not from the writers).

## Acceptance Criteria

```gherkin
Feature: Every event carries a per-room position in commit order

  Scenario: Every writer path stamps consecutive positions
    Given a room created through createRoom with a preset and initial_state, then a message, a state PUT, a power-level change, a redaction, an invite, a kick and a decline
    When the events of the room are read ordered by room_pos
    Then their positions are 1, 2, 3, ... without gaps or duplicates, rooms.event_pos equals the highest, and a personal room's events are stamped the same way

  Scenario: A second writer of the same room waits and a reader never sees N+1 before N
    Given transaction 1 has inserted an event into room R (position N) and not committed, and transaction 2 inserts into room R
    When a reader reads room R's committed events while transaction 1 is open, then after it commits, then after transaction 2 commits
    Then transaction 2 waited, got N+1, and the reader never observed N+1 without N

  Scenario: A rolled-back insert leaves no gap and other rooms are not blocked
    Given transaction 1 has inserted an event into room R and not committed
    When an insert into room S runs, and transaction 1 rolls back and another event is inserted into room R
    Then the insert into room S completes without waiting and the new event of room R gets the position transaction 1 had drawn

  Scenario: Concurrent member changes of one room do not deadlock
    Given two concurrent apply_member_change transactions on the same active room
    When both insert their member event
    Then both commit (serialised) with consecutive positions, no deadlock is reported, and an archived room still refuses both

  Scenario: Migration 000053 applies and reverts, existing rows stay unstamped
    Given a populated schema at 000052
    When 000053 is applied, an event is inserted into an existing room and 000053 is reverted
    Then existing events have room_pos NULL, the new event has room_pos 1, an INSERT that supplies room_pos is overwritten, and after the revert neither column, the trigger nor the index exists
```

## Test list (ATDD)

1. DB tests on a throwaway PostgreSQL with real concurrency (two connections, no sandbox transaction around them):
   `room/events_room_position_db_test.exs` (scenarios 2-4, positions of every writer path through the real functions).
2. HTTP / dispatcher test through the real writers (scenario 1): createRoom with preset and `initial_state`, `/send`, `PUT state`,
   power levels, redaction, invite, kick, decline, `create_personal_room`. "The reader never sees N+1 before N" means: a single-statement
   read of the committed events is always the gapless prefix (multi-statement / REPEATABLE READ readers are story 2's concern). Two member
   changes of one room are normally serialised by the room process; the DB test forces the interleaving with a stimulus trigger.
3. Migration test `migration/000053_events_room_position_test.exs` (scenario 5: fresh = the migrated test database, populated = built in a
   rolled-back transaction after a down; the manual pre-create path is tested with a plain `CREATE UNIQUE INDEX`).
4. `follow-ups.md` is edited by story 2 only; no test pins its state in this story.
5. No existing test should need an amendment (no read changes, no statement-count change); if one does, re-pin DELIBERATELY with a comment.

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Migration `000053` applies and reverts on a throwaway PostgreSQL, on a fresh and on a populated schema
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Open Questions

**ANSWERED (orchestrator, 2026-10-26):** OQ1 trigger (the only place that also stamps inserts of old nodes and future code paths; it is the
second trigger of the schema, after `events_search_vector_trigger` which only writes `search_vector`; documented as an exception to the SQL-inline style of ADR-018). OQ2 accept the in-transaction index build
with the documented manual pre-create path, as for 000051 (maintenance window in the release note).

- **OQ1 Trigger or explicit SQL (D1)?** The trigger is the only place that also stamps inserts of old nodes and of future code paths;
  it is the second trigger of the schema, after `events_search_vector_trigger` (the project style is SQL inline in the handler, ADR-018). Alternative: the CTE in
  `@sql_insert_event` plus "deploy without a mixed-version window" (as 000052). Recommendation: trigger.
- **OQ2 Maintenance window (D5):** accept the in-transaction index build with the documented manual pre-create path, as for 000051?
