/**
 * Step definitions for features/admin/admin-sidebar-nesting.feature
 *
 * ATDD, written FIRST — RED phase. Story: enhanced-logging/admin-sidebar-nesting
 * docs/stories/enhanced-logging/admin-sidebar-nesting.md
 *
 * See the feature file's own header comment for the full split of coverage
 * between this file (real-browser-only behavior: actual keyboard focus +
 * Space/Enter key presses toggling a native <button>'s aria-expanded state)
 * and the server-side ExUnit suite
 * (server/test/nebu/admin/layouts_nested_nav_test.exs), which owns the
 * render-contract half (markup shape, highlight classes, data-navkey
 * presence, Configuration/Logs reorganization).
 *
 * Reuses steps already defined elsewhere (playwright-bdd matches step text
 * against ALL loaded step files, not just the one named after the current
 * .feature file):
 *   - "the Nebu stack is running" / "bootstrap has been completed" /
 *     "the operator is logged in as admin" (admin/bootstrap.steps.ts)
 *   - "the operator navigates to {string}" (admin/bootstrap.steps.ts)
 *
 * New steps defined here (nav-toggle keyboard interactions and sidebar
 * item assertions this story introduces — none of the sibling step files
 * have any notion of a nav "toggle" or nested nav "section" yet):
 *   - "the operator presses Tab until the {string} nav toggle is focused"
 *   - "the operator presses Tab once"
 *   - "the operator clicks the {string} nav toggle"
 *   - "the operator presses Space on the focused nav toggle"
 *   - "the operator presses Enter on the focused nav toggle"
 *   - "the {string} nav toggle has aria-expanded {string}"
 *   - "the {string} nav toggle resolves as an accessible button named {string}"
 *   - "the sidebar nav item {string} is visible"
 *   - "the sidebar nav item {string} is present in the DOM"
 *   - "the sidebar nav item {string} is focused"
 *   - "the sidebar nav item {string} has aria-current {string}"
 *   - "the operator clicks the sidebar nav item {string}"
 *   - "the page URL path is exactly {string}"
 *
 * ## Data-attribute contract this file assumes (mirrors the authoritative
 * contract pinned down by server/test/nebu/admin/layouts_nested_nav_test.exs
 * — see that file's moduledoc):
 *   - Parent nav toggle: a native `<button data-navkey={key}
 *     aria-expanded="true"|"false" aria-controls="nav-{key}-children">`.
 *   - Nav item (parent OR child): `[data-navkey={key}]` — a `<button>` for
 *     parents, an `<a>` for leaves/children. Both carry `data-navkey`.
 *   - `aria-current="page"` on the active leaf/child `<a>` (unchanged
 *     contract from the pre-nesting flat nav).
 *
 * ## Verification status
 *
 * Originally a RED-phase ATDD scaffold (statically checked against the
 * pre-implementation layouts.ex, tagged @pending-feature and excluded from
 * the default run). The admin-sidebar-nesting dev-story has since landed the
 * nested nav markup (`Nebu.Admin.Layouts.nav_item/1` parent mode +
 * `wireNavSectionToggles()` in app.js), the @pending-feature tags were
 * removed, and all scenarios in admin-sidebar-nesting.feature now run in the
 * default Playwright suite (pipeline CI gate: 4/4 PASS against the live
 * stack).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

function navItemLocator(page: Page, key: string) {
  return page.locator(`[data-navkey="${key}"]`);
}

// ─── When: nav toggle focus/click/keyboard interactions ─────────────────────

// Test-review MINOR-1: focus is reached the way a keyboard-only user reaches
// it — REAL repeated Tab presses from the top of the freshly-loaded document —
// not via programmatic .focus() (which succeeds even on elements a keyboard
// user could never Tab to). Mirrors logs-trace-map-hierarchy.steps.ts's
// "repeatedly pressing Tab reaches ..." precedent. 40 presses is a generous
// ceiling: skip-link + topbar + all top-level items + both sections'
// default-expanded children total well under that.
When(
  'the operator presses Tab until the {string} nav toggle is focused',
  async ({ page }: { page: Page }, key: string) => {
    const toggle = navItemLocator(page, key);
    let focused = false;

    for (let i = 0; i < 40; i += 1) {
      await page.keyboard.press('Tab');

      if (await toggle.evaluate((el) => el === document.activeElement)) {
        focused = true;
        break;
      }
    }

    expect(focused, `Tab traversal never reached [data-navkey="${key}"]`).toBe(true);
  },
);

// Test-review MINOR-1 (story Acceptance Test 8): a single further Tab from a
// just-expanded parent must land INSIDE its children — asserted by the
// "... is focused" Then step below.
When('the operator presses Tab once', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Tab');
});

When(
  'the operator clicks the {string} nav toggle',
  async ({ page }: { page: Page }, key: string) => {
    await navItemLocator(page, key).click();
  },
);

// AC9: proves the disclosure toggle works via keyboard alone (Space on a
// focused native <button>), not merely via `.click()` (which Playwright can
// dispatch even against elements a real keyboard-only user could never
// reach/activate the same way).
When('the operator presses Space on the focused nav toggle', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Space');
});

When('the operator presses Enter on the focused nav toggle', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Enter');
});

When(
  'the operator clicks the sidebar nav item {string}',
  async ({ page }: { page: Page }, key: string) => {
    await navItemLocator(page, key).click();
  },
);

// ─── Then: aria-expanded state ───────────────────────────────────────────────

Then(
  'the {string} nav toggle has aria-expanded {string}',
  async ({ page }: { page: Page }, key: string, expected: string) => {
    await expect(navItemLocator(page, key)).toHaveAttribute('aria-expanded', expected, {
      timeout: 10_000,
    });
  },
);

// Test-review MINOR-3 (AC9): the toggle must be exposed through the REAL
// accessibility tree as a button whose accessible name is its visible label —
// getByRole would not resolve a click-wired <div>, or a <button> whose label
// is hidden from AT. Intersecting with the data-navkey locator proves both
// resolve to the SAME element (data-navkey stays the primary selector
// everywhere else, per AC11).
Then(
  'the {string} nav toggle resolves as an accessible button named {string}',
  async ({ page }: { page: Page }, key: string, name: string) => {
    const byRole = page.getByRole('button', { name, exact: true });
    await expect(byRole.and(navItemLocator(page, key))).toHaveCount(1, { timeout: 10_000 });
  },
);

// ─── Then: sidebar item visibility / DOM presence / focus / active state ────

Then(
  'the sidebar nav item {string} is visible',
  async ({ page }: { page: Page }, key: string) => {
    await expect(navItemLocator(page, key)).toBeVisible({ timeout: 10_000 });
  },
);

// AC10: a collapsed child must still be reachable in the DOM (not removed by
// conditional rendering) even while visually hidden — deliberately does NOT
// assert visibility here, only DOM attachment.
Then(
  'the sidebar nav item {string} is present in the DOM',
  async ({ page }: { page: Page }, key: string) => {
    await expect(navItemLocator(page, key)).toHaveCount(1, { timeout: 10_000 });
  },
);

// Code-review MINOR-2 (flex-beats-hidden regression gate): the collapsed
// child must be genuinely invisible in the real browser — `toBeHidden()`
// resolves the COMPUTED style, so it fails if any author display utility
// class on the child <ul> ever beats the UA's `[hidden] { display: none }`
// rule again (the trace-map-hierarchy cycle-1 bug). Complements the
// present-in-DOM step above: collapsed = attached but not visible.
Then(
  'the sidebar nav item {string} is not visible',
  async ({ page }: { page: Page }, key: string) => {
    await expect(navItemLocator(page, key)).toBeHidden({ timeout: 10_000 });
  },
);

// Test-review MINOR-1 (story Acceptance Test 8): proves the child became
// genuinely focusable and is the very next Tab stop after its expanded parent.
Then(
  'the sidebar nav item {string} is focused',
  async ({ page }: { page: Page }, key: string) => {
    const isFocused = await navItemLocator(page, key).evaluate(
      (el) => el === document.activeElement,
    );
    expect(isFocused, `[data-navkey="${key}"] should be the active element`).toBe(true);
  },
);

Then(
  'the sidebar nav item {string} has aria-current {string}',
  async ({ page }: { page: Page }, key: string, expected: string) => {
    await expect(navItemLocator(page, key)).toHaveAttribute('aria-current', expected, {
      timeout: 10_000,
    });
  },
);

// Test-review MAJOR-2: EXACT pathname comparison — a "URL contains" substring
// check would be satisfied vacuously by sibling routes (/admin/logs/config,
// /admin/logs/war-room) or by a page that never navigated at all if the
// starting URL already contained the substring.
Then(
  'the page URL path is exactly {string}',
  async ({ page }: { page: Page }, path: string) => {
    await page.waitForURL((url) => url.pathname === path, { timeout: 10_000 });
    expect(new URL(page.url()).pathname).toBe(path);
  },
);
