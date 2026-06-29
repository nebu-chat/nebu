---
story_id: bugfix-forget-room-membership-purge
title: "Bug: POST /rooms/{id}/forget is a no-op stub — forgotten rooms still appear in /sync"
type: bug
severity: medium
epic: forget-room-membership-purge
status: done
security_review: required
created: 2026-06-28
branch: feature/device-management
---

## Summary

`POST /_matrix/client/v3/rooms/{roomId}/forget` (`forget_room/2` in
`Nebu.Matrix.EventDispatcher.Server`, `server/lib/nebu/matrix/event_dispatcher/server.ex:3423`)
is an MVP stub. It correctly verifies the room exists and rejects forgetting a room the
caller is still joined to (`M_BAD_STATE`), but on success it returns an empty
`%Core.ForgetRoomResponse{}` **without persisting anything**. The Matrix spec says a
forgotten room must be purged from the user's view and excluded from future `/sync`
responses — Nebu does neither, so a left-then-forgotten room keeps reappearing in the
`leave` section of every incremental sync.

The backing table **already exists** — `forgotten_rooms (user_id, room_id, forgotten_at_ms)`
in `server/priv/migrations/000001_init.up.sql` — but is never written to or read from
anywhere in the codebase. This story wires it up. **No new migration is required.**

This is NOT a go-removal regression (the HTTP route was already restored in
`fix-missing-matrix-room-routes`); it is an unfinished MVP behavior. The stub's own comment
acknowledges it: *"In MVP, forget is a no-op beyond the FailedPrecondition check because
GetSyncDelta does not yet filter forgotten rooms. A follow-up story will add ..."*. This is
that follow-up story.

## Story

As a Matrix client user who has left a room,
I want to forget the room so it disappears from my client and never comes back in sync,
so that my room list reflects only rooms I currently care about.

## Root Cause Analysis

`forget_room/2` performs the join-state guard and returns success, but:
1. It never records the forget in `forgotten_rooms`.
2. The two sync builders — `get_initial_sync` (`server.ex:~2253`, via
   `Room.DB.get_rooms_for_user/1`) and `do_incremental_sync` (`server.ex:~2469`, via
   `get_rooms_for_user/1` + `get_recently_left_rooms_for_user/1`) — have no notion of
   forgotten rooms, so a soft-deleted (`left_at IS NOT NULL`) membership keeps surfacing
   in the `leave` block of every delta sync indefinitely.

Membership itself is persisted as a soft-delete: `Room.DB.delete_member/2`
(`server/lib/nebu/matrix/room/db.ex:~209`) sets `room_members.left_at` and emits an
`m.room.member` `leave` event. Forget is orthogonal to that membership row — it is a
per-user preference recorded in `forgotten_rooms`.

## Acceptance Criteria

**AC1 — Forget persists (after leave):** After the caller has left a room,
`POST /_matrix/client/v3/rooms/{roomId}/forget` inserts `(user_id, room_id)` into
`forgotten_rooms` (idempotent: `ON CONFLICT (user_id, room_id) DO NOTHING`) and returns
`200 {}`.

**AC2 — Join-guard unchanged (regression):** Forgetting a room the caller is still joined
to still returns `400 M_BAD_STATE` and writes **nothing** to `forgotten_rooms`. Forgetting a
non-existent room still returns the room-not-found error. (Existing tests in
`matrix_room_routes_test.exs` must stay green.)

**AC3 — Excluded from initial /sync:** A forgotten room does not appear in any section
(`join` / `invite` / `leave`) of a fresh full `/sync` for that user.

**AC4 — Excluded from incremental /sync:** A forgotten room does not appear in the `leave`
(or any) section of incremental `/sync` responses — including the
`get_recently_left_rooms_for_user` path that currently re-surfaces left rooms.

**AC5 — Per-user isolation:** Forgetting a room for user A does not exclude that room from
user B's sync. (`forgotten_rooms` is keyed by `(user_id, room_id)`.)

**AC6 — Re-join clears forget:** If the user re-joins a forgotten room
(`POST /rooms/{id}/join`), the `(user_id, room_id)` row is removed from `forgotten_rooms`
so the room reappears in sync. (Matrix: a forgotten room that you re-join is no longer
forgotten.)

**AC7 — Auth:** `POST .../forget` without a Bearer token returns `401` (OidcPlug) — unchanged.

## Persistence Strategy

**Option B — PostgreSQL (persistent).** Forgotten state lives in the existing
`forgotten_rooms` table, read fresh on every sync. There is **no GenServer state** involved
(forget is a DB write + a sync-time read), so no Horde crash/restart migration test is
required. Instead, AC3/AC4 are proven across a server-independent path: the test forgets a
room, then issues a brand-new sync (fresh query) and asserts exclusion — demonstrating the
state is durable in PostgreSQL, not held in volatile memory.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **forget-after-leave persists + 200** — ExUnit `:integration` (`server/test/nebu/matrix/`)
   - Given: user has created+left a room (`left_at IS NOT NULL`)
   - When: `POST /_matrix/client/v3/rooms/{id}/forget`
   - Then: `200 {}` and `SELECT 1 FROM forgotten_rooms WHERE user_id=$1 AND room_id=$2` returns a row

2. **forget-while-joined → M_BAD_STATE, no write** — ExUnit `:integration` (regression)
   - Given: user is still joined
   - When: `POST .../forget`
   - Then: `400 M_BAD_STATE` and `forgotten_rooms` has no row for that pair

3. **forgotten room excluded from initial sync** — ExUnit `:integration`
   - Given: user left+forgot room R
   - When: full `/sync`
   - Then: R absent from `rooms.join`, `rooms.invite`, `rooms.leave`

4. **forgotten room excluded from incremental sync** — ExUnit `:integration`
   - Given: user left+forgot room R; a `since` token exists
   - When: incremental `/sync?since=...`
   - Then: R absent from `rooms.leave` (the path that currently re-surfaces it)

5. **per-user isolation** — ExUnit `:integration`
   - Given: user A forgot room R; user B is a member of R
   - When: user B `/sync`
   - Then: R still present for B

6. **re-join clears forget** — ExUnit `:integration`
   - Given: user left+forgot room R
   - When: user re-joins R, then `/sync`
   - Then: R present again in `rooms.join`; `forgotten_rooms` row for (user, R) is gone

7. **idempotent forget** — ExUnit unit/integration
   - Given: room already forgotten
   - When: `POST .../forget` again
   - Then: `200 {}`, still exactly one `forgotten_rooms` row (ON CONFLICT DO NOTHING)

## Implementation Notes (non-binding map)

- `Room.DB` (`server/lib/nebu/matrix/room/db.ex`): add
  `insert_forgotten_room(user_id, room_id)` (`INSERT ... ON CONFLICT DO NOTHING`),
  `get_forgotten_room_ids(user_id)` (`SELECT room_id FROM forgotten_rooms WHERE user_id=$1`),
  and `remove_forgotten_room(user_id, room_id)` (`DELETE ...`). All parameter-bound (ADR-018).
- `forget_room/2` (`server.ex:3443`): after the join-guard passes, call
  `insert_forgotten_room`.
- `get_initial_sync` + `do_incremental_sync`: fetch `get_forgotten_room_ids(user_id)` once,
  `MapSet`-reject those room_ids from the room list (and from the recently-left list).
  Prefer in-process filtering over a SQL `LEFT JOIN` to keep the existing query shapes
  unchanged and the diff minimal.
- Join handler (`Room.Server` `handle_call({:join, ...})` / wherever `insert_member`
  succeeds): call `remove_forgotten_room(user_id, room_id)` so AC6 holds.

## Security Review Scope

`security_review: required` — touches `:integration` HTTP paths and adds SQL against a
PII-adjacent table. Check: SQL injection (all queries parameter-bound), per-user
authorization (a user can only forget/unforget their own membership — `user_id` comes from
the validated token, never the request body), and no IDOR (forgetting room R for the
caller must not leak whether R exists to a non-member beyond the existing not_found
behavior).
