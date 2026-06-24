-- 000008_room_aliases.down.sql
-- Reverses 000008_room_aliases.up.sql.
-- WARNING: dropping this table discards all registered room aliases — after a down+up
-- cycle, existing rooms keep their m.room.canonical_alias state event but the alias no
-- longer resolves via the directory until re-registered.

DROP INDEX IF EXISTS idx_room_aliases_room;
DROP TABLE IF EXISTS room_aliases;
