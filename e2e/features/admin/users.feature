Feature: Admin UI — Users Page
  As an authenticated admin operator
  I want to view and manage users in the Admin UI
  So that I can see who has access to the Nebu instance

  # Story 9-26 — Phase 3, AC12.
  # New feature derived from admin spec files:
  # tests/features/admin/users-page.spec.ts, users-api-integration.spec.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac12-users-list
  Scenario: Users page shows the list of registered users
    When the operator navigates to "/admin/users"
    Then the page shows "Users"
    And the user list contains at least one entry

  # device-bugfixes story — AC1/AC2/AC3/AC4 (Playwright/Gherkin guard for UI link regression)
  @ac-users-link
  Scenario: Each user row in the users list links to the device management page
    When the operator navigates to "/admin/users"
    Then each user row contains a link to the user detail page
    When the operator clicks the link for user "@alex:localhost"
    Then the device management page for "@alex:localhost" is shown
