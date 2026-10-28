---
story_id: oauth-token-endpoint
title: "Token endpoint (authorization_code + refresh_token), rotation/reuse, error mapping, Nebu-signed id_token"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-10
branch: feature/migrate-to-oauth2
---

## Summary

Story 3 of epic `oauth-broker` (spec section 13 row 3; spec sections 3a, 5 step 5, 6, 10, 11). It
turns the story-2 authorization code into a working Matrix session with Nebu as authorization
server AND resource server (broker model O2, ADR-033):

1. **`POST /oauth2/token`** (RFC 6749 3.2 / 4.1.3 / 5 / 6, RFC 7636 4.6, RFC 9700): form-encoded
   only, public clients (`token_endpoint_auth_method=none`, `client_id` in the body, client must
   be `approved`), RFC 6749 5.2 error shape (`error`, `error_description`, NEVER `errcode`),
   `Cache-Control: no-store` + `Pragma: no-cache`, CORS `*`, own body cap, rate limited (but
   NEVER `429` on `grant_type=refresh_token`: throttling is `503` + `Retry-After`). EVERY 5xx
   carries `Retry-After` and a JSON body WITHOUT an `error` member (`{}`): oidc-client-ts turns any
   JSON with `error` into an `ErrorResponse`, which matrix-js-sdk treats as a logout (oracle C1).
2. **`grant_type=authorization_code`**: atomic consume of the story-2 code
   (`Nebu.OAuth.consume_authorization_code/1`), client/redirect-URI binding, PKCE S256
   (constant-time), re-check `users.is_active`, device-ID reuse rule (spec 5.1), session creation
   in `matrix_sessions` (`auth_api = 'oauth'`, hashed tokens, 15 min access token, session maximum
   `NEBU_MATRIX_SESSION_TTL_SECONDS`), code reuse => revocation of the derived session (RFC 9700).
3. **`grant_type=refresh_token`**: rotation on every use, "old refresh token valid until the new
   token is used" (spec section 6 Refresh-Retry, the 0c semantics of the legacy store), reuse of a
   consumed refresh token revokes the whole session, scope only narrowed/equal, IdP
   re-validation `oauth_idp_revalidation = per_refresh | off` (default `per_refresh`) through the
   EXISTING `revalidate_with_idp/1` and `RefreshErrors` classification: transient => `503` +
   `Retry-After` (session stays), confirmed => `400 invalid_grant` (session revoked).
4. **Nebu-signed `id_token`** (story-2 D23 obligation, matrix-js-sdk 41.3.0 validates it) whenever
   `openid` is granted: ES256 keys generated lazily and cluster-safely by Nebu, private key
   SecretBox-encrypted in `oauth_signing_keys`, public keys at `GET /oauth2/jwks`, advertised as
   `jwks_uri` in `auth_metadata`.
5. **Resource server**: the opaque OAuth access tokens authenticate Matrix requests through the
   existing `OidcPlug` opaque path (`/whoami` returns `user_id` + `device_id`), an expired access
   token answers `401 M_UNKNOWN_TOKEN` + `soft_logout: true`; the legacy IdP-JWT Bearer path, the
   legacy `POST /refresh` and the `RefreshWorker` can never act on OAuth sessions/devices.
6. **`GET /.well-known/openid-configuration`** under the issuer: Nebu's OWN metadata document
   (same content as `auth_metadata`, incl. `jwks_uri`), because matrix-js-sdk's
   `OidcTokenRefresher` fetches `new URL(".well-known/openid-configuration", issuer)` before
   every refresh (oracle C7). 404 while OAuth is disabled.

`/oauth2/revoke` stays the router's plain `404` (story 4). `oauth_enabled` stays `false` by
default and nothing in this story enables it; follow-ups.md gate items (trusted proxy, h, i, ...)
are NOT solved here and still block `oauth_enabled`.

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 2, 3a, 5,
6, 10, 11, 13; `docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (incl. the
story-2 section D1-D23); story 2 `docs/stories/oauth-broker/oauth-authorize-idp-delegation-code.md`
(Dev Agent Record, "Story-3 handover"); `docs/stories/oauth-broker/follow-ups.md` items (e), (f);
Kassandra report `docs/stories/oauth-broker/security-reports/oauth-authorize-idp-delegation-code-security-review-2026-10-10.md`
(I-3 story-3 obligations); `_bmad-output/nebu/epics/oauth-broker/step-results/oauth-authorize-idp-delegation-code/oracle-context.md`
(id_token requirement); `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`; Matrix CS API
v1.15+ "OAuth 2.0 API" ("Token endpoint", "Refresh token grant", "Token refresh"), RFC 6749 3.2,
4.1.3, 4.1.4, 5.1, 5.2, 6, RFC 7636 4.5/4.6, RFC 7638, RFC 7517, RFC 9700 2.1/2.2.2/4.14, OpenID
Connect Core 1.0 2 / 3.1.3.7 / 12.2.

## Story

As a **Matrix user of an OAuth-capable client (Element Web / matrix-js-sdk, FluffyChat / Dart
SDK)**,
I want the client to exchange the Nebu authorization code for Nebu-issued access and refresh
tokens, use them against the Matrix API and refresh them silently,
so that I stay signed in on that device for the Nebu session maximum while deprovisioning at the
IdP, a deactivation in Nebu and stolen-token reuse end the session quickly, and no IdP token ever
reaches the client.

## Decisions

Every design decision of this story (prefix `T` = token story, so the IDs never collide with the
story-2 `D1`-`D23` in ADR-033). ADR-033 gets a new section with T1-T33 (AC20).

- **T1 (module boundaries, ADR-020).** The token endpoint is OAuth domain: `Nebu.OAuth.Token`
  (orchestration + HTTP responses), `Nebu.OAuth.TokenRequest` (pure parsing/validation, PKCE,
  scope narrowing), `Nebu.OAuth.IdToken` (pure claims + signing), `Nebu.OAuth.SigningKeyStore`
  (inline SQL, `oauth_signing_keys`). Sessions live in the Matrix-owned table `matrix_sessions`,
  so every session read/write is Matrix domain: new internal modules
  `Nebu.Matrix.Session.OAuthSessionStore` (inline SQL, ADR-018) and `Nebu.Matrix.OAuthSession`
  (issuance/refresh orchestration incl. IdP re-validation), reachable from `Nebu.OAuth` ONLY via
  new `Nebu.Matrix` facade functions (AC7, AC9). `lib/nebu/oauth/*.ex` never names
  `Nebu.Matrix.Session.*`, `Nebu.Matrix.HttpPublic`, `Nebu.Matrix.DeviceKeyStore`,
  `Nebu.Web.Plugs.OidcPlug` (static test, like story 2's).
- **T2 (one table, `auth_api` column).** OAuth sessions are rows of `matrix_sessions` (spec 8:
  every session carries `auth_api = legacy | oauth`), NOT a new table: `OidcPlug`'s opaque path,
  logout (`MatrixSessionStore.revoke/1`), device deletion (`delete_for_user_device/2`), admin
  deactivation (`delete_for_user/1`) and the `mark_access_token_used/1` Refresh-Retry machinery keep
  working for OAuth sessions without a second code path. Row model identical to legacy: one row
  per token pair, a session = all rows of `(user_id, device_id)`, at most one `revoked_at IS NULL`
  row per device.
- **T3 (two expiries).** Legacy rows use `expires_at` for access AND refresh token. OAuth rows:
  `expires_at` = ACCESS-token expiry (`LEAST(now() + access_ttl, session_expires_at)`), new column
  `session_expires_at` = absolute session maximum (`now() + Nebu.Web.SessionConfig.matrix_session_ttl_seconds()`
  at code redemption, copied VERBATIM on every rotation, never extended). Because `OidcPlug` decides
  expiry by `expires_at`, the 15-minute access token and the `soft_logout` answer work unchanged.
  A refresh is allowed while `session_expires_at > now()` even when the access token expired.
- **T4 (access-token TTL).** Default 900 s (spec 14 #2), `server_config` key
  `oauth_access_token_ttl_seconds`, valid 60..3600, anything else => 900 (never "unlimited").
  Opaque tokens = `MatrixSessionStore.generate_opaque_token/0` (64 lowercase hex, no `.`, so
  `OidcPlug` routes them to the opaque path); stored ONLY as `MatrixSessionStore.hash_token/1`.
- **T5 (`idp_revalidation`).** `server_config` key `oauth_idp_revalidation`: `per_refresh`
  (default; also for absent/unknown values, fail safe) or `off`. `per_refresh` redeems the stored
  encrypted IdP refresh token on EVERY Nebu refresh through `HttpPublic.revalidate_with_idp/1`
  (decrypt + IdP exchange + `check_still_active`), classified by `RefreshErrors.transient?/1`.
  `off` re-checks only `users.is_active` (error-aware, T19). The IdP refresh token from the code row
  (`idp_rt_enc`) is stored on the session (`matrix_sessions.oidc_refresh_token`, still SecretBox
  ciphertext, never decrypted at issuance) whenever present, in both modes.
- **T6 (`per_refresh` without an IdP refresh token = fail fast at the code grant).** When the mode
  is `per_refresh` and the code row has `idp_rt_enc IS NULL` (IdP without `offline_access`,
  `matrix_oidc_refresh_mode = online`), the authorization_code grant answers `400 invalid_grant`
  ("Sign-in cannot be completed: the server is not configured for refreshable sessions.") and logs
  ONE WARNING naming the fix (`matrix_oidc_refresh_mode=offline` or `oauth_idp_revalidation=off`).
  Rejected alternatives: degrading silently to a local `is_active` check (defeats the spec's
  "deprovisioning takes effect within one access-token lifetime") or issuing a session that dies
  with `invalid_grant` at the first refresh after 15 minutes (confusing). Accepted by the oracle
  gate (C9: fail closed is fine, the bootstrap default `matrix_oidc_refresh_mode` is `offline`).
  Detecting the missing IdP refresh token already at the IdP callback, before a code is minted, plus
  an admin config warning is follow-up (l), NOT part of this story.
- **T7 (device reuse, spec 5.1 / story-2 D9).** The code's `(user_id, device_id)` may name an
  existing device of the same user. Issuance then, inside ONE transaction, deletes EVERY
  `matrix_sessions` row of that device (legacy AND oauth: "all previous access and refresh tokens
  of the device are revoked") before inserting the new row. The `devices` row and its E2EE key
  material are KEPT (device identity and crypto continuity are the point of reusing an id);
  `DeviceKeyStore.upsert_device/3` refreshes `last_seen_ts`/`last_seen_ip` (`display_name: nil`
  keeps an existing name; a new device gets no name, O5 accepted by the oracle). Legacy raw-JWT credentials
  bound to that device are killed AFTER the commit with the existing S3 kill-switch
  (`DeviceBinding.list_for_user_device/2` -> `TokenDenylist.revoke_by_hash/2` ->
  `DeviceBinding.delete_for_user_device/2`, the `Nebu.Matrix.delete_user_device/2` idiom without
  deleting the device). Different users can never collide (PK `(user_id, device_id)`).
- **T8 (code reuse => revocation, RFC 6749 4.1.2 / RFC 9700 4.2.1; bound to proof).** The session
  row stores `oauth_code_hash` (the story-2 `code_hash`, copied on every rotation), so a reused code
  revokes EXACTLY the session derived from it (`DELETE ... WHERE (user_id, device_id) IN (SELECT ...
  WHERE oauth_code_hash = $1 AND auth_api = 'oauth')`), never an unrelated earlier session of the
  same device (which revoking by `(user_id, device_id, client_id)`, as story-2 D17 sketched, would
  hit). The revocation fires only when the reused presentation passes the SAME checks as a first
  redemption (client_id, byte-equal redirect_uri, valid PKCE verifier): presenting a leaked code
  WITH its verifier proves a real compromise (the attacker may have redeemed first); presenting it
  without the verifier cannot have produced tokens, so it must not let a third party log the user
  out. Either way the answer is `invalid_grant` (the reused code is ALWAYS denied, RFC 6749 MUST).
  **Deviation (oracle C10):** gating the revocation on the verifier weakens the RFC 6749 4.1.2
  SHOULD ("revoke all tokens previously issued based on that code") for reuses without the
  verifier; ADR-033 records it as a deliberate deviation with this rationale. **Double-submit
  risk (test review):** a legitimate client that submits the SAME code twice concurrently (or a
  retry racing the first request) presents a valid proof on the losing request, so the loser may
  revoke the session the winner just received; the client then has to log in again. Accepted
  (RFC 9700 prefers revocation over a possibly stolen session); ADR-033 records it next to the C10
  deviation. Invariant (tested): exactly one 200, at most one active row, and never a live session
  row that no 200 handed out.
- **T9 (code consumption order).** The story-2 `CodeStore.consume/1` marks the code used BEFORE
  the bindings are checked (one atomic UPDATE, cluster-safe single winner). A first presentation
  with a wrong verifier/redirect/client therefore burns the code (the client restarts the login).
  Accepted, same class as the story-2 "request consumed before the binding check" property: the
  code is 256-bit, lives 60 s, travels only through the user's browser; changing the consume to a
  binding-conditional UPDATE would weaken single use semantics and the story-2 API.
- **T10 (Refresh-Retry = legacy 0c semantics, OAuth rows only).** Rotation reuses the proven
  legacy row protocol of `MatrixSessionStore.rotate_tokens/1` (soft-revoke old row with
  `grace_until = NULL` = PENDING, insert new row, `consume_pending_siblings` when the CURRENT token
  was redeemed, `FOR UPDATE` re-validation of a replayed pending token, lock order by
  `access_token_hash`). PENDING vs CONSUMED is decided ONLY by `grace_until IS NULL`/`IS NOT NULL`.
  A pending (rotated-away, unused-successor) refresh token is served by rotating the device's
  ACTIVE row again (lost-response retry); a CONSUMED one is reuse (T11). The new access token's
  first successful request consumes the pending siblings via the existing
  `OidcPlug` -> `has_open_grace_window?/1` -> `mark_access_token_used/1` path. The OAuth variant
  lives in `OAuthSessionStore` (own SQL, filters `auth_api = 'oauth'`, uses `session_expires_at`
  instead of `expires_at` for "session alive", copies `client_id`, `scope` (or the narrowed
  scope), `session_expires_at`, `oauth_code_hash`, `auth_time`, `auth_api`).
- **T11 (refresh-token reuse).** A CONSUMED OAuth refresh token whose session is still alive
  (`session_expires_at > now()` and an active row exists) => all rows of the device with
  `auth_api = 'oauth'` are deleted (session revoked, WARNING log with `client_id`, `user_id`,
  `device_id`) and `400 invalid_grant`. Independent of the presented `client_id` (the refresh token
  itself is the secret). An unknown token, a token of an expired session, a legacy refresh token
  => `400 invalid_grant` without side effects.
- **T12 (client binding of refresh tokens, RFC 6749 6).** `session.client_id` must equal the
  request's `client_id`, else `invalid_grant` (no revocation, WARNING). The client must still be
  `approved` (`invalid_client` otherwise; unreachable through the database since a decision is
  final, defensive branch).
- **T13 (scope on refresh, RFC 6749 6; oracle C3/C12).** matrix-js-sdk sends no `scope` on
  refresh, and ANY 400 logs a client out, so the comparison is lenient where the spec allows it.
  `scope` absent OR empty (`scope=`, RFC 6749 3.1: empty = omitted) => the session's granted scope
  unchanged. Present => parsed into tokens (split on spaces, empty tokens dropped, RFC 6749 3.3
  charset) and compared as a SET (order-independent, duplicates collapsed) with the Matrix tokens
  PREFIX-NORMALIZED (stable `urn:matrix:client:` == unstable `urn:matrix:org.matrix.msc2967.client:`):
  it MUST be a subset of the granted set AND still contain the `api:*` and `device:<id>` tokens
  (refusing to drop them is Nebu policy, story-2 D6) => effectively only `openid` can be dropped;
  anything else => `400 invalid_scope`, session untouched. The response `scope` is the STORED
  granted string (request prefix of the original authorize request, stored order), minus `openid`
  when it was dropped. A narrowed scope is persistent (stored on the new row; a later refresh
  cannot widen it).
- **T14 (scope echo).** The token response `scope` is the stored granted scope string verbatim
  (story-2 D23 order `[openid ]<prefix>api:* <prefix>device:<id>` with the REQUEST's prefix, spec
  3a). No normalization to the stable prefix is stored or returned (the device id is taken from the
  code row, not re-parsed).
- **T15 (id_token: when).** Issued on `authorization_code` when the granted scope contains `openid`
  (= story-2 `openid_requested`), and on `refresh_token` when the (possibly narrowed) granted scope
  still contains `openid` (OIDC Core 12.2). Without `openid` no id_token (Dart SDK path).
- **T16 (id_token: claims).** Header `{"alg":"ES256","kid":<kid>,"typ":"JWT"}`. Claims: `iss` =
  `Metadata.normalize_issuer/1` result (byte-equal to the metadata `issuer`, which matrix-js-sdk
  compares exactly), `sub` = the Matrix user id (`@alice:server`, stable, <= 255 bytes, does not
  leak the IdP `sub`), `aud` = the `client_id` as a STRING, `iat` = now, `exp` = `iat + 300`,
  `auth_time` = the session's `auth_time` (from the code row; omitted when NULL), `nonce` = the
  code row's `client_nonce` ONLY on the authorization_code grant and only when present (OIDC Core
  12.2: a refreshed id_token SHOULD NOT carry `nonce`). Nothing else (no email/name: data
  minimization; no `at_hash`/`azp`, optional for the code flow). On refresh `iss`, `sub`, `aud` and
  `auth_time` are identical to the first id_token, `iat`/`exp` are new, no `nonce`. Confirmed by the
  oracle (C4): oidc-client-ts compares `sub`/`auth_time`/`azp` only when a stored id_token is passed,
  the js-sdk refresher passes none, so on refresh only `sub` must exist; no `nonce`/`at_hash`/`azp`
  is needed and signatures are never verified client side. Code-grant checks of matrix-js-sdk
  (C5): id_token present, `iss === issuer` exactly, `aud` (string or array) includes client_id,
  `nonce` equals the stored one, `exp` present and in the future, `sub` present.
- **T17 (signing key: ES256, Nebu-generated, encrypted at rest; SAFE variant).** Algorithm fixed
  `ES256` (P-256): small keys and signatures, supported by every JOSE library and by oidc-client-ts.
  Rejected: **HS256** (a shared secret per client cannot exist for public clients, and a verifier
  holding the secret could forge tokens), **RS256** (2048+ bit keys, slower generation, no benefit
  here), **EdDSA** (not universally supported by browser JOSE stacks), **reusing the IdP's keys**
  (Nebu cannot sign with them; broker model). Keys are generated by `JOSE.JWK.generate_key({:ec,
  "P-256"})` (`:jose` 1.11 is already a dependency), `kid` = RFC 7638 thumbprint
  (`JOSE.JWK.thumbprint/1`), the PRIVATE JWK (JSON) is stored only as `Nebu.Web.SecretBox.encrypt/1`
  ciphertext, the PUBLIC JWK as `jsonb`. `alg` is a constant in code, NEVER read from input or from
  the stored row for signing, never `none`. The private key is never logged, never `inspect`ed,
  never returned by any API, never part of an error tuple.
- **T18 (key lifecycle, cluster-safe lazy generation).** Table `oauth_signing_keys` (AC14) with
  `status active|retired`, `created_at`, `retired_at`, `not_after`; a partial UNIQUE index allows at
  most ONE `active` row. `SigningKeyStore.ensure_active_key/0`: SELECT the active row; none =>
  generate, `INSERT ... ON CONFLICT DO NOTHING`, SELECT again (exactly one winner across the
  cluster; losers discard their key; no advisory lock, no node-local state for correctness). Loading
  verifies that the decrypted private key's thumbprint equals `kid` and its public part equals the
  stored `public_jwk` (SecretBox has no associated data, so a swapped ciphertext between rows must
  fail closed). A per-node cache of the DECODED key material keyed by `kid` is allowed (immutable),
  a cache of "which kid is active" is NOT. Rotation is prepared, not automated: retiring is an
  UPDATE `active -> retired` (guard trigger), JWKS publishes `active` plus `retired` rows with
  `not_after > now()`; rotation tooling and the pre-publication runbook are a follow-up (AC20).
- **T19 (is_active checks are error-aware).** `Nebu.Matrix.active?/1` maps DB errors to `false`;
  using it on the token endpoint would turn a DB hiccup into `invalid_grant` + revocation (= logout).
  The Matrix side uses an error-aware read (`{:ok, true | false} | {:error, _}`): inactive or unknown
  user => `invalid_grant` (+ session revoked on refresh), error => `503` + `Retry-After`.
- **T20 (error mapping, RFC 6749 5.2 + spec 6; oracle C1 BLOCKER).** Every 4xx error body is
  `{"error": code, "error_description": fixed ASCII}` (never `errcode`, never `error_uri`, never
  client/IdP text). 4xx means "logged out" for Matrix clients, so only DEFINITIVE outcomes are 4xx.
  Every 5xx (503 transient: IdP, DB, rotation race, signing key, refresh bucket, `:unknown` config;
  500 rescued exception) is answered with `Retry-After` and the JSON body `{}`: NO `error` member,
  because oidc-client-ts throws an `ErrorResponse` for ANY JSON carrying `error` regardless of the
  status, and matrix-js-sdk maps that to `TokenRefreshLogoutError` (logout) instead of a retryable
  failure. Consequently `temporarily_unavailable` / `server_error` never appear in a token-endpoint
  body. Table in AC10.
- **T21 (rate limits; never 429 on refresh).** Node-local `RateLimit.take/3` buckets (abuse
  control only): `{"oauth_token", ip}` 600/h per IP (rate 10/min, burst 600) for
  `authorization_code`, unknown/missing grant types and unparsable requests => `429
  {"error":"too_many_requests"}` + `Retry-After` (the story-1 DCR shape); `{"oauth_token_refresh",
  ip}` 6000/h per IP (rate 100/min, burst 1200) for `refresh_token` => `503 {}` + `Retry-After`
  (T20), NEVER 429 (spec 6: 429 logs clients out). Charged after
  the body is parsed (the grant type selects the family) and BEFORE any DB access. Behind nginx all
  clients share one per-IP bucket: follow-ups.md item 1 (trusted proxy, HARD GATE) also covers
  these buckets; the refresh bucket is deliberately generous for that reason.
- **T22 (kill switch).** `Config` state `:disabled` or an invalid issuer => `404
  {"errcode":"M_UNRECOGNIZED"}` (`unrecognized_no_error/1`: NO `error` member on the token, jwks and
  openid-configuration endpoints, review cycle 1; metadata/register/authorize keep `unrecognized/1`).
  Oracle C2: this does NOT log matrix-js-sdk out on a refresh (no `error` member => plain `Error` =>
  transient failure, the client keeps retrying); it only stops new logins and refreshes while the
  operator has OAuth switched off. State `:unknown` (server_config unreadable) => `503 {}` +
  `Retry-After: 5` (T20) instead of the authorize endpoint's 404: a transient DB error is a
  transient answer (spec 6 "DB-Fehler => 503"). Same for `GET /oauth2/jwks` and
  `GET /.well-known/openid-configuration` (404 / 503 `{}`).
- **T23 (request format).** `POST` only; `Content-Type` must be
  `application/x-www-form-urlencoded` (parameters such as `charset` allowed); the raw body is read
  by the handler (cap 16 KiB, `Nebu.Web.Plugs.JsonBody` skips `/oauth2/token` like
  `/oauth2/authorize`) and parsed with the story-2 raw parser `AuthorizeRequest.parse_query/1`
  (duplicates kept, `x[]` literal): a duplicated parameter => `invalid_request` (RFC 6749 3.2); a
  non-empty query string => `invalid_request` (credentials never in URLs; RFC 6749 3.2 "MUST use
  POST"). Unknown parameters are ignored (RFC 6749 3.2). A parameter with an EMPTY value is treated
  as OMITTED (RFC 6749 3.1, oracle C3): an empty required parameter is therefore missing =>
  `invalid_request`, an empty optional one (`scope=`, `client_secret=`) is simply absent. Two
  occurrences still count as a duplicate even if one is empty. `conn.body_params` stays
  `%Plug.Conn.Unfetched{}`, so `RequestLogger` never logs the request body of this path.
- **T24 (client authentication `none`).** `client_id` is REQUIRED in the body (absent =>
  `401 invalid_client`); unknown / pending / rejected client => `401 invalid_client`; a NON-EMPTY
  `client_secret` parameter (an empty `client_secret=` is omitted, T23/C3) or an
  `Authorization: Basic` header (unsupported authentication method)
  => `401 invalid_client`, the Basic case with `WWW-Authenticate: Basic realm="nebu"` (RFC 6749 5.2).
  Other `Authorization` schemes (e.g. a stray `Bearer` header on a refresh) are ignored.
  The registered `grant_types` must contain the requested grant, else `400 unauthorized_client`.
  Lookup through the error-aware `ClientStore.fetch_by_client_id/1` (DB error => 503).
- **T25 (resource server: no IdP-JWT for OAuth devices, spec 2).** OAuth sessions know only opaque
  Nebu tokens. Three layers: (a) T7 kills legacy JWT bindings of a reused device at issuance;
  (b) `DeviceBinding.put/4` (legacy login + lazy `/keys/upload` binding) refuses to bind a JWT to
  a `(user_id, device_id)` that has an `auth_api = 'oauth'` row (one guarded INSERT ... SELECT ...
  WHERE NOT EXISTS); (c) `OidcPlug.call_jwt/2`: a JWT whose binding points at a device with an OAuth
  session => `401 M_UNKNOWN_TOKEN` "Access token has been revoked" (no `soft_logout`), resolved in
  the SAME (cached) binding query (`DeviceBinding` returns the device plus an `oauth_device?` flag;
  the 60 s cache is acceptable because (a) denylists cluster-wide immediately). User-level raw-JWT
  access without an OAuth device stays the ADR-033 legacy exception (story 5).
- **T26 (legacy login on an OAuth device = take-over).** Legacy `POST /login` with a client
  `device_id` that has OAuth rows deletes the device's `auth_api = 'oauth'` rows before it binds /
  creates its credential (Matrix `/login`: "the server will invalidate any access token previously
  associated with this device"), so a device is never served by both APIs. Legacy-to-legacy reuse
  is unchanged (today's behaviour; story 5 may revisit). Accepted by the oracle (C8, cs.md
  "Relationship between access tokens and devices": a login with an existing device id invalidates
  that device's earlier tokens; take-over is consistent). Legacy-to-legacy reuse NOT invalidating
  the earlier legacy tokens is a pre-existing SPEC DEVIATION, recorded in follow-ups.md (f) and
  ADR-033 as such (not fixed here).
- **T27 (legacy isolation).** Legacy `POST /_matrix/client/v3/refresh` (`resolve_refresh_token/1`,
  `active_sibling/1`, `rotate_tokens/1` siblings), `extend_in_place*/3`, `store_rotated_oidc_rt/3`
  and the `RefreshWorker` candidate query and TOCTOU re-select are restricted to `auth_api =
  'legacy'`: an OAuth refresh token at `/refresh` is unknown (`401 M_UNKNOWN_TOKEN`), the worker
  never extends/deletes an OAuth row (spec 6: no background worker for OAuth sessions). Conversely
  the OAuth store only ever matches `auth_api = 'oauth'` rows (a legacy refresh token at
  `/oauth2/token` => `invalid_grant`). `mark_access_token_used/1` / `has_open_grace_window?/1`
  consume siblings of the SAME `auth_api` only.
- **T28 (IdP refresh-token race guard).** Two truly concurrent refreshes of one session with
  `per_refresh` redeem the same IdP refresh token; a rotating IdP (Dex, RFC 9700) rejects the loser
  with 400, which `RefreshErrors` classifies as CONFIRMED and would revoke a healthy session. On a
  confirmed rejection the Matrix side re-reads the device's active row: ONLY for a genuine IdP
  rejection (400/401/`invalid_grant`; Nebu-side verdicts such as `:deactivated` always revoke) and
  ONLY if its `oidc_refresh_token` ciphertext changed since the attempt started (only a real IdP
  success writes a new ciphertext; Kassandra F-1), a concurrent refresh won => the request
  is re-resolved and served as a replay WITHOUT a second IdP call (the winner re-validated
  milliseconds ago); bounded by the existing `@refresh_race_retries`-style limit, exhaustion =>
  `503`. Anything else makes the rejection final (revoke + `invalid_grant`). The legacy
  path keeps its documented limitation (not changed here).
- **T29 (no audit rows, minimal logging).** Consistent with story-2 D20 and the legacy login: no
  `audit_log` rows. INFO: `grant_type`, `client_id`, outcome / error code, and after success
  `user_id` + `device_id`. WARNING: reuse revocations (code / refresh token), client mismatch, T6
  misconfiguration, IdP confirmed rejection (`RefreshErrors.describe/1` only). Never a token, code,
  verifier, id_token, IdP token, key material, `redirect_uri` or `scope` value.
- **T30 (metadata truthfulness).** `auth_metadata` gains `jwks_uri = <issuer>/oauth2/jwks` and
  `id_token_signing_alg_values_supported: ["ES256"]` (OIDC Discovery field, registered for RFC 8414
  documents); `grant_types_supported` (`authorization_code`, `refresh_token`) and
  `token_endpoint_auth_methods_supported: ["none"]` are now TRUE. `revocation_endpoint` stays
  advertised (required by the spec) and still 404s until story 4 (I-1, `oauth_enabled` must stay
  false). `last_used_at` of `oauth_clients` is touched on every successful grant, at most once per
  hour per client (`UPDATE ... WHERE last_used_at IS NULL OR last_used_at < now() - interval '1
  hour'`, allowed by the 000040 guard trigger), best effort. `jwks_uri` is REQUIRED by
  matrix-js-sdk's `validateAuthMetadataAndKeys` (oracle C6: not optional, the JWKS must be a
  `keys` array, CORS-readable, never 503 in normal operation), so it is truthful only because AC13
  generates the key lazily on the first JWKS GET.
- **T31 (`/.well-known/openid-configuration`, oracle C7 BLOCKER).** matrix-js-sdk's
  `OidcTokenRefresher` builds `new URL(".well-known/openid-configuration", issuer)` and fetches it
  before refreshing. Nebu serves its OWN metadata document there (exactly `Metadata.build/1`, the
  same JSON as `GET /_matrix/client/v1/auth_metadata`, incl. `jwks_uri`; NEVER the IdP passthrough
  of `Nebu.Matrix.OidcMetadata`), with CORS `*` and the metadata `Cache-Control`; `404
  M_UNRECOGNIZED` while OAuth is disabled, `503 {}` while the config is unreadable. Today no route
  exists for that path (only `/.well-known/matrix/client` in `Nebu.Web.Router`), so there is no
  passthrough to replace. **Issuer-path constraint:** relative URL resolution drops the issuer's
  last path segment, and all Nebu OAuth endpoints live at the host root, so the Nebu issuer MUST
  have an empty path (`https://chat.example.com`, a trailing `/` is allowed and stripped).
  `Metadata.normalize_issuer/1` rejects an issuer with any other path (fail closed: 404 on every
  OAuth endpoint, like an http issuer); documented in ADR-033. The reference nginx templates
  (`deploy/tofu/examples/{stackit,upcloud}/cloud-init.tftpl`) proxy only `/_matrix/`,
  `/.well-known/matrix/`, `/admin/`, `/api/v1/` to the server when Element Web is served at `/`:
  `/oauth2/` and `/.well-known/openid-configuration` must be routed too before `oauth_enabled`
  (follow-up (m), not changed here).
- **T32 (CORS, oracle C15).** Token, JWKS and openid-configuration responses carry
  `Access-Control-Allow-Origin: *` and NEVER `Access-Control-Allow-Credentials`; preflight
  (`OPTIONS`) is answered by `CORSPlug` without endpoint logic, DB access or rate-limit token, and
  its `Access-Control-Allow-Headers` include `Content-Type`, `Authorization`, `X-Requested-With`
  (the CORSPlug defaults already allow these three; nothing to configure for them).
  **Credentials (test review decision):** `plug CORSPlug` runs with its default `credentials: true`
  and adds `Access-Control-Allow-Credentials: true` to every response, including the preflights it
  halts BEFORE routing. The removal is SCOPED to the OAuth paths `/oauth2/token`, `/oauth2/jwks` and
  `/.well-known/openid-configuration` (responses AND their preflights), handled where the CORS plug
  is configured (per-path options or a thin wrapper plug in `Nebu.Web.Router` that delegates to
  CORSPlug with `credentials: false` for these paths). The global CORS behaviour of every other
  path is NOT changed.
- **T33 (`expires_in`, oracle C13).** `expires_in` = `floor(expires_at - now)` computed from the
  SAME `now()` the row's `expires_at` was written with (one SQL `RETURNING` of both values), so the
  server never expires an access token before the advertised lifetime (matrix-js-sdk logs out on
  `M_UNKNOWN_TOKEN` when its known expiry is more than 60 s away). 900 s against an 8 h
  `session_expires_at` is compliant; near the session end `expires_in` is the remaining time.

## Acceptance Criteria

### AC1 — Endpoints, routing, enablement, methods, headers

- `Nebu.Web.Router`: `forward "/oauth2/token", to: Nebu.OAuth.Http, init_opts: [action: :token]`
  and `forward "/oauth2/jwks", to: Nebu.OAuth.Http, init_opts: [action: :jwks]` next to
  `/oauth2/authorize`; `/oauth2/revoke` stays unrouted (plain 404, regression test).
- `Nebu.OAuth.Http.call(conn, :token)` => `Nebu.OAuth.Token.handle_token(conn, issuer)` when live
  (T22). Sub-paths => `404 M_UNRECOGNIZED` (existing `path_info: [_ | _]` clause). `OPTIONS` =>
  CORSPlug preflight (no endpoint logic, no DB access, no rate-limit token; T32). Any method other than `POST` while
  live => `405 {"error":"invalid_request","error_description":"Method not allowed."}` + `Allow:
  POST, OPTIONS`.
- Kill switch (T22): `:disabled` / invalid issuer => `404 M_UNRECOGNIZED`, no DB access beyond the
  config read, no rate-limit token; `:unknown` => `503 {}` + `Retry-After: 5`.
- EVERY token-endpoint response (success and error): `Content-Type: application/json` (also when
  the request has no `Accept` header), `Cache-Control: no-store`, `Pragma: no-cache`,
  `Access-Control-Allow-Origin: *`, no `Access-Control-Allow-Credentials` (browser clients, spec 10,
  T32). EVERY 5xx additionally has `Retry-After` and the body `{}` (T20: no `error` member).
- `GET /oauth2/jwks` (AC13): same kill switch; GET only (405 + `Allow: GET, OPTIONS` otherwise).

### AC2 — Request parsing (T23)

Order (first failure wins; status in brackets, every body RFC 6749 5.2 shape):

1. A non-empty `conn.query_string` => `invalid_request` [400].
2. `Content-Type` not `application/x-www-form-urlencoded` (case-insensitive media type, params
   allowed) => `invalid_request` [400].
3. Body larger than 16 384 bytes (`Plug.Conn.read_body(conn, length: 16_384)` returns `{:more,
   ...}`) => `invalid_request` "The request body is too large." [413]; read error/timeout =>
   `invalid_request` [400].
4. `AuthorizeRequest.parse_query/1` `{:error, :malformed}` => `invalid_request` [400].
5. Any parameter name occurring more than once => `invalid_request` [400] (also two identical
   values; `x[]` names are just names).
6. A parameter value with a `\p{Cc}` character or invalid UTF-8 => `invalid_request` [400] (before
   any SQL: PostgreSQL text cannot store NUL, story-2 Trap 11). Afterwards parameters with an empty
   value are dropped (T23: empty = omitted). Values are compared AFTER form-decoding (a
   percent-encoded `redirect_uri` equals the stored decoded one).
7. Rate limit (AC4) by `grant_type` family.
8. Client authentication (AC3) happens BEFORE the `grant_type` dispatch (a request without
   `client_id` is `401 invalid_client` whatever its `grant_type`), then `grant_type`: missing => `invalid_request` [400]; not exactly
   (case-sensitive) `authorization_code` / `refresh_token` (e.g. `Refresh_Token`, `password`,
   `client_credentials`, `implicit`,
   `urn:ietf:params:oauth:grant-type:device_code`) => `unsupported_grant_type` [400]; registered
   `grant_types` lack it => `unauthorized_client` [400].

### AC3 — Client authentication method `none` (T24)

- `client_id` missing => `401 invalid_client`; longer than 256 bytes or unknown => `401
  invalid_client`; status `pending` or `rejected` => `401 invalid_client`; DB error => `503`.
- A non-empty `client_secret` => `401 invalid_client`; an empty `client_secret=` is omitted and
  accepted (oracle C3); `Authorization: Basic ...` => `401 invalid_client` + `WWW-Authenticate:
  Basic realm="nebu"`. Other `Authorization` schemes (e.g. `Bearer`) are ignored.
- The client lookup is `ClientStore.fetch_by_client_id/1` (error-aware); the client row is used
  for `status`, `metadata["grant_types"]` (absent => both grants, story-1 default) and nothing else.

### AC4 — Rate limiting (T21)

- `{"oauth_token", ip}` (10/min, burst 600): `authorization_code`, missing/unknown grant types and
  requests failing AC2 steps 1-6 (charged before the error answer; exhausted => `429
  {"error":"too_many_requests"}` + `Retry-After` instead of the 4xx).
- `{"oauth_token_refresh", ip}` (100/min, burst 1200): `grant_type=refresh_token`; exhausted =>
  `503 {}` + `Retry-After` (seconds from `RateLimit.take/3`; T20: no `error` member).
  A refresh request is NEVER answered 429 (test drains the bucket and asserts 503).
- Tuple keys never collide with the plug's IP-string keys or the `oauth_register*`,
  `oauth_authorize`, `oauth_callback` families; seams `:rate_limit_clock_fn`,
  `NEBU_RATE_LIMIT_DISABLED` apply.

### AC5 — `grant_type=authorization_code`

Parameters: `code`, `redirect_uri`, `code_verifier` (each REQUIRED; missing/empty =>
`invalid_request`), `client_id` (AC3). `scope`, `state`, `nonce` and others are ignored. Order:

1. `Nebu.OAuth.consume_authorization_code(code)`: `{:error, :storage}` => `503`; `{:error,
   :invalid}` (unknown, expired-unused, malformed) => `invalid_grant`; `{:error, {:reused, row}}` =>
   AC6; `{:ok, row}` => continue.
2. `row.client_id == client_id` else `invalid_grant`.
3. `row.redirect_uri == redirect_uri` byte for byte (incl. the loopback port actually used) else
   `invalid_grant`.
4. PKCE (RFC 7636 4.6): `code_verifier` must be 43..128 chars of `[A-Za-z0-9._~-]` and
   `Plug.Crypto.secure_compare(Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
   row.code_challenge)` else `invalid_grant` (also a 64+ char "plain" verifier against an S256
   challenge).
5. T6: mode `per_refresh` and `row.idp_rt_enc == nil` => `invalid_grant` + WARNING.
6. `openid` in `row.scope` => `SigningKeyStore.ensure_active_key/0`; failure (DB, SecretBox raising
   without an internal secret, decrypt/consistency failure) => `503` (code stays burned; the
   client restarts the login). Done BEFORE the session is created so no orphan session exists.
7. `Nebu.Matrix.oauth_issue_session/1` (AC7): `{:error, :inactive}` => `invalid_grant`;
   `{:error, :unavailable}` => `503`.
8. id_token (AC12) when `openid` granted; `oauth_clients.last_used_at` touch (T30).
9. `200` with the AC8 body. Steps 2-5 never create or revoke anything; the code stays used.

### AC6 — Code reuse (T8, RFC 9700)

`{:error, {:reused, row}}`: when `client_id`, `redirect_uri` and the PKCE verifier pass AC5 steps
2-4 against `row`, call `Nebu.Matrix.oauth_revoke_sessions_for_code(row.code_hash)` (deletes every
`auth_api = 'oauth'` row of the device(s) whose rows carry `oauth_code_hash = row.code_hash`) and
log a WARNING (`client_id`, `user_id`, `device_id`, "authorization code reused, session revoked");
otherwise revoke nothing. The answer is ALWAYS `400 invalid_grant`. A reused code whose derived
session was already refreshed is still found (the column is copied on rotation). A reuse after the
code row was purged (24 h after expiry) is a plain `invalid_grant`.

### AC7 — Session issuance (Matrix side, T2-T5, T7, T19)

`Nebu.Matrix.oauth_issue_session(attrs)` (facade -> `Nebu.Matrix.OAuthSession.issue/1`), `attrs`:
`user_id`, `device_id`, `client_id`, `scope`, `oauth_code_hash`, `idp_rt_enc` (ciphertext or nil),
`auth_time` (unix seconds or nil, from the code row's `timestamptz`), `access_ttl_seconds`.
Returns `{:ok, %{access_token:, refresh_token:, expires_in:, user_id:, device_id:, scope:,
auth_time:}}` | `{:error, :inactive}` | `{:error, :unavailable}`. Never raises.

1. Error-aware `is_active` read (T19): false/absent => `:inactive`; error => `:unavailable`.
2. ONE `Nebu.Repo.transaction`: `DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id =
   $2` (T7, all `auth_api`), `INSERT` the new row: `access_token_hash`, `refresh_token_hash`,
   `oidc_refresh_token` = `idp_rt_enc`, `user_id`, `device_id`, `expires_at = LEAST(now() + ttl,
   session_expires_at)`, `session_expires_at = now() + matrix_session_ttl_seconds`, `auth_time`,
   `auth_api = 'oauth'`, `client_id`, `scope`, `oauth_code_hash`, `created_at = now()`; and
   `DeviceKeyStore.upsert_device(user_id, device_id, display_name: nil, last_seen_ts: now_ms,
   last_seen_ip: nil)` (the device row exists afterwards; `/devices` lists it). Any failure =>
   rollback, `:unavailable`.
3. After the commit, best effort: the T7 JWT kill-switch for the device (never fails the grant).
4. INFO "oauth session created" with `user_id`, `device_id`, `client_id`.

`expires_in` = whole seconds until `expires_at` (`<= ttl`, `>= 1`).

### AC8 — Token response (spec 5 step 5, RFC 6749 5.1)

`200` JSON (`Content-Type: application/json`): `access_token` (64 hex string), `token_type:
"Bearer"`, `expires_in` (JSON integer, T33), `refresh_token` (64 hex, ALWAYS present on EVERY
grant including every refresh: matrix-js-sdk sets its stored refresh token from the response and
logs out when it is absent, oracle C11; spec MUST), `scope` (T14, the stored granted scope
verbatim), `id_token` (only per T15). No other fields (no `device_id`, `user_id`, `expires_in_ms`).
The server never rejects the access token before `expires_in` has elapsed (T33).
The access token authenticates `GET /_matrix/client/v3/account/whoami` => `{"user_id":
<user_id>, "device_id": <device_id>, "is_guest": false}` immediately.

### AC9 — `grant_type=refresh_token` (T10-T13)

Parameters: `refresh_token` (REQUIRED, missing or empty => `invalid_request`), `client_id` (AC3),
optional `scope` (T13; empty = absent). `redirect_uri`, `resource` and other parameters are ignored
(the js-sdk refresher sends none of them). A value that is not 64 lowercase hex (uppercase hex is
invalid) => `invalid_grant` after client authentication and BEFORE any `OAuthSessionStore` access.
Order:

1. `Nebu.Matrix.oauth_resolve_refresh_token(rt)` => `{:ok, session, :current | :replay}` |
   `{:reused, session}` | `:error` | `{:error, :unavailable}` (`session` = `user_id`, `device_id`,
   `client_id`, `scope`, `session_expires_at`, `auth_time`, plus the internal row hash). `:error`
   => `invalid_grant` (also an ACCESS token presented as `refresh_token`: unknown hash, no side
   effect); `:unavailable` => `503 {}`; `{:reused, session}` =>
   `Nebu.Matrix.oauth_revoke_device_session(user_id, device_id)` + WARNING + `invalid_grant` (T11).
2. `session.client_id == client_id` else `invalid_grant` (T12).
3. `session.session_expires_at > now()` (re-checked in SQL) else `invalid_grant`.
4. Scope (AC11) => `invalid_scope`.
5. New granted scope contains `openid` => `ensure_active_key/0` (failure => `503`, session intact).
6. `Nebu.Matrix.oauth_refresh_session(session, mode, rt, %{scope:, idp_revalidation:,
   access_ttl_seconds:})` => `{:ok, %{access_token:, refresh_token:, expires_in:, scope:, user_id:,
   device_id:, auth_time:}}` | `{:error, :invalid_grant}` (the Matrix side already revoked the
   session where AC10 says so) | `{:error, {:unavailable, retry_after_s}}`.
7. `200` with AC8 body (+ id_token per T15/T16, without `nonce`).

Rotation semantics (Matrix side, `OAuthSessionStore`, T10): `:current` => soft-revoke the active row
+ `consume_pending_siblings` + insert; `:replay` (pending old token, lost response) => rotate the
ACTIVE row again with `FOR UPDATE` re-validation that the presented row is still pending (else
`{:error, :consumed}` => reuse => revoke + `invalid_grant`); a lost rotation race => re-resolve
and retry (bounded, exhaustion => `503`). The new row's `expires_at = LEAST(now() + ttl,
session_expires_at)`. The old refresh token stays redeemable until the new access token
authenticates a request or the new refresh token is redeemed; then it is consumed and presenting it
is reuse.

### AC10 — IdP re-validation and the error mapping (T5, T19, T20, T28)

Inside `oauth_refresh_session/4`, BEFORE rotating:

- `per_refresh`: `HttpPublic.revalidate_with_idp(active_row)`; success => rotate, a provider-rotated
  IdP refresh token is re-encrypted (`SecretBox.encrypt/1`) and stored on the NEW row; error =>
  `RefreshErrors.transient?/1`: transient => `{:error, {:unavailable,
  RefreshErrors.retry_after_seconds(reason)}}` (session untouched); confirmed => T28 guard, then
  delete the device's `auth_api = 'oauth'` rows + `{:error, :invalid_grant}`.
- `off`: error-aware `is_active` (T19): inactive => revoke + `invalid_grant`; error => `503`.

Complete token-endpoint mapping (both grants):

| Condition | Status | Body | Session |
|---|---|---|---|
| OAuth disabled / invalid issuer | 404 | `{"errcode":"M_UNRECOGNIZED"}` (no `error` member since review cycle 1, so the kill switch does not log oidc-client-ts clients out; see ADR-033 T22) | - |
| config unreadable (`:unknown`) | 503 + Retry-After | `{}` | untouched |
| query string, wrong content type (JSON, multipart), malformed/duplicate/control-char params, missing or empty `grant_type`/`code`/`redirect_uri`/`code_verifier`/`refresh_token` | 400 | `invalid_request` | - |
| body > 16 KiB | 413 | `invalid_request` | - |
| non-POST | 405 | `invalid_request` | - |
| missing/unknown/pending/rejected client, non-empty `client_secret`, Basic auth | 401 | `invalid_client` | - |
| grant not in the client's `grant_types` | 400 | `unauthorized_client` | - |
| other grant type (also wrong case) | 400 | `unsupported_grant_type` | - |
| code unknown/expired/used, client or redirect mismatch, PKCE failure, T6 | 400 | `invalid_grant` | none created |
| reused code with valid binding | 400 | `invalid_grant` | derived session revoked (AC6) |
| user deactivated/unknown (code grant) | 400 | `invalid_grant` | none created |
| refresh token unknown/legacy/an access token/expired session/client mismatch; session gone after `/logout` or `DELETE /devices/{id}` | 400 | `invalid_grant` | untouched |
| consumed refresh token (reuse) | 400 | `invalid_grant` | revoked (T11) |
| IdP confirmed rejection, deactivated user on refresh | 400 | `invalid_grant` | revoked |
| scope not a valid subset (refresh) | 400 | `invalid_scope` | untouched |
| IdP transient (network, discovery, 5xx, 429), DB error, rotation race exhausted, signing key unavailable | 503 + Retry-After | `{}` | untouched |
| refresh rate limit | 503 + Retry-After | `{}` | untouched |
| code-grant / junk rate limit | 429 + Retry-After | `too_many_requests` | - |
| unexpected exception in the handler | 500 + Retry-After | `{}` | untouched (rescued, exception type logged only) |

Every 4xx body is `{"error": code, "error_description": fixed text}` (429: `{"error":
"too_many_requests"}`); every 5xx body is exactly `{}` (T20, oracle C1). A refresh retried with the
SAME refresh token after any 503 succeeds.

### AC11 — Scope on refresh (T13)

`Nebu.OAuth.TokenRequest.narrow_scope(requested | nil, granted) :: {:ok, scope} | {:error,
:invalid_scope}` (pure, T13): `nil` or `""` => `{:ok, granted}`; otherwise SET comparison with
prefix-normalized Matrix tokens: every requested token must be in the granted set, the `api:*` and
`device:<id>` tokens must be present (Nebu policy), charset RFC 6749 3.3, max 2048 bytes; the result
is the granted STRING (stored prefix and order) with only the dropped `openid` removed. Unit tests:
absent, empty, equal, other order, the other prefix for the same tokens (accepted, echo keeps the
stored prefix), duplicate token (accepted), `openid` dropped, extra token, missing device, other
device id, missing `api:*`, non-ASCII.

### AC12 — id_token (T15, T16)

- `Nebu.OAuth.IdToken.claims(%{issuer:, user_id:, client_id:, auth_time:, nonce:}, now)` (pure)
  and `IdToken.sign(claims, key)` (JOSE ES256, protected header exactly `alg`/`kid`/`typ`).
- Tests verify every issued id_token with `JOSE.JWT.verify_strict(public_jwk_from_jwks, ["ES256"],
  token)` using the key fetched from `GET /oauth2/jwks` by `kid`, and assert the exact claim set:
  `iss` == `auth_metadata["issuer"]` byte for byte, `aud` == client_id (string), `sub` ==
  `/whoami` `user_id`, `nonce` == the authorize request's client nonce (absent when the request had
  none), `auth_time` == the code row's auth_time, `exp - iat == 300`; on refresh no `nonce` and
  identical `iss`/`sub`/`aud`/`auth_time`.
- The exact matrix-js-sdk 41.3.0 shape end to end: scope `openid
  urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj`
  + `nonce` + `response_mode=query` => token response with `id_token`, `scope` echoing the unstable
  prefix and `openid`.
- The Dart SDK shape (unstable prefix, no `openid`) => no `id_token`.

### AC13 — Signing keys and JWKS (T17, T18)

- `Nebu.OAuth.SigningKeyStore`: `ensure_active_key/0 :: {:ok, %{kid:, jwk:}} | {:error, term}`
  (lazy, cluster-safe, verified load), `published_keys/0 :: {:ok, [public_jwk_map]} | {:error,
  term}` (active first, then retired with `not_after > now()`, newest first). Repo seam
  `:nebu_http, :oauth_repo`.
- `GET /oauth2/jwks` => `200 {"keys": [...]}`, each key exactly `kty` `"EC"`, `crv` `"P-256"`,
  `x`, `y`, `kid`, `use` `"sig"`, `alg` `"ES256"` (NEVER `d` or any private member),
  `Content-Type: application/json`, `Cache-Control: public, max-age=600`, `Access-Control-Allow-Origin:
  *`. The endpoint calls `ensure_active_key/0` first, so the set is never empty while OAuth is live.
  Failure => `503 {}` + `Retry-After`. Rate limit `{"oauth_jwks", ip}` 600/h per IP => 429
  `too_many_requests`. matrix-js-sdk's `validateAuthMetadataAndKeys` must pass against the metadata
  + JWKS (C6, see the matrix_compat test).
- N (>= 10) concurrent `ensure_active_key/0` calls on an empty table yield exactly ONE row and the
  same `kid` everywhere.
- A ciphertext copied from another row (or tampered) fails the T18 consistency check =>
  `{:error, :key_inconsistent}`, never a signature with the wrong key.

### AC14 — Migration 000042 (new files; 000040/000041 untouched)

`server/priv/migrations/000042_oauth_sessions_and_signing_keys.up.sql` / `.down.sql`:

```sql
ALTER TABLE matrix_sessions
  ADD COLUMN auth_api           TEXT NOT NULL DEFAULT 'legacy',
  ADD COLUMN client_id          TEXT REFERENCES oauth_clients (client_id) ON DELETE RESTRICT,
  ADD COLUMN scope              TEXT,
  ADD COLUMN session_expires_at TIMESTAMPTZ,
  ADD COLUMN oauth_code_hash    TEXT;
-- named CHECKs:
--   matrix_sessions_auth_api_check:   auth_api IN ('legacy', 'oauth')
--   matrix_sessions_oauth_shape_check:
--     (auth_api = 'legacy' AND client_id IS NULL AND scope IS NULL AND session_expires_at IS NULL
--        AND oauth_code_hash IS NULL)
--     OR (auth_api = 'oauth' AND client_id IS NOT NULL AND scope IS NOT NULL
--        AND session_expires_at IS NOT NULL AND expires_at <= session_expires_at)
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_user_device ON matrix_sessions (user_id, device_id);
CREATE INDEX IF NOT EXISTS idx_matrix_sessions_oauth_code_hash ON matrix_sessions (oauth_code_hash)
  WHERE oauth_code_hash IS NOT NULL;

CREATE TABLE oauth_signing_keys (
  kid             TEXT PRIMARY KEY,                     -- RFC 7638 thumbprint
  alg             TEXT NOT NULL CHECK (alg = 'ES256'),
  public_jwk      JSONB NOT NULL,
  private_jwk_enc TEXT NOT NULL,                        -- SecretBox ciphertext of the private JWK JSON
  status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retired')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  retired_at      TIMESTAMPTZ,
  not_after       TIMESTAMPTZ,                          -- published in JWKS until then (retired keys)
  CONSTRAINT oauth_signing_keys_retired_check CHECK (
    (status = 'active' AND retired_at IS NULL) OR (status = 'retired' AND retired_at IS NOT NULL))
);
CREATE UNIQUE INDEX oauth_signing_keys_one_active ON oauth_signing_keys (status) WHERE status = 'active';
```

- `matrix_sessions`: no RLS change (the table has none; the 000002 table GRANT covers the new
  columns). The DEFAULT makes existing rows `legacy`; old code that inserts without the new columns
  still passes the CHECKs (rolling-deploy safe, no stop-the-world unlike 000038; header comment says
  so). The FK `ON DELETE RESTRICT` enforces in the DB the spec 4 rule "MUST NOT delete a registration
  with an active session" (pending rows, the only purged ones, never have sessions; RI checks bypass
  RLS, story-2 Trap 10).
- `oauth_signing_keys`: `GRANT SELECT, INSERT, UPDATE ON oauth_signing_keys TO nebu_app` (no
  DELETE); `ENABLE` + `FORCE ROW LEVEL SECURITY`; policies SELECT `true`, INSERT `WITH CHECK (status
  = 'active' AND retired_at IS NULL AND not_after IS NULL)`, UPDATE `USING (true) WITH CHECK
  (true)`, NO DELETE policy. Trigger `oauth_signing_keys_guard` (`BEFORE UPDATE`): refuses any change
  of `kid`, `alg`, `public_jwk`, `private_jwk_enc`, `created_at`; refuses `retired -> active`;
  `active -> retired` requires `retired_at`; `not_after` may only be set/raised.
- `server_config`: re-create `config_update_mutable` with 000040's key list VERBATIM (incl. the two
  `LIKE` families) plus `'oauth_access_token_ttl_seconds', 'oauth_idp_revalidation'`. No INSERT of
  values (absent keys => defaults, T4/T5).
- `.down.sql`: restores 000040's policy text, drops `oauth_signing_keys` + the trigger function,
  deletes `auth_api = 'oauth'` rows from `matrix_sessions` (they cannot exist without the columns),
  drops the indexes, CHECKs and columns. Transaction-safe (no `BEGIN`/`COMMIT`, no
  `CONCURRENTLY`), must not touch `oauth_clients` rows. Header comment documents T2/T3/T8/T17/T18.

### AC15 — Configuration (T4, T5)

`Nebu.OAuth.Config.token_settings/0 :: %{access_token_ttl_seconds: 60..3600, idp_revalidation:
:per_refresh | :off}` reading `oauth_access_token_ttl_seconds` / `oauth_idp_revalidation` (added to
the `@sql` key list); defaults on absent/invalid/unreadable (900, `:per_refresh`). Seam: the
`:oauth_config_source` map may carry `:access_token_ttl_seconds` / `:idp_revalidation`. Never
raises. No env variables (ADR-022 idiom).

### AC16 — Resource server (spec 2, 6; T3, T25)

- An OAuth access token authenticates every protected Matrix route through
  `OidcPlug.call_opaque/2` (no change needed beyond T27's sibling filter): `current_user`,
  `device_id`, `access_token` assigned; `/whoami` returns both (AC8); `/sync` works.
- Expired OAuth access token (`expires_at <= now()`) => `401 {"errcode":"M_UNKNOWN_TOKEN",
  "soft_logout": true}`; a rotated-away (superseded) OAuth access token => `401 M_UNKNOWN_TOKEN` +
  `soft_logout: true` ("Token has been superseded", existing branch); unknown => `401
  M_UNKNOWN_TOKEN` without `soft_logout`; deactivated user => existing soft_logout branch.
- The first request with the new access token consumes the pending old refresh token (old RT then
  => reuse => session revoked) — end-to-end test through HTTP.
- T25 (a)-(c): a legacy raw JWT bound to a device that later got an OAuth session is rejected
  (denylisted) after issuance; `DeviceBinding.put/4` refuses to bind a JWT to an OAuth device
  (legacy lazy `/keys/upload` binding included); a JWT whose binding row still points at an OAuth
  device (inserted directly) => `401 M_UNKNOWN_TOKEN` "Access token has been revoked".

### AC17 — Legacy isolation and regressions (T26, T27)

- Legacy `POST /refresh` with an OAuth refresh token => `401 M_UNKNOWN_TOKEN` (no row touched);
  `/oauth2/token` with a legacy refresh token => `invalid_grant` (no row touched).
- `RefreshWorker`: an OAuth row inside the lookahead window is NOT a candidate and is never
  extended or deleted (test with a forced cycle, `:matrix_refresh_worker_interval_ms` seam / direct
  `send(pid, :refresh)`); legacy rows behave exactly as before.
- `MatrixSessionStore`: `resolve_refresh_token/1`, `active_sibling/1`, `extend_in_place*/3`,
  `store_rotated_oidc_rt/3`, the sibling updates of `rotate_tokens/1` and
  `mark_access_token_used/1` / `has_open_grace_window?/1` filter by `auth_api` (T27);
  `cleanup_expired/0` uses `COALESCE(session_expires_at, expires_at)`. Every existing
  `matrix_session_store_test.exs`, `refresh_semantics_test.exs`, `refresh_worker_test.exs`,
  `token_hashing_test.exs`, `login_refresh_test.exs`, `oidc_plug*_test.exs` stays green.
- Legacy `POST /login` with a `device_id` that has OAuth rows deletes those rows first (T26), then
  behaves as today; without OAuth rows nothing changes.
- `POST /logout`, `DELETE /devices/{id}` and admin deactivation remove OAuth rows too (existing
  delete-by-device/user paths; regression tests only, the full logout integration is story 4).
  `/logout/all` is not routed today: a pre-existing gap, out of scope.

### AC18 — Metadata (T30)

`Nebu.OAuth.Metadata.build/1` adds `"jwks_uri" => issuer <> "/oauth2/jwks"` and
`"id_token_signing_alg_values_supported" => ["ES256"]`; moduledoc updated (no longer "never
`jwks_uri`": it is Nebu's own JWKS, still nothing IdP-derived). The story-1 "no unknown fields"
test's allowed set gains both keys; `grant_types_supported` / `token_endpoint_auth_methods_supported`
unchanged. `Metadata.normalize_issuer/1` additionally rejects an issuer with a non-empty path
(other than a single trailing `/`), T31: tests for `https://host`, `https://host/` (ok) and
`https://host/nebu` (=> 404 on metadata, authorize, token, jwks, openid-configuration).

### AC19 — Logging and redaction (No Sensitive Data law, T23, T29)

- `PayloadRedactor`: `id_token` added to `@credential_keys` AND `@credential_string_keys`
  (`access_token`, `refresh_token`, `code`, `code_verifier`, `client_secret` already present).
  Unit test: a token-endpoint response map and a `code=...&code_verifier=...&refresh_token=...`
  string are fully masked.
- `RequestLogger`: `/oauth2/token` joins `@names_only_query_paths` (a client that wrongly sends a
  query string is masked); the request body of `/oauth2/token` is never captured (`body_params`
  stays `Unfetched`, T23) — test at `:debug` with log capture.
- Log-capture tests over both grants (success, every error, reuse, IdP failure, key generation):
  no access/refresh token, code, verifier, id_token, IdP refresh token, private key member (`"d"`),
  SecretBox ciphertext, `redirect_uri` or `scope` value appears.

### AC20 — Documentation

- ADR-033: new section "Token endpoint, sessions, refresh and id_token (story 3)" with T1-T33
  (esp. T2/T3 data model, T8 proof-bound code-reuse revocation, T10/T11 refresh semantics, T17/T18
  key decision with the rejected alternatives, T20 error mapping, T21 no-429, T22 `:unknown` => 503,
  T25 legacy JWT exclusion); the "Gate items" paragraph: `/oauth2/token` exists now, `/oauth2/revoke`
  still 404 => `oauth_enabled` stays false until story 4.
- `docs/matrix-api-scope.md`: `/oauth2/token` row ✅ (grants, error mapping summary, rate limits,
  no-429 rule), new `GET /oauth2/jwks` row ✅, `/oauth2/revoke` still "not implemented (story 4)";
  `/refresh` row notes "legacy sessions only".
- `docs/stories/oauth-broker/follow-ups.md`: story-3 section: (a) item 1 (trusted proxy) also
  covers `oauth_token*` / `oauth_jwks` buckets; (b) signing-key rotation tooling + runbook
  (pre-publish the next key >= JWKS max-age + id_token lifetime before activating; retire with
  `not_after`); (c) device `display_name` for OAuth devices (O5); (d) UIA/`m.oauth` for OAuth
  sessions (stories 5/6); (e) I-1 update (token live, revoke 404); (f) legacy-to-legacy device reuse
  does not invalidate old legacy tokens: a pre-existing SPEC DEVIATION (cs.md "Relationship between
  access tokens and devices", oracle C8); and two new gate items in the follow-ups table:
  **(l)** detect a missing IdP refresh token already at the IdP callback (OAuth branch of
  `handle_idp_callback/1`) when `oauth_idp_revalidation = per_refresh`, BEFORE a code is minted
  (error redirect `server_error` / error page) and show an admin configuration warning (oracle C9;
  NOT implemented in story 3, which fails closed at the token endpoint, T6); **(m)** reverse-proxy
  routes for `/oauth2/` and `/.well-known/openid-configuration` in the reference deployments
  (T31), gate before `oauth_enabled`.
- ADR-033 additionally records the two deliberate deviations: T8 proof-gated code-reuse revocation
  (C10) and the legacy-to-legacy device reuse (C8); plus the issuer-path constraint (T31) and the
  5xx body rule (T20).
- `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`: checklist items 5-7 reflect T10/T11/T27
  (only if the oracle step finds a contradiction; otherwise unchanged).
- arc42 (by the arc42 step; Dev Notes list the hooks).

### AC21 — OpenID configuration document under the issuer (T31, oracle C7)

- `Nebu.Web.Router`: `get "/.well-known/openid-configuration"` (or a `forward` to `Nebu.OAuth.Http`
  with `action: :openid_configuration`) placed next to `get "/.well-known/matrix/client"`.
- OAuth live => `200` with `Metadata.build/1` (byte-identical JSON to `GET
  /_matrix/client/v1/auth_metadata`: same `issuer`, `jwks_uri`, endpoints), `Content-Type:
  application/json`, the metadata `Cache-Control`, `Access-Control-Allow-Origin: *`. Disabled /
  invalid issuer => `404 M_UNRECOGNIZED`; `:unknown` => `503 {}` + `Retry-After`. Never the IdP
  document (`Nebu.Matrix.OidcMetadata`), never IdP fields. GET only (405
  `{"error":"invalid_request","error_description":"Method not allowed."}` + `Allow: GET, OPTIONS`,
  as on `/oauth2/jwks`; OPTIONS via CORSPlug). Sub-paths 404.
- Test: `new URL(".well-known/openid-configuration", issuer)` resolution for the issuer as served
  (no path) points at this route; its `issuer` is byte-equal to the `auth_metadata` issuer and to
  the id_token `iss`.

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- Unit `oauth_token_request_test.exs`: raw body parse + duplicates + control chars, content-type
  matrix, PKCE verifier format + S256 check (RFC 7636 Appendix B vector:
  `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` -> `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`),
  `narrow_scope/2` table (AC11), grant/param validation table.
- Unit `oauth_id_token_test.exs`: claim set per grant, header exactly `alg`/`kid`/`typ`, ES256
  signature verifiable with the public JWK, `alg` constant (a JWK carrying `"alg":"none"` or HS256
  in the stored map cannot change the header).
- Integration `oauth_token_http_test.exs`: AC1-AC4 (kill switch 404/503, 405, CORS + no-store +
  Pragma on every response incl. errors, query string, content type, body cap 413, duplicates,
  client auth table, `unsupported_grant_type`, `unauthorized_client` with a client registered
  `grant_types: ["authorization_code"]`, rate limits incl. "refresh never 429", `/oauth2/revoke`
  still 404, no `errcode` in any OAuth error body).
- Integration `oauth_token_code_grant_test.exs`: AC5-AC8 through the real story-2 flow
  (`T.start_flow/4` + `T.finish_flow/3`): success shapes (both prefixes, js-sdk and Dart shapes),
  every `invalid_grant` cause, deactivated user (`T.DeactivatedValidator` / `users.is_active =
  false` set between callback and token request), T6, device reuse (prior legacy opaque session,
  prior OAuth session, prior JWT binding => all revoked, device row + keys kept), code reuse with and
  without verifier, concurrent redemption (N tasks, exactly one 200, others `invalid_grant`, at most
  one active row, never a live session without a 200), `last_used_at` touch.
- Integration `oauth_token_refresh_grant_test.exs`: AC9-AC11: rotation, Refresh-Retry (old RT
  works until the new AT is used via HTTP `/whoami`, then reuse => revoked), replay of a pending RT
  serves the active row, consumed RT reuse revokes, client mismatch, expired session, scope
  narrowing, `per_refresh` with `:matrix_oidc_refresh_override` returning success / provider-rotated
  RT / `{:token_endpoint_status, 503|429|400}` / `{:token_endpoint_unreachable, _}` /
  `{:discovery_failed, _}` / `:deactivated`, `off` mode with deactivation and a DB failure
  (`:oauth_user_active_override` returning `{:error, :db}`: the T19 read is a plain SELECT; the
  `:session_manager, :validator_module` seam stays for `per_refresh`'s `check_still_active`), concurrency (N concurrent
  refreshes with the same current RT => only 200/503, never 400/500, exactly one active row, session
  alive), T28 race guard (override that rotates the stored IdP RT first, then rejects).
- Integration `oauth_signing_keys_test.exs`: AC13 (lazy generation, concurrent generation race,
  JWKS shape/no private members/headers, retired key published until `not_after`, consistency check
  on swapped ciphertext, SecretBox unavailable => 503 on JWKS and on an `openid` code grant).
- Integration `oauth_resource_server_test.exs`: AC16 (whoami, sync, soft_logout on expiry and on a
  superseded token, T25 a-c) and AC17 legacy isolation (legacy `/refresh` with OAuth RT, OAuth
  token endpoint with legacy RT, RefreshWorker skip, T26 take-over, logout/device delete/deactivation
  remove OAuth rows).
- Integration `oauth_token_e2e_test.exs` (happy path with a "real client" sequence, epic-4 retro
  quality gate): register (DCR) -> admin approve -> authorize -> IdP stub -> callback -> token
  (js-sdk shape, id_token verified against `/oauth2/jwks` + metadata issuer) -> whoami -> `/sync`
  -> refresh (new id_token) -> whoami with the new AT -> old AT `soft_logout` -> old RT => reuse =>
  revoked -> new AT now 401.
- Integration `server/test/nebu/migration/000042_oauth_sessions_signing_keys_test.exs`: columns,
  defaults (existing rows `legacy`), both CHECKs (legacy row with `client_id` refused; oauth row
  without `session_expires_at` refused; `expires_at > session_expires_at` refused), FK RESTRICT
  (deleting an approved client with a session fails as privileged role), indexes, signing-key
  RLS/policies/guard trigger (runtime role: no DELETE, cannot change key material, cannot
  re-activate, second `active` row refused), config allowlist (UPDATE of the two new keys affects
  1 row; all 000040 keys still updatable), down/up round trip (`T.with_privileged_conn/1`).
- Extended: `oauth_metadata_test.exs` (AC18), `oauth_payload_redaction_test.exs` /
  `oauth_request_logger_redaction_test.exs` (AC19), `oauth_authorize_http_test.exs` (the story-2
  "token/revoke plain 404" test becomes revoke-only + token routed), `adr_033_test.exs` (story-3
  section present; the story-2 assertion "`/oauth2/token` ... not implemented" in
  `matrix-api-scope.md` is replaced by a story-3 assertion), `refresh_worker_test.exs`,
  `matrix_session_store_test.exs`, `oidc_plug` tests (T25 c), `device_binding` tests (T25 b),
  login tests (T26), `release_test.exs` only if it pins a count.

- Extra oracle tests (all must exist, spread over the files above): 5xx bodies of the refresh
  grant (IdP transient, DB, race, key, bucket, `:unknown`, rescued 500) are exactly `{}` with
  `Retry-After`; `scope=` empty on refresh => 200 with the granted scope; `client_secret=` empty
  accepted; other empty params => `invalid_request`; refresh `scope` in another order / with the
  other prefix => 200; `grant_type=Refresh_Token` => `unsupported_grant_type`; content type with
  `; charset=UTF-8` accepted, JSON and multipart bodies => `invalid_request`, missing `Accept`
  still JSON; percent-encoded `redirect_uri` compared after form-decoding; `OPTIONS /oauth2/token`
  and `/oauth2/jwks`: CORS headers (Allow-Headers incl. `Content-Type`, `Authorization`), no DB
  access, no rate-limit token; a simple cross-origin POST gets `Access-Control-Allow-Origin: *`
  and never `Access-Control-Allow-Credentials`; `/.well-known/openid-configuration` issuer
  byte-equal + `jwks_uri`; an access token presented as `refresh_token` => `invalid_grant`
  without side effect; a refresh token used as Bearer => `401 M_UNKNOWN_TOKEN` WITHOUT
  `soft_logout`; refresh after `DELETE /devices/{id}` or `/logout` => `invalid_grant`; refresh
  replay with the same RT after a 503 works; `expires_in` never exceeds the server-side remaining
  lifetime and no 401 occurs before it (set `expires_at` boundary via SQL); an extra
  `Authorization: Bearer` header on a refresh is ignored.

### matrix_compat node test (oracle C6, ATDD step)

The ATDD step writes `tests/matrix_compat/oauth_metadata_test.js` (matrix-js-sdk 41.3.0, already
the pinned dependency of `tests/matrix_compat/package.json`) that calls the SDK's
`validateAuthMetadataAndKeys` against Nebu's `auth_metadata` + JWKS and, if feasible,
`OidcTokenRefresher` against a stubbed token endpoint (503 `{}` => retryable failure, 400
`invalid_grant` => logout) — ONLY if it can run WITHOUT modifying the main checkout `open-chat`:
the file lives in the worktree, `npm ci` runs in a scratchpad COPY of `tests/matrix_compat`, the
server side is the isolated `nebu-oauth` stack or a static fixture of the metadata/JWKS JSON
produced by an ExUnit test. If it cannot run in the isolated env it is still written, its run is
recorded as "not executed" in the Dev Agent Record, and the ExUnit tests cover the same rules.

How/when it runs: `npm run test:oauth` (script added to `tests/matrix_compat/package.json`, the
existing `test` script unchanged) from a scratchpad copy with `NEBU_OAUTH_FIXTURE=<json>`; the
fixture is written by `oauth_signing_keys_test.exs` when `NEBU_OAUTH_FIXTURE_OUT=<path>` is set and
carries Nebu's REAL metadata, JWKS, openid-configuration and token-endpoint answers (200, 503 `{}`,
400 `invalid_grant`), which the node test replays through `OidcTokenRefresher`. It runs in the dev
step and the CI gate of this story manually; wiring it into CI is a follow-up (not this story).

### Gherkin

None: no UI (`ui: false`). The story-2 HTML pages are unchanged. The ExUnit e2e test above is the
real-client happy path.

## Must be test-covered (spec MUSTs, RFC 6749 / RFC 7636 / RFC 9700 / OIDC Core)

1. Kill switch: disabled / invalid issuer => `404 M_UNRECOGNIZED` on `/oauth2/token` and
   `/oauth2/jwks`; `:unknown` config => `503` + `Retry-After` (never 404, never 4xx for refresh).
2. Every token-endpoint response (200 and every error) has `Cache-Control: no-store`, `Pragma:
   no-cache`, `Access-Control-Allow-Origin: *`, JSON; no OAuth error body contains `errcode` or
   `error_uri` (js-sdk checks `errcode` first); EVERY 5xx (503 and 500, every cause, both grants)
   has `Retry-After` and the body exactly `{}` with NO `error` member (oracle C1: oidc-client-ts
   would turn it into a logout).
3. RFC 6749 5.2 codes, each with its status: `invalid_request` (400: query string, wrong content type,
   duplicate parameter, control char, missing `grant_type` / `code` / `redirect_uri` /
   `code_verifier` / `refresh_token`; 413 body cap; 405 method), `invalid_client` (401: missing /
   unknown / pending / rejected client, `client_secret`, Basic header + `WWW-Authenticate`),
   `unauthorized_client` (400), `unsupported_grant_type` (400: `password`, `client_credentials`,
   device code), `invalid_grant` (400, every cause of AC10), `invalid_scope` (400, refresh).
4. PKCE (RFC 7636 4.6, Matrix MUST S256): correct verifier succeeds (RFC 7636 Appendix B vector);
   wrong verifier, missing verifier (`invalid_request`), 42/129-char verifier, verifier with a
   forbidden character, and a plain verifier equal to the stored challenge => failure; comparison via
   `Plug.Crypto.secure_compare/2` (static check).
5. `redirect_uri` byte-equal to the authorize request's (loopback port included; another port,
   trailing slash or case change => `invalid_grant`); `client_id` bound to the code.
6. Code single use: second redemption => `invalid_grant`; N concurrent redemptions => exactly one
   200 (RFC 6749 4.1.2, cluster-safe).
7. Code reuse (RFC 9700 4.2.1 / T8): reuse with the valid verifier revokes the derived session (its
   access token => 401, its refresh token => `invalid_grant`), also after that session was refreshed
   once; reuse without a valid verifier revokes nothing; an unrelated earlier session of the same
   device is never the "derived" one (it was already revoked by T7, verify by row inspection).
8. Expired code (> 60 s, set via SQL) => `invalid_grant`; code of another client => `invalid_grant`.
9. Deactivated user at the token endpoint (follow-up f) => `invalid_grant`, no session row; DB error
   during the check => 503.
10. Device reuse (spec 5.1): earlier legacy opaque, OAuth and raw-JWT credentials of the same
    `(user, device)` are all invalid after issuance; device row and device keys survive; another
    user's device with the same id is untouched.
11. Token response: `access_token` + `refresh_token` 64 hex and only hashes stored (no plaintext in
    any column), `token_type` `Bearer`, `expires_in` <= TTL (900 default, `oauth_access_token_ttl_seconds`
    honoured, out-of-range values => 900), refresh token ALWAYS present (spec MUST), `scope` echoes
    the REQUEST's prefix (both prefixes) and `openid` when granted.
12. `/whoami` with the new access token returns `user_id` and `device_id`.
13. Expired access token => `401 M_UNKNOWN_TOKEN` + `soft_logout: true`; superseded access token =>
    `soft_logout: true`; unknown token => no `soft_logout`.
14. Refresh rotation: every refresh returns a NEW access AND refresh token; the old access token is
    superseded at once.
15. Refresh-Retry (spec 6): the old refresh token stays valid after a rotation until the new access
    token authenticates a request or the new refresh token is used (no time window: also valid after
    a simulated 10-minute delay); afterwards presenting it is reuse => whole session revoked
    (`invalid_grant`, all device rows gone).
16. Replay of a pending refresh token returns a fresh working pair and does not revoke the session.
17. Concurrent refreshes with the same current refresh token: only 200/503, exactly one active row
    afterwards, session alive (cluster-safe rotation).
18. Refresh after `session_expires_at` => `invalid_grant`; `session_expires_at` never grows across
    rotations; `expires_at <= session_expires_at` always.
19. Refresh client binding: another approved client's `client_id` => `invalid_grant`.
20. Scope narrowing (RFC 6749 6): equal/absent ok, dropping `openid` ok and persistent (no id_token
    afterwards, cannot be widened back), any extra/missing/other-prefix token => `invalid_scope`.
21. IdP re-validation `per_refresh`: transient (network, discovery, 5xx, 429, DB) => 503 +
    `Retry-After` and the same refresh token works afterwards; confirmed (400/401/403, `:deactivated`,
    decrypt failure) => `invalid_grant` + session revoked; provider-rotated IdP RT stored encrypted on
    the new row; T28 race guard keeps the session.
22. `off` mode: no IdP call (override asserts not invoked); deactivated user => `invalid_grant` +
    revoked; DB error => 503.
23. T6: `per_refresh` + code without IdP RT => `invalid_grant`, no session, one WARNING.
24. No `429` on `grant_type=refresh_token` ever (drained bucket => 503 + `Retry-After`); the code
    grant bucket answers 429 `too_many_requests`.
25. id_token on the code grant when `openid` is granted: signature verifies with the JWKS key of its
    `kid` (`JOSE.JWT.verify_strict(..., ["ES256"], ...)`); `iss` byte-equal to the metadata `issuer`;
    `aud` = client_id; `sub` = Matrix user id; `nonce` = client nonce (absent if none was sent);
    `auth_time`; `exp - iat = 300`; header `alg` ES256 (never `none`), `kid` present.
26. id_token on refresh: present iff `openid` still granted, no `nonce`, same `iss`/`sub`/`aud`/
    `auth_time`, new `iat`; no id_token without `openid` (Dart shape).
27. Signing keys: lazy generation creates exactly one active key under N concurrent callers; private
    key only as SecretBox ciphertext (no `"d"` in any plaintext column, not in JWKS, not in logs);
    tampered/swapped ciphertext fails closed; runtime role cannot delete or alter key material; JWKS
    headers and shape; retired key published until `not_after`.
28. Legacy isolation: OAuth RT at `/refresh` => 401; legacy RT at `/oauth2/token` => `invalid_grant`;
    `RefreshWorker` never touches OAuth rows; legacy `/login`, `/refresh`, worker, logout regression
    suites green.
29. Legacy JWT exclusion (spec 2, T25 a-c) and legacy login take-over of an OAuth device (T26).
30. Metadata: `jwks_uri` + `id_token_signing_alg_values_supported` present and https;
    `/oauth2/revoke` still 404.
31. No secrets in logs (AC19) for every token-endpoint path and the JWKS/key generation path.
32. Migration 000042: CHECKs, FK RESTRICT, guard trigger, RLS, allowlist, down/up round trip.
33. Empty parameters = omitted (RFC 6749 3.1): `scope=` and `client_secret=` accepted, empty required
    parameters => `invalid_request`.
34. `/.well-known/openid-configuration` (T31): Nebu's own document, issuer byte-equal, `jwks_uri`,
    CORS, 404 disabled, 503 `{}` unknown; issuer with a path rejected everywhere.
35. `refresh_token` present in EVERY refresh response (C11); `expires_in` consistent with the stored
    `expires_at` (C13).
36. matrix-js-sdk `validateAuthMetadataAndKeys` passes (node test, if runnable; C6).

## Dev Notes

### Files to create

- `server/lib/nebu/oauth/token.ex` — `handle_token(conn, issuer)`: AC2 order, AC3, AC4, grant
  dispatch (AC5/AC6/AC9), responses (`json/3` with the AC1 headers, `oauth_error/4` like
  `Nebu.OAuth.Http.oauth_error/4` + `Pragma`), rescue => 500 `{}` + `Retry-After` (T20).
- `server/lib/nebu/oauth/token_request.ex` — pure: `read_form/1` helper contract (the I/O read stays
  in `Token`), `validate_params/1`, `pkce_valid?/2`, `valid_verifier?/1`, `narrow_scope/2`,
  `valid_refresh_token_format?/1`.
- `server/lib/nebu/oauth/id_token.ex` — pure: `claims/2`, `sign/2` (constant `@alg "ES256"`).
- `server/lib/nebu/oauth/signing_key_store.ex` — inline SQL: `ensure_active_key/0`,
  `published_keys/0`; repo seam `:nebu_http, :oauth_repo`; `query/2` with the `CodeStore` rescue
  list (never `inspect` an exception carrying parameters).
- `server/lib/nebu/matrix/session/oauth_session_store.ex` — inline SQL on `matrix_sessions` for
  `auth_api = 'oauth'`: `insert_replacing_device/1` (T7 transaction), `resolve_refresh_token/1`,
  `rotate/1` (T10, modelled on `MatrixSessionStore.rotate_tokens/1`), `delete_device_oauth/2`,
  `delete_by_code_hash/1`, `active_row/2` (T28 re-read), error-aware `user_active/1` (T19, or put
  it in `Nebu.Matrix.OAuthSession`). Reuses `MatrixSessionStore.hash_token/1` and
  `generate_opaque_token/0` (single hashing seam).
- `server/lib/nebu/matrix/oauth_session.ex` — `issue/1`, `resolve_refresh_token/1`, `refresh/4`
  (revalidation via `HttpPublic.revalidate_with_idp/1`, `RefreshErrors`, T28, race retries), JWT
  kill-switch helper for T7.
- `server/priv/migrations/000042_oauth_sessions_and_signing_keys.{up,down}.sql` — AC14.
- **Test-only seams in production code (test review):** `:oauth_session_repo`,
  `:oauth_user_active_override`, `:oauth_rotate_override`, `:oauth_token_test_hook` (see "ATDD
  Decisions (story 3)") are read through ONE helper per module that is compiled to the production
  default unless `Mix.env() == :test` (compile-time guard, e.g. `if Mix.env() == :test do defp
  seam(k, d), do: Application.get_env(:nebu_http, k, d) else defp seam(_k, d), do: d end`), so a
  stray application env in a release can never inject a repo, an `is_active` answer, a rotation
  result or a fault. A static test may grep for the guard; the code review checks it.
- Tests listed under Acceptance Tests; helpers ONLY in `server/test/nebu/oauth/oauth_test_support.exs`
  (`token_request/2` (form POST builder), `redeem_code!/2`, `refresh!/3`, `jwks/0`,
  `verify_id_token!/1`, `oauth_session_rows/2`).

### Files to modify

- `server/lib/nebu/web/router.ex` — two forwards (AC1) + the `/.well-known/openid-configuration`
  route (AC21) next to `/.well-known/matrix/client`; update the comment at line ~93.
- `server/lib/nebu/web/plugs/json_body.ex` — skip `["oauth2", "token" | _]` (T23; moduledoc).
- `server/lib/nebu/oauth/http.ex` — `call(conn, :token)`, `call(conn, :jwks)`; `jwks/1` handler;
  moduledoc (token/jwks endpoints, `/oauth2/revoke` still unrouted).
- `server/lib/nebu/oauth.ex` — moduledoc (story 3 scope, Matrix facade functions used).
- `server/lib/nebu/oauth/config.ex` — `token_settings/0` + the two keys in `@sql` (AC15).
- `server/lib/nebu/oauth/metadata.ex` — AC18 (+ the issuer-path rule of T31 in `normalize_issuer/1`).
- `server/lib/nebu/oauth/http.ex` also gets `call(conn, :openid_configuration)` (AC21), reusing the
  `auth_metadata/1` response code.
- `tests/matrix_compat/oauth_metadata_test.js` — new (ATDD, C6; never `npm ci` inside the main
  checkout).
- `server/lib/nebu/oauth/client_store.ex` — `touch_last_used/1` (T30, best effort, 1 h throttle in SQL).
- `server/lib/nebu/matrix.ex` — facade: `oauth_issue_session/1`, `oauth_resolve_refresh_token/1`,
  `oauth_refresh_session/4`, `oauth_revoke_device_session/2`, `oauth_revoke_sessions_for_code/1`
  (each `@doc` + `@spec`, never raise, ADR-020 note like the story-2 IdP functions).
- `server/lib/nebu/matrix/session/matrix_session_store.ex` — T27 filters, `select_sql/1` +
  `row_to_session/1` gain `auth_api` (see Trap 3), `cleanup_expired/0`, moduledoc ("legacy rows
  only; OAuth rows: `OAuthSessionStore`").
- `server/lib/nebu/matrix/session/refresh_worker.ex` — candidates `AND auth_api = 'legacy'`, re-select
  skips non-legacy rows; moduledoc.
- `server/lib/nebu/matrix/session/device_binding.ex` — T25 b (guarded insert) and c (lookup returns
  the oauth flag, cache value shape changes — keep `get_device/1`'s public contract for existing
  callers and add e.g. `lookup/1 :: {:ok, device_id | nil, oauth_device? :: boolean}`).
- `server/lib/nebu/web/plugs/oidc_plug.ex` — T25 c in `call_jwt/2` (before assigning the device).
- `server/lib/nebu/matrix/http_public.ex` — T26 in `provision_and_respond/6` (before
  `register_device/4`): `OAuthSessionStore.delete_device_oauth(user_id, device_id)` when a client
  `device_id` was supplied; nothing else in the legacy login changes.
- `server/lib/nebu/web/plugs/request_logger.ex` — `/oauth2/token` in `@names_only_query_paths`.
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — `id_token` (AC19), moduledoc.
- Tests: see Acceptance Tests "Extended"; `oauth_test_support.exs` `cleanup_clients/1` must delete
  the clients' `matrix_sessions` rows first (FK RESTRICT, Trap 9).
- Docs per AC20.

### Current state of the code this story builds on (read before coding)

- `Nebu.OAuth.CodeStore.consume/1` (story 2): one `UPDATE ... SET used_at = now() WHERE code_hash =
  $1 AND used_at IS NULL AND expires_at > now() RETURNING` + follow-up SELECT; returns atom-key rows
  with `code_hash`, `client_id`, `redirect_uri`, `code_challenge`, `device_id`, `user_id`, `scope`,
  `scope_prefix`, `response_mode`, `client_nonce`, `openid_requested`, `idp_rt_enc` (ciphertext),
  `auth_time` (`DateTime` or nil), `created_at`, `expires_at`, `used_at`. Public via
  `Nebu.OAuth.consume_authorization_code/1`. Keep unchanged.
- `Nebu.OAuth.Authorize.live_issuer/0` (`{:ok, issuer} | :error`) is the enabled-and-valid-issuer
  gate; T22 needs the three-state answer, so call `Config.get/0` + `Metadata.normalize_issuer/1` in
  `Http` for `:token`/`:jwks` (do not change `live_issuer/0`'s callers).
- `Nebu.OAuth.AuthorizeRequest.parse_query/1` is the raw `application/x-www-form-urlencoded` parser
  (refuses `%` not followed by two hex digits; `+` = space; order + duplicates kept).
- `Nebu.OAuth.Http` already has `unrecognized/1`, `oauth_error/4`, `put_cors/1`, `ip_string/1`.
- `MatrixSessionStore` (0c + 000038): rows keyed by `access_token_hash`, `refresh_token_hash`
  UNIQUE; pending = `revoked_at IS NOT NULL AND grace_until IS NULL`; consumed = `grace_until IS
  NOT NULL`; `rotate_tokens/1` is the template for T10 (copy the lock order and the replay `FOR
  UPDATE` re-check, do not call it for OAuth rows: it copies only legacy columns and uses legacy
  expiry semantics).
- `HttpPublic.revalidate_with_idp/1` (`@doc false def`, same-domain reuse like the worker): needs a
  map with `oidc_refresh_token` and `user_id`; returns `{:ok, claims, new_rt | nil}` or `{:error,
  reason}`; `:no_oidc_refresh_token` is CONFIRMED (T6 prevents it for new sessions; if it still
  happens, e.g. mode switched to `per_refresh` later, it revokes: documented).
- `RefreshErrors.transient?/1`, `retry_after_seconds/1` (5 s, 30 s for IdP 429), `describe/1`.
- `OidcPlug.call_opaque/2`: expiry by `expires_at`, superseded branch, deactivation via the 60 s
  provision cache, `has_open_grace_window?/1` + `mark_access_token_used/1`.
- `DeviceBinding.put/4` is called by legacy login (`HttpPublic.respond_login/7`) and lazily by
  `/keys/upload` (`protected.ex` `maybe_bind_jwt_device/3`).
- `Nebu.Matrix.delete_user_device/2` shows the kill-switch order (denylist by hash, delete bindings,
  delete sessions, delete device) — T7 uses the first two steps only.
- `DeviceKeyStore.upsert_device/3` raises on a query error (`{:ok, _} = query(...)`): call it inside
  the transaction so a failure rolls back and maps to `:unavailable`.

### What must be preserved

- Legacy `POST /login` (opaque and raw-JWT branches), `POST /refresh` (rotation, replay, reuse,
  503 mapping), `RefreshWorker` (in-place extension, TOCTOU, race-safe delete), logout, device
  deletion, UIA freshness (`get_auth_context/1`), 000038 hashing guarantees.
- Story 1/2 behaviour and tests: DCR, metadata (apart from AC18), approval, authorize, callback,
  codes, pages, purge workers. Story 2's `CodeStore`/`AuthzStore` APIs unchanged.
- `Nebu.Matrix` facade boundaries: `lib/nebu/oauth/*.ex` only calls `Nebu.Matrix.*` public functions.

### Traps

1. **`OidcPlug` routes by `"."`**: OAuth tokens must stay 64 hex (no dots); never issue a JWT as an
   access token.
2. **`expires_at` means two things now** (T3): every legacy query that treats `expires_at` as the
   session/refresh bound (`active_sibling/1`, the worker, `extend_in_place`) must not see OAuth rows;
   every OAuth "session alive" check uses `session_expires_at`.
3. **Column-position code**: `MatrixSessionStore.resolve_refresh_token/1` pops computed columns at
   fixed index 8 (`List.pop_at(row, 8)` three times) after `select`-ing the 8 session columns;
   adding `auth_api` to `select_sql/1`/`row_to_session/1` shifts these positions. Adjust both or
   append the new column AFTER the computed ones; the existing tests catch a mismatch only partially.
4. **Postgres `NOW()` is the transaction start**: decide pending/consumed by `grace_until IS NULL`,
   never by comparing times (MatrixSessionStore moduledoc).
5. **Burned code on 503**: the code is consumed in AC5 step 1; every later 503 leaves the client
   with a dead code. Therefore the signing key is ensured BEFORE the session is created, and the
   session creation is one transaction.
6. **`Nebu.Matrix.active?/1` is fail-closed to `false`** (T19): never use it on the token endpoint.
7. **SecretBox raises without an internal secret** (`:admin_secret_at_rest` in tests): rescue at
   `ensure_active_key/0` and at the IdP-RT re-encryption, map to 503, log only the exception type.
8. **JOSE structs contain the private key**: never `inspect/1` a `%JOSE.JWK{}`, a key row, or an
   error tuple holding them (`Logger`, `raise`, ExUnit failure messages in tests: compare kids, not
   keys). `JOSE.JWK.to_public_map/1` for JWKS, assert no `"d"`.
9. **FK `ON DELETE RESTRICT`**: test cleanup (`cleanup_clients/1`, the e2e
   `clearOAuthClientsByIdPrefix` hook) must delete `matrix_sessions` rows of those clients first,
   or the DELETE fails.
10. **CORSPlug runs globally**; the token/JWKS responses KEEP CORS (unlike story 2's pages). The
    `Retry-After` header does not need `Access-Control-Expose-Headers` (clients act on status).
11. **`JsonBody`** must skip `/oauth2/token` before `Plug.Parsers` touches the body; read the body
    exactly once with `Plug.Conn.read_body/2` in `Token`.
12. **Config seam**: `T.enable_oauth/1` (story 1) + the new optional `:access_token_ttl_seconds` /
    `:idp_revalidation` map keys; `T.unreadable_oauth_config/0` for the `:unknown` 503.
13. **The story-2 test "token/revoke stay plain 404"** (`oauth_authorize_http_test.exs` ~line 90)
    and the `adr_033_test.exs` assertion that `matrix-api-scope.md` lists `/oauth2/token` as "not
    implemented" become wrong by design: change them in the same commit (revoke stays 404).
14. **Rate-limit ETS keys**: tests use `T.reset_rate_limits/0`, `:rate_limit_clock_fn`,
    `T.unique_ip/0` (the table is shared and never evicted, follow-ups I-3).
15. **The 000040 allowlist must be copied verbatim** when re-creating `config_update_mutable` (a
    dropped key silently turns its UPDATEs into no-ops); the migration test updates every 000040 key.
16. **`oauth_enabled` stays false** in every committed config; tests use the seam only.
17. **Unique index for "one active key"**: use `CREATE UNIQUE INDEX ... (status) WHERE status =
    'active'` (a plain column, no constant-expression index). `INSERT ... ON CONFLICT DO NOTHING`
    without a conflict target covers both the PK and this index.
18. **`DateTime` vs unix seconds**: the code row's `auth_time` is a `DateTime`, `matrix_sessions.auth_time`
    is BIGINT seconds (000012), the id_token wants integer seconds.

### Architecture compliance

ADR-018 inline SQL in `SigningKeyStore`, `OAuthSessionStore`, `ClientStore`; ADR-019 single app;
ADR-020 public-API-only cross-domain calls (T1) and no node-local state for correctness (atomic SQL
for code use, rotation, key generation; caches only for immutable key material and the existing
abuse-control buckets); ADR-022 no new env variables (server_config keys); ADR-033 broker model,
https issuer, only Nebu issues tokens; OIDC Scopes Law untouched (no IdP scope change in this
story); No Sensitive Data law (AC19).

### Library notes

- `:jose` 1.11.12 (lockfile): `JOSE.JWK.generate_key({:ec, "P-256"})`, `JOSE.JWK.thumbprint/1`
  (RFC 7638, SHA-256, base64url), `JOSE.JWK.to_map/1` / `to_public_map/1`, `JOSE.JWK.from_map/1`,
  `JOSE.JWT.sign(jwk, %{"alg" => "ES256", "kid" => kid, "typ" => "JWT"}, claims) |>
  JOSE.JWS.compact()`, test verification `JOSE.JWT.verify_strict(pub, ["ES256"], token)`.
  ES256 signatures are produced in JWS (R||S) form by JOSE; do not hand-roll `:crypto.sign/4` (DER).
- matrix-js-sdk 41.3.0 (oracle 2026-10-10): sends `grant_type`, `code`, `redirect_uri`,
  `code_verifier`, `client_id` form-encoded (oidc-client-ts `client_secret_post` without a secret),
  validates the id_token by decoding it (`iss` exact, `aud` contains client_id, `nonce`, `exp`); the
  signature check is ours to make correct, not the client's. Dart SDK 13: no `openid`, unstable
  prefix only.

### Testing commands (isolated env, see the epic brief)

`quick.sh --migrate` once (000042), then `quick.sh "mix test --include integration --warnings-as-errors
test/nebu/oauth test/nebu/migration test/nebu/matrix/session test/nebu/web/plugs"` plus the legacy
login/refresh/whoami/device tests (`grep -l "refresh\|login\|whoami\|devices" test/nebu/matrix
test/nebu/web -r`); full gate via `integration.sh` after `cleanup.sh` (new migration). Compare
failures with `scratchpad/known.txt` by name.

### Docs to touch (arc42 step and dev)

ADR-033 (AC20), `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`,
`docs/architecture/05-building-blocks.md` (new modules `Nebu.OAuth.Token`, `TokenRequest`,
`IdToken`, `SigningKeyStore`, `Nebu.Matrix.OAuthSession`, `Nebu.Matrix.Session.OAuthSessionStore`),
`docs/architecture/06-runtime.md` (token exchange + refresh sequence incl. Refresh-Retry and reuse),
`docs/architecture/08-concepts.md` ("OAuth 2.0 Authorization Server" section: sessions `auth_api`,
two expiries, signing keys/JWKS, error mapping), `docs/architecture/09-decisions.md` (ADR-033 row
mentions story 3), `docs/architecture/11-risks.md` (signing-key compromise = forged id_tokens for
clients that trust them; shared refresh bucket behind the proxy).

### Out of scope

`/oauth2/revoke` and logout integration (story 4), `oauth_aware_preferred` / `action` / UIA
`m.oauth` / coexistence flags (5), account page (6), device grant (7), mTLS / `private_key_jwt` (8),
`/versions` (9); all follow-ups.md items (trusted proxy, h, i, j, k, I-1..I-13); key rotation
tooling; device display names; enabling OAuth.

## Open questions

Resolved by the oracle gate (2026-10-10, `step-results/oauth-token-endpoint/oracle-context.md`):

- **O1 (T6):** fail closed at the code grant accepted (C9); earlier detection at the IdP callback is
  follow-up (l).
- **O2 (T26):** take-over accepted (C8); legacy-to-legacy reuse recorded as a spec deviation.
- **O3 (T15):** yes, id_token on refresh while `openid` is granted, without `nonce`.
- **O4 (T20):** replaced by C1: no `temporarily_unavailable` / `server_error` bodies at all; every
  5xx is `{}` + `Retry-After`.
- **O5 (T7):** no `display_name` for new OAuth devices is fine (follow-up note).
- **O6 (T16):** confirmed (C4): only `sub` is required on refresh, no `nonce`/`at_hash`/`azp`.

No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev-story, non-interactive, 2026-10-10)

### Debug Log References

- Targeted runs (`quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth
  test/nebu/migration test/nebu/matrix/session"`): run 1 1387/1400 (docs, one ADR-020 moduledoc
  mention, one deterministic-JWT test), run 2 1396/1400 (token-hashing guard tests, a reused-DB
  device-id collision); after the fixes all green (the full run below has no failure in these dirs).
- Full run (`quick.sh "mix test --include integration"`, reused quick DB): 4467 tests, 43 failures,
  3 skipped. All 43 are pre-existing / environment: TraceMap / WarRoom / TemporaryCapture / LogStore
  retention / sync-load families (in `known.txt`; `Nebu.Web.LogStore.WarRoomTest` passes when run
  alone) and 12 `Nebu.Admin.RoomsFallbackNameTest` (11 in the story-2 baseline; the 12th, "AC4 index
  page", fails for the same reason: the admin rooms index page no longer lists the test room on a
  reused DB with many rooms — every provisioned test user gets a personal room; not OAuth related).
- matrix_compat node test (oracle C6): fixture captured from the REAL responses by
  `NEBU_OAUTH_FIXTURE_OUT=... mix test test/nebu/oauth/oauth_signing_keys_test.exs`, then
  `NEBU_OAUTH_FIXTURE=<fixture> node oauth_metadata_test.js` in the scratchpad copy (node_modules
  symlinked read-only from the main checkout, which was not modified): all 16 checks passed
  (`validateAuthMetadataAndKeys`, openid-configuration discovery, `OidcTokenRefresher` 200 / 503 `{}`
  retryable / 400 `invalid_grant` logout / negative control).
- Compile: the only warning is the pre-existing type warning in
  `lib/nebu/matrix/event_dispatcher/server.ex:4813` (not touched).

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- Migration 000042 (new files only; 000040/000041 untouched): `matrix_sessions` gains `auth_api`
  (DEFAULT `legacy`), `client_id` (FK `ON DELETE RESTRICT`), `scope`, `session_expires_at`,
  `oauth_code_hash` + the two named CHECKs and two indexes; `oauth_signing_keys` with RLS (SELECT /
  INSERT fresh active / UPDATE, no DELETE), the one-active partial UNIQUE index and the
  `oauth_signing_keys_guard` trigger; `config_update_mutable` = 000040 list verbatim + the two token
  keys. Down restores 000040's policy.
- OAuth domain: `Nebu.OAuth.Token` (AC1-AC10 pipeline, every 5xx `{}` + `Retry-After`, rescue =>
  500 `{}`), `Nebu.OAuth.TokenRequest` (pure), `Nebu.OAuth.IdToken` (pure, `ES256` constant),
  `Nebu.OAuth.SigningKeyStore` (lazy single-winner generation via `INSERT ... ON CONFLICT DO NOTHING`
  + re-SELECT, verified load against `kid` AND `public_jwk`, per-node cache of decoded key material
  keyed by kid + ciphertext only), `Nebu.OAuth.Http` (`:token`, `:jwks`, `:openid_configuration`,
  three-state kill switch T22), `Config.token_settings/0`, `Metadata` (`jwks_uri`,
  `id_token_signing_alg_values_supported`, issuer must have an empty path), `ClientStore.touch_last_used/1`.
- Matrix domain: `Nebu.Matrix.OAuthSession` (issue / refresh / T28 guard / bounded race retries /
  T7 JWT kill switch after the commit), `Nebu.Matrix.Session.OAuthSessionStore` (inline SQL, every
  query `auth_api = 'oauth'`; the issuance transaction upserts the `devices` row FIRST so its row
  lock serializes concurrent issuances for the same device), five documented `Nebu.Matrix.oauth_*`
  facade functions (ADR-020: `lib/nebu/oauth/*.ex` names no Matrix-internal module).
- Legacy isolation (T27): `MatrixSessionStore` refresh/extension SQL filtered to `auth_api =
  'legacy'` (Trap 3: `auth_api` added to `select_sql/row_to_session`, computed columns popped at
  index 9), `mark_access_token_used/1` / `has_open_grace_window?/1` same-`auth_api` siblings,
  `cleanup_expired/0` uses `COALESCE(session_expires_at, expires_at)`; `RefreshWorker` candidates
  and the TOCTOU re-select skip non-legacy rows. T25: `DeviceBinding.put/4` guarded INSERT ... SELECT
  ... WHERE NOT EXISTS (a refused bind stores no row and does not prime the cache), new
  `DeviceBinding.lookup/1` (device + `oauth_device?` in the same cached query), `OidcPlug.call_jwt/2`
  refuses a JWT bound to an OAuth device. T26: legacy `/login` with a client `device_id` deletes that
  device's OAuth rows before registering the device.
- CORS (T32): `Nebu.Web.Router` now runs CORSPlug through a thin function plug: `credentials: false`
  ONLY for `/oauth2/token`, `/oauth2/jwks`, `/.well-known/openid-configuration` (responses and
  preflights), the CORSPlug defaults everywhere else (unchanged global behaviour).
- Logging (AC19/T29): `id_token` in both PayloadRedactor key lists; `/oauth2/token` in
  `@names_only_query_paths`; JsonBody skips `/oauth2/token` (request body never captured).
  Deviation: `RequestLogger` additionally never captures the RESPONSE body of `/oauth2/token`
  (`@no_response_body_paths`), because the token response carries the granted `scope` value, which
  T29/AC19 forbid in logs (the tokens themselves were redacted already).
- Test-only seams `:oauth_session_repo`, `:oauth_user_active_override`, `:oauth_rotate_override`,
  `:oauth_token_test_hook` are compile-time guarded (`if Mix.env() == :test`): in other builds the
  production default is compiled in. The hook is called first inside `handle_token/2`'s rescue.
- Tests changed by dev (story-mandated behaviour, minimal, documented):
  `test/nebu/matrix/session/token_hashing_test.exs` grep guards — the "only the store/worker touch
  matrix_sessions" allowlist gains `oauth_session_store.ex` and `device_binding.ex` (both required by
  T2/T25), and `device_binding.ex` is exempt from the "single hashing seam" guard (its SHA-256 is the
  raw-JWT binding key; it now mentions `matrix_sessions` only for the T25 EXISTS check). The rotate
  param of the OAuth store is named `active_access_token_hash` (not the legacy pass-the-hash
  `old_access_token_hash` the F-3 guard pins). `oauth_resource_server_test.exs` "lookup/1 of a
  normal binding": the "unbound" JWT gets a distinct `jti` (it was byte-identical to the bound JWT
  when both were signed in the same second). `oauth_token_refresh_grant_test.exs` "refresh after
  DELETE /devices/{id}": uses a unique device id (the pre-existing IDOR guard
  `belongs_to_other_user?/2` answers 404 when ANOTHER user has a device with the default id
  `AbCdEfGhIj`, which is the case on a reused DB).
- `apply/3` indirections in the new tests were left as they are: neither the story nor a test
  review finding asks for the conversion, and the pinned names are now all implemented.
- AC20 docs: ADR-033 section "Token endpoint, sessions, refresh and id_token (story 3)" with T1-T33,
  the two deliberate deviations (C10 proof-gated code-reuse revocation incl. the double-submit risk,
  C8 legacy-to-legacy device reuse), the issuer-path constraint and the story-3 gate paragraph;
  `docs/matrix-api-scope.md` (token ✅, jwks ✅, openid-configuration ✅, revoke still story 4,
  `/refresh` legacy sessions only); `follow-ups.md` story-3 section (a)-(f) + gate items (l), (m).
  arc42 is left to the arc42 step. `oauth_enabled` stays default off; nothing enables it.

### Review cycle 1 (code review 0 MAJOR / 6 MINOR, Kassandra F-1 MEDIUM)

- Kassandra F-1 + MINOR 4 (`Nebu.Matrix.OAuthSession.confirmed_rejection/4`): the T28 "lost race"
  skip now requires a genuine IdP rejection (`{:token_endpoint_status, 400|401}` / `:invalid_grant`)
  AND a NEW IdP-RT ciphertext on the active row; the access-token-hash disjunct is gone, Nebu-side
  verdicts (`:deactivated`, `:no_oidc_refresh_token`, decrypt failures, 403, ...) always revoke. New
  tests: concurrent winner without a rotated IdP RT (final), both IdP calls 400, 403 and
  `:deactivated` with a rotating winner (revoked).
- MINOR 1: kill-switch 404 of `/oauth2/token`, `/oauth2/jwks`, `/.well-known/openid-configuration`
  (and their sub-paths) is `{"errcode":"M_UNRECOGNIZED"}` without an `error` member
  (`Http.unrecognized_no_error/1`); metadata and register keep their bodies. NOTE: the story text of
  T22 / the AC10 table row ("OAuth disabled ... Matrix shape, C2") predates this decision; ADR-033 T22
  carries the current text and the tests (`T.assert_unrecognized_404_no_error/1`) pin it.
- MINOR 2: `OAuthSessionStore.rotate/1` takes the same `devices` row lock as the issuance upsert
  before its guarded UPDATE (lock order devices -> matrix_sessions). Deterministic test: the rotation
  blocks while a transaction holds the devices row and, after that transaction deleted the device's
  rows (a re-login), fails closed (`invalid_grant`, no surviving row). Residual: a device whose
  `devices` row is missing locks nothing (guarded UPDATE still decides).
- MINOR 3: a failing revoke in the refresh reuse path answers 503 `{}` + `Retry-After` (session
  survives, the retry re-detects the reuse); a failing code-reuse revoke is logged at WARNING
  ("revocation FAILED", no secrets) and still answers `invalid_grant`. Tests use a privileged
  BEFORE DELETE trigger (`T.block_session_deletes!/1`).
- MINOR 5/6: migration 000042 edited in place (not committed yet): partial index
  `idx_matrix_sessions_client_id`, matching DROP in down, header no longer claims "no stop-the-world"
  (short locks while the CHECKs/FK scan `matrix_sessions`). Migration test extended; quick DB reset.
- INFO 4: the lost-rotated-IdP-RT edge case is documented in ADR-033 T28.
- Verification: `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth
  test/nebu/migration test/nebu/matrix/session test/nebu/web/plugs"`: 1482 passed. `MIX_ENV=prod mix
  compile` in the quick container (the Dockerfile builds with `MIX_ENV=prod mix release`): compiles,
  the only warnings are the pre-existing `event_dispatcher/server.ex:4813` type warning and the
  deprecated `xref` option in mix.exs; the seam stubs (`if Mix.env() == :test`) produce none.

### File List

- `server/priv/migrations/000042_oauth_sessions_and_signing_keys.up.sql` (new)
- `server/priv/migrations/000042_oauth_sessions_and_signing_keys.down.sql` (new)
- `server/lib/nebu/oauth/token.ex` (new)
- `server/lib/nebu/oauth/token_request.ex` (new)
- `server/lib/nebu/oauth/id_token.ex` (new)
- `server/lib/nebu/oauth/signing_key_store.ex` (new)
- `server/lib/nebu/matrix/oauth_session.ex` (new)
- `server/lib/nebu/matrix/session/oauth_session_store.ex` (new)
- `server/lib/nebu/oauth.ex`
- `server/lib/nebu/oauth/http.ex`
- `server/lib/nebu/oauth/config.ex`
- `server/lib/nebu/oauth/metadata.ex`
- `server/lib/nebu/oauth/client_store.ex`
- `server/lib/nebu/matrix.ex`
- `server/lib/nebu/matrix/http_public.ex`
- `server/lib/nebu/matrix/session/matrix_session_store.ex`
- `server/lib/nebu/matrix/session/refresh_worker.ex`
- `server/lib/nebu/matrix/session/device_binding.ex`
- `server/lib/nebu/web/router.ex`
- `server/lib/nebu/web/plugs/json_body.ex`
- `server/lib/nebu/web/plugs/oidc_plug.ex`
- `server/lib/nebu/web/plugs/request_logger.ex`
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex`
- `server/test/nebu/matrix/session/token_hashing_test.exs` (guard allowlists, see Completion Notes)
- `server/test/nebu/oauth/oauth_resource_server_test.exs` (distinct `jti`, see Completion Notes)
- `server/test/nebu/oauth/oauth_token_refresh_grant_test.exs` (unique device id, see Completion Notes)
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`
- `docs/matrix-api-scope.md`
- `docs/stories/oauth-broker/follow-ups.md`
- `docs/stories/oauth-broker/oauth-token-endpoint.md` (Dev Agent Record, status)
- Review cycle 1 additionally touched `server/test/nebu/oauth/{oauth_test_support,oauth_token_http_test,oauth_token_code_grant_test,oauth_openid_configuration_test,oauth_signing_keys_test,oauth_authorize_http_test}.exs`, `server/test/nebu/migration/000042_oauth_sessions_signing_keys_test.exs`, `server/test/nebu/matrix/session/oauth_session_store_test.exs`
- ATDD files (staged before dev, unchanged unless listed above): `server/test/nebu/oauth/*` story-3
  tests, `server/test/nebu/migration/000042_oauth_sessions_signing_keys_test.exs`,
  `server/test/nebu/matrix/session/oauth_session_store_test.exs`,
  `tests/matrix_compat/oauth_metadata_test.js`, `tests/matrix_compat/package.json`

## Change Log

- **2026-10-10:** Story created (create-story, non-interactive) for story 3 of epic oauth-broker:
  token endpoint (authorization_code + refresh_token), sessions in `matrix_sessions` with
  `auth_api`, Refresh-Retry/reuse, error mapping, ES256 Nebu id_token + JWKS, migration 000042,
  decisions T1-T33, open questions O1-O6.
- **2026-10-10 (oracle-amended):** C1 (every 5xx `{}` + `Retry-After`, no `error` member; T20, AC1,
  AC4, AC10, Must #2), C2 (T22 rationale), C3 (empty = omitted: T23, T24, AC2, AC3, T13), C4/C5
  (T16), C6 (jwks_uri required, matrix_compat node test), C7 (T31, AC21 `/.well-known/openid-configuration`,
  issuer-path constraint, follow-up m), C8 (T26), C9 (follow-up l), C10 (T8 deviation in ADR-033),
  C11 (AC8), C12 (T13/AC11 set + prefix-normalized), C13 (T33), C15 (T32); extra tests; O1-O6
  resolved.
- **2026-10-10 (ATDD):** red-phase ExUnit tests (446 of 1175 in the OAuth/migration run fail for
  missing routes/modules/schema/docs) + matrix_compat node test; section "ATDD Decisions (story 3)"
  appended (pinned APIs, 4 new seams, 6 story contradictions/gaps with proposed text).

- **2026-10-10 (dev-story):** implemented T1-T33 / AC1-AC21: migration 000042, token endpoint
  (both grants), Nebu-signed ES256 id_token + JWKS + openid-configuration, OAuth sessions in
  `matrix_sessions` behind five `Nebu.Matrix` facade functions, legacy isolation (T25-T27), scoped
  CORS credentials removal, logging/redaction, docs (ADR-033, matrix-api-scope, follow-ups l/m).
  All story-3 tests green; status `review`.

## ATDD Decisions (story 3)

Written by the ATDD role (2026-10-10, red phase). Run (`quick.sh "mix test --include integration
--warnings-as-errors test/nebu/oauth test/nebu/migration test/nebu/matrix/session/oauth_session_store_test.exs"`):
1175 tests, 446 fail, 729 pass (all story-1/2 tests green; the new files' passing tests are
regression guards); `test/nebu/matrix/session` + `test/nebu/web/plugs`: 317 tests, only the 20 new
`OAuthSessionStoreTest` tests fail. Every failure is a missing route (`/oauth2/token`, `/oauth2/jwks`,
`/.well-known/openid-configuration` => router `404 not found`), a missing module/function
(`UndefinedFunctionError`), the missing 000042 schema (`oauth_signing_keys`, `matrix_sessions.auth_api`),
missing metadata fields, or missing docs. `--warnings-as-errors` compiles (all calls into new code go
through `apply/3`). The dev MUST implement against these names; changing one means changing the
tests in the same commit.

### Test files

`server/test/nebu/oauth/`: `oauth_token_request_test.exs` (unit, AC2/AC11/PKCE),
`oauth_id_token_test.exs` (unit, AC12), `oauth_token_http_test.exs` (AC1-AC4, T20-T24, T32),
`oauth_token_code_grant_test.exs` (AC5-AC8, AC12, T6-T8, T19, T30, T33),
`oauth_token_refresh_grant_test.exs` (AC9-AC11, AC10 table, T10-T13, T28), `oauth_signing_keys_test.exs`
(AC13, C6 fixture), `oauth_openid_configuration_test.exs` (AC21, AC18 issuer path),
`oauth_resource_server_test.exs` (AC16, AC17, T25-T27), `oauth_token_e2e_test.exs` (happy path),
`oauth_token_logging_test.exs` (AC19), `oauth_token_static_test.exs` (T1, files, router, JsonBody,
secure_compare, ES256 constant); extended: `oauth_config_test.exs` (AC15, + unit module
`OAuthTokenSettingsTest`), `oauth_metadata_test.exs` (AC18), `oauth_payload_redaction_test.exs` /
`oauth_request_logger_redaction_test.exs` (AC19), `adr_033_test.exs` (AC20), `oauth_test_support.exs`.
`server/test/nebu/matrix/session/oauth_session_store_test.exs` (Matrix facade, AC7/AC9).
`server/test/nebu/migration/000042_oauth_sessions_signing_keys_test.exs` (AC14).
`tests/matrix_compat/oauth_metadata_test.js` (C6, Must #36).

Deliberately changed story-2 tests (Trap 13): `oauth_authorize_http_test.exs` "token/revoke stay plain
404" is now revoke-only plus "/oauth2/token is routed (enabled) / M_UNRECOGNIZED (disabled)";
`adr_033_test.exs` "matrix-api-scope lists /oauth2/token not implemented" is now revoke-only plus a
story-3 assertion; `oauth_metadata_test.exs` "no jwks_uri passthrough" now asserts Nebu's own
`jwks_uri`, the allowed-field set gains `jwks_uri` + `id_token_signing_alg_values_supported`.
`T.cleanup_clients/1` deletes the clients' `matrix_sessions` rows first (FK RESTRICT, Trap 9; guarded
on the column's existence).

### Pinned APIs

- `Nebu.OAuth.TokenRequest`: `validate_params(pairs) :: {:ok, %{name => value}} | {:error, :invalid_request}`
  (AC2 steps 5-6: duplicates incl. one empty value, `\p{Cc}` incl. C1, invalid UTF-8; empty values
  dropped afterwards; unknown names kept); `valid_content_type?(header | nil) :: boolean`;
  `valid_verifier?/1`; `pkce_valid?(verifier, challenge)` (format first, then S256 via
  `Plug.Crypto.secure_compare/2`); `narrow_scope(requested | nil, granted)`;
  `valid_refresh_token_format?/1` (64 LOWERCASE hex only, checked before any `OAuthSessionStore` access).
- `Nebu.OAuth.IdToken.claims(%{issuer:, user_id:, client_id:, auth_time:, nonce:}, now)` (exact claim
  set, `auth_time`/`nonce` omitted when nil), `IdToken.sign(claims, %{kid:, jwk: %JOSE.JWK{}})` ->
  compact JWS, protected header exactly `alg`/`kid`/`typ`.
- `Nebu.OAuth.SigningKeyStore.ensure_active_key/0 :: {:ok, %{kid:, jwk:}} | {:error, term}`
  (`{:error, :key_inconsistent}` for a swapped ciphertext; never raises, also without SecretBox
  secret), `published_keys/0 :: {:ok, [public_map]}` (active first, retired with `not_after > now()`
  newest first by `created_at`).
- `Nebu.OAuth.Config.token_settings/0 :: %{access_token_ttl_seconds:, idp_revalidation:}`. Seam
  values (`enable_oauth/2`) are the raw `server_config` text or integer/atom: TTL integer 60..3600
  else 900 (`"900.5"`, `""`, `"0"`, junk => 900); mode `"off"`/`:off` => `:off`, anything else
  (incl. `""`, nil, unknown) => `:per_refresh`; `:unknown`/disabled config => defaults.
- `Nebu.Matrix` facade: `oauth_issue_session/1`, `oauth_resolve_refresh_token/1`,
  `oauth_refresh_session(session, :current | :replay, rt, %{scope:, idp_revalidation: :per_refresh | :off, access_ttl_seconds:})`,
  `oauth_revoke_device_session/2`, `oauth_revoke_sessions_for_code/1` (all with `@doc`); shapes as
  in AC7/AC9. `Nebu.Matrix.OAuthSession.user_active/1 :: {:ok, boolean} | {:error, term}` (unknown
  user => `{:ok, false}`).
- `Nebu.Matrix.Session.DeviceBinding.lookup/1 :: {:ok, device_id | nil, oauth_device? :: boolean}`
  (unbound => `{:ok, nil, false}`); a refused `put/4` stores no row AND does not prime the cache.
  T25c 401 error text contains "Access token has been revoked".
- Files: `lib/nebu/oauth/{token,token_request,id_token,signing_key_store}.ex`,
  `lib/nebu/matrix/oauth_session.ex`, `lib/nebu/matrix/session/oauth_session_store.ex`; JsonBody
  skips `path_info: ["oauth2", "token" | _]`; router `forward "/oauth2/token" ... [action: :token]`,
  `"/oauth2/jwks" ... [action: :jwks]`, a `/.well-known/openid-configuration` route; no `/oauth2/revoke`.
- Texts: T6 `error_description` exactly "Sign-in cannot be completed: the server is not configured
  for refreshable sessions." + exactly ONE log line naming `matrix_oidc_refresh_mode=offline` or
  `oauth_idp_revalidation=off`; AC6 WARNING contains "authorization code reused"; refresh-token reuse
  and confirmed IdP rejection log at `[warning]` (text not pinned).
- Docs (AC20 tests): ADR section heading "Token endpoint, sessions, refresh and id_token (story 3)"
  with T1..T33; the gate paragraph mentions `/oauth2/revoke`, "story 4", `oauth_token`;
  matrix-api-scope rows `| POST | \`/oauth2/token\` | ✅` (mentions `authorization_code`,
  `refresh_token`, `429`), `| GET | \`/oauth2/jwks\` | ✅`, revoke "not implemented ... story 4",
  `/refresh` "legacy sessions only", `/.well-known/openid-configuration`; follow-ups.md
  `## ... oauth-token-endpoint` section with `oauth_jwks`, rotation runbook/`not_after`,
  `display_name`, UIA/`m.oauth`, legacy-to-legacy deviation, items (l)/(m).

### Seams (test support `Nebu.OAuth.TestSupport`, section "Story 3")

- Existing: `:oauth_config_source` (+ keys `:access_token_ttl_seconds`, `:idp_revalidation`),
  `:oauth_repo` NoSuchRepo (also `SigningKeyStore` and the client lookup => 503 `{}`),
  `:matrix_oidc_refresh_override`, `:session_manager, :validator_module`, `:rate_limit_clock_fn`,
  `:admin_secret_at_rest` (deleted => SecretBox raises => 503), `:uia_fresh_auth_seconds`,
  `:matrix_refresh_worker_lookahead_seconds`.
- NEW `:nebu_http, :oauth_session_repo` (default `Nebu.Repo`): repo of `OAuthSessionStore` and of
  the T19 read; NoSuchRepo => `:unavailable` => 503 `{}`. Legacy `MatrixSessionStore`/`OidcPlug` keep
  `Nebu.Repo`.
- NEW `:nebu_http, :oauth_user_active_override`: 1-arity `user_id -> {:ok, boolean} | {:error, term}`
  replacing the T19 read (code grant AC7.1, refresh `off` mode). Replaces the story's "validator_module
  seam" for the `off`-mode DB failure (the T19 read is a plain SELECT, not `TokenValidator`).
- NEW `:nebu_http, :oauth_rotate_override`: 1-arity, called INSTEAD of the OAuth rotation with its
  params map; `:error` = lost race (bounded re-resolve, exhaustion => 503), raise => 503, session intact.
- NEW `:nebu_http, :oauth_token_test_hook`: 0-arity fun called FIRST in `Token.handle_token/2`
  (before the body is read, inside the rescue); a raise => rescued `500 {}` + `Retry-After` and the
  AC1 headers (the exception message is not logged). The test sends a fully valid refresh request,
  so a later hook position also passes; the rescue must cover the whole handler.
- All four NEW seams are compile-time guarded (`Mix.env() == :test`), see Dev Notes "Test-only seams".
- Rate-limit keys: `{"oauth_token", ip}` (10, 600), `{"oauth_token_refresh", ip}` (100, 1200),
  `{"oauth_jwks", ip}` (10, 600), ip = `:inet.ntoa/1` string.
- Order assumptions: a request WITHOUT `client_id` answers `401 invalid_client` before any DB lookup
  and before the `grant_type` checks (so content-type/charset/16384-byte tests end in 401); a malformed
  `refresh_token` => `invalid_grant` after client authentication.
- Time: no sleeps. Expiries/delays are shifted via SQL on `matrix_sessions` (respecting
  `expires_at <= session_expires_at`); expired codes are inserted directly (`T.insert_code!/2`,
  `created_at = now() - 120 s`, `expires_at = now() - 60 s`; the 000041 guard forbids changing
  `expires_at`). `expires_in` is checked against `floor(expires_at - created_at)` of the row, so both
  columns must use the same `now()` (T33).
- Signing keys: tests empty `oauth_signing_keys` with the privileged role (`T.reset_signing_keys!/0`);
  every story-3 test uses the `setup_idp!/1` SecretBox secret so a lazily generated key stays
  decryptable across test files.

### Contradictions / gaps in the story text (proposed text)

Resolved by the test review (2026-10-10) and folded into the story text above:

1. **CORS credentials (T32):** CORSPlug's default `credentials: true` adds ACAC everywhere; the
   removal is scoped to the three OAuth paths incl. their preflights, global CORS unchanged.
2. **AC17:** `/logout/all` replaced by "POST /logout, DELETE /devices/{id}, admin deactivation";
   `/logout/all` is a pre-existing gap, out of scope.
3. **`off`-mode DB failure seam:** `:oauth_user_active_override` (validator seam kept for `per_refresh`).
4. **AC9:** malformed refresh token => `invalid_grant` after client authentication, before any
   `OAuthSessionStore` access; uppercase hex invalid.
5. **AC21 405:** `{"error":"invalid_request","error_description":"Method not allowed."}` +
   `Allow: GET, OPTIONS` (test tightened).
6. **Concurrent code redemption:** invariant "exactly one 200, at most one active row, never a live
   session without a 200"; double-submit risk recorded in T8 (and for ADR-033). AC2: client
   authentication precedes the `grant_type` dispatch.

Test-review MINORs fixed: code-grant signing-key 503 test empties the key table first; the key
generation race runs 5 rounds with a start barrier; new T18 test "kid matches the decrypted key but
`public_jwk` differs => `:key_inconsistent`"; new test "reuse of a consumed RT of an EXPIRED session
=> `invalid_grant`, rows unchanged"; static router/JsonBody pins loosened; ADR error-mapping
assertions are line-structured; the refresh-grant DELETE /devices test is strict (no fallback);
the C6 fixture captures Nebu's real 200 / 503 `{}` / 400 responses for replay.

### matrix_compat node test

`tests/matrix_compat/oauth_metadata_test.js` (inputs `NEBU_OAUTH_FIXTURE` = JSON written by
`oauth_signing_keys_test.exs` when `NEBU_OAUTH_FIXTURE_OUT` is set, or `NEBU_MATRIX_URL`; neither =>
"not executed", exit 2): `validateAuthMetadataAndKeys`, discovery URL
`new URL(".well-known/openid-configuration", issuer)`, `OidcTokenRefresher` (200 => tokens incl.
refreshToken; 503 `{}` => retryable; 400 `invalid_grant` => `TokenRefreshLogoutError`; negative
control 503 with `error` => logout). Self-check against a SIMULATED fixture in a scratchpad copy
(node_modules symlinked read-only from the main checkout): PASS (14/14). Against Nebu: not executed
(red phase).
