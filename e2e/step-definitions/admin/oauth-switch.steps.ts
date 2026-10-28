/**
 * Step definitions for features/admin/oauth-switch.feature
 *
 * Story: oauth-broker / admin-oauth-switch (AC1-AC4, AC6) — ATDD steps (written before the implementation; they run only
 * against the full compose stack with the real Dex and are NOT executable in the isolated environment: verified with
 * `bddgen --tags "@oauth-switch"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project.
 *
 * Page contract (shared with server/test/nebu/admin/config_oauth_switch_test.exs): section `#oauth-switch`, form
 * `#oauth-switch-form`, checkbox `input[name="oauth_enabled"][type="checkbox"]` (label "Offer the OAuth 2.0 API"), the text
 * field `#oauth-issuer-input` (label "Issuer URL"), the checkbox `#oauth-ack-input` (label "I have read the activation
 * checklist ..."), the button "Save OAuth settings" (described by the fresh sign-in hint), the status list `ul#oauth-status`
 * (items `li[data-status-id][data-level]`, each starting with OK / Attention / Note), the paragraph `#oauth-not-checked`, the
 * errors `p#oauth-issuer-error` / `p#oauth-ack-error` (role="alert").
 *
 * Every save goes through the fresh sign-in (Dex) like the other /admin/config trust forms: the POST is answered with a
 * redirect to /admin/login/start?mode=reauth, the operator signs in again, comes back to /admin/config (rendered anew) and
 * re-enters the typed values (the POST is never replayed). The step 'the {string} button is described by the fresh sign-in hint'
 * is reused from sso-redirect-origins.steps.ts (bddgen rejects duplicates).
 */

import { When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { CONFIG_PATH, isDexAuth, signInAtDexAsAdmin } from '../../fixtures/oauth-admin';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const FORM = '#oauth-switch-form';
const ENABLED = `${FORM} input[type="checkbox"][name="oauth_enabled"]`;
const ISSUER = `${FORM} input[name="oauth_issuer_url"]`;
const ACK = `${FORM} input[name="oauth_activation_ack"]`;

type Typed = { enabled: boolean; issuer: string; ack: boolean };
let lastTyped: Typed = { enabled: false, issuer: '', ack: false };

async function setField(page: Page, typed: Typed): Promise<void> {
  lastTyped = typed;
  await expect(page.locator(FORM)).toBeVisible({ timeout: 10_000 });
  await page.locator(ISSUER).fill(typed.issuer);
  await page.locator(ENABLED).setChecked(typed.enabled);
  await page.locator(ACK).setChecked(typed.ack);
}

/** Press "Save OAuth settings"; when the server asks for a fresh sign-in, sign in at Dex and re-enter the typed values. */
async function saveWithAdminReauth(page: Page): Promise<void> {
  const press = async () => {
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'POST' && new URL(r.url()).pathname === '/admin/config/oauth-switch', {
        timeout: NAV_TIMEOUT_MS,
      }),
      page.locator(FORM).getByRole('button', { name: 'Save OAuth settings', exact: true }).click(),
    ]);
    return response;
  };

  let response = await press();
  if ([302, 303].includes(response.status()) && (response.headers()['location'] ?? '').startsWith('/admin/login/start')) {
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await setField(page, lastTyped);
    response = await press();
  }
  expect(response.status(), 'the save is answered by a redirect (saved) or the 200 re-render of a rejected value, never a refusal').not.toBe(403);
  if ([302, 303].includes(response.status())) {
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await expect(page.locator(FORM)).toBeVisible({ timeout: 15_000 });
  } else {
    await page.waitForLoadState('load');
  }
}

// Never leave OAuth switched on or an issuer behind: the same form switches it off and clears the issuer.
After({ tags: '@oauth-switch' }, async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}${CONFIG_PATH}`, { waitUntil: 'domcontentloaded' });
  await setField(page, { enabled: false, issuer: '', ack: false });
  await saveWithAdminReauth(page);
});

Then(
  'the OAuth section shows the "Offer the OAuth 2.0 API" checkbox, the "Issuer URL" field and the "Save OAuth settings" button',
  async ({ page }: { page: Page }) => {
    await expect(page.locator('section#oauth-switch')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole('heading', { name: 'OAuth 2.0 authorization server' })).toBeVisible();
    await expect(page.getByLabel('Offer the OAuth 2.0 API')).toBeVisible();
    await expect(page.getByLabel('Issuer URL')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Save OAuth settings', exact: true })).toBeVisible();
  },
);

Then('the OAuth status list shows only items that start with a status word', async ({ page }: { page: Page }) => {
  const items = page.locator('ul#oauth-status li[data-status-id]');
  await expect(items.first()).toBeVisible({ timeout: 10_000 });
  const texts = await items.allInnerTexts();
  expect(texts.length).toBeGreaterThanOrEqual(3);
  for (const t of texts) expect(t.trim(), 'a status is never colour only').toMatch(/^(OK|Attention|Note)\b/);
});

Then(
  'the OAuth section says that load balancer, client IP and IdP behaviour are not checked by the server',
  async ({ page }: { page: Page }) => {
    const note = page.locator('#oauth-not-checked');
    await expect(note).toBeVisible();
    await expect(note).toContainText(/load balancer/i);
    await expect(note).toContainText(/client IP/i);
    await expect(note).toContainText(/auth_time/);
  },
);

When(
  'the admin sets the OAuth switch on with the issuer {string} and the acknowledgement',
  async ({ page }: { page: Page }, issuer: string) => {
    await setField(page, { enabled: true, issuer, ack: true });
  },
);

When(
  'the admin sets the OAuth switch on with the issuer {string} without the acknowledgement',
  async ({ page }: { page: Page }, issuer: string) => {
    await setField(page, { enabled: true, issuer, ack: false });
  },
);

When('the admin switches the OAuth switch off', async ({ page }: { page: Page }) => {
  await setField(page, { enabled: false, issuer: lastTyped.issuer, ack: false });
});

When('the admin saves the OAuth settings', async ({ page }: { page: Page }) => {
  await saveWithAdminReauth(page);
});

Then(
  'the OAuth issuer field shows the error {string} and is marked invalid',
  async ({ page }: { page: Page }, message: string) => {
    const field = page.locator('#oauth-issuer-input');
    await expect(field).toHaveAttribute('aria-invalid', 'true');
    await expect(field).toHaveAttribute('aria-describedby', /oauth-issuer-error/);
    await expect(page.locator('p#oauth-issuer-error[role="alert"]')).toContainText(message, { ignoreCase: true });
  },
);

Then(
  'the OAuth acknowledgement field shows the error {string} and is marked invalid',
  async ({ page }: { page: Page }, message: string) => {
    const field = page.locator('#oauth-ack-input');
    await expect(field).toHaveAttribute('aria-invalid', 'true');
    await expect(field).toHaveAttribute('aria-describedby', /oauth-ack-error/);
    await expect(page.locator('p#oauth-ack-error[role="alert"]')).toContainText(message, { ignoreCase: true });
  },
);

Then('the page shows an OAuth settings saved flash message', async ({ page }: { page: Page }) => {
  await expect(
    page.locator('[role="status"], [role="alert"]').filter({ hasText: /OAuth settings saved/ }).first(),
  ).toBeVisible({ timeout: 15_000 });
});

Then('the OAuth switch is off', async ({ page }: { page: Page }) => {
  await expect(page.locator(ENABLED)).not.toBeChecked({ timeout: 10_000 });
});

Then('the OAuth switch is on with the issuer {string}', async ({ page }: { page: Page }, issuer: string) => {
  await expect(page.locator(ENABLED)).toBeChecked({ timeout: 10_000 });
  await expect(page.locator(ISSUER)).toHaveValue(issuer);
});

Then('the OAuth status list names the stored switch as {word}', async ({ page }: { page: Page }, state: string) => {
  const item = page.locator('ul#oauth-status li[data-status-id="switch"]');
  await expect(item).toBeVisible({ timeout: 10_000 });
  await expect(item).toContainText(new RegExp(`\\b${state}\\b`, 'i'));
});
