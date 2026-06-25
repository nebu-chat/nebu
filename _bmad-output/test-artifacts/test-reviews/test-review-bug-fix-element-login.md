---
stepsCompleted:
  - step-01-load-context
  - step-02-discover-tests
  - step-03-quality-evaluation
  - step-03f-aggregate-scores
  - step-04-generate-report
lastStep: step-04-generate-report
lastSaved: '2026-06-25'
reviewScope: single
overallScore: 99
overallGrade: A
recommendation: APPROVE
---

# Test Quality Review — bug-fix-element-login

**File:** `server/test/nebu/matrix/sso_login_scope_test.exs`
**Date:** 2026-06-25
**Scope:** Single file — RED-phase ATDD for bug `fix-element-login`
**Reviewer:** Master Test Architect (TEA)
**Overall Score:** 99/100 (A)
**Recommendation:** APPROVE

---

## Executive Summary

The test file is well-crafted, correctly structured for a RED-phase ATDD suite, and follows
established project conventions precisely. It mirrors the `sso_scope_mode_test.exs` idiom,
tests the observable public surface rather than a private function, and uses the existing
`:matrix_oidc_refresh_mode_reader` seam correctly.

**Strengths:**

- All 4 acceptance criteria are mapped 1:1 to `describe` blocks — full AC coverage.
- No hard waits, no conditional flow, no randomness — fully deterministic.
- Isolation is correct: `async: false` with `on_exit` cleanup for all mutated `Application.put_env` keys.
- Failure messages include `inspect(scopes)` — actionable debugging output.
- Explicitly documents the RED/GREEN status of each test case — valuable for a future reviewer.
- AC2 covers both string and list input formats for `:oidc_extra_scopes` — good edge-case coverage.
- AC2 includes a duplicate-scope deduplication test — catches a real regression vector.

**Weaknesses / Improvement opportunities:**

- One INFO-level observation about `on_exit` ordering (harmless — see below).
- No integration-tagged companion block (analogous to `sso_scope_mode_test.exs` lines 192–242) —
  acceptable for a bug-fix; the unit suite is sufficient for the stated ACs.

---

## Quality Dimension Scores

| Dimension     | Score | Grade | Weight |
|---------------|-------|-------|--------|
| Determinism   | 100   | A     | 30%    |
| Isolation     | 100   | A     | 30%    |
| Maintainability | 97  | A     | 25%    |
| Performance   | 100   | A     | 15%    |
| **Overall**   | **99**| **A** |        |

---

## AC Coverage Matrix

| AC  | Requirement                                                                                              | Tests                                                                  | Status  |
|-----|----------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------|---------|
| AC1 | No extra scopes → `"openid"` (online) or `"openid offline_access"` (offline); profile/email MUST NOT appear | 2 tests (online + offline base scope checks)                          | COVERED |
| AC2 | `:oidc_extra_scopes = "profile email"` → profile+email appear additively                                | 4 tests (string, list, dedup, arbitrary scopes)                       | COVERED |
| AC3 | offline/online toggle unchanged after base-scope reduction                                               | 3 tests (offline, online, nil→offline default)                        | COVERED |
| AC4 | Regression guard: base scope is exactly `["openid"]` (online) / `["openid","offline_access"]` (offline) | 2 explicit equality assertions with `Enum.sort` for order-independence | COVERED |

**AC Coverage Gate: PASSED. All 4 ACs have at least one test. No MAJOR finding.**

---

## Quality Criteria Assessment

| Criterion                      | Status | Notes                                                                 |
|-------------------------------|--------|-----------------------------------------------------------------------|
| Hard waits                     | PASS   | None present                                                          |
| Conditionals in tests          | PASS   | None present                                                          |
| Test length (<300 lines)       | PASS   | 273 lines                                                             |
| Deterministic                  | PASS   | Seam-controlled; no randomness or time-dependency                     |
| Isolation                      | PASS   | `async: false`, full `on_exit` cleanup for all `Application.put_env` keys |
| Explicit assertions            | PASS   | All `assert`/`refute` in test bodies; `scope_params/0` is data extraction only |
| Failure messages               | PASS   | Every assertion includes `inspect(scopes)`                            |
| Crash/restart test             | N/A    | `scope_list/0` is stateless (Persistenz Option C) — noted in `@moduledoc` |
| Playwright/UI tests            | N/A    | Pure HTTP/protocol; no UI surface                                     |
| GenServer state                | N/A    | Not applicable                                                        |

---

## Findings

### INFO-1 — `on_exit` LIFO ordering in AC3 nil-seam test (no action required)

**Severity:** INFO
**Location:** `sso_login_scope_test.exs`, lines 229–241

**Observation:** The test registers a local `on_exit` to restore the prior
`:matrix_oidc_refresh_mode_reader` value, and `setup_oidc/0` (called in `setup`) also registers
an `on_exit` that deletes that key. ExUnit fires `on_exit` callbacks in LIFO order — the
test-local cleanup runs first (restoring `prev`), then `setup_oidc`'s cleanup runs and deletes
the key. Net state: the key is deleted. This is correct and matches the intent.

The pattern is identical to what the existing `sso_scope_mode_test.exs` uses (line 155–163).
No change needed.

---

### INFO-2 — No `@moduletag :integration` companion block (no action required)

**Severity:** INFO

`sso_scope_mode_test.exs` includes a companion `:integration`-tagged describe block that tests
the live DB path. The new file covers only the unit (seam-injected) path. For a bug fix targeting
a pure configuration change, unit coverage is sufficient. The existing
`sso_scope_mode_test.exs` integration block already verifies the DB read path.
No change needed.

---

### INFO-3 — AC2 "currently GREEN" annotation should be verified post-fix

**Severity:** INFO
**Location:** Lines 163–167

The comment correctly notes that AC2 is currently passing before the fix (because `profile`/`email`
happen to be in `@base_scopes`). After the fix, AC2 should remain GREEN because the extra scopes
are appended additively. The implementer should verify this during the green phase — no test
change needed.

---

## Positive Patterns

1. **Testing private behavior through the public surface** — `scope_list/0` is `defp`, but the
   test drives the 302 redirect and inspects the `scope` query param. Correct approach, consistent
   with project convention.

2. **Seam injection without DB** — Using `:matrix_oidc_refresh_mode_reader` means the test suite
   has zero DB dependency. Fast, deterministic, and consistent with the existing
   `OidcClaimCache` `:oidc_claim_reader` and `:admin_bootstrap_store` patterns.

3. **AC4 regression guard** — The exact-equality assertion (`assert scopes == ["openid"]`) is an
   explicit regression guard against the old `~w(openid profile email)` value being accidentally
   reintroduced.

4. **Order-independent assertion** — The offline AC4 test uses
   `Enum.sort(scopes) == Enum.sort(["openid", "offline_access"])` to avoid false failures from
   scope ordering.

---

## Knowledge Base References

- `test-quality.md` — Core quality DoD: no hard waits, determinism, isolation, explicit assertions
- `test-levels-framework.md` — Unit vs. integration selection
- `data-factories.md` — Seam-based data injection (analog of factory pattern in Elixir)
- `test-healing-patterns.md` — `async: false` for shared application env

---

## Completion Summary

- **Scope reviewed:** Single file, 273 lines, 10 tests across 4 describe blocks
- **Overall score:** 99/100 (A)
- **Critical blockers:** None
- **MAJOR findings:** 0
- **MINOR findings:** 0
- **INFO findings:** 3 (all no-action)
- **Recommendation:** APPROVE — proceed to implementation (`/bmad-dev-story`)
- **Next workflow:** After green-phase implementation, run `/bmad-code-review` per Gate 3
