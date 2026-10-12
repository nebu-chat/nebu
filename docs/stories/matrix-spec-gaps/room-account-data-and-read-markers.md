---
story_id: room-account-data-and-read-markers
title: "Bug: room-scoped account data, m.fully_read protection and read_markers are missing/no-op"
type: bug
severity: medium
epic: matrix-spec-gaps
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-08
branch: bugfix/sync-room-account-data
---

## Summary

Origin: pflichten-audit v1.11→v1.15 flagged "per-room `account_data` in /sync is always `[]`". Oracle verification (2026-10-08,
see `_bmad-output/nebu/epics/matrix-spec-gaps/step-results/room-account-data-and-read-markers/oracle-context.md`) shows:
this is NOT a v1.12 MUST violation (Nebu does not advertise v1.12 and the modules are optional in every profile), but a
high-impact **feature gap** plus **two real MUST violations**:

1. The module "Client Config" is implemented for the GLOBAL scope only (`Nebu.Matrix.AccountDataStore`, durable PostgreSQL).
   Room-scoped account data has no endpoints (`PUT/GET /user/{userId}/rooms/{roomId}/account_data/{type}` fall into the
   catch-all 404), no storage, and `rooms.join.<id>.account_data.events` in `GET /sync` is always empty. Consequences for
   clients: "mark as unread" (`m.marked_unread`), the read-up-to marker (`m.fully_read`), room tags (separate story) and any other
   per-room client config are lost.
2. **MUST violation:** `PUT /user/{userId}/account_data/{type}` accepts `m.fully_read` and `m.push_rules`; the spec says servers
   MUST reject setting these (405 `M_BAD_JSON`), for global AND room scope.
3. **MUST violation:** `POST /rooms/{roomId}/read_markers` is offered but is a no-op returning `200 {}`: it never stores
   `m.fully_read` and never forwards `m.read`/`m.read.private` to the receipts path.
4. Minor contract deviation: global PUT with a malformed JSON body stores `{}` and answers 200 instead of 400 `M_NOT_JSON`.

## Story

As a Matrix user on Element or FluffyChat,
I want per-room client data (unread markers, read-up-to marker, future tags) to be stored and synced across my devices,
so that my room state is consistent and the server honors the Client Config and Read Markers contracts.

## Acceptance Criteria

**AC1 — Room account data endpoints:**
`PUT /_matrix/client/v3/user/{userId}/rooms/{roomId}/account_data/{type}` stores the JSON body VERBATIM (opaque, ADR-011, byte-exact round trip, same TEXT storage rule as the global store) per `(user_id, room_id, type)`; `GET` returns it. Errors:
`403 M_FORBIDDEN` when `{userId}` is not the authenticated user; `400 M_INVALID_PARAM` for a syntactically invalid `roomId`;
`400 M_NOT_JSON`/`M_BAD_JSON` for a body that is not a JSON object; `404 M_NOT_FOUND` on GET of an unknown type
(no fallback to the global value of the same type); `405 M_BAD_JSON` when the type is `m.fully_read` or `m.push_rules` (server managed).
GET of `m.fully_read` works once the server has set it.

**AC2 — Durable, cluster-correct storage (ADR-018/020):**
Storage is PostgreSQL via inline SQL (new migration: next free number after the highest existing one at implementation time; verify at merge),
table keyed `(user_id, room_id, type)`, content TEXT verbatim, `created_at`/`updated_at`, and a MONOTONIC per-row
change position usable for incremental sync (see AC4). Survives restart; a PUT on node A is visible to /sync on node B.
Size limit for the content (reject oversized bodies with 413 `M_TOO_LARGE`; pick a sane limit consistent with existing event/body limits) and a per-user cap on the number of room-account-data rows to prevent storage abuse (configurable, documented, safe default).

**AC3 — Initial sync delivery:**
`GET /sync` without `since` delivers all room account data of rooms in `rooms.join` under `rooms.join.<roomId>.account_data.events`
as `[{"type":..., "content":...}]` (content = the verbatim stored JSON).

**AC4 — Incremental sync delivery, correct per DEVICE:**
`GET /sync?since=...` delivers only room account data changed after the position encoded in `since`, in that room's `account_data.events`; a room
whose ONLY change is account data MUST still appear in `rooms.join` (with empty timeline/state) so clients see the change.
Delivery must be correct for MULTIPLE DEVICES of one user: device A syncing first must not make device B miss the change
(use a monotonic stream position compared against the since token, NOT a per-user consume-once flag like the global store's `changed` column).
Clarify and document how Nebu's since/next_batch token carries the position.

**AC5 — Reject server-managed types in BOTH scopes (MUST):**
Global `PUT /user/{userId}/account_data/{type}` now rejects `m.fully_read` and `m.push_rules` with `405 M_BAD_JSON` (existing clients that PUT other types keep working). Reading
these types (GET) remains allowed ("normal read"). The global PUT with a malformed JSON body returns `400 M_NOT_JSON` instead of storing `{}`.

**AC6 — read_markers (MUST):**
`POST /_matrix/client/v3/rooms/{roomId}/read_markers` with `m.fully_read` stores the event id as the room account-data event `m.fully_read` (`{"event_id": "..."}`) for the user and delivers it through /sync (AC3/AC4). The event must belong
to the room (else `400 M_INVALID_PARAM` or the Oracle-confirmed code). With `m.read` / `m.read.private` the server treats them exactly like the `/receipt` endpoint (same path, same validation,
same fan-out). Clients may not set `m.fully_read` through any account-data endpoint (AC5). Membership/authorization is the same as for `/receipt`.

**AC7 — Authorization and privacy:**
Only the authenticated user can read/write their own data (403 for other users, including admins). Writing room account data for a room the user is
NOT a member of: decide per spec (the spec does not require membership) and document; whatever is chosen must not leak existence of rooms (same response for unknown and non-member rooms) and must not allow unbounded storage (AC2 caps).
Data is deleted with the user's GDPR erasure / deactivation path where global account data is deleted today (find and extend that path) and when the room is deleted/purged, if such a path exists.

**AC8 — No regression:**
Global account data (secret storage, cross-signing material) behavior, secret-storage /sync delivery and all existing tests stay green; the per-DEVICE
weakness of the GLOBAL `changed` flag is OUT of scope (separate bugfix) but must be noted in Dev Notes with a reproduction hint.

**AC9 — Docs:**
`docs/architecture/08-concepts.md` (account data section), `docs/matrix-api-scope.md` (Client Config room scope, read_markers rows) and the arc42 building-blocks text describe the new store/endpoints and the incremental-sync design.

## Acceptance Tests

- PUT→GET byte-exact round trip for `m.marked_unread` (`{"unread":true}`) in a room; survives an app restart (store read from DB); other room does not see it; no fallback to a global value of the same type.
- All error codes in AC1 (403, 400 INVALID_PARAM, 400 NOT_JSON, 404, 405 for both server-managed types and both scopes, 413).
- Initial sync includes room account data for joined rooms; incremental sync includes only changes after `since`; two devices (two since tokens) both receive a change exactly once each; a room with only an account-data change appears in `rooms.join`.
- `m.fully_read` via read_markers is stored, GET returns it, appears in /sync, cannot be PUT directly; `m.read` through read_markers creates the same receipt as `/receipt`.
- Cross-user write attempt → 403; per-user cap enforced; erasure/deactivation removes the rows.

## Dev Notes

- Oracle result and exact spec lines: `_bmad-output/nebu/epics/matrix-spec-gaps/step-results/room-account-data-and-read-markers/oracle-context.md`.
- Relevant code: `server/lib/nebu/web/router/protected.ex` (account_data routes ~546-588, sync assembly ~100-125, read_markers ~1172-1181, catch-all ~1309), `server/lib/nebu/matrix/http.ex` (sync_response / build_joined_rooms: `account_data` hard-coded `[]` ~131-174), `server/lib/nebu/matrix/account_data_store.ex`, `server/lib/nebu/matrix/receipt/db.ex`, migration `000015_account_data.up.sql`.
- Out of scope (next story `room-tags`): `GET .../rooms/{roomId}/tags`, `PUT/DELETE .../tags/{tag}` (event `m.tag`, tag name max 255 bytes) — build the store so tags can reuse it.
- Out of scope: `rooms.leave.*.account_data` (Nebu does not deliver `leave` at all), sync filters for account_data, advertising v1.12 in `/versions`, deleting account data.
- Known pre-existing weakness (not fixed here): the GLOBAL `AccountDataStore.changed` flag is consumed per USER, so a second device can miss a change; add a note + reproduction in the final Dev Notes.
- Migration numbering: another pipeline may add migrations meanwhile; keep numbering contiguous, renumber at merge if needed.

## Dev Agent Record (implementation)

**Migration:** `000039_user_room_account_data` (table `user_room_account_data`, sequence `user_room_account_data_pos_seq`, grants for nebu_app incl. sequence). A dormant legacy table `room_account_data` (000001/000002; JSONB, FORCE RLS, never used by any code) exists and was deliberately NOT reused (needs verbatim TEXT + change position; RLS depends on an unset session variable). Cleanup of the legacy table = separate task. Verify migration numbering at merge.

**Since-token position:** `next_batch`/`since` = `<core token>[.<pos>]`. The core token keeps its per-user stored-token semantics (mismatch -> fallback to initial sync); `<pos>` is the highest room-account-data `stream_pos` this client received. Parsed/appended in `Nebu.Web.Router.Protected.do_sync/1`. Old tokens without suffix = position 0 = all room account data is re-delivered once after the upgrade. Because the position is read from the client's token (not from the stored core token), delivery is correct per device, also on the fallback path. Writers draw `stream_pos` under a per-user `pg_advisory_xact_lock` so position order == commit order per user. PUT wakes long-polls (`{:account_data_changed, room}`); `/sync` does not long-poll when changes are already pending.

**Limits:** body <= 65536 bytes (`NEBU_ROOM_ACCOUNT_DATA_MAX_BYTES`, 413 M_TOO_LARGE); <= 1000 rows per user (`NEBU_ROOM_ACCOUNT_DATA_MAX_ROWS_PER_USER`, new row beyond cap -> 403 M_RESOURCE_LIMIT_EXCEEDED; overwrite always allowed). The 1 MB parser cap is tolerated by the plug layer only on `PUT` + the exact shapes `/user/{u}/account_data/{type}` and `/user/{u}/rooms/{r}/account_data/{type}` (shared helper `RawBodyReader.account_data_shape?/1`); both handlers answer 413 M_TOO_LARGE. Every other route (also paths merely containing an `account_data` segment) keeps Plug's default 413.

**Non-member write:** same response as unknown room: 403 M_FORBIDDEN (PUT and GET); all type/authorization/format checks run before any room lookup. read_markers keeps `/receipt` parity (404 unknown room, 403 non-member) because AC6 requires identical authorization.

**Erasure/deactivation:** GDPR erasure (`UserDeletion.delete_user_keys/3`) deletes the user's rows in its transaction. Admin deactivation does NOT delete (reversible; reactivation exists). Room deletion cascades by FK.

**read_markers:** membership first (shared `Server.ensure_room_member!/2`), `m.fully_read` event must exist in the room (400 M_INVALID_PARAM, validated before any write), `m.read`/`m.read.private` via `Server.send_receipt/2` (no event-belongs-to-room check, exactly like `/receipt`), `m.fully_read` stored as `{"event_id": ...}`. Non-string/empty marker values -> 400 M_INVALID_PARAM; malformed JSON -> 400 M_NOT_JSON.

**Side findings (NOT fixed):**
- (a) global `account_data` rows are never deleted (also not by GDPR erasure).
- (b) the global `changed` flag is consumed per USER: two devices with since tokens, one global PUT, device A syncs (consumes the flag), device B's incremental sync misses it. Repro: PUT global type, `GET /sync?since=A` then `GET /sync?since=B` -> second has no entry.
- (c) catch-all answers 404 M_NOT_FOUND instead of M_UNRECOGNIZED.
- (d) a room dropped from an initial sync by the 10 s per-room fetch timeout does not receive its account data until it changes again (position advances regardless).
- (e) global PUT still stores `Jason.encode!(body_params)` (not the raw bytes); non-object bodies are now rejected (400 M_BAD_JSON, cycle 1); room scope is byte-exact + object-only.
- (f) `docs/matrix-api-scope.md` lists room tags as implemented although they are not (separate story `room-tags`).
- (g) initialSync (`/initialSync`, protected.ex) still returns per-room `account_data => []`.
- Out of scope as specified: `rooms.leave.*.account_data`, sync filters, advertising v1.12.

## Review cycle 1 (fixes)

- **Regression fixed:** a global `PUT /user/{u}/account_data/{type}` with a body > 1 MB no longer stores `{}` (200); it answers 413 M_TOO_LARGE and leaves the old value untouched. Path matching is exact (PUT + two shapes), shared by `RawBodyReader`, `JsonBody`; the `RequestLogger` uses the same shape helper.
- **Total cap:** sum of `octet_length(content_json)` per user <= `NEBU_ROOM_ACCOUNT_DATA_MAX_TOTAL_BYTES` (default 4 MiB), checked under the advisory lock (overwrite counts NEW minus OLD; a write that does not grow the total always passes) -> 403 M_RESOURCE_LIMIT_EXCEEDED. `m.fully_read` (server-managed, written by `/read_markers`) is exempt from the row and the total cap and is not counted, so a user at the cap can still advance read markers. Env values are parsed safely (positive integer <= int8 max, otherwise default).
- **Rate limit:** account-data PUT routes (global + room) are limited per USER (`RateLimit` option `key: :user`, tier `account_data`), 60/min, burst 30 -> 429 M_LIMIT_EXCEEDED.
- **Logging Law:** request and response bodies of the account-data routes (global + room, any method) are never captured at DEBUG.
- **Since token:** `<core>[.<pos>]`: the position is only a trailing `.` + ASCII digits; > 19 digits or > int8 max -> position 0 (suffix stripped); `+5`, `-1`, `5x`, `core.`, `a.b.c` are not positions (whole token = core -> unknown core -> initial sync fallback). A position above the user's latest is clamped to the latest (next_batch carries the real latest).
- **read_markers atomicity:** m.fully_read is stored first (exempt from caps, so only a DB error can fail it), receipts after; validation (membership, event belongs to room) precedes every write.
- **Percent-decoding:** the global routes no longer apply `URI.decode_www_form` on user id / type (Plug.Router already decodes path params); `a+b` is the same key in both scopes.
- **RLS:** the new table has no RLS, same as the neighbouring tables (single role `nebu_app`, every statement filters `user_id = $1`).
- **Documented only:** (1) read_markers shows a small timing/status difference unknown room (404) vs non-member (403), inherited from `/receipt`; (2) a PUT committed between the `pending?` pre-check and the `:pg` join gets no wake-up: delivery is delayed by at most the long-poll timeout, never lost (position based); (3) global account data is still not erased on GDPR erasure (separate bugfix).

## Review cycle 2 (fixes)

- **One path matcher:** `RawBodyReader.account_data_shape?/1` accepts a path string or a segment list and normalizes exactly like `Plug.Router` (drop empty segments, `URI.decode` each segment, invalid percent-encoding never raises). `RawBodyReader`, `JsonBody` and `RequestLogger` all use it, so `%61ccount_data`, `//` and a trailing slash are cached/handled as account data and their bodies are never logged.
- **Global PUT body discipline:** the global PUT now judges the RAW body like the room scope: oversized (any Content-Type) -> 413 M_TOO_LARGE; empty / invalid JSON / no or non-JSON Content-Type (parser skipped) -> 400 M_NOT_JSON; non-object -> 400 M_BAD_JSON; objects (also with a `_json` key) are stored as before. Compatibility decision: clients that send no `Content-Type: application/json` are rejected (stricter than Synapse (which parses the body without checking the Content-Type); deliberate, the target clients matrix-js-sdk and dart-sdk always send application/json); previously such a request silently overwrote the value with `{}`.
- **Rate limit test** neutralizes the OS env var `NEBU_RATE_LIMIT_DISABLED` (restored in `on_exit`); `rate_limit.ex` moduledoc documents `key: :user` and the small unbounded ETS bucket growth.
- **429 body:** `retry_after_ms` in the 429 body comes with `bugfix/matrix-session-refresh` (it changes `rate_limit.ex`; not duplicated here to avoid a merge conflict).
- **Documented only:** (1) `/sync` response bodies still reach the DEBUG log via `PayloadRedactor` (content not masked) -> open Enhanced-Logging finding F-1, not this story; (2) the global `AccountDataStore` has no per-user row/size cap (only the rate limits, up to 60 x 1 MB per minute) -> own bugfix; (3) the burst-30 limit on the global PUT should be smoke-tested with the Element secret-storage setup.
