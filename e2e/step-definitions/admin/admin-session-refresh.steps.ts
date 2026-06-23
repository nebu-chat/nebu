/**
 * Step definitions for the admin-oidc-session-refresh story (AC4 e2e) and the shared
 * admin-login step reused by oidc-refresh-mode.steps.ts.
 *
 * Feature: features/admin/admin-session-refresh.feature
 *
 * Proves the operator stays authenticated past a short OIDC/Nebu session lifetime by
 * driving the REAL Authorization-Code + PKCE flow against the live Dex IdP (NO cookie
 * forging, NO DB seeding — CLAUDE.md UI standard) and then navigating the Admin UI across
 * that lifetime so the silent pre-expiry refresh in Nebu.Admin.Auth.fetch_current_user/2
 * kicks in.
 *
 * @short-ttl: the timing scenarios run ONLY via `make test-e2e-refresh`, which starts the
 * stack with a short NEBU_ADMIN_SESSION_TTL_SECONDS and sets admin_oidc_refresh_mode=offline
 * (Dex issues a refresh token only with offline_access). They are excluded from the default
 * run (playwright.config.ts E2E_TAGS) because the shared stack caps sessions at 8h.
 *
 * REUSE (NOT redefined here — Cucumber errors on duplicate step text):
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

// The Nebu admin session TTL (seconds) the stack is started with for the @short-ttl run
// (make test-e2e-refresh wires NEBU_ADMIN_SESSION_TTL_SECONDS into the server AND exports
// it here). The wait below derives from THIS one knob — not a decoupled constant — so the
// test waits exactly long enough for the silent refresh window to open.
const ADMIN_SESSION_TTL_SECONDS = Number(process.env.NEBU_ADMIN_SESSION_TTL_SECONDS ?? '30');
// Small buffer past the TTL so the next round-trip is firmly inside the refresh window.
const WAIT_BUFFER_MS = 5_000;

const AUTHED_ADMIN_URL = /\/admin\/(rooms|users|dashboard|config|compliance|audit)/;

/**
 * Perform a real Authorization-Code + PKCE admin login against Dex and land in the admin
 * area. Mirrors admin/bootstrap.steps.ts "the operator is logged in as admin" but is the
 * canonical "logged in to the admin UI" step shared with the refresh-mode suite. No cookie
 * forging, no DB seeding — the full browser flow only.
 */
async function loginAdminViaDex(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/login/start`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});

  // Already authenticated (e.g. a prior step logged in within this context).
  if (AUTHED_ADMIN_URL.test(page.url())) return;

  // Land on the Dex login form (login/start 302s straight to Dex when OIDC is configured).
  if (!/dex.*\/auth/i.test(page.url())) {
    // Some states render an interstitial /admin/login with an SSO button.
    if (page.url().includes('/admin/login')) {
      const sso = page.getByRole('link', { name: /login with sso|sign in with sso/i })
        .or(page.getByRole('button', { name: /login with sso|sign in with sso/i }));
      await sso.first().click().catch(() => {});
    }
    await page.waitForURL(/dex.*\/auth/i, { timeout: 15_000 });
  }

  await page.locator('input[name="login"]').fill(ADMIN_EMAIL);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"], #submit-login').first().click();

  // Dex consent screen on first login per client.
  const grant = page.getByRole('button', { name: /grant access|allow|approve|confirm/i });
  if (await grant.first().isVisible({ timeout: 6_000 }).catch(() => false)) {
    await grant.first().click().catch(() => {});
  }

  await page.waitForURL(AUTHED_ADMIN_URL, { timeout: 20_000 });
  await expect(page).toHaveURL(AUTHED_ADMIN_URL, { timeout: 5_000 });
}

Given('the admin OIDC client has a short access-token lifetime', async () => {
  // Precondition wired by `make test-e2e-refresh` (NEBU_ADMIN_SESSION_TTL_SECONDS short +
  // admin_oidc_refresh_mode=offline so Dex issues a refresh token). Fail loud if the suite
  // was launched without a short TTL — otherwise the timing scenario would wait ~8h.
  expect(
    ADMIN_SESSION_TTL_SECONDS,
    'NEBU_ADMIN_SESSION_TTL_SECONDS must be short (run via `make test-e2e-refresh`)',
  ).toBeLessThanOrEqual(120);
});

Given('the operator is logged in to the admin UI', async ({ page }: { page: Page }) => {
  await loginAdminViaDex(page);
});

When('the access-token lifetime elapses', async () => {
  // Wait just past the configured Nebu admin session TTL so the next HTTP round-trip falls
  // inside Nebu.Admin.Auth's pre-expiry silent-refresh window.
  await new Promise<void>((resolve) =>
    setTimeout(resolve, ADMIN_SESSION_TTL_SECONDS * 1_000 + WAIT_BUFFER_MS),
  );
});

When('the operator navigates the Admin UI', async ({ page }: { page: Page }) => {
  // A dead render / full page load → fetch_current_user/2 runs and silently refreshes the
  // session (cookies can't be set over the LiveView websocket, so navigate, don't patch).
  await page.goto(`${ADMIN_BASE_URL}/admin/users`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
});

When(
  'the operator navigates the Admin UI repeatedly across several access-token lifetimes',
  async ({ page }: { page: Page }) => {
    // Three lifetimes, each followed by a navigation → proves repeated silent refresh.
    const pages = ['/admin/rooms', '/admin/users', '/admin/dashboard'];
    for (let i = 0; i < pages.length; i++) {
      await new Promise<void>((resolve) =>
        setTimeout(resolve, ADMIN_SESSION_TTL_SECONDS * 1_000 + WAIT_BUFFER_MS),
      );
      await page.goto(`${ADMIN_BASE_URL}${pages[i]}`);
      await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
      // Must still be authenticated after each lifetime, not bounced to login.
      await expect(page, `still authenticated after lifetime ${i + 1}`).not.toHaveURL(
        /\/admin\/login/,
        { timeout: 5_000 },
      );
    }
  },
);

Then(
  'the operator is still authenticated in the admin area',
  async ({ page }: { page: Page }) => {
    await expect(page).toHaveURL(AUTHED_ADMIN_URL, { timeout: 15_000 });
    const liveRoot = page.locator('[data-phx-main], [data-phx-session], [id^="phx-"]');
    await expect(liveRoot.first()).toBeAttached({ timeout: 15_000 });
  },
);

Then(
  'the operator was not redirected to the admin login page',
  async ({ page }: { page: Page }) => {
    await expect(page).not.toHaveURL(/\/admin\/login/, { timeout: 5_000 });
  },
);
