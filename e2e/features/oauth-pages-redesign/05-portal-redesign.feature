Feature: Account portal: overview, device cards and apps in the Nebu look

  @REQ-2026-020 @ac-the-overview-shows-what-matters-and-hides-the-rest
  Scenario: The overview shows what matters and hides the rest
    Given a user with 3 devices and 2 allowed apps, in German and in English
    When the user opens /account
    Then the overview shows the headline, the counts "3 signed in" / "2 allowed", the three tiles and the navigation, and the Matrix ID and display name only inside collapsed details

  @REQ-2026-020 @ac-devices-are-cards-not-a-table
  Scenario: Devices are cards, not a table
    Given a user with three devices
    When the user opens the devices page at 390 px
    Then each device is a list item with its name, app and last activity and a Sign out control whose accessible name includes the device, there is no table and no horizontal scroll, and device id, IP and creation time are inside each card's collapsed details

  @REQ-2026-020 @ac-signing-out-a-device-and-withdrawing-an-app-work-as-before
  Scenario: Signing out a device and withdrawing an app work as before
    Given the devices page and the apps page
    When the user signs out a device and withdraws an app
    Then the same confirmation steps, freshness rules and notice codes apply as today, the notices are shown in the shared notice style with a text label, and the device or app is gone from the list

  @REQ-2026-020 @ac-every-portal-page-and-error-follows-the-browser-language
  Scenario: Every portal page and error follows the browser language
    Given the portal pages, the signed-out page and each of the 12 account error codes
    When they are rendered with "Accept-Language: de" and with none
    Then each is German respectively English with the same data hooks, status codes and headers as before, and the catalog test finds no missing key

  @REQ-2026-020 @ac-the-reset-page-keeps-its-click-proof
  Scenario: The reset page keeps its click proof
    Given the encryption reset page with a pending request
    When it is rendered in the new layout
    Then the approve form still embeds the click-proof script allowed by its SHA-256, Approve and Decline are two clearly separated buttons with Decline first, and no other script is added
