---
status: done
epic: 16
story: 1
security_review: not-needed
matrix: false
ui: false
---

# Story 16.1: EasyWebsite Setup + GitLab CI Pipeline

Status: ready-for-dev

## Story

As a developer,
I want EasyWebsite configured with the `opencode` theme under `website/` in the monorepo, with a `pages` job in `.gitlab-ci.yml`,
So that the foundation is in place for all subsequent content stories to deploy without pipeline changes.

**Size:** S

## Acceptance Criteria

**Given** the nebu-chat repository,
**When** `ls website/` is inspected,
**Then** the following structure exists:
- `website/dokument/` - EasyWebsite content root
- `website/dokument/index.md` - Placeholder home page with heading "Nebu"
- `website/dokument/_meta.yaml` - Navigation configuration

**Given** the EasyWebsite configuration file under `website/`,
**When** it is inspected,
**Then** `theme: opencode` is configured

**Given** `.gitlab-ci.yml` at the repo root,
**When** it is inspected,
**Then** a `pages` job is defined that:
- builds EasyWebsite from `website/`
- writes output to `public/` (GitLab Pages convention)
- only runs on the `main` branch

**Given** a commit to `main`,
**When** the CI pipeline completes,
**Then** the GitLab Pages URL returns HTTP 200, the placeholder page renders with the opencode theme, and there are no browser console errors

**Given** the `pages` job in CI,
**When** it completes,
**Then** total job duration is < 5 minutes (NFR-16.1)

**Given** the EasyWebsite build output,
**When** inspected,
**Then** the site is statically rendered HTML - no server-side execution required (NFR-16.3)

## Technical Notes

- EasyWebsite Easy Mode: https://easywebsite.opencode.de
- Theme: `opencode` (CSS-Variablen-Overrides for Nebu branding later in Story 16.2)
- No Node.js/Next.js - EasyWebsite Easy Mode only
- GitLab Pages convention: `public/` as output artifact directory
- CI job name must be exactly `pages` for GitLab Pages to pick it up
- Only run on `main` branch

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. [CI pipeline structure test] - Manual CI inspection
   - Given: `.gitlab-ci.yml` exists in repo root
   - When: file content is inspected
   - Then: `pages` job exists, runs EasyWebsite build, outputs to `public/`, restricted to `main` branch

2. [EasyWebsite config test] - Manual file inspection
   - Given: EasyWebsite config under `website/`
   - When: inspected
   - Then: `theme: opencode` is set, `website/dokument/index.md` exists, `website/dokument/_meta.yaml` exists

3. [Static output test] - Manual build verification
   - Given: EasyWebsite build runs
   - When: `public/` output is inspected
   - Then: `index.html` exists, is static HTML, no JS runtime required
