@media-settings-gate
Feature: Admin UI — the media policy save needs a fresh sign-in
  As an instance admin
  I want saving the media policy to go through a fresh sign-in at the IdP
  So that a script on the shared origin cannot shorten the retention of user media

  # Story: oauth-broker / admin-forms-gate-sweep (AC2, D2): POST /admin/media/settings is a :marker form (strict fetch metadata + a fresh sign-in bound to
  # /admin/media/settings, single use). Runner: playwright-bdd (admin-ui project). Steps: e2e/step-definitions/admin/media-settings-gate.steps.ts; reused:
  # "the Nebu stack is running", "bootstrap has been completed", "the operator is logged in as admin", "the operator navigates to {string}",
  # "the operator clears the field {string}", "the operator fills in {string} with {string}", "the page shows {string}".
  # Story admin-reauth-button-flow: the form shows the link "Sign in again to save" until the admin has signed in; the steps follow it, sign in, then type and save.
  # Hygiene: the scenario restores the value it changed (through a second fresh sign-in).

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac2-media-policy-reauth
  Scenario: Saving the media policy goes through the IdP once per save and the value is stored
    When the operator navigates to "/admin/media/settings"
    And the operator remembers the value of the field "orphaned_hours"
    And the operator clears the field "orphaned_hours"
    And the operator fills in "orphaned_hours" with "25"
    And the operator saves the media settings form
    Then the page shows "Media settings saved"
    And the media settings field "orphaned_hours" shows "25"
    When the operator restores the remembered value of the field "orphaned_hours"
    And the operator saves the media settings form
    Then the page shows "Media settings saved"
