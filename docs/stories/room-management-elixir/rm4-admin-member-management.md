---
story_id: rm4-admin-member-management
title: "Feature: Add and remove room members from the Admin UI"
type: feature
epic: room-management-elixir
status: ready-for-dev
security_review: required
created: 2026-06-21
branch: feature/room-management-elixir
---

## Summary

Elixir port of the Go-era `admin-member-management` story. The Admin room detail panel
lists members read-only. Admins cannot add or remove members. The core already has join
(`join_room/2`) and leave (`leave_room/2`) in `Nebu.Matrix.EventDispatcher.Server`; the gap
is the Admin LiveView UI + thin admin-initiated add/remove path that emits the membership
events on behalf of the target user with the admin as actor.

> Architecture note: no Go gateway / Godog (ADR-021). LiveView calls the `Nebu.Matrix`
> public API. Admin-initiated membership must emit proper `m.room.member` events and update
> `room_members` (the same write path join/leave use), not a DB-only shortcut.

## Story

As an admin,
I want to add and remove users from a room directly in the Admin UI,
so that I can manage room membership without opening a Matrix client.

## Acceptance Criteria

**AC1 — Add-member control:**
The member section of the detail panel has an "Add user…" text input (Matrix user_id) and
an "Add" button.

**AC2 — Adding joins the user:**
`handle_event("add_member", …)` calls a `Nebu.Matrix` admin-add delegate that emits an
`m.room.member` join for the target user and upserts `room_members` (`left_at = NULL`). The
user appears in the member list after the LiveView re-render.

**AC3 — Remove control + confirm:**
Each member row has a "Remove" button → confirm dialog "Remove {user} from {room}?".

**AC4 — Removing leaves the user:**
Confirming calls `handle_event("remove_member", …)` → admin-remove delegate → `m.room.member`
leave event, `room_members.left_at` set; the user disappears from the list.

**AC5 — User-not-found inline error:**
Adding an unknown/invalid `user_id` re-renders with "User not found: {user_id}" (or
"Invalid user id"); no crash.

**AC6 — Admin cannot remove themselves:**
When a member row's `user_id == ` the logged-in admin's `matrix_user_id`, the "Remove"
button is absent/disabled (and the server-side handler rejects self-removal defensively).

**AC7 — Audit entries:**
Add → `member_added`; remove → `member_removed`, each with `actor_id` = admin
`matrix_user_id`.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC2/AC4/AC7] ExUnit — admin add then remove emits events + audit** —
   `core/test/nebu/admin/admin_member_management_test.exs`
   - Given a room with one member
   - When the admin-add path runs for `@charlie:<server>`
   - Then an `m.room.member` join event exists and `room_members.left_at IS NULL`, plus a
     `member_added` audit row with the admin actor
   - And when the admin-remove path runs → `m.room.member` leave exists, `left_at IS NOT NULL`,
     `member_removed` audit row

2. **[AC6] ExUnit — self-removal rejected**
   - When the admin-remove path is called with `user_id == actor_id` → returns an error /
     no-op; the admin's `left_at` stays `NULL`

3. **[AC2/AC4] Playwright+Gherkin — add then remove a member** —
   `e2e/features/admin/member_management.feature` + steps
   - add `@charlie` via the input → appears in list; remove `@bob` + confirm → disappears

## Technical Notes

- `Nebu.Matrix`: add admin-scoped delegates, e.g. `admin_add_room_member(room_id, user_id, actor_id)`
  and `admin_remove_room_member(room_id, user_id, actor_id)`, wrapping the existing join/leave
  write path (start the Room GenServer on demand if needed, matching the existing pattern).
  Both write an audit-log row. ADR-020: `Admin` calls only `Nebu.Matrix`.
- Self-removal guard in the remove delegate (defence-in-depth; UI also hides the button).
- `user_id` validation: reject malformed ids (no `@`/`:` shape) → AC5 error, before any DB
  write. Prefer validating the localpart/domain the same way `Nebu.Matrix.UserId` does.
- `core/lib/nebu/admin/rooms_live.ex`: add the add-member form, per-row remove button +
  confirm dialog, inline error assign, and the two handlers. Re-fetch members after each op.
- No proto change, no migration.
