# Test Review Findings — jwt-denylist-persistence

**Story:** jwt-denylist-persistence — Port JWT denylist from volatile ETS to PostgreSQL-backed store
**Reviewer:** Test Architect (TEA Gate — pre-implementation ATDD review)
**Date:** 2026-06-23
**Phase:** RED — tests written before implementation; reviewed before any implementation code is written

---

## Summary

The test scaffolds are well-structured, clearly labelled as RED-phase, and cover the
most critical acceptance criteria at both the integration and unit level. Two test files
are used with a clean split: `TokenDenylistIntegrationTest` (DB-backed, `@moduletag :integration`)
and `TokenDenylistDurabilityTest` (pure unit, no DB). No hard waits, no cookie forging,
no DB-seeding shortcuts that bypass the production code path.

**Overall verdict: PASS with two MINOR findings and one IMPROVEMENT note.**

No MAJOR finding. Safe to proceed to implementation.

---

## AC Coverage Matrix

| AC  | Description                                      | Priority | Covered by                          | Status   |
|-----|--------------------------------------------------|----------|-------------------------------------|----------|
| AC1 | DB write on revoke (INSERT ON CONFLICT DO NOTHING) | P0     | `TokenDenylistIntegrationTest` AC1 describe (3 tests) | COVERED |
| AC2 | DB read on cache miss                            | P0       | `TokenDenylistIntegrationTest` AC2 describe (2 tests) | COVERED |
| AC3 | ETS fast path preserved — no DB round-trip       | P0       | `TokenDenylistDurabilityTest` AC3 describe (2 tests) | COVERED |
| AC4 | Restart survival — ETS cleared, DB fallback      | P0       | `TokenDenylistIntegrationTest` AC4 describe (1 test) | COVERED |
| AC5 | DB key encoding — jti:<jti> and bare SHA-256 hex | P0       | `TokenDenylistIntegrationTest` AC5 describe (2 tests) + AC1 tests recheck key shape | COVERED |
| AC6 | Lazy expiry in DB — expired rows = absent        | P1       | `TokenDenylistIntegrationTest` AC6 describe (1 test) | COVERED |
| AC7 | Best-effort DB write — DB down → :ok, ETS written | P1      | `TokenDenylistDurabilityTest` AC7 describe (2 tests) | COVERED |
| AC8 | Best-effort DB read — DB down → false, no crash  | P1       | `TokenDenylistDurabilityTest` AC8 describe (2 tests) | COVERED |
| AC9 | Existing tests green — no regressions            | —        | `TokenDenylistTest` (6 tests) + `OidcPlugTest` (12 tests) | GUARDED |

All 9 ACs have at least one test. No AC is uncovered.

---

## Findings

### MINOR-1 — AC3 fast path assertion relies on internal ETS tuple format that will change

**File:** `server/test/nebu/web/token_denylist_integration_test.exs`, lines 378–379 (unit file)

**Test:** `[P0] revoked? returns true from ETS without needing the DB`

The test inserts the ETS entry directly as:
```elixir
:ets.insert(@table, {{:jti, jti}, exp})
```
This uses the current internal key format `{:jti, jti}`. The story's AC5 specifies that
the **DB key** must be the string `"jti:<jti>"` (not the tuple). However, AC5 says nothing
about changing the ETS key format. If the implementation keeps ETS keys as `{:jti, jti}`
tuples (unchanged from today) while using the string `"jti:<jti>"` only in the DB, the
test is correct as-is. But if the developer unifies ETS and DB keys to the same string
format (a natural refactoring), this direct `:ets.insert` will fail to simulate an ETS
hit correctly.

**Risk:** Low — the test will surface this immediately as a compile/runtime failure rather
than a false pass. But it introduces a test that is tightly coupled to an internal
representation that the story itself is in flux about.

**Recommendation:** Add a comment clarifying whether ETS internal keys are intended to
remain `{:jti, jti}` tuples post-implementation, or whether they should also migrate to
strings. If the intent is to unify to strings, update the `:ets.insert` call to use
`"jti:#{jti}"` as the key. This aligns the AC3 fast-path test with the AC5 encoding rule
and avoids a disconnect between what the test seeds and what the implementation produces.

---

### MINOR-2 — AC7 unit tests branch on `Process.whereis(Nebu.Repo)` at runtime

**File:** `server/test/nebu/web/token_denylist_integration_test.exs`, lines 419–462 (unit file, `TokenDenylistDurabilityTest`)

**Tests:** `[P1] revoke returns :ok when Repo is not started` and `[P1] ETS entry is written even when Repo is not started`

Both AC7 tests use `if Process.whereis(Nebu.Repo) do … else … end` to branch between
"integration mode (Repo running)" and "unit mode (Repo absent)". The consequence is that
the critical assertion — that `revoke/3` does NOT crash when Repo is unavailable — only
executes in the `else` branch, i.e. only when run under `mix test` without a DB. When
the same test file is included in an integration test run (where `Nebu.Repo` IS started),
the test silently takes the `if` branch and verifies a much weaker property (that `:ok`
is returned when DB is available — which any correct implementation satisfies regardless
of the safe-query guard).

This means the most important assertion for AC7 and AC8 — "no crash when Repo is absent"
— is effectively bypassed in the environment that most closely resembles production
(integration profile). After the DB integration is added, a missing `safe_query` guard
will only be caught by `mix test` (unit profile), not by `make test-integration`.

**Risk:** Medium. The test intention is sound but the implementation of the Repo-state
check weakens the regression guard in integration runs.

**Recommendation:** Consider one of these approaches:
1. Move AC7/AC8 tests to a dedicated test module that is always tagged `@moduletag :unit`
   and excluded from integration test runs, so the absence-of-Repo path is always
   exercised in the correct environment.
2. Use `Application.put_env` to force a `nil` Repo state instead of branching on
   `Process.whereis` — this decouples the test from the actual process registry state.
3. At minimum, add an assertion in the `if` branch that the safe-query guard is NOT
   bypassed even when Repo is present (i.e. that `revoke/3` does not propagate a DB
   error as an exception). This is weaker but still adds value in integration mode.

---

### IMPROVEMENT — AC2: "no ETS back-population" assertion is valuable but should be documented as intentional design

**File:** `server/test/nebu/web/token_denylist_integration_test.exs`, lines 183–201

**Test:** `[P0] revoked? does NOT back-populate ETS after a DB hit`

This is a strong test — it verifies that a DB hit on cache miss does NOT cache the result
back to ETS. This prevents the ETS from growing unboundedly during a restart recovery
phase. However, the story's AC2 text does not explicitly prohibit back-population ("DB
read on cache miss"), so a developer could reasonably implement back-population as an
optimization and be surprised when this test fails.

**Recommendation:** Add a comment to the test explaining WHY back-population is prohibited
(ETS would re-fill silently, masking the fact that the DB is the authoritative store;
also during a rolling restart all entries would flood ETS). This turns a surprising
assertion into a self-documenting design decision.

---

## Integration Tag Verification

- `TokenDenylistIntegrationTest`: `@moduletag :integration` — PRESENT on line 29. Correct.
- `TokenDenylistDurabilityTest`: No `@moduletag :integration` — CORRECT; these are pure
  unit tests that must run in `mix test` without a DB.

---

## Red/Green Phase Verification

The file header (`@moduledoc`) of `TokenDenylistIntegrationTest` explicitly states:
> "These integration tests MUST FAIL until the implementation is complete because the
> current `TokenDenylist` module does NOT write to or read from PostgreSQL."

All P0 integration tests in `TokenDenylistIntegrationTest` will fail today because:
- `revoke/3` only writes to ETS (verified against `server/lib/nebu/web/token_denylist.ex`)
- `revoked?/2` only reads from ETS

The `TokenDenylistDurabilityTest` tests for AC3/AC7/AC8 will **pass** today, as documented
in the `@moduledoc`. Their role as regression guards post-implementation is clearly noted.

---

## Schema Compatibility Verification

The `invalidated_tokens` table schema (from `server/priv/migrations/000001_init.up.sql`):

```sql
CREATE TABLE invalidated_tokens (
    token_hash  TEXT    PRIMARY KEY,
    expires_at  BIGINT  NOT NULL
);
```

The integration tests use:
- `INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2)` — COMPATIBLE
- `SELECT token_hash, expires_at FROM invalidated_tokens WHERE token_hash = $1` — COMPATIBLE
- `expires_at` stored/compared as integer (unix seconds) — COMPATIBLE with `BIGINT`

No migration is required for the story. Schema is pre-existing and compatible.

---

## Test Quality Assessment

| Criterion                                    | Status    |
|----------------------------------------------|-----------|
| No hard waits (`Process.sleep`)              | PASS — none found |
| Deterministic (no timing dependencies)       | PASS |
| No cookie forging                            | PASS (not applicable) |
| No DB-seeding shortcuts bypassing prod code  | PASS — DB helpers only used for direct verification and pre-conditions, not to bypass `revoke/3` |
| `@moduletag :integration` on DB tests        | PASS |
| Unique test data per test (no cross-test pollution) | PASS — `System.unique_integer([:positive])` used throughout |
| `on_exit` cleanup registered                 | PASS — each test registers DB row cleanup |
| `async: false` on stateful tests             | PASS — both modules use `async: false` |
| ETS cleanup in setup and on_exit             | PASS |

---

## Existing Tests Regression Risk

**`TokenDenylistTest`** (6 tests): Tests operate on ETS only. The new implementation will
add DB writes alongside ETS writes. Since tests run without `@moduletag :integration`,
`Nebu.Repo` will not be started. The new `revoke/3` must not crash when Repo is absent
(AC7). If the `safe_query` guard is correctly implemented, all 6 existing tests remain
green. If not, they will fail — which is the correct outcome (the regression guard works).

**`OidcPlugTest`** (denylist tests, lines 488–567): These exercise `TokenDenylist.revoke/3`
indirectly via the plug. They run without `@moduletag :integration`, so the same AC7
guard requirement applies.

---

## Verdict

**PASS. Proceed to implementation (Gate 2).**

The two MINOR findings should be addressed during implementation (not as blockers to
starting dev), in the order:
1. MINOR-2 first — clarify/improve the AC7/AC8 Repo-state branching logic to ensure the
   regression guard is effective in the integration profile.
2. MINOR-1 second — align the ETS key format used in the AC3 direct-insert helper with
   whatever key format the implementation settles on for the ETS store.
