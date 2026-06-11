-- 000003_compliance_rls_hardening.up.sql
-- Restrict UPDATE policies on compliance_requests and compliance_sessions so that
-- a compromised nebu_app role cannot silently alter approved/rejected records or
-- re-open revoked access windows.
--
-- USING clause controls which existing rows the operation applies to.
-- DROP … IF EXISTS guards make the migration idempotent.

-- ─── compliance_requests ─────────────────────────────────────────────────────
-- Allow UPDATE only when the row is still in the 'pending' state.
-- Approved and rejected rows become immutable.
DROP POLICY IF EXISTS compliance_requests_update ON compliance_requests;
CREATE POLICY compliance_requests_update
    ON compliance_requests
    FOR UPDATE
    USING (status = 'pending')
    WITH CHECK (true);

-- ─── compliance_sessions ─────────────────────────────────────────────────────
-- Allow UPDATE only when the session has not yet been revoked (revoked_at IS NULL).
-- Once revoked, the session record is immutable.
DROP POLICY IF EXISTS compliance_sessions_update ON compliance_sessions;
CREATE POLICY compliance_sessions_update
    ON compliance_sessions
    FOR UPDATE
    USING (revoked_at IS NULL)
    WITH CHECK (true);
