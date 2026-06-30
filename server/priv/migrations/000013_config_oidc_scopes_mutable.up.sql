-- configurable-oidc-scopes: allow runtime UPDATE of the OIDC scope keys.
--
-- Story configurable-oidc-scopes lets an operator change matrix_oidc_extra_scopes /
-- admin_oidc_extra_scopes at runtime via /admin/config. Bootstrap
-- (Nebu.Admin.Auth complete_bootstrap) already INSERTs both keys into server_config,
-- so a later runtime change is an UPDATE. server_config has FORCE ROW LEVEL SECURITY
-- and the config_update_mutable allowlist did NOT include these two keys.
--
-- Re-create the policy with the two scope keys added. Idempotent (DROP IF EXISTS).
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
        'matrix_oidc_extra_scopes', 'admin_oidc_extra_scopes'
    ));
