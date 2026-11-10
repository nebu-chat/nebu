-- 000063_events_room_pos_covering_idx.up.sql
-- Bugfix sync-rejoin-floor-window-point-lookups (follow-up `I` of the oauth-pages-redesign flake triage).
--
-- The time floor of the gated rejoin /sync range read (Room.DB.fetch_visible_events_in_range_segmented/5) reads `origin_server_ts`
-- of at most 64 events at the positions `base - 63 .. base` (or, for an empty window, `base + 1 .. base + 64`) of ONE room. Neither
-- existing index serves that well on its own: events_room_pos_idx (UNIQUE (room_id, room_pos) WHERE room_pos IS NOT NULL) needs a
-- heap fetch per row, and the planner estimates the range with GLOBAL position statistics (the position is per room), i.e. hundreds
-- of rows for a low base against the real 10, so it can prefer a bitmap scan of events_room_id_ts_idx with `room_id` as the only
-- index condition (small, because identical (room_id, origin_server_ts) keys are deduplicated), which reads the WHOLE room: 404 of
-- 414 rows removed by the filter, per device and per replay of the same `since` token. A COVERING index makes the floor an
-- index-only scan of the window (the timestamp is in the index), which was cheaper than the room-only paths in every regime measured with
-- the real indexes: the skew, stale statistics and fresh ANALYZE, generic and custom plans, and with index-only scans switched off
-- (bounded by the 64 positions in each of them).
-- Residual: when index-only scans are not usable (most pages not all-visible) AND a smaller room-only index exists AND the estimate is inflated,
-- the planner can still choose a room-only bitmap scan (one read of the room per floor, as before this migration): no hint-free statement or
-- index can exclude that. Measured on a churned table with a fresh ANALYZE: 500 rows read once per floor (accepted residual).
--
--   events_room_pos_ts_idx   (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL
--
-- It is NOT unique (events_room_pos_idx stays the uniqueness pin; an existing index is neither dropped nor changed) and partial like
-- it: events stored before 000053 have no position and are never part of a position range. Cost: one more index entry (room_id,
-- room_pos, origin_server_ts) per new event; reads that do not use it are unchanged.
--
-- OPERATOR NOTE (the lock): Nebu.Release.migrate/0 applies every file inside ONE transaction, where CONCURRENTLY is not available;
-- the plain CREATE INDEX takes a SHARE lock on events (the largest table): WRITES wait until the build is done, reads continue; the
-- duration grows with the number of positioned events. Run it in a maintenance window, or pre-create the index by hand before
-- deploying, outside a transaction:
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_ts_idx
--       ON events (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL;
-- This file is then a no-op. A CREATE INDEX CONCURRENTLY that failed midway leaves an INVALID index that IF NOT EXISTS skips silently:
-- check SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_room_pos_ts_idx'::regclass; if false, DROP INDEX CONCURRENTLY it and
-- build it again.
--
-- No data change, no grant (index only); rolling-deploy safe (old nodes ignore the index).

CREATE INDEX IF NOT EXISTS events_room_pos_ts_idx
    ON events (room_id, room_pos) INCLUDE (origin_server_ts)
    WHERE room_pos IS NOT NULL;
