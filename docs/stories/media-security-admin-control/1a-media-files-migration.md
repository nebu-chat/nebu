---
story_id: 1a-media-files-migration
title: "Media State Machine Foundation: media_files Migration + media_state_transitions Table"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

This story lays the database foundation for the entire `media-security-admin-control` epic:
a `state` column on `media_files` (the quarantine → scan → release lifecycle) and a new
append-only `media_state_transitions` table that records every state change as a compliance
ledger. No Elixir behavior changes here — this is schema-only. The guard logic that drives
transitions (`Nebu.Media.StateMachine`, Story 1b) and the HTTP enforcement point (download-gate,
Story 1c) are built on top of this schema in the next two stories and cannot start before it
lands.

The load-bearing decision in this story is **ADR-031**: `media_state_transitions` must be
provably append-only, not append-only-by-convention. A `BEFORE UPDATE OR DELETE` trigger that
raises `SQLSTATE 23001` for every role (including the table owner) is the primary guarantee;
RLS policies + a targeted `REVOKE` mirror the existing `audit_log` pattern (migration `000001`)
as a secondary, defense-in-depth layer only — because in Nebu's single-role dev/CI posture,
RLS-without-`FORCE`/`REVOKE`-on-owner are no-ops, exactly as `audit_log`'s own comments already
document.

`media_files` already exists (migration `000001_init.up.sql`) and is in production use by the
upload/download handlers (`Nebu.Media.DB`, `Nebu.Media.Storage`, `Nebu.Media.Crypto`). This
story only **adds** columns to it — it does not touch `media_id`, `server_name`,
`content_type`, `file_size`, `aes_key_hex`, `nonce_hex`, `uploader_user_id`, `uploaded_at`, or
the legacy `deleted` boolean, all of which stay as-is and keep working for existing callers.

## User Story

As the Nebu platform (all downstream media-security stories),
I want a `media_files.state` column and an immutable `media_state_transitions` audit table,
so that every future story (async scan, admin overrides, download gating, retention, compliance
reporting) has a single, DB-enforced, tamper-evident source of truth for a file's lifecycle —
instead of each story inventing its own ad-hoc state tracking.

## Acceptance Criteria

1. **New migration files** `server/priv/migrations/000022_media_state_machine_foundation.up.sql`
   and the matching `.down.sql` exist, following the numbering/naming convention of the existing
   `000012`–`000021` migrations (one `up`/`down` pair, `nebu_migrate`-owned DDL, explicit
   `GRANT`/`REVOKE` to `nebu_app` per post-squash-migration convention — see
   `Nebu.Matrix.MigrationsGrantTest`).

2. **New ENUM type `media_state`** with exactly these 8 values, in this order, and
   **no `scan_failed`** (that 9th value is added later, via `ALTER TYPE ... ADD VALUE`, in
   Story 4a — out of scope here):
   `reserved`, `quarantined`, `scanning`, `released`, `infected`, `admin_blocked`, `deleted`,
   `hard_deleted`.

3. **New ENUM type `media_transition_actor_type`** with exactly 2 values: `system`, `admin`.

4. **`media_files` gains these columns** (all additive `ALTER TABLE ... ADD COLUMN`, no existing
   column touched):
   - `state media_state NOT NULL DEFAULT 'released'`
   - `file_hash TEXT` (nullable — SHA-256 of the plaintext content, populated by the scan
     worker in a later story; historical rows have no hash)
   - `scan_metadata JSONB` (nullable — ClamAV signature name + scan timestamp)
   - `storage_key TEXT` (nullable — the S3 object key; replaces the originally-planned
     `file_path`, per the epic's Review 3 correction and ADR-029 — this is **not** a local
     filesystem path)
   - `compressed BOOLEAN NOT NULL DEFAULT false`
   - `archived_at TIMESTAMPTZ` (nullable)
   - `deleted_at TIMESTAMPTZ` (nullable)
   - `hard_deleted_at TIMESTAMPTZ` (nullable)

5. **Backfill of existing rows** (the migration runs against a `media_files` table that already
   has production rows from before this epic):
   - `state` defaults to `'released'` for every pre-existing row, **except** rows where the
     legacy `deleted` boolean is `true`, which are backfilled to `state = 'deleted'`.
   - `storage_key` is backfilled to `media_id` for every pre-existing row (this matches the
     value `Nebu.Media.DB.lookup/2` already derives at read time today — see
     `server/lib/nebu/media/db.ex` line ~110 — so the backfill makes the persisted column agree
     with current runtime behavior instead of silently diverging from it).
   - `file_hash`, `scan_metadata`, `archived_at`, `deleted_at`, `hard_deleted_at` are left `NULL`
     for pre-existing rows (no historical data exists to backfill them from).

6. **New table `media_state_transitions`** with exactly these columns:
   - `id BIGSERIAL PRIMARY KEY`
   - `media_id TEXT NOT NULL REFERENCES media_files(media_id)`
   - `from_state media_state` (nullable — the first transition into `reserved` has no prior
     state)
   - `to_state media_state NOT NULL`
   - `actor_type media_transition_actor_type NOT NULL`
   - `actor_id UUID` (nullable — `NULL` when `actor_type = 'system'`, e.g. scanner-driven
     transitions)
   - `metadata JSONB` (nullable)
   - `inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`

   No `UPDATE`, no `DELETE` is ever legitimate on this table — enforced per AC7–AC9.

7. **Primary immutability guarantee — trigger.** A `BEFORE UPDATE OR DELETE` trigger
   (`media_state_transitions_no_mutate`, backed by function
   `media_state_transitions_immutable()`) fires for **every** row and **every** role, including
   the table owner (`nebu_migrate`/`nebu_app` in single-role dev/CI), and raises
   `RAISE EXCEPTION ... USING ERRCODE = 'restrict_violation'` (**SQLSTATE `23001`**). It fires
   only on `UPDATE`/`DELETE`; `INSERT` is unaffected.

8. **Secondary immutability layer — RLS + REVOKE**, mirroring the existing `audit_log` pattern
   (migration `000001`, lines ~364–380) for vocabulary consistency:
   - `ALTER TABLE media_state_transitions ENABLE ROW LEVEL SECURITY;` (no `FORCE RLS` — same
     posture as `audit_log`, since this layer is explicitly secondary, not primary)
   - `CREATE POLICY media_state_transitions_insert ON media_state_transitions FOR INSERT WITH CHECK (true);`
   - `CREATE POLICY media_state_transitions_select ON media_state_transitions FOR SELECT USING (true);`
   - `CREATE POLICY media_state_transitions_no_update ON media_state_transitions FOR UPDATE USING (false);`
   - `CREATE POLICY media_state_transitions_no_delete ON media_state_transitions FOR DELETE USING (false);`
   - `REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app;`

9. **No `SECURITY DEFINER` purge function** is defined for `media_state_transitions` in this
   migration (unlike `audit_log_purge` for `audit_log`) — retention/rollup for this table is
   explicitly out of scope (epic's Offene Entscheidung #5). A regression test asserts this
   migration defines no `SECURITY DEFINER` function.

10. **Grants** follow the post-squash-migration convention already enforced by
    `Nebu.Matrix.MigrationsGrantTest`: `GRANT SELECT, INSERT, UPDATE, DELETE ON
    media_state_transitions TO nebu_app;` followed immediately by the `REVOKE UPDATE, DELETE`
    from AC8, plus `GRANT USAGE, SELECT ON SEQUENCE media_state_transitions_id_seq TO nebu_app;`.
    `Nebu.Matrix.MigrationsGrantTest` gains a new `describe` block asserting this for migration
    `000022`.

11. **Down migration** (`000022_media_state_machine_foundation.down.sql`) drops the trigger, the
    trigger function, the table (`CASCADE`, to also drop its FK/indexes), the 8 new
    `media_files` columns, and both new ENUM types — in an order that does not error (columns
    before types). It contains no `GRANT` statement (matches the existing down-migration
    convention, AC4 of `MigrationsGrantTest`).

12. `make build-server` compiles and the migration applies cleanly against a fresh database
    (`make dev` stack) and against a database that already has pre-epic `media_files` rows.

## Acceptance Tests

Write these ExUnit tests FIRST (TDD — they must exist and fail/RED before the migration file is
written), all under `server/test/nebu/media/`:

### `media_state_transitions_migration_test.exs` (static SQL analysis, no DB connection — mirrors the style of `Nebu.Matrix.MigrationsGrantTest`)

1. `"000022 up migration creates the media_state ENUM type"` — asserts
   `CREATE TYPE media_state AS ENUM` is present.
2. `"media_state ENUM has exactly the 8 expected values, no scan_failed"` — parses the
   `CREATE TYPE media_state AS ENUM (...)` value list and asserts it equals
   `~w(reserved quarantined scanning released infected admin_blocked deleted hard_deleted)`
   as a set, and specifically `refute "scan_failed" in values`.
3. `"media_transition_actor_type ENUM has exactly system and admin"`.
4. `"media_files gains the 8 new columns via ALTER TABLE ADD COLUMN"` — asserts each of `state`,
   `file_hash`, `scan_metadata`, `storage_key`, `compressed`, `archived_at`, `deleted_at`,
   `hard_deleted_at` appears in an `ADD COLUMN` clause, and that none of the 9 pre-existing
   columns (`media_id`, `server_name`, `content_type`, `file_size`, `aes_key_hex`, `nonce_hex`,
   `uploader_user_id`, `uploaded_at`, `deleted`) is dropped or altered.
5. `"backfills state='deleted' for legacy deleted=true rows, state='released' otherwise"` —
   asserts an `UPDATE media_files SET state = 'deleted' WHERE deleted = true` (or equivalent)
   statement is present.
6. `"backfills storage_key to media_id for existing rows"`.
7. `"media_state_transitions table has the 8 exact expected columns with a media_id FK to media_files"`.
8. `"defines the media_state_transitions_no_mutate trigger as BEFORE UPDATE OR DELETE"` —
   regex-asserts `CREATE TRIGGER media_state_transitions_no_mutate\s+BEFORE UPDATE OR DELETE ON media_state_transitions`.
9. `"trigger function raises SQLSTATE 23001 (restrict_violation)"` — asserts
   `USING ERRCODE = 'restrict_violation'` inside `media_state_transitions_immutable()`.
10. `"enables RLS and defines all 4 policies (insert, select, no_update, no_delete)"`.
11. `"REVOKEs UPDATE, DELETE ON media_state_transitions FROM nebu_app"`.
12. `"grants SELECT, INSERT, UPDATE, DELETE ON media_state_transitions TO nebu_app"` (AC1-style,
    same pattern as the existing `MigrationsGrantTest` describe blocks for `000006`/`000008`/etc).
13. `"grants USAGE, SELECT ON SEQUENCE media_state_transitions_id_seq TO nebu_app"` (AC2-style).
14. `"defines no SECURITY DEFINER function in this migration"` — regression guard, `refute
    String.match?(sql, ~r/SECURITY DEFINER/i)`.
15. `"000022 down migration contains no GRANT statement"` (AC4-style, extend the existing
    `@down_migrations` list in `Nebu.Matrix.MigrationsGrantTest` with
    `"000022_media_state_machine_foundation.down.sql"`).

### `media_state_transitions_immutability_test.exs` (real Postgres integration test — requires a DB connection via `Nebu.Repo`, run against a migrated test database; this is `MEDIA.1-INT-007` from ADR-031's Verification section)

16. `"seeded media_state_transitions row can be inserted (append path works)"` — insert a
    `media_files` row, then insert a `media_state_transitions` row referencing it; asserts
    `{:ok, _}`.
17. `"a raw UPDATE on media_state_transitions raises a Postgres error with SQLSTATE 23001"` —
    issue `Ecto.Adapters.SQL.query(Nebu.Repo, "UPDATE media_state_transitions SET to_state = $1 WHERE id = $2", [...])`
    against the seeded row from test 16 and assert it returns `{:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}}`
    (not a 0-row no-op, not an Elixir-level exception).
18. `"a raw DELETE on media_state_transitions raises the same SQLSTATE 23001 error"` — same
    shape as 17 for `DELETE FROM media_state_transitions WHERE id = $1`.
19. `"the row is unchanged after the failed UPDATE/DELETE attempts"` — re-`SELECT`s the seeded
    row and asserts every column still matches the original insert (proves the trigger actually
    blocked the effect, not just that an error surfaced while the row secretly changed).
20. `"the trigger fires even when the connecting role is the table owner (single-role dev/CI)"`
    — asserts the SQLSTATE 23001 error is observed using the same DB role the test suite
    normally connects as (no special non-owner role needed), which is precisely the gap ADR-031
    identifies in the plain RLS/REVOKE-only alternative.

### `media_files_state_backfill_test.exs` (real Postgres integration test)

21. `"a pre-migration-shaped media_files row (deleted=false) backfills to state='released'"`.
22. `"a pre-migration-shaped media_files row (deleted=true) backfills to state='deleted'"`.
23. `"a pre-migration-shaped media_files row backfills storage_key to its own media_id"`.
24. `"a fresh INSERT into media_files after the migration still succeeds without specifying the new columns"` — asserts the new columns' `DEFAULT`s/nullability don't break the existing
    `Nebu.Media.DB.insert/1` INSERT statement (which does not mention any of the 8 new columns).

## Technical Requirements

Follows ADR-018 (inline SQL, no Repository/Service layer — this is pure migration SQL, no Ecto
schema, no domain module) and ADR-031 (DB-level immutability). Shape of the up-migration
(`server/priv/migrations/000022_media_state_machine_foundation.up.sql`):

```sql
-- ─── media_state / media_transition_actor_type ENUMs ────────────────────────
CREATE TYPE media_state AS ENUM (
    'reserved', 'quarantined', 'scanning', 'released',
    'infected', 'admin_blocked', 'deleted', 'hard_deleted'
);
-- NOTE: 'scan_failed' is intentionally NOT included here — added later via
-- ALTER TYPE media_state ADD VALUE 'scan_failed' in Story 4a.

CREATE TYPE media_transition_actor_type AS ENUM ('system', 'admin');

-- ─── media_files: additive columns ──────────────────────────────────────────
ALTER TABLE media_files
    ADD COLUMN state          media_state NOT NULL DEFAULT 'released',
    ADD COLUMN file_hash      TEXT,
    ADD COLUMN scan_metadata  JSONB,
    ADD COLUMN storage_key    TEXT,
    ADD COLUMN compressed     BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN archived_at    TIMESTAMPTZ,
    ADD COLUMN deleted_at     TIMESTAMPTZ,
    ADD COLUMN hard_deleted_at TIMESTAMPTZ;

-- Backfill: legacy `deleted` boolean rows become state='deleted'; everything
-- else defaults to 'released' from the ADD COLUMN above already.
UPDATE media_files SET state = 'deleted' WHERE deleted = true;

-- Backfill: storage_key mirrors media_id, matching what Nebu.Media.DB.lookup/2
-- already derives at read time today (server/lib/nebu/media/db.ex).
UPDATE media_files SET storage_key = media_id WHERE storage_key IS NULL;

-- ─── media_state_transitions: append-only ledger ────────────────────────────
CREATE TABLE media_state_transitions (
    id          BIGSERIAL                   PRIMARY KEY,
    media_id    TEXT                        NOT NULL REFERENCES media_files(media_id),
    from_state  media_state,
    to_state    media_state                 NOT NULL,
    actor_type  media_transition_actor_type  NOT NULL,
    actor_id    UUID,
    metadata    JSONB,
    inserted_at TIMESTAMPTZ                 NOT NULL DEFAULT NOW()
);

CREATE INDEX media_state_transitions_media_id_idx ON media_state_transitions (media_id);

-- ─── Primary immutability guarantee (ADR-031 §1) ────────────────────────────
CREATE OR REPLACE FUNCTION media_state_transitions_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    RAISE EXCEPTION
        'media_state_transitions is append-only: % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation';   -- SQLSTATE 23001
END;
$$;

CREATE TRIGGER media_state_transitions_no_mutate
    BEFORE UPDATE OR DELETE ON media_state_transitions
    FOR EACH ROW EXECUTE FUNCTION media_state_transitions_immutable();

-- ─── Secondary layer: RLS + REVOKE (ADR-031 §2, mirrors audit_log) ──────────
ALTER TABLE media_state_transitions ENABLE ROW LEVEL SECURITY;
-- No FORCE RLS — same posture as audit_log; this layer is secondary only,
-- the trigger above is authoritative (see ADR-031).

CREATE POLICY media_state_transitions_insert ON media_state_transitions FOR INSERT WITH CHECK (true);
CREATE POLICY media_state_transitions_select ON media_state_transitions FOR SELECT USING (true);
CREATE POLICY media_state_transitions_no_update ON media_state_transitions FOR UPDATE USING (false);
CREATE POLICY media_state_transitions_no_delete ON media_state_transitions FOR DELETE USING (false);

-- ─── Grants (post-squash migration convention, MigrationsGrantTest) ─────────
GRANT SELECT, INSERT, UPDATE, DELETE ON media_state_transitions TO nebu_app;
GRANT USAGE, SELECT ON SEQUENCE media_state_transitions_id_seq TO nebu_app;

-- Defense-in-depth: revoke the UPDATE/DELETE just granted above. No-op if
-- nebu_app is the table owner (single-role dev/CI); meaningful in dual-role
-- deployments. The trigger, not this REVOKE, is what closes ADR-031/R-006.
REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app;

-- Deliberately NO media_state_transitions_purge() / SECURITY DEFINER function
-- here — retention/rollup for this table is out of scope (epic Offene
-- Entscheidung #5). See ADR-031 §3 for the sanctioned escape hatch if a
-- future story needs one.
```

Down migration (`000022_media_state_machine_foundation.down.sql`) — order matters (drop
dependents before the types they use):

```sql
-- Reverses 000022_media_state_machine_foundation.up.sql.
DROP TRIGGER IF EXISTS media_state_transitions_no_mutate ON media_state_transitions;
DROP FUNCTION IF EXISTS media_state_transitions_immutable();
DROP TABLE IF EXISTS media_state_transitions CASCADE;

ALTER TABLE media_files
    DROP COLUMN IF EXISTS state,
    DROP COLUMN IF EXISTS file_hash,
    DROP COLUMN IF EXISTS scan_metadata,
    DROP COLUMN IF EXISTS storage_key,
    DROP COLUMN IF EXISTS compressed,
    DROP COLUMN IF EXISTS archived_at,
    DROP COLUMN IF EXISTS deleted_at,
    DROP COLUMN IF EXISTS hard_deleted_at;

DROP TYPE IF EXISTS media_state;
DROP TYPE IF EXISTS media_transition_actor_type;
```

No Elixir module changes belong to this story — no `Nebu.Media.StateMachine` (Story 1b), no
download-handler changes (Story 1c). This story is migration SQL plus its own tests only.

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/priv/migrations/000022_media_state_machine_foundation.up.sql` | CREATE | ENUMs, `media_files` columns + backfill, `media_state_transitions` table, trigger, RLS/policies, grants/revokes — see Technical Requirements |
| `server/priv/migrations/000022_media_state_machine_foundation.down.sql` | CREATE | Reverses the above in dependency-safe order |
| `server/test/nebu/media/media_state_transitions_migration_test.exs` | CREATE | Static SQL-analysis tests (AC1–AC12, AC14–AC15) |
| `server/test/nebu/media/media_state_transitions_immutability_test.exs` | CREATE | Real-DB integration tests for the trigger (AC7, ADR-031 `MEDIA.1-INT-007`) |
| `server/test/nebu/media/media_files_state_backfill_test.exs` | CREATE | Real-DB integration tests for the backfill (AC5–AC6) |
| `server/test/nebu/matrix/migrations_grant_test.exs` | UPDATE | Add a `describe "AC1/AC2: 000022_media_state_machine_foundation.up.sql grants"` block; add `"000022_media_state_machine_foundation.down.sql"` to the existing `@down_migrations` list (AC4) |

## Dev Agent Guardrails

**Do Not Change:**

- The 9 pre-existing `media_files` columns (`media_id`, `server_name`, `content_type`,
  `file_size`, `aes_key_hex`, `nonce_hex`, `uploader_user_id`, `uploaded_at`, `deleted`) — this
  story is additive only. `Nebu.Media.DB`, `Nebu.Media.Storage`, `Nebu.Media.Crypto` and their
  existing tests (`media_upload_test.exs`, `media_download_test.exs`, etc.) must keep passing
  unmodified.
- Do **not** add `'scan_failed'` to the `media_state` ENUM in this migration. It is a Story 4a
  concern (`ALTER TYPE media_state ADD VALUE 'scan_failed'`, run in its own later migration —
  `ALTER TYPE ... ADD VALUE` cannot run inside the same transaction as other DDL using that type
  in some Postgres versions, which is exactly why the epic assigns it to a separate story/
  migration).
- Do **not** implement `Nebu.Media.StateMachine` (Story 1b) or touch the download handlers
  (Story 1c) in this story. This story stops at the schema.
- Do **not** add a `SECURITY DEFINER` purge function for `media_state_transitions`. Unlike
  `audit_log_purge`, this table's retention is explicitly deferred (epic Offene Entscheidung #5,
  ADR-031 §3). If you find yourself wanting one, stop — it does not belong in this story.
- Do **not** treat the RLS + `REVOKE` block as sufficient on its own. **CRITICAL (Review 6 /
  R-006 / ADR-031):** the original draft of this epic protected `media_state_transitions` only
  by an Elixir-side grep convention (checked in Story 1b). That was rejected — a grep test only
  sees committed Elixir source; it cannot stop a raw `Ecto.Adapters.SQL.query/4` UPDATE/DELETE, a
  later "fixing" migration, or a `psql` session using the app role. **The `BEFORE UPDATE OR
  DELETE` trigger added in this story is the authoritative, DB-level enforcement** — it is what
  makes `MEDIA.1-INT-007` observe a real `SQLSTATE 23001` Postgres error in the single-role
  dev/CI posture Nebu actually runs, where the `audit_log`-style RLS/REVOKE pattern alone is a
  documented no-op for the table owner. Story 1b's grep check remains a cheap *first* line of
  defense, never the guarantee.
- Do **not** skip the `GRANT ... TO nebu_app` / sequence grant for the new table. Post-squash
  migrations (`000002`+) do not benefit from `000001`'s blanket `GRANT ... ON ALL TABLES`; a
  missing per-table grant is a real production outage risk in the dual-role UpCloud deployment
  (see `Nebu.Matrix.MigrationsGrantTest`'s module doc).
- This migration lives under `server/priv/migrations/`, which is pipeline-protected per
  `CLAUDE.md`. Do not hand-apply it outside an active `nebu-pipeline` run.

## Dependencies

None — this is the epic's foundation story (Story 1, split 1 of 3, position 1 of 3 in the
intra-split order). Both **Story 1b** (`Nebu.Media.StateMachine` module) and **Story 1c**
(download-gate enforcement) depend on this story and cannot start before the migration and its
tests land.
