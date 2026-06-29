# S1 Device Registry — Matrix CS API Spec Findings (v1.18)

## 1. Endpoints, shapes & MUST rules

**GET /_matrix/client/v3/devices** — auth required, NOT rate-limited
- 200 → `{ "devices": [Device] }`; lists ALL registered devices for current user (key-presence irrelevant — supports keyless devices, AC1/AC4)
- `Device`: `device_id` (string, **Required**); `display_name` (string, omit if unset); `last_seen_ip` (string, optional); `last_seen_ts` (integer, ms since epoch, optional)

**GET /_matrix/client/v3/devices/{deviceId}** — auth required, NOT rate-limited
- 200 → single `Device` (same 4 fields)
- 404 → user has no device with that ID (MUST)

**POST /_matrix/client/v3/keys/upload** — auth required
- Body: `device_keys` (DeviceKeys: `algorithms`,`device_id`,`keys`,`signatures`,`user_id` all Required), `one_time_keys`, `fallback_keys` — all may be absent
- 200 → `{ "one_time_key_counts": {"<algo>": int} }` (MUST reflect server-held OTK counts per algorithm)
- `device_keys.device_id`/`user_id` MUST match the login session's device/user

**POST /_matrix/client/v3/keys/query** — auth required
- 200 → `device_keys: {userId: {deviceId: DeviceInformation}}`, plus `failures`,`master_keys`,`self_signing_keys`
- DeviceInformation = uploaded `/keys/upload` blob + `unsigned.device_display_name` (sourced from `devices.display_name` — confirms AC3 join)
- Unknown user/device → omitted from map (NOT a failure). Devices without published keys MUST NOT appear (AC3 semantics preserved)

## 2. Error codes / status / edge cases to test
- `GET /devices/{deviceId}` nonexistent → **404** (no spec errcode mandated; Nebu should use `M_NOT_FOUND`)
- `/keys/query` for keyless device → device absent from `device_keys`, NOT in `failures` (AC3/AC5 regression test)
- `/keys/upload` `one_time_key_counts` recomputed correctly after upsert (AC5 — OTK count non-regression; also surfaced in `/sync` `device_one_time_keys_count`)
- `/keys/upload` device_id mismatch vs session device → reject
- Both `/devices` endpoints require Bearer auth → missing/invalid token → 401 `M_MISSING_TOKEN`/`M_UNKNOWN_TOKEN`
- `display_name` absent (keyless or unnamed device) MUST be omitted, not null
- `last_seen_ts`/`last_seen_ip` nullable — omit when unknown (matches AC1 nullable columns)

## Nebu notes
- `PUT /devices/{deviceId}` (update/create) is out of S1 scope but spec requires 201-on-create / 200-on-update — flag for a later device-mgmt story.
- E2EE guardrail unaffected: device-key directory is orthogonal to `m.room.encryption` (ADR-011); keyless device rows are spec-consistent since `/devices` is independent of `/keys/*`.
