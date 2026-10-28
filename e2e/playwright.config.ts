/**
 * Playwright configuration for Nebu E2E tests.
 *
 * Story 9-26 — Phase 1, AC1 + AC5.
 *
 * Projects:
 * - admin-ui          : Admin UI BDD tests via playwright-bdd (Phase 3)
 * - element-web       : Element Web browser-first E2E (Phase 2)
 * - website           : Static website smoke tests (Phase 3, Story 16.2)
 *                       Self-skip when WEBSITE_BASE_URL is not reachable.
 *
 * NOTE: The legacy `chromium` project (tests/**\/*.spec.ts) was removed.
 * The 34 legacy spec files in e2e/tests/ are ATDD red-phase and API-contract
 * tests owned by individual stories (9.2, 9.3, 9.13, 9.15, etc.).
 * Fully-skipped files have been deleted. The remaining files will be migrated
 * to playwright-bdd .feature files as each owning story closes.
 * To run legacy specs manually: npx playwright test --config=tests/playwright.legacy.config.ts
 */

import { defineConfig, devices } from '@playwright/test';
import { defineBddConfig, defineBddProject } from 'playwright-bdd';
import { STUB_CHROMIUM_ARGS } from './fixtures/client-stubs';

// Tag expression applied at bddgen time. Default run excludes @pending-feature scaffolds
// and the @short-ttl session-refresh scenarios (those need a short-TTL stack and run via
// `make test-e2e-refresh`, which sets NEBU_E2E_TAGS='@short-ttl' to include ONLY them).
// @known-failure: a scenario that fails for a DOCUMENTED reason that is not (yet) a verified defect of the system under test (see e2e/KNOWN-FAILURES.md):
// excluded from the default run, never silently: `NEBU_E2E_TAGS='@known-failure'` runs exactly those.
const DEFAULT_E2E_TAGS = 'not @pending-feature and not @short-ttl and not @known-failure';
const E2E_TAGS = process.env.NEBU_E2E_TAGS ?? DEFAULT_E2E_TAGS;

// Story e2e-browser-ci-and-dex-reliability (AC2): emulation-tolerant, env-configurable
// timeouts. Defaults are raised enough to tolerate arm64-emulated Dex locally; amd64 CI
// can lower them. These bound *navigation* and per-action waits, not the short element
// detection probes inside the login fixture (those stay tight to avoid masking hangs).
const NAV_TIMEOUT_MS = Number(process.env.NEBU_E2E_NAV_TIMEOUT_MS ?? 60_000);
const ACTION_TIMEOUT_MS = Number(process.env.NEBU_E2E_ACTION_TIMEOUT_MS ?? 20_000);

// Use defineBddProject() which correctly returns { name, testDir } for multi-project setups.
// This avoids the "please manually provide different outputDir" error.
// importTestFrom points bddgen to the custom test instance (fixture file).

const elementWebProject = defineBddProject({
  name: 'element-web',
  features: 'features/element/**/*.feature',
  steps:    'step-definitions/**/*.ts',
  importTestFrom: 'fixtures/nebu-fixtures.ts',
  disableWarnings: { importTestFrom: true },
  // @pending-feature scenarios are acceptance scaffolds for capabilities not yet shipped
  // (room/upgrade — Nebu creates rooms at v10, so Element offers no upgrade path; pending a
  // product decision). Excluded from the suite rather than counted as regressions, matching
  // the admin-ui project's filter.
  // @short-ttl scenarios (e2e-session-refresh-suites) need a stack started with a SHORT
  // NEBU_*_SESSION_TTL_SECONDS so the refresh loop fires in a test window — they cannot run
  // against the shared 8h stack (they'd wait hours). They run only via `make test-e2e-refresh`
  // (a dedicated short-TTL stack), so exclude them from the default run here too.
  tags: E2E_TAGS,
});

const adminUiProject = defineBddProject({
  name: 'admin-ui',
  // features/oauth (epic oauth-broker): browser flows against Nebu's own OAuth endpoints
  // (baseURL = Nebu, like the admin UI) — no separate project needed.
  features: ['features/admin/**/*.feature', 'features/oauth/**/*.feature'],
  steps:    'step-definitions/**/*.ts',
  importTestFrom: 'fixtures/nebu-fixtures.ts',
  disableWarnings: { importTestFrom: true },
  // @pending-feature scenarios are RED-phase acceptance scaffolds for features that are
  // not yet implemented (OIDC directory user search — Story 14-2c; SCIM / Bootstrap
  // Step-4 user import — Story 14-3c). They intentionally fail until those features ship,
  // so they are excluded from the suite until then rather than counted as regressions.
  // @short-ttl scenarios (e2e-session-refresh-suites) require a stack started with a short
  // NEBU_ADMIN_SESSION_TTL_SECONDS; they run only via `make test-e2e-refresh`. Exclude here.
  tags: E2E_TAGS,
});

// Story 16.2 — website smoke tests (static site, self-skip when not reachable)
const websiteProject = defineBddProject({
  name: 'website',
  features: 'features/website/**/*.feature',
  steps:    'step-definitions/**/*.ts',
  importTestFrom: 'fixtures/nebu-fixtures.ts',
  disableWarnings: { importTestFrom: true },
});

export default defineConfig({
  globalSetup: './global-setup.ts',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,   // shared DB — serial execution required
  retries: 0,
  reporter: [['list'], ['html', { outputFolder: 'playwright-report', open: 'never' }]],
  use: {
    baseURL: process.env.NEBU_BASE_URL ?? 'http://localhost:8008',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    // ── Phase 3: Admin UI BDD (playwright-bdd) ───────────────────────────────
    {
      ...adminUiProject,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008',
        actionTimeout: ACTION_TIMEOUT_MS,
        navigationTimeout: NAV_TIMEOUT_MS,
        // The OAuth client redirect targets (*.e2e.example, fixtures/client-stubs.ts) are answered by a local HTTPS stub with a
        // self-signed certificate; the https oauth stack (dev/tls, local CA) is reached through the same browser.
        ignoreHTTPSErrors: true,
        launchOptions: { args: STUB_CHROMIUM_ARGS },
      },
      // 180s ceiling: the @short-ttl admin session-refresh scenarios deliberately wait across
      // several short token lifetimes (~105s for three). Fast admin tests still finish fast —
      // only the ceiling rises (element-web is already 300s for the analogous reason).
      timeout: 180_000,
    },

    // ── Phase 2: Element Web Browser-First E2E (playwright-bdd) ─────────────
    {
      ...elementWebProject,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070',
        actionTimeout: ACTION_TIMEOUT_MS,
        navigationTimeout: NAV_TIMEOUT_MS,
      },
      timeout: 300_000,
    },

    // ── Phase 3: Website Smoke Tests (playwright-bdd, Story 16.2) ───────────
    // Self-skip when WEBSITE_BASE_URL is not reachable (static site).
    {
      ...websiteProject,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.WEBSITE_BASE_URL ?? 'http://localhost:4000',
        actionTimeout: 15_000,
        navigationTimeout: 30_000,
      },
      timeout: 60_000,
    },
  ],
});
