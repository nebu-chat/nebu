-- 000041_oauth_authz_requests_and_codes.up.sql
-- Story oauth-authorize-idp-delegation-code (epic oauth-broker, story 2, ADR-033).
--
-- Flow state of the authorization code grant with Nebu as authorization server in front of the
-- corporate IdP (broker model O2):
--
-- * oauth_authz_requests: one row per validated GET /oauth2/authorize that was delegated to the
--   IdP. D2: the row key is state_hash = lowercase hex SHA-256 of the IdP-leg `state`
--   ("o2." + 43 base64url chars); the plaintext state is never stored (a DB read leak yields no
--   usable state). D3: this table - NOT the node-local SsoStore - is the single source of truth
--   for the flow (IdP PKCE verifier SecretBox-encrypted, IdP nonce, the client request, the
--   browser-binding hash), so any node of the cluster can complete the callback. A row is single
--   use: the callback consumes it with ONE atomic `DELETE ... RETURNING` (rows are never
--   updated, hence no UPDATE grant and no UPDATE policy). TTL 10 minutes.
-- * oauth_codes: Nebu authorization codes. D16: only code_hash = lowercase hex SHA-256 of the
--   256-bit random code is stored (high-entropy input, no salt needed), TTL <= 60 seconds, bound
--   to client, exact redirect URI, PKCE challenge, device, user, granted scope (with the
--   request's prefix) and response mode. The encrypted IdP refresh token and auth_time live in
--   the code row (story 3 moves them into the session). D17: consumption is
--   `UPDATE ... SET used_at = now() WHERE used_at IS NULL AND expires_at > now() RETURNING`
--   (exactly one winner across the cluster); a used code is kept for reuse detection until
--   24 hours after its expiry, then purged (the guard trigger below makes used_at a one-way
--   NULL -> NOT NULL transition, RLS forbids deleting a code earlier).
--
-- Both tables reference oauth_clients ON DELETE CASCADE. The cascade only ever fires for the TTL
-- purge of PENDING clients (approved/rejected registrations are never deleted, migration 000040),
-- and pending clients never have flows (authorize requires status = 'approved'), so in practice
-- it never removes live flow state.
--
-- All columns are TEXT/TIMESTAMPTZ/BOOLEAN; the application rejects NUL/control characters in
-- client-supplied values (state, nonce) before the INSERT.

CREATE TABLE IF NOT EXISTS oauth_authz_requests (
    state_hash            TEXT PRIMARY KEY,
    client_id             TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    redirect_uri          TEXT NOT NULL,           -- exact requested URI (loopback port incl.)
    code_challenge        TEXT NOT NULL,           -- the CLIENT's S256 challenge
    device_id             TEXT NOT NULL,
    scope                 TEXT NOT NULL,           -- granted scope, request prefix
    scope_prefix          TEXT NOT NULL,
    response_mode         TEXT NOT NULL,
    client_state          TEXT,                    -- the client's `state`, NULL when absent
    client_nonce          TEXT,                    -- the client's `nonce` (D23), NULL when absent
    openid_requested      BOOLEAN NOT NULL DEFAULT false,
    idp_code_verifier_enc TEXT NOT NULL,           -- SecretBox(IdP PKCE verifier)
    idp_nonce             TEXT NOT NULL,
    browser_binding_hash  TEXT NOT NULL,           -- sha256 hex of the D4 cookie value
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at            TIMESTAMPTZ NOT NULL,
    CONSTRAINT oauth_authz_requests_scope_prefix_check
        CHECK (scope_prefix IN ('urn:matrix:client:', 'urn:matrix:org.matrix.msc2967.client:')),
    CONSTRAINT oauth_authz_requests_response_mode_check
        CHECK (response_mode IN ('query', 'fragment')),
    CONSTRAINT oauth_authz_requests_ttl_check
        CHECK (expires_at <= created_at + interval '10 minutes')
);

CREATE INDEX IF NOT EXISTS oauth_authz_requests_expires_idx
    ON oauth_authz_requests (expires_at);

CREATE TABLE IF NOT EXISTS oauth_codes (
    code_hash        TEXT PRIMARY KEY,
    client_id        TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    redirect_uri     TEXT NOT NULL,
    code_challenge   TEXT NOT NULL,
    device_id        TEXT NOT NULL,
    user_id          TEXT NOT NULL,
    scope            TEXT NOT NULL,
    scope_prefix     TEXT NOT NULL,
    response_mode    TEXT NOT NULL,
    client_nonce     TEXT,
    openid_requested BOOLEAN NOT NULL DEFAULT false,
    idp_rt_enc       TEXT,                         -- SecretBox(IdP refresh token), NULL when none
    auth_time        TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ NOT NULL,
    used_at          TIMESTAMPTZ,
    CONSTRAINT oauth_codes_scope_prefix_check
        CHECK (scope_prefix IN ('urn:matrix:client:', 'urn:matrix:org.matrix.msc2967.client:')),
    CONSTRAINT oauth_codes_response_mode_check
        CHECK (response_mode IN ('query', 'fragment')),
    CONSTRAINT oauth_codes_ttl_check
        CHECK (expires_at <= created_at + interval '60 seconds')
);

CREATE INDEX IF NOT EXISTS oauth_codes_expires_idx
    ON oauth_codes (expires_at);

-- UpCloud managed Postgres has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime
-- role gets its table grants here (same as 000040). oauth_authz_requests has NO UPDATE grant: its
-- rows are only ever inserted and consumed by DELETE.
GRANT SELECT, INSERT, DELETE ON oauth_authz_requests TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_codes TO nebu_app;

-- Row level security, FORCEd because in the single-role dev setup the runtime role owns the
-- tables (a table owner bypasses RLS unless it is forced; same reasoning as 000040 section 3).
ALTER TABLE oauth_authz_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_authz_requests FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_authz_requests_select ON oauth_authz_requests;
CREATE POLICY oauth_authz_requests_select ON oauth_authz_requests FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_authz_requests_insert ON oauth_authz_requests;
CREATE POLICY oauth_authz_requests_insert ON oauth_authz_requests FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_authz_requests_delete ON oauth_authz_requests;
CREATE POLICY oauth_authz_requests_delete ON oauth_authz_requests FOR DELETE USING (true);
-- Deliberately no UPDATE policy: with FORCE RLS an UPDATE matches no row (a stored request can
-- never be rewritten, e.g. its redirect URI).

ALTER TABLE oauth_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_codes FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_codes_select ON oauth_codes;
CREATE POLICY oauth_codes_select ON oauth_codes FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_codes_insert ON oauth_codes;
-- A code is always born unused.
CREATE POLICY oauth_codes_insert ON oauth_codes FOR INSERT WITH CHECK (used_at IS NULL);
DROP POLICY IF EXISTS oauth_codes_update ON oauth_codes;
-- Narrowed by the guard trigger below (only used_at, only NULL -> NOT NULL).
CREATE POLICY oauth_codes_update ON oauth_codes FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS oauth_codes_delete ON oauth_codes;
-- D17: a code (used or not) stays for reuse detection until 24 hours after its expiry.
CREATE POLICY oauth_codes_delete ON oauth_codes FOR DELETE USING (expires_at < now() - interval '24 hours');

-- D17 guard: the only legal UPDATE of a code is marking it used, exactly once. Every change of
-- another column is refused, and used_at may only go from NULL to NOT NULL (a used code can never
-- become unused again, nor be re-dated). Not SECURITY DEFINER, reads no other table.
CREATE OR REPLACE FUNCTION oauth_codes_guard() RETURNS trigger AS $$
BEGIN
    IF (NEW.code_hash, NEW.client_id, NEW.redirect_uri, NEW.code_challenge, NEW.device_id,
        NEW.user_id, NEW.scope, NEW.scope_prefix, NEW.response_mode, NEW.client_nonce,
        NEW.openid_requested, NEW.idp_rt_enc, NEW.auth_time, NEW.created_at, NEW.expires_at)
       IS DISTINCT FROM
       (OLD.code_hash, OLD.client_id, OLD.redirect_uri, OLD.code_challenge, OLD.device_id,
        OLD.user_id, OLD.scope, OLD.scope_prefix, OLD.response_mode, OLD.client_nonce,
        OLD.openid_requested, OLD.idp_rt_enc, OLD.auth_time, OLD.created_at, OLD.expires_at) THEN
        RAISE EXCEPTION 'oauth_codes: only used_at may change'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.used_at IS DISTINCT FROM OLD.used_at
       AND NOT (OLD.used_at IS NULL AND NEW.used_at IS NOT NULL) THEN
        RAISE EXCEPTION 'oauth_codes: used_at can only be set once (NULL -> NOT NULL)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS oauth_codes_guard ON oauth_codes;
CREATE TRIGGER oauth_codes_guard
    BEFORE UPDATE ON oauth_codes
    FOR EACH ROW EXECUTE FUNCTION oauth_codes_guard();
