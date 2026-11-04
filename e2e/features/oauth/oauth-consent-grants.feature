@oauth-consent-grants
Feature: Remembered OAuth consent
  As a Nebu user who has already allowed an app
  I want Nebu to remember my decision for that app
  So that I am not asked again on every new login, and I can take the permission back on my account page

  # Story: oauth-session-and-consent / persistent-consent-grants (REQ-2026-003; the scenario tags below use the numbering of the story). The server side (the
  # skip rule, scope / redirect URI / client binding, prompt=consent, revocation, GDPR erasure, the code binding) is proven by the ExUnit suites
  # server/test/nebu/oauth/consent_grant_*_test.exs; these scenarios cover what only a browser shows: the consent screen appearing or NOT appearing, and the list of
  # allowed apps with its withdraw button on the OAuth account page (/account/apps).
  # Runs only against the full compose stack with the real Dex (NOT executable in the isolated environment: verified with `bddgen --tags "@oauth-consent-grants"` +
  # `tsc --noEmit`). Framework: playwright-bdd (admin-ui project). Step definitions: e2e/step-definitions/oauth/oauth-consent-grants.steps.ts; reused (never
  # redefined): "OAuth is enabled with an https issuer", "an approved web client {string} named {string} with client URI {string} and redirect URI {string}", "the browser
  # opens the authorize URL of {string} with response_mode {string} and device {string}", "the user signs in at the IdP", "the consent page is shown", "the user allows
  # the app", "the client receives the redirect at {string}", "the redirect query has a {string}", "the redirect query has the request's {string}" (oauth-authorize.steps.ts),
  # "the account page shows the notice {string}", "the page has exactly one level-1 heading", "the page has no detectable accessibility violations", "the page does not
  # scroll horizontally at a 320 px viewport" (oauth-account-management.steps.ts).
  #
  # The grant is keyed by the Matrix user id of the Dex test user and the client; every scenario starts without one (Before hook) and the After hook removes the grants,
  # the sessions and the clients of the `e2e-oauth-grants-` prefix and switches OAuth off again.

  Background:
    Given OAuth is enabled with an https issuer
    And an approved web client "e2e-oauth-grants-web" named "Grant Test App" with client URI "https://app.e2e.example" and redirect URI "https://app.e2e.example/cb"

  @oauth-consent-grants @scenario-1
  Scenario: First login with a client asks for consent
    Given the test user has no consent grant for "e2e-oauth-grants-web"
    When the browser opens the authorize URL of "e2e-oauth-grants-web" with response_mode "query" and device "E2EGRANTD01"
    And the user signs in at the IdP
    Then the consent page is shown
    And no consent grant exists for "e2e-oauth-grants-web"

  @oauth-consent-grants @scenario-2
  Scenario: Second login with the same client skips the consent screen
    When the browser opens the authorize URL of "e2e-oauth-grants-web" with response_mode "query" and device "E2EGRANTD02"
    And the user signs in at the IdP
    And the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And a consent grant exists for "e2e-oauth-grants-web"
    When the browser starts recording the pages it loads
    And the browser opens the authorize URL of "e2e-oauth-grants-web" with response_mode "query" and device "E2EGRANTD03"
    And the user signs in at the IdP
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"
    And the redirect query has the request's "state"
    And the browser did not load the consent page since the recording started

  @oauth-consent-grants @scenario-9
  Scenario: Withdrawing the grant on the account page brings the consent screen back
    When the browser opens the authorize URL of "e2e-oauth-grants-web" with response_mode "query" and device "E2EGRANTD04"
    And the user signs in at the IdP
    And the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    When the user opens the list of allowed apps on the account page
    Then the list of allowed apps contains "Grant Test App"
    And the page title and heading read "Apps you have allowed"
    And the navigation marks "Apps" as the current page
    And the Withdraw button of "Grant Test App" is found by its accessible name
    And the explanation says that signed-in devices stay signed in and links to Devices
    And the page has exactly one level-1 heading
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user withdraws "Grant Test App" from the list of allowed apps
    Then the account page shows the notice "grant_withdrawn"
    And the notice is announced as a status
    And the list of allowed apps does not contain "Grant Test App"
    And the empty state says "There are no allowed apps on your account. An app appears here after you allow it when you sign in."
    And the navigation marks "Apps" as the current page
    And the page has exactly one level-1 heading
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    And no consent grant exists for "e2e-oauth-grants-web"
    When the browser opens the authorize URL of "e2e-oauth-grants-web" with response_mode "query" and device "E2EGRANTD05"
    And the user signs in at the IdP
    Then the consent page is shown
