/**
 * Step definitions for features/admin/spaces.feature
 *
 * Spaces S5 (epic: spaces-elixir).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * CURRENT CONTRACT (admin-http-refactor / AC12):
 *   SpacesLive was CONVERTED to a dead HTTP controller (SpacesController). There is no
 *   LiveView socket and no in-place DOM diff. The forms are real server-rendered forms:
 *
 *   /admin/spaces            — list (table rows carry data-space-id) + a
 *                              <form data-form="create-space" method="post" action="/admin/spaces">.
 *                              On submit the controller PRG-redirects to the new space's
 *                              DETAIL page /admin/spaces/:space_id (flash "Space created").
 *                              The new space appears in the LIST only after navigating
 *                              back to /admin/spaces.
 *   /admin/spaces/:space_id  — detail page ([data-page="space-detail"]) with:
 *                                * edit name/topic form (data-form="edit-space")
 *                                * auto-join toggle: <form action=".../auto-join"> with a
 *                                  <button role="switch" aria-checked> — submitting it
 *                                  PRG-redirects back to the detail page (flash "Auto-join
 *                                  updated"). aria-checked drives Playwright toBeChecked().
 *                                * add-child form (data-form="add-child", input name
 *                                  "child_room_id") → PRG redirect; child rows carry
 *                                  data-child-id.
 *
 * Shared steps reused from the bootstrap step file:
 *   - "the Nebu stack is running" / "bootstrap has been completed" /
 *     "the operator is logged in as admin" / "the operator navigates to {string}" /
 *     "the page shows {string}"
 *   - "a room named {string} exists in the system"  (auto-join-rooms.steps.ts)
 *
 * Stale parts removed in this rewrite:
 *   - "LiveView appends the row via a DOM diff" — create now PRG-redirects to the
 *     detail page; the list only reflects the new space after a fresh GET.
 *   - networkidle waits replaced by concrete URL / element waits (PRG navigations).
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
  await expect(page.locator('[data-page="spaces"]')).toBeVisible({ timeout: 15_000 });
}

// A space's row link in the list, scoped by its visible name.
function spaceLink(page: Page, name: string) {
  return page.getByRole('link', { name }).first();
}

// The auto-join switch on the space detail page (a <button role="switch" aria-checked>).
function detailAutoJoinToggle(page: Page) {
  return page.getByRole('switch').first();
}

// Submit the create-space form and follow the PRG redirect to the space detail page.
async function createSpaceViaForm(page: Page, name: string): Promise<void> {
  await gotoSpaces(page);
  await page.locator('[data-form="create-space"] input[name="name"]').fill(name);
  await page.locator('[data-form="create-space"] button[type="submit"]').click();
  // create PRG-redirects to /admin/spaces/:space_id (the detail page), NOT back to the list.
  await page.waitForURL(/\/admin\/spaces\/[^/]+$/, { timeout: 15_000 });
  await expect(page.locator('[data-page="space-detail"]')).toBeVisible({ timeout: 15_000 });
}

// ─── Create + list (AC2) ──────────────────────────────────────────────────────

When(
  'the operator creates a space named {string}',
  async ({ page }: { page: Page }, name: string) => {
    currentSpaceName = name;
    await createSpaceViaForm(page, name);
    // Capture the new space's id from the detail page heading for later steps.
    currentSpaceId =
      (await page.locator('[data-page="space-detail"] [data-space-id]').first().getAttribute('data-space-id')) ?? '';
  }
);

Then(
  'the space {string} appears in the spaces list',
  async ({ page }: { page: Page }, name: string) => {
    // The list reflects the new space only after a fresh GET of /admin/spaces.
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
      await createSpaceViaForm(page, name);
      await gotoSpaces(page);
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
    // Full-page navigation to the detail controller page (no LiveView socket).
    await page.waitForURL(/\/admin\/spaces\/[^/]+$/, { timeout: 15_000 });
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
    await expect(page.locator('[data-page="rooms"]')).toBeVisible({ timeout: 15_000 });
    const childRow = page.locator(`tr:has-text("${childName}")`).first();
    await expect(childRow).toBeVisible({ timeout: 15_000 });
    const childId = (await childRow.getAttribute('data-room-id')) ?? '';

    // Back to the space detail page and submit the add-child form (PRG redirect).
    await page.goto(`${ADMIN_BASE_URL}/admin/spaces/${encodeURIComponent(currentSpaceId)}`);
    await expect(page.locator('[data-page="space-detail"]')).toBeVisible({ timeout: 15_000 });
    await page.locator('[data-form="add-child"] input[name="child_room_id"]').fill(childId);
    await page.locator('[data-form="add-child"] button[type="submit"]').click();
    // PRG redirect re-renders the detail page with the child row present.
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
  // The toggle is a form-POST <button role="switch">; aria-checked reflects state.
  if (!(await toggle.isChecked())) {
    await toggle.click(); // form POST persists (audited update) + PRG-redirects to detail
    await expect(page.locator('[data-page="space-detail"]')).toBeVisible({ timeout: 15_000 });
  }
});

Then('the space auto-join toggle is shown as enabled', async ({ page }: { page: Page }) => {
  await expect(detailAutoJoinToggle(page)).toBeChecked({ timeout: 10_000 });
});

Then(
  're-loading the space detail page still shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await page.goto(`${ADMIN_BASE_URL}/admin/spaces/${encodeURIComponent(currentSpaceId)}`);
    await expect(page.locator('[data-page="space-detail"]')).toBeVisible({ timeout: 15_000 });
    await expect(detailAutoJoinToggle(page)).toBeChecked({ timeout: 10_000 });
  }
);
