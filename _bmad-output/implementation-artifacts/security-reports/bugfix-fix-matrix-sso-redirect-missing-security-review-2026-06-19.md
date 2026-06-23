# Security Review (SEC Gate 1) — bugfix-fix-matrix-sso-redirect-missing — 2026-06-19
Reviewer: Kassandra. Verdict: CLEAN/PASS — 0 CRITICAL, 0 HIGH. Cleared to commit.

New unauthenticated internet-facing Matrix client SSO: GET /_matrix/client/v3/login/sso/redirect[?redirectUrl][/{idp}] → IdP; callback mints 30s single-use opaque loginToken (pg-replicated ETS); POST /login resolves opaque → verified id_token → Matrix session.

## Verified
- ONE token-verification path: callback verifies id_token via OidcPlug.verify_token (alg allowlist no none/HS, JWKS sig, fail-closed iss/aud/exp/sub) + nonce (constant-time, fail-closed) before minting; POST /login passes any non-opaque value (incl. attacker JWT) through the SAME verify → no unverified-JWT acceptance.
- state: 128-bit random, single-use (GenServer-serialized), fail-closed on unknown/expired/forged; not a timing oracle. loginToken 256-bit, single-use, 30s TTL.
- issuer/endpoints from config/env (not request) → no SSRF to malicious IdP; OidcMetadata + code-exchange TLS verify_peer + hostname match.
- secrets: client_secret only in Basic-auth header; id_token/loginToken never logged.
- open-redirect: scheme denylist (js/data/file/vbscript/blob) + userinfo/protocol-relative/CRLF all rejected (code-review verified).
- ADR-020 cluster store (GenServer+pg), ADR-018 inline SQL, HttpPublic unauthenticated (correct — it IS login).

## Concurred residuals (accepted)
- MAJOR-1 cross-node double-redeem (async pg, sub-ms window): bounded by 30s TTL + single-use-per-node + victim's-own-token; single-node unaffected; docstring softened; true atomicity deferred.
- MINOR-1 any-https redirectUrl: inherent Matrix-SSO contract (Synapse parity); 30s single-use mitigates token-phishing.

## New findings (non-blocking)
- F-1 MEDIUM (login_token map uncapped) — FIXED in-story: symmetric @max_token_entries cap added (mirrors state cap), tests green.
- F-2 LOW: no rate-limit on POST /login at core:4000 (matrix-api-migration F-3 carry-over) — deferred.
- F-3 LOW: callback_url trusts Host/X-Forwarded-Proto (same posture as /.well-known/admin; inert with strict IdP redirect_uri registration).

## Pending verification (not code defects)
- AC4 full chain + AC5 Element SSO E2E confirmed in the combined reset+E2E run against the real stack.
