# Story 16.2 — Landing Page + Nebu Brand Identity
#
# ATDD Red-Phase scaffold — tests are PENDING until the website is built and served.
#
# These tests run against WEBSITE_BASE_URL (default: http://localhost:4000).
# The URL is served from website/public/ after the EasyWebsite CI build.
# Tests skip gracefully if the URL is not reachable — set WEBSITE_BASE_URL
# to point at the deployed site (e.g. https://nebuchat.eu) for live smoke checks.
#
# CI integration: `make test-integration` starts the full stack but does NOT
# currently serve the static website. Until a website server is added to
# docker-compose, these tests self-skip. See TODO in website_smoke.steps.ts.

Feature: Nebu website smoke — landing page and brand identity

  Background:
    Given the Nebu website is accessible at the base URL

  # AC1 — landing page content sections
  # P0 — regression guard for content removal

  Scenario: Landing page shows the hero message and all required content sections
    When a visitor navigates to the landing page
    Then the page contains "Self-hosted Matrix chat"
    And the page contains "your data, your rules"
    And the page contains a value proposition section mentioning Matrix compatibility
    And the page contains a value proposition section mentioning data sovereignty
    And the page contains a value proposition section mentioning "no Redis"
    And the page contains "Apache 2.0"
    And the page contains a tech stack section mentioning "Go"
    And the page contains a tech stack section mentioning "Elixir"
    And the page contains a persona section mentioning "Marcus"
    And the page contains a persona section mentioning "Leila"
    And the page contains a link to a getting started guide
    And the page contains a link to architecture documentation

  # AC2 — logo visible in header
  # P0 — brand identity regression guard

  Scenario: Nebu logo is visible in the page header
    When a visitor navigates to the landing page
    Then the Nebu logo is visible in the header

  # AC3 — CSS brand color override applied
  # P1 — regression guard against reverting to opencode default #1544ff

  Scenario: Primary color reflects the Nebu brand color, not the opencode default
    When a visitor navigates to the landing page
    Then the CSS primary color variable is not "#1544ff"
    And the page does not apply the opencode default primary color "#1544ff"
