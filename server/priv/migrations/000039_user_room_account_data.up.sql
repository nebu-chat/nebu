-- 000039_user_room_account_data.up.sql
-- Story room-account-data-and-read-markers (epic matrix-spec-gaps).
--
-- DURABLE per-user ROOM-scoped Matrix account data. Backs:
--   PUT/GET /_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}
--   POST    /_matrix/client/v3/rooms/{roomId}/read_markers   (m.fully_read)
-- and `rooms.join.<roomId>.account_data.events` of GET /sync.
--
-- NOTE: a dormant legacy table `room_account_data` (JSONB, RLS-forced, never read or
-- written by any code) exists since 000001/000002. It is deliberately NOT reused:
-- the contract needs verbatim TEXT (ADR-011, byte-exact round trip) and a change
-- position, and its FORCE ROW LEVEL SECURITY policy depends on a session variable
-- Nebu never sets. Cleaning it up is a separate task.
--
-- content_json: the value VERBATIM as the client sent it (opaque, ADR-011), TEXT not jsonb.
--
-- stream_pos: MONOTONIC change position (taken from a sequence on every insert AND
-- every update of a row). /sync compares it with the position embedded in the client's
-- since token, so delivery is correct per DEVICE (no consume-once flag). Writers
-- serialise per user with pg_advisory_xact_lock, so for one user the position order
-- equals the commit order (a reader never sees position N+1 while N is still pending).
--
-- Reusable by the follow-up story `room-tags` (type = 'm.tag').
-- All timestamps are BIGINT epoch-millis (schema-wide convention).

CREATE SEQUENCE IF NOT EXISTS user_room_account_data_pos_seq;

CREATE TABLE IF NOT EXISTS user_room_account_data (
    user_id      TEXT   NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    room_id      TEXT   NOT NULL REFERENCES rooms(room_id) ON DELETE CASCADE,
    type         TEXT   NOT NULL,
    content_json TEXT   NOT NULL,
    stream_pos   BIGINT NOT NULL DEFAULT nextval('user_room_account_data_pos_seq'),
    created_at   BIGINT NOT NULL,
    updated_at   BIGINT NOT NULL,
    PRIMARY KEY (user_id, room_id, type)
);

ALTER SEQUENCE user_room_account_data_pos_seq OWNED BY user_room_account_data.stream_pos;

CREATE INDEX IF NOT EXISTS user_room_account_data_user_pos_idx
    ON user_room_account_data (user_id, stream_pos);

GRANT SELECT, INSERT, UPDATE, DELETE ON user_room_account_data TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE user_room_account_data_pos_seq TO nebu_app;
