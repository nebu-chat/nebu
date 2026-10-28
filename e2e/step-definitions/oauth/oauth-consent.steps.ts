/**
 * Step definitions for features/oauth/oauth-consent.feature
 *
 * Story: oauth-broker / oauth-authorize-freshness (P3). Runs only against the full compose stack with the real
 * Dex; NOT executable in the isolated env (verified with `bddgen --tags "@oauth-consent"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Scope of THIS file: the assertions about the consent page itself, the legacy device of the test user
 * and the scenario hygiene. The authorize / client side of the feature (the named web client, the
 * authorize URL with response_mode + device, Allow / Deny, the redirect checks, the code exchange, the
 * header checks and the form replay) is in oauth-authorize.steps.ts because it shares that file's
 * scenario state. Reused steps, never redefined here (bddgen rejects duplicates): "OAuth is enabled with
 * an https issuer", "an approved native client {string} with redirect URI {string}", "the user signs in
 * at the IdP", "the page is marked as OAuth error {string}"
 * (oauth-authorize.steps.ts) and "the test user has an OAuth session on device {string} through {string}",
 * "the access token of device {string} still works", "the page has exactly one level-1 heading", "the page
 * has no detectable accessibility violations", "the page does not scroll horizontally at a 320 px
 * viewport" (oauth-account-management.steps.ts).
 *
 * Page contract (shared with server/test/nebu/oauth/oauth_consent_page_test.exs):
 *   <main data-page="oauth-consent" data-device="new|same_client|replace" data-fresh="true|false">, a <dl>
 *   with the facts (user id, "App name (claimed by the app)", "App website (claimed by the app, approved by
 *   your administrator)", the redirect target, the session line), two submit buttons name="decision".
 *
 * Arming (story consent-arming-hardening, G3-5): Allow is rendered aria-disabled="true" (never `disabled`) and armed by
 * the shared Nebu.Web.ArmScript, the same script as the legacy SSO confirmation page: >= 600 ms after load AND real
 * interaction that is NOT on Allow (pointer move >= 4 px, key press, wheel, focus move elsewhere, touchstart elsewhere).
 * After arming a mouse click is accepted only after a real pointer move onto Allow, a keyboard Enter only after the
 * focus moved onto Allow, a tap once armed. A blocked activation is announced in [data-arm-status] (role=status).
 * The G3-5 / touch / keyboard steps below do exactly what a user does: real mouse moves, real key presses and real touch
 * events through the CDP `Input.dispatchTouchEvent` (the admin-ui project runs Chromium). They keep their own state and
 * helpers (a local copy of the issuer-origin override of oauth-authorize.steps.ts, its own CDP touch session): step
 * files share no module state.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, CDPSession, Page } from '@playwright/test';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  clearOAuthClientsByIdPrefix,
  clearOAuthConsentRequestsByClientPrefix,
  clearOAuthSessionsByClientPrefix,
  clearDeviceOfUser,
} from '../../fixtures/db';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const CLIENT_PREFIX = 'e2e-oauth-consent-';
const LEGACY_REDIRECT = 'http://localhost:7070/#/home';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const CONSENT_PATH = '/oauth2/consent';
// the issuer (a fake https URL by default, the real https origin with NEBU_E2E_OAUTH_ISSUER): fixtures/oauth-issuer.ts
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
const ARM_DWELL_MS = 700; // the page arms Allow >= 600 ms after load
/** Tall enough that the whole consent page (three warning blocks at most) is inside the viewport: pointer and touch coordinates are viewport coordinates. */
const TALL_VIEWPORT = { width: 1280, height: 1800 };

type LegacySession = { accessToken: string; userId: string };

// Scenario-scoped state (reset in the Before hook).
let priorIssuer: string | null = null;
let legacySessions: Record<string, LegacySession> = {};
let touchSession: CDPSession | null = null;
/** POSTs to the consent path seen by the scenario's page (a submitted decision), see "still on the consent page". */
let consentPosts = 0;
let trackedPages = new WeakSet<Page>();

// ─── Hooks ─────────────────────────────────────────────────────────────────────

// Captured BEFORE the Background's "OAuth is enabled with an https issuer" changes it.
Before({ tags: '@oauth-consent' }, async () => {
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  legacySessions = {};
  touchSession = null;
  consentPosts = 0;
  trackedPages = new WeakSet<Page>();
});

// Never leave OAuth switched on, the issuer changed, fixture clients, their sessions, consent rows or the
// legacy device behind. Order: sessions (matrix_sessions.client_id is ON DELETE RESTRICT) and consent rows
// before the clients. Failures are NOT swallowed (see fixtures/db.ts).
After({ tags: '@oauth-consent' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  for (const [deviceId, s] of Object.entries(legacySessions)) clearDeviceOfUser(s.userId, deviceId);
});

// ─── Given: a legacy session ───────────────────────────────────────────────────

async function whoamiStatus(request: APIRequestContext, token: string): Promise<number> {
  const r = await request.get(`${NEBU_BASE_URL}/_matrix/client/v3/account/whoami`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return r.status();
}

/** A LEGACY session (raw-JWT branch of POST /login) of the test user for `deviceId`, in a separate browser context. */
Given(
  'the test user has a legacy session on device {string}',
  async ({ browser, request }: { browser: Browser; request: APIRequestContext }, deviceId: string) => {
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
      await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
      await page.locator('input[name="login"]').fill(NEBU_USERS.alex.email);
      await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
      await page.locator('button[type="submit"]').click();
      // Dex shows a grant screen only on the first login per client (best-effort probe, see the account steps). It acts
      // ONLY on Dex's own approval page: the name regex also matches Nebu's consent button "Allow" (G3-5).
      // Raced against the browser leaving Dex, so the probe does not wait the full 6 s when the flow already moved on.
      const branch = await Promise.race([
        page.waitForURL((url) => url.pathname.includes('/dex/approval'), { timeout: 6_000 }).then(() => 'approval' as const),
        page.waitForURL((url) => !/^\/dex(\/|$)/i.test(url.pathname), { timeout: 6_000 }).then(() => 'left-dex' as const),
      ]).catch(() => 'none' as const);
      if (branch === 'approval') await page.getByRole('button', { name: /^(grant access|approve|confirm)$/i }).click();
      await page.waitForURL((url) => url.href.startsWith('http://localhost:7070/'), { timeout: NAV_TIMEOUT_MS });
      const loginToken = new URL(page.url()).searchParams.get('loginToken');
      expect(loginToken, 'the legacy SSO flow returned a loginToken').toBeTruthy();

      const login = await request.post(`${NEBU_BASE_URL}/_matrix/client/v3/login`, {
        data: { type: 'm.login.token', token: loginToken, device_id: deviceId },
      });

      expect(login.status(), `legacy login: ${await login.text()}`).toBe(200);
      const body = (await login.json()) as { access_token: string; user_id: string };
      expect(await whoamiStatus(request, body.access_token), 'the legacy token works before the replacement').toBe(200);
      legacySessions[deviceId] = { accessToken: body.access_token, userId: body.user_id };
    } finally {
      await ctx.close();
    }
  },
);

// ─── Then: the consent page ────────────────────────────────────────────────────

function consentMain(page: Page) {
  return page.locator('main[data-page="oauth-consent"]');
}

Then(
  'the consent page names the app {string} as claimed by the app',
  async ({ page }: { page: Page }, appName: string) => {
    await expect(consentMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await expect(consentMain(page)).toContainText('App name (claimed by the app)');
    await expect(consentMain(page)).toContainText(appName);
  },
);

/**
 * M-1 / G3-5: ONE inline script (hash-pinned by the CSP), Allow rendered aria-disabled="true" (never the `disabled`
 * attribute), Deny first and never aria-disabled, the polite live region empty until the script announces.
 */
Then('the consent page has one hash-pinned script and Allow starts unavailable', async ({ page }: { page: Page }) => {
  await expect(consentMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(page.locator('script')).toHaveCount(1);
  expect(await page.locator('script').first().getAttribute('src'), 'the script is inline').toBeNull();
  const buttons = consentMain(page).locator('button[name="decision"]');
  await expect(buttons).toHaveCount(2);
  await expect(buttons.nth(0), 'Deny is first').toHaveAttribute('value', 'deny');
  await expect(buttons.nth(0), 'Deny is a plain button').not.toHaveAttribute('aria-disabled', /.*/);
  await expect(buttons.nth(0)).not.toHaveAttribute('disabled', /.*/);
  await expect(buttons.nth(1)).toHaveAttribute('value', 'allow');
  await expect(buttons.nth(1), 'Allow starts aria-disabled, nothing armed it').toHaveAttribute('aria-disabled', 'true');
  await expect(buttons.nth(1), 'never the disabled attribute (a screen-reader touch user could not reach it)').not.toHaveAttribute(
    'disabled',
    /.*/,
  );
  await expect(page.locator('[data-arm-status][role="status"]'), 'the live region is empty until the script announces').toHaveText('');
});

Then('the consent page names the website {string}', async ({ page }: { page: Page }, host: string) => {
  await expect(consentMain(page)).toContainText('App website (claimed by the app, not verified by Nebu)');
  await expect(consentMain(page)).toContainText(host);
});

Then(
  'the consent page says a new session {string} will be created',
  async ({ page }: { page: Page }, deviceId: string) => {
    await expect(consentMain(page)).toHaveAttribute('data-device', 'new');
    await expect(consentMain(page)).toContainText(`A new session (device ${deviceId}) will be created.`);
  },
);

Then(
  'the consent page says the existing session {string} will be replaced and signed out',
  async ({ page }: { page: Page }, deviceId: string) => {
    await expect(consentMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await expect(consentMain(page)).toHaveAttribute('data-device', 'replace');
    await expect(consentMain(page)).toContainText(new RegExp(`Replaces your existing session .+ \\(device ${deviceId}\\)`));
    await expect(consentMain(page)).toContainText('That session will be signed out.');
  },
);

/**
 * The notice (data-role="freshness-notice") is present EXACTLY when the page says data-fresh="false". Which
 * variant a real IdP produces is evidence for gate y (Dex reportedly sends no auth_time): it is recorded as
 * an annotation, never asserted.
 */
Then(
  'the freshness notice is shown exactly when the consent page is marked as not fresh',
  async ({ page, $testInfo }: { page: Page; $testInfo: { annotations: { type: string; description?: string }[] } }) => {
    await expect(consentMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    const fresh = await consentMain(page).getAttribute('data-fresh');
    expect(['true', 'false']).toContain(fresh);
    const notice = consentMain(page).locator('[data-role="freshness-notice"]');
    if (fresh === 'false') {
      await expect(notice).toHaveCount(1);
      await expect(notice).toContainText('You were not asked for your password just now.');
      await expect(notice).toContainText('choose Deny');
    } else {
      await expect(notice).toHaveCount(0);
    }
    $testInfo.annotations.push({
      type: 'gate-y',
      description: fresh === 'false' ? 'the IdP did not confirm a new sign-in (no auth_time or stale): notice shown' : 'the IdP confirmed the sign-in (auth_time present): no notice',
    });
  },
);

// ─── Then: after the decision ──────────────────────────────────────────────────

Then(
  'the legacy access token of device {string} is rejected',
  async ({ request }: { request: APIRequestContext }, deviceId: string) => {
    const s = legacySessions[deviceId];
    if (!s) throw new Error(`the test user has no legacy session on device "${deviceId}" in this scenario`);
    expect(await whoamiStatus(request, s.accessToken), 'the legacy session was replaced by the OAuth session (T7/T26)').toBe(401);
  },
);

Then('the browser is not redirected to {string}', async ({ page }: { page: Page }, target: string) => {
  const t = new URL(target);
  const here = new URL(page.url());
  expect(`${here.origin}${here.pathname}`, 'the user stays on Nebu: no redirect to the client (FR18)').not.toBe(`${t.origin}${t.pathname}`);
  expect(here.origin).toBe(new URL(NEBU_BASE_URL).origin);
});

// ─── story consent-arming-hardening (G3-5): pointer, keyboard and touch arming ──────────────────

function allowButton(page: Page) {
  return page.locator('button[name="decision"][value="allow"]');
}

/** Allow is armed: aria-disabled is no longer "true" (the script flips aria-disabled, never `disabled`). */
async function expectArmed(page: Page, message: string): Promise<void> {
  await expect(allowButton(page), message).not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
}

/** Wait until the page lived longer than the arming dwell (600 ms), measured by the page itself. */
async function waitArmDwell(page: Page): Promise<void> {
  await page.waitForFunction((ms: number) => performance.now() > ms, ARM_DWELL_MS, { timeout: 15_000 });
}

async function centerOf(page: Page, selector: string): Promise<{ x: number; y: number }> {
  const box = await page.locator(selector).boundingBox();
  expect(box, `${selector} has a layout box`).not.toBeNull();
  return { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 };
}

async function touchTap(session: CDPSession, x: number, y: number): Promise<void> {
  await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
  await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
}

/**
 * LOCAL COPY of `useIssuerOriginForConsent` in oauth-authorize.steps.ts: the e2e stack serves Nebu at http://localhost:8008
 * while the issuer is a fake https URL, and the consent POST is checked against the ISSUER origin (FR8), so the browser's
 * `Origin` of the consent POST is replaced with it. Needed because these steps submit Allow themselves.
 */
async function useIssuerOriginForConsent(page: Page): Promise<void> {
  await page.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** Count the decisions (POSTs) the page submitted, so "still on the consent page" proves that nothing was sent. */
function trackConsentPosts(page: Page): void {
  if (trackedPages.has(page)) return;
  trackedPages.add(page);
  page.on('request', (r) => {
    if (r.method() === 'POST' && new URL(r.url()).pathname === CONSENT_PATH) consentPosts += 1;
  });
}

async function prepareDecisionSteps(page: Page, setViewport = true): Promise<void> {
  await expect(consentMain(page), 'the consent page is shown').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  if (setViewport) await page.setViewportSize(TALL_VIEWPORT); // the touch scenario sets it BEFORE enabling touch emulation
  trackConsentPosts(page);
  await useIssuerOriginForConsent(page);
}

// ── mouse: the G3-5 lure ──────────────────────────────────────────────────────────────────────

/**
 * AC6b, the G3-5 regression. The lure shows the consent page, makes the victim move the pointer and wait, and then asks
 * for a second click at the position where Allow IS once the page is armed (arming hides the hint, which moves Allow
 * up). This step first learns that armed position on one load (a real pointer move arms the page), reloads (GET is read
 * only, FR7: a fresh, unarmed page), parks the pointer at the armed position of Allow, lets a key press arm the page
 * (interaction that is NOT on Allow) and then presses and releases the mouse button WITHOUT moving. Playwright's mouse
 * is real input: no pointermove with new coordinates happens over Allow after arming.
 */
When(
  'the mouse rests on the armed position of Allow while the consent page arms and then clicks without moving',
  async ({ page }: { page: Page }) => {
    await prepareDecisionSteps(page);
    await waitArmDwell(page);
    await page.mouse.move(10, 10);
    await page.mouse.move(70, 60, { steps: 6 });
    await expectArmed(page, 'a real pointer move arms the page (learning the armed layout)');
    const armedBox = await allowButton(page).boundingBox();
    expect(armedBox, 'armed Allow has a layout box').not.toBeNull();
    // the top edge of the armed Allow (arming hides the hint and moves Allow up): armed Allow is under this point after arming
    const parked = { x: armedBox!.x + armedBox!.width / 2, y: armedBox!.y + 3 };

    await page.reload({ waitUntil: 'domcontentloaded' });
    await expect(consentMain(page), 'the reloaded consent page is shown').toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await expect(allowButton(page), 'a reload gives a fresh, unarmed page').toHaveAttribute('aria-disabled', 'true');

    const unarmedBox = await allowButton(page).boundingBox();
    expect(unarmedBox, 'unarmed Allow has a layout box').not.toBeNull();
    expect(
      parked.y >= unarmedBox!.y && parked.y <= unarmedBox!.y + unarmedBox!.height,
      `the parked point must NOT be on the unarmed Allow ${JSON.stringify(unarmedBox)}: Allow only arrives under the pointer with the arming`,
    ).toBe(false);
    await page.mouse.move(parked.x, parked.y); // the pointer parks where Allow will be
    await waitArmDwell(page);
    await page.keyboard.press('Shift'); // a key press is interaction that is not on Allow: it arms the page
    await expectArmed(page, 'a key press arms Allow');
    const box = await allowButton(page).boundingBox();
    expect(box, 'Allow has a layout box').not.toBeNull();
    expect(
      parked.x >= box!.x && parked.x <= box!.x + box!.width && parked.y >= box!.y && parked.y <= box!.y + box!.height,
      `the lure premise: the parked pointer (${parked.x}, ${parked.y}) is on the armed Allow ${JSON.stringify(box)}`,
    ).toBe(true);
    await page.mouse.down();
    await page.mouse.up();
  },
);

// ── keyboard: focus on Allow before arming ────────────────────────────────────────────────────

/**
 * AC6c (negative half): the focus is on Allow BEFORE the page arms (a programmatic focus is neither a key press nor
 * interaction elsewhere, so it does not arm), a key press arms the page, and Enter on the still focused Allow must not
 * submit: the focus did not move onto Allow after arming.
 */
When(
  'the user focuses Allow on the consent page before it arms and presses Enter once it is armed',
  async ({ page }: { page: Page }) => {
    await prepareDecisionSteps(page);
    await allowButton(page).focus();
    await expect(allowButton(page), 'an aria-disabled Allow is focusable').toBeFocused();
    await expect(allowButton(page), 'focusing Allow does not arm the page').toHaveAttribute('aria-disabled', 'true');
    await waitArmDwell(page);
    await page.keyboard.press('Shift');
    await expectArmed(page, 'a key press armed the page');
    await expect(allowButton(page), 'the focus never left Allow').toBeFocused();
    await page.keyboard.press('Enter');
  },
);

/**
 * Kassandra INFO #2 (G3-5): a lure can hand the victim a consent URL that ends in `#allow`. Chromium then focuses
 * the fragment target (Allow is focusable although it is aria-disabled). A fresh document load (no `hashchange`: the
 * page is left first) must not make Allow activatable: the inherited focus is not "focus moved onto Allow after
 * arming", so Enter after a key press that arms the page is cancelled and announced.
 */
When(
  'the consent page is loaded again with the inherited fragment {string}, a key press arms it and Enter is pressed',
  async ({ page }: { page: Page }, fragment: string) => {
    await prepareDecisionSteps(page);
    const url = new URL(page.url());
    url.hash = '';
    await page.goto('about:blank');
    await page.goto(url.href + fragment, { waitUntil: 'domcontentloaded' });
    await expect(consentMain(page), 'the consent page is shown again').toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await expect(allowButton(page), 'the inherited fragment does not arm the page').toHaveAttribute('aria-disabled', 'true');
    await waitArmDwell(page);
    await page.keyboard.press('Shift');
    await expectArmed(page, 'a key press arms the page');
    await page.keyboard.press('Enter');
  },
);

/** The focus moves off Allow and back onto it AFTER arming (a focusin after arming), then Enter submits. */
When('the user moves the focus off Allow and back on the consent page and presses Enter', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Shift+Tab');
  await expect(allowButton(page)).not.toBeFocused();
  await page.keyboard.press('Tab');
  await expect(allowButton(page), 'the focus is back on Allow').toBeFocused();
  await page.keyboard.press('Enter');
});

// ── touch ─────────────────────────────────────────────────────────────────────────────────────

Given('the browser emulates a touch device for the consent page', async ({ page }: { page: Page }) => {
  // Playwright's `hasTouch` is a context option (fixed when the context is created); the same Chromium emulation is
  // switched on here through the DevTools protocol, and the taps are dispatched as real touch events below.
  await page.setViewportSize(TALL_VIEWPORT); // before the touch emulation: a viewport change would reset it
  touchSession = await page.context().newCDPSession(page);
  await touchSession.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
});

/** A tap on Allow right away (nothing armed the page yet) is blocked: a touch on Allow itself never arms. */
When('the user taps Allow on the consent page right away', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser emulates a touch device').not.toBeNull();
  await prepareDecisionSteps(page, false);
  const { x, y } = await centerOf(page, 'button[name="decision"][value="allow"]');
  await touchTap(touchSession!, x, y);
});

When('the user taps the consent page outside Allow', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser emulates a touch device').not.toBeNull();
  await waitArmDwell(page);
  await touchTap(touchSession!, 8, 8);
  await expectArmed(page, 'a tap elsewhere >= 600 ms after load arms Allow');
});

/** Once armed a tap on Allow is accepted (touch has no hover); the position is read AFTER arming (the layout moved). */
When('the user taps Allow on the consent page', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser emulates a touch device').not.toBeNull();
  const { x, y } = await centerOf(page, 'button[name="decision"][value="allow"]');
  await touchTap(touchSession!, x, y);
});

// ── shared checks ─────────────────────────────────────────────────────────────────────────────

/** Nothing was decided: the user is still on Nebu's consent page and the page submitted no decision. */
Then('the browser is still on the consent page', async ({ page }: { page: Page }) => {
  // the scenarios assert the announcement first (a submit would have navigated away); let any navigation settle
  await page.waitForLoadState('domcontentloaded');
  await expect(consentMain(page)).toBeVisible();
  expect(new URL(page.url()).pathname, 'no decision was submitted').toBe(CONSENT_PATH);
  expect(consentPosts, 'the consent form was not posted').toBe(0);
});

/** UX B1/B2: the polite live region [data-arm-status] says what happened (and why a click was blocked). */
Then('the consent page announces {string}', async ({ page }: { page: Page }, text: string) => {
  const region = page.locator('[data-arm-status][role="status"]');
  await expect(region).toBeVisible();
  await expect(region).toContainText(text, { timeout: 10_000 });
});
