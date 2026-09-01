# Test Quality Re-Review — Story `media-security-admin-control/1b-state-machine-module` (Fix-Cycle Verification)

**Scope:** Re-verification of the fix cycle addressing 3 MAJOR findings (M1, M2, M3) from the original test-review pass. Files: `server/test/nebu/media/state_machine_test.exs` (now 14 tests, confirmed by direct grep count — up from 11), `server/test/nebu/media/state_machine_invariant_test.exs` (now 4 tests, confirmed — up from 3), `server/test/nebu/media/media_mutation_invariant_support.exs` (regex changed), plus unchanged wiring in `server/mix.exs`/`server/test/test_helper.exs`.

**Verification method:** Independently re-derived ground truth for each finding rather than trusting the fix agent's account:
- **M3**: Extracted both the *old* and *new* regex verbatim and ran them in a live `elixir` interpreter against the true-positive, the documented false-positive, both original test fixtures, and several additional adversarial cases (multi-column `SET`, no-`WHERE` case, a `WHERE`-keyword substring inside an unrelated string literal).
- **M2**: Spun up a disposable `postgres:16-alpine` Docker container (removed afterward), loaded the project's own compiled `postgrex`/`db_connection` deps, and reproduced the exact fault-injection mechanism against a temp table with a real `JSONB` column (matching `server/priv/migrations/000022_media_state_machine_foundation.up.sql:52`). Ran three scenarios: raw NUL-byte insert, a naive non-transactional UPDATE-then-INSERT sequence, and a real `Postgrex.transaction/2`.
- **M1**: Diffed the test's `@full_guard_table` against the story's canonical guard-table map, edge by edge.
- Ran `mix test test/nebu/media/state_machine_invariant_test.exs` for real (no live Postgres needed) — **4/4 pass**.
- Ran `mix test test/nebu/media/state_machine_test.exs --include integration` — all 14 fail on "Nebu.Repo is not started" (environment-only, same as original N3, confirms the file compiles cleanly).

---

## M1 — RESOLVED (verified)

The new table-driven test (`state_machine_test.exs:347-365`) iterates `@full_guard_table`, a literal copy of the story's canonical map (all 8 states, 14 edges), checked char-for-char against `docs/stories/media-security-admin-control/1b-state-machine-module.md:145-154` — identical. For every state it asserts `allowed_transitions/1` is an exact `MapSet` match AND asserts `allowed?/2` is `true` for every documented edge and `false` for every non-adjacent pair. A dedicated second test (`state_machine_test.exs:372-383`) explicitly covers all 4 `:scanning` edges plus 3 negative checks. A typo dropping `scanning -> infected` or adding a spurious edge would fail both tests.

## M2 — RESOLVED (verified empirically)

Live reproduction results (temp table, real Postgrex, real JSONB column):

| Scenario | Result |
|---|---|
| Raw INSERT with `%{"bad" => <<0>>}` | Genuine server-side `Postgrex.Error`, `pg_code: "22P05"` (untranslatable_character) — real Postgres round-trip failure |
| Naive non-transactional impl (separate UPDATE, then separate INSERT) | UPDATE committed (`state = "scanning"`), INSERT failed — final state changed |
| Real atomic impl (`Postgrex.transaction/2`) | Transaction raised and rolled back; final state unchanged (`"quarantined"`), transitions table empty |

The fault-injection test's core assertion (`fetch_state!(mid) == :quarantined`, `fetch_transitions!(mid) == []`) would genuinely fail against the naive implementation and pass against a real atomic one — the test discriminates correctly.

INFO (non-blocking): a future implementation adding metadata pre-validation before any DB write would still pass this test without exercising the transactional rollback path — low-probability, not called for by the story, not a reason to withhold sign-off.

## M3 — RESOLVED (verified by direct execution)

- Old regex confirmed to match the false-positive string (bug was real).
- New regex (`~r/UPDATE\s+media_files\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bSET\b(?:(?!\bWHERE\b)[\s\S]){0,200}?\bstate\s*=/i`): false-positive string → no longer matches; true positive still matches; both original test-13/14 fixtures behave correctly.
- Additional adversarial cases (multi-column SET, no-WHERE variant, literal "WHERE" substring inside an unrelated string) all resolved correctly.
- `mix test test/nebu/media/state_machine_invariant_test.exs` → 4 passed, 0 failed, for real.

---

## New issues introduced by the fix? None found (MAJOR or MINOR)

No new hardcoded ids, no hard waits/polling/flaky assertions, wiring unchanged and correct. Test counts verified by direct grep: 14 and 4, matching stated deltas.

## Findings carried forward, unchanged (non-blocking)

- **N1** (MINOR) — AC1/AC7 "no domain model" structural constraint still untested (consistent with codebase conventions; optional).
- **N2** (MINOR) — `scan/1`'s basename-exclusion path still has no dedicated fixture-directory unit test; exercised only vacuously today.
- **N3** (INFO) — moduledoc's stated RED failure mode doesn't match sandbox-without-DB failure mode — environment-only, not a defect.
- **I1** (INFO, new) — M2's fault-injection test can't in principle distinguish real DB-level rollback from a hypothetical future pre-validation step rejecting NUL bytes before any write; not called for by the story, not blocking.

---

## Verdict: CLEAN — 0 MAJOR findings open

All three original MAJOR findings (M1, M2, M3) are genuinely resolved, independently re-verified by direct execution/empirical reproduction. No new MAJOR or MINOR issues introduced. This story's TDD scaffold is ready for dev-story implementation.
