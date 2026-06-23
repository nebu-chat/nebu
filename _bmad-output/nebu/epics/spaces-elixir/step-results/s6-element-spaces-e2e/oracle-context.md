# Oracle Context — s6-element-spaces-e2e (Matrix spec contract)

## 1. Endpoints, Event Types & MUST Requirements

### createRoom — Space Creation (AC1, AC2)
- `POST /_matrix/client/v3/createRoom`
- MUST include `creation_content: { "type": "m.space" }` — sets `m.room.create` content `type` field
- Server MUST auto-join creator (`m.room.member membership: join`) as first member event
- State event sequence (MUST be applied in spec order): `m.room.create` → creator join → `m.room.power_levels` → preset events → `initial_state` → name/topic
- Space for PUBLIC join: set `preset: public_chat` or include `m.room.join_rules { join_rule: "public" }` in `initial_state`
- Space SHOULD set `m.room.power_levels events_default: 100`
- `initial_state` entries override preset values but are themselves overridden by top-level `name`/`topic` keys

### m.space.child State Event (AC5)
- `PUT /_matrix/client/v3/rooms/{spaceId}/state/m.space.child/{childRoomId}`
- `state_key` = child room ID
- Content: `{ "via": ["example.org"] }` — `via` is **required**; absent/invalid `via` means child NOT part of the space
- Child removed by setting `content` to `{}` (omitting `via`)
- Optional: `order` (ASCII 0x20–0x7E, max 50 chars), `suggested` (boolean, default false)

### m.space.parent State Event (AC5)
- `PUT /_matrix/client/v3/rooms/{childRoomId}/state/m.space.parent/{spaceId}`
- `state_key` = parent space room ID; content `{ "via": [...] }` (required)
- MUST be ignored unless corresponding `m.space.child` exists in parent OR sender has PL to send `m.space.child` in parent
- Optional: `canonical: true`

### Restricted Join Rule — MSC3083 (AC3)
- `m.room.join_rules` content: `{ "join_rule": "restricted", "allow": [{ "type": "m.room_membership", "room_id": "!spaceId:server" }] }`
- Server MUST verify requesting user meets ≥1 `allow` condition before accepting join
- Only condition type: `m.room_membership` — user MUST be currently **joined** in referenced room
- No condition satisfiable/verifiable → join MUST be rejected `403 M_FORBIDDEN`
- Conditions evaluated only at join time; member need not stay in Space afterward
- Invited users: restrictions do NOT apply — invite takes precedence

### GET /hierarchy (AC5)
- `GET /_matrix/client/v1/rooms/{spaceId}/hierarchy`
- Only `m.space.child` events considered (parent events excluded); DFS; loops handled gracefully
- Visibility filter — server MUST return rooms where ≥1 true: user joined; user invited; `join_rule: public`; `join_rule: restricted` AND meets allow; `knock`/`knock_restricted`; `history_visibility: world_readable`
- Response `rooms[]` (SpaceHierarchyRoomsChunk) required: `room_id`, `children_state`, `guest_can_join`, `num_joined_members`, `world_readable`
- `children_state`: StrippedChildStateEvent (`content`, `origin_server_ts`, `sender`, `state_key`, `type`)
- `room_type: "m.space"` present for space-rooms (v1.4)
- Pagination: `from`, `limit`, optional `max_depth`, `suggested_only`; `next_batch` when more; `max_depth`/`suggested_only` MUST NOT change mid-pagination

### Leave (AC4)
- `POST /_matrix/client/v3/rooms/{roomId}/leave`
- After leave: Space MUST NOT appear in `/sync` `rooms.join` — moves to `rooms.leave`

## 2. Error Codes & Edge Cases MUST-Covered

| Scenario | HTTP | errcode |
|---|---|---|
| AC3b: Non-Space-member restricted join | 403 | M_FORBIDDEN |
| Restricted join: empty/invalid `allow` | 403 | M_FORBIDDEN |
| /hierarchy: caller not joined + not world_readable + not public | 403 | M_FORBIDDEN |
| /hierarchy: invalid `from` token | 400 | M_UNKNOWN / server-defined |
| /hierarchy: `suggested_only`/`max_depth` changed mid-pagination | 400 | server-defined |
| `m.space.child` PUT with no `via` → child excluded | (no error) | — |
| Leave Space: gone from `/sync` rooms.join | 200 + sync assert | — |
| Hierarchy: inaccessible child rooms omitted | 200 filtered | — |

### Edge cases
- Pagination `from` + changed `max_depth` → 400
- No further rooms → `next_batch` absent (not null)
- Restricted child appears in hierarchy for Space members; NOT for non-members lacking allow conditions
