# Security Review — 1b-state-machine-module

**Epic:** media-security-admin-control
**Story ID:** 1b-state-machine-module
**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-13
**Diff scope:** STAGED changes only —
- `server/lib/nebu/media/state_machine.ex` (new — the guarded `transition/4` write path)
- `server/test/nebu/media/state_machine_test.exs` (new, real-DB integration acceptance tests)
- `server/test/nebu/media/state_machine_invariant_test.exs` (new, grep-invariant AC6 tests)
- `server/test/nebu/media/media_mutation_invariant_support.exs` (new, invariant-checker helper)
- `server/test/test_helper.exs` (modified — `Code.require_file` the invariant support module)
- `server/mix.exs` (modified — exclude the `.exs` support file from `elixirc_paths`)

**Classification: CLEAN** — no CRITICAL, HIGH, or MEDIUM findings. Two LOW/advisory notes and one INFO note recorded below; none blocks the commit. This module is now the sole application-level write path into `media_files.state`, so it was reviewed against the full focus set (SQL injection, audit-trail bypass/atomicity, actor spoofing, TOCTOU, the grep invariant, and UUID handling). It fails **closed** on every abuse path exercised.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| L-1 | LOW (advisory) | `state_machine.ex:126-135, 161-172` | `actor_type` is not whitelisted in code. Only `{:system, non_nil}` and `{:admin, nil}` are rejected; a third actor_type (e.g. `{:root, uuid}`) falls through and is `Atom.to_string`'d into the `$4` bind. It cannot be *committed* — the `media_transition_actor_type` ENUM (`'system'`,`'admin'`, 1a migration) rejects it, the `query!` raises, and the transaction rolls back (fails closed) — but the module depends on the DB ENUM rather than enforcing its own `@type actor` contract, and the rejection surfaces as a raised `Postgrex.Error`, not a clean `{:error, :invalid_actor}`. | Add an explicit whitelist guard/clause so only `{:system, nil}` and `{:admin, <uuid>}` reach the transaction; return `{:error, :invalid_actor}` for anything else before any DB call. Defense-in-depth; does not change the (already safe) committed behavior. |
| L-2 | LOW (advisory) | `state_machine.ex:134-159, 161-184` | `transition/4`'s documented return contract (`{:ok,_}` / `{:error, {:invalid_transition,…}}` / `:invalid_actor` / `:not_found`) is not exhaustive: DB-layer faults (bad-UUID `Ecto.UUID.dump!/1`, non-map/NUL-byte `metadata`, an unknown `from_state` atom, a non-binary `actor_id`) raise out of `Repo.transaction/1` rather than returning `{:error,_}`. Security-relevant property (atomicity) is intact — every such raise rolls the whole transaction back, so no partial write and no audit gap — but downstream callers (1c/2/4b/6/13) must be told the function can raise. | Not a defect (fail-closed is correct). Optionally `rescue` known encode/dump errors and map them to a documented `{:error, reason}`, or document in the `@spec`/moduledoc that DB-layer failures propagate as exceptions. |
| I-1 | INFO | `state_machine.ex:164-171` (`$6` metadata bind) | `metadata` is stored verbatim in the `media_state_transitions.metadata` JSONB column. It is safely parameterized (no injection), but it is attacker-influenced downstream (ClamAV signature names, admin reason text) and is stored with no size cap or sanitization. Rendering it inline in the admin origin later (Story 6) is a stored-XSS surface. | Out of scope for this module (correctly parameterized here). Carry the constraint into Story 6: escape/`Content-Disposition`/CSP when metadata is surfaced in the admin UI. Matches Kassandra's standing media-epic watch-list (stored-XSS in the admin same-origin context). |

---

## Detail

### Focus 1 — SQL injection across all 6 statement bindings → NONE

All three SQL statements are compile-time module attributes with no runtime string construction, and every caller-supplied value is passed as a positional bind parameter — never interpolated:

| Statement | Location | Caller values | Binding |
|---|---|---|---|
| `@sql_lock_state` `SELECT state … WHERE media_id = $1 FOR UPDATE` | `:62` | `media_id` | `$1` |
| `@sql_update_state` `UPDATE media_files SET state = $2 WHERE media_id = $1` | `:64` | `media_id`, `to_state` | `$1`, `$2` |
| `@sql_insert_transition` INSERT … `VALUES ($1..$6, now())` | `:66-70` | `media_id`, `from_state`, `to_state`, `actor_type`, `actor_id`, `metadata` | `$1`–`$6` |

- `media_id` (arbitrary caller string) flows only through `$1` binds — never concatenated. Even a `media_id` containing SQL metacharacters is inert.
- `to_state`/`from_state`/`actor_type` are `Atom.to_string`'d (`:145,:162,:166,:167,:168`) and bound, not interpolated. Bad values are rejected by the `media_state`/`media_transition_actor_type` ENUMs, not by string escaping.
- `metadata` is bound as `$6` (a map → JSONB via the Ecto/Postgrex JSON codec); no interpolation.
- `now()` is a server-side literal, not caller input.

No `#{}`, no `<>`-built SQL, no `Enum`-joined column lists anywhere in the module. **Clean.**

### Focus 2 — Audit-trail integrity / atomicity / bypass potential → SOUND (fails closed)

The `UPDATE media_files` (`:162`) and the `INSERT media_state_transitions` (`:164`) both run inside a single `Repo.transaction/1` (`:138`), in that order, both via `Ecto.Adapters.SQL.query!` (the bang variant).

- **State-without-audit-row is impossible.** If the INSERT fails (constraint, the 1a `BEFORE UPDATE OR DELETE` trigger on a re-write, a JSONB encode error, etc.), `query!` raises inside the transaction function. Ecto's `Repo.transaction/1` aborts and rolls back the enclosing transaction on any raised exception, so the preceding `UPDATE` is discarded. This is the security-critical property and it is directly proven by the staged fault-injection test (`state_machine_test.exs:217-251`): a `%{"bad" => <<0>>}` metadata forces the *second* write to fail and asserts `fetch_state!(mid) == :quarantined` and `fetch_transitions!(mid) == []` — i.e. the first write was rolled back, not left committed.
- **Audit-row-without-state-change is impossible.** The INSERT only runs after a successful `SELECT … FOR UPDATE` confirmed the row exists (`:140`) and the `UPDATE` ran; both target the same `media_id` under the same lock in the same transaction.
- **The `{:ok,_}`/`{:error,_}` case (`:155-158`) does not mask a partial commit.** A raised DB error is *not* caught here — it propagates to the caller (see L-2), but that path has already rolled the transaction back, so it cannot leave a half-applied state. There is no `rescue` that could swallow a rollback-triggering error and then report success.

No code path changes `media_files.state` without the paired ledger row, or vice versa. **Sound.**

### Focus 3 — Actor spoofing / privilege escalation → NO FALSE-ATTRIBUTION BUG (with L-1 hardening note)

The actor-type validation is enforced in code, in both directions, ahead of any DB call, via function-head pattern matching:

- `{:system, actor_id} when not is_nil(actor_id)` → `{:error, :invalid_actor}` (`:126-128`). A scanner/system call can never carry a spurious admin id. (AC5, test `:298-311`.)
- `{:admin, nil}` → `{:error, :invalid_actor}` (`:130-132`). An admin-attributed transition can never persist a `NULL` `actor_id` accountability hole. (This cycle's added symmetric check, test `:313-324`.)

Both clauses short-circuit before `Repo.transaction/1`, so a rejected actor performs zero writes (tests assert `fetch_state!` unchanged + `fetch_transitions! == []`).

On the "system recorded as admin, or vice versa" question: `actor_type` is taken verbatim from the caller's tuple. A system caller can only be logged as `admin` if that caller itself passes `{:admin, …}` — i.e. the trusted internal caller lies. The module has no independent oracle for the real actor and, by design, records what its (trusted, in-domain) caller declares; that is the correct contract for a shared enforcement primitive, and downstream stories (6/13) route admin calls through `Nebu.Media`'s public API per ADR-020. No within-module path flips a well-formed `{:system, nil}` into an admin row or a `{:admin, uuid}` into a system row.

The only residual is a *third* actor_type (e.g. `{:root, uuid}`) — see **L-1**. It cannot be committed (the `media_transition_actor_type` ENUM rejects it and the transaction rolls back), so no forged ledger row is possible, but the module leans on the DB ENUM rather than its own `@type actor` contract. Recorded as LOW advisory, not a finding of exploitable spoofing.

### Focus 4 — Race conditions / TOCTOU on the guard check → CLOSED by `SELECT … FOR UPDATE`

`transition/4` reads `from_state` with `SELECT state … WHERE media_id = $1 FOR UPDATE` (`:62,:139`) as the first statement inside the transaction. `FOR UPDATE` takes a row-level write lock held until the transaction commits or rolls back.

Two concurrent `transition/4` calls on the same `media_id`: T1 acquires the row lock; T2's identical `FOR UPDATE` blocks until T1 commits. When T1 commits its state change, T2's `SELECT` returns the *new* `from_state` and re-evaluates `allowed?/2` against it. There is no window in which both calls read the same pre-transition state and both pass the guard — the check-then-act is serialized under the lock, not merely optimistic. Because all inner `Ecto.Adapters.SQL.query!` calls execute on the transaction's checked-out connection (Ecto connection ownership), the lock is genuinely in force for the UPDATE/INSERT that follow. **No TOCTOU bypass.**

(If a future caller wraps `transition/4` in its own outer `Repo.transaction`, Ecto uses a savepoint; the `FOR UPDATE` semantics still hold within the outer transaction. Noted for downstream awareness, not a finding.)

### Focus 5 — The grep-invariant checker (AC6) → PROVIDES ITS STATED (defense-in-depth) VALUE

The checker (`media_mutation_invariant_support.exs`) is explicitly DiD-only; the authoritative immutability guarantee is the 1a DB trigger (`media_state_transitions_no_mutate`, SQLSTATE 23001) + RLS/REVOKE per ADR-031. Assessed on that basis:

- **Exclusion mechanism is not bypassable by a same-named file.** `@excluded_relative_path "nebu/media/state_machine.ex"` is compared via `Path.relative_to(&1, lib_dir) == @excluded_relative_path` (`:103`) — exact relative-path equality, not a bare basename match. A future `nebu/matrix/state_machine.ex` (or any other same-basename file) is **not** exempted; only the one blessed file is. This is the correct hardening (the in-code comment documents the MIN-2 fix that moved off basename matching). Verified against the staged tests (`state_machine_invariant_test.exs` tests 12-14: real-tree scan green, positive control flags, two negative controls pass).
- **Regex correctness.** `~r/UPDATE\s+media_files\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bSET\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bstate\s*=/i` (`:66`) bounds both spans with a `WHERE`-negative lookahead, so a legitimate `UPDATE media_files SET compressed = true WHERE state = 'released' …` (an unrelated column update whose WHERE merely *references* `state`) is not flagged — the false-positive case is covered by a dedicated negative-control test (`state_machine_invariant_test.exs`, the WHERE-boundary test). Case-insensitive, newline-tolerant.
- **Known, acknowledged evasions — acceptable because the DB trigger is authoritative.** The checker cannot catch: SQL assembled at runtime by string concatenation/interpolation (`"UPDATE media_files SET st" <> "ate = …"`), a `SET` column list longer than the 200-char span before `state =`, or a mutation placed in a `.exs` file (the scan globs `**/*.ex` only). These are the exact gaps the story's Dev Agent Guardrails call out and hand to ADR-031's trigger — which blocks a rewrite at the DB level for every role including a raw `psql` session, regardless of how the offending SQL was constructed. The grep is a fast code-review/CI tripwire for the *accidental* literal `UPDATE`, and it delivers exactly that, no more and no less than advertised. No overclaim in the module's own docs (the moduledoc repeatedly states it is NOT proof of immutability). **No finding.**

### Focus 6 — UUID handling via `Ecto.UUID.dump!/1` → NO INJECTION / NO TYPE CONFUSION

`dump_actor_id/1` (`:183-184`): `nil` → `nil` (system actor → SQL NULL, AC5); a binary → `Ecto.UUID.dump!/1`, producing the canonical 16-byte binary that Postgrex binds to the native `uuid` column (`$5`). Assessment:

- **No injection.** The output is a bound parameter, never interpolated into SQL. `dump!/1` accepts only a well-formed 36-char canonical UUID string and returns a fixed 16-byte binary; any other string raises `ArgumentError`. A malicious or malformed `actor_id` therefore cannot smuggle bytes into the query text — it either dumps to exactly 16 bytes or raises.
- **Fails closed on bad input.** A malformed admin id (or a non-binary `actor_id` such as an integer, which matches neither `dump_actor_id/1` clause) raises inside the transaction → rollback → no write. Round-trip is proven by the staged test (`state_machine_test.exs:326-343`, `Ecto.UUID.load!(actor_id_bin) == admin_id`).
- **No type confusion.** The column is a real `uuid` (1a migration); the 16-byte binary is the exact wire form Postgrex expects. There is no string/binary ambiguity that could coerce a different column interpretation.

### General — secrets, logging, error disclosure → NONE

- **No logging.** The module issues no `Logger`/`IO` calls, so no state, actor id, or metadata is written to logs.
- **No secrets** in source; no hardcoded credentials; no crypto primitives introduced.
- **Error surface.** Returned errors carry only the `from_state`/`to_state` atoms and the `:not_found`/`:invalid_actor` tags — no DB internals, no connection strings, no stack contents. The one place internal detail could escape is an un-`rescue`d DB exception (L-2); that surfaces a `Postgrex.Error` to the *internal* caller, not to an HTTP client. Downstream HTTP handlers (1c/6) must still avoid echoing raw internal state atoms or exceptions to unauthenticated clients — flagged there, not here.
- **Atom safety.** `String.to_existing_atom/1` (`:141`) is used for `from_state` (not `String.to_atom/1`), so a rogue/unknown DB enum string cannot exhaust the atom table — it raises and rolls back instead. Correct defensive choice.
- **`mix.exs` / `test_helper.exs` changes** only wire the `.exs` support file out of `elixirc_paths` and `Code.require_file` it in the test bootstrap — no production-path or dependency change, no security surface.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 2 (L-1 actor_type not code-whitelisted / relies on DB ENUM, fails closed; L-2 non-exhaustive `{:error,_}` contract on DB-layer faults, fails closed) — both advisory, non-blocking
- INFO: 1 (I-1 metadata stored verbatim — downstream Story 6 XSS constraint, not a defect here)

**Verdict: APPROVED (CLEAN).** `Nebu.Media.StateMachine` is a correctly-built single write path: all SQL is fully parameterized, the UPDATE+INSERT are genuinely atomic (fault-injection-proven), the actor guards are enforced in code in both directions, the `SELECT … FOR UPDATE` closes the guard-check TOCTOU window, UUID handling is injection-safe, and the grep invariant delivers its stated defense-in-depth value without overclaiming against the authoritative ADR-031 DB trigger. Every abuse path exercised fails closed — no state change ever escapes without its paired, correctly-attributed ledger row. The two LOW notes are hardening opportunities (whitelist actor_type in code; document/normalize the raise-on-DB-fault contract); neither is exploitable and neither blocks the commit.
