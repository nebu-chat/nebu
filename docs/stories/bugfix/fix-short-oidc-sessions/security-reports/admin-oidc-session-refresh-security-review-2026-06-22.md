# Security Review — admin-oidc-session-refresh (SEC Gate 1), 2026-06-22
**Reviewer:** Kassandra · **Verdict: CLEAN** — 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW. Commit NOT blocked.

Silent OIDC token refresh for the Admin UI (Nebu.Admin.Auth). Materially MORE secure than the prior
login flow: the admin-group gate is now re-evaluated against a freshly IdP-issued id_token on every
silent refresh (the deactivation/downgrade HIGH from the companion Matrix story is structurally absent
here — admin re-verifies a fresh token rather than trusting a stored artifact).

## 9 probes — all SAFE
1 RT at rest: SecretBox AES-256-GCM, fresh 12B nonce/encrypt, tag-verified, fail-closed empty secret;
  never logged/never to browser. 2 Cookie: signed + http_only + SameSite=Lax + Secure(prod); only the
  SecretBox-encrypted RT is secret-bearing. 3 token_endpoint: TLS verify_peer + 5s + fail-closed; issuer
  from env (not attacker-controlled) → no SSRF; the :httpc empty-ssl gap NOT reintroduced. 4 refreshed
  id_token re-verified via the same OidcPlug.verify_token (alg allowlist/iss/aud=client_id/exp/sub) — IdP
  not trusted blindly. 5 admin-group RE-GATED on refresh; deactivated → IdP rejects RT → drop; downgraded
  → check_admin :not_admin → drop. 6 configure_session(renew:true) on success; full drop on failure (no
  half-auth). 7 no new CSRF surface (server-initiated identity re-confirm; POSTs stay CSRF-guarded).
  8 seams test-only (Application env, arity-matched). 9 refresh-storm < LOW (needs misbehaving IdP;
  endpoint rate-limited).

CRITICAL: 0 · HIGH: 0 · MEDIUM: 0 · LOW: 0 — commit unblocked.
Kassandra subagent id: a5d0c8c36ff69efa8
