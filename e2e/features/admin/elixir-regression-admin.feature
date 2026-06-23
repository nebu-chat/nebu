Feature: Elixir Stack Regression — Admin UI (Phoenix LiveView) functional parity
  As a Nebu operator
  I want the full Admin UI flow exercised in a real browser against Phoenix LiveView
  So that we have documented proof that no Admin UI flow regressed during the
  Go Admin UI → Phoenix LiveView migration.

  # ATDD — Written FIRST (regression GATE for epic full-elixir-stack).
  # Story: elixir-stack-regression.
  #
  # Framework: playwright-bdd + Cucumber (admin-ui project), real browser.
  # OIDC: Authorization Code + PKCE via Dex only — NO cookie forging, NO DB seeding.
  #
  # Reused steps (already defined — intentionally NOT redefined here):
  #   "the Nebu stack is running"                                   (common/stack-health.steps.ts)
  #   "bootstrap has been completed"                                (admin/bootstrap.steps.ts)
  #   "the operator is logged in as admin"                          (admin/bootstrap.steps.ts)
  #   "a room named {string} exists in the system"                  (admin/auto-join-rooms.steps.ts)
  #   "room {string} has auto-join disabled"                        (admin/admin-ui-liveview.steps.ts)
  #   "the operator navigates to the LiveView detail page for room {string}" (admin/admin-ui-liveview.steps.ts)
  #   "the operator clicks the auto-join toggle for room {string}"  (admin/admin-ui-liveview.steps.ts)
  #   "the auto-join toggle for room {string} shows as enabled without a full page reload" (admin/admin-ui-liveview.steps.ts)
  #   "re-loading the LiveView room detail page still shows the auto-join toggle as enabled" (admin/admin-ui-liveview.steps.ts)
  #   "the operator navigates to {string}"                          (admin/bootstrap.steps.ts)
  #   "the page shows {string}"                                     (admin/bootstrap.steps.ts)
  #   "the user list contains at least one entry"                   (admin/users.steps.ts)
  # New step (defined in admin/elixir-regression-admin.steps.ts):
  #   "the displayed user count matches the number of rendered user rows"

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  # AC3 — Room Management: toggle auto-join (visible, LiveView DOM-diff, reload preserves state).
  @elixir-stack-regression @ac3-room-management
  Scenario: [AC3] Room Management auto-join toggle persists against Phoenix LiveView
    Given a room named "general" exists in the system
    And room "general" has auto-join disabled
    When the operator navigates to the LiveView detail page for room "general"
    And the operator clicks the auto-join toggle for room "general"
    Then the auto-join toggle for room "general" shows as enabled without a full page reload
    And re-loading the LiveView room detail page still shows the auto-join toggle as enabled

  # AC3 — User Overview: imported user count matches the rendered list.
  @elixir-stack-regression @ac3-user-overview
  Scenario: [AC3] User Overview shows the imported user count against Phoenix LiveView
    When the operator navigates to "/admin/users"
    Then the page shows "Users"
    And the user list contains at least one entry
    And the displayed user count matches the number of rendered user rows
