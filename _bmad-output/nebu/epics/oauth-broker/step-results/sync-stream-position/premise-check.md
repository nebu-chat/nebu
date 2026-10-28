# Premise check: sync-stream-position (follow-up `fc`, with `cj` (b))

Worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `8c58dbd4`, read-only (2026-10-26). Line numbers are those of
this HEAD; `server.ex` = `server/lib/nebu/matrix/event_dispatcher/server.ex`, `db.ex` = `server/lib/nebu/matrix/room/db.ex`.

## 1. The since token today

- Core token `new_since_token/2` (server.ex 5390): `Base.encode64("<user_id>:<last_event_id>:<monotonic>")`. Never decoded by the
  server; it is compared for equality with `sync_tokens.since_token` of the request's key (`sync_delta/2`, server.ex 5889-5957,
  mismatch / no row -> `fallback_to_initial_sync/2` 5963). The user id is readable inside the base64 (not a secret, but needless).
- The anchor is `sync_tokens.last_event_id` (ONE event id). `resolve_since_ts/1` (server.ex 5566-5593) turns it into a timestamp once
  per request (`get_event_timestamp/1`, db.ex 745); `:not_found` -> fallback, other errors -> 503.
- The new anchor is `newest_event_id/2` (server.ex 5395) over `{origin_ts, event_id}` of everything delivered (join timelines, leave
  timelines, event-backed invites; server.ex 6023-6029): a GLOBAL maximum by `origin_server_ts` across all rooms.
- Room account data suffix: `next_batch = <core>.<pos>` (protected.ex 221), `split_since_token/1` (protected.ex 245) recognises ONE
  trailing `.` + digits; the core must therefore never contain `.` (base64 / base64url do not).
- D9 of sync-token-per-device: `sync_tokens.account_data_pos`, `cross_signing_pos` (migration 000052), advanced by the HTTP layer
  guarded by `since_token = <new core token>`; read once before the core call (protected.ex ~113).

## 2. How the delta reads events today (the loss mechanics)

- `fetch_delta_rooms/3` (server.ex 6159-6238) calls `visible_since!/4` (server.ex 3456) for EVERY joined room, quiet or not.
- `fetch_visible_events_since/4` (db.ex 2694) -> `since_anchor/1` (db.ex ~2704) runs `get_event_timestamp/1` AGAIN, per room (item (e)),
  then `read_visible_since/4` (db.ex 2716): `origin_server_ts > since_ts`, `ORDER BY origin_server_ts ASC, event_id ASC LIMIT 20`:
  the OLDEST 20. The legacy `fetch_events_since/3` (db.ex 643-690) does the same without visibility (unknown anchor -> 0).
- (a) The oldest 20 of room A plus a newer event of room B: the global anchor jumps to B's event; A's events 21.. have
  `ts <= anchor` and are never read again. `limited: true`, `prev_batch` = the OLDEST delivered event id (server.ex 6178): the gap is at
  the END, unreachable.
- (b) Writers stamp `origin_server_ts` before the INSERT commits; a reader can pass a newer timestamp of another room (or of the same
  room from another writer) while the older-stamped row is uncommitted -> lost.
- (c) `>` strict on the anchor's millisecond: a second event in the same ms committed after the read is skipped.
- (d) createRoom stamps its chain `max(now, previous + 1)` (up to ~70+ ms ahead, `eu` F-4); an invitee's anchor can be such an invite
  event (invite anchors, server.ex 5407): messages of the invitee's other rooms in that window are lost.
- (h) `left_at` / `joined_at` (room_members, db.ex 1705 `@sql_membership_candidates`) come from the member writer's node clock.

## 3. Event writers (who INSERTs into `events`)

Single statement `@sql_insert_event` (db.ex 592), `insert_event/1` (db.ex 608), autocommit unless the caller is in a transaction.
Callers:

| Writer | Where | Transaction / lock today |
|---|---|---|
| message `/send` | `Room.Server.sign_and_persist_event/6` (room/server.ex 1603) | autocommit; archived check via `check_room_status_for_update/1` (db.ex 942, separate tx, `FOR UPDATE`, on cache miss only) |
| own join / leave | `Room.Server.emit_membership_event/4` (room/server.ex 1109) | autocommit, after the member row write (fail-open) |
| kick / ban / unban / invite event / decline (room process) | `apply_member_change/4` (db.ex 1852) | tx, `lock_timeout 1s`, rooms row `FOR SHARE` (`refuse_archived_room/1`, db.ex 1886/1900), event inserted LAST |
| power levels | `apply_power_levels_change/3` (db.ex 440) | tx, rooms row `FOR NO KEY UPDATE` (db.ex 1890) |
| redaction, generic state | `apply_redaction/2`, `apply_state_change/3` via `room_write_transaction/2` (db.ex 482-522) | tx, rooms row `FOR NO KEY UPDATE` |
| `m.room.create` | `EventDispatcher.Server` create_room (server.ex 516) | autocommit, OUTSIDE the room process |
| createRoom initial state / preset / upgrade copies | `emit_state_event_at/6` (server.ex 9021, insert 9048) | autocommit, outside the room process |
| personal room | `create_personal_room/2` (server.ex 7065, insert 7096) | autocommit, outside the room process |
| archived-room decline | `emit_decline_event/2` (server.ex 8024, insert 8041) | autocommit, outside the room process |
| historic backfill | migration 000035 | one-off |

Conclusion: the room process is NOT the single writer (four direct writers in `EventDispatcher.Server`, and two room processes can
exist briefly during a Horde handover). Only a DATABASE-level per-room serialisation covers all of them. The `rooms` row already is
the per-room lock object of three writers (`FOR NO KEY UPDATE`) and of the archive path (`FOR UPDATE`).

Deletes: only `@sql_delete_events_for_room` (db.ex 80, the failed-createRoom cleanup, whole room). No `UPDATE events` anywhere.

## 4. Schema

- `events` (000001 l.211): `event_id TEXT PK`, `room_id REFERENCES rooms`, `origin_server_ts BIGINT`, JSONB content, signatures,
  `state_key`, `search_vector`, `redacts` (000051). Indexes: `events_room_id_ts_idx (room_id, origin_server_ts)`,
  `events_room_state_idx`, `events_content_gin_idx` (000031), `events_redacts_idx` (000051). The largest table.
- `rooms` (000001 l.162): no counter column today.
- `sync_tokens`: `(user_id, device_id)` PK, `since_token`, `last_event_id`, `updated_at`, plus `account_data_pos`,
  `cross_signing_pos` (000052). No RLS.
- Last migration: `000052_sync_device_positions` -> next free numbers `000053`, `000054`.
- 000051 / 000052 operator notes: in-transaction DDL on `events` holds ACCESS EXCLUSIVE for the whole index build; pre-create
  `CONCURRENTLY` by hand or use a maintenance window; 000052 forbade a mixed-version window (old nodes are not correct writers).

## 5. Partition, leaves, invites (story sync-membership-partition)

- `sync_partition/1` (server.ex 5420): candidates + the two latest member events per room (`@sql_latest_member_events`, db.ex 1755,
  `ORDER BY origin_server_ts DESC, rank, event_id DESC`), forgotten set, ignore list. Classes join / invite / leave / none.
- `consistent_delivery/4` (server.ex 5258): the partition is re-read after the fetch; justified by "the anchor is a GLOBAL maximum, a
  leave passed undelivered is lost for good".
- `invite_new?/2` (server.ex 5598): event-backed by `ts > since_ts`, row-only by `invited_at > since_ts` (repeats until the anchor
  passes it). `leave_new?/2` (5602): `L.ts > since_ts`.
- `build_leave_room/3` (server.ex 5789): window `(max(since_ts, P.ts, joined_at), min(L.ts, left_at))` by timestamps
  (`window_start/2`, `window_end/1`, 5852-5857; `leave_window_events/3`, db.ex 2469-2490, newest 20); `prev_batch` = oldest event id
  (5812), same defect as the join rooms.
- D5 of sync-wakeups-cluster-wide: an unresolved room keeps the PREVIOUS global anchor (server.ex 6026): with a global anchor this pins
  every room (`bp`).

## 6. `/messages` tokens and `prev_batch`

- `/messages` tokens are `v1_` + base64url(`<ts>:<event_id>`) (`encode_token/2`, `decode_token/1`, db.ex 850-880); a non-`v1_` token
  decodes to `:empty`, so `/messages?from=<event id>` returns the NEWEST page: the incremental `prev_batch` (an event id) is not a
  valid `/messages` token (pre-existing, recorded on `fc`). The initial sync's `prev_batch` comes from `visible_page!/6` (server.ex 3439)
  and is a real `v1_` token.
- Spec (CS v1.18, `/sync`, Timeline): `limited` "True if the number of events returned was limited by the limit on the filter";
  `prev_batch` "A token that can be supplied to the `from` parameter of the `/rooms/{roomId}/messages` endpoint in order to retrieve
  earlier events". The client model is: a limited timeline = the most recent events, the gap BEFORE them is filled backwards from
  `prev_batch`.

## 7. Wake-ups

`wait_loop/2` (server.ex 6112) wakes on `{:new_event, _}` of a join room / own member event, `{:new_invite}`, `{:new_join}`,
`{:new_leave}`, `{:account_data_changed, _}`; all senders cluster-wide (`fe` closed). A wake triggers a full rebuild
(`consistent_delivery(user_id, nil, build)`, server.ex 6012). Unaffected by the position model (a wake only says "look again").

## 8. HTTP layer details

- `finish_sync/6` (protected.ex 182): `newly_joined_room_ids/2` (protected.ex 258) detects a newly joined room by the user's join EVENT
  in the timeline; with a newest-N timeline the join can fall outside it -> the room's account data would not be sent in full.
- `GetSyncDeltaResponse` (proto/core.proto 505-512) has no "newly joined" field.

## 9. Tests that pin the timestamp model (deliberate amendments needed by the read story)

Counted by `grep` (get_event_timestamp / fetch_events_since / fetch_visible_events_since / last_event_id / leave_window_events /
prev_batch): `event_dispatcher/sync_test.exs` (12 / 11 / 0 / 52 / 4 / 11), `event_dispatcher/sync_membership_partition_test.exs`
(6 / 5 / 0 / 13 / 5 / 5, incl. the `D5 - ...` anchor-pin tests), `event_dispatcher/server_dedup_test.exs`,
`sync_wakeups_cluster_test.exs`, `sync_membership_partition_http_test.exs` (L-2 anchor test, prev_batch), `sync_token_per_device_http_test.exs`
(7 x last_event_id, "never an empty anchor"), `sync_token_per_device_dispatcher_test.exs`, `session/pg_store_test.exs` (20),
`session/session_supervisor_test.exs` (8), `history_visibility_http_test.exs` (incremental statement count 51, prev_batch),
`history_visibility_unit_test.exs` / `history_visibility_test_support.exs` / `history_visibility_security_cycle1_test.exs` /
`room/history_visibility_db_test.exs` (`fetch_visible_events_since/4`), `room/membership_partition_db_test.exs` (8 x
`leave_window_events`), `membership_state_http_test.exs`, `member_prev_content_http_test.exs` (initial sync 57 statements),
`matrix_client_compat_test.exs`, `migration/000052_sync_device_positions_test.exs`. Fake DB modules in ~15 dispatcher test files
implement `get_event_timestamp/1` / `fetch_events_since/3` only as `DBBehaviour` callbacks (unaffected unless they run a delta).
Docs suites: `sync_token_per_device_docs_test.exs` l.65 pins `fc` OPEN (must be re-pinned when `fc` closes);
`sync_membership_partition_docs_test.exs` l.120, `member_prev_content_docs_test.exs` l.131, `moderation_routes_docs_test.exs` l.411,
`membership_state_model_docs_test.exs` l.480, `history_visibility_docs_test.exs` l.372/385 pin tokens INSIDE the `fc` row (kept by
the "CLOSED ... Original item" pattern). Eight+ suites pin `unused:[^.]*`gm` onward`.

## 10. Follow-up ids

Ids present in the table: 187. Unused two-letter ids below `gm`: `ak` (a label), `bm bn bo bv bw` (reserved for the backlog story),
`cn` (named "reserved for the G3-2 story" in consent-arming-hardening.md l.151 / legacy-sso-redirect-confirmation.md l.1159) and `cq`
("deliberately left free: the next id of story client-ip-misconfiguration-warnings"; the orchestrator allows it). Only `cq` is used.
`eu` does NOT name `fc` (it is linked through `fc` (d)); `gg`, `gk` and `cj` (b) name `fc`.
