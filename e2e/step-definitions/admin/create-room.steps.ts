/**
 * Step definitions for features/admin/create_room.feature
 *
 * Story rm3-admin-create-archive (epic: room-management-elixir) — ATDD, written FIRST.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *
 * RoomsLive list (/admin/rooms): a "Create room" button toggles a DaisyUI modal
 * (#create-room-modal) holding the create form [data-form="create-room"] with a name
 * input and a visibility <select>. A successful create redirects to the new room's
 * detail panel (/admin/rooms/:room_id).
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

function createForm(page: Page) {
  return page.locator('[data-form="create-room"]');
}

// ─── AC1: open the modal ──────────────────────────────────────────────────────

When('the operator opens the create-room modal', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="open-create-room"]').click();
  await expect(createForm(page).locator('input[name="name"]')).toBeVisible({ timeout: 15_000 });
});

Then(
  'the create-room modal shows a name field and a visibility selector',
  async ({ page }: { page: Page }) => {
    await expect(createForm(page).locator('input[name="name"]')).toBeVisible({ timeout: 15_000 });
    await expect(createForm(page).locator('select[name="visibility"]')).toBeVisible({
      timeout: 15_000,
    });
  }
);

// ─── AC2: create + redirect to detail ──────────────────────────────────────────

When(
  'the operator creates a room named {string} with visibility {string}',
  async ({ page }: { page: Page }, name: string, visibility: string) => {
    await page.locator('[data-role="open-create-room"]').click();
    await createForm(page).locator('input[name="name"]').fill(name);
    await createForm(page).locator('select[name="visibility"]').selectOption(visibility.toLowerCase());
    await createForm(page).locator('button[type="submit"]').click();
    // create_room push_navigates to the new room's detail panel.
    await page.waitForLoadState('networkidle');
    await expect(page.locator('[data-page="room-detail"] [data-room-id]')).toBeVisible({
      timeout: 15_000,
    });
  }
);

Then(
  'the operator is taken to the room detail panel for {string}',
  async ({ page }: { page: Page }, name: string) => {
    await expect(page.locator('[data-page="room-detail"]')).toBeVisible({ timeout: 15_000 });
    await expect(page.locator('[data-page="room-detail"]').getByText(name).first()).toBeVisible({
      timeout: 15_000,
    });
  }
);

// ─── AC3: inline validation ─────────────────────────────────────────────────────

When('the operator submits the create-room form with an empty name', async ({ page }: { page: Page }) => {
  await createForm(page).locator('input[name="name"]').fill('');
  await createForm(page).locator('button[type="submit"]').click();
});

Then(
  'the create-room modal shows the error {string}',
  async ({ page }: { page: Page }, message: string) => {
    await expect(page.locator('[data-role="create-error"]')).toContainText(message, {
      timeout: 15_000,
    });
    // The modal stays open — the create form is still on the page.
    await expect(createForm(page).locator('input[name="name"]')).toBeVisible();
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
