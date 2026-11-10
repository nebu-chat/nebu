# Oracle context: matrix-put-device-keeps-display-name (spec v1.18)

## PUT /_matrix/client/v3/devices/{deviceId}: create or update a device
- Auth: required (access token) · Rate-limited: no
- Required params: deviceId(path) · Body required fields: none · Body optional: display_name (type string)
- Spec text: display_name "If not given, the display name is unchanged." This is the core rule of the bug.
- Responses: 200 device updated | 201 device created (application services only) | 404 the current user has no device with this ID
- MUST: only application services may create devices. Regular clients may only update existing ones, so an unknown deviceId gives 404 M_NOT_FOUND and creates no row
- MUST: return 201 when a new device was created
- MUST: return 200 when a device was updated. The body is `{}`
- Spec gap: explicit JSON `null` is not defined (the type is string). The story's "null clears the name" is a Nebu choice (compatible with Synapse's Optional[str]). It is not a spec breach
- Spec gap: no 400 is listed for this endpoint. M_BAD_JSON is a common error code that any endpoint may return ("valid JSON, but ... invalid values for keys"), with HTTP 400. Use it for display_name = number, object, array or bool
- M_NOT_JSON (400): the body is not valid JSON. Optional edge case. Do not let it be confused with M_BAD_JSON

## GET /_matrix/client/v3/devices (and GET /devices/{deviceId}): list devices
- Auth: required · Rate-limited: no · 200 {devices: [Device]}
- Device.display_name: "Display name set by the user for this device. Absent if no name has been set."
  - After a null clear, the `display_name` key MUST be absent (not `null`, not `""`)
  - A stored `""` (non-NULL) counts as a set name and is returned as `""`, consistent with plan/3 `{:existing, ""}`

## POST /_matrix/client/v3/keys/query (indirect)
- device_keys.<user>.<device>.unsigned.device_display_name: "The display name which the user set on the device." Optional
- After PUT {}, this field MUST still show the old name. After a null clear, it should be absent
- Related: GET /user/devices/{userId} (federation, out of scope) has device_display_name, which is optional

## Related rules (consistency, no new endpoint)
- /login and /register initial_device_display_name: "Ignored if device_id corresponds to a known device." A name already set is never overwritten implicitly. The OAuth DeviceName.plan/3 follows the same rule
- The spec sets no length or charset limit for device names. The 64-code-point limit and stripping are Nebu choices and do not apply to PUT unless a story says so
- Device-list change notification (sync device_lists.changed after a rename) is not required by the spec for display-name-only changes. Out of scope

## Must-test (errcodes and status codes)
- PUT {} on a named device: 200 `{}`. GET /devices, GET /devices/{id} and /keys/query unsigned.device_display_name are unchanged
- PUT {"display_name": "New"}: 200, and the name is updated (regression)
- PUT {"display_name": null}: 200. GET /devices has no display_name key, and /keys/query has no device_display_name
- PUT {"display_name": 5} and {"display_name": {"a":1}} (optionally [] and true): 400 M_BAD_JSON, and the name is unchanged in the DB
- PUT on an unknown deviceId with {"display_name":"x"} and with {}: 404 M_NOT_FOUND. No device row is created (no 201 for non-AS users)
- PUT on a device of ANOTHER user: 404 M_NOT_FOUND (the "current user has no device" rule). The name is unchanged
- PUT without an access token: 401 M_MISSING_TOKEN (regression, auth required)
- Existing test device_naming_chain_test.exs (clear_name! with body `%{}`) MUST switch to `{"display_name": null}` or a DB reset, otherwise it locks in the wrong behaviour
- Unit: DeviceName.plan/3 with a stored "" returns {:existing, ""}. A typed name does not replace it
