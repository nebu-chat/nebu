---
id: war-room-dedicated-page
title: "War Room as a dedicated sub-page with session list, scoping, and historical view"
epic: enhanced-logging
status: done
security_review: required
matrix: false
ui: true
created: 2026-07-06
---

# War Room as a Dedicated Sub-Page

## Story

**As** a Nebu platform operator,
**I want** a dedicated `/admin/logs/war-room` page that lists active and historical War Room sessions with full session details, and the ability to drill down into a session to view all logs captured by that session, rather than accessing War Room only as an embedded panel on `/admin/logs`,
**so that** I can discover, review, and investigate diagnostic sessions without searching through a crowded monitoring page, pre-scope a session before starting it to avoid capturing unwanted high-frequency traffic, and maintain a permanent audit trail of which sessions captured what and when.

## Background

The `war-room-mode` story (delivered) implemented War Room as an embedded inline panel on `/admin/logs`: a form with `max_entries`/`max_duration_s` inputs and a "🚨 Start War Room" button, backed by the `war_room_sessions` table and `Nebu.Admin.WarRoomManager` API. The operator who requested this feature reviewed the shipped version in production and found two usability gaps:

1. **Discoverability and session review**: The panel is cramped on an already-full monitoring page. Operators need a proper list view of all sessions (active + historical ended) to review which sessions exist, who started them, what scope/filters were applied, and when. This also creates an audit trail that survives the next monitoring-page reload or admin logout.

2. **Pre-session scoping**: Currently, an operator must start a session with an estimated scope (e.g., "all endpoints, user @alice"), then watch it fill up / terminate, and re-analyze what went wrong. A dedicated War Room page should show a **Trace Map of live endpoint/level/source activity** (reusing `Nebu.Admin.LogsLive.TraceMapBubble` component) *before* starting a session, letting the operator see the live shape of traffic and decide "actually, I need to exclude `/sync` because it's too noisy" — rather than starting the session blindly and hoping.

3. **Convenience of "exclusive" filters**: The concept of "exclude /sync" arises from the observation that `/sync` (Matrix client long-poll) dominates any endpoint-scoped capture. This story adds an "exclusive scope" concept: instead of "only capture scope X", an operator can say "capture everything except scope Y" — a convenience syntax for "no `/sync`" (and potentially "no `/health`" or "/live/longpoll" — other noisy polling endpoints mentioned in the context).

## Acceptance Criteria

### War Room Session List View (`/admin/logs/war-room`)

**AC1:** A new page `/admin/logs/war-room` (a LiveView) displays a **list of all War Room sessions** (active and historical), fetched from the `war_room_sessions` table and sorted with active sessions first, then by most recent start time.

**AC2:** Each session row displays:
- **Session ID** (UUID, truncated or full — operator's choice)
- **Status badge** (🟢 Active, 🔴 Ended, with the end reason if known: "budget_exhausted", "duration_exceeded", "manual_stop")
- **Started by** (admin user_id who initiated the session)
- **Reason** (the free-text reason field from session creation)
- **Scope** (e.g., "all", "/_matrix/client/v3/sync", or a description of the scope)
- **Filter summary** (if a user_id/device_id filter was applied, show a compact label like "user: @alice:localhost")
- **Time range** (started_at → ended_at, or "started X ago" for active sessions)
- **Entry count** (entries_collected / max_entries, as a progress badge)
- **Duration** (elapsed time as a human-readable string: "2 min 34 sec remaining" for active, "5 min 30 sec" for ended)

**AC3:** Clicking a session row navigates to `/admin/logs/war-room/{room_id}` to drill down into that session's details (see AC5 below).

**AC4:** If no sessions exist (fresh deployment), the page shows a placeholder message: "No War Room sessions yet. Start one from the monitoring page (`/admin/logs`) to begin diagnostic logging."

### War Room Session Detail View (`/admin/logs/war-room/{room_id}`)

**AC5:** A session detail page shows:
- **Session metadata panel** (fixed at the top): the full session information (ID, started_by, reason, scope, filter, max_entries/max_duration_s, started_at, ended_at, ended_reason, entries_collected)
- **A read-only "Logs captured by this session" section** — the exact same request-stream list view from `/admin/logs` (reusing `Nebu.Admin.LogsLive`'s list and detail panel components), but FILTERED to show ONLY operational_logs entries where `war_room_id = {room_id}`, sorted by timestamp, with the trace-map disabled (no filter controls, since all entries already match the session's own scope/filter)
- **A copy-to-markdown button** for the full session metadata + entry list (for support hand-off, incident reports, etc.)
- **A breadcrumb or back link** to `/admin/logs/war-room` (list view)

**AC6:** The detail view is accessible only if the session exists; if the room_id is not found, the page shows a 404 message and an offer to return to the list.

### War Room Scoping Page (`/admin/logs/war-room` pre-session form)

**AC7:** On the War Room list page, above the session list, there is a **"Start a new War Room session" form section** that lets an operator pre-scope a session before starting it. This form mirrors the existing embedded panel from war-room-mode but adds a **live Trace Map** to show the operator the live activity shape *before* they commit to a scope.

**AC8:** The form includes:
- **A Trace Map of current live activity** (endpoints, levels, sources — identical UI to the monitoring page's trace map, but in `:configure` mode or a new `:scope` mode). This shows the operator "here's what traffic looks like right now" without committing them to collecting it yet. The map is live-updating (refreshing every 2s or on each new operational_logs entry via PubSub).
- **Reason** (text input, required)
- **Scope selector** (dropdown or toggle buttons):
  - `"all"` — capture all endpoints (default, shows AC7's global warning)
  - `"/_matrix/client/v3/sync"` — capture only `/sync` (shows stronger AC7/AC8 warning; max_entries cap enforced)
  - `"exclusive"` mode with a nested **exclude-from** selector (new feature, see AC9–AC11 below)
- **Filter inputs** (optional):
  - `user_id` (text input, e.g., `@alice:localhost`)
  - `device_id` (text input, e.g., `GHTYAJSQZD`)
- **Budget inputs**:
  - `max_entries` (number input, default 100, range 10–10000)
  - `max_duration_s` (number input, default 300, range 10–3600)
- **A "Start War Room" button** (prominent, red/alert styling, `🚨 Start War Room`)
- **Contextual warnings** (AC7–AC8 from war-room-mode, re-displayed here)

### "Exclusive Scope" Feature (Optional Narrowing, Design Decision Required)

**AC9:** When scope is set to `"exclusive"`, a secondary **exclude-list selector** appears, allowing the operator to specify one or more endpoints to EXCLUDE from capture. The exclude list can be pre-populated with the **most common noisy endpoints**:
- `"/_matrix/client/v3/sync"` — Matrix long-poll (the primary motivation)
- `"/_matrix/client/v3/sync/long"` — if alias exists (verify in codebase)
- `"/health"` — health-check polling
- `"/admin/live/longpoll"` — admin push-notification polling
- Plus an "other" option to type a custom route

**AC10:** If `exclusive` mode is selected with, say, `/sync` checked:
- The scope internally becomes `inclusive: "all", exclusive: ["/_matrix/client/v3/sync"]` (new JSONB structure in `war_room_sessions.scope`)
- When `WarRoom.check/1` receives a log entry, it checks: (1) is the endpoint in the exclusive list? If yes, skip (do not tag, do not count). If no, tag and count normally.
- This is a convenience sugar over the existing logic — it avoids requiring an operator to say "start a session for **all except sync**" by laboriously testing which endpoints they want instead.

**AC11 (Design Decision):** Should this story generalize "exclusive sync" to **"configurable noisy-endpoint exclusion"** for the Trace Map itself (not just War Room sessions)? In other words:
- Add a persistent **"Hide noisy endpoints" toggle** to `/admin/logs` (the monitoring page), hiding `/sync`, `/health`, `/live/longpoll` from the trace map and request stream by default
- Make the list of noisy endpoints operator-configurable (server_config key, e.g., `log_view_excluded_endpoints`)
- Apply this filtering to BOTH the monitoring page AND the War Room session form's Trace Map

**Decision (for this story):** This story implements "exclusive scope" ONLY for War Room sessions (AC9–AC10). The broader monitoring-page filtering (AC11's generalization) is a separate, optional follow-up. However, if the implementation of AC8's "scope Trace Map" reveals that adding the exclusion logic is trivial (e.g., a single `filter_excluded/2` function called from both places), the developer SHOULD go ahead and implement AC11 as a bonus, documenting the scope decision in Dev Notes.

### Nav Integration (Flat Nav, No New Sidebar)

**AC12:** The existing flat nav in `Nebu.Admin.Layouts` (no nested/collapsible tree anywhere) does not need a new entry for the War Room list page. Instead:
- The existing `/admin/logs` monitoring page shows a link or button near the War Room embedded panel: "📋 Full War Room Session List →" or "View all War Room sessions" that navigates to `/admin/logs/war-room`
- OR, a new `nav_item` is added to the sidebar for "War Room" that links to `/admin/logs/war-room`, with the understanding that `/admin/logs` itself (the monitoring page) can be reached via a back-link from the war-room page

**Decision (for this story):** Add a direct nav_item "War Room" to the sidebar (next to "Logs" or grouped under "Logs"). If nested nav is ever built (separate epic: admin-sidebar-nesting), the structure can be refactored to put "War Room" as a child of "Logs". For now, keep it flat.

### Accessibility

**AC13:** The session list and detail views follow WCAG 2.1 AA standards:
- Session rows are native `<button>` or `<a>` elements (clickable)
- All status badges pair color with text (e.g., "🟢 Active", "🔴 Ended (budget exhausted)")
- The Trace Map in the form section (AC8) inherits the TraceMapBubble component's own a11y (AC13–AC14 from admin-logs-monitoring-view story)
- The page title and headings are semantic `<h1>`, `<h2>`

## Acceptance Tests

### Tests written FIRST (ATDD):

1. **[AC1–AC2] War Room list page loads and displays sessions** — ExUnit integration test (Phoenix.LiveViewTest)
   - Given: 3 sessions in the war_room_sessions table (1 active, 2 ended)
   - When: LogsLive navigates to `/admin/logs/war-room`
   - Then: a list of 3 rows is displayed, with the active session first
   - And: each row shows the expected fields (ID, status, reason, scope, time range, entry count, duration)

2. **[AC2] Status badge reflects session state** — ExUnit integration test
   - Given: an active session (ended_at = NULL)
   - When: the list is rendered
   - Then: the status badge shows "🟢 Active"
   - Given: an ended session with ended_reason = "budget_exhausted"
   - When: the list is rendered
   - Then: the status badge shows "🔴 Ended (budget exhausted)"

3. **[AC3] Clicking a row navigates to detail view** — ExUnit integration test
   - Given: a session with id=W in the list
   - When: the row is clicked
   - Then: the page navigates to `/admin/logs/war-room/{W}`

4. **[AC4] Empty state message shown when no sessions exist** — ExUnit integration test
   - Given: an empty war_room_sessions table
   - When: `/admin/logs/war-room` is loaded
   - Then: the page displays "No War Room sessions yet..."

5. **[AC5] Session detail view shows metadata and captured logs** — ExUnit integration test
   - Given: a session with id=W and 5 operational_logs entries tagged with war_room_id=W
   - When: `/admin/logs/war-room/{W}` is loaded
   - Then: the metadata panel displays the full session info
   - And: the logs section shows the 5 entries, sorted by timestamp
   - And: no entries with a different war_room_id are shown

6. **[AC6] Detail view 404 for non-existent session** — ExUnit integration test
   - Given: an invalid session id
   - When: `/admin/logs/war-room/{invalid-id}` is loaded
   - Then: the page displays a 404 message
   - And: a link to return to `/admin/logs/war-room` is provided

7. **[AC8] Pre-session form renders with all fields** — ExUnit integration test
   - Given: the `/admin/logs/war-room` list page
   - When: the page loads
   - Then: the "Start a new War Room session" form section is visible
   - And: it contains: reason input, scope selector, user_id/device_id inputs, max_entries/max_duration_s inputs, Start button

8. **[AC8] Trace Map on the form is live-updating** — ExUnit integration test
   - Given: the form's Trace Map is displayed
   - When: a new operational_logs entry arrives via PubSub
   - Then: the Trace Map bubble counts update in real time (no page reload)

9. **[AC9–AC10] Exclusive scope mode shows exclude-list selector** — ExUnit integration test
   - Given: the form with scope set to `"exclusive"`
   - When: the page re-renders
   - Then: an exclude-list selector appears with options like `/sync`, `/health`, `/live/longpoll`
   - And: the operator can check one or more to exclude them

10. **[AC10] Starting a session with exclusive scope tags correctly** — ExUnit integration test
    - Given: a War Room is started with `scope: "exclusive"` and `exclusive: ["/_matrix/client/v3/sync"]`
    - When: an operational_logs entry for `/sync` arrives
    - Then: it is NOT tagged with the war_room_id (excluded)
    - When: an entry for a different endpoint arrives
    - Then: it IS tagged (included)

11. **[AC7–AC8] Warnings shown for broad/noisy scopes** — ExUnit integration test
    - Given: the form with scope set to `"all"`
    - When: the page renders
    - Then: a warning message appears: "Warning: collecting all endpoints..."
    - Given: scope set to `"/_matrix/client/v3/sync"`
    - When: the page renders
    - Then: a stronger warning appears: "⚠️ `/sync` is called continuously..."

12. **[AC12] Nav item for War Room page exists** — ExUnit integration test
    - Given: the admin sidebar
    - When: the page is loaded
    - Then: a "War Room" nav item is visible
    - And: it links to `/admin/logs/war-room`

13. **[AC13] Accessibility: status badges are not color-only** — ExUnit test + manual audit
    - Given: a session row with a status badge
    - When: the HTML is inspected
    - Then: the badge contains both a colored emoji (🟢/🔴) and text ("Active"/"Ended"), not color alone

14. **[AC5] Copy-to-markdown button exports session + logs** — ExUnit integration test
    - Given: a detail view with a session and 3 captured logs
    - When: the "Copy to markdown" button is clicked
    - Then: a text block is copied to clipboard containing session metadata + all logs in a readable format
    - And: the operator sees a toast/flash "Copied to clipboard"

## Dev Notes

### File Structure

- **New:** `server/lib/nebu/admin/war_room_list_live.ex` — LiveView for `/admin/logs/war-room` (list + form)
  - Mount: load all sessions from `war_room_sessions` table, subscribe to `"operational_logs"` PubSub for live Trace Map updates
  - Render: session list (AC1–AC2), empty state (AC4), pre-session form with Trace Map (AC8), warnings (AC7–AC8)
  - Handle_info: receive operational_logs entries, update Trace Map bubble counts for the form
  - Handle_event: "start_war_room" event (calls `Nebu.Admin.WarRoomManager.start_session/1`), scope-mode toggle, exclusive-list updates

- **New:** `server/lib/nebu/admin/war_room_detail_live.ex` — LiveView for `/admin/logs/war-room/{room_id}` (detail)
  - Mount: load session by id, fetch all operational_logs entries tagged with that war_room_id, subscribe to PubSub to receive new entries for this session in real time (AC5 — live-updating detail view)
  - Render: session metadata panel, logs section (reusing `detail_panel` component + request-stream subcomponents from LogsLive), copy-to-markdown button
  - Handle_info: receive operational_logs entries, filter to only this war_room_id, stream them into the logs view
  - Handle_event: "copy_to_markdown" event

- **New:** `server/lib/nebu/admin/war_room_list_live/scope_selector.ex` — Phoenix.Component
  - Function component `scope_selector/1` — renders the scope selector with conditional exclusive-list UI
  - Accepts: `scope` value, `on_change` callback, `on_exclusive_change` for the exclude-list updates

- **Modified:** `server/lib/nebu/admin/router.ex`
  - Add two new routes under the `live_session :admin` block:
    - `live "/logs/war-room", WarRoomListLive, :index`
    - `live "/logs/war-room/:room_id", WarRoomDetailLive, :show`

- **Modified:** `server/lib/nebu/admin/layouts.ex`
  - Add a new nav_item for "War Room" (or "War Room Sessions"), linking to `/admin/logs/war-room`

- **Modified:** `server/lib/nebu/admin/logs_live.ex`
  - Add a link/button in the War Room embedded panel: "View full session list →" that navigates to `/admin/logs/war-room`
  - (Alternatively: if AC12 decides to add a nav item instead, no change needed to LogsLive)

- **Modified:** `server/lib/nebu/web/log_store/war_room.ex`
  - Update the scope-matching logic to support `exclusive` mode (AC9–AC10):
    - `scope` can now be a string or a map: `%{"mode" => "inclusive"} | %{"mode" => "exclusive", "exclude" => ["/_matrix/client/v3/sync", ...]}`
    - `check/1` reads the mode and applies the exclude list logic
    - (Or, if simpler, `scope` remains a string and a new `exclusive_scope` JSONB column is added to `war_room_sessions` for the exclude list)

- **Modified:** `server/lib/nebu/admin/war_room_manager.ex`
  - Update `start_session/1` to accept and validate `exclusive_scope` parameter (optional list of endpoints to exclude)
  - Pass it through to the session creation in the DB

- **New:** `server/test/nebu/admin/war_room_list_live_test.exs` — ExUnit tests for the list page
  - Tests 1–4, 7–9, 11–12, 14 above

- **New:** `server/test/nebu/admin/war_room_detail_live_test.exs` — ExUnit tests for the detail page
  - Tests 5–6, 13 above (detail view specific)

- **New:** `server/test/nebu/admin/war_room_list_live/scope_selector_test.exs` — component tests
  - Test the scope_selector component rendering with different modes

### Architecture & Implementation Hints

1. **Session List Sorting & Filtering:**
   - Query: `SELECT * FROM war_room_sessions ORDER BY CASE WHEN ended_at IS NULL THEN 0 ELSE 1 END, started_at DESC`
   - This sorts active sessions first, then by most recent start time
   - On load, fetch all sessions (or implement pagination if the table grows large)

2. **Live Trace Map on Form (AC8):**
   - The form's Trace Map should be a **separate, stateful component** (not reusing the monitoring page's LogsLive trace map)
   - It subscribes to `"operational_logs"` PubSub in `WarRoomListLive.mount/3`
   - In `handle_info/2`, it receives entries and updates `@form_trace_bubble_counts` (a map)
   - The Trace Map renders with `mode: :filter` (using TraceMapBubble) but the bubbles are NOT clickable for filtering — they're read-only, just showing the live shape of traffic
   - (Alternative: `mode: :readonly` or `:view` — add to TraceMapBubble's mode allowlist, rendering bubbles that are not clickable at all)

3. **Exclusive Scope Implementation:**
   - **Option A (recommended):** Add `exclusive_scope` as a new nullable JSONB column to `war_room_sessions`, separate from `scope`. `scope` remains a string (the inclusive scope: "all", "/_matrix/client/v3/sync", or NULL). `exclusive_scope` is an optional list `["/_matrix/client/v3/sync", "/health"]` when the operator uses the exclusive mode.
   - **Option B:** Change `scope` to a JSONB map `%{"mode" => "inclusive"|"exclusive", "value" => "...", "exclude" => [...]}` — requires more refactoring of existing war_room_mode code that reads `scope` as a string.
   - **Recommend Option A** — minimal changes to existing code, backward-compatible migration (`ADD COLUMN exclusive_scope JSONB`), and clearer semantics.
   - In `WarRoom.check/1`, match on `exclusive_scope` being non-nil and non-empty; if present, check if the entry's `route_template` is in the list before tagging.

4. **Detail View Log Streaming:**
   - Load initial logs: `LogStore.get_logs(%{war_room_id: room_id, limit: 1000})` (or no limit, if reasonable)
   - In `handle_info/2`, receive operational_logs entries and filter to `entry.war_room_id == @room_id` before streaming
   - Reuse the request-stream list and detail panel components from `LogsLive` (they are already modular)
   - The detail view is read-only — no filter controls, just a chronological thread with the same layout as `/admin/logs`'s detail panel

5. **Copy-to-Markdown (AC14):**
   - Build a Markdown string:
     ```
     # War Room Session {room_id}
     
     **Started by:** {started_by}
     **Reason:** {reason}
     **Scope:** {scope}
     **Filter:** {filter}
     **Time:** {started_at} → {ended_at}
     **Entries collected:** {entries_collected} / {max_entries}
     
     ## Captured Logs
     
     {for each entry}
     - `{timestamp}` [{level}] [{source}] {message}
     ```
   - Use a client-side library (Clipboard API via `navigator.clipboard.writeText()`) to copy to the user's clipboard
   - Show a toast/flash message "Copied to clipboard" via `JS.dispatch/2` or a `handle_event/3` round-trip

6. **Trace Map Mode Decision (AC8's reuse of TraceMapBubble):**
   - The form's Trace Map shows live counts (identical to the monitoring page's) but is NOT filterable
   - Add a new TraceMapBubble mode `:view` (read-only, no phx-click) OR reuse `:filter` mode but pass a no-op `on_click` (e.g., `JS.noop()`)
   - Recommend `:readonly` as a new mode value in TraceMapBubble — clearly signals intent and allows the component to render a disabled/non-interactive button if needed

7. **Exclusive Scope UI (AC9–AC10):**
   - The exclude-list selector can be a set of checkboxes, one per pre-defined noisy endpoint
   - Or, a multi-select dropdown with the same set
   - Store the selected list in the form's `phx-value-*` attributes or in a hidden input, passed to `start_war_room` event
   - In the LiveView, validate that the provided list contains only known, safe route_templates before inserting into the DB (defense-in-depth: do not trust the form's UI validation alone)

### Testing Strategy

1. **Unit tests (scope_selector component):** Render with different scope modes, verify the conditional UI.
2. **Integration tests (WarRoomListLive & WarRoomDetailLive):** Mount the views, verify session loading, live Trace Map updates, form submission, navigation, 404 handling.
3. **Exclusive scope logic:** Test `WarRoom.check/1` with exclusive_scope set, verify that excluded entries are not tagged.
4. **Accessibility audit:** Verify status badges, button states, nav items are all semantic.
5. **E2E test (optional):** A Playwright scenario that navigates to the War Room list, starts a session, verifies it appears in the list, clicks it, views the detail page, and copies the markdown.

### Design Decision: Generalize to "Noisy Endpoint Exclusion" (AC11)

If AC11 is in scope (generalize exclusion to the monitoring page itself):
- Add a new `Nebu.Admin.LogsLive.log_view_excluded_endpoints/0` helper that reads from `server_config` or a default list
- Call it in `LogsLive.mount/3` to seed `@excluded_endpoints`
- In the monitoring page's Trace Map rendering, filter out bubbles/entries for excluded endpoints
- In the War Room form, show the same list by default (read from config)
- Make it configurable via `/admin/config` (a new field in ConfigLive, added to `server_config`)

If AC11 is out of scope:
- Document in Dev Notes that this is a follow-up opportunity and note where the code would live

## Tasks / Subtasks

Superseded by the "Story Amendments (2026-07-08)" section — the dev-story implemented the AMENDED design (one LiveView module, not three files) rather than the stale original plan below. Checked off against what was actually built:

- [x] Create migration: `server/priv/migrations/000021_war_room_exclusive_scope.{up,down}.sql` — `ALTER TABLE war_room_sessions ADD COLUMN exclusive_scope JSONB` (nullable)
- [x] ~~Create `war_room_list_live.ex`~~ / ~~`war_room_detail_live.ex`~~ / ~~`scope_selector.ex`~~ — superseded by amendment 1: ONE module, `Nebu.Admin.LogsLive.WarRoom` (`:index`/`:show` actions, no `handle_params/3`), mirroring `Nebu.Admin.LogsLive.TraceMap`'s own single-module shape. The exclusive-scope checkboxes are inline in the same module's form render, not a separate component.
- [x] Update `war_room_manager.ex` to accept and validate `exclusive_scope` parameter (shape validation, Dev Notes item 7)
- [x] Update `log_store/war_room.ex` to handle exclusive scope in `check/1`
- [x] Update `router.ex` — repoints the former `/logs/war-room` stub (amendment 1), adds `/logs/war-room/:room_id`
- [x] Update `layouts.ex` — sidebar recording dot + topbar recording pill (amendment 4); the "War Room" nav child already existed from `admin-sidebar-nesting`
- [x] Update `logs_live.ex` — embedded War Room panel REMOVED (amendment 2), not a link added; war-room status poll kept for the sidebar dot/topbar pill
- [x] Write acceptance tests FIRST (ATDD) — already staged before this dev-story cycle
- [x] Implement `Nebu.Admin.LogsLive.WarRoom` (list mode + detail mode)
- [x] Verify all tests pass (unit suite 1557/1557; new-story integration suite verified per-file, see Dev Agent Record)
- [x] Manual accessibility audit — native `<a>`/`<button>` rows, paired emoji+text badges, `aria-live` copy toast; deferred full audit to Kassandra's security/UX review
- [ ] Security review (Kassandra) — pending, `security_review: required` per frontmatter

## Cross-Story Dependencies & Notes

### Depends On (must be ready before this story's dev):
- **war-room-mode** — provides the `war_room_sessions` table, `WarRoomManager` API, scope/filter matching logic, and the embedded panel UI this story extends
- **admin-logs-monitoring-view** — provides the request-stream list and detail-panel components that this story reuses on the detail view
- **operational-log-store** — provides the `operational_logs` table and the `"operational_logs"` PubSub topic for live updates

### Coordination Notes:
- The `Nebu.Admin.LogsLive.TraceMapBubble` component is reused in the form (AC8). Confirm if a new mode (`:readonly` or `:view`) is needed, or if `:filter` with a no-op `on_click` is acceptable.
- The exclusive_scope logic in `Nebu.Web.LogStore.WarRoom.check/1` must be coordinated with the scope-matching design from war-room-mode. Verify that adding `exclusive_scope` does not conflict with the existing scope string matching.
- The session list/detail LiveViews reuse components from LogsLive (request stream, detail panel). Ensure these components are properly extracted as standalone, reusable modules if they are not already.

## Design Decisions

### AC11 Exclusion Scope (Noisy Endpoints)
**Decision:** This story implements exclusive scope ONLY for War Room sessions. The broader monitoring-page filtering is a follow-up. If the implementation reveals trivial generalization, it SHOULD be implemented as a bonus.

### AC12 Nav Integration
**Decision:** Add a flat nav item "War Room" for `/admin/logs/war-room`. If nested nav is built later (separate epic), refactor then.

### Exclusive Scope Schema (AC9–AC10)
**Decision:** Use Option A — add a separate `exclusive_scope JSONB` column to `war_room_sessions`, keeping `scope` as a string. This is backward-compatible and minimal-change.

### Trace Map Mode for AC8
**Decision:** Add a new TraceMapBubble mode `:readonly` (or reuse `:filter` with no-op `on_click`). Document clearly that the form's Trace Map is read-only, not for filtering.

## Dev Agent Record

### Implementation Summary (dev-story cycle 0)

Implemented per the story's "Story Amendments (2026-07-08)" section (authoritative over
the stale original AC text): ONE LiveView module, `Nebu.Admin.LogsLive.WarRoom`
(`:index`/`:show` actions, no `handle_params/3`), repointing the former
`/admin/logs/war-room` stub; the embedded War Room panel on `/admin/logs` was removed;
`TraceMapBubble` gained a `:readonly` mode reused for the level+source live-activity
preview; `exclusive_scope` was added as a nullable JSONB column (migration 000021) and
threaded through `WarRoomManager.start_session/1` (shape-validated, not a closed
allowlist) and `WarRoom.check/1`; the sidebar recording dot / topbar recording pill were
added to `Nebu.Admin.Layouts.live/1` via a new shared `Nebu.Admin.WarRoomIndicator`
helper, wired into every remaining admin LiveView (`DashboardLive`, `AuditLogLive`,
`LogsLive`, `LogsLive.TraceMap`, `LogsLive.WarRoom` — the full "anywhere in the admin UI"
surface after admin-http-refactor's controller conversions); copy-to-markdown reuses the
existing `nebu:copy-thread` CSP-safe client event.

An "AC2 of war-room-mode: at most one active session" banner (reusing the retired
embedded panel's own `war-room-panel`/`stop-war-room-button` testids) was added to the
dedicated page's list view, replacing the start form while a session is active — this
was NOT in the original story text but was required to keep the pre-existing
`war-room.feature`/`logs-trace-map.feature` E2E scenarios' reused step definitions
(`the operator starts/stops a War Room`) working against the new page.

### Bugs found and fixed during E2E verification (outside the story's own file list, but
required to make the ATDD/E2E suite genuinely green)

- `e2e/fixtures/db.ts`: `runSqlReturningId` didn't strip psql's trailing command-tag line
  ("INSERT 0 1") from its `-t -A` output, corrupting every ID it returned — fixed to take
  only the first line.
- `e2e/fixtures/db.ts`: `clearWarRoomSessions` didn't delete the referencing
  `operational_logs` rows first, so it failed with an FK-constraint violation once any
  scenario had attached captured entries to a session — fixed to delete children first.
- `e2e/fixtures/db.ts`: removed a duplicate `endActiveWarRoomSessions` (already existed
  from `trace-map-node-controls`) that this story's own staged diff re-added, which broke
  `bddgen`'s TypeScript compile entirely (`SyntaxError: Identifier ... has already been
  declared`).
- `e2e/features/admin/war-room.feature`: retired (embedded panel scenarios), mirroring
  the ExUnit-side `war_room_panel_retirement_test.exs`.
- `e2e/features/admin/logs-trace-map.feature`: its own `@ac6-war-room-banner` scenario
  started a session via the now-retired embedded panel on `/admin/logs` — repointed to
  start it via the new `/admin/logs/war-room` page instead (same reused step
  definitions).

### Round 2 fixes (coordinator-reported, 2026-07-08 — after a clean `war_room_sessions`
truncate isolated 4 real bugs from the earlier round's environmental noise)

1. **Cross-scenario pollution WITHIN one suite run.** Every scenario in
   `war-room-dedicated-page.feature` seeds a session and nothing cleaned up between
   scenarios (only the single `@ac4` scenario's own "no sessions exist" step called
   `clearWarRoomSessions`). Fixed by tagging every scenario `@war-room-dedicated-page` and
   registering `After({ tags: '@war-room-dedicated-page' }, () => clearWarRoomSessions())`
   in the steps file — mirrors `logs-trace-map.steps.ts`'s own `@node-controls`
   tag-scoped-hook pattern exactly. Also broadened `clearWarRoomSessions`'s WHERE clause
   (`started_by LIKE '@e2e-wr-%' OR reason LIKE 'e2e %'`) since the AC9/AC10 scenario
   starts its session through the REAL UI, so its `started_by` is the logged-in e2e
   admin's real id, never `@e2e-wr-%` — only its literal `reason` ("e2e exclusive scope
   test") is a usable cleanup marker for that row.
2. **Exclusive-scope options never appeared.** Root cause: NOT a template/testid bug —
   `Nebu.Admin.LogsLive.WarRoom`'s scope `<select>` correctly reveals
   `war-room-exclusive-options` via a `phx-change` round trip (proven by the ExUnit
   `render_change` test, which passed all along). The shared `war-room.steps.ts`'s
   "the operator selects {string} as the War Room scope" step was missing the
   `[data-phx-main].phx-connected` wait its own sibling "starts a War Room..." step already
   has — on the throttled-longpoll transport, `selectOption()` fired before the LiveSocket
   connected, so the native `change` event landed on a dead, unconnected static DOM and
   the server round trip never happened. Fixed by adding the same wait.
3. **Copy-to-markdown toast never appeared.** Same root cause as #2: "the operator clicks
   the copy-to-markdown button" (`war-room-dedicated-page.steps.ts`) had no
   `phx-connected` wait. The button's `phx-click` is
   `JS.dispatch("nebu:copy-thread") |> JS.push("copy_to_markdown")` — the `dispatch` half
   is pure client-side (fires even pre-connection, which is why the clipboard write could
   still silently succeed) but the `push` that actually sets `@copy_toast` server-side
   needs a live socket. Fixed by adding the wait.
4. **Keyboard-operability scenario: `select[name="scope"]` never found.** Same root cause
   as #2 (this scenario reuses the same buggy shared step) — fixing #2 fixed this too.

### Verification (final, after round 2)

- `mix test --warnings-as-errors` (no `NEBU_DB_URL`, mirrors `make test-unit-elixir`):
  **1557/1557 passed, 0 failures, exit code 0** (also fixed an unrelated pre-existing
  `--warnings-as-errors`-fatal compile warning in `war_room_test.exs`'s
  `insert_operational_log/2` helper — an unused default argument value — that was silently
  aborting the run even though every individual test passed).
- `mix test --include integration` targeted at every new/touched test file: passes
  cleanly in isolation (91-98 tests depending on grouping).
- E2E (`--project=admin-ui --grep "War Room"`): **10/10 passed** against a genuinely clean
  `war_room_sessions` table (confirmed empty after the run via the new After-hook).
- E2E regression sweep (`--grep "Trace Map|Node Controls|sidebar"`, 23 scenarios): all
  green (one intermittent, unrelated node-overlap click flake in
  `logs-trace-map-node-controls.feature` — pure geometry/traffic-volume timing, not
  touched by this story — passed cleanly on retry).

## Design Update (2026-07-07 — Trace Map Leitstand)

Phil approved an interactive design dummy covering this story's page shell. New ACs to
incorporate (see `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md` §6 + `trace-map-leitstand-dummy.html`):
- While a session is active: pulsing red recording dot on the "War Room" sidebar item
  and a topbar recording pill ("War Room recording · mm:ss", user + elapsed time).
- The red across-the-view banner on the Trace Map page is scoped to the trace-map story,
  driven by the same session status.

## Story Amendments (2026-07-08, coordinator/design owner — realignment after the shipped Leitstand redesign)

This story predates `admin-sidebar-nesting`, `trace-map-leitstand`, and `trace-map-node-controls`
(all committed since). Several ACs/Dev Notes below are stale and are corrected here; the
numbered ACs above stay the source of truth for everything NOT touched by this section.

1. **AC12 / nav integration — MOOT, already shipped differently.** The sidebar's "Logs"
   group already has a "War Room" child (navkey `logs-war-room`, `admin-sidebar-nesting`).
   It currently points at a STUB route (`live "/logs/war-room", LogsLive, :index` in
   `router.ex` — literally the Live Stream page, mislabeled). This story's job is to
   **replace the stub**: `live "/logs/war-room", LogsLive.WarRoom, :index` (new LiveView,
   naming consistent with the sibling `LogsLive.TraceMap` module) with
   `@active_nav = "logs-war-room"`, plus `live "/logs/war-room/:room_id", LogsLive.WarRoom, :show`
   for the detail view (same module, two `handle_params` shaped actions — mirror however
   `LogsLive.TraceMap` structures its own single-LiveView, multi-concern pattern; do NOT
   invent a second top-level nav entry).

2. **Embedded panel retirement.** `Nebu.Admin.LogsLive.WarRoomPanel.war_room_panel/1` is
   STILL embedded on `/admin/logs` (Live Stream page, `logs_live.ex:1007`) — this story's
   own premise ("dedicated page ... rather than only an embedded panel") means it must be
   REMOVED from Live Stream once the dedicated page ships (mirrors exactly how
   `trace-map-leitstand` retired the embedded Trace Map from that same page). The
   "start a new session" form (AC7/AC8) moves to the new page entirely. `WarRoomPanel`'s
   status-badge/warning sub-components may be reused by the new page if convenient; the
   component itself no longer renders on Live Stream.

3. **AC8's Trace Map reuse — `TraceMapBubble`, NOT the new radial Leitstand map.**
   `Nebu.Admin.LogsLive.TraceMapBubble` (level/source dimensions) is unchanged and still
   live on `/admin/logs`; only the ENDPOINT dimension moved to the new radial
   `LogsLive.TraceMap` page. AC8's "live activity shape" preview on the scoping form
   should reuse `TraceMapBubble` for **level + source** only (a lightweight, existing,
   already-accessible component) — do NOT build a second radial-map instance for this
   small preview widget; that is out of proportion to the need (the exclusive-scope
   checkboxes, AC9–AC11, already solve the actual "sync is noisy" motivation directly).
   Add the `:readonly` mode to `TraceMapBubble` per the story's own Trace Map Mode
   Decision (unchanged, still correct).

4. **War-room visibility in the sidebar/topbar (closes the gap left after
   `trace-map-leitstand` shipped only the in-page banner):** while a session is active,
   add (a) a pulsing recording dot on the sidebar's "War Room" nav item
   (`server/lib/nebu/admin/layouts.ex` `nav_item`, dot shown when
   `@war_room_active` — a new assign threaded through `Nebu.Admin.Layouts.live/1`, sourced
   from `Nebu.Admin.WarRoomManager.status/0`, polled the same way `LogsLive`/`LogsLive.TraceMap`
   already do) and (b) a recording pill in the topbar ("War Room recording · mm:ss") per
   the approved dummy (`trace-map-leitstand-dummy.html` topbar `.pill--warroom`). This was
   scoped to `war-room-dedicated-page` by the `trace-map-leitstand` UX gate's A2/coordination
   note and by this story's own original 2026-07-07 Design Update block below.
   CSP: countdown/dot ticking via the existing `app.js` polling pattern, no inline JS.

5. **Exclusive-scope endpoint list — reuse the canonical constant.** AC9's pre-populated
   noisy-endpoint list overlaps with `trace-map-node-controls`'s
   `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` (`/_matrix/client/v3/sync`,
   `/admin/keepalive`, `/health`). REUSE that public function as the default exclude-list
   source instead of hardcoding a parallel list (verify each AC9-named endpoint actually
   exists as a real route first — `/_matrix/client/v3/sync/long` and
   `/admin/live/longpoll` were speculative in the original AC9 text; only include real,
   observed route templates plus a free-text "other" input, exactly as AC9 already allows).

6. **Copy-to-markdown (AC14) CSP compliance.** `navigator.clipboard.writeText()` must be
   wired through the existing `app.js` hook pattern (a small dedicated hook or an
   extension of an existing one) — no inline `onclick`/`phx-click` JS. Toast/flash via a
   `handle_event` round-trip is fine and matches the rest of the admin UI.

7. **Security review stays REQUIRED** (already set in frontmatter) — this story writes
   admin-supplied exclusive-scope lists into session records and exposes historical log
   content on the detail page; Kassandra should pay particular attention to (a) the
   defense-in-depth validation AC9/Dev-Notes-item-7 already calls for (don't trust
   client-supplied route strings unchecked) and (b) whether the detail view's log display
   needs the same No-Sensitive-Data treatment as the Leitstand stream panel.

## File List

New:
- `server/priv/migrations/000021_war_room_exclusive_scope.up.sql`
- `server/priv/migrations/000021_war_room_exclusive_scope.down.sql`
- `server/lib/nebu/admin/logs_live/war_room.ex`
- `server/lib/nebu/admin/war_room_indicator.ex`

Modified:
- `server/lib/nebu/web/log_store/war_room.ex`
- `server/lib/nebu/admin/war_room_manager.ex`
- `server/lib/nebu/admin/logs_live/trace_map_bubble.ex`
- `server/lib/nebu/admin/logs_live/trace_map.ex`
- `server/lib/nebu/admin/logs_live.ex`
- `server/lib/nebu/admin/layouts.ex`
- `server/lib/nebu/admin/router.ex`
- `server/lib/nebu/admin/dashboard_live.ex`
- `server/lib/nebu/admin/audit_log_live.ex`
- `server/priv/static/assets/app.js`
- `server/test/nebu/admin/logs_live_test.exs` (removed the two retired-panel describe blocks)
- `server/test/nebu/admin/logs_live/war_room_test.exs` (UUID canonicalization fix in the
  shared test helpers)
- `server/test/nebu/web/log_store/war_room_test.exs` (already staged; unmodified beyond
  the ATDD addition)
- `server/test/nebu/release_test.exs` (migration count bump to 21)
- `e2e/fixtures/db.ts` (bug fixes: `runSqlReturningId` multi-line output,
  `clearWarRoomSessions` FK-order + broadened WHERE clause, duplicate
  `endActiveWarRoomSessions` removed)
- `e2e/features/admin/war-room.feature` (retired)
- `e2e/features/admin/logs-trace-map.feature` (`@ac6-war-room-banner` repointed to the new page)
- `e2e/features/admin/war-room-dedicated-page.feature` (every scenario tagged
  `@war-room-dedicated-page` for the new After-hook)
- `e2e/step-definitions/admin/war-room-dedicated-page.steps.ts` (After-hook registration;
  `phx-connected` wait added to the "checks... excluded endpoint" and "clicks the
  copy-to-markdown button" steps)
- `e2e/step-definitions/admin/war-room.steps.ts` (`phx-connected` wait added to the
  standalone "selects... War Room scope" step)
- `docs/stories/enhanced-logging/war-room-dedicated-page.md` (this file)

## Change Log

- 2026-07-08 (dev-story cycle 0): Implemented the amended design (single `LogsLive.WarRoom`
  module, embedded-panel retirement, `:readonly` TraceMapBubble mode, `exclusive_scope`
  column + validation, sidebar dot/topbar pill via `WarRoomIndicator`, CSP-safe
  copy-to-markdown). Fixed 3 pre-existing bugs in `e2e/fixtures/db.ts` and retired/repointed
  2 E2E feature files' War Room dependencies discovered during live-stack verification.
- 2026-07-08 (round 2, coordinator-reported): fixed cross-scenario `war_room_sessions`
  pollution (new tag-scoped After-hook), a missing `phx-connected` wait in 3 shared E2E
  step definitions (exclusive-scope select, copy-to-markdown click — the actual root cause
  behind 3 of the 4 reported failures), and an unrelated pre-existing
  `--warnings-as-errors`-fatal compile warning in a test helper. E2E War Room suite now
  10/10; `make test-unit-elixir` 1557/1557 exit 0.
- 2026-07-08 (cycle 3, code-review MINOR fix): `handle_event("start_war_room", ...)` in
  `Nebu.Admin.LogsLive.WarRoom` (`server/lib/nebu/admin/logs_live/war_room.ex`) now rejects
  a submission where `scope == "exclusive"` but `merge_exclusive_scope/1` resolves to `nil`
  (zero checkboxes checked AND a blank "other" field) with a visible `@start_error` —
  "Select at least one endpoint to exclude, or choose a different scope" — instead of
  silently degrading to `scope: "all", exclusive_scope: nil` (capture-everything, the exact
  noisy full capture the "all except…" mode exists to avoid). No session is started in this
  case. Added a regression test in
  `server/test/nebu/admin/logs_live/war_room_test.exs` ("submitting scope=exclusive with
  zero exclusions is rejected with a form error, not a silent capture-all"). Verified:
  `make test-unit-elixir` 1560 passed/0 failures/0 regressions (DB-free suite; the new test
  lives in the pre-existing `@describetag :integration` describe block and was additionally
  verified standalone against the live DB — 1 passed); E2E
  `--project=admin-ui --grep "War Room"` stays 10/10, including the pre-existing
  "Starting a session with exclusive scope excludes the chosen endpoint from capture"
  scenario (unaffected, since it always selects at least one checkbox).

## Design Conformance Verification (2026-07-08, coordinator, live browser check against approved dummy)

Verified live at http://localhost:8008 (admin: kai@example.com) against
trace-map-leitstand-dummy.html. Overall: **high fidelity** — radial map geometry,
status propagation, off-node capture+countdown, inspector logging controls, level-filter
shortcut, sidebar/topbar recording indicators, and sidebar nesting all match the approved
design and behave correctly. Two content gaps found, not blocking, worth a follow-up
story:

1. **`started_by` renders as the raw OIDC subject claim, not a human-readable
   identifier.** Confirmed in three places: the topbar recording pill, the
   trace-map-leitstand war-room banner, and this page's own active-session
   line/session-list row — all show the protobuf-encoded Dex `sub`
   (e.g. `CiQwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDESBWxvY2Fs`) instead of
   the admin's email/username. The approved dummy always showed a friendly identifier
   (`@alice:nebu.example`). Root cause is upstream of this story (`started_by` is
   stored as the raw session-derived value at session-start time, shared by
   war-room-mode/trace-map-leitstand/this story) — fix belongs in
   `Nebu.Admin.WarRoomManager.start_session/1` or a shared display-time resolver
   (admin_user_id → email lookup), then all three surfaces inherit the fix.
2. **AC4's empty-state copy is stale.** "No War Room sessions yet. Start one from the
   monitoring page (`/admin/logs`) to begin diagnostic logging." — the scoping form to
   start a session is now ON THIS SAME PAGE (per this story's whole premise), not on
   `/admin/logs`. One-line copy fix.

Screenshots: `_bmad-output/nebu/epics/enhanced-logging/design/verification/`.

### Follow-up fix (2026-07-08, coordinator)

Both gaps addressed directly (small, content-only, no pipeline run needed):

1. **Empty-state copy** — `war_room.ex`'s placeholder text no longer references
   `/admin/logs`; it now points at the form on the same page.
2. **`admin_id_from_session/1` precedence bug (real code defect, not just copy)** —
   all three duplicated copies of this private helper (`logs_live.ex`, `trace_map.ex`,
   `war_room.ex`) checked the raw OIDC `sub` claim BEFORE `matrix_user_id`, so the
   human-readable Matrix ID was never used even when present in the session. Fixed
   to prefer `matrix_user_id` in all three copies. Verified: `mix test` 1560/1560,
   live re-check shows the value now flows through as a proper `@localpart:server`
   Matrix ID rather than the bare encoded `sub`.
   **Deeper root cause found, NOT fixed (out of scope for this pass):** in this dev
   stack, Dex's local-password connector emits no `preferred_username`/`name` claim,
   so `Nebu.Matrix.UserId.localpart/1` (the single source of truth for ALL
   OIDC-derived Matrix IDs, not just admin display) falls through to encoding the raw
   `sub` — this is why the admin `kai@example.com` still resolves to
   `@ciqwmdawmdawmc0wmdawltawmdatmdawmc0wmdawmdawmdawmdesbwxvy2fs:localhost` rather
   than something like `@kai:localhost`. This affects Matrix identity derivation
   app-wide (real OIDC users too), is pre-existing (not introduced by this epic), and
   is a materially bigger change (claim-priority policy for identity derivation, needs
   its own review) than "fix two content gaps" — flagged for a separate story/decision
   rather than folded in here.
