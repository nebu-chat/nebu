/**
 * Shared step definitions for the Spaces feature suite.
 *
 * Story spaces-elixir-s6-element-spaces-e2e
 *
 * PURPOSE: playwright-bdd uses ONE global step registry across all loaded step
 * files. Registering the same Gherkin text in more than one file causes an
 * "ambiguous step" error that blocks the ENTIRE suite. This file is the single
 * authoritative registration point for steps shared across two or more of:
 *   create.steps.ts / join.steps.ts / leave.steps.ts / hierarchy.steps.ts
 *
 * Shared steps registered here:
 *   1. Given/Then "the Space {string} appears in alex's Space panel"
 *      — used in create.feature (Then) and leave.feature (And/Given).
 *
 *   2. Given "kai has created a Space {string} and alex is a member via the API"
 *      — used in join.feature (Scenario 2) and leave.feature.
 *
 * IMPORTANT: each individual step file (create, join, leave, hierarchy) imports
 * the shared state Maps from this file rather than declaring their own. This
 * prevents duplicate type declarations and keeps the Map instances in sync.
 */

import { Given, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession, inviteUser, joinRoom } from '../../../fixtures/dex-auth';
import { NEBU_USERS } from '../../../fixtures/users';
import { dismissKeySetupDialog } from '../../common/navigation.steps';

const MATRIX_BASE   = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const MATRIX_SERVER = 'localhost';

// ─────────────────────────────────────────────────────────────────────────────
// Shared cross-step state
// Exported so individual step files can read/write without owning their own Map.
// ─────────────────────────────────────────────────────────────────────────────

export type SpaceEntry = { spaceId: string; actualName: string };
export type RoomEntry  = { roomId: string;  actualName: string };

/**
 * Shared Space state Map — key is the template name (without timestamp suffix).
 *
 * Written by:
 *   - "kai has created a Space … and alex is a member" (this file)
 *   - "kai has created a public Space … via the API" (join.steps.ts)
 *   - "kai has created a Space … without inviting marie" (join.steps.ts)
 *   - "kai has created a Space … with child rooms … via the API" (hierarchy.steps.ts)
 *
 * Read by:
 *   - "the Space … appears in alex's Space panel" (this file)
 *   - "the Space … is not in alex's Space panel" (leave.steps.ts)
 *   - "alex leaves the Space … via Element Web" (leave.steps.ts)
 *   - "alex joins the Space … via Element Web" (join.steps.ts)
 *   - "kai has created a child room … with restricted join rule" (join.steps.ts)
 *   - "alex opens the Space … landing view" (hierarchy.steps.ts)
 */
export const sharedSpaceByName = new Map<string, SpaceEntry>();

// ─────────────────────────────────────────────────────────────────────────────
// Internal API helper (shared, avoids code duplication across step files)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Create a Space (room with creation_content.type = "m.space") via the Matrix API.
 *
 * Exported so join.steps.ts, leave.steps.ts, and hierarchy.steps.ts can reuse
 * it without declaring their own copy (which would be dead code and confuse readers).
 */
export async function createSpaceViaApi(
  request: APIRequestContext,
  token: string,
  spaceName: string,
  preset: 'private_chat' | 'public_chat' = 'private_chat',
): Promise<string> {
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      name: spaceName,
      preset,
      visibility: preset === 'public_chat' ? 'public' : 'private',
      creation_content: { type: 'm.space' },
    },
  });
  if (!resp.ok()) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(`[createSpaceViaApi] ${resp.status()} ${JSON.stringify(body)}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

/**
 * Create a PUBLIC room (preset public_chat → m.room.join_rules join_rule = "public")
 * via the Matrix API. Returns the new room id.
 *
 * Used by hierarchy.steps.ts for child rooms: per the Matrix hierarchy visibility
 * rules (MSC2946) and Nebu's S3 `room_visible?/3` (member OR public OR
 * world_readable), a room appears in GET /hierarchy for a caller only if the caller
 * is joined/invited to THAT room, or the room is public / world_readable. A
 * Space-member is NOT automatically able to see a *private* child they are not in.
 * Children must therefore be PUBLIC for a Space-member (who is not a child member)
 * to see them in the hierarchy — otherwise the server CORRECTLY filters them out.
 */
export async function createPublicRoomViaApi(
  request: APIRequestContext,
  token: string,
  roomName: string,
): Promise<string> {
  // IMPORTANT: Nebu's createRoom has NO `preset` field (it is dropped), and
  // top-level `visibility` only sets room-DIRECTORY listing — NOT the join rule.
  // The join_rule must be set explicitly via `initial_state` (which createRoom
  // honours since commit 652d9c00). We set BOTH join_rule=public AND
  // history_visibility=world_readable so the room satisfies Nebu's hierarchy
  // `room_visible?` predicate (member OR public OR world_readable) for a caller
  // who is not a member of the room.
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      name: roomName,
      visibility: 'public',
      initial_state: [
        { type: 'm.room.join_rules', state_key: '', content: { join_rule: 'public' } },
        { type: 'm.room.history_visibility', state_key: '', content: { history_visibility: 'world_readable' } },
      ],
    },
  });
  if (!resp.ok()) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(`[createPublicRoomViaApi] ${resp.status()} ${JSON.stringify(body)}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

/**
 * Write an m.space.child state event to link a child room to a Space.
 *
 * Exported so join.steps.ts and hierarchy.steps.ts reuse a single copy
 * (they previously each declared an identical local helper).
 *
 * Per Matrix spec (S2): "via" is REQUIRED; without it the child is excluded from
 * the hierarchy response. "suggested" is optional but recommended for Element Web.
 */
export async function addSpaceChild(
  request: APIRequestContext,
  token: string,
  spaceId: string,
  childRoomId: string,
): Promise<void> {
  const resp = await request.put(
    `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(spaceId)}/state/m.space.child/${encodeURIComponent(childRoomId)}`,
    {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { via: [MATRIX_SERVER], suggested: true },
    },
  );
  if (!resp.ok()) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(`[addSpaceChild] ${resp.status()} ${JSON.stringify(body)}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED STEP 1
// "kai has created a Space {string} and alex is a member via the API"
//
// Used in:
//   - join.feature   Scenario 2 (Scenario: Space member joins a restricted child room)
//   - leave.feature  Scenario   (Scenario: Leave a Space)
//
// Registered ONCE here. Do NOT register this Gherkin text in join.steps.ts or
// leave.steps.ts — playwright-bdd will throw an ambiguous-step error.
// ─────────────────────────────────────────────────────────────────────────────

Given(
  'kai has created a Space {string} and alex is a member via the API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    spaceName: string,
  ) => {
    const kaiSession  = await getApiSession(request, NEBU_USERS.kai, browser);
    const alexSession = await getApiSession(request, NEBU_USERS.alex, browser);

    const actualName = `${spaceName}-${Date.now()}`;
    const spaceId = await createSpaceViaApi(request, kaiSession.token, actualName);
    sharedSpaceByName.set(spaceName, { spaceId, actualName });

    // Invite alex to the Space (so alex has m.room_membership = join in this Space).
    await inviteUser(request, kaiSession.token, spaceId, NEBU_USERS.alex.matrixId);
    // alex joins via the Matrix API so the Space appears in the sidebar on login.
    await joinRoom(request, alexSession.token, spaceId);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// SHARED STEP 2
// "the Space {string} appears in alex's Space panel"
//
// Used in:
//   - create.feature  (Then) — asserts Space visible after create
//   - leave.feature   (And)  — pre-condition assertion before leave
//   - join.feature    (Then) — asserts Space visible after join
//
// Registered ONCE here. Do NOT register this Gherkin text in create.steps.ts,
// leave.steps.ts, or join.steps.ts.
// ─────────────────────────────────────────────────────────────────────────────

Then(
  'the Space {string} appears in alex\'s Space panel',
  async ({ page }: { page: Page }, spaceName: string) => {
    await dismissKeySetupDialog(page);

    // Element Web renders each Space as a button in .mx_SpacePanel with
    // aria-label matching the Space name (with a timestamp suffix appended at
    // creation time, e.g. "e2e-space-create-1719051234567").
    //
    // Strategy: look up the exact name from sharedSpaceByName if available
    // (populated by steps that own their Map entry). If not found (e.g. the
    // step was created by create-room-in-space.steps.ts which uses its own
    // local Map), fall back to an aria-label *starts-with* selector so the
    // timestamp suffix does not cause a mismatch.
    const entry = sharedSpaceByName.get(spaceName);

    let spaceButton;
    if (entry) {
      // Exact match — we know the full actual name.
      spaceButton = page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label="${entry.actualName}"]`);
    } else {
      // Starts-with match — covers cases where the step that created the Space
      // wrote to a different local Map (e.g. create-room-in-space.steps.ts).
      // The template name is always a prefix of the actual (timestamped) name.
      spaceButton = page.locator(`.mx_SpacePanel .mx_SpaceButton[aria-label^="${spaceName}"]`);
    }

    // The Space may need a reload to appear after an API join or UI create
    // (the SpaceStore updates lazily after /sync delivery).
    // Use 'attached' (not 'visible') first — the SpacePanel may have many items and the
    // button may be scrolled below the fold (attached = in DOM, visible = in viewport).
    // After confirming it's attached, scroll it into view and then check visible.
    let visible = await spaceButton.first().waitFor({ state: 'attached', timeout: 15_000 })
      .then(async () => {
        await spaceButton.first().scrollIntoViewIfNeeded({ timeout: 5_000 }).catch(() => {});
        return spaceButton.first().waitFor({ state: 'visible', timeout: 5_000 })
          .then(() => true).catch(() => false);
      })
      .catch(() => false);

    if (!visible) {
      await page.reload();
      await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 30_000 }).catch(() => {});
      await dismissKeySetupDialog(page);
      visible = await spaceButton.first().waitFor({ state: 'attached', timeout: 20_000 })
        .then(async () => {
          await spaceButton.first().scrollIntoViewIfNeeded({ timeout: 5_000 }).catch(() => {});
          return spaceButton.first().waitFor({ state: 'visible', timeout: 5_000 })
            .then(() => true).catch(() => false);
        })
        .catch(() => false);
    }

    const displayName = entry?.actualName ?? `${spaceName}*`;
    expect(
      visible,
      `Expected Space "${displayName}" button to be visible in .mx_SpacePanel. ` +
      `The Space was created or joined — if this assertion fails, ` +
      `the .mx_SpacePanel may not have re-rendered after the reload, or ` +
      `the Space create/join flow did not complete successfully.`,
    ).toBe(true);
  },
);
