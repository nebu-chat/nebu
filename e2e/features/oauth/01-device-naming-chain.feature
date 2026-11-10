@oauth-device-naming-chain
Feature: Every OAuth device gets a clean, recognisable name

  # Story: oauth-pages-redesign / 01-device-naming-chain (REQ-2026-016). The name rules (generic-name list, host derivation, sanitising table, the typed-name
  # field, the remembered-Allow rule) are proven by server/test/nebu/oauth/device_naming_chain_test.exs; these scenarios cover what only a browser shows: the
  # Allow page naming the device (or asking for a name) and the device created with that name. A `\uXXXX` in a typed name stands for that character.
  # Runs only against the full compose stack with the real Dex (NOT executable in the isolated environment). Step definitions:
  # e2e/step-definitions/oauth/oauth-device-naming-chain.steps.ts; everything else is reused from oauth-authorize.steps.ts and oauth-consent-grants.steps.ts.
  # The device ids end in 8 distinct characters, so the expected suffix is known (the last 8 characters of the device id).

  Background:
    Given OAuth is enabled with an https issuer

  @REQ-2026-016 @ac-a-usable-client-name-is-shown-on-the-allow-page-and-given-to-the
  Scenario: A usable client name is shown on the Allow page and given to the device
    Given an approved web client "e2e-oauth-devname-fluffy" named "FluffyChat" with client URI "https://fluffy.e2e.example" and redirect URI "https://fluffy.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-devname-fluffy" with response_mode "query" and device "E2ENAMEDEV1"
    And the user signs in at the IdP
    Then the consent page is shown
    And the consent page shows the device name "FluffyChat (NAMEDEV1)"
    And the consent page does not ask for a device name
    When the user allows the app
    Then the client receives the redirect at "https://fluffy.e2e.example/cb"
    When the client exchanges the code
    Then the device "E2ENAMEDEV1" has the display name "FluffyChat (NAMEDEV1)"

  @REQ-2026-016 @ac-without-a-usable-client-name-the-website-host-names-the-device
  Scenario: Without a usable client name the website host names the device
    Given an approved web client "e2e-oauth-devname-host" named "App" with client URI "https://chat.acme.example/web" and redirect URI "https://chat.acme.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-devname-host" with response_mode "query" and device "E2ENAMEDEV2"
    And the user signs in at the IdP
    Then the consent page is shown
    And the consent page shows the device name "chat.acme.example (NAMEDEV2)"
    And the consent page does not ask for a device name
    When the user allows the app
    Then the client receives the redirect at "https://chat.acme.example/cb"
    When the client exchanges the code
    Then the device "E2ENAMEDEV2" has the display name "chat.acme.example (NAMEDEV2)"

  @REQ-2026-016 @ac-when-nothing-usable-exists-the-user-is-asked-for-a-name
  Scenario: When nothing usable exists the user is asked for a name
    Given an approved web client "e2e-oauth-devname-ask" named "App" with client URI "http://nohost.e2e.example" and redirect URI "https://nohost.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-devname-ask" with response_mode "query" and device "E2ENAMEDEV3"
    And the user signs in at the IdP
    Then the consent page is shown
    And the consent page asks for a device name
    When the user presses Allow with the device name ""
    Then the consent page is shown again asking for a device name
    And the device "E2ENAMEDEV3" does not exist
    When the user types the device name "Anna's phone"
    And the user allows the app
    Then the client receives the redirect at "https://nohost.e2e.example/cb"
    When the client exchanges the code
    Then the device "E2ENAMEDEV3" has the display name "Anna's phone"

  @REQ-2026-016 @ac-a-remembered-allow-does-not-skip-the-question-when-a-new-device-has
  Scenario: A remembered Allow does not skip the question when a new device has no name
    Given an approved web client "e2e-oauth-devname-remember" named "App" with client URI "http://nohost.e2e.example" and redirect URI "https://nohost.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-devname-remember" with response_mode "query" and device "E2ENAMEDEV4"
    And the user signs in at the IdP
    Then the consent page asks for a device name
    When the user types the device name "Anna's phone"
    And the user allows the app
    Then the client receives the redirect at "https://nohost.e2e.example/cb"
    And a consent grant exists for "e2e-oauth-devname-remember"
    When the client exchanges the code
    And the browser opens the authorize URL of "e2e-oauth-devname-remember" with response_mode "query" and device "E2ENAMEDEV5"
    And the user signs in at the IdP
    Then the consent page is shown
    And the consent page asks for a device name
    When the browser starts recording the pages it loads
    And the browser opens the authorize URL of "e2e-oauth-devname-remember" with response_mode "query" and device "E2ENAMEDEV4"
    And the user signs in at the IdP
    Then the client receives the redirect at "https://nohost.e2e.example/cb"
    And the browser did not load the consent page since the recording started

  @REQ-2026-016 @ac-a-typed-name-is-sanitised-and-a-name-of-only-invisible-characters
  Scenario: A typed name is sanitised and a name of only invisible characters counts as empty
    Given an approved web client "e2e-oauth-devname-typed" named "App" with client URI "http://nohost.e2e.example" and redirect URI "https://nohost.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-devname-typed" with response_mode "query" and device "E2ENAMEDEV6"
    And the user signs in at the IdP
    Then the consent page asks for a device name
    When the user presses Allow with the device name "ㅤ⠀"
    Then the consent page is shown again asking for a device name
    And the device "E2ENAMEDEV6" does not exist
    When the user types the device name "<b>Work\u0007 laptop</b>"
    And the user allows the app
    Then the client receives the redirect at "https://nohost.e2e.example/cb"
    When the client exchanges the code
    Then the device "E2ENAMEDEV6" has the display name "Work laptop"
