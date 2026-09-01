# Code Review — `1b-state-machine-module` (`Nebu.Media.StateMachine`) — Cycle 0

**Target:** staged diff (6 files, +793/-1)
**Verdict:** APPROVE. No MAJOR/CRITICAL. 2 MINOR (cheap fail-closed hardening, not AC-blocking).

## Acceptance Criteria — all met (AC1-AC7), Dev Agent Guardrails all followed. See full detail in agent transcript; key deep-dive conclusions:

- `SELECT ... FOR UPDATE` correctly prevents races (row lock forces concurrent transitions on same media_id to serialize and re-evaluate the guard against fresh state).
- `String.to_existing_atom/1` on DB-returned state is safe — all 8 states are `@transitions` keys, materialized at compile time.
- `dump_actor_id/1` via `Ecto.UUID.dump!/1` is correct for a native Postgres `uuid` column bound via raw `Ecto.Adapters.SQL.query/3`; the cited precedent (`lib/nebu/web/log_store.ex` `normalize_filter_value/2`) genuinely does the same thing — not an extrapolation. Test 8 round-trips via `Ecto.UUID.load!` so an encoding mismatch would genuinely fail the test.
- `Repo.transaction/1` re-raises (does not convert to `{:error, _}`) for DB-layer failures inside the transaction fun (e.g. the NUL-byte JSONB fault-injection case) — consistent with the story's documented contract (only `:not_found`/`:invalid_transition` are promised as `{:error, _}`).
- Guard table (`@transitions`) is character-for-character identical to the story's literal map — 14 edges, 8 states, zero drift.
- Invariant regex WHERE-boundary fix preserved verbatim from the ATDD fix cycle; `state_machine.ex`'s own `UPDATE` statement is correctly excluded via basename match.
- All 6 SQL queries are fully parameterized ($1..$6) — no injection surface.

## MINOR findings

- **MIN-1 — `{:admin, nil}` is silently accepted.** The guard clause only rejects `{:system, non_nil}`. `{:admin, nil}` falls through and persists `actor_type='admin'` with `actor_id=NULL` — an accountability hole for a compliance ledger. Not required by AC5, but recommended: reject `{:admin, nil}` with `{:error, :invalid_actor}` as symmetric fail-closed hardening. `server/lib/nebu/media/state_machine.ex:122-127`.
- **MIN-2 — Invariant exclusion is by basename, not path.** `scan/1` excludes any file named `state_machine.ex` rather than specifically `nebu/media/state_machine.ex`. Harmless today (only one such file exists), but weakens the defense-in-depth net for any future same-named file in another domain. Tighten to a relative-path match. `server/test/nebu/media/media_mutation_invariant_support.exs:97`.

## INFO (non-blocking, no action required)

- I-1: Typespec omits the raised-exception path for DB-layer failures — documented/accepted behavior, noted for downstream callers (1c/2/4b/6).
- I-2: `String.to_existing_atom` couples this module to the DB enum — safe now, keep `@transitions` in lock-step when Story 4a adds `scan_failed`.
- I-3: Redundant identity pass-through in the `case result do ... end` mapping (lines 147-150) — harmless.
- I-4: `default_lib_dir` is cwd-relative (`File.cwd!()/lib`) — correct under `mix test`, fragile if invoked elsewhere.

## Cycle 1 fix scope (both MINORs, cheap):
1. Reject `{:admin, nil}` with `{:error, :invalid_actor}` symmetric to the `{:system, non_nil}` guard.
2. Tighten invariant-checker exclusion from basename-only match to the specific relative path `nebu/media/state_machine.ex`.

---

## Cycle 1 Re-Review — CLEAN / APPROVE

Both fixes verified independently, not just trusted from the fix agent's report:

- **MIN-1 resolved**: new `{:admin, nil}` guard clause (state_machine.ex) verified correctly ordered — cannot be shadowed by the `{:system, non_nil}` clause, and does not shadow the legitimate `{:admin, <uuid>}` success path (confirmed via clause-order static analysis and the existing positive test still passing). New acceptance test mirrors the `{:system, non-nil}` rejection test exactly: asserts `{:error, :invalid_actor}` AND that state is unchanged AND no transition row was written.
- **MIN-2 resolved**: exclusion now genuinely checks `Path.relative_to(path, lib_dir) == "nebu/media/state_machine.ex"`, independently executed against both the real file path (matches, exempt) and a hypothetical `nebu/matrix/state_machine.ex` (does not match, stays scanned) — confirmed this is a real relative-path check, not a renamed basename check. Test 12 (real-tree scan) is not vacuously green — state_machine.ex's own `UPDATE` statement was confirmed to match the violation regex, so the exclusion is load-bearing and would fail loudly if broken.
- Guard tables in impl and test confirmed to be separately-authored identical literals (not the test just echoing the impl), so the table-driven coverage genuinely guards against implementation typos.
- `mix compile --warnings-as-errors` clean; 4 DB-free invariant tests re-executed (4/4 pass); regex fixture matrix re-executed standalone (7/7 as expected). Full 19-test suite (15 state_machine_test.exs + 4 invariant) previously verified live against Postgres by the fix-cycle agent (19/19 pass, unit suite 1616/0 failed) — re-review's sandbox had no live DB so those specific 15 were verified via clause-order static analysis instead, which is definitive for Elixir pattern matching.
- No scope creep — staged diff is exactly the 6 story-scoped files.
- One INFO-level, pre-existing (not introduced by this fix), out-of-scope note: a malformed actor tuple outside the two documented variants would raise rather than return a clean error tuple — acceptable given the `@type` contract and internal-only callers.

**Final verdict: CLEAN. 0 MAJOR/MINOR open. Ready for security-review.**
