## Oracle Context — personal-self-room

### Applicable Endpoints
- `POST /_matrix/client/v3/login` — triggers self-room creation (server-side, Nebu extension)
- `GET /_matrix/client/v3/sync` — MUST return self-room under `rooms.join[roomId]`

### Room Creation Event Sequence (spec §createRoom)
- MUST emit `m.room.create` (with `creator` field set to requesting user)
- MUST emit `m.room.member` with `membership: join` for creator
- MUST emit `m.room.power_levels`
- MUST emit `m.room.join_rules`
- MUST emit `m.room.history_visibility`
- MUST emit `m.room.name` with `content.name` = localpart (e.g. `"alice"`)
- `private_chat` preset: `join_rules: invite`, `history_visibility: shared`, `guest_access: can_join`

### Sync Behavior (spec §sync)
- Self-room MUST appear in `rooms.join` on first sync (no `since`)
- State events MUST appear in `rooms.join[roomId].state.events` (not timeline, not ephemeral)
- `m.room.name` state event: `type="m.room.name"`, `state_key=""`, `content.name="alice"`
- `rooms.join[roomId]` structure: `state`, `timeline`, `ephemeral`, `account_data`

### Spec-Defined Error Cases
- Login: 200 OK with `access_token`, `device_id`, `user_id` — self-room creation must not affect this
- Login: any self-room DB error → still returns 200 (non-fatal, Nebu-specific)
- Sync: 200 with `next_batch` token; missing auth → 401 `M_UNKNOWN_TOKEN`

### Idempotency
- No spec-defined idempotency for server-side auto-room creation (Nebu extension); MUST be tested via re-login
- `m.room.name` state_key MUST be `""` (empty string per spec)

### Edge Cases MUST Cover
- First sync after first login: `rooms.join` contains self-room with `m.room.name` state event
- Second login: exactly one self-room in `rooms.join` (no duplicate `m.room.name` events)
- DB error on self-room creation: login returns 200 with valid `access_token`
- `m.room.member` for creator: `membership: join`, `state_key = @alice:nebu.local`
