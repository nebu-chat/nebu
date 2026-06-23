/**
 * ElementAppPage — Page Object for the Element Web client.
 *
 * Story 9-26 — Phase 1, AC2.
 * Adapted from element-web/apps/web/playwright/pages/ElementAppPage.ts.
 * Trimmed for Nebu MVP: removes crypto, Spotlight, E2EE-specific helpers.
 *
 * Retains: getComposerField, openCreateRoomDialog, viewRoomByName,
 *          viewRoomById, inviteUserToCurrentRoom, openUserMenu, closeDialog.
 */

import { type Page, type Locator, expect } from '@playwright/test';

export class ElementAppPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  /**
   * Wait for the main room list panel to become visible.
   * Selector: .mx_LeftPanel
   */
  async waitForRoomList(): Promise<void> {
    await this.page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 20_000 });
  }

  /**
   * Open the "Create room" dialog.
   *
   * Element Web 1.12.15: navigating to /#/new opens the "New conversation" / start-DM
   * flow, which has NO room-name field and creates an unnamed "Empty room". The correct
   * path (per story 9-26) is via the Room list:
   *   navigation[name="Room list"] → "New conversation" (add/plus) button
   *   → "New room" menu item → real Create Room dialog (with the room-name field).
   *
   * Fallback for older versions: an "Add room" / "Create room" button in the left panel.
   */
  async openCreateRoomDialog(): Promise<void> {
    // Make sure the room list is rendered before reaching for its controls.
    await this.waitForRoomList().catch(() => {});

    // Primary (Element Web 1.12.15+): the "New conversation" add button in the Room list nav.
    const roomListNav = this.page.getByRole('navigation', { name: /room list/i });
    const newConversationBtn = roomListNav.getByRole('button', { name: /new conversation/i })
      .or(this.page.getByRole('button', { name: /new conversation/i }))
      .or(this.page.locator('.mx_RoomListHeader_auxButton'));

    if (await newConversationBtn.first().isVisible({ timeout: 8_000 }).catch(() => false)) {
      await newConversationBtn.first().click();

      // The menu opens — choose "New room" (NOT "New message"/DM which has no name field).
      const newRoomItem = this.page.getByRole('menuitem', { name: /new room|create.*room/i })
        .or(this.page.getByRole('option', { name: /new room|create.*room/i }));
      if (await newRoomItem.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
        await newRoomItem.first().click();
      }
    } else {
      // Fallback for older versions: "Add room" / "Create room" button in the left panel header.
      const addRoomBtn = this.page.getByRole('button', { name: /add room|new room|create.*room|plus/i })
        .or(this.page.locator('.mx_RoomListHeader_auxButton'))
        .first();

      if (await addRoomBtn.isVisible({ timeout: 5_000 }).catch(() => false)) {
        await addRoomBtn.click();
        // A context menu may appear — click "New room" / "Create new room".
        const createItem = this.page.getByRole('menuitem', { name: /new room|create.*room/i })
          .or(this.page.getByRole('option', { name: /new room|create.*room/i }));
        if (await createItem.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
          await createItem.first().click();
        }
      }
    }

    // Wait for the real Create Room dialog (carries the room-name field).
    await this.page.locator('.mx_CreateRoomDialog, [role="dialog"]:has(input[placeholder="Name"])').first()
      .waitFor({ state: 'visible', timeout: 10_000 });
  }

  /**
   * Navigate to a room by its display name in the sidebar.
   * Tries multiple selector strategies for robustness across Element versions.
   *
   * Element Web 1.12.15 change: Room tiles use aria-label="Open room {name}" buttons
   * (no title attribute, no .mx_RoomTile class).
   */
  async viewRoomByName(name: string): Promise<void> {
    // Strategy 1 (Element Web 1.12.15+): aria-label="Open room {name}" (joined) OR
    // aria-label="Open room {name} invitation." (pending invite)
    const byAriaLabel = this.page.locator(
      `[aria-label="Open room ${name}"], [aria-label="Open room ${name} invitation."]`
    );

    // Strategy 2 (older versions): title attribute in room list
    const byTitle = this.page.getByTestId('room-list').locator(`[title="${name}"]`);

    // Strategy 3: direct locator on room list items by title/aria-label (even older)
    const byListItem = this.page.locator(`.mx_RoomTile[title="${name}"], .mx_RoomTile[aria-label="${name}"]`);

    let found = false;

    if (await byAriaLabel.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
      await byAriaLabel.first().click();
      found = true;
    }

    if (!found && await byTitle.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
      await byTitle.first().click();
      found = true;
    }

    if (!found && await byListItem.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
      await byListItem.first().click();
      found = true;
    }

    if (!found) {
      // Fallback: look for any element containing the room name in the left panel
      const fallback = this.page.locator('.mx_LeftPanel').getByText(name, { exact: true })
        .or(this.page.locator('.mx_LeftPanel').getByTitle(name));
      await expect(fallback.first()).toBeVisible({ timeout: 20_000 });
      await fallback.first().click();
    }
  }

  /**
   * Navigate to a room by its Matrix room_id.
   * Constructs the Element Web URL hash route.
   */
  async viewRoomById(roomId: string): Promise<void> {
    await this.page.goto(`/#/room/${roomId}`);
    await this.page.locator('.mx_RoomView_body').waitFor({ state: 'visible', timeout: 20_000 });
  }

  /**
   * Get the message composer input field (contenteditable div).
   *
   * Element Web 1.12.15 uses .mx_BasicMessageComposer_input as the contenteditable element.
   * Fallback selectors for older versions are chained via .or().
   */
  getComposerField(): Locator {
    // Primary: Element Web 1.12.15 class
    return this.page.locator('.mx_BasicMessageComposer_input')
      // Fallback 1: generic role=textbox in the message composer area
      .or(this.page.locator('.mx_SendMessageComposer [contenteditable="true"]'))
      // Fallback 2: older versions
      .or(this.page.locator('.mx_RoomView_body .mx_MessageComposer div[contenteditable]'));
  }

  /**
   * Open the user menu (avatar / display name in the top-left corner).
   * Clicks the user avatar button to reveal the menu.
   */
  async openUserMenu(): Promise<void> {
    // Element renders user info in top-left: either a button with the username or avatar
    const userBtn = this.page.locator('.mx_UserMenu button, [aria-label*="User menu"], [data-testid="user-menu-trigger"]')
      .or(this.page.locator('.mx_LeftPanel .mx_UserMenu'));

    await userBtn.first().waitFor({ state: 'visible', timeout: 10_000 });
    await userBtn.first().click();
  }

  /**
   * Close any open dialog (e.g. after room creation).
   * Presses Escape or clicks the Close button.
   */
  async closeDialog(): Promise<void> {
    // Deliberate fallback chain: mx_Dialog_cancelButton was renamed in Element Web v1.11+.
    // Escape key is the last resort if neither selector matches.
    const closeBtn = this.page.locator('.mx_Dialog .mx_Dialog_cancelButton, .mx_Dialog button[aria-label="Close"]');
    if (await closeBtn.first().isVisible({ timeout: 2_000 }).catch(() => false)) {
      await closeBtn.first().click();
    } else {
      await this.page.keyboard.press('Escape');
    }
  }

  /**
   * Invite a user to the current room via the room's member panel.
   * Opens the invite dialog and submits with the given Matrix user ID.
   */
  async inviteUserToCurrentRoom(userId: string): Promise<void> {
    // Open room info / member list
    const inviteBtn = this.page.getByRole('button', { name: /invite/i });
    await inviteBtn.waitFor({ state: 'visible', timeout: 10_000 });
    await inviteBtn.click();

    // Fill the invite input
    const input = this.page.locator('.mx_InviteDialog input[type="text"], .mx_InviteDialog input[placeholder]');
    await input.waitFor({ state: 'visible', timeout: 10_000 });
    await input.fill(userId);

    // Confirm invitation
    await this.page.getByRole('button', { name: /invite|send invitation/i }).last().click();
  }
}
