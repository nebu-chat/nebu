-- 000054_sync_room_cursors.up.sql
-- Story sync-stream-position (epic oauth-broker, follow-up `fc`, story 2 of 2; needs 000053 of story events-room-position), D3 / D6 /
-- D8 / D19: the incremental /sync continues from per-room stream positions (events.room_pos) instead of one timestamp anchor.
--
--   sync_room_cursors              one row per (user, device, partition room) of a device's since token: pos = the highest room
--                                  position this device has been sent for the room (or the head it was synced to), class = the
--                                  room's partition class at that time (join / invite / leave), invite_marker = the invited_at of a
--                                  delivered ROW-ONLY invitation, gen = the token generation that last wrote the row, prev_* = the
--                                  row's values in the previous generation (prev_pos NULL: the row did not exist then)
--   sync_tokens.stream_version     0 = a row of the timestamp era (its token is never read as positions: one initial-sync fallback),
--                                  1 = the row holds an `s2_` token and the device's cursor rows
--   sync_tokens.generation         the generation of the row's current token (the cursor rows' gen refers to it)
--   sync_tokens.prev_since_token   the previous generation's token: still valid for ONE generation (a retry after a lost response,
--   sync_tokens.prev_*_pos         follow-up `cj` (b)), with the two global delivery positions it was built from
--
-- The cursor rows hang off the token row (ON DELETE CASCADE): the device teardown, /logout, /logout/all, the deactivation and the
-- GDPR erasure delete them with it, no new cleanup path. `class` / `prev_class` are CHECKed against the three partition classes
-- (security review cycle 0, INFO-3: an unexpected value would read as a class change).
--
-- Locks: the five ADD COLUMNs have constant defaults (catalog-only, no rewrite) and take a brief ACCESS EXCLUSIVE lock on
-- sync_tokens; the new table is empty. No statement touches events (no lock on it). No maintenance window. Transaction-safe and
-- idempotent (IF NOT EXISTS). Existing token rows start at stream_version 0: every client does ONE full sync after the update.

CREATE TABLE IF NOT EXISTS sync_room_cursors (
    user_id            TEXT   NOT NULL,
    device_id          TEXT   NOT NULL,
    room_id            TEXT   NOT NULL,
    gen                BIGINT NOT NULL,
    pos                BIGINT NOT NULL,
    class              TEXT   NOT NULL CHECK (class IN ('join', 'invite', 'leave')),
    invite_marker      BIGINT,
    prev_pos           BIGINT,
    prev_class         TEXT   CHECK (prev_class IN ('join', 'invite', 'leave')),
    prev_invite_marker BIGINT,
    PRIMARY KEY (user_id, device_id, room_id),
    FOREIGN KEY (user_id, device_id) REFERENCES sync_tokens (user_id, device_id) ON DELETE CASCADE
);

ALTER TABLE sync_tokens ADD COLUMN IF NOT EXISTS stream_version         SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE sync_tokens ADD COLUMN IF NOT EXISTS generation             BIGINT   NOT NULL DEFAULT 0;
ALTER TABLE sync_tokens ADD COLUMN IF NOT EXISTS prev_since_token       TEXT;
ALTER TABLE sync_tokens ADD COLUMN IF NOT EXISTS prev_account_data_pos  BIGINT;
ALTER TABLE sync_tokens ADD COLUMN IF NOT EXISTS prev_cross_signing_pos BIGINT;

GRANT SELECT, INSERT, UPDATE, DELETE ON sync_room_cursors TO nebu_app;
