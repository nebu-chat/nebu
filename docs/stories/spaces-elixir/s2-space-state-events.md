---
story_id: spaces-elixir-s2-state-events
title: "Spaces S2: generic state-event PUT + m.space.child/parent (Elixir port of epic-15 15.3/15.4)"
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

Add the generic Matrix state-event write endpoint and the Space child/parent links so a
Space hierarchy can be built. Ports epic-15 stories 15.3 (m.space.child) + 15.4
(m.space.parent security check). Current Elixir has NO generic state PUT route — only a
private `emit_state_event/5` used internally by room upgrade.

**Kassandra S1 forward-warning (MUST honour):** this endpoint lets clients write arbitrary
state-event content. Enforce: power-level authorization; an allowlist of writable state
event types; and DO NOT let this generic path forge server-authoritative state
(`m.room.member`, `m.room.power_levels`, `m.room.create` must NOT be settable through the
generic content PUT — membership/PL/create have their own authorized paths).

## Story

As a Space admin,
I want to manage child rooms and parent links via
`PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}`,
So that I can build and maintain Space hierarchies (m.space.child) and link rooms back to
their parent Space (m.space.parent).

## Acceptance Criteria

**AC1 — generic state PUT route + power-level check:**
`PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` (and the
no-state-key variant `.../state/{eventType}`) authenticated; the sender must be a room
member with power_level ≥ the room's `state_default` (from m.room.power_levels). On success
returns `200 {"event_id": "..."}`; insufficient PL → `403 M_FORBIDDEN`; non-member → 403.

**AC2 — allowlist of writable state event types:**
Only an allowlist of content state events is writable through this generic endpoint:
`m.space.child`, `m.space.parent`, `m.room.name`, `m.room.topic`, `m.room.avatar`,
`m.room.join_rules`, `m.room.canonical_alias`, `m.room.history_visibility`,
`m.room.guest_access`. A request for a non-allowlisted type (esp. `m.room.member`,
`m.room.power_levels`, `m.room.create`) → `403 M_FORBIDDEN` (those have dedicated authorized
paths and must NOT be forgeable here).

**AC3 — m.space.child stored + visible in sync:**
`PUT /rooms/{spaceId}/state/m.space.child/{childRoomId}` with `{"via": ["nebu.local"],
"suggested": false}` by an authorized sender stores the event; it appears in `/sync` state.
Empty content `{}` (unlink) is accepted (200 with event_id), effectively removing the link.

**AC4 — m.space.parent requires membership of the parent space (security):**
`PUT /rooms/{roomId}/state/m.space.parent/{parentSpaceId}`:
- sender member of parent space (+ sufficient PL in the child room) → 200 stored;
- sender NOT a member of the parent space → `403 M_FORBIDDEN` ("Sender is not a member of
  the parent space");
- parentSpaceId references a non-existent room → `404 M_NOT_FOUND`.

**AC5 — name/topic denormalisation parity:**
A `m.room.name` written via this generic PUT also updates `rooms.name` (reuse
update_room_name), keeping the Admin UI in sync (same for topic if a rooms.topic column is
used). m.space.child/parent do not touch denormalised columns.

**AC6 — content size + injection safety:**
Content is bounded (existing body cap) and stored as JSON; state_key and content values are
never interpolated into SQL (parameterised). No server-authoritative top-level event field
(sender, type, room_id) is client-settable.

## Acceptance Tests (TDD — written FIRST)
1. PUT m.space.child by authorized member → 200 + appears in /sync; empty content unlink → 200 — ExUnit :integration
2. PUT by non-member / insufficient PL → 403 — ExUnit :integration
3. PUT non-allowlisted type (m.room.member / m.room.power_levels / m.room.create) → 403 — ExUnit :integration (security)
4. PUT m.space.parent: member of parent → 200; non-member of parent → 403; non-existent parent → 404 — ExUnit :integration
5. PUT m.room.name via generic PUT → rooms.name updated — ExUnit :integration
6. backend set_room_state unit: allowlist + PL check (Repo-less via injectable deps) — ExUnit

## Dev Notes

### Files likely changed
- `proto/core.proto` — add `SetRoomState` RPC + `SetRoomStateRequest{room_id, sender_id,
  event_type, state_key, content_json}` / response `{event_id}` (or reuse a generic shape).
  Regenerate via `make proto`. Use next free field/rpc numbers.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` — `set_room_state/2`: lazy-start room if
  needed; verify sender membership; check PL ≥ state_default (reuse PowerLevels.can? /
  the existing PL helpers as send_event does); enforce the allowlist (AC2); for
  m.space.parent run the parent-space existence + parent-membership check (AC4); emit via
  the existing `emit_state_event/5` (or Room.Server state path) so the event is signed +
  persisted + fanned out to /sync subscribers. Update rooms.name on m.room.name (AC5).
- `core/lib/nebu/web/router/protected.ex` — add
  `put "/client/v3/rooms/:room_id/state/:event_type/:state_key"` and
  `put "/client/v3/rooms/:room_id/state/:event_type"` (empty state_key). Acting user =
  conn.assigns[:current_user]. Map response/errors via send_json/send_error.
- `core/test/nebu/matrix/…_test.exs` — new ExUnit tests (1–6).

### Constraints / security (required)
- Allowlist is the security boundary — m.room.member/power_levels/create MUST be rejected
  (403) so this generic path can't forge membership, escalate power, or rewrite create.
- PL check mirrors send_event's authorization; non-member → 403; lazy room-restart like the
  other handlers.
- m.space.parent: parent-space membership check (AC4) is the story-15.4 security requirement.
- ADR-018 inline SQL (parameterised), let-it-crash with proper Matrix error envelopes,
  ADR-020, acting-user-from-token, content bounded by the existing body cap.

### Reference (old Go stories — parity only, do NOT port Go)
`git show origin/feature/epic-15:docs/stories/matrix-spaces/m-space-child-state-event-whitelist-core-validation.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/m-space-parent-state-event-whitelist-security-check.md`

## Dev Agent Record

### Implementation Plan / Notes

- **proto** (`proto/core.proto`): added `rpc SetRoomState(SetRoomStateRequest) returns (SetRoomStateResponse)`
  plus messages `SetRoomStateRequest{room_id, sender_id, event_type, state_key, content_json}`
  and `SetRoomStateResponse{event_id}`. Regenerated via `make proto`; protoc 0.17.0 emitted a
  spurious nested `core/lib/pb/core/` dir and did not touch the flat 0.16.0 files, so (as S1 did)
  the two message blocks were applied as minimal field-line edits to the flat `core/lib/pb/core.pb.ex`
  and the `rpc :SetRoomState` line added to `core/lib/pb/core_grpc.pb.ex`; the spurious dir was removed.

- **`set_room_state/2`** (`core/lib/nebu/matrix/event_dispatcher/server.ex`):
  1. **Allowlist FIRST** (`@writable_state_types`) — rejected types raise `permission_denied`
     before the room is touched, so `m.room.member` / `m.room.power_levels` / `m.room.create`
     (and any other type) cannot be forged or even probe room existence (AC2, SECURITY).
  2. Decode `content_json` (malformed → `%{}`, which is also the m.space.child unlink semantics).
  3. `fetch_room_state/1` lazy-starts the Room GenServer on `:noproc` (mirrors `get_room_state/2`).
  4. Membership + `PowerLevels.can?(pl, sender, :change_state)` (PL ≥ state_default) → else 403 (AC1).
  5. For `m.space.parent`: `check_parent_space_membership/2` — `rooms_db_module().get_room_create_event/1`
     for existence (404 if absent) + parent-room membership (403 "Sender is not a member of the
     parent space") (AC4).
  6. Emit via the existing private `emit_state_event/5` (signs + persists + `:pg` fan-out to /sync);
     top-level event fields are server-built there (AC6 — no client-settable sender/type/room_id).
  7. On `m.room.name`, also call `rooms_db_module().update_room_name/2` (AC5, non-fatal on failure).

- **routes** (`core/lib/nebu/web/router/protected.ex`): added
  `put "/client/v3/rooms/:room_id/state/:event_type/:state_key"` and the no-state-key variant
  `put "/client/v3/rooms/:room_id/state/:event_type"`, both delegating to `do_set_room_state/4`
  (URI-decodes path params, acting user = `conn.assigns[:current_user]`, body → content_json,
  M_BAD_JSON on parse error, `call_core` + `send_json`/`send_error`).

### Completion Notes

- TDD: 13 Repo-less ExUnit unit tests (`set_room_state_test.exs`) written FIRST → confirmed RED
  (`set_room_state/2 is undefined`), then GREEN after implementation. 7 `:integration` HTTP tests
  (`spaces_state_events_integration_test.exs`) cover Acceptance Tests 1–5 end-to-end via the router.
- `mix test test/nebu/matrix/ --warnings-as-errors`: 462 passed (+13 vs baseline 449), 41 failed.
  All 41 failures are PRE-EXISTING Repo-less integration failures (`could not lookup Ecto repo
  Nebu.Repo`) — identical count with the S2 code stashed out → zero regressions introduced.
- `:integration` tests are excluded from `mix test` (run via `make test-integration` with Postgres).

### File List

- `proto/core.proto` (modified) — SetRoomState RPC + request/response messages.
- `core/lib/pb/core.pb.ex` (modified) — Core.SetRoomStateRequest / Core.SetRoomStateResponse structs.
- `core/lib/pb/core_grpc.pb.ex` (modified) — `rpc :SetRoomState` registration.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` (modified) — `set_room_state/2` +
  `fetch_room_state/1` + `check_parent_space_membership/2` + `@writable_state_types` allowlist.
- `core/lib/nebu/web/router/protected.ex` (modified) — generic state PUT routes + `do_set_room_state/4`.
- `core/test/nebu/matrix/event_dispatcher/set_room_state_test.exs` (new) — 13 backend unit tests.
- `core/test/nebu/matrix/spaces_state_events_integration_test.exs` (new) — 7 :integration HTTP tests.

### Change Log

- 2026-06-21 — Implemented Spaces S2: generic state-event PUT + m.space.child/parent with allowlist
  + power-level + parent-space security checks. Status → review.
