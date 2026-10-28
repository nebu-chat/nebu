/**
 * Step definitions for features/admin/media-settings-gate.feature
 *
 * Story admin-forms-gate-sweep (AC2): the media policy save is a `:marker` form, every save goes through the fresh sign-in at the IdP (the shared helper
 * `saveMappingFormWithAdminReauth` keeps the typed values of the form across the sign-in, the POST is never replayed). Every other step is shared.
 */

import { Then, When } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { saveMappingFormWithAdminReauth } from '../../fixtures/oauth-admin';

const PAGE = '/admin/media/settings';
const remembered = new Map<string, string>();

When('the operator remembers the value of the field {string}', async ({ page }: { page: Page }, name: string) => {
  const input = page.locator(`form[action="${PAGE}"] input[name="${name}"]`);
  await expect(input).toBeVisible({ timeout: 10_000 });
  remembered.set(name, await input.inputValue());
});

When('the operator restores the remembered value of the field {string}', async ({ page }: { page: Page }, name: string) => {
  const value = remembered.get(name);
  expect(value, `a value was remembered for ${name}`).toBeDefined();
  await page.locator(`form[action="${PAGE}"] input[name="${name}"]`).fill(value as string);
});

When('the operator saves the media settings form', async ({ page }: { page: Page }) => {
  const outcome = await saveMappingFormWithAdminReauth(page, { page: PAGE, button: /^save$/i });
  // every save needs its OWN fresh sign-in (the marker is single use): a save without the IdP login would mean the gate is gone
  expect(outcome.reauthenticated, 'saving the media policy goes through the fresh sign-in at the IdP').toBe(true);
});

Then('the media settings field {string} shows {string}', async ({ page }: { page: Page }, name: string, expected: string) => {
  const input = page.locator(`form[action="${PAGE}"] input[name="${name}"]`);
  await expect(input).toHaveValue(expected, { timeout: 10_000 });
});
