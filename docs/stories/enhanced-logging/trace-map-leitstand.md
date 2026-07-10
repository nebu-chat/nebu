---
id: trace-map-leitstand
title: "Trace Map Leitstand — radial health-map control room at /admin/logs/trace-map"
epic: enhanced-logging
status: done
security_review: required
matrix: false
ui: true
created: 2026-07-07
---

# Trace Map Leitstand — Control-Room Health Map

## Story

**As** a Nebu platform operator managing production logs,
**I want** a dedicated, full-page radial health map ("Leitstand" control room) at `/admin/logs/trace-map` that shows the status of all domains and endpoints at a glance — selected nodes filter a live stream below — with a war-room banner at the top and resizable stream panel,
**so that** I can rapidly diagnose "where is the system red?" without embedding a trace map widget in a busier logs page, see status changes and live log events flowing to selected services in real time, and interact with filtering via keyboard and mouse in an accessible way.

This story replaces the embedded Trace Map (flat bubbles and tree) on the `/admin/logs` Live Stream page with a dedicated `/admin/logs/trace-map` LiveView page. The Live Stream page (`/admin/logs`) remains unchanged with its own simpler level/source filters; the Trace Map becomes a peer sibling page under the Logs sidebar section (implemented in `admin-sidebar-nesting`, now done with navkeys `logs-monitoring`, `logs-trace-map`, `logs-war-room`).

The Trace Map Leitstand is a **radial SVG map** (center "nebu" → domain circles → endpoint satellites), driven by a **60-second sliding window** of log-event counts (errors, warnings, requests). Nodes are focusable, clickable, and keyboard-operable for filtering. Status is never color-alone — badges show counts, and a status pill in the inspector shows the state explicitly. The page includes an always-visible legend, an inspector panel (showing live stats + status only; logging controls are the follow-up story `trace-map-node-controls`), a resizable live-stream panel at the bottom with level filtering, and a war-room banner when a session is active.

### Design Source

Authoritative design: `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md` (Phil approved 2026-07-07).
Visual/interaction reference: `trace-map-leitstand-dummy.html` (interactive browser dummy).

The spec covers:
- §1: Information architecture — Logs sidebar nesting (covered by `admin-sidebar-nesting`; this story repoints the stub route)
- §2: Radial map geometry, status model, visual states
- §3: Interactions — click/keyboard filtering, multi-select OR, tooltip, inspector, legend
- §6: War-room banner (recording dot + user + elapsed time + link)
- §7: Live stream panel — resizable drag handle, level filter pills (DEBUG/INFO/WARN/ERROR), leitstand shortcut
- §8: Hard implementation constraints — URL-driven filter state, CSP-compliant, SVG server-side, accessibility blocking, no sensitive data

OUT OF SCOPE (follow-up story `trace-map-node-controls`):
- §4: Inspector logging controls (min level, retention selects, cascading)
- §5: Long-polling endpoints — off by default, temporary capture with countdown

## Acceptance Criteria

### AC1: New LiveView route and active-nav repoint

The route `/admin/logs/trace-map` is created as a new LiveView (`Nebu.Admin.LogsLive`), replacing the stub route:
- Route key in `server/lib/nebu/web/router.ex` is live_dashboard `:protected` scope, `get "/logs/trace-map", LogsLive, :trace_map`
- The LiveView module `Nebu.Admin.LogsLive` (or alias) is extended with a new `mount/3` action for trace-map (distinct from the existing `:live` action for Live Stream)
- The `@active_nav` assign in the mount is set to `"logs-trace-map"` to satisfy the UX gate advisory A2 (correct sidebar highlight: Logs group expanded + Trace Map child active)
- The existing `/admin/logs` route remains pointing to `LogsLive` action `:live` with `@active_nav="logs-monitoring"` (no change to existing Live Stream page)
- Sidebar nav items (in `admin-sidebar-nesting` already done) show:
  - Logs (parent, expandable)
    - Live Stream (`logs-monitoring`) → `/admin/logs`
    - **Trace Map** (`logs-trace-map`) → `/admin/logs/trace-map` ← This story's route
    - War Room (`logs-war-room`) → `/admin/logs/war-room`

### AC2: Radial SVG map layout and hierarchy

The Trace Map page renders a radial SVG map with the following hierarchy:

**Geometry** (from spec §2, viewBox `-560 -400 1120 800`):
- **Center node ("nebu")**: circle r=52 at origin (0, 0). Label "nebu" inside. Click clears all filters.
- **Domain nodes**: circles r=38, positioned on a ring R1≈195 at fixed angles:
  - 4 domains: `/_matrix/client` (-48°), `/_matrix/media` (48°), `/admin` (132°), `/health` (-132°)
  - If domain count differs, distribute evenly around the ring (e.g., 3 domains → 120° spacing)
  - Domains are derived from `Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1` (REUSE existing heuristic; do not duplicate)
- **Satellite nodes** (endpoint route templates): circles r=24, positioned around each domain on a ring R2≈128, fanned over `min(130°, n·26°)` centered on the domain's outward angle
  - Satellites are observed route_template values, in first-observed order (from log store)
  - Edges: trimmed lines (node edge + 4px padding), color `--line` from CSS vars, opacity ~0.55

**SVG rendering**: Computed server-side in HEEx using a plain Elixir module (ADR-018/021 compliant, no client-side geometry logic). The module calculates (x, y) positions for each node given the hierarchy and renders them as SVG `<g>` elements with position attributes or transforms.

### AC3: Status model — 60-second sliding window, worst-child propagation, auto-heal

Per-node status is derived from a **60-second sliding window** of log events:
- Each node tracks request count, warning count, error count from entries in `LogStore` where `inserted_at > now() - 60 seconds`
- Status rule: `error > 0` → `error` state, else `warn > 0` → `warn` state, else `ok` state
- **Worst-child propagation**: A domain's status is the worst of its satellite children; the nebu node's status is the worst of its domains
- **Auto-heal**: As the 60-second window slides, old events age out. When the last warning/error exits the window, the node auto-heals to `ok` with no manual acknowledgment
- Updates happen every time a new log entry arrives (live-pushed via PubSub); the page's `handle_info/2` re-computes statuses and patches node classes

### AC4: Visual states for ok, warn, error, selected, off (logging-off), temp (temporary capture)

Six distinct visual states (from spec §2 table, Obsidian theme tokens from `server/assets/tailwind.config.js`):

| State | Meaning | Fill | Stroke | Badge | Extras |
|-------|---------|------|--------|-------|--------|
| **ok** | No errors/warnings in 60s window | `base-200` @ 35% opacity | `success` @ 55%, 1.5px stroke | none | label dimmed (recedes) |
| **warn** | Warnings in window, no errors | `#431407` (warn-bg) | `warning`, 2.5px + soft drop-shadow glow | ▲ with count | no animation |
| **error** | Errors in window | `#450a0a` (err-bg) | `error`, 3px + glow + pulse animation | ✕ with count | pulse on error state, disabled under `prefers-reduced-motion` |
| **selected** | Node is active in current filter | — (inherit state fill) | extra `primary` (orange) ring at r+7, 2.5px | none | selection is ORANGE ONLY, never used for health |
| **off** (logging-off) | Long-polling endpoint, logging disabled by default | `base-200` @ 15% opacity | `text-disabled`, 1.5px **dashed** stroke | "off" text | no status color; click enables temp capture (§5, out of scope) |
| **temp** (temporary capture) | Currently capturing (countdown running) | as status (ok/warn/err) | status color, **dashed** stroke | none | countdown mm:ss on the node; falls back to off when timer expires |

**Badge styling**:
- Warn badge: white circle with ▲ symbol, filled with warn color, positioned at top-right of node
- Error badge: white circle with ✕ symbol, filled with error color, positioned at top-right of node
- Badges use a small mono font; count shown inside (e.g., "3" for 3 errors)

**Status is NEVER conveyed by color alone**:
- Badges (▲/✕ + numeric count) make the alert explicit
- The ok state's dimmed label also serves as a cue
- Aria-labels on nodes expose status + counts to screen readers
- The always-visible legend (right column) explains all states

### AC5: Interactive filtering — click/Enter/Space to toggle node selection, OR-within-dimension multi-select

Clicking or pressing Enter/Space on any node (except nebu) toggles it as a stream filter:
- **Multi-select**: Multiple nodes can be active simultaneously; filters combine as OR (show entries matching ANY of the selected endpoints)
- **Domain convenience**: Clicking a domain node filters to that domain; a subsequent click elsewhere still includes the domain OR's matching children (satellites)
- **Clear all**: Clicking the nebu center node clears all filters
- **Filter chips**: Active filter selections appear as removable chips in the stream header (`endpoint=X&endpoint=Y&endpoint=Z` URL params)
- "Clear all" button in the stream header clears filters
- **Bookmarkable URLs**: Filter state lives in URL query params; users can paste a bookmarked URL and see the exact filtered view restored

**State storage**: Filter/selection state is in LiveView `@active_filters` (a map, keyed by dimension; e.g., `%{"endpoint" => ["/_matrix/client/v3/sync", "/_matrix/client/v3/send"]}`), driven by URL query params via `handle_params/3`:
- On mount, `handle_params/3` parses the incoming URL params and seeds `@active_filters`
- On node click, the phx-click handler updates the selection and calls `push_patch` with the new URL params
- **NEVER client-DOM-only state**: Node selection is NOT a CSS `:checked` pseudo-class or a JS variable; it is LiveView state that survives live traffic, crashes, and navigation (root cause of trace-map-filter-reset bug class)

### AC6: War-room banner across the top of the Trace Map view

While a war-room session is active (checked via `war_room_manager.ex`'s existing `is_session_active?/0`):
- A banner appears at the top of the trace-map view (above the map, below the toolbar)
- Banner contains:
  - Recording dot (animated red circle, `animation: recblink`)
  - Text: "War Room session active — capturing <user> · <elapsed>"
    - User: from the active session's `started_by` or `user_id` field (a user display name or Matrix ID)
    - Elapsed: live-updating clock showing mm:ss or hh:mm:ss
  - "Open War Room" button linking to `/admin/logs/war-room`
- **CSS/HTML only**: Banner is in the HEEx template; the elapsed timer is a simple `phx-hook` that updates text every 1 second (no inline JS per CSP constraints)
- When no session is active, the banner is hidden (`[hidden]` attribute or `display:none`)
- **Accessibility**: Banner has `role="status"` or `aria-live="polite"` if the session state changes dynamically (e.g., admin starts a session while the Trace Map is open)

### AC7: Tooltip on hover/focus — name, route, status, req/warn/err counts, CTA

When a node is hovered or focused (keyboard):
- A tooltip appears near the node (CSS-positioned, not a popoever; positioned via app.js hook to avoid going off-screen)
- Tooltip content:
  - **Name**: human-readable label (e.g., "Matrix Client", "sync", "nebu")
  - **Route**: route template or "all traffic" for the center node, mono font
  - **Status pill**: state + emoji/icon (🟢 ok, ▲ warn, ✕ error) or "off" text
  - **Counts**: "X requests · Y warnings · Z errors in the last 60s" (req/warn/err counts)
  - **CTA**: "Click to filter the stream" (or "Click to enable capture" for off-tier endpoints, out of scope)
- Tooltip hides on click or when focus leaves the node
- **No sensitive data** in the tooltip (route templates and counts only, never payloads/tokens/message content)

### AC8: Inspector panel (right column) — live stats, status pill, last 5 events, legend

The right side of the page contains a sticky column with two cards:

**Inspector Card** (top):
- **Heading**: "Node inspector"
- **Empty state** (on mount or when no node is selected): "Hover or select a node to see its live health details."
- **When a node is selected/focused**:
  - Node name (bold, large font)
  - Route template (mono, smaller, secondary color)
  - Status pill: background + text color matching state; text "Healthy" / "⚠ Warnings" / "✕ Errors"; status color
  - **Live stats** (updated on every log entry):
    - "X requests in the last 60s"
    - "Y warnings in the last 60s"
    - "Z errors in the last 60s"
  - **Last 5 events** (read-only list): newest first, each showing timestamp + level + message (truncated, no sensitive content)
- **Constraint**: The panel is BUILT once per inspected node; stat values update via `assign` changes, NOT by re-rendering the entire inspector (preserves form state for future logging controls per AC13 precedent from `admin-logs-retention-settings`)

**Legend Card** (always visible):
- **Heading**: "Legend"
- Static list of 6 rows (one per visual state):
  - ✓ Healthy — ok state (green circle, dimmed label explanation)
  - ⚠ ▲ Warnings in the last 60s — warn state (amber circle, glow explanation)
  - ✕ Errors in the last 60s — pulses — error state (red circle, pulse explanation)
  - 🟠 Selected as stream filter — selection ring (orange ring explanation)
  - ⊘ Long-polling endpoint — logging off by default; click to capture for 5 min — off state (gray dashed circle)
  - ⊘ (dashed) Dashed = temporary capture, falls back to off automatically — temp state
  - Plain text note: "Domains inherit the worst status of their satellites; nebu inherits the worst domain. Nodes heal automatically once the 60s window passes."

### AC9: Live stream panel (bottom) — resizable, level-filtered, leitstand shortcut

Below the map is a live-stream log panel:

**Layout**:
- Compact mono log lines: time | level (colored) | route | message
- Filter pills header row:
  - "Live stream" label (cap)
  - **Level filter pills** (DEBUG / INFO / WARN / ERROR), each `aria-pressed="true"/"false"`, clickable:
    - All active by default on mount
    - **Leitstand shortcut**: 
      - Click one pill when all are active → show ONLY that level (all others deactivated)
      - Click the sole active pill → restore all levels active
      - Click any other pill (when multiple active) → plain toggle
    - Visual states: inactive pills are dimmed text + line border; active pills are colored text + colored background matching the level color
  - Filter chips (from AC5): selected endpoints, removable, + "Clear all" button
- **Resizable drag handle** between map and stream:
  - A thin horizontal element (`role="separator"`, `aria-orientation="horizontal"`, `tabindex="0"`)
  - Visible affordance: small rounded bar centered on the handle
  - **Pointer drag**: `pointer-events: capture`, mouse-down drags to resize the stream height
  - **Keyboard**: ArrowUp/Down adjust height ±32px; Home key maximizes stream (minimize map); End key minimizes stream (maximize map); dblclick resets to default height (218px)
  - **Bounds**: clamp height to ~64px (min) ... viewport−140px (max)
- **Filtered content**: Log lines shown are filtered by:
  - Selected endpoints (AND across dimensions, OR within endpoint dimension)
  - Level filter (OR within levels: show if level is active)
  - First-in-first-out live stream: new entries appear at the bottom; autoscroll pauses on hover/focus
- **Stream state**: Level filter state lives in URL query params (`?level=DEBUG&level=WARN...`) or LiveView assigns, bookmarkable

### AC10: Accessibility — blocking requirements

Accessibility is a gating requirement per the spec (§8), not advisory:

**SVG nodes as focusable elements**:
- Each node (nebu, domains, satellites) is a focusable `<g role="button" aria-pressed="true"/"false">` element with `tabindex="0"`
- SVG requires explicit focus styling: a `<circle class="ring">` outline element inside each `<g>` that styles to primary orange on `:focus-visible`
- Tab order: natural document order (nebu, then domains in angle order, then satellites per domain)

**Aria-labels and status exposure**:
- Each node has an `aria-label` that includes: name + route + status (ok/warn/error/off) + counts
  - Example: "sync endpoint · /_matrix/client/v3/sync · errors · 3 errors · 12 warnings · 450 requests in last 60 seconds"
  - Example: "nebu · all traffic · healthy · 0 errors · 1 warning · 12000 requests"
  - Example: "keepalive endpoint · /admin/keepalive · logging off · click to capture for 5 minutes"
- The `aria-pressed` attribute reflects the node's selection state (true if filtered active, false otherwise)

**Live announcements** (aria-live):
- A region with `role="status" aria-live="polite"` announces new errors when they occur: "3 new errors detected in sync endpoint"
  - Throttled to prevent spam (e.g., one announcement per error, with 2-second debounce)
  - Announcement text: never includes sensitive content (endpoint name + count only)

**Keyboard navigation**:
- Tab moves focus through all focusable nodes
- Enter or Space on a node toggles its filter selection (calls the same handler as click)
- Escape on a tooltip (future) closes it
- ArrowUp/Down on the resizer adjusts stream height (AC9)

**Visible focus rings**:
- All focusable elements (nodes, resizer, level filter pills, chips) have a visible `:focus-visible` outline (primary orange, 2px, offset 2px)
- No focus ring removed by default (no `outline: none`)
- Outline is visible against both light and dark backgrounds (color contrast verified)

**Reduced motion**:
- Pulse animation on error nodes is disabled under `prefers-reduced-motion: reduce`
- Ping/expanding-ring animations on nodes are not shown under `prefers-reduced-motion`
- Blinking dots (war-room banner) are not animated

**WCAG AA contrast** (Obsidian theme tokens):
- All text meets WCAG AA 4.5:1 contrast ratio minimum
- Status colors (success, warning, error) are not the only differentiator; badges and icons accompany color
- Verified against the theme's CSS variables in `server/assets/tailwind.config.js`

**Screen reader testing**:
- Playwright tests use `getByRole`, `getByLabel`, and `getByText` (accessibility-first selectors) to verify screen-reader-exposed content
- No tests assume visual styling (e.g., "color: red means error"); assertions are on aria-labels and status attributes

### AC11: CSP-compliant client-side behavior via app.js hooks

Content Security Policy is `script-src 'self'` — no inline JavaScript. Client-only behavior goes through app.js hooks or `JS.push_event` commands:

**Tooltip positioning** (app.js hook):
- Hook name: `wire:TraceMapTooltip` (or similar)
- On node hover/focus, the hook repositions the tooltip element to avoid going off-screen
- Hook uses `element.getBoundingClientRect()` + DOM offset calculation, no inline `<script>` tags

**Resizer drag** (app.js hook):
- Hook name: `wire:StreamResizer`
- Pointer down/move/up event listeners (added via `el.addEventListener`, not inline `onmousedown`)
- Adjusts `--stream-height` CSS custom property or applies a transform/resize class
- ArrowUp/Down/Home/End keyboard handling for keyboard users

**Ping animations** (CSS):
- Expanding-ring animation on new log entries is pure CSS animation + `@keyframes` in the style block
- No JavaScript driving the animation

**Level filter leitstand shortcut** (phx-click):
- Level filter pills use `phx-click="toggle_level"` (or equivalent) to send the click to LiveView
- LiveView handler computes the shortcut logic (all→single, single→all, etc.) and patches the page with new filter state

**War-room banner timer** (app.js hook):
- Hook updates the elapsed-time text every 1 second via `setInterval`
- No inline event handlers on the banner itself; the hook attaches listeners on mount

### AC12: E2E Playwright test coverage for the new page and interaction scenarios

A new feature file `e2e/features/admin/logs-trace-map.feature` is created with BDD scenarios covering:

**Scenario 1: Map renders with domains and satellites**
- Given I'm logged in as an admin
- When I navigate to `/admin/logs/trace-map`
- Then I see the Trace Map page title
- And I see "nebu" center node
- And I see domain nodes for "Matrix Client", "Matrix Media", "Admin", "Health"
- And I see satellite nodes under each domain (e.g., sync, send, messages under Matrix Client)

**Scenario 2: Status colors reflect log entries**
- Given the Trace Map is loaded with live traffic
- When I inject a warning log entry for the `/sync` endpoint
- Then the sync satellite node changes to warn state (amber, ▲ badge)
- And the Matrix Client domain inherits warn state
- And nebu inherits warn state
- When I inject an error for the same endpoint
- Then the node changes to error state (red, ✕ badge, pulse animation visible)

**Scenario 3: Clicking a node toggles stream filter selection**
- Given the Trace Map is loaded
- When I click the "sync" satellite node
- Then the node shows a selection ring (orange)
- And `aria-pressed="true"` on the node
- And a filter chip appears in the stream header: "sync"
- And the log stream below shows only entries from `/sync`
- When I click another node ("send")
- Then both nodes show selection rings
- And two filter chips appear: "sync" and "send"
- And the stream shows entries from BOTH endpoints (OR logic)
- When I click "nebu" center node
- Then all selection rings disappear
- And all filter chips are removed

**Scenario 4: Keyboard navigation (Tab, Enter, Space)**
- Given the Trace Map is loaded
- When I press Tab
- Then focus moves to the first node (nebu)
- And a visible focus ring appears (primary orange)
- When I press Tab again
- Then focus moves to the next node (first domain)
- When I press Enter on a focused domain node
- Then the node is selected (selection ring, aria-pressed=true)
- And filter chip appears
- When I press Space on the same node
- Then the node is deselected (no ring, aria-pressed=false)
- And the filter chip is removed

**Scenario 5: Tooltip on hover and focus**
- Given the Trace Map is loaded
- When I hover over the "sync" node
- Then a tooltip appears with: name, route, status, counts, CTA text
- When I move mouse away
- Then the tooltip disappears
- When I Tab to the "sync" node and it receives focus
- Then the tooltip appears again
- When I press Escape (or Tab away)
- Then the tooltip disappears

**Scenario 6: Inspector panel shows live stats for selected node**
- Given the Trace Map is loaded
- When I click the "sync" node
- Then the inspector panel on the right shows:
  - "sync" node name (bold)
  - Route: `/_matrix/client/v3/sync` (mono)
  - Status pill: "Healthy" (or Warn/Error if there are logs)
  - "450 requests in the last 60s"
  - "1 warning in the last 60s"
  - "0 errors in the last 60s"
  - Last 5 events (list of timestamp + level + message)

**Scenario 7: War-room banner appears when session is active**
- Given a war-room session is active (started via the War Room page)
- When I navigate to the Trace Map page
- Then a red banner appears at the top with:
  - Recording dot (animated)
  - Text: "War Room session active — capturing @alice:nebu.example · 00:45"
  - "Open War Room" button
- When I click "Open War Room"
- Then I'm navigated to `/admin/logs/war-room`

**Scenario 8: Level filter leitstand shortcut**
- Given the Trace Map is loaded with all level filters active (DEBUG, INFO, WARN, ERROR)
- When I click the INFO level pill
- Then only INFO-level logs appear in the stream
- And only the INFO pill shows as active (colored)
- When I click INFO again (the sole active level)
- Then all levels become active again
- And all level pills appear colored

**Scenario 9: Resizable stream panel (drag handle)**
- Given the Trace Map is loaded
- When I drag the resizer handle downward
- Then the stream panel grows taller
- And the map shrinks
- When I drag upward
- Then the stream shrinks and map grows
- When I dblclick the resizer
- Then the stream resets to default height (218px)
- When I Tab to the resizer and press ArrowUp
- Then the stream height decreases by 32px
- When I press ArrowDown
- Then the stream height increases by 32px
- When I press Home on the resizer
- Then the stream is minimized (max height for map)
- When I press End
- Then the stream is maximized (min height for map)

**Scenario 10: Bookmarkable URLs with filter state**
- Given the Trace Map is loaded
- When I select "sync" and "send" endpoints via clicking
- Then the URL updates to: `/admin/logs/trace-map?endpoint[]=%2Fmatrix%2Fclient%2Fv3%2Fsync&endpoint[]=%2Fmatrix%2Fclient%2Fv3%2Fsend`
- When I copy the URL and reload in a new tab
- Then the page loads with both nodes pre-selected (rings + chips visible)
- And the stream is pre-filtered to those endpoints

**Also retiring/rewriting stale specs**:
- `e2e/features/admin/logs-monitoring.feature`: Scenarios asserting the OLD embedded Trace Map on `/admin/logs` must be updated or deleted (the embedded bubbles/tree are being removed; the Live Stream page keeps level/source filters, not endpoint trace-map)
- `e2e/features/admin/logs-trace-map-filter-persistence.feature` (if exists): Rewrite assertions to target the new `/admin/logs/trace-map` page, not the old embedded widget
- `e2e/features/admin/logs-trace-map-hierarchy.feature` (if exists): Same rewrite — the tree structure exists on the new dedicated page (if at all), not embedded
- Alternative: Delete the old feature files if the new `logs-trace-map.feature` fully supersedes them (simplest for this sprint)

### AC13: Retiring/repurposing embedded Trace Map components

The Trace Map is being removed from the `/admin/logs` Live Stream page to focus the page on its core function (live stream with level/source filters):

**TraceMapBubble** component:
- **Keep** if reused elsewhere (e.g., to style legend dots, or for future features)
- **Delete** if it only served the embedded widget on `/admin/logs`
- **Dev decision**: Document the choice in Dev Notes (e.g., "TraceMapBubble retained for legend styling in trace-map-leitstand; removed from logs_live.ex")

**TraceMapTree** component:
- Similar: keep if useful, delete if only served the embedded `/admin/logs` widget
- Note: The tree (hierarchical endpoint grouping) is also being removed from the Live Stream page; the Leitstand page has a simpler flat list of satellites per domain (not a nested disclosure tree)

**Impact on logs_live.ex**:
- Remove the render section that renders the flat bubble list (Endpoint dimension) and the tree (if it existed)
- Keep the level/source filter sections (these remain on the Live Stream page)
- Update the relevant tests to reflect the removal of endpoint filtering from `/admin/logs`

### AC14: Coordination note — UX Gate Advisory A1 (Configuration label duplicate)

The `admin-sidebar-nesting` story flagged an advisory A1: the Logs sidebar section has a child item **"Configuration"** (for log retention settings at `/admin/logs/config`), which duplicates the top-level **Configuration** section.

**Phil's decision (pending 2026-07-07)**:
- **Option A** (default if no decision yet): Rename the Logs child from "Configuration" to "Log Retention" (Phil's decision, 2026-07-07), keeping the navkey `logs-config` unchanged. This disambiguates the sections.
- **Option B**: Drop the Logs child entirely (no `/admin/logs/config` link in the Logs submenu); users access retention settings via the top-level Configuration section instead.

**This story must resolve A1** by:
- If Option A chosen: Update the Logs submenu's child label (template in `admin-sidebar-nesting`'s layout, or nav data structure) from "Configuration" to the renamed label
- If Option B chosen: Remove the `/admin/logs/config` child item from the Logs submenu (but `/admin/logs/config` route and the retention settings page itself remain; just no nav shortcut under Logs)
- Document the decision in Dev Notes under "UX Coordination"

**Current expectation**: DECIDED by Phil 2026-07-07: the label is "Log Retention" (navkey logs-config stays)

## Dev Notes

### Constraints from Spec §8 (Hard Implementation Constraints)

1. **Filter/selection state in LiveView assigns driven by URL query params** — never client-DOM-only state (root cause of trace-map-filter-reset bug):
   - State lives in `@active_filters` (LiveView assigns), keyed by dimension (e.g., `%{"endpoint" => [route1, route2]}`)
   - On mount, `handle_params/3` parses URL params and seeds state
   - On filter toggle, `push_patch/1` updates the URL, triggering `handle_params/3` again
   - Every page load/navigation restores state from the URL
   - This ensures state survives live traffic, page refreshes, crashes, and bookmarking

2. **CSP is `script-src 'self'`, no inline JS**:
   - Client-only behavior (tooltip positioning, resizer drag, ping animations) via app.js `phx-hook` pattern or `JS.dispatch` commands
   - No `<script>` tags in HEEx templates
   - No inline event handlers (e.g., `onmouseover="..."`)

3. **SVG server-side, positions computed in Elixir**:
   - A plain Elixir module (e.g., `Nebu.Admin.TraceMapGeometry`) computes (x, y) for each node
   - SVG is rendered in HEEx with the computed positions (no client-side geometry)
   - LiveView patches update node classes/counters, not positions

4. **Accessibility is blocking**:
   - Nodes are focusable `role="button" aria-pressed` elements with status+counts in aria-labels
   - Aria-live announcements for new errors (throttled)
   - Visible focus rings; prefers-reduced-motion disables pulse/pings
   - WCAG AA contrast per Obsidian theme tokens
   - Playwright tests use `getByRole`/`getByLabel` (accessibility-first)

5. **No sensitive data on the map, tooltips, or stream**:
   - Route templates and counts only; never payloads, tokens, message content
   - Inspector shows only endpoint name/route/status/counts, no message bodies

6. **E2E coverage must grow with every UI story** (pipeline CI gate)

### Technical Architecture Notes

**Status Calculation (handle_info/2)**:
- Every time a new log entry arrives via PubSub, the page's `handle_info({:operational_log_entry, entry}, socket)` handler:
  1. Extracts the endpoint and level from the entry
  2. Finds the corresponding node in the map
  3. Increments the appropriate counter (request, warn, or error) for the 60-second window
  4. Re-computes the node's status and its ancestors' (domain, nebu)
  5. Calls `assign(:node_statuses, updated_map)` to trigger a patch
  6. HEEx renders the updated classes on affected nodes (`:ok`, `:warn`, `:error`)

**Window Management**:
- Nodes store a rolling buffer of timestamps for each level/count
- Every 1-5 seconds, a server-side cleanup removes entries older than 60 seconds
- Alternatively: compute the window on-the-fly from LogStore queries (simpler, but may be slower for large volumes)

**Filter Interaction Flow**:
1. User clicks node (phx-click handler)
2. Handler extracts the node key and toggles it in `@active_filters["endpoint"]`
3. Handler calls `push_patch(path: ..., params: new_filters)` to update URL
4. `handle_params/3` is triggered with the new URL
5. Assigns are updated, template re-renders, filter chips + stream update
6. Live entries arriving during all of this flow are filtered by the current `@active_filters` before being rendered

**Log Stream Filtering**:
- Entries are filtered by both endpoint selection AND level filter before rendering
- Filtering logic in `handle_info/2` and/or a helper function (e.g., `apply_filters/2`)
- Only entries matching the current filter are appended to the stream

### Files to Create/Modify

**Create**:
- `server/lib/nebu/admin/trace_map_geometry.ex` — Elixir module computing radial SVG positions
- `server/lib/nebu/admin/logs_live/trace_map.ex` (or inline in `logs_live.ex`) — LiveView mount/render for `/admin/logs/trace-map` action
- `server/lib/nebu/admin/logs_live/trace_map_components.ex` (optional) — Helper components for map rendering, inspector, legend
- `server/priv/static/assets/trace-map.hook.js` (optional) — App.js hook for tooltip positioning, resizer drag, timer updates

**Modify**:
- `server/lib/nebu/web/router.ex` — Add `/admin/logs/trace-map` route
- `server/lib/nebu/admin/logs_live.ex` — Extend mount/render to handle `:trace_map` action (or create a separate module)
- `server/lib/nebu/admin/layouts.ex` (or nav data structure) — Resolve A1 (rename "Configuration" child label or drop it)
- `server/lib/nebu/admin/logs_live.ex` (live_stream action) — Remove embedded TraceMapBubble/TraceMapTree rendering, keep level/source filters
- `server/test/nebu/admin/logs_live_test.exs` — Add tests for trace-map-leitstand mount, filtering, status updates
- `e2e/features/admin/logs-trace-map.feature` — New feature file (scenarios 1-10 above)
- `e2e/features/admin/logs-monitoring.feature` (if exists) — Delete or rewrite stale embedded trace-map specs
- `e2e/features/admin/logs-trace-map-filter-persistence.feature` (if exists) — Rewrite for new page, or delete
- `e2e/features/admin/logs-trace-map-hierarchy.feature` (if exists) — Rewrite for new page, or delete

### Known Challenges & Design Decisions

1. **Window slide-in efficiency**: Computing the 60-second window on every incoming entry could be slow for high-volume logs. Consider:
   - Option A: Keep a rolling buffer of `{timestamp, level}` tuples per node, prune on a timer
   - Option B: Query LogStore's database for entries in the window (trades latency for simplicity)
   - Chosen: **Option A for now** (simple, in-memory, fast); if profiling shows DB is faster, switch to Option B

2. **Legend card always visible**: The inspector toggles between a "no selection" message and node details. The legend is below, always visible. Together they form a sticky right-column sidebar. Layout: `flex flex-col gap-X` with inspector taking `flex-1` and legend fixed height at bottom.

3. **A1 resolution pending**: The label rename decision impacts the sidebar template. DECIDED: label is "Log Retention" (Phil, 2026-07-07); navkey logs-config unchanged.

### Testing Strategy

**Unit tests** (`logs_live_test.exs`):
- Mount with no filters → all nodes render
- Mount with URL params `?endpoint=/sync` → sync node is selected
- Inject log entry → counters update, status propagates up
- After 61 seconds, entry ages out → status heals
- Click node → filter applied, URL updated, re-render
- Click filtered node again → filter removed, URL updated
- Click nebu → all filters cleared

**Integration tests** (same file):
- Full-stack: mount → live traffic → filter → verify stream content matches endpoint selection
- War-room session active/inactive → banner appears/disappears
- Level filter shortcut: all active → click one → only one active → click that one → all active again

**E2E tests** (`logs-trace-map.feature`):
- All 10 scenarios above
- Keyboard navigation (Tab, Enter, Space, Arrow, Home/End)
- Resizer interaction (pointer drag, keyboard)
- Tooltip appearance/disappearance
- Bookmarkable URLs
- (Pending follow-up): long-polling off-tier endpoints, temporary capture timer

### Predecessor Story Intelligence

**From `trace-map-filter-reset-bugfix` (completed 2026-07-06)**:
- Root cause of filter reset: re-renders wiping client-side filter state (`display:none` on rows)
- Solution: **filter state in URL query params**, not DOM classes
- Lesson: Use `push_patch` + `handle_params/3`, not client-side `phx-update`

**From `trace-map-hierarchy` (completed 2026-07-06)**:
- Hierarchical tree rendering pattern (domain parent, endpoint children)
- `TraceMapTree.domain_for_endpoint/1` is the canonical domain heuristic
- Accessibility: `aria-expanded` on disclosure buttons, natural Tab order for nested items
- Lesson: Reuse existing classification logic; don't reinvent the wheel

**From `admin-sidebar-nesting` (completed 2026-07-07)**:
- Navigation state: `@active_nav` assign, matched against nav item keys
- Nested nav pattern: parent disclosure button + child list
- Lesson: Logs section now has 3 children; Trace Map is one of them; set `@active_nav="logs-trace-map"` to highlight correctly

### Known Gaps (Out of Scope, Follow-up Story)

**`trace-map-node-controls` story** (not this one) will implement:
- Inspector logging controls (min level select, retention select, cascading to domain/nebu)
- Long-polling endpoints off by default (gray, dashed, "off" text, no logs collected)
- Temporary capture: click enables 5-minute logging, countdown on node + inspector, auto-fallback to off after timer

### CSP & Security Compliance

- **script-src 'self'**: All client interactivity via phx-hook pattern, no inline scripts
- **No sensitive data**: Route templates + counts only, never payloads/tokens/message bodies (complies with "No Sensitive Data in Logs Law" from MEMORY.md)
- **No raw user input**: Node names come from hardcoded domain list or observed routes (no XSS surface)
- **RLS/auth**: Filter state in URL params is readable by the user; filtering is presentation-only (no access-control enforcement on the stream itself — that's handled by LogStore's existing RLS policy)

### Accessibility Compliance Summary

- ✓ Native button elements (role=button) for all interactive nodes
- ✓ aria-pressed for toggle state
- ✓ aria-expanded for disclosure (future: domain grouping)
- ✓ aria-label for all nodes (name + route + status + counts)
- ✓ aria-live for error announcements
- ✓ Visible :focus-visible rings on all focusable elements
- ✓ prefers-reduced-motion disables animations
- ✓ WCAG AA contrast for all text + status colors
- ✓ Keyboard: Tab, Enter, Space, Arrow, Home/End
- ✓ Playwright tests use getByRole/getByLabel

## Questions & Follow-ups

None at this time — the design spec and dummy are comprehensive and approved by Phil. Implementation guidance is clear; constraints are explicit. Ready to start dev-story cycle.

## Story Amendments (2026-07-07, pipeline test-review)

- **AC5/AC12 URL format:** multi-select filter query params use bracket-array form
  (`?endpoint[]=X&endpoint[]=Y`) — Plug's query decoding is last-wins on repeated bare
  keys, so the originally written literal form cannot round-trip. Tests pin the
  bracket-array contract; this amendment approves it.
- **AC12 Scenario 4 wording:** "first Tab focuses the nebu node" is not achievable by an
  accessible implementation (sidebar chrome precedes main content in document order).
  Amended to: focus reaches the nebu node via sequential keyboard navigation (test may
  use a tab-until-focused loop or programmatic focus helper); focus-ring, Enter and
  Space assertions unchanged.
- **AC4 deferral note:** the "logging off" and "temp capture" visual states are
  implemented in the follow-up story trace-map-node-controls (no endpoint is off-tier
  classified by this story); the always-visible legend still enumerates all 6 states.
- **AC12 log injection:** WARN/ERROR entries for E2E are seeded via direct DB insert
  into operational_logs (fixture; in-repo raw-SQL precedent from logs_live_test.exs) —
  NO test-only HTTP routes in server code.

## Dev Agent Record

### Implementation Plan / Completion Notes (2026-07-07, dev-story cycle 0)

- **Three new modules** (per the ATDD-pinned contracts):
  - `Nebu.Admin.TraceMapGeometry` (plain module, ADR-018/021) — canonical
    4-domain fixed angles (−48/48/132/−132) with even-distribution fallback
    starting at −90°; satellite fan `min(130°, n·26°)`; `polar_to_cartesian/2`
    (SVG convention, no Y-flip); `trim_edge/2` (node radius + 4px per end);
    `layout/1` (nebu at origin r=52, domains R1=195 r=38, satellites R2=128
    r=24 relative to their OWN domain). `domain_angles([])` added (empty map
    on first mount — the 360/0 division the tests didn't cover).
  - `Nebu.Admin.LogsLive.TraceMapStatus` (pure module) — AC3's 60 s sliding
    window as pure functions of `(state, now_ms)`; `worst/1` for worst-child
    propagation; auto-heal falls out of purity (no ack/heal operation exists).
    `record/3` self-prunes aged events so per-node memory stays bounded with
    no cleanup timer.
  - `Nebu.Admin.LogsLive.TraceMap` (LiveView, `/admin/logs/trace-map`,
    `@active_nav "logs-trace-map"`) — a SEPARATE module from `Nebu.Admin.LogsLive`
    (AC1's "(or alias)" branch), because it exports `handle_params/3` (AC5's
    URL-driven filter state), which would break every `live_isolated/3` test
    of the shared LogsLive module. Selection state: `@selected` seeded from
    bracket-array `?endpoint[]=…` params in `handle_params/3`; every node
    click round-trips `toggle_node`/`clear_filters` → `push_patch` →
    `handle_params/3` (story amendment: bracket-array, not bare repeated keys).
    Status events recorded per node (satellite + domain + nebu) at ingest;
    parents' rendered status uses `TraceMapStatus.worst/1`. A 1 s server tick
    advances `@now_ms` so auto-heal is visible without traffic. War-room
    status polled every 2 s (both directions — banner appears if a session
    starts while the page is open), guarded behind `Process.whereis(Nebu.Repo)`
    like all DB reads (mount stays DB-free for unit tests).
- **Domain grouping REUSES `TraceMapTree.domain_for_endpoint/1` /
  `group_endpoints_by_domain/1`** (hard constraint; never duplicated).
  Bookmarked selections for not-yet-observed endpoints render as nodes
  immediately (a key that IS its own domain, e.g. `/admin`, renders as a
  domain-only node, never a synthetic satellite).
- **CSP (`script-src 'self'`)**: one `TraceMapLeitstand` phx-hook in
  `server/priv/static/assets/app.js` owns ALL client-only behavior: Enter/Space
  activation of SVG nodes (SVG `<g role="button">` has no native keyboard
  activation — keydown dispatches the same bubbling click phx-click handles),
  tooltip show/hide/position (content from server-rendered `data-tooltip-*`,
  built with `textContent` only), resizer (pointer capture drag, ArrowUp/Down
  ±32, Home/End, dblclick→218px, clamp 64…column−140), stream autoscroll
  (paused on hover/focus), war-room elapsed clock, decorative status-transition
  pings (elements created by JS, animation pure CSS). No inline JS/`on*=`
  anywhere (pinned by the AC11 test).
- **Visual states** in `server/assets/css/app.css` (`tm-*` classes, Obsidian
  token values, per the dummy): ok/warn/error node cores, orange-only
  selection ring + focus-visible outlines, ▲/✕ badges with counts (never
  color-alone), tooltip, resizer, legend dots for all 6 states (off/temp are
  legend-only this story, per the amendment), `@keyframes tm-errpulse` /
  `tm-ping` / `tm-recblink` all disabled under `prefers-reduced-motion`.
  `make assets` re-ran; new utilities verified in the rebuilt app.css.
- **AC13 retirement**: `logs_live.ex` dropped the Endpoints section
  (TraceMapTree render, endpoint chips, `toggle_domain`, `@domain_overrides`,
  `@endpoint_order`/`@endpoint_counts`, "endpoint" from `@filter_dimensions`).
  Levels/Sources sections unchanged. **Component decision: `TraceMapTree` and
  `TraceMapBubble` modules are KEPT** — TraceMapBubble still renders the
  Levels/Sources bubbles (and the logs-config page), TraceMapTree's
  `domain_for_endpoint/1`/`group_endpoints_by_domain/1` are the canonical
  domain heuristic the Leitstand reuses (its `endpoint_tree/1` component is
  now render-unused but its component tests keep passing; flagged for a
  future cleanup story rather than deleted mid-story).
- **AC14 (UX advisory A1)**: Logs child label "Configuration" → **"Log
  Retention"** (Phil's decision 2026-07-07); navkey `logs-config` and the
  `/admin/logs/config` route unchanged. No sidebar-nesting test asserted the
  old label (they pin keys only), so no test updates were needed for this.
- **Test updates (documented deviations from staged ATDD, all
  intent-preserving)**:
  - `trace_map_leitstand_test.exs`: (a) `viewBox` lookup → `viewbox` — Floki's
    HTML tokenizer (lazy_html) lowercases ALL attribute names on parse, so the
    staged camelCase lookup was unsatisfiable against ANY rendered output (the
    template renders the correct camelCase `viewBox`); (b) the "deactivating
    WARN" stream-content test clicked a pill while all 4 levels were active,
    which per AC9's leitstand shortcut (pinned by the same file's own shortcut
    tests) isolates that level — the opposite of its assertions; rewritten to
    click INFO (shortcut-isolate), same assertions unchanged.
  - `trace_map_geometry_test.exs` / `trace_map_status_test.exs`: `apply/3`
    RED-phase wrappers converted to direct calls (test-review recommendation).
  - `logs_live_test.exs` (AC13, count-preserving rewrites — collected total
    stays 1496): AT1 endpoint-bubble assertions dropped; the URL-seed,
    push-op, toggle-round-trip, and both popstate/sync_filters tests moved
    from the endpoint dimension to level/source; the trace-map-hierarchy AT6
    became "comma-joined ?level=error,warning multi-select URL seed"; AT8
    became the retirement-era zero-regression test (no domain-group/tree
    markup remains + surviving bubbles still click-to-filter); MINOR-3 became
    a NEW chip-"×"-remove server-round-trip test (covers
    `handle_event("remove_filter", ...)`, previously untested directly).
  - E2E: `logs-trace-map-hierarchy.feature` + `logs-trace-map-filter-persistence.feature`
    (+ steps) DELETED (AC12's "delete if superseded" option — the tree
    interaction pattern is retired outright; filter persistence/URL state is
    superseded by logs-trace-map.feature Scenarios 3/10 on the new page).
    The shared "the page URL contains the query parameter" step moved into
    `logs-trace-map.steps.ts`. `logs-monitoring.feature`: Endpoints
    bubble-section assertion + endpoint-bubble-click scenario removed
    (Levels/Sources + detail-panel scenarios untouched). `@pending-feature`
    removed from all 10 logs-trace-map.feature scenarios; `npx bddgen` ok.
- **Deviation flagged for PM/review — resizer Home/End**: the staged e2e
  contract (logs-trace-map.feature Scenario 9) pins Home = minimize stream /
  End = maximize stream; AC9's prose says the opposite. Implementation follows
  the executable spec (the staged, test-reviewed feature file).
- **Security notes for Kassandra**: no sensitive data on map/tooltips/labels/
  announcer (route templates + counts only; the stream/inspector show the
  same already-redacted `message` field the Live Stream page shows);
  `toggle_node` accepts arbitrary key strings but they only ever land in the
  URL/chips as HEEx-escaped text and in presentation-only filtering (same
  trust model as the pre-existing bookmarkable filter URLs); no new routes
  outside the `live_session :admin` gate; no test backdoors (E2E WARN/ERROR
  seeding is a direct DB insert in e2e/fixtures/db.ts, per the amendment).
- **Verification**: full suite `make test-unit-elixir`: **1496 passed,
  0 failures** (2 skipped, 368 integration-excluded), `--warnings-as-errors`
  clean — all 81 previously-red ATDD tests green, zero regressions.
  `node --check` clean on app.js; `npx bddgen` ok. (No `.formatter.exs`
  exists in this repo — no format gate to run.)

## File List

- server/lib/nebu/admin/trace_map_geometry.ex (new — AC2 radial geometry, plain module)
- server/lib/nebu/admin/logs_live/trace_map_status.ex (new — AC3 60s-window status model, pure module)
- server/lib/nebu/admin/logs_live/trace_map.ex (new — the Leitstand LiveView, AC1/AC2/AC4–AC11)
- server/lib/nebu/admin/router.ex (modified — /logs/trace-map repointed to LogsLive.TraceMap)
- server/lib/nebu/admin/layouts.ex (modified — AC14 logs-config label "Log Retention")
- server/lib/nebu/admin/logs_live.ex (modified — AC13 Endpoints dimension retired; level/source only)
- server/priv/static/assets/app.js (modified — TraceMapLeitstand phx-hook, AC7/AC9/AC10/AC11)
- server/assets/css/app.css (modified — tm-* visual states, keyframes, reduced-motion; cycle 2: V2/A7 badge fixes)
- server/priv/static/assets/app.css (regenerated — make assets)
- server/assets/tailwind.config.js (modified, cycle 2 — status-error-text token, UX gate V5)
- server/test/nebu/admin/trace_map_geometry_test.exs (modified — apply/3 → direct calls)
- server/test/nebu/admin/logs_live/trace_map_status_test.exs (modified — apply/3 → direct calls)
- server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs (modified — viewbox lookup fix; AC9 stream test shortcut-consistency fix)
- server/test/nebu/admin/logs_live_test.exs (modified — AC13 count-preserving rewrites, see Dev Agent Record)
- e2e/features/admin/logs-trace-map.feature (modified — @pending-feature removed, green-phase header)
- e2e/step-definitions/admin/logs-trace-map.steps.ts (modified — URL-param step moved in)
- e2e/features/admin/logs-monitoring.feature (modified — AC13 endpoint scenarios removed)
- e2e/step-definitions/admin/logs-monitoring.steps.ts (modified — endpoint-bubble steps removed; cycle 1: deterministic row seed + row-click sync)
- e2e/step-definitions/admin/war-room.steps.ts (modified, cycle 1 — start-step socket sync)
- e2e/fixtures/nebu-fixtures.ts (modified, cycle 1 — export After hook)
- e2e/features/admin/logs-trace-map-filter-persistence.feature (deleted — superseded, AC12)
- e2e/step-definitions/admin/logs-trace-map-filter-persistence.steps.ts (deleted)
- e2e/features/admin/logs-trace-map-hierarchy.feature (deleted — retired pattern, AC12)
- e2e/step-definitions/admin/logs-trace-map-hierarchy.steps.ts (deleted)
- e2e/fixtures/db.ts (staged by ATDD; cycle 1 — ensureOperationalLogRow, endActiveWarRoomSessions)
- docs/stories/enhanced-logging/trace-map-leitstand.md (modified — status/record)

### Dev cycle 1 (2026-07-07) — CI-gate E2E follow-up (1/10 → 10/10 live-stack PASS)

Root causes found by debugging against the running stack (all fixes are
implementation/synchronization — no assertion was weakened):

1. **Recorded traffic invisible to the map (5 scenarios)**: `RequestLogger`
   logs every hit at INFO, but INFO persistence is policy-gated
   (`log_collect_info`, default FALSE) — entries are always broadcast but,
   under the default policy, never written to `operational_logs`. Scenarios
   record traffic and THEN navigate, so the page's mount-time history read
   could never see it (the pre-existing logs-monitoring detail-panel
   scenario had the same latent dependency and also failed on a
   default-policy stack). Fix: the shared "a request to {string} has been
   recorded" step now makes its own precondition deterministic —
   `ensureOperationalLogRow` (e2e/fixtures/db.ts) inserts the row the
   request WOULD have persisted (same real x-request-id/route, INSERT …
   WHERE NOT EXISTS so an INFO-enabled stack gets no duplicate); same
   approved DB-seed mechanism as the story amendment's WARN/ERROR seeding.
2. **Interactions racing the LiveSocket (keyboard/pills/resizer/tooltip)**:
   the admin UI uses a THROTTLED LONGPOLL transport — the socket connects
   (and the TraceMapLeitstand hook mounts) a few seconds after first paint;
   clicks/keys fired before that silently no-op on the static render.
   Verified interactively that Enter/pills/drag all work once connected.
   Fix: the hook sets `window.__nebuTraceMapHookReady` in mounted(); every
   interaction step first awaits it (`awaitLeitstandReady`) — Playwright
   actionability synchronization, not an assertion change. The same wait
   (via the generic `[data-phx-main].phx-connected` class) was added to the
   war-room start step and the logs-monitoring row-click step, whose
   phx-submit/phx-click had the same race.
3. **War-room banner "visible" while hidden + no session**: (a) the banner
   div carried the Tailwind `flex` utility, which beats the UA's
   `[hidden] {display:none}` in the cascade (the known flex-beats-hidden
   trap) — the "hidden" banner still rendered, so toBeVisible passed
   vacuously and the real failure surfaced as missing text. Fixed with a
   `.tm-wr-banner` class owning `display:flex` + a `[hidden]` override in
   app.css. (b) The session itself was never created (the start submit
   raced the socket — fix 2). (c) The scenario's real session now gets
   cleaned up via an `After({tags: '@ac6-war-room-banner'})` SQL hook
   (`endActiveWarRoomSessions`) so war-room.feature's own start can never
   hit the exactly-one-active-session conflict.
4. **Focus stability insurance**: map nodes now carry a stable DOM `id`
   (`tm-node-<base64url(key)>`) so LiveView's DOM patching keys them in
   place and keyboard focus survives Enter/Space selection patches.

Verified: `logs-trace-map.feature` **10/10 PASS** + rewritten
`logs-monitoring.feature` **3/3 PASS** (combined 13 passed, 1.1m) and
`war-room.feature` **6/6 PASS** against the live stack (`make redeploy`ed
image); `make test-unit-elixir` **1496 passed, 0 failures** re-confirmed;
`npx bddgen` ok.

Cycle-1 file changes: server/lib/nebu/admin/logs_live/trace_map.ex (node
dom_id, banner tm-wr-banner class), server/assets/css/app.css +
server/priv/static/assets/app.css (tm-wr-banner hidden override),
server/priv/static/assets/app.js (hook readiness marker),
e2e/fixtures/db.ts (ensureOperationalLogRow, endActiveWarRoomSessions),
e2e/fixtures/nebu-fixtures.ts (export After),
e2e/step-definitions/admin/logs-trace-map.steps.ts (awaitLeitstandReady +
After cleanup hook), e2e/step-definitions/admin/logs-monitoring.steps.ts
(deterministic seed + row-click sync),
e2e/step-definitions/admin/war-room.steps.ts (start-step sync).

### Dev cycle 2 (2026-07-07) — UX gate fixes (5 violations + advisories A2–A5, A7)

- **V1 (aria-live misuse)**: the war-room banner is no longer a live region
  (it contains the per-second elapsed clock; `role="status"` is implicitly
  atomic → re-announcement every second). Session start/stop transitions are
  now announced as one-shot sentences through the page's existing sr-only
  announcer (`handle_info(:refresh_war_room_status)` compares previous vs
  current status). The AC6 contract test that pinned role/aria-live ON the
  banner was updated with a documented UX-gate-V1 reason (now asserts the
  banner is NOT a live region).
- **V2 (badge contrast)**: error-badge count text `#ffffff` → `#000000`
  (the theme's own error-content token; 5.58:1 on the error red — the dummy's
  white-on-red has the same flaw, AC10's 4.5:1 hard gate overrides it).
- **V3 (disabled-token misuse)**: `text-text-disabled` (#4b5563, 2.35:1/
  1.94:1) replaced with `text-text-secondary` on all operable/informative
  content: inactive level pills, stream timestamps, DEBUG level text,
  inspector empty state, empty-events dash, legend propagation note.
- **V4 (separator Name/Role/Value)**: the resizer now carries
  `aria-valuemin="0"/aria-valuemax="100"/aria-valuenow` (stream height as a
  percentage of its allowed range); the server renders an approximate
  initial value, the hook recomputes it on mount and inside every
  `setStreamHeight` (drag, arrows, Home/End, dblclick).
- **V5 (text on status-error-bg)**: new theme token `status-error-text`
  (#fca5a5, the dummy's pairing, 8.51:1) used for the active ERROR pill, the
  inspector error status pill, and the banner's Open War Room link (was
  #ef4444 at 4.29:1).
- **A2**: error announcements now include the windowed count and timestamp
  ("3 new errors detected in <route> at HH:MM:SS") — matches AC10's example
  and guarantees a DOM change on repeated bursts (identical text would never
  re-fire a polite region).
- **A3**: nebu no longer carries `aria-pressed` (clear-all action, not a
  toggle). No ExUnit test pinned it on nebu; the test-file moduledoc note
  was updated.
- **A4**: level pills / chips / clear-all now use real
  `focus-visible:outline*` utilities (forced-colors safe) instead of
  `focus:outline-none` + box-shadow rings, consistent with the SVG nodes.
- **A5**: tooltip is `aria-hidden="true"` (it duplicates node aria-labels);
  the tabbable stream body got `aria-label="Log stream lines"` (deliberately
  NOT `role="log"` — that role's implicit polite live region would announce
  every incoming line on a high-volume stream; documented in the template).
- **A7**: badge text 8px → 9.5px (dummy's size), alongside V2.
- **Regression found & fixed while verifying (duplicate DOM ids)**: cycle 1's
  node `dom_id` was key-only, but "/health" is simultaneously a domain key
  AND a satellite key → two elements shared one id, corrupting LiveView's
  id-keyed DOM patching for exactly those nodes (observed live: the /health
  domain's toggle patch never applied; order-dependent, hence the flaky
  keyboard scenario). Ids are now kind-prefixed
  (`tm-node-<kind>-<base64url(key)>`).
- Out of scope per coordinator: A1 (inspector on focus/hover — deferred to
  trace-map-node-controls), A6 (accepted), A8 (story prose amended by the
  coordinator).
- Verified: `make test-unit-elixir` **1496 passed, 0 failures**;
  `make assets` re-ran (status-error-text token in the built CSS);
  logs-trace-map.feature **10/10 PASS** against the redeployed live stack
  (V1/V4/A4 touch live behavior).

### Dev cycle 3 (2026-07-07) — code-review fixes (M1 + m1 + m2 + i1)

- **M1 (double-count on single-segment routes)**: `ingest_entry/3`'s node
  key list `[route, domain_for_endpoint(route), "nebu"]` is now
  `Enum.uniq/1`-ed — `domain_for_endpoint("/health") == "/health"`, so every
  /health event previously recorded TWICE into that node's window state
  (badge counts, tooltip counts, inspector stats, aria-labels all read 2x).
  New regression test drives one warning through the live PubSub ingest path
  and asserts the badge shows exactly "1" (not "2"), the aria-label says
  "1 warning", and the inspector stats read requests=1/warnings=1.
- **m1 (duplicate URL values)**: `normalize_selected/1` now `Enum.uniq/1`s —
  a crafted/bookmarked `?endpoint[]=X&endpoint[]=X` URL previously seeded
  two identical chips, and `toggle_node`'s `List.delete/2` removed only one
  per click. New test: duplicated URL value → exactly one chip, fully
  cleared by a single toggle click.
- **m2 (V1 announcer transitions untested)**: new integration-tagged test
  (follows the existing `:integration` pattern in the same file) drives the
  view's own `:refresh_war_room_status` poll message deterministically:
  session start announces "War Room session started — capturing <user>" via
  the sr-only announcer (banner un-hides on the same poll), stop announces
  "War Room session ended" (banner hides again). Includes shared-DB hygiene
  (pre-stops any leftover session and syncs the view to :none first).
- **i1 (stale comment)**: `logs_live.ex`'s two remaining comment references
  to the retired `@endpoint_counts` assign updated with an AC13 note.
- Not changed (accepted/deferred per the review): i2 (per-render view-model
  cost — accepted Option A tradeoff), i3 (/health rendering as both domain
  and satellite — matches the approved dummy), i4 (route location), i5
  (prune-on-record memory edge).
- Verified: `make test-unit-elixir` **1498 passed, 0 failures** (2 new unit
  tests; the m2 test is integration-tagged and runs in the CI integration
  gate); story E2E **10/10 PASS** against the redeployed live stack (the M1
  fix touches the ingest path).

## Change Log

- 2026-07-07 (dev-story cycle 0): Implemented the Trace Map Leitstand — radial
  SVG health map at /admin/logs/trace-map (server-side geometry, 60 s sliding
  status window with worst-child propagation + auto-heal, URL-driven endpoint
  multi-select via push_patch/handle_params, war-room banner, tooltip data,
  inspector + always-visible 6-state legend, resizable level-filtered live
  stream with leitstand shortcut, throttled aria-live error announcer);
  retired the embedded Endpoints dimension from /admin/logs (AC13); renamed
  the Logs sidebar child to "Log Retention" (AC14). Full suite 1496 passed /
  0 failures; @pending-feature removed from all 10 E2E scenarios; bddgen ok.
  Status → review.
- 2026-07-07 (dev-story cycle 1, CI-gate E2E follow-up): fixed the four live-
  stack root causes (policy-gated INFO persistence made deterministic via
  DB-ensured rows; longpoll-connect races synchronized via hook-readiness/
  phx-connected waits; banner flex-beats-hidden cascade bug; war-room session
  scenario cleanup + stable node DOM ids). logs-trace-map.feature 10/10,
  logs-monitoring.feature 3/3, war-room.feature 6/6 against the live stack;
  unit suite re-confirmed 1496/1496.
- 2026-07-07 (dev-story cycle 2, UX gate): fixed all 5 blocking violations
  (banner live-region misuse; badge/text contrast V2/V3/V5 via theme tokens
  incl. new status-error-text; resizer aria-valuenow) + advisories A2-A5/A7,
  and a duplicate-DOM-id patch-corruption regression on the dual
  domain/satellite "/health" key found during live verification. Unit suite
  1496/1496; story E2E 10/10 on the redeployed stack.
- 2026-07-07 (dev-story cycle 3, code review): M1 dedup of ingest node keys
  (single-segment routes no longer double-count) + regression test; m1
  Enum.uniq on URL-seeded selection + test; m2 integration test for the V1
  war-room announcer transitions; i1 stale @endpoint_counts comments updated.
  Unit suite 1498/1498; story E2E 10/10 on the redeployed stack.
- **AC9 Home/End amendment (2026-07-07, UX gate A8):** Home = minimize stream,
  End = maximize stream — as pinned by the test-reviewed feature file; the original
  AC9 prose stating the opposite is superseded.
