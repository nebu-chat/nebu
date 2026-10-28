---
story_id: moderation-routes-atomic-ban
title: "Room moderation routes POST /rooms/{roomId}/kick, /ban, /unban, backed by ONE atomic room-process member writer (kick, ban, unban, the invite event, the decline), stamped max(now, latest member ts + 1), one PostgreSQL transaction per change, a revocation-safe join, bans carried into an upgraded room: closes the ban-route gate ex and ew, takes the revoke part of fb"
type: feature
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-19
branch: feature/migrate-to-oauth2
---

# Story: room moderation routes on an atomic room-process member writer (follow-ups `ex`, `ew`, the revoke part of `fb`)

As a room moderator using Element (or any Matrix client), I want `POST /_matrix/client/v3/rooms/{roomId}/kick`, `/ban` and `/unban` to work
as the Matrix spec (v1.18) and room version 10 define them, including the "Disinvite" of a pending invitee (a kick of an invited user),
so that I can remove, ban and unban users and withdraw invitations without asking an operator.
As a Nebu operator, I want every membership change that can race a ban (kick, ban, unban, the invite event, the decline, the join) to be
decided and written inside the room process, stamped strictly after the user's latest member event and committed in ONE database
transaction, so that no concurrent join, invite or decline can ever hide a ban or re-admit a removed user, and a failed moderation leaves
nothing half done.

Follows `create-room-presets-power-levels-topic` (Kassandra F-2 / F-3 / F-6, delta gate N-1 / N-1b / N-5 / N-6, I-x "unban checks the ban
level, not the kick level"), `create-room-invites-direct` (Kassandra M-1: the invite writer erases a concurrent ban's event order; D9 equal
DM levels), `sync-membership-partition` (D13 taken-back invitations, rule 4, the leave window), `member-event-prev-content` (D4 stamps,
review cycle 1 L-1: the BINDING gate test) and `event-size-limit` (gate item Kassandra #4: `reason` cap + `EventSize.check_stored/1`).
Closes `ex` (the gate for the ban route) and `ew`; takes from `fb` the kick / revoke of a pending invitee; takes from `eu` the write side
of kick / ban / unban and of the invite writer. **This is story 1 of 2** (split: see "Sizing and split").

## Premises verified (2026-10-19, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `891ed9ce`, read-only)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise (from the request) | Verified text | Verdict |
|---|---|---|---|
| S1 | bodies `{user_id, reason?}` | `client-server-api` `POST /rooms/{roomId}/kick`: `user_id` "Required: the fully qualified user ID", `reason` string "supplied as the reason on the target's updated m.room.member event"; `/ban`: same (`reason` "Added in v1.1"); `/unban`: same, `reason` "Optional reason to be included as the reason on the subsequent membership event" (v1.1). Responses: `200 {}` and `403` only ("A meaningful errcode and description error text will be returned"; examples: kicker / banner not in the room, kickee "not currently in the room", power level insufficient). | CORRECT. `M_NOT_FOUND` is NOT listed: the 404 for an unknown room is a Nebu choice (D6, parity with `/invite` and `/join`). `M_UNKNOWN` is never a planned answer (fixed texts). |
| S2 | "Matrix says rate limited yes" | All three endpoints: **"Rate-limited: No"**. | **WRONG.** The per-user `moderation` tier is a labelled Nebu DIVERGENCE from the endpoint flag (Oracle wording of rate-limits, correction (1): `M_LIMIT_EXCEEDED` is a common errcode any endpoint may return), D5. |
| S3 | v10 auth rules: sender PL >= kick / ban, target strictly lower | `rooms/v10` m.room.member: `leave` by another user: sender not joined -> reject; **target banned and sender < ban level -> reject**; sender >= kick level AND target level < sender level -> allow; otherwise reject. `ban`: sender not joined -> reject; sender >= ban level AND target < sender -> allow; otherwise reject. Every m.room.member branch ends in allow / reject, so the generic "event type's required power level" step (the `events` map) is NOT reached for member events. | CORRECT, plus a finding: an **unban (ban -> leave) needs BOTH the ban level AND the kick level**; today `unban_user/2` checks `ban` only (Kassandra delta gate I-x, unrouted then). D3. The per-type `events` map of `eq` is irrelevant for kick / ban / unban. |
| S4 | ban of a non-member allowed | `/ban` "If the user is currently in the room, also kick them"; the v10 ban rule has no target-membership condition. | CORRECT (pre-emptive bans). D4 (b). |
| S5 | unban only from ban | `/unban` "Unban a user from the room. This allows them to be invited ... and join". No rule says what an unban of a non-banned user does (v10 would read it as a plain `leave` by another user = a kick). | Spec silent on the endpoint: Nebu refuses an unban of a user whose latest membership is not `ban` (`403`), D4 (c). Labelled Nebu choice. |
| S6 | kick of an invitee = revocation | v10 `leave` by another user applies to any target state; the m.room.member transition table (Oracle member-event-prev-content): `invite -> leave` with `state_key != sender` = "revoked". | CORRECT. D4 (a). |
| S7 | kick of a banned / left user -> 403? | Endpoint 403 example "The kickee is not currently in the room". v10 would allow a kick of a banned user by a sender with the ban level (it IS an unban). | Nebu: `/kick` acts only on `join` or a valid pending invitation, everything else `403` (a banned target: `403` "use unban"), D4 (a). Stricter than the auth rules, conformant to the endpoint text. |
| S8 | "bans are carried on upgrade? Synapse copies bans" | `#room-upgrades` server behaviour: "the recommended state events to transfer are: m.room.server_acl, m.room.encryption, m.room.name, m.room.avatar, m.room.topic, m.room.guest_access, m.room.history_visibility, m.room.join_rules, m.room.power_levels. **Membership events should not be transferred** to the new room due to technical limitations of servers not being able to impersonate people from other homeservers." | The spec does NOT say bans are carried; it says membership events SHOULD NOT be (reason: impersonation over federation). Nebu carries bans as NEW ban events sent BY THE UPGRADER (no impersonation, no federation), Synapse parity (recalled, not verifiable offline). D11; the Oracle gate must confirm. Power levels are recommended and are NOT carried today (pre-existing, new follow-up `fr`). |
| S9 | "the forget semantics" | Oracle sync-membership-partition: `POST /forget` 400 "The user has not left the room"; forgotten rooms stay hidden "until the user re-joins, is re-invited, or knocks"; `rooms.leave` = "left or banned". | Unchanged by this story: a kicked / banned user is not joined, so `forget` is allowed; a re-invite (after an unban) clears the forget (D7 of sync-membership-partition). Pinned by AC12 (e). |

### What Nebu does today (code)

| Question | Verified state |
|---|---|
| The three internals | `EventDispatcher.Server.kick_user/2` (server.ex l.6155), `ban_user/2` (l.6244), `unban_user/2` (l.6365): **no caller in `server/lib`**, called only by tests (`create_room_presets_http_test`, `join_room_test`, `sync_membership_partition_http_test`, `member_prev_content_http_test`, `matrix_client_compat_test`, `room_summary_integration_test`, `create_room_invites*`, `membership_write_limits_http_test`, `server_moderation_metadata_test`). No route in `protected.ex` (grep: no `kick` / `ban` path). |
| Where they decide and write | ALL in the CALLER's process: `lookup_room` (404 when the process is not running; no lazy start), `get_state`, `MapSet.member?(state.members, caller)`, `PowerLevels.can?(.., :kick / :ban)`, `require_higher_power_level!/3` (l.6325, strictly higher, errcode `M_FORBIDDEN`), `reject_invitation_strict!/2` (l.2673, two tries then 500), then `Room.Server.remove_member/2` and an inline sign + `insert_event` stamped **`now_ms()`** (NOT `max(now, latest + 1)`), broadcast with `:pg.get_local_members/1`. Ban: remove -> reject -> event -> remove AGAIN (`remove_member_for_ban!/2`, l.6338). |
| kick of a non-member / invitee | `remove_member` -> `{:error, :not_member}` -> **`404 M_NOT_FOUND`** "target user is not a member of this room" (mapped to "Room not found" by `Http.map_error/1`): a pending invitee CANNOT be kicked (`fb`), and the 404 is not the spec's 403. |
| unban | no check that the target is banned (an "unban" of anyone writes a `leave` by the caller = an unauthorised kick of a member with only the ban level); no kick-level check (S3); no `reason` (`Core.UnbanUserRequest` has no `reason` field: `server/lib/pb/core.pb.ex` l.458). |
| Refusal texts | `permission_denied` WITHOUT errcode is mapped to the fixed text "You are not a member of this room" (`Http.map_error/1` l.80), so "insufficient power level for kick / ban / unban" reach the client as "You are not a member of this room" (misleading). Only `require_higher_power_level!/3` carries `errcode: "M_FORBIDDEN"` and its own text. |
| `reason` | `request.reason != ""` -> put into the content as is: no type, NUL or byte cap; the event is built and signed WITHOUT `EventSize.check_stored/1` (event-size-limit gate item #4, verified). A NUL in a JSONB string is refused by PostgreSQL (500 today). |
| Audit | kick / ban / unban write **no audit row**. Joins write `room_joined` (best effort, after the join, l.1873); the Admin force-add / remove write `member_added` / `member_removed`. `Nebu.Compliance.AuditWriter` drops an action that is not in `@known_actions` (`audit_writer.ex` l.164; 08-concepts "Audit Logging": "a new audited operation MUST add its action there"). |
| Room.Server join (the atomic ban check) | `handle_call({:join, ..})` (room/server.ex l.318): `check_not_banned/2` (l.587) reads `latest_member_event/2` IN the process, refuses `ban`, then `insert_member`, then `emit_membership_event/4` stamped `max(now, latest + 1)` (member-event-prev-content D4). The event write is non-fatal (member applied, warning). Leave (l.367): in process, stamped likewise. `remove_member` (l.393): in process, no event. |
| The join decision outside the process | `authorize_join!/2` (server.ex l.1936) runs in the caller: `room_member?`, `join_banned?` (`get_member_membership/2`), the join rule state, and for a refusal that an invitation could grant: `invitation_valid!/2` (l.1973: pending row via `InviteDB.pending_invitation/2` AND no `leave` at least as new as `invited_at`, D13). Then `Room.Server.join/2` re-checks ONLY the ban. **Consequence (new, introduced by a kick-revoke route):** a revocation (row rejected + `leave` by the kicker) that commits between `invitation_valid!/2` and `Room.Server.join/2` is NOT seen by the room process: the revoked invitee joins an invite-only room. D9 closes it. |
| The invite writer (Kassandra M-1) | `do_invite!/5` (l.2816): member check against a snapshot, `invite_target_membership!/2` (ban) and `invite_pending!/2` outside the process, the caps, then `write_invitation!/4` (l.2928): the row (`insert_invitation_capped/4`, PostgreSQL advisory locks + `lock_timeout 2s`, `invite_db.ex` l.192) and then `emit_state_event_at/6` (l.7689) in the CALLER, stamped `max(now, not_before)` (POST /invite: `not_before 0`, i.e. `now`; createRoom step 8: the chain). A ban landing between the ban read and the event write is followed by the re-armed row and a NEWER `invite` event: verified, as `ex` / M-1 say. |
| The decline writer | `leave_room/2` -> `leave_guard_membership!/2` (l.2573, ban -> 403) -> `Room.Server.leave` -> `{:error, :not_member}` -> `leave_without_room_process/3` (l.2597): `delete_member`, `reject_invitation`, then `emit_decline_event/2` (l.7110) in the CALLER, stamped by `member_event_stamp/2` (l.7141, a separate read). A ban committed between the guard and the decline write is followed by a NEWER self-`leave`: the ban is hidden (F-1 class, latent until the ban route exists). Same fix as the invite writer (D8). |
| Member-event writers outside Room.Server (grep `"m.room.member"`) | invite (l.2948), kick (l.6197), ban (l.6290), unban (l.6400), decline (l.7113), `create_personal_room` (l.6103, a brand-new personal room: nothing can race it). Everything else goes through `Room.Server` (join, leave). |
| Rate limits | `Nebu.Web.RateLimitTiers`: `create_room {10, 20}`, `invite {20, 50}`, `join {12, 30}`, env `NEBU_RATE_LIMIT_<TIER>_PER_MIN / _BURST` (`config/runtime.exs` l.~120-128, `docker-compose.yml` l.~110-115); charged FIRST by `with_membership_charge/3` (protected.ex l.1426) before the body checks. |
| Upgrade | `upgrade_room/2` (l.7178): power check (>= 100 in the old room), tombstone in the OLD room FIRST, new room: create, creator join, DEFAULT levels + upgrader 100 (old levels are not carried), `copy_state_events/3` (excludes `m.room.member`, power levels, ...), then row-only invitations for the old MEMBERS (banned users are not members, so they are not invited), archive. **No ban is carried** (`ew`, verified): in a copied `public` room a user banned in the old room joins freely. |
| Transactions and seams | Room processes read through `db_module()` (`:room_manager, :db_module`), the dispatcher through `messages_db_module()` / `rooms_db_module()` / `db_module_invite()`; every unit suite that exercises these paths injects ONE fake for the room and message seams (`join_room_test`, `invite_user_test`, `create_room_invites_test`, `server_moderation_metadata_test`), so a write that moves into the room process stays in the same fake. `Room.DB` and `InviteDB` use `Ecto.Adapters.SQL.query(Nebu.Repo, ..)`, so statements run inside a `Nebu.Repo.transaction/1` in the SAME process share its connection (the room process can run a real multi-statement transaction). The integration tests run against a real database WITHOUT the Ecto sandbox (no `Sandbox` in `test_helper.exs`). |
| Element facts (recalled, not verified in the bundle) | Element's member panel "Remove from room" / "Ban" / "Unban" and "Disinvite" call matrix-js-sdk `kick` / `ban` / `unban` (the Disinvite of a pending invitee is a `kick`); the composer accepts `/remove` (alias `/kick`), `/ban`, `/unban <user-id> [reason]`. Element's "Banned users" list in Room settings is built from the room STATE: Nebu's `build_state_events/3` lists only joined members, so after a fresh initial sync the list is empty (the remaining `fb` work, story 2). |

### Sizing and split

- **Story 1 (THIS story, large: about 900 lines in `server/lib` plus the largest real-DB concurrency suite of the epic; the size of
  sync-membership-partition):** `Room.Server` gains the member writer (moderate / write_invite / write_decline, the join basis check:
  about 350 lines), `Room.DB` one transactional write and one read (about 90), `EventDispatcher.Server` (kick / ban / unban become thin
  wrappers, the body helper, the invite and decline routing, the join retry, the upgrade ban copy, the audit rows: about 300 net, the old
  inline writers are deleted), `protected.ex` three routes (about 80), the tier (about 25 incl. runtime / compose), the AuditWriter actions.
  No migration. One new e2e feature with two scenarios.
- **Story 2 (NOT written here; next story, proposed slug `membership-state-model`, closes the rest of `fb`, decides `et`):** the joined-only
  state model (`build_state_events/3`, `/members`, `/initialSync` list the latest member event of every user with `invite` / `ban` (and the
  spec's "leave" where required), so Element's "Banned users" list and the member list survive an initial sync), `upgrade_room` writes real
  invite events instead of row-only invitations (a DM partner in an upgraded room is marked direct again), the Admin member list shows
  banned users and the owner decision on an Admin unban (`et`). Medium size, no new route.
- Split out as follow-ups (see below): `fq` (`PUT .../state/m.room.member` stays refused), `fr` (upgrade does not carry power levels).

## Decisions

- **D1 (ONE member writer: the room process).** Every membership change that a ban can race is decided AND written inside
  `Nebu.Matrix.Room.Server` (`handle_call`), so all of them are serialised per room (`Horde.Registry`, one process per room, cluster-safe):
  (a) `moderate(room_id, action, sender, target, reason)` for `:kick | :ban | :unban` (D2-D4); (b) `write_invite(room_id, inviter, invitee,
  content, not_before)` for the invite EVENT of `POST /invite` and `createRoom` step 8 (D7); (c) `write_decline(room_id, user_id)` for the
  self-`leave` of a declined invitation (D8); (d) the existing `{:join, ..}` gains the basis check (D9); the existing `{:leave, ..}` is
  unchanged (a member's self-leave; a banned user is not a member there, D8 (b)). After this story the only member-event writers outside the
  room process are `create_personal_room` (a new room) and the archived-room fallback of the decline (D8 (c)): pinned by a source test
  (AC16). This is the smallest correct design for Kassandra M-1: the invite caps and the advisory-lock row write STAY in the caller (moving a
  2-second `lock_timeout` into the room process would stall every message of the room), only the final ban check + event stamp + event
  insert move in. The alternative "an authoritative ban record read by join and invite" was rejected: a second source of truth next to
  the events (migration, backfill, two writers to keep consistent) for the same guarantee.
- **D2 (`moderate/5`: decisions inside the process, first failure wins).** (1) sender in `state.members` else `:sender_not_joined`;
  (2) level: kick `>= kick`, ban `>= ban`, unban `>= ban` AND `>= kick` (S3) else `:insufficient_level`; (3) `level(target) < level(sender)`
  else `:target_not_lower` (the existing rule, now in the process; self-moderation is always refused: equal level. Oracle labels: a
  self-KICK refused this way is a **Nebu choice** (v10 would allow a self-leave; the user's own `POST /leave` is the path), a self-ban is
  refused by v10 itself, a self-unban is impossible because a banned sender is not joined); (4) ONE read of the
  target's latest member event (`db_module().latest_member_event/2`, now also returning `event_id`) and, for a kick of a non-member, the
  pending invitation (`pending_invitation/2` through the same db module): a failing read is `:membership_unavailable` (fail closed, 500,
  nothing written); (5) the target-state rule (D4); (6) the event: content `{"membership": "leave" | "ban"}` plus `"reason"` when given
  (D10), `sender` = the moderator, `state_key` = the target, `origin_server_ts = max(now, latest.origin_server_ts + 1)` (latest = the
  target's latest member event read in (4); none: `now`): the **binding stamp rule of `ex` (L-1) for kick, ban AND unban**; then
  `EventSize.check_keys/3` and `EventSize.check_stored/1` on the signed canonical bytes BEFORE signing further (`:event_too_large`, 413,
  nothing written); (7) the write (D3); (8) after the commit: the in-memory `members` / `member_identity` update, the broadcast
  `{:new_event, signed}` to `room:<id>` and, for kick and ban (incl. a revocation), `{:new_leave, room_id}` to `user:<target>`, both
  through `:pg.get_members/1` (cluster-safety; partial progress on `fe`); reply `:ok`. Levels come from `state.power_levels` (the process
  state is the authority; levels cannot change today, `eq`).
- **D3 (atomic write, failure semantics: all or nothing; closes N-6).** New `Nebu.Matrix.Room.DB.apply_member_change(room_id, user_id,
  signed_event | nil, opts)` runs in ONE `Nebu.Repo.transaction/1` (in the room process): `remove_member: true` -> the existing
  `delete_member` statement (soft delete, sets `left_at`; "not a member" is not an error), `reject_invitation: true` -> the existing
  `InviteDB` reject statement (a no-op without a pending row), then `insert_event` of `signed_event` (when not nil). Any failing statement
  rolls the whole transaction back: `{:error, reason}` -> the action answers `500` with a fixed text and a value-free ERROR log (room id and
  `db_error_class/1` only), the in-memory state is unchanged, no broadcast, no audit row; a retry starts from the unchanged state. There is
  no partial state any more: no "ban event written, member still in the set" (N-6), no "member removed without an event", no "leave event
  written, invitation still pending" (`fg` (h) cannot arise from these writers). Kick: remove (if joined) + reject + leave event. Ban:
  remove (if joined) + reject + ban event. Unban: reject + leave event. A GenServer call that exits (timeout 5 s, `:noproc`) is `503
  M_UNAVAILABLE` "The room did not answer, the change may or may not have been applied" (fixed text; `M_UNAVAILABLE` is NOT a spec errcode, kept for consistency with the existing 503s): the outcome is ambiguous only for the
  CALLER, never for the room (commit or rollback happened in the process); a retried ban is idempotent (D4 (b)), a retried kick answers the
  D4 (a) 403. The function is NOT a `DBBehaviour` callback; the room process calls it only when the db module exports it and otherwise
  answers `500` (`:unsupported_db_module`): **never** a fallback to separate statements (the real `Room.DB` always has it; the unit fakes of
  the suites that moderate, invite or decline implement it: AC16 lists them).
- **D4 (target-state rules; Nebu choices labelled).** The target's state is `join` (in `state.members`), `invite` (a pending row that was not
  taken back: the D13 predicate of `invitation_valid!/2`, now shared), `ban` (latest member event `ban`) or `none` (anything else, an
  unknown user included). (a) **kick**: `join` -> remove + reject + leave; `invite` -> **revocation**: reject + leave (sender = the kicker,
  `state_key` = the invitee, so `sender != state_key`); `ban` -> `403 M_FORBIDDEN` "The user is banned from this room: unban them instead";
  `none` -> `403 M_FORBIDDEN` "The user is not in this room" (S1 / S7). (b) **ban**: any state; `join` / `invite` / `none` -> the ban
  (pre-emptive bans of a local id that never joined or does not exist yet are allowed, no `users` read, so no existence oracle); `ban` ->
  **idempotent `200`**: no new event (a different `reason` is ignored: recorded, the first ban's reason stands), but the transaction still
  removes a member that a half state (typically a legacy N-6 leftover) left in the set and rejects a pending row (07-deployment Q-half);
  a target of ANOTHER server -> `403 M_FORBIDDEN` "Only users of this server can be banned" (a **Nebu choice**, v10 has no such rule; decided in the
  dispatcher before the room call: pure, like the invite path's local-domain rule; no federation, such a user can never join). (c) **unban**: `ban` -> reject + leave;
  anything else -> `403 M_FORBIDDEN` "The user is not banned from this room" (S5; a **Nebu choice**, v10 would treat it as a kick). The unbanned user needs a new invitation in an
  invite-only room (unchanged, F-5).
- **D5 (rate limit: a new `moderation` tier).** One unit per `POST /kick`, `/ban`, `/unban`, charged FIRST (before the body checks, like
  `invite` / `join`), default `{30 per minute, burst 60}` (a moderator clearing a spam wave bans dozens of accounts; the burst / rate <= 60
  invariant holds), env `NEBU_RATE_LIMIT_MODERATION_PER_MIN` / `NEBU_RATE_LIMIT_MODERATION_BURST` (strictly positive int64, otherwise the
  default; `invalid_settings/0` covers it), passed through by `docker-compose.yml` (empty = default), `NEBU_RATE_LIMIT_DISABLED` disables it.
  Not the `invite` tier: a moderator who invited 50 people must still be able to ban, and the two budgets are tuned separately. A divergence
  from "Rate-limited: No" (S2), labelled as such in the scope doc. Internal callers (the upgrade ban copy, D11) are not charged.
- **D6 (route order and body validation; parity with `POST /invite`).** For each route: (1) the `moderation` charge (429 with
  `Retry-After` + `retry_after_ms`); (2) a body that is not JSON `400 M_NOT_JSON`, JSON that is not an object `400 M_BAD_JSON`; (3)
  `user_id`: absent or `null` `400 M_MISSING_PARAM` "user_id is required", not a string `400 M_BAD_JSON` "user_id must be a string", longer
  than 255 bytes or not `UserId.valid?/1` `400 M_INVALID_PARAM` "user_id is not a valid user id" (the existing invitee shape helper, shared:
  `moderation_body!/1` next to `invite_body_user_id/1`); (4) `reason` (D10); (5) the sender guard of event-size-limit D2 (d): a session user
  id above 255 bytes `403 M_FORBIDDEN` (the existing `EventSize.check_keys/3` + `key_error/2`); (6) `call_core`: the room (`lookup_room/1`:
  a room whose process is not running or that does not exist is `404 M_NOT_FOUND` "Room not found", exactly like `/invite` and `/join`
  (a **Nebu choice**: the spec lists only 403; a non-member can tell an existing room (403) from an unknown one (404), the same accepted
  existence oracle as `/invite`, 64-bit random room ids); no
  room process is started and no `rooms` row is created for an unknown id); for `/ban` the local-domain rule (D4 (b)); then
  `Room.Server.moderate/5` (D2). Every refusal is a fixed text with `errcode` set explicitly (no client value echoed, no user id in a message
  or log); the spec's example wording is used: "You do not have a high enough power level to kick from this room." (and "ban", "unban"),
  "You are not a member of this room", "You cannot act on a user whose power level is not lower than yours" (existing). `200 {}` on success.
- **D7 (the invite writer: the ban check and the event in the process; closes Kassandra M-1).** `do_invite!/5` keeps its outside checks
  (member snapshot, banned 403, already-invited no-op, caps) and the row write (`insert_invitation_capped/4` with its advisory locks), then
  calls `Room.Server.write_invite/5` instead of `emit_state_event_at/6`. In the process: (1) inviter in `state.members` and `PowerLevels.can?
  (.., :invite)` (re-checked: cheap and authoritative); (2) invitee in `state.members` -> `:already_member`; (3) ONE `latest_member_event/2`
  read (fail closed); `ban` -> `apply_member_change(room, invitee, nil, reject_invitation: true)` (a banned user never holds a pending row,
  even one this call re-armed) and `:banned`; (4) the invite event stamped `max(now, not_before, latest.ts + 1)`, `EventSize` checks,
  `insert_event`, broadcast via `:pg.get_members/1`, reply `{:ok, event_id, ts}`. The caller maps `:banned` to the existing `403` "The invited
  user is banned from this room", `:already_member` / a lost inviter membership to the existing `403`s and, for a row THIS call created
  (`created_row?`), rejects the row again (the existing compensation of `handle_failed_invite_event!/4`, unchanged for `{:error, reason}` of
  the insert, the unique-violation "already invited" case included). createRoom step 8 uses the same call (its chain value is `not_before`;
  the wake-ups stay deferred, D9 of create-room-invites-direct). Every interleaving with a ban is now safe: a ban before the room call is seen
  by (3) and leaves no pending row; a ban after it is stamped after the invite event and rejects the row.
- **D8 (the decline writer in the process).** (a) `leave_without_room_process/3` keeps `delete_member` and the decision (write only for a
  pending invitation or a latest `join`), and writes the decline through `Room.Server.write_decline/2`: in the process the latest member
  event is read again (fail closed); `ban` -> `:banned` -> `403` "You are banned from this room" and NOTHING is written; a member ->
  `:member` (the caller answers as for a member leave, unreachable in practice); otherwise `apply_member_change(room, user, leave_event,
  reject_invitation: true)` (reject + self-leave in one transaction, stamped `max(now, latest + 1)`). (b) When the room process is not
  running and there is something to decline (a pending row or a latest `join`: the room exists), the process is started
  (`RoomSupervisor.start_room/1`) and (a) applies; nothing is started for a request with nothing to decline (an unknown room id never creates
  a `rooms` row). (c) Only when the process cannot be started (an archived room: `init/1` stops with `:normal`) the existing out-of-process
  write stays: no moderation can run concurrently there (moderation needs a running process). `emit_decline_event/2` keeps exactly that
  caller.
- **D9 (a revocation-safe join: the basis check).** `authorize_join!/2` returns the basis of its decision: `:any` when no invitation was
  needed (public rule, allow-room membership: a kick does not block a public join, a ban is checked in the process anyway), else
  `{:invited, event_id | nil}` = the `event_id` of the latest member event that `invitation_valid!/2` read (`nil` for a row-only invitation
  without any member event). `Room.Server.join/3` (the 2-arity stays for the internal joins = `:any`) compares, inside `check_not_banned/2`'s
  existing read, the CURRENT latest member event id with the basis; a difference is `{:error, :membership_changed}` and nothing is written.
  `join_room/2` then re-runs the whole decision ONCE (fresh reads) and joins with the new basis; a second `:membership_changed` is `503
  M_UNAVAILABLE` "The membership changed during the join, try again" (not a spec errcode, see D3) (only under a sustained loop of moderation, which the tier bounds). A
  revocation, a ban, a re-invite or an unban between the decision and the join is therefore always decided on fresh data.
- **D10 (`reason`: type, NUL, a byte cap, the size backstop).** Absent, `null` or `""` -> no `reason` key (unchanged semantics of `""`);
  a non-string `400 M_BAD_JSON` "reason must be a string"; containing U+0000 `400 M_BAD_JSON` "reason must not contain NUL" (PostgreSQL JSONB
  refuses it: today a 500); longer than **1024 bytes** (UTF-8, `byte_size/1`, NOT code points) `400 M_INVALID_PARAM` "reason exceeds 1024
  bytes". The 1024-byte cap and the NUL refusal are **Nebu choices** (the spec bounds only the whole event). 1024 bytes keep every moderation event far below 65 536 (user ids <= 255 bytes each, escapes at most 6x: < 7 KiB); the
  `EventSize.check_stored/1` backstop of D2 (6) is therefore unreachable through the routes and pinned by a direct `Room.Server` test.
  Applied identically to kick, ban and unban (`Core.UnbanUserRequest` gains `reason: ""`). The invite route's `reason` stays unread (`fa`
  (a), unchanged; the same helper is the obvious fix there later).
- **D11 (`ew`: bans are carried into the upgraded room).** In `upgrade_room/2`, right after the power check and BEFORE the tombstone (so a
  failing read changes nothing): a read `Room.DB.banned_members(old_room_id)` (since review cycle 2 only the cheap pre-check: cap,
  requester, carriability; the authoritative read follows the freeze, see below) -> the users whose latest member event is `ban` (the D3
  tie order of the partition, the shared SQL fragments, both JSONB forms), with the old ban's `reason` when it is a string that passes D10.
  After the new room's power levels are set and BEFORE `copy_state_events/3` (the join rule is copied there; before it the new room has no
  join rule = invite policy, nobody is invited yet, so nobody can join in between): one `Room.Server.moderate(new_room, :ban, upgrader,
  target, reason)` per banned user (the upgrader is at 100, every other user at the default 0: always strictly lower), not rate-charged. A
  failure of the read or of any ban copy fails the upgrade (500, the existing failure audit row of `room_upgraded`; nothing was written for
  a failed pre-tombstone read; for a failure after the tombstone the new room has no join rule and no invitations, nobody can join
  it, but the upgrade is PARTIAL: the old room is archived with its tombstone, see the review-cycle-2 / 3 notes below). The `room_upgraded` success row gains
  `"bans_carried" => n` (a count only). Label (S8, Oracle): a **deliberate deviation from a SHOULD NOT** ("Membership events should not be transferred", reason:
  impersonation over federation); Nebu does not transfer the old events but RE-ISSUES the bans as new ban events in the upgrader's own name
  (valid under v10: the upgrader is joined at 100, every target at the default 0; no impersonation, no federation), Synapse parity. Banned
  users of the old room are not members, so they get NO row-only invitation in the new room (ban -> invite "must never happen"; AC19 (j)).
  **Review cycle 2 (Kassandra L-5): freeze first.** The order is tombstone -> archive + stop the old room (both fatal) -> the ONE
  authoritative read of its bans and members -> new room (create, creator, levels) -> the bans -> `copy_state_events/3` -> invitations
  (minus the bans). The pre-tombstone read stays for the cap and the early fail-closed answer. An archived room refuses
  every moderation, invite-event and decline write (`Room.DB.apply_member_change/4`), also from a process that still runs; joins and member leaves are not covered
  (the process is stopped by then). Review cycle 3: before the tombstone the requester must be a member and not banned, and every ban
  must be carriable (cap, key limits); the same check runs again on the authoritative read.
- **D12 (audit: three new actions, best effort, value-free).** After a COMMITTED kick / ban / unban (not for a refusal, not for the
  idempotent ban no-op, not for the upgrade copies, which the `room_upgraded` row counts): `audit_writer_module().log(sender,
  "room_member_kicked" | "room_member_banned" | "room_member_unbanned", "room", room_id, %{"user_id" => target} (kick: plus
  "invitation_revoked" => boolean), "success")`, written by the dispatcher after the room call returns `:ok` (best effort like
  `room_joined`: a failed audit write is a value-free ERROR log and never undoes or fails the action). The three actions are added to
  `AuditWriter.@known_actions` (without them the rows are silently dropped: 08-concepts). The `reason` is NOT copied into the audit metadata
  (free text of a user, it lives in the signed event; No Sensitive Data in Logs Law: never in a log line either). Refused attempts are not
  audited (consistent with refused joins, Kassandra I-x of create-room-presets). **Accepted residuals (review cycle 1, Kassandra L-1):**
  (a) a failing audit writer leaves a committed change without its row (the `room_joined` precedent); (b) when the 5 s room call times
  out while the room process is still inside its transaction, the room commits but the caller answers `503` and writes no audit row.
  In both cases the signed member event (the moderator as `sender`) is the forensic record; follow-up `fs` (the audit insert inside
  `apply_member_change/4`, or a reconcile on `:room_unavailable`).
- **D13 (what is taken from `eq` and what stays).** Taken: the v10 moderation level rules as a whole (kick / ban threshold, unban = ban AND
  kick, strictly-lower target, sender joined), evaluated in the room process; the invite level re-check in `write_invite/5`. Verified
  irrelevant here: the per-type `events` map (member events never reach that auth step, S3). Stays in `eq` (the next story, power levels):
  `events` / `redact` / `notifications` enforcement for other events, a power-level change route and its change rules, `er`, `et`. The
  `trusted_private_chat` equal level (both partners at 100) means neither partner can kick, ban or revoke the other: spec-conformant,
  documented, unchanged (`fb` note, D9 (f) of create-room-invites-direct).
- **D14 (the sync side is fed, not changed).** The events written here are ordinary member events, so the existing machinery delivers them:
  the kicked / banned user's `/sync` partition (rule table of sync-membership-partition) puts the room into `rooms.leave` ONCE with the kick
  / ban event as the last timeline event (no later event of the room is delivered, the `ez` fix); a revoked invitee's invitation disappears
  from `rooms.invite` and the room is a `rooms.leave` entry (D13 / rule 4, sender = the kicker); the kick / ban / unban events carry
  `unsigned.prev_content` / `prev_sender` / `replaces_state` of their predecessor (member-event-prev-content). The `user:<target>` wake-up of
  D2 (8) makes a long-polling target see it at once. No code change in `/sync`; AC12 pins the behaviour.

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused: ... `fq` onward" and a grep of `docs/` finds `fq` / `fr` only in that id line and in the event-size-limit story's re-pin note, no row: the new ids are `fq`, `fr`)

- **`fq` — `PUT /rooms/{roomId}/state/m.room.member/{userId}` stays refused.** The spec offers it as the alternative path for every
  membership change ("a user can directly adjust the target member's state by making a request to /rooms/<room id>/state/m.room.member/<user
  id>"); Nebu refuses `m.room.member` through PUT state (not allowlisted, 403). If it is ever allowed it MUST go through
  `Room.Server.moderate/5` / the member writer of story moderation-routes-atomic-ban (never `emit_state_event_at/6`), with the same rules,
  tier and audit. Source: this story (S1). Non-gating.
- **`fr` — `upgrade_room` does not carry the power levels.** The new room gets the default levels plus the upgrader at 100 (`copy_state_events/3`
  skips `m.room.power_levels`, which the spec recommends to transfer), so the old room's moderators lose their level and only the upgrader
  can kick / ban there; together with `ew` (closed: bans are carried) this is the remaining moderation gap of an upgrade. Fixing it needs the
  power-level change rules of `eq` (a copied map must not grant the upgrader less than he has, or anyone more than the old room did).
  **Binding for the fix (Oracle):** the bans (D11 of story moderation-routes-atomic-ban) must still be issued BEFORE a copied `users` map
  could raise a banned user to a level >= the upgrader's 100 (otherwise the ban copy is refused by the strictly-lower rule and the upgrade
  fails). Also open here: the spec's SHOULD to LOWER the old room's power levels after the upgrade (`events_default` / `invite` to the
  greater of 50 and `users_default + 1`) is not done (the old room is archived and its process stopped instead).
  Source: this story (premise "Upgrade"), Oracle gate. Non-gating.
- **Story 2 (`membership-state-model`, closes the rest of `fb`, decides `et`)**: see "Sizing and split". No new id: `fb` and `et` are the rows.
- Notes (no new id): `ex` CLOSED; `ew` CLOSED; `fb` (the revoke is done, the state model remains: story 2); `eu` (write side of kick / ban /
  unban, the invite writer and the decline done; PUT state, `create_personal_room` and the join-rule slots stay); `eq` (D13); `et` (an Admin
  unban stays an owner decision, story 2; until then: Element / the API); `fi` (c) (an inviter with the kick level can now withdraw a
  pending invitation); `fg` (f) (the Admin removal stays a self-leave; `moderate/5` is the natural target once the Admin is a member with
  power; (h) cannot arise from kick / ban / decline any more); `fe` (the new writers use `:pg.get_members/1`; the remaining node-local
  senders are listed there); `fa` (a) (`reason` on `/invite` still unread; D10's helper fits); `fc` (the stamps `latest + 1` can inherit the
  clock lead of the previous member event, the (d) class); `fp` (pre-emptive bans add one state slot each, bounded by the `moderation`
  tier and the ban level); the event-size-limit notes on `ex` (EventSize, `reason` cap) are satisfied.

## Acceptance Criteria

Test files are named in "Acceptance Tests". "Real DB" = the real `Nebu.Repo`, `Room.Server` under `Horde`, `Room.DB` / `InviteDB`, through
`Nebu.Web.Router` where the AC says HTTP (`@moduletag :integration`, random users and rooms). Fakes are allowed only where an AC says
"unit"; **every concurrency and atomicity claim is proven on the real database** (fakes hid the N-1 bug before).

1. **The three routes (HTTP real DB).** (a) `POST /_matrix/client/v3/rooms/{roomId}/kick`, `/ban`, `/unban` exist (path room id
   `URI.decode_www_form`ed like `/invite`), answer `200 {}` (`application/json`) on success, and are no longer `404 M_UNRECOGNIZED`.
   (b) D6 order, first failure wins, each as its own test with nothing written (no `events` row, no `room_invitations` change, member set
   unchanged): empty bucket -> `429 M_LIMIT_EXCEEDED` with `Retry-After` and `retry_after_ms` even for a malformed body; non-JSON -> `400
   M_NOT_JSON`; `[1]` / `"x"` -> `400 M_BAD_JSON`; `{}` and `{"user_id": null}` -> `400 M_MISSING_PARAM`; `{"user_id": 5}` -> `400
   M_BAD_JSON`; `"@bad id"`, `"alice"`, a 256-byte id -> `400 M_INVALID_PARAM`; then the D10 `reason` cases; a 256-byte SESSION user id ->
   `403 M_FORBIDDEN` (the event-size-limit text); an unknown room id -> `404 M_NOT_FOUND` "Room not found" AND no `rooms` row exists for it
   afterwards; a room whose process is not running -> `404` (parity with `/invite`, pinned). (c) Every error body is exactly `{"errcode",
   "error"}` with a fixed text that contains neither the target id nor the `reason`. (d) The 3pid keys or any other unknown body keys are
   ignored (only `user_id` and `reason` are read).
2. **The `moderation` tier (unit + HTTP real DB).** `RateLimitTiers.moderation/0` returns `{30, 60}` by default and the configured pair
   (env through `runtime.exs`, the invariants of the module: burst / rate <= 60, a broken pair falls back and is named by
   `invalid_settings/0`); `docker-compose.yml` passes both variables (empty = default; a docs / config test pins the two names); with
   `rate_per_min 1, burst 2` the third `/ban` of a user is `429` (any of the three routes draws from the SAME bucket), another user is not
   affected, and the invite / join buckets are untouched (and vice versa); `NEBU_RATE_LIMIT_DISABLED=true` disables it.
3. **Authorization (HTTP real DB; the v10 rules of D2).** For each of kick, ban, unban: a sender who is not joined (never joined, left,
   banned, only invited) -> `403` "You are not a member of this room"; a sender below the action level -> `403` "You do not have a high enough
   power level to <action> from this room." (unban: a user at `ban` level but BELOW `kick` (override `{"kick": 75, "ban": 50}`, sender 60) is
   refused, at both levels allowed: S3); a target at an EQUAL or higher level -> `403` "You cannot act on a user whose power level is not
   lower than yours" (PL-50 vs PL-50, PL-50 vs the creator at 100, the sender himself); `trusted_private_chat`: neither partner can kick, ban
   or revoke the other (equal 100), a `private_chat` creator can (100 vs 0). Every refusal writes nothing (no event, member set, row
   and `room_members` unchanged, no audit row).
4. **Target-state rules and outcomes (HTTP real DB; D4).** (a) kick of a member: `room_members.left_at` set, the member is gone from the
   in-memory set, a pending row of him is rejected, ONE `m.room.member` event `{"membership": "leave"}` (+ `reason` when given) with `sender`
   = kicker, `state_key` = target; the target can re-join a `public` room, not an `invite` room without a new invitation. (b) **revocation**:
   kick of a pending invitee (with an invite event; and a row-only invitation written through `InviteDB` like `upgrade_room` does): the row
   is `rejected`, the leave event has `sender != state_key`, the invitee's `POST /join` is `403` "You are not invited to this room", his
   `/sync` no longer lists the room in `rooms.invite`; a taken-back invitation (D13) counts as `none`. (c) kick of `none` (never there, left,
   an unknown local id, a foreign id) -> `403` "The user is not in this room"; kick of a banned user -> `403` "The user is banned from this
   room: unban them instead"; the ban stays the latest membership. (d) ban of a member, of an invitee (row rejected), of a local user who
   left, of a local id that has NO `users` row (pre-emptive: the ban event exists, a later account with that id cannot join, `/invite` of it
   is `403`): `200`; ban of a foreign id -> `403` "Only users of this server can be banned"; no `users` read happens on the ban path (the
   statement-count / call test of the dispatcher). (e) ban of an already banned user -> `200`, no new event (event count unchanged, also
   with another `reason`), and when a legacy half state is seeded (an active `room_members` row + a pending row + latest `ban`, written
   directly) the call removes the row and rejects the invitation (repair) and still writes no event. (f) unban of a banned user -> one leave
   event (sender = unbanner, `reason` when given), a pending row rejected; the user can join a `public` room, needs a new invitation in an
   `invite` room; unban of a member / invitee / `none` -> `403` "The user is not banned from this room", nothing written. (g) `reason`:
   present on the event exactly as sent (multi-byte, 1024 bytes exactly accepted), absent for `""` / `null` / no key.
5. **Atomicity and failure semantics (real DB, D3).** (a) `apply_member_change/4` on the REAL `Room.DB` with an `insert_event` that fails
   INSIDE the transaction (an event whose `event_id` already exists: pre-insert the identical signed event, unique violation) after the
   member delete and the reject ran: afterwards the `room_members` row is still active (`left_at IS NULL`), the invitation is still pending,
   no new event exists; through `moderate/5` (a test db module that delegates every function to `Room.DB` and passes such a duplicating
   event, or an equivalent hook: record which) the answer is `500` "... failed" (fixed), the in-memory member set still contains the
   target, no broadcast reached a `:pg` test member of `room:<id>`, no audit row, the ERROR log names the room id and the SQLSTATE class
   only; a retry with a healthy db module succeeds. (b) A db module without `apply_member_change/4` -> `500`, nothing written, never the
   sequential fallback (unit). (c) A room process that does not answer (`:noproc` / timeout) -> `503 M_UNAVAILABLE` with the D3 text (unit).
   (d) After a committed ban the five sources agree: in-memory set, `room_members`, `room_invitations`, the latest member event (`ban`), the
   `/sync` partition of the target (leave class).
6. **Event order: the BINDING gate test of `ex` (L-1) and the stamp rule (real DB).** (a) **Gate test:** in a room the test owns, write the
   target's invite event 100 ms AHEAD of the clock (the createRoom chain or a direct insert with an `on_exit` delete; no other future-stamped
   rows, `fj`), the target joins (stamped invite + 1), the moderator bans AT ONCE: the ban event's `origin_server_ts` > the join's, the latest
   membership (`get_member_membership/2`, `latest_member_event/2` and the `/sync` partition) is `ban`, and the target's re-join is `403` "You
   are banned from this room". (b) The same with kick (latest `leave` by the kicker, re-join of an invite room `403`) and with unban after a
   ban that is itself ahead (latest `leave`, newer than the ban). (c) Every event written by `moderate/5`, `write_invite/5` and
   `write_decline/2` has `origin_server_ts >= latest + 1` of the target's slot at write time (a property over the suite's sequences: the slot's
   events sorted by `(origin_server_ts, D3 rank)` are in write order, no tie). (d) Under the OLD code the gate test fails (the dev records the
   red run in the Debug Log).
7. **Concurrency (real DB, many rounds; the heart of this story).** Each scenario runs at least 50 rounds with fresh users, the racing calls
   started together (`Task.async` with a barrier), and asserts the INVARIANTS after each round, never a particular interleaving:
   (a) ban vs N = 10 concurrent `POST /join` of the target in a `public` room: afterwards the target is NOT in the in-memory set, has no
   active `room_members` row, the latest membership is `ban`, the next `/join` is `403`; (b) ban vs 10 concurrent `POST /invite` of the
   target by different members (the invite route and createRoom's step-8 path through `write_invite/5`): afterwards no pending row, latest
   `ban`, a `/join` (invite room) `403`; every invite answered `200` was written BEFORE the ban (its event is older than the ban event),
   every later one is `403`; (c) ban vs the target's decline (`POST /leave` of a pending invitee): latest `ban`, no self-leave newer than the
   ban; (d) kick-revoke vs the invitee's `POST /join` (invite room): either the join won (the target is joined and the kick, if it came
   second, removed him again with a newer leave) or the revocation won (the join is `403`); never "revoked AND joined"; (e) ban vs the
   target's own `POST /leave` as a member: latest `ban`; (f) two moderators ban and unban concurrently: the final latest membership equals the
   last committed action and member set / rows agree with it. A failure prints the round's event sequence (no message content).
8. **The invite writer (D7; unit + real DB).** (a) unit: `do_invite!/5` no longer calls `emit_state_event_at/6` for the invite event;
   `write_invite/5` refuses a banned invitee (`:banned`, the row rejected through `apply_member_change/4`), a member (`:already_member`), a
   lost inviter (not joined / below `invite`); a row created by this call is rejected after any refusal, a pre-existing pending row only for
   `:banned`. (b) real DB: `POST /invite` and `createRoom` with `invite` answer exactly as before (the existing suites
   `create_room_invites_http_test.exs`, `membership_write_limits*`, `invite_user_test.exs` pass unchanged except the re-pins of AC18), the
   createRoom invite events keep their strictly increasing chain, the already-invited `200` writes nothing, the caps and the 503 lock
   timeout are unchanged. (c) The M-1 sequence made deterministic with a test db module that blocks between the outside checks and the room
   call: the ban commits in that gap -> the invite is `403`, no pending row, latest `ban`.
9. **The decline writer (D8; real DB).** (a) a pending invitee's `POST /leave` writes the self-leave through the room process (stamped after
   the invite), the row rejected in the same transaction; (b) with the room process STOPPED before the decline it is started and (a)
   applies; an unknown room id with nothing to decline starts nothing and creates no `rooms` row; (c) a deterministic gap test: a ban
   committed between `leave_guard_membership!/2` and the write -> `403` "You are banned from this room", no leave event; (d) an archived room
   keeps the old path (pinned).
10. **The join basis (D9; real DB + unit).** (a) unit: `Room.Server.join/3` with a basis whose event id differs from the current latest
    member event returns `{:error, :membership_changed}` and writes nothing; `:any` behaves as today; the internal joins (creator,
    upgrade, auto-join, Admin force-add through `join_room/2`) still work. (b) real DB, deterministic: a kick-revoke committed between
    `authorize_join!/2` and the room call (a test registry / db hook) -> the retry re-decides and answers `403` "You are not invited to this
    room"; a re-invite committed in that gap -> the retry joins; two changes in a row -> `503 M_UNAVAILABLE`. (c) The public join reads no
    invitation (the existing m-4 pin stays green).
11. **`reason` and the size backstop (D10; HTTP real DB + unit).** `{"user_id": .., "reason": 5}` / `[..]` / `{}` -> `400 M_BAD_JSON`; a
    reason with U+0000 -> `400 M_BAD_JSON`; exactly 1024 bytes (ASCII, and `"€"` x 341 + 1 ASCII byte) -> `200`, the stored event carries
    it; 1025 bytes (and 342 x `"€"` = 1026 bytes) -> `400 M_INVALID_PARAM` "reason exceeds 1024 bytes"; the same for all three routes. Unit:
    `Room.Server.moderate/5` called directly with a 70 000-byte reason (bypassing the router) -> `{:error, :event_too_large}`, nothing
    written, the dispatcher maps it to `413 M_TOO_LARGE`; the unban event carries the `reason`.
12. **The sync side is fed (HTTP real DB, D14).** (a) After a kick, the target's incremental `/sync` (long-poll started BEFORE the kick,
    returns within 2 s through the `user:` wake-up) has the room in `rooms.leave` with the kick event last (`sender` = kicker, `reason`),
    and a message sent after the kick is in no section of his later syncs; (b) the same for a ban (`membership: ban`); (c) a revoked invitee:
    the room leaves `rooms.invite`, appears once in `rooms.leave` with the revocation (sender = kicker); (d) the kick event in the kicker's
    `/sync` timeline carries `unsigned.prev_content = {"membership": "join"}` and `prev_sender` = the target, the revocation's
    `prev_content` is the invite (`prev_sender` = the inviter), the unban's is the ban; (e) a banned user may `POST /forget` the room (`200`,
    hidden afterwards); an unban followed by a re-invite makes it visible again in `rooms.invite`.
13. **Bans are carried into the upgraded room (D11; HTTP real DB).** A `public` room with two banned users (one with a `reason`, one
    pre-emptive without a `users` row) and one kicked user; `POST /upgrade`: the new room has exactly two ban events (sender = upgrader, the
    `reason` copied when valid), written BEFORE the copied `m.room.join_rules` event, the banned users' `/join` of the new room is `403`, the
    kicked user can join (public); a ban with a legacy `reason` that fails D10 is carried without it; the `room_upgraded` audit row has
    `"bans_carried" => 2`; a failing `banned_members/1` read (test db module) fails the upgrade with `500` BEFORE the tombstone (the old room
    has no tombstone, no new room is left behind); a failing ban copy fails it (the new room has no join rule and no invitation).
14. **Audit (real DB, D12).** A committed kick / ban / unban writes exactly one row `room_member_kicked` / `room_member_banned` /
    `room_member_unbanned` (actor = the moderator, resource `room`, the room id, metadata exactly `%{"user_id" => target}` (kick: plus
    `"invitation_revoked"`), outcome `success`), the three actions are in `@known_actions` (a test that `AuditWriter.log/6` accepts them), no
    row for refusals, for the ban no-op or for the upgrade copies; a failing audit writer (injected) does not fail the action (200, value-free
    ERROR log). No `reason` text appears in the audit row or in any log line of the suite (captured logs).
15. **Crash / restart (real DB; the Room-State convention of `.claude/rules/matrix-conventions.md`).** After a committed ban and a committed
    kick, the room process is killed (`Process.exit(pid, :kill)`) and restarted by Horde / `start_room/1`: the reloaded member set excludes
    both targets, the ban is still enforced on join, a pending invitation of the kicked user is still rejected; a process killed DURING a
    moderation call (the transaction not committed: kill from a db hook before the commit) leaves the database exactly as before.
16. **Source pins and seams (unit).** (a) In `server/lib` no `m.room.member` event map is built outside `Nebu.Matrix.Room.Server` except
    `create_personal_room` and the archived-room branch of the decline (`emit_decline_event/2`): the old inline writers of
    `kick_user/2`, `ban_user/2`, `unban_user/2` and the invite `emit_state_event_at(.., "m.room.member", ..)` are gone; `remove_member_for_ban!/2`
    is gone. (b) The fakes of every suite that reaches kick / ban / unban / invite / decline implement `apply_member_change/4` (at least
    `join_room_test.exs`, `invite_user_test.exs`, `create_room_invites_test.exs`, `server_moderation_metadata_test.exs`; the dev greps the 44
    suites that inject `:room_manager, :db_module` and records the final list in the Completion Notes). (c) `kick_user/2`, `ban_user/2`,
    `unban_user/2` keep their signatures (the tests' direct calls keep working) and are thin: request -> pure checks -> `Room.Server.moderate/5`
    -> error mapping -> audit.
17. **Docs (`server/test/nebu/matrix/moderation_routes_docs_test.exs`, new).** (a) `docs/matrix-api-scope.md`: the kick, ban and unban rows
    become ✅ with the D2-D6 and D10 rules and these explicit labels (Oracle gate, each pinned by the docs suite): "self-kick refused:
    Nebu choice (v10 would allow a self-leave)", "foreign-id ban `403`: Nebu choice", "`404` for an unknown room: Nebu choice (existence
    oracle `403` vs `404`, as `/invite`)", "unban of a non-banned user `403`: Nebu choice", "the `moderation` tier: divergence from
    Rate-limited: No", "the 1024-byte `reason` cap and the NUL refusal: Nebu choices", "`503 M_UNAVAILABLE` is not a spec errcode"; the
    upgrade row labels the ban copy "deliberate deviation from the SHOULD NOT (membership events not transferred; bans re-issued in the
    upgrader's name)" (the order, the codes and fixed texts, the `moderation` tier labelled "divergence from
    Rate-limited: No", the 404 labelled a Nebu choice, the revocation, pre-emptive bans, the foreign-id refusal, the unban rules, the
    reason cap, the one-transaction guarantee, the audit actions); they keep the words "DM" and "equal" (the create-room-invites-direct pin)
    and "enforced" + "join" (the presets pin); the words "Unrouted", "internal only", "No API can issue a ban yet", "PARTIAL" / "partial" and
    "event order is not" are gone from them; the join row's "member set ... event order" caveat is rewritten as closed (the event order IS
    protected, `ex` CLOSED); the invite row says the ban check and the invite event are decided in the room process (`ex` / M-1); the
    upgrade row says bans are carried (S8 label, `fr` for the power levels). (b) `docs/architecture/07-deployment.md`: a new paragraph
    "**Room moderation: kick, ban, unban (story moderation-routes-atomic-ban, follow-ups `ex`, `ew`).**" (what clients can see; the tier and
    its two variables; the audit actions; Element's "Banned users" list is empty after a fresh initial sync until story 2 (`fb`): unban
    through the member's profile in the timeline, `/unban <user-id>` or the API; the upgrade carries bans; the operator query **Q-half**
    (active `room_members` rows whose latest member event is `ban`: half states, typically legacy N-6 leftovers; a repeated ban repairs them, a kick refuses them), using the
    membership extraction of `@sql_member_membership_raw` (both JSONB forms) and the D3 order, checked in a rolled-back transaction with
    fixture rows); the RELEASE GATE paragraph: "`ex` remains the gate for building a ban route ... there is no ban API yet" becomes "`ex` is
    CLOSED by story moderation-routes-atomic-ban: the ban route exists ..." (keeping the pinned words "`ex`" and "ban route"); release note
    (1) loses "NO API can issue a ban yet" and "PARTIAL" and states that a ban can be issued now and that member set AND event order are
    protected (one atomic room-process call); release note (4) says "the Admin UI has no unban" (kept: the presets pin `no (Admin )?unban`)
    but no longer "there is no API to ban or unban a user at all yet"; the old-behaviour sentence "Bans and kicks were not enforced on join"
    stays. (c) `CHANGELOG.md` `[Unreleased]`: `### Added` the three routes, the tier, the audit actions; `### Changed` (**⚠**): unban needs
    the kick level too, a kick of a non-member is `403` (was an internal 404), bans are carried by `/upgrade`. (d) `follow-ups.md`: `ex` and
    `ew` rewritten as **CLOSED by story moderation-routes-atomic-ban (date)** keeping the words pinned by the existing docs suites where they
    still hold (`ex`: "gate for the ban route", "ONE atomic", "Room.Server", "N-1b", "N-6", "EVENT order", "join event", "MEMBER SET",
    "AFTER the ban event", "EventSize", "reason", "`join` tier", "ban route"; `ew`: "upgrade_room", "ban"), notes on `fb` (keeps
    "build_state_events", "kick_user", "revoke", "strictly greater", "trusted_private_chat", "upgrade", "synthesized", "predecessor", "not
    marked", "`fi`"), `eu`, `eq`, `et` (keeps "visibility", "unban", "m.room.join_rules"), `fi`, `fg`, `fe`, `fa`, `fc`, `fp`; new rows `fq`, `fr`;
    the id line: "`fq`-`fr`: moderation-routes-atomic-ban" and "unused: ... `fs` onward". (e) The docs suite pins all of (a)-(d), the absence
    of the removed phrases, and that `server/lib` comments no longer call the ban route "a gate" / "does not exist yet" (room/server.ex
    l.572-586 rewritten).
18. **Regression and deliberate re-pins.** `mix compile --warnings-as-errors`; `mix test` and `mix test --include integration` green apart
    from the known flaky families (`fj`, `fm`). Deliberate re-pins (each listed old -> new in the Change Log; any OTHER needed change is a
    finding: stop and report): `join_room_test.exs` "ban_user removes ... removes AGAIN" and "a member that cannot be removed fails the ban
    ... second removal" (the `rejoin_on_ban` fake injection models the deleted two-removal design and would call the room process from inside
    itself: replaced by AC7 (a) on the real DB), and its ban / kick / unban fakes (AC16 (b)); `server_moderation_metadata_test.exs` (its
    `FakeRoomDB`); the kick-of-non-member expectation if any suite pins the old internal 404 (grep `not a member of this room` / `:not_member`
    in moderation tests); the docs suites `create_room_presets_docs_test.exs` (the `ex` OPEN test -> CLOSED; the scope "No API can issue a ban
    yet" / "member set" / "event order" asserts; the 07-deployment "no API can issue a ban", "PARTIAL", "event order" asserts),
    `membership_write_limits_docs_test.exs` (l.133 "no API can issue a ban"), `sync_membership_partition_docs_test.exs` (gate words stay),
    `event_size_limit_docs_test.exs` (the `ex` gate item -> satisfied), and the id-line assertion "`fq` onward" in the seven suites
    `create_room_presets_docs_test.exs`, `create_room_invites_docs_test.exs`, `event_size_limit_docs_test.exs`, `member_prev_content_docs_test.exs`,
    `membership_write_limits_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`, `sync_membership_partition_docs_test.exs` (-> `fs`).
    Unchanged and green: `create_room_presets_http_test.exs` (incl. F-1 / F-3 / F-5 / unban-rejects-invite), `sync_membership_partition*`,
    `member_prev_content*`, `create_room_invites*`, `membership_write_limits*`, `matrix_client_compat_test.exs`, `room_summary_integration_test.exs`,
    `event_size_limit*`, `upgrade_room*`.

19. **Oracle missing tests (HTTP real DB unless noted; each a separate test).** (a) Self-moderation: a self-kick (PL 100 sender = target)
    -> `403` "You cannot act on a user whose power level is not lower than yours" (pinned as the Nebu choice of D2), a self-ban -> the same
    `403`, an unban by a BANNED sender of another banned user -> `403` "You are not a member of this room"; nothing written. (b) Levels of
    non-members: unban of a banned user whose `users` level is >= the sender's -> `403` (target not lower); a pre-emptive ban of a non-member
    listed in `users` at a level >= the sender's -> `403`. (c) Boundaries: a sender EXACTLY at the `kick` / `ban` level (override
    `{"kick": 60, "ban": 70}`, senders at 60 / 70) is allowed, one below (59 / 69) refused; a non-zero `users_default` (e.g. 10) counts as the
    target's level (a sender at 10 cannot kick a default user, at 11 with `kick` 10 can). (d) A kick-revoke by the INVITER who holds only
    the `invite` level (below `kick`) -> `403` (power level text): v10 has no inviter rule; the row stays pending. (e) A pre-emptive ban
    event (target with no earlier member event) has NO `unsigned.prev_content` / `prev_sender` in `/sync` and `/messages` (the spec:
    absent = previous membership `leave`). (f) A second `/unban` right after the first -> `403` "The user is not banned from this room",
    event count unchanged, no audit row. (g) Authentication: no access token -> `401 M_MISSING_TOKEN`, an invalid token -> `401
    M_UNKNOWN_TOKEN` on all three routes, before the rate charge has any effect on another user and with nothing written (pin the order
    the router has: auth plug first). (h) `/forget`: a kicked (not banned) user -> `200` and hidden; a still-joined user -> `400` (the
    existing `M_BAD_STATE` mapping, spec "must leave first"); a banned user -> `200` (AC12 (e)). (i) After an unban: `POST /invite` of the
    user by a member -> `200` (a new invite event, stamped after the unban leave); his direct `POST /join` of an invite-only room WITHOUT
    that invitation -> `403` "You are not invited to this room", with it -> `200`. (j) Upgrade: the banned users of the old room get NO
    `room_invitations` row (row-only invitation) in the new room and no invite event; the old members do. (k) A percent-encoded room id in
    the path (`!abc%3Aserver`, and a fully encoded `%21abc%3Aserver`) works for kick, ban AND unban (decoded like `/invite`), and an
    encoding of an unknown room is `404`. (l) A ban of a JOINED user writes EXACTLY ONE `m.room.member` event (`join -> ban`, no separate
    `leave` before it); its `unsigned.prev_content` is the join.

## Acceptance Tests

- `server/test/nebu/matrix/moderation_routes_http_test.exs` (new, `:integration`, through `Nebu.Web.Router`): AC1, AC2 (HTTP part), AC3, AC4,
  AC11 (HTTP part), AC12, AC13, AC14, AC19 (a)-(l).
- `server/test/nebu/matrix/room/moderation_atomic_db_test.exs` (new, `:integration`, real DB, `Room.Server` + `Room.DB` directly): AC5 (a),
  (d), AC6, AC9, AC15.
- `server/test/nebu/matrix/moderation_concurrency_test.exs` (new, `:integration`, real DB, `async: false`, tagged `:concurrency` and included in
  the integration run): AC7, AC8 (c), AC10 (b).
- `server/test/nebu/matrix/room/moderation_unit_test.exs` (new, unit, fakes): AC5 (b), (c), AC8 (a), AC10 (a), AC11 (unit part), AC16.
- `server/test/nebu/web/rate_limit_tiers_test.exs` (existing, extended) and the existing runtime-config test (record which): AC2 (unit part).
- `server/test/nebu/matrix/moderation_routes_docs_test.exs` (new): AC17.
- Re-pinned: the suites of AC18.

The concurrency suite is the gate evidence: its invariants are asserted on the database AND the room process after every round, never on
timing; the deterministic gap tests (AC8 (c), AC9 (c), AC10 (b)) prove each interleaving once on purpose. Use the existing `tick/0`
helpers only in rooms the test owns; insert no future-stamped events except the AC6 (a) invite (deleted `on_exit`).

## E2E verification

`ui: false` (no Nebu UI code). One new feature `e2e/features/element/room/moderation.feature` with two scenarios, run on a FRESH, isolated
stack built from THIS commit (the e2e-ci script builds the server image when `NEBU_E2E_PREBUILT` is unset):

- **`@moderation-api @regression`** (the regression guard, no UI selectors): alex creates a `public` room through the API, marie joins;
  alex `POST /ban`s marie with reason "e2e ban": `200`; marie's `POST /join` is `403 M_FORBIDDEN` "You are banned from this room"; marie's
  `/sync` lists the room in `rooms.leave` with the ban event (sender alex, reason); alex `POST /unban`s: marie joins again (`200`); alex
  `POST /kick`s marie with a reason: her latest membership is `leave` by alex; alex creates an invite-only room, invites kai and kicks him
  before he accepts (Disinvite): kai's `/sync` no longer lists the invitation and his `/join` is `403` "You are not invited to this room".
- **`@moderation-ui @regression @ui`**: alex is logged in via Element Web, opens the room with marie as a member and types `/ban <marie's
  user id> e2e ui ban` in the composer (the composer steps of `messages.steps.ts` are verified against Element 1.12.15) and presses Enter;
  asserted SERVER-side: marie's latest membership is `ban` with sender alex and the reason; then `/unban <marie's user id>`: latest `leave`
  by alex. **Element's slash-command handling (autocomplete on Enter, a possible confirmation dialog) and the member-panel moderation
  selectors are UNVERIFIED in the bundle**; the slash command avoids the member-panel selectors. If the first real run fails for a UI
  reason (not a server answer: check the server log for the `/ban` request), tag it `@known-failure` with a new row K11 in
  `e2e/KNOWN-FAILURES.md` (cause: Element 1.12.15 slash-command behaviour unverified) and keep the API scenario as the guard; a server
  error (anything but `200` on the `/ban` / `/unban` request) is a finding.

Run (the orchestrator; the step is `ui: false`, so it is evidence, not a UI gate):

0. Preparation: `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000 (stop a stray `nebu-oauth-dev-*` container, never
   touch the shared `nebu` project); `COMPOSE_PROJECT_NAME=nebu-oauth-e2e`.
1. **Run A (CI parity):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh element`. Pass: every scenario of the default
   tag expression green (the two new ones included, or the UI one moved to K11 as described) except the rows of `e2e/KNOWN-FAILURES.md`.
   Then `docker compose -p nebu-oauth-e2e logs --no-color server > .../e2e-run-a-server.log` and count the `RequestLogger` lines with status
   `500` (pass: zero) and with path `/kick`, `/ban`, `/unban` (record the count and the statuses: only `200` / the expected `403`s), and grep
   the log for the reasons "e2e ban" / "e2e ui ban" / "e2e kick" / "e2e disinvite" (pass: zero hits: No Sensitive Data in Logs). Then `docker compose -p
   nebu-oauth-e2e down -v --remove-orphans`.
2. Logs: `_bmad-output/nebu/epics/oauth-broker/step-results/moderation-routes-atomic-ban/e2e-run-a.log` and `e2e-run-a-server.log`; update
   the "Status of the last complete run" line of `e2e/KNOWN-FAILURES.md` with run A's numbers.

## Tasks

- [x] `Room.DB`: `apply_member_change/4` (one transaction: delete_member, the InviteDB reject statement, insert_event), `banned_members/1`
      (one statement, shared membership fragments, D3 order), `latest_member_event/2` returns `:event_id` too (D2, D3, D11).
- [x] `Room.Server`: `moderate/5`, `write_invite/5`, `write_decline/2`, `join/3` with the basis; one private member-event builder (sign,
      `EventSize.check_keys/3` + `check_stored/1`, stamp `max(now, not_before, latest + 1)`) used by all of them and by the existing join /
      leave; `:pg.get_members/1` for the new broadcasts; the comment block l.572-586 rewritten (D1-D4, D7-D10).
- [x] `EventDispatcher.Server`: `kick_user/2`, `ban_user/2`, `unban_user/2` as thin wrappers with the D6 error mapping (explicit errcodes,
      fixed texts) and the D12 audit; `moderation_body!/1` (D6, D10); `do_invite!/5` -> `write_invite/5` with the compensation (D7);
      `leave_without_room_process/3` -> `write_decline/2` with the start rule (D8); `authorize_join!/2` returns the basis, `join_room/2`
      retries once (D9); `upgrade_room/2` reads and carries the bans (D11); delete the old inline writers and `remove_member_for_ban!/2`.
- [x] `Core.UnbanUserRequest` gains `reason: ""`.
- [x] `protected.ex`: the three routes in the D6 order (charge first, body, sender guard, `call_core`); `moderation_bucket/1`.
- [x] `RateLimitTiers.moderation/0` (+ moduledoc table, `invalid_settings/0`), `config/runtime.exs`, `docker-compose.yml` (D5).
- [x] `AuditWriter.@known_actions`: `room_member_kicked`, `room_member_banned`, `room_member_unbanned` (+ the comment line) (D12).
- [x] Tests (Acceptance Tests) incl. the fakes of AC16 (b) and the re-pins of AC18 (Change Log, old -> new); record the red run of AC6 (d).
- [x] Docs AC17 (scope doc, 07-deployment incl. Q-half checked in a rolled-back transaction, CHANGELOG, follow-ups).
- [ ] E2E feature + steps (API steps through the existing `request` helpers; the composer steps reused); run A (orchestrator).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (SQL inline
  in `Room.DB` / `InviteDB`, no repository or service layer: `apply_member_change/4` is a DB function next to `delete_member/2`, the
  decisions stay in `Room.Server`), ADR-019 / ADR-021 (plain in-process modules, `Core.*` structs), ADR-020 (no new cross-domain call),
  cluster-safety (`Horde.Registry` per room, `:pg.get_members/1`, no `:global`).
- **One writer, one order.** Every decision that a ban can race reads its facts INSIDE the room process right before the write; do not
  "pre-read outside and pass in" any fact the decision depends on (the caller's reads are fast-path refusals only). The stamp is always
  `max(now, latest + 1)` from the read in the SAME call. The room process must never `GenServer.call` itself (a fake or hook that re-enters
  `Room.Server` from inside `apply_member_change/4` deadlocks: that is why the old `rejoin_on_ban` fake is replaced, AC18).
- **Nothing half done.** All writes of one moderation go through `apply_member_change/4` in ONE transaction; the in-memory state, the
  broadcasts, the wake-ups and the audit row come only AFTER the commit. No fallback to separate statements, ever (D3).
- **Fixed texts and explicit errcodes.** `permission_denied` without `errcode` becomes "You are not a member of this room" in
  `Http.map_error/1`: every moderation refusal sets `errcode: "M_FORBIDDEN"` and its own fixed message (D6). No target id, no `reason`, no
  content in a message or a log line (No Sensitive Data in Logs Law: `reason` is user text); logs carry the room id and `db_error_class/1`.
- **Fail closed.** A failing membership / invitation read refuses the action (500), never "no state".
- **Previous story learnings** (event-size-limit, member-event-prev-content, sync-membership-partition): real-DB tests for everything
  stored and every race (the N-1 bug passed a fake test); docs suites pin earlier texts: rewrite `ex` / `ew` in the CLOSED style that keeps
  the pinned words, list every re-pin old -> new; `tick/0` only in own rooms (`fj`); the e2e on a fresh isolated stack, never on the shared
  `nebu` project; reason texts must not appear in the server log (the e2e grep).
- **Element.** The "Disinvite" of a pending invitee is a `/kick` (recalled): AC4 (b) is the server side of it. Element's "Banned users"
  settings list depends on story 2; do not try to fix it here.

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` (`POST /rooms/{roomId}/kick`, `/ban`, `/unban`, "Banning
  users in a room", `#room-upgrades` server behaviour, the common errcodes), `rooms/v10/index.html` (authorization rules, m.room.member).
- Code: `server/lib/nebu/matrix/event_dispatcher/server.ex` l.1844-2065 (join_room, authorize_join!, invitation_valid!, join_banned?),
  l.2484-2684 (leave_room, leave_guard_membership!, leave_without_room_process, reject_invitation_strict!), l.2756-3045 (invite_user,
  do_invite!, write_invitation!, handle_failed_invite_event!, emit_invites), l.6155-6425 (kick_user, ban_user, require_higher_power_level!,
  remove_member_for_ban!, unban_user), l.7110-7159 (emit_decline_event, member_event_stamp), l.7178-7365 (upgrade_room), l.7689-7725
  (emit_state_event_at), l.7747 (copy_state_events); `server/lib/nebu/matrix/room/server.ex` l.318-411, l.572-683;
  `server/lib/nebu/matrix/room/db.ex` l.280-306, l.443-470, l.1443-1500, l.1585-1660; `server/lib/nebu/matrix/room/invite_db.ex` l.192-275,
  l.325-360; `server/lib/nebu/matrix/room/power_level.ex`; `server/lib/nebu/matrix/http.ex` l.56-105; `server/lib/nebu/web/router/protected.ex`
  l.1366-1446, l.1744-1770, l.3113-3119; `server/lib/nebu/web/rate_limit_tiers.ex`; `server/lib/nebu/compliance/audit_writer.ex` l.164;
  `server/lib/nebu/matrix/event_size.ex`; `server/lib/pb/core.pb.ex` l.428-470.
- Reviews: `security-reports/create-room-presets-power-levels-topic-security-review-2026-10-16.md` (F-2, F-3, F-5, F-6, N-1, N-2, N-5, I-x);
  `create-room-invites-direct-security-review-2026-10-16.md` (M-1, I-1); `sync-membership-partition-security-review-2026-10-17.md` (M-1
  left_at window, L-1, I-2); the `ex` notes of member-event-prev-content (L-1, no report file) and event-size-limit (#4).
- Oracle contexts: `step-results/{create-room-presets-power-levels-topic,create-room-invites-direct,sync-membership-partition,member-event-prev-content,rate-limits-join-invite-create-room,event-size-limit}/oracle-context.md`.
- Stories: `create-room-presets-power-levels-topic.md`, `create-room-invites-direct.md` (D1, D9), `sync-membership-partition.md` (D3, D13),
  `member-event-prev-content.md` (D4), `rate-limits-join-invite-create-room.md` (D1-D4), `event-size-limit.md` (D2 (d), D12).
- Follow-ups: `ex`, `ew`, `fb`, `eq`, `eu`, `et`, `es`, `fa`, `fc`, `fe`, `fg`, `fi`, `fp` in `docs/stories/oauth-broker/follow-ups.md`.
- Conventions: `.claude/rules/matrix-conventions.md` (crash / restart test), `skills/nebu-conventions/cluster-safety/SKILL.md`,
  `docs/architecture/08-concepts.md` "Audit Logging".

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev step, nebu-dev-story, pipeline step 4, cycle 0).

### Debug Log

- Starting point: the throwaway ATDD reference (`scratchpad/atdd/moderation/ref`), reviewed piece by piece and rewritten. Not taken over: the audit facts
  pre-read OUTSIDE the room process (racy: it could skip the audit row of a real ban), `:pg.get_local_members` style, `inspect(reason)` in 500 texts,
  stub `apply_member_change/4` fakes (`:ok`), the deleted `Room.Server.remove_member/2` (one old unit suite still needs it, see Completion Notes).
- Nested test modules: a fake that calls a sibling module defined LATER in the file must use its full name (`FakeInviteDB` inside `FakeDB` is a top-level
  alias otherwise: `UndefinedFunctionError`, which the room process logged as the class of the rolled-back change).
- **AC6 (d) red run on the OLD code** (HEAD `891ed9ce` extracted with `git archive`, the staged test support copied in, the same throwaway PostgreSQL, a quiet
  machine, nothing else running), 2026-10-19:
  * `moderation_atomic_db_test.exs:257` (the gate test as written): red, `ban at once: 404 {"errcode":"M_UNRECOGNIZED"}` (no route on the old code);
  * a scratch variant (never committed) of the same sequence with the ban issued through the OLD internal `EventDispatcher.Server.ban_user/2`: red,
    `OLD-CODE SEQUENCE: ban@1792443370695 invite@1792443370930 join@1792443370931; latest=join`: the old ban is stamped at the clock, BEFORE the
    future-stamped invite and the join, so the latest membership stays `join` (the `ex` / L-1 defect). On the new code both are green.
- **Q-half SQL evidence** (the query of 07-deployment verbatim, inside `BEGIN ... ROLLBACK` on the throwaway database, `scratchpad/mod/qhalf.sql`): fixtures in
  one room: u1 active + join -> ban (object form), u2 active + ban in the STRING form, u3 active + leave and ban in the same millisecond, u4 active + ban then
  a later join, u5 LEFT row + latest ban, u6 active + latest join. Listed: exactly u1, u2, u3 (`banned_at` 20); after the ROLLBACK the fixture room is gone (0 rows).
- Full runs (Elixir 1.20.4, `elixir:1.20-alpine`, `MIX_BUILD_PATH=/tmp/nebu_build`, `--warnings-as-errors`): `mix compile` clean; no-DB `mix test`
  6086 tests, 1 failure before the `unrecognized_routes_test.exs` re-pin (green after); `mix test --include integration` (throwaway, REUSED database,
  `regression_sync_load_test.exs` moved aside and restored): 9569 tests, 25 failures, all in the known flaky families (TemporaryCaptureManager 3,
  RoomsFallbackName 12, LogStore.Retention 2, AdminOidcLogin 3, WarRoom 1, SsoLogin 1, TraceMapNodeControls 3). Each suite re-run in isolation: the same
  failures, and the SAME failures on the OLD code on the same database: pre-existing on the reused database, not caused by this story. A first combined run
  of the related suites also had MatrixClientCompat replaces_state (known flake, re-run in isolation: same result on the old code) and three
  `moderation_atomic_db_test.exs` `tick/0` timeouts (follow-up `fj`: a future-stamped event of another suite in the same run); the suite is green in
  isolation and in the full run.

### Completion Notes List

- `Room.DB`: `apply_member_change/4` (ONE `Repo.transaction/1`: the soft delete, the `InviteDB` reject statement, `insert_event/1`; "not a member" is no error;
  any failure, a raised one included, is `{:error, reason}` and rolls everything back), `banned_members/1` (one statement, `DISTINCT ON` with the shared
  fragments and the D3 order, both JSONB forms, the string `reason` or nil), `pending_invitation/2` (delegates to `InviteDB`), `latest_member_event/2`
  answers `event_id` too.
- `Room.Server`: `moderate/6` (`moderate/5` + `opts`), `write_invite/5`, `write_decline/2`, `join/3` (join/2 = `:any`), one member-event builder
  (`member_event/5`: canonical bytes, `EventSize.check_stored/1` before signing; `checked_member_event/5` adds `check_keys/3` for moderation and invite), one
  stamp (`stamp/2` = max(now, not_before, latest + 1), also for join / leave), one latest-member reader (`read_latest_member/2`, fail closed), one write
  (`commit_member_change/4`: refuses a db module without `apply_member_change/4`, `:write_failed` / `:duplicate_event`, value-free ERROR log with room id and
  error class). Every moderation writes with `remove_member: true, reject_invitation: true` (afterwards the target is no member and holds no pending row,
  for kick, ban, the idempotent ban (the Q-half repair) and unban alike: a superset of D3's list, harmless where there is nothing to close). New broadcasts
  and the `user:<target>` wake-up use `:pg.get_members/1`. The join / leave broadcasts stay node-local (`fe`). The comment block of `check_not_banned/3`
  rewritten (no "gate", no "does not exist yet"). The join / leave event log lines are value-free now (room id + error class; they carried the user id
  and `inspect(reason)`).
- **Decision (return shape, test review "Return shapes"):** `moderate/5` answers exactly `:ok`; the dispatcher calls `moderate(.., outcome: true)` (the
  6-arity form) and gets `{:ok, %{event_written: boolean, invitation_revoked: boolean}}` from the room process itself, so the audit metadata
  (`invitation_revoked`) and the skipped audit row of the idempotent ban are decided on the committed state, never on a racy pre-read.
- `EventDispatcher.Server`: `kick_user/2`, `ban_user/2`, `unban_user/2` thin (`moderate!/3`: lookup 404 "Room not found", the local-domain rule of a ban,
  `Room.Server.moderate(.., outcome: true)`, explicit `M_FORBIDDEN` texts, 413 / 500 / 503 mapping, audit); `moderation_body!/1` (shares
  `validate_invitee_shape!/1`); `do_invite!/5` -> `write_invite_event/5` (`Room.Server.write_invite/5`) with `refused_invite_event!/4` (the row THIS call
  created is rejected after any refusal; texts as the outside checks); `leave_without_room_process/3` -> `decline_in_room!/2` (starts the room process,
  archived room = the old out-of-process write); `authorize_join!/2` returns the basis, `join_room/2` re-decides once (503 on the second change);
  `upgrade_room/2`: `banned_members!/1` before anything is written, `carry_bans!/3` before `copy_state_events/3`, banned users excluded from the row-only
  invitations, `bans_carried` in the success row. Deleted: the inline kick / ban / unban writers, `require_higher_power_level!/3`,
  `remove_member_for_ban!/2`, `reject_invitation_strict!/2`.
- Router: the three routes in the D6 order (`moderation_request/3`: charge, M_NOT_JSON / M_BAD_JSON, `moderation_body!/1` through `call_core`, the sender guard
  with the existing `key_error/2`, then the core), `moderation_bucket/1` (`{"moderation", user}`).
- `RateLimitTiers.moderation/0` (`{30, 60}`, moduledoc table + divergence note), `config/runtime.exs`, `docker-compose.yml` (comment reworded: four tiers),
  `AuditWriter.@known_actions` (+3), `Core.UnbanUserRequest.reason` (+ `proto/core.proto` field 4).
- ~~`Room.Server.remove_member/2` is KEPT~~ (SUPERSEDED by review cycle 1, M2: removed; see below) (no production caller any more; documented as such): `sync_membership_partition_test.exs` models removals with a fixed
  event timestamp through it, and `moderate/6` cannot take a timestamp.
- Docs: scope doc (kick / ban / unban rows ✅ with the seven Oracle labels, join / invite / upgrade rows), 07-deployment ("Room moderation" paragraph incl. Q-half,
  RELEASE GATE + release notes (1) / (4)), 08-concepts (tier table), CHANGELOG (`Added`, `⚠ Changed`), follow-ups (`ex`, `ew` CLOSED; notes on `fb`, `eu`,
  `eq`, `et`, `fi`, `fg`, `fe`, `fa`, `fc`, `fp`; new rows `fq`, `fr`; the id line `fq`-`fr`, unused from `fs`).
- **AC16 (b) grep list** (`grep -rln "room_manager, :db_module" server/test`: 47 files). Fakes that reach kick / ban / unban / invite / decline and now implement a
  REAL `apply_member_change/4` (delete the member, reject the pending row, insert the event, the suite's failure switches fail the WHOLE change before anything
  is applied): `event_dispatcher/join_room_test.exs` (+ `pending_invitation/2` delegating to its FakeInviteDB, `event_id` in the latest member event),
  `event_dispatcher/invite_user_test.exs`, `event_dispatcher/create_room_invites_test.exs` (+ `pending_invitation/2`), `event_dispatcher/invite_caps_test.exs`
  (+ `pending_invitation/2`), `event_dispatcher/server_moderation_metadata_test.exs`, `event_dispatcher/sync_membership_partition_test.exs`
  (+ `pending_invitation/2`, `event_id` in `latest_member_event/2`); the new `room/moderation_unit_test.exs` (FakeDB), `room/moderation_atomic_db_test.exs`
  (KillingDB delegates). The other 39 suites do not reach these writers in their tests (green unchanged; a decline or invite there would answer 500
  `:unsupported_db_module`, never fall back): `upgrade_room_test`, `upgrade_room_error_handling_test` (no bans in their fakes: `banned_members/1` absent = none),
  `leave_room_test`, `sync_test`, `create_room_*` (initial_state, canonical_alias, presets, test, input_validation, creator_provisioning), `spaces_create_room_test`,
  `audit_room_ops_test`, `audit_member_ops_test`, `audit_archive_ops_test`, `auto_join_*` (opt_out, spaces, rooms, join_rule), `admin_force_add_member_test`,
  `archive_room_test`, `update_room_settings_test`, `server_set_typing_test`, `server_receipts_test`, `server_get_room_state_system_test`, `server_dedup_test`,
  `send_event_test`, `handler_test`, `get_room_state_lazy_restart_test`, `get_messages_test`, `get_event_test`, `room/server_set_typing_test`,
  `room/server_member_stamp_test`, `room/send_event_archived_room_test`, `room/room_server_clustering_test`, `room/power_level_enforcement_test`, `room/nebu_room_test`,
  `admin/admin_create_room_test`, `admin/admin_member_management_test`, `admin/admin_oidc_login_test`.
- Results: the 6 new / changed suites (`moderation_routes_http_test`, `moderation_concurrency_test` (50 rounds), `room/moderation_atomic_db_test`,
  `room/moderation_unit_test`, `moderation_routes_docs_test`, `web/rate_limit_tiers_test`) and the 7 re-pinned docs suites: all green; the related suites of AC18
  (create_room_presets / invites / sync_membership_partition / member_prev_content / membership_write_limits* / event_size_limit* / room_summary_integration /
  `room/*`, `event_dispatcher/*`) green.

- **Review cycle 1** (code review M1-M7, I1, I6, I7; Kassandra M-1, L-1-L-4, I-6), 2026-10-19:
  * M-1: `upgrade_room/2` reads the bans AGAIN after the old room is archived and its process stopped and carries the delta (a ban in the new
    room rejects a pending row and removes a member who joined meanwhile); `bans_carried` counts both reads.
  * L-3 / M4: at most 10 000 carried bans (`:nebu, :upgrade_max_carried_bans`, a test seam); more is `403 M_FORBIDDEN` "The room has too
    many bans to be upgraded" BEFORE the tombstone; `@sql_banned_members` sorts only the `reason` (`@sql_member_reason_raw`, both JSONB forms).
  * L-2 / M3: the latest `ban` decides first for every action: a kick of a member behind a ban is `:target_banned` ("unban them instead").
  * I-6: `apply_member_change/4` starts with `SET LOCAL lock_timeout = '2s'` (55P03 -> rolled back -> `:write_failed`, 500).
  * M1: `decline_in_room!/2` falls back to the out-of-process write only when `get_room_status/1` says archived; any other start failure is
    503 with a value-free log.
  * M2: `Room.Server.remove_member/2` (public API + `handle_call`) removed; `sync_membership_partition_test.exs` drops the member from the
    running room process with `:sys.replace_state/2` in its test helper.
  * M5: the invite event is written with `require_pending_invitation: true` (the row is locked `FOR UPDATE`; none pending ->
    `:invitation_gone`, nothing written) -> `403 M_FORBIDDEN` "The user is not in this room" (the existing D4 text: the invitee is neither
    member nor invited), the row this call wrote compensated as for every refusal.
  * M6: `write_decline/2` writes no second leave when the latest membership is `leave` and no pending invitation is left (a stale pending row
    is still rejected, without an event).
  * M7, I6, I7: the `fe` header, the `/ban` scope wording, the `membership_write_limits_docs_test.exs` comment, the Room.Server moduledoc and
    the `runtime.exs` comment wrap. L-1 / L-4 documented: D12 residuals, follow-up rows `fs` and `ft`, the id line (`fs`-`ft`, unused `fu`
    onward; the eight docs suites re-pinned `fs` -> `fu` onward).
  * New tests: `server/test/nebu/matrix/moderation_fix_cycle1_http_test.exs` (real DB: M-1 seam test, cap, L-2 half state with kick 10 /
    ban 50, I-6 lock timeout, M5 / M6 gap tests, I1 event id) and `server/test/nebu/matrix/room/moderation_fix_cycle1_unit_test.exs` (M1
    archived vs. non-archived start failure, L-2 in the room process, M2 pin).

- **Review cycle 2** (Kassandra L-5, I-10, I-11, I-16; code review MINOR-1-5, INFO-8), 2026-10-20:
  * L-5 (i) freeze first: `upgrade_room/2` = tombstone -> `freeze_old_room!/1` (archive + stop, BOTH fatal: a failed `terminate_child` is
    re-checked with `lookup_room/1`, a process still registered is a 500) -> the ONE authoritative read of bans and members
    (`members_after_freeze!/2`, `rooms_db_module().load_members/1`) -> create / creator / levels -> the bans -> `copy_state_events/3` ->
    invitations minus the bans. The pre-tombstone read only checks the cap and fails closed early. The cycle-1 delta re-read (7b) is gone;
    `bans_carried` = the authoritative set. A failure after the tombstone leaves the old room archived and the new room an orphan without
    join rule or invitation (stated in the scope doc; review cycle 3, MINOR-3: the tombstone stays, to continue the owner unarchives the
    old room in the Admin UI (which restarts its process) and runs `/upgrade` again; the orphan new room has to be cleaned up).
  * L-5 (iii): `apply_member_change/4` reads `rooms.status ... FOR SHARE` first and refuses an archived room (`:room_archived`): moderation
    and the invite event answer 404 "Room not found" (the row of the invite compensated); a decline falls back to the archived-room write.
  * I-11: `lock_timeout` 1 s per wait (three waits < the 5 s call; noted in `fs`). I-10: `fp` sentence (un-upgradable by > 10 000
    pre-emptive bans, way out: unban); the cap seam accepts only a positive integer. I-16: follow-up `fu`; id line "unused `fv` onward".
  * MINOR-1 runtime.exs wrap; MINOR-3 `@doc` of `write_invite/5` (`:invitation_gone`, `:room_archived`) and `write_decline/2` (no-op);
    MINOR-4 reason tests (string form, non-string, unparseable); MINOR-5 CHANGELOG cap / freeze entry, the KEPT notes struck as superseded,
    two stale test titles; INFO-8 positive docs pins (`fs` / `ft` / `fu` rows, the `fe` header, the cap sentence).
  * New tests: `server/test/nebu/matrix/moderation_fix_cycle2_http_test.exs` (window ban / join / invite before the freeze, a failing ban
    copy after the freeze, an archived room with a running process, the reason forms). Not tested: a failing `terminate_child` (Horde cannot
    be made to fail it without a supervisor seam; the branch is a `with` over two `lookup_room/1` calls).

- **Review cycle 3** (Kassandra L-1, I-1-I-6; code review MINOR-1-4, INFO-1/3/4/5/7/9), 2026-10-20:
  * L-1 (`fu` CLOSED): before the tombstone the requester must be in `old_state.members` (403 "You are not a member of this room") and not
    in the cheap ban read (403 "You are banned from this room"); `precheck_bans!/2` also checks the cap and that every ban is carriable
    (key limits; 500 before the tombstone). I-2: the same pre-check on the authoritative set after the freeze. I-3: a decline no-op whose
    reject meets an archived room stays `:ok` (no fallback leave). I-4: the failure audit row carries `old_room_archived` (true once the
    archive committed). I-1 / MINOR-2: the archived-room claims reworded to "every moderation, invite-event and decline write" (joins and
    member leaves are not covered). I-5: `fs` notes 4-5 lock waits per transaction. I-6: the scope doc notes that a concurrent unarchive
    reopens the old room (accepted).
  * MINOR-1: seam `:event_dispatcher, :room_terminate_fun` (default: Horde `terminate_child/2`); INFO-1: a dead local pid after a failed
    stop counts as stopped. MINOR-3: the failure-recovery wording (the tombstone stays; unarchive in the Admin UI, which restarts the
    process, and run `/upgrade` again; clean up the orphan room) and the step list of `upgrade_room`. MINOR-4: the invite row of the
    archived-room test is asserted `:rejected`. INFO-3: the stale D11 / cycle-1 test prose. INFO-5: `:room_archived` in the `moderate/6`
    `@doc`; `refused_invite_event!/4` raises the 404 directly.
  * CI (pre-existing since 891ed9ce): `user_id_length_test.exs` describe / test titles shortened (271 -> < 230 characters; Elixir 1.19
    refuses names above 255); `namelen.py` over all `.exs` files reports nothing above 240. INFO-9: five stale "continues at fk / fn"
    suite titles -> "continues at fv".
  * New tests: `server/test/nebu/matrix/moderation_fix_cycle3_http_test.exs` (non-member and banned requester, an uncarriable ban, the cap
    seam junk, the stop seam (fails while alive / error after the end), a failing archive, a failing members read, the I-3 gap test).

### File List

- `server/lib/nebu/matrix/room/server.ex`, `server/lib/nebu/matrix/room/db.ex`, `server/lib/nebu/matrix/event_dispatcher/server.ex`,
  `server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/web/rate_limit_tiers.ex`, `server/lib/nebu/compliance/audit_writer.ex`, `server/lib/pb/core.pb.ex`,
  `proto/core.proto`, `server/config/runtime.exs`, `docker-compose.yml`
- `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/08-concepts.md`, `CHANGELOG.md`, `docs/stories/oauth-broker/follow-ups.md`,
  this story
- Tests (re-pins / fakes): `server/test/nebu/matrix/event_dispatcher/{join_room,invite_user,create_room_invites,invite_caps,server_moderation_metadata,sync_membership_partition}_test.exs`,
  `server/test/nebu/web/unrecognized_routes_test.exs`

### Change Log

- 2026-10-19: story created (create-story, read-only premise check on HEAD `891ed9ce`); status ready.
- 2026-10-19: Oracle gate (no WRONG verdicts, `step-results/moderation-routes-atomic-ban/oracle-context.md`) applied: Nebu-choice /
  divergence labels in D2 (self-kick), D3 / D9 (503 `M_UNAVAILABLE` not a spec errcode), D6 (404 existence oracle), D10 (1024-byte cap,
  NUL) and the scope-doc AC17 (a); D11 labelled a deliberate deviation from the SHOULD NOT (bans re-issued in the upgrader's name, no
  row-only invitation for banned users); `fr` extended (bans before a copied `users` map, the SHOULD to lower the old room's levels);
  new AC19 (a)-(l) with the twelve missing tests (self-moderation, non-member levels, level boundaries and `users_default`, inviter
  revoke below kick, pre-emptive ban without prev_content, second unban, 401s on all three routes, forget behaviours, unbanned user
  invite / join, upgrade without invitations for banned users, percent-encoded room ids, exactly one event for a ban of a joined user).
  Ids `fq` / `fr` unchanged.
- 2026-10-19: test review (pre-dev) amendments applied by the dev step: E2E invitee "bob" -> kai, the Run-A grep includes "e2e kick" / "e2e disinvite";
  `membership_write_limits_docs_test.exs` "PARTIAL" / "no API can issue a ban" re-pin is covered by AC17 (b).
- 2026-10-19: dev step (status review). Deliberate re-pins (AC18), old -> new:
  * `join_room_test.exs`: the tests "ban_user removes the member, writes the ban event and removes AGAIN ..." and "a member that cannot be removed fails the ban ...
    after a join slipped in and the second removal fails" -> deleted (replaced by AC7 (a) on the real database); the `{:rejoin_on_ban, ..}` /
    `{:rejoin_then_fail_delete, ..}` hooks of the fake's `insert_event/1` -> deleted (they re-entered Room.Server from inside the write); the fake gains a real
    `apply_member_change/4` + `pending_invitation/2` + `event_id`; N-5 kick "a failing rejection (twice) is a 500, a rejection that fails once is retried and the
    kick succeeds" (`calls(:reject_invitation) == 2`) -> "a failing rejection is a 500 and rolls the whole kick back (one transaction); a retry succeeds"
    (`calls(:apply_member_change) == 1`, still a member, invitation still pending).
  * `invite_user_test.exs`, `create_room_invites_test.exs`, `invite_caps_test.exs`, `server_moderation_metadata_test.exs`, `sync_membership_partition_test.exs`:
    fakes only (a real `apply_member_change/4`, `pending_invitation/2` where invitations exist, `event_id` in the latest member event); no assertion changed.
  * **Finding (outside the AC18 list, mechanical):** `server/test/nebu/web/unrecognized_routes_test.exs` pins the exact set of route clauses of the protected
    router; the three new clauses `POST /client/v3/rooms/:p/kick | ban | unban` are added to its list (they are exercised there: 401 without a token).
  * Decision: `Room.Server.moderate/6` with `outcome: true` (the dispatcher's audit facts come from the room process; `moderate/5` stays exactly `:ok`).
  * Decision: every moderation transaction runs with `remove_member: true, reject_invitation: true` (D3 listed fewer flags for revocation / unban; the
    superset closes a legacy half state on every path and is a no-op otherwise).
  * ~~Decision: `Room.Server.remove_member/2` kept~~ (SUPERSEDED by review cycle 1, M2: removed) (test seam of `sync_membership_partition_test.exs`, no production caller).
- 2026-10-19: review cycle 1 (code review MINOR M1-M7 / I1 / I6 / I7, Kassandra M-1 / L-2 / L-3 / I-6 applied; L-1 / L-4 documented as `fs` /
  `ft`). Re-pins, old -> new: the id-line assertion "`fs` onward" -> "`fu` onward" in the eight docs suites (`fs`-`ft` are used now);
  `sync_membership_partition_test.exs` `remove_member!/2`: `Room.Server.remove_member/2` -> `:sys.replace_state/2` on the room process
  (the lib function is removed); `membership_write_limits_docs_test.exs`: comment only. Behaviour changes: a kick of a member behind a ban
  is 403 (was: kicked, which lifted the ban); a concurrently revoked invitation is 403 "The user is not in this room" (was: an invite
  event behind a rejected row); a decline after a revocation writes no second leave; an upgrade of a room with more than 10 000 bans is
  403; the decline of a room that cannot be started and is not archived is 503 (was: the out-of-process write).


- 2026-10-20: review cycle 2 (Kassandra L-5 freeze first, I-10, I-11, I-16; code review MINOR-1-5, INFO-8). Re-pins, old -> new: the id-line
  assertion "`fu` onward" -> "`fv` onward" in the eight docs suites (`fu` is used now); the titles "continues at fs" -> "continues at fv"
  (`event_size_limit_docs_test.exs`, `moderation_routes_docs_test.exs`); the I-6 test bound 4 000 ms -> 2 500 ms (lock_timeout 1 s). The
  cycle-1 M-1 seam test is unchanged and still green (its ban now lands before the freeze and is read by the authoritative read).
  Behaviour changes: the old room is archived and stopped right after the tombstone; an archived room refuses every moderation, invite-event and decline write
  (404 for moderation and the invite event).
- 2026-10-20: review cycle 3. Re-pins, old -> new: `moderation_routes_docs_test.exs` (my cycle-2 pin) `fu` status "open" -> "closed" and its
  title; the titles "... continues at fk" / "fn" -> "continues at fv" in `create_room_invites_docs_test.exs`, `create_room_presets_docs_test.exs`,
  `member_prev_content_docs_test.exs`, `membership_write_limits_docs_test.exs`, `sync_membership_partition_docs_test.exs` (titles only);
  `user_id_length_test.exs` (outside this story, pre-existing CI blocker): the describe "AC11 (a) - server names that leave little room
  (hashed form), and the boundary of the configuration check" -> "AC11 (a) - short-room server names (hashed form) and the config check
  boundary" and the `server_name_leaves_room?/1` test title shortened (titles only); `moderation_fix_cycle2_http_test.exs` `!= :pending` ->
  `== :rejected` (stricter). Behaviour changes: an upgrade by a non-member or a banned requester is 403; an uncarriable ban fails the upgrade
  before the tombstone.

