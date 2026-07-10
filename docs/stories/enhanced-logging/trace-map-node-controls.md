---
id: trace-map-node-controls
title: "Trace Map Node Controls — inspector logging panel + long-polling off-by-default with temporary capture"
epic: enhanced-logging
status: done
security_review: required
matrix: false
ui: true
created: 2026-07-07
---

# Trace Map Node Controls — Per-Node Logging Inspector & Temporary Capture

## Story

**As** a Nebu platform operator managing production logs,
**I want** the Trace Map inspector to become a logging control panel where I can configure per-endpoint collection levels and retention, and enable temporary logging on long-polling endpoints that are off by default,
**so that** I can fine-tune collection policy without leaving the Trace Map view, safely experiment with high-frequency endpoints via time-limited capture, and keep the map signal-to-noise ratio high by defaulting polling endpoints to off.

This story completes the approved Leitstand design (spec §4 and §5 from `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md`), building on the already-shipped `trace-map-leitstand` story. The inspector panel, previously read-only with live stats only, becomes an interactive logging control center. Long-polling endpoints (config-driven list, default: `/_matrix/client/v3/sync`, `/admin/keepalive`, `/health`) are rendered off by default — gray, dashed, count "off", no collection — and a single click enables TEMPORARY capture for 5 minutes with a server-side timer, countdown display, auto-revert, and aria-live announcements.

**This story SUPERSEDES the UI concept of `noise-endpoint-bucketing.md`** (status: ready-for-dev, with a "Design Update — REALIGNMENT REQUIRED" note): the bucketing-UI (collapse/expand category) is obsolete; the backend concept (config-driven low-signal endpoint list, off-by-default collection) is reused. See AC13 for the coordination note.

### Design Source

Authoritative design: `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md` (Phil approved 2026-07-07).
- §4: Inspector control panel (logging controls)
- §5: Long-polling endpoints — off by default, temporary capture with countdown
- §8: Hard implementation constraints (cluster-safe timers, no node-local Process timers)

Visual/interaction reference: `trace-map-leitstand-dummy.html` (interactive browser dummy), sections "Inspector" and gray-dashed off-nodes with countdown.

**Out of scope:** The live-stream panel (already shipped in `trace-map-leitstand`); other monitoring features.

## Acceptance Criteria

### AC1: Inspector Logging Controls — Min Level Select

When a node is inspected (focused/clicked on the Trace Map), the inspector panel below the live stats renders a "Logging" section with a **Min level select** (DEBUG/INFO/WARN/ERROR):
- The select is wired to the per-endpoint collection level from `admin-logs-retention-settings` (already done)
- On mount/focus, the select is pre-populated with the endpoint's current configured level from the server_config
- Changing the select triggers a server round-trip to persist the new level (via the existing `Nebu.Admin.DB.upsert_server_config/1` API)
- **For domain/nebu nodes**: the label reads "Applies to all endpoints in this domain" (or "on the map" for nebu); the setting cascades to all descendant endpoints as a batch operation
- **For satellite/endpoint nodes**: the label reads "Applies to this endpoint only"
- The select never loses focus or value during re-renders (pinned by a test: the panel is built once per inspected node, only stat values update per tick)

### AC2: Inspector Logging Controls — Retention Select

When a node is inspected, the "Logging" section also renders a **Retention select** (1 h / 24 h / 7 d / 30 d):
- Wired to the per-endpoint retention days from `admin-logs-retention-settings`
- Pre-populated from server_config on mount/focus
- Changing the select persists the new retention window
- Same cascade rules as AC1 (domain/nebu cascade; endpoint is solo)
- Same focus-preservation guarantee

### AC3: Inspector Built Once Per Node, Only Stats Update

The inspector panel HTML structure and form elements are BUILT once when a node is inspected (focused/clicked). On every subsequent stat update (new log entry, window slide), only the **stat values** (request count, warning count, error count, last 5 events) are patched via LiveView assigns — not the entire panel markup.

**Test pinned:** Click node → panel renders → assert select `value` and `focus` are correct. Inject log entry → stat patch happens → assert select still has same `value` and is still focused (if it was before).

### AC4: Long-Polling Off-by-Default — Config-Driven List

A config-driven list of long-polling endpoints (default: `/_matrix/client/v3/sync`, `/admin/keepalive`, `/health`) are rendered as **logging-off nodes**:
- **Rendered state**: gray fill (base-200 @ 15%), text-disabled dashed 1.5px stroke, count shows "off" text (not a number), no status color, no error/warn badges
- **Data not collected**: entries for these endpoints are NOT persisted to `operational_logs` (server-side enforcement via policy), and the status window shows zero requests/warnings/errors
- **No status propagation**: a parent domain with ALL children as off-endpoints shows no status (no error/warn/ok; just gray and dashed like its children)
- **Backend concept reused from noise-endpoint-bucketing**: a hardcoded constant (or config key) defines which endpoints are in the off-by-default list; the same list is used by all consuming stories (reuse potential for future war-room-dedicated-page)
- **Configuration**: the list is defined as `@long_polling_endpoints = [...]` (or similar) in `Nebu.Admin.LogsLive.TraceMap`, with clear documentation; a public function `def long_polling_endpoints()` exposes it for reuse

### AC5: Click Off-Node Enables Temporary Capture (5 Minutes)

Clicking on an off-tier endpoint enables **temporary capture** for 5 minutes:
- Server-side timer: a stateful capture record is inserted into a temporary store (e.g., `admin_temporary_captures` table, or a volatile in-memory structure backed by a periodic cleanup task), recording `endpoint`, `enabled_at`, `expires_at` (now + 5 minutes), and `started_by` (current admin user)
- **NOT client-only state**: the capture timer is enforced server-side; no client-side `setTimeout` that breaks on page reload/crash
- **Cluster-safe**: if the deployment is multi-node, the temporary capture record is in the shared database or a distributed cache (follow the pattern used by `war_room_manager` — design decision notes below)
- While capturing, the node becomes **live** with dashed status stroke + countdown on the node and in the inspector panel
- Visual state: "temp capture" from the spec (as status, dashed stroke, countdown mm:ss)
- Log entries for the endpoint are now collected (the policy check skips the off-list while capture is active)
- **Early disable button**: the inspector panel shows "Disable now" button (when capture is active), which manually ends the capture before expiry
- **Auto-revert**: when the timer expires, the endpoint reverts to off automatically with no manual intervention
- **Aria-live announcements**: enable event announces "Capture enabled for X endpoint — 5 minutes" (or similar); disable/expiry announce "Capture ended" or "5 minutes expired"

### AC6: Temporary Capture Countdown Display

When capture is active on a node:
- The node itself displays countdown mm:ss (e.g., "04:32" for 4 minutes 32 seconds remaining)
- The inspector panel displays the same countdown + "Disable now" button
- Countdown updates live every second (client-side, computed from server's `expires_at` — no server tick needed; the expiry time is set once, client updates every 1 s via JS hook)
- On expiry, the countdown disappears and the node reverts to off state (gray + dashed, count "off", no countdown)

### AC7: While Capturing, Stream Filter Works Normally

While a node is in temporary-capture state:
- A second click (or Enter/Space key) toggles the node's inclusion in the stream filter (same as any other node)
- The capture timer continues regardless of filter state
- Clicking "Disable now" in the inspector ends the capture (node reverts to off, filter is NOT automatically removed if active)
- This allows the operator to enable capture, then immediately filter by that endpoint to watch its logs, then disable capture early if they see what they need

### AC8: Visual States — Off (Logging-Off) and Temp (Temporary Capture)

Two new visual states, defined in the Trace Map legend (already rendered in `trace-map-leitstand`):
- **Off**: base-200 @ 15% fill, text-disabled dashed 1.5px stroke, "off" text label, no status color
- **Temp**: status color (ok/warn/error) fill, status color dashed stroke, countdown mm:ss on the node, no badges (until capture ends and status is evaluated)

Status is never color-alone; the "off" text, countdown, and aria-labels make the state explicit.

### AC9: Accessibility — Labels, Keyboard, Announcements

- Inspector selects (min level, retention) are labelled with `<label for="...">` elements
- Clicking an off-node, pressing Enter/Space on a focused off-node, or clicking "Disable now" dispatches aria-live announcements:
  - Enable: "Temporary capture enabled for [endpoint name] · 5 minutes"
  - Disable: "Temporary capture disabled for [endpoint name]"
  - Expiry: "Temporary capture expired for [endpoint name]"
- Aria-labels on off-nodes read "off" (e.g., "sync endpoint · /_matrix/client/v3/sync · logging off")
- Aria-labels on temp-capture nodes include countdown (e.g., "sync endpoint · /_matrix/client/v3/sync · temporary capture · 4 minutes 32 seconds remaining")
- "Disable now" button has `aria-label="Disable capture for sync endpoint"` or similar

### AC10: CSP & Security Compliance

- No inline JS; countdown updating via app.js `TraceMapLeitstand` hook (existing hook from `trace-map-leitstand`, extended with capture-state awareness)
- Inspector form: POST to a new server action or a LiveView event (`handle_event("configure_logging", ...)`)
- Capture enable/disable: POST/DELETE or `handle_event("enable_capture", ...)` / `handle_event("disable_capture", ...)` on the LiveView
- CSRF token included in any form
- No raw endpoint names exposed in URLs (filter state is already URL-safe per `trace-map-leitstand`'s filter-state design)

### AC11: E2E Test Coverage — Inspector Controls & Capture

New BDD scenarios (in `e2e/features/admin/logs-trace-map.feature`, or a new file if preferred):

**Scenario A: Inspector loads with endpoint's current logging config**
- Given I click an endpoint node on the Trace Map
- Then the inspector panel shows the endpoint's current min level and retention from the config
- When I change the min level to DEBUG
- Then a server round-trip persists the change
- And the inspector panel's level select still has focus (pinned: focus is not lost)

**Scenario B: Cascade — changing domain node config applies to all satellites**
- Given I click a domain node (e.g., "Matrix Client")
- Then the inspector panel's level select shows "Applies to all endpoints in this domain"
- When I change the level to WARN
- Then all satellites under the domain inherit WARN level (verified via a second page load or a Playwright DB query)
- And a success message appears ("Updated X endpoints")

**Scenario C: Off-endpoint enable capture**
- Given an off-endpoint (e.g., "/health") is rendered as gray + dashed with count "off"
- When I click the node
- Then the inspector panel shows "Logging is off" + "Enable capture for 5 minutes" button (or similar)
- When I click "Enable capture"
- Then the node becomes live with countdown mm:ss (e.g., "04:59")
- And aria-live announces "Temporary capture enabled for /health · 5 minutes"
- And the countdown updates every second (visual test: verify 04:59 → 04:58 after ~1 second)

**Scenario D: Countdown expires and auto-reverts**
- Given capture is active on an off-endpoint with countdown visible
- When I wait for the countdown to reach 00:00 (or simulate via server-side time-travel if testable)
- Then the node reverts to off state (gray + dashed, count "off", no countdown)
- And aria-live announces "Temporary capture expired for /health"

**Scenario E: Early disable**
- Given capture is active with countdown "02:15"
- When I click "Disable now" in the inspector panel
- Then the node immediately reverts to off
- And aria-live announces "Temporary capture disabled for /health"

**Scenario F: While capturing, filter toggle works**
- Given capture is active on "/sync"
- When I click the node again (while capturing)
- Then the node shows a selection ring (filter is toggled on)
- When the countdown expires
- Then the node reverts to off (filter may remain active or be cleared, per design decision in Dev Notes)
- And the stream continues to show entries if the filter was active

### AC12: Persistence & Audit — Capture Enable/Disable Actions

**Design decision point (to be clarified in Dev Notes):**

**Option A (No audit log entry):** Temporary capture enable/disable are not recorded in the compliance audit log. They are user-facing logging experiments, not configuration changes.

**Option B (Admin actions in audit log):** Temporary capture enable/disable are recorded as admin actions in `compliance_audit_log` (similar to how `admin-logs-retention-settings` records setting changes), with the format: `action: "enable_temporary_capture" / "disable_temporary_capture"`, `resource_type: "endpoint"`, `resource_id: endpoint_name`, `admin_user: current_user`, `timestamp: now()`.

**For this story**, adopt **Option A (no audit)** as the baseline unless the security review mandates otherwise. The rationale: temporary captures are transient experiments (5 min expiry), not persistent configuration changes, and they're already logged implicitly by the operational_logs themselves (entries that wouldn't normally be persisted are being persisted, which is visible in the logs store).

### AC13: Superseding noise-endpoint-bucketing Story

The story `docs/stories/enhanced-logging/noise-endpoint-bucketing.md` (status: ready-for-dev) proposed a "Polling/Keepalive" bucket/collapse-expand UI in the Trace Map's endpoint dimension. Phil's Leitstand redesign supersedes that UI concept.

**This story supersedes that story's implementation scope by:**
1. Marking `noise-endpoint-bucketing` as status: `superseded` (with a note: "UI concept merged into `trace-map-node-controls` — reuse backend constant")
2. Reusing the backend concept: the canonical constant `@long_polling_endpoints` (or `@noise_endpoints`, using the naming from the superseded story for continuity) is the same list the superseded story would have used
3. Documenting the deprecation in `noise-endpoint-bucketing.md`'s frontmatter and a note in this story's Dev Notes

**The PM/coordinator should:**
- Mark `noise-endpoint-bucketing` as status `superseded` in the planning artifact
- No implementation work is needed for that story (it is merged into this one)

## Dev Notes

### Files to Create/Modify

**Modify:**
- `server/lib/nebu/admin/logs_live/trace_map.ex` (add inspector logging controls, off-endpoint list, capture timer logic, event handlers)
- `server/lib/nebu/admin/logs_live/trace_map_status.ex` (may need to handle off-endpoints differently if they should show zero in the status window)
- `server/priv/static/assets/app.js` (`TraceMapLeitstand` hook extended: countdown timer updates, "Disable now" click handler)
- `server/assets/css/app.css` (visual states for off/temp if not already covered by `trace-map-leitstand`)
- `server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs` (extend existing tests to cover new inspector controls and capture logic)
- `e2e/features/admin/logs-trace-map.feature` (add 6 new scenarios A–F above)
- `e2e/step-definitions/admin/logs-trace-map.steps.ts` (step implementations for capture scenarios)

**Create (if not already in place):**
- Migration or seed script: ensure `admin_temporary_captures` table exists (if using a DB-backed timer; see design decision below). Schema: `endpoint TEXT`, `enabled_at TIMESTAMP`, `expires_at TIMESTAMP`, `started_by TEXT`, `primary_key: (endpoint, started_by)` (exactly one active capture per endpoint per user, or per endpoint globally depending on design choice)

### Design Decisions — Cluster-Safe Temporary Capture Timer

**Problem:** A naive `Process.send_after(self(), {:revert_to_off, endpoint}, 5 * 60 * 1000)` only works on a single node. In a multi-node deployment, when the process crashes or the node is restarted, the timer is lost.

**Solution:** Follow `Nebu.Admin.WarRoomManager`'s pattern:
1. **Insert a record into a temporary captures table** (`admin_temporary_captures` or similar):
   - `endpoint TEXT PRIMARY KEY` (only one active capture per endpoint)
   - `enabled_at TIMESTAMP` (server time when capture started)
   - `expires_at TIMESTAMP` (server time = now + 5 minutes)
   - `started_by TEXT` (admin user who enabled it)
2. **Server-side enforcement at ingest time:** When a log entry arrives for an off-list endpoint, check if a record exists in the temporary captures table with `expires_at > now()`. If yes, persist the entry; if no, skip it (off-tier enforcement).
3. **Cleanup on a timer:** A periodic task (e.g., `Nebu.Admin.TemporaryCapturesCleaner` or integrated into the existing `Nebu.Web.LogStore.Sweeper`) runs every 10–30 seconds and deletes expired records (`DELETE FROM admin_temporary_captures WHERE expires_at < now()`).
4. **LiveView listener:** The LiveView's `handle_info/2` also checks the table on every PubSub message and patches nodes' state if a capture has expired.

**Outcome:** Cluster-safe, survives node restarts, deterministic (server time, not wall-clock).

**Alternative:** Use Redis for the temporary captures table (if Redis is in the deployment). Same logic, just swap the table for a Redis key with TTL. Not recommended unless Redis is mandatory anyway.

**For testing:** Make the 5-minute duration configurable via an Application env var (e.g., `Application.get_env(:nebu, :temporary_capture_duration_s, 300)`), so tests can use a much shorter duration (e.g., 1 second) without waiting 5 minutes. The same pattern is used by `war_room_manager` (AC8/AC10 in `war-room-mode` story).

### Architecture Notes

**Inspector Control Panel:**
- The panel is rendered in `Nebu.Admin.LogsLive.TraceMap.render(:trace_map)`, below the live stats section
- The two selects (`<select name="min_level">`, `<select name="retention_days">`) are part of the inspector panel component
- Each select's `name` attribute is encoded with the inspected node's key (e.g., `min_level[/sync]`, `retention_days[/_matrix/client]`) to distinguish which node's config is being changed
- Or simpler: use a single form per inspector panel rebuild, with a hidden field storing the inspected node's key, and the selects are always for that one node
- On change event (phx-change or phx-submit), the handler extracts the node key and the new value, and calls the same backend that `admin-logs-retention-settings` uses to persist: `Nebu.Admin.DB.upsert_server_config/1` with a map like `%{"log_min_level_/sync" => :debug, "log_retention_days_/sync" => 7}`

**Off-Endpoint List & Capture Logic:**
- Define `@long_polling_endpoints = [...]` in `Nebu.Admin.LogsLive.TraceMap`
- A public function `def long_polling_endpoints()` returns it (for reuse by other modules)
- In the Trace Map's render, filter nodes to check `Enum.member?(@long_polling_endpoints, node.key)` to determine if the node is off-tier
- In `handle_event("enable_capture", ...)` or similar, insert a record into `admin_temporary_captures` and broadcast a PubSub message to update the LiveView
- The countdown display is computed client-side in the `TraceMapLeitstand` hook: `Math.max(0, (expires_at_ms - Date.now()) / 1000)` every second

**Cascade for Domain/Nebu Nodes:**
- If the inspected node is a domain or nebu, the select change triggers a batch operation: instead of a single `upsert_server_config`, call a helper (e.g., `apply_config_to_descendants(node_key, new_config)`) that updates all satellite endpoints under the domain (or all endpoints on the map, for nebu)
- Implementation: for each descendant, call `upsert_server_config` in a transaction or a loop
- Success flash: "Updated X endpoints" (where X is the count of affected satellites)

**Focus Preservation on Inspector Panel:**
- The inspector panel is rendered as a separate component (or template section) that is only re-rendered when the inspected node changes (not on every stat update)
- Use Phoenix.LiveView's `assign/3` for stat updates only; stat updates should NOT trigger a re-render of the selects
- In Playwright tests, verify that `await page.locator('select[name="min_level"]').focus()` persists across stat updates (LiveView patches the stat values without touching the select element's DOM)

### Testing Strategy

**Unit tests** (`logs_live/trace_map_leitstand_test.exs`):
- Mount with an off-tier endpoint present → verify gray + dashed rendering, count shows "off"
- Click off-tier endpoint → enable capture → verify node state changes to temp, countdown appears
- Wait for expiry (or simulate via time-warp in test) → verify node reverts to off
- Click "Disable now" → verify immediate revert
- Inspector selects: change level → verify server round-trip and persistence
- Domain node: change level → verify batch update of all satellites (query DB to confirm)
- Focus preservation: click node → select gets focus → inject log entry (handle_info) → verify select still focused

**Integration tests** (same file):
- Full-stack: enable capture → check `admin_temporary_captures` table → verify entry exists
- Cleanup timer: insert expired record → run cleanup task → verify record deleted
- PubSub broadcast: enable capture on one page → another page listening → verify state updates without reload

**E2E tests** (`logs-trace-map.feature`):
- Scenarios A–F above, using Playwright to interact with UI and await countdown updates
- No sleeps: use `await page.waitForTimeout(1000)` or similar for the 1-second countdown update, or use `await page.waitForFunction(...)` to wait until countdown text changes

### Reuse Points for Future Stories

1. **Canonical noise endpoint list:** `Nebu.Admin.LogsLive.long_polling_endpoints()` is the single source of truth for "which endpoints are low-signal" — reused by any future story that needs to identify polling endpoints (e.g., war-room-dedicated-page's "safe scope" option, trace-map-hierarchy's domain-grouping logic)
2. **Temporary capture pattern:** The `admin_temporary_captures` table and cleanup task provide a reusable template for other time-limited operations (though temporary capture itself is specific to this story)
3. **Inspector panel pattern:** The read-once-update-stats approach (panel built once per node, only stat values patched) is a good pattern for any inspector-like panel that needs to preserve form state during live updates

### Security Notes

- **Sensitive data:** Off-tier endpoints are still endpoints (routes), not payloads. Rendering them as "off" is transparent (they appear in the legend, in the map, on the inspector label). No sensitive data leakage.
- **Capture enable/disable:** Requires admin auth (inherited from the LogsLive's `:admin` gate). No open API.
- **Temporary capture duration:** Hardcoded to 5 minutes, enforced server-side, with a configurable test override. Operators cannot arbitrarily extend or remove the timer.
- **Audit (Option A chosen):** No compliance log entries, but the operations themselves are opaque to the operator (they enable capture, entries appear in `operational_logs`, they can read them). If a compliance review later requires audit entries, Option B can be added in a follow-up story.

## Known Challenges & Design Decisions

1. **Off-tier status propagation:** A parent domain with ALL children as off-tier (e.g., `/admin` with only `/admin/keepalive` as its satellite) should itself be off-tier (gray + dashed). Implement this by checking in the status-propagation logic: if all children are off, parent is off; otherwise, parent inherits worst-status from capturing children.

2. **Capture expiry visibility:** The expiry is server-side, but the countdown display is client-side. If the browser tab is closed and reopened during a capture, the page loads fresh; on mount, the LiveView checks the `admin_temporary_captures` table and re-renders the node in temp-capture state with an updated countdown. This requires the `expires_at` timestamp to be sent to the client on every mount (or on every stat update, if the page is already loaded).

3. **Multiple endpoints, multiple captures:** If the operator enables capture on two off-tier endpoints simultaneously, two rows exist in `admin_temporary_captures`. Each countdown is independent. Cleanup runs periodically and deletes both when their respective expiry times are reached. No special ordering or batching needed.

4. **Filter state during capture:** If the operator enables capture on `/sync`, then filters by `/sync`, then disables capture early, the filter remains active (nodes can be filtered and captured independently). The stream continues to show `/sync` entries because the filter is active. Disabling capture does NOT clear filters (even if the node becomes off-tier again, it stays in the filter state).

## References & Cross-Story Coordination

- **Depends on:** `trace-map-leitstand` (shipped, provides the base Leitstand page and inspector panel structure)
- **Depends on:** `admin-logs-retention-settings` (shipped, provides config storage and API for log level/retention)
- **Blocks:** None (standalone feature)
- **Supersedes:** `noise-endpoint-bucketing` (UI concept merged into this story; backend concept reused)
- **Coordinates with:** `war-room-dedicated-page` (potential future reuse of the `long_polling_endpoints` constant for war-room scopes)
- **Coordinates with:** `trace-map-hierarchy` (potential future integration of off-tier endpoints into the hierarchy tree)

## Definition of Ready

All ACs are present and testable. The story is ready for development once:
1. Security review confirms the temporary capture timer design is acceptable (or recommends an alternative)
2. PM clarifies AC12 (audit log: Option A or Option B) if a preference exists
3. Coordinates with `noise-endpoint-bucketing` to mark it as superseded

## Story Amendments

(None at time of creation.)

## Questions for Dev Agent — ANSWERED (coordinator/design owner, 2026-07-07)

1. **Cluster-safe timer design: database-backed** (`expires_at` timestamp column; state is a row, expiry is a comparison against now() — no process timer owns correctness). Follow the war_room_manager precedent for the polling/refresh side. Rationale: Nebu is compliance-native and self-hosted with multi-node ambitions (cluster-safety convention); in-memory captures silently outliving or vanishing across deploys/nodes is exactly the class of bug this epic keeps meeting.

2. **AC12 audit logging: Option B — YES, audit-log capture enable/disable.** Enabling collection on a previously-off endpoint is an admin-initiated change to logging policy (same category as retention-settings changes — follow that story's audit precedent). Kassandra reviews this story; Option B preempts the obvious finding.

3. **Capture duration via `Application.get_env(:nebu, :temporary_capture_duration_s, 300)`: approved** (war_room_manager pattern). E2E may alternatively seed an about-to-expire capture row via the db.ts fixture.

## File List

- `server/lib/nebu/admin/logs_live/trace_map.ex` (modified — inspector controls, off-endpoint list, capture enable/disable handlers, cascade logic)
- `server/lib/nebu/admin/logs_live/trace_map_status.ex` (modified if needed — off-tier status handling)
- `server/priv/static/assets/app.js` (modified — `TraceMapLeitstand` hook extended with countdown timer and capture state)
- `server/assets/css/app.css` (modified or verified — off/temp visual states)
- `server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs` (extended — inspector controls, capture logic)
- `server/priv/migrations/XXXXXXX_admin_temporary_captures_table.up.sql` (new — create `admin_temporary_captures` table)
- `server/priv/migrations/XXXXXXX_admin_temporary_captures_table.down.sql` (new)
- `e2e/features/admin/logs-trace-map.feature` (extended — 6 new scenarios A–F)
- `e2e/step-definitions/admin/logs-trace-map.steps.ts` (extended — step implementations for capture scenarios)
- `docs/stories/enhanced-logging/noise-endpoint-bucketing.md` (marked as superseded, with note to reuse backend constant)

## Summary

This story completes the Trace Map Leitstand by making the inspector panel an interactive logging control center. Per-endpoint collection levels and retention windows are now configurable from the map itself (wired to the existing retention-settings backend). Long-polling endpoints (sync, keepalive, health) are off by default — gray, dashed, no data — keeping the signal-to-noise ratio high. A single click enables temporary 5-minute logging captures with server-side timers, countdown countdowns, and automatic expiry. The backend concept for identifying low-signal endpoints is reused from the superseded `noise-endpoint-bucketing` story, ensuring a single source of truth for future stories.

---

# Acceptance Criteria Summary

| AC | Title | Type |
|----|----|------|
| 1 | Inspector Min Level Select | Feature |
| 2 | Inspector Retention Select | Feature |
| 3 | Inspector Built Once, Stats Update Only | Constraint |
| 4 | Long-Polling Off-by-Default — Config-Driven | Feature |
| 5 | Click Off-Node Enables 5-Min Capture | Feature |
| 6 | Countdown Display mm:ss | Feature |
| 7 | While Capturing, Filter Works Normally | Behavior |
| 8 | Visual States Off/Temp | Visual |
| 9 | Accessibility — Labels, Keyboard, Announcements | A11y |
| 10 | CSP & Security Compliance | Security |
| 11 | E2E Test Coverage — 6 Scenarios | Test |
| 12 | Persistence & Audit — Capture Actions | Policy |
| 13 | Superseding noise-endpoint-bucketing | Coordination |

**Total: 13 ACs**

## Story Amendments (2026-07-07, coordinator/design owner)

- **One-click capture enable confirmed** (ATDD flag 1): clicking an off node enables
  capture immediately (dummy behavior, AC5/AC7 contract); the inspector "Enable" button
  exists for the post-early-disable state only. The intermediate click-then-Enable flow
  from the original AC text is superseded.
- **Retention options** (ATDD flag 4): the select offers **1 d / 7 d / 30 d**, mapping
  to the existing day-granularity retention backend. The dummy's "1 h" option is
  dropped — hour-granularity retention is out of scope for this story.
- **AC4 errors-always-persist exception (2026-07-07, test-review m3, design owner):**
  "logging off" suppresses DEBUG/INFO/WARN collection AND status, but **ERROR-level
  entries are always persisted and always drive node status** — an off node with errors
  in the 60 s window renders the error state on its dashed stroke (red dashed + ✕ badge
  + count). Rationale: a silently-red zone contradicts the leitstand mission; "off"
  silences noise, never failures. Spec §5 is amended accordingly.
