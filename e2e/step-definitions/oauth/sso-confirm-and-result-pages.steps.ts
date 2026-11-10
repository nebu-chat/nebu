/**
 * Step definitions for features/oauth-pages-redesign/04-sso-confirm-and-result-pages.feature
 *
 * Story: oauth-pages-redesign / 04-sso-confirm-and-result-pages (REQ-2026-019). Runs only against the full compose stack with the real Dex
 * (NOT executable in the isolated env, same as the other stories of this epic). ATDD RED phase: the pages still have the old look.
 *
 * Every step text of this feature is new; nothing is redefined from legacy-sso-redirect-confirmation.steps.ts (bddgen rejects duplicates). Step files
 * share no module state, so the helpers below (Dex sign-in, arming dwell) are copies of the ones there.
 *
 * What the black-box run covers and what it cannot:
 *   - confirm page in German and English at 390 x 844, real Dex sign-in, real arming.
 *   - cancelled, invalid_state, forbidden and invalid_request pages through the real flow. `rate_limited` and `unavailable` cannot be provoked
 *     black-box; they are pinned (together with all the others) by server/test/nebu/matrix/sso_confirm_and_result_pages_test.exs.
 *   - UIA fallback: a real session row (fixtures/db insertUiaSession) bound to alex (completion) or to somebody else (mismatch), opened by a stub
 *     "client" page through window.open (so window.opener exists), Dex sign-in in the popup. `window.onAuthDone` is defined by a context init script,
 *     the `message` event of the opener records "authDone" (with onAuthDone defined it must stay "none": the spec script is `if (onAuthDone) ... else if (opener) postMessage`;
 *     the opener branch for a client WITHOUT onAuthDone is pinned byte-wise by server/test/nebu/matrix/uia_authdone_else_if_test.exs, no e2e variant). "logs nothing new" of the 403 page is pinned by the ExUnit test (no log access here).
 *   - unsupported-login page through the real redirect leg with a scheme that is not allowed.
 *
 * Page contract (server/test/nebu/matrix/sso_confirm_and_result_pages_test.exs): `main[data-page="sso-confirm"][data-result]`, `main[data-page=
 * "sso-confirm-error"][data-error]`, `#confirm-notice`, `[data-role="target-origin"]`, `button#continue` (aria-disabled until armed), ONE closed
 * `<details>` holding `[data-role="user-id"]` and `[data-role="target-path"]`, the shell (`.shell`) on every page.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Browser, BrowserContext, Page, Response } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';
import { insertUiaSession, deleteUiaSession } from '../../fixtures/db';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const REDIRECT_PATH = '/_matrix/client/v3/login/sso/redirect';
const CONFIRM_PATH = '/_matrix/client/v3/login/sso/confirm';
const CALLBACK_PATH = '/_matrix/client/v3/login/sso/redirect/oidc';
const UIA_FALLBACK_PATH = '/_matrix/client/v3/auth/m.login.sso/fallback/web';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const ARM_DWELL_MS = 700; // the page arms Continue >= 600 ms after load
const PHONE = { width: 390, height: 844 };
const LANGS = [
  { code: 'de', locale: 'de-AT' },
  { code: 'en', locale: 'en-US' },
] as const;
const TARGET = 'https://sso-confirm-04.e2e.example/cb/deep';
const OPENER_ORIGIN = 'https://sso-opener-04.e2e.example';

/** A step text with characters that are special in a Cucumber expression ( ) / "..." as an exact regular expression. */
const lit = (text: string): RegExp => new RegExp('^' + text.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') + '$');

type Lang = (typeof LANGS)[number];
type Seen = { lang: Lang; name: string; status: number; headers: Record<string, string>; body: string };
type UiaRun = { opener: Page; popup: Page; callback: Response | null; csp: string; consoleCsp: string[] };

let contexts: BrowserContext[] = [];
let confirmPages: { lang: Lang; page: Page }[] = [];
let seen: Seen[] = [];
let uiaSessions: string[] = [];
let uiaRun: UiaRun | null = null;
let unsupportedPage: Page | null = null;
let unsupportedStatus = 0;
let dialogs = 0;

// ─── Hooks ─────────────────────────────────────────────────────────────────────

Before({ tags: '@REQ-2026-019' }, async () => {
  contexts = [];
  confirmPages = [];
  seen = [];
  uiaSessions = [];
  uiaRun = null;
  unsupportedPage = null;
  unsupportedStatus = 0;
  dialogs = 0;
});

After({ tags: '@REQ-2026-019' }, async () => {
  for (const id of uiaSessions) deleteUiaSession(id);
  for (const c of contexts) await c.close().catch(() => null);
});

// ─── helpers ───────────────────────────────────────────────────────────────────

async function newContext(browser: Browser, lang: Lang, viewport?: { width: number; height: number }): Promise<BrowserContext> {
  const ctx = await browser.newContext({ locale: lang.locale, ...(viewport ? { viewport } : {}) });
  contexts.push(ctx);
  return ctx;
}

function loginUrl(redirectUrl: string): string {
  return `${NEBU_BASE_URL}${REDIRECT_PATH}?redirectUrl=${encodeURIComponent(redirectUrl)}`;
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

/** The same-origin top-level form post headers the confirmation endpoint expects (see legacy-sso-redirect-confirmation.steps.ts). */
const NAV_HEADERS = {
  Origin: new URL(NEBU_BASE_URL).origin,
  'Sec-Fetch-Site': 'same-origin',
  'Sec-Fetch-Mode': 'navigate',
  'Sec-Fetch-Dest': 'document',
  'Sec-Fetch-User': '?1',
};

function htmlLang(body: string): string | null {
  return /<html lang="([^"]*)"/.exec(body)?.[1] ?? null;
}

async function stubTarget(ctx: BrowserContext, origin: string, html: string): Promise<void> {
  const u = new URL(origin);
  await ctx.route(`${u.protocol}//${u.host}/**`, (route) => route.fulfill({ status: 200, contentType: 'text/html', body: html }));
}

// ─── Scenario 1: the confirm page, decision first ──────────────────────────────

Given(lit('a pending legacy SSO redirect in German and in English at 390 x 844'), async () => {
  confirmPages = [];
});

When(lit('the confirm page is shown'), async ({ browser }: { browser: Browser }) => {
  for (const lang of LANGS) {
    const ctx = await newContext(browser, lang, PHONE);
    await stubTarget(ctx, TARGET, '<!doctype html><title>client</title><p>client</p>');
    const page = await ctx.newPage();
    await page.goto(loginUrl(TARGET), { waitUntil: 'domcontentloaded' });
    await signInAtDexAsAlex(page);
    await expect(page.locator('main[data-page="sso-confirm"][data-result="pending"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    confirmPages.push({ lang, page });
  }
});

Then(
  lit(
    'heading, target origin, notice, Cancel and Continue are visible without scrolling, Cancel comes first, Continue is armed as before and user id and path are inside the collapsed details',
  ),
  async () => {
    expect(confirmPages).toHaveLength(2);
    for (const { lang, page } of confirmPages) {
      const where = `[${lang.code}]`;
      await expect(page.locator('html'), where).toHaveAttribute('lang', lang.code);

      // everything of the decision fits into the 390 x 844 viewport, without scrolling
      for (const selector of ['main h1', '[data-role="target-origin"]', '#confirm-notice', 'button[value="cancel"]', 'button#continue']) {
        const el = page.locator(selector);
        await expect(el, `${where} ${selector} is visible`).toBeVisible();
        const box = await el.boundingBox();
        expect(box, `${where} ${selector} has a box`).not.toBeNull();
        expect(box!.y, `${where} ${selector} starts inside the viewport`).toBeGreaterThanOrEqual(0);
        expect(box!.y + box!.height, `${where} ${selector} ends above the fold (${PHONE.height})`).toBeLessThanOrEqual(PHONE.height);
        expect(box!.x + box!.width, `${where} ${selector} is not wider than the viewport`).toBeLessThanOrEqual(PHONE.width);
      }
      await expect(page.locator('[data-role="target-origin"]')).toHaveText('https://sso-confirm-04.e2e.example');

      // Cancel first, Continue second
      const buttons = page.locator('main button[name="decision"]');
      await expect(buttons).toHaveCount(2);
      await expect(buttons.nth(0), `${where} Cancel first`).toHaveAttribute('value', 'cancel');
      await expect(buttons.nth(1)).toHaveAttribute('value', 'continue');
      await expect(buttons.nth(0)).not.toHaveAttribute('aria-disabled', /.*/);

      // user id and path are inside the collapsed details, hidden until opened
      const details = page.locator('main details');
      await expect(details).toHaveCount(1);
      expect(await details.evaluate((d) => (d as HTMLDetailsElement).open), `${where} details start closed`).toBe(false);
      await expect(details.locator('[data-role="user-id"]')).toHaveCount(1);
      await expect(details.locator('[data-role="target-path"]')).toHaveCount(1);
      await expect(page.locator('[data-role="user-id"]'), `${where} user id is hidden while collapsed`).toBeHidden();
      await expect(page.locator('[data-role="target-path"]')).toBeHidden();
      expect(await page.locator('main dl:visible').count(), `${where} no label/value list in the first view`).toBe(0);

      // Continue is armed as before: aria-disabled until the page saw real interaction after the dwell
      await expect(page.locator('button#continue')).toHaveAttribute('aria-disabled', 'true');
      await page.waitForFunction((ms: number) => performance.now() > ms, ARM_DWELL_MS, { timeout: 15_000 });
      await page.mouse.move(10, 10);
      await page.mouse.move(70, 60, { steps: 6 });
      await expect(page.locator('button#continue'), `${where} armed by real pointer movement`).not.toHaveAttribute('aria-disabled', 'true', {
        timeout: 10_000,
      });

      // opening the details shows them
      await page.locator('main summary').click();
      await expect(page.locator('[data-role="user-id"]')).toHaveText(/^@[^\s:]+:\S+$/);
      await expect(page.locator('[data-role="target-path"]')).toHaveText('/cb/deep');
    }
  },
);

// ─── Scenario 2: cancelled and error pages ─────────────────────────────────────

Given(lit('the cancelled page and each of the five error pages of the SSO confirmation'), async () => {
  seen = [];
});

When(lit('they are rendered'), async ({ browser }: { browser: Browser }) => {
  for (const lang of LANGS) {
    const ctx = await newContext(browser, lang);
    await stubTarget(ctx, TARGET, '<!doctype html><title>client</title><p>client</p>');
    const page = await ctx.newPage();
    await page.goto(loginUrl(TARGET + '?secret=q1#frag1'), { waitUntil: 'domcontentloaded' });
    await signInAtDexAsAlex(page);
    await expect(page.locator('main[data-page="sso-confirm"][data-result="pending"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
    const csrf = await page.locator('input[name="csrf_token"]').first().getAttribute('value');
    expect(csrf).toBeTruthy();

    const record = async (name: string, r: { status(): number; headers(): Record<string, string>; text(): Promise<string> }) =>
      seen.push({ lang, name, status: r.status(), headers: r.headers(), body: await r.text() });

    // forbidden: a wrong CSRF token (nothing is consumed), invalid_request: an unknown decision (nothing is consumed)
    const post = (form: Record<string, string>) =>
      ctx.request.post(`${NEBU_BASE_URL}${CONFIRM_PATH}`, { form, headers: NAV_HEADERS, maxRedirects: 0 });
    await record('forbidden', await post({ csrf_token: 'wrong-csrf-value', decision: 'continue' }));
    await record('invalid_request', await post({ csrf_token: csrf!, decision: 'bogus-decision' }));

    // cancelled: the real Cancel button, then the entry is gone: invalid_state
    const cancelResponse = page.waitForResponse((r) => new URL(r.url()).pathname === CONFIRM_PATH && r.request().method() === 'POST');
    await page.locator('button[name="decision"][value="cancel"]').click();
    await record('cancelled', await cancelResponse);
    await record('invalid_state', await ctx.request.get(`${NEBU_BASE_URL}${CONFIRM_PATH}`, { maxRedirects: 0 }));
  }
});

Then(
  lit(
    'each uses the shell and the browser language, keeps data-page "sso-confirm" / "sso-confirm-error" with its data-result / data-error, renders no request value, and keeps its headers and status',
  ),
  async () => {
    const expected: Record<string, { status: number; attrs: string[] }> = {
      cancelled: { status: 200, attrs: ['data-page="sso-confirm"', 'data-result="cancelled"'] },
      forbidden: { status: 403, attrs: ['data-page="sso-confirm-error"', 'data-error="forbidden"'] },
      invalid_request: { status: 400, attrs: ['data-page="sso-confirm-error"', 'data-error="invalid_request"'] },
      invalid_state: { status: 400, attrs: ['data-page="sso-confirm-error"', 'data-error="invalid_state"'] },
    };
    expect(seen).toHaveLength(LANGS.length * Object.keys(expected).length);
    for (const s of seen) {
      const where = `[${s.lang.code} ${s.name}]`;
      const e = expected[s.name];
      expect(s.status, `${where} status`).toBe(e.status);
      expect(htmlLang(s.body), `${where} browser language`).toBe(s.lang.code);
      expect(s.body, `${where} shell`).toContain('class="shell"');
      expect(s.body, `${where} logo`).toContain('class="logo"');
      for (const a of e.attrs) expect(s.body, `${where} ${a}`).toContain(a);
      expect(s.body.match(/<h1[\s>]/g) ?? [], `${where} one h1`).toHaveLength(1);
      expect(s.body, `${where} no script`).not.toMatch(/<script[\s>]/);
      for (const leaked of ['wrong-csrf-value', 'secret', 'q1', 'frag1', 'sso-confirm-04.e2e.example']) {
        expect(s.body, `${where} renders no request value (${leaked})`).not.toContain(leaked);
      }
      expect(s.headers['cache-control'], `${where} cache-control`).toBe('no-store');
      expect(s.headers['pragma']).toBe('no-cache');
      expect(s.headers['x-frame-options']).toBe('DENY');
      expect(s.headers['cross-origin-opener-policy'], `${where} no COOP`).toBeUndefined();
      expect(s.headers['content-security-policy'], `${where} csp`).toMatch(/style-src 'sha256-[^']+'/);
      expect(s.headers['content-security-policy']).not.toContain('script-src');
    }
    // German and English differ in the heading of every page
    for (const name of Object.keys(expected)) {
      const h1 = (l: string) => /<h1[^>]*>([^<]*)<\/h1>/.exec(seen.find((s) => s.name === name && s.lang.code === l)!.body)?.[1];
      expect(h1('de'), `${name}: German heading differs from English`).not.toBe(h1('en'));
    }
  },
);

// ─── Scenario 3 and 4: the UIA SSO fallback result pages ───────────────────────

/** A pending UIA session bound to `boundUser`, opened by a stub client page through window.open, Dex sign-in as alex in the popup. */
async function runUiaFallback(browser: Browser, boundUser: string): Promise<void> {
  const lang = LANGS[0]; // German: proves the browser language
  const sessionId = `e2e04${randomBytes(8).toString('hex')}`;
  insertUiaSession(sessionId, boundUser);
  uiaSessions.push(sessionId);

  const ctx = await newContext(browser, lang);
  // the Matrix client's side: onAuthDone is defined on every page of the context; the opener records the "authDone" message
  await ctx.addInitScript(() => {
    (window as unknown as { onAuthDone: () => void }).onAuthDone = () => {
      const w = window as unknown as { __onAuthDoneCalls?: number };
      w.__onAuthDoneCalls = (w.__onAuthDoneCalls ?? 0) + 1;
    };
  });
  await stubTarget(
    ctx,
    OPENER_ORIGIN,
    '<!doctype html><html><head><title>opener</title></head><body data-auth-done="none"><p>client</p>' +
      '<script>window.addEventListener("message", function (e) { document.body.setAttribute("data-auth-done", String(e.data)); });</script></body></html>',
  );
  const opener = await ctx.newPage();
  await opener.goto(OPENER_ORIGIN + '/', { waitUntil: 'domcontentloaded' });

  const url = `${NEBU_BASE_URL}${UIA_FALLBACK_PATH}?session=${encodeURIComponent(sessionId)}`;
  const [popup] = await Promise.all([ctx.waitForEvent('page'), opener.evaluate((u: string) => void window.open(u), url)]);

  const consoleCsp: string[] = [];
  popup.on('console', (m) => {
    if (/content security policy/i.test(m.text())) consoleCsp.push(m.text());
  });
  let callback: Response | null = null;
  popup.on('response', (r) => {
    if (new URL(r.url()).pathname === CALLBACK_PATH) callback = r;
  });

  await signInAtDexAsAlex(popup);
  await popup.waitForURL((u) => u.pathname === CALLBACK_PATH, { timeout: NAV_TIMEOUT_MS });
  await expect(popup.locator('main h1')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  const csp = (await (callback as Response | null)?.headerValue('content-security-policy')) ?? '';
  uiaRun = { opener, popup, callback, csp, consoleCsp };
}

Given(lit('a user who completed the UIA SSO fallback'), async () => {
  uiaRun = null;
});

When(lit('the "Authentication complete" page loads in a browser'), async ({ browser }: { browser: Browser }) => {
  await runUiaFallback(browser, NEBU_USERS.alex.matrixId);
});

Then(
  lit(
    'window.onAuthDone is called once and the opener is not messaged (the spec else-if), the page is in the shell and the language of the browser, and its CSP allows only that one script by hash',
  ),
  async () => {
    expect(uiaRun).not.toBeNull();
    const { opener, popup, callback, csp, consoleCsp } = uiaRun!;
    expect(callback!.status()).toBe(200);

    await expect(popup.locator('html')).toHaveAttribute('lang', 'de');
    await expect(popup.locator('.shell')).toBeVisible();
    await expect(popup.locator('main h1')).toHaveCount(1);

    // the spec script (bugfix matrix-uia-authdone-else-if): `if (onAuthDone) onAuthDone(); else if (opener) postMessage(...)`.
    // This client defines onAuthDone, so it is called once and the opener is NOT also messaged (one notification path).
    await expect
      .poll(() => popup.evaluate(() => (window as unknown as { __onAuthDoneCalls?: number }).__onAuthDoneCalls ?? 0), { timeout: 10_000 })
      .toBe(1);
    // postMessage delivery is asynchronous: let a message round trip settle before the negative check
    await opener.waitForTimeout(1_000);
    await expect(opener.locator('body'), 'else-if: onAuthDone is defined, so no postMessage to the opener').toHaveAttribute('data-auth-done', 'none');

    // CSP: exactly one script, allowed by its SHA-256 and nothing else
    const inline = await popup.locator('script').allTextContents();
    expect(inline, 'exactly one inline script').toHaveLength(1);
    expect(await popup.locator('script[src]').count()).toBe(0);
    const hash = createHash('sha256').update(inline[0]).digest('base64');
    const scriptSrc = /(?:^|;\s*)script-src ([^;]*)/.exec(csp)?.[1];
    expect(scriptSrc, `script-src of "${csp}"`).toBe(`'sha256-${hash}'`);
    expect(csp).toMatch(/default-src 'none'/);
    expect(csp).not.toContain('unsafe');
    expect(callback!.headers()['cache-control']).toBe('no-store');
    expect(callback!.headers()['cross-origin-opener-policy'], 'no COOP: the opener must survive').toBeUndefined();
    expect(consoleCsp, 'the browser reported no CSP violation').toEqual([]);
  },
);

When(lit('the 403 page is rendered'), async ({ browser }: { browser: Browser }) => {
  await runUiaFallback(browser, '@someone-else-e2e04:localhost');
});

Given(lit('a UIA completion whose identity does not match the pending request'), async () => {
  uiaRun = null;
});

Then(
  lit('it says in plain German or English that nothing was authorised, runs no script, keeps status 403 and no-store, and logs nothing new'),
  async () => {
    expect(uiaRun).not.toBeNull();
    const { opener, popup, callback, csp, consoleCsp } = uiaRun!;
    expect(callback!.status()).toBe(403);
    expect(callback!.headers()['cache-control']).toBe('no-store');
    await expect(popup.locator('html')).toHaveAttribute('lang', 'de');
    await expect(popup.locator('.shell')).toBeVisible();
    await expect(popup.locator('main')).toContainText(/nicht autorisiert|nichts autorisiert|nicht genehmigt/i);
    expect(await popup.locator('script').count(), 'the refusal runs no script').toBe(0);
    expect(csp).not.toContain('script-src');
    expect(await popup.evaluate(() => (window as unknown as { __onAuthDoneCalls?: number }).__onAuthDoneCalls ?? 0)).toBe(0);
    await expect(opener.locator('body'), 'the opener was told nothing').toHaveAttribute('data-auth-done', 'none');
    expect(consoleCsp).toEqual([]);
    // "logs nothing new" has no black-box handle: it is pinned by the ExUnit test (capture_log on the page renderer).
  },
);

// ─── Scenario 5: the unsupported-login page ────────────────────────────────────

Given(lit('an app whose redirect scheme "<script>alert(1)</script>" is not allowed'), async () => {
  unsupportedPage = null;
});

When(lit('render_html_error/1 is rendered'), async ({ browser }: { browser: Browser }) => {
  // The browser cannot carry "<script>..." as a URL scheme (RFC 3986), so the real redirect leg is driven with a scheme that is not allowed
  // and with the hostile string as the whole redirectUrl; the escaping of an injected string is pinned by the ExUnit test.
  const ctx = await newContext(browser, LANGS[0]);
  const page = await ctx.newPage();
  page.on('dialog', async (d) => {
    dialogs += 1;
    await d.dismiss();
  });
  const response = await page.goto(loginUrl('unknown-scheme://host'), { waitUntil: 'domcontentloaded' });
  unsupportedStatus = response!.status();
  unsupportedPage = page;
  const hostile = await ctx.newPage();
  hostile.on('dialog', async (d) => {
    dialogs += 1;
    await d.dismiss();
  });
  await hostile.goto(loginUrl('<script>alert(1)</script>://host'), { waitUntil: 'domcontentloaded' });
});

Then(
  lit('the scheme is HTML-escaped inside a code element, the page has lang, viewport, one main and one h1, and tells the user to contact the administrator'),
  async () => {
    expect(unsupportedPage).not.toBeNull();
    const page = unsupportedPage!;
    expect(unsupportedStatus).toBe(400);
    await expect(page.locator('html')).toHaveAttribute('lang', 'de');
    await expect(page.locator('meta[name="viewport"]')).toHaveCount(1);
    await expect(page.locator('main')).toHaveCount(1);
    await expect(page.locator('h1')).toHaveCount(1);
    await expect(page.locator('.shell')).toBeVisible();
    await expect(page.locator('main code')).toHaveText('unknown-scheme');
    await expect(page.locator('main')).toContainText(/Administrat/);
    expect(await page.locator('script').count(), 'no script on the page').toBe(0);
    expect(dialogs, 'no injected script ran').toBe(0);
  },
);
