Feature: Admin UI — Sidebar Nesting: collapsible parent sections for Configuration and Logs
  As a Nebu platform operator
  I want the admin sidebar to group related pages under collapsible parent sections
  So that the navigation stays uncluttered and the current section is always obvious

  # ATDD, written FIRST (RED phase) — story: enhanced-logging/admin-sidebar-nesting
  # docs/stories/enhanced-logging/admin-sidebar-nesting.md
  #
  # Component-level coverage of this story's own Acceptance Tests 1-11 and 13
  # (parent/child render contract, aria-expanded/aria-controls markup,
  # highlight-priority logic, data-navkey preservation, Configuration/Logs
  # reorganization) lives in server/test/nebu/admin/layouts_nested_nav_test.exs
  # — see that file's moduledoc for the full component + integration
  # contract this story's dev-story pass must implement.
  #
  # This file covers the genuinely browser-only half Phoenix.LiveViewTest/Floki
  # cannot exercise: real keyboard focus + Space/Enter toggling a native
  # <button>'s aria-expanded state (AC9/AC10), and end-to-end proof that the
  # pre-existing E2E-relevant selectors/assertions this refactor must not
  # regress (data-navkey, aria-current="page" — AC15/AC16) still resolve
  # against the REAL rendered page after the nesting refactor lands. Mirrors
  # the established split in this codebase between
  # logs_live/trace_map_tree_test.exs (component) and
  # logs-trace-map-hierarchy.feature (real browser) for the sibling
  # trace-map-hierarchy story.
  #
  # NOTE on the legacy e2e/tests/tests/features/admin/role-mapping.spec.ts and
  # ux-polish-9-13.spec.ts referenced by AC15/AC16: those two files are
  # pre-migration Playwright specs NOT wired into playwright.config.ts's
  # default project run (see that config's own header comment — only
  # features/**/*.feature via playwright-bdd runs by default; the legacy
  # e2e/tests/ specs run only via `tests/playwright.legacy.config.ts`, run
  # manually). They are therefore not a live regression gate today. This
  # feature file's "existing selectors still work" scenario below is the
  # ACTIVE regression proof for AC15/AC16 in the currently-running suite,
  # written in this codebase's current BDD convention rather than resurrecting
  # the legacy plain-spec pattern.
  #
  # The @pending-feature scaffold tags were removed by the dev-story pass once
  # the nested nav markup landed (`Nebu.Admin.Layouts.nav_item/1` public with
  # parent/child rendering, aria-expanded/aria-controls, and the
  # Configuration/Logs reorganization) — these scenarios now run in the
  # default Playwright suite.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  # Test-review MINOR-1: focus is reached via REAL repeated Tab keypresses
  # (not programmatic .focus()), and after re-expanding, one more Tab must
  # land INSIDE the expanded children (story Acceptance Test 8's "child items
  # become visible and focusable via subsequent Tab presses").
  # Test-review MINOR-3: the toggle must also resolve via the accessibility
  # tree as a real button with its visible label as its accessible name.
  @ac9-keyboard-nav @ac10-dom-presence
  Scenario: Keyboard-only Tab, then Space, toggles the Configuration nav section's aria-expanded state
    When the operator navigates to "/admin/config"
    And the operator presses Tab until the "config" nav toggle is focused
    Then the "config" nav toggle resolves as an accessible button named "Configuration"
    And the "config" nav toggle has aria-expanded "true"
    When the operator presses Space on the focused nav toggle
    Then the "config" nav toggle has aria-expanded "false"
    And the sidebar nav item "role-mapping" is present in the DOM
    # Code-review MINOR-2: the collapsed child must be ACTUALLY hidden in the
    # real browser, not just aria-collapsed — regression gate for the
    # flex-beats-hidden cascade bug (a display utility class on the child <ul>
    # would beat the UA's `[hidden] { display: none }` rule).
    And the sidebar nav item "role-mapping" is not visible
    When the operator presses Space on the focused nav toggle
    Then the "config" nav toggle has aria-expanded "true"
    And the sidebar nav item "role-mapping" is visible
    When the operator presses Tab once
    Then the sidebar nav item "role-mapping" is focused

  @ac9-keyboard-nav
  Scenario: Enter also toggles a nav section's aria-expanded state
    When the operator navigates to "/admin/config"
    And the operator presses Tab until the "logs" nav toggle is focused
    Then the "logs" nav toggle has aria-expanded "true"
    When the operator presses Enter on the focused nav toggle
    Then the "logs" nav toggle has aria-expanded "false"

  @ac15-regression @ac16-regression
  Scenario: Existing nav selectors and aria-current assertions still resolve after the nesting refactor
    When the operator navigates to "/admin/config/role-mapping"
    Then the sidebar nav item "role-mapping" is visible
    And the sidebar nav item "role-mapping" has aria-current "page"
    And the sidebar nav item "config" is visible

  # Test-review MAJOR-2 rewrite: sections render EXPANDED by default (the
  # pinned `:expanded` default plus the previous scenario's initial
  # aria-expanded="true"), so no toggle click is needed — clicking the toggle
  # first would COLLAPSE the section and make these visibility assertions
  # fail against a correct implementation. Starting page is /admin/config
  # (a non-logs page), so the final EXACT-path assertion cannot be satisfied
  # vacuously by the starting URL or by a sibling route like
  # /admin/logs/config.
  @ac7-logs-stub-navigation
  Scenario: The Logs section's child stubs are visible by default and the Monitoring stub navigates to /admin/logs
    When the operator navigates to "/admin/config"
    Then the "logs" nav toggle has aria-expanded "true"
    And the sidebar nav item "logs-monitoring" is visible
    And the sidebar nav item "logs-config" is visible
    And the sidebar nav item "logs-war-room" is visible
    And the sidebar nav item "logs-trace-map" is visible
    When the operator clicks the sidebar nav item "logs-monitoring"
    Then the page URL path is exactly "/admin/logs"
