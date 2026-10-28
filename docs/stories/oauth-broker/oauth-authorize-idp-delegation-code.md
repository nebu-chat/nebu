---
story_id: oauth-authorize-idp-delegation-code
title: "Authorize + IdP delegation + code (both scope prefixes)"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: true
created: 2026-10-10
branch: feature/migrate-to-oauth2
---

## Summary

Story 2 of epic `oauth-broker` (spec section 13 row 2). It implements the browser half of the
OAuth 2.0 authorization code grant with Nebu as authorization server in front of the corporate
IdP (broker model O2, ADR-033):

1. **`GET /oauth2/authorize`**: strict validation of the authorization request (RFC 6749 4.1.1,
   RFC 7636, RFC 9700, Matrix CS API v1.15+ "Authorisation code flow"): approved client,
   exact redirect URI (loopback port exception), PKCE `S256` only, `response_mode`
   `query`/`fragment` (the client's explicit choice is honoured; absent => fragment for https
   redirect URIs), Matrix scopes in BOTH prefixes
   (`urn:matrix:client:` and `urn:matrix:org.matrix.msc2967.client:`), exactly one
   `device:<id>`, `api:*` required, own device-id scope validator.
2. **Delegation to the IdP**: the validated request is persisted in `oauth_authz_requests`
   (single use, 10 min TTL, atomic consume in SQL, cluster safe) and the browser is sent to the
   IdP through the EXISTING `Nebu.Matrix.SsoLogin` machinery (PKCE + nonce toward the IdP, scope
   via `Nebu.Web.OidcScopes`, `offline_access` per `matrix_oidc_refresh_mode`).
3. **IdP callback**: the SHARED, already IdP-registered callback
   `/_matrix/client/v3/login/sso/redirect/oidc` branches on a tagged `state` (`o2.` prefix, the
   precedent is the UIA-tagged state) into the OAuth completion: code exchange, `id_token`
   verification (`OidcPlug.verify_token/2`), nonce check, user provisioning incl. deactivation
   check, IdP refresh token encrypted (`SecretBox`).
4. **Nebu authorization code**: 256-bit random, only its SHA-256 hash stored in `oauth_codes`,
   single use, TTL 60 s, bound to client, redirect URI, PKCE challenge, device, user, scope
   (with the request's prefix) and response mode. The browser is redirected to the client with
   `code`, `state`, `iss` (RFC 9207). The store API to CONSUME a code (atomic, with reuse
   detection) is built and tested here; the token endpoint itself is story 3.

Every error that happens after the client and its redirect URI are trusted is returned to the
client as an RFC 6749 4.1.2.1 error redirect (`error`, `error_description`, `state`, `iss`, never
`errcode`); every error before that (unknown client, bad/mismatching redirect URI, pending or
rejected client, unknown/expired/replayed IdP state) is an accessible HTML page and NEVER a
redirect.

`/oauth2/token` and `/oauth2/revoke` stay `404` (stories 3/4). `oauth_enabled` stays `false` by
default and nothing in this story enables it. **The hard gate of `follow-ups.md` item 1
(trusted-proxy client-IP resolution) still applies before `oauth_enabled` may be true; this
story's per-IP buckets on authorize/callback are subject to the same weakness.**

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 3, 3a, 5
(steps 1-4), 10, 11, 13; `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`;
`_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`; Matrix CS API
`content/client-server-api/_index.md` ("Authorisation code flow", "Callback", "Authorisation
code grant", "Device ID allocation", "User registration"), RFC 6749 3.1/3.3/4.1, RFC 7636,
RFC 8252 7.3, RFC 9207, RFC 9700 2.1/4.1/4.5/4.7.

## Story

As a **Matrix user of an OAuth-capable client (Element Web, FluffyChat / Dart SDK)**,
I want the client to send me to Nebu's authorization endpoint, sign in at my corporate IdP and
come back to the client with a Nebu authorization code,
so that the client can (in story 3) obtain Nebu-issued tokens for a device it allocated, while
operators keep a single IdP client and only admin-approved applications can start a login.

## Decisions

Every design decision of this story. ADR-033 gets a new section that records D1-D23 (AC17).

- **D1 (callback: reuse the shared IdP callback, deliberate deviation from spec section 3).**
  The IdP leg reuses the ONE IdP client and its FIXED redirect URI
  `<public>/_matrix/client/v3/login/sso/redirect/oidc` (`SsoLogin.callback_url/1`,
  `dev/dex/config.yaml` `redirectURIs`). No `/oauth2/callback` route is added: an alias would
  only be reachable if operators registered a second redirect URI at their corporate IdP, which
  is exactly the reconfiguration the broker model avoids. `SsoLogin.callback/1` branches on the
  `state` tag (precedent: the UIA-tagged `SsoStore` state of `uia_fallback/1`). Spec section 3
  lists `/oauth2/callback` as "intern"; the deviation is recorded in ADR-033.
- **D2 (state tag and storage).** The IdP-leg `state` is `"o2." <> Base.url_encode64(32 random
  bytes, padding: false)` (exactly 46 chars, regex `\Ao2\.[A-Za-z0-9_-]{43}\z`). Legacy states
  are 32 lowercase hex chars and can never collide. ANY `state` that starts with `o2.` is routed
  to the OAuth completion, also a malformed one (it then gets the HTML error page, never the
  legacy path). The row key is `state_hash = sha256_hex(state)` (spec section 11 sketches
  `state_id`; storing a hash is a deliberate hardening: a DB read leak yields no usable state).
- **D3 (cluster-safe, DB-backed flow state, NOT `SsoStore`).** `SsoStore` is node-local ETS with
  best-effort `pg` replication (its moduledoc admits cross-node single use is not guaranteed).
  The OAuth flow keeps NOTHING in `SsoStore`: the IdP PKCE verifier (encrypted with `SecretBox`),
  the IdP nonce (plain, it travels through the browser in the IdP URL anyway), the client
  request and a browser-binding hash live in the `oauth_authz_requests` row, consumed by ONE
  atomic `DELETE ... WHERE state_hash = $1 RETURNING ..., (expires_at > now()) AS live`.
- **D4 (browser binding cookie, RFC 9700 4.7 / login-CSRF on the broker leg).** The authorize
  302 sets a per-flow cookie `nebu_oa_<first 16 hex chars of state_hash>` = 32 random bytes
  (base64url), `HttpOnly; SameSite=Lax; Path=/_matrix/client/v3/login/sso/redirect/oidc;
  Max-Age=600` (+ `Secure` when the request is https, determined like `SsoLogin.callback_url/1`).
  Only `sha256_hex(value)` is stored (`browser_binding_hash`). The callback requires the cookie,
  compares in constant time (`Plug.Crypto.secure_compare/2` on the hashes) and deletes it
  (`Max-Age=0`). Mismatch/missing => HTML error page, the row is consumed anyway. Per-flow names
  keep two parallel logins in two tabs working. Assumption (documented): authorize and callback
  are served on the same host, which is already required because `callback_url/1` is built
  from the authorize request's `Host`.
- **D5 (no consent screen).** Nebu shows no "App X wants to access your account" page in
  story 2: admin approval of the registration (story 1) is the consent gate, and the IdP is
  always asked for an interactive login (D11). Accepted by the oracle gate (2026-10-10);
  recorded as a follow-up note in follow-ups.md, not a gate. Review cycle 2 (Kassandra F-2): the
  premise is enforced as far as the IdP allows by always sending `max_age=0` on the OAuth leg (also
  with `prompt=create`); the `auth_time` freshness check and a consent screen stay gate (i) in
  follow-ups.md.
- **D6 (`api:*` required, only `api:*`; NEBU POLICY, not a spec MUST).** The spec only mandates
  exactly one device token; Nebu additionally requires the `api:*` token of the
  same prefix as the device token; missing => `invalid_scope`. No other `api:` variant exists in
  the spec; `urn:matrix:client:api:read:*` etc. are treated as unknown tokens (D7). The granted
  Matrix part of the granted scope is ALWAYS exactly `"<prefix>api:* <prefix>device:<id>"`,
  preceded by `openid` when the request contained `openid` (D23).
- **D7 (unknown scope tokens are ignored, not rejected; RFC 6749 3.3 "MAY fully or partially
  ignore"; the mixed-prefix rejection is NEBU POLICY).** `openid` is NOT unknown (D23). Tokens
  that are syntactically valid but unknown (`profile`,
  `urn:matrix:client:com.example.msc1234:foo`, `api:read:*`) are dropped from the granted scope
  and never echoed. A token that violates the RFC 6749 3.3 charset (`%x21 / %x23-5B / %x5D-7E`)
  is a malformed request => `invalid_scope`. The Matrix tokens of one request must all use the
  SAME prefix; mixing stable and unstable (`urn:matrix:client:api:*` +
  `urn:matrix:org.matrix.msc2967.client:device:X`) => `invalid_scope` (we could not echo "the
  request's prefix" otherwise).
- **D8 (device-id validator).** New pure validator in the OAuth domain (NOT
  `Nebu.Matrix.DeviceId.valid?/1`, which admits `"`, `\` and non-ASCII): 1..255 bytes, every
  byte in `%x21 / %x23-5B / %x5D-7E`. No minimum length beyond 1 is enforced (the spec says the
  server MAY reject short ids; rejecting what clients legitimately send is the bigger
  interoperability risk; confirmed by the oracle gate 2026-10-10). Exactly one `device:` token (counting occurrences, also two identical
  ones => `invalid_scope`).
- **D9 (device-id reuse).** The `devices` primary key is `(user_id, device_id)`, so a device id
  can never "belong to another user"; there is nothing to reject in story 2. Reuse of an
  existing device of the SAME user is legitimate and means "revoke all earlier tokens of that
  device" (spec section 5.1). That revocation happens atomically when tokens are issued
  (story 3). Story 2 only carries `user_id` + `device_id` through the code; it neither creates
  the `devices` row nor checks it (a code may never be redeemed).
- **D10 (`response_mode`, corrected after the oracle gate 2026-10-10).** Allowed: `query`,
  `fragment`, for EVERY redirect URI; anything else (`form_post`, `query.jwt`, ...) =>
  `invalid_request`. An explicit value is ALWAYS honoured, also `query` with an https redirect
  URI: matrix-js-sdk hard-codes `response_mode=query` and Element Web registers an https redirect
  URI, so rejecting it would break Element Web. The spec's fragment bullet ("Authorisation code
  grant") is a joint homeserver/client MUST read as "support it"; the "Callback" section says the
  CLIENT SHOULD choose fragment. Absent => `fragment` for an https redirect URI, `query`
  otherwise (loopback, private-use scheme). The error redirect for an invalid mode uses that
  default mode of the redirect URI.
- **D11 (`prompt`).** Toward the IdP Nebu keeps the legacy `prompt=login` (interactive login every
  time, legacy parity, plus `max_age=0` always, review cycle 2). Client `prompt=create` replaces it with `prompt=create` ONLY when the
  IdP's discovery document lists `create` in `prompt_values_supported`; otherwise it is ignored.
  `prompt=none` (OIDC Core 3.1.2.1): Nebu always requires an interactive IdP login, so it answers
  the client with a `login_required` error redirect (state + iss) WITHOUT contacting the IdP and
  without persisting a request. All other `prompt` values are ignored; a space-separated list
  containing `none` together with another value => `invalid_request` (OIDC Core). Nebu does NOT
  advertise `prompt_values_supported` in its metadata (the value would depend on the IdP and the
  metadata is cached 3 days); confirmed by the oracle gate 2026-10-10.
- **D12 (`action` and other unknown parameters).** RFC 6749 3.1: unrecognised parameters are
  ignored. `action` is a parameter of the LEGACY SSO redirect (OAuth-aware compatibility,
  story 5) and of the account-management URL (story 6), not of the authorization endpoint; it is
  ignored here, as are `login_hint`, `max_age`, `ui_locales`, `claims`, `request`,
  `request_uri` (none is forwarded to the IdP). The client `nonce` is NOT ignored: it is
  validated and stored for story 3, but never forwarded to the IdP (Nebu uses its own IdP nonce,
  D3; see D23).
- **D13 (duplicate and array parameters).** RFC 6749 3.1: parameters MUST NOT appear more than
  once. The query string is parsed RAW (`URI.query_decoder/1`), not via `conn.query_params`
  (last-wins, and `x[]=` becomes a list). A duplicated or array-shaped `client_id` or
  `redirect_uri` => HTML error page; any other duplicated parameter => `invalid_request` redirect.
  A malformed percent-encoding => HTML error page.
- **D14 (state).** `state` is optional (RFC 6749 RECOMMENDED; PKCE protects the client). Max
  2048 bytes, valid UTF-8, no control characters (`\p{Cc}`, PostgreSQL text cannot store NUL);
  violation => `invalid_request` WITHOUT echoing the state. Absent => no `state` in the response.
- **D15 (`iss`).** Every authorization response (success AND error redirect) carries
  `iss=<normalized Nebu issuer>` (RFC 9207). Metadata advertises
  `authorization_response_iss_parameter_supported: true`. The authorize endpoint is live only when
  `Nebu.OAuth.Config` is `:enabled` AND the issuer normalizes (`Metadata.normalize_issuer/1`);
  otherwise `404 M_UNRECOGNIZED` (same fail-closed rule as the metadata).
- **D16 (code format and binding).** Code = `Base.url_encode64(32 random bytes, padding: false)`;
  stored `code_hash = sha256_hex(code)` (high-entropy input, no salt needed). TTL 60 s (CHECK in
  the table). The encrypted IdP refresh token (`idp_rt_enc`, nullable when the IdP returned none)
  and `auth_time` (id_token `auth_time`, else `iat`, like `HttpPublic.login_auth_time/1`) live IN
  the code row (no separate pending-session table; story 3 moves them into the session).
- **D17 (code consumption API and reuse detection for story 3).** `UPDATE oauth_codes SET used_at
  = now() WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING ...`; on 0
  rows one follow-up `SELECT` distinguishes `{:error, {:reused, row}}` (row with `used_at` set)
  from `{:error, :invalid}` (unknown or expired-unused). Story 3 revokes the session derived from
  a reused code by `(user_id, device_id, client_id)` of the returned row (OAuth sessions are per
  device); no extra column is needed now. Used/expired codes are kept 24 h after expiry for
  reuse detection, then purged.
- **D18 (provisioning at the callback).** `TokenValidator.validate/4` + profile upsert + post-login
  provisioning (personal room / auto-join, `is_new`) run at the IdP callback, exactly like the
  legacy `POST /login` (`HttpPublic.provision_and_respond/6`), because `is_new` is only known on
  the first `validate` call. Device registration and session creation are story 3. A deactivated
  user gets `access_denied`. Story 3 must re-check `is_active` at the token endpoint (the code
  lives at most 60 s).
- **D19 (rate limits, abuse bounds).** `RateLimit.take/3` buckets (node-local, abuse control
  only): `{"oauth_authorize", ip}` 600/h per IP (rate 10/min, burst 600) charged by EVERY
  authorize request BEFORE any DB lookup; `{"oauth_callback", ip}` 600/h per IP charged by every
  `o2.`-tagged callback before the DB consume. Over the limit => HTML `429` page +
  `Retry-After` (no redirect: the client is not validated yet). Live `oauth_authz_requests` rows
  are capped at 10 000 inside the INSERT (`INSERT ... SELECT ... WHERE (SELECT count(*) ...
  WHERE expires_at > now()) < 10000`, same soft-cap idiom as `ClientStore.register/1`, mirrors
  `SsoStore` `@max_state_entries`); above => `temporarily_unavailable` error redirect (client is
  validated by then). No global bucket (one shared bucket behind nginx would block all logins;
  the hard gate in follow-ups.md item 1 still applies).
- **D20 (no audit rows, logging only).** Matrix logins are not written to `audit_log` today (only
  `admin_login`), so authorize/callback outcomes are not either (consistent, no PII in the
  compliance log). INFO log lines carry only `client_id`, outcome/error code and, after the
  callback, `user_id` + `device_id`; never `code`, `state`, `code_challenge`, redirect targets,
  IdP tokens, `nonce` or cookie values. The DEBUG query-string capture of `RequestLogger` masks ALL
  values (keeps only parameter names) for `/oauth2/authorize` and
  `/_matrix/client/v3/login/sso/redirect/oidc` (route-aware, AC15). `code_challenge` and the
  client `state` are not added to the generic credential key lists (not secrets, but masked on
  these two paths anyway).
- **D21 (no stubs).** `/oauth2/token` and `/oauth2/revoke` keep falling through to the router's
  `404`. No placeholder that pretends to work.
- **D22 (module boundaries, ADR-020).** The IdP leg stays in the Matrix domain (it owns the one
  IdP client): `Nebu.Matrix` gains three public functions that wrap `SsoLogin` (AC6/AC7). The
  OAuth domain owns requests and codes. Matrix -> OAuth calls go only through `Nebu.OAuth`
  (`oauth_idp_state?/1`, `handle_idp_callback/1`); OAuth -> Matrix only through `Nebu.Matrix`.
  No module calls the other domain's internals.
- **D23 (`openid` and the client `nonce`, oracle gate 2026-10-10, story-3 blocker).**
  matrix-js-sdk 41.3.0 requests `openid` plus the UNSTABLE Matrix prefix and sends a `nonce`, and
  it validates an id_token in the token response (`iss` = Nebu issuer, `aud` = client_id,
  `nonce`). Story 2 therefore: (a) keeps `openid` in the granted scope when requested (stored
  `scope` = `"openid <prefix>api:* <prefix>device:<id>"`) and stores `openid_requested = true`;
  (b) validates the client `nonce` like `state` (D14: at most 2048 bytes, valid UTF-8, no
  `\p{Cc}`; violation => `invalid_request`), stores it in `oauth_authz_requests.client_nonce`
  and carries it into `oauth_codes.client_nonce`; it is NEVER sent to the IdP. Absent nonce =>
  NULL. **Story 3 MUST issue a Nebu-signed id_token (`iss` = Nebu issuer, `aud` = client_id,
  `nonce` = stored client nonce, `sub`) whenever `openid_requested` is true**; ADR-033 records
  this obligation.

## Acceptance Criteria

### AC1 — Endpoint, enablement, methods

- `GET /oauth2/authorize` is forwarded from `Nebu.Web.Router` to `Nebu.OAuth.Http`
  (`action: :authorize`), placed next to `forward "/oauth2/register"`.
- `Config.get/0` state `:disabled` or `:unknown`, or an issuer that `Metadata.normalize_issuer/1`
  rejects => `404 {"errcode":"M_UNRECOGNIZED",...}` (the existing `unrecognized/1`, JSON). No
  DB access and NO rate-limit token: the disabled/unknown/invalid-issuer path does not charge
  D19's authorize bucket (decided by the ATDD test review, pinned by a test).
- Any method other than `GET` (and the CORSPlug-handled `OPTIONS`) while enabled => `405` with
  `Allow: GET` and an HTML page (AC12). Sub-paths (`/oauth2/authorize/x`) => `404 M_UNRECOGNIZED`
  (existing `path_info: [_ | _]` clause).
- `/oauth2/token` and `/oauth2/revoke` still answer the router's plain `404` (regression test).

### AC2 — Validation BEFORE the redirect URI is trusted (HTML page, never a redirect)

Order (RFC 6749 4.1.2.1; each step answered with an AC12 page, status in brackets):

1. Rate limit (D19) => `429` page + `Retry-After`.
2. Raw query parse (D13): malformed encoding, duplicated/array `client_id` or `redirect_uri` =>
   `400` page `invalid_request`.
3. `client_id` missing, longer than 256 bytes, or unknown (`ClientStore.get_by_client_id/1`
   returns `nil`) => `400` page `unknown_client`. DB unavailable => `503` page
   `data-error="unavailable"`. The lookup used here must be error-aware
   (`{:ok, row | nil} | {:error, _}`; `get_by_client_id/1` maps errors to `nil` and is not enough).
4. `redirect_uri` missing, longer than 2048 bytes, or not matching (AC3) => `400` page
   `invalid_redirect_uri`. The requested URI is never rendered.
5. Client `status = 'pending'` => `403` page `client_pending` ("waiting for approval by your
   administrator"); `status = 'rejected'` => `403` page `client_rejected`. Rendered client data:
   ONLY the `client_uri` host, escaped, labelled unverified (no client name, no redirect URI).
6. Defensive: registered `response_types` lacks `code` or `grant_types` lacks
   `authorization_code` => `unauthorized_client` error REDIRECT (the URI is trusted by now).

### AC3 — Redirect URI matching

- Exact, byte-for-byte string equality with one entry of the approved row's
  `metadata["redirect_uris"]`. No normalization (case, trailing slash, default port, percent
  encoding all count).
- Loopback exception (RFC 8252 7.3, Matrix "any port is accepted at flow time"): when a
  registered URI matches `\Ahttp://(localhost|127\.0\.0\.1|\[::1\])([/?]|\z)` (case as stored),
  a requested `http://<same host>:<port><same rest>` with `port` 1..65535 (decimal, no leading
  `+`/sign) matches it; the requested URI WITH its port is what is stored and later redirected
  to. `localhost` and `127.0.0.1` are NOT interchangeable. A loopback port on a non-loopback
  registered URI never matches.

### AC4 — Redirect-able validation errors and the error redirect shape

After AC2/AC3 passed, every validation failure is a `302` to the validated redirect URI with
`error`, a fixed ASCII `error_description` (never client/IdP-supplied text), `state` (when
present and valid, D14) and `iss` (D15), in the response mode of AC5. Never `errcode`, never
`error_uri`. Mapping:

| Condition | `error` |
|---|---|
| `response_type` missing | `invalid_request` |
| `response_type` present but not exactly `code` | `unsupported_response_type` |
| `code_challenge` missing, or not 43 chars of `[A-Za-z0-9_-]` | `invalid_request` |
| `code_challenge_method` missing or not exactly `S256` (incl. `plain`) | `invalid_request` |
| `response_mode` present but not `query`/`fragment` (D10; `query` with https is VALID) | `invalid_request` |
| client `nonce` invalid (D23) | `invalid_request` |
| `prompt=none` (D11) | `login_required` |
| `prompt` list combining `none` with another value | `invalid_request` |
| `state` invalid (D14) | `invalid_request` (state omitted) |
| any duplicated parameter other than `client_id`/`redirect_uri` (D13) | `invalid_request` |
| scope errors (AC4b) | `invalid_scope` |
| live-request cap reached / DB error while persisting / IdP discovery or config unavailable | `temporarily_unavailable` |
| unexpected internal error | `server_error` |

Order of checks: `response_type`, PKCE, `response_mode`, `state`, `nonce`, duplicates,
`scope`, `prompt`; first failure wins. `code_challenge` of 64+ characters (js-sdk's plain-PKCE
fallback labelled `S256`) fails the exactly-43-characters rule => `invalid_request`.

### AC4b — Scopes (both prefixes, D6-D8)

- `scope` is split on single spaces (empty tokens dropped). Prefixes:
  `urn:matrix:client:` (stable) and `urn:matrix:org.matrix.msc2967.client:` (unstable).
- `invalid_scope` when: scope missing/empty or > 2048 bytes; any token outside the RFC 6749 3.3
  charset; zero or more than one `device:` token; the device id fails D8; `api:*` missing; the
  Matrix tokens use different prefixes.
- Unknown tokens are ignored (D7); `openid` is kept (D23). Granted scope stored and later
  returned (story 3): `"[openid ]<request prefix>api:* <request prefix>device:<id>"`;
  `scope_prefix` and `openid_requested` stored separately. `api:*` required and mixed-prefix
  rejection are Nebu policy (D6/D7), not spec MUSTs.
- Pure module with unit tests for both prefixes, at least: the EXACT js-sdk 41.3.0 string
  `openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj`
  (together with a client `nonce` parameter), the Dart SDK string
  `urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:ABCDEFGHIJ`,
  and the generic stable-prefix case `urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj`.

### AC5 — Response mode

- `query`: params appended to the redirect URI's query (`?` or `&` depending on an existing
  query, `URI.encode_www_form/1` per value). `fragment`: `#` + the encoded params (registered
  URIs never contain a fragment, story 1).
- An explicit `query` or `fragment` is always honoured, for every redirect URI (D10); absent
  => `fragment` for https, `query` otherwise. Parameter order `code`/`error`
  (+`error_description`), then `state`, then `iss`.
- `iss` is byte-for-byte the `issuer` value served by `auth_metadata` (same
  `Metadata.normalize_issuer/1` result).

### AC6 — Delegation to the IdP

On a fully valid request:

1. Generate the IdP-leg `state` (D2), IdP PKCE verifier/challenge and nonce with the SAME
   helpers as `SsoLogin` (`pkce_verifier/0`, `pkce_challenge/1`, `random_token/1`), and the
   binding value (D4).
2. `Nebu.OAuth.AuthzStore.insert/1`: one row in `oauth_authz_requests` with `expires_at = now()
   + 600 s`, capped (D19). Fields in AC10.
3. Build the IdP URL through the NEW public `Nebu.Matrix.idp_authorize_location(conn, params)`
   which delegates to a function extracted from `SsoLogin.do_redirect/3`, so the legacy and the
   OAuth path produce the IdP request in ONE place: `response_type=code`, `client_id` (the one
   IdP client, ADR-022), `redirect_uri = callback_url(conn)`, `scope =
   Nebu.Web.OidcScopes.resolve_scope(:matrix)` (OIDC Scopes Law: `openid` + configured extras +
   `offline_access` iff `matrix_oidc_refresh_mode` is offline; NOTHING hardcoded), `state`,
   `nonce`, `code_challenge`, `code_challenge_method=S256`, `prompt` per D11, and always `max_age=0` (review cycle 2, Kassandra F-2; the client's own
   `max_age` is never forwarded). Legacy `/sso/redirect` output stays identical (regression tests).
4. Respond `302 Location: <IdP authorize URL>` with the D4 cookie and the AC13 headers.
- Insert failure, cap reached, IdP config/discovery failure (`{:error, _}` from
  `idp_authorize_location`) => `temporarily_unavailable` error redirect to the client (AC4),
  nothing persisted on the discovery failure (discovery happens before the insert, or the row is
  deleted again). `SecretBox.encrypt/1` raising (no internal secret) while encrypting the IdP
  verifier => `server_error` error redirect, nothing persisted, never a 500 (Trap 9).

### AC7 — IdP callback (shared path, D1)

`SsoLogin.callback/1` FIRST checks `Nebu.OAuth.oauth_idp_state?(conn.query_params["state"])`
(pure prefix check, D2). If true it returns `Nebu.OAuth.handle_idp_callback(conn)` and nothing
of the legacy branch runs (no `SsoStore.pop_state`, no Matrix error JSON); legacy and UIA states
behave exactly as before. `handle_idp_callback/1`:

1. Callback rate limit (D19) => `429` page.
2. OAuth not `:enabled` or issuer invalid => `404` HTML page `unavailable` (nothing consumed
   except the cookie).
3. Malformed tagged state => `400` page `invalid_state`.
4. `AuthzStore.consume(state)` (atomic DELETE ... RETURNING): no row, or `live = false`
   (expired) => `400` page `invalid_state` ("This sign-in link has expired or was already
   used. Start the login again from your app."). A second callback with the same state (replay)
   gets the same page.
5. Binding cookie missing/mismatch (D4) => `400` page `invalid_state`; the row stays consumed.
6. From here on the client redirect URI comes ONLY from the consumed row (open-redirect safe:
   no query parameter of the callback is ever used as a redirect target).
7. Client re-check (error-aware lookup): a client that is gone => `400` page `invalid_state` (in
   practice the FK cascade already removed the request row in step 4); a client that is not
   `approved` => `403` page `client_rejected` (defensive branch only: 000040's guard makes a
   decision final, so an approved client cannot become rejected). Never a redirect.
8. IdP error response (`error` present): mapped redirect to the client: `access_denied` ->
   `access_denied`, `temporarily_unavailable` -> `temporarily_unavailable`, everything else ->
   `server_error`; the IdP's `error_description`/`error_uri` are never forwarded or logged.
9. Missing `code` (and no `error`) => `server_error` redirect.
10. `Nebu.Matrix.idp_complete_login(conn, code, verifier, nonce)` (new public function wrapping a
    function extracted from `SsoLogin.do_callback/3`: `exchange/4` with the decrypted verifier,
    `OidcPlug.verify_token/2`, `check_nonce/2`) =>
    `{:ok, %{claims:, idp_refresh_token:}}`; IdP unreachable / 5xx / discovery failure =>
    `temporarily_unavailable` redirect; verification or nonce failure => `access_denied` redirect.
    Verifier decrypt failure => `server_error` redirect.
11. `Nebu.Matrix.provision_login_user(claims)` (new, D18; `UserId.from_claims/2` with
    `:server_name`, `TokenValidator.validate/4`, `Profile.DB.upsert_profile/3`,
    `EventDispatcher.Server.run_post_login_provisioning/2`) => `{:ok, %{user_id:, auth_time:}}`;
    `{:error, :deactivated}` => `access_denied` ("This account has been deactivated.");
    other error => `server_error` redirect.
12. Issue the code (AC8). The legacy branch's 403/400 Matrix JSON responses are never used for
    OAuth-tagged states.

### AC8 — Authorization code issuance

- `Nebu.OAuth.CodeStore.insert/1` stores `code_hash`, `client_id`, `redirect_uri` (exact,
  incl. loopback port), `code_challenge`, `device_id`, `user_id`, `scope`, `scope_prefix`,
  `response_mode`, `openid_requested`, `client_nonce`, `idp_rt_enc` (`SecretBox.encrypt/1` of
  the IdP refresh token or NULL), `auth_time`, `expires_at = now() + 60 s`. The plaintext code exists only in the redirect.
- `SecretBox.encrypt/1` raising (no internal secret) or the insert failing => `server_error`
  redirect, no code.
- Success => `302` to the redirect URI with `code`, `state` (if the request had one), `iss`, in
  the stored response mode (AC5), with AC13 headers; the D4 cookie is cleared.
- `oauth_clients.last_used_at` is NOT touched in story 2 (story 3, on token issuance).

### AC9 — Code store API for story 3 (no token endpoint)

Exposed through `Nebu.OAuth` (public API, ADR-020):

- `consume_authorization_code(code) :: {:ok, map} | {:error, :invalid} | {:error, {:reused,
  map}} | {:error, :storage}` per D17 (the map has every AC8 column, `idp_rt_enc` still
  encrypted). Exactly ONE of N concurrent consumers of the same code gets `{:ok, _}` (atomic
  UPDATE, cluster safe), the others `{:error, {:reused, _}}`.
- `purge_expired_flow_state() :: {:ok, %{authz_requests: n, codes: m}} | {:error, term}`:
  deletes `oauth_authz_requests` with `expires_at < now()` and `oauth_codes` with `expires_at <
  now() - interval '24 hours'`, batched (1000 rows, max 20 batches per table and run, `FOR
  UPDATE SKIP LOCKED`, the `ClientStore.purge_expired_pending/1` pattern).

### AC10 — Migration 000041 (new file; 000040 untouched)

`server/priv/migrations/000041_oauth_authz_requests_and_codes.up.sql` / `.down.sql`:

```sql
CREATE TABLE oauth_authz_requests (
  state_hash            TEXT PRIMARY KEY,               -- sha256 hex of the IdP-leg state (D2)
  client_id             TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
  redirect_uri          TEXT NOT NULL,                  -- exact requested URI (loopback port incl.)
  code_challenge        TEXT NOT NULL,
  device_id             TEXT NOT NULL,
  scope                 TEXT NOT NULL,                  -- granted scope, request prefix
  scope_prefix          TEXT NOT NULL,
  response_mode         TEXT NOT NULL,
  client_state          TEXT,                           -- the client's `state`, NULL when absent
  client_nonce          TEXT,                           -- the client's `nonce` (D23), NULL when absent
  openid_requested      BOOLEAN NOT NULL DEFAULT false, -- `openid` in the requested scope (D23)
  idp_code_verifier_enc TEXT NOT NULL,                  -- SecretBox
  idp_nonce             TEXT NOT NULL,
  browser_binding_hash  TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at            TIMESTAMPTZ NOT NULL
);
CREATE TABLE oauth_codes (
  code_hash      TEXT PRIMARY KEY,
  client_id      TEXT NOT NULL REFERENCES oauth_clients (client_id) ON DELETE CASCADE,
  redirect_uri   TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  device_id      TEXT NOT NULL,
  user_id        TEXT NOT NULL,
  scope          TEXT NOT NULL,
  scope_prefix   TEXT NOT NULL,
  response_mode  TEXT NOT NULL,
  client_nonce   TEXT,
  openid_requested BOOLEAN NOT NULL DEFAULT false,
  idp_rt_enc     TEXT,
  auth_time      TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at     TIMESTAMPTZ NOT NULL,
  used_at        TIMESTAMPTZ
);
```

- Named CHECKs: `scope_prefix IN ('urn:matrix:client:', 'urn:matrix:org.matrix.msc2967.client:')`,
  `response_mode IN ('query','fragment')` (both tables); `oauth_authz_requests.expires_at <=
  created_at + interval '10 minutes'`; `oauth_codes.expires_at <= created_at + interval '60
  seconds'`.
- Indexes on `expires_at` of both tables.
- `GRANT SELECT, INSERT, DELETE ON oauth_authz_requests TO nebu_app` (no UPDATE: rows are
  consumed by DELETE); `GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_codes TO nebu_app`.
- `ENABLE` + `FORCE ROW LEVEL SECURITY` on both (FORCE: the runtime role owns the tables in the
  single-role dev setup, see 000040 section 3). Policies: `oauth_authz_requests`: SELECT true,
  INSERT true, DELETE true, NO UPDATE policy (updates match no row). `oauth_codes`: SELECT true,
  INSERT `WITH CHECK (used_at IS NULL)`, UPDATE true, DELETE `USING (expires_at < now() - interval
  '24 hours')`.
- Trigger `oauth_codes_guard` (`BEFORE UPDATE`): refuses any change of a column other than
  `used_at`, and refuses `used_at` changes unless `OLD.used_at IS NULL AND NEW.used_at IS NOT
  NULL` (a used code can never be "unused" again).
- `.down.sql` drops both tables and the trigger function. Header comment documents D2/D3/D16/D17
  and that the FK cascade only ever fires for purged PENDING clients (which never have flows).

### AC11 — Purge worker

`Nebu.Workers.OAuthFlowPurgeWorker` (queue `oauth_cleanup`, `max_attempts: 3`), cron
`"*/10 * * * *"` in `config/config.exs` next to the existing `OAuthPendingPurgeWorker` entry;
calls `Nebu.OAuth.purge_expired_flow_state/0`; logs counts only. Correctness never depends on
it (consume checks `expires_at`).

### AC12 — Accessible HTML pages

One renderer `Nebu.OAuth.Pages` for all non-redirect outcomes (`unavailable` covers both the
`503` of AC2.3 and the `404` of AC7.2; `unknown_client`,
`invalid_redirect_uri`, `invalid_request`, `client_pending`, `client_rejected`, `invalid_state`,
`unavailable`, `rate_limited`, `method_not_allowed`, `server_error`):

- `<!doctype html><html lang="en">`, `<meta charset="utf-8">`, viewport meta, a specific
  `<title>`, one `<main>` with one `<h1>`, plain-language explanation plus "What you can do"
  (contact the administrator / start the login again from the app). No color-only meaning, no
  images, no links to client-controlled URLs, no `<script>`, no forms.
- Hooks for e2e: `<main data-page="oauth-error" data-error="<code>">`.
- Every interpolated value passes `Plug.HTML.html_escape/1` (only the `client_uri` host on the
  pending/rejected pages; nothing else from the request).
- Headers: `Content-Type: text/html; charset=utf-8`, `Content-Security-Policy: default-src
  'none'; style-src 'sha256-<hash of the one inline style block>'; base-uri 'none'; form-action
  'none'; frame-ancestors 'none'` (hash computed at compile time), `X-Frame-Options: DENY` plus
  the AC13 headers.

### AC13 — Response headers on authorize and OAuth callback responses

All responses (302s and pages): `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy:
no-referrer`, `X-Content-Type-Options: nosniff` (router, already). NO CORS: the
`access-control-*` headers that the global `CORSPlug` put on the conn are deleted
(`delete_resp_header/2`) on every GET response of these two flows (browser navigation, spec
section 10 "CORS only on metadata/token/register/revoke"). The legacy SSO callback keeps its
current headers.

### AC14 — Rate limiting

D19 buckets via `Nebu.Web.Plugs.RateLimit.take/3` with tuple keys (never colliding with the
plug's IP-string keys or story 1's `oauth_register*` keys); seams `:rate_limit_clock_fn` and
`NEBU_RATE_LIMIT_DISABLED` apply. 429 page carries `Retry-After`.

### AC15 — Logging and redaction (No Sensitive Data law)

- `RequestLogger` (DEBUG query-string capture): for `conn.request_path` equal to
  `/oauth2/authorize` or `/_matrix/client/v3/login/sso/redirect/oidc` the logged query string
  keeps parameter names only (`client_id=***&redirect_uri=***...`), via a route-aware branch
  in `redacted_query_string/1` (like the existing send/state route awareness).
- `PayloadRedactor`: `code`/`code_verifier` already redacted (story 1); a test proves the
  callback query `code=...&state=o2....` and an authorize query are masked on these paths.
- No `Logger` call in the new code contains a code, state, nonce, verifier, challenge, cookie,
  redirect URI with params, id_token or IdP refresh token (log-capture tests).

### AC16 — Metadata stays truthful

- `Nebu.OAuth.Metadata.build/1` adds `"authorization_response_iss_parameter_supported" => true`.
- `response_modes_supported` stays `["query","fragment"]`, `code_challenge_methods_supported`
  `["S256"]`; `prompt_values_supported` stays ABSENT (D11). The story-1 "no unknown fields"
  test's allowed set gains the new key.

### AC17 — Documentation

- ADR-033: new section "Authorization endpoint, IdP delegation and codes (story 2)" with D1-D23
  (esp. the callback deviation D1, D3 cluster safety, D4, D10, D17, and D23: story 3 MUST issue a
  Nebu id_token with `iss` = Nebu issuer, `aud` = client_id, `nonce` when `openid` was
  requested), and the "Gate items" section updated: item 1 (trusted proxy) also throttles
  authorize/callback.
- `docs/matrix-api-scope.md`: rows for `GET /oauth2/authorize` and for the shared callback's
  OAuth branch; `/oauth2/token` / `/oauth2/revoke` "not implemented (stories 3/4)".
- `docs/stories/oauth-broker/follow-ups.md`: append (a) story 2 confirms the trusted-proxy hard
  gate, (b) no consent screen (D5) for review, (c) I-1 note: authorize is live but token/revoke
  still 404, so `oauth_enabled` must stay false until story 4, (d) `prompt_values_supported`
  decision (not advertised), (e) story 3 obligation: Nebu id_token when `openid` was requested
  (D23).
- arc42 (`docs/architecture/08-concepts.md` OAuth section, `09-decisions.md` ADR-033 row text)
  is updated by the arc42 step; the Dev Notes list the hooks.

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- Unit `oauth_authorize_scope_test.exs`: both prefixes, echo prefix, mixed prefixes, 0/2/duplicate
  device tokens, missing `api:*`, unknown tokens dropped, charset boundaries (`!`, `#`, `[`,
  `]`, `~` accepted; space, `"`, `\`, DEL, non-ASCII rejected), 255/256-byte device ids.
- Unit `oauth_authorize_request_test.exs`: raw parsing (duplicates, `x[]=`, malformed `%`),
  redirect matching incl. loopback ports (`:0`, `:65536`, `:+80`, `localhost` vs `127.0.0.1`,
  `[::1]:8080`), PKCE format, response-mode rules, state limits, error mapping table of AC4.
- Integration `oauth_authorize_http_test.exs`: pages (status, `data-error`, headers, no
  `Location`), error redirects (query/fragment, `iss`, `state`, no `errcode`), rate limit, CORS
  absence with an `Origin` header, disabled/unknown/invalid-issuer 404, 405, token/revoke 404.
- Integration `oauth_idp_delegation_test.exs`: row persisted (hash key, encrypted verifier, no
  plaintext state), IdP URL params (scope law with/without extras, offline/online,
  `prompt=create` with/without IdP support), cookie attributes, cap, discovery failure.
- Integration `oauth_idp_callback_test.exs`: full flow with `:oidc_metadata_override`,
  `:oidc_jwks`, `:matrix_sso_token_override` (nonce read from the IdP `Location` URL), error
  mapping, replay, expiry, cookie mismatch, client rejected meanwhile, deactivated user
  (`:session_manager, :validator_module` seam), IdP RT encrypted in the code row, legacy and UIA
  callbacks unchanged.
- Integration `oauth_code_store_test.exs`: consume once, concurrent consume (N tasks, exactly one
  `:ok`), reuse => `{:reused, row}`, expired => `:invalid`, purge boundaries.
- Integration `server/test/nebu/migration/000041_oauth_authz_codes_test.exs`: tables, CHECKs,
  RLS/policies, guard trigger, runtime-role DELETE of an unexpired code refused, down/up.
- Extended: `oauth_metadata_test.exs` (AC16), `oauth_payload_redaction_test.exs` (AC15),
  `sso_login_test.exs` / `matrix_sso_test.exs` (legacy byte-identical IdP URL, legacy state still
  on the SsoStore path), `adr_033_test.exs` (new section present).

### Gherkin (UI: public HTML pages + flow to the client)

`e2e/features/oauth/oauth-authorize.feature`, steps `e2e/step-definitions/oauth/oauth-authorize.steps.ts`
(tag `@oauth-authorize`; After hook resets `oauth_enabled`/`oauth_issuer_url` and deletes the
feature's `e2e-oauth-authz-*` clients through the privileged DB role, like
`oauth-client-approvals.feature`).

```gherkin
Feature: OAuth 2.0 authorization endpoint (broker)

  Background:
    Given OAuth is enabled with an https issuer
    And an approved native client "e2e-oauth-authz-native" with redirect URI "http://localhost/cb"

  @oauth-authorize @ac2
  Scenario: Pending client sees an accessible notice and is not redirected
    Given a pending web client "e2e-oauth-authz-pending"
    When the browser opens the authorize URL of "e2e-oauth-authz-pending" with valid parameters
    Then the page has the heading "This app is waiting for approval"
    And the page is marked as OAuth error "client_pending"
    And the browser stays on the Nebu authorize URL
    And the page contains no script element
    And the response has a Content-Security-Policy starting with "default-src 'none'"

  @oauth-authorize @ac2
  Scenario: Rejected client sees an accessible notice and is not redirected
    Given a rejected web client "e2e-oauth-authz-rejected"
    When the browser opens the authorize URL of "e2e-oauth-authz-rejected" with valid parameters
    Then the page is marked as OAuth error "client_rejected"
    And the browser stays on the Nebu authorize URL

  @oauth-authorize @ac2
  Scenario: Unknown client gets an error page
    When the browser opens the authorize URL with client_id "does-not-exist"
    Then the page is marked as OAuth error "unknown_client"
    And the browser stays on the Nebu authorize URL

  @oauth-authorize @ac2 @ac3
  Scenario: Mismatching redirect URI gets an error page, never a redirect
    When the browser opens the authorize URL of "e2e-oauth-authz-native" with redirect URI "https://evil.example.com/cb"
    Then the page is marked as OAuth error "invalid_redirect_uri"
    And the page does not contain "evil.example.com"

  @oauth-authorize @ac4
  Scenario: Missing PKCE is reported to the client as invalid_request with iss
    When the browser opens the authorize URL of "e2e-oauth-authz-native" on port 53682 without code_challenge
    Then the browser is redirected to "http://localhost:53682/cb"
    And the redirect query has "error" = "invalid_request"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer
    And the redirect query has no "errcode"

  @oauth-authorize @ac6 @ac7 @ac8
  Scenario: Happy path through the IdP ends at the client with a code
    When the browser opens the authorize URL of "e2e-oauth-authz-native" on port 53682 with scope prefix "urn:matrix:org.matrix.msc2967.client:"
    And the user signs in at the IdP
    Then the browser is redirected to "http://localhost:53682/cb"
    And the redirect query has a "code"
    And the redirect query has the request's "state"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-authorize @ac5 @ac8
  Scenario: Element-Web-shaped request (https redirect URI, response_mode=query) succeeds in the query
    Given an approved web client "e2e-oauth-authz-web" with redirect URI "https://app.e2e.example/cb"
    When the browser opens the authorize URL of "e2e-oauth-authz-web" with response_mode "query", scope "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:AbCdEfGhIj" and a nonce
    And the user signs in at the IdP
    Then the browser is redirected to "https://app.e2e.example/cb"
    And the redirect query has a "code"
    And the redirect query has "iss" = the Nebu issuer

  @oauth-authorize @ac7
  Scenario: Replaying the IdP callback shows an expired-link page
    Given a completed authorization for "e2e-oauth-authz-native"
    When the browser opens the same IdP callback URL again
    Then the page is marked as OAuth error "invalid_state"
```

The happy path intercepts the loopback navigation with `page.route("http://localhost:53682/**")`
(nothing listens there). Playwright cannot run in the isolated env; `tsc --noEmit` and `bddgen`
must be clean (story-1 precedent).

## Must be test-covered (spec MUSTs, RFC 6749 4.1.2.1 / RFC 9207 / RFC 9700)

1. Unknown `client_id` => page, no redirect (RFC 6749 4.1.2.1).
2. Missing, mismatching or not exactly matching `redirect_uri` => page, no redirect; the URI is
   not reflected (RFC 6749 4.1.2.1, RFC 9700 4.1.3 exact match).
3. Pending and rejected clients at authorize => notice page, no redirect (spec section 4); a client
   deleted during the flow => `invalid_state` page at the callback (FK cascade).
4. Loopback port: any port accepted for registered `http://localhost|127.0.0.1|[::1]` URIs; host
   not interchangeable; non-loopback URI with an extra port rejected (RFC 8252 7.3).
5. `response_type` missing => `invalid_request`; other value => `unsupported_response_type`.
6. PKCE: missing challenge, missing method, `plain`, malformed challenge => `invalid_request`
   (RFC 7636, RFC 9700 2.1.1, Matrix MUST S256).
7. Explicit `response_mode` always honoured for every redirect URI: https + `query` => SUCCESS
   in the query (Element Web regression); `fragment` honoured; absent => fragment for https,
   query for loopback/private-use; other values => `invalid_request`.
8. Scope: exactly one `device:` (0 and 2 rejected), both prefixes accepted, the response echoes
   the REQUEST's prefix, mixed prefixes rejected, `api:*` required, unknown tokens ignored.
9. Device id charset `%x21 / %x23-5B / %x5D-7E` (RFC 6749 3.3), `"`/`\`/space/non-ASCII rejected.
10. Every error redirect has `error`, `state` (if sent), `iss`; never `errcode` (js-sdk checks it).
11. Success redirect has `code`, `state`, `iss` (RFC 9207); metadata has
    `authorization_response_iss_parameter_supported: true`.
12. Duplicated parameters rejected (RFC 6749 3.1); unknown parameters (`action`, `login_hint`, ...)
    ignored. The client `nonce` is NOT unknown: it is validated and stored (D23).
13. IdP state: single use (replay => page, also with the original binding cookie), expired =>
    page, unknown/forged `o2.` => page, deleted client => page, never a redirect; binding cookie
    required (RFC 9700 4.7 CSRF) and cleared on every callback outcome.
14. Open-redirect safety: callback redirect target comes only from the stored request.
15. IdP `error=access_denied` => client `access_denied` with `state` + `iss`; IdP description not
    forwarded.
16. `id_token` verified via `OidcPlug.verify_token/2` and nonce checked; failure => `access_denied`.
17. Deactivated user => `access_denied`, no code row.
18. Code: >= 128 bit, only the hash stored (no plaintext in any column), TTL <= 60 s, single use,
    concurrent consumption yields exactly one winner, reuse is detectable (RFC 9700 4.2.1 /
    RFC 6749 4.1.2).
19. IdP refresh token stored only encrypted (SecretBox), never in logs.
20. OIDC Scopes Law: IdP scope = `openid` + configured extras (+ `offline_access` iff offline mode).
21. No secrets in logs: `code`, `state`, verifier, nonce, id_token, IdP RT absent from captured
    logs; DEBUG query string masked on both paths.
22. `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, no `Access-Control-Allow-Origin`,
    CSP `default-src 'none'` on pages.
23. OAuth disabled/unknown/invalid issuer => `404 M_UNRECOGNIZED`; `/oauth2/token|revoke` 404.
24. Legacy `/sso/redirect` IdP URL unchanged; legacy and UIA callbacks unchanged.
25. Migration: RLS forbids deleting unexpired codes and un-using a used code; authz rows not
    updatable; down/up round trip.
26. Every error code (`invalid_request`, `unsupported_response_type`, `invalid_scope`,
    `access_denied`, `login_required`, `server_error`, `temporarily_unavailable`,
    `unauthorized_client`) in BOTH query and fragment form, each with `state` + `iss`, no `errcode`.
27. The exact js-sdk 41.3.0 scope string (`openid` + unstable prefix) plus a client `nonce` is
    accepted; `openid_requested` and `client_nonce` land in the authz row and the code row; the
    nonce is absent from the IdP URL; invalid nonce => `invalid_request`.
28. `iss` byte-equal to the `issuer` of `GET /_matrix/client/v1/auth_metadata`.
29. `code_challenge` of 64+ characters (and 42/44) => `invalid_request`.
30. Device-scope count 0, 2 distinct, 2 identical => `invalid_scope`; device id 255 bytes
    accepted, 256 bytes rejected.
31. `prompt=none` => `login_required` redirect, no IdP redirect, no row persisted.

## Dev Notes

### Files to create

- `server/lib/nebu/oauth/authorize.ex` — flow orchestration: `handle_authorize(conn)`,
  `handle_idp_callback(conn)`; builds the client redirects (AC4/AC5/AC8).
- `server/lib/nebu/oauth/authorize_request.ex` — pure: raw query parse, AC2-AC4 validation,
  redirect matching (AC3), response-mode rules, error table.
- `server/lib/nebu/oauth/scope.ex` — pure: AC4b parser, device-id validator (D8), prefixes.
- `server/lib/nebu/oauth/authz_store.ex` — inline SQL (ADR-018): `insert/1` (with cap),
  `consume/1` (DELETE ... RETURNING), `purge_expired/0`; repo seam `:nebu_http, :oauth_repo`
  (same as `ClientStore.repo/0`).
- `server/lib/nebu/oauth/code_store.ex` — inline SQL: `insert/1`, `consume/1` (D17),
  `purge_expired/0`, `hash/1`.
- `server/lib/nebu/oauth/pages.ex` — AC12 renderer.
- `server/lib/nebu/workers/oauth_flow_purge_worker.ex` — AC11.
- `server/priv/migrations/000041_oauth_authz_requests_and_codes.{up,down}.sql` — AC10.
- Tests listed under Acceptance Tests; e2e feature + steps; extend `e2e/fixtures/db.ts` with
  approved/rejected client inserts (pending insert + UPDATE, the 000040 invariant) and
  `server_config` toggles.

### Files to modify

- `e2e/playwright.config.ts` — the admin-ui project also loads `features/oauth/**/*.feature`
  (done by ATDD; no other project picks up `e2e/features/oauth/`).
- `server/lib/nebu/web/router.ex` — `forward "/oauth2/authorize", to: Nebu.OAuth.Http,
  init_opts: [action: :authorize]` next to `/oauth2/register` (before `forward "/_matrix"`,
  order irrelevant for `/oauth2`). Preserve everything else.
- `server/lib/nebu/oauth/http.ex` — `call(conn, :authorize)` delegating to
  `Nebu.OAuth.Authorize`; reuse `unrecognized/1`, `ip_string/1`. Moduledoc: new endpoint.
- `server/lib/nebu/oauth.ex` — public API: `oauth_idp_state?/1`, `handle_idp_callback/1`,
  `consume_authorization_code/1`, `purge_expired_flow_state/0`; moduledoc names the new Matrix
  -> OAuth entry points.
- `server/lib/nebu/oauth/metadata.ex` — AC16.
- `server/lib/nebu/matrix/sso_login.ex` — (a) at the top of `callback/1`: tagged-state branch
  (AC7) BEFORE the `idp_error` clause (that clause pops `SsoStore` and answers Matrix JSON
  403 — must never run for `o2.` states); (b) extract the IdP-URL builder from `do_redirect/3`
  (`base_params` map) into one function used by legacy, UIA and OAuth; legacy keeps
  `prompt=login`, UIA keeps `max_age=0`; (c) extract `exchange/4` + `verify_token` +
  `check_nonce/2` into one function used by `do_callback/3` and the OAuth path; (d) a
  provisioning function mirroring `HttpPublic.provision_and_respond/6`'s provisioning half
  (D18). Keep `callback_url/1`, `oidc_config/0`, `discover/2` as the single sources. Existing
  seams `:matrix_sso_token_override` (0/1-arity), `:sso_bootstrap_reader`,
  `:oidc_metadata_override` must keep working for both paths.
- `server/lib/nebu/matrix.ex` — public API: `idp_authorize_location/2`,
  `idp_complete_login/4`, `provision_login_user/1` (ADR-020: OAuth must not call
  `SsoLogin`/`TokenValidator` directly; `provision_identity/2` deliberately skips
  post-login provisioning and is NOT the right function).
- `server/lib/nebu/web/plugs/request_logger.ex` — route-aware masking in
  `redacted_query_string/1` (AC15).
- `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex` — moduledoc: authorize/callback
  masking note (no new keys, D20).
- `server/config/config.exs` — cron entry for `OAuthFlowPurgeWorker` (AC11).
- Tests: `oauth_metadata_test.exs` allowed-key set (line ~136), `release_test.exs` if it pins
  the migration count, `oauth_test_support.exs` (add helpers ONLY there: `authorize_url/2`,
  `approved_client!/1`, `follow_idp/1`, `pkce_pair/0`).
- Docs per AC17.

### What must be preserved

- Legacy `m.login.sso`: `/sso/redirect` IdP URL params byte-identical (prompt=login, no max_age),
  `SsoStore` state handling, loginToken mint, UIA completion page, Matrix JSON errors.
- Story 1 behaviour: DCR, metadata, discovery plug, admin approval, all story-1 tests.
- `HttpPublic.provision_and_respond/6` unchanged (D18 duplicates its provisioning half on purpose
  rather than refactoring the legacy login; keep them in sync, a test pins identical user rows).

### Traps

1. **Callback branch order.** `SsoLogin.callback/1` checks `error` first and pops `SsoStore`;
   the tag check must come before that, and an `o2.` state without code/error must not fall into
   `redirect(conn)` (it would answer `400 M_MISSING_PARAM redirectUrl`).
2. **UIA precedent ≠ storage precedent.** The UIA tag lives in `SsoStore` (node-local); the OAuth
   flow must not (D3).
3. **IdP redirect URI identity.** The IdP token exchange must send the SAME `redirect_uri` as
   the IdP authorize request: both come from `callback_url/1` of the respective conn, so the
   authorize request's and the callback's `Host`/`X-Forwarded-Proto` must agree (same as legacy).
4. **`conn.query_params` is last-wins and builds lists from `x[]=`** — parse `conn.query_string`
   with `URI.query_decoder/1` (D13); `URI.decode_www_form/1` raises on bad `%`.
5. **CORSPlug runs globally** and already set `access-control-allow-origin` before dispatch;
   delete it in the response (AC13), do not reconfigure CORSPlug.
6. **RateLimit table seams.** Use tuple keys `{"oauth_authorize", ip}` / `{"oauth_callback",
   ip}`; tests use `T.reset_rate_limits/0` + `:rate_limit_clock_fn` and `T.unique_ip/0`
   (the ETS table is shared and never evicted, follow-ups I-3).
7. **Config seam.** `T.enable_oauth/1` installs `:oauth_config_source`; authorize must also call
   `Metadata.normalize_issuer/1` for `iss` (dev's `http://localhost:8008` issuer is NOT https =>
   404; e2e must set an https `oauth_issuer_url`).
8. **Nonce in tests.** The OAuth nonce is not in `SsoStore` (no `peek_state`); tests read it from
   the IdP `Location` URL's `nonce` param and mint a matching id_token (`:oidc_jwks`).
9. **`SecretBox` raises without an internal secret** (`:admin_secret_at_rest` in tests, see
   `sso_login_test.exs`); catch at the call sites (AC6/AC8 => `server_error` error redirect),
   never 500.
10. **FK + FORCE RLS.** RI checks bypass RLS; the cascade from `oauth_clients` purge can only hit
    pending clients, which never have rows here (authorize requires `approved`).
11. **jsonb vs text.** All new columns are `TEXT`; reject NUL/control chars in `state` before the
    insert (D14) or PostgreSQL returns SQLSTATE 22 (map class 22 to `invalid_request`, never 500).
12. **000040 is committed**: never edit it; RLS/grant idioms are copied, not changed.
13. **Story-1 test helpers have random-suffix names** because decided rows survive across runs;
    new fixtures must follow (`web_body/1` precedent).
14. **`oauth_enabled` stays false** in every committed config; tests use the seam.

### Architecture compliance

ADR-018 inline SQL in the two stores; ADR-020 public-API-only cross-domain calls (D22), no
node-local state for correctness (D3, atomic SQL); ADR-022 the one IdP client, no new env; ADR-033
broker model, https issuer rule; OIDC Scopes Law (only `OidcScopes`); No Sensitive Data law (AC15).

### Testing commands (isolated env, see the epic brief)

`quick.sh "mix test --include integration test/nebu/oauth test/nebu/migration/000041_oauth_authz_codes_test.exs test/nebu/matrix/sso_login_test.exs test/nebu/matrix/matrix_sso_test.exs"`;
full gate via `integration.sh` (after `cleanup.sh` when 000041 changed in place); e2e only
`tsc --noEmit` + `bddgen --tags "@oauth-authorize or @oauth-approvals"` (a whole-suite `bddgen`
already fails on a pre-existing duplicate step `the operator clicks {string}` in
`admin/admin-media-overview.steps.ts` / `admin/bootstrap.steps.ts`; logged in follow-ups.md).

### Docs to touch (arc42 step and dev)

ADR-033 (AC17), `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`,
`docs/architecture/08-concepts.md` ("OAuth 2.0 Authorization Server" section: authorize flow,
shared callback, flow tables), `docs/architecture/09-decisions.md` (ADR-033 row mentions story 2).

### Story-3 handover (D23)

The code row carries `openid_requested` and `client_nonce`. Story 3 must issue a Nebu-signed
id_token (`iss` = Nebu issuer, `aud` = client_id, `nonce`, `sub`) when `openid_requested` is
true, because matrix-js-sdk validates it; this needs a Nebu signing key + `jwks_uri` decision
in story 3. Also correct `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md` (it says the
js-sdk sends stable scopes; 41.3.0 sends `openid` + the unstable prefix) in the docs step.

### Out of scope

Token endpoint, `matrix_sessions` columns, device registration, session creation, `last_used_at`
(story 3); revocation/logout (4); `oauth_aware_preferred`, legacy `action` (5); account page,
consent/`m.oauth` (6); `/versions` (9); all `follow-ups.md` items (trusted proxy, bulk reject,
public suffix, per-host cap).

## Open questions

Resolved by the oracle gate (2026-10-10): `prompt_values_supported` not advertised (D11); D10
corrected (explicit `response_mode` always honoured, Element Web sends `query`); no consent
screen accepted, follow-up note (D5); no minimum device-id length (D8). No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev-story, non-interactive, 2026-10-10).

### Debug Log References

- Isolated env (`quick.sh`): `mix test --include integration --warnings-as-errors test/nebu/oauth
  test/nebu/migration` => 712/712 green (was 434/712 after ATDD).
- Targeted regression: `test/nebu/web`, `release_test.exs`, `test/nebu/workers`, all
  `test/nebu/matrix/sso*` / `matrix_sso_test.exs` / `device_lifecycle_login_test.exs` /
  `login_refresh_test.exs` => 607/608, the one failure is the known `MatrixSsoTest` loginToken
  test (known.txt).
- Full quick run `mix test --include integration`: see Completion Notes.

### Completion Notes List

- **Pure modules.** `Nebu.OAuth.Scope` (AC4b, D6-D8, D23), `Nebu.OAuth.AuthorizeRequest` (raw
  query parse D13, AC3 matching incl. loopback ports, D10 default mode, AC4 checks in AC4 order,
  AC5 redirect building, plus `error_context/2` for the defensive `unauthorized_client` redirect),
  `Nebu.OAuth.Pages` (AC12/AC13, CSP hash of the one inline style computed at compile time,
  `put_flow_headers/1` shared with the redirects).
- **Flow.** `Nebu.OAuth.Authorize` (`handle_authorize/2`, `handle_idp_callback/1`, `live_issuer/0`)
  in the AC2/AC4/AC6/AC7/AC8 order of the story. `Nebu.OAuth.Http` routes `:authorize` (also a
  non-preflight OPTIONS goes to the 405 path, no CORS); the disabled / unknown / invalid-issuer path
  answers `404 M_UNRECOGNIZED` before any rate-limit token or DB access.
- **Stores (ADR-018 inline SQL, cluster safe).** `Nebu.OAuth.AuthzStore` (capped INSERT ...
  SELECT, atomic DELETE ... RETURNING with `live`, batched purge), `Nebu.OAuth.CodeStore` (D17
  UPDATE ... RETURNING + one follow-up SELECT for reuse detection, batched `FOR UPDATE SKIP
  LOCKED` purge), `ClientStore.fetch_by_client_id/1` (error-aware lookup, AC2.3;
  `get_by_client_id/1` now delegates to it).
- **Matrix side (D22).** `SsoLogin`: the `o2.` branch is the FIRST `cond` clause of `callback/1`;
  the IdP-URL builder (`idp_authorize_url/4`) is shared by legacy, UIA (`max_age=0`) and OAuth;
  `complete_idp_login/4` (exchange + `OidcPlug.verify_token/2` + nonce) is shared by the legacy
  callback and the OAuth leg; `provision_login_user/1` mirrors the provisioning half of
  `HttpPublic.provision_and_respond/6` (left unchanged). `Nebu.Matrix` gains
  `idp_authorize_location/2` (returns `location` + the IdP verifier + nonce, generated with the
  SsoLogin helpers, nothing stored in `SsoStore`), `idp_complete_login/4` (errors classified to
  `:idp_unavailable` / `:idp_rejected`, details never returned) and `provision_login_user/1`.
- **Migration 000041** (new; 000040 untouched), worker `Nebu.Workers.OAuthFlowPurgeWorker` + cron
  `*/10`, metadata `authorization_response_iss_parameter_supported: true`, RequestLogger
  names-only query masking on the two paths (AC15), PayloadRedactor moduledoc note.
- **Docs (AC17).** ADR-033 section "Authorization endpoint, IdP delegation and codes (story 2)"
  with D1-D23 + gate item 1 extended to the authorize/callback buckets + the I-1 note corrected;
  `docs/matrix-api-scope.md` rows (authorize, callback OAuth branch, token/revoke not
  implemented); `follow-ups.md` story-2 section (a)-(g); oracle reference
  `oauth2-api.md` corrected (js-sdk 41.3.0 sends `openid` + the unstable prefix + `nonce`,
  `response_mode=query`; both response modes must be supported). arc42 hooks: see "Docs to touch".
- **Deviations / decisions taken by dev:**
  1. `AuthzStore.purge_expired/0` does NOT use `FOR UPDATE SKIP LOCKED`: the runtime role has
     neither an UPDATE grant nor an UPDATE policy on `oauth_authz_requests` (AC10), and a row lock
     needs both. Concurrent purgers are still safe (a DELETE skips rows another purger deleted; a
     deadlock between two purgers is treated as "the other node does it"). The code purge keeps
     `FOR UPDATE SKIP LOCKED`.
  2. `JsonBody` skips `/oauth2/authorize` (no body; `Plug.Parsers` would otherwise fetch the query
     params and raise on a malformed percent-encoding before the D13 page could be rendered).
  3. `URI.decode_www_form/1` (Elixir 1.20) does not reject `%zz`; `parse_query/1` refuses every
     `%` not followed by two hex digits up front.
  4. D4 cookie clearing: cleared on every callback outcome (incl. the disabled 404, per the story
     text "nothing consumed except the cookie") EXCEPT the 429 (nothing is consumed there, so the
     same browser can retry).
  5. IdP token endpoint 4xx (e.g. `invalid_grant`) maps to `access_denied`, 5xx / unreachable /
     discovery or config missing to `temporarily_unavailable`.
  6. An empty `state` / `nonce` value counts as absent (not echoed, stored NULL).
  7. `server/mix.exs`: `oauth_test_support.exs` added to `test_ignore_filters` (story 1 missed it;
     with Elixir 1.20 the "file does not match test_load_filters" warning aborted every
     `--warnings-as-errors` run over `test/nebu/oauth` after all tests passed).
- **Tests changed (minimally, story-conform):** `oauth_idp_callback_test.exs`
  (a) the code-TTL assertion compared a `Decimal` (PostgreSQL 14+ `extract(epoch ...)` returns
  numeric) with an integer, which can never be true in Erlang term order => `::float8` cast;
  (b) the D18 user-shape test derived the user ids from `sub` only although
  `UserId.from_claims/2` prefers the configured claim / `preferred_username` / `name`, and used
  fixed name/email values that collide with users persisted from earlier runs => every identity
  claim is now unique per user and the ids are derived from the full claims. The assertion itself
  (equal user-row shape) is unchanged.
- `oauth_enabled` stays default off; nothing enables it. `last_used_at` is not touched.
- Known open point (test-review m1, unchanged): the "code INSERT fails => server_error" path is only
  covered indirectly; the rescue / error branch is at the call site (`issue_code/5`).

### Review cycle 1 (code review + UX gate advisories)

- MINOR 1: `Authorize.client_id/1` rejects any `\p{Cc}` => 400 `unknown_client` page (no Postgres 22021,
  no error log). Test written first (red), then fixed.
- MINOR 2: `RequestLogger` normalizes the request path (trailing / doubled slashes) before the
  names-only match, so `/oauth2/authorize/` and the callback with a trailing slash are masked.
  Test written first (red), then fixed.
- INFO 5: `Nebu.Matrix.idp_complete_login/4` no longer maps a raise to `:idp_rejected`: it is
  infrastructure trouble => `:idp_unavailable` (client gets `temporarily_unavailable`), only the
  exception type is logged. INFO 3: DoS property (request consumed before the binding check)
  noted in ADR-033. INFO 10 (CodeStore.insert failure test): not feasible without a store-level
  seam (the request consume uses the same repo), left as in test-review m1.
- UX advisories: (1) `strong{overflow-wrap:anywhere}` (CSS hash is compile-time), (3) unknown page
  code normalized to `server_error`, (4) "sign-in" wording ("Start signing in again from your app.";
  `oauth_pages_test.exs` text updated accordingly), (8) `method_not_allowed` text "This page cannot
  be opened this way. Start signing in from your app.", (9) e2e: heading + next-step assertions for
  pending / rejected / unknown client / replay, and a getComputedStyle step proving the inline
  style applies under the CSP. `tsc --noEmit` clean, `bddgen --tags "@oauth-authorize or
  @oauth-approvals"` exit 0 (run on a copy with node_modules in the scratchpad).
- Verification: `test/nebu/oauth`, `test/nebu/migration`, `test/nebu/web/plugs`, the sso tests =>
  853/853 with `--warnings-as-errors`.

### Review cycle 2 (Kassandra F-2)

- The OAuth IdP leg now ALWAYS sends `max_age=0` (also when `prompt=create` is forwarded instead of
  `prompt=login`); the client's own `max_age` is still never forwarded. Legacy `/sso/redirect`
  (no `max_age`) and the UIA fallback (`max_age=0`) are unchanged. Tests first (red): the exact
  key-set test of the OAuth leg was updated deliberately (legacy keys + `max_age`), plus the
  `prompt=create` and "unknown parameters not forwarded" tests. ADR-033 D5 and the D5/D11 story
  decisions updated. NOT done (follow-ups h, i, j): `auth_time` freshness check, cookie prefix,
  per-source cap.

### File List

New:
- `server/lib/nebu/oauth/authorize.ex`
- `server/lib/nebu/oauth/authorize_request.ex`
- `server/lib/nebu/oauth/scope.ex`
- `server/lib/nebu/oauth/authz_store.ex`
- `server/lib/nebu/oauth/code_store.ex`
- `server/lib/nebu/oauth/pages.ex`
- `server/lib/nebu/workers/oauth_flow_purge_worker.ex`
- `server/priv/migrations/000041_oauth_authz_requests_and_codes.up.sql`
- `server/priv/migrations/000041_oauth_authz_requests_and_codes.down.sql`

Modified:
- `server/lib/nebu/oauth.ex`, `server/lib/nebu/oauth/http.ex`, `server/lib/nebu/oauth/metadata.ex`,
  `server/lib/nebu/oauth/client_store.ex`
- `server/lib/nebu/matrix.ex`, `server/lib/nebu/matrix/sso_login.ex`
- `server/lib/nebu/web/router.ex`, `server/lib/nebu/web/plugs/json_body.ex`,
  `server/lib/nebu/web/plugs/request_logger.ex`,
  `server/lib/nebu/web/plugs/request_logger/payload_redactor.ex`
- `server/config/config.exs`, `server/mix.exs`
- `server/test/nebu/oauth/oauth_idp_callback_test.exs` (two test defects, see Completion Notes)
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/matrix-api-scope.md`,
  `docs/stories/oauth-broker/follow-ups.md`, `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`
- this story file (Dev Agent Record, Change Log, status)

## Change Log

- **2026-10-10:** Story created (create-story, non-interactive) for story 2 of epic oauth-broker:
  authorize endpoint, IdP delegation via the shared callback, authorization codes, migration
  000041, decisions D1-D22.
- **2026-10-10 (oracle-amended):** D10 corrected (query and fragment for every redirect URI,
  explicit mode honoured; Element Web uses query with https); D23 added (`openid` kept in the
  granted scope, client `nonce` + `openid_requested` stored in 000041 tables, story-3 id_token
  obligation); D6/D7 labelled Nebu policy; js-sdk 41.3.0 scope examples (`openid` + unstable
  prefix); `prompt=none` => `login_required`; must-test items 26-31; open questions resolved.
- **2026-10-10 (ATDD):** red-phase ExUnit + Gherkin tests written; section "ATDD Decisions (story 2)"
  appended (pinned APIs, seams, 5 story contradictions with proposed text).
- **2026-10-10 (dev-story):** implementation (authorize endpoint, IdP delegation through the shared
  callback, codes, migration 000041, purge worker, logging, docs AC17); 712/712 OAuth + migration
  tests green; two test defects fixed in `oauth_idp_callback_test.exs`; status `review`.
- **2026-10-10 (review cycle 1):** MINOR 1/2, INFO 3/5, UX advisories 1/3/4/8/9 fixed (see "Review
  cycle 1").
- **2026-10-10 (review cycle 2):** Kassandra F-2: `max_age=0` on the OAuth IdP leg; D5/D11 text.

## ATDD Decisions (story 2)

Written by the ATDD role (2026-10-10, red phase: 272 of 287 new ExUnit tests fail, 15 regression
guards are green; all 418 story-1 tests stay green; `--warnings-as-errors` compiles). The dev MUST
implement against these names; changing one means changing the tests in the same commit.

### Test files

`server/test/nebu/oauth/`: `oauth_authorize_scope_test.exs` (AC4b/D6-D8/D23, unit),
`oauth_authorize_request_test.exs` (AC3/AC4/AC5/D10/D13/D14, unit), `oauth_pages_test.exs`
(AC12/AC13, unit), `oauth_authorize_http_test.exs` (AC1-AC5/AC13/AC14), `oauth_idp_delegation_test.exs`
(AC6/AC10 rows/D2-D4/D11/D19), `oauth_idp_callback_test.exs` (AC7/AC8/AC13-AC15/D22, legacy + UIA
regressions), `oauth_code_store_test.exs` (AC9/AC11), `oauth_request_logger_redaction_test.exs`
(AC15); extended: `oauth_metadata_test.exs` (AC16), `adr_033_test.exs` (AC17 incl.
`matrix-api-scope.md` / `follow-ups.md`), `oauth_test_support.exs` (helpers below).
`server/test/nebu/migration/000041_oauth_authz_codes_test.exs` (AC10). E2E:
`e2e/features/oauth/oauth-authorize.feature`, `e2e/step-definitions/oauth/oauth-authorize.steps.ts`,
`e2e/fixtures/db.ts` (`insertOAuthClient`, `clearOAuthClientsByIdPrefix`, `deleteServerConfig`),
`e2e/playwright.config.ts` (admin-ui project also loads `features/oauth/**`). The legacy
`/sso/redirect` / callback regressions live in the two IdP test files (they need the OAuth
fixtures); `sso_login_test.exs` / `matrix_sso_test.exs` are unchanged and green.

### Pinned module APIs (pure modules, no I/O)

- `Nebu.OAuth.Scope.parse(scope | nil) :: {:ok, %{scope:, prefix:, device_id:, openid: boolean}} | {:error, :invalid_scope}`;
  `valid_device_id?/1`; `prefixes/0` (stable + unstable). Granted scope order: `openid` (if
  requested), `<p>api:*`, `<p>device:<id>`, independent of the request order.
- `Nebu.OAuth.AuthorizeRequest`: `parse_query/1 :: {:ok, [{name, value}]} | {:error, :malformed}`
  (raw, order + duplicates kept, `x[]` stays the literal name, `+` = space);
  `match_redirect_uri(requested, registered) :: {:ok, requested} | :error`;
  `default_response_mode/1` (`"fragment"` for https, else `"query"`);
  `validate(pairs, trusted_redirect_uri) :: {:ok, %{response_mode:, code_challenge:, state:, nonce:, scope:, scope_prefix:, device_id:, openid_requested:, prompt: "create" | nil}} | {:error, error_code, %{state: valid_state | nil, response_mode: mode}}`
  (only the AC4 checks, in AC4 order); `redirect_location(uri, mode, [{k, v}]) :: String.t()`
  (AC5 encoding with `URI.encode_www_form/1`, `?`/`&`/`#`).
- `Nebu.OAuth.Pages.send_page(conn, status, error_code, opts)` with opts `client_host:`,
  `retry_after:`, `allow:`; one `<main data-page="oauth-error" data-error=...>`, one `<h1>`, a
  "What you can do" section, at most ONE inline `<style>` whose sha256 is in `style-src`, no
  `<script>/<form>/<img>/<iframe>`, no `href="http..."`. Exact texts the tests rely on: pending
  `<h1>` "This app is waiting for approval" (+ the word "unverified" next to the host);
  invalid_state "This sign-in link has expired or was already used." + "Start the login again from
  your app."; deactivated `error_description` "This account has been deactivated.".
- Public API (ADR-020): `Nebu.OAuth.oauth_idp_state?/1` (pure `"o2."` prefix, `false` for
  non-binaries), `handle_idp_callback/1`, `consume_authorization_code/1` (result map with ATOM keys
  = the AC8 columns, `idp_rt_enc` still encrypted; `{:error, :invalid}` also for non-binary input;
  `{:error, :storage}` when the repo is unavailable), `purge_expired_flow_state/0`
  (`{:ok, %{authz_requests: n, codes: m}}`); `Nebu.Matrix.idp_authorize_location/2`,
  `idp_complete_login/4`, `provision_login_user/1`. `sso_login.ex` references only
  `Nebu.OAuth.oauth_idp_state?` / `Nebu.OAuth.handle_idp_callback`; `lib/nebu/oauth/*.ex` never
  names `Nebu.Matrix.{SsoLogin,SsoStore,TokenValidator,OidcPlug,Profile.DB,EventDispatcher,UserId}`
  (static test). `lib/nebu/oauth/authorize.ex` must exist.
- `Nebu.Workers.OAuthFlowPurgeWorker` (`__opts__`: queue `oauth_cleanup`, `max_attempts: 3`),
  crontab entry exactly `{"*/10 * * * *", Nebu.Workers.OAuthFlowPurgeWorker}`.

### Seams and formats

- Config: `T.enable_oauth/1` (story-1 `:oauth_config_source`). Repo: `:nebu_http, :oauth_repo`
  (NoSuchRepo) is honoured by the client lookup, `AuthzStore`, `CodeStore` and the purge.
- IdP stub = existing SsoLogin seams (`T.setup_idp!/1`): `:oidc_metadata_override` (may carry
  `prompt_values_supported`), `:sso_bootstrap_reader`, `:matrix_sso_token_override` (0-arity,
  `{:ok, id_token, idp_rt | nil}` or `{:error, {:token_endpoint_unreachable | :token_endpoint_status, _}}`
  => `temporarily_unavailable`), `:oidc_jwks`, `:matrix_oidc_extra_scopes_reader`,
  `:matrix_oidc_refresh_mode_reader`, `:server_name` (`test.local`), `:admin_secret_at_rest`;
  provisioning via `:session_manager, :validator_module` (`T.DeactivatedValidator`,
  `T.FailingValidator` => `server_error`). A discovery document without `authorization_endpoint`
  and a missing `oidc_client_id` both mean `temporarily_unavailable` with nothing persisted.
- Rate limit: `RateLimit.take({"oauth_authorize" | "oauth_callback", "a.b.c.d"}, 10, 600)` with the
  IP string of `:inet.ntoa/1`; tests pre-drain the bucket under the frozen `:rate_limit_clock_fn`.
  The authorize bucket is charged before the missing-`client_id` / DB checks; legacy
  (non-`o2.`) callbacks are never charged to the callback bucket.
- Hashes: lowercase hex SHA-256 (`state_hash`, `code_hash`, `browser_binding_hash`). Cookie name
  `nebu_oa_<first 16 hex of state_hash>`, value 43 chars base64url, cleared with `max-age=0` on a
  success redirect. Code 43 chars base64url. IdP nonce >= 32 bytes. The tests read the binding
  cookie from `set-cookie` / `resp_cookies`, the IdP `state`/`nonce` from the IdP `Location`.
- Callback while OAuth is disabled / issuer invalid: `404` page `unavailable` and the request row
  is NOT consumed (a later callback with the same state + cookie still succeeds).
- Logging (AC15): the DEBUG `query_string` of both paths is `name=***...` (`***REDACTED***` as the
  mask also satisfies the tests); the IdP's `error_description`/`error_uri` never reach the log.
- Migration test assumptions: named CHECKs may be inline or `ALTER TABLE ... ADD CONSTRAINT`
  (exactly one `scope_prefix` and one `response_mode` CHECK per table); an UPDATE of
  `oauth_authz_requests` by `nebu_app` may raise `permission denied` (owner = migrate role) or
  match 0 rows (single-role owner, no policy); the guard trigger is checked behaviourally; the
  down/up round trip runs `.down.sql` then `.up.sql` (simple protocol) on the privileged role
  inside a rolled-back transaction (`T.with_privileged_conn/1`), so `.down.sql` must not touch
  `oauth_clients` and both files must be transaction-safe (no `BEGIN`/`COMMIT`, no `CONCURRENTLY`).

### Contradictions / gaps in the story text (decisions taken, story text to adjust)

1. Gherkin location: `e2e/features/oauth/` is in NO Playwright project. ATDD widened the admin-ui
   project (`playwright.config.ts`, `features: ['features/admin/**', 'features/oauth/**']`);
   "Files to modify" should list `e2e/playwright.config.ts`.
2. AC7.7 (client "no longer approved" => `403 client_rejected`) is unreachable through the
   database: 000040's guard makes a decision final and deleting the client cascades the request
   row away (=> `invalid_state`). Tested: the deletion case. Proposed text: "7. Client re-check:
   a client that is gone or not `approved` => page (`invalid_state` for a deleted client via the
   FK cascade, `403 client_rejected` as defensive branch)".
3. AC2.3 "DB unavailable => 503 page": `ClientStore.get_by_client_id/1` returns `nil` on errors
   (=> would be `unknown_client`); the dev needs an error-aware lookup. The story names no page code
   for the 503: ATDD pins `unavailable`.
4. AC6/Trap 9: SecretBox failure at AUTHORIZE time is now pinned to `server_error` (story text
   updated after the test review). At the callback it is `server_error` as well (AC7.10/AC8).
5. Whole-suite `bddgen` already fails on this branch (duplicate step `the operator clicks {string}`
   in `admin/admin-media-overview.steps.ts` and `admin/bootstrap.steps.ts`, not story-2 related);
   the new feature was verified with `bddgen --tags "@oauth-authorize or @oauth-approvals"` (8
   scenarios generated) and `tsc --noEmit` is clean.
6. (test review) AC1: the disabled/unknown/invalid-issuer 404 path does NOT charge the authorize
   bucket (story text updated, test added).

### Test-review follow-up (2026-10-10)

Added: UIA fallback regression (IdP URL keeps `max_age=0` + `prompt=login`, 32-hex SsoStore state,
UIA-tagged callback still completes the stage), D3 crash/restart (the SsoStore is killed between
authorize and callback, the flow still completes), `server_error` pinned for SecretBox at
authorize, `prompt=none` with broken IdP discovery/config still `login_required` (IdP never
contacted), D18 user-row shape equal to a legacy `POST /login` user, cookie cleared on
mismatch/expired/IdP-error paths, IdP authorization code + client redirect URI in the log-capture
secret list, success `iss` == `auth_metadata` issuer, a "10 000 expired rows do not count" cap
test, the disabled-path bucket test; e2e: own anchored redirect step (exact origin + path), the
replay scenario restores the original binding cookie (fails only because the row is consumed),
web-first consent wait.

PARTIAL (m1): AC8 "`SecretBox.encrypt/1` raises / code INSERT fails => `server_error`, no code" is
covered only through the verifier-decrypt failure at the callback (same key, so encrypt cannot fail
alone) and the NoSuchRepo seam cannot be scoped to the code INSERT (the request consume uses the
same repo first). A store-level seam would be needed; the dev should keep the rescue at the call
site (code review checks it).
