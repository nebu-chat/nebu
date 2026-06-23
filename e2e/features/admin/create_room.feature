Feature: Admin UI — Create a room
  As an authenticated admin operator
  I want to create a new room from the Admin UI
  So that I can set up the workspace without opening a Matrix client

  # Story rm3-admin-create-archive (epic: room-management-elixir) — ATDD, written FIRST.
  # Mirrors the spaces admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/create-room.steps.ts
  #
  # RoomsLive is a LiveView master/detail:
  #   /admin/rooms            — list + "Create room" button opening a DaisyUI modal
  #   /admin/rooms/:room_id   — the new room's detail panel (create redirects here)

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-create-button
  Scenario: [AC1] The rooms list shows a Create room button + modal
    When the operator navigates to "/admin/rooms"
    And the operator opens the create-room modal
    Then the create-room modal shows a name field and a visibility selector

  @ac2-create-room
  Scenario: [AC2] Admin creates a room and lands on its detail panel
    # P0 — create via the Matrix createRoom path; redirect to the new room's detail.
    When the operator navigates to "/admin/rooms"
    And the operator creates a room named "e2e-new-room" with visibility "Private"
    Then the operator is taken to the room detail panel for "e2e-new-room"

  @ac3-create-validation
  Scenario: [AC3] Empty room name shows an inline error and the modal stays open
    When the operator navigates to "/admin/rooms"
    And the operator opens the create-room modal
    And the operator submits the create-room form with an empty name
    Then the create-room modal shows the error "Name is required"
