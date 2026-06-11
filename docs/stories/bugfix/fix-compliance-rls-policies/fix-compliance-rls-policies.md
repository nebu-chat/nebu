---
status: ready-for-dev
security_review: required
parent_story: bugfix/fix-room-management-error/fix-room-management-error.md
origin: code-review finding m3 (cycle 0, 2026-06-10)
---

# Story: Fix Compliance RLS UPDATE Policies

## Story

As an operator, I need the `compliance_requests` and `compliance_sessions` tables to enforce
immutability on rows once they leave the `pending` / active state, so that a compromised or
misconfigured `nebu_app` role cannot silently alter compliance approval records or reopen
revoked access windows.

## Background

Migration `000002_add_missing_structures.up.sql` creates `compliance_requests` and
`compliance_sessions` with unconditionally permissive `UPDATE` policies (`USING (true)`).
This was a code-review MINOR finding (m3) deferred from `bugfix/fix-room-management-error`.

The compliance feature epic has not yet started; this story hardens the schema before any
application logic builds on top of it.

## Acceptance Criteria

**AC1 — `compliance_requests` UPDATE is restricted to pending rows:**
A `nebu_app` session can UPDATE a `compliance_requests` row only when `status = 'pending'`.
Attempting to UPDATE an `approved` or `rejected` row is rejected by RLS (0 rows affected or
policy violation).

**AC2 — `compliance_sessions` UPDATE is restricted to active (non-revoked) rows:**
A `nebu_app` session can UPDATE a `compliance_sessions` row only when `revoked_at IS NULL`.
Attempting to UPDATE a row where `revoked_at IS NOT NULL` is rejected by RLS.

**AC3 — Migration is idempotent:**
Applying the migration a second time (via `IF NOT EXISTS` / `DROP … IF EXISTS` guards) does
not error.

**AC4 — Existing INSERT and SELECT behaviour is unchanged:**
INSERT and SELECT policies remain `WITH CHECK (true)` / `USING (true)` — only UPDATE is
restricted.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. `TestMigration_ComplianceRequestsUpdatePolicy` — Go integration (`migrations_003_integration_test.go`)
   - Given: a `compliance_requests` row with `status = 'pending'`
   - When: UPDATE `status = 'approved'` via `nebu_app` role
   - Then: succeeds (1 row affected)

2. `TestMigration_ComplianceRequestsUpdatePolicyBlocked` — Go integration
   - Given: a `compliance_requests` row with `status = 'approved'`
   - When: UPDATE `justification = 'tampered'` via `nebu_app` role
   - Then: 0 rows affected (RLS blocks)

3. `TestMigration_ComplianceSessionsUpdatePolicy` — Go integration
   - Given: a `compliance_sessions` row with `revoked_at IS NULL`
   - When: UPDATE `revoked_at = NOW()` via `nebu_app` role
   - Then: succeeds (1 row affected)

4. `TestMigration_ComplianceSessionsUpdatePolicyBlocked` — Go integration
   - Given: a `compliance_sessions` row with `revoked_at IS NOT NULL`
   - When: UPDATE `revoked_at = NULL` via `nebu_app` role
   - Then: 0 rows affected (RLS blocks)

## Tasks / Subtasks

- [ ] Write failing integration tests (AC1–AC4)
- [ ] Create `gateway/migrations/000003_compliance_rls_hardening.up.sql`
  - [ ] `DROP POLICY IF EXISTS compliance_requests_update ON compliance_requests`
  - [ ] `CREATE POLICY compliance_requests_update … USING (status = 'pending')`
  - [ ] `DROP POLICY IF EXISTS compliance_sessions_update ON compliance_sessions`
  - [ ] `CREATE POLICY compliance_sessions_update … USING (revoked_at IS NULL)`
- [ ] Create `gateway/migrations/000003_compliance_rls_hardening.down.sql` (restore permissive policies)
- [ ] Update `migrations_test.go` to expect 6 migration files (000001–000003 up/down)
- [ ] Run integration tests green

## Dev Notes

- This is a DDL-only story — no Elixir or Go application code changes.
- RLS `USING` clause controls which existing rows the operation applies to; `WITH CHECK`
  controls new/updated row values. For UPDATE restriction by current state, use `USING` only.
- The down migration must restore the original permissive policy (not drop it entirely), so
  that `migrate down` leaves the schema in a valid, operable state.
- `nebu_app` must have `UPDATE` privilege on both tables — do not REVOKE it; restrict via RLS.
- `FORCE ROW LEVEL SECURITY` is already set on both tables (migration 000002), so the
  superuser bypass does not apply to `nebu_app` connections.
