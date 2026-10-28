Feature: Admin UI — War Room Dedicated Page

  As a Nebu platform operator
  I want a dedicated /admin/logs/war-room page listing all War Room sessions,
  with pre-session scoping (including an "exclusive scope" convenience) and a
  drill-down detail view per session
  So that I can discover, review, and investigate diagnostic sessions without
  the embedded panel that used to crowd the monitoring page

  # Story enhanced-logging/war-room-dedicated-page — ATDD, written FIRST.
  # docs/stories/enhanced-logging/war-room-dedicated-page.md
  # Read the story's "Story Amendments (2026-07-08 ...)" section — it
  # corrects 7 stale points from the original AC text (this file follows the
  # amendments, not the superseded literal wording).
  #
  # GREEN PHASE: the @pending-feature tag has been removed from every
  # scenario below now that Nebu.Admin.LogsLive.WarRoom, the exclusive_scope
  # column, the sidebar recording dot, and the topbar recording pill are
  # implemented — mirrors war-room-mode.feature's own dev-story un-tagging
  # convention.
  #
  # Data-attribute contract this file pins down for the dev agent (mirrors
  # the ExUnit-side contract in
  # server/test/nebu/admin/logs_live/war_room_test.exs and
  # server/test/nebu/admin/layouts_war_room_indicator_test.exs):
  #   - List page: [data-testid="war-room-session-row"][data-room-id=...]
  #   - Empty state: [data-testid="war-room-empty-state"]
  #   - Start form: [data-testid="war-room-start-form"]
  #   - Exclusive-scope options: [data-testid="war-room-exclusive-options"]
  #   - Detail metadata panel: [data-testid="war-room-detail-meta"]
  #   - Detail back link: [data-testid="war-room-detail-back-link"]
  #   - Not-found message: [data-testid="war-room-not-found"]
  #   - Copy-to-markdown button: [data-testid="war-room-copy-markdown-button"]
  #   - Copy toast: [data-testid="war-room-copy-toast"]
  #   - Sidebar recording dot: [data-testid="nav-war-room-dot"]
  #   - Topbar recording pill: [data-testid="topbar-war-room-pill"]
  #   - Retired embedded panel (must be ABSENT on /admin/logs):
  #     [data-testid="war-room-panel"]

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @war-room-dedicated-page @ac1-ac2-war-room-list
  Scenario: The War Room list page shows seeded sessions, active session first
    Given a War Room session "@e2e-wr-active:test.local" is active, started 30 seconds ago
    And an ended War Room session "@e2e-wr-ended:test.local" exists, ended 5 minutes ago
    When the operator navigates to "/admin/logs/war-room"
    Then the War Room session list shows 2 sessions
    And the first session row shows the "🟢 Active" status badge
    And a session row shows the "🔴 Ended" status badge

  # @known-failure (e2e/KNOWN-FAILURES.md, K5): the empty-state text no longer mentions /admin/logs (the test expectation is stale against the UI text)
  @war-room-dedicated-page @ac4-war-room-empty-state @known-failure
  Scenario: The War Room list page shows a placeholder when no sessions exist
    Given no War Room sessions exist
    When the operator navigates to "/admin/logs/war-room"
    Then the War Room empty-state message is visible
    And the War Room empty-state message mentions "/admin/logs"

  @war-room-dedicated-page @ac3-ac5-war-room-detail-drilldown
  Scenario: Clicking a session row opens its detail view with only its own logs
    Given an ended War Room session "@e2e-wr-detail:test.local" exists, ended 2 minutes ago
    And that session has 3 captured log entries
    When the operator navigates to "/admin/logs/war-room"
    And the operator clicks the session row for "@e2e-wr-detail:test.local"
    Then the operator is on the War Room session's detail page
    And the War Room detail metadata panel shows "@e2e-wr-detail:test.local"
    And the War Room detail page shows 3 captured log entries

  @war-room-dedicated-page @ac6-war-room-detail-404
  Scenario: Visiting a non-existent session's detail page shows a 404 message
    When the operator navigates to a non-existent War Room detail page
    Then the War Room not-found message is visible
    And the operator can navigate back to the War Room list from there

  @war-room-dedicated-page @ac7-ac8-war-room-scoping-form
  Scenario: The dedicated page's scoping form shows a live activity preview before starting a session
    When the operator navigates to "/admin/logs/war-room"
    Then the War Room start form is visible on the dedicated page
    And the War Room live-activity preview is visible
    When a request to "/admin/users" has been recorded
    Then the War Room live-activity preview updates without a page reload

  @war-room-dedicated-page @ac9-ac10-war-room-exclusive-scope
  Scenario: Starting a session with exclusive scope excludes the chosen endpoint from capture
    When the operator navigates to "/admin/logs/war-room"
    And the operator selects "exclusive" as the War Room scope
    Then the War Room exclusive-scope options are visible
    And the War Room exclusive-scope options include "/_matrix/client/v3/sync"
    When the operator checks "/_matrix/client/v3/sync" as an excluded endpoint
    And the operator starts a War Room with reason "e2e exclusive scope test" and scope "exclusive"
    Then the War Room panel shows "🚨 War Room Active"
    When the operator stops the active War Room

  # test-review finding 7 (fixed): the old version of this scenario only
  # asserted the sidebar nav item is visible — that item was already shipped
  # by admin-sidebar-nesting and would be visible (and pass) even with NONE
  # of this story's changes. This version proves something this story
  # actually delivers: clicking that link lands on the REAL dedicated page
  # (an "War Room" <h1>), not the old stub that silently re-rendered the
  # Live Stream page (amendment 1).
  @war-room-dedicated-page @amendment2-embedded-panel-retired
  Scenario: The embedded War Room panel is retired from the Live Stream page, and its sidebar link leads to the real dedicated page
    When the operator navigates to "/admin/logs"
    Then the embedded War Room panel is not present on the page
    When the operator clicks the War Room nav item
    Then the operator is on "/admin/logs/war-room"
    And the page heading is "War Room"

  @war-room-dedicated-page @amendment4-nav-dot-and-topbar-pill
  Scenario: An active session shows a recording dot and topbar pill from anywhere in the admin UI
    Given a War Room session "@e2e-wr-indicator:test.local" is active, started 10 seconds ago
    When the operator navigates to "/admin/dashboard"
    Then the sidebar War Room recording dot is visible
    And the topbar War Room recording pill is visible
    And the topbar War Room recording pill shows an elapsed time

  @war-room-dedicated-page @ac14-war-room-copy-to-markdown
  Scenario: Copying a session's markdown summary to the clipboard shows a confirmation toast
    Given an ended War Room session "@e2e-wr-copy:test.local" exists, ended 1 minute ago
    And that session has 2 captured log entries
    When the operator navigates to "/admin/logs/war-room"
    And the operator clicks the session row for "@e2e-wr-copy:test.local"
    And the operator clicks the copy-to-markdown button
    Then the operator sees a "Copied to clipboard" confirmation
    And the clipboard contains "@e2e-wr-copy:test.local"

  # test-review finding 6 — AC13's real keyboard-operability contract (native
  # <a>/<button> elements, Tab reachable, Space/Enter activate — mirrors
  # admin-sidebar-nesting.feature's own "real repeated Tab presses, not
  # .focus()" convention) had no E2E coverage at all; the ExUnit side can
  # only pin the static markup (role, tabindex, native element), never a
  # REAL browser's Tab order or Space/Enter activation.
  @war-room-dedicated-page @ac13-war-room-keyboard-navigation
  Scenario: Session rows and exclusive-scope checkboxes are fully keyboard-operable
    Given an ended War Room session "@e2e-wr-keyboard:test.local" exists, ended 3 minutes ago
    When the operator navigates to "/admin/logs/war-room"
    And the operator presses Tab until the session row for "@e2e-wr-keyboard:test.local" is focused
    And the operator presses Enter on the focused session row
    Then the operator is on the War Room session's detail page
    When the operator navigates to "/admin/logs/war-room"
    And the operator selects "exclusive" as the War Room scope
    And the operator presses Tab until the "/_matrix/client/v3/sync" excluded-endpoint checkbox is focused
    And the operator presses Space on the focused checkbox
    Then the "/_matrix/client/v3/sync" excluded-endpoint checkbox is checked
