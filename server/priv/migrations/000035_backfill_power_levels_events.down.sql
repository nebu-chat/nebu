-- Rollback for 000035_backfill_power_levels_events.up.sql.
--
-- Deletes ONLY the rows this migration inserted — identified by the
-- distinguishing signatures marker the up migration sets (no real signed event
-- ever carries this marker), never a real m.room.power_levels event a client or
-- a set_power_levels call produced.
DELETE FROM events
WHERE event_type = 'm.room.power_levels'
  AND state_key = ''
  AND signatures->>'nebu_backfill_migration' = '000035_backfill_power_levels_events';
