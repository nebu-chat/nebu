# Code Review — admin-oidc-session-refresh (cycle 0), 2026-06-22
## Verdict: 2 MINOR (0 CRITICAL/MAJOR) — both non-blocking, accepted as follow-ups
Change confined to server/lib/nebu/admin/auth.ex + new ExUnit suite + e2e. Unit 763 green.
AC1/AC2/AC3/AC5/AC6 + regression all PASS (unit). AC4 = e2e (pending).
Correctness/security all verified: refresh only on HTTP plug (never websocket); window logic correct;
AC5 fail-closed (drop+delete session, redirect, no raise); admin-group re-evaluated on refreshed claims;
RT AES-256-GCM at rest via SecretBox (never logged/never to browser); TLS verify_peer + 5s timeout +
fail-closed exchange; configure_session(renew:true) anti-fixation; seams are TEST-ONLY (Application env);
2-tuple→3-tuple seam backward-compatible; cookie ~1-2KB (<4KB, no silent truncation).

## MINOR-1 (deferred follow-up) — AC4 e2e not executing
admin-session-refresh.feature is @pending-feature; steps throw pending(). AC4 has no running assertion
this cycle (known deferral, flagged up front). AC1-3/5/6 unit-covered. FOLLOW-UP: implement the 4
steps via real Auth-Code+PKCE + a short-AT test IdP client; un-pend before the epic traceability gate.

## MINOR-2 (accepted, non-blocking) — no guard against non-advancing session_exp
If a misbehaving IdP returns a refreshed id_token whose exp is not later than the current one, the
session stays in-window and re-exchanges on every HTTP request (self-inflicted refresh storm). Not a
security/correctness bug on a well-behaved Keycloak (each refresh issues a later exp); token endpoint
is rate-limited regardless. ACCEPTED: a correct guard has subtlety (must not break the refresh); tracked
as a small follow-up rather than risk a hand-fix late in the pipeline.

code-review subagent id: a5068061ad7d38990
