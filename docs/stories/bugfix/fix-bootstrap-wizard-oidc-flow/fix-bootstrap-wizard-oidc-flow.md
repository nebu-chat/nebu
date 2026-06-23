---
story_id: bugfix-fix-bootstrap-wizard-oidc-flow
title: "Bug: Bootstrap Wizard diverges from Go-parity spec — no Connect-with-OIDC / claim-discovery step"
type: bug
severity: high
epic: fix-bootstrap-wizard-oidc-flow
status: done
security_review: required
created: 2026-06-19
branch: bugfix/fix-bootstrap-wizard-oidc-flow
---

## Summary

The Elixir Bootstrap Wizard (`Nebu.Admin.BootstrapLive`) does NOT implement the
interactive OIDC-login + claim-discovery flow that the acceptance criteria
(`e2e/features/admin/bootstrap.feature` scenario `Operator completes Bootstrap
Wizard via real OIDC login`) and the Go-parity reference require. It instead
collects OIDC config in form fields and a **"Finish"** button writes
`admin_group_claim` **hardcoded to `"instance_admin"`** without the operator ever
authenticating or choosing a claim.

Because the global E2E fixture `e2e/fixtures/admin-bootstrap.ts` (`doBootstrapAdmin`)
drives the spec flow — Step 2 labels "OIDC Issuer URL / OIDC Client ID / OIDC
Client Secret", a **"Connect with OIDC"** button on step 3, a Dex login, then a
`/admin/bootstrap/select-claim` page — and it is run by `global-setup.ts` to
prepare EVERY admin E2E test, the mismatch makes `doBootstrapAdmin` time out and
**blocks the entire admin-ui E2E suite**.

> Depends on `bugfix/fix-bootstrap-wizard-unreachable` (already merged): the wizard
> is now reachable unauthenticated on a fresh instance. This story makes the wizard
> actually complete via OIDC, per spec.

## Story

As a Nebu instance operator,
I want the Bootstrap Wizard to let me authenticate via OIDC and pick the admin-group
claim from my real token claims,
so that bootstrap matches the documented (Go-parity) flow and any IdP's claim naming
works — not just a hardcoded `instance_admin`.

## Current vs. expected flow

| Step | Expected (spec / `bootstrap.feature` / Go parity) | Current Elixir (`bootstrap_live.ex`) |
|---|---|---|
| Heading | page shows **"Bootstrap Setup"** | "Bootstrap Wizard" |
| Progress | progress indicator shows step N as active | plain "Step N of 4" text, no active-step indicator |
| Step 1 | "Instance Name" → Next | "Instance name" → Next (works) |
| Step 2 | "OIDC Issuer URL", "OIDC Client ID", "OIDC Client Secret" → Next | "OIDC issuer", "Client ID", "Client secret" |
| Step 3 | claim mapping defaults, then **"Connect with OIDC"** → `/admin/login/start?mode=bootstrap` → Dex | claim-mapping fields → "Next" → step 4 |
| After Dex login | redirect to **`/admin/bootstrap/select-claim`**, shows **discovered OIDC claims** as selectable options | (none — step 4 "Finish" writes config + hardcoded `admin_group_claim=instance_admin`, no login) |
| Finish | operator selects a claim value, clicks **"Confirm"** → writes `admin_group_claim` + `bootstrap_completed` + mints admin session → `/admin/dashboard` authenticated | n/a |

## Go-parity reference (removed in `c1231ac6`, mirror the logic)

- `gateway/internal/admin/bootstrap.go` `StepHandler` case 3: saves claim-mapping to
  draft, then `http.Redirect(w, r, "/admin/login/start?mode=bootstrap", 303)`
  (line ~324). Read it: `git show c1231ac6^:gateway/internal/admin/bootstrap.go`.
- The admin OIDC login (`Nebu.Admin.Auth.login_start/2` + `callback/2`,
  `core/lib/nebu/admin/auth.ex` ~160-230) already does PKCE + state + nonce + code
  exchange + ID-token verify. The **bootstrap mode** must reuse this but:
  - `login_start` must accept `mode=bootstrap` and read OIDC client creds from the
    **bootstrap_draft** (not yet promoted to `server_config`).
  - `callback` in bootstrap mode must SKIP `check_admin/1` (no admin exists yet) and
    instead render the claim-selection page from the verified token's claims.

## Acceptance Criteria

**AC1 — Step labels + heading + progress match spec:**
The wizard shows heading "Bootstrap Setup", a progress indicator marking the active
step, Step 1 label "Instance Name", and Step 2 labels "OIDC Issuer URL",
"OIDC Client ID", "OIDC Client Secret". (`getByLabel`/`getByText` in the fixture/feature resolve.)

**AC2 — Connect with OIDC initiates real login:**
On step 3 a "Connect with OIDC" control persists the OIDC config (+ claim mapping)
to the draft and redirects to `/admin/login/start?mode=bootstrap`, which 302s to the
Dex authorize endpoint (PKCE + state + nonce), using the client credentials from the
bootstrap draft.

**AC3 — Callback (bootstrap mode) shows discovered claims, no admin gate:**
After Dex login, the callback in `mode=bootstrap` verifies the ID token but does NOT
enforce the admin-group claim (no admin exists yet). It renders
`/admin/bootstrap/select-claim` listing the discovered claim values as selectable
options.

**AC4 — Confirm writes config + completes bootstrap + mints session:**
Selecting a claim value and clicking "Confirm" writes `admin_group_claim` (the chosen
value), promotes the draft OIDC config to `server_config`, sets
`bootstrap_completed=true`, mints the admin session, and redirects to
`/admin/dashboard` authenticated.

**AC5 — Security: bootstrap-mode login works ONLY while bootstrap incomplete:**
`/admin/login/start?mode=bootstrap` and the select-claim/confirm path are inert once
`bootstrap_completed=true` (they must not let an unauthenticated party re-pick the
admin claim or overwrite OIDC config after setup). The confirm action re-checks
`bootstrap_completed?` and refuses if already complete.

**AC6 — End-to-end (the spec scenario passes):**
`e2e/features/admin/bootstrap.feature` scenario `Operator completes Bootstrap Wizard
via real OIDC login` passes against a freshly reset stack, and `doBootstrapAdmin`
(global-setup) completes without timing out.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **login_start mode=bootstrap reads draft creds → 302 to IdP** — ExUnit `:integration`
   - Given: bootstrap_draft has oidc_issuer/client_id/client_secret; bootstrap incomplete
   - When: `GET /admin/login/start?mode=bootstrap`
   - Then: 302 to the issuer authorize endpoint with state+nonce+PKCE

2. **callback mode=bootstrap does NOT enforce admin claim, renders select-claim** — ExUnit `:integration`
   - Given: a valid code exchange whose token has claims WITHOUT the admin group claim (stub OidcPlug.verify_token)
   - When: callback runs in bootstrap mode
   - Then: no 403; renders the select-claim page listing the token's claim values

3. **confirm writes admin_group_claim + bootstrap_completed + mints session** — ExUnit `:integration`
   - Given: select-claim page, operator selects "instance_admin"
   - When: Confirm
   - Then: server_config.admin_group_claim == "instance_admin", bootstrap_completed=="true", oidc_* promoted from draft, admin session present, redirect /admin/dashboard

4. **confirm is inert once bootstrap complete (security AC5)** — ExUnit
   - Given: bootstrap_completed=="true"
   - When: POST confirm / GET login/start?mode=bootstrap
   - Then: refused (redirect /admin/login or 409), no config overwrite

5. **wizard renders spec labels/heading/progress** — ExUnit (LiveView render) or covered by E2E
   - Given: fresh instance, mount BootstrapLive
   - Then: heading "Bootstrap Setup"; step 2 labels "OIDC Issuer URL"/"OIDC Client ID"/"OIDC Client Secret"; progress indicator marks active step

6. **E2E — Operator completes Bootstrap Wizard via real OIDC login** — Playwright + Cucumber
   - File: `e2e/features/admin/bootstrap.feature` (exists). Must pass end-to-end; `doBootstrapAdmin` completes in global-setup.

## Dev Notes

### Files likely changed
- `core/lib/nebu/admin/bootstrap_live.ex` — heading "Bootstrap Setup", progress
  indicator, step-2 labels, replace step-3 "Next"/step-4 "Finish" with a
  "Connect with OIDC" action that saves the draft and redirects (LiveView
  `push_navigate`/redirect to `/admin/login/start?mode=bootstrap`).
- `core/lib/nebu/admin/auth.ex` — `login_start/2` accepts `mode=bootstrap` (read creds
  from draft); `callback/2` branches on bootstrap mode (skip `check_admin`, render
  select-claim). Keep PKCE/state/nonce verification intact.
- `core/lib/nebu/admin/login_controller.ex` (or a new controller/LiveView) — routes
  `GET /admin/bootstrap/select-claim` (render discovered claims) and the Confirm POST.
- `core/lib/nebu/admin/router.ex` — add the select-claim + confirm routes
  (these must be reachable WITHOUT an admin session while bootstrap is incomplete —
  mirror the gate fix from `fix-bootstrap-wizard-unreachable`).
- Tests under `core/test/nebu/admin/`.

### Constraints
- ADR-018 inline SQL (promote draft → server_config in a single tx as the Go
  `saveBootstrapConfigTx` did), let-it-crash, ADR-020.
- Reuse the existing PKCE/state/nonce machinery; do NOT fork a second insecure OIDC path.
- Encrypt the client secret at rest exactly as the existing config path does.

### Security review scope (security_review: required)
New unauthenticated OIDC login path (`mode=bootstrap`) that bypasses the admin-group
gate. Reviewer MUST confirm: (a) it is reachable ONLY while `bootstrap_completed=false`
(AC5) and becomes inert immediately after; (b) PKCE/state/nonce replay protections are
NOT weakened by the bootstrap branch; (c) the chosen claim value cannot be injected to
grant unintended admin access; (d) the client secret is encrypted at rest; (e) no open
redirect via the bootstrap return path.

## Dev Agent Record

### Status
review (TDD dev complete; awaiting code-review + Kassandra security-review + E2E gate).

### Implementation summary (Go-parity OIDC bootstrap flow)

- **Wizard reworked to 3 steps** with the spec heading + a real progress indicator:
  Step 1 "Instance Name", Step 2 "OIDC Issuer URL"/"OIDC Client ID"/"OIDC Client Secret",
  Step 3 claim-mapping + **"Connect with OIDC"** (replaces the old step-4 "Finish" that
  hardcoded `admin_group_claim`). Connect persists the claim mapping then redirects to
  `/admin/login/start?mode=bootstrap` (no premature draft promotion / completion).
- **`login_start` mode=bootstrap** reads OIDC creds from the `bootstrap_draft` (decrypting
  the at-rest secret), binds `mode` into the signed login state, keeps PKCE/state/nonce.
  Refuses (→ /admin/login) once `bootstrap_completed`.
- **`callback` mode=bootstrap** verifies the token (same `OidcPlug.verify_token` path,
  no second insecure path), SKIPS the admin-group gate, stashes the authenticated
  sub/email in the draft, and renders the claim-selection page (HTML-escaped discovered
  claim values as radio options) inline at `/admin/callback`, POSTing to
  `/admin/bootstrap/select-claim`.
- **`bootstrap_confirm_claim`** writes the chosen `admin_group_claim`, promotes the draft
  OIDC config into `server_config` (encrypted secret carried forward unchanged), sets
  `bootstrap_completed=true`, clears the draft, mints the admin session, redirects to
  `/admin/dashboard` (mirrors Go saveBootstrapConfigTx + completeBootstrapTx).

### AC5 enforcement (inert-after-complete)
The whole mode=bootstrap leg re-checks `bootstrap_completed?()` at THREE points, all
failing closed to `/admin/login`: (1) `login_start` refuses before redirecting to the IdP;
(2) `bootstrap_callback` refuses before rendering claim selection; (3) `bootstrap_confirm_claim`
refuses before any config write or session mint. The select-claim/confirm routes sit OUTSIDE
the `live_session` admin gate (reachable unauthenticated WHILE incomplete) but the handlers
themselves gate on `bootstrap_completed?()` — same logic as the on_mount fix. `confirm` also
refuses if no authenticated `bootstrap_sub` is in the draft (no prior bootstrap callback).
The select-claim page is CSRF-protected (`_csrf_token` hidden field + `:protect_from_forgery`);
the encrypted client secret never reaches plaintext storage; discovered claim values are
HTML-escaped (IdP-influenced input).

### Security fix — C1 claim-value injection (Kassandra, 2026-06-19)
`bootstrap_confirm_claim/2` previously wrote the POSTed `admin_group_claim` verbatim into
`server_config.admin_group_claim` — the org-wide admin gate for every future login — without
validating it against the verified ID token. An operator (or anyone able to drive the confirm
POST while bootstrap is incomplete) could set the gate to ANY string, decoupling it from the
token they authenticated with (privilege-escalation / claim injection).

Fix (mirrors Go ClaimSelectionHandler — pick from the discovered list, never free-form):
- `bootstrap_callback/2` now ALSO stashes the verified token's discovered claim VALUES
  server-side via `put_draft("bootstrap_claims", encode_discovered_claims(claims))` —
  `encode_discovered_claims/1` reuses the existing `extract_discovered_claims/1`, so the stash
  is EXACTLY the set rendered on the select-claim page. (`auth.ex` ~line 306-322.)
- `bootstrap_confirm_claim/2` gains a new `cond` branch (after the AC5 `bootstrap_completed?()`
  re-check and the `bootstrap_sub`-present check, before any config write): reject when
  `not MapSet.member?(discovered_claim_values(draft), selected)` → redirect
  `/admin/login?error=auth_failed`, no `server_config` write, no `bootstrap_completed`, no
  session. `discovered_claim_values/1` decodes the stash and fails CLOSED (empty set) on a
  missing/malformed stash. (`auth.ex` ~line 343-356, helper ~line 322-340.)
- M1 (atomicity): `complete_bootstrap/2` now wraps the draft→server_config promotion in a
  single `Ecto.Adapters.SQL.transaction/2` when the real Repo is running (`seam_installed?/0`
  guard skips it on the unit-test seam path) — a mid-flight crash can no longer leave
  `bootstrap_completed = "true"` without a written `admin_group_claim`. (`auth.ex` ~line 836-862.)
- M2: corrected the misleading `select_claim_page/2` docstring (it claimed the
  `/admin/bootstrap` admin gate re-applies; in fact this route + `bootstrap_confirm_claim/2`
  each re-check `bootstrap_completed?()` directly). (`auth.ex` ~line 380-392.)

RED→GREEN proof: 3 new tests added RED-first against the unfixed handler:
`confirm REJECTS an admin_group_claim value not in the stashed discovered set (C1)`,
`confirm ACCEPTS an admin_group_claim value that IS in the stashed discovered set (C1)`,
`callback mode=bootstrap stashes the discovered claim values for confirm validation (C1)` —
the first two failed because confirm ignored the stash (would accept `"all"`), the third
because the callback never stashed the claims. After the fix: `mix test test/nebu/admin/
--warnings-as-errors` → **35 passed**, no regressions (the existing AC5 "confirm refused
when complete" test at :242 still passes — the completion gate fires before claim validation).

### File List
- `core/lib/nebu/admin/bootstrap_live.ex` — 3-step wizard; heading "Bootstrap Setup";
  progress indicator; spec labels; step-3 "Connect with OIDC" event; `encrypt_secret/1`
  made public; removed the old Finish/promote path (moved to Auth).
- `core/lib/nebu/admin/auth.ex` — `login_start/2` mode=bootstrap (draft creds);
  `callback/2` branch (`bootstrap_callback` / `normal_callback`); `bootstrap_confirm_claim/2`;
  `select_claim_page/2`; `select_claim_html/1` + `extract_discovered_claims/1`; inline-SQL
  draft read + config promotion (`:admin_bootstrap_store` seam); `:admin_oidc_token_override`
  test seam; `oidc_config/1` reads draft in bootstrap mode.
- `core/lib/nebu/admin/login_controller.ex` — `select_claim/2` + `confirm_claim/2` delegating to Auth.
- `core/lib/nebu/admin/router.ex` — `GET`/`POST /admin/bootstrap/select-claim` (ungated-while-incomplete).
- `core/test/nebu/admin/bootstrap_oidc_flow_test.exs` — NEW: tests 1-4 (login_start bootstrap
  302 + inert-when-complete; callback bootstrap render-no-gate + sub/email draft; confirm
  promote+complete+session; confirm refused-when-complete; normal-mode gate still enforced)
  + C1 claim-injection tests (confirm rejects value not in discovered set; confirm accepts
  in-set value; callback stashes discovered claim values) — 13 tests. Test 3 updated to seed
  `bootstrap_claims` (confirm now requires the value to be a discovered claim).
- `core/test/nebu/admin/admin_bootstrap_live_test.exs` — UPDATED: AC1 heading/progress/labels
  render test; AC2 3-step + Connect-with-OIDC redirect (replaces the old 4-step Finish walk).

### Test result (RED → GREEN)
RED: 9/10 new+updated tests failed for the right reasons (missing `encrypt_secret/1` public,
missing `bootstrap_confirm_claim/2`, missing `connect_oidc` button / new labels / progress).
GREEN: `mix test test/nebu/admin/ test/nebu/web/ --warnings-as-errors` → **70 passed, 4 excluded**,
no regressions. E2E (`bootstrap.feature`) deferred to the pipeline verification step.

## Discovery context
Found 2026-06-18 after fixing `fix-bootstrap-wizard-unreachable`: with the wizard now
reachable, `doBootstrapAdmin` advances past step 1 then times out at step 2/3 because
the labels and the "Connect with OIDC" flow don't exist. Root-caused to the Elixir
wizard implementing a simpler "Finish" flow (hardcoded `admin_group_claim`) instead of
the Go-parity OIDC-login + claim-discovery flow the acceptance criteria require.
User decision (2026-06-18): implement full Go parity in the wizard.
