/**
 * Step definitions for features/admin/auto-join-rooms.feature
 *
 * Story: admin-auto-join-rooms (epic: room-naming-and-default-rooms)
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Adapted to the Elixir Admin UI (Nebu.Admin.RoomsLive): the rooms page is a single
 * LiveView table with ONE inline auto-join toggle per row (role="switch",
 * aria-label="Auto-join <name>"). There is no separate detail page and no settings
 * form — the toggle persists immediately via phx-click. Steps therefore scope to a
 * specific room's switch by its accessible name and assert the live-updated state.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { NEBU_USERS } from '../../fixtures/users';
import { getApiSession, createRoom } from '../../fixtures/dex-auth';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// The suite runs serially (workers: 1, fullyParallel: false), so a module-level
// "current room" is safe and lets the generic toggle/assert steps target the room
// named by the preceding navigation step.
let currentRoom = '';

// The auto-join switch for a specific room — scoped by its accessible name so it is
// unambiguous even though the list renders one switch per room. `.first()` keeps it
// deterministic if earlier runs left more than one room with the same display name
// (each run seeds a fresh "e2e-autojoin"); acting on any one such room is sufficient.
function roomToggle(page: Page, roomName: string) {
  return page.getByRole('switch', { name: `Auto-join ${roomName}` }).first();
}

async function gotoRooms(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
  await page.waitForLoadState('networkidle');
}

// ─── Background / Given steps ────────────────────────────────────────────────

Given(
  'a room named {string} exists in the system',
  async (
    { page, request, browser }: { page: Page; request: APIRequestContext; browser: Browser },
    roomName: string,
  ) => {
    currentRoom = roomName;
    // Ensure the precondition actually holds: create the room via the Matrix API if the
    // admin list doesn't already show it (global-setup only seeds a couple of rooms).
    await gotoRooms(page);
    if (!(await roomToggle(page, roomName).isVisible().catch(() => false))) {
      const session = await getApiSession(request, NEBU_USERS.kai, browser);
      await createRoom(request, session.token, roomName).catch(() => { /* may already exist */ });
      await gotoRooms(page);
    }
    await expect(roomToggle(page, roomName)).toBeVisible({ timeout: 15_000 });
  }
);

Given(
  'room {string} has auto-join enabled',
  async ({ page }: { page: Page }, roomName: string) => {
    currentRoom = roomName;
    await gotoRooms(page);
    const toggle = roomToggle(page, roomName);
    await expect(toggle).toBeVisible({ timeout: 15_000 });
    if (!(await toggle.isChecked())) {
      await toggle.click(); // phx-click persists immediately
      await expect(toggle).toBeChecked({ timeout: 10_000 });
    }
  }
);

// ─── When steps ──────────────────────────────────────────────────────────────

When(
  'the operator navigates to the detail page for room {string}',
  async ({ page }: { page: Page }, roomName: string) => {
    // RoomsLive is a single list view (no separate detail page); navigating to the
    // rooms page is sufficient. Remember which room subsequent steps act on.
    currentRoom = roomName;
    await gotoRooms(page);
    await expect(roomToggle(page, roomName)).toBeVisible({ timeout: 15_000 });
  }
);

When('the operator enables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = roomToggle(page, currentRoom);
  if (!(await toggle.isChecked())) {
    await toggle.click();
  }
});

When('the operator disables the auto-join toggle', async ({ page }: { page: Page }) => {
  const toggle = roomToggle(page, currentRoom);
  if (await toggle.isChecked()) {
    await toggle.click();
  }
});

When(
  'the operator submits the room settings form',
  async ({ page }: { page: Page }) => {
    // No-op for the LiveView UI: the toggle persisted on click (phx-click). Just let
    // the DOM-diff settle so the subsequent assertion reads the committed state.
    await page.waitForTimeout(300);
  }
);

// ─── Then steps ──────────────────────────────────────────────────────────────

Then(
  'the page shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await expect(roomToggle(page, currentRoom)).toBeChecked({ timeout: 10_000 });
  }
);

Then(
  'the page shows the auto-join toggle as disabled',
  async ({ page }: { page: Page }) => {
    await expect(roomToggle(page, currentRoom)).not.toBeChecked({ timeout: 10_000 });
  }
);

Then(
  're-loading the room detail page still shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await gotoRooms(page);
    await expect(roomToggle(page, currentRoom)).toBeChecked({ timeout: 10_000 });
  }
);

Then(
  're-loading the room detail page still shows the auto-join toggle as disabled',
  async ({ page }: { page: Page }) => {
    await gotoRooms(page);
    await expect(roomToggle(page, currentRoom)).not.toBeChecked({ timeout: 10_000 });
  }
);
