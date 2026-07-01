-- 000008_room_aliases.up.sql
-- Story room-canonical-alias-from-name (epic room-naming-and-default-rooms).
--
-- When a room is created with a name (e.g. "general") on server "localhost", the create
-- path derives and registers a canonical alias `#general:localhost` so the room is
-- addressable/displayable by a readable alias, not just its opaque `!id:server`. This
-- table is the server-wide alias→room directory.
--
-- `alias` is the PRIMARY KEY: an alias maps to exactly one room and is unique across the
-- whole server (Matrix room-alias uniqueness). The unique constraint is what makes
-- collision handling race-safe (ADR-020): concurrent creates of two "general" rooms each
-- try `#general:localhost`, exactly one INSERT wins, the loser deterministically retries
-- `#general-2:localhost`, … — no read-then-write race, no alias hijacking/overwrite.
--
-- The FK to rooms(room_id) keeps the directory consistent with the room catalogue (a
-- dropped/non-existent room can never have a dangling alias). created_at is BIGINT
-- epoch-millis, matching the schema-wide timestamp convention.
--
-- Idempotent (IF NOT EXISTS guard) — mirrors the 000004/000005/000006 style so applying
-- on a fresh (post-squash) instance or an already-migrated instance is harmless.

CREATE TABLE IF NOT EXISTS room_aliases (
    alias      TEXT   PRIMARY KEY,
    room_id    TEXT   NOT NULL REFERENCES rooms(room_id),
    created_at BIGINT NOT NULL
);

-- Reverse lookup (room → its alias[s]) is used by name-based / admin lookups and any
-- future alias-management surface; the alias → room direction is served by the PK.
CREATE INDEX IF NOT EXISTS idx_room_aliases_room
    ON room_aliases (room_id);

-- ─── Runtime grants (dual-role: nebu_migrate owns, nebu_app operates) ────────
GRANT SELECT, INSERT, UPDATE, DELETE ON room_aliases TO nebu_app;
