-- Reverses 000040_oauth_clients_and_auth_metadata.up.sql.
-- WARNING: discards all OAuth client registrations (and thereby every approval decision).
DROP TABLE IF EXISTS oauth_clients;   -- also drops its RLS policies and the status guard trigger
DROP FUNCTION IF EXISTS oauth_clients_guard_status();

-- Restore the config_update_mutable policy to its 000020 shape (WITHOUT oauth_enabled /
-- oauth_issuer_url / oauth_pending_ttl_days / oauth_pending_cap / oauth_pending_host_cap). Any existing oauth_* server_config rows stay but become write-once again.
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
