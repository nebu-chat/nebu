Feature: Shared Nebu page shell and German/English texts

  @REQ-2026-017 @ac-an-error-page-follows-the-browser-language
  Scenario: An error page follows the browser language
    Given a request to /oauth2/authorize with an unknown client and the header "Accept-Language: de-AT,de;q=0.9,en;q=0.5"
    When the error page is rendered
    Then it is German (html lang "de", German title, heading and explanation) and keeps data-page "oauth-error" and data-error "unknown_client"

  @REQ-2026-017 @ac-unknown-missing-or-malformed-language-falls-back-to-english
  Scenario: Unknown, missing or malformed language falls back to English
    Given requests with "Accept-Language: fr", no Accept-Language header, and the garbage value "xx;;q=,,*"
    When the error page is rendered
    Then each page is English with html lang "en", the value is never echoed into the body or any header, and the response is still 200 / the original status

  @REQ-2026-017 @ac-every-page-wears-the-nebu-look-without-loosening-the-csp
  Scenario: Every page wears the Nebu look without loosening the CSP
    Given any page rendered by the shell
    When its HTML and headers are inspected
    Then it shows the inline hexagon-N logo, uses the dark Obsidian tokens and a prefers-color-scheme light variant, has exactly one inline style allowed by its SHA-256 in the CSP, loads no external resource or font, and the CSP is not looser than before

  @REQ-2026-017 @ac-the-catalog-is-complete-in-both-languages
  Scenario: The catalog is complete in both languages
    Given the string catalog and the code lists of the error pages
    When the completeness test runs
    Then every key has a non-empty English and German text, every error code has title, heading, explanation and actions in both, and a missing key fails the build instead of rendering a blank

  @REQ-2026-017 @ac-request-derived-values-stay-inert-and-the-page-stays-accessible
  Scenario: Request-derived values stay inert and the page stays accessible
    Given an error page that shows the unverified app website host "<img src=x onerror=1>.example"
    When it is rendered in German and in English
    Then the host is HTML-escaped plain text, there is one main and one h1, the text contrast is at least 4.5:1 in both themes, the focus outline is visible and the layout works at 320 px
