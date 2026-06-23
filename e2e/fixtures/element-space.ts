/**
 * ElementSpacePage — Page Object for the Element Web Spaces UI.
 *
 * Drives the GENUINE owner "create a room inside a Space" flow exactly as a real
 * user does it in Element Web. Selectors are aligned with the upstream Element
 * Web Playwright suite (apps/web/playwright/e2e/spaces/spaces.spec.ts) and verified
 * against the running nebu-element image:
 *
 *   - Create space:  getByRole("button", {name:"Create a space"})
 *                    → .mx_SpaceCreateMenu_wrapper .mx_ContextualMenu
 *                    → "Private" → textbox "Name" → "Create" → "Just me"
 *   - Space panel:   .mx_SpacePanel .mx_SpaceButton[aria-label="<space name>"]
 *   - In-space new room (the path that sets parentSpace, i.e. createRoom.ts +
 *     SpaceStore.addRoomToSpace): with the space ACTIVE, the room-list header
 *     "Add" button → menuitem "New room" → CreateRoomDialog.
 *   - Space landing list: .mx_SpaceRoomView_landing / .mx_SpaceHierarchy_list
 *
 * IMPORTANT (regression integrity): this page object issues ONLY the calls the
 * Element client itself makes. It NEVER issues a compensating server-side
 * m.space.child / m.space.parent write. The link between the room and the Space
 * must be established by the server honouring what Element sends — that is the
 * behaviour under test.
 */

import { type Page, type Locator, expect } from '@playwright/test';

export class ElementSpacePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  /**
   * Dismiss transient post-login overlays that obscure the Spaces UI.
   *
   * Idempotent and absence-safe: every interaction is guarded by a short
   * isVisible() probe so this is a no-op when no overlay is present (no hard
   * sleeps). Shared by every Element UI flow that needs a clear viewport.
   *
   * The device-verification modal is handled FIRST and explicitly. Current
   * Element Web builds render a "Verify this device" modal (role="alert",
   * heading "Verify this device", body "…unverified devices will not be able to
   * send and receive messages.") on top of the app after a fresh OIDC login.
   * Its dismiss control is the "Later" button — NOT "Continue", which would
   * START device verification. We must never click "Continue" here, so the
   * generic dismiss regex below deliberately excludes it.
   */
  private async dismissTransientDialogs(): Promise<void> {
    await this.dismissVerifyDeviceModal();

    // Generic one-off setup/welcome dialogs ("What's new", key backup nudges, …).
    // NOTE: intentionally NO "continue" here — on the verify-device modal that is
    // the affirmative (start-verification) action, the opposite of dismissing.
    await this.page
      .getByRole('button', { name: /^(not now|dismiss|skip( for now)?|got it|later|maybe later|close)$/i })
      .first()
      .click({ timeout: 3_000 })
      .catch(() => {});
  }

  /**
   * Dismiss the "Verify this device" / device-verification modal if present.
   *
   * Scopes the dismiss to the modal itself (located by its heading text) so the
   * "Later" button can't be confused with any other control, and guards on
   * visibility so it is a safe no-op when the modal is absent.
   */
  private async dismissVerifyDeviceModal(): Promise<void> {
    // Scope to the modal container by its (version-stable) heading text.
    const modal = this.page
      .locator('.mx_Dialog, [role="dialog"], [role="alert"]')
      .filter({ hasText: /verify this device|confirm your (digital )?identity|verify your identity/i })
      .first();

    if (!(await modal.isVisible({ timeout: 2_000 }).catch(() => false))) {
      return;
    }

    // Preferred dismiss affordances, in order. "Later" is what THIS build renders;
    // the others cover sibling variants ("I'll verify later", "Skip", "Can't confirm?").
    const dismiss = modal
      .getByRole('button', { name: /^later$/i })
      .or(modal.getByRole('button', { name: /i'?ll verify later|verify later|skip|not now|can'?t confirm|do this later/i }))
      .or(modal.getByRole('button', { name: /^(close|dismiss)$/i }));

    if (await dismiss.first().isVisible({ timeout: 2_000 }).catch(() => false)) {
      await dismiss.first().click({ timeout: 3_000 }).catch(() => {});
    } else {
      // Last-resort dismissal: the modal close (X) affordance, else Escape.
      const closeX = modal.locator('[aria-label="Close"], .mx_Dialog_cancelButton').first();
      if (await closeX.isVisible({ timeout: 1_000 }).catch(() => false)) {
        await closeX.click({ timeout: 2_000 }).catch(() => {});
      } else {
        await this.page.keyboard.press('Escape').catch(() => {});
      }
    }

    // Confirm it's gone (best-effort) so subsequent clicks aren't intercepted.
    await modal.waitFor({ state: 'hidden', timeout: 5_000 }).catch(() => {});
  }

  /**
   * Click a target, retrying once after re-dismissing transient overlays if the
   * first attempt is intercepted/obscured (e.g. the verify-device modal mounting
   * a beat late). Uses short timeouts; no hard sleeps.
   */
  private async clickWithDialogDismissal(target: Locator): Promise<void> {
    try {
      await target.click({ timeout: 8_000 });
    } catch {
      await this.dismissTransientDialogs();
      await target.click({ timeout: 12_000 });
    }
  }

  /**
   * Create a private Space via the real Element UI and return its room id.
   * Mirrors the upstream spaces.spec.ts "create private space" flow.
   */
  async createPrivateSpace(spaceName: string): Promise<string> {
    await this.page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});
    await this.dismissTransientDialogs();

    // The verify-device modal can mount a beat AFTER the LeftPanel; dismiss again
    // immediately before reaching for the (otherwise obscured) Create-a-space button.
    await this.clickWithDialogDismissal(
      this.page.getByRole('button', { name: 'Create a space' }),
    );
    const menu = this.page.locator('.mx_SpaceCreateMenu_wrapper .mx_ContextualMenu');
    await menu.waitFor({ state: 'visible', timeout: 15_000 });
    await menu.getByRole('button', { name: /Private/ }).click();
    await menu.getByRole('textbox', { name: 'Name' }).fill(spaceName);
    await menu.getByRole('button', { name: 'Create' }).click();

    // "Who are you working with?" → Just me (avoid auto-created sample rooms).
    await this.page.getByRole('button', { name: /Just me/i }).click({ timeout: 15_000 }).catch(() => {});
    await this.dismissTransientDialogs();

    // Element navigates into the new Space landing view; the id is in the URL.
    await this.page.waitForTimeout(2_000);
    const spaceId = this.spaceIdFromUrl();
    if (!spaceId) {
      throw new Error('[ElementSpacePage] could not read created Space id from URL after create.');
    }

    // The new Space surfaces in the SpacePanel after a full initial sync; a reload
    // is the deterministic way to wait for it (the SpacePanel updates lazily).
    await this.page.reload();
    await this.page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});
    await this.dismissTransientDialogs();
    await this.spaceButton(spaceName).waitFor({ state: 'visible', timeout: 30_000 });

    return spaceId;
  }

  /** Make a Space the active space by clicking it in the SpacePanel. */
  async selectSpace(spaceName: string): Promise<void> {
    await this.dismissTransientDialogs();
    await this.clickWithDialogDismissal(this.spaceButton(spaceName));
    await this.page.locator('.mx_SpaceRoomView, .mx_SpaceRoomView_landing').first()
      .waitFor({ state: 'visible', timeout: 20_000 }).catch(() => {});
    await this.page.waitForTimeout(1_000);
  }

  /**
   * Create a NEW room inside the currently-active Space via the genuine UI path:
   * room-list header "Add" → "New room" → CreateRoomDialog. This triggers
   * createRoom.ts with `parentSpace` set (m.space.parent in createRoom's
   * initial_state) AND SpaceStore.addRoomToSpace (the m.space.child PUT). No
   * server-side writes are forged by the test. Returns the created room id (Element
   * navigates into the new room, so its id is in the URL).
   */
  async createRoomInActiveSpace(roomName: string): Promise<string> {
    await this.dismissTransientDialogs();
    const addBtn = this.page.getByRole('button', { name: /^Add$/ });
    await addBtn.first().waitFor({ state: 'visible', timeout: 20_000 });
    await this.clickWithDialogDismissal(addBtn.first());

    await this.page.getByRole('menuitem', { name: /^New room$/i }).click({ timeout: 8_000 });

    const dialog = this.page.locator('.mx_CreateRoomDialog, [role="dialog"]').first();
    await dialog.waitFor({ state: 'visible', timeout: 15_000 });
    await dialog.getByRole('textbox', { name: /name/i }).first().fill(roomName);
    await dialog.getByRole('button', { name: /Create room|Create/i }).first().click({ timeout: 8_000 });

    // Element navigates into the new room — wait for the URL to change to a room id
    // that is NOT the active Space, then read it.
    await this.page.waitForTimeout(6_000);
    const roomId = this.spaceIdFromUrl();
    if (!roomId) {
      throw new Error('[ElementSpacePage] could not read created room id from URL.');
    }
    return roomId;
  }

  /** Open the Space landing view (which renders the Space's child-room list). */
  async openSpaceLanding(spaceName: string): Promise<void> {
    await this.selectSpace(spaceName);
    await this.page.locator('.mx_SpaceRoomView_landing, .mx_SpaceRoomView').first()
      .waitFor({ state: 'visible', timeout: 20_000 });
  }

  /**
   * Assert a room appears under the Space in the landing view's child list.
   * The room must be listed there — NOT only in the personal/home room list.
   */
  async expectRoomUnderSpace(roomName: string): Promise<void> {
    const landing = this.page.locator('.mx_SpaceRoomView_landing, .mx_SpaceRoomView');
    const list = landing.locator('.mx_SpaceHierarchy_list').or(landing);
    const item = list
      .getByRole('treeitem', { name: new RegExp(roomName, 'i') })
      .or(list.getByText(new RegExp(roomName, 'i')));

    await expect(
      item.first(),
      `Expected room "${roomName}" to appear under the Space in Element Web's Space ` +
      `landing view. RED while createRoom drops initial_state: the room created inside ` +
      `the Space lands only in the home/personal list, never under the Space.`,
    ).toBeVisible({ timeout: 20_000 });
  }

  private spaceButton(spaceName: string): Locator {
    return this.page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label="${spaceName}"]`);
  }

  private spaceIdFromUrl(): string | null {
    const m = this.page.url().match(/#\/room\/([^?]+)/);
    return m ? decodeURIComponent(m[1]) : null;
  }
}
