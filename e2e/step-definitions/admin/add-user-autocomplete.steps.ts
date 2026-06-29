/**
 * Step definitions for features/admin/add-user-autocomplete.feature
 *
 * Story admin-add-user-autocomplete (epic: room-naming-and-default-rooms).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * The typeahead (once a phx-change LiveView combobox, removed in admin-http-refactor)
 * was RESTORED in admin-add-user-autocomplete as a CSP-safe vanilla-JS fetch widget:
 * the add-user input is an ARIA combobox enhanced by priv/static/assets/app.js, which
 * calls GET /admin/users/search?q=… and renders a suggestion listbox client-side. The
 * plain free-text submit path still works without JS (progressive enhancement).
 *
 * ACTIVE coverage: the Add user field exists on room AND space detail pages, the
 * free-text submit path adds a member, AND (reactivated) typing suggests matching
 * users, selecting fills the input, and a no-match query shows an empty state — on
 * both Rooms and Spaces.
 *
 * Shared steps reused (defined elsewhere — NOT redefined here):
 *   - "the Nebu stack is running"                              (common)
 *   - "bootstrap has been completed"                           (common)
 *   - "the operator is logged in as admin"                     (common)
 *   - "a space named {string} exists"                          (spaces.steps.ts)
 *   - "the operator opens the detail page for space {string}"  (spaces.steps.ts)
 *   - "the member {string} appears in the member list"         (member-management.steps.ts)
 *
 * CURRENT add-user DOM (shared by Rooms + Spaces detail pages):
 *   [data-form="add-member"] input[name="user_id"][data-field="add-member-user-id"]
 *   + a submit button. Submit POSTs to .../members and PRG-redirects back to detail.
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
// A Dex login provisions the users row (the add-member path resolves real users).

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

// ─── Create a room via the /new page and land on its detail panel ───────────────
// (admin-http-refactor: "Create room" is a link to /admin/rooms/new; create PRG-redirects.)

When('the operator creates a room for autocomplete', async ({ page }: { page: Page }) => {
  const name = `e2e-autocomplete-${Date.now()}`;
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.locator('[data-role="open-create-room"]').click();
  await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
  const form = page.locator('form[action="/admin/rooms"][method="post"]');
  await form.locator('input[name="name"]').fill(name);
  await form.locator('select[name="visibility"]').selectOption('private');
  await form.locator('button[type="submit"]').click();
  await page.waitForURL(/\/admin\/rooms\/[^/]+$/, { timeout: 15_000 });
  await expect(page).not.toHaveURL(/\/admin\/rooms\/new$/);
  await expect(page.locator('[data-section="members"]')).toBeVisible({ timeout: 15_000 });
});

// ─── ACTIVE: the plain Add user field exists ─────────────────────────────────────

Then('the Add user field is present on the page', async ({ page }: { page: Page }) => {
  await expect(comboInput(page)).toBeVisible({ timeout: 15_000 });
  // A type="text" input (progressive enhancement: it works as free text without JS,
  // and is upgraded to an ARIA combobox by app.js).
  await expect(comboInput(page)).toHaveAttribute('type', 'text');
});

// ─── Typing into the Add user field ──────────────────────────────────────────────
// Plain text field now: just fill it. (No debounce / phx-change round-trip exists.)

When(
  'the operator types {string} into the Add user field',
  async ({ page }: { page: Page }, text: string) => {
    const input = comboInput(page);
    await input.click();
    await input.fill(text);
  },
);

When('the operator submits the Add user form', async ({ page }: { page: Page }) => {
  await page.locator('[data-form="add-member"] button[type="submit"]').click();
  await page.waitForLoadState('domcontentloaded');
});

// ─── RESTORED — client-side fetch autocomplete steps ─────────────────────────────
// The add-user typeahead returns as a CSP-safe vanilla-JS fetch widget: typing fires
// a debounced GET /admin/users/search, results render as
//   [data-form="add-member"] ul[role="listbox"] > li[role="option"][data-role="user-suggestion"][data-user-id]
// A search of sufficient length with no matches renders [data-role="no-user-suggestions"].

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
  // Deterministic: wait for the empty-state marker the widget renders once the search
  // for the (long-enough) query has resolved with zero matches — then assert no options.
  // This avoids a trivially-passing count-0 race before the fetch resolves.
  await expect(page.locator('[data-form="add-member"] [data-role="no-user-suggestions"]')).toBeVisible(
    { timeout: 15_000 },
  );
  await expect(page.locator('[data-role="user-suggestion"]')).toHaveCount(0);
});

When(
  'the operator selects the user suggestion {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await suggestion(page, userId).click();
    // Selection is fully client-side (fills the input, closes the listbox) — no network.
    await expect(page.locator('[data-form="add-member"] [role="listbox"]')).toHaveCount(0);
  },
);

Then(
  'the Add user field contains {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await expect(comboInput(page)).toHaveValue(userId, { timeout: 15_000 });
  },
);
