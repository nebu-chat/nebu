Feature: Admin UI — Logs Monitoring View
  As a Nebu platform operator or support engineer
  I want to view operational logs in real time at /admin/logs with a Trace Map
  So that I can diagnose production issues without leaving the admin dashboard

  # enhanced-logging/trace-map-leitstand (AC13): the "Endpoints" dimension
  # was retired from /admin/logs (see server/test/nebu/admin/logs_live/
  # trace_map_retirement_test.exs) — endpoint filtering now lives on the
  # dedicated /admin/logs/trace-map Leitstand page (logs-trace-map.feature).
  # The former Endpoints bubble-section assertion and the endpoint-bubble
  # click-to-filter scenario were removed here accordingly; the
  # Levels/Sources and detail-panel scenarios below are unaffected.
  #
  # Story enhanced-logging/admin-logs-monitoring-view — ATDD, written FIRST.
  # docs/stories/enhanced-logging/admin-logs-monitoring-view.md
  #
  # GREEN PHASE: `Nebu.Admin.LogsLive`, `Nebu.Admin.LogsLive.TraceMapBubble`, and
  # `Nebu.Admin.LogsLive.DetailPanel` are implemented, `/admin/logs` is registered
  # in router.ex, and the client-side-only filter toggle (AC3) is wired via
  # `priv/static/assets/app.js`'s `wireTraceMapFilters` — the `@pending-feature`
  # tag (same convention as bootstrap_import.feature / dashboard.feature) has
  # been removed now that these scenarios are genuinely passable.
  #
  # WHY THIS FILE EXISTS: Phoenix.LiveViewTest (server/test/nebu/admin/logs_live_test.exs)
  # cannot execute real browser JS. AC3 requires the Trace Map's filter-toggle to be
  # CLIENT-SIDE ONLY (Phoenix.LiveView.JS commands, no phx-click handle_event push — see
  # the story's AC3 and the test-review's finding #3 resolution). Only a real browser can
  # prove that clicking a bubble (a) visibly filters rows and (b) does not perform a server
  # round-trip. That is the scope of this file — the ExUnit suite pins down the STATIC HTML
  # contract (data-* attributes, aria-pressed defaults); this file exercises the real
  # runtime interaction.
  #
  # Data setup: scenarios record real operational_logs entries by hitting Matrix
  # Client-Server API endpoints directly (no DB seeding, no Elixir backdoor) — mirroring
  # e2e/step-definitions/admin/stale-rooms.steps.ts's API-driven precondition style. Only
  # `level: info, source: http` entries are used because that is the only entry shape the
  # RequestLogger plug guarantees regardless of the runtime Logger level (Ecto/QueryTelemetry
  # "ecto"-source entries and warn/error entries depend on conditions — debug-level logging,
  # specific failure paths — that are not safe or deterministic to force from a black-box E2E
  # test; see logs-monitoring.steps.ts for the full rationale).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-trace-map
  Scenario: Trace Map renders with bubble sections for levels and sources
    When the operator navigates to "/admin/logs"
    Then the page shows "Trace Map"
    And the Trace Map shows a bubble section for "Levels"
    And the Trace Map shows a bubble section for "Sources"

  @ac1-trace-map @ac3-client-side-filter
  Scenario: Clicking a level bubble toggles its pressed state client-side
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs"
    And the operator clicks the "info" level bubble in the Trace Map
    Then the "info" level bubble is shown as active
    And the "info" level bubble is bound to a client-side command, not a server event

  @ac8-detail-panel
  Scenario: Clicking a request row opens the detail panel with the log thread
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs"
    And the operator clicks the request row for the last recorded request
    Then the detail panel opens showing the chronological log thread for that request
    When the operator closes the detail panel
    Then the detail panel is closed
