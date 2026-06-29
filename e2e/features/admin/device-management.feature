Feature: Admin UI — Per-user device management
  As an authenticated admin operator
  I want to view, rename and revoke a user's devices from the Admin UI
  So that I can manage device access without opening a Matrix client

  # Story S4 (epic: device-management) — ATDD, written FIRST (RED).
  # Framework: playwright-bdd + Cucumber. Mirrors the member-management admin E2E.
  # Step definitions: e2e/step-definitions/admin/device-management.steps.ts
  #
  # The per-user detail page (/admin/users/:user_id) has a Devices section:
  #   * one row per device [data-role="device-row"][data-device-id=...]
  #     showing device id, display name, last-seen (ts + IP), created
  #   * a per-row rename form  [data-form="rename-device"][data-device-id=...]
  #     (input name="display_name" + a submit button)
  #   * a per-row revoke control [data-role="revoke-device"][data-device-id=...]
  #     carrying a confirmation step (Phoenix data-confirm)
  #   * an empty state [data-role="no-devices"] when the user has none
  #
  # Devices are created by logging the TARGET user in via the real Matrix login
  # flow (getApiSession) — no DB seeding, no cookie forging.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac1-device-list
  Scenario: [AC1] The user detail page lists the user's devices with metadata
    Given the user "alex" has logged in and has a registered device
    When the operator opens the device page for "@alex:localhost"
    Then a device row for "alex" is shown with its device id and last-seen metadata

  @ac1-empty-state
  Scenario: [AC1] A user with no devices shows the empty state
    When the operator opens the device page for "@nobody:localhost"
    Then the device list shows the empty state

  @ac2-rename
  Scenario: [AC2] Renaming a device persists and is reflected on reload
    Given the user "alex" has logged in and has a registered device
    When the operator opens the device page for "@alex:localhost"
    And the operator renames the device to "Renamed by Admin"
    And the operator reloads the device page for "@alex:localhost"
    Then the device display name is "Renamed by Admin"

  @ac3-revoke
  Scenario: [AC3] Revoking a device removes it after confirmation and logs the session out
    Given the user "alex" has logged in and has a registered device
    When the operator opens the device page for "@alex:localhost"
    And the operator revokes the device and confirms
    Then the device no longer appears in the device list
    And the revoked device's session can no longer authenticate
