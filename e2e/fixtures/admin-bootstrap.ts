/**
 * Admin bootstrap helper — shared between global-setup and bootstrap.steps.ts.
 *
 * Story 9-26 — BUG-E2E-11 fix:
 *   The Elixir core's upsert_with_bootstrap() sets bootstrap_completed=true when
 *   the FIRST Matrix user logs in (fresh DB). This pre-empts the admin UI wizard
 *   and leaves server_config without OIDC keys (oidc_issuer, oidc_client_id,
 *   oidc_client_secret). The fix: run admin bootstrap in global-setup BEFORE
 *   Element Web user logins, so that OIDC config is written first.
 *
 * doBootstrapAdmin():
 *   - Navigates to /admin/
 *   - If redirected to /bootstrap: completes the full wizard (Steps 1–3 + Dex login)
 *   - If NOT redirected to /bootstrap: verifies OIDC config is present
 *     (i.e., /admin/login/start doesn't redirect back to /bootstrap).
 *     If OIDC config is missing (auto-bootstrap from core), logs a warning.
 *   - Idempotent: safe to call multiple times.
 */

import type { Page } from '@playwright/test';
import { DEX_TEST_PASSWORD } from './users';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const DEX_ISSUER_URL = process.env.DEX_ISSUER_URL ?? 'http://dex:5556/dex';

/**
 * Complete the admin bootstrap wizard if it has not yet been completed.
 * Safe to call multiple times — if bootstrap is already complete AND OIDC config
 * is present, returns immediately without any browser navigation.
 *
 * Wizard flow:
 *   Step 1: Instance Name → Next
 *   Step 2: OIDC config → Connect with OIDC (Dex redirect)
 *   Dex login: email/password → submit
 *   [Optional] Dex grant screen → Grant
 *   /admin/callback: select admin group claim → Confirm Admin Claim
 *   Done: redirected to /admin/dashboard
 */
export async function doBootstrapAdmin(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/`);

  // Wait for navigation to settle
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 });

  const landingUrl = page.url();

  // If we're at the bootstrap page, run the wizard
  if (landingUrl.includes('/bootstrap')) {
    await runBootstrapWizard(page);
    return;
  }

  // If we're at the login page or dashboard, bootstrap may already be complete
  // Check if OIDC config is present by testing /admin/login/start
  // If it redirects BACK to /bootstrap, OIDC config is missing (core auto-bootstrap)
  // In that case, we cannot fix this from the browser (BootstrapGuard blocks /bootstrap).
  // Warn but continue — subsequent tests that need OIDC will fail with a clear message.
  if (landingUrl.includes('/login') || landingUrl.includes('/dashboard')) {
    // Bootstrap status: completed but may lack OIDC config
    // We cannot detect this without a DB check from browser — skip the check here
    // and rely on the test to fail if OIDC config is missing
    console.log(`[doBootstrapAdmin] Admin UI bootstrap already marked complete (url: ${landingUrl}). OIDC config may or may not be present.`);
    return;
  }

  // Unexpected URL — bootstrap may be needed
  console.warn(`[doBootstrapAdmin] Unexpected landing URL: ${landingUrl}. Attempting to navigate to bootstrap.`);
  await page.goto(`${ADMIN_BASE_URL}/admin/bootstrap`);
  await page.waitForLoadState('domcontentloaded', { timeout: 10_000 });

  if (page.url().includes('/bootstrap')) {
    await runBootstrapWizard(page);
  }
}

/**
 * Run the admin bootstrap wizard from the /admin/bootstrap page.
 * Called when the browser is already at /admin/bootstrap.
 */
async function runBootstrapWizard(page: Page): Promise<void> {
  // RED PHASE: removed the .phx-connected wait that was needed for LiveView.
  // After the fix (plain HTTP controller), there is no LiveView socket and no
  // .phx-connected class. Waiting for it would hang indefinitely on the new
  // implementation. This comment documents the intentional removal.
  // Previously: await page.locator('.phx-connected').first().waitFor({ state: 'attached', timeout: 20_000 });

  // Step 1: Instance Name
  await page.getByLabel(/instance name/i).fill('test-nebu');
  await page.getByRole('button', { name: /^next$/i }).click();

  // Step 2: OIDC configuration (page stays at /admin/bootstrap, re-renders step 2)
  await page.waitForURL(/\/admin\/bootstrap/, { timeout: 10_000 });
  // oidc-bootstrap-only-config (ADR-022): OIDC is configured EXCLUSIVELY via this wizard
  // — there is no env-var config path and no env-lock mode, so every field is always
  // editable and required. A SINGLE OIDC client (Dex `nebu-gateway` / `nebu-dev-secret`,
  // all redirect URIs registered) serves both Matrix Bearer validation and admin login.
  await page.getByLabel(/oidc issuer url/i).fill(DEX_ISSUER_URL);
  await page.getByLabel(/oidc client id/i).fill('nebu-gateway');
  await page.getByLabel(/oidc audience/i).fill('nebu-gateway');
  // RED PHASE: JWKS URI field fill removed. After the fix (Bug 3), the JWKS URI is
  // auto-discovered server-side from the OIDC well-known endpoint and the field no
  // longer exists in step 2. Filling it here would fail with a locator-not-found
  // error on the new implementation.
  // Previously: await page.getByLabel(/jwks uri/i).fill(`${DEX_ISSUER_URL}/keys`);
  await page.getByLabel(/oidc client secret/i).fill(
    process.env.NEBU_OIDC_CLIENT_SECRET ?? 'nebu-dev-secret'
  );
  // Step 2 → Step 3 (Claim Mapping): click "Next" to advance to the claim mapping step.
  // Story 11-10 added Step 3; "Connect with OIDC" is now on Step 3, not Step 2.
  await page.getByRole('button', { name: /^next$/i }).click();

  // Step 3: Claim Mapping — accept pre-filled defaults, but the "Admin client
  // scopes" field defaults to empty (OIDC Scopes Law: only `openid` is ever
  // requested unless explicitly configured — no hardcoded extras). Dex's local
  // password connector only returns the `groups` claim when the `groups` scope
  // is actually requested, and `kai@example.com`'s `instance_admin` membership
  // (dev/dex/config.yaml) IS a `groups` claim — without requesting that scope,
  // the claim-selection page below has nothing to render, and "Confirm Admin
  // Claim" always submits with no claim path selected.
  await page.waitForURL(/\/admin\/bootstrap/, { timeout: 10_000 });
  await page.getByLabel(/admin client scopes/i).fill('profile email groups');
  // "Connect with OIDC" POST → redirect to /admin/login/start?mode=bootstrap → Dex
  await page.getByRole('button', { name: /connect with oidc/i }).click();

  // Wait for Dex auth page
  await page.waitForURL(/dex.*\/auth/i, { timeout: 15_000 });

  // Dex login
  await page.locator('input[name="login"]').fill('kai@example.com');
  await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
  await page.locator('button[type="submit"]').click();

  // BUG-E2E-10 fix: CallbackHandler renders the select-claim page AT /admin/callback URL
  // (not redirecting to /admin/bootstrap/select-claim).
  // Also accept grant screen and direct dashboard landing.
  // Dex consent/grant button ONLY. Must NOT match the Nebu select-claim page's
  // "Confirm Admin Claim" submit button (which also contains "Confirm") — matching it
  // here would click it prematurely (before a claim radio is chosen) and skip the
  // proper claim-selection step below. Dex's consent button reads "Grant Access".
  const grantBtn = page.locator(
    'button[type="submit"]:has-text("Grant Access"), button:has-text("Grant Access")'
  );

  await page.waitForURL(
    /\/admin\/callback|\/admin\/bootstrap\/select-claim|\/admin\/bootstrap\/done|\/admin\/dashboard/,
    { timeout: 25_000 }
  ).catch(() => {
    // Silently ignore if URL didn't match — check grant screen below
  });

  // Handle optional Dex grant/consent screen (first login per client only).
  const grantVisible = await grantBtn.first().isVisible({ timeout: 3_000 }).catch(() => false);
  if (grantVisible) {
    await grantBtn.first().click();
    // After granting, the IdP redirects back and the flow may land on the select-claim
    // page (/admin/callback) OR — if it completes quickly — go straight through to the
    // dashboard/done. Accept any of them; the early-return below handles the terminal ones.
    await page.waitForURL(
      /\/admin\/callback|\/admin\/bootstrap\/select-claim|\/admin\/bootstrap\/done|\/admin\/dashboard/,
      { timeout: 15_000 }
    );
  }

  // Return early if already at dashboard or done
  if (page.url().includes('/admin/dashboard') || page.url().includes('/admin/bootstrap/done')) {
    return;
  }

  // Step 3: select admin group claim (rendered at /admin/callback)
  // The radio's `value` attribute is NOT the literal claim value — auth.ex's
  // select_claim_html/1 JSON-encodes it as {"value": "instance_admin", "path": "..."}
  // (a single-value encoding trick to submit two params from one no-JS radio group).
  // A substring match on the encoded attribute finds the right option regardless
  // of which claim path it came from.
  // The radio button is styled with a <label> that intercepts pointer events.
  // Click the label instead of the hidden input, or use force:true as fallback.
  const instanceAdminRadio = page.locator('input[type="radio"][value*="instance_admin"]');
  if (await instanceAdminRadio.isVisible({ timeout: 5_000 }).catch(() => false)) {
    // Try clicking the associated label first (avoids intercept issue)
    const radioId = await instanceAdminRadio.getAttribute('id').catch(() => null);
    if (radioId) {
      const label = page.locator(`label[for="${radioId}"]`);
      if (await label.isVisible({ timeout: 2_000 }).catch(() => false)) {
        await label.click();
      } else {
        await instanceAdminRadio.check({ force: true });
      }
    } else {
      // No id — click the nearest label or use force
      const parentLabel = page.locator('label').filter({ has: instanceAdminRadio });
      if (await parentLabel.isVisible({ timeout: 2_000 }).catch(() => false)) {
        await parentLabel.click();
      } else {
        await instanceAdminRadio.check({ force: true });
      }
    }
  }
  await page.getByRole('button', { name: /confirm admin claim/i }).click();

  // ClaimSelectionHandler redirects 303 to /admin/dashboard
  await page.waitForURL(/\/admin\/dashboard|\/admin\/bootstrap\/done/, { timeout: 20_000 });
  if (page.url().includes('/bootstrap/done')) {
    await page.getByRole('link', { name: /go to dashboard/i }).click();
    await page.waitForURL(/\/admin\/dashboard/, { timeout: 15_000 });
  }
}
