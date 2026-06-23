# Security Review (SEC Gate 1) — bugfix-fix-bootstrap-wizard-oidc-flow — 2026-06-19
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL, 0 HIGH. Cleared to commit.

New unauthenticated bootstrap-mode OIDC path (login/start?mode=bootstrap → Dex → callback skips admin gate → select-claim → confirm writes admin_group_claim + promotes draft + completes + mints first admin session).

## C1 (prior CRITICAL, claim-value injection) — VERIFIED FULLY CLOSED
- bootstrap_callback stashes the VERIFIED token's discovered claim values (same extract_discovered_claims/1 that renders the page) → allowed set == displayed set.
- bootstrap_confirm_claim rejects any `selected` not in the stashed set, BEFORE any write → /admin/login?error=auth_failed.
- discovered_claim_values/1 fails CLOSED (empty MapSet) on missing/malformed stash → reject-all, not bypass. Exact-string membership, no coercion. RED→GREEN tests present.

## Surface — all clean
- AC5 inert-after-complete: 3 fail-closed gates (login_start, bootstrap_callback, confirm) + select_claim_page GET; bootstrap_completed? fails CLOSED on DB error.
- Token verify: reuses OidcPlug.verify_token (alg allowlist, JWKS sig, iss/aud/exp/sub fail-closed); nonce checked before mode branch; state constant-time fail-closed; mode bound in SIGNED session not query string. No weaker second path.
- Seams (admin_oidc_token_override, oidc_metadata_override, admin_bootstrap_store, admin_secret_at_rest): test-only (get_env in lib/, never put_env in lib//config/).
- XSS escaped (Phoenix.HTML), CSRF (_csrf_token + protect_from_forgery), no open redirect (redirect_uri from server config), secret AES-256-GCM at rest (never decrypted on promotion, never logged), promotion wrapped in SQL.transaction (M1).

## Non-blocking
LOW: internal reason atoms logged on auth failure (operational, not in response). INFO: bootstrap_draft global k/v races on concurrent bootstrap → worst case re-auth, not privesc.

Tests: 35 passed across test/nebu/admin/.
