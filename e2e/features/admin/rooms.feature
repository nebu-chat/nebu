Feature: Admin UI — Rooms Page
  As an authenticated admin operator
  I want to view the list of rooms in the Admin UI
  So that I can monitor room usage

  # Story 9-26 — Phase 3, AC12.
  # New feature derived from admin spec files:
  # tests/features/admin/rooms-page.spec.ts, rooms-api-integration.spec.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac12-rooms-list
  Scenario: Rooms page shows the list of existing rooms
    When the operator navigates to "/admin/rooms"
    Then the page shows "Rooms"
    And the room list contains at least one entry

  # Story admin-rooms-fallback-name AC9: the index can be narrowed by a search term (fallback names of
  # unnamed rooms and the escaping of member names are covered by the ExUnit acceptance suite).
  @admin-rooms-search
  Scenario: A search term without a match lists no rooms
    When the operator navigates to "/admin/rooms?q=no-such-room-zzz-9d4f1c"
    Then the page shows "Rooms"
    And the page shows "No rooms found."
