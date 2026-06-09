Feature: Admin UI — Auto-Join Room Toggle
  As an authenticated admin operator
  I want to mark rooms as "auto-join" in the Admin UI
  So that newly registered users are automatically added without manual invites

  # ATDD — Written FIRST (before implementation code).
  # Story: admin-auto-join-rooms (epic: room-naming-and-default-rooms)
  #
  # These tests FAIL until:
  #   1. Migration 000003_auto_join_rooms adds is_auto_join column to rooms
  #   2. StubRoom.IsAutoJoin is wired in gateway/internal/admin/rooms.go
  #   3. UpdateSettingsHandler reads is_auto_join from form and passes to Core
  #   4. rooms.html renders the auto-join toggle inside the settings form
  #
  # Test framework: playwright-bdd + Cucumber
  # Step definitions: e2e/step-definitions/admin/auto-join-rooms.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin
    And a room named "e2e-autojoin" exists in the system

  @ac1-auto-join-enable
  Scenario: [AC1] Admin enables auto-join toggle for a room
    # P0 — Admin sets is_auto_join=true via the room detail settings form.
    # The DB is updated and the UI re-renders with toggle shown as enabled.
    When the operator navigates to the detail page for room "e2e-autojoin"
    And the operator enables the auto-join toggle
    And the operator submits the room settings form
    Then the page shows the auto-join toggle as enabled
    And re-loading the room detail page still shows the auto-join toggle as enabled

  @ac2-auto-join-disable
  Scenario: [AC2] Admin disables auto-join toggle for a room
    # P1 — Admin sets is_auto_join=false via the toggle. DB updated, UI reflects disabled.
    Given room "e2e-autojoin" has auto-join enabled
    When the operator navigates to the detail page for room "e2e-autojoin"
    And the operator disables the auto-join toggle
    And the operator submits the room settings form
    Then the page shows the auto-join toggle as disabled
    And re-loading the room detail page still shows the auto-join toggle as disabled
