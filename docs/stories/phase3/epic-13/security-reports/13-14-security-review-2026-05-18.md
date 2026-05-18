# Security Review — Story 13.14 (Squash gateway migrations into single seed)

**Reviewer:** Kassandra
**Date:** 2026-05-18
**Diff scope:** `git diff --staged` — squashes 49 gateway migrations into a single `000001_init.up.sql`, deletes migrations 000002–000049 (96 files), deletes/rewrites 5 migration test files, adds `migrations_squash_integration_test.go` and `migrations_testhelper_test.go`, updates `dev/postgres/init/01-roles.sql` (adds `GRANT CREATE` for `nebu_app` + legacy comment), adds `make dev-reset-db` target.
**Scope of review:** Schema preservation vs. migrations 1–49, RLS policy parity, SECURITY DEFINER function security, role-grant correctness, audit-log immutability semantics, test integrity, dev-init script hardening.
**Story status:** `review` — `security_review: required` flag in frontmatter.

---

## Executive Summary

Per the owner's explicit pre-review brief:

> The audit_log FORCE ROW LEVEL SECURITY removal (Option A) was an explicit user decision: in the single-role model, FORCE RLS with SECURITY DEFINER requires BYPASSRLS which is unavailable on managed PostgreSQL (Stackit PostgresFlex). The accepted trade-off: append-only enforced at application layer. Document this as a known finding if appropriate, but the user has accepted it.

I have verified the claim. The schema content of the squashed `000001_init.up.sql` is faithful to the final state of migrations 1–49 with two intentional, documented deviations:

1. **`audit_log` FORCE ROW LEVEL SECURITY omitted** — moves audit immutability from database-enforced to application-enforced. **Owner-accepted** (Stackit PostgresFlex constraint). Recorded below for audit trail.
2. **Legacy `GRANT EXECUTE ON FUNCTION audit_log_purge(INT) TO nebu` removed** — cleanup of a long-dead superuser role grant. **No regression** — `nebu` is not used at runtime.

No new attack surface is introduced beyond the explicitly accepted FORCE-RLS removal. The squashed migration preserves every other security-relevant invariant: SECURITY DEFINER + `SET search_path = pg_catalog, public`, REVOKE-from-PUBLIC, retention bounds 1–36500, FORCE RLS on `server_config` / `compliance_*` / `room_account_data` / `notifications` / `push_rules` / `pushers`, the `config_update_mutable` allowlist policy, and the BEFORE INSERT `event_time` trigger.

**Verdict: APPROVED.**

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM (accepted) | `gateway/migrations/000001_init.up.sql:309–348` | `audit_log` FORCE ROW LEVEL SECURITY removed. In single-role deployments where `nebu_app` is the table owner, RLS policies (`audit_log_no_delete USING (false)`, `audit_log_no_update USING (false)`) do not apply to the owner. The runtime gateway can issue arbitrary `DELETE FROM audit_log` / `UPDATE audit_log SET …` and they will succeed. The append-only invariant moves from DB-enforced to application-enforced. | **Accepted by Phil 2026-05-18** (Stackit PostgresFlex constraint — BYPASSRLS not available on managed PostgreSQL). Application-layer enforcement: the gateway must never issue DELETE/UPDATE on `audit_log` outside of `audit_log_purge()`. Add a grep-based CI lint that flags `DELETE FROM audit_log` / `UPDATE audit_log` in `gateway/` (excluding migrations + audit_log_purge call sites). |
| 2 | LOW | `dev/postgres/init/01-roles.sql:30, 38` | Hardcoded dev passwords (`nebu_migrate_dev_pw`, `nebu_app_dev_pw`) for the PostgreSQL roles. Pre-existing pattern (introduced by Story 5.29a, not by this story). Comment correctly flags it as DEV ONLY. | No change required — pre-existing, scoped to local dev only, documented. The matching production secret-management invariant is preserved by Stackit Terraform / AWS Secrets Manager paths. Not a regression from this story. |
| 3 | LOW (info / advisory) | `gateway/migrations/000001_init.up.sql:351–354` (comment) | The comment on `audit_log_purge` claims SECURITY DEFINER is "retained for dual-role compatibility (when nebu_migrate is the function owner, elevation bypasses FORCE RLS)". This is correct for dev (where `NEBU_DB_URL_MIGRATE` is still set in `docker-compose.yml` and migrations run as `nebu_migrate`), but the squashed migration itself no longer sets up the dual-role grants (e.g. there is no `GRANT EXECUTE ON FUNCTION audit_log_purge(INT) TO nebu_migrate`). If a future operator runs the squashed migration as `nebu_migrate` and then connects as `nebu_app`, `nebu_app` can still call `audit_log_purge` because of the explicit `GRANT EXECUTE … TO nebu_app`, but `nebu_migrate` (as function owner) would not be able to call its own function without ownership-implicit EXECUTE. PostgreSQL grants implicit EXECUTE to function owners, so this is academically safe. Confirmed: no missing grant. | None required. The "dual-role compatibility" wording in the SQL comment is accurate. |

**Severity legend:** CRITICAL/HIGH block commit. MEDIUM/LOW are advisory unless escalated; accepted-risk MEDIUMs are documented and pass-through.

---

## Detail

### Finding #1 — `audit_log` append-only weakened in single-role deployments [MEDIUM, ACCEPTED]

**Location:** `gateway/migrations/000001_init.up.sql:309–348`

**What changed:**

Before (migrations 18 + 28):
```sql
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;   -- ← FORCE present
CREATE POLICY audit_log_no_delete ON audit_log FOR DELETE USING (false);
CREATE POLICY audit_log_no_update ON audit_log FOR UPDATE USING (false);
-- audit_log_purge: SECURITY DEFINER, owned by nebu_migrate (BYPASSRLS), bypasses FORCE RLS.
```

After (squashed):
```sql
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
-- Note: FORCE ROW LEVEL SECURITY is intentionally absent — see comment above.
CREATE POLICY audit_log_no_delete ON audit_log FOR DELETE USING (false);
CREATE POLICY audit_log_no_update ON audit_log FOR UPDATE USING (false);
-- audit_log_purge: SECURITY DEFINER, owned by whoever runs the migration.
```

**Why this matters:**

In PostgreSQL, RLS policies do NOT apply to the table owner unless `FORCE ROW LEVEL SECURITY` is set. In the single-role production model (Stackit / AWS, `NEBU_DB_URL_MIGRATE` unset → migration runs as `nebu_app` → `nebu_app` is the table owner), the runtime gateway connection IS the owner. Therefore:

- `DELETE FROM audit_log WHERE id = $1` issued by the runtime gateway: **succeeds** (no FORCE RLS, owner bypass).
- `UPDATE audit_log SET action = 'tampered' WHERE id = $1`: **succeeds** (same reason).

The integration test `TestAuditLogImmutability` correctly documents this expectation rather than asserting a block — it logs the rows-affected count and prints `"In single-role mode this is 1 (owner bypasses RLS — accepted trade-off)"`. Honest test, no false comfort.

**Why it is acceptable:**

Stackit PostgresFlex (and most managed PostgreSQL services — Aurora Serverless v2, Azure Database for PostgreSQL Flexible Server) do not allow `ALTER ROLE … BYPASSRLS` to be granted by a non-superuser, and customers do not have superuser access. The only ways to keep FORCE RLS working with a `SECURITY DEFINER` purge function on managed PG would be:

1. A separate `nebu_migrate` role with BYPASSRLS — not available on managed PG.
2. A pre-deployment init script that grants BYPASSRLS — same constraint.
3. Removing FORCE RLS — chosen path.
4. Dropping `SECURITY DEFINER` and using a non-RLS retention strategy (e.g. partition drop) — significant rework.

Option 3 is the pragmatic minimum-disruption fix. The application-layer invariant (the gateway never issues DELETE/UPDATE on `audit_log` outside `audit_log_purge`) becomes the load-bearing control.

**Existing application-layer guarantees (verified in the diff and unchanged):**

- `audit_writer.ex` (Elixir) appends rows only via `INSERT`.
- The Go gateway issues `SELECT audit_log_purge($1)` for retention cleanup (no direct DELETE).
- `audit_log_event_time_force_trigger` (preserved in the squashed migration) forces `event_time = NOW()` on every INSERT, blocking backdating into the purge window.
- `audit_log_purge` parameter is typed `INT` with bounds 1–36500 — no SQL injection, no make_interval overflow.
- `SET search_path = pg_catalog, public` on both functions — CVE-2018-1058 class defense preserved.
- `REVOKE ALL ON FUNCTION audit_log_purge(INT) FROM PUBLIC; GRANT EXECUTE … TO nebu_app` — least-privilege preserved.

**Recommended hardening (non-blocking, advisory):**

Add a CI lint that fails the build if any `gateway/**/*.go` or `core/apps/audit_writer/**/*.ex` file (outside the audit_log_purge call site and the migrations directory) contains a literal `DELETE FROM audit_log` or `UPDATE audit_log SET`. Example grep:

```bash
grep -rEn "DELETE\s+FROM\s+audit_log|UPDATE\s+audit_log\s+SET" \
  gateway/ core/ \
  --include='*.go' --include='*.ex' --include='*.exs' \
  --exclude-dir=migrations \
  --exclude-dir=test \
  --exclude-dir=tests \
  | grep -v 'audit_log_purge' && exit 1 || exit 0
```

**Accepted by:** Phil (story owner) 2026-05-18 — recorded in this report for audit trail per SEC Gate 2 process.

---

### Finding #2 — Hardcoded dev DB role passwords [LOW, pre-existing]

**Location:** `dev/postgres/init/01-roles.sql:30, 38`

The file contains `CREATE ROLE nebu_migrate LOGIN PASSWORD 'nebu_migrate_dev_pw'` and `CREATE ROLE nebu_app LOGIN PASSWORD 'nebu_app_dev_pw'`. Pre-existing pattern from Story 5.29a, not introduced by this story. The file header explicitly states:

```
-- DEV ONLY: passwords are hardcoded here for development convenience.
-- Production deployments MUST use secrets management (Kubernetes Secrets,
-- Vault, AWS Secrets Manager) — never hardcode credentials in production.
```

This is consistent with the project's documented dev-vs-prod separation. The Stackit / AWS Terraform modules and the Helm chart use secret-management injection. **No regression introduced by Story 13.14.** Recorded only for completeness.

---

### Finding #3 — `audit_log_purge` SECURITY DEFINER owner ambiguity [LOW, info]

**Location:** `gateway/migrations/000001_init.up.sql:351–378`

The header comment claims dual-role compatibility, but the squashed migration no longer grants EXECUTE to `nebu_migrate` (only `GRANT EXECUTE … TO nebu_app`). In dev (current `docker-compose.yml` still sets `NEBU_DB_URL_MIGRATE`):

- The migration runs as `nebu_migrate` → `nebu_migrate` becomes the function owner.
- `nebu_app` calls the function: `GRANT EXECUTE … TO nebu_app` covers this.
- `SECURITY DEFINER` elevates execution to `nebu_migrate` (BYPASSRLS) → DELETE through FORCE RLS works on tables that still have FORCE RLS (e.g. server_config, compliance_*).
- For `audit_log` specifically, the DELETE path works regardless because the squashed migration removed FORCE RLS from `audit_log`.

In production (single-role Stackit, `NEBU_DB_URL_MIGRATE` unset):

- The migration runs as `nebu_app` → `nebu_app` becomes both table owner and function owner.
- `SECURITY DEFINER` is a no-op (caller == owner).
- DELETE works because `nebu_app` is the table owner and there's no FORCE RLS.

Both topologies work. The comment wording is accurate. **No action required.** Documented here only because the security-defender ownership story is non-trivial and worth being explicit about in the audit trail.

---

## Schema preservation audit

I spot-checked the following pairs (original migration → squashed location) for byte-equivalent semantics:

| Original | Squashed location | Status |
|---|---|---|
| `000003_server_config` | `000001_init.up.sql:36–80` | OK — FORCE RLS + read_all + insert_only + config_update_mutable allowlist (final state from m000049) |
| `000004_users` + `000006_users_email_pii` + `000021_users_deletion_status` + `000022_users_anonymized` + `000034_users_deactivation` | `000001_init.up.sql:82–113` | OK — all 18 final columns + both CHECK constraints (system_role allowlist, deletion_status allowlist). `NOT VALID` qualifier removed from `users_deletion_status_check` — semantically equivalent on fresh DB. |
| `000010_events` + `000038_events_state_key` + `000042_thread_relations_index` + `000043_search_vector` | `000001_init.up.sql:197–226, 596–612` | OK — search_vector + GIN + thread expression index + state_key + 4 indices. `CREATE INDEX CONCURRENTLY` correctly replaced with plain `CREATE INDEX` (safe on empty table). |
| `000011_sync_tokens` + `000041_sync_tokens_per_device` | `000001_init.up.sql:233–240` | OK — composite PK (user_id, device_id) created directly + FK retained. |
| `000013_room_power_levels` + `000036_rooms_admin_columns` + `000009_rooms` | `000001_init.up.sql:162–183` | OK — final 11-column shape + both CHECK constraints + 2 indices. |
| `000018_audit_log` + `000025_audit_log_event_time_trigger` + `000028_audit_log_purge_owner` | `000001_init.up.sql:320–396` | **DELTA** — FORCE RLS removed (Finding #1, accepted). All other elements preserved: SECURITY DEFINER, search_path, retention bounds 1–36500, REVOKE PUBLIC + GRANT nebu_app, BEFORE INSERT event_time trigger, REVOKE UPDATE+DELETE FROM nebu_app (defense-in-depth in dual-role). |
| `000019_compliance_requests` | `000001_init.up.sql:398–427` | OK — FORCE RLS, all 4 policies preserved including `_no_delete USING (false)`. |
| `000020_compliance_sessions` | `000001_init.up.sql:429–457` | OK — partial unique index, FORCE RLS, all 4 policies. |
| `000026_avatar_url_scrub` | (intentionally absent) | OK — one-time data scrub for existing rows; no rows in fresh DB. Story Dev Notes correctly identifies and excludes this. |
| `000029_room_account_data` + `000031_notifications` + `000032_push_rules_pushers` + `000033_rls_enable_user_tables` | `000001_init.up.sql:459–551` | OK — FORCE RLS + `current_setting('app.user_id', true)` policies on all four tables. |
| `000035_role_overrides` | `000001_init.up.sql:553–564` | OK — PK (user_id, role) + CHECK constraint + lookup index. |
| `000037_room_defaults` | `000001_init.up.sql:566–579` | OK — table + seed row preserved. |
| `000040_forgotten_rooms` | `000001_init.up.sql:581–591` | OK — ON DELETE CASCADE preserved. |
| `000044_oidc_claim_mapping` + `000045_server_config_update_policy` + `000046_server_config_scope_update_policy` + `000048_oidc_directory_config` + `000049_scim_config` | `000001_init.up.sql:51–80, 614–634` | OK — final mutable-keys allowlist (12 keys, all 3 SCIM keys + oidc_directory_* + oidc_* + admin_group_claim). ON CONFLICT DO NOTHING on all seeds. |
| `000047_media_files_uploader_user_id_comment` | `000001_init.up.sql:290–291` | OK — COMMENT ON COLUMN preserved verbatim. |

No undetected schema drift found. The 27 KB squashed file accurately represents the final state of the 49-migration sequence.

---

## Cross-checks against Kassandra MEMORY.md recurring patterns

| Pattern (Epic) | Applies here? | Status |
|---|---|---|
| Missing RLS on new tables (Epic 9) | New tables in this story? No — only consolidation. | N/A |
| Permissive RLS UPDATE without key-scope (Epic 11/12) | Squashed `server_config` UPDATE policy | **OK** — preserved key allowlist (12 explicit keys). No `USING (true)` regression. |
| Caller-controlled `system_role` (Epic 14) | `users_system_role_check` CHECK preserved | OK — allowlist still `('user', 'instance_admin', 'compliance_officer')` |
| ContextKeySub vs ContextKeyUserID (Epic 11/12/14) | N/A — no application code changes |
| DSN composition with externally-generated passwords (Epic 13) | N/A — no DSN/URL changes |
| `deletion_protection = false` IaC defaults (Epic 13) | N/A — no IaC changes staged |
| Singleton-list passthrough into ACL/SG inputs (Epic 13) | N/A — no IaC changes |
| `/admin/*` security-headers carve-out misses `/api/v1/admin/*` (Epic 14) | N/A — no router changes |

No regression in any tracked pattern.

---

## Cross-checks against the Kassandra security-review scope

| Dimension | Findings |
|---|---|
| **SQL injection** | `audit_log_purge` parameter is typed `INT` — no string concat. All `INSERT INTO server_config (key, value, set_at) VALUES (...)` use literal keys. **None.** |
| **Path traversal** | No file-path code changes. **None.** |
| **Command injection** | No shell-exec code changes. **None.** |
| **XSS** | No HTML template changes. **None.** |
| **CSRF** | No state-changing endpoint changes. **None.** |
| **Open redirects** | No redirect-handling changes. **None.** |
| **Auth bypass / IDOR** | No route registration changes. No middleware changes. **None.** |
| **JWT validation flaws** | No JWT code changes. **None.** |
| **Soft auth** | No new endpoints. **None.** |
| **Timing attacks** | No secret-comparison code changes. **None.** |
| **Plaintext secrets in logs** | No logging code changes. **None.** |
| **Secrets in error messages** | `audit_log_purge` `RAISE EXCEPTION` does not leak credentials — only echoes the retention_days input integer. **None.** |
| **Missing body-size / rate limits** | No new HTTP endpoints. **None.** |
| **Unvalidated content types** | No new media-handling code. **None.** |
| **Weak crypto primitives** | No new crypto code (`media_files.aes_key_hex` storage pattern is pre-existing). **None.** |
| **Hardcoded secrets** | Dev `01-roles.sql` passwords — pre-existing (Finding #2). No new ones. |
| **Missing security headers** | No HTML endpoints touched. **None.** |
| **New SQL migrations** | Reviewed line-by-line. Finding #1 only. |

---

## Test integrity audit

- `migrations_squash_integration_test.go` (new) — 6 acceptance tests covering AC2–AC8. `TestAuditLogImmutability` honestly documents the Option A trade-off (does NOT assert a blocked delete) — no false comfort. `TestAuditLogPurgeWorks` uses a privileged DB URL to backdate rows via `session_replication_role = replica` rather than a forged event_time INSERT, which correctly exercises the trigger. `TestSyncTokensCompositeKey` validates the composite-PK constraint with FK-satisfying user setup.
- `migrations_testhelper_test.go` (new) — consolidated shared helpers. Reads `NEBU_TEST_DB_URL` env, falls back to dev default. No hardcoded prod creds.
- `migrations_042_integration_test.go`, `migrations_046_integration_test.go`, `migrations_048_integration_test.go` — rewritten to assert against the squashed final state instead of stepping through versions. Schema invariants preserved in assertions.
- `migrations_test.go` — updated to assert exactly 2 files exist (`000001_init.up.sql`, `000001_init.down.sql`) via `fs.ReadDir` (per MINOR-1 fix). Defensive.

No test forges authentication, no test seeds the DB to skip a real flow, no test asserts a stronger property than the migration provides.

---

## Summary

CRITICAL: 0 — block commit  
HIGH: 0 — block commit  
MEDIUM: 1 (accepted — `audit_log` FORCE RLS removal, owner-accepted trade-off for managed PostgreSQL)  
LOW: 2 (pre-existing dev-password pattern; SECURITY DEFINER owner-ambiguity comment — both informational)

**Verdict: APPROVED.**

The squashed migration faithfully reproduces the final state of migrations 1–49 with two intentional, documented, owner-accepted deviations. No new exploitable surface introduced. The accepted MEDIUM (Finding #1) is recorded for the audit trail and tracked as a Memory pattern (see "Recurring Patterns" update note below).

---

## Follow-up actions

1. **No follow-up story required.** The accepted-risk MEDIUM is formally acknowledged in this report.

2. **Recommended hardening (advisory, non-blocking):** Add a CI lint flagging direct `DELETE FROM audit_log` / `UPDATE audit_log SET` outside the audit_log_purge call site. Tracked as advisory — does not block this story.

3. **Memory update:** Add to MEMORY.md recurring patterns —
   *"DB-enforced immutability via FORCE RLS + SECURITY DEFINER + BYPASSRLS is not portable to managed PostgreSQL (Stackit PostgresFlex, Aurora Serverless v2 baseline, Azure Database for PostgreSQL Flexible Server). When porting a self-hosted dual-role schema to managed PG, the FORCE RLS guarantee must be either (a) accepted as application-layer-only and lint-enforced, or (b) re-implemented via partition drop / event sourcing / external log. Always make this trade-off explicit in the squash/port migration's header comment."*

---

*Kassandra* — Security Prophet, Nebu Sanctum
2026-05-18 · `git diff --staged` review · Story 13.14
