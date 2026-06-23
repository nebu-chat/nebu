/**
 * Step definitions for features/element/spaces/leave.feature
 *
 * Story spaces-elixir-s6-element-spaces-e2e — AC4 (@ac-spaces-leave)
 *
 * Scenario: Leave a Space via the Element Web context menu → Space button removed
 * from .mx_SpacePanel.
 *
 * IMPORTANT — shared steps:
 *   "kai has created a Space {string} and alex is a member via the API"  → spaces-common.steps.ts
 *   "the Space {string} appears in alex's Space panel"                   → spaces-common.steps.ts
 *   Do NOT register those Gherkin texts here — playwright-bdd global registry, one registration only.
 *
 * Reuse patterns:
 *   - sharedSpaceByName — from spaces-common.steps.ts (shared Map)
 *   - getApiSession, inviteUser, joinRoom — from fixtures/dex-auth.ts (via spaces-common)
 *   - NEBU_USERS — from fixtures/users.ts
 *   - Timestamp-suffix: actualName = `${templateName}-${Date.now()}`
 *   - dismissKeySetupDialog — from common/navigation.steps
 */

import { When, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { dismissKeySetupDialog } from '../../common/navigation.steps';
import { sharedSpaceByName } from './spaces-common.steps';

// Re-export for future consumers (allows other files to reference the shared Map).
export { sharedSpaceByName };

// ─────────────────────────────────────────────────────────────────────────────
// Leave step — drives the real Element Web Space context menu
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When {word} leaves the Space {string} via Element Web"
 *
 * Drives the genuine Element Web Space leave flow:
 * Right-click the Space button in .mx_SpacePanel → "Leave space" menu item
 * → confirmation dialog → "Leave".
 *
 * Element Web 1.12.15: Space context menu is opened by right-clicking the
 * .mx_SpaceButton in .mx_SpacePanel. The menu item text is "Leave space" (NOT
 * "Leave room" — Spaces have their own menu item). A confirmation dialog appears
 * with a "Leave" button.
 */
When(
  '{word} leaves the Space {string} via Element Web',
  async ({ page }: { page: Page }, _userName: string, spaceName: string) => {
    const entry = sharedSpaceByName.get(spaceName);
    const actualName = entry?.actualName ?? spaceName;

    await dismissKeySetupDialog(page);

    // Locate the Space button in the Space panel.
    const spaceButton = page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label="${actualName}"]`);
    await spaceButton.waitFor({ state: 'visible', timeout: 20_000 });

    // Right-click the Space button to open the context menu.
    await spaceButton.click({ button: 'right' });

    // Wait for and click the "Leave space" menu item.
    // Element Web 1.12.15: [role="menuitem"] with text "Leave space".
    const leaveMenuItem = page
      .locator('[role="menuitem"]')
      .filter({ hasText: /leave space/i })
      .or(page.getByRole('menuitem', { name: /leave space/i }));

    await leaveMenuItem.first().waitFor({ state: 'visible', timeout: 10_000 });
    await leaveMenuItem.first().click();

    // Confirmation dialog: click the "Leave" confirmation button.
    // Element Web shows a dialog asking "Are you sure you want to leave the space?"
    // The button text varies across versions: "Leave", "Leave space", "Leave Space".
    // Use a broad regex that matches any button starting with "Leave" inside a dialog.
    const confirmLeaveBtn = page
      .locator('[role="dialog"], .mx_Dialog')
      .getByRole('button', { name: /^leave/i })
      .or(page.getByRole('button', { name: /^leave/i }));

    if (await confirmLeaveBtn.first().isVisible({ timeout: 8_000 }).catch(() => false)) {
      await confirmLeaveBtn.first().click();
    }

    // Wait for the Space button to disappear from the SpacePanel (leave confirmed).
    // Use a longer timeout: the server processes the leave, propagates via /sync,
    // and Element's SpaceStore removes the Space from the panel.
    const detachedBeforeReload = await spaceButton.waitFor({ state: 'detached', timeout: 15_000 })
      .then(() => true).catch(() => false);

    if (!detachedBeforeReload) {
      // The SpacePanel may not update until the next /sync cycle; reload to force
      // a fresh sync and SpaceStore initialization, which deterministically drops
      // rooms that the user has left.
      await page.reload();
      await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});
      await dismissKeySetupDialog(page);
    }
    await dismissKeySetupDialog(page);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Assertion steps
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Then the Space {string} is not in alex's Space panel"
 *
 * Asserts the Space button is absent from .mx_SpacePanel after leaving.
 * Uses the actual (suffixed) name from sharedSpaceByName.
 */
Then(
  'the Space {string} is not in alex\'s Space panel',
  async ({ page }: { page: Page }, spaceName: string) => {
    const entry = sharedSpaceByName.get(spaceName);
    const actualName = entry?.actualName ?? spaceName;

    const spaceButton = page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label="${actualName}"]`);

    // Wait for detached state (up to 20s for sync to propagate), then verify.
    await spaceButton.waitFor({ state: 'detached', timeout: 20_000 }).catch(() => {
      // Timeout means it's still there — the assertion below will fail with a clear message.
    });

    await expect(
      spaceButton,
      `Expected Space "${actualName}" button to be ABSENT from .mx_SpacePanel after leaving. ` +
      `If still visible, the leave action did not complete or the SpacePanel has not re-rendered.`,
    ).not.toBeVisible({ timeout: 10_000 });
  },
);
