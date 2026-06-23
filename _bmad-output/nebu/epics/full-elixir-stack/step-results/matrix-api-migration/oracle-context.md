# Oracle — Matrix CS API v1.18 parity contract for matrix-api-migration

## 1. Per-endpoint MUST requirements + success response top-level keys

- **POST /login**: GET first MAY advertise flows `{flows:[{type}]}`. Success 200 `{user_id, access_token, device_id, home_server(deprecated), well_known?, expires_in_ms?, refresh_token?}`. `m.login.token`/`m.login.password` types; Nebu uses OIDC token. `expires_in_ms`/`refresh_token` only when client sent `refresh_token:true`. MUST return fully-qualified `@user:server` user_id.
- **POST /logout**: invalidate that device's access (+refresh) token. Success 200 `{}`.
- **GET /sync**: 200 `{next_batch (MUST), rooms{join,invite,knock,leave}, presence{events}, account_data{events}, to_device, device_lists, device_one_time_keys_count, device_unused_fallback_key_types}`. Per-room join: `{timeline{events,limited,prev_batch}, state{events}, ephemeral{events}, account_data, unread_notifications, summary}`.
- **PUT /rooms/{id}/send/{type}/{txnId}**: 200 `{event_id}` (MUST be fully-qualified `$...`). txnId device-scoped idempotent.
- **GET /rooms/{id}/messages**: 200 `{chunk(MUST array), start, end, state?}`. Honors `dir`(b/f, required), `from`, `to`, `limit`, `filter`. `end` absent ⇒ timeline exhausted.
- **POST /createRoom**: 200 `{room_id}`. Creator auto-joined; preset drives join_rules/history_visibility; `initial_state`, `name`, `topic`, `room_alias_name` applied.
- **POST /join/{roomIdOrAlias}**: 200 `{room_id}`.
- **PUT /rooms/{id}/typing/{userId}**: 200 `{}`. `timeout` required when `typing:true`.
- **POST /rooms/{id}/receipt/{type}/{eventId}**: 200 `{}`.
- **GET /profile/{userId}**: 200 `{displayname?, avatar_url?}`. **PUT /profile/{userId}/displayname|avatar_url**: 200 `{}`; only self (else 403).
- **GET /presence/{userId}/status**: 200 `{presence(MUST: online|offline|unavailable), last_active_ago?, currently_active?, status_msg?}`.
- **auth_issuer / auth_metadata (MSC2965)**: 200 `{issuer}` / OIDC metadata object. Serve at both `unstable/org.matrix.msc2965/*` and stable `v1/*` paths — parity MUST keep both.

## 2. Error codes / edge cases the Elixir tests MUST cover

- Auth (all authed endpoints): no token → 401 `M_MISSING_TOKEN`; bad/expired → 401 `M_UNKNOWN_TOKEN` (+`soft_logout` per session state).
- Login: wrong creds AND unknown user → 403 `M_FORBIDDEN` (must NOT distinguish — timing). Missing `type` → 400 `M_BAD_JSON`. Unsupported login type → 400 `M_UNKNOWN`. Rate → 429 `M_LIMIT_EXCEEDED` + `retry_after_ms`.
- Send: missing `msgtype`/bad body → 400; insufficient power → 403 `M_FORBIDDEN`; **same txnId+device ⇒ identical event_id, no dup event** (must-test).
- createRoom: alias taken → 400 `M_ROOM_IN_USE`; bad version → 400 `M_UNSUPPORTED_ROOM_VERSION`; invalid initial state → 400 `M_INVALID_ROOM_STATE`.
- join: not allowed/banned → 403 `M_FORBIDDEN`; rate → 429 `M_LIMIT_EXCEEDED`.
- messages/profile/presence on unknown room/user → 404 `M_NOT_FOUND`.
- typing: `typing:true` without `timeout` → 400; PUT for another user → 403 `M_FORBIDDEN`.
- receipt: unknown receipt type → 400 `M_UNRECOGNIZED`.
- presence PUT: invalid value → 400 `M_BAD_JSON`.
- All errors: body `{errcode, error}` with correct HTTP status (parity MUST match Go exactly).

## 3. /sync long-poll rules the BEAM-native impl MUST honor

- `since` absent → full-state initial sync; present → incremental, only deltas since that token.
- `timeout` (ms): 0 → return immediately; >0 → block up to timeout, return early when data arrives; default 0 if omitted.
- `next_batch` always returned and is the next `since`; tokens MUST be opaque and round-trip.
- `limited:true` on a room timeline MUST be paired with `prev_batch` (gap-fill via /messages).
- Ephemeral typing (`m.typing`) and receipts (`m.receipt`) go in `rooms.join[id].ephemeral`, NOT timeline; presence in top-level `presence.events`.
- `full_state`, `set_presence`, `filter` params honored; long-poll is one BEAM process per request — must wake on event dispatch, not poll.

## Parity caveat
The Go side returns `event_id:""` for state PUTs (known bug, not in this story's endpoint list) — do not replicate that defect; `/send` must return real `$...` ids.
