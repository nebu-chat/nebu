Feature: Admin UI — Trace Map node controls (inspector logging panel + temporary capture)
  As a Nebu platform operator managing production logs
  I want the Trace Map inspector to configure per-endpoint collection levels and retention,
    and long-polling endpoints to be off by default with a one-click 5-minute temporary capture
  So that I can tune collection policy from the map, safely experiment with high-frequency
    endpoints, and keep the map's signal-to-noise ratio high

  # Story enhanced-logging/trace-map-node-controls — ATDD, written FIRST (RED phase).
  # docs/stories/enhanced-logging/trace-map-node-controls.md
  # Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §4/§5
  # Interactive reference: trace-map-leitstand-dummy.html (same directory).
  #
  # RED-phase note (now resolved): every scenario was originally tagged
  # @pending-feature (excluded from the default run by
  # playwright.config.ts's DEFAULT_E2E_TAGS) until the dev-story landed —
  # the established un-tagging convention (logs-trace-map.feature's
  # history). The tag has been removed now that the feature is implemented.
  #
  # These are the story's AC11 Scenarios A–F. Server-side halves live in:
  #   - server/test/nebu/admin/logs_live/trace_map_node_controls_contract_test.exs
  #     (off-list, cascade set, expiry comparison, audit vocabulary)
  #   - server/test/nebu/admin/logs_live/trace_map_node_controls_test.exs
  #     (inspector markup/events, off rendering, capture lifecycle)
  #   - server/test/nebu/admin/temporary_capture_manager_test.exs (DB-backed timer API)
  #
  # INTERACTION NOTE (story-vs-dummy discrepancy, resolved for the dummy +
  # AC5/AC7): AC11's Scenario C prose sketches a two-step enable (click node
  # -> see an "Enable capture" button -> click it). The approved dummy's
  # `activate()` and AC5's own headline pin a ONE-CLICK enable on an off
  # node (a SECOND click while capturing toggles the filter, AC7). Scenario
  # C below follows the one-click contract; the inspector's own
  # "Enable for 5 min" button is exercised in Scenario E after the early
  # disable. Flagged in the ATDD handoff report for the PM to confirm.
  #
  # TIMER SEEDING (ANSWERED design question 3): scenarios that must observe
  # expiry seed an about-to-expire admin_temporary_captures row via
  # e2e/fixtures/db.ts (insertTemporaryCapture) — never a 5-minute wait, and
  # NO test-only HTTP routes. Countdown ticking is awaited via
  # waitForFunction on the countdown text, never bare sleeps.
  #
  # /health SELECTOR NOTE: a single-segment route is simultaneously its own
  # domain AND a satellite on the map (accepted leitstand design) — every
  # /health step here uses the KIND-scoped "satellite node" steps to avoid
  # Playwright strict-mode violations.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @node-controls @node-controls-config
  Scenario: A — Inspector loads with the endpoint's current logging config and keeps focus
    Given a request to "/admin/users" has been recorded
    And the logging config for "/admin/users" is min level "ERROR" with retention days "30"
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/admin/users" node on the Trace Map
    Then the inspector logging panel shows min level "ERROR" and retention "30 d"
    And the inspector scope note reads "Applies to this endpoint only"
    When the operator changes the inspector min level to "DEBUG"
    Then the stored min level for "/admin/users" is "debug"
    When the operator focuses the inspector min level select
    And a request to "/admin/users" has been recorded
    Then the inspector requests stat reaches at least 2 without a reload
    And the inspector min level select still has focus and shows "DEBUG"

  @node-controls @node-controls-config
  Scenario: B — Cascade: changing a domain node's config applies to all its satellites
    Given a request to "/admin/users" has been recorded
    And a request to "/admin/rooms" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/admin" node on the Trace Map
    Then the inspector scope note reads "Applies to all endpoints in this domain"
    When the operator changes the inspector min level to "WARN"
    Then a success message matching "Updated" and "endpoints" is shown
    And the stored min level for "/admin/users" is "warn"
    And the stored min level for "/admin/rooms" is "warn"

  @node-controls @node-controls-capture
  Scenario: C — Clicking an off endpoint enables a 5-minute temporary capture with countdown
    When the operator navigates to "/admin/logs/trace-map"
    Then the "/health" satellite node is rendered as logging-off
    When the operator clicks the "/health" satellite node on the Trace Map
    Then the "/health" satellite node shows a capture countdown
    And the "/health" capture countdown starts near five minutes
    And the Trace Map live announcer mentions "Temporary capture enabled"
    And the Trace Map live announcer mentions "/health"
    And the Trace Map live announcer mentions "5 minutes"
    And the inspector shows capture active with a "Disable now" button
    And the "/health" capture countdown decreases within 3 seconds
    # test-review m2: the keyboard path — Enter on a focused off node must
    # enable capture too (AC9; the hook's Enter/Space -> synthetic click).
    # A DIFFERENT off endpoint is used: /health is already capturing above,
    # and /admin/keepalive is key-unambiguous for the tab-to step.
    When the operator tabs to the "/admin/keepalive" node on the Trace Map
    And the operator presses Enter on the focused Trace Map node
    Then the "/admin/keepalive" satellite node shows a capture countdown
    And the Trace Map live announcer mentions "/admin/keepalive"

  @node-controls
  Scenario: C2 — An error on an off endpoint is never silenced (errors-always-persist amendment)
    # Story amendment 2026-07-07 (test-review m3): "off" silences noise,
    # never failures — an ERROR in the 60 s window renders the error state
    # on the node's dashed off stroke (red dashed + ✕ badge + count).
    When an error has been recorded for the "/health" endpoint
    And the operator navigates to "/admin/logs/trace-map"
    Then the "/health" satellite node shows an off-tier error state

  @node-controls @node-controls-capture
  Scenario: D — The countdown expires and the node auto-reverts to off
    # test-review m1: 10 s (not 4 s) — the countdown-visible assertion above
    # the revert needs headroom on a slow first paint; the revert step
    # itself already waits up to 20 s.
    Given a temporary capture for "/health" expiring in 10 seconds exists
    When the operator navigates to "/admin/logs/trace-map"
    Then the "/health" satellite node shows a capture countdown
    And within 20 seconds the "/health" satellite node reverts to logging-off
    And the Trace Map live announcer mentions "Temporary capture expired"
    And the Trace Map live announcer mentions "/health"

  @node-controls @node-controls-capture
  Scenario: E — Early disable via the inspector's Disable now button
    Given a temporary capture for "/health" expiring in 300 seconds exists
    When the operator navigates to "/admin/logs/trace-map"
    Then the "/health" satellite node shows a capture countdown
    When the operator clicks the "/health" satellite node on the Trace Map
    And the operator clicks "Disable now" in the Trace Map inspector
    Then the "/health" satellite node is rendered as logging-off
    And the Trace Map live announcer mentions "Temporary capture disabled"
    And the Trace Map live announcer mentions "/health"
    And the Trace Map inspector offers to enable capture again
    # test-review m4: the re-enable path — the inspector's Enable button
    # brings the node straight back to temp-capture.
    When the operator clicks "Enable for 5 min" in the Trace Map inspector
    Then the "/health" satellite node shows a capture countdown
    And the Trace Map live announcer mentions "Temporary capture enabled"

  @node-controls @node-controls-capture
  Scenario: F — While capturing, the filter toggle works and survives the capture's expiry
    # test-review m1: 14 s (not 8 s) — enough headroom for navigation +
    # click + chip assertions before the expiry the revert step waits on.
    Given a temporary capture for "/_matrix/client/v3/sync" expiring in 14 seconds exists
    And a request to "/_matrix/client/v3/sync" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/_matrix/client/v3/sync" satellite node on the Trace Map
    Then the "/_matrix/client/v3/sync" node shows a selection ring
    And a Trace Map filter chip for "/_matrix/client/v3/sync" is visible
    And within 20 seconds the "/_matrix/client/v3/sync" satellite node reverts to logging-off
    And a Trace Map filter chip for "/_matrix/client/v3/sync" is visible
    And the log stream below shows only entries for "/_matrix/client/v3/sync"
