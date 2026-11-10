Feature: Consent page: the decision first, details later, in German and English

  @REQ-2026-018 @ac-the-decision-is-in-the-first-view-on-a-phone
  Scenario: The decision is in the first view on a phone
    Given a fresh login, a new device and no warnings, at a 390 x 844 viewport, in German and in English
    When the consent page is shown
    Then the heading, the app name, the permission sentence, the device name and both buttons are visible without scrolling and no label/value list is shown

  @REQ-2026-018 @ac-risk-notices-stay-visible-before-the-decision
  Scenario: Risk notices stay visible before the decision
    Given a login that is not fresh, a destination outside the app's website, and a session that would be replaced
    When the consent page is shown
    Then the three notices appear above the app block with their ids, a text label and an icon, are not inside the collapsed details, and Allow is aria-described by them

  @REQ-2026-018 @ac-details-are-collapsed-and-complete
  Scenario: Details are collapsed and complete
    Given the consent page with an app that supplies a website, terms and privacy URLs
    When the user opens "Show details"
    Then the website, the destination (id consent-destination), the session line, the terms and the privacy URLs are shown as escaped plain text and none of them is a link

  @REQ-2026-018 @ac-arming-behaviour-is-unchanged
  Scenario: Arming behaviour is unchanged
    Given the new consent page
    When the arming tests of ArmScript and the consent flow run
    Then Allow is inert until armed, Deny is never aria-disabled and comes first, Allow without JavaScript stays unavailable, the page still carries exactly one inline script allowed by its SHA-256 and the full mouse / keyboard / touch instructions stay available to assistive technology

  @REQ-2026-018 @ac-the-required-device-name-is-part-of-the-main-view
  Scenario: The required device name is part of the main view
    Given an approved client from which no device name can be derived
    When the consent page is shown
    Then a labelled "Device name" field sits above the buttons (not in details) with its own error message after a refusal, and Allow stays the only filled button
