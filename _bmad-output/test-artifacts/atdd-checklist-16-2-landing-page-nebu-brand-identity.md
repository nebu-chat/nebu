---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
lastStep: step-04-generate-tests
lastSaved: '2026-05-20'
storyId: '16-2'
storyKey: 16-2-landing-page-nebu-brand-identity
storyFile: docs/stories/phase3/epic-16/16-2-landing-page-nebu-brand-identity.md
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-16-2-landing-page-nebu-brand-identity.md
generatedTestFiles:
  - e2e/features/website/website_smoke.feature
  - e2e/step-definitions/website/website_smoke.steps.ts
  - e2e/playwright.config.ts (modified — added website project)
inputDocuments:
  - e2e/playwright.config.ts
  - e2e/step-definitions/admin/bootstrap.steps.ts
  - e2e/step-definitions/admin/build-info-footer.steps.ts
  - e2e/fixtures/nebu-fixtures.ts
  - docs/stories/phase3/epic-16/16-2-landing-page-nebu-brand-identity.md
---

# ATDD Checklist — Story 16.2: Landing Page + Nebu Brand Identity

## Step 1: Preflight & Context

- **Stack detected:** fullstack (go.mod + playwright.config.ts)
- **Framework:** playwright-bdd v8.5 + TypeScript
- **Story key:** `16-2-landing-page-nebu-brand-identity`
- **Story ID:** `16-2`
- **ACs:**
  1. Landing page with hero, value props, tech stack, personas, links
  2. Nebu logo visible in header
  3. CSS primary color NOT `#1544ff`
  4. Playwright smoke test passes in CI

## Step 2: Generation Mode

**AI generation** — static site, no running server available during scaffolding.  
Recording mode not applicable (no `WEBSITE_BASE_URL` server reachable in development context).

## Step 3: Test Strategy

| AC | Scenario | Level | Priority | Red-Phase |
|---|---|---|---|---|
| AC1 | Landing page shows hero + all content sections | E2E Playwright+BDD | P0 | `throw Error (skip)` |
| AC1 | Logo visible in header | E2E Playwright+BDD | P0 | `throw Error` |
| AC3 | CSS primary color is not #1544ff | E2E Playwright+BDD | P1 | `throw Error` |
| AC4 | Smoke test structure present | (covered by above) | — | — |

All scenarios guard with a reachability check (`Given the Nebu website is accessible at the base URL`).
If `WEBSITE_BASE_URL` is not reachable, scenarios throw a SKIP error (shows as skipped in Playwright).

## Step 4: Generated Test Files

### `e2e/features/website/website_smoke.feature`

3 scenarios covering all ACs:
1. `Landing page shows the hero message and all required content sections` (P0)
2. `Nebu logo is visible in the page header` (P0)
3. `Primary color reflects the Nebu brand color, not the opencode default` (P1)

### `e2e/step-definitions/website/website_smoke.steps.ts`

Step definitions for all Gherkin steps. Key behaviors:

- **Given**: reachability check → self-skip (throw SKIP) if URL unreachable
- **When**: `page.goto(WEBSITE_BASE_URL)`
- **Then: content**: `page.getByText(...)` visibility assertions
- **Then: logo**: checks `header img[src*="nebu-logo"]`, `header svg`, `[class*="logo"]`
- **Then: color**: evaluates CSS rules text + `--color-primary` computed value, asserts not `#1544ff`

### `e2e/playwright.config.ts` (modified)

Added `websiteProject` (`playwright-bdd`) targeting `features/website/**/*.feature`.
- `baseURL`: `WEBSITE_BASE_URL` (default `http://localhost:4000`)
- `timeout`: 60_000ms

## TDD Red-Phase Compliance

All tests WILL FAIL (via throw or skip) until:
1. `website/dokument/index.md` contains hero + value props + tech stack + personas + links
2. `website/dokument/assets/nebu-logo.svg` is created and configured as logo
3. `website/dokument/custom.css` (or equivalent) overrides `--color-primary` to `#0a2540`
4. The website is built and served at `WEBSITE_BASE_URL`
