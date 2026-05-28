# Oracle Gate — Matrix Spec Context

**Spec:** Matrix CS API v1.18 §Syncing

## Spec Finding: rooms.join vs rooms.leave

Per §GET /sync response schema:

| Field | Meaning |
|---|---|
| `rooms.join` | Rooms the user has **joined** — MUST only contain rooms with current `membership = join` |
| `rooms.leave` | Rooms the user has **left or been banned from** |
| `include_leave` filter | Defaults to `false` — left rooms are excluded from sync unless client opts in |

**Rule:** A room MUST NOT appear in `rooms.join` if the user's current membership is not `join`.

## Bug Classification (Oracle-verified)

The initial sync path is spec-correct: `get_rooms_for_user` filters `WHERE left_at IS NULL`. The bug is in the `leave_room` persistence — two fallback paths fail to write `left_at`, causing `rooms.join` to contain stale rooms on re-login.

## Spec-Mandated Behavior for Left Rooms

1. After `/leave`, the next `/sync?since=<token>` MUST return the room in `rooms.leave` with an `m.room.member` event (`membership: "leave"`)
2. The next initial sync (no `since`) MUST NOT return the room in `rooms.join`
3. Rooms that no longer exist (deleted from `rooms` table) should be silently dropped from the sync response — they cannot appear in `rooms.join`

## No New Endpoints Required

This bug is a Core persistence fix only. No new Matrix API endpoints or response format changes needed.
