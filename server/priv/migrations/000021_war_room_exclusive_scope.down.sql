-- Reverses 000021_war_room_exclusive_scope.up.sql.
ALTER TABLE war_room_sessions DROP COLUMN IF EXISTS exclusive_scope;
