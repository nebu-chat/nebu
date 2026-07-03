# Code Review Report — fix-matrix-login-missing-refresh-token (cycle 0)

## Verdict: CLEAN — 0 MAJOR, 0 MINOR, 4 INFO

The staged changes match the dev-story self-report exactly. The AC2 log-parity fix is correct, non-goals are honored, no token/PII leak, and AC1's diagnosis holds against the actual current source. No blocking issues.

## Independent verification (7-point checklist)

1. **Diff matches self-report — CONFIRMED.** Only `http_public.ex` (log string, +2/-2) and `login_refresh_test.exs` (+131) changed among lib/test. `sso_login.ex`, `oidc_scopes.ex`, `admin/auth.ex` not in staged diff.
2. **Admin-parity of the log message — CONFIRMED, near-verbatim.** Matrix: "matrix login: no OIDC refresh token returned — session cannot be silently refreshed; ensure the IdP grants offline_access to the matrix client" vs Admin: "...admin login:...ensure the IdP grants offline_access to the admin client". Identical structure, correct domain substitution.
3. **AC1 diagnosis (outcome (a)) — STILL CORRECT.** Spot-checked: oidc_scopes.ex:80 appends offline_access when mode=="offline"; :159-162 default collapse to "offline"; sso_login.ex:504-521 extract_id_token/1 correctly threads nil (spec-legal OAuth2).
4. **Log call site — NO token/id_token/PII leak.** `Logger.warning(<static string>, user_id: user_id)` only.
5. **Non-goal violations — NONE.** No IdP-contacting /refresh logic; session_expires_at/1 untouched; admin-refresh-mechanism untouched.
6. **Story DoD / Dev Agent Record — accurate.** AC1-AC5 checked, AC3 correctly N/A, Security Review correctly left unchecked pending Kassandra.
7. **Matrix spec (Oracle) — SATISFIED.** JWT-only degrade spec-legal; AC4 idempotency (no opaque session row) holds; no new error codes/status regressions.

## Findings

**INFO-1 — Story Implementation Map has stale line references** (pre-existing prose, not dev-story's edit; recurrence of known extraction-refactor-drift pattern). Non-blocking.

**INFO-2 — Minor count-phrasing inconsistency** between Dev Agent Record ("1171 tests, 0 failures, 2 skipped") and pipeline-state ("1169 passed/2 skipped") — consistent once "passed" vs "total" accounted for. Cosmetic.

**INFO-3 — Pre-existing `--warnings-as-errors` failure** in a different story's test file (bootstrap_admin_session_identity_test.exs:168), correctly out of scope here but flags CI warnings-gate is red on main from a prior story.

**INFO-4 — id_token-leak assertion still not covered by test** (carried MINOR from test-review, correctly deferred as optional hardening; mitigated by direct code verification that the log call site only interpolates user_id).

## Test quality (new AC2/AC4 tests)

Sound: `mint_login_token(priv, nil)` genuinely exercises the requested-but-not-granted branch, distinct from pre-existing "not requested" path. `session_count_for_user/2` raw-SQL justified and consistent with file convention. `capture_log` usage correct. AC4 idempotency/JWT-shape assertions precise.

## Relevant files
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/http_public.ex` (log fix at 416-420)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/admin/auth.ex` (parity reference, 326-330)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/sso_login.ex` (extract_id_token, 504-521 — confirmed correct)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/web/oidc_scopes.ex` (resolve_scope 74-86, refresh_mode 151-163 — confirmed correct)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/matrix/login_refresh_test.exs` (new AC2/AC4 tests)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/docs/stories/oidc-simplification/fix-matrix-login-missing-refresh-token.md` (stale Implementation Map line refs, INFO-1)
