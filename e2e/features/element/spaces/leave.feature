Feature: Leave a Space via Element Web UI
  As a Nebu user who is a member of a Space
  I want to leave the Space via the Element Web context menu
  So that the Space is removed from my Space panel

  # WHY THIS IS RED:
  # The leave-Space step definitions in leave.steps.ts do not exist yet (new file).
  # The API precondition steps (createSpaceViaApi, inviteUser/joinRoom for the Space)
  # and the Space-panel assertion steps are new wiring.
  # The underlying Element UI interaction (right-click SpacePanel button → Leave) is
  # new — room.steps.ts has "opens the room menu and clicks {string}" for room tiles
  # (right-click sidebar tile), but the Space panel button is a different element
  # (.mx_SpacePanel .mx_SpaceButton). A new "alex leaves the Space {string} via Element Web"
  # step is required.
  # Expected to go GREEN in dev-story once leave.steps.ts is committed.

  Background:
    Given the Nebu stack is running

  @ac-spaces-leave
  Scenario: Leave a Space — Space button disappears from the Space panel
    # Precondition (API): kai creates a Space and invites alex; alex joins via API so
    # the Space appears in alex's Space panel immediately upon login.
    Given kai has created a Space "e2e-space-leave" and alex is a member via the API
    And alex is logged in via Element Web
    And the Space "e2e-space-leave" appears in alex's Space panel
    When alex leaves the Space "e2e-space-leave" via Element Web
    Then the Space "e2e-space-leave" is not in alex's Space panel
