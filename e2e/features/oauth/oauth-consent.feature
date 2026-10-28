Feature: OAuth consent screen
  As a Matrix user I want to decide myself which app gets my account
  So that no link and no silent sign-in hands my account or a device to an app

  # Story: oauth-broker / oauth-authorize-freshness (P3, FR1-FR12, AC1, AC3-AC6, AC8, AC9, FR21):
  # runs only against the full compose stack with the real Dex
  # (NOT executable in the isolated environment: verified with `bddgen --tags "@oauth-consent"` +
  # `tsc --noEmit`).
  # Framework: playwright-bdd (admin-ui project, baseURL = Nebu at http://localhost:8008).
  # Step definitions: e2e/step-definitions/oauth/oauth-consent.steps.ts (page assertions, the legacy
  # device) and oauth-authorize.steps.ts (the authorize / client side, Allow / Deny, the redirect checks);
  # the token and device checks of oauth-account-management.steps.ts are reused.
  #
  # Real flows: the browser opens Nebu's REAL GET /oauth2/authorize, signs in at the REAL Dex and lands
  # on Nebu's consent page /oauth2/consent. The CLIENT side does not exist in the stack: the client
  # redirect URI (https://app.e2e.example/cb) is intercepted with page.route() and answered with a stub
  # page, so the final URL (code / error, state, iss) can be inspected.
  #
  # Page contract (shared with server/test/nebu/oauth/oauth_consent_page_test.exs):
  #   <main data-page="oauth-consent" data-device="new|same_client|replace" data-fresh="true|false">, one <h1>,
  #   a <dl>, two submit buttons name="decision" value="deny|allow" (Deny first, Allow aria-disabled="true" until armed by
  #   real interaction: ONE hash-pinned inline script, the shared Nebu.Web.ArmScript, no other script; never the
  #   `disabled` attribute), CSP form-action 'self' <target>.
  #   Arming (story consent-arming-hardening, G3-5): after arming, a mouse click on Allow is accepted only after a real
  #   pointer move onto Allow, a keyboard Enter only after the focus moved onto Allow, a tap once armed; a blocked
  #   activation is announced in the polite live region [data-arm-status].
  #   Errors: <main data-page="oauth-error" data-error="<code>"> (device_in_use, invalid_state, ...).
  #
  # Hygiene: an @oauth-consent After hook resets oauth_enabled to 'false', restores the prior
  # oauth_issuer_url and deletes the e2e-oauth-consent-* clients, their sessions, consent rows and the
  # legacy device of the test user.

  Background:
    Given OAuth is enabled with an https issuer
    And an approved web client "e2e-oauth-consent-web" named "Consent Test App" with client URI "https://app.e2e.example" and redirect URI "https://app.e2e.example/cb"

  @oauth-consent @ac1 @ac3 @ac5
  Scenario: Allowing the app ends at the client with a code
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSNEW1"
    And the user signs in at the IdP
    Then the consent page names the app "Consent Test App" as claimed by the app
    And the consent page names the website "app.e2e.example"
    And the consent page says a new session "E2ECONSNEW1" will be created
    And the page has exactly one level-1 heading
    And the consent page has one hash-pinned script and Allow starts unavailable
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-consent @ac6
  Scenario: Denying the app sends access_denied and no code
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "fragment" and device "E2ECONSNEW2"
    And the user signs in at the IdP
    And the user denies the app
    Then the redirect fragment has "error" = "access_denied"
    And the redirect fragment has the request's "state"
    And the redirect fragment has no "code"

  @oauth-consent @ac9
  Scenario: Replacing a legacy session is announced and signs that session out
    Given the test user has a legacy session on device "E2ECONSLEG1"
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSLEG1"
    And the user signs in at the IdP
    Then the consent page says the existing session "E2ECONSLEG1" will be replaced and signed out
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    When the user allows the app
    And the client exchanges the code
    Then the legacy access token of device "E2ECONSLEG1" is rejected

  @oauth-consent @ac9
  Scenario: A device used by another app cannot be taken over
    Given an approved native client "e2e-oauth-consent-other" with redirect URI "http://localhost/cb"
    And the test user has an OAuth session on device "E2ECONSOTH1" through "e2e-oauth-consent-other"
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSOTH1"
    And the user signs in at the IdP
    Then the page is marked as OAuth error "device_in_use"
    And the page has exactly one level-1 heading
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport
    And the browser is not redirected to "https://app.e2e.example/cb"
    And the access token of device "E2ECONSOTH1" still works

  @oauth-consent @ac4 @ac8
  Scenario: The consent page cannot be framed, survives a reload and is single use
    Given the consent page for "e2e-oauth-consent-web" is shown
    Then the response has the header "x-frame-options" = "DENY"
    And the response has a Content-Security-Policy containing "frame-ancestors 'none'"
    And the response has a Content-Security-Policy containing "script-src 'sha256-"
    And the response has the header "cross-origin-opener-policy" = "same-origin"
    When the browser reloads the page
    Then the consent page is shown
    When the user allows the app
    And the same consent form is posted again
    Then the page is marked as OAuth error "invalid_state"

  # The freshness notice depends on what the REAL IdP reports (Dex reportedly omits auth_time: gate y). The
  # scenario asserts the invariant that holds either way (the notice is shown EXACTLY when the page is marked
  # data-fresh="false") and runs the accessibility checks on whichever variant the IdP produced; it records
  # the observed variant as a "gate-y" annotation (Manual verification 1).
  @oauth-consent @ac3 @ac11
  Scenario: The sign-in notice is shown exactly when the IdP did not confirm the sign-in, and is accessible
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSNEW3"
    And the user signs in at the IdP
    Then the freshness notice is shown exactly when the consent page is marked as not fresh
    And the page has exactly one level-1 heading
    And the page has no detectable accessibility violations
    And the page does not scroll horizontally at a 320 px viewport

  @oauth-consent @ac3 @keyboard
  Scenario: The consent decision can be made with the keyboard only and nothing is focused on load
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSKEY1"
    And the user signs in at the IdP
    Then no element of the consent page has keyboard focus
    When the user chooses Allow with the keyboard only
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"

  # Story consent-arming-hardening (G3-5, AC6c): the focus is on Allow BEFORE the page arms (a programmatic focus does
  # not arm), a key press arms it, Enter does not submit and the live region says why; the focus then moves off and
  # back onto Allow and Enter submits.
  @oauth-consent @g3-5 @keyboard
  Scenario: Enter on Allow does not decide when the focus was already on Allow before arming
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSKEY2"
    And the user signs in at the IdP
    And the user focuses Allow on the consent page before it arms and presses Enter once it is armed
    Then the consent page announces "Move the focus off and back onto Allow, then press Enter."
    And the browser is still on the consent page
    And the browser is not redirected to "https://app.e2e.example/cb"
    When the user moves the focus off Allow and back on the consent page and presses Enter
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"

  # Kassandra INFO #2 (G3-5): a consent URL that ends in #allow (handed over by a lure) focuses Allow on a fresh load;
  # that inherited focus must not count as "focus moved onto Allow after arming".
  @oauth-consent @g3-5 @keyboard
  Scenario: An inherited #allow fragment cannot activate Allow
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSKEY3"
    And the user signs in at the IdP
    And the consent page is loaded again with the inherited fragment "#allow", a key press arms it and Enter is pressed
    Then the consent page announces "Move the focus off and back onto Allow, then press Enter."
    And the browser is still on the consent page
    And the browser is not redirected to "https://app.e2e.example/cb"

  # AC6b, the G3-5 regression: a lure that makes the victim move the pointer and wait, then asks for a second click at
  # the Allow position, arms the page while the pointer is already parked over Allow. The click must not decide.
  @oauth-consent @g3-5
  Scenario: A click on Allow without moving onto it after arming does not decide
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSPTR1"
    And the user signs in at the IdP
    And the mouse rests on the armed position of Allow while the consent page arms and then clicks without moving
    Then the consent page announces "Move the pointer off and back onto Allow, then click."
    And the browser is still on the consent page
    And the browser is not redirected to "https://app.e2e.example/cb"
    When the user allows the app
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"

  # AC6d: touch has no hover; the arming touch has to land elsewhere than on Allow.
  # @known-failure (e2e/KNOWN-FAILURES.md, K1): the CDP touch tap does not submit in the Playwright Chromium (headless shell); unverified whether the page or the test is at fault
  @oauth-consent @g3-5 @touch @known-failure
  Scenario: Allow on a touch device
    Given the browser emulates a touch device for the consent page
    When the browser opens the authorize URL of "e2e-oauth-consent-web" with response_mode "query" and device "E2ECONSTCH1"
    And the user signs in at the IdP
    And the user taps Allow on the consent page right away
    Then the consent page announces "Allow is not available yet."
    And the browser is still on the consent page
    When the user taps the consent page outside Allow
    Then the consent page announces "Allow is now available."
    When the user taps Allow on the consent page
    Then the client receives the redirect at "https://app.e2e.example/cb"
    And the redirect query has a "code"
