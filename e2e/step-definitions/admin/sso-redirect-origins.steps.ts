/**
 * Step definitions for features/admin/sso_redirect_origins.feature
 *
 * Story: oauth-broker / legacy-sso-redirect-confirmation (G3-3), AC14 + AC15 — ATDD tests (written before the
 * implementation; runs only against the full compose stack with the real Dex; NOT executable in the isolated
 * environment: verified with `bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Reused steps, never redefined here (bddgen rejects duplicates): "the Nebu stack is running", "bootstrap is already
 * completed", "an admin is logged into the Admin UI", "the admin navigates to {string}" (admin/bootstrap.steps.ts),
 * "the page shows a success flash message" (oidc-directory-config.steps.ts), "the page shows an error flash
 * message containing {string}" and the "Additional SSO redirect schemes" steps (sso-schemes.steps.ts).
 *
 * Page contract (shared with server/test/nebu/admin/config_controller_sso_origins_test.exs): the form
 * `#sso-origins-form` (POST /admin/config/sso-origins) with the text input `name="sso_redirect_allowed_origins"`
 * (label and aria-label "Allowed SSO redirect origins") and the submit button "Save SSO origins".
 *
 * Story sso-origins-admin-hardening (X-1): saving the form (and the SSO schemes form) needs a fresh admin sign-in; every
 * save goes through `saveConfigFormWithAdminReauth` (fixtures/oauth-admin.ts): POST -> redirect to the Dex login form
 * -> back on /admin/config -> the typed value is re-entered -> POST again.
 */

import { When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { saveConfigFormWithAdminReauth } from '../../fixtures/oauth-admin';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const SSO_ORIGINS_INPUT = 'input[name="sso_redirect_allowed_origins"]';
const SSO_SCHEMES_INPUT = 'input[name="sso_extra_redirect_schemes"]';

// Never leave an origin list or an extra scheme behind: both are cleared through their Admin UI forms (the save
// refreshes the server's OidcConfig cache on every node, a direct DB write would leave the cache stale).
// Each save is its own fresh sign-in (story sso-origins-admin-hardening, X-1): the helper drives the Dex login.
After({ tags: '@sso-redirect-origins' }, async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}/admin/config`, { waitUntil: 'domcontentloaded' });
  await page.locator(SSO_ORIGINS_INPUT).fill('');
  await saveConfigFormWithAdminReauth(page, { form: '#sso-origins-form', field: SSO_ORIGINS_INPUT, button: /save sso origins/i });
  await page.locator(SSO_SCHEMES_INPUT).fill('');
  await saveConfigFormWithAdminReauth(page, { form: '#sso-schemes-form', field: SSO_SCHEMES_INPUT, button: /save sso schemes/i });
});

Then('the page shows the "Allowed SSO redirect origins" field', async ({ page }: { page: Page }) => {
  await expect(page.locator(SSO_ORIGINS_INPUT)).toBeVisible({ timeout: 10_000 });
  await expect(page.getByLabel('Allowed SSO redirect origins')).toBeVisible();
});

When(
  'the admin enters {string} in the "Allowed SSO redirect origins" field',
  async ({ page }: { page: Page }, value: string) => {
    const field = page.locator(SSO_ORIGINS_INPUT);
    await expect(field).toBeVisible({ timeout: 10_000 });
    await field.fill(value);
  },
);

When('the admin saves the SSO origins form', async ({ page }: { page: Page }) => {
  // Scope to #sso-origins-form: /admin/config has several independent POST forms, each with its own submit button.
  // Saving needs a fresh admin sign-in (X-1): the helper goes through Dex and re-enters the typed value.
  await saveConfigFormWithAdminReauth(page, { form: '#sso-origins-form', field: SSO_ORIGINS_INPUT, button: /save sso origins/i });
});

Then('the "Allowed SSO redirect origins" field shows {string}', async ({ page }: { page: Page }, expectedValue: string) => {
  const field = page.locator(SSO_ORIGINS_INPUT);
  await expect(field).toBeVisible({ timeout: 10_000 });
  await expect(field).toHaveValue(expectedValue, { timeout: 10_000 });
});

// A rejected submission must not be persisted: after a reload the rejected value is not shown.
Then('the "Allowed SSO redirect origins" field does not show {string}', async ({ page }: { page: Page }, rejectedValue: string) => {
  const field = page.locator(SSO_ORIGINS_INPUT);
  await expect(field).toBeVisible({ timeout: 10_000 });
  expect(await field.inputValue()).not.toContain(rejectedValue);
});

/**
 * UX N10: after a rejected save the field keeps the SUBMITTED value, is marked `aria-invalid="true"`, and the error
 * is shown under the field in `<p id="sso-origins-error" role="alert">`, referenced by `aria-describedby` together
 * with the help text.
 */
Then('the "Allowed SSO redirect origins" field is marked invalid with its error message', async ({ page }: { page: Page }) => {
  const field = page.locator(SSO_ORIGINS_INPUT);
  await expect(field).toHaveAttribute('aria-invalid', 'true');
  await expect(field).toHaveAttribute('aria-describedby', /sso-origins-help/);
  await expect(field).toHaveAttribute('aria-describedby', /sso-origins-error/);
  await expect(page.locator('p#sso-origins-error[role="alert"]')).toContainText(/not valid/i);
});

/**
 * X-1 / AC4: one short sentence next to each of the three forms, referenced by `aria-describedby` of its primary control. Story admin-reauth-button-flow: the
 * control is the submit button `buttonName` with a fresh sign-in and the link "Sign in again to save" without one; the hint says to sign in first / how long the
 * fresh sign-in is valid.
 */
const FORM_OF_SAVE_BUTTON: Record<string, string> = {
  'Save SSO origins': '#sso-origins-form',
  'Save SSO schemes': '#sso-schemes-form',
  'Save OAuth settings': '#oauth-switch-form',
};
Then('the {string} form control is described by the sign-in hint', async ({ page }: { page: Page }, buttonName: string) => {
  const form = page.locator(FORM_OF_SAVE_BUTTON[buttonName] ?? '');
  const link = form.getByRole('link', { name: 'Sign in again to save', exact: true });
  const button = form.getByRole('button', { name: buttonName, exact: true });
  await expect(button.or(link), `${buttonName}: the submit or the sign-in link`).toBeVisible({ timeout: 10_000 });
  // the two states are told apart: the link (no fresh sign-in) is described by "sign in first", the submit (fresh sign-in) by the validity line
  const stale = (await link.count()) > 0;
  const control = stale ? link : button;
  const describedBy = await control.getAttribute('aria-describedby');
  expect(describedBy, `${buttonName}: aria-describedby`).toBeTruthy();
  const hint = page.locator(`#${describedBy}`);
  if (stale) {
    await expect(button, `${buttonName}: no submit while the link is shown`).toHaveCount(0);
    await expect(hint).toContainText(/\b(first|before)\b/i);
  } else {
    await expect(hint).toContainText(/\bvalid\b/i);
    await expect(hint).toContainText(/(\d+ minutes?|less than a minute)/i);
  }
});
