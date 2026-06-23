Feature: Create a Space via Element Web UI
  As a Nebu user organising my work
  I want to create a new Space via the Element Web "New Space" flow
  So that the Space appears in my Space panel sidebar

  # WHY THIS IS RED:
  # The step "alex creates a Space named {string} via Element Web" does not yet exist
  # in the spaces/create.steps.ts file (this file is new). The step drives
  # ElementSpacePage.createPrivateSpace() which exists in the page object, but the
  # Gherkin step wiring and the sidebar assertion step for spaces are new.
  # The Element Web UI flow itself (createPrivateSpace) is already implemented in
  # element-space.ts and tested via create-room-in-space.feature (Scenario 2), so
  # the underlying page-object works — only the new step wiring is missing.
  # Expected to go GREEN in dev-story once the step definitions in
  # e2e/step-definitions/element/spaces/create.steps.ts are committed.

  Background:
    Given the Nebu stack is running
    And alex is logged in via Element Web

  @ac-spaces-create
  Scenario: Create a private Space — Space button appears in the Space panel
    # Drives the genuine Element Web "Create a space" UI flow:
    # "Create a space" button → Private → name → Create → "Just me".
    # Asserts the new Space's button appears in .mx_SpacePanel after the reload.
    When alex creates a Space named "e2e-space-create" via Element Web
    Then the Space "e2e-space-create" appears in alex's Space panel
