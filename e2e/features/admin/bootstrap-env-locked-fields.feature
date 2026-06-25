Feature: Admin UI — Bootstrap OIDC fields locked when set via env vars
  As an operator
  I want OIDC fields pre-filled and read-only in the Bootstrap Wizard when set via env var
  So that I understand which values are operator-controlled vs. wizard-configured

  # ATDD — Written FIRST (before implementation code).
  # Story: bugfix/room-names (AC4 — Env vars lock bootstrap fields)
  #
  # AC4: When NEBU_OIDC_ISSUER is set via env, the bootstrap OIDC step shows the issuer
  # field as pre-filled and read-only (disabled input + locked indicator). Same for
  # NEBU_OIDC_AUDIENCE, NEBU_OIDC_CLIENT_ID. Fields not set via env remain editable.
  #
  # These scenarios require the running stack to have specific env vars set. They use
  # test.skip() when the targeted env variable state cannot be observed from the browser
  # (env vars are server-side). The E2E test observes the EFFECT: the browser receives
  # a disabled/readonly input with the env-var value pre-filled.
  #
  # The scenarios do NOT need a fresh unbootstrapped instance: the field-locking
  # behavior is observable on a standard bootstrapped stack by navigating to the OIDC
  # step directly via the bootstrap wizard URL with a step param. The lock UI must be
  # visible regardless of bootstrap state (an operator re-entering the wizard should
  # still see env-set fields as locked).
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/bootstrap-env-locked-fields.steps.ts
  #
  # To run locally:
  #   NEBU_OIDC_ISSUER=https://idp.example.com NEBU_OIDC_CLIENT_ID=nebu make dev
  #   npx playwright test --project=admin-ui --grep @env-locked-fields

  Background:
    Given the Nebu stack is running
    And the operator is logged in as admin

  @env-locked-fields
  Scenario: Issuer and client_id fields are disabled when set via env var
    Given NEBU_OIDC_ISSUER is set to "https://dex.example.com/dex" in the server environment
    And NEBU_OIDC_CLIENT_ID is set to "nebu-admin" in the server environment
    When the operator navigates to the bootstrap OIDC step
    Then the issuer field is disabled and pre-filled with "https://dex.example.com/dex"
    And the issuer field shows a locked indicator
    And the client_id field is disabled and pre-filled with "nebu-admin"
    And the client_id field shows a locked indicator
    And the audience field is editable

  @env-locked-fields
  Scenario: Audience field is disabled when NEBU_OIDC_AUDIENCE is set via env var
    Given NEBU_OIDC_AUDIENCE is set to "nebu-matrix" in the server environment
    When the operator navigates to the bootstrap OIDC step
    Then the audience field is disabled and pre-filled with "nebu-matrix"
    And the audience field shows a locked indicator

  @env-locked-fields
  Scenario: All three OIDC fields are editable when no env vars are set
    Given no OIDC env vars are set in the server environment
    When the operator navigates to the bootstrap OIDC step
    Then the issuer field is editable
    And the client_id field is editable
    And the audience field is editable

  @env-locked-fields
  Scenario: Locked indicator uses "(set via env)" label
    Given NEBU_OIDC_ISSUER is set to "https://dex.example.com/dex" in the server environment
    When the operator navigates to the bootstrap OIDC step
    Then the page shows "(set via env)" near the issuer field
