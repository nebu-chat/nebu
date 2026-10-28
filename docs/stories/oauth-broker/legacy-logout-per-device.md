---
story_id: legacy-logout-per-device
title: "Legacy `POST /logout` ends only the presented credential's device (session rows, device, E2EE keys) under the locked per-device teardown; legacy `/refresh` takes the devices lock (gates r and x)"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 bugfix P6a of epic `oauth-broker`. Closes `follow-ups.md` gate item **(r)** (story-4 R16,
story-5 (c), story-9 bullet; BLOCKING before `oauth_enabled`) and the non-gating item **(x)**
(story-5 C12: legacy `rotate_tokens/1` takes no `devices` lock), because (x) is a small change on the
same code path (decision LL9).

Bug (verified on HEAD, `server/lib/nebu/web/router/protected.ex` ~l.271-361): for every caller whose
`:auth_api` is not `"oauth"` (legacy opaque token, raw IdP JWT bound or unbound), `POST
/_matrix/client/v3/logout` runs `legacy_logout/2`:

1. `revoke_access_token/1`: an opaque token goes to `MatrixSessionStore.revoke/1` (unlocked delete of
   every row of the token's device); a JWT is denylisted best effort (`TokenDenylist.revoke/3`);
2. then `EventDispatcher.Server.invalidate_user_sessions(%{user_id: user, device_id: ""})`
   (`server/lib/nebu/matrix/event_dispatcher/server.ex` ~l.1883): `destroy_session/1` (legacy
   `sessions`/`sync_tokens` + ETS of ALL devices) and `MatrixSessionStore.delete_for_user/1`, which
   deletes EVERY `matrix_sessions` row of the user, **OAuth rows on other devices included**. Those
   OAuth devices keep their `devices` row and keys (orphaned: no session, the client is logged out
   without being told why);
3. the caller's own device and its E2EE keys are NOT deleted; the answer is always `200 {}`.

Matrix CS API v1.18 (`skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html`
`#post_matrixclientv3logout`): "Invalidates an existing access token, so that it can no longer be
used for authorization. The device associated with the access token is also deleted. Device keys for
the device are deleted alongside the device." 200 = "The access token used in the request was
successfully invalidated." `POST /logout/all` invalidates all tokens of the user and deletes all
devices (unchanged by this story). The OAuth branch (story 4, R15) is already conformant.

## Story

As a **user signed in to Nebu on several devices, some through a legacy client and some through an
OAuth-aware client**,
I want "Sign out" in one client to end only that client's session and remove only its device,
so that my other devices keep working, no orphaned device with stale E2EE keys stays behind, and a
leaked token of the signed-out client is useless afterwards.

## Decisions

Prefix `LL` (no collision with D/T/R/C/A/V/TP in ADR-033). ADR-033 gets a section with LL1-LL12 (AC11).

- **LL1 (scope: the presented credential's device, nothing else).** A legacy `/logout` ends exactly
  the device the presented credential is bound to SERVER-side (opaque: `matrix_sessions.device_id`
  of the presented row; bound raw JWT: `jwt_device_bindings.device_id`; both already assigned by
  `OidcPlug` as `:device_id`, never request input). It never touches another device's rows, of any
  `auth_api`, and never the user-wide `invalidate_user_sessions`.
- **LL2 (device deletion = Matrix device deletion).** The device is torn down with the SAME atomic,
  locked teardown as `/oauth2/revoke`, OAuth `/logout`, `DELETE /devices` and the account page:
  devices-row lock, every `matrix_sessions` row of `(user, device)` (the presented row, its pending /
  consumed rotated siblings, and any other legacy row of a reused device id, story-3 (f)), device
  keys, one-time keys, fallback keys, `devices` row; after the commit the JWT kill-switch of the
  device and the per-device legacy `sessions`/`sync_tokens`. Cross-signing keys (per user) stay. All
  credentials of the device die with it (Matrix: a deleted device has no valid token).
- **LL3 (re-check under the lock; never kill a newer session).** After the devices lock the
  transaction re-checks that the presented credential still belongs to that device:
  opaque: `SELECT 1 FROM matrix_sessions WHERE access_token_hash = $1 AND auth_api = 'legacy' AND
  user_id = $2 AND device_id = $3` (ANY state: active, soft-revoked pending or consumed, like R3);
  bound JWT: the binding row `(token_hash, user, device)` exists AND the `devices` row exists AND the
  device has NO `auth_api = 'oauth'` row. A miss (an OAuth login took the device id over, story-3 T7;
  a concurrent logout / device deletion won) => nothing is deleted, `{:ok, :unknown}`, answer `200 {}`
  (the presented credential is already invalid, see LL7). The opaque re-check deliberately does NOT
  exclude a device that also holds an OAuth row (only possible transiently): deleting a device kills
  ALL its tokens (Matrix "Relationship between access tokens and devices", `DELETE /devices`), so
  this conforms (oracle O3).
- **LL4 (raw JWT bound to a device).** Order: (1) the locked teardown (LL2/LL3); a storage failure
  (`{:error, _}`) => `500 M_UNKNOWN`, nothing changed, the JWT still works, the client may retry;
  (2) the CHECKED denylist of the presented JWT (`checked_revoke_jwt/1`: jti key, hash fallback) runs
  on EVERY non-error result, i.e. on `{:ok, :ended}` AND on `{:ok, :unknown}` (oracle O1: after an
  OAuth take-over the binding deletion is best effort, so the presented JWT must be denylisted
  explicitly); a failed DB write => `500 M_UNKNOWN` (the ETS entry of this node is written; on every node the
  binding is refused because the `devices` row is gone, C13 c, except for the 60 s binding cache of
  other nodes; the post-commit kill-switch keeps the binding fail-closed). Never a silent `200` with
  a live credential.
- **LL5 (unbound raw JWT, `:device_id` nil).** No device to delete and no session row: the presented
  JWT is denylisted CHECKED until its `exp` (jti key, hash fallback), nothing else is touched (no
  other device, no user-wide wipe). DB write failure => `500 M_UNKNOWN` (ETS entry kept: dead on this
  node). Rationale: the old wipe was the only "effect" for such tokens and it hurt every other device;
  follow-up (u) (refuse unbound JWTs) is unchanged.
- **LL6 (legacy opaque token).** One call of the new facade function (LL10); `:ended` and `:unknown`
  => `200 {}`; `{:error, :unavailable}` => `500 M_UNKNOWN` "Logout failed, please try again." (the
  OAuth branch's message), the session survives completely (rolled back). An opaque legacy row with
  an empty device id (defensive; `matrix_sessions.device_id` is set by every writer) deletes only the
  presented row (by its hash, in the same transaction) and no device.
- **LL7 (idempotence).** A replay of the logged-out token never reaches the handler: opaque => `401
  M_UNKNOWN_TOKEN` (row gone, no `soft_logout`), JWT => `401 M_UNKNOWN_TOKEN` "Access token has been
  revoked" (denylist / refused binding). Two CONCURRENT logouts with the same credential both answer
  `200 {}`; exactly one tears down (the other re-check misses).
- **LL8 (best-effort contract of R16 is replaced).** The legacy `/logout` now reports storage failures
  (`500 M_UNKNOWN`) like the OAuth branch (R15) and `/logout/all` (R17). The request body stays
  ignored (empty, absent, `{}`, invalid JSON => same behaviour, story-4 ATDD decision). No rate limit
  (spec: not rate-limited). No audit row (R21 / C19 consistency).
- **LL9 (gate x fixed here: legacy rotation takes the devices lock).** `MatrixSessionStore.rotate_tokens/1`
  first reads `user_id, device_id` of the old row (`access_token_hash = old_h AND auth_api =
  'legacy'`, no lock; no row => rollback `:not_found`, unchanged `:error` result) and takes `SELECT 1
  FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE` BEFORE the guarded soft-revoke
  UPDATE (the OAuth `lock_device_of/2` pattern). Lock order everywhere: devices -> matrix_sessions
  (`mark_access_token_used/1`, `extend_in_place*/3` and `delete_for_user/1` lock only
  matrix_sessions rows and never wait for a devices row: no cycle). A missing devices row locks
  nothing (unchanged, same as OAuth). Effect: a teardown and a legacy `/refresh` of the same device
  serialise; when the teardown wins, the UPDATE matches 0 rows, the caller re-resolves and answers
  `401 M_UNKNOWN_TOKEN`; when the rotation wins, the teardown's DELETE (a new statement after the
  lock) also deletes the new row. No working token survives a deleted device.
- **LL10 (ADR-020 surface).** New facade `Nebu.Matrix.legacy_logout_device/1` taking
  `%{kind: :opaque | :jwt, token: String.t(), user_id: String.t(), device_id: String.t()}` and
  returning `{:ok, :ended} | {:ok, :unknown} | {:error, :unavailable}`; never raises (rescue/catch
  like `end_device_session/2`). Implementation: `Nebu.Matrix.OAuthSession.end_legacy_device/1`
  (calls the store, then `after_commit/2` on `:ended`) and
  `OAuthSessionStore.end_legacy_device(kind, token, user_id, device_id, repo \\ repo())` (the
  transaction of LL2/LL3; the token is hashed INSIDE, pass-the-hash rule; the `:oauth_session_repo`
  test seam applies). `protected.ex` keeps only routing and the JWT denylist call.
- **LL11 (`/logout/all` unchanged).** The old `legacy_logout/2` body (presented-token revoke +
  user-wide `invalidate_user_sessions`) is renamed `legacy_user_wipe/2` and is used ONLY by
  `/logout/all` (byte-identical behaviour, R17, I-14 stays open). `invalidate_user_sessions/2` itself is
  not changed (admin deactivation keeps the user-wide wipe).
- **LL12 (out of scope, recorded).** `device_lists.changed` for peers on device deletion does not
  exist in Nebu and is not added here; follow-up (s) was RE-CLASSIFIED as a gate item before
  `oauth_enabled` for ALL deletion paths (oracle O2, Doc edits 2; SUPERSEDED 2026-10-13, epic SEC gate 3 G3-4: re-scoped to "before encrypted rooms are allowed / any E2EE claim"). Queued to-device messages / txn ids
  of the deleted device: see the note "Device-scoped leftovers" (oracle O5). Legacy-to-legacy device reuse (story-3
  (f)) is not changed; LL2 merely ends all credentials of the device. Logging: one INFO line
  `legacy logout` with `user_id`, `device_id`, `kind=opaque|jwt_bound|jwt_unbound`,
  `outcome=ended|unknown|failed`; never a token, hash or jti.

## Acceptance Criteria

### AC1 Two devices, legacy logs out, OAuth survives (gate r core)
Given user U with device L (legacy opaque session, device keys + one-time keys + fallback key seeded)
and device O (OAuth session of an approved client, its own keys), when `POST /logout` is called with
L's access token:
1. answer `200 {}` with `Content-Type: application/json`;
2. `matrix_sessions` has no row for `(U, L)`; `devices`, `device_keys`, `device_one_time_keys`,
   `device_fallback_keys` have no row for `(U, L)` (`T.device_gone?/2`); `POST /keys/query` by
   another user no longer returns L; U's `GET /devices` (with O's token) does not list L;
3. O is untouched: `T.rows_snapshot(U, O)` and `T.device_state(U, O)` equal the values before the
   call; `GET /account/whoami` with O's access token => `200` with `device_id = O`; an OAuth refresh
   with O's refresh token succeeds;
4. cross-signing keys of U are unchanged.

### AC2 Two devices, OAuth logs out, legacy survives (story-4 regression)
Same fixture; `POST /logout` with O's access token: `200 {}`, `(U, O)` rows and device gone (R15),
L's rows/device/keys unchanged, L's access token `200` on whoami, L's legacy `/refresh` succeeds.

### AC3 Replay and refresh after logout
After AC1: L's access token on whoami and on `POST /logout` => `401 M_UNKNOWN_TOKEN` without
`soft_logout`; legacy `POST /refresh` with L's refresh token => `401 M_UNKNOWN_TOKEN`; a rotated-away
(pending) refresh token of L from before the logout => `401 M_UNKNOWN_TOKEN` (LL2 deletes the
siblings). Every 401 of this AC has NO `soft_logout: true` (absent or false; oracle O4). After AC2:
O's access token => `401 M_UNKNOWN_TOKEN` (R20), `POST /oauth2/token` with O's refresh token =>
`400 invalid_grant`.

### AC4 Two legacy devices
U with legacy devices L1, L2 (+ an unrelated user V with a legacy device): logout with L1's token
ends only `(U, L1)` (rows + device + keys); L2 and V are unchanged and their tokens work.

### AC5 Bound raw IdP JWT
U with device J (raw JWT bound via `DeviceBinding.put/4`, `devices` row, keys) and device O (OAuth):
1. `POST /logout` with the JWT => `200 {}`; `(U, J)` device tables empty, no binding row of `(U, J)`,
   the JWT => `401 M_UNKNOWN_TOKEN` on this node and after `T.forget_node_local_jwt_state!/1` (DB
   denylist / refused binding: cluster-wide);
2. a second JWT bound to the same device J (legacy reuse) is also refused afterwards;
3. O unchanged (snapshot), O's token works.

### AC6 Unbound raw IdP JWT (LL5)
U with an unbound JWT (`T.unbound_jwt!/2`), a legacy device L and an OAuth device O: logout with the
unbound JWT => `200 {}`; the JWT => `401` (also after `forget_node_local_jwt_state!/1`); every row of
L and O and every device of U is unchanged (`T.world_snapshot([U])` equal except the denylist).

### AC7 Failures are reported, nothing half-done (LL4-LL6, LL8)
Every `500` body is the standard error JSON (`errcode` `M_UNKNOWN`, `error`), never a partial teardown.
1. Opaque legacy: with the session repo seam failing (`:oauth_session_repo` NoSuchRepo, or
   `T.block_session_deletes!(U, auth_api: "legacy")`, or `T.block_deletes!("device_keys", U)`) =>
   `500 M_UNKNOWN`; the session row, device and keys are all still there and the token works
   (rollback); after removing the block a retry => `200`, device gone.
2. Bound JWT: teardown blocked => `500`, binding and device intact, JWT works; denylist DB write
   blocked (privileged trigger on `invalidated_tokens` for the jti key) after a successful teardown
   => `500`, device gone, JWT `401` on this node.
3. Unbound JWT with the denylist DB write blocked => `500 M_UNKNOWN`; JWT `401` on this node (ETS);
   no other row of U changed.

### AC8 Concurrency (LL3, LL9)
1. **Logout waits for the lock:** a test transaction holds `SELECT 1 FROM devices WHERE (U, L) FOR
   UPDATE`; a legacy logout of L in a Task does not finish within 500 ms; after commit it answers
   `200` and `(U, L)` is gone.
2. **OAuth take-over while waiting:** while the logout waits (as 1), the lock-holding test
   transaction itself replaces L's legacy rows by an OAuth row for device L (the effect of
   `insert_replacing_device/1`; a real issuance on another connection would block on the same lock)
   and commits; the logout then answers `200`, deletes NOTHING (re-check miss), and the OAuth row and
   the device of L are intact. **Bound-JWT variant (oracle O1):** device J with a bound JWT, the
   same take-over of J by an OAuth row (binding row left in place); logout with the JWT => `200`,
   nothing deleted, and the JWT is `401` on this node AND after `T.forget_node_local_jwt_state!/1`
   (DB denylist, cluster-wide).
3. **Legacy refresh waits for the lock (x):** the test transaction holds the devices lock of `(U, L)`;
   `T.legacy_refresh(L.rt)` in a Task does not finish within 500 ms (IdP re-validation stubbed OK).
4. **Teardown wins over refresh:** inside the lock-holding transaction the test deletes every
   `matrix_sessions` row of `(U, L)` and the device tables (or calls the teardown on that connection),
   commits; the waiting refresh answers `401 M_UNKNOWN_TOKEN` and `T.session_rows(U, L) == []`
   (before LL9 the new row survived).
5. **Refresh wins over logout:** the refresh commits first (rotation), a logout authenticated with
   the OLD access token before the rotation (simulate: call the facade with the old token after the
   rotation) ends the device: the new access and refresh tokens are `401`.
6. **Concurrent double logout:** two Tasks call `POST /logout` with the same L token; both `200`,
   device gone, no exception, no deadlock (both finish within 10 s).
7. **OAuth unaffected:** the existing OAuth rotation lock tests (`oauth_device_teardown_test.exs`,
   `oauth_token_refresh_grant_test.exs`) stay green.

### AC9 `/logout/all` and other paths unchanged (LL11)
1. Every existing `/logout/all` test in `oauth_logout_test.exs` stays green unchanged (all sessions
   and devices of the user end, `500` on a failed checked part, the legacy part still wipes
   user-wide).
2. Admin deactivation (`invalidate_user_sessions` with `device_id: ""`), `DELETE /devices/{id}`,
   `/delete_devices`, `/oauth2/revoke`, the account-page device deletion: existing tests green.
3. OAuth `/logout` (R15) unchanged: existing tests green.
4. The request body is still ignored for legacy callers (none / empty JSON / `{}` / invalid JSON =>
   `200 {}` and the per-device effect).

### AC10 Logging (Law: no sensitive data in logs)
`capture_log` over AC1, AC5, AC6, AC7: exactly one INFO `legacy logout` line per call with
`kind` and `outcome`; the log contains neither the access token, the refresh token, the JWT, any
SHA-256 hex of them, nor the jti.

### AC11 Documentation (exact edits, see Dev Notes "Doc edits")
All edits of Dev Notes "Doc edits" are made; `adr_033_test.exs` pins (old and new) are green.

## Acceptance Tests

- NEW `server/test/nebu/oauth/legacy_logout_per_device_test.exs` (`@moduletag :integration`,
  `async: false`, alias `Nebu.OAuth.TestSupport, as: T`, setup like `oauth_logout_test.exs` l.28-40):
  AC1-AC8, AC10.
- CHANGED `server/test/nebu/oauth/oauth_logout_test.exs`: the describe "AC8/R16/Must #29 — legacy
  /logout unchanged" (~l.201-250) is rewritten to the new contract (opaque: only the own device ends,
  the device is deleted; the six body variants keep `200 {}` + `401` replay; raw JWT denylisted and
  device deleted); the test "a failed DURABLE denylist insert ... legacy /logout stays best effort
  (R16)" (~l.592) keeps its `/logout/all` half and asserts `500` for the legacy half (LL5); moduledoc
  l.10-11 updated. `/logout/all` tests unchanged (AC9.1).
- CHANGED `server/test/nebu/oauth/adr_033_test.exs`: new pins for the LL section headline and
  LL3/LL5/LL9 keywords; the R16 pin (l.264-269) and story-5 pins (l.333-345) must stay satisfiable
  (wording in AC11).
- Regression, green unchanged (under `server/test/nebu/`): `matrix/matrix_router_test.exs` l.610-642,
  `matrix/session/token_hashing_test.exs` l.844-870, `web/oidc_plug_test.exs` l.677,
  `matrix/event_dispatcher/invalidate_user_sessions_test.exs`, `matrix/login_refresh_test.exs` (race
  retries with the new lock), `oauth/*` (incl. `oauth_resource_server_test.exs` l.388,
  `oauth_token_refresh_grant_test.exs` l.249).
- Gherkin (written, typechecked, `bddgen` only; cannot run in the isolated env): NEW
  `e2e/features/element/legacy-logout-per-device.feature`, tag `@legacy-logout-per-device`:
  alex logged in via Element Web in browser contexts A and B (two devices); alex signs out in A =>
  A shows the welcome screen, B still shows the room list after a reload and B's session list no
  longer contains A's device. Reuse the `@ac6-logout` steps of `e2e/features/element/login.feature`.

## Must be test-covered

AC1-AC10 each need at least one test; the critical ones: per-device effect incl. keys (AC1, AC4),
cross-API isolation (AC1, AC2), replay/refresh refusal (AC3), bound vs unbound JWT (AC5, AC6), rollback
on failure (AC7), re-check under the lock (AC8.2), refresh vs teardown (AC8.3-8.5), log hygiene (AC10).

## Dev Notes

### Current state (read before coding)

- `protected.ex` `post "/client/v3/logout"` (~l.271-284): `:auth_api == "oauth"` =>
  `Nebu.Matrix.oauth_revoke_token/1` (keep as is); else `legacy_logout/2` + unconditional `200`.
  `post "/client/v3/logout/all"` (~l.293-319) calls `legacy_logout/2` inside a try (keep, renamed).
  `checked_revoke_jwt/1` ~l.323, `legacy_logout/2` ~l.340, `revoke_access_token/1` ~l.363,
  `revoke_jwt_access_token/2` ~l.377.
- `OidcPlug` (`server/lib/nebu/web/plugs/oidc_plug.ex`): opaque path ~l.74-125 assigns
  `:access_token`, `:current_user`, `:device_id` (row), `:auth_api` (row: `"legacy"|"oauth"`),
  `:oidc_claims = %{}`; soft-revoked or expired rows never reach the handler (`401` +
  `soft_logout`). JWT path ~l.130-160: `DeviceBinding.lookup/1` (60 s per-node cache) => refused =>
  `401`; else assigns `:device_id` (nil when unbound), `:auth_api "legacy"`, `:oidc_claims`.
- `OAuthSessionStore.end_session_for_token/1` (~l.398) is the template for the new
  `end_legacy_device/5`: copy its structure (plain SELECT not needed: user/device come from the
  assigns; lock; re-check SQL per kind; `delete_device_rows!/3`). `query!/3` raises inside the
  transaction (rollback), the outer rescue maps to `{:error, _}`.
- `MatrixSessionStore.rotate_tokens/1` (`server/lib/nebu/matrix/session/matrix_session_store.ex`
  ~l.280-383): the transaction starts with the guarded soft-revoke UPDATE (step 1); LL9 inserts the
  read + devices lock before it. Its private `query/2` (~l.748) returns tuples (does not raise): use
  `{:ok, %{rows: ...}}` matches and `Nebu.Repo.rollback/1`. The caller `HttpPublic.rotate_attempt`
  (`server/lib/nebu/matrix/http_public.ex` ~l.820-905, seam `:matrix_refresh_rotate_override`)
  already re-resolves on `:error`; no change there.
- `DeviceBinding` (`server/lib/nebu/matrix/session/device_binding.ex`): table
  `jwt_device_bindings(token_hash, user_id, device_id, exp, created_at)`; `hash/1` ~l.249;
  `kill_device_jwts/3` ~l.204 (run by `after_commit/2`).
- `TokenDenylist.revoke_checked/3` (`server/lib/nebu/web/token_denylist.ex` ~l.113): DB key `jti:<jti>`
  when a jti exists, else the SHA-256 hex. `T.fail_denylist_db!/1` matches `token_hash = <hex>`
  only: for jti-carrying test JWTs block `'jti:' || <jti>` (ATDD role writes the trigger helper or
  signs a JWT without jti).

### Implementation sketch

1. `OAuthSessionStore.end_legacy_device(kind, token, user_id, device_id, repo \\ repo())`:
   `h = MatrixSessionStore.hash_token(token)` (opaque) or `DeviceBinding.hash(token)` (jwt; same
   digest); transaction: `lock_device/3`; re-check SQL (LL3); miss => `:unknown`; hit =>
   `delete_device_rows!/3` => `:ended`. Empty `device_id` (opaque only, LL6): `DELETE FROM
   matrix_sessions WHERE access_token_hash = $1 AND auth_api = 'legacy'` and `:ended` without device
   tables. Returns `{:ok, :ended} | {:ok, :unknown} | {:error, reason}`; never raises.
2. `Nebu.Matrix.OAuthSession.end_legacy_device(%{kind:, token:, user_id:, device_id:})`: calls 1,
   `after_commit(user_id, device_id)` on `:ended` (non-empty device), WARNING on error (no token),
   `{:error, :unavailable}`.
3. Facade `Nebu.Matrix.legacy_logout_device/1` with `@doc`/`@spec` (LL10), rescue/catch.
4. `protected.ex`: rename `legacy_logout/2` => `legacy_user_wipe/2` (only `/logout/all` calls it);
   new `legacy_device_logout(conn)`:
   - opaque token (no `.`): `device_id` binary => facade `:opaque`; result => `200 {}` / `500`.
   - JWT with binary non-empty `device_id`: facade `:jwt`; `{:error, _}` => `500` (stop); on
     `:ended` OR `:unknown` `checked_revoke_jwt(conn)`; `:error` => `500`; else `200 {}`.
   - JWT with nil `device_id`: `checked_revoke_jwt(conn)` => `200` / `500`.
   - INFO log line (LL12) in the handler or in `OAuthSession`, once per call.
   Update the comment block above the route (R15/R16 text -> LL1-LL8).
5. `rotate_tokens/1` LL9 (and its moduledoc paragraph "Token rotation"): add "takes the devices-row
   lock first (lock order devices -> matrix_sessions, gate x)".
6. Moduledocs: `Nebu.Matrix.OAuthSession` (revocation paragraph), `MatrixSessionStore` "Legacy rows
   only" (logout now per device via the facade), the `invalidate_user_sessions` comment in
   `event_dispatcher/server.ex` ~l.1870-1880 (it claims "Matrix POST /logout: device_id=<id>"; it is
   no longer called by `/logout`, only by deactivation and `/logout/all`).

### Files to modify

`protected.ex`, `matrix.ex`, `oauth_session.ex`, `session/oauth_session_store.ex`,
`session/matrix_session_store.ex`, `event_dispatcher/server.ex` (comment) under `server/lib/nebu/`; tests
and docs as listed. No migration, `server_config` key, env var or new seam (`:oauth_session_repo`
exists; a new one only if a failure cannot be forced otherwise, compile-time guarded).

### What must be preserved

- OAuth `/logout` (R15), `/oauth2/revoke`, `/logout/all` (R17, F-1/F-2), deactivation, GDPR erasure,
  device deletion (C7/C12), the account page teardown (A13): behaviour and tests unchanged.
- `OidcPlug` unchanged (auth-time decision of `:auth_api`, Trap 4 of story 4: never decide by a
  lookup in the handler; LL3's re-check only narrows, it never widens to another device).
- Legacy `/refresh` semantics (valid-until-used, replay, bounded reuse detection, race retries,
  503 on exhaustion) unchanged apart from the lock wait.
- `oauth_enabled` stays false; nothing here flips it.

### Traps

1. Never `MatrixSessionStore.revoke/1`, `delete_for_user_device/2` or `Nebu.Matrix.end_device_session/2`
   on the new path: unlocked, or without the re-check (AC8.2 would delete the OAuth take-over).
2. The JWT re-check needs "no OAuth row on the device": OAuth issuance deletes bindings only AFTER
   its commit (best effort).
3. Lock order devices row -> matrix_sessions in all new code.
4. Keep both the post-commit kill-switch and the explicit checked revoke (`ON CONFLICT DO NOTHING`
   makes them compatible; only the explicit one gives the status, LL4).
5. Per test `T.unique_sub/0`, `async: false`.

### Doc edits (exact)

1. `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`:
   - new section `## Legacy logout per device (bugfix legacy-logout-per-device)` before
     `## Gate items before ...` with LL1-LL12 (one bullet each, condensed);
   - R16 bullet (~l.508) replaced by: "**R16 Legacy `POST /logout` (the recorded deviation) is RESOLVED
     by the bugfix legacy-logout-per-device (LL1-LL12):** it ends only the presented credential's
     device with the locked teardown, like R15; the `/logout` deviation no longer exists." (keeps
     `R16`, `deviation`, `/logout` on one line for the l.268 pin);
   - R17 last sentence (~l.515) "The legacy `/logout` keeps its best-effort contract (R16)." =>
     "The legacy part of `/logout/all` keeps its best-effort contract (LL11)."
   - append to the story-9 update (~l.728) a sentence "Bugfix legacy-logout-per-device: gate item (r)
     closed (LL1-LL12); follow-up (x) closed (LL9)." Leave the story-4/5 update paragraphs as history
     (the story-5 pins need "not changed by story 5" and "legacy-logout-per-device").
2. `docs/stories/oauth-broker/follow-ups.md`: row (r) (~l.135): prefix "**RESOLVED by bugfix
   legacy-logout-per-device (LL1-LL12):**", Gate column "closed"; story-5 bullet (c) (~l.154) and the
   story-9 bullet (~l.212): append "RESOLVED (bugfix legacy-logout-per-device)"; row (x) (~l.164):
   prefix "**RESOLVED by bugfix legacy-logout-per-device (LL9)**", Gate "closed"; I-14 (~l.145):
   append "(r) is done; `/logout/all`'s legacy part stays best effort (LL11), still open". Append a
   section `## From bugfix legacy-logout-per-device (2026-10-12)` containing: (a) row (s) (~l.136)
   Gate column changed from "non-gating, epic-end review" to "**before `oauth_enabled`** (oracle
   gate legacy-logout-per-device O2): every device-deletion path (legacy and OAuth `/logout`,
   `/logout/all`, `/oauth2/revoke`, `DELETE /devices`, `/delete_devices`, account page, admin,
   take-over, client revocation (aj)) must put the user into the peers' `device_lists.changed`";
   (b) a new row with the next free letter (`bd` at ATDD time: `ao`-`bc` are taken by P1-P4; take the next free one if P6b added rows meanwhile): "**Txn-id dedup is per user, not per
   device, and node-local** (`:NebuTxnDedup` ETS `{room_id, user_id, txn_id}`, no pruning,
   `room/server.ex` ~l.472/726): Matrix scopes txn ids per device; a deleted device's txn id can
   suppress a later send of the user on that node. No to-device inbox exists (`sendToDevice` unrouted), so no queued to-device messages
   survive a deletion. | oracle O5 (legacy-logout-per-device) | non-gating, epic-end review |".
   Also update the 07-deployment gate table: add a row `s` "`device_lists.changed` on every device
   deletion" | open | server, and remove "(s) `device_lists.changed` on device deletion," from the
   non-gating list (~l.201).
3. `docs/architecture/07-deployment.md`: gate table row `r` (~l.192): What = "Legacy `POST /logout`
   per device", Status = "closed by bugfix legacy-logout-per-device", keep Owner `server`; the
   non-gating list (~l.201): remove "(x) legacy `rotate_tokens/1` lock," (closed). Any line that
   lists the gate items "1, 2, 4, h, i, l, m, n, r, y, ac, ag" in 07-deployment stays as history only
   if it is labelled "at story-9 time"; otherwise drop `r`.
4. `docs/matrix-api-scope.md`: row `POST /_matrix/client/v3/logout` (~l.45): replace the legacy part
   by "legacy tokens (opaque or raw JWT bound to a device): end ONLY the presented credential's device
   (all its session rows, the device, its device / one-time / fallback keys) with the same locked
   teardown; an unbound raw JWT is only denylisted; a storage failure => `500 M_UNKNOWN`
   (bugfix legacy-logout-per-device)"; paragraph ~l.308: replace the sentence "`POST
   /_matrix/client/v3/logout` for legacy tokens is still the user-wide wipe ... (gate item r ...)" by
   "Legacy `POST /logout` is per device since the bugfix legacy-logout-per-device (gate item r
   closed)."

### P3/P4 adaptation (ATDD, 2026-10-12)

The code moved on after this story was written; re-read on HEAD (c7369154), nothing below changes a Decision:

- **Locations unchanged:** `protected.ex` logout routes (~l.271-361), `rotate_tokens/1` (~l.280, step 1 is still the guarded UPDATE),
  `OAuthSessionStore.lock_device/3` + `delete_device_rows!/3` (private, ~l.735-745; `end_device/3` is the closest template),
  `Nebu.Matrix.OAuthSession` / facade `Nebu.Matrix` (new function next to `oauth_revoke_token/1`).
- **P3:** the refresh lease table `oauth_idp_refresh_leases` references `devices ON DELETE CASCADE` (a deleted device drops its lease; legacy
  devices have none); `insert_replacing_device/1` gained the device holder check; OAuth sessions are created through the consent flow
  (`T.session!/4` hides it). None of this touches the legacy path. The take-over of AC8.2 is simulated by SQL in the lock-holding transaction
  (as `oauth_device_teardown_test.exs` does for rotations), not through issuance.
- **P4:** lock order is now `oauth_clients -> devices -> matrix_sessions` (client revocation locks the client row first). The legacy teardown
  takes `devices -> matrix_sessions` only and never the client lock (legacy rows have no client): no cycle. `oauth_end_client_sessions/2`,
  `oauth_after_device_teardown/1` and `oauth_end_all_sessions/0` exist; `legacy_logout_device/1` is a SEPARATE facade function (not a mode of them).
- **Docs:** follow-ups letters `ao`-`bc` are used, so the new row is `bd` (Doc edits 2 (b)); the ADR keeps `Gate items before ...` at ~l.696 (the new
  section goes right before it); 07-deployment row `r` and the non-gating list are at ~l.208/l.217.
- **Test helpers added** to `oauth_test_support.exs`: `fail_denylist_key!/1` (privileged trigger for a `jti:<jti>` or hex denylist key; the
  jti-carrying JWTs of `bound_jwt!/3` / `unbound_jwt!/2` are NOT blocked by `fail_denylist_db!/1`), `jwt_jti/1`, `denylist_db_count/1`.
- **Existing pins changed:** `adr_033_test.exs` story-9 non-gating list no longer expects `(s)` and `(x)` (they leave the list, Doc edits 2/3);
  `oauth_logout_test.exs` legacy block rewritten (see Acceptance Tests).

### Architecture compliance

ADR-018 inline SQL; ADR-020 `Nebu.Web` calls only the `Nebu.Matrix` facade; cluster-safe (row locks +
DB denylist; ETS denylist / binding cache only accelerate); no OIDC scope change; no tokens in logs.

### Testing commands (isolated env, see the epic brief)

`quick.sh "mix test --include integration test/nebu/oauth test/nebu/matrix/session test/nebu/matrix/login_refresh_test.exs test/nebu/matrix/matrix_router_test.exs test/nebu/web/oidc_plug_test.exs"`,
then `integration.sh` in the background (compare with `known.txt` by family); e2e: `tsc --noEmit` +
`bddgen --tags @legacy-logout-per-device` from a scratchpad copy of `e2e`.

### Out of scope

(s), (u), story-3 (f), I-14 (see LL11/LL12); room summary (ac/af) is story P6b.

### Device-scoped leftovers (oracle O5, inspected)

Teardown + `after_commit/2` cover every device-scoped table (`matrix_sessions`, four device tables,
JWT bindings, `sessions`/`sync_tokens`); no to-device inbox exists (`sendToDevice` unrouted). Txn-id
dedup (`:NebuTxnDedup` ETS, per user, node-local) is a pre-existing deviation: follow-up (Doc edits 2 (b)).

### Oracle gate (2026-10-12, no BLOCKER)

| # | Severity | Correction | Applied in |
|---|---|---|---|
| 1 | MAJOR | Denylist the bound JWT also on `{:ok, :unknown}` | LL4, AC8.2 bound-JWT variant |
| 2 | MAJOR | (s) gate before `oauth_enabled` for all deletion paths; manual step records | LL12, Doc edits 2 (a) + 07-deployment, Manual 2 |
| 3 | MINOR | Opaque re-check asymmetry conforms | LL3 |
| 4 | MINOR | Pending RT => `401 M_UNKNOWN_TOKEN`, no `soft_logout: true` | AC3 |
| 5 | MINOR | To-device / txn ids of the deleted device | note above, Doc edits 2 (b) |
| 6 | MINOR | Keep LL5's `500` | Open question 2 (decided) |

Also from the oracle's test list: `/keys/query` + own `GET /devices` (AC1.2), standard 500 body (AC7).

## Manual verification

Not verifiable in the isolated env; must be done before `oauth_enabled` is set (fail-closed: the gate
row (r) is closed in the server, the client behaviour below is the evidence):

1. Element Web (legacy SSO login, opaque token with `refresh_token: true`) in browser A and an
   OAuth-aware Element (or Element X) on device B for the same user: "Sign out" in A => A shows the
   welcome screen; B keeps syncing without a re-login; B's session list (Settings > Sessions) no
   longer shows A's device after a refresh.
2. FluffyChat (legacy login) and Element Web (legacy) for one user: log out in FluffyChat => Element
   keeps working; RECORD (do not expect) whether FluffyChat's device disappears from Element's
   session list and from a peer's device list without a reload (no `device_lists.changed`, gate (s)); logging into FluffyChat
   again creates a new device and E2EE works (new device keys uploaded, no "unknown device" warning
   for the old one).
3. Element Web: a logout answered `500` (database briefly stopped) still clears the local session
   (expected matrix-js-sdk behaviour; record the observed one).
4. Inspect the server log of each logout: one `legacy logout` INFO line, no token material.

## Open questions

1. End the user's account-page browser sessions on a legacy logout? Proposed: no (independent login).
2. Soften LL5's `500` to `200`? Decided no (oracle O6): LL5's `500` is kept.

## ATDD Decisions

- Red tests: `server/test/nebu/oauth/legacy_logout_per_device_test.exs` (AC1-AC8, AC10, facade LL10), rewritten legacy block + LL5 test in
  `oauth_logout_test.exs` (AC9.4, AC9 regression), AC11 pins in `adr_033_test.exs` (ADR LL section + R16/R17 + story-9 update, follow-ups rows r, s,
  x, I-14 and the new section, 07-deployment, matrix-api-scope). Gherkin: `e2e/features/element/legacy-logout-per-device.feature` (+ steps).
- Pinned contracts: facade `Nebu.Matrix.legacy_logout_device/1` (LL10, honours `:oauth_session_repo`); INFO line text `legacy logout ... user_id=<u>
  device_id=<d> kind=opaque|jwt_bound|jwt_unbound outcome=ended|unknown|failed` (unbound: any `outcome=`); `500` body for the opaque path is
  `{"errcode":"M_UNKNOWN","error":"Logout failed, please try again."}`; bound-JWT denylist key is the jti key (`jti:<jti>`) on BOTH `:ended` and
  `:unknown`; ADR bullets are `- **LLn ...` one per decision; the follow-ups table row of (r)/(x) ends with Gate `closed`.
- AC8.7 (OAuth rotation lock tests stay green) and AC9.1-AC9.3 are regression-only: covered by the existing, unchanged tests, no new test.
- Manual verification items 1-4 stay manual (real Element / FluffyChat). The e2e scenario drives two Element Web contexts of alex (raw-JWT legacy
  logins, i.e. the bound-JWT path, AC5) and reads the device list through the Matrix API of the second context; it cannot run in the isolated env.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, phase 2 P6a).

### Debug Log References

- `pg_stat_activity` is snapshotted per transaction: the lock-wait poll of `hold_lock/4` runs inside the lock-holding transaction and therefore calls `pg_stat_clear_snapshot()` before every read (without it the poll never saw the waiters).
- The WARNING `legacy logout: storage failure (...)` of `OAuthSession.end_legacy_device/1` contains the phrase of the INFO line; the tests filter on `[info]`.

### Completion Notes List

- Story created by bmad-create-story (phase 2, P6a): code paths of the legacy and OAuth logout, the
  locked teardown, legacy rotation and raw-JWT binding analysed on HEAD; developer guide created.
- Implemented LL1-LL12: `OAuthSessionStore.end_legacy_device/5` (devices-row lock, re-check per kind under the lock, `delete_device_rows!/3` reuse, empty-device opaque branch), `OAuthSession.end_legacy_device/1` (post-commit `after_commit/2` on `:ended`), facade `Nebu.Matrix.legacy_logout_device/1`, `protected.ex` `/logout` (`legacy_device_logout/1`: opaque => facade; bound JWT => teardown, then the checked denylist on `:ended` AND `:unknown` unless the facade errored; unbound JWT => checked denylist only; `500 M_UNKNOWN` "Logout failed, please try again." on any storage failure; one INFO line `legacy logout user_id= device_id= kind= outcome=`), `legacy_logout/2` renamed `legacy_user_wipe/2` (used by `/logout/all` only, behaviour unchanged).
- Gate x: `MatrixSessionStore.rotate_tokens/1` reads `(user_id, device_id)` of the old legacy row and takes the devices-row `FOR UPDATE` before the guarded soft-revoke UPDATE (lock order devices -> matrix_sessions, never the client lock: no cycle with P4).
- No migration, no new seam, no config. Comments/moduledocs updated (`protected.ex`, `OAuthSession`, `MatrixSessionStore`, `event_dispatcher/server.ex` comment).
- Docs (AC11): ADR-033 section "Legacy logout per device (bugfix legacy-logout-per-device)" (LL1-LL12) before "Gate items before ...", R16 resolved, R17 sentence, story-9 sentence; `follow-ups.md` rows r and x resolved + closed, (c) / story-9 bullets, I-14, row s re-classified as a gate item, new section with row `bd`; `07-deployment.md` row r closed + new gate row s, (s)/(x) removed from the non-gating list; `matrix-api-scope.md` row and paragraph.
- Pre-dev test review fixed in the staged tests: M1 (legacy `sessions`/`sync_tokens` rows seeded for every device and compared in `world/1`; `T.seed_legacy_session_rows!/2`, `T.legacy_session_state/1`), M2 (bounded `pg_stat_activity` poll proves every waiter), M3 (AC8.6 exactly one `ended` and one `unknown`), m1 (real race test AC8.5b; AC8.4 teardown through the real `end_legacy_device`), m2 (rollback modes devices / one-time / fallback keys, failed kill-switch, jti key absent), m3 (`[info]` filter), m4 (outcome pinned, logs for take-over / bound / unbound failures), m5 (body/query naming another device ignored, opaque and JWT), m6 (JWT binding without devices row, opaque user mismatch, binding of another JWT), m7 (`T.device_fingerprint/2` row hashes for survivors), m8 (env restored, not deleted), m9 (`conn!/1`), i2 (one `take_over!/6`).
- Verification (isolated env, `quick.sh`): story file 42/42 (stable over repeated runs), `oauth_logout_test.exs` + `adr_033_test.exs` green, `test/nebu/oauth` 2227 passed, `test/nebu/migration` 171 passed, `test/nebu/matrix` 2 known-family failures (RegressionSyncLoadTest, SyncConcurrentTest), `test/nebu/web` 1 known-family failure (OidcPlugTest denylisted jti, reused-DB family); prod compile: only the known `event_dispatcher/server.ex` warning; e2e `tsc --noEmit` and `bddgen --tags @legacy-logout-per-device` clean (scratchpad copy). Full `mix test --include integration`: see the final report.
- Review cycle 1 (code review MINOR 1-3, INFO 4-5; Kassandra L1-L3 + lock_timeout note):
  - L1: `OAuthSessionStore.lock_device/3` (shared by every teardown) locks the device's `matrix_sessions` rows (`ORDER BY access_token_hash FOR UPDATE`) when there is no `devices` row, so a refresh that commits first has its new row deleted by the following DELETE; test AC8.7 (fails without the fix, verified).
  - Lock timeout: the new legacy device lock is `lock_device_bounded!/3` (`SET LOCAL lock_timeout = '2s'`, reset after, `{:error, :lock_timeout}` => facade `{:error, :unavailable}` => `500`); test AC8.8.
  - L2 (= code-review MINOR 3): `DeviceBinding.lookup/1` no longer caches a database error; new `DeviceBinding.lookup_fresh/1` (uncached, `{:error, :unavailable}` on error); `/logout` re-reads the binding of a JWT that `OidcPlug` resolved as unbound: error => `500` (nothing deleted or denylisted), found binding => bound path. Tests: lookup not cached, logout fails closed then the retry ends the device (`T.revoke_select!/1`).
  - L3: `Logger.info("legacy logout", user_id:, device_id:, kind:, outcome:)` (static message + metadata); the tests capture with `format`/`metadata` and pin the static prefix.
  - MINOR 1: stale RED-phase wording of the test moduledoc fixed. MINOR 2: ADR-033 V13 and the story-9 update state the current gate set ((r) closed, (s) added; the old list stays as "story-9 state"), pinned in `adr_033_test.exs`. INFO 4: `delete_for_user_device/2` doc. INFO 5: `OidcPlug.jwt_token?/1` is the one opaque-vs-JWT decision (used by `OidcPlug` and the logout handlers).
  - Verification: story file 46 passed; `test/nebu/oauth` 2232, `test/nebu/migration` 171, `test/nebu/web` 581/582 (known OidcPlugTest jti), `test/nebu/matrix` only known families; prod compile only the known warning; full `mix test --include integration` 5880/5905 (known families; MediaReservedUploadCleanupWorkerTest is the GenServer.stop setup flake, green alone: `test/nebu/workers` 102 passed); e2e `tsc --noEmit` clean.
- Manual verification (Element / FluffyChat, items 1-4 of the story) is NOT done: not verifiable in the isolated env; `oauth_enabled` stays off.

### File List

- `server/lib/nebu/matrix.ex`
- `server/lib/nebu/matrix/oauth_session.ex`
- `server/lib/nebu/matrix/session/oauth_session_store.ex`
- `server/lib/nebu/matrix/session/matrix_session_store.ex`
- `server/lib/nebu/matrix/event_dispatcher/server.ex` (comment only)
- `server/lib/nebu/web/router/protected.ex`
- `server/lib/nebu/web/plugs/oidc_plug.ex` (review cycle 1: `jwt_token?/1`)
- `server/lib/nebu/matrix/session/device_binding.ex` (review cycle 1: uncached errors, `lookup_fresh/1`)
- `server/test/nebu/oauth/legacy_logout_per_device_test.exs`
- `server/test/nebu/oauth/oauth_logout_test.exs`
- `server/test/nebu/oauth/oauth_test_support.exs`
- `server/test/nebu/oauth/adr_033_test.exs`
- `e2e/features/element/legacy-logout-per-device.feature`, `e2e/step-definitions/element/legacy-logout-per-device.steps.ts`
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`
- `docs/architecture/07-deployment.md`
- `docs/matrix-api-scope.md`
- `docs/stories/oauth-broker/follow-ups.md`
- `docs/stories/oauth-broker/legacy-logout-per-device.md`

## Change Log

- 2026-10-12: story created (ready-for-dev).
- 2026-10-13: implemented (LL1-LL12, gates r and x), pre-dev test review findings fixed in the staged tests, docs edited; status review.
- 2026-10-13: review cycle 1 (code review + Kassandra L1-L3) fixed; status review.
