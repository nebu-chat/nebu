/**
 * Step definitions for features/oauth-pages-redesign/05-portal-redesign.feature
 *
 * Story: oauth-pages-redesign / 05-portal-redesign (REQ-2026-020). Runs only against the full compose stack with the real Dex
 * (NOT executable in the isolated env, same as the other stories of this epic). ATDD RED phase: the portal still has the old look.
 *
 * The feature file has no Background (it is the verbatim Gherkin of the story), so a `@REQ-2026-020` Before hook enables OAuth with the e2e issuer and an
 * After hook restores the prior config and removes every fixture (OAuth sessions + devices, consent rows and grants, clients, account sessions). Step files
 * share no module state, so the helpers below (Dex sign-in, Allow arming, issuer origin, PKCE) are copies of the ones in oauth-account-management.steps.ts /
 * consent-page-redesign.steps.ts. Every step text of this feature is new; nothing is redefined from the other step files (bddgen rejects duplicates).
 *
 * The user is `tom` (declared in fixtures/users.ts, "not used in current stories"): a user nobody else touches, so "3 signed in" / "2 allowed" are exact.
 * The data is real: three OAuth devices through two approved native clients (the remembered consent of the first client may skip the consent page of
 * the second device, both branches are handled), so there are 3 devices and 2 consent grants.
 *
 * What the black-box run covers and what it cannot:
 *   - overview, device cards (390 px) and apps in German and English, real sign-in at Dex.
 *   - sign-out of a device and withdrawing an app: the real confirmation page, the real notices. A real Dex may report no auth_time (gate y, FR14): the
 *     destructive actions are then unavailable by design and the scenario is skipped with a `gate-y` annotation, never silently passed.
 *   - of the 12 account error codes only `not_found` and `method_not_allowed` can be provoked black-box; all 12 (and every page, both languages, with the
 *     same hooks and headers) are pinned by server/test/nebu/oauth/portal_redesign_test.exs. "none" of `Accept-Language` is a browser that sends the default
 *     `en-US`: a header-less browser request cannot be made here, the header-less case is pinned by the ExUnit test.
 *   - reset page: a real pending request through the m.oauth challenge (keys upload of a real device). Needs a fresh session (gate y) and exactly one
 *     pending request; otherwise the scenario is skipped with an annotation.
 *
 * Page contract (server/test/nebu/oauth/portal_redesign_test.exs): `main[data-page="account"][data-action]`, `[data-role="signed-in-as"]`, `nav a` (four links),
 * `[data-role="portal-tile"][data-tile="devices|apps|security"]`, `details[data-role="profile-details"]`, `ul[data-role="device-list"]` of
 * `li[data-role="account-device"][data-device-id]` with `[data-role="device-name"]`, `[data-role="device-meta"]`, `[data-role="device-row-sign-out"]` and one
 * `<details>`, `ul[data-role="grant-list"]` of `li[data-role="consent-grant"][data-client-id]` with `[data-role="withdraw-grant"]`,
 * notices `[data-role="notice"][data-notice]` with role, icon and a `<strong>` label.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, BrowserContext, Page, TestInfo } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  insertOAuthClient,
  clearOAuthClientsByIdPrefix,
  clearOAuthConsentRequestsByClientPrefix,
  clearOAuthConsentGrantsByClientPrefix,
  clearOAuthSessionsByClientPrefix,
  clearDeviceOfUser,
  clearAccountSessions,
} from '../../fixtures/db';
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const CLIENT_PREFIX = 'e2e-portal-redesign-';
const CLIENT_A = `${CLIENT_PREFIX}app-a`;
const CLIENT_B = `${CLIENT_PREFIX}app-b`;
const APP_NAME = 'Portal Test App';
const DEVICE_IDS = ['E2EPORT001', 'E2EPORT002', 'E2EPORT003'];
const USER = NEBU_USERS.tom;
const STABLE = 'urn:matrix:client:';
const CONSENT_PATH = '/oauth2/consent';
const LOOPBACK_ORIGIN = 'http://localhost:53682';
const LOOPBACK_REDIRECT = `${LOOPBACK_ORIGIN}/cb`;
const DEVICES_URL = '/account?action=org.matrix.devices_list';
const PHONE = { width: 390, height: 844 };

type Lang = { code: 'de' | 'en'; locale: string };
const DE: Lang = { code: 'de', locale: 'de' };
const EN: Lang = { code: 'en', locale: 'en-US' };
const DE_AT: Lang = { code: 'de', locale: 'de-AT' };

const COPY = {
  en: { h1: 'Your account', devices: '3 signed in', apps: '2 allowed', nav: ['Overview', 'Devices', 'Apps', 'Security'], signedIn: 'Signed in as' },
  de: { h1: 'Ihr Konto', devices: '3 angemeldet', apps: '2 erlaubt', nav: ['Übersicht', 'Geräte', 'Apps', 'Sicherheit'], signedIn: 'Angemeldet als' },
} as const;

/** English UI texts of the old portal that must not survive on a German page. */
const ENGLISH_UI = [
  'Signed in as',
  'Your devices',
  'Your account',
  'Your profile',
  'Sign out',
  'Device ID',
  'Last active',
  'Withdraw',
  'Cancel',
  'Approve',
  'Decline',
  'Back to',
  'Apps you have allowed',
  'Reset your identity',
  'Display name',
  'What you can do',
];

/** A step text with characters that are special in a Cucumber expression ( ) / "..." as an exact regular expression. */
const lit = (text: string): RegExp => new RegExp('^' + text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') + '$');

type Seen = { lang: Lang; name: string; status: number; headers: Record<string, string>; body: string };
type Notice = { code: string | null; role: string | null; label: string; hasIcon: boolean; classes: string };
type ActionRun = { confirmShown: boolean; deviceNotice: Notice; grantNotice: Notice };
type ResetRun = { page: Page; csp: string };

let priorIssuer: string | null = null;
let contexts: BrowserContext[] = [];
let tokens: Record<string, string> = {};
let dataReady = false;
let overviews: { lang: Lang; page: Page }[] = [];
let phonePage: Page | null = null;
let actionPage: Page | null = null;
let actionRun: ActionRun | null = null;
let seen: Seen[] = [];
let challengeUrl = '';
let resetRun: ResetRun | null = null;

// ─── Hooks ─────────────────────────────────────────────────────────────────────

function wipe(): void {
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  for (const id of DEVICE_IDS) clearDeviceOfUser(USER.matrixId, id);
  clearAccountSessions(USER.matrixId);
}

Before({ tags: '@REQ-2026-020' }, async () => {
  contexts = [];
  tokens = {};
  dataReady = false;
  overviews = [];
  phonePage = null;
  actionPage = null;
  actionRun = null;
  seen = [];
  challengeUrl = '';
  resetRun = null;
  wipe();
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  upsertServerConfig('oauth_issuer_url', E2E_ISSUER);
  upsertServerConfig('oauth_enabled', 'true');
});

// Order: sessions + devices (matrix_sessions.client_id is ON DELETE RESTRICT), grants and consent rows, then the clients. Failures are NOT swallowed.
After({ tags: '@REQ-2026-020' }, async () => {
  for (const c of contexts) await c.close().catch(() => null);
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  wipe();
});

// ─── helpers ───────────────────────────────────────────────────────────────────

function pkcePair(): { verifier: string; challenge: string } {
  const verifier = randomBytes(32).toString('base64url');
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') };
}

/** Never leave the scenario passing silently when the real IdP cannot give the state it needs. */
function gateY($testInfo: TestInfo, why: string): void {
  $testInfo.annotations.push({ type: 'gate-y', description: why });
  console.log(`[gate-y-evidence] ${why}; scenario skipped`);
  $testInfo.skip(true, `gate-y: ${why}`);
}

async function approveDexGrantIfShown(page: Page): Promise<void> {
  // Acts ONLY on Dex's own approval page: the name regex would also match Nebu's consent button "Allow" (G3-5).
  const branch = await Promise.race([
    page.waitForURL((url) => url.pathname.includes('/dex/approval'), { timeout: 6_000 }).then(() => 'approval' as const),
    page.waitForURL((url) => !/^\/dex(\/|$)/i.test(url.pathname), { timeout: 6_000 }).then(() => 'left-dex' as const),
  ]).catch(() => 'none' as const);
  if (branch !== 'approval') return;
  await page.getByRole('button', { name: /^(grant access|approve|confirm)$/i }).click();
}

async function dexLogin(page: Page): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(USER.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  await approveDexGrantIfShown(page);
}

/** The consent POST is checked against the ISSUER origin (FR8): the e2e issuer is a fake https URL, so the browser's Origin is replaced. */
async function useIssuerOriginForConsent(page: Page): Promise<void> {
  await page.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** Allow is armed by REAL pointer movement elsewhere, then hovered (copy of armAllow in oauth-authorize.steps.ts). */
async function armAllow(page: Page): Promise<void> {
  const allow = page.locator('button[name="decision"][value="allow"]');
  await page.mouse.move(40, 40);
  await page.mouse.move(90, 110, { steps: 6 });
  await expect(allow, 'Allow is armed by real pointer movement').not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
  await page.mouse.move(4, 4);
  await allow.hover();
}

/** A real OAuth device of the user: authorize + Dex + (consent, unless the grant is remembered) + token. Returns the access token. */
async function createDevice(browser: Browser, request: APIRequestContext, clientId: string, deviceId: string): Promise<string> {
  const { verifier, challenge } = pkcePair();
  const ctx = await browser.newContext();

  try {
    const page = await ctx.newPage();
    await page.route(`${LOOPBACK_ORIGIN}/**`, (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>client stub</title>' }),
    );

    const qs = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: LOOPBACK_REDIRECT,
      scope: `${STABLE}api:* ${STABLE}device:${deviceId}`,
      state: `e2e-portal-${randomBytes(6).toString('hex')}`,
      code_challenge: challenge,
      code_challenge_method: 'S256',
    });

    await page.goto(`${NEBU_BASE_URL}/oauth2/authorize?${qs.toString()}`, { waitUntil: 'domcontentloaded' });
    await dexLogin(page);
    await page.waitForURL((url) => url.pathname === CONSENT_PATH || url.href.startsWith(LOOPBACK_REDIRECT), { timeout: NAV_TIMEOUT_MS });

    if (new URL(page.url()).pathname === CONSENT_PATH) {
      await useIssuerOriginForConsent(page);
      await armAllow(page);
      await page.locator('button[name="decision"][value="allow"]').click();
      await page.waitForURL((url) => url.href.startsWith(LOOPBACK_REDIRECT), { timeout: NAV_TIMEOUT_MS });
    }

    const code = new URL(page.url()).searchParams.get('code');
    expect(code, 'the authorize flow issued a code').toBeTruthy();

    const token = await request.post(`${NEBU_BASE_URL}/oauth2/token`, {
      form: { grant_type: 'authorization_code', code: code!, redirect_uri: LOOPBACK_REDIRECT, code_verifier: verifier, client_id: clientId },
    });

    expect(token.status(), `token endpoint: ${await token.text()}`).toBe(200);
    return ((await token.json()) as { access_token: string }).access_token;
  } finally {
    await ctx.close();
  }
}

/** Three devices (two apps) and two consent grants for the user, once per scenario. */
async function ensureUserData(browser: Browser, request: APIRequestContext): Promise<void> {
  if (dataReady) return;
  for (const [id, name] of [
    [CLIENT_A, `${APP_NAME} A`],
    [CLIENT_B, `${APP_NAME} B`],
  ]) {
    insertOAuthClient({
      clientId: id,
      status: 'approved',
      redirectUris: ['http://localhost/cb'],
      applicationType: 'native',
      clientUri: `https://${id}.e2e.example`,
      clientName: name,
    });
  }

  tokens[DEVICE_IDS[0]] = await createDevice(browser, request, CLIENT_A, DEVICE_IDS[0]);
  tokens[DEVICE_IDS[1]] = await createDevice(browser, request, CLIENT_A, DEVICE_IDS[1]);
  tokens[DEVICE_IDS[2]] = await createDevice(browser, request, CLIENT_B, DEVICE_IDS[2]);
  dataReady = true;
}

async function newContext(browser: Browser, lang: Lang, viewport?: { width: number; height: number }): Promise<BrowserContext> {
  const ctx = await browser.newContext({ locale: lang.locale, ...(viewport ? { viewport } : {}) });
  contexts.push(ctx);
  return ctx;
}

/** Signs the user in at the account page in a fresh browser context and waits for the portal. */
async function openAccount(browser: Browser, lang: Lang, path: string, viewport?: { width: number; height: number }): Promise<Page> {
  const ctx = await newContext(browser, lang, viewport);
  const page = await ctx.newPage();
  await page.goto(`${NEBU_BASE_URL}${path}`, { waitUntil: 'domcontentloaded' });
  await dexLogin(page);
  await expect(page.locator('main[data-page="account"]'), 'the portal is shown after the IdP login').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  return page;
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function htmlLang(body: string): string | null {
  return /<html lang="([^"]*)"/.exec(body)?.[1] ?? null;
}

function dataHooks(body: string): string[] {
  return body.match(/\sdata-(?:role|page|action|device-id|client-id|notice|tile|error)="[^"]*"/g) ?? [];
}

function visibleText(body: string): string {
  return body.replace(/<style>[\s\S]*?<\/style>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
}

async function readNotice(page: Page): Promise<Notice> {
  const notice = page.locator('[data-role="notice"]');
  await expect(notice, 'a notice is shown').toHaveCount(1, { timeout: NAV_TIMEOUT_MS });
  return notice.evaluate((el) => ({
    code: el.getAttribute('data-notice'),
    role: el.getAttribute('role'),
    label: el.querySelector('strong')?.textContent?.trim() ?? '',
    hasIcon: el.querySelector('svg[aria-hidden="true"]') !== null,
    classes: el.getAttribute('class') ?? '',
  }));
}

// ─── Scenario 1: the overview ──────────────────────────────────────────────────

Given(lit('a user with 3 devices and 2 allowed apps, in German and in English'), async ({ browser, request }: { browser: Browser; request: APIRequestContext }) => {
  await ensureUserData(browser, request);
});

When(lit('the user opens /account'), async ({ browser }: { browser: Browser }) => {
  overviews = [];
  for (const lang of [DE_AT, EN]) overviews.push({ lang, page: await openAccount(browser, lang, '/account') });
});

Then(
  lit(
    'the overview shows the headline, the counts "3 signed in" / "2 allowed", the three tiles and the navigation, and the Matrix ID and display name only inside collapsed details',
  ),
  async () => {
    expect(overviews).toHaveLength(2);

    for (const { lang, page } of overviews) {
      const c = COPY[lang.code];
      const where = `[${lang.code}]`;

      await expect(page.locator('html'), `${where} language`).toHaveAttribute('lang', lang.code);
      await expect(page.locator('main[data-page="account"][data-action="default"]'), `${where} overview`).toBeVisible();
      await expect(page.locator('h1'), `${where} one h1`).toHaveCount(1);
      await expect(page.locator('h1'), `${where} headline`).toHaveText(c.h1);
      await expect(page.locator('[data-role="signed-in-as"]'), `${where} signed in as`).toContainText(c.signedIn);

      // navigation
      await expect(page.locator('nav a'), `${where} navigation labels`).toHaveText([...c.nav]);
      await expect(page.locator('nav a').first(), `${where} the overview is current`).toHaveAttribute('aria-current', 'page');

      // tiles with live counts
      const tiles = page.locator('[data-role="portal-tile"]');
      await expect(tiles, `${where} three tiles`).toHaveCount(3);
      await expect(tiles.nth(0)).toHaveAttribute('data-tile', 'devices');
      await expect(tiles.nth(1)).toHaveAttribute('data-tile', 'apps');
      await expect(tiles.nth(2)).toHaveAttribute('data-tile', 'security');
      await expect(page.locator('[data-tile="devices"]'), `${where} device count`).toContainText(c.devices);
      await expect(page.locator('[data-tile="apps"]'), `${where} app count`).toContainText(c.apps);

      // profile: only inside the collapsed details
      const details = page.locator('details[data-role="profile-details"]');
      await expect(details, `${where} one profile details`).toHaveCount(1);
      await expect(details, `${where} collapsed on load`).not.toHaveAttribute('open', /.*/);
      await expect(details.locator('dd', { hasText: USER.matrixId }), `${where} Matrix ID hidden while collapsed`).toBeHidden();

      const displayName = ((await details.locator('dd').nth(1).textContent()) ?? '').trim();
      const outside = await page.locator('body').evaluate((body) => {
        const copy = body.cloneNode(true) as HTMLElement;
        copy.querySelectorAll('details,[data-role="signed-in-as"],script,style').forEach((n) => n.remove());
        return copy.textContent ?? '';
      });
      expect(outside, `${where} the Matrix ID is a detail`).not.toContain(USER.matrixId);
      if (displayName.length >= 3 && !/^(not set|nicht gesetzt)$/i.test(displayName)) {
        expect(outside, `${where} the display name is a detail`).not.toMatch(new RegExp(`\\b${escapeRe(displayName)}\\b`, 'i'));
      }

      await details.locator('summary').click();
      await expect(details.locator('dd', { hasText: USER.matrixId }).first(), `${where} Matrix ID shown once opened`).toBeVisible();
    }
  },
);

// ─── Scenario 2: device cards ──────────────────────────────────────────────────

Given(lit('a user with three devices'), async ({ browser, request }: { browser: Browser; request: APIRequestContext }) => {
  await ensureUserData(browser, request);
});

When(lit('the user opens the devices page at 390 px'), async ({ browser }: { browser: Browser }) => {
  phonePage = await openAccount(browser, EN, DEVICES_URL, PHONE);
});

Then(
  lit(
    "each device is a list item with its name, app and last activity and a Sign out control whose accessible name includes the device, there is no table and no horizontal scroll, and device id, IP and creation time are inside each card's collapsed details",
  ),
  async () => {
    const page = phonePage!;
    expect(page.viewportSize()).toEqual(PHONE);
    await expect(page.locator('main[data-page="account"][data-action="org.matrix.devices_list"]')).toBeVisible();
    await expect(page.locator('table'), 'no table').toHaveCount(0);

    const list = page.locator('ul[data-role="device-list"]');
    await expect(list, 'the device list is a <ul>').toHaveCount(1);
    const cards = list.locator(':scope > li[data-role="account-device"]');
    await expect(cards, 'one list item per device').toHaveCount(DEVICE_IDS.length);

    const ids = await cards.evaluateAll((els) => els.map((e) => e.getAttribute('data-device-id') ?? ''));
    expect([...ids].sort()).toEqual([...DEVICE_IDS].sort());

    for (let i = 0; i < DEVICE_IDS.length; i += 1) {
      const card = cards.nth(i);
      const id = (await card.getAttribute('data-device-id')) ?? '';
      const name = ((await card.locator('[data-role="device-name"]').textContent()) ?? '').trim();
      const where = `[${id}]`;

      expect(name, `${where} the device has a name`).not.toBe('');
      await expect(card.locator('[data-role="device-meta"]'), `${where} app and last activity`).toContainText(APP_NAME);
      await expect(card.locator('[data-role="device-meta"]'), `${where} last activity`).toContainText(/active/i);

      const signOut = card.locator('[data-role="device-row-sign-out"]');
      await expect(signOut, `${where} Sign out control`).toBeVisible();
      const label = (await signOut.getAttribute('aria-label')) ?? '';
      expect(label, `${where} accessible name includes the device name`).toContain(name);
      expect(label, `${where} accessible name includes the device id`).toContain(id);
      const box = await signOut.boundingBox();
      expect(box?.height ?? 0, `${where} touch target`).toBeGreaterThanOrEqual(44);

      const details = card.locator('details');
      await expect(details, `${where} one details block`).toHaveCount(1);
      await expect(details, `${where} collapsed on load`).not.toHaveAttribute('open', /.*/);
      await expect(details.locator('dl'), `${where} the details content is hidden`).toBeHidden();

      const outside = await card.evaluate((el) => {
        const copy = el.cloneNode(true) as HTMLElement;
        copy.querySelectorAll('details').forEach((d) => d.remove());
        return copy.textContent ?? '';
      });
      expect(outside, `${where} the device id is a detail`).not.toContain(id);
      expect(outside, `${where} the IP is a detail`).not.toMatch(/\b\d{1,3}(\.\d{1,3}){3}\b/);
      expect(outside, `${where} the creation time is a detail`).not.toMatch(/\d{4}-\d{2}-\d{2}/);

      const inside = (await details.textContent()) ?? '';
      expect(inside, `${where} the details hold the device id`).toContain(id);
      expect(inside, `${where} the details hold the creation time`).toMatch(/\d{4}-\d{2}-\d{2}/);
    }

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, 'no horizontal scroll at 390 px').toBeLessThanOrEqual(0);
  },
);

// ─── Scenario 3: sign out and withdraw ─────────────────────────────────────────

Given(lit('the devices page and the apps page'), async ({ browser, request }: { browser: Browser; request: APIRequestContext }) => {
  await ensureUserData(browser, request);
  actionPage = await openAccount(browser, EN, DEVICES_URL);
  actionRun = null;
});

When(lit('the user signs out a device and withdraws an app'), async ({ $testInfo }: { $testInfo: TestInfo }) => {
  const page = actionPage!;

  // the device: list -> confirmation -> notice
  const signedOutId = DEVICE_IDS[0];
  await page.locator(`[data-role="account-device"][data-device-id="${signedOutId}"] [data-role="device-row-sign-out"]`).click();
  await expect(page.locator('main[data-page="account"][data-action="org.matrix.device_delete"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  const confirm = page.locator('[data-role="delete-device-confirm"]');

  if (!(await confirm.isVisible())) {
    await expect(page.locator('[data-role="reauth"]'), 'a stale session gets the re-authentication link, never a silent failure').toBeVisible();
    gateY($testInfo, 'the IdP (Dex) reports no auth_time: the account session is not fresh, signing out a device is unavailable (FR14)');
  }

  await confirm.click();
  const deviceNotice = await readNotice(page);

  // the app: list -> withdraw -> notice
  await page.goto(`${NEBU_BASE_URL}/account/apps`, { waitUntil: 'domcontentloaded' });
  await expect(page.locator(`[data-role="consent-grant"][data-client-id="${CLIENT_B}"]`)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await page.locator(`[data-role="consent-grant"][data-client-id="${CLIENT_B}"] [data-role="withdraw-grant"]`).click();
  const grantNotice = await readNotice(page);

  if (grantNotice.code === 'stale') {
    gateY($testInfo, 'the IdP (Dex) reports no auth_time: the account session is not fresh, withdrawing an app is unavailable (FR14)');
  }

  actionRun = { confirmShown: true, deviceNotice, grantNotice };
});

Then(
  lit(
    'the same confirmation steps, freshness rules and notice codes apply as today, the notices are shown in the shared notice style with a text label, and the device or app is gone from the list',
  ),
  async () => {
    const page = actionPage!;
    expect(actionRun, 'the sign-out and the withdrawal ran').not.toBeNull();
    const run = actionRun!;

    expect(run.confirmShown, 'the confirmation step was shown before the device was signed out').toBe(true);

    for (const [notice, code, role] of [
      [run.deviceNotice, 'device_deleted', 'status'],
      [run.grantNotice, 'grant_withdrawn', 'status'],
    ] as const) {
      expect(notice.code, `notice code ${code}`).toBe(code);
      expect(notice.role, `${code} keeps its role`).toBe(role);
      expect(notice.label, `${code} has a text label`).not.toBe('');
      expect(notice.hasIcon, `${code} has the decorative icon`).toBe(true);
      expect(notice.classes, `${code} uses the shared notice style`).toMatch(/\bnotice\b/);
      expect(notice.classes, `${code} uses the shared notice style (icon)`).toMatch(/\bicon\b/);
    }

    // the app is gone, the other one stays
    await page.goto(`${NEBU_BASE_URL}/account/apps`, { waitUntil: 'domcontentloaded' });
    await expect(page.locator(`[data-role="consent-grant"][data-client-id="${CLIENT_B}"]`)).toHaveCount(0);
    await expect(page.locator(`[data-role="consent-grant"][data-client-id="${CLIENT_A}"]`)).toHaveCount(1);

    // the device is gone, the other two stay
    await page.goto(`${NEBU_BASE_URL}${DEVICES_URL}`, { waitUntil: 'domcontentloaded' });
    await expect(page.locator('main[data-page="account"][data-action="org.matrix.devices_list"]')).toBeVisible();
    await expect(page.locator(`[data-role="account-device"][data-device-id="${DEVICE_IDS[0]}"]`)).toHaveCount(0);
    await expect(page.locator('[data-role="account-device"]')).toHaveCount(DEVICE_IDS.length - 1);
  },
);

// ─── Scenario 4: every page and error follows the browser language ─────────────

Given(lit('the portal pages, the signed-out page and each of the 12 account error codes'), async ({ browser, request }: { browser: Browser; request: APIRequestContext }) => {
  await ensureUserData(browser, request);
  seen = [];
});

When(lit('they are rendered with "Accept-Language: de" and with none'), async ({ browser }: { browser: Browser }) => {
  const pages = [
    { name: 'overview', path: '/account', action: 'default' },
    { name: 'profile', path: '/account?action=org.matrix.profile', action: 'org.matrix.profile' },
    { name: 'devices', path: DEVICES_URL, action: 'org.matrix.devices_list' },
    { name: 'device', path: `/account?action=org.matrix.device_view&device_id=${DEVICE_IDS[0]}`, action: 'org.matrix.device_view' },
    { name: 'delete', path: `/account?action=org.matrix.device_delete&device_id=${DEVICE_IDS[1]}`, action: 'org.matrix.device_delete' },
    { name: 'reset', path: '/account?action=org.matrix.cross_signing_reset', action: 'org.matrix.cross_signing_reset' },
    { name: 'apps', path: '/account/apps', action: 'apps' },
  ];

  for (const lang of [DE, EN]) {
    const page = await openAccount(browser, lang, '/account');
    const ctx = page.context();

    const record = async (name: string, r: { status(): number; headers(): Record<string, string>; text(): Promise<string> }) =>
      seen.push({ lang, name, status: r.status(), headers: r.headers(), body: await r.text() });

    for (const p of pages) await record(p.name, await ctx.request.get(`${NEBU_BASE_URL}${p.path}`, { maxRedirects: 0 }));

    // the errors that can be provoked black-box (all 12 are pinned by the ExUnit test)
    await record('not_found', await ctx.request.get(`${NEBU_BASE_URL}/account/no-such-page`, { maxRedirects: 0 }));
    await record('method_not_allowed', await ctx.request.fetch(`${NEBU_BASE_URL}/account`, { method: 'PUT', maxRedirects: 0 }));

    // the signed-out page: the real sign-out control
    const signedOut = page.waitForResponse((r) => new URL(r.url()).pathname === '/account/logout' && r.request().method() === 'POST');
    await page.goto(`${NEBU_BASE_URL}/account`, { waitUntil: 'domcontentloaded' });
    await page.locator('[data-role="sign-out"]').click();
    await record('signed_out', await signedOut);
  }
});

Then(
  lit(
    'each is German respectively English with the same data hooks, status codes and headers as before, and the catalog test finds no missing key',
  ),
  async () => {
    const expected: Record<string, { status: number; page: 'account' | 'account-error' }> = {
      overview: { status: 200, page: 'account' },
      profile: { status: 200, page: 'account' },
      devices: { status: 200, page: 'account' },
      device: { status: 200, page: 'account' },
      delete: { status: 200, page: 'account' },
      reset: { status: 200, page: 'account' },
      apps: { status: 200, page: 'account' },
      not_found: { status: 404, page: 'account-error' },
      method_not_allowed: { status: 405, page: 'account-error' },
    };

    const names = Object.keys(expected);
    expect(seen.filter((s) => s.lang.code === 'de' && s.name !== 'signed_out')).toHaveLength(names.length);
    const bySide = (code: 'de' | 'en', name: string): Seen => {
      const found = seen.find((s) => s.lang.code === code && s.name === name);
      expect(found, `[${code} ${name}] was rendered`).toBeTruthy();
      return found!;
    };

    for (const name of [...names, 'signed_out']) {
      const de = bySide('de', name);
      const en = bySide('en', name);
      const e = expected[name] ?? { status: 200, page: 'account' as const };
      const where = `[${name}]`;

      for (const s of [de, en]) {
        expect(s.status, `${where} ${s.lang.code} status`).toBe(e.status);
        expect(htmlLang(s.body), `${where} browser language`).toBe(s.lang.code);
        expect(s.body, `${where} ${s.lang.code} data-page`).toContain(`data-page="${e.page}"`);
        expect(s.body.match(/<h1[\s>]/g) ?? [], `${where} ${s.lang.code} one h1`).toHaveLength(1);
        expect(s.body.match(/<main[\s>]/g) ?? [], `${where} ${s.lang.code} one main`).toHaveLength(1);
        expect(s.body, `${where} ${s.lang.code} shell logo`).toContain('class="logo"');
        expect(s.body, `${where} ${s.lang.code} no unresolved key`).not.toMatch(/translation missing|missing translation|undefined|\bnil\b/i);
        expect(s.headers['cache-control'], `${where} cache-control`).toContain('no-store');
        expect(s.headers['pragma'], `${where} pragma`).toBe('no-cache');
        expect(s.headers['x-frame-options'], `${where} x-frame-options`).toBe('DENY');
        expect(s.headers['referrer-policy'], `${where} referrer-policy`).toBe('same-origin');
        expect(s.headers['content-security-policy'], `${where} csp`).toMatch(/default-src 'none'/);
        expect(s.headers['content-security-policy'], `${where} csp form-action`).toContain("form-action 'self'");
      }

      // same hooks, same headers, translated text
      expect(dataHooks(de.body), `${where} the same data hooks in both languages`).toEqual(dataHooks(en.body));
      expect(de.headers['content-security-policy'], `${where} the CSP does not depend on the language`).toBe(en.headers['content-security-policy']);
      expect(/<h1[^>]*>([\s\S]*?)<\/h1>/.exec(de.body)?.[1], `${where} heading translated`).not.toBe(/<h1[^>]*>([\s\S]*?)<\/h1>/.exec(en.body)?.[1]);

      const german = visibleText(de.body);
      for (const phrase of ENGLISH_UI) expect(german, `${where} no English text ${JSON.stringify(phrase)} on the German page`).not.toContain(phrase);
    }

    expect(bySide('de', 'method_not_allowed').headers['allow'], 'Allow on the 405 page').toBe('GET');
  },
);

// ─── Scenario 5: the reset page keeps its click proof ──────────────────────────

Given(lit('the encryption reset page with a pending request'), async ({ browser, request }: { browser: Browser; request: APIRequestContext }) => {
  await ensureUserData(browser, request);
  const token = tokens[DEVICE_IDS[0]];

  const upload = async (keys: Record<string, unknown>): Promise<{ status: number; body: Record<string, unknown> }> => {
    const r = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/keys/device_signing/upload`, {
      headers: { Authorization: `Bearer ${token}` },
      data: keys,
    });
    return { status: r.status(), body: ((await r.text()) ? await r.json() : {}) as Record<string, unknown> };
  };

  const keySet = (): Record<string, unknown> => {
    const pub = `E2EMASTER${randomBytes(16).toString('hex')}`;
    return { master_key: { user_id: USER.matrixId, usage: ['master'], keys: { [`ed25519:${pub}`]: pub } } };
  };

  // the first upload stores the keys; when a key set of an earlier run exists it already is a replacement that needs the challenge
  let result = await upload(keySet());
  if (result.status === 200) result = await upload(keySet());
  expect(result.status, `the key upload asks for the m.oauth challenge: ${JSON.stringify(result.body)}`).toBe(401);

  const params = result.body.params as Record<string, { url?: string }> | undefined;
  const url = params?.['m.oauth']?.url ?? '';
  expect(url, 'the challenge carries the account page URL').not.toBe('');
  const parsed = new URL(url);
  challengeUrl = `${NEBU_BASE_URL}${parsed.pathname}${parsed.search}`;
});

When(lit('it is rendered in the new layout'), async ({ browser }: { browser: Browser }) => {
  const ctx = await newContext(browser, EN);
  const page = await ctx.newPage();
  await page.goto(challengeUrl, { waitUntil: 'domcontentloaded' });
  await dexLogin(page);
  await expect(page.locator('main[data-page="account"][data-action="org.matrix.cross_signing_reset"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });

  // reset requests left over from an earlier run would turn the click-proof check into a skip: decline them until exactly one is left
  // (only possible with a fresh session; without auth_time the Then step records the gate instead)
  const requestCards = page.locator('[data-role="reset-request"]');
  const declineButtons = page.locator('[data-role="decline-reset"]');
  for (let left = await requestCards.count(); left > 1 && (await declineButtons.count()) > 0; left -= 1) {
    await declineButtons.first().click();
    await expect(requestCards, 'a leftover reset request was declined').toHaveCount(left - 1, { timeout: NAV_TIMEOUT_MS });
  }

  const again = await ctx.request.get(page.url(), { maxRedirects: 0 });
  resetRun = { page, csp: again.headers()['content-security-policy'] ?? '' };
});

Then(
  lit(
    'the approve form still embeds the click-proof script allowed by its SHA-256, Approve and Decline are two clearly separated buttons with Decline first, and no other script is added',
  ),
  async ({ $testInfo }: { $testInfo: TestInfo }) => {
    const { page, csp } = resetRun!;
    const requests = await page.locator('[data-role="reset-request"]').count();
    const approve = page.locator('[data-role="approve-reset"]');
    const decline = page.locator('[data-role="decline-reset"]');

    if ((await approve.count()) === 0) {
      gateY($testInfo, 'the IdP (Dex) reports no auth_time: the account session is not fresh, the approve form is not rendered (FR14)');
    }

    expect(requests, 'exactly one reset request is pending (leftovers are declined in the When step)').toBe(1);

    // exactly one script: the click proof, allowed by its SHA-256 and nothing else
    const scripts = page.locator('script');
    await expect(scripts, 'exactly one script element').toHaveCount(1);
    const js = (await scripts.first().textContent()) ?? '';
    const hash = `'sha256-${createHash('sha256').update(js).digest('base64')}'`;
    const scriptSrc = /(?:^|;)\s*script-src ([^;]*)/.exec(csp)?.[1]?.trim();
    expect(scriptSrc, 'script-src is exactly the hash of the inline script').toBe(hash);
    expect(csp, 'no unsafe source').not.toMatch(/unsafe-/);
    await expect(page.locator('input[data-click-proof]'), 'the click-proof field is in the approve form').toHaveCount(1);
    await expect(page.locator('form:has([data-role="approve-reset"]) input[data-click-proof]')).toHaveCount(1);

    // Decline first, two separate forms, clearly separated, big targets
    await expect(approve).toBeVisible();
    await expect(decline).toBeVisible();
    const order = await page.evaluate(() => {
      const d = document.querySelector('[data-role="decline-reset"]') as HTMLElement;
      const a = document.querySelector('[data-role="approve-reset"]') as HTMLElement;
      return {
        declineFirst: (d.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0,
        separateForms: d.closest('form') !== null && a.closest('form') !== null && d.closest('form') !== a.closest('form'),
      };
    });
    expect(order.declineFirst, 'Decline comes before Approve in the DOM').toBe(true);
    expect(order.separateForms, 'Approve and Decline are two separate forms').toBe(true);

    const d = await decline.boundingBox();
    const a = await approve.boundingBox();
    expect(d && a, 'both buttons have a box').toBeTruthy();
    expect(d!.height, 'Decline is a big target').toBeGreaterThanOrEqual(44);
    expect(a!.height, 'Approve is a big target').toBeGreaterThanOrEqual(44);
    const gapX = Math.max(a!.x - (d!.x + d!.width), d!.x - (a!.x + a!.width));
    const gapY = Math.max(a!.y - (d!.y + d!.height), d!.y - (a!.y + a!.height));
    expect(Math.max(gapX, gapY), 'a visible gap between the two buttons').toBeGreaterThanOrEqual(8);
  },
);
