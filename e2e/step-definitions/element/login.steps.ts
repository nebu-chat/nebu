/**
 * Step definitions for features/element/login.feature
 *
 * Story 9-26 — Phase 2, AC6.
 *
 * Implements: SSO login via Dex, logout, cached session check.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { DEX_TEST_PASSWORD } from '../../fixtures/users';
import * as fs from 'fs';
import * as path from 'path';

const ELEMENT_URL     = process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070';
const AUTH_STATE_DIR  = path.join(__dirname, '../../auth-state');

/**
 * "Given alex has no cached session"
 *
 * Clears any existing storageState so the login flow starts fresh.
 * Also clears localStorage in the current page context.
 */
Given('{word} has no cached session', async ({ page }: { page: Page }, userName: string) => {
  // Clear the cached storageState file for this user
  const statePath = path.join(AUTH_STATE_DIR, `${userName}.json`);
  if (fs.existsSync(statePath)) {
    fs.unlinkSync(statePath);
  }

  // N-18: Also delete the token sidecar so getApiSession() does not use a stale token
  const tokenSidecar = path.join(AUTH_STATE_DIR, `${userName}.token.json`);
  if (fs.existsSync(tokenSidecar)) {
    fs.unlinkSync(tokenSidecar);
  }

  // Clear browser localStorage so the page starts fresh
  await page.goto(ELEMENT_URL);
  await page.evaluate(() => {
    try { window.localStorage.clear(); } catch { /* ignore cross-origin */ }
  });
});

/**
 * "When alex opens Element Web and clicks "Sign in""
 *
 * Navigates to Element Web and clicks the Sign in link.
 */
When(
  '{word} opens Element Web and clicks {string}',
  async ({ page }: { page: Page }, _userName: string, _buttonText: string) => {
    await page.goto(ELEMENT_URL);

    // Wait for the sign-in link (Element welcome screen)
    const signInLink = page.getByRole('link', { name: /sign in|anmelden/i });
    await signInLink.waitFor({ state: 'visible', timeout: 15_000 });
    await signInLink.click();
  }
);

/**
 * "When alex authenticates via Dex with {string}"
 *
 * Fills Dex login form and handles optional consent screen.
 * On success, waits for .mx_LeftPanel.
 */
When(
  '{word} authenticates via Dex with {string}',
  async ({ page }: { page: Page }, _userName: string, email: string) => {
    // Wait for SSO button on Element login page
    const ssoBtn = page.getByRole('button', { name: /continue with sso|mit sso|weiter mit sso/i });
    await ssoBtn.waitFor({ state: 'visible', timeout: 15_000 });
    await ssoBtn.click();

    // Dex login page
    await page.waitForURL(/dex.*\/auth/i, { timeout: 20_000 });
    await page.locator('input[name="login"]').fill(email);
    await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
    await page.locator('button[type="submit"]').click();

    // Handle optional Dex consent screen (first login)
    const consentBtn = page.getByRole('button', { name: /grant access|allow|approve|confirm/i });
    if (await consentBtn.isVisible({ timeout: 6_000 }).catch(() => false)) {
      await consentBtn.click();
    }

    // Wait for redirect back to Element Web
    await page.waitForURL(/localhost:7070/, { timeout: 30_000 });

    // Dismiss key-setup / device-verification dialog if it appears (first login).
    // Element Web 1.12.15 shows a "Confirm your digital identity / Verify this device"
    // screen with a "Skip verification for now" button once the account has a cross-signing
    // identity (which it now does — the server persists & echoes cross-signing keys, epic
    // client-crypto-setup). The old /cancel|abbrechen/ pattern did not match that button, so
    // .mx_LeftPanel was never reached. Broaden to the same set dex-auth.ts uses, plus the
    // verification-skip wording.
    const dismissPattern = /skip verification|skip|überspringen|cancel|abbrechen|not now|later|close|schließen|continue/i;
    await Promise.race([
      page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 25_000 }),
      page.getByRole('button', { name: dismissPattern })
        .first().waitFor({ state: 'visible', timeout: 25_000 }),
    ]).catch((e: Error) => { if (!e.message?.includes('Timeout')) throw e; });

    // AC4: a "Skip verification for now" prompt is EXPECTED (the account has a cross-signing
    // identity and we deliberately skip the in-browser verification). A "could not set up keys"
    // dialog is a genuine FAILURE — the server's device-key directory broke. We must NOT let the
    // broad dismiss pattern (continue/close/…) click that error away and pass silently: assert it
    // is absent BEFORE dismissing, and fail loudly if present.
    await assertNoKeySetupError(page);

    const cancelBtn = page.getByRole('button', { name: dismissPattern });
    if (await cancelBtn.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
      await cancelBtn.first().click({ timeout: 5_000 }).catch(() => { /* dialog self-closed */ });
    }

    // Re-check after dismissing: dismissing the verification screen must not surface a
    // key-setup error either.
    await assertNoKeySetupError(page);

    // Confirm .mx_LeftPanel is now visible
    await page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 20_000 });
  }
);

/**
 * AC4 guard — fail if Element shows a real key-setup ERROR rather than the (expected,
 * skippable) device-verification screen.
 *
 * Element Web surfaces a "could not set up keys" / "Schlüssel können nicht eingerichtet werden"
 * dialog when server-side cross-signing/device-key setup fails. The login dismiss pattern is
 * deliberately broad (skip/continue/close/…) so it could otherwise click that error dialog away
 * and let the scenario pass silently. This helper detects the error text and throws so the
 * scenario fails with a clear message instead.
 *
 * Exported so other element step files (e.g. the @ac6-safari-relogin step) can reuse it.
 */
export async function assertNoKeySetupError(page: Page): Promise<void> {
  // Match the failure wording (EN + DE) anywhere on the page — Element renders it inside an
  // .mx_Dialog / .mx_ErrorDialog, but text-based matching is robust across Element versions.
  const keySetupError = page.getByText(
    /could not set up (your )?keys|unable to set up keys|error setting up (secure )?keys|schlüssel können nicht eingerichtet werden|schlüssel konnten nicht eingerichtet werden/i,
  );
  // Quick probe (not a hard wait): if such text is present right now, fail.
  if (await keySetupError.first().isVisible({ timeout: 1_000 }).catch(() => false)) {
    const detail = await keySetupError.first().textContent().catch(() => null);
    throw new Error(
      `AC4: Element showed a key-setup ERROR after login (not the skippable verification screen): ` +
      `${detail?.trim() ?? '<could not read dialog text>'}`,
    );
  }
}

/**
 * "When alex opens the user menu and clicks {string}"
 *
 * Opens the user menu and clicks the specified menu item.
 *
 * Element Web 1.12.15 change: The user menu trigger is a div[role="button"] with
 * aria-label="User menu" (NOT a <button> element). The menu no longer has a "Sign out"
 * item — the equivalent is "Remove this device" which signs the user out.
 *
 * "Sign out" is mapped to "Remove this device" for Element Web 1.12.15+ compatibility.
 */
When(
  '{word} opens the user menu and clicks {string}',
  async ({ page }: { page: Page }, _userName: string, menuItem: string) => {
    // Element Web 1.12.15: user menu trigger is [aria-label="User menu"] (div with role="button")
    // Older versions used .mx_UserMenu button or [data-testid="user-menu-trigger"]
    const userMenuTrigger = page.locator('[aria-label="User menu"]')
      .or(page.locator('[data-testid="user-menu-trigger"]'))
      .or(page.locator('.mx_UserMenu button'));

    await userMenuTrigger.first().waitFor({ state: 'visible', timeout: 10_000 });
    await userMenuTrigger.first().click();

    // Normalize "Sign out" → "Remove this device" for Element Web 1.12.15+
    // (1.12.15 removed "Sign out" from the user menu; the closest equivalent is
    //  "Remove this device" which revokes the session token)
    const effectiveItem = /sign out|log out|abmelden/i.test(menuItem)
      ? 'Remove this device'
      : menuItem;

    // Click the menu item by aria-label (Element uses aria-label on <li role="menuitem">)
    const menuItemLocator = page.locator(`[role="menuitem"][aria-label="${effectiveItem}"]`)
      .or(page.getByRole('menuitem', { name: new RegExp(effectiveItem, 'i') }))
      .or(page.getByRole('button', { name: new RegExp(effectiveItem, 'i') }));

    await menuItemLocator.first().waitFor({ state: 'visible', timeout: 5_000 });
    await menuItemLocator.first().click();

    // "Remove this device" may show a confirmation dialog. Scope the confirm button to an
    // OPEN dialog so the broad regex can't latch onto a detaching Space tile in the
    // background (which caused a 20s timeout). Keep it truly optional with short timeouts.
    const confirmBtn = page.locator('.mx_Dialog, [role="dialog"]')
      .getByRole('button', { name: /sign out|remove|delete|confirm|ok/i });
    if (await confirmBtn.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
      await confirmBtn.first().click({ timeout: 3_000 }).catch(() => {});
    }
  }
);

/**
 * "When alex reloads Element Web"
 */
When('{word} reloads Element Web', async ({ page }: { page: Page }, _userName: string) => {
  await page.reload();
  // Give it a moment to settle
  await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch((e: Error) => { if (!e.message?.includes('Timeout')) throw e; });
});

/**
 * "Then the welcome screen is visible"
 *
 * Element Web 1.12.15 change: After "Remove this device" (the sign-out equivalent),
 * the page redirects to /#/login (NOT the /#/welcome or /# home screen).
 * The login page shows a "Sign in" heading (h2) and "Homeserver" heading.
 * We also check for the classic welcome screen selectors as fallback.
 */
Then('the welcome screen is visible', async ({ page }: { page: Page }) => {
  // Wait for URL to change away from the main room list
  await page.waitForURL(/\/#\/(login|welcome|home|$)/, { timeout: 15_000 }).catch(() => {});

  await expect(
    // Element Web 1.12.15+: /#/login with "Sign in" heading
    page.getByRole('heading', { name: /sign in/i })
      // Classic welcome screen selectors
      .or(page.getByRole('heading', { name: /welcome to element|willkommen/i }))
      .or(page.locator('.mx_Welcome'))
      .or(page.getByRole('link', { name: /sign in|anmelden/i }))
  ).toBeVisible({ timeout: 15_000 });
});

/**
 * "Then the {string} button is present"
 *
 * Element Web 1.12.15: After sign-out, the page is at /#/login.
 * "Sign in" appears as a heading, not a link or button.
 * Accept heading, button, or link with the given text.
 */
Then('the {string} button is present', async ({ page }: { page: Page }, buttonText: string) => {
  await expect(
    page.getByRole('link', { name: new RegExp(buttonText, 'i') })
      .or(page.getByRole('button', { name: new RegExp(buttonText, 'i') }))
      .or(page.getByRole('heading', { name: new RegExp(buttonText, 'i') }))
  ).toBeVisible({ timeout: 10_000 });
});

/**
 * "Then the room list is visible without a Dex redirect"
 */
Then('the room list is visible without a Dex redirect', async ({ page }: { page: Page }) => {
  // Assert we did NOT land on Dex (no /dex/auth in URL)
  const currentUrl = page.url();
  expect(currentUrl).not.toMatch(/dex.*\/auth/i);
  // Assert room list is visible
  await expect(page.locator('.mx_LeftPanel')).toBeVisible({ timeout: 20_000 });
});

// ---------------------------------------------------------------------------
// AC6-safari-relogin steps
// Story 11.7 — Safari logout → immediate SSO re-login lands on room list
// ---------------------------------------------------------------------------

/**
 * "When alex immediately logs back in via SSO as {string} without clearing browser storage"
 *
 * This is the critical path for the Safari re-login bug:
 *   - The user is already on the post-logout screen (/#/login or /#/welcome).
 *   - Browser storage (localStorage / IndexedDB / cookies) is NOT cleared.
 *     This replicates the Safari scenario where old state is still present.
 *   - The user initiates a fresh SSO login by clicking the SSO button.
 *   - Dex will be reached via a full Authorization Code + PKCE flow.
 *   - The nonce generated in GetSSORedirect is new, so Dex cannot replay a cached JWT.
 *   - On success, Element Web should show the room list, NOT #/welcome.
 *
 * Per CLAUDE.md: OIDC tests MUST use Authorization Code + PKCE. Never use ROPC
 * (grant_type=password) shortcuts. This step drives real browser SSO navigation.
 */
When(
  '{word} immediately logs back in via SSO as {string} without clearing browser storage',
  async ({ page }: { page: Page }, _userName: string, email: string) => {
    // IMPORTANT: do NOT clear browser storage here.
    // The bug (Safari re-login failure) was triggered precisely because the browser
    // retained state from the previous session. Clearing storage would mask the bug.

    // Wait for the post-logout login page (Element Web 1.12.15 redirects to /#/login).
    // We accept /#/login, /#/welcome, or the bare root since Element versions differ.
    await page.waitForURL(/\/(#\/(login|welcome|home))?$/, { timeout: 15_000 }).catch((e: Error) => {
      if (!e.message?.includes('Timeout')) throw e;
      // timeout is acceptable — page may already be on the right URL
    });

    // Locate the SSO / "Continue with SSO" button. After logout, Element shows the
    // login page directly with the SSO button (no intermediate "Sign in" link needed).
    // Try SSO button first; fall back to "Sign in" link → SSO button flow.
    const ssoBtn = page.getByRole('button', { name: /continue with sso|mit sso|weiter mit sso/i });
    const signInLink = page.getByRole('link', { name: /sign in|anmelden/i });

    const ssoBtnVisible = await ssoBtn.isVisible({ timeout: 6_000 }).catch(() => false);
    if (!ssoBtnVisible) {
      // May need to click "Sign in" first (some Element versions show welcome before login form)
      const signInVisible = await signInLink.isVisible({ timeout: 5_000 }).catch(() => false);
      if (signInVisible) {
        await signInLink.click();
        await ssoBtn.waitFor({ state: 'visible', timeout: 10_000 });
      }
    }

    await ssoBtn.waitFor({ state: 'visible', timeout: 10_000 });
    await ssoBtn.click();

    // Dex login page — full Authorization Code + PKCE flow (CLAUDE.md: no ROPC).
    await page.waitForURL(/dex.*\/auth/i, { timeout: 20_000 });
    await page.locator('input[name="login"]').fill(email);
    await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
    await page.locator('button[type="submit"]').click();

    // Dex consent screen (may appear if Dex session expired or if prompt=login triggered re-auth)
    const consentBtn = page.getByRole('button', { name: /grant access|allow|approve|confirm/i });
    if (await consentBtn.isVisible({ timeout: 6_000 }).catch(() => false)) {
      await consentBtn.click();
    }

    // Wait for redirect back to Element Web
    await page.waitForURL(/localhost:7070/, { timeout: 30_000 });

    // Element may show a key-setup / device-verification dialog — dismiss it so the
    // room list can appear. This mirrors loginViaOidcBrowser() and the SSO-login step:
    // once the account has a cross-signing identity, Element shows "Skip verification for now",
    // which /cancel|abbrechen/ alone did not match.
    const reloginDismissPattern = /skip verification|skip|überspringen|cancel|abbrechen|not now|later|close|schließen|continue/i;
    await Promise.race([
      page.locator('.mx_LeftPanel').waitFor({ state: 'visible', timeout: 25_000 }),
      page.getByRole('button', { name: reloginDismissPattern })
        .first().waitFor({ state: 'visible', timeout: 25_000 }),
    ]).catch((e: Error) => {
      throw new Error(`@ac6-safari-relogin: post-login state not reached — ${e.message}`);
    });

    // AC4: a key-setup error after re-login is a genuine failure — do not dismiss it silently.
    await assertNoKeySetupError(page);

    const cancelBtn = page.getByRole('button', { name: reloginDismissPattern });
    if (await cancelBtn.first().isVisible({ timeout: 3_000 }).catch(() => false)) {
      await cancelBtn.first().click({ timeout: 5_000 }).catch(() => { /* dialog self-closed */ });
    }
  }
);

/**
 * "Then the URL does not contain {string}"
 *
 * Verifies the current page URL does not include the given substring.
 * Used by @ac6-safari-relogin to assert the user did NOT land on #/welcome.
 */
Then('the URL does not contain {string}', async ({ page }: { page: Page }, fragment: string) => {
  const currentUrl = page.url();
  expect(currentUrl).not.toContain(fragment);
});
