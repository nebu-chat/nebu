/**
 * Step definitions for features/element/room/moderation.feature
 *
 * Story moderation-routes-atomic-ban (epic oauth-broker, follow-ups `ex`, `ew`): `POST /rooms/{roomId}/kick`, `/ban` and `/unban`.
 *
 * Test strategy / integrity:
 *   - Everything is set up and asserted through the Matrix API with the existing session helpers (`getApiSession`, `joinRoom`): the moderator is
 *     alex, the moderated users are marie (public room) and kai (the Disinvite of an invite-only room; the story's "bob" does not exist as an e2e
 *     user). Nothing is forged: the oracle is what the SERVER produced (status codes, errcodes, fixed texts, `/sync`, `/messages`).
 *   - The UI scenario types the composer slash commands through the composer steps of messages.steps.ts and asserts SERVER-side only (the latest
 *     membership of marie), so an Element-side change in slash-command handling never weakens the assertion.
 *   - Never logged: tokens, the moderation reasons, message content. The steps print nothing; a failing assertion shows what Playwright prints
 *     for the diff.
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

type Fixtures = { request: APIRequestContext; browser: Browser };

type MemberEvent = {
  type: string;
  state_key?: string;
  sender?: string;
  content?: { membership?: string; reason?: string };
};

type SyncBody = {
  next_batch?: string;
  rooms?: {
    join?: Record<string, unknown>;
    invite?: Record<string, unknown>;
    leave?: Record<string, { timeline?: { events?: MemberEvent[] } }>;
  };
};

/** The `since` token of a user's recorded sync position, by user name (a full /sync replaces the stored token of the user: follow-up `fd`). */
const syncPositions = new Map<string, string>();

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

function roomIdOf(template: string): string {
  const entry = roomIdByScenario.get(template);
  if (!entry) throw new Error(`Room "${template}" is not registered: the step that creates the moderation room must run first.`);
  return entry.roomId;
}

async function tokenOf(f: Fixtures, userName: string): Promise<string> {
  return (await getApiSession(f.request, userByName(userName), f.browser)).token;
}

function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

/** `POST /createRoom` with a preset (`public_chat`: join rule public, `private_chat`: invite only); the room is not listed in the directory. */
async function createModerationRoom(f: Fixtures, ownerName: string, template: string, preset: 'public_chat' | 'private_chat'): Promise<string> {
  const token = await tokenOf(f, ownerName);
  const name = `${template}-${Date.now()}`;
  const resp = await f.request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: authHeaders(token),
    data: { name, preset, visibility: 'private' },
  });
  expect(resp.status(), `createRoom (${preset}) answered ${resp.status()}`).toBe(200);
  const roomId = ((await resp.json()) as { room_id: string }).room_id;
  roomIdByScenario.set(template, { roomId, actualName: name });
  return roomId;
}

/** `POST /rooms/{roomId}/{kick|ban|unban}` as `moderatorName`: asserts `200 {}`. The reason is sent as is and never printed. */
async function moderate(
  f: Fixtures,
  action: 'kick' | 'ban' | 'unban',
  moderatorName: string,
  targetName: string,
  template: string,
  reason?: string,
): Promise<void> {
  const token = await tokenOf(f, moderatorName);
  const data: Record<string, string> = { user_id: userByName(targetName).matrixId };
  if (reason !== undefined) data.reason = reason;

  const resp = await f.request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/${action}`, {
    headers: authHeaders(token),
    data,
  });
  expect(resp.status(), `${action} answered ${resp.status()}`).toBe(200);
  expect(await resp.json(), `${action} answers an empty JSON object`).toEqual({});
}

/** The newest `m.room.member` event of `targetName` as `viewerName` sees it in `GET /messages?dir=b` (the moderator is joined and sees it). */
async function latestMemberEvent(f: Fixtures, viewerName: string, targetName: string, template: string): Promise<MemberEvent | undefined> {
  const token = await tokenOf(f, viewerName);
  const resp = await f.request.get(
    `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/messages?dir=b&limit=100`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  if (!resp.ok()) throw new Error(`[latestMemberEvent] /messages answered ${resp.status()}`);
  const chunk = ((await resp.json()) as { chunk?: MemberEvent[] }).chunk ?? [];
  const targetId = userByName(targetName).matrixId;
  return chunk.find((e) => e.type === 'm.room.member' && e.state_key === targetId);
}

/** A full `/sync` (no since token) of `userName`, `timeout=0`. */
async function fullSync(f: Fixtures, userName: string): Promise<SyncBody> {
  const token = await tokenOf(f, userName);
  const resp = await f.request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, { headers: { Authorization: `Bearer ${token}` } });
  expect(resp.status(), `full sync of ${userName} answered ${resp.status()}`).toBe(200);
  return (await resp.json()) as SyncBody;
}

/** `POST /join/{roomId}` as `userName` WITHOUT any helper that throws: the answer itself is the evidence. */
async function postJoin(f: Fixtures, userName: string, template: string): Promise<APIResponse> {
  const token = await tokenOf(f, userName);
  return f.request.post(`${MATRIX_BASE}/_matrix/client/v3/join/${encodeURIComponent(roomIdOf(template))}`, {
    headers: authHeaders(token),
    data: {},
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────────────────────────────────────

/** "Given alex has created the public moderation room {string} and marie has joined it": a `public_chat` room, the member joins through the API. */
Given(
  '{word} has created the public moderation room {string} and {word} has joined it',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, memberName: string) => {
    const roomId = await createModerationRoom({ request, browser }, ownerName, template, 'public_chat');
    await joinRoom(request, await tokenOf({ request, browser }, memberName), roomId);
  },
);

/** "Given alex has created the invite-only moderation room {string} and invited kai": a `private_chat` room, the invitee holds a pending invitation. */
Given(
  '{word} has created the invite-only moderation room {string} and invited {word}',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, inviteeName: string) => {
    const roomId = await createModerationRoom({ request, browser }, ownerName, template, 'private_chat');
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/invite`, {
      headers: authHeaders(await tokenOf({ request, browser }, ownerName)),
      data: { user_id: userByName(inviteeName).matrixId },
    });
    expect(resp.status(), `invite answered ${resp.status()}`).toBe(200);
  },
);

/** "And marie's sync position is recorded": a full /sync; its `next_batch` is the `since` of the later incremental sync. */
Given("{word}'s sync position is recorded", async ({ request, browser }: Fixtures, userName: string) => {
  const body = await fullSync({ request, browser }, userName);
  expect(typeof body.next_batch, 'the full sync has a next_batch').toBe('string');
  syncPositions.set(userName, body.next_batch as string);
});

// ─────────────────────────────────────────────────────────────────────────────
// Moderation calls
// ─────────────────────────────────────────────────────────────────────────────

When(
  '{word} bans {word} from {string} with the reason {string}',
  async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string, reason: string) => {
    await moderate({ request, browser }, 'ban', moderatorName, targetName, template, reason);
  },
);

When('{word} unbans {word} from {string}', async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string) => {
  await moderate({ request, browser }, 'unban', moderatorName, targetName, template);
});

When(
  '{word} kicks {word} from {string} with the reason {string}',
  async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string, reason: string) => {
    await moderate({ request, browser }, 'kick', moderatorName, targetName, template, reason);
  },
);

/** "When marie joins the moderation room {string}": `POST /join` must be `200` (the unban made a public join possible again). */
When('{word} joins the moderation room {string}', async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const resp = await postJoin({ request, browser }, userName, template);
  expect(resp.status(), `join answered ${resp.status()}`).toBe(200);
});

// ─────────────────────────────────────────────────────────────────────────────
// Server-side evidence
// ─────────────────────────────────────────────────────────────────────────────

/** "Then marie's join of {string} is refused with M_FORBIDDEN and the message {string}": status 403, the exact errcode and the fixed text. */
Then(
  "{word}'s join of {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, userName: string, template: string, message: string) => {
    const resp = await postJoin({ request, browser }, userName, template);
    expect(resp.status(), 'the join is refused').toBe(403);
    const body = (await resp.json()) as { errcode?: string; error?: string };
    expect(body.errcode, 'errcode').toBe('M_FORBIDDEN');
    expect(body.error, 'the fixed refusal text').toBe(message);
  },
);

/**
 * "And marie's next sync lists {string} in rooms.leave ending with the ban event by alex with the reason {string}": ONE incremental /sync from the
 * recorded position (a second one with the same token would fall back to an initial sync, so it is never repeated): the room is in `rooms.leave`,
 * not in `rooms.join`, and its LAST timeline event is the ban event of the target (sender = the moderator, `reason`).
 */
Then(
  "{word}'s next sync lists {string} in rooms.leave ending with the ban event by {word} with the reason {string}",
  async ({ request, browser }: Fixtures, userName: string, template: string, moderatorName: string, reason: string) => {
    const since = syncPositions.get(userName);
    expect(since, 'the sync position was recorded before the ban').toBeTruthy();
    const roomId = roomIdOf(template);

    const token = await tokenOf({ request, browser }, userName);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?since=${encodeURIComponent(since as string)}&timeout=0`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(resp.status(), `incremental sync answered ${resp.status()}`).toBe(200);
    const body = (await resp.json()) as SyncBody;

    expect(Object.keys(body.rooms?.join ?? {}), 'the banned room is not in rooms.join').not.toContain(roomId);
    const events = body.rooms?.leave?.[roomId]?.timeline?.events ?? [];
    expect(events.length, 'rooms.leave carries the room with a timeline').toBeGreaterThan(0);
    const last = events[events.length - 1];
    expect({ type: last.type, state_key: last.state_key, sender: last.sender, membership: last.content?.membership, reason: last.content?.reason }).toEqual({
      type: 'm.room.member',
      state_key: userByName(userName).matrixId,
      sender: userByName(moderatorName).matrixId,
      membership: 'ban',
      reason,
    });
  },
);

/** "Then marie's latest membership in {string} is leave by alex": polled (the UI scenario writes it through Element), read by alex through /messages. */
Then(
  "{word}'s latest membership in {string} is {word} by {word}",
  async ({ request, browser }: Fixtures, targetName: string, template: string, membership: string, moderatorName: string) => {
    await expect
      .poll(
        async () => {
          const event = await latestMemberEvent({ request, browser }, moderatorName, targetName, template);
          return { membership: event?.content?.membership, sender: event?.sender };
        },
        { message: `the latest membership of ${targetName} is ${membership} by ${moderatorName}`, timeout: 30_000 },
      )
      .toEqual({ membership, sender: userByName(moderatorName).matrixId });
  },
);

/** "Then marie's latest membership in {string} is ban by alex with the reason {string}": the same, plus the exact `reason` on the event. */
Then(
  "{word}'s latest membership in {string} is {word} by {word} with the reason {string}",
  async ({ request, browser }: Fixtures, targetName: string, template: string, membership: string, moderatorName: string, reason: string) => {
    await expect
      .poll(
        async () => {
          const event = await latestMemberEvent({ request, browser }, moderatorName, targetName, template);
          return { membership: event?.content?.membership, sender: event?.sender, reason: event?.content?.reason };
        },
        { message: `the latest membership of ${targetName} is ${membership} by ${moderatorName} with the reason`, timeout: 30_000 },
      )
      .toEqual({ membership, sender: userByName(moderatorName).matrixId, reason });
  },
);

/** "Then kai's sync lists the invitation to {string}": a full /sync has the room in `rooms.invite` (polled: the invitation is written before the 200). */
Then("{word}'s sync lists the invitation to {string}", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const roomId = roomIdOf(template);
  await expect
    .poll(async () => Object.keys((await fullSync({ request, browser }, userName)).rooms?.invite ?? {}).includes(roomId), {
      message: `${userName}'s sync lists the invitation`,
      timeout: 30_000,
    })
    .toBe(true);
});

/** "Then kai's sync no longer lists an invitation to {string}": the revoked invitation is in no `rooms.invite` (nor `rooms.join`) of a full /sync. */
Then("{word}'s sync no longer lists an invitation to {string}", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const roomId = roomIdOf(template);
  await expect
    .poll(
      async () => {
        const rooms = (await fullSync({ request, browser }, userName)).rooms ?? {};
        return { invited: Object.keys(rooms.invite ?? {}).includes(roomId), joined: Object.keys(rooms.join ?? {}).includes(roomId) };
      },
      { message: `${userName}'s sync no longer lists the invitation`, timeout: 30_000 },
    )
    .toEqual({ invited: false, joined: false });
});
