-- 000005_space_hierarchy_index.up.sql
-- Matrix Spaces hierarchy (epic spaces-elixir, story s3-space-hierarchy / MSC2946).
--
-- The GET /_matrix/client/v1/rooms/{roomId}/hierarchy BFS walks m.space.child state
-- events outward from a Space, and follows m.space.parent links. These two partial
-- indexes make the per-room child/parent lookups index-only scans instead of full
-- scans of the (append-only, ever-growing) events table.
--
--   idx_events_space_child  — children of a space: WHERE event_type='m.space.child'
--                             AND room_id=$1, returning state_key (the child room id).
--   idx_events_space_parent — parent links of a room: WHERE event_type='m.space.parent'
--                             keyed by state_key (the parent space id).
--
-- Idempotent (CREATE INDEX IF NOT EXISTS) — mirrors the 000004 style so applying on a
-- fresh (post-squash) instance or an already-migrated instance is harmless.

CREATE INDEX IF NOT EXISTS idx_events_space_child
    ON events (room_id, state_key)
    WHERE event_type = 'm.space.child';

CREATE INDEX IF NOT EXISTS idx_events_space_parent
    ON events (state_key)
    WHERE event_type = 'm.space.parent';
