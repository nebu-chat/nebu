---
story_id: oidc-session-refresh
title: "Bug: Matrix User Sessions Expire After Short OIDC Token Lifetime"
type: bug
severity: high
epic: fix-short-oidc-sessions
status: review
security_review: required
created: 2026-05-27
branch: bugfix/fix-short-oidc-sessions
---

## Summary

Regular Matrix users (Element Web, FluffyChat) are force-logged-out within minutes of logging in when connecting to a Keycloak-backed Nebu instance. The root cause: the OIDC `id_token` is returned directly as the Matrix `access_token` (`gateway/internal/matrix/login.go:299`). Keycloak's default access token lifetime is 5 minutes. When the token expires, `JWTMiddleware` returns `401 M_UNKNOWN_TOKEN` and the client must re-authenticate.

The OIDC `refresh_token` from `oauth2Config.Exchange()` in `GetSSOCallback` (`sso.go:412`) is silently discarded. Admin UI sessions have a full server-side session store with encrypted refresh tokens and proactive refresh (5-minute window before expiry). Matrix users have none of this.

## Story

As a Matrix chat user (Element Web / FluffyChat),
I want my session to stay alive for many hours without interruption,
so that I don't get force-logged-out every few minutes and lose my chat context.

## Acceptance Criteria

**AC1 — Login issues opaque tokens when refresh requested:**
Client sends `POST /login` with `{"type":"m.login.token","token":"...","refresh_token":true}` → Response contains:
- `access_token`: opaque hex string (NOT a JWT, no `.` characters)
- `refresh_token`: opaque hex string
- `expires_in_ms`: integer (milliseconds until access token expires)
- `user_id`, `device_id` as before

**AC2 — `/refresh` endpoint works:**
`POST /_matrix/client/v3/refresh` with valid opaque Nebu refresh token in body → HTTP 200 with:
```json
{"access_token": "<new_opaque>", "expires_in_ms": <ms>, "refresh_token": "<new_opaque>"}
```

**AC3 — New tokens function after refresh:**
New access token returned from `/refresh` works immediately for `GET /sync`, `GET /whoami`, etc.

**AC4 — Old refresh token grace period (Spec MUST):**
After `/refresh` returns new tokens, the old refresh token remains valid and can itself be used for another refresh — until the new access token or new refresh token is used for the first time. This ensures clients that fail to persist new tokens can retry.

**AC5 — Expired access token returns `soft_logout: true`:**
When an opaque Nebu access token exists in DB but `expires_at` has passed:
→ `401 {"errcode":"M_UNKNOWN_TOKEN","error":"Token has expired","soft_logout":true}`

**AC6 — Invalid/used refresh token returns 401:**
`POST /refresh` with unknown, revoked, or already-used-and-replaced refresh token → `401 {"errcode":"M_UNKNOWN_TOKEN","error":"..."}`

**AC7 — Backward compatibility: clients without `refresh_token: true` are unaffected:**
Client sends `POST /login` WITHOUT `refresh_token: true` → Response is unchanged: `access_token` is the raw OIDC JWT (as before), no `expires_in_ms`, no `refresh_token` in response.

**AC8 — Session persists across OIDC token expiry:**
Integration test with short Keycloak token lifetime (e.g. 30s) confirms FluffyChat/Element can maintain a working session for at least 8 hours without user intervention.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1] Godog: Login with `refresh_token: true` returns opaque tokens** — `gateway/features/matrix_session_refresh.feature`
   - Given: A valid OIDC login token exists for user `@alice:test.local`
   - When: `POST /login` with `{"type":"m.login.token","token":"<jwt>","refresh_token":true}`
   - Then: 200 with `access_token` matching `^[0-9a-f]{64}$` (no dots), `refresh_token` matching same pattern, `expires_in_ms` > 0

2. **[AC7] Godog: Login WITHOUT `refresh_token: true` returns JWT (backward compat)** — same feature file
   - Given: Same setup
   - When: `POST /login` with `{"type":"m.login.token","token":"<jwt>"}` (no `refresh_token` field)
   - Then: 200 with `access_token` that IS a JWT (contains dots), no `refresh_token` field, no `expires_in_ms`

3. **[AC2+AC3] Godog: `/refresh` returns new tokens; new access token works for `/sync`** — same feature file
   - Given: A valid Nebu session (opaque AT + RT in DB)
   - When: `POST /refresh` with `{"refresh_token":"<nebu-rt>"}`
   - Then: 200 with new opaque `access_token` and `expires_in_ms`; subsequent `GET /sync` with new AT → 200

4. **[AC4] Godog: Old refresh token valid until new tokens are used (grace period)** — same feature file
   - Given: Session A with (AT_A, RT_A); call `/refresh` → get (AT_B, RT_B)
   - When: Call `/refresh` again with RT_A (old RT, before AT_B/RT_B are used)
   - Then: 200 — RT_A is still valid
   - When: Make one request with AT_B (new AT is "used"), then call `/refresh` with RT_A
   - Then: 401 — RT_A is now revoked

5. **[AC5] Godog: Expired opaque AT returns `soft_logout: true`** — same feature file
   - Given: A matrix session with `expires_at` = 1 second in the past
   - When: `GET /sync` with the expired opaque AT
   - Then: `401 {"errcode":"M_UNKNOWN_TOKEN","soft_logout":true}`

6. **[AC6] Godog: Unknown/used RT returns 401** — same feature file
   - Given: A matrix session where RT was already used and replaced
   - When: `POST /refresh` with the old RT
   - Then: `401 {"errcode":"M_UNKNOWN_TOKEN"}`

7. **[Unit] Go httptest: `MatrixSessionStore` interface** — `gateway/internal/db/matrix_session_store_test.go`
   - CRUD operations (Create, GetByAccessToken, GetByRefreshToken, RotateTokens, Revoke, CleanupExpired)
   - Uses real DB (no mocks — integration test)

## Dev Notes

### Root Cause (Confirmed)

`gateway/internal/matrix/login.go:298-305`:
```go
resp := LoginTokenResponse{
    AccessToken: rawJWT,  // ← OIDC id_token used directly
    DeviceID:    generateDeviceID(),
    UserID:      userID,
    TokenType:   "Bearer",
}
```

`gateway/internal/matrix/sso.go:412-419`:
```go
token, err := oauth2Config.Exchange(r.Context(), code, ...)
rawIDToken, ok := token.Extra("id_token").(string)
// token.RefreshToken ← DISCARDED HERE, never stored
```

`gateway/internal/middleware/auth.go:195-205`: `JWTMiddleware` validates JWT signature via OIDC provider — works fine for JWTs but has no knowledge of opaque tokens.

### Reference Implementations to Mirror

**`gateway/internal/admin/session_store.go`** — `AdminSessionStore` interface — use same pattern for `MatrixSessionStore`.

**`gateway/internal/db/admin_session_store.go`** — `PostgresAdminSessionStore` — mirror for `PostgresMatrixSessionStore`.

**`gateway/internal/admin/middleware.go:285-353`** — `attemptTokenRefresh()` — the OIDC refresh logic (decrypt RT → call token endpoint → encrypt new RT → compute expiry). **Reuse this pattern** for `POST /refresh`.

**`gateway/internal/admin/auth.go` (lines ~956-995)** — `CallbackHandler` session creation: AES-256-GCM encrypt refresh token, store in DB. Reuse same pattern in `GetSSOCallback`.

### Architecture: What Changes Where

#### 1. New DB Migration: `matrix_sessions` table

File: `gateway/migrations/000001_init.up.sql` — add to the single squashed migration.

```sql
-- ─── matrix_sessions ──────────────────────────────────────────────────────────
CREATE TABLE matrix_sessions (
    access_token        TEXT        PRIMARY KEY,
    refresh_token       TEXT        UNIQUE NOT NULL,
    oidc_refresh_token  TEXT,           -- AES-256-GCM encrypted OIDC RT; NULL if not obtained
    user_id             TEXT        NOT NULL,
    device_id           TEXT        NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_matrix_sessions_refresh_token ON matrix_sessions (refresh_token);
CREATE INDEX idx_matrix_sessions_user_id       ON matrix_sessions (user_id);
CREATE INDEX idx_matrix_sessions_expires_at    ON matrix_sessions (expires_at);
```

#### 2. New: `gateway/internal/matrix/session_store.go` (Interface)

```go
package matrix

type MatrixSession struct {
    AccessToken           string
    RefreshToken          string
    EncryptedOIDCRefreshToken string // AES-256-GCM; empty = no OIDC RT stored
    UserID                string
    DeviceID              string
    ExpiresAt             time.Time
    RevokedAt             *time.Time
}

type MatrixSessionStore interface {
    // Create inserts a new session. access_token and refresh_token are caller-generated.
    Create(ctx context.Context, sess MatrixSession) error
    // GetByAccessToken looks up a session by opaque access_token.
    // Returns (nil, nil) when not found.
    GetByAccessToken(ctx context.Context, accessToken string) (*MatrixSession, error)
    // GetByRefreshToken looks up a session by opaque refresh_token.
    // Returns (nil, nil) when not found.
    GetByRefreshToken(ctx context.Context, refreshToken string) (*MatrixSession, error)
    // RotateTokens atomically replaces access+refresh tokens and updates expiry.
    // The old refresh_token row is marked with revoked_at = NOW() (grace-period: stays queryable).
    // New row is inserted. Returns error if oldRefreshToken not found or already revoked.
    RotateTokens(ctx context.Context, oldRefreshToken, newAccessToken, newRefreshToken string, newEncOIDCRT string, newExpiry time.Time) error
    // MarkAccessTokenUsed records that a new access token was first-used (triggers RT grace expiry).
    // Called at the start of every authenticated request when the session was refreshed recently.
    MarkAccessTokenUsed(ctx context.Context, accessToken string) error
    // Revoke sets revoked_at = NOW() for the given access_token (called on logout).
    Revoke(ctx context.Context, accessToken string) error
    // CleanupExpired deletes rows where expires_at < NOW() - INTERVAL '7 days'.
    CleanupExpired(ctx context.Context) error
}
```

> **Note on Grace Period (AC4):** The `RotateTokens` implementation marks the old refresh token as `revoked_at = NOW()` but keeps the row. A subsequent `GetByRefreshToken` on the old RT should still succeed IF the new access token has not yet been used (checked via a separate `last_used_at` column or via a `grace_until` TIMESTAMPTZ on the old RT row — implementer's choice, but must satisfy AC4 precisely).

**Simplest correct implementation of grace period:**
- `RotateTokens`: insert new session row; set `revoked_at` on old row with `grace_until = NOW() + 60s` (grace window)
- `GetByRefreshToken`: return session only if `revoked_at IS NULL OR grace_until > NOW()`
- `MarkAccessTokenUsed`: when the new AT is first used, immediately expire the grace on old RT (`UPDATE matrix_sessions SET grace_until = NOW() WHERE refresh_token = <old_rt>`)

This requires adding `grace_until TIMESTAMPTZ` to the migration.

#### 3. New: `gateway/internal/db/matrix_session_store.go`

Implements `MatrixSessionStore`. Mirror `PostgresAdminSessionStore`. Uses `crypto/rand` for token generation helper (move `generateSID()` to shared helper or duplicate).

Token generation helper:
```go
func generateOpaqueToken() (string, error) {
    b := make([]byte, 32)
    if _, err := rand.Read(b); err != nil {
        return "", err
    }
    return hex.EncodeToString(b), nil  // 64 hex chars, no dots → distinguishable from JWT
}
```

#### 4. Modified: `gateway/internal/matrix/sso.go` — `GetSSOCallback`

After `oauth2Config.Exchange()`:
1. Add `offline_access` to `buildSSOScopeList()` (unconditional — needed to get RT from Keycloak)
2. If `token.RefreshToken != ""`: encrypt with AES-256-GCM (same function as admin package — need to export `EncryptAES256GCM` from admin or move to shared `internal/crypto` package)
3. Generate opaque `accessToken` + `refreshToken` (32 bytes each)
4. Compute `expiresAt = min(token.Expiry, now+8h)`
5. Call `matrixSessionStore.Create()` with full session
6. Store the opaque `accessToken` in `loginTokenStore` (replacing `rawIDToken`) so `PostLogin` can retrieve it

> **Critical:** `globalLoginTokens.save()` currently stores `rawIDToken`. It must now store the opaque `accessToken` string. The SSO callback no longer gives the raw JWT to the client — it gives the opaque token. `PostLogin` retrieves the opaque token from the store and returns it directly in `LoginTokenResponse.AccessToken`.

**But:** `PostLogin` also needs a `MatrixSessionStore` reference to check whether `refresh_token: true` is in the request. The store is already set up — `PostLogin` just returns whatever token it received from the store (the opaque one).

Actually, a cleaner split:
- `GetSSOCallback` always creates the matrix session and stores opaque AT in `loginTokenStore`
- `PostLogin` pops the opaque AT from `loginTokenStore`; if `req.RefreshToken == true`: retrieve the full session from `matrixSessionStore.GetByAccessToken()` and include `refresh_token` + `expires_in_ms` in the response
- If `req.RefreshToken == false` (or field absent): the opaque AT is still returned (AC7 only preserves the old behavior for clients sending raw JWT directly, not for SSO flow clients — see note below)

> **AC7 Nuance:** The old backward-compat path (`req.RefreshToken == false`) was designed for clients that send the OIDC JWT directly via `POST /login`. After this change, SSO-flow clients (Element Web, FluffyChat) always go through `GetSSOCallback` and will always get an opaque token — whether or not they sent `refresh_token: true`. The `refresh_token` flag only controls whether `PostLogin` also returns the Nebu refresh token and `expires_in_ms`. For truly legacy clients that POST the raw JWT directly (not via SSO), the old behavior is preserved.

#### 5. Modified: `gateway/internal/matrix/login.go`

**`LoginRequest`** — add field:
```go
type LoginRequest struct {
    Type         string `json:"type"`
    Token        string `json:"token"`
    RefreshToken bool   `json:"refresh_token"` // v1.3: client supports refresh tokens
}
```

**`LoginTokenResponse`** — add optional fields:
```go
type LoginTokenResponse struct {
    AccessToken  string  `json:"access_token"`
    DeviceID     string  `json:"device_id"`
    UserID       string  `json:"user_id"`
    TokenType    string  `json:"token_type"`
    ExpiresInMs  *int64  `json:"expires_in_ms,omitempty"`  // v1.3, only when RefreshToken=true
    RefreshToken *string `json:"refresh_token,omitempty"`  // v1.3, only when RefreshToken=true
}
```

**`LoginHandler`** — add `MatrixSessionStore` field:
```go
type LoginHandler struct {
    ...
    matrixSessions MatrixSessionStore // nil = refresh not supported (backward compat)
}
```

**`PostLogin`** — after successful token verification:
```go
if req.RefreshToken && h.matrixSessions != nil {
    sess, err := h.matrixSessions.GetByAccessToken(r.Context(), rawJWT) // rawJWT = opaque AT from store
    if err == nil && sess != nil {
        expiresInMs := time.Until(sess.ExpiresAt).Milliseconds()
        resp.ExpiresInMs = &expiresInMs
        resp.RefreshToken = &sess.RefreshToken
    }
}
```

#### 6. New: `gateway/internal/matrix/refresh.go` — `RefreshHandler`

```go
type RefreshHandler struct {
    store  MatrixSessionStore
    secret []byte // AES-256-GCM key (same as internal_secret)
    // OIDC config loader (needed to refresh OIDC token when Nebu AT expires)
    configReader admin.OIDCConfigReader // interface, loaded from admin package
}
```

`PostRefresh` logic:
1. Decode request body → extract `refresh_token`
2. `store.GetByRefreshToken(ctx, refreshToken)` → find session
3. If not found or hard-revoked (grace expired): `401 M_UNKNOWN_TOKEN`
4. If `sess.EncryptedOIDCRefreshToken != ""`: call `attemptTokenRefresh()` equivalent to get new OIDC token (or just refresh the Nebu session without OIDC round-trip if Nebu AT lifetime is controlled by us)
5. Generate new opaque `newAT`, `newRT` (32 bytes each)
6. Compute `newExpiresAt = min(oidcExpiry, now+8h)` (or just `now+8h` if no OIDC refresh needed)
7. `store.RotateTokens(ctx, refreshToken, newAT, newRT, newEncOIDCRT, newExpiresAt)`
8. Return `{"access_token": newAT, "refresh_token": newRT, "expires_in_ms": <ms>}`

**Note:** The OIDC refresh token exchange is optional at the Nebu level. Nebu controls `expires_at` independently — the Nebu access token lifetime can be set to 8 hours regardless of the OIDC token's lifetime. The OIDC RT is needed only if we want to verify the user is still valid in Keycloak (not logged out there). For MVP, it's acceptable to refresh the Nebu session without calling Keycloak — Keycloak logout won't immediately invalidate Nebu sessions, but this is a known trade-off. Add a comment.

#### 7. Modified: `gateway/internal/middleware/auth.go` — `JWTMiddleware`

The middleware needs to distinguish JWT tokens (contain `.`) from opaque Nebu tokens (64 hex chars):

```go
func isOpaqueToken(token string) bool {
    return !strings.Contains(token, ".") // JWTs always have 2 dots
}
```

When `isOpaqueToken(rawToken)`:
1. Look up in `MatrixSessionStore.GetByAccessToken()`
2. If not found: `401 M_UNKNOWN_TOKEN "Invalid token"`
3. If found but `sess.RevokedAt != nil`: `401 M_UNKNOWN_TOKEN "Token has been logged out"`
4. If found but `sess.ExpiresAt.Before(time.Now())`: `401 M_UNKNOWN_TOKEN "Token has expired"` with `soft_logout: true`
5. If found and valid: populate context (user_id, device_id, etc.) from `MatrixSession` fields

**IMPORTANT:** `JWTMiddleware` is currently constructed with just `provider` and `clientID`. It needs a new optional `MatrixSessionStore` parameter. Use variadic options or an extended config struct to keep backward compatibility.

Suggested approach — add to `JWTMiddleware` signature:
```go
func JWTMiddleware(provider *auth.Provider, clientID string, claimName string, store TokenStore, 
    userIDClaimLoader func(ctx context.Context) string, serverName ...string) func(http.Handler) http.Handler
```
Add a separate `WithMatrixSessions(store MatrixSessionStore)` middleware wrapper (analog to `WithUserStatusCheck`) that intercepts opaque tokens before the JWT path runs.

OR: add `MatrixSessionStore` as an additional optional parameter to `JWTMiddleware` itself (simpler, fewer layers).

The `soft_logout` field needs to be added to `matrixError`:
```go
type matrixErrorWithSoftLogout struct {
    ErrCode    string `json:"errcode"`
    Err        string `json:"error"`
    SoftLogout bool   `json:"soft_logout,omitempty"`
}
```

#### 8. Modified: `gateway/cmd/gateway/main.go`

1. Instantiate `PostgresMatrixSessionStore` (reuse `tokenDB` connection or open new)
2. Pass `MatrixSessionStore` to `LoginHandler`
3. Add to `JWTMiddleware` or wrap it
4. Register `POST /_matrix/client/v3/refresh` (no auth required, rate-limited):
   ```go
   refreshHandler := matrix.NewRefreshHandler(matrix.RefreshConfig{
       Store:        matrixSessionStore,
       Secret:       []byte(internalSecret),
       ConfigReader: adminAuth.ConfigReader(),
   })
   mux.Handle("POST /_matrix/client/v3/refresh", strictRL(bodyLimit1MiB(http.HandlerFunc(refreshHandler.PostRefresh))))
   ```
5. Add periodic cleanup goroutine for `matrix_sessions` (analog to admin session cleanup):
   ```go
   go func() {
       for {
           time.Sleep(1 * time.Hour)
           if err := matrixSessionStore.CleanupExpired(ctx); err != nil {
               slog.Error("matrix session cleanup failed", "err", err)
           }
       }
   }()
   ```

#### 9. Modified: Crypto helpers

`encryptAES256GCM` / `decryptAES256GCM` are currently unexported in `gateway/internal/admin/`. Export them (or move to `gateway/internal/crypto/`) so the new `matrix` package and `db` package can use them without import cycles.

**Recommended:** Create `gateway/internal/crypto/aes.go` with `EncryptAES256GCM` / `DecryptAES256GCM`. Both `admin` and `matrix/db` packages import from `internal/crypto`. Update `admin` to delegate to the shared package.

### Spec Compliance (Oracle, 2026-05-27)

Per Matrix Client-Server API v1.18 §refreshing-access-tokens (Added v1.3):

| Requirement | Level | Implementation |
|---|---|---|
| `POST /refresh` takes `refresh_token` in body | MUST | `RefreshHandler.PostRefresh` |
| 200 response: `access_token` required | MUST | Always returned |
| 200 response: `expires_in_ms` optional | MAY | Always return it (good practice) |
| 200 response: `refresh_token` optional | MAY | Always return new RT (better security) |
| Old RT valid until new tokens are used | MUST | `RotateTokens` + grace period |
| `soft_logout: true` for expired tokens | SHOULD | `JWTMiddleware` opaque path |
| Login request `refresh_token: true` field | v1.3 | `LoginRequest.RefreshToken bool` |
| Login response `expires_in_ms` field | v1.3, optional | Only when `RefreshToken: true` |
| Login response `refresh_token` field | v1.3, optional | Only when `RefreshToken: true` |
| Token format opaque | SHOULD | 32-byte random hex |
| `POST /refresh` requires NO auth header | MUST | Register outside `jwtMiddleware` |

**`/_matrix/client/versions`** already advertises `v1.3` (main.go:601) — no change needed there.

### OIDC Scope: `offline_access`

Adding `offline_access` to `buildSSOScopeList()` in `sso.go` is required for Keycloak to issue a refresh token. Without this scope, `token.RefreshToken` will be empty.

Keycloak configuration note: The Nebu OIDC client in Keycloak must have "Offline Access" scope enabled. For STACKIT deployments, verify this is configured.

### Security Considerations

- Opaque access tokens MUST be 32 random bytes (256 bits) — same entropy as `generateSID()`
- OIDC refresh tokens stored AES-256-GCM encrypted with `internal_secret` (same pattern as admin sessions)
- `POST /refresh` is rate-limited (spec: rate-limited: yes) — use `strictRL` 
- Old refresh tokens: queryable during grace period, but MUST NOT be returned as "active" sessions
- `POST /refresh` response must not include the old OIDC refresh token in any form
- Log on token rotation: `slog.Info("matrix session refreshed", "user_id", sess.UserID, "device_id", sess.DeviceID)` — no token values in logs

### File List (Expected Changes)

**New files:**
- `gateway/migrations/` — new UP/DOWN migration SQL for `matrix_sessions`
- `gateway/internal/matrix/session_store.go` — `MatrixSession` struct + `MatrixSessionStore` interface
- `gateway/internal/matrix/refresh.go` — `RefreshHandler` + `RefreshConfig`
- `gateway/internal/db/matrix_session_store.go` — `PostgresMatrixSessionStore`
- `gateway/internal/crypto/aes.go` — shared `EncryptAES256GCM` / `DecryptAES256GCM`
- `gateway/features/matrix_session_refresh.feature` — Godog acceptance tests
- `gateway/features/matrix_session_refresh_test.go` — Godog step implementations

**Modified files:**
- `gateway/internal/matrix/login.go` — `LoginRequest`, `LoginTokenResponse`, `LoginHandler`, `LoginConfig`
- `gateway/internal/matrix/sso.go` — `GetSSOCallback`, `buildSSOScopeList`
- `gateway/internal/middleware/auth.go` — `JWTMiddleware` (opaque token path + `soft_logout`)
- `gateway/internal/admin/middleware.go` — export `EncryptAES256GCM` / `DecryptAES256GCM` (or remove after crypto package)
- `gateway/internal/admin/auth.go` — update to use `crypto.EncryptAES256GCM` if refactored
- `gateway/cmd/gateway/main.go` — wire `MatrixSessionStore`, register `/refresh`, cleanup goroutine

### Testing Notes

- **No mocks for DB:** Use real PostgreSQL (testcontainers or existing test DB setup) for `PostgresMatrixSessionStore` tests — same pattern as `migrations_042_integration_test.go`
- **Grace period test is mandatory** (AC4) — this is the spec MUST that's easiest to miss
- **`soft_logout: true` test is mandatory** (AC5) — requires DB row with manipulated `expires_at`
- **Backward compat test is mandatory** (AC7) — must not break existing clients

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Completion Notes List

- Implemented full Matrix v1.3 session refresh flow (all AC1–AC7 satisfied)
- DB migration: added `matrix_sessions` table with `grace_until` column for AC4 grace period semantics
- `MatrixSessionStore` interface defined in `gateway/internal/matrix/session_store.go` with `ErrMatrixSessionNotFound` sentinel
- `PostgresMatrixSessionStore` implemented in `gateway/internal/db/matrix_session_store.go` with type aliases for test access
- `db.MatrixSessionStore` also implements `middleware.OpaqueSessionLookup` interface (LookupOpaqueToken + MarkTokenUsed)
- `RefreshHandler` in `gateway/internal/matrix/refresh.go` handles `POST /refresh` — generates new opaque AT+RT, calls RotateTokens with 60s grace window
- `LoginRequest` extended with `RefreshToken bool` (v1.3 field); `LoginTokenResponse` extended with optional `ExpiresInMs` and `RefreshToken` fields
- `LoginHandler` now creates MatrixSession in `PostLogin` when SSO flow provides OIDC refresh token and `matrixSessions` store is configured
- `loginTokenEntry` in `sso.go` extended with `oidcRefreshToken` field so `GetSSOCallback` can pass the OIDC RT to `PostLogin`
- `buildSSOScopeList` now always includes `offline_access` (required for Keycloak to issue OIDC refresh tokens)
- `JWTMiddleware` in `auth.go` extended with `WithOpaqueSessionCheck` wrapper that validates opaque tokens and returns `soft_logout:true` for expired tokens (AC5)
- `main.go` wired: `MatrixSessionStore` → `LoginHandler`, `RefreshHandler` registered outside `jwtMiddleware`, `WithOpaqueSessionCheck` wraps `jwtMiddleware`, cleanup goroutine added
- MAJOR-2 fix: `iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase()` step implemented with real DB INSERT using `time.Now().Add(-2*time.Second)` for expires_at
- MINOR-3 fix: `withAuth` parameter removed from `doPostRefresh` (was unused; now uses `doPostRefreshRaw` directly)
- All 1564 unit tests pass (with -race flag via `make test-unit-go`)
- Existing `login_token_test.go` and `sso_extra_scopes_test.go` tests updated to work with refactored `pop()` return type and new `offline_access` base scope
- **Review cycle 1 fixes (2026-05-27):**
  - MAJOR-A: `LogoutHandler` now calls `MatrixSessionStore.Revoke(rawToken)` for opaque tokens (no dots); JWT tokens still go through `store.Invalidate()`. MINOR-5 fixed alongside: `ContextKeyTokenExpiry` (zero for opaque path) is no longer passed to `Invalidate` for opaque tokens. `MatrixSessions MatrixSessionStoreInterface` added to `LogoutConfig` and `LogoutHandler`. Wired in `main.go`. Three new unit tests cover the opaque revoke path, the nil-store fallback, and the error-non-fatal path.
  - MAJOR-B: `withAuth bool` parameter removed from `doPostRefresh` in integration test file; all call sites updated.
  - MINOR-1: `OpaqueSessionLookupResult` extended with `HasGraceWindow bool`; `LookupOpaqueToken` now queries for soft-revoked siblings with open grace windows; `WithOpaqueSessionCheck` only calls `MarkTokenUsed` when `HasGraceWindow` is true (avoids a write on every authenticated request).
  - MINOR-3: `slog.Warn` added in `PostLogin` when `oidcRefreshTokenFromSSO == ""` but `matrixSessions != nil` — admins now see misconfiguration.
  - MINOR-4: Encryption error in `encryptOIDCRefreshToken` call is now captured and logged via `slog.Warn` instead of being silently swallowed.
- **Review cycle 2 fixes (2026-05-27):**
  - MINOR-1: Two unit tests added to `auth_test.go` using `stubOpaqueSessionLookup`: `TestWithOpaqueSessionCheck_HasGraceWindowFalse` (verifies `MarkTokenUsed` is NOT called) and `TestWithOpaqueSessionCheck_HasGraceWindowTrue` (verifies `MarkTokenUsed` IS called with correct token).
  - MINOR-2 + INFO-2: `LookupOpaqueToken` in `matrix_session_store.go` refactored — the two-query pattern (main SELECT + separate `SELECT COUNT(*)`) replaced with a single query using a correlated `EXISTS` subquery that returns `has_grace` as an extra boolean column. Added `slog.Debug` log on query error (was previously silently dropped). Added `log/slog` import.
  - MINOR-3: Removed redundant `&& oidcRefreshTokenFromSSO != ""` inner guard in `PostLogin` (the outer `if h.matrixSessions != nil && oidcRefreshTokenFromSSO != ""` already guarantees it's non-empty). Added clarifying comment.

### Tasks / Subtasks

- [x] T1: DB migration — `matrix_sessions` table with grace_until column
- [x] T2: `MatrixSessionStore` interface in `gateway/internal/matrix/session_store.go`
- [x] T3: `PostgresMatrixSessionStore` in `gateway/internal/db/matrix_session_store.go` (CRUD + RotateTokens + grace period + OpaqueSessionLookup)
- [x] T4: `RefreshHandler` in `gateway/internal/matrix/refresh.go` (POST /refresh, outside jwtMiddleware)
- [x] T5: Modify `LoginRequest`/`LoginTokenResponse`/`LoginHandler`/`LoginConfig` in `login.go` for v1.3 refresh fields
- [x] T6: Modify `GetSSOCallback` in `sso.go` — add offline_access scope, pass OIDC RT to PostLogin via loginTokenEntry
- [x] T7: Modify `PostLogin` — create MatrixSession with opaque AT+RT after gRPC validation
- [x] T8: Extend `JWTMiddleware` with `WithOpaqueSessionCheck` in `auth.go` for opaque token validation + soft_logout
- [x] T9: Wire everything in `main.go` + cleanup goroutine
- [x] T10: Fix MAJOR-2 — implement AC5 step with real DB setup in integration test
- [x] T11: Fix broken `login_token_test.go` and `sso_extra_scopes_test.go` from refactoring
- [x] T12 (Review cycle 2): MINOR-1 — add unit tests for `WithOpaqueSessionCheck` `HasGraceWindow` branch (false → MarkTokenUsed not called; true → MarkTokenUsed called)
- [x] T13 (Review cycle 2): MINOR-2 + INFO-2 — fold `LookupOpaqueToken` 2-query roundtrip into single EXISTS subquery; add `slog.Debug` on query error
- [x] T14 (Review cycle 2): MINOR-3 — remove redundant `&& oidcRefreshTokenFromSSO != ""` inner guard in `PostLogin`

### File List

**New files:**
- `gateway/migrations/000001_init.up.sql` (modified — added `matrix_sessions` table)
- `gateway/migrations/000001_init.down.sql` (modified — added `DROP TABLE matrix_sessions`)
- `gateway/internal/matrix/session_store.go` — `MatrixSession`, `MatrixSessionStoreInterface`, `ErrMatrixSessionNotFound`, create/rotate params
- `gateway/internal/matrix/refresh.go` — `RefreshHandler`, `RefreshConfig`, `generateOpaqueToken`
- `gateway/internal/db/matrix_session_store.go` — `MatrixSessionStore` + type aliases + `OpaqueSessionLookup` impl

**Modified files:**
- `gateway/internal/matrix/login.go` — `LoginRequest`, `LoginTokenResponse`, `LoginHandler`, `LoginConfig`, `PostLogin`, `encryptOIDCRefreshToken`; MINOR-3 slog.Warn for missing OIDC RT; MINOR-4 encryption error logged
- `gateway/internal/matrix/logout.go` — MAJOR-A: `LogoutHandler` extended with `MatrixSessions` field; `PostLogout` now calls `Revoke` for opaque tokens, `Invalidate` for JWTs; MINOR-5: zero-time expiry bug avoided
- `gateway/internal/matrix/logout_test.go` — three new tests for MAJOR-A opaque token revocation path
- `gateway/internal/matrix/sso.go` — `loginTokenEntry`, `loginTokenStore.saveWithOIDCRT`, `buildSSOScopeList` (offline_access), `GetSSOCallback`
- `gateway/internal/middleware/auth.go` — `matrixErrorWithSoftLogout`, `OpaqueSessionLookupResult` (+ `HasGraceWindow` field), `OpaqueSessionLookup`, `WithOpaqueSessionCheck` (MINOR-1: conditional MarkTokenUsed)
- `gateway/internal/db/matrix_session_store.go` — MINOR-1: `LookupOpaqueToken` now sets `HasGraceWindow` by querying for soft-revoked siblings; MINOR-2: single-query EXISTS subquery (no 2nd roundtrip); INFO-2: `slog.Debug` on query error; `log/slog` import added
- `gateway/internal/middleware/auth_test.go` — MINOR-1: two new tests for `WithOpaqueSessionCheck` `HasGraceWindow` branch (`stubOpaqueSessionLookup` helper + `TestWithOpaqueSessionCheck_HasGraceWindowFalse` + `TestWithOpaqueSessionCheck_HasGraceWindowTrue`)
- `gateway/cmd/gateway/main.go` — MatrixSessionStore wiring, RefreshHandler registration, WithOpaqueSessionCheck, cleanup goroutine; MAJOR-A: `MatrixSessions` added to `LogoutConfig`
- `gateway/internal/matrix/login_token_test.go` — updated for new `pop()` return type
- `gateway/internal/matrix/sso_extra_scopes_test.go` — updated expected scopes (offline_access now in base list)
- `gateway/test/integration/matrix_session_refresh_steps_test.go` — MAJOR-B: `withAuth bool` parameter removed from `doPostRefresh` and all call sites updated; AC5 step implemented (real DB setup)

### Change Log

- 2026-05-27: Story implemented — Matrix v1.3 session refresh with opaque tokens, grace period (AC4), soft_logout (AC5), backward compat (AC7), /refresh endpoint, matrix_sessions DB table. All 1564 unit tests pass.
- 2026-05-27: Review cycle 1 — Fixed MAJOR-A (opaque token logout auth bypass: `LogoutHandler` now calls `MatrixSessionStore.Revoke` + MINOR-5 zero-expiry fix), MAJOR-B (removed unused `withAuth` param from `doPostRefresh`), MINOR-1 (conditional `MarkTokenUsed` via `HasGraceWindow` field), MINOR-3 (slog.Warn on missing OIDC RT), MINOR-4 (encryption error logged). All unit tests pass.
- 2026-05-27: Review cycle 2 — MINOR-1: added `TestWithOpaqueSessionCheck_HasGraceWindowFalse` and `TestWithOpaqueSessionCheck_HasGraceWindowTrue` unit tests in `auth_test.go`; MINOR-2+INFO-2: `LookupOpaqueToken` refactored to single EXISTS-subquery (one DB roundtrip) with `slog.Debug` on error; MINOR-3: removed redundant `&& oidcRefreshTokenFromSSO != ""` inner guard in `PostLogin`. All 1566 unit tests pass.
