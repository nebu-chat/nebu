Feature: Admin UI — Add and remove room members
  As an authenticated admin operator
  I want to add and remove members of a room from the Admin UI
  So that I can manage room membership without opening a Matrix client

  # Story rm4-admin-member-management (epic: room-management-elixir) — ATDD, written FIRST.
  # Mirrors the create-room / spaces admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/member-management.steps.ts
  #
  # The room detail panel (/admin/rooms/:room_id) has a Members section:
  #   * an "Add user" form  [data-form="add-member"] (input name="user_id" + Add button)
  #   * one row per current member [data-role="member-row"][data-user-id=...]
  #   * a per-row Remove control [data-role="remove-member"] (absent for the admin's own row)

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-add-control
  Scenario: [AC1] The room detail panel shows an add-member control
    When the operator creates a room for member management
    Then the room detail panel shows the add-member form

  @ac2-add-member
  Scenario: [AC2] Adding a user makes them appear in the member list
    When the operator creates a room for member management
    And the operator adds the member "@alex:localhost"
    Then the member "@alex:localhost" appears in the member list

  @ac4-remove-member
  Scenario: [AC4] Removing a member makes them disappear from the list
    When the operator creates a room for member management
    And the operator adds the member "@alex:localhost"
    And the operator removes the member "@alex:localhost"
    Then the member "@alex:localhost" no longer appears in the member list

  @ac6-no-self-remove
  Scenario: [AC6] The admin's own member row has no Remove control
    When the operator creates a room for member management
    Then the admin's own member row has no Remove control
