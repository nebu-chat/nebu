---
story_id: create-room-input-validation
title: "createRoom / state input validation: room_version (M_UNSUPPORTED_ROOM_VERSION, /capabilities consistent), room_alias_name (M_ROOM_IN_USE), m.room.canonical_alias content (M_BAD_ALIAS / M_INVALID_PARAM), name / depth / NUL / log hardening (follow-ups ee, ed, eg, ei)"
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

# Story: `POST /createRoom` and `PUT .../state` validate what the client sends (follow-ups `ee`, `ed`, `eg`, `ei`)

As a Matrix client user (Element Web creating a public room or Space, any client editing a room's addresses) I want the server to honour or clearly
reject what I ask for (`room_version`, `room_alias_name`, the aliases in `m.room.canonical_alias`, the room name), so that I never get a room that
silently differs from my request, an alias that does not point to the room, or a 500 for input that is simply invalid. As an operator I want no
client-supplied value (room name, alias, state content) echoed into the server log.

Follows story `create-room-initial-state-conformance` (closed `dx`): its Oracle list B4 / B5 / B7 and Kassandra INFO I-3 / I-4 / I-7 / X5-2.
The other createRoom gaps of that list (`ea` topic, `eb` invite, `ec` preset / visibility, `ef` power_level_content_override) stay open and are NOT part of this story.

## Premises verified against the code (2026-10-16)

Lesson of `dx` (a claimed root cause was wrong): every premise was checked in the code of this branch and, where possible, on the running dev
server (`nebu-oauth-dev-server-1`, read-only `bin/nebu rpc` probes; the dev DB has no rooms, so no data-based check was possible).

| Follow-up | Claim | Verified state today | What is really missing |
|---|---|---|---|
| `ee` | `room_version` ignored, always "10" | TRUE. The router (`protected.ex` `post "/client/v3/createRoom"`, ~l.1219-1294) never reads `params["room_version"]`; `do_create_room/3` (`server.ex` ~l.333-334) merges `%{"creator" => creator_id, "room_version" => "10"}` last, so even `creation_content.room_version` is overwritten. `GET /capabilities` (`protected.ex` ~l.555-568) advertises `default: "10"` and `available: 1..11 = "stable"`, i.e. 11 versions of which the server can create exactly one. `POST /rooms/{id}/upgrade` accepts ANY `new_version` string unvalidated (`upgrade_room/2` ~l.4809-4811, written into the new `m.room.create` ~l.4869). `docs/matrix-api-scope.md` says `room_versions: {6: stable}` (stale). | The 400 `M_UNSUPPORTED_ROOM_VERSION`; a capabilities answer that matches what createRoom / upgrade accept. |
| `ed` | `room_alias_name` ignored, a name-derived alias is registered instead | TRUE. Not read by the router; `Core.CreateRoomRequest` (`lib/pb/core.pb.ex` l.41-52) has no field for it. With a top-level `name`, `register_canonical_alias/3` (~l.552) derives `#<slug>:<server>` from the name, registers it with a `-2`, `-3` ... suffix on collision (non-fatal) and emits `m.room.canonical_alias` AFTER `m.room.name`. Element Web 1.12.15 (checked in the bundle of `nebu-oauth-dev-element-1`): the create-room dialog for a PUBLIC room sends `visibility: public`, `preset: public_chat` and `room_alias_name: <localpart of the alias field>` (default pre-filled from the name, user-editable; client-side rule: no `#`, `:`, `,`, URI-safe); a public Space sends `room_alias_name` too; private rooms send none. Element's "is this alias taken" check uses `GET /directory/room/{alias}`, which Nebu does not route (404 `M_UNRECOGNIZED`, any `MatrixError` counts as "available"). So today a user who typed `#team:server` can silently get `#team-2:server` or the slug of the name. | Use the given localpart, `400 M_ROOM_IN_USE` if taken, `400 M_INVALID_PARAM` for an invalid localpart, a defined interplay with the derived alias. |
| `eg` | content of `m.room.canonical_alias` not validated (PUT and `initial_state`) | TRUE. `set_room_state/2` (~l.2099-2166) only checks the allowlist, membership and power level, then persists any content. `validate_initial_state/1` (~l.5138) checks only the entry structure; probe on the dev server: `validate_initial_state([%{"type" => "m.room.canonical_alias", "content" => %{"alias" => "#elsewhere:evil.example", "alt_aliases" => ["not an alias"]}}])` returns `:ok`. What the server knows about aliases: the table `room_aliases(alias PK, room_id FK rooms, created_at)` (migration 000008), written ONLY by createRoom (`insert_room_alias/3`, `{:error, :conflict}` on the PK), read by `lookup_alias/1` (room_summary); `delete_room/1` deletes a room's aliases (orphan cleanup). There is NO alias management API: `GET/PUT/DELETE /directory/room/{alias}` and `GET /rooms/{id}/aliases` are unrouted (the scope doc rows ~l.174-176 claiming "acknowledged" are stale), `POST /join/{#alias}` does a Horde registry lookup of the literal alias string (never resolves). `upgrade_room` copies `m.room.canonical_alias` to the new room (`copy_state_events/3`) while the `room_aliases` row stays on the old room. | `M_INVALID_PARAM` for alias syntax / wrong types, `M_BAD_ALIAS` for a NEW alias that does not map to the room, on both paths. The missing directory surface is a separate follow-up (`em`). |
| `ei` | (I-3) `initial_state` content nesting unbounded | TRUE. `contains_nul?/1` (~l.5160-5163) and `CanonicalJson.normalize/1` (private, `canonical_json.ex`) recurse without a limit; only the 1 MB body cap (`JsonBody`) bounds it. Probe: a 5000-level nested `content` passes `validate_initial_state/1` (`:ok`). The PUT state body has the same property (encoded through `CanonicalJson` in `emit_state_event/5`). | A depth cap (400) checked before any recursive walk. |
| `ei` | (I-4) NUL in the top-level `name` not rejected; the `m.room.name` failure log prints `inspect(reason)` | TRUE. The router passes `params["name"]` unchecked (any JSON type). A NUL makes the `m.room.name` insert fail (PostgreSQL rejects `\u0000` in jsonb, the error context can carry the JSON snippet), logged as `Logger.warning("... m.room.name ...: #{inspect(reason)}")` (~l.449), then `update_room_name/2` fails and logs `inspect(reason)` (~l.459), then the slug alias (NUL folded to `-`) is still registered: the client gets 200 for a room WITHOUT a name event. A non-string `name` (e.g. `42`) is written as `{"name": 42}` and handed to `update_room_name/2` / `derive_alias_localpart/1`. | 400 for a non-string / NUL name before any room exists; value-free logs. |
| `ei` | (I-7) `rooms.name` has no length cap, also on PUT | TRUE. `rooms.name TEXT` (migration 000001), no check in router, core, PUT path or the `initial_state` `m.room.name` sync (D4 of the sibling). | A length cap on every writer of the name. |
| `ei` | (X5-2) the `initial_state` `m.room.name` -> `rooms.name` write logs `inspect(reason)` | TRUE (~l.5223). Same in the PUT path (~l.2155), the `m.room.create` write (~l.358, creation_content is client input), the `room_type` write (~l.480), the alias registration warnings (~l.644 / ~l.656 print the alias string = a slug of the name AND `inspect(reason)`), and the outer rescue of `create_room/2` (~l.251-253 `Exception.format(:error, e, __STACKTRACE__)`: message + args of the top frame). | One value-free log format (room id, event type, error class) for all of them. |

Already implemented and NOT to be redone: `initial_state` structure validation (`400 M_BAD_JSON`, cap 64 `M_INVALID_PARAM`), NUL inside `initial_state` entries (`400 M_BAD_JSON`), `M_NOT_JSON` / non-object body,
forbidden / skipped types, the `m.space.parent` guard, a failing `initial_state` entry -> 500 without a half room, the value-free `initial_state_error_class/1` (all sibling story);
the race-safe alias PK and orphan cleanup incl. aliases.

## Spec (Matrix CS API v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

- createRoom `room_version`: "If not provided, the homeserver is to use its configured default. If provided, the homeserver will return a 400 error with the errcode `M_UNSUPPORTED_ROOM_VERSION` if it does not support the room version."
  `/upgrade` `new_version` likewise (400 `M_UNSUPPORTED_ROOM_VERSION`). `m.room_versions` capability: `default` + `available` (what the server supports, `stable` / `unstable`).
- createRoom `room_alias_name`: "The desired room alias local part ... the complete room alias will become the canonical alias ... an `m.room.canonical_alias` event will be sent". Order step 4: after the default power levels,
  BEFORE the preset events and `initial_state` (then `name` / `topic`, then invites). 400 `M_ROOM_IN_USE` when the alias is taken.
- Room alias grammar (appendices): `#localpart:domain`, the localpart "may contain any valid non-surrogate Unicode codepoints except `:` and NUL", the whole alias incl. `#` and domain MUST NOT exceed 255 bytes.
- `PUT /rooms/{id}/state/m.room.canonical_alias`: servers SHOULD ensure that any NEW aliases are valid per the grammar and point to the room; "Servers do not validate aliases which are being removed or are already
  present in the state event." 400 `M_INVALID_PARAM` (invalid syntax), 400 `M_BAD_ALIAS` (does not point to the room).
- `m.room.canonical_alias` content: `alias` absent, `null` OR EMPTY (`""`) = "no canonical alias"; `alt_aliases` is a list of strings and may be set while `alias` is empty (Element sends `{"alias": "", "alt_aliases": [...]}`).
- `POST /rooms/{id}/upgrade`: `new_version` is REQUIRED; unsupported -> `400 M_UNSUPPORTED_ROOM_VERSION`; no permission to send `m.room.tombstone` -> `403 M_FORBIDDEN`; the server "moves local aliases to the new room" (not done today: `em`).
- `m.room_versions`: `default` = version for new rooms, MUST be in `available`; nothing requires listing all versions; one version does not conflict with `/versions` v1.15. Servers SHOULD default to v12: Nebu's `"10"` is an allowed SHOULD deviation (documented).
- StateEvent / `m.room.name`: `name` is a string; absent / `null` / `""` = no name. The spec sets no name length or JSON depth limit; it DOES require an event to be at most 65536 bytes of canonical JSON (not enforced by Nebu today: follow-up `ep`). The length and depth caps below are Nebu policy.

## Decisions

- **D1 (one room-version contract: Nebu supports exactly "10").** A single source of truth (suggested: a small pure module `Nebu.Matrix.RoomVersions` with `default/0` = `"10"`, `supported/0` = `["10"]`,
  `supported?/1`; the hard-coded `"10"` sites in `server.ex` (~l.334, ~l.3251, ~l.3793, ~l.4810) use `default/0`).
  - `GET /capabilities`: `"m.room_versions" => %{"default" => "10", "available" => %{"10" => "stable"}}` (built from the module). Reason: Nebu implements one rule set; it cannot create a v1-v9 or v11 room, and advertising
    them while createRoom now answers `M_UNSUPPORTED_ROOM_VERSION` for them would be self-contradicting. The `default` key MUST stay present: Element 1.12.15 reads it and only sends a `room_version` when the
    default does not support knock (v7) / restricted (v9) rooms; with the `"1"` fallback it would request "7" / "9" and now get a 400.
  - createRoom: `room_version` absent / `null` -> `"10"`; `"10"` -> `"10"`; any other string (incl. `""`, `"1"`, `"9"`, `"11"`, `"12"`) -> `400 M_UNSUPPORTED_ROOM_VERSION`, no room; a non-string -> `400 M_BAD_JSON`, no room.
    `creation_content.room_version` stays overwritten by the resolved version (unchanged).
  - upgrade (Oracle: `new_version` is REQUIRED, the lenient fallback goes): `new_version` absent or `null` -> `400 M_MISSING_PARAM` (router, `params` has no string value); a non-string (`10`, `true`) ->
    `400 M_BAD_JSON` (router); `""` or any unsupported string -> `400 M_UNSUPPORTED_ROOM_VERSION` (core); `"10"` ok (a same-version upgrade stays allowed, as in Synapse). All of these are decided BEFORE the room
    lookup / power check / any write (nothing is tombstoned, no new room). A valid version without the power to tombstone (today: PL >= 100) keeps answering `403 M_FORBIDDEN` (unchanged). The core drops the
    `"" -> "10"` default (`upgrade_room/2` ~l.4809-4811): `""` is unsupported there; the router is its only caller (`Core.UpgradeRoomRequest.new_version` defaults to `""`, so absent vs `""` must be told apart in the router).
    **Dependency check (2026-10-16):** no client or test relies on the fallback: Element 1.12.15 (`matrix-js-sdk` `upgradeRoom(roomId, newVersion)` in bundle `1471.js`) always posts `{new_version, additional_creators}`,
    its `/upgraderoom <new_version>` command requires the argument; all 27 `%Core.UpgradeRoomRequest{}` in `upgrade_room_test.exs` (21) and `upgrade_room_error_handling_test.exs` (6) set `new_version: "10"`;
    the HTTP tests (`matrix_room_routes_test.exs` ~l.136, ~l.225, ~l.449) send `"10"`; the only e2e scenario (`e2e/features/element/room/upgrade.feature`) is `@pending-feature` and drives Element (which sends a version).
  - Existing rooms are not touched. A room that the old, unvalidated upgrade created with another version string keeps it (Element may now show it as "unstable": honest).
  - Rejected alternative: keep `available` 1..11 and write the requested version into `m.room.create`. Nebu's auth / redaction behaviour does not change by version, a room labelled "6" would be a lie.
  - Default `"10"` instead of the spec's SHOULD v12 is a documented deviation (v12 changes room ids and creator power; out of scope).
- **D2 (`room_alias_name` is honoured).** Type and syntax first, no room before the request is known to be valid:
  - absent / `null` -> no explicit alias (D3); a non-string -> `400 M_BAD_JSON`.
  - `400 M_INVALID_PARAM`, SPEC grammar: a localpart containing `:` or NUL; a full alias `#<localpart>:<server_name>` longer than 255 BYTES (`byte_size/1`, not code points).
    `400 M_INVALID_PARAM`, NEBU POLICY (stricter than the grammar, documented as such in the scope doc): an empty localpart `""`; any whitespace (`~r/\s/u`, Synapse parity); any other C0 control character or DEL.
    Lone surrogates (not allowed by the grammar): JSON `"\ud800"` never reaches the handler, Jason refuses it (verified on the dev server: `Jason.decode(~S({"x": "\ud800"}))` -> `{:error, %Jason.DecodeError{}}`), so the HTTP answer
    is `400 M_NOT_JSON` from the existing body guard (assert exactly that); the core validator additionally rejects a localpart that is not valid UTF-8 (`String.valid?/1` false) with `M_INVALID_PARAM` (internal callers).
    Everything else is accepted verbatim (no lowercasing, NOT the slug sanitizer of the derived alias): `räume`, `a/b`, `a#b` are valid per the grammar. `server_name` = `Application.get_env(:event_dispatcher, :server_name, "nebu.local")`
    exactly as `register_canonical_alias/3` uses it (it may contain a port, e.g. `nebu.localtest.me:7443`).
  - Taken: a pre-check `alias_db_module().lookup_alias/1` BEFORE the room is created answers `400 M_ROOM_IN_USE` (normal case, no orphan); a store error there -> 500 (value-free log). The authoritative check is the PK:
    after create -> creator join -> power levels (spec step 4, BEFORE `initial_state`) `insert_room_alias/3`; `{:error, :conflict}` (lost race) -> `400 M_ROOM_IN_USE` and the orphan room is cleaned up (the existing
    `create_room/2` rescue). NO `-2` suffix fallback for an explicit alias. Then `m.room.canonical_alias` `{"alias": "#<localpart>:<server_name>"}` is emitted via `emit_state_event/5`.
  - Unlike the derived alias (non-fatal), an explicit alias is part of the request: a non-conflict insert error or a failing canonical_alias emit raises -> orphan cleanup (deletes the alias row too) -> 500.
- **D3 (interplay with the name-derived alias: the explicit alias wins, the derived alias only when none was given).** With `room_alias_name` the server registers ONLY that alias; `register_canonical_alias/3` is not run
  (no slug alias, no second canonical_alias event); an `initial_state` `m.room.canonical_alias` entry (validated, D4) is applied after step 4 and therefore wins by spec order; the top-level `name` does not touch the alias.
  Without `room_alias_name` (Admin UI `Nebu.Matrix.create_room/2` / `create_space/2`, Element private rooms, API clients) everything stays as today: the derived alias after `m.room.name`, emitted last, wins over an
  `initial_state` entry (sibling D4). That last-emitted derived alias is NEBU behaviour, not spec (the spec only knows the `room_alias_name` alias at step 4; a derived alias does not exist there): it is kept for
  creates without an explicit alias and documented as a Nebu feature in the scope doc. This is the least surprising rule: what the user typed in Element's alias field is what the room gets, and nothing changes for creates that send no alias.
- **D4 (`m.room.canonical_alias` content validation, one shared pure validator for both paths).** `content["alias"]`: absent, `null` or `""` all mean "no canonical alias" and are ACCEPTED (not a grammar
  failure; `""` is never looked up); otherwise a string; `content["alt_aliases"]`: absent / `null` or a list of strings, and may be non-empty while `alias` is empty; other types -> `400 M_INVALID_PARAM`.
  Set semantics: the given aliases are the SET {alias (when non-empty)} + alt_aliases, so a duplicate across `alias` / `alt_aliases` (or inside `alt_aliases`) is validated once and behaves exactly like listing it once
  (the content is stored as sent). NEW aliases = that set minus the set of the CURRENT state event (its non-empty alias + alt_aliases); therefore moving an existing alt alias into `alias` (or back) is NOT new and
  is not validated. Each new alias must (1) match the grammar: starts with `#`, the localpart
  up to the FIRST `:` is non-empty, the domain after it is non-empty, no NUL, at most 255 bytes, else `400 M_INVALID_PARAM`; (2) map to the room, else `400 M_BAD_ALIAS` (unknown alias, alias of another room,
  alias on another server: Nebu has no federation, so a foreign alias can never be shown to map). Removed and already-present aliases are not validated (spec), so an upgraded room whose copied canonical alias
  still maps to the OLD room can re-save its unchanged content.
  - PUT path: AFTER the allowlist, membership and power-level checks (a non-member / under-PL user keeps getting 403 and never learns whether an alias maps to the room). Current aliases: the latest
    `m.room.canonical_alias` at the same `state_key` from `messages_db_module().get_generic_state_events/1` (its `content_json` may be a double-encoded JSONB string: decode twice when the first decode yields a binary);
    a read error -> 500, nothing emitted. Mapping: `alias_db_module().lookup_alias/1` == `{:ok, room_id}`; `{:error, reason}` other than `:not_found` -> 500.
  - `initial_state` path (validated BEFORE the room exists, no orphan): there is no current state, and the only alias that can map to a not-yet-existing room is the one of `room_alias_name`; so every alias in an
    `m.room.canonical_alias` entry (any `state_key`) must be grammar-valid (`M_INVALID_PARAM`) and equal `#<room_alias_name>:<server_name>` (`M_BAD_ALIAS`). Without `room_alias_name` only entries without aliases
    (e.g. `{}`) pass. Server-authored canonical_alias events (derived alias, explicit alias, upgrade copy) are not validated.
  - `state_key` of a canonical_alias event is not restricted by this story (unchanged).
  - **Code choice for the `initial_state` path:** the spec lists `M_INVALID_ROOM_STATE` for "the initial state implied by the request is invalid", but the createRoom error list is open and the PUT codes are the
    precise ones; Nebu answers the SAME `M_INVALID_PARAM` / `M_BAD_ALIAS` on both paths (one validator, one meaning per code, clients show the error text). Documented in the scope doc.
- **D5 (hardening `ei`).**
  - (a) **Depth cap 32.** A state `content` that nests maps / lists deeper than 32 levels (the content object itself is level 1) is `400 M_BAD_JSON`: in `validate_initial_state/1` (per entry `content`, no room) and for
    the PUT state body in `do_set_room_state/4` (before the core is called). Checked by a bounded descent that stops at the limit (pattern `too_deep?/2` in `lib/nebu/oauth/http.ex` ~l.522-525), BEFORE
    `contains_nul?/1` and before anything reaches `CanonicalJson` (`CanonicalJson` itself is not changed: it also signs server-authored events).
  - (b) **Top-level `name`:** `null` / absent / `""` -> no name (unchanged); a non-string -> `400 M_BAD_JSON`; a string containing NUL -> `400 M_BAD_JSON` (same code as a NUL in `initial_state`); no room in each case.
  - (c) **Name length cap 255 Unicode code points (Nebu policy)** (`length(String.codepoints(name))`), on every writer of a room name: top-level `name`, an `initial_state` `m.room.name` entry with a string `name`, `PUT .../state/m.room.name`
    -> `400 M_INVALID_PARAM`; nothing is created / persisted (`rooms.name` and the state unchanged). 255 is accepted. `m.room.name` content type rule (PUT and `initial_state` alike): `{"name": ""}`, `{}`,
    `{"name": null}` stay valid (200, "no name": no cap / NUL error, PUT sets `rooms.name` to `""` as today); a non-string, non-null `name` (`42`, `true`, `{}`, `[]`) -> `400 M_BAD_JSON` (today: persisted as is). Generous against chat UIs (Slack 80, Discord 100) and keeps the admin list and `/sync` bounded;
    existing longer names are not touched.
  - (d) **PUT state body with a NUL anywhere** (keys or values) -> `400 M_BAD_JSON` before the core (today a 500 from the failing insert). Reuse the existing `contains_nul?/1` (make it reachable, e.g. `@doc false def`).
  - (e) **Value-free logs.** Every log line of the createRoom and set_room_state paths names only the room id, the event type and the error class (the existing `initial_state_error_class/1`, renamed / reused as a
    general `db_error_class/1`: `"postgres <code>"`, the struct module, an atom, else `"unknown"`): ~l.358 (`m.room.create`), ~l.449 (`m.room.name`), ~l.459 (`rooms.name`), ~l.480 (`room_type`), ~l.644 / ~l.656
    (alias: no alias string, it is a slug of the name), ~l.5223 (`initial_state` `rooms.name`), ~l.2155 (PUT `rooms.name`), the new explicit-alias paths. The outer rescue of `create_room/2` logs the exception module
    (and the pg code for a `Postgrex.Error`) plus `Exception.format_stacktrace/1` of the stacktrace with every argument list replaced by its arity; never `Exception.message/1` or the arguments.
- **D6 (specific errcodes from the core).** `Nebu.Matrix.Error` gets an optional `errcode` field (default `nil`); `Nebu.Matrix.Http.map_error/1` answers `{400, errcode, message}` when `errcode` is set (used with
  `status: :invalid_argument`), every existing raise (errcode `nil`) maps exactly as today. The `message` of such an error reaches the client: fixed text, no client value, no `inspect`. New codes in use:
  `M_UNSUPPORTED_ROOM_VERSION`, `M_ROOM_IN_USE`, `M_BAD_ALIAS`, `M_BAD_JSON` (core-side type checks), `M_INVALID_PARAM` (already the default of `:invalid_argument`).
- **D7 (where the checks live, order).** Router (unchanged role): body JSON / `_json` / `initial_state` structure + depth (`M_NOT_JSON` / `M_BAD_JSON` / cap `M_INVALID_PARAM`). Core: a pure, unit-testable
  `Server.validate_create_room_request/1` (`@doc false def`), called FIRST in `create_room/2`, before `start_new_room/1`, so the Admin and Space create paths are covered too. Order (first failure wins, deterministic for
  tests): name type / NUL -> name length (top level, then `initial_state` `m.room.name`) -> `room_version` -> `room_alias_name` type / syntax -> `initial_state` canonical_alias entries (syntax, then mapping) ->
  alias-taken pre-check (the only DB read). Example: a valid but taken `room_alias_name` together with `room_version: "11"` answers `M_UNSUPPORTED_ROOM_VERSION`. The router passes the raw values: `Core.CreateRoomRequest` gains `room_version: nil` and `room_alias_name: nil` (`lib/pb/core.pb.ex`; `proto/core.proto` comment-level parity
  as for `initial_state_json`); `name` is passed raw (the core type check replaces "anything goes").

## Out of scope -> new follow-ups (to be added to `follow-ups.md` by this story; next free ids after `el` are `em`-`ep`, verified by grep)

- **`em` — the room-alias directory surface is missing (found while verifying `eg`).** No `GET` / `PUT` / `DELETE /_matrix/client/v3/directory/room/{roomAlias}`, no `GET /rooms/{roomId}/aliases`; `POST /join/{#alias}`
  never resolves an alias (registry lookup of the literal string); `upgrade_room` copies `m.room.canonical_alias` but leaves the `room_aliases` row on the old room. Effects: Element's "published addresses" check
  (`GET /directory/room` must answer the room id) always fails, so aliases can only come from createRoom; `#alias:server` links do not resolve for other users. Needs its own story (alias ownership / deletion rules,
  power levels, audit). This story only corrects the stale scope-doc rows (~l.174-176) to 🔲 "unrouted, follow-up `em`".
- **`en` — depth / NUL hardening of the other JSON content routes, and internal error messages.** `PUT /rooms/{id}/send/...`, account data / room account data / tags, to-device, profile: content depth is
  unbounded through `CanonicalJson` / Jason, a NUL in message content is a 500 (`send_event` raises `"send_event failed: #{inspect(reason)}"`). Several `Nebu.Matrix.Error` messages carry `inspect(reason)` /
  `Exception.message(e)` (`create_room/2` ~l.260, ~l.381, ~l.395; `set_room_state` ~l.2164); the HTTP mapping drops them for 500, but the Admin wrappers `Nebu.Matrix.create_room/2` / `create_space/2` return
  `{:error, e.message}`. Non-gating INFO.
- **`eo` — alias namespace policy (owner decision).** With `room_alias_name` any user can claim any free localpart (Synapse default `alias_creation_rules`: allow all), e.g. `#admin`, `#announcements`, or squat
  the alias a later admin-created room would derive (it then gets `-2`). createRoom has no rate limit. Options: reserved localparts, admin-only prefixes, a per-user cap. Non-gating.
- **`ep` — events can exceed the 65536-byte spec limit (Oracle INFO).** The 1 MB body cap (`JsonBody`) lets one `initial_state` entry or one PUT state body produce an event larger than the spec MUST
  (canonical JSON of the whole event <= 65536 bytes; `type` / `state_key` <= 255 bytes). Answer `413 M_TOO_LARGE` on createRoom `initial_state` (before the room exists) and on `PUT .../state` (and, with `en`, `/send`).
  INFO, non-gating.
- Unchanged and still open: `ea`, `eb`, `ec` (note: an Element "public" room now gets its alias but is still not `public` by join rule until `ec`), `ef`. A top-level `name` whose `m.room.name` insert fails is still
  non-fatal (sibling scope; its trigger, the NUL, is now a 400).

## Acceptance Criteria

1. **Capabilities.** `GET /_matrix/client/v3/capabilities` answers `m.room_versions` = `%{"default" => "10", "available" => %{"10" => "stable"}}` (exactly one entry), and the test asserts explicitly that
   `Map.has_key?(available, default)` (the default is one of the available versions).
2. **createRoom `room_version`.** absent / `null` / `"10"` -> 200 and the room's `m.room.create` content has `room_version` `"10"`; `"11"`, `"1"`, `"9"`, `"12"`, `""`, `"foo"` -> `400 M_UNSUPPORTED_ROOM_VERSION`;
   `10` (number), `true`, `["10"]` -> `400 M_BAD_JSON`; in every 4xx case the room count does not grow. `creation_content: {"room_version": "9"}` without `room_version` -> 200, content `"10"` (unchanged). D7 first failure: a VALID but TAKEN `room_alias_name` together with `room_version: "11"` ->
   `400 M_UNSUPPORTED_ROOM_VERSION` (not `M_ROOM_IN_USE`), no room; the same taken alias with `room_version` absent -> `M_ROOM_IN_USE`.
3. **upgrade `new_version`.** For the room owner: `"11"` / `"9"` / `""` -> `400 M_UNSUPPORTED_ROOM_VERSION`; `new_version` absent and `null` -> `400 M_MISSING_PARAM`; `10` (number) / `true` -> `400 M_BAD_JSON`;
   in each case the old room has no `m.room.tombstone` and no new room exists (unit: no `insert_event`, no `start_new_room`). `"10"` -> 200 with a `replacement_room` (same-version upgrade). A member WITHOUT the
   tombstone power level sending `"10"` -> `403 M_FORBIDDEN` (unchanged). The existing upgrade suites stay green (they all send `"10"`).
4. **Explicit alias.** createRoom `{"name": "Something Else", "room_alias_name": "my-room-<rand>"}` -> 200; `room_aliases` maps `#my-room-<rand>:<server_name>` to the room; the room has exactly ONE `m.room.canonical_alias`
   event with `{"alias": "#my-room-<rand>:<server_name>"}`; no `#something-else...` row exists for the room. Unit order (spec steps 3-7): `m.room.power_levels` < `m.room.canonical_alias` < preset events
   (none are written today, `ec`; the slot is pinned so `ec` keeps it) < `initial_state` entries < `m.room.name` (and `m.room.topic` once `ea` lands). Order test with `room_alias_name` + `preset: "public_chat"` +
   `initial_state` [`m.room.join_rules`, `m.room.history_visibility`, `m.room.guest_access`]: the `m.room.canonical_alias` event precedes every `m.room.join_rules` / `m.room.history_visibility` / `m.room.guest_access`
   event of the room.
5. **Alias taken.** A second createRoom with the same `room_alias_name` (any user) -> `400 M_ROOM_IN_USE`, no room created, the first mapping unchanged. Unit (race): `lookup_alias` -> `{:error, :not_found}` but
   `insert_room_alias` -> `{:error, :conflict}` -> `Nebu.Matrix.Error` with errcode `M_ROOM_IN_USE` and the orphan room is deleted (`delete_room` called). A non-conflict insert error -> 500, room deleted.
6. **Alias syntax.** `room_alias_name` `""`, `"a:b"`, `"a b"`, `"a\tb"`, `"a\u0000b"`, `"a\u0007b"`, `"a\u007fb"`, an ASCII localpart that makes the full alias 256 bytes -> `400 M_INVALID_PARAM`; `5`, `true`, `{}` -> `400 M_BAD_JSON`;
   a raw body with `"room_alias_name": "\ud800"` (lone surrogate) -> `400 M_NOT_JSON`; core: a localpart binary that is not valid UTF-8 -> `M_INVALID_PARAM`; no room in each case. BYTE boundary with a multibyte
   localpart (`ä` = 2 bytes, padded with ASCII so the total is exact, computed from `server_name`): full alias exactly 255 bytes -> 200, 256 bytes -> `400 M_INVALID_PARAM` (although fewer than 255 code points).
   Accepted (200, alias registered verbatim): an ASCII localpart that makes the alias exactly 255 bytes, `"Räume-<rand>"`, `"a/b-<rand>"`, `"MixedCase-<rand>"` (case preserved).
7. **No explicit alias = unchanged.** Without `room_alias_name` (and with `room_alias_name: null`) the name-derived alias behaves exactly as before (`create_room_canonical_alias_test.exs` passes unchanged; a room without name gets no alias).
8. **`initial_state` canonical alias.** With `room_alias_name: "x-<rand>"`: an entry `{"alias": "#x-<rand>:<server_name>"}` or `{"alt_aliases": ["#x-<rand>:<server_name>"]}` -> 200 and the latest canonical_alias state is the entry's
   content; an entry with `"#other:<server_name>"` (unregistered, or registered to another room) -> `400 M_BAD_ALIAS`; `"not-an-alias"`, `"#nolocal"`, `"#:server"`, `"#a:"`, `alias: 5`, `alt_aliases: "x"`,
   `alt_aliases: [5]` -> `400 M_INVALID_PARAM`; no room in each 4xx case. `{"alias": "", "alt_aliases": ["#x-<rand>:<server_name>"]}` and `{"alias": null}` -> 200; the same alias in `alias` AND `alt_aliases` -> 200
   (as listed once). Without `room_alias_name`: any non-empty alias in an entry -> `400 M_BAD_ALIAS`; entries `{}`, `{"alias": ""}` -> 200 (the derived alias then wins with a `name`, sibling D4). The codes are the
   PUT codes (D4 code choice), never `M_INVALID_ROOM_STATE`.
9. **PUT canonical alias.** For a member with sufficient power level: content naming the room's own registered alias -> 200; an alias registered to another room, an unregistered alias, `#x:other.example` ->
   `400 M_BAD_ALIAS`; bad syntax / wrong types (as AC8) -> `400 M_INVALID_PARAM`; one invalid NEW entry in `alt_aliases` fails the whole request; nothing is persisted on a 4xx. Re-saving content whose alias is
   already in the current state but maps to ANOTHER room (upgraded-room case, unit with fake state + fake alias store) -> 200; removing aliases (`{}`, a shorter `alt_aliases`) -> 200. A non-member or under-PL
   sender gets 403 whatever the alias (the alias store is not consulted: unit asserts no `lookup_alias` call). A failing current-state read or alias lookup -> 500, nothing emitted. Empty-alias semantics:
   `{"alias": ""}` -> 200, `{"alias": "", "alt_aliases": [<own alias>]}` -> 200, `{"alias": null}` -> 200 (no lookup for `""` / `null`). Moving an alias that is already in the current `alt_aliases` into `alias`
   (current `{"alt_aliases": [A]}`, new `{"alias": A}`, A mapped to ANOTHER room in the fake store) -> 200 (not new, not looked up). A duplicate across `alias` / `alt_aliases` -> same result as listing it once
   (own alias: 200; foreign alias: `400 M_BAD_ALIAS`, looked up once).
10. **Depth.** An `initial_state` entry whose `content` nests 32 levels -> 200; 33 levels -> `400 M_BAD_JSON`, no room; `validate_initial_state/1` on a 5000-level content returns `{:error, :malformed}` (today `:ok`);
    a PUT state body nesting 33 levels -> `400 M_BAD_JSON`, nothing persisted; 32 levels -> 200.
11. **Name.** Top-level `name` of 255 code points -> 200 and `rooms.name` equals it; 256 -> `400 M_INVALID_PARAM`, no room; an `initial_state` `m.room.name` of 256 -> `400 M_INVALID_PARAM`, no room; `PUT .../state/m.room.name`
    with 256 -> `400 M_INVALID_PARAM`, no new event, `rooms.name` unchanged. `name` `"a\u0000b"`, `42`, `true`, `{}` -> `400 M_BAD_JSON`, no room; `name` `null` / `""` / absent -> 200 nameless room (unchanged).
    `PUT .../state/m.room.name` with `{"name": ""}`, `{}`, `{"name": null}` -> 200 (no cap / NUL error; `rooms.name` = `""`); `{"name": 42}` -> `400 M_BAD_JSON`, nothing persisted; an `initial_state`
    `m.room.name` with `{"name": 42}` -> `400 M_BAD_JSON`, no room.
    A PUT state body containing a NUL in a key or value -> `400 M_BAD_JSON` (was 500). Core: `Nebu.Matrix.create_room(creator, name: <256 code points>)` -> `{:error, _}` and no room.
12. **Value-free logs** (`ExUnit.CaptureLog`, FakeDB returning a `%Postgrex.Error{postgres: %{code: ..., pg_code: "22P05", message: ..., where: "JSON data ... MARKER ..."}}` whose `inspect` contains a marker that is also
    the room name / the alias / a creation_content value): the failure logs of `m.room.create`, `m.room.name`, `rooms.name` (top level, `initial_state`, PUT), `room_type`, derived-alias registration and emit, explicit-alias
    registration and emit contain the room id and `postgres 22P05` and NEVER the marker. The outer rescue of `create_room/2` (a seam raising `RuntimeError` with the marker in its message) logs the exception module
    and a stacktrace, not the marker.
13. **Docs.** `docs/matrix-api-scope.md`: createRoom row (read keys now incl. `room_version` and `room_alias_name`, the rules of D1-D5, `ea`/`eb`/`ec`/`ef` still not read), capabilities row (`default 10, available {10: stable}`),
    PUT state rows (canonical_alias validation, name cap, depth / NUL), upgrade row (`new_version` validation), the `/directory/room` rows -> 🔲 unrouted, follow-up `em`. `docs/architecture/07-deployment.md`: a
    behaviour-change paragraph next to the createRoom `initial_state` paragraph (~l.238): new 400s for clients, capabilities now list only v10, explicit aliases win over the derived one. `docs/stories/oauth-broker/follow-ups.md`:
    `ed`, `ee`, `eg`, `ei` closed by this story (one line each, what changed), new rows `em`, `en`, `eo`, `ep` as above. The scope doc labels the Nebu-policy rules as such (alias whitespace / C0 / DEL / empty
    localpart, name cap 255, depth 32, default v10 instead of the SHOULD v12, PUT codes on the `initial_state` path, the last-emitted derived alias).
14. **Regression.** Unchanged green, except for the three DATA adaptations listed in the Change Log (test inputs that the new contract makes invalid, no assertion about a behaviour that stays weakened):
    `create_room_canonical_alias_test.exs` (over-long-name test: 400 -> 255 characters; a byte-heavy 255 x "日" case was added), `create_room_initial_state_test.exs` (m.room.name entry without a name: `{"name": 42}` -> `{}` / `{"name": null}`),
    `space_edit_audit_test.exs` (name > 255 characters / non-string name inputs moved to the topic or to `{}` / `null`; the 300-character name now asserts the refusal; a non-string TOPIC case was added). EXTENDED (new tests only, existing ones untouched):
    `set_room_state_test.exs`, `upgrade_room_test.exs`, `matrix_room_routes_test.exs`, `matrix_client_compat_test.exs` (the exact capabilities test: default "10", `available == {"10": "stable"}`). Unchanged and green:
    `create_room_test.exs`, `create_room_initial_state_http_test.exs`, `spaces_create_room_test.exs`, `spaces_state_events_integration_test.exs`, `upgrade_room_error_handling_test.exs`.

## Acceptance Tests

- `server/test/nebu/matrix/event_dispatcher/create_room_input_validation_test.exs` (new, unit, `async: false`, FakeDB / FakeAliasDB / NoOpUserStore seams as in `create_room_canonical_alias_test.exs`):
  `validate_create_room_request/1` tables (AC2, AC6, AC8, AC11 core part), the explicit-alias flow incl. order and race (AC4, AC5), AC7 smoke, `validate_initial_state/1` depth (AC10), logs (AC12), the Admin path (AC11 last sentence).
- `server/test/nebu/matrix/event_dispatcher/set_room_state_test.exs` (extended; the FakeDB needs `get_generic_state_events/1`, plus a FakeAliasDB with `lookup_alias/1` via `:alias_db_module`): AC9, AC11 PUT name, AC12 PUT log.
- `server/test/nebu/matrix/event_dispatcher/upgrade_room_test.exs` (extended): AC3 core part (`""` / `"11"` unsupported, `"10"` ok, 403 without PL with `"10"`); the router part of AC3 (absent / `null` ->
  `M_MISSING_PARAM`, number -> `M_BAD_JSON`) in the HTTP file below or in `matrix_room_routes_test.exs`.
- `server/test/nebu/matrix/create_room_input_validation_http_test.exs` (new, `@moduletag :integration`, real stack over HTTP, helpers and `room_count/0` / `assert_rejected/5` as in `create_room_initial_state_http_test.exs`):
  AC1, AC2 (incl. the D7 first-failure case), AC3 (HTTP), AC4, AC5, AC6 (incl. the lone surrogate via a raw body as `create_raw/2` of the sibling file, the multibyte byte boundary), AC8, AC9 (HTTP: own alias 200,
  foreign alias 400 `M_BAD_ALIAS`, `{"alias": ""}` 200, non-member 403), AC10, AC11 (incl. PUT `m.room.name` `""` / `{}` / `null` 200, `42` 400). Use random localparts (`T.rand/1`) so reruns never collide (`M_ROOM_IN_USE` is now real).
- Docs: AC13 is checked in review (no docs test exists for these rows).
- No e2e: no Element UI change (`ui: false`); Element's normal private-room / Space-child creates send neither `room_version` nor `room_alias_name`; the public-room dialog path is covered by AC4 / AC5 at HTTP level.

## Tasks

- [x] `Nebu.Matrix.RoomVersions` (or equivalent functions) + use it in `/capabilities`, `do_create_room/3`, `upgrade_room/2`, the other `"10"` fallbacks (D1).
- [x] Upgrade: router `M_MISSING_PARAM` (absent / null) / `M_BAD_JSON` (non-string); core drops the `""` -> `"10"` fallback, unsupported -> `M_UNSUPPORTED_ROOM_VERSION` before any lookup (D1).
- [x] `Nebu.Matrix.Error` `errcode` field + `Nebu.Matrix.Http.map_error/1` (D6).
- [x] `Core.CreateRoomRequest` `room_version` / `room_alias_name` (`lib/pb/core.pb.ex`, `proto/core.proto`); router passes them and the raw `name` (D7).
- [x] `Server.validate_create_room_request/1` + call it first in `create_room/2`; alias-taken pre-check (D2, D5b/c, D7).
- [x] Explicit alias at spec step 4 in `do_create_room/3`; skip `register_canonical_alias/3` when given; fatal on failure (D2, D3).
- [x] Shared canonical-alias validator; wire into `set_room_state/2` after authz and into the createRoom validation (D4).
- [x] Depth check (`validate_initial_state/1`, `do_set_room_state/4`), PUT NUL check, PUT `m.room.name` cap (D5a/c/d).
- [x] Value-free logs (`db_error_class/1`), outer rescue log (D5e).
- [x] Tests (AC1-AC12, AC14), docs + follow-ups (AC13).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/` only inside the `nebu-pipeline` run. No migration needed (`room_aliases` exists, no new column). ADR-018: inline SQL stays in `Nebu.Matrix.Room.DB` (use the existing
  `insert_room_alias/3`, `lookup_alias/1`, `get_generic_state_events/1`; do not add a repository / service layer). ADR-021: plain in-process modules. ADR-011: untouched (`m.room.encryption` stays skipped in
  `initial_state`, 403 on PUT).
- **Files and current state (read before editing):**
  - `server/lib/nebu/web/router/protected.ex`: capabilities ~l.554-568; createRoom ~l.1218-1294 (guard order `json_parse_error` -> `_json` -> `validate_initial_state`); upgrade ~l.2106-2126 (passes `params["new_version"] || ""`);
    `do_set_room_state/4` ~l.2849-2884 (encryption 403 -> `json_parse_error` 400 -> core). Add the depth / NUL guards after the `json_parse_error` guard. Note `body_params/1` returns the decoded map.
  - `server/lib/nebu/matrix/event_dispatcher/server.ex`: `create_room/2` ~l.220-277 (rescue: `Nebu.Matrix.Error` -> cleanup + reraise; others -> logged + cleanup + 500); `do_create_room/3` ~l.320-494; derived alias
    ~l.496-661 (`derive_alias_localpart/1`, `bound_localpart/2`, `try_register_alias/5`, `@alias_max_bytes 255`); `@writable_state_types` ~l.2087; `set_room_state/2` ~l.2099-2166; `upgrade_room/2` ~l.4806;
    `@initial_state_forbidden_types` / `validate_initial_state/1` / `contains_nul?/1` / `apply_initial_state/3` / `initial_state_error_class/1` ~l.5108-5245; `emit_state_event/5` ~l.5281.
  - `server/lib/nebu/matrix/http.ex` `call_core/1` / `map_error/1` ~l.48-82; `server/lib/nebu/matrix/error.ex`; `server/lib/nebu/matrix/room/db.ex` `insert_room_alias/3` ~l.1507, `lookup_alias/1` ~l.1555,
    `get_generic_state_events/1` ~l.1388, `delete_room/1` (~l.250, deletes aliases); `server/lib/pb/core.pb.ex` l.41-52; `server/lib/nebu/matrix.ex` `create_space/2` ~l.476, `create_room/2` ~l.712.
- **Must be preserved:** all sibling decisions D1-D6 (structure 400 before the room, skipped types, `m.space.parent` guard, `rooms.name` sync, failing entry -> 500, K8); the creator's PL 100; the derived-alias behaviour for
  every create without `room_alias_name` (Admin UI, Spaces, auto-join / default rooms of `e2e/global-setup.ts`); `creation_content` merge with server-controlled `creator` / `room_version`; `M_NOT_JSON` / `M_BAD_JSON` for bodies.
- **Security (Kassandra will check):** authorisation before alias validation on PUT (no alias-mapping oracle for non-members); parameter-bound queries only; no client value and no `inspect(reason)` in logs
  (LAW: no sensitive data / no chat or state content in logs; room names and aliases are user content); fixed client-facing error messages (they now reach the client through D6); the explicit alias is race-safe through the PK
  (no check-then-write reliance: the pre-check is only the fast path); orphan cleanup on every post-create failure; no alias can be registered for a room that is then deleted (cleanup deletes aliases); alias squatting is a
  known, accepted policy gap (`eo`).
- **Unit seams:** `:alias_db_module` (`FakeAliasDB` needs `insert_room_alias/3` AND `lookup_alias/1`), `:rooms_db_module`, `:messages_db_module`, `:user_store_module`, `:room_supervisor_module`; reset in `on_exit`.
  `server_name` in tests comes from `Application.get_env(:event_dispatcher, :server_name)` (runtime.exs: `NEBU_SERVER_NAME`, test default `test.local` / `localhost`): build expected aliases from it, never hard-code.
- **HTTP tests:** the real stack shares `room_aliases` across tests and runs: random localparts; for the "registered to another room" cases create that other room first.
- **Element facts (bundle 1.12.15):** public room: `room_alias_name = alias.substring(1, alias.indexOf(":"))`; public Space: same + `power_level_content_override`; `room_version` only if the capabilities `default`
  lacks knock / restricted support; Element never puts `m.room.canonical_alias` into `initial_state`; the room settings "published addresses" flow PUTs `m.room.canonical_alias` with `alias` + `alt_aliases`.
- References: `docs/stories/oauth-broker/create-room-initial-state-conformance.md` (D1-D6), `_bmad-output/nebu/epics/oauth-broker/step-results/create-room-initial-state-conformance/oracle-context.md` (B4, B5, B7),
  `docs/stories/oauth-broker/security-reports/create-room-initial-state-conformance-security-review-2026-10-16.md` (I-3, I-4, I-7), `.../epic-oauth-broker-security-review-createroom-retention-delta-2026-10-16.md` (X5-2, X5-3),
  `docs/matrix-api-scope.md` (createRoom row ~l.62, capabilities ~l.24, state ~l.80-81, directory ~l.174-176), migration `server/priv/migrations/000008_room_aliases.up.sql`, spec `client-server-api/api.json`
  (`/createRoom`, `/rooms/{roomId}/state/{eventType}/{stateKey}`, `/rooms/{roomId}/upgrade`), `appendices/index.html` (Room Aliases).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (claude-sonnet-5-5), bmad-dev-story.

### Completion Notes List

- `Nebu.Matrix.RoomVersions` (new, pure): `default/0` "10", `supported/0`, `supported?/1`, `capability/0`; used by `/capabilities`, `do_create_room/3`, `upgrade_room/2` and the two other `"10"` fallbacks in `server.ex`.
- `Nebu.Matrix.Error` has an optional `errcode` (default `nil`); `Http.map_error/1` answers `{400, errcode, message}` only for `:invalid_argument` + a binary errcode, everything else maps as before.
- `Server.validate_create_room_request/1` (`@doc false def`, raises `Nebu.Matrix.Error`, returns `:ok`) is called FIRST in `create_room/2` (so Admin `create_room/2` / `create_space/2` are covered). Order as D7; the alias-taken pre-check is the only DB read.
- Explicit alias: registered right after the default power levels (spec step 4, before `initial_state`), `{:error, :conflict}` -> `M_ROOM_IN_USE` + orphan cleanup, other errors -> 500 + cleanup; the derived alias is skipped when an explicit alias was given.
- One pure canonical-alias content validator (`canonical_alias_set!/1` + `validate_alias_syntax!/1`) for the PUT path (after authz; new = given minus current state) and the `initial_state` path (only the alias of `room_alias_name` can map).
- Depth cap: `content_too_deep?/1` counts the CONTAINER itself as a level, so an empty container at level 33 is too deep (not a copy of `oauth/http.ex too_deep?/2`); used in `validate_initial_state/1` (before `contains_nul?/1`) and in the PUT router guard together with the now public `contains_nul?/1`.
- Test-review hazard (origin_server_ts tie between the explicit alias event and an `initial_state` canonical_alias entry in `Db.get_generic_state_events/1`, also an `events.event_id` PK collision because the id hashes the timestamp): cycle 0 waited for the next millisecond; review cycle 1 replaced it by deterministic timestamps without any sleep: `emit_state_event_at/6` stamps `max(now, not_before)`, `apply_initial_state/4` threads `last ts + 1` through the entries (so the later duplicate `(type, state_key)` wins too).
- Logs: `initial_state_error_class/1` became `db_error_class/1` (also handles exceptions); every createRoom / set_room_state failure log names room id, event type and error class; the outer rescue logs the exception module plus `Exception.format_stacktrace/1` with argument lists replaced by their arity; the `m.space.parent` skip warning no longer prints the creator id / the state key; orphan-cleanup logs no longer print `inspect(reason)`.
- `e2e/tests/features/acceptance/full-stack-acceptance.spec.ts` (legacy spec, not part of any Playwright project: the BDD projects only use `features/**`) sent `room_version: '16'`; the field was dropped so the spec stays valid.
- Docs (AC13): `docs/matrix-api-scope.md` (capabilities, createRoom, upgrade, PUT state rows, `/directory/room` + `/rooms/{id}/aliases` rows -> unrouted `em`, dependent-changes row), `docs/architecture/07-deployment.md` (behaviour-change paragraph), `docs/stories/oauth-broker/follow-ups.md` (`ed`, `ee`, `eg`, `ei` closed, new `em`, `en`, `eo`, `ep`, id-range line updated incl. the previously unlisted `ek`-`el`).
- Review cycle 1 (0 MAJOR / 6 MINOR, Kassandra CLEAN with 4 LOW): M1 timestamps (above); M2 the upgrade route answers `M_NOT_JSON` / `M_BAD_JSON` for a non-JSON / non-object body before `new_version`; M3 a canonical-alias event names at most 64 distinct aliases (`M_INVALID_PARAM`, Nebu policy, both paths, checked before any lookup); M4 a NUL in the room id / event type / state key of the PUT path is `400 M_BAD_JSON`; M5 `strip_stacktrace_args/1` (now `@doc false def`) also strips the `{fun, args, loc}` frame; L-1 `room_alias_name` rejects Unicode `Cc` / `Cf` (Nebu policy); L-2 `creation_content` is bounded (32 levels, no NUL, `400 M_BAD_JSON`, no room; the non-fatal `m.room.create` write is untouched, added to follow-up `en`); L-3 operator SQL for unvalidated canonical-alias claims in `docs/architecture/07-deployment.md` (checked against the throwaway database in a rolled-back transaction); L-4 the `room_created` audit metadata carries the explicit `alias`; I-5 client `type` in the `initial_state` log lines is `inspect`ed with a length limit (`log_type/1`); I-7 hand-edit comment in `core.pb.ex`; I7 `name_too_long?/1` short-circuits on `byte_size`; I10 `Nebu.Matrix.create_room/2` no longer logs `inspect(reason)` for the visibility write. New tests were added to `create_room_input_validation_test.exs`, `set_room_state_test.exs` and `matrix_room_routes_test.exs`.
- Tests (after cycle 1, fresh throwaway database): create_room_input_validation_test 58, create_room_input_validation_http_test 36, set_room_state_test 36, upgrade_room_test 25, matrix_room_routes_test 25, matrix_client_compat_test 66 (+1 excluded; it flaked 63/66 once in a looped run and was 66/66 on two reruns: the known replaces_state family), space_edit_audit_test 22, create_room_canonical_alias_test 18, create_room_initial_state_test 22. Full suite `mix test --include integration` (cycle 1): 8157/8186 passed, 8 skipped, 83 excluded, 29 failures, all by module: Nebu.Admin.RoomsFallbackNameTest (12), Nebu.Admin.LogsLive.TraceMapNodeControlsTest (3), Nebu.Admin.TemporaryCaptureManagerTest (3), Nebu.Web.AdminOidcLoginTest (3), Nebu.Web.LogStore.RetentionTest (2), Nebu.Admin.LogsLive.WarRoomTest (1), Nebu.Matrix.MatrixSsoTest (1), Nebu.Matrix.SsoLoginTest (1), Nebu.Web.OidcPlugTest (1), Nebu.Web.RegressionSyncLoadTest (1), Nebu.Media.AlertNotifierTest (1; passes alone after cleanup.sh, a media queue timing flake). The cycle-0 run had 25 failures in the same known families (the full cycle-0 list: TraceMapNodeControls, WarRoom, TemporaryCaptureManager x3, MatrixClientCompat replaces_state, LogStore.Retention x2, SsoLogin, RegressionSyncLoad, RoomsFallbackName x10, AdminOidcLogin x3). None of the failing tests is in a file this story touched; the only touched-file flake seen is the MatrixClientCompat replaces_state test (cycle 0 and once in a looped cycle-1 run). `mix compile --force --warnings-as-errors` is clean (dev and test).

### File List

- server/lib/nebu/matrix/room_versions.ex (new)
- server/lib/nebu/matrix/error.ex
- server/lib/nebu/matrix/http.ex
- server/lib/nebu/matrix/event_dispatcher/server.ex
- server/lib/nebu/web/router/protected.ex
- server/lib/pb/core.pb.ex
- server/lib/nebu/matrix.ex (review cycle 1: visibility log)
- proto/core.proto
- e2e/tests/features/acceptance/full-stack-acceptance.spec.ts
- docs/matrix-api-scope.md
- docs/architecture/07-deployment.md
- docs/stories/oauth-broker/follow-ups.md
- docs/stories/oauth-broker/create-room-input-validation.md
- tests (staged, adapted and extended by ATDD; extended again in review cycle 1 by dev): server/test/nebu/matrix/event_dispatcher/create_room_input_validation_test.exs, server/test/nebu/matrix/create_room_input_validation_http_test.exs, set_room_state_test.exs, upgrade_room_test.exs, matrix_room_routes_test.exs, matrix_client_compat_test.exs, space_edit_audit_test.exs, create_room_canonical_alias_test.exs, create_room_initial_state_test.exs

### Change Log

- 2026-10-16: story created (create-story; premises of `ee`, `ed`, `eg`, `ei` verified in the code and by read-only probes on the dev server; Element 1.12.15 request shapes checked in its bundle).
- 2026-10-16: amended with the Oracle gate (`step-results/create-room-input-validation/oracle-context.md`): upgrade `new_version` required (`M_MISSING_PARAM`, `""` unsupported, no fallback; dependency check recorded);
  empty / null `alias` = no canonical alias, set semantics for duplicates and alt -> alias moves, PUT codes on the `initial_state` path; spec vs Nebu-policy labels for the alias rules, lone surrogate (`M_NOT_JSON`) and
  byte boundary tests; spec order incl. the preset slot and the public_chat order test; derived alias marked as Nebu behaviour; `m.room.name` `""` / `{}` / `null` 200 and non-string 400; D7 first-failure and
  capabilities-default tests; new follow-up `ep` (65536-byte event limit, `413 M_TOO_LARGE`).
- 2026-10-16: ATDD (red phase) + test review applied. Three existing tests needed DATA adaptations because the new contract rejects their inputs (not a weakening of what they guard):
  `create_room_canonical_alias_test.exs` "an over-long name is bounded" 400 -> 255 characters (name cap, D5c; a byte-heavy 255 x "日" case added);
  `create_room_initial_state_test.exs` "an m.room.name entry whose name is not a string" `{"name": 42}` -> `{}` / `{"name": null}` (42 is now `400 M_BAD_JSON`, covered by the new tests);
  `space_edit_audit_test.exs` (names > 255 characters and `{"name": 42}` no longer writable): the 100000-combining-marks and 256 / 257 boundary tests moved to `m.room.topic`, the 300-character name test asserts the refusal, a 255-character name and a
  non-string TOPIC case (audit-metadata guard) were added. Dev notes from the review: the depth cap must treat an empty container at level 33 as too deep (a verbatim copy of `too_deep?/2` from `oauth/http.ex` is off by one);
  `Room.DB.get_generic_state_events/1` orders by `origin_server_ts` only, so the explicit alias event and an `initial_state` canonical_alias entry of the same millisecond tie (an HTTP /sync test exposes it);
  `e2e/tests/features/acceptance/full-stack-acceptance.spec.ts` (~l.148) sends `room_version: '16'` to createRoom, which is `400 M_UNSUPPORTED_ROOM_VERSION` now: drop the field or confirm the spec is excluded.
- 2026-10-16: dev-story implementation (all tasks): see Completion Notes; status -> review.
- 2026-10-16: review cycle 1 fixes (M1-M6, Kassandra L-1 to L-4, INFO I-5 / I-7 / I7 / I10): see Completion Notes; AC14 wording, file list and notes corrected (matrix_client_compat_test is EXTENDED, canonical_alias test adapted + byte-heavy test).
