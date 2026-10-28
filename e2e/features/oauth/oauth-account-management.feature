Feature: OAuth account management page
  As a user of an OAuth-capable Matrix client
  I want to manage my devices and approve an identity reset on a Nebu web page
  So that I keep control of my account although my client cannot do interactive auth

  # Story: oauth-broker / oauth-account-management. Real Dex, real Nebu; the OAuth client is played by
  # the step file (authorize + token through APIRequestContext, PKCE, approved fixture client inserted
  # via fixtures/db.ts insertOAuthClient). Hygiene After hook (@oauth-account): oauth_enabled back to
  # 'false', prior oauth_issuer_url restored, e2e-oauth-acct-* clients, their sessions/devices and the
  # account sessions of the test user deleted through the privileged role.
  # Page contract (shared with oauth_account_pages_test.exs): <main data-page="account" data-action=...>,
  # one <h1>, no <script>, CSP default-src 'none'.
  #
  # Story oauth-authorize-freshness (P3): the Background's OAuth session now goes through the consent
  # screen (the step file's client follows the 303 and clicks Allow). Gate y is fail closed: an IdP that
  # reports no auth_time gives an account session with auth_time NULL, on which signing out devices and
  # approving key resets are UNAVAILABLE (notice freshness_unavailable, no reauth link, no form). The
  # scenarios that need a FRESH session start with "Given the IdP reports the sign-in time" (they are
  # skipped with a `gate-y` annotation when the real Dex sends no auth_time); @ac2-freshness asserts
  # "fresh, or absent with the destructive actions unavailable", never absent-but-fresh.

  Background:
    Given OAuth is enabled with an https issuer
    And an approved native client "e2e-oauth-acct-native" with redirect URI "http://localhost/cb"
    And the test user has an OAuth session on device "E2EACCTDEV1" through "e2e-oauth-acct-native"

  @oauth-account @ac2 @ac6
  Scenario: Signing in shows the device list
    When the browser opens the account page with action "org.matrix.devices_list"
    And the user signs in at the IdP
    Then the account page shows the action "org.matrix.devices_list"
    And the device list contains "E2EACCTDEV1" with the app "e2e-oauth-acct-native"
    And the page has exactly one level-1 heading
    And the page contains no script element
    And the page has no detectable accessibility violations

  @oauth-account @ac7
  Scenario: The device page is the sign-out entry point
    Given the IdP reports the sign-in time
    And the test user has an OAuth session on device "E2EACCTDEV3" through "e2e-oauth-acct-native"
    When the browser opens the account page with action "org.matrix.device_view" for device "E2EACCTDEV3"
    And the user signs in at the IdP
    And the user follows the sign-out control of the device page
    And the user confirms signing out the device
    Then the account page shows the notice "device_deleted"
    And the access token of device "E2EACCTDEV3" is rejected

  @oauth-account @ac7
  Scenario: A legacy-only user signs out a legacy device
    Given the IdP reports the sign-in time
    And the legacy test user has a legacy session on device "E2EACCTLEG1" and no OAuth session
    When the browser opens the account page with action "org.matrix.devices_list"
    And the legacy test user signs in at the IdP
    Then the device list contains "E2EACCTLEG1"
    When the user signs out device "E2EACCTLEG1" from the list and confirms
    Then the access token of device "E2EACCTLEG1" is rejected

  @oauth-account @ac2 @ac2-freshness
  Scenario: Re-authentication at the real IdP is observed for freshness (gate y)
    Given the user is signed in on the account page
    When the browser opens the re-authentication link
    Then the IdP re-authentication outcome is recorded as gate (y) evidence
    And the account session's auth_time is fresh, or absent with the destructive actions unavailable

  @oauth-account @ac7
  Scenario: Deep link signs out a device after confirmation
    Given the IdP reports the sign-in time
    And the test user has an OAuth session on device "E2EACCTDEV2" through "e2e-oauth-acct-native"
    When the browser opens the account page with action "org.matrix.device_delete" for device "E2EACCTDEV2"
    And the user signs in at the IdP
    Then the confirmation for signing out "E2EACCTDEV2" is shown
    And the page has no detectable accessibility violations
    When the user confirms signing out the device
    Then the account page shows the notice "device_deleted"
    And the device list does not contain "E2EACCTDEV2"
    And the access token of device "E2EACCTDEV2" is rejected
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac8 @ac9
  Scenario: Resetting cross-signing keys needs an approval on the account page
    Given the IdP reports the sign-in time
    And the client of device "E2EACCTDEV1" has uploaded cross-signing keys
    When the client of device "E2EACCTDEV1" uploads different cross-signing keys
    Then the client receives an m.oauth challenge pointing at the account page
    When the browser opens the challenge URL
    And the user signs in at the IdP
    Then a pending reset request from device "E2EACCTDEV1" is shown
    And the page has no detectable accessibility violations
    When the user approves the reset request
    Then the account page shows the notice "reset_approved"
    When the client retries the upload with the challenge session
    Then the upload succeeds
    And the client's cross-signing master key is the new key
    When the client retries the same upload again
    Then the upload succeeds without a challenge

  @oauth-account @ac9
  Scenario: Declining a reset request keeps the old keys
    Given the IdP reports the sign-in time
    And the client of device "E2EACCTDEV1" has uploaded cross-signing keys
    And the client of device "E2EACCTDEV1" received an m.oauth challenge for different keys
    When the browser opens the challenge URL
    And the user signs in at the IdP
    And the user declines the reset request
    Then the account page shows the notice "reset_declined"
    When the client retries the upload with the challenge session
    Then the client receives a new m.oauth challenge

  @oauth-account @ac4
  Scenario: A form post without the CSRF token is refused
    Given the user is signed in on the account page
    When a same-origin form without the CSRF token is posted to sign out device "E2EACCTDEV1"
    Then the account error page "forbidden" is shown
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac4
  Scenario: A cross-site form post with a valid CSRF token is refused
    Given the user is signed in on the account page
    When a form with a valid CSRF token is posted cross-site to sign out device "E2EACCTDEV1"
    Then the account error page "forbidden" is shown
    And the access token of device "E2EACCTDEV1" still works

  @oauth-account @ac3
  Scenario: Signing out of the account page
    Given the user is signed in on the account page
    When the user signs out of the account page
    Then the account page shows the signed-out message
    And opening the account page again redirects to the IdP

  @oauth-account @a11y
  Scenario Outline: The <page> page is accessible and reflows at a narrow viewport
    Given the user is signed in on the account page
    When the browser opens the account page with action "<action>" for device "E2EACCTDEV1"
    Then the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport

    Examples:
      | page                | action                           |
      | profile             | org.matrix.profile               |
      | device list         | org.matrix.devices_list          |
      | device              | org.matrix.device_view           |
      | delete confirmation | org.matrix.device_delete         |
      | reset               | org.matrix.cross_signing_reset   |

  @oauth-account @a11y
  Scenario: The signed-out page is accessible and reflows at a narrow viewport
    Given the user is signed in on the account page
    When the user signs out of the account page
    Then the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport

  @oauth-account @ac1
  Scenario: The account page is unavailable while OAuth is disabled
    Given OAuth is disabled
    When the browser opens the account page with action "org.matrix.devices_list"
    Then the account error page "unavailable" is shown with status 404
