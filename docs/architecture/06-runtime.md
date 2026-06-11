# 6 Runtime View

## Scenario 1: Matrix Client Message Send (Happy Path - GRÜN Status)

```
Matrix Client      Go Gateway          Elixir Core         PostgreSQL
     │                   │                   │                   │
     │  PUT /rooms/send  │                   │                   │
     │──────────────────►│                   │                   │
     │                   │  JWT validate      │                   │
     │                   │──────────────────►│                   │
     │                   │  user_id, role     │                   │
     │                   │◄──────────────────│                   │
     │                   │  gRPC SendEvent    │                   │
     │                   │──────────────────►│                   │
     │                   │                   │  INSERT event      │
     │                   │                   │──────────────────►│
     │                   │                   │  Ed25519 sign      │
     │                   │                   │  EventId.generate  │
     │                   │  {event_id}        │                   │
     │                   │◄──────────────────│                   │
     │  200 {event_id}   │                   │                   │
     │◄──────────────────│                   │                   │
```

## Scenario 2: gRPC EventBus Stream (GRÜN/GELB/ROT State Machine)

```
Go Gateway Status Machine:

  ┌─────┐   Stream healthy      ┌──────┐
  │ ROT │──────────────────────►│ GRÜN │
  └─────┘                       └──────┘
     ▲                             │ Stream lost
     │ Unary polling fails          │
  ┌──────┐◄────────────────────────┘
  │ GELB │  Stream lost, Unary OK
  └──────┘
     │ Unary also fails
     └──────────────────────────►┌─────┐
                                 │ ROT │
                                 └─────┘
                                    │ Writes → message_buffer
                                    │ Drain on reconnect
```

**GRÜN:** EventBus stream healthy - direct gRPC streaming to Matrix clients.
**GELB:** Stream lost, Unary polling succeeds - writes to message_buffer, polling continues.
**ROT:** Stream AND Unary fail - all writes held in message_buffer, 200 OK returned to clients
(Matrix-conformant); Docker `restart: always` heals the Elixir core.

## Scenario 3: Matrix Client Sync (Long-Poll)

```
Matrix Client      Go Gateway          MessageBuffer       Elixir Core
     │                   │                   │                   │
     │  GET /sync        │                   │                   │
     │──────────────────►│                   │                   │
     │                   │  check buffer     │                   │
     │                   │──────────────────►│                   │
     │                   │  empty (wait)     │                   │
     │                   │◄──────────────────│                   │
     │                   │  (holds connection for up to 30s)     │
     │                   │  EventBus event arrives               │
     │                   │◄──────────────────────────────────────│
     │  200 {events}     │                   │                   │
     │◄──────────────────│                   │                   │
```

The Go Gateway distributes EventBus events from a single streaming connection to all waiting
Matrix client long-poll connections via the in-memory per-user ring buffer.

## Scenario 3a: Public Room Join - Sync Wakeup (GAP-JOIN-PUBLIC, Story 9-19)

After `POST /join/{roomId}` for a **public room** (no prior invite), the sync long-poll must
deliver `rooms.join[roomId]` within 10 s. Without a fix this hangs for 30 s: the sync Task
only subscribes to `:pg` groups for rooms already in `get_rooms_for_user`; the public-room join
broadcast goes to `room:#{roomId}` which no sync Task monitors yet.

```
Matrix Client      Go Gateway    Elixir Core (gRPC join_room/2)
     │                   │                   │
     │  POST /join       │                   │
     │──────────────────►│  gRPC JoinRoom    │
     │                   │──────────────────►│
     │                   │                   │  Room.Server.join → :ok
     │                   │                   │  :pg.get_local_members("user:#{user_id}")
     │                   │                   │  → send {:new_join, room_id} to sync Task
     │  200 {}           │                   │
     │◄──────────────────│                   │
     │                   │                   │
     │  GET /sync (long-poll held)           │
     │──────────────────►│                   │
     │                   │  receives {:new_join, room_id} from :pg
     │                   │  joins room:#{room_id} :pg group
     │                   │  re-queries with new room in scope
     │  200 {rooms.join} │                   │
     │◄──────────────────│                   │
```

**Key invariant:** The `{:new_join, room_id}` signal is only sent on the `:ok` (actual new join)
path, not on the idempotent `{:error, :already_member}` path.

## Scenario 3b: Incremental Sync - Left Rooms Filter (GAP-LEAVE-ONCE, Story 9-19)

After the first incremental sync delivers `rooms.leave[roomId]`, subsequent syncs with a fresh
`since` token must NOT re-include the same left room. Without a filter, `buildLeaveRooms` queries
all ever-left rooms on every incremental sync, causing Element Web to re-process the leave on
every cycle.

**Fix:** `buildLeaveRooms` accepts a `sinceMs int64` parameter. For incremental sync, `sinceMs`
is read from `sync_tokens.updated_at` (the wall-clock timestamp of the previous sync response).
Only rooms where `left_at > sinceMs` OR `rejected_at > sinceMs` are returned.
Initial sync passes `sinceMs = 0` to include all ever-left rooms.

## Scenario 3c: POST /forget - Persistent Room Exclusion (GAP-FORGET, Story 9-19)

After `POST /rooms/{roomId}/forget`, the room must not appear in any subsequent sync response
(`rooms.join`, `rooms.leave`, `rooms.invite`).

```
Matrix Client      Go Gateway                        PostgreSQL
     │                   │                                │
     │  POST /forget     │                                │
     │──────────────────►│  gRPC LeaveRoom precondition   │
     │                   │  INSERT INTO forgotten_rooms    │
     │                   │──────────────────────────────►│
     │  200 {}           │                                │
     │◄──────────────────│                                │
     │                   │                                │
     │  GET /sync        │                                │
     │──────────────────►│  SELECT room_id FROM forgotten_rooms WHERE user_id = $1
     │                   │──────────────────────────────►│
     │                   │  excluded from join/leave/invite
     │  200 (room absent)│                                │
     │◄──────────────────│                                │
```

**DB table:** `forgotten_rooms (user_id, room_id, forgotten_at_ms BIGINT)` - migration 000040.
Insert is idempotent (`ON CONFLICT DO NOTHING`). Cascade delete on `users` row removal.

## Scenario 3d: Per-Device Sync Token Isolation (GAP-SINCE-IGNORED, Story 9-22)

When a Matrix client opens a sync long-poll, the `device_id` (extracted from the `"did"` claim
of the JWT) is forwarded in `GetSyncDeltaRequest`. The Elixir Core looks up and persists the
`since` token in `sync_tokens` keyed by `(user_id, device_id)` - not just `user_id`.

```
Matrix Client A (device_id=AAAA)    Matrix Client B (device_id=BBBB)    Elixir Core
        │                                    │                                │
        │  GET /sync?since=v1_...            │                                │
        │───────────────────────────────────────────────────────────────────►│
        │                           gRPC GetSyncDelta(user_id, since, AAAA)  │
        │                                    │  get_since_token(user_id, AAAA)│
        │                                    │  ◄── {since_token for AAAA}   │
        │  200 {events, next_batch}          │                                │
        │◄────────────────────────────────── │ persist_since_token/4 (A, AAAA)│
        │                                    │                                │
        │                    GET /sync?since=v1_...                           │
        │                    ───────────────────────────────────────────────►│
        │                          gRPC GetSyncDelta(user_id, since, BBBB)   │
        │                                    │  get_since_token(user_id, BBBB)│
        │                                    │  ◄── {since_token for BBBB}   │
        │                    200 {events, next_batch}                         │
        │                    ◄───────────────│ persist_since_token/4 (A, BBBB)│
```

**Isolation invariant:** Device AAAA and device BBBB each maintain an independent checkpoint row
in `sync_tokens (user_id, device_id)`. A slow or disconnected device cannot advance another
device's token and cause it to miss events.

**Fallback:** When `device_id` is empty (legacy client or test), the Core falls back to the
`(user_id, '')` row (legacy arity-3/1 functions) and triggers a full initial sync on mismatch.

## Scenario 3e: Per-Device Logout - Sync Token Cleanup (Story 9-22)

After `POST /logout`, the Go Gateway calls `InvalidateUserSessions` with both `user_id` and
`device_id`. The Elixir Core deletes the `sync_tokens (user_id, device_id)` row and the
corresponding `sessions (user_id, device_id)` row in a single DB transaction, without evicting
the in-memory ETS session (another device for the same user may still be active).

```
Matrix Client      Go Gateway            Elixir Core               PostgreSQL
     │                   │                    │                         │
     │  POST /logout     │                    │                         │
     │──────────────────►│                    │                         │
     │                   │  JWT invalidated   │                         │
     │                   │  (local denylist)  │                         │
     │                   │  gRPC InvalidateUserSessions(user_id, DDDD) │
     │                   │───────────────────►│                         │
     │                   │                    │  DELETE sync_tokens     │
     │                   │                    │  WHERE (user_id, DDDD)  │
     │                   │                    │─────────────────────────►
     │                   │                    │  DELETE sessions         │
     │                   │                    │  WHERE (user_id, DDDD)  │
     │                   │                    │─────────────────────────►
     │  200 {}           │◄───────────────────│                         │
     │◄──────────────────│                    │                         │
```

**Non-fatal on gRPC failure:** The JWT is already invalidated before the gRPC call. If the Core
call fails, a warning is logged but the client still receives `200 {}` (Matrix spec conformance).

## Scenario 3f: Invite Tiles - Stripped State Enrichment (GAP-INVITE-STATE, Story 9-23)

Matrix Client-Server API spec §4.4.4 requires `invite_state` to contain stripped state events
so clients can display room context before a user accepts an invitation. Without these events,
Element Web invite tiles show no avatar, no join-rules badge, and no creator info.

`buildInviteRooms` in `gateway/internal/matrix/sync.go` queries five stripped state event types
per pending invite room:

| Event type | Content field queried | Inclusion condition |
|---|---|---|
| `m.room.member` | `membership = "invite"` | Always (mandatory by spec) |
| `m.room.name` | `name` | Non-empty name |
| `m.room.join_rules` | `join_rule` | Non-empty join_rule |
| `m.room.avatar` | `url` | Non-empty url |
| `m.room.create` | `creator` | Non-empty creator |

Each query uses a JSONB double-encoding guard (`CASE WHEN jsonb_typeof(content) = 'object'`)
to handle both direct JSONB objects and legacy double-encoded events. Missing events are silently
omitted (spec SHOULD semantics) - no error is returned when an event type is absent for a room.

```
Matrix Client      Go Gateway                                  PostgreSQL
     │                   │                                          │
     │  GET /sync        │                                          │
     │──────────────────►│                                          │
     │                   │  SELECT room_id, inviter_id              │
     │                   │  FROM room_invitations WHERE user_id=$1  │
     │                   │─────────────────────────────────────────►│
     │                   │  ◄── [roomID, inviterID, ...]            │
     │                   │                                          │
     │                   │  -- per room (5 queries, sequential):    │
     │                   │  SELECT content->>'name'                 │
     │                   │    FROM events WHERE room_id=$1          │
     │                   │    AND event_type='m.room.name' LIMIT 1  │
     │                   │─────────────────────────────────────────►│
     │                   │  SELECT content->>'join_rule'            │
     │                   │    FROM events WHERE room_id=$1          │
     │                   │    AND event_type='m.room.join_rules'    │
     │                   │─────────────────────────────────────────►│
     │                   │  SELECT content->>'url'                  │
     │                   │    FROM events WHERE room_id=$1          │
     │                   │    AND event_type='m.room.avatar'        │
     │                   │─────────────────────────────────────────►│
     │                   │  SELECT content->>'creator'              │
     │                   │    FROM events WHERE room_id=$1          │
     │                   │    AND event_type='m.room.create'        │
     │                   │─────────────────────────────────────────►│
     │                   │                                          │
     │  200 {rooms.invite: {                                        │
     │    invite_state.events: [                                     │
     │      {type: "m.room.member", membership: "invite"},          │
     │      {type: "m.room.name", content: {name: "..."}},          │
     │      {type: "m.room.join_rules", content: {join_rule: "..."}},
     │      {type: "m.room.avatar", content: {url: "mxc://..."}},   │
     │      {type: "m.room.create", content: {creator: "@..."}},    │
     │    ]}}                                                        │
     │◄──────────────────│                                          │
```

**Performance note:** The five queries run sequentially per invite room. For typical instances
with few pending invites (< 10) this is negligible. Batching is deferred to Phase 2.

## Scenario 3g: Top-Level Global Account Data Injection (GAP-GLOBAL-ACCOUNT-DATA, Story 9-24)

Matrix spec §6.3 requires a top-level `account_data` key in every sync response carrying global
`m.*` events (e.g. `m.push_rules`, `m.ignored_user_list`). Without this field, Element Web
cannot apply push rule customisations or ignored-user lists set by the client.

All four sync paths now call `injectGlobalAccountData` before serialising the response:

| Sync path | Call site in `sync.go` |
|---|---|
| Initial sync (`GetInitialSync`) | `GetSync` handler |
| Incremental delta sync (`GetSyncDelta`) | `handleIncrementalSync` - normal delta path |
| Fallback-to-initial (`FallbackToInitial = true`) | `handleIncrementalSync` - fallback branch |
| Buffer fast-path (local ring buffer drain) | `buildResponseFromBufferedEvents` - returns empty section (no DB call) |

The buffer fast-path intentionally skips the DB query: global account data changes are rare, and
the next non-buffered sync cycle will deliver them. This keeps the buffer hot path at zero extra
DB queries.

```
Matrix Client      Go Gateway                                  PostgreSQL
     │                   │                                          │
     │  GET /sync        │                                          │
     │──────────────────►│                                          │
     │                   │  injectGlobalAccountData(userID)         │
     │                   │  withUserDB → SET app.user_id = $1       │
     │                   │  SELECT event_type, content              │
     │                   │    FROM room_account_data                │
     │                   │    WHERE user_id=$1 AND room_id=''       │
     │                   │─────────────────────────────────────────►│
     │                   │  ◄── [(m.push_rules, {...}), ...]        │
     │                   │                                          │
     │  200 {                                                        │
     │    "account_data": {                                          │
     │      "events": [                                              │
     │        {"type": "m.push_rules", "content": {...}},           │
     │        ...                                                    │
     │      ]},                                                      │
     │    "rooms": {...}, ...}                                       │
     │◄──────────────────│                                          │
```

**RLS invariant:** `ListGlobalAccountData` uses `withUserDB` to set the `app.user_id` GUC inside
a transaction before querying. The RLS policy on `room_account_data` (migration 000033) filters
by `current_setting('app.user_id', true)`. Without this GUC the policy silently returns zero rows.

**Empty-section guarantee:** `syncResponse.AccountData` is typed `syncAccountDataSection`
(not a pointer) and never carries `omitempty`. Even when no global account data exists, the
response always contains `"account_data": {"events": []}` - a JSON-null or missing key would
break `matrix-js-sdk`.

## Scenario 3h: Buffer Fast-Path - Synthetic next_batch Token (GAP-BUFFER-NEXT-BATCH, Story 9-25)

When events are already present in the local ring buffer, `handleIncrementalSync` drains
the buffer and returns immediately without a gRPC round-trip to Elixir Core. Prior to this
fix, `buildResponseFromBufferedEvents` echoed the client's `since=` token back as
`next_batch`, causing a stuck-token loop: the client re-sent the same token, the buffer
re-delivered the same delta, and `sync_tokens.updated_at` was never advanced.

**Fix:** `syntheticNextBatch()` (added in Story 9-25) generates a `buf_<unix_ms>_<seq>`
token on every buffer-path response. The token is:

- **Monotonically advancing** - Unix-ms timestamp plus an `atomic.Int64` sequence counter
  ensures uniqueness even for sub-millisecond bursts across goroutines.
- **Opaque to the client** - the `buf_` prefix makes it clearly synthetic; it does not
  collide with Elixir's `v1_<base64url>` since-tokens.
- **Never persisted** - `sync_tokens` is not written from the buffer path. When the client
  sends `?since=buf_<ts>_<seq>` on the next poll, Elixir's `GetSyncDelta` finds no matching
  `sync_tokens` row → `fallback_to_initial = true` → the existing `FallbackToInitial` branch
  issues a safe full re-sync with a fresh real token.

```
Matrix Client      Go Gateway (buffer fast-path)
     │                   │
     │  GET /sync?since=s42_1
     │──────────────────►│
     │                   │  buffer.DrainFor(userID) → [events]
     │                   │  syntheticNextBatch() → "buf_1746518400000_7"
     │  200 {next_batch: "buf_1746518400000_7", rooms: {...}}
     │◄──────────────────│
     │                   │
     │  GET /sync?since=buf_1746518400000_7
     │──────────────────►│
     │                   │  buffer empty → gRPC GetSyncDelta(user_id, "buf_...", device_id)
     │                   │  Elixir: no sync_tokens row for "buf_..." → FallbackToInitial=true
     │                   │  GetInitialSync → fresh real token
     │  200 {next_batch: "s99_3", rooms: {...}}   ← real token resumes normal cycle
     │◄──────────────────│
```

**No stuck-token loops:** Each buffer-path response carries a distinct `next_batch`, so
`matrix-js-sdk` always issues a fresh `since=` on the next poll. The fallback-to-initial
safety net was already production-tested before this story.

## Scenario 3i: Room Upgrade - Matrix §11.35.1 (Story 9-27)

`POST /rooms/{oldRoomId}/upgrade` triggers `gRPC UpgradeRoom` which executes the full
Matrix spec §11.35.1 sequence inside `upgrade_room/2` in `event_dispatcher/server.ex`.

```
Matrix Client      Go Gateway          Elixir Core (upgrade_room/2)         PostgreSQL
     │                   │                        │                               │
     │  POST /upgrade    │                        │                               │
     │──────────────────►│  gRPC UpgradeRoom      │                               │
     │                   │───────────────────────►│                               │
     │                   │                        │  1. verify old room + power_level ≥ 100
     │                   │                        │  2. start_room(new_room_id)           │
     │                   │                        │  3. emit m.room.tombstone (old room)  │
     │                   │                        │──────────────────────────────────────►│
     │                   │                        │  4. emit m.room.create (predecessor)  │
     │                   │                        │──────────────────────────────────────►│
     │                   │                        │  5. Room.Server.join/2 (new room)     │
     │                   │                        │  6. Room.Server.set_power_levels/3    │
     │                   │                        │  7. copy_state_events                 │
     │                   │                        │──────────────────────────────────────►│
     │                   │                        │  8. insert_invitation per old member  │
     │                   │                        │──────────────────────────────────────►│
     │                   │                        │  9. archive_room_atomic(old_room_id)  │
     │                   │                        │──────────────────────────────────────►│
     │                   │                        │  10. terminate_child(old_pid)         │
     │                   │  {new_room_id}          │  11. audit_log "room_upgraded/success"│
     │                   │◄───────────────────────│                               │
     │  200 {new_room_id}│                        │                               │
     │◄──────────────────│                        │                               │
```

**Error handling invariants (Story 9-27 fixes):**

- `Room.Server.join/2` and `Room.Server.set_power_levels/3` are wrapped in `case` expressions.
  Unexpected `{:error, reason}` tuples raise `GRPC.RPCError` with `GRPC.Status.internal()`,
  surfacing as HTTP 500 (not MatchError → `codes.Unknown`).
- `archive_room_atomic/1` uses SELECT FOR UPDATE; `:not_found` is handled idempotently (`:ok`)
  to tolerate concurrent admin operations.
- `terminate_child/2` failure is non-fatal: a `Logger.warning` is emitted but the upgrade
  response is still returned (the GenServer will idle and be collected by Horde on restart).
- The entire upgrade body is wrapped in `try/rescue` that writes a "failure" audit entry
  (with `error` field) before reraising, ensuring partial upgrades leave an audit trail.

**Audit trail:** Both success and failure paths write to `audit_logs` via `audit_writer_module().log/6`
with action `"room_upgraded"`, target `old_room_id`, and `%{"new_room_id" => ..., "error" => ...}` metadata.

## Scenario 3j: Thread Relations - GetRelations + Bundled Aggregations in Sync (Story 9-28 / 9-29)

Stories 9-28 and 9-29 together add two complementary mechanisms for Matrix threaded messages.

### 3j-1: Explicit relation fetch

Story 9-29 extended the single `/{relType}` route to three variants, all handled by the same
`GetRelationsHandler.GetRelations` method:

- `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}` - base route (Story 9-29)
- `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}` - (Story 9-28)
- `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}` - (Story 9-29)

Query params added in Story 9-29: `dir` (`f`/`b`, default `b`), `recurse` (bool, accepted without
error), `from` (pagination token). `limit` existed from Story 9-28.

```
Matrix Client      Go Gateway                         Elixir Core         PostgreSQL
     │                   │                                  │                   │
     │  GET /relations   │                                  │                   │
     │  /{eventId}[/...] │                                  │                   │
     │  ?dir=b&limit=20  │                                  │                   │
     │──────────────────►│  validate dir, recurse params    │                   │
     │                   │  (400 on invalid)                │                   │
     │                   │  gRPC GetRelations               │                   │
     │                   │  (event_type, dir, recurse, from)│                   │
     │                   │─────────────────────────────────►│                   │
     │                   │                                  │  event_in_room?   │
     │                   │                                  │──────────────────►│
     │                   │                                  │  fetch_events_by_ │
     │                   │                                  │  relation/5(room, │
     │                   │                                  │  eventId, relType,│
     │                   │                                  │  limit, opts{dir, │
     │                   │                                  │  event_type})     │
     │                   │                                  │──────────────────►│
     │                   │  GetRelationsResponse            │                   │
     │                   │  {events, next_batch, prev_batch}│                   │
     │                   │◄─────────────────────────────────│                   │
     │  200 {chunk: [...],│                                  │                   │
     │   prev_batch: ...} │                                  │                   │
     │◄──────────────────│                                  │                   │
```

**Query param validation (Story 9-29, Go Gateway):**
- `dir` not in `{"f", "b"}` → `400 M_BAD_PARAM`
- `recurse` not parseable as bool → `400 M_BAD_PARAM`
- `recurse=true` is accepted without error (MVP: Core treats same as `dir=b`)

**Error cases:**
- Non-member → Elixir raises `GRPC.RPCError` with `PERMISSION_DENIED` → Go returns `403 M_FORBIDDEN`
- Unknown event_id → `NOT_FOUND` → `404 M_NOT_FOUND`
- Not authenticated → `401 M_MISSING_TOKEN` (JWT middleware, before gRPC call)

**Ordering and pagination:**
- `dir=b` (default): newest-first (DESC). `dir=f`: oldest-first (ASC).
- `prev_batch` is returned in the response for `dir=b` pagination (Story 9-29, `GetRelationsResponse` field 3).
- `rel_type` empty string = return all relation types (base route case, Story 9-29).
- `event_type` filter applied via dynamic WHERE clause in `fetch_events_by_relation/5` (Story 9-29).

### 3j-2: Bundled aggregations in /sync response (m.relations in unsigned)

Every timeline event that has thread replies receives bundled aggregation data in its `unsigned.m.relations`
JSON field. Element Web reads this to show reply count badges on parent messages without a separate
`/relations` HTTP call.

```
                    Elixir Core (attach_thread_aggregations/3)              PostgreSQL
                          │                                                      │
   build_sync_response    │                                                      │
   (initial or delta)     │  -- for each timeline event:                        │
          │               │  count_thread_children(room_id, event_id)           │
          │               │─────────────────────────────────────────────────────►│
          │               │  fetch_events_by_relation(room_id, event_id,        │
          │               │    "m.thread", limit=1) → latest reply              │
          │               │─────────────────────────────────────────────────────►│
          │               │                                                      │
          │               │  Event.unsigned_relations =                          │
          │               │    JSON {"m.thread": {                               │
          │               │      "count": N,                                     │
          │               │      "latest_event": {...},                          │
          │               │      "current_user_participated": bool               │
          │               │    }}                                                 │
          │               │                                                      │
   Go Gateway (sync.go)   │                                                      │
   syncUnsigned {         │                                                      │
     Age: ...,            │                                                      │
     MRelations: <json>   │  ← from Event.unsigned_relations (field 9)          │
   }                      │                                                      │
```

**Performance invariant:** Events with no thread children have `unsigned_relations = nil` (zero bytes).
The Go gateway sets `MRelations` only when `len(te.GetUnsignedRelations()) > 0`, so `m.relations` is
entirely omitted from the `unsigned` JSON object for non-thread events (`omitempty` on the struct field).

## Scenario 3k: Single Event Fetch - GET /rooms/{roomId}/event/{eventId} (Story 11-8)

`GET /_matrix/client/v3/rooms/{roomId}/event/{eventId}` was previously unregistered. Element Web's
`thread.ts` calls `fetchRootEvent()` on this endpoint to load the parent event of a thread before
rendering replies. Without the route, all thread views returned 404 or a 405 Method Not Allowed.

```
Matrix Client      Go Gateway (event.go)        Elixir Core                  PostgreSQL
     │                     │                          │                           │
     │  GET /rooms/        │                          │                           │
     │  {roomId}/event/    │                          │                           │
     │  {eventId}          │                          │                           │
     │────────────────────►│                          │                           │
     │                     │  validate roomId format  │                           │
     │                     │  validate eventId format │                           │
     │                     │  extract userID from JWT │                           │
     │                     │  gRPC GetEvent           │                           │
     │                     │  (room_id, event_id,     │                           │
     │                     │   user_id)               │                           │
     │                     │─────────────────────────►│                           │
     │                     │                          │  lookup_room(room_id)     │
     │                     │                          │  → {:ok, pid} | NOT_FOUND │
     │                     │                          │  get_state(room_id)       │
     │                     │                          │  MapSet.member?(members,  │
     │                     │                          │    user_id)               │
     │                     │                          │  → false: PERMISSION_DENIED
     │                     │                          │  fetch_event(event_id,    │
     │                     │                          │    room_id)               │
     │                     │                          │──────────────────────────►│
     │                     │                          │  SELECT event_id, room_id,│
     │                     │                          │    sender, event_type,    │
     │                     │                          │    content,               │
     │                     │                          │    origin_server_ts,      │
     │                     │                          │    state_key FROM events  │
     │                     │                          │    WHERE event_id=$1      │
     │                     │                          │    AND room_id=$2 LIMIT 1 │
     │                     │                          │◄──────────────────────────│
     │                     │                          │  attach_thread_           │
     │                     │                          │  aggregations/3           │
     │                     │  GetEventResponse{event} │                           │
     │                     │◄─────────────────────────│                           │
     │                     │  protoEventToMatrix(event)                           │
     │  200 {event JSON}   │                          │                           │
     │◄────────────────────│                          │                           │
```

**Error cases:**

| Condition | gRPC code | HTTP response |
|---|---|---|
| Room not found in Horde registry | `NOT_FOUND` | `404 M_NOT_FOUND` |
| User not in room's members MapSet | `PERMISSION_DENIED` | `403 M_FORBIDDEN` |
| Event not found in DB | `NOT_FOUND` | `404 M_NOT_FOUND` |
| DB error | `INTERNAL` | `500 M_UNKNOWN` |
| Invalid roomId format | (client-side) | `400 M_INVALID_PARAM` |
| Invalid eventId format | (client-side) | `400 M_INVALID_PARAM` |

**Also fixed in Story 11-8:** `core/apps/event_dispatcher/lib/pb/core_grpc.pb.ex` was missing both
`rpc :GetRelations` and `rpc :GetEvent` entries. The absence of `rpc :GetRelations` caused
`GET /relations?dir=b&recurse=true` calls to return `500` from Elixir instead of the expected
`GetRelationsResponse`. Both stubs were added manually (protoc-gen-elixir does not auto-update the
service module when `.proto` changes).

## Scenario 3l: Matrix Login - Configurable OIDC Claim Mapping (Story 11-10)

When a user authenticates via `POST /_matrix/client/v3/login`, the Matrix user ID is now derived
from the claim configured in `server_config.oidc_user_id_claim` (loaded with a 60-second TTL cache
via `claimLoader` in `main.go`) rather than being hardcoded to the `name` claim.

```
Matrix Client      Go Gateway (login.go + middleware/auth.go)        PostgreSQL (server_config)
     │                         │                                              │
     │  POST /login            │                                              │
     │  {type: m.login.token}  │                                              │
     │────────────────────────►│                                              │
     │                         │  claimLoader.get(ctx)                        │
     │                         │  → cached oidc_user_id_claim (TTL 60s)       │
     │                         │  or DB read: SELECT value FROM server_config │
     │                         │    WHERE key='oidc_user_id_claim'            │
     │                         │─────────────────────────────────────────────►│
     │                         │  ◄── "preferred_username" (or "sub", etc.)   │
     │                         │                                              │
     │                         │  FormatUserIDFromClaims(                     │
     │                         │    claimName, allClaims, serverName)         │
     │                         │  → claims[claimName] → sanitiseLocalpart     │
     │                         │  → "@alice:server" (or SHA-256 fallback)     │
     │  200 {user_id, token}   │                                              │
     │◄────────────────────────│                                              │
```

**Fallback chain:**
1. `claimLoader` returns the value of `oidc_user_id_claim` from `server_config` (cached 60s).
2. If the DB key is absent or the loader returns `""`, the gateway falls back to `"name"` - identical
   to pre-11-10 behavior (AC7 backward compatibility guarantee).
3. `NEBU_OIDC_USER_ID_CLAIM` env var overrides the DB value as a last-resort escape hatch.
4. Inside `FormatUserIDFromClaims`: if `claims[claimName]` is empty or fails `sanitiseLocalpart`,
   the function falls back to `FormatUserID(sub, serverName)` (SHA-256 opaque localpart).

**JWTMiddleware** follows the same loader pattern for the `Authorization: Bearer` path (Matrix API
requests after login). The `userIDClaimLoader` function is injected as the 5th parameter; `nil`
activates the backward-compat `"name"` claim path.

**Identity stability warning:** The Matrix user ID is a permanent identifier. Changing
`oidc_user_id_claim` after users have registered will generate different Matrix user IDs for the
same OIDC principals, breaking all room memberships. The Admin UI settings page and the Bootstrap
Wizard Step 3 both display a prominent stability warning.

## Scenario 3m: Matrix Client Session Refresh - Opaque Tokens (Story fix-short-oidc-sessions)

Matrix users on Element Web and FluffyChat previously faced force-logout within minutes when the OIDC
`id_token` expired (Keycloak default: 5 minutes). The fix implements Matrix v1.3 opaque session tokens
with server-side storage, matching the admin UI session refresh pattern.

```
Matrix Client      Go Gateway (login.go)                 PostgreSQL (matrix_sessions)
     │                     │                                        │
     │  POST /login        │                                        │
     │  {type:m.login.     │                                        │
     │   token,            │                                        │
     │   refresh_token:true}                                        │
     │────────────────────►│                                        │
     │                     │  gRPC ValidateToken (OIDC verify)      │
     │                     │  ← {user_id, oidc_refresh_token}       │
     │                     │  Generate opaque AT + RT (32 bytes)     │
     │                     │  Encrypt OIDC RT with AES-256-GCM      │
     │                     │  INSERT into matrix_sessions            │
     │                     │─────────────────────────────────────────►
     │                     │  ◄── (success or conflict-ignore)       │
     │  200 {              │                                        │
     │    access_token: <hex>, (opaque, no dots)                    │
     │    refresh_token: <hex>, (opaque, no dots)                   │
     │    expires_in_ms: 28800000, (8 hours)                        │
     │    user_id, device_id                                        │
     │  }                  │                                        │
     │◄────────────────────│                                        │
```

**AC1 — Opaque token format:** access_token and refresh_token are 32 random bytes → 64 hex chars,
no `.` characters (distinguishable from JWTs). `expires_in_ms` is present only when client sends
`refresh_token: true`.

**AC7 — Backward compatibility:** Clients omitting `refresh_token: true` receive the OIDC JWT directly
(old behavior), no `expires_in_ms`, no `refresh_token` field. Existing non-SSO clients unaffected.

```
Matrix Client      Go Gateway (refresh.go)                PostgreSQL (matrix_sessions)
     │                     │                                        │
     │  POST /refresh      │                                        │
     │  {refresh_token:<hex>}                                       │
     │────────────────────►│  (NO auth header required)             │
     │                     │  SELECT BY refresh_token               │
     │                     │─────────────────────────────────────────►
     │                     │  ◄── {access_token, expires_at, ...}   │
     │                     │  AC4: Check grace period window        │
     │                     │  Generate new opaque AT + RT           │
     │                     │  INSERT new session row                │
     │                     │  UPDATE old row: revoked_at=NOW(),     │
     │                     │    grace_until=NOW()+60s                │
     │                     │─────────────────────────────────────────►
     │  200 {              │                                        │
     │    access_token: <new_hex>,                                  │
     │    refresh_token: <new_hex>,                                 │
     │    expires_in_ms: 28800000                                   │
     │  }                  │                                        │
     │◄────────────────────│                                        │
     │                     │                                        │
     │  [client uses new AT for subsequent requests]                │
     │  GET /sync          │                                        │
     │  Authorization: Bearer <new_hex>                             │
     │────────────────────►│  WithOpaqueSessionCheck                │
     │                     │  SELECT FROM matrix_sessions           │
     │                     │  WHERE access_token=$1 (opaque)        │
     │                     │─────────────────────────────────────────►
     │                     │  ◄── {user_id, device_id, expires_at}  │
     │                     │  If not found: 401 M_UNKNOWN_TOKEN      │
     │                     │  If expires_at < NOW(): 401 + soft_logout │
     │                     │  If valid: MarkAccessTokenUsed(AT)      │
     │                     │─────────────────────────────────────────►
     │                     │    (expiry grace window for old RT)     │
     │  200 {sync response}│                                        │
     │◄────────────────────│                                        │
```

**AC4 — Grace period (Spec MUST):** The old refresh token remains valid for 60 seconds after
`/refresh` returns, covering the case where a client fails to persist the new tokens. Once the new AT
is used in any authenticated request, the grace window expires immediately via `MarkAccessTokenUsed`.
A subsequent `/refresh` call with the old RT returns `401 M_UNKNOWN_TOKEN`.

**AC5 — Expired opaque token soft logout:** When an opaque AT in the DB has `expires_at < NOW()`,
the gateway returns `401 M_UNKNOWN_TOKEN` with `soft_logout: true` (Matrix spec v1.3 semantics).

**AC8 — Session persistence across OIDC expiry:** Nebu refreshes the session independent of the OIDC
provider's token lifetime. A session with `expires_at = NOW() + 8 hours` persists even if Keycloak's
token expires after 5 minutes (the OIDC RT is refreshed transparently if configured, but the Nebu AT
lifetime is decoupled from OIDC).

**Database:** New table `matrix_sessions` (migration 000001 squash) with columns:
- `access_token` (PK), `refresh_token` (UNIQUE), `oidc_refresh_token` (encrypted AES-256-GCM),
  `user_id`, `device_id`, `expires_at`, `revoked_at`, `grace_until`, `created_at`.
- Indexes on `refresh_token`, `user_id`, `expires_at`.

**Middleware dispatch:** `WithOpaqueSessionCheck` middleware wrapper in `auth.go` detects opaque tokens
(no `.` character) and routes them to `MatrixSessionStore` lookup instead of OIDC JWT validation.

**Logout:** `POST /logout` calls `MatrixSessionStore.Revoke(opaque_token)` for opaque tokens,
setting `revoked_at = NOW()` (immediate revocation, no grace period on logout).

**Cleanup:** Periodic goroutine deletes expired `matrix_sessions` rows (7+ days old) hourly.

## Scenario 3n: Bootstrap Wizard - Step 3 Claim Mapping (Story 11-10)

The Bootstrap Wizard now has four steps. Step 3 (Claim Mapping) is inserted between the OIDC
credentials step and the OIDC redirect:

```
Admin Browser      Go Gateway (bootstrap.go + auth.go)         PostgreSQL
     │                          │                                    │
     │  GET /admin/bootstrap    │                                    │
     │  (Step 1: Instance name) │                                    │
     │─────────────────────────►│                                    │
     │  ... step 1 + 2 completed (existing flow) ...                 │
     │                          │                                    │
     │  POST /admin/bootstrap   │                                    │
     │  (Step 2: OIDC creds)    │                                    │
     │─────────────────────────►│  validate OIDC creds → save draft │
     │  200 Step 3 form         │                                    │
     │◄─────────────────────────│                                    │
     │                          │                                    │
     │  POST /admin/bootstrap   │                                    │
     │  (Step 3: Claim Mapping) │                                    │
     │  oidc_user_id_claim=sub  │                                    │
     │  oidc_displayname_claim= │                                    │
     │    name                  │                                    │
     │  oidc_email_claim=email  │                                    │
     │─────────────────────────►│  validate oidcClaimNameRe          │
     │                          │  SaveDraft(oidc_user_id_claim)     │
     │                          │  SaveDraft(oidc_displayname_claim) │
     │                          │  SaveDraft(oidc_email_claim)       │
     │  302 /admin/login/start  │                                    │
     │    ?mode=bootstrap        │                                    │
     │◄─────────────────────────│                                    │
     │  (OIDC Authorization Code flow with Dex)                      │
     │                          │                                    │
     │  GET /admin/sso/callback │                                    │
     │─────────────────────────►│  ClaimSelectionHandler             │
     │                          │  runInTx:                          │
     │                          │    INSERT server_config admin_group_claim
     │                          │    INSERT server_config bootstrap_completed=true
     │                          │    INSERT server_config oidc_user_id_claim ─────►│
     │                          │    INSERT server_config oidc_displayname_claim ──►│
     │                          │    INSERT server_config oidc_email_claim ─────────►│
     │                          │    clearDraftTx                    │
     │  302 /admin/dashboard    │                                    │
     │◄─────────────────────────│                                    │
```

**Atomicity guarantee:** All five `server_config` keys (including the three claim mapping keys) are
written in a single `runInTx` call. If any write fails, the entire bootstrap transaction is rolled
back - no partial bootstrap state is persisted.

**Defaults:** Step 3 is pre-filled with `sub` / `name` / `email`. Admins may accept the defaults
without modification. For the `oidc_user_id_claim` field a `<datalist>` provides suggestions
(`sub`, `preferred_username`, `email`).

## Scenario 3n: Read Receipt - Start on Demand After Stack Restart (Story 11-11)

`POST /_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}` returned `404 M_NOT_FOUND`
after any stack restart because `send_receipt/2` previously called `lookup_room/1`, which returns
`{:error, :not_found}` for rooms that exist in the DB but have no running GenServer. The fix aligns
receipts with the "start on demand" pattern already used by `sync`, `unarchive_room`, and `upgrade_room`.

```
Matrix Client      Go Gateway (receipts.go)     Elixir Core (send_receipt/2)   PostgreSQL
     │                        │                            │                        │
     │  POST /receipt/        │                            │                        │
     │   m.read/{eventId}     │                            │                        │
     │───────────────────────►│  gRPC SendReceipt          │                        │
     │                        │───────────────────────────►│                        │
     │                        │                            │  start_room(room_id)   │
     │                        │                            │  ← idempotent: {:ok,pid}
     │                        │                            │    if already running  │
     │                        │                            │    OR just started from│
     │                        │                            │    DB (restart case)   │
     │                        │                            │  {:error,_} → NOT_FOUND│
     │                        │                            │  (room absent from DB) │
     │                        │                            │                        │
     │                        │                            │  try get_state(room_id)│
     │                        │                            │  catch :exit {:noproc} │
     │                        │                            │  → NOT_FOUND (race)    │
     │                        │                            │                        │
     │                        │                            │  membership check      │
     │                        │                            │  → PERMISSION_DENIED   │
     │                        │                            │  if non-member         │
     │                        │                            │                        │
     │                        │                            │  upsert_receipt/4      │
     │                        │                            │──────────────────────►│
     │                        │  SendReceiptResponse{}     │                        │
     │                        │◄───────────────────────────│                        │
     │  200 {}                │                            │                        │
     │◄───────────────────────│                            │                        │
```

**Error cases after fix:**

| Condition | Path | HTTP response |
|---|---|---|
| Room exists in DB, GenServer not running (restart) | `start_room` starts GenServer on demand → success | `200 {}` |
| Room absent from DB entirely | `start_room` → `Room.Server.init/1` → `{:stop, :room_not_found_in_db}` → `{:error, _}` | `404 M_NOT_FOUND` |
| Race: GenServer stops between `start_room` and `get_state` | `try/catch :exit {:noproc, _}` in `send_receipt/2` | `404 M_NOT_FOUND` |
| User not a member of the room | `MapSet.member?/2` returns false | `403 M_FORBIDDEN` |

**Idempotency invariant:** `start_room/1` in `RoomSupervisor` handles `{:error, {:already_started, pid}}` internally and returns `{:ok, pid}`. The handler always receives either `{:ok, pid}` (GenServer running) or `{:error, _}` (room absent from DB). No special case needed for the "already running" path.

## Scenario 4: Compliance Four-Eyes Export Flow

```
Compliance Officer → POST /api/v1/compliance/access-requests (JWT auth)
Instance Admin 1 → POST /approve (four-eyes gate: needs 2 approvals)
Instance Admin 2 → POST /approve (gate satisfied → access session issued)
Compliance Officer → GET /api/v1/compliance/export (X-Compliance-Token, 24h TTL)
Export → Ed25519-signed JSON/PDF with event content + audit trail
Auto-expiry → session invalidated after 24 hours
```

## Scenario 5: Elixir Core Restart Recovery

On restart, Horde re-discovers Room GenServers across the cluster via CRDT registry.
Session Manager GenServer reads since-token checkpoints from PostgreSQL (no cold-sync forced on clients).
EventBus stream re-connects to Go Gateway after exponential backoff (max 30s + jitter).

**On-demand Room GenServer restart (lazy restart pattern):**

Several gRPC handlers participate in lazy restart — they catch `:exit, {:noproc, _}` from a `GenServer.call` and attempt `RoomSupervisor.start_room/1` before retrying:

| Handler | Added in |
|---|---|
| `send_receipt/2` | story direct-room-heroes |
| `get_room_state/2` (read path used by Go Gateway sync) | bugfix/fix-room-management-error |

If `start_room` returns `{:error, reason}` the handler returns gRPC `NOT_FOUND` and logs the reason at `warning` level. If the room starts but the process stops before `get_state` completes, `{:noproc, _}` → `NOT_FOUND`; `{:timeout, _}` → `UNAVAILABLE`.

## Scenario 6: SSO Login Flow with Nonce and Denylist Verification (Story 11-7)

The SSO flow now enforces a three-layer security mechanism to prevent the Safari re-login bug
where a cached id_token or a cached 302 redirect caused Element Web to land on `#/welcome`.

```
Matrix Client      Go Gateway (sso.go)        Dex OIDC              PostgreSQL (token_denylist)
     │                   │                       │                           │
     │  GET /sso/redirect │                       │                           │
     │  ?redirectUrl=...  │                       │                           │
     │──────────────────►│                       │                           │
     │                   │  generate 16-byte nonce (hex encoded)             │
     │                   │  generate 16-byte state                            │
     │                   │  globalSSOState.save(state, verifier,             │
     │                   │    redirectURL, nonce, 10min)                     │
     │                   │  -- capacity check: reject at 10,000 entries     │
     │  302 Location:    │                       │                           │
     │  Cache-Control:   │                       │                           │
     │    no-store       │                       │                           │
     │◄──────────────────│                       │                           │
     │  (browser follows redirect to Dex)        │                           │
     │──────────────────────────────────────────►│                           │
     │                   │                       │  auth code issued          │
     │  GET /sso/callback?code=...&state=...     │                           │
     │──────────────────►│                       │                           │
     │                   │  globalSSOState.pop(state) → {verifier, nonce}   │
     │                   │  oauth2.Exchange(code, verifier)                  │
     │                   │──────────────────────►│                           │
     │                   │  id_token             │                           │
     │                   │◄──────────────────────│                           │
     │                   │  verify id_token (callbackVerifier)               │
     │                   │  extract nonce claim                              │
     │                   │  if nonce mismatch → 403 M_FORBIDDEN             │
     │                   │    "SSO nonce mismatch"                           │
     │                   │  globalLoginTokens.save(opaqueToken, idToken, 30s)│
     │  302 Location:    │                       │                           │
     │  redirectUrl?     │                       │                           │
     │  loginToken=xxx   │                       │                           │
     │◄──────────────────│                       │                           │
     │                   │                       │                           │
     │  POST /login      │                       │                           │
     │  {type:m.login.   │                       │                           │
     │   token, token:xx}│                       │                           │
     │──────────────────►│                       │                           │
     │                   │  globalLoginTokens.pop(opaqueToken) → rawJWT     │
     │                   │  oidc.Verify(rawJWT)  │                           │
     │                   │  h.store.IsInvalidated(rawJWT)?                  │
     │                   │──────────────────────────────────────────────────►│
     │                   │  if invalidated → 403 M_FORBIDDEN                 │
     │                   │    "Token has been logged out"                    │
     │  200 {access_token}│                      │                           │
     │◄──────────────────│                       │                           │
```

**Three failure paths mitigated:**

| Path | Root Cause | Fix |
|---|---|---|
| Path A - cached id_token | Dex reuses a 24h-cached JWT (nonce not required) | Nonce generated per request in GetSSORedirect; nonce claim verified in GetSSOCallback - stale JWTs rejected before loginToken is issued |
| Path B - Safari cached 302 | Safari replays cached redirect with a consumed state | `Cache-Control: no-store` on the SSO 302 response prevents the redirect from being cached |
| Path C - direct POST /login with invalidated JWT | PostLogin did not consult the denylist | `h.store.IsInvalidated(rawJWT)` called in PostLogin before issuing access_token; returns `403 M_FORBIDDEN` (not 401, as this is an auth *attempt*) |

**State store capacity cap:** `globalSSOState.save` rejects any entry when the store already
holds ≥ 10,000 non-expired entries. `GetSSORedirect` returns `429 M_LIMIT_EXCEEDED`.
This prevents unbounded memory growth from unauthenticated flood attacks.

**LoginHandler.store nil-safety:** When `LoginConfig.Store` is `nil` (deployments without
a denylist, test setups), the denylist check in PostLogin is skipped. This preserves
backwards compatibility.

**Dynamic OIDC client credentials (bugfix-sso-bootstrap-credentials):**

`GetSSORedirect` and `GetSSOCallback` resolve `client_id` and `client_secret` via TTL-cached
loaders rather than static startup values. On every SSO flow, `resolveClientID(ctx)` and
`resolveClientSecret(ctx)` are called: each delegates to the loader, which returns a value
read from `server_config` (Bootstrap-configured) within the last 60 seconds, or falls back
to the `NEBU_OIDC_CLIENT_ID` / `NEBU_OIDC_CLIENT_SECRET` env vars when the DB has no entry.
See §8 OIDC Client Credential Source Hierarchy for the full precedence chain and decryption
details. No gateway restart is required after the Bootstrap Wizard stores new credentials.

## Scenario 3o: Room Summary (m.heroes) in Sync — Direct Room Hero Names (Story direct-room-heroes)

Matrix CS API §11.2.2 defines a `summary` block inside each joined room's sync response:

```json
{
  "rooms": {
    "join": {
      "!room:example.com": {
        "summary": {
          "m.heroes": ["@alice:nebu.local", "@bob:nebu.local"],
          "m.joined_member_count": 2,
          "m.invited_member_count": 0
        },
        "state": { ... },
        "timeline": { ... }
      }
    }
  }
}
```

Clients (Element Web, FluffyChat) use `m.heroes` to derive a display name for rooms that have no explicit `m.room.name` state event. For a two-person DM, the client renders the other participant's display name instead of showing "Empty Room".

### Implementation

**Proto (proto/core.proto):**

Three new fields were added to the `SyncRoom` message (fields 6–8):

```protobuf
repeated string heroes               = 6;  // m.heroes — max 5 participant user_ids
int32           joined_member_count  = 7;  // m.joined_member_count
int32           invited_member_count = 8;  // m.invited_member_count
```

**Elixir Core (event_dispatcher server.ex):**

`attach_heroes/3` is a private function called from `get_initial_sync` (always) and `fetch_delta_rooms` (only when `membership_changed` — the delta contains `m.room.member` events, per §11.2.2 which permits summary omission when heroes are unchanged).

`attach_heroes/3` logic:
1. If a state event `m.room.name` with a non-empty `name` is present → leave proto3 zero values (Go omits summary via `omitempty`).
2. Otherwise → call `messages_db_module().get_room_heroes(room_id, user_id)`.
3. On DB error → log warning and return `sync_room` unchanged (fail-open; client retains cached heroes).

**DB layer (room_manager/db.ex):**

`get_room_heroes/2` runs three parameterized queries:
- Heroes: UNION ALL of active joined members (ORDER BY joined_at ASC LIMIT 5) and pending invitations, globally limited to 5 entries, excluding the syncing user.
- Joined count: total active members (inclusive of syncing user).
- Invited count: total pending invitations.

**Go Gateway (sync.go):**

`syncRoomSummary` struct marshals the three fields with Matrix-standard JSON keys (`m.heroes`, `m.joined_member_count`, `m.invited_member_count`). The field is a pointer (`*syncRoomSummary`) on `syncJoinedRoom` with `omitempty` — named rooms never emit a `"summary"` key.

```
Matrix Client           Go Gateway           Elixir Core            PostgreSQL
     │                      │                      │                     │
     │  GET /sync           │                      │                     │
     │─────────────────────►│                      │                     │
     │                      │  GetInitialSync      │                     │
     │                      │─────────────────────►│                     │
     │                      │                      │ get_room_heroes      │
     │                      │                      │────────────────────►│
     │                      │                      │◄── {heroes, joined, invited}
     │                      │                      │                     │
     │                      │◄── SyncRoom{heroes:  │                     │
     │                      │      ["@bob:..."],   │                     │
     │                      │      joined: 2,      │                     │
     │                      │      invited: 0}     │                     │
     │                      │                      │                     │
     │  200 {rooms.join.    │                      │                     │
     │    summary: {        │                      │                     │
     │      m.heroes: [...],│                      │                     │
     │      m.joined_member_count: 2}}             │                     │
     │◄─────────────────────│                      │                     │
```

**Delta sync optimization:** Heroes are only re-sent when `membership_changed` (the delta contains at least one `m.room.member` event). When no membership events are present, the `SyncRoom` proto has zero-value fields for heroes/counts, and the Go layer omits the `summary` key entirely. Clients use their previously cached heroes for display.

_Source: Story direct-room-heroes (epic: room-naming-and-default-rooms); Matrix CS API §11.2.2._

## Scenario 3p: Auto-Join Rooms — New User Provisioning (Story admin-auto-join-rooms)

Admins can mark any room as `is_auto_join = true` in the Admin UI. Every newly provisioned user is
automatically joined to all such rooms at first login, without manual invite.

**Admin toggle flow:**

1. Admin submits the settings form (`POST /admin/rooms/{roomId}/settings`) with `is_auto_join=true`.
2. `UpdateRoomSettingsHandler` (Go) reads `r.FormValue("is_auto_join") == "true"`, creates a pointer,
   and passes it in `UpdateRoomSettingsRequest{IsAutoJoin: &isAutoJoin}` via gRPC.
3. `update_room_settings/2` (Elixir) checks `is_nil(req.is_auto_join)` — only updates when the optional
   field is present. Calls `admin_db_module().update_room_auto_join(room_id, is_auto_join)`.
4. DB: `UPDATE rooms SET is_auto_join = $2 WHERE room_id = $1` (parametrised).

**New-user auto-join flow (at first login):**

1. OIDC login → `validate_token` gRPC call reaches `Nebu.EventDispatcher.Server.validate_token/2`.
2. `Nebu.Session.TokenValidator.Postgres.validate/4`:
   - `lookup_user/1` returns `nil` (user not in DB) → `provision_new_user/4` → returns `is_new: true`.
   - Existing user → `decrypt_and_return/1` → returns `is_new: false`.
3. In `validate_token/2`: `is_new = Map.get(user, :is_new, false)`. A `Task.start` fire-and-forget is launched:
   - Always: `ensure_personal_room/1` (Story personal-self-room).
   - Only when `is_new = true`: `ensure_auto_join_memberships/1`.
4. `ensure_auto_join_memberships/1`:
   - `messages_db_module().list_auto_join_rooms()` → `SELECT room_id FROM rooms WHERE is_auto_join = true AND status = 'active'`.
   - For each room_id: `Nebu.Room.RoomSupervisor.start_room(room_id)` (idempotent) + `Nebu.Room.Server.join(room_id, user_id)`.
   - `{:error, :already_member}` → silently `:ok` (pre-invited edge case).
   - All errors are non-fatal (warning log, `:ok` returned) — login always succeeds.

```
Client          Go Gateway          Elixir Core                  PostgreSQL
  │  POST /login   │                     │                            │
  │───────────────▶│  ValidateToken gRPC │                            │
  │                │────────────────────▶│                            │
  │                │                     │  lookup_user(@new:...)     │
  │                │                     │───────────────────────────▶│
  │                │                     │  nil (not found)           │
  │                │                     │◀───────────────────────────│
  │                │                     │  provision_user (encrypt)  │
  │                │                     │  is_new: true              │
  │                │                     │  Task.start:               │
  │                │                     │   ensure_personal_room     │
  │                │                     │   ensure_auto_join_memberships
  │                │                     │    list_auto_join_rooms    │
  │                │                     │───────────────────────────▶│
  │                │                     │  [room_id1, room_id2]      │
  │                │                     │◀───────────────────────────│
  │                │                     │  Room.Server.join (each)   │
  │  200 {access_token} │               │                            │
  │◀───────────────│◀────────────────────│                            │
```

**Security notes:**
- `is_auto_join` is admin-only (Admin UI behind `SessionGuardWithRefresh` + CSRF token).
- `list_auto_join_rooms` results are never returned to Matrix clients.
- `ensure_auto_join_memberships` only runs for users with `is_new: true` — set server-side only during DB provisioning.
- Partial index `rooms_auto_join_idx ON rooms (is_auto_join) WHERE is_auto_join = true` keeps the query fast.

**Bulk import provisioning path:** See Scenario 3q below for the identical fire-and-forget pattern triggered by `BulkImportUsers` gRPC call.

_Source: Story admin-auto-join-rooms (epic: room-naming-and-default-rooms)._

## Scenario 3q: Auto-Join Rooms — Bulk Import Provisioning Path (Story auto-join-on-user-import)

The same auto-join + personal self-room behavior from Scenario 3p is extended to the
`BulkImportUsers` gRPC path. When an admin imports users via the SCIM/bulk API, each
newly-provisioned user receives the same room setup as a first-login user — without requiring
a login event.

**Key changes in this story:**

- `BulkImporter.import_users/1` now returns `imported_user_ids: [String.t()]` in addition to
  the existing `imported/skipped/failed` counters. Only users actually provisioned in this call
  appear in the list (skipped and failed users are excluded).
- `bulk_import_users/2` in `event_dispatcher/server.ex` iterates `imported_user_ids` and spawns
  one `Task.start` per newly-imported user — identical fire-and-forget pattern to `validate_token/2`.
- `ensure_auto_join_memberships/1` now wraps `Nebu.Room.Server.join/2` in `try/catch :exit` to
  handle `:noproc` exits non-fatally (race between `start_room` and `join` — same guard as
  `send_receipt/2` added in Scenario 3n).

```
Admin Client    Go Gateway     Elixir Core (bulk_import_users/2)   PostgreSQL
    │               │                   │                               │
    │  POST /import │                   │                               │
    │──────────────►│  BulkImportUsers  │                               │
    │               │──────────────────►│                               │
    │               │                   │  BulkImporter.import_users/1  │
    │               │                   │  → {:ok, %{imported: N,       │
    │               │                   │      imported_user_ids: [...]}}│
    │               │                   │                               │
    │               │                   │  audit_writer: users_bulk_imported
    │               │                   │                               │
    │               │                   │  Enum.each(imported_user_ids):│
    │               │                   │    Task.start per user:       │
    │               │                   │      ensure_personal_room     │
    │               │                   │      ensure_auto_join_memberships
    │               │                   │        list_auto_join_rooms  ─►│
    │               │                   │        Room.Server.join (each) │
    │               │                   │        try/catch :exit         │
    │               │                   │                               │
    │  200 {imported, skipped, failed}  │                               │
    │◄──────────────│◄──────────────────│                               │
```

**Non-blocking guarantee:** The gRPC response (`BulkImportUsersResponse`) is returned before any
`Task.start` goroutines complete. Room setup happens asynchronously — the import latency is not
affected by the number of auto-join rooms or the time taken by `Room.Server.join/2`.

**Idempotency:** `ensure_auto_join_memberships/1` returns `:ok` on `{:error, :already_member}` —
safe to call even if a previous import partially completed.

**Error isolation:** Each per-user `Task.start` is independent. A crash in one user's room setup
does not affect other users. All errors are non-fatal warning logs only.

_Source: Story auto-join-on-user-import (epic: room-naming-and-default-rooms)._

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Implementation Patterns, §API & Kommunikation, §Resilienz & Selbst-Heilung; Story 9-19 (GAP-JOIN-PUBLIC, GAP-LEAVE-ONCE, GAP-FORGET); Story 9-22 (GAP-SINCE-IGNORED - per-device sync tokens, per-device logout cleanup); Story 9-23 (GAP-INVITE-STATE - invite_state stripped state enrichment: join_rules, avatar, create); Story 9-24 (GAP-GLOBAL-ACCOUNT-DATA - top-level account_data delivery in all 4 sync paths, RLS-aware ListGlobalAccountData); Story 9-25 (GAP-BUFFER-NEXT-BATCH - synthetic buf_<ms>_<seq> next_batch token on buffer fast-path, replaces echoed since= token); Story 9-27 (Scenario 3i - full Matrix §11.35.1 room upgrade flow, GRPC.RPCError error handling, archive_room_atomic idempotency, terminate_child, try/rescue failure audit); Story 9-28 (Scenario 3j - GetRelations RPC + bundled m.thread aggregations in sync unsigned field, attach_thread_aggregations, fetch_events_by_relation, count_thread_children, migration 000042); Story 9-29 (Scenario 3j-1 expanded - base route + three-segment route, dir/event_type/recurse/from params, prev_batch response field, fetch_events_by_relation/5 dynamic WHERE builder, 400 validation for invalid dir/recurse); Story 11-7 (Scenario 6 - SSO nonce generation + verification, Cache-Control: no-store on 302, denylist check in PostLogin, ssoStateStore capacity cap at 10,000); Story 11-8 (Scenario 3k - GET /rooms/{roomId}/event/{eventId} new route + GetEvent gRPC RPC, Horde membership guard, fetch_event/2 DB query, attach_thread_aggregations, core_grpc.pb.ex rpc :GetRelations + rpc :GetEvent bug fix); Story 11-10 (Scenario 3l - Matrix login claim mapping: claimLoader TTL-cached DB lookup, FormatUserIDFromClaims fallback chain, JWTMiddleware userIDClaimLoader param, NEBU_OIDC_USER_ID_CLAIM env override; Scenario 3m - Bootstrap Wizard Step 3 claim mapping form, draft save, atomic ClaimSelectionHandler transaction, identity-stability warning); Story 11-11 (Scenario 3n - send_receipt/2 start-on-demand fix: lookup_room → start_room, :noproc guard on get_state, 404 preserved for ghost rooms, 403 preserved for non-members); bugfix-sso-bootstrap-credentials (Scenario 6 addendum - dynamic OIDC client credentials via TTL-cached loaders; resolveClientID/resolveClientSecret in GetSSORedirect + GetSSOCallback; DB precedence over env var; no restart required); Story direct-room-heroes (Scenario 3o - m.heroes room summary in sync response: attach_heroes/3, get_room_heroes/2, syncRoomSummary+omitempty, proto fields 6-8 on SyncRoom, delta optimization via membership_changed check); Story admin-auto-join-rooms (Scenario 3p - auto-join rooms at first login: is_auto_join column+partial-index, list_auto_join_rooms, ensure_auto_join_memberships, is_new flag in TokenValidator, Task.start fire-and-forget, Admin UI toggle + CSRF, update_room_auto_join gRPC+DB); Story auto-join-on-user-import (Scenario 3q - bulk import provisioning path: BulkImporter.import_users/1 returns imported_user_ids, bulk_import_users/2 spawns Task.start per new user, ensure_auto_join_memberships + ensure_personal_room fire-and-forget, try/catch :exit guard on Room.Server.join/2)_
