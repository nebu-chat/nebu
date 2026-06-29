# Pre-Dev Test-Review — bugfix-oidc-bootstrap-only-e2e-regressions

Verdict: APPROVED for RED phase. 0 MAJOR, 0 MINOR, 3 INFO.

AC coverage: AC1..AC5 each have >=1 test. AC6 = central E2E (out of scope).
AC2 fail-closed invariant genuinely guarded: (a) Matrix Bearer 401 with empty global caches; (b) AC1 draft-verify does NOT warm global :oidc_jwks and Matrix Bearer still 401.
Determinism: no hard waits, no cookie forging, no real DB seeding; all via injectable seams + in-memory Agent; observable surfaces (302 scope param), real RSA crypto. async:false correct. on_exit cleanup thorough.
Crash/restart: N/A (stateless, Option C).

INFO-1 (ACTIONABLE for dev): server/test/nebu/matrix/sso_login_scope_test.exs (pre-existing, fix-element-login) asserts Matrix scope EXACTLY ["openid"], profile/email absent — OPPOSITE of AC4/AC5. Dev MUST update/replace it or the suite will hold two contradicting tests. Expected; NOT a finding against new tests.
INFO-2: AC5 env-var negative (no NEBU_OIDC_*/NEBU_ADMIN_OIDC_SCOPE reintroduced) has no direct guard; enforced by ADR-022 design + code review. Acceptable.
INFO-3: user_id_name_claim_test.exs is largely a pre-green regression guard (UserId.from_claims already honors configured claim). Intentional.
