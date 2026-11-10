/**
 * Step definitions for features/oauth-pages-redesign/03-consent-page-redesign.feature
 *
 * Story: oauth-pages-redesign / 03-consent-page-redesign (REQ-2026-018). Runs only against the full compose stack with the real Dex
 * (NOT executable in the isolated env, same as story 01 / 02). ATDD RED phase: the redesigned consent page does not exist yet.
 *
 * The feature file has no Background (it is the verbatim Gherkin of the story), so a `@REQ-2026-018` Before hook enables OAuth with the e2e issuer and an
 * After hook restores the prior config and removes every fixture (sessions + devices, consent rows, consent grants, clients), same pattern as
 * page-shell-and-i18n.steps.ts / oauth-device-naming-chain.steps.ts.
 *
 * The Given steps of this feature carry the whole login: the shared step "the consent page is shown" (oauth-authorize.steps.ts, reused, never redefined
 * here: bddgen rejects duplicates) only ASSERTS that the browser is on the consent page, so the browser has to be there when the When runs. A Given
 * that "a login happened" is exactly that. Step files share no module state, so the helpers below (Dex sign-in, Allow arming, issuer origin, legacy
 * session) are copies of the ones in oauth-authorize.steps.ts / oauth-consent.steps.ts.
 *
 * What a real Dex decides and this suite cannot force: whether the login is FRESH (Dex reportedly sends no auth_time, gate y). A scenario that needs
 * the other variant is skipped with a `gate-y` annotation, never silently passed.
 *
 * Page contract (server/test/nebu/oauth/consent_page_redesign_test.exs): `main[data-page="oauth-consent"]`, notices `#freshness-notice`,
 * `#destination-notice`, `#replace-notice`, the device name line `[data-role="device-name"]`, a native `<details>` with `<summary>` (closed), Allow `#allow`
 * (class `primary`), Deny first, the device name field `input#device-name[name="device_name"]` with its error `#device-name-error`.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, Page, TestInfo } from '@playwright/test';
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
} from '../../fixtures/db';
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const CLIENT_PREFIX = 'e2e-oauth-consent-redesign-';
const CONSENT_PATH = '/oauth2/consent';
const AUTHORIZE_PATH = '/oauth2/authorize';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const LEGACY_REDIRECT = 'http://localhost:7070/#/home';
const STABLE = 'urn:matrix:client:';
const DE_HEADER = 'de-AT,de;q=0.9,en;q=0.5';
const PHONE = { width: 390, height: 844 };

/** A step text with characters that are special in a Cucumber expression ( ) / "..." as an exact regular expression. */
const lit = (text: string): RegExp => new RegExp('^' + text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') + '$');

type Spec = { clientId: string; redirectUri: string; deviceId: string; acceptLanguage: string };
type LegacySession = { userId: string; deviceId: string };

let priorIssuer: string | null = null;
let legacySessions: LegacySession[] = [];
let lastSpec: Spec | null = null;
let deviceCounter = 0;
/** What the arming scenario observed (filled by its When step). */
let arming: {
  initialAllowAriaDisabled: string | null;
  denyAriaDisabled: string | null;
  denyFirst: boolean;
  armedAfterInteraction: boolean;
  scriptCount: number;
  scriptHashInCsp: boolean;
  noJsAllowAriaDisabled: string | null;
  noJsDecisionPosts: number;
  noJsStillOnConsent: boolean;
} | null = null;

// ─── Hooks ─────────────────────────────────────────────────────────────────────

Before({ tags: '@REQ-2026-018' }, async () => {
  legacySessions = [];
  lastSpec = null;
  deviceCounter = 0;
  arming = null;
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  upsertServerConfig('oauth_issuer_url', E2E_ISSUER);
  upsertServerConfig('oauth_enabled', 'true');
});

// Order: sessions + devices (matrix_sessions.client_id is ON DELETE RESTRICT), grants and consent rows, then the clients. Failures are NOT swallowed.
After({ tags: '@REQ-2026-018' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  for (const s of legacySessions) clearDeviceOfUser(s.userId, s.deviceId);
});

// ─── helpers ───────────────────────────────────────────────────────────────────

function nextDeviceId(): string {
  deviceCounter += 1;
  return `E2ECRD${String(deviceCounter).padStart(2, '0')}${randomBytes(2).toString('hex').toUpperCase()}`;
}

function authorizeUrl(spec: Spec): string {
  const verifier = randomBytes(32).toString('base64url');
  const qs = new URLSearchParams({
    response_type: 'code',
    client_id: spec.clientId,
    redirect_uri: spec.redirectUri,
    scope: `${STABLE}api:* ${STABLE}device:${spec.deviceId}`,
    state: `e2e-state-${randomBytes(6).toString('hex')}`,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'),
    code_challenge_method: 'S256',
  });
  return `${NEBU_BASE_URL}${AUTHORIZE_PATH}?${qs.toString()}`;
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

async function signInAtDex(page: Page): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form (prompt=login forces an interactive login)').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(NEBU_USERS.alex.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  await approveDexGrantIfShown(page);
}

/** Nothing listens at the client: every navigation to its redirect target gets a stub page. */
async function stubClient(page: Page, redirectUri: string): Promise<void> {
  const u = new URL(redirectUri);
  await page.route(`${u.protocol}//${u.host}/**`, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>client stub</title><p>client</p>' }),
  );
}

/** The consent POST is checked against the ISSUER origin (FR8): the e2e issuer is a fake https URL, so the browser's Origin is replaced (copy of oauth-authorize.steps.ts). */
async function useIssuerOriginForConsent(page: Page): Promise<void> {
  await page.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** Allow is armed by REAL pointer movement elsewhere, then hovered (copy of armAllow in oauth-authorize.steps.ts). */
async function armAllow(page: Page): Promise<void> {
  const allow = allowButton(page);
  await page.mouse.move(40, 40);
  await page.mouse.move(90, 110, { steps: 6 });
  await expect(allow, 'Allow is armed by real pointer movement').not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
  await page.mouse.move(4, 4);
  await allow.hover();
}

function consentMain(page: Page) {
  return page.locator('main[data-page="oauth-consent"]');
}

function allowButton(page: Page) {
  return page.locator('main[data-page="oauth-consent"] button[name="decision"][value="allow"]');
}

function denyButton(page: Page) {
  return page.locator('main[data-page="oauth-consent"] button[name="decision"][value="deny"]');
}

/** Insert the approved client, then log in at the IdP in `page` until the consent page of a NEW device is shown. */
async function reachConsent(page: Page, spec: Spec): Promise<void> {
  lastSpec = spec;
  await page.context().setExtraHTTPHeaders({ 'Accept-Language': spec.acceptLanguage });
  await stubClient(page, spec.redirectUri);
  await page.goto(authorizeUrl(spec), { waitUntil: 'domcontentloaded' });
  await signInAtDex(page);
  await expect(consentMain(page), 'the browser is on the consent page after the IdP login').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  expect(new URL(page.url()).pathname).toBe(CONSENT_PATH);
}

function approvedClient(suffix: string, opts: { name: string; clientUri: string; redirectUri: string; tosUri?: string; policyUri?: string }): Spec {
  const clientId = `${CLIENT_PREFIX}${suffix}`;
  insertOAuthClient({
    clientId,
    status: 'approved',
    redirectUris: [opts.redirectUri],
    applicationType: 'web',
    clientUri: opts.clientUri,
    clientName: opts.name,
    tosUri: opts.tosUri,
    policyUri: opts.policyUri,
  });
  return { clientId, redirectUri: opts.redirectUri, deviceId: nextDeviceId(), acceptLanguage: 'en' };
}

/** A not-fresh / fresh login depends on what the real IdP reports (gate y): skip the scenario with an annotation when it is the wrong variant. */
async function requireFreshness(page: Page, wanted: 'true' | 'false', $testInfo: TestInfo): Promise<void> {
  const fresh = await consentMain(page).getAttribute('data-fresh');
  if (fresh !== wanted) {
    $testInfo.annotations.push({ type: 'gate-y', description: `the IdP produced data-fresh="${fresh}", the scenario needs "${wanted}"` });
    $testInfo.skip(true, `gate-y: the real IdP cannot be made to produce a login with data-fresh="${wanted}" here`);
  }
}

/** A LEGACY session (raw-JWT branch of POST /login) of the test user for `deviceId` (copy of the step in oauth-consent.steps.ts). */
async function legacySessionOn(browser: Browser, request: APIRequestContext, deviceId: string): Promise<void> {
  const ctx = await browser.newContext();
  try {
    const page = await ctx.newPage();
    await page.route('http://localhost:7070/**', (route) =>
      route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><title>legacy client stub</title>' }),
    );
    await page.goto(`${NEBU_BASE_URL}/_matrix/client/v3/login/sso/redirect?redirectUrl=${encodeURIComponent(LEGACY_REDIRECT)}`, {
      waitUntil: 'domcontentloaded',
    });
    await signInAtDex(page);
    await page.waitForURL((url) => url.href.startsWith('http://localhost:7070/'), { timeout: NAV_TIMEOUT_MS });
    const loginToken = new URL(page.url()).searchParams.get('loginToken');
    expect(loginToken, 'the legacy SSO flow returned a loginToken').toBeTruthy();
    const login = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/login`, {
      data: { type: 'm.login.token', token: loginToken, device_id: deviceId },
    });
    expect(login.status(), `legacy login: ${await login.text()}`).toBe(200);
    const body = (await login.json()) as { user_id: string };
    legacySessions.push({ userId: body.user_id, deviceId });
  } finally {
    await ctx.close();
  }
}

// ─── Scenario: The decision is in the first view on a phone ───────────────────

Given(
  'a fresh login, a new device and no warnings, at a 390 x 844 viewport, in German and in English',
  async ({ page, $testInfo }: { page: Page; $testInfo: TestInfo }) => {
    await page.setViewportSize(PHONE);
    // The app's website is the redirect host: no destination warning. A new device id: no replacement.
    const spec = approvedClient('phone', {
      name: 'Element Web',
      clientUri: 'https://chat.e2e.example/web',
      redirectUri: 'https://chat.e2e.example/cb',
    });
    await reachConsent(page, spec);
    await requireFreshness(page, 'true', $testInfo);
  },
);

/** Everything the first view must show (inside the viewport, no scrolling) and nothing of the old label/value list. */
async function expectDecisionInFirstView(page: Page, labels: { allow: string; deny: string; access: RegExp }): Promise<void> {
  const main = consentMain(page);
  await expect(main).toHaveAttribute('data-fresh', 'true');
  await expect(main.locator('[data-role$="-notice"]'), 'no warnings when nothing applies').toHaveCount(0);
  await expect(main.locator('h1')).toBeInViewport();
  await expect(main.getByText('Element Web').first(), 'the app name').toBeInViewport();
  await expect(main.getByText(labels.access).first(), 'the permission sentence').toBeInViewport();
  await expect(main.locator('[data-role="device-name"]'), 'the device name').toBeInViewport();
  await expect(denyButton(page)).toHaveText(labels.deny);
  await expect(allowButton(page)).toHaveText(labels.allow);
  await expect(denyButton(page), 'Deny is in the first view').toBeInViewport();
  await expect(allowButton(page), 'Allow is in the first view').toBeInViewport();
  await expect(main.locator('dl:visible, table:visible'), 'no label/value list in the first view').toHaveCount(0);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow, 'no horizontal scroll at 390 px').toBeLessThanOrEqual(0);
}

Then(
  lit('the heading, the app name, the permission sentence, the device name and both buttons are visible without scrolling and no label/value list is shown'),
  async ({ page, $testInfo }: { page: Page; $testInfo: TestInfo }) => {
    // English: the page the Given reached
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
    await expect(consentMain(page).locator('h1')).toHaveText('Allow this app to use your account?');
    await expectDecisionInFirstView(page, { allow: 'Allow', deny: 'Deny', access: /full access/ });

    // German: a second login with a German browser
    const german: Spec = { ...lastSpec!, deviceId: nextDeviceId(), acceptLanguage: DE_HEADER };
    await reachConsent(page, german);
    await requireFreshness(page, 'true', $testInfo);
    await expect(page.locator('html')).toHaveAttribute('lang', 'de');
    await expect(consentMain(page).locator('h1')).toHaveText('Dieser App Zugriff auf Ihr Konto erlauben?');
    await expectDecisionInFirstView(page, { allow: 'Erlauben', deny: 'Ablehnen', access: /vollen Zugriff/ });
  },
);

// ─── Scenario: Risk notices stay visible before the decision ──────────────────

Given(
  "a login that is not fresh, a destination outside the app's website, and a session that would be replaced",
  async ({ page, browser, request, $testInfo }: { page: Page; browser: Browser; request: APIRequestContext; $testInfo: TestInfo }) => {
    const spec = approvedClient('risk', {
      name: 'Risk App',
      clientUri: 'https://app.e2e.example',
      redirectUri: 'https://login.evil.e2e.example/cb',
    });
    await legacySessionOn(browser, request, spec.deviceId);
    await reachConsent(page, spec);
    await requireFreshness(page, 'false', $testInfo);
  },
);

Then(
  'the three notices appear above the app block with their ids, a text label and an icon, are not inside the collapsed details, and Allow is aria-described by them',
  async ({ page }: { page: Page }) => {
    const main = consentMain(page);
    const ids = ['freshness-notice', 'destination-notice', 'replace-notice'];
    const appBlock = main.getByText('Risk App').first();
    const appY = (await appBlock.boundingBox())!.y;
    const describedBy = ((await allowButton(page).getAttribute('aria-describedby')) ?? '').split(/\s+/);

    for (const id of ids) {
      const notice = main.locator(`#${id}`);
      await expect(notice, `${id} is shown`).toBeVisible();
      await expect(notice, `${id} keeps its data-role`).toHaveAttribute('data-role', id);
      await expect(notice.locator('svg'), `${id} has an icon`).toHaveCount(1);
      await expect(notice.locator('strong').first(), `${id} has a text label`).not.toHaveText('');
      expect(await main.locator(`details #${id}`).count(), `${id} is not inside the details`).toBe(0);
      expect((await notice.boundingBox())!.y, `${id} is above the app block`).toBeLessThan(appY);
      expect(describedBy, `Allow is aria-described by ${id}`).toContain(id);
    }
    await expect(main.locator('details')).not.toHaveAttribute('open', /.*/);
  },
);

// ─── Scenario: Details are collapsed and complete ─────────────────────────────

const TOS = 'https://chat.e2e.example/terms?a=1&b=2';
const PRIVACY = 'https://chat.e2e.example/privacy?x=1';

Given('the consent page with an app that supplies a website, terms and privacy URLs', async ({ page }: { page: Page }) => {
  const spec = approvedClient('details', {
    name: 'Details App',
    clientUri: 'https://chat.e2e.example/web',
    redirectUri: 'https://chat.e2e.example/cb',
    tosUri: TOS,
    policyUri: PRIVACY,
  });
  await reachConsent(page, spec);
});

When('the user opens "Show details"', async ({ page }: { page: Page }) => {
  const details = consentMain(page).locator('details');
  await expect(details, 'collapsed on load').not.toHaveAttribute('open', /.*/);
  await details.locator('summary').click();
  await expect(details).toHaveAttribute('open', /.*/);
});

Then(
  lit('the website, the destination (id consent-destination), the session line, the terms and the privacy URLs are shown as escaped plain text and none of them is a link'),
  async ({ page }: { page: Page }) => {
    const details = consentMain(page).locator('details');
    await expect(details.getByText('chat.e2e.example').first(), 'the website').toBeVisible();
    await expect(details.locator('#consent-destination'), 'the destination').toBeVisible();
    await expect(details.locator('#consent-destination')).toContainText('chat.e2e.example');
    await expect(details, 'the session line names the new device').toContainText(lastSpec!.deviceId);
    await expect(details).toContainText(TOS);
    await expect(details).toContainText(PRIVACY);
    await expect(page.locator('a'), 'nothing on the page is a link').toHaveCount(0);
    await expect(page.locator('[href]')).toHaveCount(0);
  },
);

// ─── Scenario: Arming behaviour is unchanged ──────────────────────────────────

Given('the new consent page', async ({ page }: { page: Page }) => {
  const spec = approvedClient('arming', {
    name: 'Arming App',
    clientUri: 'https://chat.e2e.example/web',
    redirectUri: 'https://chat.e2e.example/cb',
  });
  await reachConsent(page, spec);
});

When('the arming tests of ArmScript and the consent flow run', async ({ page, browser }: { page: Page; browser: Browser }) => {
  const buttons = consentMain(page).locator('button[name="decision"]');
  const initialAllowAriaDisabled = await allowButton(page).getAttribute('aria-disabled');
  const denyAriaDisabled = await denyButton(page).getAttribute('aria-disabled');
  const denyFirst = (await buttons.nth(0).getAttribute('value')) === 'deny';
  const scriptCount = await page.locator('script').count();

  // the CSP allows the inline script by its SHA-256 (the page is reloaded to read the response headers of the same page)
  const inline = (await page.locator('script').first().textContent()) ?? '';
  const response = await page.reload({ waitUntil: 'domcontentloaded' });
  const csp = response?.headers()['content-security-policy'] ?? '';
  const scriptHashInCsp = csp.includes(`script-src 'sha256-${createHash('sha256').update(inline).digest('base64')}'`) && !csp.includes('unsafe-inline');

  // armed only after real interaction
  await expect(allowButton(page)).toHaveAttribute('aria-disabled', 'true');
  await armAllow(page);
  const armedAfterInteraction = (await allowButton(page).getAttribute('aria-disabled')) !== 'true';

  // without JavaScript: a second login in a context with JavaScript off, Allow must stay unavailable and a click must send nothing
  const ctx = await browser.newContext({ javaScriptEnabled: false });
  let noJsAllowAriaDisabled: string | null = null;
  let noJsDecisionPosts = 0;
  let noJsStillOnConsent = false;
  try {
    const plain = await ctx.newPage();
    plain.on('request', (r) => {
      if (r.method() === 'POST' && new URL(r.url()).pathname === CONSENT_PATH) noJsDecisionPosts += 1;
    });
    await reachConsent(plain, { ...lastSpec!, deviceId: nextDeviceId() });
    noJsAllowAriaDisabled = await allowButton(plain).getAttribute('aria-disabled');
    await allowButton(plain).click({ force: true });
    // event-driven bounded window: a decision POST would fire a request event; none is expected, so the wait ends by its timeout
    await plain
      .waitForRequest((r) => r.method() === 'POST' && new URL(r.url()).pathname === CONSENT_PATH, { timeout: 1_000 })
      .catch(() => undefined);
    noJsStillOnConsent = new URL(plain.url()).pathname === CONSENT_PATH;
  } finally {
    await ctx.close();
  }

  arming = {
    initialAllowAriaDisabled,
    denyAriaDisabled,
    denyFirst,
    armedAfterInteraction,
    scriptCount,
    scriptHashInCsp,
    noJsAllowAriaDisabled,
    noJsDecisionPosts,
    noJsStillOnConsent,
  };
});

Then(
  lit('Allow is inert until armed, Deny is never aria-disabled and comes first, Allow without JavaScript stays unavailable, the page still carries exactly one inline script allowed by its SHA-256 and the full mouse / keyboard / touch instructions stay available to assistive technology'),
  async ({ page }: { page: Page }) => {
    expect(arming, 'the arming When step ran').not.toBeNull();
    const a = arming!;
    expect(a.initialAllowAriaDisabled, 'Allow is inert until armed').toBe('true');
    expect(a.armedAfterInteraction, 'real interaction arms Allow').toBe(true);
    expect(a.denyAriaDisabled, 'Deny is never aria-disabled').toBeNull();
    expect(a.denyFirst, 'Deny comes first').toBe(true);
    expect(a.noJsAllowAriaDisabled, 'Allow without JavaScript stays unavailable').toBe('true');
    expect(a.noJsDecisionPosts, 'a click on Allow without JavaScript sends nothing').toBe(0);
    expect(a.noJsStillOnConsent).toBe(true);
    expect(a.scriptCount, 'exactly one inline script').toBe(1);
    expect(a.scriptHashInCsp, 'the CSP allows that script by its SHA-256 (no unsafe-inline)').toBe(true);

    // the full instructions are named by Allow's aria-describedby, not hidden, not inside the details; the visible hint is one short line
    const described = ((await allowButton(page).getAttribute('aria-describedby')) ?? '').split(/\s+/).filter((id) => id !== '');
    expect(described).toContain('arm-hint');
    const hint = ((await page.locator('#arm-hint').textContent()) ?? '').trim();
    expect(hint.length, `one short hint line: "${hint}"`).toBeLessThanOrEqual(140);
    let instructions = '';
    for (const id of described) {
      if (id === 'arm-hint') continue;
      const el = page.locator(`#${id}`);
      const text = ((await el.textContent()) ?? '').trim();
      if (text.length > 80) {
        instructions = text;
        expect(await page.locator(`details #${id}`).count(), 'the instructions are not inside a closed <details>').toBe(0);
        expect(await el.getAttribute('aria-hidden'), 'not aria-hidden').toBeNull();
        expect(await el.getAttribute('hidden'), 'not hidden').toBeNull();
      }
    }
    expect(instructions, 'the mouse / keyboard / touch instructions stay available').toMatch(/Mouse/);
    expect(instructions).toMatch(/Keyboard/);
    expect(instructions).toMatch(/Touch/);
  },
);

// ─── Scenario: The required device name is part of the main view ──────────────

Given('an approved client from which no device name can be derived', async ({ page }: { page: Page }) => {
  // a generic client name and an http client website: neither yields a name (story 01), so the user is asked
  const spec = approvedClient('ask', { name: 'App', clientUri: 'http://nohost.e2e.example', redirectUri: 'https://nohost.e2e.example/cb' });
  await reachConsent(page, spec);
});

Then(
  lit('a labelled "Device name" field sits above the buttons (not in details) with its own error message after a refusal, and Allow stays the only filled button'),
  async ({ page }: { page: Page }) => {
    const main = consentMain(page);
    const input = main.locator('input[name="device_name"]');
    await expect(input).toBeVisible();
    await expect(input).toHaveAttribute('required', /.*/);
    await expect(input).toHaveAttribute('maxlength', '64');
    expect(await main.locator('details input').count(), 'the field is not in the details').toBe(0);
    await expect(main.getByLabel(/Device name/i), 'a visible label "Device name"').toHaveCount(1);
    const inputY = (await input.boundingBox())!.y;
    expect(inputY, 'the field is above Deny').toBeLessThan((await denyButton(page).boundingBox())!.y);
    expect(inputY, 'the field is above Allow').toBeLessThan((await allowButton(page).boundingBox())!.y);

    // Allow is the only filled button: its background is painted, Deny's is not
    const fill = (loc: ReturnType<typeof allowButton>) => loc.evaluate((el) => getComputedStyle(el).backgroundColor);
    const [allowFill, denyFill] = [await fill(allowButton(page)), await fill(denyButton(page))];
    expect(allowFill, 'Allow is filled').not.toMatch(/rgba\(\s*\d+,\s*\d+,\s*\d+,\s*0\s*\)|transparent/);
    expect(denyFill, 'Deny is outlined, not filled').toMatch(/rgba\(\s*\d+,\s*\d+,\s*\d+,\s*0\s*\)|transparent/);

    // a refusal (Allow without a name) shows the page again with the field's OWN error message
    await useIssuerOriginForConsent(page);
    await input.fill('');
    await armAllow(page);
    await Promise.all([
      page.waitForResponse((r) => new URL(r.url()).pathname === CONSENT_PATH && r.request().method() === 'POST', { timeout: NAV_TIMEOUT_MS }),
      allowButton(page).click(),
    ]);
    await page.waitForLoadState('domcontentloaded');
    await expect(main).toBeVisible();
    const error = main.locator('#device-name-error');
    await expect(error, 'the refusal has its own message').toBeVisible();
    await expect(error).toHaveAttribute('role', 'alert');
    await expect(main.locator('input[name="device_name"]')).toHaveAttribute('aria-describedby', /device-name-error/);
    expect(await main.locator('details #device-name-error').count()).toBe(0);
  },
);
