# Security Review — oidc-session-refresh (Elixir port), 2026-06-22

**Reviewer:** Kassandra (nebu-agent-kassandra) · **Verdict: HIGH — BLOCKED (cycle 1 of review)**

## Findings
- **HIGH #1 — Admin deactivation does not kill opaque sessions.** `deactivate_user/2`
  (server.ex:3313) calls `destroy_session/1` directly (legacy `sessions`/`sync_tokens` only),
  bypassing `invalidate_user_sessions` where the cycle-1 `matrix_sessions` deletion was wired.
  `call_opaque` (oidc_plug.ex:69-98) has no per-request `is_active` re-check (the JWT path
  re-validates every ≤60s via `provision/2`). → A deactivated user keeps a working opaque session
  up to 8h and `/refresh` mints fresh tokens. Deactivation is the primary offboarding/IR control.
  **Fix:** add `MatrixSessionStore.delete_for_user(user_id)` to `deactivate_user/2` after the DB
  commit; defense-in-depth: re-check `is_active` in `call_opaque` via the existing provision cache.
  Regression test required.
- **LOW #2 (advisory)** — `matrix_sessions` lacks `ENABLE ROW LEVEL SECURITY` (carryover of Go
  finding; single-role `nebu_app` owns table). Add RLS+allow-all or document exemption.
- **INFO #3** — `cleanup_expired/0` not wired to a sweeper (storage growth only; grace closed → no bypass).

## 8 token-refresh probes
1 entropy ✓ · 2 SecretBox AES-256-GCM (SHA-256 key, fresh 12B nonce/enc, fail-closed, tag-verified) ✓ ·
3 rotation atomic, no double-mint/replay ✓ · 4 soft_logout/expiry, min(oidc_exp,now+8h) ✓ ·
5 /refresh unauth-by-spec but rate-limited 30/min + 1MB body, uniform 401 (no oracle) ✓ ·
6 deactivation — **REFUTED → HIGH #1** · 7 opaque/JWT dispatch safe, JWT path intact ✓ · 8 SQL all `$N` ✓.

CRITICAL: 0 · HIGH: 1 (blocks) · MEDIUM: 0 · LOW: 1 · INFO: 1

Kassandra subagent id: a49a5621f7b1f3ad7
