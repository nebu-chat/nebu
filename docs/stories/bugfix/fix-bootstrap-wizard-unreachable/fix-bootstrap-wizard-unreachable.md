---
story_id: bugfix-fix-bootstrap-wizard-unreachable
title: "Bug: Bootstrap Wizard unreachable on a fresh instance (deadlock — /admin/bootstrap redirects to /admin/login)"
type: bug
severity: critical
epic: fix-bootstrap-wizard-unreachable
status: done
security_review: required
created: 2026-06-18
branch: bugfix/fix-bootstrap-wizard-unreachable
---

## Summary

On a brand-new (un-bootstrapped) instance the Bootstrap Wizard is **unreachable**,
creating a chicken-and-egg deadlock that blocks the entire admin onboarding flow.

Observed after `make dev-reset-db` (fresh DB, no `bootstrap_completed` /
`oidc_issuer` / `admin_group_claim` in `server_config`):

```
GET /admin/           -> 302 /admin/dashboard -> 302 /admin/login
GET /admin/bootstrap  -> 302 /admin/login
```

The operator is funneled to `/admin/login`, but cannot authenticate as an admin
because the admin-group claim and OIDC config are only written **by completing the
Bootstrap Wizard** — which they can never reach. Deadlock.

This was found while running the `admin-ui` Playwright BDD suite against a freshly
reset stack: **30 of 37 admin scenarios failed**, almost all cascading from this
single root cause (every authenticated admin page — dashboard, rooms, users,
audit-log, claim-mapping, oidc-directory-config, auto-join, build-info-footer,
liveview — plus both `bootstrap.feature` scenarios). The Playwright global-setup
fixture `doBootstrapAdmin()` mis-detects the instance as "already bootstrapped"
precisely because `/admin/bootstrap` redirects to `/admin/login`.

## Story

As a Nebu instance operator,
I want to reach and complete the Bootstrap Wizard on a brand-new instance without
already being an authenticated admin,
so that I can configure OIDC + the admin-group claim and bring the instance online.

## Root Cause Analysis

`Nebu.Admin.Auth.on_mount(:require_admin, ...)` (`core/lib/nebu/admin/auth.ex`,
~line 452–480) gates **all** `live_session :admin` routes — and the router places
`live "/bootstrap", BootstrapLive` **inside** that gated `live_session :admin`
block (`core/lib/nebu/admin/router.ex:64–75`).

The hook has a "bootstrap funnel" (line ~464):

```elixir
if not socket.assigns.bootstrap_completed and socket.view != Nebu.Admin.BootstrapLive do
  {:halt, redirect(socket, to: "/admin/bootstrap")}
else
  {:cont, socket}
end
```

…but this branch only runs for an **already-authenticated admin**
(`%{"admin" => true}`). For an **unauthenticated** operator (the fresh-instance
case) the catch-all branch fires first:

```elixir
_ ->
  {:halt, redirect(socket, to: "/admin/login")}
```

So the wizard is never reachable before an admin session exists, and an admin
session can never be minted before the wizard configures the admin-group claim.
The comment on `LoginController.root_redirect/2` ("the LiveView on_mount bootstrap
gate redirects to /admin/bootstrap if the instance is not yet bootstrapped") is
therefore **false for unauthenticated users**.

## Acceptance Criteria

**AC1 — Unauthenticated operator reaches the wizard on a fresh instance:**
When `bootstrap_completed?` is `false` and an **unauthenticated** request mounts
`Nebu.Admin.BootstrapLive` (`/admin/bootstrap`), the mount proceeds
(`{:cont, _}`) and the wizard renders. No redirect to `/admin/login`.

**AC2 — Unauthenticated operator on any other admin page is funneled to the wizard
(not to login) while bootstrap is incomplete:**
When `bootstrap_completed?` is `false` and an unauthenticated request mounts any
other `live_session :admin` view (e.g. `DashboardLive`, `RoomsLive`), the hook
redirects to `/admin/bootstrap` (not `/admin/login`).

**AC3 — Once bootstrap is complete, the wizard is admin-gated again (no regression,
security):**
When `bootstrap_completed?` is `true` and an **unauthenticated** request mounts
`Nebu.Admin.BootstrapLive`, the hook redirects to `/admin/login` (the wizard must
NOT be world-accessible after setup is done — it can re-write OIDC/admin-claim
config).

**AC4 — Authenticated-admin behaviour unchanged:**
An authenticated admin still: reaches every admin page when bootstrap is complete;
and is funneled to `/admin/bootstrap` when it is not (existing funnel preserved).

**AC5 — End-to-end: fresh instance completes the wizard:**
On a freshly reset stack, an operator navigating to `/admin/` is taken to the
Bootstrap Wizard, completes OIDC login + claim selection, and lands on
`/admin/dashboard` authenticated. (`e2e/features/admin/bootstrap.feature`
scenario `Operator completes Bootstrap Wizard via real OIDC login` passes.)

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **on_mount allows unauthenticated mount of BootstrapLive when not bootstrapped** — ExUnit
   - Given: `bootstrap_completed?` is false; session has no `current_user`; `socket.view == Nebu.Admin.BootstrapLive`
   - When: `Nebu.Admin.Auth.on_mount(:require_admin, %{}, session, socket)` is called
   - Then: returns `{:cont, socket}` (wizard renders, no redirect)

2. **on_mount funnels unauthenticated non-bootstrap view to /admin/bootstrap when not bootstrapped** — ExUnit
   - Given: `bootstrap_completed?` is false; no `current_user`; `socket.view == Nebu.Admin.DashboardLive`
   - When: `on_mount(:require_admin, ...)` is called
   - Then: returns `{:halt, redirect(to: "/admin/bootstrap")}`

3. **on_mount blocks unauthenticated BootstrapLive once bootstrap is complete (security)** — ExUnit
   - Given: `bootstrap_completed?` is true; no `current_user`; `socket.view == Nebu.Admin.BootstrapLive`
   - When: `on_mount(:require_admin, ...)` is called
   - Then: returns `{:halt, redirect(to: "/admin/login")}`

4. **on_mount: authenticated admin unchanged** — ExUnit
   - Given: session `current_user` is `%{"admin" => true}`, live session
   - When: `on_mount(:require_admin, ...)` with bootstrap complete vs incomplete
   - Then: complete → `{:cont, _}` for any view; incomplete → `{:halt, redirect("/admin/bootstrap")}` for non-bootstrap views, `{:cont, _}` for BootstrapLive

5. **E2E — Operator completes Bootstrap Wizard via real OIDC login** — Playwright + Cucumber
   - File: `e2e/features/admin/bootstrap.feature` (already exists, currently failing)
   - Given: a freshly reset stack with no bootstrap completed
   - When: operator navigates to `/admin/`, fills the wizard, logs in via Dex, selects the admin claim
   - Then: lands on `/admin/dashboard`, authenticated

## Dev Notes

### Likely fix shape (Dev to confirm against current code)

In `Nebu.Admin.Auth.on_mount(:require_admin, _params, session, socket)`
(`core/lib/nebu/admin/auth.ex`), handle the not-bootstrapped case **before** the
authenticated check, or restructure the catch-all so that when
`bootstrap_completed?()` is false:
- `socket.view == Nebu.Admin.BootstrapLive` → `{:cont, assign(socket, bootstrap_completed: false, current_user: nil)}`
- otherwise → `{:halt, redirect(to: "/admin/bootstrap")}`

Only fall through to the `{:halt, redirect("/admin/login")}` behaviour when
`bootstrap_completed?()` is true (AC3 — wizard re-gated post-setup).

Keep `let-it-crash`; do not wrap DB lookups in `try/rescue`. Reuse the existing
`bootstrap_completed?/0`.

### Files likely changed

- `core/lib/nebu/admin/auth.ex` — `on_mount(:require_admin, ...)` branch logic
- (verify) `core/lib/nebu/admin/login_controller.ex` — `root_redirect/2` may also
  need to send fresh instances to `/admin/bootstrap` instead of `/admin/dashboard`
  so the HTTP-level redirect chain matches AC5 (Dev to confirm).
- `core/test/nebu/admin/auth_*_test.exs` — new ExUnit on_mount tests (1–4)

### Security review scope (security_review: required)

This story changes an **auth gate**. The reviewer must confirm AC3: the Bootstrap
Wizard (which writes OIDC config + the admin-group claim) is reachable
**only** while `bootstrap_completed = false`, and becomes admin-gated again the
instant setup completes — no unauthenticated re-configuration path remains open.

## Discovery context

Found during a full `make dev-reset-db` + `make test-e2e-admin` run on
2026-06-18 (branch `feature/full-elixir-stack`). 30/37 admin scenarios failed;
this is the root cause for the admin/bootstrap cascade. A separate test-infra
issue (stale `nebu-element` compose image proxying `/_matrix` to the removed
`gateway` host) was fixed out-of-band by rebuilding the image and is **not** part
of this story.

## Dev Agent Record

### Completion Notes

- **Root cause fixed** in `Nebu.Admin.Auth.on_mount(:require_admin, ...)`: the
  unauthenticated (`_ ->`) branch previously redirected *every* mount to
  `/admin/login` regardless of bootstrap state, dead-locking fresh instances.
  It now branches on `bootstrap_completed?()`:
  - incomplete + `BootstrapLive` → `{:cont, assign(current_user: nil, bootstrap_completed: false)}` (AC1)
  - incomplete + any other view → `{:halt, redirect(to: "/admin/bootstrap")}` (AC2)
  - complete → `{:halt, redirect(to: "/admin/login")}` for all unauthenticated mounts (AC3, security re-gate)
- **MINOR-1 (test-review precondition) resolved:** `Auth.bootstrap_completed?/0` now
  consults the same injectable `:admin_bootstrap_store` seam that
  `Nebu.Admin.BootstrapLive` uses (`{:bootstrap_completed?, []}` → `{:ok, bool}`),
  falling back to the real inline SQL read (production default) when no seam is
  installed, and to `true` when neither seam nor `Nebu.Repo` is available. This makes
  AC1/AC2 deterministically reachable in the unit suite (Repo not started). The
  authenticated branch was refactored to reuse the single `completed` value (no
  double DB read), preserving AC4 funnel + expired-session behaviour exactly.
- **`LoginController.root_redirect/2` left unchanged** (INFO-3): on a fresh instance
  the chain `/admin/` → `/admin/dashboard` → (fixed on_mount funnels) → `/admin/bootstrap`
  already produces the correct AC5 end state. Keeping the change minimal and focused
  on the auth gate per the story constraints; no behaviour regression.
- ADR-018 (inline SQL, no schemas) and let-it-crash (no defensive `try/rescue`,
  `running?(Nebu.Repo)` guard retained) honoured.

### Test Results

`mix test test/nebu/admin/auth_bootstrap_gate_test.exs` → **8 passed** (3 previously RED now GREEN).
Full admin suite `mix test test/nebu/admin/` → **24 passed**, no regressions.

### File List

- `core/lib/nebu/admin/auth.ex` — restructured `on_mount(:require_admin, ...)`
  unauthenticated branch (AC1/AC2/AC3); wired `bootstrap_completed?/0` to the
  `:admin_bootstrap_store` seam via new private `bootstrap_store/2`.
- `core/test/nebu/admin/auth_bootstrap_gate_test.exs` — ATDD tests (pre-existing,
  authored in the atdd step; now GREEN).

### Change Log

- 2026-06-18: Fixed bootstrap-wizard-unreachable deadlock in the LiveView admin
  auth gate; wired `bootstrap_completed?/0` to the shared bootstrap-store seam.

## Status

review
