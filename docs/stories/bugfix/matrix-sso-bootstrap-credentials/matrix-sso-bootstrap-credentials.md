---
story_id: bugfix-sso-bootstrap-credentials
title: "Bug: Matrix SSO Ignores Bootstrap OIDC Client Credentials from DB"
type: bug
severity: high
epic: bugfix
status: review
security_review: required
created: 2026-05-26
branch: bugfix/matrix-sso-bootstrap-credentials
---

## Summary

The Matrix SSO flow (`LoginHandler`) reads `oidc_client_id` and `oidc_client_secret` exclusively from the static environment variables `NEBU_OIDC_CLIENT_ID` / `NEBU_OIDC_CLIENT_SECRET`, hardwired at gateway startup in `main.go`. However, the Admin Bootstrap wizard stores these credentials (AES-256-GCM encrypted) in the `server_config` table under keys `oidc_client_id` and `oidc_client_secret`. The DB values are never read for the SSO flow.

This means operators who configure their OIDC client via the Bootstrap UI get a confusing `unauthorized_client` error from their IdP (e.g. Keycloak), because the gateway still uses the stale/placeholder env vars instead of the Bootstrap-configured credentials.

## Root Cause

In `gateway/cmd/gateway/main.go` (~line 597–611), `LoginHandler` is initialised statically:

```go
loginHandler := matrix.NewLoginHandler(matrix.LoginConfig{
    ClientID:     cfg.OIDCClientID,     // ← always NEBU_OIDC_CLIENT_ID env var
    ClientSecret: cfg.OIDCClientSecret, // ← always NEBU_OIDC_CLIENT_SECRET env var
    ...
})
```

The existing `newServerConfigClaimLoader` pattern (used for `oidc_user_id_claim`, `oidc_displayname_claim`, `oidc_email_claim`) demonstrates the correct approach: a 60s TTL-cached loader reads from `server_config` and falls back to the env var when the DB has no value. This pattern is not applied to `oidc_client_id` and `oidc_client_secret`.

The `oidc_client_secret` in `server_config` is encrypted with AES-256-GCM using the gateway's internal secret (`h.secret` in the admin package). The loader must decrypt it before use.

## Fix

### 1. Add `ClientIDLoader` and `ClientSecretLoader` to `LoginConfig` / `LoginHandler`

In `gateway/internal/matrix/login.go`, mirror the existing claim-loader pattern:

```go
type LoginConfig struct {
    ...
    ClientID            string                       // fallback env var (pre-bootstrap)
    ClientSecret        string                       // fallback env var (pre-bootstrap)
    ClientIDLoader      func(ctx context.Context) string  // NEW: dynamic DB loader
    ClientSecretLoader  func(ctx context.Context) string  // NEW: dynamic DB loader (decrypted)
    ...
}
```

`LoginHandler.clientID()` and `LoginHandler.clientSecret()` become methods that call the loader if set, otherwise return the static field — so `sso.go` and `login.go` call `h.clientID(ctx)` / `h.clientSecret(ctx)` instead of `h.clientID` / `h.clientSecret`.

### 2. Wire TTL-cached loaders in `main.go`

Using the existing `newServerConfigClaimLoader` infrastructure, add two new loaders before `loginHandler` is constructed:

```go
clientIDCached := newServerConfigClaimLoader(adminAuth.ConfigReader(), "oidc_client_id", cfg.OIDCClientID)
// For the secret: needs decryption, so a custom loader (not newServerConfigClaimLoader)
```

The secret loader must:
1. Read the encrypted value from `server_config` via `adminAuth.ConfigReader()`
2. Decrypt with `decryptAES256GCM(secret, encryptedValue)` (the same function used in `admin/bootstrap.go`)
3. Fall back to `cfg.OIDCClientSecret` if the DB has no value or decryption fails

### 3. Export `decryptAES256GCM` from the admin package (or move to shared crypto)

`decryptAES256GCM` is currently unexported in `gateway/internal/admin/`. It must be accessible to `main.go`. Options:
- Export it as `DecryptAES256GCM` in the admin package (minimal change)
- Move it to a shared `internal/crypto` package (cleaner long-term)

Preferred: export from `admin` package to keep the change minimal.

## Acceptance Criteria

1. **AC1 — Bootstrap credentials used for SSO redirect**: When `server_config` contains `oidc_client_id`, the SSO redirect uses that value as `client_id` in the OAuth2 authorization URL — not the `NEBU_OIDC_CLIENT_ID` env var.
2. **AC2 — Bootstrap secret used for token exchange**: When `server_config` contains a valid encrypted `oidc_client_secret`, the gateway decrypts it and uses it for the OAuth2 token exchange.
3. **AC3 — Fallback to env var when DB is empty**: When `server_config` has no `oidc_client_id` / `oidc_client_secret` (pre-bootstrap state), the gateway falls back to the env vars without error.
4. **AC4 — 60s TTL cache**: The DB is queried at most once per 60 seconds per value (same as claim loaders).
5. **AC5 — Broken encrypted value falls back safely**: If decryption of the stored secret fails (corrupted value), the gateway logs a warning and falls back to the env var — no panic, no 500 error.

## Acceptance Tests

### Tests written FIRST (before implementation):

1. **`TestLoginHandlerUsesClientIDFromLoader`** — Go unit test (`login_test.go` or `sso_test.go`)
   - Given: `ClientIDLoader` returns `"db-client-id"`
   - When: `GetSSORedirect` builds the OAuth2 auth URL
   - Then: The URL contains `client_id=db-client-id`

2. **`TestLoginHandlerUsesClientSecretFromLoader`** — Go unit test
   - Given: `ClientSecretLoader` returns `"db-secret"`
   - When: `GetSSOCallback` calls `oauth2Config.Exchange`
   - Then: The exchange uses `client_secret=db-secret` (verified via intercepted HTTP request or mock)

3. **`TestLoginHandlerFallsBackToStaticClientID`** — Go unit test
   - Given: `ClientIDLoader` is nil (not set)
   - When: `GetSSORedirect` builds the OAuth2 auth URL
   - Then: The URL contains the static `ClientID` value from `LoginConfig`

4. **`TestServerConfigClientIDLoader`** — Go unit test (`main_test.go` or a new `loaders_test.go`)
   - Given: `server_config` returns `"db-client-id"` for key `"oidc_client_id"`
   - When: the loader function is called
   - Then: returns `"db-client-id"`; when DB returns empty, returns the env-var fallback

5. **`TestServerConfigClientSecretLoader`** — Go unit test
   - Given: `server_config` returns an AES-256-GCM encrypted `"secret"` for key `"oidc_client_secret"`
   - When: the loader function is called
   - Then: returns decrypted `"secret"`; when DB empty → env-var fallback; when decrypt fails → env-var fallback + log warning

## Tasks/Subtasks

- [x] **Task 1: Extend `LoginConfig` / `LoginHandler` with `ClientIDLoader` and `ClientSecretLoader`**
  - [x] Add `ClientIDLoader func(ctx context.Context) string` and `ClientSecretLoader func(ctx context.Context) string` to `LoginConfig`
  - [x] Add corresponding loader fields to `LoginHandler`
  - [x] Add `resolveClientID(ctx)` and `resolveClientSecret(ctx)` methods to `LoginHandler`
  - [x] Update `NewLoginHandler` to wire the new fields

- [x] **Task 2: Replace direct field access in `sso.go` and `login.go`**
  - [x] Replace `h.clientID` / `h.clientSecret` in `sso.go#GetSSORedirect` with `h.resolveClientID(r.Context())` / `h.resolveClientSecret(r.Context())`
  - [x] Replace `h.clientID` / `h.clientSecret` in `sso.go#GetSSOCallback` (oauth2Config + callbackVerifier)
  - [x] Replace `h.clientID` in `login.go#PostLogin` verifier config

- [x] **Task 3: Add `newServerConfigClientIDLoader` and `newServerConfigClientSecretLoader` to `main.go`**
  - [x] Implement `newServerConfigClientIDLoader` (60s TTL, DB → env fallback)
  - [x] Implement `newServerConfigClientSecretLoader` (60s TTL, DB decrypt → env fallback, slog.Warn on decrypt error)
  - [x] Wire both loaders in `LoginConfig` in `main()`

- [x] **Task 4: Post-Green MINOR fixes**
  - [x] MINOR-2: Add slog-Capture for warning assertion in AC5 subtest of `TestServerConfigClientSecretLoader`

## Dev Agent Record

### Implementation Plan

Followed the existing `newServerConfigClaimLoader` / `claimLoader` pattern in `main.go`. Two new loader functions added:

- `newServerConfigClientIDLoader`: reads `oidc_client_id` from `server_config` with 60s TTL, falls back to `cfg.OIDCClientID`
- `newServerConfigClientSecretLoader`: reads `oidc_client_secret`, decrypts with `admin.DecryptAES256GCM`, falls back to `cfg.OIDCClientSecret` on missing value or decrypt error (emits `slog.Warn`)

`LoginHandler` gains `resolveClientID(ctx)` and `resolveClientSecret(ctx)` methods that delegate to the loader when set, otherwise return the static fields (pre-bootstrap fallback). All usages of `h.clientID` / `h.clientSecret` in `sso.go` and `login.go` replaced with these methods.

`admin.EncryptAES256GCM` and `admin.DecryptAES256GCM` were already exported (exported variant added in the ATDD-prep step via `gateway/internal/admin/crypto.go`).

MINOR-2 addressed: `slogCapture` helper added to `loaders_test.go` to assert that `slog.Warn` is emitted when decryption fails.

### Completion Notes

- All 5 acceptance criteria satisfied (AC1–AC5)
- 11 acceptance tests pass (5 main test functions, multiple subtests)
- 587 total tests in affected packages — no regressions
- MINOR-1 (TTL subtest) already present in `TestServerConfigClientIDLoader` ("respects 60s TTL cache")
- MINOR-3 (`t.Parallel()` in `TestLoginHandlerUsesClientSecretFromLoader`): test does not call `t.Parallel()` intentionally — it manipulates `globalSSOState` shared state; parallelism would cause data races
- MINOR-4 (`setupOIDCServer` privateKey discarded in redirect tests): non-blocking; private key not needed for URL assertion tests

## File List

- `gateway/internal/matrix/login.go` — added `ClientIDLoader`, `ClientSecretLoader` fields to `LoginConfig`; added loader fields to `LoginHandler`; added `resolveClientID()`, `resolveClientSecret()` methods; updated `NewLoginHandler`; updated verifier in `PostLogin` to use `resolveClientID`
- `gateway/internal/matrix/sso.go` — replaced `h.clientID` / `h.clientSecret` with `h.resolveClientID(r.Context())` / `h.resolveClientSecret(r.Context())` in `GetSSORedirect`, `GetSSOCallback` (oauth2Config + callbackVerifier)
- `gateway/cmd/gateway/main.go` — added `newServerConfigClientIDLoader`, `newServerConfigClientSecretLoader`; wired `ClientIDLoader` / `ClientSecretLoader` in `LoginConfig`
- `gateway/internal/admin/crypto.go` — `EncryptAES256GCM` and `DecryptAES256GCM` exported (done in ATDD-prep step, no changes here)
- `gateway/internal/matrix/sso_bootstrap_credentials_test.go` — Red-phase acceptance tests (AC1, AC2, AC3) — staged pre-implementation
- `gateway/cmd/gateway/loaders_test.go` — Red-phase acceptance tests (AC1/AC3 for ID loader, AC2/AC3/AC5 for secret loader) + slogCapture helper (MINOR-2)

## Change Log

- 2026-05-26: Implemented bugfix-sso-bootstrap-credentials — Matrix SSO now reads OIDC client credentials from server_config (Bootstrap-configured values) via TTL-cached loaders with env-var fallback and safe decryption error handling
