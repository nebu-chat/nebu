# ADR-031: DB-Level Immutability for `media_state_transitions`

## Status

**Proposed (DRAFT)** — 2026-07-02

Born from **R-006** (test-design `media-security-admin-control`, Score 6). Governs Story 1a
(migration) and Story 1b (`Nebu.Media.StateMachine`) of the `media-security-admin-control` epic.
Extends the immutable-table pattern already established for `audit_log` in migration `000001`.
Touches ADR-018 (no domain model — inline SQL), ADR-023 (compliance vs. normal posture).

## Context

`media_state_transitions` is the append-only audit chain for every media state change (Story 1a).
Its integrity is a core compliance invariant of the epic: it is the ledger that proves *when* a
file was quarantined, released, blocked, or hard-deleted, and *by whom*.

As drafted, Story 1b protects this table **only by convention**: an "invariant grep test" asserts
that no Elixir code issues a direct `UPDATE` on `state` / the transitions table outside
`Nebu.Media.StateMachine`. R-006 (Score 6, DATA/Compliance) flagged the hole: a grep sees only
committed Elixir source. It does **not** stop:

- a raw `Ecto.Adapters.SQL.query/4` `UPDATE`/`DELETE` slipped in later,
- a future migration that "fixes" a row,
- a human `psql` session with the app role.

Any of these silently rewrites the audit chain, and the grep check is blind to all three. R-006's
verification bar is explicit and higher than the grep: an integration test that issues a raw
`UPDATE`/`DELETE` through the application DB role and expects a **PostgreSQL error** — not merely
the absence of such a statement in the codebase.

### Prior art in this codebase

The project already solved exactly this for `audit_log` (migration `000001_init.up.sql`,
lines 370–410), under the dual-role model (`nebu_migrate` owns the schema, `nebu_app` is the
runtime role):

```sql
CREATE POLICY audit_log_no_update ON audit_log FOR UPDATE USING (false);
CREATE POLICY audit_log_no_delete ON audit_log FOR DELETE USING (false);
REVOKE UPDATE, DELETE ON audit_log FROM nebu_app;
```

Two properties of that pattern matter here:

1. **RLS `USING (false)` does not raise an error.** It filters the target set to zero rows, so the
   `UPDATE`/`DELETE` "succeeds" affecting 0 rows. It prevents the *effect*, not the *statement*.
2. **`audit_log` deliberately does not `FORCE ROW LEVEL SECURITY`.** Its own comment states:
   *"nebu_app as table owner bypasses RLS (no FORCE RLS), so direct DELETE/UPDATE via the app role
   will still succeed if issued deliberately."* And `REVOKE` is a no-op when `nebu_app` *is* the
   owner (single-role dev/CI) — owners cannot lose implicit owner privileges.

The consequence: in the **single-role** posture that dev and CI actually run, the `audit_log`
recipe raises **no** Postgres error on an owner-issued `UPDATE`/`DELETE`. Copying it verbatim
would leave R-006's verification test unable to observe a real error in the environment where it
runs — the risk would be marked closed while the hole it names stays open.

### What is different about `media_state_transitions`

Unlike `audit_log`, this table has **no legitimate `UPDATE` or `DELETE`, in any posture, ever**
within this epic:

- Story 1a specifies the table as `INSERT`-only ("kein UPDATE, kein DELETE").
- `audit_log` needs a `SECURITY DEFINER` purge function for retention cleanup. This table's
  retention/rollup is **explicitly deferred** to a future follow-on story (epic Offene
  Entscheidung #5). There is no purge, no archival delete, no correction path in scope.

That absence of any legitimate mutation is what lets us choose a stricter, simpler guarantee than
`audit_log` could afford.

## Decision

Enforce the immutability of `media_state_transitions` **at the database level**, not by grep
convention alone. Use a defense-in-depth stack whose *primary* layer holds in every deployment
posture — including single-role dev/CI, where the `audit_log` recipe is a no-op.

### 1. Primary guarantee — `BEFORE UPDATE OR DELETE` trigger (raises)

A `BEFORE UPDATE OR DELETE` trigger on `media_state_transitions` raises an exception
unconditionally:

```sql
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
```

The trigger fires for **every** role, the table owner included. It therefore produces a real
PostgreSQL error (`SQLSTATE 23001`) on a raw `UPDATE`/`DELETE` in single-role dev/CI **and** in
dual-role production — which is precisely what R-006's verification test requires, with no special
non-owner CI role needed. It fires **only** on `UPDATE`/`DELETE`, never on `INSERT`, so both the
`nebu_migrate` backfill in the Story 1a migration and the `nebu_app` runtime appends are
unaffected.

### 2. Secondary layer — RLS + REVOKE (consistency with `audit_log`)

Mirror the `audit_log` defense-in-depth so the two immutable tables share vocabulary and a reader
who knows one recognizes the other:

```sql
ALTER TABLE media_state_transitions ENABLE ROW LEVEL SECURITY;
CREATE POLICY media_state_transitions_no_update ON media_state_transitions FOR UPDATE USING (false);
CREATE POLICY media_state_transitions_no_delete ON media_state_transitions FOR DELETE USING (false);
CREATE POLICY media_state_transitions_insert     ON media_state_transitions FOR INSERT WITH CHECK (true);
CREATE POLICY media_state_transitions_select     ON media_state_transitions FOR SELECT USING (true);
REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app;
```

This layer adds a `SQLSTATE 42501` ("permission denied") in dual-role deployments and blocks the
mutation effect even if the trigger were ever dropped. It is **secondary** because — as the
`audit_log` experience shows — it is a no-op for the owner in single-role. The trigger, not this
layer, is what closes R-006.

### 3. No `SECURITY DEFINER` purge — deliberately

`audit_log` carries `audit_log_purge(INT)` for retention. `media_state_transitions` gets **none**:
append-only-forever is in scope; retention/rollup is out of scope (Offene Entscheidung #5). If a
future rollup story needs to delete aged transitions, it adds its own `SECURITY DEFINER` function
*and* must `ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate`
inside that migration's transaction — a visible, reviewable, audited escape hatch, strictly
narrower than a standing role privilege.

## Alternatives considered

- **RLS + REVOKE only, verbatim `audit_log` copy (no trigger).** Rejected as the *primary* layer:
  no Postgres error for the owner in single-role, so R-006's verification test cannot observe a
  failure in the environment CI runs in. Would require introducing a dedicated non-owner CI test
  role to become meaningful. Kept as the *secondary* layer for consistency.
- **Grep convention only (status quo).** Rejected — this is exactly what R-006 flags. Retained as
  a cheap first line of defense in Story 1b, not as the guarantee.
- **Application-level `Nebu.Media.StateMachine` guard only.** Necessary for correctness of the
  business logic but insufficient for compliance: it does not bind raw SQL, migrations, or `psql`.
- **Trigger primary + no RLS/REVOKE.** Functionally sufficient, but drops the vocabulary shared
  with `audit_log`; keeping the secondary layer costs four DDL statements and buys consistency plus
  a second independent barrier.

## Consequences

- **Story 1a** migration gains: the `media_state_transitions_immutable()` function + trigger
  (primary), the RLS enable + four policies + `REVOKE` (secondary). All additive DDL in the
  existing Story 1a migration; no new migration file.
- **Story 1b** keeps its grep invariant as the cheap first line of defense; its wording is updated
  to note that the *authoritative* enforcement is now DB-level (this ADR), not the grep.
- **Test-design** R-006 moves `Planned → Addressed (Design)`. `MEDIA.1-INT-007` becomes meaningful
  as written in single-role CI: a raw `UPDATE`/`DELETE` via the app connection expects
  `SQLSTATE 23001` (trigger) — a genuine Postgres error, not an Elixir exception, not a 0-row no-op.
- **`nebu_migrate`** (owner) is subject to the trigger too. This is intended: even a migration must
  not silently rewrite history; the `DISABLE TRIGGER`-in-transaction escape hatch is the sanctioned
  path if a future migration genuinely must.
- **Performance:** the trigger is a per-statement barrier that only ever fires on `UPDATE`/`DELETE`
  — operations that never legitimately occur — so it adds zero cost to the hot `INSERT`/`SELECT`
  paths.

## Verification

`MEDIA.1-INT-007` (Story 1, P1): open a connection as the runtime app role, attempt
`UPDATE media_state_transitions SET to_state = ... WHERE id = ...` and
`DELETE FROM media_state_transitions WHERE id = ...` on a seeded row, and assert a PostgreSQL error
(`SQLSTATE 23001` from the trigger; `42501` additionally in dual-role) — **not** the mere absence
of such a statement in the Elixir source, and **not** a silent 0-row result. A companion assertion
confirms a normal `INSERT` (append) still succeeds.
