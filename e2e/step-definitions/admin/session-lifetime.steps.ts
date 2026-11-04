/**
 * Step definitions for features/admin/session-lifetime.feature
 *
 * Story: oauth-session-and-consent / session-lifetime-setting (scenarios 2, 3, 5, 6) — ATDD steps (written before the implementation; they run only against
 * the full compose stack with the real Dex and are NOT executable in the isolated environment: verified statically with `bddgen --tags "@session-lifetime"`
 * + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), admin-ui project. NOT a @short-ttl scenario (never part of `make test-e2e-refresh`).
 *
 * Page contract (shared with server/test/nebu/admin/config_session_lifetime_test.exs): section `#session-lifetime`, form `#session-lifetime-form`
 * (POST /admin/config/session-lifetime), the text field `#session-lifetime-input` (`name="matrix_session_ttl_seconds"`, whole seconds, label "Session
 * lifetime in seconds"), the current value as text in `#session-lifetime-current` ("8 hours"), the description `#session-lifetime-help` (range, units, common values) and the note
 * `#session-lifetime-note` (what happens to existing sessions), the error `p#session-lifetime-error[role="alert"]`, the button "Save session lifetime" (described by the fresh sign-in hint)
 * or, without a fresh sign-in for /admin/config, the link "Sign in again to save". The flash of a save starts with "Session lifetime saved". The audit entry
 * is `session_lifetime_changed` (target `matrix_session_ttl_seconds`, metadata `before_seconds` / `after_seconds`, numbers only).
 *
 * Every save goes through the fresh sign-in (Dex) like the other /admin/config forms: the page decides at render time, the link comes first, the value is
 * typed AFTER the round trip (anything typed before is lost, nothing is replayed).
 *
 * Hygiene (test review M2): a Before hook remembers the `server_config` row of the key (or its absence) and the After hook puts it back BY SQL and asserts that
 * it is back, so a saved value never overrides NEBU_MATRIX_SESSION_TTL_SECONDS of a reused database. The scenario state is reset in the Before hook.
 * Steps reused from other files (bddgen rejects duplicates): "the admin navigates to {string}", the Background steps.
 */

import { When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { CONFIG_PATH, forgetMarker, isDexAuth, markerKnown, rememberMarker, signInAgainLink, signInAtDexAsAdmin } from '../../fixtures/oauth-admin';
import { queryAuditMetadata, queryServerConfigValue, restoreServerConfigRow } from '../../fixtures/db';

const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const POST_PATH = '/admin/config/session-lifetime';
const FORM = '#session-lifetime-form';
const FIELD = '#session-lifetime-input';
const SAVE = 'Save session lifetime';
const KEY = 'matrix_session_ttl_seconds';
const ACTION = 'session_lifetime_changed';

// scenario state, reset by the Before hook
let originalRow: string | null = null;
let remembered: string | undefined;
let lastTyped = '';

Before({ tags: '@session-lifetime' }, async () => {
  originalRow = queryServerConfigValue(KEY);
  remembered = undefined;
  lastTyped = '';
});

// Never leave a changed lifetime behind: the row goes back through the database (the form cannot delete a row, and cannot save a value below 1 hour that the
// environment may have set), and the hook proves that it is back.
After({ tags: '@session-lifetime' }, async () => {
  restoreServerConfigRow(KEY, originalRow);
  expect(queryServerConfigValue(KEY), 'the matrix_session_ttl_seconds row is back as it was before the scenario').toBe(originalRow);
});

async function typeValue(page: Page, value: string): Promise<void> {
  lastTyped = value;
  await expect(page.locator(FORM)).toBeVisible({ timeout: 10_000 });
  await page.locator(FIELD).fill(value);
}

/** Press "Save session lifetime"; without a fresh sign-in the link "Sign in again to save" comes first: sign in at Dex, then type the value again. */
async function saveWithAdminReauth(page: Page): Promise<void> {
  const saveButton = page.locator(FORM).getByRole('button', { name: SAVE, exact: true });
  const link = signInAgainLink(page.locator(FORM), 'save');
  await expect(saveButton.or(link), 'the form shows its submit or the sign-in link').toBeVisible({ timeout: 15_000 });
  const known = markerKnown(page, CONFIG_PATH);
  const linkShown = (await link.count()) > 0;
  // The first save of a session (no fresh sign-in known) MUST show the link instead of the submit.
  if (!known) {
    expect(linkShown, 'no fresh sign-in is known for /admin/config: the form must show the "Sign in again to save" link instead of its submit').toBe(true);
  }
  if (linkShown) {
    rememberMarker(page, CONFIG_PATH);
    await link.click();
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await typeValue(page, lastTyped);
  }

  const press = async () => {
    const [response] = await Promise.all([
      page.waitForResponse((r) => r.request().method() === 'POST' && new URL(r.url()).pathname === POST_PATH, { timeout: NAV_TIMEOUT_MS }),
      saveButton.click(),
    ]);
    return response;
  };

  let response = await press();
  // fallback: the marker expired between the page load and the submit (the POST is refused with the redirect to the sign-in, never replayed)
  if ([302, 303].includes(response.status()) && (response.headers()['location'] ?? '').startsWith('/admin/login/start')) {
    expect(known, 'the save was refused although the sign-in through the link had just been done').toBe(true);
    await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
    await typeValue(page, lastTyped);
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

// story admin-reauth-button-flow: the state is shown on the primary control; the admin signs in BEFORE he enters a change
Then('the session lifetime form shows the "Sign in again to save" link and no "Save session lifetime" button', async ({ page }: { page: Page }) => {
  const link = signInAgainLink(page.locator(FORM), 'save');
  await expect(link).toBeVisible({ timeout: 10_000 });
  await expect(link, 'a link, keyboard reachable, not a submit').toHaveAttribute('href', /^\/admin\/login\/start\?mode=reauth&return_to=%2Fadmin%2Fconfig$/);
  await expect(page.locator(FORM).getByRole('button', { name: SAVE, exact: true })).toHaveCount(0);
  const describedBy = await link.getAttribute('aria-describedby');
  expect(describedBy, 'the link keeps aria-describedby').toBeTruthy();
  await expect(page.locator(`#${describedBy}`)).toBeVisible();
});

When('the admin follows the "Sign in again to save" link of the session lifetime form and signs in again', async ({ page }: { page: Page }) => {
  await signInAgainLink(page.locator(FORM), 'save').click();
  await page.waitForURL((u) => isDexAuth(u), { timeout: NAV_TIMEOUT_MS });
  await signInAtDexAsAdmin(page);
  await page.waitForURL((u) => u.pathname === CONFIG_PATH, { timeout: NAV_TIMEOUT_MS });
  await expect(page.locator(FORM)).toBeVisible({ timeout: 15_000 });
  rememberMarker(page, CONFIG_PATH);
});

Then('the session lifetime form shows the "Save session lifetime" button and no "Sign in again to save" link', async ({ page }: { page: Page }) => {
  await expect(page.locator(FORM).getByRole('button', { name: SAVE, exact: true })).toBeVisible({ timeout: 10_000 });
  await expect(signInAgainLink(page.locator(FORM), 'save')).toHaveCount(0);
});

When('the admin remembers the session lifetime', async ({ page }: { page: Page }) => {
  await expect(page.locator(FIELD)).toBeVisible({ timeout: 10_000 });
  remembered = await page.locator(FIELD).inputValue();
  expect(remembered, 'the field shows the value in effect').toMatch(/^\d+$/);
});

When('the admin enters the session lifetime {string} seconds', async ({ page }: { page: Page }, seconds: string) => {
  await typeValue(page, seconds);
});

When('the admin saves the session lifetime', async ({ page }: { page: Page }) => {
  await saveWithAdminReauth(page);
});

Then('the page shows a session lifetime saved flash message', async ({ page }: { page: Page }) => {
  await expect(page.locator('[role="status"], [role="alert"]').filter({ hasText: /Session lifetime saved/ }).first()).toBeVisible({ timeout: 15_000 });
});

Then('the session lifetime shows {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(page.locator('#session-lifetime-current')).toContainText(text, { timeout: 10_000 });
});

Then('the session lifetime field shows {string}', async ({ page }: { page: Page }, value: string) => {
  await expect(page.locator(FIELD)).toHaveValue(value, { timeout: 10_000 });
});

Then('the session lifetime field shows the remembered value', async ({ page }: { page: Page }) => {
  expect(remembered, 'a value was remembered').toBeDefined();
  await expect(page.locator(FIELD)).toHaveValue(remembered as string, { timeout: 10_000 });
});

Then('the session lifetime form says that OAuth sessions keep the lifetime they started with', async ({ page }: { page: Page }) => {
  // the explanation sits OUTSIDE the description of the field (#session-lifetime-help), in #session-lifetime-note (UX review M3)
  const note = page.locator('#session-lifetime-note');
  await expect(note).toBeVisible();
  await expect(note).toContainText(/OAuth login keep the lifetime they started with/i);
});

Then('the session lifetime field shows the error {string} and is marked invalid', async ({ page }: { page: Page }, message: string) => {
  const field = page.locator(FIELD);
  await expect(field).toHaveAttribute('aria-invalid', 'true');
  await expect(field).toHaveAttribute('aria-describedby', /session-lifetime-error/);
  await expect(page.locator('section#session-lifetime p#session-lifetime-error[role="alert"]')).toContainText(message, { ignoreCase: true });
});

// ─── the database side (scenario 6: the audit entry; scenario 3: nothing was saved) ───────────────────────────────

Then('the stored session lifetime is {string}', async ({}, value: string) => {
  expect(queryServerConfigValue(KEY)).toBe(value);
});

Then('the stored session lifetime is unchanged', async () => {
  expect(queryServerConfigValue(KEY), 'a refused value leaves the stored row as it was').toBe(originalRow);
});

Then('the audit log has a session lifetime entry from the remembered number to {int}', async ({}, after: number) => {
  expect(remembered, 'a value was remembered').toBeDefined();
  const raw = queryAuditMetadata(ACTION, KEY);
  expect(raw, `an audit entry ${ACTION} exists`).not.toBe('');
  const metadata = JSON.parse(raw as string) as Record<string, unknown>;
  expect(metadata, 'numbers only: the old and the new lifetime').toEqual({ before_seconds: Number(remembered), after_seconds: after });
});
