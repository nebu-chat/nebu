---
story_id: safari-fetch-metadata-compat
title: "Safari can use the strict admin / account actions: click proof for browsers that never send Sec-Fetch-User, friendly notice instead of a bare 403"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-14
branch: feature/migrate-to-oauth2
---

# Story: Safari compatibility of the strict fetch-metadata level

## Summary

Reported by the developer on the dev stack: in Safari (26.x, current macOS) no OAuth admin action works.
`POST /admin/oauth/registrations/<id>/approve` answers `403 "This action must be submitted with its button in the same
browser window..."`; the server log says `admin: request refused, the fetch metadata headers of the browser are not
those of a user-clicked form submit: sec-fetch-user`. Verified: Safari sends `Sec-Fetch-Site`, `Sec-Fetch-Mode` and
`Sec-Fetch-Dest`, but NEVER `Sec-Fetch-User` (WebKit does not implement it). `Nebu.OAuth.BrowserPost` requires all
four headers at the STRICT level (SO2), and the documentation (07-deployment "Manual verification", ADR-033 "Chrome,
Firefox and Safari send the four fetch metadata headers") claims the opposite. Safari users (macOS and iOS) cannot
approve, reject or revoke a client, cannot remove registrations in bulk, cannot save the legacy SSO trust lists
(`/admin/config`) and cannot approve a cross-signing reset on `/account`.

Owner requirement (verbatim): "das sollte auch für Safari funktionieren. Ich würde da dann eher einen Hinweis geben,
aber kein Error. Ich finde es uncool, wenn sowas nicht bei allen Browsern klappt. Das muss gefixed werden."

## Inventory (verified by grep over `server/lib`)

Strict level (all four headers; AFFECTED):

| Surface | Code | Form |
|---|---|---|
| `POST /admin/oauth/registrations/:id/approve` | `OAuthRegistrationsController.approve` -> `OAuthAdminHelpers.gate(:marker)` | `approve_confirm.html.heex` |
| `POST /admin/oauth/registrations/:id/reject` | `OAuthRegistrationsController.reject` -> `gate(:click)` | one form per row in `index.html.heex` (`data-confirm`) |
| `POST /admin/oauth/registrations/bulk-remove` | `bulk_remove` -> `gate(:click)` | `bulk_preview.html.heex` (`data-confirm`) |
| `POST /admin/oauth/clients/:id/revoke` | `OAuthClientsController.revoke` -> `gate(:marker)` | `revoke_confirm.html.heex` |
| `POST /admin/config/sso-origins`, `/sso-schemes` | `ConfigController.save_sso_origins/_schemes` -> `gate(:marker, "/admin/config")` | `config/index.html.heex` |
| `POST /account/cross_signing_reset/approve` | `Account.checked_post` -> `BrowserPost.check(strict: true)` | `account_templates/reset.html.eex` |

Lenient level (absent `Sec-Fetch-User` is accepted; NOT affected, regression tests added): `POST /oauth2/consent`
(`Consent` -> `BrowserPost.check/2`), the legacy SSO confirmation `POST` (`SsoConfirm` -> `check_fetch_metadata(:lenient)`),
the other `/account` POSTs (decline, device delete, sign-out).

## Decisions

- D1 **Click proof as the equivalent of `Sec-Fetch-User`.** `Sec-Fetch-User: ?1` only tells the server that a user
  activation caused the navigation (it separates a user-clicked submit from a scripted `form.submit()` without
  activation). A browser that never sends the header cannot say so. Replacement: every strict form carries a hidden
  field `_click_proof` (value empty by default). A small shared script sets it to `1` on a TRUSTED
  (`event.isTrusted === true`) `click` on a submit control of that form (mouse, touch, Space / Enter on the button and
  the implicit submit of Enter in a text field are all UA-dispatched, trusted clicks; `button.click()`,
  `dispatchEvent(new MouseEvent("click"))` and `form.submit()` are not), and clears it again 2 s later and on
  `pageshow`. The server accepts the proof ONLY when the other three headers are strictly correct
  (`same-origin` / `navigate` / `document`, exactly once). A same-origin script that sets the field itself is the
  accepted SO7 residual (see D2: Safari / WebKit only, and a script that today only needs to wait for any click would
  now not even need that click on WebKit).
- D2 **The proof is honoured only for WebKit browsers.** Chromium and Gecko always send `Sec-Fetch-User: ?1` on a
  user-activated navigation, so for them an absent header IS the "no user activation" signal and stays refused
  exactly as today (no downgrade for Chrome / Firefox / Edge, even if a script forges the field). A browser counts as
  WebKit when its single `User-Agent` header contains `AppleWebKit/` and none of `Chrome/`, `Chromium/`, `Firefox/`
  (Safari on macOS and iOS, and iOS browsers, which are WebKit; `CriOS` / `FxiOS` carry neither token). The
  `User-Agent` header of a navigation cannot be set by page script. An unrecognised engine that sends no header is
  refused with the existing 403 page (no hint that cannot help).
- D3 **`Sec-Fetch-User` present but not exactly `?1` (`?0`, duplicated, comma-merged, empty) stays refused**, with or
  without proof. `Sec-Fetch-Site` / `-Mode` / `-Dest` missing or wrong stays refused (older browsers, proxy
  stripping, `fetch()`, iframe, cross-origin): the lenient / strict semantics of the three other headers do not
  change; the lenient level is untouched (no proof logic).
- D4 **A missing proof is a notice, not an error.** WebKit, headers fine, header absent, no proof (JavaScript
  blocked, stale cached page without the script, content blocker): the admin gate answers `200` with the page
  `data-page="oauth-activation-unproven"` (a status notice: nothing was changed, press the button again, how to fix a
  blocked script, a link back to the page); the `/account` approve redirects to the reset page with the notice
  `activation_unproven`. Nothing is written, nothing is audited, the re-authentication marker is NOT consumed (the
  gate halts before it), a value-free WARNING names the case.
- D5 **Admin pages load the script from `app.js`** (CSP `script-src 'self'`, no inline); the `/account` reset page
  embeds the byte-identical script inline and pins it by SHA-256 (`script-src 'sha256-...'`, only on the page that
  has the approve form; every other account page keeps "no JavaScript"). The bytes live in ONE module
  `Nebu.Web.ClickProofScript`; `app.js` carries the same bytes (a test pins the equality).
- D6 No new route, no migration, no config key. `oauth_enabled` is not touched.

## Acceptance Criteria

1. `Nebu.OAuth.BrowserPost`: new `check_fetch_metadata(conn, :strict, params)` returning `:ok | :unproven | {:refused, names}`;
   `check/3` accepts the option `params:` and then may return `:unproven` (strict only). Rules: site / mode / dest strict as
   before (failures -> `{:refused, names}`); `Sec-Fetch-User`: `?1` once -> fine; present otherwise -> `{:refused, ["sec-fetch-user"]}`;
   absent -> a WebKit `User-Agent` (D2) with `params["_click_proof"] == "1"` -> `:ok`, WebKit without proof -> `:unproven`,
   any other engine -> `{:refused, ["sec-fetch-user"]}`. `check_fetch_metadata/2` and `check/3` without `params:` keep their
   exact behaviour (existing unit tests unchanged). `Nebu.OAuth` delegates the new arity.
2. `OAuthAdminHelpers.gate/3` passes the request params; `:unproven` answers 200 with the notice page (D4), logs a value-free
   WARNING, does not consume the marker and changes nothing, for every gated action: approve, reject, bulk-remove, revoke, the two
   `/admin/config` saves. The refusal page (403) stays for real mismatches; its text keeps the sentence about scripts / embedded pages (the `/admin/config` test pins it) and adds that a current Chrome, Firefox or Safari is needed. The notice page hooks: `data-page="oauth-activation-unproven"`, a `role="status"` element `data-role="activation-notice"` that says nothing was changed and what to do (reload, press again, blocked script), and `a[data-role="back-to-list"]` (the page of the action).
3. Per action and per header set: (a) Chrome set (four headers, with `Sec-Fetch-User: ?1`, no proof) -> the action works; (b) Safari
   set (three headers, WebKit UA) + proof -> works; (c) Safari set without proof -> notice page, nothing changed, repeatable;
   (d) `fetch()` (mode cors / dest empty), iframe, cross-origin, `same-site`, missing site / mode / dest, with or without proof -> refused;
   (e) `Sec-Fetch-User` present and not `?1`, with proof -> refused; a proof on a non-WebKit UA (Chrome, Firefox, no UA) without
   `Sec-Fetch-User` -> refused (D2).
4. Every strict admin form carries the hidden field `_click_proof` (approve, revoke, each reject row, bulk-remove, sso-origins,
   sso-schemes) and the admin layout loads `app.js`, which contains the shared script (byte-equal to `Nebu.Web.ClickProofScript.script/0`);
   the script is plain ES5, ASCII, comment-free, uses only a delegated trusted-click handler, no network, never submits or clicks.
5. `/account`: the reset approve form carries `_click_proof`; the reset page (only when the approve form is rendered) embeds the
   script and its CSP pins the hash; all other account pages keep the CSP without `script-src`. A Safari set without proof ->
   redirect to the reset page with the notice `activation_unproven`, nothing approved; with proof -> approved. The 403 text of the account
   page no longer says Safari 16.4 reports how the button was pressed (existing test `oauth_account_hardening_test.exs` M8 is adapted on purpose: it refuses the attacker string `<script>alert`, no longer any `<script`, because the reset page now embeds the one pinned script).
6. Regression: consent POST and the legacy SSO confirmation POST accept the Safari header set (no `Sec-Fetch-User`) exactly as before; the
   other `/account` POSTs too.
7. Existing tests that pinned "absent `Sec-Fetch-User` -> 403" keep passing because their conns carry no WebKit User-Agent; tests
   that built the strict header set stay valid; new Safari helpers live in `OAuthTestSupport` (`safari_fetch_headers/0`, `put_safari_fetch_headers/1`, `with_click_proof/1`, user agents). Names pinned by the tests: hidden input attribute `data-click-proof`, `Nebu.Web.ClickProofScript.script/0` and `csp_hash/0` (the quoted CSP source `'sha256-...'`), `BrowserPost.click_proof_param/0`; the script uses the selector `input[data-click-proof]`, capture-phase `click` and `keydown` listeners, a 2000 ms `setTimeout` and a `pageshow` listener.
8. Documentation: `07-deployment.md` (Manual verification row, SO7), ADR-033 (SO2 / SO3 / Manual verification (2), the "Safari before 16.4"
   wording), `11-risks.md`, `05-building-blocks.md` (`BrowserPost`), `08-concepts.md` if it names the headers, `follow-ups.md` (gate item,
   status, residual); the Manual verification group gets a Safari / Firefox / Chrome check of the admin actions (MANUAL, real browsers).
9. e2e (static only, Chromium): a real click on Reject posts `_click_proof=1` (scenario `@safari-click-proof`: the script works in a real engine; Approve needs the Dex re-login, the script is the same); existing scenarios unchanged.

## Out of scope

Real-browser runs in Safari / Firefox / Chrome (manual, listed in 07-deployment). Changing the strict level of any action, the lenient
level, the CSRF tokens, the re-authentication marker, the arming script of the consent / SSO decision pages. A separate origin for
Element Web (SO8).

## Notes for the dev agent

- ADR-018 / ADR-020: no new domain module; the facade is `Nebu.OAuth`. Test names under 255 characters.
- Static guard: only `BrowserPost` reads `Sec-Fetch-Mode/Dest/User` (test `browser_post_strict_test.exs`); the User-Agent read lives there too.
- `app.js` is served by `Plug.Static` with ETag revalidation; the hint page names the "reload" fix.

## Dev Agent Record

Cycle 0 (TDD, about 290 new tests in 5 files plus 3 adapted suites): AC1-AC9 implemented; code review 0 MAJOR / 6 MINOR (doc and comment drift, one condition duplicated), Kassandra CLEAN (K-1 doc qualification, K-2 proof read from the body only; 4 INFO), UX 0 blocking / 7 non-blocking (notice wording: use the link, do not reload; typed input; CLI hint for OAuth pages; child nav key; descriptive title). Cycle 1: all applied except code review M5 (diagnostic names) and UX N7 (axe e2e for the notice pages, manual). Deviations from the story text: the proof is read from `conn.body_params` (K-2); the Enter handler skips checkbox / radio; the 403 page keeps the old script sentence (an existing test pins it) and adds the browser sentence; `oauth_account_hardening_test.exs` M8 refutes `<script>alert` instead of `<script`.
Isolated CI (project `nebu-oauth`, own network and volumes; the developer's `nebu-oauth-dev` stack was not touched): 7167 tests, 24 failures, all known families (RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 3, TemporaryCaptureManager 2, WarRoom 1, SsoLogin 1, MatrixSso 1, RegressionSyncLoad 1). A first CI run aborted on a 259-character generated test name (elixir 1.19 limit 254): shortened. e2e verified statically only (bddgen + tsc). The node harness of `click_proof_script_test.exs` is skipped in the node-less CI image; it was run once on the host (all cases as expected).
MANUAL, not run (real browsers): Safari / Firefox / Chrome check of every strict action, incl. Safari with the script blocked, assistive-technology activation in Safari (07-deployment group D).
