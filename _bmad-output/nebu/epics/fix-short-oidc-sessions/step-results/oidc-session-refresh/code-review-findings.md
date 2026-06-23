# Code Review — oidc-session-refresh (Elixir, cycle 0), 2026-06-22

## Verdict: 4 MINOR (0 CRITICAL, 0 MAJOR)

Faithful, well-documented port of the security-reviewed Go reference. Every AC has passing test
coverage (AC8 e2e = red stubs, flagged); SQL parameterized throughout; crypto via one audited
helper; rotation atomic; JWT/admin path genuinely untouched. No correctness/security defect ≥ MAJOR.

## AC → test confirmation
AC1 login_refresh_test.exs:199-233 · AC2 :264-295 · AC3 :293-294 · AC4 store 169-234 + http 315-340
· AC5 :347-375 · AC6 store 102-104,188-203 + http 306-340 · AC7 :239-258 · AC8 feature (red stubs).
Test-review MINOR-1 (empty body → `M_MISSING_PARAM`) + MINOR-2 (HTTP rotated-then-used RT → 401) both addressed.

## Correctness spot-checks: all PASS
Grace logic matches spec; `min(oidc_exp, now+8h)`; opaque vs JWT dispatch consistent; `soft_logout`
top-level + expiry-only; `rotate_tokens/1` single transaction with `WHERE revoked_at IS NULL` +
`num_rows: 0` rollback (closes double-rotate TOCTOU); ADR-018/019/020 clean; AC7/admin JWT path byte-identical.

## MINOR findings
- **MINOR-1 — soft-revoked sibling rows never deleted (storage leak).** `matrix_session_store.ex:236-254`
  `revoke/1` deletes only the presented AT's row; rotated old rows linger (grace closed → not an auth
  bypass) because `cleanup_expired/0` is implemented but NOT wired to any sweeper. *Fix:* `revoke/1`
  also deletes soft-revoked siblings for the same `(user_id, device_id)`, OR wire `cleanup_expired/0`
  into a supervised periodic task.
- **MINOR-2 (security-relevant) — opaque path doesn't re-check deactivation.** `oidc_plug.ex:80-99`
  `call_jwt` re-runs `provision/2` and rejects `:deactivated` each request; `call_opaque` trusts the
  row and never re-checks → a user deactivated mid-session keeps a working opaque session up to 8h.
  Admin deactivation `invalidate_user_sessions` touches legacy `sessions`/`sync_tokens` only, NOT
  `matrix_sessions` (`event_dispatcher/server.ex:1359`). *Fix:* `destroy_session/1` (device "") also
  `DELETE FROM matrix_sessions WHERE user_id=$1`, or re-validate user in `call_opaque`. Kassandra to weigh in.
- **MINOR-3 — `init_opts: [action: :refresh]` is dead/decorative.** `router.ex:57` — dispatch is
  path-based (`String.ends_with?(... "/refresh")`), opt ignored. *Fix:* drop opt or add comment.
- **MINOR-4 — benign double-write race** on `has_open_grace_window?` + `mark_access_token_used`
  (`oidc_plug.ex:88-90`). UPDATE idempotent → no correctness impact. No fix required.

## Decision (orchestrator)
Cycle 1 fix: MINOR-2 (wire matrix_sessions invalidation into deactivation — important), MINOR-1
(revoke deletes siblings — cheap leak close), MINOR-3 (drop dead opt). MINOR-4 = no action.

code-review subagent id: ac6707e8853be9129
