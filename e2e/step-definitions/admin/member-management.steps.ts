/**
 * Step definitions for features/admin/member_management.feature
 *
 * Story rm4-admin-member-management (epic: room-management-elixir).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *
 * CURRENT controller contract (admin-http-refactor — RoomsLive → RoomsController):
 *   /admin/rooms       list page; "Create room" is an <a href="/admin/rooms/new">
 *                      ([data-role="open-create-room"]) — a link, not a modal toggle.
 *   /admin/rooms/new   separate page with <form method="post" action="/admin/rooms">
 *                      (input name="name" + select name="visibility").
 *   POST /admin/rooms  success → PRG redirect to /admin/rooms/:room_id (the detail page,
 *                      [data-page="room-detail"]).
 *   The detail page Members section [data-section="members"]:
 *     * add-member form [data-form="add-member"] (plain <input name="user_id"> + Add).
 *       Submit POSTs to /admin/rooms/:room_id/members and PRG-redirects back to detail.
 *     * one row per member [data-role="member-row"][data-user-id=…].
 *     * Remove control: a POST + _method=DELETE form [data-form="remove-member"] with a
 *       <button data-role="remove-member" data-user-id=…>. Plain form submit — NO JS
 *       confirm dialog. Absent for the logged-in admin's own row.
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

function addForm(page: Page) {
  return page.locator('[data-form="add-member"]');
}

// ─── Create a room via the /new page and land on its detail panel ───────────────

When('the operator creates a room for member management', async ({ page }: { page: Page }) => {
  const name = `e2e-members-${Date.now()}`;
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.locator('[data-role="open-create-room"]').click();
  await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
  const form = page.locator('form[action="/admin/rooms"][method="post"]');
  await form.locator('input[name="name"]').fill(name);
  await form.locator('select[name="visibility"]').selectOption('private');
  await form.locator('button[type="submit"]').click();
  // create POSTs then PRG-redirects to the new room's detail page.
  await page.waitForURL(/\/admin\/rooms\/[^/]+$/, { timeout: 15_000 });
  await expect(page).not.toHaveURL(/\/admin\/rooms\/new$/);
  await expect(page.locator('[data-section="members"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC1: add-member form present ───────────────────────────────────────────────

Then('the room detail panel shows the add-member form', async ({ page }: { page: Page }) => {
  await expect(addForm(page).locator('input[name="user_id"]')).toBeVisible({ timeout: 15_000 });
  await expect(addForm(page).locator('button[type="submit"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC2: add a member (form POST → PRG redirect back to detail) ─────────────────

When(
  'the operator adds the member {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await addForm(page).locator('input[name="user_id"]').fill(userId);
    await addForm(page).locator('button[type="submit"]').click();
    // POST /members → PRG redirect to the detail page; wait for the member row to land.
    await expect(
      page.locator(`[data-role="member-row"][data-user-id="${userId}"]`)
    ).toBeVisible({ timeout: 15_000 });
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

// ─── AC4: remove a member (plain form submit — no JS confirm dialog) ─────────────

When(
  'the operator removes the member {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await page.locator(`[data-role="remove-member"][data-user-id="${userId}"]`).click();
    // POST + _method=DELETE → PRG redirect to detail; wait for the row to disappear.
    await expect(
      page.locator(`[data-role="member-row"][data-user-id="${userId}"]`)
    ).toHaveCount(0, { timeout: 15_000 });
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
  const removeControls = page.locator('[data-role="remove-member"]');
  const rowCount = await rows.count();
  const removeCount = await removeControls.count();
  // The admin themselves has no remove control → fewer remove controls than rows.
  expect(removeCount).toBeLessThan(rowCount);
});
