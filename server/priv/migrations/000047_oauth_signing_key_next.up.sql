-- 000047_oauth_signing_key_next (story oauth-hardening-hygiene, HY11): a pre-published `next` id_token signing key.
-- Two-phase rotation (Nebu.Release.rotate_oauth_signing_key/0): a new key is first published as `next` (it appears
-- in the JWKS but never signs), and may become `active` only after 900 seconds (JWKS max-age 600 s + id_token
-- lifetime 300 s), so every client that cached the JWKS before the switch already knows the new public key. The
-- 900 s rule is enforced HERE by the guard trigger, not by the application. Extends 000042 (never edited).
-- Idempotent: DROP ... IF EXISTS / CREATE OR REPLACE. FORCE RLS stays on, no DELETE policy, no new grants.

ALTER TABLE oauth_signing_keys
    DROP CONSTRAINT IF EXISTS oauth_signing_keys_status_check,
    DROP CONSTRAINT IF EXISTS oauth_signing_keys_retired_check;

ALTER TABLE oauth_signing_keys
    ADD CONSTRAINT oauth_signing_keys_status_check
        CHECK (status IN ('active', 'next', 'retired')),
    ADD CONSTRAINT oauth_signing_keys_retired_check
        CHECK ((status IN ('active', 'next') AND retired_at IS NULL)
            OR (status = 'retired' AND retired_at IS NOT NULL));

-- At most ONE next key (a second publish while one is pending is a unique violation).
CREATE UNIQUE INDEX IF NOT EXISTS oauth_signing_keys_one_next ON oauth_signing_keys (status)
    WHERE status = 'next';

DROP POLICY IF EXISTS oauth_signing_keys_insert ON oauth_signing_keys;
-- Fresh ACTIVE or NEXT keys can be inserted (a retired key is always the result of an UPDATE).
CREATE POLICY oauth_signing_keys_insert ON oauth_signing_keys FOR INSERT
    WITH CHECK (status IN ('active', 'next') AND retired_at IS NULL AND not_after IS NULL);

-- Every 000042 rule stays (immutable key material, retired never active again, retiring requires retired_at,
-- not_after only set or raised) plus: active -> next and retired -> next are forbidden; next -> active only
-- when the row is at least 900 seconds old; next -> retired requires retired_at.
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
    IF OLD.status = 'retired' AND NEW.status = 'next' THEN
        RAISE EXCEPTION 'oauth_signing_keys: a retired key cannot become next'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'active' AND NEW.status = 'next' THEN
        RAISE EXCEPTION 'oauth_signing_keys: an active key cannot become next'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'next' AND NEW.status = 'active'
       AND NOT (OLD.created_at <= now() - interval '900 seconds') THEN
        RAISE EXCEPTION 'oauth_signing_keys: a next key may only become active 900 seconds after it was published'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'active' AND NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
        RAISE EXCEPTION 'oauth_signing_keys: retiring a key requires retired_at'
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'next' AND NEW.status = 'retired' AND NEW.retired_at IS NULL THEN
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

DROP TRIGGER IF EXISTS oauth_signing_keys_guard ON oauth_signing_keys;
CREATE TRIGGER oauth_signing_keys_guard
    BEFORE UPDATE ON oauth_signing_keys
    FOR EACH ROW EXECUTE FUNCTION oauth_signing_keys_guard();
