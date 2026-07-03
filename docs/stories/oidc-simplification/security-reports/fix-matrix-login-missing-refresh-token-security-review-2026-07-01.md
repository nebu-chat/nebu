## Security Review — fix-matrix-login-missing-refresh-token

**Epic:** oidc-simplification
**Type:** bugfix (severity: high) — mandatory SEC Gate 1
**Diff scope:** staged diff (`git diff --staged`) — Nebu code + tests only:
- `server/lib/nebu/matrix/http_public.ex` (+2 / -2): reworded the AC7-fallback WARNING log in `respond_login/7` for operator-actionability (admin-side parity).
- `server/test/nebu/matrix/login_refresh_test.exs` (+131): new tests for AC2 (log wording) and AC4 (requested-but-not-granted degradation + no opaque session row); added a raw-SQL `session_count_for_user/1` helper.
- Non-code pipeline/story artifacts (`_bmad-output/...`, story `.md`) — no security surface.
**Date:** 2026-07-01
**Reviewer:** Kassandra (nebu-agent-kassandra)

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No security issues found | — |

### Detail

**No security issues found.**

The only production-code change is a static log-message string rewrite. Reviewed against the story's explicit SEC Gate 1 focus and the full standard dimensions:

1. **No sensitive value logged (AC2 focus).** The new WARNING string at `http_public.ex:417-418` is a static literal with no interpolation. The only structured metadatum is `user_id:` (line 419) — unchanged from before, and an acceptable identifier per story scope. No `refresh_token`, `id_token`, `access_token`, or JWT content is logged. Verified the sibling opaque-session branch (`respond_login/7` clause at line 376) and the JWT-fallback branch (line 409) both remain free of token-value logging.

2. **No log injection / log forging.** The message body is a compile-time constant — no attacker-controlled substring is concatenated into it. `user_id` is passed as Logger structured metadata (a separate key), not spliced into the message text, so it cannot break out of / forge log lines even if it contained control characters. Its provenance is `Nebu.Matrix.UserId.from_claims(claims, server)` over *verified* OIDC claims, further gated through `TokenValidator.validate` which returns the canonical `user.user_id` — not raw request input.

3. **Log line never echoed to the client.** The HTTP response body sent from the fallback branch (`http_public.ex:431-438`) contains only `user_id`, `access_token` (the verified JWT), `device_id`, `token_type`. The WARNING is emitted via `Logger.warning` to server logs exclusively. No information disclosure to the client or to unauthenticated parties. AC4 test confirms the response contains no `refresh_token` / `expires_in_ms` in this path.

4. **No new refresh-token delivery condition (auth/authz invariant).** Diff is a string edit inside the `if refresh_requested do` warning block; it does not alter control flow. The guard selecting the opaque-session path (`when is_binary(oidc_refresh_token) and oidc_refresh_token != ""`) is untouched. A `refresh_token` can therefore still only be delivered when the client requested one *and* the IdP actually returned an OIDC refresh token. No path was introduced that could hand a refresh_token to a non-requesting client or to the wrong user. AC4 test additionally asserts the fallback creates **zero** `matrix_sessions` rows.

5. **Non-goals honored.** No change to Matrix `/refresh`, to `session_expires_at/1` lifetime math, or to the admin-refresh mechanism. Confirmed the admin parity source string still lives at `admin/auth.ex:329` — the reworded Matrix message aligns with it, no admin code was modified.

6. **Test-only helper (`session_count_for_user/1`).** Parameterized `Ecto.Adapters.SQL.query` with `$1` binding — no SQL injection; test-scope only, not shipped to production. No secrets, no new crypto, no new endpoint, no new migration.

**STRIDE / OWASP / CWE / ASVS L2 sweep:** Injection (none — no new input surface, no string-built SQL in prod), Auth bypass / IDOR (control flow unchanged), Secret handling / CWE-532 sensitive-data-in-log (explicitly checked — clean), Information disclosure (log is server-side, not in response), Timing side-channel (no new comparisons introduced), Tampering/log-forging (static message + separated metadata). Nebu-specific invariants (opaque-token store integrity, device binding at `http_public.ex:429`) untouched.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

**Verdict:** APPROVED (CLEAN)
