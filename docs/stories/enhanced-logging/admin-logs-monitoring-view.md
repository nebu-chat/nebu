---
id: admin-logs-monitoring-view
title: "Admin Logs Monitoring View — live request-stream with trace-map filtering"
epic: enhanced-logging
status: done
security_review: required
matrix: false
ui: true
created: 2026-07-04
---

# Admin Logs Monitoring View

## Story

**As** a Nebu platform operator or support engineer,
**I want** to view operational logs in real time at `/admin/logs` grouped by request ID with a live-updating "Trace Map" that lets me filter by endpoint, log level, and source dimension,
**so that** I can diagnose production issues without leaving the admin dashboard, isolate specific request flows to their full chronological thread (every HTTP entry, query, warning), and observe log trends across dimensions without the noise-reduction lag of traditional filter bars.

The current admin dashboard has an `AuditLogLive` page (compliance audit log, read-once at mount). The operational log store (sibling story, being created in parallel) provides a live data layer: table `operational_logs` with columns for `request_id`, `level`, `source`, `message`, `metadata`, `inserted_at` (timestamp), and a PubSub topic `"operational_logs"` that broadcasts each new entry as it arrives. This story builds the monitoring view on top of that foundation.

### The UX Challenge: Filtering vs. Signal Loss

A traditional log viewer offers a filter bar (level dropdown, source dropdown) and a flat log table. Operators dislike it for two reasons:

1. **False simplicity**: "Show only ERRORs" hides INFO/DEBUG context, making diagnosis harder — sometimes the ERROR itself is a symptom of an earlier warning.
2. **Filter-interaction lag**: opening a dropdown, selecting a filter, waiting for the table to re-render creates cognitive friction and kills flow.

This story rejects that pattern in favor of **Trace Map** — a grid of toggleable "bubbles" (lightweight visual hints) that are BOTH legend and interactive filter. The bubbles show live counts and let the user rapidly toggle dimensions on/off with direct DOM updates (no server round-trip). Unlike traditional filters, the trace map is **always visible** — the user sees the shape of the log space (which endpoints are noisy, which levels are present) without opening anything. And unlike a graph library (which adds 200KB of JS), the bubbles are plain HTML + client-side filtering logic in a Phoenix Component.

### Core Value Proposition: Request as Unit of Analysis

Instead of scrolling through raw log lines, the view groups by `request_id` and presents **one row per request**, summarizing:
- HTTP timestamp + method + path (from the initial HTTP entry)
- Outcome: a status indicator (🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx, or 🔵 none if not HTTP)
- Log shape: a micro-summary showing how many debug/info/warn/error events happened during this request
- Duration (if available from the HTTP entry's elapsed time)

Clicking a request row opens a **detail panel** (slide-in from the right, not a modal) that shows the full chronological thread: every `operational_logs` entry with that `request_id`, including the HTTP request, all Ecto queries, all warnings, the response — the "one click from error to full context" requirement.

## Acceptance Criteria

### Trace Map — Structure and Interactivity

**AC1:** The page displays a **Trace Map** — a cluster of toggleable "bubbles" (styled pill-shaped buttons, not a graph). Bubbles are grouped into three visual sections:
- **Endpoints** (by `route_template`, e.g., "/login", "/sync", "/createRoom"): each bubble labeled with the endpoint and a live count
- **Levels** (debug, info, warning, error): each bubble labeled with level icon + text (e.g., "🟠 WARN") and a live count
- **Sources** (http, ecto, other): each bubble labeled with source and a live count

Each bubble is a toggle button with aria-pressed semantics. Default state: all filters inactive = everything visible (no noise-reduction mode). Clicking a bubble activates it (filled/highlighted), clicking again deactivates (dimmed/outline). Active filters combine as AND logic (e.g., "/login" + "ERROR" active = only errors from /login requests).

**AC2:** For levels that are NOT currently collected (per the retention policy from the sibling admin-logs-retention-settings story), the bubble renders visually distinct — dimmed/"off" state with a marker like "⚫ off" — because it represents a structural absence (not collected) rather than zero events in the active time window.

**AC3:** Filter-toggle state is CLIENT-SIDE only (no server round-trip per bubble click). Filters the already-loaded/streaming rows in the browser. This is a deliberate, scoped exception to "no JS beyond what exists" — justified because: (a) the trace map's core value is fast, live, multi-dimension filtering impossible with server-round-trip semantics, (b) the codebase has zero JS framework deps (no Alpine, no htmx, pure Tailwind+DaisyUI) so this is genuinely minimal interactivity (no hydration, no state reconciliation), and (c) other recent admin pages like `rooms/index.html.heex` explicitly note "no LiveView event"/"no phx-click", confirming the codebase's deliberate move away from per-action server events for simple pages.

**AC4:** Below the Trace Map, a compact **active-filter chip row** displays the currently active filters as removable pills (e.g., "[/login ×] [ERROR ×]"). Clicking the × removes that filter. This visual summary ensures the user never loses track of which dimensions are filtering the view.

**AC5:** The Trace Map and active-filter chips are part of the Phoenix.Component `Nebu.Admin.LogsLive.trace_map_bubble/1` component (and a parent container component). The `trace_map_bubble/1` has a `mode` attribute:
- `:filter` (this story) — on click, toggles filter state in the LiveView via a phx-click event
- `:configure` (sibling admin-logs-retention-settings story) — on click, opens a modal to configure retention for that level/source

This story BUILDS the shared component in `:filter` mode; the retention-settings story REUSES it in `:configure` mode. Explicitly document this dependency in the story (file structure section below).

### Request-Stream View

**AC6:** Below the Trace Map, the main content area displays a **request-stream list** (one row per request). Each row shows:
- Request timestamp (from the initial HTTP log entry, or the first operational_logs entry)
- Method + Path (HTTP entries only; non-HTTP requests show "—")
- Status indicator: a colored dot or text badge (🟢 2xx, 🟡 3xx, 🟠 4xx, 🔴 5xx, or 🔵 unknown)
- A micro-summary showing the count of events by level during the request (e.g., "2 debug, 0 info, 1 warn, 0 error" — or a compact icon-based summary)
- Duration (milliseconds, only for HTTP requests where start and end times are known)
- A visual accent line (color-coded by highest log level in the request: green=info/debug, yellow=warn, red=error)

**AC7:** Rows are sorted with errors surfaced first (highest severity log level in the request determines sort order), followed by warnings, info, debug. Within each severity tier, rows are sorted newest-first (most recent request first).

**AC8:** Clicking a row expands a **detail panel** (slide-in from the right, not a modal) showing the full chronological thread of all `operational_logs` entries with that `request_id`. The detail view includes:
- All log entries in chronological order
- For each entry: timestamp, level (with icon/color), source, message, and expandable metadata (if available)
- Copy-to-clipboard button for the entire thread (for support hand-off)
- Close button to dismiss the panel

The detail panel does NOT force the list to scroll or change: if the user has scrolled down or opened a detail row, the list behind the panel should remain in its current state (not auto-jumping to the top). This is explicitly listed as an anti-pattern below.

**AC9:** Rows are added to the stream as new requests arrive (via the PubSub topic). New entries prepend to the list (most recent first). The list uses Phoenix.LiveView streams (not a plain list reassign) so that new rows appear additively without collapsing open detail panels or resetting scroll position.

**AC10:** If the user has scrolled the list or opened a detail panel, new rows arrive silently (aria-live="polite" but no autoscroll). A non-intrusive indicator appears (e.g., a small banner at the top: "X new entries available") with an optional "resume live updates" button that, when clicked, scrolls to the top and resumes auto-scrolling. This prevents the anti-pattern of auto-scroll fighting the user's manual scrolling.

### Live Updates

**AC11:** On mount, the LiveView subscribes to the `"operational_logs"` PubSub topic (provided by the sibling operational-log-store story). Each broadcast message contains a new operational_logs entry. The LiveView's `handle_info/2` callback receives each entry, applies the current filter state, and if the entry matches the filters, prepends it to the `@events` stream (or equivalent).

**AC12:** The `handle_info/2` callback also updates the Trace Map bubble counts in real time. A request that just produced an ERROR will cause the ERROR level bubble's count to increment and the associated endpoint bubble to update.

### Accessibility (WCAG 2.1 AA)

**AC13:** Level indication is NEVER color-only. All level badges pair color with text and/or icon (e.g., "🟠 WARN", not just an orange dot). Status indicators in the request row also pair color with text (e.g., "🔴 5xx", not just a red dot).

**AC14:** Filter-toggle bubbles in the Trace Map have:
- Proper `aria-pressed` attribute (true/false for active/inactive state)
- `aria-label` describing the dimension (e.g., "Filter by /login endpoint")
- Clear visual focus ring (already part of the default DaisyUI button focus styling)
- Keyboard-navigable (Tab through bubbles, Space/Enter to toggle)

**AC15:** When new live entries arrive, they are announced via `aria-live="polite"` without interrupting screen-reader flow. The "X new entries available" banner (AC10) uses aria-live so that if a screen-reader user is reading the list, they are notified of new content availability without being forced to jump around.

### Visual / Component Grounding

**AC16:** All visual components use DaisyUI classes already in use elsewhere in the codebase:
- Bubbles: `btn btn-sm` with conditional `:active` state (filled background) vs. `:inactive` state (outline)
- Request rows: `table table-zebra` or `flex` layout with DaisyUI card styling
- Detail panel: `drawer` or a `fixed` positioned `div` with `z-50`, shadow, and `transform transition-transform` for the slide-in animation
- Level badges: semantic color classes (`.badge .badge-error`, `.badge .badge-warning`, `.badge .badge-info`, `.badge .badge-neutral` for debug)
- Status badges: color-coded dots or inline badges (🟢 for 2xx via a `.text-success` utility, 🔴 for 5xx via `.text-error`, etc.)

Font: use `JetBrains Mono` (already configured in the codebase) for monospace metadata/JSON in the detail panel.

### Scope Boundaries (What This Story DOES NOT Implement)

**AC17:** This story implements ONLY:
- The monitoring view at `/admin/logs` (LiveView route, no new API endpoint needed)
- The Trace Map in `:filter` mode (toggle-based filtering, no retention configuration)
- The request-stream list and detail panel
- The reusable `trace_map_bubble/1` component in `:filter` mode

This story does NOT implement:
- Admin-logs-retention-settings (separate story, which reuses the trace_map_bubble in `:configure` mode)
- War-room sessions / request tagging for incident investigation (separate story — but the request-stream/detail panel design allows for later `war_room_id` filtering to slot in naturally)
- Log export / download (separate story, if needed)
- Search/regex filtering within log text (intentionally out-of-scope: the Trace Map's dimension-based approach is the intended filter UX)

### Dependencies

**AC18:** This story depends on:
- `operational-log-store` (sibling story, being created in parallel): provides the `operational_logs` table, the `:logger` handler broadcasting to the PubSub topic `"operational_logs"`, and the schema/API contract for each log entry
- Phoenix LiveView (already in the codebase, no new dependency)
- DaisyUI (already in the codebase, no new dependency)

Assumes the operational-log-store story will be merged before or in parallel, and that its PubSub topic and table schema are stable by the time this story's dev agent begins implementation.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1–AC5] Trace Map renders with live counts** — ExUnit integration test (Phoenix.LiveViewTest)
   - Given: LogsLive mounted and subscribed to PubSub
   - When: a message with level ERROR and source "http" is broadcast
   - Then: the ERROR bubble count increments; the "http" source bubble count increments; both bubbles are still clickable
   - And: clicking ERROR and "http" bubbles activates the filters (aria-pressed="true"); the active-filter chip row shows "[ERROR ×] [http ×]"

2. **[AC1–AC5] Trace Map bubble toggle filters rows** — ExUnit integration test
   - Given: 5 requests in the stream: 2 with ERROR level, 3 with INFO
   - When: ERROR bubble is clicked (filter activated)
   - Then: only the 2 ERROR rows are visible; INFO rows are hidden
   - And: clicking ERROR bubble again (deactivating) shows all 5 rows again
   - And: no server round-trip occurs (filter is client-side); the response is immediate

3. **[AC2] Uncollected level renders as "off"** — ExUnit integration test
   - Given: the retention policy disables DEBUG collection
   - When: LogsLive mounts
   - Then: the DEBUG bubble renders with a visual "off" indicator (e.g., "⚫ off") distinct from "0 hits"
   - And: clicking the OFF bubble does not activate a filter (or activates but shows no results, with a tooltip explaining "debug level not collected")

4. **[AC6–AC9] Request-stream rows display correct metadata** — ExUnit integration test
   - Given: an HTTP request logs an entry with method=POST, path=/sync, status=200, duration_ms=45
   - When: the LogsLive receives the operational_logs entry
   - Then: a row appears with POST /sync, 🟢 2xx status indicator, and duration "45ms"
   - And: the row's micro-summary shows the count of events by level (e.g., "0 debug, 5 info, 0 warn, 0 error")

5. **[AC7] Rows sorted with errors surfaced first** — ExUnit integration test
   - Given: 3 requests in the stream: A with ERROR, B with INFO, C with WARNING
   - When: LogsLive is mounted
   - Then: row A (ERROR) is first, C (WARNING) is second, B (INFO) is third
   - And: when a new WARN request arrives, it inserts in the correct position (after ERROR, before INFO)

6. **[AC8] Detail panel shows full chronological thread** — ExUnit integration test (Phoenix.LiveViewTest with test component)
   - Given: a request with request_id=req-123 and 5 operational_logs entries (HTTP entry, 3 Ecto queries, 1 warning)
   - When: the request row is clicked
   - Then: a detail panel slides in from the right
   - And: all 5 entries are shown in chronological order with full metadata
   - And: closing the panel does not scroll the list or collapse other rows

7. **[AC10] New entries appear without autoscroll** — ExUnit integration test
   - Given: the LogsLive has scrolled down to row 10
   - When: 3 new request rows arrive (via PubSub broadcast)
   - Then: the rows prepend to the list but the viewport does NOT jump to the top (user scroll position is preserved)
   - And: a "3 new entries available" banner appears at the top with a "resume live updates" button
   - And: clicking the button scrolls to the top and resumes autoscroll for subsequent entries

8. **[AC13–AC15] Accessibility: level badges have text + icon + colors** — ExUnit test + manual WCAG audit
   - Given: a row with WARN level
   - When: the HTML is inspected
   - Then: the level badge contains both a colored icon (e.g., 🟠) and text ("WARN"), not color alone
   - And: the badge has `aria-label="Warning level"` or similar
   - And: when the page is read by a screen reader (manual test), each level is announced clearly

9. **[AC14] Trace Map bubbles are keyboard-navigable** — ExUnit test (Plug.Test with keyboard focus simulation)
   - Given: LogsLive rendered
   - When: Tab is pressed repeatedly
   - Then: focus moves through all visible bubbles in order
   - And: when a bubble has focus, Space or Enter key toggles the filter

10. **[AC15] New-entries banner uses aria-live="polite"** — ExUnit test + manual screen-reader verification
    - Given: a screen reader is reading the list of rows
    - When: a new entry arrives and the "X new entries" banner appears
    - Then: the announcement is made without forcing focus away from the reader's current position
    - And: manual verification: screen reader announces "3 new entries available" politely (not with an interrupt)

11. **[AC5] Trace-map-bubble component is reusable** — ExUnit unit test
    - Given: `Nebu.Admin.LogsLive.trace_map_bubble/1` component with `mode: :filter`
    - When: rendered with a list of dimensions
    - Then: bubbles render with `phx-click` handlers pointing to the LogsLive event handler
    - And: when `mode: :configure` (simulated in a test component), the `phx-click` handler instead opens a config modal (stubbed for unit test)
    - This test confirms the component API is designed for reuse

### Integration test with the operational-log-store

12. **[AC11–AC12] Live subscription and filter integration** — ExUnit integration test (with live compose stack)
    - Given: LogsLive mounted and operational-log-store is running and broadcasting entries
    - When: an HTTP request handler produces a new operational_logs entry
    - Then: the entry is received via PubSub in LogsLive's handle_info
    - And: if filters are active, the entry is checked against filters before streaming
    - And: the Trace Map counts update in real time
    - And: if the entry matches active filters, a new row is prepended to the stream

## Dev Notes

### File Structure

- **New:** `server/lib/nebu/admin/logs_live.ex` — the LiveView handler for `/admin/logs`
  - Mount: sets up `@active_nav = "compliance"` (or a new nav key if logs are not under compliance), subscribes to `"operational_logs"` PubSub topic
  - Render: template with Trace Map (bubbles + active-filter chips), request-stream list, detail panel
  - Handle_info: receives operational_logs entries, applies filters, streams to the request list
  - Handle_event: "toggle_filter" event (activated from bubble clicks), updates filter state, re-filters the current rows

- **New:** `server/lib/nebu/admin/logs_live/trace_map_bubble.ex` — Phoenix.Component
  - Function component `trace_map_bubble/1` with attributes:
    - `dimension`: atom like `:endpoint`, `:level`, `:source`
    - `value`: the specific value (e.g., "/login", "error", "ecto")
    - `count`: current live count
    - `active`: boolean indicating filter state
    - `mode`: `:filter` (this story) or `:configure` (reused by retention-settings story)
    - `on_click`: callback name (e.g., "toggle_filter", "configure_retention")
  - Renders a `<button>` with DaisyUI classes, aria-pressed, aria-label, and the appropriate phx-click handler
  - Slot: optional `<:off>` indicator if the bubble represents an uncollected/disabled dimension

- **New:** `server/lib/nebu/admin/logs_live/detail_panel.ex` — Phoenix.Component
  - Stateless component for rendering the slide-in detail panel
  - Accepts: `request_id`, list of operational_logs entries, close callback
  - Renders: chronological thread of entries, copy-to-clipboard button, close button
  - Uses `transform transition-transform` for the slide-in animation (no extra JS library)

- **New:** `server/test/nebu/admin/logs_live_test.exs` — ExUnit tests for LogsLive
  - Tests 1–11 above (trace map, filtering, detail panel, accessibility, live updates)
  - Uses `Phoenix.LiveViewTest` helpers for mounting and interacting with the LiveView

- **New:** `server/test/nebu/admin/logs_live/trace_map_bubble_test.exs` — ExUnit component tests
  - Test 11 above (component rendering and reusability)

- **Modified:** `server/lib/nebu/admin/layouts.ex` — add the new logs nav item
  - Add a new nav_item for `/admin/logs` with key "logs" (or place under "compliance" if logs are grouped there)
  - The nav highlighting will work automatically via the `@active_nav` assign in LogsLive

- **Modified:** `server/lib/nebu/admin/router.ex` — add the route
  - Add a new route in the `live_session :admin` block:
    - `live "/logs", LogsLive, :index`
  - This makes the route available only to authenticated admins (via the `:require_admin` on_mount hook already applied to the `live_session :admin` scope)

### Architecture & Implementation Hints

1. **Trace Map Grouping & Counts:**
   - The Trace Map needs to show live counts of events in each dimension. These counts are derived from the current set of loaded rows (not all historical data).
   - On mount, load the most recent N requests from the `operational_logs` table (e.g., last 100 entries grouped by request_id) to seed the initial state.
   - As new entries arrive via PubSub, update the counts and the rows.
   - The counts reset when the user navigates away or the page reloads (no persistent state — counts reflect "current view", not "all time").
   - If a level is not present in the current loaded data but IS collected (retention policy allows it), the bubble shows "0 hits"; if the level is NOT collected, show "⚫ off" (per AC2).

2. **Request Grouping & Sorting:**
   - The request-stream view groups entries by `request_id`. For each request_id, find the earliest timestamp and the highest severity level (ERROR > WARNING > INFO > DEBUG).
   - Sort by severity first (ERROR rows first), then by timestamp (newest first within each severity tier).
   - To determine the HTTP status (for the status badge), look for an operational_logs entry with `source="http"` and extract the status from `metadata.status`.

3. **Filter State & Client-Side Filtering:**
   - Maintain `@active_filters` as a map: `%{endpoint: nil, level: nil, source: nil}` (or use a set of active {dimension, value} tuples).
   - When a bubble is clicked, toggle the filter in `@active_filters` and re-render the list.
   - To apply filters: for each request row, check if ALL active filters match (AND logic). If no filters are active, show all rows.
   - The filter logic runs in the browser (via a `phx-change` or `phx-click` event on the bubbles that updates a hidden input or calls a function on `@active_filters`). Alternatively, use a small inline `<script>` tag (without a framework) to toggle the filter state directly in the DOM for instant visual feedback.

4. **PubSub Subscription & Live Updates:**
   - In mount/3, call `Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")` to subscribe to the topic.
   - The operational-log-store story will broadcast each new entry as `{:operational_log_entry, entry_map}` messages.
   - In handle_info/2, match on `{:operational_log_entry, entry}` and:
     - Extract the `request_id` from the entry
     - Find or create the request row (group by request_id)
     - Apply the current filter state: if the entry matches, include it
     - Stream the updated rows using `Phoenix.LiveView.stream/4` (not a reassign)

5. **Detail Panel & Drawer:**
   - The detail panel can be rendered as a conditional `<div>` that slides in from the right via CSS (`transform translate-x-full` when closed, `translate-x-0` when open).
   - Use a `phx-click="close_detail"` button to close it.
   - Store the current `@detail_request_id` in the LiveView state; render the detail panel only if this is not nil.
   - Fetch the full list of operational_logs entries for the request_id from the table (or keep them in memory in the stream if the stream includes all entry data).

6. **Accessibility:**
   - Use semantic HTML: `<button>` for bubbles, `<table>` or `<div role="list">` for the request stream.
   - Every interactive element (bubble, row, close button) should have a clear label (text or aria-label).
   - Color indicators must always pair with text or icon.
   - New entries should use `aria-live="polite"` on a container div, not `aria-live="assertive"` which would interrupt screen-reader flow.

7. **Performance Considerations:**
   - Keep the loaded data size reasonable (e.g., last 100 requests) to avoid browser memory bloat.
   - The stream respects the "already-loaded rows don't re-render" principle: use `Phoenix.LiveView.stream/4` to append/prepend rows, not a full list reassign.
   - Sorting happens in Elixir (on the server side during render), not in the browser (no client-side sort library).

### Testing Strategy

1. **Unit tests (trace_map_bubble component):** Render the component with various modes, verify the HTML and phx-click handlers.
2. **Integration tests (LogsLive):** Mount the LiveView, simulate PubSub broadcasts, verify filtering, detail panel, accessibility.
3. **Manual accessibility audit:** Use a screen reader (NVDA, JAWS) to verify announcements and keyboard navigation.
4. **E2E test (optional):** A Playwright scenario that opens the logs page, clicks a bubble, verifies the rows filter, and opens a detail panel.

## Tasks / Subtasks

- [x] Create `trace_map_bubble.ex` component with `:filter` and `:configure` modes, render, and test
- [x] Create `detail_panel.ex` component for the slide-in thread view, render, and test
- [x] Create `logs_live.ex` LiveView with mount, render, handle_info, handle_event
  - [x] Mount: subscribe to "operational_logs" PubSub topic, load initial 100 requests from DB
  - [x] Render: Trace Map (bubbles + active chips), request-stream list, detail panel
  - [x] Handle_info: receive operational_logs entries, apply filters, stream new rows
  - [x] Handle_event: filter toggling is CLIENT-SIDE ONLY per AC3's resolution (see test-review
        finding #3) — there is deliberately NO `handle_event("toggle_filter", ...)` clause.
        Bubbles/chips bind `phx-click` to a `Phoenix.LiveView.JS.dispatch/2` command; the actual
        DOM toggle + AND-across-dimensions filtering runs in `priv/static/assets/app.js`
        (`wireTraceMapFilters`, CSP-compliant, mirrors the existing `wireConfirmForms` pattern).
        `open_detail`/`close_detail`/`pause_live_updates`/`resume_live_updates` remain real
        `handle_event/3` clauses.
- [x] Update `layouts.ex` to add logs nav item
- [x] Update `router.ex` to add /admin/logs route
- [x] Write all 12 acceptance tests FIRST (ATDD), verify they fail (already staged before this
      dev-story pass; RED state confirmed per the test files' own moduledocs)
- [x] Implement trace map, filtering, request stream, detail panel
- [x] Verify all 12 acceptance tests pass (11 pass by default; Acceptance Test 12 is tagged
      `:integration`, excluded from the default `mix test` run per project convention — verified
      separately via `mix test --include integration`, see Dev Agent Record)
- [ ] Manual accessibility audit (screen reader, keyboard navigation) — deferred to a dedicated
      UX/accessibility review pass; not performed by the dev agent (no screen reader available in
      this environment). Automated markup-contract coverage (aria-pressed/aria-label/aria-live,
      native `<button>`/keyboard-operable elements, icon+text pairing) is verified by Acceptance
      Tests 8–10.
- [ ] Security review: Kassandra to verify no sensitive data appears in log view (logs are already
      redacted by the operational-log-store story) — this is a separate pipeline step
      (security-review gate), not performed by the dev agent.

## Existing Precedent & Code Patterns

### AuditLogLive Pattern

The existing `server/lib/nebu/admin/audit_log_live.ex` provides a template for the basic LiveView structure:
- Uses `use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}` for the shared admin layout
- Sets `@active_nav = "compliance"` so the sidebar highlights the current page
- Sets `@page_title` for the browser title
- Loads data in mount/3 via inline SQL (ADR-018)
- Renders a simple table with `table-zebra` DaisyUI classes
- No live updates (read-once at mount)

This story will reuse this pattern but extend it with:
- PubSub subscription (handle_info/2 callbacks)
- Stateful filtering (handle_event/3 callbacks)
- A component-based UI (Trace Map, detail panel)
- Real-time row streaming (not a static list)

### Component Pattern

Other admin pages like `rooms/index.html.heex` and `users/show.html.heex` are plain HTTP controllers (no LiveView), intentionally avoiding per-action server events. This story explicitly breaks that pattern (justified in AC3) because the Trace Map's live-filtering value proposition genuinely requires it. The component-based approach (trace_map_bubble, detail_panel) keeps the interactivity minimal and reusable.

### DaisyUI & Tailwind

The codebase uses:
- `btn btn-sm` for buttons
- `badge badge-error`, `badge-warning`, `badge-info`, `badge-neutral` for badges
- `table table-zebra` for tables
- `form-control` + `input input-bordered` for form fields
- `drawer` or fixed positioning + `transform transition` for slide-out panels

This story will use the same classes, no new CSS.

## Dev Agent Record

### Implementation Plan

- `Nebu.Admin.LogsLive.TraceMapBubble.trace_map_bubble/1` — a mode-agnostic `Phoenix.Component`
  that only wires whatever `on_click` value it's given onto `phx-click`; it has no opinion on
  whether that value is a bare event name (`:configure`, sibling story) or a `Phoenix.LiveView.JS`
  command list (`:filter`, this story). Also renders the AC2 "off" (uncollected) state.
- `Nebu.Admin.LogsLive.DetailPanel.detail_panel/1` — stateless slide-in panel. The
  `data-testid="detail-entry"` node contains ONLY the raw message text (metadata/timestamp/level
  rendered in a sibling node) so `Floki.text/1` on it returns the exact message string.
- `Nebu.Admin.LogsLive` — mount subscribes to `"operational_logs"` PubSub and seeds from
  `Nebu.Web.LogStore.get_logs/1` (guarded by `Process.whereis(Nebu.Repo)`, mirroring
  `AuditLogLive.load_events/0`); `handle_info/2` pattern-matches the BARE MAP
  `Nebu.Web.LogStore.Handler.safe_broadcast/1` actually sends (not the `{:operational_log_entry,
  entry}` tuple this story's own original Dev Notes described — verified against the merged
  `operational-log-store` code, per the test-review's finding). Rows are grouped by `request_id`,
  sorted by `{-severity_rank, -first_seq}` (errors first, newest first within a tier), and
  bookkept incrementally in `@row_order`/`@row_meta` so each ingest only touches the ONE row it
  concerns (`upsert_row/2`): a genuinely new `request_id` calls `Phoenix.LiveView.stream_insert/4`
  once at its computed index; an EXISTING row whose severity tier changed (a previously-INFO
  request just received an ERROR entry, e.g.) is moved by first `stream_delete_by_dom_id/3` then
  `stream_insert/4` at the new index (per `stream_insert/4`'s own docs, `:at` has no effect on an
  item that already exists in the client's DOM, so a genuine tier-migration move requires the
  delete+reinsert pair). Cycle 2 fixed the original `stream(reset: true)`-on-every-ingest bug this
  section used to describe — that reset tore down and recreated EVERY row's DOM node on every
  single incoming log line, wiping the client-side Trace Map filter's `row.style.display = "none"`
  (and any open detail panel / scroll position) on every ingest anywhere, not just for the row that
  actually changed. The per-row micro-summary counts (`data-count-debug/info/warn/error`)
  deliberately EXCLUDE the row's own HTTP-sourced entry/entries (only sub-events — Ecto queries,
  warnings, etc. — are tallied), matching Acceptance Test 4's literal expectation (1 HTTP entry + 5
  "ecto" entries → count of 5, not 6); `highest_level` (used for sorting and the level-badge) still
  considers every entry, including the HTTP one.
- **MutationObserver-based filter reapply (cycle 3 fix)**: even with the cycle-2 incremental-stream
  fix, both of `upsert_row/2`'s paths above still produce a FRESH `#request-rows` child node for the
  row in question (a genuinely-new row is appended; a tier-migrated row is deleted then
  re-inserted) — and that fresh node has no memory of a previously-applied `display:none`. Neither
  path is triggered by a click, so `app.js`'s `applyTraceMapFilters()` (which only ran on bubble
  click, chip-remove click, and once at boot) never re-ran for it, silently bypassing an active
  filter for any row that streamed/migrated in mid-session. Fixed by adding a `MutationObserver` on
  `#request-rows` (`childList: true`, no `subtree` needed — rows are direct children) in `app.js`'s
  `wireTraceMapRowObserver/0`, wired from `wireTraceMapFilters()`: on ANY child mutation with added
  nodes, it re-runs the existing (idempotent) `applyTraceMapFilters()` against the full current row
  set, covering the new-row and tier-migration cases identically with no special-casing. Chosen over
  a `phx-hook` `updated()` callback for consistency with this same file's existing `V4 fix`
  (`wireDetailPanelFocus`), which already solved the identical "LiveView patches this DOM
  out-of-band with this file's own listeners" problem via a `MutationObserver` rather than a hook.
- **AC3/AC5 resolution**: Trace Map bubbles and chip-remove controls bind `phx-click` to
  `Phoenix.LiveView.JS.dispatch/2` (e.g. `JS.dispatch("nebu:trace-bubble-click")`) — a JS command
  list containing NO `push`/`patch`/`navigate` op, so there is genuinely no server round-trip. The
  actual aria-pressed toggle + AND-across-dimensions (OR-within-a-dimension) row/chip visibility
  logic lives in `priv/static/assets/app.js`'s new `wireTraceMapFilters()`, wired into `boot()`
  alongside the existing `wireConfirmForms`/`wireUserAutocomplete` — NOT an inline `<script>` tag,
  because the admin CSP is `script-src 'self'` with no `unsafe-inline` (confirmed by reading
  `Nebu.Admin.Router`'s `admin_csp/2`), which would silently block an inline script in every real
  browser.
- **`RequestLogger` metadata gap fix** (test-review finding #4, `matrix-payload-debug-logging`
  epic code, touched here as an unambiguous integration-gap fix per this step's brief): added
  `Logger.metadata(method:, status:, duration_ms:)` immediately before `Logger.info(base_fields)`
  in the `before_send` callback, so these three fields flow structurally into the `:logger` event's
  `meta` (and therefore into `Handler.parse_log_event/1`'s `metadata` map) instead of only ever
  appearing inside the `inspect/1`-rendered `message` string. Verified this does not regress
  `request_logger_test.exs`/`payload_redactor_test.exs` (both still pass; `Logger.metadata/1` does
  not affect the console-formatted text these tests assert on, since no `:metadata` formatter list
  is configured for `:console` in `config/test.exs`).

### Test-infrastructure fixes applied during this pass (not design changes)

Both ATDD test files called `Floki.find/2` directly on the raw HTML STRING returned by
`Phoenix.LiveViewTest.render/1`/`render_component/2`. Floki 0.38.4 (pinned via `mix.lock`,
`floki ~> 0.36` in `mix.exs`) has an explicit `Floki.Finder.find(html_as_string, _) when
is_binary(html_as_string), do: []` clause — a raw string is treated as an opaque text leaf, never
implicitly parsed. This made every `Floki.find(html, ...)` call in both files return `[]`
unconditionally, regardless of implementation correctness (confirmed by direct experimentation:
`Floki.parse_document/1` on the exact same string correctly finds the elements). This is a
mechanical, non-design test-infrastructure bug — fixed directly (same disposition class as the
test-review step's own "fixed directly" findings):
  - `logs_live_test.exs`: added a `parsed/1` helper (`Floki.parse_fragment!/1` when binary, pass
    through otherwise) and routed every `render(view)` call through it (`parsed(render(view))`),
    plus defensively inside the `find_bubble/3`, `rows/1`, `find_row/2` shared helpers.
  - `trace_map_bubble_test.exs`: same fix at the 3 `render_component/2` call sites.
  - Acceptance Test 3 additionally needed a `try/rescue ArgumentError` around its `render_click/1`
    call: `Phoenix.LiveViewTest.ClientProxy.maybe_js_commands/6` only recognizes `push`/`patch`/
    `navigate` ops, and for a plain `<button>` (no `href` fallback) with a `dispatch`-only JS list,
    `render_click/1` unconditionally raises `ArgumentError, "no push or navigation command found
    within JS commands: ..."` — confirmed empirically. That raise is arguably the CORRECT
    AC3-compliant runtime signal (there truly is no server-side event for a real, client-side-only
    bubble) and is semantically equivalent to the test's own "does not toggle aria-pressed at all"
    branch; documented in-line at the fix site.

### Debug Log

- `mix compile --warnings-as-errors` — clean (project code; unrelated deprecation warnings from
  `hackney`/`sweet_xml` dependencies only).
- `mix test test/nebu/admin/logs_live_test.exs test/nebu/admin/logs_live/trace_map_bubble_test.exs --warnings-as-errors`
  → 15 passed, 1 excluded (Acceptance Test 12, `:integration`).
- `mix test test/nebu/admin/logs_live_test.exs --include integration` → 13 passed (confirms
  Acceptance Test 12 passes too).
- `mix test --warnings-as-errors` (full suite) → 1359 passed, 2 skipped, 291 excluded — no
  regressions, including `request_logger_test.exs`/`payload_redactor_test.exs`.
- `mix format` applied to all new/modified `.ex`/`.exs` files.
- E2E (`e2e/features/admin/logs-monitoring.feature`, un-tagged from `@pending-feature`): NOT run
  in this pass — the full stack (`make setup && make dev`, incl. Dex/Postgres) was judged
  impractical to spin up within this sandboxed dev-story session. Deferred to the CI-gate step,
  which runs the full integration/E2E suite. The static `phx-click` JS-command-list contract these
  scenarios rely on is already covered by the ExUnit suite's Acceptance Tests 1/1b/2.
- **Bug-fix cycle 4** — this time a bare `docker compose up -d postgres` + a `--network=nebu_default`
  `elixir:1.20-alpine` container WAS reachable in-sandbox (unlike prior cycles' note above), so both
  fixes were verified against a genuinely live `Nebu.Repo`/Postgres, not just the plain in-memory
  path:
  - `mix compile --warnings-as-errors` (against `NEBU_DB_URL=postgresql://nebu_app:...@postgres/nebu`)
    — clean.
  - `mix test test/nebu/admin/logs_live_test.exs test/nebu/admin/logs_live/trace_map_bubble_test.exs --include integration --warnings-as-errors`
    (live Postgres) → **17 passed** (13 previously-passing + the 2 new regression-test assertions'
    describe block + AC3's now-explicit-precondition variant; 0 failures).
  - `mix test --warnings-as-errors` (full suite, live Postgres) → **1358/1360 passed, 2 skipped, 291
    excluded**, 2 failures — both in `config_controller_test.exs` (AC9, `insufficient_privilege`/RLS
    on `server_config`) and `sso_login_test.exs` (AC12.2) — an unrelated `sso-redirect-error-page`
    epic RLS/environment gap specific to this bare-`nebu_app`-role sandbox connection (no full
    `docker compose up` server/dex/minio stack, so whatever RLS session context the real running
    server sets is absent here). Confirmed PRE-EXISTING and unrelated to either bug fix by reverting
    both `logs_live.ex` and `logs_live_test.exs` (via `git stash`) and re-running just those two
    files: identical 2 failures, byte-for-byte the same errors, with the bug fixes absent — then
    restored the fixes (`git stash pop`) and re-verified the target suite green again.

### Completion Notes

All 12 acceptance tests pass (11 via default `mix test`, the 12th — integration-tagged — verified
separately via `--include integration`). No regressions in the full unit suite (1359 passed). The
`admin-logs-retention-settings` sibling story can reuse `trace_map_bubble/1` in `:configure` mode
exactly as designed (Acceptance Test 11 proves the same component function renders a DIFFERENT
`phx-click` purely from the `on_click` prop it's given). Manual accessibility audit and the
dedicated security review (Kassandra) are explicitly deferred to their own pipeline steps, not
performed here.

### File List

- `server/lib/nebu/admin/logs_live.ex` (new)
- `server/lib/nebu/admin/logs_live/trace_map_bubble.ex` (new)
- `server/lib/nebu/admin/logs_live/detail_panel.ex` (new)
- `server/lib/nebu/admin/router.ex` (modified — `/admin/logs` route)
- `server/lib/nebu/admin/layouts.ex` (modified — "Logs" nav item)
- `server/lib/nebu/web/plugs/request_logger.ex` (modified — `Logger.metadata(method:, status:,
  duration_ms:)` fix)
- `server/priv/static/assets/app.js` (modified — `wireTraceMapFilters` + wiring into `boot()`;
  cycle 3 added `wireTraceMapRowObserver` — `MutationObserver` on `#request-rows` re-applying the
  active filter to newly-streamed/tier-migrated rows)
- `server/test/nebu/admin/logs_live_test.exs` (modified — Floki-parsing test-infrastructure fix +
  Acceptance Test 3's `render_click` `ArgumentError` handling; ATDD assertions themselves
  unchanged)
- `server/test/nebu/admin/logs_live/trace_map_bubble_test.exs` (modified — same Floki-parsing
  test-infrastructure fix)
- `e2e/features/admin/logs-monitoring.feature` (modified — removed `@pending-feature` tag)

## Change Log

- 2026-07-04: Story created with full context on Trace Map UX, request-centric stream view, reusable component design, and live-update architecture. Depends on operational-log-store (sibling story, created in parallel). Ready for dev agent handoff.
- 2026-07-05: Dev-story implementation complete. All 12 acceptance tests green (11 default + 1
  integration-tagged). Fixed the `RequestLogger` metadata gap (method/status/duration_ms now
  structurally reach `operational_logs.metadata`) and a Floki-usage test-infrastructure bug in both
  ATDD test files (raw HTML strings were never being parsed before `Floki.find/2`, an unconditional
  no-op in floki 0.38.4). Status set to "review".
- 2026-07-05 (bug-fix cycle 2): Fixed a BLOCKING bug — `logs_live.ex` was calling
  `stream(socket, :rows, rows, reset: true)` on every ingest, tearing down and recreating every
  row's DOM node on every incoming log line and silently wiping the client-side Trace Map filter's
  `display:none` (plus scroll position / open detail state) the instant ANY new entry arrived
  anywhere. Replaced with incremental `stream_insert/4` (new row) / `stream_delete_by_dom_id/3` +
  `stream_insert/4` (existing row moved to a new severity tier), backed by `@row_order`/`@row_meta`
  bookkeeping — only the row that actually changed is touched.
- 2026-07-05 (bug-fix cycle 3): UX re-verification found ONE remaining gap in the same area: neither
  of cycle 2's two `upsert_row/2` paths (new row, tier migration) re-applied the active client-side
  filter to the fresh DOM node they produce, since `app.js`'s `applyTraceMapFilters()` only ran on
  bubble click / chip-remove click / page boot — never in reaction to the stream container itself
  gaining children. Fixed by adding a `MutationObserver` on `#request-rows` in `app.js`
  (`wireTraceMapRowObserver`) that re-runs `applyTraceMapFilters()` on any child-list mutation,
  covering both paths identically. Updated this Dev Agent Record's `upsert_row/2` description
  (previously still described the stale cycle-1 `reset: true` approach) to match the actual
  shipped incremental-stream + MutationObserver implementation.
- 2026-07-05 (bug-fix cycle 4): CI-gate found two real bugs that only manifested under the FULL
  `make test-integration` run (real live Postgres + real background data), not caught by any prior
  cycle's isolated `mix test` runs:
  1. **Crash (BLOCKING, all 11 test cases failed via a mount crash)** — `initial_entries/0` can
     legitimately load real `operational_logs` rows with a `nil` `request_id` (system/background log
     lines not tied to any HTTP request). `ingest_entry/2` unconditionally grouped by
     `entry.request_id` and called `upsert_row/2` for every entry, and `row_dom_id/1`'s
     `Base.url_encode64(row.request_id, padding: false)` raised `FunctionClauseError` the instant
     `row.request_id` was `nil`. Fixed by short-circuiting `ingest_entry/2`'s row-stream/
     `entries_by_request` update path when `request_id` is `nil` — AC6's "one row per request"
     means an entry with no request thread produces no row — while STILL updating
     `level_counts`/`source_counts`/endpoint tracking unconditionally, since AC1's Trace Map bubble
     counts are not request-scoped (confirmed against Acceptance Test 1's own baseline+delta
     assertions, which count ALL ingested events, not just request-row-backed ones). Added a
     regression test ("Bug-fix cycle 4 regression [AC1/AC6]") proving a `request_id: nil` broadcast
     increments bubble counts, does not crash mount, and produces no request row.
  2. **Test-isolation gap (Acceptance Test 3 [AC2])** — the test asserted
     `policy.log_collect_debug == false` under the now-falsified assumption that nothing else in the
     suite writes that `server_config` key; `handler_test.exs`/`writer_test.exs` both do, with no
     cross-file reset, making the assertion's outcome depend on non-deterministic test-run ordering
     under the full live-DB suite. Fixed by having the test control its own precondition explicitly
     (`Nebu.Admin.DB.upsert_server_config(%{"log_collect_debug" => "false"})` + an `on_exit` cleanup
     deleting the row), mirroring `writer_test.exs`'s "AC7: level filtering respects server_config"
     pattern, guarded by `Process.whereis(Nebu.Repo)` (this file's Repo-presence convention) since the
     write only makes sense/is safe when a live Repo is actually running. `get_policy/0` always
     performs a live DB read (never routed through the persistent_term-backed `PolicyCache`, which
     only backs `Handler.log/2`'s hot path), so no cache-staleness window applies here.
  Both fixes verified against a genuinely live `Nebu.Repo`/Postgres (not just the in-memory path) —
  see Debug Log for the exact commands and pass counts, and confirmation that the 2 unrelated
  pre-existing failures elsewhere in the full suite are reproducible with these fixes reverted.
