-- 000044_oauth_abuse_hardening.up.sql
-- Story oauth-dcr-abuse-hardening (epic oauth-broker, phase 2, P2, ADR-033 section "DCR and
-- flow-state abuse hardening", AH1-AH17).
--
-- Additive only: nullable columns, CHECKs that every existing row satisfies, and indexes. NO grant,
-- policy, trigger or server_config change (the table-level grants and the row level security of
-- 000040/000041/000043 cover the new columns as they are). Rolling deploy: nodes that still run the
-- previous release insert NULL, and a NULL source never counts towards a per-source cap. ONE
-- exception, failing closed: while an OLD node is still running, its approve / reject of a pending
-- registration that a NEW node registered (and therefore carries a source_key) violates
-- oauth_clients_source_key_pending_check, because the old SQL does not set source_key to NULL. The
-- decision fails with an error and nothing changes; repeating it on a new node succeeds.
--
-- * oauth_clients.client_domain: registrable domain of the client_uri host (public-suffix aware).
--   Written by the application at registration; it only keys the pending-row caps and is NOT part
--   of the 000040 guard trigger. Rows registered before this migration keep NULL.
-- * oauth_clients.source_key / oauth_authz_requests.source_key /
--   oauth_account_login_requests.source_key: Nebu.OAuth.SourceKey, the lowercase hex SHA-256 of the
--   normalised client address (IPv4 /32, IPv6 /64). Pseudonymous, never logged. On oauth_clients it
--   is kept ONLY while the registration is pending (the CHECK below; approve/reject set it to NULL
--   together with created_from_ip / user_agent).

ALTER TABLE oauth_clients
    ADD COLUMN IF NOT EXISTS client_domain TEXT,
    ADD COLUMN IF NOT EXISTS source_key    TEXT;

ALTER TABLE oauth_authz_requests
    ADD COLUMN IF NOT EXISTS source_key TEXT;

ALTER TABLE oauth_account_login_requests
    ADD COLUMN IF NOT EXISTS source_key TEXT;

ALTER TABLE oauth_clients
    DROP CONSTRAINT IF EXISTS oauth_clients_source_key_format_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_source_key_pending_check;

ALTER TABLE oauth_clients
    ADD CONSTRAINT oauth_clients_source_key_format_check
        CHECK (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$'),
    ADD CONSTRAINT oauth_clients_source_key_pending_check
        CHECK (status = 'pending' OR source_key IS NULL);

ALTER TABLE oauth_authz_requests
    DROP CONSTRAINT IF EXISTS oauth_authz_requests_source_key_format_check;

ALTER TABLE oauth_authz_requests
    ADD CONSTRAINT oauth_authz_requests_source_key_format_check
        CHECK (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$');

ALTER TABLE oauth_account_login_requests
    DROP CONSTRAINT IF EXISTS oauth_account_login_requests_source_key_format_check;

ALTER TABLE oauth_account_login_requests
    ADD CONSTRAINT oauth_account_login_requests_source_key_format_check
        CHECK (source_key IS NULL OR source_key ~ '^[0-9a-f]{64}$');

-- Pending-registration caps (per (registrable domain, source) and per source): the count in the
-- INSERT of ClientStore.register/1 only ever looks at pending rows.
CREATE INDEX IF NOT EXISTS oauth_clients_pending_domain_source_idx
    ON oauth_clients (client_domain, source_key) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS oauth_clients_pending_source_idx
    ON oauth_clients (source_key) WHERE status = 'pending';

-- Live-request caps per source (AuthzStore.insert/1, AccountStore.insert_login_request/1).
CREATE INDEX IF NOT EXISTS oauth_authz_requests_source_idx
    ON oauth_authz_requests (source_key, expires_at);

CREATE INDEX IF NOT EXISTS oauth_account_login_requests_source_idx
    ON oauth_account_login_requests (source_key, expires_at);
