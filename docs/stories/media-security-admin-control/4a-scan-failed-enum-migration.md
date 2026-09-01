---
story_id: 4a-scan-failed-enum-migration
title: "Async Scan Worker: scan_failed ENUM Migration + Elixir State List"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 1a's `media_state` ENUM deliberately shipped **without** `scan_failed` — the epic's "State
Machine" section names it as the "siebter State" reached only after an Oban scan job exhausts
`max_attempts` (Story 4b's `discard/2` callback), and ADR-031/1a's own guardrails flag that adding
it via `ALTER TYPE ... ADD VALUE` belongs in its own later migration, not bundled into the
foundation migration's transaction. This story is that later migration: purely additive DDL that
appends the 9th enum value, plus the small extension to `Nebu.Media.StateMachine`'s guard table
(Story 1b) that lets files actually reach and leave that state.

Nothing else changes. The download-gate (Story 1c) already treats every state it doesn't
explicitly recognize as a 451 `M_NOT_YET_UPLOADED` deny — `scan_failed` falls into that catch-all
the moment the enum value exists, with zero code change to the gate itself. This story's job is to
verify that claim against 1c's actual acceptance criteria/tests, not merely assert it.

## User Story

As the Nebu platform (specifically Story 4b's `MediaScanWorker`, which is blocked on this story),
I want the `media_state` ENUM to include `scan_failed` and `Nebu.Media.StateMachine`'s guard table
to know the legal transitions into and out of it, so that a scan job which exhausts its retries has
a state to land in — one that keeps the file out of circulation, keeps the file hash/metadata
intact for compliance, and lets an admin (or a retried scan) recover it — without reopening or
restructuring the foundation migration or the guard-table mechanism Story 1b already built.

## Acceptance Criteria

1. **AC1 — `ALTER TYPE media_state ADD VALUE 'scan_failed'`.** A new, standalone migration adds
   exactly one enum value, `'scan_failed'`, to the `media_state` type created by Story 1a's
   `000022_media_state_machine_foundation.up.sql`. No existing enum value is reordered, renamed, or
   removed. **Operational constraint (flag explicitly, do not silently work around):** PostgreSQL
   does not allow `ALTER TYPE ... ADD VALUE` to run in the same transaction as other statements that
   *use* the new value (e.g. an `INSERT`/`UPDATE`/`CAST` referencing `'scan_failed'`), and — on
   Postgres versions before 12 — not in the same transaction as any other DDL on that type at all.
   Nebu's migration runner (see `server/priv/migrations/000022_media_state_machine_foundation.up.sql`
   and its siblings) applies one `.up.sql` file per transaction; this story's migration file
   contains **only** the `ALTER TYPE ... ADD VALUE` statement and nothing else, so it cannot
   collide with this restriction — but the down-migration's "removal" (AC2) and any Elixir-side
   backfill work touching rows with `state = 'scan_failed'` in a *future* story must be a separate
   migration/deploy step, never bundled into a transaction that also adds the value.
2. **AC2 — Down migration documents PostgreSQL's ENUM-value-removal limitation.** PostgreSQL has no
   `ALTER TYPE ... DROP VALUE`. The down migration cannot literally reverse AC1. It is a no-op SQL
   file with an explanatory comment (following the same "intentionally does nothing, here's why"
   pattern documented for irreversible enum-value additions) — see Technical Requirements for the
   exact contents and the manual recreate-the-type procedure it documents for the rare case a full
   rollback is genuinely required.
3. **AC3 — `Nebu.Media.StateMachine`'s guard table gains transitions into and out of
   `:scan_failed`.** Story 1b's `@transitions` map (`server/lib/nebu/media/state_machine.ex`) is
   *extended*, not replaced or restructured — Story 1b's Dev Agent Guardrails explicitly reserved
   this map's shape for exactly this extension. The new edges, matching the epic's Story 4b scope
   (`discard/2` on `max_attempts` exhaustion: `"quarantined/scanning → scan_failed"`) and its "Admin
   entscheidet manuell" follow-up:
   - **Into `:scan_failed`:**
     - `:quarantined` → `:scan_failed` (Oban `discard/2` fires with the job still logically
       "not yet started scanning" from the state machine's point of view — e.g. immediate
       non-retryable dispatch failure)
     - `:scanning` → `:scan_failed` (the common case: `max_attempts` retries of the scan itself are
       exhausted)
   - **Out of `:scan_failed`:**
     - `:scan_failed` → `:scanning` (an admin — or an automated re-enqueue in a later story —
       retries the scan; this is the "retried back to `:scanning`" edge named in this story's own
       scope)
     - `:scan_failed` → `:released` (admin manually clears the file after out-of-band
       verification, e.g. inspecting `scan_metadata`/logs and judging the failure to be an
       infrastructure fault, not a content risk)
     - `:scan_failed` → `:admin_blocked` (admin manually blocks the file instead — the failure is
       treated as reason enough to withhold it pending further review, without asserting it is
       actually infected)
   - `:scan_failed` is **not** terminal: unlike `:hard_deleted` and `:infected` (which only has the
     single `-> :deleted` edge), a `scan_failed` file must remain actionable — it represents "we
     don't know," not "we know it's bad" or "we're done with it." It also keeps the existing
     `:deleted` reachability every other non-terminal state has, so it is not a dead end that traps
     a file outside the retention/lifecycle mechanism (Story 8/13): add `:scan_failed → :deleted`
     for parity with `:quarantined`, `:released`, `:admin_blocked`, `:infected` in Story 1b's table.
4. **AC4 — Invalid `:scan_failed` transitions are still rejected.** Edges not listed in AC3 (e.g.
   `:released → :scan_failed`, `:scan_failed → :infected`, `:scan_failed → :hard_deleted` directly)
   remain rejected by the existing `allowed?/2`/`transition/4` guard mechanism from Story 1b, with no
   new mechanism — only the data (`@transitions` map) changes.
5. **AC5 — Download-gate (Story 1c) needs no separate `:scan_failed` handler — verified, not just
   assumed.** Cross-checked against 1c's actual acceptance criteria: AC6 of
   `1c-download-gate-enforcement.md` states verbatim that "Any state not covered by AC1–AC4 —
   including states introduced by later stories (e.g. `:scan_failed`, Story 4a) — falls through to
   the AC1 response (451 `M_NOT_YET_UPLOADED`)," and 1c's own test suite
   (`media_download_gate_test.exs`, test 9) already exercises `:scan_failed` by name against the
   `download_gate/1` catch-all clause (`defp download_gate(_other), do: {451,
   "M_NOT_YET_UPLOADED"}`). This story adds no code to `server/lib/nebu/media.ex` or
   `server/lib/nebu/media/db.ex` — it only confirms (via a regression test run against 1c's already-
   existing gate, Acceptance Test 4 below) that the claim holds once the enum value actually exists
   in the database, not merely in 1c's test fixtures (which construct `state: :scan_failed` as a
   plain Elixir atom regardless of what the live ENUM contains).
6. **AC6 — No data migration.** This story is purely additive: no existing `media_files` row
   changes state, no backfill, no data touched. `ALTER TYPE ... ADD VALUE` only widens the set of
   legal values for future writes; it has no effect on rows already in the table.

## Acceptance Tests

Write these FIRST (TDD — RED before the migration file and the `@transitions` edit exist), split
across the same test-file conventions Story 1a/1b established:

### `server/test/nebu/media/media_scan_failed_migration_test.exs` (static SQL analysis, mirrors `media_state_transitions_migration_test.exs`'s style)

1. `"000023 up migration applies cleanly on top of 000022's media_state ENUM"` — asserts the SQL
   file contains exactly one statement, `ALTER TYPE media_state ADD VALUE 'scan_failed';` (or the
   `IF NOT EXISTS` variant, see Technical Requirements), and no other DDL/DML.
2. `"000023 up migration does not touch media_files, media_state_transitions, or any other type"`
   — regression guard: the file contains no `ALTER TABLE`, no `INSERT`, no `UPDATE`, no `CREATE
   TYPE`/`DROP TYPE` referencing anything other than adding the single value to `media_state`.
3. `"000023 down migration contains no destructive DDL"` — asserts the down file has no `DROP
   TYPE`, no `ALTER TYPE ... DROP VALUE` (which doesn't exist in Postgres and would be a runtime
   error if someone invented it), and instead documents the manual recreate-type procedure as a
   comment (AC2).
4. `"000023 down migration is added to Nebu.Matrix.MigrationsGrantTest's @down_migrations list"`
   — extends the existing list from Story 1a (AC4-style), asserting the down file still contains no
   `GRANT` (trivially true here since it's a no-op file, but keeps the convention's regression net
   covering every down migration, not just the ones with real grants).

### `server/test/nebu/media/media_scan_failed_enum_value_test.exs` (real Postgres integration test, requires migrated test DB via `Nebu.Repo`)

5. `"scan_failed is a queryable member of the media_state enum after migration"` — runs
   `SELECT enum_range(NULL::media_state)` (or `SELECT unnest(enum_range(NULL::media_state))`) via
   `Ecto.Adapters.SQL.query/3` and asserts `"scan_failed"` is present alongside the original 8
   values from Story 1a, with none of those 8 missing or reordered away from their original
   positions relative to each other.
6. `"a media_files row can be inserted with state = 'scan_failed'"` — proves the value is usable
   for actual writes, not just visible in the catalog (guards against a migration that adds the
   label without committing it correctly, e.g. an uncommitted `ADD VALUE` inside a still-open
   transaction in some pooled-connection edge case).

### `server/test/nebu/media/state_machine_test.exs` (extend Story 1b's existing file, do not create a new one)

7. `test "transition/4 allows quarantined -> scan_failed"`.
8. `test "transition/4 allows scanning -> scan_failed"`.
9. `test "transition/4 allows scan_failed -> scanning (retry)"`.
10. `test "transition/4 allows scan_failed -> released (admin manual clear)"`.
11. `test "transition/4 allows scan_failed -> admin_blocked (admin manual block)"`.
12. `test "transition/4 allows scan_failed -> deleted (retention/lifecycle parity)"`.
13. `test "transition/4 rejects released -> scan_failed as {:error, {:invalid_transition, :released, :scan_failed}}"`
    — negative control: `:scan_failed` is only reachable from `:quarantined`/`:scanning`, not from
    an already-released file.
14. `test "transition/4 rejects scan_failed -> infected as {:error, {:invalid_transition, :scan_failed, :infected}}"`
    — negative control: a scan failure is not itself evidence of infection; that edge must not
    exist.
15. `test "transition/4 rejects scan_failed -> hard_deleted directly as {:error, {:invalid_transition, :scan_failed, :hard_deleted}}"`
    — negative control: hard-delete remains reachable only via `:deleted`, no shortcut from
    `:scan_failed`.
16. `test "allowed_transitions(:scan_failed) returns exactly [:scanning, :released, :admin_blocked, :deleted]"`
    (order-independent set comparison) — pins down AC3's exact edge list against silent drift.

### `server/test/nebu/media/media_download_gate_test.exs` (regression check against Story 1c's existing test — extend, do not duplicate its file)

17. `test "state :scan_failed against a live media_state enum value → 451 M_NOT_YET_UPLOADED, no code change needed in download_gate/1"`
    — this is the cross-check demanded by AC5: seed a real `media_files` row (via `Nebu.Repo`, not
    just an in-memory fixture atom) with `state = 'scan_failed'` now that the enum value actually
    exists in the database, run it through the real download path, and assert the existing
    `download_gate/1` catch-all (unmodified since 1c) still produces 451/`M_NOT_YET_UPLOADED`. If
    this test requires touching `server/lib/nebu/media.ex` or `server/lib/nebu/media/db.ex` to pass,
    that is a signal 1c's catch-all was not implemented as specified — escalate per this story's Dev
    Agent Guardrails rather than patching around it.

## Technical Requirements

Follows ADR-018 (inline SQL, no domain model) and the operational constraint named in AC1. Exact
migration SQL:

`server/priv/migrations/000023_media_scan_failed_state.up.sql`:

```sql
-- Adds the 9th media_state value, deferred from Story 1a's foundation migration
-- (000022_media_state_machine_foundation.up.sql) specifically so this ADD VALUE
-- runs in its own transaction, isolated from any other DDL/DML against the
-- media_state type or media_files table.
--
-- OPERATIONAL CONSTRAINT: PostgreSQL does not allow a newly-added enum value to
-- be used (in an INSERT/UPDATE/CAST) within the SAME transaction that adds it.
-- This migration file contains ONLY this one statement for that reason — do not
-- append any statement that references 'scan_failed' to this file, even one
-- that looks harmless (e.g. a backfill, a CHECK constraint, a comment cast).
-- Any such follow-up belongs in a later migration that runs after this one has
-- committed.
ALTER TYPE media_state ADD VALUE 'scan_failed';
```

`server/priv/migrations/000023_media_scan_failed_state.down.sql`:

```sql
-- PostgreSQL has no `ALTER TYPE ... DROP VALUE` — an enum value, once committed,
-- cannot be removed by a simple reverse statement. This down migration is
-- deliberately a no-op; it exists only so the migration runner's up/down
-- pairing convention holds (see 000022's sibling files for the same
-- numbering/pairing rule this follows).
--
-- If a full rollback of 'scan_failed' is ever genuinely required (e.g. rolling
-- back this entire story pre-release, before any row has used the value), the
-- manual, out-of-band procedure is:
--   1. Verify no media_files row has state = 'scan_failed'
--      (SELECT count(*) FROM media_files WHERE state = 'scan_failed';  -- must be 0).
--   2. CREATE TYPE media_state_old AS ENUM (the original 8 values from
--      000022, in their original order).
--   3. ALTER TABLE media_files ALTER COLUMN state TYPE media_state_old
--      USING state::text::media_state_old;
--   4. DROP TYPE media_state; ALTER TYPE media_state_old RENAME TO media_state;
-- This procedure is NOT automated by this migration on purpose: it requires the
-- step-2 zero-rows precondition to hold, which only a human/ops decision can
-- verify safely at rollback time — an automated down-migration that silently
-- ran this against a database with live scan_failed rows would destroy data.
```

### Guard-table diff against Story 1b's original table

Story 1b shipped (`server/lib/nebu/media/state_machine.ex`):

```elixir
@transitions %{
  reserved:      [:quarantined],
  quarantined:   [:scanning, :admin_blocked, :deleted],
  scanning:      [:released, :infected, :quarantined, :admin_blocked],
  released:      [:admin_blocked, :deleted],
  infected:      [:deleted],
  admin_blocked: [:released, :deleted],
  deleted:       [:hard_deleted],
  hard_deleted:  []
}
```

This story's diff (additions only — no existing key or existing edge is removed or reordered):

```elixir
@transitions %{
  reserved:      [:quarantined],
  quarantined:   [:scanning, :admin_blocked, :deleted, :scan_failed],   # + :scan_failed
  scanning:      [:released, :infected, :quarantined, :admin_blocked, :scan_failed],  # + :scan_failed
  released:      [:admin_blocked, :deleted],
  infected:      [:deleted],
  admin_blocked: [:released, :deleted],
  deleted:       [:hard_deleted],
  hard_deleted:  [],
  scan_failed:   [:scanning, :released, :admin_blocked, :deleted]       # NEW key
}
```

Also extend the module's `@type state` in `server/lib/nebu/media/state_machine.ex`:

```elixir
@type state :: :reserved | :quarantined | :scanning | :released
             | :infected | :admin_blocked | :deleted | :hard_deleted
             | :scan_failed
```

No change to `transition/4`, `allowed?/2`, `allowed_transitions/1`, the atomic
`UPDATE`+`INSERT`-in-one-`Repo.transaction/1` flow, the actor validation, or the grep-based
invariant check (Story 1b) — the mechanism is untouched; only the data changes, exactly as Story
1b's Dev Agent Guardrails anticipated ("Story 4a extends this module's guard table with
`scan_failed`").

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/priv/migrations/000023_media_scan_failed_state.up.sql` | CREATE | Single `ALTER TYPE media_state ADD VALUE 'scan_failed';` statement, isolated in its own migration transaction |
| `server/priv/migrations/000023_media_scan_failed_state.down.sql` | CREATE | No-op with explanatory comment + documented manual recreate-type rollback procedure (AC2) |
| `server/lib/nebu/media/state_machine.ex` | UPDATE | Extend `@type state` and `@transitions` with `:scan_failed` and its edges (AC3) — no other change |
| `server/test/nebu/media/media_scan_failed_migration_test.exs` | CREATE | Static SQL-analysis tests (AC1, AC2, AC6) |
| `server/test/nebu/media/media_scan_failed_enum_value_test.exs` | CREATE | Real-DB integration tests confirming the enum value is queryable and usable (AC1, AC6) |
| `server/test/nebu/media/state_machine_test.exs` | UPDATE | Add transition tests for `:scan_failed` edges, both positive and negative (AC3, AC4) |
| `server/test/nebu/media/media_download_gate_test.exs` | UPDATE | Add one regression test seeding a real `state = 'scan_failed'` row against the live enum, cross-checking 1c's catch-all needs no change (AC5) |
| `server/test/nebu/matrix/migrations_grant_test.exs` | UPDATE | Add `"000023_media_scan_failed_state.down.sql"` to the existing `@down_migrations` list |

## Dev Agent Guardrails

**Do Not Change:**

- `server/priv/migrations/000022_media_state_machine_foundation.up.sql` / `.down.sql` (Story 1a) —
  this story does not reopen or amend the foundation migration. `'scan_failed'` is added by a
  **new**, separate migration file, exactly as 1a's own Dev Agent Guardrails anticipated
  ("`ALTER TYPE ... ADD VALUE` cannot run inside the same transaction as other DDL using that type
  in some Postgres versions, which is exactly why the epic assigns it to a separate story/
  migration").
- `Nebu.Media.StateMachine`'s transition *mechanism* (`transition/4`, `allowed?/2`,
  `allowed_transitions/1`, the `Repo.transaction/1` UPDATE+INSERT atomicity, the actor-validation
  guard, the grep-based invariant check) — only the `@transitions` map's data and the `@type state`
  union are extended. Do not restructure the map's shape, split it into multiple attributes, or
  introduce a new guard function for this one addition.
- **Story 1c's download handler
  (`server/lib/nebu/media.ex`'s `with_authorised_media/4`/`download_gate/1`,
  `server/lib/nebu/media/db.ex`) — do not touch it.** Per 1c's own AC6 and its existing test suite,
  `:scan_failed` is explicitly named as one of the "states introduced by later stories" that the
  catch-all clause (`defp download_gate(_other), do: {451, "M_NOT_YET_UPLOADED"}`) already handles
  with zero additional code. This story's obligation is to add Acceptance Test 17 (a regression test
  against the *live* enum value, since 1c's own tests only exercised `:scan_failed` as a bare Elixir
  atom before the value existed in the database) and confirm it passes unmodified. **If it does
  not pass without touching 1c's files, do not silently patch `download_gate/1` to make it pass —
  that would mean 1c's catch-all was not implemented as specified. Stop and escalate** (flag it as
  a defect in 1c's story/implementation, not a hidden scope addition to this one).
- `server/lib/nebu/media/db.ex`'s `@sql_lookup`, `to_map/1`'s `String.to_existing_atom/1`
  conversion (1c) — unaffected; this story doesn't change how state values are read, only that one
  more legal value exists to be read.
- No data migration, no backfill, no `UPDATE media_files` statement anywhere in this story's
  migration file (AC6) — `ALTER TYPE ... ADD VALUE` is the only DDL/DML this story introduces at
  the database level.
- This migration lives under `server/priv/migrations/`, which is pipeline-protected per
  `CLAUDE.md`. Do not hand-apply it outside an active `nebu-pipeline` run.

## Dependencies

**Depends on:**
- **1a-media-files-migration** — provides the `media_state` ENUM (8 values, without
  `scan_failed`) that this story's `ALTER TYPE ... ADD VALUE` extends. Cannot start before 1a's
  migration `000022` has landed and been applied.
- **1b-state-machine-module** — provides `Nebu.Media.StateMachine` and its `@transitions` guard
  table, which this story extends in place. Cannot start before 1b's module exists.

**Enables:**
- **4b-media-scan-worker** — the `MediaScanWorker`'s `discard/2` callback (on `max_attempts`
  exhaustion) is the sole producer of the `:scan_failed` state in normal operation; it cannot call
  `Nebu.Media.StateMachine.transition(media_id, :scan_failed, ...)` until this story's enum value
  and guard-table edges exist.
- **4c-compliance-audit-bridge** — writes an `audit_log` entry (`media_scan_failed` action) keyed
  off the same `:scan_failed` transition this story makes legal; depends transitively on this story
  through 4b.
