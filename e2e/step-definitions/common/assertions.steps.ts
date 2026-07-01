/**
 * Common assertion steps — reusable Then/And steps for all features.
 *
 * Story 9-26 — Phase 1, AC4.
 * Story 9-26a — M-1 fix: use getActualRoomName() for sidebar/UI assertions.
 */

import { Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { getActualRoomName } from './room-setup.steps';
import { dismissKeySetupDialog } from './navigation.steps';

/**
 * "Then the room list is visible"
 * Asserts that .mx_LeftPanel is visible — the main room list panel.
 */
Then('the room list is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('.mx_LeftPanel')).toBeVisible({ timeout: 20_000 });
});

/**
 * "Then no error dialog appears"
 * Asserts that no .mx_Dialog with error content is visible.
 *
 * AC4 (element-login-dismiss-verification): explicitly also fails on the key-setup error
 * dialog ("could not set up keys" / "Schlüssel können nicht eingerichtet werden"). The login
 * dismiss pattern is deliberately broad (skip/continue/close/…) and could otherwise click that
 * error away; this assertion guarantees a genuine key-setup failure is caught, not masked.
 */
Then('no error dialog appears', async ({ page }: { page: Page }) => {
  const keySetupError = page.getByText(
    /could not set up (your )?keys|unable to set up keys|error setting up (secure )?keys|schlüssel können nicht eingerichtet werden|schlüssel konnten nicht eingerichtet werden/i,
  );
  if (await keySetupError.first().isVisible({ timeout: 1_000 }).catch(() => false)) {
    const detail = await keySetupError.first().textContent().catch(() => null);
    throw new Error(
      `Key-setup error dialog appeared after login: ${detail?.trim() ?? '<could not read dialog text>'}`,
    );
  }

  const errorDialog = page.locator('.mx_Dialog .mx_Dialog_content:has-text("error"), .mx_ErrorMessage');
  const count = await errorDialog.count();
  expect(count).toBe(0);
});

/**
 * "Then the room {string} appears in the sidebar"
 *
 * M-1: resolves the actual (suffixed) room name from the template name.
 *
 * Element Web 1.12.15 change: Room tiles use aria-label="Open room {name}" (no title
 * attribute, no .mx_RoomTile class). Include "invitation." suffix variant for invite rooms.
 */
Then(
  'the room {string} appears in the sidebar',
  async ({ page }: { page: Page }, roomName: string) => {
    const actualName = getActualRoomName(roomName);

    // Resolve the room tile in the left-panel room list. After accepting an invite, the
    // room moves out of the "invites" preview and into the joined-room list. Use 'attached'
    // (not 'visible') since the tile may be in the DOM but scrolled out of view in a long
    // list. Multiple strategies cover Element Web version differences.
    //   Strategy 1 (1.12.15+): aria-label="Open room {name}" (joined) OR ".. invitation." (invited)
    //   Strategy 2 (older):    title attribute in room list / .mx_RoomTile
    //   Strategy 3:            exact text anywhere in the left panel
    const isInSidebar = async (perStrategyTimeout: number): Promise<boolean> => {
      const byAriaLabel = page.locator(`[aria-label="Open room ${actualName}"], [aria-label="Open room ${actualName} invitation."]`);
      const byTestId = page.getByTestId('room-list').locator(`[title="${actualName}"]`);
      const byTile   = page.locator(`.mx_RoomTile[title="${actualName}"]`);
      const byText   = page.locator('.mx_LeftPanel').getByText(actualName, { exact: true });

      return await byAriaLabel.first().waitFor({ state: 'attached', timeout: perStrategyTimeout }).then(() => true).catch(() => false)
        || await byTestId.first().waitFor({ state: 'attached', timeout: 5_000 }).then(() => true).catch(() => false)
        || await byTile.first().waitFor({ state: 'attached', timeout: 5_000 }).then(() => true).catch(() => false)
        || await byText.first().waitFor({ state: 'attached', timeout: 5_000 }).then(() => true).catch(() => false);
    };

    // First pass: give the invitee's long-poll /sync time to deliver the membership change
    // and Element time to re-render the room list.
    let found = await isInSidebar(20_000);

    // Reload-retry: a freshly-accepted invite often does not propagate to the room list
    // within the long-poll window (Element sync lag). Reloading re-triggers initialSync,
    // which returns the now-joined room in the joined-rooms set so the tile renders.
    // Same established pattern as messages.steps.ts ("sees ... in her timeline").
    if (!found) {
      await page.reload();
      await dismissKeySetupDialog(page);
      await page.locator('.mx_LeftPanel').first().waitFor({ state: 'visible', timeout: 20_000 }).catch(() => {});
      found = await isInSidebar(20_000);
    }

    expect(found, `Room "${actualName}" should appear in the sidebar`).toBe(true);
  }
);

/**
 * "Then the room {string} is not in {word}'s sidebar"
 *
 * M-1: resolves the actual (suffixed) room name from the template name.
 *
 * Element Web 1.12.15 change: Room tiles use aria-label="Open room {name}".
 */
Then(
  'the room {string} is not in {word}\'s sidebar',
  async ({ page }: { page: Page }, roomName: string, _userName: string) => {
    const actualName = getActualRoomName(roomName);

    // Element Web 1.12.15+: aria-label based selectors
    const byAriaLabel = page.locator(`[aria-label="Open room ${actualName}"], [aria-label="Open room ${actualName} invitation."]`);

    // Older versions: title attribute
    const byTestId = page.getByTestId('room-list').locator(`[title="${actualName}"]`);
    const byTile   = page.locator(`.mx_RoomTile[title="${actualName}"]`);

    // Wait for the room to be removed from the DOM (Element Web sync may take a moment).
    // Strategy: wait for detached state (up to 10s), then verify not attached.
    // This avoids false positives from checking immediately before sync completes.
    await byAriaLabel.first().waitFor({ state: 'detached', timeout: 10_000 }).catch(() => {
      // If the element was never attached (already gone), this resolves immediately.
      // If it times out, it means the room is STILL in the sidebar after 10s.
    });

    // Re-check: confirm that no strategy finds the room (attached or visible)
    const stillPresent = await byAriaLabel.first().waitFor({ state: 'attached', timeout: 1_000 }).then(() => true).catch(() => false)
      || await byTestId.first().waitFor({ state: 'attached', timeout: 1_000 }).then(() => true).catch(() => false)
      || await byTile.first().waitFor({ state: 'attached', timeout: 1_000 }).then(() => true).catch(() => false);
    expect(stillPresent, `Room "${actualName}" should NOT be in the sidebar`).toBe(false);
  }
);
