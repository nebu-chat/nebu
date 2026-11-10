-- 000063_events_room_pos_covering_idx.down.sql
-- Drops the covering index only (events_room_pos_idx and every other index stay). The rejoin /sync floor falls back to
-- events_room_pos_idx and becomes plan dependent again (see the up file).
DROP INDEX IF EXISTS events_room_pos_ts_idx;
