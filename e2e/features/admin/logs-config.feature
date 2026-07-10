Feature: Admin UI — Logs Retention Settings
  As a Nebu platform operator
  I want to configure log collection levels and retention windows at /admin/logs/config
  So that I can balance operational visibility against database growth without a redeploy

  # Story enhanced-logging/admin-logs-retention-settings — ATDD, written FIRST.
  # docs/stories/enhanced-logging/admin-logs-retention-settings.md
  #
  # RED PHASE: Nebu.Admin.LogsController does not exist yet, /admin/logs/config is not
  # registered in router.ex, and priv/static/assets/app.js has no wireLogsConfigToggles().
  # Every scenario below targets markup/behavior that is not yet implemented. Tagged
  # @pending-feature (same convention as oidc-directory-config.feature /
  # logs-monitoring.feature's own original RED phase) and excluded from the default e2e
  # run (see e2e/playwright.config.ts's DEFAULT_E2E_TAGS) until the dev-story implements it.
  #
  # WHY THIS FILE EXISTS (test-review MAJOR-2 finding): the ExUnit suite
  # (server/test/nebu/admin/logs_controller_test.exs) only exercises the server-rendered
  # HTML for a given DB state and the POST/redirect contract — it cannot execute
  # JavaScript. AC7 (click-to-toggle a bubble reveals/hides retention fields), AC8
  # (fields pre-fill with defaults the moment a level is toggled ON, BEFORE any submit),
  # and AC11 (the DEBUG warning appears/disappears live as the toggle changes) are all
  # implemented in a new client-side-only wireLogsConfigToggles() function (see
  # design-decisions.md #2/#4c) — no ExUnit test can observe that behavior. This file is
  # the real-browser twin of the static-HTML-contract assertions in logs_controller_test.exs,
  # mirroring exactly why logs-monitoring.feature exists for the sibling story's AC3.
  #
  # Data-attribute contract this file pins down for the dev agent (mirrors the existing
  # trace_map_bubble contract from logs_live_test.exs / logs-monitoring.steps.ts):
  #   - Bubble: [data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value=...]
  #   - Retention fields container: [data-testid="retention-fields"][data-bubble-value=...]
  #   - DEBUG warning: [data-testid="debug-warning"]

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @pending-feature @ac1-ac2-ac3-logs-config-route
  Scenario: The monitoring page links to the retention-settings page, which admins can reach
    When the operator navigates to "/admin/logs"
    And the operator clicks the "Sammlung konfigurieren" link
    Then the page shows "/admin/logs/config" in the URL

  @pending-feature @ac4-ac5-ac6-logs-config-bubbles
  Scenario: WARN and ERROR are always-on and non-interactive; INFO and DEBUG are toggleable
    When the operator navigates to "/admin/logs/config"
    Then the "warning" level bubble in the config page shows "always collected"
    And the "error" level bubble in the config page shows "always collected"
    And the "warning" level bubble in the config page is not a toggle button
    And the "error" level bubble in the config page is not a toggle button
    And the "info" level bubble in the config page is a toggle button
    And the "debug" level bubble in the config page is a toggle button

  @pending-feature @ac7-ac8-logs-config-toggle
  Scenario: Toggling the INFO bubble on reveals retention fields pre-filled with defaults
    Given INFO collection is currently off
    When the operator navigates to "/admin/logs/config"
    Then the retention fields for "info" are not visible
    When the operator clicks the "info" level bubble in the config page
    Then the retention fields for "info" are visible
    And the "info" days field shows "7"
    And the "info" max entries field shows "1000"
    When the operator clicks the "info" level bubble in the config page
    Then the retention fields for "info" are not visible

  @pending-feature @ac11-ac12-logs-config-warning
  Scenario: The excessive-logging warning appears only while DEBUG is toggled on
    Given DEBUG collection is currently off
    When the operator navigates to "/admin/logs/config"
    Then the DEBUG excessive-logging warning is not visible
    When the operator clicks the "debug" level bubble in the config page
    Then the DEBUG excessive-logging warning is visible
    And the DEBUG excessive-logging warning mentions "War Room mode"
    When the operator clicks the "debug" level bubble in the config page
    Then the DEBUG excessive-logging warning is not visible
    When the operator clicks the "info" level bubble in the config page
    Then the DEBUG excessive-logging warning is not visible

  @pending-feature @ac13-ac14-ac16-logs-config-persist
  Scenario: Saving retention settings persists them and survives a reload
    Given INFO collection is currently off
    When the operator navigates to "/admin/logs/config"
    And the operator clicks the "info" level bubble in the config page
    And the operator sets the "info" days field to "14"
    And the operator saves the logs retention settings form
    Then the page shows a success flash message
    When the operator navigates to "/admin/logs/config"
    Then the retention fields for "info" are visible
    And the "info" days field shows "14"
