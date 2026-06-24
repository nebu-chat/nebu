/**
 * Step definitions for features/admin/add-user-autocomplete.feature
 *
 * Story admin-add-user-autocomplete (epic: room-naming-and-default-rooms) — ATDD.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap/spaces step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "a space named {string} exists"                  (spaces.steps.ts)
 *   - "the operator opens the detail page for space {string}" (spaces.steps.ts)
 *   - "the member {string} appears in the member list" (member-management.steps.ts)
 *
 * The add-user input is an ARIA combobox (shared by RoomsLive + SpacesLive):
 *   input[role="combobox"][data-field="add-member-user-id"]
 *   ul[role="listbox"] > li[role="option"][data-role="user-suggestion"][data-user-id=...]
 * phx-change pushes a debounced "suggest_users"; selecting pushes "select_user_suggestion"
 * which fills the input. The free-text submit path (add_member) is unchanged.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession } from '../../fixtures/dex-auth';
import { NEBU_USERS } from '../../fixtures/users';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

function comboInput(page: Page) {
  return page.locator('[data-form="add-member"] [data-field="add-member-user-id"]');
}

function suggestion(page: Page, userId: string) {
  return page.locator(`[data-role="user-suggestion"][data-user-id="${userId}"]`);
}

// ─── Background: ensure the searched-for user exists in the DB ───────────────────
// search_users only returns provisioned (DB) users; a Dex login provisions the row.

Given(
  'the existing user {string} has logged in at least once',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown seeded user "${userName}"`);
    // getApiSession performs the OIDC login (provisioning the users row) if needed.
    await getApiSession(request, user, browser);
  },
);

// ─── Create a room via the list modal and land on its detail panel ──────────────

When('the operator creates a room for autocomplete', async ({ page }: { page: Page }) => {
  const name = `e2e-autocomplete-${Date.now()}`;
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.locator('[data-role="open-create-room"]').click();
  const form = page.locator('[data-form="create-room"]');
  await form.locator('input[name="name"]').fill(name);
  await form.locator('select[name="visibility"]').selectOption('private');
  await form.locator('button[type="submit"]').click();
  await page.waitForLoadState('networkidle');
  await expect(page.locator('[data-section="members"]')).toBeVisible({ timeout: 15_000 });
});

// ─── Typing into the combobox ────────────────────────────────────────────────────

When(
  'the operator types {string} into the Add user field',
  async ({ page }: { page: Page }, text: string) => {
    const input = comboInput(page);
    await input.click();
    // Type char-by-char so phx-change (debounced) fires as a real user would trigger it.
    await input.fill('');
    await input.pressSequentially(text, { delay: 60 });
    // Allow the 200ms debounce + the LiveView round-trip to settle.
    await page.waitForTimeout(600);
  },
);

Then(
  'a user suggestion for {string} is shown',
  async ({ page }: { page: Page }, userId: string) => {
    await expect(page.locator('[data-form="add-member"] [role="listbox"]')).toBeVisible({
      timeout: 15_000,
    });
    await expect(suggestion(page, userId)).toBeVisible({ timeout: 15_000 });
  },
);

Then('no user suggestions are shown', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-role="user-suggestion"]')).toHaveCount(0, { timeout: 15_000 });
});

When(
  'the operator selects the user suggestion {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await suggestion(page, userId).click();
    await page.waitForLoadState('networkidle');
  },
);

Then(
  'the Add user field contains {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await expect(comboInput(page)).toHaveValue(userId, { timeout: 15_000 });
  },
);

When('the operator submits the Add user form', async ({ page }: { page: Page }) => {
  await page.locator('[data-form="add-member"] button[type="submit"]').click();
  await page.waitForLoadState('networkidle');
});
