/**
 * Step definitions for features/oauth/oauth-account-management.feature
 *
 * Story: oauth-broker / oauth-account-management (story 6) — ATDD RED phase (written before the
 * implementation; runs only against the full compose stack with the real Dex; NOT executable in the
 * isolated ATDD environment: verified with `bddgen --tags "@oauth-account"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Reused steps (defined in oauth-authorize.steps.ts, never redefined here — bddgen rejects
 * duplicates): "OAuth is enabled with an https issuer", "an approved native client {string} with
 * redirect URI {string}", "the user signs in at the IdP" (alex at Dex, waits until the browser left
 * Dex and the shared callback) and "the page contains no script element".
 *
 * The OAuth client is played here: the Background's OAuth session is obtained in a SEPARATE browser
 * context (so the account page's context starts without any Dex state) through the REAL
 * GET /oauth2/authorize + Dex + shared callback, the loopback redirect (http://localhost:53682/cb,
 * RFC 8252 port-agnostic match of the registered http://localhost/cb) is intercepted, and the code is
 * redeemed at POST /oauth2/token through the APIRequestContext (PKCE S256).
 *
 * Story oauth-authorize-freshness (P3): the OAuth session of the Background now passes the consent screen
 * (the client "follows the 303" to /oauth2/consent and the user clicks Allow, FR1) before the code exists.
 * Gate y is fail closed (FR14): "the IdP reports the sign-in time" probes the real Dex (a separate login
 * on the account page) and SKIPS the scenario with a `gate-y` annotation when no auth_time arrives; the
 * freshness scenario asserts "fresh, or absent with the destructive actions unavailable".
 *
 * Page contract (story A20, shared with server/test/nebu/oauth/oauth_account_pages_test.exs):
 *   <main data-page="account" data-action="<action>">, rows data-role="account-device" data-device-id,
 *   data-role="device-sign-out" | "device-row-sign-out" | "delete-device-confirm" | "reset-request" | "approve-reset" |
 *   "decline-reset" | "reauth" | "notice" (data-notice) | "sign-out";
 *   errors <main data-page="account-error" data-error="<code>">.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, Page, TestInfo } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { createHash, randomBytes } from 'node:crypto';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  clearOAuthClientsByIdPrefix,
  clearAccountSessions,
  clearOAuthSessionsByClientPrefix,
  clearOAuthConsentRequestsByClientPrefix,
  clearDeviceOfUser,
  queryAccountSessionAuthTime,
  queryDbEpochSeconds,
  deleteOAuthSessionsOfUser,
} from '../../fixtures/db';
import { NEBU_USERS, DEX_TEST_PASSWORD, type NebUser } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const ACCOUNT_PATH = '/account';
const CALLBACK_PATH = '/_matrix/client/v3/login/sso/redirect/oidc';
const LOOPBACK_REDIRECT = 'http://localhost:53682/cb';
const LEGACY_REDIRECT = 'http://localhost:7070/#/home';
const CLIENT_PREFIX = 'e2e-oauth-acct-';
const STABLE = 'urn:matrix:client:';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const AXE_TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'];
const CONSENT_PATH = '/oauth2/consent';
// the issuer (a fake https URL by default, the real https origin with NEBU_E2E_OAUTH_ISSUER): fixtures/oauth-issuer.ts
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';

type DeviceSession = { accessToken: string; refreshToken?: string; userId: string };
type Challenge = { session: string; url: string };

// Scenario-scoped state (reset in the Before hook).
let priorIssuer: string | null = null;
let devices: Record<string, DeviceSession> = {};
let usersToClean = new Set<string>();
let currentKeys: Record<string, unknown> | null = null;
let lastChallenge: Challenge | null = null;
let lastUploadStatus = 0;
let lastUploadBody: Record<string, unknown> = {};
let lastStatus = 0;
let lastRequestHtml: string | null = null;
let reauthStartedAt = 0;

function pkcePair(): { verifier: string; challenge: string } {
  const verifier = randomBytes(32).toString('base64url');
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') };
}

function accountUrl(params: Record<string, string> = {}): string {
  const qs = new URLSearchParams(params).toString();
  return `${NEBU_BASE_URL}${ACCOUNT_PATH}${qs ? `?${qs}` : ''}`;
}

function device(id: string): DeviceSession {
  const d = devices[id];
  if (!d) throw new Error(`device "${id}" has no session in this scenario`);
  return d;
}

/**
 * Dex shows a grant screen only on the first login per client.
 * HEURISTIC (test review M9): the button names are guessed from Dex's default theme and the 6 s wait
 * is a best-effort probe; a themed / localised Dex would need its own selector here.
 * The probe acts ONLY on Dex's own approval page (`/dex/approval`): the name regex also matches Nebu's consent
 * button "Allow", which must never be clicked here without arming (story consent-arming-hardening, G3-5).
 */
async function approveConsentIfShown(page: Page): Promise<void> {
  // Race the approval page against the browser leaving Dex (for example straight to Nebu's consent page): the
  // probe never waits the full 6 s after the flow moved on, and it only clicks when the approval branch wins.
  const branch = await Promise.race([
    page.waitForURL((url) => url.pathname.includes('/dex/approval'), { timeout: 6_000 }).then(() => 'approval' as const),
    page.waitForURL((url) => !/^\/dex(\/|$)/i.test(url.pathname), { timeout: 6_000 }).then(() => 'left-dex' as const),
  ]).catch(() => 'none' as const);
  if (branch !== 'approval') return;
  await page.getByRole('button', { name: /^(grant access|approve|confirm)$/i }).click();
}

/**
 * Arms Nebu's consent page like a mouse user does (story consent-arming-hardening, G3-5): Allow is aria-disabled until
 * the shared arming script saw real interaction elsewhere, and after arming a click is accepted only after a real
 * pointer move onto Allow. LOCAL COPY of `armAllow` in oauth-authorize.steps.ts (the step files share no helper module
 * and do not import each other's state); keep the two in sync.
 */
async function armAllow(page: Page): Promise<void> {
  const allow = page.locator('button[name="decision"][value="allow"]');
  await page.mouse.move(40, 40);
  await page.mouse.move(90, 110, { steps: 6 });
  await expect(allow, 'Allow is armed by real pointer movement (aria-disabled is no longer "true")').not.toHaveAttribute(
    'aria-disabled',
    'true',
    { timeout: 10_000 },
  );
  await page.mouse.move(4, 4); // leave no pointer on Allow, so hover() below is a real move onto it
  await allow.hover();
}

async function dexLogin(page: Page, user: NebUser): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(user.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  await approveConsentIfShown(page);
}

async function whoami(request: APIRequestContext, token: string): Promise<{ status: number; userId?: string }> {
  const r = await request.get(`${NEBU_BASE_URL}/_matrix/client/v3/account/whoami`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = r.ok() ? ((await r.json()) as { user_id?: string }) : {};
  return { status: r.status(), userId: body.user_id };
}

/** A real OAuth session for `deviceId` through `clientId` (separate context, real Dex). */
async function oauthSession(
  browser: Browser,
  request: APIRequestContext,
  clientId: string,
  deviceId: string,
  user: NebUser,
): Promise<DeviceSession> {
  const { verifier, challenge } = pkcePair();
  const ctx = await browser.newContext();

  try {
    const page = await ctx.newPage();
    await page.route('http://localhost:53682/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>client stub</title>' }),
    );

    const qs = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: LOOPBACK_REDIRECT,
      scope: `${STABLE}api:* ${STABLE}device:${deviceId}`,
      state: `e2e-acct-${randomBytes(6).toString('hex')}`,
      code_challenge: challenge,
      code_challenge_method: 'S256',
    });

    await page.goto(`${NEBU_BASE_URL}/oauth2/authorize?${qs.toString()}`, { waitUntil: 'domcontentloaded' });
    await dexLogin(page, user);

    // story oauth-authorize-freshness (FR1): the client "follows the 303" to Nebu's consent page and the
    // user clicks Allow; only then does the redirect carry a code. The consent POST is checked against the
    // issuer origin (the e2e issuer is a fake https URL, see oauth-authorize.steps.ts useIssuerOriginForConsent).
    await page.waitForURL((url) => url.pathname === CONSENT_PATH, { timeout: NAV_TIMEOUT_MS });
    await page.route(`**${CONSENT_PATH}`, (route) =>
      route.request().method() === 'POST'
        ? route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } })
        : route.continue(),
    );
    await armAllow(page);
    await page.locator('button[name="decision"][value="allow"]').click();
    await page.waitForURL((url) => url.href.startsWith(LOOPBACK_REDIRECT), { timeout: NAV_TIMEOUT_MS });
    const code = new URL(page.url()).searchParams.get('code');
    expect(code, 'the authorize flow issued a code').toBeTruthy();

    const token = await request.post(`${NEBU_BASE_URL}/oauth2/token`, {
      form: {
        grant_type: 'authorization_code',
        code: code!,
        redirect_uri: LOOPBACK_REDIRECT,
        code_verifier: verifier,
        client_id: clientId,
      },
    });

    expect(token.status(), `token endpoint: ${await token.text()}`).toBe(200);
    const body = (await token.json()) as { access_token: string; refresh_token: string };
    const who = await whoami(request, body.access_token);
    expect(who.status).toBe(200);
    usersToClean.add(who.userId!);
    return { accessToken: body.access_token, refreshToken: body.refresh_token, userId: who.userId! };
  } finally {
    await ctx.close();
  }
}

/** A LEGACY session (raw-JWT branch of POST /login) for `deviceId` (separate context, real Dex). */
async function legacySession(browser: Browser, request: APIRequestContext, deviceId: string, user: NebUser): Promise<DeviceSession> {
  const ctx = await browser.newContext();

  try {
    const page = await ctx.newPage();
    await page.route('http://localhost:7070/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>legacy client stub</title>' }),
    );
    await page.goto(
      `${NEBU_BASE_URL}/_matrix/client/v3/login/sso/redirect?redirectUrl=${encodeURIComponent(LEGACY_REDIRECT)}`,
      { waitUntil: 'domcontentloaded' },
    );
    await dexLogin(page, user);
    await page.waitForURL((url) => url.href.startsWith('http://localhost:7070/'), { timeout: NAV_TIMEOUT_MS });
    const loginToken = new URL(page.url()).searchParams.get('loginToken');
    expect(loginToken, 'the legacy SSO flow returned a loginToken').toBeTruthy();

    const login = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/login`, {
      data: { type: 'm.login.token', token: loginToken, device_id: deviceId },
    });

    expect(login.status(), `legacy login: ${await login.text()}`).toBe(200);
    const body = (await login.json()) as { access_token: string; user_id: string };
    usersToClean.add(body.user_id);
    return { accessToken: body.access_token, userId: body.user_id };
  } finally {
    await ctx.close();
  }
}

function crossSigningKeys(userId: string): Record<string, unknown> {
  const pub = `E2EMASTER${randomBytes(16).toString('hex')}`;
  return { master_key: { user_id: userId, usage: ['master'], keys: { [`ed25519:${pub}`]: pub } } };
}

function masterPub(keys: Record<string, unknown>): string {
  const mk = keys.master_key as { keys: Record<string, string> };
  return Object.values(mk.keys)[0];
}

async function uploadKeys(
  request: APIRequestContext,
  token: string,
  keys: Record<string, unknown>,
  auth?: Record<string, unknown>,
): Promise<void> {
  const r = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/keys/device_signing/upload`, {
    headers: { Authorization: `Bearer ${token}` },
    data: auth ? { ...keys, auth } : keys,
  });
  lastUploadStatus = r.status();
  lastUploadBody = ((await r.text()) ? await r.json() : {}) as Record<string, unknown>;
}

function challengeOf(body: Record<string, unknown>): Challenge {
  const flows = body.flows as Array<{ stages: string[] }> | undefined;
  expect(flows?.some((f) => f.stages.includes('m.oauth')), `m.oauth flow in ${JSON.stringify(body)}`).toBe(true);
  const params = body.params as Record<string, { url?: string }> | undefined;
  const url = params?.['m.oauth']?.url ?? '';
  const session = String(body.session ?? '');
  expect(session, 'the challenge carries a session').not.toBe('');
  expect(body.errcode, 'no errcode in the challenge (Element would enter its error state)').toBeUndefined();
  return { session, url };
}

/** Open an account URL of the challenge / metadata (https issuer) on the Nebu under test. */
function onNebu(url: string): string {
  const u = new URL(url);
  return `${NEBU_BASE_URL}${u.pathname}${u.search}`;
}

async function expectAccountAction(page: Page, action: string): Promise<void> {
  await expect(page.locator(`main[data-page="account"][data-action="${action}"]`)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
}

async function signedIn(page: Page, user: NebUser = NEBU_USERS.alex): Promise<void> {
  await page.goto(accountUrl({ action: 'org.matrix.devices_list' }), { waitUntil: 'domcontentloaded' });
  await dexLogin(page, user);
  await expectAccountAction(page, 'org.matrix.devices_list');
}

// ─── Hooks ─────────────────────────────────────────────────────────────────────

// The Background's "OAuth is enabled with an https issuer" (story-2 step file) records the prior
// issuer in ITS module; this hook captures it again for this feature's own cleanup.
Before({ tags: '@oauth-account' }, async () => {
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  devices = {};
  usersToClean = new Set<string>();
  currentKeys = null;
  lastChallenge = null;
  lastUploadStatus = 0;
  lastUploadBody = {};
  lastStatus = 0;
  lastRequestHtml = null;
  reauthStartedAt = 0;
});

// Never leave OAuth switched on, the issuer changed, fixture clients, their sessions/devices or
// account sessions behind. Failures are NOT swallowed (see fixtures/db.ts).
After({ tags: '@oauth-account' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  for (const userId of usersToClean) clearAccountSessions(userId);
  // test review M9: the legacy-only scenario leaves a legacy device (E2EACCTLEG1) of the legacy test
  // user behind; delete its sessions, the device and its key material.
  for (const [deviceId, d] of Object.entries(devices)) {
    if (deviceId.startsWith('E2EACCTLEG')) clearDeviceOfUser(d.userId, deviceId);
  }
});

// ─── Given ─────────────────────────────────────────────────────────────────────

Given(
  'the test user has an OAuth session on device {string} through {string}',
  async ({ browser, request }: { browser: Browser; request: APIRequestContext }, deviceId: string, clientId: string) => {
    devices[deviceId] = await oauthSession(browser, request, clientId, deviceId, NEBU_USERS.alex);
  },
);

Given(
  'the legacy test user has a legacy session on device {string} and no OAuth session',
  async ({ browser, request }: { browser: Browser; request: APIRequestContext }, deviceId: string) => {
    const s = await legacySession(browser, request, deviceId, NEBU_USERS.marie);
    deleteOAuthSessionsOfUser(s.userId);
    devices[deviceId] = s;
  },
);

Given('the user is signed in on the account page', async ({ page }: { page: Page }) => {
  await signedIn(page);
});

/**
 * Gate y (FR14): the scenarios that sign a device out or approve a key reset need a FRESH account session,
 * i.e. an IdP that reports `auth_time`. Probe the real Dex with a login on the account page in a SEPARATE
 * browser context (the scenario's own context must still be asked to sign in) and skip the scenario with a
 * `gate-y` annotation when the session came out with auth_time NULL.
 */
Given(
  'the IdP reports the sign-in time',
  async ({ browser, $testInfo }: { browser: Browser; $testInfo: TestInfo }) => {
    const known = Object.values(devices)[0];
    const user = known?.userId === NEBU_USERS.marie.matrixId ? NEBU_USERS.marie : NEBU_USERS.alex;
    const userId = known?.userId ?? user.matrixId;
    usersToClean.add(userId);
    const ctx = await browser.newContext();

    try {
      const probe = await ctx.newPage();
      await signedIn(probe, user);
    } finally {
      await ctx.close();
    }

    const authTime = queryAccountSessionAuthTime(userId);

    if (authTime === null) {
      $testInfo.annotations.push({
        type: 'gate-y',
        description: 'The IdP (Dex) did not report auth_time: the account session is NOT fresh (fail closed, FR14); the scenario needs a fresh session',
      });
      console.log('[gate-y-evidence] the IdP reported no auth_time; scenario skipped');
      $testInfo.skip(true, 'gate-y: the IdP does not report auth_time, so destructive account actions are unavailable');
    }
  },
);

Given(
  'the client of device {string} has uploaded cross-signing keys',
  async ({ request }: { request: APIRequestContext }, deviceId: string) => {
    const d = device(deviceId);
    currentKeys = crossSigningKeys(d.userId);
    await uploadKeys(request, d.accessToken, currentKeys);
    if (lastUploadStatus !== 200) {
      // a key set from an earlier run is stored: the first upload of THIS scenario is a replacement
      // that needs the challenge itself; the scenario then starts from the stored set.
      const q = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/keys/query`, {
        headers: { Authorization: `Bearer ${d.accessToken}` },
        data: { device_keys: { [d.userId]: [] } },
      });
      const stored = ((await q.json()) as { master_keys?: Record<string, unknown> }).master_keys?.[d.userId];
      expect(stored, 'either the first upload succeeded or a master key is stored').toBeTruthy();
      currentKeys = { master_key: stored };
    }
  },
);

Given(
  'the client of device {string} received an m.oauth challenge for different keys',
  async ({ request }: { request: APIRequestContext }, deviceId: string) => {
    const d = device(deviceId);
    currentKeys = crossSigningKeys(d.userId);
    await uploadKeys(request, d.accessToken, currentKeys);
    expect(lastUploadStatus).toBe(401);
    lastChallenge = challengeOf(lastUploadBody);
  },
);

Given('OAuth is disabled', async () => {
  upsertServerConfig('oauth_enabled', 'false');
});

// ─── When ──────────────────────────────────────────────────────────────────────

When('the browser opens the account page with action {string}', async ({ page }: { page: Page }, action: string) => {
  const r = await page.goto(accountUrl({ action }), { waitUntil: 'domcontentloaded' });
  lastStatus = r?.status() ?? 0;
});

When(
  'the browser opens the account page with action {string} for device {string}',
  async ({ page }: { page: Page }, action: string, deviceId: string) => {
    const r = await page.goto(accountUrl({ action, device_id: deviceId }), { waitUntil: 'domcontentloaded' });
    lastStatus = r?.status() ?? 0;
  },
);

When('the legacy test user signs in at the IdP', async ({ page }: { page: Page }) => {
  await dexLogin(page, NEBU_USERS.marie);
  await page.waitForURL((url) => !/\/dex\//i.test(url.pathname) && url.pathname !== CALLBACK_PATH, { timeout: NAV_TIMEOUT_MS });
});

When('the user follows the sign-out control of the device page', async ({ page }: { page: Page }) => {
  await expectAccountAction(page, 'org.matrix.device_view');
  const control = page.locator('[data-role="device-sign-out"]');
  await expect(control, 'the prominent sign-out control of the device page').toBeVisible();
  await control.click();
  await expectAccountAction(page, 'org.matrix.device_delete');
});

When('the user confirms signing out the device', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="delete-device-confirm"]').click();
  await page.waitForLoadState('domcontentloaded');
});

When(
  'the user signs out device {string} from the list and confirms',
  async ({ page }: { page: Page }, deviceId: string) => {
    const row = page.locator(`[data-role="account-device"][data-device-id="${deviceId}"]`);
    await row.locator('[data-role="device-row-sign-out"]').click();
    await expectAccountAction(page, 'org.matrix.device_delete');
    await page.locator('[data-role="delete-device-confirm"]').click();
    await expect(page.locator('[data-role="notice"][data-notice="device_deleted"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  },
);

When('the browser opens the re-authentication link', async ({ page }: { page: Page }) => {
  reauthStartedAt = queryDbEpochSeconds();
  await page.goto(`${NEBU_BASE_URL}${ACCOUNT_PATH}/reauth?action=org.matrix.devices_list`, { waitUntil: 'domcontentloaded' });
});

When(
  'the client of device {string} uploads different cross-signing keys',
  async ({ request }: { request: APIRequestContext }, deviceId: string) => {
    const d = device(deviceId);
    currentKeys = crossSigningKeys(d.userId);
    await uploadKeys(request, d.accessToken, currentKeys);
  },
);

When('the browser opens the challenge URL', async ({ page }: { page: Page }) => {
  expect(lastChallenge, 'an m.oauth challenge was received').not.toBeNull();
  await page.goto(onNebu(lastChallenge!.url), { waitUntil: 'domcontentloaded' });
});

When('the user approves the reset request', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="approve-reset"]').first().click();
  await page.waitForLoadState('domcontentloaded');
});

When('the user declines the reset request', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="decline-reset"]').first().click();
  await page.waitForLoadState('domcontentloaded');
});

When(
  'the client retries the upload with the challenge session',
  async ({ request }: { request: APIRequestContext }) => {
    // Element's retry: {type: "m.oauth", session} with the SAME body (oracle O3)
    await uploadKeys(request, device('E2EACCTDEV1').accessToken, currentKeys!, { type: 'm.oauth', session: lastChallenge!.session });
  },
);

When('the client retries the same upload again', async ({ request }: { request: APIRequestContext }) => {
  await uploadKeys(request, device('E2EACCTDEV1').accessToken, currentKeys!, { type: 'm.oauth', session: lastChallenge!.session });
});

async function postDelete(page: Page, deviceId: string, form: Record<string, string>, headers: Record<string, string>): Promise<void> {
  // page.request shares the browser context's cookies (the account session), like a forged form post
  // would if SameSite were bypassed.
  const r = await page.request.post(`${NEBU_BASE_URL}${ACCOUNT_PATH}/devices/delete`, {
    form: { device_id: deviceId, ...form },
    headers,
    maxRedirects: 0,
  });
  lastStatus = r.status();
  lastRequestHtml = await r.text();
}

When(
  'a same-origin form without the CSRF token is posted to sign out device {string}',
  async ({ page }: { page: Page }, deviceId: string) => {
    // token check isolated: same origin, no cross-site hint, only the CSRF token is missing
    await postDelete(page, deviceId, {}, { Origin: new URL(NEBU_BASE_URL).origin, 'Sec-Fetch-Site': 'same-origin' });
  },
);

When(
  'a form with a valid CSRF token is posted cross-site to sign out device {string}',
  async ({ page }: { page: Page }, deviceId: string) => {
    // origin check isolated: a VALID token read from the user's own confirmation page, foreign Origin
    await page.goto(accountUrl({ action: 'org.matrix.device_delete', device_id: deviceId }), { waitUntil: 'domcontentloaded' });
    const token = await page.locator('input[name="csrf_token"]').first().getAttribute('value');
    expect(token, 'the confirmation page carries the CSRF token').toBeTruthy();
    await postDelete(page, deviceId, { csrf_token: token! }, { Origin: 'https://evil.e2e.example', 'Sec-Fetch-Site': 'cross-site' });
  },
);

When('the user signs out of the account page', async ({ page }: { page: Page }) => {
  await page.locator('[data-role="sign-out"]').click();
  await page.waitForLoadState('domcontentloaded');
});

// ─── Then: account pages ───────────────────────────────────────────────────────

Then('the account page shows the action {string}', async ({ page }: { page: Page }, action: string) => {
  await expectAccountAction(page, action);
});

Then(
  'the device list contains {string} with the app {string}',
  async ({ page }: { page: Page }, deviceId: string, app: string) => {
    const row = page.locator(`[data-role="account-device"][data-device-id="${deviceId}"]`);
    await expect(row).toBeVisible();
    await expect(row).toContainText(app);
  },
);

Then('the device list contains {string}', async ({ page }: { page: Page }, deviceId: string) => {
  await expect(page.locator(`[data-role="account-device"][data-device-id="${deviceId}"]`)).toBeVisible();
});

Then('the device list does not contain {string}', async ({ page }: { page: Page }, deviceId: string) => {
  await expect(page.locator('main[data-page="account"]')).toBeVisible();
  await expect(page.locator(`[data-role="account-device"][data-device-id="${deviceId}"]`)).toHaveCount(0);
});

Then('the page has exactly one level-1 heading', async ({ page }: { page: Page }) => {
  await expect(page.locator('h1')).toHaveCount(1);
});

// Review cycle 1 (UX V1/V3): the page reflows at a 320 px viewport without horizontal scrolling (WCAG 1.4.10).
Then('the page does not scroll horizontally at a 320 px viewport', async ({ page }: { page: Page }) => {
  await page.setViewportSize({ width: 320, height: 800 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, 'no horizontal scrolling at 320 px').toBeLessThanOrEqual(0);
});

Then('the page has no detectable accessibility violations', async ({ page }: { page: Page }) => {
  const results = await new AxeBuilder({ page }).withTags(AXE_TAGS).analyze();
  expect(results.violations.map((v) => `${v.id}: ${v.help}`)).toEqual([]);
});

Then('the confirmation for signing out {string} is shown', async ({ page }: { page: Page }, deviceId: string) => {
  await expectAccountAction(page, 'org.matrix.device_delete');
  await expect(page.locator('main')).toContainText(deviceId);
  await expect(page.locator('[data-role="delete-device-confirm"]')).toBeVisible();
});

Then('the account page shows the notice {string}', async ({ page }: { page: Page }, notice: string) => {
  await expect(page.locator(`[data-role="notice"][data-notice="${notice}"]`)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
});

Then('the account page shows the signed-out message', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-role="notice"][data-notice="signed_out"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
});

Then('opening the account page again redirects to the IdP', async ({ page }: { page: Page }) => {
  await page.goto(accountUrl({ action: 'org.matrix.devices_list' }), { waitUntil: 'domcontentloaded' });
  await page.waitForURL(/\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
});

Then('a pending reset request from device {string} is shown', async ({ page }: { page: Page }, deviceId: string) => {
  await expectAccountAction(page, 'org.matrix.cross_signing_reset');
  await expect(page.locator('[data-role="reset-request"]').filter({ hasText: deviceId })).toBeVisible();
});

Then('the account error page {string} is shown', async ({ page }: { page: Page }, code: string) => {
  if (lastRequestHtml !== null) {
    expect(lastRequestHtml).toMatch(new RegExp(`data-page="account-error"[^>]*data-error="${code}"`));
    expect(lastStatus).toBe(403);
  } else {
    await expect(page.locator(`main[data-page="account-error"][data-error="${code}"]`)).toBeVisible();
  }
});

Then(
  'the account error page {string} is shown with status {int}',
  async ({ page }: { page: Page }, code: string, status: number) => {
    await expect(page.locator(`main[data-page="account-error"][data-error="${code}"]`)).toBeVisible();
    expect(lastStatus).toBe(status);
  },
);

// ─── Then: tokens and keys ─────────────────────────────────────────────────────

Then('the access token of device {string} is rejected', async ({ request }: { request: APIRequestContext }, deviceId: string) => {
  expect((await whoami(request, device(deviceId).accessToken)).status).toBe(401);
});

Then('the access token of device {string} still works', async ({ request }: { request: APIRequestContext }, deviceId: string) => {
  expect((await whoami(request, device(deviceId).accessToken)).status).toBe(200);
});

Then('the client receives an m.oauth challenge pointing at the account page', async () => {
  expect(lastUploadStatus, JSON.stringify(lastUploadBody)).toBe(401);
  lastChallenge = challengeOf(lastUploadBody);
  const u = new URL(lastChallenge.url);
  expect(u.protocol).toBe('https:');
  expect(u.pathname).toBe(ACCOUNT_PATH);
  expect(u.searchParams.get('action')).toBe('org.matrix.cross_signing_reset');
});

Then('the client receives a new m.oauth challenge', async () => {
  expect(lastUploadStatus).toBe(401);
  const next = challengeOf(lastUploadBody);
  expect(next.session, 'a declined request is never accepted again').not.toBe(lastChallenge!.session);
});

Then('the upload succeeds', async () => {
  expect(lastUploadStatus, JSON.stringify(lastUploadBody)).toBe(200);
});

Then('the upload succeeds without a challenge', async () => {
  expect(lastUploadStatus, 'identical re-upload after the replacement (A14 step 3)').toBe(200);
  expect(lastUploadBody.flows).toBeUndefined();
});

Then("the client's cross-signing master key is the new key", async ({ request }: { request: APIRequestContext }) => {
  const d = device('E2EACCTDEV1');
  const q = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/keys/query`, {
    headers: { Authorization: `Bearer ${d.accessToken}` },
    data: { device_keys: { [d.userId]: [] } },
  });
  const master = ((await q.json()) as { master_keys?: Record<string, { keys: Record<string, string> }> }).master_keys?.[d.userId];
  expect(Object.values(master?.keys ?? {})).toContain(masterPub(currentKeys!));
});

// ─── Freshness evidence (gate y, oracle O5) ────────────────────────────────────

// test review M9: never either/or. The evidence step ALWAYS persists what Dex did (attachment + log
// line); the auth_time step FAILS when the session's auth_time is absent or older than the re-auth
// request, unless the evidence step recorded the explicit `gate-y` annotation (Dex did not re-prompt
// on max_age=0: the known gate (y) finding, oracle O5).
let dexReprompted: boolean | null = null;

Then(
  'the IdP re-authentication outcome is recorded as gate \\(y) evidence',
  async ({ page, $testInfo }: { page: Page; $testInfo: TestInfo }) => {
    const form = page.locator('input[name="login"]');
    const asked = await form
      .waitFor({ state: 'visible', timeout: 15_000 })
      .then(() => true)
      .catch(() => false);
    dexReprompted = asked;

    if (asked) await dexLogin(page, NEBU_USERS.alex);
    await page.waitForURL((url) => url.pathname === ACCOUNT_PATH, { timeout: NAV_TIMEOUT_MS });

    const evidence = {
      reauthRequestedAt: reauthStartedAt,
      dexAskedForCredentials: asked,
      sessionAuthTime: queryAccountSessionAuthTime(device('E2EACCTDEV1').userId),
      observedAt: queryDbEpochSeconds(),
    };

    await $testInfo.attach('gate-y-evidence.json', { body: JSON.stringify(evidence, null, 2), contentType: 'application/json' });
    console.log(`[gate-y-evidence] ${JSON.stringify(evidence)}`);

    if (!asked) {
      $testInfo.annotations.push({
        type: 'gate-y',
        description: 'Dex did NOT ask for the credentials again on max_age=0 (no fresh login): gate (y) evidence',
      });
    }
  },
);

// story oauth-authorize-freshness (FR14): never absent-but-fresh. A session WITH an auth_time must be fresh
// (the claim is stored raw; unless the evidence step recorded the `gate-y` annotation: Dex did not
// re-prompt); a session WITHOUT one must answer the destructive actions with the freshness_unavailable
// notice and offer neither the delete form nor a reauth link.
Then(
  "the account session's auth_time is fresh, or absent with the destructive actions unavailable",
  async ({ page, $testInfo }: { page: Page; $testInfo: TestInfo }) => {
    const authTime = queryAccountSessionAuthTime(device('E2EACCTDEV1').userId);

    if (authTime !== null) {
      const fresh = authTime >= reauthStartedAt - 60; // 60 s skew as in A7
      const gateY = $testInfo.annotations.some((a) => a.type === 'gate-y');

      if (!fresh && !gateY) {
        throw new Error(
          `account session auth_time ${authTime} is older than the re-auth request ${reauthStartedAt} ` +
            `(Dex re-prompted: ${dexReprompted}) and no gate-y annotation was recorded`,
        );
      }

      if (!fresh) console.log('[gate-y-evidence] auth_time not fresh; accepted only because the gate-y annotation is recorded');
      return;
    }

    // auth_time absent => NULL on the session: fail closed
    console.log('[gate-y-evidence] the account session has no auth_time: destructive actions must be unavailable');
    await page.goto(accountUrl({ action: 'org.matrix.device_delete', device_id: 'E2EACCTDEV1' }), { waitUntil: 'domcontentloaded' });
    await expect(page.locator('[data-role="notice"][data-notice="freshness_unavailable"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await expect(page.locator('[data-role="delete-device-confirm"]'), 'no delete control without a proven authentication time').toHaveCount(0);
    await expect(page.locator('[data-role="reauth"]'), 'no reauth link: the IdP would not report a time next time either').toHaveCount(0);
  },
);
