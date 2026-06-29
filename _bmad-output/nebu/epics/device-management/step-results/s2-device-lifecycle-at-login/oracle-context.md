# Oracle — Spec Findings: Device Registration & Token↔Device Binding (CS API v1.18)

## Q1 — Endpoints & MUST rules

**POST /_matrix/client/v3/login** (§Login)
- If client supplies NO `device_id` → server MUST auto-generate one.
- Returned access token MUST be associated with the supplied or generated `device_id`.
- Server MAY invalidate any access token previously associated with that device.
- `device_id`: if it does not match a known device → a new device created; given ID MUST NOT equal a cross-signing key ID.
- `initial_device_display_name`: display name for the newly-created device; MUST be ignored if `device_id` corresponds to a known device (→ AC1 "honor", AC2 "reuse keeps row").

**Relationship between access tokens and devices** (§4293)
- Servers should record which device each access/refresh token is assigned to (→ AC3, AC6 server-authoritative binding).
- Client may reuse an existing device "provided the user remains the same" (→ AC2).
- If the client sets the `device_id`, the server WILL invalidate any access AND refresh tokens previously assigned to that device (→ AC2 reuse invalidates prior tokens).

**POST /_matrix/client/v3/keys/upload** (§44413)
- `device_keys.device_id` (Required): "Must match the device ID used when logging in" (→ AC6, AC4).
- `device_keys.user_id` (Required): "Must match the user ID used when logging in."
- Auth required; NOT rate-limited. `device_keys` itself MAY be absent.

**POST /_matrix/client/v3/refresh** (§6417)
- Refresh-token grant; new access+refresh tokens are bound to the SAME device as the initial refresh token (§4297) (→ AC7).
- Auth via refresh token only (no access token). Old refresh token valid until new token first used, then revoked.

**GET /_matrix/client/v3/devices** & **/devices/{deviceId}** (§35654)
- Device object: `device_id` (Required), `display_name` (absent if unset), `last_seen_ip`, `last_seen_ts` (ms epoch) (→ AC1, AC5 fields). "May be a few minutes out of date" → throttling is spec-sanctioned (→ AC5).

**GET /_matrix/client/v3/account/whoami** (§11918)
- `device_id` Required in 200 response when a device is associated with the token; omit only for appservices (→ AC3 — every authed session must resolve a device).

## Q2 — Error codes / HTTP statuses / edge cases to test

- Login wrong creds / unknown user → 403 `M_FORBIDDEN` (do not distinguish — timing); missing `type` → 400 `M_BAD_JSON`.
- Login no `device_id` → 200 with server-generated `device_id` returned.
- Login reusing existing `device_id` (same user) → same device row, prior access+refresh tokens for that device invalidated.
- keys/upload with `device_keys.device_id` ≠ token's bound device → MUST reject (AC6; spec "Must match" — Nebu choice of `M_FORBIDDEN`/400; assert it is rejected, not silently accepted). Same for `user_id` mismatch.
- keys/upload with matching device_id → 200.
- whoami on opaque AND raw-JWT session → both 200 with correct `device_id` (AC3 parity). Unknown token → 401.
- GET /devices/{deviceId} unknown id → 404.
- refresh → 200, new tokens still resolve to the SAME `device_id` (assert via whoami before/after) (AC7); unknown/already-used refresh token → 401.
- /sync (and ≥) updates `last_seen_ts`/`last_seen_ip`, throttled — assert update happens but is not per-request (AC5).
- 429 + `Retry-After`/`retry_after_ms` on rate-limited login/refresh/whoami.

Note (Nebu memory): Element Web does not request refresh tokens — AC7 regression coverage matters mainly for the admin/server-driven refresh path and any client that opts in via `refresh_token: true`.
