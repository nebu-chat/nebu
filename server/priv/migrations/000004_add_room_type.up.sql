-- 000004_add_room_type.up.sql
-- Matrix Spaces foundation (epic spaces-elixir, story s1-spaces-foundation).
-- A Space is a normal room whose m.room.create content.type == "m.space" (MSC1772).
-- This adds the denormalised rooms.room_type column so the room type can be looked up
-- without re-reading the m.room.create event. NULL == an ordinary room (backward compat).
--
-- Idempotent (IF NOT EXISTS guard) — mirrors the 000002 style so applying on a fresh
-- (post-squash) instance or an already-migrated instance is harmless.

ALTER TABLE rooms
    ADD COLUMN IF NOT EXISTS room_type TEXT;
