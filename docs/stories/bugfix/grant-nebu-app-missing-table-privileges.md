---
story: grant-nebu-app-missing-table-privileges
epic: bugfix
status: done
security_review: required
matrix: false
ui: false
---

# Bugfix — the runtime role `nebu_app` has no DML privileges on five tables

Release blocker for v0.4.0. Reported earlier as hotfix commit `f80b554a` (branch `hotfix/v0.2.2-operational-logs-war-room-grants`, never merged;
its migration number `000022` is taken on `main`). Found again on `main` by static analysis of all migrations.

## Problem

Migration `000001` ends with a blanket `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app`. It only covers the tables that
exist at that moment. Every later migration that creates a table must grant `nebu_app` itself, because on UpCloud managed PostgreSQL (dual role:
`nebu_migrate` owns and migrates, `nebu_app` runs the server) no `ALTER DEFAULT PRIVILEGES` compensates. Only the development database has it
(`dev/postgres/init/01-roles.sql`), which hides the gap in dev and E2E.

Five tables were created without such a grant:

| Table | Migration | Primary key / sequence |
|---|---|---|
| `cross_signing_keys` | `000014` | TEXT, no sequence |
| `account_data` | `000015` | composite TEXT, no sequence |
| `operational_logs` | `000017` | BIGSERIAL, sequence `operational_logs_id_seq` |
| `war_room_sessions` | `000019` | UUID, no sequence |
| `admin_temporary_captures` | `000020` | TEXT, no sequence |

On such an installation `Nebu.Web.LogStore.Writer` fails with `permission denied for table operational_logs` (the original production error), and E2EE
cross-signing upload / query, account data writes, War Room sessions and temporary captures fail the same way (SQLSTATE 42501).

## Fix

A NEW forward-only migration `000064_grant_missing_table_privileges` (`.up.sql` and `.down.sql`; `000062` and `000063` are taken). It is GRANT-only:
no schema change, no change to a shipped migration. Same style as `000058`-`000061`: plain `GRANT`, no role-existence guard (the role exists in every
supported deployment; in a single-role installation the grants are no-ops). Exactly `SELECT, INSERT, UPDATE, DELETE` on the five tables and
`USAGE, SELECT` on `operational_logs_id_seq`; no `ALL`, no `TRUNCATE`, no `PUBLIC`, nothing on any other object.
`server/test/nebu/release_test.exs` hard-codes no version list (it checks uniqueness and a contiguous run from 1), so it needs no change.

## Acceptance criteria

```gherkin
Scenario: The five tables are granted to the runtime role
  Given the migrations 000001 to 000064
  When the migration files are analysed
  Then 000064 grants SELECT, INSERT, UPDATE and DELETE on cross_signing_keys, account_data, operational_logs, war_room_sessions and admin_temporary_captures to nebu_app
  And 000064 grants USAGE and SELECT on the sequence operational_logs_id_seq to nebu_app

Scenario: No table can be shipped without a runtime grant again
  Given every CREATE TABLE in the up migrations after 000001
  When the migration files are analysed
  Then every table has a GRANT naming it to nebu_app in some migration
  And the test fails with the table name and the migration that created it when a table has none

Scenario: The grant is minimal
  Given the migration 000064
  Then it contains no GRANT ALL, no TRUNCATE, no REFERENCES, no TRIGGER, no PUBLIC and no WITH GRANT OPTION
  And it grants on no object other than the five tables and operational_logs_id_seq
  And its down migration contains no GRANT

Scenario: Shipped migrations stay untouched
  Given the migrations 000001 and 000014 to 000020
  Then their content is unchanged (the fix is forward-only)

Scenario: The release still migrates
  Given the migration version list known to Nebu.Release
  Then it includes 000064 in order after 000063
```
