/**
 * Step definitions for features/element/room/power-levels.feature
 *
 * Story power-levels-enforcement (epic oauth-broker, follow-ups `eq`, `er`, `fr`): `PUT /rooms/{roomId}/state/m.room.power_levels`, the room version 10
 * change rules and the per-type `events` map.
 *
 * Test strategy / integrity:
 *   - Everything is set up and asserted through the Matrix API with the existing session helpers (`getApiSession`, `joinRoom`): the administrator is alex, the
 *     members are marie, tom and kai. Nothing is forged: the oracle is what the SERVER produced (status codes, errcodes, the fixed refusal texts, `/sync`,
 *     `/messages`).
 *   - A power-level change sends the FULL content the sender reads from his own `/sync` (what Element's `setPowerLevel` does: matrix-js-sdk copies the current
 *     `m.room.power_levels` content, changes `users[userId]` and PUTs it to `.../state/m.room.power_levels/`). The steps do the same, so the change rules compare
 *     the whole stored content with the whole new content.
 *   - The UI scenario types the composer slash commands `/op` / `/deop` through the composer steps of messages.steps.ts and asserts SERVER-side only (the latest
 *     levels event), so an Element-side change in slash-command handling never weakens the assertion.
 *   - Never logged: tokens, message content. The steps print nothing; a failing assertion shows what Playwright prints for the diff.
 *   - The rooms are registered in `roomIdByScenario` (template name -> room id) so the shared `navigates to room` step can open them.
 *   - Module-level state is safe with workers: 1 (see playwright.config.ts).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse, Browser } from '@playwright/test';
import { getApiSession, joinRoom } from '../../fixtures/dex-auth';
import { NEBU_USERS, type NebUser } from '../../fixtures/users';
import { roomIdByScenario } from '../common/room-setup.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

const POWER_LEVELS_TYPE = 'm.room.power_levels';

type Fixtures = { request: APIRequestContext; browser: Browser };

type LevelsContent = {
  users?: Record<string, number>;
  events?: Record<string, number>;
  [key: string]: unknown;
};

type StateEvent = {
  type: string;
  state_key?: string;
  sender?: string;
  event_id?: string;
  origin_server_ts?: number;
  content?: LevelsContent;
  unsigned?: { prev_content?: LevelsContent; replaces_state?: string };
};

type SyncBody = {
  rooms?: {
    join?: Record<string, { state?: { events?: StateEvent[] }; timeline?: { events?: StateEvent[] } }>;
  };
};

/** The levels events a scenario's administrator committed, per room id, oldest first (the event id and the content he sent). */
const committedLevels = new Map<string, { eventId: string; content: LevelsContent }[]>();

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

function roomIdOf(template: string): string {
  const entry = roomIdByScenario.get(template);
  if (!entry) throw new Error(`Room "${template}" is not registered: the step that creates the power-levels room must run first.`);
  return entry.roomId;
}

async function tokenOf(f: Fixtures, userName: string): Promise<string> {
  return (await getApiSession(f.request, userByName(userName), f.browser)).token;
}

function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

/** `POST /createRoom` with the `public_chat` preset (join rule public); the room is not listed in the directory. */
async function createPowerLevelsRoom(f: Fixtures, ownerName: string, template: string): Promise<string> {
  const token = await tokenOf(f, ownerName);
  const name = `${template}-${Date.now()}`;
  const resp = await f.request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: authHeaders(token),
    data: { name, preset: 'public_chat', visibility: 'private' },
  });
  expect(resp.status(), `createRoom answered ${resp.status()}`).toBe(200);
  const roomId = ((await resp.json()) as { room_id: string }).room_id;
  roomIdByScenario.set(template, { roomId, actualName: name });
  return roomId;
}

/** The newest `m.room.power_levels` event in a /sync body of one room: the state block and the timeline, the highest `origin_server_ts` wins. */
function latestLevelsEvent(body: SyncBody, roomId: string): StateEvent | undefined {
  const room = body.rooms?.join?.[roomId];
  const events = [...(room?.state?.events ?? []), ...(room?.timeline?.events ?? [])].filter((e) => e.type === POWER_LEVELS_TYPE && (e.state_key ?? '') === '');
  return events.sort((a, b) => (a.origin_server_ts ?? 0) - (b.origin_server_ts ?? 0)).pop();
}

/** A full `/sync` (no since token) of `userName`, `timeout=0`. */
async function fullSync(f: Fixtures, userName: string): Promise<SyncBody> {
  const token = await tokenOf(f, userName);
  const resp = await f.request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, { headers: { Authorization: `Bearer ${token}` } });
  expect(resp.status(), `full sync of ${userName} answered ${resp.status()}`).toBe(200);
  return (await resp.json()) as SyncBody;
}

/** The CURRENT levels content of a room as `userName` reads it from his own /sync (what Element's setPowerLevel starts from). */
async function currentLevels(f: Fixtures, userName: string, template: string): Promise<LevelsContent> {
  const event = latestLevelsEvent(await fullSync(f, userName), roomIdOf(template));
  expect(event, `${userName}'s sync carries an ${POWER_LEVELS_TYPE} event`).toBeTruthy();
  return JSON.parse(JSON.stringify((event as StateEvent).content ?? {})) as LevelsContent;
}

/** `PUT .../state/m.room.power_levels/` (the empty state key written out, like Element) with the full `content`. */
async function putLevels(f: Fixtures, userName: string, template: string, content: LevelsContent): Promise<APIResponse> {
  const token = await tokenOf(f, userName);
  return f.request.put(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/state/${POWER_LEVELS_TYPE}/`, {
    headers: authHeaders(token),
    data: content,
  });
}

/** A change by `userName` that must be committed: `200 {event_id}`; remembered as the room's newest committed levels event. */
async function changeLevels(f: Fixtures, userName: string, template: string, change: (content: LevelsContent) => void): Promise<void> {
  const content = await currentLevels(f, userName, template);
  change(content);
  const resp = await putLevels(f, userName, template, content);
  expect(resp.status(), `${userName}'s PUT of the power levels answered ${resp.status()}`).toBe(200);
  const eventId = ((await resp.json()) as { event_id?: string }).event_id;
  expect(typeof eventId, 'the answer carries an event_id').toBe('string');
  const roomId = roomIdOf(template);
  committedLevels.set(roomId, [...(committedLevels.get(roomId) ?? []), { eventId: eventId as string, content }]);
}

/** Asserts a refusal: status 403, errcode `M_FORBIDDEN` and (when given) the exact fixed text; nothing else is in the body. */
async function expectForbidden(resp: APIResponse, what: string, message?: string): Promise<void> {
  expect(resp.status(), `${what} is refused`).toBe(403);
  const body = (await resp.json()) as { errcode?: string; error?: string };
  expect(body.errcode, `${what}: errcode`).toBe('M_FORBIDDEN');
  if (message !== undefined) expect(body.error, `${what}: the fixed refusal text`).toBe(message);
}

/** The newest `m.room.power_levels` event of a room as `viewerName` sees it in `GET /messages?dir=b` (the viewer is joined and sees it). */
async function latestLevelsInTimeline(f: Fixtures, viewerName: string, template: string): Promise<StateEvent | undefined> {
  const token = await tokenOf(f, viewerName);
  const resp = await f.request.get(
    `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/messages?dir=b&limit=100`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  if (!resp.ok()) throw new Error(`[latestLevelsInTimeline] /messages answered ${resp.status()}`);
  const chunk = ((await resp.json()) as { chunk?: StateEvent[] }).chunk ?? [];
  return chunk.find((e) => e.type === POWER_LEVELS_TYPE);
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────────────────────────────────────

/** "Given alex has created the public power-levels room {string} and {string} have joined it": a `public_chat` room, the comma-separated members join through the API. */
Given(
  '{word} has created the public power-levels room {string} and {string} have joined it',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, memberNames: string) => {
    const roomId = await createPowerLevelsRoom({ request, browser }, ownerName, template);
    for (const memberName of memberNames.split(',').map((n) => n.trim()).filter((n) => n !== '')) {
      await joinRoom(request, await tokenOf({ request, browser }, memberName), roomId);
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Power-level changes (the committed ones)
// ─────────────────────────────────────────────────────────────────────────────

/** "When alex sets marie to level 50 in {string} and lets level 50 change the power levels": ONE PUT, the member gets the level and `events[m.room.power_levels]` is lowered. */
When(
  '{word} sets {word} to level {int} in {string} and lets level {int} change the power levels',
  async ({ request, browser }: Fixtures, adminName: string, targetName: string, level: number, template: string, requiredLevel: number) => {
    await changeLevels({ request, browser }, adminName, template, (content) => {
      content.users = { ...(content.users ?? {}), [userByName(targetName).matrixId]: level };
      content.events = { ...(content.events ?? {}), [POWER_LEVELS_TYPE]: requiredLevel };
    });
  },
);

/** "When alex sets marie to level 0 in {string}": ONE PUT that must be committed. */
When(
  '{word} sets {word} to level {int} in {string}',
  async ({ request, browser }: Fixtures, adminName: string, targetName: string, level: number, template: string) => {
    await changeLevels({ request, browser }, adminName, template, (content) => {
      content.users = { ...(content.users ?? {}), [userByName(targetName).matrixId]: level };
    });
  },
);

/** "When alex requires level 100 for m.room.topic in {string}": `events[type]` is set, ONE PUT that must be committed. */
When(
  '{word} requires level {int} for {word} in {string}',
  async ({ request, browser }: Fixtures, adminName: string, level: number, eventType: string, template: string) => {
    await changeLevels({ request, browser }, adminName, template, (content) => {
      content.events = { ...(content.events ?? {}), [eventType]: level };
    });
  },
);

/** "When marie kicks tom from the power-levels room {string}": `POST /kick` must be `200 {}`. */
When('{word} kicks {word} from the power-levels room {string}', async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string) => {
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/kick`, {
    headers: authHeaders(await tokenOf({ request, browser }, moderatorName)),
    data: { user_id: userByName(targetName).matrixId },
  });
  expect(resp.status(), `kick answered ${resp.status()}`).toBe(200);
  expect(await resp.json(), 'kick answers an empty JSON object').toEqual({});
});

// ─────────────────────────────────────────────────────────────────────────────
// Refusals
// ─────────────────────────────────────────────────────────────────────────────

/** "Then marie's attempt to set alex to level 0 in {string} is refused with M_FORBIDDEN and the message {string}": the full content of HIS OWN sync with one entry changed. */
Then(
  "{word}'s attempt to set {word} to level {int} in {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, senderName: string, targetName: string, level: number, template: string, message: string) => {
    const content = await currentLevels({ request, browser }, senderName, template);
    content.users = { ...(content.users ?? {}), [userByName(targetName).matrixId]: level };
    await expectForbidden(await putLevels({ request, browser }, senderName, template, content), `${senderName}'s change of ${targetName}'s level`, message);
  },
);

/** "Then marie's change of the topic of {string} is refused with M_FORBIDDEN and the message {string}": `PUT .../state/m.room.topic` needs `events[m.room.topic]`. */
Then(
  "{word}'s change of the topic of {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, userName: string, template: string, message: string) => {
    const resp = await request.put(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/state/m.room.topic`, {
      headers: authHeaders(await tokenOf({ request, browser }, userName)),
      data: { topic: 'e2e power levels' },
    });
    await expectForbidden(resp, `${userName}'s topic change`, message);
  },
);

/** "Then marie's kick of kai from {string} is refused with M_FORBIDDEN and the message {string}": a demoted moderator can no longer kick. */
Then(
  "{word}'s kick of {word} from {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string, message: string) => {
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/kick`, {
      headers: authHeaders(await tokenOf({ request, browser }, moderatorName)),
      data: { user_id: userByName(targetName).matrixId },
    });
    await expectForbidden(resp, `${moderatorName}'s kick of ${targetName}`, message);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Server-side evidence
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Then kai's sync shows the latest power levels of {string} with the previous content in unsigned.prev_content": the newest levels event of kai's full /sync is
 * the last one the administrator committed (same event id, same content) and carries the content before it in `unsigned.prev_content`.
 */
Then(
  "{word}'s sync shows the latest power levels of {string} with the previous content in unsigned.prev_content",
  async ({ request, browser }: Fixtures, userName: string, template: string) => {
    const roomId = roomIdOf(template);
    const committed = committedLevels.get(roomId) ?? [];
    expect(committed.length, 'the scenario committed at least two changes').toBeGreaterThanOrEqual(2);
    const last = committed[committed.length - 1];
    const previous = committed[committed.length - 2];

    const event = latestLevelsEvent(await fullSync({ request, browser }, userName), roomId);
    expect(event, `${userName}'s sync carries the levels event`).toBeTruthy();
    const seen = event as StateEvent;
    expect(seen.event_id, 'the latest levels event is the last committed change').toBe(last.eventId);
    expect(seen.content, 'its content is what the administrator sent').toEqual(last.content);
    expect(seen.unsigned?.prev_content, 'unsigned.prev_content is the content of the change before it').toEqual(previous.content);
    expect(seen.unsigned?.replaces_state, 'unsigned.replaces_state is the id of the change before it').toBe(previous.eventId);
  },
);

/** "Then marie's power level in {string} is 50 as set by alex": polled (the UI scenario writes it through Element), read by the administrator through /messages. */
Then(
  "{word}'s power level in {string} is {int} as set by {word}",
  async ({ request, browser }: Fixtures, targetName: string, template: string, level: number, adminName: string) => {
    await expect
      .poll(
        async () => {
          const event = await latestLevelsInTimeline({ request, browser }, adminName, template);
          return { level: event?.content?.users?.[userByName(targetName).matrixId], sender: event?.sender };
        },
        { message: `the latest levels event gives ${targetName} level ${level} by ${adminName}`, timeout: 30_000 },
      )
      .toEqual({ level, sender: userByName(adminName).matrixId });
  },
);

/** "Then marie has no power level entry in {string}": polled; the latest levels event has no `users` entry for her (a /deop removes it). */
Then('{word} has no power level entry in {string}', async ({ request, browser }: Fixtures, targetName: string, template: string) => {
  await expect
    .poll(
      async () => {
        const event = await latestLevelsInTimeline({ request, browser }, 'alex', template);
        return { hasEntry: Object.prototype.hasOwnProperty.call(event?.content?.users ?? {}, userByName(targetName).matrixId), found: event !== undefined };
      },
      { message: `the latest levels event has no entry for ${targetName}`, timeout: 30_000 },
    )
    .toEqual({ hasEntry: false, found: true });
});
