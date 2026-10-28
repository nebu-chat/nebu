/**
 * Step definitions for features/element/room/{create,join,leave,upgrade}.feature
 *
 * Story 9-26 — Phase 2, AC7 + AC8 + AC9.
 * Story 9-26a — M-1 fix: use getActualRoomName() for sidebar/header assertions.
 * Story 9-27 — AC6: Room upgrade E2E test steps.
 * F-08 fix: replaced fragile `input[id="textinput_0"]` with getByLabel(/room name/i)
 *           or getByRole('textbox', { name: /name/i }).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { ElementAppPage } from '../../fixtures/element-app';
import { getActualRoomName, roomIdByScenario } from '../common/room-setup.steps';
import { dismissKeySetupDialog } from '../common/navigation.steps';
import { getApiSession, createRoom, inviteUser, joinRoom } from '../../fixtures/dex-auth';
import { NEBU_USERS } from '../../fixtures/users';
import type { APIRequestContext, Browser } from '@playwright/test';

const ELEMENT_URL_ROOM = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';
const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

// ─────────────────────────────────────────────────────────────────────────────
// AC7: Room Creation Steps
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When alex opens the {string} dialog"
 * Opens the Create Room dialog via ElementAppPage.
 */
When(
  '{word} opens the {string} dialog',
  async ({ page }: { page: Page }, _userName: string, _dialogName: string) => {
    const app = new ElementAppPage(page);
    await app.openCreateRoomDialog();
  }
);

/**
 * "When alex enters room name {string}"
 * F-08: uses getByLabel(/room name/i) or getByRole('textbox', { name: /name/i })
 * instead of the fragile generated ID `textinput_0`.
 */
When(
  '{word} enters room name {string}',
  async ({ page }: { page: Page }, _userName: string, roomName: string) => {
    // Try semantic locators first (robust across Element versions)
    const byLabel = page.locator('.mx_CreateRoomDialog').getByLabel(/room name|name/i);
    const byRole  = page.locator('.mx_CreateRoomDialog').getByRole('textbox', { name: /name/i });

    // Fallback to the input itself inside the dialog
    const byInput = page.locator('.mx_CreateRoomDialog input[type="text"]').first();

    let filled = false;

    if (await byLabel.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
      await byLabel.first().fill(roomName);
      filled = true;
    } else if (await byRole.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
      await byRole.first().fill(roomName);
      filled = true;
    }

    if (!filled) {
      await byInput.waitFor({ state: 'visible', timeout: 10_000 });
      await byInput.fill(roomName);
    }
  }
);

/**
 * "When alex clicks {string}"
 * Generic button click step — reused across create/join/leave/login scenarios.
 *
 * BUG-E2E-13 fix: "Accept" invite in Element Web 1.12.15 may be rendered as
 * "Join the discussion" when the room is empty or can't be previewed.
 * Map "Accept" → try "Accept" first, fall back to "Join the discussion".
 */
When(
  '{word} clicks {string}',
  async ({ page }: { page: Page }, _userName: string, buttonText: string) => {
    // For invite acceptance: "Accept" may appear as "Join the discussion" in Element 1.12+
    const isAccept = /^accept$/i.test(buttonText.trim());
    // Story sync-membership-partition (@ac8-decline-invite): the decline button of the invite preview. The label is UNVERIFIED against
    // Element Web 1.12.15 (the chunk with the preview bar was not part of the bundle copy that was inspected): Element's i18n has both
    // "Decline" (action|decline) and "Reject" (action|reject); the anchored pattern also keeps "Decline and ignore user" out. Record the
    // verified label after the first real run (fix the SELECTOR, never the assertions of the scenario).
    const isDecline = /^decline$/i.test(buttonText.trim());
    const pattern = isAccept
      ? /^Accept$|Join the discussion/i
      : isDecline
        ? /^Decline$|^Reject$/i
        : new RegExp(buttonText, 'i');
    await page.getByRole('button', { name: pattern }).click({ timeout: 20_000 });
  }
);

/**
 * "Then the room header shows {string}"
 *
 * M-1: resolves the actual (suffixed) room name from the template name.
 */
Then(
  'the room header shows {string}',
  async ({ page }: { page: Page }, roomName: string) => {
    const actualName = getActualRoomName(roomName);
    // Element Web 1.12.15: room name is in a heading inside [aria-label="Room info"] button
    // in the room header. Also try legacy selectors for older versions.
    // BUG-E2E-12 fix: locator().or() can resolve to multiple elements causing strict mode violations.
    // Use the most specific locator first (scoped to room header/header area), fall through to others.
    // Scope [data-testid="room-name"] to main content area (not sidebar) to avoid duplicate matches.
    const headerLocator = page.locator('.mx_RoomHeader [role="heading"], .mx_RoomHeader_name, .mx_LegacyRoomHeader_name')
      .or(page.locator('header [role="heading"]'))
      .or(page.locator('main').locator('[data-testid="room-name"]'));
    await expect(headerLocator.first()).toHaveText(new RegExp(actualName, 'i'), { timeout: 20_000 });
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// AC8: Room Join Steps
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When the invite for {string} appears in {word}'s sidebar"
 *
 * Story sync-membership-partition: the invitation now arrives through `/sync` (`rooms.invite` with a stripped invite_state), so this step
 * WAITS for the real invitation tile of Element's room list instead of navigating to the room-id URL (the workaround of the time before
 * `ev`, when the invitation never arrived). Element Web 1.12.15 shows invitations in the flat room list as [role="option"] buttons with
 * aria-label="Open room {name} invitation." (no separate Invites group).
 *
 * The step opens the tile (the invite preview with its Accept / Decline buttons) and asserts that the preview is shown. The explicit
 * `alex clicks "Accept"` / `alex clicks "Decline"` step that follows performs the choice - clicking here too would double-accept.
 */
When(
  'the invite for {string} appears in {word}\'s sidebar',
  async ({ page }: { page: Page }, roomName: string, _userName: string) => {
    const tile = inviteTile(page, roomName);
    await expect(tile.first(), `the invitation tile of "${getActualRoomName(roomName)}" appears in the room list without any navigation`).toBeVisible({ timeout: 60_000 });
    await tile.first().click();
    await dismissKeySetupDialog(page);

    // The invite preview is open: its Accept affordance is visible (do NOT click it).
    const acceptBtn = page.getByRole('button', { name: /^accept$|^join the discussion$|^join$/i });
    await expect(acceptBtn.first()).toBeVisible({ timeout: 30_000 });
    await dismissKeySetupDialog(page);
  }
);

/** The room-list tile of an invitation to the room (Element Web 1.12.15: aria-label "Open room {name} invitation."). */
function inviteTile(page: Page, roomName: string) {
  const actualName = getActualRoomName(roomName).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.locator('[aria-label^="Open room"][aria-label*="invitation"]').filter({ hasText: new RegExp(actualName, 'i') });
}

/**
 * "Then the invite for {string} disappears from {word}'s sidebar"
 * After the decline the invitation tile leaves the room list (Element moves a room that `rooms.leave` ended out of the list).
 */
Then(
  'the invite for {string} disappears from {word}\'s sidebar',
  async ({ page }: { page: Page }, roomName: string, _userName: string) => {
    await expect(inviteTile(page, roomName), 'the invitation tile is gone after the decline').toHaveCount(0, { timeout: 30_000 });
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// AC8 (decline): server-side evidence of the decline (story sync-membership-partition, @ac8-decline-invite)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Element's own `/sync` responses of the current scenario. A leave is delivered ONCE (in the sync whose window contains it) and the sync token
 * of a user is stored per USER (follow-up `fd`), so an API session of alex cannot replay "an incremental sync from before the decline": the
 * response Element itself received IS the evidence. Recorded from the moment the step runs (module-level state: workers: 1).
 */
type RecordedSync = {
  nextBatch: string;
  rooms: {
    join?: Record<string, unknown>;
    invite?: Record<string, unknown>;
    leave?: Record<string, { timeline?: { events?: Array<{ type?: string; state_key?: string; sender?: string; content?: { membership?: string } }> } }>;
  };
};
const recordedSyncs: RecordedSync[] = [];

/** The control room of the decline scenario: joined by the invitee BEFORE the decline and never written to afterwards (test review m6). */
let controlRoomId = '';

/**
 * "And alex's Element sync responses are recorded"
 * Attaches a response listener to alex's Element page (the page of "alex is logged in via Element Web") and provisions a CONTROL room that
 * alex joins through the API. The control room makes the later incremental-sync check discriminating: an incremental sync after Element
 * delivered the room has NO entry for it (nothing new), while an initial-sync FALLBACK (a stale token) would list it in `rooms.join`.
 */
Given(
  '{word}\'s Element sync responses are recorded',
  async (
    { page, request, browser }: { page: Page; request: APIRequestContext; browser: Browser },
    userName: string,
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown user "${userName}".`);
    recordedSyncs.length = 0;
    page.on('response', async (response) => {
      if (!/\/_matrix\/client\/v3\/sync(\?|$)/.test(response.url())) return;
      try {
        const body = (await response.json()) as { next_batch?: string; rooms?: RecordedSync['rooms'] };
        if (typeof body.next_batch === 'string') recordedSyncs.push({ nextBatch: body.next_batch, rooms: body.rooms ?? {} });
      } catch {
        // an aborted long-poll (navigation, close) has no body: nothing to record
      }
    });

    const kaiSession = await getApiSession(request, NEBU_USERS.kai, browser);
    const { room_id } = await createRoom(request, kaiSession.token, `decline-control-${Date.now()}`);
    await inviteUser(request, kaiSession.token, room_id, user.matrixId);
    const userSession = await getApiSession(request, user, browser);
    await joinRoom(request, userSession.token, room_id);
    controlRoomId = room_id;
  }
);

/**
 * "Then alex's Element received the decline of {string} as a leave"
 * Some recorded /sync response has `rooms.leave.<room>` whose LAST timeline event is alex's own `leave` member event (a decline: sender ==
 * state_key == alex), and the room is not in `rooms.invite` / `rooms.join` of that response.
 */
Then(
  '{word}\'s Element received the decline of {string} as a leave',
  async ({}, userName: string, roomName: string) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown user "${userName}".`);
    const entry = roomIdByScenario.get(roomName);
    if (!entry) throw new Error(`Room "${roomName}" not in roomIdByScenario — the invite setup must run first`);

    await expect
      .poll(
        () => {
          const hit = recordedSyncs.find((sync) => sync.rooms.leave?.[entry.roomId] !== undefined);
          if (!hit) return 'no recorded /sync response carries rooms.leave for the room yet';
          const events = hit.rooms.leave?.[entry.roomId]?.timeline?.events ?? [];
          const last = events[events.length - 1];
          const ok =
            last?.type === 'm.room.member' &&
            last.state_key === user.matrixId &&
            last.sender === user.matrixId &&
            last.content?.membership === 'leave' &&
            hit.rooms.invite?.[entry.roomId] === undefined &&
            hit.rooms.join?.[entry.roomId] === undefined;
          return ok ? 'leave delivered' : `rooms.leave of the room ends with ${JSON.stringify(last)}`;
        },
        { message: 'the decline arrives as rooms.leave ending with the invitee\'s own leave event', timeout: 30_000 },
      )
      .toBe('leave delivered');
  }
);

/**
 * "Then after kai posts a message in {string} alex's next incremental sync has the room in no section"
 * kai posts (a unique body); alex's API session then does an incremental /sync with the NEWEST token Element received (the stored token
 * of alex): the room is in none of join / invite / leave (a left room is neither listed nor woken by the room's new events) and the
 * message text appears nowhere in the response body.
 */
Then(
  'after {word} posts a message in {string} {word}\'s next incremental sync has the room in no section',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    posterName: string,
    roomName: string,
    userName: string,
  ) => {
    const poster = NEBU_USERS[posterName as keyof typeof NEBU_USERS];
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!poster || !user) throw new Error(`Unknown user "${posterName}" / "${userName}".`);
    const entry = roomIdByScenario.get(roomName);
    if (!entry) throw new Error(`Room "${roomName}" not in roomIdByScenario — the invite setup must run first`);
    expect(controlRoomId, 'the control room was provisioned by the recording step').not.toBe('');
    // Element delivered the control room before (its sync responses list it in rooms.join): from then on an INCREMENTAL sync has nothing for it
    await expect
      .poll(() => recordedSyncs.some((sync) => sync.rooms.join?.[controlRoomId] !== undefined), {
        message: 'Element received the control room (the token Element holds is current)',
        timeout: 60_000,
      })
      .toBe(true);
    const since = recordedSyncs[recordedSyncs.length - 1]?.nextBatch;
    expect(since, 'Element received at least one /sync response (the recording step ran)').toBeTruthy();

    const marker = `after-decline-${Date.now()}`;
    const posterSession = await getApiSession(request, poster, browser);
    const sent = await request.put(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(entry.roomId)}/send/m.room.message/${marker}`,
      {
        headers: { Authorization: `Bearer ${posterSession.token}`, 'Content-Type': 'application/json' },
        data: { msgtype: 'm.text', body: marker },
      },
    );
    expect(sent.status(), `${posterName} can post in the room (control)`).toBe(200);

    const session = await getApiSession(request, user, browser);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?since=${encodeURIComponent(since as string)}&timeout=0`, {
      headers: { Authorization: `Bearer ${session.token}` },
    });
    expect(resp.status()).toBe(200);
    const raw = await resp.text();
    const body = JSON.parse(raw) as RecordedSync;
    for (const section of ['join', 'invite', 'leave'] as const) {
      expect(Object.keys(body.rooms?.[section] ?? {}), `the room is not in rooms.${section}`).not.toContain(entry.roomId);
    }
    expect(raw, 'the message of the room appears nowhere in the response').not.toContain(marker);
    // discriminating: a stale token would make the server fall back to an INITIAL sync, which lists every joined room (the control room)
    expect(Object.keys(body.rooms?.join ?? {}), 'the response is an incremental sync (the control room has nothing new)').not.toContain(controlRoomId);
  }
);

/**
 * "Then alex is not a member of {string} on the server"
 * `GET /joined_rooms` is a stub on Nebu: the joined rooms are read from a full /sync (as the DM steps do). Run LAST: a full sync replaces
 * the stored token of the user.
 */
Then(
  '{word} is not a member of {string} on the server',
  async ({ request, browser }: { request: APIRequestContext; browser: Browser }, userName: string, roomName: string) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown user "${userName}".`);
    const entry = roomIdByScenario.get(roomName);
    if (!entry) throw new Error(`Room "${roomName}" not in roomIdByScenario — the invite setup must run first`);

    const session = await getApiSession(request, user, browser);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, { headers: { Authorization: `Bearer ${session.token}` } });
    expect(resp.status()).toBe(200);
    const body = (await resp.json()) as RecordedSync;
    expect(Object.keys(body.rooms?.join ?? {}), 'the declined room is not a joined room').not.toContain(entry.roomId);
    expect(Object.keys(body.rooms?.invite ?? {}), 'the declined invitation is not pending any more').not.toContain(entry.roomId);
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// AC9: Room Leave Steps
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When alex opens the room menu and clicks {string}"
 *
 * Element Web 1.12.15 change: The room header no longer has a "..." / kebab / options button.
 * The room context menu is accessed via right-click on the room tile in the sidebar.
 * The menu has text-based [role="menuitem"] entries including "Leave room".
 *
 * Approach: find the current room's tile in the sidebar via room-setup state, right-click it,
 * then click the matching menuitem.
 */
When(
  '{word} opens the room menu and clicks {string}',
  async ({ page }: { page: Page }, _userName: string, menuItem: string) => {
    // Strategy 1 (Element Web 1.12.15+): right-click the active room tile in sidebar
    // The active tile has the highlighted background; find it via [aria-selected] or the current URL
    const currentUrl = page.url();
    const roomIdMatch = currentUrl.match(/#\/room\/([^/]+)/);

    let contextMenuOpened = false;

    if (roomIdMatch) {
      // Right-click any room tile — the current room is the one we're in
      // Find the tile by looking for the currently selected/focused room tile
      const activeTile = page.locator('[aria-selected="true"][role="option"], .mx_RoomListItemView._selected, button[aria-label*="Open room"]:focus')
        .first();
      const isActive = await activeTile.isVisible({ timeout: 2_000 }).catch(() => false);
      if (isActive) {
        await activeTile.click({ button: 'right' });
        contextMenuOpened = true;
      }
    }

    if (!contextMenuOpened) {
      // Strategy 2: Try the room header "..." / options button (older Element versions)
      const headerMenuBtn = page.locator('.mx_RoomHeader').getByRole('button', {
        name: /options|more options|settings|kebab|\.\.\.|⋮/i,
      });
      const headerBtnVisible = await headerMenuBtn.first().isVisible({ timeout: 3_000 }).catch(() => false);
      if (headerBtnVisible) {
        await headerMenuBtn.first().click();
        contextMenuOpened = true;
      }
    }

    if (!contextMenuOpened) {
      // Strategy 3: right-click the first visible room tile (fallback)
      const firstTile = page.locator('button[aria-label^="Open room"]').first();
      await firstTile.waitFor({ state: 'visible', timeout: 10_000 });
      await firstTile.click({ button: 'right' });
    }

    // Wait for context menu to appear and click the matching item (deterministic — no hard wait)
    // Element 1.12.15 context menu items have no aria-label — match by text content
    const menuItemLocator = page.locator('[role="menuitem"]').filter({ hasText: new RegExp(menuItem, 'i') })
      .or(page.getByRole('menuitem', { name: new RegExp(menuItem, 'i') }));
    await menuItemLocator.first().waitFor({ state: 'visible', timeout: 5_000 });
    await menuItemLocator.first().click();
  }
);

/**
 * "When alex confirms leaving"
 * Confirmation dialog: click the "Leave" button.
 */
When(
  '{word} confirms leaving',
  async ({ page }: { page: Page }, _userName: string) => {
    await page.getByRole('button', { name: /^leave$/i }).click();
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// AC6 (Story 9-27): Room Upgrade via Element Web
//
// Fixed in story 9-27: upgrade_room/2 error handling corrected, archive_room_atomic
// called after tombstone, old room GenServer terminated.
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Given alex has created a room named {string}"
 *
 * Story 9-27 AC6: The named user creates a room via the Matrix API so they are
 * the owner (Power Level 100) — required for the upgrade button to appear in Room Settings.
 * Uses a timestamp suffix for per-run uniqueness (M-1 pattern).
 *
 * The credentials fixture is already bound to alex via the Background step
 * "alex is logged in via Element Web" (credentials = NEBU_USERS.alex).
 */
Given(
  '{word} has created a room named {string}',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    roomName: string
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) {
      throw new Error(`Unknown test user "${userName}". Valid: ${Object.keys(NEBU_USERS).join(', ')}`);
    }

    // M-1: timestamp suffix for per-run uniqueness
    const actualName = `${roomName}-${Date.now()}`;
    const session = await getApiSession(request, user, browser);
    const { room_id } = await createRoom(request, session.token, actualName);

    // Store for subsequent steps (e.g. open Room Settings, navigate to room)
    roomIdByScenario.set(roomName, { roomId: room_id, actualName });
  }
);

/**
 * "When alex opens Room Settings for {string}"
 *
 * Story 9-27 AC6: Navigate to the room in Element Web and open Room Settings.
 * Room Settings contain the "Upgrade to recommended chat version" button.
 *
 * Element Web 1.12.15: Room Settings accessible via:
 *   - The room header info button (cog / info icon) → "Room settings"
 *   - Or right-clicking the room tile and choosing "Settings"
 *
 */
When(
  '{word} opens Room Settings for {string}',
  async ({ page }: { page: Page }, _userName: string, roomName: string) => {
    // Navigate by roomId direct-URL (known from Background) instead of a sidebar lookup
    // by name, which races /sync delivery and is flaky.
    const known = roomIdByScenario.get(roomName);
    if (!known) {
      throw new Error(`Room "${roomName}" not in roomIdByScenario — Background setup must run first`);
    }
    await page.goto(`${ELEMENT_URL_ROOM}/#/room/${encodeURIComponent(known.roomId)}`);
    await dismissKeySetupDialog(page);
    await page.locator('.mx_RoomView_body, .mx_BasicMessageComposer_input').first()
      .waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});

    // Open Room Settings — try the settings/gear button in the room header
    const settingsBtn = page.locator('.mx_RoomHeader').getByRole('button', {
      name: /room info|settings|gear/i,
    }).or(
      page.locator('[aria-label="Room settings"], [aria-label="Open room settings"]')
    ).or(
      page.locator('.mx_RoomHeader [data-testid="base-card-close-button"]')
    );

    // Fallback: three-dot / kebab menu in header
    const kebabBtn = page.locator('.mx_RoomHeader').getByRole('button', {
      name: /more options|options|\.\.\.|⋮/i,
    });

    let opened = false;

    if (await settingsBtn.first().isVisible({ timeout: 5_000 }).catch(() => false)) {
      await settingsBtn.first().click();
      opened = true;
    }

    if (!opened && await kebabBtn.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
      await kebabBtn.first().click();
      // Look for "Settings" in the dropdown
      const settingsItem = page.getByRole('menuitem', { name: /settings/i });
      if (await settingsItem.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
        await settingsItem.first().click();
        opened = true;
      }
    }

    if (!opened) {
      // Last resort: direct URL navigation with ?action=open_room_settings
      const entry = roomIdByScenario.get(roomName);
      if (entry) {
        await page.goto(`/#/room/${entry.roomId}?action=open_room_settings`);
        opened = true;
      }
    }

    if (!opened) {
      throw new Error(`Could not open Room Settings for room "${roomName}" — all selector strategies failed`);
    }

    // Wait for the Room Settings panel/dialog to be visible
    const settingsPanel = page.locator(
      '.mx_RoomSettingsDialog, [aria-label="Room Settings"], ' +
      '[data-testid="room-settings"], .mx_BaseCard[aria-label*="settings" i]'
    );
    await settingsPanel.first().waitFor({ state: 'visible', timeout: 15_000 });
  }
);

/**
 * "When alex upgrades the room to the recommended version"
 *
 * Story 9-27 AC6: Clicks the "Upgrade to recommended chat version" button in
 * Element Web's Room Settings → Advanced tab.
 *
 * Element Web 1.12.15: The upgrade button is in the "Advanced" tab of Room Settings.
 * Clicking it shows a confirmation dialog; confirming triggers POST /upgrade.
 *
 */
When(
  '{word} upgrades the room to the recommended version',
  async ({ page }: { page: Page }, _userName: string) => {
    // Navigate to the Advanced tab in Room Settings (contains the upgrade affordance).
    // Element 1.12.15 renders settings tabs as buttons in .mx_TabbedView_tabLabels.
    const advancedTab = page.getByRole('tab', { name: /advanced/i })
      .or(page.locator('.mx_TabbedView_tabLabel').filter({ hasText: /advanced/i }))
      .or(page.getByText(/^advanced$/i));

    if (await advancedTab.first().isVisible({ timeout: 8_000 }).catch(() => false)) {
      await advancedTab.first().click();
    }

    // The upgrade control. Element 1.12.15: an "Upgrade" button under the room-version
    // section of Advanced. Broaden the matcher (button or generic clickable) and scroll
    // it into view (the Advanced tab is long).
    const upgradeBtn = page.getByRole('button', {
      name: /^upgrade$|upgrade.*room|upgrade.*version|recommended.*version|upgrade this room/i,
    }).or(
      page.locator('.mx_SettingsFlag, .mx_SettingsSubsection').getByText(/upgrade/i)
    ).or(
      page.getByText(/upgrade.*recommended|upgrade this room/i)
    );

    await upgradeBtn.first().scrollIntoViewIfNeeded().catch(() => {});
    await upgradeBtn.first().waitFor({ state: 'visible', timeout: 15_000 });
    await upgradeBtn.first().click();

    // A confirmation dialog appears — scope to dialog to avoid matching the trigger button
    const dialog = page.locator('[role="dialog"], .mx_Dialog, .mx_QuestionDialog').first();
    const confirmBtn = dialog.getByRole('button', {
      name: /upgrade|confirm|yes/i,
    }).first();

    if (await confirmBtn.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await confirmBtn.click();
    }
  }
);

/**
 * "Then alex sees the new room without an error"
 *
 * Story 9-27 AC6: After upgrade, Element Web should redirect the user to the
 * new replacement room. The URL should change to the new room's #/room/{newRoomId}.
 *
 * After story 9-27 fix: server returns 200 and Element Web redirects to the new room.
 */
Then(
  '{word} sees the new room without an error',
  async ({ page }: { page: Page }, _userName: string) => {
    // Capture the URL *before* waiting for navigation so we can assert it changed.
    const urlBefore = page.url();

    // Wait for navigation — Element Web redirects to /#/room/{newRoomId}
    await page.waitForURL(/\/#\/room\//, { timeout: 20_000 }).catch(async () => {
      // Fallback: wait for the room view body to appear
      await page.locator('.mx_RoomView_body').waitFor({ state: 'visible', timeout: 10_000 });
    });

    // Assert: the URL changed to a different room (not still on the pre-upgrade room)
    expect(page.url(), 'Expected Element Web to navigate to the new (replacement) room after upgrade')
      .not.toBe(urlBefore);

    // Assert: the room view is visible
    const roomView = page.locator('.mx_RoomView_body, .mx_MainSplit');
    await expect(roomView.first()).toBeVisible({ timeout: 10_000 });
  }
);

/**
 * "Then alex does not see an error dialog"
 *
 * Story 9-27 AC6: After a successful upgrade, no error toast, snackbar,
 * or modal dialog with an error message should be visible.
 *
 *
 * Checks:
 *   - No .mx_ErrorDialog, .mx_GenericErrorPage, or aria[role=alertdialog]
 *   - No toast/snackbar with "error" or "failed" text
 *   - The upgrade result notification (if any) does NOT contain error language
 */
Then(
  '{word} does not see an error dialog',
  async ({ page }: { page: Page }, _userName: string) => {
    // Assert no error dialog is visible — use Playwright's built-in polling (no hard wait)
    const errorDialog = page.locator(
      '.mx_ErrorDialog, .mx_GenericErrorPage, [role="alertdialog"][aria-label*="error" i]'
    );
    await expect(errorDialog.first(), 'Expected no error dialog after room upgrade')
      .not.toBeVisible({ timeout: 3_000 });

    // Assert no toast/snackbar with error text
    const errorToast = page.locator('[role="alert"], .mx_Toast_title').filter({
      hasText: /error|failed|unable|couldn't|could not/i,
    });
    await expect(errorToast.first(), 'Expected no error toast after room upgrade')
      .not.toBeVisible({ timeout: 3_000 });
  }
);
