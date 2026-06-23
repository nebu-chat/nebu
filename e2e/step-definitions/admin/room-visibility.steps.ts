/**
 * Step definitions for features/admin/room_visibility.feature
 *
 * Story rm1-room-visibility (epic: room-management-elixir) — ATDD, written FIRST.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common / bootstrap / auto-join step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "a room named {string} exists in the system"  (auto-join-rooms.steps.ts)
 *
 * RoomsLive is a LiveView master/detail (no full reload):
 *   /admin/rooms            — list of rooms + per-room auto-join toggle
 *   /admin/rooms/:room_id   — settings panel with a visibility <select>
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// The suite runs serially, so a module-level "current room" lets later steps act on
// the room named by the preceding navigation step.
let currentRoomId = '';

async function gotoRooms(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
}

function roomLink(page: Page, name: string) {
  return page.getByRole('link', { name }).first();
}

function visibilitySelect(page: Page) {
  return page.locator('[data-form="room-settings"] select[name="visibility"]');
}

// ─── Detail navigation ───────────────────────────────────────────────────────────

When(
  'the operator opens the detail page for room {string}',
  async ({ page }: { page: Page }, name: string) => {
    await gotoRooms(page);
    const link = roomLink(page, name);
    await expect(link).toBeVisible({ timeout: 15_000 });
    // The list row carries data-room-id; capture it then navigate to the detail.
    const row = page.locator(`tr:has-text("${name}")`).first();
    currentRoomId = (await row.getAttribute('data-room-id')) ?? '';
    await link.click();
    await page.waitForLoadState('networkidle');
    await expect(page.locator('[data-page="room-detail"] [data-room-id]')).toBeVisible({
      timeout: 15_000,
    });
  }
);

// ─── AC1: visibility selector present ─────────────────────────────────────────────

Then('the room detail panel shows a visibility selector', async ({ page }: { page: Page }) => {
  await expect(visibilitySelect(page)).toBeVisible({ timeout: 15_000 });
});

// ─── AC2/AC3: flip visibility ─────────────────────────────────────────────────────

When(
  'the operator selects visibility {string} and saves',
  async ({ page }: { page: Page }, label: string) => {
    const value = label.toLowerCase(); // "Public" → "public", "Private" → "private"
    await visibilitySelect(page).selectOption(value);
    await page.locator('[data-form="room-settings"] button[type="submit"]').click();
    // LiveView updates the panel via a DOM diff — wait for the new current-visibility marker.
    await expect(page.locator(`[data-current-visibility="${value}"]`)).toBeVisible({
      timeout: 15_000,
    });
  }
);

Then(
  'the room detail panel shows visibility {string}',
  async ({ page }: { page: Page }, label: string) => {
    const value = label.toLowerCase();
    await expect(page.locator(`[data-current-visibility="${value}"]`)).toBeVisible({
      timeout: 10_000,
    });
  }
);

Then(
  're-loading the room detail page still shows visibility {string}',
  async ({ page }: { page: Page }, label: string) => {
    const value = label.toLowerCase();
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms/${encodeURIComponent(currentRoomId)}`);
    await page.waitForLoadState('networkidle');
    await expect(page.locator(`[data-current-visibility="${value}"]`)).toBeVisible({
      timeout: 10_000,
    });
  }
);