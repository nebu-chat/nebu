-- 000054_sync_room_cursors.down.sql
-- Reverses 000054_sync_room_cursors.up.sql (story sync-stream-position): the cursor table first (it references sync_tokens), then
-- the five sync_tokens columns. The code rolled back to does not understand the `s2_` tokens: every client falls back once again
-- (one initial sync). Revert this migration BEFORE 000053 (events-room-position): the reads of this story need events.room_pos.

DROP TABLE IF EXISTS sync_room_cursors;

ALTER TABLE sync_tokens DROP COLUMN IF EXISTS prev_cross_signing_pos;
ALTER TABLE sync_tokens DROP COLUMN IF EXISTS prev_account_data_pos;
ALTER TABLE sync_tokens DROP COLUMN IF EXISTS prev_since_token;
ALTER TABLE sync_tokens DROP COLUMN IF EXISTS generation;
ALTER TABLE sync_tokens DROP COLUMN IF EXISTS stream_version;
