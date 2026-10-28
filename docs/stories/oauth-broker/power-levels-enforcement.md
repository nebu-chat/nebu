---
story_id: power-levels-enforcement
title: "Power levels: PUT /rooms/{roomId}/state/m.room.power_levels with the room-version-10 change rules, ONE room-process power-level writer (one transaction: column + event), enforcement of the per-type events map for message and state events, an initial_state m.room.power_levels entry applied at createRoom step 6, power levels carried by room upgrade: closes eq, er, fr"
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

# Story: power levels can be changed, are enforced per event type and survive createRoom / upgrade (follow-ups `eq`, `er`, `fr`)

As a room administrator using Element (Room settings > Roles & Permissions, or the composer commands `/op` / `/deop`), I want to change
power levels after the room was created, and I want the levels the room shows (`events` per event type) to be the levels the server
enforces, so that I can promote a moderator, restrict who may change the topic, and demote someone again.
As a Nebu operator, I want every power-level change to follow the Matrix room-version-10 authorization rules (nobody can grant more than
he has, nobody can change a level at or above his own, only integers are stored), to be decided and written inside the room process in
ONE transaction, serialised with kick / ban / send, and audited, so that a power-level write can never be a privilege escalation.

Follows `create-room-presets-power-levels-topic` (D7 override validation, D8 the skipped `initial_state` entry = `er`, the creator
lock-out with spec semantics), `create-room-invites-direct` (D9: `trusted_private_chat` equal levels), `event-size-limit` (D6 (b): the
levels event passes `EventSize`; the note on `eq`), `member-event-prev-content` (generic state predecessors) and
`moderation-routes-atomic-ban` (the room-process writer pattern of `moderate/6`, D13: what was taken from `eq`; the Oracle binding note
on `fr`). Closes `eq`, `er`, `fr`. **This is story 1 of 2** (split: see "Sizing and split").

## Premises verified (2026-10-20, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `07c831f7`, read-only)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise (from the request) | Verified text | Verdict |
|---|---|---|---|
| S1 | `events[type]` overrides per type, for message AND state events | `client-server-api` `m.room.power_levels`: "Except for membership events and redactions, the level required to send a certain event is governed purely by `events`, `state_default` and `events_default`. If an event type is specified in `events`, then the user must have at least the level specified ... If the event type is not supplied, it defaults to `events_default` for message events and `state_default` for state events." Defaults: `state_default` 50, `events_default` 0, `invite` 0, `kick` / `ban` / `redact` 50, `users_default` 0; no PL event: creator 100, others 0. Range `[-(2**53)+1, (2**53)-1]`. | CORRECT. D5. |
| S2 | `redact` must be evaluated | Same section: "For redactions of a user's own events, the required power level is determined by the `m.room.redaction` event power level, as per `events` and `events_default`. The power level required to redact an event sent by another user is additionally governed by `redact`." `rooms/v10`: "`m.room.redaction` events are subject to auth rules in the same way as any other event ... In particular, the `redact` level is not considered by the auth rules"; it is applied when the server performs the redaction ("Handling redactions"). | `redact` only matters for PERFORMING a redaction. Nebu has **no redaction route** (`PUT /rooms/{roomId}/redact/{eventId}/{txnId}` is unrouted, grep: no `redact` route in `protected.ex`, no redaction code in `server/lib`; only `log_store/route_normalizer.ex` l.40 knows the path). **Oracle correction:** an `m.room.redaction` sent through `/send` is NOT harmless. Nebu stores it as it is (no `redacts` check, no redaction applied) and DELIVERS it to every member; the client section says "When a client receives an m.room.redaction event, it SHOULD change the affected event" (v1.18: servers MUST accept redactions on `/send` and, below v11, move `content.redacts` to the top level; Nebu advertises at most v1.15, so that MUST does not bind yet). Whether Element 1.12.15 applies `content.redacts` in a v10 room is UNVERIFIABLE in the bundle. **Risk:** a user at `events_default` may visually redact other users' messages in clients without the `redact` level. This story gates the event only by `events["m.room.redaction"]` / `events_default` (D5) and PINS the behaviour (stored as-is + delivered, AC17 (n)); no redaction enforcement here. `redact` stays stored / validated, not evaluated: follow-up `fw`, raised in priority. |
| S3 | `notifications` must be evaluated | `notifications.room`: "The level required to trigger an @room notification. Defaults to 50"; it is read by the push rule condition `sender_notification_permission` (push rules module). | Nebu has **no server-side push processing** (`protected.ex` l.596: "Nebu has no server-side push processing", `GET /pushrules/` is a static body l.599-611; push-rule writes unrouted, follow-up `ad`). Nothing on the server evaluates `@room`; clients do. Decision D6: validated, stored, delivered, NOT evaluated (documented; a note on `ad`). |
| S4 | PUT state m.room.power_levels route + v10 rules | `PUT /rooms/{roomId}/state/{eventType}/{stateKey}`: responses `200 {event_id}`, `400` "The sender's request is malformed", `403` "The sender doesn't have permission to send the event into the room"; "Rate-limited: No". `rooms/v10` m.room.power_levels: (1) `users_default`, `events_default`, `state_default`, `ban`, `redact`, `kick`, `invite` present and not an integer -> reject; (2) `events` / `notifications` present and not an object of integers -> reject; (3) `users` not an object with keys that are valid user IDs and integer values -> reject; (4) no previous PL event -> allow; (5) for each of the seven keys added / changed / removed: current value > sender's level -> reject, new value > sender's level -> reject; (6) `events` / `notifications` entries changed or removed: current > sender -> reject; added or changed: new > sender -> reject; (7) `users` entries changed or removed OTHER THAN THE SENDER'S OWN: current >= sender -> reject; added or changed: new > sender -> reject; (8) otherwise allow. Before that, the generic rules: the sender's membership must be `join`; "If the event type's required power level is greater than the sender's power level, reject"; "If the event has a `state_key` that starts with an `@` and does not match the sender, reject." | CORRECT, plus two findings the request did not name: the generic `@`-state-key rule (applies to EVERY state event, D5 (c)) and the self-entry exemption of rule (7) (a sender may LOWER or remove his own entry, never raise it above his level). D2, D3. "Rate-limited: No": the tier of D9 is a labelled divergence. |
| S5 | v10 integers: a string level must never pass | `rooms/v10` "Values in m.room.power_levels events must be integers ... power levels MUST NOT be represented as strings within this room version". | CORRECT. In Erlang term order every binary is greater than every integer: today `PowerLevels.get_user_level/2` (power_level.ex l.30-33) returns a stored `"100"` unchanged, so `can?/3` (l.45-50) compares `"100" >= 50` = `true` for EVERY action (a string USER level passes everything), and a string THRESHOLD is never reached (`50 >= "0"` = `false`). Reachable only through stored legacy content (all current writers validate integers or write literals). D4 (tolerant read), D3 (strict write). |
| S6 | `initial_state` m.room.power_levels replaces at step 6 | createRoom: "The server MUST apply the normal state resolution rules when creating the new room, including checking power levels for each event. It MUST apply the events implied by the request in the following order: ... 3. A default `m.room.power_levels` event. Overridden by the `power_level_content_override` parameter ... 5. Events set by the preset ... 6. Events listed in `initial_state`, in the order that they are listed. 7. name and topic ... 8. Invite events". | CORRECT: an entry is a full replacement (a new state event in the slot, no merge), and "checking power levels for each event" means the entry is a v10 power-level CHANGE by the creator against the step-3 levels (rules (5)-(7) of S4 apply: there is a previous PL event). D7. |
| S7 | upgrade: power levels recommended, lower the old room's levels | `#room-upgrades` server behaviour: "the recommended state events to transfer are: ... `m.room.join_rules`, `m.room.power_levels`"; "If possible, the power levels in the old room should also be modified to prevent sending of events and inviting new users. For example, setting `events_default` and `invite` to the greater of `50` and `users_default + 1`." First step: "Checks that the user has permission to send `m.room.tombstone` events in the room." | CORRECT. D8: carried (after the bans, the Oracle binding note of `fr`). The lowering is NOT done: the old room is archived and its process stopped by the freeze of moderation-routes-atomic-ban (no event can be sent there at all, a stronger effect than lowered levels): labelled deviation from an "If possible ... should". The permission check stays `users[requester] >= 100` (not the tombstone level): new follow-up `fx`. |
| S8 | upgrade copy: bans before a copied `users` map | Oracle binding note in `fr` (moderation-routes-atomic-ban): "the bans must still be issued BEFORE a copied `users` map could raise a banned user to a level >= the upgrader's 100". v10 ban rule: target level strictly lower than the sender's. | CORRECT, D8: initial levels (defaults + upgrader at his old level) -> the bans -> the copy as a v10 change by the upgrader. |

### What Nebu does today (code)

| Question | Verified state |
|---|---|
| `PowerLevels` | `server/lib/nebu/matrix/room/power_level.ex` (66 lines): `default_levels/0` (`events: %{}`, `users: %{}`, ban / kick / redact / state_default 50, invite / events_default / users_default 0), `get_user_level/2` (raw value, no type check), `can?/3` with `:send_event` (`events_default`), `:invite`, `:kick`, `:ban`, `:change_state` (`state_default`): **the `events` map, `redact`, `notifications` are never read** (`eq` verified). |
| The send path | `EventDispatcher.Server.send_event/2` (server.ex l.160-228): the MEMBERSHIP check runs in the CALLER on a `get_state` snapshot (l.191-197), then `Room.Server.send_event/6` (room/server.ex l.587-632) checks `can?(.., :send_event | :change_state)` IN the process (l.598-601). The process does NOT re-check membership: a send decided on a snapshot just before a kick / ban can still be written after it (same class as `ex`; D5 (d) closes it, it is one `MapSet.member?/2`). `/send` is always a message event (`is_state_event: false`, protected.ex l.1582), every `event_type` accepted, `m.room.redaction` included. |
| The PUT state path | `protected.ex` l.2486-2492 -> `do_set_room_state/4` (l.3111-3179: E2EE 403, JSON, NUL, UTF-8, key sizes, depth, NUL content, the envelope size pre-check) -> `EventDispatcher.Server.set_room_state/2` (l.3962-4048): allowlist `@writable_state_types` (l.3950-3960, `m.room.power_levels` NOT on it: 403 raised WITHOUT errcode, so `Http.map_error/1` answers the misleading fixed text "You are not a member of this room", the finding of moderation-routes-atomic-ban S-table), membership + `can?(.., :change_state)` on a `fetch_room_state/1` snapshot (l.3985-3999: `state_default` only, `events[type]` ignored), content rules, then `emit_state_event/5` -> `emit_state_event_at/6` (l.7873-7930) **signs and inserts in the CALLER** (not in the room process, stamped `max(now, not_before)`). No `@`-state-key rule. No rate tier (`fp`). |
| The power-level writer | `Room.Server.set_power_levels/3` (room/server.ex l.211-214) -> `handle_call({:set_power_levels, ..})` (l.552-576): allowed when `state.power_levels == %{}` (**bootstrap: ANY caller**) or `can?(.., :change_state)` (`state_default`, no change rules at all: a caller at 50 may set anybody to any value, strings included); `EventSize.check/2` (l.564-572); `apply_power_levels/4` (l.1019-1049) writes the `rooms.power_levels_json` column FIRST and then `emit_power_levels_event/3` (l.1062-1092): **two non-transactional writes** (the event write is non-fatal: the column and the in-memory levels change without an event, `power_levels_event: nil`), stamped `now_ms()` (no `latest + 1`), broadcast through `:pg.get_local_members/1` (node-local), log line `inspect(reason)`. No shape validation. |
| Callers of the writer | `create_room/2` step 3 (server.ex l.436-456, the merged override, via the bootstrap branch), `upgrade_room/2` (l.7336-7345: DEFAULT levels + upgrader 100), `EventDispatcher.Server.set_power_levels/2` (l.3390-3440: **unrouted**, no route in `protected.ex`; tests call it directly, e.g. `matrix_client_compat_test.exs` l.1653-1665 "m.room.power_levels has NO HTTP route either", `event_size_backstop_test.exs` l.225-240), and 11 test files that seed levels through `Room.Server.set_power_levels/3` (`power_level_enforcement_test`, `nebu_room_test`, `join_room_test`, `handler_test`, `upgrade_room_test` (l.409 self-demotion to 99), `moderation_unit_test`, `moderation_fix_cycle1_unit_test`, `event_size_backstop_test`, ...). `create_personal_room` (l.6249-6265) writes the column and its own event in the CALLER for a brand-new room. |
| The in-process cache and the read side | `state.power_levels` (string-key map, `parse_power_levels/1` l.700-708: `Jason.decode`, no normalisation) and `state.power_levels_event` `{event_id, ts, sender}` are loaded by `do_init/1` from the column and the identity query (`Room.DB` `@sql_power_levels_identity` l.41-45: latest PL event by `origin_server_ts`). Every reader uses the process state: `moderation_plan/4` (l.801-823), `write_invite` (l.507), `send_event` (l.600), `/sync` `build_state_events/3` (server.ex l.5697-5720: content = `state.power_levels`, identity from `power_levels_event`), `GetRoomState` (l.3922-3927), `upgrade_room` (l.7247-7248: **raw** `get_in(.., ["users", requester]) || 0`, a string `"100"` passes `>= 100`). `unsigned.prev_content` / `replaces_state` of state events come from the GENERIC predecessor lookup (`Room.DB.fetch_state_predecessors/1`, l.1810-1870; every state type, `(origin_server_ts, event_id)` order). `GET /rooms/{id}/state[/..]` is unrouted (`bf`, 404 "Unrecognized request"). |
| createRoom | `@initial_state_forbidden_types` (l.815) includes `m.room.power_levels` (skipped + value-free warning: `er`); `validate_power_level_override/1` (l.1339-1392: integers within +-(2^53-1), no `null`, `events` keys non-empty <= 255 bytes, `users` keys `UserId.valid?/1`, `notifications` integers, other keys kept); `check_creator_lock_out/6` (l.1420-1436) already uses spec semantics (`events[type]` else `state_default`, l.1448-1453); `check_event_sizes!/5` (l.898-934) sizes EVERY `initial_state` entry, the skipped ones included. The step-3 event is stamped `now`, the chain of steps 4-7 starts after it (`last_ts`). |
| Upgrade | Order since moderation-routes-atomic-ban: pre-checks -> tombstone -> `freeze_old_room!/1` (archive + stop) -> authoritative bans / members read -> create -> creator join -> default levels + upgrader 100 -> `carry_bans!/3` -> `copy_state_events/3` (l.7947-8022, `get_generic_state_events/1` excludes `m.room.power_levels`, l.1292-1316 of `db.ex`) -> row-only invitations -> `room_upgraded` audit row. |
| Element 1.12.15 (VERIFIED in the bundle of the `nebu-oauth-element` image, `docker create` + `docker cp`, nothing run) | `src/slash-commands/op.ts`: `/op <user-id> [<power-level>]` (default level 50) and `/deop <user-id>`, both `isEnabled: canAffectPowerlevels` (`slash-commands/utils.ts`: `room.currentState.maySendStateEvent("m.room.power_levels", me)`), both refuse a target that is not a member in the client's room state ("error_invalid_user_in_room"), `warnSelfDemote` dialog only for the user himself. Both call matrix-js-sdk `client.setPowerLevel(roomId, userId, level)` (`src/client.ts`): takes the CURRENT `m.room.power_levels` content from the synced room state (else `GET /state/m.room.power_levels`, and on `M_NOT_FOUND` `{}`), deep-copies it, sets / deletes `users[userId]`, and sends the FULL content with `PUT /rooms/{roomId}/state/m.room.power_levels/` (`sendStateEvent(.., "")`). So Element always sends the complete content (replacement semantics). The Room settings "Roles & Permissions" tab (recalled, NOT verified in the bundle) also sends the full content. |

### Sizing and split

- **Story 1 (THIS story, large: about 800 lines in `server/lib`):** `PowerLevels` (normalised reads, the required level per event, the pure
  v10 shape validator and change checker: about 250), `Room.Server` (the ONE power-level writer, the in-process membership re-check of
  `send_event`, the per-type enforcement: about 180), `Room.DB` (one transactional write: about 50), `EventDispatcher.Server` (the PUT
  state branch, the `/send` and PUT state enforcement, createRoom step 6, the upgrade copy, audit: about 250), `protected.ex` (the tier
  charge for this type: about 20), `AuditWriter` (one action). No migration. One new e2e feature with two scenarios.
- **Story 2 (NOT written here; follow-up `fv`, proposed slug `state-writer-room-process`):** the generic PUT state write (allowlisted
  types) decided AND written in the room process (`write_state/5`), stamped `max(now, latest slot ts + 1)` (closes the PUT-state part of
  `eu`), so a state PUT can no longer be authorised on a snapshot just before a demotion and committed after it (D5 (b) residual).
- Split out as follow-ups: `fw` (redaction route and the `redact` level), `fx` (upgrade permission by the tombstone level), `fy`
  (legacy rooms: the default `events` map, rooms without levels; owner decision). `notifications` is a note on `ad` (no new id).

## Decisions

- **D1 (ONE power-level writer: the room process).** Every write of `m.room.power_levels` goes through ONE `handle_call` of
  `Nebu.Matrix.Room.Server`: `change_power_levels(room_id, sender, content, opts)` with `mode: :client` (the PUT route, the createRoom
  `initial_state` entry of D7, the upgrade copy of D8, the unrouted `EventDispatcher.Server.set_power_levels/2`) or `mode: :internal`
  (`set_power_levels/3`, kept with its signature: createRoom step 3, the upgrade's initial levels, the test seeds; its authorisation is
  the existing one: the bootstrap branch when the in-process levels are `%{}`, else `events["m.room.power_levels"]` / `state_default`,
  NO change rules: it is never reachable from a client request, pinned by a source test, AC14). Both modes share: the strict shape
  validation (D3), the normalised view for the decision (D4), the size check, the stamp `max(now, not_before, latest PL ts + 1)` (latest
  = the identity in `state.power_levels_event`, re-read through the db module when it is `nil`, fail closed), the signed event, the
  write in ONE transaction (D10), and only after the commit: the in-memory `power_levels` + `power_levels_event`, the broadcast to
  `room:<id>` through `:pg.get_members/1` (cluster-safety). Because kick / ban / unban (`moderate/6`), the invite event, `send_event`
  and the power-level change run in the SAME process, each decision sees the levels of every change committed before it: a demoted
  moderator's next kick, invite or send is decided on the new levels (no TOCTOU between them). The alternative "validate in the
  dispatcher, write in the process" was rejected: the change rules depend on the CURRENT levels and the sender's CURRENT level.
- **D2 (`mode: :client` decision, first failure wins; the SAME order at the HTTP level: the dispatcher validates no shape before
  the room call has decided (1) and (2), test review MINOR-7; only the router's existing body checks and the empty-state-key check
  come earlier).** (1) the sender is in `state.members` else `:sender_not_joined`; (2) the
  sender's level >= the required level of `m.room.power_levels` (`events["m.room.power_levels"]` else `state_default`, normalised) else
  `:insufficient_level`; (3) the shape (D3) else `{:invalid, reason}`; (4) when the room has no previous PL event (no
  `power_levels_event` AND the db read finds none): allow (v10 rule 4; unreachable through the route in practice, see D4 (c)); (5) the
  v10 change rules of S4 (5)-(7) against the CURRENT stored content, the sender's level taken from the current levels:
  `:above_own_level` (a key / `events` / `notifications` entry whose CURRENT value is above the sender's level is altered),
  `:grant_above_own_level` (a NEW value above the sender's level), `:target_not_lower` (a `users` entry other than the sender's own whose
  current value is >= the sender's level is changed or removed). "Altered" compares the RAW stored maps: a key that is absent in one and
  present in the other is an alteration even when the present value equals the default (spec: "added, changed or removed"). The sender's
  own entry may be lowered or removed (self-demotion, no last-admin guard: spec; Element warns client-side); raising it above his level
  is `:grant_above_own_level`. No last-admin guard: the spec allows a creator to demote himself or empty `users` (rule 7
  exemption); a room in which nobody reaches the required level any more is locked out permanently (spec-conformant, AC2 (f)).
  (6) **identical content** (checked LAST, after membership, level and shape: Oracle Q2) (the new content equals the current stored content, canonical comparison) is an
  idempotent `200` with the CURRENT event id, no new event, no audit row (**Nebu choice**, Synapse parity recalled: `/deop` of a user
  without an entry sends identical content). `trusted_private_chat`: both partners are at 100, so each may change room-wide keys up to
  100 but neither may change the other's entry (rule 7: current 100 >= 100): spec-conformant, documented.
- **D3 (strict write: the v10 shape, one validator for every path).** `PowerLevels.validate_content/1` (pure, shared with
  `validate_power_level_override/1`, which becomes a thin wrapper keeping its texts): the content is an object; the seven integer keys,
  when present, are integers within +-(2^53 - 1) (a JSON float such as `50.0`, a string, a boolean or `null` is refused: v10 "present
  and not an integer"); `events` and `notifications`, when present, are objects whose values are such integers (`events` keys non-empty
  and at most 255 bytes, as the override rule); `users`, when present, an object whose keys pass `UserId.valid?/1` (at most 255 bytes)
  and whose values are such integers; an ABSENT `events` / `notifications` is allowed (v10 rule 2: "present and not an object"); an ABSENT
  `users` is allowed too: **Nebu choice, spec ambiguous** (read strictly, v10 rule 3 "If the users property in content is not an
  object ... reject" rejects an absent `users`), Synapse parity (recalled, not verifiable offline; Oracle Q3); other top-level keys are kept as sent (depth 32 and NUL rules already applied by the router, the size bound of
  `EventSize`); no `null` value anywhere at the top level. No entry cap on `users` / `events`: bounded by the 65536-byte event (at most
  about 1700 `users` entries; the validator is linear). Errors are `400 M_BAD_JSON` with FIXED texts (the override texts, e.g. "power
  level values must be integers within +-(2^53 - 1)", "users keys must be valid user ids"; no client value echoed). The PUT path's
  `state_key` must be `""`: any other key is `400 M_BAD_JSON` "m.room.power_levels requires an empty state key" (**Nebu choice**: the
  spec's state key is "A zero-length string"; a PL event in another slot would never be read by anyone; Oracle question Q4).
- **D4 (tolerant read: the normalised view).** Every READ of levels goes through `PowerLevels.normalize/1` (pure, cheap; applied once
  when the process loads or commits levels, the raw content is kept separately for the change rules and for `/sync`): a threshold key
  that is not an integer in range reads as its SPEC default (S1); a `users` value that is not an integer reads as absent (the user
  falls back to `users_default`), a `users_default` that is not an integer as 0; non-integer `events` / `notifications` values read as
  absent. So (a) a string user level can NEVER pass a check (closes S5), (b) a legacy room with odd stored content keeps working with
  the spec defaults and is fixed by its next valid change (strict write, D3: the change replaces the content; the change rules compare
  the normalised CURRENT values). (c) Levels `%{}`: normalised to the defaults with nobody listed, so nobody reaches `state_default` 50
  and the route refuses every change. Precision (Oracle Q7): for a room whose PL EVENT has the content `{}` this is exactly the SPEC
  (everyone at 0, `state_default` 50: nobody may change anything, permanently); only a room with NO PL event at all (legacy before
  migration 000035, or a failed step 3) deviates: the spec gives the creator 100 and v10 rule 4 allows the first PL event. Nebu denies
  there too (fail safe, **labelled deviation**, operator query Q-pl, follow-up `fy`).
  `get_user_level/2`, `can?/3` and the upgrade check (S-table "upgrade": the raw `get_in`) all use the normalised view.
- **D5 (enforcement of the per-type `events` map).** `PowerLevels.required_level(levels, {:message | :state, event_type})`:
  `events[type]` when present (normalised), else `events_default` (message) / `state_default` (state). (a) **`/send`** (in
  `Room.Server.send_event/6`, in the process): `{:message, type}` (so `events["m.room.message"]: 50` silences users at 0, and
  `events["m.room.redaction"]` gates the redaction event of S2, which is stored as-is and delivered: the documented
  risk of S2, AC17 (n)). (b) **PUT state** (`set_room_state/2`): `{:state, type}` instead
  of `:change_state`, still decided on the `fetch_room_state/1` snapshot in the caller and written by `emit_state_event_at/6` in the
  caller (documented residual: a state PUT decided just before a concurrent demotion can commit after it; story 2, `fv`). (c) the v10
  generic rule "a `state_key` that starts with `@` and does not match the sender" -> `403 M_FORBIDDEN` "You cannot set a state event
  whose state key is another user's id" (every allowlisted type; none uses user-id keys legitimately; behaviour change). (d)
  `Room.Server.send_event/6` re-checks the sender's membership in the process (`:sender_not_joined` -> the existing 403 text): a send
  decided on a snapshot before a kick / ban is refused after it. **Order (decided):** membership FIRST, then the level, then the
  idempotency lookup, then the archived check. Reasons: authorisation before anything else (a non-member never receives a cached
  event id and never causes the `FOR UPDATE` status read); the membership test is in-memory and free, the archived check is a locking
  DB read; a non-member learns nothing about the room's archived state (403 either way). Consequence: suites that send as a NOT joined
  user into an archived room (`nebu_room_test`, `send_event_archived_room_test`) join the user first (re-pin, AC16). (e) Member events are never gated by `events` (spec; unchanged,
  `moderation_plan/4`); `invite`, `kick`, `ban` read the normalised levels; `redact` is not evaluated (S2, `fw`); `notifications` is not
  evaluated (D6). Refusal texts (fixed, explicit `M_FORBIDDEN`): "You do not have a high enough power level to send this event" (send),
  "You do not have a high enough power level to set this state" (PUT state); the old errcode-less 403 of PUT state disappears.
- **D6 (`notifications`: validated, stored, delivered, not evaluated).** Nebu has no server-side push processing (S3), so `@room` has
  no server-side effect to gate; the content is validated (D3), stored and delivered, clients apply it. Labelled in the scope doc; a
  note on `ad` (push rules): the story that adds push evaluation MUST implement `sender_notification_permission` from the normalised
  levels.
- **D7 (`er`: an `initial_state` m.room.power_levels entry is applied at step 6).** The entry is removed from
  `@initial_state_forbidden_types`. Before the room exists (`validate_create_room_request/1`, after the override check 5b, as new step
  5b'): each PL entry must have `state_key` `""` (else `400 M_BAD_JSON`, D3 text; also for an `@` key: the empty-key rule wins), have
  an object `content` (else `400 M_BAD_JSON`, the existing entry-structure rule) and pass `validate_content/1` (`400 M_BAD_JSON`); then
  the GENERIC required-level rule D2 (2) (Oracle gap): the creator's level under the levels in effect before the entry must reach
  `events["m.room.power_levels"]` else `state_default` of those levels, else `400 M_INVALID_ROOM_STATE` "The power levels do not allow
  the room creator to set the initial room state" (the existing lock-out text; with D12 an override `users: {creator: 50}` plus a PL
  entry is refused and no room exists); then the v10 change rules (D2 (5)) with the creator as sender against the levels in effect BEFORE it (the step-3 merge for the first
  entry, the previous entry for the next one) -> `400 M_INVALID_ROOM_STATE` "The initial power levels cannot grant more than the room
  creator has" (spec: "checking power levels for each event"; the spec's own errcode for an unbuildable initial state). The creator
  lock-out (5f) is simulated with the levels IN EFFECT at each planned event (steps 4-5 under the step-3 levels, each `initial_state`
  entry under the levels before it, name / topic / derived alias / invites under the last entry's levels) -> the existing
  `400 M_INVALID_ROOM_STATE` texts. Applied in list order, each a full replacement (no merge with the step-3 content: the
  override's keys vanish unless the entry repeats them, spec; but an entry may only drop what the change rules allow: a
  `trusted_private_chat` invitee at the creator's 100 must be repeated, omitting him is refused by rule 7, AC9 (d)), written through `change_power_levels/4`
  `mode: :client` with `not_before` = the chain value (strictly increasing chain, the D3 rule of create-room-presets-power-levels-topic)
  and fatal on failure (orphan cleanup, 500). A PL entry does NOT replace a preset event (only `(type, "")` of the preset types do). The
  `room_created` audit row is unchanged; no `room_power_levels_changed` row for createRoom.
- **D8 (`fr`: the power levels are carried into the upgraded room; bans first).** The old room's levels are read AFTER the freeze,
  from the `rooms.power_levels_json` column through the db module (the authoritative content, also of a change committed between the
  snapshot and the freeze; a failing read fails the upgrade, 500), normalised (D4: legacy values that are not v10-valid are dropped or
  defaulted, the copy is always strict-valid). Pre-check BEFORE the tombstone on the snapshot (and again on the authoritative content
  after the freeze): every integer of the content (seven keys, `events`, `notifications`, `users`) must be <= the upgrader's own level `L`
  in the old room, else `403 M_FORBIDDEN` "The room has power levels above yours: a user with the highest level must upgrade it"
  (BEFORE the tombstone: nothing written). The same check on the authoritative content AFTER the freeze (a level raised in the gap
  between the snapshot and the freeze) answers `500` with a fixed text (test review MINOR-10: the existing post-freeze failure
  semantics: the old room stays tombstoned and archived, the new room is NOT populated with a level above the upgrader's, the
  `room_upgraded` failure audit row keeps `new_room_id`). Invariant: no level above the upgrader's is ever carried. **Nebu choice** (labelled):
  the spec says nothing about this case (Synapse boosts the upgrader temporarily, recalled); Nebu refuses so that the copy is a valid
  v10 change and nobody gains a level. The ORDER "bans before the copied levels" is **not spec text**: it is this project's own Oracle
  note on `fr` (the spec is silent on bans in upgrades). Then, in the new room: (1) the
  initial levels are the defaults with the upgrader at `L` (was: 100; `L >= 100` by the existing permission check) through
  `set_power_levels/3` (`:internal`); (2) the bans (D11 of moderation-routes-atomic-ban, unchanged: every target at the default 0 <
  `L`); (3) the copy: `change_power_levels/4` `mode: :client` with the upgrader as sender and the old content (normalised) -> by the
  pre-check every v10 change rule holds (all new values <= `L`, the only current `users` entry is the upgrader's own, unchanged); a
  refusal fails the upgrade (500, the new room has no join rule and no invitation yet); (4) `copy_state_events/3` (the join rule) and the
  invitations as today. The `room_upgraded` success row gains `"power_levels_carried" => true`. **Not done (labelled):** lowering the
  old room's levels (S7 "If possible ... should"): the old room is archived and stopped, no event can be sent there. The upgrade
  permission stays `users[requester] >= 100` (normalised), not the tombstone level (`fx`).
- **D9 (rate limit: the existing `moderation` tier).** One unit per `PUT .../state/m.room.power_levels[/""]`, charged FIRST in
  `do_set_room_state/4` for this event type only (before the body checks, like `/kick`; other state types stay uncharged: `fp`). The same
  bucket as kick / ban / unban (`{"moderation", user}`, `{30 per minute, burst 60}`): power-level changes and moderation are the same
  actors and the same abuse class (a privileged user flooding the room with large state events, each up to 64 KiB in every member's
  `/sync`). A labelled divergence from "Rate-limited: No" (S4). A refusal is `429 M_LIMIT_EXCEEDED` with the `Retry-After` header (spec
  SHOULD) and `retry_after_ms` in the body (the existing tier answer). Internal writers (createRoom step 3 / 6, the upgrade) are not charged.
- **D10 (atomic write).** New `Nebu.Matrix.Room.DB.apply_power_levels_change(room_id, content_json, signed_event)`: ONE
  `Nebu.Repo.transaction/1` (`SET LOCAL lock_timeout = '1s'`, then `SELECT status FROM rooms ... FOR NO KEY UPDATE` (fix cycle 1, review I7; was `FOR SHARE`): an archived room is
  `:room_archived` (404 for the route, as moderation), then `UPDATE rooms SET power_levels_json`, then the event insert); any failure rolls
  back both: `:write_failed` (`500 M_UNKNOWN` "The power levels could not be changed", value-free ERROR log: room id +
  `db_error_class/1`; **Dev task:** `Http.map_error/1` maps every internal error to "Internal server error", so this fixed text needs an
  explicit opt-in there (an `errcode: "M_UNKNOWN"` + fixed message that the mapper passes through; no other internal error changes), in-memory
  state unchanged, no broadcast, no audit row. Not a `DBBehaviour` callback: a db module without it is refused
  (`:unsupported_db_module`), never served by two separate statements (the fakes of the suites that write levels implement it, AC14 (b)).
  This also removes the F-1 hazard of `apply_power_levels/4` (column changed, event missing). A GenServer call exit (5 s, `:noproc`) is
  `503 M_UNAVAILABLE` "The room did not answer, the change may or may not have been applied" (the moderation text; not a spec errcode).
- **D11 (audit).** After a COMMITTED client-mode change of the PUT route (not the no-op, not a refusal, not createRoom / upgrade, which
  have their own rows): `room_power_levels_changed` (actor = sender, resource `room`, the room id, outcome `success`), metadata
  `%{"changed_keys" => sorted top-level keys altered (fix cycle 1, Kassandra M-1: only the ten v10 keys; altered keys of the
  client's own choosing are counted as "other_keys_changed_count", present only when > 0), "users_changed" => the user ids whose entry was added / changed / removed (at most
  50, sorted), "users_changed_count" => n}`: levels and user ids are the compliance record of "who gave whom which power", no free text
  is involved. Best effort, written by the dispatcher after the room call returned the committed outcome (the moderation precedent and
  its accepted residual `fs`). Added to `AuditWriter.@known_actions`.
- **D12 (default `events` map for NEW rooms; NON-SPEC, Synapse-derived).** What the spec states (Oracle): createRoom step 3 is only
  "a default `m.room.power_levels` event" ("in room versions 1 through 11, the room creator (and not other members) will be given
  permission to send state events"); the only `events` MUST is `m.room.tombstone` above `state_default` for room version 12+ (not v10);
  the createRoom `events` example with `m.room.name` / `m.room.power_levels` at 100 is an EXAMPLE, not a default. The eight-entry map
  below is recalled from Synapse and NOT verifiable offline (not in the spec bundle). `PowerLevels.default_levels/0` gains
  `"events" => %{"m.room.power_levels" => 100, "m.room.history_visibility" => 100, "m.room.tombstone" => 100, "m.room.server_acl" => 100,
  "m.room.encryption" => 100, "m.room.name" => 50, "m.room.avatar" => 50, "m.room.canonical_alias" => 50}`. Without it the route of this
  story would let every moderator at `state_default` 50 change the power levels and the history visibility of every new room
  (spec-conformant, but not what Element shows as "Admin only" and not what users expect). Applies to createRoom (also under an
  override that does not set `events`: shallow merge), the upgrade's initial levels, `create_personal_room`. The creator lock-out uses
  it (a creator lowered below 100 by an override can no longer have the preset's `m.room.history_visibility` written:
  `400 M_INVALID_ROOM_STATE`, correct per the Oracle: any override / `initial_state` entry leaving the creator below 100 makes the
  preset's step-5 event fail; Synapse behaves alike, recalled). The spec has no last-admin guard (Oracle Q8): the creator may still
  demote himself later through the route. Existing rooms are NOT backfilled (`fy`, operator query Q-pl).
- **D13 (what stays out).** `redact` (`fw`), `notifications` (D6, `ad`), the PUT state writer in the process (`fv`), the tombstone
  level for upgrades (`fx`), legacy rooms (`fy`), `PUT .../state/m.room.member` (`fq`, unchanged), `GET .../state` (`bf`; Element reads
  the levels from `/sync`, so `setPowerLevel` never needs the GET: the fallback `{}` of js-sdk is NOT reached while the room state
  carries the levels event, which `build_state_events/3` always emits).

### Oracle questions (the Oracle gate runs next)

- Q1: Is `400 M_BAD_JSON` the right answer for a v10-invalid content (non-integer, invalid `users` key) on PUT state, or `403
  M_FORBIDDEN` (the auth rules "reject")? Nebu: 400 (malformed request), the change-rule refusals are 403.
- Q2: The idempotent no-op for identical content (D2 (6)): acceptable, or must a new event be written?
- Q3: Absent `users` / `events` / `notifications` in the new content: allowed (Synapse) although v10 says "If the `users` property in
  content is not an object ... reject"?
- Q4: A non-empty `state_key` for `m.room.power_levels`: `400 M_BAD_JSON` (Nebu) acceptable?
- Q5: D7: the change rules applied to an `initial_state` entry against the step-3 levels, and `400 M_INVALID_ROOM_STATE` for a violation.
- Q6: D8: the upgrade refused when the old room holds a level above the upgrader's (instead of Synapse's temporary boost); not lowering
  the old room's levels because it is archived.
- Q7: D4 (c): a room with no levels content: deny everything (Nebu) vs. the spec default "creator 100". **Oracle:** OK with the
  precision now in D4 (c) (content `{}` = spec; only NO PL event deviates).
- Q8: D12: the default `events` map for new rooms (spec defines none; Synapse parity) and its effect on the creator lock-out.
  **Oracle:** OK as NON-SPEC / Synapse-derived (label in D12); the spec has no last-admin guard.
- **Oracle result (2026-10-20, `step-results/power-levels-enforcement/oracle-context.md`):** S1-S8 OK (S2 corrected), no WRONG
  decision; Q1, Q5, Q9 OK; Q2, Q3, Q4, Q6, Q7, Q8, Q10 labelled-deviation OK; Q11 OK for `notifications`, the `redact` / redaction
  wording corrected (S2, `fw`); D7 gained the generic required-level check; 16 missing tests are AC17.
- Q9: D5 (c): the `@`-state-key rule on every allowlisted PUT state type, errcode / text.
- Q10: D9: the `moderation` tier for PUT state m.room.power_levels (divergence from "Rate-limited: No").
- Q11: `notifications` not evaluated (no server-side push) and `redact` not evaluated (no redaction route): correct labels?

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused ... `fv` onward" and a grep of `docs/` finds `fv` only in that id line and in the moderation-routes-atomic-ban story's re-pin notes, `fw`-`fz` nowhere, no row: the new ids are `fv`, `fw`, `fx`, `fy`, `fz`; unused from `ga` onward)

- **`fv` — The generic PUT state write is decided and written in the CALLER.** `set_room_state/2` authorises on a `fetch_room_state/1`
  snapshot and `emit_state_event_at/6` signs and inserts in the caller: a state PUT authorised just before a concurrent power-level change
  (a demotion, a raised `events[type]`) or a kick / ban of the sender can commit after it, and its stamp is not `max(now, latest slot ts
  + 1)` (the PUT-state part of `eu`). Fix: `Room.Server.write_state/5` (the decision of D5 (b) / (c) and the content rules' final check
  in the process, one stamped insert), story 2 (`state-writer-room-process`). Source: this story (D5 (b)). Non-gating.
- **`fw` — No redaction route; `redact` is stored, not evaluated; an unchecked `/send` redaction is delivered (security-relevant,
  RAISED priority: the next power-level-adjacent story).** `PUT /rooms/{roomId}/redact/{eventId}/{txnId}` is unrouted (Element's
  "Remove" of a message fails); an `m.room.redaction` sent through `/send` is stored as it is (no check of `content.redacts`, no
  redaction applied) and DELIVERED to every member; clients SHOULD change the affected event on receipt, so a user at `events_default`
  may visually redact OTHER users' messages without the `redact` level (whether Element 1.12.15 applies `content.redacts` in a v10 room
  is UNVERIFIABLE in the bundle; the behaviour is pinned by story power-levels-enforcement AC17 (n); gated only by
  `events["m.room.redaction"]` / `events_default`). v1.18 (not yet binding: Nebu advertises at most v1.15): servers MUST accept
  redactions on `/send` and, below v11, move `content.redacts` to the top level. The story that builds redaction MUST: gate the redaction event by
  `events` / `events_default`, require `redact` for an event of another sender, apply the v10 redaction algorithm to what `/sync`,
  `/messages` and `/event` deliver, and decide the compliance interplay (audit log retention vs. redaction). Source: this story (S2).
  Non-gating.
- **`fx` — The upgrade permission is `users[requester] >= 100`, not the tombstone level.** The spec: "Checks that the user has
  permission to send `m.room.tombstone` events". With the D12 default (`m.room.tombstone: 100`) both agree for new rooms; in a room with
  another `events["m.room.tombstone"]` or `state_default` they differ. Switch to `PowerLevels.required_level(levels, {:state,
  "m.room.tombstone"})` and re-pin the upgrade suites. Source: this story (S7). Non-gating.
- **`fy` — Legacy rooms keep the old power-level content (owner decision).** Rooms created before this story have `events: {}`: in them
  `state_default` (50) governs `m.room.power_levels`, `m.room.history_visibility` and `m.room.tombstone`, so a moderator at 50 can change
  the power levels (within the v10 change rules: never above 50, never a user at or above 50) and the history visibility; rooms without
  any levels content (`%{}`) cannot be changed at all (D4 (c)). Options: a one-off migration that adds the D12 `events` entries where the
  key is absent (a new PL event by the server? the sender must be a member: the creator), or leave it to the room admins (Element shows
  the effective levels). Operator query Q-pl (07-deployment) lists the affected rooms. Source: this story (D4 (c), D12). Non-gating.
- **`fz` — Generic PUT state for an unknown room answers 403 and lazily creates a `rooms` row (pre-existing).** `set_room_state/2`
  reads the room through `fetch_room_state/1`, which lazily starts the room process on `:noproc`; for an unknown room id the start
  inserts a `rooms` row (`do_init/1` -> `insert_room/1`) before the membership check answers `403 M_FORBIDDEN` "You are not a member of
  this room". So any authenticated user can create empty `rooms` rows (and a room process) by PUTting state into random room ids. The
  `m.room.power_levels` branch of this story does NOT do this (no row, no process; AC1 (b)); the other allowlisted types still do. Fix:
  `lookup_room/1` without a lazy start for unknown ids (404 like `/invite`, or keep 403 without the row), fits story 2 (`fv`). Source:
  this story (ATDD finding, AC1 (b)). Non-gating.
- Notes (no new id): `eq` CLOSED (residuals `fv`, `fw`, `fy`, `notifications` on `ad`); `er` CLOSED; `fr` CLOSED (the SHOULD to lower
  the old room is labelled not done, the tombstone level is `fx`); `ad` (push evaluation must use `sender_notification_permission` with
  the normalised levels); `eu` (PUT state stays open: `fv`; the power-level slot is stamped `max(now, latest + 1)` now); `fp` (PUT state
  of power levels is rate-charged now; other types are not); `fq` (unchanged); `fe` (the power-level broadcast uses `:pg.get_members/1`);
  `fs` (the same audit residual applies to `room_power_levels_changed`); `ft` (the new `handle_call` carries content: `format_status/1`
  should redact it too).

## Acceptance Criteria

Test files are named in "Acceptance Tests". "Real DB" = the real `Nebu.Repo`, `Room.Server` under `Horde`, `Room.DB`, through
`Nebu.Web.Router` where the AC says HTTP (`@moduletag :integration`, random users and rooms). Fakes only where an AC says "unit"; every
concurrency and atomicity claim is proven on the real database.

1. **The route (HTTP real DB).** (a) `PUT /_matrix/client/v3/rooms/{roomId}/state/m.room.power_levels` and `.../m.room.power_levels/`
   (empty key) by a member with the required level answer `200 {"event_id": ..}`; the room state in `/sync` carries the new content,
   `sender`, the new `event_id`, and `unsigned.prev_content` = the previous content, `unsigned.replaces_state` = the previous event id.
   (b) The order, first failure wins, each its own test with NOTHING written (no event, column unchanged, in-memory levels unchanged, no
   audit row): an empty `moderation` bucket -> `429 M_LIMIT_EXCEEDED` with `Retry-After` / `retry_after_ms` even for a malformed body;
   the existing router checks (`M_BAD_JSON` non-JSON, NUL, depth, key sizes, `413` size) keep their answers; a non-empty state key ->
   `400 M_BAD_JSON` "m.room.power_levels requires an empty state key" (a path-level check); then, in the D2 order: a non-member (never
   joined, left, banned, invited) -> `403 M_FORBIDDEN` "You are not a member of this room"; below the required level -> `403` "You do not
   have a high enough power level to change the power levels"; then each D3 shape violation (`"50"`, `50.0`, `true`, `null`, 2^53,
   `-(2^53)`, `events` not an object, an `events` value `"0"`, an empty / 256-byte `events` key, `users` key `"alice"` / `"@bad id"` / 256
   bytes, a `users` value `"100"`, `notifications.room` `"50"`) -> `400 M_BAD_JSON` with its fixed text, by an authorised member; the
   order is pinned (MINOR-7): a non-member with `{"ban": "x"}` -> `403` "You are not a member of this room", a member below the level
   with an invalid body -> `403` (the low-level text); an unknown room id -> the answer PUT state gives today (`403 M_FORBIDDEN` "You are not
   a member of this room"), and for THIS route NO `rooms` row is created and NO room process is started (the generic PUT state of other
   types lazily creates a `rooms` row for an unknown room today: a pre-existing defect, not touched here, follow-up `fz`). (c) Error bodies are exactly `{"errcode", "error"}`, fixed texts, no client value echoed.
2. **The v10 change rules (HTTP real DB; D2 (5)), each a separate test, levels set up with `set_power_levels/3` seeds.** Sender at 50
   (`events["m.room.power_levels"]: 50`): (a) raising `ban` from 50 to 51 -> `403` "You cannot grant a power level above your own";
   lowering `kick` from 50 to 0 -> `200`; changing `state_default` whose CURRENT value is 75 -> `403` "You cannot change a power level
   above your own"; removing a key whose current value is 75 -> `403`; adding a key that was absent with the default value (e.g. `"redact":
   50` where `redact` was absent) -> `200` (an alteration within the level); (b) `events`: adding `"m.room.topic": 50` -> `200`, `51` ->
   `403`; changing an entry whose current value is 100 -> `403`; (c) `users`: adding a user at 50 -> `200`, at 51 -> `403`; changing or
   removing a user at 50 (equal) -> `403` "You cannot change the power level of a user whose level is not lower than yours"; a user at 49
   -> `200`; (d) self: lowering his own 50 to 10 -> `200` (and his next change is refused, he is below the level); removing his own entry
   -> `200` (falls to `users_default`); raising his own entry to 51 -> `403`; (e) `notifications.room` treated like `events`; (f) a sender
   at 100 replacing the whole content with `{}` while another user is at 100 -> `403` (removing the other's entry), with only lower users
   -> `200` (the content is `{}`, every reader sees the spec defaults afterwards); afterwards EVERY further PUT, also by the same
   sender, is `403` (nobody reaches `state_default` 50): the room's levels are locked permanently, pinned as spec-conformant (no
   last-admin guard, Oracle Q7 / Q8); (g) `trusted_private_chat`: partner A cannot change
   partner B's entry (`403`), can change `events_default` to 100 (`200`); (h) boundaries: values `2^53 - 1` / `-(2^53 - 1)` accepted by
   the shape check (then refused by the grant rule unless the sender is that high).
3. **Idempotent no-op (HTTP real DB, D2 (6)).** PUT of exactly the current content -> `200` with the CURRENT event id, event count
   unchanged, no audit row, no broadcast; content equal up to key order counts as identical; a content that differs only by an absent
   key vs. a key at its default is NOT identical (an alteration).
4. **Enforcement of `events` (HTTP real DB, D5).** (a) `/send`: with `events["m.room.message"]: 50` a user at 0 -> `403` "You do not
   have a high enough power level to send this event", at 50 -> `200`; another message type stays at `events_default`; with
   `events_default: 10` and `events["m.custom"]: 0` a user at 0 sends `m.custom` (`200`) but not `m.room.message` (`403`); `/send` of
   `m.room.redaction` follows `events["m.room.redaction"]` / `events_default`. (b) PUT state: with `events["m.room.topic"]: 100` a user at
   50 (= `state_default`) -> `403` "You do not have a high enough power level to set this state"; with `events["m.room.name"]: 0` a user at
   0 -> `200`; a type without an entry -> `state_default`. (c) the `@` rule: PUT `m.room.name` (allowlisted) with state key
   `"@other:server"` -> `403` with the D5 (c) text; with the sender's own id -> passes this rule. (d) `send_event` in the process refuses
   a sender that is no longer a member (unit: a stale snapshot; real DB: the deterministic gap test with a db / registry hook between the
   dispatcher's check and the room call, a kick committed in the gap -> `403`, no event). (e) member events are unaffected by `events`
   (`events["m.room.member"]: 100` does not block a join, invite or kick decided by the membership rules).
5. **Integers, tolerant read (unit + real DB, D4).** (a) unit: `PowerLevels.normalize/1` for a content with `"ban" => "0"`,
   `"users" => %{"@a:s" => "100", "@b:s" => 50.0, "@c:s" => 70}`, `"users_default" => "5"`, `"events" => %{"m.room.name" => "0"}`:
   `ban` 50 (default), `@a` / `@b` at `users_default` 0, `@c` 70, `events` without `m.room.name`; `can?/3` for `@a` is `false` for
   kick / ban / state; (b) real DB: a room whose column is set to such legacy content directly (SQL, rolled back / own room): `@a` (stored
   `"100"`) cannot kick, ban, change state or upgrade (`403`), the room keeps working with the defaults, and a valid PUT by a user who
   reaches the normalised levels replaces the content (afterwards strictly valid); (c) `%{}` content: every PUT is `403` (D4 (c)).
6. **The writer: atomicity, stamp, cache (real DB, D1, D10).** (a) `apply_power_levels_change/3` with an event insert that fails INSIDE
   the transaction (pre-insert the identical signed event: unique violation) -> the column is unchanged, no event; through the route
   `500` with the fixed text, in-memory levels unchanged, no broadcast to a `:pg` test member, no audit row, the ERROR log names the room
   id and the SQLSTATE class only; a retry succeeds. (b) unit: a db module without `apply_power_levels_change/3` -> `500`, nothing
   written, never the two-statement path; a room process that does not answer -> `503 M_UNAVAILABLE`. (c) stamp: a PL event written 100 ms
   AHEAD of the clock (direct insert in an own room, `on_exit` delete), then a PUT at once: the new event's `origin_server_ts` = previous
   + 1 (> previous), it is the latest PL event (`@sql_power_levels_identity`), `/sync` shows the new content. (d) after a committed change
   the four sources agree: column, latest PL event content, in-memory `power_levels`, the `/sync` state event (content + event id). (e) an
   archived room (status set, process still running) -> `404` "Room not found", nothing written. (f) `set_power_levels/3` (`:internal`)
   writes through the same transaction (the existing suites stay green).
7. **Concurrency (real DB, at least 50 rounds each, invariants after every round, `Task.async` with a barrier).** (a) a demotion of a
   moderator (100 -> 0 by the creator, who stands at **150** by a seed: under v10 rule 7 a user at 100 cannot change another user at 100)
   vs. 10 concurrent kicks / bans by that moderator of users at 0: no `500` / `503`; every moderation
   STARTED after the demotion's reply is `403`; each `200` has its event, each refusal wrote nothing; column, latest event and in-memory
   levels agree. (b) a raise of `events["m.room.message"]` to 50 vs. 10 concurrent sends by a user at 0: the same invariants (a send
   started after the change's reply is `403`). (c) two admins at 100 concurrently PUT different contents: both `200` (serialised), the
   latest event is the one committed last, the column equals its content, every `prev_content` chain is linear (each event's
   predecessor is the event committed before it). (d) Mutual demotion: (i) A and B both at 100 concurrently try to demote each other:
   this is NOT a race (rule 7: a user at the sender's level cannot be changed): BOTH are `403` in every interleaving and nothing is
   written (50 rounds); (ii) the satisfiable analogue: A (100) demotes B (60 -> 0) while B demotes C (50 -> 0): the outcome is one of
   the two serial orders (B's change committed before A's demotion, or B refused because his level is 0 by then), never B's change
   committed after A's demotion. A failure prints the round's event sequence (no
   message content).
8. **Crash / restart (real DB; `.claude/rules/matrix-conventions.md`).** After a committed change the room process is killed
   (`Process.exit(pid, :kill)`) and restarted: the reloaded `power_levels` equal the new content and `power_levels_event` its identity
   (event id, ts, sender); enforcement (a kick by the demoted user) uses the new levels; a process killed DURING a change (kill from a db
   hook before the commit) leaves column and events exactly as before.
9. **createRoom `initial_state` power levels (HTTP real DB, D7).** (a) An entry `{"type": "m.room.power_levels", "content": {...valid,
   creator at 100, "events_default": 10}}` is applied: the room's levels equal the entry content EXACTLY (no merge with the defaults or
   the override), the event is after the step-3 event and after the preset events, before `m.room.name` (strictly increasing chain); the
   warning "skipped" is gone for this type. (b) Two entries: the later wins, each a separate event. (c) An entry granting a user 101 (the
   creator at 100) -> `400 M_INVALID_ROOM_STATE` "The initial power levels cannot grant more than the room creator has" and no room
   exists; an entry that drops the creator to 0 while a `name` is given -> `400 M_INVALID_ROOM_STATE` (the lock-out text); an entry
   without the creator but with `users_default: 100` -> `200`; an entry with a string level -> `400 M_BAD_JSON`; an entry with state key
   `"x"` -> `400 M_BAD_JSON`. (d) `trusted_private_chat`: an entry that REPEATS the invitee at 100 is applied exactly and the invite
   events of step 8 still pass; an entry that OMITS the invitee is `400 M_INVALID_ROOM_STATE` "The initial power levels cannot grant
   more than the room creator has" and no room exists (D7 applies the v10 change rules with the creator as sender: removing the
   invitee's step-3 entry 100, which is not below the creator's 100, is refused by rule 7; the full replacement is only possible where
   the rules allow it). (e) An entry plus `power_level_content_override`: the entry
   wins (step 6 after step 3). (f) The entry does not suppress a preset event. (g) The re-pin of AC13 for the old "skipped" tests.
10. **Upgrade carries the levels (HTTP real DB, D8).** (a) Old room: creator / upgrader at 100, marie at 50, `events["m.room.topic"]: 75`,
    two banned users of whom one is listed in `users` at 100 (legacy: set by a seed): `POST /upgrade` -> `200`; in the new room: the
    ban events of both exist and are written BEFORE the copied PL event and before `m.room.join_rules`, the final levels equal the old
    content (marie 50, the topic entry, the banned user's entry at 100 included), the creator join and the initial PL event precede the
    bans; both banned users' `/join` -> `403`. (b) An old room with a user at 150 (upgrader at 100) -> `403 M_FORBIDDEN` "The room has
    power levels above yours: a user with the highest level must upgrade it" BEFORE the tombstone (no tombstone, no new room, old room not
    archived). (c) A change committed between the snapshot and the freeze (deterministic hook) is the one carried; a change in that gap
    that raises a user to 150 (upgrader at 100; `Hooks.arm_before_archive` + a seed) -> `500` with a fixed text, the old room tombstoned
    and archived, no new room carries a level above 100, the `room_upgraded` failure audit row with `new_room_id` (MINOR-10). (d) Legacy odd content
    is carried normalised (a string `users` value is not carried, a string `ban` becomes absent-default), the copy passes D3. (e) A
    failing copy (test db module) fails the upgrade with `500` (new room without join rule and invitation). (f) `room_upgraded` success
    row has `"power_levels_carried" => true`. (g) The old room's levels are unchanged (labelled: not lowered).
11. **Rate limit (HTTP real DB, D9).** With `moderation` at `rate_per_min 1, burst 2`, the third PUT of `m.room.power_levels` by the same
    user is `429`; a `/kick` draws from the same bucket; a PUT of `m.room.topic` is not charged (any number passes the tier); another
    user is unaffected; `NEBU_RATE_LIMIT_DISABLED=true` disables it.
12. **Audit (real DB, D11).** A committed PUT writes exactly one `room_power_levels_changed` row (actor, resource `room`, room id,
    metadata exactly `changed_keys` / `users_changed` (sorted, at most 50) / `users_changed_count` when no unknown key changed (fix
    cycle 1: plus `other_keys_changed_count` otherwise), outcome `success`); 60 changed users ->
    50 ids listed, count 60; no row for the no-op, refusals, createRoom entries or the upgrade copy; `AuditWriter.log/6` accepts the
    action; a failing audit writer does not fail the change (`200`, value-free ERROR log). No content of the levels event appears in any
    log line of the suite (captured logs).
13. **Default `events` map (unit + HTTP real DB, D12).** `PowerLevels.default_levels/0` has the eight D12 entries; a new room (no
    override) has them in its PL event; an override with `"events": {}` replaces them (shallow merge); a moderator at 50 in a new room
    cannot PUT power levels (`403`, required 100) nor `m.room.history_visibility` (`403`) but can PUT `m.room.name` (`200`); the creator
    lock-out with an override `users: {creator: 50}` and a preset -> `400 M_INVALID_ROOM_STATE`.
14. **Source pins and seams (unit).** (a) In `server/lib` no `m.room.power_levels` event is built and no `set_power_levels` column write
    happens outside `Room.Server` / `Room.DB.apply_power_levels_change/3` except `create_personal_room` (a brand-new room, pinned as the
    one exception); `apply_power_levels/4` and `emit_power_levels_event/3` are gone (replaced); `Room.Server.set_power_levels/3` has no
    caller in `server/lib/nebu/web` and in `EventDispatcher.Server` only `create_room/2` step 3 and `upgrade_room/2` step (1); the route
    reaches only `change_power_levels/4` `mode: :client`. (b) The fakes of every suite that writes levels through `set_power_levels/3` or
    the dispatcher implement `apply_power_levels_change/3` (the dev greps `def set_power_levels` in `server/test` and records the list).
    (c) `PowerLevels` is pure (no DB, no process) and `can?/3` keeps its signature.
15. **Docs (`server/test/nebu/matrix/power_levels_docs_test.exs`, new).** (a) `docs/matrix-api-scope.md`: the two PUT state rows document
    the `m.room.power_levels` branch (the D2 order and texts, the D3 shape, the no-op, the tier "divergence from Rate-limited: No", the
    `@` rule, `events[type]` enforcement), the `/send` row the per-type enforcement and the in-process membership check, the createRoom row
    the applied entry (D7: "replacement", "step 6"; the words "skipped" for `m.room.power_levels` and "deviation" for this entry are gone,
    the five other skipped types stay), the upgrade row the carried levels with the labels "bans before the copied levels" and "old room
    not lowered: archived" and `fx`; a NEW row `PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}` 🔲 "Unrouted (follow-up
    `fw`)"; the labels (each pinned): "Nebu choice" for the no-op, the state-key refusal, the empty-levels deny, the default `events` map,
    "not evaluated" for `notifications` (no server-side push) and `redact` (no redaction route), the `/send` row's risk note "an `m.room.redaction` is stored as-is and
    delivered; clients may apply it without the `redact` level (`fw`)", "Nebu choice" for an absent `users` and for the upgrade refusal
    above the upgrader's level, "non-spec, Synapse-derived" for the default `events` map, "`503 M_UNAVAILABLE` is not a spec
    errcode". **Verbatim label strings (pinned by `power_levels_docs_test.exs` l.144-153, 183-185, 192, 210; copy them exactly):** PUT
    state rows: "the tier on `m.room.power_levels`: divergence from Rate-limited: No", "non-empty state key refused: Nebu choice", "no-op
    on identical content: Nebu choice", "empty levels content denies every change: Nebu choice", "absent `users`: Nebu choice (spec
    ambiguous, Synapse parity)", "`notifications` not evaluated", "`redact` not evaluated: no redaction route", "`503 M_UNAVAILABLE` is
    not a spec errcode" (plus "no server-side push" and `fv`); `/send` row: "You do not have a high enough power level to send this
    event", "an `m.room.redaction` is stored as-is and delivered; clients may apply it without the `redact` level (`fw`)", "`redact` is
    stored, not evaluated"; createRoom row: "The initial power levels cannot grant more than the room creator has", "levels in effect",
    "does not replace a preset event", "five other skipped types", "default `events` map for new rooms: Nebu choice (non-spec,
    Synapse-derived)" (plus the eight entry names and `fy`); upgrade row: "Power levels are carried", "bans before the copied levels",
    "old room not lowered: archived", "upgrade refused above the upgrader's level: Nebu choice" (the row also states that the same
    check after the freeze answers `500` and leaves the old room tombstoned and archived, MINOR-10), "The room has power levels above yours:
    a user with the highest level must upgrade it", "project's own Oracle note" (plus `fx`, `fr`, `power_levels_carried`). **The
    createRoom row never contains the word "deviation"** (the suite refutes it over the WHOLE row): the default `events` map is labelled
    "divergence" / "Nebu choice", and the `initial_state` sentence states the entry is applied (no longer skipped) without that word.
    (b) `docs/architecture/07-deployment.md`: a new paragraph "**Power levels (story power-levels-enforcement, follow-ups `eq`,
    `er`, `fr`).**" (what clients can see: Element's Roles & Permissions and `/op` / `/deop` work; changed answers; the tier; the audit
    action; legacy rooms (`fy`) and the operator query **Q-pl** (rooms whose stored content has a non-integer value, no content, or no
    `events["m.room.power_levels"]`), checked in a rolled-back transaction with fixture rows); the moderation paragraph's "the power levels
    are still not carried, follow-up `fr`" becomes "carried (story power-levels-enforcement)" and KEEPS the word `fr` (pinned by
    `moderation_routes_docs_test.exs` l.292-296), e.g. "the power levels are carried (story power-levels-enforcement, follow-up `fr`
    closed)". (c) `CHANGELOG.md` `[Unreleased]`: `###
    Added` the route, the audit action; `### Changed` (**⚠**): `events[type]` is enforced, the `@` rule, the default `events` map of new
    rooms, `initial_state` power levels are applied, upgrades carry the levels and need the upgrader at the highest level. (d)
    `follow-ups.md`: `eq`, `er`, `fr` rewritten as **CLOSED by story power-levels-enforcement (date)** keeping the words pinned by the
    existing docs suites (`eq`: "events", "redact", "notifications", "m.room.power_levels", "EventSize", "power level", "`trusted_private_chat`",
    "100", "DM", "D13", "unban needs the ban AND the kick level", "`events`"; `er`: "initial_state", "m.room.power_levels", "replacement";
    `fr`: "m.room.power_levels", "copy_state_events/3", "BEFORE", "`eq`", "`ew`", "LOWER"); notes on `ad`, `eu`, `fp`, `fe`, `fs`, `ft`;
    new rows `fv`, `fw`, `fx`, `fy`, `fz`; the id line "`fv`-`fz`: power-levels-enforcement" and "unused: ... `ga` onward". (e) The suite pins
    (a)-(d) and the absence of the removed phrases.
16. **Regression and deliberate re-pins.** `mix compile --warnings-as-errors`; `mix test` and `mix test --include integration` green
    apart from the known flaky families (`fj`, `fm`). Deliberate re-pins (**Change Log old -> new per test; the re-pin diff is reviewed
    before the verify step**; never weaken an assertion; any OTHER needed change is a finding: stop and report): `create_room_presets_http_test.exs` "AC12 - initial_state m.room.power_levels is still skipped" (->
    applied, D7); `create_room_initial_state_http_test.exs` l.197 (`m.room.power_levels` leaves the skipped list); `set_room_state_test.exs`
    l.265 and `spaces_state_events_integration_test.exs` l.211 (the forbidden list loses `m.room.power_levels`; `m.room.member` /
    `m.room.create` stay 403); `matrix_client_compat_test.exs` l.1653 (comment: the route exists); the suites that pin the default
    content with `"events" => %{}` literally (the dev greps; tests that compare with `default_levels/0` stay green); the `trusted_private_chat`
    / override lock-out tests whose creator is below 100 (D12, if any); the docs suites `create_room_presets_docs_test.exs` (`eq` / `er`
    rows, the createRoom row's "deviation" assertion), `event_size_limit_docs_test.exs` (`eq`), `create_room_invites_docs_test.exs` (`eq`),
    `moderation_routes_docs_test.exs` (`eq`, `fr` rows, the upgrade row and the 07 paragraph `fr` words), and the id-line assertion "`fv`
    onward" in the eight suites (`create_room_invites_docs_test`, `create_room_presets_docs_test`, `event_size_limit_docs_test`,
    `member_prev_content_docs_test`, `membership_write_limits_cycle1_docs_test`, `membership_write_limits_docs_test`,
    `moderation_routes_docs_test`, `sync_membership_partition_docs_test`) -> "`ga` onward" (and the titles "continues at fv" -> "ga"),
    plus this story's own `power_levels_docs_test.exs` (staged with "`fv`-`fy`" / "`fz` onward" -> "`fv`-`fz`" / "`ga` onward").
    **Further re-pins found by the ATDD reference (dev work, each old -> new in the Change Log):** D12 default `events` map:
    `power_level_test.exs` (`default_levels/0`), `power_level_enforcement_test.exs` (`default_power_levels/0`), the lock-out / planner
    tests of `create_room_presets_test.exs`, `create_room_invites_test.exs`, `create_room_initial_state_test.exs`; the applied
    `initial_state` entry and the shorter forbidden list: `create_room_presets_http_test.exs` AC12, `create_room_initial_state_http_test.exs`,
    `set_room_state_test.exs`, `spaces_state_events_integration_test.exs`, `space_edit_audit_test.exs`, `create_room_presets_test.exs`
    AC12; D5 (d) membership-first order: `nebu_room_test.exs` and `send_event_archived_room_test.exs` (they send as NOT joined users: the
    user joins first, the archived assertion stays); D12 + D5 (a): `matrix_client_compat_test.exs` "non-state send path" (about l.2723)
    expects `200` for `PUT /send/m.room.name` by a user without power: now `403` (`events["m.room.name"]: 50` applies to the message
    event of that type too) -> re-pin to `403` (or seed the sender at 50 if the test's subject is the non-state path itself: record which).
    Unchanged and green: `power_level_enforcement_test.exs` (unless it pins the bootstrap of a NON-empty room or a string level: then a
    finding), `moderation_*`, `create_room_*` (apart from the listed), `upgrade_room*` (apart from the D8 pre-check where a seed puts a user
    above the upgrader: record), `event_size_backstop_test.exs`, `sync_*`, `member_prev_content*`.
17. **Oracle missing tests (HTTP real DB unless noted; each a separate test, nothing written on every refusal).**
    (a) createRoom: `power_level_content_override` `users: {creator: 50}` plus an `initial_state` PL entry -> `400 M_INVALID_ROOM_STATE`
    and no room exists (D7, the generic required-level rule at step 6).
    (b) Equality boundaries, sender at 50: `kick` 40 -> 50 -> `200`; an `events` entry whose current value is 50 changed to 0 -> `200`
    (strictly greater rejects); a `users` entry at 50 changed -> `403` (greater or equal rejects).
    (c) Negative levels: `users_default: -10`, a user at -5, a sender at 0 (with the required level lowered to 0 by a seed) changes that
    user -> `200`; a sender at -1 cannot change anything (`403`).
    (d) A `users` entry for a valid user id that is not a member (also of another server) is accepted (`200`).
    (e) Body a JSON array, a string, a number -> `400 M_BAD_JSON`; `users: []`, `users: null`, `notifications: []`, `events: null` ->
    `400 M_BAD_JSON`.
    (f) Exponent / float forms (`1e2`, `5.0E1`, `-0.0`) in each of the seven keys, an `events` value, a `users` value and a
    `notifications` value -> `400 M_BAD_JSON`.
    (g) `notifications` with a key other than `room`: an integer is accepted and subject to the change rules (`51` by a sender at 50 ->
    `403`); a string -> `400`.
    (h) An unknown top-level key (`"x_custom": 999`) is preserved in the stored content and `/sync` and is NOT subject to the change rules:
    a sender at the required level (50) -> `200`.
    (i) No-op ordering (D2 (6) last): identical content by a non-member -> `403`; by a member below the required level -> `403`; by
    another authorised sender than the current event's -> `200` with the CURRENT event id, no new event.
    (j) Self-exemption at an equal level: a sender at 100 lowers his OWN entry while another user is at 100 -> `200`; removing the other
    user's entry -> `403`.
    (k) `@` rule variants on an allowlisted type (`m.room.name`): state key `"@"` alone -> `403`, `"@SENDER:server"` (the sender's id
    with a different case) -> `403`; a non-`@` key `"x@y"` passes the rule.
    (l) Upgrader at `L = 150`: a content with values up to 150 is carried; a `users` entry at 151 -> `403` before the tombstone (no
    tombstone, no new room).
    (m) PUT `m.room.power_levels` with state key `"@sender:server"` (the sender's own id) -> `400 M_BAD_JSON` "m.room.power_levels
    requires an empty state key" (pins the precedence of the D3 empty-key rule over the `@` rule).
    (n) `/send` of `m.room.redaction` with `content.redacts` = another user's event id by a user below `redact` (at `events_default`):
    `200`, stored with exactly the sent content, the target event unchanged in `/messages` and `/event`, and the redaction event
    delivered in the other members' `/sync` (the documented risk of S2 until `fw`).
    (o) `429` of the PUT PL tier carries `errcode: M_LIMIT_EXCEEDED` and the `Retry-After` header (assert both; `retry_after_ms` is
    asserted only as optional, never as the only signal).
    (p) createRoom `initial_state` PL entry with an `@` state key, and one with a non-object `content` -> `400 M_BAD_JSON` (errcode
    pinned), no room.

## Acceptance Tests

- `server/test/nebu/matrix/power_levels_http_test.exs` (new, `:integration`, through `Nebu.Web.Router`): AC1, AC2, AC3, AC4 (a)-(c), (e),
  AC5 (b), (c), AC9, AC10, AC11, AC12, AC13 (HTTP part), AC17 (a)-(p).
- `server/test/nebu/matrix/room/power_levels_writer_db_test.exs` (new, `:integration`, real DB, `Room.Server` + `Room.DB` directly): AC4 (d)
  (real-DB gap test), AC6 (a), (c)-(f), AC8.
- `server/test/nebu/matrix/power_levels_concurrency_test.exs` (new, `:integration`, `async: false`, tagged `:concurrency`, included in the
  integration run): AC7.
- `server/test/nebu/matrix/room/power_levels_unit_test.exs` (new, unit: `PowerLevels` pure functions and fakes): AC4 (d) (unit), AC5 (a),
  AC6 (b), AC13 (unit), AC14; plus a table-driven test of `PowerLevels.check_change/3` over every S4 rule (5)-(7) incl. the absent-vs-default
  alteration and the self-entry exemption.
- `server/test/nebu/web/rate_limit_tiers_test.exs` (existing, extended if needed): AC11 (unit part).
- `server/test/nebu/matrix/power_levels_docs_test.exs` (new): AC15.
- Re-pinned: the suites of AC16.

## E2E verification

`ui: false` (no Nebu UI code; Element is the client). One new feature `e2e/features/element/room/power-levels.feature` with two scenarios,
run on a FRESH, isolated stack built from THIS commit:

- **`@power-levels-api @regression`** (the guard, no UI selectors; `e2e/features/element/room/power-levels.feature` is the binding
  wording): alex creates a `public` room through the API, marie, tom and kai join; alex PUTs the levels (the full content of his
  `/sync`) with marie at 50 AND `events["m.room.power_levels"]: 50` in the same PUT (with the D12 default of 100 marie could not change
  the levels at all and would be refused for her LEVEL before the change rules apply): `200`; marie PUTs herself to 100: `403` "You
  cannot grant a power level above your own"; marie PUTs alex to 0: `403` "You cannot change the power level of a user whose level is
  not lower than yours"; marie kicks tom: `200`; alex sets `events["m.room.topic"]: 100`: marie's PUT `m.room.topic` is `403` "You do
  not have a high enough power level to set this state"; alex sets marie to 0: marie's kick of kai is `403` "You do not have a high
  enough power level to kick from this room."; kai's `/sync` shows the latest `m.room.power_levels` with `unsigned.prev_content`.
- **`@power-levels-ui @regression @ui`**: alex is logged in via Element Web, opens the room with marie as a member and types `/op
  @marie:localhost 50` in the composer and presses Enter; asserted SERVER-side: marie's level is 50, sender alex; then `/deop
  @marie:localhost`: marie has no `users` entry. VERIFIED in the Element 1.12.15 bundle: both commands exist, are enabled when alex may
  send `m.room.power_levels` (alex is the creator at 100, required 100 by D12), refuse a non-member target, and send the full content
  through `PUT .../state/m.room.power_levels/`. UNVERIFIED: the composer's handling of a slash command on Enter (autocomplete, a
  confirmation) in this Element version (the moderation feature's `@moderation-ui` scenario uses the same steps; its first real run is
  the evidence); the Roles & Permissions tab is not used. If the first real run fails for a UI reason (the server log shows no PUT of
  `m.room.power_levels`, or a `200` one), tag it `@known-failure` with a new row in `e2e/KNOWN-FAILURES.md` (next free K id; cause: Element
  slash-command behaviour unverified) and keep the API scenario as the guard; a server answer other than `200` is a finding.

Run (the orchestrator; evidence, not a UI gate):

0. Preparation: `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000; `COMPOSE_PROJECT_NAME=nebu-oauth-e2e`.
1. **Run A (CI parity):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh element`. Pass: every scenario of the
   default tag expression green (the two new ones, or the UI one moved to the known-failure list as described) except the rows of
   `e2e/KNOWN-FAILURES.md`. Then save the server log, count `RequestLogger` lines with status `500` (pass: zero) and with path
   `state/m.room.power_levels` (record the statuses: only `200` / the expected `403`s); then `docker compose -p nebu-oauth-e2e down -v
   --remove-orphans`.
2. Logs: `_bmad-output/nebu/epics/oauth-broker/step-results/power-levels-enforcement/e2e-run-a.log` and `e2e-run-a-server.log`; update the
   "Status of the last complete run" line of `e2e/KNOWN-FAILURES.md`.

## Tasks

- [ ] `PowerLevels`: `normalize/1`, `required_level/2`, `validate_content/1`, `check_change/3` (pure), `can?/3` on the normalised view,
      the D12 `default_levels/0` (D3, D4, D5, D12).
- [ ] `Room.DB.apply_power_levels_change/3` (one transaction, archived check, lock timeout) (D10).
- [ ] `Room.Server`: `change_power_levels/4` (`:client` / `:internal`), `set_power_levels/3` as the `:internal` wrapper, the stamp, the
      raw + normalised levels in the state, `:pg.get_members/1`; `send_event/6`: `required_level({:message, type})` and the membership
      re-check; delete `apply_power_levels/4` / `emit_power_levels_event/3` (D1, D2, D5 (a), (d)).
- [ ] `EventDispatcher.Server`: the `m.room.power_levels` branch of `set_room_state/2` (state key, shape, `change_power_levels/4`, error
      mapping, audit); `{:state, type}` + the `@` rule for the other types; `set_power_levels/2` -> `:client`; createRoom step 5b' + step 6
      (D7); `upgrade_room/2` pre-check, initial levels at `L`, the copy after the bans, `power_levels_carried` (D8); normalised reads.
- [ ] `protected.ex`: the `moderation` charge for this type in `do_set_room_state/4` (D9).
- [ ] `Http.map_error/1`: the opt-in that passes `500 M_UNKNOWN` "The power levels could not be changed" through (D10); every other
      internal error keeps "Internal server error".
- [ ] `AuditWriter.@known_actions`: `room_power_levels_changed` (D11).
- [ ] Tests (Acceptance Tests) incl. the fakes of AC14 (b) and the re-pins of AC16 (Change Log, old -> new).
- [ ] Docs AC15 (scope doc, 07-deployment incl. Q-pl checked in a rolled-back transaction, CHANGELOG, follow-ups).
- [ ] E2E feature + steps; run A (orchestrator).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (SQL inline
  in `Room.DB`; the decision stays in `Room.Server` / the pure `PowerLevels`), ADR-019 / ADR-021 (plain in-process modules), ADR-020 (no new
  cross-domain call), cluster-safety (one process per room via `Horde.Registry`, `:pg.get_members/1`, no `:global`, no node-local cache).
- **One writer, one order.** The change rules read the CURRENT levels inside the room process, right before the write. **The D2 order
  holds at the HTTP level too (test review MINOR-7):** membership, level, then shape, first failure wins; the dispatcher must NOT
  validate the shape before the room call has decided membership and level (no shape fast path in front of it; the shape check runs
  in the writer after (1)-(2), or a dispatcher pre-check runs only after a membership / level pre-check on the same rules). Never `GenServer.call` the room process from inside its own call
  (a db hook that does deadlocks).
- **Raw vs. normalised.** Keep both in the process state: the raw stored content (what `/sync` delivers, what "identical" and
  "altered" compare) and the normalised view (what every check reads). Never compare a raw level with `>=` (Erlang term order: S5).
- **Binding signatures (chosen by the staged ATDD tests; do not deviate):** `state.power_levels` holds the RAW stored content (the
  normalised view is derived, never stored in that key); `PowerLevels.check_change(current, new, sender)` -> `:ok | {:error,
  :above_own_level | :grant_above_own_level | :target_not_lower}`; `PowerLevels.validate_content/1` -> `:ok | {:error, text}` (the fixed
  400 text); `Room.Server.change_power_levels/4` answers `{:ok, event_id}` or `{:ok, event_id, _outcome}` on success (the no-op returns
  the CURRENT event id); `Room.DB.apply_power_levels_change/3` (room id, content JSON, signed event). Fakes: every fake db module of
  the 24 suites pinned by name in `power_levels_unit_test.exs` (`@fake_suites`) defines `apply_power_levels_change/3`; the upgrade
  suites' rooms-db fakes also define `get_power_levels_json/1` (the authoritative read of D8 after the freeze).
- **Binding notes of the test review (DEV-1..DEV-6, `step-results/power-levels-enforcement/test-review-findings.md`):**
  * DEV-1 `PowerLevels`: `can?/3`, `get_user_level/2`, `required_level/2` accept RAW or normalised content; `normalize/1` is idempotent
    and always returns `users` / `events` maps and integer threshold keys; `get_user_level/2` never returns a non-integer;
    `required_level/2` takes `{:message | :state, type}` and keeps the old atoms; `check_change/3` takes RAW maps and the user id (the
    sender's level from the NORMALISED current content, alterations compared on the RAW maps); `default_levels/0` has exactly the eight
    D12 entries and `Room.Server.default_power_levels/0` equals it; `power_level.ex` stays free of the words of the source pin.
  * DEV-2 `Room.Server`: `change_power_levels/4` with `mode: :client | :internal` and `not_before:`; `:client` errors
    `:sender_not_joined`, `:insufficient_level`, `{:invalid, text}`, the three change atoms, `:event_too_large`, `:write_failed`,
    `:unsupported_db_module`; `:internal` answers `{:error, :forbidden}` when unauthorised plus the same shape / size / write errors, and
    its bootstrap lets ANY caller write when the levels are `%{}` (no change rules; internal only); `send_event/6` order membership,
    level, idempotency, archived (message AND state events); stamp `max(now, not_before, latest PL ts + 1)`;
    `apply_power_levels_change/3` returns `{:error, reason}` on a raised `Postgrex.Error` and exactly `{:error, :room_archived}` for an
    archived room; a db module without it is detected with `function_exported?/3` after loading, never the two-statement fallback;
    broadcast after the commit via `:pg.get_members/1`; `state.power_levels` = RAW content, `state.power_levels_event` = `{id, ts,
    sender}`; the event passed to `apply_power_levels_change/3` has the string keys `event_id`, `type`, `state_key`, `sender`, `content`,
    `origin_server_ts`, `signatures.nebu`.
  * DEV-3 dispatcher: the D2 order (membership, level, shape); every refusal sets `errcode: "M_FORBIDDEN"` explicitly; the `500
    M_UNKNOWN` opt-in of `Http.map_error/1` passes only the fixed text; audit best effort after the commit (rescue + catch, ERROR log
    with the room id only); the after-freeze upgrade pre-check is the `500` fixed text (MINOR-10), no level above the upgrader's is ever
    carried; exactly two `Room.Server.set_power_levels(` calls and the literal `mode: :client` on the client paths, never `:internal`
    there; the upgrade rooms-db fakes need `get_power_levels_json/1` (list them in the Completion Notes); the seams
    `:event_dispatcher, :room_registry_module` (membership snapshot = `get_state/1`), `:admin_db_module` (`archive_room_atomic/1`),
    `:room_manager, :db_module` must not move; the upgrade failure audit row keeps `new_room_id`; the 500 ERROR log carries a SQLSTATE
    class (containing "P0" in the hook test), the room id, no content and no DB error text.
  * DEV-4 fakes and re-pins: a REAL `apply_power_levels_change/3` (column AND event) in the 24 `@fake_suites`; the AC16 re-pins with a
    Change Log entry old -> new per test; never weaken an assertion; the review of that diff happens before the verify step.
  * DEV-5 docs: the labels verbatim from `power_levels_docs_test.exs` (AC15 (a)); keep `fr` and "carried (story
    power-levels-enforcement)" in the moderation paragraph; no "deviation" in the createRoom row; run the Q-pl SQL of 07-deployment in a
    rolled-back transaction and record the evidence in the Debug Log.
  * DEV-6 e2e (orchestrator): Run A as described; a UI-reason failure of the UI scenario -> `@known-failure` + the next free K row; the
    API scenario stays the guard.
- **Nothing half done.** Column and event in ONE transaction; in-memory state, broadcast and audit only after the commit.
- **No sensitive data in logs.** Log room id and `db_error_class/1` only; never the content (user ids and levels are not secret, but the
  No Sensitive Data in Logs Law treats event content as off-limits), never `inspect(reason)` of a DB error.
- **Fixed texts, explicit errcodes.** Every refusal sets `errcode` (an errcode-less `permission_denied` becomes "You are not a member of
  this room" in `Http.map_error/1`).
- **Element.** `setPowerLevel` sends the full content it has from `/sync`: the D2 change rules compare that full content with the stored
  one, so a stale client copy (another admin changed the levels meanwhile) silently reverts the other change if the sender may make
  it (the spec has no compare-and-swap; documented, not fixed).
- **Previous story learnings** (moderation-routes-atomic-ban): real-DB tests for every race and the atomicity; deterministic gap tests
  through db hooks; docs suites pin earlier texts: rewrite `eq` / `er` / `fr` in the CLOSED style keeping the pinned words; `tick/0` only
  in own rooms (`fj`); the e2e on a fresh isolated stack.

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` (`m.room.power_levels`, "Power levels", `PUT
  /rooms/{roomId}/state/{eventType}/{stateKey}`, `POST /createRoom` order, `#room-upgrades` server behaviour, push rule
  `sender_notification_permission`), `rooms/v10/index.html` (authorization rules: generic rules, m.room.power_levels, redactions).
- Code: `server/lib/nebu/matrix/room/power_level.ex`; `server/lib/nebu/matrix/room/server.ex` l.204-214, l.552-632, l.698-708, l.801-828,
  l.1018-1092; `server/lib/nebu/matrix/room/db.ex` l.34-45, l.405-424, l.1292-1316, l.1797-1870; `server/lib/nebu/matrix/event_dispatcher/server.ex`
  l.160-228, l.436-456, l.805-892, l.1336-1456, l.3390-3440, l.3850-4048, l.5627-5720, l.7216-7388, l.7873-7930, l.7947-8022;
  `server/lib/nebu/web/router/protected.ex` l.596-611, l.1539-1591, l.2474-2492, l.3111-3179; `server/lib/nebu/web/rate_limit_tiers.ex`;
  `server/lib/nebu/compliance/audit_writer.ex` l.164-200; `server/lib/nebu/matrix/event_size.ex`.
- Stories: `create-room-presets-power-levels-topic.md` (D7, D8), `create-room-invites-direct.md` (D9), `event-size-limit.md` (D6),
  `member-event-prev-content.md` (D3 predecessors), `moderation-routes-atomic-ban.md` (D1-D3, D11, D13, `fr` Oracle note).
- Follow-ups: `eq`, `er`, `fr`, `ad`, `bf`, `eu`, `fe`, `fp`, `fq`, `fs`, `ft` in `docs/stories/oauth-broker/follow-ups.md`.
- Conventions: `.claude/rules/matrix-conventions.md` (crash / restart test), `skills/nebu-conventions/cluster-safety/SKILL.md`,
  `docs/architecture/08-concepts.md` "Audit Logging".

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev-story, pipeline step 4, cycle 0).

### Debug Log

- Starting point: the throwaway ATDD reference (`scratchpad/atdd/powerlevels/ref`), read for shapes and rewritten. Not taken over: the
  separate `@sql_update_power_levels_column` (the transaction reuses `@sql_set_power_levels`: one column statement in `Room.DB`), a
  `latest_power_levels_identity/1` absence treated as "no previous event" (here a db module without the read is `:unknown`: the change
  rules still apply, only the stamp floor is missing), the `rescue Nebu.Matrix.Error` re-raise of the after-freeze check (an own
  `postcheck_levels!/2`), a separate levels event builder (the member builder became `signed_state_event/6`, shared), the
  `%{"_json" => _}` decode in the dispatcher (the non-object body check is a router body check for this type, D2 allows it before the
  room decision), the dispatcher's `:sender_not_joined` mapping without errcode (explicit `M_FORBIDDEN` everywhere, DEV-3).
- `PowerLevels.check_change/3`: alterations compared on the RAW maps, the compared values are the NORMALISED ones (D4 (b)): a legacy
  string threshold that is present counts as its default (an alteration of `"ban": "0"` by a sender at 40 is `:above_own_level`, the
  default 50 > 40), a legacy string `users` / `events` value counts as absent.
- The no-op compares the decoded maps (`content == state.power_levels`): key order never matters, `50` vs `50.0` differ (the float is
  refused by the shape check before).
- Q-pl (07-deployment) checked in a rolled-back transaction on the throwaway database (`nebu-oauth-pg`, `BEGIN` ... `ROLLBACK`) with six
  fixture rows: `!qpl_ok` (valid, events[PL] present) not listed; `!qpl_empty` (`{}`) "no content"; `!qpl_flt` (`"kick": 50.0`),
  `!qpl_str` (`"ban": "0"`), `!qpl_usr` (a users value `"100"`) "non-integer value"; `!qpl_noev` (`events: {}`) "no
  events[m.room.power_levels]". 5 rows, `ROLLBACK` confirmed (no fixture row remains).
- Verification (elixir 1.20, `--warnings-as-errors`, `MIX_BUILD_PATH=/tmp/nebu_build` in the container):
  * new suites: `power_levels_unit_test`, `power_levels_writer_db_test`, `power_levels_http_test` 280/280 (after the fakes),
    `power_levels_concurrency_test` green in the full integration run; all 23 docs suites green;
  * full unit run without a database (CI `test-unit-elixir`): 49 failures before the re-pins (all listed in the Change Log), after
    them the changed suites 451/451; the final full no-database run 6225 passed, exit 0 (an earlier one passed every test but
    aborted on three 1.20 type warnings "the following pattern will never match" in fakes whose `set_power_levels/2` always fails:
    their `apply_power_levels_change/3` calls it dynamically, `nebu_room_test` / `power_level_enforcement_test` `FailingWriteDB`,
    `upgrade_room_error_handling_test` `DBSetPowerLevelsError`);
  * full `--include integration` run (throwaway postgres, `regression_sync_load_test.exs` moved aside and restored): 9880/9911; 5
    failures were the AC16 re-pins (done afterwards, the five suites + two more green in a re-run, 307/308), 26 in the known families
    (AdminRoomsFallbackName 12, TraceMapNodeControls 3, TemporaryCapture 3, LogStore retention 1, WarRoom 1, AdminOidcLogin 3,
    AdminStaleRooms 1, MatrixSso 1, SsoLogin 1) and 1 MatrixClientCompat replaces_state (same-millisecond tie, `eu`). Each family file
    re-run in isolation on this code AND on a scratch copy of HEAD `07c831f7` (`git archive`): the same failures on HEAD
    (fallback name 12/13, trace map 3, temporary capture 2-3, retention 2, war room 1, sso 1, matrix sso 1; replaces_state 1 on HEAD
    as well), so none is caused by this story;
  * elixir 1.19: `mix compile --warnings-as-errors` clean (warnings only in deps), the 44 new / changed test files 1289 tests, 1
    failure (a `tick/0` timeout of `ModerationTestSupport` in AC2 (g), the sync tick flake `fj`); the three power-level suites again:
    0 failures.
  * test names: `namelen.py` over every test file: none above 240.

### Completion Notes List

- `Nebu.Matrix.Room.PowerLevels` (pure): `normalize/1`, `required_level/2` (`{:message | :state, type}` plus the old atoms),
  `validate_content/1` (the one shape validator, fixed texts), `check_change/3`, `valid_subset/1` (the upgrade copy), `all_levels/1`
  (the upgrade pre-check), `level?/1`, `null_text/0`; `can?/3` / `get_user_level/2` on the normalised view; `default_levels/0` with the
  eight D12 entries.
- `Room.Server.change_power_levels/4` (`:client` / `:internal`, `not_before:`), `set_power_levels/3` = the `:internal` wrapper;
  `{:ok, event_id, %{changed, previous, ts}}`; the stamp max(now, not_before, latest + 1); ONE `apply_power_levels_change/3`;
  in-memory levels / identity / `:pg.get_members/1` broadcast after the commit only. `send_event/6`: membership, level
  (`events[type]`), idempotency, archived. `apply_power_levels/4` and `emit_power_levels_event/3` are gone.
- `Room.DB`: `apply_power_levels_change/3` (lock timeout, `FOR NO KEY UPDATE` archived check, column, event; `{:error, _}` never raise),
  `latest_power_levels_identity/1`, `get_power_levels_json/1`.
- Dispatcher: the PUT branch (`set_power_levels_state/1`: empty state key, no lazy room creation for an unknown room, the D2 order in
  the room process, the 403 / 400 / 404 / 413 / 500 / 503 mapping, the audit row), `{:state, type}` + the `@` rule for the other types,
  `send_event/2` 403 texts, `set_power_levels/2` -> `:client`, createRoom 5b' + the in-effect lock-out simulation + step 6
  (`apply_initial_power_levels/4`), the upgrade (normalised permission level, pre-check 403 before the tombstone, authoritative column
  read + 500 after the freeze, initial levels at `L`, the copy after the bans, `power_levels_carried`). Exactly two
  `Room.Server.set_power_levels(` calls remain (createRoom step 3, the upgrade's initial levels); no `mode: :internal` in the dispatcher.
- Router: the `moderation` charge for this type first; a non-object body is `400 M_BAD_JSON` "Request body must be a JSON object".
  `Http.map_error/1`: the `M_UNKNOWN` + internal opt-in. `AuditWriter`: `room_power_levels_changed`.
- Fakes (AC14 (b)): `grep -rl "def set_power_levels" server/test` finds 47 suites (+ the new support file); the 24 of `@fake_suites`
  reach the writer and got a real `apply_power_levels_change/3` (the fake's own column write AND event insert, a failure of either is
  the change's failure; one per fake module: 32 modules); the other 23 (`admin_oidc_login_test`, `archive_room_test`,
  `audit_archive_ops_test`, `auto_join_*` (4), `get_event_test`, `get_room_state_lazy_restart_test`, `leave_room_test`,
  `personal_room_test`, `server_dedup_test`, `server_get_room_state_system_test`, `server_moderation_metadata_test`,
  `server_receipts_test`, `server_set_typing_test` (2), `sync_membership_partition_test`, `sync_test`, `update_room_settings_test`,
  `room_server_clustering_test`, `server_member_stamp_test`) never reach it (full unit run green). Upgrade rooms-db fakes with
  `get_power_levels_json/1` (D8, DEV-3): `upgrade_room_test.exs` `FakeDB` and `FakeDBWithName`, `upgrade_room_error_handling_test.exs`
  `BaseDB`.
- Docs: scope doc, 07-deployment (paragraph + Q-pl, moderation paragraph keeps `fr`), 08-concepts (tier row, audit action), CHANGELOG,
  follow-ups (`eq` / `er` / `fr` CLOSED, `fv`-`fz`, notes, id line "unused `ga` onward").
- Open for review: the e2e Run A (orchestrator); no `format_status/1` yet (`ft`, the new call carries content).

### File List

- `server/lib/nebu/matrix/room/power_level.ex`, `server/lib/nebu/matrix/room/server.ex`, `server/lib/nebu/matrix/room/db.ex`,
  `server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/matrix/http.ex`,
  `server/lib/nebu/compliance/audit_writer.ex`
- tests (staged by ATDD, unchanged): `power_levels_http_test.exs`, `power_levels_concurrency_test.exs`, `power_levels_docs_test.exs`,
  `power_levels_test_support.exs`, `room/power_levels_writer_db_test.exs`, `room/power_levels_unit_test.exs`, the 8 docs re-pins,
  `mix.exs`, `test_helper.exs`, e2e feature / steps / global-setup
- tests (dev re-pins and fakes): the 24 `@fake_suites`, `room/power_level_test.exs`, `matrix_client_compat_test.exs`,
  `create_room_presets_http_test.exs`, `create_room_initial_state_http_test.exs`, `spaces_state_events_integration_test.exs`,
  `space_edit_audit_test.exs`, `event_dispatcher/set_room_state_test.exs`
- docs: `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/08-concepts.md`, `CHANGELOG.md`,
  `docs/stories/oauth-broker/follow-ups.md`, this story

### Change Log

- 2026-10-20: story created (create-story, read-only premise check on HEAD `07c831f7`; Element 1.12.15 `/op` / `/deop` verified in the
  bundle of the local `nebu-oauth-element` image, nothing run); status ready.
- 2026-10-20: Oracle gate applied (`step-results/power-levels-enforcement/oracle-context.md`, no WRONG decision): D7 gained the generic
  required-level check D2 (2) at step 6 (override `users: {creator: 50}` + PL entry -> `400 M_INVALID_ROOM_STATE`) and the
  object-content / `@`-key precedence; labels added: D3 absent `users` = Nebu choice, spec ambiguous, Synapse parity (recalled); D8
  refusal above the upgrader's level = Nebu choice, "bans before copy" = the project's own Oracle note (non-spec); D12 = NON-SPEC /
  Synapse-derived with what the spec actually states (8-entry map recalled, not verifiable); D4 (c) / Q7 precision (`{}` content denies
  per spec, only NO PL event deviates); D2 / AC2 (f) the permanent lock-out pinned as spec-conformant, no last-admin guard (Q8); D9 the
  429 SHOULD `Retry-After`; D2 (6) the no-op checked last. S2 / D5 (a) / `fw` reworded: a `/send` redaction is stored as-is and
  DELIVERED (client effect in Element unverifiable; visual redaction of others' messages without `redact`), pinned by AC17 (n), `fw`
  priority raised, no enforcement here. New AC17 (a)-(p) (the sixteen missing tests) in `power_levels_http_test.exs`. Follow-up ids
  `fv`-`fy` and "unused `fz` onward" unchanged.
- 2026-10-20: ATDD ambiguities resolved (story aligned with the staged tests and the reference): AC9 (d) an entry omitting a
  `trusted_private_chat` invitee is `400 M_INVALID_ROOM_STATE` (rule 7), repeating him passes, D7 sentence corrected; AC7 (a) creator
  at 150; AC7 (d) equal levels = both `403`, nothing written (50 rounds) plus the analogue A 100 / B 60 / C 50; E2E aligned with
  `power-levels.feature` (alex's first PUT also sets `events["m.room.power_levels"]: 50`; the refusal texts); AC1 (b) unknown room =
  today's `403` and, for this route, no `rooms` row and no process; new follow-up **`fz`** (generic PUT state for an unknown room answers
  403 and lazily creates a `rooms` row), the id line becomes "`fv`-`fz`: power-levels-enforcement", "unused `ga` onward"; D10 the
  `500 M_UNKNOWN` "The power levels could not be changed" needs an opt-in in `Http.map_error/1` (Dev task); D5 (d) order decided:
  membership first, then level, idempotency, archived check; binding signatures recorded in Dev Notes; AC16 extended by the re-pins
  the reference needs. **Re-pin needed (test agent): "`fz` onward" -> "`ga` onward"** in `create_room_invites_docs_test.exs`,
  `create_room_presets_docs_test.exs`, `event_size_limit_docs_test.exs`, `member_prev_content_docs_test.exs`,
  `membership_write_limits_cycle1_docs_test.exs`, `membership_write_limits_docs_test.exs`, `moderation_routes_docs_test.exs`,
  `sync_membership_partition_docs_test.exs`, and in `power_levels_docs_test.exs` ("`fv`-`fy`" -> "`fv`-`fz`", the `fz` row pinned,
  "`fz` onward" -> "`ga` onward").
- 2026-10-20: test review applied (`step-results/power-levels-enforcement/test-review-findings.md`): MINOR-10 the after-freeze
  pre-check of the upgrade is `500` with a fixed text (old room tombstoned + archived, no new room with a level above the upgrader's,
  failure audit row keeps `new_room_id`): D8, AC10 (c), the AC15 upgrade-row note; MINOR-7 the D2 order (membership, level, shape)
  holds at the HTTP level, no dispatcher shape check before the room decision: D2, AC1 (b) reordered with the two pinning cases, Dev
  Notes; MINOR-15 the exact label strings of `power_levels_docs_test.exs` (l.144-153, 183-185, 192, 210) quoted verbatim in AC15 (a),
  "deviation" never in the createRoom row (the default `events` map is "divergence" / "Nebu choice"), the moderation paragraph keeps
  `fr` and "carried (story power-levels-enforcement)"; DEV-1..DEV-6 added to Dev Notes; AC16: Change Log old -> new per test, reviewed
  before verify.
- 2026-10-20: dev-story (cycle 0): implementation, docs, fakes. **AC16 re-pins (old -> new, no assertion removed without replacement):**
  * `room/power_level_test.exs` "default_levels/0 returns map with all required default keys": `events == %{}` -> the eight D12 entries
    (the other eight assertions and "exactly nine keys" unchanged).
  * `room/power_level_enforcement_test.exs` "default_power_levels/0 is callable ...": `events == %{}` -> the D12 map.
  * `event_dispatcher/create_room_presets_test.exs` AC11 "events[type] is the required level ...": `create_ok(users: {creator: 50})` ->
    `assert_rejected` (D12: history_visibility 100) PLUS `create_ok(users: {creator: 50}, events: {})` (the original subject: exactly at
    state_default) and the 49 case with `events: {}` (still rejected).
  * same file, AC11 "every applied initial_state entry counts, skipped types (encryption, power_levels) do not" -> "... (power_levels
    too), skipped types (encryption) do not": `create_ok(override events[PL] 101 + a PL entry)` -> `assert_rejected
    M_INVALID_ROOM_STATE` plus `create_ok(the override alone)`.
  * same file, describe "AC12 - ... still skipped (documented deviation)" (2 tests) -> "AC12 - ... is applied": the levels were the
    default / the override's merge and a warning was logged -> two levels events (step 3 = default / the merge, step 6 = the entry
    EXACTLY), the column = the entry, no "forbidden type" warning, no content in the log; with an override the entry wins.
  * `event_dispatcher/create_room_invites_test.exs` AC8 "planner table": `users_50 = %{users: {creator: 50}}` -> plus `"events" => %{}`
    (the invite-level subject unchanged: 50 ok, 51 refused).
  * `event_dispatcher/create_room_initial_state_test.exs` "cannot forge m.room.member, m.room.create, or m.room.power_levels" -> the PL
    entry removed, renamed "... m.room.member or m.room.create" (every other assertion kept, also "exactly one levels event, no @evil
    escalation"); NEW test: an escalating PL entry (`@evil` at 101) raises `M_INVALID_ROOM_STATE` with the fixed text.
  * `event_dispatcher/set_room_state_test.exs` allowlist loop: `[m.room.member, m.room.power_levels, m.room.create]` ->
    `[m.room.member, m.room.create]` (403 + nothing emitted unchanged).
  * `space_edit_audit_test.exs` AC3 "a forbidden event type (m.room.power_levels, m.room.member)" -> "(m.room.create, m.room.member)".
  * `room/nebu_room_test.exs` (D5 (d) membership first): 10 `send_event` tests join the sender first (happy path, determinism, both
    idempotency tests, 6-arg / 5-arg state_key, the four SEC-CRIT tests); the two "DB failure" send tests use the new
    `FailingWriteDBWithMember` (the sender already a member: a failing db cannot write the join) and additionally assert the error is
    not `:sender_not_joined` (so they still reach the failing write).
  * `room/send_event_archived_room_test.exs`: the 5 send tests join the sender first (every archived / ETS / idempotency assertion kept).
  * `matrix_client_compat_test.exs` "a joined non-power-user member cannot rename the room via the non-state send path": the member's
    `PUT /send/m.room.name` `200` -> `403 M_FORBIDDEN` "You do not have a high enough power level to send this event" (D12 + D5 (a)),
    PLUS the owner (at events[m.room.name]) sends the same message event (`200`) so the COALESCE guard (the name stays) is still
    exercised; the helper comment "m.room.power_levels has NO HTTP route" corrected.
  * `create_room_presets_http_test.exs` AC12 "still skipped" -> "is applied": the levels events are [default, the entry] (with an
    override: [the merge, the entry]).
  * `create_room_initial_state_http_test.exs` AC4: the PL entry removed from the skipped list (the four other types and the "no @evil
    in any levels event" check kept); NEW test: an escalating entry is `400 M_INVALID_ROOM_STATE` (exact body), no room.
  * `spaces_state_events_integration_test.exs` AT3 loop: `m.room.power_levels` removed (member / create stay 403).
  * fakes: `apply_power_levels_change/3` in the 24 `@fake_suites`; `get_power_levels_json/1` in the upgrade rooms-db fakes.
  * Not needed (green unchanged): `create_room_presets_http_test` lock-out tests, `upgrade_room*` (no seed above the upgrader),
    `event_size_backstop_test`, `sync_*`, `member_prev_content*`, `moderation_*`.
- 2026-10-20: dev-story fix cycle 1 (code review cycle 0: 5 MINOR + INFO; Kassandra cycle 0: M-1, L-1 - L-3, I-1, I-4):
  * Kassandra M-1 / review M2: the audit metadata names only the ten v10 keys in `changed_keys`; altered keys of the client's own
    choosing are counted as `other_keys_changed_count` (present only when > 0, so the AC12 "metadata exactly" pin keeps its three
    keys); the "no free text" claims of D11, 08-concepts, the scope doc and `AuditWriter` now say how that holds. Test: 1000 unknown
    keys -> `%{"changed_keys" => ["events_default"], "users_changed" => [], "users_changed_count" => 0, "other_keys_changed_count" =>
    1000}`, < 200 bytes, no key name in the row.
  * Kassandra L-2 / review M1: v10 rule 4 only when the stored levels are EMPTY too; stored levels without a levels event row keep the
    change rules (unit test with a db read `{:ok, nil}` and non-empty levels).
  * Kassandra L-1: after the freeze the requester's level is read again from the authoritative levels (>= 100 and no level above it,
    else the post-freeze `500`), and that level is his initial level in the new room (tests: a gap demotion A 100 -> 0 / B 50 -> 100
    is `500`, archived, audited, nothing carried; a gap change A 150 -> 120 starts the new room with A at 120).
  * review M3: five stale `:change_state` / allowlist comments in the dispatcher rewritten.
  * review M4: the internal writer validates `users` keys with the user-id grammar without the 255-byte bound and with an optional
    server-name port (`PowerLevels.validate_content/2`, `users_keys: :grammar`); clients stay strict; `valid_subset/1`'s silent drop is
    documented (docstring, scope doc upgrade row). Tests: unit (port id, 260-byte id; client refusal; grammar still refuses bad keys)
    and `create_room_test.exs` (a creator with a port / above 255 bytes gets 100 at step 3).
  * review M5: the current `notifications` value of the change rules is the STORED one (no phantom `room: 50`); unit tests.
  * review I1: the non-object body check refuses only the Plug wrapper (`"_json"` as the ONLY key); HTTP test with a `"_json"` key
    among the levels keys (200, stored). I2 / Kassandra I-4: `Http.map_error/1` passes only the fixed text (`power_levels_not_changed_text/0`),
    one raiser helper; tests (another `M_UNKNOWN` message is the generic 500; a grep pin: exactly one `errcode: "M_UNKNOWN"` in
    `server/lib`). I4: `space_edit_audit_test.exs` gains "m.room.power_levels through set_space_state/5: {:error, _}, no space_* audit
    row" (its `FakeDB` gains `get_room_status/1` -> `{:error, :not_found}`: the space has no rooms row in that fake world). I7: the
    archived check of `apply_power_levels_change/3` locks the row `FOR NO KEY UPDATE` (no share-lock upgrade; the lock_timeout and
    archived tests stay green). I8: Q-pl guards (`pg_input_is_valid`, `jsonb_typeof = 'object'`, reason "not a JSON object"); re-run
    in a rolled-back transaction with eight fixture rows (an unparsable `{bad` and a `[1,2]` row added): 7 rows listed with the expected
    reasons, the valid row not listed, `ROLLBACK` (0 fixture rows remain). I11: the stale first re-pin comment of the 8 docs suites
    replaced by one accurate line. I6: the scope doc's upgrade row notes the verbatim copy of `events: {}` (`fy`). I3 + Kassandra L-3
    noted in `fv`'s row, Kassandra I-1 in `fy`'s row (no new follow-up id; "unused `ga` onward" unchanged).
  * Re-pins (old -> new) of this cycle: none of an existing assertion. Added only: the new suites `power_levels_fix_cycle1_unit_test.exs`
    and `power_levels_fix_cycle1_test.exs`, one test each in `create_room_test.exs` and `space_edit_audit_test.exs` (plus that fake's
    `get_room_status/1`), and the comment-only edit of the 8 docs suites (I11).
- 2026-10-20: dev-story fix cycle 2 (cycle-1 delta reports):
  * Kassandra D-L1: the client writer accepts a `users` key under the relaxed grammar (port / above 255 bytes) when it is UNCHANGED
    from the stored content (`validate_content/2` `stored_users:`); added or changed such keys stay `400`; `valid_subset/2` keeps
    the upgrader's own relaxed-grammar entry (`keep_users`). Test (`power_levels_fix_cycle1_test.exs`, HTTP): a creator with a port
    PUTs the full content repeating his entry (200), adding a new port id is 400, the upgrade keeps him at 100. Scope doc upgrade row,
    docstrings (`PowerLevels`, `UserId.valid_shape?/1`) updated. **Re-pin (old -> new) of my own cycle-1 unit test**
    (`power_levels_fix_cycle1_unit_test.exs`, review M4): "the client writer refuses the same content" (an UNCHANGED stored
    relaxed entry -> 400) -> unchanged entries pass (200), a CHANGED entry and an ADDED one are 400; `valid_subset/2` keeps only kept
    ids (assertion added).
  * review MINOR-3: AC2 (g) of `power_levels_http_test.exs` no longer uses `invite_room/3` (its `join!/2` waits in the global
    `tick/0`): `make_room(.., "invite" => [b])` + `join_now!/2`, every assertion unchanged (the shared `tick/0` untouched).
  * review MINOR-1: the `space_edit_audit_test.exs` case is relabelled honestly ("for a space without a rooms row is refused"); the
    property itself is pinned on a real space in `power_levels_fix_cycle1_test.exs` (set_space_state/5 commits, exactly one
    `room_power_levels_changed` row, no `space_*` row).
  * review MINOR-2 + Kassandra D-I3: Q-pl now also checks the range (+-(2^53 - 1)) and the values of `events` / `notifications`
    (rewritten with CTEs; the guards stay). `power_levels_docs_test.exs` Q-pl test gains six fixture rows (`{bad`, `[1,2]`,
    `null`, a 2^53 `ban`, a string `events` value, a float `notifications` value): all listed, the healthy row absent. Evidence
    re-run in a rolled-back transaction with 12 fixture rows: 11 listed with the expected reasons, the healthy one not, `ROLLBACK`
    (0 rows remain).
  * review MINOR-4 + INFO: `FOR NO KEY UPDATE` in D10, the Completion Notes and the writer-db test comment; AC12 "exactly three keys
    when no unknown key changed"; `UserId.valid_shape?/1` doc; stale `Room.Server` header bullets and the 5-arg clause comment;
    the `users_changed` comment; the `_json` sole-key limitation comment; Kassandra D-I2: 08-concepts says exports must escape cells.
  * Verification of cycle 2: power-level suites + docs suites + changed old suites 698/698 (1.20); full no-database run 6236
    passed, exit 0; full integration run 9900/9927, the 27 failures all in the known families already compared with HEAD
    (AdminRoomsFallbackName 12, AdminOidcLogin 3, TraceMap 3, TemporaryCapture 3, LogStore retention 2, WarRoom 1, AdminStaleRooms
    1, MatrixSso 1, SsoLogin 1); 1.19: compile clean, 46 changed test files 1305 tests, 1 failure (the MatrixClientCompat
    replaces_state flake, `eu`, failing on HEAD as well); AC2 (g) green in the combined 1.19 run now.
- 2026-10-20: dev-story fix cycle 3:
  * Kassandra C2-L1 (CWE-697): every unchanged / altered / identical decision compares STRICTLY (`PowerLevels.same_json?/2`,
    `===` at every depth: `100.0` is not `100`): the unchanged check of a relaxed-grammar key, `altered?/3` of the change rules, the
    audit `altered_keys/2`, the no-op of the writer. Tests (`power_levels_fix_cycle1_unit_test.exs`): `same_json?/2` cases; a stored
    float 100.0 -> integer 100 is an alteration for a relaxed key, a strict key and a threshold key (`check_change/3`); through the
    writer a moderator at 50 cannot raise a stored 100.0 to 100 with or without an extra key (relaxed id: 400 strict-key rule, strict id:
    `:grant_above_own_level`), nothing written; removing a stored relaxed entry is allowed; identical content (same types) is still the
    no-op. C2-I1: the `users_changed` comment and 08-concepts say only a REMOVED stored entry can list a relaxed id; C2-I2 / I3: the
    scope upgrade row says other stored relaxed ids are dropped, 07 says Q-pl needs PostgreSQL 16+.
  * CI flake of the previous story's `moderation_concurrency_test.exs` AC7 (b) / (d) (`join: 401 M_UNKNOWN_TOKEN` mid-test, CI log
    ci_pl_b.log). Cause: `T.legacy_session!/3` defaults `expires_at` to now + 1 h, which is exactly the default lookahead of
    `Nebu.Matrix.Session.RefreshWorker` (60 min): every test session is a refresh candidate at once; it has no upstream refresh token,
    so the worker's next tick logs "confirmed upstream rejection, hard-invalidating session" and revokes it while the 50-round test
    still uses it (a long test spans a tick). Reproduced on a HEAD copy with `NEBU_MATRIX_REFRESH_WORKER_INTERVAL_MS=1000`: 401 +
    nine invalidations. Fix (test-side, invariants unchanged): `ModerationTestSupport.user!/1` and `long_user!/1` (shared by the
    moderation and power-level suites, `power_levels_concurrency_test.exs` included) and the cycle-1 `port_user!/0` mint sessions
    that expire beyond the lookahead (`session_expiry/0`: lookahead + 1 h). With the 1 s worker interval the moderation suite is 14/14
    and the five power-level suites + moderation concurrency 200/200 on a FRESH database; 5 consecutive runs on the reused database
    200/200 each.
  * Verification: power-level + moderation + docs suites 841/841 (1.20); full unit run 6240/6241 (one `rate_limit_take_all_test`
    GenServer.stop exit, green in isolation: 13/13, unrelated); integration and 1.19 runs: see the Debug Log of this cycle below.
  * Debug Log of cycle 3: full integration run 9897/9932: the known families (AdminRoomsFallbackName 12, AdminOidcLogin 3, TraceMap
    3, TemporaryCapture 2, WarRoom 1, AdminStaleRooms 1, MatrixSso 1, SsoLogin 1, LogStore retention 1, RateLimitTakeAll 1) plus 8
    `tick/0` timeouts in `moderation_fix_cycle1_http_test` (5) / `moderation_atomic_db_test` (3) (the global tick waits about 0.3 s for
    the newest event of the last 10 s, and `room_summary_integration_test` inserts events 60 s ahead: test-order dependent, `fj`):
    both files green in isolation (7/7, 27/27); `event_size_limit_http_test` AC11 (c) (a derived alias already taken on the reused
    database) fails on the HEAD copy too. 1.19: compile clean; the 46 changed files + moderation concurrency 1324 tests, 4 failures,
    all "expected m.room.canonical_alias" in `matrix_client_compat_test` (derived aliases already taken on the reused database: the
    same 4 fail on the HEAD copy under 1.19).

