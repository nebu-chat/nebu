---
story_id: consent-arming-hardening
title: "OAuth consent page: arm Allow with the shared Nebu.Web.ArmScript (pointer must travel onto Allow after arming) (epic SEC gate 3, G3-5)"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

## Summary

Epic SEC gate 3 (`docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-2026-10-13.md`, finding
**G3-5, LOW**): the double-click arming of the OAuth consent page (`server/lib/nebu/oauth/consent_page.ex`, ADR-033 FR21) is
beatable by a multi-gesture lure. Its private inline script enables Allow (`disabled` -> `a.disabled=false`) after a pointer move
of >= 4 px (or a key press, a wheel or a scroll event) and a 600 ms dwell. A lure that first makes the victim move the pointer and
wait, and then asks for a second click at the Allow position, arms the button while the pointer is already parked over Allow.
The gate's hardening idea was "accept Allow only after a `pointerenter` onto it that follows arming".

The story `legacy-sso-redirect-confirmation` (commit c72db5d0, D9, review cycles 1 and 2) already built that rule, in a stronger
form, as the shared, generic ES5 script `Nebu.Web.ArmScript` (`server/lib/nebu/web/arm_script.ex`). It uses a `pointermove` of
type mouse / pen with non-zero movement over the button after arming. It does not use `pointerenter`, because a layout or scroll
change under a parked pointer also fires `pointerenter`. The SSO confirmation page uses that script together with an accessible
markup contract: `data-arm`, `aria-disabled` instead of `disabled`, a visible hint, a polite live region, `focusin` arming,
keyboard activation only after the focus moved onto the button after arming, a touch path, a `hashchange` reset, and the
`form="..."` detach trick for no-JS. That story deliberately left the consent page unchanged.

This story moves the consent page onto the same script and the same markup contract. It deletes the private script and closes
G3-5, recording the remaining touch and keyboard residuals honestly. All other consent page properties stay the same: content,
CSRF and binding (FR8), headers including COOP (FR10), CSP shape, and the server-side checks.

## Decisions

- **D1 One script.** The consent page embeds exactly `Nebu.Web.ArmScript.script()` (module attribute
  `@script Nebu.Web.ArmScript.script()`, as `Nebu.Matrix.SsoConfirmPage` does). The CSP `script-src 'sha256-...'` is computed
  from those bytes. The private `@script` and the public `ConsentPage.script/0` are DELETED (no delegate: one source of truth;
  nothing in `server/lib` calls it). `Nebu.OAuth` -> `Nebu.Web` is the allowed direction (shared infrastructure, ADR-020).
- **D2 Button label in the script's messages (shared script change).** Today the live-region texts of `ArmScript` hard-code
  "Continue" ("Continue is now available.", "Continue is not available yet.", "Move the pointer off and back onto Continue, then
  click.", "Move the focus off and back onto Continue, then press Enter."). On the consent page they would name a button that
  does not exist. The script therefore takes the name from the armed element's own text: `var n=(b.textContent||"")`, trimmed
  with `.replace(/^\s+|\s+$/g,"")`, falling back to `"This button"`. The messages become `n+" is now available."` and so on,
  with the same wording. Plain ES5 and ASCII, and the text goes only into the existing live region via `textContent`. The SSO
  page's visible behaviour and its e2e texts stay byte-identical because its button text is "Continue". Its CSP hash changes,
  but it is computed from `script/0`, so nothing is pinned. The rejected alternative was a `data-arm="<label>"` value (a second
  source of truth next to the visible label, WCAG 2.5.3 label-in-name).
- **D3 Markup contract of Allow (same as SSO Continue).** `<button type="submit" name="decision" value="allow" id="allow"
  form="oauth-consent-armed" aria-disabled="true" aria-describedby="arm-hint consent-destination[ <notice ids>]" data-arm>Allow</button>`.
  - The attribute is never `disabled`.
  - `form="oauth-consent-armed"` points at no form. Arming removes it, so with JavaScript off Allow is inert (fail closed) and
    the implicit submission of the form is Deny.
  - Deny stays first and is never `aria-disabled`.
  - The hint `<p class="hint" id="arm-hint" data-arm-hint>` is visible by default and hidden by the script on arming. Its text:
    "Allow becomes available a moment after you move the pointer, press a key, scroll, tap or move the focus. Then move onto
    Allow to use it." (the SSO wording with the button name swapped).
  - The polite live region is `<p class="hint" role="status" data-arm-status></p>` (empty).
  - noscript: "JavaScript is off, so Allow stays unavailable. Turn on JavaScript or use another browser. You can still choose
    Deny."
  - CSS: `button:disabled{...}` becomes `button[aria-disabled=true]{opacity:.6;cursor:not-allowed}`. The CSS hash is computed.
- **D4 Same UX fixes as the SSO page (UX gate B1/B2/N3/N4 of legacy-sso-redirect-confirmation).**
  - B1/B2: covered by D2/D3 (focusable, announced, hint, live region, blocked-click feedback).
  - N3: Allow is described by the hint, by the destination `<dd class="key" id="consent-destination">`, and by every warning
    block that is RENDERED. Those blocks are `id="freshness-notice"`, `id="destination-notice"` and `id="replace-notice"`, and
    the existing `data-role` values stay. The id list is built server side, so it never names an absent id.
  - N4: the three warning blocks lose `role="status"`. Static text in a live region is not announced reliably, and the only
    live region is `[data-arm-status]`. They keep the "Warning:" text label.
  - N5 (per-page titles) is already satisfied: the consent page has its own static `<title>`, and the error pages
    (`Nebu.OAuth.Pages`) have their own. No change.
  - N7 (shared CSS module) stays out of scope.
- **D5 COOP stays `same-origin` on the consent page (decided, FR10/FR21 unchanged).**
  - The SSO page dropped COOP because popup-based web clients (FluffyChat web, `window.open` + `window.opener.postMessage` from
    the target page) use the legacy SSO flow. For the OAuth flow, the clients this epic targets do not need an opener through
    the consent page: Element Web uses a full-page redirect, and the native clients (Element X, FluffyChat mobile, Element
    Desktop) use a system browser / Custom Tab / ASWebAuthenticationSession / loopback.
  - COOP also removes the whole opener class (re-navigation or fragment navigation of the consent window at a chosen moment),
    which the arming only mitigates. Both consent test suites pin it.
  - Residual: a web client that runs OAuth in a popup (for example `flutter_web_auth_2` on web) loses `window.opener` at the
    consent page, and the opener stays severed after the redirect to its callback. Its login would hang. This is NOT changed
    blind. It becomes a manual verification item (group C) plus a new non-gating follow-up row. If a supported client needs it,
    a later decision drops COOP on the consent page; the shared arming with its `hashchange` reset then carries the opener class
    as on the SSO page.
- **D6 Behaviour change accepted (documented).** `scroll` no longer arms Allow (cycle 2 LOW-2 of the SSO story), but `wheel`,
  touch elsewhere, `focusin` elsewhere and keys do. A touch-scroll starts with a `touchstart`, so touch users are not locked out.
  A mouse click on Allow now needs a real pointer movement onto Allow after arming. A keyboard Enter on Allow needs the focus to
  have moved onto Allow after arming. A blocked activation is announced in the live region.
- **D7 G3-5 is closed in the server, with an honest residual.**
  - **Mouse / pen (closed):** a pointer parked on the Allow position cannot activate it. The pointer must travel onto Allow
    after arming, while the consent page is in front. A multi-gesture lure then needs the victim to visibly move onto Allow on
    the shown consent page, which is a social-engineering case, mitigated by the page content.
  - **Touch (residual, follow-up `cp` widened to the consent page):** one touch elsewhere arms after 600 ms, and a following tap
    on Allow is accepted. A multi-tap lure with a known mobile layout can still land.
  - **Keyboard (residual):** a lure with pauses ("Tab, wait, Tab, Enter") can move the focus onto Allow after arming and press
    Enter.
  - The server never trusts the button state (FR8 checks unchanged). The arming stays a usability barrier, not an
    authorization.
- **D8** No migration, no config key, no new route, no log line, no server-side behaviour change.

## Acceptance Criteria

1. **One shared script.** The `GET /oauth2/consent` page contains exactly one `<script>` whose content is byte-identical to
   `Nebu.Web.ArmScript.script()`. The CSP `script-src` is `'sha256-<base64 SHA-256 of exactly those bytes>'`, with no
   `'unsafe-inline'`. `consent_page.ex` contains no private script: no `addEventListener` and no `~S[` / `~S'` script literal,
   it references `Nebu.Web.ArmScript`, and `Nebu.OAuth.ConsentPage.script/0` no longer exists.
2. **Allow markup (D3).**
   - Allow carries `data-arm`, `aria-disabled="true"` and `form="oauth-consent-armed"`. It does NOT carry the `disabled`
     attribute. Its `aria-describedby` starts with `arm-hint consent-destination` and names the id of every rendered warning
     block, and only those.
   - Deny comes first and has no `disabled`, `aria-disabled`, `form` or `data-arm`.
   - Exactly one element has `data-arm`, one has `data-arm-hint` (`id="arm-hint"`, without `hidden`), and one has
     `data-arm-status` (`role="status"`, empty).
   - No element with `id="oauth-consent-armed"` exists.
3. **Texts (D3).** The hint, noscript, and "Allow" button texts are exactly the D3 strings. The consent page has no other
   `role="status"` than `[data-arm-status]`. Each warning block keeps its `data-role` and its "Warning:" label, and gets the
   D4 id.
4. **Script (D2).** `ArmScript.script/0` derives the button name from `textContent` (trimmed, fallback "This button") and uses
   it in all four live-region messages. No message literally contains "Continue". The script stays plain ES5 and ASCII, contains
   no `</`, and has no network API, DOM injection, `.click(` or `submit`. Every rule pinned by
   `server/test/nebu/web/arm_script_test.exs` still holds: 600 ms, 4 px, the mouse/pen movement rule, `focusin`, touch,
   `hashchange`, no `scroll` arming, no `pointerenter`, and `.disabled` never touched.
5. **Headers unchanged (D5).** The page sends `cross-origin-opener-policy: same-origin`, `x-frame-options: DENY`,
   `referrer-policy: same-origin`, `no-store`, and the CSP shape of FR10 (only the two hashes change, both computed). The SSO
   confirmation page still sends NO COOP, and its rendered texts are unchanged.
6. **Browser behaviour (e2e, real Chromium).**
   - (a) A normal mouse user arms by moving elsewhere, moves onto Allow and clicks; the client receives the code.
   - (b) G3-5 regression: with the pointer parked over the Allow position, the page arms by movement or a key elsewhere. A
     click without a new movement over Allow does NOT submit: the page stays, and the live region says "Move the pointer off
     and back onto Allow, then click.". After a real move onto Allow the click submits.
   - (c) Keyboard: Tab to Deny (arms), Tab to Allow after arming, Enter submits. Enter on Allow while the focus was already on
     it before arming does not submit and announces the focus message.
   - (d) Touch: a tap on Allow right away does nothing; a tap elsewhere, then on Allow, submits.
   - (e) The existing consent, authorize and account e2e flows still complete.
7. **No server-side change.** The consent CSRF / binding / fetch-metadata suites and the flow suites
   (`oauth_consent_flow_test.exs`, `oauth_consent_csrf_test.exs`, `oauth_consent_logging_test.exs`) are green without edits.
   The SSO suites (`sso_redirect_confirm_*`, `arm_script_test.exs`) are green, with only the D2 test edits (AC4).
8. **Docs and follow-ups** (the security report file is NOT edited):
   - ADR-033 FR9 (warning blocks without `role="status"`), FR21 (amended: shared script, `aria-disabled`, the travel rule, and
     the D7 residuals) and Manual verification item 8.
   - `docs/architecture/07-deployment.md`: the consent paragraph ("Allow stays disabled" becomes "unavailable"), the group C
     double-click item, and the "Double-click arming residual (G3-5)" accepted risk, rewritten to the D7 residual.
   - `05-building-blocks.md`: the `Nebu.Web.ArmScript` row ("consent page not changed yet" removed) and the `ConsentPage` row
     if it mentions the script.
   - `08-concepts.md`: the "No COOP" bullet adds that the consent page keeps COOP (D5).
   - `11-risks.md`: the G3-5 wording.
   - `follow-ups.md`:
     - G3-5 is marked closed in the gate-3 section text.
     - Row `cp` is widened to "confirmation and consent pages".
     - A new row (next free id; expected `cq`, but check the file: `cf`..`cn` are reserved) records the D5 COOP / popup-client
       check as non-gating.

## Acceptance Tests

Server (`quick.sh "mix test --include integration test/nebu/oauth/oauth_consent_page_test.exs test/nebu/web/arm_script_test.exs test/nebu/matrix/sso_redirect_confirm_static_test.exs test/nebu/matrix/sso_redirect_confirm_page_test.exs"`, then `test/nebu/oauth` and `test/nebu/matrix` in full):

- `server/test/nebu/oauth/oauth_consent_page_test.exs` (adapt, no weakening):
  - Moduledoc contract: Allow is `aria-disabled` and armed by `Nebu.Web.ArmScript`.
  - ~line 106: `allow =~ ~r/\sdisabled(\s|>|=)/` becomes "Allow has `aria-disabled="true"`, `data-arm` and
    `form="oauth-consent-armed"` and does NOT match `~r/\sdisabled(\s|>|=)/`". Deny has none of the four.
  - ~line 316 "the notice is a status/alert region": now asserts each rendered warning block has its "Warning:" label and no
    `role="status"`, and that `[data-arm-status]` is the only `role="status"` (AC3).
  - ~line 345 CSP test: the inline script equals `Nebu.Web.ArmScript.script()` and the hash matches it (AC1).
  - ~lines 427-445 "M-1 / FR21": COOP stays `same-origin`. Assert the new hint, live region and noscript (AC2, AC3). Replace
    the private-script test (`ConsentPage.script`, `a.disabled=false`, the `click|submit` refute) with:
    - `function_exported?(Nebu.OAuth.ConsentPage, :script, 0) == false`;
    - the page embeds `ArmScript.script()`;
    - a static read of `lib/nebu/oauth/consent_page.ex` (strip comments) has no `addEventListener` and names
      `Nebu.Web.ArmScript` (AC1).
  - New: `aria-describedby` contents for `new` / fresh (`arm-hint consent-destination`), for `login_fresh: false` plus a
    foreign destination plus `replace` (all three notice ids), and never a non-rendered id (AC2).
- `server/test/nebu/matrix/sso_redirect_confirm_static_test.exs` ~line 128: "the OAuth consent page is NOT changed by this
  story" is inverted. It now asserts that consent_page.ex names `Nebu.Web.ArmScript` and has no `def script`. Rename the test;
  keep the reference to this story.
- `server/test/nebu/web/arm_script_test.exs`:
  - Moduledoc: the consent page now uses the script.
  - ~lines 114-120: assert `textContent`, the trim, the fallback, and the four message suffixes / prefixes
    (`" is now available."`, `" is not available yet."`, `"Move the pointer off and back onto "`, `"Move the focus off and back
    onto "`), and `refute s =~ "Continue"` (AC4).
- `server/test/nebu/matrix/sso_redirect_confirm_page_test.exs`: unchanged and green (AC5; the SSO visible texts do not change).

e2e (write and typecheck only: `tsc --noEmit` and `bddgen --tags "@oauth-consent or @oauth-authorize or @oauth-account or @legacy-sso-confirm"` from a scratchpad copy of `e2e`, see the brief):

- `e2e/features/oauth/oauth-consent.feature`:
  - Header comment: Allow is `aria-disabled` until armed by `Nebu.Web.ArmScript`.
  - Step "the consent page has one hash-pinned script and Allow starts disabled" is renamed to "... and Allow starts
    unavailable". It asserts `aria-disabled="true"` instead of `toBeDisabled()`, Deny without `aria-disabled`, and an empty
    `[data-arm-status]`.
  - New scenarios (`@oauth-consent @g3-5`):
    - "A click on Allow without moving onto it after arming does not decide" (AC6b): park the pointer at the centre of Allow
      (`page.mouse.move`), wait for the dwell, arm with a key press, `page.mouse.down()` / `up()` without a move. Then: still
      on the consent page, the live region text, no redirect. Then move off, hover, click, and the client receives the code.
    - "Allow on a touch device" (AC6d): own CDP touch steps in `oauth-consent.steps.ts`, modelled on the SSO touch steps; do
      not import module state across step files.
    - The keyboard scenario gets the negative half of AC6c (focus on Allow before arming, Enter does not submit, the announced
      text), or a separate scenario.
- `e2e/step-definitions/oauth/oauth-authorize.steps.ts`:
  - `armAllow`: move elsewhere, wait for `aria-disabled` to stop being `"true"` (no `toBeEnabled`), `page.mouse.move(4, 4)`,
    then `hover()` Allow. `decide` then clicks (AC6a).
  - "the user chooses Allow with the keyboard only": replace `toBeDisabled` / `toBeEnabled` with the `aria-disabled` checks.
    The Tab order is unchanged: an `aria-disabled` Allow is focusable, but Deny is still the first Tab stop.
- `e2e/step-definitions/oauth/oauth-account-management.steps.ts` ~line 169: clicks Allow WITHOUT arming. Today this most
  likely only passes if something else arms the old script (Playwright waits for a `disabled` button to become enabled; only a
  scroll-into-view could arm it). After this story it would be silently blocked. Arm first, the same way as `armAllow`;
  use a shared helper if the files already share one, otherwise use a local copy with a comment.
- Dex grant probes (`approveConsentIfShown` in `oauth-authorize.steps.ts`, `oauth-account-management.steps.ts`, and the inline
  one in `oauth-consent.steps.ts` ~line 102): their name regex `/^(grant access|allow|approve|confirm)$/i` also matches Nebu's
  Allow. Restrict them to the Dex approval page (`page.url()` contains `/dex/approval`, or scope the locator to Dex's form) so
  they can never click Nebu's Allow.
- `e2e/features/oauth/legacy-sso-redirect-confirmation.feature` and its steps: unchanged (texts stay "Continue ...").

## Dev Notes

Files (current state -> change -> preserve):

- `server/lib/nebu/oauth/consent_page.ex`.
  - Current: private `@script` (lines ~63-75), `def script/0` (~87-89), `@script_hash` from it, Allow `disabled`, hint
    `id="arm-hint"` with no `data-arm-hint`, no live region, notices `role="status"`, CSS `button:disabled`.
  - Change: `@script Nebu.Web.ArmScript.script()` and `@script_hash` computed from it; delete `script/0` and its `@doc`; apply
    the D3/D4 markup (`render/2`, `notice/1`, `destination_notice/2`, `replace_notice/2`, a helper building the
    `aria-describedby` list from what is rendered), the CSS and the moduledoc ("Arming Allow", "Contract").
  - Preserve: everything else, byte for byte where tests pin it. That covers `target/1`, `form_action_source/1`,
    `put_headers/2` (COOP!), the CSP shape, escaping, `data-page` / `data-device` / `data-fresh`, the dl, the texts of FR9, the
    80-char device name, and no image / link / autofocus / inline handler.
- `server/lib/nebu/web/arm_script.ex`: D2 only. Moduledoc: "used by the SSO confirmation page and the OAuth consent page", and
  the button name taken from `textContent`. Keep it free of comments inside the script and keep the ES5 / ASCII rules. Keep
  `Nebu.Web` free of `Nebu.Matrix` / `Nebu.OAuth` names (a static test checks this).
- `server/lib/nebu/matrix/sso_confirm_page.ex`: NO change. Its moduledoc sentence "Continue is now available." stays true.
- Reference for the markup: `sso_confirm_page.ex` `render_page/4` (hint, status, noscript, button attributes) and its CSS
  `button[aria-disabled=true]`.
- Tests and e2e: see Acceptance Tests. Keep test names < 200 chars (CI runs Elixir 1.19).
- Rules: ADR-020 (Nebu.OAuth may use Nebu.Web, never Nebu.Matrix internals). Logging law: no new log line. `oauth_enabled` is
  untouched. No migration.
- Pitfalls:
  - A script edit changes the hash. Never paste a hash into a test; always compute it from `ArmScript.script()`.
  - `aria-disabled` buttons are "enabled" for Playwright, so every e2e path that clicks Allow must arm first and then travel
    onto it. A Playwright `click()` moves the mouse onto the target (one `pointermove` with new coordinates), which satisfies
    the travel rule only when the pointer was not already on Allow.
  - The hint/status `<p>` elements stay INSIDE the form, before `.actions`, as on the SSO page.

## Out of scope

- The touch and keyboard residuals (D7; follow-up `cp`). Dropping COOP on the consent page (D5; the new follow-up row). A shared
  CSS module (UX N7).
- Any server-side consent logic, CSRF / binding / fetch metadata, `Nebu.OAuth.Pages` error pages, the SSO confirmation page's
  markup or texts.
- Editing the epic gate-3 security report.

## Tasks

- [x] D2: `Nebu.Web.ArmScript`: button name from `textContent` in the four messages; moduledoc (AC4)
- [x] D1/D3/D4: `ConsentPage`: shared script, private script and `script/0` deleted, Allow / hint / live region / noscript / CSS,
      notices without `role="status"` and with ids, `aria-describedby` list, moduledoc (AC1-AC3, AC5)
- [x] Tests: `oauth_consent_page_test.exs`, `sso_redirect_confirm_static_test.exs`, `arm_script_test.exs` (AC1-AC5, AC7)
- [x] e2e: `oauth-consent.feature` (+2 scenarios, keyboard negative), steps in `oauth-consent.steps.ts`,
      `oauth-authorize.steps.ts` (`armAllow`, keyboard), `oauth-account-management.steps.ts` (arm before Allow), Dex grant probes
      scoped; `tsc --noEmit` + `bddgen` clean (AC6)
- [x] Docs and follow-ups (AC8): ADR-033 FR9 / FR21 / Manual verification 8, 07-deployment (consent paragraph, group C item and
      a new group C item "a popup-based web client through the consent page (COOP, D5)", G3-5 accepted-risk paragraph),
      05-building-blocks, 08-concepts, 11-risks, follow-ups (G3-5 closed, `cp` widened, new COOP row)
- [x] Regression: `test/nebu/oauth`, `test/nebu/matrix`, `test/nebu/web` with `--include integration` (known families only)

## Manual verification (adds to 07-deployment group C)

- Double-click PoC from a test page (`window.open`, navigate the opener to a consent URL, double-click at the Allow position):
  the second click does not decide. The multi-gesture variant (move and wait first, then click at the Allow position without a
  new movement) does not decide either; record the result.
- A touch device and a screen reader (VoiceOver / TalkBack touch exploration) can reach Allow, hear the hint, and allow after
  arming. With JavaScript off, Allow is inert and Deny works.
- A popup-based web client (FluffyChat web, if it supports OAuth) through the consent page: record whether the login completes
  with COOP `same-origin` (D5).

## Dev Agent Record

### Implementation plan

1. D2 in `Nebu.Web.ArmScript`: `var n=(b.textContent||"").replace(/^\s+|\s+$/g,"")||"This button";` and the four messages built from `n`. No other script change (ES5, ASCII, no comments).
2. D1/D3/D4 in `Nebu.OAuth.ConsentPage`: `@script Nebu.Web.ArmScript.script()` with a computed `@script_hash`, private script and `script/0` deleted, CSS `button[aria-disabled=true]`, the Allow / hint / live region / noscript markup of the SSO page, `consent-destination` id, notices without `role` and with ids. The three notice helpers return `{id | nil, html}` so that Allow's `aria-describedby` is built from exactly the rendered ids (`arm-hint consent-destination` + rendered notices). Deny, COOP and every other header untouched.
3. Docs and follow-ups per AC8 (ADR-033 FR9 / FR21 / manual item 8 plus the two stale sentences in the SEC gate 3 status and L5; 07-deployment; 05; 08; 11; follow-ups).

### Test results

- Changed files plus consent flow / csrf / logging (`--include integration`): 234 tests, 0 failures.
- `test/nebu/oauth`, `test/nebu/web`, `test/nebu/matrix` (one run): 5035/5038 passed, 2 skipped; the 3 failures are known families (`Nebu.Web.RegressionSyncLoadTest`, `Nebu.Web.LogStore.RetentionTest` x2).
- `mix compile --warnings-as-errors --force`: only the pre-existing `event_dispatcher/server.ex:4961` warning.
- e2e (scratchpad copy): `bddgen` for `@oauth-consent or @oauth-authorize or @oauth-account or @legacy-sso-confirm` and for `@g3-5` clean, `tsc --noEmit` clean. Playwright itself cannot run in the isolated env.

### Completion notes

- No staged test was edited; no conflict between tests and the story.
- The SSO page is unchanged; its CSP hash changes because it is computed from `ArmScript.script/0`.
- CHANGELOG: not changed (the story does not list it).
- New follow-up rows: `cr` (popup client vs COOP, D5), `cs` (remaining unscoped Dex probes in e2e), `ct` (SSO e2e parked-pointer layout shift); `cp` widened; G3-5 closed in the gate-3 section text and the gate table with the touch / keyboard residuals.

### Review cycle 1

Applied (code review 2 MINOR, Kassandra 1 LOW + INFO, UX 9 non-blocking; tests edited test-first this cycle):

- Kassandra LOW #1: G3-5 is worded "reduced, closed for the parked-pointer double-click and multi-gesture lures with the pointer parked" in ADR-033 (FR21, SEC gate 3 status, L5), 07-deployment, 11-risks, follow-ups and the `ConsentPage` moduledoc. The moving-target "click game" lure is an accepted residual (ADR-033 FR21 and manual item 8, 07-deployment accepted risk and group C PoC item, follow-up `cp`).
- Kassandra INFO #2: tests pin that an inherited `#allow` fragment cannot activate Allow (`oauth_consent_page_test.exs`, `arm_script_test.exs`: the document `focusin` skips the armed element, the button's `focusin` counts only when armed, `arm()` resets `focused=false`); new e2e scenario `An inherited #allow fragment cannot activate Allow` (`@oauth-consent @g3-5`, fresh load via `about:blank`, no hashchange).
- Code M1: follow-up `ct` rewritten to what is true (`armAndContinue` is fine; the SSO "rests on Continue" step parks at the unarmed position on purpose, but the hint hides on arming so the scenario can pass vacuously).
- Code M2: the three Dex approval probes race `/dex/approval` against "the browser left Dex" (superset of the consent URL case, same idea as `fixtures/oauth-admin.ts`) and click only when the approval branch wins.
- Code I1: `cq` is noted as left free for the client-ip story (D12).
- UX N2/N3/N8 in `Nebu.Web.ArmScript`: arming with the focus already on the button announces "<name> is now available. Press Shift+Tab, then Tab to move back onto it."; arming removes the hint id from `aria-describedby` (restored on the `hashchange` reset); `say()` clears first and the region is cleared when the pointer / focus reaches the armed element. The SSO texts and its markup are unchanged.
- UX N4/N6/N7 on the consent page: `<dt id="consent-destination-label">`, `aria-describedby="arm-hint consent-destination-label consent-destination[ notices]"`, the new hint ("Mouse: ... Keyboard: ... Touch: ... this protects you from accidental clicks.") and the new noscript text ("... even after the steps above. ..."). These supersede the D3 hint / noscript wording and the D4 id order above; tests and ADR-033 follow the new text.
- UX N9 left as pinned. UX N1 (assistive-technology activation) is a manual pre-activation gate in 07-deployment group C (VoiceOver iOS / macOS, TalkBack, NVDA, JAWS; a failure needs a security-reviewed AT path). UX N5 is the new follow-up `cu`.
- Results: changed test files + consent flow / csrf / logging + SSO page and static tests 240/240 (before the N-series test additions 239/240 with one test-side regex mistake, fixed); `test/nebu/oauth`, `web`, `matrix`: 5039/5044 passed, 2 skipped, 5 failures all known families (`RegressionSyncLoadTest`, `OidcPlugTest` denylist, `MatrixSsoTest` callback loginToken, `RetentionTest` x2); doc tests (`adr_033_test`, revocation / client-ip docs tests) green after the final doc edits; compile: only the pre-existing `server.ex:4961` warning; e2e `bddgen` (both tag sets) and `tsc --noEmit` clean.

### File List

- `server/lib/nebu/web/arm_script.ex`
- `server/lib/nebu/oauth/consent_page.ex`
- `server/test/nebu/oauth/oauth_consent_page_test.exs`, `server/test/nebu/web/arm_script_test.exs`, `server/test/nebu/matrix/sso_redirect_confirm_static_test.exs` (ATDD)
- `e2e/features/oauth/oauth-consent.feature`, `e2e/step-definitions/oauth/oauth-consent.steps.ts`, `oauth-authorize.steps.ts`, `oauth-account-management.steps.ts` (ATDD)
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/architecture/05-building-blocks.md`, `07-deployment.md`, `08-concepts.md`, `11-risks.md`
- `docs/stories/oauth-broker/follow-ups.md`, this story file

### Change Log

- 2026-10-13: story created (create-story) from G3-5, the `legacy-sso-redirect-confirmation` story (D9, D15, review cycles 1
  and 2, UX report, Kassandra delta), `consent_page.ex`, `arm_script.ex`, `sso_confirm_page.ex`, the consent tests and e2e
  steps, ADR-033 FR8-FR10 / FR21, and 07-deployment group C.
- 2026-10-13: dev-story: ArmScript D2, ConsentPage on the shared script and markup contract, docs and follow-ups; status review.
