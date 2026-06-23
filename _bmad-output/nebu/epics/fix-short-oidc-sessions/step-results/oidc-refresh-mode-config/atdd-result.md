# ATDD Result — oidc-refresh-mode-config, 2026-06-23
RED: 9 new failing tests (exactly the new behavior); compile clean, tested via PUBLIC surfaces
(scope param in the SSO/admin authorize 302 redirect — not privates).
Files: sso_scope_mode_test.exs, admin_scope_mode_test.exs, bootstrap_refresh_mode_promotion_test.exs,
config_live_refresh_mode_test.exs, e2e/features/admin/oidc-refresh-mode.feature (+steps, @pending).
AC map: AC1 defaults (Matrix offline/Admin online unset), AC2 matrix scope, AC3 admin scope (de-forced),
AC4 bootstrap promotion, AC5/AC6 ConfigLive runtime + Dex-caveat hint, AC7 no-regression defaults.
Seams the dev must add:
 1. SsoLogin :matrix_oidc_refresh_mode_reader (default: SELECT server_config; absent→offline)
 2. Auth :admin_oidc_refresh_mode_reader (default: server_config; absent→online); STOP force-adding offline_access (openid stays)
 3. Bootstrap: promote matrix_oidc_refresh_mode + admin_oidc_refresh_mode in do_complete_bootstrap; BootstrapLive put_draft
 4. ConfigLive: 2 selectors + Dex hint + save_refresh_mode handler → upsert_server_config
Note: the non-zero exit was the 9 red tests (Error 2); the rooms_live_create_archive missing_form_id is a
RUNTIME LiveView warning (not a compiler warning) — does not break --warnings-as-errors (verified clean exit on prior stories).
ATDD subagent id: aee2fb36ac5449c0e
