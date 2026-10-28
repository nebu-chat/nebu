/**
 * Playwright global setup — warms storageState + token sidecars for all test users.
 *
 * Story 9-26 — Phase 1, AC3.
 * Story 9-26a — Fix M-5: kai (and tom) are now warmed alongside alex + marie.
 * Story 9-26b — Fix BUG-E2E-02: ensureStorageState() now also writes
 *   auth-state/{user}.token.json sidecars via loginViaOidcBrowser() route
 *   interception. getApiSession() reads from the sidecar instead of the
 *   storageState localStorage (which doesn't contain mx_access_token on
 *   Element Web 1.11+ — it lives in IndexedDB).
 *
 * BUG-E2E-11 fix: admin bootstrap MUST run BEFORE Element Web user logins.
 *   The Elixir core's upsert_with_bootstrap() sets bootstrap_completed=true
 *   when the first Matrix user logs in (fresh DB), WITHOUT writing OIDC config
 *   keys. This pre-empts the admin wizard and breaks all admin auth tests.
 *   Fix: doBootstrapAdmin() runs first in a dedicated browser page.
 *
 * F-03 fix: checks ALL four users before skipping warmup.
 * Freshness check: requires both .json (storageState) AND .token.json (sidecar).
 *
 * Acceptance criterion:
 *   After the first successful `npx playwright test --project=element-web`,
 *   `e2e/auth-state/alex.json`, `marie.json`, `kai.json` exist (storageState)
 *   AND `e2e/auth-state/alex.token.json`, `marie.token.json`, `kai.token.json`
 *   exist (token sidecars) with valid access_token fields.
 */

import * as fs from 'fs';
import * as path from 'path';
import { chromium, request as playwrightRequest } from '@playwright/test';
import { ensureStorageState, getApiSession, createRoom } from './fixtures/dex-auth';
import { doBootstrapAdmin } from './fixtures/admin-bootstrap';
import { NEBU_USERS } from './fixtures/users';
import { assertDexReachable } from './fixtures/dex-preflight';
import { startClientStubs, STUB_CHROMIUM_ARGS } from './fixtures/client-stubs';
import { queryServerConfigValue, upsertServerConfig } from './fixtures/db';

const AUTH_STATE_DIR = path.join(__dirname, 'auth-state');
const MAX_AGE_MS = 12 * 60 * 60 * 1000; // 12 hours

function isStateFresh(name: string): boolean {
  const statePath  = path.join(AUTH_STATE_DIR, `${name}.json`);
  const sidecarPath = path.join(AUTH_STATE_DIR, `${name}.token.json`);
  if (!fs.existsSync(statePath) || !fs.existsSync(sidecarPath)) return false;
  const stat = fs.statSync(statePath);
  return (Date.now() - stat.mtimeMs) < MAX_AGE_MS;
}

export default async function globalSetup(): Promise<() => Promise<void>> {
  // The client side of the OAuth redirects (see fixtures/client-stubs.ts); the returned teardown stops them.
  const stopStubs = await startClientStubs();

  // Ensure output directory exists
  if (!fs.existsSync(AUTH_STATE_DIR)) {
    fs.mkdirSync(AUTH_STATE_DIR, { recursive: true });
  }

  // AC1: fail fast if the OIDC stack (Dex + server SSO redirect) is unreachable.
  // Without this, a missing Dex turns every OIDC flow below into a silent 30s
  // browser navigation timeout. The preflight aborts in a few seconds with an
  // actionable "Dex unreachable" message naming the URL and the fix (`make dev`).
  console.log('[global-setup] Preflight: checking OIDC stack (Dex + server SSO redirect) reachability...');
  await assertDexReachable();
  console.log('[global-setup] Preflight OK — OIDC stack reachable.');

  // BUG-E2E-11 fix: complete admin bootstrap BEFORE any Element Web user logins.
  // The Elixir core auto-bootstraps (sets bootstrap_completed=true without OIDC config)
  // on the first Matrix login. Admin bootstrap must run first to write OIDC config.
  // This is idempotent: if bootstrap is already complete with OIDC config, it's a no-op.
  //
  // NEBU_SKIP_BOOTSTRAP=1 — used when running bootstrap wizard scenarios on a fresh DB.
  // These scenarios test the wizard itself and must run BEFORE bootstrap is complete.
  if (process.env.NEBU_SKIP_BOOTSTRAP === '1') {
    console.log('[global-setup] NEBU_SKIP_BOOTSTRAP=1 — skipping doBootstrapAdmin (bootstrap wizard scenarios).');
  } else {
    const adminBrowser = await chromium.launch({ args: STUB_CHROMIUM_ARGS });
    try {
      const adminCtx  = await adminBrowser.newContext();
      const adminPage = await adminCtx.newPage();
      try {
        console.log('[global-setup] Ensuring admin bootstrap is complete (with OIDC config)...');
        await doBootstrapAdmin(adminPage);
        console.log('[global-setup] Admin bootstrap complete.');
      } finally {
        await adminPage.close();
        await adminCtx.close();
      }
    } finally {
      await adminBrowser.close();
    }
  }

  // An already bootstrapped stack may predate the Matrix client scopes (the wizard step above only runs on a fresh
  // database): without `profile` the Matrix localpart is the opaque `sub`, not alex / marie / kai.
  // Skipped when the stack has no direct DB access (NEBU_DB_URL / psql / docker exec): then the scopes must be set by the operator.
  if (process.env.NEBU_SKIP_BOOTSTRAP !== '1') {
    try {
      if (!queryServerConfigValue('matrix_oidc_extra_scopes')) {
        console.log("[global-setup] matrix_oidc_extra_scopes is empty -> setting 'profile email' (Matrix localparts alex / marie / kai)");
        upsertServerConfig('matrix_oidc_extra_scopes', 'profile email');
      }
    } catch (e) {
      console.warn(`[global-setup] Could not ensure matrix_oidc_extra_scopes: ${e}`);
    }
  }

  // M-5 fix: skip warm-up only when all active users are fresh (state + sidecar both present)
  // NEBU_E2E_SKIP_USER_WARMUP=1: the https oauth stack (CI job e2e-oauth-https) has no Element Web at localhost:7070 and
  // its scenarios need no Matrix user sessions: skip the warm-up and the test rooms instead of waiting out three timeouts.
  const skipWarmup = process.env.NEBU_E2E_SKIP_USER_WARMUP === '1';
  if (skipWarmup) {
    console.log('[global-setup] NEBU_E2E_SKIP_USER_WARMUP=1 — skipping the user warm-up and the test rooms');
  } else if (
    isStateFresh('alex') &&
    isStateFresh('marie') &&
    isStateFresh('tom') &&
    isStateFresh('kai')
  ) {
    console.log('[global-setup] auth-state/{alex,marie,tom,kai}.{json,token.json} are all fresh — skipping warm-up');
  } else {
    console.log('[global-setup] Warming storageState + token sidecars for alex + marie + tom + kai...');
    const browser = await chromium.launch({ args: STUB_CHROMIUM_ARGS });

    try {
      // Warm active users sequentially to avoid Dex being saturated by parallel OIDC flows.
      // Errors are non-fatal: admin-UI tests don't need Element Web storage state.
      // Element-web tests will fail naturally if sidecars are missing.
      // story power-levels-enforcement: tom is kicked in power-levels.feature through the API, so his session is warmed too
      for (const user of [NEBU_USERS.alex, NEBU_USERS.marie, NEBU_USERS.tom, NEBU_USERS.kai]) {
        try {
          await ensureStorageState(browser, user);
          console.log(`[global-setup] Warmed ${user.name}.`);
        } catch (e) {
          console.warn(`[global-setup] WARNING: Could not warm storageState for ${user.name}: ${e}. Element-web tests for this user may fail.`);
        }
      }
      console.log('[global-setup] User warm-up complete (partial failures are non-fatal).');
    } finally {
      await browser.close();
    }
  }

  if (skipWarmup) return stopStubs;

  // Create a test room via Matrix API so the admin Rooms page has at least one entry.
  // Uses alex's token sidecar (always available after warm-up or fresh-state check above).
  // Safe to call every run — the admin rooms page will show ALL rooms.
  try {
    console.log('[global-setup] Creating a test room for admin Rooms page...');
    const apiCtx = await playwrightRequest.newContext();
    try {
      const { token } = await getApiSession(apiCtx, NEBU_USERS.alex);
      await createRoom(apiCtx, token, 'admin-test-room');
      // Also create "e2e-autojoin" — required by auto-join E2E tests (admin-auto-join-rooms story).
      // NOTE: "General" is used as a stub-data sentinel in rooms-api-integration.spec.ts,
      // so the auto-join tests use a distinct room name to avoid that conflict.
      await createRoom(apiCtx, token, 'e2e-autojoin').catch(() => { /* may already exist */ });
      console.log('[global-setup] Test rooms created.');
    } finally {
      await apiCtx.dispose();
    }
  } catch (e) {
    console.warn(`[global-setup] Could not create test room: ${e}. Rooms page test may fail.`);
  }

  return stopStubs;
}
