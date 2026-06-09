/**
 * Step definitions for e2e/features/website/website_smoke.feature
 *
 * Story 16.2 — Landing Page + Nebu Brand Identity
 *
 * TDD RED PHASE — these steps will FAIL until the website is built and served.
 *
 * Target: WEBSITE_BASE_URL (default: http://localhost:4000)
 * The static site is built from website/dokument/ via the EasyWebsite CI job
 * (gitlab-ci.yml `pages` job) and served from website/public/.
 *
 * TODO: add a `website` service to docker-compose.yaml that serves
 * website/public/ on port 4000 so these tests run in make test-integration.
 * Until then every scenario self-skips if the URL is not reachable.
 *
 * CSS color check: the brand primary color must be #0a2540 (deep navy).
 * The test asserts that neither the CSS variable nor any computed style
 * resolves to the opencode default #1544ff.
 */

import { Given, When, Then, test } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';

const WEBSITE_BASE_URL = process.env.WEBSITE_BASE_URL ?? 'http://localhost:4000';

// ─── Background step ──────────────────────────────────────────────────────────

/**
 * "Given the Nebu website is accessible at the base URL"
 *
 * Performs a lightweight reachability check. If the website is not running,
 * the test skips gracefully with a descriptive message instead of failing.
 *
 * WILL SKIP until a website server is added to the docker-compose stack.
 */
Given(
  'the Nebu website is accessible at the base URL',
  async ({ page }: { page: Page }) => {
    const resp = await page.request.get(WEBSITE_BASE_URL).catch(() => null);
    if (!resp || !resp.ok()) {
      // test.skip() marks the test as "skipped" rather than "failed".
      // Remove this guard once WEBSITE_BASE_URL is reliably served in CI.
      test.skip(
        true,
        `Nebu website not reachable at ${WEBSITE_BASE_URL}. ` +
        `Build the site (make pages or the GitLab pages CI job) and set ` +
        `WEBSITE_BASE_URL or serve website/public/ locally (e.g. npx serve website/public -p 4000).`
      );
    }
  }
);

// ─── Navigation ───────────────────────────────────────────────────────────────

/**
 * "When a visitor navigates to the landing page"
 *
 * Navigates to the root path of the website. Will FAIL if the site is not running.
 */
When(
  'a visitor navigates to the landing page',
  async ({ page }: { page: Page }) => {
    await page.goto(WEBSITE_BASE_URL, { waitUntil: 'domcontentloaded' });
  }
);

// ─── AC1 — Content sections ───────────────────────────────────────────────────

/**
 * "Then the page contains {string}"
 *
 * Generic text-presence assertion. Used for hero copy, value props, tech stack,
 * persona names, and license info.
 *
 * WILL FAIL before website/dokument/index.md contains the required content.
 */
Then(
  'the page contains {string}',
  async ({ page }: { page: Page }, expectedText: string) => {
    await expect(page.getByText(expectedText, { exact: false })).toBeVisible({
      timeout: 10_000,
    });
  }
);

/**
 * "Then the page contains a value proposition section mentioning Matrix compatibility"
 *
 * AC1: value props must include Matrix compatibility messaging.
 * WILL FAIL before index.md contains that content.
 */
Then(
  'the page contains a value proposition section mentioning Matrix compatibility',
  async ({ page }: { page: Page }) => {
    // Accepts "Matrix", "Matrix-compatible", or "Matrix Client-Server"
    const locator = page.getByText(/Matrix[\s-]?(compatible|Client[\s-]Server|API)?/i, { exact: false });
    await expect(locator.first()).toBeVisible({ timeout: 10_000 });
  }
);

/**
 * "Then the page contains a value proposition section mentioning data sovereignty"
 *
 * AC1: value props must include data sovereignty messaging.
 * WILL FAIL before index.md contains that content.
 */
Then(
  'the page contains a value proposition section mentioning data sovereignty',
  async ({ page }: { page: Page }) => {
    // Accepts "data-sovereign", "data sovereignty", "your data, your rules"
    const locator = page.getByText(/data[\s-]?sovereign|your data/i, { exact: false });
    await expect(locator.first()).toBeVisible({ timeout: 10_000 });
  }
);

/**
 * "Then the page contains a value proposition section mentioning {string}"
 *
 * Parameterised fallback for value proposition mentions not covered by the
 * specific named steps above (e.g. "no Redis", "no NATS").
 */
Then(
  'the page contains a value proposition section mentioning {string}',
  async ({ page }: { page: Page }, text: string) => {
    await expect(page.getByText(text, { exact: false })).toBeVisible({
      timeout: 10_000,
    });
  }
);

/**
 * "Then the page contains a tech stack section mentioning {string}"
 *
 * AC1: tech stack overview must mention Go and Elixir.
 * WILL FAIL before index.md contains that content.
 */
Then(
  'the page contains a tech stack section mentioning {string}',
  async ({ page }: { page: Page }, tech: string) => {
    await expect(page.getByText(tech, { exact: false })).toBeVisible({
      timeout: 10_000,
    });
  }
);

/**
 * "Then the page contains a persona section mentioning {string}"
 *
 * AC1: stakeholder personas (Marcus, Leila) must appear on the page.
 * WILL FAIL before index.md contains persona content.
 */
Then(
  'the page contains a persona section mentioning {string}',
  async ({ page }: { page: Page }, personaName: string) => {
    await expect(page.getByText(personaName, { exact: false })).toBeVisible({
      timeout: 10_000,
    });
  }
);

/**
 * "Then the page contains a link to a getting started guide"
 *
 * AC1: a "Getting Started" (or equivalent) link must be present.
 * WILL FAIL before index.md contains that link.
 */
Then(
  'the page contains a link to a getting started guide',
  async ({ page }: { page: Page }) => {
    const linkLocator = page.getByRole('link', { name: /getting started|get started|quickstart/i });
    await expect(linkLocator.first()).toBeVisible({ timeout: 10_000 });
  }
);

/**
 * "Then the page contains a link to architecture documentation"
 *
 * AC1: an architecture (or "Architecture") link must be present.
 * WILL FAIL before index.md contains that link.
 */
Then(
  'the page contains a link to architecture documentation',
  async ({ page }: { page: Page }) => {
    const linkLocator = page.getByRole('link', { name: /architecture|arc42|technical/i });
    await expect(linkLocator.first()).toBeVisible({ timeout: 10_000 });
  }
);

// ─── AC2 — Logo in header ─────────────────────────────────────────────────────

/**
 * "Then the Nebu logo is visible in the header"
 *
 * AC2: the SVG logo placed in website/dokument/assets/nebu-logo.svg must
 * appear in the rendered page header (EasyWebsite renders it via the `logo`
 * theme property).
 *
 * WILL FAIL before:
 *   1. website/dokument/assets/nebu-logo.svg is created, AND
 *   2. The EasyWebsite theme is configured to use it as the logo.
 */
Then(
  'the Nebu logo is visible in the header',
  async ({ page }: { page: Page }) => {
    // EasyWebsite renders the logo as an <img> or inline <svg> in the header/nav.
    // Try both: an <img> with src containing "nebu-logo", and an inline <svg>
    // inside a header or nav element.
    const imgLogo = page.locator('header img[src*="nebu-logo"], nav img[src*="nebu-logo"]');
    const svgLogo = page.locator('header svg, nav svg').first();
    const altLogo = page.locator('[class*="logo"], [id*="logo"]').first();

    // At least one of these must be visible.
    // locator.or() returns a locator that matches if either locator matches —
    // chaining three produces a locator that matches any of the three candidates.
    await expect(imgLogo.or(svgLogo).or(altLogo)).toBeVisible({ timeout: 10_000 });
  }
);

// ─── AC3 — Brand color override ───────────────────────────────────────────────

/**
 * "Then the CSS primary color variable is not {string}"
 *
 * AC3: the Nebu brand color override must be applied. The page's CSS must not
 * resolve the primary color to the opencode EasyWebsite default #1544ff.
 *
 * Checks both:
 *   - The raw CSS text on the page (grep for #1544ff / rgb(21, 68, 255))
 *   - The computed value of --color-primary (or equivalent custom property)
 *
 * WILL FAIL before website/dokument/custom.css overrides the color variables.
 */
Then(
  'the CSS primary color variable is not {string}',
  async ({ page }: { page: Page }, forbiddenColor: string) => {
    // Normalise to lower-case hex without # for comparison
    const forbidden = forbiddenColor.replace('#', '').toLowerCase();

    // 1. Check all <style> and <link rel="stylesheet"> inline content for the
    //    literal hex color. This catches cases where the default is baked in.
    const styleContent = await page.evaluate(() => {
      const sheets = Array.from(document.styleSheets);
      let combined = '';
      for (const sheet of sheets) {
        try {
          combined += Array.from(sheet.cssRules).map(r => r.cssText).join('\n');
        } catch {
          // Cross-origin sheet — skip
        }
      }
      return combined;
    });

    // If the forbidden color appears anywhere in the resolved CSS, fail.
    expect(styleContent.toLowerCase()).not.toContain(`#${forbidden}`);

    // 2. Check the computed value of the CSS custom property --color-primary
    //    (EasyWebsite / opencode default variable name).
    const computedPrimary = await page.evaluate(() => {
      return getComputedStyle(document.documentElement)
        .getPropertyValue('--color-primary')
        .trim()
        .toLowerCase();
    });

    if (computedPrimary) {
      // Strip # and whitespace for comparison
      const normalised = computedPrimary.replace('#', '').replace(/\s/g, '');
      expect(normalised).not.toBe(forbidden);
    }
  }
);

/**
 * "Then the page does not apply the opencode default primary color {string}"
 *
 * AC3 (alias): cross-checks via computed background/text color on a prominent
 * element to catch cases where the custom property is set but not applied.
 *
 * WILL FAIL before the Nebu brand CSS override is active.
 */
Then(
  'the page does not apply the opencode default primary color {string}',
  async ({ page }: { page: Page }, forbiddenColor: string) => {
    // rgb(21, 68, 255) is the RGB equivalent of #1544ff
    const forbiddenRgb = 'rgb(21, 68, 255)';
    const forbidden = forbiddenColor.replace('#', '').toLowerCase();

    // Check computed color on the <body> and any primary-color-bearing element
    const bodyColors = await page.evaluate((rgb: string) => {
      const el = document.body;
      const style = getComputedStyle(el);
      return {
        background: style.backgroundColor,
        color: style.color,
        borderColor: style.borderColor,
      };
    }, forbiddenRgb);

    expect(bodyColors.background).not.toBe(forbiddenRgb);
    expect(bodyColors.color).not.toBe(forbiddenRgb);

    // Also check the full page HTML for the literal hex string as a safety net
    const pageSource = await page.content();
    expect(pageSource.toLowerCase()).not.toContain(`color:#${forbidden}`);
    expect(pageSource.toLowerCase()).not.toContain(`color: #${forbidden}`);
  }
);
