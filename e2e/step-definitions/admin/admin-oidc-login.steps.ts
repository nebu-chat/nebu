/**
 * Step definitions for the go-removal-cleanup story — Elixir admin OIDC login.
 *
 * Feature: features/admin/admin-oidc-login.feature
 *
 * Exercises the real Authorization-Code + PKCE flow against the live Dex stack
 * (NO cookie forging, NO DB seeding — CLAUDE.md UI standard). The login is now
 * served entirely by the Elixir admin (NebuHttp.Admin.Auth + LoginController):
 *   GET /admin/login/start  → 302 to Dex with code_challenge (S256), state, nonce
 *   GET /admin/callback     → state check, token exchange, ID-token verify (+nonce),
 *                             admin-claim gate, Phoenix admin session mint
 *
 * REUSE (NOT redefined here — Cucumber errors on duplicates):
 *   - "the Nebu stack is running"    → common/stack-health.steps.ts
 *   - "bootstrap has been completed" → admin/bootstrap.steps.ts
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { DEX_TEST_PASSWORD } from '../../fixtures/users';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const ADMIN_EMAIL = process.env.NEBU_ADMIN_EMAIL ?? 'kai@example.com';
const NON_ADMIN_EMAIL = process.env.NEBU_NON_ADMIN_EMAIL ?? 'alex@example.com';

// Captured authorization-request URL so the PKCE/state/nonce scenario can assert on it.
let lastAuthorizeUrl = '';

Given('the operator is not logged in to the admin UI', async ({ page }: { page: Page }) => {
  await page.context().clearCookies();
});

When('the operator starts the admin SSO login', async ({ page }: { page: Page }) => {
  // Capture the redirect to Dex (the authorization request) before following it.
  lastAuthorizeUrl = '';
  page.on('request', (req) => {
    const u = req.url();
    if (u.includes('/auth') && u.includes('response_type=code')) {
      lastAuthorizeUrl = u;
    }
  });
  await page.goto(`${ADMIN_BASE_URL}/admin/login/start`);
  await page.waitForLoadState('domcontentloaded');
});

Then(
  'the browser is redirected to the Dex login page for the admin flow',
  async ({ page }: { page: Page }) => {
    // Dex serves the login form at /dex/auth/... with a "login" + "password" field.
    await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  }
);

Then(
  'the Dex authorization request includes a PKCE S256 challenge, a state and a nonce',
  async () => {
    expect(lastAuthorizeUrl, 'authorization request URL was captured').not.toEqual('');
    const url = new URL(lastAuthorizeUrl);
    expect(url.searchParams.get('code_challenge_method')).toEqual('S256');
    expect((url.searchParams.get('code_challenge') ?? '').length).toBeGreaterThan(20);
    expect((url.searchParams.get('state') ?? '').length).toBeGreaterThan(8);
    expect((url.searchParams.get('nonce') ?? '').length).toBeGreaterThan(8);
  }
);

async function authenticateAtDex(page: Page, email: string) {
  await page.locator('input[name="login"]').fill(email);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"], #submit-login').first().click();
  // Dex may show a consent screen on first login.
  const grant = page.locator('button:has-text("Grant Access"), button[type="submit"]');
  if (await grant.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
    await grant.first().click().catch(() => {});
  }
  await page.waitForLoadState('networkidle');
}

When('the operator authenticates at Dex as the admin user', async ({ page }: { page: Page }) => {
  await authenticateAtDex(page, ADMIN_EMAIL);
});

When('the operator authenticates at Dex as a non-admin user', async ({ page }: { page: Page }) => {
  await authenticateAtDex(page, NON_ADMIN_EMAIL);
});

Then('the operator lands in the Phoenix LiveView admin area', async ({ page }: { page: Page }) => {
  await expect(page).toHaveURL(/\/admin\/(rooms|users|dashboard)/, { timeout: 15_000 });
  const liveRoot = page.locator('[data-phx-main], [data-phx-session], [id^="phx-"]');
  await expect(liveRoot.first()).toBeAttached({ timeout: 15_000 });
});

Then('the admin session cookie is set', async ({ page }: { page: Page }) => {
  const cookies = await page.context().cookies();
  expect(cookies.some((c) => c.name === '_nebu_admin_key')).toBeTruthy();
});

Then(
  'the admin login is rejected with a forbidden response or redirected back to the admin login',
  async ({ page }: { page: Page }) => {
    // A non-admin must not reach the admin area: either a 403 page or a bounce to login.
    await expect(page).not.toHaveURL(/\/admin\/(rooms|users|dashboard)/, { timeout: 10_000 });
  }
);

When(
  'a forged admin callback with an invalid state is requested',
  async ({ page }: { page: Page }) => {
    // No login-start was performed, so there is no stored state in the session — and
    // even if there were, this state value cannot match.
    // (playwright-bdd steps have no `this` World — navigate directly; the Then step
    // asserts on page.url(), so no response handle needs to be stored.)
    await page.goto(
      `${ADMIN_BASE_URL}/admin/callback?code=forged-code&state=forged-state-value`
    );
  }
);

Then('the admin callback is rejected as a bad request', async ({ page }: { page: Page }) => {
  // Acceptable rejections: a redirect to the login/error page, OR a 4xx error page
  // rendered in place. The callback fail-closes a forged/mismatched state with
  // HTTP 400 "Invalid login state" at /admin/callback (it does NOT bounce to /login),
  // so also accept a rejection message in the body. What must NOT happen is reaching an
  // authenticated admin view.
  const url = page.url();
  const body = (await page.locator('body').innerText().catch(() => '')) ?? '';
  const redirectedToLoginOrError = /\/admin\/login/.test(url) || /error/.test(url);
  const showsRejection = /invalid login state|bad request|forbidden|invalid|not authorized|denied/i.test(body);
  const onAdminContent = /\/admin\/(?:dashboard|rooms|users|config|compliance|audit)\b/.test(url);
  expect(
    (redirectedToLoginOrError || showsRejection) && !onAdminContent,
    `forged callback must be rejected (url=${url}, body="${body.slice(0, 80)}")`,
  ).toBeTruthy();
});
