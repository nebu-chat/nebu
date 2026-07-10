-- enhanced-logging/trace-map-node-controls (AC5/AC6, ANSWERED design
-- question 1): DB-backed temporary-capture timer for long-polling
-- endpoints. "State is a row, expiry is a comparison against now()" — no
-- process timer owns correctness (cluster-safe, survives node restarts;
-- the war_room_sessions precedent from 000019).
--
-- endpoint is the PRIMARY KEY: at most one active capture per endpoint
-- (story Dev Notes schema). Re-enabling upserts the same row with a fresh
-- expires_at. Expired rows are semantically OFF the moment now() passes
-- expires_at — the periodic cleanup (Nebu.Web.LogStore.CaptureCache /
-- Nebu.Admin.TemporaryCaptureManager.cleanup_expired/0) is hygiene only,
-- never load-bearing for correctness.
CREATE TABLE IF NOT EXISTS admin_temporary_captures (
    endpoint    TEXT PRIMARY KEY,
    enabled_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL,
    started_by  TEXT NOT NULL
);

-- AC1/AC2: the inspector's per-endpoint logging config writes DYNAMIC
-- server_config keys (log_min_level_<route> / log_retention_days_<route>,
-- one pair per observed endpoint) via upsert_server_config/1. The
-- config_update_mutable RLS allowlist (000002, last extended by 000018) is
-- key-enumerated — a brand-new key's FIRST upsert always succeeds as an
-- INSERT (config_insert_only), but any LATER upsert is an UPDATE that
-- silently affects 0 rows unless the key is allowed here (the exact
-- silent-data-loss class 000018 documents). Dynamic per-route keys cannot
-- be enumerated, so the two key FAMILIES are allowed via LIKE patterns
-- (backslash-escaped '_' so the SQL wildcard does not over-match).
--
-- Re-create the policy with the two patterns added. Idempotent (DROP IF
-- EXISTS). Key list = 000018's verbatim.
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
            'log_retention_info_max_count'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
