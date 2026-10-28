-- 000043_oauth_account_management.up.sql
-- Story oauth-account-management (epic oauth-broker, story 6, ADR-033 section "Account management and
-- m.oauth (story 6)", decisions A6, A8, A15, A24).
--
-- 1. oauth_account_login_requests (A6): flow state of the account-page sign-in through the corporate
--    IdP (the ONE IdP client, the shared callback, state tag "o2.acct."). Like oauth_authz_requests
--    (000041) the row key is state_hash = lowercase hex SHA-256 of the state (the plaintext state is
--    never stored), the IdP PKCE verifier is SecretBox-encrypted, the browser-binding cookie is stored
--    as a hash, and a row is single use: the callback consumes it with ONE atomic
--    `DELETE ... RETURNING` (rows are never updated: NO UPDATE grant, NO UPDATE policy). TTL 10 minutes.
--    The return target (`return_action` NULL = the default page, else one of the five advertised
--    actions; the device id for the two device pages) is validated when the row is
--    created and is the ONLY source of the post-login redirect (open-redirect safe).
-- 2. oauth_account_sessions (A8): the short-lived browser session of the account page. NOT a Matrix
--    device: session_hash is the SHA-256 (lowercase hex) of a 256-bit random cookie value, the CSRF token
--    is stored only as csrf_hash, auth_time (unix seconds, the IdP's auth_time claim or the callback
--    time) drives the re-authentication window of destructive actions (A10). Idle 15 minutes (sliding,
--    updated in ONE atomic UPDATE), absolute 1 hour (CHECK), at most 20 live sessions per user (enforced
--    by the INSERT transaction, A19).
-- 3. uia_sessions_user_op_pending_idx (A15): serves the per-user listing of pending
--    `cross_signing_reset` UIA sessions (the approval record reuses uia_sessions, migration 000012).
--
-- Rolling-deploy safe: only new tables and one new partial index on an existing small table; no existing
-- column or constraint changes, so old code keeps working during the rollout. CREATE INDEX takes a short
-- SHARE lock on uia_sessions (rows expire after 15 minutes: the table is tiny).
-- No server_config key (ADR-022): the lifetimes are code constants.

CREATE TABLE IF NOT EXISTS oauth_account_login_requests (
    state_hash            TEXT PRIMARY KEY,
    idp_verifier_enc      TEXT NOT NULL,           -- SecretBox(IdP PKCE verifier)
    idp_nonce             TEXT NOT NULL,
    binding_hash          TEXT NOT NULL,           -- sha256 hex of the browser-binding cookie value
    return_action         TEXT,                    -- NULL = default page, else one of the five actions
    return_device_id      TEXT,
    replaces_session_hash TEXT,                    -- hash of a still-presented old account session
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at            TIMESTAMPTZ NOT NULL,
    CONSTRAINT oauth_account_login_requests_ttl_check
        CHECK (expires_at <= created_at + interval '10 minutes'),
    CONSTRAINT oauth_account_login_requests_state_hash_check
        CHECK (state_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_account_login_requests_binding_hash_check
        CHECK (binding_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_account_login_requests_replaces_check
        CHECK (replaces_session_hash IS NULL OR replaces_session_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_account_login_requests_action_check
        CHECK (return_action IS NULL OR return_action IN (
            'org.matrix.profile', 'org.matrix.devices_list', 'org.matrix.device_view',
            'org.matrix.device_delete', 'org.matrix.cross_signing_reset')),
    CONSTRAINT oauth_account_login_requests_lengths_check
        CHECK (octet_length(idp_nonce) <= 256
           AND (return_device_id IS NULL OR octet_length(return_device_id) <= 255))
);

CREATE INDEX IF NOT EXISTS oauth_account_login_requests_expires_idx
    ON oauth_account_login_requests (expires_at);

CREATE TABLE IF NOT EXISTS oauth_account_sessions (
    session_hash    TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL,
    auth_time       BIGINT NOT NULL,               -- unix seconds
    csrf_hash       TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    idle_expires_at TIMESTAMPTZ NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    CONSTRAINT oauth_account_sessions_lifetime_check
        CHECK (expires_at <= created_at + interval '1 hour'),
    CONSTRAINT oauth_account_sessions_idle_check
        CHECK (idle_expires_at <= expires_at),
    CONSTRAINT oauth_account_sessions_session_hash_check
        CHECK (session_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_account_sessions_csrf_hash_check
        CHECK (csrf_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS oauth_account_sessions_expires_idx
    ON oauth_account_sessions (expires_at);
CREATE INDEX IF NOT EXISTS oauth_account_sessions_user_idx
    ON oauth_account_sessions (user_id, created_at);

CREATE INDEX IF NOT EXISTS uia_sessions_user_op_pending_idx
    ON uia_sessions (user_id, op) WHERE consumed = FALSE;

-- UpCloud managed Postgres has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role
-- gets its table grants here (same as 000040/000041). Login requests are never updated.
GRANT SELECT, INSERT, DELETE ON oauth_account_login_requests TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_account_sessions TO nebu_app;
-- A development database may carry ALTER DEFAULT PRIVILEGES (dev/postgres/init/01-roles.sql) that already
-- granted nebu_app UPDATE on every new table: take it away again, so "no UPDATE grant" holds everywhere.
REVOKE UPDATE ON oauth_account_login_requests FROM nebu_app;

-- Row level security, FORCEd because in the single-role dev setup the runtime role owns the tables (a
-- table owner bypasses RLS unless it is forced; same reasoning as 000040 section 3 / 000041).
ALTER TABLE oauth_account_login_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_account_login_requests FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_account_login_requests_select ON oauth_account_login_requests;
CREATE POLICY oauth_account_login_requests_select ON oauth_account_login_requests FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_account_login_requests_insert ON oauth_account_login_requests;
CREATE POLICY oauth_account_login_requests_insert ON oauth_account_login_requests FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_account_login_requests_delete ON oauth_account_login_requests;
CREATE POLICY oauth_account_login_requests_delete ON oauth_account_login_requests FOR DELETE USING (true);
-- Deliberately no UPDATE policy: a stored login request can never be rewritten.

ALTER TABLE oauth_account_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_account_sessions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_account_sessions_select ON oauth_account_sessions;
CREATE POLICY oauth_account_sessions_select ON oauth_account_sessions FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_account_sessions_insert ON oauth_account_sessions;
CREATE POLICY oauth_account_sessions_insert ON oauth_account_sessions FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_account_sessions_update ON oauth_account_sessions;
CREATE POLICY oauth_account_sessions_update ON oauth_account_sessions FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS oauth_account_sessions_delete ON oauth_account_sessions;
CREATE POLICY oauth_account_sessions_delete ON oauth_account_sessions FOR DELETE USING (true);
