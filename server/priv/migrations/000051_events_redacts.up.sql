-- 000051_events_redacts.up.sql
-- Story state-writer-redaction (epic oauth-broker, follow-up `fw`), D5.
--
-- A redaction is a writer-made redaction event whose TARGET is stored in its own column, events.redacts (the room version 10 PDU
-- shape: a top-level `redacts`). The target row itself is never changed (Compliance Mode: content stays server-readable); "redacted" is
-- DERIVED at read time from the redaction rows. Every other event leaves the column NULL; a legacy redaction row (written through /send
-- before this story) has NULL too and is therefore never applied.
--
-- ONE nullable column without default and without backfill (adding it is a catalog-only change), and ONE partial index for the
-- read-time lookup (Room.DB.redactions_for/1: at most ONE row per target, the earliest by (origin_server_ts, event_id), so the index
-- carries both after redacts) and the search / relation exclusions. The index leads with redacts: the batched lookup has no room_id
-- predicate (event ids are global content hashes). Only rows with a redacts value are indexed, so it is empty at creation.
--
-- OPERATOR NOTE (the locks): Nebu.Release.migrate/0 applies every file inside ONE transaction, where CONCURRENTLY is not available.
-- The ALTER TABLE takes an ACCESS EXCLUSIVE lock on events (the largest table) and holds it until the commit, so it covers the whole
-- scan of the plain CREATE INDEX (which alone would take a SHARE lock): READS AND WRITES on events wait, the duration grows with the
-- table size, and there is no lock timeout. Run the migration in a maintenance window, or pre-create both by hand before deploying,
-- outside a transaction:
--   1. ALTER TABLE events ADD COLUMN IF NOT EXISTS redacts TEXT;   (instant: a catalog-only change, a brief ACCESS EXCLUSIVE lock)
--   2. CREATE INDEX CONCURRENTLY IF NOT EXISTS events_redacts_idx ON events (redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL;
-- This file is then a no-op; run it when no long transaction is open on events (its no-op ALTER still needs a brief ACCESS EXCLUSIVE
-- lock).
--
-- OPERATOR NOTE (rollback): the down step drops events.redacts: every applied redaction becomes a never-applied legacy row and every
-- removed message is readable again for the room's members (a re-exposure; see docs/architecture/07-deployment.md).
--
-- No grant needed (the existing table-level grants on events cover the new column). Rolling-deploy safe: old nodes neither read nor
-- write the column.

ALTER TABLE events ADD COLUMN IF NOT EXISTS redacts TEXT;

CREATE INDEX IF NOT EXISTS events_redacts_idx
    ON events (redacts, origin_server_ts, event_id)
    WHERE redacts IS NOT NULL;
