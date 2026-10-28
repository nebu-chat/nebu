-- 000042_oauth_sessions_and_signing_keys.up.sql
-- Story oauth-token-endpoint (epic oauth-broker, story 3, ADR-033 section "Token endpoint,
-- sessions, refresh and id_token (story 3)").
--
-- 1. matrix_sessions gains the OAuth columns (T2: ONE table, an `auth_api` column, no second
--    session table). Legacy rows keep `auth_api = 'legacy'` and NULL OAuth columns; OAuth rows carry
--    `client_id`, the granted `scope`, `session_expires_at` (T3: absolute session maximum, copied
--    verbatim on every rotation; `expires_at` is the ACCESS-token expiry of an OAuth row) and
--    `oauth_code_hash` (T8: the hash of the authorization code the session was derived from, copied
--    on every rotation, so a reused code revokes exactly the derived session).
--    Rolling-deploy compatible: the DEFAULT makes every existing row 'legacy', and old code that inserts
--    without the new columns still satisfies both CHECKs, so a rolling deploy needs no code freeze (unlike
--    000038, which truncated). It is NOT lock-free: ADD COLUMN (with the volatile-free DEFAULT, no
--    rewrite), the CHECK validation scan and the FK take short ACCESS EXCLUSIVE / SHARE ROW EXCLUSIVE
--    locks on matrix_sessions for the duration of one table scan; the table is small (one row per
--    token pair, swept by cleanup_expired/0), so this is a brief pause, not a stop-the-world.
-- 2. oauth_signing_keys: Nebu's ES256 id_token signing keys (T17: ES256 fixed by a CHECK, private
--    JWK only as SecretBox ciphertext, public JWK as jsonb; T18: lazy cluster-safe generation, at
--    most ONE active row by a partial UNIQUE index, retirement prepared via an UPDATE guarded by a
--    trigger, never deleted by the runtime role).
-- 3. server_config allowlist gains oauth_access_token_ttl_seconds / oauth_idp_revalidation (T4/T5;
--    no values are inserted: absent keys mean the defaults 900 s / per_refresh).

ALTER TABLE matrix_sessions
    ADD COLUMN IF NOT EXISTS auth_api           TEXT NOT NULL DEFAULT 'legacy',
    ADD COLUMN IF NOT EXISTS client_id          TEXT REFERENCES oauth_clients (client_id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS scope              TEXT,
    ADD COLUMN IF NOT EXISTS session_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS oauth_code_hash    TEXT;

-- The FK ON DELETE RESTRICT enforces the spec rule "a server MUST NOT delete a registration with an
-- active session" in the database (pending rows, the only purged ones, never have sessions).

ALTER TABLE matrix_sessions
    ADD CONSTRAINT matrix_sessions_auth_api_check CHECK (auth_api IN ('legacy', 'oauth'));

ALTER TABLE matrix_sessions
    ADD CONSTRAINT matrix_sessions_oauth_shape_check CHECK (
        (auth_api = 'legacy'
            AND client_id IS NULL AND scope IS NULL AND session_expires_at IS NULL
            AND oauth_code_hash IS NULL)
        OR (auth_api = 'oauth'
            AND client_id IS NOT NULL AND scope IS NOT NULL
            AND session_expires_at IS NOT NULL AND expires_at <= session_expires_at)
    );

-- A session = all rows of (user_id, device_id) (device reuse T7, reuse revocation T11).
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_user_device ON matrix_sessions (user_id, device_id);
-- FK ON DELETE RESTRICT lookups (deleting an oauth_clients row checks for sessions): without it every
-- such check would scan matrix_sessions.
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_client_id ON matrix_sessions (client_id)
    WHERE client_id IS NOT NULL;
-- Code-reuse revocation (T8).
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_oauth_code_hash ON matrix_sessions (oauth_code_hash)
    WHERE oauth_code_hash IS NOT NULL;

-- matrix_sessions has no RLS; the 000002 table GRANT covers the new columns.

CREATE TABLE IF NOT EXISTS oauth_signing_keys (
    kid             TEXT PRIMARY KEY,
    alg             TEXT NOT NULL CHECK (alg = 'ES256'),
    public_jwk      JSONB NOT NULL,
    private_jwk_enc TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    retired_at      TIMESTAMPTZ,
    not_after       TIMESTAMPTZ,
    CONSTRAINT oauth_signing_keys_retired_check CHECK (
        (status = 'active' AND retired_at IS NULL) OR (status = 'retired' AND retired_at IS NOT NULL))
);

-- At most ONE active key (T18). `INSERT ... ON CONFLICT DO NOTHING` without a conflict target covers
-- both the primary key and this index: concurrent lazy generators produce exactly one winner.
CREATE UNIQUE INDEX IF NOT EXISTS oauth_signing_keys_one_active ON oauth_signing_keys (status)
    WHERE status = 'active';

-- Runtime role: no DELETE (keys are retired, never deleted by the application).
GRANT SELECT, INSERT, UPDATE ON oauth_signing_keys TO nebu_app;

ALTER TABLE oauth_signing_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_signing_keys FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_signing_keys_select ON oauth_signing_keys;
CREATE POLICY oauth_signing_keys_select ON oauth_signing_keys FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_signing_keys_insert ON oauth_signing_keys;
-- Only fresh ACTIVE keys can be inserted (a retired key is always the result of an UPDATE).
CREATE POLICY oauth_signing_keys_insert ON oauth_signing_keys FOR INSERT
    WITH CHECK (status = 'active' AND retired_at IS NULL AND not_after IS NULL);
DROP POLICY IF EXISTS oauth_signing_keys_update ON oauth_signing_keys;
CREATE POLICY oauth_signing_keys_update ON oauth_signing_keys FOR UPDATE USING (true) WITH CHECK (true);
-- Deliberately NO DELETE policy.

-- Key material is immutable; a retired key never becomes active again; retiring requires
-- retired_at; not_after (JWKS publication end of a retired key) may only be set or raised.
CREATE OR REPLACE FUNCTION oauth_signing_keys_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.kid IS DISTINCT FROM OLD.kid
       OR NEW.alg IS DISTINCT FROM OLD.alg
       OR NEW.public_jwk IS DISTINCT FROM OLD.public_jwk
       OR NEW.private_jwk_enc IS DISTINCT FROM OLD.private_jwk_enc
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'oauth_signing_keys: key material is immutable'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'retired' AND NEW.status = 'active' THEN
        RAISE EXCEPTION 'oauth_signing_keys: a retired key cannot become active again'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'active' AND NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
        RAISE EXCEPTION 'oauth_signing_keys: retiring a key requires retired_at'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.not_after IS NOT NULL AND (NEW.not_after IS NULL OR NEW.not_after < OLD.not_after) THEN
        RAISE EXCEPTION 'oauth_signing_keys: not_after may only be set or raised'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS oauth_signing_keys_guard ON oauth_signing_keys;
CREATE TRIGGER oauth_signing_keys_guard
    BEFORE UPDATE ON oauth_signing_keys
    FOR EACH ROW EXECUTE FUNCTION oauth_signing_keys_guard();

-- server_config allowlist: 000040's key list and LIKE families VERBATIM plus the two token keys
-- (a dropped key would silently turn its UPDATEs into no-ops).
DROP POLICY IF EXISTS config_update_mutable ON server_config;
CREATE POLICY config_update_mutable ON server_config
    FOR UPDATE
    USING (
        key IN (
            'max_users', 'registration_enabled', 'default_room_visibility',
            'default_max_members', 'bootstrap_completed',
            'oidc_user_id_claim', 'oidc_displayname_claim', 'oidc_email_claim',
            'oidc_directory_enabled', 'oidc_directory_endpoint',
            'gdpr_retention_days', 'signing_key_id', 'compliance_mode_enabled',
            'scim_token_hash',
            'matrix_oidc_refresh_mode', 'admin_oidc_refresh_mode',
            'matrix_oidc_extra_scopes', 'admin_oidc_extra_scopes',
            'admin_group_claim_path',
            'log_collect_info', 'log_retention_info_days',
            'log_collect_debug', 'log_retention_debug_days',
            'log_retention_debug_max_count',
            'log_retention_info_max_count',
            'oauth_enabled', 'oauth_issuer_url',
            'oauth_pending_ttl_days', 'oauth_pending_cap', 'oauth_pending_host_cap',
            'oauth_access_token_ttl_seconds', 'oauth_idp_revalidation'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
