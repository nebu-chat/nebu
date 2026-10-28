/**
 * Step definitions for features/element/dm/create-dm.feature
 *
 * Story create-room-invites-direct (epic oauth-broker, follow-up `eb`): `POST /createRoom` processes `invite`, `invite_3pid` and
 * `is_direct`. Before the story an Element DM was a room with the creator as the only member (the partner held no invitation).
 *
 * Test strategy / integrity:
 *   - Scenario 1 (API contract): ONE POST /createRoom with exactly the body Element Web 1.12.15 sends for a DM with one user
 *     (`createRoom(client, { dmUserId })` of ./src/createRoom.ts: preset trusted_private_chat, visibility private, invite [partner],
 *     is_direct true, initial_state guest_access can_join + m.room.encryption + history_visibility invited). The test forges NO server
 *     state: the oracle is what the server produced, read back through the API.
 *   - The partner's `m.room.member` event is read by the CREATOR through `GET /rooms/{id}/messages?dir=b` (`GET /rooms/{id}/state/...` is
 *     not routed on Nebu; the state in `/sync` lists only JOINED members, the invite is visible as an event of the timeline window).
 *   - Scenario 2 (real UI, creator side): Element's "Start new chat" flow (a local room that is turned into a real room on the first
 *     message). Asserted SERVER-SIDE: the DM exists, the partner holds an invite with is_direct true, the message is in the room, and the
 *     room became ready without Element's 5 s "Assuming local room ... is ready" fallback (Element waits until invited + joined members ==
 *     1 + targets; Nebu's member counts come from room_members / pending room_invitations).
 *   - Scenario 3 (real UI, INVITEE side, @dm-invitee-ui @regression @ui): the e2e acceptance of story sync-membership-partition (follow-ups
 *     `ev` + `ez`: `rooms.invite` with a stripped invite_state in /sync). marie sees the invitation tile, accepts it, the DM is joined and
 *     her `m.direct` lists it under the inviter. The final step asserts `m.direct` (the assertion is never weakened): Element writes it from
 *     the invitee's JOIN event, see "Element facts" below (story member-event-prev-content, follow-up `ff`, formerly the known failure K10).
 *
 * Element facts of Scenario 3 (Element Web 1.12.15, verified in the bundle of the image `nebu-oauth-dev-element`, bundles/3c9ddd76fa48d1221fef/;
 * offsets are byte offsets in the minified chunk; re-check with python3 `s=open(chunk).read(); s.find(needle)`):
 *   E1 `RoomView.updateDMState()` (element-web-app.js @714984) is the ONLY writer of the invitee's `m.direct` after an accept: once the own
 *      membership is "join" it calls `room.getDMInviter()` and `setDMRoom` (`./src/Rooms.ts`, init.js @112961 -> PUT account_data/m.direct).
 *   E2 it runs on every `RoomStateEvent.Update` of the open room (debounced 500 ms, leading + trailing: @697254, @696974, @707752).
 *   E3 / E4 `Room.getDMInviter()` (1471.js @218262) reads the own `RoomMember.getDMInviter()` (1471.js @188119): for a JOIN member event it needs
 *      `unsigned.prev_content.membership == "invite"` AND `unsigned.prev_content.is_direct == true` and returns `unsigned.prev_sender`.
 *   E7 `/members` after the join cannot overwrite a member event received through `/sync` (`setOutOfBandMember`, 1471.js @197973).
 *   E8 `SyncAccumulator.getJSON` (@289586) and `getDirectionalContent()` also read `unsigned.prev_content` / `prev_sender`: a wrong predecessor
 *      corrupts the cached and the back-paginated state.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { getApiSession, joinRoom } from '../../fixtures/dex-auth';
import { NEBU_USERS, type NebUser } from '../../fixtures/users';
import { dismissKeySetupDialog } from '../common/navigation.steps';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

// ─────────────────────────────────────────────────────────────────────────────
// Module-level state (safe with workers: 1 — see playwright.config.ts)
// ─────────────────────────────────────────────────────────────────────────────

/** The DM room of the current scenario (created by the API step or found server-side after the UI flow). */
let dmRoomId = '';

/** Request timestamps of the Element UI flow (ms since epoch): the createRoom POST and the first message PUT. */
const uiTimings: { createRoomAt: number; sendAt: number } = { createRoomAt: 0, sendAt: 0 };

/** The unique first message of the UI flow of THIS run (a constant text would match a room of an earlier run). */
let uiFirstMessage = '';

/** The creator's joined rooms BEFORE the UI flow: only rooms that appear afterwards can be the DM the flow created (M1). */
let roomsBeforeUiFlow = new Set<string>();

/** Console messages of the Element page during the UI flow (Element logs the 5 s fallback as a warning). */
const uiConsole: string[] = [];

/** The warning of Element Web 1.12.15 (./src/utils/localRoom/... `isRoomReady` timeout) when the local room never became ready. */
const ELEMENT_LOCAL_ROOM_FALLBACK = /Assuming local room .* is ready after hitting timeout/;

function userByName(name: string): NebUser {
  const user = NEBU_USERS[name as keyof typeof NEBU_USERS];
  if (!user) throw new Error(`Unknown test user "${name}".`);
  return user;
}

// ─────────────────────────────────────────────────────────────────────────────
// API helpers
// ─────────────────────────────────────────────────────────────────────────────

type TimelineEvent = {
  type: string;
  state_key?: string;
  sender?: string;
  origin_server_ts?: number;
  content?: Record<string, unknown>;
};

/**
 * The createRoom body of Element Web 1.12.15 for a DM with ONE user (module ./src/createRoom.ts, `dmUserId` branch). `invite_3pid` is
 * absent (an e-mail target would add it only with an identity server) and `m.room.encryption` is what Element adds when all targets have
 * device keys (Nebu skips it, ADR-011).
 */
function elementDmBody(partnerId: string): Record<string, unknown> {
  return {
    preset: 'trusted_private_chat',
    visibility: 'private',
    invite: [partnerId],
    is_direct: true,
    initial_state: [
      { type: 'm.room.guest_access', state_key: '', content: { guest_access: 'can_join' } },
      { type: 'm.room.encryption', state_key: '', content: { algorithm: 'm.megolm.v1.aes-sha2' } },
      { type: 'm.room.history_visibility', state_key: '', content: { history_visibility: 'invited' } },
    ],
  };
}

async function createDirectChat(
  request: APIRequestContext,
  browser: Browser,
  creatorName: string,
  partnerName: string,
): Promise<string> {
  const creator = userByName(creatorName);
  const partner = userByName(partnerName);
  const session = await getApiSession(request, creator, browser);

  const resp = await request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
    headers: { Authorization: `Bearer ${session.token}`, 'Content-Type': 'application/json' },
    data: elementDmBody(partner.matrixId),
  });
  if (!resp.ok()) {
    throw new Error(`[createDirectChat] ${resp.status()} ${await resp.text()}`);
  }
  return ((await resp.json()) as { room_id: string }).room_id;
}

/** `GET /rooms/{id}/messages?dir=b` as `token`: newest first. */
async function roomEvents(request: APIRequestContext, token: string, roomId: string): Promise<TimelineEvent[]> {
  const resp = await request.get(
    `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/messages?dir=b&limit=100`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  if (!resp.ok()) {
    throw new Error(`[roomEvents] ${roomId} -> ${resp.status()} ${await resp.text()}`);
  }
  return ((await resp.json()) as { chunk?: TimelineEvent[] }).chunk ?? [];
}

/** The invite member events of `partnerId` in the room's events. */
function inviteEventsOf(events: TimelineEvent[], partnerId: string): TimelineEvent[] {
  return events.filter(
    (e) => e.type === 'm.room.member' && e.state_key === partnerId && e.content?.membership === 'invite',
  );
}

/**
 * The room ids of the user's joined rooms from a full /sync (the only reliable listing: `GET /joined_rooms` is a stub on Nebu).
 */
async function joinedRoomIds(request: APIRequestContext, token: string): Promise<string[]> {
  const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/sync?timeout=0`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!resp.ok()) {
    throw new Error(`[joinedRoomIds] sync ${resp.status()}`);
  }
  const body = (await resp.json()) as { rooms?: { join?: Record<string, unknown> } };
  return Object.keys(body.rooms?.join ?? {});
}

/**
 * Polls (bounded) until a room that is NOT in `excluded` (the creator's joined rooms before the UI flow) carries an invite member event
 * of `partnerId` with is_direct true, and returns that room id. The test forges nothing: the room is the one Element's UI flow created.
 * Exactly one such new room must exist (a second one would mean Element created the DM twice).
 */
async function findNewDirectChatServerSide(
  request: APIRequestContext,
  token: string,
  partnerId: string,
  excluded: Set<string>,
  timeoutMs = 45_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let lastSeen = 0;

  while (Date.now() < deadline) {
    const rooms = (await joinedRoomIds(request, token)).filter((id) => !excluded.has(id));
    lastSeen = rooms.length;
    const matching: string[] = [];
    for (const roomId of rooms) {
      const events = await roomEvents(request, token, roomId).catch(() => [] as TimelineEvent[]);
      if (inviteEventsOf(events, partnerId).some((e) => e.content?.is_direct === true)) matching.push(roomId);
    }
    if (matching.length > 0) {
      expect(matching, 'exactly ONE new direct chat with the partner was created by the UI flow').toHaveLength(1);
      return matching[0];
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error(
    `No NEW joined room of the creator carries an invite member event of ${partnerId} with is_direct true ` +
      `(looked at ${lastSeen} new joined rooms for ${timeoutMs} ms): createRoom did not process invite / is_direct, ` +
      `or Element reused an existing DM instead of creating one.`,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 1 — the createRoom contract with Element's exact DM body
// ─────────────────────────────────────────────────────────────────────────────

When(
  '{word} creates a direct chat with {word} exactly as Element does',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    creatorName: string,
    partnerName: string,
  ) => {
    dmRoomId = await createDirectChat(request, browser, creatorName, partnerName);
    expect(dmRoomId).toMatch(/^!/);
  },
);

Then(
  "{word}'s membership in that direct chat is an invite from {word} with is_direct true",
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    partnerName: string,
    creatorName: string,
  ) => {
    const partner = userByName(partnerName);
    const creator = userByName(creatorName);
    // the creator reads the partner's member event (no GET /state route on Nebu)
    const session = await getApiSession(request, creator, browser);
    const events = await roomEvents(request, session.token, dmRoomId);

    const memberEvents = events.filter((e) => e.type === 'm.room.member' && e.state_key === partner.matrixId);
    expect(
      memberEvents.length,
      `exactly ONE m.room.member event with state_key ${partner.matrixId} (the invite), got ${JSON.stringify(memberEvents)}`,
    ).toBe(1);

    const invite = memberEvents[0];
    expect(invite.sender, 'the invite is sent by the creator').toBe(creator.matrixId);
    expect(invite.content, 'content exactly {membership: invite, is_direct: true}').toEqual({
      membership: 'invite',
      is_direct: true,
    });
  },
);

When(
  '{word} joins that direct chat',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
  ) => {
    const session = await getApiSession(request, userByName(userName), browser);
    // POST /_matrix/client/v3/join/{roomId} (joinRoom asserts a 2xx): the partner holds the invitation createRoom wrote
    await joinRoom(request, session.token, dmRoomId);
  },
);

When(
  '{word} sends the direct chat message {string}',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    message: string,
  ) => {
    const session = await getApiSession(request, userByName(userName), browser);
    const txnId = `txn-dm-${Date.now()}`;
    const resp = await request.put(
      `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(dmRoomId)}/send/m.room.message/${txnId}`,
      {
        headers: { Authorization: `Bearer ${session.token}`, 'Content-Type': 'application/json' },
        data: { msgtype: 'm.text', body: message },
      },
    );
    expect(resp.status(), `send message: ${await resp.text()}`).toBe(200);
  },
);

Then(
  '{word} reads {string} in that direct chat',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
    message: string,
  ) => {
    const session = await getApiSession(request, userByName(userName), browser);
    const events = await roomEvents(request, session.token, dmRoomId);
    const bodies = events.filter((e) => e.type === 'm.room.message').map((e) => e.content?.body);
    expect(bodies, `${userName} reads the message through /messages`).toContain(message);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 2 — the real Element UI, creator side
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Element Web 1.12.15: the room list's "New conversation" (+) button offers "Start new chat" (a DM, `mx_InviteDialog`) next to "New room".
 * Selectors are semantic with fallbacks (roles / names), never generated ids.
 */
async function openStartChatDialog(page: Page): Promise<void> {
  const roomListNav = page.getByRole('navigation', { name: /room list/i });
  const newConversation = roomListNav
    .getByRole('button', { name: /new conversation/i })
    .or(page.getByRole('button', { name: /new conversation/i }))
    .or(page.locator('.mx_RoomListHeader_auxButton'));
  await newConversation.first().click({ timeout: 20_000 });

  const startChat = page
    .getByRole('menuitem', { name: /start new chat|new message|start chat|direct message/i })
    .or(page.getByRole('option', { name: /start new chat|new message|start chat|direct message/i }));
  await startChat.first().click({ timeout: 10_000 });

  await page.locator('.mx_InviteDialog, [role="dialog"]:has(input)').first().waitFor({ state: 'visible', timeout: 15_000 });
}

/** dismissKeySetupDialog clicks Cancel / Close / Continue buttons: never while the Start-chat dialog (which has such buttons) is open. */
async function dismissKeySetupDialogUnlessStartChatOpen(page: Page): Promise<void> {
  if (await page.locator('.mx_InviteDialog').first().isVisible({ timeout: 500 }).catch(() => false)) return;
  await dismissKeySetupDialog(page);
}

When(
  '{word} starts a chat with {word} via Element Web and sends {string}',
  async (
    { page, request, browser }: { page: Page; request: APIRequestContext; browser: Browser },
    creatorName: string,
    partnerName: string,
    message: string,
  ) => {
    const partner = userByName(partnerName);
    uiTimings.createRoomAt = 0;
    uiTimings.sendAt = 0;
    uiConsole.length = 0;
    dmRoomId = '';

    // M1: a unique first message, and the creator's rooms BEFORE the flow (Element's findDMForUser reuses an existing DM of the same
    // two users, scenario 1 leaves one behind: the flow must be judged by what is NEW)
    uiFirstMessage = `${message} ${Date.now()}`;
    const creatorSession = await getApiSession(request, userByName(creatorName), browser);
    roomsBeforeUiFlow = new Set(await joinedRoomIds(request, creatorSession.token));

    page.on('console', (msg) => {
      uiConsole.push(msg.text());
    });

    // timestamps of the two requests the flow is measured by (the createRoom POST and the first message PUT)
    page.on('request', (req) => {
      const url = req.url();
      if (req.method() === 'POST' && /\/_matrix\/client\/v3\/createRoom/.test(url) && uiTimings.createRoomAt === 0) {
        uiTimings.createRoomAt = Date.now();
      }
      if (req.method() === 'PUT' && /\/send\/m\.room\.message\//.test(url) && uiTimings.sendAt === 0) {
        uiTimings.sendAt = Date.now();
      }
    });

    await dismissKeySetupDialogUnlessStartChatOpen(page);
    await openStartChatDialog(page);

    // pick the partner: the search field takes the Matrix id, the first suggestion tile is the partner
    const input = page.locator('.mx_InviteDialog input[type="text"], .mx_InviteDialog input[type="search"], [role="dialog"] input').first();
    await input.fill(partner.matrixId);
    const tile = page
      .locator('.mx_InviteDialog_tile, .mx_InviteDialog_roomTile')
      .filter({ hasText: new RegExp(partner.name, 'i') })
      .first();
    await tile.waitFor({ state: 'visible', timeout: 20_000 });
    await tile.click();

    // "Go" starts the chat (Element opens a LOCAL room: nothing is created server-side before the first message)
    await page.getByRole('button', { name: /^go$|^start chat$|^start$/i }).first().click({ timeout: 10_000 });
    await dismissKeySetupDialogUnlessStartChatOpen(page);

    const composer = page
      .locator('.mx_BasicMessageComposer_input')
      .or(page.locator('.mx_SendMessageComposer [contenteditable="true"]'))
      .or(page.locator('.mx_RoomView_body .mx_MessageComposer div[contenteditable]'))
      .first();
    await expect(composer).toBeVisible({ timeout: 30_000 });
    await composer.click();
    await composer.pressSequentially(uiFirstMessage, { delay: 10 });
    await composer.press('Enter');

    // the message tile is the UI proof that Element considered the room ready and sent the message
    await expect(page.locator('.mx_EventTile', { hasText: uiFirstMessage }).first()).toBeVisible({ timeout: 60_000 });
  },
);

Then(
  'the direct chat with {word} exists on the server and {word} holds an invite with is_direct true',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    partnerName: string,
    _sameName: string,
  ) => {
    const creator = NEBU_USERS.alex;
    const partner = userByName(partnerName);
    const session = await getApiSession(request, creator, browser);

    // the test forges no server state: the room is whatever Element's UI flow created (only NEW rooms are candidates, M1)
    dmRoomId = await findNewDirectChatServerSide(request, session.token, partner.matrixId, roomsBeforeUiFlow);

    const events = await roomEvents(request, session.token, dmRoomId);
    const invites = inviteEventsOf(events, partner.matrixId);
    expect(invites.length, 'exactly one invite member event for the partner').toBe(1);
    expect(invites[0].sender).toBe(creator.matrixId);
    expect(invites[0].content).toEqual({ membership: 'invite', is_direct: true });
  },
);

Then(
  'the message {string} is in that direct chat',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    message: string,
  ) => {
    const session = await getApiSession(request, NEBU_USERS.alex, browser);
    const events = await roomEvents(request, session.token, dmRoomId);
    // the UI flow sent `message` + a run-unique suffix (M1): the room of THIS run carries exactly that text
    const expected = uiFirstMessage !== '' && uiFirstMessage.startsWith(message) ? uiFirstMessage : message;
    expect(events.filter((e) => e.type === 'm.room.message').map((e) => e.content?.body)).toContain(expected);
  },
);

Then(
  "that direct chat became ready without Element's 5 second fallback",
  async () => {
    // Element's local-room flow waits until the room reports invited + joined members == 1 + targets and has a history_visibility event
    // (500 ms polling, 5 s timeout) and otherwise logs the warning `Assuming local room <id> is ready after hitting timeout` (verified in
    // the Element Web 1.12.15 bundle, module ./src/utils/localRoom). With the invite processed server-side the counts are right at once.
    // The ABSENCE of that warning is the precise assertion (no sync latency / render jitter in it); the elapsed time is a soft extra.
    expect(uiTimings.createRoomAt, 'the createRoom request of the UI flow was observed (Element did not reuse an existing DM)').toBeGreaterThan(0);
    expect(uiTimings.sendAt, 'the first message request of the UI flow was observed').toBeGreaterThan(0);

    const fallback = uiConsole.filter((line) => ELEMENT_LOCAL_ROOM_FALLBACK.test(line));
    expect(fallback, `Element hit its 5 s local-room fallback: ${JSON.stringify(fallback)}`).toEqual([]);

    const elapsedMs = uiTimings.sendAt - uiTimings.createRoomAt;
    expect.soft(elapsedMs, `the first message followed the createRoom request after ${elapsedMs} ms (the fallback waits 5000 ms)`).toBeLessThan(5_000);
  },
);

// ─────────────────────────────────────────────────────────────────────────────
// Scenario 3 — the INVITEE side in the Element UI (@dm-invitee-ui: story sync-membership-partition, follow-ups `ev` + `ez`)
// ─────────────────────────────────────────────────────────────────────────────

Given(
  '{word} has created a direct chat with {word} via the API',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    creatorName: string,
    partnerName: string,
  ) => {
    dmRoomId = await createDirectChat(request, browser, creatorName, partnerName);
  },
);

Then(
  "{word} sees the direct chat invitation from {word} in her room list",
  async (
    { secondPage }: { secondPage: Page },
    _inviteeName: string,
    inviterName: string,
  ) => {
    // `rooms.invite` in /sync (follow-up ev, closed by story sync-membership-partition): Element shows the DM invitation as a room-list tile
    // from the inviter. The selector is the one of Element Web 1.12.15 (`aria-label="Open room <name> invitation."`); if it proves wrong on
    // the first real run, fix the SELECTOR (and record it), never the assertion.
    const inviter = userByName(inviterName);
    const tile = secondPage
      .locator(`[aria-label^="Open room"][aria-label*="invitation"]`)
      .filter({ hasText: new RegExp(inviter.name, 'i') });
    await expect(tile.first(), 'the invitation tile appears without any /join <room id>').toBeVisible({ timeout: 60_000 });
  },
);

When(
  '{word} accepts the direct chat invitation from {word}',
  async (
    { secondPage }: { secondPage: Page },
    _inviteeName: string,
    inviterName: string,
  ) => {
    const inviter = userByName(inviterName);
    const invitationTiles = secondPage
      .locator(`[aria-label^="Open room"][aria-label*="invitation"]`)
      .filter({ hasText: new RegExp(inviter.name, 'i') });
    // On a stack that was used before, older invitations of the same inviter may exist: compare counts, not "zero".
    const tilesBefore = await invitationTiles.count();
    await invitationTiles.first().click();
    await dismissKeySetupDialog(secondPage);
    await secondPage.getByRole('button', { name: /^accept$|^join the discussion$|^start chatting$/i }).first().click({ timeout: 20_000 });

    // The click only dispatches Element's async POST /join: wait for the UI signal that the invitation was consumed (the invitation tile no
    // longer matches) before the server-side assertions run (test review M1).
    await expect
      .poll(async () => invitationTiles.count(), {
        message: 'one invitation tile is gone after the accept',
        timeout: 60_000,
      })
      .toBeLessThan(tilesBefore);
  },
);

Then(
  "{word}'s direct chat with {word} is joined and marked as a direct chat",
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    inviteeName: string,
    inviterName: string,
  ) => {
    const invitee = userByName(inviteeName);
    const inviter = userByName(inviterName);
    const session = await getApiSession(request, invitee, browser);

    // marked as direct: Element writes the invitee's `m.direct` account data AFTER the join sync (seconds later; 404 until then).
    // Polled first: a plain GET does not touch the sync token (test review M1). Element writes it from the invitee's JOIN event
    // (`unsigned.prev_content` + `unsigned.prev_sender`, see "Element facts" in the header of this file, follow-up `ff`).
    await expect
      .poll(
        async () => {
          const resp = await request.get(
            `${MATRIX_BASE}/_matrix/client/v3/user/${encodeURIComponent(invitee.matrixId)}/account_data/m.direct`,
            { headers: { Authorization: `Bearer ${session.token}` } },
          );
          if (resp.status() !== 200) return [`m.direct answered ${resp.status()}`];
          const direct = (await resp.json()) as Record<string, string[]>;
          return direct[inviter.matrixId] ?? [];
        },
        { message: 'm.direct lists the DM under the inviter', timeout: 60_000, intervals: [1_000, 2_000, 3_000] },
      )
      .toContain(dmRoomId);

    // joined: the room is in the invitee's joined rooms. A full /sync replaces the user's stored token (follow-up fd): this call comes LAST
    // and is polled with a coarse interval.
    await expect
      .poll(async () => joinedRoomIds(request, session.token), {
        message: 'the DM is joined',
        timeout: 60_000,
        intervals: [2_000, 3_000],
      })
      .toContain(dmRoomId);
  },
);
