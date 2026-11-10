---
story_id: 06-portal-rename-device
title: "Rename a device in the account portal"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: true
ui: true
traceability_id: REQ-2026-021
created: 2026-11-05
---

## Story

**As** a user with several devices, some of which still have no name or an unhelpful one such as "OAuth client (CdEfGhIj)", **I want** to give a device a name of my own in the account portal, **so that** I can tell my devices apart and recognise the one I do not know.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). Builds on 05-portal-redesign (device cards) and 01-device-naming-chain (name sanitising).
#  - Entry point: a "Rename" / "Umbenennen" control on each device card and on the device detail page. It leads to a small page with one
#    labelled text field (prefilled with the current name, at most 64 characters) and Save / Cancel. Works without JavaScript (plain form).
#  - Action: POST /account/devices/rename (device_id, device_name, csrf_token). Same protection as the sign-out of a device:
#    CSRF, Origin / fetch-metadata checks, and the 5-minute auth_time freshness rule (stale => 303 with notice "stale" and the "Confirm it is you"
#    link; no auth_time at all => notice "freshness_unavailable", no reauth link). Reason: a rogue device must not be able to hide behind a
#    harmless name set from a stolen portal session.
#  - Only the signed-in user's own device can be renamed; a foreign or unknown device id is "device_not_found" and changes nothing.
#  - The name is sanitised exactly like a typed name of 01-device-naming-chain (tags removed, control / invisible characters dropped,
#    at most 64 code points, trimmed). An empty result is refused with the form shown again; nothing is written.
#  - The change is made through a NEW public function of the Matrix domain (ADR-020: the OAuth domain never touches the devices table);
#    it writes devices.display_name for that user and device only. No new column, no migration. The new name appears at once in the portal,
#    the Matrix GET /devices, the admin user page and the Allow page's "replaces your session NAME" line.
#  - A client's own PUT /devices/{id} later still replaces the name (Matrix behaviour); the portal says nothing about that.
#  - The name is never written to a log line; it is plain text and HTML-escaped wherever it is shown. New notice codes (DE/EN):
#    "device_renamed" (status), "device_name_invalid" (alert). German uses "Sie".
Feature: Rename a device in the account portal

  Scenario: A fresh user renames a device
    Given a user signed in to the portal within the last 5 minutes with a device named "OAuth client (CdEfGhIj)"
    When the user opens Rename on that device, enters "Annas Handy" and saves
    Then the device list shows "Annas Handy" with the notice "device_renamed", and Matrix GET /devices and the admin user page show the same name

  Scenario: A stale session must confirm first and nothing changes
    Given a user whose portal sign-in is older than 5 minutes
    When the user submits a rename
    Then the response is a 303 with notice "stale" and the "Confirm it is you" link, and the device name is unchanged

  Scenario: Another user's device cannot be renamed
    Given a device id that belongs to another user, or does not exist
    When the portal user submits a rename for it
    Then the notice "device_not_found" is shown and no device of any user is changed

  Scenario: A hostile or empty name is sanitised or refused
    Given the rename form of a device
    When the user submits "<b>Work\u0007 laptop</b>", then a name of only invisible characters, then a 500 character name
    Then the names are stored as "Work laptop" and cut to 64 code points respectively, the invisible-only name is refused with "device_name_invalid" and the old name stays

  Scenario: The rename page is accessible and works in both languages
    Given the rename page in German and in English at 390 px and without JavaScript
    When it is rendered
    Then it has one main and one h1, a label tied to the field, a visible focus ring, 44 px controls, Cancel next to Save, and every text comes from the catalog
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

Proposed by the UX designer, accepted in principle by the owner on 2026-11-05 ("add the rename story as 06"); details below are defaults.

- **Freshness-gated like sign-out, unlike "withdraw an app":** withdrawing a consent only removes a convenience, but a rename can hide a rogue device, so the 5-minute rule applies (existing helper `fresh?/1` in `Nebu.OAuth.Account`).
- **Separate page, not inline editing:** a card with an inline text field needs JavaScript or a second form per card and breaks the "decision first" calm of the list. One plain GET page with one form is simple, works with the strict CSP and without script.
- **Matrix domain API:** a new `Nebu.Matrix` function (for example `account_rename_device/3`, name is the dev's choice) next to `account_devices/1`; it takes the user id from the verified portal session, never from the request.
- **Compliance audit:** whether a rename is written to the audit log is an open question below; default is no, because the name is cosmetic and visible only to the user and admins.
- **Not in scope:** renaming from the admin UI, bulk rename, a rename offer on the Allow page (`01` open question).

## Open Questions

- Should a rename be audit-logged (`Nebu.Compliance`)? Default: no. Kassandra to confirm.
- Rename also possible for the device the user is currently using in a Matrix app? Yes, nothing distinguishes it; the app may overwrite it with its own `PUT` later.
