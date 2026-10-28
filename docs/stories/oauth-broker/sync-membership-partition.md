---
story_id: sync-membership-partition
title: "/sync partitioned by membership: rooms.join = joined rooms only, rooms.invite with stripped invite_state (m.room.create, the invitee's own invite event with is_direct), rooms.leave bounded at the leave / kick / ban event, nothing after it (follow-ups ev + ez, the release gate of the createRoom batch)"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-17
branch: feature/migrate-to-oauth2
---

# Story: `/sync` partitioned by membership: `rooms.join` / `rooms.invite` / `rooms.leave` (follow-ups `ev` + `ez`)

As a Matrix user (Element Web) who is invited to a DM, a private room or a private Space, I want to see the invitation in my room list
and accept or decline it, and I want a DM to be marked as a direct chat with the person who invited me, so that invite-only rooms are
usable without typing `/join <room id>`.
As a user who left a room, was kicked, banned, removed by an Admin, or who declined an invitation, I want the server to stop sending me
that room's events at the point where my membership ended, and as an operator / compliance officer I want this to be a hard server
guarantee (data minimisation, no access after removal), so that `/sync` never delivers a room's content to someone who is not in it.

Follows `create-room-invites-direct` (the shared invite path, the signed `m.room.member` invite event with `is_direct`, the interim guard
D11 that this story REPLACES) and `create-room-presets-power-levels-topic` (join enforcement, bans enforced on join, the `InviteDB` re-arm).
This story closes `ev` and `ez`; after it the release gate is `ey` (rate limits / invite caps / invite blocking) and `ex` (the ban route).

## Premises verified against the code (2026-10-17, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `1dd91309`)

Every premise below was checked in the code and tests of this branch (the dev containers are stopped, so no `bin/nebu rpc` probe was
possible: the premises are code-level and are pinned by the acceptance tests), in the local spec copy
`skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html`, and in the Element Web 1.12.15 bundle chunks copied out of the
stopped container `nebu-oauth-dev-element-1` during the previous story (`init.js`, `7878.js`, `1471.js`; the matrix-js-sdk code is in
`7878.js` / `1471.js`).

### The HTTP layer (`server/lib/nebu/web/router/protected.ex`, `server/lib/nebu/matrix/http.ex`)

| Question | Verified state |
|---|---|
| `rooms.invite` / `rooms.leave` | **Always `%{}`.** `Nebu.Matrix.Http.sync_response/3` (http.ex l.137-153) emits `"invite" => %{}` and `"leave" => %{}` unconditionally (moduledoc "MINOR-2": the proto `SyncRoom` has no membership; the Go `buildInviteRooms` / `buildLeaveRooms` were never ported). `ev` premise CONFIRMED. |
| `rooms.join` renderer | `build_joined_rooms/2` (l.155-274): `state.events` (ClientEventWithoutRoomID incl. `event_id` / `origin_server_ts`, `unsigned.age` / `replaces_state`), `timeline.events` (incl. a `room_id` key, `unsigned.age`, `state_key` only for `is_state_event`), `limited`, `prev_batch`, `account_data.events`. No `ephemeral` section (typing is not delivered in `/sync` at all). |
| `do_sync/1` (l.85-179) | Splits `since` into `<core>[.<room account data pos>]`; calls `get_sync_delta/2` with **`device_id: ""`** (l.115-120) or `get_initial_sync/2`; room account data via `RoomAccountDataStore.list_for_sync/3` (the SQL already restricts it to rooms with an ACTIVE `room_members` row, room_account_data_store.ex l.256-266); **account-data-only rooms are added to `rooms.join` as empty entries** (`extra_rooms`, l.152-163) for every room id that has room account data changes and is not in the delta; `newly_joined_room_ids/2` (l.206) detects the user's join event in a timeline to deliver ALL account data of that room. |
| Since token: per user or per device? | **Per USER.** The route always passes `device_id: ""`, so `get_sync_delta/2` uses `pg_store_module().get_since_token(user_id)` / `persist_since_token/3` (the `sync_tokens` row with `device_id = ''`, pg_store/postgres.ex l.6-30). The client token must equal the stored token (`client_since_token != stored_token` -> fallback to a full initial sync, server.ex l.4312). Two clients of the same user therefore overwrite each other's token and alternate into initial-sync fallbacks. The per-DEVICE position exists only for room account data (the `.pos` suffix in the client's own token). Pre-existing, NOT fixed here (new follow-up `fd`). |
| Anchor | The core token is `base64("user:last_event_id:monotonic")`; `last_event_id` = the event with the max `origin_server_ts` over the delivered timelines (`generate_delta_token/3`, l.4641-4657; initial: l.4232-4239). `fetch_events_since/3` (room/db.ex l.477-523) resolves `since_ts = get_event_timestamp(last_event_id)` (one extra query PER ROOM) and reads `origin_server_ts > since_ts ORDER BY ts ASC LIMIT 20` per room. Consequences (pre-existing, new follow-up `fc`): events in the same millisecond as the anchor are skipped; a room truncated at its oldest 20 loses its remaining events when another room delivers a newer event (the anchor is the max over all rooms); an event committed late with a timestamp below the anchor is never delivered. |

### The core (`server/lib/nebu/matrix/event_dispatcher/server.ex`)

| Question | Verified state |
|---|---|
| Initial sync (`get_initial_sync/2`, l.4127-4253) | Joined rooms only: `get_rooms_for_user/1` (= `room_members.left_at IS NULL`) minus `forgotten_room_ids/1`; per room (`Task.async_stream`, max 5) `build_state_events/3` (current state), the last 20 events, `attach_heroes`; persists the token via `persist_since_token/3`. No invites, no left rooms. |
| Incremental sync (`do_incremental_sync/4`, l.4353-4525) | `room_ids = get_rooms_for_user ++ get_pending_invite_rooms_for_user ++ get_declined_invite_rooms_for_user ++ get_recently_left_rooms_for_user` (left = `left_at IS NOT NULL`, **no time bound**, room/db.ex l.315-336) minus forgotten; the D11 interim guard (l.4391-4412) removes rooms that are ONLY pending (`pending_only_room_ids`) from the FETCH set but keeps them subscribed; `fetch_delta_rooms/3` (l.4534-4603) ships every fetched room with events newer than the anchor into the **one** `rooms` list, which the HTTP layer renders as `rooms.join` with the FULL current state (`build_state_events/3`) and timeline. Read errors of the four lists are swallowed (`{:error, _} -> []`). |
| `ez` premise | **CONFIRMED.** A user who LEFT (self-leave, `Room.Server.leave` -> `delete_member` + leave event), was KICKED (`kick_user/2`: `remove_member` + leave event with sender = kicker), BANNED (`ban_user/2`: `remove_member` + ban event + second `remove_member`), REMOVED by an Admin (`admin_remove_room_member/3` -> `leave_room/2`, written as a SELF-leave), and a user who DECLINED (`leave_without_room_process/3`: `reject_invitation` + `emit_decline_event/2`) is in the left / declined list forever (until `POST /forget`), so every new event of that room, message content included, is delivered in `rooms.join`. A re-invited former member is in the pending AND the left list, so D11 does not cover him (pinned as the `ez` residual). |
| Pins of today's behaviour | `forget_room_membership_purge_test.exs` AC4 (l.246-279: the control asserts a left room re-surfaces in some section, the comment l.237-244 says "rooms.JOIN"; NOTE: its final `sync(token, since=<the OLD since>)` reuses a token that the control call already replaced, so it is in fact an INITIAL-sync fallback, not an incremental sync); `sync_test.exs` describe "interim guard for pending-invite-only rooms (D11)" (l.2388-2548, 8 tests: pending-only not delivered; pending + left delivered (`ez` pin); declined delivered (`ez` pin); left delivered (`ez` pin); pending-only events do not wake (L-3); `{:new_invite}` wakes with NO rooms); `create_room_invites_http_test.exs` describe "AC12 - the invitee's incremental /sync (interim guard D11)" (l.853-895: no `rooms.invite`; initial sync without the invite; the re-invited former member pinned in `rooms.join`). |
| Wake-ups | `do_incremental_sync/4` joins `user:<id>` and `room:<id>` for ALL rooms of the combined set (left and declined included), BEFORE the DB check. `{:new_event, ev}` re-runs `fetch_delta_rooms` with the stale room list (except D11 rooms); `{:new_invite, _}` and `{:new_leave, _}` return `[]` ("Go's buildInviteRooms / buildLeaveRooms can find it": nothing does); `{:new_join, room}` subscribes the room and re-fetches; `{:account_data_changed, _}` returns `[]` (the HTTP layer re-reads account data). Senders: `write_invitation!/4` l.2669 (`{:new_invite}` to `user:<invitee>`), `join_room/2` l.1679 (`{:new_join}`), `leave_room/2` l.2304 (`{:new_leave}`), `emit_membership_event/3` (room/server.ex l.658), kick / ban / unban / decline (`{:new_event}` to `room:<id>`), `upgrade_room` l.6459 (`{:new_invite}` for row-only invitations). ALL use `:pg.get_local_members/1` except `RoomAccountDataStore.notify_sync/2` (`:pg.get_members/1`): wake-ups do not cross nodes (pre-existing, cluster-safety skill says `:pg.get_members`; new follow-up `fe`). |
| Membership sources | **Rows:** `room_members (room_id, user_id) PK, joined_at, left_at` (one row per pair; a re-join sets `left_at = NULL` and a new `joined_at`, room/db.ex l.53-60); `room_invitations (room_id, invitee_id) PK, inviter_id, invited_at, accepted_at, rejected_at` (one row per pair, re-armed by a new invite, invite_db.ex l.9-17); `forgotten_rooms (user_id, room_id, forgotten_at_ms)`. **Events:** `m.room.member` with `state_key = user`, `content.membership` in `join` / `leave` / `ban` / `invite` (and `knock` in theory: Nebu has no knock route). `content` is a JSONB object OR a double-encoded JSONB string (both forms are read by `get_member_membership/2`, `get_room_create_event/1`). The member SET of the room process (`Room.Server` state, loaded from `room_members` on init) is what `/messages`, `/send`, `/invite` authorise against. |
| Event writes are fail-open | `emit_membership_event/3` (join / self-leave) only logs on a failed insert: a membership can change without an event. `ban_user/2`: `remove_member` BEFORE the ban event, a failing ban event is a 500 with the member already removed; the N-6 half state of `ex` (second removal fails) leaves a member whose latest event is `ban`. The decline: `reject_invitation` BEFORE `emit_decline_event/2` (fail-open). So the rows and the latest event can disagree. |
| Latest-membership read | `@sql_get_member_membership` (room/db.ex l.1527-1549): `ORDER BY origin_server_ts DESC LIMIT 1`, **no tie-break** (follow-up `eu`); index `events_room_state_idx (room_id, event_type, state_key, origin_server_ts DESC) WHERE state_key IS NOT NULL` (000001_init.up.sql l.227-228). There is NO index led by `state_key`, so a "latest member event of user U across all rooms" query without a room list would scan; a query by `room_id = ANY($1) AND event_type = 'm.room.member' AND state_key = $2` is served by `events_room_state_idx` (one range scan per room). `room_members_user_id_idx` and `room_invitations_invitee_idx` exist. |
| Row-only invitations | `upgrade_room` (l.6452-6465) writes only `room_invitations` rows (no invite event; D12 of the previous story) and wakes with `{:new_invite}`; every invitation created before story create-room-invites-direct is row-only too. |
| createRoom invite timestamps | createRoom step 8 (`emit_invites/5`, l.2740-2746) stamps each invite `max(now, previous + 1)`: up to ~70+ ms AHEAD of the clock for a long chain (follow-up `eu`, Kassandra F-4). An invite event used as an anchor can therefore be ahead of real time. |
| `{:new_invite}` timing (Kassandra L-4 note in `ev`) | `write_invitation!/4` wakes the invitee right after EACH invite event, inside step 8, before step 8 (and so createRoom) has succeeded; a failing later invite makes createRoom delete the room (`cleanup_orphan_room/1`) while an earlier invitee may already have been woken. |
| Forget | `forget_room/2` (l.5636) records `forgotten_rooms` for any non-member (a pending invitee included); `unforget_room/2` (l.61) runs on join only. An invitation does NOT clear a forget today. Spec: "Rooms which have been forgotten will never appear in the response to the /sync API, until the user re-joins, is re-invited, or knocks." |
| Ignored users | **Not implemented anywhere** (`grep ignored_user` in `server/lib`: no hit). `m.ignored_user_list` is stored as opaque global account data (`AccountDataStore.get/2`, account_data_store.ex l.87-97: `{:ok, json} | :error`, `:error` for "absent" AND for a DB error). |
| `/versions`, `full_state`, filters | `GET /_matrix/client/versions` (`Nebu.Matrix.HttpPublic.versions_body/1`, http_public.ex l.314-340) advertises v1.1-v1.15 while the OAuth 2.0 API is offered, else v1.1-v1.11: never v1.16+, so `use_state_after` (v1.16) is not claimed. `do_sync/1` reads only `since` and `timeout`: `full_state`, `filter` (incl. `include_leave`), `set_presence` and `use_state_after` are IGNORED (a `full_state=true` request with `since` long-polls like any incremental sync). |
| Taken-back invitations (Oracle correction 1) | The join decision (`authorize_join!/2`, server.ex l.1742-1770) grants an invite-only room on a PENDING ROW alone (`pending_invite?/2` l.1873: `room_id in get_pending_invite_rooms_for_user`); it does not look at the latest member event. Every writer that ends an invitation rejects the row, but several only best effort: `leave_room/2` -> `reject_invitation_guarded/2` (l.2309, failure = warning), `leave_without_room_process/3` (l.2371: result IGNORED, the decline event is written anyway), Admin removal (through `leave_room/2`). A failed reject leaves a row that is still pending behind a `leave` member event NEWER than `invited_at`: today that user stays joinable and (with rule 4 as first written) would be shown the invitation again. `kick_user/2` / `unban_user/2` reject strictly (retry, else 500) BEFORE writing, so they cannot produce it. |
| Ephemeral / account data per room | No `ephemeral` section exists. Room account data: per device position, joined rooms only (above). Global account data: consume-once flag per USER (pre-existing; not touched). |

### Spec (Matrix CS API v1.18, local copy `client-server-api/index.html`)

- `/sync` response: `rooms.join` "The rooms that the user has joined"; `rooms.invite` "The rooms that the user has been invited to", each
  `{"invite_state": {"events": [StrippedStateEvent]}}`; `rooms.leave` "The rooms that the user has left or been banned from", each Left Room
  `{account_data, state, timeline}` with `timeline` = "The timeline of messages and state changes in the room **up to the point when the user
  left**" and `state` = "The state updates for the room up to the start of the timeline"; `rooms.knock` (not used by Nebu).
- Stripped state: "Stripped state events can only have the `sender`, `type`, `state_key` and `content` properties present." The server
  SHOULD include `m.room.create`, `m.room.name`, `m.room.avatar`, `m.room.topic`, `m.room.join_rules`, `m.room.canonical_alias`,
  `m.room.encryption`; "[Changed in v1.16] The `m.room.create` event is now **required** in ... `invite_state` and `knock_state` on `/sync`
  responses." "The server might include events not described here as well."
- Leaving rooms: "A user can leave a room to stop receiving events for that room ... Once a user leaves a room, it will no longer appear in
  the response to the /sync API unless it is explicitly requested via a filter with the `include_leave` field set to true" (filter default
  `include_leave: false`). "Rooms which have been forgotten will never appear in the response to the /sync API, until the user re-joins, is
  re-invited, or knocks." Kicked users: "the behaviour is the same as if they had left of their own accord".
- History visibility (Oracle context of the previous story): after leaving, a user receives no events sent after the leave.
- Ignoring users: "Servers must not send room invites from ignored users to clients." (Also: "Once ignored, the client will no longer
  receive events sent by that user, with the exception of state events": the timeline part is NOT in this story, follow-up `fg`.)
- Oracle gate of the previous story (`_bmad-output/nebu/epics/oauth-broker/step-results/create-room-invites-direct/oracle-context.md`): "sync:
  rooms.join = joined rooms, rooms.invite stripped state (m.room.create REQUIRED since v1.16), rooms.leave = left or banned, timeline up to the
  leave; ... ignored users' invites must not be sent"; "For ev: invitee's own invite member event in invite_state is an interop MUST
  (getDMInviter); m.room.create MUST; ignored-user invites suppressed; M_INVITE_BLOCKED" (the last one stays `fa` (b) / `ey`).

### What Element Web 1.12.15 (matrix-js-sdk in chunks `7878.js` / `1471.js`) does with the sections

| Flow | Verified behaviour |
|---|---|
| `rooms.invite` | `SyncApi`: for every invite room `mapSyncEventsFormat(e.invite_state, room)` -> `injectRoomEvents(room, stateEvents)`; a brand-new room is stored and emitted (`ClientEvent.Room`). The sync accumulator merges a repeated `invite_state` per `(type, state_key)` (`accumulateInviteState`), so a repeated invite is idempotent; an entry in `rooms.join` or `rooms.leave` deletes the accumulated invite. |
| Invitee's membership / DM marking | `Room.getMyMembership()` comes from the user's own member event in the (stripped) state; `Room.getDMInviter()`: `getMember(me).getDMInviter()` = the own member event with `membership: "invite"` and `is_direct: true` -> its `sender`; after the JOIN it reads the join event's `prev_content` and `unsigned.prev_sender` (Nebu never sends `prev_content` / `prev_sender`: after the join Element relies on its `m.direct` account data; whether Element writes `m.direct` on accept is UNVERIFIED in the copied chunks, the e2e step asserts it). Without the own member event and with 2 invited+joined members it falls back to `heroes[0]` (Nebu attaches no heroes to invite rooms). **So the own invite member event is REQUIRED for the invitation to appear at all and for the DM marking.** |
| `rooms.leave` | Processed like a joined room's timeline (state + timeline injected, membership `leave`), then Element moves the room out of the list (archived / historical). The accumulator deletes the room from its joined / invite set. A separate `LEFT_ROOMS` filter request (`include_leave`) is only used by the "historical rooms" view (Nebu ignores filters: it would return `{}` there, acceptable). |
| e2e | `e2e/features/element/dm/create-dm.feature` scenario 3 "marie sees the DM invitation in Element and accepts it" is tagged `@pending-feature @needs-ev` (excluded by `DEFAULT_E2E_TAGS = 'not @pending-feature and not @short-ttl and not @known-failure'`, `e2e/playwright.config.ts` l.29); steps in `e2e/step-definitions/element/dm.steps.ts` l.436-493 (invite tile `[aria-label^="Open room"][aria-label*="invitation"]` with the inviter's name, Accept, joined + `m.direct` lists the DM under the inviter). `e2e/features/element/room/join.feature` @ac8-join-room passes today only because its step "the invite for {string} appears in {word}'s sidebar" NAVIGATES to the room-id URL instead of waiting for the tile (`room.steps.ts` l.129-148). |

### Sizing evidence (why this is ONE coherent story, comparable to create-room-invites-direct / the presets story)

| Area | Size |
|---|---|
| Core | `get_initial_sync/2` (127 lines), `do_incremental_sync/4` (173 lines) and `generate_delta_token/3` are rewritten around ONE partition function; `fetch_delta_rooms/3` stays (joined rooms); new: the partition, the invite-state builder, the leave-window builder (~300-400 new lines). createRoom step 8 wake deferral, invite -> unforget (~30 lines). |
| DB | 4 new inline-SQL reads in `Nebu.Matrix.Room.DB` (candidates, latest two member events per room, stripped state batch, leave window) + the tie-break in `@sql_get_member_membership`. No migration. |
| HTTP | `sync_response/5` with two new renderers (invite, leave), `do_sync/1` (join-set filter of `extra_rooms`), `Core.*` structs (3 new fields, 2 new structs). |
| Tests | New: unit partition suite (~30 tests on fakes), real-DB DB-read suite (~15), HTTP real-stack suite (~30), docs suite. Re-pinned: `sync_test.exs` D11 describe (8 tests) + the 6 fakes that the sync paths use (`sync_test.exs` 5 DB fakes + `server_dedup_test.exs` 1), `create_room_invites_http_test.exs` AC12 (3 tests), `forget_room_membership_purge_test.exs` AC4, `create_room_presets_http_test.exs` (comment), two docs suites. e2e: 2 scenarios become real + 1 new decline scenario. |
| Why not split | `ev` alone would make `ez` worse (a re-invited former member gets the room in BOTH sections); `ez` alone needs the leave partition, which is the same classification `ev` needs; the follow-ups say "ONE story". The anchor / multi-device / node-local wake-up defects found on the way are pre-existing and orthogonal: split out (`fc`, `fd`, `fe`). |

## The partition rule (normative)

**Inputs** for user `U`, read fresh at the start of every sync build (and again after a long-poll wake-up):

- `R_active` = rooms with a `room_members` row of `U` and `left_at IS NULL`; `R_left` = rooms with a row and `left_at IS NOT NULL`;
- `I_pending` = rooms with a `room_invitations` row of `U` (`accepted_at IS NULL AND rejected_at IS NULL`, with `inviter_id`, `invited_at`);
  `I_rejected` = rows with `rejected_at IS NOT NULL`;
- `F` = `forgotten_rooms` of `U`;
- for every candidate room `r` (`C = R_active ∪ R_left ∪ I_pending ∪ I_rejected`): the two newest `m.room.member` events with `state_key = U`,
  `L` (latest) and `P` (the one before), in the **tie order** `origin_server_ts DESC, rank ASC, event_id DESC` with
  `rank(ban) = 0 < rank(leave) = 1 < rank(invite) = 2 < rank(knock) = 3 < rank(join) = 4` (an unknown / unparseable membership has rank 1 and
  counts as `leave`): **in a same-millisecond tie the most restrictive membership is the latest** (`eu`'s rule, applied to every read of this
  story and to `@sql_get_member_membership`, D3).

**Class** of each `r ∈ C`, first match wins:

| # | Condition | Class |
|---|---|---|
| 1 | `r ∈ F` and `r ∉ R_active` | **none** (forgotten; a join clears `F`, and so does an invitation after this story, D7) |
| 2 | `L.membership == "ban"` | **leave** (ban), whatever the rows say (most restrictive: covers the `ex` N-6 half state, a member whose latest event is a ban) |
| 3 | `r ∈ R_active` | **join** (the row decides: it is the member set `/messages` and `/send` authorise against; a missing / failed join event or a legacy room without member events does not demote a member) |
| 4 | `r ∈ I_pending` and NOT (`L.membership == "leave"` and `L.origin_server_ts >= invited_at`) | **invite**, unless the inviter (`L.sender` when `L.membership == "invite"`, else the row's `inviter_id`) is in `U`'s `m.ignored_user_list` -> **none** (D8). A pending row behind a `leave` at least as new as the invitation is a TAKEN-BACK invitation (a decline, kick or removal whose row reject failed; `>=`: a tie counts as taken back, most restrictive): it falls through to rule 5 (D13) |
| 5 | `r ∈ R_left ∪ I_rejected ∪ I_pending` and `L.membership ∈ {leave, ban}` | **leave** (for a pending row only reachable through the rule-4 exclusion) |
| 6 | anything else (a left / rejected row whose leave event is missing because the write failed; `knock`; member events without rows) | **none** (value-free debug log for the missing leave event) |

**Delivery.** `since_ts` = the timestamp of the anchor event of the since token (`get_event_timestamp(last_event_id)`; `0` when there is
none), resolved ONCE per build.

| Class | Initial sync / fallback-to-initial | Incremental sync |
|---|---|---|
| join | as today: current state + the last 20 events (`get_initial_sync/2`) | as today: `fetch_delta_rooms/3` (events with `ts > since_ts`, oldest 20 first, current state, heroes on membership change, thread aggregations) |
| invite | always: `rooms.invite.<r>.invite_state.events` (D4) | only if NEW: event-backed (`L.membership == "invite"`): `L.origin_server_ts > since_ts`; row-only (no invite event): `invited_at > since_ts` (piggyback, D5) |
| leave | never (no `include_leave` filter support; spec default `false`) | only if NEW: `L.origin_server_ts > since_ts`; the entry is the **leave window** below, then never again |
| none | nothing | nothing |

**Leave window** (`rooms.leave.<r>`): `state.events = []`, `account_data.events = []`, and the timeline:

- if `P.membership == "join"` (the user was joined right before `L`): the events `E` of `r` with `max(since_ts, P.origin_server_ts) < E.ts < L.ts`
  (STRICT at both ends: an event in the same millisecond as the join or as the leave is excluded, most restrictive), the newest 20 by
  `(ts DESC, event_id DESC)` returned oldest-first; `P` itself first when `P.ts > since_ts` and the window is not limited; `L` last;
  `limited = true` when the middle read returned 20 (then `prev_batch` = the oldest delivered event id, as `fetch_delta_rooms/3` does, and `P` is
  not prepended), else `limited = false` and **`prev_batch` is OMITTED** (never `""`; Oracle correction 2). With `limited`, the state changes in the
  gap between `since` and the window start are NOT delivered (`state` is empty, D6): they are pre-leave events the user was allowed to see, nothing
  after the leave leaks (Oracle correction 5, documented in the scope doc);
- otherwise (declined invitation, banned or unbanned while invited, `P` absent or not `join`, a legacy room without a join event): the
  timeline is `[L]` only, `limited = false`.
- Nothing with `ts >= L.ts` other than `L` is ever read for a leave entry; no current state (it would carry name / topic / member changes made
  after the leave).

**Anchor (`next_batch`).** The newest event by `origin_server_ts` over: the delivered join timelines, the delivered leave timelines (so
`>= L.ts`) and the delivered event-backed invite events (`L` of each invite entry). Row-only invites never move the anchor. No delivered
event: the previous anchor (today's fallback).

**Early return / long-poll.** The build returns at once when it delivers at least one join room with events, one leave entry or one
event-backed new invite; row-only invites and account-data-only rooms do not end a wait by themselves (the HTTP layer keeps its own
"room account data pending -> timeout 0" rule). While waiting the task is subscribed to `user:<U>`, to `room:<r>` for every **join** and
**invite** room (never for leave / none rooms), and a message wakes it as follows:

| Message | Effect |
|---|---|
| `{:new_event, ev}` with `ev["room_id"]` in the join set | wake |
| `{:new_event, ev}` that is an `m.room.member` with `state_key == U` (any room: decline from another device, a ban of a pending invitee, a kick) | wake |
| any other `{:new_event, _}` (a message in an invite room, a member event of someone else in an invite room) | ignored, keep waiting with the ORIGINAL timer (D11's L-3 rule generalised) |
| `{:new_invite, _}`, `{:new_join, _}`, `{:new_leave, _}`, `{:account_data_changed, _}` | wake |
| `:sync_long_poll_timeout` | stop waiting |

**On wake: the WHOLE partition and delivery are rebuilt from fresh reads** (memberships may have changed: invite -> join, join -> leave), the
result is returned even if empty, and the token is persisted (today's semantics: a wake-up returns once).

### Edge cases (each is an AC6 row)

| Since token at `t0`; what happened after `t0` | Section of the next incremental sync | Content |
|---|---|---|
| invited | invite | stripped state incl. the own invite event (with `is_direct` for an Element DM) |
| invited, then joined | join | `fetch_delta_rooms`: the events after `t0` incl. the invite and the join event (history visibility of events before the join: unchanged, `es`) |
| invited, then declined | leave | `[decline leave event]` only (sender == state_key == U) |
| invited, then banned | leave | `[ban event]` only |
| joined before `t0`, then left / kicked / banned / removed by an Admin | leave | events in `(t0, L)` (max 20, limited) + `L`; nothing after `L` |
| joined after `t0`, then left | leave | `P` (the join) + events in `(P, L)` + `L` |
| joined before `t0`, left, re-invited | invite | the new invitation only (the leave is superseded; Element replaces the joined room by the invite) |
| joined before `t0`, left, re-joined (public room) | join | `fetch_delta_rooms` (events while away included: `es`, shared visibility) |
| left before `t0` (already delivered) + new messages | none | nothing (this is the `ez` fix) |
| declined before `t0` + new messages in the room | none | nothing (Kassandra I-3 harassment case) |
| pending before `t0` (already delivered) + new messages in the room | none | nothing, and the messages do not wake the long-poll |
| active row but latest member event `ban` (`ex` N-6 half state) | leave once (when the ban is new), then none | `[...window..., ban]`; never in `rooms.join` again, not even as an account-data-only room |
| left, then `POST /forget` | none | nothing |
| forgot, then re-invited | invite | the invite clears the forget (D7) |
| ban and join in the same millisecond | leave | the tie order makes `ban` the latest |
| an event of another user in the same millisecond as the kick | leave | excluded (strict upper bound) |
| a pending invitation from a user in `m.ignored_user_list` | none | suppressed (initial and incremental) |
| invited, then taken back (decline / removal written, row reject failed: row still pending, `L = leave` with `L.ts >= invited_at`) | leave once, then none | `[L]` only (sender = the kicker / remover, or U for a decline); never `rooms.invite` again; `POST /join` is 403 (D13) |
| invited, banned, then unbanned (`L = leave` from the unban, sender = the unbanner) | leave at most once per NEW `L`, never join | `[L]`; no `rooms.join`, no `rooms.invite` |
| a `full_state=true` request with `since` | as the incremental row, plus every joined room | returns at once; joined rooms carry their full current state (D14); new invite / leave entries as usual; a left room never in `rooms.join` |
| a row-only invitation (upgrade / legacy) | invite | synthesized own member event `{sender: inviter_id, type: m.room.member, state_key: U, content: {membership: invite}}`; delivered while `invited_at > since_ts`, may repeat until the anchor passes `invited_at` (idempotent in matrix-js-sdk), never ends a wait by itself |

## Decisions

- **D1 (one partition function, row-based join, ban override).** A single internal builder (suggested `sync_partition/2` returning
  `%{join: [room_id], invite: [...], leave: [...]}` with the per-room data) is used by `get_initial_sync/2`, `do_incremental_sync/4` and the
  wake-up rebuild; `get_rooms_for_user/1`, `get_pending_invite_rooms_for_user/1`, `get_declined_invite_rooms_for_user/1` and
  `get_recently_left_rooms_for_user/1` are no longer read by the sync (they stay for their other callers: the join decision uses the pending read;
  `get_recently_left_rooms_for_user/1` becomes unused by `server/lib`: **DECIDED (test review m11): keep it in `Room.DB` AND in `DBBehaviour`
  with a "not used by the sync since story sync-membership-partition" doc line**, so `room/db_behaviour_test.exs` (which requires the callback) and every
  fake that implements it stay unchanged). The join class is decided by the ROW (access-control parity), the latest event only ever
  DEMOTES (rule 2, `ban`): the classification can only remove delivery compared to the row, never add it. Rationale for rows over "latest event
  only": member event writes are fail-open (premise table), legacy rooms have members without member events, and `/messages` / `/send` authorise
  against the member set; a classification that disagrees with the authorisation would either hide rooms the user is in or show rooms he is not in.
- **D2a (names and return shapes of the reads, PINNED by the ATDD tests; test review m3).** All four live in `Nebu.Matrix.Room.DB` (inline
  parameter-bound SQL), are NOT `DBBehaviour` callbacks (the sync reaches them through `rooms_db_module()`; a module without one of them is
  `unavailable`, D10), and answer `{:ok, value}` | `{:error, reason}`:
  - `membership_candidates(user_id)` -> `{:ok, [%{room_id, kind: :member | :invitation, active, pending, inviter_id, invited_at, left_at}]}` (review cycle 1: `left_at` is the member row's end, nil while active and for invitation rows; D2 (a); a member
    row: `kind: :member`, `active` = `left_at IS NULL`, `pending: false`, `inviter_id` / `invited_at` nil; an invitation row: `kind: :invitation`,
    `active: false`, `pending` = neither accepted nor rejected, the row's `inviter_id` / `invited_at`; ACCEPTED invitation rows are not candidates; a
    re-invited former member is TWO candidates of one room);
  - `latest_member_events(room_ids, user_id)` -> `{:ok, %{room_id => [%{event_id, origin_server_ts, sender, membership, content}]}}` (D2 (b); at most
    two per room, NEWEST FIRST = `[L, P]`, tie order of D3; `membership` is NORMALISED: ban / leave / invite / knock / join, anything else, a
    non-string, a missing key or unparseable content is `"leave"` and must never make the statement fail; `content` decoded from both JSONB forms;
    a room without a member event of the user is absent or `[]`; `[]` as the room list answers `{:ok, %{}}` without a statement);
  - `invite_state_events(room_ids)` -> `{:ok, %{room_id => [%{"type", "state_key", "sender", "content"}]}}` (D2 (c); the first `m.room.create`, then the
    latest `state_key = ""` event of name, avatar, topic, canonical_alias, join_rules, encryption in this order, those that exist; no create event: none
    is invented, the core synthesizes it; the inviter's member event is read with `latest_member_events/2` of the inviter);
  - `leave_window_events(room_id, after_ts, before_ts)` -> `{:ok, [event_map]}` (D2 (d); STRICT bounds, newest 20, `(origin_server_ts DESC, event_id DESC)`,
    the columns of `fetch_events_since/3`);
  - `latest_member_event(room_id, user_id)` -> `{:ok, %{membership, origin_server_ts, sender} | nil}` and `InviteDB.pending_invitation(room_id, user_id)` ->
    `{:ok, invited_at | nil}` (D13).
  - review cycle 1: `inviter_member_events([{room_id, inviter_id}])` -> `{:ok, %{{room_id, inviter_id} => %{event_id, origin_server_ts, sender, membership, content}}}` is an OPTIONAL batched read (ONE statement for all inviters, MINOR-4 / Kassandra L-3; a rooms module without it, the unit fakes, is served per inviter by `latest_member_events/2`); `Room.DB.get_member_membership/2` returns the NORMALISED membership (unknown / non-string / missing / unparseable = `"leave"`, `nil` only without any member event, MINOR-2).
  The sync response structs carry `join_room_ids`, `invite_rooms` (`Core.SyncInviteRoom{room_id, invite_state: [Core.StrippedStateEvent{type,
  state_key, sender, content}]}`) and `leave_rooms` (`Core.SyncRoom`); an exception raised in the incremental sync task must be handed back and
  re-raised in the caller (a raise in the Task is an EXIT, not a `Nebu.Matrix.Error`: the 503 depends on it); a failed sync leaves no `:pg` group.
- **D2 (reads and their cost, no migration).** Three statements per build, independent of the number of rooms, plus one per new leave entry:
  (a) **candidates**: ONE statement over `room_members` and `room_invitations` of `U` (`UNION ALL`, served by `room_members_user_id_idx` and
  `room_invitations_invitee_idx`) returning `room_id`, the row kind and `active` / `pending` / `inviter_id` / `invited_at`;
  (b) **latest member events**: ONE statement for all candidate rooms: `row_number() OVER (PARTITION BY room_id ORDER BY origin_server_ts DESC,
  <rank> ASC, event_id DESC)` over `events WHERE room_id = ANY($1) AND event_type = 'm.room.member' AND state_key = $2`, keeping `rn <= 2`, returning
  `room_id, rn, event_id, origin_server_ts, sender, membership, content` (content decoded from BOTH JSONB forms, as `get_member_membership/2`);
  it is served by `events_room_state_idx` (one small range scan per room: the user's own member events, typically 1-5 rows);
  (c) **stripped state** (only when there are invite entries): ONE statement for all invite rooms (D4);
  (d) **leave window**: one statement per NEW leave entry (`room_id = $1 AND origin_server_ts > $2 AND origin_server_ts < $3 ORDER BY
  origin_server_ts DESC, event_id DESC LIMIT 20`, `events_room_id_ts_idx`).
  Plus `get_event_timestamp/1` once for `since_ts`, `forgotten` (existing) and the ignored list (D8, only when there are invite candidates).
  For a large account (2 000 rooms ever joined / invited) statement (b) is 2 000 index range scans in ONE round trip; today's incremental sync already
  runs `get_event_timestamp` + `fetch_events_since` PER ROOM of the (unbounded) combined list, i.e. 4 000+ round trips for the same account, so the
  new shape is cheaper, not more expensive. The dev records `EXPLAIN (ANALYZE, BUFFERS)` of (a), (b) and (d) on a seeded dev DB (500 rooms, 20 member
  events each) in the Completion Notes; a sequential scan of `events` in (b) is a blocker (then the predicate is rewritten so the partial index
  applies, still no migration). The joined-room path (`fetch_delta_rooms/3`) keeps its per-room reads (unchanged, out of scope; `fc` notes the
  per-room `get_event_timestamp`).
- **D3 (tie order).** `rank` as in the rule; the same `ORDER BY origin_server_ts DESC, <rank> ASC, event_id DESC` is applied to
  `@sql_get_member_membership` (used by the join decision, the ban check in `Room.Server`, the invite path and the room summary): a same-millisecond
  `join` + `ban` now reads `ban` everywhere, so the partition and the access decisions agree. This closes the READ side of `eu` for member events;
  the WRITE side (stamping `max(now, latest_for_slot + 1)`) and the non-member slots (PUT state, join rules) stay `eu` (row note).
- **D4 (`invite_state`).** Stripped events (exactly the four keys `type`, `state_key`, `sender`, `content`; no `event_id`, `origin_server_ts`,
  `unsigned`, `signatures`), in this order: `m.room.create` (the room's FIRST create event, as `get_room_create_event/1`; a legacy room without one gets
  a synthesized `{"type": "m.room.create", "state_key": "", "sender": <get_room_creator/1 or the inviter>, "content": {"creator": <same>,
  "room_version": Nebu.Matrix.RoomVersions.default()}}`, the same fallback `build_state_events/3` uses: the spec REQUIRES the create event since v1.16),
  then the latest event with `state_key = ""` of each of `m.room.name`, `m.room.avatar`, `m.room.topic`, `m.room.canonical_alias`,
  `m.room.join_rules`, `m.room.encryption` that exists (current state at sync time, as Synapse does), then the INVITER's latest `m.room.member`
  (when it exists; Synapse includes the sender's membership; Nebu's content is `{"membership": "join"}`), then the invitee's OWN invite member event
  (`L` when `L.membership == "invite"`, with its real `sender` and `content` incl. `is_direct`; row-only invitation: synthesized
  `{"type": "m.room.member", "state_key": U, "sender": inviter_id, "content": {"membership": "invite"}}`). Nothing else: no history, no
  power levels, no history_visibility / guest_access, no member list, no heroes. `content` is the stored content decoded from either JSONB form.
- **D5 (newness and the anchor).** An event-backed invite or a leave is NEW iff its event's `origin_server_ts > since_ts` (strict, as
  `fetch_events_since/3`); delivering it moves the anchor to at least its timestamp, so it is delivered exactly once and the next sync waits
  (no hot loop). Row-only invitations have no event id to anchor on: `invited_at > since_ts`, delivered in every build while that holds
  (idempotent for clients), never an early return, never a wake on their own except the existing `{:new_invite}` of `upgrade_room` (that wake
  returns once, the next sync waits). Invitations and leaves that are OLDER than a client's token are not delivered incrementally: they appear
  with the next initial sync (Element: new login or "Clear cache and reload"). This is the release-note item for invitations that exist before
  this story is deployed. The residuals of a timestamp anchor (same millisecond as the anchor, late commits, createRoom invite events stamped
  ahead of the clock moving the INVITEE's anchor ahead by up to ~70+ ms) are follow-up `fc`, which this story extends (it does not fix them).
- **D6 (leave window, no state).** As in the rule. `state.events = []` (Nebu has no historical state resolution; the current state would leak
  changes made after the leave: data minimisation; the client keeps the state it had while joined), `account_data.events = []` (room account data is
  joined-only, premise), no heroes, no thread aggregations, no `unsigned.replaces_state` (plain timeline events rendered with the existing event shape
  incl. `unsigned.age`). A `limited` window carries `prev_batch` like the join path, a non-limited window has NO `prev_batch` key, and the state gap of a limited window
  is documented; `/messages` for a leaver is 403 (`get_messages/2` checks the
  member set): Nebu does not let leavers paginate their own pre-leave history (known deviation, spec allows it by history visibility: follow-up `fg`).
- **D7 (forget and re-invite).** The invitation write (`write_invitation!/4`, the shared path of `POST /invite` and createRoom step 8) clears a
  forget of the invitee for that room (`unforget_room/2`, best effort as on join) AFTER the invite event was written: spec "until the user re-joins,
  is re-invited". `upgrade_room`'s row-only invitations do not clear it (the upgraded room is a NEW room id, nothing to clear). A user who forgets a
  PENDING invitation (allowed today, spec says 400 "has not left": follow-up `fg`) hides it (rule 1).
- **D8 (ignored users, in scope: sync side only).** The spec MUST "Servers must not send room invites from ignored users to clients" is
  implemented in the partition: `m.ignored_user_list` is read once per build (`AccountDataStore.get(U, "m.ignored_user_list")`, only when there are
  invite candidates); `content.ignored_users` is an object whose KEYS are user ids; an invitation whose inviter is a key is class none (initial and
  incremental). Absent, `:error` (the store conflates "absent" and a DB error: fail open, an ignore list is a UX filter, not an access boundary:
  documented), malformed JSON or a non-object `ignored_users` -> no suppression (value-free debug log). Un-ignoring a user does not re-deliver older
  invitations incrementally (D5 applies; initial sync shows them). NOT in scope: filtering ignored users' timeline events (`fg`),
  `m.invite_permission_config` / `M_INVITE_BLOCKED` (`fa` (b), part of the `ey` gate), rejecting the invite server-side.
- **D9 (createRoom wake deferral, Kassandra L-4).** createRoom step 8 collects the `{:new_invite, room_id}` wake-ups of its invitees and sends
  them only after step 8 (the last step) has succeeded; a failing step 8 sends none. `POST /rooms/{id}/invite` keeps waking at once (the room exists).
  New / touched broadcasts of this story use `:pg.get_members/1` (cluster-safety skill); the existing `get_local_members` senders are `fe`.
  Residual (documented for the security review): an invitee whose sync runs in the milliseconds between a committed invite event and the end of
  step 8 can see the invite and race a `POST /join` against the orphan cleanup (pre-existing class, much narrower than an immediate wake).
- **D10 (fail closed).** A failing candidates, membership, stripped-state or leave-window read makes the whole sync answer `503 M_UNAVAILABLE`
  ("Core is temporarily unavailable", `Nebu.Matrix.Status.unavailable()`), with NO token persisted (the client retries with the same token). `M_UNAVAILABLE` is not a spec errcode (the spec only requires `errcode` + `error`):
  kept for consistency with every other `unavailable` answer of Nebu (`Http.map_error/1`), documented in the scope doc sync row. Never a
  partial classification (a missing ban would deliver a banned user's room; a missing leave window must not fall back to `fetch_delta_rooms`). A unit
  fake without the new reads is treated the same way (raise unavailable), never as "no memberships". The forgotten read keeps its current
  degradation (empty set on error: it can only re-show a NEW leave or a forgotten pending invite once); the ignored list: D8.
- **D11 (structs and HTTP).** `Core.GetInitialSyncResponse` and `Core.GetSyncDeltaResponse` get `invite_rooms: []` (`%Core.SyncInviteRoom{room_id,
  invite_state: [%Core.StrippedStateEvent{type, state_key, sender, content}]}`, `content` a JSON string like the other proto-shaped structs),
  `leave_rooms: []` (`%Core.SyncRoom{}` with `state_events: []`) and `join_room_ids: []` (the WHOLE join class, delivered or not); `rooms` stays the
  delivered join rooms (every existing reader of `response.rooms` keeps working). `Nebu.Matrix.Http.sync_response/5` (`next_batch, rooms,
  room_account_data, invite_rooms, leave_rooms`) renders `rooms.invite.<id> = {"invite_state": {"events": [...]}}` and `rooms.leave.<id> =
  {"state": {"events": []}, "timeline": {"events", "limited", "prev_batch" (ONLY when limited)}, "account_data": {"events": []}}` (timeline
  events with the same shape as join timelines); the moduledoc "MINOR-2" paragraph and comments are replaced. `do_sync/1` adds account-data-only rooms (`extra_rooms`) ONLY for
  ids in `join_room_ids` and never for an id present in `rooms.invite` / `rooms.leave` of the same response (a ban-override room with an active row
  must not come back as an empty joined room). A room id appears in at most ONE section of a response. `proto/core.proto` gets a comment-parity note
  (no codegen, hand-edited structs as before).
- **D12 (what is NOT changed).** The join delivery (`fetch_delta_rooms/3`, `build_state_events/3`, heroes, thread aggregations, `limited` /
  `prev_batch`, the per-room `get_event_timestamp`), room account data positions, global account data, device lists / E2E counts, the since-token
  storage (per user: `fd`), the event writers (kick / ban / leave / decline / join / invite) apart from D7 / D9, `upgrade_room` (row-only invitations
  stay: `fb`), `/initialSync`, `/joined_rooms`, `/members`, the room summary, `m.room.member` content (no `displayname`, no `prev_content`).
  No migration. Filters (`filter=`, `include_leave`, `lazy_load_members`, timeline `limit`) stay unsupported: a KNOWN DEVIATION, documented in the
  scope doc sync row (`fg` (a)); an initial sync with `include_leave: true` still has `rooms.leave = {}` (pinned, AC21).
- **D13 (the join decision honours a taken-back invitation; small, in scope).** `authorize_join!/2` counts an invitation only when the row is
  pending AND the user's latest member event is not a `leave` with `origin_server_ts >= invited_at` (the rule-4 predicate; a `ban` is refused before).
  Implementation: the pending row WITH `invited_at` (new `InviteDB.pending_invitation/2` -> `{:ok, invited_at | nil}`) and the latest member event WITH
  its timestamp (new `Room.DB.latest_member_event/2` -> `{:ok, %{membership, origin_server_ts, sender} | nil}`, D3 order; `get_member_membership/2` may
  delegate to it), both fail closed (500) like the existing reads. `pending_invite?/2` keeps its signature for the other callers. Row-only invitations
  (upgrade: no member event in the new room; legacy: an OLDER leave) stay valid. Such a user gets `403 M_FORBIDDEN` "You are not invited to this room"
  and must be re-invited (the re-arm writes a newer invite event). The `room_summary` membership is NOT changed (`fg` (h)).
- **D14 (`full_state=true`, implemented).** `do_sync/1` reads `full_state` (`"true"` only; anything else = false). With `since` and
  `full_state=true`: the timeout is forced to 0 (spec: timeout ignored, returns immediately), the incremental partition runs as usual (new invite /
  leave entries, the anchor), and EVERY joined room (join class) is in `rooms.join` with its full current state (`build_state_events/3`; rooms with new
  events keep today's state-minus-timeline rule) and its timeline since `since` (empty for rooms without new events, `limited: false`; `prev_batch`
  as the join renderer emits it today: the join shape is unchanged, D12). Left / invite / none rooms are never added to `rooms.join` by `full_state`. Without `since`, `full_state` changes nothing.
- **D15 (`use_state_after`: not claimed, pinned).** Nebu advertises at most v1.15 (`/versions`), so the v1.16 `use_state_after` parameter is ignored:
  the response never has `state_after` / `org.matrix.msc4222.state_after`, join / leave rooms keep `state`. A test pins both facts (the `/versions`
  maximum is below v1.16 AND `use_state_after=true` yields no `state_after`), so a later version bump fails the pin and forces the decision
  (implement `state_after` for join and leave rooms, or stay below v1.16).

### Review cycle 1 decisions (code review 0 MAJOR / 8 MINOR, Kassandra CLEAN with 1 MEDIUM + 3 LOW; implemented in the same story)

- **R1 (Kassandra M-1, the leave window and the row).** `membership_candidates/1` returns `left_at`; when the member row has ended the leave window's strict upper
  bound is `min(L.ts, left_at)`, so a removal whose leave event write failed (self-leave, kick, ban: member event writes are fail-open) followed by a later ban
  does not open a window over the time the user was already out. The `[L]`-only alternative was not needed: the window (anchor, min(L, left_at)) plus L is
  exact. A module that does not report `left_at` (nil) falls back to `L.ts`.
- **R2 (Kassandra L-1, the fetch race): CHOSEN: re-read, not truncate.** After the join rooms were fetched (initial sync, incremental, `full_state`, the wake
  rebuild) the partition is read AGAIN; a delivered room that is no longer in the join class makes the delivery be rebuilt from the fresh partition (the room
  becomes a NEW leave of the same sync with its bounded window; the anchor therefore passes the leave only together with its delivery), at most two rebuilds,
  then the sync is `503 M_UNAVAILABLE` with no token persisted (review cycle 2, Kassandra N-1: the cycle 1 text said "dropped, the leave arrives with the next
  sync", which is wrong because the anchor is a GLOBAL maximum: a dropped room's leave is lost once any other delivered event moves the anchor past it). Truncating the join timeline at the own
  leave/ban event was rejected: it needs anchor surgery (an anchor that must not pass a truncated leave, while the anchor is a global maximum, `fc`). Cost: the
  two partition statements once more, only when join rooms were delivered.
- **R3 (MINOR-1 / Kassandra L-2, the anchor read).** `resolve_since_ts/1` runs before the Task: `nil` / `""` = no anchor (0); `{:error, :not_found}` = an initial-sync
  fallback (no leaves); any other failure or exception = `503 M_UNAVAILABLE`, no token. Never 0.
- **R4 (MINOR-2).** `get_member_membership/2` is normalised like `latest_member_events/2` (one reading of "the latest member event").
- **R5 (MINOR-3).** The redundant `Process.whereis(Nebu.Repo)` guard of the ignore-list read is gone (`AccountDataStore.get/2` answers `:error` without a Repo).
- **R6 (MINOR-4 / Kassandra L-3).** One batched statement for all inviters (D2a addendum). No per-response invite cap here: the cap and the per-inviter pending cap
  stay in `ey`.
- **R7 (MINOR-8 / Kassandra I-9).** The sync Task hands back exceptions (with `strip_stacktrace_args/1` applied: no argument lists in logs) AND throws / exits; the
  caller re-raises / re-throws / exits, never a linked EXIT.
- **R8 (MINOR-5).** The CI unit job and production run Elixir 1.20: `mix compile --force --warnings-as-errors` and the no-DB `mix test --warnings-as-errors` were
  run on `elixir:1.20-alpine`.
- **R9 (review cycle 2, Kassandra N-1 LOW integrity; Kassandra I-1).** (a) The post-fetch re-read compares the WHOLE join class of the build with the fresh
  partition (`delivery.join_room_ids -- fresh join class`), not only the delivered rooms: a joined room fetched without news can be demoted during the fetch of
  another room, and a leave that the global-maximum anchor passes undelivered is lost. (b) The re-read runs whenever the delivery delivers a join room OR would move
  the anchor (a delivered timeline event, a leave entry, an event-backed invitation), not only when `rooms != []`. (c) CHOSEN for exhausted rebuilds: `503
  M_UNAVAILABLE`, no token persisted (the simpler safe option; building the dropped rooms' leave entries from the fresh partition would be a third delivery path). The
  retry delivers every leave. (I-1) `membership_candidates/1` also returns `joined_at`; the leave window starts at `max(anchor, P.ts, joined_at)` (a double fail-open can
  leave P older than the membership the row knows). Not done: I-5 (the exception structs of an unknown crash still carry their terms; an exit re-raised in the caller is
  not mapped to a 503, same exposure as before the story).

## Out of scope -> follow-ups (to be added to `follow-ups.md` by this story; the id line says "unused: ... `fc` onward", a grep of the file finds no `fc`-`fg` row: the new ids are `fc`, `fd`, `fe`, `ff`, `fg`)

- **`fc` — the timestamp anchor of the since token loses events (pre-existing, functional, data completeness).** The core token anchors on ONE
  event id; `fetch_events_since/3` reads `origin_server_ts > ts(anchor)` per room, oldest 20 first, and the new anchor is the max over all rooms:
  (a) a room with more than 20 new events loses the rest when another room delivers a newer event (the client gets `limited: true` with a
  `prev_batch` at the START, but the gap is at the END); (b) an event committed after a sync read with a timestamp below the anchor (concurrent
  writers, cross-node clocks) is never delivered incrementally; (c) an event in the same millisecond as the anchor event is skipped;
  (d) createRoom stamps its chain (and its invite events) up to ~70+ ms ahead of the clock (`eu` F-4), and since story sync-membership-partition an
  INVITEE's anchor can be such an invite event: messages of the invitee's other rooms in that window are lost; (e) `get_event_timestamp/1` runs once
  PER ROOM per sync. Fix direction: a stream position (a monotonically increasing sequence on `events`, migration) instead of a timestamp anchor,
  per-room positions for truncated rooms. Same class: invitations / leaves hit by (b) / (c) only appear on the next initial sync.
- **`fd` — the since token is per user, not per device (pre-existing).** `GET /sync` passes `device_id: ""`, so two clients of the same user
  overwrite each other's stored token and every sync of the "other" client falls back to a full initial sync (no long-poll, full payload; with
  story sync-membership-partition such a fallback also carries no `rooms.leave`, so a client can miss a leave and keep a left room listed, without
  receiving its events). The per-device rows (`sync_tokens.device_id`, `get_since_token/2`) exist (Story 9-22) but are unused by the route
  (`conn.assigns[:device_id]` is available for OAuth / bound tokens; raw IdP JWTs have none).
- **`fe` — long-poll wake-ups are node-local (cluster-safety).** `emit_membership_event/3`, `send_event`, kick / ban / unban / decline, the
  invite / join / leave / upgrade wake-ups use `:pg.get_local_members/1`: a sync task on another node is woken only by its timeout (up to 25 s
  late). The cluster-safety skill requires `:pg.get_members/1`; `RoomAccountDataStore.notify_sync/2` already uses it.
- **`ff` — `unsigned.prev_content` / `prev_sender` on member events.** Nebu never sends them; matrix-js-sdk's `getDMInviter()` reads them after
  the invitee's JOIN (the join event's `prev_content.is_direct` and `unsigned.prev_sender`), so after a join Element marks a DM as direct only through
  its `m.direct` account data. If the e2e scenario of story sync-membership-partition shows that Element does not write `m.direct` on accept, this
  item becomes the fix (the predecessor lookup of `replaces_state` already exists).
- **`fg` — sync / membership leftovers.** (a) Filters are ignored (`filter=`, `include_leave`, `lazy_load_members`, timeline `limit`): Element's
  "historical rooms" view (a `LEFT_ROOMS` filter) gets no left rooms; (b) leavers cannot paginate their pre-leave history (`/messages` is 403 for
  non-members, spec allows it by history visibility; the `prev_batch` of a limited leave window is unusable for them) — relates to `es`;
  (c) `POST /forget` accepts a pending invitee (spec: 400 "The user has not left the room"); (d) no `rooms.knock` section and no knock API;
  (e) ignored users' TIMELINE events are still delivered (spec: "the client will no longer receive events sent by that user, with the exception of
  state events"); (f) an Admin removal is written as a SELF-leave (`admin_remove_room_member/3` -> `leave_room/2`), so Element shows "left" instead
  of "was removed" (spec: a kick has the kicker as sender); (g) a left / rejected row whose leave event write failed is never delivered as a leave
  (the client keeps the room listed, receives nothing; rule 6); (h) a taken-back invitation (failed row reject) keeps its row pending and the
  `room_summary` membership still answers `invite`; D13 makes it harmless for join and sync, a transactional reject + event or a repair is the real fix.
- **Notes to existing rows:** `ev` -> CLOSED (one line: what changed: the partition, `invite_state` per D4, D5 newness, the interim guard D11 replaced,
  ignored users' invites suppressed (sync side, D8), L-4 wake deferral (D9), the e2e scenario is a real one); `ez` -> CLOSED (the leave window, the tie
  rule, the declined / left / kicked / banned / Admin-removed / re-invited cases pinned, `forget_room_membership_purge_test` AC4 re-pinned); `eu`
  (the READ side for member events is closed by D3, the write side and the non-member slots stay open); `ey` (`ev` is shipped: invitations are now
  visible, the invite-spam vector is live: the gate is now `ey` alone (+ `ex` for the ban route); the sync-side ignore list exists (D8), the per-user
  tier, the per-inviter pending cap and `M_INVITE_BLOCKED` are still missing); `fa` (b) (the sync side of ignored users is done by D8; invite
  permission / `M_INVITE_BLOCKED` stays); `fb` (row-only invitations get a synthesized stripped member event in `invite_state`; upgrade still writes
  no invite event); `es` (with rooms partitioned, a re-joined user still gets the events of the gap in `rooms.join`: shared visibility only).

## Acceptance Criteria

1. **The membership reads (real DB, `Nebu.Repo`, no fakes).** New `Nebu.Matrix.Room.DB` functions (ADR-018 inline SQL, parameter-bound) for D2 (a),
   (b), (c), (d), each pinned against real rows written through the real writers where possible (`insert_member`, `delete_member`, `insert_event`,
   `InviteDB.insert_invitation/3` / `reject_invitation/2`, `insert_forgotten_room/2`): (a) returns active, left, pending and rejected rows of the user
   only (another user's rows never), with `inviter_id` / `invited_at`; (b) returns at most two rows per room in the tie order: `join` then `ban` in the
   SAME millisecond -> latest `ban`; `invite` and `leave` in the same millisecond -> latest `leave`; `join` (t1) < `leave` (t2) -> `L = leave`,
   `P = join`; content stored as a JSONB object AND as a double-encoded JSONB string (insert one row with `content = to_jsonb('<json text>'::text)`)
   both decode, `is_direct` preserved; an unknown membership string ranks as `leave`; rooms not in the list are never returned; 300 candidate rooms
   are answered by ONE statement (count queries with a telemetry handler on `[:nebu, :repo, :query]` or the repo's equivalent: exactly one query
   for the call); (c) returns the first `m.room.create` and the latest `state_key = ""` event of the six types per room, nothing else; (d) returns
   the strict window (an event exactly at the lower or upper bound is NOT returned), newest 20, `event_id` as the second sort key.
   `@sql_get_member_membership` with the D3 order: a same-millisecond `join` + `ban` answers `ban` (and therefore `POST /join` is 403 for that user:
   one HTTP assertion).
2. **Initial sync (HTTP, real stack).** For user B with: a joined room J, a pending invitation (event-backed, from A) I1, a row-only pending
   invitation I2 (insert the row with `InviteDB.insert_invitation/3` only), a left room L1, a declined invitation D1, a forgotten left room F1, a
   pending invitation I3 from a user listed in B's `m.ignored_user_list`, and a room K with an ACTIVE row whose latest member event is `ban` (write the
   ban event with `Room.DB.insert_event/1` without removing the member): `rooms.join` = exactly `{J}` (K is NOT in it), `rooms.invite` = exactly
   `{I1, I2}`, `rooms.leave = {}`; no room id in two sections; `next_batch` usable for an incremental sync that waits (`timeout=200` takes >= 150 ms
   when nothing happens).
3. **`invite_state` content (HTTP + unit).** For I1 (createRoom with `name`, `topic`, `preset: private_chat`, `room_alias_name`, an avatar via
   `initial_state`, `is_direct: true`, `invite: [B]`): the events are exactly, in order, `m.room.create` (content = the stored create content),
   `m.room.name`, `m.room.avatar`, `m.room.topic`, `m.room.canonical_alias`, `m.room.join_rules` (`{"join_rule": "invite"}`), the inviter A's
   `m.room.member` (`{"membership": "join"}`, sender A), and B's own `m.room.member` with `sender` A, `state_key` B, content exactly
   `{"membership": "invite", "is_direct": true}`; every event has EXACTLY the keys `type`, `state_key`, `sender`, `content`; no `m.room.power_levels`,
   `m.room.history_visibility`, `m.room.guest_access`, no message, no other member. `m.room.encryption` appears when the room has one (unit). For I2
   (row-only): B's own member event is synthesized with `sender` = the row's `inviter_id` and content exactly `{"membership": "invite"}`. A legacy
   room without a create event (unit fake) gets the synthesized `m.room.create` (D4). A room whose name was changed after the invitation shows the
   CURRENT name.
4. **Incremental invite delivery (unit + HTTP).** B syncs (token T0); A creates an Element DM with B: B's next incremental sync (with T0) has
   `rooms.invite.<dm>` (AC3 content) and NOT `rooms.join.<dm>`, and returns at once (no wait) when called after the invite; the sync after it
   (with the returned token, `timeout=200`) has no `rooms.invite.<dm>` and WAITS (>= 150 ms; no hot loop); a long-polling sync of B (`timeout=5000`)
   started BEFORE `POST /rooms/{id}/invite` returns early (< 2 500 ms) WITH `rooms.invite.<id>` in that response; an invitation older than the token
   is not re-delivered; a row-only invitation newer than the token is delivered but does not end a wait by itself (unit: no `{:new_invite}`, a
   200 ms wait takes >= 150 ms and the response carries the invite); messages A posts in the DM while B is only invited are NOT delivered in any
   section and do NOT wake B's long-poll (the D11 L-3 pin, kept).
5. **Leave delivery, the `ez` fix (HTTP, real stack, B and A members of a private room R unless stated).** For each way out:
   (a) B leaves (`POST /rooms/{id}/leave`); (b) B is kicked (internal `kick_user/2` with A as sender, as the `moderate/4` helper of
   `create_room_presets_http_test.exs` l.143-158 does); (c) B is banned (internal `ban_user/2`); (d) B is removed by an Admin (`admin_remove_room_member/3`);
   (e) B declines a pending invitation; (f) B, a pending invitee, is banned:
   B's next incremental sync has `rooms.leave.<R>` and NOT `rooms.join.<R>` / `rooms.invite.<R>`; the last timeline event is B's `m.room.member`
   with `membership` `leave` / `ban` (sender B for (a) (d) (e), A for (b) (c) (f)); for (a)-(d) the timeline contains A's messages sent after T0 and
   before the leave and NO event after it; for (e) and (f) the timeline is exactly `[L]` (no message of the room, although A posted some before and
   after the invite); `state.events == []`, `account_data.events == []`. Then A posts 3 messages and changes the room name: B's next two incremental
   syncs (each with the previously returned token) contain R in NO section, and the content of A's messages appears nowhere in B's response bodies
   (assert on the raw body); a long-polling sync of B is NOT woken by A's messages (`timeout=500` takes >= 450 ms). The same for a room B left
   BEFORE T0 (nothing at all). A message of A in the SAME millisecond as B's kick (unit with a fixed timestamp) is not in the window.
6. **Transitions within one window (unit table + HTTP for the starred rows).** Every row of the "Edge cases" table above is a test; HTTP for:
   invited -> joined*; invited -> declined*; joined -> left*; joined (after T0) -> left; left -> re-invited* (the re-invited former member: `rooms.invite`,
   not `rooms.join`, not `rooms.leave`: replaces the `ez` pin); left -> forgot -> re-invited* (D7: the forgotten-rooms row is gone, `rooms.invite`
   has the room); ban override*.
7. **Long-poll wake rules (unit).** With a join room J, an invite room I and a left room L: a `{:new_event}` in L does not wake (L is not
   subscribed: `:pg.get_local_members("room:" <> L)` does not contain the task, and an injected message is ignored); a non-member `{:new_event}` in I
   does not wake; an `m.room.member` `{:new_event}` with `state_key` B in I wakes, and the rebuilt response classifies I by the NEW state (a decline
   written meanwhile: `rooms.leave.<I>` = `[L]`); a `{:new_event}` in J wakes and J's events are delivered; `{:new_invite, _}` wakes and the rebuilt
   response has the invite; `{:new_join, X}` wakes and X is in `rooms.join`; `{:new_leave, J}` wakes and J is in `rooms.leave`; after every wake the
   token is persisted exactly once (`SyncDeltaFakePgStore.recorded_calls/0`).
8. **Anchor and fail-closed (unit).** The persisted `last_event_id` is the newest of: join timeline events, leave timeline events (incl. `L`),
   event-backed invite events; a row-only invite never becomes the anchor; with nothing delivered the previous anchor is kept. A failing
   candidates / membership / stripped-state / leave-window read raises `unavailable` (HTTP: `503 M_UNAVAILABLE`), and NO token is persisted; a fake
   without the new reads behaves the same (no silent "no memberships").
9. **Ban override and account-data-only rooms (unit + HTTP).** Room K (active row, latest member event `ban`): never in `rooms.join` (initial
   and incremental); `rooms.leave.<K>` once when the ban is newer than the token; a room account data write for K by B (written directly through
   `RoomAccountDataStore.put/4` or its SQL, since the route refuses non-members) does NOT bring K back into `rooms.join` as an empty entry; for a
   normal joined room an account-data-only change still produces the empty `rooms.join` entry (regression).
10. **Ignored users (HTTP).** A invites B to R; B has `m.ignored_user_list` `{"ignored_users": {A: {}}}`: R is in no section of B's initial or
    incremental sync; C (not ignored) invites B to R2 at the same time: R2 is in `rooms.invite`; with a malformed list (`{"ignored_users": []}`)
    nothing is suppressed; B can still `POST /join` R (the ignore list hides the invitation, it does not revoke it: documented).
11. **createRoom wake deferral (unit).** createRoom with `invite: [B, C]`: B's and C's `user:` groups receive `{:new_invite, room}` only after
    the createRoom call returned success (a test process subscribed to both groups receives nothing while a fake makes the SECOND invite event
    fail, and receives two messages, after the response, on success); `POST /rooms/{id}/invite` still wakes at once.
12. **HTTP shape (HTTP).** `rooms.invite.<id>` is exactly `{"invite_state": {"events": [...]}}`; `rooms.leave.<id>` has exactly the keys `state`,
    `timeline`, `account_data`, its timeline events have the join timeline event shape (`event_id`, `type`, `sender`, `content`,
    `origin_server_ts`, `unsigned.age`, `state_key` for state events); a non-limited leave timeline has NO `prev_batch` key (never `""`), a limited one
    a non-empty `prev_batch`; `rooms.join` is unchanged (the existing compat / sync suites stay green);
    `next_batch` keeps the `<core>.<pos>` shape.
13. **The Element DM flow over HTTP (HTTP).** A sends Element's exact DM body for B (the body of `create_room_invites_http_test.exs`
    `element_dm/2`); B's incremental sync: `rooms.invite.<dm>` with B's own invite event `is_direct: true` and sender A; B `POST /join/<dm>`; B's
    next sync: `rooms.join.<dm>` with B's join event, no `rooms.invite.<dm>`; A sends "hello", B receives it in `rooms.join`; B leaves; B's next sync:
    `rooms.leave.<dm>` ending with B's leave; A sends "after"; B receives nothing of it.
14. **Regression (existing suites, unchanged assertions unless listed in AC16).** `sync_test.exs` (all describes except the D11 one),
    `server_dedup_test.exs`, `matrix_client_compat_test.exs`, `forget_room_membership_purge_test.exs` AC1-AC3, AC5-AC7,
    `create_room_invites_http_test.exs` / `_test.exs` (except AC12), `invite_user_test.exs`, `join_room_test.exs`, `leave_room_test.exs`,
    `room_summary_integration_test.exs`, `room_tags_test.exs` (room account data), `backfill_power_levels_events_migration_test.exs`,
    `matrix_mutual_rooms_test.exs`, `matrix_room_view_routes_test.exs`, `upgrade_room_test.exs`.
15. **Docs (docs test `server/test/nebu/matrix/sync_membership_partition_docs_test.exs`).**
    (a) `docs/matrix-api-scope.md` `GET /_matrix/client/v3/sync` row: rewritten: `rooms.join` = joined rooms only (row-based, latest-`ban`
    override), `rooms.invite` with stripped `invite_state` (the D4 list, `m.room.create` required, the invitee's own invite event with `is_direct`,
    row-only invitations synthesized, ignored users' invitations suppressed), `rooms.leave` incremental only, timeline bounded at the leave / kick /
    ban event, `state` empty (Nebu choice), never repeated; the tie rule; initial sync = join + invite; filters / `include_leave` ignored (KNOWN DEVIATION, `fg`); the state gap of a `limited` leave window; `full_state=true`
    honoured (D14); `use_state_after` not supported, `/versions` below v1.16 (D15); a failed read is `503 M_UNAVAILABLE` (not a spec errcode, kept
    for consistency); a taken-back invitation is a leave and not joinable (D13); the words "interim guard" and "still always empty" are gone. The `POST .../forget` row: "an invitation clears a forget (spec)" and "a pending invitee can forget (200; spec: 400): known deviation, `fg` (c)".
    The `POST /join` row: a taken-back invitation does not grant the join (D13). The `POST .../leave` row: "the leaver
    gets `rooms.leave` once". (b) `docs/architecture/07-deployment.md`: the **RELEASE GATE** paragraph is rewritten: `ev` and `ez` are CLOSED by
    story sync-membership-partition (invitees see invitations and DMs in Element; left / kicked / banned / removed / declined users stop receiving
    events at the leave); the branch must still NOT be released to Element-based deployments before `ey` (per-user rate limits for `createRoom` /
    `POST /invite` / `POST /join`, a per-inviter cap of pending invitations, invite blocking `M_INVITE_BLOCKED`: invitations are now VISIBLE, the
    invite-spam vector is live) is done; `ex` remains the gate for building a ban route; the release-note list is updated: point (3) ("invitations
    are NOT shown in Element") is replaced by "invitations are shown; invitations that exist before the update appear after the client's next
    initial sync (Element: Clear cache and reload, or a new login)", plus "a user who left / was removed stops receiving the room's events at once
    (a SECURITY fix, `ez`); clients do not get leaves that happened while another session of the same user was syncing (`fd`)". The
    create-room-invites-direct paragraph ("The invitee does not see the invitation in Element yet ... interim guard") is updated to point to this
    story. (c) `docs/architecture/06-runtime.md` Scenario 3b: the implementation note says the Elixir partition replaces the Go
    `buildLeaveRooms` design (anchor-based newness, not `sync_tokens.updated_at`), with a pointer to this story. (d) `follow-ups.md`: `ev` and `ez`
    CLOSED (status column `closed`, a "CLOSED by story sync-membership-partition (2026-10-17): ..." prefix like `ea`), the notes to `eu`, `ey`, `fa`,
    `fb`, `es`, the new rows `fc`-`fg` attributed to this story, the id line: "`fc`-`fg`: sync-membership-partition" and "unused: ... `fh` onward".
    (e) The `Nebu.Matrix.Http` moduledoc "MINOR-2" paragraph is gone (code-level docs pinned by the docs test with `File.read!`).
16. **Tests that pin the OLD behaviour are changed deliberately (listed in the Change Log with old -> new assertion).**
    - `server/test/nebu/matrix/forget_room_membership_purge_test.exs` AC4: the control asserts `rooms.leave.<room>` (NOT `rooms.join`) with the
      leave event as the last timeline event; the final assertion uses the CONTROL's `next_batch` (a real incremental sync, not the stale-token
      initial fallback) and additionally a fresh initial sync; the comment l.237-244 is rewritten.
    - `server/test/nebu/matrix/event_dispatcher/sync_test.exs` describe "interim guard for pending-invite-only rooms (D11)" (l.2388-2548):
      "pending-only not delivered" -> delivered in `invite_rooms`, not in `rooms`; "pending + left still delivered (ez pin)" -> `invite_rooms` only;
      "DECLINED still delivered (ez pin)" -> `leave_rooms` with `[L]` only when the decline is new, nothing otherwise; "LEFT still delivered (ez pin)"
      -> `leave_rooms` once / nothing; L-3 "events in a pending-only room do not wake" -> kept; "`{:new_invite}` wakes with NO rooms" -> wakes WITH the
      invite in `invite_rooms`, the next sync waits; the describe is renamed. The `SyncGuardFakeDB` / `SyncGuardFakeInviteDB` and the other DB fakes of
      the file (`SyncTestFakeDB`, `SyncDeltaFakeDB`, `SyncDeltaThreadFakeDB`) implement the new reads (derived from their existing ETS keys).
    - `server/test/nebu/matrix/event_dispatcher/server_dedup_test.exs`: `DedupTestFakeDB` implements the new reads (DATA adaptation, no assertion
      change).
    - `server/test/nebu/matrix/create_room_invites_http_test.exs` describe "AC12 - the invitee's incremental /sync (interim guard D11)": test 1
      ("no rooms.join and no rooms.invite") -> `rooms.invite` present, `rooms.join` absent; test 2 ("INITIAL sync does not list the pending room") ->
      the initial sync lists it in `rooms.invite`; test 3 ("pinned (follow-up ez): re-invited former member still in rooms.join") -> `rooms.invite`
      only; module doc l.17 updated.
    - `server/test/nebu/matrix/create_room_presets_http_test.exs` l.589-595: the DEV NOTE ("does NOT serve a rooms.invite section") is rewritten;
      the test may additionally assert the re-armed invitation in `rooms.invite` (optional).
    - `server/test/nebu/matrix/create_room_invites_docs_test.exs`: the `ez` row test (`refute ez =~ "CLOSED"`), the `ev` row note test, the id-line
      test ("continues at fc"), the scope-doc sync-row test ("interim guard", "rooms.invite / rooms.leave still empty") and the 07-deployment RELEASE
      GATE test ("the gate is ev + ez", "the INVITEE does not see the invitation", "/join <room id>") move to the new texts.
    - `server/test/nebu/matrix/create_room_presets_docs_test.exs`: the `ev` row test (words "must not be released" etc. now in a CLOSED row: keep
      the words in the closure line or move the assertion), the id-line test l.115-121 ("`fc` onward" -> "`fh` onward"), the 07-deployment test
      l.229-238 ("must not be released", "rooms.invite", "/join <room id>": the gate paragraph still says "must not be released" (now because of `ey`);
      the `/join <room id>` wording is replaced: move the assertion).
17. **No regression of the invite / join / leave writers.** Apart from D7 (unforget on invite) and D9 (wake deferral in createRoom), the
    writers are unchanged (the existing `invite_user_test.exs`, `create_room_invites_test.exs`, `leave_room_test.exs`, `join_room_test.exs` pass;
    the new unforget is best effort: a failing `remove_forgotten_room/2` does not fail the invite).
18. **e2e acceptance (see "E2E verification").** `create-dm.feature` scenario 3 runs in the default `element-web` run (tags `@dm-invitee-ui
    @regression @ui`, `@pending-feature @needs-ev` removed) and passes; `room/join.feature` @ac8-join-room waits for the REAL invite tile in the
    sidebar (no room-id URL navigation) and passes; the new `@ac8-decline-invite` scenario passes; the whole `element-web` project is green except the
    rows of `e2e/KNOWN-FAILURES.md`.
19. **Taken-back invitation (Oracle correction 1; real DB + unit + HTTP).** A invites B (row pending + invite event); then B's `m.room.member`
    `leave` with sender A (second case: sender B, a decline) is written through `Room.DB.insert_event/1` WITHOUT rejecting the row (the failed-reject
    state): (a) B's next incremental sync has `rooms.leave.<R>` with timeline exactly `[L]` (sender A in the first case), not `rooms.invite.<R>`; the
    sync after it has R in no section; B's initial sync does not list R; (b) `POST /join` of B is `403 M_FORBIDDEN` "You are not invited to this
    room"; (c) a leave in the SAME millisecond as `invited_at` counts as taken back (unit, fixed timestamps); (d) a leave OLDER than `invited_at` (the
    re-invited former member, a legacy row-only re-invite) is still a valid invitation (sync: `rooms.invite`; join: 200); (e) after a fresh `POST
    /invite` B sees `rooms.invite` again and can join; (f) a failing read of the pending row or the latest member event in the join decision is `500`
    (fail closed); (g) invited -> banned -> unbanned (internal `ban_user/2`, `unban_user/2`): one leave entry per new `L` (`[ban]`, then `[unban leave]`),
    never `rooms.join` / `rooms.invite`.
20. **`full_state=true` with `since` (HTTP).** B has a joined room J without new events, a joined room J2 with a new message, a new invitation I
    and a new leave of L2 since T0, and L1 left BEFORE T0: `GET /sync?since=T0&full_state=true&timeout=5000` returns in < 1 000 ms; `rooms.join` has J
    (full current state incl. `m.room.create`, `m.room.power_levels`, B's member event; empty timeline, `limited: false`) and J2 (full
    state, the new message); `rooms.invite.<I>` and `rooms.leave.<L2>` are present; L1 and L2 are NOT in `rooms.join` and none of their state appears;
    `full_state=false` / absent / `"1"` behave like today (long-poll); `full_state=true` without `since` equals an initial sync.
21. **Unsupported parameters pinned (HTTP).** (a) `/versions` lists no version >= v1.16 in both OAuth states (`HttpPublic.versions_body(true)` and
    `(false)`) AND `GET /sync?use_state_after=true` (initial and incremental) has no `state_after` / `org.matrix.msc4222.state_after` key in any join or
    leave room, `state` present (D15); (b) an initial sync with `filter={"room":{"include_leave":true}}` (URL-encoded) for a user with a left room has
    `rooms.leave = {}` (known deviation, `fg` (a)); (c) `POST /rooms/{id}/forget` by a PENDING invitee answers `200 {}` (known deviation, `fg` (c);
    spec 400) and the invitation is then hidden (rule 1).
22. **Remaining tests of the Oracle list.** (a) EVERY `invite_state` event (event-backed, row-only, legacy-synthesized create) has exactly the keys
    `type`, `state_key`, `sender`, `content`: no `room_id`, `event_id`, `unsigned`, `origin_server_ts`, `signatures` (HTTP for event-backed and row-only,
    unit for the legacy create); (b) an invitation to a private Space (createRoom `creation_content: {"type": "m.space"}`): the stripped `m.room.create`
    content carries `"type": "m.space"` unchanged (HTTP); (c) ignore list changed while an invitation is pending: B received the invite, then ignores A:
    the next incremental sync does not re-send it (and sends no leave for it); after un-ignore the next incremental sync does NOT re-deliver it (spec:
    missed events are not re-sent), a fresh initial sync shows it (HTTP); (d) a forced read failure answers `503` with a JSON body that has `errcode`
    (`M_UNAVAILABLE`) AND `error`, persists NO token, and a retry with the SAME `since` succeeds incrementally (`fallback_to_initial: false`) (unit; plus
    one router-level test with an injected failing fake); (e) an invalid or foreign `since` (a random string; another user's token) falls back to an
    initial sync: 200, `rooms.leave = {}`, joined rooms and pending invitations present, no error (HTTP); (f) A renames the room 1 ms after B's kick
    (explicit timestamps, unit; over HTTP right after the kick): the leave entry contains no event dated after `L` (no `m.room.name` change,
    `state.events == []`), and B's later syncs never contain the new name.

23. **Review cycle 1 (real DB + unit + HTTP).** (a) `membership_candidates/1` returns `left_at` (nil while active, the soft-delete clock once left; nil for invitation
    rows); a left row without a leave event, messages after it and a later ban: `rooms.leave` has the messages before `left_at`, the ban last and NO message after
    `left_at` (HTTP, raw body, and unit with the recorded window bound); (b) a kick (and, as a second case, repeated demotions) between the partition read and the fetch
    of the join rooms: the room is a leave of the same sync, no message after the removal is in any section (initial sync: in none); after the bounded rebuilds the
    the sync is 503 with no token and the retry delivers every leave (unit, a hook after the candidates read; cycle 2: the re-read compares the WHOLE join class, also when only an invitation or a leave moves the anchor, unit hooks after the first fetch); (c) an anchor event that is gone is an initial-sync
    fallback without leaves (unit + HTTP), any other anchor-read failure is `503`, no token, no pg group (unit); (d) `get_member_membership/2` answers `"leave"` for an
    unknown / non-string / missing / unparseable latest event and agrees with `latest_member_event/2`, `nil` only without a member event (real DB); (e)
    `inviter_member_events/1`: ONE statement for 300 pairs, normalised, tie order, no Seq Scan (real DB); (f) an exception, a throw and an exit inside the sync Task are
    re-raised / re-thrown / exited in the caller, with a stacktrace of arities only (unit); (g) docs: the `ez` row, the scope-doc sync row and the 07-deployment gate name
    the residuals, notes on `fc`, `fg`, `ey` (follow-ups), the proto comment, "PostgreSQL 16+" in the Helm values.

## Acceptance Tests

- `server/test/nebu/matrix/room/membership_partition_db_test.exs` (new, `@moduletag :integration`, real `Nebu.Repo`, rows written through the real
  writers, random ids): AC1 and the D13 reads (`InviteDB.pending_invitation/2`, `Room.DB.latest_member_event/2`, tie + both JSONB forms).
- `server/test/nebu/matrix/event_dispatcher/join_room_test.exs` (extended, unit fakes): AC19 (b) (c) (d) (f) for the join decision.
- `server/test/nebu/matrix/event_dispatcher/sync_membership_partition_test.exs` (new, unit, `async: false`, the seams of `sync_test.exs`:
  `:pg_store_module`, `:messages_db_module`, `:rooms_db_module`, `:invite_db_module`, room registry fakes; reset in `on_exit`): the partition table
  (AC6 all rows), AC3 (legacy create, encryption), AC4 (row-only piggyback, L-3), AC5 (same-millisecond exclusion), AC7, AC8, AC9 (unit part), AC11,
  AC19 (c) (f), AC22 (a) legacy create, (d), (f) with fixed timestamps.
- `server/test/nebu/matrix/sync_membership_partition_http_test.exs` (new, `@moduletag :integration`, real stack via `Nebu.Web.Router` and
  `Plug.Test`, the helpers of `create_room_invites_http_test.exs` (`make_room/2`, `invite!/3`, `join!/2`, `leave/2`, `tick/0`, `element_dm/2`,
  `invitation_state/2`), `moderate/4` of `create_room_presets_http_test.exs`, `Nebu.Test.ServerName.pin!/1`
  (`create_room_test_support.exs`), users provisioned, random localparts): AC1 (the `POST /join` 403 for the tie), AC2, AC3, AC4, AC5, AC6 (starred rows),
  AC9, AC10, AC12, AC13, AC19 (a) (b) (d) (e) (g), AC20, AC21, AC22 (a) (b) (c) (e) (f), the router-level part of AC22 (d).
- `server/test/nebu/matrix/sync_membership_partition_docs_test.exs` (new): AC15.
- Changed suites: AC16.
- e2e: `e2e/features/element/dm/create-dm.feature` (scenario 3 untagged), `e2e/features/element/room/join.feature` (real tile + decline
  scenario), step definitions in `e2e/step-definitions/element/room.steps.ts` / `dm.steps.ts`.

The names and return shapes of the new reads are D2a (the tests pin exactly those).

**SQL-dependent behaviour MUST be pinned on the real DB** (the tie order, the JSONB string form, the window bounds, the candidate union, the
one-statement property): a fake that returns pre-sorted rows proves nothing about the SQL (a fake hid a real defect in an earlier story). The unit
suite covers the orchestration (classification, wake-ups, anchor, fail-closed) on fakes; every SQL rule has its AC1 twin.

## E2E verification (the run the siblings did)

Scenarios (element-web project, users alex / marie / kai of `e2e/fixtures/users.ts`, API helpers of `e2e/fixtures/dex-auth.ts`):

1. `create-dm.feature` scenario 3 "marie sees the DM invitation in Element and accepts it": the tags `@pending-feature @needs-ev` become
   `@dm-invitee-ui @regression @ui`; the comment lines that call it a RED scaffold are rewritten. Steps exist (`dm.steps.ts` l.436-493); if a
   selector proves wrong against Element 1.12.15 (the K9 experience), fix the SELECTOR (record it), never the assertion. The final step asserts
   that the DM is joined and that marie's `m.direct` lists it under alex: if this fails ONLY because Element does not write `m.direct` on accept,
   record it, keep the assertion, tag the scenario `@known-failure` with a K-row in `e2e/KNOWN-FAILURES.md` pointing to `ff` (do not weaken it),
   and say so in the Completion Notes; the invitation tile and the join are the acceptance of `ev` and must pass.
2. `room/join.feature` @ac8-join-room: the step "the invite for {string} appears in {word}'s sidebar" waits for the room-list tile
   (`[aria-label^="Open room"][aria-label*="invitation"]` filtered by the room name, timeout 60 s) instead of navigating to the room-id URL; the
   comment that explains the navigation workaround is removed; the RED-phase comment block of the feature is updated.
3. New `@ac8-decline-invite` in `room/join.feature`: kai invites alex; alex sees the tile, opens it, clicks "Decline" (Element 1.12.15: the
   decline / "Reject" button of the invite preview; confirm the label in the bundle or by a first run, record it); the tile disappears; server-side
   (alex's API session): alex's invitation is rejected (alex is not in `/joined_rooms`, and an incremental `/sync` from before the decline has
   `rooms.leave.<room>` whose last event is alex's leave), and after kai posts a message, alex's next incremental `/sync` has the room in no section.

**The run (pass criterion).** Against an isolated throwaway stack (plain http, the commands and env of `scripts/e2e-ci.sh element`: compose with
`--profile e2e`, Playwright container on the host network, `NEBU_ELEMENT_URL=http://localhost:7070` / `NEBU_MATRIX_BASE` as in the script, a
dedicated compose project such as `nebu-oauth`, NEVER the shared dev compose project; `make redeploy`-equivalent image build of THIS commit): the full
`element-web` project with the default tag expression (the scenarios of the previous run + scenario 3 + the decline scenario; `room/leave.feature`
@ac9-leave-room and `messages/receive.feature` are the leave / message regression checks). All green except the rows of `e2e/KNOWN-FAILURES.md`. Log:
`_bmad-output/nebu/epics/oauth-broker/step-results/sync-membership-partition/e2e-run.log`, linked in the Completion Notes. A red
@ac9-leave-room or `receive` is a finding (a left room that Element still lists, or a missing message), never hidden by changing the scenario.

## Tasks

- [x] `Room.DB`: the four reads of D2 (candidates, latest two member events with the tie order, stripped state batch, leave window), the D3 order
      in `@sql_get_member_membership`; doc strings; `get_recently_left_rooms_for_user/1` removed or documented as unused by the sync (D1).
- [x] `Core.*` structs (D11) + `proto/core.proto` comment parity.
- [x] Core: the partition builder (D1, rule table), the invite-state builder (D4, D8), the leave-window builder (D6), newness + anchor (D5),
      `get_initial_sync/2` and `do_incremental_sync/4` on top of it, the wake rules + rebuild, fail closed (D10); delete `pending_only_room_ids` /
      `pending_only_event?/2` (D11 guard) and the stale "Go buildInviteRooms / buildLeaveRooms" comments.
- [x] Join decision D13 (`authorize_join!/2` + the two reads); `do_sync/1`: `full_state` (D14); the D15 pin.
- [x] `write_invitation!/4`: unforget after a written invite event (D7); createRoom step 8: deferred wake-ups (D9) with `:pg.get_members/1`.
- [x] HTTP: `Nebu.Matrix.Http.sync_response/5` + renderers, moduledoc; `do_sync/1` passes invite / leave rooms and filters `extra_rooms` by
      `join_room_ids` (D11).
- [x] Tests: the four new suites (Acceptance Tests), the deliberate re-pins of AC16 (Change Log entries), fakes.
- [x] Docs AC15 (scope doc, 07-deployment gate + release notes, 06-runtime 3b, follow-ups closures / notes / `fc`-`fg` / id line).
- [ ] e2e scenarios + the run with log (E2E verification). The scenarios and steps are written (ATDD step); the dev step does not run the e2e suites, the orchestrator runs them (log: `step-results/sync-membership-partition/e2e-run.log`).
- [x] `EXPLAIN (ANALYZE, BUFFERS)` of D2 (a), (b), (d) on a seeded DB in the Completion Notes.

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/` only inside the `nebu-pipeline` run. **No migration.** ADR-018 (inline SQL in
  `Nebu.Matrix.Room.DB` / `InviteDB`, no repository layer), ADR-019 / ADR-021 (plain modules, in-process), ADR-020 (everything is inside
  `Nebu.Matrix`; `AccountDataStore` is in the same namespace), ADR-011 (`m.room.encryption` is passed through as stripped state only if a room has
  one; nothing is decrypted or interpreted).
- **Files and current state (HEAD `1dd91309`, read before editing):**
  - `server/lib/nebu/matrix/http.ex`: `sync_response/3` l.137-153 (moduledoc "MINOR-2" l.119-136), `build_joined_rooms/2` l.155-274 (reuse its
    timeline event rendering for leave entries: extract a private helper rather than duplicating), `decode_content/1` l.278-285, `put_state_key/2`
    l.347-360.
  - `server/lib/nebu/web/router/protected.ex`: `do_sync/1` l.85-179 (`device_id: ""` l.119 stays: `fd`), `extra_rooms` l.152-163,
    `newly_joined_room_ids/2` l.206-213, `put_global_account_data/3` l.222-234.
  - `server/lib/nebu/matrix/event_dispatcher/server.ex`: `forgotten_room_ids/1` l.40, `unforget_room/2` l.61, `join_room/2` l.1652-1721 (the
    `{:new_join}` sender l.1679), `pending_invite?/2` l.1873 (the join decision's pending read: unchanged), `admin_remove_room_member/3` l.2211,
    `leave_room/2` l.2244 (`{:new_leave}` l.2304), `leave_without_room_process/3` l.2357, `invite_user/2` l.2516, `do_invite!/5` l.2572,
    `write_invitation!/4` l.2656 (wake l.2669-2670), `handle_failed_invite_event!/4` l.2692, `emit_invites/5` l.2740 (createRoom step 8),
    `get_initial_sync/2` l.4127-4253, `get_sync_delta/2` l.4270-4348 (token lookup / fallback: unchanged), `do_incremental_sync/4` l.4353-4525,
    `pending_only_event?/2` l.4528, `fetch_delta_rooms/3` l.4534-4603 (unchanged), `dedup_member_state_events/2` l.4614, `generate_delta_token/3`
    l.4641, `build_state_events/3` l.4679 (create fallback l.4680-4709: reuse for D4), `attach_heroes/3` l.4888, `kick_user/2` l.5351, `ban_user/2`
    l.5440, `unban_user/2` l.5561, `forget_room/2` l.5636, `emit_decline_event/2` l.6302, `upgrade_room` invites l.6452-6465.
  - `server/lib/nebu/matrix/room/server.ex`: `handle_call({:join, ...})` l.318, `{:leave, ...}` l.363, `{:remove_member, ...}` l.387,
    `check_not_banned/2` l.596 (reads `get_member_membership/2`: gets the D3 order for free), `emit_membership_event/3` l.635.
  - `server/lib/nebu/matrix/room/db.ex`: `@sql_insert_member` l.53, `get_rooms_for_user/1` l.296, `get_recently_left_rooms_for_user/1` l.315,
    forgotten rooms l.350-407, `fetch_events_since/3` l.477-523, `get_event_timestamp/1` l.569, `get_room_create_event/1` l.843 (both JSONB forms),
    `@sql_get_member_membership` l.1527-1549.
  - `server/lib/nebu/matrix/room/invite_db.ex` (all reads), `server/lib/nebu/matrix/room/db_behaviour.ex` (callbacks; adding callbacks forces all
    fakes to implement them: prefer NOT adding the new reads to the behaviour, call them through `rooms_db_module()` with a
    `Code.ensure_loaded?/1` + `function_exported?/3` check whose negative branch raises `unavailable` (D10), and implement them in the sync fakes).
  - `server/lib/nebu/matrix/account_data_store.ex` `get/2` l.87; `server/lib/nebu/matrix/room_account_data_store.ex` `list_for_sync/3` l.242;
    `server/lib/nebu/matrix/session/pg_store/postgres.ex` (tokens); `server/lib/pb/core.pb.ex` l.277-330.
- **Must be preserved:** the join delivery byte-for-byte (state, timeline, heroes, `replaces_state`, thread aggregations, `limited` / `prev_batch`),
  room account data per device position and the "newly joined room gets all account data" rule, global account data consume-once, device lists /
  E2E counts, the fallback-to-initial semantics of `get_sync_delta/2`, the 25 s cap, the per-IP `/sync` rate limit, the token format, the
  `{:new_join}` path (a joined public room arrives in the same long-poll), every writer's behaviour except D7 / D9, value-free logs (room id and error
  class only; NEVER message content, NEVER the ignore list content).
- **Security (Kassandra will check):** (1) no path delivers an event with `ts >= L.ts` (other than `L`) for a leave entry, nor any event of a room in
  class none / invite (assert on raw bodies); (2) invite entries carry ONLY the D4 stripped events (no history, no power levels, no member list, no
  `event_id` / signatures); (3) the classification only removes delivery relative to the active row (rule 2 demotes, nothing promotes); (4) the tie
  rule is most restrictive everywhere it is used, including the join decision (D3); (5) fail closed on every read (D10), no token persisted on
  failure; (6) long-poll: no hot loop (an invite / leave is delivered once and moves the anchor; row-only invites never end a wait); no wake-up from
  rooms the user is not in (except his own member events); (7) the ignore list suppresses, it never grants; it is read only for the syncing user;
  (8) account-data-only rooms cannot resurrect a non-joined room in `rooms.join`; (9) the createRoom wake deferral (D9) and its documented residual;
  (10) a room id is in at most one section; (11) a taken-back invitation is neither shown nor joinable (D13); (12) `full_state` never adds a
  non-joined room or its state. **Residuals to name in the review:** `ey` (now LIVE: invitations are visible, 50 per createRoom, no rate
  limit, no per-inviter cap, no `M_INVITE_BLOCKED`), `ex` (ban route), `fc` (anchor loses events; an invite event stamped ahead moves the invitee's
  anchor), `fd` (multi-device fallbacks miss leaves), `fe` (node-local wake-ups), `es` (history visibility not enforced for joiners / re-joiners),
  `fg` (e) (ignored users' timeline events), D8's fail-open on an unreadable ignore list.
- **Unit seams:** `:pg_store_module`, `:messages_db_module`, `:rooms_db_module`, `:invite_db_module`, room registry / supervisor seams as in
  `sync_test.exs`; the ignore list through `AccountDataStore` (real store needs a Repo: in unit tests either inject a seam (an `:account_data_module`
  env with a default of `Nebu.Matrix.AccountDataStore`, like the other seams) or cover D8 at HTTP level only and keep the unit tests on "no ignore
  list": dev's choice, record it).
- **Concurrency notes:** the partition reads are separate statements (no transaction): a membership change between (a) and (b) is resolved by
  the rule order (a ban seen in (b) wins; a join seen in (a) but not yet in (b) is a join by the row) and repaired by the next build (the change's
  own wake-up). Never hold a DB connection across the long-poll wait.
- **Element facts:** see the premise table (chunk names for re-checks: `7878.js` `accumulateInviteState`, `getDMInviter`, `mapSyncResponseToRoomArray`;
  `init.js` `getUserIdForRoomId`).
- **Previous-story intelligence (create-room-invites-direct, commit `1dd91309`):** the test review found 3 MAJORs about tests that would pass
  vacuously (assert the negative AND a positive control in the same test, as AC5 does with the timeline before the leave); the code review asked for
  conditional compensation and value-free logs; Kassandra's L-3 (no wake-up per message of a room the user is not in) and L-4 (wake deferral) are
  carried into AC4 / AC7 / D9; the HTTP suites must pin `:server_name` (`Nebu.Test.ServerName.pin!/1`) because 28 older suites delete it on exit;
  `tick/0` between membership changes in HTTP tests (millisecond timestamps), except where a test deliberately builds a same-millisecond tie (then
  write the events with explicit timestamps through `Room.DB.insert_event/1`).
- **References:** follow-ups `ev`, `ez`, `eu`, `ex`, `ey`, `fa`, `fb`, `es` (`docs/stories/oauth-broker/follow-ups.md` l.505-512); stories
  `create-room-invites-direct.md` (premise tables, D1, D11, D12, review cycle 1), `create-room-presets-power-levels-topic.md` (join / ban
  enforcement); `docs/architecture/07-deployment.md` l.272 (RELEASE GATE) and l.363 (create-room-invites-direct paragraph);
  `docs/matrix-api-scope.md` l.56 (sync), l.65 (leave), l.70 (forget); `docs/architecture/06-runtime.md` Scenario 3b (l.202-215); the Oracle
  context `_bmad-output/nebu/epics/oauth-broker/step-results/create-room-invites-direct/oracle-context.md`; spec `client-server-api/index.html`
  (`GET /sync` response, Stripped state, Leaving rooms, `POST /forget`, Ignoring Users), `skills/nebu-conventions/cluster-safety/SKILL.md`.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev step, bmad-dev-story). The ATDD reference implementation was used as a starting point only and was reviewed and rewritten
(SQL fragments shared, the partition in small functions, the wait loop without the process dictionary, DISTINCT ON for the stripped state).

### Debug Log

- The runner scripts named in the brief (`quick.sh`, `env.sh`, `cleanup.sh`) did not exist; an own runner (`docker run elixir:1.19-alpine` against a
  throwaway PostgreSQL 16 on a private network) was used. The shared compose project `nebu` was never touched.
- The first full run on the long-lived throwaway DB failed `AdminStaleRoomsTest` (15 659 accumulated rooms, the test lists 50): DB pollution, a fresh
  PostgreSQL + migration fixed it. `CreateRoomInvitesHttpTest` "AC5 - is_direct" failed once in the final full run with a 401 `M_UNKNOWN_TOKEN` (a token
  invalidated by a concurrent suite) and passed twice alone (53 tests, 0 failures each).
- (first pass, Elixir 1.19.5; the CI image is 1.20 and review cycle 1 re-ran everything on `elixir:1.20-alpine`, where this warning does not exist) `mix test --warnings-as-errors` without a database: 5 723 tests, 0 failures, but the run aborts on ONE warning that is not in this story's code: the
  Elixir 1.19.5 type checker warns about `hd(aliases)` in the untouched `test/nebu/matrix/event_dispatcher/set_room_state_test.exs:713` (a `for ... into []`
  list). Reproduced identically on a clean `git archive HEAD` copy (46 tests, 0 failures, "aborted due to warnings"): pre-existing, out of scope (new
  follow-up note below). `mix compile --force --warnings-as-errors` is clean.

### Completion Notes List

- **Implementation (as the story).** `Nebu.Matrix.Room.DB`: `membership_candidates/1`, `latest_member_events/2`, `invite_state_events/1`,
  `leave_window_events/3`, `latest_member_event/2` (D2a shapes), the D3 tie order shared by `@sql_get_member_membership` and the new reads (one set of SQL
  fragments: raw membership with `pg_input_is_valid` so an unparseable string never fails the statement, rank, normalisation); `InviteDB.pending_invitation/2`.
  `EventDispatcher.Server`: `sync_partition/1` (rule table, one function per read, `partition_read!/2` raises `unavailable`), `get_initial_sync/2` and
  `do_incremental_sync/5` on top of it (try/after leaves the `:pg` groups, `wait_for_wakeup/3` with the D11 wake rules, rebuild from fresh reads on a wake),
  `build_invite_rooms/2` (D4), `build_leave_room/3` (D6), `full_state_rooms/3` (D14), the Task result handed back and re-raised in the caller, D13
  (`invitation_valid!/2`, both reads fail closed with 500), D7 (unforget after the invite event) and D9 (`wake: false` in createRoom step 8, wake-ups after the
  last invite with `:pg.get_members/1`). `Http.sync_response/5` renders `rooms.invite` / `rooms.leave` (the timeline event rendering is one shared helper);
  `do_sync/1` reads `full_state`, maps a failed read to `503 M_UNAVAILABLE` through `call_core/1` and adds account-data-only rooms only for the join class.
  `Core.*` structs and `proto/core.proto` in parity. The interim guard (`pending_only_room_ids`, `pending_only_event?/2`), `generate_delta_token/3` and the
  stale Go comments are gone; `get_recently_left_rooms_for_user/1` / `get_declined_invite_rooms_for_user/1` stay (documented as unused by the sync).
- **Tests.** New suites: `room/membership_partition_db_test.exs` 28, `event_dispatcher/sync_membership_partition_test.exs` 57,
  `sync_membership_partition_http_test.exs` 48, `sync_membership_partition_docs_test.exs` 26 (all green). Re-pinned / extended: `join_room_test.exs` 79,
  `create_room_invites_test.exs` 69, `sync_test.exs` 29, `server_dedup_test.exs` 3, `forget_room_membership_purge_test.exs` 8,
  `create_room_invites_http_test.exs` 53, `create_room_invites_docs_test.exs` 17, `create_room_presets_http_test.exs` 71,
  `create_room_presets_docs_test.exs` 28 (all green). No test was changed in this step. Full suite with `--include integration` (fresh DB, the 150 ms
  `regression_sync_load_test` moved aside and restored): 8 800 tests, 24 failures, all in known flaky families (TraceMapNodeControls, TemporaryCaptureManager,
  AdminOidcLogin, RoomsFallbackName, LogStore.Retention, WarRoom) plus the one 401 flake above that passes alone.
- **EXPLAIN (ANALYZE, BUFFERS)** on a seeded throwaway DB (PostgreSQL 16, 600 rooms, one user with 500 member rows (400 active, 100 left) and 50 pending invitations,
  20 member events of the user per room, 200 messages + 30 foreign member events + create + 5 name events per room: about 225 000 events; the statements as
  prepared, parameters bound, a generic-plan shape). NO Seq Scan anywhere (the 30-line plans, long `Index Cond` id lists cut):
  - (a) `membership_candidates`: `Append` of `Bitmap Index Scan on room_members_user_id_idx` (500 rows) and `Bitmap Index Scan on room_invitations_invitee_idx`
    (50 rows); Buffers: shared hit=24; Execution Time: 0.195 ms.
  - (b) `latest_member_events` for 550 candidate rooms: `Incremental Sort` > `Subquery Scan on ranked` > `WindowAgg` (Run Condition: row_number() <= 2) >
    `Incremental Sort` (Sort Key: room_id, origin_server_ts DESC, rank, event_id DESC) > `Index Scan using events_room_state_idx on events` (Index Cond: room_id =
    ANY (...) AND event_type = 'm.room.member' AND state_key = '@u:test.local'; 11 000 rows = the user's own member events, 12 709 buffers); returns 1 100 rows;
    Planning Time: 3.692 ms, Execution Time: 14.077 ms (ONE round trip for 550 rooms).
  - (c) `invite_state_events` for 50 invite rooms: `Unique` > `Sort` > `Index Scan using events_room_state_idx on events` (Index Cond: room_id = ANY (...) AND
    state_key = ''; 300 rows); Execution Time: 0.636 ms.
  - (d) `leave_window_events`: `Limit` > `Incremental Sort` > `Index Scan Backward using events_room_id_ts_idx on events` (Index Cond: room_id AND
    origin_server_ts > $2 AND origin_server_ts < $3); Buffers: shared hit=24; Execution Time: 0.143 ms.
- **Review cycle 1 (code review 0 MAJOR / 8 MINOR, Kassandra CLEAN: 1 MEDIUM, 3 LOW), all implemented, decisions R1-R8 above and AC23.**
  - M-1: `membership_candidates/1` returns `left_at`, the leave window ends at `min(L.ts, left_at)` (real-DB candidate test, HTTP test with a raw-body check, unit test
    with the recorded window bound; the tests fail without the bound: verified by mutation).
  - L-1: CHOSEN the re-read (not the truncation): the partition is read again after the join rooms were fetched, a demoted room rebuilds the delivery (max 2 rebuilds,
    then 503, cycle 2). Unit tests with a hook after the candidates read: incremental, initial sync, repeated demotions.
  - L-2 / MINOR-1: `resolve_since_ts/1` before the Task: gone anchor = initial-sync fallback, other failures = 503 (unit + HTTP).
  - MINOR-2: `get_member_membership/2` normalised (real-DB tests, both readers agree). MINOR-3: the Repo guard is gone. MINOR-4 / L-3: `Room.DB.inviter_member_events/1`,
    ONE statement for all inviters (real-DB tests: 300 pairs = one statement, tie order, no Seq Scan); the unit fakes use the per-inviter fallback. MINOR-6: the stale
    prose of the new suites rewritten (comments only; `pending_invitation/2` is called directly). MINOR-8 / I-9: throw / exit / exception re-raised in the caller with
    `strip_stacktrace_args/1` (unit tests). MINOR-7 / docs: notes on `ez`, `fc`, `fg`, `ey` (no new ids: the sibling suites pin "`fh` onward"), the scope doc sync row, the
    07-deployment gate, the proto comment (INFO-10), "PostgreSQL 16+" in the Helm values (the README already says 16+).
  - Results on `elixir:1.20-alpine` (the CI image): per file `room/membership_partition_db_test.exs` 33, `sync_membership_partition_test.exs` 66,
    `sync_membership_partition_http_test.exs` 50, `sync_membership_partition_docs_test.exs` 26, `join_room_test.exs` 79, `create_room_invites_test.exs` 69, `sync_test.exs` 29,
    `server_dedup_test.exs` 3, `forget_room_membership_purge_test.exs` 8, `create_room_invites_http_test.exs` 53, `create_room_invites_docs_test.exs` 17,
    `create_room_presets_http_test.exs` 71, `create_room_presets_docs_test.exs` 28 (all green). Full suite with `--include integration` on a fresh DB (the 150 ms
    `regression_sync_load_test` moved aside and restored): 8 783 of 8 808 passed, 25 failures, all known flaky families (SweeperTest, RoomsFallbackName x12, AdminOidcLogin x3,
    WarRoom, SsoLogin, TraceMapNodeControls x3, TemporaryCaptureManager x3, MatrixClientCompat replaces_state; the replaces_state test that fails changes from run to run
    and failed alone as well, on a test of that family). `mix compile --force --warnings-as-errors` is clean and the no-DB `mix test --warnings-as-errors` is green
    (5 725 passed, exit 0) on Elixir 1.20: the `set_room_state_test.exs:713` warning is a 1.19-lane warning only (follow-up note `fg` (l)).
  - EXPLAIN (ANALYZE, BUFFERS) of the CHANGED statements (same seeded DB, plus 20 000 foreign member rows and 2 000 foreign invitations for (a)): no Seq Scan.
    (a) `membership_candidates` with `left_at`: two `Bitmap Index Scan` (`room_members_user_id_idx` 500 rows, `room_invitations_invitee_idx` 50 rows), Buffers shared hit=10,
    0.152 ms (on a database where the user owns 61 % of a tiny table the planner prefers a Seq Scan, a cost choice: the DB test with `enable_seqscan` off pins that the
    index serves it). `get_member_membership` (normalised): `Index Scan using events_room_state_idx` (Index Cond room_id AND event_type AND state_key), Incremental Sort, Limit,
    0.104 ms. `inviter_member_events` (50 invite rooms, 50 inviters in ONE statement): `Nested Loop` over `Function Scan on pair` and `Index Scan using events_room_state_idx
    on events ev` (Index Cond room_id = pair.room_id AND event_type AND state_key = pair.user_id), Sort, Unique, 0.476 ms. (b), (c), (d) are unchanged (see above).
- **Review cycle 2 (Kassandra delta gate: CLEAN, N-1 LOW), implemented, R9.** The re-read compares the whole join class and also runs when only an invitation / leave moves
  the anchor; exhausted rebuilds are a 503 (no token) instead of a silent drop; `joined_at` bounds the window start (I-1). New tests: unit (the kick during the fetch of
  another room whose newer message moves the anchor: same-sync leave; the anchor moved by a delivered invitation; repeated demotions = 503 and the retry delivers all
  leaves; the `joined_at` bound), real DB (`joined_at` in the candidates); the two N-1 tests fail with the cycle 1 logic (verified by mutation). I-5 not done. The cycle 1
  statements "dropped, the leave arrives with the next sync" in R2, the Completion Notes and `fc` (g) were wrong and are corrected.
  - Results of cycle 2 on `elixir:1.20-alpine` with a fresh DB: `membership_partition_db_test.exs` 33, `sync_membership_partition_test.exs` 69, `sync_membership_partition_http_test.exs` 50,
    `sync_membership_partition_docs_test.exs` 26, `join_room_test.exs` 79, `create_room_invites_test.exs` 69, `sync_test.exs` 29, `server_dedup_test.exs` 3,
    `forget_room_membership_purge_test.exs` 8, the four create_room invites / presets suites 53 / 17 / 71 / 28 (all green). Full suite with `--include integration`
    (`regression_sync_load_test.exs` left aside by the coordinator): 8 790 of 8 811 passed, 21 failures, all known families (RoomsFallbackName x11, AdminOidcLogin x3,
    TraceMapNodeControls x2, LogStore.Retention x2, TemporaryCaptureManager x2, MatrixClientCompat replaces_state x1). `mix compile --force --warnings-as-errors` clean, the no-DB
    `mix test --warnings-as-errors` green (5 728 passed, exit 0, no warning).
- **Deviations of review cycle 1.** (1) `inviter_member_events/1` is a fifth read next to the four of D2a, OPTIONAL for the sync (a module without it is served by
  `latest_member_events/2` per inviter) so the pinned fakes stay valid; (2) the L-1 re-read costs the two partition statements once more when join rooms were delivered
  (the EXPLAIN pins and the statement-count pins are per read, unchanged); (3) no new follow-up ids (the sibling docs suites pin "`fh` onward"): the notes are on `ez`, `fc`,
  `fg`, `ey`.
- **Deviations from the story.** (1) D2 counts three statements per build; the stripped state of an invitation also reads the INVITER's member event with
  `latest_member_events/2` of the inviter (D2a pins that read): one extra statement per DISTINCT inviter among the new invitations (restricted to the rooms that
  inviter invited to), plus the ignore-list read when there is a pending invitation. (2) D14: the timeout is forced to 0 in the core (`get_sync_delta/2`) and not in
  the route, so the property also holds for a direct core call. (3) `get_member_membership/2` now reads an unparseable double-encoded body as `nil` instead of
  raising (the shared `pg_input_is_valid` fragment; PostgreSQL 16 is the documented platform minimum). (4) The join decision's read failures use the existing
  `raise_join_unavailable/0` (500, message "join_room: the room state is unavailable"). (5) The e2e task is not ticked: the scenarios are written, the orchestrator runs them.
- **Follow-ups noticed (not implemented).** (a) `set_room_state_test.exs:713` `hd(aliases)` type warning under Elixir 1.19.5 aborts `mix test --warnings-as-errors`
  (pre-existing on `HEAD`; a one-line test fix, `hd/1` on a literal-length list). (b) `since_ts_of/1` treats a failed anchor timestamp read like a missing anchor (0):
  ended leaves and invitations of a user would be re-delivered once (no content after a leave leaks; the same fallback as `fetch_events_since/3`), fold into `fc`.
  (c) A change that lands between the partition read and the `:pg` subscription (for example a decline from another device) is delivered by the next sync, not by
  this wait (documented in `do_incremental_sync/5`). (d) `get_recently_left_rooms_for_user/1` and `get_declined_invite_rooms_for_user/1` have no caller in
  `server/lib` any more (kept by decision m11), remove with the next `DBBehaviour` change. (e) One statement per NEW leave entry: an account that leaves hundreds of
  rooms between two syncs costs hundreds of window reads (bounded by the 20-event limit; batching is possible if it ever matters).

### File List

- `server/lib/nebu/matrix/room/db.ex` (D3 order, the five new reads)
- `server/lib/nebu/matrix/room/invite_db.ex` (`pending_invitation/2`, doc of the unused declined read)
- `server/lib/nebu/matrix/room/db_behaviour.ex` (doc line of `get_recently_left_rooms_for_user/1`)
- `server/lib/nebu/matrix/event_dispatcher/server.ex` (partition, initial / incremental sync, D7, D9, D13, D14, Task re-raise)
- `server/lib/nebu/matrix/http.ex` (`sync_response/5`, invite / leave renderers, shared timeline event helper, moduledoc)
- `server/lib/nebu/web/router/protected.ex` (`do_sync/1`: `full_state`, 503 mapping, join-class filter of the account-data-only rooms)
- `server/lib/pb/core.pb.ex`, `proto/core.proto` (new fields and structs, comment parity)
- `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/06-runtime.md`, `docs/stories/oauth-broker/follow-ups.md` (AC15)
- `docs/stories/oauth-broker/sync-membership-partition.md` (this file)
- Review cycle 1: `deploy/helm/nebu/values.yaml` (comment: PostgreSQL 16+), `server/test/nebu/matrix/room/membership_partition_db_test.exs`, `server/test/nebu/matrix/event_dispatcher/sync_membership_partition_test.exs`, `server/test/nebu/matrix/sync_membership_partition_http_test.exs`, `server/test/nebu/matrix/sync_membership_partition_docs_test.exs` (new tests, fake switches, comment rewrites only; no assertion weakened)
- Staged by the ATDD step and unchanged here: the four new suites, the re-pinned suites of AC16 and the e2e files (`e2e/features/element/dm/create-dm.feature`,
  `e2e/features/element/room/join.feature`, `e2e/step-definitions/element/dm.steps.ts`, `e2e/step-definitions/element/room.steps.ts`)

### Change Log

- 2026-10-17 (create-story, Oracle gate corrections): rule 4 excludes taken-back invitations (`leave` with `ts >= invited_at` -> rule 5, leave
  `[L]`); D13: the join decision refuses them (premise: `authorize_join!/2` granted on the pending row alone, `leave_without_room_process/3` ignores a
  failed reject); a non-limited leave window omits `prev_batch`; the limited-window state gap documented; D14 `full_state=true` implemented; D15
  `use_state_after` not claimed (`/versions` max v1.15) and pinned; `M_UNAVAILABLE` documented as a non-spec errcode; filters / `include_leave`
  documented as a known deviation; `fg` (h) added; AC19-AC22 cover every test of the Oracle list; edge table +3 rows. Ids `fc`-`fg` unchanged.
- 2026-10-17 (ATDD step, re-pins beyond the AC16 list; old -> new): `join_room_test.exs`: the test "a failing pending-invite read keeps today's
  semantics" (403 in an invite room) -> 500 in an invite room (D13 / AC19 (f): the join decision's reads fail closed), public room unchanged (200,
  no read); the call-count pin `get_pending_invite_rooms_for_user` == 1 -> `pending_invitation` == 1 (the decision reads the invitation through the new
  read); the "reads nothing" pins also assert `pending_invitation` / `latest_member_event` are not called; the fakes gain `latest_member_event/2` and
  `pending_invitation/2`. `sync_test.exs` D11 describe: the wake test no longer asserts `{:room_group_subscribed, true}` (replaced by the subscription
  checks of the new unit suite) and asserts the invitation in `invite_rooms`; the L-3 test also asserts empty `invite_rooms` / `leave_rooms`.
  `create_room_invites_docs_test.exs` / `create_room_presets_docs_test.exs`: the assertions "the creator side of a DM works", "the INVITEE does not
  see the invitation" and "`/join <room id>`" -> refutations (the old claims must be gone) and "invitations are shown"; the gate is `ey`. Fakes of
  `admin_force_add_member`, `audit_member_ops` and `admin_member_management` gain `pending_invitation/2` / `latest_member_event/2` (data only).
- 2026-10-17 (test review fixes): D2a added (names and shapes pinned, test review m3); `get_recently_left_rooms_for_user/1` stays in `Room.DB` and
  `DBBehaviour` with a doc line (m11).
- 2026-10-17 (dev step): implementation of the story as specified; deviations and follow-ups in the Completion Notes (EXPLAIN output included); status review.
- 2026-10-17 (review cycle 1): Kassandra M-1 (`left_at` bounds the leave window), L-1 (partition re-read after the join fetch, rebuild / drop), L-2 + MINOR-1 (anchor read:
  gone = initial fallback, other = 503), L-3 + MINOR-4 (`inviter_member_events/1`, one statement), MINOR-2 (`get_member_membership/2` normalised), MINOR-3 (Repo guard removed),
  MINOR-8 + I-9 (Task hand-back of throw / exit, stacktrace without arguments), MINOR-5 (verified on Elixir 1.20), MINOR-6 (stale test prose), MINOR-7 + INFO-10 (follow-up notes,
  proto comment, Helm comment), residual wording in the docs; new tests: DB +5, unit +9, HTTP +2; D2a addendum, decisions R1-R8, AC23.
- 2026-10-17 (review cycle 2): Kassandra N-1 (whole-join-class re-read, also when only an invitation / leave moves the anchor; exhausted rebuilds = 503 instead of a drop),
  I-1 (`joined_at` bounds the window start), wording of R2 / `ez` / `fc` (g) corrected, AC23 (b) updated, R9; I-5 not done.
