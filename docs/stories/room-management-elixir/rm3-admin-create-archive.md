---
story_id: rm3-admin-create-archive
title: "Feature: Create a room and Archive/Unarchive rooms from the Admin UI"
type: feature
epic: room-management-elixir
status: ready-for-dev
security_review: required
created: 2026-06-21
branch: feature/room-management-elixir
---

## Summary

Elixir port + merge of the Go-era `admin-create-room` and `archive-room-fix` stories. The
core dispatcher already implements `create_room/2`, `archive_room/2`, and
`unarchive_room/2` (`Nebu.Matrix.EventDispatcher.Server`). The gap is purely the **Admin
LiveView UI**: `Nebu.Admin.RoomsLive` today only has a `toggle_auto_join` event — no way to
create a room, and no archive/unarchive controls. This mirrors what S5 already did for
Spaces (create/edit modal in `Nebu.Admin.SpacesLive`); apply the same pattern to rooms.

> Architecture note: no Go gateway, no `.html` templates, no `AdminCreateRoom` gRPC over
> the wire (ADR-021). The LiveView calls the in-process `Nebu.Matrix` public API directly,
> exactly like `SpacesLive` does. Use `Nebu.Matrix.create_room/2` (the same path the Matrix
> `POST /createRoom` and the Spaces create flow use) with the admin's `matrix_user_id`
> (already on `conn.assigns`/session via `Nebu.Admin.Auth`) as creator.

## Story

As an admin,
I want to create a new room and archive/unarchive rooms directly from the Admin UI,
so that I can manage the Nebu workspace without opening a Matrix client.

## Acceptance Criteria

**AC1 — "Create room" button + modal:**
The rooms list header shows a "Create room" button. Clicking it opens a DaisyUI modal with:
a required "Room name" text input (1–100 chars) and a "Visibility" select (private default /
public), plus "Create" and "Cancel".

**AC2 — Room created on submit:**
Submitting calls a `handle_event("create_room", …)` that invokes `Nebu.Matrix.create_room/2`
with the admin's `matrix_user_id` as creator, the name (→ `m.room.name`), and the chosen
visibility. The new room appears in the list and the admin is taken to its detail panel.

**AC3 — Create validation inline:**
Empty name → "Name is required"; name > 100 chars → "Name must be at most 100 characters".
Errors render in the modal without closing it; no crash.

**AC4 — New room: admin is creator + first member, audit logged:**
`m.room.create` + admin `m.room.member` join events exist; a `room_created` audit-log row
is written with the admin's `matrix_user_id` as actor.

**AC5 — Archive button + confirm:**
An active room's detail panel shows an "Archive room" control that opens a confirm dialog
naming the room. Confirming calls `handle_event("archive_room", …)` → `Nebu.Matrix`
archive delegate → `archive_room/2`; `rooms.status` becomes `'archived'`.

**AC6 — Archive works with no running GenServer:**
Archiving a stale room (0 members, no Room GenServer) still sets `status='archived'` in DB
(the dispatcher path is GenServer-independent). No silent failure.

**AC7 — Archived rooms: badge + Unarchive, success flash:**
After archiving, the panel shows the "Archived" badge, hides "Archive room", and shows an
"Unarchive" control (→ `unarchive_room/2`). A success flash ("Room archived" /
"Room unarchived") is shown via `put_flash`.

**AC8 — Non-existent room:**
Archiving a non-existent `room_id` shows an error flash ("Room not found"), never a 500/crash.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC2/AC4] ExUnit — create via Matrix path writes events + audit** —
   `core/test/nebu/admin/admin_create_room_test.exs`
   - Given an admin `matrix_user_id`
   - When the create path runs with name "General", visibility "public"
   - Then `m.room.create` + admin `m.room.member` join exist, `rooms.visibility='public'`,
     and an audit row `room_created` with the admin actor exists

2. **[AC6] ExUnit — archive a roomwith no running GenServer** —
   `core/test/nebu/admin/archive_room_no_genserver_test.exs`
   - Given a room row in DB with no started Room GenServer
   - When the archive path runs
   - Then `SELECT status FROM rooms` returns `'archived'`, returns `:ok`

3. **[AC1–AC3] Playwright+Gherkin — create room end-to-end** —
   `e2e/features/admin/create_room.feature` + steps
   - admin clicks "Create room", enters "My New Room"/private, submits → redirected to its
     detail panel; empty-name submit shows "Name is required" inline

4. **[AC5/AC7] Playwright+Gherkin — archive then unarchive** —
   `e2e/features/admin/archive_room.feature` + steps
   - archive an active room → "Room archived" flash + "Archived" badge + "Unarchive"
     visible; unarchive → back to active

## Technical Notes

- `Nebu.Matrix` public delegates if not already present: `create_room/2` exists; add
  `archive_room/2` / `unarchive_room/2` delegates if the LiveView can't already reach them
  through the public API (ADR-020 — never call `EventDispatcher.Server` internals from
  `Admin`).
- `core/lib/nebu/admin/rooms_live.ex`: add the create modal (copy the `SpacesLive` create
  modal shape), the `create_room`/`archive_room`/`unarchive_room` handlers, confirm dialog,
  flash messages, and the active-vs-archived footer (Archive button vs Archived badge +
  Unarchive). Reuse `Nebu.Admin.Auth` for the admin `matrix_user_id`.
- Audit: `create_room/2` should already audit; verify a `room_created` row is written
  (add it if missing, mirroring archive's audit write).
- No proto change; visibility on create reuses the existing `create_room` content path.
- Personal rooms must NOT be archivable — that guard is `rm5`; this story only needs the
  happy/normal-room path plus the not-found flash.
