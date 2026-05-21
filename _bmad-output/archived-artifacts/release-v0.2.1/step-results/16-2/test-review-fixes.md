# Test Review — Minor Fixes Applied — Story 16-2

**Date:** 2026-05-20
**Story:** 16-2 Landing Page + Nebu Brand Identity
**Action:** Auto-fix MINOR findings M1 and M2

## Findings Fixed

### M1: Background step skip mechanism
- **File:** `e2e/step-definitions/website/website_smoke.steps.ts`
- **Change:** Replaced `throw new Error(...)` with `test.skip(true, ...)` in the Background reachability check step.
- **Import added:** `test` imported from `../../fixtures/nebu-fixtures` alongside `Given, When, Then`.
- **Result:** When the website is unreachable, Playwright will mark the test as "skipped" (not "failed"), which is the correct behavior for an infra-unavailable guard.

### M2: Logo visibility assertion
- **File:** `e2e/step-definitions/website/website_smoke.steps.ts`
- **Change:** Replaced the manual `isVisible()` + if/then pattern with `expect(imgLogo.or(svgLogo).or(altLogo)).toBeVisible({ timeout: 10_000 })`.
- **Pattern used:** `locator.or()` chaining to produce a single locator for any of the three logo candidates, then a standard Playwright `expect(...).toBeVisible()` assertion.
- **Result:** Failure message now comes from Playwright's assertion engine (with locator diff), not a hand-rolled throw.

## Status

Both MINOR findings fixed. Tests remain in RED phase (website not yet built/served). Step file compiles correctly.
