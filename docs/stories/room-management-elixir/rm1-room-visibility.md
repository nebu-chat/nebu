---
story_id: rm1-room-visibility
title: "Feature: Change a room's visibility (public/private) from the Admin UI"
type: feature
epic: room-management-elixir
status: ready-for-dev
security_review: required
created: 2026-06-21
branch: feature/room-management-elixir
---

## Summary

Elixir port of the Go-era `admin-room-visibility` story. The Admin UI room detail
panel (`Nebu.Admin.RoomsLive`) shows a room's visibility as read-only text. There is no
way to change it. The in-process gRPC DTO `Core.UpdateRoomSettingsRequest` has
`max_members` and `is_auto_join` but **no `visibility` field**, and
`Nebu.Matrix.EventDispatcher.Server.update_room_settings/2` never touches the
`rooms.visibility` column.

**Desired UX:** the room detail settings form gets a DaisyUI `<select>` (or radio) for
visibility (private ↔ public), saved alongside `max_members` / `is_auto_join`.

> Architecture note (ADR-021): the Go gateway is gone. The Admin UI is Phoenix LiveView
> (`core/lib/nebu/admin/rooms_live.ex`) calling the in-process `Nebu.Matrix` public API
> (ADR-020). There is no `gateway/` package, no `.html` template, and no Godog. Replace
> every Go/template/Godog reference in the original story with LiveView + ExUnit +
> Playwright/Gherkin.

## Story

As an admin,
I want to change a room's visibility between public and private from the Admin UI,
so that I can control whether the room is discoverable in the public room directory.

## Acceptance Criteria

**AC1 — Visibility control in the detail/settings form:**
The room detail panel in `RoomsLive` shows a `<select name="visibility">` (or two radios)
with options "Private" and "Public". The room's current `visibility` is pre-selected.

**AC2 — Saving updates `rooms.visibility` in DB:**
Submitting the settings form (a `phx-submit`/`handle_event` such as
`"save_room_settings"`) routes the new visibility through `Nebu.Matrix.update_room_settings/…`
(or a dedicated `Nebu.Matrix` delegate) → `update_room_settings/2`, which calls
`admin_db_module().update_room_visibility(room_id, visibility)`.

**AC3 — Detail panel reflects the updated visibility immediately:**
After the LiveView event completes, the panel shows the new visibility (re-read from DB
or via `assign`), without a manual full-page reload.

**AC4 — DTO field added for visibility:**
`Core.UpdateRoomSettingsRequest` gains `string visibility = 4;` (`"public"` | `"private"`
| `""` = no change). Regenerate via the project's flat-file proto convention (mirror how
`room_type`/space fields were added — minimal edit to `core/lib/pb/core.pb.ex`, no spurious
nested dir).

**AC5 — Empty/invalid visibility = no change:**
If `visibility == ""` (legacy callers) **or** not one of `"public"`/`"private"`, the core
does NOT update the column. Invalid values from the form are rejected server-side
(default-deny) — never written to the DB.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC2/AC5] ExUnit — `update_room_settings/2` visibility paths** —
   `core/test/nebu/matrix/event_dispatcher/update_room_settings_visibility_test.exs`
   - Given a room with `visibility = "private"`
   - When `update_room_settings(%Core.UpdateRoomSettingsRequest{room_id: id, visibility: "public", max_members: 0})`
   - Then `admin_db_module().update_room_visibility/2` is invoked with `(id, "public")`
   - And with `visibility: ""` → `update_room_visibility` is NOT called
   - And with `visibility: "bogus"` → NOT called (rejected), function still returns ok for the rest

2. **[AC2] ExUnit — `Nebu.Admin.DB.update_room_visibility/2` writes the column** (live-DB `:integration`)
   - Given a seeded room with `visibility='private'`
   - When `update_room_visibility(room_id, "public")`
   - Then `SELECT visibility FROM rooms WHERE room_id=$1` returns `'public'`

3. **[AC1/AC3] Playwright+Gherkin — admin flips visibility** —
   `e2e/features/admin/room_visibility.feature` + steps
   - Given the admin is on a private room's detail panel
   - When they select "Public" and save
   - Then the panel shows visibility "Public" and the DB column is `'public'`

## Technical Notes

- `proto/core.proto`: add `string visibility = 4;` to `UpdateRoomSettingsRequest`; apply
  the established flat-file regen pattern to `core/lib/pb/core.pb.ex`.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` `update_room_settings/2`: after the
  `is_auto_join` block, add — `if req.visibility in ["public","private"], do: admin_db_module().update_room_visibility(room_id, req.visibility)`.
  Emit an audit-log row (`room_visibility_changed`, actor_id) mirroring the existing
  `room_auto_join_changed` audit write.
- `core/lib/nebu/admin/db.ex`: add `update_room_visibility/2` —
  `UPDATE rooms SET visibility = $2 WHERE room_id = $1 AND visibility != $2` (parameterised,
  ADR-018). Add to the DB behaviour if one is used for `admin_db_module()`.
- `core/lib/nebu/admin/rooms_live.ex`: add the visibility `<select>` to the detail form and
  a `handle_event` that calls the `Nebu.Matrix` delegate, then re-assigns the room.
- The `rooms.visibility` column + `rooms_visibility_check` CHECK already exist
  (`000001_init.up.sql`) — no migration needed.
