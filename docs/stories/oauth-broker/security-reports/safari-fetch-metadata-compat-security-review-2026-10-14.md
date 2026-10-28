# Security review: safari-fetch-metadata-compat (Kassandra, SEC Gate 1, 2026-10-14)

Scope: staged diff of story `safari-fetch-metadata-compat` (37 files): `Nebu.OAuth.BrowserPost` (`check_fetch_metadata/3`, `check/3` with `params:`, `webkit?/1`), `OAuthAdminHelpers.gate/3` and the notice page, `Account.checked_post`, `AccountPages` (script, CSP hash, notice), `Nebu.Web.ClickProofScript` and its copy in `app.js`, the six strict forms, tests, ADR-033 SO9, 07-deployment, 11-risks, follow-ups cx-cz.

**Verdict: CLEAN, release granted.** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 2 LOW, 4 INFO. The design (a script-set click proof replaces `Sec-Fetch-User` for WebKit user agents only) is acceptable at the usability level, with the honest SO7 residual.

## Design assessment

- No weakening for Chrome / Firefox / Edge: `absent_user_header/2` checks `webkit?/1` first and refuses otherwise, proof or not; Chromium family UAs contain `Chrome/`, Gecko `Firefox/`; `CriOS` / `FxiOS` are real WebKit. A cross-site attacker may send `_click_proof=1` but fails on strict `Sec-Fetch-Site: same-origin`, the CSRF token and (on `/account`) the Origin rules. Page script cannot set the `User-Agent` of a navigation.
- Header variants covered by tests: duplicated / comma-merged / empty `Sec-Fetch-User`, two `User-Agent` headers, lower-case tokens.
- Notice path: stateless (halts before the marker, nothing written or audited), order CSRF -> fetch metadata -> marker, `/account` only `{csrf ok, :unproven}` reaches the notice, no reflected input, `no-store` / no-framing headers from the router, no oracle.
- `/account` CSP: header and template condition equivalent; `@csp` had no `script-src`, so no duplicate directive; the hash covers exactly the embedded bytes; attacker strings are escaped.
- Logs: the new WARNINGs are static literals (no UA, client, session, token).

## Findings

| ID | Sev | Topic | Disposition |
|---|---|---|---|
| K-1 | LOW | three places still said a scripted `form.submit()` without activation is refused (BrowserPost "does NOT stop", account.ex, SO7 first sentence) | FIXED: qualified "not on WebKit (ADR-033 SO9)" |
| K-2 | LOW | the admin gate read the proof from `conn.params` (query + body merged) | FIXED: `conn.body_params`; test: query-string `_click_proof=1` without the body field is no proof |
| K-3 | INFO | residual cy: on WebKit no click wait; strongest for the actions without a re-authentication marker (reject, bulk removal) | documented in follow-ups cy |
| K-4 | INFO | a user who overrides a Chromium UA with a Safari string leaves the Chrome-level rule voluntarily (not an attack path) | documented in follow-ups cz |
| K-5 | INFO | missing test: several pending requests -> no script, no `script-src` | FIXED (test added) |
| K-6 | INFO | Enter on any INPUT (checkbox) set the proof for 2 s | FIXED: checkbox / radio excluded (harness case added) |

Not stopped / accepted: a script on the shared origin (SO7) can set the field itself; the real fix is SO8 (own origin for Element Web).
