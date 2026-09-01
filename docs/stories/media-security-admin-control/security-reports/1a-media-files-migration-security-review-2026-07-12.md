# Security Review — 1a-media-files-migration

**Epic:** media-security-admin-control
**Story ID:** 1a-media-files-migration
**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-12
**Diff scope:** STAGED changes only —
- `server/priv/migrations/000022_media_state_machine_foundation.up.sql` (new)
- `server/priv/migrations/000022_media_state_machine_foundation.down.sql` (new)
- `server/test/nebu/media/media_state_transitions_migration_test.exs` (new, static SQL analysis)
- `server/test/nebu/media/media_state_transitions_immutability_test.exs` (new, real-DB integration)
- `server/test/nebu/media/media_files_state_backfill_test.exs` (new, real-DB integration)
- `server/test/nebu/matrix/migrations_grant_test.exs` (modified — +000022 describe block, +down-migration entry)
- `server/test/nebu/release_test.exs` (modified — version list 21 → 22)

**Classification: CLEAN** — no CRITICAL, HIGH, or MEDIUM findings. Two LOW/advisory notes recorded below; neither blocks the commit and neither is introduced or worsened by this story.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| L-1 | LOW (informational) | `000022...up.sql:65-79` (trigger) + dual-role deployment | Append-only guarantee ceiling: the table-owner role (`nebu_migrate`) can `DISABLE`/`DROP` the trigger, or `TRUNCATE`, and mutate the ledger. Inherent to owner-based triggers in PostgreSQL; NOT introduced by this story; strictly a subset of what the owner credential already commands over the entire compliance DB. | Accept as a documented risk (same class as the existing `audit_log` accepted risk). Keep `nebu_migrate` creds out of the runtime path (already the case). If ever hardened: own compliance tables with a dedicated role no operational actor holds, or move to append-only WAL/external log. |
| L-2 | LOW (advisory) | `media_state_transitions_immutability_test.exs:81` | First test file to hardcode `nebu_migrate_dev_pw`. Genuinely inert (already-public dev-only credential, CI/dev DB only) but creates a maintenance coupling and a copy-paste seed for a future non-dev credential. | Leave as-is for now (correct, and the value is already public). Optional: read the migrate password from an env var (e.g. `NEBU_DB_URL_MIGRATE`) instead of a literal, so no credential literal ever lives in `server/test/`. |

---

## Detail

### Question 1 — Does hardcoding `nebu_migrate_dev_pw` in a CI-run test introduce secret-handling risk? → NO (genuinely inert)

Verified against tracked source:

- The identical literal already appears, in the clear, in two tracked files:
  - `docker-compose.yml:73` — `NEBU_DB_URL_MIGRATE: "postgresql://nebu_migrate:nebu_migrate_dev_pw@postgres:5432/nebu"`
  - `dev/postgres/init/01-roles.sql:30` — `CREATE ROLE nebu_migrate LOGIN PASSWORD 'nebu_migrate_dev_pw' ...`
- `dev/postgres/init/01-roles.sql` carries an explicit header: *"DEV ONLY: passwords are hardcoded here for development convenience. Production deployments MUST use secrets management ... never hardcode credentials in production."*
- Production never uses this value: the cloud-init path injects `NEBU_DB_URL_MIGRATE` as a rendered secret (`deploy_config_test.exs` enforces it is an inlined `postgresql://` value sourced from Terraform vars, not this literal). The role/password pair `nebu_migrate` / `nebu_migrate_dev_pw` exists only in the dev/CI docker stack.
- The test is tagged `@moduletag :integration` and only executes against the ephemeral `make test-integration` / `make dev` PostgreSQL — never a production credential store.

**Conclusion:** the literal is a re-statement of an already-public dev-only secret, scoped to a throwaway database. No new secret is exposed, no production credential is reachable, and no secret leaks to logs (the value is passed to `Postgrex.start_link/1` opts, never logged). Recorded as **L-2 (LOW, advisory)** only because this is the *first* file under `server/test/` to embed the migrate password (grep-confirmed: `war_room_manager_test.exs` documents the dual-role fact but does not open a `nebu_migrate` connection). Deriving it from `NEBU_DB_URL_MIGRATE` would keep `server/test/` credential-literal-free, but this is hardening, not a defect.

### Question 2 — Does the test's `ALTER TABLE ... DISABLE/ENABLE TRIGGER` reveal an owner-side bypass exploitable in a REAL deployment? → YES it reveals the ceiling, but it is PRE-EXISTING and INHERENT, not introduced or worsened by this story

The concern is real and correctly identified: in the dual-role production deployment (`Nebu.Release.migrate/0` prefers `NEBU_DB_URL_MIGRATE` → migrations run as `nebu_migrate`, which owns every table), `media_state_transitions` is owned by `nebu_migrate`. PostgreSQL permits a **non-superuser table owner** to run `ALTER TABLE ... DISABLE TRIGGER` on its own tables. So an actor holding `nebu_migrate` credentials in production could execute exactly the teardown pattern — `DISABLE TRIGGER` → `UPDATE`/`DELETE` → `ENABLE TRIGGER` — and tamper with the compliance ledger. `session_replication_role` (superuser-only) is correctly noted as unavailable to `nebu_migrate`; `DISABLE TRIGGER` (owner-only, no superuser needed) is the path that works, which is precisely why the test uses it.

Assessed against the threat model, this is **LOW / inherent (L-1)**, not a story defect, for four independent reasons:

1. **It is a fundamental PostgreSQL property of owner-based triggers, not a flaw in this SQL.** Any table owner can `DISABLE TRIGGER`, `DROP TRIGGER`, `TRUNCATE`, or `DROP TABLE`. There is no SQL a table owner can write that constrains that same owner without a superuser boundary or ownership by a role the actor does not hold. The trigger is authoritative against every role *that is not the table owner* — which is exactly the role the runtime actually uses.

2. **`nebu_app` (the runtime role, the only continuously-live credential) cannot do any of it.** It is `NOBYPASSRLS`, is not the owner, is `REVOKE`d `UPDATE, DELETE` (verified: `up.sql:98`), and is granted only `SELECT, INSERT, UPDATE, DELETE` with no `TRUNCATE` (so `TRUNCATE`, which bypasses row triggers, is also denied — confirmed no blanket `TRUNCATE` grant in `000001` or `000022`). The `media_state_transitions_immutability_test.exs` "granted-then-revoked nebu_app" test proves `nebu_app` is stopped at the privilege-check stage (`42501`) before even reaching the trigger. So through the entire live attack surface the app exposes, the ledger is genuinely append-only.

3. **Compromise of `nebu_migrate` is strictly worse for the whole compliance DB, not specific to this ledger.** That credential is `BYPASSRLS` and owns `audit_log`, `compliance_requests`, `compliance_sessions`, `server_config`, and every other table. An attacker with it can already rewrite or drop the entire audit trail. This story's ledger adds no new exposure — it is a subset of a pre-existing all-powerful-owner risk. `nebu_migrate` creds are used only at container-start migration time and are absent from the runtime path, so the exposure window is the deployment bootstrap, not the serving process.

4. **This story is a net improvement over the existing `audit_log` posture, not a regression.** Confirmed by grep: `000001_init.up.sql` gives `audit_log` NO `BEFORE UPDATE OR DELETE` trigger at all — its immutability against the owner is purely convention (the "gateway never issues DELETE/UPDATE outside `audit_log_purge()`" comment) plus RLS-without-FORCE + REVOKE, which is a documented no-op for the owner. `media_state_transitions` adds a DB-enforced trigger that `audit_log` lacks, closing the gap for the runtime role. It maps directly onto the **already-accepted risk** in Kassandra's MEMORY.md ("`audit_log` FORCE RLS removed ... append-only invariant moves from DB-enforced to application-enforced ... managed PostgreSQL does not allow BYPASSRLS by non-superuser", Phil, 2026-05-18) and the recurring pattern *"DB-enforced immutability via FORCE RLS + SECURITY DEFINER + BYPASSRLS is not portable to managed PostgreSQL."*

**Bottom line for Q2:** `nebu_migrate` (or whichever role owns the table) is *by design* a trusted, superuser-adjacent role; it is not, and cannot be, constrained by a trigger it owns. The `DISABLE TRIGGER` teardown does not create or widen this — it merely exercises a capability PostgreSQL unconditionally grants the owner. The teardown is scoped to test `after` blocks, re-enables the trigger even on error (`try/after`, `immutability_test.exs:139-145`), and never ships in `server/lib/`. No production code path disables the trigger. **Not a finding beyond the L-1 informational note.**

### Question 3 — Does the actual SQL match the ADR-031 guarantees exactly? → YES, verbatim

Read both files directly. Every claimed guarantee is present and correct:

| ADR-031 / AC claim | Implemented at | Verdict |
|---|---|---|
| `BEFORE UPDATE OR DELETE` trigger `media_state_transitions_no_mutate` | `up.sql:77-79` | ✅ |
| `FOR EACH ROW`, fires for every role incl. owner | `up.sql:79` + integration test 269-300 proves owner-role hit | ✅ |
| `RAISE EXCEPTION ... USING ERRCODE = 'restrict_violation'` (SQLSTATE 23001) | `up.sql:71-73` | ✅ |
| RLS `ENABLE`, **no** `FORCE` (mirrors audit_log) | `up.sql:82-84` | ✅ |
| 4 policies (insert/select WITH CHECK/USING true; no_update/no_delete USING false) | `up.sql:86-89` | ✅ |
| `GRANT SELECT, INSERT, UPDATE, DELETE ... TO nebu_app` immediately followed by `REVOKE UPDATE, DELETE ... FROM nebu_app` | `up.sql:92` then `up.sql:98` | ✅ |
| Sequence grant `USAGE, SELECT ON SEQUENCE ..._id_seq` | `up.sql:93` | ✅ |
| **No** `SECURITY DEFINER` function | absent (grep-confirmed; test 352-355 asserts `refute SECURITY DEFINER`) | ✅ |
| Down migration contains **no** GRANT | `down.sql` (grep-confirmed; test 363-368) | ✅ |
| Down order: trigger → function → table CASCADE → columns → types | `down.sql:7-22` | ✅ |
| ENUM `media_state` 8 values, no `scan_failed` | `up.sql:11-14` | ✅ |
| Additive-only ALTER on `media_files` (no existing column touched) | `up.sql:26-34` | ✅ |

The trigger function additionally sets `SET search_path = pg_catalog, public` (`up.sql:68`) — a good hardening habit that eliminates search-path ambiguity even though the function is `SECURITY INVOKER` and takes no user input. No gap between what ADR-031 describes and what is implemented.

### Question 4 — Other injection / privilege-escalation / data-integrity concerns → NONE

- **SQL injection:** None. The migration SQL is fully static DDL with no dynamic string construction. The trigger function's only interpolation is `%` on `TG_OP` (a PostgreSQL-supplied system value: `'UPDATE'`/`'DELETE'`), never user input, and it is inside a `RAISE` message, not an executed statement. All test queries are parameterized (`$1`, `$2`); `media_id` values are server-generated via `:crypto.strong_rand_bytes`. The `DISABLE/ENABLE TRIGGER` statements are constant literals with no interpolation.
- **Privilege escalation:** None. Grants are minimal and correctly scoped to `nebu_app` (DML minus UPDATE/DELETE after the revoke; USAGE/SELECT on the sequence). No `GRANT ... TO PUBLIC`, no role creation, no `SECURITY DEFINER`.
- **Data integrity:** The `media_id TEXT NOT NULL REFERENCES media_files(media_id)` FK is correct; the CASCADE in the down migration is scoped to dropping the table's own dependent objects. Backfill statements (`state='deleted' WHERE deleted=true`, `storage_key=media_id WHERE storage_key IS NULL`) are idempotent and match `Nebu.Media.DB.lookup/2`'s existing read-time derivation, so the persisted column agrees with current runtime behavior rather than diverging.
- **Trigger coverage completeness:** The trigger is `BEFORE UPDATE OR DELETE` and does not cover `TRUNCATE`. This is not exploitable by the runtime role (`nebu_app` has no `TRUNCATE` privilege) and is moot against the owner (who has unrestricted destructive power regardless), matching the `audit_log` posture. Noted for completeness only; folded into L-1.
- **`FOR EACH ROW` on a zero-row UPDATE/DELETE:** does not fire, but a zero-row statement mutates nothing, so the append-only invariant is intact. Not a gap.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 2 (L-1 inherent owner-ceiling / informational; L-2 hardcoded dev credential / advisory) — both non-blocking, neither introduced by this story

**Verdict: APPROVED (CLEAN).** The migration implements ADR-031 exactly as specified and is a genuine strengthening of Nebu's compliance-ledger posture relative to the pre-existing `audit_log`. The hardcoded dev credential is inert. The owner-side `DISABLE TRIGGER` capability is an inherent, pre-existing PostgreSQL property that this story neither creates nor worsens, is unreachable by the live runtime role, and is already covered by the accepted `audit_log` immutability risk. No finding blocks the commit.
