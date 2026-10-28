# Oracle gate: story 2 oauth-authorize-idp-delegation-code (2026-10-10)

## MUST requirements
- Auth code grant RFC 6749 4.1, PKCE S256, pre-registered redirect URIs strictly matched (loopback: any port at flow time).
- Spec fragment bullet ("Authorisation code grant") is a joint homeserver/client MUST for clients with https redirect URI; "Callback" section only SHOULD. response_mode is client-chosen: server must support BOTH modes and honour the requested one.
- Exactly one device:<id> scope token; device id charset %x21 / %x23-5B / %x5D-7E; server MAY reject short/outside-unreserved ids.
- Callback carries `state` on success and failure; failure = RFC 6749 4.1.2.1 error (+error_description/error_uri), never a Matrix error object.
- Bad/missing/unknown client_id or redirect_uri: NO redirect. Parameters MUST NOT repeat (6749 3.1); unknown params ignored.
- RFC 9207: with authorization_response_iss_parameter_supported=true every response (success+error) carries `iss`, byte-identical to metadata issuer.
- Codes short-lived, single use, bound to client, redirect URI, challenge.
- prompt=create optional; support signalled only via prompt_values_supported.

## Must be test-covered (additional to story's 25)
- Every error (invalid_request, unsupported_response_type, invalid_scope, access_denied, server_error, temporarily_unavailable, unauthorized_client) in query AND fragment form, with state + iss, no errcode.
- NEW: https redirect + response_mode=query => SUCCESS in the query (Element Web regression). https + no response_mode => fragment.
- NEW: exact js-sdk 41.3.0 scope `openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:<10 chars>` plus client `nonce` param accepted.
- NEW: `iss` equals issuer served by auth_metadata byte for byte.
- code_challenge >= 64 chars (js-sdk plain fallback labelled S256) => invalid_request.
- Device-scope count 0, 2, two identical; 255/256 byte boundary.

## Corrections / verdicts
- D10 WRONG (breaks Element Web: js-sdk hard-codes response_mode=query, Element registers https redirect). Fix: accept query+fragment for every redirect URI, honour explicit value; absent => fragment for https, query otherwise; anything else invalid_request.
- Story 3 blocker: js-sdk sends `openid` + `nonce`, validates id_token (iss=Nebu issuer, aud=client_id, nonce). Story 2 must persist client `nonce` (length cap, no control chars) and `openid_requested` in oauth_authz_requests and oauth_codes (columns in migration 000041). Story 3 must issue a Nebu-signed id_token and echo `openid` in granted scope when requested. D12: nonce stored, not forwarded to IdP.
- D6 api:* required = Nebu policy not spec MUST (label). D7 ignoring unknown tokens OK; mixed-prefix rejection = policy; granted scope keeps `openid` when requested. D8 OK, no minimum length.
- AC4b/oauth2-api.md wrong: js-sdk 41.3.0 sends `openid` + UNSTABLE prefix (urn:matrix:org.matrix.msc2967...). Keep a stable-prefix test as generic case.
- D11: not advertising prompt_values_supported is right; forward create only if IdP lists it. prompt=none should answer login_required (OIDC Core).
- D5 no consent screen acceptable (admin approval + interactive IdP login); follow-up.
- D13/D14/D15 compliant. js-sdk ignores iss. D1 deviation OK once recorded in ADR-033. AC1 JSON 404 acceptable.
