@media-config-damaged
Feature: Admin UI — a damaged stored media setting is shown on the media settings page
  As an instance admin
  I want a damaged stored media setting to be named on the media settings page
  So that the other settings keep their values and a paused media cleanup is not invisible

  # Story: oauth-broker / media-config-tolerant-loader (AC7, AC8; follow-up ej): a media_config row that cannot be read (here deleted_days = 'abc', the
  # result of a wrong break-glass UPDATE) affects only itself: the form shows the default, the page carries ONE text warning (role="status",
  # data-testid="media-config-damaged") that names the key and says that the media cleanup is paused, and a plain save of the form repairs the row.
  # Runner: playwright-bdd (admin-ui project). Steps: e2e/step-definitions/admin/media-config-damaged.steps.ts; reused: "the Nebu stack is running",
  # "bootstrap has been completed", "the operator is logged in as admin", "the operator saves the media settings form" and "the media settings field
  # {string} shows {string}" (media-settings-gate.steps.ts, the save goes through the fresh sign-in), "the page shows {string}".
  # The direct SQL write sends no cache invalidation: the server serves media_config from a per-node cache (TTL 60 s), the step reloads the page until
  # the warning appears (at most 75 s). Hygiene: the After hook puts the original row back (or removes it).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac7-warning-and-repair
  Scenario: A damaged deleted_days row is named on the page, shows the default, and a plain save repairs it
    Given the media setting "deleted_days" is stored as "abc"
    When the operator opens the media settings page until the damaged settings warning appears
    Then the damaged settings warning names "deleted_days"
    And the damaged settings warning says "paused"
    And the media settings field "deleted_days" shows "30"
    When the operator saves the media settings form
    Then the page shows "Media settings saved"
    And the damaged settings warning is gone
    And the media settings field "deleted_days" shows "30"
