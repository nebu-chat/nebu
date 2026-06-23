/**
 * Step definitions for features/element/spaces/hierarchy.feature
 *
 * Story spaces-elixir-s6-element-spaces-e2e — AC5 (@ac-spaces-hierarchy)
 *
 * Scenario: Space landing view renders child rooms via GET /hierarchy (S3).
 *
 * VISIBILITY CONTRACT (important — see precondition step):
 *   alex is a member of the Space but NOT of the child rooms. Per MSC2946 hierarchy
 *   visibility and Nebu S3 `room_visible?/3` (member OR public OR world_readable),
 *   a child appears in GET /hierarchy for alex only if alex is in it OR it is public
 *   / world_readable. The children are therefore created PUBLIC so a Space-member
 *   legitimately sees them. (Creating them PRIVATE would make the server correctly
 *   filter them out — that would be a TEST defect, not a server defect.)
 *
 *   With public children, a GREEN result proves the hierarchy endpoint surfaces
 *   visible children; a RED result would be a genuine S3 server defect — in that
 *   case tag the scenario @pending-feature and open a /nebu-pipeline --bug for S3.
 *
 * Matrix spec contract:
 *   - m.space.child state event:
 *       PUT /rooms/{spaceId}/state/m.space.child/{childRoomId}
 *       content: {"via":["localhost"],"suggested":true}
 *   - GET /_matrix/client/v1/rooms/{spaceId}/hierarchy — returns rooms[] with child
 *     rooms visible to the caller. Element Web renders this as .mx_SpaceHierarchy_list.
 *
 * Reuse patterns:
 *   - createSpaceViaApi (inline copy)
 *   - getApiSession — from fixtures/dex-auth.ts
 *   - createRoom — from fixtures/dex-auth.ts
 *   - NEBU_USERS — from fixtures/users.ts
 *   - ElementSpacePage.openSpaceLanding() — drives selectSpace + landing view wait
 *   - ElementSpacePage.expectRoomUnderSpace() — landing view assertion
 *   - Timestamp-suffix pattern; module-level Map (spaceByName, roomByName)
 */

import { Given, When, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession } from '../../../fixtures/dex-auth';
import { ElementSpacePage } from '../../../fixtures/element-space';
import { NEBU_USERS } from '../../../fixtures/users';
import { dismissKeySetupDialog } from '../../common/navigation.steps';
import { createSpaceViaApi, addSpaceChild, createPublicRoomViaApi } from './spaces-common.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

// ─────────────────────────────────────────────────────────────────────────────
// Module-level cross-step state (safe with workers: 1)
// ─────────────────────────────────────────────────────────────────────────────

type SpaceEntry = { spaceId: string; actualName: string };
type RoomEntry  = { roomId: string; actualName: string };

const spaceByName = new Map<string, SpaceEntry>();
const roomByName  = new Map<string, RoomEntry>();

// createSpaceViaApi and addSpaceChild are imported from spaces-common.steps.ts
// (single shared copy — previously each step file declared its own).

// ─────────────────────────────────────────────────────────────────────────────
// Precondition step — API only
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Given kai has created a Space {string} with child rooms {string} and {string} via the API"
 *
 * Fully API-driven precondition:
 *   1. kai creates the Space ("e2e-hierarchy-space").
 *   2. kai invites alex to the Space so alex can see the hierarchy (visibility rules).
 *   3. kai creates two child rooms ("e2e-child-alpha", "e2e-child-beta").
 *   4. kai issues two m.space.child state PUTs to link both rooms to the Space.
 *      (PUT /rooms/{spaceId}/state/m.space.child/{childRoomId} with {"via":["localhost"],"suggested":true})
 *   5. alex joins the Space so GET /hierarchy returns results for the alex context.
 *
 * This is API-only — the precondition itself is not under test; the hierarchy
 * rendering in Element Web is.
 */
Given(
  'kai has created a Space {string} with child rooms {string} and {string} via the API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    spaceName: string,
    childRoomName1: string,
    childRoomName2: string,
  ) => {
    const kaiSession  = await getApiSession(request, NEBU_USERS.kai, browser);
    const alexSession = await getApiSession(request, NEBU_USERS.alex, browser);

    // 1. Create Space
    const spaceActualName = `${spaceName}-${Date.now()}`;
    const spaceId = await createSpaceViaApi(request, kaiSession.token, spaceActualName);
    spaceByName.set(spaceName, { spaceId, actualName: spaceActualName });

    // 2. Invite alex to the Space (so GET /hierarchy is not 403 for the alex context)
    const inviteResp = await request.post(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(spaceId)}/invite`,
      {
        headers: { Authorization: `Bearer ${kaiSession.token}`, 'Content-Type': 'application/json' },
        data: { user_id: NEBU_USERS.alex.matrixId },
      },
    );
    if (!inviteResp.ok()) {
      const body = await inviteResp.json().catch(() => ({}));
      // Non-fatal if already a member
      if (!/already (in|a member|joined)|user already in room/i.test(String((body as Record<string, unknown>).error ?? ''))) {
        throw new Error(`[hierarchy precondition] invite alex ${inviteResp.status()} ${JSON.stringify(body)}`);
      }
    }

    // 3. alex joins the Space
    const joinResp = await request.post(
      `${MATRIX_BASE}/_matrix/client/v3/join/${encodeURIComponent(spaceId)}`,
      {
        headers: { Authorization: `Bearer ${alexSession.token}`, 'Content-Type': 'application/json' },
        data: {},
      },
    );
    if (!joinResp.ok()) {
      const body = await joinResp.json().catch(() => ({}));
      if (!/already (in|a member|joined)|user already in room/i.test(String((body as Record<string, unknown>).error ?? ''))) {
        throw new Error(`[hierarchy precondition] alex join space ${joinResp.status()} ${JSON.stringify(body)}`);
      }
    }

    // 4. Create the two child rooms and link them to the Space.
    //
    // Children are created PUBLIC (join_rule = "public"). This is REQUIRED for the
    // scenario to be correct: alex is a member of the Space but NOT of the child
    // rooms. Per MSC2946 hierarchy visibility and Nebu S3 `room_visible?/3`
    // (member OR public OR world_readable), a *private* child alex is not in would
    // be CORRECTLY filtered out of GET /hierarchy — a Space-member is not granted
    // automatic visibility into private children. Creating the children PUBLIC means
    // a green result genuinely proves the hierarchy endpoint surfaces visible
    // children; a red result would then be a real server defect.
    //
    // MINOR-1 fix: static "-2" suffix for the second room (no setTimeout sleep).
    const ts = Date.now();

    const child1ActualName = `${childRoomName1}-${ts}`;
    const roomId1 = await createPublicRoomViaApi(request, kaiSession.token, child1ActualName);
    roomByName.set(childRoomName1, { roomId: roomId1, actualName: child1ActualName });
    await addSpaceChild(request, kaiSession.token, spaceId, roomId1);

    const child2ActualName = `${childRoomName2}-${ts}-2`;
    const roomId2 = await createPublicRoomViaApi(request, kaiSession.token, child2ActualName);
    roomByName.set(childRoomName2, { roomId: roomId2, actualName: child2ActualName });
    await addSpaceChild(request, kaiSession.token, spaceId, roomId2);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Navigation step — open the Space landing view
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "When alex opens the Space {string} landing view"
 *
 * Clicks the Space button in .mx_SpacePanel to select the Space, then waits for
 * the landing view (.mx_SpaceRoomView_landing) to render.
 *
 * This triggers Element Web's call to GET /_matrix/client/v1/rooms/{spaceId}/hierarchy
 * (S3). The child rooms should appear in .mx_SpaceHierarchy_list once Element renders
 * the hierarchy response.
 */
When(
  '{word} opens the Space {string} landing view',
  async ({ page }: { page: Page }, _userName: string, spaceName: string) => {
    const entry = spaceByName.get(spaceName);
    if (!entry) throw new Error(`Space "${spaceName}" not set up — run the Given step first.`);

    await dismissKeySetupDialog(page);

    const space = new ElementSpacePage(page);

    // The Space may need a reload to appear in the SpacePanel after the API join.
    const spaceButton = page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label="${entry.actualName}"]`);
    let buttonVisible = await spaceButton.waitFor({ state: 'visible', timeout: 15_000 })
      .then(() => true).catch(() => false);

    if (!buttonVisible) {
      await page.reload();
      await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});
      await dismissKeySetupDialog(page);
      buttonVisible = await spaceButton.waitFor({ state: 'visible', timeout: 20_000 })
        .then(() => true).catch(() => false);
    }

    if (!buttonVisible) {
      throw new Error(
        `Space "${entry.actualName}" button not visible in .mx_SpacePanel. ` +
        `The API precondition may have failed or Element's SpaceStore did not sync.`,
      );
    }

    // Open the Space landing view using the existing page-object method.
    await space.openSpaceLanding(entry.actualName);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Assertion steps — child rooms visible in the landing view
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Then the child room {string} is visible in the Space hierarchy"
 * "And the child room {string} is visible in the Space hierarchy"
 *
 * Asserts a child room is rendered in the Space landing view
 * (.mx_SpaceRoomView_landing / .mx_SpaceHierarchy_list).
 *
 * This exercises GET /_matrix/client/v1/rooms/{spaceId}/hierarchy (S3).
 * If S3 is not deployed or returns empty children_state, this assertion fails.
 * In that case, the scenario should be tagged @pending-feature.
 * FOLLOW-UP BUG (conditional): /nebu-pipeline --bug for S3 hierarchy endpoint.
 */
Then(
  'the child room {string} is visible in the Space hierarchy',
  async ({ page }: { page: Page }, roomName: string) => {
    const entry = roomByName.get(roomName);
    const actualName = entry?.actualName ?? roomName;

    // ElementSpacePage.expectRoomUnderSpace() asserts the room appears under the Space
    // landing view in .mx_SpaceHierarchy_list or .mx_SpaceRoomView_landing.
    // This uses the existing page-object method to avoid duplicating the selector logic.
    const space = new ElementSpacePage(page);

    // expectRoomUnderSpace asserts via Playwright's expect() and throws on failure.
    // The error message includes context about the @pending-feature scenario if S3
    // is missing.
    try {
      await space.expectRoomUnderSpace(actualName);
    } catch (err) {
      // Re-throw with additional context pointing to the server-side defect scenario.
      const message = err instanceof Error ? err.message : String(err);
      throw new Error(
        `Child room "${actualName}" is NOT visible in the Space hierarchy list. ` +
        `This either means: (a) the step wiring is incomplete (fix in dev-story), or ` +
        `(b) GET /_matrix/client/v1/rooms/{spaceId}/hierarchy (S3) is not returning ` +
        `the correct children_state — mark the scenario @pending-feature and open a ` +
        `/nebu-pipeline --bug for S3. Original error: ${message}`,
      );
    }
  },
);

// Export state for potential future cross-file use.
export { spaceByName, roomByName };
