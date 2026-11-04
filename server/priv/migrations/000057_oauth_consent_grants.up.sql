-- 000057_oauth_consent_grants.up.sql
-- Story persistent-consent-grants (epic oauth-session-and-consent, REQ-2026-003): remember a user's "Allow" for an OAuth client.
--
-- 1. oauth_consent_grants: ONE row per (user, client) = what the user last allowed: the normalised scope WITHOUT the per-login device token, the
--    exact redirect URI, and the identity binding client_approved_at (the approved_at of the registration at the time of the Allow: a client that
--    is approved again later has a new approved_at and does not inherit the grant). An Allow upserts the row (ON CONFLICT, so concurrent Allows are
--    one row); the skip decision, the account page, the revocation and the GDPR erasure read / delete it. No secret, no token, no per-login value.
--    The client FK cascades (an owner-role client delete takes its grants). Column level UPDATE only: user_id, client_id and created_at can never be
--    rewritten by the runtime role.
-- 2. oauth_authz_requests.force_consent: `prompt=consent` and `prompt=login` have to travel from /oauth2/authorize to the IdP callback, where the
--    user is known and the decision is taken (the name is historic). Defaulted, so a node that still runs the previous release keeps inserting
--    valid rows.
-- 3. oauth_account_login_requests_action_check (000043) gains 'apps': a sign-in started at /account/apps returns to /account/apps. A node of the
--    previous release does not know the value and falls back to /account for such a row (it never writes one).
--
-- Rolling-deploy safe: a new table and a defaulted column. A node of the previous release never touches the table: it keeps showing the consent
-- screen on every login (no grant is ever read or written there) until every node runs this release; grants written by new nodes are simply not
-- used by old ones. No server_config key (ADR-022).

CREATE TABLE IF NOT EXISTS oauth_consent_grants (
    user_id            TEXT        NOT NULL,
    client_id          TEXT        NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
    scope              TEXT        NOT NULL,   -- normalised: sorted unique tokens, no device token
    redirect_uri       TEXT        NOT NULL,   -- exact requested URI (loopback port included)
    client_approved_at TIMESTAMPTZ NOT NULL,   -- identity binding: oauth_clients.approved_at at the Allow
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),   -- first Allow, never rewritten
    granted_at         TIMESTAMPTZ NOT NULL DEFAULT now(),   -- latest Allow
    PRIMARY KEY (user_id, client_id),
    CONSTRAINT oauth_consent_grants_scope_size_check CHECK (octet_length(scope) BETWEEN 1 AND 2048),
    CONSTRAINT oauth_consent_grants_redirect_size_check CHECK (octet_length(redirect_uri) BETWEEN 1 AND 2048)
);

CREATE INDEX IF NOT EXISTS oauth_consent_grants_client_idx ON oauth_consent_grants (client_id);

ALTER TABLE oauth_authz_requests ADD COLUMN IF NOT EXISTS force_consent BOOLEAN NOT NULL DEFAULT false;

-- 3. (see the header) The account sign-in started at /account/apps returns to /account/apps: the return action CHECK of 000043 gains 'apps'.
ALTER TABLE oauth_account_login_requests DROP CONSTRAINT IF EXISTS oauth_account_login_requests_action_check;
ALTER TABLE oauth_account_login_requests
    ADD CONSTRAINT oauth_account_login_requests_action_check
        CHECK (return_action IS NULL OR return_action IN (
            'org.matrix.profile', 'org.matrix.devices_list', 'org.matrix.device_view',
            'org.matrix.device_delete', 'org.matrix.cross_signing_reset', 'apps'));

-- UpCloud managed Postgres has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets its grants here (same as 000040-000045).
GRANT SELECT, INSERT, DELETE ON oauth_consent_grants TO nebu_app;
-- A development database may carry ALTER DEFAULT PRIVILEGES (dev/postgres/init/01-roles.sql) that already granted nebu_app UPDATE on every new table:
-- take it away, then grant UPDATE on the four columns an Allow rewrites (never user_id, client_id or created_at).
REVOKE UPDATE ON oauth_consent_grants FROM nebu_app;
GRANT UPDATE (scope, redirect_uri, client_approved_at, granted_at) ON oauth_consent_grants TO nebu_app;

-- Row level security, FORCEd because in the single-role dev setup the runtime role owns the tables (same reasoning as 000040 section 3 / 000045).
ALTER TABLE oauth_consent_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_consent_grants FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_consent_grants_select ON oauth_consent_grants;
CREATE POLICY oauth_consent_grants_select ON oauth_consent_grants FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_consent_grants_insert ON oauth_consent_grants;
CREATE POLICY oauth_consent_grants_insert ON oauth_consent_grants FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS oauth_consent_grants_update ON oauth_consent_grants;
CREATE POLICY oauth_consent_grants_update ON oauth_consent_grants FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS oauth_consent_grants_delete ON oauth_consent_grants;
CREATE POLICY oauth_consent_grants_delete ON oauth_consent_grants FOR DELETE USING (true);
