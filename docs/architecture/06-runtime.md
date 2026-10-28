# 6 Runtime View

> **Reading the sequence diagrams (ADR-021 + `grpc-removal` epic):** Nebu is a single Elixir/OTP
> application. The HTTP plug pipeline (`Nebu.Web` / `Nebu.Matrix.Http*`) and the domain logic
> (`Nebu.Matrix.EventDispatcher.Server`, rooms, sessions, …) run in the same BEAM node; all
> "request handler → domain" steps are **in-process function calls**. Several older diagrams were
> drawn with a separate "Go Gateway" column and a "gRPC" arrow to an "Elixir Core" — read those as
> the in-process HTTP-layer → domain dispatch. Labels such as "gRPC GetSyncDelta" or "gRPC JoinRoom"
> in older scenarios mean "in-process call to `EventDispatcher.Server`"; the `:grpc` dep and all
> `GRPC.*` types were removed in the `grpc-removal` epic (ADR-021, 2026-06-22). `Core.*` are plain
> `defstruct` DTOs; errors are `Nebu.Matrix.Error` / `Nebu.Matrix.Status`.

## Scenario 1: Matrix Client Message Send (Happy Path)

```
Matrix Client      Nebu HTTP layer        Domain (EventDispatcher)   PostgreSQL
     │                   │                        │                     │
     │  PUT /rooms/send  │                        │                     │
     │──────────────────►│                        │                     │
     │                   │  OidcPlug: verify JWT  │                     │
     │                   │  → user_id, role       │                     │
     │                   │  send_event/… (in-proc)│                     │
     │                   │───────────────────────►│                     │
     │                   │                        │  INSERT event        │
     │                   │                        │─────────────────────►│
     │                   │                        │  Ed25519 sign        │
     │                   │                        │  EventId.generate    │
     │                   │  {event_id}            │                     │
     │                   │◄───────────────────────│                     │
     │  200 {event_id}   │                        │                     │
     │◄──────────────────│                        │                     │
```

OIDC validation, the in-process `send_event` call, the DB INSERT and the Ed25519 signing all happen
inside the one application. There is no inter-process boundary to fail between the HTTP layer and the
domain, so there is no gateway-side buffering or GRÜN/GELB/ROT degradation state — the former
`message_buffer` drain strategy existed only to bridge the gateway↔core gRPC boundary that ADR-021
removed. Node-level resilience is provided by OTP supervision + Horde (see Scenario 5) and Docker
`restart: always`.

## Scenario 3: Matrix Client Sync (Long-Poll)

```
Matrix Client      Nebu HTTP layer        Domain (sync + pg groups)
     │                   │                        │
     │  GET /sync        │                        │
     │──────────────────►│                        │
     │                   │  get_sync_delta (in-proc), subscribes to
     │                   │  the user's pg process group; holds the
     │                   │  connection for up to 30s
     │                   │  new event arrives → pg fanout wakes the
     │                   │  waiting sync process
     │  200 {events}     │                        │
     │◄──────────────────│                        │
```

The sync handler runs in a per-request sync Task on the node that received the `GET /sync`; the Task joins the
`:pg` groups `user:<id>` and `room:<id>` of that node. Every writer (room process, join / leave /
createRoom handlers) wakes the members of these groups cluster-wide with `:pg.get_members/1` (never
`get_local_members/1`), so the writer and the waiting long-poll can run on different nodes — no
cross-process streaming connection and no ring buffer are involved. The wake-up message is only a
nudge: the woken task re-reads its state from the database. The room state of a joined room with new
events still comes from its room process through the Horde registry, which replicates by CRDT and can
lag a few hundred milliseconds behind a wake-up: a room that is archived (an upgraded room) or missing
is dropped at once, any other room whose process cannot be resolved is retried for at most one second
per build (one deadline per build, shared by the rooms of the build), then started once on demand and
delivered in the same response; only a room that still cannot be resolved (a transient failure) is left
to the next sync and keeps its own cursor (story sync-stream-position, D13; before: it did not move the
since-token anchor). Because the deadline is shared, a room first
met after another room used up the second is started on its first miss without polling (rare; Horde's
name-conflict resolution, as in the initial sync, handles a duplicate). Worst case of the poll bound per
request is about 31 s of the 35 s task budget (`timeout_ms + 10 s`; three builds before the long poll,
25 s wait, three builds after the wake, one second each), which is why the bound is one second. Each start
attempt adds Horde `start_child`, the init database reads and up to 500 ms of `await_registry` per room
and build: two rooms whose start times out in all six builds cost 6 x (1 + 1) + 25 = 37 s and the task
is killed (the client retries); accepted as rare. A non-archived room that can never start keeps its
own cursor pinned (follow-up `bp`; before story sync-stream-position it pinned the global anchor).

**Incremental `/sync` by stream position (story sync-stream-position, follow-up `fc`).** Since this story
there is no anchor: every event carries a per-room position allocated in commit order (`events.room_pos`,
story events-room-position), and the device's state lives server-side in `sync_room_cursors`, one row per
(user, device, partition room): the position the device was synced to, the room's class then (join /
invite / leave), the `invited_at` marker of a delivered row-only invitation, and the previous generation's
values. The core since token is a constant-size nonce (`s2_` + 16 random bytes) that only selects the
token row's current or previous generation. A build reads the partition, then ONE head statement
(`Room.DB.room_heads/3`: `rooms.event_pos` and the device's cursor row of every partition room), then only
the joined rooms whose head is above their cursor, each by the exact range `(cursor, head]` (newest 20
visible events, `limited` with a real `/messages` `prev_batch` above that); a joined room WITHOUT a
cursor row is read as an initial-sync room instead (the segment-driven newest-20 page up to the head,
legacy events without a position included); a quiet room costs no statement. Invitations and leaves are new by position and class; the leave window is bounded by
positions and, as an extra restriction, by the member row's clocks. The response is persisted in ONE
guarded transaction (the token row's next generation and the changed cursor rows, written only while
the base token is still the row's current or previous one AND the row is still at the generation the
request read: of two concurrent requests of one device built from the same base the second one writes
nothing, its response is sent with a token that is not stored and the client's next request falls back
once; nothing is lost). The previous `next_batch` of a device stays valid for one generation, i.e. until
the client moves on to a newer token (a retry after a lost response continues incrementally; the retry
itself writes a new generation whose previous token is again the one it presented). An unresolvable room
keeps only its own cursor (see the previous paragraph). A joined room without a cursor row (newly
joined, or dropped from an initial sync) is read like an initial-sync room: the newest 20 visible events
up to the head through the segment-driven page read. The initial sync reads the heads before the rooms
are fetched, bounds each page by its head and writes one cursor row per partition room in one bulk
statement. A token row of the timestamp era (`stream_version` 0) or a token without the `s2_` prefix is
the initial-sync fallback (once per client after the update).

**The range read of a re-joined room is bounded by the visible segments (story sync-rejoin-range-scan-bound,
follow-up `cq` (f)).** The plain position range `(cursor, head]` (`Room.DB.fetch_visible_events_in_range/5`) walks
the positions and judges every row, so it meets each hidden row between the cursor and the head; for a
continuously joined room that stretch is empty and the plain range stays the read. A room can hold a hidden
stretch when the cursor's base is an invitation or a leave, or when the viewer's own member event (the higher
position of the partition's latest and previous member event) is above the base position (a leave and re-join
between two syncs, or a profile change): such a room is read by the segmented range read
(`Room.DB.fetch_visible_events_in_range_segmented/5`, one statement, the same answer and the same visibility
fragment). It is driven by the visible history-visibility segments (one index range per visible segment with
`LIMIT limit + 1` inside, plus the viewer's own member events and the hv state events), with the position bounds
`base < room_pos <= head` in every branch and a time floor: the oldest `origin_server_ts` of the events at the
64 positions up to the base (a window with a gap only raises the floor; a window that is empty falls back to the
oldest timestamp of the next 64 positions above the base, a position range like the window; when both ranges
are empty there is no floor, which can cost rows but loses no event; none for base position 0, which is read
like an absent base, see the last sentence). No hidden row is returned and no hidden ordinary row is walked:
the floor probe reads at most 64 rows of the window or, when that is empty, of its fallback range, whatever
their visibility, and only their timestamp. So the cost of the read, and of a replay of the previous `next_batch` (it reads the previous
generation's base and costs what the first request cost), is independent of the hidden history. Accepted
residuals, same class as `cq` (b), the event stays reachable through `/messages`: (1) a late commit with a
timestamp older than the oldest of the 64 events at the base is below the floor: the trigger is a TIME span (the
clock skew must exceed the time spread of the newest 64 events, which is short in a busy room), not a count of
positions; (2) skew plus an overflow: the cut inside a segment is by timestamp and the final cut by position, so
when one visible segment holds `limit + 1` or more events newer by timestamp, a late commit with the highest
position but an old timestamp is not read, only in a `limited` window; (3) the cost of the NEW visible events
since the base is plan dependent: in the worst plan O(M) rows for M new visible events instead of about 21, also
for a `shared` or `world_readable` room where the plain read was cheap (so there it is a regression), M is not
bounded by the age of an invite or leave base (a re-join after a month in a busy public room) and a replay
repeats the read, but it is never a function of the hidden history and the `/sync` rate limit is unchanged. No
statement timeout on `/sync` (follow-up `gk` (4)); a failing read is the existing `503`. A gated room whose base
position is 0 (the device's cursor was written before the room had a positioned event, and the viewer's member
event is above it) is read like an absent base: for a base of class `join` that can re-send up to 20 legacy
events the device already had, and `limited` / `prev_batch` can be set (accepted, the answer still holds only
events the viewer may see).

**State Event Construction in Sync (bugfix: sync-state-events-missing-fields):**

Every `rooms.join[roomId].state.events[]` entry is constructed by `EventDispatcher.build_state_events/2`
and serialized in `Http.build_joined_rooms/1`. Spec compliance requires all state events include
`ClientEventWithoutRoomID` fields (`event_id`, `origin_server_ts`, `unsigned`), not just timeline
events. The fix threads real event identity:
- **DB-backed state** (`m.room.create`, `m.room.name`, generic state events): SELECT `event_id` and
  `origin_server_ts` from the `events` table alongside content/sender (zero added round-trips).
- **GenServer state-backed** (`m.room.power_levels`, and the joined `m.room.member` slots only for the incremental `/sync` and the
  summary / hierarchy paths): capture event identity at the moment each change is applied and persisted in GenServer memory, or
  restore from DB on restart (widened `load_members/1` contract to 5-tuple). **Note (membership-state-model, 2026-10-20):** the
  member slots of the initial `/sync`, `/members` and `/initialSync` are read from the member EVENTS from the database
  (`Room.DB.member_state_slice/2`: the latest member event of every user, every membership, real ids and content).
- **Power levels persistence** (new): `set_power_levels` now emits a real, signed, persisted Matrix
  event via `emit_power_levels_event/3` — replaces the prior denormalized column-only approach. New
  migration `000035_backfill_power_levels_events` backfills one event per pre-existing room.
- **Serialization**: state events now include `event_id`, `origin_server_ts`, `unsigned` (with `age`);
  genuinely missing identity is logged at debug level (rare fallback for very old rooms).

**State Event Construction in Sync — `unsigned.replaces_state` (bugfix: unsigned-replaces-state, 2026-10-07):**

Matrix CS API v1.19 adds a MUST-have `unsigned.replaces_state` field on every state event returned to
clients: the `event_id` of the state event previously current at that `(room_id, type, state_key)`
slot. Nebu now includes this field across all state-event surfaces: `/sync` state.events + timeline
(when state-bearing), `/messages` chunk (state-bearing entries only), `/event/{eventId}`,
`/relations/*`. The field is **absent from `unsigned` entirely** (never `null` or empty string) when no
prior state event exists at the slot.

```
Matrix Client      Nebu app (sync handler)              PostgreSQL (events table)
     │                    │                                        │
     │  GET /sync         │                                        │
     │───────────────────►│  build_state_events/2 collects    │
     │                    │  (room_id, type, state_key,       │
     │                    │   origin_server_ts) tuples of all  │
     │                    │  current state events across rooms │
     │                    │                                        │
     │                    │  attach_predecessors_to_...        │
     │                    │  state_events/2 — SINGLE batched   │
     │                    │  query per sync response:           │
     │                    │  SELECT req.room_id, type, key     │
     │                    │    e.event_id AS replaces_state    │
     │                    │  FROM UNNEST(...) AS req           │
     │                    │  LEFT JOIN LATERAL (                │
     │                    │    SELECT event_id FROM events e2  │
     │                    │    WHERE e2.room_id=req.room_id    │
     │                    │    AND e2.event_type=req.type      │
     │                    │    AND e2.state_key=req.key        │
     │                    │    AND (ts,id) < (req.ts,req.id)   │
     │                    │    ORDER BY ts DESC, id DESC       │
     │                    │    LIMIT 1) e ON true              │
     │                    │──────────────────────────────────►│
     │                    │  ◄── [(room, type, key,            │
     │                    │       replaces_state_id), ...]     │
     │                    │                                        │
     │                    │  Map replaces_state into unsigned   │
     │                    │  (key absent if NULL from query)   │
     │                    │                                        │
     │  200 {                                                      │
     │    "rooms": {"join": {                                     │
     │      "state": {"events": [{                               │
     │        "type": "m.room.member",                           │
     │        "state_key": "@user:host",                         │
     │        "unsigned": {                                       │
     │          "age": 1234,                                      │
     │          "replaces_state": "$prev_member_event"           │
     │        }},                                                 │
     │        {"type": "m.room.name",                            │
     │         "unsigned": {"age": 2345}},  ← no replaces_state  │
     │                                          (first name set) │
     │      ]}}}                                                  │
     │◄──────────────────│                                        │
```

**Key design facts (bugfix: unsigned-replaces-state, AC5 N+1 avoidance; widened by story member-event-prev-content):**
- **Three keys, together or none:** the predecessor lookup returns the predecessor's `event_id`, `content`
  and `sender`, rendered as `unsigned.replaces_state`, `unsigned.prev_content` and `unsigned.prev_sender`.
  They are added only for a state event with a predecessor and always as a triple (a non-state event, the
  first event of a slot and `m.room.create` carry none of them: absent, never `null`). `prev_content` is
  the spec (v1.2+: inside `unsigned`); `prev_sender` and `replaces_state` are Synapse-compatible
  extensions outside the v1.18 text. This is what lets Element mark an accepted DM invitation as a direct
  chat: the invitee's JOIN event carries `prev_content = {"membership": "invite", "is_direct": true}` and
  `prev_sender` = the inviter (matrix-js-sdk `getDMInviter()`).
- **Single batched statement per response:** `Nebu.Matrix.Room.DB.fetch_state_predecessors/1` runs once per
  sync room (joined sections) or per /messages chunk, /event call, /relations call, with ONE statement
  covering all state-event slots. Not one per state event (which would be N+1). The `rooms.leave` section
  of a sync response runs ONE batched lookup for ALL its leave entries together (the slots of every state
  event of every leave timeline), and none when there is no leave entry with a state event. Since story
  membership-state-model (`fl` (c)) `/members` and `/initialSync` state events carry `unsigned` and run ONE batched predecessor statement each.
  `rooms.invite` stripped events keep exactly `type`, `state_key`, `sender`, `content`.
- **Index-backed:** The statement uses UNNEST+LATERAL against the existing
  `events_room_state_idx(room_id, event_type, state_key, origin_server_ts DESC)` index (the own row of a
  requested event is read by the `events` primary key). No migration.
- **Order of a slot (a Nebu rule, not a spec rule):** for member slots (`m.room.member`) the predecessor is
  found in the partition's tie order, built from the same SQL fragments as every other membership read:
  `origin_server_ts`, then the most restrictive membership is the latest (`ban`, `leave`, `invite`, `knock`,
  `join`), then `event_id`. For every other type the order is `(origin_server_ts, event_id)` (stable
  secondary sort for same-millisecond collisions). The user's own join / leave / decline are stamped
  `max(now, latest member event + 1)`, so the invite -> join order of an invitee who joins inside the clock
  lead of a createRoom invite stays strict (follow-up `eu`).
- **Visibility rule (D8, follow-up `es`, enforced by story history-visibility-enforcement):** the three keys
  are omitted when the predecessor is not visible to the viewer under the room's `history_visibility`. The
  predecessor is computed exactly as before and then kept or dropped as a whole (never replaced by an older
  visible row); every client read passes the viewer (`fetch_state_predecessors(slots, viewer: user_id)`, still
  ONE statement for all slots), a nil / empty viewer serves no keys at all.
- **m.room.create optimization:** For every room's create event (first-ever at its slot), the keys are
  always absent. Create events can be omitted from the batch query as a minor optimization (though
  including them is also correct — they just resolve to NULL).
- **Failure mode:** a DB error answers no predecessors for the response and logs ONE warning with the slot
  count and the SQLSTATE code only (never a content, a sender or a row).

**History visibility (story history-visibility-enforcement, follow-up `es`):** which events a member may read
is decided by ONE SQL fragment, `Room.DB.history_visibility_sql/0` (`@sql_history_visibility`), inside the existing
statement of every read path that serves events: `/messages`, the initial and the incremental `/sync` timeline (and
the thread roots prepended to a delta), `/event`, `/relations` (parent and children), `/search`, the
`/initialSync` messages and the predecessor lookup (`prev_content` / `prev_sender` / `replaces_state`). The fragment
builds, per room, the visibility segments of the viewer from the room's `m.room.history_visibility` state events
and the viewer's member events (the existing member fragments: both JSONB forms, the D3 tie order), the special
before-or-after rule for history-visibility events and the viewer's own member events, and the most restrictive
same-millisecond rule; the page reads are driven by the visible segments (index ranges of `events_room_id_ts_idx`),
the inputs come from `events_room_state_idx`. No new statement, no cache (read from the committed events per
statement). The reads fail closed: a failing read is a handled `500` (`/messages`, `/event`, `/relations`,
`/initialSync`, the initial `/sync`, `/search`) or the `503` `M_UNAVAILABLE` of the incremental `/sync` (no since
token stored), with one value-free ERROR line (room id and error class), never an unfiltered page. An invisible
event on `/event` and an invisible parent on `/relations` answer the same `404 M_NOT_FOUND "Event not found"` as an
unknown one. The current state (`/sync` `state`, `/members`, `/initialSync` `state`) is not gated. Test doubles
without the viewer-aware reads fall back to their unfiltered reads; the real `Room.DB` never does.
*Bounds (security cycle 1, follow-up `gk`).* The fragment costs O(B log B) per statement for B boundaries (the room's
history-visibility events + the viewer's member events): sorts and window functions only, a binary search per candidate
row (measured: a later joiner's backward page in a room with 3 000 history-visibility events took 5.2 s with the first,
quadratic version and 46 ms now). The input B is bounded: at most 256 history-visibility state events per room (the room
process refuses the write above it with `429 M_LIMIT_EXCEEDED`, except a strictly more restrictive change: the cap never
blocks tightening, at most 3 more rows; the createRoom chain, preset + at most 64 `initial_state` entries, is not counted), and a PUT of `m.room.history_visibility`,
`m.room.guest_access` or `m.room.join_rules` costs a `moderation` token. The request reads (`/messages` incl. the
`/initialSync` messages, `/event`, `/relations`, `/search`) run in a transaction under `SET LOCAL statement_timeout = '2s'`
(a timeout is the handled `500`); the `/sync` reads are not (a room that always timed out would fail every member's sync).
The incremental `/sync` read computes nothing for a room without new events (the inputs are conditional inside the
statement); a thread aggregation reads the visible latest child only for a message that has children.

**SECURITY FIX — Pre-existing state-event-forgery privilege escalation (bugfix: unsigned-replaces-state, 2026-10-07):**

Nebu's pre-fix `Room.Server.do_send_event/7` collapsed `nil` state_key to `""` before persisting. This
enabled **any joined member at power_level 0** (default) to forge state events via
`PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` (no event-type allowlist on this
path, no :change_state permission check). Forged rows landed in the DB marked `state_key = ''` and
were consumed by every state-derivation query (`get_room_name/1`, `get_generic_state_events/1`,
search encryption predicate, admin space queries). **Attack class: room rename, `m.room.join_rules`
(→ restricted membership-policy bypass), `m.room.history_visibility` (→ private room's summary
exposed to non-members), `m.room.encryption` (→ ADR-011 managed decryption broken).**

Post-fix: `Room.Server.do_send_event/7` persists state_key as SQL `NULL` instead of `""`. The new
`Core.Event.is_state_event` field (server-derived: nil-ness of raw `events.state_key` column)
distinguishes genuine state events from non-state events. Concurrent changes to state-derivation
queries add `is_state_event = true` or `state_key IS NOT NULL` predicates.

**Migration 000036** (`backfill_nonstate_events_null_state_key`): backfills historical corruption via
`UPDATE events SET state_key = NULL WHERE state_key = '' AND event_type IN ('m.room.message')`.
Conservative inclusion-list design: **fail-safe, never deletes legitimate state rows.** For data
planted during the pre-fix attack window, operators must run a documented detection query before
deploying; no blind automated remediation. Partial fix for m.room.message only; other type classes
(e.g. m.reaction, custom types) require manual review and are NOT backfilled (risk of destroying
legitimate custom state events).

## Scenario 3a: Public Room Join - Sync Wakeup (GAP-JOIN-PUBLIC, Story 9-19)

After `POST /join/{roomId}` for a **public room** (no prior invite), the sync long-poll must
deliver `rooms.join[roomId]` within 10 s. Without a fix this hangs for 30 s: the sync Task
only subscribes to `:pg` groups for rooms already in `get_rooms_for_user`; the public-room join
broadcast goes to `room:#{roomId}` which no sync Task monitors yet.

```
Matrix Client      Nebu app    Domain (gRPC join_room/2)
     │                   │                   │
     │  POST /join       │                   │
     │──────────────────►│  gRPC JoinRoom    │
     │                   │──────────────────►│
     │                   │                   │  Room.Server.join → :ok
     │                   │                   │  :pg.get_members("user:#{user_id}")  (cluster-wide)
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

> **Implementation note (story sync-membership-partition, follow-ups `ev` + `ez`):** `buildLeaveRooms` / `buildInviteRooms` were the
> design of the Go gateway and were never ported to the Elixir server; the story above is the target, and the Elixir server implements
> it differently. One partition function (`sync_partition/1` in `Nebu.Matrix.EventDispatcher.Server`) classifies every room of the
> user as join / invite / leave / none from the membership rows and the latest `m.room.member` events (a fixed tie order: the most
> restrictive membership wins), and the incremental sync delivers `rooms.invite` and `rooms.leave` from it. "Once" is NOT based on
> `sync_tokens.updated_at` (a wall-clock time per user, shared by every device) but on the device's per-room CURSOR (story
> sync-stream-position; the story itself used the anchor of the since token): a leave or an invitation is delivered when it is new by
> position and class against the cursor row of the room, moves that cursor to the room's head (so the next sync does not repeat it
> and the long-poll waits instead of looping) and is never delivered in an initial sync. The leave window is the events after the
> cursor (or the join) strictly before the leave event by position, then the leave event; nothing after it is ever read.
> Until this story a left, declined or kicked room was delivered in `rooms.join` with every new event (a confidentiality defect,
> `ez`). Details: `docs/stories/oauth-broker/sync-membership-partition.md`; scope: `docs/matrix-api-scope.md` (`GET /sync`).
> See "Incremental `/sync` by stream position" above for the cursors.

## Scenario 3c: POST /forget - Persistent Room Exclusion (GAP-FORGET, Story 9-19; wired in `forget-room-membership-purge`)

After `POST /rooms/{roomId}/forget`, the room must not appear in any subsequent sync response
(`rooms.join`, `rooms.leave`, `rooms.invite`) until the user re-joins.

> **Implementation note:** Story 9-19 described this design but the Elixir
> `forget_room/2` shipped as a no-op stub (it only ran the join-state guard and returned
> `{}` without persisting). The `forget-room-membership-purge` bugfix epic wired up the
> real behavior against the already-existing `forgotten_rooms` table. There is **no
> GenServer state** — forget is a DB write at `/forget` time and a DB read at sync time.

```
Matrix Client      Nebu app                        PostgreSQL
     │                   │                                │
     │  POST /forget     │                                │
     │──────────────────►│  join-state guard (must be     │
     │                   │  not-joined → else M_BAD_STATE) │
     │                   │  INSERT INTO forgotten_rooms    │
     │                   │  ON CONFLICT DO NOTHING          │
     │                   │──────────────────────────────►│
     │  200 {}           │                                │
     │◄──────────────────│                                │
     │                   │                                │
     │  GET /sync        │                                │
     │──────────────────►│  SELECT room_id FROM forgotten_rooms WHERE user_id = $1
     │                   │──────────────────────────────►│
     │                   │  in-process MapSet reject of those room_ids in BOTH sync
     │                   │  builders (get_initial_sync + do_incremental_sync,
     │                   │  incl. the recently-left list) — keeps the existing
     │                   │  query shapes unchanged
     │  200 (room absent)│                                │
     │◄──────────────────│                                │
```

**Re-join clears the forget:** on a successful `POST /rooms/{id}/join`, `join_room/2`
calls `remove_forgotten_room(user_id, room_id)` so a re-joined room reappears in sync
(Matrix: a re-joined room is no longer forgotten).

**DB table:** `forgotten_rooms (user_id, room_id, forgotten_at_ms BIGINT)` — defined in
the canonical schema `000001_init.up.sql` (NOT a separate 000040 migration; the table
pre-existed and only needed wiring). PRIMARY KEY `(user_id, room_id)`; insert is
idempotent (`ON CONFLICT DO NOTHING`); `ON DELETE CASCADE` on `users` row removal. All
queries (`Nebu.Matrix.Room.DB.insert_forgotten_room/2`, `get_forgotten_room_ids/1`,
`remove_forgotten_room/2`) are parameter-bound (ADR-018) and keyed strictly on the
token's `user_id` (per-user isolation).

## Scenario 3d: Per-Device Sync Token Isolation (GAP-SINCE-IGNORED, Story 9-22)

When a Matrix client opens a sync long-poll, the `device_id` (extracted from the `"did"` claim
of the JWT) is forwarded in `GetSyncDeltaRequest`. The Domain looks up and persists the
`since` token in `sync_tokens` keyed by `(user_id, device_id)` - not just `user_id`.

```
Matrix Client A (device_id=AAAA)    Matrix Client B (device_id=BBBB)    Domain
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

**Fallback:** When `device_id` is empty (legacy client or test), the Server falls back to the
`(user_id, '')` row (legacy arity-3/1 functions) and triggers a full initial sync on mismatch.

Since story sync-stream-position the write of a response is `persist_sync_position/3` (the token row and
the device's `sync_room_cursors` rows in one transaction, guarded by the base token for a delta) instead
of `persist_since_token/4`; the cursor rows hang off the `(user_id, device_id)` token row (`ON DELETE
CASCADE`), so the per-device logout below removes them too.

## Scenario 3e: Per-Device Logout - Sync Token Cleanup (Story 9-22)

After `POST /logout`, the Nebu app calls `InvalidateUserSessions` with both `user_id` and
`device_id`. The Domain deletes the `sync_tokens (user_id, device_id)` row and the
corresponding `sessions (user_id, device_id)` row in a single DB transaction, without evicting
the in-memory ETS session (another device for the same user may still be active).

```
Matrix Client      Nebu app            Domain               PostgreSQL
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

**Non-fatal on domain call failure:** The JWT is already invalidated before the in-process
`invalidate_user_sessions` call. If the call fails, a warning is logged but the client still
receives `200 {}` (Matrix spec conformance).

## Scenario 3f: Invite Tiles - Stripped State Enrichment (GAP-INVITE-STATE, Story 9-23)

Matrix Client-Server API spec §4.4.4 requires `invite_state` to contain stripped state events
so clients can display room context before a user accepts an invitation. Without these events,
Element Web invite tiles show no avatar, no join-rules badge, and no creator info.

`buildInviteRooms` in `the Matrix sync handler (Nebu.Matrix.Http*)` queries five stripped state event types
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
Matrix Client      Nebu app                                  PostgreSQL
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

All three sync paths now call the account data query before serialising the response:

| Sync path | Call site in `Nebu.Matrix.Http*` |
|---|---|
| Initial sync | `get_initial_sync` → `build_sync_response` |
| Incremental delta sync | `do_incremental_sync` - normal delta path |
| Fallback-to-initial | `do_incremental_sync` - fallback branch |

```
Matrix Client      Nebu app                                  PostgreSQL
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

**Account data query:** `Nebu.Matrix.EventDispatcher.Server` queries `room_account_data` with
`room_id = ''` for global-scope account data. The `app.user_id` GUC (PostgreSQL RLS) is set
inside the transaction; the policy on `room_account_data` (migration 000033) filters by
`current_setting('app.user_id', true)`. Without this GUC the policy silently returns zero rows.

**Empty-section guarantee:** Even when no global account data exists, the response always contains
`"account_data": {"events": []}` — a missing key would break `matrix-js-sdk`.

## Scenario 3i: Room Upgrade - Matrix §11.35.1 (Story 9-27)

`POST /rooms/{oldRoomId}/upgrade` calls `Nebu.Matrix.EventDispatcher.Server.upgrade_room/2`
(in-process), which executes the full Matrix spec §11.35.1 sequence.

```
Matrix Client      Nebu app          Domain (upgrade_room/2)         PostgreSQL
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
  Unexpected `{:error, reason}` tuples raise `Nebu.Matrix.Error` with `Nebu.Matrix.Status.internal()`,
  surfacing as HTTP 500 (not MatchError → unknown error).
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
Matrix Client      Nebu app                         Domain         PostgreSQL
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

**Query param validation (Story 9-29, Nebu app):**
- `dir` not in `{"f", "b"}` → `400 M_BAD_PARAM`
- `recurse` not parseable as bool → `400 M_BAD_PARAM`
- `recurse=true` is accepted without error (MVP: Server treats same as `dir=b`)

**Error cases:**
- Non-member → raises `Nebu.Matrix.Error` with `:permission_denied` → HTTP `403 M_FORBIDDEN`
- Unknown event_id → raises `:not_found` → `404 M_NOT_FOUND`
- Not authenticated → `401 M_MISSING_TOKEN` (OidcPlug, before in-process call)

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
                    Domain (attach_thread_aggregations/3)              PostgreSQL
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
   Nebu app (sync handler)   │                                                      │
   syncUnsigned {         │                                                      │
     Age: ...,            │                                                      │
     MRelations: <json>   │  ← from Event.unsigned_relations (field 9)          │
   }                      │                                                      │
```

**Performance invariant:** Events with no thread children have `unsigned_relations = nil` (zero bytes).
The Nebu app sets `MRelations` only when `len(te.GetUnsignedRelations()) > 0`, so `m.relations` is
entirely omitted from the `unsigned` JSON object for non-thread events (`omitempty` on the struct field).

## Scenario 3k: Single Event Fetch - GET /rooms/{roomId}/event/{eventId} (Story 11-8)

`GET /_matrix/client/v3/rooms/{roomId}/event/{eventId}` was previously unregistered. Element Web's
`thread.ts` calls `fetchRootEvent()` on this endpoint to load the parent event of a thread before
rendering replies. Without the route, all thread views returned 404 or a 405 Method Not Allowed.

```
Matrix Client      Nebu app (event handler)        Domain                  PostgreSQL
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

| Condition | Error atom | HTTP response |
|---|---|---|
| Room not found in Horde registry | `:not_found` | `404 M_NOT_FOUND` |
| User not in room's members MapSet | `:permission_denied` | `403 M_FORBIDDEN` |
| Event not found in DB | `:not_found` | `404 M_NOT_FOUND` |
| DB error | `:internal` | `500 M_UNKNOWN` |
| Invalid roomId format | (HTTP layer) | `400 M_INVALID_PARAM` |
| Invalid eventId format | (HTTP layer) | `400 M_INVALID_PARAM` |

**Also fixed in Story 11-8:** The `get_event` and `get_relations` handler clauses were missing
from the `EventDispatcher.Server` dispatch table. Their absence caused `GET /relations?dir=b&recurse=true`
to return `500`. Both handlers were added. (Historically these were `rpc :GetRelations` / `rpc :GetEvent`
entries in the generated gRPC service stub; that stub no longer exists after the `grpc-removal` epic.)

## Scenario 3l: Matrix Login - Configurable OIDC Claim Mapping (Story 11-10)

When a user authenticates via `POST /_matrix/client/v3/login`, the Matrix user ID is derived
from the claim configured in `server_config.oidc_user_id_claim` (loaded with a 60-second TTL cache
via `Nebu.Web.OidcConfig`) rather than being hardcoded to the `name` claim.

```
Matrix Client      Nebu app (login + OIDC plug)        PostgreSQL (server_config)
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
1. `Nebu.Web.OidcConfig` returns the value of `oidc_user_id_claim` from `server_config` (TTL-cached).
2. If the DB key is absent or the loader returns `""`, the handler falls back to `"name"` — identical
   to pre-11-10 behaviour (AC7 backward compatibility guarantee).
3. Inside the claim mapper: if `claims[claimName]` is empty or fails the localpart validator,
   the function falls back to an SHA-256 opaque localpart derived from `sub`.

**Identity stability warning:** The Matrix user ID is a permanent identifier. Changing
`oidc_user_id_claim` after users have registered will generate different Matrix user IDs for the
same OIDC principals, breaking all room memberships. The Admin UI settings page and the Bootstrap
Wizard Step 3 both display a prominent stability warning.

## Scenario 3m: Matrix Client Session Refresh - Opaque Tokens (Story oidc-session-refresh)

> **Stack note (ADR-021):** Realised in the Elixir/OTP stack. Earlier revisions referenced a Go gateway
> (`auth.go`, gRPC ValidateToken, `WithOpaqueSessionCheck`, `MarkAccessTokenUsed`, a cleanup goroutine).
> The current implementation is `Nebu.Web.Plugs.OidcPlug` (token-shape dispatch),
> `Nebu.Matrix.Session.MatrixSessionStore` (inline SQL over `matrix_sessions`), and `Nebu.Web.SecretBox`
> (AES-256-GCM). The in-process token validation replaces the former gRPC call.

Matrix users on Element Web and FluffyChat previously faced force-logout within minutes when the OIDC
`id_token` expired (Keycloak default: 5 minutes). The fix implements Matrix v1.3 opaque session tokens
with server-side storage; the Admin UI solves the same force-logout problem with silent OIDC refresh
(see Scenario 3m-admin).

```
Matrix Client      Nebu app (login handler)                 PostgreSQL (matrix_sessions)
     │                     │                                        │
     │  POST /login        │                                        │
     │  {type:m.login.     │                                        │
     │   token,            │                                        │
     │   refresh_token:true}                                        │
     │────────────────────►│                                        │
     │                     │  validate_token (in-process OIDC verify)│
     │                     │  ← {user_id, oidc_refresh_token}       │
     │                     │  Generate opaque AT + RT (32 bytes)     │
     │                     │  Encrypt OIDC RT (Nebu.Web.SecretBox)   │
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
Matrix Client      Nebu app (refresh handler)                PostgreSQL (matrix_sessions)
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
     │────────────────────►│  OidcPlug (opaque-token branch)        │
     │                     │  SELECT FROM matrix_sessions           │
     │                     │  WHERE access_token_hash=$1            │
     │                     │  (= SHA-256 hex of the opaque token)   │
     │                     │─────────────────────────────────────────►
     │                     │  ◄── {user_id, device_id, expires_at}  │
     │                     │  If not found: 401 M_UNKNOWN_TOKEN      │
     │                     │  Re-check is_active / expires_at:       │
     │                     │  if expired: 401 + soft_logout:true     │
     │                     │  If valid: assign user_id/device_id     │
     │  200 {sync response}│                                        │
     │◄────────────────────│                                        │
```

**AC4 — Grace period (Spec MUST):** The old refresh token remains valid for 60 seconds after
`/refresh` returns, covering the case where a client fails to persist the new tokens. A subsequent
`/refresh` call with the old RT after the window returns `401 M_UNKNOWN_TOKEN`.

**Rate limiting:** `POST /_matrix/client/v3/refresh` is unauthenticated by spec but guarded by the
per-IP `Nebu.Web.Plugs.RateLimit` token bucket.

**AC5 — Expired opaque token soft logout:** When an opaque AT in the DB has `expires_at < NOW()`,
`OidcPlug` returns `401 M_UNKNOWN_TOKEN` with `soft_logout: true` (Matrix spec v1.3 semantics).

**AC8 — Session persistence across OIDC expiry:** Nebu refreshes the session independent of the OIDC
provider's token lifetime. The Nebu session `expires_at = min(oidc_exp, NOW() + 8h)` persists even if
Keycloak's access token expires after 5 minutes — this decoupling is what fixes the "force-logout every
5 min" regression (the OIDC RT is refreshed transparently if configured).

**Database:** New table `matrix_sessions` (migration 000001 squash) with columns:
- `access_token_hash` (PK), `refresh_token_hash` (UNIQUE NOT NULL) - lowercase hex SHA-256 of the opaque
  tokens; plaintext tokens are never stored (migration 000038, story `token-hashing-matrix-sessions`),
  `oidc_refresh_token` (encrypted AES-256-GCM), `user_id`, `device_id`, `expires_at`, `revoked_at`,
  `grace_until`, `created_at`, `auth_time`.
- Indexes: the PK and the UNIQUE constraint on the hash columns, plus `user_id`, `expires_at`.

**Plug dispatch:** `Nebu.Web.Plugs.OidcPlug` detects opaque tokens (no `.` character) and routes them to
the `MatrixSessionStore` lookup branch instead of OIDC JWT validation; the JWT path is unchanged.

**Logout:** `POST /logout` deletes the user's `matrix_sessions` rows (immediate revocation, no grace
period on logout).

**Admin deactivation:** `deactivate_user` also deletes the target user's `matrix_sessions` rows, so a
deactivated user's opaque sessions are killed at once.

## Scenario 3m-admin: Admin UI Silent OIDC Refresh (Story admin-oidc-session-refresh)

The Admin UI (`Nebu.Admin.Auth`) previously capped the admin session at the short
`id_token.exp` with no refresh, so admins were force-logged-out roughly every 5 minutes against
Keycloak. The fix keeps the admin signed in by silently refreshing the OIDC token on HTTP round-trips —
no DB-backed session, no plaintext refresh token at rest. As of Story `oidc-refresh-mode-config` the
refresh below is **gated on the configurable `admin_oidc_refresh_mode`** (`offline | online`, default
`online`): `offline_access` is requested — and silent refresh active — **only** when the mode is
`offline`. The diagram shows the `offline` path.

```
Admin Browser     Nebu app (Nebu.Admin.Auth)                IdP (Keycloak token_endpoint)
     │                     │                                        │
     │  GET /admin/login/start  [admin_oidc_refresh_mode = offline] │
     │────────────────────►│  scope += offline_access               │
     │  302 → IdP ──────────────────────────────────────────────────►
     │  …Auth-Code + PKCE callback…                                 │
     │  GET /admin/callback│                                        │
     │────────────────────►│  exchange code → {id_token, refresh_token}
     │                     │◄────────────────────────────────────────
     │                     │  verify id_token, enforce admin-group  │
     │                     │  Encrypt RT (Nebu.Web.SecretBox AES-GCM)│
     │                     │  session_exp = min(id_token.exp, now+8h)│
     │                     │  put encrypted RT + claims in signed    │
     │                     │  Phoenix session cookie (renew:true)    │
     │  303 → /admin/ ◄─────│                                        │
     │                     │                                        │
     │  [later HTTP request, now within 120s of session_exp]        │
     │  GET /admin/…       │                                        │
     │────────────────────►│  fetch_current_user/2:                 │
     │                     │  session_exp - now ≤ 120s → refresh    │
     │                     │  decrypt stored RT                     │
     │                     │  POST token_endpoint grant=refresh_token
     │                     │───────────────────────────────────────►
     │                     │◄── {new id_token, new refresh_token}   │
     │                     │  OidcPlug.verify_token(new id_token)   │
     │                     │  RE-EVALUATE admin-group on new claims  │
     │                     │  session_exp = min(new exp, now+8h)    │
     │                     │  renew session, rotate encrypted RT    │
     │  200 (page) ◄────────│                                        │
     │                     │                                        │
     │  [refresh fails OR admin group lost]                         │
     │                     │  clear session                         │
     │  302 → /admin/login ◄│                                        │
```

**Refresh window:** `fetch_current_user/2` triggers a refresh when `session_exp - now ≤ 120 s`;
outside the window the request proceeds on the existing session with no IdP round-trip.

**Group re-evaluation:** the admin-group gate is re-checked against the *refreshed* claims, so an admin
removed from the group at the IdP loses access on the next refresh (not only at next full login).

**At-rest:** the OIDC refresh token lives only inside the signed Phoenix session cookie, encrypted with
`Nebu.Web.SecretBox` (AES-256-GCM) — there is no `admin_sessions` table row and no DB persistence.

**Known limitation:** refresh occurs on HTTP round-trips, not over the live LiveView websocket; a tab
sitting idle on a websocket-only LiveView (Dashboard, AuditLog, Bootstrap) is refreshed on its next HTTP navigation. HTTP controller pages trigger refresh on every page load.

**Configurable refresh mode (Story oidc-refresh-mode-config):** the `offline_access` request and the
silent-refresh path above are active only when `admin_oidc_refresh_mode = offline`. The **default is
`online`**, in which the admin flow requests no `offline_access` (no special IdP approval needed) and
relies on the IdP's own session — on Dex this means no refresh token at all, so the admin is logged
out at `session_exp`; Keycloak supports session-bound online refresh. Matrix login is governed by the
sibling key `matrix_oidc_refresh_mode` (default `offline`). Both keys are set at bootstrap and
changeable at runtime via `/admin/config` (`Nebu.Admin.ConfigController`), applying to subsequent logins
with no redeploy; `Nebu.Admin.Auth.admin_oidc_scope/0` and `Nebu.Matrix.SsoLogin.scope_list/0` read
their mode live.

## Scenario 3n: Bootstrap Wizard - Step 3 Claim Mapping (Story 11-10)

The Bootstrap Wizard now has four steps. Step 3 (Claim Mapping) is inserted between the OIDC
credentials step and the OIDC redirect:

```
Admin Browser      Nebu app (admin bootstrap + auth)         PostgreSQL
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
Matrix Client      Nebu app (receipts handler)     Domain (send_receipt/2)   PostgreSQL
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

## Scenario 5: Node Restart Recovery

On restart, Horde re-discovers Room GenServers across the cluster via CRDT registry.
The Session Manager GenServer reads since-token checkpoints from PostgreSQL (no cold-sync forced on
clients). When the cluster has more than one node, libcluster re-forms the BEAM cluster and Horde
re-distributes Room GenServers (see Deployment View, Server Clustering).

**On-demand Room GenServer restart (lazy restart pattern):**

Several domain handlers participate in lazy restart — they catch `:exit, {:noproc, _}` from a `GenServer.call` and attempt `RoomSupervisor.start_room/1` before retrying:

| Handler | Added in |
|---|---|
| `send_receipt/2` | story direct-room-heroes |
| `get_room_state/2` (read path used by the sync handler) | bugfix/fix-room-management-error |

If `start_room` returns `{:error, reason}` the handler returns `NOT_FOUND` and logs the reason at `warning` level. If the room starts but the process stops before `get_state` completes, `{:noproc, _}` → `NOT_FOUND`; `{:timeout, _}` → `UNAVAILABLE`.

## Scenario 6: SSO Login Flow with Nonce and Denylist Verification (Story 11-7)

The SSO flow now enforces a three-layer security mechanism to prevent the Safari re-login bug
where a cached id_token or a cached 302 redirect caused Element Web to land on `#/welcome`.

```
Matrix Client      Nebu app (SSO handler)        Dex OIDC              PostgreSQL (token_denylist)
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

**DTO (`Core.SyncRoom` struct):**

Three fields were added to the `Core.SyncRoom` struct (fields 6–8, originally protobuf — now
plain `defstruct` keys since the `grpc-removal` epic):

```elixir
# heroes: [String.t()]           # m.heroes — max 5 participant user_ids
# joined_member_count: integer   # m.joined_member_count
# invited_member_count: integer  # m.invited_member_count
```

**Domain (event_dispatcher server.ex):**

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

**Nebu app (sync handler):**

`syncRoomSummary` struct marshals the three fields with Matrix-standard JSON keys (`m.heroes`, `m.joined_member_count`, `m.invited_member_count`). The field is a pointer (`*syncRoomSummary`) on `syncJoinedRoom` with `omitempty` — named rooms never emit a `"summary"` key.

```
Matrix Client           Nebu app           Domain            PostgreSQL
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

**Delta sync optimization:** Heroes are only re-sent when `membership_changed` (the delta contains at least one `m.room.member` event). When no membership events are present, the `SyncRoom` proto has zero-value fields for heroes/counts, and the sync handler omits the `summary` key entirely. Clients use their previously cached heroes for display.

_Source: Story direct-room-heroes (epic: room-naming-and-default-rooms); Matrix CS API §11.2.2._

## Scenario 3p: Auto-Join Rooms — New User Provisioning (Story admin-auto-join-rooms)

Admins can mark any room as `is_auto_join = true` in the Admin UI. Every newly provisioned user is
automatically joined to all such rooms at first login, without manual invite.

**Admin toggle flow:**

1. Admin submits the settings form (`POST /admin/rooms/{roomId}/settings`) with `is_auto_join=true`.
2. The Admin HTTP controller (`Nebu.Admin.RoomsController`) reads the submitted value and passes it
   as `is_auto_join` in an `UpdateRoomSettingsRequest` struct to `update_room_settings/2` in-process.
3. `update_room_settings/2` checks `is_nil(req.is_auto_join)` — only updates when the optional
   field is present. Calls `admin_db_module().update_room_auto_join(room_id, is_auto_join)`.
4. DB: `UPDATE rooms SET is_auto_join = $2 WHERE room_id = $1` (parametrised).

**New-user auto-join flow (at first login):**

> **Bugfix note (bugfix-autojoin-first-login-race, 2026-07-01):** the flow below
> previously described a `ValidateToken gRPC` hop that no longer exists post
> gRPC-removal (ADR-021), and — more importantly — described behavior that was
> **only ever reachable from `EventDispatcher.Server.validate_token/2`, which had
> zero production callers**. The real, publicly-reachable `POST
> /_matrix/client/v3/login` path (`Nebu.Matrix.HttpPublic.do_login/1` →
> `provision_and_respond/6`) called `TokenValidator.validate/4` directly and
> never triggered auto-join at all. This is why the auto-join unit test suite
> was green while the feature was completely broken for real clients. The fix
> extracts the shared logic into `run_post_login_provisioning/2` and calls it
> from all three real/test entry points. The flow below reflects the
> post-fix, corrected state.

1. Real Matrix client login (`POST /_matrix/client/v3/login`) is handled by
   `Nebu.Matrix.HttpPublic.do_login/1` → `provision_and_respond/6`, which calls
   `Nebu.Matrix.Session.TokenValidator.Postgres.validate/4` in-process (no gRPC —
   single OTP app, ADR-019/021).
2. `TokenValidator.Postgres.validate/4`:
   - `lookup_user/1` returns `nil` (user not in DB) → `provision_new_user/4` → returns `is_new: true`.
   - Existing user → `decrypt_and_return/1` → returns `is_new: false`.
3. `provision_and_respond/6` calls `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning(user_id, is_new)`.
   `run_post_login_provisioning/2` is the single shared entry point, also called from
   `validate_token/2` (test/legacy in-process path) and `bulk_import_users/2` (Scenario 3q).
   It launches a `Task.start` fire-and-forget:
   - Always: `ensure_personal_room/1` (Story personal-self-room).
   - Only when `is_new = true`: `ensure_auto_join_memberships/1` + `ensure_auto_join_space_memberships/1`.
   - `Task.start/1` (unlike `Task.start_link/1`) has typespec `dynamic({:ok, pid()})` —
     it cannot return `{:error, reason}`, so there is no failure branch to observe here
     (confirmed by Elixir 1.20's type checker; a prior `{:error, reason} ->
     Logger.warning(...)` clause was flagged as dead code and removed —
     bugfix-remove-unused-confirm-default, 2026-07-03). Spawn-level resource exhaustion
     is still possible in principle but is not surfaced as a return value to branch on;
     it would need a system-level probe, not a `case` clause here.
4. `ensure_auto_join_memberships/1`:
   - `messages_db_module().list_auto_join_rooms()` → `SELECT room_id FROM rooms WHERE is_auto_join = true AND status = 'active'`.
   - For each room_id: `Nebu.Room.RoomSupervisor.start_room(room_id)` (idempotent) + `Nebu.Room.Server.join(room_id, user_id)`.
   - `{:error, :already_member}` (or `:noproc` in test env) → silently `:ok` (idempotent, non-fatal).
   - Any other genuine join failure is now logged at `Logger.error` (was `Logger.warning`) so a real
     provisioning failure is observable in production; `list_auto_join_rooms` DB-listing failures
     remain `Logger.warning`. Login always succeeds regardless.

```
Client          Nebu app (HttpPublic)   EventDispatcher.Server         PostgreSQL
  │  POST /login   │                          │                            │
  │───────────────▶│  TokenValidator.validate │                            │
  │                │─────────────────────────▶│                            │
  │                │                          │  lookup_user(@new:...)     │
  │                │                          │───────────────────────────▶│
  │                │                          │  nil (not found)           │
  │                │                          │◀───────────────────────────│
  │                │                          │  provision_user (encrypt)  │
  │                │                          │  is_new: true              │
  │                │  run_post_login_provisioning(user_id, is_new)         │
  │                │─────────────────────────▶│                            │
  │                │                          │  Task.start:               │
  │                │                          │   ensure_personal_room     │
  │                │                          │   ensure_auto_join_memberships
  │                │                          │    list_auto_join_rooms    │
  │                │                          │───────────────────────────▶│
  │                │                          │  [room_id1, room_id2]      │
  │                │                          │◀───────────────────────────│
  │                │                          │  Room.Server.join (each)   │
  │  200 {access_token} │                     │                            │
  │◀───────────────│                          │                            │
```

**Security notes:**
- `is_auto_join` is admin-only (Admin UI behind `SessionGuardWithRefresh` + CSRF token).
- `list_auto_join_rooms` results are never returned to Matrix clients.
- `ensure_auto_join_memberships` only runs for users with `is_new: true` — set server-side only during DB provisioning.
- Partial index `rooms_auto_join_idx ON rooms (is_auto_join) WHERE is_auto_join = true` keeps the query fast.

**Regression coverage:** `server/test/nebu/matrix/event_dispatcher/auto_join_first_login_regression_test.exs`
exercises the real HTTP `/login` route end-to-end (not just the in-process function), synchronized via
the room's `:pg` broadcast group plus a direct `room_members` row assertion — specifically to prevent a
recurrence of "unit-green, production-dead" auto-join code.

**Bulk import provisioning path:** See Scenario 3q below for the identical fire-and-forget pattern triggered by the `bulk_import_users/2` in-process call.

_Source: Story admin-auto-join-rooms (epic: room-naming-and-default-rooms)._

## Scenario 3q: Auto-Join Rooms — Bulk Import Provisioning Path (Story auto-join-on-user-import)

The same auto-join + personal self-room behavior from Scenario 3p is extended to the
`bulk_import_users/2` in-process call path. When an admin imports users via the SCIM/bulk API,
each newly-provisioned user receives the same room setup as a first-login user — without requiring
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
Admin Client    Nebu app     Domain (bulk_import_users/2)   PostgreSQL
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

**Non-blocking guarantee:** The `bulk_import_users/2` response (`BulkImportUsersResponse`) is
returned before any `Task.start` processes complete. Room setup happens asynchronously — the
import latency is not affected by the number of auto-join rooms or the time taken by
`Nebu.Matrix.Room.Server.join/2`.

**Idempotency:** `ensure_auto_join_memberships/1` returns `:ok` on `{:error, :already_member}` —
safe to call even if a previous import partially completed.

**Error isolation:** Each per-user `Task.start` is independent. A crash in one user's room setup
does not affect other users. All errors are non-fatal warning logs only.

_Source: Story auto-join-on-user-import (epic: room-naming-and-default-rooms)._

## Scenario 3r: createRoom — Creator Provisioning & Orphan Cleanup (Story admin-room-creator-provisioning)

A room's creator must become its first member (`m.room.member` join), and `room_members.user_id`
has FK `room_members_user_id_fkey → users(user_id)`. The Admin-UI OIDC login path does **not**
provision a `users` row (unlike the Matrix `OidcPlug.provision/2` path), so an admin creating a room
via the Admin UI used a `creator_id` absent from `users`. The creator-join then violated the FK and
aborted creation **after** `m.room.create` but **before** membership and `m.room.name` — leaving an
orphan room rendered in the Admin UI as the raw `!id:localhost` + "Stale" (0 members).

**Hardened `create_room/2` flow** (`Nebu.Matrix.EventDispatcher.Server`, both the Admin UI
`Nebu.Matrix.create_room/2` path and the Matrix `POST /createRoom` path converge here):

1. `generate_room_id/0` → `room_supervisor_module().start_new_room(room_id)`. `start_new_room/1`
   surfaces an already-running room as `{:error, :already_started, pid}` (instead of the old
   `{:ok, pid}` collapse) → `create_room` raises `Nebu.Matrix.Error` `already_exists` and runs **no**
   cleanup, so orphan cleanup can never target a pre-existing room (defense-in-depth, SEC LOW-1).
2. Persist `m.room.create`.
3. **Provision the creator:** `user_store_module().upsert_user(creator_id, "user")` —
   `INSERT … ON CONFLICT (user_id) DO UPDATE SET last_seen_at = …`. Idempotent, cluster-safe; role is
   always `"user"` (never `instance_admin`) and an existing user's `system_role`/`is_active` are
   untouched on conflict (no privilege escalation, no re-activation of a deactivated user).
4. Creator-join → power levels → `m.room.name` + `update_room_name`.
   - **Canonical alias (Story room-canonical-alias-from-name):** still inside the `if name`
     block, after `m.room.name`, the name is sanitised to a Matrix alias localpart
     (`[a-z0-9._=\-+]`, runs→`-`, dot/dash-trimmed; needs ≥1 alphanumeric else no alias),
     bounded so `#localpart:<server>` ≤ 255 bytes, and registered in the `room_aliases`
     table (migration 000008: `alias PK, room_id → rooms, created_at`). The PK is the sole
     uniqueness authority — a plain INSERT whose `unique_violation → {:error, :conflict}`
     drives a deterministic collision suffix (`-2`, `-3`, … up to 20), race-safe (ADR-020,
     no read-then-write). On success an `m.room.canonical_alias` state event (already in
     `@writable_state_types`, read by `build_room_summary/3`) is emitted so the alias surfaces
     in sync + space hierarchy with no proto change. The whole alias step is **non-fatal** and
     skipped for nameless rooms. `delete_room/1` also deletes `room_aliases` rows (FK child
     before parent) so orphan cleanup of a failed create cannot FK-fail.
5. The whole post-`start_new_room` body runs in `try/rescue`. Any raise (including `Postgrex.Error`,
   which the previous `rescue e in Nebu.Matrix.Error` did not catch) triggers `cleanup_orphan_room/1`:
   stop the Room GenServer with `:normal` (relies on Horde `restart: :transient` so it is not
   restarted and cannot re-insert the row) then `delete_room/1` (transactional DELETE
   `events` → `room_members` → `rooms`, `room_id` param-bound), and the clean error is re-surfaced.

**Accepted limitation:** cleanup is best-effort — a correlated DB outage that fails both the create
and `delete_room/1` may leave the row; a fully transactional create is out of scope because the
`rooms` row is inserted in the Room GenServer `init/1` (Horde), not in the event-write transaction.

_Source: Stories admin-room-creator-provisioning + room-canonical-alias-from-name (epic: room-naming-and-default-rooms)._

## Scenario 3s: Admin UI — Add-User Autocomplete (Story admin-add-user-autocomplete)

The "Add user" inputs on the room detail and Spaces detail pages suggest existing users as the
admin types, instead of requiring a full Matrix id from memory.

1. The admin types into the add-user field (autocomplete input on the Rooms/Spaces HTTP controller pages).
2. The controller calls the shared `Nebu.Admin.UserSuggest.search/1` (min 2 chars enforced
   **server-side**, `LIMIT 10`, `:admin_user_searcher` seam → `Nebu.Admin.DB.search_users/2`).
3. `search_users/2`: `SELECT user_id FROM users WHERE is_active = true AND user_id ILIKE $1 ESCAPE '\\'
   ORDER BY user_id LIMIT $2`. The term is parameter-bound; `escape_like/1` escapes `\`, `%`, `_`
   so wildcard chars match literally (no enumeration broadening). Only `user_id` is selected — no PII
   decryption.
4. Results render as an ARIA combobox (`role=combobox` input + `role=listbox`/`option` list,
   `aria-expanded`/`aria-controls`/`aria-activedescendant`); the `UserCombobox` JS hook handles
   Up/Down/Enter/Esc with no focus trap and degrades to free-text + `phx-click` selection without JS.
   Selecting a suggestion fills the field; the existing `add_member` submit path is unchanged and
   stays free-text (autocomplete is assistive).
5. Both pages share one helper + event contract + JS hook. The Spaces detail page also gained an
   "Add member" form (a Space is a room) routing through `Nebu.Matrix.admin_add_room_member/3`
   (ADR-020, audited, local-domain default-deny) with a member roster + success flash.
   `list_users/3` now honours its search term across keyset pagination (filtered page 2+).

**Security:** admin-only via `require_admin` plug in the `:admin` HTTP pipeline; `actor_id` is
server-derived, never a client param; user_id is HEEx-escaped (no XSS). Kassandra SEC Gate 1: PASS, no findings.

_Source: Story admin-add-user-autocomplete (epic: room-naming-and-default-rooms)._

## Scenario 4: OAuth 2.0 Dynamic Client Registration (RFC 7591) - Broker Model

Third-party OAuth 2.0 clients (Matrix SDK apps, desktop clients) discover Nebu as an authorization
server via `GET /_matrix/client/v1/auth_metadata` (RFC 8414 document) and register themselves with
`POST /oauth2/register` (RFC 7591 Dynamic Client Registration). Every registration starts with status
`pending` and is usable only after admin approval (no auto-approve). Nebu acts as a broker: it
authenticates users via the corporate OIDC provider but issues its own Matrix access/refresh tokens
to clients (ADR-033, broker model O2).

```
Third-party Client      Nebu app (OAuth)                PostgreSQL
       │                       │                              │
       │ GET /auth_metadata    │                              │
       │──────────────────────►│  RFC 8414 document:          │
       │                       │  issuer, authorization_      │
       │  200 {issuer, ...}    │  endpoint, token_endpoint,   │
       │◄──────────────────────│  registration_endpoint, …    │
       │                       │                              │
       │ POST /oauth2/register │  Validate request (RFC 7591) │
       │ {client_name, ...}    │  Compute metadata_hash       │
       │──────────────────────►│──────────────────────────────►│
       │                       │  INSERT oauth_clients        │
       │                       │  status = 'pending'          │
       │                       │  (ON CONFLICT DO NOTHING)    │
       │  201 {client_id}      │◄──────────────────────────────│
       │◄──────────────────────│                              │
       │                       │                              │
       │  (client waits or…)   │  [Admin approves via UI]     │
       │  (tries auth, gets…)  │  UPDATE oauth_clients        │
       │  (pending error)      │  status = 'approved'         │
       │                       │──────────────────────────────►│
       │                       │                              │
       │ (continues in "Authorization code flow" below)       │
```

### Authorization code flow: authorize -> IdP -> shared callback -> Nebu code (story oauth-authorize-idp-delegation-code)

```
Client (browser)        Nebu app (OAuth)                    PostgreSQL            Corporate IdP
     │ GET /oauth2/authorize?client_id&redirect_uri&scope&code_challenge(S256)&state     │
     │───────────────────────►│ rate limit; validate (HTML page on any error before     │
     │                        │ client + redirect URI are trusted); client approved?    │
     │                        │ INSERT oauth_authz_requests (state_hash = sha256(o2.…), │
     │                        │  SecretBox(IdP PKCE verifier), idp_nonce, request,      │
     │                        │  sha256(binding cookie), TTL 10 min)  ──────────────────►│
     │ 302 Location: IdP (prompt=login, max_age=0, PKCE+nonce, state=o2.<32 bytes>)      │
     │ Set-Cookie: nebu_oa_<16 hex>=<32 random bytes>; HttpOnly; SameSite=Lax; 600 s    │
     │◄───────────────────────│                                                         │
     │ interactive login at the IdP ────────────────────────────────────────────────────►│
     │ GET /_matrix/client/v3/login/sso/redirect/oidc?code&state=o2.…  (SHARED callback) │
     │───────────────────────►│ SsoLogin.callback/1: `o2.` tag => OAuth branch FIRST     │
     │                        │ DELETE oauth_authz_requests ... RETURNING (atomic, once) │
     │                        │ binding cookie check (constant time), clear the cookie   │
     │                        │ IdP code exchange + id_token + nonce check ─────────────►│
     │                        │ provision user (same as legacy login; deactivated =>     │
     │                        │ access_denied); SecretBox(IdP refresh token)             │
     │                        │ INSERT oauth_codes (code_hash only, TTL 60 s) ──────────►│
     │ 302 redirect_uri?code=…&state=…&iss=<issuer>   (query or fragment, D10)           │
     │◄───────────────────────│                                                         │
     │ POST /oauth2/token (story oauth-token-endpoint, see the next flow)               │
```

**Key design aspects (story oauth-authorize-idp-delegation-code, ADR-033 D1-D23):**

- **Shared callback (D1):** there is no `/oauth2/callback`; the IdP's one already registered redirect URI
  `/_matrix/client/v3/login/sso/redirect/oidc` serves both flows. `o2.`-prefixed states (D2) always go to
  the OAuth branch, legacy states (32 hex) are untouched.
- **Cluster-safe flow state (D3):** the IdP verifier/nonce/request live in `oauth_authz_requests`, not in the
  node-local `SsoStore`; any node can complete a flow, restarts lose nothing.
- **Browser binding (D4, RFC 9700 4.7):** the callback requires the per-flow cookie set by the authorize 302
  (login-CSRF defence). Accepted property: the request is consumed before the cookie check, so a third party
  holding a live `state` can burn (not complete) one login attempt.
- **Errors:** before client and redirect URI are trusted (unknown/pending/rejected client, bad redirect URI,
  unknown/expired/replayed IdP state) => accessible HTML page, never a redirect; afterwards RFC 6749 4.1.2.1
  error redirects with `state` + `iss` (RFC 9207), never `errcode`. `prompt=none` => `login_required` without
  contacting the IdP.
- **Codes (D16/D17):** 256-bit random, only the SHA-256 hash stored, TTL 60 s, single use via atomic
  `UPDATE ... WHERE used_at IS NULL ... RETURNING`; reuse is detected (`{:reused, row}`); the token endpoint (story 3) revokes the
  derived session. Used/expired rows are purged 24 h after expiry by `OAuthFlowPurgeWorker` (every 10 min).
- **No consent screen (D5):** admin approval of the client is the consent gate; the IdP always asks for an
  interactive login (`prompt=login` plus `max_age=0`).
- **Revocation:** `/oauth2/revoke` answered 404 until story 4 (resolved) and is live since story oauth-token-revocation-logout (see the
  last flow of this scenario). (`/oauth2/token` exists since story oauth-token-endpoint; it issues the Nebu-signed id_token when `openid` was
  requested, D23, see the next flow.)

### Token endpoint: code grant, refresh rotation, id_token (story oauth-token-endpoint)

```
Client                 Nebu app (OAuth + Matrix domain)                PostgreSQL            Corporate IdP
  │ POST /oauth2/token  grant_type=authorization_code&code&code_verifier&redirect_uri&client_id (form, 16 KiB cap)
  │───────────────────►│ bucket {"oauth_token", ip}; parse (TokenRequest); client auth `none`; grant allowed
  │                    │ CodeStore.consume: UPDATE oauth_codes SET used_at ... WHERE used_at IS NULL ... RETURNING
  │                    │   (already used => {:reused, row}: revoke the derived session ONLY if client, redirect URI
  │                    │    and PKCE verifier are valid (T8), ALWAYS answer invalid_grant)
  │                    │ client / byte-equal redirect URI / PKCE S256 checks; error-aware users.is_active (T19)
  │                    │ per_refresh and no IdP refresh token in the code => invalid_grant + WARNING (T6)
  │                    │ Nebu.oauth_issue_session/1: ONE transaction ─────────────────►│ upsert devices row (lock),
  │                    │   DELETE all earlier matrix_sessions rows of the device (T7)   │ DELETE old rows, INSERT
  │                    │   INSERT row auth_api='oauth', hashed tokens, session_expires_at│ (hashes only)
  │                    │ after commit: denylist raw IdP JWTs bound to the device (T7)
  │                    │ openid granted => id_token (ES256, key from oauth_signing_keys, lazily generated)
  │ 200 {access_token, token_type: Bearer, expires_in, refresh_token, scope, id_token?}  (no-store)
  │◄───────────────────│
  │ POST /oauth2/token  grant_type=refresh_token&refresh_token&client_id[&scope]
  │───────────────────►│ bucket {"oauth_token_refresh", ip}: exhausted => 503 `{}` + Retry-After (NEVER 429)
  │                    │ resolve token hash: unknown/expired/legacy => invalid_grant (no side effects)
  │                    │   CONSUMED token of a live session => revoke every OAuth row of the device, invalid_grant (T11)
  │                    │   other client's client_id => invalid_grant, no revocation (T12)
  │                    │ scope: absent/empty = granted; subset allowed only by dropping `openid` (T13)
  │                    │ idp_revalidation=per_refresh: redeem the stored IdP refresh token ───────────────────────►│
  │                    │   (off: only users.is_active). Confirmed rejection => revoke + invalid_grant;
  │                    │   transient error => 503 `{}`; T28 guard: a rejection is skipped only if the device row
  │                    │   already carries a NEW IdP refresh-token ciphertext (concurrent refresh won)
  │                    │ rotate (devices row lock, SELECT ... FOR UPDATE, guarded UPDATE): new access + refresh token,
  │                    │   session_expires_at copied verbatim (never extended); old refresh token stays PENDING
  │                    │   (lost-response retry) until the new access token is used or the new refresh token is redeemed
  │ 200 {access_token, refresh_token, expires_in, scope, id_token? (while openid is granted)}
  │◄───────────────────│
  │ GET /_matrix/client/v3/... Authorization: Bearer <opaque 64 hex>   (resource server)
  │───────────────────►│ OidcPlug opaque path: hash lookup in matrix_sessions; expires_at passed => 401 soft_logout:true,
  │                    │   M_UNKNOWN_TOKEN (client refreshes); a raw IdP JWT bound to an OAuth device => 401 M_UNKNOWN_TOKEN (T25)
```

**Key design aspects (story oauth-token-endpoint, ADR-033 T1-T33):**

- **Code grant.** The story-2 atomic consume marks the code used BEFORE the binding checks, so a wrong verifier, redirect
  URI or client burns the code (T9). Reuse of a code revokes exactly the session derived from it (`oauth_code_hash`,
  copied on every rotation), proof-gated (T8, deliberate deviation from the RFC 6749 SHOULD); the reused code is always
  `invalid_grant`.
- **One session model.** OAuth sessions are `matrix_sessions` rows with `auth_api = 'oauth'` (one row per token pair,
  a session = all rows of `(user_id, device_id)`). `expires_at` is the access-token expiry
  (`LEAST(now() + oauth_access_token_ttl_seconds, session_expires_at)`), `session_expires_at` the absolute session
  maximum set at redemption and never extended (T3). Device reuse deletes every earlier row of the device in the
  issuance transaction and keeps the device row and its E2EE keys (T7); a legacy `POST /login` with an OAuth device's
  `device_id` takes the device over (T26).
- **Refresh rotation with reuse detection (T10-T12).** Every refresh rotates both tokens. The previous refresh token
  stays redeemable while PENDING (lost-response retry, legacy 0c semantics, no time window); once CONSUMED, presenting it
  revokes the whole OAuth session (WARNING) and answers `invalid_grant`.
- **IdP re-validation (T5/T6/T28).** `per_refresh` (default) redeems the SecretBox-stored IdP refresh token on every Nebu
  refresh, so a user disabled at the IdP loses the Nebu session at the next refresh; `off` only checks `users.is_active`.
  A missing IdP refresh token fails closed (`invalid_grant`, follow-up (l) for earlier detection at the callback).
  T28 closes the concurrent-refresh race without letting an overlapping refresh bypass re-validation (Kassandra F-1);
  residual: two truly concurrent refreshes against an IdP that rotates its refresh tokens can end in a false logout
  (follow-up n).
- **Errors that must not log clients out (T20/T22).** 4xx are RFC 6749 5.2 bodies and only for DEFINITIVE outcomes; every
  5xx (transient DB/IdP trouble, rescued exceptions, an exhausted refresh bucket) is `{}` without an `error` member plus
  `Retry-After`, because oidc-client-ts turns any JSON with `error` into an `ErrorResponse` and matrix-js-sdk then logs out.
  The same reasoning shapes the kill-switch 404 (`{"errcode":"M_UNRECOGNIZED"}`, no `error`).
- **id_token (T15-T17).** Issued when `openid` is granted (also on refresh while it is still granted); claims exactly
  `iss`, `sub`, `aud`, `iat`, `exp = iat + 300`, `auth_time`, `nonce` (code grant only). Signed ES256 with a Nebu-generated
  key; the `kid` is the RFC 7638 thumbprint; `GET /oauth2/jwks` publishes the active and unexpired retired keys.
- **Resource server (T3/T25).** The access token is an opaque 64-hex string resolved by hash; an expired access token
  (or a superseded one after rotation) answers `401 M_UNKNOWN_TOKEN` with `soft_logout: true` so the client refreshes
  instead of dropping the session; an unknown token answers `401` without `soft_logout`; a refresh is only possible while
  `session_expires_at > now()`, afterwards it answers `invalid_grant`. No raw IdP JWT is accepted for an OAuth
  device (issuance denylists existing bindings, `DeviceBinding.put/4` refuses new ones, `OidcPlug` rejects them).
- **Open:** `oauth_enabled` stays false: the reverse-proxy templates do not route `/oauth2/` and
  `/.well-known/openid-configuration` yet (follow-up m), and the trusted-proxy gate (item 1) covers the new buckets.
  (`/oauth2/revoke` exists since story 4, see the next flow.)

### Token revocation and logout (story oauth-token-revocation-logout)

```
Client                 Nebu app (OAuth + Matrix domain)                          PostgreSQL
  │ POST /oauth2/revoke  token=<access OR refresh token>[&token_type_hint][&client_id]   (form, 16 KiB cap, no client auth)
  │───────────────────►│ config :unknown => 503 `{}` + Retry-After (disabled / bad issuer: STILL served, R13)
  │                    │ FormPost.parse (query string / duplicate / control char => 400 invalid_request, 413, 405 incl. HEAD)
  │                    │ bucket {"oauth_revoke", ip} 60/min burst 600 (429), charged BEFORE any DB access
  │                    │ token not 64 lowercase hex => 200 `{}` with NO DB access (R5)
  │                    │ Nebu.oauth_revoke_token/1: ONE transaction ───────────────►│ SELECT row by access_hash OR refresh_hash
  │                    │                                                            │   (any state, auth_api='oauth', hint ignored)
  │                    │                                                            │ SELECT ... FROM devices WHERE (user,device) FOR UPDATE
  │                    │                                                            │ re-check the row after the lock (T7 re-login?)
  │                    │                                                            │ DELETE every matrix_sessions row of the device
  │                    │                                                            │ DELETE devices row + device_keys, one-time, fallback keys
  │                    │ after commit, best effort: S3 JWT kill-switch (bindings deleted only after every denylist
  │                    │   write was confirmed) + per-device legacy session rows
  │◄───────────────────│ 200 `{}` (application/json) for revoked, unknown, malformed AND legacy tokens (byte-identical, R10)

Matrix client (OAuth access token)
  │ POST /_matrix/client/v3/logout            OidcPlug assigns :auth_api = "oauth" => ends ONLY this device (same function, R15);
  │                                           storage failure => 500 M_UNKNOWN; a legacy token/JWT keeps the legacy wipe (R16)
  │ POST /_matrix/client/v3/logout/all        (routed since story 4, both APIs; needs no UIA, R17)
  │                    │ 1. oauth_end_user_sessions/1: every OAuth session with its device and keys
  │                    │ 2. legacy part (sessions, opaque rows, caller's raw JWT denylisted durably via revoke_checked/3)
  │                    │ 3. end_all_user_devices/1: union of devices rows + matrix_sessions device ids, each torn down
  │                    │    under the devices-row lock (devices -> matrix_sessions), cross-signing keys stay
  │◄───────────────────│ 200 `{}` only when EVERY part succeeded; a failed part => 500 M_UNKNOWN, the other parts still ran

GDPR key erasure (delete_user_keys/2): ONE transaction (story gdpr-erasure-global-data), in this order: `deletion_in_progress`, the private keys set to NULL, the row locks
(`uia_sessions`, `cross_signing_keys`) and THEN the per-user `sync_global` advisory lock (the order of the cross-signing reset writer, so no lock cycle), `DELETE` of the user's rows in
`account_data`, `cross_signing_keys`, `device_keys` / `device_one_time_keys` / `device_fallback_keys`, `user_room_account_data` and the other per-user tables
(`UserDeletion.erased_tables/0`; fails closed when an `oauth_codes` row is left), the profile anonymised (`Deleted User`), `keys_deleted` + `is_active = false` + the `users` PII
columns NULL (the erasure is terminal for authentication); a failing step rolls everything back and is named in the attempted audit. After the commit (success branch only)
OAuth sessions, legacy opaque sessions, legacy devices and legacy `sessions` / `sync_tokens` of the user are ended best effort; the response is unchanged.
```

**Key design aspects (story oauth-token-revocation-logout, ADR-033 R1-R24):**

- **One revocation function (R1/R2/R11).** Revoke, OAuth `/logout`, `/logout/all` and erasure all end an OAuth session through
  the same locked, atomic teardown (session rows + device + keys in one transaction); idempotent, so the parallel access-token
  and refresh-token revocations Element sends for one logout both answer `200 {}`. Code-reuse and refresh-reuse revocations
  (T8/T11) still delete only the OAuth rows and keep the device.
- **After revocation (R20):** the access token answers `401 M_UNKNOWN_TOKEN` without `soft_logout`, the refresh token `invalid_grant`.
- **No client authentication, no oracle (R4/R5/R10).** Any holder of any old token of a session, also a consumed or superseded
  one, can end it (RFC 7009 grant revocation); a missing or wrong `client_id` still revokes (Matrix spec precedence); a legacy
  token cannot be killed through this endpoint.
- **`{}` contract (R6/R7):** every 5xx is `{}` + `Retry-After` (T20), 4xx uses the RFC 6749 shape; `401 invalid_client` and
  `unsupported_token_type` are unreachable by design.
- **IdP refresh token (R12):** deleted with the rows; Nebu makes no outbound IdP call from the unauthenticated endpoint (follow-up t).
- **Legacy `POST /logout` (R16)** is byte-identical and remains a recorded spec deviation: it wipes every session of the user,
  also OAuth sessions on other devices (gate item r, to be closed by the bugfix `legacy-logout-per-device` before `oauth_enabled`; the story-9 `/versions` flip code is dormant).
- **Open:** `device_lists.changed` on deletion (follow-up s) is later work; the `DELETE /devices/{id}` refusal for OAuth sessions landed in story oauth-legacy-coexistence (next section).

### Legacy coexistence: login flags, SSO `action`, device deletion (story oauth-legacy-coexistence)

```
Matrix client                    Nebu app (Nebu.Matrix HTTP layer)                           PostgreSQL
  │ GET /login                   │ Nebu.OAuth.oauth_aware?/0 (Config.live_state/0 == {:live, _}, per request, never raises)
  │─────────────────────────────►│ offered => `m.login.sso` flow carries oauth_aware_preferred + org.matrix.msc3824.
  │                              │            delegated_oidc_compatibility (JSON true); `m.login.token` never does
  │◄─────────────────────────────│ not offered / unknown / exception => the pre-broker map, byte-identical, still 200
  │ GET /login/sso/redirect[/oidc]?redirectUrl=..&action=register
  │─────────────────────────────►│ bad redirectUrl 400 first; discovery failure 503; `action` (stable, else unstable, exact
  │                              │ login|register, repeated key => last) honoured only while oauth_aware?/0 and only for no
  │                              │ {idpId} or `oidc`; register => `prompt=create` iff IdP prompt_values_supported lists it
  │◄─────────────────────────────│ 302 to the IdP (otherwise `prompt=login`); the raw value is never forwarded or logged

Matrix client                    DELETE /devices/{id} | POST /delete_devices
  │ OAuth session (`:auth_api`="oauth")  => FIRST step: 403 M_FORBIDDEN (before IDOR guard, body validation, UIA gate; no uia_sessions row)
  │ legacy session (IdP JWT / opaque)    => UIA gate as before, then per device Nebu.Matrix.end_device_session/2 ──────►│ devices row FOR UPDATE,
  │                                         matrix_sessions rows + device tables, ONE transaction; then DeviceBinding.kill_device_jwts/3
  │                                         (denylist write confirmed => binding deleted; failed write => binding kept, fail closed)
  │◄─ 200 {} | 500 M_UNKNOWN "Device deletion failed, please try again." (/delete_devices still attempts every id)
  │ preserved own device of a fresh-UIA self-delete: unchanged steps (kill-switch with `except_hash:`); an opaque caller continues,
  │ a raw-JWT caller's binding is kept and refused by lookup/1 after the 60 s cache TTL (401 M_UNKNOWN_TOKEN, no soft_logout)
Admin UI  POST /admin/users/:id/devices/:device_id (DELETE) => Nebu.Matrix.delete_user_device/2 (the same atomic teardown); failure => flash :error + audit `failure`
```

**Key design aspects (story oauth-legacy-coexistence, ADR-033 C1-C20):**

- **Flags fail closed (C2/C3).** Present only while OAuth is offered; `GET /login` stays 200 in every state (legacy clients need it).
  `m.login.sso` is always offered. A runtime toggle flips the flags and `auth_metadata` together on the next request (no cache).
- **`action` is a Nebu-gated extension (C4-C6).** Unknown values are ignored (never 4xx); `register` => `prompt=create` is a Nebu
  extension; an arbitrary `{idpId}` and the UIA fallback / OAuth leg are untouched.
- **Raw-JWT hardening (C11/C13).** `POST /keys/upload` runs the lazy bind first and answers `403 M_FORBIDDEN` (no key write) when the
  binding is refused; legacy raw-JWT `POST /login` answers `403 M_FORBIDDEN` for a denylisted JWT and
  `500 M_UNKNOWN "Login failed, please try again."` when `DeviceBinding.put/4` refuses (`{:error, :oauth_device}`, also a re-point
  attempt) or `register_device/4` fails; the opaque branch ignores the latter. A bound JWT can never turn into a working unbound one.
- **UIA freshness is legacy-only (C9):** `refresh_auth_time/2` touches only `auth_api = 'legacy'` rows.
- **Legacy `POST /logout` (user-wide wipe, gate r) and legacy-to-legacy device reuse (follow-up f) are NOT changed**; gate item r
  must be closed by the bugfix run `legacy-logout-per-device` before `oauth_enabled` (the story-9 `/versions` flip code exists and is dormant).

### Account management page and `m.oauth` cross-signing reset (story oauth-account-management)

Account sign-in (browser) through the SHARED IdP callback; the IdP client, the registered redirect URI and the scope are the ones of the
authorize flow, only the state tag differs (`o2.acct.`):

```
Browser                  Nebu app (Nebu.OAuth.Account)                       PostgreSQL            Corporate IdP
  │ GET /account[?action=..&device_id=..]  (no valid account session)
  │─────────────────────►│ live check (Config.live_state/0: 404 / 503 page otherwise), bucket {"oauth_account", ip}
  │                      │ INSERT oauth_account_login_requests (state_hash = sha256(o2.acct.<43>), SecretBox PKCE verifier, nonce,
  │                      │   binding hash, validated return_action / return_device_id, expires_at = now()+600 s; soft cap 10 000) ──►│
  │◄─────────────────────│ 302 to the IdP (prompt=login + max_age=0, S256) + Set-Cookie nebu_acct_<16 hex> (HttpOnly; Lax; Path=callback)
  │ ... user signs in at the IdP ...                                                                         │
  │ GET /_matrix/client/v3/login/sso/redirect/oidc?code&state=o2.acct.…  (the shared callback; SsoLogin.callback/1 `o2.` => OAuth branch)
  │─────────────────────►│ Nebu.OAuth.handle_idp_callback/1: `o2.acct.` => Account.handle_idp_callback/1 (everything else => Authorize)
  │                      │ bucket => live check (nothing consumed) => state format => atomic DELETE ... RETURNING => binding cookie
  │                      │ => IdP `error` page => Nebu.Matrix.idp_complete_login/4 => account_identity/1 (existing, active user, else
  │                      │ no_account / deactivated / 503) => `auth_time` claim >= created_at - 60 s (absent: accepted + WARNING, gate y)
  │                      │ => rotation transaction: INSERT oauth_account_sessions (hash of a 256-bit cookie value), DELETE the replaced
  │                      │    session, per-user cap 20 ──────────────────────────────────────────────────►│
  │◄─────────────────────│ 303 to the SERVER-built `/account?action=..` + Set-Cookie `__Host-nebu_account` (Secure; HttpOnly; Lax; Path=/)
  │                      │   (plain http: `nebu_account`, Path=/account); the IdP refresh token is discarded; binding cookie cleared
  │ GET /account?...     │ ONE atomic sliding UPDATE ... RETURNING (idle 900 s, absolute 3600 s) + error-aware is_active read => page
```

Device sign-out (`org.matrix.device_delete`, Element deep-links `device_view` / `device_delete` with a `device_id`):

```
Browser                  Nebu.OAuth.Account                          Nebu.Matrix (facade)                    PostgreSQL
  │ GET /account?action=org.matrix.device_delete&device_id=X  => confirmation page ("Sign out <name>?"; GET never mutates)
  │   stale session (now - auth_time >= 300 s) => the page shows a "Confirm it's you" LINK to GET /account/reauth?action&device_id
  │   => a new IdP login (max_age=0, same return target) => back on the SAME confirmation page, now fresh
  │ POST /account/devices/delete  device_id, csrf_token (form, 16 KiB, no query string)
  │─────────────────────►│ bucket; session; CSRF (token hash, Origin == issuer origin, Sec-Fetch-Site != cross-site, navigation
  │                      │ metadata when present) BEFORE freshness; freshness re-checked (stale => 303 notice=stale, nothing changed)
  │                      │ ownership = membership in account_devices/1 (foreign / unknown => 303 notice=device_not_found)
  │                      │ end_device_session(user, device) ──────────────►│ devices row FOR UPDATE; every matrix_sessions row of ANY
  │                      │                                                 │ auth_api; device + key tables; ONE transaction ───────►│
  │                      │                                                 │ post-commit: JWT kill switch, SessionSupervisor teardown
  │◄─────────────────────│ 303 /account?action=..&notice=device_deleted   (failure => 500 page server_error, nothing changed)
  │ afterwards: the device's access token => 401 M_UNKNOWN_TOKEN (no soft_logout), its refresh token => invalid_grant (story 4 R20)
```

Cross-signing reset (`m.oauth` UIA stage, `POST /_matrix/client/v3/keys/device_signing/upload`, OAuth callers only):

```
Matrix client (OAuth token)   Nebu app (protected.ex)                  PostgreSQL (uia_sessions)        Browser (account page)
  │ POST keys/device_signing/upload  {master_key, self_signing_key, user_signing_key}  (stored master exists, keys differ)
  │─────────────────────►│ OAuth caller (`:auth_api`) AND Nebu.OAuth.cross_signing_reset_url/0 == {:ok, url} (else the legacy 403)
  │                      │ no `auth.session` => reuse the caller's PENDING `cross_signing_reset` session for the same
  │                      │ (user, params = {device_id, sha256(canonical JSON of ALL supplied keys)}), else mint (checked insert; advisory
  │                      │ lock per (user, device); one pending per device, cap 5 per user) ───────────────►│
  │◄─────────────────────│ 401 {"flows":[{"stages":["m.oauth"]}],"params":{"m.oauth":{"url":"<issuer>/account?action=org.matrix.cross_signing_reset"}},"session":"<id>"}
  │ (Element opens the url)                                                                                    │ GET /account?action=org.matrix.cross_signing_reset
  │                                                                                                            │   sign-in / re-auth as above; the page lists the user's
  │                                                                                                            │   PENDING requests: requesting device, app, time, reference
  │                                                                                                            │ POST /account/cross_signing_reset/approve  session_id, csrf_token
  │                      │◄── Nebu.Matrix.approve_cross_signing_reset/2: UPDATE uia_sessions SET stage_complete = TRUE,
  │                      │    expires_at = LEAST(expires_at, now()+600) WHERE session_id AND user_id AND op = 'cross_signing_reset'
  │                      │    AND stage_complete = FALSE AND consumed = FALSE AND expires_at > now()  (atomic; fresh session required)
  │                      │                                                                                     │ 303 notice=reset_approved
  │ user clicks Retry in the client (no polling): POST keys/device_signing/upload {same keys, auth:{type:"m.oauth", session:"<id>"}}
  │─────────────────────►│ ONE transaction: Uia.consume(session, user, "cross_signing_reset", params) (single use, approved, unexpired,
  │                      │ same user, same device + key set) AND the key write (stored keys merged with the supplied ones; sets
  │                      │ cross_signing_changed and, under the per-user sync_global| advisory lock, a new changed_pos, so every
  │                      │ device of the user lists the OWN user in device_lists.changed once; story sync-token-per-device) ─►│
  │◄─────────────────────│ 200 {}   (failed write rolls the consume back => 500 M_UNKNOWN; consume :error => a NEW 401 challenge)
```

**Key design aspects (story oauth-account-management, ADR-033 A1-A27):**

- **Session lifecycle (A8).** Login or re-auth always creates a NEW session and deletes the replaced one in the same transaction
  (session-fixation defence); lookup slides the idle timeout (900 s, never beyond the 3600 s absolute lifetime) in one atomic UPDATE, so any
  node answers; a deactivated user's next request deletes the session; `POST /account/logout` (CSRF) deletes it and renders the
  `signed_out` page directly (the one POST that is not Post/Redirect/Get). Expired login requests and sessions are purged by the
  `OAuthFlowPurgeWorker` (every 10 min); correctness never depends on it. The browser session is NOT a Matrix device and never
  authenticates `/_matrix/*`.
- **Liveness and kill switch (A3).** The page and the account branch of the IdP callback are live exactly while `auth_metadata` answers 200
  (`Config.live_state/0 == {:live, issuer}`): `404` page when OAuth is off / the issuer invalid, `503` page when the config is unreadable.
- **Re-authentication (A10, A17).** Device deletion and reset approve / decline need `now - auth_time < 300 s` on the ACCOUNT session. An
  account re-auth never writes `matrix_sessions.auth_time` (deliberate deviation from the epic spec section 8, ADR-033 A17): it proves that
  the user is at this browser, not that the Matrix client holding a token is.
- **Approval is bound (A14/A15).** The approval record is the `uia_sessions` row (`op = "cross_signing_reset"`), single use, TTL 900 s from
  the challenge and at most 600 s after the approval; it is bound to the user, the requesting device and the exact key set. A different key
  set never matches (a new challenge), approving request A never authorises request B, and the legacy `m.login.sso` fallback can never
  approve a reset. Request-first: no user-level "allow resets" window.
- **Same-origin residual (gate ag).** `/account` shares the origin with Element Web, so a script injected into Element could drive the page;
  see 11-risks (ag) and the CSRF / fetch-metadata notes in 08-concepts.

**Key design aspects (ADR-033):**

- **Metadata hash deduplication:** Identical metadata across multiple registration requests resolves
  to ONE oauth_clients row (`ON CONFLICT (metadata_hash) DO NOTHING`). Re-registration returns the
  same `client_id`, idempotent.
- **No auto-approve:** Every registration starts `pending`. An admin must explicitly approve each
  client via the Admin UI (`/admin/oauth/registrations`), recording `approved_by` and `approved_at`.
  Rejected clients stay rejected; rejected registrations are never deleted (spec rule: do not delete
  a registration with an active session).
- **Pending TTL + caps:** Pending registrations older than `oauth_pending_ttl_days` (default 30) are
  purged hourly by `Nebu.Workers.OAuthPendingPurgeWorker`. Global cap (default 5000) and per-host cap
  (default 20, keyed on `client_uri` host) prevent registration floods. Exceeding a cap returns `503
  temporarily_unavailable`; dedup hits bypass the cap (idempotency preserved).
- **Rate limiting (three bucket families):** Junk requests (unparsable, oversize, invalid) use a
  separate 600/h per-IP + 5000/h global budget. Valid requests pay a loose 600/h per-IP budget. New
  registrations (unknown metadata hash) additionally pay a strict 50/h per-IP + 500/h global budget.
  Dedup hits (known hash) skip the strict budget (only lookedup index query, O(1)).
- **CORS:** Both metadata and registration endpoints respond to preflight `OPTIONS` with
  `Access-Control-Allow-Origin: *` and permit browser clients (Matrix Dart SDK, Element Web).
- **https-for-all-URLs:** All OAuth endpoints and metadata URLs must be https. Non-https issuer
  configuration makes the metadata endpoint answer `404 M_UNRECOGNIZED` (fail closed) instead of
  advertising insecure URLs.

### Phase 2 runtime views: authorize -> consent -> code, client revocation, per-device legacy logout (ADR-033 "Phase 2 summary")

Delta to the authorization code flow above: the callback no longer mints a code; a consent step sits between the verified IdP login and the code.

```
Browser                 Nebu (Authorize / Consent)                                      PostgreSQL                  IdP
  │ GET /oauth2/authorize ─►│ ClientIP.bucket rate limit, per-source cap, live check, client approved; INSERT oauth_authz_requests ──►│
  │◄───────────────────────│ 302 to the IdP (max_age=0, S256) + binding cookie __Host-nebu_oa_<16 hex> (https)
  │ ... IdP login ...                                                                                                    │
  │ GET callback ──────────►│ consume request, binding, recheck client, IdP login; gate l (refresh token present?), provisioning,
  │                         │ Freshness.evaluate(auth_time) (absent/stale => login_fresh=false, never login_required), device holder
  │                         │ (another app's live device => 403 device_in_use); INSERT oauth_consent_requests (binding_hash, TTL<=5 min) ►│
  │◄───────────────────────│ 303 /oauth2/consent + cookie __Host-nebu_oauth_consent
  │ GET /oauth2/consent ───►│ renders from the live row (no mutation): app, claimed host, redirect target, session line, notice if not fresh
  │ POST /oauth2/consent ──►│ BrowserPost checks (Origin, Sec-Fetch-*, CSRF) BEFORE consumption; ONE DELETE ... RETURNING; Allow:
  │   (Allow armed by JS    │ re-check client approved + device holder; CodeStore.insert (only here) ──────────────────────►│
  │    after real input)    │ Deny: error redirect `access_denied`
  │◄───────────────────────│ 303 to the client's redirect_uri?code&state (https, loopback, private-use scheme)
```

Client revocation (admin UI or `bin/nebu rpc`), one transaction, lock order `oauth_clients -> devices -> matrix_sessions`:

```
Admin (fresh re-auth, typed host) ─► Nebu.OAuth.revoke_client/3 ──► BEGIN
   UPDATE oauth_clients SET status='revoked' WHERE status='approved'   (0 rows => :not_approved)
   for each (user, device) of the client: locked per-device teardown (devices FOR UPDATE, all session rows, device + E2EE key tables)
   oauth_codes.used_at (unused codes); DELETE oauth_authz_requests, oauth_consent_requests of the client
   audit row oauth_client_revoked (a failed audit rolls everything back)                          COMMIT
   post-commit, best effort: JWT denylist + bindings, legacy per-device cleanup
Concurrent issuance / rotation: SELECT status ... FOR SHARE (2 s lock_timeout) first => either the revoke's teardown removes the new
session or the issuance sees `revoked` (invalid_grant / 503 + Retry-After). Old tokens: M_UNKNOWN_TOKEN; token request: invalid_client.
```

Legacy `POST /logout` (per device):

```
Client (legacy token) ─► protected.ex ─► Nebu.Matrix.legacy_logout_device(%{kind: opaque | jwt, token, user_id, device_id})
   devices row FOR UPDATE; re-check that the presented credential still belongs to the device (a newer OAuth take-over is never killed:
   {:ok, :unknown}); delete the device's session rows (any auth_api), device keys, the devices row; COMMIT
   bound raw JWT: CHECKED denylist write on :ended AND :unknown (failure => 500 M_UNKNOWN, never a silent 200)
   other devices, other users' sessions and cross-signing keys are untouched; `/logout/all` keeps the user-wide wipe
```

Legacy SSO login with the confirmation branch (story legacy-sso-redirect-confirmation, epic SEC gate 3 G3-3; independent of `oauth_enabled`):

```
Browser / client          Nebu (SsoLogin, SsoConfirm)                                         IdP
  │ GET /login/sso/redirect[/oidc]?redirectUrl=U ─►│ SsoRedirect.classify(U): {:reject, _} => 400 (unchanged bodies; stricter syntax:
  │                         │ userinfo, backslash, control bytes, numeric host lookalikes, > 2048 bytes); state stores the RAW U
  │◄───────────────────────│ 302 to the IdP (unchanged)   ... IdP login ...                                          │
  │ GET callback ──────────►│ classify(U) again at callback time:
  │                         │   :direct (loopback http, default / operator schemes) or {:confirmable, t} with listed?(t.origin, U)
  │                         │     => unchanged: loginToken (30 s), 302 to U?loginToken=..   (old loginToken params of U removed first)
  │                         │   {:confirmable, t}, NOT listed => NO loginToken: SsoStore.put_confirm (5 min), binding cookie
  │                         │     (__Host-nebu_sso_confirm on https), INFO "redirect confirmation shown host=<host>"
  │◄───────────────────────│ 303 /_matrix/client/v3/login/sso/confirm
  │ GET .../sso/confirm ───►│ peek_confirm (no mutation, reload safe): page names the target origin and the signed-in Matrix user
  │ POST .../sso/confirm ──►│ per-IP bucket, form parse, decision, Origin + Sec-Fetch-*, cookie, CSRF, THEN pop_confirm (single use)
  │   Cancel                │   => 200 "Sign-in cancelled", nothing minted, cookie cleared
  │   Continue (armed by JS)│   => put_login_token (30 s) ; 303 to U?loginToken=.. ; cookie cleared
  │ POST /login {m.login.token} ─► unchanged (SsoStore.pop_login_token, full session)
```

`listed?/2` (exact origin, fail closed, evaluated at callback time so an allowlist change during the 10 min IdP window applies): `https://<server_name>` (never the `Host` header), the operator list `sso_redirect_allowed_origins`, then `Nebu.OAuth.trusted_redirect_url?/2` (issuer origin; a URL equal to or below a registered https redirect URI of an `approved` OAuth client). A pending entry lives 5 minutes (the cookie `Max-Age` equals it); an expired, consumed or unknown entry answers the `400 invalid_state` page. `UIA` fallback (`uia_session` states) and the `o2.` OAuth branch never reach the classification. Failure shapes: confirm store full or not answering => `503` page, nothing minted; token store not answering after Continue => `503` page, the entry stays consumed (a second Continue is `invalid_state`); `Origin` / fetch-metadata / CSRF failure => `403 forbidden`, cookie kept; more than 600 requests per hour per client IP => `429` + `Retry-After`. The confirmation routes send no `access-control-*` headers and no `Cross-Origin-Opener-Policy` (popup-based web clients such as FluffyChat web read the result through `window.opener`; framing stays blocked by `X-Frame-Options` and `frame-ancestors`).

Admin list `sso_redirect_allowed_origins`: `POST /admin/config/sso-origins` -> `Nebu.Matrix.normalize_sso_redirect_origins/1` (error => re-render, nothing persisted) -> `Nebu.Admin.DB.upsert_server_config/1` (cluster-wide cache refresh) -> compliance audit row `sso_redirect_origins_changed` (target `server_config` / `sso_redirect_allowed_origins`, metadata `origins` and `count`; a refused audit write logs one value-free warning and never undoes the save).

Client-IP misconfiguration warnings (story client-ip-misconfiguration-warnings, epic SEC gate 3 G3-2; informational, node-local, never blocks anything):

```
W1, per request (Nebu.Web.Plugs.ClientIP.call/2, tuple peer, direct peer NOT trusted)
  request carries X-Forwarded-For (List.keymember?, no header read) ─► ClientIP.note_untrusted_forwarding/0
     :persistent_term ref -> :atomics slot (last warning, monotonic s); now - last >= 600 and compare_exchange wins
        => ONE static WARNING "client IP: a request carried X-Forwarded-For but its direct peer is not in NEBU_TRUSTED_PROXY_CIDRS ..."
     otherwise nothing; no slot (plug used without configure/1) => nothing. Resolution is UNCHANGED: the header is still ignored,
     the client address is the direct peer. A TRUSTED peer (nginx) never reaches this branch, so W1 cannot see the alb collapse.

W2, every 6 h (Oban cron "37 */6 * * *", leader only; Nebu.Workers.ClientIPCheckWorker.perform/1)
  since_ms = now - 24 h ─► Nebu.Matrix.device_address_spread(since_ms) ─► DeviceKeyStore.address_spread/1
     BEGIN; SET LOCAL statement_timeout = '5s'; SELECT count(*), count(DISTINCT user_id), count(DISTINCT last_seen_ip) FROM devices
       WHERE last_seen_ts >= $1 AND last_seen_ip IS NOT NULL AND last_seen_ip <> ''; COMMIT      (one seq scan, MVCC read, no address selected)
  {:ok, counts}   ─► assess/1: devices >= 10 and users >= 5 and addresses in 1..2 => ONE WARNING "client IP: all <n> devices of <u> users ..."
                     (three integers + oauth_offered, no address); otherwise silent
  {:error, reason} ─► ONE WARNING "client IP: device address check failed: <SQLSTATE | struct>"; perform/1 returns {:error, reason}
                     (max_attempts 1: the next cron run is the retry)
```

`last_seen_ip` is written with `ClientIP.get/1` at login and by the throttled (60 s) `touch_last_seen` on authenticated requests, so W2 reads the effect of the client-IP resolution after the fact. Both lines are aids: their absence proves nothing, and a single-NAT deployment legitimately triggers W2 (up to four lines a day, cannot be silenced, follow-up `ch`). W3 (the OpenTofu `check` block) is deploy time and has no runtime view (07-deployment).

Unrecognized endpoints: a Matrix request that matches no route reaches `Nebu.Web.Unrecognized.respond/2` and answers `404 M_UNRECOGNIZED` (or `405` + `Allow` for a known path with another method) without authentication; `GET /rooms/{id}/state[/...]` keeps `404 M_NOT_FOUND` (clients read it as "state absent").

_Source: Stories oauth-metadata-dcr-admin-approval, oauth-authorize-idp-delegation-code, oauth-token-endpoint, oauth-token-revocation-logout, oauth-legacy-coexistence and oauth-account-management and, in phase 2, oauth-trusted-proxy-client-ip, oauth-dcr-abuse-hardening, oauth-authorize-freshness, oauth-client-revocation, legacy-logout-per-device, oauth-room-summary-unrecognized, oauth-hardening-hygiene and legacy-sso-redirect-confirmation (epic: oauth-broker)._

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Implementation Patterns, §API & Kommunikation, §Resilienz & Selbst-Heilung; Story 9-19 (GAP-JOIN-PUBLIC, GAP-LEAVE-ONCE, GAP-FORGET); Story 9-22 (GAP-SINCE-IGNORED - per-device sync tokens, per-device logout cleanup); Story 9-23 (GAP-INVITE-STATE - invite_state stripped state enrichment: join_rules, avatar, create); Story 9-24 (GAP-GLOBAL-ACCOUNT-DATA - top-level account_data delivery in all 4 sync paths, RLS-aware ListGlobalAccountData); Story 9-25 (GAP-BUFFER-NEXT-BATCH - synthetic buf_<ms>_<seq> next_batch token on buffer fast-path, replaces echoed since= token); Story 9-27 (Scenario 3i - full Matrix §11.35.1 room upgrade flow, GRPC.RPCError error handling, archive_room_atomic idempotency, terminate_child, try/rescue failure audit); Story 9-28 (Scenario 3j - GetRelations RPC + bundled m.thread aggregations in sync unsigned field, attach_thread_aggregations, fetch_events_by_relation, count_thread_children, migration 000042); Story 9-29 (Scenario 3j-1 expanded - base route + three-segment route, dir/event_type/recurse/from params, prev_batch response field, fetch_events_by_relation/5 dynamic WHERE builder, 400 validation for invalid dir/recurse); Story 11-7 (Scenario 6 - SSO nonce generation + verification, Cache-Control: no-store on 302, denylist check in PostLogin, ssoStateStore capacity cap at 10,000); Story 11-8 (Scenario 3k - GET /rooms/{roomId}/event/{eventId} new route + GetEvent gRPC RPC, Horde membership guard, fetch_event/2 DB query, attach_thread_aggregations, core_grpc.pb.ex rpc :GetRelations + rpc :GetEvent bug fix); Story 11-10 (Scenario 3l - Matrix login claim mapping: claimLoader TTL-cached DB lookup, FormatUserIDFromClaims fallback chain, JWTMiddleware userIDClaimLoader param, NEBU_OIDC_USER_ID_CLAIM env override; Scenario 3m - Bootstrap Wizard Step 3 claim mapping form, draft save, atomic ClaimSelectionHandler transaction, identity-stability warning); Story 11-11 (Scenario 3n - send_receipt/2 start-on-demand fix: lookup_room → start_room, :noproc guard on get_state, 404 preserved for ghost rooms, 403 preserved for non-members); bugfix-sso-bootstrap-credentials (Scenario 6 addendum - dynamic OIDC client credentials via TTL-cached loaders; resolveClientID/resolveClientSecret in GetSSORedirect + GetSSOCallback; DB precedence over env var; no restart required); Story direct-room-heroes (Scenario 3o - m.heroes room summary in sync response: attach_heroes/3, get_room_heroes/2, syncRoomSummary+omitempty, proto fields 6-8 on SyncRoom, delta optimization via membership_changed check); Story admin-auto-join-rooms (Scenario 3p - auto-join rooms at first login: is_auto_join column+partial-index, list_auto_join_rooms, ensure_auto_join_memberships, is_new flag in TokenValidator, Task.start fire-and-forget, Admin UI toggle + CSRF, update_room_auto_join gRPC+DB); Story auto-join-on-user-import (Scenario 3q - bulk import provisioning path: BulkImporter.import_users/1 returns imported_user_ids, bulk_import_users/2 spawns Task.start per new user, ensure_auto_join_memberships + ensure_personal_room fire-and-forget, try/catch :exit guard on Room.Server.join/2)_
