Feature: Admin UI — Add-user field on room and space detail pages
  As an authenticated admin operator
  I want an Add user field on room and space detail pages
  So that I can add an existing user without opening a Matrix client

  # Story admin-add-user-autocomplete (epic: room-naming-and-default-rooms).
  #
  # HISTORY:
  #   The original typeahead was a phx-change LiveView combobox. It was REMOVED when
  #   RoomsLive/SpacesLive became server-rendered controllers (admin-http-refactor), and
  #   the five suggestion/selection scenarios were parked as @pending-feature.
  #
  #   admin-add-user-autocomplete RESTORED the typeahead in a controller-compatible,
  #   CSP-safe way (no LiveView, no inline JS):
  #     - a JSON search endpoint: GET /admin/users/search?q=… (Nebu.Admin.UsersController
  #       .search/2 → Nebu.Admin.UserSuggest.search/1 → parameter-bound SQL), behind
  #       :require_admin;
  #     - a vanilla-JS fetch autocomplete in priv/static/assets/app.js that renders
  #       ul[role="listbox"] > li[role="option"][data-role="user-suggestion"][data-user-id]
  #       and fills the input on select (user_id via textContent — XSS-safe).
  #   All five scenarios are reactivated below. The plain free-text submit path still
  #   works without JS (progressive enhancement).
  #
  # The add-user input (shared by Rooms + Spaces detail) is an ARIA combobox:
  #   [data-form="add-member"] input[name="user_id"][data-field="add-member-user-id"][role="combobox"]
  #   with a sibling [data-role="user-suggestions"] container the widget renders into.
  # Step definitions: e2e/step-definitions/admin/add-user-autocomplete.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the existing user "alex" has logged in at least once
    And the operator is logged in as admin

  @add-field-room
  Scenario: A room detail page exposes a plain Add user field that adds a member
    When the operator creates a room for autocomplete
    Then the Add user field is present on the page
    When the operator types "@alex:localhost" into the Add user field
    And the operator submits the Add user form
    Then the member "@alex:localhost" appears in the member list

  @add-field-space
  Scenario: A space detail page exposes a plain Add user field
    Given a space named "e2e-autocomplete" exists
    When the operator opens the detail page for space "e2e-autocomplete"
    Then the Add user field is present on the page

  # ── REMOVED CAPABILITY — live autocomplete combobox (see STALE-SPEC NOTE above) ──

  @ac1-rooms-suggest
  Scenario: [AC1] Typing in a room's Add user field suggests matching users
    # Restored: client-side fetch autocomplete (GET /admin/users/search), CSP-safe app.js.
    When the operator creates a room for autocomplete
    And the operator types "al" into the Add user field
    Then a user suggestion for "@alex:localhost" is shown

  @ac1-rooms-select
  Scenario: [AC1/AC3] Selecting a suggestion fills the field and submit adds the member
    # Restored: selecting a suggestion fills the input client-side; free-text submit unchanged.
    When the operator creates a room for autocomplete
    And the operator types "al" into the Add user field
    And the operator selects the user suggestion "@alex:localhost"
    Then the Add user field contains "@alex:localhost"
    When the operator submits the Add user form
    Then the member "@alex:localhost" appears in the member list

  @ac2-rooms-no-match
  Scenario: [AC2] A query matching no user shows no suggestions
    # Restored: empty result set renders no [data-role=user-suggestion] options.
    When the operator creates a room for autocomplete
    And the operator types "zzqqxx" into the Add user field
    Then no user suggestions are shown

  @ac4-spaces-suggest
  Scenario: [AC4] Typing in a Space's Add user field suggests matching users
    # Restored: same fetch autocomplete, on the Spaces detail page.
    Given a space named "e2e-autocomplete" exists
    When the operator opens the detail page for space "e2e-autocomplete"
    And the operator types "al" into the Add user field
    Then a user suggestion for "@alex:localhost" is shown

  @ac4-spaces-select
  Scenario: [AC4] Selecting a suggestion on a Space fills the field
    # Restored: suggestion selection fills the input client-side.
    Given a space named "e2e-autocomplete" exists
    When the operator opens the detail page for space "e2e-autocomplete"
    And the operator types "al" into the Add user field
    And the operator selects the user suggestion "@alex:localhost"
    Then the Add user field contains "@alex:localhost"
