/**
 * Step definitions for features/oauth/oauth-consent-grants.feature
 *
 * Story: oauth-session-and-consent / persistent-consent-grants (REQ-2026-003). Runs only against the full compose stack with the real Dex;
 * NOT executable in the isolated env (verified with `bddgen --tags "@oauth-consent-grants"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Reused, never redefined here (bddgen rejects duplicates): the whole authorize / client / consent side comes from oauth-authorize.steps.ts
 * ("OAuth is enabled with an https issuer", the named web client, "the browser opens the authorize URL of {string} with response_mode {string} and
 * device {string}", "the user signs in at the IdP", "the consent page is shown", "the user allows the app", "the client receives the redirect at {string}",
 * "the redirect query has a {string}", "the redirect query has the request's {string}"); the generic account page assertions come from
 * oauth-account-management.steps.ts ("the account page shows the notice {string}", "the page has exactly one level-1 heading", the axe and 320 px steps).
 * Step files share no module state, so this file keeps its own (the recorded page loads, the prior issuer) and its own Dex sign-in for the account page.
 *
 * Page contract of the new account page (shared with server/test/nebu/oauth/consent_grant_account_test.exs):
 *   <main data-page="account" data-action="apps">, rows `[data-role="consent-grant"][data-client-id=...]` that show the app name as claimed by the app,
 *   a form per row with the button `[data-role="withdraw-grant"]`, the empty state `[data-role="no-grants"]`, the notice `[data-notice="grant_withdrawn"]`.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  clearOAuthClientsByIdPrefix,
  clearOAuthConsentRequestsByClientPrefix,
  clearOAuthConsentGrantsByClientPrefix,
  clearOAuthSessionsByClientPrefix,
  countOAuthConsentGrants,
} from '../../fixtures/db';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const CLIENT_PREFIX = 'e2e-oauth-grants-';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const CONSENT_PATH = '/oauth2/consent';
const APPS_PATH = '/account/apps';

// Scenario-scoped state (reset in the Before hook).
let priorIssuer: string | null = null;
let recordedPaths: string[] = [];
let recordedPages = new WeakSet<Page>();

// ─── Hooks ─────────────────────────────────────────────────────────────────────

// Captured BEFORE the Background's "OAuth is enabled with an https issuer" changes it. A grant left behind by an earlier run would make the first
// login skip the consent screen: every scenario starts without one.
Before({ tags: '@oauth-consent-grants' }, async () => {
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  recordedPaths = [];
  recordedPages = new WeakSet<Page>();
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
});

// Never leave OAuth switched on, the issuer changed, grants, consent rows, sessions or fixture clients behind. Order: sessions (matrix_sessions.client_id
// is ON DELETE RESTRICT), grants and consent rows, then the clients. Failures are NOT swallowed (see fixtures/db.ts).
After({ tags: '@oauth-consent-grants' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
});

// ─── The state of the database ─────────────────────────────────────────────────

Given('the test user has no consent grant for {string}', async ({}, clientId: string) => {
  expect(countOAuthConsentGrants(clientId), `a grant of ${clientId} exists although the scenario starts without one`).toBe(0);
});

// Polled: the grant is written (or deleted) by the server right after the browser's last navigation, so a one-shot read could race a late write.
Then('no consent grant exists for {string}', async ({}, clientId: string) => {
  await expect.poll(() => countOAuthConsentGrants(clientId), { message: `a grant of ${clientId} exists although none should`, timeout: 10_000 }).toBe(0);
});

Then('a consent grant exists for {string}', async ({}, clientId: string) => {
  await expect.poll(() => countOAuthConsentGrants(clientId), { message: `Allow remembered the decision for ${clientId}`, timeout: 10_000 }).toBe(1);
});

// ─── The consent screen did (not) appear ───────────────────────────────────────

/** From now on every top-level navigation of the page is recorded (the consent page of an earlier Allow is not counted). */
When('the browser starts recording the pages it loads', async ({ page }: { page: Page }) => {
  recordedPaths = [];
  if (recordedPages.has(page)) return;
  recordedPages.add(page);
  page.on('framenavigated', (frame) => {
    if (frame === page.mainFrame()) recordedPaths.push(new URL(frame.url()).pathname);
  });
});

Then('the browser did not load the consent page since the recording started', async ({ page }: { page: Page }) => {
  expect(recordedPaths.length, 'the recording saw the navigations of the second authorization').toBeGreaterThan(0);
  expect(recordedPaths, 'the consent screen was skipped: no navigation to it').not.toContain(CONSENT_PATH);
  await expect(page.locator('main[data-page="oauth-consent"]')).toHaveCount(0);
});

// ─── The account page: allowed apps ────────────────────────────────────────────

async function dexLogin(page: Page): Promise<void> {
  await page.waitForURL(/^https?:\/\/[^/]+\/dex\/auth(\/|\?|$)/i, { timeout: NAV_TIMEOUT_MS });
  const login = page.locator('input[name="login"]');
  await expect(login, 'Dex login form').toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await login.fill(NEBU_USERS.alex.email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  // Dex's own grant screen (first login per client only); acts ONLY on /dex/approval: its name regex would also match Nebu's consent "Allow"
  const branch = await Promise.race([
    page.waitForURL((url) => url.pathname.includes('/dex/approval'), { timeout: 6_000 }).then(() => 'approval' as const),
    page.waitForURL((url) => !/^\/dex(\/|$)/i.test(url.pathname), { timeout: 6_000 }).then(() => 'left-dex' as const),
  ]).catch(() => 'none' as const);
  if (branch === 'approval') await page.getByRole('button', { name: /^(grant access|approve|confirm)$/i }).click();
}

/** Opens the page; the account sign-in (a fresh Dex login: prompt=login) comes first when the browser has no account session. */
When('the user opens the list of allowed apps on the account page', async ({ page }: { page: Page }) => {
  await page.goto(`${NEBU_BASE_URL}${APPS_PATH}`, { waitUntil: 'domcontentloaded' });

  // without an account session the request is answered with a 302 to the IdP: goto() has followed it
  if (/^\/dex\//i.test(new URL(page.url()).pathname)) {
    await dexLogin(page);
    await page.waitForURL((url) => url.pathname.startsWith('/account'), { timeout: NAV_TIMEOUT_MS });
    // the sign-in lands on the default account page: open the list itself
    await page.goto(`${NEBU_BASE_URL}${APPS_PATH}`, { waitUntil: 'domcontentloaded' });
  }

  await expect(page.locator('main[data-page="account"][data-action="apps"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
});

function grantRow(page: Page, appName: string) {
  return page.locator('[data-role="consent-grant"]').filter({ hasText: appName });
}

Then('the list of allowed apps contains {string}', async ({ page }: { page: Page }, appName: string) => {
  await expect(grantRow(page, appName)).toHaveCount(1);
  await expect(grantRow(page, appName).locator('[data-role="withdraw-grant"]')).toBeVisible();
});

Then('the list of allowed apps does not contain {string}', async ({ page }: { page: Page }, appName: string) => {
  await expect(page.locator('main[data-page="account"][data-action="apps"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(grantRow(page, appName)).toHaveCount(0);
  await expect(page.locator('[data-role="no-grants"]')).toBeVisible();
});

/** `Withdraw the permission of <name> (<host>)`: the accessible name of the button of one app (UX review MINOR 1). */
function withdrawButton(page: Page, appName: string) {
  const escaped = appName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return page.getByRole('button', { name: new RegExp(`^Withdraw the permission of ${escaped} \\(`) });
}

When('the user withdraws {string} from the list of allowed apps', async ({ page }: { page: Page }, appName: string) => {
  // by role and accessible name, as a screen reader user finds it (not by a test hook)
  await withdrawButton(page, appName).click();
  await page.waitForLoadState('domcontentloaded');
});

Then('the Withdraw button of {string} is found by its accessible name', async ({ page }: { page: Page }, appName: string) => {
  await expect(withdrawButton(page, appName)).toHaveCount(1);
  await expect(withdrawButton(page, appName)).toBeVisible();
});

Then('the page title and heading read {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(page).toHaveTitle(text);
  await expect(page.locator('h1')).toHaveText(text);
});

Then('the navigation marks {string} as the current page', async ({ page }: { page: Page }, label: string) => {
  await expect(page.locator('nav[aria-label="Account"] a[aria-current="page"]')).toHaveText(label);
});

Then('the notice is announced as a status', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-role="notice"][role="status"]')).toBeVisible();
});

Then('the explanation says that signed-in devices stay signed in and links to Devices', async ({ page }: { page: Page }) => {
  const note = page.locator('[data-role="grants-note"]');
  await expect(note).toContainText('does not sign out devices that are already signed in');
  await expect(note.locator('a[href="/account?action=org.matrix.devices_list"]')).toHaveText('Devices');
});

Then('the empty state says {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(page.locator('[data-role="no-grants"]')).toHaveText(text);
});
