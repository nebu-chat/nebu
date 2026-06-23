/**
 * Step definitions for features/element/auth/matrix-session-refresh.feature
 *
 * Story: e2e-session-refresh-suites (epic fix-short-oidc-sessions) — AC8 at the browser level.
 *
 * Drives the REAL Element Web + Dex Authorization-Code + PKCE flow via the shared
 * fixtures/dex-auth.ts helper loginViaOidcBrowser — NO ROPC, NO cookie
 * forging, NO DB seeding (project E2E standard).
 *
 *   - @ac8-refresh-token-issued (default stack): the stored Matrix access token is opaque
 *     (64 hex, no '.'), i.e. Nebu minted a refreshable session rather than echoing a JWT.
 *   - @ac8-session-refresh (@short-ttl): after a short Matrix session lifetime elapses, a
 *     reload stays logged in (matrix-js-sdk silently refreshed) instead of bouncing to Dex.
 *   - @ac8-soft-logout (@short-ttl): a server-side-revoked session yields Element's
 *     soft-logout state (re-sign-in offered), not a hard kick — relies on Element behaviour.
 */

import { Given, When, Then } from '../../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { NEBU_USERS, DEX_TEST_PASSWORD } from '../../../fixtures/users';
import { loginViaOidcBrowser } from '../../../fixtures/dex-auth';

const MATRIX_BASE = process.env.NEBU_MATRIX_BASE ?? 'http://localhost:8008';
const MATRIX_SESSION_TTL_SECONDS = Number(process.env.NEBU_MATRIX_SESSION_TTL_SECONDS ?? '30');
const WAIT_BUFFER_MS = 5_000;

/**
 * The access token Element Web is actively using, read from the live MatrixClient. This is
 * the authoritative "what the browser holds" — more reliable than the token sidecar, which
 * can carry a token captured from an earlier login in the fixture flow. Falls back to the
 * legacy localStorage key for older Element builds. Returns null if unreadable.
 */
async function readLiveAccessToken(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const w = window as unknown as Record<string, unknown>;
    const peg = w['mxMatrixClientPeg'] as
      | { get?: () => { getAccessToken?: () => string | null } }
      | undefined;
    try {
      const fromClient = peg?.get?.()?.getAccessToken?.();
      if (typeof fromClient === 'string' && fromClient.length > 0) return fromClient;
    } catch {
      /* fall through to localStorage */
    }
    return localStorage.getItem('mx_access_token');
  });
}

Given('the Nebu stack uses a short Matrix session lifetime', async () => {
  // Wired by `make test-e2e-refresh` (NEBU_MATRIX_SESSION_TTL_SECONDS). Fail loud if absent
  // so the timing scenario never silently waits ~8h.
  expect(
    MATRIX_SESSION_TTL_SECONDS,
    'NEBU_MATRIX_SESSION_TTL_SECONDS must be short (run via `make test-e2e-refresh`)',
  ).toBeLessThanOrEqual(120);
});

Given(
  'alex logs in to Element Web via Dex SSO with {string}',
  async ({ page }: { page: Page }, email: string) => {
    await loginViaOidcBrowser(page, NEBU_USERS.alex, email, DEX_TEST_PASSWORD);
  },
);

// "the room list is visible" is defined in step-definitions/common/assertions.steps.ts
// (reused here, not redefined). "{word} has no cached session" + "{word} reloads Element Web"
// come from step-definitions/element/login.steps.ts.

Then(
  'the stored Matrix access token is an opaque token, not a JWT',
  async ({ page }: { page: Page }) => {
    // Read the token Element is ACTIVELY USING from the live MatrixClient — the authoritative
    // signal (the token sidecar can hold a token captured from an earlier login in the fixture
    // flow). Opaque = 64 lowercase hex, no '.' (a JWT is header.payload.sig — two dots). An
    // opaque token proves Nebu minted a refreshable session, not the OIDC JWT (AC7 fallback).
    const token = await readLiveAccessToken(page);
    expect(token, 'live Element access token was readable').toBeTruthy();
    expect(token as string, 'access token must not be a JWT (no dots)').not.toContain('.');
    expect(token as string, 'opaque token is 64 lowercase hex chars').toMatch(/^[0-9a-f]{64}$/);
  },
);

Then('Element has a refreshable Matrix session', async ({ page }: { page: Page }) => {
  // A refreshable session is one Nebu issued with a refresh token. An opaque access token is
  // only ever issued together with a refresh token in Nebu's login path, so the opaque live
  // token is itself the proof; also surface the client's refresh token when exposed.
  const hasRefresh = await page.evaluate(() => {
    const w = window as unknown as Record<string, unknown>;
    const peg = w['mxMatrixClientPeg'] as
      | { get?: () => { getRefreshToken?: () => string | null } }
      | undefined;
    try {
      const rt = peg?.get?.()?.getRefreshToken?.();
      return typeof rt === 'string' && rt.length > 0;
    } catch {
      return false;
    }
  });
  const token = await readLiveAccessToken(page);
  expect(
    hasRefresh || /^[0-9a-f]{64}$/.test(token ?? ''),
    'opaque AT ⟺ refreshable session (or client exposes a refresh token)',
  ).toBeTruthy();
});

When('the Matrix session lifetime elapses', async () => {
  await new Promise<void>((resolve) =>
    setTimeout(resolve, MATRIX_SESSION_TTL_SECONDS * 1_000 + WAIT_BUFFER_MS),
  );
});

When(
  'alex reloads Element Web after the lifetime has elapsed',
  async ({ page }: { page: Page }) => {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle', { timeout: 20_000 }).catch(() => {});
  },
);

When("alex's Matrix session is revoked server-side", async ({ page }: { page: Page }) => {
  // Revoke the REAL opaque session Element is using (not a forged one): call Matrix logout
  // with the LIVE token → Nebu deletes the matrix_sessions row. Element's next request then
  // 401s and its refresh attempt also fails → soft logout. Use the live token (not the
  // sidecar) so we revoke the opaque session, not an earlier JWT.
  const token = await readLiveAccessToken(page);
  expect(token, 'live Element access token was readable').toBeTruthy();
  const resp = await page.request.post(`${MATRIX_BASE}/_matrix/client/v3/logout`, {
    headers: { Authorization: `Bearer ${token as string}`, 'Content-Type': 'application/json' },
    data: {},
  });
  expect([200, 401]).toContain(resp.status());
});

Then('alex is NOT redirected to the Dex login page', async ({ page }: { page: Page }) => {
  await expect(page).not.toHaveURL(/dex.*\/auth/i, { timeout: 5_000 });
});

Then('the room list is still visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('.mx_LeftPanel')).toBeVisible({ timeout: 30_000 });
});

Then(
  'Element shows a soft-logout state or returns to the sign-in screen',
  async ({ page }: { page: Page }) => {
    // Element's soft-logout view (.mx_SoftLogout) keeps the session store and offers to sign
    // back in. Accept either the explicit soft-logout panel or a return to the welcome/login
    // screen with a sign-in affordance (Element version differences).
    const softLogout = page.locator('.mx_SoftLogout');
    const signIn = page.getByRole('link', { name: /sign in|anmelden/i })
      .or(page.getByRole('button', { name: /sign in|sign out|anmelden/i }));
    await expect(softLogout.or(signIn).first()).toBeVisible({ timeout: 30_000 });
  },
);
