/**
 * Step definitions for the admin-ui-migration story (Admin UI rooms page + auth gate).
 *
 * Features:
 *   - features/admin/admin-ui-liveview.feature     (AC1 — rooms list + toggles)
 *   - features/admin/admin-ui-auth-gate.feature    (AC3 — admin claim gate)
 *
 * NOTE (admin-http-refactor): RoomsLive was CONVERTED to RoomsController. /admin/rooms is
 * now plain server-rendered HTML — the auto-join toggle is a per-row <form method="post">
 * button on the LIST page (role="switch", aria-label="Auto-join <name>"), and create-room
 * lives on a separate /admin/rooms/new page. The former AC2 "live DOM-diff toggle" feature
 * (admin-ui-room-toggle.feature) was rewritten to the controller contract and now reuses the
 * list-page toggle steps in admin/auto-join-rooms.steps.ts — its bespoke steps (detail-page
 * navigation, "no full page reload" sentinel) were removed from this file.
 *
 * REUSE: The following steps are already defined elsewhere and are intentionally NOT
 * redefined here (Cucumber would error on a duplicate):
 *   - "the Nebu stack is running"            → common/stack-health.steps.ts
 *   - "bootstrap has been completed"         → admin/bootstrap.steps.ts
 *   - "the operator is logged in as admin"   → admin/bootstrap.steps.ts
 *   - "the operator navigates to {string}"   → admin/bootstrap.steps.ts
 *   - "the page shows {string}"              → admin/bootstrap.steps.ts
 *   - "the room list contains at least one entry" → admin/rooms.steps.ts
 *   - "a room named {string} exists in the system" → admin/auto-join-rooms.steps.ts
 *   - "room {string} has auto-join disabled" / list-page toggle steps → admin/auto-join-rooms.steps.ts
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 * OIDC: Authorization Code + PKCE via Dex only (no ROPC) — per CLAUDE.md.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { DEX_TEST_PASSWORD } from '../../fixtures/users';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// A Dex test user WITHOUT the admin group claim. The fixtures use "kai" as the admin;
// "alex" is a regular user and must be rejected by the admin claim gate.
const NON_ADMIN_EMAIL = process.env.NEBU_NON_ADMIN_EMAIL ?? 'alex@example.com';

// ─── AC1 assertions ───────────────────────────────────────────────────────────

Then(
  'each room row shows an auto-join toggle control',
  async ({ page }: { page: Page }) => {
    // Every room entry must expose a per-room auto-join toggle. The converted controller
    // renders it as a form-POST button [data-role="auto-join-toggle"].
    const toggles = page.locator('[data-role="auto-join-toggle"]');
    await expect(toggles.first()).toBeVisible({ timeout: 15_000 });
    expect(await toggles.count()).toBeGreaterThan(0);
  }
);

Then(
  'the page is served by the Phoenix LiveView admin app',
  async ({ page }: { page: Page }) => {
    // STALE-SPEC REWRITE: RoomsLive was CONVERTED to RoomsController (admin-http-refactor),
    // so /admin/rooms is now a plain server-rendered admin page with NO LiveView socket —
    // it carries none of the data-phx-* attributes the old LiveView assertion looked for.
    // AC1's intent ("the rooms page is served by the admin app") is preserved by asserting
    // the controller-rendered rooms page marker instead.
    await expect(page.locator('[data-page="rooms"]')).toBeVisible({ timeout: 15_000 });
    await expect(page).toHaveURL(/\/admin\/rooms/, { timeout: 15_000 });
  }
);

// ─── AC3: admin claim gate ─────────────────────────────────────────────────────

Given('a non-admin user is logged in via OIDC', async ({ page }: { page: Page }) => {
  // Real Authorization Code + PKCE flow via Dex for a user WITHOUT the admin claim.
  // No cookie forging, no DB seeding. Start the admin login, authenticate at Dex as
  // the non-admin user. The admin gate decides the outcome (asserted in the Then step).
  await page.context().clearCookies();
  await page.goto(`${ADMIN_BASE_URL}/admin/login/start`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});

  let url = page.url();

  // If we landed on the admin login page, click SSO to start the Dex flow.
  if (url.includes('/admin/login') && !/dex.*\/auth/i.test(url)) {
    const ssoLink = page.getByRole('link', { name: /login with sso|sign in with sso/i });
    if (await ssoLink.isVisible({ timeout: 3_000 }).catch(() => false)) {
      await ssoLink.click();
    } else {
      await page.getByRole('button', { name: /login with sso|sign in with sso/i }).click();
    }
    await page.waitForURL(/dex.*\/auth/i, { timeout: 15_000 }).catch(() => {});
    url = page.url();
  }

  // Authenticate at Dex as the non-admin user.
  if (/dex.*\/auth/i.test(url)) {
    await page.locator('input[name="login"]').fill(NON_ADMIN_EMAIL);
    await page.locator('input[name="password"]').fill(DEX_TEST_PASSWORD);
    await page.locator('button[type="submit"]').click();
    const grantBtn = page.locator(
      'button[type="submit"]:has-text("Grant"), button[type="submit"]:has-text("Confirm")'
    );
    if (await grantBtn.first().isVisible({ timeout: 8_000 }).catch(() => false)) {
      await grantBtn.first().click();
    }
    // Let the callback settle. The admin gate may 403 here or in the subsequent navigation.
    await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});
  }
});

Then(
  'the admin area access is denied with 403 or a redirect to the admin login',
  async ({ page }: { page: Page }) => {
    // The admin claim gate must NOT grant access to a non-admin. Acceptable outcomes:
    //   (a) an HTTP 403 page, or
    //   (b) a redirect to /admin/login (or a forbidden/error page),
    // and in NO case the actual admin dashboard / rooms management content.
    const url = page.url();
    const bodyText = (await page.locator('body').innerText().catch(() => '')) ?? '';

    const redirectedToLogin = /\/admin\/login/.test(url) || /\/forbidden|\/error|\/403/.test(url);
    const showsForbidden = /403|forbidden|not authorized|access denied/i.test(bodyText);

    // Must not be sitting on a working admin management view.
    const onAdminContent =
      /\/admin\/(?:dashboard|rooms|users|config|compliance|audit)\b/.test(url) &&
      !showsForbidden &&
      !redirectedToLogin;

    expect(
      (redirectedToLogin || showsForbidden) && !onAdminContent,
      `Non-admin must be denied. url=${url} forbidden=${showsForbidden} login=${redirectedToLogin}`
    ).toBe(true);
  }
);

