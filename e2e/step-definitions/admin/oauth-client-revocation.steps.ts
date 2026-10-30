/**
 * Step definitions for features/admin/oauth-client-revocation.feature
 *
 * Story: oauth-broker / oauth-client-revocation (P4, AC10) — ATDD: written first, run only against the full
 * compose stack with Dex (typechecked with `tsc --noEmit` and `bddgen --tags "@oauth-revocation or @oauth-approvals"`
 * in the isolated environment).
 *
 * Shared steps reused (NOT redefined here — bddgen rejects duplicates):
 *   - "the Nebu stack is running"                                  -> common/stack-health.steps.ts
 *   - "bootstrap has been completed" / "the operator is logged in as admin" -> admin/bootstrap.steps.ts
 *   - "OAuth is enabled in the instance config"                    -> admin/oauth-client-approvals.steps.ts
 *   - "the operator opens {string} from the OAuth admin menu"      -> admin/oauth-client-approvals.steps.ts
 *   - "a success toast is shown"                                   -> admin/oauth-client-approvals.steps.ts
 *   - "the page is marked as OAuth error {string}"                 -> oauth/oauth-authorize.steps.ts
 *   - "the page has no detectable accessibility violations"        -> oauth/oauth-account-management.steps.ts
 *
 * Real flows only: the client registers through the REAL POST /oauth2/register, approval and revocation are
 * clicked in the REAL Admin UI (confirm pages, the fresh sign-in at Dex), the database is only READ. The one
 * "attack" step (fetch() from an admin page) is what a same-origin script would do; it must be refused.
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, Page } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import {
  upsertServerConfig,
  clearOAuthClientsByNamePrefix,
  countAuditEntries,
  queryAuditMetadata,
  queryOAuthClientByName,
  queryOAuthClientRevocation,
  countOAuthClientSessions,
} from '../../fixtures/db';
import {
  ADMIN_BASE_URL,
  CLIENTS_PATH,
  REGISTRATIONS_PATH,
  approveThroughConfirmPage,
  revokeThroughConfirmPage,
  signInAtDexAsAdmin,
} from '../../fixtures/oauth-admin';

const REGISTER_URL = `${ADMIN_BASE_URL}/oauth2/register`;
/** Starts with the approvals feature's prefix so its Background `clearOAuthClientsByNamePrefix` also removes leftovers. */
const NAME_PREFIX = 'e2e-oauth-revoke';
const CLIENT_HOST = 'example.com';
const STABLE = 'urn:matrix:client:';

type Registered = { name: string; clientId: string; redirectUri: string };

// Scenario-scoped state (reset by every Given that registers a client).
let current: Registered | null = null;
let sawVerifiedHost = false;
let reauthenticated = false;
let signedInViaLink = false; // story admin-reauth-button-flow: the sign-in started at the "Sign in again to approve" link
let fetchStatus = 0;

function theClient(): Registered {
  if (!current) throw new Error('no client was registered in this scenario');
  return current;
}

async function registerClient(request: APIRequestContext): Promise<Registered> {
  const name = `${NAME_PREFIX}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const redirectUri = `https://${CLIENT_HOST}/callback/${name}`;
  const resp = await request.post(REGISTER_URL, {
    data: {
      client_name: name,
      client_uri: `https://${CLIENT_HOST}`,
      redirect_uris: [redirectUri],
      application_type: 'web',
    },
  });
  expect(resp.status(), `POST /oauth2/register -> ${await resp.text()}`).toBe(201);
  const { client_id: clientId } = (await resp.json()) as { client_id: string };
  expect(queryOAuthClientByName(name)?.status, 'a new registration starts pending').toBe('pending');
  return { name, clientId, redirectUri };
}

async function openOAuthMenuPage(page: Page, navKey: string, pageKey: string): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/dashboard`);
  const group = page.locator('button[data-navkey="oauth"]');
  await expect(group, 'sidebar must contain the "OAuth" nav group').toBeVisible({ timeout: 15_000 });
  if ((await group.getAttribute('aria-expanded')) === 'false') await group.click();
  const link = page.locator(`a[data-navkey="${navKey}"]`);
  await expect(link).toBeVisible({ timeout: 15_000 });
  await link.click();
  await expect(page.locator(`[data-page="${pageKey}"]`)).toBeVisible({ timeout: 15_000 });
}

// ─── hygiene ───────────────────────────────────────────────────────────────────

After({ tags: '@oauth-revocation' }, async () => {
  current = null;
  upsertServerConfig('oauth_enabled', 'false');
  clearOAuthClientsByNamePrefix(NAME_PREFIX);
});

// ─── Given ─────────────────────────────────────────────────────────────────────

Given('a client is registered for the revocation scenarios', async ({ request }: { request: APIRequestContext }) => {
  sawVerifiedHost = false;
  reauthenticated = false;
  signedInViaLink = false;
  fetchStatus = 0;
  current = await registerClient(request);
});

Given(
  'an approved client is registered for the revocation scenarios',
  async ({ request, page }: { request: APIRequestContext; page: Page }) => {
    sawVerifiedHost = false;
    reauthenticated = false;
    fetchStatus = 0;
    current = await registerClient(request);
    // approved the way the operator really does it: confirm page + fresh sign-in (SO3/SO4)
    await page.goto(`${ADMIN_BASE_URL}${REGISTRATIONS_PATH}`);
    await approveThroughConfirmPage(page, current.clientId);
    expect(queryOAuthClientRevocation(current.clientId)?.status).toBe('approved');
  },
);

// ─── When ──────────────────────────────────────────────────────────────────────

When('the operator reviews the pending client and approves it on its confirm page', async ({ page }: { page: Page }) => {
  const c = theClient();
  const outcome = await approveThroughConfirmPage(page, c.clientId);
  sawVerifiedHost = outcome.host === CLIENT_HOST;
  reauthenticated = outcome.reauthenticated;
  signedInViaLink = outcome.viaLink;
});

When('the operator opens the approved clients page from the OAuth admin menu', async ({ page }: { page: Page }) => {
  await openOAuthMenuPage(page, 'oauth-approved-clients', 'oauth-clients');
});

When('the operator opens the revoked clients page from the OAuth admin menu', async ({ page }: { page: Page }) => {
  await openOAuthMenuPage(page, 'oauth-revoked-clients', 'oauth-revoked-clients');
});

When(
  'the operator revokes the client by typing its host and the reason {string}',
  async ({ page }: { page: Page }, reason: string) => {
    await page.goto(`${ADMIN_BASE_URL}${CLIENTS_PATH}`);
    // the way an operator gets there: the Revoke link of the client's row opens the confirm page
    const row = page.locator(`[data-role="oauth-approved-row"][data-client-id="${theClient().clientId}"]`);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await row.locator('a[data-role="revoke-client"]').click();
    await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
    await expect(page.locator('[data-page="oauth-revoke-confirm"] [data-role="client-host"]')).toContainText(CLIENT_HOST);
    await expect(page.locator('[data-role="revoke-device-count"]')).toHaveText('0');
    await revokeThroughConfirmPage(page, theClient().clientId, CLIENT_HOST, reason);
  },
);

When('the operator tries to revoke the client by typing the host {string}', async ({ page }: { page: Page }, host: string) => {
  const c = theClient();
  await page.goto(`${ADMIN_BASE_URL}${CLIENTS_PATH}/${encodeURIComponent(c.clientId)}/revoke`);
  await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
  const typeAndSubmit = async (): Promise<void> => {
    await page.locator('[data-role="revoke-confirm-form"] [name="confirm_host"]').fill(host);
    await page.locator('[data-role="revoke-confirm-form"] [data-role="revoke-confirm"]').click();
  };
  await typeAndSubmit();
  // The fresh sign-in is bound to ONE confirm page and consumed by a decision (Kassandra M-1): the approval in the Given
  // does not cover this revoke page, so the server first sends the operator to Dex. Sign in, come back, type again.
  const isDex = (u: URL): boolean => /\/dex\/auth(\/|$)/i.test(u.pathname);
  const errorToast = page.locator('[data-role="toast"][data-toast-kind="error"]').first();
  const first = await Promise.race([
    page.waitForURL((u) => isDex(u), { timeout: 60_000 }).then(() => 'dex' as const),
    errorToast.waitFor({ state: 'visible', timeout: 60_000 }).then(() => 'error' as const),
  ]);
  if (first === 'dex') {
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => /\/revoke$/.test(u.pathname), { timeout: 60_000 });
    await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
    await typeAndSubmit();
  }
});

When(
  'a script on an admin page posts the revoke form of the client with a fetch request and the correct host',
  async ({ page }: { page: Page }) => {
    const c = theClient();
    const url = `${ADMIN_BASE_URL}${CLIENTS_PATH}/${encodeURIComponent(c.clientId)}/revoke`;
    await page.goto(url);
    await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
    // exactly what a same-origin script can do: read the CSRF token from the page and post with the admin's cookies
    fetchStatus = await page.evaluate(
      async ({ target, host }) => {
        const token = (document.querySelector('input[name="_csrf_token"]') as HTMLInputElement | null)?.value ?? '';
        const body = new URLSearchParams({ _csrf_token: token, confirm_host: host, reason: 'scripted' });
        const resp = await fetch(target, { method: 'POST', body, credentials: 'same-origin', redirect: 'manual' });
        return resp.status;
      },
      { target: url, host: CLIENT_HOST },
    );
  },
);

When('the operator opens the revoke confirm page of the client', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}${CLIENTS_PATH}/${encodeURIComponent(theClient().clientId)}/revoke`);
  await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
});

/** Tab (never click) until the focused element matches `selector`; fails loudly after `max` presses. */
async function tabTo(page: Page, selector: string, max = 200): Promise<void> {
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  for (let i = 0; i < max; i++) {
    await page.keyboard.press('Tab');
    if (await page.evaluate((sel) => document.activeElement?.matches(sel) ?? false, selector)) return;
  }
  throw new Error(`keyboard focus never reached ${selector} within ${max} Tab presses`);
}

/** Types the host and the reason with the keyboard and submits with Enter (implicit form submission, no click). */
async function typeAndSubmitWithKeyboard(page: Page, host: string, reason: string): Promise<void> {
  await tabTo(page, '[data-role="revoke-confirm-form"] [name="confirm_host"]');
  await page.keyboard.type(host);
  await page.keyboard.press('Tab');
  await expect(page.locator('[data-role="revoke-confirm-form"] [name="reason"]'), 'Tab moves from the host to the reason').toBeFocused();
  await page.keyboard.type(reason);
  await page.keyboard.press('Enter');
}

When(
  'the operator revokes the client with the keyboard only, typing its host and the reason {string}',
  async ({ page }: { page: Page }, reason: string) => {
    const done = (u: URL): boolean => u.pathname === CLIENTS_PATH;
    const isDex = (u: URL): boolean => /\/dex\/auth(\/|$)/i.test(u.pathname);
    // story admin-reauth-button-flow: without a fresh sign-in the form shows the link "Sign in again to revoke" instead of the submit: Tab to it, press
    // Enter, sign in, come back to the (empty) confirm page; only then the host and the reason are typed and the form is submitted, all by keyboard
    // No fresh sign-in is known here (a new revoke confirm page: the marker is bound to ONE client and action): the link is MANDATORY. A page that shows
    // the submit instead, or a refused POST that redirects to the sign-in, is a defect: this scenario fails.
    const signInLink = page.locator('[data-role="revoke-confirm-form"]').getByRole('link', { name: 'Sign in again to revoke', exact: true });
    await expect(signInLink, 'the revoke confirm page shows the "Sign in again to revoke" link').toBeVisible({ timeout: 15_000 });
    await expect(page.locator('[data-role="revoke-confirm"]'), 'and no submit before the sign-in').toHaveCount(0);
    await tabTo(page, '[data-role="revoke-confirm-form"] a[href^="/admin/login/start"]');
    await page.keyboard.press('Enter');
    await page.waitForURL((u) => isDex(u), { timeout: 60_000 });
    await signInAtDexAsAdmin(page);
    await page.waitForURL((u) => /\/revoke$/.test(u.pathname), { timeout: 60_000 });
    await expect(page.locator('[data-role="revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
    await typeAndSubmitWithKeyboard(page, CLIENT_HOST, reason);
    await page.waitForURL((u) => done(u), { timeout: 60_000 });
  },
);

When("the client's authorize URL is opened in the browser", async ({ page }: { page: Page }) => {
  const c = theClient();
  const verifier = randomBytes(32).toString('base64url');
  const qs = new URLSearchParams({
    response_type: 'code',
    client_id: c.clientId,
    redirect_uri: c.redirectUri,
    scope: `${STABLE}api:* ${STABLE}device:E2EREVOKE${randomBytes(3).toString('hex')}`,
    state: `e2e-state-${randomBytes(6).toString('hex')}`,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'),
    code_challenge_method: 'S256',
  });
  await page.goto(`${ADMIN_BASE_URL}/oauth2/authorize?${qs.toString()}`, { waitUntil: 'domcontentloaded' });
});

// ─── Then ──────────────────────────────────────────────────────────────────────

Then('the confirm page showed the verified host of the client before it was approved', async () => {
  expect(sawVerifiedHost, 'the approve confirm page names the verified client host (example.com)').toBe(true);
});

Then('the operator had to sign in again at the identity provider before the approval was saved', async () => {
  expect(reauthenticated, 'the first approval of a session needs a fresh sign-in through Dex (SO4)').toBe(true);
  expect(signedInViaLink, 'the sign-in started at the "Sign in again to approve" link of the confirm page, not at a refused POST').toBe(true);
});

Then(
  'the client is listed there with its verified host and {int} live sessions',
  async ({ page }: { page: Page }, sessions: number) => {
    const row = page.locator(`[data-role="oauth-approved-row"][data-client-id="${theClient().clientId}"]`);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row.locator('[data-role="client-host"]')).toHaveText(CLIENT_HOST);
    await expect(row.locator('[data-field="sessions"]')).toHaveText(String(sessions));
    await expect(row.locator('a[data-role="revoke-client"]')).toBeVisible();
  },
);

Then(`the client's database status is "approved" with an approval audit entry`, async () => {
  const c = theClient();
  const row = queryOAuthClientRevocation(c.clientId);
  expect(row?.status).toBe('approved');
  expect(row?.approvedBy, 'approved_by = the admin').toBeTruthy();
  expect(countAuditEntries('oauth_client_approved', c.clientId)).toBe(1);
  // CR9: the approval records how the fresh sign-in was proven
  expect(queryAuditMetadata('oauth_client_approved', c.clientId)).toMatch(/"reauth":\s*"(auth_time|flow)"/);
});

Then('the client is no longer listed under Approved Clients', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}${CLIENTS_PATH}`);
  await expect(page.locator('[data-page="oauth-clients"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator(`[data-role="oauth-approved-row"][data-client-id="${theClient().clientId}"]`)).toHaveCount(0);
});

Then(
  'the client is listed there with the reason {string} and the revoking admin',
  async ({ page }: { page: Page }, reason: string) => {
    const row = page.locator(`[data-role="oauth-revoked-row"][data-client-id="${theClient().clientId}"]`);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row.locator('[data-field="revoked-reason"]')).toContainText(reason);
    await expect(row.locator('[data-field="revoked-by"]')).not.toHaveText('');
    await expect(row.locator('[data-field="revoked-at"]')).not.toHaveText('');
  },
);

Then(
  `the client's database status is "revoked" with exactly one revocation audit entry and no session left`,
  async () => {
    const c = theClient();
    const row = queryOAuthClientRevocation(c.clientId);
    expect(row?.status).toBe('revoked');
    expect(row?.revokedBy, 'revoked_by = the admin').toBeTruthy();
    expect(row?.revokedAt).toBeTruthy();
    expect(row?.revokedReason).toBe('Lost the signing key');
    expect(row?.approvedBy, 'the approval attribution is kept').toBeTruthy();
    expect(countAuditEntries('oauth_client_revoked', c.clientId)).toBe(1);
    expect(queryAuditMetadata('oauth_client_revoked', c.clientId)).toMatch(/"devices":\s*0/);
    expect(countOAuthClientSessions(c.clientId)).toBe(0);
  },
);

Then('the host and reason inputs of the confirm page are labelled and described', async ({ page }: { page: Page }) => {
  // the typed host has a visible label that names what to type; the reason has its own label
  const host = page.getByRole('textbox', { name: /^Type .+ to confirm$/ });
  await expect(host, 'confirm_host is a labelled textbox').toHaveCount(1);
  await expect(host).toHaveAttribute('name', 'confirm_host');
  const reason = page.getByRole('textbox', { name: 'Reason (optional, max 500)' });
  await expect(reason, 'reason is a labelled textbox').toHaveCount(1);
  await expect(reason).toHaveAttribute('name', 'reason');
  // each input points to an existing help text through aria-describedby
  for (const input of [host, reason]) {
    const describedBy = (await input.getAttribute('aria-describedby')) ?? '';
    expect(describedBy, 'aria-describedby names a help text').not.toBe('');
    for (const id of describedBy.split(/\s+/)) {
      await expect(page.locator(`#${id}`), `help text #${id} exists`).toHaveCount(1);
    }
  }
  // the consequences have a heading; the device count and the re-authentication hint are plain text (no static status role)
  await expect(page.locator('[data-role="revoke-consequences"] h2')).toBeVisible();
  await expect(page.locator('[data-role="revoke-device-count"]')).toBeVisible();
  await expect(page.locator('[data-role="reauth-state"]')).toBeVisible();
  // story admin-reauth-button-flow: the host field takes the autofocus only when the page is fresh (with the sign-in link as primary control the typed text would be lost)
  const state = await page.locator('[data-role="reauth-state"]').getAttribute('data-reauth');
  if (state === 'fresh') {
    await expect(host, 'the typed host has the focus when the page opens fresh (autofocus)').toBeFocused();
  } else {
    await expect(host, 'no autofocus while the sign-in link is the primary control').not.toBeFocused();
  }
});

Then('the operator stays on the revoke confirm page with an error message', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-page="oauth-revoke-confirm"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-role="toast"][data-toast-kind="error"]').first()).toBeVisible({ timeout: 15_000 });
});

Then(`the client's database status is "approved" and no revocation audit entry exists`, async () => {
  const c = theClient();
  expect(queryOAuthClientRevocation(c.clientId)?.status).toBe('approved');
  expect(countAuditEntries('oauth_client_revoked', c.clientId)).toBe(0);
});

Then('the server answers {int}', async ({}, status: number) => {
  expect(fetchStatus, 'a fetch() POST is not a user-clicked form submit (no Sec-Fetch-Mode: navigate)').toBe(status);
});

// ─── story admin-reauth-button-flow: the state is shown on the primary control of the confirm pages ─────────────────────────────────────

const CONFIRM_SUBMITS = '[data-role="approve-confirm"], [data-role="revoke-confirm"]';

When('the operator opens the approve confirm page of the client', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}${REGISTRATIONS_PATH}/${encodeURIComponent(theClient().clientId)}/approve`);
  await expect(page.locator('[data-page="oauth-approve-confirm"]')).toBeVisible({ timeout: 15_000 });
});

Then('the confirm page shows the {string} link and no {string} button', async ({ page }: { page: Page }, linkText: string, buttonText: string) => {
  const link = page.getByRole('link', { name: linkText, exact: true });
  await expect(link).toBeVisible({ timeout: 10_000 });
  await expect(link, 'a link to the sign-in of THIS page, keyboard reachable').toHaveAttribute('href', /^\/admin\/login\/start\?mode=reauth&return_to=%2Fadmin%2Foauth%2F/);
  const describedBy = await link.getAttribute('aria-describedby');
  expect(describedBy, 'the link keeps aria-describedby').toBeTruthy();
  await expect(page.locator(`#${describedBy}`)).toContainText(/\b(first|before)\b/i);
  await expect(page.locator(CONFIRM_SUBMITS).filter({ hasText: buttonText }), `no "${buttonText}" button before the sign-in`).toHaveCount(0);
  await expect(page.locator('[data-role="reauth-state"]')).toHaveAttribute('data-reauth', 'needed');
});

When('the operator follows the {string} link and signs in again', async ({ page }: { page: Page }, linkText: string) => {
  await page.getByRole('link', { name: linkText, exact: true }).click();
  await page.waitForURL((u) => /\/dex\/auth(\/|$)/i.test(u.pathname), { timeout: 60_000 });
  await signInAtDexAsAdmin(page);
  await page.waitForURL((u) => /\/(approve|revoke)$/.test(u.pathname), { timeout: 60_000 });
});

Then(
  'the confirm page shows the {string} button, no sign-in link and a validity line',
  async ({ page }: { page: Page }, buttonText: string) => {
    await expect(page.locator(CONFIRM_SUBMITS).filter({ hasText: buttonText })).toBeVisible({ timeout: 15_000 });
    await expect(page.getByRole('link', { name: /^Sign in again to /i })).toHaveCount(0);
    const state = page.locator('[data-role="reauth-state"]');
    await expect(state).toHaveAttribute('data-reauth', 'fresh');
    await expect(state).toContainText(/\bvalid\b/i);
    await expect(state).toContainText(/(\d+ minutes?|less than a minute)/i);
  },
);
