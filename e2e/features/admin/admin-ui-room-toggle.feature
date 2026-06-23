Feature: Admin UI (Phoenix LiveView) — Auto-Join Toggle (live DOM-diff)
  As an authenticated admin operator
  I want to flip a room's auto-join state with a single click
  So that the change applies instantly (LiveView DOM-diff) and is persisted

  # ATDD — Written FIRST (before implementation code).
  # Story: admin-ui-migration (epic: full-elixir-stack)
  # AC2: admin toggles auto-join → reflected immediately via LiveView DOM-diff
  #      (no full page reload) AND persisted to the database (rooms.is_auto_join).
  #
  # Why this FAILS now (RED):
  #   No LiveView handle_event("toggle_auto_join", ...) exists. The Go-template UI
  #   used a settings <form> with a Save button (POST + redirect, full reload) — the
  #   LiveView in-place DOM-diff behaviour (no navigation) is a NEW requirement that
  #   the Go backend cannot satisfy.
  #
  # Persistence is verified through a real page reload (no DB-seeding / raw-SQL shortcut),
  # consistent with the existing auto-join-rooms.feature and CLAUDE.md E2E rules.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/admin-ui-liveview.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin
    And a room named "general" exists in the system
    And room "general" has auto-join disabled

  @admin-ui-migration @ac2-live-toggle
  Scenario: [AC2] Toggling auto-join updates in place without a full reload and persists
    When the operator navigates to the LiveView detail page for room "general"
    And the operator clicks the auto-join toggle for room "general"
    Then the auto-join toggle for room "general" shows as enabled without a full page reload
    And re-loading the LiveView room detail page still shows the auto-join toggle as enabled
