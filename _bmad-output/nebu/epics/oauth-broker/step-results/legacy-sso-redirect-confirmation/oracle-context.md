# Oracle gate: legacy-sso-redirect-confirmation (G3-3), 2026-10-13

Verdict: PASS with 1 MAJOR and 6 MINOR (read-only review by nebu-oracle; the story was updated afterwards, see its Decisions).

## Spec anchors
- `GET /login/sso/redirect[/{idpId}]`: server MUST answer with an HTTP redirect to the SSO interface (302; 404 for an unknown IdP id). The 400 for a rejected redirectUrl is outside the spec but allowed.
- Callback: loginToken lifetime SHOULD be around five seconds; existing `loginToken` parameters of the redirectUrl "should be removed before adding the new one"; the status of the redirect to the client is not specified.
- Security considerations: homeservers SHOULD confirm with the user that they are happy to grant access to the site named in redirectUrl, either before redirecting or after login when handling the callback; whitelisting known-trusted client URLs is allowed; SHOULD guard against unsolicited authentication attempts by setting a cookie at /login/sso/redirect (follow-up ca).
- `m.login.token`: invalid token => 403 M_FORBIDDEN. M_UNRECOGNIZED: 404 for an unimplemented endpoint, 405 for a wrong method.

## Answers (client knowledge, confidence stated)
1. Element Web: redirectUrl = origin + path + current query + `#/...` fragment (may contain `@` and `#`; may carry an old `?loginToken=` after a failed token login), ASCII, < 300 bytes (medium-high).
2. Element Desktop: `element://vector/webapp/?element-desktop-ssoid=<id>#/login` (medium); `io.element.desktop:` mostly OIDC (follow-up cd).
3. Element X: no legacy m.login.sso; a rust-sdk SSO would use a loopback redirect.
4. FluffyChat: native `<scheme>://login` (possibly `im.fluffychat://login`, not the default `im.fluffychat.auth`; follow-up cd), desktop `http://localhost:3001//login`, web `https://<host>/<base>/auth.html` as a popup using `window.opener.postMessage` (low-medium).
5. SchildiChat `schildichat://`, Cinny https own origin `/login/<server>/`, Hydrogen https `#/sso`, nheko loopback, Element Android/iOS classic `element://connect`.
6. New route `/_matrix/client/v3/login/sso/confirm`: not forbidden by the spec, INFO (a vendor prefix would need nginx changes).
7. Remove old loginToken parameters: spec SHOULD, do it now.
8. 30 s loginToken lifetime vs ~5 s: keep, record the deviation in docs/matrix-api-scope.md.
9./10. 2048-byte cap and strict 400s: safe for all clients listed.
11. Post-IdP placement is spec conformant (second option of the spec). Breaks: popup clients because of COOP (M1); touch devices without pointermove (m5); JS-off WebViews see only Cancel (INFO).
12. Auto-listing approved OAuth clients is acceptable (admin approved); caveat: legacy loginToken gives a full unscoped session; say so in the admin UI/docs.

## Findings
- M1 (MAJOR): `Cross-Origin-Opener-Policy: same-origin` on the confirm page/303s cuts `window.opener` of popup-based web clients (FluffyChat web). Drop COOP on the confirm, cancel, error pages and the 303s; assert its absence; test that a popup opener survives.
- m1: `@` and `%` checks only inside the authority; accepted rows: `https://app.ex/#/user/@bob:ex.org`, `https://app.ex/#/room/#a:ex.org`, `https://app.ex/p%20q?x=%2F`, `https://app.ex?x=1#/login`, `element://vector/webapp/?element-desktop-ssoid=abc#/login`, `http://localhost:3001//login`.
- m2: numeric-looking hosts (`0x7f.0.0.1`, `2130706433`, `10.1`): require canonical dotted decimal else reject.
- m3: strip existing `loginToken` parameters in `append_login_token/2` now (rows `?loginToken=old`, `#...?loginToken`).
- m4: `https://<server_name>` is trusted automatically: document that it must be an origin the operator controls (well-known delegation case), help text + 07-deployment.
- m5: touch devices: add a touch arming path and a Playwright `hasTouch` scenario.
- m6: assert 403 M_FORBIDDEN for replayed / expired / forged loginToken at `POST /login`; the redirect leg still answers 302 for `/sso/redirect/{idpId}`.
- INFO: record route choice, 30 s lifetime, JS-required Continue, approved-client caveat, old 400 wording, unknown idpId redirected instead of 404.
