/**
 * Step definitions for features/admin/users.feature
 *
 * Story 9-26 — Phase 3, AC13.
 * F-10/F-11 fix: room-list and audit-log steps moved to rooms.steps.ts.
 *               Only the user-list assertion remains here.
 *
 * device-bugfixes story — AC1/AC2/AC3/AC4: added steps for user-row link
 * navigation scenario (@ac-users-link).
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

/**
 * "Then the user list contains at least one entry"
 * Used in features/admin/users.feature
 */
Then('the user list contains at least one entry', async ({ page }: { page: Page }) => {
  // Admin users page renders a [role="listbox"][aria-label="Users"] with
  // [role="listitem"] > [role="option"] children showing usernames like "alex active".
  // Strategy 1 (observed DOM): ARIA listbox options
  const listboxOptions = page.locator('[role="listbox"][aria-label="Users"] [role="option"], [role="listbox"][aria-label="Users"] li');
  const optionCount = await listboxOptions.count();

  if (optionCount > 0) {
    expect(optionCount).toBeGreaterThan(0);
    return;
  }

  // Strategy 2: table rows (older layout)
  const tableRows = page.locator('table tbody tr, [class*="user-list"] li, [class*="user-row"]');
  const rowCount = await tableRows.count();

  if (rowCount > 0) {
    expect(rowCount).toBeGreaterThan(0);
    return;
  }

  // Strategy 3: any listbox with items (generic fallback)
  const anyListbox = page.locator('[role="listbox"] [role="option"], [role="listbox"] [role="listitem"]');
  const anyCount = await anyListbox.count();
  expect(anyCount, 'User list should contain at least one entry').toBeGreaterThan(0);
});

// ── device-bugfixes — AC1/AC2/AC3/AC4: user-row link navigation steps ────────

/**
 * "Then each user row contains a link to the user detail page"
 *
 * device-bugfixes story AC1/AC3 guard: every user row must have an <a href>
 * pointing to /admin/users/<encoded_user_id>. Plain text without a link means
 * the detail page is unreachable via the UI.
 */
Then('each user row contains a link to the user detail page', async ({ page }: { page: Page }) => {
  // The users index renders a table; each row's first cell contains the user_id
  // wrapped in an <a href="/admin/users/..."> (fixed in device-bugfixes story).
  const rows = page.locator('table tbody tr');
  await expect(rows.first()).toBeVisible({ timeout: 15_000 });

  const rowCount = await rows.count();
  expect(rowCount, 'at least one user row must be present').toBeGreaterThan(0);

  for (let i = 0; i < rowCount; i++) {
    const row = rows.nth(i);
    // Each row must have at least one anchor pointing to /admin/users/
    const link = row.locator('a[href*="/admin/users/"]');
    await expect(link.first(), `row ${i} must contain a link to /admin/users/`).toBeVisible({ timeout: 5_000 });
  }
});

/**
 * "When the operator clicks the link for user {string}"
 *
 * device-bugfixes story AC2 guard: clicking the user_id link in the index
 * navigates to the per-user detail page.
 */
When(
  'the operator clicks the link for user {string}',
  async ({ page }: { page: Page }, userId: string) => {
    // The href is percent-encoded; Playwright matches by href content.
    const encodedId = encodeURIComponent(userId);
    const link = page.locator(`a[href="/admin/users/${encodedId}"]`);
    await expect(link.first()).toBeVisible({ timeout: 15_000 });
    await link.first().click();
    await page.waitForLoadState('networkidle');
  },
);

/**
 * "Then the device management page for {string} is shown"
 *
 * device-bugfixes story AC2 guard: after clicking the user link, the per-user
 * device management detail page (/admin/users/:user_id) is rendered. The page
 * must show the Devices section ([data-section="devices"]), which is the
 * definitive indicator that S4's show page is loaded.
 */
Then(
  'the device management page for {string} is shown',
  async ({ page }: { page: Page }, userId: string) => {
    const encodedId = encodeURIComponent(userId);
    await expect(page).toHaveURL(
      new RegExp(`/admin/users/${encodedId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`),
      { timeout: 15_000 },
    );
    // The detail page must show the Devices section (S4 AC1 requirement).
    await expect(page.locator('[data-section="devices"]')).toBeVisible({ timeout: 15_000 });
    // Also confirm the admin URL is correct (navigated away from the index).
    expect(page.url()).toContain(`${ADMIN_BASE_URL}/admin/users/`);
  },
);
