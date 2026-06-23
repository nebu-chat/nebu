# Security Review — oidc-refresh-mode-config (SEC Gate 1), 2026-06-23
**Reviewer:** Kassandra · **Verdict: CLEAN** — 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW. Commit NOT blocked.

Configurable OIDC refresh mode (online|offline) for Matrix + admin clients, server_config-backed,
set at bootstrap + runtime-changeable via /admin/config.

## Probes — all clean
1. Scope injection — REFUTED. Mode is an **enum-as-selector**: validated to offline|online on every
   write path (ConfigLive save, bootstrap save + do_complete_bootstrap) AND on the read side
   (sso_login.ex:326, auth.ex:770), then merely selects between two hardcoded literal scope lists
   (["openid","offline_access"] vs ["openid"]). Junk server_config value is inert — no scope/space/newline injection.
2. Writer privilege — gated: ConfigLive/BootstrapLive under live_session :admin on_mount :require_admin
   (router.ex:73,82,85); bootstrap promotion only in verified flow; no unauth path.
3. No verification weakening — diff touches no verify_token/alg/iss/aud/jwks; openid always present;
   online drops only offline_access, keeps profile/email (claim mapping intact).
4. Dex foot-gun surfaced verbatim in both hints (transparency), not silent.
5. Admin default online is MORE conservative than prior forced-offline (session-bound vs long-lived RT).
6. No XSS — mode renders only into <option selected={enum==...}> boolean attr; HEEx escapes.

CRITICAL 0 · HIGH 0 · MEDIUM 0 · LOW 0. New pattern recorded: enum-as-selector, not enum-as-value.
Kassandra subagent id: ae4f8c6bb133a2c99
