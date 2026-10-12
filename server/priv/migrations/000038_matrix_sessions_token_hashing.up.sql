-- 000038_matrix_sessions_token_hashing.up.sql
-- token-hashing-matrix-sessions (matrix-session-refresh-fixes).
--
-- matrix_sessions held the live Matrix access/refresh bearer tokens in PLAINTEXT
-- (access_token PRIMARY KEY, refresh_token UNIQUE). A read-only DB leak (backup,
-- replica, SQL injection) therefore handed out usable sessions. This migration
-- replaces both columns by the lowercase hex SHA-256 of the token:
--   access_token  -> access_token_hash  (PRIMARY KEY)
--   refresh_token -> refresh_token_hash (UNIQUE NOT NULL)
-- Both tokens are 256-bit random values, so an unsalted hash is sufficient
-- (Nebu.Matrix.Session.MatrixSessionStore.hash_token/1: SHA-256 over the UTF-8 bytes).
--
-- !! ALL SESSIONS ARE DELETED (forced one-time re-login for every user). !!
-- The table is TRUNCATEd - there is deliberately NO backfill and no CLUSTER. Reason:
-- DROP COLUMN leaves the plaintext bytes in the table file and a backfill UPDATE
-- would leave the old row versions (with plaintext) behind. TRUNCATE gives the table
-- a NEW file (relfilenode); since every session is invalid afterwards, plaintext
-- residue left in old files, backups, WAL or replicas is worthless to an attacker.
-- TRUNCATE requires the TRUNCATE privilege (the owner has it automatically; nebu_app only has
-- SELECT/INSERT/UPDATE/DELETE): run this migration as the role that owns matrix_sessions.
--
-- !! THIS RELEASE MUST BE DEPLOYED STOP-THE-WORLD. !!
-- Stop ALL nodes, run the migration, start the new version. Nodes still running the
-- previous code query the dropped access_token column: every opaque-token request
-- gets a hard 401 (no soft_logout) and logins fail with 500 until the node is replaced.
-- After a rollback (.down.sql) the previous code writes plaintext tokens again.
--
-- The migration runner wraps this file in ONE transaction (no explicit BEGIN/COMMIT);
-- the table is ALTERed in place, so the table-level GRANT to nebu_app (000002) stays.
-- The TRUNCATE comes after the structural ADD COLUMN so a failure rolls everything back.
--
-- Dropping the plaintext columns also drops the old PK, UNIQUE constraint and
-- idx_matrix_sessions_refresh_token; the UNIQUE constraint on refresh_token_hash
-- already provides the lookup index (no separate index is created).
-- idx_matrix_sessions_user_id / _expires_at are untouched.

ALTER TABLE matrix_sessions
    ADD COLUMN access_token_hash  TEXT,
    ADD COLUMN refresh_token_hash TEXT;

TRUNCATE TABLE matrix_sessions;

ALTER TABLE matrix_sessions
    ALTER COLUMN access_token_hash  SET NOT NULL,
    ALTER COLUMN refresh_token_hash SET NOT NULL;

ALTER TABLE matrix_sessions
    DROP COLUMN access_token,
    DROP COLUMN refresh_token;

ALTER TABLE matrix_sessions
    ADD PRIMARY KEY (access_token_hash),
    ADD CONSTRAINT matrix_sessions_refresh_token_hash_key UNIQUE (refresh_token_hash);
