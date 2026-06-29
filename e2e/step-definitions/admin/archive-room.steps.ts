/**
 * Step definitions for features/admin/archive_room.feature
 *
 * Story rm3-admin-create-archive (epic: room-management-elixir).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * CURRENT CONTRACT (admin-http-refactor / AC12):
 *   RoomsLive was CONVERTED to a dead HTTP controller (RoomsController). There is no
 *   LiveView socket, no in-place DOM diff and no `data-confirm` dialog on the admin UI:
 *
 *   - "Create room" on /admin/rooms is a plain <a href="/admin/rooms/new"> link
 *     ([data-role="open-create-room"]) — NOT a modal. The dedicated /admin/rooms/new
 *     page holds <form method="post" action="/admin/rooms"> with name + visibility.
 *     On submit the controller PRG-redirects to the new room's detail page
 *     /admin/rooms/:room_id ([data-page="room-detail"]), flash "Room created".
 *   - The room detail page renders archive/unarchive as plain form-POST buttons:
 *       active   → <form action=".../archive"> button [data-role="archive-room"]
 *       archived → <form action=".../unarchive"> button [data-role="unarchive-room"]
 *     There is NO confirm dialog — submitting the form full-page-redirects back to the
 *     detail page (PRG) with flash :info ("Room archived" / "Room unarchived") rendered
 *     as <p class="alert alert-success">, and the status badge flipped
 *     ([data-role="status-badge"][data-status="archived"|"active"]).
 *
 * Shared steps reused from the bootstrap step file:
 *   - "the Nebu stack is running" / "bootstrap has been completed" /
 *     "the operator is logged in as admin"
 *
 * Stale parts removed in this rewrite:
 *   - The [data-form="create-room"] modal (never existed on the dead controller page).
 *   - The phx-click `data-confirm` dialog handler (dead controllers have no JS confirm).
 *   - LiveView "DOM diff" waits — every action is a full-page PRG navigation now.
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// The create form lives on the dedicated /admin/rooms/new page (no modal).
function createForm(page: Page) {
  return page.locator('form[action="/admin/rooms"][method="post"]');
}

// ─── Precondition: create a fresh, uniquely-named ACTIVE room to archive ─────────
//
// The shared stack persists across runs AND the stale-room filter (rm2) hides archived
// rooms from the default list — so reusing a fixed room name re-created duplicates and
// left ambiguous/already-archived rooms behind, making the archive control absent on a
// re-run. A uniquely-named room per run guarantees a known-active starting state and
// lands directly on the new room's detail page where the Archive control is present.
When('the operator creates a room to archive', async ({ page }: { page: Page }) => {
  const name = `e2e-archive-${Date.now()}`;
  await page.goto('/admin/rooms');
  // "Create room" is a link to /admin/rooms/new, not a modal trigger.
  await page.locator('[data-role="open-create-room"]').click();
  await page.waitForURL(/\/admin\/rooms\/new$/, { timeout: 15_000 });
  await createForm(page).locator('input[name="name"]').fill(name);
  await createForm(page).locator('select[name="visibility"]').selectOption('private');
  await createForm(page).locator('button[type="submit"]').click();
  // PRG redirect away from /new to the new room's detail page (active → Archive control).
  await page.waitForURL(/\/admin\/rooms\/[^/]+$/, { timeout: 15_000 });
  await expect(page).not.toHaveURL(/\/admin\/rooms\/new$/);
  await expect(page.locator('[data-page="room-detail"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-role="archive-room"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC5: archive (plain form-POST, no confirm dialog) ──────────────────────────

When('the operator archives the room', async ({ page }: { page: Page }) => {
  // The Archive control is a form-POST submit button — no JS confirm dialog. Submitting
  // full-page-redirects (PRG) back to the detail page with the Archived badge.
  await page.locator('[data-role="archive-room"]').click();
  await expect(page.locator('[data-role="status-badge"][data-status="archived"]')).toBeVisible({
    timeout: 15_000,
  });
});

// ─── AC7: unarchive (plain form-POST) ───────────────────────────────────────────

When('the operator unarchives the room', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="unarchive-room"]').click();
  // PRG redirect back to the detail page; the Archive control returns (room is active).
  await expect(page.locator('[data-role="archive-room"]')).toBeVisible({ timeout: 15_000 });
});

// ─── Flash + badge + control assertions ─────────────────────────────────────────

Then(
  'the room detail panel shows the {string} flash',
  async ({ page }: { page: Page }, message: string) => {
    await expect(page.locator('.alert-success')).toContainText(message, { timeout: 15_000 });
  }
);

Then('the room detail panel shows the {string} badge', async ({ page }: { page: Page }, label: string) => {
  await expect(page.locator('[data-role="status-badge"]').first()).toContainText(label, {
    timeout: 15_000,
  });
});

Then(
  'the room detail panel shows an {string} control',
  async ({ page }: { page: Page }, label: string) => {
    if (label === 'Unarchive') {
      await expect(page.locator('[data-role="unarchive-room"]')).toBeVisible({ timeout: 15_000 });
    } else {
      await expect(page.locator('[data-role="archive-room"]')).toBeVisible({ timeout: 15_000 });
    }
  }
);
