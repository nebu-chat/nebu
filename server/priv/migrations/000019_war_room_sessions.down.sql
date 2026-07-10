-- Reverses 000019_war_room_sessions.up.sql.
--
-- The operational_logs_war_room_id_idx index (on operational_logs, not on
-- war_room_sessions) is dropped explicitly — it is not a dependent object
-- of war_room_sessions, so DROP TABLE ... CASCADE below would not touch it.
-- CASCADE on the table drop DOES take care of the
-- operational_logs_war_room_id_fkey FK constraint (a genuine dependent of
-- war_room_sessions) and the table's own
-- war_room_sessions_single_active_idx index. Neither this nor the CASCADE
-- drops the operational_logs.war_room_id column itself — that column is
-- owned by the operational-log-store story's own migration (000017).
DROP INDEX IF EXISTS operational_logs_war_room_id_idx;
DROP TABLE IF EXISTS war_room_sessions CASCADE;
