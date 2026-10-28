---
story_id: sync-stream-position
title: "The /sync since token continues from per-room stream positions instead of one timestamp anchor: every joined, invite and leave room is read from the device's own per-room cursor by position (allocated per room in commit order, story events-room-position), a truncated room delivers its NEWEST events with a real /messages prev_batch, and the device's previous next_batch stays valid for one generation (closes fc, mitigates cj (b))"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
traceability_id: REQ-2026-003
created: 2026-10-26
branch: feature/migrate-to-oauth2
depends_on: events-room-position
sizing: large
---

# Story: `/sync` continues from per-room stream positions (follow-up `fc`, with `cj` (b))

## Story

**As** a user of any Matrix client (Element Web, Element X, FluffyChat) with one or more devices, **I want** every incremental `/sync`
to deliver every event, invitation and leave that happened since my device's previous `next_batch` exactly once, also when a room got
more than 20 new events, when two writers commit out of order, when two events share a millisecond, when a room was created with
timestamps ahead of the clock or when the cluster nodes' clocks disagree, and I want a retried request with my previous `next_batch`
to continue incrementally, **so that** no message silently disappears from my timeline, a room I left or was banned from is always
removed, and a lost response does not cost a full re-sync without `rooms.leave`.

**Split (D1).** The fix is two ordered pipeline runs. **Story 1, `events-room-position`** (prerequisite, its own file
`docs/stories/oauth-broker/events-room-position.md`, migration `000053`): every event gets a per-room position allocated in commit
order; no read changes. **This file is story 2** (migration `000054`): `/sync` reads by those positions and closes `fc`. This story
must not start before story 1 is merged.

Scope: (1) per-device per-room cursors stored server-side (D3) and the token format (D6); (2) the incremental read of join, invite and
leave rooms by position (D4, D9, D10), newest-N truncation with a valid `/messages` `prev_batch` (D5); (3) the initial sync writes the
cursors (D12); (4) the previous token generation (`cj` (b), D8); (5) the HTTP layer's "newly joined" detection (D11); (6) docs: `fc`
closed, notes on `cj`, `eu`, `gg`, `gk`, `bp`, one new row `cq` (D17).

## Premise check (2026-10-26, HEAD `8c58dbd4`, read-only)

Full notes with file:line: `_bmad-output/nebu/epics/oauth-broker/step-results/sync-stream-position/premise-check.md`. The facts the
design depends on:

- The core token is `base64("<user>:<last_event_id>:<monotonic>")` (`new_since_token/2`, `server.ex` 5390), never decoded: only
  compared for equality with the request key's `sync_tokens.since_token`. The anchor is the row's `last_event_id`, resolved to a
  timestamp once per request (`resolve_since_ts/1`, 5566) and AGAIN per joined room (`fetch_visible_events_since/4` ->
  `since_anchor/1`, `db.ex` 2694-2710; item (e)). The new anchor is the newest delivered event by `origin_server_ts` over ALL rooms
  (6023-6029).
- Every joined room is read on every build (`fetch_delta_rooms/3`, 6159), quiet or not: the OLDEST 20 with `origin_server_ts >
  since_ts` (`read_visible_since/4`, `db.ex` 2716). `prev_batch` of a limited join or leave room is the oldest delivered EVENT ID
  (6178, 5812), which `/messages` decodes as `:empty` (newest page, `decode_token/1`, `db.ex` 860): wrong (the pre-existing defect on the
  `fc` row).
- Writers: the room process is NOT the only writer of a room. Four direct writers in `EventDispatcher.Server` (the `m.room.create`
  event, the createRoom / upgrade state chain `emit_state_event_at/6`, `create_personal_room/2`, `emit_decline_event/2`) insert
  outside it, autocommit; during a Horde handover two room processes can briefly exist. Three room-process writers already lock the
  `rooms` row `FOR NO KEY UPDATE`, `apply_member_change/4` locks it `FOR SHARE`, the message path does not lock it.
- Wake-ups (all cluster-wide since `fe`) only trigger a rebuild; they carry no position.
- `newly_joined_room_ids/2` (`protected.ex` 258) needs the join EVENT in the timeline to send a newly joined room's full room account
  data: a newest-N timeline can omit it.

## Decisions

- **D1 Two ordered stories; this file is story 2.** Story 1 `events-room-position` (small-medium): migration `000053`
  (`rooms.event_pos`, `events.room_pos`, a `BEFORE INSERT` trigger that allocates the position under the `rooms` row lock, a partial
  unique index), the lock-mode change of `apply_member_change/4`, no backfill, no read change. Story 2 (this file, large): everything
  below. Reason: story 1 changes the write path of every event (locking, concurrency tests, migration on the largest table) and is
  reviewable on its own; story 2 changes the read path and the token. Neither closes `fc` alone; together they close (a)-(e), (h) and
  the timestamp part of the invite / leave class.

- **D2 Position scheme: per-room positions in commit order (story 1), never a global one.** Each event gets `events.room_pos`, drawn by
  the trigger as `UPDATE rooms SET event_pos = event_pos + 1 WHERE room_id = NEW.room_id RETURNING event_pos` inside the inserting
  transaction. The row lock is held until that transaction ends, so a second writer of the same room (any process, any node, any
  writer path) waits and draws N+1 only after N committed or rolled back (a rollback also rolls the counter back: no gaps). Therefore,
  per room, **position order == commit order**: a reader that sees position N+1 committed has seen N. Rooms never block each other.
  **Rejected:**
  (i) a global `BIGSERIAL` / `nextval` at insert: a transaction holding value 10 can commit after a reader passed 11 (the exact `fc` (b)
  hole);
  (ii) a global sequence with a visibility fence (`pg_snapshot_xmin(pg_current_snapshot())`, deliver only rows of transactions below
  xmin): sound, but delivery is coupled to EVERY in-flight transaction with an xid in the PostgreSQL cluster (an unrelated Admin, media or
  GDPR transaction, an idle-in-transaction connection stalls all `/sync` delivery), and the wake-up that arrives after a commit finds the
  event still behind the fence and waits until the 25 s timeout;
  (iii) a global sequence drawn under one global advisory lock (commit order == position order cluster-wide): serialises every event
  commit of the whole cluster (throughput ceiling of about one commit latency per event, one slow fsync stalls every room, the 1 s
  `lock_timeout` of the room writers starts failing under load);
  (iv) an in-memory counter in `Room.Server`: not the only writer (D2 premise), lost on restart / handover;
  (v) per-room positions in the client token: unbounded token size (URL length) and a client-controlled input per room.

- **D3 Per-device per-room cursors, stored server-side; the client token stays O(1).** New table `sync_room_cursors (user_id,
  device_id, room_id, gen BIGINT, pos BIGINT, class TEXT, invite_marker BIGINT, prev_pos BIGINT, prev_class TEXT, prev_invite_marker
  BIGINT)`, `PRIMARY KEY (user_id, device_id, room_id)`, `FOREIGN KEY (user_id, device_id) REFERENCES sync_tokens ON DELETE CASCADE`
  (the device teardown, logout, `/logout/all`, deactivation and GDPR erasure delete the cursors with the token row, no new cleanup
  path; `cj` (a) orphan-row race unchanged and accepted). `pos` = the highest room position this device has been sent for the room
  (or the head it was synced to), `class` = the room's partition class at that time (`join`, `invite`, `leave`), `invite_marker` = the
  `invited_at` of a delivered ROW-ONLY invitation. **Size bound:** the client token is a constant-size nonce (+ the existing room
  account data suffix); server-side storage is one row per (device, partition room), deleted when the room leaves the partition
  (forgotten) or with the device; an incremental sync WRITES only the rows whose values changed (= rooms with deliveries or a class
  change), an initial sync writes all partition rooms once (one bulk statement). The device-less `''` key (D2 of
  sync-token-per-device) uses the same table with `device_id = ''`.

- **D4 The incremental read: one head statement, then only the rooms that moved.** After the partition read, ONE statement reads, for
  all candidate rooms, `rooms.event_pos` (the committed head) and the device's cursor row. Only a room with `head > base pos` (or
  without a row, or with a class change) is fetched, with the exact range `(base pos, head]` (the upper bound is the head READ, so the
  cursor written afterwards matches exactly what was considered, and an event committed after the head read is left for the next
  sync). `get_event_timestamp/1` is no longer called by `/sync` (neither once per request nor per room); a quiet room costs no
  statement. Visibility (story history-visibility-enforcement) is unchanged in meaning: the history-visibility segments still judge
  each candidate row by its `origin_server_ts`; only the candidate set is selected by position. The timeline is ordered by
  `room_pos` ASC (stream order). Events stored before story 1 (`room_pos IS NULL`) are never part of a position range (every
  client falls back once at rollout, D6, so they predate every cursor). **Fix cycle 1 (security review MEDIUM-1):** the range read
  applies to a joined room WITH a cursor row; a joined room WITHOUT one (newly joined, dropped from an initial sync, or a retry whose
  base row did not exist) is read as an initial-sync room (D9): the segment-driven newest-20 page up to the head (`room_pos <= head OR
  room_pos IS NULL`, so legacy events are included, ordered by `origin_server_ts`), `limited` / `prev_batch` as D5.

- **D5 Truncation: the NEWEST 20 visible events of the range, `limited` and a real `/messages` `prev_batch`; the cursor moves to the
  head.** Read 21 visible rows of `(base, head]` by `room_pos DESC`; deliver the newest 20 ascending; `limited = true` when a 21st exists;
  `prev_batch` = the `v1_` `/messages` token of the oldest delivered event (`encode_token/2`, the same encoder as the initial sync's
  `prev_batch`), so `GET /messages?dir=b&from=<prev_batch>` returns the gap. The cursor becomes `head`: the tail is never lost, the gap is
  at the START (the spec model: a limited timeline holds the most recent events, the client fills backwards from `prev_batch`). A
  non-limited room has no `prev_batch` (as today). **The pre-existing wrong incremental `prev_batch` (an event id) is FIXED** for join and
  leave rooms: with newest-N it is the only way to reach the gap. **Rejected:** "oldest 20 and a per-room cursor at the last delivered
  event" (no tail loss either, but the client lags N syncs behind a busy room, `limited` would mean the opposite of the spec and
  wake-ups would return at once until the room is drained). Residual (follow-up `cq` (b)): `/messages` orders by `(origin_server_ts,
  event_id)`, not by position: a gap event whose timestamp is NEWER than the oldest delivered event (a late commit or a skewed clock)
  is not returned by backward pagination from that token.

- **D6 Token format and compatibility.** The core token becomes `s2_` + base64url (no padding) of 16 random bytes: no user id, no event
  id, never contains `.` (the `.<pos>` room account data suffix and `split_since_token/1` stay unchanged). `sync_tokens.stream_version
  SMALLINT NOT NULL DEFAULT 0` (catalog-only); the new code writes `1`. **A row with `stream_version = 0`, or a client token without the
  `s2_` prefix, is an initial-sync fallback ONCE** (the existing, tested recovery; release note "after the update each client does one
  full sync", as D3 of sync-token-per-device). An old timestamp-anchored token is therefore never read as positions, and no event id is
  ever interpreted as a position. Mixed-version window: an old node writes an old-format token (`stream_version` may already be 1 from a
  new node), the prefix check catches it -> fallback, never a misread. `last_event_id` stays written (the newest delivered event id,
  informational) and is no longer read; dropping it is a later cleanup.

- **D7 Token row and cursors are written atomically, guarded by the base token.** The persist step is ONE transaction: `SELECT ... FROM
  sync_tokens WHERE user_id = $1 AND device_id = $2 FOR UPDATE`; it proceeds only if the row's `since_token` (current generation) or
  `prev_since_token` (D8) still equals the base token the request was built from; then it upserts the changed cursor rows and the token
  row. Otherwise (a concurrent request of the same device committed first) nothing is written: the response is still sent, its token is
  unknown and the next request falls back (today's behaviour for concurrent requests; residual `cj` (b), third case). Reason: cursors
  advanced without the token (or the reverse) would lose events (cursor ahead of a still-valid old token) or repeat them. The initial
  sync / fallback writes unconditionally (it has no base) in the same single transaction.

- **D8 The previous generation stays valid (the `cj` (b) mitigation).** `sync_tokens` gains `generation BIGINT NOT NULL DEFAULT 0`,
  `prev_since_token TEXT`, `prev_account_data_pos BIGINT`, `prev_cross_signing_pos BIGINT`. A request whose core token equals
  `since_token` uses the current base: every cursor row's `(pos, class, invite_marker)`. A request whose core token equals
  `prev_since_token` uses the previous base: for a row with `gen = generation` its `prev_*` values (`prev_pos IS NULL` = the row did not
  exist in the previous generation), for a row with `gen < generation` its current values (unchanged in the last generation); the D9
  positions of sync-token-per-device are taken from `prev_account_data_pos` / `prev_cross_signing_pos` (the HTTP layer passes the client's
  core token to `get_positions`). The write of the new generation `g' = generation + 1` sets `prev_since_token := base token`,
  `prev_*_pos := base positions`, and for every cursor row whose new value differs from what is stored OR whose `gen = generation` (a row
  changed in a generation that is being replaced must be re-based): `prev_* := base values`, current values := new, `gen := g'`. A token
  two or more generations old, or any other token, falls back (unchanged). **Effect:** a retry after a lost response, or a client
  restored from the token before its last one, continues incrementally with `rooms.leave`. **Not covered** (stays on `cj` (b)): two
  CONCURRENT requests of one device (D7), and older cached tokens. **Security:** the previous token grants nothing beyond the caller's
  own delivery (D18); it is invalid as soon as the client moves on to a newer token (a retry with it writes a new generation whose
  previous token is again the one presented, security review cycle 0 INFO-1).

- **D9 Invitations and leaves by position and class.** With `base` = the room's base row (absent = the room entered the partition since
  this device's last sync):
  - **join**: delivered when `head > base.pos`, or `base` absent, or `base.class != 'join'` (newly joined: see D11). Range `(base.pos or 0,
    head]` (for an absent row the visible newest 20, as an initial-sync room, history visibility decides what a newcomer sees).
  - **invite**: new when `base` absent, or `base.class != 'invite'`, or the invite EVENT's `room_pos > base.pos` (a re-invite after a
    decline), or for a ROW-ONLY invitation `invitation.invited_at != base.invite_marker` (an exact equality on the row's own value: no
    clock comparison; the former "repeats until the anchor passes `invited_at`" behaviour ends: delivered exactly once). After delivery
    the row stores `class = 'invite'`, `pos = head`, `invite_marker`.
  - **leave**: new when `L.room_pos IS NOT NULL` and (`base` absent, or `base.class != 'leave'`, or `L.room_pos > base.pos`). A legacy
    `L` (stored before story 1, `room_pos` NULL) is never new (it predates every cursor). After delivery the row stores `class =
    'leave'`, `pos = head`.
  - `ends_wait?` keeps its definition (story sync-membership-partition D5).

- **D10 The leave window is bounded by positions AND by the row clocks (fail-closed under skew, items (g) (h)).** Window = events with
  `room_pos > max(base.pos, P.room_pos)` and `room_pos < L.room_pos` AND (unchanged, as an extra restriction) `origin_server_ts > joined_at`
  and `origin_server_ts < left_at` of the member row when set, newest 20, `limited` / `prev_batch` as D5; `P` prepended only when the
  window is not limited and `P.room_pos > base.pos`. Nothing at or after the leave / ban position is ever read. The row clock bounds can
  only SHRINK the window under clock skew (never widen it): the security bound of story sync-membership-partition (review cycles 1 / 2)
  holds. `left_at` / `joined_at` stay node-clock values (no migration of `room_members`). The partition order of the latest member
  events (`@sql_latest_member_events`, D3 tie order by timestamp) is UNCHANGED (follow-up `cq` (b) / `eu`).

- **D11 The core reports the newly joined rooms explicitly.** `GetSyncDeltaResponse` gains `repeated string newly_joined_room_ids = 7`
  (`proto/core.proto` + `lib/pb/core.pb.ex`, parity doc): the join rooms whose base row was absent or had `class != 'join'`.
  `protected.ex` `finish_sync/6` uses it instead of scanning the timeline for the join event (a newest-N timeline can omit it), so a newly
  joined room still gets ALL its room account data. The room's state shape is unchanged (joined slice, `gg`).

- **D12 Initial sync and fallback write the cursors.** Before the join rooms are fetched, ONE head statement reads `rooms.event_pos` of all
  partition rooms; each initial room page (`visible_page!/6`, newest 20 by timestamp as today) is bounded by `room_pos <= head OR room_pos
  IS NULL` (exact: an event committed after the head read is not in the snapshot and has a position above the cursor, so it comes with the
  next delta; no duplicate, no loss). The persist transaction (D7) deletes the device's cursor rows, inserts one row per partition room
  (`pos = head`, `class`, `invite_marker` for delivered row-only invitations, `gen = 1`, `prev_* = NULL`), and writes the token row with
  `stream_version = 1`, `generation = 1`, `prev_since_token = NULL`. One bulk statement (`unnest`) regardless of the room count.

- **D13 `D5` of sync-wakeups-cluster-wide becomes per room.** An unresolved joined room keeps ITS cursor (not advanced, not re-based);
  every other room advances. The global "keep the previous anchor" is gone: an unresolvable room no longer makes the other rooms'
  events repeat (the `bp` symptom "re-delivered, the long-poll returns at once" ends; the 1 s poll per build stays: note on `bp`).
  `consistent_delivery/4` (the partition re-read after the fetch, the bounded rebuilds, the `503`) is KEPT unchanged: its security
  reason (never deliver an event after a demotion) still holds; its "global anchor" reason becomes moot (comment updated).

- **D14 Per-sync cost.** Incremental: partition (unchanged) + 1 head/cursor statement + 1 fetch per MOVED room (instead of 1 anchor read +
  1 fetch per joined room) + the persist transaction (1 row lock + 1 cursor upsert when something changed + the token upsert, which existed).
  A user with 200 joined rooms and 1 active room: from about 202 statements to about 5 plus the partition. Initial sync: + 1 head statement
  + 1 cursor delete + 1 bulk insert. The statement-count pins are re-pinned DELIBERATELY with the measured numbers.

- **D15 Cluster safety.** No node-local state: positions come from the database (story 1), cursors and tokens are rows, the row lock of D7
  serialises two requests of one device on any nodes, wake-ups are unchanged (`:pg.get_members/1`). Clock skew between nodes no longer
  affects which events are delivered (only the ts-ordered reads named in `cq` (b)).

- **D16 Unchanged.** The partition rules and the rule table; history visibility; `full_state=true` (D14 of sync-membership-partition;
  rooms with news keep their shape, the others are full-state rooms with empty timelines); the device key choice (D1 / D2 of
  sync-token-per-device), the D9 / D10 / D11 global account data and cross-signing delivery (only their PREVIOUS values are added, D8);
  the room account data suffix; `/messages`, `/context`, `/initialSync`; the `503` / fallback rules for a failed read (no token persisted);
  the long-poll and the wake-ups; the incremental state shape (`gg`); thread aggregations; the initial sync's response shape.

- **D17 Follow-ups (docs, done in this story).**
  - **`fc` CLOSED** with the pattern "**CLOSED by story sync-stream-position (YYYY-MM-DD): ...**" followed by "**Original item:**" and
    the full original text (all pinned tokens stay: "timestamp anchor", "same millisecond", "committed", "stream position", "`503`",
    "D3", "invite + 1", "predecessor", "latest + 1", "(d)", "initial `/sync`", "`state`"); status `closed`. The closure names: (a)-(e)
    and (h) closed by per-room positions and per-device cursors, (f) moot (no anchor event), (g) moved to `cq` (a), the `prev_batch`
    fix, the one-time rollout fallback, the previous generation.
  - **`cj`**: a note: (b) mitigated by D8 (retry / previous token continue incrementally); residual: concurrent requests of one device
    and tokens two generations old still fall back.
  - **`eu`**: a note: positions give a tie-free per-room commit order; the latest-per-slot reads and the D3 tie order still use
    `origin_server_ts` (untouched here, `cq` (b)); the `fc` (d) loss from the createRoom clock lead is closed.
  - **`gg`**: a note: a state DELTA for incremental syncs can now be built from positions (the state events in `(base, head]`); not done
    here (explicitly out of scope).
  - **`gk`**: a note: the timestamp residual of visibility is unchanged (segments are still by `origin_server_ts`); option "position
    instead of timestamp" recorded in `cq` (b).
  - **`bp`**: a note (D13).
  - **New row `cq`** (formerly deliberately free; the only free id the id line names): "Residuals of the per-room stream positions
    (story sync-stream-position)": (a) the partition-read vs `:pg`-subscription gap (former `fc` (g)): a change in that gap is delivered
    by the next sync, up to 25 s late; (b) `/messages`, `/context`, the latest-per-slot reads, the D3 tie order and the history-visibility
    segments still order by `origin_server_ts` (skew and the createRoom clock lead still matter THERE; a position-based `/messages` token
    and `room_pos` tie-breaks would close it together with the open parts of `eu` and the `gk` timestamp residual); (c) events stored
    before migration 000053 have no position (no backfill, story events-room-position D3); a future position-based reader of OLD events
    needs a backfill; (d) cursor storage is one row per (device, partition room) without a separate cap (bounded by the partition and the
    device count); (e) the newly joined room keeps the joined-slice state (`gg`). Status `open, non-gating`.
  - **The id line** keeps `unused:[^.]*`gm` onward`: "unused: `cq` (deliberately free) and `gm` onward (" becomes "unused: `gm` onward ("
    and the parenthesis gains "; `cq`, formerly deliberately free, is the row after `cm`: story sync-stream-position" (no `.` between
    `unused:` and "`gm` onward", as the eight suites require).
  - `docs/architecture/07-deployment.md`: release note (one full sync per client, migrations 000053 / 000054 and their locks, mixed
    version = fallback); `docs/architecture/06-runtime.md` (the sync flow) and `docs/matrix-api-scope.md` (the `prev_batch` and
    `limited` sentences, if present) updated.

- **D18 Security review required.** Trust boundaries touched: the since token (new format, previous generation valid), the per-device
  cursors (keyed ONLY by the authenticated user and device, never by request input), the leave / ban window (D10: position bound plus the
  unchanged row clock bounds; nothing at or after the leave / ban position), invitations of ignored inviters (unchanged), history
  visibility (unchanged filter on a new candidate set). Expected: no new disclosure; the token no longer carries the user id. For the
  review: a foreign or forged `s2_` token never matches (fallback, other rows byte-identical); the previous token of a device is useless to
  another device or user (the lookup key is the caller's); a cursor row can only ever select the caller's own visible events.

- **D19 Migration `000054_sync_room_cursors` (number confirmed at commit; `000053` is story 1).** `CREATE TABLE sync_room_cursors` (D3) and
  `ALTER TABLE sync_tokens ADD COLUMN stream_version SMALLINT NOT NULL DEFAULT 0, generation BIGINT NOT NULL DEFAULT 0, prev_since_token
  TEXT, prev_account_data_pos BIGINT, prev_cross_signing_pos BIGINT` (catalog-only, no rewrite, a brief ACCESS EXCLUSIVE lock on
  `sync_tokens`); grants for `nebu_app` as in 000039 / 000052. No lock on `events`. No maintenance window. Down: drop the table and the
  columns (every client falls back once again).

**Requirements check.** (a) a room with more than 20 new events delivers its newest 20 with a usable `prev_batch`, the cursor reaches the
head: no tail loss (D5); (b) a late commit is delivered: per room, position order is commit order (D2) and each room has its own cursor
(D3); (c) positions are unique per room: no same-millisecond skip; (d) / (h) delivery does not depend on any clock (D4), the row clock
bounds only shrink the leave window (D10); (e) no per-room timestamp read, quiet rooms cost nothing (D4, D14); `cj` (b) retry continues
(D8); old tokens fall back once, never misread (D6); token size constant, storage bounded by the partition (D3); cluster-safe (D15);
no regression of the partition / membership / visibility rules (D9, D10, D16).

### Files (indicative, for the implementer)

- `server/priv/migrations/000054_sync_room_cursors.{up,down}.sql` (D19).
- `server/lib/nebu/matrix/room/db.ex`: `room_heads(room_ids, user_id, device_id)` (heads + cursor rows, one statement),
  `fetch_visible_events_in_range(room_id, viewer, after_pos, head, limit)` (newest `limit + 1` visible, by position, the hv fragment
  applied per row), `leave_window_events` by positions (D10), the initial page bound (D12). The timestamp readers
  (`fetch_events_since/3`, `fetch_visible_events_since/4`, `get_event_timestamp/1`) stay as `DBBehaviour` callbacks (other callers and
  the test fakes), `/sync` stops calling them. The new reads are NOT `DBBehaviour` callbacks; a module without them is the `503` of the
  delta (fail closed, like the partition reads); the dispatcher test fakes get them.
- `server/lib/nebu/matrix/event_dispatcher/server.ex`: `sync_delta/2` (base selection current / previous), `do_incremental_sync/6`,
  `build_delta/5`, `fetch_delta_rooms/3`, `build_leave_room/3`, `invite_new?` / `leave_new?`, `initial_sync/2`, `persist_token/4` -> the
  D7 transaction, `new_since_token/2` (D6), the D5 per-room unresolved handling.
- `server/lib/nebu/matrix/session/pg_store.ex` (+ `postgres.ex`, behaviour, `@optional_callbacks`): the guarded persist, the base read,
  `get_positions(user, device, core_token)` (current or previous).
- `server/lib/nebu/web/router/protected.ex`: `newly_joined_room_ids` from the core (D11); the core token passed to `get_positions`.
- `proto/core.proto`, `server/lib/pb/core.pb.ex`: field 7 (D11).
- Docs: D17.

- **D20 Clarifications after the ATDD step (orchestrator, 2026-10-27).**
  (1) D8 re-base: a row is re-based only when the request's base is the PREVIOUS generation AND the row's `gen = generation`; a request with the
  CURRENT token writes only rows whose values changed (D3 wins; otherwise every row that ever changed would be rewritten on every sync).
  (2) D9: an inviter that was ignored and is un-ignored later re-enters the partition without a base row, so its pending invitation is delivered
  once (no base row = new); the old "missed events are not re-sent" test is amended to that.
  (3) D5/D10: `limited` is set when a 21st visible event exists (20 events are not limited); the leave window reads the newest 21 and keeps 20.
  (4) D7: for a device whose token row was deleted meanwhile NOTHING is written (no orphan token row, no orphan cursor row); `cj` (a) for this path
  is closed by this.
  (5) D7/D8 make the persist depend on the position columns: unreadable columns fail CLOSED (no 200, nothing written, the old token stays valid),
  where the old upsert ignored them (200).
  (6) Names/shapes chosen in the ATDD step and pinned by tests: `Room.DB.leave_window_events/5` (positions + clock bounds), `fetch_visible_events/6`
  (initial page bound by the head), `room_pos` in `latest_member_events/2` entries, a guarded persist whose name is the implementer's choice.
  (7) `now_ms` is NOT made injectable; the clock-skew scenario inserts through `Room.DB.insert_event/1` with a timestamp behind the clock.
  (8) Statement-count pins of existing suites (history visibility, member prev content) are re-pinned to the measured values of the final design.

- **D21 Test contract (named by the ATDD step, binding for the dev).** The tests, the spy and the shared unit fakes
  (`Nebu.Matrix.SyncPositionsFake`) rely on exactly these shapes and nothing else of the store / read API:
  (1) **Persist.** The ONE write of a `/sync` response is `persist_sync_position(user_id, device_id, spec)` of the `:event_dispatcher,
  :pg_store_module` seam (`device_id` is `""` for the device-less key), answering `:ok | :stale | {:error, term}` (`:stale` = the guard of D7
  refused, nothing written; an `{:error, _}` is a handled `503 M_UNAVAILABLE`, no token persisted). `spec` is a map with the keys `mode`
  (`:initial | :delta`), `new_token` (the core `s2_` token), `last_event_id` (string or nil), `base_token` (delta only: the core token the
  request presented), `rows` (the cursor rows to write: `%{room_id, pos, class, invite_marker, base}` with `base` = `nil | %{pos, class,
  invite_marker}`, the value the request was built from), `keep` (the partition room ids; the device's rows of other rooms are deleted) and, for a delta, `expected_generation` (fix cycle 1, see (5); absent = not checked).
  Exactly ONE call whose function name starts with `persist` happens per request, its first argument is the user id.
  (2) **Token lookup.** `get_since_token/1,2` keep their name and answer `{:ok, %{since_token, last_event_id, stream_version, generation,
  prev_since_token}}` (the three new keys are what the core reads) or `{:error, :not_found}`.
  (3) **Reads of `Room.DB`.** `room_heads(room_ids, user_id, device_id)` answers `{:ok, %{room_id => %{head: integer, cursor: nil | %{gen,
  pos, class, invite_marker, prev_pos, prev_class, prev_invite_marker}}}}` (a room without a `rooms` row is absent, `[]` costs no statement);
  `fetch_visible_events_in_range(room_id, viewer, after_pos, head, limit)` and `fetch_visible_events(room_id, viewer, dir, limit, from, head)`
  answer like their existing twins (`{:ok, events}` / `{:ok, events, next, prev}`), the range read the newest `limit + 1` rows newest first;
  `leave_window_events(room_id, after_pos, before_pos, after_ts, before_ts)` answers `{:ok, events}` (newest 21, newest first), `0` and
  `9_223_372_036_854_775_807` meaning "no clock bound".
  (4) **Migration `000054`.** `gen`, `pos`, `class` are `NOT NULL`; `invite_marker` and the three `prev_*` columns are nullable; the file is
  idempotent (`IF NOT EXISTS` for the table and each column), like 000052 / 000053.
  (5) **Residual of `cj` (b).** A second request built from the SAME base token while the first one committed would pass the token guard
  through `prev_since_token` (D7 / D8), but its cursors were read against rows the first one may have advanced (a silent loss, code
  review cycle 0 MAJOR-1). Fix cycle 1 (orchestrator decision, option (a)): the delta spec carries `expected_generation` (the
  generation of the token row when the request read it) and the guarded write also requires `generation = expected_generation`
  (compare-and-set). The second writer is `:stale`: nothing is written, its response is still sent with a token that is not stored,
  and the client's next request with it is the one-time fallback; nothing is lost. A sequential retry with the previous token (D8)
  is unaffected (the generation does not change between its read and its write). A spec without the key is checked by the token
  only (the shared fakes keep working).

## Acceptance Criteria

```gherkin
Feature: /sync continues from per-room stream positions and never loses an event, invitation or leave

  Scenario: (a) A room with more than 20 new events keeps its tail when another room has a newer event
    Given a device has synced and then room A receives 30 new messages and afterwards room B receives 1 message
    When the device calls /sync with its next_batch
    Then room A carries its NEWEST 20 messages with limited true and a prev_batch for which GET /messages?dir=b&from=<prev_batch> returns the 10 older ones, room B carries its message
    And the following /sync with the new next_batch repeats none of them and a message sent to A afterwards is delivered

  Scenario: (b) An event committed after a sync read is delivered although its timestamp is older than delivered events
    Given a device syncs while a transaction has inserted an event into room A with an older origin_server_ts but has not committed, and room B has a newer committed event
    When the transaction commits after the sync response and the device syncs again
    Then the second response delivers the room A event exactly once

  Scenario: (c) Two events in the same millisecond on either side of a sync are both delivered
    Given two events of one room carry the same origin_server_ts and a /sync response was built after the first committed and before the second
    When the device syncs with that response's next_batch
    Then the second event is delivered and the first is not repeated

  Scenario: (d) Messages are not lost behind a createRoom chain stamped ahead of the clock
    Given an invitee's last delivered event is a createRoom invite stamped up to about 70 ms ahead of the clock, and a message is sent in another of the invitee's rooms inside that lead
    When the invitee syncs with the next_batch that delivered the invite
    Then the message is delivered

  Scenario: Two writers of one room interleave with a reader
    Given a direct writer (createRoom state chain) and the room process write to the same room concurrently, the first holds position N uncommitted and the second waits
    When a device syncs during the wait, after the first commit and after the second commit
    Then no response contains position N+1 before N, the device's cursor never passes an uncommitted position, and both events are delivered exactly once across the responses

  Scenario: Clock skew between nodes does not hide an event
    Given node 2's clock is 5 s behind node 1's and a message is written through node 2 after the device received a newer event written through node 1
    When the device syncs
    Then the message is delivered

  Scenario: A since token issued before the update falls back once and is never read as positions
    Given a device's sync_tokens row was written before migration 000054 (stream_version 0) or the client presents a core token without the s2_ prefix
    When the device calls /sync with that next_batch
    Then it receives one 200 initial-shaped response (fallback, the own user in device_lists.changed) and every following /sync of the device is incremental from its per-room cursors

  Scenario: A retry with the previous next_batch continues incrementally
    Given a device received next_batch T1, then a response with T2 was lost, and in between the user was kicked from a room and a message arrived in another room
    When the device calls /sync again with T1
    Then the response is incremental (not a fallback), carries the kicked room in rooms.leave and the message, and its new next_batch works
    And a next_batch two generations old, a foreign device's or user's next_batch, and a forged s2_ token are 200 initial-shaped fallbacks of the caller's own partition, and every other sync_tokens and sync_room_cursors row stays byte-identical

  Scenario Outline: The leave window ends before the <cause> and never extends past it
    Given device B of a user has synced while the user was joined, and later messages, then the <cause>, then more messages are sent in the room
    When device B syncs
    Then rooms.leave carries the room with the messages strictly between B's cursor (or the join) and the <cause> event, then the <cause> event, and no event at or after it
    And with the member row's left_at set earlier than the event (a skewed node clock) the window ends at left_at instead, never later

    Examples:
      | cause |
      | leave |
      | kick  |
      | ban   |

  Scenario: Invitations are delivered exactly once by position
    Given a device has synced and the user then receives an event-backed invitation in room R and a row-only (upgrade) invitation in room S
    When the device syncs twice, then declines R, is re-invited to R and syncs again
    Then the first sync carries R and S in rooms.invite, the second carries neither, and the third carries the re-invitation to R

  Scenario: A newly joined room with more than 20 events gets all its room account data
    Given a device has synced, the user joins a room that then receives 25 messages, and the user has room account data for that room
    When the device syncs
    Then the room is in rooms.join with its newest 20 messages, limited true, a valid prev_batch, and all of the room's account data

  Scenario: Quiet rooms cost no statement and no anchor timestamp is read
    Given a user is joined to 50 rooms and only one received an event since the device's last sync
    When the device calls /sync
    Then exactly one room timeline read runs, get_event_timestamp is never called, and the statement count equals the re-pinned constant

  Scenario: History visibility still filters the position window
    Given a room's history visibility hides some events of the device's position range from the user
    When the device syncs
    Then the hidden events are not delivered, do not count towards the 20, and the cursor still reaches the head
```

## Test list (ATDD)

1. HTTP on a throwaway PostgreSQL (`sync_stream_position_http_test.exs`): scenarios 1-4, 6-12 with two opaque sessions; (b) and the
   two-writer case with a held transaction on a second connection (`Ecto.Adapters.SQL.Sandbox` off: real concurrency); (c) with fixed
   `origin_server_ts` values written through the real writers' code paths; (d) with a real createRoom chain; skew by stamping through a
   writer with a shifted clock (the injectable `now_ms`) rather than faking positions.
2. DB tests (`room/sync_positions_db_test.exs`): `room_heads/3` (one statement for N rooms, cursors only of the given key),
   `fetch_visible_events_in_range/5` (newest-first, `limit + 1`, NULL positions excluded, hv applied per row), the leave window by
   positions plus the clock bounds, the initial page bound.
3. Store tests (`session/pg_store` + new): the D7 guarded transaction (a concurrent request of the same device commits first -> no write),
   the D8 base selection (current / previous / two old), the cascade on device delete and erasure.
4. Dispatcher unit tests with the fake modules: the base selection, `newly_joined_room_ids`, D13 per-room unresolved.
5. Migration `000054` up / down on a fresh and a populated schema.
6. Docs test (`sync_stream_position_docs_test.exs`): `fc` CLOSED with its original text, notes on `cj`, `eu`, `gg`, `gk`, `bp`, row `cq`
   unique with status, the id line still matching `unused:[^.]*`gm` onward` and no longer listing `cq` as unused, the release note.

**Existing tests that need DELIBERATE amendments (with an old -> new comment):** `event_dispatcher/sync_test.exs` (52 `last_event_id`,
the delta fakes `get_event_timestamp` / `fetch_events_since`, `prev_batch` = event id), `event_dispatcher/sync_membership_partition_test.exs`
(anchor assertions, `leave_window_events` by timestamps, the `D5 - ...` "keeps the previous anchor" tests -> per-room cursor),
`event_dispatcher/server_dedup_test.exs`, `sync_wakeups_cluster_test.exs` (anchor kept), `sync_membership_partition_http_test.exs` (the
L-2 anchor test, `prev_batch`), `sync_token_per_device_http_test.exs` and `sync_token_per_device_dispatcher_test.exs` ("never an empty
anchor": becomes "the token row has stream_version 1 and cursor rows"), `session/pg_store_test.exs` and `session/session_supervisor_test.exs`
(the `@behaviour` fakes gain the new optional callbacks), `history_visibility_http_test.exs` (incremental statement count 51, `prev_batch`),
`history_visibility_unit_test.exs`, `history_visibility_test_support.exs`, `history_visibility_security_cycle1_test.exs`,
`room/history_visibility_db_test.exs` (the delta read moves to `fetch_visible_events_in_range/5`; the timestamp twin's own tests stay),
`room/membership_partition_db_test.exs` (8 x `leave_window_events`), `membership_state_http_test.exs`, `member_prev_content_http_test.exs`
(initial sync 57 statements), `matrix_client_compat_test.exs`, `sync_token_per_device_docs_test.exs` l.65 (`fc` stays open -> `fc` CLOSED
by this story). Partition / membership / visibility RULE tests must stay green unchanged.

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Migration `000054` applies and reverts on a throwaway PostgreSQL, on a fresh and on a populated schema
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Open Questions

**ANSWERED (orchestrator, 2026-10-26):** OQ1 split accepted (story 1 `events-room-position` ships and is committed first). OQ2 keep `cj` (b)
here (as recommended). OQ3 accept newest-N with `limited` and a real `/messages` `prev_batch`. OQ4 accept one cursor row per (device,
partition room) without a cap (deleted with the `sync_tokens` row by FK cascade). OQ5 yes, both stories in one release (one fallback).
OQ6 `cq` may be taken (keep the id line pattern `unused:[^.]*`gm` onward` intact).

- **OQ1 Split.** Accept the two-story split (story 1 `events-room-position` first, then this file)? The alternative, one story, is
  sizing XL (two migrations, write path and read path in one review).
- **OQ2 `cj` (b) in this story or later?** D8 adds four `sync_tokens` columns, three `prev_*` columns on the cursor rows and the base
  selection; it can be cut out into a story 3 without changing D2-D7 (the columns can stay unused). Recommendation: keep it here (the
  design is small once the cursor table exists, and the rollout fallback is paid only once).
- **OQ3 Newest-N for incremental timelines (D5)** changes what a busy room shows after a gap: clients see a `limited` timeline and fill
  the gap backwards (Element / matrix-js-sdk do this). Accept, or prefer "oldest-N with the cursor at the last delivered event" (rejected in
  D5)?
- **OQ4 Cursor storage (D3)**: one row per (device, partition room) without a separate cap. Accept, or cap the partition rooms per device
  and fall back above the cap?
- **OQ5 Release.** Every client does ONE full sync after the deploy (D6), as after sync-token-per-device. Acceptable to ship both
  stories in one release (then it is one fallback, not two)?
- **OQ6 New follow-up id.** Only `cq` is used (one row with lettered items). `cn` is also unused in the table but is named "reserved for the
  G3-2 story" in two story files; confirm `cq` may be taken (it is named "deliberately free ... next id of story
  client-ip-misconfiguration-warnings").
