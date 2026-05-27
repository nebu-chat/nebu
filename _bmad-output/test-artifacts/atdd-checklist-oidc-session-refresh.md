---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-generate-tests
lastStep: step-03-generate-tests
lastSaved: '2026-05-27'
storyId: oidc-session-refresh
storyKey: oidc-session-refresh
storyFile: docs/stories/bugfix/fix-short-oidc-sessions/oidc-session-refresh.md
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-oidc-session-refresh.md
generatedTestFiles:
  - gateway/features/matrix_session_refresh.feature
  - gateway/test/integration/matrix_session_refresh_steps_test.go
  - gateway/internal/db/matrix_session_store_test.go
inputDocuments:
  - docs/stories/bugfix/fix-short-oidc-sessions/oidc-session-refresh.md
  - gateway/features/auth.feature
  - gateway/test/integration/auth_steps_test.go
  - gateway/test/integration/steps_test.go
  - gateway/test/integration/main_test.go
  - gateway/test/integration/devices_steps_test.go
  - gateway/internal/db/tokenstore.go
  - _bmad/tea/config.yaml
---

# ATDD Checklist — oidc-session-refresh

## Story

Bug: Matrix User Sessions Expire After Short OIDC Token Lifetime

Epic: bugfix/fix-short-oidc-sessions
Branch: bugfix/fix-short-oidc-sessions

## Stack Detection

- Detected: `fullstack`
- Backend: Go + Godog (Gherkin, gateway/features/ → gateway/test/integration/)
- Frontend: Playwright + playwright-bdd (e2e/)
- Decision: This story is a backend protocol story only — no browser-level behavior.
  Godog scenarios cover all ACs. No Playwright scenario required (no UI interaction).

## Generated Test Files

### 1. `gateway/features/matrix_session_refresh.feature` — Gherkin Feature

Covers all 8 ACs + 3 spec edge cases. Scenarios:

| Scenario | AC | Expected in Red |
|---|---|---|
| AC1_Login_WithRefreshFlag_ReturnsOpaqueTokens | AC1 | FAIL — /login returns JWT, not opaque |
| AC7_Login_WithoutRefreshFlag_ReturnsJWT | AC7 | PASS — backward compat already works |
| AC2_Refresh_WithValidRT_ReturnsNewOpaqueTokens | AC2 | FAIL — /refresh endpoint → 404 |
| AC3_NewAccessToken_WorksForSync | AC3 | FAIL — opaque AT not recognized by middleware |
| AC3_NewAccessToken_WorksForWhoami | AC3 | FAIL — same reason |
| AC4_OldRT_ValidDuringGracePeriod_BeforeNewTokensUsed | AC4 | FAIL — /refresh → 404 |
| AC4_OldRT_RevokedAfterNewATIsUsed | AC4 | FAIL — /refresh → 404 |
| AC5_ExpiredOpaqueAT_ReturnsSoftLogout | AC5 | FAIL — matrix_sessions table missing |
| AC6_UnknownRT_Returns401 | AC6 | FAIL — /refresh → 404 |
| AC6_UsedAndReplacedRT_Returns401 | AC6 | FAIL — /refresh → 404 |
| Spec_Refresh_RequiresNoAuthHeader | Spec | FAIL — /refresh → 404 |
| Spec_Refresh_MissingBody_Returns400 | Spec | FAIL — /refresh → 404 |
| Spec_Refresh_MissingRefreshTokenField_Returns400 | Spec | FAIL — /refresh → 404 |

### 2. `gateway/test/integration/matrix_session_refresh_steps_test.go` — Godog Steps

- Build tag: `//go:build integration`
- Package: `integration_test`
- Registered via: `initializeMatrixSessionRefreshSteps(sc)` in steps_test.go
- go vet (integration tag): **No issues** — compiles cleanly

Key step functions:
- `iPostLoginWithDexTokenAndRequestRefreshToken` — POSTs with `refresh_token:true`
- `theAccessTokenIsAnOpaqueHexStringWithNoDots` — regex `^[0-9a-f]{64}$`, fails if dots present
- `theRefreshTokenIsAnOpaqueHexStringWithNoDots` — same regex
- `theExpiresInMsIsGreaterThanZero` — checks `expires_in_ms > 0`
- `iPostRefreshWithCurrentRefreshToken` — POST /refresh, no auth header
- `theNewAccessTokenIsAnOpaqueHexStringWithNoDots` — asserts new AT from /refresh
- `iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase` — explicitly returns error (RED)
- `theSoftLogoutFieldIsTrue` — asserts `soft_logout: true` in 401 body
- `iCaptureTheCurrentRefreshTokenAsRTA` / `iPostRefreshWithRTA` / `iPostRefreshWithRTAAgain` — grace-period test

### 3. `gateway/internal/db/matrix_session_store_test.go` — Unit Tests

- Build tag: none (plain unit, but skips if DB unreachable via `t.Skip`)
- go vet: **1 issue** (expected RED): `undefined: db.MatrixSessionStoreInterface`

Tests:
| Test | Covers |
|---|---|
| TestMatrixSessionStore_Create_InsertsRow | Create + GetByAccessToken round-trip |
| TestMatrixSessionStore_GetByAccessToken_NotFound | ErrNotFound sentinel |
| TestMatrixSessionStore_GetByRefreshToken_ReturnsSession | GetByRefreshToken |
| TestMatrixSessionStore_RotateTokens_OldRTValidDuringGracePeriod | AC4 grace-period + MarkAccessTokenUsed |
| TestMatrixSessionStore_Revoke_RemovesSession | Revoke |
| TestMatrixSessionStore_CleanupExpired_RemovesExpiredRows | CleanupExpired |

## AC ↔ Test Coverage Matrix

| AC | Gherkin Scenario | Unit Test | Status |
|---|---|---|---|
| AC1 — opaque AT+RT+expires_in_ms on login | AC1_Login_WithRefreshFlag_ReturnsOpaqueTokens | — | RED |
| AC2 — POST /refresh returns new tokens | AC2_Refresh_WithValidRT_ReturnsNewOpaqueTokens | — | RED |
| AC3 — new AT works for /sync and /whoami | AC3_NewAccessToken_WorksForSync + Whoami | — | RED |
| AC4 — old RT valid during grace period | AC4_OldRT_ValidDuringGracePeriod + AC4_OldRT_RevokedAfterNewATIsUsed | RotateTokens test | RED |
| AC5 — expired AT → soft_logout:true | AC5_ExpiredOpaqueAT_ReturnsSoftLogout | — | RED |
| AC6 — invalid/used RT → 401 | AC6_UnknownRT_Returns401 + AC6_UsedAndReplacedRT_Returns401 | — | RED |
| AC7 — backward compat (no refresh flag) | AC7_Login_WithoutRefreshFlag_ReturnsJWT | — | Expected PASS |
| AC8 — long session (8h) | No automated test (exploratory/manual) | — | Manual |
| Spec — /refresh needs no auth header | Spec_Refresh_RequiresNoAuthHeader | — | RED |
| Spec — missing body/field → 400 | Spec_Refresh_MissingBody + MissingField | — | RED |
| DB CRUD | — | Create, GetByAT, GetByRT, Revoke, Cleanup | RED (compile) |

## Red Phase Verification

- Gherkin: All scenarios registered. Suite will fail on first scenario (AC1)
  because `/login` does not return opaque tokens.
- Steps Go file: compiles clean with `-tags integration`. No undefined symbols
  (all referenced vars from other step files are in the same package).
- Unit test: fails to compile (`undefined: db.MatrixSessionStoreInterface`) — correct RED.

## Implementation Guide (for Developer)

Sequence of changes to turn RED → GREEN:

1. **Migration**: Add `matrix_sessions` table (AT hash, RT hash, user_id, device_id,
   expires_at, grace_active bool or old_rt_hash column for grace period tracking).
2. **MatrixSessionStore** in `gateway/internal/db/`: implement Create, GetByAccessToken,
   GetByRefreshToken, RotateTokens (with grace period), MarkAccessTokenUsed, Revoke,
   CleanupExpired. Export `MatrixSessionStoreInterface` and `ErrMatrixSessionNotFound`.
3. **POST /login** (`gateway/internal/matrix/login.go`): when `refresh_token: true` in
   request body, generate 32-byte opaque AT + RT, store via MatrixSessionStore, return
   `access_token`, `refresh_token`, `expires_in_ms` in response.
4. **POST /refresh** (`gateway/internal/matrix/refresh.go`): register outside jwtMiddleware.
   Look up session by RT, call RotateTokens, return new AT + expires_in_ms (+ new RT).
5. **JWTMiddleware**: add opaque token path. If token has no dots, look up in
   MatrixSessionStore. If found and not expired → proceed. If expired →
   `401 {"errcode":"M_UNKNOWN_TOKEN","soft_logout":true}`.
6. **CleanupExpired**: register background goroutine (e.g. every 15 min) or
   integrate into existing maintenance job.
