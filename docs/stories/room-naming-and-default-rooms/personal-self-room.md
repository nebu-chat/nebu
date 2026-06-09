---
story_id: personal-self-room
title: "Personal Self-Room at First Login"
epic: room-naming-and-default-rooms
status: done
security_review: not-needed
created: 2026-05-28
branch: feature/room-naming-and-default-rooms
---

## Summary

When a new user logs in for the first time, a personal self-room is automatically created for them.
This room is named after the user's Matrix localpart (everything before the `:` in their Matrix ID,
without the leading `@`). The room is private, the user is the sole member, and creation is
idempotent — subsequent logins never create a duplicate.

This mirrors the "personal notes" channel in Slack (DM to yourself) and gives users a persistent
space for personal notes, saved links, or drafts.

## User Story

As a Nebu user,
I want a personal room named after my username to exist automatically after my first login,
so that I have a place for personal notes without having to create a room manually.

## Acceptance Criteria

1. **Given** a user `@alice:nebu.local` has never logged in before,
   **When** they complete their first login (OIDC token validated, `validate_token` gRPC called),
   **Then** a room with `name = "alice"` exists in the database and alice is its sole member.

2. **Given** the personal self-room already exists for `@alice:nebu.local`,
   **When** alice logs in again (second or later login),
   **Then** no additional self-room is created (exactly one self-room per user, idempotent).

3. **Given** alice's personal self-room exists,
   **When** alice calls `GET /_matrix/client/v3/sync`,
   **Then** the sync response includes alice's self-room under `rooms.join` with the room name "alice" visible in the room's state events.

4. **Given** the self-room creation fails (DB error during room creation),
   **When** alice logs in,
   **Then** the login still succeeds — self-room creation failure is non-fatal and logged as a warning.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`TestPersonalSelfRoom_CreatedOnFirstLogin`** — Godog integration test
   (`gateway/features/personal-self-room.feature`)
   - Given: User `@alice:nebu.local` has never logged in
   - When: POST `/_matrix/client/v3/login` with valid OIDC token
   - Then: GET `/_matrix/client/v3/sync` returns a room in `rooms.join` whose state contains
     `m.room.name` with `content.name = "alice"`
   - And: The room has exactly one member (alice herself)

2. **`TestPersonalSelfRoom_IdempotentOnRelogin`** — Godog integration test (same feature file)
   - Given: User `@alice:nebu.local` has logged in before (self-room exists)
   - When: Alice logs in again (second session)
   - Then: Sync still shows exactly one self-room for alice (no duplicates)

3. **`TestEnsurePersonalRoom_NonFatalOnDBError`** — ExUnit unit test
   (`core/apps/event_dispatcher/test/nebu/event_dispatcher/personal_room_test.exs`)
   - Given: `messages_db_module` returns `{:error, :db_down}` for self-room check
   - When: `ensure_personal_room/1` is called
   - Then: Returns `:ok` (non-fatal), a warning is logged

## Technical Requirements

### 1. Database Migration

New column on `users` table:

```sql
ALTER TABLE users ADD COLUMN personal_room_id TEXT REFERENCES rooms(room_id);
```

This is the idempotency anchor — `NULL` means no self-room yet; a room ID means it already exists.
New migration file: `gateway/migrations/000002_personal_room_id.up.sql` (and `.down.sql`).

### 2. New DB helper — `messages_db_module` (Elixir Core)

Two new functions in `Nebu.Messages.DB` (or a dedicated `Nebu.Room.PersonalRoom.DB`):

```elixir
@spec get_personal_room_id(user_id :: String.t()) :: {:ok, String.t() | nil} | {:error, term()}
@spec set_personal_room_id(user_id :: String.t(), room_id :: String.t()) :: :ok | {:error, term()}
```

`get_personal_room_id/1` reads `personal_room_id` from the `users` row.
`set_personal_room_id/2` updates it (only when currently `NULL`; use `WHERE personal_room_id IS NULL` for race-safety).

### 3. New internal helper — `ensure_personal_room/1` in `event_dispatcher/server.ex`

```elixir
defp ensure_personal_room(user_id) do
  localpart = user_id |> String.split(":") |> hd() |> String.trim_leading("@")
  case get_personal_room_id(user_id) do
    {:ok, nil} ->
      # Reuse create_room/2 logic inline (no gRPC roundtrip) or extract a
      # shared private helper create_room_internal/2 from create_room/2.
      case create_personal_room(user_id, localpart) do
        {:ok, room_id} -> set_personal_room_id(user_id, room_id)
        {:error, reason} ->
          Logger.warning("ensure_personal_room failed for #{user_id}: #{inspect(reason)}")
          :ok
      end
    {:ok, _room_id} -> :ok
    {:error, reason} ->
      Logger.warning("ensure_personal_room: DB error for #{user_id}: #{inspect(reason)}")
      :ok
  end
end
```

### 4. Hook into `validate_token/2` in `event_dispatcher/server.ex`

After the `TokenValidator.validate/4` call returns `{:ok, user}`, spawn a non-blocking task:

```elixir
Task.start(fn -> ensure_personal_room(user_id) end)
```

This is fire-and-forget: the login response is not delayed.

### 5. `create_personal_room/2` internal helper

Extract the room-creation logic from `create_room/2` into a private function that can be called
without a gRPC request. The personal room:
- `is_self_room`: not stored as a separate DB column — presence of `personal_room_id` in `users` is the marker
- `name`: Matrix localpart (e.g., `"alice"` for `@alice:nebu.local`)
- `visibility`: `"private"`
- Creator is the only member (no invite list)
- Emits `m.room.create`, `m.room.member`, `m.room.power_levels`, and `m.room.name` (with localpart name)

### 6. Proto — no changes needed

`create_room/2` is called as an internal Elixir function, not via a new gRPC RPC.

### 7. Go Gateway — no changes needed

The self-room appears in sync as a regular joined room; no gateway-side changes required.
