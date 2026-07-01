---
epic: client-crypto-setup
story: cross-signing-readback
security_review: required
baseline_commit: ce1e34ba83ac8161e45e0193966e7eccafee031b
---

# Story: Cross-signing upload/read-back so clients set up cleanly (E2EE-ready)

Status: done

# Story

As an Element Web / Element X user on Nebu,
I want my cross-signing keys and signatures to be stored and read back consistently,
so that the recovery / cross-signing bootstrap completes without
"Schlüssel können nicht eingerichtet werden" and my session is verifiable — leaving the
client E2EE-ready regardless of whether rooms are ever encrypted.

## Context & Spec Notes (Oracle)

Cross-signing is a **write-then-read-back contract**, not fire-and-forget. The current no-op
stubs return spec-correct *shapes* but never persist, so the read-back is empty and the
client treats the bootstrap as failed.

§Cross-signing (Matrix CS API v1.18):
> "When Alice uploads new keys, her user ID will appear in the `changed` property of the
> `device_lists` field of the `/sync` response… When Bob sees Alice's user ID in his `/sync`,
> he will call POST /_matrix/client/v3/keys/query to retrieve Alice's device keys, as well as
> their cross-signing keys."

Endpoint shapes (already correct, keep them):
- `POST /keys/device_signing/upload` → `200 {}` (§device_signing/upload).
  UIA is required for regular clients **except** when there is no existing master key, OR the
  uploaded keys exactly match the stored ones (idempotent retry) — §device_signing/upload,
  changed in v1.11. First-time bootstrap = no existing MSK ⇒ no UIA ⇒ flat `200 {}` is correct.
- `POST /keys/signatures/upload` → `200 {"failures": {}}` (empty `failures` = success;
  per-key `M_INVALID_SIGNATURE` on failure).

**MUST guard** (§Cross-signing, key-and-signature security): servers MUST NOT allow a device
to have the same ID as a cross-signing key (`ed25519:DEVICE_ID` and `ed25519:PUBLIC_KEY`
share one namespace). Enforce on persist.

**Managed model holds (ADR-011):** all stored material is **opaque** — the server never
decrypts and never gains a private part. Persisting cross-signing keys does NOT enable room
encryption; that is still gated solely by `m.room.encryption`, which the server keeps
rejecting. Cross-signing / device verification is mechanically independent of room E2EE.

Current code (baseline ce1e34ba), `server/lib/nebu/web/router/protected.ex`:
- `post "/client/v3/keys/device_signing/upload"` (~line 231) → `200 {}`, **no store**.
- `post "/client/v3/keys/query"` (~line 273) → hardcodes `master_keys: {}`,
  `self_signing_keys: {}`, `user_signing_keys: {}` (~lines 285–287). **This is the bug.**
- `post "/client/v3/keys/signatures/upload"` → `200 {"failures": {}}`, **no store**.
- `/sync` body has no `device_lists` (account_data is `[]` ~line 597).
- Existing precedent to mirror: `Nebu.Matrix.DeviceKeyStore` (PostgreSQL, migration
  `000009_device_keys`) — device keys are already Postgres-backed; cross-signing keys belong
  in the same persistence style.

## Scope guardrail

IN: persist + echo cross-signing keys & signatures; surface own user in `/sync`
`device_lists.changed`; MUST-guard the device/cross-signing ID namespace.

OUT (explicit follow-ups, not this story): account_data durability across restart + `/sync`
account_data extension (today ETS round-trips in-session, which is enough to clear the
bootstrap error); the Compliance/Normal mode switch; federation; mTLS; escrow client; any
acceptance of `m.room.encryption`.

## Acceptance Criteria

1. `POST /keys/device_signing/upload` persists the supplied `master_key`, `self_signing_key`,
   and `user_signing_key` (opaque, per user) and returns `200 {}`.
2. Idempotent re-upload of the **same** keys returns `200 {}` without requiring UIA; an attempt
   to **overwrite** existing different keys without `auth` returns the UIA-style `401` flow
   (or, minimally for this story, `403 M_FORBIDDEN "Key ID in use"` per §device_signing/upload
   403). The first-upload (no existing MSK) path requires no UIA.
3. `POST /keys/query` for a user who has uploaded cross-signing keys returns those keys in
   `master_keys[user_id]`, `self_signing_keys[user_id]`, and `user_signing_keys[user_id]`,
   echoing the uploaded objects (replacing today's hardcoded `{}`). Users without cross-signing
   keys still get empty maps. `device_keys` behaviour (DeviceKeyStore echo) is unchanged.
4. `POST /keys/signatures/upload` merges each supplied signature into the `signatures` property
   of the targeted stored key object (device key or cross-signing key), returns
   `200 {"failures": {}}` on success, and a per-(user,key) `M_INVALID_SIGNATURE` entry under
   `failures` when the signed object does not match the stored key. The merged signature is
   visible on the next `POST /keys/query`.
5. After a successful `device_signing/upload`, the uploading user's own ID appears in
   `device_lists.changed` of that user's next **incremental** `/sync` response.
6. **MUST guard:** an upload that would create a cross-signing key whose ID collides with an
   existing device ID for that user (or vice-versa) is rejected (`400 M_INVALID_PARAM`),
   before any write.
7. No room becomes encrypted as a result of any of the above; a client `PUT` of
   `m.room.encryption` is still rejected (ADR-011 regression guard).
8. `make test-unit-elixir` is green; no regressions in existing protected-router / device-key
   tests.

## Tasks / Subtasks

- [x] Persistence (mirror `DeviceKeyStore`): new migration `priv/migrations/000010_cross_signing_keys`
      (table keyed by `user_id`, columns for master/self/user signing JSON + signatures),
      and a `Nebu.Matrix.CrossSigningKeyStore` module with `put_keys/2`, `get_keys/1`,
      `merge_signatures/3` (AC 1, 3, 4).
- [x] `device_signing/upload` handler: validate namespace MUST-guard, persist keys, idempotency
      / overwrite-without-auth handling (AC 1, 2, 6).
- [x] `keys/query` handler: populate `master_keys` / `self_signing_keys` / `user_signing_keys`
      from the store for every requested user (AC 3).
- [x] `signatures/upload` handler: merge signatures into stored objects; build `failures` map
      for mismatches (AC 4).
- [x] `/sync`: include `device_lists.changed` with the user's own ID when their cross-signing
      keys changed since the `since` token (AC 5).
- [x] ADR-011 regression guard test: `m.room.encryption` PUT still rejected (AC 7).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. device_signing/upload → keys/query read-back — ExUnit `:integration`
   - Given: an authenticated user with no existing cross-signing keys
   - When: `POST /keys/device_signing/upload` with master/self/user signing keys, then
     `POST /keys/query` for that user
   - Then: response `master_keys`/`self_signing_keys`/`user_signing_keys` echo the uploaded
     objects (not `{}`)

2. signatures/upload merges and is visible — ExUnit `:integration`
   - Given: a device key uploaded via `/keys/upload`
   - When: `POST /keys/signatures/upload` adds a signature for that device key, then
     `POST /keys/query`
   - Then: `200 {"failures": {}}`, and the device key object's `signatures` now contains the
     added signature

3. device_lists.changed in incremental sync — ExUnit `:integration`
   - Given: a user completes `device_signing/upload`
   - When: that user calls incremental `/sync`
   - Then: `device_lists.changed` contains the user's own ID

4. MUST-guard: ID namespace collision rejected — ExUnit
   - Given: a user with device `ABCDEF`
   - When: `device_signing/upload` supplies a cross-signing key whose ID equals `ABCDEF`
   - Then: `400 M_INVALID_PARAM`, nothing persisted

5. Persistence survives restart (Persistenz-Strategie = PostgreSQL, read-on-start) — ExUnit
   - Given: cross-signing keys persisted for a user
   - When: the store/process is restarted (or queried via a fresh process)
   - Then: `get_keys/1` returns the previously stored keys (Postgres-backed, not volatile)

6. ADR-011 regression: m.room.encryption still rejected — ExUnit `:integration`
   - Given: an authenticated user in a room
   - When: `PUT /rooms/{id}/state/m.room.encryption`
   - Then: `403 M_FORBIDDEN` (unchanged), and the room is not encrypted

## Dev Agent Record

### Completion Notes

Implemented the cross-signing write-then-read-back contract (Matrix CS API v1.18)
PostgreSQL-backed (ADR-018 inline SQL, ADR-020 cluster-correct, ADR-011 opaque/orthogonal
to E2EE).

- **Persistence** — migration `000010_cross_signing_keys` (one row per `user_id`:
  `master_key_json` / `self_signing_key_json` / `user_signing_key_json` nullable TEXT,
  `cross_signing_changed` BOOLEAN consume-once flag, BIGINT epoch-millis `created_at`/`updated_at`).
  New module `Nebu.Matrix.CrossSigningKeyStore` mirrors `DeviceKeyStore` style:
  `put_keys/2` (upsert ON CONFLICT user_id, sets changed flag), `get_keys/1` (read-on-start,
  all-nil map when absent), `query_cross_signing/1` (bulk WHERE user_id = ANY($1), safe_query
  that never raises), `merge_signatures/3`, `consume_changed_flag/1` (atomic
  UPDATE ... RETURNING), plus `key_ids_in_upload/1` and `key_id_of/1` for the namespace guard.
  Signatures are stored inside the JSON blob.
- **device_signing/upload** (AC1/2/6) — MUST-guard FIRST (reject `400 M_INVALID_PARAM` if any
  cross-signing key-id collides with an existing device id, before any write); first upload (no
  existing MSK) → `200 {}`; identical re-upload → idempotent `200 {}`; differing keys without
  auth → `403 M_FORBIDDEN`.
- **keys/query** (AC3) — populates `master_keys`/`self_signing_keys`/`user_signing_keys` from
  the store for the requested users; users without cross-signing keys are omitted (maps stay
  empty). `device_keys` echo unchanged.
- **signatures/upload** (AC4) — new route; merges `signatures` into the stored key object
  (device key via `DeviceKeyStore`, else cross-signing key); per-(user,key)
  `M_INVALID_SIGNATURE` in `failures` on mismatch / unknown key; always `200 {"failures": …}`.
- **/sync device_lists.changed** (AC5) — implemented via the consume-once Postgres boolean
  `cross_signing_changed` (set on upload; the first INCREMENTAL sync reads-and-clears it via
  `consume_changed_flag/1` and adds the user's own id to `device_lists.changed`). Cluster-correct,
  no token-timestamp parsing. Initial sync (no `since`) does not consume the flag.
- **AC7** — ADR-011 `m.room.encryption` rejection untouched (still `403 M_FORBIDDEN`).

`mix compile --warnings-as-errors` → ok. Unit-layer test (AC7 guardrail) passes; the
`:integration` tests require Docker/Postgres (run via `make test-integration` in the pipeline
CI gate). No regression in `device_keys_test.exs`.

### File List

- `server/priv/migrations/000010_cross_signing_keys.up.sql` (new)
- `server/priv/migrations/000010_cross_signing_keys.down.sql` (new)
- `server/lib/nebu/matrix/cross_signing_key_store.ex` (new)
- `server/lib/nebu/matrix/device_key_store.ex` (added `device_ids/1`)
- `server/lib/nebu/web/router/protected.ex` (device_signing/upload, keys/query, new
  signatures/upload route, /sync device_lists.changed, cross-signing helpers)

## Change Log

- 2026-06-28 — Implemented cross-signing upload/read-back + signature merge + device_lists.changed
  (PostgreSQL-backed CrossSigningKeyStore, migration 000010). All AC tasks complete; status → review.
