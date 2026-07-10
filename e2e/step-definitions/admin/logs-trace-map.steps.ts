/**
 * Step definitions for features/admin/logs-trace-map.feature
 *
 * Story enhanced-logging/trace-map-leitstand — ATDD, written FIRST (RED phase).
 * docs/stories/enhanced-logging/trace-map-leitstand.md
 *
 * RED PHASE: every locator below targets markup that does not exist yet —
 * `/admin/logs/trace-map` is still a stub pointing at the OLD `/admin/logs`
 * page (see router.ex). Every scenario in the companion feature file is
 * tagged @pending-feature and excluded from the default suite
 * (playwright.config.ts's DEFAULT_E2E_TAGS) until the dev-story lands.
 *
 * Reuses steps already defined elsewhere (playwright-bdd matches step text
 * against ALL loaded step files — redefining an identical pattern here would
 * make the step ambiguous at `bddgen` time):
 *   - "the Nebu stack is running"                  (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"                (admin/bootstrap.steps.ts)
 *   - "the operator is logged in as admin"          (admin/bootstrap.steps.ts)
 *   - "the operator navigates to {string}"          (admin/bootstrap.steps.ts)
 *   - "the page shows {string}"                     (admin/bootstrap.steps.ts)
 *   - "a request to {string} has been recorded"     (admin/logs-monitoring.steps.ts)
 *   - "the operator starts a War Room with reason {string} and scope {string}"
 *                                                    (admin/war-room.steps.ts)
 *
 * "the page URL contains the query parameter {string}" was originally defined
 * in admin/logs-trace-map-filter-persistence.steps.ts — that file (and its
 * feature) was deleted by this story's dev cycle (AC12: the new Leitstand
 * scenarios supersede the old embedded-map filter-persistence specs), so the
 * definition moved HERE (see below).
 *
 * ## Data-attribute contract this file assumes (mirrors the AUTHORITATIVE
 * contract pinned down server-side by
 * server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs's own
 * moduledoc — kept in sync with that file, not duplicated/reinvented here):
 *   - Node: [data-testid="trace-map-node"][data-node-key=...]
 *     [data-node-status=...][data-node-selected=...], role="button",
 *     tabindex="0", aria-pressed, aria-label.
 *   - Filter chip: [data-testid="trace-map-filter-chip"][data-chip-value=...].
 *   - War-room banner: [data-testid="trace-map-war-room-banner"],
 *     dot [data-testid="trace-map-war-room-dot"],
 *     open link [data-testid="trace-map-war-room-open-link"].
 *   - Tooltip: [data-testid="trace-map-tooltip"].
 *   - Inspector: [data-testid="trace-map-inspector-name"/-route/-status-pill/-event].
 *   - Level pill: [data-testid="trace-map-level-pill"][data-level="DEBUG"|"INFO"|"WARN"|"ERROR"].
 *   - Resizer: [data-testid="trace-map-resizer"], role="separator".
 *   - Stream line: [data-testid="trace-map-stream-line"][data-route=...].
 *
 * ## WARN/ERROR log seeding — direct DB insert, NO test-only HTTP routes
 *
 * "a warning/error has been recorded for the {string} endpoint" seeds an
 * operational_logs row via a direct DB INSERT (fixtures/db.ts) — real
 * black-box HTTP traffic cannot deterministically produce WARN/ERROR entries
 * (RequestLogger only ever logs at INFO; see logs-monitoring.steps.ts's own
 * header comment). Test-review MAJOR-1 + the story's "Story Amendments"
 * section rejected the originally-proposed `POST /admin/_test/...` backdoor:
 * no test-only HTTP routes may land in server code, ever. The DB-seed
 * mechanism follows server/test/nebu/admin/logs_live_test.exs's AC12
 * raw-SQL-seed precedent. Scenarios reload/navigate after seeding, so the
 * page's mount-time LogStore history read picks the rows up (no PubSub).
 */

import { After, Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import {
  clearEndpointLoggingConfig,
  clearOffEndpointOperationalLogs,
  clearTemporaryCaptures,
  endActiveWarRoomSessions,
  insertOperationalLog,
  insertTemporaryCapture,
  queryServerConfigValue,
  upsertServerConfig,
} from '../../fixtures/db';

// dev cycle 1: the war-room-banner scenario starts a REAL session; end it
// after the scenario so it cannot leak into war-room.feature's own start step
// (the "exactly one active session" conflict). SQL cleanup — see db.ts.
After({ tags: '@ac6-war-room-banner' }, async () => {
  endActiveWarRoomSessions();
});

function nodeLocator(page: Page, key: string) {
  return page.locator(`[data-testid="trace-map-node"][data-node-key="${key}"]`);
}

function chipLocator(page: Page, key: string) {
  return page.locator(`[data-testid="trace-map-filter-chip"][data-chip-value="${key}"]`);
}

function streamLineLocator(page: Page, key: string) {
  return page.locator(`[data-testid="trace-map-stream-line"][data-route="${key}"]`);
}

function levelPillLocator(page: Page, level: string) {
  return page.locator(`[data-testid="trace-map-level-pill"][data-level="${level}"]`);
}

function tooltipLocator(page: Page) {
  return page.locator('[data-testid="trace-map-tooltip"]');
}

function inspectorLocator(page: Page) {
  return page.locator('[data-testid="trace-map-inspector"]');
}

function resizerLocator(page: Page) {
  return page.getByRole('separator', { name: /resize/i });
}

function bannerLocator(page: Page) {
  return page.locator('[data-testid="trace-map-war-room-banner"]');
}

function streamPanelLocator(page: Page) {
  return page.locator('[data-testid="trace-map-stream"]');
}

/**
 * dev cycle 1: every LiveView-backed interaction on the Leitstand page
 * (phx-click on nodes/pills, the hook's Enter/Space activation, tooltip,
 * resizer) only works once the LiveSocket has connected AND the
 * TraceMapLeitstand hook has mounted. The admin UI deliberately uses a
 * THROTTLED LONGPOLL transport (app.js's ThrottledLongPoll), so that takes a
 * few seconds after first paint — interacting immediately after navigation
 * races it (clicks/keys silently no-op on the static render). The hook sets
 * `window.__nebuTraceMapHookReady` in mounted() exactly for this wait. This
 * is interaction SYNCHRONIZATION (Playwright-standard actionability), not an
 * assertion change.
 */
async function awaitLeitstandReady(page: Page) {
  await page.waitForFunction(
    () => (window as unknown as { __nebuTraceMapHookReady?: boolean }).__nebuTraceMapHookReady === true,
    undefined,
    { timeout: 20_000 },
  );
}

// ─── Given/When: WARN/ERROR seeding via direct DB insert (MAJOR-1 fix) ─────
// See this file's header comment + fixtures/db.ts for the full rationale.
// Steps are synchronous DB INSERTs; the scenario navigates/reloads afterward
// so the mount-time LogStore history read picks the seeded rows up.

Given(
  'a warning has been recorded for the {string} endpoint',
  async ({}: object, route: string) => {
    insertOperationalLog({ level: 'warning', routeTemplate: route });
  },
);

When(
  'an error has been recorded for the {string} endpoint',
  async ({}: object, route: string) => {
    insertOperationalLog({ level: 'error', routeTemplate: route });
  },
);

// ─── When: page-level actions ───────────────────────────────────────────────

When('the operator reloads the Trace Map page', async ({ page }: { page: Page }) => {
  await page.reload();
});

// Moved here from the deleted admin/logs-trace-map-filter-persistence.steps.ts
// (see this file's header comment) — Scenario 10 (bookmarkable URLs) uses it.
Then(
  'the page URL contains the query parameter {string}',
  async ({ page }: { page: Page }, param: string) => {
    await expect(async () => {
      expect(page.url()).toContain(param);
    }).toPass({ timeout: 10_000 });
  },
);

// ─── Then: map structure (AC1/AC2) ──────────────────────────────────────────

Then(
  'I see the {string} center node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await expect(nodeLocator(page, key)).toBeVisible({ timeout: 10_000 });
  },
);

Then(
  'I see a domain node for {string} on the Trace Map',
  async ({ page }: { page: Page }, domain: string) => {
    await expect(nodeLocator(page, domain)).toBeVisible({ timeout: 10_000 });
  },
);

Then(
  'I see a satellite node for {string} on the Trace Map',
  async ({ page }: { page: Page }, route: string) => {
    await expect(nodeLocator(page, route)).toBeVisible({ timeout: 10_000 });
  },
);

// ─── Then: status / visual states (AC3/AC4) ─────────────────────────────────

Then(
  'the {string} node shows warn status',
  async ({ page }: { page: Page }, key: string) => {
    await expect(nodeLocator(page, key)).toHaveAttribute('data-node-status', 'warn', {
      timeout: 10_000,
    });
  },
);

Then(
  'the {string} node shows error status',
  async ({ page }: { page: Page }, key: string) => {
    await expect(nodeLocator(page, key)).toHaveAttribute('data-node-status', 'error', {
      timeout: 10_000,
    });
  },
);

Then(
  'the {string} domain node shows warn status',
  async ({ page }: { page: Page }, domain: string) => {
    await expect(nodeLocator(page, domain)).toHaveAttribute('data-node-status', 'warn', {
      timeout: 10_000,
    });
  },
);

Then('the {string} center node shows warn status', async ({ page }: { page: Page }, key: string) => {
  await expect(nodeLocator(page, key)).toHaveAttribute('data-node-status', 'warn', {
    timeout: 10_000,
  });
});

Then(
  'the {string} node pulses \\(no prefers-reduced-motion\\)',
  async ({ page }: { page: Page }, key: string) => {
    const animationName = await nodeLocator(page, key)
      .locator('[data-testid="trace-map-node-core"]')
      .evaluate((el) => getComputedStyle(el).animationName);
    expect(animationName).not.toBe('none');
  },
);

// MINOR-6 fix (test-review): AC10/spec §8 make prefers-reduced-motion a
// BLOCKING requirement — the error pulse must be disabled under it.
// `emulateMedia` re-evaluates `@media (prefers-reduced-motion: reduce)`
// rules immediately, so the same computed-style probe as the pulse step
// above must now report no animation.
When('the operator emulates reduced motion', async ({ page }: { page: Page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
});

Then(
  'the {string} node does not pulse \\(reduced motion\\)',
  async ({ page }: { page: Page }, key: string) => {
    const animationName = await nodeLocator(page, key)
      .locator('[data-testid="trace-map-node-core"]')
      .evaluate((el) => getComputedStyle(el).animationName);
    expect(animationName).toBe('none');
  },
);

// ─── When/Then: click-to-filter (AC5) ───────────────────────────────────────

When(
  'the operator clicks the {string} node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await awaitLeitstandReady(page);
    await nodeLocator(page, key).click();
  },
);

When(
  'the operator clicks the {string} center node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await awaitLeitstandReady(page);
    await nodeLocator(page, key).click();
  },
);

Then(
  'the {string} node shows a selection ring',
  async ({ page }: { page: Page }, key: string) => {
    await expect(nodeLocator(page, key)).toHaveAttribute('data-node-selected', 'true', {
      timeout: 10_000,
    });
  },
);

Then('no Trace Map node shows a selection ring', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-node-selected="true"]')).toHaveCount(0, { timeout: 10_000 });
});

Then(
  'the {string} node has aria-pressed {string}',
  async ({ page }: { page: Page }, key: string, expected: string) => {
    await expect(nodeLocator(page, key)).toHaveAttribute('aria-pressed', expected, {
      timeout: 10_000,
    });
  },
);

Then(
  'a Trace Map filter chip for {string} is visible',
  async ({ page }: { page: Page }, key: string) => {
    await expect(chipLocator(page, key)).toBeVisible({ timeout: 10_000 });
  },
);

Then('a Trace Map filter chip is visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="trace-map-filter-chip"]').first()).toBeVisible({
    timeout: 10_000,
  });
});

Then('two Trace Map filter chips are visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="trace-map-filter-chip"]')).toHaveCount(2, {
    timeout: 10_000,
  });
});

Then('no Trace Map filter chips are visible', async ({ page }: { page: Page }) => {
  await expect(page.locator('[data-testid="trace-map-filter-chip"]')).toHaveCount(0, {
    timeout: 10_000,
  });
});

Then(
  'the log stream below shows only entries for {string}',
  async ({ page }: { page: Page }, route: string) => {
    await expect(streamLineLocator(page, route).first()).toBeVisible({ timeout: 10_000 });
  },
);

Then(
  'the log stream below shows entries for both {string} and {string}',
  async ({ page }: { page: Page }, routeA: string, routeB: string) => {
    await expect(streamLineLocator(page, routeA).first()).toBeVisible({ timeout: 10_000 });
    await expect(streamLineLocator(page, routeB).first()).toBeVisible({ timeout: 10_000 });
  },
);

// ─── When/Then: keyboard navigation (AC10) ──────────────────────────────────

When('the operator presses Tab', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Tab');
});

// MAJOR-2 fix (test-review; story AC12 Scenario 4 wording amended to match):
// the admin layout's sidebar chrome (skip link, nav items, Logs disclosure
// children) precedes the main content in document order — a single Tab from
// a fresh navigation lands in the chrome, never on nebu. An accessible
// implementation (natural document order, no positive tabindex, no focus
// stealing) reaches the map via SEQUENTIAL keyboard navigation, so this step
// tabs until the first Trace Map node receives focus (nebu, per the
// DOM-order contract pinned server-side in trace_map_leitstand_test.exs's
// AC10 "DOM order" test).
When(
  'the operator presses Tab until a Trace Map node is focused',
  async ({ page }: { page: Page }) => {
    await awaitLeitstandReady(page);
    const maxTabs = 40;
    for (let i = 0; i < maxTabs; i += 1) {
      await page.keyboard.press('Tab');
      const nodeFocused = await page.evaluate(
        () => document.activeElement?.getAttribute('data-testid') === 'trace-map-node',
      );
      if (nodeFocused) return;
    }
    throw new Error(
      `[logs-trace-map] no Trace Map node received focus within ${maxTabs} Tab presses — ` +
        'either the nodes are not focusable (tabindex missing) or the page has a keyboard trap',
    );
  },
);

When('the operator presses Enter on the focused Trace Map node', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Enter');
});

When('the operator presses Space on the focused Trace Map node', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Space');
});

When('the operator presses Escape', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Escape');
});

Then('the {string} node on the Trace Map has focus', async ({ page }: { page: Page }, key: string) => {
  await expect(nodeLocator(page, key)).toBeFocused({ timeout: 10_000 });
});

Then('the focused Trace Map node shows a visible focus ring', async ({ page }: { page: Page }) => {
  const outlineStyle = await page
    .locator('[data-testid="trace-map-node"]:focus-visible')
    .evaluate((el) => getComputedStyle(el).outlineStyle);
  expect(outlineStyle).not.toBe('none');
});

Then('the focused Trace Map node is a domain node', async ({ page }: { page: Page }) => {
  const kind = await page
    .locator('[data-testid="trace-map-node"]:focus')
    .getAttribute('data-node-kind');
  expect(kind).toBe('domain');
});

Then(
  'the focused domain node has aria-pressed {string}',
  async ({ page }: { page: Page }, expected: string) => {
    await expect(page.locator('[data-testid="trace-map-node"]:focus')).toHaveAttribute(
      'aria-pressed',
      expected,
      { timeout: 10_000 },
    );
  },
);

// ─── When/Then: tooltip (AC7) ────────────────────────────────────────────────

When(
  'the operator hovers over the {string} node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await awaitLeitstandReady(page);
    await nodeLocator(page, key).hover();
  },
);

When('the operator moves the mouse away from the Trace Map', async ({ page }: { page: Page }) => {
  await page.mouse.move(0, 0);
});

When(
  'the operator tabs to the {string} node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await awaitLeitstandReady(page);
    await nodeLocator(page, key).focus();
  },
);

Then(
  'a Trace Map tooltip is visible showing name, route, status, and counts',
  async ({ page }: { page: Page }) => {
    const tooltip = tooltipLocator(page);
    await expect(tooltip).toBeVisible({ timeout: 10_000 });
    await expect(tooltip).not.toBeEmpty();
  },
);

Then('the Trace Map tooltip is hidden', async ({ page }: { page: Page }) => {
  await expect(tooltipLocator(page)).toBeHidden({ timeout: 10_000 });
});

// ─── Then: inspector panel (AC8) ────────────────────────────────────────────

Then(
  'the Trace Map inspector shows the name {string}',
  async ({ page }: { page: Page }, name: string) => {
    await expect(inspectorLocator(page).locator('[data-testid="trace-map-inspector-name"]')).toContainText(
      name,
      { timeout: 10_000 },
    );
  },
);

Then(
  'the Trace Map inspector shows the route {string}',
  async ({ page }: { page: Page }, route: string) => {
    await expect(inspectorLocator(page).locator('[data-testid="trace-map-inspector-route"]')).toContainText(
      route,
      { timeout: 10_000 },
    );
  },
);

Then('the Trace Map inspector shows a status pill', async ({ page }: { page: Page }) => {
  await expect(
    inspectorLocator(page).locator('[data-testid="trace-map-inspector-status-pill"]'),
  ).toBeVisible({ timeout: 10_000 });
});

Then(
  'the Trace Map inspector shows at least {int} recent event',
  async ({ page }: { page: Page }, minCount: number) => {
    const count = await inspectorLocator(page)
      .locator('[data-testid="trace-map-inspector-event"]')
      .count();
    expect(count).toBeGreaterThanOrEqual(minCount);
  },
);

// ─── When/Then: war-room banner (AC6) ───────────────────────────────────────

Then('the Trace Map war-room banner is visible', async ({ page }: { page: Page }) => {
  await expect(bannerLocator(page)).toBeVisible({ timeout: 10_000 });
});

Then('the Trace Map war-room banner shows the recording dot', async ({ page }: { page: Page }) => {
  await expect(bannerLocator(page).locator('[data-testid="trace-map-war-room-dot"]')).toBeVisible({
    timeout: 10_000,
  });
});

Then(
  'the Trace Map war-room banner mentions {string}',
  async ({ page }: { page: Page }, text: string) => {
    await expect(bannerLocator(page)).toContainText(text, { timeout: 10_000 });
  },
);

// MINOR-7 fix (test-review): AC6's live elapsed clock (mm:ss, phx-hook-driven)
// must actually render — assert the banner text contains a clock-shaped value.
Then('the Trace Map war-room banner shows an elapsed time', async ({ page }: { page: Page }) => {
  await expect(bannerLocator(page)).toContainText(/\d{2}:\d{2}/, { timeout: 10_000 });
});

When('the operator clicks {string} on the Trace Map war-room banner', async ({ page }: { page: Page }) => {
  await bannerLocator(page).locator('[data-testid="trace-map-war-room-open-link"]').click();
});

Then('the operator is on {string}', async ({ page }: { page: Page }, path: string) => {
  await expect(page).toHaveURL(new RegExp(path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '$'), {
    timeout: 10_000,
  });
});

// ─── When/Then: level filter leitstand shortcut (AC9) ───────────────────────

Then('all Trace Map level filter pills are active', async ({ page }: { page: Page }) => {
  for (const level of ['DEBUG', 'INFO', 'WARN', 'ERROR']) {
    await expect(levelPillLocator(page, level)).toHaveAttribute('aria-pressed', 'true', {
      timeout: 10_000,
    });
  }
});

When(
  'the operator clicks the {string} Trace Map level filter pill',
  async ({ page }: { page: Page }, level: string) => {
    await awaitLeitstandReady(page);
    await levelPillLocator(page, level).click();
  },
);

Then(
  'only the {string} Trace Map level filter pill is active',
  async ({ page }: { page: Page }, activeLevel: string) => {
    for (const level of ['DEBUG', 'INFO', 'WARN', 'ERROR']) {
      await expect(levelPillLocator(page, level)).toHaveAttribute(
        'aria-pressed',
        String(level === activeLevel),
        { timeout: 10_000 },
      );
    }
  },
);

// ─── When/Then: resizer (AC9) ────────────────────────────────────────────────

When(
  'the operator drags the Trace Map stream resizer down by {int} pixels',
  async ({ page }: { page: Page }, pixels: number) => {
    await awaitLeitstandReady(page);
    const handle = resizerLocator(page);
    const box = await handle.boundingBox();
    if (!box) throw new Error('[logs-trace-map] resizer has no bounding box');
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 + pixels);
    await page.mouse.up();
  },
);

When(
  'the operator drags the Trace Map stream resizer up by {int} pixels',
  async ({ page }: { page: Page }, pixels: number) => {
    await awaitLeitstandReady(page);
    const handle = resizerLocator(page);
    const box = await handle.boundingBox();
    if (!box) throw new Error('[logs-trace-map] resizer has no bounding box');
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 - pixels);
    await page.mouse.up();
  },
);

When('the operator double-clicks the Trace Map stream resizer', async ({ page }: { page: Page }) => {
  await awaitLeitstandReady(page);
  await resizerLocator(page).dblclick();
});

When('the operator focuses the Trace Map stream resizer and presses ArrowUp', async ({ page }: { page: Page }) => {
  await awaitLeitstandReady(page);
  await resizerLocator(page).focus();
  await page.keyboard.press('ArrowUp');
});

When('the operator presses ArrowDown', async ({ page }: { page: Page }) => {
  await page.keyboard.press('ArrowDown');
});

When('the operator presses Home', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Home');
});

When('the operator presses End', async ({ page }: { page: Page }) => {
  await page.keyboard.press('End');
});

let lastStreamHeight: number | null = null;

async function currentStreamHeight(page: Page): Promise<number> {
  const box = await streamPanelLocator(page).boundingBox();
  if (!box) throw new Error('[logs-trace-map] stream panel has no bounding box');
  return box.height;
}

Then('the Trace Map stream panel is taller than its default height', async ({ page }: { page: Page }) => {
  const height = await currentStreamHeight(page);
  expect(height).toBeGreaterThan(218);
  lastStreamHeight = height;
});

Then('the Trace Map stream panel is shorter than it was', async ({ page }: { page: Page }) => {
  const height = await currentStreamHeight(page);
  expect(lastStreamHeight).not.toBeNull();
  expect(height).toBeLessThan(lastStreamHeight as number);
  lastStreamHeight = height;
});

Then(
  'the Trace Map stream panel is at its default height of {int} pixels',
  async ({ page }: { page: Page }, expected: number) => {
    const height = await currentStreamHeight(page);
    expect(Math.abs(height - expected)).toBeLessThanOrEqual(2);
    lastStreamHeight = height;
  },
);

Then(
  'the Trace Map stream panel height decreases by {int} pixels',
  async ({ page }: { page: Page }, delta: number) => {
    const height = await currentStreamHeight(page);
    expect(lastStreamHeight).not.toBeNull();
    expect(Math.abs((lastStreamHeight as number) - delta - height)).toBeLessThanOrEqual(2);
    lastStreamHeight = height;
  },
);

Then(
  'the Trace Map stream panel height increases by {int} pixels',
  async ({ page }: { page: Page }, delta: number) => {
    const height = await currentStreamHeight(page);
    expect(lastStreamHeight).not.toBeNull();
    expect(Math.abs((lastStreamHeight as number) + delta - height)).toBeLessThanOrEqual(2);
    lastStreamHeight = height;
  },
);

Then('the Trace Map stream panel is minimized', async ({ page }: { page: Page }) => {
  const height = await currentStreamHeight(page);
  expect(height).toBeLessThan(100);
});

Then('the Trace Map stream panel is maximized', async ({ page }: { page: Page }) => {
  const height = await currentStreamHeight(page);
  expect(height).toBeGreaterThan(300);
});

// ═════════════════════════════════════════════════════════════════════════════
// enhanced-logging/trace-map-node-controls (ATDD, RED phase) — Scenarios A–F
// of logs-trace-map-node-controls.feature (@pending-feature until the
// dev-story lands).
//
// docs/stories/enhanced-logging/trace-map-node-controls.md
// Design: trace-map-leitstand-spec.md §4/§5 + trace-map-leitstand-dummy.html.
//
// Data-attribute contract (mirrors the AUTHORITATIVE server-side pins in
// server/test/nebu/admin/logs_live/trace_map_node_controls_test.exs):
//   - Off node: data-node-status="off", count text "off", aria-label
//     contains "logging off".
//   - Temp node: data-node-status="temp" +
//     [data-testid="trace-map-node-countdown"] (mm:ss, data-expires-at).
//   - Inspector logging: [data-testid="trace-map-inspector-logging"],
//     level select [data-testid="trace-map-inspector-level-select"],
//     retention select [data-testid="trace-map-inspector-retention-select"],
//     scope note [data-testid="trace-map-inspector-scope-note"], capture
//     state [data-testid="trace-map-inspector-capture-state"] + toggle
//     button [data-testid="trace-map-inspector-capture-toggle"].
//   - Announcer: [data-testid="trace-map-announcer"] (sr-only live region).
//
// /health is BOTH a domain and a satellite node (single-segment route) —
// all node steps below are KIND-scoped to "satellite" to stay strict-mode
// safe (the ATDD lesson from trace-map-hierarchy).
// ═════════════════════════════════════════════════════════════════════════════

// Scenario cleanup: capture rows and per-endpoint config rows must not leak
// into later scenarios/suite runs (same hygiene as @ac6-war-room-banner).
After({ tags: '@node-controls-capture' }, async () => {
  clearTemporaryCaptures();
});

After({ tags: '@node-controls-config' }, async () => {
  clearEndpointLoggingConfig();
});

// Broadest node-controls hygiene: an ERROR seeded for an off-list route
// (e.g. Scenario C2) is genuinely persisted (errors-always-persist) and
// stays inside the Trace Map's 60-second sliding window for up to 60 real
// seconds — long enough to leak into a LATER scenario's fresh mount and
// falsely render that endpoint in the "error" state. Runs after EVERY
// node-controls scenario (all 7 carry this tag) so the window can never
// straddle two scenarios.
After({ tags: '@node-controls' }, async () => {
  clearOffEndpointOperationalLogs();
});

function satNodeLocator(page: Page, key: string) {
  return page.locator(
    `[data-testid="trace-map-node"][data-node-key="${key}"][data-node-kind="satellite"]`,
  );
}

function nodeCountdownLocator(page: Page, key: string) {
  return satNodeLocator(page, key).locator('[data-testid="trace-map-node-countdown"]');
}

function levelSelectLocator(page: Page) {
  return page.locator('[data-testid="trace-map-inspector-level-select"]');
}

function retentionSelectLocator(page: Page) {
  return page.locator('[data-testid="trace-map-inspector-retention-select"]');
}

function announcerLocator(page: Page) {
  return page.locator('[data-testid="trace-map-announcer"]');
}

/** The selected <option>'s LABEL (not value) of a select. */
async function selectedOptionLabel(locator: ReturnType<Page['locator']>): Promise<string> {
  return locator.evaluate((el) => {
    const select = el as HTMLSelectElement;
    return select.selectedOptions[0]?.label?.trim() ?? '';
  });
}

// ─── Given: config + capture seeding (direct DB, fixtures/db.ts) ────────────

Given(
  'the logging config for {string} is min level {string} with retention days {string}',
  async ({}: object, route: string, level: string, days: string) => {
    upsertServerConfig(`log_min_level_${route}`, level.toLowerCase());
    upsertServerConfig(`log_retention_days_${route}`, days);
  },
);

Given(
  'a temporary capture for {string} expiring in {int} seconds exists',
  async ({}: object, endpoint: string, seconds: number) => {
    insertTemporaryCapture({ endpoint, expiresInSeconds: seconds });
  },
);

// ─── When: inspector interactions ───────────────────────────────────────────

When(
  'the operator clicks the {string} satellite node on the Trace Map',
  async ({ page }: { page: Page }, key: string) => {
    await awaitLeitstandReady(page);
    await satNodeLocator(page, key).click();
  },
);

When(
  'the operator changes the inspector min level to {string}',
  async ({ page }: { page: Page }, level: string) => {
    await awaitLeitstandReady(page);
    await levelSelectLocator(page).selectOption({ label: level });
  },
);

When(
  'the operator focuses the inspector min level select',
  async ({ page }: { page: Page }) => {
    await levelSelectLocator(page).focus();
  },
);

When(
  'the operator clicks {string} in the Trace Map inspector',
  async ({ page }: { page: Page }, buttonName: string) => {
    await awaitLeitstandReady(page);
    await inspectorLocator(page).getByRole('button', { name: buttonName }).click();
  },
);

// ─── Then: inspector logging panel (Scenarios A/B — AC1/AC2/AC3) ────────────

Then(
  'the inspector logging panel shows min level {string} and retention {string}',
  async ({ page }: { page: Page }, level: string, retention: string) => {
    await expect(levelSelectLocator(page)).toBeVisible({ timeout: 10_000 });

    await expect
      .poll(async () => selectedOptionLabel(levelSelectLocator(page)), { timeout: 10_000 })
      .toBe(level);

    await expect
      .poll(async () => selectedOptionLabel(retentionSelectLocator(page)), { timeout: 10_000 })
      .toBe(retention);
  },
);

Then(
  'the inspector scope note reads {string}',
  async ({ page }: { page: Page }, note: string) => {
    await expect(page.locator('[data-testid="trace-map-inspector-scope-note"]')).toContainText(
      note,
      { timeout: 10_000 },
    );
  },
);

Then(
  'the stored min level for {string} is {string}',
  async ({}: object, route: string, expected: string) => {
    // "verified via a Playwright DB query" (story AC11, Scenario B) —
    // polled because the LiveView change event persists asynchronously
    // relative to the browser interaction.
    await expect
      .poll(() => queryServerConfigValue(`log_min_level_${route}`), { timeout: 10_000 })
      .toBe(expected);
  },
);

Then(
  'the inspector requests stat reaches at least 2 without a reload',
  async ({ page }: { page: Page }, ) => {
    // The live stat patch (AC3's trigger): the second real request's PubSub
    // broadcast must bump the requests/60s stat on the ALREADY-OPEN page.
    await expect
      .poll(
        async () => {
          const text = await page
            .locator('[data-testid="trace-map-inspector-stat-requests"]')
            .innerText();
          return Number.parseInt(text.trim(), 10) || 0;
        },
        { timeout: 20_000 },
      )
      .toBeGreaterThanOrEqual(2);
  },
);

Then(
  'the inspector min level select still has focus and shows {string}',
  async ({ page }: { page: Page }, level: string) => {
    // AC3, the authoritative browser-level check: the stat patch above must
    // NOT have rebuilt the select — value and REAL keyboard focus survive.
    expect(await selectedOptionLabel(levelSelectLocator(page))).toBe(level);

    const focused = await page.evaluate(
      () =>
        document.activeElement?.getAttribute('data-testid') ===
        'trace-map-inspector-level-select',
    );
    expect(focused, 'AC3: the level select must never lose focus to a re-render').toBe(true);
  },
);

Then(
  'a success message matching {string} and {string} is shown',
  async ({ page }: { page: Page }, first: string, second: string) => {
    const flash = page.getByText(new RegExp(`${first}.*${second}`), { exact: false }).first();
    await expect(flash).toBeVisible({ timeout: 10_000 });
  },
);

// ─── Then: off / temp visual states (Scenarios C–F — AC4/AC6/AC8) ───────────

Then(
  'the {string} satellite node is rendered as logging-off',
  async ({ page }: { page: Page }, key: string) => {
    const node = satNodeLocator(page, key);
    await expect(node).toHaveAttribute('data-node-status', 'off', { timeout: 10_000 });
    await expect(node).toContainText('off');
    await expect(node).toHaveAttribute('aria-label', /logging off/i);
    await expect(nodeCountdownLocator(page, key)).toHaveCount(0);
  },
);

Then(
  'the {string} satellite node shows a capture countdown',
  async ({ page }: { page: Page }, key: string) => {
    await expect(satNodeLocator(page, key)).toHaveAttribute('data-node-status', 'temp', {
      timeout: 10_000,
    });
    await expect(nodeCountdownLocator(page, key)).toHaveText(/\d{2}:\d{2}/, { timeout: 10_000 });
  },
);

Then(
  'the {string} capture countdown starts near five minutes',
  async ({ page }: { page: Page }, key: string) => {
    // Default duration 300 s -> "04:5x" right after enabling (05:00 allowed
    // for a same-second read).
    await expect(nodeCountdownLocator(page, key)).toHaveText(/^(04:5\d|05:00)$/, {
      timeout: 10_000,
    });
  },
);

Then(
  'the {string} capture countdown decreases within {int} seconds',
  async ({ page }: { page: Page }, key: string, seconds: number) => {
    const countdown = nodeCountdownLocator(page, key);
    // The node's own countdown is an SVG <text> element — SVGElement has no
    // `innerText` (an HTMLElement-only DOM property; Playwright's
    // `.innerText()` action explicitly rejects non-HTMLElement targets with
    // "Node is not an HTMLElement"). `.textContent()` works uniformly for
    // both SVG and HTML nodes.
    const before = ((await countdown.textContent()) ?? '').trim();

    // AC6: client-side 1 s tick (TraceMapLeitstand hook) — wait for the
    // TEXT to change, never a bare sleep.
    await page.waitForFunction(
      ({ selector, previous }) => {
        const el = document.querySelector(selector);
        return el !== null && el.textContent?.trim() !== previous && el.textContent !== null;
      },
      {
        selector:
          `[data-testid="trace-map-node"][data-node-key="${key}"][data-node-kind="satellite"] ` +
          '[data-testid="trace-map-node-countdown"]',
        previous: before,
      },
      { timeout: seconds * 1_000 },
    );

    const after = ((await countdown.textContent()) ?? '').trim();
    expect(after < before, `countdown must decrease (was ${before}, now ${after})`).toBe(true);
  },
);

Then(
  'within {int} seconds the {string} satellite node reverts to logging-off',
  async ({ page }: { page: Page }, seconds: number, key: string) => {
    const node = satNodeLocator(page, key);
    await expect(node).toHaveAttribute('data-node-status', 'off', { timeout: seconds * 1_000 });
    await expect(nodeCountdownLocator(page, key)).toHaveCount(0);
  },
);

// ─── Then: inspector capture controls + announcer (AC5/AC9) ─────────────────

Then(
  'the inspector shows capture active with a {string} button',
  async ({ page }: { page: Page }, buttonName: string) => {
    await expect(
      page.locator('[data-testid="trace-map-inspector-capture-state"]'),
    ).toContainText('Capture active', { timeout: 10_000 });

    await expect(
      inspectorLocator(page).getByRole('button', { name: buttonName }),
    ).toBeVisible({ timeout: 10_000 });
  },
);

Then(
  'the Trace Map inspector offers to enable capture again',
  async ({ page }: { page: Page }) => {
    await expect(
      page.locator('[data-testid="trace-map-inspector-capture-state"]'),
    ).toContainText('Logging off', { timeout: 10_000 });

    await expect(
      inspectorLocator(page).getByRole('button', { name: /enable/i }),
    ).toBeVisible({ timeout: 10_000 });
  },
);

Then(
  'the Trace Map live announcer mentions {string}',
  async ({ page }: { page: Page }, text: string) => {
    // The announcer is an sr-only (visually clipped, NOT display:none) live
    // region — assert on its text content, not visibility.
    await expect(announcerLocator(page)).toContainText(text, { timeout: 10_000 });
  },
);

Then(
  'the {string} satellite node shows an off-tier error state',
  async ({ page }: { page: Page }, key: string) => {
    // Story amendment 2026-07-07 (errors-always-persist): an ERROR in the
    // 60 s window drives the node's status even while logging is off — the
    // error state renders ON the dashed off stroke (data-node-off keeps the
    // dashed styling, data-node-status carries the error).
    const node = satNodeLocator(page, key);
    await expect(node).toHaveAttribute('data-node-status', 'error', { timeout: 10_000 });
    await expect(node).toHaveAttribute('data-node-off', 'true');
    await expect(node.locator('[data-testid="trace-map-badge-error"]')).toBeVisible();
  },
);
