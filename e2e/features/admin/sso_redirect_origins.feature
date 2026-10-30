@sso-redirect-origins
Feature: Admin UI — allowed SSO redirect origins
  As an instance admin
  I want to list the web client origins my users sign in with
  So that their legacy SSO logins skip the confirmation page

  # Story: oauth-broker / legacy-sso-redirect-confirmation (G3-3), AC14 + AC15 (the second save of a form works):
  # the form `#sso-origins-form` (POST /admin/config/sso-origins) on /admin/config next to "SSO redirect schemes".
  # Runner: playwright-bdd (admin-ui project). Step definitions: e2e/step-definitions/admin/sso-redirect-origins.steps.ts;
  # reused (never redefined): "the Nebu stack is running", "bootstrap is already completed", "an admin is logged
  # into the Admin UI", "the admin navigates to {string}", "the page shows a success flash message"
  # (oidc-directory-config.steps.ts, now a real assertion), "the page shows an error flash message containing
  # {string}", and the "Additional SSO redirect schemes" steps of sso-schemes.steps.ts.
  #
  # Story sso-origins-admin-hardening (X-1): saving the origins form and the schemes form needs a FRESH admin sign-in
  # (strict fetch metadata + a re-authentication marker bound to /admin/config, single use). The save steps follow the
  # "Sign in again to save" link (story admin-reauth-button-flow), sign in at the Dex login form once per save, then type the
  # values and press Save (helper `saveConfigFormWithAdminReauth`, e2e/fixtures/oauth-admin.ts).
  #
  # Hygiene: an @sso-redirect-origins After hook clears both server_config keys through the SAME forms (the save
  # refreshes the server's cache; a direct DB write would leave it stale).

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And an admin is logged into the Admin UI

  @ac14 @ac15
  Scenario: The origins are normalized and a second save takes effect
    When the admin navigates to "/admin/config"
    Then the page shows the "Allowed SSO redirect origins" field
    When the admin enters "https://Chat.E2E.example:443/, https://web.e2e.example:8443" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows a success flash message
    And the "Allowed SSO redirect origins" field shows "https://chat.e2e.example, https://web.e2e.example:8443"
    When the admin enters "https://chat.e2e.example" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows a success flash message
    And the "Allowed SSO redirect origins" field shows "https://chat.e2e.example"

  @ac14
  Scenario: A wildcard origin is refused
    When the admin navigates to "/admin/config"
    And the admin enters "https://*.e2e.example" in the "Allowed SSO redirect origins" field
    And the admin saves the SSO origins form
    Then the page shows an error flash message containing "not valid"
    And the "Allowed SSO redirect origins" field shows "https://*.e2e.example"
    And the "Allowed SSO redirect origins" field is marked invalid with its error message
    When the admin navigates to "/admin/config"
    Then the "Allowed SSO redirect origins" field does not show "*"

  @ac15
  Scenario: The SSO redirect schemes can be saved twice
    When the admin navigates to "/admin/config"
    And the admin enters "e2e-one" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    And the admin enters "e2e-two" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    Then the page shows a success flash message
    And the "Additional SSO redirect schemes" field shows "e2e-two"

  @x1
  Scenario: The two SSO trust forms say that saving needs a fresh sign-in
    When the admin navigates to "/admin/config"
    Then the "Save SSO origins" form control is described by the sign-in hint
    And the "Save SSO schemes" form control is described by the sign-in hint
