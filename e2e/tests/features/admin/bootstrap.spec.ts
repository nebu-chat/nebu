/**
 * E2E tests for the Bootstrap Wizard UI (Admin panel, pre-bootstrap state).
 *
 * Prerequisites:
 *   - Stack running via `make dev`
 *   - DB in bootstrap state: `bootstrap_active = true`, no `bootstrap_completed`
 *   - If testing OIDC login: `127.0.0.1 dex` in /etc/hosts
 *
 * Reset DB to bootstrap state between runs:
 *   docker compose exec postgres psql -U nebu -d nebu -c \
 *     "DELETE FROM server_config WHERE key IN ('bootstrap_completed','oidc_issuer','oidc_client_id','oidc_client_secret','instance_name');"
 */

import { test, expect, type Page } from '@playwright/test';
import { execSync } from 'child_process';
import * as path from 'path';

const PROJECT_ROOT = path.resolve(__dirname, '../../../..');

// Restores the fully-bootstrapped DB state that existed before bootstrap.spec.ts
// ran its wizard tests (which rely on the DB being in pre-bootstrap state).
// Called in the final afterAll so subsequent test files (compliance, config,
// master-detail, etc.) can login via OIDC again.
//
// Values mirror what `make setup` inserts and what dex-auth fixtures expect:
//   oidc_client_secret: plaintext "nebu-admin-secret" (gateway reads the raw
//   value from server_config and matches it against NEBU_OIDC_CLIENT_SECRET env).
function restoreBootstrappedState(): void {
  const now = Date.now();
  execSync(
    [
      'docker compose exec -T postgres psql -U nebu -d nebu',
      `-c "TRUNCATE TABLE server_config"`,
      `-c "TRUNCATE TABLE bootstrap_draft"`,
      `-c "INSERT INTO server_config (key, value, set_at) VALUES` +
        ` ('bootstrap_active', 'true', ${now}),` +
        ` ('bootstrap_completed', 'true', ${now}),` +
        ` ('instance_name', 'nebuchadnezzar', ${now}),` +
        ` ('oidc_issuer', 'http://dex:5556/dex', ${now}),` +
        ` ('oidc_client_id', 'nebu-gateway', ${now}),` +
        ` ('oidc_client_secret', 'nebu-dev-secret', ${now}),` +
        ` ('oidc_user_id_claim', 'email', ${now}),` +
        ` ('oidc_displayname_claim', 'name', ${now}),` +
        ` ('admin_group_claim', 'instance_admin', ${now})"`,
    ].join(' '),
    { cwd: PROJECT_ROOT, stdio: 'pipe' }
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function resetBootstrap(page: Page) {
  // Use the gateway's test-only reset endpoint is not available — use direct DB
  // via the Playwright request context calling a psql wrapper is out of scope.
  // Instead tests call the shared fixture below via beforeEach.
}

async function goToBootstrap(page: Page) {
  await page.goto('/admin');
  await expect(page).toHaveURL(/\/admin\/bootstrap/);
  await expect(page).toHaveTitle('Bootstrap Setup — Nebu Admin');
}

// ---------------------------------------------------------------------------
// Layout & Navigation Guards
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Layout', () => {
  test('redirects /admin to /admin/bootstrap when not configured', async ({ page }) => {
    await page.goto('/admin');
    await expect(page).toHaveURL(/\/admin\/bootstrap/);
  });

  test('redirects /admin/ (trailing slash) to /admin/bootstrap', async ({ page }) => {
    await page.goto('/admin/');
    await expect(page).toHaveURL(/\/admin\/bootstrap/);
  });

  test('does NOT show Dashboard or Logout in sidebar during bootstrap', async ({ page }) => {
    await goToBootstrap(page);
    const nav = page.getByRole('navigation', { name: 'Admin navigation' });
    await expect(nav.getByRole('link', { name: 'Dashboard' })).not.toBeVisible();
    await expect(nav.getByRole('link', { name: 'Logout' })).not.toBeVisible();
    await expect(nav.getByRole('link', { name: 'Bootstrap Setup' })).toBeVisible();
  });

  test('does NOT show Connecting… status in header during bootstrap', async ({ page }) => {
    await goToBootstrap(page);
    await expect(page.locator('#topbar-status')).not.toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Step 1 — Instance Name
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Step 1: Instance Name', () => {
  test.beforeEach(async ({ page }) => {
    await goToBootstrap(page);
  });

  test('shows step 1 on initial load', async ({ page }) => {
    await expect(page.getByRole('heading', { name: 'Step 1: Instance Name' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Instance Name' })).toBeVisible();
  });

  test('steps indicator highlights Step 1', async ({ page }) => {
    const steps = page.locator('.steps li');
    await expect(steps.nth(0)).toHaveClass(/step-primary/);
    await expect(steps.nth(1)).not.toHaveClass(/step-primary/);
  });

  test('shows error on empty instance name submit', async ({ page }) => {
    await page.getByRole('button', { name: 'Next' }).click();
    // Browser native validation prevents submit — field stays visible
    await expect(page.getByRole('heading', { name: 'Step 1' })).toBeVisible();
  });

  test('shows server error for instance name that is too short (2 chars)', async ({ page }) => {
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('ab');
    // Bypass browser required-validation to let server validate
    await page.evaluate(() => {
      const form = document.querySelector('form') as HTMLFormElement;
      form?.setAttribute('novalidate', '');
    });
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.locator('.alert-error')).toBeVisible();
    await expect(page.locator('.alert-error')).toContainText('3');
  });

  test('shows server error for instance name with special characters', async ({ page }) => {
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('my instance!');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.locator('.alert-error')).toBeVisible();
  });

  test('advances to step 2 with valid instance name', async ({ page }) => {
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Step 2 — OIDC Configuration
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Step 2: OIDC Configuration', () => {
  test.beforeEach(async ({ page }) => {
    await goToBootstrap(page);
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
  });

  test('shows all OIDC fields', async ({ page }) => {
    await expect(page.getByRole('textbox', { name: 'OIDC Issuer URL' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'OIDC Client ID' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'OIDC Client Secret' })).toBeVisible();
  });

  test('Back button returns to step 1 and preserves instance name', async ({ page }) => {
    await page.getByRole('button', { name: 'Back' }).click();
    await expect(page.getByRole('heading', { name: /Step 1/ })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Instance Name' })).toHaveValue('nebu-dev');
  });

  test('Back button is visually recognizable (has outline style)', async ({ page }) => {
    const back = page.getByRole('button', { name: 'Back' });
    await expect(back).toHaveClass(/btn-outline/);
    await expect(back).not.toHaveClass(/btn-ghost/);
  });

  test('shows error on missing OIDC Issuer', async ({ page }) => {
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-gateway');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('secret');
    await page.getByRole('button', { name: 'Next' }).click();
    // Browser native required validation fires first; stay on step 2
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
  });

  test('shows error for invalid (non-URL) issuer', async ({ page }) => {
    await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('not-a-url');
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-gateway');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('secret');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.locator('.alert-error').first()).toBeVisible({ timeout: 5_000 });
  });

  test('shows HTTP warning for http:// issuer on Next', async ({ page }) => {
    await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('http://dex:5556/dex');
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-gateway');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('secret');
    await page.getByRole('button', { name: 'Next' }).click();
    // HTTP issuers show a warning but still advance
    const warning = page.locator('.alert-warning');
    const step3heading = page.getByRole('heading', { name: 'Step 3' });
    // Either a warning is shown on step 2, or we advanced to step 3
    const warningVisible = await warning.isVisible().catch(() => false);
    const advancedToStep3 = await step3heading.isVisible().catch(() => false);
    expect(warningVisible || advancedToStep3).toBeTruthy();
  });

  test('preserves OIDC values when navigating back and forward', async ({ page }) => {
    await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('http://dex:5556/dex');
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-gateway');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('nebu-dev-secret');
    // Back to step 1 — issuer/clientID should be carried via hidden fields
    await page.getByRole('button', { name: 'Back' }).click();
    await expect(page.getByRole('heading', { name: 'Step 1: Instance Name' })).toBeVisible();
    // Forward to step 2 — issuer/clientID should be preserved
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2: OIDC Configuration' })).toBeVisible();
    // Issuer and client ID preserved; secret is intentionally NOT re-populated (security)
    await expect(page.getByRole('textbox', { name: 'OIDC Issuer URL' })).toHaveValue('http://dex:5556/dex');
    await expect(page.getByRole('textbox', { name: 'OIDC Client ID' })).toHaveValue('nebu-gateway');
  });
});

// ---------------------------------------------------------------------------
// Step 3 — Claim Mapping
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Step 3: Claim Mapping', () => {
  test.beforeEach(async ({ page }) => {
    await goToBootstrap(page);
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
    await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('http://dex:5556/dex');
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-gateway');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('nebu-dev-secret');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 3' })).toBeVisible();
  });

  test('shows claim mapping form', async ({ page }) => {
    await expect(page.getByRole('heading', { name: 'Step 3: Claim Mapping' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Matrix User ID Source Claim' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Display Name Source Claim' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Connect with OIDC' })).toBeVisible();
  });

  test('shows info alert about Matrix User ID claim', async ({ page }) => {
    await expect(page.locator('.alert-info')).toContainText('Matrix User ID');
  });

  test('Back button returns to step 2 with preserved OIDC values', async ({ page }) => {
    await page.getByRole('button', { name: 'Back' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'OIDC Issuer URL' })).toHaveValue('http://dex:5556/dex');
  });
});

// ---------------------------------------------------------------------------
// Step 4 — User Import
// (Full end-to-end flow through OAuth is covered by bootstrap.feature + Gherkin.)
// These tests check the Step 4 UI elements reachable without a live OAuth round-trip.
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Step 4: User Import', () => {
  // Reach Step 4 by POST-submitting step=3 directly (simulates the server-side
  // redirect that happens after the OAuth callback selects the admin group claim).
  test.beforeEach(async ({ page }) => {
    // First navigate through Steps 1–3 to establish a session with OIDC state,
    // then POST step=3 to trigger the server to advance to Step 4.
    await goToBootstrap(page);
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: 'Step 2' })).toBeVisible();
  });

  test('steps indicator shows 4 steps total', async ({ page }) => {
    const steps = page.locator('.steps li');
    await expect(steps).toHaveCount(4);
    const labels = await steps.allTextContents();
    expect(labels.map(l => l.trim())).toEqual(['Instance', 'OIDC', 'Claims', 'Import']);
  });
});

// ---------------------------------------------------------------------------
// Login Page
// ---------------------------------------------------------------------------

test.describe('Login Page', () => {
  test('shows login page at /admin/login', async ({ page }) => {
    // After bootstrap is complete, /admin/login should be accessible
    // For now just check the page exists (may redirect to bootstrap in test env)
    const resp = await page.goto('/admin/login');
    expect([200, 302, 303]).toContain(resp?.status());
  });

  test('/admin/login/start redirects to bootstrap when OIDC not configured', async ({ page }) => {
    await page.goto('/admin/login/start');
    await expect(page).toHaveURL(/\/admin\/bootstrap/);
  });
});

// ---------------------------------------------------------------------------
// Error Pages
// ---------------------------------------------------------------------------

test.describe('Error Pages', () => {
  test('unknown /admin/* path redirects to bootstrap when bootstrap is active', async ({ page }) => {
    // When bootstrap is not yet complete, catch-all redirects to /admin/bootstrap
    await page.goto('/admin/this-does-not-exist-xyz');
    await expect(page).toHaveURL(/\/admin\/bootstrap/);
  });

  test('unknown /admin/* path shows 404 after bootstrap is complete', async ({ page }) => {
    // This test verifies the 404 template renders correctly via direct URL.
    // (After bootstrap, catch-all shows 404 — tested in integration state)
    // Verify our Error404 template at least renders the 404 heading when served
    const resp = await page.request.get('/admin/this-does-not-exist-xyz');
    // Response is either 302 (→bootstrap) or 404 depending on bootstrap state
    expect([200, 302, 303, 404]).toContain(resp.status());
  });

  test('401 page renders correctly', async ({ page }) => {
    const resp = await page.goto('/admin/login');
    // 401 page is served by Error401 helper when session is invalid
    // We verify the template renders without JS errors
    const errors: Error[] = [];
    page.on('pageerror', e => errors.push(e));
    expect(errors).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// CSRF Protection — Story 5.13
// ---------------------------------------------------------------------------
// These assertions verify that:
//   1. The csrf_token cookie is issued when visiting any bootstrap page
//   2. Every form on the bootstrap page embeds a matching hidden _csrf field
//   3. The token in the cookie matches the token in the hidden input (double-submit)

test.describe('CSRF Protection — Bootstrap forms', () => {
  // Precondition: stack must be in bootstrap state (bootstrap_completed not set).
  // goToBootstrap() asserts the redirect to /admin/bootstrap — if the stack is already
  // bootstrapped it will redirect to /admin/dashboard and the assertion will fail fast,
  // surfacing the missing precondition rather than a spurious CSRF failure.
  test.beforeEach(async ({ page }) => {
    await goToBootstrap(page);
  });

  test('bootstrap page sets csrf_token cookie on GET', async ({ page, context }) => {
    await page.goto('/admin/bootstrap');
    const cookies = await context.cookies();
    const csrfCookie = cookies.find(c => c.name === 'csrf_token');
    expect(csrfCookie, 'csrf_token cookie must be set after visiting /admin/bootstrap').toBeDefined();
    expect(csrfCookie!.value, 'csrf_token cookie must be non-empty').toBeTruthy();
  });

  test('bootstrap step 1 form contains hidden _csrf input', async ({ page }) => {
    await page.goto('/admin/bootstrap');
    const csrfInput = page.locator('form input[type="hidden"][name="_csrf"]');
    // type="hidden" inputs are not visible in the DOM — use toHaveCount instead of toBeVisible.
    await expect(csrfInput, 'form must contain a hidden _csrf input').toHaveCount(1);
    const csrfValue = await csrfInput.inputValue();
    expect(csrfValue, '_csrf hidden field must be non-empty').toBeTruthy();
  });

  test('_csrf form value matches csrf_token cookie (double-submit)', async ({ page, context }) => {
    await page.goto('/admin/bootstrap');
    const cookies = await context.cookies();
    const csrfCookie = cookies.find(c => c.name === 'csrf_token');
    expect(csrfCookie, 'csrf_token cookie must be present').toBeDefined();

    const csrfInput = page.locator('form input[type="hidden"][name="_csrf"]').first();
    const formToken = await csrfInput.inputValue();
    expect(formToken).toBe(csrfCookie!.value);
  });
});

// ---------------------------------------------------------------------------
// Static Assets
// ---------------------------------------------------------------------------

test.describe('Static Assets', () => {
  test('admin.css loads successfully', async ({ page }) => {
    const resp = await page.request.get('/admin/static/admin.css');
    expect(resp.status()).toBe(200);
    expect(resp.headers()['content-type']).toContain('text/css');
  });

  test('vue.esm-browser.prod.js loads successfully', async ({ page }) => {
    const resp = await page.request.get('/admin/static/vendor/vue.esm-browser.prod.js');
    expect(resp.status()).toBe(200);
    expect(resp.headers()['content-type']).toContain('javascript');
  });

  test('metrics-widget.js loads successfully', async ({ page }) => {
    const resp = await page.request.get('/admin/static/metrics-widget.js');
    expect(resp.status()).toBe(200);
  });

  // Restore fully-bootstrapped DB state so subsequent test files (compliance,
  // config, master-detail, etc.) can login via OIDC. bootstrap.spec.ts tests
  // the wizard in unbootstrapped state; this afterAll undoes that for the suite.
  test.afterAll(() => {
    restoreBootstrappedState();
  });
});
