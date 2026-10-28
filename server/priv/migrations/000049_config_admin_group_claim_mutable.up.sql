-- 000049_config_admin_group_claim_mutable.up.sql
-- Story admin-config-privileged-forms-sweep (epic oauth-broker, follow-up `cw`, ADR-033 SO10; found by its code review).
--
-- Re-creates the server_config `config_update_mutable` RLS policy (the allowlist of keys the runtime role nebu_app may UPDATE; every other
-- key is write-once) with the list of 000048 VERBATIM plus ONE key:
--
--   * admin_group_claim: a PRE-EXISTING gap, the same class as the one 000048 closed for the SSO keys. The key was in the policy of 000001
--     but not in the re-creation of 000002, so Nebu.Admin.DB.upsert_server_config/1 (INSERT ... ON CONFLICT DO UPDATE) on the EXISTING
--     row (the bootstrap wizard writes it) fails the UPDATE USING check, which PostgreSQL raises as an RLS error: every save of the
--     "Role mapping" page of the Admin UI crashed on a bootstrapped instance. The page exists to change exactly this value; since this story
--     it needs a fresh admin sign-in and is audited (`admin_group_claim_changed`).
--
-- No values are inserted. Rolling-deploy safe: old nodes only gain the ability to update the key. The statements are transaction-safe (no
-- BEGIN / COMMIT, no CONCURRENTLY). Throwaway test database: after adding or editing this migration reset it (`docker rm -f` of the throwaway
-- Postgres container) so the migration runs again.

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
            'admin_group_claim', 'admin_group_claim_path',
            'log_collect_info', 'log_retention_info_days',
            'log_collect_debug', 'log_retention_debug_days',
            'log_retention_debug_max_count',
            'log_retention_info_max_count',
            'oauth_enabled', 'oauth_issuer_url',
            'oauth_pending_ttl_days', 'oauth_pending_cap', 'oauth_pending_host_cap',
            'oauth_access_token_ttl_seconds', 'oauth_idp_revalidation',
            'sso_extra_redirect_schemes', 'sso_redirect_allowed_origins'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
