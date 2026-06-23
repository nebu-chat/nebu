# Pre-Dev Test-Review — oidc-session-refresh (Elixir re-target), 2026-06-22

## Verdict: CLEAN (0 MAJOR)

Every AC1–AC8 has ≥1 failing test; timing deterministic (DB UPDATEs, no sleeps); real
`matrix_sessions` table via `Nebu.Repo`; E2E uses real Auth-Code+PKCE (no cookie forging/ROPC);
spec-fidelity present (`^[0-9a-f]{64}$` no dots, `soft_logout: true` top-level, `/refresh` no auth header).

## AC → test coverage
- AC1 login_refresh_test.exs:193-227 · AC2 :258-289 · AC3 :287-288 · AC4 store test 169-234
- AC5 login_refresh_test.exs:308-336 · AC6 store 102-104 + http 297-301 · AC7 :233-252
- AC8 matrix-session-refresh.feature (3 scenarios) + steps

## MINOR (address during dev or flag in post-dev review)
- **MINOR-1** login_refresh_test.exs:294 accepts `errcode in ["M_MISSING_PARAM","M_BAD_JSON"]`.
  Intended (Dev Notes §5): empty body → `M_MISSING_PARAM`. Tighten once handler distinguishes
  empty-`{}` from malformed JSON. Both 400 → low risk.
- **MINOR-2** AC6 "already-used-and-replaced RT → 401" proven only at store layer (grace-closed
  205-227); no HTTP-level rotate-then-reuse-RT → 401. Dev should add one.

## INFO / dev awareness
- AC8 steps are PENDING throw-stubs (correct for red). Dev MUST implement against real Element+Dex
  with a genuinely short OIDC access-token lifetime so refresh fires in-window. Don't let AC8 pass hollow.
- New 3-tuple seam `:matrix_sso_token_override` → `{:ok, id_token, oidc_refresh_token}` must be wired
  while keeping the legacy 2-tuple working (AC7).
- Crash/restart test N/A (DB-backed store).

ATDD subagent id: ac5d425e79857fd5d · test-review subagent id: ac53c48457a330f79
