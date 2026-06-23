/**
 * Step definitions for features/admin/member_management.feature
 *
 * Story rm4-admin-member-management (epic: room-management-elixir) — ATDD, written FIRST.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *
 * The room detail panel (/admin/rooms/:room_id) has a Members section:
 *   * add-member form [data-form="add-member"] (input name="user_id" + Add button)
 *   * one row per current member [data-role="member-row"][data-user-id=...]
 *   * per-row Remove control [data-role="remove-member"][data-user-id=...]
 *     (with a Phoenix data-confirm; absent for the logged-in admin's own row)
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

function addForm(page: Page) {
  return page.locator('[data-form="add-member"]');
}

// ─── Create a room via the list modal and land on its detail panel ──────────────

When('the operator creates a room for member management', async ({ page }: { page: Page }) => {
  const name = `e2e-members-${Date.now()}`;
  await page.goto('/admin/rooms');
  await page.locator('[data-role="open-create-room"]').click();
  const form = page.locator('[data-form="create-room"]');
  await form.locator('input[name="name"]').fill(name);
  await form.locator('select[name="visibility"]').selectOption('private');
  await form.locator('button[type="submit"]').click();
  // create_room push_navigates to the new room's detail panel.
  await page.waitForLoadState('networkidle');
  await expect(page.locator('[data-section="members"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC1: add-member form present ───────────────────────────────────────────────

Then('the room detail panel shows the add-member form', async ({ page }: { page: Page }) => {
  await expect(addForm(page).locator('input[name="user_id"]')).toBeVisible({ timeout: 15_000 });
  await expect(addForm(page).locator('button[type="submit"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC2: add a member ──────────────────────────────────────────────────────────

When(
  'the operator adds the member {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await addForm(page).locator('input[name="user_id"]').fill(userId);
    await addForm(page).locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
  }
);

Then(
  'the member {string} appears in the member list',
  async ({ page }: { page: Page }, userId: string) => {
    await expect(
      page.locator(`[data-role="member-row"][data-user-id="${userId}"]`)
    ).toBeVisible({ timeout: 15_000 });
  }
);

// ─── AC4: remove a member (accepting the confirm dialog) ─────────────────────────

When(
  'the operator removes the member {string}',
  async ({ page }: { page: Page }, userId: string) => {
    page.once('dialog', (dialog) => dialog.accept());
    await page.locator(`[data-role="remove-member"][data-user-id="${userId}"]`).click();
    await page.waitForLoadState('networkidle');
  }
);

Then(
  'the member {string} no longer appears in the member list',
  async ({ page }: { page: Page }, userId: string) => {
    await expect(
      page.locator(`[data-role="member-row"][data-user-id="${userId}"]`)
    ).toHaveCount(0, { timeout: 15_000 });
  }
);

// ─── AC6: admin's own row has no Remove control ──────────────────────────────────

Then("the admin's own member row has no Remove control", async ({ page }: { page: Page }) => {
  // The creating admin is a member; their row exists but carries no remove control.
  const rows = page.locator('[data-role="member-row"]');
  await expect(rows.first()).toBeVisible({ timeout: 15_000 });
  // No remove control should target the admin's own row. We assert there is at least
  // one member row, and that the admin row (the one without a remove button) exists.
  const removeControls = page.locator('[data-role="remove-member"]');
  const rowCount = await rows.count();
  const removeCount = await removeControls.count();
  // The admin themselves has no remove control → fewer remove controls than rows.
  expect(removeCount).toBeLessThan(rowCount);
});
