/**
 * Step definitions for features/admin/oauth-client-approvals.feature
 *
 * Story: oauth-broker / oauth-metadata-dcr-admin-approval (AC4) — ATDD: written first, since implemented (the scenarios are
 * expected GREEN; they run only against the full compose stack with Dex).
 *
 * Framework: playwright-bdd (importTestFrom: 'fixtures/nebu-fixtures.ts')
 *
 * Shared steps reused (NOT redefined here — Cucumber errors on duplicates):
 *   - "the Nebu stack is running"          -> common/stack-health.steps.ts
 *   - "bootstrap has been completed"       -> admin/bootstrap.steps.ts
 *   - "the operator is logged in as admin" -> admin/bootstrap.steps.ts (real Dex OIDC login)
 *
 * Real flows only: clients are registered through the REAL POST /oauth2/register endpoint,
 * decided through the REAL Admin UI; the DB is only READ for verification. OAuth is switched
 * on through the documented `oauth_enabled` server_config key (same fixture mechanism as the
 * other admin features' config seeding — see fixtures/db.ts).
 *
 * UI contract pinned here (test-review M1; mirrors the existing device-revoke flow, see
 * users/show.html.heex + device-management.steps.ts — NOT a modal):
 *   - sidebar parent toggle  button[data-navkey="oauth"]  (aria-expanded, expanded by default)
 *     with the child link    a[data-navkey="oauth-pending-clients"]
 *   - Reject is a <button type=submit> inside a per-row form; the confirmation step is a
 *     NATIVE window.confirm() wired from the form's `data-confirm` message by the external
 *     /admin/static/assets/app.js (CSP script-src 'self'; dead controller render, no LiveView).
 *   - story oauth-client-revocation (P4, SO3/SO4): Approve is a LINK [data-role="review-approve"] to a confirm
 *     PAGE (no native confirm(): Sec-Fetch-User needs a plain user-clicked submit) and approving needs a
 *     FRESH admin sign-in: the first approval of a session goes through the Dex login form again (shared
 *     helper fixtures/oauth-admin.ts approveThroughConfirmPage; the marker is reused for 300 s).
 *   - a native confirm() cannot collect text, so the reject form carries an always-visible
 *     optional text input [name="reason"] that is filled BEFORE clicking Reject.
 *   - success toast [data-role="toast"] after the redirect back to the list.
 * All waits are web-first (expect(...).toBeVisible/toHaveCount) — never locator.isVisible({timeout}),
 * which ignores its timeout and returns immediately.
 *
 * Contract: migration 000040 (oauth_clients), POST /oauth2/register, the
 * /admin/oauth/registrations page with its approve/reject routes and the "OAuth" nav group.
 */

import { Given, When, Then, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext, Browser } from '@playwright/test';
import { approveThroughConfirmPage } from '../../fixtures/oauth-admin';
import {
  upsertServerConfig,
  queryOAuthClientByName,
  countAuditEntries,
  queryAuditReason,
  clearOAuthClientsByNamePrefix,
  countPendingOAuthClientsOutsideNamePrefix,
  insertPendingOAuthClients,
  insertAgedPendingOAuthClients,
  queryBulkRemovalAudit,
} from '../../fixtures/db';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const REGISTER_URL = `${ADMIN_BASE_URL}/oauth2/register`;
const LIST_PATH = '/admin/oauth/registrations';
const NAME_PREFIX = 'e2e-oauth';

type Registered = { name: string; clientId: string; body: Record<string, unknown> };

// Scenario-scoped state (module-level, reset by the first Given of each scenario).
let pending: Registered[] = [];
let approvedNames: string[] = [];
let lastDecided: Registered | null = null;
let firstClientId = '';
let secondClientId = '';
let anonContext: Awaited<ReturnType<Browser['newContext']>> | null = null;
let anonPage: Page | null = null;
let seeded: string[] = [];
let seenIds: string[] = [];
let listCsp = '';
let requestedUrls: string[] = [];
let requestLogPage: Page | null = null;
// Story oauth-dcr-abuse-hardening (AC15): unique registrable test domains per scenario
let bulkDomain = '';
let otherDomain = '';
let bulkClients: Registered[] = [];
let otherClients: Registered[] = [];
let agedSeeded: string[] = [];
let sharedClient: Registered | null = null;
let lastRegisterStatus = 0;
let lastRegisterError = '';

function uniqueName(): string {
  return `${NAME_PREFIX}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function registrationBody(name: string): Record<string, unknown> {
  // client_uri host is fixed (example.com) — uniqueness comes from client_name (part of the hash).
  return {
    client_name: name,
    client_uri: 'https://example.com',
    logo_uri: 'https://example.com/logo.png',
    redirect_uris: [`https://example.com/callback/${name}`],
    application_type: 'web',
  };
}

async function registerClient(request: APIRequestContext, body: Record<string, unknown>) {
  const resp = await request.post(REGISTER_URL, { data: body });
  expect(resp.status(), `POST /oauth2/register -> ${await resp.text()}`).toBe(201);
  const json = (await resp.json()) as { client_id: string };
  expect(json.client_id, 'server-generated client_id').toBeTruthy();
  return json.client_id;
}

function rowFor(page: Page, clientId: string) {
  return page.locator(`[data-role="oauth-client-row"][data-client-id="${clientId}"]`);
}

const isListDocument = (r: import('@playwright/test').Response, query = '') =>
  new URL(r.url()).pathname === LIST_PATH &&
  new URL(r.url()).search.includes(query) &&
  r.request().method() === 'GET' &&
  r.request().resourceType() === 'document';

/** Record every request of this page (once per scenario/page) so "no client-hosted URL was contacted" is provable. */
function logRequests(page: Page): void {
  if (requestLogPage === page) return;
  requestLogPage = page;
  requestedUrls = [];
  page.on('request', (r) => requestedUrls.push(r.url()));
}

async function openPendingClients(page: Page): Promise<void> {
  logRequests(page);
  await page.goto(`${ADMIN_BASE_URL}/admin/dashboard`);
  // "OAuth" sidebar group (parent disclosure button, expanded by default) -> "Pending Clients" link.
  const group = page.locator('button[data-navkey="oauth"]');
  await expect(group, 'sidebar must contain the "OAuth" nav group').toBeVisible({ timeout: 15_000 });
  if ((await group.getAttribute('aria-expanded')) === 'false') await group.click();
  const link = page.locator('a[data-navkey="oauth-pending-clients"]');
  await expect(link).toBeVisible({ timeout: 15_000 });
  const [listResponse] = await Promise.all([
    page.waitForResponse((r) => isListDocument(r), { timeout: 15_000 }),
    link.click(),
  ]);
  listCsp = listResponse.headers()['content-security-policy'] ?? '';
  await page.waitForURL(new RegExp(`${LIST_PATH}$`), { timeout: 15_000 });
  await expect(page.locator('[data-page="oauth-registrations"]')).toBeVisible({ timeout: 15_000 });
}

// ─── Background ────────────────────────────────────────────────────────────────

Given('OAuth is enabled in the instance config', async () => {
  upsertServerConfig('oauth_enabled', 'true');
  pending = [];
  approvedNames = [];
  lastDecided = null;
  firstClientId = '';
  secondClientId = '';
  anonContext = null;
  anonPage = null;
  seeded = [];
  seenIds = [];
  listCsp = '';
  requestedUrls = [];
  requestLogPage = null;
  const rand = Math.random().toString(36).slice(2, 8);
  bulkDomain = `e2e-bulk-${rand}.org`;
  otherDomain = `e2e-other-${rand}.org`;
  bulkClients = [];
  otherClients = [];
  agedSeeded = [];
  sharedClient = null;
  lastRegisterStatus = 0;
  lastRegisterError = '';
  clearOAuthClientsByNamePrefix(NAME_PREFIX);
});

// Scenario cleanup (test-review m4): never leave OAuth switched on or e2e registrations behind.
// Tag-scoped so it only runs for this feature; failures are NOT swallowed (see fixtures/db.ts).
After({ tags: '@oauth-approvals' }, async () => {
  await anonContext?.close();
  anonContext = null;
  anonPage = null;
  upsertServerConfig('oauth_enabled', 'false');
  clearOAuthClientsByNamePrefix(NAME_PREFIX);
});

// ─── Given: registrations through the REAL DCR endpoint ────────────────────────

Given(
  /^(\d+) clients? (?:is|are) registered via Dynamic Client Registration$/,
  async ({ request }: { request: APIRequestContext }, count: number) => {
    for (let i = 0; i < Number(count); i++) {
      const name = uniqueName();
      const body = registrationBody(name);
      const clientId = await registerClient(request, body);
      pending.push({ name, clientId, body });
    }
    firstClientId = pending[0]?.clientId ?? '';
    for (const p of pending) {
      expect(queryOAuthClientByName(p.name)?.status, 'new registration starts pending').toBe('pending');
    }
  },
);

Given(
  /^(\d+) more clients are registered and approved by the operator$/,
  async ({ request, page }: { request: APIRequestContext; page: Page }, count: number) => {
    // Register, then approve through the real Admin UI (the Background logged the operator in).
    const fresh: Registered[] = [];
    for (let i = 0; i < Number(count); i++) {
      const name = uniqueName();
      const body = registrationBody(name);
      fresh.push({ name, clientId: await registerClient(request, body), body });
    }
    await openPendingClients(page);
    for (const c of fresh) {
      await approveRow(page, c.clientId);
      approvedNames.push(c.name);
      expect(queryOAuthClientByName(c.name)?.status).toBe('approved');
    }
  },
);

Given(
  /^(\d+) pending registrations are seeded directly in the database$/,
  async ({}, count: number) => {
    // Direct seeding is the documented exception (see the feature header): the DCR endpoint's
    // 50/hour/IP rate limit makes >1 page of registrations impossible to create through it.
    seeded = insertPendingOAuthClients(`${NAME_PREFIX}-pg-${Date.now().toString(36)}`, Number(count));
  },
);

Given('no client registration is pending', async () => {
  // Non-destructive (test-review m4): this scenario's own leftovers were removed by the Background /
  // After hook. Foreign pending registrations (a shared dev DB) are NEVER decided on the
  // operator's behalf — fail loudly instead, the empty state cannot be shown with them present.
  const foreign = countPendingOAuthClientsOutsideNamePrefix(NAME_PREFIX);
  expect(
    foreign,
    `${foreign} foreign pending OAuth registration(s) exist; this scenario needs a DB without pending ` +
      'registrations (fresh stack). Refusing to approve/reject them automatically.',
  ).toBe(0);
});

Given('an anonymous visitor without an admin session', async ({ browser }: { browser: Browser }) => {
  anonContext = await browser.newContext();
});

// ─── UI interaction helpers ────────────────────────────────────────────────────

/**
 * Click Approve/Reject on one row. Pins the confirmation contract: a NATIVE confirm() must fire
 * before the decision is submitted (asserted, not assumed), the optional reject reason is an
 * always-visible [name="reason"] input filled first, and the row must disappear afterwards.
 */
async function decide(
  page: Page,
  clientId: string,
  action: 'reject-client',
  reason = '',
): Promise<void> {
  const row = rowFor(page, clientId);
  await expect(row).toBeVisible({ timeout: 15_000 });

  if (reason !== '') {
    const reasonInput = row.locator('[name="reason"]');
    await expect(reasonInput, 'reject form must expose the optional [name="reason"] input').toBeVisible();
    await reasonInput.fill(reason);
  }

  let confirmFired = false;
  page.once('dialog', (dialog) => {
    confirmFired = true;
    void dialog.accept();
  });
  await row.locator(`[data-role="${action}"]`).click();

  await expect(rowFor(page, clientId)).toHaveCount(0, { timeout: 15_000 });
  expect(confirmFired, `a native confirm() dialog must fire before ${action} is submitted`).toBe(true);
}

// story oauth-client-revocation (SO3/SO4): confirm page + fresh sign-in instead of the old native-confirm form
const approveRow = async (page: Page, clientId: string): Promise<void> => {
  await approveThroughConfirmPage(page, clientId);
  await expect(rowFor(page, clientId)).toHaveCount(0, { timeout: 15_000 });
};
const rejectRow = (page: Page, clientId: string, reason: string) =>
  decide(page, clientId, 'reject-client', reason);

// ─── When ──────────────────────────────────────────────────────────────────────

When(
  'the operator opens {string} from the OAuth admin menu',
  async ({ page }: { page: Page }, _label: string) => {
    await openPendingClients(page);
  },
);

When('the operator approves the pending client', async ({ page }: { page: Page }) => {
  lastDecided = pending[0];
  await approveRow(page, lastDecided.clientId);
});

When(
  'the operator rejects the pending client with the reason {string}',
  async ({ page }: { page: Page }, reason: string) => {
    lastDecided = pending[0];
    await rejectRow(page, lastDecided.clientId, reason);
  },
);

// Story safari-fetch-metadata-compat (AC9): record the body of the reject POST of a REAL click.
let recordedRejectBody: string | null = null;

When(
  'the operator rejects the pending client with the reason {string} and records the request',
  async ({ page }: { page: Page }, reason: string) => {
    lastDecided = pending[0];
    recordedRejectBody = null;
    const [req] = await Promise.all([
      page.waitForRequest(
        (r) => r.method() === 'POST' && /\/admin\/oauth\/registrations\/[^/]+\/reject$/.test(r.url()),
        { timeout: 30_000 },
      ),
      rejectRow(page, lastDecided.clientId, reason),
    ]);
    recordedRejectBody = req.postData();
  },
);

When('the same client registers again with identical metadata', async ({ request }: { request: APIRequestContext }) => {
  const again = await registerClient(request, (lastDecided as Registered).body);
  (lastDecided as Registered).clientId = again;
  secondClientId = again;
});

When('the visitor opens the pending client registrations page', async () => {
  anonPage = await (anonContext as NonNullable<typeof anonContext>).newPage();
  await anonPage.goto(`${ADMIN_BASE_URL}${LIST_PATH}`);
  await anonPage.waitForLoadState('domcontentloaded');
});

// ─── Then ──────────────────────────────────────────────────────────────────────

Then('the recorded reject request carried the click proof {string}', async ({}, expected: string) => {
  expect(recordedRejectBody, 'the reject POST was recorded').not.toBeNull();
  const params = new URLSearchParams(recordedRejectBody ?? '');
  expect(
    params.get('_click_proof'),
    'a trusted click fills the hidden _click_proof field through the shared app.js script',
  ).toBe(expected);
});

Then('the page lists exactly the 3 pending registrations of this scenario', async ({ page }: { page: Page }) => {
  for (const p of pending) {
    await expect(rowFor(page, p.clientId)).toBeVisible({ timeout: 15_000 });
  }
  // Scoped to this scenario's clients: other scenarios/runs may leave unrelated pending rows.
  const names = await page.locator('[data-role="oauth-client-row"] [data-field="client-name"]').allTextContents();
  const mine = names.filter((n) => n.includes(NAME_PREFIX) && pending.some((p) => n.includes(p.name)));
  expect(mine).toHaveLength(3);
});

Then(
  'each pending row shows client name, client URI, redirect URIs, the logo URL as text, created time, an Approve and a Reject button',
  async ({ page }: { page: Page }) => {
    for (const p of pending) {
      const row = rowFor(page, p.clientId);
      await expect(row.locator('[data-field="client-name"]')).toContainText(p.name);
      await expect(row.locator('[data-field="client-uri"] a')).toHaveAttribute('href', 'https://example.com');
      await expect(row.locator('[data-field="redirect-uris"]')).toContainText(`https://example.com/callback/${p.name}`);
      // Logos are loaded only on click: the cell shows the URL as text and NO image.
      await expect(row.locator('[data-field="logo"] [data-role="logo-url"]')).toContainText('https://example.com/logo.png');
      await expect(row.locator('[data-field="logo"] img')).toHaveCount(0);
      await expect(row.locator('[data-field="created"]')).not.toBeEmpty();
      await expect(row.locator('a[data-role="review-approve"]')).toBeVisible();
      await expect(row.locator('[data-role="reject-client"]')).toBeVisible();
    }
  },
);

// Security review F-5: the approval page lets the admin spot impersonation.
Then(
  'the page marks the client details as unverified and each row shows its application type and host-bound redirect URIs',
  async ({ page }: { page: Page }) => {
    await expect(page.locator('[data-role="unverified-claims-note"]')).toBeVisible();
    for (const p of pending) {
      const row = rowFor(page, p.clientId);
      await expect(row.locator('[data-role="application-type"]')).toHaveText('web');
      // The registered https redirect URI is on the client URI host: host-bound, no "unverified" warning.
      await expect(row.locator('[data-role="redirect-host-bound"]')).toHaveCount(1);
      await expect(row.locator('[data-role="redirect-not-host-bound"]')).toHaveCount(0);
    }
  },
);

// ─── Decision 2: logos only on click ───────────────────────────────────────────

const STRICT_IMG_SRC = "img-src 'self' data:";
const hasHttpsWildcard = (csp: string) => /img-src[^;]*\shttps:(\s|;|$)/.test(csp);

Then('no logo image is rendered and the browser did not contact any client-hosted URL', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-field="logo"] img')).toHaveCount(0);
  expect(listCsp, 'default page keeps the strict image policy').toContain(STRICT_IMG_SRC);
  expect(hasHttpsWildcard(listCsp), `no https: wildcard in "${listCsp}"`).toBe(false);
  const foreign = requestedUrls.filter((u) => !u.startsWith(ADMIN_BASE_URL) && /example\.com/.test(u));
  expect(foreign, 'the admin browser must not contact client-hosted URLs by default').toEqual([]);
});

Then('the logo URL of each pending row is shown as text with its host', async ({ page }: { page: Page }) => {
  for (const p of pending) {
    const cell = rowFor(page, p.clientId).locator('[data-field="logo"] [data-role="logo-url"]');
    await expect(cell).toContainText('https://example.com/logo.png');
    await expect(cell.locator('[data-role="logo-host"]')).toHaveText('example.com');
  }
  await expect(page.locator('[data-role="load-logos"]')).toBeVisible();
});

When('the operator requests the logos via the Load logos control', async ({ page }: { page: Page }) => {
  const [resp] = await Promise.all([
    page.waitForResponse((r) => isListDocument(r, 'logos=1'), { timeout: 15_000 }),
    page.locator('[data-role="load-logos"]').click(),
  ]);
  listCsp = resp.headers()['content-security-policy'] ?? '';
  await expect(page.locator('[data-role="hide-logos"]')).toBeVisible({ timeout: 15_000 });
});

Then(
  'each pending row renders its logo image with referrer policy {string}',
  async ({ page }: { page: Page }, policy: string) => {
    for (const p of pending) {
      // Attached, not "visible": the logo host (example.com) may be unreachable from the test network.
      const img = rowFor(page, p.clientId).locator('[data-field="logo"] img');
      await expect(img).toHaveCount(1);
      await expect(img).toHaveAttribute('src', 'https://example.com/logo.png');
      await expect(img).toHaveAttribute('referrerpolicy', policy);
      await expect(img).toHaveAttribute('loading', 'lazy');
    }
  },
);

Then('only this response widens the image policy, to the exact logo origin', async () => {
  expect(listCsp).toContain("img-src 'self' data: https://example.com");
  expect(hasHttpsWildcard(listCsp), `no https: wildcard in "${listCsp}"`).toBe(false);
  expect(listCsp).toContain("script-src 'self'");
});

When('the operator hides the logos again', async ({ page }: { page: Page }) => {
  const [resp] = await Promise.all([
    page.waitForResponse((r) => isListDocument(r) && !new URL(r.url()).search.includes('logos'), { timeout: 15_000 }),
    page.locator('[data-role="hide-logos"]').click(),
  ]);
  listCsp = resp.headers()['content-security-policy'] ?? '';
});

Then('the image policy is strict again and no logo image is rendered', async ({ page }: { page: Page }) => {
  expect(listCsp).toContain(STRICT_IMG_SRC);
  expect(hasHttpsWildcard(listCsp)).toBe(false);
  expect(listCsp).not.toContain('https://example.com');
  await expect(page.locator('[data-field="logo"] img')).toHaveCount(0);
});

// ─── Decision 1: pagination ────────────────────────────────────────────────────

const rowIdsOnPage = (page: Page) =>
  page.locator('[data-role="oauth-client-row"]').evaluateAll((els) => els.map((e) => e.getAttribute('data-client-id') ?? ''));

Then(
  'the first page lists 50 registrations and states the pending total and how many are still pending',
  async ({ page }: { page: Page }) => {
    await expect(page.locator('[data-role="oauth-client-row"]')).toHaveCount(50);
    const summary = page.locator('[data-role="pending-summary"]');
    await expect(summary).toBeVisible();
    const total = Number(await summary.getAttribute('data-total'));
    expect(total, 'the real total, not a truncated one').toBeGreaterThanOrEqual(seeded.length);
    const more = page.locator('[data-role="more-pending"]');
    await expect(more).toBeVisible();
    expect(Number(await more.getAttribute('data-more'))).toBe(total - 50);
    await expect(more).toContainText(`${total - 50} more pending`);
  },
);

Then(
  'a {string} link is offered but no {string} link',
  async ({ page }: { page: Page }, _next: string, _prev: string) => {
    await expect(page.locator('[data-role="page-next"]')).toBeVisible();
    await expect(page.locator('[data-role="page-prev"]')).toHaveCount(0);
  },
);

When('the operator follows the Next page links until the last page', async ({ page }: { page: Page }) => {
  seenIds = [...(await rowIdsOnPage(page))];
  for (let guard = 0; guard < 500; guard++) {
    const next = page.locator('[data-role="page-next"]');
    if ((await next.count()) === 0) break;
    const current = page.url();
    await Promise.all([page.waitForURL((u) => u.toString() !== current, { timeout: 15_000 }), next.click()]);
    await expect(page.locator('[data-page="oauth-registrations"]')).toBeVisible();
    seenIds.push(...(await rowIdsOnPage(page)));
  }
});

Then(
  /^all (\d+) seeded registrations were listed exactly once across the pages$/,
  async ({}, count: number) => {
    expect(seeded).toHaveLength(Number(count));
    expect(new Set(seenIds).size, 'no registration is listed twice').toBe(seenIds.length);
    for (const id of seeded) expect(seenIds, `seeded registration ${id} was never listed`).toContain(id);
  },
);

Then('the last page offers no {string} link and no more-pending hint', async ({ page }: { page: Page }, _next: string) => {
  await expect(page.locator('[data-role="page-next"]')).toHaveCount(0);
  await expect(page.locator('[data-role="more-pending"]')).toHaveCount(0);
});

Then('none of the approved clients is listed', async ({ page }: { page: Page }) => {
  const root = page.locator('[data-page="oauth-registrations"]');
  await expect(root).toBeVisible();
  for (const name of approvedNames) await expect(root).not.toContainText(name);
});

Then('a success toast is shown', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-role="toast"]').first()).toBeVisible({ timeout: 15_000 });
});

Then('the client is no longer listed as pending', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}${LIST_PATH}`);
  await expect(rowFor(page, (lastDecided as Registered).clientId)).toHaveCount(0);
});

Then(
  /^the client's status in the database is "(approved|rejected)" with the admin recorded as (?:approver|rejecter)$/,
  async ({}, status: string) => {
    const row = queryOAuthClientByName((lastDecided as Registered).name);
    expect(row, 'registration must still exist (never deleted)').not.toBeNull();
    expect(row!.status).toBe(status);
    if (status === 'approved') {
      expect(row!.approvedBy, 'approved_by = admin user id').toBeTruthy();
      expect(row!.approvedAt, 'approved_at set').toBeTruthy();
    } else {
      expect(row!.rejectedBy, 'rejected_by = admin user id').toBeTruthy();
      expect(row!.rejectedAt, 'rejected_at set').toBeTruthy();
    }
  },
);

Then(/^an audit entry "(oauth_client_approved)" exists for the client$/, async ({}, action: string) => {
  expect(countAuditEntries(action, (lastDecided as Registered).clientId)).toBeGreaterThanOrEqual(1);
});

Then(
  /^an audit entry "(oauth_client_rejected)" with the reason "([^"]+)" exists for the client$/,
  async ({}, action: string, reason: string) => {
    const id = (lastDecided as Registered).clientId;
    expect(countAuditEntries(action, id)).toBeGreaterThanOrEqual(1);
    expect(queryAuditReason(action, id)).toBe(reason);
  },
);

Then('the registration returns the same client id as before', async () => {
  expect(secondClientId).toBe(firstClientId);
});

Then('the empty state {string} is shown', async ({ page }: { page: Page }, _text: string) => {
  await expect(page.locator('[data-role="no-pending-clients"]')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('[data-role="oauth-client-row"]')).toHaveCount(0);
});

Then('the visitor is redirected to the admin login page', async () => {
  await expect(anonPage as Page).toHaveURL(/\/admin\/login/, { timeout: 15_000 });
});

// ─── Story oauth-dcr-abuse-hardening (AC15): bulk removal, age, public suffix, keyboard ───────────

/** A web registration whose client URI is `https://<host>` (redirect URI on the same host: host-bound). */
function registrationBodyForHost(name: string, host: string): Record<string, unknown> {
  return {
    client_name: name,
    client_uri: `https://${host}`,
    redirect_uris: [`https://${host}/callback/${name}`],
    application_type: 'web',
  };
}

async function registerOnDomain(request: APIRequestContext, domain: string, count: number, into: Registered[]) {
  for (let i = 0; i < count; i++) {
    const name = uniqueName();
    const body = registrationBodyForHost(name, `app${into.length + 1}.${domain}`);
    const clientId = await registerClient(request, body);
    into.push({ name, clientId, body });
    expect(queryOAuthClientByName(name)?.status, 'new registration starts pending').toBe('pending');
  }
}

Given(
  /^(\d+) clients? (?:is|are) registered via Dynamic Client Registration on one test domain$/,
  async ({ request }: { request: APIRequestContext }, count: number) => {
    await registerOnDomain(request, bulkDomain, Number(count), bulkClients);
  },
);

Given(
  /^(\d+) clients? (?:is|are) registered via Dynamic Client Registration on another test domain$/,
  async ({ request }: { request: APIRequestContext }, count: number) => {
    await registerOnDomain(request, otherDomain, Number(count), otherClients);
  },
);

Given(
  /^(\d+) pending registrations of the test domain are seeded (\d+) days old directly in the database$/,
  async ({}, count: number, days: number) => {
    // Documented exception (feature header): the age of a registration cannot be produced through
    // the real endpoint. The rows carry the stored host/domain the way the endpoint would write them.
    agedSeeded = insertAgedPendingOAuthClients(
      `${NAME_PREFIX}-aged-${Date.now().toString(36)}`,
      Number(count),
      Number(days),
      `seed.${bulkDomain}`,
      bulkDomain,
    );
  },
);

const previewUrl = /\/admin\/oauth\/registrations\/bulk-remove/;
const listUrl = new RegExp(`${LIST_PATH}(\\?.*)?$`);

When('the operator follows the bulk-remove link of the test domain', async ({ page }: { page: Page }) => {
  // One identical link per row of the domain: any of them leads to the same preview.
  const link = page.getByRole('link', { name: `Remove all pending registrations of ${bulkDomain}` }).first();
  await expect(link, 'every row with a host offers the bulk-remove link').toBeVisible({ timeout: 15_000 });
  await Promise.all([page.waitForURL(previewUrl, { timeout: 15_000 }), link.click()]);
});

When(
  /^the operator previews the removal for the test domain older than (\d+) days$/,
  async ({ page }: { page: Page }, days: number) => {
    const form = page.locator('[data-form="bulk-remove"]');
    await expect(form, 'the list page offers the bulk-remove form').toBeVisible({ timeout: 15_000 });
    await form.locator('[name="host"]').fill(bulkDomain);
    await form.locator('[name="match"][value="domain"]').check();
    await form.locator('[name="older_than_days"]').fill(String(days));
    await Promise.all([page.waitForURL(previewUrl, { timeout: 15_000 }), form.locator('button[type="submit"], input[type="submit"]').first().click()]);
  },
);

Then('the preview states {string}', async ({ page }: { page: Page }, text: string) => {
  const summary = page.locator('[data-role="bulk-match-count"]');
  await expect(summary).toBeVisible({ timeout: 15_000 });
  await expect(summary).toContainText(text);
});

/** Click the confirm button; the NATIVE confirm() must fire (asserted, not assumed). */
async function confirmRemoval(page: Page, press: (() => Promise<void>) | null): Promise<void> {
  let confirmFired = false;
  page.once('dialog', (dialog) => {
    confirmFired = true;
    void dialog.accept();
  });
  if (press) await press();
  else await page.locator('[data-role="bulk-remove-confirm"]').click();
  await page.waitForURL(listUrl, { timeout: 15_000 });
  expect(confirmFired, 'a native confirm() dialog must fire before the removal is submitted').toBe(true);
}

When('the operator confirms the removal of the pending registrations', async ({ page }: { page: Page }) => {
  await confirmRemoval(page, null);
});

Then(
  /^the (\d+) registrations of the test domain are gone from the database$/,
  async ({}, count: number) => {
    expect(bulkClients).toHaveLength(Number(count));
    for (const c of bulkClients) {
      expect(queryOAuthClientByName(c.name), `${c.name} must be removed (deleted, not rejected)`).toBeNull();
    }
  },
);

Then('the registration of the other domain is still pending', async () => {
  expect(otherClients.length).toBeGreaterThan(0);
  for (const c of otherClients) expect(queryOAuthClientByName(c.name)?.status).toBe('pending');
});

Then(
  /^one audit entry "(oauth_clients_bulk_removed)" with removed (\d+) exists for these registrations$/,
  async ({}, _action: string, removed: number) => {
    const audit = queryBulkRemovalAudit(bulkClients[0].clientId);
    expect(audit.count, 'exactly ONE audit row per bulk removal').toBe(1);
    expect(audit.removed).toBe(Number(removed));
  },
);

Then(
  /^the (\d+) seeded registrations are gone and the fresh registration is still pending$/,
  async ({}, count: number) => {
    expect(agedSeeded).toHaveLength(Number(count));
    for (const id of agedSeeded) expect(queryOAuthClientByName(id), `${id} (40 days old) must be removed`).toBeNull();
    expect(bulkClients.length).toBeGreaterThan(0);
    for (const c of bulkClients) {
      expect(queryOAuthClientByName(c.name)?.status, 'the fresh registration is not older than 30 days').toBe('pending');
    }
  },
);

Then(
  /^one audit entry "(oauth_clients_bulk_removed)" with removed (\d+) exists for the seeded registrations$/,
  async ({}, _action: string, removed: number) => {
    const audit = queryBulkRemovalAudit(agedSeeded[0]);
    expect(audit.count).toBe(1);
    expect(audit.removed).toBe(Number(removed));
  },
);

// ─── AC15.3: public suffix ─────────────────────────────────────────────────────

When(
  'a client tries to register with the public suffix client URI {string}',
  async ({ request }: { request: APIRequestContext }, uri: string) => {
    const resp = await request.post(REGISTER_URL, {
      data: registrationBodyForHost(uniqueName(), new URL(uri).host),
    });
    lastRegisterStatus = resp.status();
    lastRegisterError = ((await resp.json()) as { error?: string }).error ?? '';
  },
);

Then('the registration is refused with {string}', async ({}, code: string) => {
  expect(lastRegisterStatus, 'a public-suffix client URI is a 400').toBe(400);
  expect(lastRegisterError).toBe(code);
});

Given(
  'a client is registered on a shared hosting subdomain of {string}',
  async ({ request }: { request: APIRequestContext }, suffix: string) => {
    const name = uniqueName();
    const body = registrationBodyForHost(name, `e2e-${Math.random().toString(36).slice(2, 8)}.${suffix}`);
    sharedClient = { name, clientId: await registerClient(request, body), body };
    expect(queryOAuthClientByName(name)?.status).toBe('pending');
  },
);

Then(
  "that client's row shows the shared hosting warning for {string}",
  async ({ page }: { page: Page }, suffix: string) => {
    const row = rowFor(page, (sharedClient as Registered).clientId);
    await expect(row).toBeVisible({ timeout: 15_000 });
    await expect(row.locator('[data-role="shared-hosting-warning"]')).toContainText(`shared hosting domain (${suffix})`);
    await expect(row.locator('[data-role="public-suffix-error"]')).toHaveCount(0);
  },
);

// ─── AC15.4: keyboard only ─────────────────────────────────────────────────────

/** Tab (never click) until the focused element matches `selector`; fails loudly after `max` presses. */
async function tabTo(page: Page, selector: string, max = 400): Promise<void> {
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  for (let i = 0; i < max; i++) {
    await page.keyboard.press('Tab');
    const hit = await page.evaluate((sel) => document.activeElement?.matches(sel) ?? false, selector);
    if (hit) return;
  }
  throw new Error(`keyboard focus never reached ${selector} within ${max} Tab presses`);
}

When('the operator opens the bulk-remove preview with the keyboard only', async ({ page }: { page: Page }) => {
  await tabTo(page, `a[data-role="bulk-remove-domain"][aria-label="Remove all pending registrations of ${bulkDomain}"]`);
  await Promise.all([page.waitForURL(previewUrl, { timeout: 15_000 }), page.keyboard.press('Enter')]);
});

When('the operator confirms the removal with the keyboard only', async ({ page }: { page: Page }) => {
  await tabTo(page, '[data-role="bulk-remove-confirm"]');
  await confirmRemoval(page, () => page.keyboard.press('Enter'));
});

// ─── AC15.5: invalid criteria are wired for assistive technology ───────────────

When('the operator previews the bulk removal with the host {string}', async ({ page }: { page: Page }, host: string) => {
  const form = page.locator('[data-form="bulk-remove"]');
  await expect(form, 'the list page offers the bulk-remove form').toBeVisible({ timeout: 15_000 });
  await form.getByLabel('Host or domain').fill(host);
  await Promise.all([page.waitForURL(previewUrl, { timeout: 15_000 }), form.locator('button[type="submit"]').first().click()]);
});

Then('the invalid host is announced and wired to its label, error and match group', async ({ page }: { page: Page }) => {
  const alert = page.locator('[data-role="bulk-error"][role="alert"]');
  await expect(alert).toBeVisible({ timeout: 15_000 });
  const alertId = await alert.getAttribute('id');
  expect(alertId, 'the alert has an id the input can point to').toBeTruthy();

  // label <-> input, invalid state and the error in aria-describedby (besides the help text)
  const host = page.getByLabel('Host or domain');
  await expect(host).toHaveAttribute('aria-invalid', 'true');
  const described = (await host.getAttribute('aria-describedby')) ?? '';
  expect(described.split(/\s+/)).toContain(alertId as string);
  expect(described.split(/\s+/).length, 'help text AND error').toBeGreaterThanOrEqual(2);

  // the radio group is a fieldset with a legend (accessible group name)
  await expect(page.getByRole('group', { name: 'Match' })).toBeVisible();
});

Then('the preview offers no removal', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-form="bulk-remove-confirm"]')).toHaveCount(0);
});
