---
story_id: oauth-legacy-coexistence
title: "Legacy coexistence: OAuth-aware login flows, SSO `action`, UIA delineation for OAuth sessions, auth_api coexistence audit"
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

Story 5 of epic `oauth-broker` (spec section 13 row 5; spec sections 2, 3a, 8; section 14 decisions 6
and 7). Both authentication APIs run fully in parallel (decision 6): every `matrix_sessions` row
carries `auth_api = legacy | oauth` (story 3, T2) and a session only ever uses the API it was issued
by (spec 8, "mutually incompatible"). This story makes that parallel operation complete and
correct:

1. **OAuth-aware compatibility (Matrix CS API v1.18 "OAuth 2.0 aware clients", server MUSTs).**
   `GET /_matrix/client/v3/login` advertises `oauth_aware_preferred: true` (stable, v1.18) AND
   `org.matrix.msc3824.delegated_oidc_compatibility: true` (unstable, read by matrix-js-sdk 41.3.0)
   on the `m.login.sso` flow object, ONLY while OAuth is offered (`Config` state `:enabled` and a
   valid issuer). Disabled, invalid issuer or unreadable config => both keys absent (the response
   stays byte-identical to today).
2. **`action` at the legacy SSO redirect** (`GET /login/sso/redirect[/{idpId}]`, also the unstable
   `org.matrix.msc3824.action` that matrix-js-sdk sends): `login` => today's IdP URL byte for byte;
   `register` => `prompt=create` toward the IdP only when the IdP advertises it, else identical to
   `login`; anything else ignored. Honoured only while OAuth is offered (C5).
3. **UIA delineation (spec 8 table, decision 4).** `DELETE /devices/{id}` and `POST /delete_devices`
   refuse OAuth-session callers with `403 M_FORBIDDEN` before any lookup or UIA session (UIA is not
   compatible with the OAuth API; device deletion for OAuth sessions is the account page, story 6).
   Legacy callers keep the `m.login.sso` UIA flow unchanged. The UIA SSO completion no longer
   refreshes `auth_time` of OAuth rows. `/account/deactivate`, `/account/password`,
   `/account/3pid/*` stay absent (verified, now pinned by tests).
4. **Coexistence audit of every token/device touchpoint** (table in Dev Notes) and the real gaps it
   found: raw-JWT key upload into an OAuth device (C11), non-atomic device teardown racing an OAuth
   rotation (C12), the best-effort JWT kill-switch turning a bound JWT into a working unbound one
   (Kassandra story-3 I-6, C13). Legacy semantics stay unchanged (decision 6): the legacy `/logout`
   user-wide wipe (gate item (r)) and legacy `/login` device-id reuse (follow-up story-3 (f)) are
   recorded in the audit but NOT changed here (they stay open follow-ups).
5. **Docs:** ADR-033 coexistence section (incl. what happens when one API is deprecated),
   `docs/matrix-api-scope.md`, follow-ups (new items u-x).

`oauth_enabled` stays `false` by default and nothing in this story enables it. Out of scope: the
account-management page and the `m.oauth` UIA for `/keys/device_signing/upload` (story 6),
`/versions` (story 9), revoke / OAuth `/logout` / `/logout/all` (story 4, being implemented: its
ACs and R-decisions are treated as existing code), every follow-ups.md gate item (1-4, h-q, r, s,
t) and follow-up story-3 (f).

Authoritative sources: `_bmad-output/planning-artifacts/oauth-broker-spec.md` sections 2, 3a, 8, 13,
14; `docs/architecture/adr/ADR-033-authorization-server-broker-model.md` (D1-D23, T1-T33; story 4
adds R1-R24); story 3 `docs/stories/oauth-broker/oauth-token-endpoint.md` (T25-T27, Dev Agent
Record); story 4 `docs/stories/oauth-broker/oauth-token-revocation-logout.md` (R2, R15-R19, Trap 1);
`docs/stories/oauth-broker/follow-ups.md` (story-3 (d); (f) and story-4 (r) stay open); Kassandra
`security-reports/oauth-token-endpoint-security-review-2026-10-10.md` (I-5, I-6); Matrix CS API
v1.18 "OAuth 2.0 aware clients" (client + server behaviour), "OAuth 2.0 API" warning box (UIA not
compatible, `m.oauth` only on `/keys/device_signing/upload`), "Relationship between access tokens
and devices", `GET /login`, `GET /login/sso/redirect`, `POST /logout`; MSC3824; matrix-js-sdk
41.3.0 `src/@types/auth.ts` (`OAUTH_AWARE_PREFERRED_FLOW_FIELD`), `src/client.ts`
(`SSO_ACTION_PARAM`, `getSsoLoginUrl`); `_bmad/memory/nebu-agent-oracle/references/oauth2-api.md`
(checklist 9, 11).

## Story

As a **user of a legacy-only Matrix client AND of an OAuth-capable client on the same Nebu
instance**,
I want both kinds of clients to keep working side by side, OAuth-aware clients to see that Nebu
prefers SSO and to be able to ask for registration, and every device operation to be correct no
matter which API created the device,
so that signing out, deleting a device or logging in again in one client never leaves a session of
the other API alive by accident or ends it by accident.

## Decisions

Prefix `C` (coexistence story), so the IDs never collide with D1-D23 (story 2), T1-T33 (story 3)
and R1-R24 (story 4) in ADR-033. ADR-033 gets a new section with C1-C20 (AC10).

- **C1 (module boundaries, ADR-020).** The Matrix domain learns whether OAuth is offered ONLY
  through a new facade function `Nebu.OAuth.oauth_aware?/0 :: boolean()` (`@doc` + `@spec`, never
  raises, rescue => `false`): `true` iff `Nebu.OAuth.Config.get/0` reports `state: :enabled` AND
  `Nebu.OAuth.Metadata.normalize_issuer(config.issuer_url)` is `{:ok, _}` (the SAME predicate as
  `Nebu.OAuth.Http.live_state/0`'s `{:live, _}` branch; extract one private helper in the OAuth
  domain, do not copy the condition). `Nebu.Matrix.HttpPublic` and `Nebu.Matrix.SsoLogin` call
  `Nebu.OAuth.oauth_aware?/0`, never `Nebu.OAuth.Config` / `Metadata`. The web layer
  (`Nebu.Web.Router.Protected`) and `Nebu.Admin` reach the atomic device teardown only through the
  new facade function `Nebu.Matrix.end_device_session/2` (C12).
- **C2 (when the OAuth-aware flags are advertised: fail closed).** `oauth_aware?/0 == true` =>
  advertised; `:disabled`, `:enabled` with a missing / non-https / path-carrying issuer, `:unknown`
  (unreadable `server_config`) or an exception => NOT advertised. `GET /login` never answers 503
  because of the OAuth config (login flows are needed by legacy clients in every state); it simply
  omits the keys. Rationale: spec v1.18 makes the flag a duty of a homeserver that "supports OAuth
  2.0 aware clients" and requires the OAuth 2.0 API to be supported; advertising it while
  `auth_metadata` answers 404 would push OAuth-aware clients to an API that is not there. Decision 6
  ("OAuth-aware compatibility stays always active") applies to the time OAuth is offered; while it is
  off Nebu is exactly the pre-broker server (spec 14 "OAuth aus = Zustand von heute"). One
  uncached `server_config` read per `GET /login` (ADR-020: no node-local switch state; I-12 caching
  remains a follow-up note). Oracle O5: the flags are present IFF `GET /_matrix/client/v1/auth_metadata`
  answers 200 (same predicate, evaluated per request, so a runtime toggle of `oauth_enabled` flips both
  on the next request); the `m.login.sso` flow itself is ALWAYS offered (OAuth-aware MUST). Advertising
  the v1.18 field while `/versions` still reports < v1.15 has no spec conflict (oracle). Story 9 does
  not change this rule; it flips `/versions` on the SAME predicate `Nebu.OAuth.oauth_aware?/0` (see
  "Handover to story 9"). `account_management_uri` (OAuth-aware SHOULD) stays absent from the metadata
  until story 6 (consistent with gate item (w)).
- **C3 (field placement and shape).** On the `m.login.sso` flow object ONLY (Matrix v1.18 `GET
  /login` response: `oauth_aware_preferred` is a property of the flow, meaningful for `type:
  m.login.sso`; MSC3824's unstable name sits at the same place; matrix-js-sdk 41.3.0 `ISSOFlow`
  declares both `[OAUTH_AWARE_PREFERRED_FLOW_FIELD.name]` = `org.matrix.msc3824.delegated_oidc_compatibility`
  and `.altName` = `oauth_aware_preferred` on the flow). Both keys with the JSON boolean `true`, never
  `false` (absent when not advertised, so the disabled response is byte-identical to today). The
  `m.login.token` flow, `identity_providers` (`id: "oidc"`, configured display name, `icon: null`)
  and the flow order are unchanged. No `unstable_features` entry (spec 3a: MSC3824 is not one).
- **C4 (`action` parsing).** Read from `conn.query_params`: the stable `action`, else the unstable
  `org.matrix.msc3824.action` (matrix-js-sdk sends both with the same value). Only the exact
  binary values `"login"` and `"register"` count (case-sensitive); absent, empty, any other string,
  a map/list (`action[]=`), or a value > 32 bytes is IGNORED (treated as absent; never a 4xx: the
  spec only requires support for the two values, and a failing redirect would break login for a
  forward-looking client). When both are present and differ, the stable one wins (also when the
  stable one is invalid and the unstable valid: invalid stable => absent => the unstable one is
  used; both invalid => absent; document the exact precedence in code). A repeated key
  (`action=login&action=register`) resolves through `conn.query_params` (Plug: last value wins) to a
  pinned outcome, never a 4xx. Ignoring unknown values is conformant (oracle O2). The value is never
  logged raw and never forwarded verbatim (only the mapped `prompt`). The mapping `register` =>
  `prompt=create` is a Nebu extension (the spec only requires the parameter to be supported) and is
  recorded as such in `docs/matrix-api-scope.md`.
- **C5 (`action` mapping and gating).** Applies to `GET /login/sso/redirect` and
  `/login/sso/redirect/{idpId}` (both reach `Nebu.Matrix.SsoLogin.redirect/1`), NOT to the UIA
  fallback (`uia_fallback/1`) and NOT to the OAuth leg (story 2 D11 owns `prompt` there).
  - `oauth_aware?/0 == false`: `action` is ignored entirely; the IdP URL is byte-identical to today
    for every `action` value (no extra discovery read, same parameters, same order).
  - `oauth_aware?/0 == true` and `action == "register"`: `prompt=create` replaces `prompt=login`
    IFF the IdP discovery document lists `"create"` in `prompt_values_supported` (the story-2 D11
    rule, same `discovery_doc/1` helper; `do_redirect/3` already reads the discovery document for
    `authorization_endpoint`, so this costs no extra fetch); otherwise `prompt=login` (byte-identical
    to `login`). The legacy redirect never adds `max_age` (unchanged; only the UIA fallback and the
    OAuth leg do).
  - `action == "login"` or ignored: today's URL byte for byte.
  - `prompt=create` REPLACES `prompt=login`: the URL carries exactly one `prompt` parameter (never
    `login create`).
  - Error order unchanged: a missing / rejected `redirectUrl` answers today's 400 (JSON or HTML)
    before `action` is looked at; an IdP discovery failure answers today's `503 M_UNAVAILABLE` for
    `action=register` exactly as for `login`; an arbitrary `{idpId}` behaves as today (pinned as
    measured).
  - Everything else of the legacy flow (redirectUrl allowlist, HTML error page, `SsoStore` state,
    callback, loginToken) is untouched. After an IdP self-registration the user is provisioned on
    the first `POST /login` exactly like any new user.
- **C6 (no new secrets, no raw values in logs).** `action` is not a secret, but it is
  attacker-controlled: never logged raw (the `RequestLogger` query capture of
  `/login/sso/redirect` already goes through `PayloadRedactor`; no new log line contains the raw
  value). Optional DEBUG line with the mapped outcome only (`action=register prompt=create|login`).
- **C7 (OAuth callers refused at device deletion).** `DELETE /_matrix/client/v3/devices/{id}` and
  `POST /_matrix/client/v3/delete_devices`: when `conn.assigns[:auth_api] == "oauth"` (decided at
  AUTHENTICATION time by `OidcPlug`, story 4 R15 / Trap 4; never by a lookup in the handler) the
  handler answers `403 {"errcode":"M_FORBIDDEN","error":"Device deletion is not available for OAuth
  sessions; use the account management page."}` as its FIRST step: before the IDOR guard
  `belongs_to_other_user?/2`, before body validation (`devices` missing / not a list / > 100), before
  `uia_gate/4` (no `uia_sessions` row is minted, no `auth` block is consumed). Nothing is deleted, no
  device existence is revealed (same answer for an own, a foreign and an unknown device id, also for
  the caller's own device), also with an empty or non-JSON body (the refusal does not depend on the
  parsed body). Authentication runs first: an expired / superseded OAuth access token is answered by
  `OidcPlug` with `401 M_UNKNOWN_TOKEN` + `soft_logout: true` and never reaches the refusal. The
  handlers get a code comment: Matrix v1.17 exempts application-service callers from UIA on device
  deletion; Nebu has no appservice API (epic 10), so no exception exists (oracle correction c).
  Basis: spec "The User-Interactive Authentication API is not compatible
  with the OAuth 2.0 API, so the endpoints that depend on it for authentication can't be used when
  an access token is obtained with this API"; decision 4 / spec 8 table ("abgelehnt", deletion via
  the account page `org.matrix.device_delete`, story 6; the own session ends through revocation,
  story 4). Legacy callers (opaque legacy, raw JWT) are byte-identical to today, also when they
  delete an OAuth device of the same user (story 4 R18; the teardown itself becomes atomic, C12).
- **C8 (why 403 `M_FORBIDDEN`).** The Matrix spec defines no error for "UIA endpoint called with an
  OAuth token". `401` + UIA flows is wrong (no stage an OAuth client can complete; `m.oauth` is only
  valid on `/keys/device_signing/upload`, story 6); `404/405 M_UNRECOGNIZED` is wrong for Nebu,
  because the endpoint exists and works for legacy sessions on the same server (a client could
  conclude the server lacks the endpoint). `403 M_FORBIDDEN` ("forbidden access") says "not with
  this token" and is non-retryable. OAuth-aware clients never call these endpoints for OAuth
  sessions (spec: they MUST deep-link to the account page). Oracle O1 (resolved): keep `403
  M_FORBIDDEN` (the spec defines no code; `M_UNRECOGNIZED` means "not implemented"; Synapse+MAS
  answering 404 is from memory and is a global, not per-token, behaviour).
- **C9 (UIA freshness is legacy-only).** `Nebu.Matrix.Uia.complete/2` refreshes `auth_time` via
  `MatrixSessionStore.refresh_auth_time/2`, which today updates EVERY `matrix_sessions` row of the
  user (`WHERE user_id = $1 AND revoked_at IS NULL`, no `auth_api` filter): a legacy UIA SSO
  completion would mark the user's OAuth sessions as freshly authenticated. Fix: add `AND auth_api =
  'legacy'`. The `auth_time` of OAuth rows (IdP login time, story 3) stays reserved for the story-6
  re-auth on the account page (spec 8 "`auth_time` muss auch bei OAuth-Sessions gesetzt werden").
  `caller_auth_time/1` is unreachable for OAuth callers after C7 (no change).
- **C10 (account endpoints stay absent).** Verified: `POST /account/deactivate`, `POST
  /account/password`, `GET|POST /account/3pid*`, `POST /register` are not routed (with a token they fall into
  `Nebu.Web.Router.Protected`'s `match _` => `404 M_NOT_FOUND`; without a token `OidcPlug` answers 401 first).
  Two KNOWN DEVIATIONS, recorded, not pinned as correct and not fixed here (oracle corrections a, b):
  the spec expects `404 M_UNRECOGNIZED` for an unrecognised endpoint (Nebu: `M_NOT_FOUND`, spec 3a
  recommendation), and an unauthenticated `POST /register` answers `401 M_MISSING_TOKEN` before the
  404;
  `GET /capabilities` advertises `m.change_password: false` and `m.3pid_changes: false`. This
  matches the OAuth-aware duties (clients MUST honour `m.3pid_changes`, deactivation only through the
  account page or admin). No code change; regression tests assert only the 404 STATUS (not the
  errcode) and the capability values for an OAuth caller and a legacy caller. `/keys/device_signing/upload` is unchanged for OAuth
  callers (first upload / identical re-upload 200, replacing keys `403`): the `m.oauth` challenge
  is story 6.
- **C11 (raw JWT never writes keys of an OAuth device).** Gap: an UNBOUND raw IdP JWT
  (`conn.assigns[:device_id] == nil`) can `POST /keys/upload` with `device_keys.device_id` = the id
  of the user's OAuth device: `maybe_bind_jwt_device/3` -> `DeviceBinding.put/4` silently refuses
  the binding (T25 b), but the handler then still runs `DeviceKeyStore.put_device_keys/3`,
  `store_one_time_keys/3`, `store_fallback_keys/3` for the OAuth device (identity-key overwrite of a
  device the JWT may not act as; spec 2 "OAuth sessions know only opaque Nebu tokens"). Fix:
  `DeviceBinding.put/4` returns `:ok | {:error, :oauth_device}` (`num_rows: 0` of the guarded INSERT
  => `{:error, :oauth_device}`; a DB error stays best effort `:ok`, unchanged); the `/keys/upload`
  lazy-bind branch binds FIRST and, on `{:error, :oauth_device}`, answers `403
  {"errcode":"M_FORBIDDEN","error":"device_keys device_id does not match the authenticated device"}`
  (the existing G1 text) WITHOUT any key write. Legacy `POST /login` raw-JWT branch: a refused
  binding (a concurrent OAuth issuance won the device right after the T26 take-over) => `500
  M_UNKNOWN "Login failed, please try again."` instead of returning an unusable JWT. Oracle O4
  correction: in the same raw-JWT branch a FAILED `register_device/4` (the `devices` upsert) is mapped
  to the same `500 M_UNKNOWN "Login failed, please try again."` (C13 refuses a JWT bound to a missing
  device, so returning it would cause a hard-logout loop); `register_device/4` therefore returns `:ok
  | {:error, term}` (from `DeviceKeyStore.upsert_device/3`), the opaque branch keeps ignoring it.
  Nothing else of the legacy login changes. Other callers ignore the `put/4` result as today.
- **C12 (atomic device teardown for every non-preserved deletion).** Gap: `delete_one_device/3`
  (`protected.ex`) and `Nebu.Matrix.delete_user_device/2` (admin) delete `matrix_sessions` with a
  plain `DELETE ... WHERE user_id AND device_id` WITHOUT the `devices`-row lock. A concurrent OAuth
  rotation (`OAuthSessionStore.rotate/1`, which takes that lock and INSERTs a new row) that commits
  after the DELETE's snapshot leaves the NEW row alive while the device is deleted: the "deleted"
  device keeps a working access and refresh token until `session_expires_at` (story 4 Trap 1, fixed
  there only for revoke). An attacker holding a stolen OAuth refresh token controls the timing.
  Fix: a new facade function `Nebu.Matrix.end_device_session(user_id, device_id) :: :ok | {:error,
  :unavailable}` delegating to story 4's `Nebu.Matrix.OAuthSession.end_device_session/2` (lock
  `devices` FOR UPDATE, delete every `matrix_sessions` row of the device (any `auth_api`) and the
  device tables in ONE transaction, then post-commit JWT kill-switch (C13) +
  `SessionSupervisor.destroy_session/2`). Used by: `delete_one_device/3` whenever the device is NOT
  the preserved caller device (DELETE with the fresh-login window, every non-caller device of
  `/delete_devices`) and admin `Nebu.Matrix.delete_user_device/2`. Legacy `/logout` and legacy
  `/login` are NOT changed (decision 6; gate (r), follow-up (f)). The preserved
  own-device path (a legacy caller deleting its OWN device after a fresh UIA re-auth) keeps today's
  code exactly (its credential survives by design; legacy-only by construction since an OAuth caller
  never reaches it, C7). Error mapping: `DELETE /devices/{id}` => `500 {"errcode":"M_UNKNOWN",
  "error":"Device deletion failed, please try again."}`; `/delete_devices` attempts every id and
  answers that 500 when any failed (the other ids are still deleted, the failed one stays intact);
  admin: flash key `:error` + audit `device_deleted` with outcome `failure` and error detail
  `delete_failed` (the controller's `:ok = do_delete_device` match becomes a `case`).
  Behavioural side effect for legacy devices (accepted, spec-correct): the deleted device's legacy
  `sessions` / `sync_tokens` rows are now removed too. Residual: the LEGACY `rotate_tokens/1` takes no
  `devices` lock, so a concurrent legacy `/refresh` can still survive a deletion (pre-existing,
  follow-up (x)).
- **C13 (JWT kill-switch: never turn a bound JWT into a working unbound one; Kassandra story-3 I-6).**
  The kill-switches of `delete_one_device/3` and `Nebu.Matrix.delete_user_device/2` do
  `TokenDenylist.revoke_by_hash/2` per binding and then `DeviceBinding.delete_for_user_device/2`
  UNCONDITIONALLY. (`OAuthSession.kill_bound_jwts/2`, used by T7 issuance and story-4 revocation,
  already uses story 4's `TokenDenylist.revoke_by_hash_checked/2` and keeps the bindings when a
  denylist write fails; it is unified below.) `revoke_by_hash/2`
  writes ETS (node-local) and then the DB best effort and returns `:ok` even when the DB write failed
  (and is a no-op for a binding with `exp == nil`). Deleting the binding row then makes
  `DeviceBinding.lookup/1` answer `{:ok, nil, false}` on every other node, so the JWT authenticates
  AGAIN as a device-less legacy credential: T25 layer (c) and the device deletion are bypassed
  cluster-wide. Fix with the minimal blast radius:
  (a) `TokenDenylist.revoke_by_hash/2 :: :ok | {:error, term}` (ETS insert always; the result is the
  DB write; `exp == nil` => `{:error, :no_exp}` without a DB write). Story 4's
  `revoke_by_hash_checked/2` is merged into it (or delegates to it; one implementation). Its callers
  are the kill-switch loops (`delete_one_device/3`, `Nebu.Matrix.delete_user_device/2`) and
  `kill_bound_jwts/2`; story-5 tests pin the new return value (`oauth_device_teardown_test.exs`).
  Semantic change: `revoke_by_hash_checked/2` treated `exp == nil` as `:ok` (binding deleted); now
  `{:error, :no_exp}` => the binding is KEPT, and the JWT stays refused fail closed through the
  binding (OAuth device, or the missing `devices` row of a deleted device, C13 c), also on the T7
  path.
  (b) One shared `DeviceBinding.kill_device_jwts(user_id, device_id, opts \\ []) :: :ok | {:error,
  :partial}` (option `except_hash:` for the preserved own-device branch of `delete_one_device/3`: that
  token is neither denylisted nor its row deleted) replaces the loops of `delete_one_device/3`,
  `Nebu.Matrix.delete_user_device/2` AND `OAuthSession.kill_bound_jwts/2`; it keeps the
  rescue/catch "never fail the grant / the deletion" envelope and the WARNING log line of
  `kill_bound_jwts/2`; it deletes ONLY the binding rows whose denylist DB write succeeded and
  returns `{:error, :partial}` when a row was kept (callers log a WARNING without token or hash; HTTP
  callers keep their success answer: the session/device teardown already committed).
  (c) `DeviceBinding.lookup/1` KEEPS its shape `{:ok, device_id | nil, refused? :: boolean()}`; the
  third element (today `oauth_device?`, T25 c) becomes "refused": `true` when the bound device has an
  `auth_api = 'oauth'` row OR has NO `devices` row any more (`NOT EXISTS (SELECT 1 FROM devices d
  WHERE d.user_id = b.user_id AND d.device_id = b.device_id)`), in the SAME cached query. `OidcPlug`
  is unchanged (it already answers `401 M_UNKNOWN_TOKEN` "Access token has been revoked", no
  `soft_logout`, on `true`); `get_device/1` unchanged; unbound => `{:ok, nil, false}` unchanged. A
  kept binding therefore still kills the JWT through the database within the 60 s lookup-cache TTL
  even when the denylist write failed. (d) `DeviceBinding.put/4` result change: see C11 (`:ok |
  {:error, :oauth_device}`; every successful bind still returns `:ok`).
  Blast radius (exact): production callers of `lookup/1`: only `OidcPlug.call_jwt/2` (unchanged
  code); of `put/4`: `HttpPublic.respond_login/7` and `protected.ex` `maybe_bind_jwt_device/3` (both
  `_ =` today; C11 changes them). Tests: `Nebu.OAuth.TestSupport.bound_jwt!/3`
  (`oauth_test_support.exs` ~1282, `:ok = DeviceBinding.put(...)` on `dev()` WITHOUT a `devices` row)
  must first upsert the device (`Nebu.Matrix.DeviceKeyStore.upsert_device/3`), otherwise every JWT it
  returns is refused; its callers (e.g. `oauth_resource_server_test.exs` "a normal (non-OAuth) device
  still binds" and "lookup/1 of a normal binding => {:ok, device, false}") then stay green unchanged.
  `T.insert_jwt_binding!/4` (~1559; callers `oauth_session_store_test.exs` ~498,
  `oauth_revoke_semantics_test.exs` ~360, story-4 `oauth_logout_test.exs` fixtures) and the direct
  INSERT in `oauth_resource_server_test.exs` ~214 bind to devices that have a `devices` row (OAuth
  devices, or legacy devices created by the fixture): the ATDD step verifies each call site and adds
  the device row where a fixture binds to a never-registered id. Legacy suites that obtain JWTs
  through `POST /login` (`device_lifecycle_login_test.exs`, `sso_login_configured_claim_device_test.exs`,
  `device_endpoints_test.exs`) get the `devices` row from `register_device/4`; tests that use UNBOUND
  raw JWTs (~40 files) are unaffected. Behaviour consequence: a legacy raw JWT whose `devices` row is
  missing (only when the best-effort `register_device/4` failed at login, or after its device was
  deleted) is refused (fail closed; oracle O4: acceptable and required for deleted devices, `401
  M_UNKNOWN_TOKEN` without `soft_logout`); the login-time case is closed by C11's 500.
- **C14 (unbound raw-JWT path stays for legacy; the remaining hole is closed by C11/C13).** Spec 2:
  only Nebu-issued opaque tokens for OAuth sessions. Story 3 refuses JWTs bound to OAuth devices
  (T25). An UNBOUND raw IdP JWT (never redeemed through `POST /login`, or a pre-binding JWT)
  authenticates as the user with `device_id == nil`, also for a user who only has OAuth devices.
  Decision (decision 6, full parallel operation; ADR-033 "Accepted risk (legacy bypass)"): KEEP this
  legacy exception, but an unbound JWT can never become or act as an OAuth device (C11: no binding,
  no key writes; it cannot read an OAuth device's to-device queue because it has no device). It is a
  legacy credential and dies with legacy shutdown. Refusing unbound JWTs outright would break the
  ~40 test files that use raw JWTs and every direct-IdP-token integration; recorded as follow-up (u)
  for the day legacy is deprecated.
- **C15 (Kassandra story-3 I-5, device take-over across APIs).** An approved OAuth client can pick
  the id of the user's existing LEGACY device (T7: deletes its legacy rows, kills its JWTs, keeps
  keys) and a legacy login can pick the id of an OAuth device (T26). Both are spec-conformant
  ("reuse an existing device, provided the user remains the same") and need an interactive login of
  the SAME user; the residual risk (malicious approved native app on a silent IdP SSO session) is
  gate item (i). No change; documented in ADR-033.
- **C16 (OAuth sessions while OAuth is switched off).** `OidcPlug` does not consult
  `oauth_enabled`: existing OAuth sessions keep authenticating after an operator switches OAuth off
  (their refresh then fails with the T22 kill switch, so they die within one access-token lifetime;
  `/oauth2/revoke` and `/logout` still end them, story 4 R13). Decision: unchanged, documented as the
  operator semantics of the switch (deprecation path C20, AC10).
- **C17 (`/whoami`, `/refresh`, `RefreshWorker`, media).** Verified, no change: `/whoami` returns
  `user_id`, `is_guest: false` and the bound `device_id` for OAuth and opaque legacy sessions (raw JWT
  without binding: no `device_id`); `POST /refresh`, `MatrixSessionStore` refresh/extension functions
  and the `RefreshWorker` act on `auth_api = 'legacy'` rows only (T27); media routers run the same
  `OidcPlug` (identical semantics for both APIs).
- **C18 (admin device list).** Verified: `Nebu.Matrix.list_user_devices/1` lists OAuth devices
  (they are `devices` rows); admin deletion ends OAuth sessions (now atomically, C12); admin
  deactivation deletes every row of the user (story 3/4 regression tests). The list does not show
  which API / client owns a device: not a correctness gap (`ui: false`), follow-up (v).
- **C19 (no audit rows, no new config, no migration).** Consistent with T29/D20/R21: no
  `audit_log` rows for logins/logouts/device deletions by users (admin device deletion keeps its
  existing audit row). No new `server_config` key, no env variable (ADR-022), no schema change (all
  new SQL uses existing tables, the `devices` PK and the existing `matrix_sessions` indexes).
- **C20 (deprecation path, decision 6 "until one of the two is deprecated").** Documented in
  ADR-033, not implemented: (a) deprecating LEGACY introduces a `legacy_login_enabled` switch then
  (spec 14 "Folgerungen"): `GET /login` stops advertising `m.login.token` / the SSO flow for new
  logins, `POST /login` refuses new legacy logins, `/refresh` and the `RefreshWorker` are removed, legacy sessions are NOT migrated (spec
  8), they run out at `expires_at` and the user logs in again through OAuth; the raw-JWT path
  (follow-up u) goes with it; (b) deprecating OAuth = `oauth_enabled = false` (today's kill switch):
  discovery back to the IdP passthrough, the OAuth-aware flags disappear (C2), existing OAuth
  sessions die at their next refresh (C16), revoke stays live.

## Acceptance Criteria

### AC1 — `GET /_matrix/client/v3/login` advertises OAuth-aware preference (C1-C3)

- `Nebu.OAuth.oauth_aware?/0` exists (`@doc`, `@spec`, never raises) with the C1 predicate, shared
  with `Nebu.OAuth.Http.live_state/0` (one helper, no duplicated condition).
- `Nebu.Matrix.HttpPublic.login_flows/1`: when `Nebu.OAuth.oauth_aware?/0` is true the
  `m.login.sso` flow object carries `"oauth_aware_preferred": true` and
  `"org.matrix.msc3824.delegated_oidc_compatibility": true`; otherwise neither key exists.
- Every other part of the response is unchanged: status 200, `application/json`, flows
  `[m.login.sso (identity_providers [{"id":"oidc","name":<display name>,"icon":null}]),
  m.login.token]` in this order; the `m.login.token` flow never carries the keys.
- States: `:enabled` + valid https issuer => advertised; `:enabled` + nil / http / path-carrying
  issuer => absent; `:disabled` => absent; `:unknown` (`T.unreadable_oauth_config/0`) => absent and
  still `200` (never 503); an exception in the config read => absent and 200.
- With OAuth disabled the response body is byte-identical to today's (snapshot test).
- Same predicate as discovery (O5): for each config state the flags are present IFF `GET
  /_matrix/client/v1/auth_metadata` answers 200 in the same state; toggling `oauth_enabled` at runtime
  flips both on the next request (no cache). The values are JSON `true` (not `"true"`); `m.login.sso`
  stays the FIRST flow.

### AC2 — `action` at the legacy SSO redirect (C4-C6)

- `Nebu.Matrix.SsoLogin.redirect/1` (both `/sso/redirect` and `/sso/redirect/{idpId}`) derives the
  action per C4 and the IdP `prompt` per C5.
- OAuth offered + `action=register` + IdP `prompt_values_supported` contains `create` => the
  302 `Location` has `prompt=create` and otherwise the same parameter set as a `login` redirect
  (`response_type`, `client_id`, `redirect_uri`, `scope` (OIDC Scopes Law, unchanged), `state`,
  `nonce`, `code_challenge`, `code_challenge_method`), no `max_age`.
- OAuth offered + `action=register` + IdP without `create` (key missing, not a list, list without
  `create`) => `prompt=login`, parameter set identical to `action=login`.
- `org.matrix.msc3824.action=register` alone behaves like `action=register`; stable `action=login`
  + unstable `register` => `login` wins.
- Ignored values (absent, empty, `REGISTER`, `signup`, `action[]=register`, 33+ bytes, control
  characters) => identical to no action; never a 4xx or 5xx. Stable invalid + unstable `register` =>
  `register`; both invalid => absent; repeated `action` key => the LAST value (`conn.query_params`,
  e.g. `action=login&action=register` => `register`), never a 4xx.
- `prompt=create` replaces `prompt=login`: exactly one `prompt` parameter in the `Location`.
- `action=register` with a missing / rejected `redirectUrl` => today's 400 (error order unchanged);
  with an IdP discovery failure => today's `503 M_UNAVAILABLE`, same as `login`; on an arbitrary
  `{idpId}` => today's behaviour (pinned as measured).
- OAuth NOT offered (disabled / invalid issuer / unknown): every `action` value => `Location`
  identical to today's redirect (only `state`, `nonce`, `code_challenge` differ by randomness;
  compare the parameter names and the non-random values).
- The UIA fallback (`/auth/m.login.sso/fallback/web`) and the OAuth leg are unaffected (their
  existing tests stay green; a test with `action=register` on the fallback URL shows `prompt=login`
  + `max_age=0`).
- Logging: no log line contains the raw `action` value of a request (log capture with a unique
  marker value).

### AC3 — OAuth callers refused at device deletion (C7, C8)

- `DELETE /devices/{id}` with an OAuth access token => `403 {"errcode":"M_FORBIDDEN","error":"Device
  deletion is not available for OAuth sessions; use the account management page."}` for the
  caller's OWN device id, another OAuth or legacy device of the same user, another user's device id
  and an unknown id; with and without an `auth` block (also a valid completed UIA session of the
  user, which stays unconsumed).
- `POST /delete_devices` with an OAuth access token => the same 403 for `{"devices":[...]}` (own,
  other, foreign ids), `{}` (missing `devices`), `{"devices":"x"}`, 101 ids, and with an `auth` block.
- The 403 also for an empty body and a non-JSON body on both endpoints (refusal before body parsing).
- An EXPIRED OAuth access token on both endpoints => `401 M_UNKNOWN_TOKEN` + `soft_logout: true`
  (authentication before the refusal), nothing touched.
- Effects: no `matrix_sessions` / `devices` / key / `jwt_device_bindings` row of any user changes,
  no `uia_sessions` row is inserted or consumed (row snapshots); the caller's session keeps
  working afterwards (`/whoami` 200).
- Legacy callers (opaque legacy and raw JWT): today's behaviour for their own and other devices
  (challenge 401 with `m.login.sso` when stale, fresh-window delete, `auth` block, IDOR 404, body
  400s), including deleting an OAuth device of the same user (story 4 AC10 tests stay green).
- `OidcPlug` assigns `:auth_api` (story 4); the handler reads only that assign (static test: no
  `MatrixSessionStore` / `OAuthSessionStore` lookup to decide the API in these handlers).

### AC4 — UIA freshness legacy-only (C9)

- `MatrixSessionStore.refresh_auth_time/2` updates only `auth_api = 'legacy'` rows.
- Test: a user with one legacy opaque session and one OAuth session; `Uia.complete/2` (legacy SSO
  UIA completion) => the legacy row's `auth_time` is refreshed, the OAuth row's `auth_time` is
  unchanged.

### AC5 — Account endpoints stay absent (C10)

- With an OAuth token AND with a legacy token: `POST /account/deactivate`, `POST /account/password`,
  `GET /account/3pid`, `POST /account/3pid/add`, `POST /account/3pid/delete`, `POST /register` =>
  status `404` (the errcode is NOT asserted: `M_NOT_FOUND` instead of the spec's `M_UNRECOGNIZED` is a
  known deviation, C10); unauthenticated `POST /register` => 401 is NOT pinned either (recorded
  deviation); `GET /capabilities` => `m.change_password.enabled == false` and
  `m.3pid_changes.enabled == false`.
- `POST /keys/device_signing/upload` with an OAuth token: unchanged behaviour (first upload 200,
  identical re-upload 200, different keys 403) — regression only, `m.oauth` is story 6.

### AC6 — Raw JWT cannot write keys of an OAuth device (C11)

- `DeviceBinding.put/4 :: :ok | {:error, :oauth_device}`; a refused bind stores no row and primes no
  cache entry (unchanged); a DB error => `:ok` (unchanged best effort).
- `POST /keys/upload` with an UNBOUND raw JWT and `device_keys.device_id` (or only
  `one_time_keys`/`fallback_keys` plus a body `device_keys.device_id`) naming the user's OAuth device
  => `403 M_FORBIDDEN` (G1 text), no row in `device_keys` / `device_one_time_keys` /
  `device_fallback_keys` / `jwt_device_bindings` changed; the OAuth device's keys are byte-identical
  afterwards. Naming a legacy device of the user or a new id => unchanged (binds + writes, 200).
- Legacy `POST /login` raw-JWT branch with `{:error, :oauth_device}` from `put/4` => `500 M_UNKNOWN
  "Login failed, please try again."` (forced via the test-only, compile-time guarded seam
  `:nebu_http, :device_binding_put_override` in `DeviceBinding.put/4`; the JWT is not returned).
- Legacy `POST /login` raw-JWT branch with a FAILING `register_device/4` (seam or a privileged
  trigger refusing the `devices` upsert) => the same `500 M_UNKNOWN "Login failed, please try
  again."`, no JWT returned, no binding row (O4 correction). The opaque branch is unchanged.

### AC7 — Atomic device teardown (C12)

- `Nebu.Matrix.end_device_session/2` exists (`@doc`, `@spec`, never raises; delegates to
  `OAuthSession.end_device_session/2`).
- `delete_one_device/3` uses it for every non-preserved device; the preserved own-device branch is
  unchanged. `Nebu.Matrix.delete_user_device/2` uses it (`:ok | {:error, :unavailable}`; admin
  controller maps the error to a flash error and a `failure` audit row).
- Concurrency (deterministic, story-4 idiom): a test holds the device's `devices` row `FOR UPDATE`,
  starts a legacy `DELETE /devices/{oauth_device}` (fresh window) in a Task, asserts it WAITS
  (`Task.yield(task, 500) == nil`), commits a hand-made OAuth rotation (UPDATE + INSERT) for that
  device, then asserts: 200, zero `matrix_sessions` rows of the device, the rotated-in access token
  => 401 without `soft_logout`, its refresh token => `invalid_grant`. Same for admin
  `delete_user_device/2`.
- Failure: `:oauth_session_repo` NoSuchRepo (or `T.block_session_deletes!/1`) => `DELETE /devices`
  `500 M_UNKNOWN "Device deletion failed, please try again."`, `/delete_devices` 500 after attempting
  every id, the session survives intact (AT works).
- A deleted legacy device also loses its legacy `sessions` / `sync_tokens` rows.

### AC8 — JWT kill-switch keeps failed bindings; bound-to-missing-device JWT refused (C13)

- `TokenDenylist.revoke_by_hash/2 :: :ok | {:error, term}` (ETS insert always; the result reflects
  the DB write; `exp == nil` => `{:error, :no_exp}` without a DB write). Existing callers adapted.
- `DeviceBinding.kill_device_jwts/3` (`except_hash:`) replaces the two inline kill-switch loops
  (`delete_one_device/3`, `Nebu.Matrix.delete_user_device/2`) and `OAuthSession.kill_bound_jwts/2`;
  only successfully denylisted rows are deleted; a kept row => `{:error, :partial}` + WARNING (no
  token, no hash).
- `DeviceBinding.lookup/1` keeps `{:ok, device_id | nil, refused? :: boolean()}` (C13 c): `true`
  for an OAuth device OR a missing `devices` row, ONE cached query; `OidcPlug.call_jwt/2` code
  unchanged (`401 M_UNKNOWN_TOKEN` "Access token has been revoked", no `soft_logout`);
  `T.bound_jwt!/3` upserts the device row first (C13 blast radius).
- Tests: with the denylist DB write forced to fail (seam or a privileged trigger on the denylist
  table), deleting the JWT's device (legacy DELETE /devices, admin) => the binding row is KEPT and
  the JWT is refused on a node without the ETS entry (clear the ETS denylist entry and the lookup
  cache in the test to simulate another node); T7 issuance on a device with a bound JWT and a failing
  denylist write => the JWT is still refused (binding kept, T25 c) — a REGRESSION GUARD, green at
  HEAD since story 4; a binding with `exp == nil` is kept (`{:error, :partial}`) and refused.
- A legacy raw JWT bound to a device that an admin deleted, then `POST /keys/upload` for that device
  id => `401 M_UNKNOWN_TOKEN` "Access token has been revoked" (refused by `OidcPlug`), NOT a fresh lazy
  bind.

### AC9 — Coexistence regressions (C14-C18)

- Unbound raw JWT for a user with ONLY OAuth devices: authenticates device-less (`/whoami` without
  `device_id`, `/sync` 200) and cannot bind/upload to the OAuth device (AC6) — documents C14.
- Legacy `/refresh` with an OAuth RT => 401, `/oauth2/token` with a legacy RT => `invalid_grant`,
  `RefreshWorker` never touches OAuth rows (story-3 tests stay green).
- `/whoami` for OAuth, opaque legacy, bound JWT, unbound JWT (device_id present/absent per C17).
- Admin device list of a user with one legacy and one OAuth device lists both; admin delete of the
  OAuth device ends its session (AT 401, RT `invalid_grant`).
- OAuth switched off with a live OAuth session: the AT keeps authenticating, `/oauth2/token`
  refresh => 404 (T22), `/logout` ends it (C16).
- Legacy `POST /logout` (user-wide wipe, devices kept; story-4 R16) and legacy `POST /login` device-id
  reuse (earlier legacy tokens survive) are UNCHANGED: the story-4 R16 tests and the legacy login
  suites stay green as they are.

### AC10 — Documentation

- ADR-033: new section "Legacy coexistence (story 5)" with C1-C20, incl. the coexistence touchpoint
  table (Dev Notes), the deprecation path (C20), the OAuth-aware flags rule (C2/C3) and the C8
  rationale; the R16 (legacy `/logout`) and story-3 oracle-C8 (legacy-to-legacy device reuse)
  deviations stay as recorded deviations ("not changed by story 5, follow-ups (r)/(f)"); the "Implications: legacy coexistence is temporary" section is rewritten to point at
  C20 (`auth_api`, parallel operation, what happens when one API is deprecated); T25's sentence
  "User-level raw-JWT access without an OAuth device stays the legacy exception (story 5)" gets "(C14:
  kept; follow-up u)"; the gate paragraph gets "Story 5 update: OAuth sessions cannot delete devices
  until story 6 (item w); gate item (r) remains open and MUST be closed before the story-9 `/versions`
  flip (at the latest before `oauth_enabled`) by the bugfix run `legacy-logout-per-device`; story 9
  flips `/versions` on `Nebu.OAuth.oauth_aware?/0`".
- `docs/matrix-api-scope.md`: rows `GET /login` (OAuth-aware flags while OAuth is offered),
  `GET /login/sso/redirect` (`action` / unstable `org.matrix.msc3824.action`, `register` =>
  `prompt=create` when the IdP supports it, marked as a Nebu extension; unknown values ignored),
  `DELETE /devices/{deviceId}` and `POST /delete_devices` (`403 M_FORBIDDEN`
  for OAuth sessions; legacy UIA unchanged), `POST /keys/upload` (no raw-JWT writes into OAuth
  devices); a note that `/account/deactivate|password|3pid` and `/register` are deliberately absent
  (known deviations: `M_NOT_FOUND` instead of `M_UNRECOGNIZED`; unauthenticated `/register` 401
  before 404).
- `docs/stories/oauth-broker/follow-ups.md`: section "From story oauth-legacy-coexistence": story-3
  (d) RESOLVED for device deletion (C7: refused; `m.oauth` for cross-signing reset remains story 6),
  story-3 (f) gets the note "not in story 5"; story-4 (r) gets the note "not in story 5; MUST be
  closed before the story-9 `/versions` flip, at the latest before `oauth_enabled`, by the bugfix run
  `legacy-logout-per-device` (`/nebu-pipeline --bug`); story 9 flips `/versions` on
  `Nebu.OAuth.oauth_aware?/0`" (otherwise unchanged); story-4 R18
  extension RESOLVED (C7/C12),
  Kassandra story-3 I-5 accepted (C15), I-6 RESOLVED (C13); new rows **(u)** refuse unbound raw IdP
  JWTs / remove the raw-JWT path when legacy is deprecated (non-gating, C14), **(v)** admin device
  list shows no owning API / OAuth client per device (non-gating, story 6 or epic end), **(w)** OAuth
  sessions cannot delete other devices until the account page exists (story 6 before `oauth_enabled`;
  gating), **(x)** legacy `rotate_tokens/1` takes no `devices` lock, so a concurrent legacy `/refresh`
  can survive a device deletion (non-gating, epic-end review). Letters a-t are used by stories 1-4.
- `Nebu.OAuth` moduledoc (`oauth_aware?/0`), `Nebu.Matrix` (`end_device_session/2` `@doc`),
  `HttpPublic` / `SsoLogin` / `protected.ex` comments (the stale "Option B ... OIDC-only" UIA text
  gains the OAuth refusal).
- arc42 (by the arc42 step; Dev Notes list the hooks).

## Acceptance Tests

### ExUnit matrix (unit = pure, integration = `@tag :integration`, DB)

- New `server/test/nebu/oauth/oauth_legacy_coexistence_test.exs` (integration): AC1 (every config
  state, byte snapshot while disabled), AC2 (Location parameter comparison with a stubbed IdP
  discovery document with/without `create`; `Nebu.Matrix.OidcMetadata` fetch seam used by story 2
  tests), AC3, AC4, AC5, AC9.
- New `server/test/nebu/oauth/oauth_device_teardown_test.exs` (integration): AC6, AC7 (incl. the
  deterministic lock test and NoSuchRepo failure), AC8.
- New `server/test/nebu/oauth/oauth_legacy_coexistence_static_test.exs` (unit/static): C1 (Matrix
  files name no `Nebu.OAuth.Config`/`Metadata`; `oauth_aware?/0` and `end_device_session/2` exported
  with docs), C7 (the device-delete handlers read `conn.assigns[:auth_api]` and run the refusal
  before `belongs_to_other_user?`/`uia_gate`), C13 (no remaining inline `revoke_by_hash` loop
  outside `DeviceBinding.kill_device_jwts/3`).
- Changed deliberately (Trap 6): story-3 `oauth_token_refresh_grant_test.exs` "refresh after DELETE
  /devices/{id} => invalid_grant" (an OAuth caller deleting its own device) and
  `oauth_resource_server_test.exs` "DELETE /devices/{id} (fresh-auth window) removes the OAuth rows"
  become "OAuth caller => 403, nothing deleted" (the deletion-by-legacy-session variant already lives
  in story 4's `oauth_logout_test.exs`); `test/nebu/matrix/matrix_router_test.exs` `GET /login` test
  extended (keys absent while disabled); `oauth_test_support.exs` `bound_jwt!/3` upserts the device
  row (C13); `adr_033_test.exs` (AC10 pins). The story-4 legacy `/logout` (R16) tests stay AS IS.
- Extended: `server/test/nebu/matrix/device_endpoints_test.exs` (legacy UIA
  unchanged + atomic teardown), `server/test/nebu/web/oidc_plug_test.exs` (missing-device refusal),
  `server/test/nebu/web/token_denylist*_test.exs` (return values), admin users controller tests
  (error flash), `token_hashing_test.exs` guards if the new store function needs acknowledging.

### matrix_compat node test (optional, like stories 3/4)

If runnable without modifying the main checkout: a fixture with Nebu's real `GET /login` response
(OAuth offered) and a replay through matrix-js-sdk 41.3.0 (`OAUTH_AWARE_PREFERRED_FLOW_FIELD.findIn`
on the SSO flow => `true`) and `getSsoLoginUrl(url, "sso", "oidc", SSOAction.REGISTER)` (both
`action` and `org.matrix.msc3824.action` present). Otherwise "not executed" in the Dev Agent Record.

### Gherkin

None: no UI (`ui: false`).

## Must be test-covered (Matrix CS API v1.18, spec 2/3a/8, decisions 4/6)

1. OAuth offered (`:enabled` + valid issuer): `m.login.sso` flow has `oauth_aware_preferred: true`
   AND `org.matrix.msc3824.delegated_oidc_compatibility: true` (JSON booleans).
2. Disabled / invalid issuer / unknown config / exception: neither key present; `GET /login` still 200
   with both flows; disabled response byte-identical to the pre-story response.
3. The `m.login.token` flow never carries the keys; `identity_providers` unchanged.
4. `action=register` + IdP supports `create` + OAuth offered => `prompt=create`, no `max_age`.
5. `action=register` + IdP without `create` => `prompt=login`, identical parameter set to `login`.
6. `org.matrix.msc3824.action` honoured; stable `action` wins on conflict.
7. Junk / array / oversized / case-variant `action` => ignored, never 4xx/5xx.
8. OAuth not offered => `action` ignored for every value (URL identical to today's).
9. `/sso/redirect/{idpId}` behaves like `/sso/redirect`; UIA fallback and OAuth leg unaffected.
10. The raw `action` value never appears in logs.
11. OAuth caller `DELETE /devices/{id}` => 403 `M_FORBIDDEN` for own / other / foreign / unknown id,
    with and without `auth`; nothing changed; no UIA session minted or consumed.
12. OAuth caller `POST /delete_devices` => 403 before body validation (missing / non-list / > 100).
13. Legacy callers (opaque, JWT): UIA challenge (`m.login.sso`), fresh-window delete, `auth` block,
    IDOR 404 and body 400s unchanged; deleting an OAuth device of the same user still works.
14. Legacy UIA SSO completion refreshes only legacy rows' `auth_time`.
15. `/account/deactivate`, `/account/password`, `/account/3pid*`, `/register` absent for both APIs;
    capabilities `m.change_password` and `m.3pid_changes` false.
16. `/keys/device_signing/upload` with an OAuth token unchanged (story 6 owns `m.oauth`).
17. Unbound raw JWT cannot upload/overwrite keys of an OAuth device (403, row snapshot identical).
18. Unbound raw JWT can still upload keys for a legacy/new device of the user (legacy unchanged).
19. Legacy raw-JWT `/login` whose binding is refused => 500, no JWT returned.
20. Device deletion vs concurrent OAuth rotation (legacy DELETE /devices and admin delete): no
    surviving row; the rotated-in AT 401, RT `invalid_grant`.
21. Device deletion storage failure => 500 (DELETE, `/delete_devices`), admin flash error; session intact.
22. Deleting a legacy device removes its legacy `sessions` / `sync_tokens` rows.
23. Legacy `/logout` (user-wide, R16) and legacy `/login` device reuse unchanged (regression).
24. Kill-switch with a failing denylist DB write keeps the binding; the JWT is refused on another
    node (ETS cleared) through the binding (T25 c or missing device).
25. A raw JWT bound to a deleted device => 401 `M_UNKNOWN_TOKEN` "revoked", no `soft_logout`.
26. Unbound raw JWT for an OAuth-only user authenticates device-less (C14 documented behaviour).
27. `/whoami` per credential kind (OAuth, opaque legacy, bound JWT, unbound JWT).
28. Legacy `/refresh` vs OAuth RT and `/oauth2/token` vs legacy RT stay isolated; RefreshWorker skips
    OAuth rows (story-3 suites green).
29. OAuth switched off: a live OAuth AT still authenticates, its refresh is 404, `/logout` ends it.
30. No cross-domain call from `lib/nebu/matrix/**` into `Nebu.OAuth.Config` / `Nebu.OAuth.Metadata`;
    no node-local state decides any C-behaviour (static).
31. Logging: no token, hash, IdP token, raw `action` or `Authorization` value in any new log line.
32. OAuth-aware flags present IFF `auth_metadata` answers 200 (per state, runtime toggle, JSON `true`,
    `m.login.sso` first and always offered).
33. Exactly one `prompt` parameter for `action=register`; error order (bad `redirectUrl`, discovery
    failure, `{idpId}`) unchanged; stable-invalid + unstable-valid, both invalid, repeated key pinned.
34. OAuth caller refusal also with empty / non-JSON body; expired OAuth AT => 401 `soft_logout: true`.
35. Legacy raw-JWT `/login` with a failing `register_device/4` => 500 `M_UNKNOWN`, no JWT.
36. JWT bound to an admin-deleted device + `/keys/upload` => 401 "revoked", no lazy re-bind.
37. Unrouted account endpoints: 404 status only (errcode not pinned, known deviation).

## Dev Notes

### Coexistence touchpoint audit (verdicts; this table goes into ADR-033)

| Touchpoint | Code | Legacy | OAuth | Verdict |
|---|---|---|---|---|
| Opaque bearer auth | `OidcPlug.call_opaque/2` (`get_by_access_token/1`, any `auth_api`) | ok | ok, assigns `:auth_api` (story 4) | ok |
| Raw IdP JWT auth | `OidcPlug.call_jwt/2` + `DeviceBinding.lookup/1` | ok | JWT bound to OAuth device refused (T25 c) | gap: binding deleted after failed denylist => C13 |
| Unbound raw JWT | `call_jwt/2` `{:ok, nil, false}` | legacy exception | cannot act as OAuth device only after C11 | C14 keep + C11 |
| `POST /keys/upload` lazy bind | `maybe_bind_jwt_device/3`, `upload_device_id/2` | ok | refused bind still writes keys | gap => C11 |
| `POST /login` device reuse | `HttpPublic.provision_and_respond/6` (T26 `delete_device_oauth/2`) | earlier legacy tokens survive (spec deviation (f)) | OAuth rows deleted (T26), no lock | not in story 5: follow-up (f); refused bind => C11 |
| `POST /refresh` | `MatrixSessionStore.resolve_refresh_token/1`, `rotate_tokens/1` (`auth_api = 'legacy'`) | ok | OAuth RT unknown (401) | ok (T27); residual lockless legacy rotation => (x) |
| `RefreshWorker` | candidates + TOCTOU re-select `auth_api = 'legacy'` | ok | skipped | ok (T27) |
| `/oauth2/token` refresh | `OAuthSessionStore` (`auth_api = 'oauth'`) | legacy RT `invalid_grant` | ok | ok (T27) |
| `POST /logout` | `protected.ex` (story 4 R15/R16) | user-wide wipe incl. OAuth sessions of other devices, devices kept (gate r) | current device only | not in story 5: gate (r) stays open |
| `POST /logout/all` | story 4 R17 | all | all | ok (unchanged) |
| `DELETE /devices`, `/delete_devices` | `uia_gate/4`, `delete_one_device/3` | UIA `m.login.sso` | UIA fallback reachable (follow-up d); lockless teardown | gaps => C7, C12 |
| UIA SSO completion | `Uia.complete/2` -> `refresh_auth_time/2` | ok | refreshes OAuth `auth_time` too | gap => C9 |
| `/keys/device_signing/upload` | `do_device_signing_upload/1` | ok | no `m.oauth` | story 6 (unchanged) |
| `/account/deactivate|password|3pid`, `/register` | not routed | absent | absent | ok (C10, pinned) |
| `/whoami` | `protected.ex` | ok | `device_id` present | ok (C17) |
| Admin device list / delete | `Nebu.Matrix.list_user_devices/1`, `delete_user_device/2` | ok | listed; lockless teardown; no API marker | gap => C12; marker => (v) |
| Admin deactivation | `deactivate_user/2` -> `delete_for_user/1` | ok | ok | ok |
| GDPR erasure | story 4 R19 | ok | ok | ok |
| Media | `Router.Media`, `ClientV1Media` run `OidcPlug` | ok | ok | ok |
| `GET /login` | `HttpPublic.login_flows/1` | flows | no `oauth_aware_preferred` | gap => C1-C3 |
| SSO redirect `action` | `SsoLogin.redirect/1` | ignored | ignored | gap => C4-C6 |
| T7 issuance JWT kill | `OAuthSession.kill_bound_jwts/2` | - | best effort (I-6) | gap => C13 |

### Files to create

- Tests listed under Acceptance Tests; helpers ONLY in `server/test/nebu/oauth/oauth_test_support.exs`
  (section "Story 5": `login_flows/0`, `sso_redirect(params)` returning the decoded `Location`
  query, `stub_idp_discovery(prompt_values)`, `legacy_session!/2`, `bound_jwt!/3`, `unbound_jwt!/1`,
  `fail_denylist_db!/0`, `forget_node_local_jwt_state!/1` (ETS denylist + binding cache), reuse
  story-4 `device_state/2`, `world_snapshot/1`, `insert_jwt_binding!/4`, `block_session_deletes!/1`).

### Files to modify

- `server/lib/nebu/oauth.ex` — `oauth_aware?/0` (+ moduledoc "Matrix -> OAuth entry points").
- `server/lib/nebu/oauth/http.ex` — `live_state/0` uses the shared predicate helper (no behaviour change).
- `server/lib/nebu/matrix/http_public.ex` — `login_flows/1` (AC1); `respond_login/7` raw-JWT branch
  (C11: refused bind => 500) and `register_device/4` result (O4: failure => 500 in the raw-JWT branch).
- `server/lib/nebu/matrix/sso_login.ex` — `redirect/1` / `do_redirect/3`: action derivation (C4),
  `prompt` from the discovery document (C5) via `discovery_doc/1` + `doc_url/2`; `uia_fallback/1`
  unchanged.
- `server/lib/nebu/web/router/protected.ex` — device-delete handlers (C7), `delete_one_device/3`
  (C12, C13), `/keys/upload` (C11), comments. `/logout`, `/logout/all` untouched.
- `server/lib/nebu/matrix.ex` — `end_device_session/2` facade; `delete_user_device/2` (C12, C13).
- `server/lib/nebu/matrix/oauth_session.ex` — `kill_bound_jwts/2` -> `DeviceBinding.kill_device_jwts/3`.
- `server/lib/nebu/matrix/session/matrix_session_store.ex` — `refresh_auth_time/2` filter (C9).
- `server/lib/nebu/matrix/session/device_binding.ex` — `put/4` result (C11) + the test-only,
  compile-time guarded seam `:device_binding_put_override` (`if Mix.env() == :test`), `lookup/1`
  "refused" incl. missing device (C13 c, same tuple shape), `kill_device_jwts/3` (C13 b).
- `server/lib/nebu/web/token_denylist.ex` — `revoke_by_hash/2` result; `revoke_by_hash_checked/2`
  merged into it / delegating (C13 a).
- `server/lib/nebu/admin/users_controller.ex` — `delete_device/2` error branch (C12).
- Tests per Trap 6; docs per AC10.

### Current state of the code this story builds on (read before coding)

- `HttpPublic.login_flows/1` (~line 205): static map, no DB, `:oidc_display_name` env; `get "/"`
  disambiguates `/login` by `conn.request_path`.
- `SsoLogin.redirect/1` (~80) -> `do_redirect/3` (~243): `discover(cfg.issuer,
  "authorization_endpoint")`, `SsoStore.put_state/3`, `idp_authorize_url/4` with `prompt: "login"`,
  `max_age` only for the UIA fallback; `oauth_idp_authorize_location/2` (~328) has the D11
  `prompt_values_supported` rule to mirror. `discovery_doc/1` (~866) / `doc_url/2` are private.
- `protected.ex`: `delete "/client/v3/devices/:device_id"` (~556: IDOR guard, then `uia_gate/4`),
  `post "/client/v3/delete_devices"` (~584: param checks, then `uia_gate/4`), `uia_gate/4` (~1962),
  `caller_auth_time/1`, `delete_one_device/3` (~2035, kill-switch loop + `delete_for_user_device/2`
  + `DeviceKeyStore.delete_device/2`), `caller_credential/1`, `maybe_bind_jwt_device/3` (~2102),
  `upload_device_id/2`, `post "/client/v3/keys/upload"` (~469), `post "/client/v3/logout"` and
  `"/client/v3/logout/all"` + `legacy_logout/2` (story 4, uncommitted at story creation),
  `revoke_access_token/1`, `revoke_jwt_access_token/2`.
- `OidcPlug`: `call_opaque/2` assigns `:auth_api` from the row, `call_jwt/2` assigns `"legacy"` and
  refuses `{:ok, _, true}` from `DeviceBinding.lookup/1`.
- `DeviceBinding`: `put/4` guarded `INSERT ... SELECT ... WHERE NOT EXISTS (oauth rows)`, always
  `:ok`; `lookup/1` cached 60 s per node (`{device_id, oauth?}`, nil cached too);
  `list_for_user_device/2`, `delete_for_user_device/2`, `hash/1`.
- `TokenDenylist.revoke_by_hash/2`: ETS insert + `db_revoke/2`, always `:ok`; `revoked?/2` checks ETS
  then DB.
- `Uia.complete/2` -> `MatrixSessionStore.refresh_auth_time/2` (`WHERE user_id = $1 AND revoked_at IS
  NULL`).
- `OAuthSession.end_device_session/2` / `OAuthSessionStore.end_device/2` (story 4): devices lock,
  delete all rows of the device, `DeviceKeyStore.delete_device!/3` in the transaction, post-commit
  `kill_bound_jwts/2` + `SessionSupervisor.destroy_session/2`.
- `EventDispatcher.Server.invalidate_user_sessions/2` (~1883): `device_id != ""` => per device
  (`destroy_session/2` + `delete_for_user_device/2`), else user-wide.
- `Nebu.Admin.UsersController.delete_device/2`: `:ok = do_delete_device(...)` + audit.

### What must be preserved

- Every story-1..4 behaviour not named in a C-decision (T7, T10/T11, T25-T27, R2, R13, R15, R17-R19).
- Legacy SSO login URL byte for byte while OAuth is not offered, and for `action=login`.
- Legacy UIA flow for legacy callers; `/keys/device_signing/upload`; legacy `/logout` (R16) and
  `/logout/all`; legacy `/login` device reuse (T26 only); deactivation.
- `DeviceKeyStore.delete_device/2` best-effort semantics for its other callers; the preserved
  own-device branch of `delete_one_device/3`.

### Traps

1. **Decide OAuth vs legacy by `conn.assigns[:auth_api]`** (authentication time), never by a lookup in
   the handler (story 4 Trap 4). An expired/superseded OAuth AT never reaches the handler (soft logout).
2. **Refusal FIRST** in both device handlers (C7): before the IDOR guard (existence oracle), before
   body validation, before `uia_gate` (would mint a `uia_sessions` row).
3. **`action` gating** (C5): do not fetch anything new when OAuth is not offered; the disabled URL must
   stay byte-identical (parameter set and order of `URI.encode_query/1` over the same map).
4. **Bind before write** (C11): the lazy bind must run and be checked BEFORE `put_device_keys/3`; today
   it runs first but its result is ignored.
5. **Lock order devices -> matrix_sessions** everywhere (C12), the DELETE in a later statement than
   the lock (story 4 Trap 1, READ COMMITTED snapshot).
6. **Stale tests (change deliberately, same commit):** story-3 OAuth self-delete via `DELETE /devices`
   (`oauth_token_refresh_grant_test.exs` ~255, `oauth_resource_server_test.exs` ~395), `GET /login`
   flow tests that compare the whole body, `T.bound_jwt!/3` (must create the `devices` row, C13),
   any fixture that binds a JWT to a never-registered device id. The story-4 legacy `/logout` (R16)
   tests are NOT stale and stay unchanged.
7. **Do not change legacy `/logout` or legacy `/login` semantics** (decision 6; gate (r), follow-up (f)
   stay open).
8. **Cache TTLs:** the binding lookup cache (60 s) and the provisioning cache (60 s) are node-local;
   tests must clear them to simulate another node (C13) and use unique device ids (IDOR guard, reused
   DB).
9. **`oauth_enabled` stays false** in every committed config; tests use `T.enable_oauth/1`.
10. **No raw `action` in logs** (C6) and the No Sensitive Data law (no token/hash in the new WARNINGs).
11. **Config read on every `GET /login`**: wrap it so an exception or `:unknown` can never fail the
    login flows (C2).

### Architecture compliance

ADR-018 inline SQL (`DeviceBinding`, `TokenDenylist`);
ADR-019 single app; ADR-020 facade-only cross-domain calls (`Nebu.OAuth.oauth_aware?/0`,
`Nebu.Matrix.end_device_session/2`) and no node-local state for correctness (every decision is a DB
read or a DB transaction; the ETS denylist and lookup caches are accelerators, C13 makes the DB
authoritative); ADR-022 no new env / `server_config` key (the only new application env is the
test-only `:device_binding_put_override`, compiled out outside `MIX_ENV=test`); ADR-033 broker model; OIDC Scopes Law
untouched (`scope` of the legacy redirect unchanged; `prompt=create` is not a scope); No Sensitive
Data law. No migration.

### Library / client notes

- matrix-js-sdk 41.3.0: `OAUTH_AWARE_PREFERRED_FLOW_FIELD = new UnstableValue("oauth_aware_preferred",
  "org.matrix.msc3824.delegated_oidc_compatibility")` (`src/@types/auth.ts`), both declared on
  `ISSOFlow`; `getSsoLoginUrl(redirectUrl, loginType, idpId, action)` sends `redirectUrl`, `action`
  AND `org.matrix.msc3824.action` (`SSO_ACTION_PARAM`, `src/client.ts`); `SSOAction` = `login` |
  `register`.
- Matrix v1.18: OAuth-aware clients only offer the SSO flow when `oauth_aware_preferred` is true,
  append `action`, honour `m.3pid_changes`, and MUST send users to the account page for deactivation
  and for signing out other devices (`action=org.matrix.device_delete&device_id=`), so a correct
  OAuth-aware client never hits C7's 403.
- Dart SDK 13: no OAuth-aware SSO handling verified; FluffyChat OAuth sessions see the C7 403 if they
  call device deletion (oracle O1).

### Testing commands (isolated env, see the epic brief)

No migration: `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth
test/nebu/matrix test/nebu/web test/nebu/admin"`; full gate via `integration.sh` (background, output
to a file); compare failures with `scratchpad/known.txt` by name. `MIX_ENV=prod mix compile`.

### Docs to touch (arc42 step and dev)

ADR-033 (AC10), `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`;
`docs/architecture/05-building-blocks.md` (`Nebu.OAuth.oauth_aware?/0`, `Nebu.Matrix.end_device_session/2`,
`DeviceBinding.kill_device_jwts/3`), `06-runtime.md` (OAuth-aware login discovery, SSO `action`,
device deletion refusal for OAuth sessions), `08-concepts.md` (coexistence of
the two auth APIs, deprecation path C20), `11-risks.md` (unbound raw JWT (u), lockless legacy rotation
(x), C15 take-over).

### Handover to story 9 (`/versions`, oracle O3/O5)

- Story 9's AC MUST flip `/versions` (v1.12-v1.15+) on the SAME predicate `Nebu.OAuth.oauth_aware?/0`
  (= `Nebu.OAuth.Http.live_state/0` `{:live, _}` = `auth_metadata` 200) that gates the OAuth-aware
  flags and `action` here; no second condition.
- Precondition of the story-9 flip (and at the latest of `oauth_enabled`): gate item (r) closed by
  the bugfix run `legacy-logout-per-device` (legacy `POST /logout` must delete the device and must not
  end the user's OAuth sessions on other devices; spec deviation, oracle O3). Also gate (w) / story 6
  (`account_management_uri`, device deletion for OAuth sessions).

### Out of scope

Account page and `m.oauth` UIA (6), `/versions` (9), device grant (7), mTLS (8), every follow-ups.md
gate item (1-4, h-q, r, s, t, story-3 (f), and the new u-x), enabling OAuth, refusing unbound raw JWTs (u), admin UI
changes beyond the delete error branch (v).

## Open questions

Resolved by the oracle gate (2026-10-10,
`_bmad-output/nebu/epics/oauth-broker/step-results/oauth-legacy-coexistence/oracle-context.md`):

- **O1 (C7/C8):** keep `403 M_FORBIDDEN` for OAuth callers at `DELETE /devices` / `/delete_devices`.
- **O2 (C4):** ignoring unknown `action` values is conformant; `register` => `prompt=create` is a Nebu
  extension, recorded in `docs/matrix-api-scope.md`.
- **O3 (gate r, follow-up f):** legacy unchanged in story 5 is acceptable; gate (r) is a real spec
  deviation and is closed by the bugfix run `legacy-logout-per-device` before the story-9 `/versions`
  flip, at the latest before `oauth_enabled` ("Handover to story 9").
- **O4 (C13):** refusing a JWT bound to a missing device is acceptable and required; CORRECTION folded
  into C11/AC6: a failed `register_device/4` in the legacy raw-JWT login => `500 M_UNKNOWN`.
- **O5 (C2/C5):** flags only while OAuth is offered (== `auth_metadata` 200), `m.login.sso` always
  offered; story 9 flips `/versions` on the same predicate.

Also folded in: corrections (a) unrouted endpoints assert 404 only (`M_NOT_FOUND` known deviation),
(b) unauthenticated `/register` 401-before-404 recorded, not pinned, (c) appservice note in the C7
code comment, (d) `account_management_uri` absent until story 6; the oracle's edge-case tests (AC1,
AC2, AC3, AC6, AC8; Must #32-#37). No open questions remain.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story, non-interactive, 2026-10-10)

### Debug Log References

- `quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth test/nebu/migration
  test/nebu/matrix test/nebu/web test/nebu/admin"` (first full pass): 3926/3970, 44 failures = 4 ADR/docs
  tests (written afterwards), 1 request-logger pin (see Completion Notes), the rest known families.
  After the fixes `test/nebu/oauth test/nebu/migration test/nebu/web/plugs` + the admin device and router tests:
  1543/1543 (the ADR wording fix was verified in the full run below).
- Full run, prod compile: see the Completion Notes (filled after the runs).
- matrix_compat node replay (optional): not executed (the ExUnit tests pin the flag and `action` shapes).

### Completion Notes List

- Ultimate context engine analysis completed - comprehensive developer guide created.
- No migration (000043 stays reserved for story 6). `oauth_enabled` stays default off.
- `Nebu.OAuth.Config.live_state/0` (new, public) is THE liveness predicate (`{:live, issuer}` | `:unknown` | `:off`);
  `Nebu.OAuth.Http` delegates to it and `Nebu.OAuth.oauth_aware?/0` (facade, `@doc`/`@spec`, never raises) is
  `match?({:live, _}, live_state())`, so the flags and `action` are present IFF `auth_metadata` answers 200.
- `GET /login`: `m.login.sso` carries `oauth_aware_preferred` and `org.matrix.msc3824.delegated_oidc_compatibility`
  (JSON `true`) only while OAuth is offered; otherwise the response is the pre-broker map (a config failure can
  never fail the endpoint).
- SSO `action` (`SsoLogin`): stable valid wins, invalid stable falls through to the unstable one, only exact
  `login`/`register`; honoured only for no `{idpId}` or `oidc` (an arbitrary `{idpId}` keeps today's behaviour,
  as the ATDD test pins) and only while `oauth_aware?/0` (asked only when an action is present); `prompt=create`
  iff the IdP document lists it AS A LIST (a string `"create"` does not count); `do_redirect/4` reads the discovery
  document once (no extra fetch). The UIA fallback and the OAuth leg are untouched.
- Device deletion: OAuth callers get `403 M_FORBIDDEN` as the first step of both handlers (`:auth_api` assign),
  `delete_one_device/3` uses `Nebu.Matrix.end_device_session/2` (atomic, story 4's `OAuthSession.end_device_session/2`)
  for every non-preserved device, the preserved own-device branch keeps today's steps (kill-switch with `except_hash:`);
  500 `M_UNKNOWN` on failure (`/delete_devices` attempts every id); admin controller: flash `:error` + audit `failure`/`delete_failed`.
- `/keys/upload`: the lazy bind runs first and is checked (403 G1 text, no write); legacy raw-JWT `POST /login`:
  a refused binding or a failed `register_device/4` => `500 M_UNKNOWN "Login failed, please try again."`; `register_device/4`
  returns `:ok | {:error, _}` (rescued), the opaque branch ignores it.
- C13: `TokenDenylist.revoke_by_hash/2 :: :ok | {:error, term}` (story 4's `revoke_by_hash_checked/2` merged into it, `{:error, :no_exp}`
  for nil exp); `DeviceBinding.kill_device_jwts/3` is the one kill-switch (also used by `OAuthSession.kill_bound_jwts/2`, which keeps
  never failing the grant); `DeviceBinding.lookup/1` refuses a binding whose device has an OAuth session OR no `devices` row;
  `DeviceBinding.put/4 :: :ok | {:error, :oauth_device}` with the compile-time guarded test seam `:device_binding_put_override`.
- C9: `refresh_auth_time/2` filtered to `auth_api = 'legacy'`.
- Logging (C6): the RequestLogger masks only the values of `action` / `org.matrix.msc3824.action` in the query-string capture of
  `/login/sso/redirect[/...]` (NOT names-only: the story-2 test pins that `redirectUrl` stays visible there).
- Deviations / notes: the `GET /account/3pid` row of `matrix-api-scope.md` claimed an empty-list stub but the route does not exist
  (test-verified 404): corrected to "absent". arc42 (05/06/08/11) left to the arc42 step. Follow-ups r and f carry the "not in story 5" notes.
- Docs: ADR-033 section "Legacy coexistence (story 5)" (C1-C20, touchpoint table, deprecation path, C8 rationale), T25 sentence, gate paragraph,
  rewritten Implications section; `docs/matrix-api-scope.md` rows + coexistence notes; `follow-ups.md` (story-5 section, rows u-x, r note).

### Review cycle 1 (code review 0 MAJOR / 6 MINOR, Kassandra L-1, L-2 LOW)

- MINOR 2: `sso_idp/1` matches the stripped `path_info` directly (`["sso","redirect",idp]`), so an idpId literally named
  `redirect` is an arbitrary idpId (action not honoured); test added.
- L-1: `POST /login` with a raw JWT checks the denylist (`403 M_FORBIDDEN`, no device registered); `DeviceBinding.put/4`'s conflict
  update only refreshes `exp` for the SAME (user, device) (`WHERE ... device_id = EXCLUDED.device_id`), a different target affects 0 rows and
  is refused (login => `500` under C11), so a binding kept by the kill-switch cannot be revived. Optional (3) (`lookup/1` refusing a binding
  older than the device row) not done. Tests: denylisted JWT login, no re-pointing via `put/4`, login with a bound JWT for another device.
- L-2 + MINOR 1: the SSO-redirect query capture masks the value of EVERY key starting (case-insensitively) with `action` /
  `org.matrix.msc3824.action` (incl. `action[]`, `Action`); `redirectUrl` stays visible. ADR C4/C6 describe this final behaviour. Test added.
- MINOR 3: the comment of `delete_one_device/3` and ADR C13 state the real fail-closed semantics of the preserved own-device path (the raw-JWT
  caller's binding is kept, the device row is gone, `lookup/1` refuses it after the 60 s cache TTL; not symmetric across token kinds); test of the
  post-TTL outcome added (401 "revoked", no soft_logout).
- MINOR 4: stale "static (no DB)" comment of `GET /login` corrected; `auth_metadata` now uses `Config.live_state/0` too (predicate parity by construction).
- MINOR 5: `05-building-blocks.md` and test prose no longer mention `revoke_by_hash_checked/2` / RED-phase text. MINOR 6: `matrix-api-scope.md` rows
  punctuated, the ADR touchpoint table columns labelled "as found" vs "after story 5".

### File List

- `server/lib/nebu/oauth.ex`, `oauth/config.ex`, `oauth/http.ex`
- `server/lib/nebu/matrix.ex`, `matrix/http_public.ex`, `matrix/sso_login.ex`, `matrix/oauth_session.ex`,
  `matrix/session/device_binding.ex`, `matrix/session/matrix_session_store.ex`
- `server/lib/nebu/web/router/protected.ex`, `web/token_denylist.ex`, `web/plugs/request_logger.ex` (review cycle 1 also: `docs/architecture/05-building-blocks.md`, test prose/tests in `oauth_device_teardown_test.exs`, `oauth_legacy_coexistence_test.exs`, `oauth_legacy_coexistence_static_test.exs`)
- `server/lib/nebu/admin/users_controller.ex`
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/matrix-api-scope.md`,
  `docs/stories/oauth-broker/follow-ups.md`, this story file
- ATDD files (staged before dev, unchanged): `server/test/nebu/oauth/oauth_{legacy_coexistence,device_teardown,legacy_coexistence_static}_test.exs`,
  extended `oauth_test_support.exs`, `adr_033_test.exs`, `oauth_resource_server_test.exs`, `oauth_token_refresh_grant_test.exs`,
  `server/test/nebu/admin/device_management_test.exs`, `server/test/nebu/matrix/matrix_router_test.exs`

## Change Log

- **2026-10-10:** Story created (create-story, non-interactive) for story 5 of epic oauth-broker:
  OAuth-aware login flags, SSO `action`, OAuth refusal at device deletion, UIA freshness legacy-only,
  coexistence audit with fixes C11-C15, decisions C1-C22, open questions O1-O5 (pre-amendment numbering).
- **2026-10-10 (scope amendment):** dropped the former C13 (legacy `/logout` per device) and C14
  (legacy `/login` device-id reuse invalidation) with their ACs, tests, traps and test changes
  (decision 6: legacy unchanged; gate (r) and follow-up (f) stay open, "not in story 5");
  decisions renumbered (C1-C20, former C15-C22 => C13-C20; ACs AC1-AC10); C13 (kill-switch) made
  minimal-blast-radius (`lookup/1` keeps its tuple shape, exact test call sites listed).
- **2026-10-10 (oracle-amended):** O1-O5 resolved (403 kept; unknown `action` ignored, `register`
  mapping a Nebu extension; gate (r) closed by bugfix `legacy-logout-per-device` before the story-9
  flip; failed `register_device/4` => 500 in the legacy raw-JWT login; flags == `auth_metadata` 200,
  story 9 on the same predicate); corrections (a)-(d); edge-case tests; "Handover to story 9".
- **2026-10-10 (atdd):** red-phase acceptance tests written (ATDD role, non-interactive) for AC1-AC10
  and Must #1-#37 (3 new test files, 7 extended files, story-5 helpers in `oauth_test_support.exs`);
  section "ATDD Decisions (story 5)" appended.

- **2026-10-10 (dev-story):** implemented C1-C20 / AC1-AC10 (no migration): OAuth-aware flags + `oauth_aware?/0`, SSO `action`,
  403 refusal at device deletion, atomic teardown, raw-JWT key write / login refusals, kill-switch consolidation, legacy-only UIA
  freshness, docs (ADR-033, matrix-api-scope, follow-ups u-x). Status `review`.

## ATDD Decisions (story 5)

Written by the ATDD role (2026-10-10, red phase). See the run line at the end of this section. All
calls into new code go through `apply/3`, so `--warnings-as-errors` compiles. The dev MUST implement
against these names; changing one means changing the tests in the same commit.

### Test files

New (`server/test/nebu/oauth/`): `oauth_legacy_coexistence_test.exs` (AC1 unit, AC2-AC5 and AC9
integration), `oauth_device_teardown_test.exs` (AC6-AC8), `oauth_legacy_coexistence_static_test.exs`
(C1, C7, C13). Extended: `adr_033_test.exs` (AC10), `test/nebu/admin/device_management_test.exs`
(C12 admin failure branch), `test/nebu/matrix/matrix_router_test.exs` (`GET /login` keys absent while
OAuth is not offered; green by design). Green-by-design regression describes: AC2 "not offered" /
junk / error order / discovery failure / UIA fallback, AC3 legacy callers and expired AT, AC5, AC9,
AC6 legacy/new device upload and the opaque/raw-JWT login regressions, AC8 normal binding and the
T7 failing-denylist case (story 4 already keeps the bindings there, see contradiction 1).

### Deliberately changed tests (Trap 6)

- `oauth_token_refresh_grant_test.exs` "refresh after DELETE /devices/{id} => invalid_grant" (OAuth
  caller deleting its OWN device) => "DELETE /devices/{id} by the OAuth session itself => 403, nothing
  deleted, refresh still works".
- `oauth_resource_server_test.exs` "DELETE /devices/{id} (fresh-auth window) removes the OAuth rows"
  => "... by the OAuth session itself => 403, the OAuth rows stay".
- `oauth_test_support.exs` `T.bound_jwt!/3` (C13 blast radius): upserts the `devices` row FIRST and
  adds a random `jti` (two JWTs minted in the same second stay distinct). Verified call sites: every
  `T.insert_jwt_binding!/4` caller and the direct INSERT in `oauth_resource_server_test.exs` ~214 bind
  to OAuth devices (they have a `devices` row); the story-4 `oauth_logout_test.exs` fixtures bind via
  `bound_jwt!/3` (now with a row) or seed device keys (row exists). No other fixture binds to a
  never-registered id. The story-4 R16 legacy `/logout` tests are unchanged.

### Pinned APIs / texts (beyond the story)

- `Nebu.OAuth.oauth_aware?/0` (`false` also when the `:oauth_config_source` fun RAISES; `GET /login`
  then still answers 200 without keys). `GET /login` body while not offered is byte-identical to
  `Jason.encode!/1` of today's map; while offered it is the same map with both keys `true` on the SSO
  flow.
- `action` precedence: stable valid wins; stable invalid => unstable; repeated key => Plug's LAST value
  (`action=login&action=register` => `prompt=create`). Ignored values tested: `""`, `REGISTER`,
  `Register`, `signup`, 33 bytes, a control character, `action[]=`, `action[x]=`. An arbitrary
  `{idpId}` is pinned RELATIVELY (same status/body as without `action`). Discovery failure = an IdP
  document without `authorization_endpoint` (the existing `:oidc_metadata_override`).
- `DeviceBinding.put/4 :: :ok | {:error, :oauth_device}`; `DeviceBinding.kill_device_jwts(uid, did,
  opts) :: :ok | {:error, :partial}` (`except_hash:` => that token is NOT denylisted);
  `TokenDenylist.revoke_by_hash/2 :: :ok | {:error, term}` (`{:error, :no_exp}` for nil exp, ETS insert
  always); `Nebu.Matrix.end_device_session/2 :: :ok | {:error, :unavailable}`;
  `Nebu.Matrix.delete_user_device/2 :: :ok | {:error, :unavailable}`.
- Texts: C7 403 body exactly `{"errcode":"M_FORBIDDEN","error":"Device deletion is not available for
  OAuth sessions; use the account management page."}`; C11 403 = the G1 text; login 500 exactly
  `{"errcode":"M_UNKNOWN","error":"Login failed, please try again."}`; C12 500 exactly
  `{"errcode":"M_UNKNOWN","error":"Device deletion failed, please try again."}`; admin failure: 302 +
  flash `:error` + audit `device_deleted` with outcome `"failure"` and error detail `"delete_failed"`.
- Docs (AC10 tests): ADR heading "Legacy coexistence (story 5)" with C1..C20, a `| Touchpoint |`
  table, both flag names, `M_FORBIDDEN`, "deprecat", `legacy_login_enabled`; the ADR contains "not
  changed by story 5" and "(C14: kept; follow-up u)"; the gate paragraph contains "Story 5 update",
  `legacy-logout-per-device`, `oauth_aware?/0`; the "Implications" section mentions `C20` and
  `auth_api`. matrix-api-scope rows: `GET /login` (`oauth_aware_preferred`), `GET
  /login/sso/redirect` (`action`, `org.matrix.msc3824.action`, `prompt=create`, "Nebu extension"),
  `DELETE /devices/{deviceId}` and `POST /delete_devices` (`403`, `M_FORBIDDEN`, OAuth), `POST
  /keys/upload` (OAuth), a note naming `account/deactivate` and `M_UNRECOGNIZED`. follow-ups: `##
  ... oauth-legacy-coexistence` section with `legacy-logout-per-device` and `RESOLVED`; rows `| u |`
  (raw), `| v |` (admin), `| w |` (account), `| x |` (`rotate_tokens` / lock).

### Seams (test support, section "Story 5")

- NEW `:nebu_http, :device_binding_put_override` (compile-time guarded, `Mix.env() == :test`):
  4-arity fun `(jwt, user_id, device_id, exp)` called INSTEAD of the guarded INSERT in
  `DeviceBinding.put/4`; its value is `put/4`'s result. Forces the C11 login race (`{:error,
  :oauth_device}`) deterministically.
- Privileged triggers (no production seam): `T.fail_denylist_db!/1` (INSERT of one hash into
  `invalidated_tokens` fails), `T.block_device_upserts!/1` (INSERT/UPDATE of `devices` rows of one
  user fails => failing `register_device/4`), story-4 `T.block_session_deletes!/1`.
- `T.forget_node_local_jwt_state!/1` deletes the ETS denylist entries (`{:hash, h}`, `{:jti, jti}`)
  and the `:nebu_jwt_device_binding_cache` entry ("another node").
- Helpers: `login_flows/1`, `sso_flow/1`, `sso_redirect/2`, `location_pairs/1`,
  `set_idp_prompt_values/1`, `legacy_login/4` (raw-JWT branch; `refresh_token: true` + `idp_rt:` for
  the opaque branch), `unbound_jwt!/2`, `binding_rows/2`, `uia_session!/3`, `uia_rows/1`,
  `raw_request/5`.
- Concurrency (AC7): the story-4 idiom (`devices` row `FOR UPDATE` held, `Task.yield(task, 500) ==
  nil`, hand-made rotation from a row captured BEFORE the task starts, because today's lockless
  delete removes the old row first).

### Contradictions / gaps with the story (resolved in the story text, test review 2026-10-10)

Folded into C12/C13/AC2/AC6/AC7/AC8 and the Dev Notes: (1) C13 (a) merges story 4's
`revoke_by_hash_checked/2` into `revoke_by_hash/2`, (b) lists `kill_bound_jwts/2` among the replaced
loops (keeping its rescue/catch envelope and WARNING), states the `exp == nil` semantic change (binding
kept, fail closed) and marks the T7 test a regression guard; (2) AC6 names the compile-time guarded
seam `:device_binding_put_override` (Files to modify + Architecture compliance); (3) AC2: repeated key
=> the LAST value; (4) AC7 keeps "attempts every id" and is tested (OAuth device blocked via
`T.block_session_deletes!(uid, auth_api: "oauth")`, the legacy device is still deleted); (5) C12:
flash key `:error`, audit detail `delete_failed`.

Test review follow-up (2026-10-10): added the mixed `/delete_devices` test, `kill_device_jwts/3`
WARNING / `except_hash:` row semantics / `exp == nil` kept, failing denylist in the preserved
own-device branch and in `/delete_devices`, `put/4` best effort on a DB error (`T.block_binding_inserts!/1`),
the opaque login branch ignoring a failed `register_device/4`, log hygiene on the new 500 paths;
strict 200 for the raw-JWT legacy caller, Location comparison for an arbitrary `{idpId}` 302, asserted
`delete_user_device/2` results; loosened static pins (comments stripped, `alias Nebu.OAuth.{...}`
caught, the refusal may be an OAuth-named helper, no layout literals); behavioural denylist checks
instead of ETS table names (only `T.forget_node_local_jwt_state!/1` still names them: no behavioural
way to simulate another node). Kept `apply/3` for `DeviceBinding.put/4`,
`Nebu.Matrix.delete_user_device/2` and `TokenDenylist.revoke_by_hash/2` where the test compares
against a NEW return value: the Elixir type checker warns ("comparison between distinct types") on a
direct call whose current spec is `:ok`, which `--warnings-as-errors` turns into a failure.

### Run

`quick.sh "mix test --include integration --warnings-as-errors test/nebu/oauth test/nebu/migration
test/nebu/matrix test/nebu/web test/nebu/admin/device_management_test.exs"` (after the test review):
3187 tests, 60 failures. 51 are story-5 tests (teardown 23, coexistence 15, static 5, ADR/docs 4, the 2
deliberately changed OAuth self-delete tests, the admin failure branch 1), all failing for the right
reason (missing functions/seam, no flags / `action` ignored, OAuth callers still delete devices,
UIA refreshes OAuth `auth_time`, raw JWT writes OAuth keys, refused bind / failed device upsert still
log in or raise, lockless teardown, bindings deleted after a failed denylist write, missing-device
binding not refused, admin controller MatchError, docs missing). The other 9 are unrelated and
order-dependent: 2 sync load tests and `MatrixSsoTest` loginToken (known.txt), the `OidcPlugTest`
denylist-on-reused-DB test (epic brief), and 6 `MatrixMutualRoomsTest` 429s (rate-limit bucket order;
the file passes alone, 19/19). An earlier run instead showed 2 `LogStore.RetentionTest` max-count
failures (LogStore family).
