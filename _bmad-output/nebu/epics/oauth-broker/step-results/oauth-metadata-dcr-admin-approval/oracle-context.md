# Oracle context — Story 1 oauth-broker (spec v1.18)

## 1. Endpoints and MUST rules
- GET /_matrix/client/v1/auth_metadata: no auth, not rate-limited. 200 RFC 8414 document, or 404 {"errcode":"M_UNRECOGNIZED","error":...} (Matrix error shape) when OAuth not supported.
- Required fields: issuer (https, no query/fragment), authorization_endpoint, token_endpoint, revocation_endpoint, registration_endpoint.
- Required arrays (must contain at least): response_types_supported ⊇ code; grant_types_supported ⊇ authorization_code, refresh_token; response_modes_supported ⊇ query, fragment; code_challenge_methods_supported ⊇ S256.
- DCR (RFC 7591, POST registration_endpoint, JSON OAuthClientMetadata):
  - MUST support application_type web and native (default web); MUST support token_endpoint_auth_method=none; MUST ignore unknown response_types/grant_types values; MUST validate redirect_uris.
  - client_uri: https, no user/password. logo_uri, tos_uri, policy_uri: https. All other URIs on client_uri host or subdomain (port/path/query may differ).
  - Redirect URIs (all): no fragment. web: https, no userinfo, host under client_uri, urlencoded query allowed. native private-use scheme: scheme = reverse-DNS of client_uri host; no authority (single slash or none). native loopback: http on localhost/127.0.0.1/[::1] WITHOUT port at registration; any port accepted at authorize time. native claimed https: same rules as web.
  - Success: 201 with client_id plus all REGISTERED metadata values (dropped values omitted).
  - Server MUST NOT delete registrations with an active session. Dedup is spec-sanctioned and must be idempotent (clients re-register every flow).
  - CORS: MUST answer OPTIONS without running endpoint logic. Recommended: ACAO *, Methods GET, POST, PUT, DELETE, OPTIONS, Headers X-Requested-With, Content-Type, Authorization.
  - Not in spec (Nebu extensions): pending/approved/rejected, admin approval, rate limit on register.

## 2. Must be test-covered
- Metadata enabled: 200 with every required field and minimum values; issuer = Nebu https URL, not the IdP; no device_authorization_endpoint unless implemented; Cache-Control present.
- Metadata disabled: 404 errcode M_UNRECOGNIZED; OPTIONS preflight returns CORS headers, no logic.
- DCR success: 201 + client_id; unknown response_types/grant_types omitted in response; auth method none accepted; application_type omitted = web.
- Valid redirect URIs (201): com.example.app:/callback, com.example:callback, http://localhost/cb, http://[::1]/cb, https://app.example.com/cb (subdomain), https://example.com:5173/?q=v.
- Invalid redirect URIs (400 invalid_redirect_uri): #fragment, web http://, web http://localhost/, https://app.com/cb (other host), userinfo, example:/cb (not reverse-DNS), com.example.app://cb (authority), https://localhost/cb (native), http://localhost:1234/cb (port).
- 400 invalid_client_metadata: non-https/userinfo client_uri; logo/tos/policy off-host or http; unknown application_type; missing client_uri if required; unsupported token_endpoint_auth_method.
- Error body RFC 7591 3.2.2 {"error","error_description"} with NO errcode.
- Dedup: same metadata different key order → same client_id, one row; concurrent identical POSTs → one row.
- 429 + Retry-After on register (OAuth-style body, no errcode).

## Story deviations from spec v1.18 (to fix in story)
- AC1: no auth_issuer field in auth_metadata (it was a separate unstable MSC2965 endpoint); optional fields are not "SHOULD"; account_management_* / device_authorization_endpoint are v1.18 additions — do NOT advertise device_authorization_endpoint or prompt_values_supported before implemented; "all URLs https" is a Nebu rule (spec: https only for issuer).
- Gherkin: field is errcode, not error_code. Bad redirect → invalid_redirect_uri (other bad fields invalid_client_metadata), not invalid_request.
- AC2/Gherkin: response returns REGISTERED (filtered) values, not "the submitted metadata". Native claimed-https type missing; loopback no-port-at-registration rule and no-userinfo rule missing.
- AC3: hash normalized, filtered metadata (not raw body); define #lang handling before hashing.
- AC2: response_types lacking code or grant_types lacking authorization_code/refresh_token → reject (invalid_client_metadata) or define defaults (RFC default grant_types lacks refresh_token).
- AC4: error page for unknown/unusable client_id IS RFC 6749 4.1.2.1 behaviour. Rejecting a client with active sessions (later stories) must respect "MUST NOT delete".
- Inconsistencies: rejected_by/rejected_at in Gherkin but not in table; AC7 "metadata not redacted" vs "no full metadata in logs".
- Gap: /oauth2/register with OAuth off undefined → return 404 there too.
