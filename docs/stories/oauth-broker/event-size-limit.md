---
story_id: event-size-limit
title: "Matrix event size limits at write time: 413 M_TOO_LARGE when the canonical signed event exceeds 65536 bytes or type / state_key exceed 255 bytes, on PUT /rooms/{roomId}/state, PUT /rooms/{roomId}/send and POST /createRoom (initial_state, creation_content, power_level_content_override; refused before the room exists), and a Matrix 413 envelope for bodies over the 1 MB parser cap: closes follow-up ep"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-19
branch: feature/migrate-to-oauth2
---

# Story: write-time event size limits (65 536 bytes canonical, 255-byte `type` / `state_key`), follow-up `ep`

As a Nebu operator, I want every event a client makes the server write to stay within the Matrix size limits (the complete event at most
65 536 bytes of canonical JSON, `type` and `state_key` at most 255 bytes each), refused with `413 M_TOO_LARGE` BEFORE anything is persisted,
so that attacker-written state (names, topics, avatars, join rules, `m.space.child`, `creation_content`, power levels) can no longer carry
megabytes into every member's and every invitee's `/sync`, and so that the payload amplification of `unsigned.prev_content` is bounded per event.
As a Matrix client developer, I want an oversized request to get a proper Matrix error envelope (`{"errcode": "M_TOO_LARGE", "error": ...}`,
`application/json`) on every client route, including bodies over the 1 MB parser cap that today end in an empty-bodied 413.

Follows `rate-limits-join-invite-create-room` (Kassandra M-2 and delta gate L-1: the `/sync` invite_state byte budget and the `m.room.create`
reduction were stop-gaps "until `ep`") and `member-event-prev-content` (review cycle 1, Kassandra L-2: `ep` must bound state-event content at write
time, which bounds `prev_content` too). Closes `ep`. The existing read-side budgets stay as defence in depth for rows written before this story.

## Premises verified (2026-10-19, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `50145470`)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise (from the request / `ep`) | Verified text | Verdict |
|---|---|---|---|
| S1 | "a complete event MUST NOT exceed 65 536 bytes of canonical JSON" | `client-server-api/index.html#size-limits`: "The complete event MUST NOT be larger than 65536 bytes, when formatted with the federation event format, including any signatures, and encoded as Canonical JSON." | CORRECT. Note the "federation event format": Nebu has no federation (D1 says what is measured instead). |
| S2 | "`type` and `state_key` MUST NOT exceed 255 bytes each" | same section: "`state_key` MUST NOT exceed 255 bytes. `type` MUST NOT exceed 255 bytes." plus `sender` / `room_id` / `event_id` "MUST NOT exceed the size limit for user IDs / room IDs / event IDs" (appendices: 255 bytes each). "Additional keys have no limit other than that implied by the total 64 KiB limit on events." | CORRECT (bytes, not code points). `sender`, `room_id`, `event_id` are server-built in Nebu (D2). |
| S3 | "the spec error is 413 `M_TOO_LARGE`" | PARTLY WRONG. The size-limits section names NO error code. `M_TOO_LARGE` is a common errcode ("The request or entity was too large."), and 413 + `M_TOO_LARGE` is specified for media only (content repository, "returning a HTTP 413 error with the M_TOO_LARGE code"). The response tables of `PUT .../state/{eventType}/{stateKey}` (200 / 400 / 403), `PUT .../send/{eventType}/{txnId}` (200 / 400) and `POST /createRoom` (200 / 400 / 403) do not list 413. | The choice 413 `M_TOO_LARGE` is a NEBU decision (Synapse parity: Synapse's `EventSizeError` is a 413 `M_TOO_LARGE` for both the total size and the per-key limits; recalled from Synapse, not verifiable offline), D2. The Oracle gate must confirm or correct it. |
| S4 | the "federation event format" | `rooms/v10/index.html`, Persistent Data Unit (v4-v10): `auth_events`, `content`, `depth`, `hashes`, `origin_server_ts`, `prev_events`, `redacts`, `room_id`, `sender`, `signatures`, `state_key`, `type`, `unsigned`; NO `event_id` (it is the reference hash). | Nebu stores none of `auth_events`, `prev_events`, `depth`, `hashes` (no DAG), and does store `event_id`: D1. |
| S5 | canonical JSON | `appendices/index.html#canonical-json`: shortest UTF-8 encoding, keys sorted by code point, integers only in [-(2^53)+1, 2^53-1], "Float values are not permitted", `\u` escapes in LOWERCASE hex (`u000X` with `b`, `e`-`f`; `u001X` with `a`-`f`). | Nebu's `CanonicalJson` is Jason with sorted keys: it renders floats (`1.0e2`) and UPPERCASE `\u001F`. Byte counts are identical for escapes; floats are not canonical at all. Out of scope, new follow-up `fn`. The size is measured on Nebu's canonical bytes (D1). |

### What Nebu does today (code)

| Question | Verified state |
|---|---|
| How is an event built, hashed, signed, stored? | Every write site builds the same six-key map `%{"room_id", "type", "state_key", "sender", "content", "origin_server_ts"}`, then `event_id = Nebu.Matrix.EventId.generate(event_map)` (`"$" <> Base.url_encode64(SHA-256(CanonicalJson(map without signatures / unsigned)), padding: false)`: always 44 bytes), `event_json = Nebu.Matrix.CanonicalJson.encode!(event_map)` (the SAME bytes), an Ed25519 signature over `event_json`, and the stored map `event_map + "event_id" + "signatures" => %{"nebu" => Base.encode64(sig)}` (64-byte signature: always 88 base64 characters). Write sites: `EventDispatcher.Server.emit_state_event_at/6` (server.ex l.7564-7593: PUT state, `initial_state`, preset, name, topic, alias events, upgrade copies), the inline `m.room.create` of `do_create_room/3` (l.341-371), `Room.Server.do_send_event/7` (room/server.ex l.760-830: `/send`), `Room.Server.emit_membership_event/4` (l.666-701) and `emit_power_levels_event/3` (l.713-746), and the kick / ban / invite / decline builders in server.ex (l.~6090-7013). |
| `state_key` of a message event | `do_send_event/7` puts `"state_key" => nil` into the signed map (bugfix unsigned-replaces-state: NULL in the DB), so `"state_key":null` IS part of the signed canonical bytes. |
| `CanonicalJson` vs `Jason.encode!` | `CanonicalJson.encode!/1` = keys `to_string`ed and sorted into `Jason.OrderedObject`, then `Jason.encode!` with the default `escape: :json` (deps/jason 1.4.5 `encode.ex` l.284-300: only `0x00`-`0x1F` (`\uXXXX`, or `\b \t \n \f \r`), `"` and `\` are escaped; `/`, DEL, U+2028 / U+2029 and every non-ASCII code point are written raw as UTF-8). So for a string-keyed map, `byte_size(Jason.encode!(m)) == byte_size(CanonicalJson.encode!(m))`: only the key ORDER differs. This is the fact that makes the check cheap (D3); AC1 (b) pins it. |
| PUT state route | `protected.ex` l.2385-2391 -> `do_set_room_state/4` (l.3010-3057): `m.room.encryption` 403, `json_parse_error` 400 M_BAD_JSON, NUL in a path identifier 400, `content_too_deep?` 400, `contains_nul?` 400, then `content_json: Jason.encode!(content)` and `EventDispatcher.Server.set_room_state/2`. No size check. Path values are decoded twice (Plug.Router + `URI.decode_www_form`); the decoded value is what is stored. |
| `set_room_state/2` (server.ex l.3719-3790) | allowlist (9 types, all short) -> 403; `Jason.decode(content_json)`; `fetch_room_state/1` (LAZY-STARTS a Room GenServer for an unknown id, whose `do_init/1` inserts a `rooms` row: room/server.ex l.244-260); membership + `state_default` check; canonical_alias / name / topic content rules (alias rules read the DB); `m.space.parent` parent check (DB); `emit_state_event/5`; then `rooms.name` denormalisation (after a successful emit only). `{:error, reason}` -> 500 with `inspect(reason)` in the message (en). |
| `/send` route | `protected.ex` l.1462-1490: `json_parse_error` 400, then `content: Jason.encode!(content)` -> `EventDispatcher.Server.send_event/2` (l.160-221: `Jason.decode` again, room lookup 404, membership 403) -> `Room.Server.send_event/6` (power level, txn dedup ETS, `check_room_status_for_update` = `SELECT ... FOR UPDATE`, `do_send_event/7`). No depth / NUL check (en), no size check. `{:error, reason}` -> 500 with `inspect(reason)`. |
| createRoom route and validation | `protected.ex` l.1245-1356: rate-limit charge FIRST (`with_membership_charge/3`), then `validate_initial_state/1` (shape, 64 entries, depth 32, NUL: server.ex l.7405-7425), `creation_content_json = Jason.encode!(m)`, `initial_state_json = Jason.encode!(list)`; `create_room/2` (l.224) calls `validate_create_room_request/1` (l.822-865, the D7 first-failure-wins order 1 - 8: pure steps 1-5f, then the DB reads 6 alias-taken, 7 invitee existence, 8 pending caps) BEFORE `start_new_room/1`. |
| Which createRoom events carry client-sized content | `m.room.create` = `Map.merge(creation_content, %{creator, room_version})` (only depth / NUL bounded, step 2b); `m.room.power_levels` = `merged_power_levels(creator, override, level_invitees)` (override: integer values and valid user-id keys for `users` / `events`, ANY other top-level key with any content up to depth 32: `validate_power_level_override/1` l.1246-1263 `{_other_key, _value} -> :ok`; the `users` and `events` maps have no entry cap); every `initial_state` entry (shape only; topic entries: `topic` <= 1024 code points, `m.topic` up to 8 bodies of <= 4096 code points: 8 x 4096 x 6 bytes (C0 controls escape to `\u00XX`) = 196 608 bytes is LEGAL today, so the code-point caps do not bound bytes). Bounded by construction: name (<= 255 code points: <= 1 530 bytes escaped), top-level topic (`topic_event_content/1` writes it twice: <= 2 x 1024 x 6 = 12 288 bytes), preset events (constant), aliases (<= 64 x 255), member / invite events (`{"membership", "is_direct"}`, user ids <= 255). |
| Room id length | `generate_room_id/0` (l.1738): `"!" <> 16 hex <> ":" <> server_name`: a constant length per server, hex only (no escapes). |
| `origin_server_ts` | milliseconds, 13 digits until the year 2286; the createRoom chain stamps `last_ts + 1` (same digit count). |
| Power levels write | `Room.Server.handle_call({:set_power_levels, ...})` (room/server.ex l.414-450) writes `rooms.power_levels_json` FIRST and then the event (non-fatal emit): a size refusal must come BEFORE the column write. Callers: createRoom step 3 (`:ok = ...`, a non-`:ok` is a MatchError -> generic 500 + cleanup), `upgrade_room` (default levels only), `EventDispatcher.Server.set_power_levels/2` (no HTTP route). `PUT .../state/m.room.power_levels` is 403 (not allowlisted, `eq`). |
| Upgrade copy | `copy_state_events/3` (l.7600-7680) re-emits the old room's state through `emit_state_event/5` and IGNORES the result: a refused copy is silently skipped. |
| JsonBody over 1 MB | `Nebu.Web.Plugs.JsonBody` (`length: 1_000_000`): `Plug.Parsers.RequestTooLargeError` is caught only for the account-data / room-tag PUT shapes (`:body_too_large`, the handler answers `413 M_TOO_LARGE`) and `/oauth2/register` (OAuth shape); every other route RE-RAISES. The router has no `Plug.ErrorHandler`, so Bandit 1.12.5 answers (`deps/bandit/lib/bandit/pipeline.ex` l.232-245 -> `http1/socket.ex` `send_on_error/2` l.601-613): `send_headers(socket, 413, [{"connection", "close"}], :no_body)`: **a 413 with NO body, no errcode, no CORS headers**. So today an oversized `/send` / PUT state / createRoom body is NOT a Matrix error. Pinned as "raises" by `room_account_data_hardening_test.exs` l.216-223 (`assert_generic_413/3`). |
| Existing `M_TOO_LARGE` uses | media upload (`media.ex` l.209 / 469, own reader), account data and room tags (`protected.ex` l.916-1180, 64 KiB per body). The command layer has no "too large" status: `Nebu.Matrix.Status` has 10 atoms, `Http.map_error/1` maps `resource_exhausted` to `403 M_ROOM_FULL`; there is no path to a 413 from `call_core/1`. |
| Read-side budgets (unchanged by this story) | `EventDispatcher.Server` l.4732-4830: `@invite_event_max_bytes 65_536`, `@invite_state_budget_bytes 8 MiB`, `stripped_content/1` (an `m.room.create` content above 64 KiB is reduced to `creator`, `room_version`, `type`, `predecessor`), `limit_invite_state/3`. Comments there say "bounded only by the 1 MB body until follow-up `ep`" (to update, AC10 (f)). `/sync` timeline: 20 events per room (l.4449); the `rooms.join` state section carries the full current state of each room (all slots) with `prev_content` since member-event-prev-content. |
| User ids: where created, 255 bytes? (Oracle gate) | Every identity is derived by ONE function, `Nebu.Matrix.UserId.from_claims/2` (`"@" <> localpart(claims) <> ":" <> server_name`; callers: `OidcPlug` l.143, `HttpPublic` l.478 (login), `SsoLogin` l.524 / 587 / 636, `AccountManagement` l.55, `Admin.Auth` l.294 / 338, `Nebu.Matrix` l.204 / 887). `localpart/1` takes the configured claim, else `preferred_username`, `name`, `sub`, and `sanitize/1` downcases and maps every character outside `a-z 0-9 . _ = - / +` to `_` (ASCII only, so bytes == characters), **with NO length bound**: a 300-character IdP claim yields a 300+-byte user id, written as `sender` / `state_key` of member events. `UserId.valid?/1` (`\A@[a-z0-9._=\-\/+]+:[A-Za-z0-9.\-]+\z`) has no length bound either; only `validate_invite_list/2` adds `byte_size <= 255`. The `users.user_id` column is `TEXT`. **Verdict: D2 (d)'s premise "sender is server-built and within the limit" was WRONG; fixed by D12.** |
| Room aliases: 255 BYTES incl. `#` and domain? (Oracle gate) | YES, everywhere aliases are created: `validate_room_alias_name/1` (l.1424-1435: `byte_size(full_alias(localpart)) > 255`, `full_alias = "#" <> localpart <> ":" <> server_name`), `validate_alias_syntax!/1` (l.1565-1580: `byte_size(alias_str) <= 255` for `m.room.canonical_alias` `alias` / `alt_aliases`, initial_state and PUT; only NEW aliases are validated on PUT, per spec), the derived alias (l.682-690: the localpart is bounded so the full alias fits 255 bytes). Bytes, not code points. Boundary tests with multi-byte localparts exist for `room_alias_name` (create-room-input-validation, Oracle "multibyte localpart at exactly 255 / 256 bytes"); this story adds the `alt_aliases` and the derived-alias cases (AC11 (c)). |
| Upgrade defaults of the security state (Oracle caveat) | The new room of `upgrade_room` gets NO preset events; its state is the copy. Missing `m.room.join_rules` is read as `invite` (`join_rules.ex` l.22, Nebu / Synapse policy: never more open than a copied `public`); `private`, an unknown value and a malformed event refuse every join, even invited ones; `restricted` / `knock_restricted` admit an invitation or a member of an `allow[]` room. Missing `m.room.guest_access` = `forbidden` (spec default; not enforced, `es`). Missing `m.room.history_visibility` = `shared` (spec default; stored, not enforced, `es`): a skipped legacy `joined` / `invited` value would make the new room MORE open in spec terms, and a skipped legacy malformed / `private` join rule would become `invite` (more open than refuse-all). D8 (b) prevents both. |
| Profile, account data, kick / ban | `update_profile/2` (l.3224) stores `displayname` / `avatar_url` without a length cap and writes NO event (no member event carries them). Account data / tags have their own caps (`NEBU_ROOM_ACCOUNT_DATA_MAX_BYTES`, 64 KiB). `kick_user/2` / `ban_user/2` put a client `reason` into a member event but have no client route (`ex`). |
| The Kassandra report files | `security-reports/rate-limits-join-invite-create-room-security-review-2026-10-19.md` has M-2 (cycle 0: ~5 MB per invitation, ~500 MB per victim's initial sync) and the delta gate L-1 (100 invitations can still carry ~100 MB of `m.room.create` content). **There is NO file `member-event-prev-content-security-review-2026-10-19.md`** in `security-reports/` (the request named it): the L-2 text exists only as the "Note (member-event-prev-content, review cycle 1, Kassandra L-2)" of `ep` and in the pipeline-state line of that story. This story uses that note as the source. |
| Existing tests that write oversized events through HTTP | `membership_write_limits_cycle1_http_test.exs` l.248-262 creates a room with a 100 KB `creation_content` through `POST /createRoom` (it becomes a 413: deliberate re-pin, AC8 (c)); l.215-245 already inserts the 70 KiB topic through `DB.insert_event/1` (unchanged). `invite_state_budget_test.exs` is pure (unchanged). |

### Sizing evidence (ONE story, smaller than member-event-prev-content)

- `server/lib`: one new pure module `Nebu.Matrix.EventSize` (about 80 lines); `Nebu.Matrix.Status` one atom, `Http.map_error/1` one clause; `JsonBody`
  one rescue branch (about 15 lines); `protected.ex` two pre-checks (about 30 lines); `EventDispatcher.Server` the createRoom size step (about 70
  lines), the backstop in `emit_state_event_at/6` and the inline create event, the 413 mapping in `set_room_state/2`, `send_event/2`, the
  `initial_state` / create / power-level failure branches (about 50 lines); `Room.Server` backstops in `do_send_event/7` and
  `set_power_levels` (about 25 lines). Estimate 270 lines, no migration, no new route, no new dependency, no new SQL.
- Tests: one pure suite, one HTTP real-DB suite, one core real-DB suite, one plug suite, one docs suite; deliberate re-pins in three existing suites
  and the id line of six docs suites.
- Docs / e2e: scope doc, 07-deployment (release note + operator query), CHANGELOG, follow-ups; two e2e runs, no new scenario.
- Split out: canonical-JSON number / hex conformance (`fn`), the encode / decode round trips (`fo`, incl. the optional part of L-2), the unbounded
  NUMBER of state slots per room / per sync response (`fp`).

## Decisions

- **D1 (what is measured: Nebu's complete signed event, in Nebu's canonical JSON).** The size of an event is
  `byte_size(Nebu.Matrix.CanonicalJson.encode!(stored_event))`, where `stored_event` is exactly the map Nebu persists and serves before any
  read-time `unsigned`: the six signed keys `content`, `origin_server_ts`, `room_id`, `sender`, `state_key` (the string, or JSON `null` for a
  message event, because that is what Nebu signs), `type`, plus `event_id` (44 bytes) and `signatures` (`{"nebu": <88 base64 chars>}`).
  Rationale: the spec measures "the federation event format, including any signatures" (S1). Nebu does not federate by design and has no PDU: the
  keys `auth_events`, `prev_events`, `depth`, `hashes` do not exist, `event_id` does. The stored signed event is the closest thing Nebu has to "the
  complete event", it is exactly what every client receives (minus `unsigned`, which is computed at read time) and what a future export would
  carry. **No reserve** is added for the missing PDU keys (a federating PDU would be roughly 1-2 KB larger: Nebu accepts events whose content is up
  to that much larger than Synapse would; recorded, accepted: there is no federation to break). `unsigned` is excluded (spec: "not covered by the
  signatures"; it does not exist at write time). The measure is the CANONICAL form, never the request body: whitespace, the SHADOWED value of a duplicate key (Jason keeps the FIRST value of a duplicate key, verified; Synapse keeps the last: recorded
  divergence, harmless for the size because the size is measured after the decode) and `\uXXXX` escapes of non-ASCII characters in the body shrink, floats grow (`1e2` -> `100.0`), escapes of control characters stay 6 bytes.
- **D2 (limits and errors).** (a) An event whose D1 size is greater than **65 536** bytes is refused; exactly 65 536 is accepted. (b) `type` and
  `state_key` are refused when their UTF-8 byte size (`byte_size/1` of the decoded string, NOT of its JSON encoding, NOT code points) is greater than
  **255**. (c) Every refusal is **`413 M_TOO_LARGE`** with a FIXED message (no client value, no number other than the limit): "Event type exceeds
  255 bytes", "State key exceeds 255 bytes", "Event exceeds the maximum size of 65536 bytes"; createRoom names the source: "An initial_state
  event type exceeds 255 bytes", "An initial_state state key exceeds 255 bytes", "An initial_state event exceeds the maximum size of 65536 bytes",
  "creation_content makes the m.room.create event exceed the maximum size of 65536 bytes", "power_level_content_override makes the
  m.room.power_levels event exceed the maximum size of 65536 bytes". 413 is a Nebu decision with Synapse parity (S3; label it so in the scope doc),
  for the per-key limits too (one rule, one code: a client cannot shorten a `type` it needs any more than it can shorten content). **The
  strictly table-conformant alternative was `400 M_TOO_LARGE`** (the response tables of the three endpoints list 400, not 413; clients act on the
  errcode, so either works for them). 413 was chosen because it is the HTTP status for "payload too large", the spec itself pairs `M_TOO_LARGE`
  with 413 in the content repository, Nebu already answers 413 `M_TOO_LARGE` for account data, tags and media, the 1 MB body cap (D7) is a 413 by
  nature, and Synapse (the server Element is tested against) answers 413: one status for every "too large" answer of Nebu. `M_INVALID_PARAM`
  for the per-key limits was the other option (Oracle: acceptable; `M_BAD_JSON` would be wrong). (d) `event_id` (44 bytes) and `room_id`
  (`1 + 16 + 1 + byte_size(server_name)`, within 255 for any server name of at most 237 bytes) are server-built and not checked per event (a path
  room id of an unknown room only enters the envelope of the pre-check, D4). `sender` is the authenticated user id: bounded at its source by D12;
  as defence in depth for sessions minted before D12, `EventSize.check_keys/3` also refuses a `sender` above 255 bytes on the three routes with
  `403 M_FORBIDDEN` "Your user id exceeds 255 bytes: sign in again" (the client cannot fix it by changing the request, so not a 413). (e) Mapping: a new status `Nebu.Matrix.Status.too_large/0` (`:too_large`, added to
  the `t()` type) and one `Http.map_error/1` clause `status == :too_large -> {413, "M_TOO_LARGE", message || "Event exceeds the maximum size of
  65536 bytes"}` (errcode ignored); the Admin wrappers (`Nebu.Matrix.create_room/2`, `create_space/2`, `set_space_state/5`) return the fixed
  `message` as before. The envelope is exactly `{"errcode", "error"}`, `application/json`.
- **D3 (one pure module, no extra pass over the content).** New `Nebu.Matrix.EventSize` (pure, no DB, next to `CanonicalJson`; ADR-018 allows a
  pure helper, it holds no domain model): `max_event_bytes/0` (65_536), `max_key_bytes/0` (255), `signed_overhead/0` (the bytes `event_id` and
  `signatures` add: `,"event_id":"` + 44 + `"` = 58 and `,"signatures":{"nebu":"` + 88 + `"}` = 113, total **171**, computed from the
  constituent strings in the module, not a magic literal), `stored_bytes(event_json)` (= `byte_size(event_json) + signed_overhead()`, for the write
  sites that already hold the signed canonical bytes), `predicted_bytes(envelope, content_bytes)` (= `byte_size(CanonicalJson.encode!(Map.put(envelope,
  "content", %{}))) - 2 + content_bytes + signed_overhead()`: the envelope is encoded with an empty content placeholder, a few hundred bytes, and
  the content size is passed in), `check_keys(type, state_key_or_nil, sender)` returning `:ok | {:error, :type_too_long | :state_key_too_long | :sender_too_long}` (`:sender_too_long`
  maps to the 403 of D2 (d), the others to 413; a `nil` state key, the `/send` route, is not counted) and `check(envelope, content_bytes)` returning
  `:ok | {:error, :event_too_large}` (the SIZE only; the keys are `check_keys/3`). The envelope is a STRING-keyed map without `"content"`. The content size passed in is `byte_size(Jason.encode!(content))` that the callers ALREADY compute
  (the routers' `Jason.encode!(content)`, the createRoom router's per-entry encode is new, D6), equal to the canonical content size (premise table).
  Message events pass `"state_key" => nil` in the envelope.
- **D4 (`PUT .../state`: pre-check in the router, backstop at the write).** (a) `do_set_room_state/4` order, first failure wins: `m.room.encryption`
  403 -> `json_parse_error` 400 -> NUL in a path identifier 400 -> **`type` / `state_key` > 255 bytes 413** -> depth 400 -> NUL in content 400 ->
  `content_json = Jason.encode!(content)` (moved before the check, still computed once) -> **`EventSize.check(%{"room_id" => room, "sender" => user,
  "type" => type, "state_key" => state_key, "origin_server_ts" => now_ms()}, byte_size(content_json))` 413** (string keys, like D3) -> `call_core`. The size checks come BEFORE the room lookup, the
  membership and power-level checks and the type allowlist: they reveal nothing about the room, cost no DB statement, and an unknown room id with an
  oversized body is refused without lazy-starting a Room (no `rooms` row is created for it). (b) Authoritative backstop: `emit_state_event_at/6`
  checks `EventSize.stored_bytes(event_json)` right after `event_json` is computed and returns `{:error, :event_too_large}` WITHOUT inserting,
  broadcasting or signing further (no extra encode: the bytes exist already). `set_room_state/2` maps it to `raise Nebu.Matrix.Error, status:
  :too_large, message: <fixed text>` (it reaches the Admin `set_space_state/5` the same way); the `rooms.name` denormalisation runs only after a
  successful emit (unchanged), so nothing is written. Every other `{:error, reason}` keeps its current mapping (`en`). (c) The pre-check and the
  backstop agree exactly (same room id, sender, type, state key; `now_ms()` and the stamped ts have the same digit count).
- **D5 (`PUT .../send`: the same, size only).** Router order: `json_parse_error` 400 -> **`type` > 255 bytes 413** -> `content_json =
  Jason.encode!(content)` -> **`EventSize.check(%{..., "state_key" => nil}, byte_size(content_json))` 413** -> `call_core`. Backstop in
  `Room.Server.do_send_event/7` after `event_json`: `{:reply, {:error, :event_too_large}, state}` BEFORE `insert_event`, the ETS txn-dedup insert
  and the broadcast (a retry with the same `txn_id` is processed afresh, never answered with a cached id); `EventDispatcher.Server.send_event/2` maps
  it to 413 (a fixed message, not the `inspect(reason)` of the generic branch). The `txn_id` is not part of the event. **Taken from `en`: nothing
  but this size rule.** Left with `en`: depth / NUL on `/send` (a NUL in message content is still a 500), on account data, tags, to-device and
  profile, and the `inspect(reason)` messages of the other branches.
- **D6 (createRoom: one pure size step BEFORE the room exists, plus backstops).** (a) New step **5g** of `validate_create_room_request/1`, after 5f
  (creator lock-out) and BEFORE 6 (the alias-taken read), so a refused request costs no DB statement and creates nothing: 5g runs after every depth
  check (creation_content 2b, override 5b, initial_state in the router) because `Jason.encode!` recurses. The envelope uses the creator as sender, a
  room id PLACEHOLDER of the exact generated length (`"!" <> String.duplicate("0", 16) <> ":" <> server_name`, `server_name` read through the
  same `Application.get_env(:event_dispatcher, :server_name, "nebu.local")` as `generate_room_id/0`; a unit test pins
  `byte_size(generate_room_id()) == byte_size(placeholder)`; the dev may instead generate the id before the validation and pass it in: record the
  choice), `now_ms()`. Checked in this order, first failure wins: (1) `m.room.create` with the content `do_create_room/3` will write (the same
  merge: client `creation_content` + `creator` + `room_version`); (2) `m.room.power_levels` with `merged_power_levels(creator, override,
  level_invitees)` (the invitees of a `trusted_private_chat` count); (3) every `initial_state` object entry in list order: `type` bytes, then
  `state_key` bytes, then the event size, for ALL entries including those `apply_initial_state/4` will skip (a forbidden type, a failing
  `m.space.parent`) and exact duplicates (one rule, no run-time dependency). The top-level `name` and `topic` events, the preset, alias, member and
  invite events are NOT checked in 5g: bounded far below the limit by existing rules (premise table: <= 1 530, <= 12 288, constant, <= 16 KiB,
  <= ~600 bytes); AC4 (h) pins the worst case of the top-level topic. (b) Backstops (unreachable when 5g is correct; they make the write sites
  safe for any caller): `emit_state_event_at/6` (D4 b) covers `initial_state`, preset, name, topic and alias events: in `apply_initial_state/4` an
  `{:error, :event_too_large}` raises `:too_large` (the existing rescue deletes the room and re-raises: the client gets the 413, nothing remains);
  name / topic stay non-fatal (skipped with the existing warning); the inline `m.room.create` write checks `stored_bytes` before
  `insert_event` and raises `:too_large` (fatal for THIS reason only; the other non-fatal create-write failures stay with `en`);
  `Room.Server.handle_call({:set_power_levels, ...})` checks `predicted_bytes` of the levels (from the `Jason.encode!(new_levels)` it computes
  anyway) BEFORE `db_module().set_power_levels/2` and replies `{:error, :event_too_large}` (nothing written, state unchanged); createRoom step 3
  maps that to `:too_large` instead of the `:ok =` MatchError. (c) The rate-limit charge stays FIRST (rate-limits D2): a 413 createRoom has spent
  its `create_room` (and invite) units, like every other refused createRoom.
- **D7 (bodies over the 1 MB parser cap get a Matrix envelope).** `JsonBody` keeps `length: 1_000_000` (the cap is not changed). In its
  `RequestTooLargeError` rescue, a request whose `path_info` starts with `"_matrix"` and that is NOT an opaque-content PUT (account data / tags keep
  their own handler answer and texts) and not `/oauth2/register` is answered directly: `413`, `application/json`, `{"errcode": "M_TOO_LARGE",
  "error": "Request body is too large"}`, `Plug.Conn.halt/1` (no route runs, nothing is written; the CORS headers set earlier by `:cors` stay on the
  response, so a browser client can read the error). All other paths keep the re-raise (Bandit's empty 413). This includes `/_matrix/media`
  (a JSON-typed upload over 1 MB was an empty 413 and becomes the spec's media answer `413 M_TOO_LARGE`; the pinned small-JSON-upload behaviour of
  `media_upload_test.exs` l.197-210 is unchanged). Rationale: the request asked to check it; it is not a Matrix error today; it is 15 lines in one
  place.
- **D8 (legacy rows: detected, never deleted, read paths unchanged).** No migration, no backfill, no deletion: events written before this story
  stay exactly as stored and are delivered as today (timeline, state, `/messages`, `/event`, `/relations`, stripped state). The `/sync` invite
  budget (`limit_invite_state/3`: 64 KiB per optional event, 8 MiB per response) and the `m.room.create` reduction above 64 KiB stay unchanged as
  defence in depth for those rows. A legacy oversized state event keeps travelling as the `prev_content` of its slot's NEXT event; the slot is clean
  after TWO new writes (the 07-deployment note tells room admins how). A legacy oversized MESSAGE event cannot be removed (no redaction, `fl` (d)).
  (a) `upgrade_room` skips a legacy oversized state event of the old room (the existing ignore of `copy_state_events/3`), with ONE value-free
  warning per upgrade (the contract: exactly ONE `[warning]` entry for the whole upgrade, containing `skipped N` and `reduced M` with the word directly
  next to its number, and no type name, no content, no state key) that names only the number of skipped events. (b) **Never a more open new room (Oracle caveat):** the
  three access types are NOT skipped but copied in a REDUCED form that holds only their spec key, decided by the old value: `m.room.join_rules`
  -> `{"join_rule": v}` when the old `join_rule` is a string of at most 255 bytes (any value, an unknown one stays unknown and refuses every join
  as before), else `{"join_rule": "private"}` (a malformed old event refused every join; `private` does too); `allow` is DROPPED, so a
  `restricted` / `knock_restricted` room admits invitations only (a subset of before). `m.room.history_visibility` -> `{"history_visibility": v}`
  for a string of at most 255 bytes, else `"joined"` (the most restrictive spec value). `m.room.guest_access` -> `{"guest_access": v}` for a string
  of at most 255 bytes, else `"forbidden"`. The reduced events are tiny, so the upgrade never fails for this reason, and the warning of (a) counts
  them as "reduced" separately (count only). Rationale for reducing instead of failing the upgrade: a failing upgrade would block a room admin
  until he rewrites the slot, while the reduced copy is provably no more open than the old room. The operator detection query (AC9 (c)) lists the
  candidates.
- **D9 (cost).** `PUT .../state` and `/send` add NO pass over the content: the size comes from the `Jason.encode!(content)` the routers already do,
  the envelope encode is a few hundred bytes, the backstop reuses `event_json`. createRoom adds one `Jason.encode!` per `initial_state` content, of
  the merged create content and of the merged levels: bounded by the 1 MB body (canonical <= about 1.5 x body, the float growth of D1), run only
  for a request that passed every shape check, and refused before the room. A refused request runs no SQL statement beyond the authentication on any of the
  three routes (createRoom: 5g is before step 6; the rate limiter is ETS). Floats grow the canonical form, so the check is bounded by the body cap times 1.5, never
  unbounded.
- **D10 (what the limit bounds, with numbers; the L-2 / M-2 / L-1 closure).** Every NEW event is at most 65 536 bytes signed, so its content is at
  most 65 536 - envelope (about 300 bytes on a typical server name) bytes. (a) `unsigned.prev_content` (L-2): a delivered state event is at most
  its own event (<= 64 KiB) plus its predecessor's content (<= 64 KiB) plus the three unsigned keys: <= about 130 KB, i.e. the "up to twice its
  content size" of `fl` (e) is now an absolute bound per event. Per joined room and `/sync` response: (S current state slots + 20 timeline events)
  x ~130 KB; S is unbounded (a member at `state_default` can add any number of `m.space.child` / other state keys): that is a COUNT problem, split to
  `fp`. (b) invite_state (M-2 / L-1): per invitation at most 7 room-state events x 64 KiB + 2 member events (fixed shape, < 1 KB) = about 460 KB;
  with the per-invitee cap of 100: about 46 MB built in memory before the budget (was ~500 MB), the `m.room.create` contents alone at most 100 x 64
  KiB = 6.4 MiB (was ~100 MB) and never dropped, the response bounded by the 8 MiB budget (the creates fit inside it). Legacy rows keep the old
  bounds until rewritten (D8). (c) `m.space.child` with huge or many keys, power levels with huge `users` / `events` maps or unknown top-level keys:
  one event each, all under the same 64 KiB rule (PUT state for `m.space.child`, createRoom 5g for the power levels; `PUT .../state/m.room.power_levels`
  stays 403, `eq`).
- **D11 (not in this story).** Depth / NUL on the other routes (`en`, D5); account data and tags keep their own caps (`NEBU_ROOM_ACCOUNT_DATA_MAX_*`,
  unchanged); profile `displayname` / `avatar_url` are not events in Nebu (no member event carries them), so the event limit does not apply: their
  missing length cap is recorded as a note on `en`; kick / ban `reason` (no client route): note on `ex`; canonical-JSON number rules (`fn`); the
  encode round trips (`fo`); the state-slot count (`fp`); a Nebu-side size cap below 64 KiB for specific types (none: the spec's per-type extra limits
  do not exist for the writable types).

- **D12 (user ids are at most 255 bytes at their source, Oracle gate; CONTRACT CHANGED by code review cycle 1, Kassandra #1 MEDIUM: domain separation by length).**
  `Nebu.Matrix.UserId.from_claims/2` (the single identity function, premise table) bounds the result: an id of at most **254 bytes** is returned
  unchanged, byte for byte (no identity change for anyone with a normal claim); every id that `"@" <> localpart <> ":" <> server_name` would make
  **255 bytes or more** is HASHED: the localpart becomes its first `255 - 2 - byte_size(server_name) - 17` bytes, `"-"`, and the first 16 lowercase hex
  characters of SHA-256 of the FULL sanitised localpart, so the hashed id has EXACTLY 255 bytes (deterministic, so login, `OidcPlug`, SSO, account management
  and the Admin agree; two long claims with a common prefix get different ids; grammar-valid, ASCII). The two forms are DISJOINT BY LENGTH (a natural id
  never has 255 bytes, a hashed id always has): no claim a user can choose equals the hashed id of another user's long claim (the original rule "at most
  255 bytes unchanged" let an IdP user who can pick a ~237-character username take over the hashed id of a victim whose full claim he knows). There is NO
  hash-only branch: a server name that leaves fewer than 18 bytes of the localpart (more than 235 bytes) is a configuration error, and `Nebu.Application`
  REFUSES TO BOOT with a message that names the byte size only (`check_server_name_length!/1`, tested). `UserId.valid?/1` gains the 255-byte bound (it guards invite lists,
  power-level `users` keys and the Admin add-member path); `UserId.valid_shape?/1` is the same grammar WITHOUT the bound and is used only by
  `admin_remove_room_member/3`, so an Admin can still remove a legacy id above 255 bytes from a room (Kassandra #3). An account created before this story with an id of 255
  bytes or more gets a NEW id at its next login (its old rows stay: the 07-deployment query Q-uid (`>= 255`, run BEFORE the upgrade, afterwards it also lists
  the legitimate hashed ids) lists such accounts, expected none; their sessions hit the D2 (d) 403 until they sign in again).

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused: ... `fn` onward" and a grep of `docs/stories/oauth-broker/` finds `fn`, `fo`, `fp` only in that id line and in the member-event-prev-content story's text about it, no row: the new ids are `fn`, `fo`, `fp`)

- **`fn` — Canonical JSON number and escape conformance.** `Nebu.Matrix.CanonicalJson` is Jason with sorted keys: floats in client content
  (`1e2`, `0.5`) are accepted, stored and signed in Jason's rendering (`100.0`, `0.5`), integers outside [-(2^53)+1, 2^53-1] are accepted, and
  control characters are escaped with UPPERCASE hex (`\u001F`); the spec's canonical JSON forbids floats and out-of-range integers and uses
  lowercase hex (appendices, Canonical JSON). Byte counts are unaffected except for floats (this story measures Nebu's rendering, D1). A fix
  decides between rejecting such content (`400 M_BAD_JSON`, Synapse rejects floats in room v6+) and normalising; the e2e must show Element never
  sends floats. Source: this story (premise S5). Non-gating.
- **`fo` — Encode / decode round trips on the event paths.** `/send` and PUT state content is `Jason.encode!`d in the router, `Jason.decode`d in
  the core, and encoded to canonical JSON twice per write (`EventId.generate/1` and the signature encode the same bytes); the read side encodes the
  predecessor content to JSON text and decodes it again for `unsigned.prev_content` (Kassandra L-2 of member-event-prev-content, the optional
  item: hand the decoded map to the renderer). Bounded by 64 KiB per event since this story; a CPU / allocation optimisation (pass the decoded map
  and the canonical bytes through; `EventId.generate/1` from `event_json`). Source: this story, ep L-2. Non-gating.
- **`fp` — No bound on the number of state slots per room, nor a byte budget for joined-room state in `/sync`.** Each event is <= 64 KiB since this
  story, but a member at `state_default` (50) can write any number of distinct state keys (`m.space.child/<anything>` up to 255 bytes, other
  allowlisted types with non-empty state keys), and every member's initial `/sync` carries the full current state of each joined room, each state
  event with its `prev_content`: (S + 20) x ~130 KB per room per response, S unbounded (no per-user rate limit on PUT state either). Options: a cap of
  state slots per (room, type), a per-response state byte budget like the invite budget, lazy-loading members (`fg` (a)), a PUT-state rate tier.
  Source: this story (D10 (a)). Non-gating.
- Notes (no new id): `en` (what this story took and left, profile caps), `fi` (g) (the write-time limit exists), `fl` (e) (the bound in numbers),
  `ey` / `ff` (their texts call `ep` pending), `ex` (kick / ban `reason` must pass `EventSize` when routed), `eq` (the power-level route, when
  built, must pass `EventSize`).

## Acceptance Criteria

1. **The accounting (pure unit, `server/test/nebu/matrix/event_size_test.exs`, `async: true`, no DB).** (a) `signed_overhead/0 == 171`, and for
   200 generated events (random string-keyed contents: nested maps with more than 32 keys, lists, 1- to 4-byte UTF-8, `"`, `\`, `/`, C0 controls,
   DEL, U+2028, integers, floats, `true` / `false` / `null`, empty maps; `state_key` `nil`, `""` and long values; two server names) built EXACTLY
   like `emit_state_event_at/6` (real `EventId.generate/1`, a real Ed25519 signature with a test key): `byte_size(CanonicalJson.encode!(stored)) ==
   EventSize.stored_bytes(CanonicalJson.encode!(event_map))`. (b) For the same contents `byte_size(Jason.encode!(c)) ==
   byte_size(CanonicalJson.encode!(c))`. (c) `predicted_bytes(envelope, byte_size(Jason.encode!(c)))` equals the real stored size of (a). (d) The
   test computes its EXPECTED sizes independently (it builds the stored map and encodes it), never through `EventSize`. (e) Limits: a stored size
   of exactly 65 536 is `:ok`, 65 537 `{:error, :event_too_large}`; `type` / `state_key` of 255 bytes `:ok`, 256 too long; counted in BYTES: 85 x
   `"€"` (255 bytes) ok, 86 x `"€"` (258 bytes, 86 code points) too long, 128 x `"é"` (256 bytes, 128 code points) too long, 63 x `"😀"` + `"abc"`
   (255 bytes) ok; a `type` containing `"` counts 1 byte per `"` (raw string bytes, not its JSON form). (f) Escapes: a string of 10 000 x U+0001
   has a canonical size of 60 002 bytes (6 per character + quotes), 10 000 x `"é"` 20 002, 10 000 x `"/"` 10 002; a decoded float `100.0` costs 5
   bytes; pins of today's rendering (`fn`): `-0` decodes to the integer `0` (1 byte), `1.0` stays the float `1.0` (3 bytes), `-0.0` renders as `-0.0` (4 bytes). (g) The generated room id has the byte size of the placeholder (D6) for two server names: `generate_room_id/0` is private, so this is pinned in the HTTP suite through a real createRoom (`byte_size(room_id) == 1 + 16 + 1 + byte_size(server_name)`).
2. **`PUT .../state` (HTTP real DB, `server/test/nebu/matrix/event_size_limit_http_test.exs`, `@moduletag :integration`, through
   `Nebu.Web.Router`, random users and rooms).** The tests size their bodies with an INDEPENDENT helper that builds the stored map (dummy
   44-byte event id, 88-byte signature, the real room id, sender, type, state key and a 13-digit ts) and adjusts a padding string. (a) Boundary:
   `m.space.child` / `!child:<server>` with `{"via": [<server>], "pad": <ASCII>}` sized to exactly 65 536 -> 200; the stored row (read from
   `events`, both JSONB forms handled) re-encoded as D1 is exactly 65 536 bytes; one more byte -> `413 M_TOO_LARGE` with the fixed text, no new
   `events` row, the slot's current event unchanged (`/sync` state still shows the previous content), no broadcast (the test process joins the `:pg` group `room:<id>`
   that every write site broadcasts to: a refused write delivers no `{:new_event, _}` (`refute_receive`), the next accepted write does). (b) Multi-byte boundary: padding of `"€"` + ASCII at exactly 65 536 -> 200 (far fewer code points than
   bytes), +1 byte -> 413. (c) Canonical, not body: a body of more than 65 536 bytes whose padding is written as `é` escapes (6 body bytes, 2
   canonical) and whose canonical size is exactly 65 536 -> 200; a body with 10 KB of insignificant whitespace and a canonical size of 65 536 ->
   200; a body with a duplicate key: first value `"x"`, second 70 000 bytes -> 200 and the stored content is `"x"` (Jason keeps the FIRST value), the reversed order (70 000 bytes first) -> 413; a body below 65 536 bytes whose
   canonical form exceeds it through floats (`[1e2, 1e2, ...]`) -> 413 (comment: pins Nebu's float rendering, `fn`); a content of C0 control
   characters below 65 536 code points whose canonical form exceeds the limit -> 413. (d) `m.room.topic` within the code-point caps (`topic` 1024
   C0 controls, `m.topic` 8 bodies of 4096 C0 controls) -> 413 (the code-point caps do not bound bytes). (e) Keys: a `state_key` of 255 bytes
   (85 x `"€"`) -> 200, 256 bytes -> 413 "State key exceeds 255 bytes"; a `type` of 256 bytes -> 413 "Event type exceeds 255 bytes" (BEFORE the
   allowlist's 403: pinned order). (f) Order: `m.room.encryption` with an oversized body -> 403 (first); a NUL in the path state key plus a 256-byte
   state key -> 400; a 33-deep content that is also oversized -> 400 M_BAD_JSON (depth before size); an oversized body from a NON-member -> 413; an
   oversized body to an UNKNOWN room id -> 413 and NO `rooms` row exists for that id afterwards (the pre-check runs before the lazy start); a
   small body from a non-member -> 403 as before (positive control). (g) No room work on refusal: a 413 of (a), (e) and (f) runs exactly as many `[:nebu, :repo,
   :query]` telemetry events as a `400 M_BAD_JSON` (malformed body) request of the same user on the same route, i.e. the authentication
   statements only (record the number; attach the handler for the request process only); none of them touches `events`, `rooms` or
   `room_members`. (h) Percent-encoded path values are counted DECODED: a `state_key` of 85 x `%E2%82%AC` (255 bytes after decoding, 765 in the
   path) -> 200, 86 x -> 413; the same for a `/send` type (AC3 (b)); the `state_key` `""` is accepted on both forms (`PUT .../state/m.room.topic`
   and `PUT .../state/m.room.topic/`), and the stored row has `state_key = ''`. (i) A lone surrogate escape `"\ud800"` in the content (and in a key)
   is a defined 400 (`M_BAD_JSON`, the route's malformed-body answer) and never a 200 or a 500 (if Jason decodes it into an invalid binary, the
   router adds a `String.valid?` walk next to the NUL scan and answers 400: record which happened). (j) Response shape of EVERY 413 of this story
   (AC2-AC4 and AC7): status 413, `content-type` `application/json` (charset as the other Nebu errors), a body whose keys are exactly `errcode` and
   `error`, and, for a request with an `Origin` header, the same CORS response headers as a 200 of the same route (`access-control-allow-origin`
   present).
3. **`PUT .../send` (same suite).** (a) Boundary with `"state_key": null` accounted: an `m.room.message` sized to exactly 65 536 -> 200 and the
   stored row re-encoded as D1 (with `"state_key": null`) is 65 536 bytes; +1 byte -> 413, no `events` row; the SAME `txn_id` then with a small
   body -> 200 with a NEW event id (no cached id from the refused attempt), and the same `txn_id` again -> the same id (idempotency unchanged). (b)
   `type` of 255 bytes -> 200 (any type is accepted on `/send`), 256 bytes -> 413. (c) An oversized body to an unknown room -> 413 (before the
   404), a small one -> 404 as before. (d) A small `m.room.message`, an `m.reaction` and an `m.room.message` with `m.relates_to` -> 200 (positive
   controls). (e) A 413 runs no statement beyond the authentication (as AC2 (g)).
4. **createRoom (same suite).** For each refusal: `413 M_TOO_LARGE` with the D2 text, and NOTHING exists afterwards: no new `rooms` row whose
   `m.room.create` sender is the creator (count before / after), no `events`, no `room_aliases` row for the requested `room_alias_name`, no
   `room_invitations` rows for the requested invitees, no `room_created` audit row, and no statement beyond the authentication (as AC2 (g);
   the rate-limit charge is ETS; the 5g envelope uses the creator as sender and a placeholder room id of the exact generated length, D6, pinned by
   AC1 (g) and by the boundary tests below, which size their bodies with that placeholder and re-read the STORED rows). (a) `initial_state` entry (`m.room.topic` with a padded `"x.pad"` key, or `m.space.child`) sized to exactly 65 536 as STORED (the test
   reads the created room's row and re-encodes it: 65 536) -> 200; +1 byte -> 413. (b) The entry is the 3rd of 3 and the first two are valid: 413,
   nothing created (no partial room). (c) Entry `type` 256 bytes -> 413 "An initial_state event type exceeds 255 bytes"; `state_key` 256 bytes ->
   413 "... state key ..."; 255 bytes each -> 200. (d) An oversized `m.room.member` entry (a type that is SKIPPED when applied) -> 413. (e)
   `creation_content` making the create event 65 537 -> 413 "creation_content ..."; 65 536 -> 200 and the stored create row is 65 536 (the
   server-added `creator` / `room_version` are counted). (f) `power_level_content_override` with a `users` map of valid ids that makes the levels
   event 65 537 -> 413 "power_level_content_override ..."; an override that fits WITHOUT invitees but exceeds the limit with `preset:
   "trusted_private_chat"` and 3 invitees (their level-100 entries count) -> 413; an override with an unknown top-level key holding 70 KB -> 413.
   (g) Order (first failure wins, D7 of create-room-input-validation extended by 5g): an oversized entry plus `room_version: "9"` -> 400
   M_UNSUPPORTED_ROOM_VERSION (step 3 first); an oversized entry plus a 33-deep `creation_content` -> 400 M_BAD_JSON; an oversized entry plus a
   TAKEN `room_alias_name` -> 413 (5g before 6, no alias read); an oversized entry plus an unknown invitee -> 413 (before 7). (h) Bounded by
   construction: a top-level `topic` of 1024 U+0001 characters and a `name` of 255 U+0001 characters -> 200 (the topic event is about 12.3 KB:
   the D6 bound holds). (i) A createRoom body of 999 000 bytes that is mostly insignificant whitespace around a small valid request -> 200 (the
   body cap and the event limit are different things). (j) The refused createRoom still spent one `create_room` token (rate-limits D2: the charge
   comes first; pin with the bucket level).
5. **Backstops at the write sites (core, real DB, `server/test/nebu/matrix/event_dispatcher/event_size_backstop_test.exs`, `@moduletag
   :integration`; the router pre-checks are bypassed on purpose).** (a) `EventDispatcher.Server.set_room_state/2` with an oversized `content_json`
   raises `Nebu.Matrix.Error` with status `:too_large` and the fixed text; no `events` row; for `m.room.name` the `rooms.name` column is unchanged.
   (b) `EventDispatcher.Server.send_event/2` with an oversized content -> `:too_large`; no `events` row; no `:NebuTxnDedup` entry for the txn.
   (c) `Nebu.Matrix.Room.Server.set_power_levels/3` on a test room with oversized levels -> `{:error, :event_too_large}`; `rooms.power_levels_json`,
   the room's in-memory `power_levels` and its `m.room.power_levels` events unchanged. (d) Admin paths: `Nebu.Matrix.set_space_state/5` with an
   oversized content -> `{:error, "Event exceeds the maximum size of 65536 bytes"}` and no space-edit audit row; `Nebu.Matrix.create_room/2` and `create_space/2` CANNOT carry a client `initial_state` / `creation_content` (their
   content is fixed): the createRoom refusal is pinned at `EventDispatcher.Server.create_room/2` (oversized `initial_state_json` -> `Nebu.Matrix.Error`
   `:too_large`, no room); `EventDispatcher.Server.set_power_levels/2` (no route) maps `{:error, :event_too_large}` to the same `:too_large` error, nothing changes. (e)
   `upgrade_room` of a room holding a LEGACY oversized `m.room.topic` (inserted with `DB.insert_event/1`) and a normal `m.room.name` -> 200; the
   new room has the name, not the topic; exactly ONE warning is logged and its text contains the number 1 and neither the type nor a content
   marker. (e2) Never more open (D8 (b)), one test per row, legacy events inserted with `DB.insert_event/1` as the CURRENT event of the slot:
   oversized `m.room.join_rules` `{"join_rule": "invite", "allow": [<70 KB>]}` -> the new room's rule is `{"join_rule": "invite"}` and a
   non-invited user's `POST /join` is 403; oversized `restricted` with an `allow` room the joiner is a member of -> `{"join_rule": "restricted"}`
   without `allow`, the joiner is refused (403), an invited user can join; oversized malformed (`"join_rule": 42` plus padding) ->
   `{"join_rule": "private"}`, an invited user is refused; oversized `m.room.history_visibility` `"joined"` -> `{"history_visibility": "joined"}`;
   oversized non-string history visibility -> `"joined"`; oversized `m.room.guest_access` `"can_join"` -> `{"guest_access": "can_join"}`, a
   non-string -> `"forbidden"`; a NORMAL `public` join rule is copied unchanged (positive control). The warning counts skipped and reduced events
   separately and holds no type or content. (f) The error message of every 413 contains no client value (assert the absence of a marker string put into the type, state key and
   content).
6. **Error mapping (unit, `server/test/nebu/matrix/http_map_error_test.exs` or the existing mapping suite).** `call_core(fn -> raise
   Nebu.Matrix.Error, status: :too_large, message: "M" end)` -> `{:error, {413, "M_TOO_LARGE", "M"}}`; with an `errcode` set it is ignored (still
   `M_TOO_LARGE`); `Nebu.Matrix.Status.too_large/0` returns `:too_large`; every existing mapping unchanged (the existing mapping tests stay green).
7. **Bodies over the parser cap (`server/test/nebu/web/json_body_too_large_test.exs`).** (a) A body of 1_000_001 bytes to PUT state, `/send`,
   `POST /createRoom` and `POST /rooms/{id}/invite` -> `413`, `content-type: application/json`, body exactly `{"errcode": "M_TOO_LARGE", "error":
   "Request body is too large"}`; nothing written (no `events` / `rooms` rows); also without an `Authorization` header (the plug runs before the
   auth, as the old empty 413 did). (b) Exactly 1_000_000 bytes passes the parser (a whitespace-padded small valid `/send` body -> 200). (c)
   Unchanged: the account-data and room-tag PUTs keep their handler texts ("Account data content too large", "Tag content too large");
   `/oauth2/register` keeps its OAuth error shape; a non-`_matrix` path (pick one JSON route outside `/_matrix`, e.g. `/oauth2/...` that is not
   register / token / revoke / consent) still raises `Plug.Parsers.RequestTooLargeError` under `Plug.Test` (status 413). (d) DELIBERATE re-pins
   (old -> new, each with a one-line comment naming this story): `room_account_data_hardening_test.exs` l.216-223 ("send/{type}/account_data with
   > 1 MB keeps the generic 413", "state event with state_key account_data ...") assert the rendered `413 M_TOO_LARGE` envelope instead of the
   raise (their "never an empty event" intent stays: no `events` row); `assert_generic_413/3` is renamed or kept for the remaining raise case.
8. **Legacy rows and the read side are unchanged (real DB, in the AC2 suite).** (a) A legacy 80 KB `m.room.topic` inserted with
   `DB.insert_event/1`: `/sync` of a member still delivers it in the join state (unchanged); a new small topic through PUT state -> 200 and its
   `unsigned.prev_content` is the legacy content (D8, documented); a second small topic -> its `prev_content` is the first small one (the slot is
   clean). (b) The invite budget suites (`invite_state_budget_test.exs`, the 70 KiB topic case of `membership_write_limits_cycle1_http_test.exs`)
   pass unchanged. (c) DELIBERATE re-pin: `membership_write_limits_cycle1_http_test.exs` l.248-262 ("a 100 KB creation_content ...") creates the
   big room with a SMALL `creation_content` and then inserts a legacy oversized `m.room.create` (100 KB `junk`, `type: "m.space"`) with
   `DB.insert_event/1`, stamped so that the stripped-state read returns it (check which create row `invite_state_events` picks and record it), so
   the reduction above 64 KiB is still exercised; a new assertion in the same describe: the old request through `POST /createRoom` is now `413
   M_TOO_LARGE`.
9. **Docs (`server/test/nebu/matrix/event_size_limit_docs_test.exs` pins facts and unique terms, not sentences).** (a)
   `docs/matrix-api-scope.md`: the rows `POST /createRoom`, `PUT .../send/{eventType}/{txnId}`, `PUT .../state/{eventType}/{stateKey}` (and the
   no-stateKey row by reference) name `413 M_TOO_LARGE`, `65536`, `255 bytes`, "canonical", and label the status code a Nebu decision (Synapse
   parity, the spec names no code; `400 M_TOO_LARGE` named as the table-conformant alternative) AND the size accounting a **Nebu interpretation**
   ("the stored client-format event plus `event_id` and `signatures`; no reserve for PDU keys because Nebu does not federate; a reserve is due if
   federation or an export format is ever added"); one sentence names the 1 MB body answer (`M_TOO_LARGE`, "Request body is too large"). (b)
   `docs/stories/oauth-broker/follow-ups.md`: `ep` rewritten in the CLOSED style ("**CLOSED by story event-size-limit (date): ...**" then
   "Original item: ..." keeping the old text, so the words `65536`, `M_TOO_LARGE`, `initial_state`, `JsonBody`, `power_level_content_override`,
   `invite_state`, `prev_content` and the sources stay), status `closed`; notes "**Note (event-size-limit, date):**" on `en` (taken: the size rule
   on `/send`; left: depth / NUL on `/send`, account data, tags, to-device, profile, the `inspect(reason)` messages, the non-fatal create write for
   other failures; profile `displayname` / `avatar_url` have no byte cap and are not events), `fi` (g) (the write-time limit exists; the budget
   stays for legacy rows), `fl` (e) (the per-event bound in numbers, D10 (a)), `ey` and `ff` (`ep` is closed; the M-2 / L-1 / L-2 numbers of
   D10), `ex` (when kick / ban are routed, their member event with `reason` must pass `EventSize`), `eq` (a power-level route must pass
   `EventSize`); new rows `fn`, `fo`, `fp` (Out of scope); the id line: "`fn`-`fp`: event-size-limit" and "unused: ... `fq` onward". DELIBERATE
   re-pins (old -> new, each with a one-line comment naming this story): the id-line assertions `` `fn` onward `` in
   `create_room_presets_docs_test.exs`, `create_room_invites_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`,
   `sync_membership_partition_docs_test.exs`, `membership_write_limits_docs_test.exs`, `member_prev_content_docs_test.exs` become `` `fq`
   onward `` (the old `fn` onward is refuted in the new docs suite); check that no other suite pins the `ep` row's open status (grep `"ep"` /
   `` `ep` `` in `server/test` and re-pin deliberately if one does). (c) `docs/architecture/07-deployment.md`: a release note "**Event size limits
   (story event-size-limit, follow-up `ep`).**" (what clients can see: the 413s and their texts, the Synapse parity, Element's normal events are
   far below the limit (e2e run B), the 1 MB envelope; existing events are NOT changed or deleted; the read-side budgets stay) and the operator
   query "*Q-size: events above the size limits (candidates)*": read-only, a sequential scan of `events` (run off-peak, with a read-only role),
   an UPPER-BOUND estimate (`content::text` of JSONB adds a space after every `:` and `,`; a double-encoded JSONB string adds escapes; so every
   event above the limit is listed, plus some just below it), checked inside a rolled-back transaction with a fixture row of 70 000 bytes, one
   of 1 000 bytes, one with a 256-byte `state_key` and tiny content and one with a 256-byte `event_type` (all but the 1 000 byte row are listed):

   ```sql
   SELECT e.room_id, e.event_id, e.event_type,
          e.state_key IS NOT NULL AS is_state,
          e.origin_server_ts,
          octet_length(e.content::text) AS content_text_bytes,
          octet_length(e.event_type) AS type_bytes,
          octet_length(coalesce(e.state_key, '')) AS state_key_bytes
   FROM events e
   WHERE octet_length(e.content::text) + octet_length(e.event_type) + octet_length(coalesce(e.state_key, ''))
         + octet_length(e.sender) + octet_length(e.room_id) + 268 > 65536
      OR octet_length(e.event_type) > 255
      OR octet_length(coalesce(e.state_key, '')) > 255
   ORDER BY e.room_id, e.origin_server_ts;
   ```

   (`268` = the fixed canonical envelope without the four string values (97 bytes: the key names and punctuation, the quotes of `room_id`, `sender`, `type`, `state_key` written as `null` (the larger of `null` and `""`), a 13-digit timestamp) + `event_id` / `signatures` (171), D1; escapes inside the identifiers are not counted, a negligible under-count against the much larger `content::text` over-count.) Plus what to do: nothing is
   required; a room admin removes a legacy oversized STATE event from the current state and from `prev_content` by writing that slot TWICE with a
   normal content (Element room settings, or two `PUT .../state`); legacy oversized MESSAGE events stay (no redaction, `fl` (d)); `upgrade_room`
   does not copy legacy oversized state and copies the three access types in their reduced form (D8 (b)); and the query "*Q-uid: accounts whose
   user id has 255 bytes or more*" (`SELECT user_id, octet_length(user_id) FROM users WHERE octet_length(user_id) >= 255 ORDER BY 1;`, expected none;
   such an account gets a new id at its next login, D12; checked in a rolled-back transaction with a fixture row). (d) `CHANGELOG.md` `[Unreleased]` `### Changed`: one **⚠** entry (behaviour
   change: `413 M_TOO_LARGE` for events above 65 536 canonical bytes or with `type` / `state_key` above 255 bytes on PUT state, `/send` and
   createRoom; bodies over 1 MB on `/_matrix/*` now get the `M_TOO_LARGE` envelope instead of an empty 413; user ids derived from IdP claims are
   bounded to 255 bytes (D12); `upgrade_room` copies legacy oversized access state in a reduced form; existing events unchanged, see
   07-deployment Q-size). (e) The comments in `server/lib/nebu/matrix/event_dispatcher/server.ex` (the invite budget, l.4732-4800) that say "until
   follow-up `ep`" / "the 65 536 byte event limit is follow-up `ep`" are updated to "defence in depth for rows written before story
   event-size-limit" (the docs suite pins that `server/lib` no longer contains `until follow-up \`ep\``, `is follow-up \`ep\`` and the third stale phrase `as written until \`ep\`` of the member-event comment, server.ex ~l.4787).
10. **Regression.** `mix compile --warnings-as-errors`; `mix test` (unit) and `mix test --include integration` green on the branch apart from the
    known flaky families; the existing suites `create_room_initial_state_test*`, `create_room_input_validation*`, `create_room_presets*`,
    `create_room_invites*`, `set_room_state_test.exs`, `matrix_client_compat_test.exs`, `membership_write_limits*`, `member_prev_content*`,
    `room_account_data_hardening_test.exs`, `room_tags_test.exs`, `media_upload_test.exs` pass with only the re-pins named in AC7 (d), AC8 (c) and
    AC9 (b) (any other needed change is a finding: stop and report). The suites of `Nebu.Matrix.UserId` (`user_id_test*`, the OidcPlug, login and
    SSO suites) pass unchanged: no existing fixture uses an id above 255 bytes (if one does, it is a finding).
11. **User ids and aliases within 255 bytes (Oracle gate; unit `server/test/nebu/matrix/user_id_length_test.exs`, `async: false` (the configured claim is read through the global `:matrix, :oidc_claim_reader` seam and the `persistent_term` cache), plus HTTP cases in
    the AC2 suite).** (a) `UserId.from_claims/2`: a claim giving exactly 254 bytes -> unchanged (byte for byte); 255 bytes, 256 bytes and a 1 000-character
    claim -> exactly D12's form, `byte_size == 255`, `UserId.valid?/1` true, deterministic (same claims, same id;
    called through the configured claim AND the `sub` fallback); two 1 000-character claims sharing the first 300 characters -> different ids; the hashed id of a long
    claim is never the id of another claim (natural ids <= 254 bytes, hashed ids exactly 255); a
    normal claim (`alice`) -> `@alice:<server>` exactly (regression pin); the bound applies to the SANITISED localpart (`sanitize/1` replaces every non-ASCII
    BYTE by one `_`: 122 x `"é"` is 244 bytes and is hashed, 121 x is 242 and is not; 61 x `"😀"` is 244 bytes, 60 x 240); server names of 218 / 219 / 220 / 235
    bytes give D12's form; `UserId.server_name_leaves_room?/1` is true up to 235 bytes and false from 236 bytes, and `Nebu.Application.check_server_name_length!/1` refuses
    236 bytes and more with a byte-count-only message (no hash-only form exists); the same function is the only identity source (a source pin: no
    `"@" <>` user-id construction from claims elsewhere in `server/lib`). (b) `UserId.valid?/1`: 255-byte id true, 256-byte id false; `valid_shape?/1` true for both, and the Admin removal of a stored 300-byte id works (add is still refused). (c)
    Aliases in BYTES incl. `#` and the domain: `room_alias_name` whose full alias is 255 bytes with a multi-byte localpart (`"é"` x n + ASCII) ->
    200, 256 -> 400 M_INVALID_PARAM (existing rule, re-asserted here next to the event rules); `m.room.canonical_alias` through PUT state with an
    own alias of 255 bytes in `alt_aliases` (multi-byte) -> accepted by the syntax rule (then `M_BAD_ALIAS` / 200 by mapping, as today), 256 ->
    400 M_INVALID_PARAM; a derived alias from the longest name (255 characters: a `name` is capped at 255 code points) stays within 255 bytes. (d) Sender guard (D2 (d)): a session whose user id is
    256 bytes (a fixture session / token for such an id) -> PUT state, `/send` and createRoom answer `403 M_FORBIDDEN` "Your user id exceeds 255
    bytes: sign in again", nothing written; with a 255-byte id -> 200.

## Acceptance Tests

- `server/test/nebu/matrix/event_size_test.exs` (new, pure, `async: true`): AC1 (a)-(g).
- `server/test/nebu/matrix/event_size_limit_http_test.exs` (new, `@moduletag :integration`, real stack through `Nebu.Web.Router`): AC2, AC3, AC4,
  AC8 (a).
- `server/test/nebu/matrix/event_dispatcher/event_size_backstop_test.exs` (new, `@moduletag :integration`, real DB, core calls): AC5.
- `server/test/nebu/web/json_body_too_large_test.exs` (new; the parts that write go through the real DB, `@moduletag :integration` where needed):
  AC7 (a)-(c).
- `server/test/nebu/matrix/user_id_length_test.exs` (new, pure, `async: false`): AC11 (a), (b); AC11 (c), (d) and AC2 (h)-(j) in the AC2 HTTP suite; AC5 (e2) in
  the backstop suite.
- AC6 in the existing `Nebu.Matrix.Http` mapping suite (or a new `http_map_error_test.exs` if none exists: record which).
- `server/test/nebu/matrix/event_size_limit_docs_test.exs` (new): AC9.
- Re-pinned: `room_account_data_hardening_test.exs` (AC7 (d)), `membership_write_limits_cycle1_http_test.exs` (AC8 (c)), the six docs suites
  (AC9 (b)).

The boundary tests are the heart of this story: the expected sizes MUST be computed by the test itself from the stored map (AC1 (d), AC2 head), and
every 200 at the boundary MUST be confirmed on the STORED row (re-encoded from `events`), because a pre-check that is off by the length of the
event id or the `"state_key":null` would pass a test that only compares the code with itself. Use `tick/0` only where the existing helpers need it;
do not insert future-stamped events outside a room the test owns (known flake `fj`).

## E2E verification

`ui: false` (no UI code changes) and no new scenario: Element sends events far below the limit (its largest events in the normal flows are the
createRoom `m.room.create` / `m.room.power_levels` and Space state, a few KB). What Element shows for a 413 on `/send` (a message pasted above 64 KiB
is now refused, as on Synapse) is NOT verified in the bundle by this story: expected "message not sent" handling of matrix-js-sdk; an optional
manual check, not a gate. Two runs of the full `element-web` project on a FRESH, isolated stack built from THIS commit (the e2e-ci script builds the
server image when `NEBU_E2E_PREBUILT` is unset):

0. Preparation: `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000 (stop a stray `nebu-oauth-dev-*` container, never touch the
   shared `nebu` project); `COMPOSE_PROJECT_NAME=nebu-oauth-e2e` for both runs; `down -v --remove-orphans` between the runs (fresh DB each time).
1. **Run A (CI parity, the regression gate):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e scripts/e2e-ci.sh element`. Pass: every scenario of the default
   tag expression green except the rows of `e2e/KNOWN-FAILURES.md` (K9). Log:
   `_bmad-output/nebu/epics/oauth-broker/step-results/event-size-limit/e2e-run-a.log`.
2. **Run B (no 413 in normal use, and the real event sizes):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh element`,
   then (a) `docker compose -p nebu-oauth-e2e logs --no-color server > .../event-size-limit/e2e-run-b-server.log` and count the
   `Nebu.Web.Plugs.RequestLogger` lines with status `413` (record the exact grep and the count; pass: **zero**, on any path); (b) run the Q-size
   query of AC9 (c) against the e2e database (`docker compose -p nebu-oauth-e2e exec -T postgres psql -U nebu -d nebu -f -`): pass: **zero rows**;
   and record `SELECT max(octet_length(content::text)), event_type FROM events GROUP BY event_type ORDER BY 1 DESC LIMIT 5` (the largest real
   Element events, expected a few KB: the evidence that the limit has a wide margin); (c) `docker compose -p nebu-oauth-e2e down -v
   --remove-orphans`. Logs: `e2e-run-b.log`, `e2e-run-b-server.log`, `e2e-run-b-sizes.txt` in the same directory.
3. Update the "Status of the last complete runs" line of `e2e/KNOWN-FAILURES.md` with run A's numbers.

## Tasks

- [x] `Nebu.Matrix.EventSize` (D3) with the moduledoc of D1 (what is measured, why no PDU reserve, why Jason size == canonical size).
- [x] `Nebu.Matrix.Status.too_large/0` + type; `Http.map_error/1` clause (D2 (e)).
- [x] `protected.ex`: PUT state and `/send` pre-checks in the D4 / D5 order; the content is encoded once.
- [x] `EventDispatcher.Server`: step 5g in `validate_create_room_request/1` (and its doc list), backstop in `emit_state_event_at/6`, the inline
      create write, the 413 mapping in `set_room_state/2`, `send_event/2`, `apply_initial_state/4`, createRoom step 3; the upgrade skip warning
      (D8); the stale `ep` comments (AC9 (e)).
- [x] `Room.Server`: backstops in `do_send_event/7` (before insert / ETS / broadcast) and `handle_call({:set_power_levels, ...})` (before the column
      write).
- [x] `JsonBody`: the `/_matrix` 413 envelope (D7).
- [x] Tests (Acceptance Tests) and the re-pins (Change Log, old -> new).
- [x] `UserId.from_claims/2` and `valid?/1` 255-byte bound (D12) + boot error for a too-long server name; the sender guard (D2 (d)); the reduced
      copy of the access types in `upgrade_room` (D8 (b)).
- [x] Docs AC9 (scope doc, follow-ups, 07-deployment with Q-size checked in a rolled-back transaction, CHANGELOG).
- [x] E2E run A (orchestrator, 2026-10-20, fresh isolated stack): 25 passed + the one browser-flake (thread_messages hover) re-run green 3/3; 0 x 413 in the server log, Q-size 0 rows, Q-uid 0 users, largest real event 293 bytes: evidence step-results/event-size-limit/e2e-run.md (run B was not needed: the story's run B repeats A with the rate limits enabled for the 429 check of the previous story).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (no repository /
  service layer: `EventSize` is a pure function module like `CanonicalJson`, no state, no DB), ADR-019 / ADR-021 (plain in-process modules),
  ADR-020 (the Admin wrappers in `Nebu.Matrix` keep calling the core; no new cross-domain call).
- **One accounting, three callers.** The routers, the createRoom step and the write-site backstops all go through `EventSize`; do not re-derive
  171 or the envelope anywhere else. The backstop MUST use the `event_json` that is signed (no second canonical encode); the pre-checks MUST use the
  `Jason.encode!` the routers already do (no new pass over a 1 MB body). `EventId.generate/1` keeps its own encode (that double encode is `fo`).
- **Order matters (first failure wins).** Router: identifiers (NUL 400, then length 413), depth 400, NUL 400, size 413, then the core. Core
  createRoom: 5g after 5f, before 6. Size is checked BEFORE any room lookup: `fetch_room_state/1` lazy-starts a Room and inserts a `rooms` row for
  an unknown id; an oversized request to an unknown id must not reach it (AC2 (f)).
- **Nothing persisted on refusal.** `Room.Server.handle_call({:set_power_levels, ...})` writes `rooms.power_levels_json` BEFORE the event today:
  the size check goes before that write. `do_send_event/7`: before `insert_event`, the ETS txn insert and the broadcast. `set_room_state/2`: the
  `rooms.name` write is after the emit (keep it there). createRoom: 5g is the guarantee; the backstops raise `:too_large` so the existing rescue
  cleans the half-created room (never a 500 for this reason).
- **Bytes, not code points.** `byte_size/1` on the decoded `type` / `state_key` (after the router's `URI.decode_www_form`, the stored value); the
  existing name / topic caps count code points (`too_long?/2`) and stay as they are.
- **Fixed messages, no values.** No type, state key, size number other than the limit, room id or content in a 413 message or log line (No
  Sensitive Data in Logs Law: topic / name / message content never in a log). The upgrade warning carries a count only.
- **Floats.** Do not reject or normalise floats here (`fn`): the AC2 (c) float case pins today's rendering and will be re-pinned by `fn`.
- **Previous story learnings:** real-DB tests for everything stored (the boundary is confirmed on the stored row); docs suites pin texts of
  earlier stories, so rewrite `ep` in the CLOSED style that keeps the pinned words; re-pins are deliberate and listed old -> new in the Change Log;
  the e2e helpers and Element must not hit the new 413 (run B counts it).

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` (`#size-limits`, the three endpoints' response tables, the
  common errcode `M_TOO_LARGE`, the content repository 413), `appendices/index.html` (`#canonical-json`, the identifier length limits),
  `rooms/v10/index.html` (Persistent Data Unit).
- Code: `server/lib/nebu/web/plugs/json_body.ex`; `server/lib/nebu/web/router/protected.ex` l.1245-1356, l.1462-1490, l.2385-2391,
  l.3010-3057; `server/lib/nebu/matrix/event_dispatcher/server.ex` l.160-221, l.224-331, l.341-371, l.427, l.765-865, l.1244-1312, l.1389-1403,
  l.3719-3790, l.4732-4830, l.7405-7425, l.7444-7593, l.7600-7680; `server/lib/nebu/matrix/room/server.ex` l.414-450, l.666-830;
  `server/lib/nebu/matrix/canonical_json.ex`; `server/lib/nebu/matrix/event_id.ex`; `server/lib/nebu/matrix/http.ex` l.48-118;
  `server/lib/nebu/matrix/status.ex`; `server/lib/nebu/matrix/error.ex`; `deps/jason/lib/encode.ex` l.284-300; `deps/bandit/lib/bandit/pipeline.ex`
  l.232-245, `deps/bandit/lib/bandit/http1/socket.ex` l.601-613.
- Reviews: `security-reports/rate-limits-join-invite-create-room-security-review-2026-10-19.md` (M-2, delta gate L-1); the `ep` note of
  member-event-prev-content review cycle 1 (L-2; no report file exists); Oracle `step-results/create-room-input-validation/oracle-context.md`
  (size limits line, the INFO that created `ep`).
- Stories: `create-room-input-validation.md` (D5, D7 order), `create-room-presets-power-levels-topic.md` (override rules, topic caps),
  `rate-limits-join-invite-create-room.md` (charge first, invite budget, e2e run B pattern), `member-event-prev-content.md` (format, prev_content).
- Follow-ups: `ep`, `en`, `fi`, `fl`, `fg`, `fk`, `ey`, `ff`, `ex`, `eq` in `docs/stories/oauth-broker/follow-ups.md`.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev step, bmad-dev-story).

### Debug Log

- Starting point: the throwaway reference implementation of the ATDD step (`scratchpad/atdd/ref`), reviewed part by part and rewritten: the reference had deleted
  comments, reindented nothing, put a bare `if` around `do_send_event/7`, repeated the 413 texts as literals and used no shared envelope helper.
- `handle_call/3` clauses of `Room.Server` must stay grouped (a helper between them is a `--warnings-as-errors` failure): `apply_power_levels/4` lives next to
  `emit_power_levels_event/3`.
- Elixir 1.20: `mix compile --force --warnings-as-errors` and the no-DB `mix test --warnings-as-errors` green on `elixir:1.20-alpine` with
  `MIX_BUILD_PATH=/tmp/nebu_build` (5999 passed, 7 skipped).

### Completion Notes List

- `Nebu.Matrix.EventSize` (pure): `max_event_bytes/0`, `max_key_bytes/0`, `signed_overhead/0` (171, computed from the constituent strings), `stored_bytes/1`,
  `predicted_bytes/2`, `check/2` (size only), `check_stored/1` (size of the signed canonical bytes a write site holds), `check_keys/3`, plus two helpers the story did
  not name: `envelope/5` (the one place the five-key envelope is built, used by the router pre-checks, step 5g, the power-level check and the upgrade) and `message/1`
  (the fixed client-facing texts: no client value, no number other than the limit).
- `Status.too_large/0` + `Http.map_error/1` clause (413 `M_TOO_LARGE`, errcode ignored, default text = the event limit).
- Router (`protected.ex`): PUT state in the D4 order (encryption 403, malformed 400, NUL in path 400, `type` / `state_key` 413 (or sender 403), depth 400, NUL 400, size 413,
  then the core), `/send` (malformed 400, key check, size, core), createRoom (sender 403 first inside the handler; the rate-limit charge stays first). The content is encoded once.
- Backstops: `emit_state_event_at/6` (`check_stored/1` on the `event_json` that is signed; `{:error, :event_too_large}` before signing further, insert and broadcast),
  `Room.Server.do_send_event/7` (before insert, txn-dedup entry and broadcast; the signing / persisting tail moved to `sign_and_persist_event/6`),
  `Room.Server.handle_call({:set_power_levels, ...})` (before the column write; `apply_power_levels/4` is the unchanged tail), the inline `m.room.create` write and
  step 3 of createRoom (fatal for this reason only: they raise `:too_large`, the existing rescue deletes the half-created room), `apply_initial_state/4`.
  `EventDispatcher.Server` maps `{:error, :event_too_large}` to `:too_large` in `set_room_state/2`, `send_event/2`, `set_power_levels/2`.
- Step 5g in `validate_create_room_request/1` (and its doc list): create, power levels (invitees of a `trusted_private_chat` included), every `initial_state`
  entry (also skipped types). Choice recorded (D6): a PLACEHOLDER room id, not a pre-generated id; `generate_room_id/0` and the placeholder now share ONE function
  (`room_id_with/1`), so they cannot drift; the HTTP suite pins the length through a real createRoom.
- `JsonBody`: `/_matrix/*` bodies above the 1 MB cap answer the Matrix envelope and halt; the opaque-content PUTs, `/oauth2/register` and non-`_matrix` paths are unchanged.
- D8: `copy_state_events/3` plans every copy (`:copy` / `:reduce` / `:skip`), ONE warning with the counts "skipped N, reduced M" (no type, key, content or room id), the
  three access types copied reduced (`join_rule` / `history_visibility` / `guest_access` only; fallback `private` / `joined` / `forbidden`; `allow` dropped).
- D12 (as changed in review cycle 1, see the Change Log): `UserId.from_claims/2` passes ids of at most 254 bytes through and hashes every id of 255 bytes or more to EXACTLY 255
  bytes (truncated prefix + `-` + 16 hex of the SHA-256 of the full sanitised localpart); no hash-only branch; `valid?/1` bound, `valid_shape?/1` for the Admin removal; a
  server name above 235 bytes makes `Nebu.Application.check_server_name_length!/1` raise (the node does not boot; byte count only; now tested).
- The stale `ep` comments of `server/lib` rewritten (three phrases, "defence in depth for rows written before story event-size-limit").
- Docs: scope doc (three rows + the no-stateKey row + the 1 MB sentence, with the Nebu decision / Nebu interpretation labels), follow-ups (`ep` CLOSED keeping the old text and the
  keep-words "NEXT story" / `power_level_content_override`, notes on `en` / `fi` / `fl` / `ey` / `ff` / `ex` / `eq`, new rows `fn` / `fo` / `fp`, id line `fq` onward),
  07-deployment (release note, Q-size, Q-uid; the phrases "optional stripped state is bounded" and "`m.room.create` above 64 KiB is reduced" are the existing ones),
  CHANGELOG `[Unreleased]` `### Changed`.
- Q-size / Q-uid verification: the docs suite `event_size_limit_docs_test.exs` RUNS both queries from `07-deployment.md` inside rolled-back transactions on the real
  database (Q-size fixtures: 70 000 bytes, 1 000 bytes, 256-byte `state_key`, 256-byte `event_type`: all but the 1 000-byte row listed; Q-uid fixtures: 256 and 255 bytes listed,
  254 bytes not), and asserts the rollback.
- Deviations: none from the decisions. Two additions beyond the named API of D3 (`envelope/5`, `message/1`, `check_stored/1`) and the two config-check helpers of `UserId`
  (`server_name_leaves_room?/1`, `server_name_too_long_for_any_id?/1`); the e2e runs A and B were not run by this step (the orchestrator may run them).
- Tests: staged ATDD suites green (event_size_test, user_id_length_test, http_map_error_test, json_body_too_large_test, event_size_limit_http_test,
  event_size_backstop_test, event_size_limit_docs_test) plus the re-pinned suites and the six docs suites.

### File List

- `server/lib/nebu/matrix/event_size.ex` (new)
- `server/lib/nebu/matrix/status.ex`, `server/lib/nebu/matrix/http.ex`
- `server/lib/nebu/matrix/user_id.ex`, `server/lib/nebu/application.ex`
- `server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/matrix/room/server.ex`
- `server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/web/plugs/json_body.ex`
- `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/stories/oauth-broker/follow-ups.md`, `CHANGELOG.md`
- `docs/stories/oauth-broker/event-size-limit.md` (this file)
- Tests (staged by the ATDD step, not changed by the dev step): `server/test/nebu/matrix/{event_size_test,user_id_length_test,http_map_error_test,event_size_limit_http_test,event_size_limit_docs_test}.exs`,
  `server/test/nebu/matrix/event_dispatcher/{event_size_backstop_test,create_room_input_validation_test}.exs` + `create_room_test_support.exs`,
  `server/test/nebu/web/json_body_too_large_test.exs`, and the re-pinned suites named in the Change Log.

### Change Log

- 2026-10-19: story created (create-story, premises verified at HEAD `50145470`).
- 2026-10-19: Oracle gate amendments (no WRONG verdicts on the core decisions; `step-results/event-size-limit/oracle-context.md`): the size
  accounting is labelled a Nebu interpretation in the scope-doc AC (AC9 (a)); D2 (c) records `400 M_TOO_LARGE` as the table-conformant
  alternative and why 413 was chosen; premise check of user ids (NOT bounded today: D2 (d) corrected, new D12 + sender guard, AC11 (a), (b), (d),
  07-deployment Q-uid) and of aliases (bounded in bytes incl. `#` and domain: AC11 (c) boundary tests); D8 (b): the upgrade copies
  `m.room.join_rules` / `history_visibility` / `guest_access` in a reduced, never more open form (AC5 (e2)); missing tests added: decoded
  percent-encoded 255 / 256 and `state_key ""` (AC2 (h)), lone surrogate (AC2 (i)), `-0` / `1.0` / `-0.0` pins (AC1 (f)), 413 body, content
  type and CORS headers on every 413 (AC2 (j)). Follow-up ids unchanged (`fn`-`fp`).
- 2026-10-19: test review of the ATDD step (`step-results/event-size-limit/test-review-findings.md`): 0 MAJOR, 13 MINOR applied (hash-only D12 branch and multi-byte
  claims tests, `canonical_alias` `alias` and `initial_state` boundaries, key checks before depth / the non-member 403, fresh-alias no-row assertion, the core
  `set_power_levels/2` test, third and fourth Q-size fixtures, `binary_slice` in the docs tests, the CORS loop of D7, one shared legacy-row helper, the visible
  keep-words of `ep`, the warning contract) and ten story amendments (duplicate keys: Jason keeps the first value; room id length via createRoom; `:pg` instead of a
  long poll; the Admin createRoom wrappers cannot carry client content; the 255-character name; `async: false` of the user id suite; the third stale phrase; D3 / D4
  return shapes and string keys; the warning contract; the 5g envelope as an AC). The D12 boot error stays UNTESTED (no seam).
- 2026-10-19: dev step (bmad-dev-story): implementation of D1-D12 and docs; status review. See the Dev Agent Record.
- 2026-10-19: code review cycle 1 (`step-results/event-size-limit/code-review-findings.md`): 0 MAJOR, 5 MINOR; Kassandra CLEAN (1 MEDIUM, 2 LOW, 4 INFO). **DELIBERATE CONTRACT CHANGE of D12 (Kassandra #1, MEDIUM; a decided
  change, not a weakening of tests):** natural user ids pass through up to 254 bytes (was 255), every id of 255 bytes or more is hashed to EXACTLY 255 bytes, so the two forms are disjoint by length; the hash-only
  branch is removed; a server name above 235 bytes refuses to boot (was: one boot error, untested); Q-uid is `>= 255` (was `> 255`). Re-pinned old -> new: `user_id_length_test.exs` ("exactly 255 bytes unchanged" ->
  254 unchanged and 255 hashed; the 236 / 237-byte hash-only tests -> the 235-byte hashed form, the `server_name_leaves_room?/1` boundary at 235 / 236 and the boot refusal in `application_test.exs`),
  `event_size_limit_docs_test.exs` (Q-uid title, `>= 255`, fixtures 254 / 255 / 256). Also: invalid UTF-8 path values are `400 M_BAD_JSON` on PUT state and `/send` (M1, new tests); the JsonBody 413 sends `Connection: close`
  (Kassandra #2, new test; the opaque-content PUT flag routes keep the handler answer and are unchanged); `UserId.valid_shape?/1` for `admin_remove_room_member/3` (Kassandra #3, new test; the controllers' remove paths
  validate nothing themselves); the `ex` row carries the kick / ban gate item (Kassandra #4); `emit_state_event_at/6` also refuses a `type` / `state_key` above 255 bytes and the upgrade skips (never reduces) such a slot (Kassandra #5);
  the size texts have ONE source (`EventSize.message/1`, I3); the `@min_prefix_bytes` comment is corrected (I2); the scope rows are separated (M4); 07-deployment states the length-disjoint namespaces (M5).
