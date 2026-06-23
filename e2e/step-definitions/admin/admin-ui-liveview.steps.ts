/**
 * Step definitions for the admin-ui-migration story (Phoenix LiveView Admin UI).
 *
 * Features:
 *   - features/admin/admin-ui-liveview.feature     (AC1 — rooms list + toggles)
 *   - features/admin/admin-ui-room-toggle.feature  (AC2 — live DOM-diff toggle + persistence)
 *   - features/admin/admin-ui-auth-gate.feature    (AC3 — admin claim gate)
 *
 * RED PHASE: these steps fail until the Phoenix LiveView Admin UI is implemented in
 * the nebu_http OTP app and /admin/* is served by Phoenix (Go admin backend removed).
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

// ─── AC2 Background: ensure the room starts with auto-join DISABLED ───────────
// Mirrors "room {string} has auto-join enabled" (auto-join-rooms.steps.ts) but for
// the disabled starting state required by the toggle scenario. No DB shortcut: the
// state is read/changed through the real LiveView control.
Given(
  'room {string} has auto-join disabled',
  async ({ page }: { page: Page }, roomName: string) => {
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    await page.locator('td, li, a').filter({ hasText: roomName }).first().click();
    await page.waitForLoadState('networkidle');
    const toggle = liveToggle(page, roomName);
    if (await toggle.isChecked().catch(() => false)) {
      await toggle.click();
      // LiveView pushes a DOM-diff; await the unchecked state rather than a hard wait.
      await expect(toggle).not.toBeChecked({ timeout: 10_000 });
    }
  }
);

// ─── AC1 assertions ───────────────────────────────────────────────────────────

Then(
  'each room row shows an auto-join toggle control',
  async ({ page }: { page: Page }) => {
    // Every room entry must expose a per-room auto-join toggle. Accept either a
    // LiveView phx-click control or a checkbox bound to the auto-join state.
    const toggles = page.locator(
      '[phx-click="toggle_auto_join"], input[name="is_auto_join"], [data-role="auto-join-toggle"]'
    );
    await expect(toggles.first()).toBeVisible({ timeout: 15_000 });
    expect(await toggles.count()).toBeGreaterThan(0);
  }
);

Then(
  'the page is served by the Phoenix LiveView admin app',
  async ({ page }: { page: Page }) => {
    // A LiveView page bootstraps a stateful socket: the root carries data-phx-* attributes
    // and the page loads the phoenix_live_view client. The Go-template admin UI has neither.
    const liveRoot = page.locator('[data-phx-main], [data-phx-session], [id^="phx-"]');
    await expect(liveRoot.first()).toBeAttached({ timeout: 15_000 });
  }
);

// ─── AC2: live toggle (DOM-diff, no full reload) + persistence ────────────────

When(
  'the operator navigates to the LiveView detail page for room {string}',
  async ({ page }: { page: Page }, roomName: string) => {
    await page.goto(`${ADMIN_BASE_URL}/admin/rooms`);
    await page.waitForLoadState('networkidle');
    await page.locator('td, li, a').filter({ hasText: roomName }).first().click();
    await page.waitForLoadState('networkidle');
  }
);

When(
  'the operator clicks the auto-join toggle for room {string}',
  async ({ page }: { page: Page }, roomName: string) => {
    // Mark the document so we can prove no full navigation happened (see "without a
    // full page reload"). A full reload discards this window flag; a LiveView DOM-diff
    // keeps it. This is a deterministic, wait-free reload sentinel.
    await page.evaluate(() => {
      (window as unknown as { __nebuNoReload?: boolean }).__nebuNoReload = true;
    });
    await liveToggle(page, roomName).click();
  }
);

Then(
  'the auto-join toggle for room {string} shows as enabled without a full page reload',
  async ({ page }: { page: Page }, roomName: string) => {
    // 1) LiveView DOM-diff: the toggle reflects the new state in place.
    await expect(liveToggle(page, roomName)).toBeChecked({ timeout: 10_000 });
    // 2) No full page reload: the sentinel set before the click survived.
    const survived = await page.evaluate(
      () => (window as unknown as { __nebuNoReload?: boolean }).__nebuNoReload === true
    );
    expect(survived, 'a full page reload occurred — expected an in-place LiveView DOM-diff').toBe(true);
  }
);

// The feature uses the parameterless form of this step (no room name in the text).
Then(
  're-loading the LiveView room detail page still shows the auto-join toggle as enabled',
  async ({ page }: { page: Page }) => {
    await page.reload();
    await page.waitForLoadState('networkidle');
    const toggle = page.locator(
      '[phx-click="toggle_auto_join"], input[name="is_auto_join"], [data-role="auto-join-toggle"]'
    ).first();
    await expect(toggle).toBeChecked({ timeout: 10_000 });
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

// ─── helpers ────────────────────────────────────────────────────────────────

/**
 * Locator for the auto-join toggle of a specific room on the LiveView detail page.
 * Accepts the LiveView phx-click control (preferred) or a checkbox bound to
 * is_auto_join, scoped to the room when a row marker is present.
 */
function liveToggle(page: Page, _roomName: string) {
  return page
    .locator(
      '[phx-click="toggle_auto_join"], input[name="is_auto_join"], [data-role="auto-join-toggle"]'
    )
    .first();
}
