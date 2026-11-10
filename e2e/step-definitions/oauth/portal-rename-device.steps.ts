/**
 * Step definitions for features/oauth-pages-redesign/06-portal-rename-device.feature
 *
 * Story: oauth-pages-redesign / 06-portal-rename-device (REQ-2026-021). Runs only against the full compose stack with the real Dex
 * (NOT executable in the isolated env, same as the other stories of this epic). ATDD RED phase: the portal has no rename page yet.
 *
 * The feature file has no Background (verbatim Gherkin of the story), so a `@REQ-2026-021` Before hook enables OAuth with the e2e issuer and an After hook
 * restores the prior config and removes every fixture. Step files share no module state, so the helpers below (Dex sign-in, Allow arming, PKCE, device
 * creation) are copies of the ones in portal-redesign.steps.ts. Every step text of this feature is new (bddgen rejects duplicates).
 *
 * The user is `tom` (a user nobody else touches). Two real OAuth devices through one approved native client; the "other user's device" is a bare `devices`
 * row of `marie` (inserted by SQL, only when marie has a `users` row; otherwise the scenario uses the unknown device id only and says so in an annotation).
 *
 * A real Dex may report no auth_time (gate y, FR14): every scenario needs a FRESH portal session, so it is skipped with a `gate-y` annotation in that case,
 * never silently passed. The "stale" scenario ages the session by SQL after the form was opened (the form is only offered to a fresh session).
 *
 * Contract (server/test/nebu/oauth/portal_rename_device_test.exs): the devices list card carries `[data-role="device-row-rename"]` (a link to
 * `/account/devices/rename?device_id=<id>`); the page is `main[data-page="account"][data-action="device_rename"]` with `form[data-role="rename-device-form"]`
 * (hidden `device_id`, `csrf_token`; text input `device_name` with a `<label for>`), Save `[data-role="rename-save"]` and Cancel `[data-role="rename-cancel"]`
 * inside one `.actions` container; notices `[data-role="notice"][data-notice=<code>]`; the stale notice comes with `[data-role="reauth"]`.
 * The admin user page reads `Nebu.Matrix.list_user_devices/1`, i.e. the same `devices.display_name` column the check below reads.
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
  queryAccountSessionAuthTime,
  queryUserDeviceDisplayName,
  setUserDeviceDisplayName,
  ageAccountSessionAuthTime,
  insertUserDeviceRow,
  deleteUserDeviceRow,
  deleteUserRowIfCreated,
} from '../../fixtures/db';
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const CLIENT_PREFIX = 'e2e-portal-rename-';
const CLIENT_ID = `${CLIENT_PREFIX}app`;
const APP_NAME = 'Rename Test App';
const DEVICE_A = 'E2ERENAME1';
const DEVICE_B = 'E2ERENAME2';
const FOREIGN_DEVICE = 'E2ERENAMEF';
const UNKNOWN_DEVICE = 'E2ERENAMEX';
const OLD_NAME = 'OAuth client (CdEfGhIj)';
const OTHER_NAME = 'Second device';
const FOREIGN_NAME = 'Marie private device';
const USER = NEBU_USERS.tom;
const FOREIGN_USER = NEBU_USERS.marie;
const STABLE = 'urn:matrix:client:';
const CONSENT_PATH = '/oauth2/consent';
const LOOPBACK_ORIGIN = 'http://localhost:53682';
const LOOPBACK_REDIRECT = `${LOOPBACK_ORIGIN}/cb`;
const DEVICES_URL = '/account?action=org.matrix.devices_list';
const PHONE = { width: 390, height: 844 };

type Lang = { code: 'de' | 'en'; locale: string };
const DE: Lang = { code: 'de', locale: 'de-AT' };
const EN: Lang = { code: 'en', locale: 'en-US' };

const COPY = {
  en: { save: 'Save', cancel: 'Cancel' },
  de: { save: 'Speichern', cancel: 'Abbrechen' },
} as const;

/** English UI texts of the rename page that must not survive on a German page. */
const ENGLISH_UI = ['Cancel', 'Save', 'Rename', 'Device name', 'Back to'];

/** A step text with characters that are special in a Cucumber expression ( ) / "..." as an exact regular expression. */
const lit = (text: string): RegExp => new RegExp('^' + text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') + '$');

type Notice = { code: string | null; role: string | null; label: string; hasIcon: boolean };
type Submitted = { label: string; notice: Notice; stored: string | null };

let priorIssuer: string | null = null;
let contexts: BrowserContext[] = [];
let tokens: Record<string, string> = {};
let dataReady = false;
let foreignUserCreated = false;
let page: Page | null = null;
let notice: Notice | null = null;
let staleHasReauth = false;
let submitted: Submitted[] = [];
let pages: { lang: Lang; page: Page }[] = [];

// ─── Hooks ─────────────────────────────────────────────────────────────────────

function wipe(): void {
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  for (const id of [DEVICE_A, DEVICE_B]) clearDeviceOfUser(USER.matrixId, id);
  deleteUserDeviceRow(FOREIGN_USER.matrixId, FOREIGN_DEVICE);
  if (foreignUserCreated) deleteUserRowIfCreated(FOREIGN_USER.matrixId);
  foreignUserCreated = false;
  clearAccountSessions(USER.matrixId);
}

Before({ tags: '@REQ-2026-021' }, async () => {
  contexts = [];
  tokens = {};
  dataReady = false;
  page = null;
  notice = null;
  staleHasReauth = false;
  submitted = [];
  pages = [];
  wipe();
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  upsertServerConfig('oauth_issuer_url', E2E_ISSUER);
  upsertServerConfig('oauth_enabled', 'true');
});

// Order: sessions + devices (matrix_sessions.client_id is ON DELETE RESTRICT), grants and consent rows, then the clients. Failures are NOT swallowed.
After({ tags: '@REQ-2026-021' }, async () => {
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

async function approveDexGrantIfShown(p: Page): Promise<void> {
  // Acts ONLY on Dex's own approval page: the name regex would also match Nebu's consent button "Allow" (G3-5).
  const branch = await Promise.race([
    p.waitForURL((url) => url.pathname.includes('/dex/approval'), { timeout: 6_000 }).then(() => 'approval' as const),
    p.waitForURL((url) => !/^\/dex(\/|$)/i.test(url.pathname), { timeout: 6_000 }).then(() => 'left-dex' as const),
  ]).catch(() => 'none' as const);
  if (branch !== 'approval') return;
  await p.getByRole('button', { name: /^(grant access|approve|confirm)$/i }).click();
}

async function dexLogin(p: Page): Promise<void> {
  await p.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = p.locator('input[name="login"]');
  await expect(login, 'Dex login form').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(USER.email);
  await p.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await p.locator('button[type="submit"]').click();
  await approveDexGrantIfShown(p);
}

/** The consent POST is checked against the ISSUER origin (FR8): the e2e issuer is a fake https URL, so the browser's Origin is replaced. */
async function useIssuerOriginForConsent(p: Page): Promise<void> {
  await p.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** Allow is armed by REAL pointer movement elsewhere, then hovered (copy of armAllow in oauth-authorize.steps.ts). */
async function armAllow(p: Page): Promise<void> {
  const allow = p.locator('button[name="decision"][value="allow"]');
  await p.mouse.move(40, 40);
  await p.mouse.move(90, 110, { steps: 6 });
  await expect(allow, 'Allow is armed by real pointer movement').not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
  await p.mouse.move(4, 4);
  await allow.hover();
}

/** A real OAuth device of the user: authorize + Dex + (consent, unless the grant is remembered) + token. Returns the access token. */
async function createDevice(browser: Browser, request: APIRequestContext, deviceId: string): Promise<string> {
  const { verifier, challenge } = pkcePair();
  const ctx = await browser.newContext();

  try {
    const p = await ctx.newPage();
    await p.route(`${LOOPBACK_ORIGIN}/**`, (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>client stub</title>' }),
    );

    const qs = new URLSearchParams({
      response_type: 'code',
      client_id: CLIENT_ID,
      redirect_uri: LOOPBACK_REDIRECT,
      scope: `${STABLE}api:* ${STABLE}device:${deviceId}`,
      state: `e2e-rename-${randomBytes(6).toString('hex')}`,
      code_challenge: challenge,
      code_challenge_method: 'S256',
    });

    await p.goto(`${NEBU_BASE_URL}/oauth2/authorize?${qs.toString()}`, { waitUntil: 'domcontentloaded' });
    await dexLogin(p);
    await p.waitForURL((url) => url.pathname === CONSENT_PATH || url.href.startsWith(LOOPBACK_REDIRECT), { timeout: NAV_TIMEOUT_MS });

    if (new URL(p.url()).pathname === CONSENT_PATH) {
      await useIssuerOriginForConsent(p);
      await armAllow(p);
      await p.locator('button[name="decision"][value="allow"]').click();
      await p.waitForURL((url) => url.href.startsWith(LOOPBACK_REDIRECT), { timeout: NAV_TIMEOUT_MS });
    }

    const code = new URL(p.url()).searchParams.get('code');
    expect(code, 'the authorize flow issued a code').toBeTruthy();

    const token = await request.post(`${NEBU_BASE_URL}/oauth2/token`, {
      form: { grant_type: 'authorization_code', code: code!, redirect_uri: LOOPBACK_REDIRECT, code_verifier: verifier, client_id: CLIENT_ID },
    });

    expect(token.status(), `token endpoint: ${await token.text()}`).toBe(200);
    return ((await token.json()) as { access_token: string }).access_token;
  } finally {
    await ctx.close();
  }
}

/** Two devices of the user (the first named "OAuth client (CdEfGhIj)"), and the foreign device row, once per scenario. */
async function ensureUserData(browser: Browser, request: APIRequestContext): Promise<void> {
  if (dataReady) return;
  insertOAuthClient({
    clientId: CLIENT_ID,
    status: 'approved',
    redirectUris: ['http://localhost/cb'],
    applicationType: 'native',
    clientUri: `https://${CLIENT_ID}.e2e.example`,
    clientName: APP_NAME,
  });

  tokens[DEVICE_A] = await createDevice(browser, request, DEVICE_A);
  tokens[DEVICE_B] = await createDevice(browser, request, DEVICE_B);
  setUserDeviceDisplayName(USER.matrixId, DEVICE_A, OLD_NAME);
  setUserDeviceDisplayName(USER.matrixId, DEVICE_B, OTHER_NAME);
  foreignUserCreated = insertUserDeviceRow(FOREIGN_USER.matrixId, FOREIGN_DEVICE, FOREIGN_NAME);
  dataReady = true;
}

async function openAccount(browser: Browser, lang: Lang, path: string, viewport?: { width: number; height: number }): Promise<Page> {
  const ctx = await browser.newContext({ locale: lang.locale, ...(viewport ? { viewport } : {}) });
  contexts.push(ctx);
  const p = await ctx.newPage();
  await p.goto(`${NEBU_BASE_URL}${path}`, { waitUntil: 'domcontentloaded' });
  await dexLogin(p);
  await expect(p.locator('main[data-page="account"]'), 'the portal is shown after the IdP login').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  return p;
}

function renameUrl(deviceId: string): string {
  return `${NEBU_BASE_URL}/account/devices/rename?device_id=${encodeURIComponent(deviceId)}`;
}

/** Every scenario needs a fresh portal session; a Dex without auth_time cannot give one. */
function requireFresh($testInfo: TestInfo): void {
  if (queryAccountSessionAuthTime(USER.matrixId) === null) {
    gateY($testInfo, 'the IdP (Dex) reports no auth_time: the account session is not fresh, renaming a device is unavailable (FR14)');
  }
}

async function openRenamePage(p: Page, deviceId: string): Promise<void> {
  await p.goto(renameUrl(deviceId), { waitUntil: 'domcontentloaded' });
  await expect(p.locator('main[data-page="account"][data-action="device_rename"]'), 'the rename page').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(p.locator('form[data-role="rename-device-form"]'), 'the rename form (fresh session)').toBeVisible();
}

async function readNotice(p: Page): Promise<Notice> {
  const n = p.locator('[data-role="notice"]');
  await expect(n, 'a notice is shown').toHaveCount(1, { timeout: NAV_TIMEOUT_MS });
  return n.evaluate((el) => ({
    code: el.getAttribute('data-notice'),
    role: el.getAttribute('role'),
    label: el.querySelector('strong')?.textContent?.trim() ?? '',
    hasIcon: el.querySelector('svg[aria-hidden="true"]') !== null,
  }));
}

async function saveName(p: Page, name: string): Promise<Notice> {
  await p.locator('form[data-role="rename-device-form"] input[name="device_name"]').fill(name);
  await p.locator('[data-role="rename-save"]').click();
  return readNotice(p);
}

async function matrixDevices(request: APIRequestContext, token: string): Promise<{ device_id: string; display_name?: string }[]> {
  const res = await request.get(`${NEBU_BASE_URL}/_matrix/client/v3/devices`, { headers: { Authorization: `Bearer ${token}` } });
  expect(res.status(), `GET /devices: ${await res.text()}`).toBe(200);
  return ((await res.json()) as { devices: { device_id: string; display_name?: string }[] }).devices;
}

// ─── Scenario 1: a fresh user renames a device ─────────────────────────────────

Given(
  lit('a user signed in to the portal within the last 5 minutes with a device named "OAuth client (CdEfGhIj)"'),
  async ({ browser, request, $testInfo }: { browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
    await ensureUserData(browser, request);
    page = await openAccount(browser, EN, DEVICES_URL);
    requireFresh($testInfo);
    await expect(
      page.locator(`[data-role="account-device"][data-device-id="${DEVICE_A}"] [data-role="device-name"]`),
      'the device carries the old name',
    ).toHaveText(OLD_NAME);
  },
);

When(lit('the user opens Rename on that device, enters "Annas Handy" and saves'), async () => {
  const p = page!;
  await p.locator(`[data-role="account-device"][data-device-id="${DEVICE_A}"] [data-role="device-row-rename"]`).click();
  await expect(p.locator('main[data-page="account"][data-action="device_rename"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(p.locator('input[name="device_name"]'), 'the form starts from the current name').toHaveValue(OLD_NAME);
  notice = await saveName(p, 'Annas Handy');
});

Then(
  lit('the device list shows "Annas Handy" with the notice "device_renamed", and Matrix GET /devices and the admin user page show the same name'),
  async ({ request }: { request: APIRequestContext }) => {
    const p = page!;
    expect(notice!.code, 'notice code').toBe('device_renamed');
    expect(notice!.role, 'device_renamed is a status').toBe('status');
    expect(notice!.label, 'the notice has a text label').not.toBe('');
    expect(notice!.hasIcon, 'the notice has the decorative icon').toBe(true);

    await expect(p.locator('main[data-page="account"][data-action="org.matrix.devices_list"]'), 'back on the device list').toBeVisible();
    await expect(
      p.locator(`[data-role="account-device"][data-device-id="${DEVICE_A}"] [data-role="device-name"]`),
      'the list shows the new name',
    ).toHaveText('Annas Handy');
    await expect(p.locator(`[data-role="account-device"][data-device-id="${DEVICE_B}"] [data-role="device-name"]`)).toHaveText(OTHER_NAME);

    const devices = await matrixDevices(request, tokens[DEVICE_A]);
    expect(devices.find((d) => d.device_id === DEVICE_A)?.display_name, 'Matrix GET /devices').toBe('Annas Handy');
    expect(devices.find((d) => d.device_id === DEVICE_B)?.display_name, 'the other device is untouched').toBe(OTHER_NAME);
    // The admin user page lists `Nebu.Matrix.list_user_devices/1`: the same `devices.display_name` column.
    expect(queryUserDeviceDisplayName(USER.matrixId, DEVICE_A), 'the stored name (admin user page)').toBe('Annas Handy');
  },
);

// ─── Scenario 2: a stale session must confirm first ────────────────────────────

Given(
  lit('a user whose portal sign-in is older than 5 minutes'),
  async ({ browser, request, $testInfo }: { browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
    await ensureUserData(browser, request);
    page = await openAccount(browser, EN, DEVICES_URL);
    requireFresh($testInfo);
    // the form is only offered to a fresh session: open it first, then let the sign-in grow old
    await openRenamePage(page, DEVICE_A);
    await page.locator('input[name="device_name"]').fill('Sneaky name');
    ageAccountSessionAuthTime(USER.matrixId, 400);
  },
);

When(lit('the user submits a rename'), async () => {
  const p = page!;
  await p.locator('[data-role="rename-save"]').click();
  notice = await readNotice(p);
  staleHasReauth = await p.locator('[data-role="reauth"]').isVisible();
});

Then(lit('the response is a 303 with notice "stale" and the "Confirm it is you" link, and the device name is unchanged'), async ({ request }: { request: APIRequestContext }) => {
  expect(notice!.code, 'notice code').toBe('stale');
  expect(notice!.role, 'stale is an alert').toBe('alert');
  expect(staleHasReauth, 'the "Confirm it is you" re-authentication link is offered').toBe(true);
  // a browser form POST answered with a 303 lands on the device list (the redirect target of every portal action)
  await expect(page!.locator('main[data-page="account"]')).toBeVisible();
  expect(queryUserDeviceDisplayName(USER.matrixId, DEVICE_A), 'the stored name is unchanged').toBe(OLD_NAME);
  const devices = await matrixDevices(request, tokens[DEVICE_A]);
  expect(devices.find((d) => d.device_id === DEVICE_A)?.display_name, 'Matrix GET /devices is unchanged').toBe(OLD_NAME);
});

// ─── Scenario 3: another user's device cannot be renamed ───────────────────────

Given(
  lit('a device id that belongs to another user, or does not exist'),
  async ({ browser, request, $testInfo }: { browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
    await ensureUserData(browser, request);
    page = await openAccount(browser, EN, DEVICES_URL);
    requireFresh($testInfo);
  },
);

When(lit('the portal user submits a rename for it'), async () => {
  const p = page!;
  submitted = [];

  const ids = [FOREIGN_DEVICE, UNKNOWN_DEVICE];

  for (const id of ids) {
    // the form of the user's own device, with the hidden device id swapped for the foreign / unknown one
    await openRenamePage(p, DEVICE_A);
    await p.locator('form[data-role="rename-device-form"] input[name="device_id"]').evaluate((el, value) => {
      (el as HTMLInputElement).value = value;
    }, id);
    const n = await saveName(p, 'Taken over');
    submitted.push({ label: id, notice: n, stored: queryUserDeviceDisplayName(FOREIGN_USER.matrixId, FOREIGN_DEVICE) });
  }
});

Then(lit('the notice "device_not_found" is shown and no device of any user is changed'), async ({ request }: { request: APIRequestContext }) => {
  expect(submitted.length, 'at least one submission').toBeGreaterThan(0);

  for (const s of submitted) {
    expect(s.notice.code, `${s.label}: notice code`).toBe('device_not_found');
    expect(s.notice.role, `${s.label}: device_not_found is an alert`).toBe('alert');
  }

  expect(queryUserDeviceDisplayName(USER.matrixId, DEVICE_A), 'the own device is unchanged').toBe(OLD_NAME);
  expect(queryUserDeviceDisplayName(USER.matrixId, DEVICE_B), 'the own other device is unchanged').toBe(OTHER_NAME);
  expect(queryUserDeviceDisplayName(USER.matrixId, UNKNOWN_DEVICE), 'no row was created').toBeNull();
  expect(queryUserDeviceDisplayName(FOREIGN_USER.matrixId, FOREIGN_DEVICE), 'the other user device is unchanged').toBe(FOREIGN_NAME);

  const devices = await matrixDevices(request, tokens[DEVICE_A]);
  expect(devices.find((d) => d.device_id === DEVICE_A)?.display_name, 'Matrix GET /devices is unchanged').toBe(OLD_NAME);
});

// ─── Scenario 4: a hostile or empty name ───────────────────────────────────────

Given(lit('the rename form of a device'), async ({ browser, request, $testInfo }: { browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
  await ensureUserData(browser, request);
  page = await openAccount(browser, EN, DEVICES_URL);
  requireFresh($testInfo);
  await openRenamePage(page, DEVICE_A);
});

When(lit('the user submits "<b>Work\\u0007 laptop</b>", then a name of only invisible characters, then a 500 character name'), async () => {
  const p = page!;
  submitted = [];

  const attempts: [string, string][] = [
    ['markup and a control character', '<b>Work\u0007 laptop</b>'],
    ['only invisible characters', '\u200B\u200D\u2060\u00AD'],
    ['500 characters (multi-byte)', 'ä'.repeat(500)],
  ];

  for (const [label, value] of attempts) {
    await openRenamePage(p, DEVICE_A);
    const n = await saveName(p, value);
    submitted.push({ label, notice: n, stored: queryUserDeviceDisplayName(USER.matrixId, DEVICE_A) });
  }
});

Then(
  lit(
    'the names are stored as "Work laptop" and cut to 64 code points respectively, the invisible-only name is refused with "device_name_invalid" and the old name stays',
  ),
  async ({ request }: { request: APIRequestContext }) => {
    expect(submitted).toHaveLength(3);
    const [markup, invisible, long] = submitted;

    expect(markup.notice.code, 'markup: notice').toBe('device_renamed');
    expect(markup.stored, 'markup and control character removed').toBe('Work laptop');

    expect(invisible.notice.code, 'invisible-only: notice').toBe('device_name_invalid');
    expect(invisible.notice.role, 'device_name_invalid is an alert').toBe('alert');
    expect(invisible.stored, 'the old name stays').toBe('Work laptop');

    expect(long.notice.code, '500 characters: notice').toBe('device_renamed');
    expect(Array.from(long.stored ?? '').length, 'cut to 64 code points').toBe(64);
    expect(long.stored, 'the first 64 characters are kept').toBe('ä'.repeat(64));

    const devices = await matrixDevices(request, tokens[DEVICE_A]);
    expect(devices.find((d) => d.device_id === DEVICE_A)?.display_name, 'Matrix GET /devices shows the stored name').toBe('ä'.repeat(64));
  },
);

// ─── Scenario 5: the rename page, both languages, 390 px, no script ────────────

Given(
  lit('the rename page in German and in English at 390 px and without JavaScript'),
  async ({ browser, request, $testInfo }: { browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
    await ensureUserData(browser, request);
    pages = [];

    for (const lang of [DE, EN]) {
      const p = await openAccount(browser, lang, DEVICES_URL, PHONE);
      if (pages.length === 0) requireFresh($testInfo);
      pages.push({ lang, page: p });
    }
  },
);

When(lit('it is rendered'), async () => {
  for (const { page: p } of pages) await openRenamePage(p, DEVICE_A);
});

Then(
  lit('it has one main and one h1, a label tied to the field, a visible focus ring, 44 px controls, Cancel next to Save, and every text comes from the catalog'),
  async () => {
    expect(pages).toHaveLength(2);

    for (const { lang, page: p } of pages) {
      const c = COPY[lang.code];
      const where = `[${lang.code}]`;
      expect(p.viewportSize(), `${where} phone viewport`).toEqual(PHONE);

      await expect(p.locator('html'), `${where} language`).toHaveAttribute('lang', lang.code);
      await expect(p.locator('main'), `${where} one main`).toHaveCount(1);
      await expect(p.locator('h1'), `${where} one h1`).toHaveCount(1);

      // the page needs no script
      await expect(p.locator('script'), `${where} no script element (works without JavaScript)`).toHaveCount(0);
      const overflow = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow, `${where} no horizontal scroll at 390 px`).toBeLessThanOrEqual(0);

      // a label tied to the field
      const input = p.locator('form[data-role="rename-device-form"] input[name="device_name"]');
      const fieldId = await input.getAttribute('id');
      expect(fieldId, `${where} the field has an id`).toBeTruthy();
      const label = p.locator(`label[for="${fieldId}"]`);
      await expect(label, `${where} a label is tied to the field`).toHaveCount(1);
      expect(((await label.textContent()) ?? '').trim(), `${where} the label has text`).not.toBe('');

      // 44 px controls, Cancel next to Save
      const save = p.locator('[data-role="rename-save"]');
      const cancel = p.locator('[data-role="rename-cancel"]');
      await expect(save, `${where} Save`).toHaveText(c.save);
      await expect(cancel, `${where} Cancel`).toHaveText(c.cancel);
      const boxes = { input: await input.boundingBox(), save: await save.boundingBox(), cancel: await cancel.boundingBox() };
      for (const [name, box] of Object.entries(boxes)) {
        expect(box, `${where} ${name} is laid out`).not.toBeNull();
        expect(box!.height, `${where} ${name} is at least 44 px high`).toBeGreaterThanOrEqual(44);
      }
      expect(Math.abs(boxes.save!.y - boxes.cancel!.y), `${where} Cancel is on the row of Save`).toBeLessThan(12);

      // a visible focus ring on the keyboard path input -> Save
      await input.focus();
      await p.keyboard.press('Tab');
      await expect(save, `${where} Save is focused by Tab`).toBeFocused();
      const ring = await save.evaluate((el) => {
        const s = getComputedStyle(el);
        return { style: s.outlineStyle, width: parseFloat(s.outlineWidth) };
      });
      expect(ring.style, `${where} focus outline style`).not.toBe('none');
      expect(ring.width, `${where} focus outline width`).toBeGreaterThanOrEqual(2);

      // every text comes from the catalog: no English UI text on the German page
      if (lang.code === 'de') {
        const text = await p.locator('body').innerText();
        for (const word of ENGLISH_UI) expect(text, `${where} English UI text "${word}"`).not.toContain(word);
      }
    }
  },
);
