-- enhanced-logging/admin-logs-retention-settings: adds the new
-- log_retention_info_max_count server_config key (AC8/AC9 — INFO gains a
-- "max entries" retention dimension, symmetric with the existing
-- log_retention_debug_max_count) to the config_update_mutable RLS allowlist.
--
-- See 000017_operational_logs.up.sql for the precedent this extends (it added
-- the OTHER 5 log-policy keys). Without this migration, a SECOND upsert (an
-- UPDATE) of log_retention_info_max_count silently affects 0 rows — the
-- FIRST upsert of any brand-new key always succeeds unconditionally as an
-- INSERT via the pre-existing config_insert_only policy, regardless of this
-- allowlist, which is why a single-upsert test would not catch this gap.
--
-- Re-create the policy with the new key added. Idempotent (DROP IF EXISTS).
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
        'admin_group_claim_path',
        'log_collect_info', 'log_retention_info_days',
        'log_collect_debug', 'log_retention_debug_days',
        'log_retention_debug_max_count',
        'log_retention_info_max_count'
    ));
