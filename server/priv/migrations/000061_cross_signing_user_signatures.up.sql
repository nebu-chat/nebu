-- 000061_cross_signing_user_signatures.up.sql
-- Story key-query-hardening (epic e2ee-client-support, REQ-2026-014): the CROSS-USER signatures of Matrix cross-signing (Matrix CS v1.18 "Cross-signing"):
-- the signature that user V (the signer) makes with its user-signing key over the master key of ANOTHER user X (the target). Public signature material only:
-- no private key, no key material beyond the signature itself (ADR-011 stays: this enables no E2EE room). No federation.
--
-- Such a signature is stored APART from the key object (the master key of X is served with the signatures of X's own keys plus the signatures made by the
-- VIEWER, never a signature by a third user): one row per (signer, target user, target key id), replaced idempotently, so the table is bounded by
-- signers x the users they share a room with.
--
-- user_id is the SIGNER and the DELETE key of the GDPR erasure (UserDeletion.erased_tables/0); target_user_id is the second erasure key (the signatures made
-- ON the keys of an erased user are deleted by one more statement). The name contains `signature` on purpose: the acceptance test of the erasure scans every
-- table of that name. There is no foreign key (a row may outlive neither user, the erasure deletes both directions); target_key_id is the id of the target
-- master key and target_key its public key value (nothing enforces id == public key, so a replacement keeping the id must not keep the signature): the reader
-- only shows a row whose (id, key) is still a key of the CURRENT master key of the target (a replaced master key drops its rows, see
-- CrossSigningKeyStore.put_keys/2).
--
-- UpCloud managed PostgreSQL has no ALTER DEFAULT PRIVILEGES for the migrate role, so the runtime role gets its grants here. Row level security is ENABLEd and
-- FORCEd with a policy for each command (the shape of 000060). Only a new table: rolling-deploy safe (old nodes ignore it).
CREATE TABLE IF NOT EXISTS cross_signing_user_signatures (
    user_id        TEXT   NOT NULL,
    target_user_id TEXT   NOT NULL,
    target_key_id  TEXT   NOT NULL,
    target_key     TEXT   NOT NULL,
    signing_key_id TEXT   NOT NULL,
    signature      TEXT   NOT NULL,
    updated_at     BIGINT NOT NULL,
    PRIMARY KEY (user_id, target_user_id, target_key_id)
);

CREATE INDEX IF NOT EXISTS cross_signing_user_signatures_target_idx ON cross_signing_user_signatures (target_user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON cross_signing_user_signatures TO nebu_app;

ALTER TABLE cross_signing_user_signatures ENABLE ROW LEVEL SECURITY;
ALTER TABLE cross_signing_user_signatures FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cross_signing_user_signatures_select ON cross_signing_user_signatures;
CREATE POLICY cross_signing_user_signatures_select ON cross_signing_user_signatures FOR SELECT USING (true);
DROP POLICY IF EXISTS cross_signing_user_signatures_insert ON cross_signing_user_signatures;
CREATE POLICY cross_signing_user_signatures_insert ON cross_signing_user_signatures FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS cross_signing_user_signatures_update ON cross_signing_user_signatures;
CREATE POLICY cross_signing_user_signatures_update ON cross_signing_user_signatures FOR UPDATE USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS cross_signing_user_signatures_delete ON cross_signing_user_signatures;
CREATE POLICY cross_signing_user_signatures_delete ON cross_signing_user_signatures FOR DELETE USING (true);
