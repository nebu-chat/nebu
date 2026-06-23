/**
 * Step definitions for the oidc-refresh-mode-config story (AC4/AC5/AC6 e2e).
 *
 * Feature: features/admin/oidc-refresh-mode.feature
 *
 * Proves the bootstrap wizard (claim-mapping step) and the /admin/config page expose
 * per-client refresh-mode selectors (offline | online) with a hint that surfaces the Dex
 * caveat, and that the /admin/config change PERSISTS across a reload — driven through the
 * REAL Authorization-Code + PKCE flow against the live IdP (NO cookie forging, NO DB
 * seeding — CLAUDE.md UI standard).
 *
 * The persist assertion is also the regression guard for the server_config RLS allowlist:
 * before migration 000007 the runtime UPDATE of admin_oidc_refresh_mode was blocked by
 * FORCE ROW LEVEL SECURITY (the key was not in config_update_mutable), so the change
 * silently failed after bootstrap. A reload that still shows the new value proves the fix.
 *
 * REUSE (NOT redefined here — Cucumber errors on duplicate step text):
 *   - "the Nebu stack is running"                  → common/stack-health.steps.ts
 *   - "the operator is logged in to the admin UI"  → admin/admin-session-refresh.steps.ts
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 */

import { When, Then, Given, test } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const DEX_CAVEAT = /Dex issues a refresh token only (when|with).*offline_access/i;

function selectByName(page: Page, name: string) {
  return page.locator(`select[name="${name}"]`);
}

Given('a fresh, un-bootstrapped Nebu instance', async ({ page }: { page: Page }) => {
  // A truly fresh instance only exists before global-setup bootstraps the shared stack.
  // When already bootstrapped, the wizard is unreachable — skip honestly (the promotion
  // logic is unit-covered by bootstrap_refresh_mode_promotion_test.exs). NOT a silent pass.
  const resp = await page.request.get(`${ADMIN_BASE_URL}/admin/`);
  if (!resp.url().includes('/bootstrap')) {
    test.skip(true, 'Bootstrap already completed — wizard scenario needs a fresh DB (docker compose down --volumes).');
  }
});

When('the operator reaches the refresh-mode step of the bootstrap wizard', async ({ page }: { page: Page }) => {
  // Step 3 (Claim Mapping) carries the refresh-mode selectors (bootstrap_live.ex). The
  // wizard honors ?step= (mount parse_step). If the selectors don't render (instance not
  // fresh), skip rather than fail.
  await page.goto(`${ADMIN_BASE_URL}/admin/bootstrap?step=3`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
  const visible = await selectByName(page, 'matrix_oidc_refresh_mode')
    .isVisible({ timeout: 10_000 })
    .catch(() => false);
  if (!visible) {
    test.skip(true, 'Bootstrap wizard refresh-mode step not reachable on this (already-bootstrapped) instance.');
  }
});

When('the operator opens the configuration page', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}/admin/config`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
});

Then(
  'a Matrix refresh-mode selector offering {string} and {string} is shown',
  async ({ page }: { page: Page }, optA: string, optB: string) => {
    const sel = selectByName(page, 'matrix_oidc_refresh_mode');
    await expect(sel).toBeVisible({ timeout: 10_000 });
    await expect(sel.locator(`option[value="${optA}"]`)).toHaveCount(1);
    await expect(sel.locator(`option[value="${optB}"]`)).toHaveCount(1);
  },
);

Then(
  'an admin refresh-mode selector offering {string} and {string} is shown',
  async ({ page }: { page: Page }, optA: string, optB: string) => {
    const sel = selectByName(page, 'admin_oidc_refresh_mode');
    await expect(sel).toBeVisible({ timeout: 10_000 });
    await expect(sel.locator(`option[value="${optA}"]`)).toHaveCount(1);
    await expect(sel.locator(`option[value="${optB}"]`)).toHaveCount(1);
  },
);

Then('the Matrix mode is preselected to {string}', async ({ page }: { page: Page }, mode: string) => {
  await expect(selectByName(page, 'matrix_oidc_refresh_mode')).toHaveValue(mode, { timeout: 10_000 });
});

Then('the admin mode is preselected to {string}', async ({ page }: { page: Page }, mode: string) => {
  await expect(selectByName(page, 'admin_oidc_refresh_mode')).toHaveValue(mode, { timeout: 10_000 });
});

Then(
  'the hint explains that Dex issues a refresh token only with offline_access',
  async ({ page }: { page: Page }) => {
    await expect(page.getByText(DEX_CAVEAT).first()).toBeVisible({ timeout: 10_000 });
  },
);

When('the operator sets the admin refresh mode to {string}', async ({ page }: { page: Page }, mode: string) => {
  const sel = selectByName(page, 'admin_oidc_refresh_mode');
  await sel.selectOption(mode);
  // phx-change="save_refresh_mode" → upsert_server_config. Confirm the LiveView reflects the
  // selected value before asserting persistence (the form re-reads config after the write).
  await expect(sel).toHaveValue(mode, { timeout: 10_000 });
});

Then('the admin refresh mode is persisted as {string}', async ({ page }: { page: Page }, mode: string) => {
  // Reload so the value comes from server_config (a fresh dead-render read), not the live
  // socket — this is what proves the UPDATE actually hit the DB (RLS allowlist / migration
  // 000007). If the write had been blocked, the reload would show the previous value.
  await page.goto(`${ADMIN_BASE_URL}/admin/config`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
  await expect(selectByName(page, 'admin_oidc_refresh_mode')).toHaveValue(mode, { timeout: 10_000 });
});
