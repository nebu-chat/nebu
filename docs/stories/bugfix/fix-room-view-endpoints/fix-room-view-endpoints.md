---
story_id: bugfix-fix-room-view-endpoints
title: "Bug: Matrix room-view endpoints 404 — members/event(/{id})/read_markers HTTP routes missing (go-removal regression)"
type: bug
severity: high
epic: fix-room-view-endpoints
status: done
security_review: required
created: 2026-06-20
branch: bugfix/fix-missing-matrix-room-routes
---

## Summary

Three more Matrix Client-Server endpoints that a real client (Element Web) calls while
rendering a room return **404**, after the earlier batch (leave/forget/relations/upgrade/
search) was fixed. Same go-removal class: the backend logic exists in-process; only the
HTTP route is missing (or, for read_markers, a tiny no-op handler is needed).

```
GET  /_matrix/client/v3/rooms/{roomId}/members             -> 404  (backend: get_room_state/2 → state_events / members)
GET  /_matrix/client/v3/rooms/{roomId}/event/{eventId}     -> 404  (backend: get_event/2 ~L3362)
POST /_matrix/client/v3/rooms/{roomId}/read_markers        -> 404  (NO backend — Nebu has no fully-read marker store)
```

Observed in the Element Web E2E run (core logs) while opening rooms / loading threads.

## Story

As a Matrix client (Element Web) user,
I want the member list, single-event fetch, and read-marker set to work over HTTP,
so that the room view and thread loading complete instead of 404ing.

## Root Cause Analysis

Go-removal regression (same as fix-missing-matrix-room-routes). `get_room_state/2` and
`get_event/2` survive in `Nebu.Matrix.EventDispatcher.Server`; their HTTP routes were
never ported to `Nebu.Web.Router.Protected`. `read_markers` has no backend — Nebu tracks
read receipts but not a separate `m.fully_read` marker; a spec-valid no-op (200 {}) is the
right MVP behaviour (clients tolerate it; the marker is best-effort UI state).

Also investigate the **relations 403** seen for a second user (marie) who is invited+joined
via room-setup but whom `get_relations` rejected with `permission_denied` — determine
whether the Room GenServer membership state genuinely lacks the user (product bug) or it
was test-timing (room not yet synced). If it is a real membership-state gap, fix it;
otherwise document it as test-timing and leave the backend as-is.

## Acceptance Criteria

**AC1 — Members:** `GET /_matrix/client/v3/rooms/{roomId}/members` returns
`200 {"chunk": [<m.room.member state events>]}` for a member of the room; 403 for a
non-member; auth required. Built from `get_room_state/2` (filter state_events to
`type == "m.room.member"`).

**AC2 — Single event:** `GET /_matrix/client/v3/rooms/{roomId}/event/{eventId}` returns
`200 <event JSON>` for an event in a room the user is a member of; 404 for an unknown
event; 403 for a non-member. Delegates to `get_event/2`.

**AC3 — Read markers:** `POST /_matrix/client/v3/rooms/{roomId}/read_markers` returns
`200 {}` (accepts `m.fully_read` / `m.read` body; no-op since there is no marker store).
If the body carries `m.read`, it MAY forward to the existing receipt path, but a 200 no-op
is acceptable for MVP.

**AC4 — relations 403 triage:** either (a) fix the membership-state gap so an invited+joined
user's `get_relations` succeeds, with a regression test, or (b) document it as test-timing
with evidence and no code change.

**AC5 — Security:** all routes authenticated (OidcPlug); acting user from
`conn.assigns[:current_user]` only; members/event scoped to the requester's membership
(no cross-room leak); no IDOR on read_markers.

## Acceptance Tests (written FIRST)
1. members → 200 chunk of m.room.member events (member); 403 non-member — ExUnit :integration
2. event → 200 for known event (member); 404 unknown; 403 non-member — ExUnit :integration
3. read_markers → 200 {} — ExUnit :integration
4. auth: each route 401 without token; acting user is token user — ExUnit
5. relations 403 triage test (regression if product fix) — ExUnit :integration
6. E2E: thread_messages / receive room-view loading no longer 404 on members/event

## Dev Notes
- Wire routes in `core/lib/nebu/web/router/protected.ex` mirroring the existing
  members-less get_room_state usage in the initialSync handler + the join/messages routes.
- members: call get_room_state, filter state_events to m.room.member, map via the state
  serializer (reuse the initial_sync_state_event/3 shape or message_event where apt).
- event: call get_event/2 → map Core.Event → Matrix event JSON (reuse message_event/1).
- read_markers: 200 {} no-op (document why).
- ADR-018, let-it-crash w/ proper Matrix errors, ADR-020, acting-user-from-token.

### Security review scope (required)
Members/event are room-scoped reads — confirm membership enforcement (no cross-room
leak), acting-user-from-token (no IDOR), proper error envelopes.

## Discovery context
Found 2026-06-20 continuing the Element Web E2E rehab after the first room-routes batch
(element 8/16). Backends for members/event already exist; read_markers is a no-op stub.

## File List
- `core/lib/nebu/web/router/protected.ex` — added 3 routes (members, event/{eventId}, read_markers)
- `core/test/nebu/matrix/matrix_room_view_routes_test.exs` — new ATDD test file (14 tests)

## Dev Agent Record

### Implementation summary
Pure go-removal regression fix: backends `get_room_state/2` and `get_event/2` already
existed in `Nebu.Matrix.EventDispatcher.Server`; only the HTTP routes were missing.
All three routes added to `Nebu.Web.Router.Protected` (authenticated pipeline), reusing
the established `call_core/stream(user)/send_json/send_error` pattern. No new SQL (ADR-018),
no new dependency, acting user always from `conn.assigns[:current_user]` (no path/body user → no IDOR).

**Routes + field mappings:**

1. **GET .../members** → `get_room_state/2` with `event_type: ""`, `state_key: ""`.
   Filters `resp.state_events` to `type == "m.room.member"`, maps each via the existing
   `initial_sync_state_event/3` flattener (Core.SyncRoomStateEvent → Matrix state-event JSON:
   type, state_key, content, sender, room_id, synth event_id, origin_server_ts). Returns
   `200 {"chunk": [...]}` — full member EVENTS, not just user ids. Membership enforced by the
   backend (non-member → 403, no cross-room leak).

2. **GET .../event/{eventId}** → `Core.GetEventRequest{room_id, event_id, user_id}` → `get_event/2`
   → `resp.event` (Core.Event) mapped via the shared `message_event/1` (event_id, room_id,
   sender, type, content, origin_server_ts, +state_key when present). Returns the event JSON
   directly. Backend enforces membership (403) and unknown-event (404), surfaced via `send_error`.

3. **POST .../read_markers** → `200 {}` no-op. Nebu has no `m.fully_read` marker store (it
   tracks read RECEIPTS via /receipt only); a 200 {} is spec-valid and clients tolerate it.
   Deliberately does NOT forward `m.read` to avoid double-counting a receipt the client also
   sets via /receipt. Authenticated; acting user is the token user → no IDOR.

### AC4 — relations-403 triage VERDICT: **test-timing, no code change**
Wrote an integration test (`invited+joined second user's get_relations does NOT 403`) that
invites AND joins a second user (marie) to a room, then calls `get_relations` as marie.
**Result: 200, not 403.** Root cause of the E2E 403 was test-timing, not a membership-state
bug. `Nebu.Matrix.Room.Server.join/2` is a synchronous `GenServer.call` that adds the user
to the in-memory `members` MapSet (server.ex:286) BEFORE returning; `get_relations` checks
exactly that MapSet (`MapSet.member?(state.members, user_id)`, server.ex:3321). So a user who
has completed join IS a member. The E2E 403 occurred because the second user called
get_relations before its join had propagated/synced in the browser flow. Backend left as-is;
the regression test documents the correct behaviour.

### RED → GREEN proof
- **RED:** with the routes missing, the 3 "routes are wired" probes failed with the 404
  catch-all (`M_NOT_FOUND "Unrecognized request"`); the 3 auth-gate tests passed (401 before
  any handler) — `3/6 passed` excluding integration.
- **GREEN (unit, DB-less container):** `6 passed, 8 excluded`.
- **GREEN (integration, live compose stack):** `14 passed` (6 unit + 8 integration), incl. the
  AC4 triage test. `make redeploy` applied; live smoke `GET .../members` returns 401 (route
  wired) instead of the previous 404.

### Test notes
The 41 failures seen in the DB-less `mix test test/nebu/matrix/` run are all the pre-existing
`could not lookup Ecto repo Nebu.Repo` infra class (every `:integration` test needs the live
stack) — not introduced by this story; they pass against the compose stack. No
compile/warnings-as-errors errors were introduced.

## Change Log
- 2026-06-20: Added members / event / read_markers HTTP routes to Protected router; new
  ATDD test file; AC4 relations-403 triaged as test-timing (no code change). Status → review.
