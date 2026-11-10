---
story: admin-rooms-fallback-name
epic: bugfix
status: done
security_review: required
matrix: false
ui: true
---

# Bugfix — Admin rooms pages show the raw room_id for rooms without a name (follow-up G of the flake triage)

Follow-up G of the `oauth-pages-redesign` flake triage. The red ATDD suite `server/test/nebu/admin/admin_rooms_fallback_name_test.exs` (bugfix
`admin-rooms-fallback-name`, added in 314d8829) never got its implementation: the former Go gateway rendered a fallback name for unnamed rooms
(cb4c0e89, story 9-15), the Elixir admin did not port it.

## Problem

`Nebu.Admin.RoomsHTML.room_display_name/1` returns the raw `room_id` (`!15a233d26eaa6557:localhost`) for every room whose `name` is blank. Most rooms (direct
chats, rooms created without a name) have none, so the rooms index and the detail page are a list of opaque ids.

## Acceptance criteria

```gherkin
Scenario: AC1 two members with display names
  Given an unnamed room with the joined members "Alice" and "Bob" (profiles.displayname)
  When an admin opens the rooms index or the room detail page
  Then the room is shown as "Alice & Bob" (or "Bob & Alice"), not as its room_id

Scenario: AC2 a member without a display name
  Given an unnamed room whose member has no profiles row or a NULL / blank displayname
  When an admin opens the rooms index or the room detail page
  Then that member is shown by the localpart of the user id (never nil, never blank) and the page does not crash

Scenario: AC3 many members
  Given an unnamed room with more than 4 joined members
  When an admin opens the rooms index or the room detail page
  Then the room is shown as "(N members)" and no member name is listed

Scenario: AC4 explicit names are unaffected
  Given a room with an explicit name
  When an admin opens the rooms index or the room detail page
  Then the name is shown verbatim

Scenario: AC5 empty and single-member rooms
  Given an unnamed room with zero joined members, or with exactly one
  When an admin opens either page
  Then the page renders (HTTP 200) and the room is shown as "(empty room)" or by the sole member's name, never only as the raw room_id

Scenario: AC6 one shared fallback
  Given an unnamed room
  When the index and the detail page render it
  Then both show the identical text (one shared function, no second implementation)

Scenario: AC7 no query per room
  Given the rooms index lists many unnamed rooms
  When it is rendered
  Then the member names of all listed rooms are fetched with ONE batched query (at most 4 names per room, stable order),
       so the number of queries does not grow with the number of rooms

Scenario: AC8 user-controlled names are escaped and bounded
  Given a member whose display name contains markup (for example "<script>alert(1)</script>"), control or bidi override characters, or is very long
  When an admin opens either page
  Then the markup appears only HTML-escaped, the control / bidi characters are removed, and the rendered fallback name is length-capped

Scenario: AC9 the index can be narrowed
  Given the index lists at most 500 rooms in a fixed order
  When an admin passes a search term (room id or explicit name, case-insensitive substring)
  Then only the matching rooms are listed, so any room can be reached even beyond the first 500 (and the index tests do not depend on global table contents)
```

## Notes

- Shared function `Nebu.Admin.RoomNames` (admin namespace, SQL inline, ADR-018): `display_name/1` (pure), `attach_member_names/1` (one query for the unnamed rooms of a list with
  1..4 members, `row_number() OVER (PARTITION BY room_id ORDER BY joined_at, user_id)`), used by `RoomsController.index/show` and `RoomsHTML`.
- Fallback format decided by the ATDD suite: `" & "` separator, "(N members)" above 4 members, "(empty room)" for none. Only joined members (`left_at IS NULL`, as `member_count`).
- Nothing new is exposed: only `profiles.displayname` / the localpart of a user id that the same admin page already lists.
- No migration, no Matrix client API change. Canonical alias / disambiguation of equal names are out of scope.
- AC9 is a small product addition forced by the test suite: `ORDER BY COALESCE(name,''), room_id LIMIT 500` makes any index assertion depend on the rows other suites leave behind.

## Out of scope

Matrix client-side room naming (heroes), Playwright e2e (not runnable in the sandbox: no node_modules).
