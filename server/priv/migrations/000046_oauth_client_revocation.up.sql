-- 000046_oauth_client_revocation.up.sql
-- Story oauth-client-revocation (epic oauth-broker, ADR-033 "Client revocation and same-origin hardening").
--
-- CR1 (status `revoked`): an APPROVED client can be withdrawn. `oauth_clients` gains
--   revoked_by / revoked_at / revoked_reason (all NULL-able). The status CHECK admits `revoked`; the
--   decision CHECK is re-created: pending = every decision column NULL (incl. revoked_*), approved =
--   approved_* set and rejected_* / revoked_* NULL, rejected = the 000040 shape and revoked_* NULL, revoked =
--   approved_* set (the row WAS approved: attribution is kept), revoked_by / revoked_at set, rejected_* NULL.
--   `oauth_clients_revoked_reason_check`: a reason exists only on a revoked row, at most 500 characters.
--
-- CR2 (guard trigger): approved -> revoked is the ONLY new transition. oauth_clients_guard_status() keeps
--   every 000040 rule and additionally allows exactly OLD.status = 'approved' AND NEW.status = 'revoked'
--   with approved_* / rejected_* unchanged, OLD.revoked_* NULL and NEW.revoked_by / revoked_at set. Everything
--   else on a decided row stays check_violation: revoked -> any status, re-attribution or edit of revoked_*,
--   approved -> rejected, and pending -> revoked / rejected -> revoked (a registration can never skip the
--   admin approval: the generic CHECK alone would accept a revoked-shaped row). Identity / metadata
--   immutability is unchanged. Still not SECURITY DEFINER, reads no other table.
--
-- CR3 (RLS unchanged, FORCEd): the DELETE policy stays `status = 'pending'` (a revoked row is never deleted:
--   it keeps its metadata hash occupied, so identical metadata can never be re-registered as pending). The
--   INSERT policy is re-created with revoked_by / revoked_at IS NULL. config_update_mutable is NOT touched
--   (other migrations re-create it; doing it here could drop their keys).
--
-- Idempotent (IF NOT EXISTS / DROP ... IF EXISTS), no explicit transaction (the runner wraps the file).
ALTER TABLE oauth_clients
    ADD COLUMN IF NOT EXISTS revoked_by     TEXT,
    ADD COLUMN IF NOT EXISTS revoked_at     TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS revoked_reason TEXT;

ALTER TABLE oauth_clients
    DROP CONSTRAINT IF EXISTS oauth_clients_status_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_decision_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_revoked_reason_check;

ALTER TABLE oauth_clients
    ADD CONSTRAINT oauth_clients_status_check
        CHECK (status IN ('pending', 'approved', 'rejected', 'revoked')),
    ADD CONSTRAINT oauth_clients_decision_check
        CHECK (
            (status = 'pending'
                AND approved_by IS NULL AND approved_at IS NULL
                AND rejected_by IS NULL AND rejected_at IS NULL
                AND revoked_by IS NULL AND revoked_at IS NULL)
            OR (status = 'approved'
                AND approved_by IS NOT NULL AND approved_at IS NOT NULL
                AND rejected_by IS NULL AND rejected_at IS NULL
                AND revoked_by IS NULL AND revoked_at IS NULL)
            OR (status = 'rejected'
                AND rejected_by IS NOT NULL AND rejected_at IS NOT NULL
                AND approved_by IS NULL AND approved_at IS NULL
                AND revoked_by IS NULL AND revoked_at IS NULL)
            OR (status = 'revoked'
                AND approved_by IS NOT NULL AND approved_at IS NOT NULL
                AND revoked_by IS NOT NULL AND revoked_at IS NOT NULL
                AND rejected_by IS NULL AND rejected_at IS NULL)
        ),
    ADD CONSTRAINT oauth_clients_revoked_reason_check
        CHECK (revoked_reason IS NULL OR (status = 'revoked' AND char_length(revoked_reason) <= 500));

-- The runtime role still cannot INSERT a decided row: revoked_* must be NULL as well.
DROP POLICY IF EXISTS oauth_clients_insert ON oauth_clients;
CREATE POLICY oauth_clients_insert ON oauth_clients FOR INSERT
    WITH CHECK (
        status = 'pending'
        AND approved_by IS NULL AND approved_at IS NULL
        AND rejected_by IS NULL AND rejected_at IS NULL
        AND revoked_by IS NULL AND revoked_at IS NULL
    );

-- The trigger itself (000040) stays; only its function is replaced.
CREATE OR REPLACE FUNCTION oauth_clients_guard_status() RETURNS trigger AS $$
BEGIN
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN
        RAISE EXCEPTION 'oauth_clients: a decided registration (%) cannot become pending again', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'revoked' AND OLD.status NOT IN ('approved', 'revoked') THEN
        RAISE EXCEPTION 'oauth_clients: only an approved registration can be revoked (was %)', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status = 'approved' AND NEW.status = 'revoked' THEN
        IF (NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at)
               IS DISTINCT FROM (OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at)
           OR OLD.revoked_by IS NOT NULL OR OLD.revoked_at IS NOT NULL OR OLD.revoked_reason IS NOT NULL
           OR NEW.revoked_by IS NULL OR NEW.revoked_at IS NULL THEN
            RAISE EXCEPTION 'oauth_clients: revoking requires revoked_by and revoked_at and must not touch the approval'
                USING ERRCODE = 'check_violation';
        END IF;
    ELSIF OLD.status <> 'pending'
       AND (NEW.status, NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at,
            NEW.revoked_by, NEW.revoked_at, NEW.revoked_reason)
           IS DISTINCT FROM
           (OLD.status, OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at,
            OLD.revoked_by, OLD.revoked_at, OLD.revoked_reason) THEN
        RAISE EXCEPTION 'oauth_clients: a decision (%) is final; only approved -> revoked is allowed', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.metadata IS DISTINCT FROM OLD.metadata
       OR NEW.metadata_hash IS DISTINCT FROM OLD.metadata_hash
       OR NEW.application_type IS DISTINCT FROM OLD.application_type
       OR NEW.token_endpoint_auth_method IS DISTINCT FROM OLD.token_endpoint_auth_method
       OR NEW.client_host IS DISTINCT FROM OLD.client_host THEN
        RAISE EXCEPTION 'oauth_clients: the identity and metadata of a registration are immutable'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
