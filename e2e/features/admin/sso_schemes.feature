Feature: Admin UI — Configurable SSO Redirect Schemes
  As an instance admin
  I want to manage additional trusted SSO redirect URL schemes via the Admin UI
  So that I can allowlist custom/private Matrix clients without a code change or redeploy

  # Story: configurable-sso-redirect-schemes/fix-and-configure-sso-redirect-schemes
  # AC13 — Godog/BDD scenarios (this project's BDD runner is playwright-bdd, not Godog;
  # see e2e/playwright.config.ts and e2e/step-definitions/ conventions).
  #
  # Runner: playwright-bdd (Cucumber-based Playwright runner)
  # Step definitions: e2e/step-definitions/admin/sso-schemes.steps.ts
  #
  # AC coverage:
  #   AC8 — Admin UI form field renders at /admin/config
  #   AC9 — POST /admin/config/sso-schemes persists valid input, flashes success
  #   AC5/AC9 — Denylisted scheme submission is rejected, flashes error, not persisted

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed

  @ac8-ac9-sso-schemes-save
  Scenario: Admin configures custom SSO redirect schemes
    Given an admin is logged into the Admin UI
    When the admin navigates to "/admin/config"
    Then the page shows the "Additional SSO redirect schemes" field
    When the admin enters "myorg-matrix, custom-app" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    Then the page shows a success flash message
    When the admin navigates to "/admin/config"
    Then the "Additional SSO redirect schemes" field shows "myorg-matrix, custom-app"

  @ac5-ac9-sso-schemes-denylist-rejected
  Scenario: Admin cannot allowlist a blocked scheme
    Given an admin is logged into the Admin UI
    When the admin navigates to "/admin/config"
    And the admin enters "javascript" in the "Additional SSO redirect schemes" field
    And the admin saves the SSO schemes form
    Then the page shows an error flash message containing "blocked"
    When the admin navigates to "/admin/config"
    Then the "Additional SSO redirect schemes" field does not show "javascript"
