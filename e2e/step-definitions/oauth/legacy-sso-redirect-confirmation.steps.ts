/**
 * Step definitions for features/oauth/legacy-sso-redirect-confirmation.feature
 *
 * Story: oauth-broker / legacy-sso-redirect-confirmation (epic SEC gate 3, G3-3) — ATDD tests (written before
 * the implementation; runs only against the full compose stack with the real Dex; NOT executable in the isolated
 * environment: verified with `bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project, baseURL = Nebu at
 * http://localhost:8008 (plain http: the `nebu_sso_confirm` cookie variant; the `__Host-` variant is covered by
 * the plug tests).
 *
 * Reused steps, never redefined here (bddgen rejects duplicates): "the Nebu stack is running", "bootstrap is already
 * completed" (admin/bootstrap.steps.ts), "the user signs in at the IdP", "the client receives the redirect at
 * {string}", "the redirect query has a {string}", "the redirect query has {string} = {string}", "the response has a
 * Content-Security-Policy starting with {string}" (oauth-authorize.steps.ts), "the browser is not redirected to
 * {string}" (oauth-consent.steps.ts), "the page has exactly one level-1 heading", "the page has no detectable
 * accessibility violations", "the page does not scroll horizontally at a 320 px viewport"
 * (oauth-account-management.steps.ts).
 *
 * Client side: nothing listens on the https redirect targets, so every target is intercepted at CONTEXT level
 * (a popup is a new page of the same context) and answered with a stub page that records whether `window.opener`
 * survived (data-opener on <body>). The stub of the popup client page also exposes `window.startLogin(url)`
 * (window.open, no noopener), the way a web client such as FluffyChat web starts the legacy SSO flow.
 *
 * Arming (story D9, oracle m5): Continue is rendered aria-disabled="true" (UX B1: focusable, announced) and armed by ONE inline script (Nebu.Web.ArmScript)
 * >= 600 ms after load AND after real interaction that is NOT on Continue: a pointer move of >= 4 px, a key press,
 * a wheel event, a focus move, or (touch) a touchstart elsewhere (a scroll alone never arms). For mouse / pen a click is accepted only after a
 * `pointermove` with non-zero movement over Continue that happened AFTER the arming; a fragment change (`hashchange`) disarms. The steps below do exactly what a user does:
 * real mouse moves (Playwright's mouse is real input), a real key press, and real touch events through the CDP
 * `Input.dispatchTouchEvent` (the admin-ui project runs Chromium).
 *
 * "the response has a Content-Security-Policy starting with" reads the last response recorded by
 * oauth-authorize.steps.ts: this file hands the confirmation page's GET response over through `setLastResponse`.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Browser, BrowserContext, CDPSession, Page, Response } from '@playwright/test';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';
import { isDexAuth, saveConfigFormWithAdminReauth, signInAtDexAsAdmin } from '../../fixtures/oauth-admin';
import { setLastResponse } from './oauth-authorize.steps';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const REDIRECT_PATH = '/_matrix/client/v3/login/sso/redirect';
const CONFIRM_PATH = '/_matrix/client/v3/login/sso/confirm';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const ARM_DWELL_MS = 700; // the page arms Continue >= 600 ms after load

// Scenario-scoped state (reset in the Before hook).
let operatorOriginsSet = false;
let touchSession: CDPSession | null = null;
let confirmForm: { csrf: string; cookie: { name: string; value: string } } | null = null;
let popupPage: Page | null = null;
let lastRedirectResponse: Response | null = null;
/** POST requests to the confirmation path seen by the scenario's pages (a submitted decision), see "still on the page". */
let confirmPosts = 0;

// ─── Hooks ─────────────────────────────────────────────────────────────────────

Before({ tags: '@legacy-sso-confirm' }, async () => {
  operatorOriginsSet = false;
  touchSession = null;
  confirmForm = null;
  popupPage = null;
  lastRedirectResponse = null;
  confirmPosts = 0;
});

// Never leave an operator list behind: it is cleared through the SAME Admin UI form (the save refreshes the
// server's OidcConfig cache on every node; a direct DB write would leave the cache stale).
After({ tags: '@legacy-sso-confirm' }, async ({ browser }: { browser: Browser }) => {
  if (operatorOriginsSet) {
    await setOperatorOrigins(browser, '');
    operatorOriginsSet = false;
  }
});

// ─── helpers ───────────────────────────────────────────────────────────────────

/** A stub client page: records whether `window.opener` survived, and (for the popup client) can start a popup. */
const STUB_HTML =
  '<!doctype html><html><head><title>client stub</title></head><body data-opener="pending"><p>client</p>' +
  '<script>document.body.setAttribute("data-opener", String(window.opener !== null));' +
  'window.startLogin = function (u) { window.open(u); return true; };</script></body></html>';

function loginUrl(redirectUrl: string): string {
  return `${NEBU_BASE_URL}${REDIRECT_PATH}?redirectUrl=${encodeURIComponent(redirectUrl)}`;
}

/**
 * Remember the confirmation page's GET response for the shared "the response has a Content-Security-Policy" step
 * and count the POSTs to the confirmation path (race-free "nothing was submitted" check, no timeouts).
 */
function recordConfirmResponses(page: Page): void {
  page.on('request', (r) => {
    if (new URL(r.url()).pathname === CONFIRM_PATH && r.method() === 'POST') confirmPosts += 1;
  });
  page.on('response', (r) => {
    const u = new URL(r.url());
    if (u.pathname === CONFIRM_PATH && r.request().method() === 'GET' && r.request().isNavigationRequest()) setLastResponse(r);
  });
}

async function signInAtDexAsAlex(page: Page): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form (prompt=login forces an interactive login)').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(NEBU_USERS.alex.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  const grant = page.getByRole('button', { name: /^(grant access|allow|approve|confirm)$/i });
  const shown = await grant
    .waitFor({ state: 'visible', timeout: 6_000 })
    .then(() => true)
    .catch(() => false);
  if (shown) await grant.click();
}

function confirmMain(page: Page) {
  return page.locator('main[data-page="sso-confirm"]');
}

function continueButton(page: Page) {
  return page.locator('button#continue');
}

/** Continue is armed: aria-disabled is no longer "true" (UX B1: the script flips aria-disabled, never `disabled`). */
async function expectArmed(page: Page, message: string): Promise<void> {
  await expect(continueButton(page), message).not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
}

/** Wait until the page lived longer than the arming dwell (600 ms), measured by the page itself. */
async function waitArmDwell(page: Page): Promise<void> {
  await page.waitForFunction((ms: number) => performance.now() > ms, ARM_DWELL_MS, { timeout: 15_000 });
}

/** Keep what a replay needs: the page's CSRF token and the binding cookie. */
async function captureConfirmForm(page: Page): Promise<void> {
  const csrf = await page.locator('input[name="csrf_token"]').first().getAttribute('value');
  expect(csrf, 'the confirmation form carries a CSRF token').toBeTruthy();
  const cookie = (await page.context().cookies(NEBU_BASE_URL)).find((c) => /^(__Host-)?nebu_sso_confirm$/.test(c.name));
  expect(cookie, 'the binding cookie is set').toBeTruthy();
  confirmForm = { csrf: csrf!, cookie: { name: cookie!.name, value: cookie!.value } };
}

/**
 * The user's Continue as a mouse user does it: real pointer movement away from the button arms the page (>= 4 px,
 * >= 600 ms after load), then the pointer travels onto Continue (a real move over it after arming) and clicks.
 */
async function armAndContinue(page: Page): Promise<void> {
  await expect(confirmMain(page), 'the confirmation page is shown').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await captureConfirmForm(page);
  await waitArmDwell(page);
  await page.mouse.move(10, 10);
  await page.mouse.move(70, 60, { steps: 6 });
  await expectArmed(page, 'Continue is armed by real pointer movement');
  await page.mouse.move(4, 4); // leave no pointer on the button, so hover() below is a real move onto it
  await continueButton(page).hover();
  await continueButton(page).click();
}

async function touchTap(session: CDPSession, x: number, y: number): Promise<void> {
  await session.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
  await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
}

async function centerOf(page: Page, selector: string): Promise<{ x: number; y: number }> {
  const box = await page.locator(selector).boundingBox();
  expect(box, `${selector} has a layout box`).not.toBeNull();
  return { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 };
}

/** Sign in at the Admin UI (own browser context), set the operator list through the form, close the context. */
async function setOperatorOrigins(browser: Browser, value: string): Promise<void> {
  const ctx: BrowserContext = await browser.newContext();
  try {
    const page = await ctx.newPage();
    await page.goto(`${NEBU_BASE_URL}/admin/login/start`, { waitUntil: 'domcontentloaded' });
    await page.waitForURL((u) => isDexAuth(u) || /\/admin\/(login|dashboard|config)/.test(u.pathname), { timeout: NAV_TIMEOUT_MS });
    if (/\/admin\/login/.test(new URL(page.url()).pathname)) {
      const sso = page.getByRole('link', { name: /login with sso|sign in with sso/i });
      if (await sso.isVisible({ timeout: 3_000 }).catch(() => false)) await sso.click();
      else await page.getByRole('button', { name: /login with sso|sign in with sso/i }).click();
    }
    if (isDexAuth(new URL(page.url())) || (await page.waitForURL((u) => isDexAuth(u), { timeout: 10_000 }).then(() => true).catch(() => false))) {
      await signInAtDexAsAdmin(page);
    }
    await page.goto(`${NEBU_BASE_URL}/admin/config`, { waitUntil: 'domcontentloaded' });
    await page.locator('input[name="sso_redirect_allowed_origins"]').fill(value);
    // saving needs a fresh admin sign-in (story sso-origins-admin-hardening, X-1): the helper drives the Dex login
    await saveConfigFormWithAdminReauth(page, {
      form: '#sso-origins-form',
      field: 'input[name="sso_redirect_allowed_origins"]',
      button: /save sso origins/i,
    });
    await expect(page.locator('[role="status"]').filter({ hasText: /saved/i })).toBeVisible({ timeout: 10_000 });
  } finally {
    await ctx.close();
  }
}

// ─── Background ────────────────────────────────────────────────────────────────

Given('the browser stubs the client page {string}', async ({ page }: { page: Page }, target: string) => {
  const u = new URL(target);
  // context level: a popup opened by a stubbed page is a new page of the same context
  await page.context().route(`${u.protocol}//${u.host}/**`, (route) =>
    route.fulfill({ status: 200, contentType: 'text/html', body: STUB_HTML }),
  );
});

Given('the operator lists {string} as an allowed SSO redirect origin', async ({ browser }: { browser: Browser }, origin: string) => {
  await setOperatorOrigins(browser, origin);
  operatorOriginsSet = true;
});

Given('the browser is a touch device', async ({ page }: { page: Page }) => {
  // Playwright's `hasTouch` is a context option (fixed when the context is created); the same Chromium emulation is
  // switched on here through the DevTools protocol, and the taps are dispatched as real touch events below.
  touchSession = await page.context().newCDPSession(page);
  await touchSession.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
});

// ─── When: the legacy SSO login ─────────────────────────────────────────────────

When('the browser starts a legacy SSO login with redirectUrl {string}', async ({ page }: { page: Page }, redirectUrl: string) => {
  recordConfirmResponses(page);
  lastRedirectResponse = await page.goto(loginUrl(redirectUrl), { waitUntil: 'domcontentloaded' });
});

When(
  'the browser starts a legacy SSO login whose redirectUrl hides {string} behind a backslash before {string}',
  async ({ page }: { page: Page }, evilHost: string, listedHost: string) => {
    // https://evil.e2e.example\@listed.e2e.example/cb: a browser reads the backslash as a slash (host = the evil
    // host), URI.parse/1 reads userinfo + the listed host. The backslash is built here, not in the Gherkin text.
    const hostile = `https://${evilHost}\\@${listedHost}/cb`;
    lastRedirectResponse = await page.goto(loginUrl(hostile), { waitUntil: 'domcontentloaded' });
  },
);

When('the user continues the SSO sign-in', async ({ page }: { page: Page }) => {
  await armAndContinue(page);
});

When('the user cancels the SSO sign-in', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page), 'the confirmation page is shown').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await page.locator('button[name="decision"][value="cancel"]').click();
});

/**
 * The browser's Back button after Continue, then the SAME confirmation form posted again (cookie, CSRF token,
 * same-origin navigation headers): the pending entry is single use, so the answer is the invalid_state page
 * (400), never a second loginToken. The answer is rendered into the page so the shared page assertions apply.
 */
When('the browser goes back and submits the SSO confirmation again', async ({ page, request }: { page: Page; request: APIRequestContext }) => {
  expect(confirmForm, 'the confirmation form was captured before Continue').not.toBeNull();
  await page.goBack({ waitUntil: 'domcontentloaded' }).catch(() => null);
  const r = await request.post(`${NEBU_BASE_URL}${CONFIRM_PATH}`, {
    form: { csrf_token: confirmForm!.csrf, decision: 'continue' },
    headers: {
      Cookie: `${confirmForm!.cookie.name}=${confirmForm!.cookie.value}`,
      Origin: new URL(NEBU_BASE_URL).origin,
      'Sec-Fetch-Site': 'same-origin',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-User': '?1',
    },
    maxRedirects: 0,
  });
  expect(r.status(), 'a replayed confirmation is refused, never answered with a second redirect').toBe(400);
  await page.setContent(await r.text());
});

// ─── When: touch and mouse arming ───────────────────────────────────────────────

When('the user taps Continue on the SSO confirmation page right away', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser is a touch device').not.toBeNull();
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  const { x, y } = await centerOf(page, 'button#continue');
  await touchTap(touchSession!, x, y);
});

When('the user taps the SSO confirmation page outside Continue', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser is a touch device').not.toBeNull();
  await waitArmDwell(page);
  await touchTap(touchSession!, 8, 8);
  await expectArmed(page, 'a tap elsewhere >= 600 ms after load arms Continue');
});

When('the user taps Continue on the SSO confirmation page', async ({ page }: { page: Page }) => {
  expect(touchSession, 'the browser is a touch device').not.toBeNull();
  const { x, y } = await centerOf(page, 'button#continue');
  await touchTap(touchSession!, x, y);
});

/**
 * G3-5: the pointer rests ON Continue before the page arms (a double-click lure parks the pointer on the spot);
 * a key press arms the page (interaction that is not on Continue), then a click WITHOUT moving must not submit.
 */
When(
  'the mouse rests on Continue while the SSO confirmation page arms and then clicks without moving',
  async ({ page }: { page: Page }) => {
    await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    await continueButton(page).hover();
    await waitArmDwell(page);
    await page.keyboard.press('Shift');
    await expectArmed(page, 'a key press arms Continue');
    await page.mouse.down();
    await page.mouse.up();
  },
);

When('the user moves the mouse onto Continue and clicks it', async ({ page }: { page: Page }) => {
  await page.mouse.move(4, 4);
  await page.mouse.move(40, 30, { steps: 4 });
  await continueButton(page).hover(); // a real pointer move onto Continue after arming
  await continueButton(page).click();
});

/**
 * Keyboard (oracle m5 / rule c): a key press arms the page (>= 600 ms after load), Tab moves the focus to Continue
 * and Enter activates it (a click with detail 0 is accepted once armed; no pointer is involved).
 */
When('the user arms the SSO confirmation page with a key press and activates Continue with Tab and Enter', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await waitArmDwell(page);
  await page.keyboard.press('Shift');
  await expectArmed(page, 'a key press arms Continue');
  for (let i = 0; i < 4; i += 1) {
    await page.keyboard.press('Tab');
    if (await page.evaluate(() => document.activeElement?.id === 'continue')) break;
  }
  await expect(continueButton(page), 'Tab reached Continue').toBeFocused();
  await page.keyboard.press('Enter');
});

/**
 * SEC #4: the focus is on Continue BEFORE the page arms (Tab, Tab: Cancel, then the aria-disabled Continue). Once
 * armed, Enter does NOT submit: the focus did not move onto Continue after arming.
 */
When('the user focuses Continue with the keyboard before the page arms and presses Enter once it is armed', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  for (let i = 0; i < 4; i += 1) {
    await page.keyboard.press('Tab');
    if (await page.evaluate(() => document.activeElement?.id === 'continue')) break;
  }
  await expect(continueButton(page), 'Continue (aria-disabled) is focusable').toBeFocused();
  await expectArmed(page, 'the key presses armed the page');
  await page.keyboard.press('Enter');
});

/** The focus moves off Continue and back onto it AFTER arming (a focusin after arming), then Enter submits. */
When('the user moves the focus off Continue and back with the keyboard and presses Enter', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Shift+Tab');
  await expect(continueButton(page)).not.toBeFocused();
  await page.keyboard.press('Tab');
  await expect(continueButton(page), 'the focus is back on Continue').toBeFocused();
  await page.keyboard.press('Enter');
});

// ─── popup client ───────────────────────────────────────────────────────────────

When(
  'the stub client page {string} opens a legacy SSO login popup with redirectUrl {string}',
  async ({ page }: { page: Page }, clientPage: string, redirectUrl: string) => {
    await page.goto(clientPage, { waitUntil: 'domcontentloaded' });
    const popupPromise = page.waitForEvent('popup');
    await page.evaluate((u: string) => (window as unknown as { startLogin: (x: string) => boolean }).startLogin(u), loginUrl(redirectUrl));
    popupPage = await popupPromise;
    recordConfirmResponses(popupPage);
  },
);

When('the user signs in at the IdP in the popup', async () => {
  expect(popupPage, 'a popup was opened by the client page').not.toBeNull();
  await signInAtDexAsAlex(popupPage!);
  await popupPage!.waitForURL((u) => !/\/dex\//i.test(u.pathname) && u.pathname !== '/_matrix/client/v3/login/sso/redirect/oidc', {
    timeout: NAV_TIMEOUT_MS,
  });
});

When('the user continues the SSO sign-in in the popup', async () => {
  expect(popupPage, 'a popup was opened by the client page').not.toBeNull();
  await armAndContinue(popupPage!);
});

// ─── Then: the confirmation page ────────────────────────────────────────────────

Then('the SSO confirmation page names the target {string}', async ({ page }: { page: Page }, origin: string) => {
  await expect(page.locator('main[data-page="sso-confirm"][data-result="pending"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(page.locator('[data-role="target-origin"]')).toHaveText(origin);
});

Then('the SSO confirmation page names the signed-in Matrix user', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(page.locator('[data-role="user-id"]')).toHaveText(/^@[^\s:]+:\S+$/);
});

Then('the SSO confirmation page does not contain {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  expect(await page.content(), 'the query and the fragment of the redirect URL are never rendered').not.toContain(text);
  expect(page.url()).not.toContain(text);
});

/** ONE inline script (hash-pinned by the CSP), Cancel first and never disabled, Continue rendered aria-disabled. */
Then('the SSO confirmation page has one hash-pinned script and Continue starts disabled', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(page.locator('script')).toHaveCount(1);
  expect(await page.locator('script').first().getAttribute('src'), 'the script is inline').toBeNull();
  const buttons = confirmMain(page).locator('button[name="decision"]');
  await expect(buttons).toHaveCount(2);
  await expect(buttons.nth(0), 'Cancel is first').toHaveAttribute('value', 'cancel');
  await expect(buttons.nth(0)).toBeEnabled();
  await expect(buttons.nth(1)).toHaveAttribute('value', 'continue');
  await expect(buttons.nth(1), 'Continue starts aria-disabled, nothing armed it').toHaveAttribute('aria-disabled', 'true');
  await expect(buttons.nth(1), 'never the disabled attribute (UX B1)').not.toHaveAttribute('disabled', /.*/);
});

/** UX B1/B2: the polite live region [data-arm-status] says what happened. */
Then('the SSO confirmation page announces {string}', async ({ page }: { page: Page }, text: string) => {
  const region = page.locator('[data-arm-status][role="status"]');
  await expect(region).toBeVisible();
  await expect(region).toContainText(text, { timeout: 10_000 });
});

Then('the page shows the SSO sign-in was cancelled', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="sso-confirm"][data-result="cancelled"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(page.locator('main h1')).toHaveText('Sign-in cancelled');
  await expect(page.locator('main')).toContainText('No access was given.');
});

Then('the browser is still on the SSO confirmation page', async ({ page }: { page: Page }) => {
  // race-free: every submit of the form is a POST request that the listener counted when it left the browser;
  // after the load state settled none was made, so the page itself refused to submit
  await page.waitForLoadState('domcontentloaded');
  expect(confirmPosts, 'no confirmation form was submitted').toBe(0);
  expect(new URL(page.url()).pathname).toBe(CONFIRM_PATH);
  await expect(page.locator('main[data-page="sso-confirm"][data-result="pending"]')).toBeVisible();
});

Then('the page is marked as SSO confirmation error {string}', async ({ page }: { page: Page }, code: string) => {
  await expect(page.locator(`main[data-page="sso-confirm-error"][data-error="${code}"]`)).toBeVisible({ timeout: 15_000 });
});

// ─── Then: the popup and the rejected redirect leg ──────────────────────────────

Then('the popup reaches {string} with a {string}', async ({}, target: string, key: string) => {
  expect(popupPage, 'a popup was opened by the client page').not.toBeNull();
  const t = new URL(target);
  await popupPage!.waitForURL((u) => `${u.origin}${u.pathname}` === `${t.origin}${t.pathname}`, { timeout: NAV_TIMEOUT_MS });
  expect(new URL(popupPage!.url()).searchParams.get(key), `"${key}" in ${popupPage!.url()}`).toBeTruthy();
});

/** Oracle M1: no COOP on any response of the flow, so a popup-based client (FluffyChat web) keeps window.opener. */
Then('the popup still has its opener', async () => {
  expect(popupPage, 'a popup was opened by the client page').not.toBeNull();
  await expect(popupPage!.locator('body')).toHaveAttribute('data-opener', /true|false/, { timeout: 15_000 });
  expect(await popupPage!.evaluate(() => window.opener !== null), 'window.opener survived the whole flow').toBe(true);
  await expect(popupPage!.locator('body')).toHaveAttribute('data-opener', 'true');
});

Then('the browser shows the SSO redirect error page with status {int}', async ({ page }: { page: Page }, status: number) => {
  expect(lastRedirectResponse, 'the redirect leg answered').not.toBeNull();
  expect(lastRedirectResponse!.status()).toBe(status);
  const u = new URL(page.url());
  expect(u.origin, 'the browser never left Nebu (no IdP redirect)').toBe(new URL(NEBU_BASE_URL).origin);
  expect(u.pathname).toBe(REDIRECT_PATH);
  await expect(page.locator('h1')).toHaveText('Login Method Not Supported');
});

/**
 * Review cycle 2 (LOW-2): the popup carries no COOP, so an opener can scroll it or navigate its fragment without any
 * user input. A scroll alone must not arm Continue and a fragment change must disarm it again.
 */
When('the opener scrolls the SSO confirmation page and changes its fragment without any user input', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await waitArmDwell(page);
  await page.evaluate(() => {
    window.scrollTo(0, 5);
    window.location.hash = '#continue';
  });
  await page.waitForTimeout(ARM_DWELL_MS + 300);
});

Then('Continue is still unavailable on the SSO confirmation page', async ({ page }: { page: Page }) => {
  await expect(continueButton(page)).toHaveAttribute('aria-disabled', 'true');
});

When('the user arms the SSO confirmation page with a key press and the opener then changes its fragment', async ({ page }: { page: Page }) => {
  await expect(confirmMain(page)).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await waitArmDwell(page);
  await page.keyboard.press('Shift');
  await expectArmed(page, 'a key press arms Continue');
  await page.evaluate(() => {
    window.location.hash = '#again';
  });
});
