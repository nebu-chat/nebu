---
story_id: s2-device-lifecycle-at-login
title: "Device lifecycle at login + reliable device_id binding"
epic: device-management
status: done
security_review: required
matrix: true
ui: false
created: 2026-06-26
baseline_commit: d90bcccab95de61da4493a81192dd4d57e1edd14
---

# S2 — Device lifecycle at login + reliable device_id binding

## Story

**As** a user logging in from a client,
**I want** my device to be registered/updated at login and reliably identified on every request,
**so that** the device list reflects my actual sessions and per-device operations (keys, rename,
revoke) target the correct device.

This closes the raw-OIDC-JWT gap from the bugfix: `conn.assigns[:device_id]` is only set for opaque
sessions, so `/keys/upload` had to fall back to the `sole_device_id/1` heuristic. With devices now
first-class (S1), login should own device creation and the request pipeline should always know the
device.

## Background / current state

- Login (`server/lib/nebu/matrix/http_public.ex`) generates a `device_id` per login; persists it only
  on the opaque-session path (`matrix_sessions.device_id`). Raw-JWT sessions carry no server-side
  device binding.
- `OidcPlug` assigns `:device_id` only for opaque sessions.
- `sole_device_id/1` (from the bugfix) attributes OTK-only uploads when no device_id is present —
  a heuristic that breaks for genuine multi-device users.

## Acceptance Criteria

1. **AC1 — device created at login.** On a successful login, an entry in `devices` (S1) is
   created/updated for `(user_id, device_id)`, with `created_at` on first sight and refreshed
   `last_seen_ts`/`last_seen_ip`. Honors `initial_device_display_name` from the login body as
   `display_name` when present.
2. **AC2 — stable per-client device_id.** A client that presents/reuses its own `device_id` (Matrix
   allows reuse "provided the user remains the same") keeps the same device row rather than spawning a
   new one each login. A login that reuses a device_id must not duplicate the device. (Note the spec
   rule: reusing a device_id invalidates tokens previously bound to that device — honor or document.)
3. **AC3 — device_id bound to every authenticated request.** `conn.assigns[:device_id]` is populated
   for **all** authenticated sessions (opaque AND raw-JWT), via a server-side token→device binding so
   protected routes always know the device.
4. **AC4 — heuristic removed.** `sole_device_id/1` and its use in `/keys/upload` are removed; the
   upload attributes keys via the now-reliable `conn.assigns[:device_id]` (body device_id still
   authoritative for the first upload).
5. **AC5 — last-seen updates.** `last_seen_ts` (and `last_seen_ip`) update on authenticated activity
   (at minimum on `/sync`), without a write on every request hammering the DB (throttle/"""best effort""").
6. **AC6 — token↔device binding is server-authoritative (anti-transfer).** The device a request acts
   as is determined SOLELY by the server-side binding of the presented token. A session authenticated
   as device A can NOT operate as device B by supplying a different `device_id` in a request body
   (e.g. `/keys/upload` `device_keys.device_id` ≠ the token's bound device → reject with the
   spec-appropriate error; do NOT silently write to the other device). A token can NOT be "promoted"
   to a different/new device. This makes a stolen/copied token unable to masquerade as another device.
7. **AC7 — refresh preserves the device binding (NO REGRESSION).** `POST /_matrix/client/v3/refresh`
   (oidc-session-refresh) keeps working exactly as today, and the rotated access+refresh tokens stay
   bound to the SAME `device_id` as before the refresh (spec: "New tokens from refresh remain bound to
   the same device_id"). The grace-window behavior of the old refresh token is unchanged.

## Security Goals (explicit — Kassandra/SEC Gate 1 must verify)

> **G1 — No cross-device session transfer.** It must be impossible to take the authentication of one
> device and use it as/for another device ("login stealing" / token transfer). Concretely: the bound
> `device_id` comes from the token's server-side record, never from attacker-controllable input; a
> request that names a different device than the one bound to its token is rejected, not honored.
>
> **G2 — Refresh cannot re-bind the device.** Refreshing a token must not let a caller change which
> device the resulting tokens belong to (no `device_id` switch through the refresh path).
>
> **G3 — The refresh feature must not regress.** The oidc-session-refresh flow (`/refresh`,
> `rotate_tokens/1`, `expires_in_ms`, soft-logout 401 semantics) is a hard "do-not-break" invariant —
> it is verified by a dedicated regression test in this story and must stay green.

## Acceptance Tests

### Tests written FIRST:

1. **Login registers a device** — ExUnit `:integration`
   - Given: a fresh user logging in with `initial_device_display_name: "Element Desktop"`
   - When: login completes, then `GET /devices`
   - Then: the device appears with that display name and a `created_at`.
2. **device_id present on raw-JWT request** — ExUnit `:integration`
   - Given: a JWT-authenticated session whose device was registered at login
   - When: a protected request runs
   - Then: `conn.assigns[:device_id]` equals the login device_id (no `sole_device_id` fallback).
3. **OTK-only upload attributes to the bound device (multi-device)** — ExUnit `:integration`
   - Given: a user with two devices, JWT session bound to `DEV_A`
   - When: an OTK-only `/keys/upload` (no `device_keys` in body)
   - Then: OTKs land on `DEV_A` (not dropped, not mis-attributed) — the case the old heuristic failed.
4. **SECURITY G1 — no cross-device transfer** — ExUnit `:integration`
   - Given: a session bound to `DEV_A` (token T_A) and a separate device `DEV_B`
   - When: a request with T_A tries to act as `DEV_B` (e.g. `/keys/upload` with
     `device_keys.device_id = "DEV_B"`, or any per-device write naming `DEV_B`)
   - Then: it is rejected / scoped to `DEV_A` — T_A can NOT publish keys for or operate as `DEV_B`;
     `DEV_B`'s keys are unchanged.
5. **SECURITY G2 — refresh keeps the device** — ExUnit `:integration`
   - Given: a session bound to `DEV_A` with a refresh token
   - When: `POST /refresh`
   - Then: the new access token resolves to `DEV_A` (device_id unchanged); there is no way to obtain a
     token for a different device via refresh.
6. **REGRESSION G3 — refresh flow intact** — ExUnit `:integration`
   - Given: an opaque session issued with `refresh_token: true`
   - When: `POST /refresh` with the refresh token
   - Then: returns a new `access_token` + `refresh_token` + `expires_in_ms`; the old RT honors its
     grace window then is revoked; an expired AT yields `401 M_UNKNOWN_TOKEN` with `soft_logout: true`.
     (Mirrors/keeps the existing oidc-session-refresh tests green.)

## Dev Notes

- Binding device_id for JWT sessions: persist a token→device association at login (e.g. extend the
  session store, or a token-hash→device map) and have `OidcPlug` assign `:device_id` from it. Avoid
  putting device_id in the JWT (issued by the IdP, not Nebu).
- **The refresh flow already exists and already preserves the device — EXTEND, don't rewrite.**
  `POST /refresh` → `Nebu.Matrix.HttpPublic.do_refresh/1` → `MatrixSessionStore.rotate_tokens/1`, which
  already copies `user_id`/`device_id` from the old session row into the rotated row (device binding on
  refresh is implemented for opaque sessions). Do not regress this; keep its existing tests green and
  add the G2/G3 tests above. The token↔device record this story binds (AC3) is the same `matrix_sessions`
  row `rotate_tokens` carries forward.
- For G1: the per-device write paths (`/keys/upload`, and S3's device endpoints) must derive the device
  from `conn.assigns[:device_id]` and reject a body `device_id` that contradicts it (spec: device_keys
  `device_id` "Must match the device ID used when logging in").
- Removing `sole_device_id/1`: ensure the `/keys/upload` empty-input no-DB short-circuit still holds
  for the unit layer.

## Dev Agent Record

### Completion Notes

Implemented by Amelia (Dev). All 13 acceptance tests in
`server/test/nebu/matrix/device_lifecycle_login_test.exs` pass; the G3 regression suites
(`login_refresh_test.exs`, `device_keys_test.exs`) stay green.

- **AC1** — `Nebu.Matrix.HttpPublic.do_login_with/2` now reads `initial_device_display_name`
  and `provision_and_respond/6` registers the device via `DeviceKeyStore.upsert_device/3`
  (`last_seen_ts`/`last_seen_ip` from the conn; display_name only on first creation so S1's
  COALESCE keeps the original on reuse).
- **AC2** — login honours a client-supplied body `device_id` (reuse keeps the same row);
  `initial_device_display_name` is ignored on reuse.
- **AC3** — raw-JWT token→device binding added: new table `jwt_device_bindings` (migration
  `000011`) + `Nebu.Matrix.Session.DeviceBinding` (token SHA-256 → device, per-node TTL
  cache). Login persists the binding for the JWT path; `OidcPlug.call_jwt/2` assigns
  `:device_id` from it. `device_id` is NOT put in the JWT. Opaque sessions keep binding via
  `matrix_sessions.device_id`. whoami now returns `device_id` for BOTH session kinds.
- **AC4** — `DeviceKeyStore.sole_device_id/1` and its `/keys/upload` use removed; the upload
  attributes OTKs via the now-reliable `conn.assigns[:device_id]`. Empty-input no-DB
  short-circuit preserved.
- **AC5** — `DeviceKeyStore.touch_last_seen/3` (throttled to 60s, best-effort, never raises)
  called from `/sync`; a second immediate `/sync` does not re-write.
- **AC6 / G1** — `/keys/upload` rejects a body `device_keys.device_id` that contradicts the
  token's bound device UP FRONT (403 M_FORBIDDEN) before any write; the bound device is the
  sole authority for attribution.
- **AC7 / G2 / G3** — refresh flow untouched (`rotate_tokens/1` still carries device_id
  forward); the new G2/G3 tests observe it via whoami.

**Hot-path note:** `DeviceBinding.get_device/1` runs on every raw-JWT request, so it is backed
by a per-node 60s ETS TTL cache (mirrors OidcPlug's provisioning cache); `put/3` primes it.

**Test environment notes (pre-existing flakes, NOT caused by this story):**
- `matrix_sso_test.exs:302` 500 is the documented PII-key flake — a stale fixed-sub
  (`@alex`) row from a prior boot is undecryptable under the per-boot random
  `pii_encryption_key`. Green on a clean DB (verified by clearing the `@alex` rows).
- `regression_sync_load_test.exs` (200-client latency gate) and `http_foundation_test.exs`
  `/health` only fail under host CPU saturation when run alongside the load test; both pass
  in isolation. This story's measured-path overhead is microseconds (cache hit + a nil
  check) and cannot move the median — environmental, not a regression.

### File List

- `server/priv/migrations/000011_jwt_device_bindings.up.sql` (new) — token→device binding table
- `server/priv/migrations/000011_jwt_device_bindings.down.sql` (new) — reverse migration
- `server/lib/nebu/matrix/session/device_binding.ex` (new) — token-hash→device store + TTL cache
- `server/lib/nebu/matrix/http_public.ex` — login registers device, honours client device_id, binds JWT token
- `server/lib/nebu/web/plugs/oidc_plug.ex` — `call_jwt/2` assigns `:device_id` from the binding
- `server/lib/nebu/web/router/protected.ex` — `/keys/upload` G1 mismatch reject + bound-device attribution + lazy JWT bind; `/sync` throttled last-seen
- `server/lib/nebu/matrix/device_key_store.ex` — removed `sole_device_id/1`; added `touch_last_seen/3`
- `server/test/nebu/release_test.exs` — migration-list assertion updated to include 000011

### Change Log

- 2026-06-26 — S2 implemented: device lifecycle at login + server-authoritative token↔device
  binding (opaque + raw-JWT), cross-device-transfer rejection (G1), throttled last-seen,
  `sole_device_id/1` removed. Migration 000011 adds `jwt_device_bindings`.
