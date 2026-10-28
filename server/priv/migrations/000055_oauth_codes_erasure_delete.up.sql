-- 000055_oauth_codes_erasure_delete.up.sql
-- Story gdpr-erasure-global-data (follow-up `ck`, D2 / D11): the GDPR erasure must be able to DELETE the authorization codes of the erased user
-- (a pending code carries `idp_rt_enc`, an IdP refresh token ciphertext). 000041 lets the runtime role delete only codes that expired
-- more than 24 hours ago (reuse detection). The policy oauth_codes_delete gains a second branch: rows of a user whose erasure is under way or done
-- (users.deletion_status IS NOT NULL; the erasure sets 'deletion_in_progress' in the same transaction BEFORE it deletes). The code of an
-- ACTIVE user stays undeletable until 24 hours after its expiry. Policy only: no table, column, index, trigger or grant changes, no data.
DROP POLICY IF EXISTS oauth_codes_delete ON oauth_codes;
CREATE POLICY oauth_codes_delete ON oauth_codes FOR DELETE USING (
    expires_at < now() - interval '24 hours'
    OR EXISTS (SELECT 1 FROM users u WHERE u.user_id = oauth_codes.user_id AND u.deletion_status IS NOT NULL)
);
