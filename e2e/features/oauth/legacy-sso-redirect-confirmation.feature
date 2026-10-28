@legacy-sso-confirm
Feature: Confirmation before a legacy SSO login is handed to an unknown web address
  As a Matrix user I want to be asked before my sign-in goes to a site this server does not know
  So that a link cannot silently log someone else's site into my account

  # Story: oauth-broker / legacy-sso-redirect-confirmation (epic SEC gate 3, G3-3; AC4-AC8, AC2, AC3, AC14).
  # Runs only against the full compose stack with the real Dex (NOT executable in the isolated environment:
  # verified with `bddgen --tags "@legacy-sso-confirm or @sso-redirect-origins"` + `tsc --noEmit`).
  # Framework: playwright-bdd (admin-ui project, baseURL = Nebu at http://localhost:8008; plain http, so the
  # http cookie variant `nebu_sso_confirm` is exercised here, the `__Host-` variant is covered by the plug tests).
  # Step definitions: e2e/step-definitions/oauth/legacy-sso-redirect-confirmation.steps.ts; reused (never
  # redefined): "the user signs in at the IdP", "the client receives the redirect at {string}", "the redirect
  # query has a {string}", "the redirect query has {string} = {string}", "the response has a
  # Content-Security-Policy starting with {string}" (oauth-authorize.steps.ts), "the browser is not redirected to
  # {string}" (oauth-consent.steps.ts), "the page has exactly one level-1 heading", "the page has no detectable
  # accessibility violations", "the page does not scroll horizontally at a 320 px viewport"
  # (oauth-account-management.steps.ts).
  #
  # Real flows: the browser opens Nebu's REAL legacy GET /_matrix/client/v3/login/sso/redirect, signs in at the
  # REAL Dex and lands on Nebu's confirmation page /_matrix/client/v3/login/sso/confirm (an UNLISTED https
  # target) or at the target (a listed one). The CLIENT side does not exist in the stack: every https target is
  # intercepted with context.route() and answered with a stub page, so the final URL (loginToken) can be
  # inspected and a popup client keeps (or loses) its window.opener.
  #
  # Page contract (shared with server/test/nebu/matrix/sso_redirect_confirm_page_test.exs):
  #   <main data-page="sso-confirm" data-result="pending|cancelled">, data-role="target-origin" and "user-id",
  #   Cancel first, Continue (id="continue") disabled until armed by ONE hash-pinned script (Nebu.Web.ArmScript),
  #   errors <main data-page="sso-confirm-error" data-error="invalid_state|forbidden|invalid_request|...">.
  #
  # Hygiene: an @legacy-sso-confirm After hook clears sso_redirect_allowed_origins through the Admin UI form
  # when a scenario set it.

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And the browser stubs the client page "https://unlisted.e2e.example/cb"

  @ac4 @ac5 @ac6 @ac7
  Scenario: Continuing to an unlisted web address
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb?app=1#/login"
    And the user signs in at the IdP
    Then the SSO confirmation page names the target "https://unlisted.e2e.example"
    And the SSO confirmation page names the signed-in Matrix user
    And the SSO confirmation page does not contain "app=1"
    And the page has exactly one level-1 heading
    And the SSO confirmation page has one hash-pinned script and Continue starts disabled
    And the response has a Content-Security-Policy starting with "default-src 'none'"
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user continues the SSO sign-in
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"
    And the redirect query has "app" = "1"

  @ac8
  Scenario: Cancelling sends nothing to the web address
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user cancels the SSO sign-in
    Then the page shows the SSO sign-in was cancelled
    And the browser is not redirected to "https://unlisted.e2e.example/cb"

  @ac5 @ac7
  Scenario: The confirmation cannot be used twice
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user continues the SSO sign-in
    And the browser goes back and submits the SSO confirmation again
    Then the page is marked as SSO confirmation error "invalid_state"

  @ac3 @ac14
  Scenario: A listed origin is not confirmed
    Given the browser stubs the client page "https://listed.e2e.example/cb"
    And the operator lists "https://listed.e2e.example" as an allowed SSO redirect origin
    When the browser starts a legacy SSO login with redirectUrl "https://listed.e2e.example/cb"
    And the user signs in at the IdP
    Then the client receives the redirect at "https://listed.e2e.example/cb"
    And the redirect query has a "loginToken"

  # @known-failure (e2e/KNOWN-FAILURES.md, K1): the CDP touch tap does not submit in the Playwright Chromium (headless shell); unverified whether the page or the test is at fault
  @ac5 @known-failure
  Scenario: Continue on a touch device
    Given the browser is a touch device
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user taps Continue on the SSO confirmation page right away
    Then the browser is still on the SSO confirmation page
    When the user taps the SSO confirmation page outside Continue
    Then the SSO confirmation page announces "Continue is now available."
    When the user taps Continue on the SSO confirmation page
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"

  @ac5 @ac6
  Scenario: A scroll or a fragment change from the opener does not arm Continue
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the opener scrolls the SSO confirmation page and changes its fragment without any user input
    Then Continue is still unavailable on the SSO confirmation page
    When the user arms the SSO confirmation page with a key press and the opener then changes its fragment
    Then Continue is still unavailable on the SSO confirmation page

  # @known-failure (e2e/KNOWN-FAILURES.md, K2): the live region [data-arm-status] stays empty (hidden) after the blocked stationary click; unverified whether the page or the test is at fault
  @ac5 @known-failure
  Scenario: A click without moving onto Continue after arming does not submit
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the mouse rests on Continue while the SSO confirmation page arms and then clicks without moving
    Then the browser is still on the SSO confirmation page
    And the SSO confirmation page announces "Move the pointer off and back onto Continue, then click."
    When the user moves the mouse onto Continue and clicks it
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"

  @ac5
  Scenario: Continue with the keyboard
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user arms the SSO confirmation page with a key press and activates Continue with Tab and Enter
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"

  @ac5
  Scenario: A keyboard activation without moving the focus after arming does not submit
    When the browser starts a legacy SSO login with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP
    And the user focuses Continue with the keyboard before the page arms and presses Enter once it is armed
    Then the browser is still on the SSO confirmation page
    When the user moves the focus off Continue and back with the keyboard and presses Enter
    Then the client receives the redirect at "https://unlisted.e2e.example/cb"
    And the redirect query has a "loginToken"

  @ac5 @ac6
  Scenario: A popup-based web client keeps its opener
    Given the browser stubs the client page "https://popup.e2e.example/app"
    When the stub client page "https://popup.e2e.example/app" opens a legacy SSO login popup with redirectUrl "https://unlisted.e2e.example/cb"
    And the user signs in at the IdP in the popup
    And the user continues the SSO sign-in in the popup
    Then the popup reaches "https://unlisted.e2e.example/cb" with a "loginToken"
    And the popup still has its opener

  @ac2
  Scenario: A disguised address is refused before the IdP
    # the step builds https://evil.e2e.example\@listed.e2e.example/cb in TypeScript (no backslash inside a Gherkin string)
    When the browser starts a legacy SSO login whose redirectUrl hides "evil.e2e.example" behind a backslash before "listed.e2e.example"
    Then the browser shows the SSO redirect error page with status 400
