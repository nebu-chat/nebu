---
story_id: 04-sso-confirm-and-result-pages
title: "SSO confirmation and sign-in result pages in the Nebu look"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: true
ui: true
traceability_id: REQ-2026-019
created: 2026-11-05
---

## Story

**As** a user who signs in or confirms a sensitive action through a Matrix app that uses SSO, **I want** the confirmation and result pages to look like the consent page and to speak my language, **so that** I trust them and understand whether it worked.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). Design: DESIGN.md 5.2 and 5.3. Builds on 02-page-shell-and-i18n.
#  - Pages in scope: Nebu.Matrix.SsoConfirmPage (confirm, cancelled, 5 error pages) and the three bare pages of Nebu.Matrix.SsoLogin:
#    "Login Not Supported" (render_html_error/1), "Authentication complete" (200) and "Authentication did not match" (403) of the UIA fallback.
#  - Confirm page = same structure as the consent page: h1, risk notice, the target origin as the app block, Cancel first, Continue (armed),
#    one visible hint line, the user id and path in <details>. Unchanged: ArmScript and its hash, aria-disabled on Continue, data-arm /
#    data-arm-hint / data-arm-status, noscript, data-page "sso-confirm" with data-result / data-error, data-role hooks, all headers
#    (including NO Cross-Origin-Opener-Policy: popup clients need window.opener), the CSP form-action https origin.
#  - "Authentication complete" must keep working for Matrix clients: window.onAuthDone() and window.opener.postMessage("authDone", ...) run exactly
#    as today. With the shell's strict CSP the inline script is allowed ONLY by its SHA-256 (script-src 'sha256-...'), computed at compile time.
#  - The three SsoLogin pages gain html lang, viewport meta, the shell and German/English text; render_html_error/1 keeps escaping the scheme.
Feature: SSO confirmation and result pages

  Scenario: The SSO confirm page has the same decision-first structure as consent
    Given a pending legacy SSO redirect in German and in English at 390 x 844
    When the confirm page is shown
    Then heading, target origin, notice, Cancel and Continue are visible without scrolling, Cancel comes first, Continue is armed as before and user id and path are inside the collapsed details

  Scenario: Cancelled and error pages use the shell and keep their hooks
    Given the cancelled page and each of the five error pages of the SSO confirmation
    When they are rendered
    Then each uses the shell and the browser language, keeps data-page "sso-confirm" / "sso-confirm-error" with its data-result / data-error, renders no request value, and keeps its headers and status

  Scenario: A finished sign-in still tells the Matrix client that authentication is done
    Given a user who completed the UIA SSO fallback
    When the "Authentication complete" page loads in a browser
    Then window.onAuthDone is called and "authDone" is posted to window.opener exactly as before, the page is in the shell and the language of the browser, and its CSP allows only that one script by hash

  Scenario: A mismatching authentication shows a clear refusal
    Given a UIA completion whose identity does not match the pending request
    When the 403 page is rendered
    Then it says in plain German or English that nothing was authorised, runs no script, keeps status 403 and no-store, and logs nothing new

  Scenario: The unsupported-login page escapes the scheme and is readable
    Given an app whose redirect scheme "<script>alert(1)</script>" is not allowed
    When render_html_error/1 is rendered
    Then the scheme is HTML-escaped inside a code element, the page has lang, viewport, one main and one h1, and tells the user to contact the administrator
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

- **Why this is its own story:** the "Authentication complete" page is the only page in the epic that must execute script for a Matrix client; getting its CSP wrong would silently break UIA re-authentication in every client. It needs its own ATDD scenario (3) and an e2e / compat check with a real client (`tests/matrix_compat`).
- **Existing target origin warning** of the confirm page stays a notice above the target block.
- **Out of scope, noted for Kassandra:** `postMessage("authDone", "*")` uses a wildcard target origin today (Matrix UIA fallback convention). Do not change it here; record it in the security report if still relevant.
- **Tests to update:** `server/test/nebu/matrix/*sso*`, the e2e steps `e2e/step-definitions/oauth/legacy-sso-redirect-confirmation.steps.ts`, and the tests of `SsoLogin.render_html_error/1`.

## Open Questions

- None beyond those of `02-page-shell-and-i18n`.
