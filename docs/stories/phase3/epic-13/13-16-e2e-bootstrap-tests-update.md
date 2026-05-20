---
status: done
epic: 13
story: 16
security_review: not-needed
matrix: false
ui: false
atdd: not-applicable
---

# Story 13.16: E2E Bootstrap Tests — Align to 4-Step Wizard and Fix restoreBootstrappedState

Status: done

## Story

As a developer maintaining the Nebu test suite,
I want the Bootstrap Wizard E2E tests to accurately reflect the current 4-step wizard flow,
so that the test suite neither generates false negatives (testing removed UI elements) nor leaves the database in a broken state that breaks subsequent E2E tests.

**Size:** S

---

## Background & Motivation

The Bootstrap Wizard was extended over Epics 13–14 from a 2-step flow to a 4-step flow:

| Step | Title | Notes |
|------|-------|-------|
| 1 | Instance Name | Unchanged |
| 2 | OIDC Configuration | Unchanged |
| 3 | Claim Mapping | New — replaced "Key Generation"; includes "Connect with OIDC" button |
| 4 | User Import | New — replaced "Complete Setup"; OAuth round-trip now happens here |

The existing `bootstrap.spec.ts` and `bootstrap-happy-path.spec.ts` were written against the old 2/3-step structure. After the wizard was extended the tests were stale in two ways:

1. **Removed UI elements were still tested.** Three `test()` blocks targeted a "Test Connection" button that was removed from the wizard. Step 3 was still described as "Key Generation" instead of "Claim Mapping". Step 4 was still described as "Complete Setup" instead of "User Import".

2. **`restoreBootstrappedState()` was silently broken.** The helper function that restores a fully-bootstrapped DB state after `bootstrap.spec.ts` runs was inserting `admin_group_claim = 'groups'` — the name of the JWT claim field — instead of `'instance_admin'`, the group name that `MatchesAdminGroupClaim()` in `gateway/internal/auth/roles.go` searches for by scanning all claim *values*. As a result, all subsequent E2E tests (compliance, config, master-detail) that rely on an authenticated admin session silently failed with 403 Unauthorized instead of surfacing a real test failure.

3. **`bootstrap-happy-path.spec.ts` reflected the old OAuth placement.** In the old wizard, the OAuth flow was triggered at Step 4 ("Complete Setup"). The new flow triggers it at Step 3 via the "Connect with OIDC" button, redirects through Dex, then lands on `/admin/bootstrap/select-claim` (a new page), and after claim selection by the operator, advances to Step 4 (User Import). The file was also missing a retry test for the `ON CONFLICT DO UPDATE` fix applied to `SaveBootstrapConfig`.

This story documents and covers the changes already committed in `7c20168` (fix(matrix/sso): handle URL fragments when embedding login tokens).

---

## Acceptance Criteria

**AC1 — `restoreBootstrappedState()` inserts `admin_group_claim = 'instance_admin'`:**
Given `e2e/tests/features/admin/bootstrap.spec.ts`,
When `restoreBootstrappedState()` is called after bootstrap tests run,
Then the `server_config` row for `admin_group_claim` has value `'instance_admin'` (not `'groups'`),
so that `MatchesAdminGroupClaim()` in `gateway/internal/auth/roles.go` finds the group name in the JWT claim values and grants admin access.

**AC2 — "Test Connection" button tests removed:**
Given `e2e/tests/features/admin/bootstrap.spec.ts`,
When the file is inspected,
Then no `test()` block references a "Test Connection" button (the button was removed in the wizard redesign).

**AC3 — Step 3 describe block reflects "Claim Mapping":**
Given `e2e/tests/features/admin/bootstrap.spec.ts`,
When the Step 3 `describe` block is inspected,
Then:
- The heading is `'Step 3: Claim Mapping'`
- Tests check for a `'Matrix User ID Source Claim'` textbox, a `'Display Name Source Claim'` textbox, and a `'Connect with OIDC'` button

**AC4 — Step 4 describe block reflects "User Import":**
Given `e2e/tests/features/admin/bootstrap.spec.ts`,
When the Step 4 `describe` block is inspected,
Then the steps indicator test verifies 4 steps with labels `['Instance', 'OIDC', 'Claims', 'Import']`.

**AC5 — Happy-path reflects new wizard OAuth flow:**
Given `e2e/tests/features/admin/bootstrap-happy-path.spec.ts`,
When the `'completes wizard steps 1–4 and first-admin OIDC login'` test is read,
Then:
- Step 3 triggers the OAuth flow via `'Connect with OIDC'` button click (not a Step 4 button)
- After Dex login the test expects `toHaveURL(/\/admin\/bootstrap\/select-claim/)` and selects `input[type="radio"][value="instance_admin"]`
- After Confirm the test expects Step 4 heading `'Step 4: User Import'`
- The final action is `getByRole('link', { name: 'Skip and finish' })` → dashboard

**AC6 — Retry test covers `ON CONFLICT DO UPDATE` fix:**
Given `e2e/tests/features/admin/bootstrap-happy-path.spec.ts`,
When inspected,
Then a test `'ClaimSelectionHandler allows retry after failed OIDC login (no unique-constraint error)'` exists that:
- Goes through the wizard twice (abandoning OAuth mid-way the first time)
- Verifies the second completion reaches Step 4 without a 500 error

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

*This story documents existing changes — the tests themselves are the deliverable. No separate pre-implementation test scaffolding was required.*

1. **AC1 validation** — Manual inspection of `restoreBootstrappedState()` in `bootstrap.spec.ts`
   - Given: DB bootstrapped by `restoreBootstrappedState()`
   - When: OIDC login attempted by subsequent E2E tests
   - Then: `MatchesAdminGroupClaim()` returns `true`; login succeeds (200/303 to dashboard, not 403)

2. **AC5 + AC6 — Playwright happy-path tests** (in `bootstrap-happy-path.spec.ts`)
   - Given: stack running with Dex and `127.0.0.1 dex` in /etc/hosts
   - When: full 4-step wizard is completed via browser
   - Then: test reaches `/admin/dashboard` without errors
   - And (retry): second wizard completion after abandoned OAuth returns 303 to Step 4 (not 500)

---

## Tasks / Subtasks

*All tasks already completed in commit `7c20168`. Listed here for audit trail.*

- [x] Fix `restoreBootstrappedState()` — change `admin_group_claim` value from `'groups'` to `'instance_admin'` (AC1)
- [x] Remove "Test Connection" button tests (3 tests deleted) (AC2)
- [x] Replace Step 3 describe block with "Claim Mapping" block (AC3)
- [x] Replace Step 4 describe block with "User Import" block / steps-indicator test (AC4)
- [x] Rewrite `bootstrap-happy-path.spec.ts` to match new OAuth flow order (AC5)
- [x] Add retry test `ClaimSelectionHandler allows retry after failed OIDC login` (AC6)

---

## Dev Notes

### Root Cause: `admin_group_claim` Semantic Mismatch

`MatchesAdminGroupClaim(claims, adminGroupClaim)` in `gateway/internal/auth/roles.go` does **not** look up a claim by name — it scans all claim *values* and checks if any equals `adminGroupClaim`. The admin group claim stored in `server_config` must therefore be the group **name** (`"instance_admin"`), not the JWT claim **field name** (`"groups"`).

The original `restoreBootstrappedState()` inserted the claim field name `'groups'`. This made `MatchesAdminGroupClaim` return `false` for every JWT — silently denying admin access for every subsequent test file that assumed a logged-in admin session. The failure mode was subtle: each affected test would redirect to `/admin/login` instead of surfacing a 403, making the root cause hard to diagnose without reading `roles.go`.

### Files Modified (commit 7c20168)

- `e2e/tests/features/admin/bootstrap.spec.ts` — `restoreBootstrappedState()` fix + Step 3/4 describe block rewrite + "Test Connection" tests removed
- `e2e/tests/features/admin/bootstrap-happy-path.spec.ts` — complete rewrite to new wizard flow
- `e2e/step-definitions/admin/bootstrap.steps.ts` — new step definitions for admin OIDC bootstrap and login flows

### Why `atdd: not-applicable`

This story covers test-infrastructure fixes. The "implementation" is the tests themselves. Generating failing ATDD scaffolds for changes that are already committed and green would be circular. BMAD `not-applicable` is the correct flag.

### Why `security_review: not-needed`

All changes are confined to `e2e/tests/` and `e2e/step-definitions/`. No production code, no gateway handler, no SQL migration, no auth middleware was modified.

### Project Structure Notes

- E2E test files live in `e2e/tests/features/<area>/` — not `e2e/features/` (which holds Gherkin `.feature` files for the `playwright-bdd` pipeline)
- `bootstrap.spec.ts` and `bootstrap-happy-path.spec.ts` are legacy plain `.spec.ts` files (pre-Gherkin migration) — they remain as-is pending a future migration to `.feature` + `.steps.ts`
- `restoreBootstrappedState()` must always be called in `afterAll` of the last `describe` block in `bootstrap.spec.ts` so it runs exactly once at the end of all bootstrap tests

### References

- [Source: gateway/internal/auth/roles.go#MatchesAdminGroupClaim] — scans all JWT claim values, not claim keys
- [Source: e2e/tests/features/admin/bootstrap.spec.ts] — `restoreBootstrappedState()` helper + Step 3/4 describe blocks
- [Source: e2e/tests/features/admin/bootstrap-happy-path.spec.ts] — full wizard + retry test
- [Source: git commit 7c20168] — all changes committed here

---

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

N/A — changes already committed in `7c20168`.

### Completion Notes List

- Changes implemented and committed in `7c20168` as part of the SSO/Element Web integration work.
- `restoreBootstrappedState()` fix unblocked the entire subsequent E2E suite (compliance, config, master-detail tests that depend on authenticated admin sessions).
- The `ON CONFLICT DO UPDATE` fix in `SaveBootstrapConfig` (tested by AC6 retry test) was a pre-existing production bug surfaced by the new test.

### File List

- `e2e/tests/features/admin/bootstrap.spec.ts`
- `e2e/tests/features/admin/bootstrap-happy-path.spec.ts`
- `e2e/step-definitions/admin/bootstrap.steps.ts`