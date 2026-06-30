---
stepsCompleted: ['step-01-preflight-and-context', 'step-02-generation-mode', 'step-03-test-strategy', 'step-04-generate-tests', 'step-04c-aggregate', 'step-05-validate-and-complete']
lastStep: 'step-05-validate-and-complete'
lastSaved: '2026-06-17'
storyId: 'element-web-oidc-sso-login-fix'
storyKey: 'element-web-oidc-sso-login-fix'
storyFile: 'docs/stories/bugfix-element-spinner/element-web-oidc-sso-login-fix.md'
atddChecklistPath: '_bmad-output/test-artifacts/atdd-checklist-element-web-oidc-sso-login-fix.md'
generatedTestFiles:
  - gateway/internal/matrix/oidc_discovery_test.go
  - gateway/cmd/gateway/login_revoke_test.go
  - gateway/cmd/gateway/dex_proxy_test.go
  - gateway/cmd/gateway/profile_ratelimit_test.go
  - e2e/features/element/login.feature
  - e2e/step-definitions/element/login.steps.ts
inputDocuments:
  - _bmad/tea/config.yaml
  - gateway/internal/matrix/oidc_discovery.go
  - gateway/internal/middleware/ratelimit.go
  - e2e/features/element/login.feature
  - e2e/step-definitions/element/login.steps.ts
tddPhase: RED
---

# ATDD Checklist — Element Web OIDC SSO Login Fix

**Story:** Element Web OIDC SSO Login Fix  
**Story Key:** element-web-oidc-sso-login-fix  
**Date:** 2026-06-17  
**TDD Phase:** RED (tests written before / alongside implementation)

---

## Step 1: Preflight & Context

**Stack Detected:** fullstack (Go gateway + Elixir core + Playwright E2E)

**Prerequisites verified:**
- [x] Acceptance criteria clear (6 ACs with matrix spec requirements)
- [x] `playwright.config.ts` present (`e2e/playwright.config.ts`)
- [x] Go test framework configured (`gateway/go.mod`)
- [x] `patchMetadata` function exists in `oidc_discovery.go` — tests extend existing file

**Story Key:** `element-web-oidc-sso-login-fix`

---

## Step 2: Generation Mode

**Mode selected:** AI Generation  
**Reason:** Acceptance criteria are well-defined; no browser recording needed (selectors from existing login.steps.ts patterns; E2E scenario extends existing feature file).

---

## Step 3: Test Strategy

| AC | Test Level | Priority | File | Status |
|----|-----------|----------|------|--------|
| AC2 — revocation_endpoint injected | Go unit (`patchMetadata`) | P0 | `gateway/internal/matrix/oidc_discovery_test.go` | Generated |
| AC3 — dex:5556 rewritten in endpoints | Go unit (`patchMetadata`) | P0 | same | Generated |
| AC3 — issuer NOT rewritten | Go unit (`patchMetadata`) | P0 | same | Generated |
| AC2 edge — revocation uses requestHost | Go unit (`patchMetadata`) | P0 | same | Generated |
| AC4 — POST /login/revoke returns 200 {} | Go httptest unit | P0 | `gateway/cmd/gateway/login_revoke_test.go` | Generated |
| AC4 — Content-Type application/json | Go httptest unit | P1 | same | Generated |
| AC4 — no auth required | Go httptest unit | P1 | same | Generated |
| AC4 — ignores RFC 7009 body | Go httptest unit | P1 | same | Generated |
| AC6 — OPTIONS /dex/ returns 204 + CORS | Go httptest unit | P0 | `gateway/cmd/gateway/dex_proxy_test.go` | Generated |
| AC6 — GET /dex/ response has CORS header | Go httptest unit | P0 | same | Generated |
| AC6 — OPTIONS no body | Go httptest unit | P1 | same | Generated |
| AC6 — POST passthrough works | Go httptest unit | P1 | same | Generated |
| AC5 — profile on looseRL, 20 concurrent OK | Go unit (rate limiter) | P1 | `gateway/cmd/gateway/profile_ratelimit_test.go` | Generated |
| AC5 — mediumRL exhausts at 10 (negative) | Go unit (rate limiter) | P1 | same | Generated |
| AC1 — Element Web login reaches room list | Playwright+Gherkin E2E | P0 | `e2e/features/element/login.feature` | Generated |

---

## Step 4: Generated Test Files

### 4A — API / Unit Tests

#### `gateway/internal/matrix/oidc_discovery_test.go` (extended)

New tests added (all patchMetadata unit tests, AC2/AC3):

| Test | AC | Priority | RED Reason |
|------|----|----------|-----------|
| `TestPatchMetadata_InjectsRevocationEndpoint` | AC2 | P0 | patchMetadata must inject revocation_endpoint |
| `TestPatchMetadata_NoDexHostInResponse` | AC3 | P0 | endpoint fields must not contain dex:5556 |
| `TestPatchMetadata_IssuerNotRewritten` | AC3 | P0 | issuer must stay unchanged (JWT iss match) |
| `TestPatchMetadata_RevocationEndpointUsesRequestHost` | AC2 | P0 | injected endpoint must use requestHost |
| `TestPatchMetadata_InvalidJSON` | defensive | P2 | must not panic on invalid input |

**Note:** All 5 tests PASS — `patchMetadata` was already implemented. These serve as regression tests.

#### `gateway/cmd/gateway/login_revoke_test.go` (new)

| Test | AC | Priority | RED Reason |
|------|----|----------|-----------|
| `TestLoginRevokeStub_Returns200` | AC4 | P0 | stub handler must return 200 {} |
| `TestLoginRevokeStub_ContentTypeJSON` | AC4 | P1 | RFC 7009 requires JSON content type |
| `TestLoginRevokeStub_NoAuthRequired` | AC4 | P1 | must work without Authorization header |
| `TestLoginRevokeStub_IgnoresBody` | AC4 | P1 | must silently accept any RFC 7009 body |

**Note:** All 4 tests PASS — stub handler is already wired in main.go.

#### `gateway/cmd/gateway/dex_proxy_test.go` (new)

| Test | AC | Priority | RED Reason |
|------|----|----------|-----------|
| `TestDexProxy_OptionsPreflight` | AC6 | P0 | OPTIONS must return 204 + 3 CORS headers |
| `TestDexProxy_CORSHeaders` | AC6 | P0 | GET response must carry ACAO: * |
| `TestDexProxy_OptionsReturnsNoBody` | AC6 | P1 | 204 must have no response body |
| `TestDexProxy_PostPassthrough` | AC6 | P1 | POST must not be rejected (token endpoint) |

**Note:** All 4 tests PASS — dex proxy + CORS is already implemented in main.go.

#### `gateway/cmd/gateway/profile_ratelimit_test.go` (new)

| Test | AC | Priority | RED Reason |
|------|----|----------|-----------|
| `TestProfileEndpoint_LooseRL_ConcurrentRequestsDoNotHit429` | AC5 | P1 | 20 concurrent requests must not get 429 under looseRL |
| `TestProfileEndpoint_MediumRL_ExhaustsAt10` | AC5 (negative) | P1 | Documents root cause: mediumRL (burst 10) is insufficient |

**Note:** Both tests PASS — profile endpoint is already on looseRL in main.go.

### 4B — E2E Tests

#### `e2e/features/element/login.feature` (extended)

New scenario added:

```gherkin
@ac1-oidc-no-spinner
Scenario: Element Web completes OIDC SSO login and reaches room list without spinner
  Given alex has no cached session
  When alex opens Element Web and clicks "Sign in"
  And alex authenticates via Dex with "alex@example.com"
  Then the room list is visible within 30 seconds
  And no loading spinner is visible
  And no error dialog appears
  And the URL does not contain "spinner" or "error"
```

**New step definitions added to `e2e/step-definitions/element/login.steps.ts`:**

| Step | Purpose |
|------|---------|
| `Then the room list is visible within 30 seconds` | Explicit 30s timeout for OIDC flow |
| `Then no loading spinner is visible` | Asserts .mx_Spinner is gone (3s cooldown) |
| `Then the URL does not contain {string} or {string}` | Two-fragment URL assertion |

---

## Step 5: Validation

### Coverage Matrix

| AC | Tests | Coverage |
|----|-------|---------|
| AC1 — E2E login without spinner | `@ac1-oidc-no-spinner` Gherkin scenario | ✅ |
| AC2 — revocation_endpoint present | `TestPatchMetadata_InjectsRevocationEndpoint`, `TestPatchMetadata_RevocationEndpointUsesRequestHost` | ✅ |
| AC3 — no dex:5556 in endpoints | `TestPatchMetadata_NoDexHostInResponse`, `TestPatchMetadata_IssuerNotRewritten` | ✅ |
| AC4 — POST /login/revoke returns 200 {} | `TestLoginRevokeStub_*` (4 tests) | ✅ |
| AC5 — concurrent logins no 429 | `TestProfileEndpoint_LooseRL_*`, `TestProfileEndpoint_MediumRL_*` | ✅ |
| AC6 — /dex/ CORS headers | `TestDexProxy_*` (4 tests) | ✅ |

**Coverage: 6/6 ACs covered (100%)**

### Spec Edge Cases Covered

- [x] issuer field must NOT be rewritten (Matrix spec, JWT iss match)
- [x] revocation_endpoint must use requestHost (not hardcoded localhost:8008)
- [x] OPTIONS preflight must return 204 with no body
- [x] POST /dex/token (token exchange) must pass through, not 405
- [x] No Authorization header required on /login/revoke (RFC 7009 §2.1)
- [x] patchMetadata must not panic on invalid JSON input

### TDD Red Phase Compliance

All tests in the Gherkin scenario use real browser flows (Authorization Code + PKCE, no ROPC).  
No cookie forging or DB-seeding shortcuts used.  
`no loading spinner` step uses `page.waitForTimeout(3_000)` — acceptable for UI settle (not a hard wait on a network call).

---

## Summary

- **15 Go unit tests** generated across 3 new/extended files — all currently PASS
- **1 Playwright+Gherkin E2E scenario** generated — RED phase (requires stack redeploy + all fixes in place)
- **3 new step definitions** added to login.steps.ts
- All ACs covered; all Matrix spec edge cases addressed
