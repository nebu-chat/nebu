---
story_id: create-room-initial-state-conformance
title: "createRoom initial_state: the K8 e2e failure is a test defect; close the real Matrix-spec gaps of initial_state (follow-up dx)"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-16
branch: feature/migrate-to-oauth2
---

# Story: `POST /createRoom` and `initial_state` (follow-up `dx`)

Follow-up `dx` (e2e CI run 2026-10-15) says: "`POST /createRoom` drops `initial_state`, the `m.space.parent` Element sends is lost; scenario K8 `create-room-in-space` is the red regression test."

## Root cause (verified 2026-10-16): the premise of `dx` is wrong

- The server DOES honour `initial_state`: `protected.ex` (`post "/client/v3/createRoom"`) carries the array (cap 64) as `initial_state_json`, `Nebu.Matrix.EventDispatcher.Server.create_room/2` applies it
  after create -> creator join -> power levels and before `name` (`apply_initial_state/3`, since the Go -> Elixir migration, commit 6f94c20c), with a unit suite
  (`create_room_initial_state_test.exs`) and a real-stack API scenario. In the e2e run the API scenario ("createRoom honours the m.space.parent link Element sends in initial_state") PASSED
  (`plain-final-default-tags.log`); only the Element UI scenario K8 failed.
- K8 fails because of the test, not the server: Nebu derives a canonical alias from the room name (story room-canonical-alias-from-name), so Element navigates to `#/room/#e2e-room-in-space-ui-...:localhost`;
  `ElementSpacePage.spaceIdFromUrl()` returns that ALIAS and the step compares it with the `state_key` of the `m.space.parent` event (the real `!room:localhost` id) and looks the "room id"
  up in `/sync` `rooms.join` (keys are room ids): `Got event types: []`, the failure text even names the aliases (`#e2e-space-host-ui-...:localhost`).

So there is no server bug of the kind `dx` describes. The pipeline run therefore (1) fixes the e2e step, (2) uses the Oracle review of `initial_state` against Matrix CS v1.18 to close the real gaps it found
(they are small and in the same code path), (3) records the larger createRoom gaps (`topic`, `invite`, `preset` ...) as separate follow-ups.

## Oracle findings (full text: `_bmad-output/nebu/epics/oauth-broker/step-results/create-room-initial-state-conformance/oracle-context.md`)

Spec order (MUST): create -> creator join -> default power levels (+ `power_level_content_override`) -> `m.room.canonical_alias` (`room_alias_name`) -> preset events -> `initial_state` in array order -> `name` / `topic` -> `invite`.
`initial_state` beats the preset, `name` / `topic` beat `initial_state`. StateEvent schema: `type` required string, `content` required object, `state_key` string (default `""`).

## Decisions

- **D1 (structure is validated BEFORE the room is created, 400 `M_BAD_JSON`).** `initial_state` that is present (and not `null`) but not an array, an entry that is not an object, without a string `type`, with a non-string
  `state_key` or with a missing / non-object `content` answers `400 M_BAD_JSON` and creates nothing (no orphan room). Before: the entry was skipped silently (a non-string `state_key` silently became `""` and could clobber the
  `""` slot), a non-array was ignored. A body that is not valid JSON answers `400 M_NOT_JSON` (like the other JSON routes: login, account data, tags) and a valid JSON body that is not an object (`[1]`, `42`) `400 M_BAD_JSON` (before: both created a nameless room, 200). An EMPTY body stays a valid request (a nameless room, as Synapse allows). The cap of 64 entries stays `400 M_INVALID_PARAM`.
  `null` / missing / `[]` stay no-ops.
- **D2 (privileged types stay skipped, not rejected).** `m.room.create`, `m.room.member`, `m.room.power_levels`, `m.room.encryption` (ADR-011) are still skipped with a warning and the room is created: Element sends
  `m.room.encryption` in `initial_state` when its default E2EE is on, a rejection would break every room creation in Element (the Oracle agrees). The direct `PUT .../state/m.room.encryption` stays `403`; the asymmetry is
  deliberate and documented. Nothing is persisted for these types, the creator keeps power level 100, no foreign membership can be forged.
- **D3 (the forbidden list grows).** `m.room.tombstone` (a brand-new room that claims to be replaced by an arbitrary room) and `m.room.third_party_invite` (federation / 3pid invite machinery Nebu does not have) join the
  forbidden list. Everything else stays honoured (still NOT an allowlist: the Space flow must not break again). Not in scope: the content of `m.room.canonical_alias` is not validated (same as the PUT path, follow-up).
- **D4 (`m.room.name` in `initial_state` keeps the admin list in sync).** Like the PUT path, an `m.room.name` entry with a string `name` also updates the denormalised `rooms.name` column (Admin UI list); a top-level `name`
  (emitted afterwards) still wins in the state AND in the column. The alias derived from the top-level `name` is emitted after `initial_state` and wins over an `m.room.canonical_alias` entry (Nebu feature, documented).
- **D5 (a failing entry fails the creation).** The spec says the server MUST apply the events: when persisting an entry fails (DB error), `create_room` raises, the orphan room is cleaned up and the client gets `500`
  (before: warning and `200` with a half-configured room). Skipped (forbidden / `m.space.parent` guard) entries are unchanged: not a failure, a deliberate rule.
- **D6 (e2e K8).** The e2e step resolves an alias to the room id through `GET /_matrix/client/v1/room_summary/{alias}` (Nebu has no `directory/room` lookup route; the preview resolves local aliases) before comparing; the `@known-failure` tag and the `KNOWN-FAILURES.md` row K8 go.
- **Not in this story (new follow-ups):** the createRoom keys the handler does not read at all: `topic`, `invite` / `invite_3pid` (DMs), `preset` / `visibility`, `room_alias_name`, `room_version` (unknown version must be
  `400 M_UNSUPPORTED_ROOM_VERSION`), `power_level_content_override`; `m.room.canonical_alias` content validation.

## Acceptance Criteria

1. `initial_state` entries with `m.space.parent` and a restricted `m.room.join_rules` are persisted (unchanged): the `m.space.parent` state event with the parent's id as `state_key` exists on the new room (real stack).
2. `initial_state` as an object / string / number, an entry that is not an object, without `type`, with `type: 123`, with `state_key: 5`, with `content` missing / `null` / a string answers `400 M_BAD_JSON`
   and NO room is created (the creator's room count does not grow). `initial_state: null`, missing, `[]` answer 200. 65 entries answer `400 M_INVALID_PARAM`, no room.
3. A request body that is not valid JSON answers `400 M_NOT_JSON`, a JSON body that is not an object `400 M_BAD_JSON`, no room; an empty body / `{}` stays 200.
4. `m.room.tombstone` and `m.room.third_party_invite` in `initial_state` are not persisted (the room is created, 200); `m.room.encryption`, `m.room.create`, `m.room.member` (foreign user), `m.room.power_levels` stay unpersisted (existing tests).
5. `initial_state` `m.room.name` without a top-level `name` sets the state event AND `rooms.name`; with a top-level `name` the later value wins in both.
6. A DB error while persisting an `initial_state` entry raises (no half room, `500`): unit level with a failing `insert_event` for that entry, the orphan room is cleaned up.
7. Order (unchanged, pinned): create < creator member < power levels < `initial_state` entries in array order < `m.room.name`.
8. e2e K8 (`A room created inside a Space via Element Web is linked to the Space server-side`) passes against the isolated stack (one targeted run); tag and `KNOWN-FAILURES.md` row removed.
9. `docs/matrix-api-scope.md` states the `initial_state` contract (honoured, validation, forbidden / skipped types, order, what is not read) and 07-deployment / `follow-ups.md` carry the closed `dx` and the new follow-ups.

## Acceptance Tests

- `server/test/nebu/matrix/event_dispatcher/create_room_initial_state_test.exs` (extended): AC4 (tombstone / third_party_invite), AC5 (rooms.name via the FakeDB), AC6 (failing insert), AC7 order.
- `server/test/nebu/matrix/create_room_initial_state_http_test.exs` (new, `@moduletag :integration`, real stack over HTTP): AC1, AC2, AC3.
- e2e: `e2e/step-definitions/element/create-room-in-space.steps.ts` (alias resolution), scenario K8 un-tagged.

## Result (2026-10-16)

- ATDD: 15 red ExUnit (unit + HTTP) + the e2e step fix. test-review: 2 MAJOR (empty / non-object body, `M_NOT_JSON`) + 5 MINOR applied. Dev: `Server.validate_initial_state/1`, router guard order, forbidden list, `rooms.name` sync, failing entry raises.
  code-review: 0 MAJOR, 4 MINOR applied (docs, value-free ERROR log, NUL character -> 400, stale comment). Kassandra: CLEAN, 1 LOW (the NUL case) fixed, 8 INFO (`ei`, `eg`).
- Verified: 36 server tests (unit + HTTP on the real stack) green; e2e (isolated stack, one targeted run of `element/spaces` + `element/room`): 10 passed incl. K8 (`step-results/create-room-initial-state-conformance/e2e-k8-spaces-room-run.log`).
- Behaviour change for running instances: a createRoom with a malformed `initial_state` / a non-JSON body / a NUL character is now a 400 (before: a nameless or half-configured room, 200); a failing `initial_state` entry is a 500 without a half room (before: 200). No change for Element's normal requests.
