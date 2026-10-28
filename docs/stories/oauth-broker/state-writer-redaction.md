---
story_id: state-writer-redaction
title: "Redaction (PUT /rooms/{roomId}/redact/{eventId}/{txnId} and m.room.redaction on /send) decided and written by ONE room-process redaction writer that evaluates the redact level, served pruned on every read path with unsigned.redacted_because (stored content kept: compliance), and the generic PUT state decided AND written in the room process (Room.Server.write_state/5, stamped max(now, latest slot ts + 1), one transaction, no lazy rooms row), the upgrade tombstone through the same writer at the tombstone level: closes fw, fv, fz, fx and the PUT-state part of eu"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-20
branch: feature/migrate-to-oauth2
---

# Story: redaction with the `redact` level, and the generic state writer in the room process (follow-ups `fw`, `fv`, `fz`, `fx`)

As a room member using Element (message options > "Remove", the moderator's "Remove recent messages"), I want "Remove" to work for my own
messages and, as a moderator, for other users' messages, and I want nobody below the room's `redact` level to be able to hide other users'
messages.
As a Nebu operator, I want every redaction and every state change to be decided and written inside the room process (serialised with
power-level changes, kicks and bans: a demoted moderator's next redaction or state change is refused), every redaction to be pruned
consistently on every client read path, and the original content to stay in the database (Compliance Mode: server-readable content,
eDiscovery), so that "Remove" hides a message from every client without destroying the compliance record.

Follows `power-levels-enforcement` (the one-writer pattern `Room.Server.change_power_levels/4` + `Room.DB.apply_power_levels_change/3`,
the `send_event` order membership -> level -> idempotency -> archived, `events[type]` enforcement, S2 / AC17 (n): the pinned risk of an
unchecked `/send` redaction, follow-ups `fv`, `fw`, `fx`, `fz`) and `moderation-routes-atomic-ban` (`Room.Server.moderate/6`, the
`moderation` tier, `Http.map_error/1` opt-ins, the audit residual `fs`). Closes `fw` (security-relevant, raised priority), `fv`, `fz`, `fx`
(with a labelled floor) and the PUT-state part of `eu`. **One story, no split** (see "Sizing").

## Premises verified (2026-10-20, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `b651fee8`, read-only)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise (from the request) | Verified text | Verdict |
|---|---|---|---|
| S1 | `PUT /redact` exists and gates by `events` + `redact` | `client-server-api` "Redactions", Client behaviour: `PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}`, body `{reason?}`, `200 {event_id}`, "This cannot be undone. Any user with a power level greater than or equal to the `m.room.redaction` event power level may send redactions for their own events in the room. If the user's power level is also greater than or equal to the `redact` power level of the room, the user may redact events sent by other users. Server administrators may redact events sent by users on their server." "Rate-limited: No". `txnId`: "it will be used by the server to ensure idempotency of requests". `m.room.power_levels` section: "For redactions of a user's own events, the required power level is determined by the `m.room.redaction` event power level, as per `events` and `events_default`. The power level required to redact an event sent by another user is additionally governed by `redact`" (default 50). | CORRECT. D2, D3. Server-admin redaction is not offered (follow-up `gc`). "Rate-limited: No" is honoured (D7). |
| S2 | v10 auth rules for `m.room.redaction` | `rooms/v10` "Authorization rules": "`m.room.redaction` events are subject to auth rules in the same way as any other event ... In particular, the `redact` level is not considered by the auth rules. The ability to send a redaction event does not mean that the redaction itself should be performed." "Handling redactions": the server applies a redaction if "The power level of the redaction event's sender is greater than or equal to the `redact` level" OR "The domain of the redaction event's sender matches that of the original event's sender"; "If the server would apply a redaction, the redaction event is also sent to clients." | CORRECT, with a precision the request did not name: the "same domain" condition is the FEDERATION rule (a receiving server trusts the origin server, which checked the client rule). On a single non-federated server every local sender has the same domain, so that condition would apply every redaction that passed the auth rules. Nebu is the ORIGIN server of every event: it enforces the client-server rule of S1 (own event: `events` level; another sender's event: additionally `redact`) at CREATION and never writes a redaction it would not apply (D2). Oracle Q1. |
| S3 | v10 redaction algorithm | `rooms/v10` "Redactions": strip every top-level key except `event_id`, `type`, `room_id`, `sender`, `state_key`, `content`, `hashes`, `signatures`, `depth`, `prev_events`, `prev_state`, `auth_events`, `origin`, `origin_server_ts`, `membership`; content keys kept only for `m.room.member` (`membership`, `join_authorised_via_users_server`), `m.room.create` (`creator`), `m.room.join_rules` (`join_rule`, `allow`), `m.room.power_levels` (`ban`, `events`, `events_default`, `kick`, `redact`, `state_default`, `users`, `users_default`; NOT `invite` / `notifications` in v10), `m.room.history_visibility` (`history_visibility`). | CORRECT. Every type that keeps content keys is a STATE event; Nebu redacts message events only (D4), so a redacted event is always served with `content: {}`. `top-level redacts` is NOT in the kept list (a redacted redaction would lose it): one reason why a redaction event cannot be redacted here (D4, `ga`). |
| S4 | `unsigned.redacted_because`; reads show redacted events | CS "Redactions": "This stripped down event is thereafter returned anytime a client or remote server requests it. Redacting an event cannot be undone, allowing server owners to delete the offending content from the databases. Servers should include a copy of the `m.room.redaction` event under `unsigned` as `redacted_because` when serving the redacted event to clients." `ClientEvent.unsigned.redacted_because`: "The event that redacted this event, if any." "Redacted events can still affect the state of the room ... a redacted topic ... causes the topic to be removed from the room." | CORRECT. "allowing server owners to delete" is a permission, not a duty: Nebu keeps the stored content and prunes on EVERY client read path (D5, D6; Oracle Q2). State redaction is out (D4). |
| S5 | v1.18: `m.room.redaction` on `/send`, `content.redacts` moved for rooms below v11 | `PUT /send/{eventType}/{txnId}`: "Changed in v1.18: Homeservers must support sending m.room.redaction events with this endpoint for all room versions ... In rooms with a version older than 11 they MUST move the `redacts` property inside the content to the top level of the event." `rooms/v11` "Moving the redacts property": "For backwards-compatibility with older clients, servers should add a `redacts` property to the top level of m.room.redaction events when serving such events over the Client-Server API. For improved compatibility with newer clients, servers should add a `redacts` property to the content of m.room.redaction events in older room versions when serving such events over the Client-Server API." | CORRECT. Nebu creates only room version `"10"` (`server/lib/nebu/matrix/room_versions.ex` l.13-14) and advertises v1.1-v1.15 (`http_public.ex` l.315), so the v1.18 MUST does not bind yet; it is implemented anyway because the unchecked `/send` path is the security gap (D3). Stored as the v10 shape (top-level `redacts`), served with BOTH (D5). |
| S6 | relations / edits of redacted events | CS "Forming relationships": "when a child event is redacted then the relationship is broken. Therefore, the server needs to de-aggregate or disassociate the event once the relationship is lost." "Redactions of edited events": redacting the original returns empty content; "the subsequent edits are not actually redacted themselves". | CORRECT. D6: a redacted child is excluded from `/relations` and from the thread count; edits of a redacted original stay served (spec). |
| S7 | PUT state: generic auth rules | `rooms/v10` generic rules (verified in story power-levels-enforcement S4): sender joined; level >= `events[type]` else `state_default`; a `state_key` starting with `@` must equal the sender. createRoom: "The server MUST apply the normal state resolution rules when creating the new room, including checking power levels for each event." | CORRECT. D8 (the writer), D10 (the `@` rule on `initial_state`). |
| S8 | Upgrade permission (`fx`) | `#room-upgrades` server behaviour, first step: "Checks that the user has permission to send `m.room.tombstone` events in the room." | CORRECT. D11: the tombstone level, decided in the old room's process at the tombstone write, with a labelled floor of 100. |

### What Nebu does today (code)

| Question | Verified state |
|---|---|
| Redaction | **No route and no redaction code** in `server/lib` (grep `redact`: only `log_store/route_normalizer.ex` l.40 / l.86 knows the path, `power_level.ex` l.18 says "Not evaluated anywhere ... `redact` (no redaction route, follow-up `fw`)", l.33 the default 50). `PowerLevels.required_level/2` (l.114-126) has no `:redact` action; `can?/3` (l.132). |
| `/send` of `m.room.redaction` | `protected.ex` l.1539-1591: no rate tier, `is_state_event: false` (l.1582), any `event_type`; `EventDispatcher.Server.send_event/2` (server.ex l.160-239): membership on a `get_state` snapshot (l.190-197), then `Room.Server.send_event/6` (room/server.ex l.621-645: membership, `{:message, type}` level, then `send_authorised_event/7` l.1181-1206: the ETS idempotency key `{room_id, user_id, txn_id}` l.1183 / l.1281, the archived check l.1192, `do_send_event/7` l.1211-1266, the insert l.1276, broadcast with `:pg.get_local_members/1` l.1285). The content is stored AS SENT (no check of `content.redacts`, no redaction applied) and delivered (pinned by `power_levels_http_test.exs` AC17 (n), l.1448-1470, and l.628-644). |
| What Element 1.12.15 does (VERIFIED in the source maps of an Element Web 1.12.15 bundle: `html/version` = `1.12.15`, `bundles/3c9ddd76fa48d1221fef/*.js.map`, extracted earlier into this session's scratchpad; NOT re-extracted from the `nebu-oauth-element` image in this step, no docker) | matrix-js-sdk `src/client.ts`: `redactEvent` (l.3144-3185) builds `{type: "m.room.redaction", content: {reason}, redacts: eventId}` (`with_rel_types` only when passed); `sendEventHttpRequest` (l.3092-3097) sends every redaction with a top-level `redacts` to **`PUT /rooms/{roomId}/redact/{eventId}/{txnId}`** with the wire content (`{"reason": ..}` or `{}`). `src/models/room.ts` l.2630-2645 applies a RECEIVED redaction only through the TOP-LEVEL `event.redacts` (`findEventById` -> `applyEventAsRedaction` -> `makeRedacted`: content stripped, `unsigned.redacted_because` set); no reader of `content.redacts` exists in `event.ts`, `room.ts`, `event-mapper.ts`, `sync.ts`. **So Element 1.12.15 does NOT apply today's unchecked `/send` redaction** (only `content.redacts`, no top-level key): the "UNVERIFIABLE" of power-levels-enforcement S2 is resolved for Element (the risk stays for clients that read `content.redacts`, e.g. v11-aware clients) — and Nebu MUST serve a top-level `redacts` for Element to apply a redaction live (D5). `room-state.ts` `maySendRedactionForEvent`: own event -> `maySendEvent("m.room.redaction")`; another sender's -> plus `redact` (default 50). Element's `MessageContextMenu.tsx` l.183-186 offers "Remove" for every sent event incl. STATE events, except `m.room.server_acl` / `m.room.encryption`; `ConfirmRedactDialog.tsx` l.63-75 passes an optional reason and no `with_rel_types`. `BulkRedactDialog.tsx` l.86-97 ("Remove recent messages") fires ALL redactions concurrently (`Promise.all`) and swallows each error; Element's `createMatrixClient.ts` configures no `MatrixScheduler`, so a `429` is never retried automatically. |
| The PUT state path | `protected.ex` l.2488-2493 -> `do_set_room_state/4` (l.3116-3124: the `moderation` charge only for `m.room.power_levels`) -> `set_room_state_request/4` (l.3126-3200: E2EE 403, JSON, NUL, UTF-8, key sizes, depth, NUL content, the envelope size) -> `EventDispatcher.Server.set_room_state/2` (server.ex l.3961-4059): allowlist `@writable_state_types` (l.3946-3956; a refused type raises `permission_denied` WITHOUT errcode, l.3970-3974), `fetch_room_state/1` (l.3984; l.4219-4243 lazily STARTS the room process on `:noproc`: for an unknown room id `do_init/1` inserts a `rooms` row before the membership check answers 403: **`fz`**), membership (l.3988-3992, errcode-less), `{:state, type}` level (l.3996-4001) and the `@` rule (l.4005-4010) on that SNAPSHOT, the content rules (l.4016-4029: canonical alias, name, topic, `m.space.parent` membership of the parent space), then `emit_state_event/5` (l.4033) -> `emit_state_event_at/6` (l.8166-8202) **signs and inserts in the CALLER** (stamp `max(now, not_before)` with `not_before` 0: no read of the slot's latest event; no archived check; broadcast with `:pg.get_local_members/1` l.8195), then the NON-FATAL `rooms.name` update (l.4038-4045, for ANY state key of `m.room.name`), a 500 with `inspect(reason)` (l.4054-4057, `en`). **`fv`**: a PUT decided on the snapshot just before a demotion / kick commits after it. |
| The power-level branch (the pattern to reuse) | `set_power_levels_state/1` (l.4078-4103): empty state key, `ensure_room_without_lazy_create!/1` (l.4115-4134: unknown room -> `403 M_FORBIDDEN` "You are not a member of this room", no row, no process; a known stopped room is started), `Room.Server.change_power_levels/4` (room/server.ex l.597-610, decision l.1064-1087, stamp l.1126-1146 `max(now, not_before, latest + 1)`, ONE transaction l.1151-1171 via `Room.DB.apply_power_levels_change/3` (db.ex l.438-457: `set_lock_timeout/0`, `lock_active_room_for_update/1` = `FOR NO KEY UPDATE`, archived -> `:room_archived`), broadcast `:pg.get_members/1` l.1002), refusals with explicit errcodes (l.4137-4166), audit best effort (l.4182-4202). |
| Other callers of `emit_state_event_at/6` | createRoom (a brand-new room nobody else can reach yet): preset events l.602, name l.619, topic l.631, derived alias l.791, explicit alias l.1610, `initial_state` l.8082; upgrade: the TOMBSTONE in the OLD room l.7460 (`emit_state_event/5`, after a snapshot check), `m.room.create` of the NEW room l.7500, the state copy into the NEW room l.8298-8299. The Admin Space form reaches `set_room_state/2` through `Nebu.Matrix.set_space_state/5` (`server/lib/nebu/matrix.ex` l.516-540). |
| Upgrade permission (`fx`) | server.ex l.7414-7422: `PowerLevels.get_user_level(old_state.power_levels, requester) < 100` -> `permission_denied` WITHOUT errcode, text "insufficient power level for room upgrade" (the mapper answers the misleading fixed "You are not a member of this room"); decided on a snapshot; the tombstone is written in the caller afterwards (l.7459-7466), then `freeze_old_room!/1` (l.7475) and the post-freeze level re-check of story power-levels-enforcement (Kassandra L-1). |
| Read paths that serve event content | `event_maps_to_core_events/1` (server.ex l.3362-3382; ONE batched predecessor lookup per call) serves `/messages` (l.3223), `/event` (l.8436), `/relations` (l.8398) and the `/sync` join timelines (l.4858, l.4888, l.5676); `/initialSync` uses `get_messages/2`. BYPASSES (`event_map_to_core_event/1` directly): the `/sync` LEAVE window `build_leave_room/3` (l.5347; predecessors attached by `attach_leave_predecessors/1`) and the thread roots of `thread_root_updates/3` (l.8516). `attach_thread_aggregations/3` (l.8460-8495) computes `unsigned_relations`, but NOTHING renders it (no reader in `server/lib/nebu`: grep). Search: `Nebu.Matrix.Search.DB` (`search/db.ex` l.13-68) returns `e.content` of every matching `m.room.message`. Rendering: `Nebu.Matrix.Http.timeline_event_json/2` (http.ex l.200-216), `message_event/1` (l.320-336), `put_predecessor_keys/2` (l.344-354). `Core.Event` (`server/lib/pb/core.pb.ex` l.1-21) has no `redacts` / `redacted_because` field. Relations: `Room.DB.fetch_events_by_relation/5` (db.ex l.1067), `count_thread_children/2` (l.1139-1165). |
| Storage | `events` (migration 000001 l.211-223): `event_id`, `room_id`, `sender`, `event_type`, `content`, `origin_server_ts`, `signatures`, `state_key`, `search_vector`; **no `redacts` column**; `Room.DB.insert_event/1` (db.ex l.488-537) writes the 8 columns. The only `UPDATE events` / `DELETE FROM events` in `server/lib` is `delete_room` (l.80, orphan cleanup). Migrations run inside ONE transaction each (`Nebu.Release.migrate/0`, see the 000031 / 000050 headers: no `CONCURRENTLY`). Last migration: 000050. |
| Compliance expectations | ADR-023: Compliance Mode "must guarantee message content is server-readable (auditing, eDiscovery, DLP)". `docs/compliance/gdpr-deletion-runbook.md` l.101-106: "The Matrix event timeline is an immutable append-only log - event content is preserved as sent." ADR-030 l.244-248: "Redaction stays decoupled from legal hold (Oracle-confirmed) ... `m.room.redaction` ... is therefore offered — if at all — as a separate, operator-initiated, per-room action". `NebuTxnDedup` is node-local, per user (not per device), unpruned (follow-up `bd`). |
| `Http.map_error/1` | `failed_precondition` -> `400 M_BAD_STATE` (http.ex l.102; the `/send` archived answer "M_ROOM_ARCHIVED: room is archived"); an `unavailable` with an errcode passes it through (l.105-107). |

### Sizing

One story, large (about 850 lines in `server/lib`, comparable to power-levels-enforcement): `Nebu.Matrix.Redaction` (pure: prune, render
helpers: about 80), `Room.Server` (`redact/5`, `write_state/5`: about 250), `Room.DB` (`apply_redaction/2`, `apply_state_change/3`,
`latest_state_identity/3`, `redactions_for/1`, `insert_event/1` + `redacts`, relation / search exclusions: about 150), `EventDispatcher.Server`
(the redaction handler, the `/send` branch, `set_room_state/2` on the writer, the prune in the read paths, the upgrade tombstone: about 250),
`protected.ex` (the route, about 60), `Http` (about 40), `PowerLevels` (`:redact`), `AuditWriter` (one action), migration 000051 (one
column, one partial index). Redaction is NOT split out: it is the security gap with the highest priority (`fw`), and the state writer is
its natural sibling (same pattern, same file regions). If the ATDD reference exceeds about 1000 lines in `server/lib`, the dev stops and
reports (the orchestrator may then move D8-D11 into a story 2 under `fv`), never a half-built writer.

## Decisions

- **D1 (one redaction writer: the room process).** Every `m.room.redaction` that Nebu writes is decided and written by ONE `handle_call`
  of `Nebu.Matrix.Room.Server`: `redact(room_id, sender, target_event_id, content, txn_key)` (`txn_key` the idempotency key of D7). Both
  entry points use it: `PUT /redact/{eventId}/{txnId}` and `PUT /send/m.room.redaction/{txnId}` (D3). `Room.Server.send_event/6` refuses
  the type `m.room.redaction` (`{:error, :forbidden}`, defence in depth: no second writer; pinned by a source test). Because send, kick /
  ban / unban, the invite event, power-level changes, state writes (D8) and redactions run in the same process, each redaction is decided
  on the levels and the member set of every change committed before it.
- **D2 (decision order, first failure wins; the CS rule of S1 at creation).** (1) the sender is in `state.members` else
  `:sender_not_joined` (403 "You are not a member of this room"); (2) the sender reaches `required_level({:message, "m.room.redaction"})`
  (`events["m.room.redaction"]` else `events_default`) else `:forbidden` (403 "You do not have a high enough power level to send this
  event", the `/send` text); (3) idempotency (D7): a cached event id for `txn_key` is returned (`200`, nothing written); (4) the target:
  ONE read `fetch_event(target, room_id)` through the db module inside the process: absent in THIS room -> `:target_not_found` (`404
  M_NOT_FOUND` "Event not found"; Nebu choice, Oracle Q4); a STATE event (`state_key` not null) or an `m.room.redaction` -> `:not_redactable`
  (`403 M_FORBIDDEN` "This event cannot be redacted on this server", D4); a failing read fails closed (`:write_failed`); (5) another
  sender's event: the sender reaches `redact` (normalised, `PowerLevels.can?(levels, sender, :redact)`, new action) else
  `:insufficient_redact_level` (403 "You do not have a high enough power level to redact other users' events"); own event (`target.sender
  == sender`): (2) suffices; (6) the archived check and the write in ONE transaction (D9: `apply_redaction/2`; archived -> `:room_archived`,
  answered like `/send`: `400 M_BAD_STATE` "M_ROOM_ARCHIVED: room is archived"); (7) the size backstop (`EventSize.check_stored/1` on the
  signed bytes, `413`). Reasons for the order: authorisation that needs no read first; idempotency before the target so a retry of a
  committed redaction is answered with its id even when the target rule would now refuse (the event exists, the spec's idempotency); the
  target before `redact` because "own event" needs the target's sender. A member at the `m.room.redaction` level learns whether an event
  id exists in the room (404 vs 403): members can read the room's events anyway. **An already redacted target (security cycle 1,
  Kassandra #1 HIGH, read amplification):** after (1)-(5) (authorisation is still evaluated first: membership, the redaction level, own vs
  `redact`), a target that already has a writer-made redaction (`redacts` column not NULL; a LEGACY unchecked row does NOT count) is an
  IDEMPOTENT success: `200` with the event id of the EXISTING EARLIEST redaction (by `(origin_server_ts, event_id)`), NO new row, NO ETS
  entry: nothing is remembered under the new txn key (a retry is decided afresh, so it answers the existing id again, or `403` after a
  kick or demotion; this also keeps ETS from growing per txn id), NO audit row, no broadcast (labelled Nebu choice "a redaction of a
  redacted event returns the existing redaction"; the spec does not require a second event). The check runs inside the room process, so
  concurrent redactions of one target serialise: exactly one row is ever written per target. **Labelled Nebu choice (Oracle):** "authorisation is always re-evaluated before idempotency": the
  idempotency lookup comes AFTER membership and the `m.room.redaction` level, so a retry of a committed txn after the sender was kicked
  or demoted below the redaction level answers `403` instead of the original `200` (the spec's SHOULD "same status and body" for a
  retransmission is not met in that case; nothing is written either way). A REFUSED request is never cached: a retry after a promotion is
  decided afresh (`200`, a new event). Room resolution for `/redact` (Oracle decision): an unknown room id AND a known room whose process
  is not running both answer `404 M_NOT_FOUND` "room not found" exactly as `/send` (`lookup_room/1`, no lazy start, no `rooms` row);
  labelled "unknown room: 404 as `/send` (an existence oracle, accepted for parity; PUT state answers 403, `fz`)".
- **D3 (`/send` of `m.room.redaction` goes through the same writer).** v1.18 S5 (implemented although Nebu advertises v1.15): the
  dispatcher's `send_event/2` branches on `event_type == "m.room.redaction"` BEFORE the snapshot membership check and calls the redaction
  handler: `content.redacts` must be a non-empty string (else `400 M_BAD_JSON` "m.room.redaction requires content.redacts"; a value
  containing NUL -> `400 M_BAD_JSON` "content must not contain NUL characters", review M3: never a 500 or an ERROR log); it is
  MOVED to the top level (v10, S5: removed from the stored content), the rest of the content is the redaction's content, checked like the
  `/redact` body (`reason` string, at most 1024 bytes, no NUL: D13; Kassandra INFO 9); the idempotency key is `{room_id, user_id, {:send,
  "m.room.redaction", txn_id}}` (D7, security cycle 1). Same decision (D2), same answers, same audit (D12). A `/send`
  redaction is therefore no longer "stored as-is and delivered": the behaviour pinned by power-levels-enforcement AC17 (n) changes (re-pin,
  AC15). Room lookup as `/send` today (`lookup_room/1`, `404` "room not found" for an unknown or not running room, no lazy start, no row).
- **D4 (only message events can be redacted; Nebu restriction).** State events (incl. member, power levels, join rules, name, topic) and
  `m.room.redaction` events are `:not_redactable` (`403`). Reasons: a redacted state event changes the room state ("a redacted topic ...
  causes the topic to be removed"; a redacted v10 `m.room.power_levels` loses `invite` and `notifications`, an authorisation change), and
  Nebu's state readers (`rooms.power_levels_json`, `rooms.name`, the in-memory levels, the join-rule reads) are not redaction-aware; a
  redacted redaction loses its top-level `redacts` in v10 (S3). Labelled deviation ("state events and redactions cannot be redacted: Nebu
  restriction"), follow-up `ga`. Element offers "Remove" on state events (verified): it gets the 403 (an error dialog; the bulk dialog
  swallows it and has a "keep state events" option).
- **D5 (storage and serving format).** The redaction event is built and signed as the v10 PDU shape: top-level `"redacts" => target`,
  `content` = the client content without `redacts` (`/redact`: the body object, a body `redacts` key is dropped, the path wins; `/send`: the
  moved content). `Room.DB.insert_event/1` writes the new column `events.redacts` from the top-level key (NULL for every other event).
  **Migration 000051** (files `server/priv/migrations/000051_events_redacts.up.sql` / `.down.sql`): `ALTER TABLE events ADD COLUMN IF NOT
  EXISTS redacts TEXT` (nullable, no default, no backfill) and `CREATE INDEX IF NOT EXISTS events_redacts_idx ON events (redacts,
  origin_server_ts, event_id) WHERE redacts IS NOT NULL` (test review STORY-4: the D6 lookup has no `room_id` predicate and target ids
  are global content hashes, so the index leads with `redacts`; security cycle 1: the trailing `(origin_server_ts, event_id)` serves the
  "earliest per target" read of D6; down drops the index and the column) (plain, transactional; rolling-deploy safe: old nodes neither
  read nor write the column; header comment like 000050). **Operator notes (security cycle 1, Kassandra #4 / #10, review M6; 07-deployment
  and the migration header):** (a) (corrected in security cycle 2, review M4) the `ALTER TABLE events ADD COLUMN` takes an ACCESS EXCLUSIVE lock and holds it
  to the commit, covering the whole scan of the plain `CREATE INDEX` (alone a SHARE lock): reads AND writes on `events` wait, the duration
  grows with the table size, there is no lock timeout: run the migration in a maintenance window, or pre-create by hand before deploying:
  add the column (instant), then `CREATE INDEX CONCURRENTLY IF NOT EXISTS events_redacts_idx ...` (same definition); the migration is
  then a no-op, run it when no long transaction is open (its no-op ALTER still needs a brief ACCESS EXCLUSIVE lock); (b) ROLLING BACK 000051 (the down step) drops `events.redacts`: every applied redaction becomes a never-applied legacy row
  and every removed message is readable again for the room's members (a re-exposure; the down step is NOT refused, decision: documented). Served (every path of D6): a
  redaction event carries the top-level `redacts` (Element reads only that, verified) AND `content.redacts` (v11 S5 compatibility for
  newer clients, "should ... when serving"); a redacted event carries `content: {}`, no other change of the served keys (all Nebu-served
  keys are in the S3 kept list; `state_key` is absent for message events), and `unsigned.redacted_because` = the full served redaction
  event (event_id, type, room_id, sender, origin_server_ts, content with `redacts`, top-level `redacts`; no `unsigned`); `unsigned.age`
  stays where it is served today. Several redactions of one target: `redacted_because` is the EARLIEST by `(origin_server_ts, event_id)`
  (deterministic; labelled Nebu choice, Oracle Q8). **Legacy rows** (`m.room.redaction` written through `/send` before this story, column
  NULL) are NEVER applied: they were never authorised. **Oracle decision (Q9):** they are served WITHOUT `content.redacts` (the stored key
  is dropped at read time by the D6 render) and without a top-level `redacts`, so no client (also no v11-aware one reading
  `content.redacts`) applies them and server and clients agree; the stored row is unchanged (operator query Q-rd; follow-up `gd`).
  **Guard for a future room version (Oracle):** the stored shape is v10-only; `Room.Server.redact/5` builds the event through ONE function
  keyed by the room version (`Nebu.Matrix.RoomVersions`): for `"10"` top-level `redacts`, any other version is refused
  (`:unsupported_room_version`, unit test) until a v11 story stores `content.redacts` (v11 keeps it in the content).
- **D6 (prune on read, stored content kept; one pure module, one batched read per response).** The stored target row is NOT changed
  (`events` stays append-only, the GDPR runbook and ADR-023 Compliance Mode: content stays server-readable; ADR-030: redaction is not a
  deletion tool). "Redacted" is DERIVED: a row whose `event_id` is the `redacts` of a writer-made redaction row (column not NULL) in the
  same room. `Nebu.Matrix.Redaction` (pure): `prune(event_map, redaction_map)` (content `%{}`, attaches the served redaction) and the render
  helper for `redacts`. `Room.DB.redactions_for(event_ids)` (test review STORY-3, decided: ONE batched statement per
  `event_maps_to_core_events/1` call, i.e. one per joined room of a `/sync` response and one per `/messages` / `/event` / `/relations`
  response, plus ONE for all leave entries of a response; the same granularity as `fetch_state_predecessors/1`; seam
  `messages_db_module()`): ONE statement that returns AT MOST ONE row per target (security cycle 1, Kassandra #1: bounded in SQL, never
  "load all, keep the earliest" in the BEAM): the EARLIEST writer-made redaction per target by `(origin_server_ts, event_id)` (`SELECT
  DISTINCT ON (redacts) ... WHERE redacts = ANY($1) ORDER BY redacts, origin_server_ts, event_id`, or a `LATERAL ... LIMIT 1` per id;
  served by `events_redacts_idx`), UNION the redaction rows whose `event_id = ANY($1)` (the redaction events of the page, so every served
  redaction gets its `redacts`; at most one row per id by the primary key); the six string keys and the `(origin_server_ts, event_id)`
  order of the ATDD contract stay. The result size is bounded by the page size; with the D2 idempotency at most one writer-made row exists
  per target for new data anyway. Applied on EVERY client read path
  that serves content: `event_maps_to_core_events/1` (`/messages`, `/event`, `/relations`, `/sync` join timelines, `/initialSync`), the
  `/sync` LEAVE window (`build_leave_room/3` / `attach_leave_predecessors/1`: one batch for all leave entries, like the predecessors), the
  thread roots of `thread_root_updates/3`. `Core.Event` gains `redacts: ""` and `redacted_because: ""` (JSON); `Http.timeline_event_json/2`
  and `message_event/1` render them (`redacted_because` inside `unsigned`, never `null`, absent when empty). Search: both search statements
  exclude redacted events (`AND NOT EXISTS (SELECT 1 FROM events r WHERE r.room_id = e.room_id AND r.redacts = e.event_id)`).
  Relations (S6): `fetch_events_by_relation/5` and `count_thread_children/2` exclude redacted CHILDREN the same way (the relationship is
  broken); a redacted PARENT keeps its children. Edits (`m.replace`) of a redacted original stay served in `/messages`, `/sync` and
  `/relations` (S6: edits are not redacted; Element hides them in its timeline only; documented in the scope doc and 07-deployment:
  "edits of a removed message stay served"; security cycle 1, Kassandra #2), BUT both search statements also exclude every `m.replace`
  whose ORIGINAL is redacted (`AND NOT (e.content->'m.relates_to'->>'rel_type' = 'm.replace' AND EXISTS (SELECT 1 FROM events r WHERE
  r.redacts = e.content->'m.relates_to'->>'event_id' AND r.room_id = e.room_id))`), so "Remove" on an edited message removes its text from
  search too. Cascading the redaction to the edits (or MSC3912 `with_rel_types`) is a note on `ga`. **ONE prune rule (review M5):** the
  pure `Nebu.Matrix.Redaction` rule is the only one: the dispatcher's prune helper calls it (no second implementation); a dead function
  and its test are removed. **Fail-closed index (review M1, Kassandra INFO 6):** when the messages db module is the real
  `Nebu.Matrix.Room.DB`, a missing `Nebu.Repo` or a missing `redactions_for/1` raises the same handled `500` as a failed lookup; the
  `nil` ("no redactions") fallback is allowed ONLY for a test db module (`messages_db_module() != Nebu.Matrix.Room.DB`).
  `unsigned_relations` is not rendered anywhere (verified): not touched. Nobody (not the sender, not a room admin, not the Nebu Admin UI)
  sees the original content through any client API afterwards; the database keeps it (follow-up `gb`: retention / purge policy for
  redacted content, a compliance viewer, media of redacted events). A batched read failure fails CLOSED for the response (`500`, value-free
  ERROR log): never an unpruned page because the lookup failed.
- **D7 (idempotency and rate limit).** `/redact`: the key `{room_id, user_id, {:redact, event_id, txn_id}}` in `NebuTxnDedup` (the spec
  scopes a txn id to its path: a `/send` txn `"1"` and a `/redact` txn `"1"` never collide); **labelled "txn scope per user, not per
  device, node-local (`bd`)"**: the spec scopes a txn id to one device and one endpoint, so two devices of one user reusing a txn id on the
  same `/redact` path collide (the second gets the first's event id); `/send` (security cycle 1, Kassandra #5): the key becomes
  `{room_id, user_id, {:send, event_type, txn_id}}` for EVERY `/send` (messages and redactions alike), so a `/send` redaction and a
  `/send` message with the same txn id are two requests on two paths (the spec scopes a txn id to the HTTP path incl. the event type);
  still per user and node-local (`bd`). The entry is written only after the commit. **No rate tier** (spec "Rate-limited: No", the `/send`
  parity: a redaction is a small timeline event, not a state event in every member's `/sync`; Element's "Remove recent messages" sends
  every redaction at once without a retry on `429`, verified, so a tier would silently leave messages unremoved). Labelled "redactions are
  not rate-limited (spec: Rate-limited: No)"; the abuse bound is the `events["m.room.redaction"]` level and the `redact` level (Oracle Q6).
- **D8 (`fv`: ONE generic state writer, `Room.Server.write_state/5`).** `write_state(room_id, sender, {type, state_key}, content, opts)`
  (`opts`: `mode: :client | :tombstone`, `not_before:`), one `handle_call`: (1) membership else `:sender_not_joined`; (2) the level:
  `:client` `required_level({:state, type})`, `:tombstone` `max(required_level({:state, "m.room.tombstone"}), 100)` (D11) else
  `:insufficient_level`; (3) the `@` rule (`String.starts_with?(state_key, "@") and state_key != sender`) else `:foreign_user_key`; (4)
  the stamp `max(now, not_before, latest slot ts + 1)` with the latest slot read through the db module (`latest_state_identity(room_id,
  type, state_key)`: ONE indexed read of `events_room_state_idx`, every call, no cache; a failing read fails closed `:write_failed`; a db
  module without it is `:unsupported_db_module`) (closes the PUT-state part of `eu`); (5) `signed_state_event/6` (size backstop, `413`);
  (6) `Room.DB.apply_state_change(room_id, signed, opts)`: ONE transaction (`set_lock_timeout/0`, `lock_active_room_for_update/1`:
  archived -> `:room_archived` -> `404 M_NOT_FOUND` "Room not found" as the power-level branch (**labelled Nebu choice**: PUT state lists
  no 404 in the spec; and **labelled inconsistency, kept on purpose**: `/redact` and `/send` answer an archived room with `400 M_BAD_STATE`
  "M_ROOM_ARCHIVED: room is archived"; each path keeps the answer of its existing sibling (PUT state = the power-level branch, `/redact` =
  `/send`) so no existing client-visible answer changes; aligning them is a later decision), the event insert, and for `m.room.name` with state key
  `""` ONLY the `rooms.name` update: the denormalisation becomes atomic and no longer follows a name in another slot); (7) after the commit
  only: broadcast with `:pg.get_members/1` (cluster-safety; `fe`). The dispatcher keeps the ORDER of today's answers by a SNAPSHOT
  pre-check (allowlist, membership, level, `@` rule exactly as today, but with explicit `M_FORBIDDEN` texts) BEFORE the content rules
  (canonical alias store, name, topic, `m.space.parent` membership of the parent space: they read other rooms / the alias store and stay
  in the caller: calling another room's process from inside a room process could deadlock), so a refused sender still learns nothing about
  the alias store; the room process then decides (1)-(3) AUTHORITATIVELY: a demotion, a raised `events[type]` or a kick committed between
  the pre-check and the write refuses the write (`403`, nothing written). `m.room.power_levels` keeps its own writer (`change_power_levels/4`).
  Refusal texts (explicit `M_FORBIDDEN`): "You are not a member of this room", "You do not have a high enough power level to set this
  state", "You cannot set a state event whose state key is another user's id" (unchanged texts, now with errcode on every path); a write
  failure is the generic `500` (no `inspect(reason)`, value-free ERROR log with the room id and `db_error_class/1`; the `en` text of
  this path is gone); a call exit `503 M_UNAVAILABLE` "The room did not answer, the change may or may not have been applied" (the
  power-level text). The Admin Space form (`set_space_state/5`) uses the same path (its audit row stays after the committed write).
- **D9 (atomic writes in `Room.DB`; not `DBBehaviour` callbacks).** `apply_redaction(room_id, signed)` (lock timeout, the archived check,
  the insert incl. `redacts`) and `apply_state_change(room_id, signed, opts)` as in D8; both return `:ok | {:error, :room_archived} |
  {:error, reason}` and never raise (the `apply_power_levels_change/3` contract). The room process calls them only when the db module
  exports them (`Code.ensure_loaded?/1` + `function_exported?/3`), otherwise `:unsupported_db_module` (never a fallback to
  `insert_event/1`). The in-memory state is not changed by either (no cached state for these slots); ETS, broadcast and audit follow the
  commit.
- **D10 (`fz` and the `@` rule on `initial_state`).** (a) `set_room_state/2` uses `ensure_room_without_lazy_create!/1` (the power-level
  branch): an unknown room id answers `403 M_FORBIDDEN` "You are not a member of this room" with NO `rooms` row and NO room process; a known
  stopped room is started from the database; `fetch_room_state/1` is no longer reached from PUT state. (b) createRoom: an `initial_state`
  entry of any type (incl. an `m.room.member` entry) whose `state_key` starts with `@` and is not the creator -> `400 M_INVALID_ROOM_STATE`
  "The initial state contains a state key of another user" before the room exists (S7: "checking power levels for each event"; the
  power-levels review I3 note on `fv`). **Labelled "stricter Nebu rule"** (Oracle): the v10 `@` rule sits after the `m.room.member` branch
  and does not apply to member events; Nebu applies it to every entry, so an `m.room.member` entry for another user (today SKIPPED with a
  value-free warning: `@initial_state_forbidden_types`, server.ex l.839) is now refused with `400` instead of being skipped silently; a
  member entry with the creator's own key stays skipped. The PUT state `@` rule is unchanged (`m.room.member` is not allowlisted, `fq`).
  The createRoom writers and the upgrade copy into the NEW room stay `emit_state_event_at/6` in the caller (a brand-new room no other
  client can reach yet; labelled in the scope doc, pinned by a source test listing exactly these callers).
- **D11 (`fx`: the upgrade permission is the tombstone level, with a floor of 100; decided at the tombstone write).** The pre-check on the
  snapshot (before anything is written) and the AUTHORITATIVE check in the old room's process: the tombstone goes through
  `write_state/5` `mode: :tombstone` (membership, `max(required_level({:state, "m.room.tombstone"}), 100)`, the slot stamp, one
  transaction). Refusal: `403 M_FORBIDDEN` "You do not have a high enough power level to upgrade this room" (replaces the errcode-less
  "insufficient power level for room upgrade"); a demotion committed between the pre-check and the tombstone refuses the tombstone (nothing
  written, no freeze, no new room: the started new room process is stopped and its row cleaned up). **Orphan cleanup only for DEFINITE
  refusals (security cycle 1, Kassandra #3, review M2):** `cleanup_orphan_room` runs only when the tombstone write answered a definite
  refusal (`:insufficient_level`, `:sender_not_joined`, `:room_archived`, `:write_failed`, `:event_too_large`, `:foreign_user_key`,
  `:unsupported_db_module`: the seven reasons after which nothing was written); on
  `:room_unavailable` (the 5 s call exit: the tombstone MAY have committed) the new room is KEPT (an orphan without join rule or invitation,
  nobody can join it), the answer is `503 M_UNAVAILABLE` "The room did not answer, the change may or may not have been applied" (the state-writer text), and the
  operator / client retries `/upgrade` (documented in the scope doc upgrade row and 07-deployment: "on 503, retry the upgrade; a left
  orphan room is cleaned up by archiving it in the Admin UI"); the source comment "nothing was written to the old room" is corrected.
  **The floor 100 is a labelled Nebu restriction** ("upgrade needs the tombstone level and at least 100: Nebu restriction"): the D8 copy of
  story power-levels-enforcement is a v10 change by the upgrader in the new room, whose default `events["m.room.power_levels"]` is 100, so
  an upgrader below 100 could tombstone but never carry the levels. The D8 pre-check (no level above the upgrader's) and the post-freeze
  re-check stay. Closes `fx` (the floor is documented on the closed row, no new id).
- **D12 (audit).** After a COMMITTED redaction of ANOTHER user's event (not the idempotent replay, not a refusal): `room_event_redacted`
  (actor = sender, resource `room`, the room id, outcome `success`), metadata exactly `%{"event_id" => target, "target_sender" => the
  target's sender}` (no reason, no content: the reason is in the signed redaction event). Own-event redactions write NO row (Nebu choice:
  the signed redaction event is the record; a moderator act on another user is the compliance-relevant one, like kick / ban). Best effort
  after the room call (the `fs` residual). Added to `AuditWriter.@known_actions`. State writes keep their existing audit (only the Admin
  Space form).
- **D13 (request validation of `/redact`, router).** First failure wins: invalid JSON -> `400 M_NOT_JSON` "Request body is not valid JSON";
  a non-object body -> `400 M_BAD_JSON` "Request body must be a JSON object"; a path value (room id, event id) that is not UTF-8 or
  contains NUL -> `400 M_BAD_JSON` "Path parameters must be valid UTF-8" / "Path parameters must not contain NUL characters" (the PUT
  state texts; tested in AC17 (s)); nesting above 32 levels / a NUL anywhere in the body -> `400 M_BAD_JSON` (the PUT state texts); `reason`
  present and not a string -> `400 M_BAD_JSON` "reason must be a string", above 1024 bytes -> `400 M_INVALID_PARAM` "reason exceeds 1024
  bytes" (the moderation rule reused, Nebu choice; absent / `""` = no reason key); the sender above 255 bytes -> `403` (EventSize keys);
  the envelope above 65536 canonical bytes -> `413 M_TOO_LARGE`; then the core (room lookup `404`, D2). Other body keys are kept as
  content (Synapse parity, recalled); decided again in security cycle 1: kept, because the stored volume per target is bounded by ONE
  row (D2 idempotency) and every read by at most one row per target (D6), so a padded body can no longer be multiplied. The request
  logger treats the `/redact` path as a CONTENT body (review M4: `write_path_content_body?/1` gains the redact path regex, so DEBUG payload
  logging redacts it like `/send` and PUT state; No Sensitive Data in Logs Law). `/send` redactions keep the `/send` router checks plus
  the D3 content checks.
- **D15 (security cycle 1 hygiene: review I1, I3, I11).** (a) `Room.Server.write_state/5` is public without its own type allowlist:
  a SOURCE TEST pins its callers in `server/lib` (exactly `set_room_state/2`'s writer call and the upgrade tombstone, both through
  `room_registry_module()`), decided instead of a second allowlist inside the room process. (b) `ensure_room_without_lazy_create!/1`
  returns the fetched state on the stopped-room path and `set_room_state/2` reuses it as its snapshot (no second `get_state`). (c) Stale
  prose is fixed: the upgrade header comment (it still says "power_level >= 100": now the tombstone level with the floor 100), the
  tombstone failure comment (see D11), and any comment that still calls a re-redaction "a second row".
- **D14 (what stays out).** (Relations: all three `/relations` routes share `fetch_events_by_relation/5`, so the D6 child exclusion
  covers all of them; the tests pin the base route and `/{relType}` and `/{relType}/{eventType}` once each, AC17 (t).) State /
  redaction-event redaction (`ga`), stored-content purge and a compliance viewer (`gb`), server-admin
  redaction (`gc`), legacy unchecked redaction rows (`gd`), MSC3912 relation-based redactions (not advertised; js-sdk only sends them when
  asked), `PUT .../state/m.room.member` (`fq`, unchanged), `GET .../state` (`bf`), a PUT-state rate tier (`fp`), the join-rule slot reads
  vs a concurrent join (`eu`, open), `format_status/1` (`ft`, the new calls carry content), `/context` (`fk`, unrouted: when built it MUST
  use the D6 prune).

### Oracle questions (the Oracle gate runs next)

- Q1 (S2): Nebu enforces the client-server rule (own: `events` level; other: plus `redact`) at creation and never writes a redaction it
  would not apply; the v10 "same domain" condition is a federation rule and not used. Correct reading?
- Q2 (D6): prune on read with the stored content kept (Compliance Mode) instead of pruning the stored row: acceptable under "allowing
  server owners to delete" (a permission) and "returned anytime a client ... requests it"?
- Q3 (D3, D5): `/send` `m.room.redaction` through the same writer with `content.redacts` moved to the top level (v10) and served with both
  top-level and `content.redacts`; missing `content.redacts` -> `400 M_BAD_JSON`.
- Q4 (D2 (4)): a target that does not exist in the room -> `404 M_NOT_FOUND` (the spec lists no 404 for `/redact`; v10 "should not be sent
  to clients until both ... have been received").
- Q5 (D4): refusing redaction of state events and of redaction events (`403`): a labelled deviation acceptable for now?
- Q6 (D7): no rate tier for redactions (spec "Rate-limited: No") although kick / ban / power levels are charged.
- Q7 (D7): the `/redact` idempotency scope `{room, user, event_id, txn_id}` (per path, not per device).
- Q8 (D5): `redacted_because` = the earliest of several redactions.
- Q9 (D5): legacy unchecked redaction rows are never applied.
- Q10 (D6): redacted children excluded from `/relations` and the thread count; edits of a redacted original stay; search excludes
  redacted events.
- Q11 (D8, D10): snapshot pre-check for the answer order + the authoritative decision in the process; createRoom / upgrade-copy writers
  stay in the caller for a brand-new room; the `@` rule on `initial_state` as `400 M_INVALID_ROOM_STATE`.
- Q12 (D11): upgrade permission = tombstone level with a floor of 100 (Nebu restriction).
- Q13 (D12): auditing only redactions of other users' events.

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused ... `ga` onward" and a grep of `docs/` finds `ga`-`gd` in no row: the new ids are `ga`, `gb`, `gc`, `gd`; unused from `ge` onward)

- **`ga` — State events and redaction events cannot be redacted (Nebu restriction).** `PUT /redact` (and `/send` `m.room.redaction`) for a
  state event (member, power levels, join rules, name, topic, ...) or an `m.room.redaction` answers `403 M_FORBIDDEN` "This event cannot be
  redacted on this server". Element 1.12.15 offers "Remove" on state events (except server ACL / encryption). Building it needs
  redaction-aware state reads: the v10 prune of `m.room.power_levels` drops `invite` / `notifications` (an authorisation change), a redacted
  name / topic removes it (`rooms.name`), the in-memory levels and the join-rule reads. **Note (security cycle 1, Kassandra #2):** edits
  (`m.replace`) of a removed message stay served in `/messages`, `/sync` and `/relations` (the spec does not redact edits; Element hides
  them in its timeline only; search excludes them since this story); a server-side cascade of a redaction to the edits, or MSC3912
  relation-based redactions (`with_rel_types`, not advertised), belong to this row. Source: this story (D4, D6). Non-gating.
- **`gb` — Redacted content stays in the database (prune on read).** The original content of a redacted event is kept (Compliance Mode,
  GDPR runbook); no retention / purge policy for redacted content (spec: "allowing server owners to delete the offending content"), no
  compliance-side viewer of the original, media referenced by a redacted message stays downloadable by its mxc URL (ADR-030: decoupled),
  edits of a redacted original stay served (spec), the `search_vector` of a redacted row keeps its tokens (search excludes the row).
  Owner decision (compliance vs erasure). Source: this story (D6). Non-gating.
- **`gc` — Server-admin redaction is not offered.** Spec: "Server administrators may redact events sent by users on their server." The
  Admin UI has no message moderation and the Admin is usually not a room member. Source: this story (S1). Non-gating.
- **`gd` — Legacy unchecked `m.room.redaction` rows.** Rows written through `/send` before this story were never authorised (power-levels
  -enforcement AC17 (n)); their `redacts` column is NULL, they are never applied and are served as stored (content incl. the client's
  `content.redacts` and `reason`). Operator query **Q-rd** (07-deployment) lists them; cleanup (or applying the ones whose sender had the
  `redact` level at the time) is an owner decision. Since this story they are SERVED without `content.redacts` and without a top-level
  `redacts` (Oracle Q9: no client applies them; the stored row keeps the key). Source: this story (D5). Non-gating.
- Notes (no new id): `fw`, `fv`, `fz`, `fx` CLOSED (the floor 100 of D11 on the `fx` row); `eu` (the PUT-state part and the tombstone are
  stamped `max(now, latest slot + 1)` now; the join-rule slot reads vs a concurrent join, `create_personal_room` stay open); `en` (the
  `set_room_state failed: inspect(..)` 500 is gone; `/send` depth / NUL stay); `fp` (PUT state still uncharged; redactions are not
  charged by decision); `fl` (`unsigned.redacted_because` is served now; `age` on `/messages` still missing); `ft` (`write_state` and
  `redact` carry content: `format_status/1` must redact it); `fe` (the state writer broadcasts with `:pg.get_members/1`; the `/send` path
  and the createRoom writers stay node-local); `bd` (the `/redact` key adds the event id; still per user and node-local); `fk` (a future
  `/context`, the search `context.events_before` / `events_after` and a rendered thread `latest_event` must apply the D6 prune; a
  redacted original must not bundle `m.replace`); `ad` unchanged.

## Acceptance Criteria

Test files are named in "Acceptance Tests". "Real DB" = the real `Nebu.Repo`, `Room.Server` under `Horde`, `Room.DB`, through
`Nebu.Web.Router` where the AC says HTTP (`@moduletag :integration`, random users and rooms). Fakes only where an AC says "unit"; every
concurrency and atomicity claim is proven on the real database. Every refusal: nothing written (no event, no ETS entry, no audit row).

1. **The redaction route (HTTP real DB, D1, D2, D5).** (a) bob sends a message; bob `PUT /rooms/{r}/redact/{bob's event}/{txn}` with
   `{"reason": "typo"}` -> `200 {"event_id"}`; the stored redaction row has `redacts` = the target, `content` = `{"reason": "typo"}`
   (no `redacts` in the stored content), a valid signature; a `200` with `{}` body works too (no `reason` key). (b) In every member's next
   `/sync` timeline the redaction event carries top-level `redacts` AND `content.redacts` = the target and the `reason`. (c) Afterwards the
   target is served with `content: {}` and `unsigned.redacted_because` (the full redaction event: `event_id`, `type`, `sender`, `room_id`,
   `origin_server_ts`, `content.redacts`, top-level `redacts`) by `/messages`, `/event`, an initial `/sync` timeline, `/initialSync`; the
   other served keys unchanged; the stored target row is byte-identical to before (content, signatures). (d) The same txn id again ->
   `200` with the SAME event id, one row only; the same txn id for ANOTHER target -> a new redaction (scope D7); a `/send` txn with the same
   id string is unaffected; (security cycle 1, Kassandra #5) a `/send/m.room.message/T` and a `/send/m.room.redaction/T` by the same
   user are two requests (each written, two different event ids; no replay across event types).
2. **The decision (HTTP real DB, D2), each a separate test, levels seeded with `set_power_levels/3`.** (a) Own event at `events_default`
   (0, no `events` entry): `200`. (b) Another user's event by a member at 0 (`redact` 50): `403` "You do not have a high enough power level
   to redact other users' events", the target unchanged in `/event`. (c) The same by a member at 50: `200`. (d) `events["m.room.redaction"]:
   50`: a member at 0 cannot redact even his OWN event (`403` "You do not have a high enough power level to send this event"). (e) `redact:
   0` with `events["m.room.redaction"]: 0`: anyone may redact anyone's message (`200`, spec). (f) Non-member (never joined, left, kicked,
   banned, invited) -> `403` "You are not a member of this room". (g) An unknown event id, an event of ANOTHER room -> `404 M_NOT_FOUND`
   "Event not found" (the other room's event unchanged). (h) A state event (`m.room.topic`, `m.room.member`, `m.room.power_levels`) and an
   `m.room.redaction` as target -> `403` "This event cannot be redacted on this server". (i) An archived room (status set, process running)
   -> `400 M_BAD_STATE` "M_ROOM_ARCHIVED: room is archived". (j) The order (first failure wins): a non-member with an unknown target ->
   `403` (not `404`); a member below the redaction level with an unknown target -> `403`; a member at the level with an unknown target ->
   `404`. (k) (rewritten, security cycle 1) An already redacted event redacted again (another
   txn id, by the same and by another authorised sender) -> `200` with the SAME event id as the existing redaction, EXACTLY ONE
   redaction row for the target, no audit row and no broadcast for the replay, nothing remembered under the new txn key (a retry is
   decided afresh: the existing id again, or `403` after a kick or demotion); the second request by a member BELOW `redact` (another
   user's event) is still `403` (authorisation first); a target that only has a LEGACY unchecked row is redacted normally (`200`, a new
   writer-made row). (l) An unknown room and
   a known room whose process is stopped -> `404 M_NOT_FOUND` (as `/send`), NO `rooms` row created, no process started.
3. **Request validation (HTTP real DB, D13).** Each case `400` / `403` / `413` with the D13 errcode and fixed text: invalid JSON, a JSON
   array body, `reason: 5`, `reason: null` (= absent: `200`), a 1025-byte reason (`M_INVALID_PARAM`), a 1024-byte reason (`200`), a NUL in
   the reason, a body nested 33 levels, a body of 70 000 bytes (`413`); other body keys are kept in the stored content; a body `redacts`
   key differing from the path is dropped (the path wins). Error bodies are exactly `{"errcode", "error"}`, no client value echoed.
4. **`/send` of `m.room.redaction` (HTTP real DB, D3).** (a) `content: {"redacts": <other user's event>}` by a member at 0 -> `403` (the
   `redact` rule; was `200` stored as-is: AC17 (n) of power-levels-enforcement re-pinned); by a member at 50 -> `200`, the stored row has
   the top-level `redacts` (column set) and NO `content.redacts`; served exactly as AC1 (b) / (c). (b) Without `redacts`, with a non-string
   `redacts` -> `400 M_BAD_JSON` "m.room.redaction requires content.redacts". (c) Idempotency with the `/send` key. (d) Own event at
   `events_default` -> `200`. (e) `Room.Server.send_event/6` called directly with type `m.room.redaction` -> `{:error, :forbidden}`, nothing
   written (unit + source pin).
5. **Every read path is pruned (HTTP real DB, D6).** With one redacted message M (sender bob, content with a unique marker word) and its
   redaction R: (a) `/messages` both directions, `/event/{M}`, initial and incremental `/sync` (join timeline), `/initialSync`, the `/sync`
   LEAVE window of a member who left after R, the thread-root prepend of `thread_root_updates/3` (M a thread root, a new reply after R):
   M has `content: {}` and `redacted_because`, R has both `redacts`; the marker word appears in NO response body of the test (asserted on
   the raw JSON). (b) `POST /search` for the marker word -> no result (before R: one result). (c) `/relations/{parent}` with a redacted
   reaction / thread reply child: the child is absent, the thread count excludes it; a redacted PARENT still lists its children. (d) An edit
   (`m.replace`) of M stays served with its own content (spec, S6). (e) A LEGACY redaction row (inserted directly with column NULL and
   `content.redacts` = M2) does NOT redact M2 anywhere and is served without a top-level `redacts` AND without `content.redacts`
   (its `reason` and other keys unchanged; the stored row keeps the key). (f) The batched lookup granularity of D6
   (a db hook counts `redactions_for/1` calls): one per `/messages` / `/event` / `/relations` response; an initial and an incremental
   `/sync` with 3 joined rooms -> one per joined room (the statement-count baseline of `member_prev_content_http_test.exs` 45 -> 48,
   AC15 (f)); a `/sync` with 2 new leave entries -> ONE for both; `/messages?dir=b&limit=1` whose page holds M but not R -> M still
   pruned. (g) A failing `redactions_for/1` (hook) on `/messages` and on an initial `/sync` -> a HANDLED `500` with the generic body
   (value-free ERROR log with `db_error_class/1`), the request process does not crash, never an unpruned page.
6. **The redaction writer: atomicity, archived, crash (real DB, D1, D9).** (a) `apply_redaction/2` with an insert that fails inside the
   transaction (pre-insert the identical signed event: unique violation) -> nothing written, no ETS entry, no broadcast to a `:pg` test
   member, no audit row; `500`; a retry with a new txn id succeeds. (b) unit: a db module without `apply_redaction/2` -> refused
   (`:unsupported_db_module`), never `insert_event/1`. (c) A room process that does not answer -> `503 M_UNAVAILABLE` "The room did not
   answer, the redaction may or may not have been applied". (d) Crash / restart (`.claude/rules/matrix-conventions.md`): after a committed
   redaction the room process is killed and restarted: M is still served redacted, a new redaction works; a process killed DURING a
   redaction (db hook before the commit) leaves no row.
7. **The state writer (HTTP real DB, D8).** (a) A PUT of `m.room.topic` by a member at the level -> `200`; the event is written by the room
   process (source pin: `set_room_state/2` has no `emit_state_event` call), `/sync` shows it with `unsigned.prev_content` /
   `replaces_state`. (b) Stamp: a topic event inserted 100 ms AHEAD of the clock (own room, `on_exit` delete), then a PUT at once: the new
   event's `origin_server_ts` = previous + 1, it is the latest topic in `/sync`. (c) `m.room.name` with state key `""` updates
   `rooms.name` in the same transaction (an insert failure leaves `rooms.name` unchanged); `m.room.name` with state key `"x"` does NOT
   touch `rooms.name`. (d) An archived room (process running) -> `404 M_NOT_FOUND` "Room not found" (errcode
   asserted), nothing written. (e) A failing write -> `500`
   with the generic body, the ERROR log names the room id and the SQLSTATE class only (no content, no `inspect`). (f) unit: a db module
   without `apply_state_change/3` or `latest_state_identity/3` -> refused, never the caller-side insert. (g) The answers and their order
   stay: forbidden type (text unchanged: "You are not a member of this room", now with an explicit `M_FORBIDDEN`; STORY-8), non-member,
   level, `@` rule (each with `M_FORBIDDEN`; order pairs: a forbidden type by a non-member, a below-level user with another user's `@`
   key -> the level text), then the content rules (`M_BAD_ALIAS`,
   `M_INVALID_PARAM`, `M_BAD_JSON` of name / topic, the `m.space.parent` 404 / 403), each a separate test. (h) The Admin Space form
   (`Nebu.Matrix.set_space_state/5`) writes through the same writer and keeps its one audit row. (i) Crash / restart: a PUT after a room
   process restart stamps after the latest slot event (read from the database).
8. **`fz` and the `@` rule on `initial_state` (HTTP real DB, D10).** (a) PUT `m.room.topic` into an unknown room id -> `403 M_FORBIDDEN`
   "You are not a member of this room", NO `rooms` row, NO room process (Horde lookup). (b) A known room whose process is stopped: the PUT
   starts it and succeeds. (c) createRoom with an `initial_state` entry `{"type": "m.room.name", "state_key": "@other:localhost", ...}` ->
   `400 M_INVALID_ROOM_STATE` "The initial state contains a state key of another user", no room; with the creator's own id -> `200`.
9. **Concurrency (real DB, at least 50 rounds each, `Task.async` with a barrier, invariants after every round).** (a) A demotion of a
   moderator (100 -> 0 by a creator seeded at 150) vs 10 concurrent redactions of other users' messages by that moderator: no `500` / `503`;
   every redaction STARTED after the demotion's reply is `403`; each `200` has its row; each refusal wrote nothing. (b) A raise of
   `events["m.room.topic"]` to 100 vs 10 concurrent topic PUTs by a member at 50: the same invariants (state writer). (c) A kick of a member
   vs his concurrent topic PUTs and own-message redactions: none STARTED after the kick's reply succeeds. (d) Two concurrent PUTs of one
   slot: both `200`, distinct strictly increasing `origin_server_ts`, the `prev_content` chain is linear. (e) Two (and, security cycle 1, ten)
   concurrent redactions of one target by authorised senders: all `200` with the SAME event id, EXACTLY ONE redaction row (D2
   idempotency), `redacted_because` is that row. A failure prints the round's event sequence (no message content).
10. **Upgrade (`fx`, HTTP real DB, D11).** (a) `events["m.room.tombstone"]: 150`, the requester at 100 -> `403 M_FORBIDDEN` "You do not
    have a high enough power level to upgrade this room", no tombstone, no new room, old room not archived. (b) The requester at 150 with
    every level <= 150 -> `200`. (c) `events["m.room.tombstone"]: 50`, the requester at 60 -> `403` (the floor 100, labelled). (d) A
    demotion committed between the pre-check and the tombstone (deterministic hook): `403`, no tombstone, no freeze, no new room left
    behind (its row and process cleaned up). (d') (security cycle 1, Kassandra #3 / review M2) a tombstone write whose room call EXITS
    (a fake / hooked `write_state` that exits; `:room_unavailable`): `503 M_UNAVAILABLE` "The room did not answer, the change may or may
    not have been applied", the new room is NOT cleaned up (row and process stay), a retried `/upgrade` works; every DEFINITE refusal
    (`:insufficient_level`, `:sender_not_joined`, `:room_archived`, `:write_failed`, `:event_too_large`, `:foreign_user_key`,
    `:unsupported_db_module`) still cleans
    up (one test per refusal kind that is reachable). (e) The tombstone is stamped after the latest tombstone-slot event and written in one
    transaction (an archived old room whose process still runs -> `404 M_NOT_FOUND` "Room not found", the D8 power-level-branch answer,
    nothing written; STORY-7). (f) The existing upgrade suites stay green apart from the AC15 re-pins.
11. **Audit (real DB, D12).** A committed redaction of another user's event writes exactly one `room_event_redacted` row (actor, resource
    `room`, room id, metadata EXACTLY `event_id` + `target_sender`, outcome `success`); own redactions, the idempotent replay and every
    refusal write none; `AuditWriter.log/6` accepts the action; a failing audit writer does not fail the redaction (`200`, value-free ERROR
    log). No reason and no message content appear in any log line of the suite (captured logs) or in the audit row.
12. **Source pins (unit).** (a) In `server/lib` no `m.room.redaction` event is built outside `Room.Server.redact/5`; `apply_redaction/2` is
    the only writer of a non-NULL `redacts`. (b) `emit_state_event_at/6` / `emit_state_event/5` callers are EXACTLY the createRoom writers
    (preset, name, topic, derived alias, explicit alias, `initial_state`) and the upgrade's NEW-room writers (`m.room.create`, the state
    copy); the tombstone and `set_room_state/2` call `Room.Server.write_state/5`. (c) `PowerLevels.required_level/2` / `can?/3` know
    `:redact`; the "Not evaluated anywhere ... `redact`" moduledoc sentence is gone. (d) `Nebu.Matrix.Redaction` is pure (no DB, no
    process). (e) **Mandatory seams (STORY-11):** the dispatcher reaches both writers ONLY through
    `room_registry_module().write_state/5` and `room_registry_module().redact/5` (`:event_dispatcher, :room_registry_module`, default
    `Nebu.Matrix.Room.Server`; an AST pin), never a direct `Nebu.Matrix.Room.Server.write_state` / `.redact` call; the fakes of every suite
    that reaches the new writers implement them (real fakes that write the state and the event, never stubs) and the db fakes implement
    `apply_redaction/2` / `apply_state_change/3` / `latest_state_identity/3` (list in AC15 (d)). (f) The broadcasts of `redact/5` and
    `write_state/5` use `:pg.get_members/1`, not `get_local_members/1` (AST pin in `room/server.ex`). (g) (security cycle 1, D15 (a))
    the callers of `write_state/5` in `server/lib` are exactly `set_room_state/2`'s writer call and the upgrade tombstone (source test). (h)
    (D6, review M5) exactly ONE prune rule: the dispatcher's prune helper calls `Nebu.Matrix.Redaction`; no unused prune function remains
    in `server/lib` (source test).
13. **Migration (real DB).** `000051_events_redacts.up.sql` / `.down.sql`: up: the column and the partial index
    `events_redacts_idx` on `(redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL` exist (definition pinned via `pg_indexes`;
    security cycle 1); the migration header and 07-deployment carry the SHARE-lock / `CONCURRENTLY` pre-create note and the rollback
    re-exposure note of D5 (docs suite); down: both gone; up is idempotent (`IF NOT EXISTS`);
    a `redacts` value is written only for writer-made redactions (every other insert leaves NULL).
14. **Docs (`server/test/nebu/matrix/state_writer_redaction_docs_test.exs`, new).** (a) `docs/matrix-api-scope.md`: the `/redact` row
    becomes ✅ (the D2 order and texts, own vs `redact`, D4 "state events and redactions cannot be redacted: Nebu restriction", D13, the
    labels "redactions are not rate-limited (spec: Rate-limited: No)", "target must exist: Nebu choice", "stored content kept, pruned on
    read: compliance (`gb`)", `ga`, `gc`); the `/send` row: `m.room.redaction` goes through the redaction writer, `content.redacts` moved to
    the top level, the risk note of `fw` is gone; the two PUT state rows: decided and written in the room process (`write_state/5`), the
    slot stamp, `404` for an archived room, no lazy `rooms` row (`fz`), the explicit errcodes, "createRoom and upgrade-copy writers stay in
    the caller: brand-new room"; the createRoom row: the `@` rule on `initial_state`; the upgrade row: "upgrade needs the tombstone level
    and at least 100: Nebu restriction", the tombstone in the room process; `/messages`, `/event`, `/relations` (3 rows), `/sync`, `/search`
    rows: redacted events are served pruned with `unsigned.redacted_because` / excluded (search, relation children). (b)
    `docs/architecture/07-deployment.md`: a new paragraph "**Redaction and the room-process state writer (story state-writer-redaction,
    follow-ups `fw`, `fv`, `fz`, `fx`).**" (Element's "Remove" works; what is kept in the database and why (Compliance Mode); legacy rows and
    operator query **Q-rd** (`SELECT ... FROM events WHERE event_type = 'm.room.redaction' AND redacts IS NULL`), checked in a rolled-back
    transaction with fixture rows; the migration is rolling-deploy safe). (c) `docs/architecture/08-concepts.md`: the audit action. (d)
    `CHANGELOG.md` `[Unreleased]`: `### Added` the route, the audit action, migration 000051; `### Changed` (**⚠**): `/send` redactions are
    authorised (redact level) and applied, redacted events are served pruned, state events cannot be redacted, PUT state is decided in the
    room process (archived room `404`, unknown room no row), upgrade needs the tombstone level, `initial_state` `@` keys refused. (e)
    `follow-ups.md`: `fw`, `fv`, `fz`, `fx` rewritten as **CLOSED by story state-writer-redaction (date)** KEEPING the words pinned by
    `power_levels_docs_test.exs` (`fv`: "write_state/5", "state-writer-room-process", "`eu`", "emit_state_event_at/6"; `fw`: "redact",
    "m.room.redaction", "/send", "events_default", "RAISED", `events["m.room.redaction"]`; `fx`: "m.room.tombstone", "required_level",
    "users[requester] >= 100"; `fz`: "rooms", "lazily", "fetch_room_state/1", "403", "pre-existing"); notes on `eu`, `en`, `fp`, `fl`, `ft`,
    `fe`, `bd`, `fk`; new rows `ga`, `gb`, `gc`, `gd`; the id line "`ga`-`gd`: state-writer-redaction" and "unused: ... `ge` onward". (f)
    The suite pins (a)-(e), the Q-rd SQL against fixture rows, and the absence of the removed phrases ("an `m.room.redaction` is stored
    as-is and delivered", "`redact` not evaluated: no redaction route", "Unrouted (follow-up `fw`)").
15. **Regression and deliberate re-pins.** `mix compile --warnings-as-errors`; `mix test` and `mix test --include integration` green apart
    from the known flaky families (`fj`, `fm`, the families listed in the power-levels-enforcement Debug Log). Deliberate re-pins (**Change
    Log old -> new per test; the re-pin diff is reviewed before the verify step**; never weaken an assertion; any OTHER needed change is a
    finding: stop and report): **(a) the id-line assertion "`ga` onward" -> "`ge` onward" in the NINE docs suites**
    `create_room_invites_docs_test.exs`, `create_room_presets_docs_test.exs`, `event_size_limit_docs_test.exs`,
    `member_prev_content_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`, `membership_write_limits_docs_test.exs`,
    `moderation_routes_docs_test.exs`, `sync_membership_partition_docs_test.exs`, `power_levels_docs_test.exs` (each with a comment naming
    this story; the old "`ga` onward" is refuted by the new docs suite); (b) `power_levels_docs_test.exs`: the rows `fv`, `fw`, `fx`, `fz`
    "open" -> "closed" (the fact words kept), the PUT-state label "`redact` not evaluated: no redaction route", the `/send` risk note and
    "`redact` is stored, not evaluated", the `/redact` row "🔲 ... Unrouted (follow-up `fw`)" -> ✅, the upgrade-row test title "the
    permission stays 100 (fx)"; (c) `power_levels_http_test.exs` l.628-644 (`/send` redaction gating: the 200 by a member at 50 needs the
    target to be his own or `redact` <= 50; record which) and AC17 (n) (l.1448-1470: `200` stored as-is and delivered -> `403`, nothing
    stored); (d) the fake-registry / fake-db suites (STORY-2; edits taken from the ATDD reference diff
    `scratchpad/atdd/handoff/reference-fake-suites.diff`, real fakes, never stubs): `event_dispatcher/set_room_state_test.exs` (42 tests:
    the fake DB gains `get_room_status/1`, the fake registry `write_state/5`; the test "a `rooms.name` failure stays non-fatal" becomes a
    `500` with nothing written (D8: atomic), its log assertions move to the real-DB suite); `space_edit_audit_test.exs` (16);
    `upgrade_room_test.exs` (18) and `event_dispatcher/upgrade_room_error_handling_test.exs` (3) (the fake dbs gain `apply_state_change/3`
    and `latest_state_identity/3`; the upgrade 403 text); further candidates the dev checks and records: `event_size_backstop_test.exs`,
    `matrix_client_compat_test.exs`, `spaces_state_events_integration_test.exs`; answer texts with errcodes (the errcode-less 403s become
    `M_FORBIDDEN`); the archived PUT state (was written, now `404`); (e) `event_dispatcher/create_room_initial_state_test.exs` and
    `create_room_initial_state_http_test.exs` AC4: an `m.room.member` entry for another user was skipped, now `400 M_INVALID_ROOM_STATE`
    (D10 (b)); other createRoom tests with another user's `@` key, if any; (f) **three existing tests the story breaks (STORY-1)**:
    `room/state_predecessors_db_test.exs` l.601-619 AC1 (m) "redaction guard": the refutation of the literal `m.room.redaction` in every
    `server/lib` file -> an ALLOW-LIST of files (`room/server.ex`, `redaction.ex`, `event_dispatcher/server.ex`, `http.ex`, `room/db.ex`,
    `room/power_level.ex`, `compliance/audit_writer.ex`, `web/log_store/route_normalizer.ex`), the refutations of `UPDATE events` and
    `events SET content` STAY (the D6 compliance guard); `member_prev_content_http_test.exs` l.42 `@baseline_initial_sync_statements` 45 ->
    48 (one batched redaction lookup per joined room, 3 rooms; STORY-3); `unrecognized_routes_test.exs`: `{:put,
    "/client/v3/rooms/:p/redact/:p/:p"}` moves from the unrouted to the routed list. Unchanged and green: `power_levels_*` apart from (b) /
    (c), `moderation_*`, `sync_*`, `member_prev_content*` apart from (f), `create_room_*` apart from (e).
16. **Labels in the scope doc (part of AC14 (a), pinned verbatim by the docs suite).** `/redact` row: "authorisation is always
    re-evaluated before idempotency: Nebu choice", "txn scope per user, not per device, node-local (`bd`)", "unknown room: 404 as `/send`",
    "archived room: 400 M_BAD_STATE as `/send`"; PUT state rows: "archived room: 404 M_NOT_FOUND: Nebu choice", "archived answer differs
    from `/redact` (400 M_BAD_STATE): kept on purpose"; createRoom row: "`@` rule on every `initial_state` entry incl. `m.room.member`:
    stricter Nebu rule"; `/send` / `/sync` rows: "legacy unchecked redactions are served without `redacts` (`gd`)". **Further tokens
    the staged docs suite pins (test review M-17; the docs MUST contain them, the dev copies them exactly):** PUT state rows: "decided
    AUTHORITATIVELY in the room process", "stamped max(now, latest slot ts + 1)"; `/send` row: "`content.redacts` is MOVED to the top
    level"; `/search` row: "redacted events are excluded (NOT EXISTS)"; `/redact` row: "nesting above 32 levels" (D13) and "never the
    reason" (no log line, no audit row carries the reason); 07-deployment paragraph: "\"Remove\" HIDES a message, it does not erase it".
17. **Oracle missing tests (HTTP real DB unless noted; each a separate test; nothing written on every refusal).**
    (a) `events["m.room.redaction"]: 75`, `redact: 50`, a user at 60 redacts another user's event -> `403` "You do not have a high enough
    power level to send this event" (the redaction level is checked before `redact`).
    (b) A redaction succeeds with txn T; the user is then demoted below the redaction level (one test) / kicked (another test); T retried ->
    `403` (the labelled D2 choice), no second row.
    (c) The same user with two devices (two sessions), the same `/redact` path and txn id -> the second answers `200` with the FIRST event
    id, one row (pins the per-user scope, `bd` label).
    (d) A refused redaction (`403`, below `redact`) with txn T; the user is promoted; T retried -> `200` with a new event (refusals are not
    cached).
    (e) `/send` `m.room.redaction` with `content.redacts: ""` -> `400 M_BAD_JSON`; with a target of another room -> `404 M_NOT_FOUND`; with
    `{"redacts", "reason", "x_extra"}` -> `200`, the stored content keeps `reason` and `x_extra`, `redacts` is top-level only.
    (f) Redacting an `m.replace` edit -> the edit is served pruned; the original keeps its content; `/relations/{original}` no longer
    lists the edit.
    (g) Redacting a reply and a thread reply (`m.relates_to`) -> served `content: {}`, gone from `/relations` and from the thread count; a
    redacted thread ROOT still lists its replies in `/relations`.
    (h) Redacting an event whose sender has since left (one test) / been banned (another) -> `200` (a moderator at `redact`).
    (i) Archived room side by side: `/redact` -> `400 M_BAD_STATE`, PUT state -> `404 M_NOT_FOUND` (both errcodes asserted), nothing written.
    (j) `/redact` on a known room whose process is stopped -> `404 M_NOT_FOUND`, no lazy start, the `rooms` row unchanged, no process.
    (k) `PUT /rooms/{r}/state/{type}` (the route without a state key) goes through `write_state/5` too: the same refusals (non-member,
        level, archived) and the slot stamp.
    (l) PUT state with `state_key` = the sender's own `@` id (an allowlisted type) -> `200` (positive case of the `@` rule).
    (m) createRoom with `power_level_content_override.users[creator]: 0` plus a `name` / plus an `initial_state` `m.room.topic` ->
        `400 M_INVALID_ROOM_STATE` (the spec's example; record today's behaviour in the Debug Log first: if it already holds, a pin).
    (n) createRoom with an `initial_state` `m.room.member` entry for another user -> `400 M_INVALID_ROOM_STATE` (D10 (b), stricter Nebu
        rule), no room; with the creator's own key -> skipped as today (`200`, no extra member event).
    (o) Upgrade: no `events["m.room.tombstone"]`, `state_default: 50`: a requester at 50 -> `403` (the floor 100), at 100 -> `200`; a
        non-member requester at 100 -> `403 M_FORBIDDEN`.
    (p) `/messages` and `/sync` with a filter (`types`, `not_types`; `contains_url` only if Nebu supports it, else recorded as not
        applicable): a redacted message in the result is still pruned; a filter never matches on the stored original content (if
        filters are ignored, `fg` (a), the test pins the pruned result and records it).
    (q) `POST /search` for a word of a redaction's `reason` -> no result; an unrelated message in the same room is still found after a
        redaction.
    (r) The `redacted_because` copy contains no `unsigned` and no content of the target (the raw-JSON marker check of AC5 (a) covers
        `redacted_because`).
    (s) (test review STORY-10) `/redact` with a room id path value containing a NUL (`%00`) and one that is not UTF-8 (`%FF`) -> `400
        M_BAD_JSON` with the D13 texts, before any room lookup, nothing written, no `rooms` row.
    (t) (STORY-10) A redacted child is absent from `/relations/{parent}`, `/relations/{parent}/{relType}` and
        `/relations/{parent}/{relType}/{eventType}` (one test each).
    (u) (test review M-1) Archive committed through `Nebu.Admin.DB.archive_room_atomic/1` while a redaction write is blocked inside its
        transaction (db hook), then released -> `{:error, :room_archived}` / `400 M_BAD_STATE`, nothing written (the archived check is
        INSIDE the transaction).
    (v) (M-5) The `/send` variants of AC2: a non-member -> `403` "You are not a member of this room"; an archived room -> `400 M_BAD_STATE`;
        an unknown room -> `404`; a state-event target -> `403` "This event cannot be redacted on this server"; another user's event by a
        moderator -> exactly one `room_event_redacted` row.
    (w) (M-6) A member at 0 whose target is a state event -> "This event cannot be redacted on this server" (D2 (4) before (5)); a user at
        50 with `redact: 51` -> `403` (the other side of the `>=` boundary).
18. **Security cycle 1 (Kassandra #1-#5, code review M1-M6, I1, I3, I11; each a separate test, nothing written on every refusal).**
    (a) **Read-amplification regression (#1 HIGH):** 5 sequential `/redact` (distinct txn ids, bodies padded with 1 KB) and 10 concurrent
        redactions (AC9 (e)) of ONE target leave EXACTLY ONE redaction row; a target with 30 directly inserted writer rows (2 KB padding
        each) reads as ONE row (cycle 2: the numbers of the tests); `Room.DB.redactions_for/1` for that target (and for a target
        with several legacy-style writer rows inserted directly, so the SQL bound is tested independently of the writer) returns AT MOST
        ONE row per target, the earliest by `(origin_server_ts, event_id)`; the statement is bounded in SQL (an EXPLAIN / source pin
        that the dev's real statement uses `DISTINCT ON` or `LATERAL ... LIMIT 1` over `events_redacts_idx`).
    (b) (#5) `PUT /send/m.room.message/T` then `PUT /send/m.room.redaction/T` (content.redacts = that message) by the same user: both
        written (two ids, the message redacted); and in the other order; a repeated `/send/m.room.message/T` is still a replay.
    (c) (#2) An edited message M (an `m.replace` edit E with a marker word in `m.new_content` and the `* ` fallback) is redacted: `POST
        /search` for E's marker -> no result (both search statements, with and without a room filter); E itself is still served by
        `/messages` and `/relations/{M}` (spec, documented); an `m.replace` whose original is NOT redacted is still found.
    (d) (M3) `/send` `m.room.redaction` with `content.redacts` containing NUL -> `400 M_BAD_JSON` "content.redacts must not contain NUL
        characters", no ERROR log line; with a `reason` above 1024 bytes / a non-string `reason` -> the D13 answers.
    (e) (M4) The request-logger suite: with DEBUG payload logging on, a `PUT .../redact/...` body with a custom key and a marker value is
        logged redacted as a content body (the marker never appears).
    (f) (M1) `redaction_index` fail-closed: with the real `Nebu.Matrix.Room.DB` as messages db module and `redactions_for/1` unavailable
        (no Repo process, simulated) -> the handled `500`, never an unpruned page; the `nil` fallback only for a test db module (unit).
    (g) (#3 / M2) see AC10 (d').
    (h) (D15 (b), I3) the stopped-room path of PUT state reads the room state once (a counting registry fake: one `get_state/1`).
    (i) (#4, M6) the docs suite pins the 07-deployment rollback re-exposure sentence, the SHARE-lock / maintenance-window /
        `CONCURRENTLY` pre-create sentence and "edits of a removed message stay served" (scope doc and 07-deployment).

## Acceptance Tests

- `server/test/nebu/matrix/redaction_http_test.exs` (new, `:integration`, through `Nebu.Web.Router`): AC1, AC2, AC3, AC4 (a)-(d), AC5,
  AC11, AC17 (a)-(j), (p)-(t), (v), (w); AC17 (u) in `room/redaction_writer_db_test.exs`; AC18 (a) (HTTP part), (b), (c), (d).
- Security cycle 1: AC18 (a) (the `redactions_for/1` bound and the SQL pin) in `room/redaction_writer_db_test.exs`; AC18 (e) in the
  request-logger suite (`server/test/nebu/web/plugs/request_logger_test.exs` or its existing equivalent); AC18 (f), (h) and AC12 (g),
  (h) in `room/state_writer_redaction_unit_test.exs`; AC10 (d') in `state_writer_http_test.exs`; AC18 (i) in
  `state_writer_redaction_docs_test.exs`; AC9 (e) in the concurrency suite.
- `server/test/nebu/matrix/room/redaction_writer_db_test.exs` (new, `:integration`, `Room.Server` + `Room.DB` directly): AC6, AC13.
- `server/test/nebu/matrix/state_writer_http_test.exs` (new, `:integration`): AC7, AC8, AC10, AC17 (i) (PUT-state half, side by side
  with the `/redact` half in `redaction_http_test.exs`), (k)-(o).
- `server/test/nebu/matrix/state_writer_redaction_concurrency_test.exs` (new, `:integration`, `async: false`, tagged `:concurrency`): AC9.
- `server/test/nebu/matrix/room/state_writer_redaction_unit_test.exs` (new, unit: `Nebu.Matrix.Redaction`, `PowerLevels` `:redact`, the
  fakes): AC4 (e), AC6 (b), AC7 (f), AC12.
- `server/test/nebu/matrix/state_writer_redaction_docs_test.exs` (new): AC14, AC16.
- The D5 room-version guard (`:unsupported_room_version`) is a unit test in `room/state_writer_redaction_unit_test.exs`.
- Re-pinned: the suites of AC15.

## E2E verification

`ui: false` (no Nebu UI code; Element is the client). One new feature `e2e/features/element/room/redaction.feature` with two scenarios,
run on a FRESH, isolated stack built from THIS commit:

- **`@redaction-api @regression`** (the guard, no UI selectors): alex creates a `public` room through the API, marie, tom and kai join;
  marie sends a message M1 and tom a message M2; marie redacts her own M1 with `PUT /redact` (`200`); kai's `/sync` shows M1 with
  `content: {}` and `unsigned.redacted_because` and the redaction with a top-level `redacts`; marie (at 0) redacts tom's M2: `403` "You do
  not have a high enough power level to redact other users' events"; marie's `/send` of `m.room.redaction` with `content.redacts` = M2:
  `403` (the gap of `fw` is closed); alex (100) redacts M2: `200`; `GET /event/{M2}` by kai: `content: {}`; `POST /search` by kai for M2's
  marker word: no result; alex's redaction of the room's `m.room.topic` event: `403` "This event cannot be redacted on this server".
- **`@redaction-ui @regression @ui`**: tom is logged in via Element Web, opens the room, hovers his own message M3, opens its options
  ("Options"), clicks "Remove", confirms with the dialog's "Remove" button; asserted SERVER-side: a redaction of M3 by tom exists (the
  server log shows `PUT .../redact/...` `200`) and kai's `/event/{M3}` has `content: {}`. VERIFIED in the Element 1.12.15 bundle: "Remove"
  (`action|remove`) is offered when `maySendRedactionForEvent` holds (own message at `events_default`), the confirm dialog's button is
  "Remove" with an optional reason field, the request is `PUT /rooms/{roomId}/redact/{eventId}/{txnId}` with `{}` or `{"reason"}`.
  UNVERIFIED: the tile hover / "Options" button selectors of Element 1.12.15 and the dialog's accessible names. If the first real run fails
  for a UI reason (the server log shows no `PUT .../redact/`), tag it `@known-failure` with a new row in `e2e/KNOWN-FAILURES.md` (next free
  K id: **K12** — K8 and K10 are retired paragraphs in `e2e/KNOWN-FAILURES.md`, K11 is reserved by the moderation plan (test review
  STORY-6; the headers of `redaction.feature` / `redaction.steps.ts` name K12); cause: Element message-options selectors unverified) and keep the API scenario as the guard; a server answer other than `200`
  is a finding.

Run (the orchestrator; evidence, not a UI gate): 0. `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000;
`COMPOSE_PROJECT_NAME=nebu-oauth-e2e`. 1. **Run A (CI parity):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh
element`. Pass: every scenario of the default tag expression green (the two new ones, or the UI one moved to the known-failure list)
except the rows of `e2e/KNOWN-FAILURES.md`; then save the server log, count `RequestLogger` lines with status `500` (pass: zero) and with
path `/redact/` (record the statuses: only `200` / the expected `403`s); `docker compose -p nebu-oauth-e2e down -v --remove-orphans`. 2.
Logs: `_bmad-output/nebu/epics/oauth-broker/step-results/state-writer-redaction/e2e-run-a.log` and `e2e-run-a-server.log`; update the
"Status of the last complete run" line of `e2e/KNOWN-FAILURES.md`.

## Tasks

- [x] Migration 000051 (column `events.redacts`, partial index `events_redacts_idx`), up / down (D5).
- [x] `Nebu.Matrix.Redaction` (pure: prune, render) and `Core.Event` `redacts` / `redacted_because` (D5, D6).
- [x] `PowerLevels`: `:redact` in `required_level/2` / `can?/3`, moduledoc (D2).
- [x] `Room.DB`: `insert_event/1` + `redacts`; `apply_redaction/2`, `apply_state_change/3`, `latest_state_identity/3`, `redactions_for/1`;
      the redacted-child exclusion in `fetch_events_by_relation/5` / `count_thread_children/2`; `Search.DB` exclusion (D6, D8, D9).
- [x] `Room.Server`: `redact/5` (D1, D2, D7), `write_state/5` (`:client`, `:tombstone`) (D8, D11); `send_event/6` refuses
      `m.room.redaction` (D1).
- [x] `EventDispatcher.Server`: the redaction handler (both entry points, error mapping, audit) (D2, D3, D12); `set_room_state/2` on the
      writer with the snapshot pre-check, `ensure_room_without_lazy_create!/1` (D8, D10 (a)); createRoom `@` rule (D10 (b)); the prune in
      `event_maps_to_core_events/1`, the leave window, the thread roots (D6); the upgrade pre-check + tombstone via `write_state/5` (D11).
- [x] `protected.ex`: `PUT /client/v3/rooms/:room_id/redact/:event_id/:txn_id` with the D13 checks; `Http` rendering of `redacts` /
      `redacted_because` (D5, D13).
- [x] `AuditWriter.@known_actions`: `room_event_redacted` (D12).
- [x] Tests (Acceptance Tests) incl. the fakes of AC12 (e) and the re-pins of AC15 (Change Log, old -> new).
- [x] Docs AC14 (scope doc, 07-deployment incl. Q-rd checked in a rolled-back transaction, 08-concepts, CHANGELOG, follow-ups).
- [x] E2E feature + steps (staged by ATDD); [ ] run A (orchestrator).
- [x] **Security cycle 1 (Kassandra #1-#5, review M1-M6, I1, I3, I11; AC18, AC2 (k), AC9 (e), AC10 (d'), AC12 (g) / (h), AC13):**
  - [x] #1: idempotent re-redaction in `Room.Server.redact/5` (existing earliest id, no row, no audit, legacy rows do not count) (D2);
        `redactions_for/1` at most one row per target in SQL; index `(redacts, origin_server_ts, event_id)` in 000051 (D5, D6).
  - [x] #5: `/send` txn key `{room, user, {:send, type, txn}}` (D7).
  - [x] #3 / M2: orphan cleanup only for definite refusals; `503` on `:room_unavailable`; comment fixed (D11).
  - [x] #2: search excludes `m.replace` of a redacted original (both statements); docs "edits of a removed message stay served" (D6).
  - [x] #4 / M6: migration header + 07-deployment: rollback re-exposure, SHARE lock / maintenance window / `CONCURRENTLY` pre-create (D5).
  - [x] M1 fail-closed index for the real `Room.DB`; M3 NUL in `content.redacts` -> 400; M4 request logger redact path as content
        body; M5 one prune rule (D3, D6, D13).
  - [x] I1 source test pinning the `write_state/5` callers; I3 reuse the fetched state; I11 stale prose (D15).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (SQL inline
  in `Room.DB` / `Search.DB`; the decisions in `Room.Server` and the pure `Redaction` / `PowerLevels`), ADR-019 / ADR-021 (plain in-process
  modules), ADR-020 (no new cross-domain call; the Admin keeps using `Nebu.Matrix.set_space_state/5`), cluster-safety (one process per
  room via `Horde.Registry`, `:pg.get_members/1` for the new writers' broadcasts, no `:global`, no node-local cache of redaction state:
  it is derived from the database on every read).
- **One writer per kind, one order.** Redactions only through `Room.Server.redact/5`, generic state only through `write_state/5`, power
  levels only through `change_power_levels/4`, membership only through the member writer. The decision reads the CURRENT in-process levels
  and members right before the write. Never `GenServer.call` a room process from inside its own call (the content rules that read other
  rooms stay in the caller, D8).
- **Prune is fail-closed.** A served page is either pruned correctly or a `500`; never serve unpruned content because a lookup failed. Every
  new read path that serves event content (a future `/context`, `fk`) must go through the same prune. **Oracle guardrail:** the same holds
  for the search result `context.events_before` / `events_after` (server.ex about l.7900, empty today) and the `latest_event` of
  `attach_thread_aggregations/3` (about l.8470-8483, computed but not rendered today): when either is ever filled / rendered it MUST go
  through the D6 prune, and a redacted original MUST NOT bundle an `m.replace` aggregation (S6). A source comment at both places and a
  note on `fk` record it.
- **Nothing half done.** Event and `rooms.name` in ONE transaction; ETS, broadcast and audit only after the commit.
- **No sensitive data in logs (LAW).** Log room id, event ids, `db_error_class/1` only; never the reason, never content, never
  `inspect(reason)` of a DB error. The redaction `reason` is user free text: never in a log line, never in the audit row.
- **Fixed texts, explicit errcodes.** Every refusal sets `errcode` (an errcode-less `permission_denied` becomes "You are not a member of
  this room" in `Http.map_error/1`).
- **Element.** Element reads only the top-level `redacts` (verified): without it a live redaction is not applied client-side. "Remove
  recent messages" sends all redactions concurrently: the writer must not serialise them by anything else than the room process (no extra
  locks); each must be decided independently.
- **Compliance.** Do not UPDATE or DELETE the target row. The stored content stays (ADR-023, GDPR runbook); say so in 07-deployment
  ("Remove" hides, it does not erase).
- **Binding notes of the test review (DEV-SIDE, `step-results/state-writer-redaction/test-review-findings.md`):**
  * Every refusal sets `errcode: "M_FORBIDDEN"` explicitly, the forbidden-type refusal included (its text stays "You are not a member of
    this room").
  * The first `room_registry_module().get_state(room)` of a request is its snapshot; the room process re-decides membership, level and
    the `@` rule authoritatively (the gap tests rely on it). The writers are reached only via `room_registry_module().write_state/5` /
    `.redact/5`.
  * Room resolution: `/redact` and `/send` redactions use `lookup_room/1` (`404` "Room not found", no lazy start, no row); PUT state
    and the upgrade use `ensure_room_without_lazy_create!/1` (`403` for an unknown room, no row, no process).
  * `:room_archived`: `/redact` and `/send` -> `400 M_BAD_STATE` "M_ROOM_ARCHIVED: room is archived"; PUT state and the upgrade tombstone
    -> `404 M_NOT_FOUND` "Room not found"; a room call exit -> `503` with the story's texts.
  * `redactions_for/1` goes through the `messages_db_module()` seam (the hook installs it and `rooms_db_module()` too); called once per
    `event_maps_to_core_events/1` call and once for all leave entries of a response; a lookup error raises a handled value-free `500`
    (`db_error_class/1`), never an unpruned page.
  * Logs: room id, event ids, `db_error_class/1` only.
  * After the AC15 (f) allow-list: do not write the literal `m.room.redaction` (also not in comments) outside the allow-listed files;
    `UPDATE events` and `events SET content` stay absent from `server/lib`.
  * The AC15 (d) fake edits come from the ATDD reference diff; real fakes (they write the state and the event), never stubs.
- **Previous story learnings** (power-levels-enforcement, moderation-routes-atomic-ban): real-DB tests for every race and the atomicity;
  deterministic gap tests through db hooks; sessions minted beyond the refresh lookahead (`ModerationTestSupport.user!/1`); `tick/0` only
  in own rooms (`fj`); docs suites pin earlier texts: rewrite `fv` / `fw` / `fx` / `fz` in the CLOSED style keeping the pinned words; the
  e2e on a fresh isolated stack.

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` ("Redactions", `PUT /redact`, `PUT /send` (v1.18
  change), `m.room.power_levels`, "Forming relationships", "Redactions of edited events", `PUT /state`, `#room-upgrades`),
  `rooms/v10/index.html` (authorization rules, "Redactions", "Handling redactions"), `rooms/v11/index.html` ("Moving the redacts property").
- Code: `server/lib/nebu/matrix/event_dispatcher/server.ex` l.160-239, l.3192-3395, l.3946-4243, l.5326-5375, l.7383-7480, l.8150-8202,
  l.8352-8527; `server/lib/nebu/matrix/room/server.ex` l.597-645, l.940-1003, l.1035-1206, l.1269-1294; `server/lib/nebu/matrix/room/db.ex`
  l.438-457, l.488-613, l.1067-1165, l.1770-1800; `server/lib/nebu/matrix/room/power_level.ex` l.18, l.114-132;
  `server/lib/nebu/matrix/search/db.ex` l.13-68; `server/lib/nebu/matrix/http.ex` l.95-112, l.200-216, l.320-354;
  `server/lib/nebu/web/router/protected.ex` l.1422-1591, l.2488-2493, l.3116-3206; `server/lib/pb/core.pb.ex` l.1-21;
  `server/lib/nebu/matrix.ex` l.495-540; `server/priv/migrations/000001_init.up.sql` l.209-239.
- Element 1.12.15 (source maps): matrix-js-sdk `src/client.ts` l.3092-3097, l.3144-3185; `src/models/room.ts` l.2590-2645;
  `src/models/event.ts` l.1227-1250, l.1601-1610; `src/models/room-state.ts` `maySendRedactionForEvent`; element-web
  `MessageContextMenu.tsx` l.180-191, l.439-447; `ConfirmRedactDialog.tsx` l.46-90; `BulkRedactDialog.tsx` l.76-102;
  `utils/createMatrixClient.ts` (no scheduler).
- Stories: `power-levels-enforcement.md` (D1, D2, D5, D10, S2, AC17 (n)), `moderation-routes-atomic-ban.md` (D3, D6, D12).
- Follow-ups: `fw`, `fv`, `fx`, `fz`, `eu`, `en`, `ex`, `fq`, `fp`, `fl`, `ft`, `fe`, `bd`, `fk` in `docs/stories/oauth-broker/follow-ups.md`.
- Conventions: `.claude/rules/matrix-conventions.md` (crash / restart test), `skills/nebu-conventions/cluster-safety/SKILL.md`, ADR-023,
  ADR-030, `docs/compliance/gdpr-deletion-runbook.md`, `docs/architecture/08-concepts.md` "Audit Logging".

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev step, nebu-dev-story, pipeline step 4, cycle 0).

### Debug Log

- Starting point: the throwaway ATDD reference (`scratchpad/atdd/redaction/`, diffs in `scratchpad/atdd/handoff/`), applied and then reviewed piece by
  piece. (Superseded by security cycle 1: the index is `(redacts, origin_server_ts, event_id)`.) Changed against the reference: migration 000051 indexes `(redacts)` ALONE (the reference had `(room_id, redacts)`; the staged AC13 test and
  test review STORY-4 require `(redacts)`: the D6 lookup has no `room_id` predicate), its header and the 07-deployment sentence follow; `Room.DB`
  `apply_redaction/2` / `apply_state_change/3` share ONE private transaction helper (`room_write_transaction/2`; the AC12 (a) AST pin needs the
  `insert_event/1` call inside `apply_redaction/2` itself, a first variant with the insert in the helper was red); `Room.Server` has ONE signer
  (`signed_event/1`, used by `signed_state_event/6` and the redaction; the reference duplicated it) and ONE atomic-commit helper for both writers;
  the upgrade level is `PowerLevels.upgrade_level/1` (one rule for the dispatcher pre-check and the room-process tombstone mode); the served content of
  a redaction event is ONE pure rule (`Redaction.served_content/2`, used by `served/1` and the dispatcher's render of a redaction event in a page);
  `ensure_room_without_lazy_create!/2` takes the 500 of its caller (the generic PUT state no longer answers a status-read failure with the
  power-level text); the initial `/sync` task re-raises a `Nebu.Matrix.Error` of the prune lookup in the caller through a `rescue` clause on the
  existing `try` (no re-indentation of the block); `proto/core.proto` documents `Event.redacts` / `redacted_because` (14 / 15) and
  `RedactEventRequest` / `RedactEventResponse` (the hand-written `core.pb.ex` is the source); outdated comments (SetRoomState header, upgrade header,
  "the permission stays 100", "bypasses Room.Server power check", "the generic path still does: `fz`") rewritten; Oracle guardrail comments at the
  search `events_before` / `events_after` and the thread `latest_event`.
- `server/lib` size: 827 insertions, 93 deletions (920 changed lines, `git diff --numstat`), below the ~1000 stop line.
- **AC17 (m) today's behaviour:** createRoom with `power_level_content_override.users[creator]: 0` plus a `name` / an `initial_state` topic is
  `400 M_INVALID_ROOM_STATE` (the creator lock-out of power-levels-enforcement D7); recorded by the ATDD step as a pin that is green before the dev step
  (`state_writer_http_test.exs` header), not re-run on HEAD in this step; green on this code. No code change for it.
- **Q-rd SQL evidence** (the 07-deployment query verbatim plus a fixture-room predicate, inside `BEGIN ... ROLLBACK` on the throwaway database
  `nebu-oauth-pg`, 2026-10-20): fixtures in one new room `!qrd-fixture:test.local`: a message `$qrd-message`, a LEGACY redaction `$qrd-legacy`
  (`content.redacts` = the message, column NULL), a writer-made redaction `$qrd-writer` (column = the message). Listed: exactly `$qrd-legacy`
  (1 row, `origin_server_ts` 2); after the ROLLBACK the fixture room has 0 events. The staged docs test runs the same SQL against its own fixtures.
- Runs (`MIX_BUILD_PATH=/tmp/nebu_build` in a named build volume, `--warnings-as-errors`):
  * Elixir 1.20.4: `mix compile` clean; the 6 new suites 292 tests green (one red AC12 (a) pin fixed, see above); the AC15 suites, the fake suites
    and all docs suites green.
  * no-DB `mix test` (the `test-unit-elixir` job): 6333 tests, 0 failures.
  * `mix test --include integration` on a FRESH throwaway database (own network, migrated 000001-000051, `regression_sync_load_test.exs` moved aside
    and restored): 10226 tests, 25 failures, all in known flaky / environment families: RoomsFallbackName 12, TemporaryCaptureManager 3,
    TraceMapNodeControls 3, AdminOidcLogin 3, LogStore.Retention 2, WarRoom 1, AdminStaleRooms 1, Media ClamAV 1. Each file re-run in isolation and on
    a `git archive` copy of HEAD `b651fee8` against the same database: AdminStaleRooms and ClamAV green (flakes); RoomsFallbackName 12,
    TemporaryCaptureManager 2, TraceMapNodeControls 3, AdminOidcLogin 3, LogStore.Retention 2, WarRoom 1 fail IDENTICALLY on HEAD: pre-existing, not
    caused by this story. An earlier run on the REUSED database additionally had MatrixClientCompat 4 (missing derived `m.room.canonical_alias`: "exhausted
    alias-collision retries", leftovers of the reused database), EventSizeLimitHttp AC11 (c) (same cause), SsoLogin 1, MatrixSso 1 and the then
    not yet re-pinned `create_room_initial_state_http_test` AC4 (re-pinned, AC15 (e)); none of them failed on the fresh database.
  * Elixir 1.19 (`elixir:1.19-alpine`): `mix compile --force --warnings-as-errors` without a warning in `lib/` (dependency warnings only); the new and
    changed suites (25 files): 928 tests, 0 failures.
  * Test-name length (`namelen.py`, > 240): none.

### Completion Notes List

- Migration 000051 (`events.redacts TEXT`, nullable, no default, no backfill; partial index `events_redacts_idx ON events (redacts) WHERE redacts IS
  NOT NULL`; down drops both). (Superseded by security cycle 1: `(redacts, origin_server_ts, event_id)`.) No grant (table-level grants cover the column), no RLS on `events`.
- `Nebu.Matrix.Redaction` (pure): `index/1`, `served/1`, `served_content/2`, `prune/2`, `content_map/1`. `Core.Event` `redacts` / `redacted_because`;
  `Http.timeline_event_json/2` and `message_event/1` render the top-level `redacts` and `unsigned.redacted_because` (absent when empty, never null).
- `PowerLevels`: `:redact` in `required_level/2` / `can?/3`, `upgrade_level/1` (D11), the moduledoc sentence "Not evaluated anywhere ... `redact`" gone.
- `Room.DB`: `insert_event/1` writes `redacts` (NULL for every other event); `apply_redaction/2`, `apply_state_change/3` (`room_name:`), ONE
  transaction each (lock timeout, `FOR NO KEY UPDATE` archived check, never raising); `latest_state_identity/3`; `redactions_for/1` (one statement,
  oldest first, six string keys); `fetch_events_by_relation/5` and `count_thread_children/2` exclude redacted children; `Search.DB` both statements
  exclude redacted events (`NOT EXISTS`).
- `Room.Server`: `redact/5` (D2 order: membership, the redaction-event level, idempotency, ONE target read, `redact` for another sender, the
  version-keyed `redaction_event/6`, size backstop, `apply_redaction/2`; ETS and broadcast after the commit, `:pg.get_members/1`; answer
  `{:ok, event_id, %{replayed, target_sender}}`); `write_state/5` (`:client` / `:tombstone`, the `@` rule, the slot stamp from the database,
  `apply_state_change/3`, broadcast after the commit; `{:ok, event_id}`); `send_event/6` refuses the redaction type (`{:error, :forbidden}`). Both
  writers refuse a db module without their functions (`:unsupported_db_module`); failures are value-free logged (room id, `db_error_class/1`).
- `EventDispatcher.Server`: `redact_event/2` (PUT /redact, key `{room, user, {:redact, event_id, txn_id}}`) and the `send_event/2` clause for the
  redaction type (`content.redacts` required and moved to the top level, the `/send` key), both via `lookup_room/1` (404, no lazy start) and
  `room_registry_module().redact/5`; refusal mapping with explicit errcodes (archived `400 M_BAD_STATE`, exit `503`); audit `room_event_redacted` only
  for a committed redaction of another user's event (best effort). `set_room_state/2`: allowlist refusal with `M_FORBIDDEN` (text unchanged),
  `ensure_room_without_lazy_create!/2` (`fz`), the snapshot pre-check (membership, level, `@` rule) before the content rules, then
  `room_registry_module().write_state/5`; archived `404`, exit `503`, write failure the generic `500` (the `inspect(reason)` text is gone).
  createRoom: the `@` rule on every `initial_state` entry (`400 M_INVALID_ROOM_STATE`), after the size rule. Prune on read: `event_maps_to_core_events/1`
  (one batch per call), the leave window (one batch for all leave entries), the thread roots; fail closed (`500`, value-free ERROR), the initial
  `/sync` task hands the error back to the caller. Upgrade: snapshot pre-check `upgrade_level/1` with the new `403` text; the tombstone through
  `room_registry_module().write_state/5` `mode: :tombstone` (a refusal stops and cleans up the started new room before anything is frozen).
- Router: `PUT /client/v3/rooms/:room_id/redact/:event_id/:txn_id` with the D13 checks (no rate tier).
- `AuditWriter.@known_actions` + `room_event_redacted`.
- Docs: scope doc (the `/redact` row ✅ and the labels of AC16, `/send`, the PUT state rows, createRoom, upgrade, read rows, `/search`), 07-deployment
  (the paragraph, Q-rd, migration), 08-concepts (the audit action), CHANGELOG (`Added`, `⚠ Changed`), follow-ups (`fw`, `fv`, `fz`, `fx` CLOSED keeping
  the pinned words; notes on `eu`, `en`, `fp`, `fl`, `ft`, `fe`, `bd`, `fk`; new rows `ga`-`gd`; the id line "unused ... `ge` onward").
- **AC12 (e) grep list of fakes.** `grep -rln "room_registry_module" server/test` (13 files): the suites that reach the new writers implement them with
  REAL fakes: `event_dispatcher/set_room_state_test.exs` and `space_edit_audit_test.exs` (`write_state/5` writes the event and, for `m.room.name` with
  the empty key, `rooms.name`; a failing write removes the event again: one transaction), `redaction_test_support.exs` / `state_writer_http_test.exs`
  (staged), `room/state_writer_redaction_unit_test.exs` (staged). `handler_test`, `join_room_test`, `send_event_test`, `sync_test`,
  `thread_relations_test`, `room_summary_test`, `get_room_state_lazy_restart_test`, `power_levels_test_support`, `room/power_levels_writer_db_test` do
  not reach `write_state/5` / `redact/5` (green unchanged). Db fakes (`:room_manager, :db_module`) reaching the tombstone: `upgrade_room_test.exs` (2 fakes)
  and `upgrade_room_error_handling_test.exs` (4 fakes) gain `apply_state_change/3` (writes through the fake's `insert_event/1`) and
  `latest_state_identity/3` (`{:ok, nil}`: these fakes keep no slot index, the stamp then has no floor); `apply_redaction/2` only in the staged
  fakes. Messages-db fakes without `redactions_for/1` (or without a Repo) serve pages unpruned (the seam of the predecessor batch; production always
  has it). Checked and unchanged: `event_size_backstop_test.exs`, `matrix_client_compat_test.exs`, `spaces_state_events_integration_test.exs` (green).
- **AC15 re-pins by the dev (old -> new; the ATDD re-pins (a)-(c), (f) were staged before this step and are unchanged):**
  * (d) `event_dispatcher/set_room_state_test.exs`: FakeRoomRegistry + `write_state/5` (real, see above), FakeDB + `get_room_status/1` (a registered
    room is known and active). Test "AC12 - a failing rooms.name write logs room id and error class only": OLD `{:ok, %SetRoomStateResponse{}}` ("the
    denormalisation failure stays non-fatal") + `log =~ room id` + `log =~ "postgres 22P05"` + `refute log =~ marker` -> NEW `{:error, {500, _, _}}` +
    no `m.room.name` event in the fake + `rooms.name` unchanged + `refute log =~ marker` (D8: one transaction); the room-id / SQLSTATE-class log
    assertions are covered on the real database by `state_writer_http_test.exs` AC7 (e). The other 41 tests unchanged.
  * (d) `space_edit_audit_test.exs`: FakeRoomRegistry + `write_state/5` (real); FakeDB `get_room_status/1` OLD always `{:error, :not_found}` -> NEW
    `{:ok, "active"}` for a room of the fake registry (D10 (a): PUT state needs a known room). Assertions unchanged.
  * (d) `event_dispatcher/upgrade_room_test.exs`, `upgrade_room_error_handling_test.exs`: the db fakes gain `apply_state_change/3` /
    `latest_state_identity/3` (above); assertions unchanged (no test pinned the old errcode-less upgrade text).
  * (e) `event_dispatcher/create_room_initial_state_test.exs`: "initial_state cannot forge m.room.member or m.room.create": OLD a foreign member entry
    in the list (skipped, `refute` a forged member) -> NEW the entry moved to a new test "an initial_state m.room.member entry for another user is
    refused before the room exists" (`Nebu.Matrix.Error`, message "The initial state contains a state key of another user", errcode
    `M_INVALID_ROOM_STATE`); the old test keeps every other assertion (incl. the `refute` of a forged member).
  * (e) `create_room_initial_state_http_test.exs` AC4 "... and a foreign m.room.member are skipped; a plain entry applies": OLD the foreign member entry
    skipped, `200` -> NEW the skipped member entry is the creator's OWN (`leave`, skipped: one member event, `join`), every other assertion unchanged;
    plus a new test "a foreign m.room.member entry is 400 M_INVALID_ROOM_STATE and no room is created (it was skipped)" (exact body, `room_count`
    unchanged).

- **Security cycle 1 (dev fix cycle 1, 2026-10-20; Kassandra #1-#5, code review M1-M6, I1, I3, I11):**
  * #1 HIGH: `Room.Server.redact/5` answers a target that already has a writer-made redaction with the EARLIEST one (`replayed: true`,
    no row, no ETS entry under the new key, no broadcast, no audit; after membership, level, target and `redact`; read through
    `redactions_for([target])`, a failing read `:write_failed`, a db module without it `:unsupported_db_module`; legacy rows do not
    count). `Room.DB.redactions_for/1`: `DISTINCT ON (redacts) ... ORDER BY redacts, origin_server_ts, event_id` UNION the redaction
    events among the ids: at most one row per target in SQL. Migration 000051 (edited in place, not committed before): index
    `(redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL`; the throwaway `nebu-oauth-pg` was recreated.
  * #5: the `/send` txn key is `Room.Server.send_txn_key/4` = `{room, user, {:send, event_type, txn}}` (lookup and insert in
    `send_event/6`, the dispatcher's `/send` redaction); the only other reader/writer of `NebuTxnDedup` is the `/redact` key.
  * #3 / M2: `cleanup_orphan_room` only for `@definite_tombstone_refusals` (`:insufficient_level`, `:sender_not_joined`,
    `:foreign_user_key`, `:room_archived`, `:write_failed`, `:event_too_large`, plus `:unsupported_db_module`: nothing written
    there either); `:room_unavailable` keeps the new room, `503` (the staged test pins the existing state-writer text "The room did not
    answer, the change may or may not have been applied", not the story's "the upgrade may ..."); the false comment replaced.
  * #2: both search statements exclude an `m.replace` whose original is redacted (`COALESCE(rel_type, '') = 'm.replace' AND EXISTS ...`,
    COALESCE so a missing `rel_type` never turns the predicate NULL); docs "edits of a removed message stay served"; cascade / MSC3912
    as a note on `ga`.
  * #4 / M6: migration header + 07-deployment: SHARE lock / maintenance window / `CONCURRENTLY` pre-create; rollback re-exposure (also
    the down file header); CHANGELOG operator sentence.
  * M1: `redaction_index/1` raises the handled 500 for `Nebu.Matrix.Room.DB` without Repo / function (nil only for a test module).
    M3: `/send` redaction: NUL in `content.redacts` -> `400 M_BAD_JSON` "content must not contain NUL characters"; the rest of
    the content gets the `/redact` body rules (NUL, `reason` string / 1024 bytes). M4: request logger `@redact_event_path_regex` as a
    content body. M5: the dispatcher's `prune_event/2` calls `Nebu.Matrix.Redaction.prune/2` (the ATDD keeps `prune/2` and its test).
  * D15: I1 pinned by the staged AC12 (f) source test (no code change); I3 `ensure_room_without_lazy_create!/2` returns
    `{:started, state}` / `:running`, `set_room_state/2` reuses the started state; I11 the upgrade header / step-1 comments.
  * Re-pins in this cycle: none by the dev (the key-shape re-pins in `nebu_room_test`, `send_event_archived_room_test`,
    `power_level_enforcement_test`, `event_size_backstop_test`, `power_levels_unit_test` D5 (d) and the rewritten AC2 (k) / AC9 (e)
    were staged by the ATDD agent; unchanged here).
  * Not pinned by the staged tests (reported): AC18 (h) (one `get_state/1` on the stopped-room path) and AC18 (i) (the docs sentences)
    have no test in the staged suites; implemented and documented anyway.
  * Runs: the 23 red tests (12 files, 510 tests) green; 1.20 compile clean; no-DB `mix test` 6339 / 0 failures; full integration on a
    FRESH throwaway DB (load test moved aside and restored): 10245 tests, 22 failures, all known families (RoomsFallbackName 12,
    AdminOidcLogin 3, TraceMapNodeControls 2, TemporaryCapture 2, LogStore.Retention 2, AdminStaleRooms 1); in isolation on the
    worktree and on the `git archive` HEAD copy: RoomsFallbackName, TraceMapNodeControls, TemporaryCapture, Retention fail identically
    on HEAD (pre-existing); AdminOidcLogin and AdminStaleRooms fail intermittently on HEAD too (flaky). 1.19: compile without `lib/`
    warnings, the new + changed files 1146 tests, 0 failures. Names: none above 240 (none of this story's above 230). `server/lib`
    vs HEAD now 941 + / 105 - (1046 changed lines; this cycle 148 + / 46 -).

- **Security cycle 2 (dev fix cycle 2, 2026-10-20; delta reviews: security CLEAN, code review 0 MAJOR / 7 MINOR):**
  * Story text: the upgrade 503 text ("... the change may or may not have been applied"), seven definite refusals incl.
    `:unsupported_db_module` (D11, AC10 (d')); D2 / AC2 (k): nothing remembered under the new txn key; AC18 (a) numbers aligned with the
    tests (5 sequential with 1 KB, 10 concurrent, a 30-row DB bound with 2 KB); D5 lock note corrected; superseded markers on the cycle-0
    index notes and in the `bd` row.
  * M4 lock wording (000051 header, 07-deployment, CHANGELOG): the ALTER TABLE holds ACCESS EXCLUSIVE to the commit (reads and writes
    wait); explicit pre-create recipe (column by hand, then `CREATE INDEX CONCURRENTLY`, run the migration with no long transaction
    open); INFO 7: rolling back only the application image re-exposes too.
  * M5 request logger: the three content-body regexes are matched against `normalized_path/1`. M6 stale comments (protected.ex upgrade
    route, upgrade_room_test header). Kassandra INFO 10: neutral NUL text "content must not contain NUL characters" for `/send`
    redactions. INFO 2: `not_before:` of `write_state/5` kept (pinned by the unit suite).
  * Dev-added tests: `redaction_cycle2_test.exs` (integration: `:write_failed` / `:event_too_large` / `:unsupported_db_module` tombstone
    refusals clean up the new room; unit: the stopped-room PUT-state path calls `get_state/1` once, AC18 (h)); request-logger cases
    (trailing slash and `//` for redact, send, state); four docs pins for AC18 (i) and the migration header; M7: the EXPLAIN copy is
    kept for the plan, plus a source pin that `@sql_redactions_for` in `db.ex` has `DISTINCT ON (redacts)` and `ORDER BY redacts,
    origin_server_ts, event_id`; its stale comment fixed. No existing assertion changed.
  * Runs: the changed / new suites and all docs suites 1247 tests, 0 failures (1.20 and 1.19, `--warnings-as-errors`, no `lib/`
    warnings); no-DB `mix test` 6350 / 0; ONE fresh-DB integration run (load test moved aside and restored): 10260 tests, 23 failures,
    all in the known families classified in cycles 0 / 1 (RoomsFallbackName 12, AdminOidcLogin 3, TemporaryCapture 3,
    TraceMapNodeControls 2, WarRoom 1, LogStore.Retention 1, SsoLogin 1). `server/lib` vs HEAD: 949 + / 108 -.

### File List

- `server/priv/migrations/000051_events_redacts.up.sql`, `000051_events_redacts.down.sql` (new)
- `server/lib/nebu/matrix/redaction.ex` (new); `server/lib/nebu/matrix/event_dispatcher/server.ex`, `room/server.ex`, `room/db.ex`, `room/power_level.ex`,
  `search/db.ex`, `http.ex`; `server/lib/nebu/web/router/protected.ex`; `server/lib/nebu/compliance/audit_writer.ex`; `server/lib/pb/core.pb.ex`
- `proto/core.proto`
- `server/test/nebu/matrix/event_dispatcher/set_room_state_test.exs`, `space_edit_audit_test.exs`, `event_dispatcher/upgrade_room_test.exs`,
  `event_dispatcher/upgrade_room_error_handling_test.exs`, `event_dispatcher/create_room_initial_state_test.exs`,
  `create_room_initial_state_http_test.exs` (AC15 (d) / (e) re-pins)
- `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/08-concepts.md`, `docs/stories/oauth-broker/follow-ups.md`,
  `CHANGELOG.md`, this story
- Staged by ATDD (unchanged here): the new suites, `redaction_test_support.exs`, the re-pinned docs / power-levels / member-prev-content /
  state-predecessors / unrecognized-routes suites, `test_helper.exs`, `mix.exs`, `e2e/features/element/room/redaction.feature` + steps

### Change Log

- 2026-10-20: story created (create-story, read-only premise check on HEAD `b651fee8`; Element 1.12.15 redaction path verified in the
  source maps of a local 1.12.15 bundle, nothing run); status ready. Scope: `fw`, `fv`, `fz`, `fx` (floor 100 labelled) in one story; new
  follow-up ids `ga`-`gd`, unused from `ge` onward. **Re-pin needed (test agent): "`ga` onward" -> "`ge` onward" in the nine docs suites
  of AC15 (a).**
- 2026-10-20: Oracle gate applied (`step-results/state-writer-redaction/oracle-context.md`: S1-S8 OK, no WRONG decision). Labels: D2
  idempotency after authorisation (a retry after a demotion / kick is `403`, refusals never cached); D8 PUT state on an archived room `404
  M_NOT_FOUND` (Nebu choice) and the kept inconsistency with `/redact` / `/send` `400 M_BAD_STATE` (each path keeps its sibling's answer);
  D2 `/redact` unknown room `404` as `/send` (existence oracle); D10 (b) the `@` rule on every `initial_state` entry incl. `m.room.member`
  = stricter Nebu rule (a member entry for another user is now `400`, was skipped); D7 per-user txn scope (`bd`); D5 earliest
  `redacted_because` = Nebu choice. Decisions: `/redact` on a known stopped room = `404` as `/send`, no lazy row; Q9 legacy unchecked
  redaction rows are served without `content.redacts` and without top-level `redacts` (`gd`); D5 room-version guard (only v10 stores the
  top-level shape); guardrail: search `context.events_before` / `events_after` and the thread `latest_event` go through the D6 prune and a
  redacted original bundles no `m.replace` (note on `fk`). New AC16 (labels) and AC17 (a)-(r) (the 18 missing tests) with their test-file
  assignment. Follow-up ids unchanged: `ga`-`gd`, unused `ge` onward.
- 2026-10-20: test review applied (`step-results/state-writer-redaction/test-review-findings.md`, STORY-1..11 + DEV-SIDE notes):
  STORY-1 AC15 (f) the three broken existing tests (`state_predecessors_db_test` AC1 (m) allow-list, `member_prev_content_http_test`
  baseline 45 -> 48, `unrecognized_routes_test` redact route moves to routed); STORY-2 AC15 (d) / (e) the fake-suite edits named
  (`set_room_state_test` 42 incl. the non-fatal `rooms.name` test -> `500`, `space_edit_audit_test` 16, `upgrade_room_test` 18,
  `upgrade_room_error_handling_test` 3, `create_room_initial_state_test` / `_http_test` AC4); STORY-3 D6 / AC5 (f) the lookup granularity
  (one per `event_maps_to_core_events/1` call = per joined room, one for all leave entries); STORY-4 D5 index `events_redacts_idx` on
  `(redacts) WHERE redacts IS NOT NULL`; STORY-5 migration files `000051_events_redacts.up.sql` / `.down.sql`; STORY-6 e2e fallback id
  K12 (not K10); STORY-7 AC10 (e) archived old room = `404 M_NOT_FOUND`; STORY-8 AC7 (g) forbidden-type text kept with explicit
  `M_FORBIDDEN`; STORY-9 AC5 (g) handled `500`, no process crash; STORY-10 AC17 (s) path NUL / non-UTF-8 room id, AC17 (t) all three
  `/relations` routes (D14 note); STORY-11 AC12 (e) mandatory `room_registry_module()` seams, AC12 (f) `:pg.get_members/1` pin; test
  review M-1 / M-5 / M-6 as AC17 (u)-(w); M-17 the extra docs tokens listed in AC16 (the tests keep them, nothing loosened); DEV-SIDE
  notes in Dev Notes. **ATDD-chosen names / return shapes (binding):** `Room.Server.redaction_event/6` (the version-keyed builder of
  D5), `Nebu.Matrix.Redaction.prune/2` + `served/1`, `Room.DB.latest_state_identity/3` -> `{:ok, {event_id, ts, sender} | nil}`,
  `Room.DB.apply_state_change/3` with the opt `room_name:`, `Room.DB.redactions_for/1` -> `{:ok, rows}` ordered by `(origin_server_ts,
  event_id)` with six string keys, `Room.Server.redact/5` -> `{:ok, event_id, %{replayed: boolean, target_sender: String.t()}}`,
  `Room.Server.write_state/5` -> `{:ok, event_id}`.
- 2026-10-20: dev step (cycle 0): implementation as in the Completion Notes; AC15 (d) / (e) re-pins logged there (old -> new); status review.
- 2026-10-20: security cycle 1 (Kassandra cycle 0 `security-reports/state-writer-redaction-security-review-2026-10-20.md`: HIGH #1,
  MEDIUM #2, LOW #3-#5; code review cycle 0 M1-M6, I1, I3, I11). Decisions: D2 a redaction of an already redacted target is idempotent
  (`200` with the existing earliest redaction's id, no row, no audit, no broadcast; authorisation still first; legacy rows do not count;
  AC2 (k) rewritten, AC9 (e) one row); D6 `redactions_for/1` returns at most ONE row per target in SQL (earliest by `(origin_server_ts,
  event_id)`), D5 index `events_redacts_idx` on `(redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL`, D13 body keys kept
  (bounded by one row per target); D7 `/send` txn key `{room, user, {:send, type, txn}}`; D11 orphan cleanup only for definite refusals,
  `503` "may or may not have been applied" on `:room_unavailable`, retry `/upgrade`; D6 search excludes `m.replace` edits of a redacted
  original, edits otherwise stay served (documented; cascade / MSC3912 as a note on `ga`, no new id); D5 operator notes: rollback of
  000051 = re-exposure (down step not refused), the index build's SHARE lock (maintenance window or `CONCURRENTLY` pre-create); D6 one
  prune rule (M5) and a fail-closed index for the real `Room.DB` (M1); D3 NUL in `content.redacts` -> `400` (M3) and the `/redact` body
  checks for `/send` redactions; D13 request logger treats the redact path as a content body (M4); D15 source test for the
  `write_state/5` callers (I1), state reuse (I3), stale prose (I11). New AC10 (d'), AC12 (g) / (h), AC18 (a)-(i); AC13 index
  definition. Follow-up ids unchanged: `ga`-`gd`, unused `ge` onward; front-matter status unchanged (the orchestrator sets it for the dev fix cycle).
- 2026-10-20: dev fix cycle 1 (security cycle 1): implemented as in the Completion Notes "Security cycle 1"; no dev re-pins.
- 2026-10-20: dev fix cycle 2 (security cycle 2): story text, lock wording, request-logger normalisation, dev-added tests (see Completion Notes).
