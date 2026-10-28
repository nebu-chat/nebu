/**
 * Step definitions for features/admin/sso_schemes.feature
 *
 * Story: configurable-sso-redirect-schemes/fix-and-configure-sso-redirect-schemes
 *
 * Unlike some ATDD scaffolds in this repo (e.g. oidc-directory-config.steps.ts),
 * this story's implementation is already complete and unit/code/security-reviewed
 * before these BDD steps were added — so these steps are GREEN (fully implemented),
 * not RED-phase throwing stubs.
 *
 * Runner: playwright-bdd (Cucumber-based Playwright runner)
 * Config: e2e/playwright.config.ts
 *
 * Background steps ("the Nebu stack is running", "bootstrap is already completed",
 * "an admin is logged into the Admin UI", "the admin navigates to {string}") are
 * defined in bootstrap.steps.ts / common/stack-health.steps.ts and reused here
 * automatically via playwright-bdd — not redefined in this file.
 *
 * AC coverage:
 *   AC8 — Admin UI form field renders at /admin/config
 *   AC9 — POST /admin/config/sso-schemes persists valid input, flashes success
 *   AC5/AC9 — Denylisted scheme submission is rejected, flashes error, not persisted
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { saveConfigFormWithAdminReauth } from '../../fixtures/oauth-admin';

const SSO_SCHEMES_INPUT = 'input[name="sso_extra_redirect_schemes"]';

// ---------------------------------------------------------------------------
// Step: page shows the "Additional SSO redirect schemes" field (AC8)
// ---------------------------------------------------------------------------
Then(
  'the page shows the "Additional SSO redirect schemes" field',
  async ({ page }: { page: Page }) => {
    await expect(page.locator(SSO_SCHEMES_INPUT)).toBeVisible({ timeout: 10_000 });
  }
);

// ---------------------------------------------------------------------------
// Step: admin enters a value in the "Additional SSO redirect schemes" field
// ---------------------------------------------------------------------------
When(
  'the admin enters {string} in the "Additional SSO redirect schemes" field',
  async ({ page }: { page: Page }, value: string) => {
    const field = page.locator(SSO_SCHEMES_INPUT);
    await expect(field).toBeVisible({ timeout: 10_000 });
    await field.fill(value);
  }
);

// ---------------------------------------------------------------------------
// Step: admin saves the SSO schemes form (AC9)
// ---------------------------------------------------------------------------
When(
  'the admin saves the SSO schemes form',
  async ({ page }: { page: Page }) => {
    // Scope to #sso-schemes-form specifically — the /admin/config page has
    // multiple independent POST forms (scopes, sso-schemes, refresh-mode) each
    // with their own "Save ..." submit button.
    // Story sso-origins-admin-hardening (X-1): saving needs a fresh admin sign-in, driven by the shared helper.
    await saveConfigFormWithAdminReauth(page, {
      form: '#sso-schemes-form',
      field: SSO_SCHEMES_INPUT,
      button: /save sso schemes/i,
    });
  }
);

// ---------------------------------------------------------------------------
// Step: page shows an error flash message containing {string} (AC5/AC9)
// ---------------------------------------------------------------------------
Then(
  'the page shows an error flash message containing {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    // story sso-origins-admin-hardening (UX N10) added an inline field error with role=alert next to the flash: the first alert is the flash
    const flash = page.locator('[role="alert"]').first();
    await expect(flash).toBeVisible({ timeout: 10_000 });
    await expect(flash).toContainText(new RegExp(expectedSubstring, 'i'));
  }
);

// ---------------------------------------------------------------------------
// Step: the "Additional SSO redirect schemes" field shows {string} (AC9)
// ---------------------------------------------------------------------------
Then(
  'the "Additional SSO redirect schemes" field shows {string}',
  async ({ page }: { page: Page }, expectedValue: string) => {
    const field = page.locator(SSO_SCHEMES_INPUT);
    await expect(field).toBeVisible({ timeout: 10_000 });
    await expect(field).toHaveValue(expectedValue, { timeout: 10_000 });
  }
);

// ---------------------------------------------------------------------------
// Step: the "Additional SSO redirect schemes" field does not show {string}
// (AC5 — a rejected submission must not be persisted, so a reload must not
// show the denylisted value that was rejected)
// ---------------------------------------------------------------------------
Then(
  'the "Additional SSO redirect schemes" field does not show {string}',
  async ({ page }: { page: Page }, rejectedValue: string) => {
    const field = page.locator(SSO_SCHEMES_INPUT);
    await expect(field).toBeVisible({ timeout: 10_000 });
    const actual = await field.inputValue();
    expect(actual).not.toContain(rejectedValue);
  }
);
