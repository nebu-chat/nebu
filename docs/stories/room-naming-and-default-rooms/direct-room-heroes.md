---
story_id: direct-room-heroes
title: "DM Room Names: Populate Matrix Sync Heroes"
epic: room-naming-and-default-rooms
status: done
security_review: not-needed
created: 2026-05-28
branch: feature/room-naming-and-default-rooms
oracle_reviewed: true
oracle_review_date: 2026-05-28
---

## Summary

Direct-message (DM) rooms without an explicit `m.room.name` state event currently appear as
"Leerer Chat" ("Empty Room") in Matrix clients like Element Web. This is because Nebu does not
populate the `summary["m.heroes"]` field in sync responses.

The Matrix CS API specification defines a display name fallback hierarchy: when there is no
`m.room.name` and no `m.room.canonical_alias`, the client uses the `summary.m.heroes` list to
compute a name from the display names of the other participants.

This story implements the heroes field in the sync response so that DM rooms are shown as
"Alice" (for 1:1 DMs) or "Alice, Bob" (for small group DMs), matching user expectations.

Oracle review completed 2026-05-28. Technical Requirements below reflect the Oracle's spec findings.

## User Story

As a Nebu user,
I want direct-message rooms to show the names of the participants instead of "Empty Room",
so that I can identify my conversations without manually renaming each DM room.

## Acceptance Criteria

1. **Given** alice and bob have an existing DM room with `is_direct: true` and no `m.room.name`,
   **When** bob calls `GET /_matrix/client/v3/sync`,
   **Then** the room in `rooms.join` contains a `summary` object with
   `summary["m.heroes"] = ["@alice:nebu.local"]`.

2. **Given** alice, bob, and charlie have a 3-person DM room with no `m.room.name`,
   **When** charlie calls sync,
   **Then** `summary["m.heroes"]` contains both `@alice:nebu.local` and `@bob:nebu.local`
   (up to 5 heroes, excluding the calling user, per spec).

3. **Given** a room has an explicit `m.room.name` state event with a non-empty name,
   **When** any member calls sync,
   **Then** `summary` is either absent or has an empty `m.heroes` list — the explicit name takes
   precedence and heroes are not needed (spec-compliant behaviour; confirm with Oracle).

4. **Given** the initial sync (`since` parameter absent),
   **When** sync is called,
   **Then** `summary["m.heroes"]` is populated for all rooms without an explicit name.

5. **Given** a delta sync with no membership changes in a room,
   **When** sync is called,
   **Then** `summary` MAY be omitted for that room (spec allows omitting summary when
   there are no changes; confirm exact behaviour with Oracle before implementing).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`TestSyncHeroes_DirectRoom1on1`** — Godog integration test
   (`gateway/features/direct-room-heroes.feature`)
   - Given: Room "dm-alice-bob" exists; alice and bob are members; `is_direct = true`; no `m.room.name`
   - When: Bob calls GET `/_matrix/client/v3/sync`
   - Then: Response contains `rooms.join["!dm-room-id"].summary["m.heroes"] = ["@alice:nebu.local"]`

2. **`TestSyncHeroes_GroupDM`** — Godog integration test (same feature file)
   - Given: 3-person DM room with alice, bob, charlie; no `m.room.name`
   - When: Charlie calls sync
   - Then: `summary["m.heroes"]` contains alice and bob (order may vary; test as set)

3. **`TestSyncHeroes_NamedRoomHasNoHeroes`** — Godog integration test (same feature file)
   - Given: Room "Team" exists with `m.room.name = "Team"`
   - When: Any member calls sync
   - Then: Response does NOT contain `summary["m.heroes"]` (or heroes is empty) for that room

4. **`TestSyncHeroes_InitialSync`** — Godog integration test (same feature file)
   - Given: Alice has 2 DM rooms without names
   - When: Alice calls sync without `since` (initial sync)
   - Then: Both rooms in `rooms.join` have `summary["m.heroes"]` populated

## Technical Requirements

Oracle-reviewed 2026-05-28. Corrections from spec review applied below.

### 1. Proto changes — `proto/core.proto`

Add to `SyncRoom` message:
```protobuf
repeated string heroes               = 6;  // m.heroes: full MXIDs (excl. syncing user), max 5
int32           joined_member_count  = 7;  // m.joined_member_count: currently joined (not invited)
int32           invited_member_count = 8;  // m.invited_member_count: pending invitations
```

Regenerate: `make proto`.

### 2. Elixir Core — hero computation in `event_dispatcher/server.ex`

For each `SyncRoom` being built:

**When to include summary** (spec §11.2.2):
- **Initial sync** (`since` absent): always include summary for rooms without `m.room.name`.
- **Delta sync**: include summary only if heroes/counts changed since the previous sync token.
  Elixir must compare current heroes/counts against what was sent in the previous token window
  and set the proto fields only when there is a change.
- **When a room gains `m.room.name` in this delta**: send `heroes = []` and counts in this one
  delta so clients can clear their cached heroes. After that, omit summary for the named room.

**Hero computation rules** (spec §11.2.2.5, strict):
- Pool = all members in `join` state + all members in `invite` state, excluding the syncing user
- Selection order: joined members first (by `joined_at ASC`), then invited members
- Cap at 5 heroes total
- Hero IDs must be full MXIDs (e.g., `@alice:nebu.local`)
- `joined_member_count` = `COUNT(*)` from `room_members WHERE room_id = $1 AND left_at IS NULL`
- `invited_member_count` = `COUNT(*)` from `room_invitations WHERE room_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL`

**New DB helpers** (in `Nebu.Messages.DB` or a dedicated `Nebu.Room.SyncSummary` module):

```elixir
@spec get_room_heroes(room_id :: String.t(), exclude_user_id :: String.t()) ::
        {:ok, %{heroes: [String.t()], joined: integer(), invited: integer()}} | {:error, term()}
```

SQL for heroes (joined first, then invited, cap 5):
```sql
-- Joined members (excluding syncing user), sorted by join time
(SELECT user_id, joined_at FROM room_members
 WHERE room_id = $1 AND user_id != $2 AND left_at IS NULL
 ORDER BY joined_at ASC LIMIT 5)
UNION ALL
-- Invited members (pad to 5 if not enough joined)
(SELECT invitee_id AS user_id, invited_at AS joined_at FROM room_invitations
 WHERE room_id = $1 AND invitee_id != $2
   AND accepted_at IS NULL AND rejected_at IS NULL
 ORDER BY invited_at ASC)
LIMIT 5
```

### 3. Go Gateway — `sync.go`

New struct `syncRoomSummary`:
```go
type syncRoomSummary struct {
    Heroes             []string `json:"m.heroes"`
    JoinedMemberCount  int32    `json:"m.joined_member_count"`
    InvitedMemberCount int32    `json:"m.invited_member_count"`
}
```

Extend `syncJoinedRoom`:
```go
type syncJoinedRoom struct {
    State       syncStateSection       `json:"state"`
    Timeline    syncTimelineSection    `json:"timeline"`
    AccountData syncAccountDataSection `json:"account_data"`
    Summary     *syncRoomSummary       `json:"summary,omitempty"`  // nil = omitted from JSON
}
```

In `buildJoinedRooms`: if `room.GetJoinedMemberCount() > 0 || len(room.GetHeroes()) > 0`, build and attach `Summary`. Use `omitempty` on the field pointer so named rooms (where Elixir sends no heroes) marshal as no `summary` key at all.

### 4. No database schema changes required

Heroes are computed at sync time from the existing `room_members` and `room_invitations` tables.

### 5. Matrix spec display name algorithm (for dev reference)

The client-side algorithm (spec §11.2.2.5) that `summary["m.heroes"]` feeds into:

1. `m.room.name` event with non-empty `name` → use that name. Done.
2. `m.room.canonical_alias` with non-empty `alias` → use alias. Done.
3. `summary["m.heroes"]` non-empty → compose from heroes' display names:
   - 1 hero → `"Alice"`
   - 2 heroes → `"Alice, Bob"`
   - 3+ heroes, total == heroes count → `"Alice, Bob, and Charlie"`
   - 3+ heroes, more members than shown → `"Alice, Bob, and N others"` where
     `N = m.joined_member_count + m.invited_member_count - heroes.length`
4. No heroes → `"Empty Room"` (the current bug)

Nebu does not implement this algorithm — the client does. Nebu only needs to supply the data.

### 6. `m.direct` and `is_direct` — no server-side action needed

`m.direct` global account data is written by the *client* via
`PUT /_matrix/client/v3/user/{userId}/account_data/m.direct`. Nebu stores and returns it
through the existing account data sync path. No new server logic is needed for this.

The `is_direct: true` flag in `m.room.member` content is likewise set by clients and stored
verbatim by Nebu in the `events` table. No server-side generation is required.
