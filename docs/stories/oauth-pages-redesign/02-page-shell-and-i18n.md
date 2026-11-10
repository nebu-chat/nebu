---
story_id: 02-page-shell-and-i18n
title: "Shared Nebu page shell and German/English texts"
epic: oauth-pages-redesign
status: done
security_review: required
matrix: false
ui: true
traceability_id: REQ-2026-017
created: 2026-11-05
---

## Story

**As** an employee who opens a Nebu page in a browser, **I want** every page to look like Nebu and to speak my language (German or English), **so that** I recognise where I am and understand what is asked of me.

## Acceptance Criteria

```gherkin
# Rules (apply to all scenarios). Design: _bmad-output/planning-artifacts/ux-designs/ux-oauth-pages-redesign-2026-11-05/DESIGN.md
#  - ONE shared module renders the page frame (logo, tokens, notice / button / details styles) and holds ONE inline <style> block.
#    Its SHA-256 goes into the CSP as today (computed at compile time). Dark by default, light via prefers-color-scheme.
#    The logo is an inline SVG. No external resource, NO webfont (owner decision 2026-11-05): font stack Inter, system-ui, ...
#  - ONE string catalog: key -> {en, de}. Pages reference keys, never literals. German uses the formal "Sie".
#  - Language = first language of Accept-Language that is "de" or "en" (region tags such as de-AT count, q-values are honoured),
#    otherwise English. No cookie, no ?lang=, no switch. <html lang> follows the choice. <title> stays static per page and translated.
#  - The Accept-Language value is parsed and NEVER echoed into a page or a header.
#  - Existing data-page / data-error / data-role hooks, status codes and headers stay as they are.
#  - First consumers in this story: the 13 error pages of Nebu.OAuth.Pages. Later stories move the other pages onto the shell.
Feature: Shared page shell and DE/EN

  Scenario: An error page follows the browser language
    Given a request to /oauth2/authorize with an unknown client and the header "Accept-Language: de-AT,de;q=0.9,en;q=0.5"
    When the error page is rendered
    Then it is German (html lang "de", German title, heading and explanation) and keeps data-page "oauth-error" and data-error "unknown_client"

  Scenario: Unknown, missing or malformed language falls back to English
    Given requests with "Accept-Language: fr", no Accept-Language header, and the garbage value "xx;;q=,,*"
    When the error page is rendered
    Then each page is English with html lang "en", the value is never echoed into the body or any header, and the response is still 200 / the original status

  Scenario: Every page wears the Nebu look without loosening the CSP
    Given any page rendered by the shell
    When its HTML and headers are inspected
    Then it shows the inline hexagon-N logo, uses the dark Obsidian tokens and a prefers-color-scheme light variant, has exactly one inline style allowed by its SHA-256 in the CSP, loads no external resource or font, and the CSP is not looser than before

  Scenario: The catalog is complete in both languages
    Given the string catalog and the code lists of the error pages
    When the completeness test runs
    Then every key has a non-empty English and German text, every error code has title, heading, explanation and actions in both, and a missing key fails the build instead of rendering a blank

  Scenario: Request-derived values stay inert and the page stays accessible
    Given an error page that shows the unverified app website host "<img src=x onerror=1>.example"
    When it is rendered in German and in English
    Then the host is HTML-escaped plain text, there is one main and one h1, the text contrast is at least 4.5:1 in both themes, the focus outline is visible and the layout works at 320 px
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Decisions

- **Formal "Sie"** and **no Inter webfont** are owner decisions (2026-11-05). A webfont would need `font-src` and a font route on the OAuth endpoint: not worth it for these pages.
- **Error copy shape** (DESIGN.md 5.3): headline, one sentence of reason, one bold primary suggestion; further suggestions under a native `<details>` "More options" / "Weitere Möglichkeiten". The `h2` "What you can do" goes away.
- **Where it lives:** a new module in the web domain, for example `Nebu.Web.PageShell` plus `Nebu.Web.PageText` (catalog) and a `Nebu.Web.Locale` plug-free helper `Locale.from_conn/1`. Names are the dev's choice. `Nebu.OAuth.Pages` keeps its public API (`send_page/4`, `put_flow_headers/1`, `codes/0`).
- **Tests that pin the old English copy** (`server/test/nebu/oauth/*pages*`, e2e steps checking error text) are updated in this story. Tests must pin hooks and structure rather than literal sentences where possible.
- **Not in this story:** consent page, SSO confirm, SSO result pages, account portal.

## Open Questions

- Should `/account` error pages be switched in this story too (same renderer family), or stay for `05-portal-redesign`? Default: stay.
