# Oracle context: matrix-uia-authdone-else-if (spec v1.18, CS API)

## Applicable spec sections
- UIA Fallback (`#fallback`, index.html:5261-5283): `GET /_matrix/client/v3/auth/<auth type>/fallback/web?session=<session ID>`
- SSO during UIA (`#sso-during-user-interactive-authentication`, index.html:54281+): server returns "the user-interactive authentication fallback completion page" after validating the IdP callback
- No api.json endpoint facts (draft has no matches); no event types, sync, e2ee or room-version rules involved

## MUST / SHOULD
- MUST: fallback "MUST return an HTML page which can perform this authentication stage"
- MUST ("must use"): the page must use this JavaScript once authentication is complete (verbatim, index.html:5274-5278):
  - `if (window.onAuthDone) {`
  - `    window.onAuthDone();`
  - `} else if (window.opener && window.opener.postMessage) {`
  - `    window.opener.postMessage("authDone", "*");`
  - `}`
- Semantics: exactly ONE notification path. onAuthDone (embedded browser) takes priority, and postMessage runs only if onAuthDone is NOT defined
- postMessage origin rule: the target origin is the wildcard `"*"` (spec-prescribed, do not narrow it). The receiver checks `ev.data === "authDone"` and `ev.origin === homeserverUrl` (spec example, index.html:5311). Origin safety is on the client side
- After the notification, the client resubmits the request with an auth dict holding only `{"session": "<session ID>"}`. The server must accept that once the stage is complete
- SHOULD: confirm the operation with the user (before the redirect or after the callback). SHOULD guard against unsolicited auth attempts (cookie set on fallback/web, checked and cleared on callback). Both are existing behaviour and must stay unchanged

## Current defect (sso_login.ex:68-69, @uia_script)
- Two independent `if`s: an embedded browser with onAuthDone AND an opener gets two notifications, so the request can be resubmitted twice. This deviates from the "must use" script
- Fix: change `@uia_script` to `else if`. `@uia_csp` (PageShell.csp_with_script, compile-time SHA-256) is then recomputed automatically

## Must be test-covered
- Byte-equal assert of the served inline script against the spec structure `if (window.onAuthDone) {...} else if (window.opener && window.opener.postMessage) {...}` (replace `=~` in sso_confirm_and_result_pages_test.exs:383-384)
- Negative: the body contains no second standalone `if (window.opener` (no double notification)
- `postMessage("authDone", "*")`: literal `"authDone"` and the literal `"*"` target
- CSP header script-src `'sha256-<base64>'` == base64(SHA-256(inline script text exactly as served in the body)). Extract it from the response body, not from the module attribute
- CSP still has `default-src 'none'`, `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'none'`. No `Cross-Origin-Opener-Policy` header (a COOP header would sever window.opener and break the popup path)
- Status 200 on the success page. The failure page (wrong IdP account) stays 403 and has NO authDone script (no onAuthDone/postMessage)
- Edge: replaying the same UIA session after success must not authorize a different action (existing session consumption, regression only)
- HTTP codes/errcodes: none new. The completion page is HTML, not a Matrix JSON error
