Feature: Admin UI — Auto-Join Toggle (controller form POST)
  As an authenticated admin operator
  I want to flip a room's auto-join state with a single click
  So that the change is persisted (rooms.is_auto_join)

  # Story: admin-ui-migration (epic: full-elixir-stack), kept current for admin-http-refactor.
  #
  # CURRENT contract (RoomsLive was CONVERTED to RoomsController):
  #   The auto-join toggle is rendered ON THE ROOMS LIST (/admin/rooms) as a per-row
  #   <form method="post" action="/admin/rooms/:room_id/auto-join"> whose submit control is a
  #   <button role="switch" aria-label="Auto-join <name>" aria-checked=…> ([data-role="auto-join-toggle"]).
  #   Submitting flips rooms.is_auto_join and PRG-redirects back to /admin/rooms with the new
  #   state rendered server-side. There is NO LiveView socket and NO in-place DOM-diff — a full
  #   page render is the correct, expected behaviour, so the old "no full page reload" sentinel
  #   is removed. Persistence is still verified by reloading the list (no DB shortcut).
  #
  # Persistence is verified through a real page reload (no DB-seeding / raw-SQL shortcut),
  # consistent with the existing auto-join-rooms.feature and CLAUDE.md E2E rules.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/auto-join-rooms.steps.ts (reused)

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin
    And a room named "general" exists in the system
    And room "general" has auto-join disabled

  @admin-ui-migration @ac2-live-toggle
  Scenario: [AC2] Toggling auto-join flips the state and persists across a reload
    When the operator navigates to the detail page for room "general"
    And the operator enables the auto-join toggle
    Then the page shows the auto-join toggle as enabled
    And re-loading the room detail page still shows the auto-join toggle as enabled
