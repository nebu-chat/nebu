/**
 * Step definitions for features/admin/logs-config.feature
 *
 * Story enhanced-logging/admin-logs-retention-settings — ATDD, written FIRST.
 * docs/stories/enhanced-logging/admin-logs-retention-settings.md
 *
 * RED PHASE: step bodies target markup/behavior that does not exist yet
 * (Nebu.Admin.LogsController, /admin/logs/config route, wireLogsConfigToggles()
 * in app.js — see design-decisions.md). Every scenario referencing these steps
 * is tagged @pending-feature (see e2e/playwright.config.ts's DEFAULT_E2E_TAGS)
 * and therefore excluded from the default suite until the dev-story implements
 * it — mirroring the exact convention used for the sibling
 * admin-logs-monitoring-view story's original logs-monitoring.feature RED phase.
 *
 * Data-attribute contract pinned down here for the dev agent (see
 * design-decisions.md #2 for why interaction is plain client-side JS, not
 * LiveView phx-click):
 *   - Level bubble (reused trace_map_bubble, mode={:configure}):
 *     [data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value=...]
 *   - Inline retention fields container (AC9):
 *     [data-testid="retention-fields"][data-bubble-value="info"|"debug"]
 *     containing input[name="info_days"|"debug_days"] and
 *     input[name="info_max_entries"|"debug_max_entries"]
 *   - DEBUG excessive-logging warning (AC11): [data-testid="debug-warning"]
 *   - Save button: a real <button type="submit"> inside the retention form
 *     (AC13 — traditional POST, not LiveView)
 *
 * Shared background steps reused from admin/bootstrap.steps.ts:
 *   - "the Nebu stack is running"        (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *   - "the page shows a success flash message" (shared, from
 *     oidc-directory-config.steps.ts — currently a RED-phase throw; reused
 *     as-is rather than duplicated, per this project's one-definition-per-step-text
 *     convention. Its error message references a different story number; this is
 *     a pre-existing cosmetic inaccuracy in shared infra, out of scope here.)
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

function bubbleLocator(page: Page, value: string) {
  return page.locator(
    `[data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value="${value}"]`,
  );
}

function retentionFieldsLocator(page: Page, value: string) {
  return page.locator(`[data-testid="retention-fields"][data-bubble-value="${value}"]`);
}

function warningLocator(page: Page) {
  return page.locator('[data-testid="debug-warning"]');
}

// ─── Given: policy preconditions (via the real admin config POST, not a DB backdoor) ──

async function setLevelEnabled(page: Page, level: 'info' | 'debug', enabled: boolean) {
  // RED PHASE: relies on the very form this story implements. Until it exists,
  // navigating here 404s, which is expected/fine for a Given precondition in a
  // red-phase scaffold — the scenario's own When/Then steps are what must go
  // green once the story ships, and this precondition will then work for real
  // (submitting the existing state unchanged for the level not under test).
  await page.goto('/admin/logs/config');
  const bubble = bubbleLocator(page, level);
  const pressed = (await bubble.getAttribute('aria-pressed')) === 'true';
  if (pressed !== enabled) {
    await bubble.click();
  }
  await page.locator('form[data-testid="logs-retention-form"] button[type="submit"]').click();
}

Given('INFO collection is currently off', async ({ page }: { page: Page }) => {
  await setLevelEnabled(page, 'info', false);
});

Given('DEBUG collection is currently off', async ({ page }: { page: Page }) => {
  await setLevelEnabled(page, 'debug', false);
});

// ─── When: navigation / interaction ──────────────────────────────────────────

When('the operator clicks the {string} link', async ({ page }: { page: Page }, linkText: string) => {
  await page.getByRole('link', { name: new RegExp(linkText, 'i') }).click();
});

When(
  'the operator clicks the {string} level bubble in the config page',
  async ({ page }: { page: Page }, value: string) => {
    await bubbleLocator(page, value).click();
  },
);

When(
  'the operator sets the {string} days field to {string}',
  async ({ page }: { page: Page }, level: string, days: string) => {
    await retentionFieldsLocator(page, level).locator(`input[name="${level}_days"]`).fill(days);
  },
);

When('the operator saves the logs retention settings form', async ({ page }: { page: Page }) => {
  const form = page.locator('form[data-testid="logs-retention-form"]');
  await form.locator('button[type="submit"]').click();
  await page.waitForURL(/\/admin\/logs\/config$/, { timeout: 10_000 });
});

// ─── Then: URL / navigation ──────────────────────────────────────────────────

Then('the page shows {string} in the URL', async ({ page }: { page: Page }, expectedPath: string) => {
  await expect(page).toHaveURL(new RegExp(expectedPath.replace(/\//g, '\\/')), { timeout: 10_000 });
});

// ─── Then: AC5/AC6 — WARN/ERROR always-on, non-interactive; INFO/DEBUG toggleable ──

Then(
  'the {string} level bubble in the config page shows {string}',
  async ({ page }: { page: Page }, value: string, expectedText: string) => {
    const bubble = bubbleLocator(page, value);
    await expect(bubble).toBeVisible({ timeout: 10_000 });
    const text = (await bubble.innerText()).toLowerCase();
    const matchesAlways = text.includes('immer') || text.includes('always');
    expect(
      matchesAlways,
      `expected the "${value}" bubble to indicate "${expectedText}", got text: "${text}"`,
    ).toBe(true);
  },
);

Then(
  'the {string} level bubble in the config page is not a toggle button',
  async ({ page }: { page: Page }, value: string) => {
    const bubble = bubbleLocator(page, value);
    const tag = await bubble.evaluate((el) => el.tagName.toLowerCase());
    const ariaDisabled = await bubble.getAttribute('aria-disabled');
    expect(
      tag !== 'button' || ariaDisabled === 'true',
      `expected the "${value}" bubble to be non-interactive (no <button>, or aria-disabled="true")`,
    ).toBe(true);
  },
);

Then(
  'the {string} level bubble in the config page is a toggle button',
  async ({ page }: { page: Page }, value: string) => {
    const bubble = bubbleLocator(page, value);
    await expect(bubble).toBeVisible({ timeout: 10_000 });
    const tag = await bubble.evaluate((el) => el.tagName.toLowerCase());
    expect(tag, `expected the "${value}" bubble to be a real <button>`).toBe('button');
  },
);

// ─── Then: AC7/AC8/AC9 — inline retention fields reveal/hide + defaults ──────────

Then('the retention fields for {string} are not visible', async ({ page }: { page: Page }, value: string) => {
  await expect(retentionFieldsLocator(page, value)).toBeHidden({ timeout: 10_000 });
});

Then('the retention fields for {string} are visible', async ({ page }: { page: Page }, value: string) => {
  await expect(retentionFieldsLocator(page, value)).toBeVisible({ timeout: 10_000 });
});

Then(
  'the {string} days field shows {string}',
  async ({ page }: { page: Page }, level: string, expected: string) => {
    const field = retentionFieldsLocator(page, level).locator(`input[name="${level}_days"]`);
    await expect(field).toHaveValue(expected, { timeout: 10_000 });
  },
);

Then(
  'the {string} max entries field shows {string}',
  async ({ page }: { page: Page }, level: string, expected: string) => {
    const field = retentionFieldsLocator(page, level).locator(`input[name="${level}_max_entries"]`);
    await expect(field).toHaveValue(expected, { timeout: 10_000 });
  },
);

// ─── Then: AC11/AC12 — DEBUG excessive-logging warning ───────────────────────────

Then('the DEBUG excessive-logging warning is visible', async ({ page }: { page: Page }) => {
  await expect(warningLocator(page)).toBeVisible({ timeout: 10_000 });
});

Then('the DEBUG excessive-logging warning is not visible', async ({ page }: { page: Page }) => {
  await expect(warningLocator(page)).toBeHidden({ timeout: 10_000 });
});

Then(
  'the DEBUG excessive-logging warning mentions {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    await expect(warningLocator(page)).toContainText(expectedSubstring, { timeout: 10_000 });
  },
);
