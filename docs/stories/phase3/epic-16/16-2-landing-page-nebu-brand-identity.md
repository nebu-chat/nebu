---
status: done
epic: 16
story: 2
security_review: not-needed
matrix: false
ui: true
---

# Story 16.2: Landing Page + Nebu Brand Identity

Status: done

## Story

As a visitor to nebuchat.eu,
I want a landing page that clearly presents what Nebu is and why it matters, styled with Nebu's logo and brand colors,
So that I immediately understand if Nebu solves my problem.

**Size:** M

**Pre-Story TODO:** Nebu brand color(s) for CSS variable overrides must be decided before this story starts. Default: use `#0a2540` (deep navy) as primary color if no decision has been made.

## Acceptance Criteria

**Given** `website/dokument/index.md` with landing page content,
**When** the page is rendered,
**Then** the following sections are present:
- Hero with core message (e.g. "Self-hosted Matrix chat - your data, your rules")
- Value propositions: Matrix-compatible, data-sovereign, no Redis/NATS/Kafka, Apache 2.0
- Tech stack overview (Go + Elixir/OTP)
- Stakeholder personas (Operator Marcus, End User Leila, Compliance Officer, Admin Kai)
- Links to Getting Started guide and Architecture documentation

**Given** `website/dokument/assets/nebu-logo.svg` exists,
**When** the site renders,
**Then** the Nebu logo appears in the header (via the `logo` property in the theme configuration)

**Given** a CSS override file (e.g. `website/dokument/custom.css`) with Nebu brand color variables,
**When** the site renders,
**Then** the primary color is no longer `#1544ff` (opencode default) but reflects the defined Nebu brand color

**Given** a Playwright screenshot test `e2e/features/website_smoke.feature`,
**When** `make test-integration` runs,
**Then** the scenario "Landing page renders with Nebu logo and custom primary color" passes - catching CSS variable regressions on future changes

## Technical Notes

- EasyWebsite Easy Mode - content is Markdown
- Logo: create a simple SVG placeholder if no official logo exists yet
- Brand color decision: use `#0a2540` (deep navy) as default if not otherwise specified
- CSS override: EasyWebsite supports CSS variable overrides via a custom CSS file
- Playwright test: must use `.feature` + `.steps.ts` format (project standard)

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. [Landing page content test] - Playwright+Cucumber (`e2e/features/website_smoke.feature` + `e2e/steps/website_smoke.steps.ts`)
   - Given: the website is running (served from `public/`)
   - When: visitor navigates to `/`
   - Then: page contains "Self-hosted Matrix chat", value proposition sections, tech stack, and persona names

2. [Brand color regression test] - Playwright+Cucumber
   - Given: the website is running
   - When: visitor navigates to `/`
   - Then: the CSS primary color variable is NOT `#1544ff` (opencode default) - brand override is applied

3. [Logo presence test] - Playwright+Cucumber
   - Given: `website/dokument/assets/nebu-logo.svg` exists
   - When: visitor navigates to `/`
   - Then: logo element is visible in the header
