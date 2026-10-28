# Oracle gate story 4 oauth-token-revocation-logout (2026-10-10)
## MUSTs
Revoke: form-encoded; `token` required (AT or RT). token_type_hint binds the client only; server MAY ignore (RFC 7009 2.1: search all types). Server MUST revoke BOTH AT and RT linked to the token. Missing/wrong client_id: SHOULD still revoke (MAY warn). Responses SHOULD: 200 revoked/invalid, 401 client not authorised, 400 other; error bodies RFC 7009 2.2.1. OAuth clients must use revocation; /logout is legacy (client MUST use only the issuing API), server may still accept OAuth tokens on /logout. POST /logout: invalidates presented token, deletes its device + keys, 200 {}. POST /logout/all: invalidates EVERY token of the user (incl. caller's), deletes ALL devices + keys, no UIA. Both take EMPTY body; every JSON response has Content-Type application/json. soft_logout missing/false = session destroyed.
## Extra tests
/logout and /logout/all with no body/no Content-Type and with `{}` => 200 `{}` application/json (JsonBody must not 400); /logout/all again with dead token => 401 M_UNKNOWN_TOKEN no soft_logout; percent-encoded hex token decoded before format check and revoked, token with surrounding spaces => 200 no-op; HEAD on revoke 405, upper-case Content-Type accepted; simple browser request must get ACAO `*` on EVERY status; after revoke other users' /keys/query no longer returns the device keys, cross-signing keys untouched; revoke after DELETE /devices => 200 no-op; /logout/all by OAuth caller => other OAuth devices' RT invalid_grant; no Set-Cookie/WWW-Authenticate on revoke. Non-gating follow-up: deleting a device should put the user into device_lists.changed for peers (Nebu does it only for cross-signing, protected.ex:222-231).
## Corrections (binding decisions)
- O1 confirmed: revocation/OAuth /logout delete device + E2EE keys (R2 correct).
- O2 fine: /logout/all accepts OAuth tokens.
- R17 CORRECTION: /logout/all must delete ALL devices (and their keys) of the user per spec; do that (not only sessions).
- O3 DECISION: 200 with body `{}` and Content-Type application/json (oidc-client-ts accepts both; safer for JSON-parsing clients).
- O5 DECISION: keep /oauth2/revoke LIVE while `:disabled` and with an invalid issuer (it can only delete; Element clears local state anyway, otherwise server sessions survive); only `:unknown` config => 503 `{}`+Retry-After. Update R13 and tests. Rate limit still applies.
- R4: wording "conforms to the Matrix spec (SHOULD still revoke)", not "deliberate deviation" in ADR-033. Note: a leaked LEGACY token cannot be killed through /oauth2/revoke (accepted).
- R5-R7 correct; R11 sound (OidcPlug per-request DB lookup, no token cache); R15 fine; R16 correctly recorded deviation (gate r).
- CORS: ACAO `*` on EVERY status for revoke (simple request, no preflight needed).
- R20/AC7: `soft_logout` absent is a consistency choice (false is spec-equal); say so.
- Element Web revokes AT and RT in parallel, clears local state on failure, does not call /logout (memory of upstream); js-sdk never calls revoke.
