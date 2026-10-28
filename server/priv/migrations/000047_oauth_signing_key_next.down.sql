-- Reverses 000047_oauth_signing_key_next.up.sql: restores 000042's CHECKs, insert policy and guard function and
-- drops the `next` index. WARNING: a published `next` key is DISCARDED (a half-finished rotation is lost; the
-- active and retired keys are untouched). FORCE ROW LEVEL SECURITY binds the table owner and there is no DELETE
-- policy, so the DELETE runs between NO FORCE / FORCE (the table owner bypasses RLS while it is off); FORCE is
-- restored afterwards.
ALTER TABLE oauth_signing_keys NO FORCE ROW LEVEL SECURITY;
DELETE FROM oauth_signing_keys WHERE status = 'next';
ALTER TABLE oauth_signing_keys FORCE ROW LEVEL SECURITY;

DROP INDEX IF EXISTS oauth_signing_keys_one_next;

ALTER TABLE oauth_signing_keys
    DROP CONSTRAINT IF EXISTS oauth_signing_keys_status_check,
    DROP CONSTRAINT IF EXISTS oauth_signing_keys_retired_check;

ALTER TABLE oauth_signing_keys
    ADD CONSTRAINT oauth_signing_keys_status_check
        CHECK (status IN ('active', 'retired')),
    ADD CONSTRAINT oauth_signing_keys_retired_check
        CHECK ((status = 'active' AND retired_at IS NULL) OR (status = 'retired' AND retired_at IS NOT NULL));

DROP POLICY IF EXISTS oauth_signing_keys_insert ON oauth_signing_keys;
CREATE POLICY oauth_signing_keys_insert ON oauth_signing_keys FOR INSERT
    WITH CHECK (status = 'active' AND retired_at IS NULL AND not_after IS NULL);

CREATE OR REPLACE FUNCTION oauth_signing_keys_guard() RETURNS trigger AS $$
BEGIN
    IF NEW.kid IS DISTINCT FROM OLD.kid
       OR NEW.alg IS DISTINCT FROM OLD.alg
       OR NEW.public_jwk IS DISTINCT FROM OLD.public_jwk
       OR NEW.private_jwk_enc IS DISTINCT FROM OLD.private_jwk_enc
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'oauth_signing_keys: key material is immutable'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'retired' AND NEW.status = 'active' THEN
        RAISE EXCEPTION 'oauth_signing_keys: a retired key cannot become active again'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'active' AND NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
        RAISE EXCEPTION 'oauth_signing_keys: retiring a key requires retired_at'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.not_after IS NOT NULL AND (NEW.not_after IS NULL OR NEW.not_after < OLD.not_after) THEN
        RAISE EXCEPTION 'oauth_signing_keys: not_after may only be set or raised'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
