# UX Design: Nebu end-user pages (OAuth consent, SSO, error pages, account portal)

Author: Sally (UX) · Date: 2026-11-05 · Status: **draft for review**, no production code changed
Mockups: `mockups/consent.html`, `mockups/portal.html` (static; language / theme / scenario switches are mockup-only)
Open `mockups/*.html` in a browser (they are self-contained).

## 1. Problem

Found while testing OAuth + E2EE: the user-facing pages look unfinished and bury the one thing the
user has to decide.

- **No brand.** White page, `system-ui`, default blue `#0b57d0`. Nothing of the Nebu "Obsidian" CI.
- **No hierarchy.** The consent page shows ~9 label/value pairs, up to 3 warnings and a 3-sentence arming
  paragraph *before* Allow / Deny. The portal shows a 7-column device table (device id, last IP, ...) as the
  first thing on the landing page.
- **English only.** No locale handling in `server/lib`.
- **Four copies of near-identical CSS** in `ConsentPage`, `SsoConfirmPage`, `Pages` and `AccountPages`,
  plus three bare pages in `sso_login.ex` with no CSS and no `lang` attribute at all.

## 2. Scope: 7 pages, one shell

| # | Page | Module | Today's main problem |
|---|---|---|---|
| 1 | Consent `/oauth2/consent` | `oauth/consent_page.ex` | decision buried under 9 facts + 3 notices |
| 2 | Legacy SSO confirm | `matrix/sso_confirm_page.ex` | same pattern, same CSS copy |
| 3 | SSO login result pages ("Login Not Supported", "Authentication complete", "Authentication did not match") | `matrix/sso_login.ex` (lines ~271, 644, 661) | completely unstyled, no `lang`, no viewport meta |
| 4 | OAuth error pages (13 codes) | `oauth/pages.ex` | h1 + h2 + ul on white; no brand |
| 5 | Portal overview / profile | `account_templates/overview` + `profile` | raw dl + device table |
| 6 | Portal devices / device / delete | `devices`, `device_table`, `device`, `delete_confirm` | 7 columns; ids and IPs first |
| 7 | Portal apps / reset / errors / signed-out | `apps`, `reset`, `error` | long prose first, table second |

## 3. Design principles (apply to every page)

1. **Decision first.** The first screen at 390 x 844 contains: headline, *who is asking*, *what it gets*, the buttons.
2. **Risk is never hidden.** Anything that can change the user's decision (not-fresh login, destination
   not on the app's website, another session being signed out) is a notice **above** the app block, always visible.
3. **Everything else is "Details".** Informational facts go in a native `<details>` ("Show details" /
   "Details anzeigen"). No JavaScript, works with the strict CSP.
4. **One primary action per screen.** Only Allow is a filled orange button. Deny, Sign out and the like are outlined; destructive = red outline.
5. **Plain words.** One sentence says what happens; no protocol vocabulary ("claimed", "device id") in the main view.
6. **Never colour alone.** Notices keep icon + bold label ("Warning:" / "Achtung:").

## 4. Visual language (Nebu CI)

Source of truth is `server/assets/tailwind.config.js` (theme `nebu`) and the logo `docs/icons/icon.svg`.
The standalone pages cannot load `app.css` (CSP `default-src 'none'`, separate endpoint), so they get the same
tokens as CSS custom properties in **one shared stylesheet** (still one inline `<style>`, SHA-256 pinned).

| Token | Dark (default) | Light (`prefers-color-scheme: light`) |
|---|---|---|
| page `--bg` | `#111827` | `#f3f4f6` |
| card `--card` | `#1f2937` | `#ffffff` |
| border | `#374151` | `#d1d5db` |
| text | `#f9fafb` | `#111827` |
| muted text | `#9ca3af` | `#4b5563` |
| primary (button fill) | `#f97316`, text `#1c1917` | same |
| link / accent text | `#fb923c` | `#c2410c` |
| outline control | `#9ca3af` | `#6b7280` |
| warning bg / border / text | `#451a03` / `#f59e0b` / `#fde68a` | `#fffbeb` / `#b45309` / `#78350f` |
| error bg / border / text | `#450a0a` / `#ef4444` / `#fca5a5` | `#fef2f2` / `#b91c1c` / `#7f1d1d` |
| focus ring | `#f9fafb` 3 px, 2 px offset | `#111827` 3 px, 2 px offset |

Measured contrast (WCAG 2.1): body text 14.1:1 dark / 17.7:1 light; muted 5.8:1 / 7.6:1; button text on
orange 6.2:1; warning text 12.0:1 / 8.8:1; error text 8.5:1 / 9.2:1; orange link on card 5.2:1 (dark),
`#c2410c` on white 5.2:1 (light); outline control borders >= 4.8:1; focus ring 14:1 / 17.7:1.
All >= 4.5:1 for text and >= 3:1 for UI components. (Orange on white would only be 2.8:1, which is why the light
theme uses `#c2410c` for text and a dark focus ring.)

- **Type:** `Inter, system-ui, ...` stack. The pages do **not** load the Inter webfont (owner decision 2026-11-05); they fall back to system fonts, so no CSP change is needed.
- **Scale:** h1 1.5 rem / 600 / -0.02em, body 1 rem / 1.6, meta 0.9 rem. Radius 8 px controls, 12 px cards.
- **Logo:** inline SVG hexagon-N (allowed under `img-src 'none'`), 32 px, top of every page.
- **Layout:** single centred card, `max-width: 30rem` (consent) / `44rem` (portal), 16 px side gutters, no horizontal scroll at 320 px. Touch targets >= 44 px.
- **Forced colors:** borders on buttons, cards and notices keep a `CanvasText` border.

## 5. Page specs

### 5.1 Consent (`data-page="oauth-consent"`)

Order top to bottom:

1. Logo + "Nebu"
2. `h1` "Allow this app to use your account?" (static, never a request value)
3. Notices, **only when they apply**: `freshness-notice` (error style), `destination-notice` (error style), `replace-notice` (warning style)
4. **App block:** letter glyph + the app's claimed name + the line "Name given by the app, not verified"
5. **One sentence:** "As @user it gets **full access**: read and send messages, manage rooms, devices and encryption keys."
5b. **Device name** (story 01): a labelled line "This session will be named / Diese Sitzung heißt **Element Web (CdEfGhIj)**". When no name can be derived (client name, then website host, then ask), this becomes a required text field "Name this device" above the buttons.
6. **Buttons:** Deny (outlined, first) · Allow (orange, armed, second)
7. One short hint line under the buttons (the arming reason) + the existing `role="status"` live region + `<noscript>` line
8. Fine print: "Only allow this if you just started signing in to this app yourself."
9. `<details>` "Show details": app website, destination (`consent-destination`), session line, terms, privacy

What moved out of the first view: website, destination row (still in the DOM, still `aria-describedby` target),
session line, terms and privacy links, the 3-sentence mouse/keyboard/touch arming instructions (shortened to one line).

### 5.2 Legacy SSO confirm
Same shell and same structure as consent: h1 "Continue signing in to this app?", target origin as the app block, warning notice,
Cancel first / Continue (armed), path and user id in details. Cancelled / error pages use the error layout (5.3).

### 5.3 Error pages (`oauth-error`, `account-error`, `sso-confirm-error`)
Shell + a status icon + `h1` (what happened) + **one** sentence (why) + **one** primary suggestion as a
bold line + remaining suggestions under "More options" (`<details>`). No "What you can do" `h2`.
The 13 + 12 existing codes (`Pages` + `AccountPages`) keep their codes and their `data-error` hooks; copy is shortened and translated.

### 5.4 Account portal
- Header: logo left, "Signed in as @user" (wraps below the logo at phone width).
- Nav: Overview · Devices · Apps · Security (rename of "Profile" / "Reset identity"; "Reset identity" is
  security jargon, "Security" is the label, the page still says "Reset your encryption identity").
- **Overview:** headline, one sentence, three tiles with a live count ("3 signed in", "2 allowed"). Profile (Matrix ID, display name) in `<details>`.
- **Devices:** one **card per device** instead of a 7-column table: name, "app, last active", **Sign out** button.
  Device id, IP and "added" are in each card's `<details>`. Table semantics are replaced by a list (`<ul>`), the
  `data-role="account-device"` / `data-device-id` hooks stay on the `<li>`.
  There is **no** "This device" badge: the portal is a browser session, the server does not know which Matrix device the user is on.
- **Apps:** same card pattern (app name, website, allowed on, Withdraw button). The long explanatory paragraph becomes one sentence + details.
- **Success / problem notices:** unchanged codes and `role` (status / alert); restyled with the shared notice component.

## 6. Language (DE / EN)

- Resolution: first match of the `Accept-Language` header in {`de`, `en`}, else `en`. No cookie, no toggle (decision 2026-11-05).
- `<html lang>` follows the choice; the `<title>` is translated and stays static.
- All copy moves into one catalog module (key -> {en, de}); templates and page modules only reference keys.
  A test asserts that every key has both languages and that every `data-error` code has a translation.
- **Formal address ("Sie")** for German (owner decision 2026-11-05).
- Dates stay ISO `2026-10-02 09:14 UTC` in details; relative time ("vor 5 Minuten") in the main line. Open question Q4.
- Error responses that cannot parse the header fall back to English.

German copy for the consent page (full set is in `mockups/consent.html`):

| EN | DE |
|---|---|
| Allow this app to use your account? | Dieser App Zugriff auf Ihr Konto erlauben? |
| Allow / Deny | Erlauben / Ablehnen |
| Show details | Details anzeigen |
| Warning: You were not asked for your password just now... | Achtung: Ihr Passwort wurde eben nicht abgefragt... |
| Only allow this if you just started signing in to this app yourself. | Erlauben Sie nur, wenn Sie die Anmeldung in dieser App gerade selbst gestartet haben. |

## 7. Constraints the implementation must keep (do not regress)

These come from the existing, security-reviewed code and are what the tests pin:

1. **CSP stays strict.** One inline `<style>` allowed by SHA-256, one inline script only where one exists today
   (`Nebu.Web.ArmScript` on consent / SSO confirm, `ClickProofScript` on the reset page), `img-src 'none'`, `form-action` unchanged. The shared stylesheet changes the CSS hash: it is computed at compile time, so no manual step.
   Inline SVG logo needs no CSP change. **No webfont** unless `font-src 'self'` is added deliberately (Q3).
2. **Arming behaviour is untouched.** Allow stays `aria-disabled="true"` + `data-arm` + `form="oauth-consent-armed"`; Deny first in DOM and visual order; `data-arm-hint` and `data-arm-status` stay. Only the *visible hint text* gets shorter. The device-specific instructions (mouse / keyboard / touch) must not be lost for assistive tech: keep the full text as the `aria-describedby` target or in `<details>`, to be decided with the security reviewer (Q2).
3. **Test and e2e hooks stay:** `data-page`, `data-device`, `data-fresh`, `data-role`, `id="allow"`, `consent-destination[-label]`, `freshness-notice` / `destination-notice` / `replace-notice`, `account-device`, `sign-out`, `withdraw-grant`, `device-row-sign-out`, `notice` + `data-notice`. Text-based e2e steps ("ONE h1 ...") will need updating: `oauth_consent_page_test.exs`, `oauth_consent_flow_test.exs`, `adr_033_test.exs`, `e2e/step-definitions/oauth/*.steps.ts`.
4. **Escaping and claims.** Every request-derived value stays HTML-escaped, app-supplied URLs stay plain text (never a link), "claimed, not verified" remains visible next to the app name.
5. **Fail closed without JavaScript:** Allow stays unavailable, Deny works, `<noscript>` line stays.
6. **Accessibility:** one `<main>`, one `<h1>`, `lang` set, visible focus, 44 px targets, 320 px layout, notices with text label. Details toggles are native `<summary>` (keyboard operable).
7. **Headers unchanged:** `no-store`, `X-Frame-Options: DENY`, COOP on consent (not on SSO confirm, popup clients), referrer policies.

## 8. What the mockups verified (Playwright, 390 x 844)

- Consent, light, normal: headline, app, permission sentence and both buttons all in the first view.
- Consent, dark, German, all three notices: still readable, decision reachable after one short scroll; notices come first, as intended.
- Portal overview (light, EN + DE) and devices (dark): no horizontal scroll, buttons >= 44 px.
- Two defects found and fixed in the mockup: header text overflowing at 390 px, and a CSS selector that restyled the German/English spans inside tile titles. Both are worth a visual regression check in the real implementation.
- **Not verified:** the arming script (mockup does not include it), `forced-colors` rendering, 320 px width, real screen reader output.

## 9. Open questions

- ~~Q1 "Sie" or "du"~~ **Decided 2026-11-05: "Sie".**
- **Q2 Arming hint:** shorten the visible text to one line and keep the full text in a visually hidden element for screen readers. Default written into story 03; needs Kassandra's view (ADR-033 FR21).
- ~~Q3 Inter webfont~~ **Decided 2026-11-05: do not load it.**
- **Q4 Relative times** ("active 5 minutes ago"): default in story 05 is relative up to 7 days, then ISO date, absolute UTC in details. Owner may veto.
- **Q5 Language switch:** none for now. If users report wrong language, add `?lang=` later.
- ~~Q6 Device rename in the portal~~ **Decided 2026-11-05: yes, as story 06.**

## 10. Suggested delivery (for `/nebu-pipeline`)

Server code is pipeline-protected, so implementation goes through stories, not direct edits. Epic `oauth-pages-redesign`, stories in `docs/stories/oauth-pages-redesign/` (run in file order):

1. **01-device-naming-chain** (pre-story, REQ-2026-016): device name from the client's own Matrix name, else the registry's `client_name`, else the `client_uri` host, else ask on the Allow page; shown on Allow and in every device list. Minimal UI on the existing consent page.
2. **02-page-shell-and-i18n** (REQ-2026-017): shared shell, tokens, logo, DE/EN catalog and locale; the 13 OAuth error pages as first consumer.
3. **03-consent-page-redesign** (REQ-2026-018): page 1, carrying the device-name line and field from story 01.
4. **04-sso-confirm-and-result-pages** (REQ-2026-019): pages 2 and 3, including the "Authentication complete" page whose inline script must stay CSP-allowed.
5. **05-portal-redesign** (REQ-2026-020): pages 5 to 7 (cards instead of table, tiles, notices).
6. **06-portal-rename-device** (REQ-2026-021): rename a device in the portal (freshness-gated, Matrix-domain call), the repair path for existing unnamed devices.

Work happens in the worktree `.claude/worktrees/feature-better-accounts-ux` on branch `feature/better-accounts-ux` (off `main` 697e2cd9).

`ui:true` applies: UX reviewer gate, Playwright checks at 320 / 390 / 1280 px in both themes and both languages.
