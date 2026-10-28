/**
 * Step definitions for features/admin/role-mapping.feature
 *
 * Story role-mapping-self-lockout-guard (follow-up dg): the Role mapping page refuses a value that is not in the verified claims of the
 * fresh sign-in the save needs. Every other step is shared (bootstrap.steps.ts, claim-mapping.steps.ts, the admin login steps).
 */

import { Then, When } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { saveMappingFormWithAdminReauth } from '../../fixtures/oauth-admin';

Then('the role mapping page shows the claim path it looks the value up in', async ({ page }: { page: Page }) => {
  const path = page.locator('[data-role="admin-claim-path"]');
  await expect(path, 'the claim path (or the any-claim text) is shown read-only').toBeVisible({ timeout: 10_000 });
  await expect(path).not.toHaveText(/^\s*$/);
});

Then(
  'the role mapping form has {string} pre-filled with {string}',
  async ({ page }: { page: Page }, fieldName: string, expectedValue: string) => {
    const input = page.locator(`form[action="/admin/config/role-mapping"] input[name="${fieldName}"]`);
    await expect(input).toBeVisible({ timeout: 10_000 });
    await expect(input).toHaveValue(expectedValue, { timeout: 10_000 });
  },
);

When('the operator saves the role mapping form', async ({ page }: { page: Page }) => {
  const outcome = await saveMappingFormWithAdminReauth(page, { page: '/admin/config/role-mapping', button: /^save$/i });
  // every save needs its OWN fresh sign-in (the marker is single use): a save that never went through the IdP would mean the gate is gone
  expect(outcome.reauthenticated, 'saving the role mapping goes through the fresh sign-in at the IdP').toBe(true);
});
