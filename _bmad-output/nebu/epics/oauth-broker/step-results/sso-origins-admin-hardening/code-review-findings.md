# Code review cycle 0: sso-origins-admin-hardening (nebu-code-reviewer, 2026-10-14)

1 MAJOR, 3 MINOR, INFO. Tests run by the reviewer: config_sso_trust_hardening, admin_reauth, oauth_trusted_redirect_origin (79 passed, DB tests excluded).

MAJOR
- M1 `router.ex` `unframed_path?/1` compared `conn.request_path` (exact strings) while Phoenix routes on `path_info`: `GET /admin/config/`, `/admin//config` returned 200 with `frame-ancestors 'self'` and no `X-Frame-Options` (AC3 bypass; same for the four POST paths; the OAuth prefix check had the same pre-existing gap). Fix: decide on `conn.path_info`; tests for trailing / doubled slashes.
MINOR
- m2 e2e `saveConfigFormWithAdminReauth` and the After hook returned before the redirected GET had loaded (two chained saves): wait for the redirect target and the flash.
- m3 X-4 test row `/cb;jsessionid=1` was already refused by the boundary check and did not exercise the new `;` rule; add `/cb/;x/y` and a direct `trusted_redirect_url?/2` assertion.
- m4 replay test built a new conn instead of carrying the session cookie of the first response.
INFO: gate order verified (require_admin -> CSRF -> strict fetch metadata -> marker -> validation -> write; the consumed conn reaches the response; marker consumed only on success, errors keep it, like oauth_clients_controller); `@reauth_return_re` anchored `\A...\z`, no open redirect; exactly one `x-frame-options`, LiveView / websocket unaffected, claim / role mapping keep `'self'`; `climbs?/1` only on the path part (query / fragment unaffected; a registered URI with `;` / `%25` in its path is now always "unlisted": fail closed, documented); ADR-033 SO4 allowlist wording to update (docs).

Cycle 1 (dev): M1, m2, m3, m4 fixed (tests written first, 6 red confirmed); see the UX report for the other changes of the cycle.
