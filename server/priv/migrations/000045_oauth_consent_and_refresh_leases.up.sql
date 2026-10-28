-- 000045_oauth_consent_and_refresh_leases.up.sql
-- Story oauth-authorize-freshness (epic oauth-broker, phase 2, P3, ADR-033 section "Consent, freshness
-- and refresh serialization", FR6, FR15, FR19).
--
-- 1. oauth_consent_requests (FR6): the state between the verified IdP login and the user's click on the
--    consent page. The row key is binding_hash = lowercase hex SHA-256 of the 256-bit consent cookie (the
--    plaintext cookie is never stored; there is no CSRF column either: the token is derived from the
--    cookie). The row carries every input of the authorization code (the code itself is minted only at
--    "Allow"), the SecretBox-encrypted IdP refresh token, the RAW auth_time claim or NULL (FR4: never iat,
--    never the consent time) and login_fresh (drives the notice on the page). A row is single use: Allow
--    and Deny consume it with ONE atomic `DELETE ... RETURNING` (rows are never updated: NO UPDATE grant,
--    NO UPDATE policy). TTL at most 5 minutes (CHECK).
-- 2. oauth_idp_refresh_leases (FR15, gate n): the per-device lease that serializes the IdP leg of a
--    `per_refresh` token refresh across the cluster WITHOUT holding a pool connection or a transaction
--    across the IdP HTTP call (an advisory xact lock would). Claim: INSERT ... ON CONFLICT DO UPDATE ...
--    WHERE lease_until <= now(); a crashed holder's lease simply expires (CHECK: at most 120 seconds).
--    The row dies with its device (FK ON DELETE CASCADE).
-- 3. oauth_account_sessions.auth_time becomes nullable (FR14, gate y): an IdP that reports no auth_time
--    yields a session that is never fresh (fail closed) instead of a session stamped with the callback time.
--
-- 4. (review cycle 1) oauth_consent_requests.source_key (L-2: per-source live cap, NULL = not counted) and two
--    cap indexes; oauth_codes.device_holder_checked / device_holder_client_id (L-1): the device holder the user
--    consented to at Allow, re-checked under the devices row lock when the code is redeemed.
--
-- Rolling-deploy safe: new tables, one relaxed constraint and two defaulted columns. Nodes still running the
-- previous release never touch the new tables and keep inserting a NOT NULL auth_time, which stays valid; the
-- defaulted oauth_codes columns say "holder not checked" for their codes. They also keep redirecting to the
-- client right after the IdP callback (no consent), and they have NO /oauth2/consent route: a browser that a
-- NEW node sent there and that lands on an OLD node (load balancer) gets a 404 until every node is upgraded.
-- Cut ALL nodes over before oauth_enabled (the epic leaves it off, so this window is never user visible).
-- No server_config key (ADR-022).

CREATE TABLE IF NOT EXISTS oauth_consent_requests (
    binding_hash     TEXT PRIMARY KEY,
    client_id        TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    redirect_uri     TEXT NOT NULL,           -- exact requested URI (loopback port incl.)
    code_challenge   TEXT NOT NULL,           -- the CLIENT's S256 challenge
    device_id        TEXT NOT NULL,
    user_id          TEXT NOT NULL,
    scope            TEXT NOT NULL,           -- granted scope, request prefix
    scope_prefix     TEXT NOT NULL,
    response_mode    TEXT NOT NULL,
    client_state     TEXT,                    -- the client's `state`, NULL when absent
    client_nonce     TEXT,                    -- the client's `nonce`, NULL when absent
    openid_requested BOOLEAN NOT NULL,
    idp_rt_enc       TEXT,                    -- SecretBox(IdP refresh token), NULL when none
    auth_time        TIMESTAMPTZ,             -- the RAW auth_time claim (clamped) or NULL, FR4
    login_fresh      BOOLEAN NOT NULL,
    source_key       TEXT,                    -- Nebu.OAuth.SourceKey of the callback's client address, L-2
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at       TIMESTAMPTZ NOT NULL,
    CONSTRAINT oauth_consent_requests_source_key_check
        CHECK (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_consent_requests_binding_hash_check
        CHECK (binding_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT oauth_consent_requests_scope_prefix_check
        CHECK (scope_prefix IN ('urn:matrix:client:', 'urn:matrix:org.matrix.msc2967.client:')),
    CONSTRAINT oauth_consent_requests_response_mode_check
        CHECK (response_mode IN ('query', 'fragment')),
    CONSTRAINT oauth_consent_requests_ttl_check
        CHECK (expires_at <= created_at + interval '5 minutes')
);

CREATE INDEX IF NOT EXISTS oauth_consent_requests_expires_idx
    ON oauth_consent_requests (expires_at);
-- per-user / per-source live caps inside the INSERT (L-2)
CREATE INDEX IF NOT EXISTS oauth_consent_requests_user_idx
    ON oauth_consent_requests (user_id, expires_at);
CREATE INDEX IF NOT EXISTS oauth_consent_requests_source_idx
    ON oauth_consent_requests (source_key, expires_at);

CREATE TABLE IF NOT EXISTS oauth_idp_refresh_leases (
    user_id     TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    holder      TEXT NOT NULL,               -- 128-bit random hex of the holder
    acquired_at TIMESTAMPTZ NOT NULL,
    lease_until TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, device_id),
    FOREIGN KEY (user_id, device_id) REFERENCES devices (user_id, device_id) ON DELETE CASCADE,
    CONSTRAINT oauth_idp_refresh_leases_ttl_check
        CHECK (lease_until <= acquired_at + interval '120 seconds')
);

ALTER TABLE oauth_account_sessions ALTER COLUMN auth_time DROP NOT NULL;

-- L-1: the holder of the device at Allow. `device_holder_checked = false` (every code of an older node, every
-- code minted outside the consent step) means "no holder re-check at redemption".
ALTER TABLE oauth_codes
    ADD COLUMN IF NOT EXISTS device_holder_checked   BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS device_holder_client_id TEXT;

-- UpCloud managed Postgres has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets
-- its table grants here (same as 000040/000041/000043). Consent rows are never updated.
GRANT SELECT, INSERT, DELETE ON oauth_consent_requests TO nebu_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_idp_refresh_leases TO nebu_app;
-- A development database may carry ALTER DEFAULT PRIVILEGES (dev/postgres/init/01-roles.sql) that already
-- granted nebu_app UPDATE on every new table: take it away again, so "no UPDATE grant" holds everywhere.
REVOKE UPDATE ON oauth_consent_requests FROM nebu_app;

-- Row level security, FORCEd because in the single-role dev setup the runtime role owns the tables (a
-- table owner bypasses RLS unless it is forced; same reasoning as 000040 section 3 / 000041 / 000043).
ALTER TABLE oauth_consent_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_consent_requests FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_consent_requests_select ON oauth_consent_requests;
CREATE POLICY oauth_consent_requests_select ON oauth_consent_requests FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_consent_requests_insert ON oauth_consent_requests;
CREATE POLICY oauth_consent_requests_insert ON oauth_consent_requests FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_consent_requests_delete ON oauth_consent_requests;
CREATE POLICY oauth_consent_requests_delete ON oauth_consent_requests FOR DELETE USING (true);
-- Deliberately no UPDATE policy: a stored consent request can never be rewritten (e.g. its redirect URI).

ALTER TABLE oauth_idp_refresh_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_idp_refresh_leases FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_idp_refresh_leases_select ON oauth_idp_refresh_leases;
CREATE POLICY oauth_idp_refresh_leases_select ON oauth_idp_refresh_leases FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_idp_refresh_leases_insert ON oauth_idp_refresh_leases;
CREATE POLICY oauth_idp_refresh_leases_insert ON oauth_idp_refresh_leases FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_idp_refresh_leases_update ON oauth_idp_refresh_leases;
CREATE POLICY oauth_idp_refresh_leases_update ON oauth_idp_refresh_leases FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS oauth_idp_refresh_leases_delete ON oauth_idp_refresh_leases;
CREATE POLICY oauth_idp_refresh_leases_delete ON oauth_idp_refresh_leases FOR DELETE USING (true);
