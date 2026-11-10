# Oracle retro review: 01-device-naming-chain (commit 595cbfd6)

## Verdict
- MAJOR (1 MAJOR, 2 MINOR, 4 INFO). The MAJOR is an older handler defect that this commit's new test now treats as correct behaviour.

## Spec basis (v1.18 bundled)
- PUT /devices/{deviceId}: `display_name`: "If not given, the display name is unchanged." 200 on update, 404 for an unknown device.
- GET /devices `Device.display_name`: "Display name set by the user for this device. Absent if no name has been set."
- /login and /register `initial_device_display_name`: "Ignored if device_id corresponds to a known device." The OAuth flow should follow the same idea: a device that already has a name keeps it.
- /keys/query `UnsignedDeviceInfo.device_display_name`: "The display name which the user set on the device."
- OAuthClientMetadata `client_uri`: Required, MUST be https, no userinfo. `client_name` is human-readable and may be localised.
- The spec sets no length or charset limit on device display names.

## Findings
- MAJOR: a PUT without `display_name` wipes the name. server/lib/nebu/web/router/protected.ex:1002-1011 passes the missing key as nil to DeviceKeyStore.rename_device (server/lib/nebu/matrix/device_key_store.ex:389-403, `SET display_name = $3`), so `PUT {}` sets the name to NULL. The spec says the name stays unchanged.
  - New in this commit: server/test/nebu/oauth/device_naming_chain_test.exs:293-297 (using test support device_name_oauth_test_support.exs:131-135 `clear_name!`, body `%{}`) asserts that NULL. The "a nameless device is asked again" scenario is built on this.
  - Real impact: a client that PUTs other device metadata without `display_name` silently erases the user's typed or derived name. The next OAuth login then asks for a name again or falls back to "OAuth client (…)".
  - Fix: only update when the `display_name` key is present. Optionally treat an explicit JSON `null` as "clear". Reject a non-string value with 400 M_BAD_JSON. Rewrite the test to clear with `{"display_name": null}` (or a direct DB reset), and add a test that `PUT {}` keeps the name.
- MINOR: a non-string `display_name` (number, object) reaches the SQL parameter. The likely result is a failed UPDATE and a 404 M_NOT_FOUND for a device that exists. The spec's 404 means "no device with the given ID". Validate the type and return 400 M_BAD_JSON. Same place as the MAJOR (protected.ex:1004).
- MINOR: the "ask for a name" path almost never happens for spec-conformant clients. Dynamic client registration requires an https `client_uri` with an ASCII LDH host (server/lib/nebu/oauth/registration.ex:177-189, 356-367). So DeviceName.derive/2 step 2 (server/lib/nebu/oauth/device_name.ex:60-63) always produces "<host> (<suffix>)".
  - `:ask` is reachable only for admin-created or static clients without `client_uri`, or for legacy rows.
  - Not a spec breach, but the story's "asked for a name" promise holds for almost no Matrix client. Confirm this is intended, or rank a generic `client_name` below asking.
- INFO: GET /devices now nearly always returns a server-chosen `display_name` for OAuth devices, although the spec describes it as "set by the user". This was accepted in story oauth-device-default-display-name and is the same practice as MAS/Synapse. Clients must not treat it as user-chosen. No action.
- INFO: a typed or derived name reaches other users through /keys/query `unsigned.device_display_name` (server/lib/nebu/matrix/key_query_store.ex:29,103). The spec allows this. Product suggestion: say so in the consent hint (server/lib/nebu/oauth/consent_page.ex device_name_input). No spec action.
- INFO: the 64-code-point limit, control/format-character stripping and the 80-character display cut are Nebu choices; the spec sets no limit. A client-side PUT can still store longer or unsanitised names, which the account portal must escape and cut (it does: cut_80 and esc).
- INFO: a re-login with a known device_id never overwrites the name (oauth_session_store.ex:202-211, `WHERE display_name IS NULL`). This matches the `initial_device_display_name` rule. Localised `client_name#xx` is dropped at registration, so the derived name is never localised. Both conform.

## Must-test (add)
- `PUT /devices/{id}` with `{}`: 200, and `display_name` unchanged in GET /devices and in /keys/query.
- `PUT` with `{"display_name": 5}`: 400 M_BAD_JSON. `PUT` on an unknown device: 404 M_NOT_FOUND.
- GET /devices for an OAuth device named via the Allow-page input: `display_name` equals the typed name, with no suffix.
