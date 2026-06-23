# CODE-REVIEW — admin-ui-migration (RE-REVIEW cycle 1)

**Verdict: CLEAN.** All 2 MAJOR + 4 MINOR from cycle 0 RESOLVED. 1 INFO (non-blocking).

## Cycle-0 findings — all resolved
- MAJOR-1 RESOLVED: /admin/login/start route added (public, before live_session), 302 to gateway OIDC start. Open-redirect CLEAN — target only from Application.get_env :admin_oidc_login_url (NEBU_ADMIN_OIDC_LOGIN_URL), start/2 ignores _params. Gateway owns the real /admin/login/start → LoginStartHandler (PKCE+state).
- MAJOR-2 RESOLVED: admin_bootstrap_live_test.exs is a real Phoenix.LiveViewTest — drives 4 steps via render_submit/render_click, asserts data-step transitions + server_config promotion + draft cleared + encrypted-secret + empty-name rejection. :admin_bootstrap_store seam keeps inline SQL in production path (ADR-018 intact).
- MINOR-2 RESOLVED: rescue _ removed from auth.ex admin_group_claim/0; running?(Nebu.Repo) guard intact; hard query crash propagates (let-it-crash).
- MINOR-3 RESOLVED: oidc_client_secret AES-256-GCM at rest (NebuHttp.Media.Crypto, key=SHA-256(internal secret), random 12B nonce per call, hex(nonce‖ct‖tag), Go parity). Encrypted before persist to draft AND server_config; decrypt round-trips; no nonce reuse.
- MINOR-4 RESOLVED: :admin_csp plug in browser pipeline — connect-src 'self' ws: wss:, script-src 'self' (no unsafe-eval/inline), style-src 'self' 'unsafe-inline', frame-ancestors 'self'.
- MINOR-1: skipped (perf note, ADR-018 compliant).

## Additional security checks (all clean)
- All 4 LiveViews inside live_session :admin on_mount {:require_admin}; /admin/login + /admin/login/start intentionally public. No bypass.
- secret_key_base prod from NEBU_ADMIN_SECRET_KEY_BASE or SHA-512 of internal-secret file (raises if neither); test fixed non-secret. No hardcoded prod secret.
- No new SQLi ($1/$2/$3 parameterized), no XSS (HEEx auto-escape, no raw/1), no plaintext-secret regression.
- E2E uses real OIDC via /admin/login/start → Dex; no cookie forging, no DB seeding.

## NEW
- INFO-1: latent self-redirect risk IF AC4 cutover later proxies /admin/* to core (deferred). Current deployment: gateway owns /admin/login/start so no loop. The go-removal-cleanup cutover story must set NEBU_ADMIN_OIDC_LOGIN_URL to the gateway/IdP absolute origin. Config-driven, documented, not user-controllable. Not a blocker.
