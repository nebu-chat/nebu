---
story_id: room-tags
title: "Bug: room tag endpoints (m.tag: favourites / low priority) are missing although the scope doc says they exist"
type: bug
severity: medium
epic: matrix-spec-gaps
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-08
branch: bugfix/room-tags
---

## Summary

`GET /user/{userId}/rooms/{roomId}/tags`, `PUT .../tags/{tag}` and `DELETE .../tags/{tag}` do not exist in Nebu (catch-all 404 `M_NOT_FOUND`),
yet `docs/matrix-api-scope.md` (~l.121-123) marks them as implemented. Clients (FluffyChat: favourites / pinned, Element: Favourites and Low priority sections) therefore
cannot persist room tags. Oracle verification (2026-10-08, see `_bmad-output/nebu/epics/matrix-spec-gaps/step-results/room-tags/oracle-context.md`): the module "Room Tagging" is
optional in every feature profile (no MUST breach), but the dev-facing contract (docs) is wrong and the user-visible gap is high.

Tags live in the room account data event `m.tag` (`{"tags": {"m.favourite": {"order": 0.25}}}`), which the previous story (`room-account-data-and-read-markers`, branch
`bugfix/sync-room-account-data`, table `user_room_account_data`) already stores and syncs. This story adds the three comfort endpoints on top and MUST reuse that store.
This branch is stacked on `bugfix/sync-room-account-data`.

## Story

As a Matrix user on Element or FluffyChat,
I want to mark rooms as favourite / low priority (and user tags) and have that shared across my devices,
so that my room list organisation persists.

## Acceptance Criteria

**AC1 — Endpoints and shapes (spec):**
`GET /_matrix/client/v3/user/{userId}/rooms/{roomId}/tags` → 200 `{"tags": {...}}` (the stored `m.tag` content's `tags` object; `{"tags":{}}` when nothing is stored, never 404).
`PUT .../tags/{tag}` with body = tag object (e.g. `{"order": 0.25}`, `{}` allowed) → 200 `{}`; stores/overwrites that tag in the room's `m.tag` event, other tags untouched.
`DELETE .../tags/{tag}` → 200 `{}` (idempotent: unknown tag also 200). Deleting the last tag leaves `m.tag` = `{"tags":{}}` (so /sync delivers the change; the store has no delete/tombstone).
A numeric `order` round-trips numerically equal (0.25 → 0.25). The tag's other fields in the body are preserved verbatim.

**AC2 — Validation / error matrix (Nebu decisions, spec names none):**
`403 M_FORBIDDEN` when `{userId}` ≠ authenticated user (all three methods, also for admins); `400 M_INVALID_PARAM` for a syntactically invalid `roomId`;
tag name: empty or > 255 BYTES after URL-decoding (multibyte at the 255/256 boundary, `%2F` in the name) → `400 M_INVALID_PARAM`;
body not a JSON object → `400 M_NOT_JSON` (PUT); `order` present but not a JSON number → `400 M_BAD_JSON`; `order` outside [0,1] is accepted (spec does not require rejection; document);
non-member and unknown room answer identically with `403 M_FORBIDDEN` (same as room account data, no existence leak); oversize body → 413 `M_TOO_LARGE`; event > 64 KiB after the merge → 413 `M_TOO_LARGE`; `403 M_RESOURCE_LIMIT_EXCEEDED` for the row cap (only a NEW room row) and for the per-user total-bytes cap (4 MiB; also refuses growth of an existing row)
(adding a tag to a room that already has an `m.tag` row never grows the row count). Rate limit: same tier as room account data (`account_data`, 60/min, burst 30/user) — a Nebu deviation from the spec's "Rate-limited: No", documented.

**AC3 — Atomic read-modify-write (the main risk):**
Tag PUT/DELETE must read the current `m.tag`, modify, and write in ONE transaction under the existing per-user advisory lock (new store function, e.g. `update(user, room, "m.tag", fun)`), including the cap/size checks and `notify_sync`.
N concurrent PUTs of DIFFERENT tags to the same room end with all N tags; concurrent PUT+DELETE of different tags do not lose either. A direct `PUT .../account_data/m.tag` concurrent with tag PUTs is last-writer-wins on the whole event (documented), never a corrupted event.

**AC4 — Interop with direct account data:**
`PUT .../rooms/{roomId}/account_data/m.tag` stays allowed (no 405; only `m.fully_read`/`m.push_rules` are server-managed). A directly PUT `m.tag` is visible through `GET .../tags` and vice versa. A stored `m.tag` with a malformed shape (`tags` missing / not an object) is handled tolerantly: treated as `{}` for modification, unknown top-level keys preserved, never a 500.

**AC5 — Sync:**
Exactly ONE `m.tag` event per room in `rooms.join.<roomId>.account_data.events` (initial: current state; incremental: only when changed after the token's position); two devices (two since-tokens) each get a change once; a long-poll /sync is woken by a tag change; rooms the user left deliver nothing.

**AC6 — Privacy / lifecycle:**
Rows are removed by GDPR erasure (`delete_user_keys`) and by user/room cascade, exactly like room account data (no new deletion path needed, verify with a test). No tag names/orders in logs (Logging-Law: the request logger must treat the three tag route shapes like account-data content: no body capture; use the shared router-identical path matcher, extend it for the `tags` shapes incl. `%`-encoded / `//` variants).

**AC7 — Docs:**
`docs/matrix-api-scope.md` tag rows corrected to the real state; `docs/architecture/08-concepts.md` account data section and 05-building-blocks mention the tag layer, the atomic update function, the sync behavior; Dev Notes list Nebu-vs-spec decisions (error codes, rate limit, order range, last-tag semantics).

## Acceptance Tests

- GET empty → `{"tags":{}}`; PUT m.favourite order 0.25 then PUT u.work `{}` → GET has both; DELETE one; DELETE unknown → 200; DELETE last → `{"tags":{}}` and a sync event.
- Tag name boundary: 255 ASCII bytes ok, 256 → 400; multibyte by BYTES: 127 two-byte chars (254) and 127 + 1 ASCII byte (255) ok, 128 two-byte chars (256) → 400; 85 three-byte chars ok / 86 → 400; 63 four-byte chars ok / 64 → 400, empty name → 400 (route shape), `%2F` handled.
- Error matrix: 403 other user (+admin), 400 roomId, 400 NOT_JSON (array/scalar/malformed), 400 BAD_JSON non-numeric order (string/null/bool/array), non-member vs unknown room identical 403.
- Race test: 20 parallel PUTs of 20 distinct tags → 20 tags; PUT/DELETE mix.
- Interop: direct PUT account_data/m.tag then GET tags; tag PUT then GET account_data/m.tag; malformed stored m.tag + tag PUT → no 500, valid result.
- Sync: initial/incremental/two devices/long-poll wake/leave; exactly one m.tag event per room.
- Cap: existing room row + tag add allowed at the 1000-row cap; new room beyond cap → 403 M_RESOURCE_LIMIT_EXCEEDED; rate limit 429.
- GDPR erasure removes tags; request logger test (no tag names/orders in DEBUG log, also for `%74ags` and `//` variants).

## Dev Notes

- Code: `server/lib/nebu/web/router/protected.ex` (room account data handlers ~ do_put_room_account_data, shared plug helpers), `server/lib/nebu/matrix/room_account_data_store.ex` (put/4 with advisory lock + caps, list_for_sync, notify_sync), `server/lib/nebu/web/plugs/raw_body_reader.ex` (`account_data_shape?/1` shared matcher; request_logger uses it), `server/lib/nebu/compliance/user_deletion.ex`, docs/matrix-api-scope.md ~l.121-123.
- Oracle: `_bmad-output/nebu/epics/matrix-spec-gaps/step-results/room-tags/oracle-context.md`.
- Out of scope: `/events` with room_id, `initialSync` account_data (still `[]`), m.server_notice semantics, M_UNRECOGNIZED for unknown routes, sorting/namespace semantics (client side).
- Migration: none expected (reuses `user_room_account_data`).

## Dev Agent Record

### Implementation Notes / Nebu-vs-spec decisions

- New `RoomAccountDataStore.update/4`: transaction + per-user advisory lock + SELECT + pure fun + shared `upsert!/4` (same caps as `put/4`). The fun returns `{:ok, json}` or `:unchanged` (no write, no `stream_pos`, no sync event, never creates a row: DELETE of an unknown tag / on a room without row). Event above `max_bytes` -> `{:error, :too_large}` -> 413 `M_TOO_LARGE` (403 `M_RESOURCE_LIMIT_EXCEEDED` would be defensible; documented choice).
- Error codes (spec names none): 403 `M_FORBIDDEN` (other user incl. admins; non-member and unknown room identical), 400 `M_INVALID_PARAM` (roomId, tag name empty / > 255 bytes / invalid UTF-8 / NUL), 400 `M_NOT_JSON`, 400 `M_BAD_JSON` (non-numeric `order`), 413, 403 `M_RESOURCE_LIMIT_EXCEEDED` (row cap only for a NEW row; total-bytes cap also for growth of an existing row).
- Rate limit: PUT/DELETE share the `account_data` bucket (60/min, burst 30/user), a documented deviation from the spec's "Rate-limited: No"; GET is not limited. `order` outside [0,1] is accepted.
- Last tag: deleting it keeps `{"tags":{}}` as the row. Direct `PUT account_data/m.tag` stays allowed (last writer wins on the whole event). Malformed stored `m.tag` is treated as `{}`; unknown top-level keys are preserved.
- Route shapes: `PUT/DELETE .../tags` and `.../tags/` (no name) -> 400 `M_INVALID_PARAM` (own routes); `.../tags//u.x` normalizes to the named tag (Plug.Router drops empty segments); `%2F` in a name is one segment and is stored as `u.a/b`. A tag PUT whose body was not sent as JSON (no / non-JSON Content-Type) -> 400 `M_NOT_JSON` (like the global scope; stricter than the room account data PUT).
- Request log: the tag NAME is user content and is REDACTED (review cycle 1, Kassandra MEDIUM): `RouteNormalizer` anchor rule `"tags" => %{1 => ":tag"}` makes `path` and `route_template` read `.../tags/:tag`. The normalizer now builds the anchor index from the router-identical segment view (empty segments dropped, each segment percent-decoded via the never-raising `safe_decode`), so `%74ags/<tag>`, `tags//<tag>`, `%61ccount_data/<type>`, `account_data//<type>` are redacted too; output keeps the input's raw structure (empty segments / trailing slash preserved, only matched segments replaced). Bodies and responses of the tag routes are never captured (`RawBodyReader.room_tags_shape?/1`, `opaque_content_shape?/1`, `opaque_content_put?/1`; the dead `account_data_put?/1` was removed). `.../tags/:tag` appears in `path` and `route_template` only as long as both are derived from `normalize_route` (`request_logger.ex` ~69/102). An empty raw segment directly after the last routed segment (trailing slash, e.g. empty `state_key`) still counts as a target slot, so the same endpoint never yields two `route_template` variants.
- Accepted (Kassandra INFO): tag names get no NFC/bidi normalization (stored verbatim, byte-length limited); `GET .../tags` is not rate limited (spec: not rate limited); room membership is checked before the transaction (a concurrent leave can let one write through, harmless: the row is invisible to /sync for non-members).
- `RoomAccountDataStore.update/4` applies the 64 KiB per-event cap only when the event grows (an operator who lowered the cap can still delete tags).
- The same normalizer segment fix covers the media `{fileName}` follow-up (rule `"download"`) of branch `bugfix/media-response-content-type` only AFTER that branch is merged; not part of this story.
- Tests corrected before implementation (test-review findings M1, M2, m1-m6, i1): logging test accepts 200/400 for the `%2F` path and asserts the logger line; matcher-name test deleted; cascade test verifies the FK `ON DELETE CASCADE` in the catalog (a real parent DELETE is blocked by unrelated FKs); new tests for invalid token, `%FF`/`%00`, `Retry-After`, DELETE without row; accumulation overflow accepts 413 or 403; fixed invite+join; relative row cap; deterministic `:pg` wait point instead of `sleep`.

### File List

- server/lib/nebu/matrix/room_account_data_store.ex
- server/lib/nebu/web/router/protected.ex
- server/lib/nebu/web/plugs/raw_body_reader.ex
- server/lib/nebu/web/plugs/json_body.ex
- server/lib/nebu/web/plugs/request_logger.ex
- server/test/nebu/matrix/room_tags_test.exs
- docs/matrix-api-scope.md
- docs/architecture/08-concepts.md
- docs/architecture/05-building-blocks.md
- docs/stories/matrix-spec-gaps/room-tags.md

### Change Log

- 2026-10-08: implemented room tag endpoints on top of room account data; docs corrected.
