-- 000038_matrix_sessions_token_hashing.down.sql
-- Reverse of 000038 (token-hashing-matrix-sessions).
--
-- DATA LOSS / FORCED RE-LOGIN: a SHA-256 hash cannot be turned back into the
-- plaintext token, so the old plaintext access_token/refresh_token columns CANNOT be
-- restored from the hashed rows. Rolling back therefore DELETEs ALL matrix_sessions
-- rows (every opaque Matrix session ends; every client must log in again) and then
-- recreates the original plaintext shape (access_token PRIMARY KEY, refresh_token
-- UNIQUE NOT NULL, idx_matrix_sessions_refresh_token). Hard-revoked state is lost too.
-- After this rollback the previous release writes plaintext tokens again. Roll back
-- stop-the-world as well (all nodes stopped, migrate down, start the old version).

DELETE FROM matrix_sessions;

ALTER TABLE matrix_sessions
    DROP COLUMN access_token_hash,
    DROP COLUMN refresh_token_hash;

ALTER TABLE matrix_sessions
    ADD COLUMN access_token  TEXT NOT NULL,
    ADD COLUMN refresh_token TEXT NOT NULL;

ALTER TABLE matrix_sessions
    ADD PRIMARY KEY (access_token),
    ADD UNIQUE (refresh_token);

CREATE INDEX idx_matrix_sessions_refresh_token ON matrix_sessions (refresh_token);
