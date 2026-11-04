-- 000058_room_key_backup.up.sql
-- Story server-side-key-backup (epic e2ee-client-support, REQ-2026-011): the Matrix CS v1.18 "Server-side key backups" store
-- (/_matrix/client/v3/room_keys/**). OPAQUE per user: the server stores `auth_data` and the `session_data` blobs as opaque JSON text,
-- never decrypts and never parses them beyond well-formedness and size (ADR-011 stays: this enables no E2EE room).
--
-- room_key_backup_versions: one row per backup version of a user. `version` is a per-user counter (the newest non-deleted version is the
--   CURRENT one). A deleted version stays as a soft-delete MARKER (`deleted_at` set, `algorithm` / `auth_data` NULL: nothing but the number)
--   so a version number is never reused and a repeated DELETE is idempotent. `etag` is a counter bumped by every change of the stored set
--   of the version (cluster-safe: state lives only here). The marker carries `user_id`: the GDPR erasure deletes it too.
-- room_key_backup_sessions: one row per stored session (user, version, room, session); the megolm indexes are unsigned 32 bit numbers.
--
-- Both tables are per-user data: `user_id TEXT NOT NULL`, deleted by the GDPR erasure (`Nebu.Compliance.UserDeletion`, sessions first).
-- UpCloud managed PostgreSQL has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets its grants here.
-- Row level security is ENABLEd and FORCEd (in the single-role dev setup the runtime role owns the tables); a policy exists for each command.
-- Only new tables: no existing table is touched (rolling-deploy safe). All timestamps are BIGINT epoch-millis.

CREATE TABLE IF NOT EXISTS room_key_backup_versions (
    user_id    TEXT   NOT NULL,
    version    BIGINT NOT NULL,
    algorithm  TEXT,
    auth_data  TEXT,
    etag       BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    deleted_at BIGINT,
    PRIMARY KEY (user_id, version),
    CONSTRAINT room_key_backup_versions_live_check
        CHECK ((deleted_at IS NULL AND algorithm IS NOT NULL AND auth_data IS NOT NULL)
            OR (deleted_at IS NOT NULL AND algorithm IS NULL AND auth_data IS NULL))
);

CREATE TABLE IF NOT EXISTS room_key_backup_sessions (
    user_id             TEXT    NOT NULL,
    version             BIGINT  NOT NULL,
    room_id             TEXT    NOT NULL,
    session_id          TEXT    NOT NULL,
    first_message_index BIGINT  NOT NULL,
    forwarded_count     BIGINT  NOT NULL,
    is_verified         BOOLEAN NOT NULL,
    session_data        TEXT    NOT NULL,
    updated_at          BIGINT  NOT NULL,
    PRIMARY KEY (user_id, version, room_id, session_id),
    FOREIGN KEY (user_id, version) REFERENCES room_key_backup_versions (user_id, version),
    CONSTRAINT room_key_backup_sessions_index_check
        CHECK (first_message_index BETWEEN 0 AND 4294967295 AND forwarded_count BETWEEN 0 AND 4294967295)
);

-- the live versions (the markers are never pruned automatically: accepted growth, bounded by the per-user row cap; an operator prunes old markers with the SQL of
-- docs/compliance/gdpr-deletion-runbook.md): the lookups of the current version and of a live version must not scan them
CREATE INDEX IF NOT EXISTS room_key_backup_versions_live_idx ON room_key_backup_versions (user_id, version) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON room_key_backup_versions TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON room_key_backup_sessions TO nebu_app;

ALTER TABLE room_key_backup_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_key_backup_versions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS room_key_backup_versions_select ON room_key_backup_versions;
CREATE POLICY room_key_backup_versions_select ON room_key_backup_versions FOR SELECT USING (true);
DROP POLICY IF EXISTS room_key_backup_versions_insert ON room_key_backup_versions;
CREATE POLICY room_key_backup_versions_insert ON room_key_backup_versions FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS room_key_backup_versions_update ON room_key_backup_versions;
CREATE POLICY room_key_backup_versions_update ON room_key_backup_versions FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS room_key_backup_versions_delete ON room_key_backup_versions;
CREATE POLICY room_key_backup_versions_delete ON room_key_backup_versions FOR DELETE USING (true);

ALTER TABLE room_key_backup_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_key_backup_sessions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS room_key_backup_sessions_select ON room_key_backup_sessions;
CREATE POLICY room_key_backup_sessions_select ON room_key_backup_sessions FOR SELECT USING (true);
DROP POLICY IF EXISTS room_key_backup_sessions_insert ON room_key_backup_sessions;
CREATE POLICY room_key_backup_sessions_insert ON room_key_backup_sessions FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS room_key_backup_sessions_update ON room_key_backup_sessions;
CREATE POLICY room_key_backup_sessions_update ON room_key_backup_sessions FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS room_key_backup_sessions_delete ON room_key_backup_sessions;
CREATE POLICY room_key_backup_sessions_delete ON room_key_backup_sessions FOR DELETE USING (true);
