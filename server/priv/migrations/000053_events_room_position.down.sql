-- 000053_events_room_position.down.sql
-- Reverses 000053_events_room_position.up.sql (story events-room-position): the trigger first, then its function, the index and the
-- two columns. Story sync-stream-position (the reader of the positions) must be reverted first. The positions are lost, the events stay.

DROP TRIGGER IF EXISTS events_room_pos_trigger ON events;
DROP FUNCTION IF EXISTS events_assign_room_pos();

DROP INDEX IF EXISTS events_room_pos_idx;

ALTER TABLE events DROP COLUMN IF EXISTS room_pos;
ALTER TABLE rooms  DROP COLUMN IF EXISTS event_pos;
