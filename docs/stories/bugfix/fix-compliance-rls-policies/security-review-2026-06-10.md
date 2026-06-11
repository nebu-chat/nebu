---
reviewer: Kassandra
story: bugfix/fix-compliance-rls-policies
date: 2026-06-10
classification: CLEAN
critical: 0
high: 0
medium: 1
low: 2
informational: 1
---

# Security Review — Fix Compliance RLS UPDATE Policies
**Story:** `bugfix/fix-compliance-rls-policies`
**Date:** 2026-06-10
**Reviewer:** Kassandra (nebu-agent-kassandra)
**Scope:** Staged diff — `000003_compliance_rls_hardening.up.sql`, `000003_compliance_rls_hardening.down.sql`, `migrations_003_integration_test.go`, `migrations_test.go`

---

## Classification: CLEAN

No CRITICAL or HIGH findings. This commit may proceed. Medium and Low findings are advisory; they do not block the commit but should inform future compliance-feature stories.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 2 |
| INFO | 1 |

---

## Findings

### F-1 — MEDIUM: `WITH CHECK (true)` creates an invisible pivot-after-approval window

**Location:** `000003_compliance_rls_hardening.up.sql` — both policies

**Mechanism:**

```sql
CREATE POLICY compliance_requests_update
    ON compliance_requests
    FOR UPDATE
    USING (status = 'pending')
    WITH CHECK (true);
```

`USING` filters *which existing rows* can be updated (the pre-image check). `WITH CHECK` validates the *new row values* (the post-image check). With `WITH CHECK (true)`, any column value — including `status` — can be written freely once the USING gate passes.

This means a `nebu_app` session that has caught the row in `pending` state can UPDATE it to an arbitrary `status` value. The `status CHECK` constraint limits valid values to `('pending', 'approved', 'rejected')`, but it does not constrain the *transition path*: `pending → rejected → pending` (re-opening a rejected request) is possible via two consecutive UPDATEs, each of which passes `USING (status = 'pending')` at the moment of execution.

The practical exploit requires two round-trips to the database and a row still in `pending` state. It is not a single-step bypass of an already-approved record (which is correctly blocked). But for a compliance audit trail where *the sequence of state transitions* matters, this is a meaningful gap.

**Note:** The story requirement (AC1) is "approved and rejected rows become immutable" — which the USING clause correctly enforces. This finding goes beyond AC1, noting that `pending` rows have no field-level protection.

**Remediation:** Either (a) accept the current scope as intentional (pending rows are expected to be freely editable by the application), or (b) tighten `WITH CHECK` if specific columns should be immutable even on pending rows. For the compliance use-case, locking down `requester_user_id`, `room_id`, and `time_range_start`/`time_range_end` to be non-modifiable after initial INSERT is worth considering. If acceptable:

```sql
WITH CHECK (
    requester_user_id = (SELECT requester_user_id FROM compliance_requests WHERE id = compliance_requests.id)
    -- or: a status-transition allowlist enforced at application layer
)
```

The simpler and fully-correct fix is to enforce transitions at the application layer with explicit `WHERE status = 'pending' AND status <> 'pending'` guards, and treat the DB policy as defense-in-depth only against terminal states.

**If the application already enforces valid transitions (pending → approved/rejected only, no re-opening), this finding is informational.**

---

### F-2 — LOW: DOWN migration restores permissive `USING (true)` — no `WITH CHECK`

**Location:** `000003_compliance_rls_hardening.down.sql`

**Mechanism:**

```sql
CREATE POLICY compliance_requests_update
    ON compliance_requests
    FOR UPDATE
    USING (true);
```

The down migration creates the policy with only `USING (true)` and no `WITH CHECK` clause. PostgreSQL defaults `WITH CHECK` to match `USING` when omitted for `UPDATE`, so this is functionally equivalent to `WITH CHECK (true)`. This matches the pre-migration state in `000002`.

However, the original `000002` policy also uses `USING (true)` with no explicit `WITH CHECK`. If a future story tightens `WITH CHECK` on these tables, the down migration would restore a weaker-than-expected baseline. This is low-risk today but worth documenting for maintainability.

**Remediation:** Add explicit `WITH CHECK (true)` to the down migration for clarity and robustness against future delta migrations.

```sql
CREATE POLICY compliance_requests_update
    ON compliance_requests
    FOR UPDATE
    USING (true)
    WITH CHECK (true);
```

---

### F-3 — LOW: DELETE policy not verified in tests — `compliance_requests_no_delete` blocks verified in 000002 but not regression-tested in 000003

**Location:** `migrations_003_integration_test.go`

**Mechanism:**

Migration `000002` sets `USING (false)` DELETE policies on both compliance tables. Migration `000003` drops and recreates the UPDATE policies via `DROP POLICY IF EXISTS`. If a future edit to the migration file inadvertently included a DROP of the no-delete policy (easy mistake when copy-pasting the DROP IF EXISTS pattern), there would be no test catching the regression.

The 7 integration tests cover AC1–AC4 thoroughly for UPDATE and INSERT/SELECT. None verify that DELETE remains blocked post-migration-003.

**Remediation:** Add a test that attempts `DELETE FROM compliance_requests WHERE id = $1` and asserts 0 rows affected (or a policy violation error). Low effort, adds a useful regression guard for a security-critical invariant.

---

### F-4 — INFO: BYPASSRLS note absent from migration comment

**Location:** `000003_compliance_rls_hardening.up.sql` — header comment

**Observation:**

The migration comment correctly explains the USING/WITH CHECK semantics. It does not mention that `FORCE ROW LEVEL SECURITY` (already set in `000002`) means that even the table owner (`nebu_app` in single-role managed-PG deployments) cannot bypass RLS by default. This is the crucial distinction from the `audit_log` case (MEMORY.md — `audit_log` FORCE RLS removed in Story 13.14 for managed-PG compatibility).

For `compliance_requests` and `compliance_sessions`, the architecture decision is: the tables remain under FORCE RLS with `nebu_app` as runtime role — no dual-role setup, no `BYPASSRLS`. This is different from audit_log and should be stated explicitly in the comment to prevent a future "managed-PG compatibility" story from incorrectly removing FORCE RLS here.

**Remediation (advisory):** Add a one-line comment:

```sql
-- FORCE ROW LEVEL SECURITY is intentionally retained on both tables.
-- nebu_app is the runtime role and must not be granted BYPASSRLS.
-- See audit_log (Story 13.14) for the exception pattern — it does not apply here.
```

---

## Checks Not Raised

**SQL injection in migration SQL:** Not applicable. No user-controlled input in DDL. Parameterized queries used in all test SQL.

**Privilege escalation:** No `GRANT` statements in the migration. No new privileges are created. The migration only replaces one policy with a more restrictive one.

**Idempotency:** `DROP POLICY IF EXISTS` guards present on all four statements. Test AC3 (`TestMigration_ComplianceRLSHardening_Idempotent`) verifies this directly and inspects `pg_policy` to confirm the correct USING clause was installed.

**Migration reversibility:** Down migration present and correctly restores the permissive policy. No data loss path identified. Both tables have `IF NOT EXISTS` guards in `000002` so re-applying `000002` after a down is harmless.

**INSERT and DELETE coverage:** INSERT (`WITH CHECK (true)`) and DELETE (`USING (false)`) policies are not touched by this migration. AC4 test covers INSERT/SELECT regression. DELETE regression not covered — see F-3.

**Role boundary:** The tests connect via the `nebu_app` DSN URL (`testMigrationDBURL()`). This is the correct role to use for RLS verification since FORCE RLS is active.

**Compliance audit trail — new MEMORY pattern relevant:**
The `audit_log` accepted-risk (MEMORY.md) documents that FORCE RLS was removed from `audit_log` for managed-PG compatibility. That exception does NOT apply here. The compliance tables have no SECURITY DEFINER purge function and do not face the same managed-PG constraint. FORCE RLS on compliance tables is architecturally sound and should remain.

---

## Accepted Risks Referenced

None from MEMORY.md apply to this diff.

---

## Verdict

**CLEAN — commit proceeds.**

The migration correctly hardens both compliance tables against post-approval tampering. MEDIUM finding F-1 (WITH CHECK pivot window for pending rows) is advisory — it is outside AC1's stated scope and requires a two-step attack against a pending row. LOW findings F-2 and F-3 are maintenance improvements. INFO F-4 is a documentation suggestion.

Recommend addressing F-1 in the compliance-feature epic when application-layer transition logic is built — at that point the decision between application-enforced vs. DB-enforced transition rules should be made explicit.
