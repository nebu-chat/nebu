Feature: Rename a device in the account portal

  @REQ-2026-021 @ac-a-fresh-user-renames-a-device
  Scenario: A fresh user renames a device
    Given a user signed in to the portal within the last 5 minutes with a device named "OAuth client (CdEfGhIj)"
    When the user opens Rename on that device, enters "Annas Handy" and saves
    Then the device list shows "Annas Handy" with the notice "device_renamed", and Matrix GET /devices and the admin user page show the same name

  @REQ-2026-021 @ac-a-stale-session-must-confirm-first-and-nothing-changes
  Scenario: A stale session must confirm first and nothing changes
    Given a user whose portal sign-in is older than 5 minutes
    When the user submits a rename
    Then the response is a 303 with notice "stale" and the "Confirm it is you" link, and the device name is unchanged

  @REQ-2026-021 @ac-another-user-s-device-cannot-be-renamed
  Scenario: Another user's device cannot be renamed
    Given a device id that belongs to another user, or does not exist
    When the portal user submits a rename for it
    Then the notice "device_not_found" is shown and no device of any user is changed

  @REQ-2026-021 @ac-a-hostile-or-empty-name-is-sanitised-or-refused
  Scenario: A hostile or empty name is sanitised or refused
    Given the rename form of a device
    When the user submits "<b>Work\u0007 laptop</b>", then a name of only invisible characters, then a 500 character name
    Then the names are stored as "Work laptop" and cut to 64 code points respectively, the invisible-only name is refused with "device_name_invalid" and the old name stays

  @REQ-2026-021 @ac-the-rename-page-is-accessible-and-works-in-both-languages
  Scenario: The rename page is accessible and works in both languages
    Given the rename page in German and in English at 390 px and without JavaScript
    When it is rendered
    Then it has one main and one h1, a label tied to the field, a visible focus ring, 44 px controls, Cancel next to Save, and every text comes from the catalog
