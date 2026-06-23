# Oracle Context — elixir-stack-regression (Matrix CS API v1.18)

## 1. MUST Requirements

**Login** `POST /_matrix/client/v3/login`
- Body `type: m.login.password` (or token); 200 → `access_token`, `device_id`, `user_id` (all required)
- Wrong password AND unknown user → identical `403 M_FORBIDDEN` (no distinction — timing-attack prevention)

**Create room** `POST /_matrix/client/v3/createRoom`
- 200 → fully-qualified `room_id`; creator auto-joined (`m.room.create` + creator `m.room.member` join)
- `preset` controls `m.room.join_rules` + `m.room.history_visibility`; `initial_state` applied in order

**Invite / membership** `POST /_matrix/client/v3/rooms/{roomId}/invite`, `/join/{roomIdOrAlias}`
- Invite → target `m.room.member` `membership: invite`; join → `membership: join`; leave → `leave`
- Inviter MUST hold ≥ `invite` power level

**Send message** `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`
- 200 → `{event_id}`; `m.room.message` requires `msgtype` + `body`
- Same `txnId` + same device → same `event_id`, no duplicate (idempotent, MUST)

**Sync** `GET /_matrix/client/v3/sync`
- No `since` → full state + `next_batch`; with `since` → incremental only
- Long-poll honors `timeout` ms; `timeout=0` returns immediately; `next_batch` always present
- `limited: true` ⇒ `prev_batch` present; ephemeral (`m.typing`, `m.receipt`) in `rooms.join[id].ephemeral`, NOT timeline

**Receipt** `POST /_matrix/client/v3/rooms/{roomId}/receipt/m.read/{eventId}` → 200 `{}`; `m.receipt` surfaces in sync ephemeral

**Typing** `PUT /_matrix/client/v3/rooms/{roomId}/typing/{userId}`
- `typing:true` requires `timeout`; `typing:false` stops; 200 `{}`; `m.typing` in sync ephemeral

**Logout** `POST /_matrix/client/v3/logout` → 200 `{}`; access_token invalidated thereafter

**Media upload** `POST /_matrix/media/v3/upload` (auth required) → 200 `{content_uri: "mxc://..."}` (required)

**Media download** `GET /_matrix/client/v1/media/download/{server}/{mediaId}` (`/_matrix/media/v3/` deprecated)
- 200 returns identical bytes + `Content-Type`; spec defines NO Range/206 (AC2 Range is a Nebu extension, not a spec MUST)

**Preview** `GET /_matrix/client/v1/media/preview_url?url=` (`/_matrix/media/v3/` deprecated) → 200 OpenGraph JSON: `og:title`, `og:description`, `og:image`, `matrix:image:size`

**Auth (AC5):** Bearer token in `Authorization` header on all protected endpoints; valid token MUST NOT 401.

## 2. Error Codes / HTTP Status / Edge Cases to Cover
- Login: missing `type` → `400 M_BAD_JSON`; bad creds/unknown user → `403 M_FORBIDDEN`
- Send: missing `msgtype` → 400; insufficient power → `403 M_FORBIDDEN`; duplicate `txnId` → same `event_id`
- Membership: invite/kick/ban without power → `403 M_FORBIDDEN`; banned user rejoin → 403
- Typing: `typing:true` without `timeout` → 400
- Receipt: unknown receipt type → `400 M_UNRECOGNIZED`
- Upload: too large → `413 M_TOO_LARGE`; forbidden type/quota → 403; rate-limited → `429 M_LIMIT_EXCEEDED` (+ `retry_after_ms`)
- Download: unknown media → 404; remote fetch too large → `502 M_TOO_LARGE`
- Preview: rate-limited → 429
- Auth: invalid/expired/missing token → `401 M_UNKNOWN_TOKEN` / `M_MISSING_TOKEN`; valid token MUST stay non-401
- Sync edge: `timeout=0` immediate return; ephemeral position (ephemeral vs timeline) asserted structurally

**NOTE:** AC2's Range/206 has no v1.18 spec backing — test it as a Nebu implementation requirement (parity with prior Go behavior), not a Matrix MUST.
