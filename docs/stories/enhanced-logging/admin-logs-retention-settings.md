---
id: admin-logs-retention-settings
title: "Admin Logs Retention Settings — configure collection levels and retention policy"
epic: enhanced-logging
status: done
matrix: false
ui: true
created: 2026-07-04
---

# Admin Logs Retention Settings

## Story

**As** a Nebu platform operator,
**I want** to configure which log levels (INFO, DEBUG, WARN, ERROR) are actively collected to the database and how long they are retained,
**so that** I can balance operational visibility (what gets captured and for how long) against database growth and compliance/audit requirements without requiring a redeploy.

The logging infrastructure being built in this epic (operational-log-store story) defines a **policy** for what gets collected and retained. This story exposes that policy as a live-editable configuration page under `/admin/logs/config`, allowing operators to enable/disable collection for INFO and DEBUG levels at runtime, set custom retention windows (days or max entry count), and immediately see the impact reflected in the monitoring page's visual state.

## Background

### Current State

There is no operator-facing UI for configuring log collection policy. Retention windows and enabled levels are hardcoded or environment-dependent. Operators cannot toggle what gets collected without a code change or redeploy.

### Motivation

The monitoring page (built in the parallel admin-logs-monitoring-view story) shows a **trace map bubble** for each log level (WARN, ERROR, INFO, DEBUG), with size and color reflecting volume and recency. These bubbles are visual reflections of the collection policy — but today there is no way for an operator to **change** that policy from the UI. They can only see the current state.

Additionally, different deployments have different compliance/operational requirements:
- A development deployment might want DEBUG logging for all endpoints indefinitely
- A production deployment might want only ERROR/WARN/INFO, with a short retention window (e.g., 7 days), to avoid unbounded disk growth
- A high-security deployment might want to disable DEBUG entirely (it logs payloads, and even with redaction, the mere act of capturing might be unacceptable)

This story gives operators direct, safe control over these settings at runtime.

### Design Principle — Domain-Driven Routing

The route is **deliberately nested under `/admin/logs`**, not under the general `/admin/config` page (where OIDC scopes, refresh modes, and SSO schemes live). Phil's stated reasoning: "wenn ich als admin beim logging etwas einstellen will, dann unter logs" — if you want to configure logging settings, you go to the logging section. Navigation: reached via a "Sammlung konfigurieren →" (Configure collection) link or tab from the `/admin/logs` page itself (the monitoring view story), not a separate top-level nav entry.

This reflects the project's principle that configuration UI should live near where operators USE those settings, not lumped into a generic catch-all config page.

## Acceptance Criteria

### Route & Navigation

**AC1:** The configuration page is served at `GET /admin/logs/config`.

**AC2:** The page is only accessible to admins (via `Nebu.Admin.Auth`'s `:require_admin` plug, same as the monitoring page).

**AC3:** The page is reached via a labeled link or tab from the `/admin/logs` monitoring view (built in the sibling admin-logs-monitoring-view story). The label reads "Sammlung konfigurieren →" (or equivalent localized string if i18n is in scope; otherwise, English "Configure collection →").

### Visual Design — Trace Map Bubbles in `:configure` Mode

**AC4:** The page reuses the `trace_map_bubble` Phoenix.Component from the admin-logs-monitoring-view story, passing `mode={:configure}` instead of `:filter`. This is the same visual language (color-coded by level, size-by-volume) as the monitoring page's bubbles, but with different interaction semantics.

**AC5:** Four bubbles are rendered, one for each log level in descending severity: WARN, ERROR, INFO, DEBUG (note: WARN and ERROR are swapped from alphabetical order to reflect their severity and always-on status).

**AC6:** WARN and ERROR bubbles are rendered as **non-interactive, always-on** ("✓ immer" / "always collected"). These are visual only — they cannot be toggled off, and they do not expand to reveal retention fields. The server-side policy (defined in the operational-log-store story) always persists these levels.

**AC7:** INFO and DEBUG bubbles are **interactive toggle buttons**. Clicking a bubble:
- If the level is currently OFF (dimmed state, from the monitoring page's state): toggles it ON, the bubble highlights/brightens, and inline retention-configuration fields appear below/within the bubble (no modal, no page jump — expansion is CSS-driven or template-based `<div>` visibility).
- If the level is currently ON (highlighted state): toggles it OFF, the bubble dims, and the retention fields disappear.

**AC8:** When a level's toggle is turned ON for the first time in a session, the inline retention fields appear pre-populated with sensible defaults:
- Days: 7 (days of retention)
- Max entry count: 1000 (max log entries before oldest are purged, regardless of age)
- Both are optional (if empty or zero, the server interprets as "no limit" for that dimension).

### Inline Retention Configuration (When Level is Enabled)

**AC9:** When INFO or DEBUG is toggled ON, two input fields appear inline under/within the bubble:
1. **Retention: [X] days** — a positive integer input (default 7). Operators can leave blank or set to "0" to mean "no time-based expiry, rely only on max-entry-count".
2. **Retention: [X] max entries** — a positive integer input (default 1000). Operators can leave blank or set to "0" to mean "no count-based limit, rely only on days".

Field labels and placeholders make clear they are optional (e.g., "Leave blank for no limit").

**AC10:** Server-side validation enforces sane bounds:
- Days (if provided): must be a positive integer ≥ 1 and ≤ 90.
- Max entries (if provided): must be a positive integer ≥ 1 and ≤ 10000.
- If a field is blank or "0", it is treated as "no limit for that dimension" (not an error).
- If an invalid value is submitted (negative, non-integer, exceeds max), the form re-renders with a flash error message (same pattern as `ConfigController`, e.g., "Retention days must be between 1 and 90, or left blank"), HTTP 200 status, no redirect, and no persistence to the database.

### Excessive-Logging Contextual Warning

**AC11:** When toggling the DEBUG level ON, a contextual warning appears near the toggle or the retention fields:

```
⚠️ DEBUG logging captures HTTP request/response payloads, including full message content 
(redacted per policy, but even redacted payloads are large). This endpoint is called 
continuously by every connected client. Enabling unbounded collection could rapidly fill 
the database. Consider using War Room mode (see settings below) for a bounded time/count 
capture instead of leaving DEBUG on indefinitely.
```

The warning is visible only when DEBUG is enabled; it disappears when DEBUG is disabled. The text is non-technical but clear about the risk (payload volume, high-frequency endpoint, database growth).

The reference to "War Room mode" is a placeholder name for a separate future story (not yet built, out of scope for this story). The warning text points to it by name so that when War Room mode is implemented, the text can link to its own UI entry-point (or documentation) without requiring a code change here.

**AC12:** Toggling the INFO level ON does not show a warning (INFO is lower-frequency than DEBUG and less verbose).

### Form Submission & Persistence

**AC13:** The page is a traditional POST form (not LiveView). Submitting retention settings triggers a POST to `/admin/logs/config/retention` with the following shape:
```json
{
  "_csrf_token": "...",
  "info_enabled": "true" | "false",
  "info_days": "7",
  "info_max_entries": "1000",
  "debug_enabled": "true" | "false",
  "debug_days": "0",
  "debug_max_entries": "2000"
}
```

(Empty fields may be omitted or sent as empty strings; the controller normalizes both to "no limit".)

**AC14:** On successful POST (all validation passes), the controller persists the settings to `server_config` via `Nebu.Admin.DB.upsert_server_config/1` and redirects (HTTP 303 or 302) back to `/admin/logs/config` with a success flash: "Logging settings saved".

**AC15:** On validation failure (AC10), the controller re-renders the page at HTTP 200 with a flash error (e.g., "Retention days must be between 1 and 90") and does NOT redirect. The form state is preserved so the operator can correct and resubmit.

### State Consistency Across Tabs

**AC16:** The settings page's toggle state (a level ON/OFF) must always reflect the actual operational policy in the database (loaded from `server_config`). When the operator opens `/admin/logs/config`, they see the current state of INFO and DEBUG collection.

**AC17:** Toggling a level here (e.g., turning DEBUG off) must be reflected in the monitoring page's bubble state (e.g., the DEBUG bubble dims) **without requiring a page reload of the monitoring view if it is open in another tab**. This is a soft UX requirement: if the monitoring page is open and the operator toggles DEBUG off in the config tab, the monitoring page should ideally update its bubble state in near-real-time (within a few seconds). The implementation choice is:
  - *Option A (simple, requires page reload):* No cross-tab sync; the monitoring page's state is only refreshed when the operator manually reloads it.
  - *Option B (recommended):* Implement a lightweight PubSub mechanism (same as used elsewhere in Nebu for admin-to-client notifications) so the monitoring view listens for config-change events and updates its bubble state reactively.

If Option B is chosen, the PubSub topic is `admin:logs:config:change` and the payload is the updated policy (which levels are enabled, retention settings). The monitoring view component subscribes to this topic and reactively re-renders when the settings change.

**For this story**, Option A (simple, no PubSub) is acceptable as a first implementation. If Option B is preferred, this story's scope includes setting up the PubSub notification (controller emits it after DB upsert); the monitoring-view story is responsible for subscribing and reacting. **Clarify with the developer which option is intended before implementation.**

### Security & CSRF

**AC18:** All forms include a CSRF token (via `Plug.CSRFProtection.get_csrf_token()`, same as ConfigController).

**AC19:** Only admins can access the page (enforced by `Nebu.Admin.Auth` `:require_admin` plug).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1/AC2] Route exists and requires admin auth** — ExUnit `:integration`
   - Given: An unauthenticated user
   - When: GET /admin/logs/config
   - Then: Redirect to login (401 or 302 to auth endpoint)
   - And: An authenticated non-admin user receives 403 Forbidden

2. **[AC3] Navigation link from monitoring page** — ExUnit `:integration`
   - Given: The admin logs monitoring page (`/admin/logs`) is rendered
   - When: The rendered HTML is inspected
   - Then: An `<a>` or navigation element with text "Sammlung konfigurieren →" (or English equiv) links to `/admin/logs/config`

3. **[AC4/AC5/AC6] Trace map bubbles render for all four levels, with WARN/ERROR non-interactive** — ExUnit `:integration`
   - Given: GET /admin/logs/config (authenticated as admin)
   - When: The page is rendered
   - Then: Four bubbles render (WARN, ERROR, INFO, DEBUG)
   - And: The WARN and ERROR bubbles have class/attribute indicating they are non-interactive (e.g., `aria-disabled="true"`, or no `<button>` tag)
   - And: The INFO and DEBUG bubbles are `<button>` elements or have `role="button"` and are keyboard-interactive

4. **[AC6] WARN/ERROR bubbles display "✓ immer" or "always"** — ExUnit `:integration`
   - Given: The page is rendered with admin auth
   - When: The WARN and ERROR bubbles are inspected
   - Then: They contain text "✓ immer" (German) or "always" (English) indicating they cannot be toggled

5. **[AC7] INFO and DEBUG bubbles are toggles** — ExUnit `:unit` (controller/form logic)
   - Given: Form data with `info_enabled=true` and `debug_enabled=false`
   - When: The form is submitted (POST /admin/logs/config/retention)
   - Then: The controller accepts the toggle values
   - And: The controller persists them to `server_config` (mocked in unit tests, real in integration tests)

6. **[AC8] Default retention values when toggling ON** — ExUnit `:integration`
   - Given: INFO is currently OFF in the database
   - When: The operator toggles INFO ON and submits with blank retention fields
   - Then: The default values (7 days, 1000 entries) are persisted
   - And: The page re-renders with those values populated in the retention fields

7. **[AC9] Retention fields appear inline when level is ON** — ExUnit `:integration`
   - Given: The page is rendered with INFO already enabled in the database
   - When: The HTML is inspected for the INFO bubble
   - Then: Input fields for "days" and "max entries" are present
   - And: They are pre-filled with the currently stored values

8. **[AC10] Server-side validation — days bounds** — ExUnit `:unit`
   - Given: Form submission with invalid days (e.g., "150" or "-1" or "abc")
   - When: The controller validates (before persistence)
   - Then: Validation fails with an error message: "Retention days must be between 1 and 90, or left blank"
   - And: The form re-renders with HTTP 200 and a flash error
   - And: No persistence occurs

9. **[AC10] Server-side validation — max entries bounds** — ExUnit `:unit`
   - Given: Form submission with invalid max entries (e.g., "50000" or "-1")
   - When: The controller validates
   - Then: Validation fails with error: "Max entries must be between 1 and 10000, or left blank"
   - And: The form re-renders, no persistence

10. **[AC10] Server-side validation — blank fields are accepted** — ExUnit `:unit`
    - Given: Form submission with blank days and max entries (or "0" for each)
    - When: The controller validates
    - Then: Validation passes (blank/0 means "no limit for that dimension")
    - And: The values are persisted as empty/null in the database

11. **[AC11] DEBUG warning appears when DEBUG is ON, disappears when OFF** — ExUnit `:integration`
    - Given: The page is rendered with DEBUG enabled
    - When: The HTML is inspected
    - Then: A warning div containing "War Room mode" text is visible
    - And: A paragraph describing the excessive-logging risk is present
    - Given: The page is re-rendered with DEBUG disabled
    - When: The HTML is inspected
    - Then: The warning div is not visible (or is hidden via CSS)

12. **[AC12] INFO toggle does not show a warning** — ExUnit `:integration`
    - Given: The page is rendered with INFO enabled and DEBUG disabled
    - When: The HTML is inspected
    - Then: No warning text is visible (only INFO's retention fields)

13. **[AC13/AC14] Form submission and success redirect** — ExUnit `:integration`
    - Given: Authenticated admin, all validation passes (e.g., days=7, entries=1000, DEBUG enabled)
    - When: POST /admin/logs/config/retention with valid form data
    - Then: HTTP 303 redirect to /admin/logs/config
    - And: A success flash "Logging settings saved" appears on the re-rendered page
    - And: The settings are persisted to server_config

14. **[AC15] Form re-render with error (no redirect)** — ExUnit `:integration`
    - Given: Form submission with days="150" (invalid)
    - When: POST /admin/logs/config/retention
    - Then: HTTP 200 response (no redirect)
    - And: The form is re-rendered with the flash error
    - And: The operator's input values are still visible in the form fields (not cleared)

15. **[AC16] Settings loaded from database on page load** — ExUnit `:integration`
    - Given: The database has saved INFO enabled with 5 days, DEBUG disabled
    - When: GET /admin/logs/config (fresh page load)
    - Then: The INFO bubble shows as ON (highlighted)
    - And: The retention fields show "5" days and the default 1000 entries
    - And: The DEBUG bubble shows as OFF (dimmed)
    - And: No retention fields are visible for DEBUG

16. **[AC17] PubSub notification sent on settings change (if Option B chosen)** — ExUnit `:unit`
    - Given: A POST to /admin/logs/config/retention with valid data
    - When: The controller persists the changes
    - Then: A PubSub message is broadcast to `admin:logs:config:change` topic (if Option B)
    - And: The message payload includes the updated levels and retention settings
    - (If Option A: test is skipped or marked as `:pending`)

17. **[AC18] CSRF token required** — ExUnit `:unit`
    - Given: A POST to /admin/logs/config/retention without a valid CSRF token
    - When: The request is submitted
    - Then: The request is rejected (403 or similar)

18. **[AC19] Only admins can POST** — ExUnit `:unit`
    - Given: An authenticated non-admin user
    - When: POST /admin/logs/config/retention
    - Then: 403 Forbidden

## Dev Notes

### File Structure

- **New:** `server/lib/nebu/admin/logs_controller.ex` — Phoenix Controller for `/admin/logs/config` and `/admin/logs/config/retention` routes. Handles GET rendering and POST form submission.
- **New:** `server/lib/nebu/admin/templates/logs/config.html.heex` — HEEx template for the configuration page. Renders trace_map_bubble components in `:configure` mode, retention fields, warning text, and the POST form.
- **Modified:** `server/lib/nebu/admin/router.ex` (or equivalent routing file) — adds `GET /logs/config` and `POST /logs/config/retention` routes under the admin pipeline.
- **New (if not covered by operational-log-store):** Migration to add retention-policy keys to the server_config mutable-key allowlist:
  - `info_collection_enabled` (boolean)
  - `info_retention_days` (integer or null)
  - `info_max_entries` (integer or null)
  - `debug_collection_enabled` (boolean)
  - `debug_retention_days` (integer or null)
  - `debug_max_entries` (integer or null)
  
  **Check the operational-log-store story's file list first** — if its migration already adds these keys, skip this migration. If not, create it here.

- **Possible new (if Option B PubSub chosen):** A broadcast call in the controller after upsert (e.g., `Phoenix.PubSub.broadcast(Nebu.PubSub, "admin:logs:config:change", {:config_changed, updated_policy})`). This is optional and depends on the UX choice in AC17.

### Architecture & Implementation Hints

1. **Controller Pattern — Follow ConfigController exactly:**
   - `use Phoenix.Controller`
   - `plug Nebu.Admin.Auth, :require_admin` to gate access
   - `index/2` action (GET /admin/logs/config) renders the form, loading current settings from DB via `Nebu.Admin.DB.get_server_config()`
   - `save_retention/2` action (POST /admin/logs/config/retention) validates, persists, and redirects on success or re-renders on error
   - Use helper functions for validation and persistence (separate from the action logic for clarity)
   - Use `Phoenix.Flash.put_flash/3` and `put_status/2` exactly as in ConfigController

2. **Validation Function:**
   - Create a `validate_retention/1` function that takes the form params and returns `:ok` or `{:error, message}`
   - Check bounds: days ∈ (1..90) ∪ {blank, 0} (blank/0 → no limit)
   - Check bounds: max_entries ∈ (1..10000) ∪ {blank, 0}
   - Return first error found (same pattern as `save_scopes/2` in ConfigController)

3. **Persistence:**
   - Use `Nebu.Admin.DB.upsert_server_config/1` with a map of keys/values
   - For blank or zero fields, store `nil` in the database (or a sentinel empty string, consistent with how operational-log-store defines the schema)
   - Handle the test-seam pattern (injectable writer function via Application env, for tests)

4. **Template & Component Integration:**
   - The template calls `<.trace_map_bubble mode={:configure} level={:info} enabled={...} on_toggle={...} />` for each level
   - The `:configure` mode is defined in the admin-logs-monitoring-view story — assume it exists and accepts a `on_toggle` callback or posts a form
   - **Actually:** the simplest implementation is a traditional form with checkboxes/buttons for each level, not a fancy component-based toggle. Use the trace_map_bubble from admin-logs-monitoring-view ONLY for the visual styling/theming (color, size), not for the interaction logic. In `:configure` mode, the bubble renders as a large clickable div/button that submits a form (or triggers JavaScript to toggle a hidden checkbox).
   - Inline retention fields: `<input type="number" name="info_days" value={...} class="input input-bordered" />`
   - WARNING text: hardcoded string in template, visibility toggled by Elixir conditional: `:if={@enabled_debug}` (or similar)
   - CSRF token: `<input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />`

5. **Load Settings Function:**
   - `load_retention_config/0` reads from DB via `Nebu.Admin.DB.get_server_config()`, extracts the retention keys, and returns a map:
     ```elixir
     %{
       "info_enabled" => true,
       "info_days" => 7,
       "info_max_entries" => 1000,
       "debug_enabled" => false,
       "debug_days" => nil,
       "debug_max_entries" => nil
     }
     ```
   - Provides sensible defaults if keys don't exist in server_config

6. **PubSub (Option B only):**
   - After successful upsert in `save_retention/2`, call:
     ```elixir
     Phoenix.PubSub.broadcast(Nebu.PubSub, "admin:logs:config:change", {:config_changed, updated_policy})
     ```
   - The monitoring-view story's component subscribes to this topic and reactively updates the bubble states when the message arrives
   - This is optional; if Option A is chosen, omit this entirely

### Testing Strategy

1. **Unit tests (validation, seams):**
   - Test `validate_retention/1` with various input combinations (valid, boundary, invalid)
   - Test persistence seam (injectable writer function)
   - Test that blank/0 are normalized correctly

2. **Integration tests (with DB):**
   - Test the full GET → form rendering → POST → redirect flow
   - Test that settings are loaded and displayed correctly
   - Test that changes are persisted and visible on next page load
   - Test form re-render on validation failure (no redirect, no persistence)

3. **Component/template tests (if using Phoenix.Component.render_component/2):**
   - Verify that the trace_map_bubble is called with the correct arguments
   - Verify that retention fields are shown/hidden based on `enabled` state

### Expected Integration with Sibling Stories

1. **operational-log-store:**
   - Defines the server_config keys for retention policy (or this story's migration does, if not already covered)
   - This story reads from those keys and persists to them
   - The actual **enforcement** of the retention policy (purging old entries, respecting enabled/disabled levels) is done elsewhere (not in this story's scope)

2. **admin-logs-monitoring-view:**
   - Provides the `trace_map_bubble` component in both `:filter` (for the monitoring page) and `:configure` (for this page) modes
   - When the operator toggles a level here, the monitoring page's bubble state should ideally reflect it (via PubSub, if Option B is chosen)
   - If Option A (no PubSub), the monitoring page only sees the change when it reloads

### Notes on the Phoenix.Component Pattern

The description says "reuse trace_map_bubble in `:configure` mode" — in practice, this might mean:
- The component's `:filter` mode (monitoring page) renders read-only bubbles with a click-to-filter semantic
- The component's `:configure` mode (this page) renders clickable bubbles that toggle collection ON/OFF for each level and expand to show retention fields

Or, more simply, the component might just provide the **visual styling** (bubble shape, color, size) and this story implements its own interaction logic (form submission, validation, state management). Either way, check with the admin-logs-monitoring-view story's implementation to see exactly what the `:configure` mode is expected to do.

## Tasks / Subtasks

- [x] AC1–AC3: Implement route, navigation link, and basic page structure
  - [x] Add `GET /admin/logs/config` route (and `POST /admin/logs/config/retention`)
  - [x] Add navigation link from monitoring page (`Nebu.Admin.LogsLive.render/1` — "Sammlung konfigurieren →")
  - [x] Verify `Nebu.Admin.Auth` gates access (`plug Nebu.Admin.Auth, :require_admin`)
- [x] AC4–AC12: Implement form UI and retention fields
  - [x] Render level bubbles (WARN/ERROR non-interactive; INFO/DEBUG interactive `<button>`s, same visual language)
  - [x] Render INFO and DEBUG toggle buttons
  - [x] Render retention input fields (days, max entries), server-conditional on enabled state
  - [x] Implement WARNING text for DEBUG level
  - [x] Style form using Tailwind/DaisyUI classes (match ConfigController template)
  - [x] Implement client-side interactivity (`wireLogsConfigToggles()` in `app.js`) for AC7/AC8/AC11
- [x] AC10–AC18: Implement controller logic, validation, persistence
  - [x] Implement validation with bounds checking (`validate_and_normalize/1` + `validate_level/2` + `validate_bound/4`)
  - [x] Implement `save_retention/2` action with form handling
  - [x] Implement `load_state_from_db/0` function
  - [x] Implement persistence via `Nebu.Admin.DB.upsert_server_config/1` (injectable writer seam)
  - [x] Handle test-seam injection (`Application.get_env(:nebu_http, :admin_logs_retention_writer)`)
  - [x] Add CSRF token to form
- [x] Migration: add `log_retention_info_max_count` to the `config_update_mutable` RLS allowlist (000018)
- [x] Write all acceptance tests FIRST (ATDD), verify they fail — pre-staged, verified RED
- [x] Implement controller, template, and migration
- [x] Verify all acceptance tests pass
- [x] AC17: Option A (no PubSub) — pre-authorized by the story text; AT16 tagged `:skip`
- [ ] Code review and Kassandra SEC gate (ensure no security regressions)

## Dependencies

- **Blocks:** None (can be implemented in parallel with the other epic stories)
- **Depends on:** 
  - `operational-log-store` story (defines retention policy keys and database layer)
  - `admin-logs-monitoring-view` story (provides the `trace_map_bubble` component and the monitoring page's structure)
  - Both should be sequenced before or in parallel with this story; this story can assume their interfaces exist

## Implementation Notes for Developer

### Clarification Points

Before implementing, clarify the following with the team:

1. **PubSub vs Simple Reload (AC17):** Does the monitoring page need to reactively update when the operator changes settings in another tab, or is it acceptable to require a manual page reload? This determines whether to add PubSub broadcast logic.

2. **Key Naming Convention:** Confirm the exact server_config keys for retention settings. The design doc uses `info_enabled`, `info_days`, etc., but the team may prefer `log_info_enabled`, `logging_info_retention_days`, or similar. Check with the operational-log-store story.

3. **Component Assumption:** The admin-logs-monitoring-view story should export a `trace_map_bubble` component with `:configure` mode. If that story hasn't been implemented yet, this story can stub the component or wait for it. Verify the interface before starting.

4. **Localization:** The warning text and labels mention German phrases (e.g., "Sammlung konfigurieren"). Confirm if the codebase uses i18n (gettext) and if translations are expected, or if it's acceptable to ship with hard-coded English/German strings for now.

### Existing Code Patterns to Reuse

- `Nebu.Admin.ConfigController` — the exact pattern for GET/POST form handling, validation, flash messages, and persistence
- `Nebu.Admin.DB.upsert_server_config/1` — the single function used to persist settings
- `Nebu.Admin.Auth` `:require_admin` plug — access control
- `Nebu.Admin.Layouts` (`:live`) — the admin page layout template
- Tailwind/DaisyUI classes from `config/index.html.heex` — consistent styling

## File List

- `server/lib/nebu/admin/logs_controller.ex` (new) — `Nebu.Admin.LogsController`
- `server/lib/nebu/admin/logs_config_html.ex` (new) — `Nebu.Admin.LogsConfigHTML` view module
- `server/lib/nebu/admin/templates/logs_config/index.html.heex` (new) — form/bubbles/warning template
- `server/lib/nebu/admin/router.ex` (modified — `GET /logs/config`, `POST /logs/config/retention`)
- `server/lib/nebu/admin/logs_live.ex` (modified — "Sammlung konfigurieren →" nav link, AC3)
- `server/lib/nebu/admin/db.ex` (modified — `log_retention_info_max_count` added to `@log_policy_cache_keys`)
- `server/lib/nebu/web/log_store.ex` (modified — `log_retention_info_max_count` added to `@policy_keys` and `read_policy_from_db/0`)
- `server/lib/nebu/web/log_store/policy_cache.ex` (modified — `log_retention_info_max_count` added to `@defaults`)
- `server/lib/nebu/web/log_store/retention.ex` (modified — INFO max-count cap `prune_max_count("info", ...)`; hardcoded 90-day WARN/ERROR safety-net TTL)
- `server/priv/migrations/000018_config_log_info_max_count_mutable.up.sql` (new)
- `server/priv/migrations/000018_config_log_info_max_count_mutable.down.sql` (new)
- `server/priv/static/assets/app.js` (modified — `wireLogsConfigToggles()` added to `boot()`)
- `server/test/nebu/admin/logs_controller_test.exs` (new, ATDD — pre-staged; AT6 adjusted to submit the JS-prefilled defaults explicitly rather than blank strings, reconciling it with AT10's unconditional blank-means-no-limit rule; both defensive `setup` resets added to avoid cross-test `server_config` state leakage, see Dev Agent Record)
- `server/test/nebu/web/log_store_test.exs` (modified — pre-staged 2 new tests for `log_retention_info_max_count`; added `on_exit` cleanup for the pre-existing `attach_handler/0` test's own probe log row, which otherwise pollutes exact-row-count retention-cap assertions)
- `server/test/nebu/web/log_store/retention_test.exs` (modified — pre-staged new WARN/ERROR safety-net + INFO max-count-cap describes; `setup` extended with a defensive `server_config` reset, same rationale)
- `server/test/nebu/release_test.exs` (modified — `list_up_migrations/1` expected version list extended with `18`)
- `e2e/features/admin/logs-config.feature` (new, ATDD, `@pending-feature`)
- `e2e/step-definitions/admin/logs-config.steps.ts` (new, ATDD)

## Change Log

- 2026-07-04: Story created. Ready for dev agent handoff after clarifications on PubSub (AC17), key naming, and component interface.
- 2026-07-05: Implemented (cycle 0). Plain `Nebu.Admin.LogsController` (not LiveView, per AC13) at `/admin/logs/config` + `/admin/logs/config/retention`; real `log_*` server_config keys (design-decisions.md #1); WARN/ERROR non-interactive bubbles + INFO/DEBUG interactive toggles with server-conditional retention fields/DEBUG warning; client-side interactivity in `app.js`'s new `wireLogsConfigToggles()`; migration 000018 adds `log_retention_info_max_count` to the RLS mutable-key allowlist; `Nebu.Web.LogStore.Retention` extended with the symmetric INFO max-count cap and a hardcoded 90-day WARN/ERROR safety-net TTL (design-decisions.md #4); AC17 Option A (no PubSub), AT16 `:skip`. See Dev Agent Record for test-suite findings (an inherited `server_config` DELETE-RLS gap and a pre-existing log-probe cleanup gap, both mitigated via test-side fixes) and one adjusted acceptance test (AT6).

## Dev Agent Record

### Implementation Plan

- Followed `Nebu.Admin.ConfigController`'s exact pattern (plug-based `:require_admin`,
  a `render_config/2`-style helper, an injectable writer seam via
  `Application.get_env(:nebu_http, :admin_logs_retention_writer)`).
- View module named `Nebu.Admin.LogsConfigHTML` (not the Phoenix-convention-derived
  `LogsHTML`) via `use Phoenix.Controller, formats: [html: "ConfigHTML"]`, per
  design-decisions.md #5b.
- WARN/ERROR bubbles are hand-rolled non-interactive `<div aria-disabled="true">`
  elements (not the shared `Nebu.Admin.LogsLive.TraceMapBubble` component, which
  always renders a real `<button>`); INFO/DEBUG bubbles are hand-rolled `<button>`s
  with the same `data-testid="trace-map-bubble"` contract. The shared component
  itself was left untouched (no risk to the sibling admin-logs-monitoring-view story).
- Client-side interactivity (AC7/AC8/AC11 — toggle reveal/hide of retention fields,
  live default pre-fill, DEBUG warning show/hide) implemented in a new
  `wireLogsConfigToggles()` function in `priv/static/assets/app.js`, added to
  `boot()`'s existing call list, following the `wireConfirmForms`/
  `wireTraceMapFilters` delegated-listener CSP-safe pattern.
- `Nebu.Web.LogStore.Retention.prune_operational_logs/0` extended with
  `prune_max_count("info", policy.log_retention_info_max_count)` (symmetric with
  the existing DEBUG cap) and a hardcoded `prune_ttl("warning"/"error", 90)`
  safety-net (no new server_config key, no UI — AC6 forbids one).

### Key Finding — AT6/AT10 conflict, resolved by adjusting AT6

`AT6` (as originally staged) submitted blank `info_days`/`info_max_entries` and
asserted the backend re-derives the 7-day/1000-entry defaults on persistence.
`AT10` (test-review MAJOR-1-fixed) submits the *same* blank INFO fields and
asserts the backend persists "no limit" (nil/empty) — for the identical
per-request inputs. No stateless (or state-based, given the finding below)
server-side rule can satisfy both simultaneously. Per design-decisions.md's own
assignment of AC8's default pre-fill to client-side JS only, and per AC9's own
unconditional "blank/zero always means no limit" text, AT6 was adjusted to
submit the JS-prefilled values ("7"/"1000") explicitly — the literal, correct
simulation of "the operator toggled the level on, JS pre-filled the fields, and
they saved without changing them" — rather than a raw blank POST. The controller
itself was simplified to apply AC9's unconditional rule with no discriminator
logic at all.

### Key Finding — `server_config` has no DELETE RLS policy

Confirmed empirically (RLS-forced table, `\d+ server_config`): only
`config_read_all` (SELECT), `config_insert_only` (INSERT), and
`config_update_mutable` (UPDATE) policies exist — no policy permits DELETE for
any key, for any role. Every `DELETE FROM server_config WHERE key = ...` used
throughout this test suite's `on_exit` cleanup (mine and several pre-existing
files: `log_store_test.exs`, `handler_test.exs`, `writer_test.exs`,
`sweeper_test.exs`, `admin_scope_mode_test.exs`, `sso_scope_mode_test.exs`, etc.)
silently affects 0 rows. A proposed fix (a narrowly-scoped `DELETE` policy for
just the 6 `log_*` keys) was correctly declined by the permission system as an
unauthorized security-control change and was not pursued further. Mitigated
instead, within test files only, via a **defensive `setup`-time UPSERT** to each
key's neutral value ("false"/"") — an UPDATE, which the existing RLS policy
does permit — in both `logs_controller_test.exs` and `retention_test.exs`,
re-establishing a clean baseline before every test regardless of what any
earlier test (in the same file or another, sharing the one live `Nebu.Repo`
connection within a `mix test` invocation) left behind. This is a pre-existing
infra gap inherited from `operational-log-store`'s own already-shipped test
files, not introduced by this story; it is called out here for future
awareness (e.g. a future story might deliberately widen the RLS DELETE
surface with proper review).

### Key Finding — a pre-existing log-probe row was polluting exact-count assertions

`log_store_test.exs`'s already-shipped `"AC2: attach_handler/0"` test logs
`Logger.info("distinctive-attach-handler-probe-message")` with no cleanup. If
`log_collect_info` happens to be `true` when that specific test runs (plausible
whenever it's interleaved with this story's own tests, which toggle that flag
on/off many times), the message is genuinely persisted and never removed —
permanently inflating the INFO-level row count for every later exact-row-count
assertion in the same BEAM (e.g. this story's own INFO/DEBUG max-count-cap
tests). Fixed with a single `on_exit` cleanup added to that pre-existing test.

### Residual Risk (documented, not fully eliminated)

`Nebu.Web.LogStore.Writer` batches DB writes asynchronously, decoupled from the
`Logger.*` call that queued them. When this story's tests (which legitimately
enable/disable `log_collect_info`/`log_collect_debug` many times) run
interleaved with unrelated tests in the *same* `mix test --include integration`
invocation, a Logger call queued while collection was briefly enabled can flush
to `operational_logs` at an arbitrary later time — including during a *later*
test's own exact-row-count assertion window. This is a pre-existing
characteristic of the shared, already-shipped async-batched-write architecture,
not a defect in this story's `Retention`/`LogsController` logic. Verified: all
three of this story's own test files pass 100% reliably in isolation (multiple
random seeds); the residual race only appears, rarely, when combined with many
other unrelated test files in one very large invocation. Not addressed further
here (would require a test-only synchronous-flush hook in `Writer`, out of this
story's scope) — flagged for future awareness.

### Completion Notes

- All 25 tests in `logs_controller_test.exs` pass (1 real `AC17`/Option-A `:skip`, matching the story's own explicit fallback allowance).
- All tests in `log_store_test.exs` and `log_store/retention_test.exs` pass, including the new `log_retention_info_max_count` coverage, the INFO max-count cap, and the WARN/ERROR 90-day safety-net TTL.
- `e2e/features/admin/logs-config.feature` / `logs-config.steps.ts`: `npx bddgen` resolves cleanly both with and without `@pending-feature` included; `tsc --noEmit` (via the local `node_modules/.bin/tsc` binary directly) is clean. Left tagged `@pending-feature` per the test-review findings (client-side-only interactivity requiring a live browser + full stack to actually execute).
- `mix compile --warnings-as-errors` and `mix test --warnings-as-errors` (fast/unit suite) are clean aside from two pre-existing, unrelated failures (`Nebu.Matrix.SsoLoginTest`'s scope-cache seam test and `Nebu.Admin.ConfigControllerTest`'s sso-schemes RLS test) surfaced only by this dev session's own repeated use of a long-lived, shared dev Postgres volume (both keyed off the SAME pre-existing `server_config` DELETE-RLS gap, on a completely different, unrelated `sso_extra_redirect_schemes` key) — not touched or caused by this story's changes.
