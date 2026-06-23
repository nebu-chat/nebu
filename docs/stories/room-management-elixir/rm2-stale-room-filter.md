---
story_id: rm2-stale-room-filter
title: "Feature: Filter and badge stale rooms (0 active members) in the Admin UI"
type: feature
epic: room-management-elixir
status: ready-for-dev
security_review: not-needed
created: 2026-06-21
branch: feature/room-management-elixir
---

## Summary

Elixir port of the Go-era `admin-stale-room-filter` story. Rooms where every member has
left (`member_count = 0`) but `status = 'active'` linger in the Admin list with a green
"Active" badge and create noise. There is no way to filter for them.

**Definition of "stale":** `status = 'active'` AND 0 members with `left_at IS NULL`.

**Desired UX:** the rooms list status filter offers "All / Active / Archived / Stale";
selecting "Stale" lists only stale rooms; stale rooms render a warning "Stale" badge in
both the list and the detail panel.

> Architecture note: LiveView + `Nebu.Admin.DB`, no Go/Godog (ADR-021). The list filter is
> a LiveView `handle_event`/`handle_params`, not an HTTP query param handler.

## Story

As an admin,
I want to filter the room list by "stale" (0 members, not archived),
so that I can identify and clean up abandoned rooms efficiently.

## Acceptance Criteria

**AC1 — Status filter includes "Stale":**
`RoomsLive` exposes a status filter with values `all | active | archived | stale`.
Selecting "Stale" shows only rooms where `status='active' AND member_count=0`.

**AC2 — Stale badge:**
In the list, a stale room renders a `badge-warning` "Stale" (instead of `badge-success`
"Active"); `badge-ghost` "Archived" for archived. The detail panel status reads "Stale".
The effective badge is computed server-side (in the row→map function), not in the template.

**AC3 — Filter applied in SQL, server-side:**
`Nebu.Admin.DB.list_rooms/4` handles `status_filter == "stale"` with
`WHERE status='active' AND (SELECT COUNT(*) FROM room_members m WHERE m.room_id=r.room_id AND m.left_at IS NULL)=0`.
No client-side filtering. Unknown filter values fall back to "all" (or are rejected) — no
SQL injection (filter value never interpolated; mapped to a fixed clause).

**AC4 — Stale rooms remain archivable:**
A stale room can still be archived from the detail panel (see `rm3`). After archiving it
leaves the "Stale" view.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC3] ExUnit (`:integration`) — `list_rooms` stale subset** —
   `core/test/nebu/admin/admin_stale_rooms_test.exs`
   - Given 3 rooms: active+1member, active+0members, archived+0members
   - When `Nebu.Admin.DB.list_rooms(50, "", "stale", "")`
   - Then exactly the active+0members room is returned

2. **[AC2] ExUnit — row→map computes effective "stale" status**
   - Given a row with `status="active"`, `member_count=0`
   - Then the mapped struct's badge/status field is `"stale"` (and `"active"` when member_count>0)

3. **[AC1/AC2] Playwright+Gherkin — stale filter + badge** —
   `e2e/features/admin/stale_rooms.feature` + steps
   - Given an active room with 0 members exists
   - When the admin selects the "Stale" filter
   - Then only that room is listed, showing a "Stale" badge

## Technical Notes

- `core/lib/nebu/admin/db.ex` `list_rooms/4`: add a `"stale"` branch to the
  `status_filter` case with the correlated-subquery `= 0` predicate; map the filter value
  to a fixed WHERE fragment (never string-interpolate it). Existing `member_count`
  subquery can be reused.
- Row→map: set effective status `"stale"` when `status=="active" and member_count==0`.
- `core/lib/nebu/admin/rooms_live.ex`: add the status filter control (a `<form phx-change>`
  select or filter links) and the badge rendering helper. Keep the badge in the list row
  even when a room is selected.
- No proto change, no migration.
