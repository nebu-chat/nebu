# TEA Test-Review (PRE-DEV / TDD gate) — `e2e-session-refresh-suites`

Reviewed: story spec, 3 feature files, 3 pending step-stub files, grounded against `http_public.ex`,
`admin/auth.ex`, existing step definitions. RED-phase review of the acceptance tests.

## AC → Test mapping
Every AC (AC1–AC7) maps to ≥1 concrete test (3 feature files + `session_ttl_seam_test.exs`).
No AC has zero coverage.

## Findings

**MAJOR — AC7/seam guard misses the `/v3/refresh` re-mint path.**
`http_public.ex:429` re-derives the lifetime on refresh:
`new_expires_at = DateTime.add(DateTime.utc_now(), @max_session_seconds, :second)` — a SEPARATE
use of the constant, not routed through `session_expires_at/1` (line 372). If the dev converts
only `session_expires_at/1` to the runtime read, the refreshed session reverts to 8h in the e2e
stack → `@ac8-session-refresh` cannot fail-for-the-right-reason / flakes, and AC7 "seam is inert"
is only half-true. Action: route line 429 through the same configurable TTL; add a guard case
asserting the post-refresh lifetime honors the configured TTL.

**MINOR — soft-logout trigger under-specified / racy.** "expired server-side" via a real wait
races silent refresh and spends a second long wait. Commit to the **revoke-the-real-session**
trigger (deterministic), documented as acting on a session minted by the real PKCE login (NOT a
seeding shortcut). Decide concrete DOM/localStorage locators for "soft-logout state" + "context
preserved" before green.

**MINOR — bootstrap-wizard "fresh, un-bootstrapped instance" unrealistic in the shared serial
stack.** Story mitigation (narrow to "wizard OIDC step reachable", guard + log, no silent skip)
is the right call but only in Dev Notes prose; the feature `Given` still says "fresh,
un-bootstrapped." Soften the feature wording (or comment it) to match the mitigation; confirm
`admin/bootstrap.steps.ts` exposes a reach-the-wizard helper first.

**MINOR — admin step reads the wrong lifetime variable.** `admin-session-refresh.steps.ts:36`
hardcodes `NEBU_ADMIN_ACCESS_TOKEN_LIFETIME ?? '60'`; the wait must derive from the SAME value
wired into the stack (`NEBU_ADMIN_SESSION_TTL_SECONDS`, ~25–30s). Reconcile to one knob.

**INFO** — single derived wait per suite is acceptable; standards clean (no ROPC/forging/seeding);
duplicate-step discipline correct; stubs throw (honest RED); `@ac8-refresh-token-issued` honestly
depends on Element sending `refresh_token:true` (surface as real finding if not).

## Verdict
1 MAJOR (seam must cover `/v3/refresh` re-mint @ http_public.ex:429) + 3 MINOR. Resolved in the
story before dev (TTL seam ACs + Dev Notes updated; soft-logout committed to revoke trigger;
bootstrap feature wording softened; admin wait unified on the session-TTL knob).
