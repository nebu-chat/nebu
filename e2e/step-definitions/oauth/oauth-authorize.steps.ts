/**
 * Step definitions for features/oauth/oauth-authorize.feature
 *
 * Story: oauth-broker / oauth-authorize-idp-delegation-code — ATDD RED phase (written before the
 * implementation; runs only against the full compose stack with the real Dex).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * No shared steps are reused: the client-redirect check is an exact origin + path comparison
 * ("the client receives the redirect at {string}"), not the unanchored URL regex of
 * admin/bootstrap.steps.ts' "the browser is redirected to {string}".
 *
 * Client side: nothing listens on the registered client redirect URIs, so every client redirect
 * target is intercepted with page.route() and answered with a stub page; the steps read code /
 * error / state / iss from the final URL. The Dex login uses the shared test user (fixtures/users.ts).
 *
 * Story oauth-authorize-freshness (P3, FR1): the IdP login no longer ends at the client. The shared
 * callback answers 303 to the consent page (/oauth2/consent); the code is issued after
 * "the user allows the app" (Allow, `decide`), and "the user denies the app" ends in an access_denied
 * redirect. This file also holds the steps of oauth-consent.feature that touch the authorize / client
 * side state (`clients`, `requestState`, the PKCE verifier, the expected redirect): the named web client,
 * the authorize URL with response_mode + device, Allow / Deny, the fragment redirect checks, the code
 * exchange, the response header checks and the replay of a consent form. Page-only assertions of the
 * consent screen live in oauth-consent.steps.ts.
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Page, Response } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  insertOAuthClient,
  clearOAuthClientsByIdPrefix,
} from '../../fixtures/db';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const AUTHORIZE_PATH = '/oauth2/authorize';
const CONSENT_PATH = '/oauth2/consent';
const CALLBACK_PATH = '/_matrix/client/v3/login/sso/redirect/oidc';
// the issuer (a fake https URL by default, the real https origin with NEBU_E2E_OAUTH_ISSUER): fixtures/oauth-issuer.ts
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
const CLIENT_PREFIX = 'e2e-oauth-authz-';
const STABLE = 'urn:matrix:client:';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);

type Client = { clientId: string; redirectUri: string };

// Scenario-scoped state (reset by the Background).
let clients: Record<string, Client> = {};
let priorIssuer: string | null = null;
let lastResponse: Response | null = null;

/**
 * Hands a response over to the shared "the response has ..." steps of this file (story
 * legacy-sso-redirect-confirmation: the confirmation page's GET response is the one whose headers are checked).
 */
export function setLastResponse(r: Response | null): void {
  lastResponse = r;
}
let requestState = '';
let callbackUrl = '';
let routed: string[] = [];
let bindingCookie: { name: string; value: string } | null = null;
// story oauth-authorize-freshness (P3)
let lastVerifier = '';
let lastClientId = '';
/** The redirect URI the current scenario's authorize request asked for (what Allow / Deny must end at). */
let expectedRedirect = '';
/** The consent form as the browser saw it (csrf token + cookie), captured by "the consent page ... is shown". */
let consentForm: { csrf: string; cookie: { name: string; value: string } } | null = null;

function pkceChallenge(): string {
  const verifier = randomBytes(32).toString('base64url');
  lastVerifier = verifier;
  return createHash('sha256').update(verifier).digest('base64url');
}

function authorizeUrl(params: Record<string, string | undefined>): string {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) qs.append(k, v);
  return `${NEBU_BASE_URL}${AUTHORIZE_PATH}?${qs.toString()}`;
}

function validParams(client: Client, overrides: Record<string, string | undefined> = {}) {
  requestState = `e2e-state-${randomBytes(6).toString('hex')}`;
  lastClientId = client.clientId;
  expectedRedirect = client.redirectUri;
  return {
    response_type: 'code',
    client_id: client.clientId,
    redirect_uri: client.redirectUri,
    scope: `${STABLE}api:* ${STABLE}device:E2EDEVICE${randomBytes(3).toString('hex')}`,
    state: requestState,
    code_challenge: pkceChallenge(),
    code_challenge_method: 'S256',
    ...overrides,
  };
}

function client(name: string): Client {
  const c = clients[name];
  if (!c) throw new Error(`fixture client "${name}" was not created in this scenario`);
  return c;
}

/** Answer every navigation to the client redirect target with a stub page (nothing listens there). */
async function interceptClient(page: Page, redirectUri: string): Promise<void> {
  const u = new URL(redirectUri);
  const pattern = `${u.protocol}//${u.host}/**`;
  if (routed.includes(pattern)) return;
  routed.push(pattern);
  await page.route(pattern, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>client stub</title><p>client</p>' }),
  );
}

/** Record the shared IdP callback URL and the D4 binding cookie of the authorize 302 (replay scenario). */
function recordCallback(page: Page): void {
  page.on('request', (r) => {
    const url = new URL(r.url());
    if (url.pathname === CALLBACK_PATH && url.searchParams.get('state')?.startsWith('o2.')) callbackUrl = r.url();
  });
  page.on('response', async (r) => {
    if (new URL(r.url()).pathname !== AUTHORIZE_PATH) return;
    for (const h of await r.headersArray()) {
      const m = h.name.toLowerCase() === 'set-cookie' ? /^((?:__Host-)?nebu_oa_[0-9a-f]{16})=([^;]+)/.exec(h.value) : null;
      if (m) bindingCookie = { name: m[1], value: m[2] };
    }
  });
}

/**
 * Dex shows a grant screen only on the first login per client. The probe acts ONLY on Dex's own approval page
 * (`/dex/approval`): its button name regex also matches Nebu's consent button "Allow", and a probe that clicked
 * Nebu's Allow would bypass the arming (story consent-arming-hardening, G3-5). Anywhere else it returns after the
 * (best-effort) wait.
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

async function signInAtDex(page: Page): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form (prompt=login forces an interactive login)').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(NEBU_USERS.alex.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  await approveConsentIfShown(page);
}

/**
 * The e2e stack serves Nebu at http://localhost:8008 while the issuer is a fake https URL (it is only
 * compared, never fetched), and the consent POST is checked against the ISSUER origin (FR8). A real
 * deployment's issuer is the origin the browser uses; here the browser's `Origin` of the consent POST is
 * therefore replaced with the issuer origin. UNVERIFIED against a real Chromium (route.continue header
 * override of `Origin`): if Chromium refuses it the consent scenarios need an issuer equal to the base URL.
 */
async function useIssuerOriginForConsent(page: Page): Promise<void> {
  await page.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** The user's decision on Nebu's consent page (FR9: two equal buttons name="decision" value="allow|deny"). */
async function decide(page: Page, decision: 'allow' | 'deny'): Promise<void> {
  await expect(page.locator('main[data-page="oauth-consent"]'), 'the consent page is shown before the client redirect').toBeVisible({
    timeout: NAV_TIMEOUT_MS,
  });
  await useIssuerOriginForConsent(page);
  if (decision === 'allow') await armAllow(page);
  await page.locator(`button[name="decision"][value="${decision}"]`).click();
  if (expectedRedirect) await page.waitForURL((url) => url.href.startsWith(expectedRedirect), { timeout: NAV_TIMEOUT_MS });
}

/**
 * Security review M-1 / FR21, story consent-arming-hardening (G3-5): Allow is rendered aria-disabled="true" and armed
 * by the shared Nebu.Web.ArmScript only after REAL interaction elsewhere (a pointer move of at least 4 px, a key press,
 * ...) and 600 ms after load. After arming, a mouse click is accepted only after a real pointer move onto Allow.
 * Playwright's mouse moves are real input events, so this is what a user does: move elsewhere, wait until Allow is
 * available (an aria-disabled button counts as enabled for Playwright, so `toBeEnabled` proves nothing), leave the
 * pointer away from Allow, then hover (a real move onto it). `decide` clicks afterwards.
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

async function openAuthorize(page: Page, url: string): Promise<void> {
  recordCallback(page);
  lastResponse = await page.goto(url, { waitUntil: 'domcontentloaded' });
}

function redirectParams(page: Page): URLSearchParams {
  return new URL(page.url()).searchParams;
}

// ─── Background ────────────────────────────────────────────────────────────────

Given('OAuth is enabled with an https issuer', async () => {
  clients = {};
  lastResponse = null;
  requestState = '';
  callbackUrl = '';
  routed = [];
  bindingCookie = null;
  lastVerifier = '';
  lastClientId = '';
  expectedRedirect = '';
  consentForm = null;
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  upsertServerConfig('oauth_issuer_url', E2E_ISSUER);
  upsertServerConfig('oauth_enabled', 'true');
});

// Scenario cleanup: never leave OAuth switched on, the issuer changed or fixture clients behind.
// Failures are NOT swallowed (see fixtures/db.ts).
After({ tags: '@oauth-authorize' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
});

// ─── Given: fixture clients ────────────────────────────────────────────────────

Given(
  /^an approved (native|web) client "([^"]+)" with redirect URI "([^"]+)"$/,
  async ({}, appType: string, name: string, redirectUri: string) => {
    insertOAuthClient({
      clientId: name,
      status: 'approved',
      redirectUris: [redirectUri],
      applicationType: appType as 'web' | 'native',
    });
    clients[name] = { clientId: name, redirectUri };
  },
);

Given(/^a (pending|rejected) web client "([^"]+)"$/, async ({}, status: string, name: string) => {
  const redirectUri = `https://client.e2e.example/cb/${name}`;
  insertOAuthClient({
    clientId: name,
    status: status as 'pending' | 'rejected',
    redirectUris: [redirectUri],
    applicationType: 'web',
  });
  clients[name] = { clientId: name, redirectUri };
});

// story oauth-authorize-freshness (P3): an approved web client with a NAME and a client URI (what the
// consent page shows as claimed by the app, and the identity the device-holder policy compares).
Given(
  'an approved web client {string} named {string} with client URI {string} and redirect URI {string}',
  async ({}, clientId: string, clientName: string, clientUri: string, redirectUri: string) => {
    insertOAuthClient({
      clientId,
      status: 'approved',
      redirectUris: [redirectUri],
      applicationType: 'web',
      clientUri,
      clientName,
    });
    clients[clientId] = { clientId, redirectUri };
  },
);

// ─── When: authorize requests ──────────────────────────────────────────────────

When(
  'the browser opens the authorize URL of {string} with valid parameters',
  async ({ page }: { page: Page }, name: string) => {
    const c = client(name);
    await interceptClient(page, c.redirectUri);
    await openAuthorize(page, authorizeUrl(validParams(c)));
  },
);

When('the browser opens the authorize URL with client_id {string}', async ({ page }: { page: Page }, clientId: string) => {
  await openAuthorize(page, authorizeUrl(validParams({ clientId, redirectUri: 'https://client.e2e.example/cb' })));
});

When(
  'the browser opens the authorize URL of {string} with redirect URI {string}',
  async ({ page }: { page: Page }, name: string, redirectUri: string) => {
    // Intercept the foreign target too: if the server ever redirected there the test would see it.
    await interceptClient(page, redirectUri);
    await openAuthorize(page, authorizeUrl(validParams({ clientId: client(name).clientId, redirectUri })));
  },
);

function loopbackWithPort(name: string, port: number): Client {
  const c = client(name);
  const u = new URL(c.redirectUri);
  u.port = String(port);
  return { clientId: c.clientId, redirectUri: u.toString() };
}

When(
  'the browser opens the authorize URL of {string} on port {int} without code_challenge',
  async ({ page }: { page: Page }, name: string, port: number) => {
    const c = loopbackWithPort(name, port);
    await interceptClient(page, c.redirectUri);
    await openAuthorize(page, authorizeUrl(validParams(c, { code_challenge: undefined })));
  },
);

When(
  'the browser opens the authorize URL of {string} on port {int} with scope prefix {string}',
  async ({ page }: { page: Page }, name: string, port: number, prefix: string) => {
    const c = loopbackWithPort(name, port);
    await interceptClient(page, c.redirectUri);
    const device = `E2E${randomBytes(4).toString('hex').toUpperCase()}`;
    await openAuthorize(page, authorizeUrl(validParams(c, { scope: `${prefix}api:* ${prefix}device:${device}` })));
  },
);

When(
  'the browser opens the authorize URL of {string} with response_mode {string}, scope {string} and a nonce',
  async ({ page }: { page: Page }, name: string, mode: string, scope: string) => {
    const c = client(name);
    await interceptClient(page, c.redirectUri);
    await openAuthorize(
      page,
      authorizeUrl(validParams(c, { response_mode: mode, scope, nonce: randomBytes(16).toString('base64url') })),
    );
  },
);

When(
  'the browser opens the authorize URL of {string} with response_mode {string} and device {string}',
  async ({ page }: { page: Page }, name: string, mode: string, deviceId: string) => {
    const c = client(name);
    await interceptClient(page, c.redirectUri);
    await openAuthorize(
      page,
      authorizeUrl(validParams(c, { response_mode: mode, scope: `${STABLE}api:* ${STABLE}device:${deviceId}` })),
    );
  },
);

When('the user signs in at the IdP', async ({ page }: { page: Page }) => {
  // The authorize 302 leads to the ONE IdP client's Dex login page (shared callback, D1).
  await signInAtDex(page);
  // Dex -> Nebu callback -> 303 to the consent page (story oauth-authorize-freshness; before it: the 302 to
  // the client). The flow can also END at the callback with an HTML error page (e.g. device_in_use: no
  // redirect to the client, FR11/FR18), which is served AT the callback path.
  await expect
    .poll(
      async () => {
        const url = new URL(page.url());
        if (!/\/dex\//i.test(url.pathname) && url.pathname !== CALLBACK_PATH) return true;
        return (await page.locator('main[data-page="oauth-error"]').count()) > 0;
      },
      { timeout: NAV_TIMEOUT_MS },
    )
    .toBe(true);
});

Given('a completed authorization for {string}', async ({ page }: { page: Page }, name: string) => {
  const c = loopbackWithPort(name, 53682);
  await interceptClient(page, c.redirectUri);
  await openAuthorize(page, authorizeUrl(validParams(c)));
  await signInAtDex(page);
  // the callback leads to the consent page; the code follows the user's Allow (story oauth-authorize-freshness)
  await decide(page, 'allow');
  await page.waitForURL((url) => url.href.startsWith(c.redirectUri), { timeout: NAV_TIMEOUT_MS });
  expect(redirectParams(page).get('code'), 'the first callback issued a code').toBeTruthy();
  expect(callbackUrl, 'the shared IdP callback with an o2. state was observed').not.toBe('');
  expect(bindingCookie, 'the authorize 302 set the (__Host-)nebu_oa_* binding cookie').not.toBeNull();
});

When(
  'the browser opens the same IdP callback URL again with the original binding cookie',
  async ({ page }: { page: Page }) => {
    // Restore the (cleared) binding cookie so the replay fails ONLY because the request row was
    // consumed (single use), not because the cookie is missing.
    const cb = new URL(callbackUrl);
    // a `__Host-` cookie (https issuer) must be Secure, Path=/ and carry no Domain: a `url` gives exactly that; the plain
    // cookie of the http stack keeps its domain / path
    await page.context().addCookies([
      bindingCookie!.name.startsWith('__Host-')
        ? { name: bindingCookie!.name, value: bindingCookie!.value, url: `${cb.origin}/`, httpOnly: true, sameSite: 'Lax' }
        : { name: bindingCookie!.name, value: bindingCookie!.value, domain: cb.hostname, path: CALLBACK_PATH, httpOnly: true, sameSite: 'Lax' },
    ]);
    lastResponse = await page.goto(callbackUrl, { waitUntil: 'domcontentloaded' });
  },
);

// ─── Then: pages ───────────────────────────────────────────────────────────────

Then('the page has the heading {string}', async ({ page }: { page: Page }, heading: string) => {
  await expect(page.locator('main h1')).toHaveText(heading);
  await expect(page.locator('h1')).toHaveCount(1);
});

Then('the page is marked as OAuth error {string}', async ({ page }: { page: Page }, code: string) => {
  await expect(page.locator(`main[data-page="oauth-error"][data-error="${code}"]`)).toBeVisible({ timeout: 15_000 });
});

Then('the browser stays on the Nebu authorize URL', async ({ page }: { page: Page }) => {
  const url = new URL(page.url());
  expect(`${url.protocol}//${url.host}`).toBe(new URL(NEBU_BASE_URL).origin);
  expect(url.pathname).toBe(AUTHORIZE_PATH);
  expect(lastResponse?.status(), 'the error page is the authorize response itself (no redirect)').toBeGreaterThanOrEqual(400);
});

Then('the page shows the next step {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(page.locator('main')).toContainText('What you can do');
  await expect(page.locator('main')).toContainText(text);
});

// The CSP carries the SHA-256 of the one inline <style> block: a wrong hash would silently unstyle the
// page. h1 is 1.5rem (24px) in that block; the UA default (2em = 32px) would show up as a different size.
Then('the inline style of the page is applied under the CSP', async ({ page }: { page: Page }) => {
  const h1Size = await page.locator('main h1').evaluate((el: Element) => getComputedStyle(el).fontSize);
  expect(h1Size, 'inline <style> blocked by the CSP (wrong hash?)').toBe('24px');
  const margin = await page.locator('body').evaluate((el: Element) => getComputedStyle(el).margin);
  expect(margin).not.toBe('8px');
});

Then('the page contains no script element', async ({ page }: { page: Page }) => {
  await expect(page.locator('script')).toHaveCount(0);
});

Then(
  'the response has a Content-Security-Policy starting with {string}',
  async ({}, prefix: string) => {
    const csp = lastResponse?.headers()['content-security-policy'] ?? '';
    expect(csp.startsWith(prefix), `CSP was ${JSON.stringify(csp)}`).toBe(true);
  },
);

Then('the page does not contain {string}', async ({ page }: { page: Page }, text: string) => {
  expect(await page.content()).not.toContain(text);
  // the page URL (origin + path): the browser stays on the authorize URL, whose QUERY legitimately carries the rejected
  // redirect_uri (percent-encoded); what must not happen is a NAVIGATION to that target.
  const u = new URL(page.url());
  expect(`${u.origin}${u.pathname}`).not.toContain(text);
});

// ─── Then: client redirect ─────────────────────────────────────────────────────

Then('the client receives the redirect at {string}', async ({ page }: { page: Page }, expected: string) => {
  await page.waitForURL((url) => `${url.origin}${url.pathname}` === expected, { timeout: NAV_TIMEOUT_MS });
  const url = new URL(page.url());
  expect(`${url.origin}${url.pathname}`).toBe(expected);
});

Then('the redirect query has {string} = {string}', async ({ page }: { page: Page }, key: string, value: string) => {
  expect(redirectParams(page).get(key)).toBe(value);
});

Then('the redirect query has a {string}', async ({ page }: { page: Page }, key: string) => {
  const v = redirectParams(page).get(key);
  expect(v, `"${key}" in ${page.url()}`).toBeTruthy();
  if (key === 'code') expect(v).toMatch(/^[A-Za-z0-9_-]{43}$/);
});

Then("the redirect query has the request's {string}", async ({ page }: { page: Page }, key: string) => {
  expect(key).toBe('state');
  expect(redirectParams(page).get('state')).toBe(requestState);
});

Then('the redirect query has {string} = the Nebu issuer', async ({ page }: { page: Page }, key: string) => {
  expect(redirectParams(page).get(key)).toBe(E2E_ISSUER);
});

Then('the redirect query has no {string}', async ({ page }: { page: Page }, key: string) => {
  expect(redirectParams(page).has(key)).toBe(false);
});

// ─── story oauth-authorize-freshness (P3): consent decisions and the client side ───────────────

When('the user allows the app', async ({ page }: { page: Page }) => {
  await decide(page, 'allow');
});

When('the user denies the app', async ({ page }: { page: Page }) => {
  await decide(page, 'deny');
});

/** WCAG 3.2.1 / 2.1.1: the page must not move focus by itself (no autofocus on a decision button). */
Then('no element of the consent page has keyboard focus', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  const active = await page.evaluate(() => document.activeElement?.tagName ?? 'NONE');
  expect(['BODY', 'HTML', 'NONE'], `the focused element on load was <${active}>`).toContain(active);
});

/**
 * Keyboard only (M-1, G3-5): Deny comes first and is the first Tab stop (an aria-disabled Allow is focusable, but it
 * comes after Deny); the key press armed Allow (600 ms); the focus then moves onto Allow AFTER arming (the second Tab
 * stop); Shift+Tab goes back, Tab again, Enter on Allow decides.
 */
When('the user chooses Allow with the keyboard only', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await useIssuerOriginForConsent(page);
  const allow = page.locator('button[name="decision"][value="allow"]');
  const deny = page.locator('button[name="decision"][value="deny"]');
  await expect(allow, 'Allow starts aria-disabled').toHaveAttribute('aria-disabled', 'true');
  await expect(deny, 'Deny is never aria-disabled').not.toHaveAttribute('aria-disabled', /.*/);
  await page.keyboard.press('Tab');
  await expect(deny, 'the first Tab stop is the Deny button (Deny first, Allow is still unavailable)').toBeFocused();
  await expect(allow, 'a key press armed Allow after the dwell time').not.toHaveAttribute('aria-disabled', 'true', {
    timeout: 10_000,
  });
  await page.keyboard.press('Tab');
  await expect(allow, 'the second Tab stop is the Allow button').toBeFocused();
  await page.keyboard.press('Shift+Tab');
  await expect(deny).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(allow).toBeFocused();
  await page.keyboard.press('Enter');
  if (expectedRedirect) await page.waitForURL((url) => url.href.startsWith(expectedRedirect), { timeout: NAV_TIMEOUT_MS });
});

/** The params of a fragment-mode client redirect (`https://client/cb#error=...&state=...&iss=...`). */
function fragmentParams(page: Page): URLSearchParams {
  return new URLSearchParams(new URL(page.url()).hash.replace(/^#/, ''));
}

Then('the redirect fragment has {string} = {string}', async ({ page }: { page: Page }, key: string, value: string) => {
  await page.waitForURL((url) => url.href.startsWith(expectedRedirect), { timeout: NAV_TIMEOUT_MS });
  expect(fragmentParams(page).get(key)).toBe(value);
});

Then("the redirect fragment has the request's {string}", async ({ page }: { page: Page }, key: string) => {
  expect(key).toBe('state');
  expect(fragmentParams(page).get('state')).toBe(requestState);
  expect(fragmentParams(page).get('iss'), 'RFC 9207 iss on the error redirect too').toBe(E2E_ISSUER);
});

Then('the redirect fragment has no {string}', async ({ page }: { page: Page }, key: string) => {
  expect(fragmentParams(page).has(key)).toBe(false);
  expect(redirectParams(page).has(key), 'not in the query either').toBe(false);
});

/** The client redeems the code at POST /oauth2/token with its PKCE verifier (what makes the replacement of a legacy device happen). */
When('the client exchanges the code', async ({ page, request }: { page: Page; request: APIRequestContext }) => {
  const params = redirectParams(page);
  const code = params.get('code') ?? fragmentParams(page).get('code');
  expect(code, `a code in ${page.url()}`).toBeTruthy();
  const redirectUri = expectedRedirect.split('#')[0];
  const r = await request.post(`${NEBU_BASE_URL}/oauth2/token`, {
    form: {
      grant_type: 'authorization_code',
      code: code!,
      redirect_uri: redirectUri,
      code_verifier: lastVerifier,
      client_id: lastClientId,
    },
  });
  expect(r.status(), `token endpoint: ${await r.text()}`).toBe(200);
});

/** Open the consent page and keep what a replay needs: the page's CSRF token and the consent cookie. */
Given('the consent page for {string} is shown', async ({ page }: { page: Page }, name: string) => {
  const c = client(name);
  await interceptClient(page, c.redirectUri);
  await openAuthorize(page, authorizeUrl(validParams(c, { response_mode: 'query' })));
  await signInAtDex(page);
  await page.waitForURL((url) => url.pathname === CONSENT_PATH, { timeout: NAV_TIMEOUT_MS });
  // a reload re-renders the page from the live row (PRG, FR7); its response carries the headers under test
  lastResponse = await page.reload({ waitUntil: 'domcontentloaded' });
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });

  const csrf = await page.locator('input[name="csrf_token"]').first().getAttribute('value');
  expect(csrf, 'the consent form carries a CSRF token').toBeTruthy();
  const cookie = (await page.context().cookies(NEBU_BASE_URL)).find((ck) => /^(__Host-)?nebu_oauth_consent$/.test(ck.name));
  expect(cookie, 'the consent cookie is set').toBeTruthy();
  consentForm = { csrf: csrf!, cookie: { name: cookie!.name, value: cookie!.value } };
});

When('the browser reloads the page', async ({ page }: { page: Page }) => {
  lastResponse = await page.reload({ waitUntil: 'domcontentloaded' });
});

Then('the consent page is shown', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  expect(new URL(page.url()).pathname).toBe(CONSENT_PATH);
});

Then(
  'the response has the header {string} = {string}',
  async ({}, name: string, value: string) => {
    expect(lastResponse?.headers()[name.toLowerCase()]).toBe(value);
  },
);

Then('the response has a Content-Security-Policy containing {string}', async ({}, part: string) => {
  const csp = lastResponse?.headers()['content-security-policy'] ?? '';
  expect(csp, `CSP was ${JSON.stringify(csp)}`).toContain(part);
});

/**
 * The SAME consent form (cookie, CSRF token, same-origin navigation headers, the issuer origin) is
 * posted again after the Allow: the row is single use, so the answer is the invalid_state page (400),
 * never a second code. The answer is rendered into the page so the shared page assertions apply.
 */
When('the same consent form is posted again', async ({ page, request }: { page: Page; request: APIRequestContext }) => {
  expect(consentForm, 'the consent form was captured before the decision').not.toBeNull();
  const r = await request.post(`${NEBU_BASE_URL}${CONSENT_PATH}`, {
    form: { csrf_token: consentForm!.csrf, decision: 'allow' },
    headers: {
      Cookie: `${consentForm!.cookie.name}=${consentForm!.cookie.value}`,
      Origin: new URL(E2E_ISSUER).origin,
      'Sec-Fetch-Site': 'same-origin',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-User': '?1',
    },
    maxRedirects: 0,
  });
  expect(r.status(), 'a replayed consent form is refused, never answered with a second redirect').toBe(400);
  await page.setContent(await r.text());
});
