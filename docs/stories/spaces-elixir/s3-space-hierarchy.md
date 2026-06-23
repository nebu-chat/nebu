---
story_id: spaces-elixir-s3-hierarchy
title: "Spaces S3: SpaceHierarchy BFS + GET /hierarchy + pagination (Elixir port of epic-15 15.2/15.6b/15.7)"
type: feature
severity: high
epic: spaces-elixir
status: review
security_review: required
created: 2026-06-21
branch: feature/spaces-elixir
matrix: true
ui: false
---

## Summary

Implement the Matrix Space hierarchy read API: `GET /_matrix/client/v1/rooms/{roomId}/hierarchy`
(MSC2946, stable v1.2). Element/FluffyChat call it to render a Space's tree of child rooms.
Ports epic-15 stories 15.2 (DB index), 15.6b (BFS module), 15.7 (HTTP handler + pagination).
Builds on S1 (room_type) + S2 (m.space.child events).

## Story

As a Matrix client,
I want `GET /_matrix/client/v1/rooms/{spaceId}/hierarchy` to return the BFS-ordered tree of
rooms reachable via `m.space.child` from the Space, with depth/suggested filtering,
visibility filtering and pagination,
So that the Space sidebar can be rendered.

## Acceptance Criteria

**AC1 — BFS traversal (Nebu.Matrix.SpaceHierarchy):**
`Nebu.Matrix.SpaceHierarchy.get_hierarchy(root_room_id, user_id, opts)` does a breadth-first
traversal over `m.space.child` state events from the root. Given a Space with 2 regular
child rooms + 1 sub-space (itself with 2 children), the result contains all 6 rooms in BFS
order; each room summary carries `room_type` ("m.space" for the sub-space, null otherwise).

**AC2 — max_depth limits traversal:** `max_depth: 1` returns only direct children (the
sub-space is included; its children are NOT). `max_depth: 0` returns just the root.

**AC3 — suggested_only filters:** `suggested_only: true` returns only children whose
`m.space.child` content has `"suggested": true`.

**AC4 — visibility filter:** a room the requesting user cannot see (private room they're not
a member of) is EXCLUDED from the response, but its children are STILL traversed (per spec).
The root: if the user is not a member AND the space is not world-readable/public → the whole
request is `403 M_FORBIDDEN`.

**AC5 — room summary shape (per Matrix spec):** each entry has `room_id`, `name`, `topic`,
`canonical_alias`, `num_joined_members`, `world_readable` (bool), `guest_can_join` (bool),
`join_rule`, `room_type` (nullable), `avatar_url`, and `children_state` (the room's
`m.space.child` stripped state events). The response is `{"rooms": [...], "next_batch": "..."}`.

**AC6 — HTTP route + query params:** `GET /_matrix/client/v1/rooms/{roomId}/hierarchy`
(authenticated) parses `limit`, `max_depth`, `suggested_only`, `from`:
- `suggested_only=not-a-bool` → `400 M_INVALID_PARAM`
- `limit=-1` (negative) → `400 M_INVALID_PARAM`
- `limit=2000` → clamped to server max 1000 (no error, spec server-side clamp)
- non-member of a private space → `403 M_FORBIDDEN`

**AC7 — pagination:** when the result exceeds `limit`, the response includes a
`next_batch` token; passing it back via `?from=<token>` returns the next page and
eventually an empty/absent `next_batch`. The token must be opaque and not leak internal
state; an invalid/forged token → `400 M_INVALID_PARAM` (fail closed).

**AC8 — DB indexes:** migration adds `idx_events_space_child` on
`events (room_id, state_key) WHERE event_type = 'm.space.child'` and
`idx_events_space_parent` on `events (state_key) WHERE event_type = 'm.space.parent'`.

## Acceptance Tests (TDD — written FIRST)
1. SpaceHierarchy BFS: full-depth (6 rooms, BFS order, room_type set) — ExUnit (Repo-less via injectable child-lookup) 
2. max_depth: 1 / 0 — ExUnit
3. suggested_only: true filters — ExUnit
4. visibility: private room excluded but children traversed; root non-member private → forbidden — ExUnit
5. HTTP: query-param validation (bad bool 400, negative limit 400, over-limit clamp) — ExUnit :integration
6. HTTP: 403 non-member of private space; 200 {rooms,next_batch} for member — ExUnit :integration
7. pagination: next_batch round-trip; forged token → 400 — ExUnit :integration
8. migration: both indexes exist — ExUnit/migration check

## Dev Notes

### Files likely changed
- `core/priv/migrations/000005_space_hierarchy_index.{up,down}.sql` — the two partial
  indexes (idempotent CREATE INDEX IF NOT EXISTS; next version after 000004).
- `proto/core.proto` — `rpc GetSpaceHierarchy(GetSpaceHierarchyRequest) returns
  (GetSpaceHierarchyResponse)`; request `{root_room_id, user_id, limit, max_depth,
  suggested_only, from_token}`; response `{repeated HierarchyRoom rooms; string
  next_batch_token}`; `HierarchyRoom{room_id,name,topic,canonical_alias,
  num_joined_members,world_readable,guest_can_join,join_rule,room_type,avatar_url,
  children_state_json}`. `make proto`, minimal flat-file edits (S1/S2 pattern), add the rpc
  to core_grpc.pb.ex, remove spurious nested dir.
- `core/lib/nebu/matrix/space_hierarchy.ex` — NEW. `get_hierarchy/3` BFS over m.space.child
  (read children via a DB helper querying events WHERE event_type='m.space.child' AND
  room_id=$1, mapping state_key→child room id + content suggested flag). Depth + suggested
  + visibility filtering. Build each room summary from room state (name/topic/join_rule/
  history_visibility/guest_access/member count/room_type/avatar). Pagination: deterministic
  ordering + opaque cursor (e.g. base64 of the BFS offset / last room id); fail-closed on
  bad token.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` — `get_space_hierarchy/2` wraps the
  module, enforces the root visibility/membership gate (AC4 403).
- `core/lib/nebu/web/router/protected.ex` — `get "/client/v1/rooms/:room_id/hierarchy"`
  (note /v1, like relations); parse + validate query params (AC6); send {rooms, next_batch}.
  Confirm the /v1 path reaches Protected (the catch-all forward covers it, as for relations).
- `core/test/nebu/matrix/…` — tests 1–8.

### Constraints / security (required)
- AC4/AC6 visibility gate is the security boundary: do NOT leak private rooms' existence,
  members, or content to non-members; the root 403 must fire before any traversal data
  leaks. children_state of a hidden room must not leak its private children's content beyond
  what spec allows (only the stripped m.space.child events of visible rooms).
- Pagination token opaque + fail-closed (AC7) — no internal-state leak, no injection.
- limit clamp ≤ 1000; BFS bounded (no infinite loop on cyclic m.space.child graphs — track
  visited room ids).
- ADR-018 inline parameterised SQL; let-it-crash w/ Matrix error envelopes; ADR-020;
  acting-user-from-token.

### Reference (old Go stories — parity only, do NOT port Go)
`git show origin/feature/epic-15:docs/stories/matrix-spaces/core-spacehierarchy-bfs-module-exunit.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/get-hierarchy-go-gateway-handler-pagination.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/postgresql-index-for-space-bfs.md`

## Dev Agent Record

### Approach (TDD)

RED first: `core/test/nebu/matrix/space_hierarchy_test.exs` (9 Repo-less unit tests
driving `SpaceHierarchy.get_hierarchy/3` with injected `child_lookup` / `room_summary`
functions) was written and run before the module existed → 9 failing. Then implemented
`Nebu.Matrix.SpaceHierarchy` → 9 green. Integration tests (`:integration`, AT5-8) were
added for the HTTP route, root gate, pagination round-trip and the migration indexes;
they are excluded from the DB-less `mix test` run (run via `make test-integration`).

### Design

**SpaceHierarchy module (`space_hierarchy.ex`).** BFS over `m.space.child` with a
`visited` MapSet (cycle-safe — a child pointing back to the root is visited once).
Level-order frontier so `max_depth` is a clean cutoff (0 = root only). `suggested_only`
prunes both inclusion AND traversal of non-suggested edges. The visibility resolver
(`room_summary`) returns `{:ok, summary}` or `:hidden`; a hidden room is dropped from the
output but its children are still enqueued (spec). The full visible BFS sequence is
deterministic (edge order by MSC1772 `order` then room id); a page is the window
`[offset, offset+limit)`. The cursor is an opaque url-safe Base64 of `"h1:<offset>"`;
`decode_token/1` fail-closes (`{:error, :invalid_token}`) on anything malformed —
never silently resets to page 0. `clamp_limit/1` bounds the page size to 1..1000.

**Server wrapper (`server.ex` `get_space_hierarchy/2`).** Enforces the ROOT gate FIRST
(`visible_summary_or_forbid!/2` → `permission_denied` before any traversal), then supplies
DB-backed `child_lookup` (`Room.DB.get_space_children/1`) and `room_summary` resolvers.
`room_visible?/3`: member OR `join_rule == "public"` OR `history_visibility ==
"world_readable"`. Room summaries are built from `build_state_events/2` (reusing the same
state assembly `/sync` uses) + the live member count; `room_type` from `m.room.create`
content `type`; `children_state` = the room's stripped `m.space.child` events. A dangling
child edge (room gone) resolves to `:hidden` (rescue `GRPC.RPCError`) rather than crashing.
A forged token maps to `invalid_argument` → 400.

**DB helper (`Room.DB.get_space_children/1`).** `DISTINCT ON (state_key)` latest
`m.space.child` per child (backed by `idx_events_space_child`), decodes content, drops
empty-content (unlinked) edges, orders by `order` then child id. Parameterised SQL
(ADR-018). Deliberately NOT a `DBBehaviour` callback (that contract is the Room GenServer
persistence surface; many fakes implement it) — it is a server-side read helper.

**HTTP route (`protected.ex`).** `get "/client/v1/rooms/:room_id/hierarchy"` (reaches
Protected via the catch-all `/_matrix` forward, like relations). Param validation:
`suggested_only` must be `"true"`/`"false"` else 400 `M_INVALID_PARAM`; negative/non-int
`limit` → 400; `limit > 1000` clamped; `max_depth` negative/non-int → 400. Acting user =
`conn.assigns[:current_user]`. Response `{rooms: [...], next_batch}` (next_batch omitted
when empty); `room_type` omitted when empty.

### Security

Root 403 fires before traversal — a private space's existence/children/members never leak
to a non-member (integration test asserts no `rooms` key in the 403 body). Hidden rooms are
excluded from output but traversed. Pagination token opaque + fail-closed. BFS cycle-safe
+ depth-bounded; limit clamped ≤ 1000. SQL parameterised; let-it-crash with Matrix error
envelopes; acting user from token (no path/body user → no IDOR).

### File List

- `core/priv/migrations/000005_space_hierarchy_index.up.sql` (new)
- `core/priv/migrations/000005_space_hierarchy_index.down.sql` (new)
- `proto/core.proto` (GetSpaceHierarchy rpc + request/response/HierarchyRoom messages)
- `core/lib/pb/core.pb.ex` (flat-file: 3 message structs)
- `core/lib/pb/core_grpc.pb.ex` (flat-file: GetSpaceHierarchy rpc)
- `core/lib/nebu/matrix/space_hierarchy.ex` (new — BFS + visibility + pagination)
- `core/lib/nebu/matrix/event_dispatcher/server.ex` (get_space_hierarchy/2 + resolvers/summary helpers)
- `core/lib/nebu/matrix/room/db.ex` (get_space_children/1)
- `core/lib/nebu/web/router/protected.ex` (GET /client/v1/.../hierarchy + param validation)
- `core/test/nebu/matrix/space_hierarchy_test.exs` (new — 9 unit tests, AT1-4 + pagination + cycle)
- `core/test/nebu/matrix/space_hierarchy_integration_test.exs` (new — AT5-8, :integration)

### Verification

`mix test test/nebu/matrix/ --warnings-as-errors`: compiles clean (no warnings), 471
passed, 2 skipped, 71 excluded, 41 failed. All 41 failures are the pre-existing DB-less
`could not lookup Ecto repo Nebu.Repo` set (files: `upgrade_room*`, etc. — untouched here);
0 new failures. The 9 S3 unit tests pass; the 8 S3 integration tests are correctly excluded
(no DB). `make proto` was NOT run (flat-file edits per S1/S2 precedent → no spurious nested dir).

### Status: review
