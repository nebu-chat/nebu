/**
 * Step definitions for features/admin/device-management.feature
 *
 * Story S4 (epic: device-management) — ATDD, written FIRST (RED).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused (NOT redefined here — Cucumber errors on duplicates):
 *   - "the Nebu stack is running"    → common/stack-health.steps.ts
 *   - "bootstrap has been completed" → admin/bootstrap.steps.ts
 *   - "the operator is logged in as admin" → admin/bootstrap.steps.ts
 *
 * A real device is created for the target user by warming a real Matrix session
 * via getApiSession() (Authorization Code + PKCE under the hood, NO cookie forging,
 * NO DB seeding). That login registers a `devices` row for the user, which the
 * admin then views / renames / revokes through the real Admin UI.
 *
 * The per-user detail page (/admin/users/:user_id) Devices section:
 *   * [data-role="device-row"][data-device-id=...]   one row per device
 *   * [data-form="rename-device"][data-device-id=...] rename form (input name="display_name")
 *   * [data-role="revoke-device"][data-device-id=...] revoke control (Phoenix data-confirm)
 *   * [data-role="no-devices"]                         empty state
 *
 * RED: these steps fail until the dev step ships GET /admin/users/:user_id +
 * the rename / revoke POSTs + the Devices section template.
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { NEBU_USERS } from '../../fixtures/users';
import { getApiSession } from '../../fixtures/dex-auth';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const MATRIX_BASE = process.env.NEBU_MATRIX_URL ?? 'http://localhost:8008';

// Carried between steps within a scenario.
let targetUserId = '';
let targetToken = '';
// device_id of the device created by THIS scenario's login. In the full suite,
// the dev user "alex" accumulates many `devices` rows (one per Element login),
// so `.first()` is ambiguous and non-deterministic. We scope rename/revoke to
// the specific device this scenario just created, derived from the captured
// session token via GET /account/whoami (real API, no DB seeding).
let targetDeviceId = '';

function deviceRows(page: Page) {
  return page.locator('[data-role="device-row"]');
}

// The row/form/control for THE device this scenario created (deterministic).
function targetDeviceRow(page: Page) {
  return page.locator(`[data-role="device-row"][data-device-id="${targetDeviceId}"]`);
}

function targetRenameForm(page: Page) {
  return page.locator(`[data-form="rename-device"][data-device-id="${targetDeviceId}"]`);
}

function targetRevokeControl(page: Page) {
  return page.locator(`[data-role="revoke-device"][data-device-id="${targetDeviceId}"]`);
}

// Derive the device_id bound to the captured opaque session token. whoami returns
// device_id for opaque Nebu sessions (the Element-login token is one) — see
// GET /_matrix/client/v3/account/whoami. No DB seeding; real API only.
async function deviceIdForToken(
  request: APIRequestContext,
  token: string,
): Promise<string> {
  const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/account/whoami`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(resp.status(), 'whoami for captured session token succeeds').toBe(200);
  const body = (await resp.json()) as { device_id?: string };
  expect(body.device_id, 'whoami returns the device_id bound to the session token').toBeTruthy();
  return body.device_id as string;
}

async function gotoDevicePage(page: Page, userId: string): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/users/${encodeURIComponent(userId)}`);
  await page.waitForLoadState('networkidle');
}

// ─── Precondition: a real device for the target user (real Matrix login) ────────

Given(
  'the user {string} has logged in and has a registered device',
  async (
    { request, browser }: { request: APIRequestContext; browser: Browser },
    userName: string,
  ) => {
    const user = NEBU_USERS[userName as keyof typeof NEBU_USERS];
    if (!user) throw new Error(`[device-management] unknown test user "${userName}"`);
    // getApiSession warms a real Matrix session (Authorization Code + PKCE) for the
    // user — the server registers a `devices` row + opaque session token for it.
    const session = await getApiSession(request, user, browser);
    targetUserId = session.userId;
    targetToken = session.token;
    expect(targetToken, 'target user has a live session token').not.toEqual('');
    // Capture the device_id of the device this login just created so AC2/AC3 can
    // target it deterministically even when alex has many accumulated devices.
    targetDeviceId = await deviceIdForToken(request, targetToken);
  },
);

// ─── Open the per-user device page ──────────────────────────────────────────────

When(
  'the operator opens the device page for {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await gotoDevicePage(page, userId);
    await expect(page.locator('[data-section="devices"]')).toBeVisible({ timeout: 15_000 });
  },
);

When(
  'the operator reloads the device page for {string}',
  async ({ page }: { page: Page }, userId: string) => {
    await gotoDevicePage(page, userId);
    await expect(page.locator('[data-section="devices"]')).toBeVisible({ timeout: 15_000 });
  },
);

// ─── AC1: device list with metadata ───────────────────────────────────────────

Then(
  'a device row for {string} is shown with its device id and last-seen metadata',
  async ({ page }: { page: Page }) => {
    // Scope to THE device this scenario created — deterministic in the full suite.
    const row = targetDeviceRow(page);
    await expect(row).toBeVisible({ timeout: 15_000 });
    // The row must carry a non-empty device id and a last-seen cell.
    const deviceId = await row.getAttribute('data-device-id');
    expect(deviceId, 'device row carries a device id').toBeTruthy();
    await expect(row.locator('[data-field="last-seen"]')).toBeVisible({ timeout: 15_000 });
  },
);

// ─── AC1: empty state ──────────────────────────────────────────────────────────

Then('the device list shows the empty state', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-role="no-devices"]')).toBeVisible({ timeout: 15_000 });
  await expect(deviceRows(page)).toHaveCount(0);
});

// ─── AC2: rename a device ──────────────────────────────────────────────────────

When(
  'the operator renames the device to {string}',
  async ({ page }: { page: Page }, newName: string) => {
    // Scope to THE device this scenario created — not `.first()`, which is ambiguous
    // once alex has accumulated many devices in the full suite.
    const form = targetRenameForm(page);
    await form.locator('input[name="display_name"]').fill(newName);
    await form.locator('button[type="submit"]').click();
    await page.waitForLoadState('networkidle');
  },
);

Then(
  'the device display name is {string}',
  async ({ page }: { page: Page }, expectedName: string) => {
    const row = targetDeviceRow(page);
    await expect(row.locator('[data-field="display-name"]')).toHaveText(expectedName, {
      timeout: 15_000,
    });
  },
);

// ─── AC3: revoke a device (accepting the confirm dialog) ───────────────────────

When('the operator revokes the device and confirms', async ({ page }: { page: Page }) => {
  // AC3: a confirmation step MUST precede deletion. The page is a dead controller
  // render (no LiveView socket), so the real confirmation is a native confirm()
  // wired to the revoke form's onsubmit. Accept the dialog AND assert it actually
  // fired — proving the confirmation step is real, not an unwired data-confirm
  // attribute (regression guard for the previously-shipped dead control).
  let confirmFired = false;
  page.once('dialog', (dialog) => {
    confirmFired = true;
    void dialog.accept();
  });
  await targetRevokeControl(page).click();
  await page.waitForLoadState('networkidle');
  expect(confirmFired, 'a native confirm() dialog must fire before deletion (AC3)').toBe(true);
});

Then('the device no longer appears in the device list', async ({ page }: { page: Page }) => {
  // Assert THE revoked device is gone — not total count 0. In the full suite alex
  // retains other accumulated devices, so a count-0 assertion is wrong there.
  await expect(targetDeviceRow(page)).toHaveCount(0, { timeout: 15_000 });
});

Then(
  "the revoked device's session can no longer authenticate",
  async ({ request }: { request: APIRequestContext }) => {
    // AC3: revoke kills the bound session → the captured token is now denied.
    const resp = await request.get(`${MATRIX_BASE}/_matrix/client/v3/account/whoami`, {
      headers: { Authorization: `Bearer ${targetToken}` },
    });
    expect(resp.status(), 'revoked session token is rejected (401)').toBe(401);
  },
);
