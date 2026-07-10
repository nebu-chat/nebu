/**
 * Step definitions for features/admin/war-room-dedicated-page.feature
 *
 * Story enhanced-logging/war-room-dedicated-page — ATDD, written FIRST.
 * docs/stories/enhanced-logging/war-room-dedicated-page.md
 *
 * GREEN PHASE: the `@pending-feature` tag has been removed from every
 * scenario in `war-room-dedicated-page.feature` now that
 * `Nebu.Admin.LogsLive.WarRoom`, the sidebar dot, the topbar pill, and the
 * `exclusive_scope` column are implemented — mirrors `war-room.feature`'s
 * own dev-story un-tagging convention.
 *
 * Shared background/navigation/recording steps reused from existing step
 * files (this project's one-definition-per-step-text convention — see
 * `logs-config.steps.ts`'s own header comment for the identical note):
 *   - "the Nebu stack is running"                 (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"               (admin/bootstrap.steps.ts)
 *   - "the operator is logged in as admin"         (admin/bootstrap.steps.ts)
 *   - "the operator navigates to {string}"         (admin/bootstrap.steps.ts)
 *   - "a request to {string} has been recorded"    (admin/logs-monitoring.steps.ts)
 *   - "the operator selects {string} as the War Room scope"
 *   - "the operator starts a War Room with reason {string} and scope {string}"
 *   - "the operator stops the active War Room"
 *   - "the War Room panel shows {string}"
 *                                                   (admin/war-room.steps.ts)
 *
 * Data-attribute contract this file pins down for the dev agent — see
 * war-room-dedicated-page.feature's header comment for the full list, and
 * server/test/nebu/admin/logs_live/war_room_test.exs /
 * server/test/nebu/admin/layouts_war_room_indicator_test.exs for the
 * identical contract pinned down on the ExUnit side.
 *
 * ## No test-only HTTP routes (epic-wide lesson)
 *
 * Every `Given` seed below goes through `fixtures/db.ts`'s direct-SQL
 * helpers (extended for this story: `insertWarRoomSession`,
 * `insertOperationalLogForWarRoom`, `clearWarRoomSessions`) — never a
 * test-only HTTP endpoint. Mirrors the epic-wide `war-room-mode`/
 * `trace-map-leitstand`/`trace-map-node-controls` precedent exactly.
 *
 * ## No sleeps, no first-Tab assumptions
 *
 * Session-active/duration-based state is DB-seeded (`startedSecondsAgo`/
 * `endedSecondsAgo` params), never waited-out with `page.waitForTimeout`.
 * Every interaction that depends on the LiveSocket being connected (starting
 * a session, checking an exclusive-scope checkbox) waits for
 * `[data-phx-main].phx-connected` first — the SAME pattern
 * `war-room.steps.ts`'s own "starts a War Room" step already establishes
 * for this exact class of race (this page does not need a dedicated
 * `phx-hook` of its own — the exclusive-scope UI and copy-to-markdown both
 * work through plain LiveView `phx-change`/`phx-click` round trips plus the
 * ALREADY-EXISTING generic `nebu:copy-thread` document-level listener in
 * `app.js`; only the sidebar dot / topbar pill client-side tick needs new
 * JS, and that lives in `Nebu.Admin.Layouts`, shared by every admin page —
 * no per-page hook-ready flag to await there either).
 */

import { After, Before, Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import {
  insertWarRoomSession,
  insertOperationalLogForWarRoom,
  endActiveWarRoomSessions,
  clearWarRoomSessions,
} from '../../fixtures/db';

// Mirrors bootstrap.steps.ts's own local ADMIN_BASE_URL constant exactly
// (each step file defines its own copy rather than exporting a shared one —
// existing convention in this codebase).
const ADMIN_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';

// Coordinator finding (2026-07-08, round 3): every scenario in this feature
// seeds at least one war_room_sessions row (via insertWarRoomSession or the
// real "starts a War Room" UI flow). An AFTER-only, PATTERN-matched cleanup
// (this function's earlier shape) is not enough under a FULL suite run:
// OTHER feature files that also touch war rooms through the real UI (e.g.
// logs-trace-map.feature's own @ac6-war-room-banner scenario) use the real
// logged-in e2e admin's own started_by/an arbitrary reason, which no
// pattern can reliably catch, and those rows leaked into THIS feature's
// exact-count ("shows 2 sessions")/empty-state ("no sessions exist")
// assertions. No scenario in this file depends on another scenario's
// session surviving (each Given seeds exactly what it needs), so the
// robust fix is a BEFORE hook that unconditionally clears
// war_room_sessions before EVERY scenario here, guaranteeing a clean slate
// regardless of what ran earlier in the suite — full stop, not a
// pattern-matched partial clear. The AFTER hook is kept too, as a good
// citizen for whatever runs after this file in the same suite.
Before({ tags: '@war-room-dedicated-page' }, async () => {
  clearWarRoomSessions();
});

After({ tags: '@war-room-dedicated-page' }, async () => {
  clearWarRoomSessions();
});

// Tracks the session under test across a scenario's Given/When/Then chain:
// `lastSeededSessionId` is the war_room_sessions.id UUID (needed to tag
// operational_logs rows correctly), `lastSeededSessionStartedBy` is its
// human-readable started_by (used for the "clicks the session row for
// {string}" locator, which matches on visible row text, not the id).
let lastSeededSessionId: string | null = null;
let lastSeededSessionStartedBy: string | null = null;

function sessionRowLocator(page: Page, startedBy: string) {
  return page.locator(`[data-testid="war-room-session-row"]:has-text("${startedBy}")`);
}

// ─── Given: seeding via direct SQL (no test-only HTTP routes) ──────────────

Given(
  'a War Room session {string} is active, started {int} seconds ago',
  async ({}: object, startedBy: string, startedSecondsAgo: number) => {
    endActiveWarRoomSessions();
    lastSeededSessionId = insertWarRoomSession({
      startedBy,
      reason: 'e2e dedicated-page ATDD probe (active)',
      startedSecondsAgo,
    });
    lastSeededSessionStartedBy = startedBy;
  },
);

Given(
  'an ended War Room session {string} exists, ended {int} minute(s) ago',
  async ({}: object, startedBy: string, endedMinutesAgo: number) => {
    lastSeededSessionId = insertWarRoomSession({
      startedBy,
      reason: 'e2e dedicated-page ATDD probe (ended)',
      startedSecondsAgo: endedMinutesAgo * 60 + 60,
      endedSecondsAgo: endedMinutesAgo * 60,
      endedReason: 'manual_stop',
    });
    lastSeededSessionStartedBy = startedBy;
  },
);

Given('no War Room sessions exist', async () => {
  clearWarRoomSessions();
});

Given('that session has {int} captured log entries', async ({}: object, count: number) => {
  if (!lastSeededSessionId) {
    throw new Error('[war-room-dedicated-page] no War Room session has been seeded in this scenario');
  }

  // AC5: the detail page filters strictly by war_room_id — tag every seeded
  // entry with the REAL session UUID returned by insertWarRoomSession, not
  // the human-readable started_by string.
  const sessionId = lastSeededSessionId;
  const startedBy = lastSeededSessionStartedBy;
  for (let i = 0; i < count; i += 1) {
    insertOperationalLogForWarRoom(sessionId, {
      message: `e2e-seeded captured entry ${i + 1} for ${startedBy}`,
    });
  }
});

// ─── When: interactions specific to this page ──────────────────────────────

When('the operator clicks the session row for {string}', async ({ page }: { page: Page }, startedBy: string) => {
  await sessionRowLocator(page, startedBy).click();
});

When('the operator navigates to a non-existent War Room detail page', async ({ page }: { page: Page }) => {
  await page.goto(`${ADMIN_BASE_URL}/admin/logs/war-room/00000000-0000-0000-0000-000000000000`);
});

When('the operator checks {string} as an excluded endpoint', async ({ page }: { page: Page }, route: string) => {
  // Coordinator finding 2 (2026-07-08): the checkbox itself is a plain,
  // unconnected-DOM-safe `.check()` (no server round trip needed to toggle
  // it — the merge into `exclusive_scope` happens on form submit), but the
  // checkbox only EXISTS once the preceding "selects... War Room scope"
  // step's phx-change round trip has actually landed. Waiting here too is
  // cheap insurance against the same connection race.
  await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 20_000 });
  await page
    .locator(`[data-testid="war-room-exclusive-options"] input[type="checkbox"][value="${route}"]`)
    .check();
});

When('the operator clicks the copy-to-markdown button', async ({ page }: { page: Page }) => {
  // Clipboard writes require a granted permission — see the assertion step
  // below for the matching `clipboard-read` grant (both are requested per
  // scenario, mirroring standard Playwright clipboard-testing practice).
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  // Coordinator finding 3 (2026-07-08): this button's `phx-click` is a JS
  // command list ending in `JS.push("copy_to_markdown")` — the toast
  // (`@copy_toast`) only ever appears via that SERVER round trip. Clicking
  // before the LiveSocket has connected (throttled-longpoll transport,
  // same class of race as every other server-round-trip interaction on
  // this page) lets the `JS.dispatch("nebu:copy-thread")` half fire (a
  // pure client-side CustomEvent) while the push silently no-ops, so the
  // clipboard write can succeed even though the toast never shows.
  await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 20_000 });
  await page.locator('[data-testid="war-room-copy-markdown-button"]').click();
});

// ─── Then: list view ────────────────────────────────────────────────────────

Then('the War Room session list shows {int} sessions', async ({ page }: { page: Page }, count: number) => {
  await expect(page.locator('[data-testid="war-room-session-row"]')).toHaveCount(count, {
    timeout: 10_000,
  });
});

Then('the first session row shows the {string} status badge', async ({ page }: { page: Page }, badgeText: string) => {
  const firstRow = page.locator('[data-testid="war-room-session-row"]').first();
  await expect(firstRow.locator('[data-testid="war-room-session-status"]')).toContainText(badgeText);
});

Then('a session row shows the {string} status badge', async ({ page }: { page: Page }, badgeText: string) => {
  await expect(
    page.locator('[data-testid="war-room-session-status"]', { hasText: badgeText }).first(),
  ).toBeVisible({ timeout: 10_000 });
});

Then('the War Room empty-state message is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-empty-state"]')).toBeVisible({ timeout: 10_000 });
});

Then(
  'the War Room empty-state message mentions {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    await expect(page.locator('[data-testid="war-room-empty-state"]')).toContainText(expectedSubstring);
  },
);

// ─── Then: detail view ──────────────────────────────────────────────────────

Then("the operator is on the War Room session's detail page", async ({ page }: { page: Page }) => {
  await expect(page).toHaveURL(/\/admin\/logs\/war-room\/[0-9a-f-]{36}/, { timeout: 10_000 });
});

Then(
  'the War Room detail metadata panel shows {string}',
  async ({ page }: { page: Page }, expectedSubstring: string) => {
    await expect(page.locator('[data-testid="war-room-detail-meta"]')).toContainText(expectedSubstring, {
      timeout: 10_000,
    });
  },
);

Then('the War Room detail page shows {int} captured log entries', async ({ page }: { page: Page }, count: number) => {
  await expect(page.locator('[data-testid="request-row"]')).toHaveCount(count, { timeout: 10_000 });
});

Then('the War Room not-found message is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-not-found"]')).toBeVisible({ timeout: 10_000 });
});

Then('the operator can navigate back to the War Room list from there', async ({ page }: { page: Page }) => {
  await page.locator('[data-testid="war-room-detail-back-link"]').click();
  await expect(page).toHaveURL(/\/admin\/logs\/war-room$/, { timeout: 10_000 });
});

// ─── Then: scoping form / live preview / exclusive scope ───────────────────

Then('the War Room start form is visible on the dedicated page', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-start-form"]')).toBeVisible({ timeout: 10_000 });
});

Then('the War Room live-activity preview is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-trace-preview"]')).toBeVisible({ timeout: 10_000 });
});

Then('the War Room live-activity preview updates without a page reload', async ({ page }: { page: Page }) => {
  const preview = page.locator('[data-testid="war-room-trace-preview"]');
  await expect(
    preview.locator('[data-testid="trace-map-bubble"][data-bubble-dimension="source"][data-bubble-value="http"]'),
  ).not.toHaveAttribute('data-bubble-count', '0', { timeout: 10_000 });
});

Then('the War Room exclusive-scope options are visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-exclusive-options"]')).toBeVisible({ timeout: 10_000 });
});

Then(
  'the War Room exclusive-scope options include {string}',
  async ({ page }: { page: Page }, route: string) => {
    await expect(
      page.locator(`[data-testid="war-room-exclusive-options"] input[type="checkbox"][value="${route}"]`),
    ).toBeVisible();
  },
);

// ─── Then: amendment 2 — embedded panel retirement ─────────────────────────

Then('the embedded War Room panel is not present on the page', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="war-room-panel"]')).toHaveCount(0);
});

// test-review finding 7 (fixed): the sidebar nav item itself was already
// shipped by admin-sidebar-nesting — merely asserting it's *visible* proves
// nothing this story delivers. This step instead drives the actual
// navigation and the next Then asserts the REAL dedicated page renders
// (amendment 1) rather than the old stub silently re-rendering Live Stream.
When('the operator clicks the War Room nav item', async ({ page }: { page: Page }) => {
  await page.locator('a[data-navkey="logs-war-room"]').click();
});

Then('the page heading is {string}', async ({ page }: { page: Page }, expectedHeading: string) => {
  await expect(page.locator('h1')).toHaveText(expectedHeading, { timeout: 10_000 });
});

// ─── Then: amendment 4 — nav dot + topbar pill ─────────────────────────────

Then('the sidebar War Room recording dot is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="nav-war-room-dot"]')).toBeVisible({ timeout: 10_000 });
});

Then('the topbar War Room recording pill is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="topbar-war-room-pill"]')).toBeVisible({ timeout: 10_000 });
});

Then('the topbar War Room recording pill shows an elapsed time', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="topbar-war-room-pill"]')).toContainText(/\d{1,2}:\d{2}/, {
    timeout: 10_000,
  });
});

// ─── Then: AC14 — copy-to-markdown ──────────────────────────────────────────

Then('the operator sees a {string} confirmation', async ({ page }: { page: Page }, message: string) => {
  await expect(page.locator('[data-testid="war-room-copy-toast"]')).toContainText(message, {
    timeout: 10_000,
  });
});

Then('the clipboard contains {string}', async ({ page }: { page: Page }, expectedSubstring: string) => {
  const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
  expect(clipboardText).toContain(expectedSubstring);
});

// ─── When/Then: AC13 keyboard operability (test-review finding 6) ──────────
//
// Mirrors admin-sidebar-nesting.steps.ts's own "presses Tab until {string}
// nav toggle is focused" convention EXACTLY: real, repeated Tab presses from
// wherever focus currently is — never a programmatic `.focus()` (which
// succeeds even on elements a real keyboard-only user could never Tab to,
// e.g. something with a negative tabindex or hidden ancestor). 60 presses is
// a generous ceiling for a page with a session row, a start form with
// several fields, and (once exclusive mode is chosen) a handful of
// checkboxes.

When(
  'the operator presses Tab until the session row for {string} is focused',
  async ({ page }: { page: Page }, startedBy: string) => {
    const row = sessionRowLocator(page, startedBy);
    let focused = false;

    for (let i = 0; i < 60; i += 1) {
      await page.keyboard.press('Tab');

      if (await row.evaluate((el) => el === document.activeElement)) {
        focused = true;
        break;
      }
    }

    expect(focused, `Tab traversal never reached the session row for ${startedBy}`).toBe(true);
  },
);

When('the operator presses Enter on the focused session row', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Enter');
});

When(
  'the operator presses Tab until the {string} excluded-endpoint checkbox is focused',
  async ({ page }: { page: Page }, route: string) => {
    const checkbox = page.locator(
      `[data-testid="war-room-exclusive-options"] input[type="checkbox"][value="${route}"]`,
    );
    let focused = false;

    for (let i = 0; i < 60; i += 1) {
      await page.keyboard.press('Tab');

      if (await checkbox.evaluate((el) => el === document.activeElement)) {
        focused = true;
        break;
      }
    }

    expect(focused, `Tab traversal never reached the ${route} excluded-endpoint checkbox`).toBe(true);
  },
);

When('the operator presses Space on the focused checkbox', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Space');
});

Then(
  'the {string} excluded-endpoint checkbox is checked',
  async ({ page }: { page: Page }, route: string) => {
    await expect(
      page.locator(`[data-testid="war-room-exclusive-options"] input[type="checkbox"][value="${route}"]`),
    ).toBeChecked({ timeout: 10_000 });
  },
);
