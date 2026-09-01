---
story_id: 1b-state-machine-module
title: "Media State Machine Foundation: Nebu.Media.StateMachine Module"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

`media_files.state` (ENUM) and the append-only `media_state_transitions` ledger are defined by
Story 1a. This story adds the Elixir enforcement layer that sits in front of them:
`Nebu.Media.StateMachine`, a guarded, inline-SQL state-transition module. It is the **only**
code path in the application allowed to change `media_files.state`, and every change it makes
writes exactly one row to `media_state_transitions` in the same DB transaction.

Per ADR-031, the authoritative guarantee that `media_state_transitions` cannot be silently
rewritten is the DB-level `BEFORE UPDATE OR DELETE` trigger + RLS/REVOKE added in Story 1a's
migration — not this module and not the grep-based invariant check added here. This story's grep
check is a cheap, fast, first line of defense (catches an accidental direct `UPDATE` in a code
review before it ever reaches the DB); it is explicitly **not** a substitute for the DB trigger,
which is the only layer that also blocks a raw `psql` session or a future migration bug.

## User Story

As a developer implementing media upload, scan, and admin-control flows (Stories 1c, 2, 4b, 6,
13), I want a single guarded module that enforces which `media_files.state` transitions are legal
and unconditionally records who/what/why for every transition, so that no code path can move a
file into an inconsistent state or silently skip the compliance audit trail.

## Acceptance Criteria

1. **AC1 — Module exists.** `Nebu.Media.StateMachine` is a plain Elixir module (no Ecto schema,
   no changeset, no Repository/Service layer — ADR-018) exposing a guarded `transition/4` public
   function plus read-only helpers `allowed?/2` and `allowed_transitions/1`.
2. **AC2 — Guard table matches the epic's state diagram.** An internal `%{from_state => [to_state,
   ...]}` map encodes every transition described in the epic's "State Machine" section (the 8
   states defined by Story 1a's ENUM: `reserved`, `quarantined`, `scanning`, `released`,
   `infected`, `admin_blocked`, `deleted`, `hard_deleted` — **not** `scan_failed`, which Story 4a
   adds later via `ALTER TYPE`). `allowed?/2` and `transition/4` consult this single map; there is
   no per-call-site hardcoded transition check anywhere else.
3. **AC3 — Every successful transition writes exactly one audit row.** A call to `transition/4`
   that passes the guard performs the `media_files.state` `UPDATE` and the
   `media_state_transitions` `INSERT` in one `Repo.transaction/1`. Either both statements commit
   or neither does — there is no window where `state` changes without a corresponding transition
   row, and no window where a transition row exists without the state having actually changed.
4. **AC4 — Invalid transitions are rejected before any write.** If `to_state` is not in
   `allowed_transitions(from_state)`, `transition/4` returns
   `{:error, {:invalid_transition, from_state, to_state}}` without issuing the `UPDATE` or the
   `INSERT`. `media_files.state` and the `media_state_transitions` row count are both unchanged
   after a rejected call.
5. **AC5 — `actor_id` is NULL for system actors.** The caller passes `actor` as
   `{:system, nil}` or `{:admin, admin_user_id}`. `transition/4` persists `actor_type` and
   `actor_id` from this tuple; `{:system, actor_id}` with a non-nil `actor_id` is rejected with
   `{:error, :invalid_actor}` before any write — a scanner-driven transition can never carry a
   spurious admin identity.
6. **AC6 — Grep-based invariant check exists (defense-in-depth, not authoritative).** A check
   (implemented as an ExUnit test, run under `make test-unit-elixir`) scans every `.ex` file under
   `server/lib/` (excluding `state_machine.ex` itself) for a direct SQL statement matching
   `UPDATE ... media_files ... SET ... state` and fails if any match is found. The test's
   `@moduledoc`/inline comment states explicitly that this is a cheap first line of defense and
   that the authoritative enforcement of `media_state_transitions` immutability is the DB-level
   trigger + RLS from Story 1a / ADR-031, not this check.
6. **AC7 — No domain model.** No Ecto schema or changeset is introduced for `media_files` or
   `media_state_transitions`. `Nebu.Media.StateMachine` uses `Ecto.Adapters.SQL.query/3` directly
   against `Nebu.Repo`, following the same inline-SQL convention as `Nebu.Media.DB`.

## Acceptance Tests

Test file: `server/test/nebu/media/state_machine_test.exs`

1. `test "transition/4 with a valid edge (quarantined -> scanning) updates media_files.state"`
2. `test "transition/4 with a valid edge writes exactly one media_state_transitions row with from_state, to_state, actor_type, actor_id, metadata, inserted_at"`
3. `test "transition/4 with an invalid edge (reserved -> released) returns {:error, {:invalid_transition, :reserved, :released}}"`
4. `test "transition/4 with an invalid edge leaves media_files.state unchanged"`
5. `test "transition/4 with an invalid edge writes no media_state_transitions row"`
6. `test "transition/4 with actor {:system, nil} persists actor_id as SQL NULL"`
7. `test "transition/4 with actor {:system, <non-nil id>} is rejected with {:error, :invalid_actor} and writes nothing"`
8. `test "transition/4 with actor {:admin, admin_user_id} persists actor_id as the given admin_user_id"`
9. `test "allowed_transitions/1 returns the full guard-table edge list for a given from_state"`
10. `test "allowed?/2 returns false for hard_deleted -> anything (terminal state, no outgoing edges)"`
11. `test "transition/4 on a media_id that does not exist returns {:error, :not_found} and writes nothing"`

Test file: `server/test/nebu/media/state_machine_invariant_test.exs`

12. `test "no file under server/lib (excluding state_machine.ex) contains a direct UPDATE ... media_files ... SET state statement"` — runs the real invariant scan against the actual `server/lib` tree; must be green today.
13. `test "the invariant checker itself flags a deliberately-introduced violation"` — feeds the
    checker function an in-memory fixture string containing
    `"UPDATE media_files SET state = $2 WHERE media_id = $1"` (i.e. calls the scanning/matching
    function directly rather than writing a file into the real tree) and asserts it is reported as
    a violation. This proves the check is not a no-op/always-green test.
14. `test "the invariant checker does not flag an unrelated UPDATE statement (e.g. UPDATE media_files SET compressed = true)"` — negative control so the regex isn't so broad it flags legitimate, unrelated `media_files` updates from later stories (e.g. Story 12's `compressed` column, Story 8's `archived_at`/`deleted_at` bookkeeping outside `state` itself, if such columns are ever updated directly — though note AC2/AC3 mean `deleted`/`hard_deleted` as *states* must still go through `transition/4`; this test only guards against false positives on non-`state` column updates).

## Technical Requirements

### Public API — `Nebu.Media.StateMachine`

```elixir
@type state :: :reserved | :quarantined | :scanning | :released
             | :infected | :admin_blocked | :deleted | :hard_deleted
@type actor :: {:system, nil} | {:admin, Ecto.UUID.t()}

@spec transition(media_id :: String.t(), to_state :: state(), actor(), metadata :: map()) ::
        {:ok, state()}
        | {:error, {:invalid_transition, state(), state()}}
        | {:error, :invalid_actor}
        | {:error, :not_found}
@spec allowed?(from :: state(), to :: state()) :: boolean()
@spec allowed_transitions(from :: state()) :: [state()]
```

`transition/4`'s `metadata` param defaults to `%{}` and is stored as-is in the
`media_state_transitions.metadata` JSONB column (e.g. ClamAV signature name, admin reason text
from Story 6).

### Guard table (matches epic "State Machine" section)

| From | To | Trigger |
|---|---|---|
| `reserved` | `quarantined` | Bytes arrive via `PUT /upload` |
| `quarantined` | `scanning` | Oban scan job picked up (Story 4b) |
| `scanning` | `released` | ClamAV: clean |
| `scanning` | `infected` | ClamAV: malware found |
| `scanning` | `quarantined` | Scan-error path — Oban retry with backoff (epic: "Scan-Error-Pfad") |
| `quarantined` | `admin_blocked` | Admin manual block, pre-scan |
| `scanning` | `admin_blocked` | Admin manual block, mid-scan |
| `released` | `admin_blocked` | Admin manual block, post-release |
| `admin_blocked` | `released` | Admin unblock |
| `quarantined` | `deleted` | Admin/user soft-delete before release |
| `released` | `deleted` | Admin/user soft-delete |
| `admin_blocked` | `deleted` | Admin soft-delete of a blocked file |
| `infected` | `deleted` | Admin soft-delete/cleanup of an infected record |
| `deleted` | `hard_deleted` | Retention/hard-delete job (mechanism only — policy is Story 8/13) |

`hard_deleted` and `infected` (beyond the single `-> deleted` edge) are terminal — `infected`
files are "nie ausgeliefert" (epic), never transition to `released`.

Implement this as a single module attribute, e.g.:

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

so that Story 4a (adds `scan_failed` + its edges) and any future lifecycle-policy story extend
this map rather than restructuring the guard mechanism.

### Inline SQL (ADR-018 — no Repository/Service layer)

Follow `Nebu.Media.DB`'s convention: `Ecto.Adapters.SQL.query/3` against `Nebu.Repo`, no Ecto
schema. Suggested shape (adapt to `Nebu.Repo.transaction/1` for the atomic UPDATE+INSERT):

```elixir
@sql_lock_state "SELECT state FROM media_files WHERE media_id = $1 FOR UPDATE"

@sql_update_state "UPDATE media_files SET state = $2 WHERE media_id = $1"

@sql_insert_transition """
INSERT INTO media_state_transitions
  (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
VALUES ($1, $2, $3, $4, $5, $6, now())
"""
```

`transition/4` flow:

1. Validate `actor` shape (`{:system, nil}` or `{:admin, uuid}`) — reject early on
   `{:system, non_nil}` with `{:error, :invalid_actor}`, no DB call.
2. `Repo.transaction/1`:
   a. `SELECT state ... FOR UPDATE` to lock the row and read `from_state` (row lock prevents a
      concurrent transition on the same `media_id` from racing past the guard check).
   b. If no row found → `Repo.rollback(:not_found)`.
   c. If `to_state not in allowed_transitions(from_state)` →
      `Repo.rollback({:invalid_transition, from_state, to_state})`.
   d. Otherwise: run the `UPDATE` and the `INSERT` (both inside the same transaction), return
      `{:ok, to_state}`.
3. Map `Repo.transaction/1`'s `{:error, reason}` back to the documented `{:error, reason}` shapes.

### Grep-based invariant check

Implement in pure Elixir (portable, no shell dependency): read every `*.ex` file under
`server/lib/`, apply a case-insensitive regex that matches an `UPDATE` statement referencing both
`media_files` and `state` as the assigned column (e.g.
`~r/UPDATE\s+media_files\b[\s\S]{0,200}?\bSET\b[\s\S]{0,200}?\bstate\s*=/i`), and collect any hit
outside `nebu/media/state_machine.ex`. Expose the matching/scanning logic as a small private
function (or a `Nebu.Media.StateMachine.MutationInvariant` test-support module under
`server/test/support/`) so `state_machine_invariant_test.exs` can call it both against the real
tree (AC6/test 12) and against an in-memory fixture string (tests 13/14) without writing a
throwaway file into the repo.

## File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media/state_machine.ex` | NEW |
| `server/test/nebu/media/state_machine_test.exs` | NEW |
| `server/test/nebu/media/state_machine_invariant_test.exs` | NEW |
| `server/test/support/media_mutation_invariant.ex` (or equivalent helper, if factored out) | NEW (optional) |

## Dev Agent Guardrails

- **The grep invariant is defense-in-depth only.** It catches an accidental direct SQL `UPDATE`
  in committed Elixir source during code review / CI. It does **not** and cannot stop a raw
  `Ecto.Adapters.SQL.query/4` slipped in later that this test doesn't scan, a future migration, or
  a manual `psql` session — that is exactly the gap ADR-031 identifies and closes at the DB level
  in Story 1a (`BEFORE UPDATE OR DELETE` trigger, SQLSTATE `23001`, plus RLS/REVOKE). Do not treat
  a green grep test as proof of immutability, and do not remove, weaken, or "simplify away" the
  Story 1a trigger/RLS on the theory that this module's guard makes it redundant — they protect
  different attack surfaces (application-level correctness vs. any raw SQL/DB-role access).
- **No Ecto schema/changeset for `media_files` or `media_state_transitions`** (ADR-018). Follow
  `Nebu.Media.DB`'s inline-SQL style exactly, not `Nebu.Compliance.AuditWriter`'s
  schema+changeset style (that module predates ADR-018's application to the media epic and is not
  the pattern to copy here).
- **No Repository/Service layer module.** `Nebu.Media.StateMachine` is the single module; do not
  split guard logic, SQL, and a "service" into separate files.
- **Do not implement `scan_failed`.** That ENUM value and its edges are Story 4a's scope
  (`ALTER TYPE ... ADD VALUE`). This story's guard table must be structured (a plain map) so 4a can
  add entries without restructuring `allowed?/2`/`transition/4`.
- **Do not implement lifecycle policy, archival, or legal-hold logic** (Story 8/13). This story
  provides only the transition *mechanism* (`deleted -> hard_deleted` as an edge exists in the
  guard table so the retention job can call it later) — no cron, no policy evaluation, no
  `legal_hold` checks here.
- **Cross-domain callers must go through `Nebu.Media`'s public API** (ADR-020). Other modules
  inside `Nebu.Media` (Story 1c's download handler, Story 4b's scan worker) may call
  `Nebu.Media.StateMachine` directly. `Nebu.Admin` (Story 6, 13) must call through `Nebu.Media`'s
  public module, not reach into `Nebu.Media.StateMachine` directly from the admin namespace.
- **`actor_id` must never be persisted for `actor_type = :system`.** This is enforced by the guard
  in `transition/4` (AC5/test 7), not merely documented — a scanner-driven call that somehow
  carries a non-nil id must fail closed, not silently drop the id.
- **Do not touch `server/priv/migrations/`.** The `media_files`/`media_state_transitions` schema
  and the DB-level trigger/RLS are Story 1a's scope; this story only adds an Elixir module and
  tests against that already-migrated schema.

### Do Not Change

- `server/lib/nebu/media/db.ex`, `storage.ex`, `crypto.ex`, `membership.ex`, `http_fetch.ex`,
  `ssrf.ex` — unrelated to this story's scope.
- `server/lib/nebu/media.ex` (the existing `Nebu.Media` public-API/handler module) — this story
  adds a new module underneath it; wiring `Nebu.Media`'s upload/download handlers to call
  `StateMachine.transition/4` is Story 1c's (download gate) and Story 2's (async upload) scope,
  not this one's.
- `server/priv/migrations/` — Story 1a's scope.

## Dependencies

**Depends on:** `1a-media-files-migration` — the `media_files.state` ENUM, the
`media_state_transitions` table, and its DB-level trigger/RLS (ADR-031) must exist before this
module's SQL and tests can run. This story cannot start until 1a is merged.

**Downstream:** `1c-download-gate-enforcement` depends on this story (reads/relies on
`media_files.state` values produced through this module). Story 4a extends this module's guard
table with `scan_failed`. Stories 2 (async upload), 4b (scan worker), 6 (admin actions), 8/13
(retention & lifecycle policy) all call `Nebu.Media.StateMachine.transition/4` as their sole
write path into `media_files.state`.
