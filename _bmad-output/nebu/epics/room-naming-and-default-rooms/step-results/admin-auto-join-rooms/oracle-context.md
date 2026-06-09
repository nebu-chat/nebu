## Oracle: Matrix Spec Context — admin-auto-join-rooms

### Applicable Endpoints

- `POST /_matrix/client/v3/login` — entry point for auto-join logic (server-side, triggers on first provision)
- `GET /_matrix/client/v3/sync` — MUST show auto-joined rooms in `rooms.join` map after join
- `POST /_matrix/client/v3/rooms/{roomId}/join` (or `/join/{roomIdOrAlias}`) — Nebu Core calls this internally for auto-join

### MUST Requirements (spec-defined)

1. After user joins a room, room MUST appear in `GET /sync` under `rooms.join` mapped by room ID.
2. `POST /rooms/{roomId}/join` — 200 response MUST include `room_id` field (joined room ID).
3. `POST /join/{roomIdOrAlias}` — 403 response MUST include `errcode` field (e.g. `M_FORBIDDEN`) when join is denied.
4. Server-side auto-join membership event MUST be `m.room.member` with `content.membership = "join"`.
5. Sync `rooms.join` state MUST include `m.room.member` event for the joining user.
6. When lazy-loading enabled in sync filter, server MUST include the syncing user's own `m.room.member` event.
7. On a limited sync (gap), MUST return membership events for events in the gap regardless of redundancy.

### Spec-Defined Error Codes to Test-Cover

- `M_FORBIDDEN` (403) — join denied: invite-only room, banned user, failed restricted-room conditions
- `M_LIMIT_EXCEEDED` (429) — join rate-limited (auto-join bulk: test doesn't explode rate limits)
- `M_UNKNOWN_TOKEN` (401) — if token invalid at login; login MUST still succeed before auto-join fires

### Edge Cases MUST Test-Cover

- **Idempotent join:** Calling join when user already a member MUST NOT produce duplicate `m.room.member` event or error (AC5). Spec doesn't define behavior explicitly — Nebu Core's `{:error, :already_member}` → `:ok` is the correct handling.
- **Non-fatal DB failure:** Login MUST succeed even if `list_auto_join_rooms` fails — spec MUST NOT expose internal errors to the Matrix client (no 5xx from auto-join failure).
- **New vs existing user detection:** Spec has no concept of "first login" — Nebu detects via user provisioning. Test must confirm existing user's `rooms.join` is unmodified after re-login.
- **Auto-join is server-internal:** The `is_auto_join` flag MUST NOT be exposed to the Matrix Client-Server API. No Matrix endpoint should return or accept this field.

### Not Spec-Governed (Nebu-specific)

- `rooms.is_auto_join` DB column — Nebu extension, not Matrix-spec
- Admin UI toggle — Nebu admin plane, not Matrix-spec
- `list_auto_join_rooms` DB query — Nebu internal
