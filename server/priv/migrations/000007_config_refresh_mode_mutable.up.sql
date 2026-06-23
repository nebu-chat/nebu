-- e2e-session-refresh-suites: allow runtime UPDATE of the OIDC refresh-mode keys.
--
-- Story oidc-refresh-mode-config (AC5) lets an operator change matrix_oidc_refresh_mode /
-- admin_oidc_refresh_mode at runtime via /admin/config. Bootstrap (Nebu.Admin.Auth
-- complete_bootstrap) already INSERTs both keys into server_config, so a later runtime
-- change is an UPDATE — but server_config has FORCE ROW LEVEL SECURITY and the
-- config_update_mutable allowlist (migration 49 / 000002) did NOT include these two keys.
-- For the non-superuser app role (nebu_app) the UPDATE was therefore blocked, silently
-- defeating AC5 after bootstrap. This was caught by the oidc-refresh-mode browser e2e.
--
-- Re-create the policy with the two refresh-mode keys added. Idempotent (DROP IF EXISTS).
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
        'matrix_oidc_refresh_mode', 'admin_oidc_refresh_mode'
    ));
