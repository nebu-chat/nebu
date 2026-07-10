Feature: Admin UI — Trace Map Leitstand (dedicated radial health map)
  As a Nebu platform operator managing production logs
  I want a dedicated, full-page radial health map at /admin/logs/trace-map
  So that I can rapidly diagnose "where is the system red?" and filter the live stream
    by clicking nodes, with keyboard and mouse, in an accessible way

  # Story enhanced-logging/trace-map-leitstand — ATDD, written FIRST (RED phase).
  # docs/stories/enhanced-logging/trace-map-leitstand.md
  # Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md
  # Interactive reference: trace-map-leitstand-dummy.html (same directory).
  #
  # GREEN PHASE: `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.TraceMapGeometry`,
  # `Nebu.Admin.LogsLive.TraceMapStatus` and the real `/admin/logs/trace-map`
  # route are implemented (dev-story cycle 0) — the `@pending-feature` tags
  # have been removed, following this project's established un-tagging
  # convention (logs-monitoring.feature's own history).
  #
  # Scenario 9 note (resizer keyboard contract, corrected 2026-07-09 — the
  # design owner found the drag direction backwards live): this file pins
  # ArrowUp = grow stream / ArrowDown = shrink stream / Home = minimize
  # stream / End = maximize stream (drag UP grows the stream, matching the
  # standard split-pane convention — moving the divider up gives the panel
  # below it, the stream, more room). The story's AC9 prose says the
  # opposite for Home/End ("Home key maximizes stream; End key minimizes
  # stream") — the implementation follows THIS file (the executable spec,
  # staged by ATDD and reviewed by test-review); flagged in the story's Dev
  # Agent Record for the PM to confirm.
  #
  # Server-side/component-level coverage of this story's ACs lives in:
  #   - server/test/nebu/admin/trace_map_geometry_test.exs (AC2 geometry)
  #   - server/test/nebu/admin/logs_live/trace_map_status_test.exs (AC3 status model)
  #   - server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs (AC1/AC4-AC11/AC14)
  #   - server/test/nebu/admin/logs_live/trace_map_retirement_test.exs (AC13)
  # This file covers the genuinely browser-only half Phoenix.LiveViewTest cannot
  # exercise: real keyboard focus movement, hover tooltips, pointer drag on the
  # resizer, and real page-URL/reload round trips.
  #
  # WARN/ERROR SEEDING (test-review MAJOR-1 resolution + story amendment
  # "AC12 log injection"): Scenario 2 needs genuine WARN/ERROR-level
  # operational_logs entries, which real black-box HTTP traffic cannot
  # deterministically produce (RequestLogger only ever logs at INFO — see
  # logs-monitoring.feature's own header comment). "a warning/error has been
  # recorded for the {string} endpoint" (logs-trace-map.steps.ts) seeds the
  # row via a DIRECT DB INSERT (e2e/fixtures/db.ts, following
  # server/test/nebu/admin/logs_live_test.exs's AC12 raw-SQL-seed precedent).
  # NO test-only HTTP routes exist or may be added in server code. Scenarios
  # navigate/reload after seeding so the page's mount-time LogStore history
  # read picks the rows up.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-route
  Scenario: Map renders with domains and satellites
    Given a request to "/_matrix/client/versions" has been recorded
    And a request to "/_matrix/client/v3/login" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    Then the page shows "Trace Map"
    And I see the "nebu" center node on the Trace Map
    And I see a domain node for "/_matrix/client" on the Trace Map
    And I see a satellite node for "/_matrix/client/versions" on the Trace Map

  # enhanced-logging/trace-map-node-controls: `/_matrix/client/v3/sync` is
  # now one of the off-by-default long-polling endpoints (AC4) — a plain
  # WARNING with no active capture is correctly suppressed by that story's
  # own contract, breaking this scenario's original WARN probe. Swapped to
  # `/_matrix/client/v3/whoami`, a plain (non-off-list) route under the same
  # `/_matrix/client` domain, preserving this scenario's original intent
  # (status-color propagation) unchanged.
  @ac3-status @ac4-visual-states
  Scenario: Status colors reflect log entries
    Given a warning has been recorded for the "/_matrix/client/v3/whoami" endpoint
    When the operator navigates to "/admin/logs/trace-map"
    Then the "/_matrix/client/v3/whoami" node shows warn status
    And the "/_matrix/client" domain node shows warn status
    And the "nebu" center node shows warn status
    When an error has been recorded for the "/_matrix/client/v3/whoami" endpoint
    And the operator reloads the Trace Map page
    Then the "/_matrix/client/v3/whoami" node shows error status
    And the "/_matrix/client/v3/whoami" node pulses (no prefers-reduced-motion)
    When the operator emulates reduced motion
    Then the "/_matrix/client/v3/whoami" node does not pulse (reduced motion)

  @ac5-filtering
  Scenario: Clicking a node toggles stream filter selection
    Given a request to "/_matrix/client/versions" has been recorded
    And a request to "/_matrix/client/v3/login" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/_matrix/client/versions" node on the Trace Map
    Then the "/_matrix/client/versions" node shows a selection ring
    And the "/_matrix/client/versions" node has aria-pressed "true"
    And a Trace Map filter chip for "/_matrix/client/versions" is visible
    And the log stream below shows only entries for "/_matrix/client/versions"
    When the operator clicks the "/_matrix/client/v3/login" node on the Trace Map
    Then the "/_matrix/client/versions" node shows a selection ring
    And the "/_matrix/client/v3/login" node shows a selection ring
    And two Trace Map filter chips are visible
    And the log stream below shows entries for both "/_matrix/client/versions" and "/_matrix/client/v3/login"
    When the operator clicks the "nebu" center node on the Trace Map
    Then no Trace Map node shows a selection ring
    And no Trace Map filter chips are visible

  @ac10-keyboard-nav
  Scenario: Keyboard navigation (Tab, Enter, Space)
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    # Test-review MAJOR-2 / story amendment "AC12 Scenario 4 wording": the
    # sidebar chrome precedes the main content in document order, so a single
    # Tab never lands on nebu — sequential keyboard navigation reaches it.
    And the operator presses Tab until a Trace Map node is focused
    Then the "nebu" node on the Trace Map has focus
    And the focused Trace Map node shows a visible focus ring
    When the operator presses Tab
    Then the focused Trace Map node is a domain node
    When the operator presses Enter on the focused Trace Map node
    Then the focused domain node has aria-pressed "true"
    And a Trace Map filter chip is visible
    When the operator presses Space on the focused Trace Map node
    Then the focused domain node has aria-pressed "false"
    And no Trace Map filter chips are visible

  @ac7-tooltip
  Scenario: Tooltip on hover and focus
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator hovers over the "/_matrix/client/versions" node on the Trace Map
    Then a Trace Map tooltip is visible showing name, route, status, and counts
    When the operator moves the mouse away from the Trace Map
    Then the Trace Map tooltip is hidden
    When the operator tabs to the "/_matrix/client/versions" node on the Trace Map
    Then a Trace Map tooltip is visible showing name, route, status, and counts
    When the operator presses Escape
    Then the Trace Map tooltip is hidden

  @ac8-inspector
  Scenario: Inspector panel shows live stats for selected node
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/_matrix/client/versions" node on the Trace Map
    Then the Trace Map inspector shows the name "versions"
    And the Trace Map inspector shows the route "/_matrix/client/versions"
    And the Trace Map inspector shows a status pill
    And the Trace Map inspector shows at least 1 recent event

  # enhanced-logging/war-room-dedicated-page (amendment 2): the embedded
  # War Room start form on /admin/logs was RETIRED once the dedicated
  # /admin/logs/war-room page shipped — starting a session for this probe
  # now goes through that page instead (same reused
  # war-room.steps.ts step definitions: the dedicated page renders the same
  # war-room-start-form/stop-war-room-button contract).
  @ac6-war-room-banner
  Scenario: War-room banner appears when session is active
    When the operator navigates to "/admin/logs/war-room"
    And the operator starts a War Room with reason "trace-map leitstand e2e probe" and scope "all"
    And the operator navigates to "/admin/logs/trace-map"
    Then the Trace Map war-room banner is visible
    And the Trace Map war-room banner shows the recording dot
    And the Trace Map war-room banner mentions "trace-map leitstand e2e probe"
    And the Trace Map war-room banner shows an elapsed time
    When the operator clicks "Open War Room" on the Trace Map war-room banner
    Then the operator is on "/admin/logs/war-room"

  @ac9-level-filter-shortcut
  Scenario: Level filter leitstand shortcut
    When the operator navigates to "/admin/logs/trace-map"
    Then all Trace Map level filter pills are active
    When the operator clicks the "INFO" Trace Map level filter pill
    Then only the "INFO" Trace Map level filter pill is active
    When the operator clicks the "INFO" Trace Map level filter pill
    Then all Trace Map level filter pills are active

  @ac9-resizer
  Scenario: Resizable stream panel (drag handle)
    When the operator navigates to "/admin/logs/trace-map"
    And the operator drags the Trace Map stream resizer up by 60 pixels
    Then the Trace Map stream panel is taller than its default height
    When the operator drags the Trace Map stream resizer down by 60 pixels
    Then the Trace Map stream panel is shorter than it was
    When the operator double-clicks the Trace Map stream resizer
    Then the Trace Map stream panel is at its default height of 218 pixels
    When the operator focuses the Trace Map stream resizer and presses ArrowUp
    Then the Trace Map stream panel height increases by 32 pixels
    When the operator presses ArrowDown
    Then the Trace Map stream panel height decreases by 32 pixels
    When the operator presses Home
    Then the Trace Map stream panel is minimized
    When the operator presses End
    Then the Trace Map stream panel is maximized

  @ac5-bookmarkable-urls
  Scenario: Bookmarkable URLs with filter state
    Given a request to "/_matrix/client/versions" has been recorded
    And a request to "/_matrix/client/v3/login" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator clicks the "/_matrix/client/versions" node on the Trace Map
    And the operator clicks the "/_matrix/client/v3/login" node on the Trace Map
    Then the page URL contains the query parameter "endpoint%5B%5D=%2F_matrix%2Fclient%2Fversions"
    When the operator reloads the Trace Map page
    Then the "/_matrix/client/versions" node shows a selection ring
    And the "/_matrix/client/v3/login" node shows a selection ring
    And the log stream below shows entries for both "/_matrix/client/versions" and "/_matrix/client/v3/login"
