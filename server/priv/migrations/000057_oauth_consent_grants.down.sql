-- Reverses 000057_oauth_consent_grants.up.sql.
-- WARNING: discards every remembered consent grant (the users are asked for consent again on their next login) and the force_consent flag of the
-- authorization requests in flight (a request with prompt=consent that is still waiting for the IdP callback is then treated like any other).
-- login requests that return to the apps page are short-lived (10 minutes): they go BEFORE the CHECK of 000043 is restored
DELETE FROM oauth_account_login_requests WHERE return_action = 'apps';
ALTER TABLE oauth_account_login_requests DROP CONSTRAINT IF EXISTS oauth_account_login_requests_action_check;
ALTER TABLE oauth_account_login_requests
    ADD CONSTRAINT oauth_account_login_requests_action_check
        CHECK (return_action IS NULL OR return_action IN (
            'org.matrix.profile', 'org.matrix.devices_list', 'org.matrix.device_view',
            'org.matrix.device_delete', 'org.matrix.cross_signing_reset'));
ALTER TABLE oauth_authz_requests DROP COLUMN IF EXISTS force_consent;
DROP TABLE IF EXISTS oauth_consent_grants;   -- also drops its policies and index
