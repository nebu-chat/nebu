# Test Review Report — server/test/nebu/web/oidc_claims_test.exs

**Scope:** Staged file only — `server/test/nebu/web/oidc_claims_test.exs` (new, 307 lines, 34 tests, `async: true`). Story: `centralize-claim-resolution` (epic `oidc-simplification`, type: refactor, no `ui: true`, no GenServer/state involved).

## AC coverage

**AC1 — `Nebu.Web.OidcClaims` module exposes `claim_value_matches?/2` and `flatten_discovered_claims/2`**
Covered extensively — 28 of 34 tests target these two functions directly: flat match, list match, nested map match (1 and 2 levels, Keycloak-shaped `realm_access.roles` / `resource_access.<client>.roles`), list-of-maps, empty containers, non-binary scalars, dot-path key generation, prefix handling, empty-string exclusion, and de-dup-is-caller's-job semantics. PASS — well covered.

**AC2 — Admin delegates, behavior byte-identical**
Not testable from this file (correctly out of scope — new unit-test file for the extracted module, not the admin-level regression suite). Independently confirmed by the reviewer reading `server/test/nebu/admin/admin_oidc_login_test.exs:276-368`:
- `admin_claim?/1` tested against `realm_access.roles` (1-level), `resource_access.<client>.roles` (2-level), a negative case, flat `groups`/`role` backward-compat, and an "accepted risk" nested-claim case.
- `extract_discovered_claims/1` tested against the same nested shapes, verifying dot-path keys.

Confirms the ATDD agent's prior claim: a regression in nested-claim handling would be caught by this existing suite without expectation-value changes once dev-story wires up delegation. PASS — genuinely verifiable, independently confirmed.

**AC3 — Recursion-depth-limit rationale survives as a code comment**
Not directly assertable by ExUnit. Two 200-level-deep nesting tests act as a behavioral proxy (no stack overflow/crash), but do NOT verify the comment itself — that must be checked by a human/reviewer reading the new `oidc_claims.ex` file once it exists (code-review-time check).

## Determinism / brittleness
None found. No hard waits, no time-based logic, no I/O, no selectors. `async: true` safe (pure/stateless module under test).

## Findings

| # | Severity | Finding |
|---|----------|---------|
| 1 | INFO | AC2/AC3 intentionally not assertable within this file; docstring explains why and scopes verification elsewhere. Good practice. |
| 2 | INFO | Story text and test-file docstring cite `auth_test.exs` as part of the AC2 regression net, but `server/test/nebu/admin/auth_test.exs` has ZERO claim-traversal tests — actual coverage lives entirely in `admin_oidc_login_test.exs`. Flag for dev-story author: don't rely on `auth_test.exs` for this guarantee; verify via `admin_oidc_login_test.exs` instead. No action needed on the staged test file itself. |
| 3 | INFO | No hard waits, no non-determinism, no brittle selectors — clean pure-function unit tests. |
| 4 | INFO | 200-level-deep nesting test is a reasonable proxy for AC3 but does not verify comment survival — must still be checked by reviewing `oidc_claims.ex` diff once dev-story completes. |

**No MAJOR or MINOR findings.** Gate: CLEAN (0 MAJOR). Proceeding to dev-story.

Dev-story note: when moving the SEC-NOTE / no-depth-limit comment blocks (auth.ex:1079-1097 and :1115-1123) into `oidc_claims.ex`, verify AC3 by direct diff read — tests cannot assert this.
