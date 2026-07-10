-- Reverses 000017_operational_logs.up.sql.
-- WARNING: dropping operational_logs discards all captured diagnostic log
-- history (mutable/pruneable by design — unlike audit_log, this is NOT a
-- compliance record, so this loss has no legal-hold implication).

-- Restore config_update_mutable to the migration-000016 allowlist (without
-- the 5 log-policy keys this story added).
DROP POLICY IF EXISTS config_update_mutable ON server_config;
CREATE POLICY config_update_mutable ON server_config
    FOR UPDATE
    USING (key IN (
        'max_users', 'registration_enabled', 'default_room_visibility',
        'default_max_members', 'bootstrap_completed',
        'oidc_user_id_claim', 'oidc_displayname_claim', 'oidc_email_claim',
        'oidc_directory_enabled', 'oidc_directory_endpoint',
        'gdpr_retention_days', 'signing_key_id', 'compliance_mode_enabled',
        'scim_token_hash',
        'matrix_oidc_refresh_mode', 'admin_oidc_refresh_mode',
        'matrix_oidc_extra_scopes', 'admin_oidc_extra_scopes',
        'admin_group_claim_path'
    ));

DROP TABLE IF EXISTS operational_logs;
