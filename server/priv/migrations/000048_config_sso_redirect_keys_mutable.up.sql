-- 000048_config_sso_redirect_keys_mutable.up.sql
-- Story legacy-sso-redirect-confirmation (epic oauth-broker, epic SEC gate 3 finding G3-3, ADR-033).
--
-- Re-creates the server_config `config_update_mutable` RLS policy (the allowlist of keys the runtime
-- role nebu_app may UPDATE; every other key is write-once) with the list of 000042 VERBATIM (000042 is
-- the latest re-creation: it added oauth_access_token_ttl_seconds / oauth_idp_revalidation, which must
-- not be dropped, a dropped key silently turns its UPDATEs into no-ops) plus two keys:
--
--   * sso_extra_redirect_schemes: a PRE-EXISTING gap. The key was never added to the policy, so
--     Nebu.Admin.DB.upsert_server_config/1 (INSERT ... ON CONFLICT DO UPDATE) on the EXISTING row fails
--     the UPDATE USING check, which PostgreSQL raises as an RLS error for ON CONFLICT DO UPDATE: the
--     SECOND save of the "SSO redirect schemes" form of the Admin UI crashed.
--   * sso_redirect_allowed_origins: the operator list of https origins whose legacy SSO logins skip the
--     confirmation page (new in this story, saved through the same upsert, so it must be updatable).
--
-- No values are inserted: absent keys mean "no extra schemes" / "no listed origins". Rolling-deploy safe:
-- old nodes never write the new key and only gain the ability to update the other one; nothing else is
-- touched. The statements are transaction-safe (no BEGIN / COMMIT, no CONCURRENTLY).
-- Throwaway test database: after adding or editing this migration reset it (`docker rm -f` of the
-- throwaway Postgres container) so the migration runs again.

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
            'oauth_pending_ttl_days', 'oauth_pending_cap', 'oauth_pending_host_cap',
            'oauth_access_token_ttl_seconds', 'oauth_idp_revalidation',
            'sso_extra_redirect_schemes', 'sso_redirect_allowed_origins'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
