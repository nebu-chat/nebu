## Spec Findings: Startup-Phase Stub Endpoints (Matrix CS API v1.18)

### GET /thirdparty/protocols
- Spec anchor: `#get_matrixclientv3thirdpartyprotocols` (line 55890)
- 200 response: `{string: Protocol}` dictionary — empty object `{}` is **spec-valid** (no protocols)
- VERDICT: `200 {}` correct

### GET /voip/turnServer
- Spec anchor: `#get_matrixclientv3voipturnserver` (line 30210)
- Spec only defines 200 and 429 — no 404 in spec table
- Server MAY provide TURN (optional); unimplemented → `404 M_UNRECOGNIZED` strictly
- `M_NOT_FOUND` also acceptable; Element accepts either
- VERDICT: Use `404 M_NOT_FOUND` — spec-acceptable, Element-compatible

### GET /room_keys/version
- Spec anchor: `#get_matrixclientv3room_keysversion`
- Spec explicitly defines `404 M_NOT_FOUND` for "No backup exists"
- VERDICT: `404 M_NOT_FOUND` is **exact spec match**

### POST /keys/device_signing/upload
- Spec anchor: `#post_matrixclientv3keysdevice_signingupload` (line 38866)
- 200 response: spec example is `{}` — empty object
- UIA not required when no master key exists yet (v1.11+)
- VERDICT: `200 {}` is **exact spec match**

### Unstable MSC endpoints
- `msc3814` (dehydrated_device) and `msc4143` (rtc/transports): NOT in v1.18 spec
- Unimplemented unstable endpoints: `404 M_NOT_FOUND` acceptable
- VERDICT: `404 M_NOT_FOUND` correct — Element accepts this
