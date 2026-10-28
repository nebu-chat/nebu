Feature: Room Join via Invite in Element Web UI
  As a Nebu user who has been invited to a room
  I want to accept the invite via the Element Web UI
  So that I can participate in the room

  # Story sync-membership-partition (epic oauth-broker, follow-ups `ev` + `ez`): `/sync` serves `rooms.invite` (stripped invite_state) and
  # `rooms.leave` (the leave window), so BOTH scenarios drive the REAL invitation tile of Element's room list: the step waits for the tile
  # (before the story it navigated to the room-id URL, because the invitation never arrived through /sync).
  #   @ac8-join-room       alex waits for the invitation tile, opens it, accepts, and the room is in his sidebar.
  #   @ac8-decline-invite  alex declines: the tile disappears; Element's own /sync responses carry the decline as `rooms.leave` ending with
  #                        alex's leave event; after kai posts a message the room is in NO section of alex's next incremental /sync;
  #                        alex is not a member (a full /sync lists the room nowhere).

  Background:
    Given the Nebu stack is running
    And a room "invite-test-template" exists and kai is the owner

  @ac8-join-room
  Scenario: Accept invite via UI
    Given kai has invited alex to "invite-test-template"
    And alex is logged in via Element Web
    When the invite for "invite-test-template" appears in alex's sidebar
    And alex clicks "Accept"
    Then the room "invite-test-template" appears in the sidebar

  @ac8-decline-invite
  Scenario: Decline invite via UI
    Given kai has invited alex to "invite-test-template"
    And alex is logged in via Element Web
    And alex's Element sync responses are recorded
    When the invite for "invite-test-template" appears in alex's sidebar
    And alex clicks "Decline"
    Then the invite for "invite-test-template" disappears from alex's sidebar
    And alex's Element received the decline of "invite-test-template" as a leave
    And after kai posts a message in "invite-test-template" alex's next incremental sync has the room in no section
    And alex is not a member of "invite-test-template" on the server
