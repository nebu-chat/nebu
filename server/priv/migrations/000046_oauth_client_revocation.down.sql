-- Reverses 000046_oauth_client_revocation.up.sql: restores 000040's CHECKs, insert policy and guard function
-- and drops the revocation columns. It REFUSES while a revoked row exists: it must never turn a revoked
-- client back into an approved one (the sessions are gone; the operator decides what to do with the rows).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM oauth_clients WHERE status = 'revoked') THEN
        RAISE EXCEPTION 'oauth_clients: revoked registrations exist; refusing to downgrade (it would turn revoked into approved)';
    END IF;
END $$;

ALTER TABLE oauth_clients
    DROP CONSTRAINT IF EXISTS oauth_clients_revoked_reason_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_decision_check,
    DROP CONSTRAINT IF EXISTS oauth_clients_status_check;

DROP POLICY IF EXISTS oauth_clients_insert ON oauth_clients;
CREATE POLICY oauth_clients_insert ON oauth_clients FOR INSERT
    WITH CHECK (
        status = 'pending'
        AND approved_by IS NULL AND approved_at IS NULL
        AND rejected_by IS NULL AND rejected_at IS NULL
    );

CREATE OR REPLACE FUNCTION oauth_clients_guard_status() RETURNS trigger AS $$
BEGIN
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN
        RAISE EXCEPTION 'oauth_clients: a decided registration (%) cannot become pending again', OLD.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'pending'
       AND (NEW.status, NEW.approved_by, NEW.approved_at, NEW.rejected_by, NEW.rejected_at)
           IS DISTINCT FROM
           (OLD.status, OLD.approved_by, OLD.approved_at, OLD.rejected_by, OLD.rejected_at) THEN
        RAISE EXCEPTION 'oauth_clients: a decision (%) is final and cannot be changed or re-attributed', OLD.status
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

ALTER TABLE oauth_clients
    ADD CONSTRAINT oauth_clients_status_check
        CHECK (status IN ('pending', 'approved', 'rejected')),
    ADD CONSTRAINT oauth_clients_decision_check
        CHECK (
            (status = 'pending'
                AND approved_by IS NULL AND approved_at IS NULL
                AND rejected_by IS NULL AND rejected_at IS NULL)
            OR (status = 'approved'
                AND approved_by IS NOT NULL AND approved_at IS NOT NULL
                AND rejected_by IS NULL AND rejected_at IS NULL)
            OR (status = 'rejected'
                AND rejected_by IS NOT NULL AND rejected_at IS NOT NULL
                AND approved_by IS NULL AND approved_at IS NULL)
        );

ALTER TABLE oauth_clients
    DROP COLUMN IF EXISTS revoked_reason,
    DROP COLUMN IF EXISTS revoked_at,
    DROP COLUMN IF EXISTS revoked_by;
