-- 000061_cross_signing_user_signatures.down.sql
-- Reverses 000061_cross_signing_user_signatures.up.sql.
-- WARNING: dropping the table DISCARDS every cross-user signature (users have to verify each other again). Story key-query-hardening (the reader and writer
-- of the table) must be reverted first.

DROP TABLE IF EXISTS cross_signing_user_signatures;
