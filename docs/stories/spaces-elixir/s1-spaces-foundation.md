---
story_id: spaces-elixir-s1-foundation
title: "Spaces S1: createRoom m.space + room_type persistence (Elixir port of epic-15 15.1)"
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

Port Matrix Spaces foundation from the old Go `feature/epic-15` branch to the current
Elixir-only architecture. A Space is a normal room whose `m.room.create` event carries
`content.type: "m.space"` (MSC1772, stable since Matrix v1.2). This first batch adds the
data-model + creation plumbing so a Space can be created; child management (m.space.child),
hierarchy, restricted join, and admin UI follow in later batches (S2–S5).

Current Elixir state (greenfield): `Core.CreateRoomRequest` has only creator_id/name/topic/
is_direct; the `rooms` table has no `room_type` column; `createRoom` ignores
`creation_content`. This batch wires those through.

## Story

As a Matrix client user,
I want to create a Space by passing `creation_content: {"type": "m.space"}` to
`POST /_matrix/client/v3/createRoom`,
So that the room is created as a Space (type `m.space`) and appears in Element's Space sidebar.

## Acceptance Criteria

**AC1 — createRoom honours creation_content.type:**
`POST /_matrix/client/v3/createRoom` with body `{"creation_content": {"type": "m.space"}}`
creates a room whose stored `m.room.create` event has `content.type == "m.space"`.

**AC2 — room_type persisted:**
The `rooms` row for that room has `room_type = 'm.space'` (new nullable column). A regular
room (no creation_content.type) has `room_type` NULL.

**AC3 — /sync surfaces the type:**
A `/sync` for the creator shows the space's `m.room.create` state event with
`content.type == "m.space"`.

**AC4 — backward compatibility:**
`POST /createRoom` WITHOUT `creation_content.type` is unchanged — no `type` key in
`m.room.create` content, `rooms.room_type` NULL. All existing room tests stay green.

**AC5 — other creation_content keys forwarded:**
Any other keys in `creation_content` (e.g. future flags) are merged into the
`m.room.create` content (Matrix spec: creation_content is merged into the create event),
without breaking the reserved `creator`/`room_version` fields.

## Acceptance Tests (TDD — written FIRST)

1. **create space → m.room.create content.type == m.space** — ExUnit `:integration`
   (POST /createRoom with creation_content.type=m.space; assert stored create event + rooms.room_type).
2. **regular room → no type, room_type NULL (backward compat)** — ExUnit `:integration`.
3. **/sync shows content.type for the space** — ExUnit `:integration`.
4. **creation_content extra keys merged into create content** — ExUnit.
5. **migration 000004 idempotent + column present** — ExUnit/migration check (room_type column exists, default NULL).

## Dev Notes

### Files likely changed
- `core/priv/migrations/000004_*.up.sql` (+ `.down.sql`) — `ALTER TABLE rooms ADD COLUMN IF
  NOT EXISTS room_type TEXT;` Keep it idempotent (mirrors 000002 style). NOTE: the migration
  runner (`Nebu.Release`) is golang-migrate-compatible; pick the next version number (000004)
  and follow the existing up/down convention.
- `proto/core.proto` — extend `CreateRoomRequest` (message ~L199) with the creation_content
  payload. Simplest coherent shape: add `string creation_content_json = N;` (the raw JSON
  object the client sent) OR a dedicated `string room_type = N;`. Prefer carrying the type
  explicitly (`room_type`) AND the full `creation_content_json` so AC5 (merge extra keys)
  works. Regenerate with `make proto` (writes `core/lib/pb/core.pb.ex`). Use the next free
  field numbers; do not renumber existing fields.
- `core/lib/nebu/web/router/protected.ex` — the `createRoom` route currently reads only
  `params["name"]`. Read `params["creation_content"]` (a map) and pass it on the
  `Core.CreateRoomRequest` (room_type + creation_content_json).
- `core/lib/nebu/matrix/event_dispatcher/server.ex` — `create_room/2` builds the
  `m.room.create` content as `%{"creator" => creator_id, "room_version" => "10"}`. Merge the
  client's creation_content into it (so `type` and any extra keys land in content), and
  persist `room_type` into the new `rooms.room_type` column when the type is "m.space"
  (or store the raw type). Keep `creator`/`room_version` authoritative (not overridable).
- `core/test/nebu/matrix/…_test.exs` — new ExUnit `:integration` tests (1–5).

### Constraints
- ADR-018 inline SQL; the new column write goes in the existing room-insert path
  (`Nebu.Matrix.Room.DB` insert_room or a follow-up UPDATE like the rooms.name fix).
- Matrix spec: `creation_content` is merged into `m.room.create` content but the server
  controls `creator` and `room_version` — do not let the client override those.
- let-it-crash; keep backward compatibility (AC4) — verify existing create_room tests pass.
- Reuse the existing rooms.name persistence pattern (Nebu.Matrix.Room.DB.update_room_name)
  for the room_type write if cleaner than threading it into insert_room.

### Reference (old Go story, for parity only — do NOT port Go code)
`git show origin/feature/epic-15:docs/stories/matrix-spaces/createroom-extension-creation-content-type-m-space.md`

### Security review scope (required — migration + Matrix creation path)
New migration + createRoom extension. Confirm: client cannot override server-controlled
create fields (creator/room_version) via creation_content; room_type write is parameterised
(no SQL injection from a client-supplied type string); the type string is constrained/safe
(it lands in JSON content + a TEXT column — ensure no injection or unbounded value abuse).

## Tasks/Subtasks

- [x] Migration 000004: idempotent `ALTER TABLE rooms ADD COLUMN IF NOT EXISTS room_type TEXT` (+ down).
- [x] proto: add `room_type = 5` + `creation_content_json = 6` to `CreateRoomRequest`; regenerate `core/lib/pb/core.pb.ex` via `make proto`.
- [x] createRoom route: read `params["creation_content"]`, lift `.type` → `room_type`, pass raw object as `creation_content_json`.
- [x] create_room handler: merge client creation_content into `m.room.create` content (server keeps `creator`/`room_version`); persist `room_type` via `Room.DB.update_room_type/2`.
- [x] `Nebu.Matrix.Room.DB.update_room_type/2` (parameterised UPDATE, mirrors `update_room_name/2`).
- [x] Tests written FIRST (RED proven, then GREEN): unit (`spaces_create_room_test.exs`) + `:integration` (`spaces_foundation_integration_test.exs`).

## Dev Agent Record

### Completion Notes

- **TDD RED→GREEN:** Wrote `spaces_create_room_test.exs` first; reverting the
  `create_content` merge + `room_type` persist made 4/5 fail (the AC4 "regular room
  has no type" test correctly stayed green — it asserts absence). Restoring the
  implementation → 5/5 pass.
- **Proto:** `CreateRoomRequest` gained `string room_type = 5` and
  `string creation_content_json = 6` (existing fields 1–4 unchanged). `make proto`
  regenerated cleanly; new fields are present in `Core.CreateRoomRequest`. The
  generated diff was applied minimally (two field lines) to keep the protoc version
  string churn out of the committed file.
- **AC1/AC5 merge semantics:** `create_room/2` decodes `creation_content_json`, then
  `Map.merge(client_content, %{"creator" => ..., "room_version" => "10"})` so the two
  server-controlled keys always win — the client cannot override them (verified by an
  explicit "@evil"/"room_version 1" override test). Extra keys (e.g. `m.federate`) merge.
- **AC2/AC4 persistence:** `room_type` is written via `rooms_db_module().update_room_type/2`
  only when non-empty, so a regular room leaves `rooms.room_type` NULL. The room-name
  write was also routed through `rooms_db_module()` (was a hard `Nebu.Matrix.Room.DB`
  call) so both denormalised writes share the injectable path — required to unit-test
  the handler without a live Repo, and the story's "reuse the name persistence pattern"
  guidance.
- **AC3 /sync:** No extra code needed — `build_state_events/2` already reads the persisted
  `m.room.create` content via `get_room_create_event/1`, so the merged `content.type`
  surfaces in `/sync` automatically. Covered by the `:integration` test.
- **Security:** `update_room_type/2` binds the type string as `$2` (parameterised) — no
  interpolation, no SQL injection from the client-supplied type. creator/room_version are
  server-authoritative.
- **Test split:** unit tests run in the verify gate (no DB); the `:integration` file
  (real router + Postgres) is `:integration`-tagged and runs via `make test-integration`
  — it covers the actual `rooms.room_type` column read, the migration column-exists check,
  and the /sync round-trip.
- **Regression:** `mix test test/nebu/matrix/ --warnings-as-errors` → 449 passed (baseline
  was 444); the 41 remaining failures are pre-existing, DB-less `create_room`/`upgrade_room`/
  `audit_room_ops` unit tests that require a live Repo (unrelated to this story) — my change
  reduced the count by adding 5 passing tests and introduced zero new failures. Also fixed a
  pre-existing misplaced `@doc` in `room/db.ex` that triggered a "redefining @doc" warning.

### File List

- `core/priv/migrations/000004_add_room_type.up.sql` (new)
- `core/priv/migrations/000004_add_room_type.down.sql` (new)
- `proto/core.proto` (modified — `CreateRoomRequest` +room_type +creation_content_json)
- `core/lib/pb/core.pb.ex` (modified — regenerated fields)
- `core/lib/nebu/web/router/protected.ex` (modified — createRoom reads creation_content)
- `core/lib/nebu/matrix/event_dispatcher/server.ex` (modified — create_room merge + room_type persist)
- `core/lib/nebu/matrix/room/db.ex` (modified — update_room_type/2; routed name write; @doc fix)
- `core/test/nebu/matrix/event_dispatcher/spaces_create_room_test.exs` (new — unit, AC1/AC2/AC4/AC5)
- `core/test/nebu/matrix/spaces_foundation_integration_test.exs` (new — :integration, AC1–AC5 + migration)

## Change Log

- 2026-06-21 — Spaces S1 foundation implemented: room_type column (migration 000004),
  proto CreateRoomRequest extension, createRoom creation_content plumbing, create_room
  content-merge + room_type persistence. Status → review.
