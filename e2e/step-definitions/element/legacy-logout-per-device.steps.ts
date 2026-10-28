/**
 * Step definitions for features/element/legacy-logout-per-device.feature
 *
 * Bugfix: legacy-logout-per-device (epic oauth-broker, gate item r). Runs only against the full compose
 * stack with the real Dex; NOT executable in the isolated env (verified with
 * `bddgen --tags "@legacy-logout-per-device"` + `tsc --noEmit`).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts'), element-web project.
 *
 * The scenario state (the remembered first device and the second browser context) lives in module scope and
 * is reset by the @legacy-logout-per-device After hook. Reused steps, never redefined here (bddgen rejects
 * duplicates): "the Nebu stack is running", "alex is logged in via Element Web", 'alex opens the user menu
 * and clicks {string}', "the welcome screen is visible", 'the {string} button is present'.
 *
 * The access token and device id are read from the LIVE MatrixClient (`window.mxMatrixClientPeg`), the
 * authoritative "what the browser holds"; all server checks go through the Matrix client-server API of the
 * homeserver (`NEBU_MATRIX_BASE`), not through UI text.
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { BrowserContext, Browser, Page } from '@playwright/test';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../fixtures/users';
import { loginViaOidcBrowser } from '../../fixtures/dex-auth';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';

type LiveDevice = { token: string; deviceId: string };

type SecondDevice = LiveDevice & { context: BrowserContext; page: Page };

let firstDevice: LiveDevice | null = null;
let secondDevice: SecondDevice | null = null;

/** The access token and device id Element Web is actively using (live MatrixClient). */
async function readLiveDevice(page: Page): Promise<LiveDevice> {
  const live = await page.evaluate(() => {
    const w = window as unknown as Record<string, unknown>;
    const peg = w['mxMatrixClientPeg'] as
      | { get?: () => { getAccessToken?: () => string | null; getDeviceId?: () => string | null } }
      | undefined;
    const client = peg?.get?.();
    return {
      token: client?.getAccessToken?.() ?? null,
      deviceId: client?.getDeviceId?.() ?? null,
    };
  });
  expect(live.token, 'live Element access token was readable').toBeTruthy();
  expect(live.deviceId, 'live Element device id was readable').toBeTruthy();
  return { token: live.token as string, deviceId: live.deviceId as string };
}

function requireFirst(): LiveDevice {
  if (!firstDevice) throw new Error('"alex remembers the device of this browser" must run first');
  return firstDevice;
}

function requireSecond(): SecondDevice {
  if (!secondDevice) throw new Error('"alex is also logged in via Element Web on a second device" must run first');
  return secondDevice;
}

async function whoamiStatus(page: Page, token: string): Promise<number> {
  const resp = await page.request.get(`${MATRIX_BASE}/_matrix/client/v3/account/whoami`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return resp.status();
}

async function deviceIds(page: Page, token: string): Promise<string[]> {
  const resp = await page.request.get(`${MATRIX_BASE}/_matrix/client/v3/devices`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(resp.status(), 'GET /devices with the second device token').toBe(200);
  const body = (await resp.json()) as { devices?: Array<{ device_id: string }> };
  return (body.devices ?? []).map((d) => d.device_id);
}

/** "And alex remembers the device of this browser": the first device (token + device id), read before it signs out. */
Given('alex remembers the device of this browser', async ({ page }: { page: Page }) => {
  firstDevice = await readLiveDevice(page);
});

/**
 * "And alex is also logged in via Element Web on a second device": a SECOND browser context, a full
 * Authorization Code + PKCE login via Dex (a new Matrix device of the same user). The page stays open for the
 * later steps; the After hook closes the context.
 */
Given(
  'alex is also logged in via Element Web on a second device',
  async ({ browser }: { browser: Browser }) => {
    const first = requireFirst();
    const context = await browser.newContext();
    const page = await context.newPage();
    try {
      await loginViaOidcBrowser(page, NEBU_USERS.alex, NEBU_USERS.alex.email, DEX_TEST_PASSWORD);
      await expect(page.locator('.mx_LeftPanel')).toBeVisible({ timeout: 20_000 });
      const live = await readLiveDevice(page);
      expect(live.deviceId, 'the second browser is a DIFFERENT Matrix device').not.toBe(first.deviceId);
      secondDevice = { ...live, context, page };
    } catch (e) {
      await context.close().catch(() => { /* already closed */ });
      throw e;
    }
  },
);

/** "Then the access token of the remembered device is rejected by the server": the signed-out credential is dead (LL4). */
Then('the access token of the remembered device is rejected by the server', async ({ page }: { page: Page }) => {
  const first = requireFirst();
  await expect.poll(() => whoamiStatus(page, first.token), { timeout: 15_000 }).toBe(401);
});

/** "When alex reloads Element Web on the second device" */
When('alex reloads Element Web on the second device', async () => {
  const second = requireSecond();
  await second.page.reload();
  await second.page
    .waitForLoadState('networkidle', { timeout: 15_000 })
    .catch((e: Error) => { if (!e.message?.includes('Timeout')) throw e; });
});

/** "Then the room list is visible on the second device": the other session survived (it was wiped before the fix). */
Then('the room list is visible on the second device', async () => {
  const second = requireSecond();
  await expect(second.page.locator('.mx_LeftPanel')).toBeVisible({ timeout: 30_000 });
});

/** "And the access token of the second device is still accepted by the server" */
Then('the access token of the second device is still accepted by the server', async () => {
  const second = requireSecond();
  expect(await whoamiStatus(second.page, second.token)).toBe(200);
});

/** "And the device list of the second device no longer contains the remembered device" (the device was deleted, LL2). */
Then('the device list of the second device no longer contains the remembered device', async () => {
  const first = requireFirst();
  const second = requireSecond();
  await expect
    .poll(async () => (await deviceIds(second.page, second.token)).includes(first.deviceId), { timeout: 15_000 })
    .toBe(false);
});

/** "And the device list of the second device still contains the second device" */
Then('the device list of the second device still contains the second device', async () => {
  const second = requireSecond();
  expect(await deviceIds(second.page, second.token)).toContain(second.deviceId);
});

After({ tags: '@legacy-logout-per-device' }, async () => {
  const second = secondDevice;
  firstDevice = null;
  secondDevice = null;
  if (second) await second.context.close().catch(() => { /* already closed */ });
});
