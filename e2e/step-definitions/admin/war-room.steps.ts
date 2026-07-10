/**
 * Step definitions for features/admin/war-room.feature
 *
 * Story enhanced-logging/war-room-mode — ATDD, written FIRST.
 * docs/stories/enhanced-logging/war-room-mode.md
 * Design decisions: _bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md
 *
 * GREEN PHASE: step bodies target markup/behavior implemented by the
 * dev-story (Nebu.Web.LogStore.WarRoom, Nebu.Admin.WarRoomManager,
 * Nebu.Admin.LogsLive.WarRoomPanel — see design-decisions.md). The
 * @pending-feature tag has been removed from war-room.feature's scenarios
 * — they now run in the default suite, mirroring logs-config.steps.ts's own
 * dev-story un-tagging.
 *
 * Data-attribute contract pinned down here for the dev agent — see
 * war-room.feature's header comment for the full list, and
 * server/test/nebu/admin/logs_live_test.exs's "enhanced-logging/war-room-mode
 * (AC11)" describe block for the identical contract pinned down on the
 * ExUnit side.
 *
 * Shared background/navigation steps reused from existing step files (this
 * project's one-definition-per-step-text convention — see logs-config.steps.ts's
 * own header comment for the same note):
 *   - "the Nebu stack is running"           (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"        (admin/bootstrap.steps.ts)
 *   - "the operator is logged in as admin"  (admin/bootstrap.steps.ts)
 *   - "the operator navigates to {string}"  (admin/logs-config.steps.ts)
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

function panelLocator(page: Page) {
  return page.locator('[data-testid="war-room-panel"]');
}

function startFormLocator(page: Page) {
  return page.locator('[data-testid="war-room-start-form"]');
}

function warningAllLocator(page: Page) {
  return page.locator('[data-testid="war-room-warning-all"]');
}

function warningSyncLocator(page: Page) {
  return page.locator('[data-testid="war-room-warning-sync"]');
}

function statusLocator(page: Page) {
  return page.locator('[data-testid="war-room-status"]');
}

// ─── When: interaction ────────────────────────────────────────────────────

When(
  'the operator selects {string} as the War Room scope',
  async ({ page }: { page: Page }, scope: string) => {
    // Coordinator finding 2/4 (2026-07-08): this select's `phx-change`
    // requires a genuine server round trip to reveal the exclusive-scope
    // options (war-room-dedicated-page's AC9) — on the throttled-longpoll
    // transport the socket connects a few seconds after first paint (same
    // race the sibling "starts a War Room..." step below already guards
    // against); selecting before that silently no-ops against the static,
    // unconnected render.
    await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 20_000 });
    await startFormLocator(page).locator('select[name="scope"]').selectOption(scope);
  },
);

When(
  'the operator starts a War Room with reason {string} and scope {string}',
  async ({ page }: { page: Page }, reason: string, scope: string) => {
    // dev cycle 1 (trace-map-leitstand): the start form is a LiveView
    // phx-submit — on the throttled-longpoll transport the socket connects a
    // few seconds after first paint, and a submit fired before that silently
    // no-ops on the static render. Wait for the LiveView to be genuinely
    // connected first, and only return once the panel reflects the ACTIVE
    // session (both callers of this step assert/depend on an active session
    // immediately afterwards) — interaction synchronization, not an
    // assertion change.
    await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 20_000 });
    const form = startFormLocator(page);
    await form.locator('input[name="reason"]').fill(reason);
    await form.locator('select[name="scope"]').selectOption(scope);
    await form.locator('button[type="submit"]').click();
    await page
      .locator('[data-testid="stop-war-room-button"]')
      .waitFor({ timeout: 20_000 });
  },
);

When('the operator stops the active War Room', async ({ page }: { page: Page }) => {
  await page.locator('[data-testid="stop-war-room-button"]').click();
});

// ─── Then: AC11 — panel visibility / states ───────────────────────────────

Then('the War Room panel is visible', async ({ page }: { page: Page }) => {
  await expect(panelLocator(page)).toBeVisible({ timeout: 10_000 });
});

Then(
  'the War Room panel shows the {string} button',
  async ({ page }: { page: Page }, buttonText: string) => {
    await expect(panelLocator(page)).toContainText(buttonText, { timeout: 10_000 });
  },
);

Then('the War Room panel shows {string}', async ({ page }: { page: Page }, text: string) => {
  await expect(panelLocator(page)).toContainText(text, { timeout: 10_000 });
});

Then(
  'the War Room status bar shows the reason {string}',
  async ({ page }: { page: Page }, reason: string) => {
    await expect(statusLocator(page)).toContainText(reason, { timeout: 10_000 });
  },
);

// ─── Then: AC7/AC8 — warnings ──────────────────────────────────────────────

Then('the War Room broad-scope warning is not visible', async ({ page }: { page: Page }) => {
  await expect(warningAllLocator(page)).toBeHidden({ timeout: 10_000 });
});

Then('the War Room broad-scope warning is visible', async ({ page }: { page: Page }) => {
  await expect(warningAllLocator(page)).toBeVisible({ timeout: 10_000 });
});

Then(
  'the War Room broad-scope warning mentions {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    await expect(warningAllLocator(page)).toContainText(expectedSubstring, { timeout: 10_000 });
  },
);

Then('the War Room sync-scope warning is visible', async ({ page }: { page: Page }) => {
  await expect(warningSyncLocator(page)).toBeVisible({ timeout: 10_000 });
});

Then(
  'the War Room sync-scope warning mentions {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    await expect(warningSyncLocator(page)).toContainText(expectedSubstring, { timeout: 10_000 });
  },
);

// ─── Then: AC9 — filter fields ─────────────────────────────────────────────

Then(
  'the War Room start form has a {string} text field',
  async ({ page }: { page: Page }, fieldName: string) => {
    await expect(startFormLocator(page).locator(`input[name="${fieldName}"]`)).toBeVisible({
      timeout: 10_000,
    });
  },
);
