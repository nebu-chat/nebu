/**
 * Step definitions for features/admin/archive_room.feature
 *
 * Story rm3-admin-create-archive (epic: room-management-elixir) — ATDD, written FIRST.
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused from the common/bootstrap/room-visibility step files:
 *   - "the Nebu stack is running"
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "a room named {string} exists in the system"   (auto-join-rooms.steps.ts)
 *   - "the operator opens the detail page for room {string}"  (room-visibility.steps.ts)
 *
 * RoomsLive detail panel (/admin/rooms/:room_id):
 *   active room   → [data-role="archive-room"] (phx-click="archive_room", data-confirm)
 *   archived room → "Archived" badge + [data-role="unarchive-room"] (phx-click="unarchive_room")
 * Success/error are shown via a LiveView flash (alert-success / alert-error).
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// ─── Precondition: create a fresh, uniquely-named ACTIVE room to archive ─────────
//
// The shared stack persists across runs AND the stale-room filter (rm2) hides archived
// rooms from the default list — so reusing a fixed room name ("a room named X exists")
// re-created duplicates and left ambiguous/already-archived rooms behind, making the
// archive control absent on a re-run. Creating a uniquely-named room per run (mirrors
// the member-management create flow) guarantees a known-active starting state and lands
// directly on the new room's detail panel where the Archive control is present.
When('the operator creates a room to archive', async ({ page }: { page: Page }) => {
  const name = `e2e-archive-${Date.now()}`;
  await page.goto('/admin/rooms');
  await page.locator('[data-role="open-create-room"]').click();
  const form = page.locator('[data-form="create-room"]');
  await form.locator('input[name="name"]').fill(name);
  await form.locator('select[name="visibility"]').selectOption('private');
  await form.locator('button[type="submit"]').click();
  // create_room push_navigates to the new room's detail panel (active → Archive control).
  await page.waitForLoadState('networkidle');
  await expect(page.locator('[data-role="archive-room"]')).toBeVisible({ timeout: 15_000 });
});

// ─── AC5: archive (accepting the confirm dialog) ────────────────────────────────

When('the operator archives the room', async ({ page }: { page: Page }) => {
  // The Archive control carries a Phoenix LiveView data-confirm — auto-accept it.
  page.once('dialog', (dialog) => dialog.accept());
  await page.locator('[data-role="archive-room"]').click();
  // The panel flips to the Archived badge via a DOM diff.
  await expect(page.locator('[data-role="status-badge"][data-status="archived"]')).toBeVisible({
    timeout: 15_000,
  });
});

// ─── AC7: unarchive ─────────────────────────────────────────────────────────────

When('the operator unarchives the room', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="unarchive-room"]').click();
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
  await expect(page.locator('[data-role="status-badge"]')).toContainText(label, { timeout: 15_000 });
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
