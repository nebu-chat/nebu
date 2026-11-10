---
story: matrix-uia-authdone-else-if
epic: bugfix
status: done
security_review: required
matrix: true
ui: false
---

# Bugfix — UIA SSO fallback "Authentication complete" page must notify the client once (`else if`)

Found by the retro Oracle review of `oauth-pages-redesign/04-sso-confirm-and-result-pages`
(`_bmad-output/nebu/epics/oauth-pages-redesign/step-results/04-sso-confirm-and-result-pages/oracle-retro-review.md`).

## Problem

Matrix spec v1.18, User-Interactive Authentication, Fallback: the completion page script is
`if (window.onAuthDone) { window.onAuthDone(); } else if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }`.
`Nebu.Matrix.SsoLogin` (`@uia_script`) runs two independent `if`s, so a client that defines `onAuthDone` AND has an opener is notified twice
(the request could be resubmitted twice). The inline script is allowed by a SHA-256 in the page CSP (`PageShell.csp_with_script/1`, computed at
compile time from `@uia_script`), so the hash follows the script text.

## Acceptance criteria

```gherkin
Scenario: The completion script notifies the client through exactly one path
  Given a user who completed the UIA SSO fallback
  When the "Authentication complete" page is served
  Then its one inline script is `if (window.onAuthDone) { ... } else if (window.opener && window.opener.postMessage) { ... }`
  And "authDone" is posted with the target origin "*" exactly as the spec prescribes

Scenario: The CSP hash matches the served script exactly
  When the "Authentication complete" page is served
  Then the script-src hash in the Content-Security-Policy header equals the SHA-256 (base64) of the inline script text of the response body

Scenario: Framing protection and the rest of the policy are unchanged
  When the "Authentication complete" page is served
  Then the CSP still contains frame-ancestors 'none', default-src 'none', base-uri 'none', form-action 'none', and no COOP header is set
```

## Notes

- Only the script text changes (and with it the compile-time hash). The page, texts, the 403 mismatch page and all other CSP directives are unchanged.
- Story 04's ExUnit test and e2e step pinned the old two-`if` text; both are updated deliberately.
- No migration.
