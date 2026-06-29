Feature: Admin UI — Create a room
  As an authenticated admin operator
  I want to create a new room from the Admin UI
  So that I can set up the workspace without opening a Matrix client

  # Story rm3-admin-create-archive (epic: room-management-elixir).
  # Mirrors the spaces admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/create-room.steps.ts
  #
  # CURRENT contract (admin-http-refactor — RoomsLive was CONVERTED to RoomsController):
  #   /admin/rooms        — list page. A "Create room" link ([data-role="open-create-room"])
  #                         is a plain <a href="/admin/rooms/new"> — NOT a modal toggle.
  #   /admin/rooms/new    — a separate page with <form method="post" action="/admin/rooms">
  #                         (name input + visibility <select> + submit). No socket, no phx-*.
  #   POST /admin/rooms   — on success redirects (PRG) to the new room's detail page
  #                         /admin/rooms/:room_id ([data-page="room-detail"]); on a validation
  #                         error re-renders the list (/admin/rooms) with [data-role="create-error"].

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-create-button
  Scenario: [AC1] The rooms list links to a create-room page with a name field + visibility selector
    When the operator navigates to "/admin/rooms"
    And the operator opens the create-room page
    Then the create-room page shows a name field and a visibility selector

  @ac2-create-room
  Scenario: [AC2] Admin creates a room and lands on its detail page
    # P0 — create via the Matrix createRoom path; PRG redirect to the new room's detail page.
    When the operator navigates to "/admin/rooms"
    And the operator creates a room named "e2e-new-room" with visibility "Private"
    Then the operator is taken to the room detail page for "e2e-new-room"

  @ac3-create-validation
  Scenario: [AC3] Empty room name re-renders the rooms list with an inline error
    # The controller re-renders /admin/rooms (200) with [data-role="create-error"] "Name is
    # required" when the submitted name is empty. (Was: "modal stays open" — the modal is gone;
    # the equivalent post-submit outcome is the list page carrying the server-side error.)
    When the operator navigates to "/admin/rooms"
    And the operator submits the create-room form with an empty name
    Then the rooms list shows the create error "Name is required"

  # Story admin-room-creator-provisioning (epic: room-naming-and-default-rooms) — AC4 + AC5.
  # Regression: an admin whose Matrix id has no `users` row used to leave an orphan room
  # (raw "!…:localhost" id + "Stale" badge). The creator-provisioning fix means the room
  # must now show its typed name with an "Active" status. The admin in this stack logs in
  # via the Admin-UI OIDC flow (no pre-seeded Matrix `users` row) — exactly the bug case.
  @ac4-created-room-named-and-active @room-creator-provisioning
  Scenario: [AC4/AC5] An admin-created room shows its name and an Active status (not the raw id + Stale)
    When the operator navigates to "/admin/rooms"
    And the operator creates a room named "general" with visibility "Private"
    And the operator navigates to "/admin/rooms"
    Then the rooms list shows a room named "general" with status "Active"
    And the rooms list does not show that room as a raw room id
    And the rooms list does not show that room with status "Stale"
