/**
 * Step definitions for features/admin/media-config-damaged.feature
 *
 * Story media-config-tolerant-loader (AC7, AC8): a damaged `media_config` row is written with the documented break-glass SQL (the Admin form validates, so
 * it cannot produce one), the page must name the key in ONE text warning, and a plain save of the form (through the fresh sign-in, the shared step of
 * media-settings-gate.steps.ts) repairs the row. Reused, not redefined: "the media settings field {string} shows {string}", "the operator saves the media
 * settings form", "the page shows {string}".
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { queryMediaConfigRow, restoreMediaConfigRow, setMediaConfigRow } from '../../fixtures/db';

const PAGE_URL = '/admin/media/settings';
const WARNING = '[data-testid="media-config-damaged"]';
// the server's media_config cache is per node with a 60 s TTL and the direct SQL write sends no invalidation
const CACHE_TTL_WAIT_MS = 75_000;
const RELOAD_PAUSE_MS = 3_000;

/** key -> the value the row had before the scenario (null = no row), restored by the After hook. */
const originals = new Map<string, string | null>();

Given('the media setting {string} is stored as {string}', async ({}, key: string, value: string) => {
  if (!originals.has(key)) originals.set(key, queryMediaConfigRow(key));
  setMediaConfigRow(key, value);
});

When('the operator opens the media settings page until the damaged settings warning appears', async ({ page }: { page: Page }) => {
  const deadline = Date.now() + CACHE_TTL_WAIT_MS;
  for (;;) {
    await page.goto(PAGE_URL);
    if (await page.locator(WARNING).count()) return;
    if (Date.now() > deadline) break;
    await page.waitForTimeout(RELOAD_PAUSE_MS);
  }
  throw new Error(`the damaged-settings warning did not appear on ${PAGE_URL} within ${CACHE_TTL_WAIT_MS} ms (per-node cache TTL 60 s)`);
});

Then('the damaged settings warning names {string}', async ({ page }: { page: Page }, key: string) => {
  const warning = page.locator(WARNING);
  await expect(warning).toBeVisible({ timeout: 10_000 });
  await expect(warning).toHaveAttribute('role', 'status');
  await expect(warning).toContainText(key);
});

Then('the damaged settings warning says {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(page.locator(WARNING)).toContainText(text);
});

Then('the damaged settings warning is gone', async ({ page }: { page: Page }) => {
  await expect(page.locator(WARNING)).toHaveCount(0, { timeout: 10_000 });
});

// Never leave a damaged row behind: the scenario puts the row back as it found it (a repaired row is overwritten by the original value, an absent one removed).
After({ tags: '@media-config-damaged' }, async () => {
  for (const [key, original] of originals) restoreMediaConfigRow(key, original);
  originals.clear();
});
