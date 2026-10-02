## Applicable Matrix CS API Endpoints & Behavioral Rules

- `GET /_matrix/client/v1/auth_metadata` — §server-metadata-discovery, "OAuth 2.0 authorization server metadata" (RFC 8414). No auth, not rate-limited.
- `GET /_matrix/client/v3/login/sso/redirect/{idpId}` — §get_matrixclientv3loginssoredirectidpid (idpId=`oidc`). No auth, not rate-limited.
- §authentication-api-discovery: SHOULD (not MUST) return 404 `M_UNRECOGNIZED` only when the OAuth 2.0 API is entirely unsupported — not a substitute for "upstream unreachable."
- §token-revocation (RFC 7009): client POSTs to `revocation_endpoint` sourced from auth_metadata — this field must be a real, client-usable URL.

## MUST Requirements — `auth_metadata` 200 body

- `authorization_endpoint` (URI) — **Required**
- `code_challenge_methods_supported` (array) — **Required**, MUST include `S256`
- `grant_types_supported` (array) — **Required**, MUST include `authorization_code` + `refresh_token`
- `issuer` (URI) — **Required**, RFC 8414: MUST use `https` scheme, no query/fragment
- `registration_endpoint` (URI) — **Required** (AC1 target)
- `response_modes_supported` (array) — **Required**, MUST include `query` + `fragment` (AC1 target)
- `response_types_supported` (array) — **Required**, MUST include `code`
- `revocation_endpoint` (URI) — **Required** (AC1 target)
- `token_endpoint` (URI) — **Required**
- Spec defines only 200/404 for this endpoint — **no 503 contract exists**; Nebu's fail-closed 503 (AC5) is a project-specific overlay, not spec-mandated, but also not spec-forbidden.

## MUST Requirements — SSO redirect

- `/login/sso/redirect/{idpId}`: server **MUST** respond with an HTTP redirect (302) to the SSO interface for that IdP. Spec gives no field-level rule on the URL's origin, but the `Location` target is drawn from `authorization_endpoint`, so the AC2/AC3 public-origin rewrite is transitive from the metadata endpoint's contract.

## Error codes / HTTP status / edge cases requiring test coverage

- 200 shape: all array-type MUST-fields contain their mandated minimum members (`S256`; `authorization_code`+`refresh_token`; `query`+`fragment`; `code`).
- 200 completeness: `registration_endpoint`, `response_modes_supported`, `revocation_endpoint` present and non-null even when dex's discovery document omits them (AC1) — spec allows no exception once OAuth API is advertised as supported.
- 200 origin rewrite: every URI field (`authorization_endpoint`, `token_endpoint`, `registration_endpoint`, `revocation_endpoint`, plus `device_authorization_endpoint`/`account_management_uri` if present) uses the public base URL's origin, not the internal issuer origin (AC2).
- 404 `M_UNRECOGNIZED` path (API-not-supported) must stay distinct from and unaffected by the AC5 upstream-failure path — test both independently, do not conflate.
- AC5 regression: total upstream discovery failure → 503, response body is NOT a synthesized/fabricated metadata document, NOT 200.
- AC3: 302 `Location` header host+scheme match the public base URL's authorization endpoint, not the internal issuer host — assert on the actual HTTP redirect, not just the URL-builder unit.
- AC4 regression: with no public base URL configured, both `auth_metadata` body and redirect `Location` are byte-identical to pre-fix (internal-issuer) output — needs an explicit "unset" test case.
- AC6: outbound server-to-server calls (discovery fetch, token exchange, JWKS fetch) still target the internal `oidc_issuer` URL after the change — assert on the *outbound* request URL, since AC2 rewriting must be response-serialization-only.
- AC7: bootstrap wizard POST persists the new public base URL field to `server_config`; assert no `NEBU_OIDC_*`/`NEBU_ADMIN_OIDC_*` env var is read (ADR-022).
- Edge case (not spec, but real): public base URL with/without trailing slash — rewritten URIs must remain valid absolute URIs (spec types these fields strictly as `URI`).
