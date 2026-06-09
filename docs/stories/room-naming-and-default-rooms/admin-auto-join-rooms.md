---
story_id: admin-auto-join-rooms
title: "Admin UI: Mark Rooms as Auto-Join"
epic: room-naming-and-default-rooms
status: done
security_review: required
created: 2026-05-28
branch: feature/room-naming-and-default-rooms
---

## Summary

Admins can mark any room as "auto-join" in the Admin UI. Every newly provisioned user is
automatically joined to all auto-join rooms at their first login — no manual invite needed.

Retroactive auto-join (joining already-existing users to a newly flagged room) is out of scope for
this story. The current design applies only to new users provisioned after the flag is set.

A future story can add a separate "Join all existing users" action to the Admin UI.

## User Story

As an instance admin,
I want to mark a room as "auto-join" in the Admin UI,
so that all newly registered users are automatically added to that room without manual invites.

## Acceptance Criteria

1. **Given** the admin is on the room detail page for "General",
   **When** they enable the "Auto-join" toggle and submit the settings form,
   **Then** the `rooms.is_auto_join` column is set to `true` for that room in the database,
   **And** the detail page re-renders with the toggle shown as enabled.

2. **Given** a room has `is_auto_join = true`,
   **When** it is disabled via the Admin UI toggle and submitted,
   **Then** `rooms.is_auto_join` is set to `false` and the UI reflects the disabled state.

3. **Given** room "General" has `is_auto_join = true`,
   **When** a new user `@charlie:nebu.local` logs in for the first time (first provision),
   **Then** charlie is a member of "General" after login completes.

4. **Given** room "General" has `is_auto_join = true`,
   **When** an already-existing user `@alice:nebu.local` logs in again (re-login),
   **Then** alice's membership in "General" is not changed by the login (idempotent for existing users).

5. **Given** room "General" has `is_auto_join = true` and charlie is already a member,
   **When** charlie logs in for the first time (edge case: pre-invited before first login),
   **Then** no duplicate membership error occurs (join is idempotent).

6. **Given** the auto-join room list is queried at login time,
   **When** the DB query fails,
   **Then** login still succeeds and the error is logged as a warning (non-fatal).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`TestAutoJoinRoom_NewUserJoinsOnFirstLogin`** — Godog integration test
   (`gateway/features/auto-join-rooms.feature`)
   - Given: Room "general" exists with `is_auto_join = true`
   - When: New user `@charlie:nebu.local` completes first login
   - Then: GET `/_matrix/client/v3/sync` for charlie includes "general" under `rooms.join`

2. **`TestAutoJoinRoom_ExistingUserNotRejoined`** — Godog integration test (same feature file)
   - Given: Room "general" has `is_auto_join = true`; alice already exists
   - When: Alice re-logs in (not a new provision)
   - Then: Alice's room list is unchanged from before login (no new join event emitted)

3. **`TestAutoJoinRoom_AdminToggle`** — Playwright + Cucumber E2E test
   (`e2e/features/auto-join-rooms.feature` + `e2e/steps/auto-join-rooms.steps.ts`)
   - Given: Admin is authenticated; room "General" exists
   - When: Admin navigates to room detail, enables auto-join toggle, submits
   - Then: Page shows "Auto-join" badge/toggle in enabled state
   - And: Re-loading the page still shows toggle enabled (persisted)

4. **`TestAutoJoin_NonFatalOnDBError`** — ExUnit unit test
   - Given: `messages_db_module().list_auto_join_rooms()` returns `{:error, :db_down}`
   - When: `ensure_auto_join_memberships/1` is called for a new user
   - Then: Returns `:ok` (non-fatal), warning logged

## Technical Requirements

### 1. Database Migration

```sql
-- gateway/migrations/000003_auto_join_rooms.up.sql
ALTER TABLE rooms ADD COLUMN is_auto_join BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX rooms_auto_join_idx ON rooms (is_auto_join) WHERE is_auto_join = true;
```

The partial index keeps the "find all auto-join rooms" query fast regardless of total room count.

### 2. Proto changes — `proto/core.proto`

Add to `AdminRoomDetailProto`:
```protobuf
bool is_auto_join = 8;
```

Add to `UpdateRoomSettingsRequest`:
```protobuf
optional bool is_auto_join = 3;
```

Regenerate: `make proto`.

### 3. Elixir Core — `event_dispatcher/server.ex`

**`update_room_settings/2`**: Read `req.is_auto_join` and update `rooms.is_auto_join` in DB.
Use `optional bool` (proto `optional`) so absence ≠ `false` — only update when the field is present.

New private helper:

```elixir
defp ensure_auto_join_memberships(user_id) do
  case messages_db_module().list_auto_join_rooms() do
    {:ok, room_ids} ->
      Enum.each(room_ids, fn room_id ->
        case Nebu.Room.Server.join(room_id, user_id) do
          :ok -> :ok
          {:error, :already_member} -> :ok
          {:error, reason} ->
            Logger.warning("auto-join #{room_id} for #{user_id} failed: #{inspect(reason)}")
        end
      end)
    {:error, reason} ->
      Logger.warning("list_auto_join_rooms failed: #{inspect(reason)}")
  end
  :ok
end
```

Called from `validate_token/2` only for **new users** (users where `TokenValidator` provisions a new
user row). Detect new users by adding `is_new: boolean` to the `TokenValidator` return type
(see Story `personal-self-room` — the same hook point can serve both stories).

Both `ensure_personal_room/1` and `ensure_auto_join_memberships/1` should be called in the same
`Task.start/1` callback after a new provision to keep them non-blocking and co-located.

New DB helper: `messages_db_module().list_auto_join_rooms/0` → `{:ok, [String.t()]} | {:error, term()}`:
```sql
SELECT room_id FROM rooms WHERE is_auto_join = true AND status = 'active';
```

### 4. Admin UI — `gateway/internal/admin/rooms.go`

**`StubRoom` struct**: add `IsAutoJoin bool`.

**`protoToStubRoom/1`**: map `r.GetIsAutoJoin()` → `StubRoom.IsAutoJoin`.

**`UpdateSettingsHandler`**: read `is_auto_join` from form value (`"true"/"false"`) and include in
`pb.UpdateRoomSettingsRequest{IsAutoJoin: proto.Bool(isAutoJoin)}`.

### 5. Admin UI — `gateway/internal/admin/templates/rooms.html`

Add below the `max_members` input in the settings form:

```html
{{/* Auto-join toggle — Story room-naming-and-default-rooms */}}
<div class="form-control mb-3">
  <label class="label cursor-pointer">
    <span class="label-text">Auto-join for new users</span>
    <input type="checkbox" name="is_auto_join" value="true"
           class="toggle toggle-primary"
           {{ if .ActiveRoom.IsAutoJoin }}checked{{ end }}>
  </label>
  <p class="text-xs text-base-content/60 mt-1">
    New users are automatically joined to this room on first login.
  </p>
</div>
```

The toggle must be inside the existing `<form method="POST" ...>` for settings.

### 6. Security Note (Security Review Gate)

`UpdateRoomSettings` is an admin-only endpoint. Verify:
- The Go admin middleware (`AdminAuthMiddleware`) enforces `system_role = "instance_admin"` before
  reaching `UpdateSettingsHandler` — no additional auth needed on the handler itself.
- The `is_auto_join` flag is not exposed or settable via the Matrix Client-Server API (user-facing
  endpoints have no path to this field).
- `list_auto_join_rooms` runs server-side in Elixir; results are never returned to the Matrix client.
