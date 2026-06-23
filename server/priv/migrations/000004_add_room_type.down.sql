-- 000004_add_room_type.down.sql
-- Reverses 000004_add_room_type.up.sql.
-- WARNING: dropping this column removes the denormalised room type permanently
-- (the m.room.create event still carries content.type for Spaces).

ALTER TABLE rooms DROP COLUMN IF EXISTS room_type;
