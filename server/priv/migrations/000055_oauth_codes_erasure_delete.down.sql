-- 000055_oauth_codes_erasure_delete.down.sql: back to the 000041 policy (a code is deletable 24 hours after its expiry only).
DROP POLICY IF EXISTS oauth_codes_delete ON oauth_codes;
CREATE POLICY oauth_codes_delete ON oauth_codes FOR DELETE USING (expires_at < now() - interval '24 hours');
