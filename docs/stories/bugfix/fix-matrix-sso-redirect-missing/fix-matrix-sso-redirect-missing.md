---
story_id: bugfix-fix-matrix-sso-redirect-missing
title: "Bug: Matrix client SSO login broken — /login/sso/redirect returns 404 (go-removal regression, sso.go never ported)"
type: bug
severity: critical
epic: fix-matrix-sso-redirect-missing
status: done
security_review: required
created: 2026-06-18
branch: bugfix/fix-matrix-sso-redirect-missing
---

## Summary

Real Matrix clients (Element Web, FluffyChat, …) **cannot complete SSO login**.
`GET /_matrix/client/v3/login` advertises the `m.login.sso` flow, but the endpoint
that actually initiates SSO — `GET /_matrix/client/v3/login/sso/redirect` — and its
callback are **not implemented** and return **404**:

```
GET /_matrix/client/v3/login/sso/redirect?redirectUrl=...        -> 404
GET /_matrix/client/v3/login/sso/redirect/oidc?redirectUrl=...   -> 404
```

A client offered `m.login.sso` navigates the browser to `/login/sso/redirect`,
receives a 404, and the login flow dead-ends. The Matrix OIDC discovery endpoints
(`auth_issuer`, `auth_metadata`) and the `POST /_matrix/client/v3/login`
(`m.login.token`) handler all exist — only the **SSO redirect + callback** leg is
missing, so there is no way to obtain a login token via the browser.

Found while running the `element-web` Playwright BDD suite against a freshly reset
stack: **all 16 element scenarios failed**. The Playwright global-setup user
warm-up clicks Element's "Continue with SSO" button and then times out
(`page.waitForURL(/dex.*\/auth/, 45s)`) because the browser is sent to
`/login/sso/redirect` (404) and never reaches the Dex auth page.

## Root Cause Analysis

**Go-removal regression.** Commit `c1231ac6` ("go-removal-cleanup: remove Go stack;
migrate **admin** OIDC login to Elixir") deleted the Go Matrix-SSO implementation:

```
gateway/internal/matrix/sso.go             (-525)   ← GetSSORedirect + GetSSOCallback
gateway/internal/matrix/login.go           (-426)
gateway/internal/matrix/login_token_test.go (-176)  ← opaque single-use loginToken mint
```

…but **only the admin OIDC login** (`/admin/login/start` + `/admin/callback`) was
re-implemented in Elixir (`Nebu.Admin.Auth`). The **Matrix client SSO** flow that
`sso.go` provided was removed and never ported. The current
`Nebu.Matrix.HttpPublic` (`core/lib/nebu/matrix/http_public.ex`) only handles:
- `GET "/"` → `login_flows` / `auth_issuer` / `auth_metadata`
- `POST "/"` → `do_login` (validates an `m.login.token` JWT against JWKS)

There is no route for path_info `["sso", "redirect"]` / `["sso","redirect","oidc"]`,
so the forward `"/_matrix/client/v3/login"` → `HttpPublic` falls through to 404.

### What the removed Go handler did (implementation blueprint — `sso.go`)

- `GET /_matrix/client/v3/login/sso/redirect[?redirectUrl=<url>]` and
  `.../sso/redirect/{idpId}` (`GetSSORedirect`): validate `redirectUrl` against an
  **allowlist** (open-redirect protection — `isRedirectURLAllowed`, rejects
  `javascript:`/`data:` and off-host schemes), generate CSRF `state` + OIDC `nonce`
  + PKCE verifier, persist them with a TTL, 302 the browser to the IdP authorize
  endpoint with the SSO scope list (`buildSSOScopeList`, incl.
  `NEBU_OIDC_EXTRA_SCOPES`).
- `GET /_matrix/client/v3/login/sso/redirect/oidc` (`GetSSOCallback`): constant-time
  `state` check (fail-closed), exchange the code, verify the id_token, mint a
  **short-lived (30s) single-use opaque `loginToken`** mapped to the id_token, then
  302 the browser back to the original `redirectUrl` with `?loginToken=<opaque>`.
- The client then calls `POST /_matrix/client/v3/login` with
  `{"type":"m.login.token","token":"<opaque>"}`.

> NOTE for Dev/Architect: the current Elixir `POST /login` expects the
> `m.login.token` value to be a **JWT id_token verifiable via JWKS**, whereas the Go
> flow minted an **opaque single-use token** that `POST /login` resolved back to the
> id_token. Reconcile these: either (a) port the opaque-token store and teach
> `do_login` to resolve it, or (b) keep advertising `m.login.sso` and have the
> callback redirect with a token `do_login` already accepts. Pick one and make the
> advertised flow actually work end-to-end. Reuse the credential/issuer source used
> by admin OIDC (`bfd4884f`: SSO reads OIDC client credentials from the Bootstrap DB;
> falls back to `NEBU_OIDC_*` env). Honor `NEBU_OIDC_EXTRA_SCOPES` (`53904df6`).

## Acceptance Criteria

**AC1 — SSO redirect initiates the IdP flow:**
`GET /_matrix/client/v3/login/sso/redirect?redirectUrl=<allowed>` returns `302` to
the configured OIDC issuer's authorization endpoint, carrying `state`, `nonce`, and
(if used) PKCE `code_challenge`. Same for `.../sso/redirect/{idpId}`.

**AC2 — open-redirect protection (security):**
A `redirectUrl` that is not on the allowlist, or uses a dangerous scheme
(`javascript:`, `data:`, `vbscript:`, off-host), is rejected (400, no redirect).

**AC3 — callback mints a usable login token and returns to the client:**
`GET /_matrix/client/v3/login/sso/redirect/oidc?code=...&state=...` with a valid
state and successful code exchange 302s the browser back to the original
`redirectUrl` with a token the `m.login.token` flow accepts. A mismatched/expired
`state` is rejected (fail-closed, constant-time compare — no CSRF bypass).

**AC4 — end-to-end POST /login completes:**
`POST /_matrix/client/v3/login` with `{"type":"m.login.token","token":"<from AC3>"}`
returns `200` with `access_token`, `user_id`, `device_id`. The token is single-use
(a second redemption fails).

**AC5 — E2E: Element Web logs in via SSO:**
On a freshly reset stack with the element sidecar, a user completes SSO login through
Element Web and reaches the room list. (`e2e/features/element/login.feature` passes;
the Playwright global-setup user warm-up succeeds for alex/marie/kai.)

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **GET /login/sso/redirect → 302 to IdP** — ExUnit `:integration` (Plug.Test / httpc)
   - Given: OIDC configured; `redirectUrl` is on the allowlist
   - When: `GET /_matrix/client/v3/login/sso/redirect?redirectUrl=http://localhost:7070`
   - Then: 302 `Location` is the issuer authorize endpoint with `state` + `nonce`; state persisted

2. **open-redirect rejected** — ExUnit (Plug.Test)
   - Given: `redirectUrl=javascript:alert(1)` (and an off-host https URL)
   - When: `GET .../sso/redirect`
   - Then: 400, no `Location` redirect to the attacker URL

3. **callback with bad state rejected (CSRF)** — ExUnit
   - Given: a callback request whose `state` does not match any stored entry
   - When: `GET .../sso/redirect/oidc?code=x&state=bogus`
   - Then: rejected (fail-closed), no token minted

4. **callback success → loginToken → POST /login → access_token** — ExUnit `:integration`
   - Given: a valid code-exchange (mock/stub the IdP token endpoint + JWKS)
   - When: callback runs, then `POST /login` with the returned token
   - Then: 200 with `access_token`/`user_id`/`device_id`; second redemption of the token fails (single-use)

5. **E2E — Element Web SSO login** — Playwright + Cucumber
   - File: `e2e/features/element/login.feature` (exists, currently failing)
   - Given: freshly reset stack + element sidecar
   - When: user clicks "Continue with SSO", authenticates at Dex, returns
   - Then: Element reaches the room list (left panel visible); token sidecar written

## Dev Notes

### Files likely changed

- `core/lib/nebu/matrix/http_public.ex` — add `get "/sso/redirect"`,
  `get "/sso/redirect/:idp_id"`, and the callback route (path_info
  `["sso","redirect","oidc"]`); wire to a new SSO module.
- `core/lib/nebu/matrix/` — new module for the SSO state store + login-token store
  (ETS, TTL, single-use — cluster-aware per ADR-020; prefer a shared/`pg`-backed or
  DB-backed store over a node-local map so it works across nodes).
- `core/lib/nebu/web/router.ex` — confirm `forward "/_matrix/client/v3/login"`
  already routes the `sso/redirect*` sub-paths to `HttpPublic` (it should, as a
  subtree forward) and that these stay on the **unauthenticated** `HttpPublic`
  pipeline (no `OidcPlug`).
- `core/test/nebu/matrix/…_sso_*_test.exs` — new ExUnit tests (1–4).

### Reuse / parity references

- Removed Go blueprint: `git show c1231ac6^:gateway/internal/matrix/sso.go`
  (GetSSORedirect ~L289, GetSSOCallback ~L368, `isRedirectURLAllowed` ~L229,
  `buildSSOScopeList` ~L158, callback URL ~L179).
- OIDC client credentials: read from Bootstrap DB with `NEBU_OIDC_*` env fallback
  (commit `bfd4884f`); extra scopes via `NEBU_OIDC_EXTRA_SCOPES` (`53904df6`).
- Admin OIDC port (`Nebu.Admin.Auth` login_start/callback) is the closest existing
  Elixir pattern for PKCE + state + nonce + code exchange — mirror it.

### Security review scope (security_review: required)

New unauthenticated, internet-facing endpoints handling OIDC: must enforce the
redirectUrl allowlist (open redirect), constant-time fail-closed state check (CSRF),
single-use + short-TTL login tokens (replay), and must not leak the id_token in URLs
beyond the opaque token. This is a security-critical surface.

## Discovery context

Found during a full `make dev-reset-db` + `make test-e2e-element` run on
2026-06-18 (branch `feature/full-elixir-stack`). All 16 element scenarios failed;
this is the root cause. A separate test-infra issue (stale `nebu-element` compose
image still proxying `/_matrix` to the removed `gateway` host) was fixed
out-of-band by rebuilding the image (`docker compose build --no-cache element`) and
is **not** part of this story. The admin-suite failures are a **separate** root
cause tracked in `bugfix/fix-bootstrap-wizard-unreachable`.

## Dev Agent Record

**Status:** review · **Agent:** combined ATDD+dev-story (Opus 4.8 1M)

### Design decision — Option A (opaque single-use loginToken)

Per the story reconcile note, **Option A** was chosen: the callback mints a
short-lived (30 s), single-use **opaque** loginToken (32-byte hex) mapped to the
verified `id_token`, and `do_login`'s `m.login.token` branch resolves the opaque
token back to the `id_token` before verification.

Why A over B (callback redirects with a token `do_login` already accepts, i.e. the
raw JWT in the URL):

- **Least surprise for Element** — Element's SSO flow expects an opaque
  `loginToken` in `?loginToken=`, exactly what the removed Go `sso.go` produced.
- **Security** — the raw `id_token` (≈1 h lifetime, full claims) would otherwise be
  exposed in browser history, `Referer` headers and proxy logs. The opaque token is
  random, single-use, and expires in 30 s, shrinking the replay window to nothing.
- **One verification path** — the opaque token is resolved to the stored `id_token`,
  which is then verified through the *same* `Nebu.Web.Plugs.OidcPlug.verify_token/2`
  used by the bearer plug and admin login. No second/divergent verifier. A direct
  JWT is still accepted (passed through unchanged when it is not a known opaque
  token), so non-SSO callers are unaffected.

### State / token store — cluster-aware, single-use, TTL (ADR-020)

`Nebu.Matrix.SsoStore` is a supervised GenServer (in `Nebu.Supervisor`, alongside
the other stateful children) that owns a private ETS table and **joins a `pg`
process group**. Every `put`/`pop` is broadcast to all group members, so each node
keeps a replica and the three hops of the flow (`/sso/redirect` → IdP callback →
`POST /login`) work even when they land on different cluster nodes behind the LB —
identical single-node and cluster behaviour, per ADR-020. It is NOT a node-local
map.

- **Single-use:** `pop_state` / `pop_login_token` delete locally and broadcast a
  delete tombstone, so a state/token consumed on node A cannot be redeemed again on
  node B. The second `POST /login` with the same loginToken therefore fails.
- **TTL:** SSO state 10 min (user-typing-at-IdP window), loginToken 30 s. Entries
  carry an absolute `exp`; a lookup treats an expired entry as absent (lazy delete)
  and a 60 s sweep evicts stale rows. A per-node cap (10 000 pending states, Go
  parity) bounds memory under an unauthenticated `/sso/redirect` flood → 429.
- **Volatile by design** (like `Nebu.Web.TokenDenylist`): a full-cluster restart
  drops pending flows; the user simply re-initiates — fine for a 10 min / 30 s
  window.

### Open-redirect + CSRF-state enforcement

- **Open redirect (AC2):** `SsoLogin.redirect_url_allowed?/1` enforces a scheme
  allowlist — `https` any host; `http` loopback only; the Element/FluffyChat
  deep-link schemes; operator-configured `NEBU_SSO_REDIRECT_SCHEMES`. A
  **denylist** (`javascript`, `data`, `file`, `vbscript`, `blob`) wins over the
  allowlist. A bare/relative URL (no scheme) is rejected. A rejected URL → 400 with
  no `Location`, and the scheme/URL is never echoed into the response (no reflected
  XSS / info leak).
- **CSRF state (AC3):** the `state` is a 128-bit random token persisted server-side
  at `/sso/redirect` and `pop`-ed single-use in the callback (fail-closed: an
  unknown/expired/forged state yields `:error` → 400, no code exchange, no token
  minted). The OIDC `nonce` is additionally checked with
  `Plug.Crypto.secure_compare/2` (constant-time) against the value bound at
  redirect time, rejecting a stale/cached `id_token`.

### Routes (unauthenticated — they ARE the login; no OidcPlug)

Added to `Nebu.Matrix.HttpPublic` (forwarded subtree, prefix stripped):
`get "/sso/redirect/oidc"` (callback — listed first so the literal segment beats the
wildcard), `get "/sso/redirect"`, `get "/sso/redirect/:_idp"`.

### File List

- `core/lib/nebu/matrix/sso_store.ex` — **new** cluster-aware (`pg`-replicated ETS),
  single-use, TTL state + loginToken store.
- `core/lib/nebu/matrix/sso_login.ex` — **new** SSO redirect + callback handler
  (allowlist, PKCE/state/nonce, code exchange, opaque loginToken mint).
- `core/lib/nebu/matrix/http_public.ex` — add the 3 `get "/sso/redirect*"` routes;
  teach `do_login` to resolve an opaque loginToken → id_token (single-use) before
  the shared `OidcPlug.verify_token` path.
- `core/lib/nebu/application.ex` — start `Nebu.Matrix.SsoStore` under
  `Nebu.Supervisor`.
- `core/config/runtime.exs` — `matrix_oidc_client_id`/`_secret` (Bootstrap-DB
  source with `NEBU_OIDC_*` env fallback), `oidc_extra_scopes`
  (`NEBU_OIDC_EXTRA_SCOPES`), `sso_redirect_schemes`.
- `core/test/nebu/matrix/matrix_sso_test.exs` — **new** tests 1–4 + store unit tests.

### Test results (RED → GREEN)

- RED: before implementation, all 11 tests failed (routes 404 / `SsoStore`
  undefined).
- GREEN: `mix test test/nebu/matrix/matrix_sso_test.exs --include integration` →
  **12 tests, 0 failures** (10 unit + the full callback→loginToken→POST /login
  integration test incl. single-use re-redemption).
- Full `mix test test/nebu/matrix/ --include integration --warnings-as-errors` — no
  regressions.
- AC5 (Element Web Playwright E2E) is verified later in the combined pipeline run.
