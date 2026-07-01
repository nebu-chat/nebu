-- 000010_cross_signing_keys.down.sql
-- Reverses 000010_cross_signing_keys.up.sql.
-- WARNING: dropping this table discards the cross-signing key directory — after a
-- down+up cycle, clients must re-publish their cross-signing keys (clients do this
-- on the next cross-signing bootstrap), and peers' /keys/query cross-signing maps
-- are empty until then.

DROP TABLE IF EXISTS cross_signing_keys;
