/**
 * Step definitions for features/oauth/01-device-naming-chain.feature
 *
 * Story: oauth-pages-redesign / 01-device-naming-chain (REQ-2026-016). Runs only against the full compose stack with the real Dex;
 * NOT executable in the isolated env (verified with `bddgen --tags "@oauth-device-naming-chain"` + `tsc --noEmit` where node_modules exist).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Reused, never redefined here (bddgen rejects duplicates): "OAuth is enabled with an https issuer", "an approved web client {string} named {string}
 * with client URI {string} and redirect URI {string}", "the browser opens the authorize URL of {string} with response_mode {string} and device {string}",
 * "the user signs in at the IdP", "the consent page is shown", "the user allows the app", "the client receives the redirect at {string}",
 * "the client exchanges the code" (oauth-authorize.steps.ts), "a consent grant exists for {string}", "the browser starts recording the pages it loads",
 * "the browser did not load the consent page since the recording started" (oauth-consent-grants.steps.ts).
 *
 * Page contract (shared with server/test/nebu/oauth/device_naming_chain_test.exs): the consent page shows the name that WILL be given in ONE line
 * `[data-role="device-name"]`; when nothing can be derived it carries a required text input `name="device_name"` (maxlength 64, with a <label>).
 * Step files share no module state, so the Allow arming / issuer-origin helper below is a copy of the one in oauth-authorize.steps.ts.
 */

import { When, Then, Before, After } from '../../fixtures/nebu-fixtures';
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
  countDevicesById,
  queryDeviceDisplayName,
} from '../../fixtures/db';
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';

const CLIENT_PREFIX = 'e2e-oauth-devname-';
const CONSENT_PATH = '/oauth2/consent';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);

let priorIssuer: string | null = null;

// ─── Hooks ─────────────────────────────────────────────────────────────────────

// Captured BEFORE the Background's "OAuth is enabled with an https issuer" changes it. A grant left behind by an earlier run would make a first login skip
// the consent screen: every scenario starts without one.
Before({ tags: '@oauth-device-naming-chain' }, async () => {
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
});

// Order: sessions + their devices (matrix_sessions.client_id is ON DELETE RESTRICT), grants and consent rows, then the clients. Failures are NOT swallowed.
After({ tags: '@oauth-device-naming-chain' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthSessionsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentGrantsByClientPrefix(CLIENT_PREFIX);
  clearOAuthConsentRequestsByClientPrefix(CLIENT_PREFIX);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
});

// ─── helpers ───────────────────────────────────────────────────────────────────

/** `\uXXXX` escapes of a Gherkin text become the characters (a feature file cannot carry an invisible control character readably). */
function decode(text: string): string {
  return text.replace(/\\u([0-9a-fA-F]{4})/g, (_m, hex: string) => String.fromCharCode(parseInt(hex, 16)));
}

function nameInput(page: Page) {
  return page.locator('main[data-page="oauth-consent"] input[name="device_name"]');
}

/** The POST of the consent form carries the issuer origin (the e2e issuer is a fake https URL), as in oauth-authorize.steps.ts. */
async function useIssuerOriginForConsent(page: Page): Promise<void> {
  await page.route(`**${CONSENT_PATH}`, (route) => {
    if (route.request().method() !== 'POST') return route.continue();
    return route.continue({ headers: { ...route.request().headers(), origin: new URL(E2E_ISSUER).origin } });
  });
}

/** Allow is armed by real pointer movement (see armAllow in oauth-authorize.steps.ts), then hovered. */
async function armAllow(page: Page): Promise<void> {
  const allow = page.locator('button[name="decision"][value="allow"]');
  await page.mouse.move(40, 40);
  await page.mouse.move(90, 110, { steps: 6 });
  await expect(allow, 'Allow is armed by real pointer movement').not.toHaveAttribute('aria-disabled', 'true', { timeout: 10_000 });
  await page.mouse.move(4, 4);
  await allow.hover();
}

// ─── The consent page: the name that will be given ─────────────────────────────

Then('the consent page shows the device name {string}', async ({ page }: { page: Page }, name: string) => {
  await expect(page.locator('main[data-page="oauth-consent"] [data-role="device-name"]')).toContainText(name);
});

/** A name made of the host plus the last 8 characters of the device id: `host (suffix)`. */
Then(
  'the consent page shows the device name {string} followed by the last 8 characters of the device id in brackets',
  async ({ page }: { page: Page }, base: string) => {
    const escaped = base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    await expect(page.locator('main[data-page="oauth-consent"] [data-role="device-name"]')).toContainText(
      new RegExp(`${escaped} \\([A-Za-z0-9._-]{1,8}\\)`),
    );
  },
);

Then('the consent page does not ask for a device name', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(nameInput(page)).toHaveCount(0);
});

Then('the consent page asks for a device name', async ({ page }: { page: Page }) => {
  const input = nameInput(page);
  await expect(input).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(input, 'the name is required').toHaveAttribute('required', /.*/);
  await expect(input, 'the name is bounded to 64 characters').toHaveAttribute('maxlength', '64');
  const labels = await input.evaluate((el) => (el as HTMLInputElement).labels?.length ?? 0);
  expect(labels, 'the name input has a visible <label>').toBeGreaterThan(0);
});

// ─── The user's input ──────────────────────────────────────────────────────────

When('the user types the device name {string}', async ({ page }: { page: Page }, name: string) => {
  await nameInput(page).fill(decode(name));
});

/**
 * Allow with a (possibly empty / invisible) name: the page must come back (nothing is redirected), so this does not wait for the client redirect that
 * "the user allows the app" waits for.
 */
When('the user presses Allow with the device name {string}', async ({ page }: { page: Page }, name: string) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await useIssuerOriginForConsent(page);
  await nameInput(page).fill(decode(name));
  await armAllow(page);
  await Promise.all([
    page.waitForResponse((r) => new URL(r.url()).pathname === CONSENT_PATH && r.request().method() === 'POST', { timeout: NAV_TIMEOUT_MS }),
    page.locator('button[name="decision"][value="allow"]').click(),
  ]);
  await page.waitForLoadState('domcontentloaded');
});

Then('the consent page is shown again asking for a device name', async ({ page }: { page: Page }) => {
  await expect(page.locator('main[data-page="oauth-consent"]')).toBeVisible({ timeout: NAV_TIMEOUT_MS });
  await expect(nameInput(page)).toBeVisible();
  expect(new URL(page.url()).pathname, 'the browser stays at Nebu, not at the client').toBe(CONSENT_PATH);
});

// ─── The device rows ───────────────────────────────────────────────────────────

Then('the device {string} does not exist', async ({}, deviceId: string) => {
  expect(countDevicesById(deviceId), `the device ${deviceId} exists although nothing may be created yet`).toBe(0);
});

// Polled: the device is written by the token endpoint right after the client's code exchange.
Then('the device {string} has the display name {string}', async ({}, deviceId: string, name: string) => {
  await expect
    .poll(() => queryDeviceDisplayName(deviceId), { message: `display name of ${deviceId}`, timeout: 10_000 })
    .toBe(decode(name));
});
