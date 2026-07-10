---
id: noise-endpoint-bucketing
title: "Noise Endpoint Bucketing — dedicated low-signal category in Trace Map"
epic: enhanced-logging
status: superseded
security_review: not-needed
matrix: false
ui: true
created: 2026-07-06
---

# Noise Endpoint Bucketing

## Story

**As** a Nebu platform operator using `/admin/logs`,
**I want** high-frequency polling/keepalive endpoints (`/admin/live/longpoll`, `/health`, `/_matrix/client/v3/sync`) grouped together in a dedicated, visually distinct "Polling/Keepalive" category in the Trace Map, separate from real diagnostic endpoints,
**so that** I can quickly identify which endpoints represent actual application activity vs. continuous background traffic, and avoid having the Trace Map's endpoint list completely dominated by these three noise sources (which otherwise dwarf every diagnostic signal).

## Background

### The Noise Floor Problem

The Trace Map in `/admin/logs` (from `admin-logs-monitoring-view` story) displays every distinct observed HTTP endpoint as its own bubble with a live count badge. In a running deployment, three endpoints dominate the endpoint list because they fire constantly, regardless of what the operator is actually doing:

1. **`/admin/live/longpoll`** — the Admin UI's own LiveView transport keepalive. This admin UI is forced onto `ThrottledLongPoll` (not WebSocket; see `server/priv/static/assets/app.js`'s transport config, established by `trace-map-filter-reset-bugfix` story's code-review findings). The admin browser may be open and idle, yet longpoll requests fire every few seconds.

2. **`/health`** — the container/orchestrator health-check endpoint (see `server/lib/nebu/web/plugs/`), hit on a fixed interval regardless of any real usage. Every deployment's monitoring stack pings this continuously.

3. **`/_matrix/client/v3/sync`** — Matrix's long-poll endpoint, held open continuously by every connected client. In a real deployment with dozens or hundreds of active users, this endpoint alone can generate 1000+ entries per second when elevated logging is active (see `war-room-mode` story's AC8 for the safety concern this creates).

These three endpoints are the same class of problem: **constant, low-diagnostic-value, high-volume polling traffic**. When they occupy 50–90% of the Trace Map's endpoint-dimension real estate, the operator cannot quickly scan for the endpoints they actually care about (login errors, sync bugs, room creation failures, etc.).

### Operator Request

From the initial requirements: these three endpoints should be "behandelt wie Matrix sync" (treated like Matrix sync) — whatever special handling `/_matrix/client/v3/sync` gets (bucketed/excluded/deprioritized) should apply uniformly to all three, since they're the same category of problem.

### Sibling Story Context

Two related stories provide integration points:

1. **`trace-map-hierarchy`** (planned, design in progress) — restructures the Endpoint dimension into a domain→endpoint tree (e.g., `/_matrix/client` → `/sync`, `/profile`, etc.). If landing in the same sprint, this story's "noise bucket" should be modeled as a **domain-level category** (e.g., "Polling/Keepalive" alongside "/_matrix/client", "/admin", etc.) rather than a second, parallel categorization system. **Forward-reference: if trace-map-hierarchy lands, migrate the noise endpoint list from this story's hardcoded constant to a computed domain-membership rule.**

2. **`war-room-mode`** (already shipped) — introduces session-scoped logging with scope/filter matching (scope can exclude specific endpoints like `/_matrix/client/v3/sync`). That story's `scope` parameter already implements endpoint-exclusion logic. This story should **coordinate with war-room-mode** to ensure both stories use the same definition of "which endpoints count as noise" rather than duplicating the logic. **Forward-reference: if war-room-mode adds a "safe by default" scope option (e.g., `scope: "all_except_polling"`), this story's noise-endpoint list is the canonical definition of what `:exclude_polling` means.**

## Acceptance Criteria

### Dedicated Noise Category

**AC1:** The Trace Map's Endpoint dimension displays a dedicated "Polling/Keepalive" category, visually grouped and distinct from real diagnostic endpoints. The category includes exactly three endpoints:
- `/admin/live/longpoll`
- `/health`
- `/_matrix/client/v3/sync`

Clicking the category name (or a collapse/expand icon) toggles visibility of the three endpoints' individual bubbles. Default state: category is **collapsed** (shows a single "Polling/Keepalive (N)" bubble with the summed count of all three endpoints, not expanded).

**AC2:** When the "Polling/Keepalive" category is collapsed, the Trace Map displays:
- A single collapsed bubble labeled "🔄 Polling/Keepalive" with a count badge (e.g., "🔄 Polling/Keepalive (1247)" = sum of all three endpoints' current entry counts)
- The bubble is visually de-emphasized (e.g., muted color, reduced opacity, dimmed text) compared to real diagnostic endpoints
- The bubble is still interactive: clickable to expand, and (if expanded) the three individual bubbles inside are toggleable as filters, same as any other endpoint

**AC3:** When the "Polling/Keepalive" category is expanded, the Trace Map displays:
- The three individual endpoint bubbles (`/admin/live/longpoll`, `/health`, `/_matrix/client/v3/sync`), grouped visually beneath a "Polling/Keepalive" section header or indented under a parent node
- Each individual bubble shows its own live count
- The three bubbles are still de-emphasized (same muted styling as the collapsed bubble)
- A collapse icon/button allows collapsing the group back to the single summary bubble

**AC4:** The collapsed/expanded state of the "Polling/Keepalive" category is:
- Persisted in the browser's `localStorage` (key: `"nebu_logs_polling_category_expanded"`, value: true/false)
- Restored when the page reloads
- Shareable via URL query param (`?polling_expanded=true`), following the same pattern as the Trace Map's existing filter-state URL params (from `trace-map-filter-reset-bugfix` story)

**AC5:** When a user applies a filter (e.g., clicks "/sync" endpoint bubble to activate it), the filter works identically whether "/sync" is displayed as part of the collapsed group or expanded individually:
- If the "/sync" bubble is expanded, clicking it toggles the filter directly (as before)
- If the "/sync" bubble is inside the collapsed "Polling/Keepalive" group (i.e., the group is collapsed), clicking the collapsed group's bubble applies a filter for "any of the three polling endpoints" (OR logic across the three). Expanding the group then allows fine-grained filtering per endpoint.

Alternatively, **design choice deferred to Dev Notes below**: the collapsed "Polling/Keepalive" bubble might be **not filterable itself**, and only the expanded individual bubbles are filterable. The dev agent's task is to decide which UX is clearer and implement the chosen one explicitly in Dev Notes.

**AC6:** Filter state (which endpoints are active) continues to work correctly across the collapsed/expanded category state. Example scenario:
- User clicks `/health` endpoint bubble (filter activates, category may be expanded or collapsed, depending on implementation choice from AC5)
- User collapses the "Polling/Keepalive" category (or it collapses automatically)
- The filter remains active (row visibility unchanged, aria-pressed still true for the bubble)
- New log entries continue to respect the filter, whether the group is collapsed or expanded

### Visual & Styling

**AC7:** All three polling endpoints share **muted styling** compared to diagnostic endpoints:
- Reduced opacity (e.g., `opacity: 0.6` or similar) on the bubbles
- Dimmed color (e.g., slightly grayed text or slightly desaturated background color)
- Optional: a subtle icon or badge indicating "low-signal" (e.g., a small 🔄 icon next to the endpoint names, or a "low-signal" tooltip on hover)

The muting is applied whether the category is collapsed (single bubble) or expanded (three individual bubbles).

**AC8:** The "Polling/Keepalive" group header (if implemented as a visual section) uses styling consistent with DaisyUI's hierarchy. Example:
- A slightly larger, bolder text label ("Polling/Keepalive") than individual endpoint bubbles
- A subtle background or border distinguishing the group from the diagnostic-endpoint section
- The collapse/expand icon (▶ / ▼) is visually clear and accessible

**AC9:** The collapsed "Polling/Keepalive (N)" bubble's count badge updates in real time, just like any other endpoint's count. When a log entry is received for any of the three endpoints while the group is collapsed, the count increments.

### Accessibility

**AC10:** The collapse/expand button (if a dedicated button exists) has:
- Clear `aria-label` describing the action (e.g., "Expand polling/keepalive endpoints" / "Collapse polling/keepalive endpoints")
- Clear visual focus ring
- Keyboard-navigable (Tab-able and triggerable via Enter/Space)

**AC11:** Screen-reader users are informed that the three endpoints are grouped and potentially hidden. The collapsed bubble should have an `aria-expanded="false"` attribute (true when expanded), and the button should announce "Polling/Keepalive, 3 endpoints, collapsed" (or similar).

**AC12:** The muted styling (opacity/color) is not the ONLY indication of the category's special status. The visual grouping and header text make it clear these are low-signal without relying on color/opacity alone.

### Data Definition & Reusability

**AC13:** The list of polling/keepalive endpoints is defined as a single, **canonical constant** in the codebase:
- Location: `server/lib/nebu/admin/logs_live.ex` (or a separate `server/lib/nebu/admin/logs_live/noise_endpoints.ex` module if the list grows or is reused)
- Definition: `@noise_endpoints = ["/admin/live/longpoll", "/health", "/_matrix/client/v3/sync"]` (or a similar constant, with clear documentation that this is the authoritative "noise" definition)
- This constant is used by **all stories** that need to refer to "which endpoints are noise" (e.g., `war-room-mode`'s scope-exclusion logic, future `trace-map-hierarchy`'s domain-membership rules, future `war-room-dedicated-page`'s "safe by default" scope option)

**AC14:** The constant has clear documentation (inline comment or docstring) explaining why these three endpoints are grouped: constant polling, low diagnostic value, and dominating the endpoint list. This serves as a reference when adding future endpoints to the list or when other stories need to understand the noise-endpoint definition.

### Integration with Trace Map Filters

**AC15:** When the noise category is collapsed, the Trace Map's existing filter/chip-removal semantics work correctly:
- If a user has filtered by endpoint (e.g., `/health` active), and then collapses the polling category, the filter remains active and the rows remain filtered
- If the user then removes the filter (via the chip-remove button), the filter is removed and rows are unfiltered, regardless of category state

**AC16:** The "Active Filters" chip row (from `admin-logs-monitoring-view` story, AC4) displays filters for individual polling endpoints correctly, whether the category is collapsed or expanded:
- Example: user expands the category and filters by `/health` → chip shows "[/health ×]"
- User collapses the category → chip still shows "[/health ×]" (the endpoint name, not "Polling/Keepalive")
- This ensures the filter state is always clear and unambiguous, regardless of category state

### Scope Boundaries (What This Story DOES NOT Implement)

**AC17:** This story does NOT implement:
- A configurable/admin-editable list of noise endpoints (the list is hardcoded per AC13; if a future need arises to make it configurable, that is a separate story)
- Automatic filtering/hiding of noise endpoints by default (the category is collapsed by default, but if the user expands it, the endpoints are visible; no auto-hiding based on signal/noise heuristics)
- A distinct "exclude polling endpoints" war room scope option (war-room-mode's scope-exclusion logic is unchanged by this story; if a future story adds such an option, it reuses the @noise_endpoints constant from AC13)
- Analysis or ML-based auto-classification of endpoints as "noisy" vs. "diagnostic" (the three endpoints are explicitly curated, not auto-detected)

## Acceptance Tests

### Tests written FIRST (ATDD):

1. **[AC1–AC2] Polling/Keepalive category renders collapsed by default** — ExUnit component/integration test
   - Given: LogsLive mounted with default state
   - When: The Trace Map endpoint dimension is rendered
   - Then: A single "🔄 Polling/Keepalive (N)" bubble appears (collapsed)
   - And: The three individual polling endpoints (`/admin/live/longpoll`, `/health`, `/_matrix/client/v3/sync`) are NOT visible (not rendered in the DOM)
   - And: The bubble is visually de-emphasized (muted styling verified via DOM class inspection)

2. **[AC3] Polling/Keepalive category expands and shows individual bubbles** — ExUnit integration test
   - Given: LogsLive mounted with the polling category collapsed
   - When: The user clicks the "🔄 Polling/Keepalive" bubble (or an expand icon if using a separate button)
   - Then: The three individual endpoint bubbles appear beneath a "Polling/Keepalive" section header (or indented)
   - And: Each bubble shows its own live count
   - And: All three bubbles retain the muted styling (AC7)

3. **[AC3] Polling/Keepalive category collapses back** — ExUnit integration test
   - Given: LogsLive mounted with the polling category expanded (user previously clicked to expand)
   - When: The user clicks the collapse icon/button
   - Then: The three individual bubbles disappear
   - And: The single "🔄 Polling/Keepalive (N)" bubble re-appears with the summed count

4. **[AC4] Collapsed/expanded state persists in localStorage** — ExUnit integration test + manual browser verification
   - Given: LogsLive mounted with the polling category collapsed
   - When: The user expands the category, then reloads the page
   - Then: The category is still expanded after reload
   - And: The state is stored in `localStorage["nebu_logs_polling_category_expanded"]`
   - When: The user collapses the category and reloads again
   - Then: The category is still collapsed

5. **[AC4] Collapsed/expanded state syncs with URL query param** — ExUnit integration test
   - Given: LogsLive mounted with the polling category state determined by a URL query param
   - When: The page loads with `?polling_expanded=true`
   - Then: The category is expanded at mount
   - When: The page loads with `?polling_expanded=false` (or absent, defaulting to collapsed)
   - Then: The category is collapsed

6. **[AC5–AC6] Filtering a polling endpoint works while category is collapsed** — ExUnit integration test
   - Given: LogsLive with the polling category collapsed, and some rows visible
   - When: The user clicks the "🔄 Polling/Keepalive" bubble (assuming AC5's first design choice: group bubble is filterable)
   - Then: Only rows matching any of the three polling endpoints are visible (OR logic)
   - And: The bubble shows `aria-pressed="true"`
   - And: The category remains collapsed (clicking the collapsed bubble activates a filter, not an expand action)
   - [Alternative test for AC5's second design choice: if the group bubble is NOT filterable, then clicking it expands the group instead, and filtering only works on the individual bubbles]

7. **[AC6] Filtering a polling endpoint survives category state change** — ExUnit integration test
   - Given: LogsLive with `/health` filter active (category may be collapsed or expanded)
   - When: The user collapses the category (if it was expanded) or expands it (if it was collapsed)
   - Then: The `/health` filter remains active
   - And: Rows remain filtered by `/health`
   - And: New incoming entries continue to respect the filter

8. **[AC7] Polling endpoints are visually de-emphasized** — ExUnit component test + manual visual verification
   - Given: The Trace Map endpoint dimension is rendered with both diagnostic and polling endpoints
   - When: The DOM is inspected
   - Then: The diagnostic-endpoint bubbles (e.g., `/login`, `/sync`, `/createRoom`) have standard styling
   - And: The polling-endpoint bubbles (`/admin/live/longpoll`, `/health`, `/_matrix/client/v3/sync`) have muted styling (e.g., `opacity: 0.6`, `text-gray-500`, or similar)
   - And: A screen-reader user reading the Trace Map can distinguish polling endpoints by name alone (not just by color/opacity)

9. **[AC9] Collapsed group count updates in real time** — ExUnit integration test
   - Given: LogsLive mounted with the polling category collapsed, count showing "🔄 Polling/Keepalive (100)"
   - When: A new log entry for `/health` is broadcast via PubSub
   - Then: The count increments to "🔄 Polling/Keepalive (101)"
   - And: No expansion/collapse occurs (the category remains collapsed)

10. **[AC10–AC11] Collapse/expand button is accessible** — ExUnit test + manual keyboard/screen-reader verification
    - Given: LogsLive rendered with a separate expand/collapse button (if used)
    - When: The button HTML is inspected
    - Then: It has an `aria-label` describing the action
    - And: It has an `aria-expanded` attribute (true/false)
    - When: The page is read by a screen reader (manual test)
    - Then: The button announces "Expand polling/keepalive endpoints" (or similar)
    - When: The user navigates with Tab
    - Then: The button is in the tab order
    - And: Space/Enter toggles the category state

11. **[AC13] Noise endpoints constant is defined and used** — ExUnit unit test
    - Given: The source code is reviewed
    - When: A search for `@noise_endpoints` (or equivalent) is performed
    - Then: A single, canonical definition exists in `server/lib/nebu/admin/logs_live.ex` (or `noise_endpoints.ex`)
    - And: The constant includes exactly the three endpoints: `/admin/live/longpoll`, `/health`, `/_matrix/client/v3/sync`
    - And: The constant has clear documentation explaining why these are grouped

12. **[AC13–AC14] Noise endpoints are reusable by other stories** — Coordination/integration test (manual verification or a test spanning both stories)
    - Given: `Nebu.Admin.LogsLive.noise_endpoints()` (or equivalent) is called from a different module
    - When: The function is invoked
    - Then: It returns the canonical noise-endpoint list
    - And: No duplication of the list exists elsewhere in the codebase
    - [This test is primarily a code-review assertion, not an ExUnit test per se, but a clear pattern check: is there a single source of truth?]

13. **[AC15–AC16] Filter chip shows endpoint name, not category name** — ExUnit integration test
    - Given: LogsLive with `/health` filter active (category may be expanded or collapsed)
    - When: The active-filter chip row is rendered
    - Then: The chip displays "[/health ×]" (not "[Polling/Keepalive ×]")
    - And: Clicking the × removes the `/health` filter
    - And: If other polling endpoints had been filtered, clicking × only removes the `/health` one (no bulk deactivation of the whole group)

14. **[AC1–AC3, integration] Endpoint bubble counts are correct before and after category state change** — ExUnit integration test
    - Given: LogsLive with 50 log entries: 10 for `/admin/live/longpoll`, 15 for `/health`, 25 for `/_matrix/client/v3/sync`
    - When: The category is collapsed
    - Then: The "🔄 Polling/Keepalive (50)" bubble shows the summed count
    - When: The category is expanded
    - Then: Three bubbles appear: `/admin/live/longpoll (10)`, `/health (15)`, `/_matrix/client/v3/sync (25)`
    - And: The sum of the three equals the collapsed count

## Dev Notes

### File Structure

- **Modified:** `server/lib/nebu/admin/logs_live.ex`
  - Add a constant `@noise_endpoints = ["/admin/live/longpoll", "/health", "/_matrix/client/v3/sync"]` with clear documentation (AC13–AC14)
  - Expose a public function `def noise_endpoints()` returning this constant, for reuse by other modules (AC13)
  - Modify the Endpoint dimension render in the Trace Map to group polling endpoints into a collapsible category:
    - Separate the endpoint list into `@noise_endpoints` and `@diagnostic_endpoints` (computed at render time or in mount)
    - Render the polling category first (or at a fixed position in the Trace Map for consistency), followed by diagnostic endpoints
    - Render the category as a collapsible/expandable section with the three bubbles grouped beneath
    - Apply `@category_expanded` state (from `socket.assigns`) to control visibility of individual bubbles
  - Add `@category_expanded` to `socket.assigns` at mount (default: false, per AC2)
  - Add a `handle_event("toggle_polling_category", ...)` clause to handle expand/collapse clicks
  - Sync the category state to `localStorage` and URL query params (AC4), following the pattern established by `trace-map-filter-reset-bugfix` story's filter-state syncing

- **Modified:** `server/priv/static/assets/app.js`
  - Add syncing logic for the `polling_expanded` state to URL query param and `localStorage` (AC4)
  - Wire the collapse/expand button's click handler to dispatch a custom event (e.g., `nebu:polling-category-toggle`) that triggers the LogsLive `handle_event` (or use a plain `phx-click` with the event name)
  - Update the existing `applyTraceMapFilters()` function (from `trace-map-filter-reset-bugfix`) to skip applying filters to polling endpoints if the category is collapsed and the user hasn't explicitly filtered a polling endpoint (or implement AC5's chosen design: if the collapsed group is filterable, update `applyTraceMapFilters()` to handle the group's filter as an OR across the three endpoints)

- **New (optional):** `server/lib/nebu/admin/logs_live/noise_endpoints.ex`
  - If the noise endpoint list grows or is used by multiple modules, extract it to a separate module with a single public function `def list()` returning the canonical list and helper functions (e.g., `def is_noise_endpoint?(endpoint)`)
  - Otherwise, keep the constant inline in `logs_live.ex` (simpler, less indirection)

- **Modified:** `server/test/nebu/admin/logs_live_test.exs`
  - Add 14 Acceptance Tests above (ATDD style, written FIRST before implementation)
  - Tests 1–3, 9, 14 are primary functional tests; Tests 4–8, 10–13 verify details, accessibility, and reusability

### Design Decision: AC5's Filterable Behavior

**Two design choices presented; dev agent chooses one:**

**Option A (Collapsed group is NOT filterable; expand to filter):**
- Clicking the collapsed "🔄 Polling/Keepalive" bubble expands the category (does not activate a filter)
- Only the expanded individual bubbles are filterable
- Pros: Clear mental model (collapse/expand is a UI gesture, filtering is a separate gesture)
- Cons: Slightly more clicks if the user wants to filter by `/sync` while the category is collapsed

**Option B (Collapsed group IS filterable as an OR across the three endpoints):**
- Clicking the collapsed "🔄 Polling/Keepalive" bubble activates a filter matching ANY of the three endpoints (OR logic)
- If the user wants to filter by only one endpoint (e.g., just `/health`), they must expand the category and click the individual bubble
- Pros: Faster filtering if the user wants "any polling endpoint"; direct parity with other endpoints
- Cons: Slightly unusual semantics (a single bubble activating three filters)

**Recommendation:** Option A (not filterable when collapsed) is the clearer, simpler UX. The category is a navigational/organizational feature (collapse/expand), and filtering is a separate action (click to filter). This avoids the confusion of a single bubble activating multiple filters. If this feels limiting in user testing, Option B can be added in a future story without breaking Option A's implementation.

**Dev agent's decision:** Implement **Option A** (expand/collapse only, filtering requires expansion) unless existing testing data or code patterns in the codebase strongly suggest Option B.

### Architecture & Implementation Hints

1. **Ordering in the Trace Map:**
   - The polling category should appear at a **consistent, predictable position** in the endpoint list (e.g., always first, or always last among endpoints). Recommended: **last** (after all diagnostic endpoints), so the operator scans diagnostic endpoints first and can ignore the polling section if not interested.
   - Alternatively, **first**, with clear visual separation (e.g., a divider line), to signal "these are special" upfront.
   - **Decision: left to dev agent**, but should be made explicitly and documented in the story's completion notes.

2. **Category State Management:**
   - The `@category_expanded` socket assign should be managed just like any other LiveView state:
     - Initialized at mount (default: false)
     - Updated via `handle_event("toggle_polling_category", ...)` (or named similarly)
     - Synced to URL and localStorage via the JavaScript in `app.js`
   - Use the same pattern as `trace-map-filter-reset-bugfix`'s `@active_filters` for consistency.

3. **Real-Time Count Updates:**
   - When a new log entry is received (via PubSub), the existing `handle_info/2` in `logs_live.ex` updates `level_counts`, `source_counts`, and `@endpoint_counts` (from `admin-logs-monitoring-view`).
   - For the noise category, compute the collapsed count as a **derived value** at render time (sum of the three endpoint counts from `@endpoint_counts`), not a separate state variable. This ensures the count is always accurate and updates automatically when any of the three endpoints' counts change.
   - No new state variable for "polling_count" — it is computed on-the-fly.

4. **Styling & DaisyUI:**
   - Use DaisyUI's existing `opacity` or `opacity-75` / `opacity-60` utility class for muting (already supported)
   - Use a slightly grayed color for text (e.g., `text-gray-500` or `text-base-content/60`)
   - For the category header, use a slightly larger font or bold text (e.g., `font-semibold` or `text-sm` vs. `text-xs` for individual bubbles)
   - The collapse/expand icon can be a simple `▶` / `▼` (Unicode) or a `+` / `−` symbol, or a DaisyUI-compatible chevron icon if available
   - Ensure the section visually groups the three bubbles (e.g., a subtle background box, or indentation)

5. **Accessibility Considerations:**
   - The collapse/expand button (if a separate button exists) must have `aria-expanded` and `aria-label`
   - If the button is part of the category header (e.g., a clickable `<h3>` with a nested button), ensure the entire header is keyboard-accessible
   - The muting (opacity, color) should not be the SOLE indicator of the category's special status — the visual grouping and text label must make it clear

6. **Reusability & Future Stories:**
   - The `@noise_endpoints` constant (or `Nebu.Admin.LogsLive.noise_endpoints()` function) is the **canonical definition** of which endpoints are "noise"
   - When `trace-map-hierarchy` lands, if it models endpoints as a domain-hierarchy tree, consider adding a function like `def noise_domains()` that maps the noise endpoints to their domain nodes (e.g., all three as "Polling/Keepalive" domain)
   - When/if `war-room-dedicated-page` (or a similar story) adds a "safe by default" scope option to war-room-mode, it will reference `Nebu.Admin.LogsLive.noise_endpoints()` to define what `:exclude_polling` means

7. **Testing Notes:**
   - Tests 1–3 verify the UI's collapse/expand behavior
   - Tests 4–5 verify state persistence (localStorage, URL)
   - Tests 6–8 verify filtering (the chosen design from AC5)
   - Tests 9–14 verify details and accessibility
   - Use `Phoenix.LiveViewTest.render/1`, `render_click/2` to simulate user interactions
   - For localStorage/URL tests, inspect the JavaScript-side behavior (may require a Playwright/real-browser test for AC4, unless mocking is feasible)

### Cross-Story Coordination Notes

1. **With `trace-map-hierarchy` (planned, status unknown):**
   - If `trace-map-hierarchy` structures endpoints as a domain tree (e.g., `/_matrix/client` > `/sync`, `/profile`, etc.), coordinate on whether "Polling/Keepalive" is a **top-level domain** (like `/_matrix/client`) or a **special marker on existing domains** (e.g., `/admin` is marked "polling", `/_matrix/client/v3/sync` is marked "polling").
   - **Preferred approach:** "Polling/Keepalive" is a **virtual domain** (not tied to any real URL path) that groups the three noise endpoints. This allows the tree structure to be preserved for real domain organization, while the noise category is a distinct, orthogonal categorization.
   - **Forward-reference for trace-map-hierarchy:** once it lands, migrate this story's hardcoded "Polling/Keepalive" collapse/expand logic to use `trace-map-hierarchy`'s domain tree structure (the noise endpoints become a domain node, and domain nodes are collapsed/expandable).
   - **Current story's scope:** standalone collapse/expand mechanism, no dependency on `trace-map-hierarchy` (deferred integration).

2. **With `war-room-mode` (already shipped):**
   - `war-room-mode` defines a `scope` parameter for filtering endpoints. Currently, scope is "all", a specific route_template, or NULL.
   - This story's canonical noise-endpoint list is defined for the Trace Map's UI. **Coordinate to ensure:** if a future story wants to add a scope option like `"all_except_polling"` to war-room-mode, it will use `Nebu.Admin.LogsLive.noise_endpoints()` as the definition of what `:exclude_polling` means.
   - **Current story's scope:** no changes to war-room-mode (it is already shipped). Future stories (e.g., `war-room-dedicated-page`) will integrate with this story's constant.

3. **With `admin-logs-monitoring-view` (already shipped):**
   - The Trace Map is part of `admin-logs-monitoring-view`. This story modifies that Trace Map's endpoint rendering to add the noise category.
   - No changes to the request-stream list, detail panel, or other parts of the monitoring view.
   - The filter state and chip-removal semantics (AC15–AC16) continue to work as before; the noise category is a purely visual/organizational change to the endpoint dimension.

## Existing Precedent & Code Patterns

### Trace Map Structure (admin-logs-monitoring-view)

The existing Trace Map renders three dimensions (Endpoints, Levels, Sources) as separate sections with bubbles. This story adds a sub-structure to the Endpoints dimension:
- Instead of a flat list of all endpoints, endpoints are grouped into "Diagnostic" and "Polling/Keepalive" categories
- The "Polling/Keepalive" category is collapsible/expandable
- Styling differentiates the two categories (normal vs. muted)

The existing filter-state syncing pattern (`trace-map-filter-reset-bugfix`, AC3/AC4) uses `history.pushState` and `localStorage` — this story reuses the same pattern for the category state.

### Collapse/Expand Pattern

The codebase already has collapsible sections (e.g., detail panels that slide in/out). This story uses a similar pattern: a clickable header that toggles a boolean state, with the toggled content showing/hiding. The styling (opacity, indentation) is purely CSS/Tailwind, no special libraries.

### DaisyUI Classes

Existing bubbles use `btn btn-sm` with conditional `:active` state. The muted polling bubbles can use the same classes but with additional modifiers:
- Standard endpoint: `btn btn-sm btn-outline` (or similar)
- Polling endpoint (unmuted): `btn btn-sm btn-outline opacity-60 text-gray-500` (or similar utilities)
- Category header: `text-sm font-semibold` or similar

## Change Log

- 2026-07-06: Story created with full context on noise-endpoint bucketing, design decision (AC5 Option A recommended), and cross-story coordination points with `trace-map-hierarchy` and `war-room-mode`. Ready for dev-agent handoff.

## Design Update (2026-07-07 — Trace Map Leitstand) — REALIGNMENT REQUIRED

Phil approved a Trace Map redesign that SUPERSEDES this story's "noise bucket" UI
concept. Low-signal long-polling endpoints (default: /_matrix/client/v3/sync,
/admin/keepalive, /health) are now rendered as logging-OFF nodes (gray, dashed, no data)
on the radial leitstand map; clicking one enables a TEMPORARY capture (5 min, countdown,
auto-revert, server-side timer). See `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md` §5
+ `trace-map-leitstand-dummy.html`. The backend concept (config-driven low-signal
endpoint list, off-by-default collection) stays; the bucket/label UI does not. This
story should be re-scoped (likely merged into the new `trace-map-node-controls` story)
before dev starts.
