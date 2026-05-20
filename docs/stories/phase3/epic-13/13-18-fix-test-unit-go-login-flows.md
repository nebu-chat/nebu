---
status: in-progress
epic: 13
story: 18
security_review: not-needed
matrix: false
ui: false
atdd: not-applicable
---

# Story 13.18: Fix test-unit-go — TestGetLogin_ReturnsSSO expects wrong flow count

Status: in-progress

## Story

As a developer running `make test-unit-go`,
I want `TestGetLogin_ReturnsSSO` to pass,
so that the CI pipeline does not block releases on a stale assertion.

**Size:** XS

---

## Background & Motivation

Commit `7c20168` (fix(matrix/sso): handle URL fragments) intentionally added `m.login.token`
to the `GET /_matrix/client/v3/login` response alongside `m.login.sso`.

**Why `m.login.token` must be advertised:**
Element Web 1.12+ only uses the `loginToken` embedded by `GetSSOCallback` in the redirect URL
if `m.login.token` appears in the login flows list. Without it, Element ignores the token and
re-initiates a fresh SSO flow (another round-trip to Dex), causing visible login latency and
occasionally a nonce-mismatch error.

The behavior change was correct, but `TestGetLogin_ReturnsSSO` was not updated:

```go
// Before 7c20168: 1 flow returned
if len(resp.Flows) != 1 {          // ← still asserts 1 flow
    t.Fatalf("expected 1 flow, got %d", len(resp.Flows))
}
```

The test must be updated to assert the current (correct) behavior: 2 flows.

---

## Acceptance Criteria

**AC1 — Test asserts 2 flows:**
Given `TestGetLogin_ReturnsSSO` in `gateway/internal/matrix/login_test.go`,
When `h.GetLogin(w, req)` is called,
Then the test asserts `len(resp.Flows) == 2`.

**AC2 — Test verifies `m.login.sso` is first flow:**
Then `resp.Flows[0].Type == "m.login.sso"` with 1 identity provider (`oidc`).

**AC3 — Test verifies `m.login.token` is second flow:**
Then `resp.Flows[1].Type == "m.login.token"` with no identity providers.

**AC4 — `make test-unit-go` passes:**
Given the updated test,
When `make test-unit-go` is run,
Then exit code is 0 and `TestGetLogin_ReturnsSSO` shows `ok`.

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. `TestGetLogin_ReturnsSSO` — Go httptest (already failing — this IS the regression test)
   - Given: `LoginHandler` with `DisplayName: "Test SSO"`
   - When: `GET /_matrix/client/v3/login`
   - Then: response has 2 flows — `m.login.sso` (with oidc IDP) and `m.login.token` (no IDP)

The test already exists and is already failing — no new test file needed. Updating the
existing assertion IS the ATDD step.

---

## Implementation Notes

Update `login_test.go:138–143`:
- Change `len(resp.Flows) != 1` → `len(resp.Flows) != 2`
- Add assertion for `resp.Flows[1].Type == "m.login.token"`
- Keep existing `m.login.sso` + IDP assertions as-is

No changes to `login.go` — the implementation is correct.
