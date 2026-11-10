# Oracle context: 06-portal-rename-device (Matrix spec v1.18)

## GET /_matrix/client/v3/devices: list the current user's registered devices
- Auth: required (access token) · Rate-limited: no
- Responses: 200 `{"devices":[Device]}`; Device = `device_id` (required), `display_name` (optional, "Absent if no name has been set"), `last_seen_ip`, `last_seen_ts`
- Test: after a portal rename, `display_name` == the sanitised name, only for that device of that user; other users' GET /devices are unchanged
- Edge: `display_name` must be absent (not `""`/null) when no name is set. A portal rename never stores an empty name (refused), so this cannot happen through the portal
- GET /_matrix/client/v3/devices/{deviceId}: same Device object, 404 if the current user has no such device. The portal rename must show up here too (same column)

## PUT /_matrix/client/v3/devices/{deviceId}: create or update a device
- Auth: required (access token) · Rate-limited: no
- Required params: deviceId(path) · Body optional: display_name ("If not given, the display name is unchanged")
- Responses: 200 The device was successfully updated. | 201 The device was successfully created by the application service. | 404 The current user has no device with the given ID.
- MUST: The ability to create new devices is only available to application services: regular clients may only update existing devices.
- MUST: When a new device was created, the homeserver MUST return a 201 HTTP status code.
- MUST: It MUST return a 200 HTTP status code if a device was updated.
- Test (AC rule "client PUT later still replaces the name"): portal rename -> client PUT `{"display_name":"X"}` -> 200 `{}` -> GET /devices shows "X" (last write wins)
- Test: PUT with body `{}` after a portal rename keeps the portal name (field absent = unchanged)
- Not in scope: the spec does not apply the portal's sanitising to client PUT. Do not add PUT tests that expect sanitising unless the 01-device-naming-chain story already did that

## Other spec touchpoints (behaviour, not new endpoints)
- POST /keys/query: Nebu returns `unsigned.device_display_name` from `devices.display_name` (key_query_store.ex:103). So a portal rename is visible to other users who query keys
- Device-list change: the existing `DeviceKeyStore.rename_device/3` stamps a device-list change for keyed devices (`stamp_if_keyed!`), so other members get the user in `device_lists.changed` in /sync. The new portal path MUST go through that same function (or keep the stamp); otherwise E2EE peers keep a stale name. Test: rename a keyed device -> the peer's incremental /sync lists the user in `device_lists.changed`
- Existing facade `Nebu.Matrix.rename_user_device/3` (user-scoped UPDATE, `:ok | :error`, no IDOR) already exists for the admin UI. Reuse it or wrap it; the user_id comes from the verified portal session only
- Device Management module: "Clients ... should offer ... the means to update their display names" (SHOULD). The portal fills this role for OAuth users
- OAuth 2.0 account management (v1.18): `account_management_actions_supported` actions are `org.matrix.profile`, `org.matrix.devices_list`, `org.matrix.device_view`, `org.matrix.device_delete`, ... There is no spec action for renaming, so no new action may be advertised (it would have to be namespaced and is out of scope)
- If `org.matrix.device_view` is advertised, the server SHOULD support `device_id`. The rename entry on the device detail page fits that flow and must not break it
- No events, room versions or e2ee payloads change. The device name is not a room event and is not redacted or audited by spec

## Errcodes / statuses that MUST be test-covered
- Matrix side: GET /devices 200 shows the new name; PUT /devices/{id} 200 overwrites it; PUT for a device the user does not own -> 404 (regression only)
- Portal side (not Matrix API, so no errcodes): foreign or unknown device -> notice `device_not_found` and zero rows changed (check another user's device row is unchanged); stale auth_time -> 303 + notice `stale`, name unchanged; no auth_time -> notice `freshness_unavailable`, no reauth link; empty/invisible-only name -> `device_name_invalid`, old name kept
- Sanitising edge cases: tags and control characters removed (`<b>Work\u0007 laptop</b>` -> `Work laptop`); a 500-char name is cut to 64 code points (not bytes, so test with multi-byte characters); surrounding whitespace trimmed
- Not testable through the CS API: "name never in a log line" (needs a log-capture test); HTML escaping (portal and admin render tests)
