---
story_id: 5-31
title: "Bug: Hardcoded `groups` Scope in Matrix SSO Handlers Breaks Keycloak Login"
type: bug
severity: high
epic: 5
status: done
security_review: not-needed
created: 2026-05-26
branch: bugfix/custom-scopes-in-matrix-sso
---

## Summary

The Matrix SSO login flow (`GET /_matrix/client/v3/login/sso/redirect` and its callback) hardcodes `groups` as an extra scope in both handlers. This scope is Dex-specific and is absent from Keycloak's `scopes_supported`. The exact same class of bug was fixed in the admin auth flow in story 5-30 — but `gateway/internal/matrix/sso.go` was not covered.

```go
// gateway/internal/matrix/sso.go:303 and :363 — current broken state
Scopes: []string{oidc.ScopeOpenID, "profile", "email", "groups"},
```

Note: `offline_access` is NOT present here (unlike the admin flow), so this is a narrower fix. Only `groups` needs to be made configurable.

## Root Cause

Two locations in `gateway/internal/matrix/sso.go` hardcode `"groups"`:

- `GetSSORedirect` (~line 303): `oauth2Config.Scopes` used in `AuthCodeURL`
- `GetSSOCallback` (~line 363): `oauth2Config.Scopes` (not sent in token exchange, but should be consistent)

The matrix package has no access to `server_config` (that lives in the admin package). The correct fix is to pass extra scopes through `LoginConfig → LoginHandler → sso.go` at startup, reading them from the same `NEBU_OIDC_EXTRA_SCOPES` env var used by the admin flow (story 5-30).

## Fix

### 1. Add `OIDCExtraScopes []string` to `gateway/internal/config/config.go`

Read from `NEBU_OIDC_EXTRA_SCOPES` using the existing `getEnvStringSlice` helper (same function used for `SSORedirectSchemes`):

```go
OIDCExtraScopes: getEnvStringSlice("NEBU_OIDC_EXTRA_SCOPES"),
```

Note: `getEnvStringSlice` splits on commas. `NEBU_OIDC_EXTRA_SCOPES` uses space-separated values in the admin flow (`os.Getenv` + `strings.Fields`). Use `strings.Fields(os.Getenv("NEBU_OIDC_EXTRA_SCOPES"))` directly in `config.go` instead of `getEnvStringSlice` to stay consistent with the admin package's parsing behaviour. Alternatively, add a `getEnvStringFieldsSlice` helper that splits on whitespace.

### 2. Add `ExtraScopes []string` to `LoginConfig` and `LoginHandler` in `gateway/internal/matrix/login.go`

Mirror the pattern of `SSORedirectSchemes`:

```go
type LoginConfig struct {
    // ... existing fields ...
    ExtraScopes []string // from NEBU_OIDC_EXTRA_SCOPES; appended to [openid, profile, email]
}

type LoginHandler struct {
    // ... existing fields ...
    extraScopes []string
}
```

Wire it in `NewLoginHandler`:
```go
extraScopes: cfg.ExtraScopes,
```

### 3. Add `buildSSOScopeList` helper in `sso.go`

The `buildScopeList` and `resolveExtraScopes` helpers in `auth.go` are unexported and in the `admin` package. Do NOT import `admin` from `matrix` (circular dependency). Add a small private helper in `sso.go`:

```go
// buildSSOScopeList returns [openid, profile, email] plus any non-duplicate extra scopes.
func buildSSOScopeList(extra []string) []string {
    base := []string{oidc.ScopeOpenID, "profile", "email"}
    seen := map[string]bool{oidc.ScopeOpenID: true, "profile": true, "email": true}
    for _, s := range extra {
        if s != "" && !seen[s] {
            base = append(base, s)
            seen[s] = true
        }
    }
    return base
}
```

### 4. Use `buildSSOScopeList` in `GetSSORedirect` and `GetSSOCallback`

Replace both hardcoded scope lists:

```go
// Before:
Scopes: []string{oidc.ScopeOpenID, "profile", "email", "groups"},

// After:
Scopes: buildSSOScopeList(h.extraScopes),
```

### 5. Wire `ExtraScopes` in `gateway/cmd/gateway/main.go`

```go
loginHandler := matrix.NewLoginHandler(matrix.LoginConfig{
    // ... existing fields ...
    ExtraScopes:        cfg.OIDCExtraScopes, // NEW
})
```

### 6. No changes to `docker-compose.yml` or `cloud-init.tftpl`

Both were already updated in story 5-30:
- `docker-compose.yml`: `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`
- `cloud-init.tftpl`: conditional `NEBU_OIDC_EXTRA_SCOPES` (dex: `groups offline_access`, external: empty)

These values are now consumed by BOTH the admin flow (story 5-30) and the matrix SSO flow (this story).

## Acceptance Criteria

### AC1: Standard scopes always sent
- Matrix SSO auth request always includes `openid profile email`.
- No extra scopes added unless `NEBU_OIDC_EXTRA_SCOPES` is set.

### AC2: Extra scopes from env var applied to matrix SSO
- When `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`, matrix SSO auth request includes those scopes.
- When `NEBU_OIDC_EXTRA_SCOPES=` (empty), only standard scopes sent.

### AC3: Keycloak matrix SSO works without custom scopes
- With empty/unset `NEBU_OIDC_EXTRA_SCOPES`, the matrix SSO auth request only includes `openid profile email`.
- No Keycloak rejection due to unsupported `groups` scope.

### AC4: Dex environment unaffected
- With `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`, the matrix SSO flow includes those scopes — same as before the fix.
- Existing Dex SSO login flow continues to work.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **TestMatrixSSORedirectScopesDefault** — Go unit test (httptest)
   - Given: `NEBU_OIDC_EXTRA_SCOPES` unset, `LoginHandler` built with `ExtraScopes: nil`
   - When: `GetSSORedirect` is called
   - Then: redirect URL `Location` header contains `scope=openid+profile+email` (no `groups`, no `offline_access`)

2. **TestMatrixSSORedirectScopesFromExtraScopes** — Go unit test (httptest)
   - Given: `LoginHandler` built with `ExtraScopes: []string{"groups", "offline_access"}`
   - When: `GetSSORedirect` is called
   - Then: redirect URL contains `scope=openid+profile+email+groups+offline_access`

3. **TestMatrixSSORedirectScopesDedup** — Go unit test (httptest)
   - Given: `LoginHandler` built with `ExtraScopes: []string{"openid", "roles", "email"}`
   - When: `GetSSORedirect` is called
   - Then: redirect URL contains `scope=openid+profile+email+roles` (no duplicate `openid`/`email`)

4. **TestBuildSSOScopeList** — direct unit test of the helper
   - Verifies empty extra → `[openid, profile, email]`
   - Verifies non-empty extra → appended correctly
   - Verifies duplicates dropped

## Implementation Notes

### File changes

| File | Change type | What |
|---|---|---|
| `gateway/internal/config/config.go` | UPDATE | Add `OIDCExtraScopes []string`; parse with `strings.Fields(os.Getenv("NEBU_OIDC_EXTRA_SCOPES"))` |
| `gateway/internal/matrix/login.go` | UPDATE | Add `ExtraScopes []string` to `LoginConfig` and `LoginHandler`; wire in `NewLoginHandler` |
| `gateway/internal/matrix/sso.go` | UPDATE | Add `buildSSOScopeList` helper; replace hardcoded scopes in `GetSSORedirect` (line 303) and `GetSSOCallback` (line 363) |
| `gateway/cmd/gateway/main.go` | UPDATE | Pass `cfg.OIDCExtraScopes` to `LoginConfig.ExtraScopes` |
| `gateway/internal/matrix/sso_extra_scopes_test.go` | NEW | Acceptance tests + `buildSSOScopeList` unit tests |

### No DB access needed

The matrix SSO handler is stateless at auth-request time — it has no `configReader` and no access to `server_config`. The env var is the only mechanism. This is intentional and correct: the DB-based override (story 5-30) is limited to the admin flow where the admin package's `ServerConfigReader` is already wired up.

### Scope parsing consistency

The admin package uses `strings.Fields(os.Getenv("NEBU_OIDC_EXTRA_SCOPES"))` (whitespace split). The `config.go` existing `getEnvStringSlice` uses comma split. To maintain consistency with the admin package and the documented env var format (`"groups offline_access"`), use `strings.Fields` explicitly:

```go
OIDCExtraScopes: strings.Fields(os.Getenv("NEBU_OIDC_EXTRA_SCOPES")),
```

Add `"strings"` import to `config.go` if not already present.

### Test setup

The existing SSO tests in `gateway/internal/matrix/` use a mock OIDC provider. Look at how `GetSSORedirect` tests are structured (e.g., in the test file for story 5-24's redirect scheme allowlist) — the handler redirects to the OIDC provider's auth URL, so the test can parse the `Location` header to assert the scope parameter.

`LoginHandler` is constructed directly in tests via `NewLoginHandler(LoginConfig{...})` with a test provider — pass `ExtraScopes` through `LoginConfig` in the new tests.

## Tasks

- [x] Write failing tests in `gateway/internal/matrix/sso_extra_scopes_test.go`
- [x] Add `OIDCExtraScopes []string` to `Config` in `config.go` (parse with `strings.Fields`)
- [x] Add `ExtraScopes []string` to `LoginConfig` and `LoginHandler` in `login.go`
- [x] Wire `ExtraScopes: cfg.OIDCExtraScopes` in `main.go`
- [x] Add `buildSSOScopeList` helper in `sso.go`
- [x] Replace hardcoded scope lists in `GetSSORedirect` and `GetSSOCallback`
- [x] Run `make test-unit-go` — all tests green

## Dev Agent Record

### Implementation Plan

Implemented in four targeted changes following the story spec exactly:
1. `config.go`: Added `OIDCExtraScopes []string` parsed via `strings.Fields(os.Getenv("NEBU_OIDC_EXTRA_SCOPES"))` — whitespace-split for consistency with the admin package.
2. `login.go`: Added `ExtraScopes []string` to both `LoginConfig` (public) and `LoginHandler` (private `extraScopes`); wired in `NewLoginHandler`.
3. `sso.go`: Added `buildSSOScopeList(extra []string) []string` private helper with dedup logic; replaced both hardcoded `[]string{oidc.ScopeOpenID, "profile", "email", "groups"}` calls in `GetSSORedirect` and `GetSSOCallback`.
4. `main.go`: Added `ExtraScopes: cfg.OIDCExtraScopes` to the `LoginConfig` struct literal.

Test quality improvements (MINOR-1 + MINOR-2):
- Added `TestMatrixSSORedirectScopesEmptyEnvVar` testing `ExtraScopes: []string{}` (empty env var path).
- Added comment explaining why `GetSSOCallback` is not separately tested for scope behaviour.

### Completion Notes

All 7 tasks checked. `make test-unit-go` passed: all 26+ gateway packages green including `internal/matrix` (32s). No regressions. AC1–AC4 fully covered by the acceptance tests in `sso_extra_scopes_test.go`.

## Change Log

- 2026-05-26: Story created. Matrix SSO scope bug (sibling of 5-30).
- 2026-05-26: Implementation complete. Story moved to review.

## File List

- `gateway/internal/config/config.go` — Added `OIDCExtraScopes []string` field and `strings.Fields` parse
- `gateway/internal/matrix/login.go` — Added `ExtraScopes []string` to `LoginConfig` and `LoginHandler`; wired in `NewLoginHandler`
- `gateway/internal/matrix/sso.go` — Added `buildSSOScopeList` helper; replaced two hardcoded scope lists
- `gateway/cmd/gateway/main.go` — Added `ExtraScopes: cfg.OIDCExtraScopes` to `LoginConfig`
- `gateway/internal/matrix/sso_extra_scopes_test.go` — Added `TestMatrixSSORedirectScopesEmptyEnvVar` + MINOR-2 comment
