@session-lifetime
Feature: Admin UI — configurable Matrix session lifetime
  As an instance admin
  I want to set how long a signed-in Matrix session lasts on the Configuration page
  So that I can balance security against users being logged out after a fixed 8 hours

  # Story: oauth-session-and-consent / session-lifetime-setting (the scenario tags below use the numbering of the story): the section `#session-lifetime` with
  # the form `#session-lifetime-form` (POST /admin/config/session-lifetime) on /admin/config. The server side of the story (the ceiling `session_expires_at` that
  # a login stamps, existing sessions keeping theirs, the cache) is proven by the ExUnit suites server/test/nebu/{web/session_config_lifetime,admin/config_session_lifetime*,
  # oauth/session_lifetime_*}_test.exs; these scenarios cover what only a browser shows: the sign-in link instead of the Save button, the validation error next
  # to the field, the saved value on the page and the audit entry.
  # Runner: playwright-bdd (admin-ui project). Step definitions: e2e/step-definitions/admin/session-lifetime.steps.ts; reused (never redefined): "the Nebu stack is
  # running", "bootstrap is already completed", "an admin is logged into the Admin UI", "the admin navigates to {string}".
  #
  # NOT a @short-ttl scenario: it belongs to the default admin-ui run and never to `make test-e2e-refresh` (NEBU_E2E_TAGS='@short-ttl'), which runs against a stack
  # with a SHORT NEBU_MATRIX_SESSION_TTL_SECONDS. Hygiene: a Before / After hook pair remembers the `matrix_session_ttl_seconds` row (or its absence) in the database
  # and puts it back by SQL, so that no saved row ever overrides the environment value of a reused database.
  #
  # Saving needs a FRESH admin sign-in (strict fetch metadata + a re-authentication marker bound to /admin/config, single use, kept after a validation error):
  # the link "Sign in again to save" comes first (story admin-reauth-button-flow), then the value is typed and the submit "Save session lifetime" pressed.

  Background:
    Given the Nebu stack is running
    And bootstrap is already completed
    And an admin is logged into the Admin UI

  @scenario-5 @reauth-button
  Scenario: Without a fresh sign-in the form shows a Sign in again link, after signing in the Save button appears
    When the admin navigates to "/admin/config"
    Then the session lifetime form shows the "Sign in again to save" link and no "Save session lifetime" button
    When the admin follows the "Sign in again to save" link of the session lifetime form and signs in again
    Then the session lifetime form shows the "Save session lifetime" button and no "Sign in again to save" link

  @scenario-2 @scenario-6
  Scenario: A saved lifetime is shown as text, stays after reloading the page and is written to the audit log
    When the admin navigates to "/admin/config"
    And the admin remembers the session lifetime
    And the admin enters the session lifetime "7200" seconds
    And the admin saves the session lifetime
    Then the page shows a session lifetime saved flash message
    And the session lifetime shows "2 hours"
    And the stored session lifetime is "7200"
    And the audit log has a session lifetime entry from the remembered number to 7200
    When the admin navigates to "/admin/config"
    Then the session lifetime field shows "7200"
    And the session lifetime shows "2 hours"
    And the session lifetime form says that OAuth sessions keep the lifetime they started with

  @scenario-3
  Scenario: A lifetime above 90 days is refused with an error next to the field and nothing is saved
    When the admin navigates to "/admin/config"
    And the admin remembers the session lifetime
    And the admin enters the session lifetime "8640000" seconds
    And the admin saves the session lifetime
    Then the session lifetime field shows the error "7776000" and is marked invalid
    And the stored session lifetime is unchanged
    When the admin navigates to "/admin/config"
    Then the session lifetime field shows the remembered value
