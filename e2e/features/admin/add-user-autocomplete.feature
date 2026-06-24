Feature: Admin UI — Autocomplete existing users in add-user fields
  As an authenticated admin operator
  I want the "Add user" field to suggest existing users as I type
  So that I can pick a real user without remembering the exact Matrix id

  # Story admin-add-user-autocomplete (epic: room-naming-and-default-rooms) — ATDD.
  # Step definitions: e2e/step-definitions/admin/add-user-autocomplete.steps.ts
  #
  # The add-user input is an ARIA combobox:
  #   input[role="combobox"][data-field="add-member-user-id"]  (aria-autocomplete="list")
  #   ul[role="listbox"] > li[role="option"][data-role="user-suggestion"][data-user-id=...]
  # Selecting an option fills the input with the full Matrix id; the field stays
  # free-text and the existing add-member submit path is unchanged.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the existing user "alex" has logged in at least once
    And the operator is logged in as admin

  @ac1-rooms-suggest
  Scenario: [AC1] Typing in a room's Add user field suggests matching users
    When the operator creates a room for autocomplete
    And the operator types "al" into the Add user field
    Then a user suggestion for "@alex:localhost" is shown

  @ac1-rooms-select
  Scenario: [AC1/AC3] Selecting a suggestion fills the field and submit adds the member
    When the operator creates a room for autocomplete
    And the operator types "al" into the Add user field
    And the operator selects the user suggestion "@alex:localhost"
    Then the Add user field contains "@alex:localhost"
    When the operator submits the Add user form
    Then the member "@alex:localhost" appears in the member list

  @ac2-rooms-no-match
  Scenario: [AC2] A query matching no user shows no suggestions
    When the operator creates a room for autocomplete
    And the operator types "zzqqxx" into the Add user field
    Then no user suggestions are shown

  @ac4-spaces-suggest
  Scenario: [AC4] Typing in a Space's Add user field suggests matching users
    Given a space named "e2e-autocomplete" exists
    When the operator opens the detail page for space "e2e-autocomplete"
    And the operator types "al" into the Add user field
    Then a user suggestion for "@alex:localhost" is shown

  @ac4-spaces-select
  Scenario: [AC4] Selecting a suggestion on a Space fills the field
    Given a space named "e2e-autocomplete" exists
    When the operator opens the detail page for space "e2e-autocomplete"
    And the operator types "al" into the Add user field
    And the operator selects the user suggestion "@alex:localhost"
    Then the Add user field contains "@alex:localhost"
