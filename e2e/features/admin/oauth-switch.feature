@oauth-switch
Feature: Admin UI — switch for the OAuth 2.0 authorization server
  As an instance admin
  I want to switch OAuth on and off and to set its issuer URL on the Configuration page
  So that I can activate OAuth (and roll it back) on a running instance without database access

  # Story: oauth-broker / admin-oauth-switch (AC1-AC4, AC6, D1-D12): the section `#oauth-switch` with the form
  # `#oauth-switch-form` (POST /admin/config/oauth-switch) on /admin/config.
  # Runner: playwright-bdd (admin-ui project). Step definitions: e2e/step-definitions/admin/oauth-switch.steps.ts;
  # reused (never redefined): "the Nebu stack is running", "bootstrap is already completed", "an admin is logged into the
  # Admin UI", "the admin navigates to {string}", "the page shows a success flash message" (oidc-directory-config.steps.ts).
  #
  # Saving needs a FRESH admin sign-in (strict fetch metadata + a re-authentication marker bound to /admin/config, single use,
  # kept after a validation error): the save steps go through the Dex login form once per save (helper in the steps file).
  #
  # Hygiene: an @oauth-switch After hook switches OAuth OFF again and clears the issuer through the SAME form, so no other
  # scenario ever sees it on. Static check only in the isolated CI (bddgen + tsc): the stack with the real Dex does not run there.

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And an admin is logged into the Admin UI

  @ac1
  Scenario: The section shows the switch, the status list and the honest limits
    When the admin navigates to "/admin/config"
    Then the OAuth section shows the "Offer the OAuth 2.0 API" checkbox, the "Issuer URL" field and the "Save OAuth settings" button
    And the OAuth status list shows only items that start with a status word
    And the OAuth section says that load balancer, client IP and IdP behaviour are not checked by the server
    And the "Save OAuth settings" button is described by the fresh sign-in hint

  @ac3
  Scenario: Switching on without a valid https issuer is refused with a clear message
    When the admin navigates to "/admin/config"
    And the admin sets the OAuth switch on with the issuer "http://not-https.example" and the acknowledgement
    And the admin saves the OAuth settings
    Then the OAuth issuer field shows the error "switched on without a valid https issuer" and is marked invalid
    When the admin navigates to "/admin/config"
    Then the OAuth switch is off

  @ac3
  Scenario: Switching on needs the activation acknowledgement
    When the admin navigates to "/admin/config"
    And the admin sets the OAuth switch on with the issuer "https://oauth-switch.e2e.example" without the acknowledgement
    And the admin saves the OAuth settings
    Then the OAuth acknowledgement field shows the error "checklist" and is marked invalid
    When the admin navigates to "/admin/config"
    Then the OAuth switch is off

  @ac4 @ac6
  Scenario: Switching on and off round trip
    When the admin navigates to "/admin/config"
    And the admin sets the OAuth switch on with the issuer "https://oauth-switch.e2e.example" and the acknowledgement
    And the admin saves the OAuth settings
    Then the page shows an OAuth settings saved flash message
    And the OAuth switch is on with the issuer "https://oauth-switch.e2e.example"
    And the OAuth status list names the stored switch as on
    When the admin switches the OAuth switch off
    And the admin saves the OAuth settings
    Then the page shows an OAuth settings saved flash message
    And the OAuth switch is off
    And the OAuth status list names the stored switch as off
