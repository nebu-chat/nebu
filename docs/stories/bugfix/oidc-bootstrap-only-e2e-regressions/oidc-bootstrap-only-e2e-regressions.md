---
story_id: bugfix-oidc-bootstrap-only-e2e-regressions
title: "Bug: ADR-022 bootstrap-only broke end-to-end OIDC — :no_keys during bootstrap + missing profile/groups scopes"
type: bug
severity: critical
epic: oidc-bootstrap-only
status: done
security_review: required
created: 2026-06-28
branch: feature/device-management
---

## Summary

The ADR-022 "OIDC bootstrap-only" change (commit `53a3cb4f`) passed all ExUnit gates but
**fails end-to-end** in the full-stack E2E verification: the global-setup bootstrap wizard
cannot complete, so the entire Playwright suite runs **0 tests**
(`expected:0, unexpected:0`, `playwright_exit=1`). Root cause is that removing the env-var
OIDC path also removed two things the live flow depended on — the boot-time JWKS source and
the requested OIDC scopes — without replacing them. Three concrete regressions, all from
the same under-scoped removal:

1. **`:no_keys` during bootstrap (the blocker).** Server log:
   `admin callback failed: :no_keys`. During the bootstrap wizard, OIDC config lives in
   `bootstrap_draft`, NOT yet in `server_config`. The admin operator-login callback verifies
   the ID token via `OidcPlug.verify_token/2`, which pulls JWKS from the global `JwksCache`
   (empty — it reads its URI from `server_config`/`OidcConfig`, unpopulated until bootstrap
   *completes*) and the issuer from `OidcConfig` (also empty). Previously
   `NEBU_OIDC_JWKS_URI` warmed `JwksCache` at boot, masking this; with env gone there is no
   JWKS source mid-bootstrap → `:no_keys` → deadlock (can't complete bootstrap because
   completing it is what would populate the keys).

2. **Missing `groups` scope → empty select-claim page.** `admin_oidc_scope/0` now returns a
   fixed `"openid profile email"` (no `groups`). Dex only releases the `groups` claim when
   the `groups` scope is requested. Without it the operator's token has no `groups` claim,
   so `extract_discovered_claims/1` produces no `instance_admin` option and the
   select-claim step has nothing to choose → bootstrap cannot finish even after (1) is fixed.

3. **Missing `profile` scope on Matrix SSO → MXID regression.** `SsoLogin.scope_list/0` now
   returns just `openid` (+`offline_access`). Without `profile`, Dex omits the `name` claim,
   so `oidc_user_id_claim = "name"` cannot resolve and the MXID falls back to `sub` — the
   exact regression previously fixed by `df249f8c` (the `NEBU_OIDC_EXTRA_SCOPES="profile
   email"` setting that this change deleted).

The ADR-022 decision (bootstrap-only, single client, no env) stands — this story makes that
decision actually work end-to-end.

## Root Cause Analysis

ADR-022 removed `NEBU_OIDC_JWKS_URI` (which warmed `JwksCache` at boot) and
`NEBU_OIDC_EXTRA_SCOPES` / `NEBU_ADMIN_OIDC_SCOPE` (which requested `profile`/`email`/
`groups`). The implementation assumed (a) bootstrap-mode verification could use the global
caches and (b) the IdP releases standard claims without their scopes — both false. The
bootstrap flow needs JWKS from the draft; the IdP needs the scopes requested explicitly.

## Acceptance Criteria

**AC1 — Bootstrap-mode token verification uses the draft (fixes `:no_keys`):** During the
bootstrap operator-login callback, the ID token is verified using JWKS fetched from the
**bootstrap draft's** `oidc_jwks_uri` (or discovered from the draft's `oidc_issuer`) and the
draft's issuer/client_id — NOT the global `JwksCache`/`OidcConfig`. Verification succeeds on
a fresh DB with no env and empty `server_config`.

**AC2 — Fail-closed invariant preserved (no global-cache pollution):** The bootstrap-mode
path MUST NOT write the draft config into the global `JwksCache`/`OidcConfig` (those stay
empty until bootstrap completes). Concretely: while bootstrap is in progress, a Matrix
Bearer request still returns `401` (the Matrix API does not start accepting tokens until
`bootstrap_completed=true` and the caches are refreshed from `server_config`). This is the
ADR-022 security invariant and the reason the fix is local-verification, not early
cache-warming.

**AC3 — `groups` scope requested for admin/bootstrap login:** The admin (and bootstrap-mode
operator) OIDC authorization request includes the `groups` scope so the token carries the
`groups` claim. After Dex login, the select-claim page renders the `instance_admin` option
and bootstrap completes to `/admin/dashboard`.

**AC4 — `profile`/`email` scopes requested for Matrix SSO:** The Matrix SSO authorization
request includes `profile` (and `email`) so the `name`/`email` claims are present. A user
logging in via Matrix SSO gets an MXID derived from `oidc_user_id_claim = "name"`, NOT `sub`.

**AC5 — Scopes are a sensible fixed/derived default, not env:** No `NEBU_OIDC_*` /
`NEBU_ADMIN_OIDC_SCOPE` env var is reintroduced (ADR-022 holds). The requested scopes are
either fixed defaults (Matrix: `openid profile email` [+`offline_access` when refresh mode
is offline]; admin/bootstrap: `openid profile email groups`) or derived from the configured
claim mappings. `offline_access` behavior (refresh mode) is unchanged.

**AC6 — Full E2E suite goes green:** After this fix, the central full-stack E2E run
(fresh DB + single-client Dex + wizard bootstrap) completes global-setup and runs the suite
to a green result (no `0 tests`, no bootstrap deadlock). [Verified centrally by the operator,
not in this pipeline.]

## Persistence Strategy

**Stateless / DB-draft.** No new GenServer state. Bootstrap-mode verification reads the
existing `bootstrap_draft` rows and fetches JWKS over HTTP per callback (same TLS-verifying
fetcher `JwksCache` uses). Post-bootstrap behavior is unchanged (global caches, refreshed on
completion). No crash/restart test needed beyond the existing OidcConfig/JwksCache boot
tests.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **Bootstrap-mode verify succeeds with empty global caches** — ExUnit
   - Given: empty `OidcConfig`/`JwksCache` (no server_config OIDC), a bootstrap draft with
     `oidc_issuer`/`oidc_jwks_uri`/`oidc_client_id`, and a draft-signed ID token (use the
     existing JWKS/token test seam pointed at the draft jwks)
   - When: the bootstrap callback verifies the operator ID token
   - Then: `{:ok, claims}` — proving keys+issuer come from the draft, not the global cache
   - (RED before the draft-JWKS path exists: currently `:no_keys`)

2. **Fail-closed preserved during bootstrap** — ExUnit
   - Given: bootstrap in progress (draft set, `bootstrap_completed` not true), global caches
     empty
   - When: a Matrix Bearer request hits `OidcPlug`
   - Then: `401` — the draft path did NOT warm the global caches

3. **Admin/bootstrap scope includes `groups`** — ExUnit
   - When: building the admin/bootstrap authorization URL / scope
   - Then: scope string contains `groups` (and `openid profile email`)

4. **Matrix SSO scope includes `profile`** — ExUnit
   - When: `SsoLogin.scope_list/0` builds the scope (online mode)
   - Then: contains `openid profile email`; offline mode additionally contains
     `offline_access` (regression for the refresh-mode behavior)

5. **MXID derives from `name` claim** — ExUnit (using the claim-mapping resolution path)
   - Given: a token with `name` present and `oidc_user_id_claim = "name"`
   - Then: the resolved user_id derives from `name`, not `sub`

## Implementation Notes (non-binding map)

- `web/plugs/oidc_plug.ex` — extend `verify_token/2` to accept `:issuer` and `:jwks` (key
  list) overrides alongside the existing `:audience` (so the bootstrap path can pass
  draft-sourced issuer + keys). Keep `check_issuer`/`available_keys` using the global source
  when no override is given (normal post-bootstrap login unchanged).
- `admin/auth.ex` — in the bootstrap-mode `exchange_and_verify`, fetch JWKS from the draft's
  `oidc_jwks_uri` (or discover via the draft issuer) using the same TLS-verifying fetcher,
  and call `verify_token(id_token, issuer: draft_issuer, audience: cfg.client_id, jwks: keys)`.
  Add `groups` to `admin_oidc_scope/0` (→ `"openid profile email groups"`).
- `matrix/sso_login.ex` — `scope_list/0` base becomes `~w(openid profile email)` (keep the
  `offline_access`-when-offline logic).
- Optionally factor a small shared "fetch JWKS for an explicit uri/issuer" helper out of
  `JwksCache` so the bootstrap path reuses the same TLS/discovery logic.
- E2E fixture is already updated for the single client; no further fixture change expected
  beyond what global-setup needs (the scopes are server-side).

## Security Review Scope (Kassandra — required)

Touches token verification (`:crypto`/JOSE), admin auth, and OIDC scopes. Verify:
**fail-closed preserved** (AC2 — the draft path must not let the Matrix API accept tokens
before bootstrap completes); the draft-sourced JWKS fetch uses the same TLS peer
verification as `JwksCache` (no downgrade); the new `:issuer`/`:jwks` overrides on
`verify_token` cannot be triggered on the normal request path (only the bootstrap callback
passes them); adding `groups`/`profile` scopes does not over-request beyond standard OIDC
claims; alg-allowlist / exp / nonce / PKCE checks unchanged.

## Status

review

## File List

- `server/lib/nebu/web/plugs/oidc_plug.ex` (modified) — `verify_token/2` accepts
  `:issuer` + `:jwks` overrides; `select_key/2` honors a jwks override; `check_issuer/2`
  honors an issuer override. Both fail-closed; absent → unchanged global resolution.
- `server/lib/nebu/web/jwks_cache.ex` (modified) — new public `fetch_keys_for/2`
  (explicit jwks_uri/issuer fetch, no cache/OidcConfig mutation); refactored discovery
  into shared `discover_jwks_uri_and_fetch_for/1` (OidcConfig read only in the global path).
- `server/lib/nebu/admin/auth.ex` (modified) — bootstrap-mode `exchange_and_verify`
  verifies via draft issuer+JWKS (`verify_id_token/3`); `oidc_config("bootstrap")` surfaces
  draft `jwks_uri`; `admin_oidc_scope/0` base → `openid profile email groups`.
- `server/lib/nebu/matrix/sso_login.ex` (modified) — `@base_scopes` →
  `~w(openid profile email)`; moduledoc + scope comment updated.
- `server/test/nebu/matrix/sso_login_scope_test.exs` (modified) — reconciled the
  superseded `fix-element-login` `~w(openid)` assertions to the new
  `openid profile email` contract.
- `server/test/nebu/matrix/sso_scope_mode_test.exs` (modified) — same reconciliation
  (the two stale `refute "profile"/"email"` lines + moduledoc).
- `server/test/nebu/matrix/sso_login_configured_claim_device_test.exs` (modified) —
  narrative comments corrected to the new base scope (no assertion change).

## Dev Agent Record

### Completion Notes

Implemented all 6 ACs. Three regressions fixed:

1. AC1/AC2 — `:no_keys` during bootstrap: `verify_token/2` now accepts `:issuer`/`:jwks`
   overrides; the bootstrap callback fetches keys locally from the draft via the new
   `JwksCache.fetch_keys_for/2` (same TLS-verifying fetcher) and verifies with the draft
   issuer+keys. The global `JwksCache`/`OidcConfig` are NEVER warmed — the #1 invariant.
   A draft JWKS fetch failure returns the tagged `{:error, :bootstrap_jwks_unavailable}`
   so the callback logs + bounces, never crashes. The normal request path passes no
   overrides → unchanged global, fail-closed resolution (proven by the AC2 guard tests).
2. AC3 — `admin_oidc_scope/0` base → `openid profile email groups` (admin + bootstrap).
3. AC4/AC5 — `SsoLogin.@base_scopes` → `openid profile email`; offline_access logic intact.

Two pre-existing tests asserted the superseded `fix-element-login` `~w(openid)` minimal
scope (`sso_login_scope_test.exs` named in the brief, plus `sso_scope_mode_test.exs`
discovered during the run). Both were converted into correct regression guards for the new
default; no new ATDD test file was weakened. AC6 (full E2E green) is verified centrally by
the operator, out of this pipeline.

Full unit suite: 934 passed, 2 skipped, 200 excluded. `mix test --warnings-as-errors`
exit code 0.

## Change Log

- 2026-06-28 — Fixed ADR-022 bootstrap-only end-to-end regressions (`:no_keys` during
  bootstrap via draft-local token verification; `groups` scope for admin/bootstrap;
  `profile`/`email` scopes for Matrix SSO). Reconciled two superseded scope tests.
