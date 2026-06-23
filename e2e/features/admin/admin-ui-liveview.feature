Feature: Admin UI (Phoenix LiveView) — Rooms Page
  As an authenticated admin operator
  I want the Phoenix LiveView Admin UI to list rooms with auto-join toggles
  So that I can manage rooms without the Go-template admin backend

  # ATDD — Written FIRST (before implementation code).
  # Story: admin-ui-migration (epic: full-elixir-stack)
  # AC1: admin → /admin/rooms → LiveView dashboard renders room list + auto-join toggles.
  #
  # Why this FAILS now (RED):
  #   The /admin/* routes are still served by the Go admin backend container, OR the
  #   Phoenix LiveView mount does not yet exist in nebu_http. There is no LiveView-rendered
  #   rooms page exposing per-room auto-join toggles via the new endpoint yet.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/admin-ui-liveview.steps.ts
  # OIDC: Authorization Code + PKCE via Dex (no ROPC) — reuses the shared admin login step.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @admin-ui-migration @ac1-liveview-rooms-list
  Scenario: [AC1] Phoenix LiveView rooms page lists rooms with auto-join toggles
    Given a room named "general" exists in the system
    When the operator navigates to "/admin/rooms"
    Then the page shows "Rooms"
    And the room list contains at least one entry
    And each room row shows an auto-join toggle control
    And the page is served by the Phoenix LiveView admin app
