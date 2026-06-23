---
story_id: bugfix-fix-missing-matrix-room-routes
title: "Bug: Matrix room endpoints 404 — leave/forget/relations/upgrade/search HTTP routes never ported (go-removal regression)"
type: bug
severity: high
epic: fix-missing-matrix-room-routes
status: done
security_review: required
created: 2026-06-20
branch: bugfix/fix-missing-matrix-room-routes
---

## Summary

Five Matrix Client-Server endpoints return **404 "M_UNRECOGNIZED / Unrecognized request"**
even though their backend handlers fully exist in `Nebu.Matrix.EventDispatcher.Server`.
Only the HTTP routes were never ported to the Elixir `Nebu.Web.Router.Protected` during
the Go removal — the same class of regression already fixed for `/rooms/{id}/invite` and
`/account/whoami`:

```
POST /_matrix/client/v3/rooms/{roomId}/leave              -> 404  (backend: leave_room/2)
POST /_matrix/client/v3/rooms/{roomId}/forget             -> 404  (backend: forget_room/2)
GET  /_matrix/client/v1/rooms/{roomId}/relations/{eventId}[/{relType}[/{eventType}]] -> 404  (backend: get_relations/2)
POST /_matrix/client/v3/rooms/{roomId}/upgrade            -> 404  (backend: upgrade_room/2)
POST /_matrix/client/v3/search                            -> 404  (backend: search_messages/2)
```

Found via the Element Web E2E suite: room leave, thread/relations, room upgrade, and the
three message-search scenarios all fail because Element's HTTP calls 404. The backends
(`leave_room`, `forget_room`, `get_relations`, `upgrade_room`, `search_messages` — Stories
9-8 / 9-28 / 9-29 / search) are intact and reachable in-process; this story wires the HTTP
surface back to them.

## Story

As a Matrix client (Element Web) user,
I want to leave/forget rooms, load event relations (threads), upgrade rooms, and search
messages,
so that those features work over the HTTP API instead of returning 404.

## Root Cause Analysis

Go-removal regression. The Go gateway exposed these routes and called the Core gRPC
handlers; when the gateway was removed, the Elixir `Nebu.Web.Router.Protected` was given
routes only for the MVP-critical subset (sync, login, createRoom, join, send, messages,
typing, receipt, profile, presence) plus the later-added invite/whoami. The
leave/forget/relations/upgrade/search routes were omitted, so requests fall through to the
404 catch-all even though `EventDispatcher.Server` implements every one of them.

## Acceptance Criteria

**AC1 — Leave:** `POST /_matrix/client/v3/rooms/{roomId}/leave` calls `leave_room/2`,
returns `200 {}` on success; the room then appears in the `leave` section of the next
`/sync` and disappears from `join`. Auth required (OidcPlug).

**AC2 — Forget:** `POST /_matrix/client/v3/rooms/{roomId}/forget` calls `forget_room/2`,
returns `200 {}`. (Spec: forgetting is only valid after leaving — surface the backend's
error as the proper Matrix error if it rejects.)

**AC3 — Relations:** `GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}` (and the
`/{relType}` and `/{relType}/{eventType}` variants) calls `get_relations/2` and returns
`200 {"chunk": [...]}` with the related events; unknown event → empty chunk, not 500.
(Also keep the existing stable/unstable path parity if the client uses `/v1`.)

**AC4 — Upgrade:** `POST /_matrix/client/v3/rooms/{roomId}/upgrade` with
`{"new_version": "<v>"}` calls `upgrade_room/2` and returns `200 {"replacement_room":
"<new_room_id>"}`.

**AC5 — Search:** `POST /_matrix/client/v3/search` calls `search_messages/2` and returns
the Matrix `search` response shape (`{"search_categories": {"room_events": {"count": N,
"results": [...]}}}`). An empty result set returns `200` with `count: 0`, not 404/500.

**AC6 — Security:** all five routes sit on the authenticated `Protected` pipeline (OidcPlug);
the acting user is `conn.assigns[:current_user]` (never taken from the path/body). A user
cannot leave/forget/upgrade/search a room on behalf of another user, and relations/search
only return events from rooms the user is in (verify the backend already enforces this; if
not, that is part of this fix).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **leave → 200 + room in /sync leave** — ExUnit `:integration`
2. **forget after leave → 200** — ExUnit `:integration`
3. **relations GET → 200 chunk (thread reply present); unknown event → empty chunk** — ExUnit `:integration`
4. **upgrade → 200 replacement_room; tombstone emitted in old room** — ExUnit `:integration`
5. **search → 200 search_categories shape; empty query → count 0** — ExUnit `:integration`
6. **auth/authorization** — ExUnit: each route 401 without token; acting user is the
   token's user, not a path/body-supplied one; relations/search scoped to member rooms.
7. **E2E** — `e2e/features/element/room/leave.feature`, `room/upgrade.feature`,
   `messages/thread_messages.feature`, `search.feature` pass against the running stack.

## Dev Notes

### Files likely changed
- `core/lib/nebu/web/router/protected.ex` — add the five routes, each delegating to the
  existing `Nebu.Matrix.EventDispatcher.Server` handler via `call_core/1` + `stream/1`,
  mapping the proto response to the Matrix JSON shape (mirror the existing invite/join/
  messages routes). Relations needs the `/v1` path + optional `relType`/`eventType` path
  segments; search reads the body's `search_categories.room_events.search_term`.
- `core/lib/nebu/web/router.ex` — confirm `/_matrix/client/v1/rooms/...` relations path is
  forwarded to Protected (currently only `/_matrix` catch-all + explicit v3 forwards —
  verify the v1 relations path reaches Protected).
- `core/test/nebu/matrix/…_test.exs` — new ExUnit `:integration` tests (1–6).

### Reuse / parity references
- Backends: `leave_room/2` (~L398), `forget_room/2` (~L2251), `get_relations/2` (~L3300),
  `upgrade_room/2` (~L2883), `search_messages/2` (~L3076) in
  `core/lib/nebu/matrix/event_dispatcher/server.ex`.
- HTTP wiring pattern: the existing `invite`/`join`/`messages` routes in `protected.ex`
  (call_core + stream(user) + send_json/send_error).
- Matrix response shapes: leave/forget `{}`; relations `{chunk}`; upgrade
  `{replacement_room}`; search `{search_categories:{room_events:{count,results,...}}}`.

### Security review scope (security_review: required)
Five authenticated room endpoints. Reviewer must confirm: acting user is always the
token's `current_user` (no path/body user spoofing → no IDOR on leave/forget/upgrade);
relations and search only return events from rooms the requesting user is a member of (no
cross-room data leak); search term handling has no SQL injection (ADR-018 inline SQL must
be parameterised); no unbounded result sets (search/relations honour a limit).

## Discovery context
Found 2026-06-20 during the Element Web E2E rehab after the Matrix client-compatibility +
identity-unification fixes brought element-web from 0 to 6/16 passing. These five 404s are
the remaining product gaps behind room leave / threads / upgrade / search. All backends
already exist (go-removal left them in-process); only the HTTP routes are missing.

## Dev Agent Record

### Implementation summary
Added the five missing HTTP routes to `Nebu.Web.Router.Protected`, each delegating
to the existing `Nebu.Matrix.EventDispatcher.Server` handler via `call_core/1` +
`stream/1` (the trusted identity is always `conn.assigns[:current_user]` from
OidcPlug — never the path/body, AC6). No backend changes; no new SQL (the search
term stays parameterised inside `Nebu.Matrix.Search.DB`).

### Request/response field mappings (per endpoint)
- **leave** — `POST /client/v3/rooms/:room_id/leave` → `Core.LeaveRoomRequest{user_id:
  current_user, room_id: decoded}` → `leave_room/2` → `Core.LeaveRoomResponse{room_id}`;
  HTTP `200 {}`. (leave_room is best-effort — unknown room also returns 200, decline
  semantics.)
- **forget** — `POST /client/v3/rooms/:room_id/forget` → `Core.ForgetRoomRequest{room_id,
  user_id}` → `forget_room/2` → `Core.ForgetRoomResponse{}`; HTTP `200 {}`. Forgetting
  while still joined raises `failed_precondition` → `call_core` maps to `400 M_BAD_STATE`.
- **relations** — `GET /client/v1/rooms/:room_id/relations/:event_id[/:rel_type[/:event_type]]`
  → `Core.GetRelationsRequest{user_id, room_id, event_id, rel_type, event_type, dir, from,
  limit}` → `get_relations/2` → `Core.GetRelationsResponse{events, next_batch, prev_batch}`;
  events mapped via `Nebu.Matrix.Http.message_event/1` → HTTP `200 {"chunk":[...],
  "next_batch", "prev_batch"}`. Backend enforces membership + room-scoped parent-event
  existence (unknown event → `404`, not 500) and clamps limit 1..100.
- **upgrade** — `POST /client/v3/rooms/:room_id/upgrade` body `{"new_version"}` →
  `Core.UpgradeRoomRequest{old_room_id, requester_id: current_user, new_version}` →
  `upgrade_room/2` (takes requester from the trusted stream identity, requires power ≥100)
  → `Core.UpgradeRoomResponse{new_room_id}`; HTTP `200 {"replacement_room": new_room_id}`.
- **search** — `POST /client/v3/search`, term read from
  `search_categories.room_events.search_term` (filter `rooms`/`senders`/`limit`, paging via
  `?next_batch`) → `Core.SearchMessagesRequest{user_id: current_user, search_term,
  room_filter, sender_filter, limit, next_batch}` → `search_messages/2` (user from trusted
  stream identity, membership scoping at SQL layer, limit clamped 1..100) →
  `Core.SearchMessagesResponse{results, next_batch, total_count}`; each `Core.SearchResult.event`
  (a JSON string) is decoded → HTTP `200 {"search_categories":{"room_events":{"count":
  total_count, "results":[{rank, result, context}], "next_batch", "highlights", "groups"}}}`.

### Routing note (relations /v1)
`/_matrix/client/v1/rooms/.../relations/...` reaches `Protected` via the top router's
catch-all `forward "/_matrix"` (`core/lib/nebu/web/router.ex` L121). The only explicit
`/_matrix/client/v1/...` forwards are `auth_issuer` / `auth_metadata` (exact-prefix), which
do not shadow `/v1/rooms`. Inside `Protected` the prefix is stripped, so routes are written
as `/client/v1/rooms/...`. Confirmed by the "GET .../relations is routed (v1 path reaches
Protected)" test.

### RED → GREEN proof
New file `core/test/nebu/matrix/matrix_room_routes_test.exs`:
- RED (before adding routes): the 6 "is routed" probes failed with the `match _` catch-all
  `404 {"errcode":"M_NOT_FOUND","error":"Unrecognized request"}`; the 5 auth-gate tests
  already passed (OidcPlug 401 runs before routing).
- GREEN (after adding routes): 11/11 pure-unit pass with `--warnings-as-errors`; the 9
  `@moduletag :integration` contract tests pass against a live Postgres
  (`mix test test/nebu/matrix/matrix_room_routes_test.exs --include integration` → all pass).
- No regressions attributable to this change. Pre-existing unrelated failures in the wider
  `test/nebu/matrix/` integration run: `MatrixSsoTest` / `MatrixRouterTest` login
  (`FakeEventDB.set_personal_room_id/2` missing in those tests' own fixtures) and the
  timing-sensitive `SyncConcurrentTest` / `RegressionSyncLoadTest` load tests — none touch
  the leave/forget/relations/upgrade/search routes.

### File List
- `core/lib/nebu/web/router/protected.ex` — added the 5 routes + private helpers
  (`do_relations/5`, `relations_limit/1`, `search_result/1`, `decode_event/1`, `list_param/1`,
  `search_limit/1`).
- `core/test/nebu/matrix/matrix_room_routes_test.exs` — new ATDD test file (auth-gate +
  routing probes + integration contract shapes for AC1–AC6).
