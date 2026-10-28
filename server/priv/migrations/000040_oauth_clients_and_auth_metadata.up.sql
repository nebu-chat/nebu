-- 000040_oauth_clients_and_auth_metadata.up.sql
-- Story oauth-metadata-dcr-admin-approval (epic oauth-broker, ADR-033).
--
-- 1. oauth_clients: registrations created by Dynamic Client Registration (RFC 7591,
--    POST /oauth2/register). Every registration starts 'pending' and becomes usable only
--    after an admin approved it (there is deliberately NO auto-approve / dcr_policy switch).
--
--    Dedup + approval are per METADATA HASH, not per client_id: `metadata_hash` is the
--    SHA-256 (lowercase hex) of the canonical JSON (keys sorted alphabetically) of the
--    NORMALIZED, REGISTERED metadata. System/audit fields (client_id, created_at,
--    approved_*, rejected_*, last_used_at, created_from_ip, user_agent) are never part of the
--    hashed metadata. Localized metadata keys with a `#lang` suffix (e.g. `client_name#de`) are
--    DROPPED before hashing and are never stored; only the base key (`client_name`) is kept in
--    the `metadata` JSONB. Identical metadata therefore resolves to ONE row; concurrent
--    registrations are made atomic by `INSERT ... ON CONFLICT (metadata_hash) DO NOTHING`.
--
--    APPROVED and REJECTED registrations are never deleted (Matrix spec: a server MUST NOT
--    delete a registration with an active session) - rejecting only sets status = 'rejected'.
--    PENDING registrations never have a session and are the only rows an unauthenticated caller
--    can create in bulk, so they ARE purged after a TTL (see section 3: RLS lets the runtime role
--    DELETE only rows with status = 'pending'). No foreign keys: a registration is independent
--    of any user identity.
--
--    Timestamps are TIMESTAMPTZ (the story sketch says TIMESTAMP; TIMESTAMPTZ avoids a
--    session-timezone dependency of CURRENT_TIMESTAMP / NOW()).
CREATE TABLE IF NOT EXISTS oauth_clients (
    client_id                  TEXT PRIMARY KEY,
    metadata                   JSONB NOT NULL,
    metadata_hash              TEXT NOT NULL UNIQUE,
    application_type           TEXT NOT NULL DEFAULT 'web',
    status                     TEXT NOT NULL DEFAULT 'pending',
    approved_by                TEXT,
    approved_at                TIMESTAMPTZ,
    rejected_by                TEXT,
    rejected_at                TIMESTAMPTZ,
    token_endpoint_auth_method TEXT NOT NULL DEFAULT 'none',
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_used_at               TIMESTAMPTZ,
    -- Lower-cased host of metadata.client_uri: the key of the per-host PENDING cap
    -- (server_config `oauth_pending_host_cap`, section 3). NULL for rows that were not created
    -- through Nebu.OAuth.ClientStore.register/1.
    client_host                TEXT,
    -- Abuse-triage data of the FIRST registrant, kept ONLY while the row is pending: the approve /
    -- reject UPDATE sets both to NULL (data minimisation, ADR-033 "Retention").
    created_from_ip            TEXT,
    user_agent                 TEXT,
    -- Defence in depth: the application only ever writes these values, but a typo'd status (e.g.
    -- 'aproved') must not silently create a row that is neither pending nor approved.
    CONSTRAINT oauth_clients_status_check
        CHECK (status IN ('pending', 'approved', 'rejected')),
    CONSTRAINT oauth_clients_application_type_check
        CHECK (application_type IN ('web', 'native')),
    -- A decision is always attributable: approved/rejected rows carry their *_by/*_at, pending rows
    -- carry none of them (security review F-3). The two decisions are mutually exclusive.
    CONSTRAINT oauth_clients_decision_check
        CHECK (
            (status = 'pending'
                AND approved_by IS NULL AND approved_at IS NULL
                AND rejected_by IS NULL AND rejected_at IS NULL)
            OR (status = 'approved'
                AND approved_by IS NOT NULL AND approved_at IS NOT NULL
                AND rejected_by IS NULL AND rejected_at IS NULL)
            OR (status = 'rejected'
                AND rejected_by IS NOT NULL AND rejected_at IS NOT NULL
                AND approved_by IS NULL AND approved_at IS NULL)
        )
);

-- Admin approval list: pending/rejected registrations, newest first.
CREATE INDEX IF NOT EXISTS oauth_clients_status_created_idx
    ON oauth_clients (status, created_at DESC);

-- Dedup lookup by hash. (The UNIQUE constraint above already maintains an equivalent index;
-- this named one is kept explicit so the dedup path is documented and asserted by the tests.)
CREATE INDEX IF NOT EXISTS oauth_clients_metadata_hash_idx
    ON oauth_clients (metadata_hash);

-- Per-client_uri-host pending cap lookup (security review F-1b).
CREATE INDEX IF NOT EXISTS oauth_clients_pending_host_idx
    ON oauth_clients (client_host) WHERE status = 'pending';

-- UpCloud managed Postgres has no ALTER DEFAULT PRIVILEGES for the migrate role, so the
-- runtime role gets its table grant here (same as 000024/000039). DELETE is granted too, but is
-- confined to PENDING rows by the row level security of section 3.
GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_clients TO nebu_app;

-- 3. Pending-row protection (code-review cycle 0 decision, ADR-033 "Pending registrations").
--
-- POST /oauth2/register is unauthenticated, so `pending` rows can be created in bulk. They are
-- purged after a TTL (server_config `oauth_pending_ttl_days`, default 30) by the periodic
-- `Nebu.Workers.OAuthPendingPurgeWorker`, and the number of pending rows is capped
-- (`oauth_pending_cap`, default 5000) and per client_uri host (`oauth_pending_host_cap`, default 20;
-- Nebu.OAuth.ClientStore.register/1).
--
-- The purge needs DELETE; approved/rejected rows must stay undeletable for the runtime role. The
-- migration role and the runtime role are the SAME role (nebu_app owns the table), and a table
-- owner bypasses RLS unless it is FORCEd - exactly like server_config / audit_log. The policies
-- below therefore allow SELECT of any row, INSERT of PENDING rows only (see the insert policy),
-- UPDATE of any row (narrowed by the trigger below) and DELETE ONLY for `status = 'pending'`.
ALTER TABLE oauth_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_clients FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS oauth_clients_select ON oauth_clients;
CREATE POLICY oauth_clients_select ON oauth_clients FOR SELECT USING (true);
DROP POLICY IF EXISTS oauth_clients_insert ON oauth_clients;
-- Every registration starts pending (security review F-3): the runtime role cannot INSERT a row that
-- is already decided; a decision is only ever an UPDATE of a pending row (which the admin approval
-- performs). E2E/test fixtures that need a decided row insert it pending and UPDATE it.
CREATE POLICY oauth_clients_insert ON oauth_clients FOR INSERT
    WITH CHECK (
        status = 'pending'
        AND approved_by IS NULL AND approved_at IS NULL
        AND rejected_by IS NULL AND rejected_at IS NULL
    );
DROP POLICY IF EXISTS oauth_clients_update ON oauth_clients;
CREATE POLICY oauth_clients_update ON oauth_clients FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS oauth_clients_delete_pending ON oauth_clients;
CREATE POLICY oauth_clients_delete_pending ON oauth_clients FOR DELETE USING (status = 'pending');

-- RLS decides on the CURRENT row, so without this guard a decided row could be flipped back to
-- 'pending' (UPDATE is unrestricted) and then deleted. A decision is FINAL (security review N-3):
-- once OLD.status <> 'pending' the trigger refuses every change of `status` and of the decision
-- columns (approved_by, approved_at, rejected_by, rejected_at), so a decided registration can
-- neither become pending again nor flip rejected -> approved (which would bypass the admin gate) or
-- approved -> rejected, nor be re-attributed. Still allowed on a decided row: `last_used_at`
-- (story 2) and the NULLing of created_from_ip / user_agent (data minimisation). The application
-- never needs more (re-registration of decided metadata returns the existing row unchanged).
--
-- Approval is per METADATA HASH: the admin approves exactly the metadata (redirect URIs, client
-- URI, ...) they were shown. The same trigger therefore refuses ANY change of the identity and
-- metadata columns (client_id, metadata, metadata_hash, application_type,
-- token_endpoint_auth_method, client_host) on every UPDATE, so approved metadata can never be
-- rewritten without a new registration + approval (security review F-3). The trigger function is
-- not SECURITY DEFINER and reads no other table.
CREATE OR REPLACE FUNCTION oauth_clients_guard_status() RETURNS trigger AS $$
BEGIN
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN
        RAISE EXCEPTION 'oauth_clients: a decided registration (%) cannot become pending again', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'pending'
       AND (NEW.status, NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at)
           IS DISTINCT FROM
           (OLD.status, OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at) THEN
        RAISE EXCEPTION 'oauth_clients: a decision (%) is final and cannot be changed or re-attributed', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.metadata IS DISTINCT FROM OLD.metadata
       OR NEW.metadata_hash IS DISTINCT FROM OLD.metadata_hash
       OR NEW.application_type IS DISTINCT FROM OLD.application_type
       OR NEW.token_endpoint_auth_method IS DISTINCT FROM OLD.token_endpoint_auth_method
       OR NEW.client_host IS DISTINCT FROM OLD.client_host THEN
        RAISE EXCEPTION 'oauth_clients: the identity and metadata of a registration are immutable'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS oauth_clients_guard_status ON oauth_clients;
CREATE TRIGGER oauth_clients_guard_status
    BEFORE UPDATE ON oauth_clients
    FOR EACH ROW EXECUTE FUNCTION oauth_clients_guard_status();

-- 2. server_config.oauth_enabled / oauth_issuer_url.
--
-- `oauth_enabled` (default false / absent) switches the Matrix OAuth 2.0 authorization server
-- surface on (Nebu.OAuth.Config). server_config has FORCE ROW LEVEL SECURITY: a key missing from
-- the `config_update_mutable` allowlist is writable once (INSERT, config_insert_only) but every
-- later UPDATE silently affects 0 rows (the silent-data-loss class 000013/000016/000018 document).
-- Re-create the policy with 'oauth_enabled', 'oauth_issuer_url' (the public https URL Nebu
-- advertises as OAuth issuer), 'oauth_pending_ttl_days', 'oauth_pending_cap' and 'oauth_pending_host_cap' (section 3) added. Key list and LIKE families = 000020's verbatim. Idempotent.
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
            'oauth_pending_ttl_days', 'oauth_pending_cap', 'oauth_pending_host_cap'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
