---
id: trace-map-zoom-pan
title: Trace Map zoom and pan (map-app-style interaction)
epic: enhanced-logging
status: ready-for-dev
security_review: not-needed
matrix: false
ui: true
created: 2026-07-09
---

# Trace Map Zoom and Pan — Map-App-Style Viewport Control

## Summary

Add Google Maps-style zoom and pan controls to the Trace Map Leitstand radial SVG view at `/admin/logs/trace-map`. Operators can zoom in/out with the mouse wheel (centered on cursor), drag-pan the map, and reset to fit the full layout. Zoom/pan state is client-owned and survives LiveView patches the same way the stream resizer does.

## User Story

As an operator monitoring a busy system via the Trace Map,
I want to zoom in and pan around the radial SVG the same way I'd interact with a browser map or a DevTools canvas,
so that I can examine individual nodes and their relationships more closely without losing the overall viewport controls and interaction patterns I already know.

## Acceptance Criteria

1. **Mouse wheel zoom** (requirement 1)
   - Scrolling the mouse wheel over the SVG map zooms in (scroll up) or out (scroll down)
   - Zoom is centered on the cursor position — the point under the cursor stays under the cursor during the zoom, not jumping to the center
   - Zoom behavior matches "standard map app" expectations (Google Maps, Leaflet, OpenStreetMap)

2. **Click-and-drag pan** (requirement 2)
   - Clicking and dragging on empty map background pans the view
   - Dragging must be distinct from existing node click/tooltip interactions: clicking a node still toggles its filter and shows/inspects the node (clicking a node does NOT start a pan)
   - Accidental drag-starts on a node do not pan the map

3. **Sensible zoom bounds** (requirement 3)
   - Minimum zoom: the entire current layout is comfortably visible (user cannot zoom out further than seeing all nodes; specific bound: zoom level ≤ 1.0 shows the full viewBox `[-780 -650 1560 1300]` without being forced to pan)
   - Maximum zoom: zoom level ≥ 4.0 to prevent the map becoming unusably cluttered; beyond 4.0 users are blocked
   - Zoom steps are smooth and granular (e.g., 0.1 per scroll event); fractional zoom levels work
   - Pan boundaries prevent the user from panning so far that the entire map exits the viewport

4. **Reset/fit-to-view control** (requirement 4)
   - A visible button labeled "Reset view" or "Fit to map" (choose clear label in implementation) that returns to the default zoom level (1.0) and pan offset (0, 0)
   - Button is accessible via keyboard (Tab, Enter/Space)
   - Button has a visible focus ring

5. **Keyboard accessibility** (requirement 5 — WCAG compliance)
   - The map container (SVG or a wrapper) is keyboard-operable without requiring a mouse
   - Zoom controls: `+`/`=` key or `PageUp` to zoom in; `-`/`_` key or `PageDown` to zoom out (zoom step e.g. ±0.1 per keystroke)
   - Pan controls: `ArrowUp`/`ArrowDown`/`ArrowLeft`/`ArrowRight` to pan in the corresponding directions (pan step e.g. ±32px per keystroke, or a sensible % of the current viewport)
   - All keyboard controls must have visible focus indication on the map container or a dedicated control (e.g., the reset button or a keyboard-help tooltip)
   - Existing Tab/Enter/Space node activation must remain unchanged: Tab between nodes works at any zoom/pan level; Enter/Space on a focused node toggles its filter and shows the tooltip exactly as today
   - The map container must announce (via aria-label or similar) that it supports keyboard navigation so screen-reader users discover the feature

6. **Client-owned zoom/pan state survives LiveView patches** (requirement 6 — critical for live UX)
   - Zoom level and pan offset are stored on the TraceMapLeitstand hook instance (exactly like `this.streamHeight` for the resizer)
   - On every `updated()` callback (after every LiveView patch — status tick, new log entry, etc.), the hook reasserts the user's last chosen zoom/pan values into the SVG viewBox or transform
   - Zoom/pan state never resets when new log lines arrive, node counts update, or other periodic server data changes
   - A unit test confirms zoom/pan state is preserved across a LiveView re-render

7. **CSP compliance** (requirement 7)
   - No inline `<script>` tags or `onclick` attributes in the HEEx template
   - All zoom/pan wiring lives in the TraceMapLeitstand hook in `server/priv/static/assets/app.js`
   - No external libraries (jQuery, three.js, etc.) added; use native SVG viewBox or CSS transform manipulation only

8. **No regressions to existing Trace Map interactions** (requirement 8)
   - Node click-to-filter, hover tooltip, Enter/Space activation all work unchanged at any zoom/pan level
   - The inspector panel, war-room banner, resizable log stream, and level filter pills all continue to work
   - Scrolling the mouse wheel over the map no longer interferes with browser scroll or page zoom (scroll events are `preventDefault()`d only while over the SVG to avoid side effects outside the map)
   - Dragging on a node (with intent to filter) does not pan the map

9. **Zoom/pan is per-session, client-side only** (requirement 9)
   - Zoom/pan state is NOT persisted to the database, localStorage, or across page reloads
   - Purely a client-side viewport transform applied on top of the server-computed node positions
   - The SVG/node positions never change; only the viewport's view of them changes
   - Closing the tab and reopening `/admin/logs/trace-map` resets zoom/pan to default

## Dev Notes

### Current state

- **SVG viewBox**: defined in `server/lib/nebu/admin/logs_live/trace_map.ex` line 918: `viewBox="-780 -650 1560 1300"`
- **SVG element**: `<svg data-testid="trace-map-svg" viewBox="-780 -650 1560 1300" preserveAspectRatio="xMidYMid meet" role="group" aria-label="Service health map" class="w-full h-full block">`
- **Hook lifecycle**: `TraceMapLeitstand` in `server/priv/static/assets/app.js` (lines 1239–1433)
  - `mounted()`: initialize all listeners, set up initial state
  - `updated()`: reassert client-owned state after every LiveView patch (see `this.streamHeight` for the pattern)
  - `destroyed()`: clean up timers and listeners
- **Client-owned state precedent**: the stream resizer's `this.streamHeight` pattern (lines 1314–1324, reasserted in `updated()` at lines 1420–1423) is the exact model to follow — store zoom/pan on `this`, reassert in `updated()`

### Geometry context

- `Nebu.Admin.TraceMapGeometry.layout/1` (server/lib/nebu/admin/trace_map_geometry.ex) computes all node positions server-side (pure Elixir, no HTML/JS knowledge — ADR-018/021)
- Node positions NEVER change; zoom/pan is a viewport layer on top
- Two implementation approaches both valid:
  1. **SVG viewBox manipulation** (recommended): modify the SVG's `viewBox` attribute dynamically (e.g., `"0 0 1560 1300"` shrinks to a portion of the current view). Native SVG event coordinates adjust automatically, so node hit-testing/click keeps working without extra transforms
  2. **CSS/SVG transform**: apply a `<g transform="scale(...) translate(...)">` wrapper around the nodes group, with manual coordinate conversion for mouse events

### Implementation notes

- **Zoom calculation**: use a zoom level scalar (e.g., 1.0 = default, 2.0 = 200%, 0.5 = 50%). With a 1560×1300 viewBox, a zoom of 1.0 shows the full map, 2.0 shows half the width/height (i.e., viewBox becomes 390×325), etc.
- **Pan calculation**: track pan offset in SVG coordinate space (e.g., `{px: 0, py: 0}` is default). When panning, adjust the viewBox's top-left corner: `viewBox = "${-780 + px} ${-650 + py} 1560 1300"`
- **Wheel event**: `event.deltaY` is positive for scroll-down (zoom out), negative for scroll-up (zoom in). Scroll events are common; debounce/smooth if performance is a concern, but 60 FPS single-step per event is usually fine
- **Pan drag**: use `pointerdown` / `pointermove` / `pointerup` (with `setPointerCapture` for smooth tracking outside the SVG bounds, as the resizer already does). Store start position and current offset; compute delta each move
- **Node click disambiguation**: on `pointerdown` over a node, flag `skipPan = true`; pan only when `pointerdown` is on empty space. Threshold: if drag distance is < 5px, treat as a click, not a pan
- **Coordinate transforms**: when implementing keyboard pan, choose a sensible step (e.g., 32px, matching the resizer's `TRACE_MAP_RESIZE_STEP`). May need conversion between viewport-relative pixels and SVG coordinate space depending on your approach
- **Accessibility**: the map container should have `tabindex="0"` if it doesn't already, and a descriptive `aria-label` that mentions keyboard support (e.g., "Service health map. Use arrow keys to pan, +/- to zoom, or R to reset.")
- **Test coverage**: E2E (Gherkin) scenarios should include:
  - Zoom in to 2.0, pan left, then verify a specific satellite node is visible and clickable
  - Keyboard zoom +/- works
  - Zoom then pan, then click a node to verify filter still fires
  - Reset button returns to default view
  - Zoom/pan state survives a stream line update (via `act do page.waitFor 500 end` to trigger a tick)

### CSP notes

- No `onclick` attributes; no inline `<script>`
- Mouse wheel / pan / keyboard listeners are added in the hook's `mounted()` with `addEventListener` (allowed by `script-src 'self'`)
- The `app.js` file is `script-src 'self'` compliant (commit-time external asset)

### Definition of Ready

- ✓ Acceptance criteria are comprehensive and unambiguous
- ✓ No ADR conflicts: ADR-021 (pure Elixir) is unaffected — this is client JS + template changes only
- ✓ Security review not needed (client-side viewport math only; no new data flows)
- ✓ Frontmatter is classify_story.py-compatible
- ✓ Dev notes provide exact file paths, current state, precedent pattern (stream resizer), and implementation guidance

---

## Questions for dev

None at creation time. This story is self-contained: extend the existing TraceMapLeitstand hook with zoom/pan, reusing the client-state-persistence pattern already established by the stream resizer.
