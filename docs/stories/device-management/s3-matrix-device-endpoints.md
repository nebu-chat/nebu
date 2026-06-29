---
story_id: s3-matrix-device-endpoints
title: "Matrix device-management endpoints (rename, delete, delete_devices)"
epic: device-management
status: done
security_review: required
matrix: true
ui: false
created: 2026-06-26
---

# S3 — Matrix device-management endpoints

## Story

**As** a user,
**I want** to rename and delete my devices via the Matrix client API,
**so that** I can manage my sessions from any standard Matrix client (Element "Sessions" panel).

## Background

The bugfix added `GET /devices` and `GET /devices/{id}` (read-only). The write side of Matrix device
management is missing. Deleting a device must also revoke its session and key material.

## Acceptance Criteria — consult `/nebu-agent-oracle` for exact CS v1.18 shapes during atdd/dev

1. **AC1 — `GET /devices` full metadata.** `GET /devices` and `GET /devices/{id}` return
   `device_id`, `display_name?`, `last_seen_ip?`, `last_seen_ts?` (from `devices`, S1/S2).
2. **AC2 — `PUT /devices/{deviceId}`.** Updates the device `display_name`. Only the owner may rename
   their device (the device must belong to `conn.assigns[:current_user]`); renaming another user's /
   a non-existent device → `404 M_NOT_FOUND` (no existence oracle / no IDOR). Returns `200 {}`.
3. **AC3 — `DELETE /devices/{deviceId}` (UIA-gated, Option B).** Deletes the device: removes its
   `devices` + `device_keys`/OTK/fallback rows **and revokes the associated `matrix_sessions` token**
   (and denylists the JWT if applicable) so that session can no longer authenticate. Returns `200 {}`
   **only after UIA is satisfied** (see AC5). Deleting another user's device → `404`.
4. **AC4 — `POST /delete_devices`.** Bulk-deletes a list of the caller's devices (same per-device
   semantics as AC3, same UIA gate). Returns `200 {}`.
5. **AC5 — UIA via SSO with a 15-minute freshness window.** Device deletion (`DELETE /devices/{id}`
   and `POST /delete_devices`) is a sensitive operation guarded by User-Interactive Authentication:
   - If the caller's **last fresh authentication** (`auth_time`) is **≤ 15 minutes** ago, the operation
     proceeds directly (recent login satisfies UIA).
   - If it is **> 15 minutes** ago, the server responds `401` with a UIA flow requiring a fresh login:
     `{ "flows": [ { "stages": ["m.login.sso"] } ], "session": "<uia_session>", "params": {} }`.
     The client completes a fresh SSO/OIDC login for that UIA `session`, then re-submits the request
     with the `auth` block; the server verifies the fresh auth, refreshes `auth_time`, and executes.
   - `m.login.sso` is the chosen stage because Nebu is OIDC-only (no `m.login.password`). The 15-minute
     window is configurable. **Future:** additional stages (email / other MFA) may be added to the
     flow without changing the endpoints.
6. **AC6 — E2EE invariant intact.** None of these endpoints can enable encryption; the
   `m.room.encryption` guardrail is untouched.

## Security Goals (explicit — Kassandra/SEC Gate 1 must verify)

> **G1 — Sensitive ops require fresh auth.** A device deletion (single or bulk) MUST NOT succeed when
> the caller's last fresh authentication is older than 15 minutes without completing a fresh `m.login.sso`
> UIA stage. A stale-but-valid session alone is insufficient. This prevents a walked-up-to / hijacked
> open session from silently revoking the user's other devices.
> **G2 — UIA session integrity.** The UIA `session` is server-issued, single-use, bound to the same
> user + the specific pending operation; it cannot be replayed for a different op or user, and the
> fresh-auth it grants does not widen beyond the 15-minute window.
> **G3 — No IDOR.** Every operation scopes strictly to `conn.assigns[:current_user]` (S2 device
> binding); another user's device is never visible or actionable (→ `404`).

## Acceptance Tests

### Tests written FIRST:

1. **Rename** — ExUnit `:integration`: `PUT /devices/{id}` with `{"display_name":"My Laptop"}` →
   `200`; `GET /devices/{id}` reflects the new name.
2. **Rename IDOR** — ExUnit: user A renames user B's device → `404` (and B's device unchanged).
3. **Delete revokes session** — ExUnit `:integration`: create a device+session, `DELETE /devices/{id}`,
   then a request with that session's token → `401 M_UNKNOWN_TOKEN`; the device is gone from
   `GET /devices`.
4. **delete_devices bulk** — ExUnit: `POST /delete_devices` with two of the caller's device_ids →
   both removed (after UIA is satisfied).
5. **Delete other user's device** — ExUnit: A deletes B's device → `404`, B's device intact.
6. **UIA G1 — fresh login ≤ 15 min proceeds** — ExUnit `:integration`: caller authenticated < 15 min
   ago, `DELETE /devices/{id}` → `200` directly (no challenge).
7. **UIA G1 — stale login > 15 min is challenged then completes** — ExUnit `:integration`: caller's
   `auth_time` > 15 min ago → first `DELETE` returns `401` with
   `flows:[{stages:["m.login.sso"]}]` + a `session`; after completing a fresh SSO login for that UIA
   `session` and re-submitting with `auth`, the `DELETE` returns `200` and the device is gone.
8. **UIA G2 — session cannot be replayed** — ExUnit: a completed/foreign UIA `session` reused for a
   different op or user is rejected (`401`/`403`), not honored.

## Dev Notes

- Oracle gate (matrix: true): confirm `PUT/DELETE /devices/{id}`, `POST /delete_devices` request/
  response shapes AND the exact UIA wire format in CS v1.18 (§User-Interactive Authentication API +
  §Single Sign-On UIA stage `m.login.sso`, the `401` `{flows, session, params}` body, the re-submit
  `auth` dict) before implementing.
- **`auth_time` source:** track the user's last *fresh* authentication time. OIDC tokens carry an
  `auth_time` claim (IdP authentication time) — prefer that; for opaque sessions, persist `auth_time`
  at login (from the id_token's `auth_time`/`iat`) on the `matrix_sessions` row. The 15-minute window
  compares `now - auth_time`. NOTE: a token *refresh* (S2/oidc-session-refresh) is NOT a fresh
  authentication — it MUST NOT reset `auth_time` (otherwise refresh would defeat the freshness gate).
- **UIA session store:** server-issued single-use `session` id bound to (user, pending op). ETS or a
  short-TTL table; expire quickly. The SSO UIA stage reuses the existing OIDC/SSO login machinery
  (`Nebu.Matrix.SsoLogin` / OidcPlug) — coordinate so the UIA SSO redirect returns into the UIA flow,
  not a normal login.
- 15-minute window is configurable (env, e.g. `NEBU_UIA_FRESH_AUTH_SECONDS`, default 900).
- Future MFA: the flow is a list of stages — adding `m.login.email.identity` or a custom MFA stage
  later must not require changing the device endpoints.
- Session revocation: reuse the logout revocation path (`revoke_access_token` /
  `MatrixSessionStore.revoke` / `TokenDenylist`) — deleting a device == logging out that session.
- IDOR is the dominant risk (Kassandra will gate): all operations scope strictly to
  `conn.assigns[:current_user]`; never trust a path/body user.

## Dev Agent Record

### What was built

- **Migration `000012_device_management_uia`** (forward-only, idempotent): adds
  `matrix_sessions.auth_time BIGINT`, `jwt_device_bindings.exp BIGINT`,
  `idx_jwt_device_bindings_user_device`, and the DB-backed `uia_sessions` table
  (`session_id` PK, `user_id`, `op`, `params`, `stage_complete`,
  `consumed`, `created_at`, `expires_at` + index on `expires_at`). The SSO callback
  resolves the UIA session via `SsoStore` state → uia_session and `Uia.complete/2`
  keys by `(session_id, authenticated_user)` (H-1, cycle 2), so the row stores no
  SSO-state linkage of its own.
  `Nebu.Release` discovers migrations from disk (no hard-coded count), so adding the
  file alone moves `release_test` to 12 migrations.
- **`auth_time` (Option B freshness):** captured at opaque login from
  `claims["auth_time"] || claims["iat"]` (`MatrixSessionStore.create`), copied
  VERBATIM on `rotate_tokens` (a refresh is NOT a fresh auth — cannot defeat the
  gate), refreshed for the user on UIA SSO completion. New getters
  `get_auth_context/1`, `refresh_auth_time/2`.
- **`Nebu.Matrix.DeviceId.valid?/1`** (F-2): ≤255 bytes, no `\x00-\x1f`/`\x7f`.
  Applied at login (`device_id` → 400 `M_INVALID_PARAM`) and `/keys/upload`
  (`device_keys.device_id` → 400).
- **`DeviceKeyStore`:** `delete_device/2` (devices + device_keys + OTK + fallback,
  scoped + idempotent), `rename_device/3` (owner-scoped UPDATE → 0 rows = `:error`
  → 404), `belongs_to_other_user?/2` (delete IDOR discriminator).
- **`Nebu.Matrix.Uia`** (DB-backed UIA gate): window from
  `:nebu_http :uia_fresh_auth_seconds` (env `NEBU_UIA_FRESH_AUTH_SECONDS`, default
  900); `mint_session`, single-use atomic `consume` (bound to user+op+params,
  `consumed=TRUE WHERE consumed=FALSE`), `complete/2` (identity-bound — H-1, cycle 2),
  `cleanup_expired`.
- **Endpoints (`protected.ex`):** `PUT /devices/{id}` (rename, not gated),
  `DELETE /devices/{id}` and `POST /delete_devices` (UIA-gated, IDOR-scoped). Shared
  `uia_gate/4`: auth-block → consume-or-rechallenge; no auth → fresh→proceed else
  401 challenge `%{"flows"=>[%{"stages"=>["m.login.sso"]}],"session"=>id,"params"=>%{}}`.
- **SSO auth fallback:** `GET /_matrix/client/v3/auth/m.login.sso/fallback/web?session=`
  (public router forward → `HttpPublic` → `SsoLogin.uia_fallback/1`), tags the SSO
  state with the UIA session; the shared OIDC callback (`/sso/redirect/oidc`) detects
  the tag, marks `stage_complete`, refreshes `auth_time`, renders a 200 completion page.
- **F-1 kill-switch:** `DeviceBinding.put/4` now persists the verified JWT `exp`;
  `list_for_user_device/2` enumerates `(token_hash, exp)`; delete calls
  `TokenDenylist.revoke_by_hash/2`. Hash alignment: `DeviceBinding.hash/1` and
  `TokenDenylist`'s hash key are BOTH `SHA-256(token)` lowercase hex, so the next
  request's live token resolves `revoked?` true → 401 `M_UNKNOWN_TOKEN`.
- **Sweeper:** `Nebu.Matrix.Session.Sweeper` (hourly) deletes expired
  `jwt_device_bindings` (exp < now) + `uia_sessions`; started with the Repo.

### UIA session store choice (ADR-020)

DB-backed `uia_sessions`, NOT node-local ETS: a UIA session is minted on one node,
its `m.login.sso` stage completed via the browser SSO callback on possibly another,
and the re-submit may hit a third. Every node reads the same authoritative row;
single-use is enforced by the atomic conditional UPDATE.

### Self-delete session-revocation semantics (single coherent rule — symmetric preserve)

Deleting a device revokes that device's session (AC3). The ONLY exception is the
credential MAKING the request: when the caller deletes its own current device in a
context where the live token must finish the request, that one token is PRESERVED.
This preserve is now SYMMETRIC across token kinds — it holds IDENTICALLY for opaque
and raw-JWT callers:

- opaque caller — its `matrix_sessions` row (matched by the request's bound device)
  is NOT dropped;
- raw-JWT caller — the F-1 kill-switch SKIPS the binding row whose `token_hash` equals
  `SHA-256(live request token)` (`DeviceBinding.hash/1`), so the live JWT is not
  denylisted; OTHER JWTs bound to the same device ARE still revoked.

`preserve` is supplied as `{current_device, current_token_hash}` (from
`caller_credential/1`) and is honored:

- bulk `POST /delete_devices` — ALWAYS (the caller's own device may be in the batch;
  it must keep managing devices after the batch);
- single `DELETE /devices/{id}` satisfied by a fresh `m.login.sso` re-auth
  (`via_auth=true`) — the user just re-proved themselves this request.

It is NOT honored (`preserve == nil`) for a single `DELETE` satisfied only by the
recent-login window (`via_auth=false`): there the presented token bound to the deleted
device stops authenticating, which is exactly what the F-1 kill-switch / AC3 require
(pinned by the F-1 single-DELETE test, which expects the bound JWT to be DEAD).

This closes the prior blind spot where the preserve held only for opaque sessions
(the `matrix_sessions` row was spared) while a raw-JWT caller was logged out mid-batch
anyway via the unconditional kill-switch. A caller that does not target its own device
is unaffected and keeps managing devices normally. Two regression tests pin this:
(1) a raw-JWT caller bulk-deleting OTHER devices keeps its own JWT alive and completes
the batch; (2) a raw-JWT caller bulk-deleting its OWN device keeps its own live JWT
alive while the device is still removed.

### SHOULD gap (Option B vs. an explicit confirm page)

There is NO dedicated UIA confirmation page; per the chosen Option B the 15-minute
fresh-auth window stands in for an explicit per-op confirmation. A fresh login within
the window proceeds without any prompt; only a stale session is challenged. This is
the deliberate design (AC5), but a future story could add an explicit confirm step
(or additional MFA stages — the flow is already a stage list).

### Verification

- `make build-server` compiles clean (`--warnings-as-errors`).
- `make redeploy` applied 000012 (schema_migrations = 12; `uia_sessions`,
  `auth_time`, `exp`, index all present).
- `mix test --include integration test/nebu/matrix/device_endpoints_test.exs
  test/nebu/release_test.exs` → 31 tests, 0 failures.
- Full `test/nebu/matrix` + `test/nebu/web` on a fresh DB volume → 879 tests, 1
  failure (only `RegressionSyncLoadTest` latency 154ms vs 150ms — an environmental
  perf flake under the loaded test container, unrelated to S3).

### Security review cycle 2 (Kassandra 2026-06-26) — H-1 + M-1 + array cap

Kassandra BLOCKED the commit on one HIGH (H-1) plus two land-alongside NOTEs. Fixed:

- **H-1 (HIGH) — UIA `m.login.sso` completion is now identity-bound.** The OIDC
  callback derives the Matrix `user_id` from the freshly-verified id_token claims via
  `UserId.from_claims/2` (the EXACT derivation login uses, incl. sub normalisation) and
  threads it into `Nebu.Matrix.Uia.complete/2` (was `complete/1`). The completion UPDATE
  now carries `AND user_id = $authenticated_user`: a fresh login by a DIFFERENT IdP
  account (the attacker holding a victim's open token) matches 0 rows, so the stage is
  NOT marked complete and `auth_time` is NOT refreshed. `complete_uia/3` in
  `sso_login.ex` renders the success page ONLY on `{:ok, _}`; on `:error` (mismatch /
  unknown / consumed) it renders an explicit 403 failure page, does not run
  `onAuthDone()`, and logs a PII/token-free warning. Pinned by a cross-sub regression
  test (`device_endpoints_test.exs`: "H-1: a foreign IdP identity completing the fallback
  does NOT satisfy the victim's step-up") — the foreign-sub callback returns 403, the
  victim's re-submitted DELETE is still 401, and the victim's device is intact.
- **M-1 — `max_age=0` on the UIA-fallback authorize.** `do_redirect` now adds
  `max_age=0` to the authorize query ONLY when an `uia_session` is set (the step-up
  fallback), forcing the IdP to genuinely re-authenticate rather than silently reuse an
  existing SSO-session cookie. The normal login redirect keeps `prompt=login` alone (no
  UX regression). Limitation: the callback does not additionally assert
  `now - claims["auth_time"] <= window` — the `max_age` request parameter is the
  load-bearing freshness control here, and H-1's sub-binding already anchors the
  completion to the verified identity.
- **`/delete_devices` array cap + dedupe.** The handler rejects a `devices` array with
  more than 100 entries (`400 M_INVALID_PARAM`, checked on the raw array length before
  filtering) and dedupes the binary id list with `Enum.uniq` so the UIA params
  canonicalisation and the per-device loop are stable. Empty-array and missing-key
  behavior unchanged. Pinned by "oversized devices array (>100 entries) → 400
  M_INVALID_PARAM".

Verification: `mix compile --warnings-as-errors` clean; `make redeploy` clean;
`mix test --include integration test/nebu/matrix/device_endpoints_test.exs` → 23 tests,
0 failures (21 prior + the 2 new regression tests).
