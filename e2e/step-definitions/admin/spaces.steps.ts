/**
 * Step definitions for features/admin/spaces.feature
 *
 * Spaces S5 (epic: spaces-elixir) — ATDD, written FIRST (failing).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *   - "the page shows {string}"
 *   - "a room named {string} exists in the system"  (auto-join-rooms.steps.ts)
 *
 * SpacesLive is a LiveView master/detail (no settings form, no full reload):
 *   /admin/spaces            — list + create form + per-space auto-join toggle
 *   /admin/spaces/:space_id  — name/topic edit, child add/remove, auto-join toggle
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// The suite runs serially, so a module-level "current space" lets later steps act on
// the space named by the preceding navigation/create step.
let currentSpaceId = '';
let currentSpaceName = '';

async function gotoSpaces(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/spaces`);
  await page.waitForLoadState('networkidle');
}

// A space's row link in the list, scoped by its visible name.
function spaceLink(page: Page, name: string) {
  return page.getByRole('link', { name }).first();
}

// The auto-join switch on the space detail page (single switch, accessible name
// "Auto-join <name|id>").
function detailAutoJoinToggle(page: Page) {
  return page.getByRole('switch').first();
}

// ─── Create + list (AC2) ──────────────────────────────────────────────────────

When(
  'the operator creates a space named {string}',
  async ({ page }: { page: Page }, name: string) => {
    currentSpaceName = name;
    await gotoSpaces(page);
    await page.locator('[data-form="create-space"] input[name="name"]').fill(name);
    await page.locator('[data-form="create-space"] button[type="submit"]').click();
    // LiveView appends the row via a DOM diff — wait for it.
    await expect(spaceLink(page, name)).toBeVisible({ timeout: 15_000 });
  }
);

Then(
  'the space {string} appears in the spaces list',
  async ({ page }: { page: Page }, name: string) => {
    await gotoSpaces(page);
    await expect(spaceLink(page, name)).toBeVisible({ timeout: 15_000 });
  }
);

// ─── Space precondition ─────────────────────────────────────────────────────────

Given(
  'a space named {string} exists',
  async ({ page }: { page: Page }, name: string) => {
    currentSpaceName = name;
    await gotoSpaces(page);
    if (!(await spaceLink(page, name).isVisible().catch(() => false))) {
      await page.locator('[data-form="create-space"] input[name="name"]').fill(name);
      await page.locator('[data-form="create-space"] button[type="submit"]').click();
    }
    await expect(spaceLink(page, name)).toBeVisible({ timeout: 15_000 });
  }
);

// ─── Detail navigation ──────────────────────────────────────────────────────────

When(
  'the operator opens the detail page for space {string}',
  async ({ page }: { page: Page }, name: string) => {
    currentSpaceName = name;
    await gotoSpaces(page);
    const link = spaceLink(page, name);
    await expect(link).toBeVisible({ timeout: 15_000 });
    // The list row carries data-space-id; capture it then navigate to the detail.
    const row = page.locator(`tr:has-text("${name}")`).first();
    currentSpaceId = (await row.getAttribute('data-space-id')) ?? '';
    await link.click();
    await page.waitForLoadState('networkidle');
    await expect(page.locator('[data-page="space-detail"]')).toBeVisible({ timeout: 15_000 });
  }
);

// ─── Child management (AC4) ──────────────────────────────────────────────────────

When(
  'the operator adds child room {string} to the space',
  async ({ page }: { page: Page }, childName: string) => {
    // Resolve the child room's roomId from the rooms admin list (data-room-id), then
    // submit it into the add-child form (m.space.child is keyed by the child room id).
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    const childRow = page.locator(`tr:has-text("${childName}")`).first();
    const childId = (await childRow.getAttribute('data-room-id')) ?? '';

    // Back to the space detail page.
    await page.goto(`${ADMIN_BASE_URL}/admin/spaces/${encodeURIComponent(currentSpaceId)}`);
    await page.waitForLoadState('networkidle');
    await page.locator('[data-form="add-child"] input[name="child_room_id"]').fill(childId);
    await page.locator('[data-form="add-child"] button[type="submit"]').click();
    await expect(page.locator(`[data-child-id="${childId}"]`)).toBeVisible({ timeout: 15_000 });
    // Remember for the assertion.
    (page as unknown as { __lastChildId?: string }).__lastChildId = childId;
  }
);

Then(
  'the child room {string} is listed under the space',
  async ({ page }: { page: Page }, _childName: string) => {
    const childId = (page as unknown as { __lastChildId?: string }).__lastChildId ?? '';
    await expect(page.locator(`[data-child-id="${childId}"]`)).toBeVisible({ timeout: 15_000 });
  }
);

// ─── Auto-join toggle (AC5) ──────────────────────────────────────────────────────

When('the operator enables the space auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = detailAutoJoinToggle(page);
  if (!(await toggle.isChecked())) {
    await toggle.click(); // phx-click persists immediately (audited update path)
  }
});

Then('the space auto-join toggle is shown as enabled', async ({ page }: { page: Page }) => {
  await expect(detailAutoJoinToggle(page)).toBeChecked({ timeout: 10_000 });
});

Then(
  're-loading the space detail page still shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await page.goto(`${ADMIN_BASE_URL}/admin/spaces/${encodeURIComponent(currentSpaceId)}`);
    await page.waitForLoadState('networkidle');
    await expect(detailAutoJoinToggle(page)).toBeChecked({ timeout: 10_000 });
  }
);
