Feature: SSO confirmation and sign-in result pages in the Nebu look

  @REQ-2026-019 @ac-the-sso-confirm-page-has-the-same-decision-first-structure-as-consent
  Scenario: The SSO confirm page has the same decision-first structure as consent
    Given a pending legacy SSO redirect in German and in English at 390 x 844
    When the confirm page is shown
    Then heading, target origin, notice, Cancel and Continue are visible without scrolling, Cancel comes first, Continue is armed as before and user id and path are inside the collapsed details

  @REQ-2026-019 @ac-cancelled-and-error-pages-use-the-shell-and-keep-their-hooks
  Scenario: Cancelled and error pages use the shell and keep their hooks
    Given the cancelled page and each of the five error pages of the SSO confirmation
    When they are rendered
    Then each uses the shell and the browser language, keeps data-page "sso-confirm" / "sso-confirm-error" with its data-result / data-error, renders no request value, and keeps its headers and status

  @REQ-2026-019 @ac-a-finished-sign-in-still-tells-the-matrix-client-that-authentication
  Scenario: A finished sign-in still tells the Matrix client that authentication is done
    Given a user who completed the UIA SSO fallback
    When the "Authentication complete" page loads in a browser
    Then window.onAuthDone is called once and the opener is not messaged (the spec else-if), the page is in the shell and the language of the browser, and its CSP allows only that one script by hash

  @REQ-2026-019 @ac-a-mismatching-authentication-shows-a-clear-refusal
  Scenario: A mismatching authentication shows a clear refusal
    Given a UIA completion whose identity does not match the pending request
    When the 403 page is rendered
    Then it says in plain German or English that nothing was authorised, runs no script, keeps status 403 and no-store, and logs nothing new

  @REQ-2026-019 @ac-the-unsupported-login-page-escapes-the-scheme-and-is-readable
  Scenario: The unsupported-login page escapes the scheme and is readable
    Given an app whose redirect scheme "<script>alert(1)</script>" is not allowed
    When render_html_error/1 is rendered
    Then the scheme is HTML-escaped inside a code element, the page has lang, viewport, one main and one h1, and tells the user to contact the administrator
