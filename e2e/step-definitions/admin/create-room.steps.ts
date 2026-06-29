/**
 * Step definitions for features/admin/create_room.feature
 *
 * Story rm3-admin-create-archive (epic: room-management-elixir).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *
 * CURRENT controller contract (admin-http-refactor — RoomsLive → RoomsController):
 *   /admin/rooms        list page; "Create room" is an <a href="/admin/rooms/new">
 *                       ([data-role="open-create-room"]) — a link, not a modal toggle.
 *   /admin/rooms/new    a separate page with <form method="post" action="/admin/rooms">
 *                       holding a name <input name="name"> and a visibility <select
 *                       name="visibility">. No LiveView socket, no DaisyUI modal.
 *   POST /admin/rooms   success → PRG redirect to /admin/rooms/:room_id (the detail page,
 *                       [data-page="room-detail"]); empty/invalid name → re-render of the
 *                       list (/admin/rooms) with [data-role="create-error"].
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// The create form lives on the dedicated /admin/rooms/new page.
function createForm(page: Page) {
  return page.locator('form[action="/admin/rooms"][method="post"]');
}

// ─── AC1: navigate to the create-room page ────────────────────────────────────

When('the operator opens the create-room page', async ({ page }: { page: Page }) => {
  // The "Create room" control is a plain link to /admin/rooms/new (no modal).
  await page.locator('[data-role="open-create-room"]').click();
  await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
  await expect(createForm(page).locator('input[name="name"]')).toBeVisible({ timeout: 15_000 });
});

Then(
  'the create-room page shows a name field and a visibility selector',
  async ({ page }: { page: Page }) => {
    await expect(createForm(page).locator('input[name="name"]')).toBeVisible({ timeout: 15_000 });
    await expect(createForm(page).locator('select[name="visibility"]')).toBeVisible({
      timeout: 15_000,
    });
  }
);

// ─── AC2: create + PRG redirect to detail page ────────────────────────────────

When(
  'the operator creates a room named {string} with visibility {string}',
  async ({ page }: { page: Page }, name: string, visibility: string) => {
    // Go to the dedicated create page, fill the real form, submit. The POST redirects
    // (Post-Redirect-Get) to the new room's detail page /admin/rooms/:room_id.
    await page.locator('[data-role="open-create-room"]').click();
    await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
    await createForm(page).locator('input[name="name"]').fill(name);
    await createForm(page)
      .locator('select[name="visibility"]')
      .selectOption(visibility.toLowerCase());
    await createForm(page).locator('button[type="submit"]').click();
    // Wait for the PRG redirect away from /new (to the detail page or, for AC4/AC5, the
    // caller navigates to the list afterwards).
    await page.waitForLoadState('domcontentloaded');
  }
);

Then(
  'the operator is taken to the room detail page for {string}',
  async ({ page }: { page: Page }, name: string) => {
    // Full-page redirect lands on the room detail controller page.
    await expect(page).toHaveURL(/\/admin\/rooms\/[^/]+$/, { timeout: 15_000 });
    await expect(page).not.toHaveURL(/\/admin\/rooms\/new$/);
    const detail = page.locator('[data-page="room-detail"]');
    await expect(detail).toBeVisible({ timeout: 15_000 });
    await expect(detail.locator('[data-room-id]')).toBeVisible({ timeout: 15_000 });
    await expect(detail.getByText(name).first()).toBeVisible({ timeout: 15_000 });
  }
);

// ─── AC3: server-side validation error on empty name ──────────────────────────

When('the operator submits the create-room form with an empty name', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="open-create-room"]').click();
  await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
  // The name input is `required`, which blocks a native submit. Remove the attribute so the
  // request reaches the server and exercises the controller's server-side validation (the
  // real defence — clients can always bypass HTML validity).
  await createForm(page).locator('input[name="name"]').evaluate((el) => {
    (el as HTMLInputElement).removeAttribute('required');
  });
  await createForm(page).locator('input[name="name"]').fill('');
  await createForm(page).locator('button[type="submit"]').click();
  await page.waitForLoadState('domcontentloaded');
});

Then(
  'the rooms list shows the create error {string}',
  async ({ page }: { page: Page }, message: string) => {
    // On an empty name the controller re-renders the rooms list (/admin/rooms) carrying the
    // inline error. The create form is no longer on this page (it lives on /admin/rooms/new).
    await expect(page.locator('[data-role="create-error"]')).toContainText(message, {
      timeout: 15_000,
    });
  }
);

// ─── AC4/AC5 (story admin-room-creator-provisioning): named + Active, not raw id + Stale ──
//
// The rooms list renders one <tr data-room-id=… data-status=…> per room, the room name
// in a link cell, and a status badge [data-role="status-badge"]. The row for the created
// room must show the typed name and an "Active" status — never the raw "!…:localhost" id
// nor a "Stale" badge (the orphan-room symptom this story fixes).

function roomRowByName(page: Page, name: string) {
  // The first cell links to the room detail with the display name as text.
  return page.locator('tr[data-room-id]').filter({ hasText: name });
}

Then(
  'the rooms list shows a room named {string} with status {string}',
  async ({ page }: { page: Page }, name: string, status: string) => {
    const row = roomRowByName(page, name).first();
    await expect(row).toBeVisible({ timeout: 15_000 });
    // Name must be the typed name, not a raw room id.
    await expect(row).toContainText(name);
    await expect(row.locator('[data-role="status-badge"]')).toContainText(status, {
      timeout: 15_000,
    });
  }
);

Then(
  'the rooms list does not show that room as a raw room id',
  async ({ page }: { page: Page }) => {
    // No row's NAME cell may display a bare "!<hex>:<server>" room id. (data-room-id
    // attribute legitimately holds the id; we assert on the visible link text instead.)
    const nameLinks = page.locator('tr[data-room-id] td:first-child a');
    const count = await nameLinks.count();
    for (let i = 0; i < count; i++) {
      const text = ((await nameLinks.nth(i).textContent()) ?? '').trim();
      expect(text).not.toMatch(/^![0-9a-f]+:/i);
    }
  }
);

Then(
  'the rooms list does not show that room with status {string}',
  async ({ page }: { page: Page }, status: string) => {
    // The freshly-created "general" room must not carry the given (Stale) status.
    const row = roomRowByName(page, 'general').first();
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row.locator('[data-role="status-badge"]')).not.toContainText(status);
  }
);
