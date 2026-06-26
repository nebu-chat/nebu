# Oracle Context — Device-Key Registration (CS API v1.18)

## Root cause
Element's post-login crypto bootstrap: POST /keys/upload (publish device identity keys + OTKs + fallback)
-> reconcile OTK count -> POST /keys/query for OWN user to confirm device published.

Two stub violations:
- (A) DOMINANT: POST /keys/query returns empty device_keys{} -> client never sees its own device ->
  "device could not be registered". Spec: device_keys = {user_id:{device_id: DeviceInformation}},
  must echo the SAME object uploaded via /keys/upload + an `unsigned` property.
- (B) POST /keys/upload returns constant {one_time_key_counts:{}} ignoring body. Spec: one_time_key_counts
  REQUIRED = unclaimed OTK count per algorithm for THIS device. Breaks OlmMachine reconciliation.
- /sync E2E extension missing device_one_time_keys_count + device_unused_fallback_key_types (Required, v1.2).
- whoami omits device_id (required when device bound to token).

## E2EE boundary (CRITICAL — must NOT activate E2EE)
Device-key directory is ORTHOGONAL to encryption. E2EE is enabled PER ROOM by the client sending an
`m.room.encryption` state event (m.megolm.v1.aes-sha2). Implementing the key directory encrypts nothing.
MUST NOT: auto-emit m.room.encryption; default createRoom to encrypted; advertise m.e2e_encryption in
/versions or capabilities. RECOMMENDED guardrail: reject client PUT .../state/m.room.encryption with
403 M_FORBIDDEN to hard-enforce ADR-011.

## Required contracts (shapes)
- POST /keys/upload -> 200 {"one_time_key_counts":{"signed_curve25519":N}}. Persist per (user_id,device_id):
  device_keys blob (overwrite), OTKs algorithm:key_id->key (store-once), fallback per-algorithm (replace).
- POST /keys/query -> {"device_keys":{"@u:s":{"DEV":{<uploaded device_keys>,"unsigned":{"device_display_name":..}}}},
  "master_keys":{},"self_signing_keys":{},"user_signing_keys":{},"failures":{}}. Empty device-list = all devices.
- GET /sync add: "device_one_time_keys_count":{"signed_curve25519":N}, "device_unused_fallback_key_types":[..].
- GET /account/whoami add "device_id".
- GET /_matrix/client/v3/devices (+ /devices/{deviceId}) -> {"devices":[{"device_id","display_name?","last_seen_ts?"}]}.
- POST /keys/claim optional (only exercised when actually encrypting; stub {} ok or claim-and-delete).

## State / persistence
Per (user_id, device_id): device_keys JSON blob, OTKs, fallback per-algorithm, display_name, last_seen_ts.
RECOMMEND PostgreSQL table (ADR-018 SQL inline) — directory must survive restarts AND the Ed25519 device
public key is needed for PRD FR25-FR27 message-signature / non-repudiation use. ETS (AccountDataStore pattern)
is MVP-acceptable but loses directory on restart.

## Minimal fix plan
1. /keys/upload stateful  2. /keys/query echoes stored keys (clears the error)  3. /sync E2E fields
4. whoami device_id  5. GET /devices(+{deviceId})  6. guardrail reject m.room.encryption PUT (recommended)
