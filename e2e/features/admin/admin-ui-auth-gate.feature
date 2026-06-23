Feature: Admin UI (Phoenix LiveView) — Admin Auth Gate
  As the Nebu operator
  I want the LiveView /admin area locked behind the admin claim
  So that a non-admin OIDC user cannot reach admin functionality

  # ATDD — Written FIRST (before implementation code).
  # Story: admin-ui-migration (epic: full-elixir-stack)
  # AC3: non-admin user (no admin claim in OIDC token) → /admin → 403 Forbidden
  #      OR redirect to /admin/login (admin gate preserved by the LiveView on_mount hook).
  #
  # Why this FAILS now (RED):
  #   The on_mount admin-claim guard for the LiveView does not exist yet. Until the
  #   Phoenix LiveView and its on_mount hook (current_user.admin == true) are implemented,
  #   there is no LiveView-level admin gate to exercise — the route is still Go-served.
  #
  # OIDC: Authorization Code + PKCE via Dex (no ROPC). The non-admin user "alex" is a
  # valid Dex user WITHOUT the admin group claim (kai is the admin in the fixtures).
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/admin-ui-liveview.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed

  @admin-ui-migration @ac3-auth-gate
  Scenario: [AC3] Non-admin OIDC user is denied access to the LiveView admin area
    Given a non-admin user is logged in via OIDC
    When the operator navigates to "/admin/rooms"
    Then the admin area access is denied with 403 or a redirect to the admin login
