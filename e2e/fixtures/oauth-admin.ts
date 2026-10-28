/**
 * Shared Admin-UI helpers for the OAuth client decisions that need a FRESH admin sign-in (story
 * oauth-client-revocation, P4, SO3/SO4): approving a pending registration and revoking an approved client.
 *
 * Contract (shared with server/test/nebu/oauth/oauth_admin_clients_test.exs and admin_reauth_test.exs):
 *   - the list's Approve is a LINK [data-role="review-approve"] to the confirm page
 *     GET /admin/oauth/registrations/:id/approve ([data-page="oauth-approve-confirm"], form
 *     [data-role="approve-confirm-form"], submit [data-role="approve-confirm"]); no native confirm() (SO3);
 *   - the approved list row has [data-role="revoke-client"] -> GET /admin/oauth/clients/:id/revoke
 *     ([data-page="oauth-revoke-confirm"], form [data-role="revoke-confirm-form"], inputs [name="confirm_host"]
 *     and [name="reason"], submit [data-role="revoke-confirm"]);
 *   - a POST without a fresh marker answers a redirect to /admin/login/start?mode=reauth, i.e. to the IdP
 *     (Dex) login form; after signing in again the browser is back on the SAME confirm page and the operator
 *     submits it once more (the POST is never replayed). A marker lives 300 s and is reused within it.
 *
 * Story sso-origins-admin-hardening (X-1): the two /admin/config forms that widen legacy-SSO trust (SSO redirect
 * origins, SSO redirect schemes) need the same fresh sign-in (marker bound to /admin/config, single use: it is
 * consumed by a SUCCESSFUL save, kept after a validation error). `saveConfigFormWithAdminReauth` drives that.
 *
 * Real flows only: the Dex login is driven in the browser, no cookie forging.
 */

import { expect } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';
import { DEX_TEST_PASSWORD } from './users';

export const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const ADMIN_EMAIL = process.env.NEBU_ADMIN_EMAIL ?? 'kai@example.com';
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);

export const REGISTRATIONS_PATH = '/admin/oauth/registrations';
export const CLIENTS_PATH = '/admin/oauth/clients';
export const REVOKED_PATH = '/admin/oauth/clients/revoked';
export const CONFIG_PATH = '/admin/config';

/** True for the Dex authorization endpoint (the IdP login form of the re-authentication). */
export const isDexAuth = (u: URL): boolean => /\/dex\/auth(\/|$)/i.test(u.pathname);

/** Signs in at the Dex login form as the admin operator (and passes the grant screen when Dex shows it). */
export async function signInAtDexAsAdmin(page: Page): Promise<void> {
  await expect(page.locator('input[name="login"]')).toBeVisible({ timeout: 15_000 });
  await page.locator('input[name="login"]').fill(ADMIN_EMAIL);
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();
  // Dex may show a grant screen (/dex/approval) before it redirects back: wait for EITHER the grant button OR the
  // browser leaving Dex, never a fixed delay (a slow Dex would otherwise be mistaken for "no grant screen").
  const grant = page.getByRole('button', { name: /^(grant access|allow|approve|confirm)$/i });
  const outcome = await Promise.race([
    grant.waitFor({ state: 'visible', timeout: NAV_TIMEOUT_MS }).then(() => 'grant' as const),
    page.waitForURL((u) => !/\/dex(\/|$)/i.test(u.pathname), { timeout: NAV_TIMEOUT_MS }).then(() => 'redirected' as const),
  ]);
  if (outcome === 'grant') await grant.click();
}

export type SubmitOutcome = {
  /** The browser went through the IdP login form (the fresh re-authentication of SO4). */
  reauthenticated: boolean;
};

/**
 * Click `submit` on a confirm page and drive the decision to its end: when the server asks for a fresh sign-in the
 * browser lands on Dex, the operator signs in, comes back to the confirm page (`confirmPath`) and submits again.
 * Resolves once the browser is on a page matching `donePath` (the list the decision redirects to).
 */
export async function submitWithAdminReauth(
  page: Page,
  opts: {
    submit: () => Locator;
    confirmPath: RegExp;
    confirmPageSelector: string;
    donePath: RegExp;
    /** Re-type the form after the fresh sign-in (the confirm page is rendered anew and empty). */
    refill?: () => Promise<void>;
  },
): Promise<SubmitOutcome> {
  await opts.submit().click();
  // Either the decision went through (redirect to the list), or the server asks for a fresh sign-in (Dex).
  await page.waitForURL((u) => opts.donePath.test(u.pathname) || isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
  if (opts.donePath.test(new URL(page.url()).pathname)) return { reauthenticated: false };

  await signInAtDexAsAdmin(page);
  await page.waitForURL((u) => opts.confirmPath.test(u.pathname), { timeout: NAV_TIMEOUT_MS });
  await expect(page.locator(opts.confirmPageSelector), 'back on the confirm page after the fresh sign-in').toBeVisible({
    timeout: 15_000,
  });
  if (opts.refill) await opts.refill();
  await opts.submit().click();
  await page.waitForURL((u) => opts.donePath.test(u.pathname), { timeout: NAV_TIMEOUT_MS });
  return { reauthenticated: true };
}

/** Approve a pending registration through its confirm page (list link -> confirm page -> submit, with re-auth). */
export async function approveThroughConfirmPage(page: Page, clientId: string): Promise<SubmitOutcome & { host: string }> {
  const row = page.locator(`[data-role="oauth-client-row"][data-client-id="${clientId}"]`);
  await expect(row).toBeVisible({ timeout: 15_000 });
  // SO3: a plain link, never a native confirm(): a dialog here would mean the old approve form is still there
  let dialogFired = false;
  page.once('dialog', (d) => {
    dialogFired = true;
    void d.dismiss();
  });
  await row.locator('a[data-role="review-approve"]').click();
  await expect(page.locator('[data-page="oauth-approve-confirm"]')).toBeVisible({ timeout: 15_000 });
  const host = ((await page.locator('[data-page="oauth-approve-confirm"] [data-role="client-host"]').first().textContent()) ?? '').trim();

  const outcome = await submitWithAdminReauth(page, {
    submit: () => page.locator('[data-role="approve-confirm-form"] [data-role="approve-confirm"]'),
    confirmPath: new RegExp(`${REGISTRATIONS_PATH}/[^/]+/approve$`),
    confirmPageSelector: '[data-page="oauth-approve-confirm"]',
    donePath: new RegExp(`${REGISTRATIONS_PATH}$`),
  });
  expect(dialogFired, 'approving uses a confirm PAGE, not a native confirm() dialog (SO3)').toBe(false);
  return { ...outcome, host };
}

/** Revoke an approved client through its confirm page with the typed host (and an optional reason). */
export async function revokeThroughConfirmPage(
  page: Page,
  clientId: string,
  typedHost: string,
  reason = '',
): Promise<SubmitOutcome> {
  await page.goto(`${ADMIN_BASE_URL}${CLIENTS_PATH}/${encodeURIComponent(clientId)}/revoke`);
  await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
  const fill = async (): Promise<void> => {
    await page.locator('[data-role="revoke-confirm-form"] [name="confirm_host"]').fill(typedHost);
    if (reason !== '') await page.locator('[data-role="revoke-confirm-form"] [name="reason"]').fill(reason);
  };
  await fill();
  return submitWithAdminReauth(page, {
    refill: fill,
    submit: () => page.locator('[data-role="revoke-confirm-form"] [data-role="revoke-confirm"]'),
    confirmPath: new RegExp(`${CLIENTS_PATH}/[^/]+/revoke$`),
    confirmPageSelector: '[data-page="oauth-revoke-confirm"]',
    donePath: new RegExp(`${CLIENTS_PATH}$`),
  });
}

/**
 * Submit one of the SSO trust forms of /admin/config (`#sso-origins-form`, `#sso-schemes-form`) with the fresh sign-in
 * they need (story sso-origins-admin-hardening, X-1). The POST is refused with a redirect to
 * /admin/login/start?mode=reauth when the session has no fresh marker bound to /admin/config; the browser then goes
 * through the Dex login form, comes back to /admin/config (rendered anew, the form empty, with the info flash "Signed in again. Your change was
 * not saved yet ...") and the typed value is re-entered and submitted once more (the POST is never replayed). The admin may also still hold a marker
 * (a validation error does not consume it): then the first POST answers directly.
 *
 * Resolves after the final POST answered: a redirect back to /admin/config (saved) or the 200 re-render of a
 * rejected value (at the POST path). `form`: CSS selector of the form, `field`: selector of its text input (inside
 * the form), `button`: accessible name of its submit button.
 */
export async function saveConfigFormWithAdminReauth(
  page: Page,
  opts: { form: string; field: string; button: RegExp },
): Promise<SubmitOutcome> {
  const form = page.locator(opts.form);
  const action = (await form.getAttribute('action')) ?? '';
  const typed = await form.locator(opts.field).inputValue();

  const press = async () => {
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'POST' && new URL(r.url()).pathname === action, {
        timeout: NAV_TIMEOUT_MS,
      }),
      form.getByRole('button', { name: opts.button }).click(),
    ]);
    return response;
  };
  const asksForSignIn = (status: number, location: string): boolean =>
    [302, 303].includes(status) && location.startsWith('/admin/login/start');

  let response = await press();
  let reauthenticated = false;
  if (asksForSignIn(response.status(), response.headers()['location'] ?? '')) {
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await expect(page.locator(opts.form), 'back on /admin/config after the fresh sign-in').toBeVisible({ timeout: 15_000 });
    await page.locator(opts.form).locator(opts.field).fill(typed);
    response = await press();
    reauthenticated = true;
  }
  expect(
    response.status(),
    'the save is answered by a redirect back to /admin/config (saved) or the 200 re-render of a rejected value, not by another sign-in request or a refusal',
  ).not.toBe(403);
  if ([302, 303].includes(response.status())) {
    // Saved: wait for the redirect target to be loaded AND rendered with the flash of THIS save (the page after the
    // fresh sign-in carries an info flash "Signed in again. Your change was not saved yet ...": it must not be
    // mistaken for the result, hence the exact texts of the save flashes).
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await expect(
      page
        .locator('[role="status"], [role="alert"]')
        .filter({ hasText: /^\s*(SSO (origins|schemes) saved|Failed to save SSO (origins|schemes))\s*$/ })
        .first(),
      'the config page is loaded with the flash of the save',
    ).toBeVisible({ timeout: 15_000 });
  } else {
    // a rejected value is re-rendered by the POST itself (200)
    await page.waitForLoadState('load');
  }
  return { reauthenticated };
}

/**
 * Submit one of the mapping forms (`/admin/config/claim-mapping`, `/admin/config/role-mapping`) with the fresh sign-in they need (story
 * admin-config-privileged-forms-sweep, follow-up `cw`; the marker is bound to THAT page). Like `saveConfigFormWithAdminReauth`, but the
 * values of ALL visible text inputs of the form are kept and re-entered after the sign-in at the IdP (the page comes back with its stored
 * values; the POST is never replayed). Resolves after the final POST answered: a redirect back to the page (saved) or the 200 re-render of
 * a rejected value. `page` is the page path, `button` the accessible name of the submit button.
 */
export async function saveMappingFormWithAdminReauth(page: Page, opts: { page: string; button: RegExp }): Promise<SubmitOutcome> {
  const form = page.locator(`form[action="${opts.page}"]`);
  const names = await form.locator('input:not([type="hidden"])').evaluateAll((els) => els.map((e) => (e as HTMLInputElement).name));
  const typed: Record<string, string> = {};
  for (const name of names) typed[name] = await form.locator(`input[name="${name}"]`).inputValue();

  const press = async () => {
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'POST' && new URL(r.url()).pathname === opts.page, { timeout: NAV_TIMEOUT_MS }),
      form.getByRole('button', { name: opts.button }).click(),
    ]);
    return response;
  };
  const asksForSignIn = (status: number, location: string): boolean => [302, 303].includes(status) && location.startsWith('/admin/login/start');

  let response = await press();
  let reauthenticated = false;
  if (asksForSignIn(response.status(), response.headers()['location'] ?? '')) {
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === opts.page, { timeout: NAV_TIMEOUT_MS });
    await expect(page.locator(`form[action="${opts.page}"]`), 'back on the mapping page after the fresh sign-in').toBeVisible({ timeout: 15_000 });
    for (const [name, value] of Object.entries(typed)) await page.locator(`form[action="${opts.page}"] input[name="${name}"]`).fill(value);
    response = await press();
    reauthenticated = true;
  }
  expect(response.status(), 'the save is answered by a redirect (saved) or the 200 re-render of a rejected value, never a refusal').not.toBe(403);
  if ([302, 303].includes(response.status())) await page.waitForURL((u) => u.pathname === opts.page, { timeout: NAV_TIMEOUT_MS });
  else await page.waitForLoadState('load');
  return { reauthenticated };
}
