/**
 * Step definitions for features/element/spaces/join.feature
 *
 * Story spaces-elixir-s6-element-spaces-e2e — AC2 + AC3 (@ac-spaces-join)
 *
 * Scenarios:
 *   1. Public Space join via Element Web UI → Space appears in sidebar.
 *   2. Space member joins restricted child room via Element Web (MSC3083 member path).
 *   3. Non-member cannot join restricted child room → 403 M_FORBIDDEN (API assertion).
 *      Tagged @pending-feature — may be RED if S4 restricted-join is not deployed.
 *
 * Matrix spec contract:
 *   - Public Space: POST /createRoom with preset:"public_chat" + creation_content.type:"m.space"
 *   - Restricted join (MSC3083): child room m.room.join_rules =
 *       {join_rule:"restricted", allow:[{type:"m.room_membership", room_id:"<spaceId>"}]}
 *   - Member → POST /join/{roomId} → 200
 *   - Non-member → POST /join/{roomId} → 403 M_FORBIDDEN (S4 enforcement)
 *
 * IMPORTANT — shared steps:
 *   "kai has created a Space {string} and alex is a member via the API"  → spaces-common.steps.ts
 *   "the Space {string} appears in alex's Space panel"                   → spaces-common.steps.ts
 *   Do NOT register those Gherkin texts here — playwright-bdd global registry, one registration only.
 *
 * Reuse patterns:
 *   - createSpaceViaApi — from spaces-common.steps.ts (exported helper)
 *   - sharedSpaceByName — from spaces-common.steps.ts (shared Map)
 *   - getApiSession, inviteUser, joinRoom — from fixtures/dex-auth.ts
 *   - NEBU_USERS — from fixtures/users.ts
 *   - Timestamp-suffix: actualName = `${templateName}-${Date.now()}`
 */

import { Given, When, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession, inviteUser, joinRoom } from '../../../fixtures/dex-auth';
import { NEBU_USERS } from '../../../fixtures/users';
import { dismissKeySetupDialog } from '../../common/navigation.steps';
import { sharedSpaceByName, createSpaceViaApi, addSpaceChild } from './spaces-common.steps';

const MATRIX_BASE   = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const ELEMENT_URL   = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';

// ─────────────────────────────────────────────────────────────────────────────
// Module-level cross-step state (safe with workers: 1)
// ─────────────────────────────────────────────────────────────────────────────

type RoomEntry  = { roomId: string; actualName: string };

const roomByName  = new Map<string, RoomEntry>();

// ─────────────────────────────────────────────────────────────────────────────
// Internal API helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Create a room with join_rule:restricted referencing the given spaceId. */
async function createRestrictedRoomViaApi(
  request: APIRequestContext,
  token: string,
  roomName: string,
  spaceId: string,
): Promise<string> {
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      name: roomName,
      preset: 'private_chat',
      visibility: 'private',
      creation_content: { 'm.federate': false },
      initial_state: [
        {
          type: 'm.room.join_rules',
          content: {
            join_rule: 'restricted',
            allow: [{ type: 'm.room_membership', room_id: spaceId }],
          },
        },
      ],
    },
  });
  if (!resp.ok()) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(`[createRestrictedRoomViaApi] ${resp.status()} ${JSON.stringify(body)}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

// addSpaceChild is imported from spaces-common.steps.ts (single shared copy).

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 1 — Public Space join
// ─────────────────────────────────────────────────────────────────────────────

Given(
  'kai has created a public Space {string} via the API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    spaceName: string,
  ) => {
    const session = await getApiSession(request, NEBU_USERS.kai, browser);
    const actualName = `${spaceName}-${Date.now()}`;
    const spaceId = await createSpaceViaApi(request, session.token, actualName, 'public_chat');
    sharedSpaceByName.set(spaceName, { spaceId, actualName });
  },
);

/**
 * "When {word} joins the Space {string} via Element Web"
 *
 * Navigates to the Space's room URL so Element Web presents the join option,
 * then clicks the join/accept button.
 *
 * MINOR-2 fix: use waitFor({state:'visible'}) instead of isVisible() guard so
 * the test fails loudly when no join button appears, rather than silently passing.
 */
When(
  '{word} joins the Space {string} via Element Web',
  async ({ page }: { page: Page }, _userName: string, spaceName: string) => {
    const entry = sharedSpaceByName.get(spaceName);
    if (!entry) throw new Error(`Space "${spaceName}" not set up — run the Given step first.`);

    // Navigate to the Space by roomId direct URL (avoids slow /sync sidebar delivery).
    await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(entry.spaceId)}`);
    await dismissKeySetupDialog(page);

    // Element shows a join preview for public rooms — wait for and click the join button.
    // MINOR-2 fix: waitFor({state:'visible'}) fails loudly if the button is absent,
    // catching wiring bugs instead of silently passing.
    const joinBtn = page.getByRole('button', { name: /^join$|^join the discussion$|^accept$/i });
    await joinBtn.first().waitFor({ state: 'visible', timeout: 10_000 });
    await joinBtn.first().click();

    // Wait for the room/space view body to load (confirming membership).
    await page.locator('.mx_RoomView_body, .mx_SpaceRoomView').first()
      .waitFor({ state: 'visible', timeout: 30_000 });
    await dismissKeySetupDialog(page);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 2 — Restricted join: Space member succeeds (MSC3083)
// NOTE: "kai has created a Space {string} and alex is a member via the API" is
// registered in spaces-common.steps.ts — do NOT duplicate it here.
// ─────────────────────────────────────────────────────────────────────────────

Given(
  'kai has created a child room {string} with restricted join rule referencing the Space',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    roomName: string,
  ) => {
    // Determine which space to reference — use the last entry in the shared Map.
    // In join.feature Scenario 2 and Scenario 3 there is exactly one space per scenario.
    const entries = [...sharedSpaceByName.values()];
    const space = entries[entries.length - 1];
    if (!space) throw new Error('No Space found in sharedSpaceByName — run the Given Space step first.');

    const kaiSession = await getApiSession(request, NEBU_USERS.kai, browser);
    const actualName = `${roomName}-${Date.now()}`;
    const roomId = await createRestrictedRoomViaApi(request, kaiSession.token, actualName, space.spaceId);
    roomByName.set(roomName, { roomId, actualName });

    // Also link via m.space.child so the child appears in the hierarchy.
    await addSpaceChild(request, kaiSession.token, space.spaceId, roomId);
  },
);

/**
 * "When {word} navigates to room {string} via Element Web and joins"
 *
 * Navigates to the room by direct roomId URL and clicks join if presented.
 * For a restricted room, Element Web will show a join preview if the user is a
 * Space member; non-members see an error or are blocked entirely.
 *
 * MINOR-2 fix: use waitFor({state:'visible'}) instead of isVisible() guard.
 */
When(
  '{word} navigates to room {string} via Element Web and joins',
  async ({ page }: { page: Page }, _userName: string, roomName: string) => {
    const entry = roomByName.get(roomName);
    if (!entry) throw new Error(`Room "${roomName}" not set up — run the Given step first.`);

    await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(entry.roomId)}`);
    await dismissKeySetupDialog(page);

    // MINOR-2 fix: waitFor({state:'visible'}) ensures the join button is actually present.
    const joinBtn = page.getByRole('button', { name: /^join$|^join the discussion$|^accept$/i });
    await joinBtn.first().waitFor({ state: 'visible', timeout: 10_000 });
    await joinBtn.first().click();

    await page.locator('.mx_RoomView_body, .mx_BasicMessageComposer_input').first()
      .waitFor({ state: 'visible', timeout: 30_000 });
    await dismissKeySetupDialog(page);
  },
);

/**
 * "Then the room {string} appears in alex's room list"
 *
 * Asserts the room tile is visible in the Element Web sidebar / room list.
 * Uses the actual (suffixed) name stored in roomByName.
 */
Then(
  'the room {string} appears in alex\'s room list',
  async ({ page }: { page: Page }, roomName: string) => {
    const entry = roomByName.get(roomName);
    const actualName = entry?.actualName ?? roomName;

    // Element Web 1.12.15+: room tiles use aria-label="Open room {name}"
    const byAriaLabel = page.locator(`[aria-label="Open room ${actualName}"]`);
    // Reload-retry: newly joined rooms may not appear in the initial sync immediately.
    let found = await byAriaLabel.first().waitFor({ state: 'attached', timeout: 20_000 })
      .then(() => true).catch(() => false);

    if (!found) {
      await page.reload();
      await dismissKeySetupDialog(page);
      await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 20_000 }).catch(() => {});
      found = await byAriaLabel.first().waitFor({ state: 'attached', timeout: 20_000 })
        .then(() => true).catch(() => false);
    }

    expect(
      found,
      `Room "${actualName}" should appear in the sidebar after a restricted join. ` +
      `If this fails for a non-member (marie), check that S4 restricted join is enforced. ` +
      `For a Space member (alex), this should always succeed once the step wiring is committed.`,
    ).toBe(true);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 3 — Restricted join: Non-member receives 403 M_FORBIDDEN (@pending-feature)
// ─────────────────────────────────────────────────────────────────────────────

Given(
  'kai has created a Space {string} without inviting marie via the API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    spaceName: string,
  ) => {
    const kaiSession = await getApiSession(request, NEBU_USERS.kai, browser);
    const actualName = `${spaceName}-${Date.now()}`;
    const spaceId = await createSpaceViaApi(request, kaiSession.token, actualName);
    // NOTE: intentionally NOT inviting marie — this is the non-member scenario.
    sharedSpaceByName.set(spaceName, { spaceId, actualName });
  },
);

// NOTE: The step "kai has created a child room {string} with restricted join rule
// referencing the Space" is already registered above (Scenario 2 precondition).
// playwright-bdd resolves that single registration for BOTH Scenario 2 and Scenario 3
// because the Gherkin text is identical. No duplicate registration here.

/**
 * "When {word} attempts to join {string} directly via the Matrix API"
 *
 * Issues POST /join/{roomId} using the named user's Matrix API token directly.
 * Stores the response status AND body for the Then step.
 * This is an API assertion, not a UI step — Element Web has no UI path
 * for a join that will be rejected by the server.
 *
 * MINOR-3 fix: reset lastJoinResponseStatus at the start of this step so a
 * previous scenario's value cannot leak through if the When step is skipped or
 * re-run in a retry.
 */
let lastJoinResponseStatus: number | null = null;
let lastJoinResponseErrcode: string | null = null;

When(
  '{word} attempts to join {string} directly via the Matrix API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    roomName: string,
  ) => {
    // MINOR-3 fix: reset module-level state at the start of the When step.
    lastJoinResponseStatus = null;
    lastJoinResponseErrcode = null;

    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown test user "${userName}".`);

    const entry = roomByName.get(roomName);
    if (!entry) throw new Error(`Room "${roomName}" not set up — run the Given step first.`);

    const session = await getApiSession(request, user, browser);

    const resp = await request.post(
      `${MATRIX_BASE}/_matrix/client/v3/join/${encodeURIComponent(entry.roomId)}`,
      {
        headers: { Authorization: `Bearer ${session.token}`, 'Content-Type': 'application/json' },
        data: {},
      },
    );
    lastJoinResponseStatus = resp.status();

    // MINOR-4 fix: capture the response body to assert errcode in the Then step.
    try {
      const body = (await resp.json()) as Record<string, unknown>;
      lastJoinResponseErrcode = typeof body.errcode === 'string' ? body.errcode : null;
    } catch {
      lastJoinResponseErrcode = null;
    }
  },
);

/**
 * "Then the join response is 403 M_FORBIDDEN"
 *
 * Asserts the stored join response status is 403 AND errcode is M_FORBIDDEN.
 * Tagged @pending-feature: if S4 (MSC3083 enforcement) is not yet deployed,
 * the server returns 200 (or another status) instead of 403, failing this assertion.
 *
 * MINOR-4 fix: also assert body.errcode === 'M_FORBIDDEN'.
 */
Then(
  'the join response is 403 M_FORBIDDEN',
  async () => {
    // FOLLOW-UP BUG: if lastJoinResponseStatus !== 403, S4 restricted join
    // enforcement is not yet live. Tag @pending-feature and open a bug via
    // /nebu-pipeline --bug targeting s4-restricted-join.
    expect(
      lastJoinResponseStatus,
      `Expected HTTP 403 from the server (MSC3083 restricted join enforcement, S4). ` +
      `Got HTTP ${lastJoinResponseStatus}. If the server returns 200 (no enforcement), this scenario ` +
      `is @pending-feature — open a follow-up bug via /nebu-pipeline --bug for S4.`,
    ).toBe(403);

    // MINOR-4: also assert errcode in the response body.
    expect(
      lastJoinResponseErrcode,
      `Expected errcode "M_FORBIDDEN" in the 403 response body (Matrix spec). ` +
      `Got errcode "${lastJoinResponseErrcode}". ` +
      `If the server returns 403 but with a different errcode, the response does not ` +
      `conform to the Matrix Client-Server API spec.`,
    ).toBe('M_FORBIDDEN');
  },
);

// Re-export room state for potential reuse in other spaces step files.
export { roomByName };
