## Security Review — oauth-pages-redesign / 03-consent-page-redesign

**Diff scope:** staged diff. Server: `server/lib/nebu/oauth/consent_page.ex` (OAuth consent page rendered through the shared `PageShell`, texts in English and German from `PageText`, new layout with a collapsed `<details>`), `server/lib/nebu/web/page_shell.ex` (consent CSS, optional `:script` slot), `server/lib/nebu/web/page_text.ex` (`consent.*` texts). Also tests and e2e steps.
**Date:** 2026-11-05
**Prescan:** `sec-candidates.md` had 0 candidates.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/oauth/consent_page.ex `render/3`, `details/4` | Consent hardening reduced: the redirect destination for loopback and private-scheme targets ("an app on this device … Nebu cannot check which app receives this") is now only inside the collapsed `<details>`. It is also no longer in Allow's `aria-describedby`. | Consider an always-visible notice (or a describedby entry) for `:loopback` / `:private` targets, like the https mismatch notice. Not blocking; the change follows design 5.1. |

### Detail

**Finding #1: native-app destination hidden by default** [LOW]
Before this change, the destination row was always visible and part of Allow's accessible description. Now the visible risk notices are freshness, an https host that does not match `client_uri`, and replace. Loopback and private-use-scheme redirects get no visible notice. The "Nebu cannot check which app receives this" caveat only shows after expanding "Show details". This is not directly exploitable: redirect_uri validation and registration are unchanged. It is a defense-in-depth step back against consent phishing by a malicious native or loopback client with a spoofed `client_name`. The "Name given by the app, not verified" line partly offsets this.

### Verified (no finding)

- **XSS:** every app-controlled or user-controlled value is escaped with `PageShell.esc` (Plug.HTML.html_escape) before it is inserted. This covers client_name (control and format characters also removed), client_uri host, tos/policy URIs (plain text, not links), user_id, device_id, holder display name, derived device name (cut at 80), csrf_token, and host/port/scheme. The catalog texts are escaped by `t/2`.
- **Placeholder filling** (`fill/3`): a single `Regex.replace` pass over the escaped template. Substituted values are never scanned again, so a value containing `{site}`/`{id}` cannot cause a second substitution. `Map.fetch!` on a missing key is a crash at build time or in tests, not an injection.
- **Language:** `Locale.from_conn` only returns `:en`/`:de`, and the `PageShell.render` guard enforces this. `lang` in `<html lang>` cannot be injected. `<title>` is static catalog text.
- **CSP:** `@css = PageShell.css()`, and the shell emits exactly `<style>#{@css}</style>`, so the style hash matches. The pinned `@script` is unchanged; it moved after `</main>` but its hash is unchanged. `img-src 'none'` still holds (inline SVG icons only). frame-ancestors, base-uri and form-action are unchanged.
- **CSRF / decision flow:** the hidden `csrf_token`, POST `/oauth2/consent`, Deny `formnovalidate`, and Allow's `form="oauth-consent-armed"`, `aria-disabled` and arming are unchanged. Deny comes first in the DOM, so Enter denies (fail-safe).
- No new routes, no SQL, no crypto changes (sha256 for CSP hashes only), no logging.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 1 — advisory

**Verdict:** APPROVED
