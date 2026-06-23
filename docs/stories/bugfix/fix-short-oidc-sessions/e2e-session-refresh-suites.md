---
story_id: e2e-session-refresh-suites
title: "Complete the 3 pending browser e2e suites for OIDC session refresh (Matrix AC8, Admin AC4, refresh-mode AC5/AC6)"
type: test
severity: medium
epic: fix-short-oidc-sessions
status: done
security_review: required
created: 2026-06-23
branch: feature/full-elixir-stack
matrix: true
ui: true
---

## Summary

The `fix-short-oidc-sessions` epic shipped the OIDC session-refresh stack (Matrix opaque
tokens + `POST /_matrix/client/v3/refresh`, admin silent refresh, configurable refresh mode)
with full ExUnit coverage, but three **browser** acceptance suites were left as `@pending`
RED stubs because they need a way to make access tokens expire fast enough to exercise the
refresh loop in a test window. They are carried as open follow-ups in the epic traceability
matrix (`trace-fix-short-oidc-sessions-2026-06-22.md`):

1. **Matrix AC8** — `e2e/features/element/auth/matrix-session-refresh.feature` — an Element
   Web session must survive past the access-token lifetime via silent refresh (no Dex re-login),
   plus the opaque-token / soft-logout assertions.
2. **Admin AC4** — `e2e/features/admin/admin-session-refresh.feature` — an operator doing
   normal Admin UI navigation stays authenticated past the short access-token lifetime (silent
   refresh in `fetch_current_user/2`), without being bounced to `/admin/login`.
3. **Refresh-mode AC5/AC6** — `e2e/features/admin/oidc-refresh-mode.feature` — the bootstrap
   wizard and `/admin/config` expose per-client refresh-mode selectors + the Dex caveat hint,
   and the `/admin/config` change persists at runtime.

The blocker is a missing **short-lived-session enabler**: today both the Matrix opaque-AT
expiry (`Nebu.Matrix.HttpPublic.session_expires_at/1`, `@max_session_seconds = 8 * 3600`) and
the admin session expiry (`Nebu.Admin.Auth.session_expiry/1`, `@session_ttl_seconds = 8h`) are
**hardcoded** to an 8h ceiling, and Dex's `expiry.idTokens` is a global 24h. There is no way to
make a session expire in seconds for a deterministic test. This story adds a small,
production-neutral **configurable session-TTL seam** (env var, default 8h — behavior unchanged
in prod), wires it short in the e2e stack, then implements and un-pends the three suites using
the existing real Authorization-Code + PKCE browser helpers (NO ROPC, NO cookie forging, NO DB
seeding — CLAUDE.md E2E standard).

## Acceptance Criteria

**AC1 — Configurable session-TTL seam (default unchanged), covering BOTH login and refresh:**
The Matrix opaque-AT ceiling and the admin session ceiling are read from configuration with a
default of `8 * 3600` seconds. New env vars (wired in `server/config/runtime.exs`):
`NEBU_MATRIX_SESSION_TTL_SECONDS` and `NEBU_ADMIN_SESSION_TTL_SECONDS`. When unset, the
computed expiry is **byte-for-byte identical to today** (`min(oidc_exp, now + 8h)`). The value
is parsed defensively (non-integer / ≤0 → fall back to the 8h default; never crash the login
path). This is the only server-code change in the story.
**Both uses of `@max_session_seconds` in `http_public.ex` must route through the seam:** the
login path `session_expires_at/1` (line ~372) AND the `/v3/refresh` re-mint path (line ~429,
`DateTime.add(utc_now, @max_session_seconds, :second)`). If the refresh re-mint keeps the
hardcoded 8h, the refreshed session reverts to 8h in the e2e stack and the Matrix refresh suite
cannot fail-for-the-right-reason. After the change `@max_session_seconds` should have no
remaining direct callers (replaced by one helper, e.g. `matrix_session_ttl_seconds/0`).

**AC2 — Matrix refresh suite green (`matrix-session-refresh.feature`, AC8):**
With a short `NEBU_MATRIX_SESSION_TTL_SECONDS` in the e2e stack: a real Element Web login via
Dex (Auth Code + PKCE) issues opaque tokens (`refresh_token: true` path); the session survives
past the short lifetime (matrix-js-sdk silently refreshes via `/v3/refresh`); the user is NOT
redirected to the Dex login page and the room list stays visible; the stored Matrix access
token is opaque (64 hex, no `.`), not a JWT; and a server-side-expired/revoked session yields a
soft-logout state rather than a hard kick.

**AC3 — Admin refresh suite green (`admin-session-refresh.feature`, AC4):**
With a short `NEBU_ADMIN_SESSION_TTL_SECONDS`: a real admin login via Dex (Auth Code + PKCE)
stays authenticated while the operator navigates the Admin UI across one and several token
lifetimes (silent refresh on the HTTP round-trip in `fetch_current_user/2`); the operator is
never redirected to `/admin/login` and the LiveView root stays attached.

**AC4 — Refresh-mode suite green (`oidc-refresh-mode.feature`, AC5/AC6):**
The bootstrap wizard shows both refresh-mode selectors (`offline`/`online`) preselected
Matrix=`offline` / Admin=`online` with the Dex-caveat hint; the `/admin/config` page shows the
same selectors + hint and persists a runtime change (set admin mode → `offline`, assert
persisted) with no redeploy. Driven through the real PKCE admin flow.

**AC5 — Suites un-pended and in the default run:**
The `@pending-feature` / `@pending` exclusion tags are removed from all three feature files so
they execute under the default `playwright.config.ts` `tags: 'not @pending-feature'` filter.
The traceability matrix is updated (AC8 / admin-AC4 / mode-AC5/6 → ✅ green, e2e).

**AC6 — No test-standard violations:**
No ROPC / `grant_type=password`, no cookie forging, no DB seeding. All logins reuse the
existing helpers (`fixtures/dex-auth.ts` `loginViaOidcBrowser`, the admin `authenticateAtDex`
pattern, `fixtures/element-app.ts` `ElementAppPage`). Tests are deterministic (no arbitrary
sleeps beyond the single, necessary wait past the configured short TTL; that wait is derived
from the configured value, not a magic constant).

**AC7 — Production default regression guard:**
A unit/integration test asserts that with the env vars **unset**, `session_expires_at/1`
(Matrix) and `session_expiry/1` (admin) produce exactly the pre-existing `min(oidc_exp, now+8h)`
result — proving the seam is inert in production.

## Acceptance Tests

### Tests written FIRST (already exist as RED feature files + the new guard):

1. **`session_ttl_seam_test.exs`** — ExUnit (new, write first, RED)
   - Given: `NEBU_MATRIX_SESSION_TTL_SECONDS` unset → Then: ceiling == `now + 8h` (AC7).
   - Given: `NEBU_MATRIX_SESSION_TTL_SECONDS=30` → Then: ceiling == `now + 30s` (AC1).
   - Given: junk value (`"abc"`, `"0"`, `"-5"`) → Then: falls back to 8h, no crash (AC1).
   - **Refresh re-mint path:** assert the `/v3/refresh` re-minted expiry also honors the
     configured TTL (the line ~429 use), not just the login path — guards the MAJOR finding.
   - Same set for the admin `session_expiry/1` path with `NEBU_ADMIN_SESSION_TTL_SECONDS`.

2. **`matrix-session-refresh.feature`** — Playwright+Cucumber (element-web project), un-pend
   `@ac8-*`. Steps: `e2e/step-definitions/element/auth/matrix-session-refresh.steps.ts` (AC2/AC8).
   - Given alex logs in via Dex SSO; When the configured TTL elapses and alex sends a message;
     Then it is delivered with no Dex re-redirect and the room list stays visible.
   - Then Element stored an opaque (non-JWT) access token + a refresh token.
   - Soft-logout: When the session is expired server-side and alex acts; Then a soft-logout
     state is shown (context preserved), not a hard kick.

3. **`admin-session-refresh.feature`** — Playwright+Cucumber (admin-ui project), remove
   `@pending-feature`. Steps: `e2e/step-definitions/admin/admin-session-refresh.steps.ts` (AC3/AC4).
   - Given the operator is logged in (real PKCE); When the lifetime elapses and they navigate;
     Then still authenticated, not redirected to `/admin/login`. Repeat across several lifetimes.

4. **`oidc-refresh-mode.feature`** — Playwright+Cucumber (admin-ui project), remove
   `@pending-feature`. Steps: `e2e/step-definitions/admin/oidc-refresh-mode.steps.ts` (AC4/AC5/AC6).
   - Bootstrap selectors + preselect + Dex-caveat hint; `/admin/config` runtime change persists.

## Dev Notes

**Server-side enabler (AC1) — the ONLY production-code change:**
- `server/lib/nebu/matrix/http_public.ex` — `session_expires_at/1` (~line 370) uses
  `@max_session_seconds = 8 * 3600`. Replace the constant use with a runtime read, e.g.
  `Application.get_env(:nebu, :matrix_session_ttl_seconds, 8 * 3600)`; keep the existing
  `min(oidc_exp, ceiling)` logic exactly. `expires_in_ms/1` (~383) is derived from this, so it
  follows automatically.
- `server/lib/nebu/admin/auth.ex` — `session_expiry/1` (~242) uses `@session_ttl_seconds = 8h`.
  Same treatment with `:admin_session_ttl_seconds`.
- `server/config/runtime.exs` — parse the two env vars with a safe integer parser
  (`Integer.parse/1`, reject ≤0) and set the `:nebu` app env keys; default 8h. Mirror the
  existing `NEBU_ADMIN_SESSION_SECURE` / `NEBU_OIDC_JWKS_TTL` pattern already in this file.
- **Do not** change any default. AC7 guards this.

**e2e stack wiring:**
- `docker-compose.yml` server service env: add `NEBU_MATRIX_SESSION_TTL_SECONDS` /
  `NEBU_ADMIN_SESSION_TTL_SECONDS`. Prefer a dedicated e2e override (e.g. a
  `docker-compose.e2e.yml` overlay or values in the compose used by `make test-e2e`) so dev
  `make dev` keeps the 8h default. Confirm how `make test-e2e` / `make dev` select compose
  files before adding (the Makefile `test-e2e*` targets assume the stack is already up — see
  `Makefile:233`). Pick a TTL around **25–30s**: long enough for matrix-js-sdk to settle after
  login, short enough to keep the suite fast.
- After any server change: `make redeploy` (rebuilds the image the compose uses) before running
  e2e — a stale image silently serves the old 8h ceiling (known gotcha, see project memory).

**e2e infra map (reuse — do NOT redefine duplicate step text, Cucumber errors):**
- Fixtures: `e2e/fixtures/nebu-fixtures.ts` exports `{ Given, When, Then, test }` (playwright-bdd,
  `importTestFrom: fixtures/nebu-fixtures.ts`). Users: `e2e/fixtures/users.ts` (`NEBU_USERS`,
  `DEX_TEST_PASSWORD = 'changeme'`).
- Element login: `e2e/fixtures/dex-auth.ts` `loginViaOidcBrowser(page, user, email, password)`
  (real Auth Code + PKCE, writes a token sidecar `auth-state/{user}.token.json`);
  `getApiSession(request, user, browser?)` reads/validates the opaque token (handles 401
  `M_UNKNOWN_TOKEN` = expired). `e2e/fixtures/element-app.ts` `ElementAppPage`
  (`waitForRoomList`, `viewRoomByName`, `getComposerField`, …).
- Working reference steps to copy patterns from (already green):
  `e2e/step-definitions/element/login.steps.ts` (Element SSO) and
  `e2e/step-definitions/admin/admin-oidc-login.steps.ts` (admin PKCE via `authenticateAtDex`,
  asserts `/admin/(rooms|users|dashboard)`, LiveView root `[data-phx-main]`, cookie
  `_nebu_admin_key`).
- playwright projects (`e2e/playwright.config.ts`): `element-web`
  (`features/element/**`, baseURL `:7070`, 300s timeout), `admin-ui` (`features/admin/**`,
  baseURL `:8008`, 90s). Both filter `tags: 'not @pending-feature'`, `workers: 1`, serial.
- Makefile: `make test-e2e-element` and `make test-e2e-admin` run the projects individually.
  **Scope the ci-gate to the three refresh suites** (run by feature path or a dedicated tag),
  NOT the whole suite — the broader Playwright suite is pre-existing red from fixture
  brittleness (a separate test-rehab workstream; project memory `project_e2e_suite_health`).

**Matrix refresh specifics / risks:**
- Element only requests refresh tokens when it sends `refresh_token: true` on `/login`; the
  Elixir opaque-token branch keys on exactly that. Verify the Element Web build in the e2e
  stack actually sends it (recent matrix-js-sdk does). If it does not, that is a real finding
  for the `@ac8-refresh-token-issued` scenario — surface it, don't paper over it.
- Opaque token shape: `:crypto.strong_rand_bytes(32) |> Base.encode16(:lower)` → 64 hex, no
  `.` — that is the "opaque, not a JWT" assertion.
- Soft-logout: an expired/revoked opaque AT → 401 `M_UNKNOWN_TOKEN` with `soft_logout: true`;
  Element shows the soft-logout UI. **Trigger deterministically by REVOKING the real session**
  (the one minted by alex's real PKCE login) — `MatrixSessionStore.revoke/1` via an admin/API
  call, NOT a wait. A wait races silent refresh (js-sdk may refresh before you observe
  soft-logout) and spends a second long wait. This is acting on a real login's session, not a
  seeding shortcut. Decide the concrete locators for "soft-logout state" (Element shows a
  `mx_SoftLogout`/"You're signed out" view with a re-sign-in button) and "context preserved"
  before calling it green — no hidden assertions.

**Refresh-mode suite specifics:**
- Selectors already exist: `ConfigLive` form `id="oidc-refresh-mode-form"`,
  `phx-change="save_refresh_mode"`, native `<select name="matrix_oidc_refresh_mode">` /
  `name="admin_oidc_refresh_mode"` with `aria-label`. Bootstrap wizard has the same in
  `BootstrapLive`. The Dex-caveat hint text contains "Dex issues a refresh token only when
  offline_access". Assert on these. Persisted value is read back via `server_config`.
- Bootstrap "fresh, un-bootstrapped instance": the suite runs serial after global-setup which
  bootstraps. Implement the bootstrap-wizard scenario against the pre-completion wizard route,
  or guard it so it does not depend on tearing down an already-bootstrapped instance — decide
  in dev based on `admin/bootstrap.steps.ts` helpers. If a true fresh instance is infeasible in
  the shared-stack run, narrow that scenario to assert the selectors render on the wizard step
  reachable without re-bootstrapping, and log the limitation (no silent skip).

**Wait must read the SAME knob wired into the stack (test-review MINOR):** the existing
`admin-session-refresh.steps.ts:36` constant `NEBU_ADMIN_ACCESS_TOKEN_LIFETIME ?? '60'` is the
wrong variable — reconcile the test wait to derive from `NEBU_ADMIN_SESSION_TTL_SECONDS` (the
admin Nebu-session TTL actually wired into the e2e stack), not a decoupled 60s default. Same
for the Matrix suite: wait is derived from `NEBU_MATRIX_SESSION_TTL_SECONDS`. One knob per
suite, no magic constants.

**Bootstrap-wizard scenario wording (test-review MINOR):** the feature `Given a fresh,
un-bootstrapped Nebu instance` cannot get a truly fresh instance in the shared serial stack
(global-setup already bootstraps). Soften the `Given` (or add a feature comment) to match the
mitigation — assert the wizard's OIDC step is reachable and renders the selectors — and confirm
`admin/bootstrap.steps.ts` exposes a reach-the-wizard-step helper before relying on it. Guard +
log the limitation; never silently skip.

**Standards:** Auth Code + PKCE only (no ROPC); no cookie forging; no DB seeding; reuse helpers.

## Completion notes (2026-06-23)

- **AC1/AC7 (TTL seam):** `Nebu.Web.SessionConfig` + `runtime.exs` wiring; both `http_public.ex`
  login and `/v3/refresh` re-mint + `admin/auth.ex` route through it. Unit: `session_config_test.exs`
  (13 cases) green in `make test-unit-elixir` (790/0). Integration: `login_refresh_test.exs` asserts
  `expires_in_ms` shrinks under a short TTL on login + refresh (runs in the integration gate).
- **AC3 (admin refresh):** ✅ validated LIVE via `make test-e2e-refresh` — admin session survived past
  a 30s lifetime across one and several lifetimes (silent refresh in `fetch_current_user/2`).
- **AC4/AC5 (refresh-mode):** ✅ runtime-change-persists scenario passed LIVE (also proved the
  migration `000007` RLS fix — a latent Story-3 bug where the runtime change was blocked after
  bootstrap). Bootstrap-wizard scenario self-skips on an already-bootstrapped stack (unit-covered).
- **AC2 (Matrix browser) — DEFERRED, blocked on the Matrix client, not Nebu.** Verified 2026-06-23:
  Element Web v1.12.15 does NOT send `refresh_token:true` in the SSO loginToken flow, so it uses the
  OIDC JWT directly (live client token is a JWT; zero opaque sessions minted). The Nebu opaque-token +
  `/v3/refresh` server path is covered end-to-end by `login_refresh_test.exs`. The 3 Matrix browser
  scenarios are `@pending-feature` with the reason documented in the feature header + ready step
  definitions; un-pend when the bundled client opts into refresh tokens. This is an important product
  finding: Element-via-SSO-loginToken does not currently benefit from the Matrix refresh fix.
- **Gates:** test-review (1 MAJOR + 3 MINOR fixed pre-dev) · code-review CLEAN · Kassandra CLEAN
  (enum-as-selector; defaults unchanged; operator-only seam).

## Tasks

1. (AC1/AC7) Write `session_ttl_seam_test.exs` (RED) → make `session_expires_at/1` +
   `session_expiry/1` read the configurable TTL; wire `runtime.exs` env parsing; default 8h.
2. (AC2) Implement `matrix-session-refresh.steps.ts` against real Element flow; un-pend.
3. (AC3) Implement `admin-session-refresh.steps.ts` against real admin PKCE flow; un-pend.
4. (AC4) Implement `oidc-refresh-mode.steps.ts` (bootstrap + `/admin/config`); un-pend.
5. (AC1) Wire short TTL into the e2e compose; `make redeploy`.
6. (AC5) Run scoped e2e (the three suites) to green; update the traceability matrix.
