-- Reverses 000045_oauth_consent_and_refresh_leases.up.sql.
-- WARNING: discards every pending consent request (the user starts signing in again), every IdP refresh
-- lease, and every account-page browser session whose auth_time is NULL (the users simply sign in
-- again), so that NOT NULL can be restored.
ALTER TABLE oauth_codes
    DROP COLUMN IF EXISTS device_holder_client_id,
    DROP COLUMN IF EXISTS device_holder_checked;
DROP TABLE IF EXISTS oauth_idp_refresh_leases;   -- also drops its policies
DROP TABLE IF EXISTS oauth_consent_requests;     -- also drops its policies and index
DELETE FROM oauth_account_sessions WHERE auth_time IS NULL;
ALTER TABLE oauth_account_sessions ALTER COLUMN auth_time SET NOT NULL;
