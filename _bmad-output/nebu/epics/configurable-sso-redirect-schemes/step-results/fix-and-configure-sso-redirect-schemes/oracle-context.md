## Matrix CS API Spec Findings — SSO redirect / `m.login.sso`

Spec: v1.18, `client-server-api/index.html` (§client-login-via-sso L53800, §get_matrixclientv3loginssoredirect L53992, §security-considerations-15 L54248, §sso-during-UIA L54281, §standard-error-response L3388)

### Endpoints in scope
- `GET /_matrix/client/v3/login/sso/redirect` (Added v1.1) — not rate-limited, no auth
- `GET /_matrix/client/v3/login/sso/redirect/{idpId}` (Added v1.1) — same, plus 404 for unknown `idpId`
- `GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=<id>` — UIA fallback; handled "in much the same way"
- Callback `/login/sso/redirect/oidc` — out of scope per story; spec does not define a distinct path

### MUST requirements
- `redirectUrl` query param is Required (both redirect endpoints); type string, URI
- Server MUST respond with 302 redirect to SSO interface (or IdP-select page)
- `{idpId}` variant MUST redirect to SSO for that IdP; MUST return 404 if `idpId` unrecognized
- Callback: homeserver MUST map SSO identity to a valid Matrix user identifier; MUST append `loginToken` to `redirectUrl` (stripping any pre-existing `loginToken`)
- Clients MUST NOT store mutable state in `redirectUrl` (client-side; not server testable)

### SHOULD (server, testable at unit level)
- SHOULD ensure login tokens are not sent to malicious clients; SHOULD confirm user consent OR whitelist known-trusted client URLs (spec explicitly endorses the allowlist approach — L54268)
- SHOULD guard against unsolicited auth attempts (pending-request cookie)
- Login token lifetime SHOULD be ~5s

### Error code for rejected redirectUrl — key finding
- No `M_INVALID_REDIRECT_URL` exists in the Matrix CS API. The spec defines NO error response schema for a disallowed/malformed `redirectUrl` on these endpoints (only 302, and 404 for bad idpId). Rejection behavior is implementation-defined.
- `M_INVALID_PARAM` (L3520: "a parameter has the wrong value") is the spec-correct, semantically-closest standard errcode for a well-formed-but-disallowed `redirectUrl`, at HTTP 400. `M_MISSING_PARAM`/400 fits an absent `redirectUrl`. This choice is spec-compliant; the spec neither mandates nor forbids it.
- Not echoing the scheme/URL in the error body is a security choice consistent with the §security-considerations-15 concerns; spec does not require echoing.

### Edge cases that MUST be test-covered
- Valid https redirectUrl → 302 (happy path, both endpoints)
- Allowlisted deep-link scheme (element, schildichat, im.fluffychat.auth) → 302
- Runtime-added scheme via sso_extra_redirect_schemes → 302; removed scheme → 400
- http localhost/127.0.0.1 → 302; http non-localhost → 400
- Denylist scheme (javascript, data, file, vbscript, blob) → 400 even if also on allowlist (denylist wins)
- Disallowed/unknown scheme → 400 M_INVALID_PARAM, body does NOT contain the scheme/URL
- Missing redirectUrl → 400 (M_MISSING_PARAM recommended)
- Unknown idpId on /redirect/{idpId} → 404
- Same validation applied identically on /auth/m.login.sso/fallback/web
- No pattern/wildcard match: near-miss scheme (e.g. element-evil, xelement) → 400 (exact-match only, RFC 8252 §8.6)

Relevant local spec file: skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html
