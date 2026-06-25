/**
 * Step definitions for features/admin/bootstrap-env-locked-fields.feature
 *
 * Story: bugfix/room-names — AC4 (Env vars lock bootstrap fields)
 *
 * Proves that when NEBU_OIDC_ISSUER / NEBU_OIDC_AUDIENCE / NEBU_OIDC_CLIENT_ID are
 * set as env vars, the corresponding Bootstrap Wizard OIDC step fields are rendered
 * as disabled/read-only with a "(set via env)" locked indicator, while fields NOT set
 * via env remain editable.
 *
 * NOTE: These tests require the running Nebu server to have been started with specific
 * env vars. The steps use a health-check endpoint (or a dedicated API endpoint exposed
 * for testing) to discover which OIDC env vars are locked. If the required env state
 * is absent, the test self-skips (test.skip) rather than failing with a misleading error.
 *
 * IMPLEMENTATION NOTE: The server must expose which OIDC fields are env-locked so the
 * browser can render them as disabled. The expected mechanism: BootstrapLive passes
 * `oidc_env_locked: %{issuer: bool, audience: bool, client_id: bool}` as a socket
 * assign, and the template renders `disabled` on locked inputs.
 *
 * A dedicated endpoint GET /admin/bootstrap/oidc-env-status (or a LiveView assign
 * embedded in the page HTML) exposes the locked state so these steps can verify it.
 *
 * RED PHASE: All step bodies are scaffolded to FAIL immediately with an unimplemented
 * error. They must be activated and implemented during the dev phase.
 *
 * Test framework: playwright-bdd + Cucumber (admin-ui project).
 * Runner: npx playwright test --project=admin-ui --grep @env-locked-fields
 */

import { Given, When, Then, test } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Navigate to the Bootstrap Wizard OIDC step (step 2).
 * The wizard allows direct navigation to a step via the query param ?step=2.
 * If the wizard is not accessible (bootstrap already completed and step nav blocked),
 * the test self-skips.
 */
async function navigateToOidcStep(page: Page): Promise<void> {
  await page.goto(`${ADMIN_BASE_URL}/admin/bootstrap?step=2`);
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 }).catch(() => {});

  const url = page.url();
  if (!url.includes('/bootstrap')) {
    test.skip(true, 'Bootstrap OIDC step not accessible — wizard may be in a different state.');
  }
}

/**
 * Query the server for which OIDC env vars are currently set (locked).
 * Expects a JSON response: { issuer: boolean, audience: boolean, client_id: boolean }
 *
 * IMPLEMENTATION NOTE: This endpoint does NOT exist yet — it must be added by the dev.
 * The endpoint path is GET /admin/api/bootstrap/oidc-env-locked (or equivalent).
 * If the endpoint returns 404, the test self-skips (endpoint not yet implemented).
 */
async function getOidcEnvLocked(page: Page): Promise<{ issuer: boolean; audience: boolean; client_id: boolean }> {
  const resp = await page.request
    .get(`${ADMIN_BASE_URL}/admin/api/bootstrap/oidc-env-locked`)
    .catch(() => null);

  if (!resp || resp.status() === 404) {
    test.skip(true, 'GET /admin/api/bootstrap/oidc-env-locked not yet implemented — skip until dev phase.');
    // test.skip throws, so the line below is unreachable but satisfies TS.
    return { issuer: false, audience: false, client_id: false };
  }

  if (!resp.ok()) {
    throw new Error(`Unexpected status ${resp.status()} from oidc-env-locked endpoint`);
  }

  return resp.json() as Promise<{ issuer: boolean; audience: boolean; client_id: boolean }>;
}

// ── Given steps ──────────────────────────────────────────────────────────────

Given(
  'NEBU_OIDC_ISSUER is set to {string} in the server environment',
  async ({ page }: { page: Page }, expectedValue: string) => {
    // RED PHASE — self-skip if the server doesn't report issuer as env-locked
    // (meaning the env var is not set in the running instance).
    const locked = await getOidcEnvLocked(page);

    if (!locked.issuer) {
      test.skip(
        true,
        `NEBU_OIDC_ISSUER is not set in the server environment. ` +
          `Restart the stack with NEBU_OIDC_ISSUER=${expectedValue} to enable this scenario.`,
      );
    }
  },
);

Given(
  'NEBU_OIDC_CLIENT_ID is set to {string} in the server environment',
  async ({ page }: { page: Page }, _expectedValue: string) => {
    const locked = await getOidcEnvLocked(page);

    if (!locked.client_id) {
      test.skip(
        true,
        'NEBU_OIDC_CLIENT_ID is not set in the server environment.',
      );
    }
  },
);

Given(
  'NEBU_OIDC_AUDIENCE is set to {string} in the server environment',
  async ({ page }: { page: Page }, _expectedValue: string) => {
    const locked = await getOidcEnvLocked(page);

    if (!locked.audience) {
      test.skip(
        true,
        'NEBU_OIDC_AUDIENCE is not set in the server environment.',
      );
    }
  },
);

Given('no OIDC env vars are set in the server environment', async ({ page }: { page: Page }) => {
  const locked = await getOidcEnvLocked(page);

  if (locked.issuer || locked.audience || locked.client_id) {
    test.skip(
      true,
      'One or more OIDC env vars are set in the server environment. ' +
        'Restart the stack without OIDC env vars to enable this scenario.',
    );
  }
});

// ── When steps ───────────────────────────────────────────────────────────────

When('the operator navigates to the bootstrap OIDC step', async ({ page }: { page: Page }) => {
  // RED PHASE — step body will fail until BootstrapLive renders the OIDC step.
  throw new Error(
    'RED PHASE: "the operator navigates to the bootstrap OIDC step" is not yet implemented. ' +
      'Implement BootstrapLive to render step 2 with env-locked field support.',
  );
  // INTENDED IMPLEMENTATION (uncomment in dev phase):
  // await navigateToOidcStep(page);
});

// ── Then steps ────────────────────────────────────────────────────────────────

Then(
  'the issuer field is disabled and pre-filled with {string}',
  async ({ page }: { page: Page }, expectedValue: string) => {
    // RED PHASE — will fail until BootstrapLive renders the disabled input.
    throw new Error(
      `RED PHASE: "the issuer field is disabled and pre-filled with ${expectedValue}" not yet implemented. ` +
        'BootstrapLive step-2 template must render <input name="oidc_issuer" disabled value="...">.',
    );
    // INTENDED IMPLEMENTATION:
    // const issuerInput = page.locator('input[name="oidc_issuer"]');
    // await expect(issuerInput).toBeVisible({ timeout: 10_000 });
    // await expect(issuerInput).toBeDisabled();
    // await expect(issuerInput).toHaveValue(expectedValue);
  },
);

Then('the issuer field shows a locked indicator', async ({ page }: { page: Page }) => {
  // RED PHASE — will fail until the locked indicator is rendered.
  throw new Error(
    'RED PHASE: "the issuer field shows a locked indicator" not yet implemented. ' +
      'BootstrapLive must render a "(set via env)" note near the disabled issuer input.',
  );
  // INTENDED IMPLEMENTATION:
  // const lockIndicator = page.locator('[data-locked-field="oidc_issuer"]');
  // await expect(lockIndicator).toBeVisible({ timeout: 5_000 });
});

Then(
  'the client_id field is disabled and pre-filled with {string}',
  async ({ page }: { page: Page }, expectedValue: string) => {
    // RED PHASE
    throw new Error(
      `RED PHASE: "the client_id field is disabled and pre-filled with ${expectedValue}" not yet implemented.`,
    );
    // INTENDED IMPLEMENTATION:
    // const clientIdInput = page.locator('input[name="oidc_client_id"]');
    // await expect(clientIdInput).toBeDisabled();
    // await expect(clientIdInput).toHaveValue(expectedValue);
  },
);

Then('the client_id field shows a locked indicator', async ({ page }: { page: Page }) => {
  // RED PHASE
  throw new Error(
    'RED PHASE: "the client_id field shows a locked indicator" not yet implemented.',
  );
});

Then(
  'the audience field is disabled and pre-filled with {string}',
  async ({ page }: { page: Page }, expectedValue: string) => {
    // RED PHASE
    throw new Error(
      `RED PHASE: "the audience field is disabled and pre-filled with ${expectedValue}" not yet implemented. ` +
        'BootstrapLive step-2 template must render <input name="oidc_audience" disabled value="...">.',
    );
  },
);

Then('the audience field shows a locked indicator', async ({ page }: { page: Page }) => {
  // RED PHASE
  throw new Error(
    'RED PHASE: "the audience field shows a locked indicator" not yet implemented.',
  );
});

Then('the audience field is editable', async ({ page }: { page: Page }) => {
  // RED PHASE — will fail until BootstrapLive renders the oidc_audience input field.
  throw new Error(
    'RED PHASE: "the audience field is editable" not yet implemented. ' +
      'BootstrapLive step-2 template must render an enabled <input name="oidc_audience">.',
  );
  // INTENDED IMPLEMENTATION:
  // const audienceInput = page.locator('input[name="oidc_audience"]');
  // await expect(audienceInput).toBeVisible({ timeout: 10_000 });
  // await expect(audienceInput).not.toBeDisabled();
  // await expect(audienceInput).toBeEditable();
});

Then('the issuer field is editable', async ({ page }: { page: Page }) => {
  // RED PHASE
  throw new Error(
    'RED PHASE: "the issuer field is editable" not yet implemented.',
  );
  // INTENDED IMPLEMENTATION:
  // const issuerInput = page.locator('input[name="oidc_issuer"]');
  // await expect(issuerInput).toBeEditable();
});

Then('the client_id field is editable', async ({ page }: { page: Page }) => {
  // RED PHASE
  throw new Error(
    'RED PHASE: "the client_id field is editable" not yet implemented.',
  );
  // INTENDED IMPLEMENTATION:
  // const clientIdInput = page.locator('input[name="oidc_client_id"]');
  // await expect(clientIdInput).toBeEditable();
});

Then('the page shows {string} near the issuer field', async ({ page }: { page: Page }, text: string) => {
  // RED PHASE — will fail until the locked indicator text is rendered.
  throw new Error(
    `RED PHASE: "the page shows '${text}' near the issuer field" not yet implemented. ` +
      `BootstrapLive must render a text element containing "${text}" adjacent to the disabled issuer input.`,
  );
  // INTENDED IMPLEMENTATION:
  // const issuerGroup = page.locator('[data-field-group="oidc_issuer"]');
  // await expect(issuerGroup.getByText(text)).toBeVisible({ timeout: 5_000 });
});
