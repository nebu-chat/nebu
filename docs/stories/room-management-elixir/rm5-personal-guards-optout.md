---
story_id: rm5-personal-guards-optout
title: "Security+Fix: Personal-room leave/archive guards + auto-join opt-out (rooms stay gone after leave)"
type: security
severity: high
epic: room-management-elixir
status: ready-for-dev
security_review: required
created: 2026-06-21
branch: feature/room-management-elixir
---

## Summary

Elixir port + merge of the Go-era `leave-event-sync-fix` and `personal-room-archive-guard`
stories. The current stack already has personal rooms (`ensure_personal_room/1`,
`create_personal_room/2`, `messages_db_module().get_personal_room_id/1`) and auto-join
(`ensure_auto_join_memberships/1`, `ensure_auto_join_space_memberships/1`), but it is
missing three protections:

1. **No personal-room leave guard** — `leave_room/2` lets a user leave their own personal
   self-room.
2. **No personal-room archive guard** — `archive_room/2` lets an admin archive any user's
   personal room by calling the path directly (UI-only hiding is not enough — SEC finding).
3. **No auto-join opt-out** — leaving an `is_auto_join` room (or auto-join space) re-joins
   the user on the next login/sync via `ensure_auto_join_memberships`, so the room
   "reappears" and feels stale/unleavable.

## Story

As a security control and a Matrix user,
I want personal rooms protected from leave/archive and left auto-join rooms to stay gone,
so that users keep their personal anchor and their room list reflects reality.

## Acceptance Criteria

**AC1 — Personal-room leave returns 403 `M_FORBIDDEN`:**
`leave_room/2` (and thus `POST /_matrix/client/v3/rooms/{personalRoomId}/leave`) for a
`room_id` equal to the requesting user's `personal_room_id` raises `GRPC.RPCError`
`permission_denied` → HTTP 403 `M_FORBIDDEN`, message mentions "personal room". The
membership is unchanged.

**AC2 — Personal-room archive rejected server-side:**
`archive_room/2` for a `room_id` matching ANY user's `personal_room_id` returns
`{:error, :personal_room}` / raises `GRPC.RPCError permission_denied`. `rooms.status` stays
`'active'`. Holds even when the request bypasses the Admin UI guard.

**AC3 — `auto_join_opt_outs` table:**
A new migration creates `auto_join_opt_outs (room_id TEXT NOT NULL REFERENCES rooms(room_id),
user_id TEXT NOT NULL, opted_out_at BIGINT NOT NULL, PRIMARY KEY (room_id, user_id))`. Up +
down SQL, numbered next in `core/priv/migrations/`.

**AC4 — Leaving an auto-join room records an opt-out:**
When `leave_room/2` succeeds for a room with `is_auto_join = true` (or an auto-join space),
a row is inserted into `auto_join_opt_outs` for `(room_id, user_id)` (idempotent upsert).

**AC5 — Opt-out suppresses re-join:**
`ensure_auto_join_memberships/1` and `ensure_auto_join_space_memberships/1` skip any
`(room_id, user_id)` present in `auto_join_opt_outs`. After leaving, the next login/initial
sync does NOT re-add the room; it is absent from `rooms.join`.

**AC6 — No regression for normal rooms:**
Leaving a normal (non-personal, non-auto-join) room behaves exactly as before. Archiving a
normal room still works (`rm3` regression). Joining an auto-join room a user has NOT opted
out of still happens on login.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1] ExUnit — leave personal room raises permission_denied** —
   `core/test/nebu/matrix/event_dispatcher/leave_personal_room_guard_test.exs`
   - Given a user whose `personal_room_id = "!p:<server>"`
   - When `leave_room` is called for that room by that user
   - Then it raises `GRPC.RPCError` `permission_denied` and membership is unchanged

2. **[AC2/AC6] ExUnit — archive personal room rejected; normal room ok** —
   `core/test/nebu/matrix/event_dispatcher/personal_room_archive_guard_test.exs`
   - personal room → `archive_room` rejected, status stays `'active'`
   - non-personal room → archive succeeds, status `'archived'`

3. **[AC4/AC5] ExUnit — leave auto-join writes opt-out + suppresses re-join** —
   `core/test/nebu/matrix/event_dispatcher/auto_join_opt_out_test.exs`
   - Given an `is_auto_join` room with the user a member
   - When `leave_room` succeeds → an `auto_join_opt_outs` row exists for `(room_id,user_id)`
   - And `ensure_auto_join_memberships(user_id)` does NOT re-add the room

4. **[AC1/AC5] Playwright+Gherkin (or integration) — left auto-join room stays gone** —
   `e2e/features/matrix/leave_auto_join.feature` (or an `:integration` ExUnit driving
   `/leave` then initial `/sync`) — after leaving, the room is absent from `rooms.join` on
   the next sync.

## Technical Notes

- **Personal-room helpers:** reuse `messages_db_module().get_personal_room_id/1` for the
  leave guard (compare to the request's `room_id`). For the archive guard add
  `Nebu.Admin.DB.get_personal_room_owner(room_id)` →
  `SELECT user_id FROM users WHERE personal_room_id = $1` returning `{:ok, uid} | {:error, :not_found}`,
  and reject in `archive_room/2` when it matches (mirrors the leave guard).
- **Migration:** `core/priv/migrations/NNNNNN_auto_join_opt_outs.up.sql` (+ `.down.sql`).
  Use the next free number after the spaces migrations (000004/000005 already used →
  000006). golang-migrate-compatible.
- **Opt-out write:** in `leave_room/2`, after a successful leave, if the room is auto-join
  (`rooms.is_auto_join = true` / auto-join space), `INSERT … ON CONFLICT DO NOTHING` into
  `auto_join_opt_outs` with `opted_out_at`. Add `Nebu.Matrix.Room.DB` helpers
  `insert_auto_join_opt_out/2` and `opted_out?/2` (or `list_opt_outs/1`).
- **Skip on re-join:** in `ensure_auto_join_memberships/1` and
  `ensure_auto_join_space_memberships/1`, filter out rooms/spaces the user has opted out of
  before joining.
- **403 mapping:** confirm the `leave_room` HTTP path maps `permission_denied` →
  403 `M_FORBIDDEN` (same as the restricted-join path from Spaces S4).
- Default-deny / parameterised SQL throughout (ADR-018). No raw interpolation.
