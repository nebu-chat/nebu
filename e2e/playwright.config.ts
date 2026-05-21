/**
 * Playwright configuration for Nebu E2E tests.
 *
 * Story 9-26 — Phase 1, AC1 + AC5.
 *
 * Projects:
 * - chromium          : existing API-contract tests (unchanged)
 * - admin-ui          : Admin UI BDD tests via playwright-bdd (Phase 3)
 * - element-web       : Element Web browser-first E2E (Phase 2)
 * - website           : Static website smoke tests (Phase 3, Story 16.2)
 *                       Self-skip when WEBSITE_BASE_URL is not reachable.
 */

import { defineConfig, devices } from '@playwright/test';
import { defineBddConfig, defineBddProject } from 'playwright-bdd';

// Use defineBddProject() which correctly returns { name, testDir } for multi-project setups.
// This avoids the "please manually provide different outputDir" error.
// importTestFrom points bddgen to the custom test instance (fixture file).

const elementWebProject = defineBddProject({
  name: 'element-web',
  features: 'features/element/**/*.feature',
  steps:    'step-definitions/**/*.ts',
  importTestFrom: 'fixtures/nebu-fixtures.ts',
  disableWarnings: { importTestFrom: true },
});

const adminUiProject = defineBddProject({
  name: 'admin-ui',
  features: 'features/admin/**/*.feature',
  steps:    'step-definitions/**/*.ts',
  importTestFrom: 'fixtures/nebu-fixtures.ts',
  disableWarnings: { importTestFrom: true },
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
    // ── Existing: API-Contract Tests (no BDD, no change) ─────────────────────
    {
      name: 'chromium',
      testDir: './tests',
      use: { ...devices['Desktop Chrome'] },
    },

    // ── Phase 3: Admin UI BDD (playwright-bdd) ───────────────────────────────
    {
      ...adminUiProject,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008',
        actionTimeout: 20_000,
        navigationTimeout: 45_000,
      },
      timeout: 90_000,
    },

    // ── Phase 2: Element Web Browser-First E2E (playwright-bdd) ─────────────
    {
      ...elementWebProject,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: process.env.NEBU_ELEMENT_URL ?? 'http://localhost:7070',
        actionTimeout: 20_000,
        navigationTimeout: 45_000,
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
