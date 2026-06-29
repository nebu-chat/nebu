/**
 * Step definitions for features/element/messages/{send,receive}.feature
 *
 * Story 9-26 — Phase 2, AC10 + AC11.
 * Story 9-26a — Fixes M-7, M-9, m-13.
 *
 * F-09 fix: composer uses pressSequentially() instead of fill() for proper
 *           React event dispatch on contenteditable div.
 * F-01 fix: "marie sees" step uses secondPage fixture (not module-level variable).
 * M-7 fix:  second-context step guards against non-marie users.
 * M-9 fix:  message-visible step also asserts sending indicator disappears.
 * m-13 fix: removed redundant ensureStorageState call (fixture already warmed it).
 */

import { When, Then, Given } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { getActualRoomName, roomIdByScenario } from '../common/room-setup.steps';
import { dismissKeySetupDialog } from '../common/navigation.steps';

const ELEMENT_URL_MSG = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';

// ─────────────────────────────────────────────────────────────────────────────
// AC10: Message Send Steps
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When alex types {string} in the composer"
 * F-09: uses pressSequentially() for proper React event dispatch on contenteditable.
 */
When(
  '{word} types {string} in the composer',
  async ({ page }: { page: Page }, _userName: string, message: string) => {
    // Element Web 1.12.15 uses .mx_BasicMessageComposer_input; older versions use the path below
    const composer = page.locator('.mx_BasicMessageComposer_input')
      .or(page.locator('.mx_SendMessageComposer [contenteditable="true"]'))
      .or(page.locator('.mx_RoomView_body .mx_MessageComposer div[contenteditable]'))
      .first();
    await expect(composer).toBeVisible({ timeout: 20_000 });
    await composer.click();
    // pressSequentially triggers proper React synthetic events on contenteditable
    await composer.pressSequentially(message, { delay: 10 });
  }
);

/**
 * "When alex presses Enter"
 */
When('{word} presses Enter', async ({ page }: { page: Page }, _userName: string) => {
  const composer = page.locator('.mx_BasicMessageComposer_input')
    .or(page.locator('.mx_SendMessageComposer [contenteditable="true"]'))
    .or(page.locator('.mx_RoomView_body .mx_MessageComposer div[contenteditable]'))
    .first();
  await composer.press('Enter');
});

/**
 * "When alex sends {string}"
 * Shorthand: type + Enter. Used in receive.feature.
 * F-09: uses pressSequentially() for proper React event dispatch.
 */
When(
  '{word} sends {string}',
  async ({ page }: { page: Page }, _userName: string, message: string) => {
    // Element Web 1.12.15 uses .mx_BasicMessageComposer_input; older versions use the path below
    const composer = page.locator('.mx_BasicMessageComposer_input')
      .or(page.locator('.mx_SendMessageComposer [contenteditable="true"]'))
      .or(page.locator('.mx_RoomView_body .mx_MessageComposer div[contenteditable]'))
      .first();
    await expect(composer).toBeVisible({ timeout: 20_000 });
    await composer.click();
    // pressSequentially triggers proper React synthetic events
    await composer.pressSequentially(message, { delay: 10 });
    await composer.press('Enter');
  }
);

/**
 * "Then the message {string} is visible in the timeline"
 *
 * M-9 fix: after asserting tile visibility, also assert that the "sending"
 * indicator disappears — confirming server delivery, not just local-echo.
 */
Then(
  'the message {string} is visible in the timeline',
  async ({ page }: { page: Page }, message: string) => {
    const tile = page.locator('.mx_EventTile', { hasText: message });
    await expect(tile.first()).toBeVisible({ timeout: 20_000 });

    // Wait for local-echo sending indicator to disappear (message confirmed by server)
    const sending = page.locator('.mx_EventTile.mx_EventTile_sending', { hasText: message });
    await expect(sending).not.toBeVisible({ timeout: 15_000 });
  }
);

/**
 * "Then the message shows no error status"
 */
Then('the message shows no error status', async ({ page }: { page: Page }) => {
  const errorStatus = page.locator('.mx_EventTile_failed, .mx_EventTile_sending_error');
  await expect(errorStatus).not.toBeVisible({ timeout: 5_000 });
});

// ─────────────────────────────────────────────────────────────────────────────
// AC11: Message Receive Steps (multi-context)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Given marie is logged in via Element Web in a second browser context"
 *
 * Opens Element Web in the secondPage fixture (backed by secondContext/marie).
 * F-01 fix: uses secondPage fixture instead of module-level context variable.
 * M-7 fix:  guards against non-marie users — secondContext is marie-only.
 * m-13 fix: removed redundant ensureStorageState call (secondContext fixture already warmed it).
 */
Given(
  '{word} is logged in via Element Web in a second browser context',
  async (
    { secondPage }: { secondPage: Page },
    userName: string
  ) => {
    // M-7: secondContext is pre-configured for marie only
    if (userName !== 'marie') {
      throw new Error(
        `"${userName} is logged in via Element Web in a second browser context": ` +
        `the secondPage fixture is pre-configured for 'marie'. ` +
        `To use a different second user, add a new fixture to nebu-fixtures.ts.`
      );
    }

    // m-13: secondContext fixture already warmed the storageState — no ensureStorageState call needed

    await secondPage.goto(process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070');

    // Dismiss key dialog if it appears
    await Promise.race([
      secondPage.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 25_000 }),
      secondPage.getByRole('button', { name: /cancel|abbrechen/i })
        .waitFor({ state: 'visible', timeout: 25_000 }),
    ]).catch((e: Error) => { if (!e.message?.includes('Timeout')) throw e; });

    const cancelBtn = secondPage.getByRole('button', { name: /cancel|abbrechen/i });
    if (await cancelBtn.isVisible({ timeout: 1_000 }).catch(() => false)) {
      await cancelBtn.click();
    }

    await secondPage.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 20_000 });
  }
);

/**
 * "Then marie sees {string} in her timeline for {string}"
 *
 * F-01 fix: uses secondPage fixture (same Page object from the Given step above).
 * No manual cleanup needed: secondContext fixture tears it down after the test.
 * M-1: resolves actualRoomName from the template name for sidebar lookup.
 *
 * Navigation strategy (sync-deterministic):
 *   Server-side delivery is proven correct — the message is persisted and marie is a
 *   joined member, so her /sync returns it in the room's joined-timeline. The previous
 *   roomId direct-URL navigation was the flaky part: when marie's /sync hasn't yet
 *   placed the room in her client store, Element falls back to resolving the *alias*
 *   (#msg-recv-template…:localhost → 404 directory lookup) and renders
 *   "room does not exist". A reload of the same roomId URL re-hits that same race.
 *
 *   Instead we wait for the room to appear in marie's *synced* sidebar (the entry only
 *   exists once /sync has delivered the membership) and click it — exactly how Element
 *   navigates internally, which never degrades to an alias lookup.
 */
Then(
  '{word} sees {string} in her timeline for {string}',
  async (
    { secondPage }: { secondPage: Page },
    _userName: string,
    message: string,
    roomName: string
  ) => {
    const known = roomIdByScenario.get(roomName);
    if (!known) {
      throw new Error(`Room "${roomName}" not in roomIdByScenario — Background setup must run first`);
    }
    const actualName = getActualRoomName(roomName);

    // Open the room from marie's synced sidebar. The sidebar entry only renders once
    // /sync has delivered her membership, so its presence is the signal that the room
    // (and its joined-timeline, including alex's message) is in her client store —
    // unlike a roomId direct-URL, which races sync and can 404 via the alias path.
    const sidebarEntry = secondPage.locator(
      `[aria-label="Open room ${actualName}"], [aria-label="Open room ${actualName} invitation."]`
    );

    const openRoom = async () => {
      await sidebarEntry.first().waitFor({ state: 'visible', timeout: 60_000 });
      await sidebarEntry.first().scrollIntoViewIfNeeded().catch(() => {});
      await sidebarEntry.first().click();
      await dismissKeySetupDialog(secondPage);

      // If the room opens on a pending invite, accept it to reveal the timeline.
      const acceptBtn = secondPage.getByRole('button', { name: /^accept$|^join the discussion$/i });
      if (await acceptBtn.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
        await acceptBtn.first().click();
      }
      await secondPage.locator('.mx_RoomView_body').first()
        .waitFor({ state: 'visible', timeout: 20_000 }).catch(() => {});
    };

    await openRoom();

    // Assert alex's message is in marie's timeline. If it hasn't rendered yet, re-open
    // the room from the sidebar once more (re-triggers Element's room load against the
    // already-synced store) — no alias-resolving reload.
    const tile = secondPage.locator('.mx_EventTile', { hasText: message });
    if (!(await tile.first().isVisible({ timeout: 20_000 }).catch(() => false))) {
      await openRoom();
      await expect(tile.first()).toBeVisible({ timeout: 20_000 });
    }
  }
);
