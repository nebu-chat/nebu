---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-04c-aggregate
  - step-05-validate-and-complete
lastStep: step-05-validate-and-complete
lastSaved: '2026-06-23'
storyId: token-denylist-postgres-persistence
storyKey: token-denylist-postgres-persistence
storyFile: null
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-token-denylist-postgres-persistence.md
generatedTestFiles:
  - server/test/nebu/web/token_denylist_integration_test.exs
---

# ATDD Checklist: token-denylist-postgres-persistence

## TDD Red Phase (Current State)

Red-phase test scaffolds generated and written to disk.

| Module | Tests | Phase |
|---|---|---|
| `Nebu.Web.TokenDenylistIntegrationTest` | 10 tests | RED (`@moduletag :integration` — fail without DB write/read) |
| `Nebu.Web.TokenDenylistDurabilityTest` | 6 tests | RED (AC7/AC8) + regression guard (AC3) |

## Stack Detection

Backend — Elixir/OTP, ExUnit. No E2E (Playwright/Gherkin) tests needed: this story has no
browser-visible behaviour; it is a pure internal module persistence change.

## Generation Mode

AI generation (backend project, acceptance criteria fully specified).

## Test Strategy

| AC | Test name | Level | Priority | Red? |
|---|---|---|---|---|
| AC1 | revoke writes jti key to invalidated_tokens | integration | P0 | YES — DB write not implemented |
| AC1 | revoke without jti writes SHA-256 hex key | integration | P0 | YES |
| AC1 | revoke is idempotent — ON CONFLICT DO NOTHING | integration | P0 | YES |
| AC2 | revoked? returns true on DB hit when ETS cold | integration | P0 | YES — DB read not implemented |
| AC2 | revoked? does NOT back-populate ETS after DB hit | integration | P0 | YES |
| AC3 | revoked? returns true from ETS without DB | unit | P0 | PASSES NOW (regression guard) |
| AC3 | ETS fast path does not crash when Repo absent | unit | P0 | PASSES NOW (regression guard) |
| AC4 | token revoked before restart rejected after ETS clear | integration | P0 | YES — no DB write |
| AC5 | DB key is string "jti:<jti_value>" | integration | P0 | YES — no DB write |
| AC5 | DB key for no-jti is bare SHA-256 hex string | integration | P0 | YES — no DB write |
| AC6 | revoked? returns false for expired DB row | integration | P1 | YES — no DB read |
| AC7 | revoke returns :ok when Repo absent (no crash) | unit | P1 | PASSES NOW (regression guard) |
| AC7 | ETS entry written even when Repo absent | unit | P1 | PASSES NOW (regression guard) |
| AC8 | revoked? returns false when Repo absent, not in ETS | unit | P1 | PASSES NOW (regression guard) |
| AC8 | ETS positive result unaffected by Repo state | unit | P1 | PASSES NOW (regression guard) |
| AC9 | Existing token_denylist_test.exs tests still pass | unit | — | Pre-existing (must remain green) |

## Acceptance Criteria Coverage

| AC | Covered by | Status |
|---|---|---|
| AC1 — DB write on revoke | 3 integration tests | RED |
| AC2 — DB cache miss fallback | 2 integration tests | RED |
| AC3 — ETS fast path preserved | 2 unit tests | GREEN (regression guard) |
| AC4 — Restart survival | 1 integration test | RED |
| AC5 — Schema compatibility / key encoding | 2 integration tests | RED |
| AC6 — Lazy expiry in DB | 1 integration test | RED |
| AC7 — Best-effort DB write | 2 unit tests | GREEN (regression guard) |
| AC8 — Best-effort DB read | 2 unit tests | GREEN (regression guard) |
| AC9 — Existing tests green | Covered by existing unit tests | — |

## Generated Test Files

```
server/test/nebu/web/token_denylist_integration_test.exs
```

Two modules in one file:

* `Nebu.Web.TokenDenylistIntegrationTest` — `@moduletag :integration`, needs running Repo
* `Nebu.Web.TokenDenylistDurabilityTest` — no integration tag, runs in `mix test`

## How Tests Fail Before Implementation

The integration tests fail because `TokenDenylist.revoke/3` currently only writes to ETS:

```
# AC1 test:
assert length(rows) == 1  # → fails: rows == [] (no DB write)

# AC2 test:
assert result == true     # → fails: returns false (ETS miss, no DB fallback)

# AC4 test:
assert result == true     # → fails: returns false (ETS cleared, no DB)
```

The unit tests in `TokenDenylistDurabilityTest` (AC3, AC7, AC8) PASS NOW with the existing
ETS-only implementation — they act as regression guards to confirm the safe_query pattern
doesn't break existing behaviour when added.

## Implementation Guidance

The dev must:

1. Add `safe_query/2` guard (pattern from `MatrixSessionStore`, line 358):
   ```elixir
   defp safe_query(sql, params) do
     if Process.whereis(Nebu.Repo) do
       Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
     else
       {:error, :repo_not_started}
     end
   rescue
     e -> {:error, e}
   end
   ```

2. Add `jti_db_key/1` and `hash_db_key/1` helpers that return STRING keys (not tuples):
   ```elixir
   defp jti_db_key(jti) when is_binary(jti) and jti != "", do: "jti:" <> jti
   defp jti_db_key(_), do: nil

   defp hash_db_key(token) when is_binary(token) and token != "" do
     :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
   end
   defp hash_db_key(_), do: nil
   ```

3. In `revoke/3`: after ETS insert, call `safe_query` with INSERT … ON CONFLICT DO NOTHING.
   On `{:error, _}`: `Logger.warning(...)` and return `:ok`.

4. In `revoked?/2`: when both `revoked_key?/1` checks return false, call `safe_query`
   to look up the DB key. Return `true` if a non-expired row exists. Do NOT write back to ETS.

## Next Steps

1. Remove `@tag :skip` from tests (N/A — these are ExUnit, not Playwright; tests are NOT
   skipped but excluded via `@moduletag :integration`).
2. Run `make dev` to start the stack with Postgres.
3. Run `make test-integration` — integration tests must fail (RED confirmed).
4. Implement the DB integration in `server/lib/nebu/web/token_denylist.ex`.
5. Run `make test-integration` again — integration tests must now pass (GREEN).
6. Run `make test-unit-elixir` — unit tests in `TokenDenylistDurabilityTest` must remain green.
7. Commit.

Next recommended workflow: `/bmad-dev-story`
