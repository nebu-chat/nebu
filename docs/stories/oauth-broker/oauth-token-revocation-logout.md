---
story_id: oauth-token-revocation-logout
title: "Token revocation (RFC 7009 POST /oauth2/revoke) + logout integration for OAuth sessions"
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

Story 4 of epic `oauth-broker` (spec section 13 row 4; spec sections 6, 7, 8, 10). It lets an OAuth
session end cleanly and makes the advertised `revocation_endpoint` real:

1. **`POST /oauth2/revoke`** (RFC 7009, Matrix CS API v1.15+ "Token revocation", spec 7):
   form-encoded, NO client authentication (`client_id` optional; a missing or wrong `client_id`
   still revokes), `token` may be the access OR the refresh token of an OAuth session in ANY state
   (active, expired access token, superseded pending/consumed rows, expired session),
   `token_type_hint` is advisory. A hit ends the WHOLE OAuth session of the device: every
   `matrix_sessions` row of `(user_id, device_id)` (incl. the SecretBox ciphertext of the IdP
   refresh token), the `devices` row with its E2EE key material and any bound raw-JWT credential.
   Unknown / malformed / legacy / JWT tokens are answered `200 {}` (`application/json`) and touch
   nothing (RFC 7009 2.2). Same envelope as the token endpoint: `Cache-Control: no-store`,
   `Pragma: no-cache`, CORS `*` (on EVERY status) without credentials, 16 KiB body cap, own per-IP
   rate limit charged before any DB access, every 5xx `{}` + `Retry-After`. Unlike the other OAuth
   endpoints revoke stays LIVE while OAuth is disabled or the issuer is invalid (it can only delete;
   oracle O5); only an unreadable config answers `503 {}`.
2. **One revocation function** on the Matrix side (`Nebu.Matrix.OAuthSession`), atomic and
   cluster-safe (devices-row lock shared with issuance and rotation, so a revocation never races a
   rotation into a surviving row), reached from the OAuth domain only through the new facade
   function `Nebu.Matrix.oauth_revoke_token/1` (ADR-020).
3. **Logout integration** (spec 7: "`POST /logout` and `/logout/all` remain and call the same
   function"): `POST /_matrix/client/v3/logout` with an OAuth access token ends ONLY that device's
   session through the same function (today it wipes every session of the user);
   `POST /_matrix/client/v3/logout/all` is routed for the first time and ends every session of the
   user and deletes ALL devices of the user with their keys (Matrix spec; oracle correction of
   R17). Legacy `/logout` semantics are unchanged (recorded spec deviation, new gate item).
4. **Deprovisioning paths**: admin deactivation is verified to kill OAuth sessions (unchanged);
   the GDPR key erasure (`delete_user_keys`) gets the missing session kill.
5. After a revocation the resource server answers `401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout`
   (spec 6: a destroyed session has no soft logout) and the refresh token is `invalid_grant`.

`oauth_enabled` stays `false` by default and nothing in this story enables it; the follow-ups.md
gate items (trusted proxy, h, i, l, m, n, ...) are NOT solved here and still block it. Stories 5
(legacy coexistence, UIA delineation), 6 (account page, device delete for OAuth sessions) and 9
(`/versions`) are out of scope.

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 6, 7, 8, 10,
13; `docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (story-3 section T1-T33);
story 3 `docs/stories/oauth-broker/oauth-token-endpoint.md` (Dev Agent Record = what exists);
`docs/stories/oauth-broker/follow-ups.md` (story-2 (c), story-3 (d), (e), gate items n, o, p);
oracle gate of this story `_bmad-output/nebu/epics/oauth-broker/step-results/oauth-token-revocation-logout/oracle-context.md`
(binding, folded in; see "Open questions" and the Change Log);
Kassandra reports `docs/stories/oauth-broker/security-reports/oauth-authorize-idp-delegation-code-security-review-2026-10-10.md`
and `.../oauth-token-endpoint-security-review-2026-10-10.md`;
`_bmad-output/nebu/epics/oauth-broker/step-results/oauth-token-endpoint/oracle-context.md` (C1, C2,
C15: `error` member semantics, CORS); `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`
(checklist item 8: "Revocation returns 200 for unknown tokens and deletes the whole session");
RFC 7009 2.1 / 2.2 / 2.2.1 / 3 / 5, RFC 6749 3.1 / 5.2, Matrix CS API "Token revocation",
`POST /logout`, `POST /logout/all`, "soft logout".

## Story

As a **Matrix user of an OAuth-capable client (Element Web / matrix-js-sdk + oidc-client-ts,
FluffyChat / Dart SDK)**,
I want "Sign out" in my client to really end the session on the server (also when my access token
already expired), and "sign out everywhere" to end all of my sessions,
so that a token left on a device, in a backup or in a crashed client can no longer be used or
refreshed, and Nebu keeps no IdP refresh token for a session I ended.

## Decisions

Prefix `R` (revocation story), so the IDs never collide with story 2's `D1`-`D23` or story 3's
`T1`-`T33` in ADR-033. ADR-033 gets a new section with R1-R24 (AC13).

- **R1 (module boundaries, ADR-020).** OAuth domain: `Nebu.OAuth.Revoke` (HTTP orchestration of
  `POST /oauth2/revoke`) and `Nebu.OAuth.FormPost` (the form-POST plumbing EXTRACTED from
  `Nebu.OAuth.Token`: raw body read, parse order, JSON/error/5xx responses; `Token` delegates to it
  with byte-identical behaviour, no second copy). Matrix domain: `Nebu.Matrix.OAuthSession`
  (`revoke_token/1`, `end_device_session/2`, `end_all_for_user/1`) and
  `Nebu.Matrix.Session.OAuthSessionStore` (inline SQL). The OAuth domain reaches it ONLY through
  the new facade function `Nebu.Matrix.oauth_revoke_token/1`; `lib/nebu/oauth/*.ex` keeps naming no
  Matrix-internal module (story-3 static test). `Nebu.Web.Router.Protected` (logout) and
  `Nebu.Matrix.EventDispatcher.Server` (erasure) call `Nebu.Matrix.oauth_revoke_token/1` /
  `Nebu.Matrix.oauth_end_user_sessions/1` (facade, so the web layer does not grow new direct calls
  into `Nebu.Matrix.Session.*`).
- **R2 (what a revocation ends = Matrix logout semantics).** A hit ends the device's OAuth session
  completely, in ONE transaction: every `matrix_sessions` row of `(user_id, device_id)` (no
  `auth_api` filter: after T7/T26 a device only ever has rows of one API, and "all rows of the
  device" leaves nothing redeemable; the IdP refresh-token ciphertext dies with the rows), and the
  `devices` row with `device_keys`, `device_one_time_keys`, `device_fallback_keys`. After the commit,
  best effort: the S3 JWT kill-switch for the device (`DeviceBinding.list_for_user_device/2` ->
  `TokenDenylist.revoke_by_hash/2` -> `DeviceBinding.delete_for_user_device/2`, normally empty for an
  OAuth device, T25) and the per-device legacy `sessions` / `sync_tokens` rows
  (`SessionSupervisor.destroy_session/2`). Rationale: Matrix `POST /logout` "The device associated
  with the access token is also deleted. Device keys for the device are deleted alongside the
  device"; revocation IS the OAuth client's logout; keeping the device would leave a ghost device
  with live E2EE keys in `/devices` and in other users' key queries. Contrast (unchanged, story 3):
  the T11 refresh-token-reuse and T8 code-reuse revocations delete only the OAuth rows and keep the
  device (they are security reactions, not a user's logout). Legacy `/logout` keeps its devices
  (pre-existing deviation, R16). Confirmed by the oracle gate (O1).
- **R3 (token lookup: either token, any state, one statement).** The presented token is hashed once
  (`MatrixSessionStore.hash_token/1`) and looked up with ONE statement
  `WHERE (access_token_hash = $1 OR refresh_token_hash = $1) AND auth_api = 'oauth'` WITHOUT any
  state filter: it finds the active row, an EXPIRED access token (`expires_at <= now()`, the Dart SDK
  revokes with a possibly expired access token, spec 7), superseded rows (pending or consumed
  refresh tokens, superseded access tokens) and rows of an expired session (`session_expires_at <=
  now()`; ending it is a harmless cleanup + device logout). Rows purged by `cleanup_expired/0`
  (`session_expires_at + 7 d`) are unknown => 200. `token_type_hint` is IGNORED for the lookup (RFC
  7009 2.1: the server MAY ignore it and MUST extend the search to all types; one statement over both
  indexed columns means the hint can change neither the result nor the timing); any hint value,
  also an unknown one (`id_token`, junk), is accepted (subject only to the generic parameter checks
  of R8).
- **R4 (no client authentication; `client_id` advisory).** Nebu performs NO client
  authentication on revoke (spec 7 / Matrix "SHOULD NOT require client authentication"; metadata
  already advertises `revocation_endpoint_auth_methods_supported: ["none"]`). `client_id` is
  optional, is NOT looked up in `oauth_clients` (no DB access, no oracle about registrations), and a
  missing or different `client_id` still revokes. This CONFORMS to the Matrix spec (missing/wrong
  `client_id`: the server SHOULD still revoke; it MAY warn), which takes precedence over the RFC 7009
  2.1 client-binding check ("verifies whether the token was issued to the client making the
  revocation request"); ADR-033 records it in that wording (oracle gate), NOT as a deviation. The
  token itself is the credential, and refusing a logout leaves a live session behind. Accepted
  consequence (oracle): a leaked LEGACY token cannot be killed through `/oauth2/revoke` (R5). A
  `client_secret` parameter and any `Authorization` header (Basic or Bearer) are IGNORED (unlike the
  token endpoint's T24, which answers 401: there a secret would be an authentication attempt, here
  nothing is authenticated and rejecting would only keep a session alive).
- **R5 (unknown / malformed / legacy => 200, no side effects).** A `token` that is not 64 lowercase
  hex (`TokenRequest.valid_refresh_token_format?/1`; every Nebu opaque token has that shape, a JWT
  has dots) => `200` WITHOUT any DB access. A well-formed token without an `auth_api = 'oauth'` row
  (unknown, already revoked, a LEGACY opaque access/refresh token, an authorization code) => `200`, no
  row touched: OAuth and legacy are mutually incompatible APIs (spec 8), `/oauth2/revoke` never acts
  on legacy sessions.
- **R6 (response shapes; oracle C1 applied to revoke; oracle O3 decision).** Success and "unknown
  token": `200` with the body `{}` and `Content-Type: application/json` (RFC 7009 2.2: the client
  ignores the body; a JSON body is safer for JSON-parsing clients, and every Nebu JSON response
  carries the JSON content type). oidc-client-ts `JsonService.postForm` (used by
  `OidcClient.revoke`) accepts it (`Content-Type` starts with `application/json`, `{}` parses); a
  `text/*` type would make it THROW ("Invalid response Content-Type"). Every 4xx: RFC 6749 5.2 shape `{"error",
  "error_description"}` (`429`: `{"error":"too_many_requests"}`), `application/json`, never
  `errcode`. Every 5xx (`503` DB/config, `500` rescued exception): `Retry-After` + body `{}`, no
  `error` member (T20 contract kept for ALL OAuth endpoints; RFC 7009 2.2.1: on 503 "the client must
  assume the token still exists and may retry"). For revoke the `error` member does not decide a
  logout (the client IS logging out; oidc-client-ts throws for any non-2xx, `ErrorResponse` with
  `error`, plain `Error` without), so the shapes are chosen for one uniform contract, not for client
  classification. Client behaviour on a failed revoke: matrix-js-sdk 41.3.0 itself never calls the
  revocation endpoint (it only requires `revocation_endpoint` in `validateAuthMetadataAndKeys`); the
  application (Element Web) calls oidc-client-ts `OidcClient.revokeToken(token, hint)` for the access
  and the refresh token IN PARALLEL, clears its local session even when that fails and does NOT call
  `/logout` (oracle O4), so
  a failed revoke leaves the server session alive until `session_expires_at`: transient failures are
  503 (retryable), never a silent 200.
- **R7 (error reachability: 400 / 401 per spec 7).** Reachable: `400 invalid_request` (query
  string, wrong content type, malformed form encoding, duplicated parameter, control character /
  invalid UTF-8, `token` missing or empty), `413 invalid_request` (body > 16 KiB), `405
  invalid_request` (`Allow: POST, OPTIONS`; also for `HEAD`), `429 too_many_requests`, `404` for a
  sub-path, `503` / `500` `{}`. The endpoint itself never answers 404 (R13). UNREACHABLE by design (documented, tested as "never"): `401 invalid_client` (spec 7 "401 bei
  fehlender Berechtigung" = RFC 7009 2.2.1 `invalid_client`, which requires a failed client
  authentication, and Nebu authenticates no client, R4) and `400 unsupported_token_type` (both token
  types are supported; hints are ignored, R3).
- **R8 (request format = T23).** POST only; `Content-Type: application/x-www-form-urlencoded`
  (parameters such as `charset` allowed); raw body read once by the handler (cap 16 384 bytes,
  `Nebu.Web.Plugs.JsonBody` skips `/oauth2/revoke`, `conn.body_params` stays `Unfetched`, so
  `RequestLogger` never captures the `token`); parsed with `AuthorizeRequest.parse_query/1` and
  validated with `TokenRequest.validate_params/1` (duplicates incl. one empty occurrence =>
  `invalid_request`; `\p{Cc}` / invalid UTF-8 => `invalid_request`; afterwards empty values are
  omitted, RFC 6749 3.1, so `token=` is a missing `token`). A non-empty query string =>
  `invalid_request` (credentials never in URLs; the token is NOT revoked, a client that leaks it in
  the URL gets an error and the query is logged names-only). Unknown parameters are ignored. The
  `token` value is compared AFTER form-decoding (a percent-encoded hex token is decoded first, then
  format-checked and revoked); it is NOT trimmed (a token with surrounding spaces fails the format
  check => 200 no-op, R5). `Content-Type` comparison is case-insensitive (`Application/X-WWW-Form-Urlencoded`
  accepted).
- **R9 (rate limit).** Node-local abuse control `{"oauth_revoke", ip}` = `RateLimit.take/3` with
  rate 60/min, burst 600 (3600/h per IP), charged AFTER the config read and the body parse (a request
  failing R8 is charged too, before its 4xx; the token-endpoint pattern) and BEFORE any DB access;
  exhausted => `429 {"error":"too_many_requests"}` + `Retry-After` (a 429 on revoke logs nobody out:
  the client is already logging out). Generous on purpose: behind nginx every client shares one
  per-IP bucket (follow-ups item 1, HARD GATE, now also covers `oauth_revoke`), Element sends TWO
  revocations per logout, and a valid-shaped request costs one indexed SELECT. No global bucket (no
  per-request cost beyond that SELECT; DELETEs happen only for real tokens). `OPTIONS` takes no
  token (CORSPlug preflight); `:unknown` config takes none either (503 first). The bucket applies
  also while OAuth is disabled (R13).
- **R10 (no oracle; timing).** The response for a revoked token, an unknown token, a malformed token
  and a legacy token is byte-identical (200, empty, same headers). Work: the format check is
  constant; every well-formed token costs exactly one hash + one indexed SELECT; only a REAL OAuth
  token additionally causes the DELETE transaction. The timing difference therefore reveals validity
  only to someone who already holds a 256-bit token (enumeration infeasible); `client_id` is never
  looked up (R4), so client existence is not observable either. Documented, not engineered away.
- **R11 (atomicity + concurrency; cluster-safe).** `OAuthSessionStore.end_session_for_token/1`
  runs ONE transaction: (1) a PLAIN SELECT (no row lock) of `user_id, device_id, client_id` of the
  presented row (R3); 0 rows => `{:ok, :unknown}`, nothing locked; (2) `SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR
  UPDATE` (the SAME row lock `insert_replacing_device/1` (T7 issuance) and `rotate/1` (review cycle
  1, MINOR 2) take; lock order devices -> matrix_sessions everywhere); (3) re-check AFTER the lock
  that the presented token still has an `auth_api = 'oauth'` row (a T7 re-login on the same device id
  may have replaced the session between (1) and (2): then nothing is deleted, `:unknown`, the NEW
  session survives); (4) `DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2` (a new
  statement, so under READ COMMITTED its snapshot includes a rotation that committed while we waited
  for the lock: the rotated-in row is deleted too); (5) device tables deleted with the raising
  `DeviceKeyStore` variant (inside the transaction, so a concurrent re-login cannot lose its fresh
  device row to a post-commit cleanup). A rotation that waits on the lock afterwards finds no row
  (`lock_device_of/2` rolls back `:not_found`, or the guarded UPDATE matches 0 rows) => re-resolve =>
  `invalid_grant`. Residual (as story 3): a session whose `devices` row is missing locks nothing; the
  re-check and the guarded rotation UPDATE still decide. Idempotent: a second revocation (Element
  revokes access AND refresh token, possibly in parallel) finds nothing after the lock => 200.
- **R12 (IdP refresh token).** Ending the session deletes the stored IdP refresh-token ciphertext
  (spec 7 "inkl. IdP-RT"). Nebu does NOT call an IdP revocation endpoint: the IdP is only an
  identity source, Dex advertises none, and an unauthenticated endpoint must not trigger outbound
  calls (amplification). Follow-up (t), non-gating: optional IdP-side revocation when the IdP
  advertises `revocation_endpoint`.
- **R13 (NO kill switch for revoke; oracle O5 decision).** Unlike token/JWKS/openid-configuration
  (T22), `/oauth2/revoke` stays LIVE while `Config` is `:disabled` AND with an invalid / missing
  issuer: it can only DELETE sessions, Element clears its local state anyway, and otherwise the
  server sessions would survive a logout made while the operator has OAuth switched off (switching
  OAuth off does not end OAuth sessions: `OidcPlug` does not consult `oauth_enabled`). The handler
  needs no issuer. Only `:unknown` (server_config unreadable) => `503 {}` + `Retry-After: 5` before
  any parse / rate-limit token. The rate limit (R9) and every other rule apply in all live states.
  Consequence: `revoke` uses a two-state gate (`:unknown` vs everything else), not
  `Http.live_state/0`'s `:off` branch; the metadata still advertises the endpoint only while enabled.
- **R14 (CORS, = T32).** `/oauth2/revoke` joins the credentials-free CORS branch of
  `Nebu.Web.Router.cors/2` (`path_info: ["oauth2", endpoint | _] when endpoint in ["token", "jwks",
  "revoke"]`): responses (EVERY status, so a simple cross-origin POST without preflight can read
  any answer; oracle) AND preflights answer `Access-Control-Allow-Origin: *` and never
  `Access-Control-Allow-Credentials`; `OPTIONS` is answered by CORSPlug before routing (no endpoint
  logic, no DB, no rate-limit token; the `Nebu.OAuth.Http` OPTIONS clause stays the fallback). Global
  CORS of every other path unchanged.
- **R15 (`POST /logout` with an OAuth access token).** `OidcPlug.call_opaque/2` additionally assigns
  `:auth_api` (`sess.auth_api`; the JWT path assigns `"legacy"`), decided at AUTHENTICATION time.
  The logout handler: `auth_api == "oauth"` => `Nebu.Matrix.oauth_revoke_token(access_token)` (the
  SAME function as `/oauth2/revoke`): ends ONLY this device's session (R2), never calls
  `invalidate_user_sessions` (which wipes every session of the user). `{:ok, _}` (also `:unknown`,
  e.g. a concurrent revocation won) => `200 {}`; `{:error, :unavailable}` => `500
  {"errcode":"M_UNKNOWN","error":"Logout failed, please try again."}` (never a 200 while the session
  survives). An EXPIRED or superseded OAuth access token never reaches the handler: `OidcPlug`
  answers `401 M_UNKNOWN_TOKEN` + `soft_logout: true` (unchanged, Matrix soft-logout flow: the client
  refreshes and retries, or uses `/oauth2/revoke`, which accepts expired tokens). Deciding by a lookup
  at logout time would be wrong: a concurrent revocation would turn the OAuth logout into the legacy
  user-wide wipe (Trap 4).
- **R16 (legacy `POST /logout` unchanged = recorded deviation).** Verified: legacy `/logout`
  (`protected.ex` `post "/client/v3/logout"`) deletes the presented session's device rows
  (`MatrixSessionStore.revoke/1` / JWT denylist) and then calls
  `invalidate_user_sessions(%{device_id: ""})` => `destroy_session/1` + `MatrixSessionStore.delete_for_user/1`:
  EVERY session of the user ends (also the user's OAuth sessions on other devices, whose devices then
  remain), and no device is deleted. Matrix `/logout` invalidates only the presented token and
  deletes its device. This is a pre-existing spec deviation; changing legacy semantics is story 5
  (legacy coexistence). New gate item (r) before `oauth_enabled` (a legacy logout in one client must
  not end the user's OAuth sessions in another; and per-device legacy logout).
- **R17 (`POST /logout/all` routed now, both APIs).** Not routed today (falls into `protected.ex`
  `match _` => `404 M_NOT_FOUND`), a pre-existing gap recorded by story 3. Spec 7 says it remains and
  calls the same function, so it is routed in this story: `post "/client/v3/logout/all"` =>
  (1) `Nebu.Matrix.oauth_end_user_sessions(user_id)` (every device with an `auth_api = 'oauth'` row:
  `end_device_session/2`, R2 incl. device deletion), then (2) the legacy part = exactly today's
  legacy `/logout` body (`revoke_access_token/1` for the presented credential, i.e. JWT denylist /
  opaque row delete, then `invalidate_user_sessions(%{device_id: ""})`), then (3) ORACLE CORRECTION
  (binding): EVERY remaining device of the user is deleted with its keys (Matrix `/logout/all`:
  "invalidates every token of the user, including the caller's, and deletes ALL devices and their
  keys", no UIA), i.e. for every `devices` row of the user (legacy devices too): JWT kill-switch of
  the device + `DeviceKeyStore.delete_device/2` (new facade helper inside `oauth_end_user_sessions`'s
  sibling `Nebu.Matrix.end_all_user_devices/1`, or one Matrix-internal function the handler calls;
  user-scoped, idempotent). Cross-signing keys (per user) are NOT deleted. Same for OAuth and legacy
  callers. `200 {}`; when (1) or (3) fails => `500 M_UNKNOWN` (the other parts still run, so tokens
  are dead anyway; the client may retry). A concurrent NEW login during `/logout/all` may survive
  (point-in-time semantics, accepted). The body may be empty / absent or `{}` (JsonBody must not 400).
- **R18 (`DELETE /devices/{id}`, `POST /delete_devices`: unchanged here).** Verified (story 3 AC17):
  deleting a device through any path (`protected.ex` `delete_one_device/3`, admin
  `Nebu.Matrix.delete_user_device/2`) already deletes ALL `matrix_sessions` rows of the device
  (`MatrixSessionStore.delete_for_user_device/2`, no `auth_api` filter) plus the device and its keys,
  i.e. ends an OAuth session completely (IdP RT included). The spec-8 decision "rejected for OAuth
  sessions, device deletion via the account page" needs the UIA delineation for OAuth tokens (story 5,
  spec 13 row 5) and the account page (story 6); implementing the rejection now would duplicate that
  contract. Story-3 follow-up (d) already tracks it; this story only extends its text (the UIA
  `preserve` branch can keep an OAuth caller's own rows on a deleted device) and adds no new item.
  Story-3 tests that delete an OAuth device via `DELETE /devices` stay green unchanged.
- **R19 (deactivation and GDPR erasure).** Admin deactivation (`EventDispatcher.Server.deactivate_user/2`)
  already calls `MatrixSessionStore.delete_for_user/1` after the commit: all OAuth tokens die
  immediately (story-3 regression test); unchanged (devices stay, the user cannot log in again). GDPR
  key erasure (`EventDispatcher.Server.delete_user_keys/2` -> `Nebu.Compliance.UserDeletion.delete_user_keys/3`)
  ends NO session today: after a successful erasure it now calls, best effort and after the commit
  (the `deactivate_user` sequencing idiom), `Nebu.Matrix.oauth_end_user_sessions/1`, then
  `MatrixSessionStore.delete_for_user/1` and `session_supervisor_module().destroy_session/1` (also
  ends legacy sessions: an erased user with working tokens is the same class of bug). Never changes
  the `DeleteUserKeysResponse`, never raises (warnings only).
- **R20 (after revocation: resource server and token endpoint).** No code change, only tests: the
  rows are gone, so `OidcPlug.call_opaque/2` answers `401 {"errcode":"M_UNKNOWN_TOKEN"}` WITHOUT
  `soft_logout` for the access token (spec 6: missing or `false` both mean "session destroyed";
  ABSENT is a consistency choice with every other Nebu destroyed-session answer, oracle gate), and
  `/oauth2/token` with the refresh token resolves `:error` => `400 invalid_grant` with no side effect
  (the T11 reuse path cannot fire: the consumed siblings are gone too).
- **R21 (no audit rows; logging).** Consistent with T29 / D20 and legacy logout: no `audit_log`
  rows. INFO: `"OAuth revoke: outcome=revoked|ignored client_id_match=true|false|absent"` and, on
  `revoked`, `user_id`, `device_id`, the session's STORED `client_id` (trusted value).
  `client_id_match` is `true` when the presented `client_id` equals the stored one, `absent` when no
  `client_id` was sent, else `false` (also for every `outcome=ignored`). The PRESENTED
  `client_id` is attacker-controlled (up to 16 KiB) and is never logged, only compared. WARNING: a
  failed revocation (storage), exception type only. Never a token, a hint value, a hash, an IdP token.
- **R22 (redaction).** `token` is already in `PayloadRedactor`'s `@credential_keys` and
  `@credential_string_keys` (nothing to add; `token_type_hint` is not a secret, and the body is never
  captured: R8). `RequestLogger`: `/oauth2/revoke` joins `@names_only_query_paths` (the existing
  `normalized_path/1` covers trailing / doubled slashes); its response bodies carry no secret (no
  `@no_response_body_paths` entry needed).
- **R23 (metadata truthfulness, stale "revoke is 404").** `auth_metadata` /
  `/.well-known/openid-configuration` already advertise `revocation_endpoint` and
  `revocation_endpoint_auth_methods_supported: ["none"]`: both are now true, `Metadata` is unchanged.
  Every test and doc that pins "/oauth2/revoke is 404 / not implemented / unrouted" changes in the
  same commit (list in Trap 7). With `/oauth2/revoke` live every advertised endpoint exists, but
  `oauth_enabled` still stays false (gate items 1, h, i, l, m, n, r; stories 5, 6, 9).
- **R24 (facade contract).** `Nebu.Matrix.oauth_revoke_token(token) :: {:ok, :revoked, %{user_id:,
  device_id:, client_id:}} | {:ok, :unknown} | {:error, :unavailable}` and
  `Nebu.Matrix.oauth_end_user_sessions(user_id) :: {:ok, [device_id]} | {:error, :unavailable}`, both
  with `@doc` + `@spec`, never raising (rescue => `{:error, :unavailable}`), format check repeated
  inside `oauth_revoke_token/1` (defence in depth: a non-64-hex value is `{:ok, :unknown}` without DB
  access).

## Acceptance Criteria

### AC1 — Endpoint, routing, enablement, methods, headers (R13, R14)

- `Nebu.Web.Router`: `forward "/oauth2/revoke", to: Nebu.OAuth.Http, init_opts: [action: :revoke]`
  next to `/oauth2/token`; the comments "/oauth2/revoke stays unrouted" (router ~line 98) are
  updated. `cors/2`: the credentials-free branch matches `endpoint in ["token", "jwks", "revoke"]`.
- `Nebu.OAuth.Http`: `call(conn, :revoke)` => `Config.get/0` state (R13, two-state): `:unknown` =>
  `503 {}` + `Retry-After: 5`; ANY other state (`:enabled` with a valid or INVALID issuer,
  `:disabled`) => `POST` => `Nebu.OAuth.Revoke.handle_revoke(conn)`, other methods (incl. `HEAD`)
  => `405 {"error":"invalid_request","error_description":"Method not allowed."}` + `Allow: POST,
  OPTIONS`. Sub-paths (`/oauth2/revoke/x`) => `unrecognized_no_error/1` (add `:revoke` to the
  `path_info: [_ | _]` guard list); the shared `unrecognized_no_error/1` helper gains `Pragma:
  no-cache` (harmless for the story-3 endpoints), so the sub-path 404 carries the AC1 headers too. A trailing slash (`/oauth2/revoke/`) is the endpoint itself
  (empty `path_info`).
  Moduledoc lists the endpoint (removes "not routed yet").
- `OPTIONS /oauth2/revoke` (preflight with `Origin` + `Access-Control-Request-Method: POST`): CORSPlug
  answers `204` with `Access-Control-Allow-Origin: *`, `Access-Control-Allow-Headers` incl.
  `Content-Type` and `Authorization`, NO `Access-Control-Allow-Credentials`; no endpoint logic, no
  DB access, no rate-limit token (also while OAuth is disabled).
- EVERY `/oauth2/revoke` response (200 and every error, incl. 404/405/413/429/5xx), also to a simple
  cross-origin POST without preflight: `Content-Type: application/json`, `Cache-Control: no-store`,
  `Pragma: no-cache`, `Access-Control-Allow-Origin: *`, never `Access-Control-Allow-Credentials`, no
  `Set-Cookie`, no `WWW-Authenticate`. EVERY 5xx: `Retry-After` and the body exactly `{}`.
- `Nebu.Web.Plugs.JsonBody` skips `path_info: ["oauth2", "revoke" | _]` (body untouched, read once
  by the handler; moduledoc).

### AC2 — Request parsing (R8)

`Nebu.OAuth.Revoke.handle_revoke/1` (wrapped in the same rescue/catch as `Token.handle_token/2`:
exception => `500 {}` + `Retry-After: 5`, exception TYPE logged only). Order, first failure wins
(status in brackets, body RFC 6749 5.2):

1. Non-empty `conn.query_string` => `invalid_request` [400].
2. `Content-Type` not `application/x-www-form-urlencoded` (case-insensitive, parameters allowed;
   `TokenRequest.valid_content_type?/1`) => `invalid_request` [400] (JSON, multipart, missing).
3. Body > 16 384 bytes => `invalid_request` "The request body is too large." [413]; read error =>
   `invalid_request` [400].
4. `AuthorizeRequest.parse_query/1` `{:error, :malformed}` => `invalid_request` [400].
5. `TokenRequest.validate_params/1` `{:error, :invalid_request}` (duplicate name, also `token=a&token=`;
   control character; invalid UTF-8) => `invalid_request` [400].
6. Rate limit (AC3). Steps 1-5 failures are charged BEFORE their 4xx (exhausted => 429 instead).
7. `token` absent (or empty, which step 5 dropped) => `invalid_request` "The token parameter is
   required." [400].
8. `token` (form-decoded, not trimmed) not 64 lowercase hex => `200 {}` (R5), no DB access.
9. `Nebu.Matrix.oauth_revoke_token(token)` (AC4/AC5): `{:ok, :revoked, info}` / `{:ok, :unknown}` =>
   `200 {}`; `{:error, :unavailable}` => `503 {}` + `Retry-After: 5`.

`client_id`, `client_secret`, `token_type_hint`, `Authorization` and every other parameter/header
never change the outcome (R3, R4). Steps 1-5 are the SAME code as the token endpoint
(`Nebu.OAuth.FormPost.parse/1`, R1).

### AC3 — Rate limiting (R9)

- `RateLimit.take({"oauth_revoke", ip}, 60, 600)` (ip = `:inet.ntoa/1` string), charged once per
  request after the config read and after parsing, before AC2 step 7, in every live state (also
  `:disabled` / invalid issuer). Exhausted => `429
  {"error":"too_many_requests"}` + `Retry-After` (seconds from `RateLimit.take/3`) + AC1 headers.
- The key never collides with `oauth_token*`, `oauth_jwks`, `oauth_register*`, `oauth_authorize`,
  `oauth_callback` or the plug's IP-string keys; `:unknown` config and `OPTIONS` take no token; seams
  `:rate_limit_clock_fn`, `NEBU_RATE_LIMIT_DISABLED` apply.

### AC4 — Revocation semantics (R2-R5, R10)

- A hit = an `auth_api = 'oauth'` row whose `access_token_hash` OR `refresh_token_hash` equals
  `hash_token(token)`, regardless of `revoked_at`, `grace_until`, `expires_at`,
  `session_expires_at`. Covered token kinds: active access token, active refresh token, EXPIRED
  access token, superseded access token, PENDING refresh token, CONSUMED refresh token, token of an
  expired session.
- A hit ends the session per R2: afterwards `matrix_sessions` has NO row for `(user_id, device_id)`
  (any `auth_api`), the `devices` row and its `device_keys` / `device_one_time_keys` /
  `device_fallback_keys` are gone, `GET /devices` of the user no longer lists it, JWT bindings of the
  device are denylisted + deleted; another user's `POST /keys/query` no longer returns the device's
  keys, the user's cross-signing keys are untouched.
- `token_type_hint` absent, `access_token`, `refresh_token`, mismatching the real type, or an unknown
  value => identical result. `client_id` absent, the session's client, ANOTHER approved client, an
  unknown string => identical result (revoked).
- No hit (unknown, already revoked, legacy opaque access or refresh token, a JWT, an authorization
  code value, an access token of a purged session) => `200`, NO row of any table changed (row
  snapshot test, incl. the legacy session, which keeps working: `/whoami` 200, legacy `/refresh` works).
- Response bytes and headers of "revoked" and "unknown" are identical (R10).

### AC5 — Matrix side: the one revocation function (R1, R11, R24)

- `Nebu.Matrix.oauth_revoke_token/1` -> `Nebu.Matrix.OAuthSession.revoke_token/1` ->
  `Nebu.Matrix.Session.OAuthSessionStore.end_session_for_token/1` (plaintext token in, hashed
  inside; transaction per R11 steps 1-5) -> after the commit `OAuthSession` runs the best-effort part
  of R2 (JWT kill-switch via the existing private `kill_bound_jwts/2`, `SessionSupervisor.destroy_session/2`)
  and logs per R21. Returns per R24. Never raises.
- `Nebu.Matrix.OAuthSession.end_device_session(user_id, device_id)` = the same transaction without
  the token re-check (lock, delete all rows of the device, device tables) + the same post-commit part;
  used by `end_all_for_user/1`.
- `Nebu.Matrix.oauth_end_user_sessions(user_id)` -> `OAuthSession.end_all_for_user/1`: `SELECT
  DISTINCT device_id FROM matrix_sessions WHERE user_id = $1 AND auth_api = 'oauth'`, then
  `end_device_session/2` per device; `{:ok, device_ids}` or `{:error, :unavailable}` (first failure;
  the remaining devices are still attempted).
- Device tables inside the transaction: `Nebu.Matrix.DeviceKeyStore` gets a raising variant (e.g.
  `delete_device!/2`) that shares ONE `@device_tables` list with the existing best-effort
  `delete_device/2` (order `device_one_time_keys`, `device_fallback_keys`, `device_keys`, `devices`);
  `delete_device/2`'s behaviour is unchanged.
- Repo: `OAuthSessionStore`'s compile-time guarded `repo/0` seam (`:oauth_session_repo`); a
  NoSuchRepo => `{:error, :unavailable}` => 503 at the endpoint, 500 at `/logout`.
- Concurrency (tests, AC-level invariants): (a) revoke vs an in-flight rotation of the same session:
  after both finished there is NO row for the device and no token returned by either request
  authenticates; (b) two concurrent revokes (access + refresh token of one session): both `200`, the
  session ended once, no error log; (c) revoke of an OLD token vs a concurrent T7 re-login with the
  same device id: when the re-login committed first, its NEW session and device survive.

### AC6 — Response and error mapping (R6, R7)

| Condition | Status | Body | Effect |
|---|---|---|---|
| OAuth disabled / invalid issuer | as live (every row below applies) | - | - |
| config unreadable (`:unknown`) | 503 + `Retry-After: 5` | `{}` | none |
| sub-path `/oauth2/revoke/x` | 404 | `{"errcode":"M_UNRECOGNIZED"}` (no `error`) | none |
| non-POST (incl. `HEAD`) | 405 + `Allow: POST, OPTIONS` | `invalid_request` | none |
| query string, wrong content type, malformed / duplicated / control-char parameter, `token` missing or empty | 400 | `invalid_request` | none |
| body > 16 KiB | 413 | `invalid_request` | none |
| rate limit | 429 + `Retry-After` | `{"error":"too_many_requests"}` | none |
| valid OAuth token (any state), any/no `client_id`, any/no hint, ignored `client_secret` / `Authorization` | 200 | `{}` | session + device ended |
| unknown / malformed / legacy / JWT / already revoked token, token with surrounding spaces | 200 | `{}` | none |
| DB unavailable (lookup or delete) | 503 + `Retry-After: 5` | `{}` | none (transaction rolled back) |
| unexpected exception | 500 + `Retry-After: 5` | `{}` | rolled back / unchanged |
| `401 invalid_client`, `400 unsupported_token_type` | never | - | - |

No body contains `errcode` except the sub-path 404; no body contains `error_uri`. Every row:
`Content-Type: application/json`, ACAO `*`.

### AC7 — After revocation (R20)

- The revoked access token (whatever token was presented) => every protected Matrix route answers
  `401 {"errcode":"M_UNKNOWN_TOKEN", ...}` WITHOUT a `soft_logout` key (spec: absent and `false`
  are equivalent; Nebu asserts ABSENT as a consistency choice with every other destroyed-session
  answer, R20).
- The revoked session's refresh token (active, pending or consumed) at `/oauth2/token` => `400
  invalid_grant`, no row of any session changed (no reuse revocation fires, no other device touched).
- Other devices of the same user (OAuth and legacy) are untouched and keep working.

### AC8 — `POST /_matrix/client/v3/logout` with an OAuth access token (R15)

- `OidcPlug.call_opaque/2` assigns `:auth_api` (`"legacy"` | `"oauth"` from the row); `call_jwt/2`
  assigns `"legacy"`. No other `OidcPlug` behaviour changes.
- `auth_api == "oauth"`: `Nebu.Matrix.oauth_revoke_token(conn.assigns[:access_token])`; `{:ok, _}` =>
  `200 {}`; `{:error, :unavailable}` => `500 {"errcode":"M_UNKNOWN","error":"Logout failed, please
  try again."}`. `invalidate_user_sessions` and `revoke_access_token/1` are NOT called on this branch.
- Effects: this device's session + device ended (AC4); the user's OTHER devices (OAuth and legacy)
  are untouched; afterwards the access token => 401 without `soft_logout`, the refresh token =>
  `invalid_grant`.
- An expired / superseded OAuth access token => `401 M_UNKNOWN_TOKEN` + `soft_logout: true` from
  `OidcPlug` (unchanged; the handler is not reached, nothing deleted).
- Legacy callers (opaque legacy, raw JWT): byte-identical behaviour to today (R16), regression
  tests stay green.
- Works while OAuth is disabled (no `Config` read on this path).
- Request body (this AND AC9, every caller kind: OAuth, legacy opaque, raw JWT): none, empty (with or
  without `Content-Type: application/json`), or `{}` => `200 {}` with `Content-Type:
  application/json` (JsonBody must not answer 400 `M_NOT_JSON` for these); an invalid NON-empty JSON
  body is IGNORED like today's legacy `/logout` does (measured: `200`; R16 keeps legacy
  byte-identical, Matrix logout takes no body), i.e. it is answered exactly like an empty body.

### AC9 — `POST /_matrix/client/v3/logout/all` (R17)

- New route `post "/client/v3/logout/all"` in `Nebu.Web.Router.Protected` (before `match _`; the
  existing `post "/client/v3/logout"` keeps matching only the exact path).
- Handler: `Nebu.Matrix.oauth_end_user_sessions(user)`, then the legacy part (the CURRENT
  `/logout` body: `revoke_access_token(conn)` + `invalidate_user_sessions(%{user_id: user,
  device_id: ""})` via `call_core/1`), for every caller kind. `200 {}`; OAuth part failed => `500
  M_UNKNOWN` while the legacy part and the all-device deletion below still run.
- Then (R17 oracle correction) EVERY remaining `devices` row of the user (legacy devices too) is
  deleted with its keys (JWT kill-switch per device + device-table deletion with an error-aware
  result, e.g. `DeviceKeyStore.delete_device!/2` rescued per device); cross-signing keys are kept. A
  failed device deletion (step 3) => `500 M_UNKNOWN` (never a silent 200).
- Effects: every `matrix_sessions` row of the user is gone, EVERY device of the user (with its keys)
  is gone, the presented credential is dead (opaque: row deleted; JWT: denylisted), the RT of every
  other OAuth device of the user is `invalid_grant`, another user is untouched. Repeating
  `/logout/all` with the now dead token => `401 M_UNKNOWN_TOKEN` without `soft_logout`.
- Request body: as AC8 (none / empty with or without JSON content type / `{}` => `200 {}`
  `application/json`; an invalid non-empty JSON body is ignored); unauthenticated => `401
  M_MISSING_TOKEN`; works while OAuth is disabled.
- `docs/matrix-api-scope.md` gets the row.

### AC10 — Device deletion, deactivation, GDPR erasure (R18, R19)

- `DELETE /devices/{id}` / `POST /delete_devices`: no code change; regression tests: an OAuth
  device deleted by a legacy session of the same user => its OAuth rows gone, its RT `invalid_grant`,
  its AT 401 without `soft_logout` (the story-3 self-delete tests stay unchanged).
- Admin deactivation: no code change; regression test extended: `deactivate_user/2` => every OAuth
  row of the user gone, AT 401, RT `invalid_grant`.
- GDPR erasure: `Nebu.Matrix.EventDispatcher.Server.delete_user_keys/2` after `{:ok, _}` calls
  `Nebu.Matrix.oauth_end_user_sessions/1`, `MatrixSessionStore.delete_for_user/1`,
  `session_supervisor_module().destroy_session/1` (each best effort, WARNING without secrets on
  failure), then returns the unchanged `DeleteUserKeysResponse`. Error/conflict branches end nothing.
  Test: erasure of a user with an OAuth session and a legacy session => both dead; existing
  `user_deletion_test.exs` / `admin_ops_test.exs` stay green (injected modules, no Repo => no raise).

### AC11 — Metadata truthfulness and stale 404 assertions (R23)

- `Nebu.OAuth.Metadata.build/1` unchanged; a test asserts `revocation_endpoint == issuer <>
  "/oauth2/revoke"` is routed (POST with an unknown well-formed token => 200, also while disabled) and
  `revocation_endpoint_auth_methods_supported == ["none"]`.
- The story-2/3 assertions "revoke is the router's plain 404 / unrouted / not implemented" are
  replaced in the same commit (Trap 7): routed and LIVE also while disabled (R13), only `:unknown`
  => 503 `{}`.

### AC12 — Logging and redaction (R21, R22, No Sensitive Data law)

- `RequestLogger`: `/oauth2/revoke` in `@names_only_query_paths` (also `/oauth2/revoke/`,
  `//oauth2//revoke`); the request body of `/oauth2/revoke` is never captured (`body_params`
  `Unfetched`) — tests at `:debug` with log capture.
- Log-capture tests over every AC6 row and AC8/AC9: no token value (access, refresh, presented
  junk), no token hash, no `token_type_hint` VALUE from the body, no presented `client_id` value, no
  IdP refresh token / ciphertext, no Authorization header value appears; the INFO line has
  `outcome=` and `client_id_match=`.
- `PayloadRedactor`: no change; a unit test confirms `token=...&token_type_hint=...&client_id=...`
  strings and a `%{"token" => ...}` map are masked for `token`.

### AC13 — Documentation

- ADR-033: new section "Token revocation and logout (story 4)" with R1-R24, incl. R4 worded as
  "conforms to the Matrix spec (SHOULD still revoke)" (NOT a deviation), the one deliberate deviation
  R16 (legacy user-wide `/logout` + kept legacy devices), the R2 contrast with T8/T11, R13 (revoke
  is exempt from the T22 kill switch, only `:unknown` => 503), the unreachable 401/400 (R7) and the
  response-shape rationale (R6, `200 {}`); the story-2 / story-3 texts "`/oauth2/revoke` stays unrouted" get
  "(until story 4)" or are updated; T2's "Logout ... work unchanged" sentence gets a story-4 pointer;
  the gate paragraph: "Story 4 update: `/oauth2/revoke` is live; every advertised endpoint exists;
  `oauth_enabled` stays false because of gate items 1, h, i, l, m, n, r and stories 5, 6, 9"; the
  T22 text gets "(`/oauth2/revoke` is exempt, story 4 R13)".
- `docs/matrix-api-scope.md`: `/oauth2/revoke` row ✅ (RFC 7009, no client auth, either token in
  any state, whole session + device, `200 {}` for unknown tokens, rate limit, live also while OAuth is disabled, `503 {}` only for an unreadable config);
  `/logout` row (OAuth: current device only, legacy unchanged user-wide); new `/logout/all` row ✅.
- `docs/stories/oauth-broker/follow-ups.md`: section "From story oauth-token-revocation-logout":
  (a) item 1 also covers `{"oauth_revoke", ip}`; (b) I-1 / story-3 (e) update: revoke live;
  (c) story-3 (d) extended (R18: rejection of `DELETE /devices` / `/delete_devices` for OAuth
  callers and the UIA `preserve` branch, stories 5/6); gate table rows **(r)** legacy `/logout`
  user-wide wipe ends OAuth sessions on other devices + legacy logout keeps devices (R16; before
  `oauth_enabled`, story 5), **(s)** (oracle, non-gating, epic-end review) deleting a device
  (revoke, OAuth `/logout`, `/logout/all`, `DELETE /devices`, admin) should put the user into
  `device_lists.changed` of the peers' next `/sync`; Nebu does it only for cross-signing changes
  (`protected.ex` ~222-231 `put_cross_signing_device_lists/3`), and **(t)** optional IdP-side
  revocation of the IdP refresh token (R12; non-gating, epic-end review). Letters a-q are used by
  stories 1-3.
- `Nebu.OAuth` moduledoc (facade functions incl. `oauth_revoke_token/1`), `Nebu.OAuth.Http`,
  `Nebu.Matrix` (`@doc` of both new functions), router comments.
- arc42 (by the arc42 step; Dev Notes list the hooks).

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- Integration `server/test/nebu/oauth/oauth_revoke_http_test.exs`: AC1-AC3, AC6 (revoke LIVE while
  disabled and with an invalid issuer, 503 via `T.unreadable_oauth_config/0`, 405 + Allow, sub-path 404, trailing slash, OPTIONS preflight
  without DB / rate-limit token / ACAC, headers on EVERY row of the AC6 table, query string, content
  types (JSON, multipart, missing, `; charset=UTF-8` accepted), body cap 413, duplicates incl. one
  empty, control char, missing / empty `token`, malformed token => 200 without DB access (NoSuchRepo
  seam proves it), DB unavailable => 503 `{}`, rescued 500 `{}` (via a new compile-time guarded
  `:oauth_revoke_test_hook`, same contract as `:oauth_token_test_hook`), rate limit 429, `client_secret`
  / Basic / Bearer ignored, `401`/`unsupported_token_type` never).
- Integration `server/test/nebu/oauth/oauth_revoke_semantics_test.exs`: AC4, AC5, AC7 through the real
  story-2/3 flow (`T.flow_code!/4`, `T.redeem!/3`, `T.session!/4`, `T.refresh!/4`, `T.sql!/2`): every
  token kind of AC4, hint/client_id matrix, legacy and unknown tokens with row snapshots, device +
  keys deleted (seed `device_keys` / OTK / fallback rows for the device), JWT binding of the device
  denylisted (insert a binding directly, story-3 T25 helper), the three concurrency invariants
  (AC5 a-c: (a) deterministic with a privileged transaction holding the `devices` row lock while a
  rotation row is inserted and committed, the revoke Task blocked on the lock, then asserting zero
  rows; plus an N-task stress run of refreshes + one revoke asserting no live row and every returned
  access token 401 afterwards; (b) parallel AT + RT revokes; (c) re-login with the same device id
  committed between the revoke's lookup and lock: use `:oauth_revoke_test_hook` or a privileged lock
  to order it deterministically), other devices untouched.
- Integration `server/test/nebu/oauth/oauth_logout_test.exs`: AC8-AC10 (OAuth `/logout` ends only
  the current device; another OAuth device and a legacy device of the same user survive; expired /
  superseded AT => 401 soft_logout and nothing deleted; DB failure => 500 `M_UNKNOWN` and the
  session survives (`T.block_session_deletes!/1` or the repo seam); legacy `/logout` regression
  (user-wide, unchanged); `/logout/all` for an OAuth caller, a legacy opaque caller and a raw-JWT
  caller; another user untouched; `/logout` while OAuth is disabled; device deletion by a legacy
  session of an OAuth device; deactivation; GDPR erasure).
- Integration `server/test/nebu/oauth/oauth_revoke_logging_test.exs`: AC12.
- Unit/static `server/test/nebu/oauth/oauth_revoke_static_test.exs`: router forward + CORS branch,
  JsonBody skip, `lib/nebu/oauth/revoke.ex` and `form_post.ex` name no Matrix-internal module, the
  facade exports `oauth_revoke_token/1` and `oauth_end_user_sessions/1` with docs, `Token` delegates
  to `FormPost` (no second parser copy), the test hook is compile-time guarded.
- Extended: `server/test/nebu/matrix/session/oauth_session_store_test.exs` (store functions:
  `end_session_for_token/1` per token kind, re-check after lock, `oauth_devices` enumeration),
  `oauth_token_e2e_test.exs` (new test: login -> whoami -> expire the AT via SQL -> revoke with the
  EXPIRED AT + Dart-like params (`token`, `token_type_hint=access_token`, `client_id`) -> 200 ->
  whoami 401 without soft_logout -> refresh `invalid_grant` -> `GET /devices` (other session) no
  longer lists the device), `oauth_metadata_test.exs` (AC11), `oauth_payload_redaction_test.exs` /
  `oauth_request_logger_redaction_test.exs` (AC12), `adr_033_test.exs` (AC13 section + gate text),
  the stale-404 tests of Trap 7, `server/test/nebu/compliance/user_deletion_test.exs` /
  `event_dispatcher/admin_ops_test.exs` only if they pin the erasure call sequence.

### matrix_compat node test (optional, like story 3 C6)

If runnable WITHOUT modifying the main checkout: extend the story-3 fixture
(`oauth_signing_keys_test.exs` with `NEBU_OAUTH_FIXTURE_OUT`) with Nebu's REAL revoke answers (200
empty, 503 `{}`, 400 `invalid_request`) and add to `tests/matrix_compat/oauth_metadata_test.js` an
`OidcClient.revokeToken(token, "access_token")` replay: 200 resolves, 503 rejects with a plain
`Error`, 400 rejects with an `ErrorResponse`. Otherwise record "not executed" in the Dev Agent Record
(the ExUnit tests cover the shapes).

### Gherkin

None: no UI (`ui: false`).

## Must be test-covered (RFC 7009, Matrix CS API, spec 6/7/8/10)

1. No kill switch (R13): with OAuth disabled AND with an invalid issuer a valid OAuth token is
   revoked (200 `{}`), an unknown one is 200 `{}`, the rate limit applies; `:unknown` => `503 {}` +
   `Retry-After: 5`, no rate-limit token, no lookup.
2. `OPTIONS /oauth2/revoke` preflight: 204 by CORSPlug, ACAO `*`, Allow-Headers incl. `Content-Type`
   and `Authorization`, NO ACAC, no DB access, no rate-limit token (also while disabled).
3. Every response (200 and every error, also to a simple cross-origin POST with `Origin` and no
   preflight) has `Content-Type: application/json`, `Cache-Control: no-store`, `Pragma: no-cache`,
   ACAO `*`, never ACAC, no `Set-Cookie`, no `WWW-Authenticate`; no body carries `errcode` (except
   the sub-path 404) or `error_uri`.
4. EVERY 5xx (`:unknown` config, DB unavailable on lookup, DB unavailable on delete, rescued
   exception) is exactly `{}` + `Retry-After`, and a 5xx leaves the session fully intact (AT works,
   RT refreshes).
5. 200 for success is `{}` with `Content-Type: application/json`, byte-identical (body and
   headers) to the 200 for an unknown token (RFC 7009 2.2, R6, R10).
6. Unknown well-formed token => 200, no row changed (snapshot of `matrix_sessions`, `devices`,
   key tables).
7. Malformed token (not 64 lowercase hex, uppercase hex, 63/65 chars, a JWT) => 200 WITHOUT DB
   access (NoSuchRepo seam would otherwise answer 503).
8. LEGACY opaque access token and LEGACY refresh token => 200, legacy session untouched and still
   working (`/whoami` 200, legacy `/refresh` 200).
9. Active OAuth access token => session + device ended; token 401 without `soft_logout`; RT
   `invalid_grant`.
10. Active OAuth refresh token => same as 9 (MUST revoke access AND refresh token).
11. EXPIRED access token (`expires_at` moved into the past via SQL) => revoked (spec 7, Dart SDK).
12. Superseded access token and PENDING refresh token after a rotation => the whole session (incl. the
    NEW active row) ended.
13. CONSUMED refresh token (after the new AT was used) => the whole session ended (no T11 path, no
    WARNING "reuse").
14. Token of an expired session (`session_expires_at` in the past) => rows + device deleted, 200.
15. `client_id` absent, the right one, another approved client, an unknown string => revoked in every
    case (spec 7 / R4); the presented `client_id` value never appears in logs.
16. `token_type_hint` absent / `access_token` / `refresh_token` / wrong for the presented token /
    `id_token` / junk => identical result; never `unsupported_token_type`.
17. `client_secret=x` and `Authorization: Basic ...` / `Bearer ...` are ignored: still 200 + revoked;
    `401 invalid_client` is never produced by any request of the suite.
18. Request format: query string 400; JSON body 400; multipart 400; missing content type 400;
    `; charset=UTF-8` and upper-case `Application/X-WWW-Form-Urlencoded` accepted; malformed
    percent-encoding 400; duplicate `token` (also one empty) 400; control char 400; `token` missing
    400; `token=` (empty) 400; body 16 385 bytes 413; GET/PUT/HEAD 405 + `Allow: POST, OPTIONS`;
    sub-path 404; trailing slash works; a percent-encoded hex token is decoded and revoked; a token
    with surrounding spaces => 200 no-op.
19. Rate limit: drained `{"oauth_revoke", ip}` => 429 `too_many_requests` + `Retry-After`; charged
    before any DB access (NoSuchRepo seam + drained bucket => 429, not 503); junk requests are charged.
20. Idempotence: revoking the same token twice => 200 twice; revoking AT and RT of one session (in
    sequence and in parallel) => 200 for both, one teardown.
21. Concurrency revoke vs rotate (AC5 a): no surviving row, no token returned by the rotation works
    afterwards; the losing rotation answers `invalid_grant` (or `503`), never 500.
22. Concurrency revoke vs re-login on the same device id (AC5 c): the newer session survives when it
    committed first; an older token never deletes a newer session.
23. Device teardown: `devices`, `device_keys`, `device_one_time_keys`, `device_fallback_keys` rows of
    the device gone; other devices' keys untouched; JWT bound to the device => 401 "revoked";
    another user's `POST /keys/query` no longer returns the device's keys; the user's cross-signing
    keys are untouched; revoke after `DELETE /devices/{id}` of that device => 200 no-op.
24. After revocation: AT => `401 M_UNKNOWN_TOKEN` with NO `soft_logout` key (consistency choice,
    R20); RT => `400 invalid_grant` with no side effect on anything (spec 6).
25. Revocation never touches another device of the same user or another user (row snapshots).
26. `POST /logout` with an OAuth AT ends only the current device (session + device); other OAuth
    and legacy devices of the user keep working; response `200 {}` `application/json`, also with no
    body / no `Content-Type` and with `{}` (never 400 `M_NOT_JSON`).
27. `POST /logout` with an EXPIRED / superseded OAuth AT => `401 M_UNKNOWN_TOKEN` + `soft_logout:
    true`, nothing deleted.
28. `POST /logout` OAuth branch DB failure => `500 M_UNKNOWN`, session intact.
29. Legacy `POST /logout` unchanged (user-wide, devices kept) — existing regression suites green.
30. `POST /logout/all` (OAuth caller, legacy opaque caller, raw-JWT caller; no body / no
    `Content-Type` and `{}` => `200 {}` `application/json`): every session of the user ended (rows
    gone, presented JWT denylisted), ALL devices of the user (legacy too) and their keys deleted,
    cross-signing keys kept, other OAuth devices' RT `invalid_grant`; repeating it with the dead
    token => `401 M_UNKNOWN_TOKEN` without `soft_logout`; another user untouched.
31. Admin deactivation and GDPR erasure end the user's OAuth sessions (AT 401, RT `invalid_grant`);
    erasure also ends legacy sessions; erasure response unchanged; erasure error branches end nothing.
32. `DELETE /devices/{id}` of an OAuth device by a legacy session of the same user ends the OAuth
    session completely.
33. Metadata: `revocation_endpoint` routed (200 for an unknown token while live) and
    `revocation_endpoint_auth_methods_supported == ["none"]`; no test or doc still claims revoke is
    404 / not implemented.
34. Logging: no token, hash, hint value, presented `client_id`, IdP token or Authorization value in
    any log line (all AC6 rows, AC8, AC9); query string names-only incl. trailing-slash variants;
    request body never captured.
35. Cluster safety: no node-local state decides a revocation (static: no ETS/process state in
    `Revoke`/`OAuthSession.revoke_token/1` apart from the existing rate-limit and denylist ETS).
36. `Nebu.OAuth.Token` behaviour unchanged after the `FormPost` extraction: the whole story-3 token
    suite stays green (its T22 kill switch still answers 404 while disabled; only revoke is exempt).

## Dev Notes

### Files to create

- `server/lib/nebu/oauth/revoke.ex` — `handle_revoke(conn) :: Plug.Conn.t()` (AC2 order, AC3
  charge, R21 logging, rescue/catch => 500 `{}`), `no_content/1` (200 empty with the AC1 headers);
  calls only `Nebu.OAuth.FormPost`, `Nebu.OAuth.TokenRequest`, `Nebu.Web.Plugs.RateLimit`,
  `Nebu.Matrix.oauth_revoke_token/1`. Test hook `:oauth_revoke_test_hook` compile-time guarded
  (`if Mix.env() == :test`), called first inside the rescue.
- `server/lib/nebu/oauth/form_post.ex` — EXTRACTED from `token.ex` (move, do not copy):
  `parse(conn) :: {:ok, conn, params} | {:error, conn, status, description}` (today's
  `parse/1` + `check_query/1` + `check_content_type/1` + `read_form/1` (`@max_body 16_384`) +
  `parse_pairs/2` + `validate/2`), `json(conn, status, body)` (ACAO `*`, delete ACAC, `no-store`,
  `Pragma`, JSON), `oauth_error(conn, status, code, description | nil)`,
  `server_error(conn, status, retry_after_s)` (`{}`), `ip_string(conn)`. `Token` calls these; its
  public functions and messages stay byte-identical.
- Tests listed under Acceptance Tests; helpers ONLY in `server/test/nebu/oauth/oauth_test_support.exs`
  (section "Story 4": `revoke(params, opts)` form POST builder (with `unique_ip` and optional
  headers), `assert_revoke_ok/1` (status 200, body `{}`, `application/json`, AC1 headers),
  `device_state(user_id, device_id)` (device + key-table row counts), `seed_device_keys!/2`).

### Files to modify

- `server/lib/nebu/web/router.ex` — `forward "/oauth2/revoke"` (AC1), `cors/2` branch adds
  `"revoke"`, comments at ~lines 16-21, 95-99, 101-103.
- `server/lib/nebu/web/plugs/json_body.ex` — skip `["oauth2", "revoke" | _]`; moduledoc.
- `server/lib/nebu/oauth/http.ex` — `call(conn, :revoke)`, `:revoke` in the sub-path guard, a private
  `revoke/1` with the TWO-state gate of R13 (`Config.get/0`: `:unknown` => `FormPost.server_error/3`
  503 `{}`; everything else live, no issuer needed; sub-paths `unrecognized_no_error/1`, which gains
  `Pragma: no-cache` for all its callers), 405 via `Token.method_not_allowed/1`-style
  helper with `Allow: POST, OPTIONS`); moduledoc.
- `server/lib/nebu/oauth/token.ex` — delegate to `FormPost` (no behaviour change); `token.ex` keeps
  no body read (`read_body`) and no 16 KiB cap literal of its own (static test).
- `server/lib/nebu/oauth.ex` — moduledoc (story 4, facade functions).
- `server/lib/nebu/matrix.ex` — facade `oauth_revoke_token/1`, `oauth_end_user_sessions/1` (`@doc`,
  `@spec`, rescue => `{:error, :unavailable}`, ADR-020 note like the story-3 functions).
- `server/lib/nebu/matrix/oauth_session.ex` — `revoke_token/1`, `end_device_session/2`,
  `end_all_for_user/1` (+ post-commit part reusing `kill_bound_jwts/2`; moduledoc).
- `server/lib/nebu/matrix/session/oauth_session_store.ex` — `end_session_for_token/1` (R11),
  `end_device/2`, `oauth_device_ids/1`; moduledoc ("Revocation (story 4)").
- `server/lib/nebu/matrix/device_key_store.ex` — `@device_tables` + raising `delete_device!/2`
  (transaction use); `delete_device/2` unchanged.
- `server/lib/nebu/web/plugs/oidc_plug.ex` — assign `:auth_api` in `call_opaque/2` and `call_jwt/2`
  (`"legacy"`); nothing else.
- `server/lib/nebu/web/router/protected.ex` — `/logout` OAuth branch (AC8), new `/logout/all` route
  (AC9), helper extraction so the legacy `/logout` body is shared by both routes unchanged.
- `server/lib/nebu/matrix/event_dispatcher/server.ex` — `delete_user_keys/2` success branch (AC10).
- `server/lib/nebu/web/plugs/request_logger.ex` — `/oauth2/revoke` in `@names_only_query_paths`
  (+ comment).
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — moduledoc only (story 4: `token`
  already covered), if at all.
- Tests: Trap 7 list; `server/test/nebu/matrix/session/token_hashing_test.exs` only if its
  "who touches matrix_sessions" / pass-the-hash guards need the new store functions acknowledged (they
  live in `oauth_session_store.ex`, already allowlisted; keep the plaintext-in API, Trap 10).
- Docs per AC13.

### Current state of the code this story builds on (read before coding)

- `Nebu.OAuth.Http` (story 3): `live_state/0` three-state kill switch, `unrecognized_no_error/1`,
  `empty_5xx/2`, `put_cors/1`; OPTIONS fallback clause before the action clauses; sub-path guard
  `action in [:token, :jwks, :openid_configuration]`.
- `Nebu.OAuth.Token` (story 3): `handle_token/2` with rescue/catch (500 `{}`), `dispatch/2` ->
  `parse/1` -> `charge/2` (junk charged to `oauth_token`), `json/3` sets ACAO, deletes ACAC, sets
  `no-store` + `Pragma`; `server_error/3` = `{}` + `Retry-After`; `method_not_allowed/1`,
  `unavailable/2` public. These become `FormPost` (R1).
- `Nebu.OAuth.TokenRequest`: `validate_params/1`, `valid_content_type?/1`,
  `valid_refresh_token_format?/1` (64 lowercase hex; reuse for the revoke token format, both token
  kinds share `MatrixSessionStore.generate_opaque_token/0`).
- `Nebu.Matrix.Session.OAuthSessionStore` (story 3): `@columns`, `query/2` (rescuing) and `query!/2`
  (raising inside transactions), compile-time guarded `repo/0`; `insert_replacing_device/1` upserts
  the `devices` row FIRST (row lock); `rotate/1` -> `lock_device_of/2` (`SELECT ... FROM
  matrix_sessions WHERE access_token_hash = $1`, then `SELECT 1 FROM devices ... FOR UPDATE`, rollback
  `:not_found` when the row is gone); `delete_device_oauth/2` (T11, oauth rows only, device kept);
  `delete_by_code_hash/1` (T8).
- `Nebu.Matrix.OAuthSession` (story 3): `kill_bound_jwts/2` (private, best effort), `seam/2`
  compile-time guarded, `revoke_device_session/2` (facade of T11, unchanged).
- `MatrixSessionStore`: `hash_token/1` (the single hashing seam), `revoke/1` (legacy logout: deletes
  the presented token's device rows, any `auth_api`), `delete_for_user/1` / `delete_for_user_device/2`
  (best effort, all `auth_api`), `get_by_access_token/1` returns `auth_api`.
- `OidcPlug.call_opaque/2`: unknown => `deny/3` (no `soft_logout`); revoked_at set => soft_logout
  "superseded"; expired => soft_logout; deactivated (60 s provision cache) => soft_logout; else
  assigns `access_token`, `current_user`, `device_id`, `oidc_claims`. No `oauth_enabled` check.
- `Nebu.Web.Router.Protected` `post "/client/v3/logout"`: `revoke_access_token/1` (opaque =>
  `MatrixSessionStore.revoke/1`; JWT => `TokenDenylist.revoke/3`) then
  `EventDispatcher.Server.invalidate_user_sessions(%Core.InvalidateUserSessionsRequest{user_id: user,
  device_id: ""})` => `destroy_session/1` (legacy `sessions` + `sync_tokens`, ETS eviction) +
  `MatrixSessionStore.delete_for_user/1`; always `200 {}` (R16). `/logout/all` is unrouted =>
  `match _` => `404 M_NOT_FOUND`.
- `delete_one_device/3` (protected.ex ~2035): JWT kill-switch (preserving the caller's token on a
  fresh UIA), `delete_for_user_device/2` unless preserved, `DeviceKeyStore.delete_device/2`.
- `EventDispatcher.Server.deactivate_user/2` (~4226): `set_is_active(false)`, then
  `destroy_session/1`, `delete_for_user/1`, audit `user_deactivated`.
- `EventDispatcher.Server.delete_user_keys/2` (~1816) -> `Nebu.Compliance.UserDeletion.delete_user_keys/3`
  (key soft-deletion + room account data erasure in one transaction): no session handling.
- `RequestLogger`: `@names_only_query_paths`, `normalized_path/1` (trailing / doubled slashes),
  `@no_response_body_paths`; `PayloadRedactor`: `token` in both credential lists.
- `Nebu.Web.Router.cors/2` (story 3): CORSPlug `credentials: false` for `["oauth2", "token"|"jwks"
  | _]` and `[".well-known", "openid-configuration" | _]`.

### What must be preserved

- Story-3 token endpoint behaviour byte for byte (the `FormPost` extraction is a move), refresh
  semantics T10/T11, T7 issuance, T25 JWT exclusion, T26 take-over, T27 legacy isolation.
- Legacy `POST /logout` (both credential kinds), `DELETE /devices`, `/delete_devices`, admin device
  deletion, deactivation (incl. audit row), legacy `/refresh`, `RefreshWorker`.
- `DeviceKeyStore.delete_device/2` best-effort semantics for its existing callers.
- `Nebu.Matrix` facade boundary (`lib/nebu/oauth/*.ex` calls only public `Nebu.Matrix.*`).

### Traps

1. **READ COMMITTED snapshot vs lock (R11).** A `DELETE ... WHERE user_id AND device_id` that starts
   BEFORE a concurrent rotation commits does not see the rotation's new row and leaves it alive. The
   devices-row `FOR UPDATE` must be taken in an EARLIER statement of the same transaction than the
   DELETE, so the DELETE's snapshot is taken after the rotation committed.
2. **Re-check after the lock.** Without the "presented token still has an oauth row" re-check, an old
   token revoked while the user re-logs in with the same device id (T7 deletes the old rows and
   inserts a new session) deletes the brand-new session and device.
3. **Device teardown inside the transaction.** `DeviceKeyStore.delete_device/2` uses `safe_query`
   and swallows errors; inside a transaction a swallowed failure aborts the transaction silently.
   Use the raising variant; and never delete the device AFTER the commit (a re-login may have
   recreated it).
4. **OAuth vs legacy at logout is decided at authentication time** (`:auth_api` assign), never by
   a lookup in the handler: a concurrent revoke would make the lookup miss and fall through to the
   legacy user-wide wipe.
5. **Do not route OAuth logouts through `invalidate_user_sessions(device_id: "")`**: it ends every
   session of the user (R16).
6. **200 is `{}` + `application/json`** (oracle O3): use `FormPost.json(conn, 200, %{})`; a
   `text/plain` or `text/html` type makes oidc-client-ts throw.
6a. **Revoke has NO kill switch** (R13): do not reuse `Http.live_state/0`'s `:off` => 404 branch for
   `:revoke`; the token/JWKS/openid-configuration kill switch must stay as it is.
6b. **`/logout` / `/logout/all` bodies**: clients send no body or `{}`; make sure the JsonBody
   `json_parse_error` flag (empty body with a JSON content type) never turns these into 400.
7. **Stale "revoke is 404" assertions (change deliberately, same commit):**
   `test/nebu/oauth/oauth_authorize_http_test.exs` ~91-103 ("/oauth2/revoke stays the router's plain
   404"), `test/nebu/oauth/oauth_token_http_test.exs` ~544-555 ("still the router's plain 404"),
   `test/nebu/oauth/oauth_token_static_test.exs` ~95 ("/oauth2/revoke stays unrouted"),
   `test/nebu/oauth/adr_033_test.exs` ~132-138 (story-2 "revoke not implemented") and ~194-209
   (story-3 gate / matrix-api-scope "revoke still not implemented ... story 4"); any story-4 ATDD test
   written against the pre-oracle kill-switch text (404 while disabled) is wrong; docs:
   `docs/matrix-api-scope.md` line ~33 and the `/logout` row ~44, `docs/architecture/03-context.md`
   ~16, `06-runtime.md` ~1458 and ~1533, `07-deployment.md` ~128, ADR-033 lines ~207, ~318, ~495-505,
   `Nebu.OAuth.Http` moduledoc line ~24, router comment ~98. Replace them by story-4 assertions
   (routed; kill-switch shape while disabled).
8. **JsonBody** must skip `/oauth2/revoke` before `Plug.Parsers` touches the body; read the body
   exactly once in `FormPost.parse/1`.
9. **CORSPlug runs globally with `credentials: true`**: forgetting the `cors/2` branch adds
   `Access-Control-Allow-Credentials: true` to every revoke response and preflight.
10. **Pass-the-hash guard (story 3 F-3 / `token_hashing_test.exs`).** The store API takes the
    PLAINTEXT token and hashes it once; never accept a hash from a caller; do not name a parameter
    `old_access_token_hash`.
11. **`soft_logout` at `/logout`** for an expired OAuth AT is correct Matrix behaviour (do not
    "fix" `OidcPlug`); revocation of expired tokens is `/oauth2/revoke`'s job.
12. **Rate-limit ETS is shared and never evicted**: tests use `T.reset_rate_limits/0`,
    `T.unique_ip/0`, `:rate_limit_clock_fn`.
13. **Reused test DB**: unique device ids per test (`DELETE /devices` IDOR guard and the shared
    `devices` table, story-3 dev notes); `T.cleanup_clients/1` already deletes sessions first (FK
    RESTRICT).
14. **Erasure is best effort**: `delete_user_keys/2` callers (Admin) and tests inject modules /
    run without a Repo; the new calls must not raise (`MatrixSessionStore.delete_for_user/1` and the
    facade already never raise) and must not change the response.
15. **Do not log the presented `client_id`** (attacker-controlled, up to 16 KiB): compare it, log
    `client_id_match` and the stored `client_id` only.
16. **`oauth_enabled` stays false** in every committed config; tests use `T.enable_oauth/1`.
17. **Element revokes twice** (access + refresh token, possibly in parallel): the second call must be
    a silent 200 (no WARNING, no 503 from a lock timeout).

### Architecture compliance

ADR-018 inline SQL in `OAuthSessionStore` / `DeviceKeyStore`; ADR-019 single app; ADR-020 facade-only
cross-domain calls (R1) and no node-local state for correctness (the revocation is one DB
transaction; the rate-limit bucket and the JWT denylist ETS are the existing abuse/kill-switch
mechanisms); ADR-022 no new env variables and no new `server_config` keys; ADR-033 broker model (no
IdP call, R12); OIDC Scopes Law untouched; No Sensitive Data law (AC12). No migration (no schema
change: the lookup uses the existing PK on `access_token_hash` and UNIQUE on `refresh_token_hash`,
the device lock uses the `devices` PK).

### Library / client notes

- oidc-client-ts (bundled with matrix-js-sdk 41.3.0 in `tests/matrix_compat`): `TokenClient.revoke`
  posts `token`, `token_type_hint` (when given), `client_id` (and `client_secret` only when
  configured) form-encoded via `JsonService.postForm`; response handling: `Content-Type` checked only
  when present (must start with `application/json`), empty body => `{}`, non-2xx => `ErrorResponse`
  when the JSON has `error`, plain `Error` otherwise. `UserManager._revokeInternal` revokes the types
  sequentially and stops at the first failure.
- matrix-js-sdk 41.3.0: no revocation call; `validateAuthMetadataAndKeys` requires
  `revocation_endpoint` (already advertised).
- Dart SDK 13 (oracle 2026-10-07): revokes with the possibly EXPIRED access token.

### Testing commands (isolated env, see the epic brief)

No migration: `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth
test/nebu/matrix/session test/nebu/web/plugs test/nebu/compliance"` plus the legacy logout / device /
deactivation tests (`grep -rl "logout\|delete_devices\|deactivate_user\|delete_user_keys" test/nebu`);
full gate via `integration.sh` (background, output to a file). Compare failures with
`scratchpad/known.txt` by name. Also `MIX_ENV=prod mix compile` (the new test hook must compile out).

### Docs to touch (arc42 step and dev)

ADR-033 (AC13), `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`,
`docs/architecture/03-context.md` (revoke routed, CORS list), `05-building-blocks.md`
(`Nebu.OAuth.Revoke`, `Nebu.OAuth.FormPost`, new `OAuthSession` / `OAuthSessionStore` functions,
facade), `06-runtime.md` (revocation sequence incl. the devices-row lock, OAuth `/logout`,
`/logout/all`), `07-deployment.md` (~128: revoke served; operator note: OAuth sessions survive the
kill switch; revoke and `/logout` still end them, revoke is exempt from the kill switch), `08-concepts.md` ("OAuth 2.0 Authorization Server":
revocation = logout semantics, device deletion, no client auth), `09-decisions.md` (ADR-033 row
mentions story 4), `11-risks.md` (unauthenticated revoke: any holder of any old token of a session,
also a consumed one, can end it; legacy `/logout` cross-API wipe, gate r).

### Out of scope

Account page and device deletion for OAuth sessions (6), UIA delineation / `m.oauth` /
`oauth_aware_preferred` / legacy `/logout` per-device fix (5), `/versions` (9), device grant (7),
mTLS / `private_key_jwt` (8), every follow-ups.md item (1, 2-4, h-q), IdP-side revocation (t),
enabling OAuth.

## Open questions

Resolved by the oracle gate (2026-10-10, `step-results/oauth-token-revocation-logout/oracle-context.md`):

- **O1 (R2):** confirmed: revocation and OAuth `/logout` delete the device and its E2EE keys.
- **O2 (R17):** `/logout/all` accepts OAuth tokens; CORRECTION folded into R17/AC9: it deletes ALL
  devices of the user with their keys (Matrix spec).
- **O3 (R6):** 200 with `{}` and `Content-Type: application/json`.
- **O4 (R6):** Element Web revokes access and refresh token in parallel, clears local state on
  failure and does not call `/logout`; matrix-js-sdk never calls revoke.
- **O5 (R13):** revoke stays LIVE while disabled / with an invalid issuer; only `:unknown` => 503 `{}`.

Also folded in: R4 wording ("conforms to the Matrix spec"), R20 (`soft_logout` absent = consistency
choice), ACAO `*` on every status, the oracle's extra tests (Must 1, 3, 5, 18, 23, 24, 26, 30),
follow-up (s) `device_lists.changed` on device deletion (non-gating). No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story, non-interactive, 2026-10-10)

### Debug Log References

- `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth test/nebu/migration
  test/nebu/matrix/session test/nebu/web/plugs"`: run 1 1642/1654 (docs + 3 genuinely wrong tests, see
  below), run 2 1654/1654.
- Full run `quick.sh "mix test --include integration"` (reused quick DB, no migration needed): 4647
  tests, 37 failures, 3 skipped. By name all 37 are in `known.txt` or the known families: 12
  `RoomsFallbackNameTest`, the TraceMap / WarRoom / TemporaryCapture / LogStore retention / sync-load
  flakes. None is OAuth, logout, revocation, erasure or deactivation related.
- `MIX_ENV=prod mix compile --force` in the quick container: compiles; the only warning is the
  pre-existing `event_dispatcher/server.ex:4840` type warning (the test hook stubs compile out).
- matrix_compat node replay (optional): not executed (the ExUnit tests pin the shapes).

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- No migration (000042 untouched): the lookup uses the existing hash indexes, the lock the `devices` PK.
- `Nebu.OAuth.FormPost` (new): the form-POST plumbing MOVED out of `Nebu.OAuth.Token` (parse order,
  16 KiB cap, JSON / error / 5xx responses, `ip_string/1`); `Token` delegates, behaviour byte-identical
  (the whole story-3 suite is green; `token.ex` has no `read_body` and no cap literal).
- `Nebu.OAuth.Revoke` (new): AC2 order, `{"oauth_revoke", ip}` 60/min burst 600 charged after the parse
  and before any DB access, `200 {}` (`application/json`) for revoked and unknown tokens, 503 `{}` for a
  storage error, rescue => 500 `{}`, R21 INFO log (outcome, `client_id_match`; the presented client id
  is only compared), compile-time guarded `:oauth_revoke_test_hook`.
- `Nebu.OAuth.Http`: `:revoke` action with the TWO-state gate (R13: only `:unknown` => 503 `{}`;
  disabled / invalid issuer stay live), 405 incl. HEAD, sub-path 404 via `unrecognized_no_error/1`
  (now with `Pragma: no-cache`). Router: forward, `"revoke"` in the credentials-free CORS branch;
  `JsonBody` skips the path; `RequestLogger` names-only list.
- Matrix side: `OAuthSessionStore.end_session_for_token/1` (plain SELECT, devices-row `FOR UPDATE`,
  re-check after the lock, DELETE, raising device-table deletion INSIDE the transaction),
  `end_device/2`, `oauth_device_ids/1`; `OAuthSession.revoke_token/1` (format check repeated, post-commit
  JWT kill-switch + per-device legacy session cleanup), `end_device_session/2`, `end_all_for_user/1` and
  `end_all_devices/1`; `DeviceKeyStore` gets `@device_tables` + `delete_device!/3` (repo parameter so the
  statements run on the store's transaction connection; `delete_device/2` behaviour unchanged).
  Facade: `oauth_revoke_token/1`, `oauth_end_user_sessions/1` (R24) and `end_all_user_devices/1` (the
  `/logout/all` step 3, a documented addition to the story's facade list: the web layer must not reach
  into `Nebu.Matrix.OAuthSession`).
- Logout: `OidcPlug` assigns `:auth_api` (`"legacy"` for JWTs); `POST /logout` OAuth branch ends only the
  device (500 `M_UNKNOWN` on storage failure); the legacy body is extracted to `legacy_logout/2` and is
  byte-identical (R16); new `POST /logout/all` (OAuth sessions + devices, then the legacy part, then every
  remaining device with its keys; cross-signing untouched; a failed part => 500 but the others still ran).
- GDPR erasure: `delete_user_keys/2` success branch now ends OAuth sessions (facade), legacy opaque
  sessions and legacy `sessions`/`sync_tokens` best effort after the commit; response unchanged, error
  branches end nothing.
- Tests changed by dev (genuinely wrong, minimal): (1) `oauth_request_logger_redaction_test.exs` and
  `oauth_revoke_logging_test.exs`: `Plug.Test.conn(:post, "//oauth2//revoke")` parses `//oauth2` as the
  URI authority (host `oauth2`, path `//revoke`), so the doubled-slash path never reached the route; the
  test now uses `http://localhost//oauth2//revoke`, which keeps the doubled slashes in `request_path` as
  Bandit delivers them. (2) `oauth_logout_test.exs` `oauth_end_user_sessions/1`: `T.legacy_session!/3`
  creates only the session row, so the assertion `devices == 1` for the legacy device was unsatisfiable;
  the test seeds the legacy device (`T.seed_device_keys!/2`) first. (3) `oauth_logout_test.exs` "/logout/all
  works while OAuth is DISABLED": `assert_all_gone/2` then calls `/oauth2/token`, which IS behind the T22
  kill switch (404 while disabled); the test re-enables OAuth after the logout call.
- Deviations / notes: R20 `soft_logout` absent is a consistency choice; the optional matrix_compat revoke
  replay was not written/executed; arc42 docs (03/05/06/07/08/09/11) are left to the arc42 step.
- Docs: ADR-033 section "Token revocation and logout (story 4)" (R1-R24, R4 as conformance, R16 as the
  deviation, R13 exemption, T22 pointer, story-2/3 "unrouted" wording, gate paragraph), `docs/matrix-api-scope.md`
  (revoke, logout, logout/all rows), `follow-ups.md` (story-4 section (a)-(c), gate rows r, s, t).
  `oauth_enabled` stays default off.

### Review cycle 1 (code review 0 MAJOR / 4 MINOR, Kassandra F-1, F-2 LOW)

- F-1 / MINOR 1: `POST /logout/all` answers 200 only when every CHECKED part succeeded (wording narrowed after the
  delta review: the legacy core cleanup of sessions/sync_tokens and the other devices' bound-JWT kill-switch stay best-effort). The legacy part is
  guarded (an exception in the checked deletes is a failure), the caller's raw JWT is denylisted with the new CHECKED
  `TokenDenylist.revoke_checked/3` (a failed durable insert => 500; the node's ETS entry stays, so the
  token is dead there), and step 3 now covers every device AND every `matrix_sessions` row of the user.
  Legacy `/logout` is untouched (best effort, byte-identical; a test shows it still answers 200 while the
  durable denylist insert fails).
- F-2 / MINOR 2: `OAuthSession.end_all_devices/1` tears down the union of `devices` rows and
  `matrix_sessions` device ids, each with the atomic locked `OAuthSessionStore.end_device/3` (devices
  lock, all sessions of the device, device tables, one transaction) + JWT kill-switch; a session without
  a devices row can no longer survive. Deliberate: step 3 uses `Nebu.Repo` directly (the store functions
  gained an optional repo argument), i.e. NOT the `:oauth_session_repo` test seam, because the ATDD test
  "OAuth part fails (repo unavailable) => 500, step 3 still ran" models an OAuth-only failure with that seam.
- MINOR 3: `kill_bound_jwts/2` deletes the JWT bindings only after EVERY denylist write was confirmed
  (`TokenDenylist.revoke_by_hash_checked/2`); on a failed write the bindings are kept and a warning is
  logged (the ETS entry of the node stays).
- MINOR 4: `catch :exit` added to `revoke_token/1`, `end_device_session/2`, `end_all_for_user/1`,
  `end_all_devices/1` and `kill_bound_jwts/2` (`after_commit/2` was already guarded).
- Changelog note (INFO): `unrecognized_no_error/1` gained `Pragma: no-cache`, which also changes the
  story-3 kill-switch 404s (harmless).
- New tests (`oauth_logout_test.exs`, "review cycle 1"): failing legacy delete => 500 and the legacy
  session still alive, retry succeeds; failed durable denylist insert => 500 while legacy `/logout` stays
  200; a login committing while `/logout/all` waits on a device lock survives whole, listed devices gone;
  a session without a devices row is ended; binding kept on a failed denylist write / deleted on success;
  exit (`ExitRepo`) => `{:error, :unavailable}` / 503 at revoke. Test helper `T.block_session_deletes!/2`
  gained an optional `auth_api:` filter.

### File List

- `server/lib/nebu/oauth/form_post.ex` (new), `server/lib/nebu/oauth/revoke.ex` (new)
- `server/lib/nebu/oauth/token.ex`, `oauth/http.ex`, `oauth.ex`
- `server/lib/nebu/matrix.ex`, `matrix/oauth_session.ex`, `matrix/session/oauth_session_store.ex`,
  `matrix/device_key_store.ex`, `matrix/event_dispatcher/server.ex`
- `server/lib/nebu/web/router.ex`, `web/router/protected.ex`, `web/plugs/{json_body,oidc_plug,request_logger}.ex`
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/matrix-api-scope.md`,
  `docs/stories/oauth-broker/follow-ups.md`, this story file
- Tests fixed by dev: `server/test/nebu/oauth/{oauth_request_logger_redaction_test,oauth_revoke_logging_test,oauth_logout_test}.exs`
- Review cycle 1 additionally: `server/lib/nebu/web/token_denylist.ex`, `server/test/nebu/oauth/{oauth_logout_test,oauth_test_support}.exs`
- ATDD files (staged before dev): `server/test/nebu/oauth/oauth_{revoke_http,revoke_semantics,logout,revoke_logging,revoke_static}_test.exs`,
  extended `oauth_test_support.exs`, `adr_033_test.exs`, `oauth_authorize_http_test.exs`, `oauth_metadata_test.exs`,
  `oauth_payload_redaction_test.exs`, `oauth_token_e2e_test.exs`, `oauth_token_http_test.exs`,
  `oauth_token_static_test.exs`, `server/test/nebu/matrix/session/oauth_session_store_test.exs`

## Change Log

- **2026-10-10:** Story created (create-story, non-interactive) for story 4 of epic oauth-broker:
  RFC 7009 `POST /oauth2/revoke`, one atomic revocation function (session + device), OAuth `/logout`,
  `/logout/all`, GDPR erasure session kill, decisions R1-R24, open questions O1-O5.
- **2026-10-10 (oracle-amended):** O1-O5 resolved; R6/AC1/AC6 `200 {}` + `application/json`; R13 no
  kill switch for revoke (only `:unknown` => 503); R17/AC9 `/logout/all` deletes all devices + keys;
  R4 wording, R20 rationale, R14 ACAO on every status; R8 decoding / no trimming / case-insensitive
  content type; extra tests (empty `/logout` bodies, dead token on `/logout/all`, HEAD 405,
  `/keys/query`, revoke after `DELETE /devices`, no Set-Cookie / WWW-Authenticate); follow-up (s).
- **2026-10-10 (atdd):** red-phase acceptance tests written (ATDD role, non-interactive) for AC1-AC13
  and Must #1-#36 (5 new test files, 10 extended files, story-4 helpers in `oauth_test_support.exs`);
  section "ATDD Decisions (story 4)" appended (pinned APIs, seams, deliberate stale-404 changes,
  contradictions/gaps with proposed text).

- **2026-10-10 (dev-story):** implemented R1-R24 / AC1-AC13: `POST /oauth2/revoke` (live while disabled),
  `FormPost` extraction, one atomic revocation function on the Matrix side, OAuth `/logout`, `/logout/all`,
  GDPR erasure session kill, docs (ADR-033, matrix-api-scope, follow-ups r/s/t). All story-4 tests green;
  status `review`.

## ATDD Decisions (story 4)

Written by the ATDD role (2026-10-10, red phase). Run (`quick.sh "mix test --include integration
--warnings-as-errors test/nebu/oauth test/nebu/migration test/nebu/matrix/session test/nebu/web/plugs"`):
1638 tests, 150 fail, 1488 pass. ALL 150 failures are in story-4 tests (new files or the deliberately
changed story-2/3 assertions); every story-1/2/3 test stays green. Failure shapes: `/oauth2/revoke`
unrouted (router plain `404 "not found"`, incl. ACAC on the sub-path 404 and the preflight because
the credentials-free CORS branch is missing), `/logout/all` unrouted (`404 M_NOT_FOUND`), OAuth
`/logout` still the user-wide legacy wipe (other devices 401, device kept, DB failure => 200 or the
legacy crash), no `:auth_api` assign, missing modules/functions (`UndefinedFunctionError` for
`Nebu.Matrix.oauth_revoke_token/1`, `oauth_end_user_sessions/1`, `OAuthSessionStore.end_session_for_token/1`,
`end_device/2`, `oauth_device_ids/1`, `OAuthSession.end_device_session/2`, `DeviceKeyStore.delete_device!/2`),
missing files (`revoke.ex`, `form_post.ex`), the erasure ending no session, `/oauth2/revoke` not on
the names-only list, and missing docs (ADR section, matrix-api-scope rows, follow-ups section).
`--warnings-as-errors` compiles (all calls into new code go through `apply/3`). The dev MUST
implement against these names; changing one means changing the tests in the same commit.

### Test files

New (`server/test/nebu/oauth/`): `oauth_revoke_http_test.exs` (AC1-AC3, AC6, R13 no kill switch,
CORS on every status, request format, rate limit, 5xx, ignored credentials, byte-identical 200s),
`oauth_revoke_semantics_test.exs` (AC4, AC5, AC7: every token kind, hint/client_id matrix, no-hit
snapshots, device teardown, `/keys/query`, cross-signing, JWT kill-switch, concurrency a/b/c + stress),
`oauth_logout_test.exs` (AC8-AC10: `:auth_api`, OAuth `/logout`, legacy regression, `/logout/all` for
OAuth / legacy opaque / raw-JWT callers, DELETE /devices, deactivation, GDPR erasure, the
`oauth_end_user_sessions/1` facade), `oauth_revoke_logging_test.exs` (AC12), `oauth_revoke_static_test.exs`
(R1, AC1 router/CORS/JsonBody, test hook guard, `FormPost` extraction, `@device_tables`, Must #35).
Extended: `test/nebu/matrix/session/oauth_session_store_test.exs` (store + `OAuthSession` functions,
re-check after lock, `delete_device!/2`), `oauth_token_e2e_test.exs` (Dart-SDK logout with an expired
AT), `oauth_metadata_test.exs` (AC11), `oauth_payload_redaction_test.exs` (AC12 confirmation, green by
design), `oauth_request_logger_redaction_test.exs` (AC12), `adr_033_test.exs` (AC13), and the stale
tests below. Not written: the optional `tests/matrix_compat` node replay (not executed; the ExUnit
tests pin the shapes, record it in the Dev Agent Record).

### Deliberately changed story-2/3 assertions (Trap 7)

- `oauth_authorize_http_test.exs` "AC1/D21 — /oauth2/revoke stays the router's plain 404": now
  "/oauth2/revoke is routed and live" (GET 405, POST malformed token `200 {}` enabled AND disabled,
  `:unknown` => `503 {}`); moduledoc line updated.
- `oauth_token_http_test.exs` "/oauth2/revoke is still the router's plain 404": now routed + live
  while disabled, plus "the /oauth2/token T22 kill switch is unchanged while disabled" (Must #36).
- `oauth_token_static_test.exs` "/oauth2/revoke stays unrouted (story 4)": now "is routed (story 4)".
- `adr_033_test.exs`: story-2 matrix-api-scope test now REFUTES "revoke ... not implemented"; the
  story-3 gate test keeps its assertions (`/oauth2/revoke`, `story 4`, `oauth_token`) under a new
  title; the story-3 matrix-api-scope test refutes "revoke ... not implemented" instead of asserting it.
- `oauth_resource_server_test.exs` "POST /logout with the OAuth access token removes every row of the
  device" is UNCHANGED (still true; the device deletion is asserted in `oauth_logout_test.exs`).

### Pinned APIs (beyond the story text)

- `Nebu.Matrix.oauth_revoke_token/1` exactly per R24; `{:ok, :revoked, %{user_id:, device_id:,
  client_id:}}` carries the STORED `client_id`; a second call for the same session => `{:ok, :unknown}`.
- `Nebu.Matrix.oauth_end_user_sessions/1 :: {:ok, [device_id]} | {:error, :unavailable}`; a second call
  => `{:ok, []}`; legacy rows/devices are not touched by it (the `/logout/all` handler deletes them).
- `OAuthSessionStore.end_session_for_token(plaintext) :: {:ok, :revoked, info} | {:ok, :unknown} |
  {:error, term}` (the story's bare `:unknown` is wrapped in `{:ok, _}` like the facade);
  `end_device(user_id, device_id) :: :ok | {:error, term}` (every row of the device, any `auth_api`,
  + device tables); `oauth_device_ids(user_id) :: {:ok, [device_id]} | {:error, term}` (DISTINCT).
- `OAuthSession.end_device_session/2 :: :ok | {:error, :unavailable}` (includes the JWT kill-switch);
  `OAuthSession.end_all_for_user/1 :: {:ok, [device_id]} | {:error, :unavailable}`.
- `DeviceKeyStore.delete_device!/2 :: :ok` (idempotent; raises on a DB error); the shared
  `@device_tables` list of AC5 is no longer pinned statically (test review MINOR 11).
- `OidcPlug` assigns `:auth_api` = `"oauth"` | `"legacy"` (JWT => `"legacy"`).
- Texts: 413 `error_description` exactly "The request body is too large."; missing token exactly "The
  token parameter is required."; OAuth `/logout` failure body exactly `{"errcode":"M_UNKNOWN","error":"Logout
  failed, please try again."}`; R21 INFO lines contain exactly `OAuth revoke: outcome=revoked client_id_match=true`,
  `... outcome=revoked client_id_match=false`, `OAuth revoke: outcome=ignored client_id_match=absent`
  (well-formed unknown token without `client_id`), plus `user_id`, `device_id` and the stored `client_id`
  on `revoked`. Revocation logs nothing at WARNING for a lost race / second revocation.
- Docs (AC13 tests): ADR heading "Token revocation and logout (story 4)" with R1..R24; one line with
  `R4` + "conforms to the Matrix spec" + "SHOULD still revoke" and no `R4` line containing "deviation";
  one line with `R16` + "deviation" + `/logout`; `exempt`, `invalid_client`, `unsupported_token_type`,
  `200 {}`, `oidc-client-ts`; the ADR contains "`/oauth2/revoke` is exempt, story 4 R13" and no
  "`/oauth2/revoke` stays unrouted" without "(until story 4)"; the gate paragraph contains "Story 4
  update", "every advertised endpoint exists" and "gate items 1, h, i, l, m, n, r". matrix-api-scope:
  `| POST | \`/oauth2/revoke\` | ✅` row with "RFC 7009", "no client auth", "200 {}", "rate limit",
  "disabled", "503"; the `/logout` row mentions OAuth, "current device" and legacy; a
  `| POST | \`/_matrix/client/v3/logout/all\` | ✅` row. follow-ups.md: a `## ...
  oauth-token-revocation-logout` section naming `oauth_revoke`, table rows `| r |` (with `/logout`),
  `| s |` (with `device_lists`), `| t |` (with `IdP`).

### Seams (test support `Nebu.OAuth.TestSupport`, section "Story 4")

- Existing: `:oauth_config_source` (`enable_oauth/1`, `disable_oauth/0`, `unreadable_oauth_config/0`),
  `:oauth_session_repo` NoSuchRepo (now also every new store function: revoke => `503 {}`, `/logout`
  => `500 M_UNKNOWN`, `/logout/all` => `500 M_UNKNOWN`), `:rate_limit_clock_fn`, `:uia_fresh_auth_seconds`,
  `:matrix_oidc_refresh_override`, `T.block_session_deletes!/1` (trigger => DB error on the DELETE).
- NEW `:nebu_http, :oauth_revoke_test_hook` (compile-time guarded): 0-arity fun called FIRST in
  `Revoke.handle_revoke/1` inside the rescue; a raise => `500 {}` + `Retry-After`, exception message
  never logged (`T.inject_revoke_handler_fault!/0`).
- Helpers: `revoke/2`, `revoke_params/3`, `assert_revoke_ok/1`, `assert_revoke_error/3`,
  `assert_revoke_5xx/2`, `assert_revoke_headers/1` (token headers + no Set-Cookie / WWW-Authenticate),
  `device_state/2`, `device_gone?/2`, `seed_device_keys!/2`, `seed_cross_signing!/1`, `world_snapshot/1`,
  `insert_jwt_binding!/4`, `logout/2` (`body: :none | :empty_json | :object`, `path: :all`),
  `assert_logout_ok/1`, `assert_unknown_token/2` (`soft_logout` key ABSENT), `legacy_refresh/1`, `safely/1`.
- Concurrency ordering (AC5 a/c, store re-check): the test holds `SELECT ... FROM devices ... FOR
  UPDATE` in a `Nebu.Repo.transaction`, starts the revocation in a Task, asserts `Task.yield(task, 500)
  == nil` (proves it WAITS for the lock; same idiom as story 3's MINOR-2 test, not a sleep), then
  commits a hand-made rotation (UPDATE + INSERT) or a T7 re-login (DELETE + INSERT). This assumes R11
  exactly: step (1) is a PLAIN SELECT (no row lock on `matrix_sessions` before the devices lock),
  otherwise the test's UPDATE would deadlock with the revocation.

### Contradictions / gaps with the story (resolved in the story text, test review 2026-10-10)

All six were folded into the story text after the test review: (1) AC1 / Dev Notes: the shared
`unrecognized_no_error/1` gains `Pragma: no-cache`; (2) R11: step (1) is a plain SELECT, 0 rows =>
`{:ok, :unknown}`, nothing locked; (3) R21: `client_id_match` = `absent` when no `client_id` was sent,
else `false` (unless it equals the stored one); (4) Dev Notes: no body read / 16 KiB cap in `token.ex`;
(5) AC9: OAuth part failed => `500 M_UNKNOWN` while the legacy part and the all-device deletion still
run, a failed step 3 => `500 M_UNKNOWN`; (6) AC8/AC9: body variants for every caller kind. DEVIATION
from the test review: it asked "an invalid non-empty JSON body keeps today's `400 M_NOT_JSON`", but
today's legacy `/logout` IGNORES the body (measured: `200` + user-wide wipe). R16 keeps legacy
byte-identical, so the story pins "an invalid non-empty JSON body is ignored" for every caller kind
(legacy regression green, OAuth `/logout` and `/logout/all` red).

### Test review follow-up (2026-10-10)

MINORs fixed in the tests: percent-encoded REAL token revoked (semantics); byte-identical 200 also for
an already-revoked and a legacy token; `/logout/all` fixture gains a legacy device with a bound raw JWT
(denylisted afterwards) and a step-3 failure test (`T.block_deletes!/2` on `devices` => `500
M_UNKNOWN`); the OAuth-part-fails test asserts the devices are still deleted; `POST /delete_devices`
regression; GDPR erasure best effort (`:oauth_session_repo` NoSuchRepo => response unchanged, no
raise, WARNING without secrets); body variants for legacy opaque and raw-JWT callers on `/logout` and
`/logout/all`, unauthenticated `/logout/all` => `401 M_MISSING_TOKEN`, `/logout/all` while disabled,
invalid non-empty JSON ignored (see (6)); cross-user SAME `device_id` isolation; a deterministic
parallel-revoke test (both wait on the held devices lock, exactly one `{:ok, :revoked, _}`); the
`token.ex` static pin loosened to "no `read_body`, no 16 KiB literal"; brittle regex pins for the router
forward / CORS branch / JsonBody skip / `@device_tables` dropped (covered behaviourally); the helper-only
test dropped. Documented only: item 9 (the Element "no WARNING" check stays a log-level refute) and item
10 (the stale `docs/architecture/03-context.md`, `06-runtime.md`, `07-deployment.md`, `11-risks.md`
texts are owned by the arc42 step; only ADR-033, matrix-api-scope and follow-ups are pinned by tests).
