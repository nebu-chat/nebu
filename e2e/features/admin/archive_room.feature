Feature: Admin UI — Archive and unarchive a room
  As an authenticated admin operator
  I want to archive and unarchive a room from the Admin UI
  So that I can retire stale rooms and bring them back without a Matrix client

  # Story rm3-admin-create-archive (epic: room-management-elixir).
  # Mirrors the room-visibility / spaces admin E2E (playwright-bdd + Cucumber).
  # Step definitions: e2e/step-definitions/admin/archive-room.steps.ts
  #
  # CURRENT contract (admin-http-refactor / AC12): RoomsController is a dead HTTP
  # controller — no LiveView socket, no confirm dialog. Every action is a form-POST
  # that PRG-redirects to the room detail page (/admin/rooms/:room_id):
  #   active room   → form-POST "Archive room" control + Active/Stale badge
  #   archived room → "Archived" badge + form-POST "Unarchive" control
  # Success/error render as a server-side flash (alert-success / alert-error).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac5-ac7-archive
  Scenario: [AC5/AC7] Admin archives an active room
    # P0 — archive persists status='archived'; the panel flips to the Archived badge +
    # an Unarchive control and shows a success flash.
    When the operator creates a room to archive
    And the operator archives the room
    Then the room detail panel shows the "Room archived" flash
    And the room detail panel shows the "Archived" badge
    And the room detail panel shows an "Unarchive" control

  @ac7-unarchive
  Scenario: [AC7] Admin unarchives an archived room
    # P1 — unarchive flips status back to active with a success flash.
    # Uses a fresh uniquely-named room (created active) so it is independent of the
    # shared stack's persisted/archived rooms — archive first, then unarchive.
    When the operator creates a room to archive
    And the operator archives the room
    And the operator unarchives the room
    Then the room detail panel shows the "Room unarchived" flash
    And the room detail panel shows an "Archive room" control
