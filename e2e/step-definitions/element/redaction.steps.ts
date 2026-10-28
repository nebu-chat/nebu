/**
 * Step definitions for features/element/room/redaction.feature
 *
 * Story state-writer-redaction (epic oauth-broker, follow-ups `fw`, `fv`, `fz`, `fx`): `PUT /rooms/{roomId}/redact/{eventId}/{txnId}`, `m.room.redaction` on
 * `/send` through the same room-process writer, the redact level, and a redacted event served pruned (`content: {}`, `unsigned.redacted_because`) on every client
 * read path.
 *
 * Test strategy / integrity:
 *   - The API scenario sets everything up and asserts through the Matrix API with the existing session helpers (`getApiSession`, `joinRoom`): the administrator is
 *     alex, the members are marie, tom and kai. Nothing is forged: the oracle is what the SERVER produced (status codes, errcodes, the fixed refusal texts,
 *     `/sync`, `GET /event`, `POST /search`).
 *   - A message carries a unique marker word (`mk<random>`), the one token the search step looks for. The steps print nothing: not a token, not a message body,
 *     not a reason; a failing assertion shows what Playwright prints for the diff.
 *   - The UI scenario drives Element Web with tom's OWN browser context (the shared `page` fixture of the element-web project is alex's, the second context is
 *     marie's): the step logs tom in through `loginViaOidcBrowser` like the fixtures do, opens the room by id, hovers his own message tile, opens its options,
 *     clicks "Remove" and confirms with the dialog's "Remove" button; everything is asserted SERVER-side (kai's GET of the event), so an Element-side change of
 *     the message options never weakens the assertion. UNVERIFIED against Element 1.12.15: the tile hover / "Options" button selectors and the accessible
 *     names of the menu item and the dialog button (the story verified the TEXTS in the bundle, not the DOM); the first real run is the evidence (KNOWN-FAILURES.md
 *     K12 when it fails for a UI reason).
 *   - The rooms are registered in `roomIdByScenario` (template name -> room id), the messages in `redactionMessages` (name -> event id and marker word).
 *   - Module-level state is safe with workers: 1 (see playwright.config.ts).
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse, Browser, BrowserContext, Page } from '@playwright/test';
import { getApiSession, joinRoom, loginViaOidcBrowser } from '../../fixtures/dex-auth';
import { DEX_TEST_PASSWORD, NEBU_USERS, type NebUser } from '../../fixtures/users';
import { roomIdByScenario } from '../common/room-setup.steps';
import { dismissKeySetupDialog } from '../common/navigation.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const ELEMENT_URL = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';

type Fixtures = { request: APIRequestContext; browser: Browser };

type ServedEvent = {
  event_id?: string;
  type?: string;
  sender?: string;
  redacts?: string;
  content?: Record<string, unknown>;
  unsigned?: { redacted_because?: { sender?: string; redacts?: string; content?: Record<string, unknown>; event_id?: string; type?: string } };
};

type SyncBody = { rooms?: { join?: Record<string, { timeline?: { events?: ServedEvent[] } }> } };

/** The messages a scenario sent: remembered name -> event id and the unique marker word inside the body. */
const redactionMessages = new Map<string, { eventId: string; marker: string; roomId: string }>();

/** The redaction events a scenario's redactions produced: remembered by the NAME of the target message. */
const redactionIds = new Map<string, string>();

let tomContext: BrowserContext | undefined;
let tomPage: Page | undefined;

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

function roomIdOf(template: string): string {
  const entry = roomIdByScenario.get(template);
  if (!entry) throw new Error(`Room "${template}" is not registered: the step that creates the redaction room must run first.`);
  return entry.roomId;
}

function messageOf(name: string): { eventId: string; marker: string; roomId: string } {
  const message = redactionMessages.get(name);
  if (!message) throw new Error(`Message "${name}" is not remembered: the step that sends it must run first.`);
  return message;
}

async function tokenOf(f: Fixtures, userName: string): Promise<string> {
  return (await getApiSession(f.request, userByName(userName), f.browser)).token;
}

function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
}

function eventUrl(roomId: string, eventId: string): string {
  return `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/event/${encodeURIComponent(eventId)}`;
}

function uniqueTxn(): string {
  return `e2e-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/** `PUT .../redact/{eventId}/{txnId}` with an optional reason. */
async function putRedaction(f: Fixtures, userName: string, roomId: string, eventId: string, reason?: string): Promise<APIResponse> {
  return f.request.put(
    `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/redact/${encodeURIComponent(eventId)}/${uniqueTxn()}`,
    { headers: authHeaders(await tokenOf(f, userName)), data: reason === undefined ? {} : { reason } },
  );
}

/** Asserts a refusal: status 403, errcode `M_FORBIDDEN` and the exact fixed text. */
async function expectForbidden(resp: APIResponse, what: string, message: string): Promise<void> {
  expect(resp.status(), `${what} is refused`).toBe(403);
  const body = (await resp.json()) as { errcode?: string; error?: string };
  expect(body.errcode, `${what}: errcode`).toBe('M_FORBIDDEN');
  expect(body.error, `${what}: the fixed refusal text`).toBe(message);
}

async function getEvent(f: Fixtures, userName: string, roomId: string, eventId: string): Promise<ServedEvent> {
  const resp = await f.request.get(eventUrl(roomId, eventId), { headers: { Authorization: `Bearer ${await tokenOf(f, userName)}` } });
  expect(resp.status(), `GET /event answered ${resp.status()}`).toBe(200);
  return (await resp.json()) as ServedEvent;
}

/** The event ids kai's `POST /search` returns for `term`. */
async function searchIds(f: Fixtures, userName: string, term: string): Promise<string[]> {
  const resp = await f.request.post(`${MATRIX_BASE}/_matrix/client/v3/search`, {
    headers: authHeaders(await tokenOf(f, userName)),
    data: { search_categories: { room_events: { search_term: term, filter: { limit: 20 } } } },
  });
  expect(resp.status(), `search answered ${resp.status()}`).toBe(200);
  const body = (await resp.json()) as { search_categories?: { room_events?: { results?: { result?: { event_id?: string } }[] } } };
  return (body.search_categories?.room_events?.results ?? []).map((r) => r.result?.event_id ?? '');
}

// ─────────────────────────────────────────────────────────────────────────────
// Setup
// ─────────────────────────────────────────────────────────────────────────────

/** "Given alex has created the public redaction room {string} and {string} have joined it": a `public_chat` room with a topic (the topic event is a state event to redact), the members join through the API. */
Given(
  '{word} has created the public redaction room {string} and {string} have joined it',
  async ({ request, browser }: Fixtures, ownerName: string, template: string, memberNames: string) => {
    const token = await tokenOf({ request, browser }, ownerName);
    const name = `${template}-${Date.now()}`;
    const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
      headers: authHeaders(token),
      data: { name, topic: 'redaction e2e', preset: 'public_chat', visibility: 'private' },
    });
    expect(resp.status(), `createRoom answered ${resp.status()}`).toBe(200);
    const roomId = ((await resp.json()) as { room_id: string }).room_id;
    roomIdByScenario.set(template, { roomId, actualName: name });
    for (const memberName of memberNames.split(',').map((n) => n.trim()).filter((n) => n !== '')) {
      await joinRoom(request, await tokenOf({ request, browser }, memberName), roomId);
    }
  },
);

/** "Given marie has sent a message in the redaction room {string} remembered as {string}": a text message with a unique marker word; its event id is remembered. */
Given(
  '{word} has sent a message in the redaction room {string} remembered as {string}',
  async ({ request, browser }: Fixtures, userName: string, template: string, name: string) => {
    const roomId = roomIdOf(template);
    const marker = `mk${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
    const resp = await request.put(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/send/m.room.message/${uniqueTxn()}`,
      { headers: authHeaders(await tokenOf({ request, browser }, userName)), data: { msgtype: 'm.text', body: `e2e redaction ${name} ${marker}` } },
    );
    expect(resp.status(), `${userName}'s send answered ${resp.status()}`).toBe(200);
    const eventId = ((await resp.json()) as { event_id?: string }).event_id;
    expect(typeof eventId, 'the answer carries an event_id').toBe('string');
    redactionMessages.set(name, { eventId: eventId as string, marker, roomId });
  },
);

/** "Given kai's search for the marker word of {string} finds the message {string}": the positive control of the search assertion (before the redaction). */
Given(
  "{word}'s search for the marker word of {string} finds the message {string}",
  async ({ request, browser }: Fixtures, userName: string, name: string, expectedName: string) => {
    const { marker } = messageOf(name);
    await expect
      .poll(async () => searchIds({ request, browser }, userName, marker), { message: `${userName}'s search finds ${expectedName} before the redaction`, timeout: 15_000 })
      .toEqual([messageOf(expectedName).eventId]);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Redactions (the committed ones)
// ─────────────────────────────────────────────────────────────────────────────

/** "When marie redacts {string} in the redaction room {string} with the reason {string}": `PUT /redact` must be `200 {event_id}`. */
When(
  '{word} redacts {string} in the redaction room {string} with the reason {string}',
  async ({ request, browser }: Fixtures, userName: string, name: string, template: string, reason: string) => {
    const message = messageOf(name);
    expect(message.roomId, 'the message belongs to the room').toBe(roomIdOf(template));
    const resp = await putRedaction({ request, browser }, userName, message.roomId, message.eventId, reason);
    expect(resp.status(), `${userName}'s redaction of ${name} answered ${resp.status()}`).toBe(200);
    const body = (await resp.json()) as { event_id?: string };
    expect(Object.keys(body), 'the answer is exactly {event_id}').toEqual(['event_id']);
    expect(typeof body.event_id, 'the answer carries an event_id').toBe('string');
    redactionIds.set(name, body.event_id as string);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Refusals
// ─────────────────────────────────────────────────────────────────────────────

/** "Then marie's attempt to redact {string} in {string} is refused with M_FORBIDDEN and the message {string}": `PUT /redact` below the redact level. */
Then(
  "{word}'s attempt to redact {string} in {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, userName: string, name: string, template: string, message: string) => {
    const target = messageOf(name);
    expect(target.roomId).toBe(roomIdOf(template));
    await expectForbidden(await putRedaction({ request, browser }, userName, target.roomId, target.eventId), `${userName}'s redaction of ${name}`, message);
  },
);

/** "Then marie's send of an m.room.redaction for {string} in {string} is refused with M_FORBIDDEN and the message {string}": the gap of `fw` is closed. */
Then(
  "{word}'s send of an m.room.redaction for {string} in {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, userName: string, name: string, template: string, message: string) => {
    const target = messageOf(name);
    expect(target.roomId).toBe(roomIdOf(template));
    const resp = await request.put(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(target.roomId)}/send/m.room.redaction/${uniqueTxn()}`,
      { headers: authHeaders(await tokenOf({ request, browser }, userName)), data: { redacts: target.eventId } },
    );
    await expectForbidden(resp, `${userName}'s /send of a redaction of ${name}`, message);
  },
);

/** "Then alex's attempt to redact the topic event of {string} is refused ...": the room's `m.room.topic` event (found through alex's /messages) cannot be redacted. */
Then(
  "{word}'s attempt to redact the topic event of {string} is refused with M_FORBIDDEN and the message {string}",
  async ({ request, browser }: Fixtures, userName: string, template: string, message: string) => {
    const roomId = roomIdOf(template);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/messages?dir=b&limit=100`, {
      headers: { Authorization: `Bearer ${await tokenOf({ request, browser }, userName)}` },
    });
    expect(resp.status(), `/messages answered ${resp.status()}`).toBe(200);
    const topic = ((await resp.json()) as { chunk?: ServedEvent[] }).chunk?.find((e) => e.type === 'm.room.topic');
    expect(topic?.event_id, 'the room has an m.room.topic event').toBeTruthy();
    await expectForbidden(await putRedaction({ request, browser }, userName, roomId, topic?.event_id as string), `${userName}'s redaction of the topic event`, message);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Server-side evidence
// ─────────────────────────────────────────────────────────────────────────────

/**
 * "Then kai's sync of {string} shows {string} with empty content and unsigned.redacted_because and the redaction with a top-level redacts": kai's full /sync timeline
 * has the target pruned (`content: {}`, `unsigned.redacted_because` = the redaction event) and the redaction event with the top-level `redacts` (Element applies
 * a live redaction only through it) and `content.redacts`; the original marker word is in no byte of the response.
 */
Then(
  "{word}'s sync of {string} shows {string} with empty content and unsigned.redacted_because and the redaction with a top-level redacts",
  async ({ request, browser }: Fixtures, userName: string, template: string, name: string) => {
    const roomId = roomIdOf(template);
    const target = messageOf(name);
    const redactionId = redactionIds.get(name);
    expect(redactionId, `${name} was redacted by a step before`).toBeTruthy();

    const token = await tokenOf({ request, browser }, userName);
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, { headers: { Authorization: `Bearer ${token}` } });
    expect(resp.status(), `full sync of ${userName} answered ${resp.status()}`).toBe(200);
    const raw = await resp.text();
    expect(raw.includes(target.marker), 'the original content is in no byte of the sync response').toBe(false);

    const events = ((JSON.parse(raw) as SyncBody).rooms?.join?.[roomId]?.timeline?.events ?? []) as ServedEvent[];
    const pruned = events.find((e) => e.event_id === target.eventId);
    expect(pruned, `${userName}'s sync timeline carries ${name}`).toBeTruthy();
    expect(pruned?.content, `${name} is served with empty content`).toEqual({});
    expect(pruned?.unsigned?.redacted_because?.event_id, 'unsigned.redacted_because is the redaction event').toBe(redactionId);
    expect(pruned?.unsigned?.redacted_because?.type).toBe('m.room.redaction');

    const redaction = events.find((e) => e.event_id === redactionId);
    expect(redaction, `${userName}'s sync timeline carries the redaction`).toBeTruthy();
    expect(redaction?.redacts, 'the redaction carries the top-level redacts').toBe(target.eventId);
    expect(redaction?.content?.redacts, 'and content.redacts').toBe(target.eventId);
  },
);

/** "Then kai's GET of {string} in {string} still has its content": the target is unchanged after the refusals. */
Then(
  "{word}'s GET of {string} in {string} still has its content",
  async ({ request, browser }: Fixtures, userName: string, name: string, template: string) => {
    const target = messageOf(name);
    expect(target.roomId).toBe(roomIdOf(template));
    const served = await getEvent({ request, browser }, userName, target.roomId, target.eventId);
    expect(String(served.content?.body ?? ''), 'the refused redactions changed nothing').toContain(target.marker);
    expect(served.unsigned?.redacted_because, 'no redacted_because').toBeUndefined();
  },
);

/** "Then kai's GET of {string} in {string} has empty content and unsigned.redacted_because by alex": polled (the UI scenario writes it through Element). */
Then(
  "{word}'s GET of {string} in {string} has empty content and unsigned.redacted_because by {word}",
  async ({ request, browser }: Fixtures, userName: string, name: string, template: string, redactorName: string) => {
    const target = messageOf(name);
    expect(target.roomId).toBe(roomIdOf(template));
    await expect
      .poll(
        async () => {
          const served = await getEvent({ request, browser }, userName, target.roomId, target.eventId);
          return {
            content: served.content,
            because: served.unsigned?.redacted_because?.type,
            by: served.unsigned?.redacted_because?.sender,
            redacts: served.unsigned?.redacted_because?.redacts,
            leaked: JSON.stringify(served).includes(target.marker),
          };
        },
        { message: `${userName}'s GET of ${name} shows the redaction by ${redactorName}`, timeout: 30_000 },
      )
      .toEqual({ content: {}, because: 'm.room.redaction', by: userByName(redactorName).matrixId, redacts: target.eventId, leaked: false });
  },
);

/** "Then kai's search for the marker word of {string} finds nothing": a redacted event is excluded from the search. */
Then("{word}'s search for the marker word of {string} finds nothing", async ({ request, browser }: Fixtures, userName: string, name: string) => {
  const { marker } = messageOf(name);
  await expect.poll(async () => searchIds({ request, browser }, userName, marker), { message: `${userName}'s search for ${name} finds nothing`, timeout: 15_000 }).toEqual([]);
});

// ─────────────────────────────────────────────────────────────────────────────
// The Element Web scenario (tom's own browser context)
// ─────────────────────────────────────────────────────────────────────────────

/** "Given tom is logged in via Element Web in a context of his own": the shared `page` is alex's, the second context marie's; tom gets a context and a fresh OIDC login like the fixtures do. */
Given('{word} is logged in via Element Web in a context of his own', async ({ browser }: { browser: Browser }, userName: string) => {
  const user = userByName(userName);
  tomContext = await browser.newContext();
  tomPage = await tomContext.newPage();
  await loginViaOidcBrowser(tomPage, user, user.email, DEX_TEST_PASSWORD);
});

/** "When tom opens the redaction room {string} in Element Web": direct URL navigation by room id, the managed-E2EE key-setup dialog is dismissed. */
When('{word} opens the redaction room {string} in Element Web', async ({}: object, _userName: string, template: string) => {
  const page = tomPage;
  if (!page) throw new Error('tom has no Element Web page: the login step must run first.');
  await page.goto(`${ELEMENT_URL}/#/room/${encodeURIComponent(roomIdOf(template))}`);
  await dismissKeySetupDialog(page);
  const composer = page.locator('.mx_BasicMessageComposer_input').or(page.locator('.mx_SendMessageComposer [contenteditable="true"]')).first();
  await expect(composer).toBeVisible({ timeout: 30_000 });
  await dismissKeySetupDialog(page);
});

/**
 * "When tom removes his message {string} with the message options and confirms": hovers the tile of the message, opens "Options", clicks "Remove" and confirms with the
 * dialog's "Remove" button. UNVERIFIED selectors (see the header).
 */
When('{word} removes his message {string} with the message options and confirms', async ({}: object, _userName: string, name: string) => {
  const page = tomPage;
  if (!page) throw new Error('tom has no Element Web page: the login step must run first.');
  const { marker } = messageOf(name);
  const tile = page.locator('.mx_EventTile', { hasText: marker }).first();
  await expect(tile).toBeVisible({ timeout: 30_000 });
  await tile.hover();
  await tile.getByRole('button', { name: 'Options' }).click({ timeout: 10_000 });
  await page.getByRole('menuitem', { name: 'Remove' }).click({ timeout: 10_000 });
  await page.getByRole('dialog').getByRole('button', { name: 'Remove' }).click({ timeout: 10_000 });
});

After(async () => {
  if (tomContext) {
    await tomContext.close().catch(() => undefined);
    tomContext = undefined;
    tomPage = undefined;
  }
});
