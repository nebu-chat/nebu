-- Revert config_update_mutable to the migration-49 allowlist (without the OIDC
-- refresh-mode keys). After this, runtime UPDATE of matrix_oidc_refresh_mode /
-- admin_oidc_refresh_mode is blocked again for the app role.
DROP POLICY IF EXISTS config_update_mutable ON server_config;
CREATE POLICY config_update_mutable ON server_config
    FOR UPDATE
    USING (key IN (
        'max_users', 'registration_enabled', 'default_room_visibility',
        'default_max_members', 'bootstrap_completed',
        'oidc_user_id_claim', 'oidc_displayname_claim', 'oidc_email_claim',
        'oidc_directory_enabled', 'oidc_directory_endpoint',
        'gdpr_retention_days', 'signing_key_id', 'compliance_mode_enabled',
        'scim_token_hash'
    ));
