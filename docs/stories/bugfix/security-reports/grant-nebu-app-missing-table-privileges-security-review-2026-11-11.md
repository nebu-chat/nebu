## Security Review — grant-nebu-app-missing-table-privileges

**Diff scope:** Staged diff. New migration `server/priv/migrations/000064_grant_missing_table_privileges.{up,down}.sql` (GRANT-only, no schema change), acceptance test `server/test/nebu/acceptance/grant_nebu_app_missing_table_privileges_test.exs`, story file and pipeline artefacts. Grants `SELECT, INSERT, UPDATE, DELETE` on `cross_signing_keys`, `account_data`, `operational_logs`, `war_room_sessions`, `admin_temporary_captures` and `USAGE, SELECT` on `operational_logs_id_seq` to `nebu_app`. The down migration is a deliberate no-op (`SELECT 1`).
**Date:** 2026-11-11
**Comparison:** hotfix commit `f80b554a` (branch `hotfix/v0.2.2-operational-logs-war-room-grants`, never merged to main) shipped the same fix as `000022` with a Kassandra report dated 2026-07-10. That report found the three logging tables, raised the `cross_signing_keys`/`account_data` gap as MEDIUM, and approved. 000064 is the main-line equivalent and already includes all five tables, so the earlier MEDIUM is resolved here.

### Prescan candidates

The prescan only triggered on the migration path (no pattern hits). Verified as a sensitive-migration review below.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `server/priv/migrations/000064_grant_missing_table_privileges.up.sql:18` (war_room_sessions), `:16` (operational_logs) | Privileges beyond what the code uses: `DELETE` on `war_room_sessions` and `UPDATE` on `operational_logs` are never used by any code path in `lib/`. `war_room_sessions` is the only durable record of who started a war-room capture (`started_by`, `reason`); war-room start/stop is not an `AuditWriter` action, so this row is the accountability trail | Optional hardening: grant `SELECT, INSERT, UPDATE` on `war_room_sessions` and `SELECT, INSERT, DELETE` on `operational_logs`, and adjust the AC/test. Or keep the uniform SIUD convention and record it as an accepted deviation. Separately, consider adding `war_room_started`/`war_room_stopped` to `audit_log` so accountability does not depend on a mutable table |

### Detail

**Finding #1: Uniform SIUD grant is wider than actual usage on two tables** [LOW]

I compared the privileges with the actual DML in `server/lib` (static SQL and dynamic `#{table}` sites, including `ON CONFLICT DO UPDATE`, which needs UPDATE):

| Table | Used by code | Granted | Surplus |
|---|---|---|---|
| cross_signing_keys | SELECT (incl. FOR UPDATE), INSERT+ON CONFLICT DO UPDATE, UPDATE, DELETE (GDPR erasure `user_deletion.ex:343` via `@erased_tables`) | SIUD | none |
| account_data | SELECT, INSERT+ON CONFLICT DO UPDATE, UPDATE, DELETE (GDPR erasure) | SIUD | none |
| admin_temporary_captures | SELECT, INSERT+ON CONFLICT DO UPDATE, DELETE (disable + expiry cleanup) | SIUD | none |
| operational_logs | SELECT, INSERT (writer), DELETE (retention) | SIUD + seq | UPDATE |
| war_room_sessions | SELECT, INSERT, UPDATE (end session) | SIUD | DELETE |

To exploit the extra privileges, an attacker first needs code execution or SQL injection as `nebu_app`. In that position, `DELETE` on `operational_logs` (a legitimate retention privilege) already lets them destroy diagnostics. So surplus `UPDATE` there adds only silent rewriting of entries, which is marginal. The `war_room_sessions` `DELETE` matters a little more: it would let such an attacker erase the record that an operator turned on verbose payload capture, and `audit_log` has no independent copy. This is defence-in-depth only. There is no exploit path without a prior compromise, and single-role deployments (dev, where `nebu_app` owns the tables) already have every privilege. LOW.

### Reviewed and clean

- **Fixes under-privilege. Nothing new is exposed.** Before 000064, `nebu_app` on dual-role PostgreSQL could not read or write these tables at all (42501, confirmed by the manual control on fresh PG16). Every granted privilege on the three tables with matching usage is needed by existing features. The result equals what single-role deployments already have.
- **Compliance audit trail untouched.** The immutable compliance log is `audit_log`, where 000001/000002 `REVOKE UPDATE, DELETE ... FROM nebu_app` and purge goes through the `audit_log_purge` SECURITY DEFINER function. 000064 does not touch `audit_log` or any function. `operational_logs` is documented as diagnostic data that can be pruned (retention worker DELETEs), not an append-only compliance store.
- **No RLS interaction.** None of the five tables has `ENABLE ROW LEVEL SECURITY` or policies in any migration. The `server_config` policies recreated in 000017/000020 belong to a different table. A plain table GRANT bypasses no policy. RLS stays enforced on `cross_signing_user_signatures` (000061, `FORCE RLS`), which 000064 does not touch.
- **Data content.** `cross_signing_keys` holds public cross-signing keys, not private keys. `account_data` can hold client-encrypted SSSS blobs (`m.secret_storage.*`), which the server cannot decrypt. `admin_temporary_captures` holds only endpoint, timestamps and `started_by`. Captured payloads go to `operational_logs`, which the same role must write and the admin UI must read. Granting the runtime role (the only consumer) access to its own data adds no exposure to any other principal.
- **Grant minimality (syntactic).** No `ALL`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, `PUBLIC`, or `WITH GRANT OPTION`. Only the one existing runtime role is named. The sequence name `operational_logs_id_seq` matches the BIGSERIAL default. The other four tables have UUID/TEXT/composite PKs, so they need no sequence grant.
- **FK `operational_logs.war_room_id -> war_room_sessions(id)`.** Referential checks run with owner rights, so no `REFERENCES` grant is needed. Correctly omitted.
- **Down migration no-op is sound.** The creating migrations' downs drop the tables, and a revoke would reintroduce the outage on a code-only rollback. Same reasoning was accepted in the 2026-07-10 review.
- **No injection surface.** Static DCL, no interpolation. The acceptance test only reads migration files.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory
LOW: 1 — advisory

**Verdict:** APPROVED
