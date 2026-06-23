-- 000003_compliance_rls_hardening.down.sql
-- Restore the original permissive UPDATE policies so that migrate down leaves
-- the schema in the same valid, operable state as after migration 000002.

DROP POLICY IF EXISTS compliance_requests_update ON compliance_requests;
CREATE POLICY compliance_requests_update
    ON compliance_requests
    FOR UPDATE
    USING (true);

DROP POLICY IF EXISTS compliance_sessions_update ON compliance_sessions;
CREATE POLICY compliance_sessions_update
    ON compliance_sessions
    FOR UPDATE
    USING (true);
