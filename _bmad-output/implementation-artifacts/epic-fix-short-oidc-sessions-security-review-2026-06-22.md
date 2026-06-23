# Epic fix-short-oidc-sessions — SEC Gate 2 (Epic-End Security Review) — 2026-06-22

Reviewer: Kassandra 🔐
Verdict: **CLEAN / LOW only — PASS. No CRITICAL/HIGH. Epic may be marked done.**

## Scope
- Epic: `fix-short-oidc-sessions` (Matrix v1.3 token refresh + Admin UI silent OIDC refresh)
- Diff: `git diff HEAD~2..HEAD` (commits `cc228680` Matrix, `f6a4407d` Admin)
- Branch: feature/full-elixir-stack
- Stories: `oidc-session-refresh` (Matrix), `admin-oidc-session-refresh` (Admin)
- Key files reviewed in full: `matrix_session_store.ex`, `secret_box.ex`, `http_public.ex`,
  `oidc_plug.ex`, `admin/auth.ex`, `sso_login.ex`, `sso_store.ex`, `router.ex`,
  `router/protected.ex`, `event_dispatcher/server.ex` (deactivation + invalidate sites),
  `rate_limit.ex`, `matrix_sessions` schema (migrations 000001/000002).

## Consolidation of the per-story outcomes
- **Matrix story** — per-story review found a HIGH (deactivation bypass for opaque sessions:
  `deactivate_user/2` called `destroy_session/1` directly, never reaching the patched
  `invalidate_user_sessions`, so an admin-deactivated user kept a working opaque AT + could
  mint fresh tokens via `/refresh` up to 8h). **FIXED + verified** in cycle-2 re-review.
- **Admin story** — per-story review **CLEAN**.

This SEC Gate 2 confirms the HIGH fix holds with both diffs in view and looked specifically
for cross-story / holistic issues a per-story view could miss. None rise to MEDIUM+.

## Cross-story findings (NEW, holistic)

### 1. Shared `Nebu.Web.SecretBox` — SOUND for both paths
Both stories encrypt OIDC refresh tokens with the one helper.
- **Key:** `SHA-256(internal_secret)` (`secret_box.ex:59-78`), one AES-256 key shared by the
  admin client-secret, the admin OIDC RT (in the signed session) and the Matrix OIDC RT (in
  `matrix_sessions.oidc_refresh_token`). All three are server-side at-rest secrets under one
  trust boundary; AEAD with a per-call random nonce; no blind cross-store decryption (admin RT
  is only ever read back from the admin session, Matrix RT only from its DB column). Key reuse
  here is not a confusion surface.
- **Nonce:** fresh 12-byte `:crypto.strong_rand_bytes(12)` per `encrypt/1` call
  (`secret_box.ex:33`), prepended to the blob. GCM nonce-reuse requires same key **and** same
  nonce; with 96-bit random nonces at refresh-token volume the collision probability is
  negligible. No nonce-derivation-from-counter, no fixed nonce.
- **Fail-closed:** empty secret → `raise` (`secret_box.ex:72`), closing the
  `SHA-256("")`-publicly-computable hole that pattern #60 (admin-ui-migration F-1) flagged.
- **Decrypt:** returns `{:error, :decrypt_failed}` on any decode/tag failure, never raises on
  bad input; callers (`auth.ex:127`) treat a failed decrypt as a failed refresh → clear session.
**No finding.**

### 2. Deactivation / session-kill completeness across BOTH token systems — COMPLETE
- `set_is_active(user_id, false)` has **exactly one** call site: `deactivate_user/2`
  (`server.ex:3318`), which now calls `MatrixSessionStore.delete_for_user/1` after the DB
  commit (`server.ex:3336`) AND `destroy_session/1` (ETS). `reactivate` (`server.ex:3370`)
  sets `true` — not a revocation path, correctly untouched.
- `invalidate_user_sessions/2` (`server.ex:~1377`) — the second deactivation/logout choke-point
  — now also deletes opaque rows (`delete_for_user[_device]`).
- Admin cookie session: deactivation is a Matrix-domain action; the admin operator's own
  Phoenix session is a separate identity surface, cleared on its own expiry / failed refresh.
  A deactivated **Matrix user** loses the opaque Matrix AT/RT immediately (row delete) AND, as
  backstop, the opaque-path per-request `provision(...) == :deactivated` re-check
  (`oidc_plug.ex:95`) locks them out within the ≤60s cache TTL even if a delete is ever missed.
  This gives the opaque path full parity with the JWT path. **No entry point clears one token
  system but not the other for the deactivation case.** Closed pattern #64.

### 3. `invalidate_all_admin_sessions/2` (OIDC-config rotation, `server.ex:1404`) — LOW (carried INFO from cycle-2)
Still destroys only ETS sessions; does **not** call `delete_for_user`, so opaque
`matrix_sessions` rows survive an OIDC issuer/client rotation until `min(oidc_exp, 8h)`.
Re-assessed at epic scope: this is the **config-rotation re-auth** path, NOT the deactivation
kill-switch (which IS complete, see #2). Threat: after an operator rotates OIDC config (e.g.
because the IdP relationship changed), already-issued opaque Matrix sessions keep working for
up to 8h. They cannot be *refreshed against the new IdP* (the carried encrypted OIDC RT is
never round-tripped — Nebu controls lifetime independently per the documented trade-off), and
they still expire at the 8h ceiling. No privilege escalation, no new auth bypass — a bounded
staleness window on a rare admin action. **Severity: LOW.** Recommended disposition: follow-up
hardening item (add `MatrixSessionStore.delete_for_user` per affected user, or a bulk
`DELETE FROM matrix_sessions` truncate, inside `invalidate_all_admin_sessions/2`) — not a
blocker.

### 4. Two unauthenticated/auto refresh endpoints — combined surface is BOUNDED, no finding
- Matrix `POST /refresh` (`http_public.ex:97-105`) and `POST /login` are both per-IP
  rate-limited 30/min burst 10 (`@refresh_rate_limit` / `@login_rate_limit`), keyed on
  `conn.remote_ip` (`rate_limit.ex:154`) — **XFF is NOT trusted** (no trusted-proxy config),
  so the Epic 12 XFF-bucket-rotation bypass (pattern #31) is correctly avoided by default.
- **No token oracle:** `/refresh` returns the same `401 M_UNKNOWN_TOKEN` for unknown, revoked,
  and grace-expired RTs (`http_public.ex:419-420`); the opaque AT path returns the same
  `M_UNKNOWN_TOKEN` for not-found and soft/hard-revoked (`oidc_plug.ex:73-79`). Constant
  response shape — no distinguishing oracle. (Expiry adds `soft_logout: true`, which is a spec
  SHOULD and reveals only "this was a once-valid, now-expired session" — not account existence.)
- **Work per request is bounded:** one indexed lookup (`idx_matrix_sessions_refresh_token`) +
  one short transaction; no JWKS/CPU verification on the opaque path. Login still does JWKS
  verification but is identically throttled. The admin auto-refresh fires only inside the 120s
  pre-expiry window on an *already-authenticated* request, and a failed refresh fail-closes the
  session — not an unauthenticated amplification surface.
**No finding.**

### 5. Fail-closed consistency across both paths — CONSISTENT
Both the Matrix login (`http_public.ex:249`), the Matrix SSO leg (`sso_login.ex`), the admin
login callback (`auth.ex:404`) and the admin refresh (`auth.ex:187`) re-verify the id_token via
the **single** `OidcPlug.verify_token/1,2` path — alg allowlist (RS*/ES*/PS* only, no `none`/HS*),
JWKS signature, fail-closed iss, fail-closed aud (admin passes an explicit `audience:` override
that is itself fail-closed on nil/empty — `oidc_plug.ex:416-422`), exp, sub. Admin refresh
additionally re-runs `check_admin/1` so a refreshed token that lost the admin-group claim
fail-closes the session (`auth.ex:129,135-153`). No divergence; neither path is weaker.

### 6. Other holistic checks — clean
- `sso_store.ex` login-token payload widened to a map with backward-compat 2-tuple/bare-id_token
  fallback; single-use pop semantics preserved (the opaque loginToken is popped, so a replayed
  loginToken fails). OIDC RT lives only in the in-memory 30s TTL store, never persisted plaintext.
- `protected.ex` logout now branches: opaque token (no `.`) → `MatrixSessionStore.revoke/1`
  (deletes ALL rows for the `(user_id, device_id)` pair, including grace-window siblings — MINOR-1);
  JWT → denylist path unchanged. No regression to the matrix-api-migration F-1 logout-revocation fix.
- All `matrix_sessions` SQL is parameterized (`Ecto.Adapters.SQL.query` with `$n`); the
  `has_open_grace_window?` correlated EXISTS subquery is well-formed and injection-free.
- All token values are opaque or encrypted; no token/secret is logged on any path (login/refresh
  log only `user_id`/`device_id`).

## Accepted-risk / follow-up items carried out of the epic
| # | Item | Severity | Disposition |
|---|------|----------|-------------|
| 1 | `invalidate_all_admin_sessions/2` does not clear opaque `matrix_sessions` (OIDC-config rotation leaves opaque Matrix sessions live ≤8h) | LOW | **Follow-up story** (hardening) — not blocking |
| 2 | No RLS policy on `matrix_sessions` (defense-in-depth; table pre-exists in init migration, not added this epic) | LOW (advisory) | Accept for now; revisit if/when app runs under NOBYPASSRLS `nebu_app` role. Pattern #20. |
| 3 | `cleanup_expired/0` sweeper exists but is not wired to a periodic supervised task — expired/revoked rows accumulate until a future sweeper calls it | LOW (advisory, ops) | Follow-up (wire to a supervised sweeper) — not a security boundary |
| 4 | No createRoom/initial_state-style refresh-storm guard beyond per-IP 30/min — a botnet with many IPs could still drive refresh volume | LOW (advisory) | Accept — per-IP limit is Go parity; global cap is a broader infra concern (pattern carried from space-room-in-space F-1 family) |
| 5 | Pending e2e suites (`matrix-session-refresh.feature`, `admin-session-refresh.feature`) — green status not re-verified by this review | n/a (test coverage, not a vuln) | Verify in CI gate before tagging |
| 6 | Keycloak/IdP-side logout does NOT immediately invalidate the Nebu opaque session (Nebu controls lifetime independently; OIDC RT carried but not round-tripped) | LOW (documented trade-off) | **Accepted** — explicitly documented in `http_public.ex:425-428` story trade-off |

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 0 | LOW: 1 new (#3 invalidate_all_admin_sessions) + 5 carried advisories
Follow-up stories recommended: 2 (invalidate_all_admin_sessions opaque-clear; wire cleanup_expired sweeper) — both LOW, non-blocking.
Accepted risks: IdP-side-logout lifetime trade-off (documented); no-RLS-on-matrix_sessions (advisory).

**Epic security gate: PASS.** No CRITICAL/HIGH blocks the epic from being marked done. The
cross-story HIGH (deactivation bypass) found per-story was fixed and is verified complete from
the holistic view; the residual items are LOW/advisory and recommended as follow-up hardening.
