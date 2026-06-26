---
story: fix-device-key-registration
status: in-progress
security_review: required
matrix: true
ui: false
---

# Bugfix — Device Key Registration ("device could not be registered" on login)

## Story

**As** an Element Web user logging into Nebu via OIDC,
**I want** my device to register cleanly (no "device could not be registered" / "key upload not yet active" error),
**so that** the client finishes startup without a crypto error banner.

The device-key endpoints (`/keys/upload`, `/keys/query`, `/keys/device_signing/upload`) are
currently **no-op stubs** that ignore the request body and return empty maps. The Oracle
(Matrix CS API v1.18 spec review, see `_bmad-output/nebu/step-results/device-key-registration/oracle-context.md`)
identified two MUST-level contract violations:

- **Dominant trigger:** `POST /keys/query` returns empty `device_keys: {}`. When Element queries its
  *own* user after upload, it never sees its own device published → "device could not be registered."
- `POST /keys/upload` returns a constant `{"one_time_key_counts": {}}`, ignoring the uploaded keys →
  the client's OTK-reconciliation loop never settles.

This story makes the device-key **directory** stateful and spec-correct so devices register cleanly.

### Hard constraint — E2EE MUST stay OFF (ADR-011)

The device-key directory is **orthogonal** to end-to-end encryption. Per CS spec §E2E, encryption is
enabled **per room** only when a client sends an `m.room.encryption` state event. Storing/echoing
device keys encrypts nothing. This story MUST NOT:
- auto-emit `m.room.encryption`, default `createRoom` to encrypted, or advertise `m.e2e_encryption`
  in `/versions` or `/capabilities`.

It SHOULD add a guardrail: **reject** client `PUT .../state/m.room.encryption` with `403 M_FORBIDDEN`
to hard-enforce the managed-decryption model (ADR-011) — a room can never flip to client-side E2EE.

### Forward link (PRD FR25–FR27)

The uploaded device Ed25519 **public** key is persisted durably (PostgreSQL) so it can later back
message-signature verification / non-repudiation (PRD FR25–FR27). This story only persists + serves
the directory; it does NOT implement signing (separate story).

## Acceptance Criteria

1. **AC1 — Upload is stateful.** `POST /_matrix/client/v3/keys/upload` parses the body, persists the
   `device_keys` blob (when present) and counts `one_time_keys` / `fallback_keys` per algorithm for the
   uploading `(user_id, device_id)`, and returns `one_time_key_counts` reflecting the unclaimed OTK
   count actually held for that device (e.g. `{"signed_curve25519": N}`).
2. **AC2 — Query echoes stored devices.** `POST /_matrix/client/v3/keys/query` returns, for each
   requested user, `device_keys[user_id][device_id]` = the exact uploaded device-keys object plus an
   `unsigned.device_display_name` field. An empty device-id list = all of that user's devices. The
   four cross-signing maps (`master_keys`, `self_signing_keys`, `user_signing_keys`) and `failures`
   remain present (empty). Unknown users/devices are simply omitted (no `failures` entry).
3. **AC3 — whoami device_id.** `GET /_matrix/client/v3/account/whoami` includes `device_id` when a
   device is bound to the token (opaque session); omitted only when none is bound (JWT/appservice).
4. **AC4 — /sync OTK counts.** `GET /sync` populates `device_one_time_keys_count` and
   `device_unused_fallback_key_types` from the store for the caller's device (best-effort when the
   token carries no device_id).
5. **AC5 — Device list.** `GET /_matrix/client/v3/devices` returns the user's devices
   (`{device_id, display_name?, last_seen_ts?}`); `GET /_matrix/client/v3/devices/{deviceId}` returns
   one device or `404 M_NOT_FOUND`.
6. **AC6 — E2EE stays off (guardrail).** A client `PUT .../rooms/{roomId}/state/m.room.encryption`
   is rejected with `403 M_FORBIDDEN`; no server code path emits `m.room.encryption`; `/versions`
   and `/capabilities` are unchanged (no `m.e2e_encryption` advertised).
7. **AC7 — Durability.** Device keys survive a server/Repo restart (PostgreSQL-backed), so a peer's
   `/keys/query` is stable across restarts.

## Dev Notes

- **device_id source:** opaque sessions carry `conn.assigns[:device_id]` (oidc_plug.ex:107-111); raw
  OIDC JWTs (Element's path) do NOT. So `/keys/upload` takes the device_id from the request body
  (`device_keys.device_id`, a Required field on first upload) and falls back to `conn.assigns[:device_id]`.
  `/keys/query` is keyed by **user_id only** — needs no session device_id (this is the dominant fix).
- **Persistence:** new PostgreSQL table `device_keys` (migration `000009_*`), accessed via a new
  `Nebu.Matrix.DeviceKeyStore` module with inline SQL (ADR-018). Mirrors the durability the PRD's
  non-repudiation goal needs; ETS would lose the directory on restart.
- `sync_response/2` (http.ex:121-137) already emits the two device fields as empty placeholders.
- Existing tests asserting the old empty shapes (`matrix_client_compat_test.exs`) must be updated to
  the new stateful contract.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **keys/upload then keys/query round-trip** — ExUnit `:integration` (matrix_client_compat_test.exs)
   - Given: an authenticated user
   - When: `POST /keys/upload` with a `device_keys` object (device_id `DABCDEF`, ed25519+curve25519
     keys, signatures) + 5 `signed_curve25519` one_time_keys
   - Then: response `one_time_key_counts == {"signed_curve25519": 5}`; a subsequent
     `POST /keys/query {"device_keys": {"@user": []}}` returns
     `device_keys["@user"]["DABCDEF"]` equal to the uploaded object with an added
     `unsigned.device_display_name`.

2. **keys/query for unknown user** — ExUnit
   - Given: no keys uploaded for `@stranger`
   - When: `POST /keys/query {"device_keys": {"@stranger": []}}`
   - Then: 200 with `device_keys == {}` and `failures == {}` (omitted, not failed).

3. **whoami returns device_id for opaque session** — ExUnit
   - Given: an opaque-session token bound to device `DXYZ`
   - When: `GET /account/whoami`
   - Then: 200 with `device_id == "DXYZ"`.

4. **E2EE guardrail** — ExUnit
   - Given: an authenticated user in a room
   - When: `PUT /rooms/{roomId}/state/m.room.encryption` with `{"algorithm":"m.megolm.v1.aes-sha2"}`
   - Then: `403 M_FORBIDDEN`.

5. **GET /devices lists the uploaded device** — ExUnit
   - Given: a `keys/upload` for device `DABCDEF`
   - When: `GET /devices`
   - Then: 200 with `devices` containing an entry whose `device_id == "DABCDEF"`.

6. **Durability / restart** — ExUnit (DeviceKeyStore unit test against Repo)
   - Given: device keys persisted for `(@user, DABCDEF)`
   - When: re-read via a fresh query (simulating restart — no in-process cache)
   - Then: the stored `device_keys` blob is returned intact.
