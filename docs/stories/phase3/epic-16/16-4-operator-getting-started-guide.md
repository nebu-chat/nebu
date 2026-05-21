---
status: ready-for-dev
epic: 16
story: 4
security_review: not-needed
matrix: false
ui: false
---

# Story 16.4: Operator Getting-Started Guide

Status: ready-for-dev

## Story

As an operator wanting to self-host Nebu,
I want a step-by-step Getting Started guide on the website,
So that I can get Nebu running with Docker Compose and OIDC and complete my first login in under 30 minutes.

**Size:** S

## Acceptance Criteria

**Given** `website/dokument/getting-started/index.md`,
**When** it is rendered,
**Then** it contains the following sections:
- Prerequisites (Docker, Docker Compose, OIDC provider or Keycloak)
- Clone + Setup (`git clone`, `make setup`)
- Configuration (OIDC_ISSUER, DB_URL, secrets)
- First Start (`make dev`)
- Verification (health check URL, first Matrix client login)
- Common Troubleshooting (≥ 3 common failure scenarios with resolution steps)

**Given** `website/dokument/_meta.yaml`,
**When** the site renders,
**Then** "Getting Started" appears as a top-level navigation entry

**Given** a new operator with no prior Nebu knowledge,
**When** they follow the guide end-to-end,
**Then** they can reach the Admin UI and complete the first OIDC login without consulting additional documentation - validated via a manual usability pass by Phil before the story is marked done

## Technical Notes

- Content is Markdown under `website/dokument/getting-started/`
- Navigation entry in `website/dokument/_meta.yaml` at top level
- Must include accurate env var names: `NEBU_OIDC_ISSUER`, `NEBU_DB_URL`, `NEBU_INTERNAL_SECRET_FILE`
- Reference `make setup` for secrets generation
- Include link to Keycloak setup if user doesn't have an OIDC provider
- Troubleshooting: container startup failures, OIDC redirect errors, database connection issues

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. [Content completeness test] - Manual document inspection
   - Given: `website/dokument/getting-started/index.md` exists
   - When: file is inspected
   - Then: all 6 required sections are present (Prerequisites, Clone+Setup, Configuration, First Start, Verification, Troubleshooting with ≥3 scenarios)

2. [Navigation test] - Manual site inspection
   - Given: the website is built and served
   - When: top-level navigation is inspected
   - Then: "Getting Started" link is present and navigates to the guide

3. [Usability pass] - Manual end-to-end validation by Phil
   - Given: a clean environment with Docker and Docker Compose
   - When: the guide is followed from start to finish
   - Then: Admin UI is reachable and first OIDC login completes successfully
