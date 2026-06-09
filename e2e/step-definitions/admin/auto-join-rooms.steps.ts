/**
 * Step definitions for features/admin/auto-join-rooms.feature
 *
 * Story: admin-auto-join-rooms (epic: room-naming-and-default-rooms)
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// ─── Background steps (reuse existing where available) ───────────────────────
// "the Nebu stack is running", "bootstrap has been completed", and
// "the operator is logged in as admin" are defined in bootstrap.steps.ts.
// Only new steps specific to auto-join are defined here.

Given(
  'a room named {string} exists in the system',
  async ({ page }: { page: Page }, roomName: string) => {
    // Navigate to the admin rooms list and verify the room appears.
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    // Use a specific locator targeting table cells, list items, or links.
    const roomEntry = page.locator('td, li, a').filter({ hasText: roomName }).first();
    await expect(roomEntry).toBeVisible({ timeout: 15_000 });
  }
);

Given(
  'room {string} has auto-join enabled',
  async ({ page }: { page: Page }, roomName: string) => {
    // Navigate to the room detail and enable auto-join if not already enabled.
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    // Click into the room detail using a specific locator.
    await page.locator('td, li, a').filter({ hasText: roomName }).first().click();
    await page.waitForLoadState('networkidle');
    const toggle = page.locator('input[name="is_auto_join"]');
    const isChecked = await toggle.isChecked();
    if (!isChecked) {
      await toggle.check();
      await page.getByRole('button', { name: /save/i }).click();
      await page.waitForLoadState('networkidle');
    }
  }
);

// ─── When steps ──────────────────────────────────────────────────────────────

When(
  'the operator navigates to the detail page for room {string}',
  async ({ page }: { page: Page }, roomName: string) => {
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    await page.locator('td, li, a').filter({ hasText: roomName }).first().click();
    await page.waitForLoadState('networkidle');
  }
);

When('the operator enables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await toggle.check();
});

When('the operator disables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = page.locator('input[name="is_auto_join"]');
  await toggle.uncheck();
});

When(
  'the operator submits the room settings form',
  async ({ page }: { page: Page }) => {
    // Find the form that contains the auto-join toggle and click its Save button.
    const form = page.locator('form').filter({ has: page.locator('input[name="is_auto_join"]') });
    await form.getByRole('button', { name: /save/i }).click();
    await page.waitForLoadState('networkidle');
  }
);

// ─── Then steps ──────────────────────────────────────────────────────────────

Then(
  'the page shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    const toggle = page.locator('input[name="is_auto_join"]');
    await expect(toggle).toBeChecked();
  }
);

Then(
  'the page shows the auto-join toggle as disabled',
  async ({ page }: { page: Page }) => {
    const toggle = page.locator('input[name="is_auto_join"]');
    await expect(toggle).not.toBeChecked();
  }
);

Then(
  're-loading the room detail page still shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await page.reload();
    await page.waitForLoadState('networkidle');
    const toggle = page.locator('input[name="is_auto_join"]');
    await expect(toggle).toBeChecked();
  }
);

Then(
  're-loading the room detail page still shows the auto-join toggle as disabled',
  async ({ page }: { page: Page }) => {
    await page.reload();
    await page.waitForLoadState('networkidle');
    const toggle = page.locator('input[name="is_auto_join"]');
    await expect(toggle).not.toBeChecked();
  }
);
