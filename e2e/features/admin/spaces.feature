Feature: Admin UI — Spaces management
  As an authenticated admin operator
  I want to create, edit, manage child rooms of, and flag-as-auto-join Spaces
  So that I can organise the instance into Slack-style workspaces from the admin panel

  # Spaces S5 (epic: spaces-elixir) — ATDD, written FIRST (failing).
  # Mirrors the rooms admin / auto-join-rooms E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/spaces.steps.ts
  #
  # SpacesLive is a LiveView master/detail:
  #   /admin/spaces            — list + "Create Space" form + per-space auto-join toggle
  #   /admin/spaces/:space_id  — name/topic edit, child add/remove, auto-join toggle

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-spaces-list
  Scenario: Spaces page is reachable and shows the Spaces heading
    When the operator navigates to "/admin/spaces"
    Then the page shows "Spaces"

  @ac2-create-space
  Scenario: [AC2] Admin creates a Space
    # P0 — create via the Matrix createRoom path (creation_content.type=m.space).
    When the operator navigates to "/admin/spaces"
    And the operator creates a space named "e2e-engineering"
    Then the space "e2e-engineering" appears in the spaces list

  @ac4-add-child
  Scenario: [AC4] Admin adds a child room to a Space
    # P1 — writes m.space.child for the child via the authorized state PUT.
    Given a space named "e2e-engineering" exists
    And a room named "e2e-backend" exists in the system
    When the operator opens the detail page for space "e2e-engineering"
    And the operator adds child room "e2e-backend" to the space
    Then the child room "e2e-backend" is listed under the space

  @ac5-auto-join-toggle
  Scenario: [AC5] Admin toggles auto-join for a Space
    # P1 — auto-join persists via the audited update path and survives reload.
    Given a space named "e2e-engineering" exists
    When the operator opens the detail page for space "e2e-engineering"
    And the operator enables the space auto-join toggle
    Then the space auto-join toggle is shown as enabled
    And re-loading the space detail page still shows the auto-join toggle as enabled
