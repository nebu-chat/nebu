---
story_id: 03-consent-page-redesign
title: "Consent page: the decision first, details later, in German and English"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-018
created: 2026-11-05
---

## Story

**As** a user who is asked to allow an app to use my account, **I want** the page to show me which app asks, what it gets and the two buttons first, with everything else one tap away, **so that** I understand the question at a glance and can decide safely.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). Design: _bmad-output/planning-artifacts/ux-designs/ux-oauth-pages-redesign-2026-11-05/DESIGN.md 5.1,
# mockup mockups/consent.html. Builds on 01-device-naming-chain (name line and name field) and 02-page-shell-and-i18n (shell, texts, language).
#  - Order: logo, h1, risk notices (only those that apply), app block, ONE permission sentence, [device name field when required],
#    buttons (Deny first, then Allow), one visible hint line, fine print, <details> "Show details" / "Details anzeigen" (collapsed).
#  - Always visible, never in details: freshness-notice, destination-notice, replace-notice, the app name with "not verified by Nebu",
#    the device name line (or the required name field).
#  - In details: app website, destination (id consent-destination), session line, terms, privacy. App-supplied URLs stay plain text, never links.
#  - Unchanged: the arming script and its CSP hash, aria-disabled on Allow, form="oauth-consent-armed", data-arm / data-arm-hint /
#    data-arm-status, Deny first in DOM and order, noscript line, every header (no-store, X-Frame-Options, COOP same-origin, CSP form-action
#    source), the server-side checks (cookie, CSRF, fetch metadata), data-page / data-device / data-fresh and the id / data-role hooks.
Feature: Consent page redesign

  Scenario: The decision is in the first view on a phone
    Given a fresh login, a new device and no warnings, at a 390 x 844 viewport, in German and in English
    When the consent page is shown
    Then the heading, the app name, the permission sentence, the device name and both buttons are visible without scrolling and no label/value list is shown

  Scenario: Risk notices stay visible before the decision
    Given a login that is not fresh, a destination outside the app's website, and a session that would be replaced
    When the consent page is shown
    Then the three notices appear above the app block with their ids, a text label and an icon, are not inside the collapsed details, and Allow is aria-described by them

  Scenario: Details are collapsed and complete
    Given the consent page with an app that supplies a website, terms and privacy URLs
    When the user opens "Show details"
    Then the website, the destination (id consent-destination), the session line, the terms and the privacy URLs are shown as escaped plain text and none of them is a link

  Scenario: Arming behaviour is unchanged
    Given the new consent page
    When the arming tests of ArmScript and the consent flow run
    Then Allow is inert until armed, Deny is never aria-disabled and comes first, Allow without JavaScript stays unavailable, the page still carries exactly one inline script allowed by its SHA-256 and the full mouse / keyboard / touch instructions stay available to assistive technology

  Scenario: The required device name is part of the main view
    Given an approved client from which no device name can be derived
    When the consent page is shown
    Then a labelled "Device name" field sits above the buttons (not in details) with its own error message after a refusal, and Allow stays the only filled button
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

Defaults chosen by the UX designer where the owner has not answered yet; Kassandra / owner may overrule.

- **Arming hint (Q2):** the visible hint shrinks to one line ("Allow unlocks a moment after you interact with this page. This protects you from accidental clicks."). The full device-specific instructions (mouse / keyboard / touch) go into a visually hidden element that Allow's `aria-describedby` also points at, so screen-reader users lose nothing. A closed `<details>` would hide them from assistive technology, so it is not used for this. Needs Kassandra's sign-off (ADR-033 FR21).
- **Texts** come from the catalog of `02-page-shell-and-i18n`; German copy for this page is in the mockup. The h1 and the `<title>` stay static (never a request value). The app name is shown as the app's claim, with the line "Name given by the app, not verified" / "Vom Hersteller der App angegeben, nicht geprüft".
- **Allow label** "Erlauben", **Deny label** "Ablehnen"; the form values stay `allow` / `deny`.
- **Tests that pin the old page** are updated: `server/test/nebu/oauth/oauth_consent_page_test.exs`, `oauth_consent_flow_test.exs`, `oauth_consent_csrf_test.exs`, `adr_033_test.exs`, `server/test/nebu/web/arm_script_test.exs` (only if its page assumptions change), and the e2e steps `e2e/step-definitions/oauth/oauth-consent*.steps.ts`. The moduledoc of `ConsentPage` (its "Contract" section) is rewritten with the new order.
- **Visual checks:** Playwright at 320, 390 and 1280 px, dark and light, German and English, with 0 and with 3 notices.

## Open Questions

- With three notices the buttons sit below the first view on a phone (seen in the mockup). Accepted: the warnings are the point. Confirm.
