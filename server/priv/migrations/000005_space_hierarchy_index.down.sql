-- 000005_space_hierarchy_index.down.sql
-- Reverses 000005_space_hierarchy_index.up.sql.
-- Dropping these indexes only removes a query optimisation — no data is lost
-- (the m.space.child / m.space.parent events stay in the events table).

DROP INDEX IF EXISTS idx_events_space_child;
DROP INDEX IF EXISTS idx_events_space_parent;
