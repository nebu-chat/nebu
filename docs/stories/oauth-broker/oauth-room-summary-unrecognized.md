---
story_id: oauth-room-summary-unrecognized
title: "Local-only `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` (Matrix v1.15 core) and spec `M_UNRECOGNIZED` answers for unrouted Matrix endpoints (404) and unsupported methods (405) (gates ac, af)"
type: feature
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-12
branch: feature/migrate-to-oauth2
---

## Summary

Phase-2 story P6b of epic `oauth-broker`. Closes two gates of `follow-ups.md`, both required before
`oauth_enabled` and before any release claiming v1.15 (story 9 V13, oracle O1/O7):

- **ac (G1):** `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` is CORE in v1.15 ("Room Summaries": auth
  required, Rate-limited No, 200 / 404) and missing. Nebu adds a minimal LOCAL-ONLY summary (no federation, `via`
  ignored, Protected auth, visibility like `/hierarchy` plus invites and knock rules, aliases via `room_aliases`).
- **af (V19, story-5 (e)):** spec: `M_UNRECOGNIZED` "with a 404 ... if the endpoint is not implemented or a 405 ...
  if the endpoint is implemented, but the incorrect HTTP method is used". Today: Protected / Media / ClientV1Media
  answer `404 M_NOT_FOUND "Unrecognized request"`, HttpPublic `404 M_NOT_FOUND "Not found"`, and (OidcPlug runs
  before the match) unknown paths without a token and `POST`/`PUT`/`HEAD /_matrix/client/versions` answer `401
  M_MISSING_TOKEN`. Afterwards router fall-throughs answer `404`/`405 M_UNRECOGNIZED` with no auth requirement;
  every handler-level `M_NOT_FOUND` stays; `POST /v3/register` gets an explicit `403 M_FORBIDDEN` (RU10a).

`oauth_enabled` stays `false`; nothing reads or changes it except the live-only 405 branch of RU14. No migration.
createRoom `topic` (G2, item ad) stays out of scope (not trivial: event ordering); room_summary reads `m.topic`.

Sources: spec copy `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/`; story 9 (V13, V19, G1) + Kassandra report; oracle contexts of story 9 and of this story; matrix-js-sdk 41.3.0 `src/client.ts` (~8741, ~8833, ~6627). Lines as of 7c2a8ad8 (parallel stories touch `http_public.ex`, `oauth/http.ex`: re-locate by name).

## Story

As a **FluffyChat / Element Web user on a Nebu instance announcing v1.15**, I want room / space previews by id or alias and spec error codes for unimplemented endpoints, so that previews work and clients take their documented fallbacks.

## Decisions

Prefix `RU` (new in ADR-033; taken: D, T, R, C, A, V, TP, CR, SO). Safe variant wherever the spec leaves room.

**Room summary (ac)**

- **RU1 Local only.** No federation, no outbound HTTP; `via` and other query params ignored. Aliases resolve only
  via `Nebu.Matrix.Room.DB.lookup_alias/1` (not in the store => `404 M_NOT_FOUND`, any server part); room ids are
  looked up as given.
- **RU2 Auth required** (Protected, OidcPlug; legacy and OAuth tokens alike). The spec MAY (unauthenticated) is
  not taken.
- **RU3 Existence before state; one 404 for everything hidden.** First `Room.DB.get_room_status/1 == {:ok,
  "active"}`, only then `fetch_room_state/1`: it lazy-starts the Room and `Room.Server.do_init/1` calls
  `insert_room/1` for an unknown id, so an unchecked lookup inserts a `rooms` row and spawns a process per
  attacker-chosen id (trap 1). Unknown, archived and not-visible rooms all get the byte-identical `404
  {"errcode":"M_NOT_FOUND","error":"Room not found"}` (anti-enumeration; the spec lists only 404). Deliberately
  unlike `/hierarchy` (403 for a hidden root).
- **RU4 Visibility:** joined (`state.members`) OR pending invite (`room_invitations`, `accepted_at IS NULL AND
  rejected_at IS NULL`) OR `join_rule` in `public`/`knock`/`knock_restricted` OR `history_visibility` =
  `world_readable` (defaults `invite`/`shared`, same helpers as `/hierarchy`). `restricted` rooms are NOT visible
  through `allow` (as `/hierarchy`; follow-up). Banned / departed callers see a room only if the rule makes it
  visible.
- **RU5 Shape** (spec `RoomSummary` + `membership`). Always: `room_id`, `num_joined_members`
  (`MapSet.size(state.members)`), `guest_can_join` (`m.room.guest_access` = `can_join`), `world_readable`,
  `join_rule`, `room_version` (create content, `"1"` if absent per spec), `membership` (`join` / `invite` from
  state and the pending invite, else the latest `m.room.member` with `state_key` = caller: `ban`/`leave`/`knock`;
  never a member => `leave`: a Nebu choice, the spec defines no default for that case; the spec omits it only for unauthenticated calls). Omitted when
  empty: `name`, `topic`, `avatar_url`, `canonical_alias`, `room_type`. `topic` = the `m.topic` block with
  mimetype `text/plain` (a block without mimetype counts as text/plain, `m.topic` default), else the legacy `topic`; never another mimetype. `encryption` only for `m.room.encryption` algorithm
  `m.megolm.v1.aes-sha2` (absent in practice, ADR-011). `allowed_room_ids` only for `restricted` /
  `knock_restricted` (`room_id` of `m.room_membership` allow entries). Never `children_state`,
  `im.nheko.summary.*`, `aliases`.
- **RU6 No unstable alias** `/unstable/im.nheko.summary/...`: matrix-js-sdk `getRoomSummary` gets 404
  `M_UNRECOGNIZED`, falls back to `/rooms/{id}/summary`, same answer, fails as today (js-sdk 41.3.0 code reading;
  manual check 5). Element uses `/hierarchy`
  for spaces. Optional follow-up.
- **RU7 Rate limit (recorded deviation from "Rate-limited: No"):** tier `room_summary`, `rate_per_min: 300`,
  `burst: 60`, `key: :user`, no-op under `NEBU_RATE_LIMIT_DISABLED`; reason: each call may lazy-start a Room. The 429 carries `retry_after_ms` AND the `Retry-After` header (the plug already sets both).
- **RU8 Validation:** use the param as Plug decoded it (NO `URI.decode_www_form`, trap 3); must start with `!` or
  `#`, <= 255 bytes; `:` is required only for `#` aliases (room version 12 ids may lack a domain), else `400
  M_INVALID_PARAM` without DB access. A well-formed `!` id without `:` goes through RU3 (404 if unknown).

**`M_UNRECOGNIZED` (af)**

- **RU9 Scope = `/_matrix` paths:** the fall-throughs of Protected, `Nebu.Web.Router.Media`,
  `Nebu.Web.Router.ClientV1Media`, `Nebu.Matrix.HttpPublic`; non-GET on the top-level `/_matrix/client/versions`;
  RU14. Unchanged: top-level `match _` (plain `404 "not found"` for non-Matrix paths), `/admin`, `/oauth2/*`,
  `/account*`, `/.well-known/*` (own RFC 6749 shapes / 405s).
- **RU10 Unknown endpoints have no auth requirement** (auth is per endpoint; an unimplemented path/method has
  none): no token, junk token and valid token get the same 404/405. Fail-closed mechanism: pipelines of Protected /
  Media / ClientV1Media become `:fetch_query_params` (Protected) -> `:match` -> `:authenticate` -> `:dispatch`;
  the catch-all becomes `match _, private: %{nebu_unrecognized: true}`; `:authenticate` skips OidcPlug ONLY when
  `conn.private[:nebu_unrecognized] === true`, every real route runs OidcPlug as before, a halted conn never
  dispatches. Accepted disclosure: unauthenticated callers can tell implemented (401) from unknown (404) paths;
  the route set is public (open source, `/versions`, scope doc); unknown paths stop costing a token lookup.
  Rejected alternative (auth first, unauthenticated unknown paths stay 401): it keeps V19 everywhere but
  `/versions`; the marker is narrow and AC12 guards it.
- **RU10a `POST /_matrix/client/v3/register` (oracle MAJOR 1).** Not a fall-through: routed explicitly in the top
  router before `forward "/_matrix"`, no auth check, answers `403 {"errcode":"M_FORBIDDEN","error":"Registration is
  not enabled on this homeserver."}` for any body / `kind` / token (the spec's "registration not supported" answer;
  Element treats 403 as registration disabled). No rate-limit token, no DB, no log line. Other methods on
  `/v3/register` => 405 + `Allow: POST, OPTIONS` (same `match` pattern as `/versions`). Sub-paths
  (`/register/available`, `/register/email/requestToken`, ...) stay fall-throughs (404).
- **RU11 405, HEAD, OPTIONS.** The catch-all probes the router's OWN clauses: private `do_match/4` with
  `GET`/`PUT`/`POST`/`DELETE`/`PATCH` (minus the request method) on `Plug.Router.Utils.decode_path_info!(conn)`,
  marker removed (trap 2); a probe selects a clause, it never dispatches. A real match => `405` + `Allow:
  <methods>, OPTIONS` (RFC 9110 MUST); none => `404`. HEAD is not mapped to GET (no `Plug.Head`) => 405 on
  GET-only paths (Bandit strips the body). CORS preflights unchanged (CORSPlug halts them in the top router). A
  non-preflight `OPTIONS` => `204` + `Allow` on a known path (no auth, no logic: "MUST NOT perform any logic"),
  404 on an unknown one, never 405. This also holds for the explicit routes: OPTIONS on room_summary,
  `/_matrix/client/versions` and `/v3/register` => 204 + `Allow`, no auth, no rate-limit token, no DB. HEAD => 405
  deviates from the RFC 9110 SHOULD (HEAD wherever GET works): recorded in the scope doc.
- **RU11a Carve-out for the unimplemented state reads (orchestrator decision of the pre-dev test review, M1).**
  `GET /_matrix/client/v3/rooms/{id}/state` and `GET .../state/{type}[/{key}]` are NOT routed (only the PUT state
  routes exist). Clients (matrix-js-sdk `getStateEvent`, Element, Dart SDK) read `404 M_NOT_FOUND` as "state
  absent"; an `M_UNRECOGNIZED` 404 or a 405 would break them. So exactly these GETs keep today's `404
  {"errcode":"M_NOT_FOUND","error":"Unrecognized request"}` (no auth check, like every fall-through) until
  follow-up bf implements the endpoints; other methods follow RU11 (`DELETE .../state/{type}` => 405 + `Allow:
  PUT, OPTIONS`). Pinned by `unrecognized_routes_test.exs` (RU11a describe) and the AC9 integration test.
- **RU12 Handler-level `M_NOT_FOUND` stays:** missing account data (js-sdk maps it to null), missing state events
  (power levels), unknown device / media / profile, `room_keys/version`, `voip/turnServer`, `dehydrated_device`,
  `rtc/transports`, room_summary RU3. The catch-all never rewrites a handler-generated answer: e.g. `PUT
  .../account_data/m.push_rules` keeps its `405 M_BAD_JSON` (server-managed type); only requests that reach `match _`
  change.
- **RU13 HttpPublic root by `conn.script_name`** (forward prefix; also set when `OAuthDiscovery` calls
  `HttpPublic.call/2`). Today `post "/"` runs `do_login` for every forward landing on `/`: `POST /v3/auth`, `POST
  /v3/profile` and, OAuth disabled, `POST /v1/auth_issuer` and the unstable `auth_issuer`/`auth_metadata` attempt
  a login (pre-existing bug, code reading; ATDD measures first). New table for path_info `[]`:

  | Prefix | Allowed | Other methods |
  |---|---|---|
  | `login` | GET, POST | 405 |
  | `refresh` | POST | 405 |
  | `auth_issuer`, `auth_metadata` (legacy) | GET | 405 |
  | `auth`, `profile` | - | 404 |

  Non-root paths use the RU11 probe. `POST /login` / `POST /refresh` stay byte-identical (rate limits incl.).
- **RU14 OAuth discovery while live:** in `Nebu.OAuth.Http` a non-GET on `auth_metadata` / `auth_issuer` (v1 +
  unstable) => `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS` iff `Config.live_state/0` is `{:live, _}`, else `404
  M_UNRECOGNIZED` as today.
- **RU15 Bodies:** 404 `{"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}`; 405
  `{"errcode":"M_UNRECOGNIZED","error":"Unsupported method"}`; `application/json` and today's CORS headers
  (`access-control-allow-origin` asserted on every 404 / 405 / 204 in AC8, AC10, AC11), no log line of their own.
- **RU16** `/_matrix/client/v3/versions` stays unrouted (ae): now 404 instead of 401; health checks probing it
  fail as before (fix: ae / P5).
- **RU17** No Gherkin (`ui: false`): ExUnit + "Manual verification".
- **RU18 Side finding, not fixed:** reads that lazy-start a Room (`fetch_room_state/1`, `get_room_state/2`:
  `/hierarchy`, `GET /rooms/{id}/state...`) insert a `rooms` row and start a GenServer for any unknown id an
  authenticated user sends. Follow-up.

## Oracle gate (2026-10-12, PASS: 0 BLOCKER, 1 MAJOR, 8 MINOR)

Source: `_bmad-output/nebu/epics/oauth-broker/step-results/oauth-room-summary-unrecognized/oracle-context.md`.

| # | Sev | Correction | Applied in |
|---|---|---|---|
| 1 | MAJOR | `POST /v3/register` must not become 404: explicit route, no auth, `403 M_FORBIDDEN` | RU10a, AC8a (new), AC8.1 (removed), AC16.4, doc edits 1 + 3, manual 4 |
| 2 | MINOR | never-member `membership: leave` is a Nebu choice, not a spec default | RU5 |
| 3 | MINOR | `:` required only for `#` aliases; `!` id without `:` => RU3 404, not 400 | RU8, AC6.1 |
| 4 | MINOR | assert `Retry-After` on the 429 | RU7, AC7 |
| 5 | MINOR | CORS + Content-Type assertions on 404 / 405 / 204 | RU15, AC8, AC8a, AC10.3 |
| 6 | MINOR | OPTIONS on room_summary and `/versions` => 204 + `Allow`, no rate limit, no DB | RU11, AC10.3 |
| 7 | MINOR | the catch-all never rewrites handler-generated 405s / errors (`405 M_BAD_JSON`) | RU12, AC9 |
| 8 | MINOR | HEAD => 405 deviates from the RFC 9110 SHOULD: note in the scope doc | RU11, doc edit 3, OQ3 |
| 9 | MINOR | matrix-js-sdk behaviour claims unverifiable in the gate: manual check | RU6, manual 5 |

Also taken from the oracle facts: `topic` only from text/plain (RU5); "test-must-cover" items are covered by AC2-AC12
(optional keys absent, not `null`/`""`: AC2.1).

## Acceptance Criteria

### AC1 — Route and auth (RU2)
1. `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` is routed in Protected, before `match _`.
2. Without a token: `401 M_MISSING_TOKEN`. With a junk token: `401 M_UNKNOWN_TOKEN`. Legacy and OAuth
   (`T.session!`) tokens both reach the handler.
3. Other methods answer `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS`, with or without a token.

### AC2 — Joined member (RU5)
1. A room created with name, legacy topic, avatar, `room_alias_name` and `preset: public_chat` answers 200 with
   exactly these keys: `room_id`, `num_joined_members`, `guest_can_join`, `world_readable`, `join_rule`
   (`public`), `room_version`, `membership` (`join`), `name`, `topic`, `avatar_url`, `canonical_alias`; required
   fields have their spec types; absent optional keys are missing, never `null` or `""`.
2. A space adds `room_type: "m.space"`.
3. With `m.topic: [{text/html…},{"mimetype":"text/plain","body":"P"}]` and `topic: "L"`, the answer has
   `topic: "P"`. With `topic: ""` and no text/plain block, `topic` is omitted.
4. An invited user does not count in `num_joined_members`.
5. A `restricted` room with allow `[{type: m.room_membership, room_id: S}]` answers `allowed_room_ids: [S]`.
6. `room_version` equals the create content value. Without one it is `"1"` (unit, builder).

### AC3 — Visibility (RU4); every hidden row answers the RU3 404 body

| Caller | join_rule / history | Result | membership |
|---|---|---|---|
| joined | invite / shared | 200 | join |
| pending invite | invite / shared | 200 | invite |
| declined invite | invite / shared | 404 | - |
| never member | public | 200 | leave |
| never member | knock | 200 | leave |
| never member | invite / world_readable | 200 | leave |
| never member | invite / shared | 404 | - |
| member of allowed space | restricted | 404 | - |
| left | invite / shared | 404 | - |
| left | public | 200 | leave |
| banned | public | 200 | ban |
| banned | invite / shared | 404 | - |

### AC4 — Unknown rooms leave no trace (RU3)
1. `!doesnotexist:<server>`, `!x:other.example` and an archived room answer the RU3 404.
2. For the unknown ids, the `rooms` row count is unchanged and `RoomSupervisor.lookup_room/1` stays
   `{:error, :not_found}`.
3. The hidden 404 and the unknown 404 are byte-identical: status, body and content-type.

### AC5 — Aliases (RU1)
1. A percent-encoded `#alias:<server>` of a visible room answers 200 with its `room_id`.
2. An unknown local alias, `#x:other.example` and the alias of a hidden room answer the RU3 404.
3. `?via=matrix.org&via=other.example` gives an identical body, and the handler never reads `via`.

### AC6 — Validation (RU8)
1. `abc`, `#x` (alias without `:`) and a 256-byte value answer `400 M_INVALID_PARAM`; the injected DB module is
   not called. `!opaqueid` (no `:`) is accepted and answers the RU3 404 when unknown.
2. An alias with `+` and `%25` resolves literally.

### AC7 — Rate limit (RU7)
With the limit enabled, request 61 of one user's burst answers `429 M_LIMIT_EXCEEDED` + `retry_after_ms` + a `Retry-After` header, and a
second user is unaffected. Under `NEBU_RATE_LIMIT_DISABLED` the limit is a no-op. Pattern:
`matrix_mutual_rooms_test.exs`.

### AC8 — Unknown endpoints → 404 M_UNRECOGNIZED (RU9, RU10, RU15)
Each request is sent with no token, with a junk token and with a valid token, and answers 404 + the RU15 body,
`Content-Type: application/json` and `access-control-allow-origin` (RU15):
1. Protected:
   - `GET /_matrix/client/v3/does_not_exist`
   - `POST /_matrix/client/v3/account/deactivate`
   - `GET /_matrix/client/v3/publicRooms`
   - `GET /_matrix/client/v3/versions`
   - `GET /_matrix/federation/v1/version`
   - `GET /_matrix/client/unstable/im.nheko.summary/summary/!r:s`
2. Media and ClientV1Media:
   - `GET /_matrix/media/v3/config`
   - `GET /_matrix/media/v3/nope`
   - `GET /_matrix/client/v1/media/config`
3. HttpPublic:
   - `GET /_matrix/client/v3/auth`
   - `GET /_matrix/client/v3/profile`
   - `GET /_matrix/client/v3/login/sso/unknown/x/y`
   - `GET /_matrix/client/v3/auth/m.login.password/fallback/web`
4. Unchanged: `GET /nope` still answers the plain `404 "not found"`, and `/admin` is untouched.

### AC8a — Registration disabled (RU10a)
1. `POST /_matrix/client/v3/register` with no token, junk token, legacy token and OAuth token, with bodies `{}`,
   `{"username":"x","password":"y"}` and `?kind=guest`: `403` + the RU10a body, JSON content type, CORS header; no
   `register`/`login` rate-limit bucket touched; `capture_log` empty.
2. `GET`/`PUT /_matrix/client/v3/register` => 405 + `Allow: POST, OPTIONS`; non-preflight OPTIONS => 204.

### AC9 — Handler-level M_NOT_FOUND preserved (RU12)
With a valid token, each of these still answers `404 M_NOT_FOUND` with today's message:
- unset `GET /user/{me}/account_data/x`;
- a missing state event in a joined room;
- `GET /devices/UNKNOWN`;
- `GET /room_keys/version`;
- `GET /voip/turnServer`;
- an unknown `/_matrix/client/v1/media/download/{s}/{id}`;
- `GET /profile/@nobody:{server}`.

And handler-generated non-404 errors are untouched: `PUT /user/{me}/account_data/m.push_rules` stays `405
M_BAD_JSON` (RU12).

`/hierarchy` keeps 403 for a hidden root. For an unknown id, pin the MEASURED answer (probably 403 after the
RU18 lazy insert).

### AC10 — Unsupported methods → 405 M_UNRECOGNIZED (RU11)
1. With and without a token:

   | Request | `Allow` (plus OPTIONS) |
   |---|---|
   | `PUT /_matrix/client/v3/sync` | `GET` |
   | `GET /_matrix/client/v3/createRoom` | `POST` |
   | `POST /_matrix/client/v3/devices/X` | `GET, PUT, DELETE` |
   | `PUT /_matrix/media/v3/upload` | `POST` |
   | `DELETE /_matrix/client/v1/media/download/s/m` | (pin as routed) |

2. `HEAD /_matrix/client/v3/sync` answers 405 with an empty body.
3. A non-preflight `OPTIONS` on `/_matrix/client/v3/sync`, `/_matrix/client/v1/room_summary/!r:s` and
   `/_matrix/client/versions` answers 204 + `Allow`, never 401, no rate-limit token, no DB query. On an unknown
   path it answers 404. A preflight is unchanged (Must #39 style). Each 405 / 204 asserts the JSON content type
   (405) and `access-control-allow-origin`.
4. `Allow` lists only methods that really route.

### AC11 — `/_matrix/client/versions` (V19)
1. `POST`, `PUT` and `DELETE` answer `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS`, and `HEAD` answers 405. This
   holds in both OAuth states and regardless of `Authorization`. Implement it as an exact top-level
   `match "/_matrix/client/versions"` after the `get` and before `forward "/_matrix"`.
2. `GET` stays byte-identical in both states, and `/versions/` behaves the same.

### AC12 — No route lost its authentication (RU10)
1. A unit test sends an unauthenticated request to EVERY route clause of Protected, Media and ClientV1Media (one
   representative path per clause, with the clause's method) and expects `401 M_MISSING_TOKEN`.
2. A companion test counts the `get|post|put|delete|patch "` clauses in the three files and compares the count
   with the list length. On 7c2a8ad8 the counts are Protected 58 (+1 room_summary), Media 7, ClientV1Media 3.
3. `:authenticate` runs OidcPlug when the marker is absent, `false` or `"true"` (unit).
4. `PUT /_matrix/client/v3/profile/{u}/displayname` without a token still answers 401.

### AC13 — HttpPublic root (RU13)
1. ATDD first pins today's answers to `POST /v3/auth`, `POST /v3/profile`, and (OAuth disabled)
   `POST /v1/auth_issuer` and the unstable `auth_{issuer,metadata}`.
2. After the change:

   | Request | Answer |
   |---|---|
   | `POST /v3/auth`, `POST /v3/profile` | 404 |
   | `POST` on the legacy discovery paths | 405, `Allow: GET, OPTIONS` |
   | `PUT /login` | 405, `Allow: GET, POST` |
   | `GET /refresh` | 405, `Allow: POST` |

   None of them reaches `do_login` / `do_refresh`: the login bucket is untouched and there is no login log line.
3. `POST /login`, `POST /refresh`, `GET /login`, SSO redirect and callback, and the UIA fallback are unchanged.
   `login_refresh_test.exs`, `matrix_sso_test.exs` and the OAuth suites stay green.

### AC14 — OAuth discovery methods (RU14)
OAuth live: `POST /_matrix/client/v1/auth_metadata` and `POST /_matrix/client/v1/auth_issuer` answer 405 +
`Allow: GET, OPTIONS`. Disabled or invalid issuer: 404 `M_UNRECOGNIZED`, unchanged. GET is unchanged
(`oauth_conformance_contract_test.exs` stays green).

### AC15 — Logging law
No new log line carries a room name, topic, alias, avatar or request body. The catch-all and room_summary log
nothing on 200, 404 or 405. On a DB error, room_summary logs only the error class and answers `500 M_UNKNOWN`.
Verify with `capture_log`.

### AC16 — Existing tests updated on purpose (comment `# story oauth-room-summary-unrecognized (af)`)
1. `oauth_versions_switch_test.exs`: "Must #11/#42" (401) becomes AC11.1. "Must #41 /v3/versions" (401 without a
   token and with a junk token) becomes 404 `M_UNRECOGNIZED`. Update the moduledoc lines 12-13.
2. `media_upload_verb_test.exs` "AC2: PUT /_matrix/media/v3/upload": 404 `M_NOT_FOUND` becomes 405 `M_UNRECOGNIZED`
   (pin `Allow`).
3. Set these constants and literals to the RU15 404 body, otherwise their `refute` becomes vacuous:
   `room_tags_test.exs:31`, `room_account_data_test.exs:29`, `matrix_room_view_routes_test.exs:147-152`,
   `matrix_room_routes_test.exs:167-172`.
4. `oauth_legacy_coexistence_test.exs:494-500` ("errcode NOT pinned"): the account paths now pin 404
   `M_UNRECOGNIZED`; the `{:post, "/_matrix/client/v3/register"}` entry moves to its own assertion `403 M_FORBIDDEN`
   (RU10a). Grep on 7c2a8ad8 found no other test pinning the unauthenticated `POST /register` 401 (story-5 (e) was
   recorded, not pinned); if ATDD finds one, update it to 403 and record it.
5. `oauth_test_support.exs` `unimplemented_answer?/1`: logic unchanged, doc updated. Red-phase moduledocs change
   only if they assert.
7. Before coding, run `grep -rn "M_NOT_FOUND\|M_MISSING_TOKEN\|\"not found\"" server/test` and the full suite on
   HEAD. Record every further failure this story causes, with its disposition.

### AC17 — Documentation
Make the edits listed under "Doc edits".

## Acceptance Tests

| File (new unless noted) | Kind | Covers |
|---|---|---|
| `server/test/nebu/matrix/room_summary_test.exs` | unit (builder, validation, injected DB modules) | AC2.3, AC2.6, AC5.3, AC6, AC15 |
| `server/test/nebu/matrix/room_summary_integration_test.exs` | integration (model: `space_hierarchy_integration_test.exs`) | AC1-AC5, AC7 |
| `server/test/nebu/web/unrecognized_routes_test.exs` | unit (router level, no DB) | AC8, AC10-AC12 |
| `server/test/nebu/web/unrecognized_routes_integration_test.exs` | integration (legacy + OAuth tokens via `oauth_test_support.exs`) | AC8 (valid token), AC9, AC13, AC14 |
| `server/test/nebu/oauth/oauth_room_summary_static_test.exs` | static docs check | AC17 |
| AC16 files (modify) | unit / integration | AC16 |

## ATDD adaptation (P3/P4/P6a, 2026-10-12, HEAD 671ea2e8)

Line numbers of the Dev Notes drifted (P1 added the `ClientIP` plug to the top router pipeline, P3/P4/P6a grew `protected.ex` / `oauth.ex`): re-locate by name. Route counts re-measured on HEAD: Protected 58 (+1 room_summary), Media 7, ClientV1Media 3 (unchanged). Pinned by the red tests:

- `Nebu.Matrix.RoomSummary.build(room_id, state_events, %{num_joined_members: n, membership: m})`: pure, string-keyed map (RU5); `Server.get_room_summary/2` goes through the injectable `alias_db_module` (`lookup_alias/1`), `rooms_db_module` (`get_room_status/1`, new `get_member_membership/2`), `invite_db_module` (new `pending_invite?/2`), `room_registry_module` (`get_state/1`, only AFTER the status check).
- `Nebu.Web.Unrecognized` (`not_found/1`, `method_not_allowed/2`, `options/2`; methods exclude OPTIONS); public plug `authenticate/2` in Protected, Media, ClientV1Media; a plain OPTIONS answers 204 with `access-control-allow-origin` set by `Unrecognized.options/2` itself (CORSPlug adds nothing for an OPTIONS without `access-control-request-method`).
- Deviations from the story text: (1) AC9 "missing state event": `GET /rooms/{id}/state/{type}` is NOT routed (only the PUT state routes exist), so it is a fall-through; the test pins `GET .../event/{unknown}` instead. ~~Consequence of RU11: that GET now answers `405 M_UNRECOGNIZED` + `Allow: PUT`~~ SUPERSEDED by RU11a: that GET keeps `404 M_NOT_FOUND "Unrecognized request"` (only DELETE etc. answer `405` + `Allow: PUT`); `device_keys_test.exs` AC6 used it (vacuously) and now reads the `events` table (with a positive control). (2) createRoom has no `preset` / `room_alias_name` / `topic`: tests configure rooms through `initial_state`; the alias is the one derived from the name. (3) Extra by-design change: `oauth_metadata_test.exs` "non-GET on the discovery paths" 404 -> 405 (RU14).
- AC13.1 measured before the change (`{}` body, OAuth disabled): `POST /v3/auth`, `/v3/profile`, `/v1/auth_issuer`, unstable `auth_issuer` and `auth_metadata` all answered `400 M_UNKNOWN "Unsupported login type"`; `PUT /login`, `GET /refresh` `404 M_NOT_FOUND`.
- AC16.7 on HEAD: full suite `mix test --include integration`, 28 failures, all in the known families (`known.txt`). A throwaway reference implementation of the story (scratchpad, not committed) turned every new test green and surfaced exactly three further tests that pin the old answers: `oauth_metadata_test`, `device_keys_test` AC6 (both updated) and the four catch-all constants already listed in AC16.3.

## Dev Notes

### Code pointers (read before coding)

- `server/lib/nebu/web/router.ex`: `get "/_matrix/client/versions"` 164-166 (add the 405 `match` right after),
  `forward "/_matrix"` 200, `match _` 214 (stays), `cors/2` 235-243 (preflights, unchanged).
- `server/lib/nebu/web/router/protected.ex`: pipeline 45-48 (OidcPlug before `:match` today); model handler
  hierarchy 1551-1660 (`call_core`, `send_error`, `stream(user)`); rate-limit pattern mutual_rooms 1695-1709;
  catch-all 2068-2070. `router/media.ex` 60-62 / 103-107 and `router/client_v1_media.ex` 46-48 / 62-66: same
  change.
- `server/lib/nebu/matrix/http_public.ex`: `get "/"` 43-63 (only `true ->` changes), `post "/"` 114-123,
  `match _` 152-154, inline `authenticate/1` 1042.
- `server/lib/nebu/oauth/http.ex` 291-325: non-GET clauses of `auth_metadata/1` / `auth_issuer/1`;
  `unrecognized/1` ~525.
- `server/lib/nebu/matrix/event_dispatcher/server.ex`: add `get_room_summary/2` next to `get_space_hierarchy/2`
  (2250); reuse `room_visible?/3` 2340 (read only, trap 8), `build_room_summary/3` 2347, `join_rule/1` 2366,
  `history_visibility/1` 2374, `room_type_from_create/1` 2382, `state_event_string/3` 2406,
  `find_state_content/3` 2413; `fetch_room_state/1` 2167 (LAZY START); `build_state_events/3` 3115; injectable
  `rooms_db_module/0`, `db_module_invite/0`, `alias_db_module/0` (1-75). Return a plain map (ADR-021); a pure
  builder `Nebu.Matrix.RoomSummary.build/3` is recommended for unit tests.
- `server/lib/nebu/matrix/room/db.ex`: `get_room_status/1` 747, `lookup_alias/1` 1529; trap 1 =
  `load_members/1` 104 + `insert_room/1` 198.
- New inline SQL (ADR-018): `room/invite_db.ex` `SELECT 1 FROM room_invitations WHERE room_id=$1 AND
  invitee_id=$2 AND accepted_at IS NULL AND rejected_at IS NULL`; membership (index `(room_id, event_type,
  state_key, origin_server_ts DESC)`): `SELECT content->>'membership' FROM events WHERE room_id=$1 AND
  event_type='m.room.member' AND state_key=$2 ORDER BY origin_server_ts DESC LIMIT 1`.
- `server/lib/nebu/matrix/http.ex` 48-90: `call_core/1` maps `not_found` to exactly the RU3 body;
  `rate_limit.ex` has `key: :user`.
- Plug 1.20.3 `deps/plug/lib/plug/router.ex`: `match/2` calls `do_match(conn, method, decode_path_info!(conn),
  host)`; each route is a private `do_match/4` clause merging `:private` and putting `:plug_route`, so each
  router needs its own `defp allowed_methods(conn)`. Shared responses in a new `Nebu.Web.Unrecognized`
  (`not_found/1`, `method_not_allowed/2`, `options/2`).

### Files

New: `server/lib/nebu/web/unrecognized.ex`, optional `matrix/room_summary.ex`, the tests above; modified: the files under Code pointers, AC16 tests, docs.

### Traps

1. Lazy room creation: never `fetch_room_state/1` / `get_room_state` on an unchecked id (check status first, after
   `lookup_alias/1`).
2. Probe marker: delete `:nebu_unrecognized` before probing; a probe is a real match only without the marker.
3. No second `URI.decode_www_form/1` (the hierarchy / join handlers do it; do not copy).
4. Plug order `:match` -> `:authenticate` -> `:dispatch`; a halted conn never dispatches.
5. Preflights never reach the sub-routers; a non-preflight OPTIONS answers 204 / 404, never 405.
6. `get` does not match HEAD; the new `match` answers 405. No `Plug.Head`.
7. HttpPublic `GET "/"`: only the `true ->` branch changes.
8. Do not refactor `room_visible?/3`; `/hierarchy` is unchanged.
9. Cluster safety: no node-local state; room state via Horde, buckets via the existing plug.

### Doc edits

1. `docs/stories/oauth-broker/follow-ups.md`: row **ac** append "**Closed** by story
   oauth-room-summary-unrecognized (P6b): local-only summary, RU1-RU8 (ADR-033)."; row **af** append "**Closed**
   by story oauth-room-summary-unrecognized: 404/405 `M_UNRECOGNIZED` for Matrix fall-throughs, no auth on
   unknown endpoints (RU9-RU16)."; row **ad** append "createRoom `topic` / `m.topic` (G2) stays open (not
   trivial); room_summary reads `m.topic` text/plain."; story-5 line (e) (157) append "(M_UNRECOGNIZED part
   closed by P6b; `POST /register` now answers `403 M_FORBIDDEN` for every caller, RU10a)". New section "## From
   story oauth-room-summary-unrecognized (phase 2, P6b, 2026-10-12)" with the next free ids (other phase-2
   stories append in parallel), all non-gating: RU18 lazy room creation (SEC-relevant), RU6 unstable alias,
   restricted-room visibility via `allow` (room_summary + `/hierarchy`), RU7 rate-limit deviation.
2. `docs/architecture/07-deployment.md`: preconditions row `ac` (~195) status "closed (story
   oauth-room-summary-unrecognized, with af)"; release-notes block: "unknown Matrix endpoints answer 404/405
   `M_UNRECOGNIZED` without authentication (RU10)"; under ae note that `/v3/versions` now answers 404 (RU16).
3. `docs/matrix-api-scope.md`: line 21 replace "KNOWN GAPS under the v1.15 claim: `room_summary` (follow-up (ac),
   gate), (ad), (af)" with "KNOWN GAPS under the v1.15 claim: (ad) (non-gating)"; add in "Room Directory and
   Public Rooms" `| GET | /_matrix/client/v1/room_summary/{roomIdOrAlias} | ✅ | v1.15 core, local only (no
   federation, via ignored), auth required; visible when joined / invited / join_rule public, knock,
   knock_restricted / world_readable, else 404 M_NOT_FOUND (also unknown rooms and aliases); membership always
   present; per-user rate limit (deviation); unstable im.nheko.summary not routed. Story
   oauth-room-summary-unrecognized |`; line 308 replace "Known deviations, recorded and not pinned as correct: an
   unrouted endpoint answers `404 M_NOT_FOUND` ... before the 404." with "Since story
   oauth-room-summary-unrecognized an unrouted Matrix endpoint answers `404 M_UNRECOGNIZED` and an unsupported
   method `405 M_UNRECOGNIZED` + `Allow`, without an auth check; `POST /register` answers `403 M_FORBIDDEN` (registration not enabled, RU10a); HEAD on GET
   routes answers 405 (deviation from the RFC 9110 SHOULD)."; the same rule once under the legend; rows `/_matrix/media/v3/config` and
   `/_matrix/client/v1/media/config`: "answers 404 M_UNRECOGNIZED".
4. ADR-033: section "## Room summary and `M_UNRECOGNIZED` (phase 2, story oauth-room-summary-unrecognized)" after
   the last phase-2 section: RU1-RU18 one line each + ac/af gate status.
5. `_bmad/memory/nebu-agent-oracle/references/dev-support.md` "Error codes": add "- 404 / 405: `M_UNRECOGNIZED`
   for an unimplemented endpoint / unsupported method (Nebu: router fall-throughs only, no auth check, `Allow`
   on 405; handler-level 404 stays `M_NOT_FOUND`)"; change "400: `M_UNRECOGNIZED`" to "400: `M_UNRECOGNIZED`
   only where an endpoint defines it (e.g. unknown receipt type)"; a short "Room summary" paragraph (local-only,
   RU4, 404 for hidden rooms).
6. `docs/architecture/08-concepts.md`: short "Unrecognized endpoints (RU9-RU11)" paragraph (match ->
   authenticate -> dispatch, marker, probe, OPTIONS rule).

### Architecture compliance

ADR-018/019/020/021 as `/hierarchy`; fail-closed auth plug (AC12), anti-enumeration 404, no lazy creation, logging law (AC15); no migration, no secret, `oauth_enabled` untouched.

### Testing commands (isolated env, see the epic brief)

`quick.sh "mix test test/nebu/web/unrecognized_routes_test.exs test/nebu/matrix/room_summary_test.exs"`;
`quick.sh "mix test --include integration test/nebu/matrix test/nebu/web test/nebu/oauth test/nebu/media"` (AC16 files
green with the new pins); full gate `cleanup.sh` + `integration.sh` in the background, compare with `known.txt`;
new failures mentioning `M_NOT_FOUND`, `M_MISSING_TOKEN`, `403` or `405` belong to this story (AC16.7).

### Out of scope

Federation / `via`; unauthenticated room_summary; the `im.nheko.summary` alias; item ad; `/v3/versions` routing and health-check templates (ae, P5); `Plug.Head`; non-Matrix fall-throughs; the RU18 fix.

## Manual verification

Reference stack, OAuth off; record results in the Dev Agent Record.

1. **Element Web:** explore a space (`/hierarchy`; public, invite-only, restricted children): unchanged. Open a
   `#alias:server` link of a public room you are not in: preview + join work. No regression in Sessions, the quiet
   key-backup check (`room_keys/version` M_NOT_FOUND), media, tags; list new `M_UNRECOGNIZED` console errors.
2. **FluffyChat (Dart SDK):** space room list; `matrix.to` links to a public room (not joined) and an invite-only
   room (invited): preview shows name / topic / members; record whether the SDK calls `/v1/room_summary`
   (unverified) and check its fields; log in / out without 404/405 errors.
3. **curl:** `POST /_matrix/client/versions` => 405 + `Allow`; `GET /_matrix/client/v3/nope` (no token) => 404
   `M_UNRECOGNIZED`; `OPTIONS /_matrix/client/v3/sync` => 204; `GET
   /_matrix/client/v1/room_summary/%23alias%3A<server>` with a token => 200.
4. **Element Web registration link (legacy-only):** with `POST /register` => 403 M_FORBIDDEN, Element must show
   "registration disabled" (no generic error); record it.
5. **matrix-js-sdk claims (oracle MINOR 9, not verifiable in the gate):** confirm in Element's network tab that
   `getRoomSummary` probes `im.nheko.summary` and falls back on `M_UNRECOGNIZED` (RU6), and that room hierarchy /
   timestamp lookups take their documented `M_UNRECOGNIZED` fallbacks without user-visible errors.

## Open questions

1. Unauthenticated room_summary for public / world-readable rooms (spec MAY)? Proposed: no; revisit with guest
   access.
2. Add the unstable `im.nheko.summary` alias for matrix-js-sdk `getRoomSummary`? Proposed: decide as a follow-up
   after manual check 1.
3. Enable `Plug.Head` for GET routes (RFC 9110 SHOULD)? Proposed: no; HEAD stays 405 (RU11), documented as a
   deviation in the scope doc.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (bmad-dev-story, phase 2 P6b).

### Debug Log References

- Staged red tests (91) turned green with one implementation pass; the story tests and the AC16 files: 266 passed
  (`mix test --include integration`, 10 files). The first full run of `test/nebu/matrix test/nebu/media test/nebu/oauth`
  failed only the not-yet-written docs (static test) and known order-dependent families.
- `GET /_matrix/client/v3/login/abc` still reaches the profile read ("Profile not found", measured): the HttpPublic
  `get "/:user_id"` routes answer under every forward prefix. Pre-existing, recorded as follow-up bk, not fixed.

### Completion Notes List

- Story created by bmad-create-story (phase 2, P6b). The context analysis is complete and the dev guide is
  written.
- **Implemented (RU1-RU18, RU10a, RU11a):** `Nebu.Web.Unrecognized` (`not_found/1`, `method_not_allowed/2`, `options/2`,
  `respond/2`, `probe/2`); Protected / Media / ClientV1Media pipelines `:match` -> `:authenticate` -> `:dispatch`
  with a public `authenticate/2` (skips the OidcPlug only for `conn.private[:nebu_unrecognized] === true`) and the
  catch-all `match _, private: %{nebu_unrecognized: true}` plus a per-router `allowed_methods/1` probe of its own
  `do_match/4` clauses; top router: exact `match "/_matrix/client/versions"` (405) and explicit `POST /v3/register`
  `403 M_FORBIDDEN` (+ 405 for other methods); HttpPublic root table by `conn.script_name` and the probe for
  non-root paths; `Nebu.OAuth.Http` live-only 405 for non-GET discovery (`Config.live_state/0`).
- **room_summary:** `get "/client/v1/room_summary/:room_id_or_alias"` (RateLimit tier `room_summary` 300/min burst 60
  `key: :user`, RU8 validation without DB), `Server.get_room_summary/2` (alias -> `get_room_status/1` -> state, never
  a lazy `rooms` row; one `Nebu.Matrix.Error` not_found for unknown / archived / hidden; store errors log only the
  error class and answer 500 `M_UNKNOWN`), pure `Nebu.Matrix.RoomSummary.build/3`, `InviteDB.pending_invite?/2`,
  `Room.DB.get_member_membership/2` (reads both JSONB forms of `events.content`). No migration, no DB behaviour
  callback added (fakes unchanged).
- **RU11a carve-out** (decision of the pre-dev review M1): the catch-all keeps `404 M_NOT_FOUND "Unrecognized
  request"` for `GET /rooms/*/state[/*]`; recorded as RU11a (story, ADR-033), follow-up bf, scope doc rows 🔲.
- **Pre-dev review findings fixed in the staged tests:** M1 (carve-out tests in `unrecognized_routes_test.exs` and the
  AC9 integration list), m1 (knock_restricted never-member, restricted without allow, banned in a world_readable room),
  m2 (capture_log around a 200), m3 (room process terminated -> lazy-started 200 with the same body), m4 (the four
  `refute_catch_all` helpers also fail on any 404 / 405 `M_UNRECOGNIZED`), m5 (positive control in `device_keys_test`
  AC6), m6 (AC8.5 no longer claims a token-lookup it did not assert), m7 (AC12 guard against any other route macro,
  heredocs stripped), m8 (bucket key shape no longer pinned), m9 (three more doc assertions, plus bf / RU11a).
- **Docs (AC17):** ADR-033 section "Room summary and `M_UNRECOGNIZED`" (RU1-RU18, RU11a), 07-deployment (ac closed, ae
  note, release note), follow-ups (ac / af closed, ad note, story-5 (e), new section bf-bk), `docs/matrix-api-scope.md`
  (room_summary row, legend rule, GET state rows corrected from a stale checkmark to 🔲, media config rows, line 21
  and the OAuth coexistence note), oracle `dev-support.md`, arc42 `08-concepts.md`.
- **AC16.7 / verification:** targeted story + AC16 files 266 green; `test/nebu/web test/nebu/admin test/nebu/migration`
  only the known families; unit suite without a DB (`NEBU_DB_URL` unset) 3665 passed; prod compile only the known
  `event_dispatcher/server.ex` warning; the full `mix test --include integration` result is recorded in the final
  report of the dev run (known families only).
- **Manual verification** (story section) is NOT done: it needs a reference stack with Element Web / FluffyChat.

### Review cycle 1 (code review 0 MAJOR 4 MINOR; Kassandra CLEAN, 1 MEDIUM 2 LOW)

- **MINOR 1** HttpPublic `get "/"` now dispatches on `root_prefix(conn)` (script_name) like `post "/"`: `GET /v3/login/` lists
  the flows, `GET /v3/refresh/` answers a consistent 405 `Allow: POST`; trailing-slash test added.
- **MINOR 2** room_summary param must be valid UTF-8 without control characters (`!%00x`, `#a%FFb:c` => 400
  `M_INVALID_PARAM`, no DB access); validation test extended.
- **MINOR 3** stale RED-phase moduledocs removed, `room_summary_test.exs` calls `Nebu.Matrix.RoomSummary.build/3` directly.
- **MINOR 4** Dev Notes deviation (1) amended (superseded by RU11a).
- **Kassandra M-1 (MEDIUM, banned former invitee kept summary access):** `ban_user/2` now rejects the target's pending
  invitation (best-effort, guarded for fakes / no Repo); the summary also reads the latest `m.room.member` event BEFORE
  the invite check, so a `ban` revokes a stale pending row (defence in depth; invitations emit no member event, so
  "latest event still the invite" cannot be used). Banned: visible only by rule with membership `ban`, else the RU3
  404. Tests: invite -> ban in an invite-only room => 404 and no pending row, in a public room => `ban`, a stale row +
  ban event => 404. **/sync:** it lists invites from the same table (`get_pending_invite_rooms_for_user`), so the
  `ban_user` fix also removes the stale invite from /sync; `kick_user/2` rejects non-members (an invitee cannot be
  kicked, no invite revocation exists): follow-up bl.
- **L-1 (timing)** accepted risk, recorded in ADR RU3 (the room state is read before the visibility decision; follow-up
  bg: decide visibility from the DB first). **L-2** accepted (P8 config cache).

### File List

Server (new): `server/lib/nebu/web/unrecognized.ex`, `server/lib/nebu/matrix/room_summary.ex`.
Server (modified): `server/lib/nebu/web/router.ex`, `server/lib/nebu/web/router/protected.ex`,
`server/lib/nebu/web/router/media.ex`, `server/lib/nebu/web/router/client_v1_media.ex`,
`server/lib/nebu/matrix/http_public.ex`, `server/lib/nebu/oauth/http.ex`,
`server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/matrix/room/db.ex`,
`server/lib/nebu/matrix/room/invite_db.ex`.
Tests (new, ATDD, edited for the review findings): `server/test/nebu/web/unrecognized_routes_test.exs`,
`server/test/nebu/web/unrecognized_routes_integration_test.exs`, `server/test/nebu/matrix/room_summary_test.exs`,
`server/test/nebu/matrix/room_summary_integration_test.exs`, `server/test/nebu/oauth/oauth_room_summary_static_test.exs`.
Tests (modified): `server/test/nebu/matrix/{device_keys,matrix_room_routes,matrix_room_view_routes,room_account_data,room_tags}_test.exs`,
`server/test/nebu/media/media_upload_verb_test.exs`, `server/test/nebu/oauth/{oauth_legacy_coexistence,oauth_metadata,oauth_versions_switch}_test.exs`,
`server/test/nebu/oauth/oauth_test_support.exs`.
Docs: `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/architecture/07-deployment.md`,
`docs/architecture/08-concepts.md`, `docs/matrix-api-scope.md`, `docs/stories/oauth-broker/follow-ups.md`,
`_bmad/memory/nebu-agent-oracle/references/dev-support.md`, this story file.

- Story created by bmad-create-story (phase 2, P6b). The context analysis is complete and the dev guide is
  written.

### File List

## Change Log

- 2026-10-12: story created (ready-for-dev).
- 2026-10-12: oracle gate corrections 1-9 applied (section "Oracle gate").
- 2026-10-13: implemented (RU1-RU18, RU10a), RU11a carve-out added (pre-dev review M1), review findings m1-m9 fixed in the staged tests, docs written; status review.
