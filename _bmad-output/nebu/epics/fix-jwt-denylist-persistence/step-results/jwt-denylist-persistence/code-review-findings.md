# Code Review Findings — jwt-denylist-persistence

**Date:** 2026-06-23
**Epic:** fix-jwt-denylist-persistence
**Story:** jwt-denylist-persistence
**Cycle:** 0 (first review)
**Reviewer layers:** Blind Hunter · Edge Case Hunter · Acceptance Auditor
**Files reviewed:**
- `server/lib/nebu/web/token_denylist.ex`
- `server/test/nebu/web/token_denylist_integration_test.exs`

---

## Summary

> **Code review complete.** 0 `decision-needed`, 3 `patch`, 2 `defer`, 5 dismissed as noise.

All nine acceptance criteria are correctly implemented in the production code. Three patch findings were surfaced — one MEDIUM correctness issue and two LOW/MINOR gaps. No CRITICAL or HIGH blockers. The implementation is correct for the stated ACs and safe to ship with the patches below applied.

---

## Triage Results

### Dismissed (noise / false positive)

| # | Finding | Reason |
|---|---|---|
| D1 | Blind Hunter #1 — "CRITICAL: ETS failure skips DB write, causing auth bypass" | After tracing carefully: `rescue ArgumentError` in `revoke/3` fires only when ETS insert raises `ArgumentError`. In that scenario `db_revoke` is also skipped. But `ArgumentError` from `:ets.insert` is only raised if the table is `protected`/`private` — the table is created `:public`, and `ensure_table()` re-creates it idempotently. In practice this rescue only fires during the table-creation race which `ensure_table` already handles. The Acceptance Auditor's FINDING-1 is the more precise framing of a related-but-narrower version — see Patch #1 below. The "CRITICAL auth bypass" framing is overstated. |
| D2 | Blind Hunter #2 — "CRITICAL: DB write failure → auth bypass after restart" | This is the explicitly accepted trade-off documented in the `@moduledoc`: DB write is best-effort. Auth bypass on DB write failure + restart is acknowledged design; AC7 says `:ok` is returned, not that DB failure is surfaced. Not a finding. |
| D3 | Blind Hunter #3 — "HIGH: TOCTOU race in ensure_table / ETS access" | `init_table()` is called eagerly from `Nebu.Application.start/2` — the Application master process owns the table and never crashes independently of the VM. The lazy race is not reachable in production. Dismissed. |
| D4 | Blind Hunter #10 — "Integration test @moduletag commented out" | False positive. `@moduletag :integration` IS present at line 29 of the test file. The blind hunter misread the `@moduledoc` comment. |
| D5 | Edge Case Hunter #8 — "jti reuse with ON CONFLICT DO NOTHING ignores later exp" | The `invalidated_tokens` schema has no `updated_at` or `exp` update path by design (ADR-018, Go parity). Revoking the same jti twice is idempotent by spec. The second revoke's `exp` being ignored is correct: a JWS `jti` uniquely identifies a token issuance, so two different tokens can't legitimately share a jti. |

### Deferred (pre-existing / out of scope)

| # | Finding | Reason |
|---|---|---|
| W1 | Edge Case Hunter #4 — Two sequential DB queries on every ETS miss (double round-trip) | Expected behavior per design: `db_revoked_any?` must check both key forms because different nodes may have stored different forms. In the common case the short-circuit `or` means only one query fires. Performance optimization (single query checking both keys via OR) is a valid future improvement but not a regression introduced by this story. Deferred. |
| W2 | Edge Case Hunter #7 — ETS ownership: if the process that "won" the creation race dies, the table is deleted | Not applicable: `init_table()` is called from `Nebu.Application.start/2`. The Application master process owns the table for the lifetime of the VM. The lazy-creation path in `ensure_table` is a fallback, but the table is always pre-created at boot. Deferred as a theoretical concern only if boot order is ever changed. |

---

## Patch Findings

### PATCH-1 — MEDIUM: `rescue ArgumentError` scope in `revoke/3` covers `db_revoke/2`, causing DB write to be silently skipped on an ETS insert failure

**AC violated:** AC7 ("ETS still written, no crash") — the rescue is correct for the "no crash" part, but the scope is too broad: if `:ets.insert` raises, `db_revoke` is also silently skipped, so the DB write is lost.

**File:** `server/lib/nebu/web/token_denylist.ex` — `revoke/3` (lines 85–93)

**Current code:**
```elixir
def revoke(jti, token, exp) when is_integer(exp) do
  ensure_table()
  :ets.insert(@table, {key(jti, token), exp})
  db_revoke(db_key(jti, token), exp)
  :ok
rescue
  ArgumentError -> :ok
end
```

**Problem:** If `:ets.insert` raises `ArgumentError` (e.g., table is unexpectedly absent), the rescue catches it and returns `:ok` immediately — `db_revoke` is never called. The token is not persisted anywhere.

**Fix:** Compute the DB key before the ETS insert, then ensure `db_revoke` runs independently of the ETS result:
```elixir
def revoke(jti, token, exp) when is_integer(exp) do
  ensure_table()
  db_k = db_key(jti, token)

  try do
    :ets.insert(@table, {key(jti, token), exp})
  rescue
    ArgumentError -> :ok
  end

  db_revoke(db_k, exp)
  :ok
end
```
This guarantees `db_revoke` is always called, preserving persistence even if the ETS write fails.

---

### PATCH-2 — LOW: Silent no-op when `revoke/3` is called with `jti = nil` and `token = ""` (or both nil/empty)

**AC violated:** AC1 (DB write on revoke) and AC7 (ETS written) — neither is performed when both key sources are absent/empty, but `:ok` is returned.

**File:** `server/lib/nebu/web/token_denylist.ex` — `key/2` and `hash_key/1` (lines 135–144)

**Problem:** `key(nil, "")` returns `nil` because `hash_key("")` returns `nil` (guard `token != ""`). `:ets.insert(@table, {nil, exp})` inserts a `nil`-keyed entry that `revoked?` can never match (both `revoked_key?(nil)` paths return `false`). Similarly, `db_key(nil, "")` returns `nil` and `db_revoke(nil, _)` is a no-op. The caller receives `:ok` but nothing was actually revoked.

This is an edge case only reachable if a caller passes an empty-string token with no jti. The real logout path (`protected.ex:136`) passes the verified compact JWS, which is always non-empty. However, the silent failure mode is worth guarding.

**Fix:** Add a guard that returns early (still `:ok` — the token is un-revocable with no key material) or logs a warning:
```elixir
def revoke(jti, token, exp) when is_integer(exp) do
  ensure_table()
  k = key(jti, token)

  if k == nil do
    Logger.warning("TokenDenylist.revoke called with no usable key — jti and token are absent/empty")
    :ok
  else
    # ... rest of implementation
  end
end
```

Alternatively, add `when token != ""` (or similar) to the function head guards. The important thing is the silent no-op is made visible.

---

### PATCH-3 — LOW: Test helper `insert_db_row/2` uses `ON CONFLICT DO NOTHING` without a conflict target column

**AC violated:** AC9 (existing tests green) — not a regression risk today, but a latent brittleness.

**File:** `server/test/nebu/web/token_denylist_integration_test.exs` — `insert_db_row/2` (line 55)

**Current code:**
```elixir
defp insert_db_row(token_hash, expires_at) do
  Ecto.Adapters.SQL.query!(
    Nebu.Repo,
    "INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT DO NOTHING",
    [token_hash, expires_at]
  )
end
```

**Problem:** `ON CONFLICT DO NOTHING` without a column target relies on any unique constraint violation to trigger the no-op. The production `invalidated_tokens` table has `token_hash TEXT PRIMARY KEY` as its only unique constraint, so this works today. But the production code uses `ON CONFLICT (token_hash) DO NOTHING` (explicit target). The test helper should match for consistency and to make the intent clear.

**Fix:**
```elixir
"INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT (token_hash) DO NOTHING"
```

---

## Test Coverage Alignment (bmad-testarch-test-review)

| AC | Test name | Priority | Status |
|----|-----------|----------|--------|
| AC1 | `[P0] revoke writes jti key to invalidated_tokens table` | P0 | Covered |
| AC1 | `[P0] revoke without jti writes bare SHA-256 hex key` | P0 | Covered |
| AC1 | `[P0] revoke is idempotent — ON CONFLICT DO NOTHING` | P0 | Covered |
| AC2 | `[P0] revoked? returns true on DB hit when ETS is cold` | P0 | Covered |
| AC2 | `[P0] revoked? does NOT back-populate ETS after a DB hit` | P0 | Covered |
| AC3 | `[P0] revoked? returns true from ETS without needing the DB` | P0 | Covered |
| AC3 | `[P0] ETS fast path does not crash when Repo may be absent` | P0 | Covered |
| AC4 | `[P0] token revoked before restart is still rejected after ETS is cleared` | P0 | Covered |
| AC5 | `[P0] DB key for jti token is the string 'jti:<jti_value>'` | P0 | Covered |
| AC5 | `[P0] DB key for no-jti token is the bare SHA-256 hex string` | P0 | Covered |
| AC6 | `[P1] revoked? returns false for an expired DB row` | P1 | Covered |
| AC7 | `[P1] revoke returns :ok when Repo is not started (no crash)` | P1 | Covered |
| AC7 | `[P1] ETS entry is written even when Repo is not started` | P1 | Covered |
| AC8 | `[P1] revoked? returns false when Repo absent and token not in ETS` | P1 | Covered |
| AC8 | `[P1] ETS positive result is unaffected regardless of Repo state` | P1 | Covered |

**Coverage: 15/15 (100% of P0+P1 criteria).**

No AC has zero test coverage. All P0 criteria are covered by integration-tagged tests. All P1 criteria are covered by unit-level tests.

**Test review observations:**
- No hard waits or flaky patterns detected.
- Tests use `on_exit/1` for cleanup — correct.
- `async: false` is correct since tests share the global ETS table.
- The `TokenDenylistDurabilityTest` correctly detects whether Repo is running (integration vs unit environment) and branches accordingly in AC7 tests — this is slightly unconventional but sound given the test must work in both environments.

---

## Pre-dev Carry-through Findings

| Finding | Status |
|---------|--------|
| MINOR-1: ETS keys as tuples, DB keys as strings — different namespaces | Resolved. `{:jti, x}` / `{:hash, x}` in ETS; `"jti:x"` / `"<hex>"` in DB. Consistent and correct. |
| MINOR-2: `safe_query` uses `Process.whereis(Nebu.Repo)` guard | Resolved. Pattern matches `MatrixSessionStore.safe_query/2` exactly. |

---

---

## Cycle 1 Re-Review — Patch Verification

**Date:** 2026-06-23
**Cycle:** 1 (re-review after dev applied 3 patches from cycle 0)
**Reviewer:** Code Review Agent

### Patch verification

#### PATCH-1 — `revoke/3`: `try/rescue` wraps only `:ets.insert`; `db_revoke` called unconditionally after rescue block

**Status: CORRECTLY APPLIED.**

Lines 94–101 of `server/lib/nebu/web/token_denylist.ex`:
```elixir
try do
  :ets.insert(@table, {k, exp})
rescue
  ArgumentError -> :ok
end

# AC1, AC7: persist to DB (best-effort — never crash on DB failure)
db_revoke(db_k, exp)
```

The `try/rescue` block is narrowly scoped to `:ets.insert`. `db_revoke(db_k, exp)` is at line 101, outside the try/rescue, within the `else` branch of the `k == nil` guard. It will execute regardless of whether the ETS insert raised or succeeded. AC1 and AC7 are correctly satisfied.

**No regression introduced by this patch.**

---

#### PATCH-2 — Early-return guard when `key(jti, token) == nil`; warning logged

**Status: CORRECTLY APPLIED.**

Lines 90–93 of `server/lib/nebu/web/token_denylist.ex`:
```elixir
if k == nil do
  Logger.warning("TokenDenylist.revoke called with no usable key — token cannot be revoked")
  :ok
else
  ...
end
```

The guard correctly uses `k == nil` (not `k === nil` — both are equivalent in Elixir for `nil`). The warning is logged via `Logger.warning/1`. The `:ok` early return is correct per AC7.

**Symmetry observation (no bug):** `key/2` and `db_key/2` share identical guard conditions — both return nil for the same input combinations. Therefore `k == nil` iff `db_k == nil`. When the `else` branch executes (line 93), `db_k` is guaranteed non-nil, making `db_revoke(db_k, exp)` at line 101 safe. The `defp db_revoke(nil, _exp), do: :ok` clause at line 189 is now dead code on the `revoke/3` path — this is harmless defensive programming.

**No regression introduced by this patch.**

---

#### PATCH-3 — Test helper `insert_db_row/2`: explicit conflict target `ON CONFLICT (token_hash) DO NOTHING`

**Status: CORRECTLY APPLIED.**

Line 55 of `server/test/nebu/web/token_denylist_integration_test.exs`:
```elixir
"INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT (token_hash) DO NOTHING"
```

The explicit conflict target `(token_hash)` is now present, matching the production SQL. No regression.

---

### Acceptance Criteria — final status after patches

| AC | Description | Status |
|----|-------------|--------|
| AC1 | DB write on revoke | SATISFIED — `db_revoke(db_k, exp)` runs unconditionally in the `else` branch (PATCH-1) |
| AC2 | DB read on cache miss | SATISFIED — `db_revoked_any?/2` fallback intact; no changes in this cycle |
| AC3 | ETS fast path preserved | SATISFIED — ETS check in `revoked?/2` unchanged; PATCH-1/2 do not affect the read path |
| AC4 | Restart survival | SATISFIED — DB persistence guaranteed (PATCH-1 ensures DB write always runs) |
| AC5 | Key encoding correct | SATISFIED — ETS tuple vs DB string distinction unchanged |
| AC6 | Lazy DB expiry | SATISFIED — `expires_at > $now` predicate unchanged |
| AC7 | Best-effort DB write (no crash) | SATISFIED — `safe_query` wrapper intact; early return on nil key (PATCH-2) |
| AC8 | Best-effort DB read (no crash) | SATISFIED — `rescue ArgumentError -> false` on `revoked?/2` unchanged |
| AC9 | No regressions | SATISFIED — all three patches are narrowly scoped; no new logic paths introduced |

### New findings from cycle 1

**None.** The three patches are minimal, correct, and do not introduce any new issues.

The only observation worth noting (not a finding): the `defp db_revoke(nil, _exp), do: :ok` clause at line 189 is now dead code on the `revoke/3` call path, since PATCH-2 ensures `db_revoke` is never called with `nil` inside `revoke/3`. It remains as harmless defensive code and its removal would be an out-of-scope cleanup. Not raised as a patch.

### Cycle 1 verdict

**APPROVED — all patches correctly applied, no regressions, no new findings.**

---

## Security Assessment

**Can the denylist be bypassed?**

- **Logout no-op regression:** Not present. `revoke/3` writes to both ETS and DB. After a restart, `revoked?` correctly falls back to DB.
- **Key collision risk:** None. ETS uses tagged tuples (`{:jti, x}`, `{:hash, x}`); DB uses prefixed strings (`"jti:x"`) or 64-char hex. Namespaces are disjoint.
- **Timing attack on key comparison:** Not applicable. `revoked?` is a lookup by exact key, not a secret comparison.
- **Clock manipulation via `exp`:** If an attacker can manipulate `exp` passed to `revoke/3`, they could make a revocation appear expired immediately. This value comes from `claims["exp"]` in `protected.ex` which is derived from the verified JWT — not user-controllable.
- **Cluster race on DB write failure:** If the DB write fails silently (AC7), a token is only in ETS. After a node restart that clears ETS, the token passes `revoked?`. This is the documented and accepted trade-off. Mitigated by: (a) the warning log on DB failure, and (b) short OIDC token lifetimes meaning the window is bounded.

**Overall security posture:** No exploitable bypass discovered. The DB persistence layer is correctly implemented and closes the restart-survival gap that was the motivation for this story.
