Feature: Admin UI — Stale room filter and badge
  As an authenticated admin operator
  I want to filter the rooms list by "Stale" and see a Stale badge
  So that I can identify and clean up abandoned rooms (0 active members)

  # Story rm2-stale-room-filter (epic: room-management-elixir) — ATDD, written FIRST.
  # Mirrors the spaces / rooms admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/stale-rooms.steps.ts
  #
  # RoomsLive is a LiveView master/detail with a status filter on the list:
  #   /admin/rooms             — list + status filter (all|active|archived|stale) + badges
  #   /admin/rooms/:room_id    — detail panel (status reads "Stale" for stale rooms)

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-stale-filter
  Scenario: [AC1/AC2] Admin filters by Stale and sees only the stale room with a Stale badge
    Given a stale room named "e2e-abandoned" exists
    When the operator navigates to "/admin/rooms"
    And the operator selects the "stale" status filter
    Then the room "e2e-abandoned" is listed with a "Stale" badge
