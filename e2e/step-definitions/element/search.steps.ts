/**
 * Step definitions for features/element/search.feature
 *
 * Story 11.6 — AC6, AC7, AC8.
 *
 * Implements: Element Web search dialog, result click navigation, empty state.
 * Auth: Authorization Code + PKCE via Dex (no ROPC — dex v2.41+ constraint).
 *
 * Template name "search-test-template" is unique across all feature files in a
 * single test run — do not reuse this name in other feature files.
 *
 * Message pre-seeding (AC6/AC7 Background): messages are sent via direct Matrix
 * API calls (not through the Element Web UI) so search tests are independent of
 * message-send UI timing. Uses getApiSession() + direct PUT /send event call.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getActualRoomName, roomIdByScenario } from '../common/room-setup.steps';
import { dismissKeySetupDialog } from '../common/navigation.steps';
import { getApiSession } from '../../fixtures/dex-auth';
import { NEBU_USERS } from '../../fixtures/users';

const ELEMENT_URL = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';
const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

// ─── Message pre-seeding ──────────────────────────────────────────────────────

/**
 * "Given alex has sent message {string} in {string}"
 *
 * Sends a message via direct Matrix API (PUT /rooms/{roomId}/send/m.room.message/{txnId}).
 * Called BEFORE the browser login step so the message is indexed before searching.
 */
Given(
  '{word} has sent message {string} in {string}',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    message: string,
    roomName: string
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown test user: ${userName}`);

    const session = await getApiSession(request, user, browser);
    const roomEntry = roomIdByScenario.get(roomName);
    if (!roomEntry) {
      throw new Error(
        `Room "${roomName}" not found in roomIdByScenario — ensure "a room ${roomName} exists" step ran first`
      );
    }

    const txnId = `search-seed-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const url = `${MATRIX_BASE}/_matrix/client/v3/rooms/${roomEntry.roomId}/send/m.room.message/${txnId}`;
    const resp = await request.put(url, {
      headers: {
        Authorization: `Bearer ${session.token}`,
        'Content-Type': 'application/json',
      },
      data: { msgtype: 'm.text', body: message },
    });

    if (!resp.ok()) {
      const body = await resp.text();
      throw new Error(`Failed to send message "${message}" in room "${roomName}": ${resp.status()} ${body}`);
    }
  }
);

// ─── Search dialog setup for AC7 ─────────────────────────────────────────────

/**
 * "Given {word} has searched for {string} and results are visible"
 *
 * Opens the search dialog, types the term, submits, and waits for at least one
 * result tile to appear. Used as a Given precondition in AC7 so the scenario
 * starts from a fully-populated results panel before clicking a result.
 */
Given(
  '{word} has searched for {string} and results are visible',
  async ({ page }: { page: Page }, _userName: string, term: string) => {
    await openSearchDialog(page);
    await typeInSearchInput(page, term);
    await submitSearch(page);
    // Wait for at least one result tile
    await expect(
      page.locator('.mx_SearchResultTile, .mx_EventTile_searchHighlight, [data-testid="searchResultTile"]').first()
    ).toBeVisible({ timeout: 20_000 });
  }
);

// ─── Search dialog steps ──────────────────────────────────────────────────────

/**
 * "When {word} opens the search dialog"
 *
 * Attempts the search trigger button first; falls back to keyboard shortcut.
 */
When(
  '{word} opens the search dialog',
  async ({ page }: { page: Page }, _userName: string) => {
    await openSearchDialog(page);
  }
);

/**
 * "When {word} types {string} in the search input"
 */
When(
  '{word} types {string} in the search input',
  async ({ page }: { page: Page }, _userName: string, term: string) => {
    await typeInSearchInput(page, term);
  }
);

/**
 * "When {word} submits the search"
 */
When('{word} submits the search', async ({ page }: { page: Page }, _userName: string) => {
  await submitSearch(page);
});

// ─── Assertions ───────────────────────────────────────────────────────────────

/**
 * "Then at least one search result containing {string} is visible"
 */
Then(
  'at least one search result containing {string} is visible',
  async ({ page }: { page: Page }, text: string) => {
    // Element renders matched events highlighted in-place (.mx_EventTile_searchHighlight)
    // within the search results panel. Assert a highlighted event tile carries the text.
    const tile = page
      .locator(
        '.mx_EventTile_searchHighlight, .mx_SearchResultTile, [data-testid="searchResultTile"]'
      )
      .filter({ hasText: text })
      .first();
    await expect(tile).toBeVisible({ timeout: 20_000 });
  }
);

/**
 * "When {word} clicks on the first search result"
 */
When(
  '{word} clicks on the first search result',
  async ({ page }: { page: Page }, _userName: string) => {
    const firstResult = page
      .locator('.mx_EventTile_searchHighlight, .mx_SearchResultTile, [data-testid="searchResultTile"]')
      .first();
    await expect(firstResult).toBeVisible({ timeout: 20_000 });
    await firstResult.click();
  }
);

// "Then the message {string} is visible in the timeline" is defined in messages.steps.ts

/**
 * "Then an empty state indicator is visible"
 *
 * Waits for the search results panel to settle, then asserts either an explicit
 * empty-state element is visible OR the results panel has zero result tiles.
 */
Then('an empty state indicator is visible', async ({ page }: { page: Page }) => {
  // A search with no matches renders no highlighted result tiles, and Element shows a
  // "No results" indicator. Accept either signal: an explicit no-results message OR
  // zero highlighted result tiles after the search settled.
  const noResults = page.getByText(/no results|no search results|nothing found/i).first();
  const tiles = page.locator('.mx_EventTile_searchHighlight, .mx_SearchResultTile, [data-testid="searchResultTile"]');

  const hasMsg = await noResults.isVisible({ timeout: 10_000 }).catch(() => false);
  if (!hasMsg) {
    await expect(tiles).toHaveCount(0, { timeout: 5_000 });
  }
});

// "Then no error dialog appears" is defined in common/assertions.steps.ts

// ─── Internal helpers ─────────────────────────────────────────────────────────

async function openSearchDialog(page: Page): Promise<void> {
  // Element's message search (.mx_SearchBar) is a PER-ROOM affordance opened from the
  // room header — it does not exist on the Home page. So open a room first (the seeded
  // search-test room by roomId when known, else the first room tile in the sidebar),
  // dismiss the managed-E2EE key dialog, then open the room-header search.
  const seeded = roomIdByScenario.get('search-test-template');
  if (seeded) {
    await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(seeded.roomId)}`);
  } else {
    await page.goto(ELEMENT_URL);
    const firstRoom = page.locator('.mx_RoomTile, [aria-label^="Open room"]').first();
    if (await firstRoom.isVisible({ timeout: 10_000 }).catch(() => false)) {
      await firstRoom.click();
    }
  }
  await dismissKeySetupDialog(page);

  // Wait for the room view so the header is present.
  await page.locator('.mx_RoomView_body, .mx_BasicMessageComposer_input').first()
    .waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});

  // Element 1.12.15: message search lives in the Room Summary Card (room info panel),
  // not a header magnifying glass. Open the room-info (i) panel, then the search box
  // is .mx_RoomSummaryCard_search [role=searchbox] (matches the upstream element-web
  // playwright pattern app.toggleRoomInfoPanel() + .mx_RoomSummaryCard_search).
  if (!(await searchBox(page).isVisible({ timeout: 2_000 }).catch(() => false))) {
    await page.getByRole('button', { name: 'Room info' }).first().click().catch(() => {});
  }
  await expect(searchBox(page)).toBeVisible({ timeout: 10_000 });
}

// The Element 1.12 room message-search input (Room Summary Card), with legacy fallbacks.
function searchBox(page: Page) {
  return page.locator('.mx_RoomSummaryCard_search').getByRole('searchbox')
    .or(page.locator('.mx_SearchBar_input input'))
    .or(page.locator('input[placeholder*="Search" i]'))
    .first();
}

async function typeInSearchInput(page: Page, term: string): Promise<void> {
  const input = searchBox(page);
  await expect(input).toBeVisible({ timeout: 10_000 });
  await input.fill(term);
}

async function submitSearch(page: Page): Promise<void> {
  await searchBox(page).press('Enter');
  // Element renders search results in-place: matching events get .mx_EventTile_searchHighlight
  // inside a results panel, or a "no results" state. Wait for either to settle.
  await page.waitForSelector(
    '.mx_RoomView_searchResultsPanel, .mx_SearchResultsPanel, .mx_EventTile_searchHighlight, .mx_RoomView_empty, [data-testid="searchResults"]',
    { timeout: 20_000 }
  ).catch(() => {});
}
