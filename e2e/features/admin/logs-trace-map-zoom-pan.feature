Feature: Admin UI — Trace Map zoom and pan (map-app-style viewport control)
  As an operator monitoring a busy system via the Trace Map
  I want to zoom in and pan around the radial SVG the same way I'd interact
    with a browser map or a DevTools canvas
  So that I can examine individual nodes and their relationships more
    closely without losing the overall viewport controls and interaction
    patterns I already know

  # Story enhanced-logging/trace-map-zoom-pan — ATDD, written FIRST (RED phase).
  # docs/stories/enhanced-logging/trace-map-zoom-pan.md
  # Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md
  #         (2026-07-09 addenda — current viewBox "-780 -650 1560 1300", domain_ring=300)
  #
  # RED PHASE: every scenario below is tagged (excluded from
  # the default run by playwright.config.ts's DEFAULT_E2E_TAGS) until the
  # dev-story lands — the established un-tagging convention (this epic's own
  # logs-trace-map.feature / logs-trace-map-node-controls.feature history).
  #
  # SCOPE: this file exercises the genuinely browser-only behavior
  # Phoenix.LiveViewTest cannot — real mouse wheel (page.mouse.wheel), real
  # pointer drag (page.mouse.down/move/up — the SAME mechanism this file's
  # own resizer precedent in logs-trace-map.steps.ts already uses to drive
  # pointerdown/pointermove/pointerup listeners), real keyboard, and a real
  # update-survival check. The static markup contract (new testids,
  # aria-labels, tabindex, "no phx-click/no inline JS" on the new controls,
  # and a full regression guard over every already-shipped Trace Map
  # testid) is pinned server-side in
  # server/test/nebu/admin/logs_live/trace_map_zoom_pan_test.exs — see that
  # file's moduledoc for the exact concrete testids/labels/bounds this file
  # assumes (trace-map-zoom-in/-zoom-out/-zoom-reset/-zoom-controls,
  # MIN_ZOOM=1.0, MAX_ZOOM=4.0, zoom step 0.1, keyboard pan step 32 SVG
  # units).
  #
  # NAVIGATION: no Background auto-navigation (deliberately, matching
  # logs-trace-map.feature's own convention) — scenarios that seed traffic
  # via "a request to {string} has been recorded" do so BEFORE navigating,
  # so the mount-time LogStore history read picks the seeded row up.
  #
  # ZOOM/PAN BOUNDS TESTING STRATEGY: rather than hardcoding brittle exact
  # pixel math for the pan-clamp formula (an implementation detail), the
  # "saturates at a boundary" scenarios below press the same key repeatedly
  # and assert the tracked value stops changing well before the last
  # keystroke — the true observable behavior "sensible zoom/pan bounds
  # exist" (AC3), without over-specifying the exact clamp arithmetic.
  #
  # LIVE-UPDATE-SURVIVAL TESTING STRATEGY (AC6): "a request to {string} has
  # been recorded" (defined in admin/logs-monitoring.steps.ts, reused here)
  # performs a REAL HTTP GET against the running stack while the Trace Map
  # page stays mounted — Nebu.Web.Plugs.RequestLogger broadcasts that hit on
  # the "operational_logs" PubSub topic in real time, which the already-open
  # LiveView process is subscribed to, producing a genuine LiveView patch
  # without any navigation/reload. This is the same mechanism that makes the
  # stream panel/map nodes update live without a page refresh — reusing it
  # here (rather than a bare wait on the 1s status tick, which may produce a
  # zero-diff no-op patch when nothing about the map actually changed) is
  # what makes this scenario a genuine, deterministic patch trigger. NO
  # test-only HTTP routes are added or used.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-wheel-zoom
  Scenario: Mouse wheel zoom is centered on the cursor
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator scrolls the mouse wheel up 5 times over the "/_matrix/client/versions" node on the Trace Map
    Then the Trace Map view is zoomed in
    And the "/_matrix/client/versions" node stays under the cursor after zooming

  @ac1-wheel-zoom @ac4-reset
  Scenario: On-screen zoom in/out buttons work via mouse click
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator clicks the Trace Map zoom-in button 5 times
    Then the Trace Map view is zoomed in
    When the operator clicks the Trace Map zoom-out button 5 times
    Then the Trace Map view is at its default zoom level, showing the full map without panning

  @ac1-wheel-zoom @ac3-zoom-bounds
  Scenario: Mouse wheel zoom out returns toward the default, never past it
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator scrolls the mouse wheel up 5 times over the center of the Trace Map
    And the operator scrolls the mouse wheel down 20 times over the center of the Trace Map
    Then the Trace Map view is at its default zoom level, showing the full map without panning

  # test-review follow-up: dragging at the DEFAULT zoom level (1.0) is a
  # mathematically guaranteed no-op under the pinned pan-clamp formula
  # (px ∈ [0, 1560 - 1560/zoom] collapses to [0, 0] at zoom = 1.0 — the
  # exact property that makes AC3's "minimum zoom shows the full map
  # without being forced to pan" true). Zooming in first gives the drag
  # actual pan room to move within, matching what AC2's drag-to-pan is
  # meant to exercise.
  #
  # Direction note: the default (pre-drag) viewport is anchored to the map's
  # top-left corner (px/py clamp floor is 0, never negative), and panning
  # follows the standard "grab and drag" map convention (content follows
  # the cursor — drag left/up to reveal more of the map's right/down side,
  # exactly like Google Maps/Leaflet). From that top-left-anchored default,
  # only a left-and-up drag has clamp room to move; a right-and-down drag
  # would need px/py < 0, which is an immediate no-op regardless of zoom —
  # confirmed via a live reproduction, not a guess.
  @ac2-drag-pan
  Scenario: Click-and-drag pan on empty map background
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    When the operator drags the Trace Map background from an empty area by 80 pixels left and 40 pixels up
    Then the Trace Map viewport has panned
    And no Trace Map filter chips are visible

  @ac2-drag-pan @ac8-no-regression
  Scenario: Dragging on a node does not pan the map — it still toggles the node's filter
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator drags the "/_matrix/client/versions" node on the Trace Map by 3 pixels
    Then the Trace Map viewport has not panned
    And the "/_matrix/client/versions" node shows a selection ring

  # test-review MINOR-2: the scenario above only exercises a sub-5px
  # "accidental" drag start on a node. The dev notes' contract is
  # "on pointerdown over a node, flag skipPan = true" — not a uniform
  # distance threshold — so a larger, genuinely intentional drag started ON
  # a node must equally never pan the map.
  @ac2-drag-pan @ac8-no-regression
  Scenario: A longer, intentional drag started on a node still does not pan the map
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator drags the "/_matrix/client/versions" node on the Trace Map by 60 pixels
    Then the Trace Map viewport has not panned

  @ac3-zoom-bounds
  Scenario: Zoom-in saturates at the maximum bound
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator focuses the Trace Map and presses the zoom-in key 60 times
    Then the Trace Map zoom level stops increasing before 60 keystrokes
    And the Trace Map view is zoomed in to at least 3 times the default

  # test-review MINOR-3: starting this scenario already AT the minimum
  # (default) zoom made the saturation check vacuous-pass-prone — a
  # completely non-functional zoom-out handler would also "saturate" at the
  # value it started at. Zooming in FIRST establishes a real, non-boundary
  # starting point, so the assertSaturatesWithRoomToSpare "value actually
  # changed from its pre-press baseline" check is meaningful here (a broken
  # handler would leave the view stuck zoomed in, never returning to
  # default, and the "at its default zoom level" assertion below would
  # catch that too).
  @ac3-zoom-bounds
  Scenario: Zoom-out saturates at the minimum bound — the full map, never forced to pan
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    When the operator presses the zoom-out key 60 times
    Then the Trace Map zoom level stops decreasing before 60 keystrokes
    And the Trace Map view is at its default zoom level, showing the full map without panning

  @ac3-zoom-bounds
  Scenario: Pan saturates at a boundary once zoomed in
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    When the operator presses the pan-right key 60 times
    Then the Trace Map pan offset stops increasing before 60 keystrokes
    And the "nebu" node on the Trace Map remains at least partially within the visible viewport

  @ac4-reset
  Scenario: Reset view control returns to the default zoom and pan, keyboard operable
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses the pan-right key 10 times
    When the operator clicks the Trace Map "Reset view" button
    Then the Trace Map view is at its default zoom level, showing the full map without panning
    When the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses Tab until the Trace Map "Reset view" button is focused
    And the operator presses Enter on the focused Trace Map control
    Then the Trace Map view is at its default zoom level, showing the full map without panning
    And the focused Trace Map control shows a visible focus ring

  # UX gate finding 1: the SVG map surface itself (tabindex="0") had no
  # explicit `:focus-visible` CSS of its own — only the Reset button (and
  # other controls) were ever exercised by the "shows a visible focus ring"
  # check above. This scenario exercises the SAME generic assertion against
  # the map surface directly, closing that gap.
  @ac5-keyboard
  Scenario: The map surface itself shows a visible focus ring when focused
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator focuses the Trace Map
    Then the focused Trace Map control shows a visible focus ring

  # UX gate finding 2: drag-to-pan is pointer-only, and the SVG's own
  # keydown arrow-key handler is not a reliable screen-reader path
  # (role="group" + tabindex="0" does not dependably put NVDA/JAWS into
  # "focus mode"). These on-screen Pan Up/Down/Left/Right buttons are a
  # discoverable, dependable AT-accessible alternative — this scenario
  # proves the button path reaches the SAME pan mechanism the keyboard
  # arrow keys already use (right then left round-trips back to the
  # pre-pan x position, mirroring "Keyboard zoom and pan controls" above).
  @ac5-keyboard
  Scenario: On-screen pan buttons work via mouse click
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    When the operator clicks the Trace Map pan-right button 3 times
    Then the Trace Map viewport has panned
    When the operator clicks the Trace Map pan-left button 3 times
    Then the Trace Map view is back at its pre-pan position

  @ac5-keyboard
  Scenario: Keyboard zoom and pan controls
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator focuses the Trace Map and presses the zoom-in key 5 times
    Then the Trace Map view is zoomed in
    When the operator presses the zoom-out key 5 times
    Then the Trace Map view is at its default zoom level, showing the full map without panning
    When the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses the pan-right key 3 times
    Then the Trace Map viewport has panned
    When the operator presses the pan-left key 3 times
    Then the Trace Map view is back at its pre-pan position

  # test-review MINOR-1: AC5 specifies "+"/"=" or PageUp to zoom in, "-"/"_"
  # or PageDown to zoom out — the scenario above only ever presses the bare
  # "+"/"-". An implementation that wires only "+"/"-" (dropping the
  # alternates) would pass every other scenario in this file while
  # violating the letter of AC5; this scenario exercises all four
  # alternates explicitly so that gap fails as it should.
  @ac5-keyboard
  Scenario: Alternate keyboard zoom key bindings are also wired
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator focuses the Trace Map
    And the operator presses "=" to zoom in 5 times
    Then the Trace Map view is zoomed in
    When the operator presses "PageDown" to zoom out 5 times
    Then the Trace Map view is at its default zoom level, showing the full map without panning
    When the operator presses "PageUp" to zoom in 5 times
    Then the Trace Map view is zoomed in
    When the operator presses "_" to zoom out 5 times
    Then the Trace Map view is at its default zoom level, showing the full map without panning

  @ac5-keyboard @ac8-no-regression
  Scenario: Existing Tab/Enter/Space node activation is unaffected by zoom/pan
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses the pan-right key 5 times
    And the operator presses Tab until a Trace Map node is focused
    Then the "nebu" node on the Trace Map has focus
    When the operator presses Tab
    Then the focused Trace Map node is a domain node
    When the operator presses Enter on the focused Trace Map node
    Then the focused domain node has aria-pressed "true"
    And a Trace Map filter chip is visible

  @ac6-patch-survival
  Scenario: Zoom and pan state survives a live log update (LiveView patch)
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses the pan-right key 5 times
    And the operator remembers the current Trace Map viewport
    And a request to "/_matrix/client/v3/whoami" has been recorded
    Then a Trace Map stream line for "/_matrix/client/v3/whoami" appears
    And the Trace Map viewport is unchanged from the remembered viewport

  @ac7-csp
  Scenario: Mouse wheel over the map zooms it and never scrolls the page
    Given the operator navigates to "/admin/logs/trace-map"
    When the operator scrolls the mouse wheel up 5 times over the center of the Trace Map
    Then the page has not scrolled

  @ac8-no-regression
  # test-review follow-up: TraceMapGeometry's radial layout angle for any
  # one satellite depends on `endpoint_order`, which accumulates across the
  # WHOLE E2E session (every scenario's seeded traffic, run in whatever
  # order the suite happens to execute) — so a large, fixed zoom+pan tuned
  # against one specific satellite's position is fragile (confirmed: this
  # scenario failed two different ways across two runs, once via the
  # right-hand inspector panel intercepting the click and once via the
  # on-screen zoom-controls overlay, exactly because the target node landed
  # in a different place each time). A much MORE MODEST zoom+pan still
  # genuinely exercises "click-to-filter works at a non-default zoom/pan"
  # (AC8) while keeping the overwhelming majority of the default viewBox
  # (including any plausible satellite position) still on-screen — this is
  # a deliberately conservative amount, not a no-op (contrast with the
  # @ac3-zoom-bounds scenarios above, which are the dedicated place for
  # stress-testing zoom/pan AT its extremes).
  Scenario: Clicking a node still toggles the stream filter while zoomed and panned
    Given a request to "/_matrix/client/versions" has been recorded
    When the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 2 times
    And the operator presses the pan-right key 2 times
    And the operator clicks the "/_matrix/client/versions" node on the Trace Map
    Then the "/_matrix/client/versions" node shows a selection ring
    And a Trace Map filter chip for "/_matrix/client/versions" is visible

  @ac9-not-persisted
  Scenario: Zoom and pan reset on page reload — never persisted
    Given the operator navigates to "/admin/logs/trace-map"
    And the operator focuses the Trace Map and presses the zoom-in key 10 times
    And the operator presses the pan-right key 5 times
    When the operator reloads the Trace Map page
    Then the Trace Map view is at its default zoom level, showing the full map without panning
