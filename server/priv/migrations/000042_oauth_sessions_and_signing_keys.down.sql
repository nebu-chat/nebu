-- Reverses 000042_oauth_sessions_and_signing_keys.up.sql.
-- WARNING: discards every OAuth session (auth_api = 'oauth' rows cannot exist without the columns)
-- and every id_token signing key (clients holding an id_token are unaffected; new keys are generated
-- lazily after a re-apply). oauth_clients rows are never touched.

-- server_config allowlist: restore 000040's policy verbatim.
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

DROP TABLE IF EXISTS oauth_signing_keys;   -- also drops its policies, index and the guard trigger
DROP FUNCTION IF EXISTS oauth_signing_keys_guard();

DELETE FROM matrix_sessions WHERE auth_api = 'oauth';

DROP INDEX IF EXISTS idx_matrix_sessions_client_id;
DROP INDEX IF EXISTS idx_matrix_sessions_oauth_code_hash;
DROP INDEX IF EXISTS idx_matrix_sessions_user_device;

ALTER TABLE matrix_sessions DROP CONSTRAINT IF EXISTS matrix_sessions_oauth_shape_check;
ALTER TABLE matrix_sessions DROP CONSTRAINT IF EXISTS matrix_sessions_auth_api_check;

ALTER TABLE matrix_sessions
    DROP COLUMN IF EXISTS oauth_code_hash,
    DROP COLUMN IF EXISTS session_expires_at,
    DROP COLUMN IF EXISTS scope,
    DROP COLUMN IF EXISTS client_id,
    DROP COLUMN IF EXISTS auth_api;
