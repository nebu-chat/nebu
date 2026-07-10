---
id: admin-sidebar-nesting
title: "Admin Sidebar Nesting — collapsible parent sections for Configuration and Logs"
epic: enhanced-logging
status: done
security_review: not-needed
matrix: false
ui: true
created: 2026-07-06
---

# Admin Sidebar Nesting

## Story

**As** a Nebu platform operator,
**I want** the admin sidebar navigation to support nested/collapsible parent sections with child links,
**so that** related admin pages are visually grouped (Configuration and its sub-pages, Logs and its monitoring/config/diagnostics pages), the sidebar remains uncluttered, and navigation feels modern and discoverable (nested/collapsible nav is now standard UX in admin dashboards).

The current flat-list navigation renders separate top-level items for "Configuration," "Role Mapping," and "Claim Mapping," even though Role Mapping and Claim Mapping are logically nested under Configuration. Similarly, new logging-related pages (monitoring view, retention settings, war room diagnostics) currently live under a flat "Logs" top-level entry, but they should be nested child pages. Operators reviewed this and explicitly noted: "das ist man mittlerweile so gewohnt" (this is what users expect from modern admin UIs).

This story is distinct from the logging features themselves (those are built in parallel/prior stories in this epic) — this story is **pure UI navigation infrastructure**. It adds the mechanism for true parent/child hierarchy and applies it to reorganize Configuration and Logs sections. The mechanism itself is reusable for any future admin section that needs nesting.

## Background

### Current State

The admin sidebar (`Nebu.Admin.Layouts`) renders nav items as a flat list using the `nav_item/1` private function component. The route structure **is already nested** (e.g., `/admin/config/role-mapping` is a child route of `/admin/config`), but the navigation presentation is flat — all items appear at the same visual level with no visual grouping. Navigation selection is via `@active_nav` assign, which matches the nav key against the current route to determine highlight.

Current navigation structure (flat):
```
- Bootstrap Setup (conditional, pre-bootstrap only)
- Dashboard
- Compliance
- Logs
- Users
- Rooms
- Spaces
- Configuration
- Role Mapping  ← logically under Configuration, but rendered as peer
- Claim Mapping ← logically under Configuration, but rendered as peer
- Logout
```

### Motivation

1. **Cognitive clarity**: Grouping related pages (Configuration + its sub-pages; Logs + monitoring/config/war-room) reduces scanning time and makes the hierarchy visible.
2. **Discoverability**: Collapsed nested sections signal "there are more options here" without cluttering the default view.
3. **Modern UX pattern**: Nested/collapsible sidebars are now the standard in admin dashboards (Terraform, Grafana, GitHub Admin, AWS Console). Operators expect this.
4. **Future-proofing**: The enhanced-logging epic adds multiple Logs sub-pages (`/admin/logs/config`, `/admin/logs/war-room`); organizing them under a parent "Logs" section prevents sidebar bloat.

### Scope: Navigation UX Only

This story builds ONLY the navigation mechanism and reorganizes existing routes. It does NOT:
- Implement the logging pages themselves (those are separate stories: admin-logs-monitoring-view, admin-logs-retention-settings, war-room-mode)
- Add new routes (routes already exist)
- Change page functionality or page layouts

## Acceptance Criteria

### Mechanism: Nested Nav Items with Expand/Collapse

**AC1:** The nav component in `Nebu.Admin.Layouts` is extended to support parent items with optional child lists. The layout accepts a nested structure (in data or template) such that:
- A parent item (e.g., "Configuration") can optionally have a list of child nav_items
- When a parent has children, a toggle control (chevron icon or similar) appears next to the parent label
- Clicking the parent label's toggle expands/collapses the child list (CSS-driven `display: block / none` or similar, no JS framework required)

**AC2:** The `nav_item` component is refactored from a private function to an internal Phoenix.Component that can render either:
- A standalone leaf item (no children) — exactly as today
- A parent item with an inline child `<ul>` that expands/collapses (new)

Refactor intent: the component must be flexible enough to support both modes without breaking existing nav items or requiring major template rewrites in `layouts.ex`.

### Active-State Highlighting: Parent + Child

**AC3:** The `@active_nav` assign mechanism is extended to determine active state for BOTH parents and children:
- If `@active_nav` exactly matches a nav item's `key`, that item is highlighted (current behavior).
- **NEW:** If `@active_nav` matches any child's `key`, the parent is ALSO visually active/expanded (even if the parent's own key is not matched). This ensures "you are inside this section" is always visible.
  - Example: when navigating to `/admin/config/role-mapping`, `@active_nav="role-mapping"`, the "Configuration" parent should be expanded and visually highlighted (even though its key is "config"), and the "Role Mapping" child should have the primary highlight.

**AC4:** The visual hierarchy when a child is active should be:
- Parent: secondary highlight or accent (e.g., a slightly lighter background, or a sidebar accent color), never the full primary color
- Active child: full primary highlight (current `bg-primary text-primary-content` class)
- Other children: neutral (current `text-base-content hover:bg-base-300`)

This prevents confusion about which level is "the current page" while still showing you're inside the parent section.

### Reorganization: Configuration Section

**AC5:** The "Configuration" and its child items are reorganized into a nested structure:

**Parent Item:**
- Label: "Configuration"
- Key: `"config"`
- Navigate: `/admin/config` (the main config page)

**Child Items:**
- "Role Mapping" (key: `"role-mapping"`, navigate: `/admin/config/role-mapping`)
- "Claim Mapping" (key: `"claim-mapping"`, navigate: `/admin/config/claim-mapping`)

**AC6:** The flat "Role Mapping" and "Claim Mapping" nav items are **removed** from the top-level nav list. They appear **only** as children under the "Configuration" parent. If the parent is collapsed, they are not visible; if expanded, they are indented and visually nested.

### Reorganization: Logs Section

**AC7:** A "Logs" parent section is created (key: `"logs"`) with the following structure:

**Parent Item:**
- Label: "Logs"
- Key: `"logs"`
- Navigate: `/admin/logs` (the monitoring view, built in the admin-logs-monitoring-view story)

**Child Items (planned/stub entries):**
- "Monitoring" (key: `"logs-monitoring"`, navigate: `/admin/logs`) — the live request-stream view from admin-logs-monitoring-view
- "Configuration" (key: `"logs-config"`, navigate: `/admin/logs/config`) — retention settings from admin-logs-retention-settings
- "War Room" (key: `"logs-war-room"`, navigate: `/admin/logs/war-room`) — diagnostics from war-room-mode

**AC8:** Child nav items (like "Logs: Monitoring") use a `key` that includes the parent namespace (e.g., `"logs-monitoring"`, not just `"monitoring"`) to avoid collisions with other sections' child keys. The `@active_nav` mechanism matches these keys exactly.

**Coordination Note:** Stories implementing these child pages (`admin-logs-monitoring-view`, `admin-logs-retention-settings`, `war-room-mode`) must set `@active_nav` to the appropriate child key (e.g., `assign(:active_nav, "logs-monitoring")` for the monitoring view) so that the sidebar highlights both the parent and the correct child. This is explicitly documented in the Dev Notes below.

### Accessibility — Nested Disclosure Pattern

**AC9:** Parent items with children render as `<button>` elements (not `<a>` links) with the following attributes:
- `aria-expanded`: `true` if the parent is expanded, `false` if collapsed. Changes dynamically when the user clicks the toggle.
- `aria-controls`: an `id` pointing to the child `<ul>` (e.g., `aria-controls="nav-config-children"`), establishing the relationship for screen readers.
- Keyboard operability: Space or Enter key toggles expand/collapse; Tab navigates through all nav items (parents and visible children).

**AC10:** Child items inside a collapsed parent are **not hidden from the DOM**, but are hidden via `display: none` or similar CSS class (so screen readers can still navigate to them if they expand the parent). Alternatively, if the children are rendered conditionally in the template (only when expanded), the implementation is acceptable as long as keyboard navigation still works when the parent is expanded.

**AC11:** The entire sidebar `<nav>` element retains its `aria-label="Admin navigation"` attribute and landmark role. The `data-navkey` attribute on each nav item (used by E2E tests) is preserved for all items, including nested children. No existing nav selectors should break; E2E tests that select `[data-navkey="role-mapping"]` continue to work (the element just moves under a parent, not removed).

### Visual Design — Indentation & Icons

**AC12:** Child items are visually indented (e.g., `ml-4` or similar Tailwind spacing) relative to the parent, making the hierarchy obvious without relying on color alone.

**AC13:** Parent items with children display a toggle icon (e.g., a chevron ">" or "▼") that rotates/changes when expanded/collapsed. The icon is placed to the left of the label (inside the clickable button area) so clicking the icon toggles expand/collapse. Clicking the label itself can either:
- Option A: Navigate to the parent's page (`/admin/config`) AND toggle expand/collapse (parent is both a link and a toggle).
- Option B: Navigate to the parent's page (`/admin/config`) with NO collapse behavior (clicking the label navigates, clicking the icon toggles).

**For this story**, Option A is acceptable as a first implementation (common in sidebars like Terraform, Grafana). Clarify with the developer if Option B is preferred (adds a small bit of UX complexity but is clearer for users who expect the label to be a link).

**AC14:** All visual changes use DaisyUI classes already in the codebase. No new color classes or animations are added; the design strictly reuses existing theme variables (`bg-base-300`, `text-base-content`, primary colors, etc.).

### Regression Testing — E2E Coverage

**AC15:** Every existing admin E2E test that asserts on nav structure or nav selection continues to pass WITHOUT modification. This includes:
- Tests that navigate via `page.locator('[data-navkey="..."]').click()` (e.g., role-mapping.spec.ts, ux-polish-9-13.spec.ts)
- Tests that assert `aria-current="page"` on a nav item (e.g., role-mapping.spec.ts)
- Tests that check nav visibility in certain states (e.g., ux-polish-9-13.spec.ts checking nav-key visibility before/after bootstrap)

**AC16:** If any existing E2E test DOES break due to this story's refactoring, it indicates a regression. The dev must investigate and either:
- Fix the nav mechanism to preserve the old selector
- Fix the test to use the new selector (acceptable ONLY if the test is testing nav structure itself, and the change is intentional and documented)

In all cases, every existing E2E test must pass before marking this story done.

### Scope Boundaries

**AC17:** This story implements ONLY:
- The nested nav component mechanism in `Nebu.Admin.Layouts`
- The Configuration nesting (with Role Mapping and Claim Mapping as children)
- The Logs nesting structure (parent item + child stubs for monitoring, config, war-room)
- The `@active_nav` extension for parent/child highlighting
- The accessibility pattern (aria-expanded, aria-controls, keyboard nav)

This story does NOT implement:
- The actual Logs monitoring page (admin-logs-monitoring-view story)
- The Logs retention settings page (admin-logs-retention-settings story)
- The War Room diagnostics page (war-room-mode story)
- Any new routes beyond the nesting mechanism

Those stories implement their own pages and set the appropriate `@active_nav` key to integrate with the nested nav.

## Acceptance Tests

### Tests written FIRST (before implementation code):

**1. [AC1–AC2] Nested nav items render with expand/collapse toggle** — ExUnit component test
   - Given: A parent nav item with children defined
   - When: The item is rendered
   - Then: A toggle/chevron icon is visible to the left of the parent label
   - And: The child list is rendered as a nested `<ul>` (initially expanded or collapsed per default state)
   - And: A leaf item (no children) renders exactly as before (no toggle icon)

**2. [AC3–AC4] Active-nav extends to parent when child is active** — ExUnit component test
   - Given: A nav structure with a parent "Configuration" and children "Role Mapping" and "Claim Mapping"
   - When: `@active_nav="role-mapping"` (child is active)
   - Then: The "Role Mapping" child item has the primary highlight class (`bg-primary text-primary-content`)
   - And: The "Configuration" parent has a secondary/accent highlight (e.g., `bg-base-300` or similar, NOT `bg-primary`)
   - And: Other children (e.g., "Claim Mapping") are neutral

**3. [AC3] When parent is active, parent is highlighted** — ExUnit component test
   - Given: `@active_nav="config"` (the Configuration parent itself)
   - When: The nav is rendered
   - Then: The "Configuration" parent item has the primary highlight
   - And: The child items are neutral (not highlighted)

**4. [AC5–AC6] Configuration nesting removes flat Role Mapping and Claim Mapping** — ExUnit integration test
   - Given: The admin layout rendered with bootstrap completed
   - When: The sidebar is inspected
   - Then: "Configuration" appears as a single top-level item
   - And: "Role Mapping" and "Claim Mapping" do NOT appear as top-level items
   - And: When the Configuration parent is expanded, "Role Mapping" and "Claim Mapping" are visible as nested children

**5. [AC7–AC8] Logs section is created with child stubs** — ExUnit integration test
   - Given: The admin layout rendered with bootstrap completed
   - When: The sidebar is inspected
   - Then: A "Logs" parent item is visible
   - And: When expanded, it shows child items: "Monitoring", "Configuration", "War Room" (all as stubs, keys "logs-monitoring", "logs-config", "logs-war-room")
   - And: The navigation works (clicking child items does not error, even if the pages don't fully exist yet)

**6. [AC9] Parent items render as buttons with aria-expanded** — ExUnit component test
   - Given: A parent nav item
   - When: The HTML is inspected
   - Then: The parent is a `<button>` element (not `<a>`), with `aria-expanded="true"` or `"false"`
   - And: The value of `aria-expanded` matches the expanded/collapsed state

**7. [AC9] aria-controls establishes relationship to child list** — ExUnit component test
   - Given: A parent nav item with children
   - When: The HTML is inspected
   - Then: The parent `<button>` has `aria-controls="nav-<parent-key>-children"` (e.g., `aria-controls="nav-config-children"`)
   - And: The child `<ul>` has a matching `id="nav-<parent-key>-children"`

**8. [AC10–AC11] Keyboard navigation and expand/collapse** — ExUnit component test + manual verification
   - Given: The admin sidebar rendered with a collapsed parent
   - When: Tab is pressed to focus the parent button
   - And: Space or Enter is pressed
   - Then: The parent expands and `aria-expanded` changes to `"true"`
   - And: The child items become visible and focusable via subsequent Tab presses
   - When: The parent button is focused again and Space is pressed
   - Then: The parent collapses, `aria-expanded` changes to `"false"`

**9. [AC11] data-navkey preserved on all items, including nested children** — ExUnit integration test
   - Given: The admin sidebar is rendered
   - When: The HTML is inspected
   - Then: Every nav item (parent and child) has a `data-navkey` attribute matching its key
   - And: A selector like `[data-navkey="role-mapping"]` successfully locates the nested child item

**10. [AC12] Nested children are visually indented** — ExUnit visual test (manual or screenshot comparison)
   - Given: The admin sidebar is rendered with an expanded parent
   - When: A child item is inspected
   - Then: The child has a left margin or padding that visually indents it relative to the parent (e.g., `ml-4`)

**11. [AC13] Parent items show a toggle chevron** — ExUnit visual test
   - Given: A parent nav item
   - When: The HTML is inspected
   - Then: A chevron or similar toggle icon is present inside the button
   - And: The icon rotates or changes appearance when the state toggles (CSS-driven, no JS logic needed)

**12. [AC15–AC16] Existing E2E tests still pass** — Integration test (Playwright)
   - Given: Running the existing admin E2E test suite (e.g., role-mapping.spec.ts, ux-polish-9-13.spec.ts)
   - When: The tests run against the new nested nav structure
   - Then: All tests pass without modification
   - And: Selectors like `[data-navkey="role-mapping"]` still work
   - And: `aria-current="page"` assertions still pass

**13. [AC3–AC4] Parent collapses when child on different section is active** — ExUnit component test
   - Given: Two parent sections: "Configuration" (with children) and "Logs" (with children)
   - When: `@active_nav="logs-monitoring"` (a Logs child)
   - Then: The "Logs" parent is expanded and highlighted secondarily
   - And: The "Configuration" parent is collapsed (or does not have secondary highlight)
   - And: When navigation changes to `@active_nav="role-mapping"` (a Configuration child), the behaviors reverse

## Dev Notes

### File Structure

**Modified:** `server/lib/nebu/admin/layouts.ex` — extend nav rendering
- Refactor the private `nav_item/1` function component to support both standalone items and parent items with children
- The component signature changes from:
  ```elixir
  defp nav_item(assigns) do
    # single-level item
  end
  ```
  to (example):
  ```elixir
  attr :navigate, :string, required: true
  attr :key, :string, required: true
  attr :active, :string, default: nil
  attr :children, :list, default: []  # NEW: optional list of child items
  # ... other attrs

  def nav_item(assigns) do
    # renders parent OR child depending on presence of children
  end
  ```
  
- Alternatively (cleaner), introduce a **separate** component for parent items (e.g., `nav_parent/1`) and keep `nav_item/1` for leaf items. This avoids overloading the component and makes the template clearer.
- In the `live/1` layout function, update the nav list to include parent items and pass child lists as attributes
- Example structure:
  ```heex
  <.nav_parent navigate="/admin/config" key="config" active={@active_nav}>
    Config
    <:child navigate="/admin/config/role-mapping" key="role-mapping">Role Mapping</:child>
    <:child navigate="/admin/config/claim-mapping" key="claim-mapping">Claim Mapping</:child>
  </.nav_parent>
  ```

**New:** `server/test/nebu/admin/layouts_nested_nav_test.exs` — comprehensive ExUnit tests
- Tests 1–13 above (component rendering, active-state, accessibility, visual structure, keyboard nav)
- Uses `Phoenix.LiveViewTest` helpers to render the layout and assert on HTML structure

### Architecture & Implementation Hints

**1. State Management for Expand/Collapse:**
   - The expanded/collapsed state for each parent can be:
     - *Option A (simple, stateless):* Always expanded by default; use CSS `:target` or a hidden checkbox pattern for collapse state (CSS-only, no JS).
     - *Option B (with state):* Store in the LiveView's `assigns` or in browser `localStorage` via a small phx-hook script. Provides persistent state across navigations.
   
   **For this story**, Option A (always-expanded or CSS-checkbox-trick) is simplest and avoids JS complexity. However, Option B is more polished (users expect their collapse state to persist). Clarify with the developer which is preferred.

**2. Active-Nav Logic for Parent Highlighting:**
   - In the `live/1` layout function or in a helper function, compute which parent(s) should be highlighted based on `@active_nav`:
     ```elixir
     defp parent_is_active?(parent_key, active_nav, children) do
       # Return true if:
       # 1. active_nav == parent_key (parent is directly active)
       # 2. active_nav is in Enum.map(children, &(&1[:key])) (a child is active)
       parent_key == active_nav or Enum.any?(children, &(&1.key == active_nav))
     end
     ```
   - Use this function to conditionally apply secondary highlight classes to the parent

**3. Keyboard Navigation:**
   - The parent button's click handler should toggle `aria-expanded` via a small `<script>` tag (no framework required):
     ```html
     <button aria-expanded="false" aria-controls="nav-config-children" onclick="this.setAttribute('aria-expanded', this.getAttribute('aria-expanded') === 'true' ? 'false' : 'true')">
       ...
     </button>
     ```
   - Alternatively, use a `phx-click` event in a LiveView and toggle state in `handle_event/3`

**4. CSS for Expand/Collapse:**
   - Use `display: none / block` or `max-height: 0 / auto` with `overflow: hidden` and a CSS transition for smooth animation
   - Example:
     ```css
     .nav-parent-children {
       max-height: 500px;
       overflow: hidden;
       transition: max-height 0.3s ease;
     }
     .nav-parent[aria-expanded="false"] .nav-parent-children {
       max-height: 0;
     }
     ```

**5. Coordination with Logging Stories:**
   - Stories implementing `/admin/logs`, `/admin/logs/config`, and `/admin/logs/war-room` must set `@active_nav` to the appropriate child key:
     - Monitoring view: `assign(:active_nav, "logs-monitoring")`
     - Retention settings: `assign(:active_nav, "logs-config")`
     - War Room: `assign(:active_nav, "logs-war-room")`
   - Add this requirement as a NOTE in each logging story's Dev Notes section (or include a forward-reference in this story's Dev Notes documenting the contract)

**6. E2E Test Regression Prevention:**
   - Before marking this story done, run the full admin E2E test suite:
     ```bash
     make test-integration
     ```
   - Monitor for any failures related to nav selectors or aria-current assertions
   - Common failure points:
     - `[data-navkey="..."]` selector returns multiple elements (parent + child?) — ensure selectors still work
     - `aria-current="page"` assertions on nav items — still work for nested children
     - Navigation timing (e.g., if collapse/expand has animation, tests may need `waitForLoadState()`)

**7. Accessibility Checklist Before Completion:**
   - Manual keyboard-only navigation of the sidebar (Tab, Space, arrow keys if used)
   - Screen reader verification (NVDA, JAWS, VoiceOver) of nav hierarchy and expanded state
   - Focus visibility: ensure the focus ring is visible on all nav items, especially when inside a collapsed section that is expanding
   - Color contrast: secondary highlight on parent items must meet WCAG AA (4.5:1 text contrast)

### Coordination Notes — Multi-Story Dependencies

- **admin-logs-monitoring-view story:** Must set `assign(:active_nav, "logs-monitoring")` in the LogsLive mount to highlight the correct child
- **admin-logs-retention-settings story:** Must set `assign(:active_nav, "logs-config")` in the LogsController to highlight the correct child
- **war-room-mode story:** Must set `assign(:active_nav, "logs-war-room")` in the WarRoomLive (or controller) to highlight the correct child
- If these stories are implemented in parallel with this one, this nav mechanism must be in place before they land, or they must be updated immediately after this story merges

### Testing Strategy

**Order of Test Execution:**
1. Unit tests (component rendering, active-nav logic) — fastest, no full browser
2. Integration tests with ExUnit (nav structure, E2E selectors) — medium
3. Full E2E test suite against real browser (regression testing) — slowest, must pass

**Test Data/Fixtures:**
- Use the same test data as existing admin tests (authenticated admin user, bootstrapped server)
- No new database fixtures needed; nav structure is pure template logic

**Blast Radius Warning:**
- This is a SHARED layout used by EVERY admin page. Every admin page will be affected by nav changes
- Regression risk is HIGH; extra care is needed during testing
- If any E2E test breaks, investigate thoroughly — it may indicate a subtle regression affecting all admin pages, not just nav

## Story-Completion Criteria

This story is **done** when:

1. ✅ Nested nav structure is implemented in `Nebu.Admin.Layouts`
2. ✅ Configuration section is reorganized with Role Mapping and Claim Mapping as children
3. ✅ Logs section is created with child stubs (Monitoring, Configuration, War Room)
4. ✅ Active-nav mechanism extends to highlight parent when child is active
5. ✅ All AC acceptance tests pass (13 tests, all green)
6. ✅ ALL existing admin E2E tests pass without modification (no regressions)
7. ✅ Accessibility verification: keyboard nav, screen reader compatibility, aria-expanded/aria-controls working
8. ✅ Visual inspection: indentation, chevron/toggle icon, colors meet design spec
9. ✅ Code review approves layout changes and test coverage

---

## Background: Current Route Structure (for reference)

The following routes already exist; this story does not create new routes, only reorganizes nav presentation:

```
/admin/config                  → ConfigController (main config page)
/admin/config/role-mapping    → RoleMappingController (already nested in URL)
/admin/config/claim-mapping   → ClaimMappingController (already nested in URL)
/admin/logs                    → LogsController (monitoring view, from admin-logs-monitoring-view story)
/admin/logs/config            → LogsController (retention settings, from admin-logs-retention-settings story)
/admin/logs/war-room          → WarRoomController (diagnostics, from war-room-mode story)
```

This story's job is to make the **navigation UI** reflect this nesting, not to change the route structure.

---

## Questions for the Developer (Resolution Notes)

**Q1: Expand/Collapse State Persistence**
- Should parent sections collapse when navigating away and re-expand when returning? (Option B: yes, use localStorage)
- Or should they always be expanded? (Option A: simpler, no persistence)

**Q2: Parent as Link or Just a Label**
- When clicking the parent label (not the toggle), should it navigate to the parent's page (e.g., `/admin/config`) AND toggle expand/collapse? (Option A, common)
- Or should only the toggle icon trigger collapse, and the label is non-interactive? (Option B, less common but clearer)

**Q3: Initial State**
- Should all parents be expanded by default (simplest)?
- Or only the parent matching `@active_nav` expanded, others collapsed (cleaner but more complex)?

Recommended defaults: Q1→Option A (no persistence), Q2→Option A (label + toggle), Q3→all expanded by default (simplest first implementation).


## Design Update (2026-07-07 — Trace Map Leitstand)

Phil approved an interactive design dummy that includes this story's sidebar nesting
exactly as scoped (Logs group: Live Stream / Trace Map / War Room; Configuration group:
General / Role Mapping / Claim Mapping). Authoritative design source:
`_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md` (§1) + `trace-map-leitstand-dummy.html` in the same directory.
Note: the Logs group gains a third child "Trace Map" (/admin/logs/trace-map, new page
from the leitstand spec) — include the nav item; the page itself is a separate story.

## Dev Agent Record

### Implementation Plan / Completion Notes (2026-07-07, dev-story cycle 0)

- **`nav_item/1` is now PUBLIC with two clauses** (`Nebu.Admin.Layouts`):
  - Leaf clause (`children == []`, the default) — byte-identical markup to the
    pre-nesting `<li><.link data-navkey=...>` item; zero change for existing call
    sites (AC2). `slot :inner_block` became optional (not `required`) so the
    component-contract tests can render it via `render_component/2` without a slot.
  - Parent clause — accessible disclosure group: `<button type="button"
    data-navkey={key} data-nav-toggle aria-expanded aria-controls="nav-{key}-children">`
    with a chevron SVG (`data-testid="nav-toggle-icon"`, `rotate-90` class when
    expanded) + label slot, followed by a sibling `<ul id="nav-{key}-children"
    role="list" class="ml-4 mt-1 space-y-1">` that carries the boolean `hidden`
    attribute when collapsed. Children ALWAYS stay in the DOM (AC10). The child
    `<ul>` deliberately carries NO display utility class so the UA's
    `[hidden] { display: none }` actually applies (avoids the trace-map-hierarchy
    cycle-1 flex-beats-hidden cascade bug).
  - Highlight priority (AC3/AC4): `key == active` → primary; a child's key matches
    → parent `bg-base-300` secondary (never `bg-primary`) + child primary with
    `aria-current="page"`; otherwise neutral. `expanded` defaults to `true` (Q3).
- **Toggle transport (CSP `script-src 'self'`, works on dead AND live views):**
  a single delegated document-level `click` listener, `wireNavSectionToggles()` in
  `server/priv/static/assets/app.js`, flips `aria-expanded` + `hidden` + the
  chevron's `rotate-90`. Native buttons fire `click` for mouse/Space/Enter, so
  AC9's keyboard operability comes for free; delegation survives LiveView morphdom
  patches and needs no socket on dead controller renders. No persistence (Q1/Q2/Q3
  resolved per the recommended defaults; the parent is a PURE toggle — the staged
  E2E contract proves Space must NOT navigate, so AC13's "Option A" label-navigation
  was superseded by AC9's button requirement + the ATDD keyboard scenarios).
- **IA (live/1):** "Logs" parent (children per the Leitstand spec §1 + AC7:
  Live Stream `logs-monitoring` → /admin/logs, Trace Map `logs-trace-map` →
  /admin/logs/trace-map, War Room `logs-war-room` → /admin/logs/war-room,
  Configuration `logs-config` → /admin/logs/config) and "Configuration" parent
  (Role Mapping, Claim Mapping, General `config-general` → /admin/config). Flat
  Role/Claim Mapping top-level items removed (AC6).
  - **Deviation (documented for review):** the Leitstand spec lists "General"
    FIRST under Configuration, but the ATDD keyboard scenario pins "Role Mapping"
    as the first Tab stop after the toggle, and AC5 enumerates only Role/Claim
    Mapping — so "General" is APPENDED (kept at all so /admin/config stays
    nav-reachable, since the parent is no longer a link).
- **Stub routes (AC7 "clicking child items does not error"):**
  `live "/logs/trace-map"` and `live "/logs/war-room"` → existing `LogsLive`
  (`:index`), to be repointed by `trace-map-leitstand` / `war-room-dedicated-page`.
- **Coordination contract (Dev Notes item 5) applied to the already-shipped pages:**
  `LogsLive` mount now assigns `active_nav: "logs-monitoring"`, `LogsController`
  (`/admin/logs/config`) now assigns `active_nav: "logs-config"`, and — UX gate V1
  fix (WCAG 1.3.1) — `ConfigController` (`/admin/config`) now assigns
  `active_nav: "config-general"` so the current page keeps a programmatic
  `aria-current="page"` indicator (the parent "config" key belongs to a pure
  disclosure button that never emits aria-current). No real page assigns a
  parent key ("config"/"logs") anymore; the `key == active`-on-parent branch
  remains covered by the component contract tests only.
- **CSS:** `make assets` re-ran; new utilities (`rotate-90`, `transition-transform`,
  `text-left`, `mt-1`, `space-y-1`, `h-4`/`w-4`, `shrink-0`, `py-2`) verified in the
  rebuilt `server/priv/static/assets/app.css`.
- **Tests:** `server/test/nebu/admin/layouts_nested_nav_test.exs` — 17/17 green.
  Full suite `make test-unit-elixir`: **1411 passed, 0 failures** (2 skipped,
  367 integration-excluded), `--warnings-as-errors` clean. `@pending-feature`
  tags removed from `e2e/features/admin/admin-sidebar-nesting.feature` (4
  scenarios now in the default Playwright run; executed by the pipeline CI gate).

## File List

- server/lib/nebu/admin/layouts.ex (modified — public dual-mode `nav_item/1`, nested IA)
- server/lib/nebu/admin/router.ex (modified — stub live routes /logs/trace-map, /logs/war-room)
- server/lib/nebu/admin/logs_live.ex (modified — active_nav "logs-monitoring")
- server/lib/nebu/admin/logs_controller.ex (modified — active_nav "logs-config")
- server/lib/nebu/admin/config_controller.ex (modified — active_nav "config-general", UX gate V1)
- server/priv/static/assets/app.js (modified — wireNavSectionToggles)
- server/priv/static/assets/app.css (regenerated — make assets)
- e2e/features/admin/admin-sidebar-nesting.feature (modified — @pending-feature tags removed; MINOR-2 hidden-assert added)
- e2e/step-definitions/admin/admin-sidebar-nesting.steps.ts (modified — MINOR-1 stale scaffold comment updated; MINOR-2 "is not visible" step added)
- docs/stories/enhanced-logging/admin-sidebar-nesting.md (modified — status/record)

## Change Log

- 2026-07-07: Implemented nested/collapsible sidebar sections (Logs, Configuration)
  with accessible disclosure buttons, parent/child highlight priority, CSP-safe
  delegated toggle in app.js, Logs child stubs incl. Trace Map, and coordination
  active_nav keys on the shipped logs pages. All 17 ATDD ExUnit tests green;
  full suite 1411/1411; E2E scenarios activated. Status → review.
- 2026-07-07 (UX gate V1 fix): ConfigController now assigns active_nav
  "config-general" so /admin/config retains a programmatic aria-current="page"
  (WCAG 1.3.1). Re-verified: nested-nav suite 17/17, full suite 1411 passed /
  0 failures.
- 2026-07-07 (code-review cycle 0 — 3 MINORs fixed): (1) stale ATDD scaffold
  comment in admin-sidebar-nesting.steps.ts rewritten to post-implementation
  reality; (2) new browser assertion "the sidebar nav item ... is not visible"
  (toBeHidden) after Space-collapse — regression gate for the flex-beats-hidden
  cascade bug; (3) nav_item/1's :navigate attr made optional and documented as
  LEAF-ONLY (parents are pure disclosure toggles), parent call sites in live/1
  no longer pass it. Verified: npx bddgen ok (no ambiguous steps), 4/4 sidebar
  E2E scenarios PASS against the live stack, full ExUnit suite 1411 passed /
  0 failures.
