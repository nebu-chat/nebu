-- 000056_config_session_lifetime_mutable.up.sql
-- Story session-lifetime-setting (epic oauth-session-and-consent).
--
-- Re-creates the server_config `config_update_mutable` RLS policy (the allowlist of keys the runtime role nebu_app may UPDATE; every other
-- key is write-once) with the list of 000049 VERBATIM plus ONE key:
--
--   * matrix_session_ttl_seconds: the Admin-configurable lifetime of a signed-in Matrix session (whole seconds, 3600 .. 7776000). Saved through
--     Nebu.Admin.DB.upsert / save_config_audited (INSERT ... ON CONFLICT DO UPDATE): the FIRST save inserts the row, the SECOND save updates the
--     EXISTING row, which fails the UPDATE USING check and PostgreSQL raises it as an RLS (row-level security) error unless the key is listed.
--
-- No values are inserted: an absent row means "the env value NEBU_MATRIX_SESSION_TTL_SECONDS, else 8 hours". Rolling-deploy safe: old nodes only
-- gain the ability to update the key and never read it. The statements are transaction-safe (no BEGIN / COMMIT, no CONCURRENTLY).
-- Throwaway test database: after adding or editing this migration reset it (`docker rm -f` of the throwaway Postgres container) so the
-- migration runs again.

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
            'sso_extra_redirect_schemes', 'sso_redirect_allowed_origins',
            'matrix_session_ttl_seconds'
        )
        OR key LIKE 'log\_min\_level\_%'
        OR key LIKE 'log\_retention\_days\_%'
    );
