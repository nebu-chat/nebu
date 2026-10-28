@role-mapping
Feature: Admin UI — role mapping refuses a group value the saving admin would not satisfy
  As an instance admin
  I want the Role mapping page to refuse a value that is not in my own fresh sign-in token
  So that a typo cannot lock every administrator out at the next sign-in

  # Story: oauth-broker / role-mapping-self-lockout-guard (follow-up dg, AC2 - AC4, AC7): POST /admin/config/role-mapping runs the gate
  # (strict fetch metadata + a fresh sign-in marker bound to the page) and then compares the new value with the values of the fresh
  # sign-in (a fingerprint in the marker). Static check only in the isolated CI (bddgen + tsc): the stack with the real Dex does not run there.
  #
  # Runner: playwright-bdd (admin-ui project). Step definitions: e2e/step-definitions/admin/role-mapping.steps.ts; reused (never redefined):
  # "the Nebu stack is running", "bootstrap has been completed", "the operator is logged in as admin", "the operator navigates to {string}",
  # "the operator clears the field {string}", "the operator fills in {string} with {string}", "the page shows {string}",
  # "the page shows a validation error for {string}", "the page does not show {string}".
  # Hygiene: both scenarios leave the stored value `instance_admin` (the Dex admin's group) untouched.

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the operator is logged in as admin

  @ac7-role-mapping-claim-path
  Scenario: The page shows where the value is looked up and that it must be in the token of the person who saves
    When the operator navigates to "/admin/config/role-mapping"
    Then the page shows "Role Mapping"
    And the role mapping page shows the claim path it looks the value up in
    And the page shows "token of the person who saves"

  @ac3-role-mapping-refused
  Scenario: A group the admin does not hold is refused after the fresh sign-in, nothing is saved
    When the operator navigates to "/admin/config/role-mapping"
    And the operator clears the field "admin_group_claim"
    And the operator fills in "admin_group_claim" with "no-such-group-xyz"
    And the operator saves the role mapping form
    Then the page shows a validation error for "admin_group_claim"
    And the page shows "not in your own sign-in token"
    And the page does not show "Role mapping saved."
    When the operator navigates to "/admin/config/role-mapping"
    Then the role mapping form has "admin_group_claim" pre-filled with "instance_admin"

  @ac2-role-mapping-own-group
  Scenario: The admin's own group is saved (the value stays instance_admin)
    When the operator navigates to "/admin/config/role-mapping"
    And the operator clears the field "admin_group_claim"
    And the operator fills in "admin_group_claim" with "instance_admin"
    And the operator saves the role mapping form
    Then the page shows "Role mapping saved."
    And the role mapping form has "admin_group_claim" pre-filled with "instance_admin"
