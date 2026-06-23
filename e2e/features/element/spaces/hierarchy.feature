Feature: Space hierarchy is rendered in the Element Web Space landing view
  As a Nebu user browsing a Space
  I want to see the Space's child rooms in the Space landing view
  So that I can navigate to the rooms that belong to the Space

  # VISIBILITY CONTRACT:
  # alex is a member of the Space but NOT of the child rooms. Per MSC2946 hierarchy
  # visibility and Nebu S3 `room_visible?/3` (member OR public OR world_readable), a
  # child appears in GET /hierarchy for alex only if alex is in it OR it is public /
  # world_readable. The children are therefore created PUBLIC (preset public_chat) so
  # a Space-member legitimately sees them. (Earlier the children were created PRIVATE,
  # which the server CORRECTLY filtered out — that was a test-design error, not a
  # server defect; fixed by making the children public.)
  #
  # With public children, a GREEN result proves the hierarchy endpoint surfaces
  # visible children. If this scenario goes RED against a running stack, THAT would be
  # a genuine S3 defect → tag @pending-feature and open a /nebu-pipeline --bug for S3.

  Background:
    Given the Nebu stack is running

  @ac-spaces-hierarchy
  Scenario: Space landing view renders child rooms from the hierarchy endpoint (S3)
    # Precondition (API only):
    #   kai creates a Space "e2e-hierarchy-space" (createSpaceViaApi).
    #   kai creates two rooms "e2e-child-alpha" and "e2e-child-beta".
    #   kai issues two m.space.child state PUTs to link both rooms to the Space.
    #   (PUT /rooms/{spaceId}/state/m.space.child/{childRoomId} with {"via":["localhost"],"suggested":true})
    # Assertion: alex opens the Space landing view and both rooms are visible in
    #   .mx_SpaceRoomView_landing / .mx_SpaceHierarchy_list.
    Given kai has created a Space "e2e-hierarchy-space" with child rooms "e2e-child-alpha" and "e2e-child-beta" via the API
    And alex is logged in via Element Web
    When alex opens the Space "e2e-hierarchy-space" landing view
    Then the child room "e2e-child-alpha" is visible in the Space hierarchy
    And the child room "e2e-child-beta" is visible in the Space hierarchy
