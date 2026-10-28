@legacy-logout-per-device
Feature: Legacy sign-out ends only the signed-out device
  As a Nebu user signed in on two devices
  I want "Sign out" in one browser to end only that browser's session and device
  So that my other device keeps working and no orphaned device with stale keys stays behind

  # Bugfix legacy-logout-per-device (epic oauth-broker, gate item r; story
  # docs/stories/oauth-broker/legacy-logout-per-device.md, AC1/AC5, LL1-LL4).
  #
  # Element Web in the e2e stack signs in through the legacy SSO login (raw IdP JWT bound to a device,
  # no refresh token), so this is the bound-JWT path of the legacy POST /logout. Before the fix the
  # logout wiped EVERY session of the user (the second browser was logged out too) and kept the device
  # of the first browser. The opaque-token, OAuth-device and failure cases are covered by the ExUnit
  # suite (server/test/nebu/oauth/legacy_logout_per_device_test.exs); the OAuth-aware client check is
  # a manual verification item of the story.
  #
  # Both browsers log in through the real Authorization Code + PKCE flow via Dex (no ROPC, no cookie
  # forging, no DB seeding). The second browser context is created by the step, not by a fixture.
  # Cannot run in the isolated environment (needs the full compose stack); verified there with
  # `bddgen --tags @legacy-logout-per-device` and `tsc --noEmit` only.

  Background:
    Given the Nebu stack is running

  Scenario: Signing out in one browser leaves the second device of the same user working
    Given alex is logged in via Element Web
    And alex remembers the device of this browser
    And alex is also logged in via Element Web on a second device
    When alex opens the user menu and clicks "Sign out"
    Then the welcome screen is visible
    And the "Sign in" button is present
    And the access token of the remembered device is rejected by the server
    When alex reloads Element Web on the second device
    Then the room list is visible on the second device
    And the access token of the second device is still accepted by the server
    And the device list of the second device no longer contains the remembered device
    And the device list of the second device still contains the second device
