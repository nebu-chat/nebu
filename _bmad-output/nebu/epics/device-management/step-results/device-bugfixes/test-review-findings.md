## Test Quality Review — device-bugfixes

**Result: 0 MAJOR | 2 MINOR | 4 INFO**

All 7 ACs covered. Tests are deterministic, no hard waits.

### MINOR-1
`_priv = setup_oidc_keys()` in AC7 test setup has no comment explaining why keys are set up
when no token is minted. Add: `# OIDC keys must be configured so OidcPlug can validate (and reject) the request.`

### MINOR-2
No Playwright/Gherkin scenario for the Admin UI link (AC1–AC4).
The existing `e2e/features/admin/users.feature` checks the list exists but does NOT verify
each user_id is a clickable href. Per CLAUDE.md, UI changes require at least one E2E scenario.
Specifically missing: a scenario clicking a user link and verifying navigation to the device page.
(MINOR not MAJOR — ExUnit Plug.Test tests are thorough; E2E device page tests already exercise show action.)

### INFO-1
Both test files: add `# async: false — uses Application.put_env; cannot run concurrently` comment.

### INFO-2
`users_index_link_test.exs` on_exit re-sets `:admin_csrf_bypass` to `true` instead of deleting.
Should be: `Application.delete_env(:nebu_http, :admin_csrf_bypass)`.

### INFO-3
AC4 test: inline assertion on `enc/1` helper slightly conflates unit and integration.
Non-blocking.

### INFO-4
`signatures_upload_test.exs` missing `@moduletag :integration`. Check test_helper.exs exclusions.
