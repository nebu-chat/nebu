---
id: war-room-mode
title: "War Room Mode — bounded, self-terminating diagnostic logging sessions"
epic: enhanced-logging
status: done
security_review: required
matrix: true
ui: true
created: 2026-07-04
---

# War Room Mode

## Story

**As** a Nebu platform operator or support engineer,
**I want** a way to temporarily enable elevated logging (DEBUG+ scope) in a bounded, tagged, self-terminating session — scoped by endpoint, user, or device, with automatic budget enforcement,
**so that** I can diagnose live issues without (a) forgetting to turn verbose logging back off, (b) flooding the operational log database with excessive entries if elevated logging happens to land on a high-frequency endpoint like `/sync`, or (c) having to redeploy the server to enable collection.

The standard operational-log-store posture is quiet: only WARN/ERROR are visible/collected by default. But "bei Bedarf" (when something is actually wrong), an admin must have a bounded, safe way to go verbose temporarily. War Room Mode is distinct from the operational-log-store's per-level DEBUG retention toggle (a separate story: a persistent on/off switch for DEBUG collection) — War Room is a **diagnostic session with enforced limits**: a maximum number of entries, a maximum duration, precise scoping rules, and automatic termination when either budget is exhausted.

## Background

### Current State

Per the operational-log-store story, the standard logging policy is conservative: by default, only WARN/ERROR entries are persisted to the operational_logs table. A DEBUG-level toggle exists to allow elevated collection when needed (via env var or admin UI), but it is a global on/off switch that (a) requires operator discipline to remember to turn off, and (b) has no bounds — if a high-frequency endpoint like `/sync` is involved and gets matched by an elevated logging session, the database can fill with thousands of entries per second.

### Motivation

Two support workflow pain points:

1. **Investigation requires tedious redeploy cycles**: When a live issue appears (e.g., "user cannot sync," "search endpoint returns errors"), the only way to gather diagnostic data currently is to (a) enable debug collection, (b) wait for the operator to reproduce the issue, (c) gather logs, (d) disable debug collection, (e) redeploy. This is slow, manual, and error-prone. A self-contained, bounded diagnostic session would make this instant and safe.

2. **Risk of database flooding**: `/sync` (the Matrix client long-poll endpoint) is called continuously by every connected client — once per few seconds, multiplied by dozens/hundreds of active users in a large deployment. If an operator enables elevated logging and that scope includes `/sync` (unintentionally or under time pressure), the operational_logs table can grow from kilobytes to gigabytes in seconds, degrading the live platform. A strict per-session budget (max entries, max duration) with precise scoping (e.g., "only user @alice:localhost, all endpoints") prevents this.

### Compliance & Safety

War Room Mode is **not** intended to capture message content — that is the redaction layer's job (implemented in the matrix-payload-debug-logging story). War Room simply decides "which logs get persisted at all during this window, and for how long." The redaction layer still applies to everything War Room collects, so even elevated logging is still privacy-safe. See the operational-log-store story for the schema and writer GenServer; this story assumes it exists and focuses on session management and UI.

## Acceptance Criteria

### Session Lifecycle

**AC1:** A new table `war_room_sessions` (UUID primary key, created_at/started_at, admin/reason text, scope, filters, max budgets, end markers) is added to the database schema. A migration file is created and applied.

**AC2:** Exactly one war room session may be active at any given time (strict v1 simplification). Attempting to start a second session while one is active returns a clear error message (e.g., "War Room already active, started by admin X at T, reason: Y — end it first"). Restarting the same session (idempotent) is allowed if the session exists, is active, and the admin's request matches the original parameters.

**AC3:** A war room session is created with the following required parameters:
- `started_by`: text (admin user_id for accountability)
- `reason`: text (free text, e.g., "FluffyChat sync bug investigation")
- `max_entries`: integer (hard budget: when `entries_collected` reaches this, session auto-terminates with `ended_reason = "budget_exhausted"`)
- `max_duration_s`: integer (in seconds; when elapsed time from started_at exceeds this, session auto-terminates with `ended_reason = "duration_exceeded"`)

And optional parameters:
- `scope`: text, one of `"all"` (no endpoint filtering) | a route_template (e.g., `"/_matrix/client/v3/sync"`) | NULL (treated as `"all"`). If a specific route, only HTTP requests matching that exact path pattern contribute to this session's collection and entry count.
- `filter`: JSONB, optional structured scope (e.g., `{"user_id": "@alice:localhost"}` or `{"device_id": "..."}` or both). If present, only logs matching ALL filter fields (AND semantics) are collected. NULL/empty = no additional filtering.

**AC4:** When a session is active, the operational-log-store's writer GenServer (assumed to exist from that story) checks every incoming log entry against the active war room session's scope/filter. If the entry matches:
1. It is persisted to operational_logs (regardless of the ambient per-level retention policy — e.g., even DEBUG entries that would normally be discarded are saved).
2. It is tagged with `war_room_id` (a new nullable column on operational_logs, pointing back to the war_room_sessions.id).
3. `war_room_sessions.entries_collected` is incremented.
4. If `entries_collected` now equals `max_entries`, the session is atomically marked as ended: set `ended_at = now()`, `ended_reason = "budget_exhausted"`.

**AC5:** Every war room session has a timer scheduled at creation. If the session is still active when the timer fires (at start_time + max_duration_s), the session is marked as ended: set `ended_at = now()`, `ended_reason = "duration_exceeded"`. The timer runs in the same writer GenServer (or a sibling lightweight process in Nebu.Application, given the "exactly one active" constraint from AC2) — no per-session process spawn.

**AC6:** The session can be manually ended by an admin via an HTTP endpoint (presumed to be part of the admin-logs-monitoring-view story). When manually ended: set `ended_at = now()`, `ended_reason = "manual_stop"`, mark the session inactive so no further entries are collected against it.

### Scope & Filter Validation — `/sync` Safety

**AC7:** If a war room is started with `scope = "all"` (or NULL), the admin UI shows a prominent warning: "Warning: collecting all endpoints. High-frequency endpoints like `/sync` can generate 1000s of entries per second. Recommend narrowing scope (by user_id/device_id) or keeping max_entries/max_duration_s conservative." This is the same warning class as the admin-logs-retention-settings story uses when recommending caution about DEBUG retention globally.

**AC8:** If a war room is started with `scope` set to `"/_matrix/client/v3/sync"` specifically, the UI shows a **stronger** warning: "⚠️ `/sync` is called continuously by every client. Unless you are targeting a single user/device, this will fill your log budget in seconds. Require max_entries ≤ 100 and max_duration_s ≤ 300, or cancel."

**AC9:** Scoping by `user_id` and/or `device_id` is the primary safe pattern. The filter UI for starting a war room includes simple text input fields for these two dimensions (not a generic query language — deliberately simple, per Rule-of-Three). If the user enters `@alice:localhost` in the user_id field and `GHTYAJSQZD` (or any device_id) in the device field, the filter is `{"user_id": "@alice:localhost", "device_id": "GHTYAJSQZD"}`, and only logs from that specific user-device pair are collected.

**AC10:** Verify at migration time that the operational_logs table has a `war_room_id` column (UUID, nullable foreign key to war_room_sessions). If the column is missing, the migration adds it as a fallback. This is a cross-story coordination note: the operational-log-store story should add this column; if it is not present when this story's migration runs, this story adds it to be safe.

### UI Integration

**AC11:** The War Room start/stop control is a visually distinct, prominent panel on `/admin/logs` (the monitoring view built in admin-logs-monitoring-view). It includes:
- A large toggle or button: "🚨 Start War Room" (when inactive) or "🚨 War Room Active" (when active, red/alert styling).
- When active: shows a live status bar with budget remaining ("73/100 entries · 2:14 remaining · started by admin X at T for reason: Y").
- When inactive: shows a form to start a new session:
  - `reason` (text input)
  - `scope` dropdown: `all` | `/_matrix/client/v3/sync` | (optional) other high-frequency endpoints
  - `user_id` (text input, optional, e.g., `@alice:localhost`)
  - `device_id` (text input, optional, e.g., `GHTYAJSQZD`)
  - `max_entries` (number input, default 100, range 10–10000)
  - `max_duration_s` (number input, default 300, range 10–3600)
  - A "Start" button and contextual warnings per AC7–AC8.

**AC12:** The request stream/detail panel in the admin-logs-monitoring-view should support filtering by `war_room_id` in addition to existing filters (level, endpoint, time range, etc.). If the monitoring-view story's stream component does not have an obvious extension point for this, flag it as a coordination note in Dev Notes; do not silently reimplement the stream component. The goal is: an admin should be able to pull up a completed war room session and say "show me all logs tagged with war-room-session-X" as a coherent, bookmarkable slice.

## Acceptance Tests

### Tests written FIRST (ATDD):

1. **[AC1] war_room_sessions table exists and migration applied** — ExUnit `:integration`
   - Given: A fresh test database
   - When: The migrations are run
   - Then: The `war_room_sessions` table exists with columns: id (UUID), started_at, started_by, reason, scope, filter (JSONB), max_entries, max_duration_s, ended_at, ended_reason, entries_collected
   - And: operational_logs table has a `war_room_id` column (nullable, UUID FK)

2. **[AC2] Exactly one active war room session allowed** — ExUnit `:unit`
   - Given: A war room session is active (started_at set, ended_at NULL)
   - When: Another admin attempts to start a second war room
   - Then: The API returns a 409 Conflict error with a message like "War Room already active, started by admin X at T, reason: Y"
   - And: The second session is NOT created

3. **[AC2] Idempotent restart of same session** — ExUnit `:unit`
   - Given: A war room session with id=W, started_by=admin-X, reason="test", scope="all", max_entries=100, max_duration_s=300, is currently active
   - When: The same admin calls start again with identical parameters
   - Then: The API returns success (or idempotent: 200 or 409 with "same session already running")
   - And: Only one row in war_room_sessions table (no duplicate created)

4. **[AC3] Session created with all required parameters** — ExUnit `:integration`
   - Given: An admin requests `POST /admin/war-room/start` with `{"started_by": "admin-1", "reason": "sync investigation", "max_entries": 50, "max_duration_s": 120}`
   - When: The request is processed
   - Then: A row is created in war_room_sessions with those values, started_at = now(), ended_at = NULL, entries_collected = 0
   - And: The API returns the session id

5. **[AC3] Optional scope and filter parameters** — ExUnit `:integration`
   - Given: An admin requests start with scope=`"/_matrix/client/v3/sync"` and filter=`{"user_id": "@alice:localhost"}`
   - When: The request is processed
   - Then: The session row has those values in scope and filter columns
   - And: No error is raised

6. **[AC4] Log entry matching scope/filter is tagged with war_room_id** — ExUnit `:integration`
   - Given: An active war room with scope=`"/_matrix/client/v3/sync"`, filter=NULL, max_entries=1000
   - When: A log entry for `/_matrix/client/v3/sync` (matching scope) is written to operational_logs
   - Then: The entry is persisted (regardless of ambient retention policy, e.g., even DEBUG level)
   - And: The entry's `war_room_id` column references the active session
   - And: The session's `entries_collected` increments by 1

7. **[AC4] Log entry NOT matching scope/filter is not tagged** — ExUnit `:integration`
   - Given: An active war room with scope=`"/_matrix/client/v3/sync"` (only this endpoint)
   - When: A log entry for a different endpoint (e.g., `/_matrix/client/v3/profile/@alice:localhost`) is written
   - Then: The entry's `war_room_id` is NULL (not tagged)
   - And: The session's `entries_collected` does NOT increment

8. **[AC4] Log entry matching filter (user_id + device_id)** — ExUnit `:integration`
   - Given: An active war room with filter=`{"user_id": "@alice:localhost", "device_id": "DEVICE1"}`
   - When: A log entry with matching user_id and device_id is written
   - Then: It is tagged with the war_room_id
   - And: A log entry with the same user_id but different device_id is NOT tagged (filter requires ALL fields to match)

9. **[AC4] Budget enforcement: entries_collected reaches max_entries, session auto-terminates** — ExUnit `:integration`
   - Given: An active war room with max_entries=5
   - When: The 5th matching log entry is written
   - Then: That entry is persisted and tagged with war_room_id
   - And: The session is atomically marked ended: ended_at is set to a timestamp ≈ now(), ended_reason = "budget_exhausted"
   - And: The 6th matching entry written after this is NOT tagged (session is no longer active)

10. **[AC5] Duration timer: session auto-terminates when elapsed time exceeds max_duration_s** — ExUnit `:unit`
    - Given: A war room session started at T with max_duration_s=2
    - When: The timer fires at T+2 seconds (or the check is triggered)
    - Then: The session is marked ended: ended_at ≈ T+2, ended_reason = "duration_exceeded"
    - And: Subsequent log entries are no longer tagged (session is inactive)

11. **[AC6] Manual stop: admin ends session via HTTP endpoint** — ExUnit `:integration`
    - Given: An active war room session with id=W
    - When: An admin calls `POST /admin/war-room/W/stop`
    - Then: The session is marked ended: ended_at = now(), ended_reason = "manual_stop"
    - And: Subsequent matching log entries are not tagged

12. **[AC7/AC8] UI warnings for broad scope** — ExUnit `:unit` (UI/component test, or manual verification in dev)
    - Given: The War Room start form
    - When: scope is set to `"all"` or NULL
    - Then: A warning message appears: "Warning: collecting all endpoints..."
    - When: scope is set to `"/_matrix/client/v3/sync"`
    - Then: A stronger warning appears: "⚠️ `/sync` is called continuously..."
    - And: The form enforces max_entries ≤ 100 and max_duration_s ≤ 300 (or shows error if admin tries to exceed)

13. **[AC10] Migration adds war_room_id column if missing** — ExUnit `:integration`
    - Given: An operational_logs table WITHOUT a `war_room_id` column
    - When: This story's migration runs
    - Then: The column is added (UUID, nullable, FK to war_room_sessions.id)
    - And: No error is raised

14. **[AC11] War Room UI panel is rendered on /admin/logs** — ExUnit `:integration` (Phoenix template test or E2E)
    - Given: An admin navigates to `/admin/logs`
    - When: The page loads
    - Then: The War Room panel is visible with "🚨 Start War Room" button
    - And: The panel is styled distinctly (alert color, prominent placement)

15. **[AC12] Stream filtering by war_room_id** — ExUnit `:integration`
    - Given: A completed war room session with id=W, and several log entries tagged with that session
    - When: An admin applies a filter for war_room_id=W in the log stream
    - Then: Only entries tagged with that session are displayed
    - And: The filter is bookmarkable (URL query param or similar)

## Dev Notes

### Schema & Migrations

**File Structure:**
- **New:** `server/priv/migrations/YYYYMMDDHHMMSS_create_war_room_sessions.exs` — migration that creates the war_room_sessions table and adds the war_room_id column to operational_logs (if not already present from the operational-log-store story).

**Schema Details:**
```sql
CREATE TABLE war_room_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_by TEXT NOT NULL,                -- admin user_id
  reason TEXT NOT NULL,                    -- free text reason
  scope TEXT,                              -- "all" | route_template | NULL
  filter JSONB,                            -- e.g. {"user_id": "@alice:localhost", "device_id": "..."}
  max_entries INT NOT NULL,                -- hard budget
  max_duration_s INT NOT NULL,             -- in seconds
  ended_at TIMESTAMPTZ,                    -- NULL while active
  ended_reason TEXT,                       -- "budget_exhausted" | "duration_exceeded" | "manual_stop"
  entries_collected INT NOT NULL DEFAULT 0 -- incremented with each matching entry
);

-- On operational_logs table:
ALTER TABLE operational_logs ADD COLUMN war_room_id UUID REFERENCES war_room_sessions(id);
```

### Implementation Strategy

1. **GenServer Integration (writer process — reuse from operational-log-store story):**
   - The operational-log-store story builds a central logger writer GenServer (exact name TBD, e.g., `Nebu.Compliance.OperationalLogWriter`).
   - This story's code adds a **scope/filter matching layer** to that GenServer's write path:
     - Before persisting an entry, check if a war room session is active (query the DB or cache the session in the GenServer's state).
     - If active, test the entry against session.scope and session.filter.
     - If matched, tag the entry with war_room_id and increment entries_collected.
     - If entries_collected now equals max_entries, atomically mark the session as ended.
   - No new process needed — just additional logic in the existing writer's `handle_cast` or `handle_call`.

2. **Session State & Caching:**
   - At application start (`Nebu.Application.start/2`), load the currently active war room session (if any) from the DB and cache it in the writer GenServer's state.
   - On create/stop operations (via HTTP), update the cache + the DB atomically.
   - This avoids querying the DB for every single log entry (performance-critical path).

3. **Duration Timer:**
   - When a session is created, schedule a message to the writer GenServer using `Process.send_after(pid, :check_war_room_timeout, max_duration_s * 1000)` (in milliseconds).
   - The GenServer's `handle_info` clause receives this message and checks: is the session still active (in cache/DB), and is elapsed time ≥ max_duration_s?
   - If yes, mark it ended with `ended_reason = "duration_exceeded"`.
   - Given the "exactly one active" constraint, only one timer is ever scheduled at a time.

4. **Scope/Filter Matching:**
   - A scope is matched if:
     - scope = "all" or NULL → always match
     - scope = a specific route_template (e.g., `"/_matrix/client/v3/sync"`) → match only if the log entry's `endpoint` (or equivalent field in operational_logs) equals that string. For now, exact string match; future enhancements could allow glob patterns.
   - A filter is matched if:
     - filter = NULL/empty → always match
     - filter = `{"user_id": "...", "device_id": "..."}` → the log entry's user_id AND device_id must both match. (AND semantics: all filter fields must be present and equal.)
   - Both must match for the entry to be tagged and counted.

5. **Cross-Story Coordination (operational-log-store):**
   - This story assumes `Nebu.Compliance.OperationalLogWriter` or equivalent exists and is the single place where entries are written to the DB.
   - This story adds code to that writer to check for active war rooms and tag/count entries.
   - If the operational-log-store story's final design differs (e.g., a different writer module name or structure), update this story's implementation to match.
   - The `war_room_id` column on operational_logs may be added by the operational-log-store story (if it anticipated this) or by this story's migration (as a fallback per AC10).

### Admin HTTP Endpoints

**File Structure:**
- **New/Modified:** `server/lib/nebu/admin/war_room_manager.ex` (or similar) — public API module for war room operations (create, stop, get status).
- **New/Modified:** `server/lib/nebu/web/controllers/admin/war_room_controller.ex` (or similar) — HTTP endpoints:
  - `POST /admin/war-room/start` — create a new session
  - `POST /admin/war-room/:id/stop` — stop an active session
  - `GET /admin/war-room/status` — get the current active session (if any)

### UI Integration (admin-logs-monitoring-view dependency)

The monitoring-view story builds `/admin/logs` with a request stream/detail panel. This story integrates War Room controls into that page:
- **New component (or panel extension):** A visually distinct War Room section at the top of `/admin/logs`.
- **Reuse:** The existing log stream component should support filtering by `war_room_id`. If it doesn't have an obvious hook, coordinate with the monitoring-view story to add one (e.g., a filter dropdown or query param), rather than reimplementing the stream.

### Testing Strategy

1. **Unit tests:** War room session creation, scope/filter matching logic, timer scheduling.
2. **Integration tests:** Full flow with database: start session, write matching/non-matching log entries, verify tagging and count, auto-terminate on budget/duration, manual stop.
3. **UI tests:** War Room panel renders, form inputs, warnings, filter integration with log stream.
4. **Security/compliance:** Verify that war room logs are still redacted (two-category redaction from matrix-payload-debug-logging applies), and that the audit trail (who started it, when, why) is clear.

### Excessive-Logging Safety

- **Per AC7–AC8:** UI warnings are the primary mechanism. The form can also enforce hard limits: max_entries ≤ 10000, max_duration_s ≤ 3600 (1 hour), with stronger defaults/caps for `/sync`.
- **No auto-trigger:** This story does NOT implement auto-triggering a war room when an ERROR occurs. That idea (error-triggered retroactive log collection) is a larger architectural pattern (requires always-on light sampling, error-triggered retention upgrade) — explicitly deferred per Phil's reasoning. If that demand appears in future, it is a separate epic.
- **No predicate language:** Scoping is limited to simple user_id/device_id filters. No RSQL, JSONB-path expressions, or generic query language. This is deliberate per Rule-of-Three: one concrete need (investigate a specific user's requests), not three demanding an abstraction.

## Tasks / Subtasks

- [x] Create migration: `war_room_sessions` table, `war_room_id` FK on `operational_logs` (column already existed from operational-log-store's 000017; this migration adds the FK constraint that 000017 deliberately deferred, plus an idempotent `ADD COLUMN IF NOT EXISTS` fallback guard and the "exactly one active" partial unique index)
- [x] Implement `Nebu.Admin.WarRoomManager` public API (`start_session/1`, `stop_session/1`, `status/0`)
- [x] Integrate scope/filter matching logic into `Nebu.Web.LogStore.Handler.log/2`, via a new `Nebu.Web.LogStore.WarRoom` GenServer (design-decisions.md #3/#4 — NOT the Writer, which batches and would break AC4/AC9's single-entry-granularity budget enforcement and "regardless of ambient policy" override)
  - [x] Cache active session in `WarRoom`'s GenServer state (+ a `persistent_term` boolean flag for the hot "nothing active" path)
  - [x] Match log entries against scope/filter (AC3/AC9 AND semantics; opaque/case-sensitive `device_id`)
  - [x] Tag entries with `war_room_id` and increment counter (single atomic `UPDATE ... RETURNING`)
  - [x] Enforce budget and auto-terminate on exhaustion (`budget_exhausted`)
- [x] Implement duration timer in `Nebu.Web.LogStore.WarRoom`
  - [x] Schedule `Process.send_after(self(), {:check_timeout, id}, ...)` on session load (covers both fresh starts and boot/restart)
  - [x] Handle `handle_info({:check_timeout, id}, state)` and auto-terminate on duration exceeded (`duration_exceeded`), including immediately on load for an already-expired session (cross-restart AC5)
- [x] War Room start/stop/status: `handle_event("start_war_room"/"stop_war_room", ...)` in `Nebu.Admin.LogsLive` calling `Nebu.Admin.WarRoomManager` (design-decisions.md #6 — NOT a separate HTTP controller/routes; `/admin/logs` is a LiveView, and every admin mutation in this codebase is a LiveView round-trip or plain-form POST, never a JSON API)
- [x] Implement War Room UI panel on `/admin/logs` (`Nebu.Admin.LogsLive.WarRoomPanel` component)
  - [x] Start form (reason, scope, user_id/device_id filters, max_entries/max_duration_s)
  - [x] Active session status display (live-refreshing via a 2s self-tick while active)
  - [x] Stop button
  - [x] Contextual warnings (AC7–AC8) — static markup, client-side visibility toggle in `app.js`'s `wireWarRoomPanel()`
- [x] Extend `Nebu.Web.LogStore.get_logs/1` to filter by `war_room_id` (1-line `@allowed_filter_keys` addition — the SELECT/`row_to_log/1` already returned it) and `Nebu.Admin.LogsLive.mount/3` to read the `war_room_id` query param and seed the initial stream from that filtered, uncapped query (AC12 — a historical, bookmarkable slice, not the default 200-row live window)
- [x] Write all 15 acceptance tests (ATDD) — already staged before this dev-story ran; extended/fixed 3 genuine test-quality bugs found during GREEN verification (see Completion Notes)
- [x] Implement functionality
- [x] Verify all tests pass
- [x] Full integration test: start war room, generate matching traffic, verify logs tagged and counted, verify auto-termination, verify UI reflection — verified end-to-end against a real Postgres/docker-compose stack (see Completion Notes)

## Dev Agent Record

### Completion Notes

**Architecture** — Implemented exactly per
`_bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md`,
which superseded the story's own (pre-sibling-shipping) Dev Notes on every
point where they conflicted with the actually-shipped
operational-log-store/admin-logs-monitoring-view code. Key real module names
(vs. the story's placeholder guesses): `Nebu.Web.LogStore.WarRoom` (new
GenServer, `server/lib/nebu/web/log_store/war_room.ex`), `Nebu.Admin.WarRoomManager`
(`server/lib/nebu/admin/war_room_manager.ex`), `Nebu.Admin.LogsLive.WarRoomPanel`
(`server/lib/nebu/admin/logs_live/war_room_panel.ex`). No
`war_room_controller.ex`, no new HTTP routes — War Room start/stop is a
LiveView `handle_event` round-trip.

**Real-Postgres integration verification** — Per this project's
no-Ecto-Sandbox convention, verified end-to-end against a real
docker-compose Postgres stack (`make redeploy` + `make test-integration`),
INCLUDING a from-scratch `docker compose down --volumes` + fresh `up` cycle
to rule out any stale-volume artifacts. Final full-suite result: 1729
tests, 0 war-room-related failures (5 unrelated pre-existing flakes: a
timing-budget load test, two retention max-count-cap tests showing
count-contamination from concurrently-running suite traffic, one
rate-limit-count-contamination `/login` test, and one OIDC redirect-scheme
cache-staleness test — none touch `war_room_sessions`/`WarRoom`/
`WarRoomManager`/`LogsLive`'s war-room code, confirmed via `git diff`
against the files each failure's own test exercises). Plain `mix test
--warnings-as-errors` (no live DB): 1374 tests, 0 failures. `mix compile
--warnings-as-errors`: clean.

**3 genuine test-quality bugs found and fixed during GREEN verification**
(none were design decisions — each is a provable defect in the staged
ATDD tests themselves, fixed the same way test-quality issues were handled
earlier in this pipeline for sibling stories):
1. `logs_live_test.exs`'s AC12 test called `Phoenix.LiveViewTest.live/1` on
   a conn that was only *built* (session set via `put_session/3`), never
   actually *sent* through the router — `live/1` requires a sent conn.
   Fixed by dispatching through `@endpoint.call/2` directly (mirroring
   `logs_controller_test.exs`'s own proven admin-session-cookie pattern,
   which — unlike `Phoenix.ConnTest.get/2`'s automatic cookie-recycling —
   does not silently drop the manually-set session). Also fixed: the test
   interpolated the RAW 16-byte Postgrex UUID binary (Postgres's native
   `uuid` type decodes/encodes as a binary, not the human-readable
   hex-dash string every other identifier in this codebase uses) directly
   into a URL query string, producing invalid UTF-8 bytes — converted via
   `Ecto.UUID.load!/1` before building the URL. This same binary-vs-string
   UUID gap was also a **real implementation bug**, not just a test bug:
   `Nebu.Web.LogStore.get_logs/1`'s `war_room_id` filter now normalizes
   either form via `Ecto.UUID.cast/1` + `dump!/1` before binding it as a
   SQL parameter, since a real browser's bookmarked
   `?war_room_id=<uuid>` URL always carries the canonical string form.
   Also seeded `server_config.bootstrap_completed = "true"` in that
   describe block's setup — the ONLY test in the file that mounts through
   the real router (and therefore the `{Nebu.Admin.Auth, :require_admin}`
   `on_mount` hook, which redirects to `/admin/bootstrap` on a genuinely
   fresh, never-bootstrapped database).
2. `handler_test.exs`'s AC4 scope-mismatch test asserted on an INFO-level
   log line without ever elevating `Logger.level()` — `config/test.exs`
   defaults to `:warning`, so `Logger.info/1` is a silent no-op unless some
   *other*, unrelated, concurrently-running test happens to have
   transiently raised the global level at that exact moment. Fixed by
   wrapping the request in `with_log_level(:info, fn -> ... end)`, matching
   this file's own established pattern for its DEBUG-level siblings.
3. `war_room_manager_test.exs`'s AC10 FK test queried
   `information_schema.constraint_column_usage` joined with
   `table_constraints`/`key_column_usage`. Confirmed via `pg_get_viewdef/2`
   that `constraint_column_usage`'s definition filters on ONLY
   `pg_has_role(tableowner, 'USAGE')` — unlike its sibling views, it has NO
   `has_table_privilege` fallback — so it can never show a row for a table
   owned by a role the connecting role isn't a member of. This project's
   docker-compose deployment *always* runs migrations as `nebu_migrate`
   (`server/Dockerfile`'s `NEBU_DB_URL_MIGRATE`), while every integration
   test connects as `nebu_app`; `nebu_app` is never a member of
   `nebu_migrate`. Reproduced on a from-scratch fresh volume (not just a
   legacy one), confirming this is permanent for this deployment model, not
   volume-state debt. Fixed by querying `pg_constraint`/`pg_class`/
   `pg_attribute` (`pg_catalog`, not the ownership-scoped
   `information_schema` views) instead — verified directly via `psql` that
   this query correctly returns the constraint as `nebu_app`.

**Also fixed one real robustness gap found only under full-suite
concurrency**: `Nebu.Web.LogStore.WarRoom`'s `increment_and_maybe_end/1`
pattern-matched on exactly one `UPDATE ... RETURNING` row, crashing the
GenServer (`MatchError`) if the cached session's row had been deleted
out from under it (observed once, from an unrelated test's cleanup
racing the shared, process-wide `WarRoom` singleton). Hardened to treat a
zero-row result as `:gone` — the same "no active session" outcome an
already-ended session produces — rather than crashing.

**AC8's numeric caps (max_entries<=100/max_duration_s<=300 for the
`/sync` scope) are advisory-only** (warning text, not server-enforced),
matching the sibling admin-logs-retention-settings page's own precedent —
documented explicitly in `WarRoomPanel`'s moduledoc per the test-review's
MINOR-2 finding.

**AC3's negative case** (required param omitted): `WarRoomManager.start_session/1`
returns `{:error, :invalid_params, message}` — a documented, deliberately
chosen contract (test-review MINOR-1 — no ATDD test pins this exact
shape).

### Code-review cycle 1 fixes (2026-07-06)

**MAJOR-1 (security regression, fixed)** — `RequestLogger`'s `Logger.metadata(user_id:
conn.assigns[:current_user], ...)` logged the RAW `conn.assigns.current_user` value.
On Matrix routes that assign is already a bare string (safe, per design-decisions.md
#5), but `RequestLogger` is a plug in the TOP-LEVEL `Nebu.Web.Router`, which also
serves `/admin/*` — there, `Nebu.Admin.Auth.fetch_current_user/2` assigns a MAP
(`"sub"`, `"email"`, `"admin"`, `"matrix_user_id"`, session-timing fields), and
`Handler.safe_metadata/1` recurses into maps, so an admin's EMAIL would flow straight
into the persisted/broadcast `operational_logs.metadata["user_id"]` field — a new PII
leak introduced by this story. Fixed by adding `extract_user_id/1` (private helper in
`request_logger.ex`) which reduces `conn.assigns.current_user` to a bare identifier
string (or nil) BEFORE it ever reaches `Logger.metadata/1`: an already-a-string value
passes through unchanged (Matrix routes); a map yields `"matrix_user_id"` if present,
else `"sub"`, else nil (admin routes) — never `"email"`, never the whole map. Added 3
new regression tests in `request_logger_test.exs` (mirroring the existing SECURITY LAW
describe-block pattern in `handler_test.exs`): (a) a Matrix-route STRING
`current_user` still flows through unchanged to the broadcast entry's
`metadata["user_id"]`, (b) an admin-route MAP `current_user` containing an `"email"`
key NEVER lets that email appear anywhere in the broadcast entry, and is reduced to
`matrix_user_id`, and (c) the same MAP shape without `matrix_user_id` falls back to
`"sub"`, still never the email.

**MINOR-1 (fixed)** — AC7's broad-scope warning was shown for explicit `scope="all"`
but not for the default/empty `""` select value (the SAME null-scope case AC7 also
requires a warning for — the most dangerous case, since it is the form's out-of-the-box
state). Fixed `wireWarRoomPanel()` in `app.js` to treat `""` identically to `"all"` for
warning-display purposes. Added a new e2e scenario
(`@ac7-war-room-default-scope-warning`) to `war-room.feature` covering re-selecting the
blank placeholder option after having selected another scope.

**MINOR-2 (fixed)** — `parse_int_bounded/4` in `logs_live.ex` silently substituted the
hard-coded default (100/300) for any out-of-range `max_entries`/`max_duration_s` value
with no flash/error shown — an admin who bypassed the HTML `min`/`max` (edited value,
crafted phx-submit) got a silently different value than what they submitted, with no
explanation. Fixed by distinguishing "field absent/blank" (falls back to the default,
unchanged behavior for normal optional-field omission) from "field present but invalid
or out of bounds" (now returns `{:error, message}`, reusing the SAME
`build_war_room_start_params/2` → `handle_event("start_war_room", ...)` → `put_flash/3`
plumbing already used for the "reason is required" validation error, rather than a new
error-reporting path).

### Security review fix (2026-07-06)

**F-1 MEDIUM (fixed)** — `WarRoomManager.start_session/1` (the actual public-API trust
boundary, per ADR-020) previously validated only PARAMETER PRESENCE
(`validate_required/1`), not the numeric bounds on `max_entries`/`max_duration_s`. The
10..10_000 / 10..3_600 bounds (AC8/AC11) lived ONLY in `LogsLive`'s
`parse_int_bounded/5` — a UI-only defense that a direct caller of the manager (bypassing
the LiveView entirely: a future caller, a test, a crafted request) could sidestep to
create an unbounded session, defeating the story's entire flooding-safety purpose (e.g. a
huge `max_entries` with `scope="all"`). Fixed by adding `validate_bounds/1` (private,
runs after `validate_required/1` passes) directly inside `start_session/1` itself, using
the SAME bounds (`@max_entries_bounds {10, 10_000}`, `@max_duration_s_bounds {10,
3_600}`) as the LiveView form — defense-in-depth, the same pattern already used for AC2's
"exactly one active" (app-level check + DB-level partial unique index backstop). Returns
`{:error, :invalid_params, message}` on an out-of-bounds value, matching the existing
error contract for missing required params. The LiveView's own `parse_int_bounded/5`
check is unchanged (still the friendly early-UI-feedback layer). Added 5 tests directly
to `war_room_manager_test.exs` (bypassing the LiveView): rejects `max_entries` below 10,
rejects `max_entries` above 10_000 (the exact "unbounded flooding" scenario with
`scope="all"`), rejects `max_duration_s` below 10, rejects `max_duration_s` above 3_600,
and accepts the exact boundary values (10/10_000/10/3_600).

**Verification (security fix)** — `mix compile --warnings-as-errors`: clean (via the
`elixir:1.20-alpine` container per `make build-server`'s image — the local host
toolchain's `lazy_html` NIF is unavailable outside the container, an unrelated
environment gap, not a regression). `mix test --warnings-as-errors` (no DB, in
container): 1375 passed, 2 skipped, 0 failures. Targeted real-Postgres integration run
(`docker compose up -d --wait` + `docker run ... mix test --include integration
--warnings-as-errors test/nebu/admin/war_room_manager_test.exs
test/nebu/web/log_store/war_room_test.exs test/nebu/admin/logs_live_test.exs`): 53
tests, 0 failures — including all 5 new F-1 tests, confirmed individually via `--trace`.

**Verification (cycle 1)** — `mix compile --warnings-as-errors`: clean. `mix test
--warnings-as-errors` (no DB): 1375 passed, 2 skipped, 0 failures. Full real-Postgres
integration run (`docker compose up` + `mix test --include integration
--warnings-as-errors`, bypassing the `make` wrapper directly via `docker run` for
reliable, untruncated output): 1732 tests, 9 failures — all 9 match this project's
already-accepted baseline flake set (`RegressionSyncLoadTest` timing budget,
`MatrixSsoTest`, `SsoLoginTest` AC12.2 redirect-scheme cache-staleness,
`LogStore.RetentionTest` INFO/DEBUG max-count cap, `ConfigControllerTest` AC9
sso-schemes) PLUS 3 `AdminOidcLoginTest` failures showing the SAME
"count-contamination from concurrently-running suite traffic" symptom (a
`list_users/3` assertion failing against a result set polluted by thousands of
concurrently-created users from unrelated tests) — confirmed unrelated to this cycle's
3 fixes by re-running `admin_oidc_login_test.exs` + `matrix_sso_test.exs` in isolation
against a freshly-booted stack: all 3 `AdminOidcLoginTest` cases pass cleanly (only the
already-accepted `MatrixSsoTest` flake remains). A separate targeted integration run of
every war-room/request-logger-related test file (`war_room_manager_test.exs`,
`war_room_test.exs`, `handler_test.exs`, `logs_live_test.exs`,
`request_logger_test.exs`, `log_store_test.exs`, `release_test.exs`) against the live
stack: 110 tests, 0 failures.

## File List

- `server/priv/migrations/000019_war_room_sessions.up.sql` (new)
- `server/priv/migrations/000019_war_room_sessions.down.sql` (new)
- `server/lib/nebu/web/log_store/war_room.ex` (new)
- `server/lib/nebu/admin/war_room_manager.ex` (new; security review 2026-07-06 fix: added
  `@max_entries_bounds`/`@max_duration_s_bounds` + `validate_bounds/1`/`validate_in_range/4`,
  called from `start_session/1` after required-param validation — F-1 MEDIUM)
- `server/lib/nebu/admin/logs_live/war_room_panel.ex` (new)
- `server/lib/nebu/admin/logs_live.ex` (modified — mount/3 war_room_id param + AC11 handle_event/handle_info clauses + panel render)
- `server/lib/nebu/web/log_store.ex` (modified — `war_room_id` added to `@allowed_filter_keys`; `normalize_filter_value/2` UUID binary/string normalization)
- `server/lib/nebu/web/log_store/writer.ex` (modified — `war_room_id` added to `@columns`/`row_values/1`; moduledoc updated)
- `server/lib/nebu/web/log_store/handler.ex` (modified — `maybe_tag_war_room/1` called before the `should_persist?/1` gate)
- `server/lib/nebu/web/plugs/request_logger.ex` (modified — `user_id`/`device_id` added to `Logger.metadata/1` in `before_send`; cycle 1: `extract_user_id/1` added to reduce `conn.assigns.current_user` to a bare identifier before it reaches `Logger.metadata/1` — MAJOR-1 fix)
- `server/lib/nebu/application.ex` (modified — `Nebu.Web.LogStore.WarRoom` added to `repo_children/0`)
- `server/priv/static/assets/app.js` (modified — `wireWarRoomPanel()` for AC7/AC8 client-side warning toggling; cycle 1: `""` treated identically to `"all"` — MINOR-1 fix)
- `server/lib/nebu/admin/logs_live.ex` (cycle 1: `parse_int_bounded/4` → `/5`, now returns `{:ok, n} | {:error, message}` instead of silently substituting the default for an out-of-range value — MINOR-2 fix)
- `server/test/nebu/web/log_store/war_room_test.exs` (already staged; unmodified)
- `server/test/nebu/admin/war_room_manager_test.exs` (staged; modified — AC10 FK query fixed to use `pg_catalog` instead of `information_schema.constraint_column_usage`, see Completion Notes #3; security review fix: added 5 F-1 tests for direct-call bounds enforcement)
- `server/test/nebu/web/log_store/handler_test.exs` (staged; modified — AC4 scope-mismatch test wrapped in `with_log_level(:info, ...)`, see Completion Notes #2)
- `server/test/nebu/web/log_store_test.exs` (already staged; unmodified)
- `server/test/nebu/admin/logs_live_test.exs` (staged; modified — AC12 test's router dispatch/UUID/bootstrap-seed fixes, see Completion Notes #1)
- `server/test/nebu/release_test.exs` (modified — migration count assertion extended to include 000019)
- `server/test/nebu/web/plugs/request_logger_test.exs` (cycle 1: added 3 regression tests for MAJOR-1's `extract_user_id/1` fix)
- `e2e/features/admin/war-room.feature` (modified — `@pending-feature` tag removed; cycle 1: added `@ac7-war-room-default-scope-warning` scenario for MINOR-1)
- `e2e/step-definitions/admin/war-room.steps.ts` (modified — header comment updated to GREEN phase)

## Change Log

- 2026-07-04: Story created with full design context. Ready for dev agent handoff.
- 2026-07-06: Dev-story implementation complete. All 15 ATDD acceptance
  tests green against a real Postgres/docker-compose integration run (fresh
  volume, verified twice). 3 genuine test-quality bugs and 1 implementation
  robustness gap found and fixed during verification (see Completion
  Notes). Status → review.
- 2026-07-06: Code-review cycle 1 fixes: MAJOR-1 (RequestLogger PII leak via
  admin-route map `current_user` — added `extract_user_id/1`, 3 new
  regression tests), MINOR-1 (AC7 broad-scope warning now also shown for the
  default/empty scope selection — `app.js` + new e2e scenario), MINOR-2
  (`parse_int_bounded/4` now returns a validation error instead of silently
  substituting the default for an out-of-range value). Re-verified via
  `mix test --warnings-as-errors` (1375 passed) and a full real-Postgres
  integration run (1732 tests, 9 failures — all matching the accepted
  baseline flake set or confirmed-unrelated full-suite concurrency
  contamination; 0 war-room/request-logger-related failures). Status
  remains "review".
- 2026-07-06: Security review fix: F-1 MEDIUM (`WarRoomManager.start_session/1`
  did not enforce the `max_entries`/`max_duration_s` numeric bounds at the
  actual public-API trust boundary — only the LiveView form did). Added
  `validate_bounds/1` to the manager itself (defense-in-depth, LiveView
  check unchanged) + 5 new direct-call tests in `war_room_manager_test.exs`.
  Re-verified: `mix compile --warnings-as-errors` clean, `mix test
  --warnings-as-errors` 1375 passed/0 failures, targeted real-Postgres
  integration run of `war_room_manager_test.exs`/`war_room_test.exs`/
  `logs_live_test.exs` (53 tests, 0 failures). Status remains "review".

## Cross-Story Dependencies & Notes

### Depends On (must be ready before this story's dev):
- **operational-log-store** — provides the writer GenServer, operational_logs table schema, and central handler. This story integrates into that writer.
- **admin-logs-monitoring-view** — provides the `/admin/logs` page and log stream component. This story adds the War Room panel to that page and extends stream filtering if needed.

### Can be Implemented in Parallel With:
- **admin-logs-retention-settings** — no direct dependency between War Room and per-level DEBUG retention toggling (different concerns: bounded session vs. global policy).

### Coordination Notes:
- Confirm with operational-log-store story owner whether `war_room_id` column on operational_logs is already planned. If not, this story's migration adds it as a fallback.
- Coordinate with admin-logs-monitoring-view on the extension point for filtering by `war_room_id`. If the stream component is rigid, this story may need to contribute a filter-layer addition to that component.
