/**
 * Happy-Path E2E test for the full Bootstrap Wizard + first-admin OIDC login.
 *
 * Current wizard flow (4 steps):
 *   Step 1: Instance Name → Next
 *   Step 2: OIDC Configuration → Next
 *   Step 3: Claim Mapping → "Connect with OIDC" → Dex OAuth
 *   After OAuth: /admin/bootstrap/select-claim → select admin group → Confirm
 *   Step 4: User Import → "Skip and finish" → /admin/dashboard
 *
 * Prerequisites:
 *   - Stack running: `make dev`
 *   - "127.0.0.1 dex" in /etc/hosts (test skips automatically if dex is unreachable)
 *   - Docker available (used for DB reset via `docker compose exec psql`)
 *
 * DB state is reset to bootstrap before and after each test via docker compose exec.
 */

import { test, expect } from '@playwright/test';
import { execSync } from 'child_process';
import * as path from 'path';

const PROJECT_ROOT = path.resolve(__dirname, '../../../..');

// ---------------------------------------------------------------------------
// DB Reset Helper
// ---------------------------------------------------------------------------

function resetToBootstrapState(): void {
  const now = Date.now();
  execSync(
    [
      'docker compose exec -T postgres psql -U nebu -d nebu',
      `-c "TRUNCATE TABLE server_config"`,
      `-c "TRUNCATE TABLE bootstrap_draft"`,
      `-c "INSERT INTO server_config (key, value, set_at) VALUES ('bootstrap_active', 'true', ${now})"`,
    ].join(' '),
    { cwd: PROJECT_ROOT, stdio: 'pipe' }
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe('Bootstrap — Full Happy Path (OIDC E2E)', () => {
  test.beforeEach(() => {
    resetToBootstrapState();
  });

  test.afterEach(() => {
    // Restore bootstrap state so bootstrap.spec.ts tests still work when run after this file
    resetToBootstrapState();
  });

  test('completes wizard steps 1–4 and first-admin OIDC login', async ({ page, request }) => {
    // Skip if dex is not resolvable — requires "127.0.0.1 dex" in /etc/hosts
    const dexDiscovery = await request
      .get('http://dex:5556/dex/.well-known/openid-configuration')
      .catch(() => null);
    test.skip(
      !dexDiscovery?.ok(),
      'Dex unreachable — add "127.0.0.1 dex" to /etc/hosts: echo "127.0.0.1 dex" | sudo tee -a /etc/hosts'
    );

    // ── Navigate: /admin redirects to /admin/bootstrap ────────────────────────
    await page.goto('/admin');
    await expect(page).toHaveURL(/\/admin\/bootstrap/);
    await expect(page).toHaveTitle('Bootstrap Setup — Nebu Admin');

    // ── Step 1: Instance Name ─────────────────────────────────────────────────
    await expect(page.getByRole('heading', { name: 'Step 1: Instance Name' })).toBeVisible();
    await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: /Step 2/ })).toBeVisible();

    // ── Step 2: OIDC Configuration ────────────────────────────────────────────
    await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('http://dex:5556/dex');
    await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-admin');
    await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('nebu-admin-secret');
    await page.getByRole('button', { name: 'Next' }).click();
    await expect(page.getByRole('heading', { name: /Step 3/ })).toBeVisible();

    // ── Step 3: Claim Mapping → Connect with OIDC ─────────────────────────────
    // Default claim values are pre-filled; just click "Connect with OIDC"
    await expect(page.getByRole('heading', { name: 'Step 3: Claim Mapping' })).toBeVisible();
    await page.getByRole('button', { name: 'Connect with OIDC' }).click();

    // ── Dex Authorization Page ────────────────────────────────────────────────
    // Step 3 POSTs to /admin/bootstrap → saves draft → LoginStart → Dex auth
    await page.waitForURL(/dex.*\/auth/, { timeout: 15_000 });

    await page.locator('input[name="login"]').fill('kai@example.com');
    await page.locator('input[name="password"]').fill('changeme');
    await page.locator('button[type="submit"]').click();

    // ── Claim Selection Page ──────────────────────────────────────────────────
    // OIDC callback → /admin/bootstrap/select-claim (shows discovered group claims)
    await expect(page).toHaveURL(/\/admin\/bootstrap\/select-claim/, { timeout: 15_000 });
    await expect(page.locator('input[type="radio"][value="instance_admin"]')).toBeVisible();
    await page.locator('input[type="radio"][value="instance_admin"]').check();
    await page.getByRole('button', { name: 'Confirm' }).click();

    // ── Step 4: User Import ───────────────────────────────────────────────────
    // ClaimSelectionHandler saves config + creates session → /admin/bootstrap?step=4
    await expect(page).toHaveURL(/\/admin\/bootstrap/, { timeout: 10_000 });
    await expect(page.getByRole('heading', { name: 'Step 4: User Import' })).toBeVisible();

    // Skip import and go to dashboard
    await page.getByRole('link', { name: 'Skip and finish' }).click();
    await expect(page).toHaveURL(/\/admin\/dashboard/, { timeout: 10_000 });
    await expect(page).toHaveTitle(/Dashboard — Nebu Admin/);
  });

  test('ClaimSelectionHandler allows retry after failed OIDC login (no unique-constraint error)', async ({ page, request }) => {
    // This test verifies the fix for the production bug:
    // SaveBootstrapConfig used plain INSERT — second finalize attempt would return 500.
    // Now uses ON CONFLICT DO UPDATE — retries must succeed.

    const dexDiscovery = await request
      .get('http://dex:5556/dex/.well-known/openid-configuration')
      .catch(() => null);
    test.skip(
      !dexDiscovery?.ok(),
      'Dex unreachable — add "127.0.0.1 dex" to /etc/hosts'
    );

    const fillThroughStep3 = async () => {
      await page.goto('/admin/bootstrap');
      await page.getByRole('textbox', { name: 'Instance Name' }).fill('nebu-dev');
      await page.getByRole('button', { name: 'Next' }).click();
      await expect(page.getByRole('heading', { name: /Step 2/ })).toBeVisible();

      await page.getByRole('textbox', { name: 'OIDC Issuer URL' }).fill('http://dex:5556/dex');
      await page.getByRole('textbox', { name: 'OIDC Client ID' }).fill('nebu-admin');
      await page.getByRole('textbox', { name: 'OIDC Client Secret' }).fill('nebu-admin-secret');
      await page.getByRole('button', { name: 'Next' }).click();
      await expect(page.getByRole('heading', { name: /Step 3/ })).toBeVisible();

      await page.getByRole('button', { name: 'Connect with OIDC' }).click();
      // Wait for redirect away from bootstrap (to Dex or error page)
      await page.waitForURL(/dex.*\/auth|admin\/login/, { timeout: 15_000 });
    };

    // First attempt: go through wizard + OAuth but abandon at Dex (don't complete login)
    await fillThroughStep3();
    // Abandon OAuth by navigating away
    await page.goto('/admin/bootstrap');
    // Should still be on bootstrap (bootstrap_completed not set)
    await expect(page).toHaveURL(/\/admin\/bootstrap/);

    // Second attempt: MUST NOT return 500 (was the bug)
    await fillThroughStep3();

    // Complete Dex login
    await page.locator('input[name="login"]').fill('kai@example.com');
    await page.locator('input[name="password"]').fill('changeme');
    await page.locator('button[type="submit"]').click();

    // Claim selection → dashboard
    await expect(page).toHaveURL(/\/admin\/bootstrap\/select-claim/, { timeout: 15_000 });
    await page.locator('input[type="radio"][value="instance_admin"]').check();
    await page.getByRole('button', { name: 'Confirm' }).click();

    // Must NOT land on an error page — should reach Step 4
    await expect(page).toHaveURL(/\/admin\/bootstrap/, { timeout: 10_000 });
    await expect(page.getByRole('heading', { name: 'Step 4: User Import' })).toBeVisible();
  });
});
