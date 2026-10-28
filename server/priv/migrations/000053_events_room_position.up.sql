-- 000053_events_room_position.up.sql
-- Story events-room-position (epic oauth-broker, follow-up `fc`, story 1 of 2; the reader is story sync-stream-position), D1-D7.
--
-- Every event gets a position that is unique WITHIN ITS ROOM and whose order is the COMMIT order of the room's events, whatever
-- process, node or code path wrote it:
--
--   rooms.event_pos   BIGINT NOT NULL DEFAULT 0   the highest position handed out in the room (the per-room counter)
--   events.room_pos   BIGINT, nullable            the position of the event; NULL for every event stored before this migration
--   events_room_pos_idx                           UNIQUE (room_id, room_pos) WHERE room_pos IS NOT NULL: the range reads of story 2,
--                                                 and the uniqueness pin (empty at creation)
--
-- A BEFORE INSERT ... FOR EACH ROW trigger on events (events_room_pos_trigger, function events_assign_room_pos) draws the position:
-- UPDATE rooms SET event_pos = event_pos + 1 WHERE room_id = NEW.room_id RETURNING event_pos INTO NEW.room_pos (a value supplied by
-- the INSERT is overwritten). The row lock of that UPDATE lives until the inserting transaction ends, so a second insert into the same
-- room (any writer, any node) waits and draws N+1 only after N committed; a rollback rolls the counter back too (no gaps for failed or
-- rolled-back statements; a row skipped by INSERT ... ON CONFLICT DO NOTHING, or DO UPDATE, which also keeps the old row's room_pos,
-- would still consume one; no writer does that). Rooms do not block each other. An event of a room without a rooms row finds no row
-- to update, keeps room_pos NULL and is refused by the foreign key as before. rooms.event_pos is not indexed, so the counter UPDATE
-- is HOT-eligible (D6).
--
-- BULK INSERTS: repeated UPDATEs of ONE rooms row inside ONE transaction cannot be pruned before the commit, so a bulk insert of many
-- events of ONE room in ONE transaction or statement is O(n^2) (about 11 s for 10 000, measured). No current writer does it; a future
-- importer must insert in batches of at most about 1 000 events per room per transaction, committing between batches, and must NOT
-- disable the trigger table-wide (live writers would store NULL positions); a session-scoped session_replication_role = replica plus
-- explicit stamping is the only safe variant (superuser only).
--
-- ADR-018 EXCEPTION: the project writes its SQL inline in the caller; this trigger is a deliberate exception (owner decision, story
-- events-room-position OQ1). The room process is not the only writer (the m.room.create event, emit_state_event_at/6,
-- create_personal_room/2 and emit_decline_event/2 write directly, a Horde handover can briefly run two room processes), and an OLD node
-- during a rolling deploy must be stamped as well: only a trigger covers every present and future INSERT INTO events. It is the second
-- trigger of the schema, after events_search_vector_trigger (000002, writes search_vector only; the two touch different columns).
--
-- No backfill (D3): a backfill would rewrite every events row (JSONB content, GIN, search_vector, four indexes). Existing events keep
-- room_pos NULL and rooms.event_pos starts at 0, so the first new event of an existing room gets 1: rooms.event_pos is NOT the number
-- of events of a pre-existing room, every reader must use room_pos IS NOT NULL ranges.
--
-- OPERATOR NOTE (the locks): Nebu.Release.migrate/0 applies every file inside ONE transaction, where CONCURRENTLY is not available.
-- The two ADD COLUMNs are catalog-only (nullable / constant default: no rewrite), but the ALTER TABLE events takes an ACCESS EXCLUSIVE
-- lock on events (the largest table) and holds it until the commit, so it covers the whole scan of the plain CREATE UNIQUE INDEX (the
-- index stays empty, the build still scans the table): READS AND WRITES on events wait, the duration grows with the table size, and
-- there is no lock timeout. Run the migration in a maintenance window, or pre-create the columns and the index by hand before
-- deploying, outside a transaction:
--   1. ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT;
--   2. ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0;
--   3. CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL;
-- This file is then a no-op except the trigger (a brief lock): it is idempotent (IF NOT EXISTS, OR REPLACE, DROP TRIGGER IF EXISTS).
-- Run it when no long transaction is open on events or rooms: its no-op ALTERs and the trigger DDL still need a brief ACCESS EXCLUSIVE
-- lock on both, and every new query on them queues behind it. A deadlock abort of the migration (against a live insert during the
-- window) is harmless: the whole file rolls back, re-run it.
-- A CREATE UNIQUE INDEX CONCURRENTLY that failed midway leaves an INVALID index that IF NOT EXISTS skips silently (uniqueness is then
-- not enforced): check SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_room_pos_idx'::regclass; if it is false, DROP INDEX
-- CONCURRENTLY events_room_pos_idx and run step 3 again.
--
-- OPERATOR NOTE (rollback): the down step drops the trigger, the function, the index and both columns (the positions are lost, the
-- events stay). Story sync-stream-position (the reader of the positions) must be reverted first.
--
-- Grants: the function runs with the rights of the inserting role (SECURITY INVOKER); nebu_app already updates rooms. EXECUTE is
-- granted explicitly to nebu_app for clarity (PostgreSQL does not check it when the trigger fires).

ALTER TABLE rooms  ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0;
ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos  BIGINT;

CREATE UNIQUE INDEX IF NOT EXISTS events_room_pos_idx
    ON events (room_id, room_pos)
    WHERE room_pos IS NOT NULL;

CREATE OR REPLACE FUNCTION events_assign_room_pos() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE rooms SET event_pos = event_pos + 1 WHERE room_id = NEW.room_id RETURNING event_pos INTO NEW.room_pos;
    RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION events_assign_room_pos() TO nebu_app;

DROP TRIGGER IF EXISTS events_room_pos_trigger ON events;
CREATE TRIGGER events_room_pos_trigger
    BEFORE INSERT ON events
    FOR EACH ROW
    EXECUTE FUNCTION events_assign_room_pos();
