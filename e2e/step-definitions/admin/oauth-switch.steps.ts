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
 * Every save goes through the fresh sign-in (Dex) like the other /admin/config trust forms. Story admin-reauth-button-flow: the page decides at
 * render time. Without a fresh sign-in the form shows the link "Sign in again to save" INSTEAD of the submit: the operator clicks it, signs in again,
 * comes back to /admin/config (rendered anew) and enters the values THEN (anything typed before the round trip is lost, a refused POST is never
 * replayed); only then the button "Save OAuth settings" is there. The step 'the {string} form control is described by the sign-in hint'
 * is reused from sso-redirect-origins.steps.ts (bddgen rejects duplicates).
 */

import { When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { CONFIG_PATH, forgetMarker, isDexAuth, markerKnown, rememberMarker, signInAgainLink, signInAtDexAsAdmin } from '../../fixtures/oauth-admin';

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

/** Press "Save OAuth settings"; without a fresh sign-in the link "Sign in again to save" comes first: sign in at Dex, then re-enter the typed values. */
async function saveWithAdminReauth(page: Page, opts: { cleanup?: boolean } = {}): Promise<void> {
  const saveButton = page.locator(FORM).getByRole('button', { name: 'Save OAuth settings', exact: true });
  const link = signInAgainLink(page.locator(FORM), 'save');
  await expect(saveButton.or(link), 'the OAuth form shows its submit or the sign-in link').toBeVisible({ timeout: 15_000 });
  const known = markerKnown(page, CONFIG_PATH);
  const linkShown = (await link.count()) > 0;
  // The first save of a session (no fresh sign-in known) MUST show the link instead of the submit; the teardown hook is tolerant (the state is unknown after a failure).
  if (!known && !opts.cleanup) {
    expect(linkShown, 'no fresh sign-in is known for /admin/config: the OAuth form must show the "Sign in again to save" link instead of its submit').toBe(true);
  }
  if (linkShown) {
    rememberMarker(page, CONFIG_PATH);
    await link.click();
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await setField(page, lastTyped);
  }

  const press = async () => {
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'POST' && new URL(r.url()).pathname === '/admin/config/oauth-switch', {
        timeout: NAV_TIMEOUT_MS,
      }),
      saveButton.click(),
    ]);
    return response;
  };

  let response = await press();
  // fallback: the marker expired between the page load and the submit (the POST is refused with the redirect to the sign-in, never replayed)
  if ([302, 303].includes(response.status()) && (response.headers()['location'] ?? '').startsWith('/admin/login/start')) {
    expect(known || opts.cleanup === true, 'the save was refused although the sign-in through the link had just been done').toBe(true);
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await setField(page, lastTyped);
    response = await press();
  }
  expect(response.status(), 'the save is answered by a redirect (saved) or the 200 re-render of a rejected value, never a refusal').not.toBe(403);
  if ([302, 303].includes(response.status())) {
    forgetMarker(page, CONFIG_PATH); // a save consumes the marker
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
  await saveWithAdminReauth(page, { cleanup: true });
});

Then(
  'the OAuth section shows the "Offer the OAuth 2.0 API" checkbox, the "Issuer URL" field and the "Save OAuth settings" button or its sign-in link',
  async ({ page }: { page: Page }) => {
    await expect(page.locator('section#oauth-switch')).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole('heading', { name: 'OAuth 2.0 authorization server' })).toBeVisible();
    await expect(page.getByLabel('Offer the OAuth 2.0 API')).toBeVisible();
    await expect(page.getByLabel('Issuer URL')).toBeVisible();
    // the primary control is the submit with a fresh sign-in, the link "Sign in again to save" without one (story admin-reauth-button-flow)
    await expect(
      page.getByRole('button', { name: 'Save OAuth settings', exact: true }).or(signInAgainLink(page.locator(FORM), 'save')),
    ).toBeVisible();
  },
);

// story admin-reauth-button-flow: the state is shown on the primary control; the admin signs in BEFORE he enters a change
Then('the OAuth form shows the "Sign in again to save" link and no "Save OAuth settings" button', async ({ page }: { page: Page }) => {
  const link = signInAgainLink(page.locator(FORM), 'save');
  await expect(link).toBeVisible({ timeout: 10_000 });
  await expect(link, 'a link, keyboard reachable, not a submit').toHaveAttribute('href', /^\/admin\/login\/start\?mode=reauth&return_to=%2Fadmin%2Fconfig$/);
  await expect(page.locator(FORM).getByRole('button', { name: 'Save OAuth settings', exact: true })).toHaveCount(0);
  const describedBy = await link.getAttribute('aria-describedby');
  expect(describedBy, 'the link keeps aria-describedby').toBeTruthy();
  await expect(page.locator(`#${describedBy}`)).toBeVisible();
});

When('the admin follows the "Sign in again to save" link of the OAuth form and signs in again', async ({ page }: { page: Page }) => {
  await signInAgainLink(page.locator(FORM), 'save').click();
  await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
  await signInAtDexAsAdmin(page);
  await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
  await expect(page.locator(FORM)).toBeVisible({ timeout: 15_000 });
  rememberMarker(page, CONFIG_PATH);
});

Then('the OAuth form shows the "Save OAuth settings" button and no "Sign in again to save" link', async ({ page }: { page: Page }) => {
  await expect(page.locator(FORM).getByRole('button', { name: 'Save OAuth settings', exact: true })).toBeVisible({ timeout: 10_000 });
  await expect(signInAgainLink(page.locator(FORM), 'save')).toHaveCount(0);
});

// story admin-reauth-button-flow, scenario "a fresh sign-in for another page does not unlock this page": the sign-in is made on the claim mapping page
When('the admin follows the "Sign in again to save" link of the claim mapping form and signs in again', async ({ page }: { page: Page }) => {
  const mapping = '/admin/config/claim-mapping';
  await signInAgainLink(page.locator(`form[action="${mapping}"]`), 'save').click();
  await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
  await signInAtDexAsAdmin(page);
  await page.waitForURL((u) => u.pathname === mapping, { timeout: NAV_TIMEOUT_MS });
  await expect(page.locator(`form[action="${mapping}"]`).getByRole('button', { name: 'Save', exact: true })).toBeVisible({ timeout: 15_000 });
});

Then('the OIDC scopes and refresh mode forms still show their plain submit buttons', async ({ page }: { page: Page }) => {
  for (const [form, name] of [['#oidc-scopes-form', 'Save scopes'], ['#oidc-refresh-mode-form', 'Save refresh mode']] as const) {
    await expect(page.locator(form).getByRole('button', { name, exact: true }), `${form}: the plain submit`).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(form).getByRole('link', { name: /^Sign in again to /i }), `${form}: never a sign-in link`).toHaveCount(0);
  }
});

Then('the OAuth form says that the fresh sign-in is valid for some minutes and for one save', async ({ page }: { page: Page }) => {
  const hint = page.locator('#oauth-switch-reauth-hint');
  await expect(hint).toContainText(/valid/i);
  await expect(hint).toContainText(/(\d+ minutes?|less than a minute)/i);
  await expect(hint).toContainText(/one save/i);
  const describedBy = await page.locator(FORM).getByRole('button', { name: 'Save OAuth settings', exact: true }).getAttribute('aria-describedby');
  expect(describedBy, 'the button is described by the validity line').toContain('oauth-switch-reauth-hint');
});

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
