/**
 * Step definitions for features/admin/logs-trace-map-zoom-pan.feature
 *
 * Story enhanced-logging/trace-map-zoom-pan — ATDD, written FIRST (RED phase).
 * docs/stories/enhanced-logging/trace-map-zoom-pan.md
 *
 * RED PHASE: none of `[data-testid="trace-map-zoom-in"/"trace-map-zoom-out"/
 * "trace-map-zoom-reset"/"trace-map-zoom-controls"]` exist yet, and the SVG
 * map (`[data-testid="trace-map-svg"]`) carries no `tabindex` or
 * keyboard-support aria-label yet — every scenario below is tagged
 * @pending-feature (excluded from the default run by playwright.config.ts's
 * DEFAULT_E2E_TAGS) until the dev-story lands, following this project's
 * established un-tagging convention (logs-trace-map.feature's own history).
 *
 * Reuses steps already defined elsewhere (playwright-bdd matches step text
 * against ALL loaded step files — redefining an identical pattern here would
 * make the step ambiguous at `bddgen` time):
 *   - "the Nebu stack is running"                        (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"                      (admin/bootstrap.steps.ts)
 *   - "the operator is logged in as admin"                (admin/bootstrap.steps.ts)
 *   - "the operator navigates to {string}"                (admin/bootstrap.steps.ts)
 *   - "a request to {string} has been recorded"           (admin/logs-monitoring.steps.ts)
 *   - "the operator reloads the Trace Map page"            (admin/logs-trace-map.steps.ts)
 *   - "the operator clicks the {string} node on the Trace Map"          (admin/logs-trace-map.steps.ts)
 *   - "the {string} node shows a selection ring"           (admin/logs-trace-map.steps.ts)
 *   - "a Trace Map filter chip for {string} is visible"    (admin/logs-trace-map.steps.ts)
 *   - "a Trace Map filter chip is visible"                 (admin/logs-trace-map.steps.ts)
 *   - "the operator presses Tab"                           (admin/logs-trace-map.steps.ts)
 *   - "the operator presses Tab until a Trace Map node is focused" (admin/logs-trace-map.steps.ts)
 *   - "the {string} node on the Trace Map has focus"       (admin/logs-trace-map.steps.ts)
 *   - "the focused Trace Map node is a domain node"        (admin/logs-trace-map.steps.ts)
 *   - "the operator presses Enter on the focused Trace Map node" (admin/logs-trace-map.steps.ts)
 *   - "the focused domain node has aria-pressed {string}"  (admin/logs-trace-map.steps.ts)
 *
 * ## Data-attribute / concrete contract this file assumes (kept in sync with
 * the AUTHORITATIVE pin in
 * server/test/nebu/admin/logs_live/trace_map_zoom_pan_test.exs — see that
 * file's moduledoc for the full rationale):
 *   - Zoom in:    [data-testid="trace-map-zoom-in"], aria-label "Zoom in".
 *   - Zoom out:   [data-testid="trace-map-zoom-out"], aria-label "Zoom out".
 *   - Reset:      [data-testid="trace-map-zoom-reset"], visible text AND
 *                 aria-label "Reset view".
 *   - Controls group: [data-testid="trace-map-zoom-controls"].
 *   - Map surface: [data-testid="trace-map-svg"] gains tabindex="0"; real
 *                  keyboard zoom/pan works regardless of which element on
 *                  the page currently has focus vs. is the ACTIVE target for
 *                  +/-/arrow keys is an implementation choice — these steps
 *                  press keys globally (`page.keyboard.press`), matching the
 *                  existing resizer steps' own convention (they never
 *                  re-verify which element is focused before pressing
 *                  Arrow/Home/End either).
 *   - Proposed numeric bounds (dev's own implementation, not re-derivable
 *     from markup — see the ExUnit file's moduledoc for the full formula):
 *     MIN_ZOOM=1.0, MAX_ZOOM=4.0, zoom step 0.1/keystroke or wheel-tick,
 *     keyboard pan step 32 SVG units, pan offset clamped to
 *     px ∈ [0, 1560 - 1560/zoom], py ∈ [0, 1300 - 1300/zoom] (so at the
 *     default zoom=1.0 panning is a no-op).
 *
 * ## "Saturates at a boundary" testing strategy
 *
 * Rather than hardcoding the exact clamp arithmetic (an implementation
 * detail), the zoom/pan-bounds scenarios press the same key repeatedly and
 * assert the tracked value (viewBox width for zoom, viewBox x for pan)
 * stops changing well before the last keystroke — the true observable
 * "sensible bounds exist" behavior (AC3), without over-specifying the exact
 * numbers a correct implementation must produce.
 */

import { When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

// ─── Locators ────────────────────────────────────────────────────────────

function svgLocator(page: Page) {
  return page.locator('[data-testid="trace-map-svg"]');
}

function zoomInLocator(page: Page) {
  return page.locator('[data-testid="trace-map-zoom-in"]');
}

function zoomOutLocator(page: Page) {
  return page.locator('[data-testid="trace-map-zoom-out"]');
}

function resetLocator(page: Page) {
  return page.locator('[data-testid="trace-map-zoom-reset"]');
}

// UX gate finding 2: on-screen Pan Up/Down/Left/Right buttons (AT-accessible
// pan path, mirroring the zoom buttons' own locator pattern).
function panRightLocator(page: Page) {
  return page.locator('[data-testid="trace-map-pan-right"]');
}

function panLeftLocator(page: Page) {
  return page.locator('[data-testid="trace-map-pan-left"]');
}

function nodeLocator(page: Page, key: string) {
  return page.locator(`[data-testid="trace-map-node"][data-node-key="${key}"]`);
}

function mapWrapLocator(page: Page) {
  return page.locator('#trace-map-map-wrap');
}

function streamLineLocator(page: Page, route: string) {
  return page.locator(`[data-testid="trace-map-stream-line"][data-route="${route}"]`);
}

/**
 * Same synchronization contract as logs-trace-map.steps.ts's own
 * awaitLeitstandReady — every hook-driven interaction (including the new
 * zoom/pan wiring, which lives in the SAME TraceMapLeitstand hook) only
 * works once the LiveSocket has connected and the hook has mounted.
 */
async function awaitLeitstandReady(page: Page) {
  await page.waitForFunction(
    () => (window as unknown as { __nebuTraceMapHookReady?: boolean }).__nebuTraceMapHookReady === true,
    undefined,
    { timeout: 20_000 },
  );
}

interface ViewBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

const DEFAULT_VIEWBOX: ViewBox = { x: -780, y: -650, w: 1560, h: 1300 };
const VIEWBOX_EPSILON = 0.75;

async function readViewBox(page: Page): Promise<ViewBox> {
  // Real browser DOM: unlike Floki (which lowercases attribute NAMES in the
  // ExUnit tests), `getAttribute` here reads the actual case-correct SVG
  // `viewBox` attribute.
  const raw = await svgLocator(page).getAttribute('viewBox');
  if (!raw) {
    throw new Error('[logs-trace-map-zoom-pan] the Trace Map SVG has no viewBox attribute');
  }
  const [x, y, w, h] = raw.trim().split(/\s+/).map(Number);
  return { x, y, w, h };
}

function viewBoxesEqual(a: ViewBox, b: ViewBox): boolean {
  return (
    Math.abs(a.x - b.x) < VIEWBOX_EPSILON &&
    Math.abs(a.y - b.y) < VIEWBOX_EPSILON &&
    Math.abs(a.w - b.w) < VIEWBOX_EPSILON &&
    Math.abs(a.h - b.h) < VIEWBOX_EPSILON
  );
}

async function boundingBox(page: Page, locator: ReturnType<typeof page.locator>) {
  const box = await locator.boundingBox();
  if (!box) throw new Error('[logs-trace-map-zoom-pan] element has no bounding box (not visible?)');
  return box;
}

// ─── Scenario-local state (reset per scenario by playwright-bdd's own
// per-test module isolation — each scenario runs in a fresh worker context,
// mirrors the `lastStreamHeight`-style module-level state already used in
// logs-trace-map.steps.ts for the resizer) ─────────────────────────────────

let rememberedViewBox: ViewBox | null = null;
let rememberedNodeScreenCenter: { x: number; y: number } | null = null;
let rememberedScrollY: number | null = null;
let rememberedViewBoxBeforePan: ViewBox | null = null;
let zoomWidthHistory: number[] = [];
let zoomWidthPreValue: number | null = null;
let panXHistory: number[] = [];
let panXPreValue: number | null = null;

// ─── When: mouse wheel zoom (AC1) ───────────────────────────────────────────

async function wheelZoom(page: Page, x: number, y: number, ticks: number, direction: 'in' | 'out') {
  await awaitLeitstandReady(page);
  await page.mouse.move(x, y);
  const deltaY = direction === 'in' ? -120 : 120; // negative deltaY = scroll up = zoom in (spec convention)
  for (let i = 0; i < ticks; i += 1) {
    await page.mouse.wheel(0, deltaY);
  }
}

When(
  'the operator scrolls the mouse wheel up {int} times over the {string} node on the Trace Map',
  async ({ page }: { page: Page }, ticks: number, key: string) => {
    const box = await boundingBox(page, nodeLocator(page, key));
    rememberedNodeScreenCenter = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    await wheelZoom(page, rememberedNodeScreenCenter.x, rememberedNodeScreenCenter.y, ticks, 'in');
  },
);

When(
  'the operator scrolls the mouse wheel up {int} times over the center of the Trace Map',
  async ({ page }: { page: Page }, ticks: number) => {
    const box = await boundingBox(page, mapWrapLocator(page));
    rememberedScrollY = await page.evaluate(() => window.scrollY);
    await wheelZoom(page, box.x + box.width / 2, box.y + box.height / 2, ticks, 'in');
  },
);

When(
  'the operator scrolls the mouse wheel down {int} times over the center of the Trace Map',
  async ({ page }: { page: Page }, ticks: number) => {
    const box = await boundingBox(page, mapWrapLocator(page));
    await wheelZoom(page, box.x + box.width / 2, box.y + box.height / 2, ticks, 'out');
  },
);

// ─── Then: zoom-level assertions (AC1/AC3) ──────────────────────────────────

Then('the Trace Map view is zoomed in', async ({ page }: { page: Page }) => {
  const vb = await readViewBox(page);
  expect(vb.w).toBeLessThan(DEFAULT_VIEWBOX.w - VIEWBOX_EPSILON);
});

Then(
  'the Trace Map view is zoomed in to at least {int} times the default',
  async ({ page }: { page: Page }, factor: number) => {
    const vb = await readViewBox(page);
    expect(vb.w).toBeLessThanOrEqual(DEFAULT_VIEWBOX.w / factor + VIEWBOX_EPSILON);
  },
);

Then(
  'the Trace Map view is at its default zoom level, showing the full map without panning',
  async ({ page }: { page: Page }) => {
    const vb = await readViewBox(page);
    expect(viewBoxesEqual(vb, DEFAULT_VIEWBOX)).toBe(true);
  },
);

Then(
  'the {string} node stays under the cursor after zooming',
  async ({ page }: { page: Page }, key: string) => {
    expect(rememberedNodeScreenCenter).not.toBeNull();
    const box = await boundingBox(page, nodeLocator(page, key));
    const after = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
    // "the point under the cursor stays under the cursor" (AC1) — a
    // generous tolerance (the node itself has non-zero radius on screen)
    // rather than pixel-perfect equality, since rendering/anti-aliasing and
    // the exact wheel-to-zoom-step mapping are implementation details.
    expect(Math.abs(after.x - (rememberedNodeScreenCenter as { x: number }).x)).toBeLessThan(15);
    expect(Math.abs(after.y - (rememberedNodeScreenCenter as { y: number }).y)).toBeLessThan(15);
  },
);

Then('the page has not scrolled', async ({ page }: { page: Page }) => {
  expect(rememberedScrollY).not.toBeNull();
  const scrollY = await page.evaluate(() => window.scrollY);
  expect(scrollY).toBe(rememberedScrollY);
});

// ─── When/Then: click-and-drag pan (AC2) ────────────────────────────────────

When(
  'the operator drags the Trace Map background from an empty area by {int} pixels right and {int} pixels down',
  async ({ page }: { page: Page }, dx: number, dy: number) => {
    await awaitLeitstandReady(page);
    rememberedViewBoxBeforePan = await readViewBox(page);
    const box = await boundingBox(page, mapWrapLocator(page));
    // A corner well away from nebu (origin, center of the map) and from any
    // domain/satellite ring — empty background, never a node.
    const startX = box.x + 12;
    const startY = box.y + 12;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(startX + dx, startY + dy, { steps: 8 });
    await page.mouse.up();
  },
);

// test-review follow-up: the app's pan model anchors the DEFAULT viewport to
// the map's top-left corner (px/py clamp to [0, ...], never negative — see
// traceMapClampPan in app.js) and follows the standard "grab and drag" map
// convention (drag the mouse LEFT/UP to reveal more of the map's RIGHT/DOWN
// side, exactly like Google Maps/Leaflet — content follows the cursor).
// Starting from that default top-left-anchored position, dragging
// right-and-down (the sibling step above) tries to move the viewport to
// panX/panY < 0, which the clamp floor makes an immediate no-op regardless
// of zoom level — confirmed live: at zoom 2.0 a right+down drag never moves
// the viewBox at all, while an otherwise-identical left+up drag does. This
// step drags in the direction that actually has clamp room to move in.
When(
  'the operator drags the Trace Map background from an empty area by {int} pixels left and {int} pixels up',
  async ({ page }: { page: Page }, dx: number, dy: number) => {
    await awaitLeitstandReady(page);
    rememberedViewBoxBeforePan = await readViewBox(page);
    const box = await boundingBox(page, mapWrapLocator(page));
    const startX = box.x + 12;
    const startY = box.y + 12;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(startX - dx, startY - dy, { steps: 8 });
    await page.mouse.up();
  },
);

When(
  'the operator drags the {string} node on the Trace Map by {int} pixels',
  async ({ page }: { page: Page }, key: string, pixels: number) => {
    await awaitLeitstandReady(page);
    rememberedViewBoxBeforePan = await readViewBox(page);
    const box = await boundingBox(page, nodeLocator(page, key));
    const startX = box.x + box.width / 2;
    const startY = box.y + box.height / 2;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    // AC2/Dev Notes: "on pointerdown over a node, flag skipPan = true; pan
    // only when pointerdown is on empty space" — this step is invoked with
    // BOTH a small ({int} well under the dev notes' 5px click/drag
    // threshold, exercising the "accidental drag-start" case) AND a large
    // {int} (50-80px, test-review MINOR-2: a genuine, intentional drag
    // gesture started ON a node). Both must equally fail to pan — the
    // dev notes' contract is "started on a node", never a uniform distance
    // threshold, so a correct implementation must not pan regardless of
    // how far the drag travels once it began on a node.
    await page.mouse.move(startX + pixels, startY, { steps: 8 });
    await page.mouse.up();
  },
);

Then('the Trace Map viewport has panned', async ({ page }: { page: Page }) => {
  expect(rememberedViewBoxBeforePan).not.toBeNull();
  const vb = await readViewBox(page);
  expect(viewBoxesEqual(vb, rememberedViewBoxBeforePan as ViewBox)).toBe(false);
});

Then('the Trace Map viewport has not panned', async ({ page }: { page: Page }) => {
  expect(rememberedViewBoxBeforePan).not.toBeNull();
  const vb = await readViewBox(page);
  expect(viewBoxesEqual(vb, rememberedViewBoxBeforePan as ViewBox)).toBe(true);
});

// ─── When/Then: keyboard zoom/pan (AC5) ─────────────────────────────────────

async function focusMap(page: Page) {
  await awaitLeitstandReady(page);
  await svgLocator(page).focus();
}

When('the operator focuses the Trace Map', async ({ page }: { page: Page }) => {
  await focusMap(page);
});

When(
  'the operator focuses the Trace Map and presses the zoom-in key {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await focusMap(page);
    zoomWidthPreValue = (await readViewBox(page)).w;
    zoomWidthHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press('+');
      zoomWidthHistory.push((await readViewBox(page)).w);
    }
  },
);

When(
  'the operator presses the zoom-out key {int} times',
  async ({ page }: { page: Page }, times: number) => {
    zoomWidthPreValue = (await readViewBox(page)).w;
    zoomWidthHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press('-');
      zoomWidthHistory.push((await readViewBox(page)).w);
    }
  },
);

When(
  'the operator focuses the Trace Map and presses the zoom-out key {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await focusMap(page);
    zoomWidthPreValue = (await readViewBox(page)).w;
    zoomWidthHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press('-');
      zoomWidthHistory.push((await readViewBox(page)).w);
    }
  },
);

// AC5 alternate key bindings (test-review MINOR-1): the story specifies
// `+`/`=` or `PageUp` to zoom in, `-`/`_` or `PageDown` to zoom out — not
// just the bare `+`/`-` the scenarios above exercise. This generic step
// drives ANY of the four alternates by name so an implementation that wires
// only `+`/`-` (dropping the alternates) fails the alternate-binding
// scenario as it should.
When(
  'the operator presses {string} to zoom in {int} times',
  async ({ page }: { page: Page }, key: string, times: number) => {
    zoomWidthPreValue = (await readViewBox(page)).w;
    zoomWidthHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press(key);
      zoomWidthHistory.push((await readViewBox(page)).w);
    }
  },
);

When(
  'the operator presses {string} to zoom out {int} times',
  async ({ page }: { page: Page }, key: string, times: number) => {
    zoomWidthPreValue = (await readViewBox(page)).w;
    zoomWidthHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press(key);
      zoomWidthHistory.push((await readViewBox(page)).w);
    }
  },
);

When(
  'the operator presses the pan-right key {int} times',
  async ({ page }: { page: Page }, times: number) => {
    panXPreValue = (await readViewBox(page)).x;
    panXHistory = [];
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press('ArrowRight');
      panXHistory.push((await readViewBox(page)).x);
    }
  },
);

When(
  'the operator presses the pan-left key {int} times',
  async ({ page }: { page: Page }, times: number) => {
    for (let i = 0; i < times; i += 1) {
      await page.keyboard.press('ArrowLeft');
    }
  },
);

Then(
  'the Trace Map zoom level stops increasing before {int} keystrokes',
  async ({}: object, totalPresses: number) => {
    expect(zoomWidthHistory.length).toBe(totalPresses);
    assertSaturatesWithRoomToSpare(zoomWidthHistory, totalPresses, zoomWidthPreValue);
  },
);

Then(
  'the Trace Map zoom level stops decreasing before {int} keystrokes',
  async ({}: object, totalPresses: number) => {
    expect(zoomWidthHistory.length).toBe(totalPresses);
    assertSaturatesWithRoomToSpare(zoomWidthHistory, totalPresses, zoomWidthPreValue);
  },
);

Then(
  'the Trace Map pan offset stops increasing before {int} keystrokes',
  async ({}: object, totalPresses: number) => {
    expect(panXHistory.length).toBe(totalPresses);
    assertSaturatesWithRoomToSpare(panXHistory, totalPresses, panXPreValue);
  },
);

/**
 * Asserts that `history` (one sample per keystroke) reaches a stable
 * plateau (consecutive values within VIEWBOX_EPSILON of the final value)
 * well before the last keystroke — proof that a hard bound was hit, not
 * just that the sampled sequence happens to end there. "Well before" =
 * at least 3 keystrokes of headroom, which is comfortably inside any of
 * this file's `{int} times` scenario counts (all ≥ 10 keystrokes past the
 * proposed MIN/MAX bounds' own reachable step counts).
 *
 * test-review MINOR-3 (defense-in-depth): a "saturates" plateau at the
 * FINAL value is not, by itself, proof that the key/button actually did
 * anything — a completely non-functional handler produces a perfectly flat
 * history too, and would satisfy the plateau check above vacuously. `pre`
 * is the value read immediately BEFORE the press loop started; this also
 * asserts the tracked value moved away from that baseline by at least one
 * sample, proving the mechanism responds to input at all. Callers whose
 * scenario legitimately starts already AT the boundary (so `pre` itself
 * already equals every subsequent reading) must zoom/pan away from that
 * boundary first — see "Zoom-out saturates at the minimum bound", which
 * zooms in before zooming out, specifically so this check is meaningful
 * rather than spuriously failing a correct implementation.
 */
function assertSaturatesWithRoomToSpare(history: number[], totalPresses: number, pre: number | null) {
  expect(pre, '[logs-trace-map-zoom-pan] no pre-press baseline was recorded').not.toBeNull();

  const last = history[history.length - 1];
  const plateauStart = history.findIndex((v) => Math.abs(v - last) < VIEWBOX_EPSILON);
  expect(
    plateauStart,
    `[logs-trace-map-zoom-pan] expected the tracked value to saturate at a boundary well before ` +
      `all ${totalPresses} keystrokes were used, but it kept changing until the very end: ` +
      `${JSON.stringify(history)}`,
  ).toBeLessThan(totalPresses - 3);

  const movedAtLeastOnce = history.some((v) => Math.abs(v - (pre as number)) >= VIEWBOX_EPSILON);
  expect(
    movedAtLeastOnce,
    `[logs-trace-map-zoom-pan] the tracked value never changed from its pre-press baseline ` +
      `(${pre}) — a non-functional key/button handler would also produce this flat history: ` +
      `${JSON.stringify(history)}. The scenario must start away from the boundary it expects to ` +
      `reach, not already on it.`,
  ).toBe(true);
}

Then(
  'the {string} node on the Trace Map remains at least partially within the visible viewport',
  async ({ page }: { page: Page }, key: string) => {
    const nodeBox = await boundingBox(page, nodeLocator(page, key));
    const mapBox = await boundingBox(page, mapWrapLocator(page));
    const intersects =
      nodeBox.x < mapBox.x + mapBox.width &&
      nodeBox.x + nodeBox.width > mapBox.x &&
      nodeBox.y < mapBox.y + mapBox.height &&
      nodeBox.y + nodeBox.height > mapBox.y;
    expect(
      intersects,
      `[logs-trace-map-zoom-pan] AC3: panning must never push the entire map out of the viewport — ` +
        `"${key}" node rect ${JSON.stringify(nodeBox)} no longer overlaps the map area ${JSON.stringify(mapBox)}`,
    ).toBe(true);
  },
);

Then('the Trace Map view is back at its pre-pan position', async ({ page }: { page: Page }) => {
  const vb = await readViewBox(page);
  // panXHistory[0] is the x AFTER the first pan-right press; the position
  // "before" that first press is the entry the caller remembered via
  // "the operator focuses the Trace Map and presses the zoom-in key N times"
  // (zoom only, no pan yet) — so an equal number of pan-left presses must
  // return x to whatever it was right after the zoom-in sequence, i.e. the
  // default pan offset (px=0) at that zoom level.
  expect(Math.abs(vb.x - DEFAULT_VIEWBOX.x)).toBeLessThan(VIEWBOX_EPSILON);
});

// ─── When: on-screen zoom in/out buttons (AC1/AC4 affordance) ───────────────

When(
  'the operator clicks the Trace Map zoom-in button {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await awaitLeitstandReady(page);
    for (let i = 0; i < times; i += 1) {
      await zoomInLocator(page).click();
    }
  },
);

When(
  'the operator clicks the Trace Map zoom-out button {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await awaitLeitstandReady(page);
    for (let i = 0; i < times; i += 1) {
      await zoomOutLocator(page).click();
    }
  },
);

// ─── When: on-screen pan buttons (UX gate finding 2 — AT-accessible pan) ────

When(
  'the operator clicks the Trace Map pan-right button {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await awaitLeitstandReady(page);
    rememberedViewBoxBeforePan = await readViewBox(page);
    for (let i = 0; i < times; i += 1) {
      await panRightLocator(page).click();
    }
  },
);

When(
  'the operator clicks the Trace Map pan-left button {int} times',
  async ({ page }: { page: Page }, times: number) => {
    await awaitLeitstandReady(page);
    for (let i = 0; i < times; i += 1) {
      await panLeftLocator(page).click();
    }
  },
);

// ─── When/Then: reset control (AC4) ─────────────────────────────────────────

When('the operator clicks the Trace Map {string} button', async ({ page }: { page: Page }, name: string) => {
  await awaitLeitstandReady(page);
  if (name === 'Reset view') {
    await resetLocator(page).click();
  } else {
    throw new Error(`[logs-trace-map-zoom-pan] unrecognized Trace Map button name: ${name}`);
  }
});

When(
  'the operator presses Tab until the Trace Map {string} button is focused',
  async ({ page }: { page: Page }, name: string) => {
    await awaitLeitstandReady(page);
    const maxTabs = 60;
    for (let i = 0; i < maxTabs; i += 1) {
      await page.keyboard.press('Tab');
      // test-review MINOR-4: substring match against the ACCESSIBLE NAME
      // (aria-label if present, else visible text) — matches the same
      // convention the ExUnit AC4 test uses (`Floki.text(button) =~ "Reset
      // view"`, substring) and what `getByRole(..., { name })` computes
      // (accessible name, aria-label preferred over text content). An
      // exact textContent match would silently diverge from both the moment
      // a future icon/decorative glyph is added inside the button.
      const focused = await page.evaluate((expectedName) => {
        const el = document.activeElement as HTMLElement | null;
        if (!el) return false;
        const accessibleName = (el.getAttribute('aria-label') || el.textContent || '').trim();
        return accessibleName.includes(expectedName);
      }, name);
      if (focused) return;
    }
    throw new Error(
      `[logs-trace-map-zoom-pan] the "${name}" button never received focus within ${maxTabs} Tab presses`,
    );
  },
);

When('the operator presses Enter on the focused Trace Map control', async ({ page }: { page: Page }) => {
  await page.keyboard.press('Enter');
});

Then('the focused Trace Map control shows a visible focus ring', async ({ page }: { page: Page }) => {
  const outlineStyle = await page.evaluate(() => {
    const el = document.activeElement as HTMLElement | null;
    return el ? getComputedStyle(el).outlineStyle : 'none';
  });
  expect(outlineStyle).not.toBe('none');
});

// ─── When/Then: live-update survival (AC6) ──────────────────────────────────

When('the operator remembers the current Trace Map viewport', async ({ page }: { page: Page }) => {
  rememberedViewBox = await readViewBox(page);
});

Then(
  'a Trace Map stream line for {string} appears',
  async ({ page }: { page: Page }, route: string) => {
    await expect(streamLineLocator(page, route).first()).toBeVisible({ timeout: 10_000 });
  },
);

Then('the Trace Map viewport is unchanged from the remembered viewport', async ({ page }: { page: Page }) => {
  expect(rememberedViewBox).not.toBeNull();
  const vb = await readViewBox(page);
  expect(
    viewBoxesEqual(vb, rememberedViewBox as ViewBox),
    `[logs-trace-map-zoom-pan] AC6: a LiveView patch (triggered by the live log broadcast) must ` +
      `never reset the client-owned zoom/pan viewport — remembered ${JSON.stringify(rememberedViewBox)}, ` +
      `now ${JSON.stringify(vb)}`,
  ).toBe(true);
});
