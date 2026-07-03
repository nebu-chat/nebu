-- scope-admin-claim-to-path: allow runtime UPDATE of admin_group_claim_path.
--
-- Story scope-admin-claim-to-path (epic oidc-simplification) closes the accepted-risk
-- any-key claim-value scan (Kassandra MEDIUM, bugfix-unify-admin-matrix-oidc-identity +
-- bugfix-nested-oidc-claim-support, both 2026-07-01): the admin-group-claim gate
-- (Nebu.Admin.Auth.admin_claim?/1) is made PATH-scoped instead of scanning every claim
-- value in the tree regardless of key. The Bootstrap Wizard's claim-picker already shows
-- the operator the dot-path of each discovered claim (`realm_access.roles`, `groups`,
-- ...) -- this migration adds the server_config key that persists WHICH path was picked,
-- alongside the existing `admin_group_claim` value.
--
-- No schema change (key-value store, ADR-018). `admin_group_claim_path` is written by
-- Nebu.Admin.Auth.complete_bootstrap/3 at bootstrap-completion time (an INSERT, per
-- do_complete_bootstrap/3's ON CONFLICT upsert) -- this migration only needs to widen the
-- config_update_mutable RLS UPDATE policy so a later runtime change (re-bootstrap-style
-- config edit) is also possible, mirroring 000013_config_oidc_scopes_mutable's pattern.
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
        'admin_group_claim_path'
    ));
