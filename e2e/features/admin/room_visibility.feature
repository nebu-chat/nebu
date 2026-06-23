Feature: Admin UI — Room visibility (public/private)
  As an authenticated admin operator
  I want to change a room's visibility between public and private from the Admin UI
  So that I can control whether the room is discoverable in the public room directory

  # Story rm1-room-visibility (epic: room-management-elixir) — ATDD, written FIRST.
  # Mirrors the spaces admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/room-visibility.steps.ts
  #
  # RoomsLive is a LiveView master/detail:
  #   /admin/rooms            — list of rooms + per-room auto-join toggle
  #   /admin/rooms/:room_id   — settings panel with a visibility <select> (Private/Public)

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-visibility-control
  Scenario: [AC1] The room detail panel shows a visibility select
    Given a room named "e2e-visibility-room" exists in the system
    When the operator opens the detail page for room "e2e-visibility-room"
    Then the room detail panel shows a visibility selector

  @ac2-ac3-flip-visibility
  Scenario: [AC2/AC3] Admin flips a private room to public
    # P0 — visibility persists via the audited Matrix update path and the panel reflects it.
    Given a room named "e2e-visibility-room" exists in the system
    When the operator opens the detail page for room "e2e-visibility-room"
    And the operator selects visibility "Public" and saves
    Then the room detail panel shows visibility "Public"
    And re-loading the room detail page still shows visibility "Public"
