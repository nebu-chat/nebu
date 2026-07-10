/**
 * Step definitions for features/admin/logs-monitoring.feature
 *
 * Story enhanced-logging/admin-logs-monitoring-view — ATDD, written FIRST.
 * docs/stories/enhanced-logging/admin-logs-monitoring-view.md
 *
 * RED PHASE: `Nebu.Admin.LogsLive` etc. do not exist yet — every step below
 * targets markup/data-attributes that are not yet rendered anywhere. This is
 * expected; the feature is tagged @pending-feature (see playwright.config.ts's
 * `DEFAULT_E2E_TAGS`) and excluded from the default suite until the dev-story
 * implements `/admin/logs`.
 *
 * Shared background steps reused from admin/bootstrap.steps.ts:
 *   - "the Nebu stack is running"           (common/stack-health.steps.ts)
 *   - "bootstrap has been completed"
 *   - "the operator is logged in as admin"
 *   - "the operator navigates to {string}"
 *   - "the page shows {string}"
 *
 * ## Data-attribute contract (mirrors server/test/nebu/admin/logs_live_test.exs's
 * moduledoc — the SAME `data-testid`/`data-bubble-*` contract that file pins down
 * for the ExUnit suite, reused here so both suites exercise one consistent markup
 * shape):
 *   - Trace Map bubble: `[data-testid="trace-map-bubble"][data-bubble-dimension=...]
 *     [data-bubble-value=...]`, `aria-pressed`, `phx-click`.
 *   - Request row: `[data-testid="request-row"][data-request-id=...]`.
 *   - Detail panel: `[data-testid="detail-panel"][data-request-id=...]`.
 *
 * ## Why only level=info/source=http entries are used as fixtures
 *
 * `Nebu.Web.Plugs.RequestLogger` always logs the HTTP request/response line at
 * `:info` (server/lib/nebu/web/plugs/request_logger.ex) regardless of the response
 * status — RequestLogger never itself logs at :warning/:error. `Nebu.Repo.QueryTelemetry`
 * (the "ecto"-source entries) logs at `:debug`, which the running stack's Logger level
 * does not accept by default, so "ecto" entries are not reliably observable from a
 * black-box E2E test without also toggling the runtime Logger level (no such
 * operator-facing control exists yet — that is out of scope for this story). WARN/ERROR
 * entries only come from scattered `Logger.warning/error` calls tied to specific
 * internal failure conditions (OIDC claim gaps, DB errors, etc.) that are not safe or
 * deterministic to force from here. Real, plain Matrix Client-Server API calls
 * (`GET /_matrix/client/versions`, `GET /_matrix/client/v3/login` — both public,
 * unauthenticated, side-effect-free) are the only entry shape this file can
 * deterministically and safely produce, so endpoint-dimension filtering (two distinct
 * real route_templates) is used to prove real row-filtering, and the level-bubble
 * scenario only exercises the "info" bubble (the level every entry here actually has).
 */

import { Given, When, Then } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page, APIRequestContext } from '@playwright/test';
import { ensureOperationalLogRow } from '../../fixtures/db';

const MATRIX_BASE = process.env.NEBU_MATRIX_URL ?? 'http://localhost:8008';

// request_id (from the `x-request-id` response header — the SAME id RequestLogger
// reads to populate `operational_logs.request_id`, per request_logger.ex).
// Module-level state is safe here: this project runs with `workers: 1` /
// `fullyParallel: false` (playwright.config.ts), matching the existing pattern
// in stale-rooms.steps.ts's `currentRoomName`.
let lastRecordedRequestId: string | null = null;

async function recordEndpointHit(request: APIRequestContext, path: string): Promise<string> {
  const resp = await request.get(`${MATRIX_BASE}${path}`);
  const requestId = resp.headers()['x-request-id'];
  if (!requestId) {
    throw new Error(
      `[logs-monitoring] expected an "x-request-id" response header from GET ${path} ` +
        `(set by Nebu.Web.Plugs.RequestId — see request_logger.ex's ordering dependency note)`,
    );
  }
  return requestId;
}

function bubbleLocator(page: Page, dimension: string, value: string) {
  return page.locator(
    `[data-testid="trace-map-bubble"][data-bubble-dimension="${dimension}"][data-bubble-value="${value}"]`,
  );
}

function rowLocator(page: Page, requestId: string) {
  return page.locator(`[data-testid="request-row"][data-request-id="${requestId}"]`);
}

// ─── Given: real, deterministic log-entry fixtures ──────────────────────────────

Given(
  'a request to {string} has been recorded',
  async ({ request }: { request: APIRequestContext }, path: string) => {
    lastRecordedRequestId = await recordEndpointHit(request, path);
    // dev cycle 1 (trace-map-leitstand): RequestLogger logs this hit at INFO,
    // which is only PERSISTED when the log_collect_info policy is enabled —
    // scenarios that navigate AFTER recording read mount-time history from
    // the DB and were silently depending on that policy's state. Make the
    // precondition deterministic under any policy: ensure the row exists
    // (INSERT … WHERE NOT EXISTS on the real x-request-id — no duplicate when
    // collection IS on). See fixtures/db.ts's ensureOperationalLogRow doc.
    ensureOperationalLogRow({ requestId: lastRecordedRequestId, routeTemplate: path });
  },
);

// ─── When: Trace Map / row interactions ─────────────────────────────────────────
// (The endpoint-bubble click steps were retired by trace-map-leitstand AC13 —
// the Endpoints dimension no longer exists on /admin/logs; endpoint filtering
// is covered by logs-trace-map.feature on the dedicated Leitstand page.)

When(
  'the operator clicks the {string} level bubble in the Trace Map',
  async ({ page }: { page: Page }, value: string) => {
    await bubbleLocator(page, 'level', value).click();
  },
);

When('the operator clicks the request row for the last recorded request', async ({ page }: { page: Page }) => {
  if (!lastRecordedRequestId) {
    throw new Error('[logs-monitoring] no request has been recorded yet in this scenario');
  }
  // dev cycle 1 (trace-map-leitstand): opening the detail panel is a genuine
  // phx-click server round trip — on the throttled-longpoll transport the
  // LiveSocket connects a few seconds after first paint, and a click fired
  // before that silently no-ops on the static render. Wait for the LiveView
  // to be connected first (interaction synchronization, not an assertion
  // change).
  await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 20_000 });
  await rowLocator(page, lastRecordedRequestId).click();
});

When('the operator closes the detail panel', async ({ page }: { page: Page }) => {
  await page.locator('[data-testid="detail-panel"] button[phx-click="close_detail"]').click();
});

// ─── Then: Trace Map structure ───────────────────────────────────────────────────

Then(
  'the Trace Map shows a bubble section for {string}',
  async ({ page }: { page: Page }, sectionName: string) => {
    await expect(page.getByText(sectionName, { exact: false }).first()).toBeVisible({ timeout: 10_000 });
  },
);

// ─── Then: AC3 client-side-only filter contract ──────────────────────────────────

Then('the {string} level bubble is shown as active', async ({ page }: { page: Page }, value: string) => {
  await expect(bubbleLocator(page, 'level', value)).toHaveAttribute('aria-pressed', 'true');
});

/**
 * AC3 requires the bubble's click handler to be CLIENT-SIDE ONLY — no
 * `phx-click="some_event_name"` handle_event push. Phoenix.LiveView.JS commands
 * serialize the `phx-click` attribute as a JSON-encoded command list (e.g.
 * `[["attr",{...}]]`), which is syntactically nothing like a bare event-name string.
 * This is the browser-side twin of the static-HTML-contract assertion added to
 * logs_live_test.exs (see that file's comment above Test 1/2) — checking the
 * ACTUAL rendered attribute in a real browser, not just server-rendered HTML.
 */
Then(
  'the {string} level bubble is bound to a client-side command, not a server event',
  async ({ page }: { page: Page }, value: string) => {
    await assertPhxClickIsJsCommand(bubbleLocator(page, 'level', value));
  },
);

async function assertPhxClickIsJsCommand(bubble: ReturnType<typeof bubbleLocator>) {
  const phxClick = await bubble.first().getAttribute('phx-click');
  expect(phxClick, 'expected the bubble to carry a phx-click attribute').toBeTruthy();
  expect(
    phxClick!.trim().startsWith('['),
    `phx-click="${phxClick}" looks like a bare server event name (handle_event push), ` +
      'not a Phoenix.LiveView.JS command list — this violates AC3 (client-side-only filter toggle)',
  ).toBe(true);
}

// ─── Then: AC8 detail panel ───────────────────────────────────────────────────────

Then('the detail panel opens showing the chronological log thread for that request', async ({ page }: { page: Page }) => {
  if (!lastRecordedRequestId) {
    throw new Error('[logs-monitoring] no request has been recorded yet in this scenario');
  }
  const panel = page.locator(`[data-testid="detail-panel"][data-request-id="${lastRecordedRequestId}"]`);
  await expect(panel).toBeVisible({ timeout: 10_000 });
  await expect(panel.locator('[data-testid="detail-entry"]').first()).toBeVisible({ timeout: 10_000 });
});

Then('the detail panel is closed', async ({ page }: { page: Page }) => {
  if (!lastRecordedRequestId) {
    throw new Error('[logs-monitoring] no request has been recorded yet in this scenario');
  }
  await expect(
    page.locator(`[data-testid="detail-panel"][data-request-id="${lastRecordedRequestId}"]`),
  ).toBeHidden({ timeout: 10_000 });
});
