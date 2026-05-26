---
story_id: 5-32
title: "Bug: Matrix SSO Callback Returns M_MISSING_PARAM on IdP Error Response"
type: bug
severity: high
epic: 5
status: done
security_review: not-needed
created: 2026-05-26
branch: bugfix/custom-scopes-in-matrix-sso
---

## Summary

When the OIDC provider (e.g. Keycloak) rejects the authorization request and redirects back with an error response (RFC 6749 §4.1.2.1), the Matrix SSO callback handler returns a confusing `M_MISSING_PARAM: redirectUrl is required` instead of a meaningful error.

**Observed behaviour:**
```
GET /_matrix/client/v3/login/sso/redirect/oidc
  ?error=invalid_scope
  &error_description=Invalid+scopes%3A+openid+profile+email+groups
  &state=9d5f1444747fdd84f7bf2329e558bcf3
  &iss=https%3A%2F%2Fidentity.innoq.io%2Frealms%2FINNOQ
→ HTTP 400 {"errcode":"M_MISSING_PARAM","error":"redirectUrl is required"}
```

**Expected behaviour:**
```
→ HTTP 403 {"errcode":"M_FORBIDDEN","error":"SSO provider rejected the authorization request: invalid_scope — Invalid scopes: openid profile email groups"}
```

## Root Cause

`GetSSOCallback` (sso.go) has a "dual-purpose" guard:

```go
code := r.URL.Query().Get("code")
state := r.URL.Query().Get("state")

// No code → treat as initiation for the "oidc" IDP.
if code == "" || state == "" {
    h.GetSSORedirect(w, r)
    return
}
```

An IdP error response carries `?error=...&state=...` but no `code`. Since `code == ""`, the handler delegates to `GetSSORedirect`, which requires `redirectUrl` — absent in the IdP callback URL — and returns `M_MISSING_PARAM`.

## Fix

Add an IdP-error check **before** the `code == "" || state == ""` guard in `GetSSOCallback`:

```go
if idpErr := r.URL.Query().Get("error"); idpErr != "" {
    idpErrDesc := r.URL.Query().Get("error_description")
    if len([]rune(idpErrDesc)) > 256 {
        idpErrDesc = string([]rune(idpErrDesc)[:256])
    }
    slog.Warn("matrix SSO: IdP returned authorization error",
        "error", idpErr,
        "error_description", idpErrDesc,
    )
    if state != "" {
        globalSSOState.pop(state) // consume state entry to prevent replay
    }
    msg := "SSO provider rejected the authorization request: " + idpErr
    if idpErrDesc != "" {
        msg += " — " + idpErrDesc
    }
    writeMatrixError(w, http.StatusForbidden, "M_FORBIDDEN", msg)
    return
}
```

Also update the `GetSSOCallback` doc comment to list IdP error responses as a third case.

## Acceptance Criteria

### AC1: IdP error with error_description returns M_FORBIDDEN
- `GET /sso/redirect/oidc?error=invalid_scope&error_description=Invalid+scopes%3A+groups&state=X`
- Returns HTTP 403 `{"errcode":"M_FORBIDDEN","error":"...invalid_scope — Invalid scopes: groups..."}`

### AC2: IdP error without error_description returns M_FORBIDDEN
- `GET /sso/redirect/oidc?error=access_denied&state=X`
- Returns HTTP 403 `{"errcode":"M_FORBIDDEN","error":"...access_denied..."}`

### AC3: IdP error without state doesn't panic
- `GET /sso/redirect/oidc?error=server_error` (no state)
- Returns HTTP 403 — no crash

### AC4: Normal initiation path unaffected
- `GET /sso/redirect/oidc?redirectUrl=https://app.example.com/cb`
- Still returns HTTP 302 redirect to IdP (no regression)

### AC5: Normal callback path (code + state) unaffected
- `GET /sso/redirect/oidc?code=X&state=Y`
- Continues to the token exchange (no regression)

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **TestMatrixSSOCallbackIdPError** — Go unit test (httptest)
   - Given: `GetSSOCallback` receives `?error=invalid_scope&error_description=...&state=X`
   - When: handler processes request
   - Then: HTTP 403, body contains `M_FORBIDDEN` and `invalid_scope`

   Sub-cases:
   - with `error_description` — error text included in response
   - without `error_description` — graceful, just error code
   - without `state` — no panic, still returns 403

## Implementation Notes

- **Only `GetSSOCallback` changes** — `GetSSORedirect` is unchanged.
- The `error_description` from the IdP is included in the response body. It is already visible in the browser URL bar (redirect from Keycloak), so this does not leak new information.
- The state entry is popped (single-use cleanup) when `state` is present. If absent (unusual), `pop` is simply skipped.
- The doc comment on `GetSSOCallback` is updated to list the three cases: success callback, initiation, and IdP error.
- Security classification: `not-needed` — the change translates an IdP-supplied error string (already visible in the redirect URL) into a Matrix JSON error. No new auth paths, no new sinks, no IDOR risk. `error_description` is JSON-encoded by `writeMatrixError` (no injection risk) and now capped at 256 chars.

## Tasks

- [x] Add IdP-error check in `GetSSOCallback` before the `code == ""` guard
- [x] Update `GetSSOCallback` doc comment
- [x] Add `TestMatrixSSOCallbackIdPError` with 3 sub-cases
- [x] Run `make test-unit-go` — all tests green

## Dev Agent Record

### Completion Notes

Implementation complete. Tests added in `gateway/internal/matrix/sso_extra_scopes_test.go` (same file as story 5-31 tests since they share the same package and test infrastructure). All packages green.

## File List

- `gateway/internal/matrix/sso.go` — `GetSSOCallback`: IdP-error guard added, doc comment updated
- `gateway/internal/matrix/sso_extra_scopes_test.go` — `TestMatrixSSOCallbackIdPError` added

## Change Log

- 2026-05-26: Implemented IdP error handling in Matrix SSO callback (story 5-32).
