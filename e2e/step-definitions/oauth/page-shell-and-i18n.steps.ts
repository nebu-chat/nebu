/**
 * Step definitions for features/oauth-pages-redesign/02-page-shell-and-i18n.feature
 *
 * Story: oauth-pages-redesign / 02-page-shell-and-i18n (REQ-2026-017). Runs against the full compose stack (admin-ui project, baseURL = Nebu).
 * ATDD RED phase: the shell, the DE/EN catalog and the locale resolution do not exist yet.
 *
 * Nothing here needs the IdP: the pages under test are the pre-trust error pages of GET /oauth2/authorize
 * (unknown client => 400 unknown_client; POST => 405 method_not_allowed; pending client => 403 client_pending).
 * The feature file has no Background (it is the verbatim Gherkin of the story), so a `@REQ-2026-017` Before hook enables OAuth with the
 * e2e issuer and an After hook restores the prior config and removes the fixture clients (same pattern as oauth-authorize.steps.ts).
 *
 * Reused, never redefined here (bddgen rejects duplicates): nothing - every step text of this feature is new.
 * The text pinned in other features ("What you can do", English headings) is updated by the dev in the same story.
 *
 * Module-level state below is scenario-scoped and reset in the Before hook.
 */

import { Given, When, Then, Before, After } from '../../fixtures/nebu-fixtures';
import { expect } from '@playwright/test';
import type { APIRequestContext, APIResponse, Page } from '@playwright/test';
import {
  upsertServerConfig,
  queryServerConfigValue,
  deleteServerConfig,
  insertOAuthClient,
  clearOAuthClientsByIdPrefix,
} from '../../fixtures/db';
import { E2E_ISSUER } from '../../fixtures/oauth-issuer';
import { createHash } from 'node:crypto';

const NEBU_BASE_URL = process.env.NEBU_ADMIN_URL ?? 'http://localhost:8008';
const AUTHORIZE_PATH = '/oauth2/authorize';
const CLIENT_PREFIX = 'e2e-oauth-shell-';
const UNKNOWN_CLIENT = `${CLIENT_PREFIX}does-not-exist`;
const REDIRECT_URI = 'https://client.e2e.example/cb';
const DE_HEADER = 'de-AT,de;q=0.9,en;q=0.5';

type Planned = { label: string; method: 'GET' | 'POST'; query: Record<string, string>; acceptLanguage: string | null };
type Fetched = { planned: Planned; status: number; headers: Record<string, string>; body: string };

let priorIssuer: string | null = null;
let plan: Planned[] = [];
let fetched: Fetched[] = [];
let garbageValues: string[] = [];
let pendingClientId = '';

// ─── Hooks ─────────────────────────────────────────────────────────────────────

Before({ tags: '@REQ-2026-017' }, async () => {
  plan = [];
  fetched = [];
  garbageValues = [];
  pendingClientId = '';
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
  priorIssuer = queryServerConfigValue('oauth_issuer_url');
  upsertServerConfig('oauth_issuer_url', E2E_ISSUER);
  upsertServerConfig('oauth_enabled', 'true');
});

// Never leave OAuth switched on, the issuer changed or fixture clients behind. Failures are NOT swallowed.
After({ tags: '@REQ-2026-017' }, async () => {
  upsertServerConfig('oauth_enabled', 'false');
  if (priorIssuer === null) deleteServerConfig('oauth_issuer_url');
  else upsertServerConfig('oauth_issuer_url', priorIssuer);
  clearOAuthClientsByIdPrefix(CLIENT_PREFIX);
});

// ─── helpers ───────────────────────────────────────────────────────────────────

function authorizeQuery(clientId: string): Record<string, string> {
  return {
    response_type: 'code',
    client_id: clientId,
    redirect_uri: REDIRECT_URI,
    scope: 'openid',
    state: 'e2e-state',
    code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    code_challenge_method: 'S256',
  };
}

function unknownClient(label: string, acceptLanguage: string | null, method: 'GET' | 'POST' = 'GET'): Planned {
  return { label, method, query: authorizeQuery(UNKNOWN_CLIENT), acceptLanguage };
}

/** "Accept-Language: de-AT,de" => "de-AT,de" (the step texts carry the whole header line). */
function headerValue(line: string): string {
  return line.replace(/^\s*Accept-Language:\s*/i, '');
}

async function doFetch(request: APIRequestContext, planned: Planned): Promise<Fetched> {
  const url = `${NEBU_BASE_URL}${AUTHORIZE_PATH}?${new URLSearchParams(planned.query).toString()}`;
  const headers: Record<string, string> = {};
  if (planned.acceptLanguage !== null) headers['Accept-Language'] = planned.acceptLanguage;
  const res: APIResponse =
    planned.method === 'POST'
      ? await request.post(url, { headers, maxRedirects: 0 })
      : await request.get(url, { headers, maxRedirects: 0 });
  return { planned, status: res.status(), headers: res.headers(), body: await res.text() };
}

async function fetchPlan(request: APIRequestContext): Promise<void> {
  fetched = [];
  for (const p of plan) fetched.push(await doFetch(request, p));
}

function htmlLang(body: string): string | null {
  return /<html lang="([^"]*)"/.exec(body)?.[1] ?? null;
}

function tagText(body: string, tag: string): string {
  const m = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)</${tag}>`).exec(body);
  return m ? m[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim() : '';
}

function dataError(body: string): string | null {
  return /<main[^>]*data-error="([^"]*)"/.exec(body)?.[1] ?? null;
}

function inlineStyle(body: string): string {
  const all = [...body.matchAll(/<style>([\s\S]*?)<\/style>/g)];
  expect(all.length, 'exactly one inline <style> block').toBe(1);
  return all[0][1];
}

// ─── Scenario: An error page follows the browser language ─────────────────────

Given(
  /^a request to \/oauth2\/authorize with an unknown client and the header "([^"]+)"$/,
  async ({}, header: string) => {
    plan = [unknownClient('unknown client (browser language)', headerValue(header))];
  },
);

When('the error page is rendered', async ({ request }: { request: APIRequestContext }) => {
  await fetchPlan(request);
});

Then(
  /^it is German \(html lang "de", German title, heading and explanation\) and keeps data-page "oauth-error" and data-error "unknown_client"$/,
  async ({ request }: { request: APIRequestContext }) => {
    expect(fetched).toHaveLength(1);
    const { body, status } = fetched[0];
    expect(status).toBe(400);
    expect(htmlLang(body)).toBe('de');
    expect(body).toContain('<main data-page="oauth-error" data-error="unknown_client">');

    // The same page without a language header is the English reference: every text part must differ from it.
    const en = await doFetch(request, unknownClient('english reference', null));
    expect(htmlLang(en.body)).toBe('en');
    for (const tag of ['title', 'h1', 'p']) {
      expect(tagText(body, tag), `German <${tag}> is not blank`).not.toBe('');
      expect(tagText(body, tag), `German <${tag}> differs from English`).not.toBe(tagText(en.body, tag));
    }
    expect(tagText(body, 'h1')).toMatch(/\b(nicht|ist|sind|Sie|Ihr\w*|Anmeldung|App|die|der|das|und|diesem|Server)\b/);
  },
);

// ─── Scenario: Unknown, missing or malformed language falls back to English ───

Given(
  /^requests with "([^"]*)", no Accept-Language header, and the garbage value "([^"]*)"$/,
  async ({}, unsupported: string, garbage: string) => {
    garbageValues = [headerValue(unsupported), garbage];
    plan = [
      unknownClient('unsupported language', headerValue(unsupported)),
      unknownClient('no Accept-Language header', null),
      unknownClient('garbage Accept-Language', garbage),
    ];
  },
);

Then(
  /^each page is English with html lang "en", the value is never echoed into the body or any header, and the response is still 200 \/ the original status$/,
  async () => {
    expect(fetched).toHaveLength(3);
    for (const f of fetched) {
      expect(f.status, `${f.planned.label}: the original status of unknown_client`).toBe(400);
      expect(htmlLang(f.body), `${f.planned.label}: html lang`).toBe('en');
      expect(dataError(f.body)).toBe('unknown_client');
      expect(f.headers['location'], 'an error page is never a redirect').toBeUndefined();
      for (const g of garbageValues.filter((v) => v.length >= 4)) {
        expect(f.body, `${f.planned.label}: the value is never echoed into the body`).not.toContain(g);
        for (const [name, value] of Object.entries(f.headers)) {
          expect(value, `${f.planned.label}: the value is never echoed into header ${name}`).not.toContain(g);
        }
      }
    }
    // all three render the same English page
    expect(fetched[1].body).toBe(fetched[0].body);
    expect(fetched[2].body).toBe(fetched[0].body);
  },
);

// ─── Scenario: Every page wears the Nebu look without loosening the CSP ───────

Given('any page rendered by the shell', async () => {
  plan = [unknownClient('unknown client', null), unknownClient('unknown client (de)', DE_HEADER), unknownClient('method not allowed', null, 'POST')];
});

When('its HTML and headers are inspected', async ({ request }: { request: APIRequestContext }) => {
  await fetchPlan(request);
});

Then(
  /^it shows the inline hexagon-N logo, uses the dark Obsidian tokens and a prefers-color-scheme light variant, has exactly one inline style allowed by its SHA-256 in the CSP, loads no external resource or font, and the CSP is not looser than before$/,
  async () => {
    expect(fetched.length).toBeGreaterThan(0);
    for (const f of fetched) {
      const where = f.planned.label;
      expect(f.status).toBeGreaterThanOrEqual(400);

      // logo: inline SVG, never an <img>
      expect(f.body, `${where}: inline logo`).toMatch(/<svg\b/);
      expect(f.body).not.toMatch(/<img\b/i);

      // Obsidian tokens (DESIGN.md section 4) + light variant
      const style = inlineStyle(f.body);
      for (const hex of ['#111827', '#1f2937', '#f9fafb', '#f97316', '#f3f4f6', '#c2410c']) {
        expect(style.toLowerCase(), `${where}: token ${hex}`).toContain(hex);
      }
      expect(style).toMatch(/@media\s*\(\s*prefers-color-scheme:\s*light\s*\)/);
      expect(style).toMatch(/:focus-visible/);

      // one style, no external resource or font
      expect(f.body).not.toMatch(/\sstyle\s*=/i);
      expect(f.body).not.toMatch(/(src|href|action)\s*=\s*["']?(https?:)?\/\//i);
      expect(style).not.toMatch(/url\(|@import|@font-face/i);

      // CSP: exactly the style hash, nothing looser
      const csp = f.headers['content-security-policy'] ?? '';
      const hash = createHash('sha256').update(style).digest('base64');
      const directives = Object.fromEntries(
        csp
          .split(';')
          .map((d) => d.trim())
          .filter(Boolean)
          .map((d) => {
            const [k, ...v] = d.split(' ');
            return [k, v.join(' ')];
          }),
      );
      expect(directives['default-src']).toBe("'none'");
      expect(directives['style-src']).toBe(`'sha256-${hash}'`);
      expect(directives['base-uri']).toBe("'none'");
      expect(directives['form-action']).toBe("'none'");
      expect(directives['frame-ancestors']).toBe("'none'");
      for (const k of Object.keys(directives)) {
        expect(['default-src', 'style-src', 'base-uri', 'form-action', 'frame-ancestors', 'img-src'], `${where}: unexpected CSP directive ${k}`).toContain(k);
      }
      expect(csp).not.toMatch(/unsafe-|font-src|script-src|\*/);
      expect(f.headers['x-frame-options']).toBe('DENY');
      expect(f.headers['cache-control']).toContain('no-store');
    }
  },
);

// ─── Scenario: The catalog is complete in both languages ──────────────────────

// The authoritative completeness check is the ExUnit test (every key and every code); here the codes reachable over HTTP without an IdP
// are rendered in both languages as a black-box smoke test of the same property.
Given('the string catalog and the code lists of the error pages', async () => {
  plan = [];
  for (const lang of [null, DE_HEADER]) {
    plan.push(unknownClient(`unknown_client / ${lang ?? 'en'}`, lang));
    plan.push(unknownClient(`method_not_allowed / ${lang ?? 'en'}`, lang, 'POST'));
    plan.push({ label: `invalid_request / ${lang ?? 'en'}`, method: 'GET', query: {}, acceptLanguage: lang });
  }
});

When('the completeness test runs', async ({ request }: { request: APIRequestContext }) => {
  await fetchPlan(request);
});

Then(
  /^every key has a non-empty English and German text, every error code has title, heading, explanation and actions in both, and a missing key fails the build instead of rendering a blank$/,
  async () => {
    expect(fetched).toHaveLength(6);
    const byCode: Record<string, Fetched[]> = {};
    for (const f of fetched) {
      const code = dataError(f.body);
      expect(code, `${f.planned.label}: an error page with a data-error hook`).not.toBeNull();
      expect(f.status).toBeGreaterThanOrEqual(400);
      (byCode[code as string] ??= []).push(f);

      const lang = f.planned.acceptLanguage === null ? 'en' : 'de';
      expect(htmlLang(f.body), f.planned.label).toBe(lang);
      for (const tag of ['title', 'h1', 'p', 'strong']) {
        expect(tagText(f.body, tag), `${f.planned.label}: <${tag}> is not blank`).not.toBe('');
      }
      expect(f.body).not.toMatch(/What you can do/i);
      expect(f.body).not.toMatch(/translation missing|missing translation|#\{|%\{|\{\{|\bnil\b|\bundefined\b/i);
      expect(f.body).not.toMatch(/<(title|h1|p|li|strong|summary)\b[^>]*>\s*<\/\1>/);
    }
    for (const [code, pair] of Object.entries(byCode)) {
      expect(pair, `code ${code} rendered in both languages`).toHaveLength(2);
      const [en, de] = pair[0].planned.acceptLanguage === null ? pair : [pair[1], pair[0]];
      for (const tag of ['title', 'h1', 'p', 'strong']) {
        expect(tagText(de.body, tag), `${code}: <${tag}> translated`).not.toBe(tagText(en.body, tag));
      }
    }
  },
);

// ─── Scenario: Request-derived values stay inert and the page stays accessible ─

Given(
  /^an error page that shows the unverified app website host "([^"]+)"$/,
  async ({}, host: string) => {
    pendingClientId = `${CLIENT_PREFIX}pending`;
    insertOAuthClient({
      clientId: pendingClientId,
      status: 'pending',
      redirectUris: [REDIRECT_URI],
      applicationType: 'web',
      clientUri: `https://${host}/`,
    });
    plan = [];
    fetched = [];
    garbageValues = [host];
  },
);

async function openPending(page: Page, acceptLanguage: string | null): Promise<void> {
  await page.setExtraHTTPHeaders(acceptLanguage === null ? {} : { 'Accept-Language': acceptLanguage });
  const url = `${NEBU_BASE_URL}${AUTHORIZE_PATH}?${new URLSearchParams(authorizeQuery(pendingClientId)).toString()}`;
  const res = await page.goto(url, { waitUntil: 'domcontentloaded' });
  expect(res?.status(), 'the pending-client page is the authorize response itself').toBe(403);
}

/** WCAG 2.1 contrast of every visible text element against its effective background, in the browser (real cascade, real theme). */
async function minTextContrast(page: Page): Promise<number> {
  return page.evaluate(() => {
    const parse = (c: string): [number, number, number, number] => {
      const m = /rgba?\(([^)]+)\)/.exec(c);
      if (!m) return [0, 0, 0, 0];
      const p = m[1].split(',').map((x) => parseFloat(x));
      return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
    };
    const lum = ([r, g, b]: number[]) => {
      const f = (v: number) => {
        const c = v / 255;
        return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
      };
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
    };
    const bgOf = (el: Element | null): [number, number, number, number] => {
      for (let e = el; e; e = e.parentElement) {
        const c = parse(getComputedStyle(e).backgroundColor);
        if (c[3] > 0) return c;
      }
      return [255, 255, 255, 1];
    };
    let min = 21;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!n.textContent || !n.textContent.trim()) continue;
      const el = n.parentElement;
      if (!el || ['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(el.tagName)) continue;
      const fg = parse(getComputedStyle(el).color);
      const bg = bgOf(el);
      const l1 = lum(fg);
      const l2 = lum(bg);
      min = Math.min(min, (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05));
    }
    return min;
  });
}

When('it is rendered in German and in English', async ({ page }: { page: Page }) => {
  // the rendering itself happens per language in the Then step (one navigation each); a first request proves the page exists
  await openPending(page, null);
});

Then(
  /^the host is HTML-escaped plain text, there is one main and one h1, the text contrast is at least 4\.5:1 in both themes, the focus outline is visible and the layout works at 320 px$/,
  async ({ page }: { page: Page }) => {
    const host = garbageValues[0];
    for (const [accept, lang] of [
      [null, 'en'],
      [DE_HEADER, 'de'],
    ] as const) {
      await openPending(page, accept);
      const where = `lang ${lang}`;
      await expect(page.locator('html')).toHaveAttribute('lang', lang);

      // the host is text, never markup
      await expect(page.locator('main')).toContainText(host);
      await expect(page.locator('main img, body img')).toHaveCount(0);
      await expect(page.locator('main a')).toHaveCount(0);
      await expect(page.locator('main')).toHaveCount(1);
      await expect(page.locator('h1')).toHaveCount(1);

      // layout at 320 px: no horizontal scroll
      await page.setViewportSize({ width: 320, height: 640 });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow, `${where}: no horizontal scroll at 320 px`).toBeLessThanOrEqual(0);

      // contrast in both themes
      for (const scheme of ['dark', 'light'] as const) {
        await page.emulateMedia({ colorScheme: scheme });
        const ratio = await minTextContrast(page);
        expect(ratio, `${where}/${scheme}: text contrast`).toBeGreaterThanOrEqual(4.5);
      }

      // the focus outline is defined (the page has no control to focus, so the rule itself is inspected)
      const html = await page.content();
      expect(inlineStyle(html), `${where}: focus-visible outline`).toMatch(/:focus-visible[^{]*\{[^}]*outline/);
    }
  },
);
