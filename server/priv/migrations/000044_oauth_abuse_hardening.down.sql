-- Reverses 000044_oauth_abuse_hardening.up.sql: drops indexes, CHECKs and columns only.
-- WARNING: discards the per-source / registrable-domain grouping of pending registrations and of
-- live authorization / account-login requests (the caps simply stop being per source until the
-- migration is applied again). No client registration, request row or grant is removed.
DROP INDEX IF EXISTS oauth_account_login_requests_source_idx;
DROP INDEX IF EXISTS oauth_authz_requests_source_idx;
DROP INDEX IF EXISTS oauth_clients_pending_source_idx;
DROP INDEX IF EXISTS oauth_clients_pending_domain_source_idx;

ALTER TABLE oauth_account_login_requests
    DROP CONSTRAINT IF EXISTS oauth_account_login_requests_source_key_format_check;

ALTER TABLE oauth_authz_requests
    DROP CONSTRAINT IF EXISTS oauth_authz_requests_source_key_format_check;

ALTER TABLE oauth_clients
    DROP CONSTRAINT IF EXISTS oauth_clients_source_key_pending_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_source_key_format_check;

ALTER TABLE oauth_account_login_requests
    DROP COLUMN IF EXISTS source_key;

ALTER TABLE oauth_authz_requests
    DROP COLUMN IF EXISTS source_key;

ALTER TABLE oauth_clients
    DROP COLUMN IF EXISTS source_key,
    DROP COLUMN IF EXISTS client_domain;
