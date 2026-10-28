-- Reverses 000043_oauth_account_management.up.sql.
-- WARNING: discards every pending account-page login request and every account-page browser session
-- (users simply sign in again). uia_sessions rows are never touched.
DROP INDEX IF EXISTS uia_sessions_user_op_pending_idx;
DROP TABLE IF EXISTS oauth_account_sessions;        -- also drops its policies and indexes
DROP TABLE IF EXISTS oauth_account_login_requests;  -- also drops its policies and indexes
