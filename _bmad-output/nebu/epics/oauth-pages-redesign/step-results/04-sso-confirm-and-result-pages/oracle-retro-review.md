# Oracle retro review: 04-sso-confirm-and-result-pages (commit 8e09a3d1)

## Verdict: MINOR (0 MAJOR, 1 MINOR, 4 INFO). No Matrix-visible regression in the commit; one spec divergence it re-pinned rather than introduced
- Spec: CS API v1.18 "User-Interactive Authentication API > Fallback", "SSO during User-Interactive Authentication", "Client login via SSO > Security considerations"
- Scope of the commit: presentation only (shell, i18n, CSP). Endpoints, status codes, the loginToken mint/append, redirectUrl classify and the UIA session flow are not touched

## Findings
- MINOR: sso_login.ex:68-69. The UIA completion script runs TWO independent `if`s. The spec text the page "must use" is `if (window.onAuthDone) {...} else if (window.opener && window.opener.postMessage) {...}`
  - Effect: an embedded browser that defines onAuthDone AND has an opener gets two notifications, so the request could be resubmitted twice (the second retry should fail harmlessly once the UIA session is consumed). This is old behaviour, and story AC "exactly as today" froze it again with a new CSP hash
  - To do: in a follow-up story, switch to `else if` (exact spec text) and recompute the hash (compile-time, `@uia_csp`). Pin it with a byte-equal assert in sso_confirm_and_result_pages_test.exs:383-384 (they currently use `=~`)
- INFO: postMessage("authDone", "*") wildcard target. CONFIRMED as spec-prescribed (Fallback section, verbatim). Clients must check `ev.origin === homeserverUrl` (spec example). Kassandra's note stands as accepted
- INFO: sso_login.ex:681 + page_shell.ex:112. The "Authentication complete" page went from no CSP to the shell CSP, which includes `frame-ancestors 'none'`. The spec's embedded-browser path (onAuthDone in a WebView, top-level) and popup path (window.opener) are unaffected, and there is still no COOP (test asserts this). Only clients that IFRAME the fallback would break. The spec does not mention iframes, and the IdP leg already prevents framing. Acceptable, but call it out in release notes
- INFO: sso_confirm_page.ex:139-213. The confirm page still names the redirectUrl site prominently (target origin in the app block, Cancel/Continue, CSRF, armed Continue). This satisfies the SHOULD "confirm with the user ... the site named in the redirectUrl". Moving the user id and path into a closed `<details>` does not weaken it (spec asks for the site, not the path)
- INFO: sso_login.ex:166. GET /login/sso/redirect answers 400 text/html (unsupported scheme) for browsers and 400 M_INVALID_PARAM JSON otherwise. The spec lists only 302 for this endpoint. This is old behaviour; the commit changed only the look, lang and CSP, the status is unchanged and the scheme is still escaped. Not a spec MUST
- Not in the commit / unchanged (checked): UIA mismatch stays 403 + no-store with no script (spec does not define it; fail-closed is fine); loginToken handling, m.login.sso / m.login.token, redirectUrl validation, the /redirect/{idpId} route and the `session` param of fallback/web are untouched by the diff

## What tests/matrix_compat (UIA real-client check, NOT run) should verify
- A real client (matrix-js-sdk) hits a UIA-guarded endpoint (e.g. POST /keys/device_signing/upload or DELETE /devices/{id}) and gets 401 with flows containing m.login.sso and a `session`
- Open /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id> in a popup (window.open), complete the IdP login, then on the complete page:
  - the opener receives MessageEvent data === "authDone" with ev.origin === homeserver base URL (same origin as the callback)
  - no CSP violation is reported (script hash matches in Chromium and Firefox)
  - the client retries with `auth: {session}` alone and gets 200
- Variant: inject window.onAuthDone (embedded-browser style). It is called exactly once. Today postMessage also fires if there is an opener, which is the MINOR above
- Negative: a second retry with the same session after success must not succeed a different action. A wrong IdP account gives the 403 page and no authDone
- Legacy SSO login: /login/sso/redirect?redirectUrl=https://untrusted gives the confirm page in German and English. Continue gives a 302 with exactly one loginToken (existing loginToken params removed). POST /login {type: m.login.token} succeeds once and replay is refused (403 M_FORBIDDEN)
