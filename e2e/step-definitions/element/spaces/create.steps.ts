/**
 * Step definitions for features/element/spaces/create.feature
 *
 * Story spaces-elixir-s6-element-spaces-e2e — AC1 (@ac-spaces-create)
 *
 * Scenario: Create a private Space via Element Web → button in .mx_SpacePanel.
 *
 * STEP REGISTRATION NOTE:
 *   "{word} creates a Space named {string} via Element Web"
 *   is already registered as a Given in
 *   e2e/step-definitions/element/create-room-in-space.steps.ts.
 *   playwright-bdd uses ONE global step registry — registering the same text
 *   again here would cause an ambiguous-step error. This file therefore contains
 *   NO additional step registrations: the step is already available suite-wide.
 *
 *   "the Space {string} appears in alex's Space panel"
 *   is registered in spaces-common.steps.ts (SHARED STEP 2).
 *
 * This file is kept as a module boundary so TypeScript sees a clean import path
 * for any create.feature–specific helpers that may be added in future stories.
 */

// No imports or step registrations needed here.
// The required steps are provided by:
//   - create-room-in-space.steps.ts → "{word} creates a Space named {string} via Element Web"
//   - spaces-common.steps.ts        → "the Space {string} appears in alex's Space panel"
// Both files are picked up by the glob: step-definitions/**/*.ts
