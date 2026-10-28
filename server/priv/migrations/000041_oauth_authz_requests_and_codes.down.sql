-- Reverses 000041_oauth_authz_requests_and_codes.up.sql.
-- WARNING: discards every pending authorization request and every (unredeemed) authorization code;
-- in-flight logins have to be started again from the client.
DROP TABLE IF EXISTS oauth_codes;            -- also drops its policies and the guard trigger
DROP TABLE IF EXISTS oauth_authz_requests;   -- also drops its policies
DROP FUNCTION IF EXISTS oauth_codes_guard();
