Feature: Join a Space via Element Web UI
  As a Nebu user
  I want to join public and restricted Spaces via Element Web
  So that I can access Space content and child rooms

  # WHY THIS IS RED (different reasons per scenario):
  #
  # Scenario 1 (public join): New step definitions in join.steps.ts don't exist yet.
  #   The API helper createSpaceViaApi is reused from create-room-in-space.steps.ts,
  #   but the Gherkin wiring for Space join via the Element Web UI is new.
  #   Expected to go GREEN in dev-story.
  #
  # Scenario 2 (restricted join — member succeeds): Same as above: step definitions
  #   are new. Additionally, the restricted join ENFORCEMENT (MSC3083 / S4) may not yet
  #   be active on the deployed stack. If the server does not enforce restricted join
  #   rules (i.e. it either always rejects or always allows), the UI assertion will be
  #   wrong. This scenario has @ac-spaces-join but is NOT @pending-feature because the
  #   spec says a MEMBER should succeed — if the server rejects a member, that is a
  #   distinct server defect handled by Scenario 3b. The step itself is correct.
  #   Expected to go GREEN in dev-story once step wiring is committed (assuming S4 is live).
  #
  # Scenario 3 (restricted join — non-member blocked, 403):
  #   Tagged @pending-feature because the 403 M_FORBIDDEN enforcement from S4 may not
  #   yet be deployed. If S4 is not live, the server returns 200 (erroneously letting
  #   the non-member in), making the assertion fail. The test itself is correctly written.
  #   FOLLOW-UP BUG: if this scenario is RED due to missing 403 enforcement, open a
  #   /nebu-pipeline --bug run for story s4-restricted-join.

  Background:
    Given the Nebu stack is running

  @ac-spaces-join
  Scenario: Join a public Space via Element Web — Space appears in sidebar
    # Precondition: kai creates a public Space via the Matrix API.
    # alex (the primary context user) then joins it via the Element Web UI.
    Given kai has created a public Space "e2e-public-space" via the API
    And alex is logged in via Element Web
    When alex joins the Space "e2e-public-space" via Element Web
    Then the Space "e2e-public-space" appears in alex's Space panel

  @ac-spaces-join
  Scenario: Space member joins a restricted child room via Element Web (MSC3083)
    # Precondition (API only — not the thing under test):
    #   kai creates a Space and invites alex so alex is a Space member.
    #   kai creates a child room with join_rule:restricted referencing the Space.
    # Assertion: alex (already a Space member) navigates to the child room and joins.
    #   The room appears in alex's room list. Element Web shows the room join succeeds.
    Given kai has created a Space "e2e-restricted-space" and alex is a member via the API
    And kai has created a child room "e2e-restricted-child" with restricted join rule referencing the Space
    And alex is logged in via Element Web
    When alex navigates to room "e2e-restricted-child" via Element Web and joins
    Then the room "e2e-restricted-child" appears in alex's room list

  # @pending-feature — NOTE (2026-06-22): this is NOT a server defect. A direct API
  # probe confirmed the server already returns the expected 403 M_FORBIDDEN for a
  # non-member joining this restricted room (S4 enforcement is live — see
  # server.ex enforce_restricted_join!; AC3a above, which is GREEN, also proves
  # restricted joins work for members). The scenario is kept @pending ONLY because
  # enabling it currently breaks `npx bddgen` due to an UNRELATED broken WIP step
  # file from the parallel fix-short-oidc-sessions story
  # (e2e/step-definitions/element/auth/matrix-session-refresh.steps.ts: a malformed
  # cucumber expression `alex's draft / room context is preserved` + a duplicate
  # `the room list is visible` registration). Once that WIP file is fixed/landed,
  # drop @pending-feature here and this scenario will pass as-is. NO /nebu-pipeline
  # --bug is warranted for S4.
  @ac-spaces-join @pending-feature
  Scenario: Non-member cannot join a restricted child room — receives 403 M_FORBIDDEN
    # Precondition: kai creates a Space and does NOT invite marie.
    # kai creates a child room with join_rule:restricted referencing that Space.
    # Assertion: marie (not a Space member) calls POST /join/{roomId} directly and
    #   receives 403 M_FORBIDDEN. This is an API assertion, not a UI assertion,
    #   because Element Web does not show a UI join path for a room that will be rejected.
    Given kai has created a Space "e2e-restricted-space-2" without inviting marie via the API
    And kai has created a child room "e2e-restricted-child-2" with restricted join rule referencing the Space
    When marie attempts to join "e2e-restricted-child-2" directly via the Matrix API
    Then the join response is 403 M_FORBIDDEN
