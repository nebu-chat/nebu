# Oracle Context — oidc-session-refresh (2026-05-27)

## Spec Compliance: Matrix Client-Server API v1.18 §refreshing-access-tokens (Added v1.3)

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

`/_matrix/client/versions` already advertises `v1.3` (main.go:601) — no change needed there.

## OIDC Scope: `offline_access`

Adding `offline_access` to `buildSSOScopeList()` in `sso.go` is required for Keycloak to issue a refresh token. Without this scope, `token.RefreshToken` will be empty.

Keycloak configuration note: The Nebu OIDC client in Keycloak must have "Offline Access" scope enabled. For STACKIT deployments, verify this is configured.
