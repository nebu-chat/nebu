# Oracle Compliance Verdict: sso-redirect-error-page-html-response

## VERDICT: CLEAR (with 3 non-blocking notes)

## Applicable spec (CS API v1.18)
- Endpoints: `GET /_matrix/client/v3/login/sso/redirect`, `GET /_matrix/client/v3/login/sso/redirect/{idpId}` (spec lines 53992-54168; added v1.1, `action` added v1.18)
- Rule: standard-error-response — "Any errors which occur at the Matrix API level MUST return a standard error response" (`{errcode,error}` JSON) — spec line 3389
- `M_INVALID_PARAM` is a documented common errcode (request param invalid); correct HTTP status is 400
- SSO flow: client "instructs the browser to navigate to this endpoint" (line 53982); server MUST respond with 302 redirect or IdP-selection page; no JSON success body is defined for these endpoints

## Answers

1. JSON-default-when-ambiguous is correct and conservative. The MUST at line 3389 governs the error
   *envelope* for API-level callers; it does not forbid an additional representation. Defaulting to the
   byte-identical JSON envelope for missing/`application/json`/`*/*`/ambiguous Accept means every plausible
   Matrix-client-library caller still receives the exact standard error. Spec imposes nothing stricter for
   these endpoints. AC2 (byte-for-byte JSON) satisfies the MUST fully.

2. Yes — these two endpoints are uniquely legitimate. They are documented browser-navigation targets
   (line 53982), define only 302/404 responses (no JSON success schema), and the sibling 404 case is
   explicitly told the server "is encouraged to provide a user-friendly page explaining the error given the
   user will be navigated to it" (lines 54164-54166). HTML error output here is spec-endorsed in spirit; the
   400 rejection case is directly analogous to the 404 case.

3. `M_INVALID_PARAM` remains semantically correct (rejected `redirectUrl` param value). No well-known/
   discoverability contract is affected — these endpoints are not in `/.well-known` or `/versions`;
   `m.login.sso` capability advertisement is untouched (AC6/AC7). No conflict with SSO security-considerations
   (lines 54171-54280): rejecting non-allowlisted schemes is the whitelist mitigation the spec SHOULDs; only
   the response format changes.

## Non-blocking notes for dev/review

- N1: 302 redirect is the spec's normative success/404-fallback shape; the 400 rejection path is
  Nebu-specific hardening not in the spec's response table — acceptable, but keep it strictly a
  rejection-only branch (AC6).
- N2: HTML page MUST NOT be treated by the spec as a substitute for the JSON MUST — the JSON path must
  stay the guaranteed fallback (AC2 covers this; make it a regression assertion).
- N3: `action` query param (v1.18) and `idpId` path param are unrelated to the scheme-rejection branch;
  do not let content negotiation alter their handling.

## Test coverage required

- Accept `text/html` and `application/xhtml+xml` (no higher-priority JSON) -> 400, HTML body,
  `Content-Type: text/html`, headers `Content-Security-Policy: default-src 'none'` +
  `X-Content-Type-Options: nosniff` (AC1, AC5)
- Missing Accept / `application/json` / `*/*` / ambiguous multi-type -> 400, JSON body byte-for-byte
  `{"errcode":"M_INVALID_PARAM","error":"redirectUrl scheme is not permitted"}` (AC1, AC2)
- HTML-escaping: scheme containing HTML metachars -> only escaped scheme token appears; assert no
  unescaped `<`/`>`/`&`/`"` (AC3)
- Non-echo: full URL host/path/query never present in HTML body (AC4)
- Both endpoints (`/redirect` and `/redirect/{idpId}`) exercise identical negotiation
- Regression guard: allowed scheme still 302-redirects unchanged (AC6); `uia_fallback/1` and
  `.../sso/redirect/oidc` callback untouched (AC7)

## Relevant files
- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html`
  (endpoints 53992-54168; standard error 3388-3413; SSO flow 53981-53988)
