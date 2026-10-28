/**
 * Step definitions for features/element/room/history-visibility.feature
 *
 * Story history-visibility-enforcement (epic oauth-broker, follow-up `es`): ONE SQL rule decides which events a member may read; a user who is invited or joins later does
 * not see the history before his invitation / join in a `joined` (since the join) or `invited` (since the invitation) room.
 *
 * Test strategy / integrity:
 *   - The API scenario sets everything up and asserts through the Matrix API with the existing session helpers (`getApiSession`, `joinRoom`): the room owner is alex, the
 *     later users are marie (hv-joined), tom (hv-invited) and kai (hv-shared). Nothing is forged: the oracle is what the SERVER produced (status codes, `/messages`,
 *     `/event`, `/search`, the initial `/sync`). The steps print nothing: not a token, not a message body; the markers are random per run and a failing assertion shows what
 *     Playwright prints for the diff. Every negative assertion has a positive control in the same response or in alex's own read.
 *   - The history of a room is played in the order of the story: "before-invite-<marker>", the invitation, "while-invited-<marker>", the join, "after-join-<marker>".
 *     A short pause (`GAP_MS`) separates the writes: the rule judges events in the SAME millisecond as an invitation / join most restrictively (D2 (c)), so the messages are
 *     separated from the member events by a clock tick like the ExUnit suites do (`tick/0`).
 *   - The UI scenario drives Element Web with marie's and kai's OWN browser contexts (a fresh OIDC login = an initial sync; the shared `page` fixture of the element-web
 *     project is alex's) and RECORDS the responses of the browser to `GET .../rooms/{roomId}/messages` (the server answer Element got is part of the evidence).
 *     UNVERIFIED against Element Web 1.12.15: its rendering at the start of a `joined` history (a "You can't see earlier messages" style notice is not asserted) and the
 *     timeline scroll selectors (`.mx_RoomView_MessageList`, `.mx_ScrollPanel`). If the first real run fails for a UI reason (Scenario 1 green, the `/messages` answer 200)
 *     the scenario moves to `@known-failure` with a new row K14 in e2e/KNOWN-FAILURES.md (cause: Element timeline pagination / selectors unverified; K13 is the
 *     membership-state UI row, K12 is named by the redaction feature, K11 is reserved by the moderation plan, K8 and K10 are retired paragraphs) and Scenario 1 stays the guard.
 *   - The rooms are registered in `roomIdByScenario` (template name -> room id) and in `histories` (the markers and the event ids of the three messages).
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

/** The clock tick between a message and a member event (the same-millisecond rule judges both of one millisecond most restrictively). */
const GAP_MS = 25;

/** How long the UI steps scroll up while Element still paginates (the story: bounded to 10 s). */
const SCROLL_BOUND_MS = 10_000;

type Fixtures = { request: APIRequestContext; browser: Browser };

type Event = {
  event_id?: string;
  type?: string;
  state_key?: string;
  sender?: string;
  content?: { body?: string; membership?: string };
};

type SyncBody = {
  rooms?: { join?: Record<string, { timeline?: { events?: Event[] } }> };
};

/** The three messages of a played history: their random markers (body = "<kind>-<marker>") and their event ids. */
type History = {
  roomId: string;
  later: string;
  before: { body: string; eventId: string };
  whileInvited: { body: string; eventId: string };
  after: { body: string; eventId: string };
};

const histories = new Map<string, History>();

/** What a user's browser got from `GET .../rooms/{roomId}/messages`, by user name. */
const recordedMessages = new Map<string, { url: string; status: number }[]>();

const contexts = new Map<string, { context: BrowserContext; page: Page }>();

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

function historyOf(template: string): History {
  const history = histories.get(template);
  if (!history) throw new Error(`History "${template}" was not played: the step that plays it must run first.`);
  return history;
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

function marker(): string {
  return Math.random().toString(36).slice(2, 10) + Math.random().toString(36).slice(2, 6);
}

async function pause(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

/** `PUT /send/m.room.message`: must be 200; returns the event id. */
async function sendMessage(f: Fixtures, userName: string, roomId: string, body: string): Promise<string> {
  const resp = await f.request.put(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${uniqueTxn()}`, {
    headers: authHeaders(await tokenOf(f, userName)),
    data: { msgtype: 'm.text', body },
  });
  expect(resp.status(), `send answered ${resp.status()}`).toBe(200);
  const eventId = ((await resp.json()) as { event_id?: string }).event_id;
  expect(typeof eventId, 'the send answer names the event').toBe('string');
  return eventId as string;
}

/** `GET /messages?dir=b&limit=50` as `userName`: the chunk (status 200 asserted) and the raw text of the answer. */
async function backwardMessages(f: Fixtures, userName: string, roomId: string): Promise<{ chunk: Event[]; raw: string }> {
  const resp = await f.request.get(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/messages?dir=b&limit=50`, {
    headers: { Authorization: `Bearer ${await tokenOf(f, userName)}` },
  });
  expect(resp.status(), `${userName}'s /messages answered ${resp.status()}`).toBe(200);
  const raw = await resp.text();
  return { chunk: ((JSON.parse(raw) as { chunk?: Event[] }).chunk ?? []), raw };
}

function messageBodies(chunk: Event[]): string[] {
  return chunk.filter((e) => e.type === 'm.room.message').map((e) => e.content?.body ?? '');
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup (through the Matrix API)
// ─────────────────────────────────────────────────────────────────────────────

/** "Given alex has created the history visibility room {string} with the setting {string}": a `private_chat` room, then `PUT /state/m.room.history_visibility`. */
Given(
  '{word} has created the history visibility room {string} with the setting {string}',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, setting: string) => {
    const token = await tokenOf({ request, browser }, ownerName);
    const name = `${template}-${Date.now()}`;
    const created = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
      headers: authHeaders(token),
      data: { name, preset: 'private_chat', visibility: 'private' },
    });
    expect(created.status(), `createRoom answered ${created.status()}`).toBe(200);
    const roomId = ((await created.json()) as { room_id: string }).room_id;
    roomIdByScenario.set(template, { roomId, actualName: name });

    await pause(GAP_MS);
    const put = await request.put(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/state/m.room.history_visibility/`, {
      headers: authHeaders(token),
      data: { history_visibility: setting },
    });
    expect(put.status(), `PUT history_visibility answered ${put.status()}`).toBe(200);
    await pause(GAP_MS);
  },
);

/**
 * "And alex has played the history of {string} with marie as the later user": "before-invite-<marker>", the invitation of the later user, "while-invited-<marker>", the
 * join of the later user, "after-join-<marker>" (a random marker per message); the three bodies and event ids are remembered for the assertions.
 */
Given(
  '{word} has played the history of {string} with {word} as the later user',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, laterName: string) => {
    const roomId = roomIdByScenario.get(template)?.roomId;
    expect(roomId, `room "${template}" is registered`).toBeTruthy();
    const room = roomId as string;
    const f = { request, browser };
    // one random marker word per message (a marker is also its search term)
    const beforeBody = `before-invite-${marker()}`;
    const beforeId = await sendMessage(f, ownerName, room, beforeBody);
    await pause(GAP_MS);

    const invited = await request.post(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(room)}/invite`, {
      headers: authHeaders(await tokenOf(f, ownerName)),
      data: { user_id: userByName(laterName).matrixId },
    });
    expect(invited.status(), `invite answered ${invited.status()}`).toBe(200);
    await pause(GAP_MS);

    const whileBody = `while-invited-${marker()}`;
    const whileId = await sendMessage(f, ownerName, room, whileBody);
    await pause(GAP_MS);

    await joinRoom(request, await tokenOf(f, laterName), room);
    await pause(GAP_MS);

    const afterBody = `after-join-${marker()}`;
    const afterId = await sendMessage(f, ownerName, room, afterBody);

    histories.set(template, {
      roomId: room,
      later: laterName,
      before: { body: beforeBody, eventId: beforeId },
      whileInvited: { body: whileBody, eventId: whileId },
      after: { body: afterBody, eventId: afterId },
    });
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Server-side evidence: /messages, /event, /search, the initial /sync
// ─────────────────────────────────────────────────────────────────────────────

/** "marie's backward messages of {string} hold the after-join message and her join but neither the before-invite nor the while-invited message". */
Then(
  "{word}'s backward messages of {string} hold the after-join message and her join but neither the before-invite nor the while-invited message",
  async ({ request, browser }: Fixtures, userName: string, template: string) => {
    const h = historyOf(template);
    const { chunk, raw } = await backwardMessages({ request, browser }, userName, h.roomId);
    const ofHistory = [h.before.body, h.whileInvited.body, h.after.body];
    expect(messageBodies(chunk).filter((b) => ofHistory.includes(b)), 'only the after-join message of the three').toEqual([h.after.body]);
    const joins = chunk.filter((e) => e.type === 'm.room.member' && e.state_key === userByName(userName).matrixId && e.content?.membership === 'join');
    expect(joins.length, `${userName}'s own join event is on the page`).toBe(1);
    for (const hidden of [h.before, h.whileInvited]) {
      expect(raw.includes(hidden.eventId), 'the response names no hidden event id').toBe(false);
      expect(raw.includes(hidden.body), 'the response carries no hidden message').toBe(false);
    }

    // positive control: the room's owner reads all three
    const owner = await backwardMessages({ request, browser }, 'alex', h.roomId);
    expect(messageBodies(owner.chunk), "alex's own page holds all three messages").toEqual(expect.arrayContaining([h.before.body, h.whileInvited.body, h.after.body]));
  },
);

/** "tom's backward messages of {string} hold the while-invited and the after-join message but not the before-invite message". */
Then(
  "{word}'s backward messages of {string} hold the while-invited and the after-join message but not the before-invite message",
  async ({ request, browser }: Fixtures, userName: string, template: string) => {
    const h = historyOf(template);
    const { chunk, raw } = await backwardMessages({ request, browser }, userName, h.roomId);
    const bodies = messageBodies(chunk);
    expect(bodies, 'the while-invited and the after-join message').toEqual(expect.arrayContaining([h.whileInvited.body, h.after.body]));
    expect(bodies, 'not the before-invite message').not.toContain(h.before.body);
    expect(raw.includes(h.before.eventId), 'the response names no hidden event id').toBe(false);
    expect(raw.includes(h.before.body), 'the response carries no hidden message').toBe(false);
  },
);

/** "kai's backward messages of {string} hold all three messages": the shared room (the positive control of the rule). */
Then("{word}'s backward messages of {string} hold all three messages", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const h = historyOf(template);
  const { chunk } = await backwardMessages({ request, browser }, userName, h.roomId);
  expect(messageBodies(chunk)).toEqual(expect.arrayContaining([h.before.body, h.whileInvited.body, h.after.body]));
});

/** "marie's GET of the before-invite event of {string} is a 404": `404 M_NOT_FOUND` with the fixed text; the owner reads the same event with 200. */
Then("{word}'s GET of the before-invite event of {string} is a 404", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const h = historyOf(template);
  const url = `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(h.roomId)}/event/${encodeURIComponent(h.before.eventId)}`;
  const resp = await request.get(url, { headers: { Authorization: `Bearer ${await tokenOf({ request, browser }, userName)}` } });
  expect(resp.status(), `/event answered ${resp.status()}`).toBe(404);
  const body = (await resp.json()) as { errcode?: string; error?: string };
  expect(body, 'the fixed 404 body').toEqual({ errcode: 'M_NOT_FOUND', error: 'Event not found' });

  const control = await request.get(url, { headers: { Authorization: `Bearer ${await tokenOf({ request, browser }, 'alex')}` } });
  expect(control.status(), "positive control: alex reads the same event").toBe(200);
});

async function searchResults(f: Fixtures, userName: string, term: string): Promise<{ results: { result?: { event_id?: string } }[]; raw: string }> {
  const resp = await f.request.post(`${MATRIX_BASE}/_matrix/client/v3/search`, {
    headers: authHeaders(await tokenOf(f, userName)),
    data: { search_categories: { room_events: { search_term: term, filter: { limit: 20 } } } },
  });
  expect(resp.status(), `search answered ${resp.status()}`).toBe(200);
  const raw = await resp.text();
  const body = JSON.parse(raw) as { search_categories?: { room_events?: { results?: { result?: { event_id?: string } }[] } } };
  return { results: body.search_categories?.room_events?.results ?? [], raw };
}

/** The marker word of the before-invite message ("before-invite-<marker>": the marker is the search term, a single token). */
function beforeMarker(h: History): string {
  return h.before.body.replace('before-invite-', '');
}

/** "marie's search for the before-invite marker of {string} finds nothing". */
Then("{word}'s search for the before-invite marker of {string} finds nothing", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const h = historyOf(template);
  const { results, raw } = await searchResults({ request, browser }, userName, beforeMarker(h));
  expect(results, 'no result for a message sent before the invitation').toEqual([]);
  expect(raw.includes(h.before.eventId), 'the response names no hidden event id').toBe(false);
});

/** "alex's search for the before-invite marker of {string} finds one result": the positive control of the search filter. */
Then("{word}'s search for the before-invite marker of {string} finds one result", async ({ request, browser }: Fixtures, userName: string, template: string) => {
  const h = historyOf(template);
  const { results } = await searchResults({ request, browser }, userName, beforeMarker(h));
  expect(results.map((r) => r.result?.event_id)).toEqual([h.before.eventId]);
});

/** "marie's initial sync timeline of {string} holds neither the before-invite nor the while-invited event": a FULL /sync, the room's join timeline. */
Then(
  "{word}'s initial sync timeline of {string} holds neither the before-invite nor the while-invited event",
  async ({ request, browser }: Fixtures, userName: string, template: string) => {
    const h = historyOf(template);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, {
      headers: { Authorization: `Bearer ${await tokenOf({ request, browser }, userName)}` },
    });
    expect(resp.status(), `initial sync answered ${resp.status()}`).toBe(200);
    const raw = await resp.text();
    const timeline = (JSON.parse(raw) as SyncBody).rooms?.join?.[h.roomId]?.timeline?.events ?? [];
    const ids = timeline.map((e) => e.event_id);
    expect(ids, 'positive control: the after-join message is on the timeline').toContain(h.after.eventId);
    expect(ids).not.toContain(h.before.eventId);
    expect(ids).not.toContain(h.whileInvited.eventId);
    expect(raw.includes(h.before.body) || raw.includes(h.whileInvited.body), 'no hidden message text anywhere in the sync').toBe(false);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// The Element Web scenario (the later users' own browser contexts)
// ─────────────────────────────────────────────────────────────────────────────

async function loginInOwnContext(browser: Browser, userName: string): Promise<void> {
  const user = userByName(userName);
  const context = await browser.newContext();
  const page = await context.newPage();
  const recorded: { url: string; status: number }[] = [];
  recordedMessages.set(userName, recorded);
  page.on('response', (response) => {
    const url = response.url();
    if (/\/_matrix\/client\/v3\/rooms\/[^/]+\/messages(\?|$)/.test(url)) recorded.push({ url, status: response.status() });
  });
  await loginViaOidcBrowser(page, user, user.email, DEX_TEST_PASSWORD);
  contexts.set(userName, { context, page });
}

/** "Given marie is logged in via Element Web in a history visibility context of her own with her requests recorded": a fresh OIDC login, the `/messages` responses recorded. */
Given('{word} is logged in via Element Web in a history visibility context of her own with her requests recorded', async ({ browser }: { browser: Browser }, userName: string) => {
  await loginInOwnContext(browser, userName);
});

/** "Given kai is logged in via Element Web in a history visibility context of his own". */
Given('{word} is logged in via Element Web in a history visibility context of his own', async ({ browser }: { browser: Browser }, userName: string) => {
  await loginInOwnContext(browser, userName);
});

function pageOf(userName: string): Page {
  const entry = contexts.get(userName);
  if (!entry) throw new Error(`${userName} has no Element Web page: the login step must run first.`);
  return entry.page;
}

/**
 * "When marie opens the history visibility room {string} in Element Web and scrolls to the top": direct URL navigation by room id, the managed-E2EE key-setup dialog is
 * dismissed; then the message panel is scrolled to the top until Element stops paginating (no new `/messages` response for two polls), bounded to 10 s.
 */
When(
  '{word} opens the history visibility room {string} in Element Web and scrolls to the top',
  async ({}: object, userName: string, template: string) => {
    const page = pageOf(userName);
    const h = historyOf(template);
    await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(h.roomId)}`);
    await dismissKeySetupDialog(page);
    const composer = page.locator('.mx_BasicMessageComposer_input').or(page.locator('.mx_SendMessageComposer [contenteditable="true"]')).first();
    await expect(composer).toBeVisible({ timeout: 30_000 });
    await dismissKeySetupDialog(page);

    // the newest text is on screen first: the after-join message of the later user's history
    await expect(page.getByText(h.after.body).first(), 'the after-join text is shown').toBeVisible({ timeout: 30_000 });

    const recorded = recordedMessages.get(userName) ?? [];
    const panel = page.locator('.mx_RoomView_MessageList').or(page.locator('.mx_ScrollPanel')).first();
    const deadline = Date.now() + SCROLL_BOUND_MS;
    let stableRounds = 0;
    let seen = recorded.length;
    while (Date.now() < deadline && stableRounds < 2) {
      await panel.evaluate((el) => {
        const scroller = el.closest('.mx_ScrollPanel') ?? el;
        (scroller as HTMLElement).scrollTop = 0;
      });
      await pause(500);
      if (recorded.length === seen) stableRounds += 1;
      else {
        stableRounds = 0;
        seen = recorded.length;
      }
    }
  },
);

/** "Then marie's timeline of {string} shows the after-join text and neither the before-invite nor the while-invited text". */
Then(
  "{word}'s timeline of {string} shows the after-join text and neither the before-invite nor the while-invited text",
  async ({}: object, userName: string, template: string) => {
    const page = pageOf(userName);
    const h = historyOf(template);
    await expect(page.getByText(h.after.body).first(), 'the after-join text is shown').toBeVisible({ timeout: 30_000 });
    await expect(page.getByText(h.before.body), 'the before-invite text is not in the timeline').toHaveCount(0);
    await expect(page.getByText(h.whileInvited.body), 'the while-invited text is not in the timeline').toHaveCount(0);
  },
);

/**
 * "And every /messages answer marie's Element got for {string} was a 200": NON-BLOCKING evidence from the browser's own network log (the server answer Element got): every
 * recorded `GET .../messages?...dir=b` answer for the room is a 200 and none is a 5xx; zero recorded calls are tolerated (Element may need none) and the count is logged.
 * The API scenario carries the hard `/messages` 200 assertions.
 */
Then("every messages answer {word}'s Element got for {string} was a 200", async ({}: object, userName: string, template: string) => {
  const h = historyOf(template);
  const recorded = recordedMessages.get(userName) ?? [];
  const forRoom = recorded.filter((r) => decodeURIComponent(r.url).includes(`/rooms/${h.roomId}/messages`) && r.url.includes('dir=b'));
  console.log(`[history-visibility] ${userName}'s Element made ${forRoom.length} backward /messages request(s) for ${template}`);
  expect(forRoom.filter((r) => r.status !== 200).map((r) => r.status), 'every recorded /messages answer for the room is a 200').toEqual([]);
  expect(recorded.filter((r) => r.status >= 500).map((r) => r.status), 'no /messages answer is a 5xx').toEqual([]);
});

/** "Then kai's timeline of {string} shows all three texts": the positive control (Element paginates in the shared room). */
Then("{word}'s timeline of {string} shows all three texts", async ({}: object, userName: string, template: string) => {
  const page = pageOf(userName);
  const h = historyOf(template);
  for (const text of [h.before.body, h.whileInvited.body, h.after.body]) {
    await expect(page.getByText(text).first(), 'the text is shown in the shared room').toBeVisible({ timeout: 30_000 });
  }
});

After(async () => {
  for (const { context } of contexts.values()) await context.close().catch(() => undefined);
  contexts.clear();
  recordedMessages.clear();
});
