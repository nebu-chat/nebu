/**
 * Step definitions for features/element/spaces/create-room-in-space.feature
 *
 * Regression guard for: "a room a Space OWNER creates INSIDE their own Space lands in the
 * personal/home area instead of becoming a child of the Space".
 *
 * With the Space active, Element's "Add -> New room" issues ONE POST /_matrix/client/v3/createRoom
 * whose `initial_state` contains the child's `m.space.parent` (state_key = spaceId) plus a
 * restricted `m.room.join_rules` referencing the parent Space (then a separate m.space.child PUT
 * to the Space). Nebu applies `initial_state` (Nebu.Matrix.EventDispatcher.Server.create_room/2);
 * these scenarios pin that.
 *
 * Test strategy / integrity:
 *   - Real OIDC login via the shared "{word} is logged in via Element Web" step.
 *   - Scenario 1 (API contract): one POST /createRoom with the `initial_state` Element sends and
 *     NO m.space.child / m.space.parent state write of its own; the oracle is the child room's own
 *     m.space.parent edge (read via /sync).
 *   - Scenario 2 (real UI): the genuine owner UI path (select Space -> Add -> New room).
 *
 * ROOM IDS vs ALIASES (follow-up dx, the cause of the old "K8" failure): Nebu derives a canonical
 * alias from the room name, so Element navigates to `#/room/#name-123:localhost` and the id read
 * from the URL is the ALIAS, not the room id. `/sync` is keyed by room id and `m.space.parent`
 * carries the Space's room id as state_key, so UI-derived ids are resolved to room ids first
 * (GET /_matrix/client/v1/room_summary/{roomIdOrAlias}).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession } from '../../fixtures/dex-auth';
import { ElementSpacePage } from '../../fixtures/element-space';
import { NEBU_USERS } from '../../fixtures/users';

const MATRIX_BASE   = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const MATRIX_SERVER = 'localhost'; // matches NEBU_USERS matrixId server part

// ─────────────────────────────────────────────────────────────────────────────
// Module-level state (safe with workers: 1 — see playwright.config.ts)
// ─────────────────────────────────────────────────────────────────────────────

type SpaceEntry = { spaceId: string; actualName: string };
type RoomEntry  = { roomId: string;  actualName: string };

const spaceByName = new Map<string, SpaceEntry>();
const roomByName  = new Map<string, RoomEntry>();

// ─────────────────────────────────────────────────────────────────────────────
// Internal API helpers (Scenario 1 — the exact requests Element issues)
// ─────────────────────────────────────────────────────────────────────────────

/** Create a Space (room with creation_content.type = "m.space") via the Matrix API. */
async function createSpaceViaApi(
  request: APIRequestContext,
  token: string,
  spaceName: string,
): Promise<string> {
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    data: {
      name: spaceName,
      preset: 'private_chat',
      visibility: 'private',
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
 * Create a room INSIDE a Space with the EXACT createRoom body Element Web sends when
 * `parentSpace` is set (see element-web apps/web/src/createRoom.ts): the child's
 * `m.space.parent` link plus the restricted join rule, all inside `initial_state`.
 *
 * Crucially: this issues NO separate m.space.child / m.space.parent state PUT. The
 * parent→child link must be established by the server honouring `initial_state`.
 * That is the behaviour under test — nothing here masks the drop.
 */
async function createRoomInSpaceLikeElement(
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
          type: 'm.space.parent',
          state_key: spaceId,
          content: { via: [MATRIX_SERVER], canonical: true },
        },
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
    throw new Error(`[createRoomInSpaceLikeElement] ${resp.status()} ${JSON.stringify(body)}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

/**
 * Read a room's current state events via /sync (the GET /rooms/{id}/state endpoint is
 * not implemented on Nebu). Returns the joined room's state + timeline events.
 */
async function roomStateEvents(
  request: APIRequestContext,
  token: string,
  roomId: string,
): Promise<Array<{ type: string; state_key?: string; content?: unknown }>> {
  const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!resp.ok()) {
    throw new Error(`[roomStateEvents] sync ${resp.status()}`);
  }
  const body = (await resp.json()) as {
    rooms?: { join?: Record<string, {
      state?: { events?: Array<{ type: string; state_key?: string; content?: unknown }> };
      timeline?: { events?: Array<{ type: string; state_key?: string; content?: unknown }> };
    }> };
  };
  const room = body.rooms?.join?.[roomId];
  return [
    ...(room?.state?.events ?? []),
    ...(room?.timeline?.events ?? []),
  ];
}

/**
 * A room reference read from the Element URL is a room id (`!x:server`) or, for a room with a
 * canonical alias, the alias (`#name:server`). Resolve an alias to the room id through the
 * local-only room preview endpoint; a room id is returned unchanged.
 */
async function resolveRoomId(
  request: APIRequestContext,
  token: string,
  idOrAlias: string,
): Promise<string> {
  if (!idOrAlias.startsWith('#')) return idOrAlias;
  const resp = await request.get(
    `${MATRIX_BASE}/_matrix/client/v1/room_summary/${encodeURIComponent(idOrAlias)}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  if (!resp.ok()) {
    throw new Error(`[resolveRoomId] ${idOrAlias} -> ${resp.status()} ${await resp.text()}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 1 — pure createRoom contract (no side-channel)
// ─────────────────────────────────────────────────────────────────────────────

Given(
  '{word} owns a Space named {string}',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    spaceName: string,
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown test user "${userName}".`);
    const session = await getApiSession(request, user, browser);

    const actualName = `${spaceName}-${Date.now()}`;
    const spaceId = await createSpaceViaApi(request, session.token, actualName);
    spaceByName.set(spaceName, { spaceId, actualName });
  },
);

When(
  '{word} creates a room {string} inside the Space {string} exactly as Element does',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    roomName: string,
    spaceName: string,
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`Unknown test user "${userName}".`);
    const space = spaceByName.get(spaceName);
    if (!space) throw new Error(`Space "${spaceName}" not set up — run the Given first.`);

    const session = await getApiSession(request, user, browser);
    const actualName = `${roomName}-${Date.now()}`;
    const roomId = await createRoomInSpaceLikeElement(
      request, session.token, actualName, space.spaceId,
    );
    roomByName.set(roomName, { roomId, actualName });
  },
);

Then(
  'the room {string} carries an m.space.parent link to the Space {string}',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    roomName: string,
    spaceName: string,
  ) => {
    const space = spaceByName.get(spaceName);
    const room  = roomByName.get(roomName);
    if (!space) throw new Error(`Space "${spaceName}" not set up.`);
    if (!room)  throw new Error(`Room "${roomName}" not created.`);

    const session = await getApiSession(request, NEBU_USERS.alex, browser);
    // UI-derived references may be canonical aliases (see the header): compare room ids.
    const roomId  = await resolveRoomId(request, session.token, room.roomId);
    const spaceId = await resolveRoomId(request, session.token, space.spaceId);
    const events = await roomStateEvents(request, session.token, roomId);

    const parentEdge = events.find(
      (e) => e.type === 'm.space.parent' && e.state_key === spaceId,
    );

    expect(
      parentEdge,
      `Expected the room ${roomId} to carry an m.space.parent state event ` +
      `(state_key=${spaceId}) — the link Element supplies in createRoom's ` +
      `initial_state. Without it the room is never associated with the Space. ` +
      `Got events: ${JSON.stringify(events.map((e) => [e.type, e.state_key]))}`,
    ).toBeTruthy();
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 2 — genuine Element UI flow (no forged server state)
// ─────────────────────────────────────────────────────────────────────────────

Given(
  '{word} creates a Space named {string} via Element Web',
  async ({ page }: { page: Page }, _userName: string, spaceName: string) => {
    const actualName = `${spaceName}-${Date.now()}`;
    const space = new ElementSpacePage(page);
    const spaceId = await space.createPrivateSpace(actualName);
    spaceByName.set(spaceName, { spaceId, actualName });
  },
);

When(
  '{word} creates a room {string} inside that Space via Element Web',
  async ({ page }: { page: Page }, _userName: string, roomName: string) => {
    // The most-recently created Space (Scenario 2 uses a single Space) is the active one.
    const entries = [...spaceByName.values()];
    const space = entries[entries.length - 1];
    if (!space) throw new Error('No Space created via Element Web in this scenario.');

    const actualName = `${roomName}-${Date.now()}`;
    const sp = new ElementSpacePage(page);
    await sp.selectSpace(space.actualName);
    const roomId = await sp.createRoomInActiveSpace(actualName);
    roomByName.set(roomName, { roomId, actualName });
  },
);
