# Test Quality Review Report

**Scope:** `server/test/nebu/matrix/login_refresh_test.exs` (130 insertions, 0 deletions — the only staged file)
**Story:** `docs/stories/oidc-simplification/fix-matrix-login-missing-refresh-token.md`
**Context:** RED-phase ATDD tests for a bugfix story; AC1 diagnosis is (a) — IdP-side misconfiguration, no Nebu code bug; AC3 N/A.

## AC Coverage Matrix

| AC | Covered? | Test(s) | Notes |
|---|---|---|---|
| AC1 (root-cause diagnosis) | Yes, via documentation | Doc-comment block lines 372–405 | Not an executable assertion (correctly so — AC1 is a diagnosis/analysis deliverable, not runtime behavior). Comment correctly cites concrete code lines (`oidc_scopes.ex:74-86`, `:151-163`, `sso_login.ex:504-521`) for both ruled-out causes (b)/(c). |
| AC2 (actionable WARNING log) | Yes | `"logs a WARNING with admin-parity, operator-actionable wording (AC2)"` (lines 447–480) | Uses `ExUnit.CaptureLog`, correctly. Currently failing (correctly RED) — proves the gap exists. |
| AC3 (code bug fix) | N/A — correctly not tested | — | No test asserts a "fix" for (b)/(c) since AC1 ruled those out. No implementation file staged alongside. |
| AC4 (requested-but-not-granted regression) | Yes | Two tests: JWT-only degrade shape (409–428) + no-opaque-session-row idempotency (430–445) | Verified genuinely distinct from the pre-existing "not requested" test. |
| AC5 (existing tests stay green) | Yes, by construction | Diff is purely additive (0 deletions confirmed via `git diff --staged`) | No existing test lines were touched. |

## Findings

**INFO — AC1 is documentation-only, not an executable test.** Appropriate for a diagnosis-type AC.

**INFO (positive) — AC4 distinctness confirmed genuine.** Pre-existing AC7 test (lines 351-370): `mint_login_token(priv, "oidc-rt-from-keycloak")` with `refresh_token` omitted from request — "client did not ask" case. New AC4 tests: `mint_login_token(priv, nil)` with `"refresh_token" => true` explicitly sent — "client asked, IdP didn't grant" case. Different code paths confirmed via source inspection.

**INFO (positive) — ExUnit.CaptureLog used correctly**, not on internals. Matches existing convention (`admin_token_refresh_test.exs:389`).

**Intended RED (not a test defect) — AC2 log-wording assertion currently fails against `main`.** Current log: `"...verify the IdP grants offline_access)"`. Test asserts `"ensure the IdP grants offline_access to the matrix client"`. This is the proof of the gap dev-story must close.

**MINOR — SEC Gate 1 log-leak assertion covers the Matrix login-token but not the `id_token` (JWT) content.** Story's Security Considerations says log must contain no id_token content. Test only asserts `refute log =~ login_token`, not id_token. Mitigated: manual verification confirms `Logger.warning` call site only interpolates `user_id`, never token/claims content. Recommend (non-blocking): have `mint_login_token/2` also return the signed id_token so test can add `refute log =~ id_token`.

**MINOR — cosmetic `mix format` drift.** One line in new AC4 block wants a blank-line adjustment. Trivial, non-blocking for test correctness, may fail a `mix format --check-formatted` CI gate if present.

**INFO — no hard waits, no non-deterministic assertions, no brittle selectors.**

**N/A — GenServer crash/restart test.** Not applicable (no GenServer state touched, ADR-018 no domain model).

**N/A — Playwright/UI tests.** Not a UI story.

**INFO — Matrix spec status codes.** No new error codes introduced. 200 JWT-only degrade path asserted precisely (access_token present/JWT-shaped, refresh_token/expires_in_ms absent). user_id/device_id presence covered by sibling pre-existing test on same code path.

**INFO — no scope creep into follow-up story.** No staged test references `/refresh` IdP-contacting logic or `matrix-refresh-revalidates-with-idp`. Only the test file is staged — no implementation files bundled.

## Summary

| Severity | Count | Items |
|---|---|---|
| MAJOR | 0 (real defects) | The 1 "MAJOR-flagged" item is the intended RED-phase failure proving AC2's gap — not a test defect. |
| MINOR | 2 | (1) SEC Gate 1 test doesn't cover id_token leak explicitly (mitigated by manual code verification); (2) trivial `mix format` drift. |
| INFO | 8 | Positive confirmations (AC4 distinctness genuine, CaptureLog usage correct, no hard waits, no scope creep, additive-only diff, etc.) |

**Overall assessment:** CLEAN for pre-dev gate purposes — 0 MAJOR. Proceeding to dev-story. Dev-story should: (1) fix the AC2 log wording in `http_public.ex:416-420` to match admin parity ("...ensure the IdP grants offline_access to the matrix client"), (2) run `mix format` on the test file to fix the MINOR formatting drift. The id_token-leak-assertion MINOR is a nice-to-have test hardening, not required to close this story (mitigated by direct code verification); may be fixed opportunistically in the same dev-story pass without expanding scope.

**Relevant files:**
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/matrix/login_refresh_test.exs` (staged, reviewed)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/http_public.ex` (lines 409-434, AC2 log call site — needs wording fix)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/admin/auth.ex` (lines 317-330, admin-side parity message reference)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/sso_login.ex` (lines 499-521, `extract_id_token/1` — confirmed correct, no change needed)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/oidc_scopes.ex` (lines 74-86, 151-163, scope resolution — confirmed correct, no change needed)
