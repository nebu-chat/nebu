/**
 * Step definitions for features/element/room/membership-state.feature
 *
 * Story membership-state-model (epic oauth-broker, follow-ups `fb`, `fl` (c)): the member state of the initial `/sync`, `GET /rooms/{roomId}/members`
 * (`membership` / `not_membership` / `at`) and the real invite events of `POST /rooms/{roomId}/upgrade`.
 *
 * Test strategy / integrity:
 *   - The API scenario sets everything up and asserts through the Matrix API with the existing session helpers (`getApiSession`, `joinRoom`): the room owner is
 *     alex, the members are marie and tom, the invitee is kai. Nothing is forged: the oracle is what the SERVER produced (status codes, errcodes, `/sync`,
 *     `/members`). The steps print nothing: not a token, not a ban reason, not a message body; a failing assertion shows what Playwright prints for the diff.
 *   - The 25 messages after the invitation and the ban put every member event OUTSIDE the 20-event window of an initial `/sync`: the member state can only come from
 *     the state block (and `/members`), never from the timeline.
 *   - The UI scenario drives Element Web with marie's OWN browser context (a fresh OIDC login = an initial sync; the shared `page` fixture of the element-web
 *     project is alex's): the step logs marie in through `loginViaOidcBrowser` like the fixtures do and RECORDS the responses of her browser to
 *     `GET .../rooms/{roomId}/members`, so the server answer Element got is part of the evidence. UNVERIFIED against Element Web 1.12.15: the selectors of the
 *     room info / People panel and of the settings dialog tab (the story verified the TEXTS in the bundle, not the DOM). If the first real run fails for a UI
 *     reason the scenario moves to `@known-failure` with a new row K13 in e2e/KNOWN-FAILURES.md (cause: Element room-info / settings selectors unverified) and the API
 *     scenario stays the guard; K8 and K10 are retired paragraphs of that file, K11 is reserved by the moderation plan, K12 by the redaction feature.
 *   - The rooms are registered in `roomIdByScenario` (template name -> room id); the replacement room of an upgrade as "<template> (new)".
 *   - Module-level state is safe with workers: 1 (see playwright.config.ts).
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, BrowserContext, Page } from '@playwright/test';
import { getApiSession, joinRoom, loginViaOidcBrowser } from '../../fixtures/dex-auth';
import { DEX_TEST_PASSWORD, NEBU_USERS, type NebUser } from '../../fixtures/users';
import { roomIdByScenario } from '../common/room-setup.steps';
import { dismissKeySetupDialog } from '../common/navigation.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const ELEMENT_URL = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';

type Fixtures = { request: APIRequestContext; browser: Browser };

type StateEvent = {
  event_id?: string;
  type?: string;
  state_key?: string;
  sender?: string;
  content?: { membership?: string; reason?: string };
};

type SyncBody = {
  next_batch?: string;
  rooms?: {
    join?: Record<string, { state?: { events?: StateEvent[] } }>;
    invite?: Record<string, { invite_state?: { events?: StateEvent[] } }>;
  };
};

/** The `next_batch` of a user's recorded initial sync, by user name (a full /sync replaces the stored token of the user: follow-up `fd`). */
const syncTokens = new Map<string, string>();

/** What marie's browser got from `GET .../rooms/{roomId}/members` while Element Web was open. */
const recordedMembers: { url: string; status: number }[] = [];

let marieContext: BrowserContext | undefined;
let mariePage: Page | undefined;

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

function roomIdOf(template: string): string {
  const entry = roomIdByScenario.get(template);
  if (!entry) throw new Error(`Room "${template}" is not registered: the step that creates the membership room must run first.`);
  return entry.roomId;
}

async function tokenOf(f: Fixtures, userName: string): Promise<string> {
  return (await getApiSession(f.request, userByName(userName), f.browser)).token;
}

function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

function uniqueTxn(): string {
  return `e2e-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/** `GET /rooms/{roomId}/members?<query>` as `userName`: the raw response (callers assert the status). */
async function getMembers(f: Fixtures, userName: string, roomId: string, query: string) {
  return f.request.get(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/members${query === '' ? '' : `?${query}`}`, {
    headers: { Authorization: `Bearer ${await tokenOf(f, userName)}` },
  });
}

/** The `user:membership` pairs of a `/members` chunk, sorted. */
function pairsOf(chunk: StateEvent[]): string[] {
  return chunk.map((e) => `${e.state_key}:${e.content?.membership}`).sort();
}

function pairList(...entries: [string, string][]): string[] {
  return entries.map(([name, membership]) => `${userByName(name).matrixId}:${membership}`).sort();
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup (through the Matrix API)
// ─────────────────────────────────────────────────────────────────────────────

/** "Given alex has created the public membership room {string} and {string} have joined it": a `public_chat` room, the members join through the API. */
Given(
  '{word} has created the public membership room {string} and {string} have joined it',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, memberNames: string) => {
    const token = await tokenOf({ request, browser }, ownerName);
    const name = `${template}-${Date.now()}`;
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
      headers: authHeaders(token),
      data: { name, preset: 'public_chat', visibility: 'private' },
    });
    expect(resp.status(), `createRoom answered ${resp.status()}`).toBe(200);
    const roomId = ((await resp.json()) as { room_id: string }).room_id;
    roomIdByScenario.set(template, { roomId, actualName: name });
    for (const memberName of memberNames.split(',').map((n) => n.trim()).filter((n) => n !== '')) {
      await joinRoom(request, await tokenOf({ request, browser }, memberName), roomId);
    }
  },
);

/** "And alex has invited kai to the membership room {string}": `POST /invite` must be `200`. */
Given(
  '{word} has invited {word} to the membership room {string}',
  async ({ request, browser }: Fixtures, ownerName: string, inviteeName: string, template: string) => {
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/invite`, {
      headers: authHeaders(await tokenOf({ request, browser }, ownerName)),
      data: { user_id: userByName(inviteeName).matrixId },
    });
    expect(resp.status(), `invite answered ${resp.status()}`).toBe(200);
  },
);

/** "And alex has banned tom from the membership room {string} with the reason {string}": `POST /ban` must be `200 {}`. */
Given(
  '{word} has banned {word} from the membership room {string} with the reason {string}',
  async ({ request, browser }: Fixtures, moderatorName: string, targetName: string, template: string, reason: string) => {
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/ban`, {
      headers: authHeaders(await tokenOf({ request, browser }, moderatorName)),
      data: { user_id: userByName(targetName).matrixId, reason },
    });
    expect(resp.status(), `ban answered ${resp.status()}`).toBe(200);
    expect(await resp.json(), 'ban answers an empty JSON object').toEqual({});
  },
);

/** "And alex has sent 25 messages in the membership room {string}": the member events fall out of the 20-event window of an initial sync. */
Given(
  '{word} has sent {int} messages in the membership room {string}',
  async ({ request, browser }: Fixtures, userName: string, count: number, template: string) => {
    const roomId = roomIdOf(template);
    const token = await tokenOf({ request, browser }, userName);
    for (let i = 0; i < count; i++) {
      const resp = await request.put(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${uniqueTxn()}`, {
        headers: authHeaders(token),
        data: { msgtype: 'm.text', body: `e2e membership filler ${i}` },
      });
      expect(resp.status(), `send ${i} answered ${resp.status()}`).toBe(200);
    }
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Server-side evidence: the initial /sync and GET /members
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Then marie's initial sync of {string} lists kai as invite by alex and tom as ban by alex with the reason {string}, both with real event ids": a FULL /sync
 * (no since): the state block of the room has the invitee's and the banned user's latest member event, the stored sender and reason, a real event id
 * (never a `$synth_` placeholder). Its `next_batch` is recorded for the `at` / `since` of the later steps.
 */
Then(
  "{word}'s initial sync of {string} lists {word} as invite by {word} and {word} as ban by {word} with the reason {string}, both with real event ids",
  async (
    { request, browser }: Fixtures,
    userName: string,
    template: string,
    inviteeName: string,
    inviterName: string,
    bannedName: string,
    bannerName: string,
    reason: string,
  ) => {
    const token = await tokenOf({ request, browser }, userName);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, { headers: { Authorization: `Bearer ${token}` } });
    expect(resp.status(), `initial sync answered ${resp.status()}`).toBe(200);
    const body = (await resp.json()) as SyncBody;
    expect(typeof body.next_batch, 'the initial sync has a next_batch').toBe('string');
    syncTokens.set(userName, body.next_batch as string);

    const roomId = roomIdOf(template);
    const state = body.rooms?.join?.[roomId]?.state?.events ?? [];
    const slot = (name: string): StateEvent | undefined => state.find((e) => e.type === 'm.room.member' && e.state_key === userByName(name).matrixId);

    const invite = slot(inviteeName);
    expect({ membership: invite?.content?.membership, sender: invite?.sender }, `${inviteeName}'s member slot`).toEqual({
      membership: 'invite',
      sender: userByName(inviterName).matrixId,
    });
    const ban = slot(bannedName);
    expect({ membership: ban?.content?.membership, sender: ban?.sender, reason: ban?.content?.reason }, `${bannedName}'s member slot`).toEqual({
      membership: 'ban',
      sender: userByName(bannerName).matrixId,
      reason,
    });
    for (const ev of [invite, ban]) {
      expect(ev?.event_id, 'a real event id').toMatch(/^\$/);
      expect(ev?.event_id, 'never a synthesized id').not.toMatch(/^\$synth_/);
    }
  },
);

/** "And marie's members of {string} with not_membership leave at her sync token are alex join, marie join, kai invite and tom ban": Element's own request. */
Then(
  "{word}'s members of {string} with not_membership leave at her sync token are {word} join, {word} join, {word} invite and {word} ban",
  async ({ request, browser }: Fixtures, userName: string, template: string, joinA: string, joinB: string, invited: string, banned: string) => {
    const at = syncTokens.get(userName);
    expect(at, 'the initial sync was recorded before').toBeTruthy();
    const resp = await getMembers({ request, browser }, userName, roomIdOf(template), `not_membership=leave&at=${encodeURIComponent(at as string)}`);
    expect(resp.status(), `/members answered ${resp.status()}`).toBe(200);
    const chunk = ((await resp.json()) as { chunk?: StateEvent[] }).chunk ?? [];
    expect(pairsOf(chunk)).toEqual(pairList([joinA, 'join'], [joinB, 'join'], [invited, 'invite'], [banned, 'ban']));
    for (const ev of chunk) expect(ev.event_id, 'a real event id').toMatch(/^\$(?!synth_)/);
  },
);

/** "And marie's members of {string} with membership ban are tom only". */
Then("{word}'s members of {string} with membership ban are {word} only", async ({ request, browser }: Fixtures, userName: string, template: string, bannedName: string) => {
  const resp = await getMembers({ request, browser }, userName, roomIdOf(template), 'membership=ban');
  expect(resp.status(), `/members answered ${resp.status()}`).toBe(200);
  const chunk = ((await resp.json()) as { chunk?: StateEvent[] }).chunk ?? [];
  expect(pairsOf(chunk)).toEqual(pairList([bannedName, 'ban']));
});

/** "And tom's members request for {string} is refused with M_FORBIDDEN": a banned user (and an invitee) gets 403 and the fixed text. */
Then("{word}'s members request for {string} is refused with M_FORBIDDEN", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const resp = await getMembers({ request, browser }, userName, roomIdOf(template), '');
  expect(resp.status(), `${userName}'s /members is refused`).toBe(403);
  const body = (await resp.json()) as { errcode?: string; error?: string };
  expect(body.errcode, 'errcode').toBe('M_FORBIDDEN');
  expect(body.error, 'the fixed refusal text').toBe('You are not a member of this room');
});

// ─────────────────────────────────────────────────────────────────────────────
// The upgrade
// ─────────────────────────────────────────────────────────────────────────────

/** "When alex upgrades the membership room {string}": `POST /upgrade` must be `200`; the replacement room is registered as "<template> (new)". */
When('{word} upgrades the membership room {string}', async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomIdOf(template))}/upgrade`, {
    headers: authHeaders(await tokenOf({ request, browser }, userName)),
    data: { new_version: '10' },
  });
  expect(resp.status(), `upgrade answered ${resp.status()}`).toBe(200);
  const replacement = ((await resp.json()) as { replacement_room?: string }).replacement_room;
  expect(typeof replacement, 'the answer names the replacement room').toBe('string');
  roomIdByScenario.set(`${template} (new)`, { roomId: replacement as string, actualName: `${template} (new)` });
});

/**
 * "Then marie's next sync lists the new room of {string} in rooms.invite with the invite event by alex in its invite_state": ONE incremental /sync from the recorded
 * token (a second one with the same token would fall back to an initial sync, so it is never repeated).
 */
Then(
  "{word}'s next sync lists the new room of {string} in rooms.invite with the invite event by {word} in its invite_state",
  async ({ request, browser }: Fixtures, userName: string, template: string, inviterName: string) => {
    const since = syncTokens.get(userName);
    expect(since, 'the initial sync was recorded before the upgrade').toBeTruthy();
    const token = await tokenOf({ request, browser }, userName);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?since=${encodeURIComponent(since as string)}&timeout=0`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(resp.status(), `incremental sync answered ${resp.status()}`).toBe(200);
    const body = (await resp.json()) as SyncBody;

    const newRoom = roomIdOf(`${template} (new)`);
    const events = body.rooms?.invite?.[newRoom]?.invite_state?.events ?? [];
    expect(events.length, 'the new room is in rooms.invite with stripped state').toBeGreaterThan(0);
    const own = events.find((e) => e.type === 'm.room.member' && e.state_key === userByName(userName).matrixId);
    expect({ membership: own?.content?.membership, sender: own?.sender }, "the invitee's own invite event").toEqual({
      membership: 'invite',
      sender: userByName(inviterName).matrixId,
    });
  },
);

/** "And alex's members of the new room of {string} with membership invite are marie only": the old member was invited by an event, listed by the new room's /members. */
Then(
  "{word}'s members of the new room of {string} with membership invite are {word} only",
  async ({ request, browser }: Fixtures, userName: string, template: string, inviteeName: string) => {
    const resp = await getMembers({ request, browser }, userName, roomIdOf(`${template} (new)`), 'membership=invite');
    expect(resp.status(), `/members answered ${resp.status()}`).toBe(200);
    const chunk = ((await resp.json()) as { chunk?: StateEvent[] }).chunk ?? [];
    expect(pairsOf(chunk)).toEqual(pairList([inviteeName, 'invite']));
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// The Element Web scenario (marie's own browser context)
// ─────────────────────────────────────────────────────────────────────────────

/** "Given marie is logged in via Element Web in a context of her own with her requests recorded": a fresh OIDC login; the `/members` responses of the browser are recorded. */
Given('{word} is logged in via Element Web in a context of her own with her requests recorded', async ({ browser }: { browser: Browser }, userName: string) => {
  const user = userByName(userName);
  recordedMembers.length = 0;
  marieContext = await browser.newContext();
  mariePage = await marieContext.newPage();
  mariePage.on('response', (response) => {
    const url = response.url();
    if (/\/_matrix\/client\/v3\/rooms\/[^/]+\/members(\?|$)/.test(url)) recordedMembers.push({ url, status: response.status() });
  });
  await loginViaOidcBrowser(mariePage, user, user.email, DEX_TEST_PASSWORD);
});

function pageOfMarie(): Page {
  if (!mariePage) throw new Error('marie has no Element Web page: the login step must run first.');
  return mariePage;
}

/** "When marie opens the membership room {string} in Element Web": direct URL navigation by room id, the managed-E2EE key-setup dialog is dismissed. */
When('{word} opens the membership room {string} in Element Web', async ({}: object, _userName: string, template: string) => {
  const page = pageOfMarie();
  await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(roomIdOf(template))}`);
  await dismissKeySetupDialog(page);
  const composer = page.locator('.mx_BasicMessageComposer_input').or(page.locator('.mx_SendMessageComposer [contenteditable="true"]')).first();
  await expect(composer).toBeVisible({ timeout: 30_000 });
  await dismissKeySetupDialog(page);
});

/** "And marie opens the People panel of the room": the header's "Room info" button, then the "People" entry. UNVERIFIED selectors (see the header). */
When('{word} opens the People panel of the room', async ({}: object, _userName: string) => {
  const page = pageOfMarie();
  await page.getByRole('button', { name: 'Room info' }).first().click({ timeout: 15_000 });
  await page
    .getByRole('menuitem', { name: /People/ })
    .or(page.getByRole('button', { name: /People/ }))
    .or(page.getByText('People', { exact: true }))
    .first()
    .click({ timeout: 15_000 });
});

/** "Then the People panel lists kai under {string}": the "Invited" section label is visible and the invitee is listed (polled: the member list loads lazily). */
Then('the People panel lists {word} under {string}', async ({}: object, inviteeName: string, section: string) => {
  const page = pageOfMarie();
  await expect(page.getByText(section, { exact: true }).first(), `the "${section}" section is shown`).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText(new RegExp(inviteeName)).first(), `${inviteeName} is listed`).toBeVisible({ timeout: 30_000 });
});

/** "When marie opens the room settings tab {string}": the "Room info" card's "Settings" entry, then the tab. UNVERIFIED selectors (see the header). */
When('{word} opens the room settings tab {string}', async ({}: object, _userName: string, tab: string) => {
  const page = pageOfMarie();
  // the room info panel may still be open from the People step: open it only when the "Settings" entry is not visible yet
  const settings = page.getByRole('menuitem', { name: 'Settings' }).or(page.getByRole('button', { name: 'Settings' })).first();
  if (!(await settings.isVisible())) {
    await page.getByRole('button', { name: 'Room info' }).first().click({ timeout: 15_000 });
  }
  await settings.click({ timeout: 15_000 });
  await page.getByRole('tab', { name: tab }).click({ timeout: 15_000 });
});

/** "Then the {string} list shows tom with the reason {string}": the fieldset of the settings tab lists the banned user with "Reason: <reason>". */
Then('the {string} list shows {word} with the reason {string}', async ({}: object, listName: string, bannedName: string, reason: string) => {
  const page = pageOfMarie();
  const list = page.getByRole('group', { name: listName });
  await expect(list, `the "${listName}" list is shown`).toBeVisible({ timeout: 30_000 });
  await expect(list.getByText(new RegExp(bannedName)).first(), `${bannedName} is listed`).toBeVisible({ timeout: 30_000 });
  await expect(list.getByText(`Reason: ${reason}`), 'the stored reason of the ban').toBeVisible({ timeout: 30_000 });
});

/** "And marie's Element requested the members of {string} with not_membership leave and got 200": the browser's own network log (the server answer Element got). */
Then(
  "{word}'s Element requested the members of {string} with not_membership leave and got 200",
  async ({}: object, _userName: string, template: string) => {
    const roomId = roomIdOf(template);
    await expect
      .poll(
        () =>
          recordedMembers
            .filter((r) => decodeURIComponent(r.url).includes(`/rooms/${roomId}/members`) && r.url.includes('not_membership=leave'))
            .map((r) => r.status),
        { message: "Element's /members?not_membership=leave request was answered", timeout: 30_000 },
      )
      .toContain(200);
    expect(recordedMembers.filter((r) => r.status >= 500).map((r) => r.status), 'no /members answer is a 5xx').toEqual([]);
  },
);

After(async () => {
  if (marieContext) {
    await marieContext.close().catch(() => undefined);
    marieContext = undefined;
    mariePage = undefined;
  }
});
