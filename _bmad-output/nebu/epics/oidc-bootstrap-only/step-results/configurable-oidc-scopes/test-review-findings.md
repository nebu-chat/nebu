# Test Review Report — configurable-oidc-scopes

**Date:** 2026-06-30 | **Cycle:** 0

## AC Coverage

| AC | Test file(s) | Covered |
|----|-------------|---------|
| AC1 migration RLS | migration_oidc_scopes_mutable_test.exs | ✓ |
| AC2 wizard UI fields | bootstrap_live_test.exs | ✓ |
| AC3 scope sanitization | bootstrap_live_test.exs | ✓ |
| AC4 Matrix scope seam | sso_login_test.exs (4 tests) | ✓ |
| AC5 Admin scope seam | auth_test.exs (4 tests) | ✓ |
| AC6 bootstrap persistence | bootstrap_live_test.exs + bootstrap_scope_promotion_test.exs | ✓ |
| AC7 config page read | config_scopes_test.exs | ✓ (seam fixed) |
| AC8 config page write | config_scopes_test.exs (4 tests) | ✓ |

## Findings

### MAJOR
**F1 (FIXED)** — AC7 test used `:admin_bootstrap_store` seam which ConfigController.load_config/0 does NOT consult. Fixed: replaced with `:admin_server_config_reader` seam (fn() → {:ok, [{key, value}]}). Dev agent must add this seam to ConfigController.load_config/0 before the Nebu.Repo path.

### MINOR
**F2 (FIXED)** — AC8 invalid-scope tests used `status in [200, 422]`. Fixed: pinned to `== 200` matching the existing save_refresh_mode/2 pattern.

**F3 (FIXED)** — AC8 empty-scope test accepted both 200 and 302. Fixed: empty string is valid input (no invalid chars), test now asserts 302 redirect (same as valid input path).

### INFO
**F4** — AC2 default pre-fill checks use substring `html =~ "profile email"` which could match help text. Low risk since fields are new. Acceptable.

**F5** — All `async: false` with proper `on_exit` cleanup. Expected pattern.

**F6** — No hard waits, no brittle selectors. Clean.

**F7** — ui: false in frontmatter, no Playwright tests required.

## Result: CLEAN after fixes (0 MAJOR remaining)
