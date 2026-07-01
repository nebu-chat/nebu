-- 000006_auto_join_opt_outs.up.sql
-- Story rm5-personal-guards-optout (epic room-management-elixir).
--
-- Records per-user opt-outs from auto-join rooms/spaces. When a user leaves a room
-- with is_auto_join=true (or an auto-join Space), a row is written here so that the
-- room is NOT re-added on the next login/initial-sync by
-- ensure_auto_join_memberships/1 / ensure_auto_join_space_memberships/1. Without this
-- the room would "reappear" and feel unleavable.
--
-- PRIMARY KEY (room_id, user_id) makes the opt-out write idempotent (the leave path
-- uses INSERT ... ON CONFLICT DO NOTHING) and prevents duplicate rows.
--
-- The FK to rooms(room_id) keeps the table consistent with the room catalogue (a
-- dropped/non-existent room can never have a dangling opt-out). user_id mirrors the
-- denormalised TEXT user id used throughout the schema (no FK — same as room_members).
--
-- Idempotent (IF NOT EXISTS guard) — mirrors the 000004/000005 style so applying on a
-- fresh (post-squash) instance or an already-migrated instance is harmless.

CREATE TABLE IF NOT EXISTS auto_join_opt_outs (
    room_id     TEXT   NOT NULL REFERENCES rooms(room_id),
    user_id     TEXT   NOT NULL,
    opted_out_at BIGINT NOT NULL,
    PRIMARY KEY (room_id, user_id)
);

-- Lookup by user is the hot path: ensure_auto_join_*_memberships/1 filters the
-- candidate auto-join rooms against this user's opt-outs on every first login.
CREATE INDEX IF NOT EXISTS idx_auto_join_opt_outs_user
    ON auto_join_opt_outs (user_id);

-- ─── Runtime grants (dual-role: nebu_migrate owns, nebu_app operates) ────────
GRANT SELECT, INSERT, UPDATE, DELETE ON auto_join_opt_outs TO nebu_app;
