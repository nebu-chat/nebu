---
story_id: create-room-invites-direct
title: "createRoom processes invite / invite_3pid / is_direct (DMs), trusted_private_chat invitee power level, one shared invite path with an m.room.member invite event, and an interim /sync guard for invited-only rooms (follow-up eb)"
type: bugfix
severity: high
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-16
branch: feature/migrate-to-oauth2
---

# Story: `POST /createRoom` invites (`invite`, `invite_3pid`, `is_direct`, `trusted_private_chat`) through the same path as `POST /rooms/{roomId}/invite` (follow-up `eb`)

As a Matrix user (Element Web "Start chat" with one colleague, a group DM, a private room with invitees) I want the people I name in
`createRoom` to be invited into the new room, a DM to be marked as a direct chat for my partner, and my DM partner to get the same power
level as me (the `trusted_private_chat` preset), so that a DM or a private room is not an empty invite-only room nobody else can enter.
As an operator I want every invitation, whether it comes from `createRoom` or from `POST /invite`, to follow the same rules (no foreign,
unknown, banned or already joined users; a malformed request is a clear 4xx, never a 500) and to leave a signed `m.room.member` invite
event in the room, and I want to know exactly what still does not work in Element before the release (the invitation is not shown to
the invitee until the `/sync` invite section exists: follow-ups `ev` and `ez`, the NEXT story and the release gate).

Follows `create-room-presets-power-levels-topic` (join enforcement, `InviteDB` re-arm, `invite_user/2` rules, presets, power levels,
one timestamp chain) and `create-room-input-validation` (`validate_create_room_request/1`, the errcode convention). **Not in this story:**
the `/sync` `rooms.invite` / `rooms.leave` sections (`ev`) and the confidentiality defect of the incremental sync (`ez`, new, HIGH): both
are the next story and gate the release to Element-based deployments (see "Decision on `ev`" below).

## Premises verified against the code (2026-10-16, HEAD `1af141f4`)

Every premise was checked in the code of this branch, in the Element Web 1.12.15 bundle of the dev container `nebu-oauth-dev-element-1`
(`/usr/share/nginx/html/bundles/3c9ddd76fa48d1221fef/init.js`, copied out of the stopped container with `docker cp`; the dev server
container `nebu-oauth-dev-server-1` was stopped, so no `bin/nebu rpc` probe was possible: the premises below are code-level and are pinned
by the acceptance tests) and in the local spec copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`.

### What `createRoom` does with `invite` / `invite_3pid` / `is_direct` today

| Question | Verified state |
|---|---|
| Does the router read `invite` / `invite_3pid`? | **NO.** `protected.ex` `post "/client/v3/createRoom"` (~l.1219-1313) builds `Core.CreateRoomRequest` without them; `Core.CreateRoomRequest` (`lib/pb/core.pb.ex` ~l.41-62) has no such keys. A DM / private room is created with the creator as the only member and NO invitation. |
| `is_direct` | Read as `is_direct: params["is_direct"] == true` (~l.1291): any non-boolean value (`"true"`, `1`) silently becomes `false`. Its ONLY use is the `room_created` audit metadata (`create_audit_metadata/2`, server.ex ~l.587). Nothing stores it on an event (there is no invite event to put it on). |
| `trusted_private_chat` | Writes the same preset events as `private_chat` (`preset_events/1` ~l.984-996; comment "its invitee power level rule needs `invite`, follow-up eb"). |
| Consequence since the join enforcement | A DM is invite-only (preset `trusted_private_chat` -> join rule `invite`), the partner holds no invitation, so `POST /join` is `403 "You are not invited to this room"`: Element DMs cannot be entered at all, only after a separate `POST /rooms/{id}/invite` by the creator. |
| Spec order | `invite` / `invite_3pid` are step 8, after `name` / `topic` (`api.json` `/createRoom`: "8. Invite events implied by `invite` and `invite_3pid` (`m.room.member` with `membership: invite` and `m.room.third_party_invite`)"). |

### What `invite_user/2` does on its own today (server.ex ~l.2332-2419)

| Step | Verified state |
|---|---|
| Order | room running (`RoomSupervisor.lookup_room/1`, else `404`) -> inviter is a member (else `403`) -> `PowerLevels.can?(levels, inviter, :invite)` (`invite`, default 0) -> target already a member (`403 M_FORBIDDEN` "The invited user is already in this room", self-invite included) -> target's latest membership `ban` (`invite_target_banned?/2`, `403 M_FORBIDDEN`, a failing read is `500`) -> `InviteDB.insert_invitation/3` (re-arms an accepted / rejected row) -> `{:new_invite, room_id}` to the `:pg` group `user:<invitee>` -> `200 {}`. |
| **No `m.room.member` invite event** | `invite_user/2` writes ONLY the `room_invitations` row. No event is signed or inserted, so the room timeline of the inviter never shows the invitation, `get_member_membership/2` never returns `invite`, and `is_direct` has nowhere to live. Spec: "If the user was invited to the room, the homeserver will append a `m.room.member` event to the room" (`POST /rooms/{roomId}/invite`) and, Direct Messaging, Server behaviour: "When the `is_direct` flag is given to `/createRoom`, the home server **must** set the `is_direct` flag in the invite member event for any users invited in the `/createRoom` call." |
| Validation of `user_id` | NONE. The route (`protected.ex` ~l.1332-1347) passes `params["user_id"]` raw (any JSON type, or `nil`) as `invitee_id`; there is no JSON-parse / non-object guard on this route either. `room_invitations` (`000001_init.up.sql` l.256-264) has `invitee_id TEXT NOT NULL REFERENCES users(user_id)`: a missing `user_id`, a non-string, a malformed id, a foreign-domain id and a well-formed local id without a `users` row (a colleague who never logged in) all end in a constraint violation -> `500 M_UNKNOWN` (the `Nebu.Matrix.Error` message carries `inspect(reason)`, dropped by `map_error/1` for 500s). The third-party form of the endpoint (`{id_server, id_access_token, medium, address}`, no `user_id`) is also a `500`. |
| Already invited | A second invite of a pending invitee refreshes the row (`ON CONFLICT ... DO UPDATE`), `200`. Spec: "200: The user has been invited to join the room, or was already invited to the room." |
| Deactivated users | Not checked: the row exists, so a deactivated account (`users.is_active = false`) gets an invitation. `Nebu.Matrix.active?/1` (matrix.ex ~l.459) is the existing read-only signal. |
| Foreign domain | Not checked here; `admin_add_room_member/3` has `local_domain?/1` (server.ex ~l.2043, compares with `:event_dispatcher, :server_name`) as its no-federation guard. |
| `reason` | Not read (spec v1.1 optional field). Out of scope (`fa`). |
| Other writers of invitations | `admin_add_room_member/3` (inserts the row then joins at once; no invite event needed), `upgrade_room` (~l.6098-6110: row only, failures are warnings). Both stay unchanged (D12). |
| Orphan cleanup | `Room.DB.delete_room/1` (db.ex ~l.251) deletes events, members, aliases and the room row, **not `room_invitations`**: the FK `room_invitations.room_id REFERENCES rooms(room_id)` makes the cleanup of a half-created room that already holds an invitation fail (the transaction rolls back, the orphan stays). Must be fixed before step 8 can be fatal (D8). |

### What Element Web 1.12.15 sends (bundle `init.js`, module `./src/createRoom.ts`, `./src/utils/direct-messages.ts`, `./src/utils/local-room.ts`, `./src/Rooms.ts`, `./src/utils/MultiInviter.ts`)

| Flow | Verified request / behaviour |
|---|---|
| DM with ONE user (`startDm` -> `createRoom(client, {dmUserId, encryption?, spinner})`) | `preset: "trusted_private_chat"`, `visibility: "private"`, `invite: ["@partner:server"]`, `is_direct: true`, `initial_state`: `m.room.guest_access {"guest_access": "can_join"}`, `m.room.encryption` (only when Element decides to encrypt: all targets have device keys; skipped by Nebu, ADR-011), `m.room.history_visibility {"history_visibility": "invited"}`; no `name`, no `topic`. An e-mail target becomes `invite_3pid: [{id_server, medium: "email", address}]` ONLY if an identity server is configured, otherwise Element throws `cannot_invite_without_identity_server` itself. |
| Group DM (several targets) | `createOpts: {invite: [...], invite_3pid: []}` (always both keys; `invite_3pid` is an EMPTY list for Matrix ids), no `dmUserId` -> `preset: "private_chat"`, no `is_direct`. So `invite_3pid: []` MUST be accepted. |
| After the create | Element waits until the room appears in its own `/sync`, then `Rooms.setDMRoom` (`FZ`) writes the creator's `m.direct` account data (`PUT /user/{id}/account_data/m.direct`, already supported). For a "local room" DM (start on first message) Element waits until `room.getInvitedAndJoinedMemberCount() === 1 + targets` and a history_visibility state event exist (500 ms polling, 5 s timeout "Assuming local room ... is ready"): Nebu's `m.joined_member_count` / `m.invited_member_count` come from `room_members` / pending `room_invitations` (`get_room_heroes/2`), so today the count stays 1 and Element only proceeds after the 5 s timeout; with this story it is 2 at once. |
| Invitee side | `DMRoomMap.getUserIdForRoomId` -> `room.getDMInviter()` (js-sdk: the `is_direct` flag of the syncing user's own `m.room.member` invite event, its `sender` is the DM partner). So `is_direct` must be on the invite member event; the invitee only sees it through `rooms.invite.<id>.invite_state` (`ev`). Element accepts with `POST /_matrix/client/v3/join/{roomId}` (routed). |
| `POST /invite` (`MultiInviter`) | Body `{user_id, reason?}`. Errcodes Element handles: `M_FORBIDDEN` -> "no permission" AND `_fatal` (stops the remaining invites of the batch); `M_NOT_FOUND` / `M_USER_NOT_FOUND` -> "user not found" (with the "invite anyway" dialog); `M_BAD_STATE` -> bad state; client-side already-joined / already-invited checks read the member list (needs the invite member event). |
| Duplicate DMs | `findDMForUser` reuses a DM only when the target is among the room's joined / invited MEMBERS (member events) and there are exactly two: without an invite member event every "Message" click on the same user creates a new room. |

### `/sync` and the invite section (`ev`): sizing evidence

| Finding | Verified state |
|---|---|
| `Nebu.Matrix.Http.sync_response/3` | Always `"invite" => %{}` and `"leave" => %{}` (moduledoc "MINOR-2": the proto `SyncRoom` carries no membership; the Go gateway's `buildInviteRooms` / `buildLeaveRooms` were never ported). |
| Initial sync (`get_initial_sync/2`, server.ex ~l.3800) | Joined rooms only (`get_rooms_for_user/1` = `left_at IS NULL`). No invites, no left rooms. |
| Incremental sync (`do_incremental_sync/4`, ~l.4026-4173) | `room_ids = joined ++ pending invitations ++ ALL declined invitations ++ ALL left rooms` (`get_recently_left_rooms_for_user/1` is `left_at IS NOT NULL`, no time bound) minus forgotten, then `fetch_delta_rooms/3` ships EVERY room of that list with new events (`fetch_events_since/3`, `origin_server_ts > anchor`, up to 20) into **`rooms.join`** with the full state (`build_state_events/3`). `forget_room_membership_purge_test.exs` AC4 pins a left room re-surfacing in `rooms.join`. |
| **Consequence (new finding, `ez`, HIGH)** | A user who LEFT a room, was kicked, banned or removed by an Admin (all soft-delete `room_members.left_at`), and a user who DECLINED an invitation, receives every NEW event of that room, message content included, in `rooms.join` of each incremental `/sync` until they forget the room. An invitee receives the room's events before joining. Not recorded anywhere before (`06-runtime.md` Scenario 3b still describes the never-ported Go `buildLeaveRooms`). |
| Wake-ups | `{:new_invite, _}` and `{:new_leave, _}` return `[]` "so Go's buildInviteRooms / buildLeaveRooms can find it" (comments ~l.4110-4143): nothing builds them. |
| Since-token anchor | One global newest-event id (`generate_delta_token/3`); invite / leave delivery must advance it without delivering room content, otherwise an invite repeats and the long-poll returns immediately forever. |
| Element e2e | `room/join.feature` @ac8-join-room passes only because its step navigates to the room id URL ("rather than waiting for the invite tile to arrive via the invitee's long-poll /sync", `room.steps.ts` ~l.132-139). |

### Decision on `ev`: NOT in this story; `ev` + `ez` are the NEXT story and gate the release

Doing `ev` honestly means re-partitioning the incremental `/sync` by membership: invited rooms into `rooms.invite` with a stripped
`invite_state` (`m.room.create` is REQUIRED since v1.16, plus `m.room.name`, `m.room.avatar`, `m.room.topic`, `m.room.join_rules`,
`m.room.canonical_alias`, `m.room.encryption` and the invitee's own invite member event with `is_direct`, only `type` / `state_key` /
`sender` / `content`), invites "new since the token" (invite event timestamp vs. the anchor) for incremental syncs and all pending invites
for initial syncs, declined / left / kicked / banned rooms into `rooms.leave` with a timeline bounded AT the leave event (the `ez` fix: nothing
after it), the anchor advanced past delivered invite / leave events, the two wake-ups re-querying, ignored users' invites suppressed (spec
MUST), proto / struct and `Http` changes, unit fakes for three sync code paths, the re-pinned `forget_room_membership_purge_test` AC4 and an
Element UI invite / accept / decline / DM scenario. That is a story of the size of this one (or of the presets story), with its own security
review (a confidentiality fix). Both together would not be one coherent, reviewable unit. **This story therefore delivers `eb` only, plus one
narrow interim guard (D11) without which `eb` would make the `ez` defect visible for every DM; `ev` + `ez` are the next story and remain the
release gate** (07-deployment, release gate paragraph, updated by AC17).

## Spec (Matrix CS API v1.18, local copy)

- createRoom step 3: "A default `m.room.power_levels` event. Overridden by the `power_level_content_override` parameter." Preset table:
  `trusted_private_chat` -> "All invitees are given the same power level as the room creator." Note: for `trusted_private_chat` the invitees
  SHOULD also go to `additional_creators` (room v12+ only; Nebu creates v10 only, `Nebu.Matrix.RoomVersions`: not applicable).
- Step 8: invite events (`m.room.member`, `membership: invite`) after `name` / `topic`. "The server MUST apply the normal state resolution
  rules ... including checking power levels for each event" (v10 invite auth: the sender's level >= `invite`; the target is not joined / banned).
- `invite`: "A list of user IDs to invite to the room." (array of strings). `invite_3pid`: list of `{id_server, id_access_token, medium,
  address}` (all required). `is_direct`: "This flag makes the server set the `is_direct` flag on the `m.room.member` events sent to the users
  in `invite` and `invite_3pid`." Direct Messaging, Server behaviour: the server **must** set it on the invite member event.
- createRoom responses: 400 (`M_BAD_JSON` / `M_NOT_JSON`, `M_ROOM_IN_USE`, `M_INVALID_ROOM_STATE`, `M_UNSUPPORTED_ROOM_VERSION` incl. "one or
  more users being invited ... are residents of a homeserver which does not support the requested room version"), **403 "Creating the room is
  not allowed"** (v1.18: `M_INVITE_BLOCKED` when an invitee's homeserver rejected the invite). Invite permission module: "It is possible for one of
  the invited users to be rejected whilst the room creation as a whole succeeds" (in the invite-blocking context; Nebu decides all-or-nothing, D8).
- `POST /rooms/{roomId}/invite` (user-id form): body `user_id` (required), `reason` (optional); 200 also when already invited; 400 malformed
  body (`M_BAD_JSON` / `M_NOT_JSON`); 403 banned / already a member / inviter not in the room / insufficient power level (`M_INVITE_BLOCKED`
  v1.18). The 3pid form needs an identity server; Nebu has none (`docs/matrix-api-scope.md` "Intentionally Excluded": `/_matrix/identity/*`,
  `GET /capabilities` `m.3pid_changes: false`).
- Errcodes: `M_THREEPID_DENIED` "The server does not permit this third-party identifier" (Synapse uses it with 403);
  `M_SERVER_NOT_TRUSTED` (an untrusted identity server). `m.room.member` content: `membership` (required), `is_direct` (boolean), `reason`.
- Stripped state / `rooms.invite` (for `ev`, not this story): see the sizing table.

## Decisions

- **D1 (one shared invite path).** `invite_user/2` is split into the request part (room running, inviter member, inviter `invite` level: unchanged,
  same order, same texts) and a shared internal helper (suggested name `do_invite!/4`: `room_id`, `inviter`, `invitee`, `opts` with `is_direct`)
  that BOTH `invite_user/2` and `create_room` step 8 call. The helper decides, in this order: target already a member -> `403 M_FORBIDDEN`
  (unchanged text); target's latest membership `ban` -> `403 M_FORBIDDEN` (unchanged, fail closed); target ALREADY INVITED (a pending
  `room_invitations` row AND the latest membership read is `invite`) -> `200`, nothing written (spec "or was already invited"; no refreshed row,
  no second event, no broadcast); otherwise `InviteDB.insert_invitation/3` (re-arm, unchanged) THEN the invite member event (D2) THEN the
  `{:new_invite, room_id}` broadcast. A failing invite event write after a successful row write rejects that row again (best effort,
  `reject_invitation/2`, value-free log) and is a `500` on `POST /invite` (no half invitation that is joinable but invisible); in `createRoom` it
  is fatal (D8). The latest-membership read for the ban check is reused for the already-invited check (one read).
- **D2 (the invite member event).** Through `emit_state_event_at/6` (signed, inserted, fanned out to `room:<id>`): `type: "m.room.member"`,
  `state_key: <invitee>`, `sender: <inviter>`, `content: {"membership": "invite"}` plus `"is_direct": true` ONLY for a `createRoom` invite with
  `is_direct: true` (POST /invite never sets it; `false` is not written). No `displayname` / `avatar_url` (Nebu's own join events carry none
  either; `fa`). After it `get_member_membership/2` answers `invite` for the target: every existing reader was checked (join decision and
  `Room.Server.check_not_banned/2`: `== "ban"` only; `leave_without_room_process/2`: decline for a pending invitation; `summary_membership/4`:
  pending row first; auto-join: `== "ban"`): no behaviour change except that the room summary keeps answering `invite`. The decline
  (`POST /rooms/{id}/leave` of an invitee) now follows a real invite event (invite -> leave, spec-shaped). **`reason` is IGNORED (known
  deviation, Oracle gate):** the spec says the `/invite` `reason` is "included as the reason on the subsequent membership event"; Nebu does not
  read it yet (`fa` (a)). A request WITH a `reason` (any type) is processed exactly like one without (`200`, no `reason` key on the event, no
  400 for a non-string `reason`); the scope doc invite row labels this a known deviation.
- **D3 (who can be invited: the same eligibility on both paths).** A target is eligible when: a string (else `400 M_BAD_JSON`); a valid user id
  (`Nebu.Matrix.UserId.valid?/1`, else `400 M_INVALID_PARAM`); of the LOCAL server (`local_domain?/1`, else **`403 M_FORBIDDEN`** "Users of other
  servers cannot be invited: this server does not federate"); an existing ACTIVE local account (`users.is_active = true`, one read, a failing
  read is `500` fail closed; else **`404 M_NOT_FOUND`** "The user to invite does not exist on this server", the SAME text for unknown and
  deactivated: no distinction between the two; the response BODY is byte-identical for both and echoes no user id). **Nebu choices (the spec is
  silent on unknown, deactivated and foreign invitees), labelled as such in the docs:** 403 / 404 are spec-shaped (`/invite` 403 list; createRoom 403
  "not allowed"); `M_USER_DEACTIVATED` is NOT used (it describes the caller's own account) and `M_USER_NOT_FOUND` is NEVER emitted (it is an
  Element-internal code, not a spec errcode); an unknown user is never `M_FORBIDDEN`; `M_NOT_FOUND` is what Element's `MultiInviter` maps to "user not found" (an `M_FORBIDDEN` would read "no permission" and abort
  the rest of an Element invite batch). Enumeration: not new (`GET /profile` and the user directory already tell existing users apart); on
  `POST /invite` the existence read runs AFTER the inviter's own checks, so a non-member learns nothing. NEVER provision a `users` row for an
  invitee (the creator-provisioning rule of `do_create_room/3` stays: only the caller's own id). The read lives in `Nebu.Matrix.Room.DB`
  (ADR-018, `invitable_local_users/1`: `SELECT user_id FROM users WHERE user_id = ANY($1) AND is_active`, one query for a whole
  `createRoom` list) behind `rooms_db_module()`. **Normative contract (the acceptance tests pin it in their fakes):**
  `rooms_db_module().invitable_local_users(user_ids) :: {:ok, [user_id]} | {:error, term}`: the SUBSET of `user_ids` that are existing ACTIVE local
  accounts, in any order; an id that is missing from the answer is unknown or deactivated (the core cannot and must not tell them apart); exactly ONE
  call per request (`createRoom`: the de-duplicated list; `POST /invite`: `[invitee]`); `{:error, _}` is a `500` (fail closed). **Normative message
  texts** (pinned verbatim by the acceptance tests, fixed, no client value in them): foreign `403 M_FORBIDDEN` "Users of other servers cannot be
  invited: this server does not federate"; unknown / deactivated `404 M_NOT_FOUND` "The user to invite does not exist on this server"; 3pid `403
  M_THREEPID_DENIED` "Third-party invites are not supported on this server"; creator in `invite` `400 M_INVALID_PARAM` "invite must not contain the
  room creator"; a refused join "You are not invited to this room" (presets story).
- **D4 (`POST /rooms/{roomId}/invite` body).** Not JSON -> `400 M_NOT_JSON`; JSON but not an object -> `400 M_BAD_JSON`. **A present
  `user_id` (not `null`) always selects the user-id form**, whatever 3pid keys are also present (they are ignored; Oracle gate). `user_id` absent /
  `null`: if NONE of `medium`, `address`, `id_server`, `id_access_token` is present -> `400 M_MISSING_PARAM`; if SOME but not all four are present, or
  one of them is not a string -> `400 M_BAD_JSON` (a malformed 3pid body); all four present as strings (the well-shaped 3pid form) -> **`403
  M_THREEPID_DENIED`** "Third-party invites are not supported on this server" (D6). Then D3 shape for `user_id` (`M_BAD_JSON` / `M_INVALID_PARAM`). These body checks run BEFORE
  the room checks (they reveal nothing about the room). The room / inviter checks follow unchanged, then D3 domain + existence, then D1. Fixed
  texts, no client value in a message or log.
- **D5 (`createRoom` `invite` validation, before the room exists).** **Nebu policy (labelled in the docs): the cap, the 400 for the creator's own
  id (strict v10 invite auth would answer 403 "already joined" once the room exists; Nebu refuses it as a request error before any room), the silent
  de-duplication and the all-or-nothing rule; the spec defines none of them.** `invite` absent / `null` / `[]` -> no invites. A non-list -> `400 M_BAD_JSON`;
  an element that is not a string -> `400 M_BAD_JSON`; more than **50** entries (counted RAW, before de-duplication) -> `400 M_INVALID_PARAM`
  (**Nebu policy**, the spec has no limit: bounds one createRoom, which has no rate limit yet (`ey`), to 50 eligibility reads + 50 x (row + signed
  event); Element sends 1 for a DM and the picked users for a group DM); a malformed user id -> `400 M_INVALID_PARAM`; the CREATOR's own id ->
  `400 M_INVALID_PARAM` "invite must not contain the room creator" (Element never sends it; a member holds no invitation, D1 of the presets
  story); duplicates are dropped silently, first occurrence wins, list order kept (Nebu policy); a foreign-domain id ->
  `403 M_FORBIDDEN` (D3); an unknown / deactivated local id -> `404 M_NOT_FOUND` (D3). All-or-nothing: one ineligible entry refuses the whole
  request and NO room is created.
- **D6 (`invite_3pid`).** Nebu has no identity server and no 3pid invites (`m.room.third_party_invite` is already a skipped `initial_state` type).
  `invite_3pid` absent / `null` / `[]` -> ok (Element's group DM always sends `[]`); a non-list -> `400 M_BAD_JSON`; a list with an item that is not
  an object, or an object missing one of the four REQUIRED keys (`id_server`, `id_access_token`, `medium`, `address`) or holding a non-string value
  for one of them -> `400 M_BAD_JSON` (malformed, Oracle gate correction: checked over the whole list first); a list of only well-shaped items ->
  **`403 M_THREEPID_DENIED`** "Third-party invites are not supported on this server", no room (the entries are never forwarded anywhere). Not ignored: silently dropping a 3pid
  invite would create a DM room without the partner. Same answer for the 3pid form of `POST /invite` (D4).
- **D7 (`is_direct`).** The router answers a PRESENT `is_direct` that is neither a boolean nor `null` with `400 M_BAD_JSON` (like `topic: null`, the
  router is the only place that sees the raw value; `Core.CreateRoomRequest.is_direct` stays a boolean). `true` sets `"is_direct": true` on the
  createRoom invite events (D2); without invitees it has no effect. The `room_created` audit metadata (`is_direct`, `alias`) is unchanged.
- **D8 (step 8 placement, timestamps, failure).** Invites run in `do_create_room/3` after the derived canonical alias (the last event of steps 4-7),
  in list order, each invite member event stamped strictly after the previous event of the chain (`register_canonical_alias/4` must return the
  timestamp it used, or the chain is threaded through it; without a name / topic / alias the chain continues from the last `initial_state` / preset
  event). The inviter is the creator (member, PL from step 3). Every invite (row + event) is **FATAL** on failure (`500`, orphan cleanup): the
  request was fully validated before the room existed, a failure is a store error, and a DM without its partner is useless (the spec's partial
  success is the invite-blocking case Nebu does not have). `Room.DB.delete_room/1` deletes the room's `room_invitations` rows first (same
  transaction), so the cleanup works for a room that already holds invitations (unit + real-DB test). The `{:new_invite}` broadcasts happen per
  invite as on `POST /invite` (a broadcast for a room that is then cleaned up only wakes a sync that finds nothing).
- **D9 (`trusted_private_chat` invitee power level, spec-normative, step 3).** With `preset` (effective, D2 of the presets story) =
  `trusted_private_chat` and a non-empty validated invite list, the generated content BEFORE the override is the default levels with
  `users[creator] = 100` AND `users[invitee] = 100` for every invitee (the creator's level); then `power_level_content_override` is merged on
  top, shallow (Synapse parity: an override `users` map REPLACES the generated map including the invitees; documented). One `m.room.power_levels`
  event as today. `private_chat` / `public_chat` / no invitees: unchanged. Room v12 `additional_creators`: not applicable (v10). **Consequences
  (evaluated, documented, accepted as spec):** in a DM both users are at 100, so (a) under the room v10 rule "caller level strictly greater than the
  target's" (`require_higher_power_level!/3`, presets story review cycle 1) neither can kick, ban or unban the other: kick / ban / unban have NO HTTP
  route today (internal only, scope doc), so nothing is lost now; when the routes come (`ex` gate) DM partners stay equal; (b) the partner can
  change every state event (`state_default` 50) and invite others (`invite` 0), as the creator can; (c) power levels cannot be changed after
  creation (`eq`), so the equality is permanent; (d) an invitee who never joins keeps the `users` entry (harmless; it is only effective once
  they join with an invitation); (e) Element's group DM uses `private_chat` (no equal levels); (f) **the creator cannot revoke a PENDING invitation of a `trusted_private_chat`
  invitee** (Oracle gate: v10 revoke = kick of the invitee, needs a level strictly greater than the target's; the invitee is already at 100 before
  joining): there is no revoke path today anyway (`kick_user/2` requires a member, `fb`), and a future revoke must refuse it in this case (recorded in
  `fb`). The creator lock-out planner (D10) is not affected
  (the creator's own level does not change).
- **D10 (creator lock-out includes the invites).** v10 invite auth: the sender's level must reach `invite`. With a non-empty invite list the
  pure planner of `check_creator_lock_out/5` also requires `creator_level >= merged["invite"]` (integer, else 0, the same default as
  `PowerLevels.can?/3`) -> else `400 M_INVALID_ROOM_STATE`, no room (example: `power_level_content_override: {"invite": 101}` with an `invite` list;
  the same override without `invite` stays 200, it only restricts later invites). The runtime check of the shared path (D1, `can?/3 :invite`)
  then cannot fail for a validated request.
- **D11 (interim `/sync` guard, until `ev`).** In `do_incremental_sync/4` a room that is in the set ONLY because of a pending invitation (in
  `get_pending_invite_rooms_for_user/1`, not in `get_rooms_for_user/1`, not in the declined or left lists) stays subscribed (`:pg`, so the
  `{:new_invite}` / decline wake-ups keep working) but is NOT passed to `fetch_delta_rooms/3`, so it never appears in `rooms.join` before the
  invitee joined. Why here: every createRoom invite makes the whole history of a brand-new room "newer than the invitee's anchor"; without the
  guard the invitee's next incremental sync would ship the DM (state, timeline, later messages) in `rooms.join`, Element would show it as a
  JOINED room the invitee cannot write to (`PUT /send` 403) and has no Accept for. With the guard the invitee sees nothing until `ev` (the
  documented state: join with `/join <room id>`), and after the join the room arrives through the joined list as today (`{:new_join}` path). Not
  more: declined and left rooms keep today's (defective) delivery, that is `ez`, fixed with `ev`. Initial sync is unchanged (joined rooms only).
- **D12 (unchanged paths).** `admin_add_room_member/3` (row + immediate join, no invite event), `upgrade_room` (row-only invites of the old
  members, warnings on failure), auto-join, `create_personal_room/2`, `Nebu.Matrix.create_room/2` and `create_space/2` (no `invite` key: the new
  struct keys default to `nil` = no invites) are not changed. Row-only invitations (upgrade, and every invitation created before this story) have
  no invite member event; they stay joinable (the join decision reads the row) and `ev` must cope with them (a synthesized stripped member event
  from the row, noted in `ev`). No audit row for invitations (the signed invite event is the record; whether invites get an audit action like
  `room_joined` is an owner decision, `fa`).
- **D13 (errcode mapping).** `Nebu.Matrix.Http.map_error/1` honours errcode + message of a `not_found` `Nebu.Matrix.Error` only when the error carries
  an explicit `errcode` (opt-in, like `permission_denied` since the presets story); every existing `not_found` keeps "Room not found".
  `M_THREEPID_DENIED` / `M_FORBIDDEN` use the existing `permission_denied` opt-in, `M_MISSING_PARAM` / `M_BAD_JSON` / `M_INVALID_PARAM` the
  `invalid_argument` opt-in. The two Admin wrappers that return `{:error, e.message}` are not on these paths.
- **D14 (where the checks live, order).** Router: passes `params["invite"]` and `params["invite_3pid"]` RAW in `Core.CreateRoomRequest` (new keys
  `invite: nil`, `invite_3pid: nil`; hand-edit comment of `lib/pb/core.pb.ex` extended; `proto/core.proto` comment parity) and decides `is_direct`
  (D7) next to the `topic: null` check. Core `validate_create_room_request/1`, first failure wins: name -> topic -> creation_content -> room_version
  -> room_alias_name -> initial_state aliases -> preset / visibility -> override shape -> **`invite` shape (D5: type, cap, syntax, creator,
  de-duplication)** -> **`invite_3pid` (D6)** -> **invitee domains (D3, pure, 403)** -> creator lock-out (D7 of the presets story + **D10**) ->
  alias-taken read -> **invitee existence read (D3, the last DB read, 404)**. Example for a test: a malformed invitee together with a taken alias
  answers `M_INVALID_PARAM`; a foreign invitee together with an `{"invite": 101}` override answers `403 M_FORBIDDEN`.

## Out of scope -> follow-ups (to be added to `follow-ups.md` by this story; the id line says "unused: ... `ez` onward" and a grep of the file finds no `ez` / `fa` / `fb` row: the new ids are `ez`, `fa`, `fb`)

- **`ez` — SECURITY (HIGH, release gate together with `ev`): the incremental `/sync` serves rooms the user is not joined to in `rooms.join`.**
  `do_incremental_sync/4` adds ALL declined invitations (`get_declined_invite_rooms_for_user/1`) and ALL left rooms (`get_recently_left_rooms_for_user/1`
  = `left_at IS NOT NULL`, no time bound) to the fetched set, and `fetch_delta_rooms/3` ships every one with new events into `rooms.join` with full
  state and timeline: a user who left, was kicked, banned or removed by an Admin, and a user who declined an invitation, keeps receiving every new
  event (message content included) until they forget the room; an invitee received the room before joining (closed for pending-invite-only rooms
  by the interim guard D11 of story create-room-invites-direct; a re-invited former member is still in the left list). Pinned today by
  `forget_room_membership_purge_test.exs` AC4 ("a left room re-surfaces in rooms.join"). Fix with `ev` in ONE story: `rooms.leave` with a timeline
  bounded at the leave / kick / ban event, nothing after it, invites only in `rooms.invite`. Compliance relevance: data minimisation and access
  after removal.
- **`fa` — invite API leftovers.** (a) `reason` (spec v1.1) is not read on `POST /invite` and not written on the invite event (known deviation, D2: a request with `reason` is a 200); (b) invite permission
  (v1.18 `m.invite_permission_config`, `M_INVITE_BLOCKED`: a server MUST answer 403 `M_INVITE_BLOCKED` for a user who blocks invites; Nebu ignores
  the setting today, a spec gap) and ignored users (`m.ignored_user_list`: "Servers must not send room invites from
  ignored users to clients", the sync side belongs to `ev`) are not implemented; (c) owner decision: an audit row for invitations (joins are
  audited as `room_joined`, invitations only through the signed invite event); (d) the invite event carries no `displayname` / `avatar_url` of the
  invitee (Synapse adds them; Element falls back to the user id).
- **`fb` — membership state model.** `build_state_events/3` (and so the `/sync` state, `/members`, `/initialSync`) lists only JOINED members
  (synthesized from the room process), so an invite / leave / ban member event is visible only while it is in a timeline window; room upgrade
  writes row-only invitations (no invite member event; D12); a kick of a PENDING invitee (spec: a kick revokes an invitation) is not possible
  (`kick_user/2` requires a member); when a revoke is added it must apply the "strictly greater level" rule, so the creator of a
  `trusted_private_chat` room can NOT revoke the pending invitation of an invitee at the creator's level (D9 (f)).
- **Notes to existing rows:** `eb` -> CLOSED (one line: what changed, incl. the decisions D3 / D5 / D6 / D9 / D11); `ev` (the invite section must
  include the invitee's invite member event with `is_direct` (Element reads it through `getDMInviter`), `m.room.create` is required (v1.16), row-only
  invitations without an invite event get a synthesized stripped member event, the interim guard D11 is replaced, ignored users' invites are
  suppressed, `M_INVITE_BLOCKED` / `m.invite_permission_config` is `fa` (b), the Element UI DM scenario of this story tagged `@pending-feature` is its e2e acceptance, ships with `ez`); `ey` (a createRoom can now
  issue up to 50 invitations without a rate limit: invite spam vector, include createRoom invites in the tier); `eq` (in `trusted_private_chat` DMs
  both users are at 100; the PL change rules matter there when `eq` adds a route).

## Acceptance Criteria

1. **Element DM request works server-side (HTTP, real stack, users A = creator, B = partner).** Element's exact DM body (`preset:
   "trusted_private_chat"`, `visibility: "private"`, `invite: [B]`, `is_direct: true`, `initial_state` guest_access `can_join` + history_visibility
   `invited` + `m.room.encryption`) -> `200`; B holds a pending invitation (`InviteDB.pending_invite?/2` true); the room has exactly ONE
   `m.room.member` event with `state_key` B: `sender` A, content exactly `{"membership": "invite", "is_direct": true}`; B `POST /join/{id}` -> `200`,
   B is a member, the invitation is accepted, the room's latest membership of B is `join`; A and B can both send `m.room.message` (200) and read
   each other's messages through `/messages`; A's incremental `/sync` timeline contains the invite event; `get_room_heroes` for A: `joined 1,
   invited 1` before B's join. The join rule is still `invite` (a third user C without invitation -> `403`).
2. **Group DM / private room with several invitees.** `invite: [B, C]`, `invite_3pid: []`, `preset: "private_chat"`, no `is_direct` -> `200`; B and C
   each have a pending invitation and an invite event with content exactly `{"membership": "invite"}` (no `is_direct` key); `invite: [B, B, C, B]`
   -> exactly one invitation and ONE invite event per user, in first-occurrence order; `invite: []` / `null` / absent -> no invitation, no invite
   event; `is_direct: true` without `invite` -> 200, no invite event.
3. **`invite` validation (D5, no room in every 4xx case: the creator's room count and the `rooms` row count are unchanged).** `invite: "@b:<srv>"`,
   `{}`, `5` -> `400 M_BAD_JSON`; `[5]`, `[null]`, `[["@b:<srv>"]]` -> `400 M_BAD_JSON`; 51 distinct valid local ids -> `400 M_INVALID_PARAM`
   (50 -> 200 against 50 provisioned users, or unit with a fake reader); 51 entries that are 51 times the same id -> `400 M_INVALID_PARAM` (raw
   count); `["bob"]`, `["@Bob:<srv>"]`, `["@b"]`, `[""]` -> `400 M_INVALID_PARAM`; `[A]` (the creator) -> `400 M_INVALID_PARAM`;
   `["@b:other.example"]` -> `403 M_FORBIDDEN`; a well-formed local id without a `users` row -> `404 M_NOT_FOUND`; a deactivated local user
   (`is_active = false`) -> `404 M_NOT_FOUND` with a BYTE-IDENTICAL body to the unknown one (no user id echoed; the errcode is `M_NOT_FOUND`,
   never `M_FORBIDDEN`, `M_USER_NOT_FOUND` or `M_USER_DEACTIVATED`); two different foreign ids -> byte-identical `403 M_FORBIDDEN` bodies, no user id echoed; `[B, "@x:other.example"]` -> `403`, no room, B has NO
   invitation (all-or-nothing). Messages are fixed text (no client value).
4. **`invite_3pid` (D6).** `[]`, `null`, absent -> 200; `"x"`, `{}`, `5` -> `400 M_BAD_JSON`; `[5]`, `[null]`, `[{"medium": "email"}]`,
   `[{"id_server": "matrix.org", "medium": "email", "address": "a@b.c"}]` (no `id_access_token`), `[{"id_server": 5, "id_access_token": "t", "medium":
   "email", "address": "a@b.c"}]`, and a list of one well-shaped item plus `5` -> `400 M_BAD_JSON`; `[{"id_server": "matrix.org", "id_access_token":
   "t", "medium": "email", "address": "a@b.c"}]` -> `403 M_THREEPID_DENIED`; no room in every non-200 case.
5. **`is_direct` (D7).** `true` / `false` / `null` / absent -> 200 (only `true` puts `is_direct` on the invite events); `"true"`, `1`, `{}` ->
   `400 M_BAD_JSON`, no room (router, HTTP test only).
6. **Order and timestamps (unit, FakeDB recording `insert_event`).** With `room_alias_name` absent, `name`, `topic`, `preset: trusted_private_chat`,
   `initial_state` entries and `invite: [B, C]`: event order `m.room.create` < creator member < `m.room.power_levels` < preset events <
   `initial_state` < `m.room.name` < `m.room.topic` < derived `m.room.canonical_alias` < invite B < invite C, every `origin_server_ts` from step 4 on
   strictly greater than its predecessor's (also with a frozen clock seam if one exists); without name / topic the invites follow the last
   `initial_state` / preset event. The order tests of the previous stories stay green.
7. **`trusted_private_chat` power levels (D9).** `preset: trusted_private_chat`, `invite: [B, C]` -> the room's `m.room.power_levels` `users` is
   exactly `{A: 100, B: 100, C: 100}` (one event, `rooms.power_levels_json` equal), every other key the default; `preset: private_chat` with the
   same invites -> `users` `{A: 100}`; `trusted_private_chat` + `power_level_content_override: {"users": {A: 100}}` -> `users` exactly `{A: 100}`
   (override wins, shallow); `+ {"events_default": 50}` -> `users` `{A: 100, B: 100, C: 100}` and `events_default` 50; `trusted_private_chat`
   without `invite` -> `{A: 100}`. After B joined: B can `PUT .../state/m.room.name` (200) and invite C2 (200). Unit (internal API, no HTTP route):
   `kick_user/2` and `ban_user/2` by A against the joined B -> `403 M_FORBIDDEN` (equal levels) and the same by B against A (pins the documented
   consequence); `kick_user/2` by A against B while B is still only INVITED -> refused (no revoke of a pending invitation of an equal-level invitee,
   D9 (f): today because `kick_user/2` requires a member; the test pins "refused and B's invitation stays pending", whatever the reason).
   `trusted_private_chat` + `power_level_content_override: {"users": {A: 100, "@x:<srv>": 50}}` + `invite: [B, C]` -> `users` exactly
   `{A: 100, "@x:<srv>": 50}` (the invitees are ABSENT: the override replaces the generated map), B and C are still invited, and the lock-out check
   still runs on the merged map (`{"users": {A: 0, "@x:<srv>": 50}}` + `invite: [B]` -> `400 M_INVALID_ROOM_STATE`).
8. **Creator lock-out includes invites (D10).** `power_level_content_override: {"invite": 101}` + `invite: [B]` -> `400 M_INVALID_ROOM_STATE`, no room;
   the same override without `invite` -> 200; `{"users": {A: 0}, "invite": 0}` + `invite` still refused by the existing state-event planner
   (preset events) with `M_INVALID_ROOM_STATE`; unit planner table: invite level 100 with creator 100 -> ok, 101 -> refused, non-integer
   `invite` cannot reach the planner (override shape is `M_BAD_JSON` first).
9. **First failure (D14).** malformed invitee + taken `room_alias_name` -> `400 M_INVALID_PARAM`; foreign invitee + `{"invite": 101}` -> `403 M_FORBIDDEN`;
   unknown local invitee + taken alias -> `400 M_ROOM_IN_USE` (the existence read is last); non-empty `invite_3pid` + malformed `invite` ->
   `400 M_INVALID_PARAM`; invalid `preset` + malformed invitee -> `400 M_INVALID_PARAM` from the preset check (message of the preset).
10. **Step 8 is fatal and the cleanup works (D8, unit + real DB).** A failing invite row write and (separately) a failing invite event write for the
    SECOND invitee -> `500`, the orphan room is cleaned up: no `rooms` row, no events, no members, no aliases AND no `room_invitations` row for the
    first invitee (real DB: `Room.DB.delete_room/1` on a room with an invitation row returns `:ok` and removes it); the log names only the room id,
    the event type and the error class.
11. **`POST /rooms/{roomId}/invite` (D1-D4, HTTP).** (a) A valid invite -> `200 {}`, a pending row AND one invite event (`sender` inviter, content
    exactly `{"membership": "invite"}`); (b) the same invite again while pending -> `200 {}`, no second event, the row's `invited_at` unchanged;
    after B declined (`POST /leave`) a new invite -> 200, a NEW invite event after the leave event, the row re-armed; (c) body not JSON ->
    `400 M_NOT_JSON`; `[]` / `"x"` -> `400 M_BAD_JSON`; `{}` -> `400 M_MISSING_PARAM`; `{"user_id": 5}` -> `400 M_BAD_JSON`; `{"user_id": "bob"}` ->
    `400 M_INVALID_PARAM`; `{"medium": "email", "address": "a@b.c", "id_server": "x", "id_access_token": "t"}` -> `403 M_THREEPID_DENIED`;
    (d) foreign user -> `403 M_FORBIDDEN`, unknown / deactivated local user -> `404 M_NOT_FOUND` (same body), none of them writes a row or an event;
    (e) order: a NON-member inviting an unknown user gets the inviter `403` ("You are not a member of this room"), not the 404 (no enumeration by
    non-members); an unknown room id stays `404 M_NOT_FOUND` "Room not found"; (f) the existing rules stay: member target 403, banned target 403, a
    failing membership read 500 (existing tests green); (g) a failing users-row read -> `500`, nothing written (unit); a failing invite event write
    after the row -> `500` and the row is rejected again (unit: `reject_invitation/2` called; the target's `POST /join` in an invite room -> 403);
    (h) Oracle gate tests: `{"user_id": B, "reason": "welcome"}` and `{"user_id": B, "reason": 5}` -> `200`, the invite event content exactly
    `{"membership": "invite"}` (known deviation D2); `{"user_id": B, "medium": "email", "address": "a@b.c", "id_server": "x", "id_access_token": "t"}`
    -> `200`, the user-id form (B invited); `{"medium": "email"}` and `{"medium": "email", "address": "a@b.c"}` -> `400 M_BAD_JSON`;
    `{"medium": "email", "address": 5, "id_server": "x", "id_access_token": "t"}` -> `400 M_BAD_JSON`; (i) an inviter below the invite level (room created
    with `power_level_content_override: {"invite": 50}`, a joined member at PL 0 invites C) -> `403 M_FORBIDDEN`, no row, no event; (j) re-invite after a
    VOLUNTARY leave of a former member (B joined, B `POST /leave`, A invites B) -> `200`, a NEW invite event after B's leave event, the row re-armed, B's
    `POST /join` -> 200; re-invite after a BAN (unit, internal `ban_user/2`) -> `403 M_FORBIDDEN`, no row, no event; (k) the invitee declines
    (`POST /rooms/{id}/leave` while invited) -> a leave event with `sender == state_key == B` after the invite event, the invitation rejected, then
    B `POST /join` in the invite room -> `403 M_FORBIDDEN` "You are not invited to this room"; (l) unknown-user responses are `M_NOT_FOUND`, never
    `M_FORBIDDEN` (Element's `MultiInviter` treats `M_FORBIDDEN` as fatal for the whole batch), byte-identical for unknown vs deactivated, no user id
    in the body; the foreign `403` body likewise echoes no user id.
12. **Interim `/sync` guard (D11).** Unit (`do_incremental_sync` through `get_sync_delta/2` with fakes): a room that is only in the pending-invite
    list and has events newer than the anchor is NOT in `response.rooms`, while a joined room with new events is; a room in both the pending and the
    left list is still delivered (today's behaviour, `ez`, pinned so the change stays narrow: the re-invited former member residual); the `{:new_invite}` wake-up test (`sync_test.exs`
    "wakes on {:new_invite, _}") stays green, and with `timeout_ms > 0` an incremental sync of a user whose only new room is a pending-invite room
    returns early on `{:new_invite, _}` with no rooms, and the NEXT incremental sync with the returned token (`timeout_ms` 200) waits for its timeout
    instead of returning at once (no hot loop through the guarded room; elapsed time asserted, generous bound). HTTP: A creates a DM with B; B's incremental `/sync` (with a `since` from before the create,
    `timeout=0`) has no `rooms.join.<dm>` and no `rooms.invite.<dm>` (`ev`); after B `POST /join` B's next incremental sync has `rooms.join.<dm>` with
    B's join event in the timeline. `forget_room_membership_purge_test.exs` stays green (setup pin only, AC4 unchanged).
13. **Unchanged paths (D12).** `Nebu.Matrix.create_room/2` and `create_space/2` (existing Admin tests green, no invitation, no invite event);
    `admin_add_room_member/3` (rm4 tests green; no invite event); `upgrade_room` (old members get row-only invitations as before, `upgrade_room_test.exs`
    green); auto-join; the personal room.
14. **Value-free logs.** Every new failure log (eligibility read, invite row / event write, cleanup of invitations, re-reject) names only the room id,
    the event type and `db_error_class/1`, never an invitee or inviter user id, never request content (CaptureLog test with a marker localpart in the
    invite list, as AC14 of the presets story).
15. **Element-shaped regression (HTTP).** The previous stories' Element private-room, public-room and Space-create request shapes still produce the
    same rooms (their tests green); a Space created with `invite: [B]` (Element's "invite people" at Space creation uses `POST /invite` later, but the
    createRoom path must work too) -> B invited into the Space room, Space type preserved.
16. **e2e (see "E2E verification"):** the new API-level scenario passes, the Element UI creator-side DM scenario passes, the invitee-side UI scenario
    is present and tagged `@pending-feature` (needs `ev`), the regression runs are green except the rows of `KNOWN-FAILURES.md`; logs saved and linked.
17. **Docs.** `docs/matrix-api-scope.md`: the createRoom row (read keys now include `invite`, `invite_3pid`, `is_direct`; D3, D5-D10, D14 with the
    Nebu-policy / Nebu-choice labels: cap 50, `404 M_NOT_FOUND` for unknown / deactivated, `403 M_FORBIDDEN` foreign, `403 M_THREEPID_DENIED`, creator
    in `invite` 400, de-duplication, all-or-nothing, fatal step 8, `trusted_private_chat` equal levels and the override precedence, `additional_creators`
    not applicable (v10); "Not read yet" no longer lists `eb`), the invite row (D1-D4, the invite member event, already-invited 200 no-op, the 3pid form incl. "user_id wins" and the
    malformed-3pid 400, the order of checks, the Nebu-choice labels of D3, and `reason` ignored as a **known deviation**), the `/sync` row (the interim guard D11; `rooms.invite` / `rooms.leave` still empty = `ev`; `ez`), the kick / ban rows (DM
    partners are at equal level: neither can kick or ban the other once the routes exist), the "Intentionally Excluded" identity line (3pid invites
    `403 M_THREEPID_DENIED`). `docs/architecture/07-deployment.md`: a behaviour-change paragraph for this story after the presets paragraph (what
    clients can see: DMs and private rooms invite their `invite` list, invite events now appear in the timeline, the new 4xx of createRoom and `/invite`
    incl. the former 500s, DM partners at power level 100, existing pending invitations have no invite event and are not backfilled) AND the release
    gate paragraph updated: `eb` is done; the gate is now `ev` + `ez` (no `rooms.invite`, so the INVITEE still does not see an invitation or a DM in
    Element and joins with `/join <room id>`; the creator side of a DM works; the left / declined room delivery defect `ez`); release-note point (3)
    rewritten accordingly. `docs/stories/oauth-broker/follow-ups.md`: `eb` closed, the notes on `ev`, `ey`, `eq`, new rows `ez`, `fa`, `fb`, the id
    line (`ez`-`fb`: create-room-invites-direct; unused from `fc` onward). `docs/architecture/06-runtime.md` Scenario 3b: one sentence that the
    described `buildLeaveRooms` is the Go design and is NOT ported (pointer to `ev` / `ez`).
18. **Regression.** Green and unchanged (except the DATA adaptations listed below): `create_room_input_validation_test.exs` / `_http_test.exs`, `create_room_initial_state_test.exs` / `_http_test.exs`,
    `create_room_canonical_alias_test.exs`, `create_room_test.exs`, `spaces_create_room_test.exs`, `spaces_restricted_join_integration_test.exs`,
    `create_room_presets_test.exs` / `_http_test.exs`, `join_room_test.exs`, `join_rules_test.exs`, `leave_room_test.exs`, `upgrade_room_test.exs`,
    `room_summary_integration_test.exs`, `forget_room_membership_purge_test.exs`, `sync_test.exs`, `matrix_room_routes_test.exs`,
    `matrix_client_compat_test.exs`, `matrix_mutual_rooms_test.exs`, `matrix_room_view_routes_test.exs`, `room_tags_test.exs`. DATA adaptations only
    (list them in the Change Log): fakes used by `invite_user/2` / `create_room` get `insert_event/1` (already in `invite_user_test.exs`), the
    eligibility reader and `reject_invitation/2`; tests that invite a user without a `users` row or with a foreign / malformed id and expected 200 or 500
    get a provisioned user or the new code; `create_room_presets_docs_test.exs` (it pins the `eb` row text, the id line "`ez` onward", the createRoom
    scope row naming `invite_3pid` + `eb` and the 07-deployment "DMs do not work" wording): its assertions move to the new texts (state which in the
    Change Log). `e2e/tests/features/dm/dm_create_bug_5_29e.spec.ts` (not in any Playwright project) uses the unrouted `POST /rooms/{id}/join`: switch
    to `POST /join/{roomId}` (static adaptation). **The DATA adaptations that exist (ATDD step):** (1) `Nebu.Test.ServerName.pin!/1`
    (`create_room_test_support.exs`, loaded by `test_helper.exs`) in the setup of the eight suites that invite through `POST /invite`
    (`create_room_input_validation_http_test`, `room_summary_integration_test`, `spaces_restricted_join_integration_test`,
    `forget_room_membership_purge_test` (setup only, AC4 untouched), `matrix_client_compat_test`, `matrix_mutual_rooms_test`,
    `matrix_room_view_routes_test`, `room_tags_test`): the invite path refuses foreign-domain invitees by `:event_dispatcher, :server_name`, which 28
    older suites DELETE on exit (the outcome would depend on the suite order); (2) `invitable_local_users/1` in the `join_room_test` fake and the
    extended fakes of `invite_user_test`; (3) the four assertions of `create_room_presets_docs_test.exs` (see Change Log); (4) the stale comments of
    `e2e/tests/features/messages/messages.spec.ts`, `e2e/tests/features/login/sso-login.spec.ts` (it invites `@marie:localhost` before marie's own
    login: marie exists because `global-setup.ts` warms alex / marie / kai first, now a hard precondition: an unknown invitee is a 404) and the name
    of one `create_room_presets_test.exs` test.

19. **Review cycle 1 (code review M1-M5 / Kassandra L-2, L-3, I-4).** (a) The compensation of a failed invite EVENT write is conditional (D1
    amended): `pending_invite?` and the latest membership are read BEFORE the row insert; the row is rejected again ONLY when this call created or
    re-armed it (a legacy pending row without an invite event, from `upgrade_room` or an older invitation, survives a failing event write: `500`,
    row still pending, invitee still joinable); a unique violation of the event insert (the event id is a content hash: an identical concurrent invite)
    while the latest membership is now `invite` is "already invited" (`200`, no reject, the winner's invitation stays valid); a failing reject is logged
    at ERROR with "half invitation remains" (room id and error class only) and retried once on `POST /invite` (unit: invite_user_test.exs; HTTP: the legacy-row trigger test).
    (b) D11 amended: an event in a pending-invite-only room does not end the invitee's long-poll (the wait continues with the original timer), so
    a message in a DM the invitee has not joined causes no empty sync and no token write per message (sync_test.exs). (c) An invitee id longer than
    255 bytes is `400 M_INVALID_PARAM` on both paths. (d) Docs only (no code): follow-ups `ev` (reworded: `eb` is closed; Kassandra L-4: defer the
    `{:new_invite}` wake-ups until step 8 succeeded), `ex` (Kassandra M-1: the invite writer can erase a concurrent ban's event order; the ban route is
    gated on serialising it), `ey` (now GATING together with `ev`, Kassandra M-2; L-1 note), `ez` (Kassandra I-3), 07-deployment ("a trusted DM is
    co-owned", `ey` in the gate paragraph), scope doc sync row.

## Acceptance Tests

- `server/test/nebu/matrix/event_dispatcher/create_room_invites_test.exs` (new, unit, `async: false`, seams as `create_room_presets_test.exs`):
  AC2 (de-duplication / order), AC3 (shape / cap / creator / foreign / unknown with a fake reader, all-or-nothing), AC4, AC6, AC7 (incl. the
  `kick_user/2` / `ban_user/2` equal-level pins), AC8 (planner table), AC9, AC10 (failing row / event write, cleanup calls), AC13 (Admin / Space
  wrappers through the unit seams), AC14.
- `server/test/nebu/matrix/create_room_invites_http_test.exs` (new, `@moduletag :integration`, real stack, helpers of `create_room_presets_http_test.exs`,
  random localparts, `:server_name` pinned to the users' domain for the run as in that file): AC1, AC2, AC3 (incl. the deactivated user: set
  `is_active = false` through `Nebu.Repo` in the test), AC4, AC5, AC7 (HTTP part), AC8, AC9, AC10 (real-DB `delete_room/1` with an invitation row),
  AC11, AC12 (HTTP part), AC15.
- `server/test/nebu/matrix/event_dispatcher/invite_user_test.exs` (extended): AC11 (b) (g) (i) (j: the ban case through internal `ban_user/2`), the D1
  order (already-invited no-op, the event after the row).
- `server/test/nebu/matrix/create_room_invites_http_test.exs` additionally covers the Oracle-gate list: AC3 byte-identical 404 / 403 bodies; AC4 the
  malformed `invite_3pid` items (`[5]`, `[{"medium":"email"}]`, missing / non-string required keys) vs the well-shaped 403; AC7 the pending-invite
  revoke pin and the override `users` map with `"@x:<srv>": 50`; AC11 (h) `reason` 200, `user_id` + 3pid keys = user-id form, partial 3pid bodies
  400, (i) inviter below the invite level, (j) re-invite after a voluntary leave, (k) decline (leave sender == state_key, then join 403), (l) errcode
  never `M_FORBIDDEN` for an unknown user.
- `server/test/nebu/matrix/event_dispatcher/sync_test.exs` (extended): AC12 unit part incl. the pending + left pin (`ez`) and the timeout > 0
  `{:new_invite}` wake-up without a hot loop.
- `server/test/nebu/matrix/create_room_invites_docs_test.exs` (new): AC17 (rows `eb` closed, `ez` / `fa` / `fb`, id line, scope rows, 07-deployment gate text).
- e2e: `e2e/features/element/dm/create-dm.feature` (new) + step definitions (see below).

## E2E verification (the run the siblings did, extended by DM scenarios)

New scenarios (`e2e/features/element/dm/create-dm.feature`, element-web project, step definitions in `e2e/step-definitions/element/dm.steps.ts`,
API helpers from `e2e/fixtures/dex-auth.ts`, users alex / marie of `e2e/fixtures/users.ts`):

1. `@dm-create-api @regression` "createRoom with Element's DM body invites the partner": alex sends exactly Element's DM body (AC1) for marie; marie's
   `m.room.member` in the room (read by alex through `GET /rooms/{id}/messages?dir=b`: `GET /rooms/{id}/state/...` is not routed) is
   `invite` with `is_direct: true`, sender alex; marie `POST /join/{roomId}` -> 200; alex sends a message, marie reads it via `/messages`.
2. `@dm-create-ui @regression @ui` "Starting a DM in Element Web invites the partner server-side": alex opens "Start chat", picks marie, sends a first
   message (Element's local-room flow); the test forges no server state and asserts server-side that the DM room exists, marie holds an invite
   with `is_direct: true` and the message is in the room, and that the room became ready without Element's 5 s fallback (the first message is sent
   within 5 s after the create, measured from the `/send` request; a soft assertion if the timing proves noisy: then record it in the Completion Notes).
3. `@pending-feature @needs-ev` "marie sees the DM invitation in Element and accepts it": RED scaffold for `ev` (invite tile in the room list,
   Accept -> joined DM marked as direct). Excluded by the default tag expression; it becomes the e2e acceptance of the `ev` story.

**The run (pass criterion).** Against an isolated throwaway stack (plain http, the commands and env of `scripts/e2e-ci.sh element` / `admin`:
compose with `--profile e2e`, Playwright container on the host network, `NEBU_ELEMENT_URL` / `NEBU_MATRIX_BASE` as in the script, a dedicated compose
project such as `nebu-oauth` as in the presets run, NEVER the shared dev compose project): (a) the full `element-web` project (default tag expression:
the 23 scenarios of the presets run + the two new DM scenarios; `room/join.feature` @ac8-join-room and `messages/receive.feature` are the
invitation regression checks); (b) the Admin subset `features/admin/{create_room,rooms,spaces,member_management,room_visibility,auto-join-rooms,archive_room}.feature`
(Admin create / force-add paths). All green except the rows of `e2e/KNOWN-FAILURES.md`. Logs:
`_bmad-output/nebu/epics/oauth-broker/step-results/create-room-invites-direct/e2e-run.log` and `e2e-admin-run.log`, linked in the Completion
Notes. If @ac8-join-room or `receive` turns red, it is a finding (do not change the scenario to hide it): record the cause; a red caused by the
invited room surfacing in `rooms.join` means D11 is incomplete.

## Tasks

- [x] `InviteDB` / `Room.DB`: `delete_room/1` deletes `room_invitations` of the room in its transaction (D8); the eligibility read
      (`invitable_local_users/1` or similar, D3, ADR-018 inline SQL, parameter-bound `ANY($1)`).
- [x] Shared invite helper (D1, D2): member / ban / already-invited (one membership read) -> row -> invite event -> broadcast; re-reject on a failed
      event write; value-free logs. `invite_user/2` = body / room / inviter checks + D3 + helper.
- [x] Router `POST /rooms/{roomId}/invite`: D4 body checks (`M_NOT_JSON`, `M_BAD_JSON`, `M_MISSING_PARAM`, 3pid form `M_THREEPID_DENIED`).
- [x] `Http.map_error/1`: opt-in errcode / message for `not_found` (D13).
- [x] Router `createRoom`: `is_direct` type check (D7); pass `invite`, `invite_3pid` raw; `Core.CreateRoomRequest` keys + hand-edit comment;
      `proto/core.proto` comment parity (D14).
- [x] `validate_create_room_request/1`: D5, D6, D3 domain, D10 planner, existence read last (D14 order); returns / exposes the de-duplicated list.
- [x] `do_create_room/3`: invitee levels at step 3 for `trusted_private_chat` (D9, `merged_power_levels` gets the invitees before the override);
      step 8 after the derived alias with the threaded timestamp (`register_canonical_alias/4` returns its ts) (D8); fatal.
- [x] `do_incremental_sync/4`: the interim guard D11 (subscribe all, fetch joined + declined + left only).
- [x] Remove the "follow-up eb" comments (`preset_events/1`, scope / docs) that this story makes stale.
- [ ] Tests (Acceptance Tests list), DATA adaptations of AC18 (incl. the new test helper `Nebu.Test.ServerName.pin!/1` in
      `server/test/nebu/matrix/event_dispatcher/create_room_test_support.exs`), the e2e scenarios + the legacy spec adaptation, the e2e run with logs.
- [x] Docs AC17 incl. follow-ups `ez`, `fa`, `fb`, the notes and the id line.

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/` only inside the `nebu-pipeline` run. **No migration** (no schema change: `room_invitations`,
  `users.is_active`, `events` exist; `delete_room/1` is a code change). ADR-018 (inline SQL in `Nebu.Matrix.Room.DB` / `InviteDB`), ADR-020 (no
  cross-domain call; `Nebu.Matrix.active?/1` is the public read for OTHER domains, inside `Nebu.Matrix` use the `Room.DB` read behind the seam),
  ADR-021 (plain modules), ADR-011 (`m.room.encryption` stays skipped, Element's encrypted DM falls back to its 5 s timeout: unchanged).
- **Files and current state (read before editing):**
  - `server/lib/nebu/matrix/event_dispatcher/server.ex`: `create_room/2` ~l.224-288 (validation first, rescue + `cleanup_orphan_room/1` ~l.304);
    `do_create_room/3` ~l.331-525 (PL step 3 ~l.419-420 `merged_power_levels/2`, presets ~l.451-453, `apply_initial_state/4` ~l.455, name / topic
    ~l.459-482, derived alias ~l.493-494 (return value discarded today), room_type / visibility / audit ~l.500-522); `emit_preset_events/5` ~l.529;
    `register_canonical_alias/4` ~l.641; `create_audit_metadata/2` ~l.587; constants ~l.760-776; `validate_create_room_request/1` ~l.799-826 and helpers
    (`reject!/2` ~l.839, override validation ~l.1012-1065, `merged_power_levels/2` ~l.1069, `check_creator_lock_out/5` ~l.1085, `planned_state_types/4`
    ~l.1118); `join_room/2` ~l.1498, `authorize_join!/2` ~l.1588; `admin_add_room_member/3` ~l.1928 and `local_domain?/1` ~l.2043; `leave_room/2` ~l.2090;
    `invite_user/2` ~l.2332-2395, `invite_target_banned?/2` ~l.2397; `summary_membership/4` ~l.3468; `get_initial_sync/2` ~l.3800;
    `do_incremental_sync/4` ~l.4026-4173, `fetch_delta_rooms/3` ~l.4178; `build_state_events/3` ~l.4323; `get_room_heroes` use ~l.4548; `kick_user/2`
    ~l.4995, `ban_user/2` ~l.5084, `require_higher_power_level!/3` ~l.5165; `upgrade_room` invites ~l.6098; `emit_state_event_at/6` ~l.6488.
  - `server/lib/nebu/matrix/room/invite_db.ex` (re-arm insert, pending / accept / reject / declined reads), `server/lib/nebu/matrix/room/db.ex`
    (`delete_room/1` ~l.251, `get_rooms_for_user/1` ~l.303, `get_recently_left_rooms_for_user/1` ~l.326, `get_room_heroes/2` ~l.882,
    `get_generic_state_events/1` ~l.1388, `get_member_membership/2` ~l.1522-1544), `server/lib/nebu/matrix/room/power_level.ex` (`can?/3`, do not
    change semantics), `server/lib/nebu/matrix/user_id.ex` (`valid?/1`, lowercase localparts), `server/lib/nebu/matrix/http.ex` (`map_error/1`).
  - `server/lib/nebu/web/router/protected.ex`: createRoom ~l.1219-1313, invite ~l.1332-1347, `/sync` `do_sync/1` ~l.85-179 (no change: the guard is in
    the core); `server/lib/pb/core.pb.ex` l.41-62; `proto/core.proto` l.238-262; `server/lib/nebu/matrix.ex` `create_space/2` ~l.476, `create_room/2` ~l.712.
- **Must be preserved:** everything of the three sibling stories (validation before any room, errcode convention: wrong type `M_BAD_JSON`, wrong
  value `M_INVALID_PARAM`; one timestamp chain; skipped `initial_state` types incl. `m.room.member` and `m.room.third_party_invite`; join decision and
  its texts; `InviteDB` re-arm; the inviter-first order of `invite_user/2`; value-free logs; the creator-only provisioning); the `{:new_invite}` wake-up;
  heroes / member counts; Element's Space-child and private / public room flows; Admin, Space, upgrade, auto-join and personal-room paths.
- **Security (Kassandra will check):** no path provisions a `users` row for an invitee; no foreign / unknown / deactivated / banned / joined target gets a
  row or an event; the 3pid input is refused, never forwarded anywhere; the eligibility read on `POST /invite` comes after the inviter's checks; fail
  closed on every read (users row, membership, pending invite); all-or-nothing createRoom (no room for a refused list) and fatal step 8 with a cleanup
  that also removes invitation rows; the `trusted_private_chat` levels go only to validated invitees and lose against an explicit override `users`
  map; the invite count is capped; the interim guard D11 removes, and does not add, delivery; no client value in messages or logs; no information leak
  beyond the documented 403 / 404 distinction (foreign vs unknown) which `GET /profile` already exposes. Residuals to name in the review: `ez` (left /
  declined rooms still receive new events; a re-invited former member sees the room in `rooms.join`), `ev` (invitee does not see the invitation),
  `ey` (no rate limit: up to 50 invites per createRoom), `eq` (DM partners at equal level, permanent), `fa` (no invite blocking / ignored users).
- **Unit seams:** `:messages_db_module` (`insert_event/1`, `get_generic_state_events/1`), `:rooms_db_module` (`get_member_membership/2`,
  `delete_room/1`, the new eligibility read, `get_rooms_for_user/1`, `get_recently_left_rooms_for_user/1`), `:invite_db_module`
  (`insert_invitation/3`, `pending_invite?/2` / `get_pending_invite_rooms_for_user/1`, `reject_invitation/2`, `get_declined_invite_rooms_for_user/1`),
  `:audit_writer_module`, `:room_supervisor_module`; reset in `on_exit`. Fakes that lack the new eligibility read: implement it in the fakes
  (preferred); a guarded call (`Code.ensure_loaded?` + `function_exported?`) must never turn a real read failure or a missing real function into
  "eligible". `server_name` from `Application.get_env(:event_dispatcher, :server_name)`; never hard-code domains in expectations.
- **HTTP tests:** users are provisioned through the helpers of `create_room_presets_http_test.exs` (a `users` row is now REQUIRED for every invitee);
  random localparts; the foreign id uses a domain that is certainly not the pinned server name.
- **Element facts:** see the premise tables (bundle module names given there for re-checks).
- References: `docs/stories/oauth-broker/create-room-presets-power-levels-topic.md` (D1, D2, D3, D7, review cycles), `create-room-input-validation.md`
  (D6 errcode mapping, D7 order), `create-room-initial-state-conformance.md` (D2 skipped types), `_bmad-output/nebu/epics/oauth-broker/step-results/*/oracle-context.md`
  (spec order, step 8), `docs/stories/oauth-broker/follow-ups.md` rows `eb`, `ev`, `ex`, `ey`, `eq`, `et`, `es`, `docs/matrix-api-scope.md` (createRoom l.62,
  invite l.66, kick / ban l.67-69, sync l.56, Intentionally Excluded l.300-306), `docs/architecture/07-deployment.md` (l.270-280 release gate), spec
  `client-server-api/api.json` (`/createRoom`), `client-server-api/index.html` (POST `/rooms/{roomId}/invite`, Direct Messaging, Stripped state, `m.room.member`).

## Dev Agent Record

### Agent Model Used

Claude (Sonnet 5.5), dev step of the nebu-pipeline.

### Debug Log

- The unit assertion helper `assert_rejected/4` of `create_room_invites_test.exs` compared `invite_calls() == []` absolutely, but the AC8 planner-table
  test creates an accepted room (with invitation calls) BEFORE it asserts a rejection: it could never pass. Changed to a relative comparison
  (`calls_before`), identical for every other test (no weakening).
- `room_summary_integration_test.exs` "invite -> ban in a public room": an invite now writes an invite member event, and an immediate ban can tie
  with it in the same millisecond (follow-up `eu`, no tie-break), roughly one run in three. The in-process ban helper now waits for the next
  millisecond (same pattern as the `tick/0` of the sibling suites). No lib change.

### Completion Notes List

- Implementation (all in `server/lib`): `Nebu.Matrix.EventDispatcher.Server` (`do_invite!/5` shared path, `invite_user/2`, `invite_body_user_id/1`,
  `validate_invite_list/2`, `validate_invite_3pid/1`, `ensure_local_invitee!/1`, `ensure_invitees_exist!/1`, `emit_invites/5`, D9 invitee levels in
  `merged_power_levels/3`, D10 in `check_creator_lock_out/6`, `register_canonical_alias/4` returns its chain timestamp, D11 guard in
  `do_incremental_sync/4`), `Nebu.Matrix.Room.DB` (`invitable_local_users/1`, `delete_room/1` deletes `room_invitations`), `Nebu.Matrix.Http.map_error/1`
  (opt-in errcode for `not_found`), the router (`createRoom` `is_direct` check + raw `invite` / `invite_3pid`, `POST /invite` body checks),
  `Core.CreateRoomRequest` keys + `proto/core.proto` comment.
- The route body checks live in the core (`invite_body_user_id/1`, called from the router inside `call_core/1`) so the fixed texts exist once; the
  user-id SHAPE check (`M_BAD_JSON` / `M_INVALID_PARAM`) runs again at the top of `invite_user/2`, before the room lookup, so direct callers get it too.
- Eligibility on `POST /invite` runs after the inviter's checks (D3); on createRoom it is the last validation read (D14). The domain check uses
  the existing `local_domain?/1` (`:event_dispatcher, :server_name`, default "localhost"), createRoom's alias code keeps its own default "nebu.local":
  production always configures the name (`NEBU_SERVER_NAME`), the tests pin it.
- e2e UI scenarios: first real run pending (see below). The e2e run itself is done by the pipeline orchestrator.

- **e2e UI scenarios: first real run pending.** `e2e/features/element/dm/create-dm.feature` and `dm.steps.ts` were verified statically only (`npx bddgen`,
  `tsc --noEmit`); the Element 1.12.15 selectors of the UI steps ("New conversation" menu, `.mx_InviteDialog_tile`, the "Go" button, the composer)
  have never been run against a stack. Expect to adapt them in the first real run (the scenario 2 assertions are server-side and do not depend on them).
  The 5 s fallback is asserted by the ABSENCE of Element's console warning `Assuming local room <id> is ready after hitting timeout` (verified in the
  1.12.15 bundle); the elapsed time between the createRoom and the first message request is a soft extra.

### File List

- Implementation: `server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/matrix/room/db.ex`, `server/lib/nebu/matrix/http.ex`,
  `server/lib/nebu/web/router/protected.ex`, `server/lib/pb/core.pb.ex`, `proto/core.proto`; docs: `docs/matrix-api-scope.md`,
  `docs/architecture/07-deployment.md`, `docs/architecture/06-runtime.md`, `docs/stories/oauth-broker/follow-ups.md`; tests adapted in the dev step:
  `create_room_invites_test.exs` (relative `invite_calls` comparison), `room_summary_integration_test.exs` (wait for the next millisecond before the ban).

- Tests (ATDD step): `server/test/nebu/matrix/event_dispatcher/create_room_invites_test.exs`, `server/test/nebu/matrix/create_room_invites_http_test.exs`,
  `server/test/nebu/matrix/create_room_invites_docs_test.exs` (new); `invite_user_test.exs`, `sync_test.exs`, `join_room_test.exs`,
  `create_room_test_support.exs` (adds `Nebu.Test.ServerName`), `create_room_presets_docs_test.exs`, `create_room_presets_test.exs` (one name) and the
  eight suites with the `ServerName.pin!/1` line (AC18); `e2e/features/element/dm/create-dm.feature`, `e2e/step-definitions/element/dm.steps.ts`,
  `e2e/tests/features/dm/dm_create_bug_5_29e.spec.ts`, `messages.spec.ts`, `sso-login.spec.ts` (comments).

### Change Log

- 2026-10-16: story created (create-story; premises of `eb` verified in the code of HEAD `1af141f4` and in the Element Web 1.12.15 bundle copied from the
  stopped `nebu-oauth-dev-element-1` container; the dev server container was stopped, so no `bin/nebu rpc` probe; new finding `ez` (incremental `/sync`
  ships left / declined / invited rooms in `rooms.join`); decision: `ev` + `ez` are the next story and the release gate, this story adds only the
  interim guard D11; new follow-ups `ez`, `fa`, `fb`).
- 2026-10-16: amended with the Oracle gate (`step-results/create-room-invites-direct/oracle-context.md`; verdicts D1-D5, D7-D14 OK, D6 corrected):
  D6 malformed `invite_3pid` items (non-object, missing or non-string required key) are `400 M_BAD_JSON`, `403 M_THREEPID_DENIED` only for a list of
  well-shaped items, `[]` accepted; D4 a present `user_id` selects the user-id form even with 3pid keys, a partial / non-string 3pid body is
  `400 M_BAD_JSON`, `M_MISSING_PARAM` only without any 3pid key; D3 the unknown / deactivated / foreign answers labelled Nebu choices (byte-identical
  bodies, no user id, never `M_USER_NOT_FOUND` / `M_USER_DEACTIVATED`, never `M_FORBIDDEN` for an unknown user); D5 cap, creator 400,
  de-duplication and all-or-nothing labelled Nebu policy (the unverified "Synapse also de-duplicates" removed); D2 `reason` ignored = known
  deviation (a request with `reason` is a 200, scope doc label); D9 consequence (f): the creator cannot revoke a pending invitation of a
  `trusted_private_chat` invitee (AC7 pin, `fb`); `fa` (b) records the v1.18 `M_INVITE_BLOCKED` MUST. Every missing test of the Oracle list added to
  AC3, AC4, AC7, AC11 (h)-(l), AC12 and the Acceptance Tests. Follow-up ids `ez` / `fa` / `fb` unchanged.
- 2026-10-16: ATDD step + test review: tests written (unit 64, HTTP, docs, e2e). Change Log entries of this step: (a) `create_room_presets_docs_test.exs`
  assertions moved to the new texts: the `eb` row (now CLOSED; the old note "DMs are invite-only" is dropped), the id line (`ez` onward -> `fc` onward),
  the createRoom scope row (no longer names `eb` as a gap), the 07-deployment release note "DMs do not work until eb" (rewritten; pinned in
  `create_room_invites_docs_test.exs`); (b) the unit `FakeDB.delete_room/1` models D8 (deletes invitation rows): that is documentation only, the real-DB tests
  of `create_room_invites_http_test.exs` (AC10: invitation row, accepted / rejected rows, alias, Space, privileged triggers) are the proof; (c) amendments
  from the test review: AC18 wording (adapted suites named), `invitable_local_users/1` and the message texts made normative (D3), `Nebu.Test.ServerName.pin!/1`
  in the Tasks / File List, the stale comments fixed.
- 2026-10-16: dev step: implementation, docs AC17 (scope rows, 07-deployment paragraph + RELEASE GATE, follow-ups `eb` closed / `ez` `fa` `fb` new /
  notes on `ev` `ey` `eq` / id line, 06-runtime Scenario 3b), two test data fixes (see Debug Log). Status `review`.
- 2026-10-16: review cycle 1 (code review 0 MAJOR / 5 MINOR, Kassandra CLEAN 2 MEDIUM / 4 LOW): AC19 added. Code: conditional compensation of a failed invite
  event (`handle_failed_invite_event!/4`: unique violation = already invited, reject only a row this call created / re-armed, ERROR + one retry),
  D11 long-poll no longer woken by events of pending-only rooms, 255-byte cap on invitee ids. Tests added first: 6 in `invite_user_test.exs`, 1 in
  `create_room_invites_test.exs`, 1 in `sync_test.exs`, 1 in `create_room_invites_http_test.exs`; the `ev` pin of `create_room_presets_docs_test.exs`
  now reads "create-room-invites-direct" instead of the substring "eb". Docs as in AC19 (d). Not fixed here by decision: Kassandra M-1 (gate of the ban
  route, `ex`), M-2 (`ey`), L-4 (`ev`), I2 (`not_before: 0` on `POST /invite`, `eu` family).
