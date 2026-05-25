---
story_id: 5-30
title: "Bug: Hardcoded OIDC Extra Scopes Break Auth Code Exchange with Keycloak"
type: bug
severity: high
epic: 5
status: done
security_review: not-needed
created: 2026-05-24
---

## Summary

The admin OIDC login and bootstrap flows hardcode `groups` and `offline_access` as additional
authorization scopes in every auth request. These scopes are Dex-specific:

- `groups` is not a standard OIDC scope and is absent from many providers' `scopes_supported`
  (e.g. the INNOQ Keycloak realm at `identity.innoq.io`).
- `offline_access` causes Keycloak to issue a code linked to an **offline session**. If the
  Keycloak client does not have `offline_access` enabled, the code exchange fails with
  `invalid_grant: "Code not valid"` — because Keycloak cannot fulfill the offline-session
  token type at exchange time, even though it accepted the auth request.

Both scopes are harmless for Dex but actively break the Authorization Code flow for Keycloak
and other providers where these scopes are not granted.

## Root Cause

Two locations in `gateway/internal/admin/auth.go` hardcode the scope list:

```go
// LoginStartHandler (~line 512) and CallbackHandler (~line 717)
Scopes: []string{oidc.ScopeOpenID, "profile", "email", "groups", "offline_access"},
```

`offline_access` is sent in the **auth request** (via `AuthCodeURL`). The Go `oauth2` library
does *not* send scopes in the token exchange itself (`Exchange` only sends
`grant_type`, `code`, `redirect_uri`, and `code_verifier`). However, when `offline_access` is
present in the auth request, Keycloak creates an offline-session-backed code. Exchange of such
a code fails if the client's offline access is not permitted.

## Fix

1. Add `oidc_extra_scopes` as a configurable key in both `server_config` (regular login) and
   `bootstrap_draft` (bootstrap flow). The value is a space-separated list of additional scopes,
   e.g. `"groups offline_access"` for Dex or `""` (empty) for Keycloak.

2. Read `oidc_extra_scopes` in `LoadOIDCConfig` and `loadOIDCConfigFromDraft` alongside the
   existing `oidc_issuer`, `oidc_client_id`, `oidc_client_secret` keys.

3. Use the configured extra scopes in `LoginStartHandler` (the only place that actually calls
   `AuthCodeURL` — the scopes in `CallbackHandler`'s oauth2Config are not sent during Exchange
   but keep them consistent for clarity).

4. Add `NEBU_OIDC_EXTRA_SCOPES` env-var fallback: if `oidc_extra_scopes` is not set in the DB,
   fall back to this env var. Default value when env var is also absent: `""` (empty — no
   custom scopes, just `openid profile email`).

5. Update `docker-compose.yml` (Dex dev environment): set
   `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` so existing Dex tests are unaffected.

6. Update `deploy/tofu/examples/stackit/cloud-init.tftpl`: when `oidc_mode = "dex"`, inject
   `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` into the gateway environment. Leave it unset
   (empty) for `oidc_mode = "external"`.

## Acceptance Criteria

### AC1: Standard scopes are always sent
- Auth request always includes `openid profile email`.
- No extra scopes are added unless `oidc_extra_scopes` / `NEBU_OIDC_EXTRA_SCOPES` is set.

### AC2: Extra scopes are configurable via env var
- When `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` is set, the auth request includes those
  two scopes in addition to the standard ones.
- When `NEBU_OIDC_EXTRA_SCOPES=` (empty), no extra scopes are added.

### AC3: Extra scopes stored in server_config / bootstrap_draft take precedence over env var
- `oidc_extra_scopes` key in `server_config` overrides the env-var fallback when present.
- Same for `bootstrap_draft` during the bootstrap flow.

### AC4: Existing Dex integration tests pass unchanged
- `make test-unit-go` passes with `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` in the
  test environment.
- All existing OIDC integration tests remain green.

### AC5: Keycloak (external OIDC) login works without custom scopes
- With empty `oidc_extra_scopes` and no `NEBU_OIDC_EXTRA_SCOPES`, the auth request only
  includes `openid profile email`. No `invalid_grant: "Code not valid"` error from Keycloak.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **TestLoginStartScopesDefaultEmpty** — Go unit test (httptest)
   - Given: `NEBU_OIDC_EXTRA_SCOPES` unset, no `oidc_extra_scopes` in DB
   - When: `LoginStartHandler` is called
   - Then: redirect URL contains `scope=openid+profile+email` (no `groups`, no `offline_access`)

2. **TestLoginStartScopesFromEnvVar** — Go unit test (httptest)
   - Given: `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`
   - When: `LoginStartHandler` is called
   - Then: redirect URL contains `scope=openid+profile+email+groups+offline_access`

3. **TestLoginStartScopesFromDBOverridesEnv** — Go unit test (httptest)
   - Given: `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`, DB has `oidc_extra_scopes=roles`
   - When: `LoginStartHandler` is called
   - Then: redirect URL contains `roles` but NOT `groups` or `offline_access`

4. **TestBootstrapFlowScopesFromDraft** — Go unit test (httptest)
   - Given: bootstrap_draft has `oidc_extra_scopes=""`, no env var
   - When: `LoginStartHandler` is called with `mode=bootstrap`
   - Then: redirect URL contains only `openid profile email`

## Implementation Notes

- `server_config` is a key-value table — no DB migration needed for a new key (SQL `WHERE key
  IN (...)` returns zero rows for missing keys, which maps to empty string → correct default).
- `bootstrap_draft` (same key-value approach) — same, no migration needed.
- `LoadOIDCConfig` currently returns `(issuer, clientID, clientSecret, err)`. Extend signature
  to `(issuer, clientID, clientSecret, extraScopes string, err error)`.
- `ServerConfigReader` interface update is required — update all implementors (real + mock).
- Both handlers should split `extraScopes` on whitespace and append non-empty tokens to the
  base scope list `[]string{oidc.ScopeOpenID, "profile", "email"}`.

## Tasks

- [x] Extend `LoadOIDCConfig` interface and `postgresServerConfigReader` to return `extraScopes`
- [x] Update `loadOIDCConfigFromDraft` to also read and return `oidc_extra_scopes`
- [x] Add `buildScopeList` and `resolveExtraScopes` helpers in `auth.go`
- [x] Update `LoginStartHandler` to use configurable extra scopes (DB + env var fallback)
- [x] Update `CallbackHandler` to use configurable extra scopes for consistency
- [x] Fix `middleware.go` (`attemptTokenRefresh`) for updated `LoadOIDCConfig` signature
- [x] Update `fakeServerConfigReader.LoadOIDCConfig` in `login_test.go` (5-return signature)
- [x] Fix `fakeServerConfigReader.LoadServerConfigKey` to return `sql.ErrNoRows` by default
- [x] Update all other test doubles for new `LoadOIDCConfig` signature
- [x] Fix `TestOfflineAccessScopeInCallback` to set `NEBU_OIDC_EXTRA_SCOPES=offline_access`
- [x] Add `TestLoginStartScopesEmptyEnvVar` (MINOR: isolated empty-env-var sub-case)
- [x] Add `TestLoginStartScopesDBMultiToken` (MINOR: multi-token DB value for AC3)
- [x] Fix nil context in `scopedFakeConfigReader.LoadServerConfigKey` fallback (MINOR)
- [x] Update `docker-compose.yml` with `NEBU_OIDC_EXTRA_SCOPES=groups offline_access`
- [x] Update `cloud-init.tftpl` with conditional `NEBU_OIDC_EXTRA_SCOPES` for dex/external mode
- [x] Run `make test-unit-go` — all tests green

### Review Follow-ups (AI)

- [x] [AI-Review] MAJOR-1: DB errors in `LoginStartHandler` and `CallbackHandler` silently treated as "key present" — fixed with switch/default + `slog.WarnContext` + `extraScopesAbsent = true` fallback
- [x] [AI-Review] MAJOR-2: `loadOIDCConfigFromDraft` discarded `ok` bool for `oidc_extra_scopes`; bootstrap mode block always set `extraScopesAbsent = false` — fixed: function now returns `extraScopesAbsent bool` (6th return value), callers updated in both `LoginStartHandler` and `CallbackHandler`
- [x] [AI-Review] MINOR-1: `buildScopeList` did not deduplicate — fixed: seen-set dedup preserves order, drops duplicate extra scopes already in base list

### Review Follow-ups (AI) — Cycle 2

- [x] [AI-Review] MINOR-1 (cycle 2): `postgresServerConfigReader.LoadOIDCConfig` redundantly queried `oidc_extra_scopes` — removed from SQL `WHERE key IN (...)` clause; function now returns `""` for extraScopes (callers use `LoadServerConfigKey` for the actual lookup)
- [x] [AI-Review] MINOR-2 (cycle 2): No regression test for `buildScopeList` deduplication — added `TestBuildScopeListDedup` to `auth_extra_scopes_test.go`; asserts that base-scope duplicates in extra-scopes input are dropped and final list has no duplicates
- [x] [AI-Review] MINOR-3 (cycle 2): `recordingServerConfigReader.LoadServerConfigKey` returned `("", nil)` for unknown keys — fixed to return `("", sql.ErrNoRows)`; same fix applied to `txAwareConfigStore.LoadServerConfigKey` in `claim_selection_tx_test.go`

### Review Follow-ups (AI) — Cycle 3

- [x] [AI-Review] MINOR-1+5 (cycle 3): misleading doc comment on `LoadOIDCConfig` (claimed implementors did not need updating) — corrected; both `LoginStartHandler` and `CallbackHandler` now use `_` for the 4th return value of `LoadOIDCConfig` and declare `extraScopesFromSource` separately, making the dead-value discard explicit in the code
- [x] [AI-Review] MINOR-2 (cycle 3): no unit test for CallbackHandler DB error fallback — added `TestResolveExtraScopesDBError` to `auth_extra_scopes_test.go`; tests `resolveExtraScopes("", true)` with `NEBU_OIDC_EXTRA_SCOPES=fallback_scope` set, verifying the env-var fallback is returned (this is the exact call both handlers make in the `default` switch branch after a non-ErrNoRows DB error)

## Dev Agent Record

### Completion Notes

Implementation complete. All 6 acceptance tests pass (4 from ATDD + 2 new sub-cases from MINOR findings).

Key decisions:
- `LoadOIDCConfig` return signature extended to include `extraScopes string` as the 4th return value. All callers updated.
- `loadOIDCConfigFromDraft` extended the same way — `oidc_extra_scopes` is read from `bootstrap_draft` as an optional key (absent = empty string).
- Precedence logic: DB key present (even if empty) wins over env var; DB key absent → fall back to `NEBU_OIDC_EXTRA_SCOPES`; both absent → empty = standard scopes only.
- `resolveExtraScopes(dbVal, dbAbsent)` encapsulates the precedence rule.
- `buildScopeList(extraScopes)` appends non-empty whitespace-separated tokens to the base `[openid, profile, email]` list, with deduplication (seen-set, order preserved).
- `fakeServerConfigReader.LoadServerConfigKey` now returns `sql.ErrNoRows` by default (simulating missing key) instead of `("", nil)` (simulating present-but-empty key). This is semantically correct and required for the env-var fallback to work in tests that don't configure a DB key.
- `TestOfflineAccessScopeInCallback` (Story 9.14 test) updated to set `NEBU_OIDC_EXTRA_SCOPES=offline_access` — the test continues to verify the offline session behavior, now via the new configurable mechanism.
- No DB migration needed: `server_config` and `bootstrap_draft` are key-value tables; missing keys simply return no rows.

Review cycle 1 fixes (2026-05-24):
- MAJOR-1: `LoginStartHandler` and `CallbackHandler` now use a switch/default on `LoadServerConfigKey` error; non-`ErrNoRows` DB errors log a `slog.WarnContext` warning and fall back to env var (`extraScopesAbsent = true`) instead of silently treating them as "key present, empty value".
- MAJOR-2: `loadOIDCConfigFromDraft` now returns a 6th value `extraScopesAbsent bool` (true when `oidc_extra_scopes` key absent from draft). Bootstrap mode blocks in both handlers now propagate this value correctly instead of hardcoding `false`.
- MINOR-1: `buildScopeList` now deduplicates using a seen-set; extra scopes already in the base list are silently dropped, preserving order.

Review cycle 2 fixes (2026-05-24):
- MINOR-1: Removed `oidc_extra_scopes` from `postgresServerConfigReader.LoadOIDCConfig` SQL query. The function now always returns `""` for extraScopes; callers already use `LoadServerConfigKey("oidc_extra_scopes")` which correctly distinguishes absent-key vs empty-value. Interface signature unchanged (4th return value stays `""` — no test double updates needed).
- MINOR-2: Added `TestBuildScopeListDedup` to `auth_extra_scopes_test.go` to lock in the deduplication behaviour of `buildScopeList`. Input `"openid roles email custom"` asserts final list is `[openid, profile, email, roles, custom]` (no duplicates from base-scope overlap).
- MINOR-3: `recordingServerConfigReader.LoadServerConfigKey` (in `claim_mapping_handler_test.go`) now returns `("", sql.ErrNoRows)` for unknown keys. `txAwareConfigStore.LoadServerConfigKey` (in `claim_selection_tx_test.go`) fixed the same way. Both now mirror `fakeServerConfigReader`.

Review cycle 3 fixes (2026-05-24):
- MINOR-1+5: Updated `LoadOIDCConfig` doc comment — no longer claims "implementors do not need to be updated" (they were all updated). Both `LoginStartHandler` and `CallbackHandler` now discard the 4th return value of `LoadOIDCConfig` with `_` and declare `extraScopesFromSource` separately, making it explicit that the value is intentionally discarded and assigned only inside the `LoadServerConfigKey` switch.
- MINOR-2: Added `TestResolveExtraScopesDBError` to `auth_extra_scopes_test.go`. Verifies that `resolveExtraScopes("", true)` (the call both handlers make after a non-ErrNoRows DB error) returns the `NEBU_OIDC_EXTRA_SCOPES` env-var value, proving the fallback path works correctly for `CallbackHandler` (which shares the same `resolveExtraScopes` function as `LoginStartHandler`).

## File List

- `gateway/internal/admin/auth.go` — extended `LoadOIDCConfig` interface + implementation, `loadOIDCConfigFromDraft`, `LoginStartHandler`, `CallbackHandler`; added `buildScopeList`, `resolveExtraScopes`; added `os` import
- `gateway/internal/admin/middleware.go` — updated `attemptTokenRefresh` for new `LoadOIDCConfig` signature
- `gateway/internal/admin/auth_extra_scopes_test.go` — fixed `LoadOIDCConfig` return count, nil-context fix, added `TestLoginStartScopesEmptyEnvVar` and `TestLoginStartScopesDBMultiToken`
- `gateway/internal/admin/login_test.go` — updated `fakeServerConfigReader.LoadOIDCConfig` + `LoadServerConfigKey`, added `database/sql` import
- `gateway/internal/admin/claim_mapping_handler_test.go` — updated `recordingServerConfigReader.LoadOIDCConfig`
- `gateway/internal/admin/claim_selection_tx_test.go` — updated `txAwareConfigStore.LoadOIDCConfig`
- `gateway/internal/admin/token_refresh_9_14_test.go` — updated `TestOfflineAccessScopeInCallback` to set `NEBU_OIDC_EXTRA_SCOPES=offline_access`
- `docker-compose.yml` — added `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` to gateway service
- `deploy/tofu/examples/stackit/cloud-init.tftpl` — added conditional `NEBU_OIDC_EXTRA_SCOPES` (dex: `groups offline_access`, external: empty)

## Change Log

- 2026-05-24: Implemented configurable OIDC extra scopes (story 5-30). Extended `ServerConfigReader.LoadOIDCConfig` interface, fixed hardcoded `groups offline_access` scopes in `LoginStartHandler` and `CallbackHandler`, added env-var fallback `NEBU_OIDC_EXTRA_SCOPES`, updated docker-compose.yml and cloud-init.tftpl for Dex dev environment. All tests green.
- 2026-05-24: Review cycle 1 fixes — addressed MAJOR-1 (DB error silently ignored in LoadServerConfigKey fallback), MAJOR-2 (loadOIDCConfigFromDraft now returns extraScopesAbsent bool; bootstrap blocks propagate it), MINOR-1 (buildScopeList deduplication). All tests remain green.
- 2026-05-24: Review cycle 2 fixes — MINOR-1: removed redundant oidc_extra_scopes from LoadOIDCConfig SQL query (callers use LoadServerConfigKey); MINOR-2: added TestBuildScopeListDedup regression test for dedup behaviour; MINOR-3: fixed recordingServerConfigReader and txAwareConfigStore LoadServerConfigKey to return sql.ErrNoRows for unknown keys. All tests green.
- 2026-05-24: Review cycle 3 fixes — MINOR-1+5: corrected LoadOIDCConfig doc comment; both handlers now use _ for 4th return value of LoadOIDCConfig and declare extraScopesFromSource separately (explicit dead-value discard); MINOR-2: added TestResolveExtraScopesDBError for CallbackHandler DB error fallback path. All tests green.
