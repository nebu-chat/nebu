---
story_id: 05-portal-redesign
title: "Account portal: overview, device cards and apps in the Nebu look"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-020
created: 2026-11-05
---

## Story

**As** an employee who opens my account page, **I want** a clear overview with my devices and allowed apps as easy-to-read cards in German or English, **so that** I can see where I am signed in and sign out a device I do not recognise without reading a table of technical columns.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). Design: DESIGN.md 5.4, mockup mockups/portal.html. Builds on 02-page-shell-and-i18n and 01-device-naming-chain.
#  - Pages in scope: every template in server/lib/nebu/oauth/account_templates/ (layout, overview, profile, devices, device_table, device,
#    delete_confirm, reset, apps, error) and the signed-out page and error codes of Nebu.OAuth.AccountPages.
#  - Navigation: Overview, Devices, Apps, Security (was Profile / Devices / Apps / Reset identity); aria-current stays on the active entry.
#  - Overview: headline, one sentence, three tiles with a live count (devices, allowed apps) and the reset entry; Matrix ID and display name in <details>.
#  - Devices: one card per device in a <ul>: device name, "app - last active", Sign out. Device id, IP and "added" in <details>.
#    NO "this device" badge: the portal is a browser session, the server does not know which Matrix device the user is on.
#  - Apps: one card per allowed app: name (claimed), website, allowed on, Withdraw. The long explanation becomes one sentence plus details.
#  - Unchanged: every route, form action, CSRF field, freshness / reauth rule, data-page / data-action / data-role / data-device-id / data-notice
#    hook, notice code and role (status / alert), the click-proof script of the reset page and its CSP hash, all headers.
Feature: Account portal redesign

  Scenario: The overview shows what matters and hides the rest
    Given a user with 3 devices and 2 allowed apps, in German and in English
    When the user opens /account
    Then the overview shows the headline, the counts "3 signed in" / "2 allowed", the three tiles and the navigation, and the Matrix ID and display name only inside collapsed details

  Scenario: Devices are cards, not a table
    Given a user with three devices
    When the user opens the devices page at 390 px
    Then each device is a list item with its name, app and last activity and a Sign out control whose accessible name includes the device, there is no table and no horizontal scroll, and device id, IP and creation time are inside each card's collapsed details

  Scenario: Signing out a device and withdrawing an app work as before
    Given the devices page and the apps page
    When the user signs out a device and withdraws an app
    Then the same confirmation steps, freshness rules and notice codes apply as today, the notices are shown in the shared notice style with a text label, and the device or app is gone from the list

  Scenario: Every portal page and error follows the browser language
    Given the portal pages, the signed-out page and each of the 12 account error codes
    When they are rendered with "Accept-Language: de" and with none
    Then each is German respectively English with the same data hooks, status codes and headers as before, and the catalog test finds no missing key

  Scenario: The reset page keeps its click proof
    Given the encryption reset page with a pending request
    When it is rendered in the new layout
    Then the approve form still embeds the click-proof script allowed by its SHA-256, Approve and Decline are two clearly separated buttons with Decline first, and no other script is added
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

- **Relative times** (Q4): the main line shows relative time up to 7 days ("active 5 minutes ago" / "zuletzt aktiv vor 5 Minuten"), then the ISO date; details always show the absolute UTC timestamp. One small formatter in the catalog module, tested for both languages and for singular / plural. The owner may switch to absolute-only.
- **Device cards replace the table**, so `<caption>` / `<th scope>` semantics are replaced by list semantics; the `data-role="account-device"` and `data-device-id` hooks move to the `<li>`. The "devices-truncated" note stays below the list.
- **App label** on a device card uses the existing `app_label/1` (the name claimed by the app), shown with "not verified" only in details, to keep the card short.
- **Tests to update:** every test and e2e step that reads table cells or the old nav labels (`server/test/nebu/oauth/*account*`, `e2e/step-definitions/oauth/*account*`); prefer hooks over text.
- **Visual checks:** Playwright at 320, 390 and 1280 px, dark and light, German and English.

## Open Questions

- None. Renaming a device (the way to repair existing "OAuth client (xxxxxxxx)" names, there is no backfill) is its own story, `06-portal-rename-device` (owner decision 2026-11-05). The device cards of this story leave room for a "Rename" control next to "Sign out".
