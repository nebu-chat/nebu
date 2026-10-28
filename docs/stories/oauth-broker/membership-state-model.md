---
story_id: membership-state-model
title: "Membership state model: the m.room.member slice of the initial /sync state, GET /rooms/{roomId}/members (membership / not_membership filters, at accepted) and /initialSync is read from the member EVENTS in the database (latest per user, the D3 tie order, invite / ban / leave / knock included, bounded), served with real event ids and unsigned (age, prev_content); upgrade_room writes real invite events through the room-process invite writer (is_direct carried); closes fb and fl (c), splits the Admin part of et into ge"
type: feature
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: true
ui: false
created: 2026-10-20
branch: feature/migrate-to-oauth2
---

# Story: membership state model (follow-ups `fb`, `fl` (c); the Admin part of `et` is split out to `ge`)

As a room member using Element Web, I want the member list to show who is invited ("Invited" section) and the room settings to show
who is banned ("Banned users", with the reason and who banned them) also after a reload, a new login or "Clear cache and reload", and
not only while the invite / ban event happens to be inside the last 20 timeline events.
As a member of an upgraded room, I want to receive a real invitation into the replacement room, so that Element shows who invited me
and marks a direct chat as direct again after I join.
As a Nebu operator, I want the member state to be read from the signed member events in the database (the same rule the `/sync`
partition and the join decision use), bounded per response, visible only to joined members, and never logged.

Follows `moderation-routes-atomic-ban` (the member writer `Room.Server.moderate/6`, `write_invite/5`, `write_decline/2`; its "Sizing
and split" proposed this story as story 2), `sync-membership-partition` (the D3 tie order, `latest_member_events/2`, the synthesized
`invite_state` of row-only invitations), `member-event-prev-content` (the batched predecessor lookup, `unsigned.prev_content`) and
`state-writer-redaction` (the room resolution `ensure_room_without_lazy_create!/2`, the fail-closed seam rule for a real db module,
the docs-suite re-pin discipline). Closes `fb` and part (c) of `fl`. **Split:** the Admin part of `et` (visibility toggle writing
`m.room.join_rules`, an Admin force-add of a banned user, banned users and an unban in the Admin UI, the Admin removal as a kick, `fg`
(f)) is NOT in this story; it is a separate pipeline run with owner decisions and an Admin UI (`ui: true`) gate: follow-up `ge`
records the binding design constraints (see "Sizing").

## Premises verified (2026-10-20, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `bac58977`, read-only)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise (from the request) | Verified text | Verdict |
|---|---|---|---|
| S1 | `GET /rooms/{roomId}/members` has `at`, `membership`, `not_membership`; 403 for non-members unless they left | `api.json` `/_matrix/client/v3/rooms/{roomId}/members` GET: `at` "The point in time (pagination token) to return members for in the room. This token can be obtained from a `prev_batch` token returned for each room by the sync API. Defaults to the current state of the room, as determined by the server."; `membership` enum `join, invite, knock, leave, ban` "Defaults to no filtering ... When specified alongside `not_membership`, the two parameters create an 'or' condition: either the membership *is* the same as `membership` **or** *is not* the same as `not_membership`."; `not_membership` same enum. `200`: "If you are joined to the room then this will be the current members of the room. If you have left the room then this will be the members of the room when you left." `403`: "You aren't a member of the room and weren't previously a member of the room." | CORRECT. Two precisions: (a) the literal "or" of the two filters is not what Synapse implements (Synapse skips an event when `membership` is set and differs, OR `not_membership` is set and equals: an AND of the two conditions); Nebu takes the AND (D6, Oracle Q3). (b) A user who LEFT may read the members "when you left": Nebu answers `403` for every non-joined user (a labelled deviation, D5, follow-up `gf`); `at` is accepted and ignored (D6). |
| S2 | `/sync` state and the member events of the current state | `GET /sync` `JoinedRoom.state`: "Updates to the state, between the time indicated by the `since` parameter, and the start of the `timeline` (or all state up to the start of the `timeline`, if `since` is not given, or `full_state` is true). State updates for `m.room.member` events will be incomplete if `lazy_load_members` is enabled in the `/sync` filter, and only return the member events required to display the senders of the timeline events in this response." | CORRECT. The current state holds one `m.room.member` slot per user who ever had a member event (`join`, `invite`, `leave`, `ban`, `knock`); a full (initial) state therefore includes invited, banned and left users. Nebu lists only JOINED members (C1): the gap of `fb`. |
| S3 | lazy-loading | CS "Lazy-loading room members": "servers will attempt to only send membership events which are relevant to the client ... it is valid for the server to send redundant membership events to the client"; "Clients which support display-name tab-completion ... should call `/members` for the currently selected room, with an `?at` parameter set to the `/sync` response's `from` token. The member list for the room is then maintained by the state in subsequent incremental `/sync` responses." Endpoints: `/sync`, `/messages`, `/context`. | CORRECT. Nebu ignores filters (`fg` (a), unchanged): it sends every member slot (redundant under lazy-loading, which the spec allows) within the D4 bound. |
| S4 | `/initialSync` (room) | `api.json` `/_matrix/client/v3/rooms/{roomId}/initialSync` GET (not flagged deprecated in the schema): "This endpoint should now exclusively be used for 'peeking' into viewable rooms you're not a member of (Room Previews). Using this endpoint for something other than peeking was deprecated in r0". `403` "You aren't a member of the room and weren't previously a member of the room." The example state events carry `event_id`, `origin_server_ts`, `room_id`, `unsigned`. | CORRECT, decided (D7): kept, state from the same slice; Element 1.12.15 calls it ONLY for peeking (verified, C9), which Nebu refuses for non-members (`403`, unchanged, `gf`). |
| S5 | `unsigned.membership`, `unsigned.age`, `prev_content` | `ClientEvent.unsigned.membership` (Added in v1.11): "The room membership of the user making the request, at the time of the event ... Homeservers SHOULD populate this property wherever practical, but they MAY omit it"; `prev_content` "only returned if the event is a state event, and the client has permission to see the previous content". | CORRECT. In scope: `age` and the predecessor keys on the `/members` and `/initialSync` state events (`fl` (c), D10). Out: `unsigned.membership` (`fl` (a)) and `age` on `/messages`, `/event`, `/relations` (`fl` (b)). |
| S6 | Room upgrade and membership | CS "Room Upgrades", Server behaviour: tombstone permission, new room with `predecessor`, "Replicates transferable state events ... Membership events should not be transferred to the new room due to technical limitations of servers not being able to impersonate people from other homeservers", aliases, tombstone, "If possible, the power levels in the old room should also be modified". No invite step. | CORRECT. Nebu INVITES the old members (a pre-existing Nebu addition, not a spec step; Synapse does not invite); the bans are carried as new ban events in the upgrader's name (moderation-routes-atomic-ban D11). This story makes the invitations real invite events in the upgrader's name (no impersonation): D9. |
| S7 | `m.room.member` content | `m.room.member` content: `membership` (required), `reason` "Optional user-supplied text for why their membership has changed. For kicks and bans, this is typically the reason", `is_direct`, `displayname`, `avatar_url`, `join_authorised_via_users_server`. | CORRECT. The slice serves the STORED content of the latest member event (D2): `reason` of a kick / ban is visible to every joined member (state, as in Synapse and Element's "Banned users" list, C8). |

### What Nebu does today (code)

| # | Question | Verified state |
|---|---|---|
| C1 | The member part of `build_state_events/3` | `server/lib/nebu/matrix/event_dispatcher/server.ex` l.6011-6171. The member slots (l.6065-6079) are SYNTHESIZED from the room process: one `m.room.member` per entry of `state.members` (the joined set), content `{"membership": "join"}`, `sender` = the user, `event_id` / `origin_server_ts` from `state.member_identity` (`Room.Server` l.58, captured at the join, restored by `do_init/1`). Invited, banned, left users have NO slot. The other slots: `m.room.create` (`get_room_create_event/1`), `m.room.power_levels` (process), `m.room.name` (`get_room_name/1`), the generic state (`Room.DB.get_generic_state_events/1` db.ex l.1473-1505, which EXCLUDES `m.room.member` explicitly). `fetch_predecessors?` (l.6166-6170) attaches the batched predecessor lookup (`attach_predecessors_to_state_events/2` l.6193-6202, ONE statement per call). |
| C2 | Callers of `build_state_events/3` | (a) `get_room_state/2` l.4087 (`/members`, `/initialSync`; `fetch_predecessors?` false); (b) `get_room_summary/2` l.4557, `visible_summary_or_forbid!/2` l.4663, `room_visibility_summary/2` l.4680 (summary / hierarchy BFS per room; they read `state.members` for counts and visibility, not the member slots); (c) `/sync`: `initial_join_rooms/2` l.5049 and its `:noproc` path l.5088, `full_state_room/2` l.5827 (via `full_state_rooms/3` l.5804), `fetch_delta_rooms/3` l.5915 (all with `true`). The incremental delta (`fetch_delta_rooms/3`) sends the FULL state minus the slots that appear in its timeline (l.5905-5919), for every room with new events (pre-existing; redundant, spec-allowed). `dedup_member_state_events/2` (l.5964-5977) drops a member slot that is in the timeline. |
| C3 | `GET /rooms/{roomId}/members` | `server/lib/nebu/web/router/protected.ex` l.2242-2270: `get_room_state/2` with an empty type, then `Enum.filter(&(&1.type == "m.room.member"))` and `initial_sync_state_event/3` (l.1754-1777), which **SYNTHESIZES** `event_id` = `"$synth_" <> Base.url_encode64(type <> "|" <> state_key)` and `origin_server_ts` = `now` (l.1773-1775), no `unsigned`, although the real values are on the struct (the comment l.1743-1753 calls this a deferred follow-up). No query parameter is read (`at`, `membership`, `not_membership` ignored). It runs the four non-member reads of C1 (create, name, generic state, creator) for nothing. |
| C4 | `GET /rooms/{roomId}/initialSync` | `protected.ex` l.1702-1741: `get_room_state/2` + `get_messages/2` (`limit: 20`, `dir: b`); `state` through `initial_sync_state_event/3` (synthetic ids, `now`, no `unsigned`); `"membership" => "join"`, `"visibility" => "private"` constant; `messages.chunk` is a `/messages` page (real ids, predecessor keys, pruned redactions). The js-sdk passes `limit` (default 30): ignored, 20 is used (pre-existing, unchanged). |
| C5 | Room resolution and access of `get_room_state/2` | server.ex l.4038-4110: `get_state/1`; on `:noproc` it calls `RoomSupervisor.start_room/1` (l.4053) for ANY id. `Room.Server.do_init/1` (room/server.ex l.434-470) answers an unknown id (`load_members/1` -> `{:error, :not_found}`) with `insert_room/1` (l.452): **an unknown room id reached through `/members` or `/initialSync` gets a `rooms` row** before the membership check refuses it (the `fz` class on a READ path; the ATDD step pins it red first). Access: `MapSet.member?(state.members, caller_id)` else `permission_denied` WITHOUT errcode, message with the caller and room id (l.4080-4084; `Http.map_error/1` answers `403 M_FORBIDDEN` "You are not a member of this room"). Invitees, leavers, kicked and banned users are refused alike. |
| C6 | The latest-member-event reads that exist | `Room.DB` `@sql_member_membership_raw` (db.ex l.1611), `@sql_member_rank` (l.1622: `ban` 0 < `leave` 1 < `invite` 2 < `knock` 3 < `join` 4), `@sql_membership_normalised`, `@sql_get_member_membership` (l.1634), `latest_member_events/2` (l.1755-1810: per USER over many rooms, `row_number()` in the D3 order `origin_server_ts DESC, rank ASC, event_id DESC`). There is no "latest member event per user of ONE room" read. Index `events_room_state_idx` `(room_id, event_type, state_key, origin_server_ts DESC)` (migration 000001 l.228 / 000002 l.27) serves one. `content` exists in two JSONB forms (object or JSON string, `decode_json_object/1`). Last migration: 000051 (no migration in this story). |
| C7 | `upgrade_room/2` invitations | server.ex l.7603ff; step 6 (l.7775-7791): for every member of the frozen old room except the upgrader and the banned users, `db_module_invite().insert_invitation(new_room_id, requester_id, member_id)` = a **row-only invitation** (no `m.room.member` invite event), wake with `:pg.get_local_members/1` (node-local, `fe`), a failure is `Logger.warning(... #{member_id} ... #{inspect(reason)})` (`inspect` of a DB error: against the log rule) and the upgrade continues. Order: tombstone, freeze, `banned_members!/1`, create event, upgrader join, levels, `carry_bans!/3` (l.7764), `carry_power_levels!/3` (l.7770), `copy_state_events/3` (l.7773, incl. the join rule), then the invitations. The audit row `room_upgraded` (l.7794-7801) has `bans_carried` and `power_levels_carried`. Uncapped by decision (`fi`; pinned by `membership_write_limits_http_test.exs` l.767-810 "neither issues the count read"). Only joined members are invited (pending invitees of the old room are not). |
| C8 | The invite writer to reuse | `Room.Server.write_invite/5` (room/server.ex l.187-189, `handle_call` l.613-624): inviter joined and at the `invite` level, invitee not a member, ONE read of the invitee's latest member event (a `ban` rejects the pending row, `{:error, :banned}`), stamp `max(now, not_before, latest + 1)`, size check, insert only while the row is still pending (`:invitation_gone`), `:room_archived`, `:write_failed` / `:duplicate_event`. The dispatcher side: `write_invite_event/5` (server.ex l.3219-3223, a call exit is `:room_unavailable`), `refused_invite_event!/3` and `handle_failed_invite_event!/3` (l.3228-3270: the row THIS call created is rejected again), `wake_invitee/2` (l.3302-3304, `:pg.get_members/1`), `unforget_room/2`. `do_invite!/5` (l.3058-3092) adds the cap check and RAISES: not usable as is for a best-effort multi-invite. |
| C9 | What Element 1.12.15 does (VERIFIED in the source maps of the Element Web 1.12.15 bundle, `html/version` = `1.12.15`, `bundles/3c9ddd76fa48d1221fef/*.js.map`, extracted earlier into THIS session's scratchpad `element-bundle/`; not re-extracted from the `nebu-oauth-element` image, no docker) | `MatrixClientPeg.ts` l.297-300: `opts.lazyLoadMembers = true` (always). matrix-js-sdk `models/room.ts` `loadMembersFromServer()` (l.1048-1057): `client.members(roomId, undefined, "leave", lastSyncToken)` = **`GET /rooms/{roomId}/members?not_membership=leave&at=<the /sync next_batch token>`** (`client.ts` l.6928-6950: `membership`, `not_membership`, `at` query params); called once per room by `loadMembersIfNeeded()` from `RoomView.loadMembersIfJoined` (`RoomView.tsx` l.1526-1540, only when the own membership is `join`) and `MemberListStore.loadMembers` (l.70-104). `room-state.ts` `setOutOfBandMember` (l.~820): "never replace members received as part of the sync": a slot from `/sync` state / timeline wins over `/members`. `MemberListStore.filterMembers` (l.155-185) keeps only `join` and `invite` (left / banned "bail early"); `MemberListViewModel.tsx` l.144-175 renders the joined members, a separator, then the invited ones (i18n `member_list|invited_label` = "Invited"). `RolesRoomSettingsTab.tsx` l.366-390: `room.getMembersWithMembership("ban")` -> fieldset "Banned users" (`room_settings|permissions|banned_users_section`), each entry with the member name, user id, "Reason: <reason>" (`ban_reason`), title "Banned by <sender>" and an Unban button when `currentUserLevel >= banLevel`. `client.ts` l.7085-7089 `roomInitialSync` is called only by `sync.ts` `peek()` (l.406, `peekInRoom`: world-readable peeking). |
| C10 | Admin paths (for the split, not changed here) | `set_room_visibility/3` (server.ex l.2437-2461): only `Admin.DB.update_room_visibility/2` + audit `room_visibility_changed`, no `m.room.join_rules`. `admin_add_room_member/3` (l.2484-2554): refuses a banned target (l.2527-2532, `@join_banned_text`), otherwise a ROW-ONLY invitation from the admin (`insert_invitation/3` l.2540, no invite event) and then `join_room/2`. `admin_remove_room_member/3` (l.2613-2638): a self-`leave_room/2` (`fg` (f)). No Admin unban / ban. |
| C11 | Scope doc | `docs/matrix-api-scope.md` l.101 `/members` ✅ "Returns membership events; no `unsigned` on them (... follow-up `fl`)"; l.102 `/initialSync` ✅; **l.103 `GET /rooms/{roomId}/joined_members` ✅ "Compact map of joined members" although NO such route exists** (`protected.ex` has none; `unrecognized_routes_test.exs` lists `/members` and `/initialSync` only): it answers `404 M_UNRECOGNIZED`. Corrected by this story (D12, follow-up `gh`). |
| C12 | Tests that pin today's behaviour | `member_prev_content_http_test.exs` l.681-704 (`/members` and `/initialSync` state events carry NONE of the predecessor keys; `/members` runs NO predecessor statement; `/initialSync` at most the one of its `messages.chunk`), l.45 `@baseline_initial_sync_statements 48` (3 rooms); `matrix_room_view_routes_test.exs` l.235-280 (`/members` shape, unknown room `403 or 404`, non-member `403`); `matrix_client_compat_test.exs` l.2787ff (`/initialSync` shape); `moderation_routes_http_test.exs` l.1048-1058 (banned users get no invitation in the upgraded room; c / d `:pending`); `membership_write_limits_http_test.exs` l.767-810 (upgrade rows uncapped, no count read). The id line of `follow-ups.md` ("unused: ... `ge` onward") is pinned by TEN docs suites (AC15 (a)). |

### Sizing

One story, medium (about 450 lines in `server/lib`): `Room.DB` two reads (`member_state_slice/2`, `direct_invitees/1`: about 110),
`EventDispatcher.Server` (the slice option of `build_state_events/3` and its callers, `get_room_members/2` for `/members`, the
`/initialSync` state, the room resolution, the upgrade invitations through the invite writer: about 220), `protected.ex` (the two routes,
the query validation, the shared renderer: about 80), `Http` (a public state-event renderer with `room_id`: about 40). No migration, no
new route, no new audit action, no Nebu UI. **Split (decided):** the Admin part of `et` needs owner decisions (as which sender the
Admin writes `m.room.join_rules` when he is not a member; whether the Admin gets ban / unban) and an Admin UI change (`ui: true`, the
UX gate): it is follow-up `ge`, a separate run. If the ATDD reference exceeds about 650 lines in `server/lib`, the dev stops and reports
(the orchestrator may then move D9 (upgrade invitations) into its own story under `fb`), never a half-built slice.

## Decisions

- **D1 (the member slice is EVENT-based and read from the database).** A new read `Room.DB.member_state_slice(room_id, opts)` returns,
  for ONE room, the latest `m.room.member` event per `state_key` (= per user) in the D3 tie order of sync-membership-partition
  (`origin_server_ts DESC`, then `@sql_member_rank` (most restrictive first), then `event_id DESC`), with the membership normalised by
  `@sql_membership_normalised` (an unknown / missing / unparseable value is `leave`, the `fg` (k) rule): `{:ok, [%{event_id, state_key,
  sender, content, origin_server_ts, membership}]}` | `{:error, reason}`. ONE statement (SQL inline, ADR-018; `DISTINCT ON (state_key)`
  over `events_room_state_idx`, or an equivalent window), `content` decoded from either JSONB form. It is the SAME rule the `/sync`
  partition, the join decision and the ban check use, so the served state and the authorization agree. The slice is NOT kept in the
  room process (no cache: no stale node-local copy, cluster-safety) and is read outside the room process (a snapshot of committed
  events; a member event committed concurrently is in this response or the next one). Seam (BINDING, test review S-1): the slice is reached through `messages_db_module()` (the
  db seam of `build_state_events/3`; the suites inject there); `get_room_status/1` and `direct_invitees/1` through `rooms_db_module()`.
  Signature (binding): `member_state_slice(room_id, opts)` with the keyword options `:membership`, `:not_membership` (D6 filters) and
  `:other_cap` (a test seam, default 10 000), answering `{:ok, [%{event_id, state_key, sender, content, origin_server_ts,
  membership}]}` ordered `join`, `invite`, `ban`, `knock`, `leave`, then `state_key`; `content` is `%{}` for an unparseable content
  (one JSON level decoded is required, a doubly nested JSON string is best effort); the SQL text starts with the marker comment
  `/* member_state_slice */` (the statement counters match it); a db module
  that does not export it: allowed ONLY for a test db module (the process-joined slice of today is then used); for the real
  `Nebu.Matrix.Room.DB` a missing function or a failing read is a handled `500` with the generic body and a value-free ERROR log (room
  id, `db_error_class/1`) (the state-writer-redaction M1 rule): never a silently joined-only state.
- **D2 (which content is served).** Each slot is the STORED latest member event: its real `event_id`, `origin_server_ts`, `sender` (the
  kicker / banner / inviter for those transitions), `content` as stored (`membership`, `reason`, `is_direct`, `displayname`,
  `avatar_url` when present). No synthesis for a slot that has an event. Element's "Banned by <sender>" and "Reason: <reason>" (C9)
  therefore show the real values. **Legacy fallback (D8).**
- **D3 (which paths use the event slice; labelled where they do not).** (a) The initial `/sync`: `initial_join_rooms/2` (both code paths)
  and `full_state_room/2` (the full state of a room delivered in full, incl. a newly joined room). (b) `/members` (D6). (c)
  `/initialSync` (D7). (d) NOT changed, labelled (Oracle wording) "the incremental `/sync` state keeps the joined slice of the room process:
  member changes reach clients in the timeline, except in a `limited: true` delta, whose gap loses them (`fc`); the synthesized
  joined slot re-sent in a delta can overwrite the real latest join content (`displayname`, `avatar_url`) delivered by the initial
  sync (`gg`)": `fetch_delta_rooms/3` (C2: it re-sends the full state for every room with new events; an
  extra slice statement there would be paid on every delta; follow-up `gg`); the room-summary / hierarchy callers (C2 (b): they need no
  member slots). `build_state_events` gets a keyword option (`build_state_events/4`: `member_slice: :events | :joined`, default `:joined`; the call
  sites pass the LITERAL keyword pair `member_slice: :events`, AST-pinned) instead of a boolean
  flag soup; the two `/sync` opt-ins keep `fetch_predecessors?`. The joined slice of the process (C1) stays the implementation of
  `:joined`.
- **D4 (bounds and cost).** Joined slots are not capped (as today; bounded by `max_members` when the room has one). The NON-joined slots
  (`invite`, `ban`, `knock`, `leave`) are capped at **10 000 per room per response** (`@member_slice_other_cap`, a module attribute, not
  an env var), selected in SQL in the priority `invite` > `ban` > `knock` > `leave`, newest `origin_server_ts` first within a class,
  `state_key` as the last tie-break (deterministic); the cap is applied AFTER the `/members` filters of D6 (in SQL, so a
  `membership=ban` query of a room with many left users still returns its bans). Labelled "member slots other than `join` are capped at
  10 000 per room in the `/sync` state, `/members` and `/initialSync`: Nebu bound (those responses are then incomplete)". No log line per truncated response (the `/sync` hot path): the 07-deployment operator query **Q-ms**
  lists rooms above the cap. Cost: TWO more statements per joined room of an initial `/sync` since security cycle 1 (`SET LOCAL statement_timeout` + the
  slice inside `BEGIN` / `COMMIT`; the statement baseline of `member_prev_content_http_test.exs` 48 -> 54 for 3 rooms, AC15 (c);
  was 51 before the timeout); the existing batched predecessor statement now also covers the
  non-joined member slots (no extra statement); `/members` runs the slice + ONE predecessor statement and NO create / name / generic
  state read (fewer statements than today); `/initialSync` runs the slice, the four non-member reads of today and ONE predecessor
  statement for its `state`. The byte cost of an initial `/sync` grows by the non-joined slots (each at most 64 KiB + its predecessor
  content, story event-size-limit): noted on `fp`; lazy-loading stays ignored (`fg` (a)). **Security cycle 1 (D15):** the slice
  cost is O(member EVENTS of the room) (every member event is read to pick the latest per user), not O(users); the slice statement runs
  under `SET LOCAL statement_timeout = '2s'`; operator query **Q-ms2** (07-deployment) lists the total member-event volume per room.
- **D5 (who may read the member slice; security).** Only a JOINED user (the room process member set, the existing check of
  `get_room_state/2`) gets the slice: `/members`, `/initialSync` and the `rooms.join` state of `/sync`. An invitee keeps only the
  stripped `invite_state` of `rooms.invite` (unchanged: no member list, no bans); a user who left, was kicked or banned gets `403
  M_FORBIDDEN` "You are not a member of this room" on `/members` and `/initialSync` (unchanged) and his `rooms.leave` window as today
  (unchanged). **Labelled deviation** "a user who left gets `403` on `/members` (spec: the members when you left): Nebu restriction"
  (follow-up `gf`): no historical state is computed. The refusal sets `errcode: "M_FORBIDDEN"` explicitly and its message carries NO
  caller or room id (C5 today: the message names both; the mapper hides it, the fixed text is set at the source now). **Visibility of
  the content:** banned / kicked / invited / left user ids, the `sender` of each transition and the stored `reason` are visible to EVERY
  joined member (spec: room state; Element shows them in "Banned users" to every member who opens the settings); current state is not
  gated by `history_visibility` (the spec gates EVENTS, a joined member always sees the current state; `es` unchanged). **PII / logs (No
  Sensitive Data in Logs Law; reworded by test review S-3, no names-only mask):** at INFO and above nothing sensitive is logged (no
  slice, no `reason`, no `displayname`, no content; an ERROR / WARNING names the room id and `db_error_class/1` / the refusal atom
  only); at DEBUG the EXISTING `RequestLogger` payload redactor masks `reason`, `displayname` and `content` (pinned by AC17 (a)); user
  ids and the query string (the `membership` / `not_membership` enum values, the `at` token) are logged as for `/sync`. `/members` is a GET
  without a body. **Rate limits:** SUPERSEDED by security cycle 1 (D14): `/members` and `/initialSync` are charged to the new `members_read`
  tier; the initial `/sync` stays uncharged.
- **D6 (`GET /rooms/{roomId}/members`).** (a) Room resolution: `ensure_room_without_lazy_create!/2` (state-writer-redaction D10 (a)): an
  unknown room id answers `403 M_FORBIDDEN` "You are not a member of this room" with NO `rooms` row and NO room process (fixes C5 for
  this path); for a known STOPPED room the caller's latest membership is read from the database FIRST (security cycle 1, Kassandra
  L-1, D16: `get_member_membership/2`, an index lookup): a non-member gets the fixed `403` WITHOUT a process start; a joined member's
  request starts the room from the database (the system role keeps working); then the membership check (D5) on the process state. A failing `get_room_status/1` read is a handled
  `500` (generic body, value-free ERROR log). **Decision (test review S-2):** the SYSTEM-role path of `get_room_state/2` (internal
  callers) gets the same room resolution: an unknown room answers `permission_denied` `M_FORBIDDEN` "You are not a member of this
  room" (no lazy row) for it too, not `not_found`. **Archived / tombstoned rooms (test review S-5, decided as a TRUE non-goal; corrected):**
  the answers for an archived (or upgraded) room stay EXACTLY as today; `get_messages`, `get_room_state/2` and `get_room_members/2` are
  NOT changed for archived rooms (Admin-archived rooms are frozen on purpose). Today (verified): `upgrade_room/2` archives the old room
  (`archive_room_atomic/1`) and stops its process (`freeze_old_room!/1`, server.ex l.7962-7986); `Room.Server.init` stops an archived
  room at once (`{:stop, :normal}`, room/server.ex l.421-427), so `start_room/1` fails and `get_room_state/2` / `fetch_room_state/1` raise
  `not_found`: `/members` and `/initialSync` of an archived room answer `404 M_NOT_FOUND` "Room not found" to EVERY caller (old member
  or not; the `get_room_status/1` read of `ensure_room_without_lazy_create!/2` finds the row and the start then fails the same way); the
  initial `/sync` of an old member answers `200` with the archived room in NO section and the new room in `rooms.invite`. Labelled
  "known, unchanged: an archived room is not served to its members (`gi`)". (b) Query parameters, validated before
  any room access, first failure wins: `membership` / `not_membership` present and not exactly one of `join`, `invite`, `knock`,
  `leave`, `ban` (the empty string included) -> `400 M_INVALID_PARAM` "membership must be one of join, invite, knock, leave, ban" /
  "not_membership must be one of join, invite, knock, leave, ban" (fixed texts, no value echoed); both given -> an event is returned
  when `membership` matches AND `not_membership` does not (**labelled "membership and not_membership combine as AND: Synapse parity;
  the spec text says 'or'"**, S1 (a), Oracle Q3; Element sends only `not_membership`); the `400` is **labelled "400 for values outside
  the enum: Nebu choice"** (the spec lists no 400 for `/members`; the check is case-sensitive); `at` is accepted with ANY value and ignored (**labelled "`at` is ignored: the current state is returned"**; the
  spec's default; Element sends its `/sync` `next_batch` token, C9, which is not a `prev_batch`); a repeated parameter: the last value
  (Plug). (c) Response `200 {"chunk": [...]}`: one ClientEvent per slot of the slice after the filters (D4 cap), each with `event_id`,
  `type` `m.room.member`, `state_key`, `sender`, `content`, `origin_server_ts`, `room_id` and `unsigned` = `age` (`max(1, now -
  origin_server_ts)`, the `/sync` rule) plus `replaces_state` / `prev_content` / `prev_sender` when the slot has a predecessor (ONE
  batched `fetch_state_predecessors` statement; the keys together or not at all, `put_predecessor_keys/2`); order: `join`, `invite`,
  `ban`, `knock`, `leave`, then `state_key` ascending (deterministic, Nebu choice). `knock` matches nothing today (no knock API, `fg`
  (d)). (d) A dedicated dispatcher function, BINDING name and shape: `get_room_members/2` taking a plain map `%{room_id, membership,
  not_membership}` (and the stream) and answering `%Core.GetRoomStateResponse{state_events: ...}`, instead of `get_room_state/2` + a
  filter; it sets `errcode: "M_FORBIDDEN"` and the fixed text at the source (as `get_room_state/2` now does); it reads the
  slice only (D4).
- **D7 (`GET /rooms/{roomId}/initialSync`).** Kept (Element uses it only for peeking, C9; other clients may use it as a room snapshot).
  Room resolution as D6 (a) (unknown room `403`, no row); access D5 (`403` for non-members: no peeking, `gf`). `state` = the full state
  with the event slice (`member_slice: :events`), rendered like `/members` (real ids, `room_id`, `unsigned.age` + predecessor keys, ONE
  predecessor statement). `messages`, `membership: "join"`, `visibility: "private"`, `presence`, `account_data`: unchanged; the constant `visibility` is
  WRONG for a room listed in the directory (Oracle; pre-existing) and is **labelled "`visibility` is always `private`: known deviation
  (`gf`)"**, the ignored `limit` is recorded in the scope doc; the `state` is the FULL current state, so `messages.chunk` may repeat a
  state event (labelled "the `state` of `/initialSync` is the full current state, `messages.chunk` may repeat state events"); no change
  (note on `gf`).
- **D8 (legacy fallbacks; labelled).** (a) A member of the process set WITHOUT any persisted member event (legacy rows from before the
  member events were written) is added to the slice as today's synthesized join (C1): `/sync` with `event_id` `""` and
  `origin_server_ts` 0 and without `unsigned` (as today; AC5 (c)); `/members`
  and `/initialSync` keep the deterministic `$synth_` id and `now` ONLY for such an entry, without `unsigned` (labelled "a member
  without a member event is served synthesized: legacy"). (b) A latest member event `join` whose user is NOT in the process member set
  (a legacy half state, operator query Q-half of moderation-routes-atomic-ban) is served as the event says: the state is event-based,
  the authorization stays with the member set (labelled "state is event-based; legacy half states are visible as such (Q-half)"). (c) A
  `$synth_` id never appears for a slot that has an event (AC source pin).
- **D9 (`upgrade_room` writes real invite events; closes the upgrade part of `fb`).** Step 6 becomes, for each old member (not the
  upgrader, not banned, in the existing order): (1) the row through the plain `insert_invitation/3` (UNCAPPED as today, `fi`; the cap
  tests of C12 stay green; labelled "the upgrade's invitations are not charged to the pending caps"); (2) the invite EVENT through the
  room-process invite writer of the NEW room (`write_invite_event/5` -> `Room.Server.write_invite/5`, inviter = the upgrader, who is
  joined at his carried level >= 100, `not_before` 0: the writer stamps after the latest member event), content `{"membership":
  "invite"}` plus `"is_direct": true` iff the member's OWN latest `invite` event in the OLD room had `is_direct: true` (one batched read
  `Room.DB.direct_invitees(old_room_id)` -> `{:ok, MapSet}` through `rooms_db_module()`, read BEFORE the tombstone next to the bans
  pre-check (security cycle 1, MINOR-7: a pure read; a failure answers `500` and writes NOTHING: no tombstone, no freeze, no new room;
  the old room stays active), SQL inline, both JSONB forms); (3) after the event: `unforget_room/2` and
  `wake_invitee/2` (`:pg.get_members/1`, cluster-wide: replaces the node-local wake of C7; `fe`). A refusal or a failed write of the event
  (`:banned`, `:already_member`, `:invitation_gone`, `:room_archived`, `:room_unavailable`, `:write_failed`, a unique violation that is
  not "already invited") rejects the row THIS call created (the compensation rule of C8) and logs a value-free WARNING (new room id,
  the refusal atom or `db_error_class/1`; no user id list, no `inspect`); the upgrade CONTINUES (best effort per member, as today) and
  answers `200`. Not via `do_invite!/5` (it charges the caps and raises). The upgrade keeps the existing seams and function names
  (`insert_invitation_row`, `wake_invitee`; AST-pinned); the suites inject an invite-event failure through the `:room_manager`
  `db_module` (`apply_member_change/4` with `require_pending_invitation`), the BINDING failure seam. The `room_upgraded` audit row is unchanged (no new key).
  Labelled "the upgrade invites the old joined members as real invite events in the upgrader's name: Nebu addition (the spec has no
  invite step)". **Ignored users (verified):** the invite path writes the invitation regardless of the invitee's `m.ignored_user_list`;
  the SUPPRESSION is on the sync side (`ignored_inviters/1`, server.ex l.5283-5302: an invitation whose inviter the syncing user ignores
  is not delivered in `rooms.invite`, sync-membership-partition D8), so an upgrade invitation by an ignored upgrader is suppressed like
  any other (pinned, AC16 (f)). **Invite blocking** (`m.invite_permission_config` `block`: `403 M_INVITE_BLOCKED`, suppression of stored
  invites) is NOT implemented anywhere (`fh`): **labelled "invite blocking (`m.invite_permission_config`) is not applied, also not to
  upgrade invitations (`fh`)"** (note on `fh`, `gi` (d)). **Element's upgrade dialog** may also invite the old members client-side
  (`POST /invite`): for an invitee the upgrade already invited, the invite path answers the already-invited no-op (`200 {}`, nothing
  written, C8 `do_invite!/5`), so the client flow does not break (pinned, AC16 (e)). Pending invitees of the old room are still not invited (`gi`). The synthesized `invite_state` for row-only invitations
  of sync-membership-partition stays for legacy rows.
- **D10 (`fl` (c): `unsigned` on `/members` and `/initialSync` state).** Both render through ONE public renderer in `Nebu.Matrix.Http`,
  BINDING signature `Http.state_event_json(%Core.SyncRoomStateEvent{}, now_ms, room_id | nil)` (the state-event branch of
  `build_joined_rooms/2` extracted; `nil` = `/sync`, ClientEventWithoutRoomID; the D8 (a) legacy rule lives INSIDE it: an entry with
  `event_id` `""` renders as `""` / `origin_server_ts` 0 without `room_id` and as the `$synth_` id / `now` with a `room_id`; `$synth_` in
  ONE file, `http.ex`): the same `age` rule and `put_predecessor_keys/2`; an
  entry without a real event id (D8 (a)) gets no `unsigned`. `replaces_state` and `prev_sender` are not v1.18 `unsigned` keys (only
  `prev_content` is): **labelled "`unsigned.replaces_state` / `prev_sender`: Synapse-compatible extension"** (as on `/sync` since
  member-event-prev-content). `initial_sync_state_event/3` and its `$synth_` synthesis for real events
  are removed; the comment l.1743-1753 is replaced. `fl` (a) (`unsigned.membership`) and (b) (`age` on `/messages`, `/event`,
  `/relations`) stay open.
- **D11 (`/sync` state and timeline).** `dedup_member_state_events/2` stays: a member slot that is in the timeline window is not repeated
  in `state` (now also for invite / ban / leave slots). The spec's `state` is the state at the START of the timeline (a user banned
  inside the window would show his prior `join` there); Nebu serves no predecessor slot: **labelled (Oracle decision) "state = current
  member state minus the timeline slots; a client replaying the timeline ends in the same final state"**. The join rooms of an initial `/sync` deliver the full member slice; `rooms.invite`
  and `rooms.leave` are unchanged. The heroes / `m.joined_member_count` / `m.invited_member_count` (row-based, `get_room_heroes/2`) are
  unchanged.
- **D12 (docs).** Scope doc rows `/members`, `/initialSync`, `/sync` (the state paragraph), `/upgrade` and the corrected
  `joined_members` row (🔲 "not routed: `404 M_UNRECOGNIZED`", `gh`; the "✅ Compact map" claim is removed); 07-deployment paragraph
  and query Q-ms; CHANGELOG; follow-ups (AC14).
- **D13 (what stays out).** The Admin part (`ge`, from `et`; `fg` (f)); leavers' `/members` / `at` / peeking (`gf`); lazy-loading, the
  incremental full-state re-send, a `/members` pagination (`gg`); `joined_members` (`gh`); pending invitees of an upgraded room and the
  partial `is_direct` rule (`gi`); `GET /rooms/{id}/state`, `/state/{type}` and `/state/{type}/{key}` (`bf`: unrouted, they keep
  `404 M_NOT_FOUND` "Unrecognized request" and read no slice, so they cannot disagree with `/members`; **labelled "GET state is not
  implemented (`bf`)"**, pinned by AC16 (n)); `unsigned.membership` / `age` on `/messages` (`fl` (a), (b)); `PUT
  .../state/m.room.member` (`fq`); knock (`fg` (d)); `history_visibility` enforcement (`es`); `/context` (`fk`).

### Oracle questions (the Oracle gate runs next)

- Q1 (S2, D1, D3): the initial `/sync` state lists the latest member event of EVERY user (join, invite, ban, knock, leave) read from the
  member events with the D3 tie order; the incremental `/sync` state keeps the joined slice (changes come through the timeline). Correct
  reading of "all state up to the start of the timeline" (Nebu ignores `lazy_load_members`, so every slot is "redundant but valid")?
- Q2 (D4): capping the non-joined member slots at 10 000 per room (invite > ban > knock > leave, newest first) is an acceptable Nebu
  bound (the spec has no limit; the state is then incomplete for such rooms)?
- Q3 (S1 (a), D6): `membership` + `not_membership` combined as AND (Synapse parity) instead of the literal "or" of the spec text?
- Q4 (D6): `at` accepted with any value and ignored (current state); Element sends its `/sync` `next_batch` token, not a `prev_batch`.
- Q5 (D5): `403` for a user who left (the spec allows the members "when you left"): acceptable as a labelled restriction (`gf`)?
- Q6 (D5): banned / kicked users' ids and their `reason` are visible to every joined member through the state (spec: state is visible to
  joined members regardless of `history_visibility`). Confirm.
- Q7 (D6 (b)): invalid / empty `membership` / `not_membership` -> `400 M_INVALID_PARAM` (the spec lists no 400 for `/members`).
- Q8 (D7): `/initialSync` kept for members with the same state; no peeking (`403` for non-members, also for `world_readable` rooms).
- Q9 (D9): the upgrade's invitations as real invite events by the upgrader (the spec says membership events should not be
  transferred; Nebu writes NEW invite events in the upgrader's own name, no impersonation), `is_direct` carried from the invitee's own
  old invite.
- Q10 (D8): the legacy fallbacks (synthesized join for a member without an event; an event-based `join` of a half state served as is).

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused ... `ge` onward" and a grep of `docs/` finds `ge`-`gi` in no row: the new ids are `ge`, `gf`, `gg`, `gh`, `gi`; unused from `gj` onward)

- **`ge` — Admin room membership and visibility (the Admin part of `et`; story `admin-room-membership`, a separate run with owner
  decisions and the UX gate).** Binding design constraints for that story: (a) the Admin "Visibility" toggle either writes
  `m.room.join_rules` (and, if decided, `m.room.history_visibility`) through the ONE state writer `Room.Server.write_state/5` (never
  `emit_state_event_at/6` from the caller), deciding as which sender (the Admin is often not a member; a server-side sender is an owner
  decision), or the divergence (the toggle is a directory label only) is documented in the Admin UI next to the control; (b) an Admin
  force-add never writes a row-only invitation (C10): it goes through the invite writer (`write_invite/5`) and the join writer, and a
  banned target stays refused unless an Admin unban is decided; (c) an Admin ban / unban / removal goes through `Room.Server.moderate/6`
  (the Admin as a member with the level, or a decided server sender) with an audit row; the Admin removal becomes a kick with the Admin
  as sender (`fg` (f)); (d) banned users in the Admin room detail read the event slice of this story (`Room.DB.member_state_slice/2`),
  not `room_members`. Source: this story (split, D13), `et`. Non-gating (owner decision).
- **`gf` — `/members` and `/initialSync` for users who left; `at`; peeking.** A user who left, was kicked or banned gets `403` (spec: the
  members of the room when he left); `at` is ignored (no historical state); `/initialSync` does not offer peeking into `world_readable`
  rooms (Element's `peekInRoom` gets `403` and falls back to the room preview); `/initialSync` answers a constant `"visibility":
  "private"` also for a room listed in the directory (pre-existing, Oracle: wrong; the value should come from `rooms.visibility`).
  Needs a state-at-event read (relates to `fg` (b), `es`). Source: this story (D5, D6, D7). Non-gating.
- **`gg` — Member state cost: no lazy-loading, the incremental full-state re-send, no `/members` paging.** `lazy_load_members` is
  ignored (`fg` (a)), so every initial `/sync` carries every member slot (non-joined slots capped at 10 000 per room by this story); the
  incremental `/sync` re-sends the full state (joined slice) of every room with new events instead of the state delta (pre-existing,
  redundant), and its synthesized joined slot (`{"membership": "join"}`, the join-time id) can overwrite the real latest join content
  (`displayname`, `avatar_url`) that the initial sync delivered; `/members` has no paging (the spec has none either). Options: honour `lazy_load_members` (timeline senders only), a state
  delta for incremental syncs (a stream position, `fc`), the per-response byte budget of `fp`. Source: this story (D3 (d), D4). Non-gating.
- **`gh` — `GET /rooms/{roomId}/joined_members` is not routed.** `docs/matrix-api-scope.md` listed it as ✅ "Compact map of joined
  members" by mistake (corrected by this story to "not routed"); it answers `404 M_UNRECOGNIZED`. Spec: a map of user id -> `display_name`
  / `avatar_url` for joined members ("primarily for Application Services"). Source: this story (C11). Non-gating.
- **`gi` — Upgrade invitation residuals.** (a) Pending invitees of the old room are not invited into the new room (only joined members
  are); (b) `is_direct` is carried only when the invitee's OWN latest invite in the old room had it: the original creator of a DM that
  the partner upgrades gets a plain invitation (Element may not mark the new room direct for him); (c) the upgrade's invitations stay
  uncapped (`fi`); (d) invite blocking (`m.invite_permission_config`, `fh`) is not applied to them (ignored inviters ARE suppressed on
  the sync side); (e) known, unchanged: an archived room (also the old room of an upgrade) is not served to its members: `/members`,
  `/initialSync` and `/messages` answer `404 M_NOT_FOUND` "Room not found" and the initial `/sync` lists it in no section (Admin-archived
  rooms are frozen on purpose; reading their history would need an archived-read decision). Source: this story (D9, D6 (a)). Non-gating.
- Notes (no new id): `fb` CLOSED (all parts: the state model, the revoke done by moderation-routes-atomic-ban, the upgrade invite
  events); `et` (the Admin part is follow-up `ge`; the owner decision stays there); `fl` ((c) closed: `/members` and `/initialSync`
  state events carry `unsigned.age` and the predecessor keys; (a) and (b) open); `fg` ((a) the initial `/sync` now lists every member slot
  although `lazy_load_members` is still ignored; (f) moved to `ge`); `fi` (the upgrade's invitations are event-backed now and still
  uncapped, `gi` (c)); `fe` (the upgrade invitation wake uses `:pg.get_members/1` now); `fp` (the initial `/sync` carries the non-joined
  member slots, capped at 10 000 per room; `/members` and `/initialSync` are charged to the `members_read` tier since security cycle 1,
  the initial `/sync` is not; no byte budget for `rooms.join.state` yet; a slice timeout fails the whole initial `/sync` (availability
  coupling, D15)); `fc` (the incremental delta can still lose member events in a truncated window; the next
  initial `/sync` now repairs them in `state`); `fh` (invite blocking is not applied to upgrade invitations either); `gg` (security cycle 1: long term, a current-membership table
  updated in the SAME transaction as the member writer would make the slice O(users); narrow-columns-first selection, if not done
  (MINOR-4); the slice timeout couples the whole initial `/sync` to the largest room); `gb` (GDPR / erasure note, Kassandra I-5:
  member-event `content` incl. `reason`, `displayname` and `prev_content` stays visible to joined members through the state; an erasure
  story must cover member events).

## Acceptance Criteria

Test files are named in "Acceptance Tests". "Real DB" = the real `Nebu.Repo`, `Room.Server` under `Horde`, `Room.DB`, through
`Nebu.Web.Router` where the AC says HTTP (`@moduletag :integration`, random users and rooms, sessions from
`ModerationTestSupport.user!/1` or the equivalent helper). Fakes only where an AC says "unit". Every refusal: nothing written (no event,
no `rooms` row, no room process started for an unknown id).

1. **Initial `/sync` state lists every member slot (HTTP real DB, D1-D3, D11).** Room R (`public_chat`, creator A at 100): B joins; C is
   invited by A; D joins and is banned by A with `reason` "spam"; E joins and leaves; F joins and is kicked by A with `reason` "off
   topic"; G is invited and declines. Then A sends 25 messages (all member events are outside the 20-event window). An initial `/sync`
   (no `since`) of B: `rooms.join[R].state.events` contains exactly one `m.room.member` per user A-G with the membership of the latest
   member event (A, B join; C invite; D ban; E leave; F leave; G leave), each with the REAL `event_id` (equal to the stored row),
   `origin_server_ts`, `sender` (C's invite: A; D's ban: A; F's kick: A; E's leave: E; G's decline: G) and stored `content` (D: `reason`
   "spam"; F: `reason` "off topic"); `unsigned.age` and, where a predecessor exists, `replaces_state` / `prev_content` / `prev_sender`
   (D's ban: `prev_content.membership` = `join`). (b) The same with the member events INSIDE the timeline window: each slot appears in the
   timeline, not in `state` (D11). (c) An incremental `/sync` of B after a new message: unchanged behaviour (the joined slice; pinned,
   labelled D3 (d)). (d) The D3 tie: a `join` and a `ban` of one user inserted with the same `origin_server_ts` (direct inserts in an
   own room, `on_exit` cleanup) -> the slot is the `ban`. (e) The room-summary paths (`GET /rooms/{id}/summary` or the hierarchy) run no
   slice statement (statement count).
2. **`GET /rooms/{roomId}/members` (HTTP real DB, D5, D6).** With R of AC1: (a) B without parameters -> `200`, `chunk` = all seven slots
   in the D6 order (join, invite, ban, leave; `state_key` ascending within a class), each a ClientEvent with `room_id`, the real
   `event_id` / `origin_server_ts` / `sender` / `content`, `unsigned.age` and the predecessor keys where a predecessor exists; no
   `$synth_` id anywhere. (b) `?not_membership=leave` (Element's call) -> A, B (join), C (invite), D (ban). (c) `?membership=ban` -> D
   only; `?membership=invite` -> C only; `?membership=knock` -> `[]`. (d) `?membership=join&not_membership=leave` -> A, B (AND);
   `?membership=ban&not_membership=ban` -> `[]` (AND, the Oracle-Q3 pin). (e) `?at=<B's next_batch>` and `?at=garbage` -> the same as
   without `at`. (f) `?membership=joined`, `?membership=`, `?not_membership=JOIN` -> `400 M_INVALID_PARAM` with the D6 fixed texts, body
   exactly `{"errcode", "error"}`, no value echoed; the validation happens before the room lookup (a non-member gets the `400`, not the
   `403`). (g) C (invited), D (banned), E (left), F (kicked), G (declined) and a never-member -> `403 M_FORBIDDEN` "You are not a member of
   this room" (errcode asserted; the body names neither the caller nor the room). (h) An unknown room id -> `403 M_FORBIDDEN`, NO `rooms`
   row, NO room process (Horde lookup) (the ATDD step pins today's lazily created row red first); a known room whose process is stopped
   -> started, `200`. (i) Statement count of `/members`: exactly the slice + one predecessor statement (+ the room status read when the
   process was stopped); no create / name / generic-state read.
3. **`GET /rooms/{roomId}/initialSync` (HTTP real DB, D7, D10).** B on R: `state` contains the seven member slots of AC1 and the
   non-member state (create, power levels, join rules, ...), every entry with its real `event_id`, `origin_server_ts`, `room_id` and
   `unsigned` (age + predecessor keys where one exists); no `$synth_` id for a slot with an event; `messages.chunk` unchanged (a
   `/messages` page). Non-members (C-G, a never-member) -> `403 M_FORBIDDEN`; an unknown room -> `403`, no row, no process.
4. **Bounds (real DB, D4).** In an own room: 3 joined members and, inserted directly (`on_exit` cleanup), 10 005 non-joined member slots
   (invites, bans and leaves of random user ids, distinct timestamps). (a) An initial `/sync` of a member and `/members` deliver all 3
   joined slots and EXACTLY 10 000 non-joined slots, chosen invite > ban > leave, newest first, deterministic across two calls. (b)
   `?membership=ban` returns every ban (they are fewer than the cap) even though the leaves alone exceed it (filter before the cap). (c)
   `Room.DB.member_state_slice/2` is ONE statement, response-bounded (the cap selected in SQL by a window rank; it reads every member
   event of the room through `events_room_state_idx`) and index-served (an EXPLAIN / source pin; no `LIMIT` required). (d) The Q-ms query of 07-deployment lists this room (checked in a rolled-back transaction with fixture rows).
5. **`member_state_slice/2` contract (real DB, D1, D8).** (a) The latest per user in the D3 order with normalised memberships (an
   unparseable content row reads as `leave`; a JSON-string content row decodes like an object row); (b) a user with a single member event;
   (c) a member of the process set without any member event (a `room_members` row inserted directly) appears in `/sync` as a synthesized
   join (`event_id` `""`, `origin_server_ts` 0, no `unsigned`) and in `/members` with a `$synth_` id and no `unsigned` (D8 (a)); (d) a latest `join` event of a user who is NOT
   in the member set (direct insert) is served as `join` in `/members` while that user's own `/members` call is `403` (D8 (b)); (e) a
   failing slice read (db hook) on an initial `/sync`, on `/members` and on `/initialSync` -> a handled `500` with the generic body and a
   value-free ERROR log (room id, `db_error_class/1`), never a joined-only answer; EXCEPT (security cycle 2, D18) a timeout (`57014`), a
   `DBConnection.ConnectionError` or a D19 limit overflow: on the `/sync` paths that room is DEGRADED to the joined slice, on `/members`
   / `/initialSync` the fixed `503` (AC19); (f) unit: a TEST db module without the read -> the
   joined slice; the real `Room.DB` -> never the fallback (source pin).
6. **Upgrade invitations are real invite events (HTTP real DB, D9).** (a) A public room with A (creator), B, C joined, D banned: `POST
   /upgrade` by A -> `200`; in the new room B and C each have a pending row AND an `m.room.member` invite event (sender A, `state_key` the
   user, content `{"membership": "invite"}`), D has neither (the C12 pin stays green); B's next `/sync` lists the new room in
   `rooms.invite` with the REAL invite event in `invite_state` (the event's `sender` A; the stripped form); B joins: B's join event has
   the invite as predecessor (`unsigned.prev_content.membership` = `invite`). (b) A DM (`createRoom` with `is_direct: true`, B invited and
   joined) upgraded by A: B's new invite carries `is_direct: true`; upgraded by B instead: A's new invite has no `is_direct` (`gi` (b),
   pinned). (c) The invite events are stamped after the copied state and each after the invitee's latest member event (`origin_server_ts`
   strictly greater). (d) A failing invite event for one member (a db hook on `write_invite` for B): the upgrade answers `200`, B's row
   is rejected again (no pending row, no event), C is invited normally, ONE value-free WARNING (room id + refusal / error class; no
   `inspect`, no user id list). (e) A failing `direct_invitees/1` read -> `500` and nothing written (SUPERSEDED by AC18 (j): read before the
   tombstone). (f) The wake reaches a sync task of the invitee subscribed through `:pg.get_members/1` (a `:pg` test member; source pin that the
   upgrade has no `:pg.get_local_members/1` call). (g) The upgrade still issues no count read (C12, `membership_write_limits_http_test.exs`
   green) and the `room_upgraded` audit metadata is unchanged.
7. **Element's view after a reload (HTTP real DB, the API side of the E2E).** Replay Element's requests on R: an initial `/sync` of A,
   then `GET /members?not_membership=leave&at=<that next_batch>`: the union contains C as `invite` and D as `ban` with `reason` "spam" and
   `sender` A (what MemberList "Invited" and settings "Banned users" read, C9), although every member event is outside the timeline.
8. **Concurrency (real DB, at least 30 rounds, `Task.async` with a barrier).** A ban of D by A races 10 concurrent `/members` calls of B
   and initial `/sync`s of B: every answer is `200`, each lists D's slot exactly once as either `join` (read before the commit) or `ban`
   (after), never twice, never a `500`; every call STARTED after the ban's reply lists `ban`. A failure prints the round's sequence (no
   reason text).
9. **Source pins (unit).** (a) `build_state_events/3` callers: `member_slice: :events` exactly at the initial `/sync` paths, `full_state_room/2`,
   the `/initialSync` state and nowhere else; `/members` reads the slice through its own function; the summary / hierarchy callers and
   `fetch_delta_rooms/3` keep `:joined`. (b) `$synth_` appears only in the D8 (a) fallback. (c) `initial_sync_state_event/3` is gone; ONE
   public state-event renderer in `Nebu.Matrix.Http` is used by `/sync` state, `/members` and `/initialSync`. (d) `upgrade_room/2` writes
   no invitation row without the following `write_invite_event/5` call, and has no `:pg.get_local_members/1` and no `inspect(` in its
   invitation step. (e) `member_state_slice/2` and `direct_invitees/1` live in `Room.DB` (ADR-018, SQL inline) and are reached through the
   dispatcher's db seam.
10. **Logs (real DB; D5 as reworded by test review S-3).** Across the suite (captured logs at INFO and above): no `reason` text, no
    `displayname`, no content and no member list appears in any log line (user ids and the enum query values may appear, as for
    `/sync`); the DEBUG level is AC17 (a); the ERROR / WARNING lines of AC5 (e), AC6 (d) / (e) name the room id and the error class only.
11. **Regression.** `mix compile --warnings-as-errors`; `mix test` and `mix test --include integration` green apart from the known flaky
    families (`fj`, `fm`, those listed in the state-writer-redaction Debug Log) and the re-pins of AC15.
12. **Crash / restart (`.claude/rules/matrix-conventions.md`).** After the AC1 setup the room process is killed and restarted: the
    initial `/sync`, `/members` and `/initialSync` answers are identical (the slice is read from the database); a member event written
    after the restart appears.
13. **Docs (`server/test/nebu/matrix/membership_state_model_docs_test.exs`, new).** (a) `docs/matrix-api-scope.md`: the `/members` row
    (event-based slice, `membership` / `not_membership` with the AND label, "`at` is ignored: the current state is returned", `403` for
    non-joined users with the `gf` label "a user who left gets `403` on `/members`", the unknown-room `403` without a row, real ids and
    `unsigned`; the "no `unsigned` on them" sentence is gone); the `/initialSync` row (event-based state, `unsigned`, "no peeking (`gf`)",
    the "`visibility` is always `private`: known deviation (`gf`)" label, the ignored `limit` and the full-state label of D7
    recorded); the `/sync` row: "the initial `/sync` state lists every member slot
    (join, invite, ban, knock, leave) from the member events" and "the incremental `/sync` state keeps the joined slice of the room
    process" and "member slots other than `join` are capped at 10 000 per room in the `/sync` state, `/members` and `/initialSync`: Nebu bound"; the `/upgrade` row: "the upgrade invites the
    old joined members as real invite events in the upgrader's name" and "the upgrade's invitations are not charged to the pending caps";
    the `joined_members` row 🔲 "not routed" (`gh`), the "Compact map of joined members" ✅ claim is gone. (b)
    `docs/architecture/07-deployment.md`: a new paragraph "**Room membership state (story membership-state-model, follow-ups `fb`,
    `fl`).**" (what Element shows now: "Invited", "Banned users" after a reload; who can see bans and reasons: every joined member; the
    D4 cap and operator query **Q-ms** (`SELECT room_id, count(*) ...` over the latest non-join member slot per room, `HAVING count(*) >
    10000`), checked in a rolled-back transaction with fixture rows; upgrade invitations are real invite events; existing row-only
    invitations stay valid; no migration). (c) `CHANGELOG.md` `[Unreleased]`: `### Changed` the initial `/sync` state, `/members`
    (filters, real ids, `unsigned`, unknown room `403`), `/initialSync` (real ids, `unsigned`, unknown room `403`), upgrade invite events;
    `### Fixed` the scope doc `joined_members` claim. (d) `follow-ups.md`: `fb` rewritten as **CLOSED by story membership-state-model
    (date)** KEEPING its "Original item" text and every note, so the words pinned by the suites stay (`create_room_invites_docs_test.exs`:
    "build_state_events", "kick_user", "revoke", "strictly greater", "trusted_private_chat", "upgrade"; `member_prev_content_docs_test.exs`:
    "predecessor", "not marked", "upgrade"; `membership_write_limits_docs_test.exs`: "`fi`"; `moderation_routes_docs_test.exs` (its note):
    "revoke", "kick", "membership-state-model", "trusted_private_chat"; `sync_membership_partition_docs_test.exs`: "synthesized"); notes
    "**Note (membership-state-model, <date>):**" on `et`, `fl`, `fg`, `fi`, `fe`, `fp`, `fc`, `fh` (pinned words of those rows kept: `et`
    "visibility", "unban", "m.room.join_rules", "membership-state-model", "owner decision"; `fl` "unsigned.membership", "/members",
    "/initialSync", "redact", "`age` on `/messages`", "(e)", "65536", "130", "`unsigned.redacted_because`"); new rows `ge`, `gf`, `gg`, `gh`,
    `gi`; the id line "`ge`-`gi`: membership-state-model" and "unused: ... `gj` onward". (e) The suite pins (a)-(d), the Q-ms SQL against
    fixture rows, and the absence of the removed phrases ("Compact map of joined members", "no `unsigned` on them (no `replaces_state`").
14. **Labels in the scope doc (part of AC13 (a), pinned verbatim by the docs suite).** "membership and not_membership combine as AND:
    Synapse parity"; "`at` is ignored: the current state is returned"; "a user who left gets `403` on `/members` (spec: the members when
    you left): Nebu restriction"; "member slots other than `join` are capped at 10 000 per room in the `/sync` state, `/members` and
    `/initialSync`: Nebu bound"; "the incremental `/sync` state keeps the joined slice of the room process: member changes reach clients
    in the timeline, except in a `limited: true` delta"; "the spec text says 'or'"; "400 for values outside the enum: Nebu choice";
    "`visibility` is always `private`: known deviation (`gf`)"; "the `state` of `/initialSync` is the full current state,
    `messages.chunk` may repeat state events"; "`unsigned.replaces_state` / `prev_sender`: Synapse-compatible extension"; "state =
    current member state minus the timeline slots"; "invite blocking (`m.invite_permission_config`) is not applied, also not to upgrade
    invitations (`fh`)"; "GET state is not implemented (`bf`)"; "known, unchanged: an archived room is not served to its members (`gi`)"; "a member without a member event is
    served synthesized: legacy"; "state is event-based; legacy half states are visible as such (Q-half)"; "the upgrade invites the old
    joined members as real invite events in the upgrader's name: Nebu addition (the spec has no invite step)"; "the upgrade's
    invitations are not charged to the pending caps".
15. **Deliberate re-pins (Change Log old -> new per test; the re-pin diff is reviewed before the verify step; never weaken an assertion;
    any OTHER needed change is a finding: stop and report).** **(a) The id-line assertion "`ge` onward" -> "`gj` onward" in the TEN docs
    suites** `create_room_invites_docs_test.exs`, `create_room_presets_docs_test.exs`, `event_size_limit_docs_test.exs`,
    `member_prev_content_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`, `membership_write_limits_docs_test.exs`,
    `moderation_routes_docs_test.exs`, `sync_membership_partition_docs_test.exs`, `power_levels_docs_test.exs`,
    `state_writer_redaction_docs_test.exs` (each with a comment naming this story; EVERY new follow-up id forces this re-pin; the old
    "`ge` onward" is refuted by the new docs suite). (b) `member_prev_content_http_test.exs` l.681-704: `/members` and `/initialSync` state
    events now CARRY the three keys where a predecessor exists (the test's DM: B's join has the invite predecessor) and each runs ONE
    predecessor statement (was: none of the keys, zero statements; `fl` (c) closed). (c) `member_prev_content_http_test.exs` l.45
    `@baseline_initial_sync_statements` 48 -> 54 (per joined room `SET LOCAL statement_timeout` + the slice, inside `BEGIN` / `COMMIT`
    counted as the counter counts them; 3 rooms; 51 before security cycle 1; the dev records the measured value; a different delta is a
    finding). (d) `matrix_room_view_routes_test.exs` l.252-263 (unknown room `403 or 404`) stays green (now `403`);
    the `/members` shape test l.235-250 stays green. (e) Candidates the dev checks and records (old -> new or "green"): `/sync` suites that
    assert the exact member list of the initial `state` (`sync_*`, `matrix_client_compat_test.exs`, `direct_room_heroes*`), the
    `/initialSync` shape test (`matrix_client_compat_test.exs` l.2787ff: real ids instead of `$synth_`), upgrade suites that assert "no
    invite event" for the old members (`upgrade_room_test.exs` with its fake registry: the fake gains `write_invite/5` as a REAL fake that
    writes the row-backed event, never a stub), `moderation_routes_http_test.exs` l.1048 and `membership_write_limits_http_test.exs`
    l.767-810 (expected green; their "row-only" comments may be updated, not their assertions). Unchanged and green: `moderation_*`,
    `power_levels_*`, `state_writer_*`, `redaction_*` apart from statement baselines that count initial-sync statements (recorded). **(f)
    The unit suites the room resolution breaks (test review S-2; staged by the test side; old -> new in the Change Log):**
    `handler_test.exs` l.116 / l.126 (unknown room: `NOT_FOUND` -> `403 M_FORBIDDEN` "You are not a member of this room"; the fake gains
    `rooms_db_module().get_room_status/1`); `get_room_state_lazy_restart_test.exs` (4 tests: two need `get_room_status/1` in the fake, the
    two ghost-room tests `NOT_FOUND` -> `permission_denied` "You are not a member of this room", also for the SYSTEM caller, the D6 (a)
    decision); `matrix_room_view_routes_test.exs` l.163 ("members is routed", no DB: it now reaches the room-status read without a Repo;
    the assertion stays "routed, not the catch-all"). (g) **Older docs-suite words the scope-doc rewrite MUST keep (binding):** the
    `/sync` row keeps "row-only", "synthesized", `rooms.join` / `rooms.invite` / `rooms.leave`, `invite_state`, `m.room.create`,
    `is_direct`, `m.ignored_user_list`, "ban" (`sync_membership_partition_docs_test.exs` l.151-158); the `/upgrade` row keeps "deliberate
    deviation from the SHOULD NOT" (membership events not transferred; bans re-issued in the upgrader's name), "10 000 bans", "The room
    has too many bans to be upgraded", "before anything is written", "freeze first", `create_room`, "429"
    (`moderation_routes_docs_test.exs` l.259, l.481-482; `membership_write_limits_cycle1_docs_test.exs` l.79-80). The new docs suite
    `membership_state_model_docs_test.exs` is the contract for the AC13 / AC14 word lists.

16. **Oracle missing tests (HTTP real DB unless noted; each a separate test).**
    (a) An initial `/sync` of A where D's ban lies INSIDE the 20-event timeline: the ban is in the timeline, `state` has NO slot for D
        (the D11 label: no prior `join` is served); `state` replayed with the timeline ends with `ban`.
    (b) The `invite_state` of an upgrade invitation (B's `rooms.invite` entry for the new room) contains `m.room.create` (v1.16 MUST)
        and B's real invite event in STRIPPED form: exactly `type`, `state_key`, `sender`, `content` (no `event_id`, no `unsigned`).
    (c) An incremental `/sync` after a member's latest join carries `displayname` (a direct insert in an own room, `on_exit`
        cleanup): pins what the delta `state` re-sends for that slot (the synthesized `{"membership": "join"}` slot, or none) and names
        the `gg` risk in the test comment; never a `500`.
    (d) A `limited: true` incremental `/sync` (more than 20 new events, a ban of C inside the lost part of the gap): pins the current
        loss (the ban is neither in `state` nor in the timeline of that delta; `fc`, the D3 (d) label) and that the NEXT initial `/sync`
        lists C as `ban`. The lost part is the TAIL of the gap (the ban is written after the 25 messages; `fetch_events_since/3` reads
        the oldest 20 first, `fc` (a)).
    (e) After the upgrade, A's client-side `POST /rooms/{new}/invite` for B (already invited by the upgrade) -> `200 {}`, no second invite
        event, the upgrade answer was `200`; for a user the upgrade did NOT invite (left before the upgrade) -> a normal invite.
    (f) B ignores A (`m.ignored_user_list` with A) before A upgrades: the upgrade writes B's row and invite event, B's `/sync` does NOT list
        the new room in `rooms.invite` (sync-side suppression); C (not ignoring) gets it.
    (g) `m.invite_permission_config` `{"default_action": "block"}` as account data of C before the upgrade: C's upgrade invitation IS
        written and delivered (pins the `fh` label; the test comment names `fh`).
    (h) `/members` of a never-member on an existing room and `/members` on an unknown room id: byte-identical `403` bodies (no existence
        oracle).
    (i) Every `/members` chunk item carries `state_key` and `room_id` (and `event_id`, `type`, `sender`, `origin_server_ts`, `content`);
        a D8 (a) legacy entry carries `room_id` too.
    (j) `?membership=ban&membership=join` -> the last value (`join`) applies; `?membership=ban&membership=bogus` -> `400 M_INVALID_PARAM`.
    (k) A member slot whose latest content is unparseable / has an unknown membership (direct insert) appears under `?membership=leave`
        (normalised) and not under `?membership=join`; without any filter it is listed as `leave`.
    (l) `/initialSync`: a member slot whose event is also in `messages.chunk` (a join among the last 20 events) appears in BOTH (the D7
        full-state label; pinned, not deduplicated).
    (m) AC2 (e) also with `at=<prev_batch>` of a limited room of an initial `/sync` -> identical to no `at`.
    (n) (the `bf` pin) `GET /rooms/{r}/state`, `/state/m.room.member` and `/state/m.room.member/{D}` by A -> `404 M_NOT_FOUND`
        "Unrecognized request" (unchanged), no slice statement.

17. **Test review additions (HTTP real DB unless noted; each a separate test; nothing written on every refusal).**
    (a) (S-3) DEBUG logging on: `/members`, `/initialSync` and an initial `/sync` of a room with a ban `reason` marker and a join
        `displayname` marker: neither marker appears in any log line, and the `RequestLogger` payload line DOES appear (positive control).
    (b) (security) The initial `/sync` of an INVITEE (C) and of a BANNED user (D): C's `rooms.invite` entry carries only the stripped
        `invite_state` (no member list, no ban `reason`); D's `rooms.leave` entry carries no member slot of other users and no ban
        `reason` of another user; neither has a `rooms.join` entry for R.
    (c) (security) A `world_readable` room (`m.room.history_visibility` set) and a never-member: `/members` and `/initialSync` -> `403
        M_FORBIDDEN` (no peeking, D5 / D7).
    (d) A failing `get_room_status/1` (hook) on `/members` and `/initialSync` of a stopped room -> a handled `500` (generic body, value-free
        ERROR log), no process started.
    (e) AC2 (f) extended: `?membership[]=ban`, `?membership[x]=ban` (Plug parses a list / a map) -> `400 M_INVALID_PARAM` (the D6 fixed
        text), never a `500`.
    (f) (upgrade) A second failure injection: the invite-event call for one member exits (`:room_unavailable`): the upgrade answers
        `200`, that member's row is rejected again, the others are invited, one value-free WARNING.
    (g) (S-5, true non-goal: pins TODAY's behaviour) After an upgrade, for the OLD (archived, tombstoned, stopped) room: an old member's
        `/members` and `/initialSync` -> `404 M_NOT_FOUND` "Room not found"; a never-member's -> `403 M_FORBIDDEN` (the fixed text;
        corrected by security cycle 2, MINOR 1: a consequence of the D16 gate, which refuses a non-member before the start attempt; no
        existence signal for never-members); no process started; the old member's initial `/sync` -> `200`, the old room in no section (`rooms.join` / `invite` / `leave`), the new room
        in `rooms.invite`. Labelled "known, unchanged: an archived room is not served to its members (`gi`)".
    (h) (changed by security cycle 1, D16) `/members` and `/initialSync` of a known STOPPED room by a never-member: `403` (the fixed
        text) and the room process is NOT started (Horde lookup); by a joined member: `200` and the process is started.

## Security cycle 1 (code review cycle 0 + Kassandra: M-1 MEDIUM, L-1 LOW, MINOR-1..8; binding)

- **D14 (`members_read` rate tier, Kassandra M-1).** A new per-user tier `members_read`, one unit per `GET /rooms/{roomId}/members` and
  per `GET /rooms/{roomId}/initialSync`, charged FIRST (before the query validation and the room resolution, like `invite` / `join` /
  `moderation`); default `{60 per minute, burst 30}`; env `NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN` / `NEBU_RATE_LIMIT_MEMBERS_READ_BURST`
  (strictly positive int64, otherwise the default; the module invariants, a broken pair falls back and is named by `invalid_settings/0`,
  the boot warning), passed through by `docker-compose.yml` (empty = default), `NEBU_RATE_LIMIT_DISABLED=true` disables it: the SAME
  plumbing as the `moderation` tier of moderation-routes-atomic-ban (`RateLimitTiers.members_read/0`, `runtime.exs`). A `429
  M_LIMIT_EXCEEDED` with `retry_after_ms` (the existing limiter answer). The initial `/sync` is NOT charged. Separate bucket (not
  `moderation`, not `join`). Labelled "`/members` and `/initialSync` are rate-limited (`members_read` tier): divergence from the spec
  (no rate limit listed)". Element retries a failed `loadMembersIfNeeded` on the next member-list open (C9: `membersPromise` reset).
- **D15 (statement timeout for the slice, Kassandra M-1).** `member_state_slice/2` runs inside a transaction with `SET LOCAL
  statement_timeout = '2s'`; a timeout (SQLSTATE `57014`) and a `DBConnection.ConnectionError` (pool checkout drop / queue timeout; security cycle 2,
  MINOR 3) answer `503 M_UNAVAILABLE` "The member list is temporarily unavailable, try again" on `/members` and `/initialSync` (fixed
  text, value-free WARNING: room id + error class); the dead `reason == :timeout` clause is removed (or justified in a comment). On the
  `/sync` paths: SUPERSEDED by D18 (per-room degradation). **Predecessor pass (security cycle 2, MINOR 2, decided):** for `/members`
  and `/initialSync` the predecessor statement (`attach_predecessors_to_state_events/2`, `@sql_state_predecessors`, per-slot LATERAL,
  O(member events)) runs under its own `SET LOCAL statement_timeout = '2s'` in a timed transaction, with the same `503` mapping; if that
  is not clean, D15 and 08-concepts say "the slice read" only and `gg` gets the note (the dev records which). Cost documented: O(member events of the room), not O(users); operator query **Q-ms2** (total
  `m.room.member` events per room, `GROUP BY room_id ORDER BY count DESC LIMIT 20`) in 07-deployment next to Q-ms, with the Q-ms
  caveats (security cycle 2, MINOR 7: run off-peak, with a read-only role). MINOR-4
  (narrow columns first, `content` only for the winners) is OPTIONAL: only if the SQL stays correct and the ATDD tests stay green, else
  a note on `gg`.
- **D16 (no process start for a non-member, Kassandra L-1).** Before starting a STOPPED room, `/members` and `/initialSync` read the
  caller's latest membership from the database (`get_member_membership/2`); anything but `join` -> the fixed `403 M_FORBIDDEN` "You are
  not a member of this room" without a start; the system role is not affected. Replaces the D6 (a) label "starts its process".
- **D17 (MINOR fixes).** MINOR-1: a `get_state` timeout AFTER a lazy start is the same handled `503` as a timeout of the first
  `get_state` (`readable_room_state!` wraps the `ensure_room_without_lazy_create!` call). MINOR-3: a room id containing NUL (`%00`) is
  an unknown room: the fixed `403` BEFORE any DB read (no ERROR log, no `500`). MINOR-6: the upgrade invitation loop stops after the
  first `:room_unavailable` (the remaining rows are not written) and logs ONE value-free WARNING with the number skipped; per-member
  failure lines are DEBUG; other refusals continue the loop. MINOR-7: D9 (`direct_invitees` before the tombstone). MINOR-8: stale comments
  and banners (`get_room_state_lazy_restart_test.exs` header / steps / flunk text, `membership_state_http_test.exs` l.307, the banner of
  `get_room_members` / `readable_room_state!` in server.ex) rewritten. INFO-5 (corrected by security cycle 2, MINOR 1): labelled "old members of an
  archived room: 404; never-members: 403, no existence signal" (`gi` (e)). MINOR-2: docs (AC18 (h)).

18. **Security cycle 1 (HTTP real DB unless noted; each a separate test; nothing written / no process started on every refusal).**
    (a) `RateLimitTiers.members_read/0` returns `{60, 30}` by default and the configured pair; a broken pair falls back and is named by
        `invalid_settings/0` (unit); `docker-compose.yml` passes `NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN` and
        `NEBU_RATE_LIMIT_MEMBERS_READ_BURST` (config test pins both names).
    (b) With `rate_per_min 1, burst 2`: the third request of a user is `429 M_LIMIT_EXCEEDED` (any mix of `/members` and `/initialSync`
        draws from the SAME bucket); another user is not affected; the `moderation` / `join` / `invite` buckets are untouched; the
        initial `/sync` is not charged (unlimited initial syncs at the exhausted bucket stay `200`); `NEBU_RATE_LIMIT_DISABLED=true`
        disables it.
    (c) The charge comes FIRST: an exhausted bucket answers `429` also for an invalid `membership` value, an unknown room and a
        non-member (no `400` / `403`, no DB read, no process start).
    (d) A slice that exceeds the statement timeout (db hook: `pg_sleep` or a forced `57014`) -> `503 M_UNAVAILABLE` with the D15 fixed
        text on `/members` and `/initialSync`, and `503` for an initial `/sync`; never a joined-only answer; the WARNING is value-free;
        source pin: the slice statement runs after `SET LOCAL statement_timeout = '2s'` in one transaction.
    (e) (D16) see AC17 (h): a never-member's request on a stopped room starts no process; a member's starts it.
    (f) (MINOR-1, unit) a registry fake that answers `:noproc` first and times out on the second `get_state` -> the handled `503`, not a
        crash.
    (g) (MINOR-3) `GET /rooms/%00/members` and `GET /rooms/%00/initialSync` -> `403 M_FORBIDDEN` (the fixed text), no ERROR log line, no DB
        statement with the id.
    (h) (MINOR-2, docs suite) `docs/architecture/06-runtime.md` (the `/members` / `/initialSync` passage, about l.146-147, no longer says
        "run no predecessor statement and carry no unsigned"; the "GenServer state-backed" passage, about l.68-70, says "only for the
        incremental `/sync` and the summary paths") and `docs/architecture/09-decisions.md` (about l.181-184: no "synthetic event IDs", no
        `initial_sync_state_event/3`) each carry a note naming membership-state-model.
    (i) (MINOR-6) Two members whose invite-event call exits (`:room_unavailable`) during an upgrade: the loop stops after the first,
        exactly ONE WARNING with the skipped count, the upgrade answers `200`, no row without its event remains.
    (j) (MINOR-7) A failing `direct_invitees/1` -> `500` with NO tombstone, the old room NOT archived, no new room left behind (replaces
        AC6 (e)'s "before the first invitation").
    (k) (docs) The scope doc `/members` and `/initialSync` rows, 07-deployment and CHANGELOG contain EXACTLY these words (pinned by the
        docs suite): "`members_read`", "60 per minute, burst 30" (security cycle 2, MINOR 5: replaces the vacuous "60" / "30"),
        "`NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN`", "`NEBU_RATE_LIMIT_MEMBERS_READ_BURST`",
        "the initial `/sync` is not charged", "divergence from the spec (no rate limit listed)", "statement_timeout", "503 M_UNAVAILABLE",
        "O(member events", "Q-ms2"; 07-deployment additionally the Q-ms2 SQL (checked in a rolled-back transaction with fixture rows).

## Security cycle 2 (delta reviews of cycle 1: Kassandra M-1R, M-2 MEDIUM; code review MINOR 1-7; binding)

- **D18 (per-room degradation on the `/sync` paths, Kassandra M-2).** On `initial_join_rooms` (both paths) and `full_state_rooms` /
  `full_state_room`, a slice TIMEOUT (`57014`), a `DBConnection.ConnectionError` or a D19 overflow DEGRADES that ROOM only: it is served
  with the joined slice of the room process (the pre-story behaviour); per room a DEBUG line, per `/sync` response ONE aggregated
  value-free WARNING (count of degraded rooms + error classes + at most 10 room ids; security cycle 3, L-3); the rest of the response
  is unchanged. Labelled (security cycle 3, L-4) "member state of this room is joined-only until the client's next initial or
  `full_state` sync, or a `/members` call (lazy loading); a new member event refreshes only that member's slot; completeness gap, not a leak". Every OTHER slice error (the `500` class: a missing function on the real `Room.DB`, a SQL error) still fails the request
  (fail-closed, D1). `/members` and `/initialSync` do NOT degrade: the fixed `503 M_UNAVAILABLE` (timeout, ConnectionError, overflow).
  Rationale: one member of an open / auto-join room must not be able to make the initial `/sync` fail for every other member.
- **D19 (node-wide concurrency limit for slice reads, Kassandra M-1R).** At most N concurrent `member_state_slice/2` reads per NODE
  (default 3; app-env seam `:nebu, :member_slice_max_concurrency`, read per admission; env `NEBU_MEMBER_SLICE_MAX_CONCURRENCY`, a
  value-free boot warning for an invalid value or one not below the pool size). Implementation (security cycle 3, Kassandra M-3, replaces
  the polling ETS semaphore of cycle 2): `Nebu.Matrix.MemberSliceGate`, a SUPERVISED GenServer (a child of `Nebu.Application`, before
  Bandit) with the API `run(fun, wait_ms)`; admission is EXACT (the holders are the live MONITORED reader processes); a holder frees its
  slot in the `after` of `run/2` (a cast) and, when killed, on its `:DOWN` at once; a reader that finds the gate full is refused at once
  when `wait_ms` is 0 (`/members`, `/initialSync`) and otherwise waits in a FIFO queue (answered by the gate: the oldest waiter gets the
  next free slot; a timer of the gate answers `:overflow` at the caller's deadline; no polling), the queue is bounded at 4 x the limit
  (beyond it: refused at once); the `/sync` paths wait up to 1 s (one initial `/sync` reads up to 5 rooms in parallel); a gate that is
  not running answers `:overflow` (fail closed per D18). When the read is NOT started: `/sync` paths degrade that room (D18), `/members` and `/initialSync` answer the fixed `503 M_UNAVAILABLE`. Node-local by
  design, documented like the rate tiers (N nodes = N x the limit; it bounds the pool share, at most 3 of 10 connections per node,
  whatever route triggers it, incl. `/sync` without `since`, with a garbage `since` and `full_state=true`, which `members_read` does not
  charge). A single reader is never blocked. 07-deployment, load-bound paragraph: what bounds `/sync` (the node-wide limit + the 2 s
  timeout) and the Q-ms2 off-peak caveat. Labelled "slice reads are limited to 3 concurrent per node: node-local, like the rate tiers".
- **D20 (doc and test hygiene, code review MINOR 1-7, INFO).** MINOR 1: the archived-room re-pin (`membership_state_upgrade_http_test.exs`
  about l.300-312: a never-member's `/members` / `/initialSync` on an archived room `404` -> `403`) goes into the Change Log; AC17 (g),
  the D17 INFO-5 label and the scope doc `/members` row (`docs/matrix-api-scope.md` about l.101) say "old members of an archived room:
  404; never-members: 403, no existence signal". MINOR 4: 07-deployment (about l.413) "two more statements per joined room (`SET LOCAL`
  + the slice inside `BEGIN` / `COMMIT`)", D4 and AC15 (c) `54`, the `member_state_slice/2` `@doc` no longer says "ONE statement" (one
  slice statement in a timed transaction). MINOR 5: the 08-concepts tier table row heading that held only membership WRITE tiers is
  renamed to "room membership tiers (writes and the `members_read` read tier)", and the `RateLimitTiers` moduledoc says "membership
  tiers (writes: invite, join, moderation; read: members_read)"; the docs suite pins exactly "room membership tiers" (08-concepts),
  "members_read" and "60 per minute, burst 30" (moduledoc and 08-concepts). MINOR 6: AC18 (c) additionally counts statements: no room
  statement (no slice, no status, no membership read) after the `429`. INFO: the comment on `ensure_room_without_lazy_create!/2` (about
  server.ex l.4362-4368) becomes ONE paragraph and no longer claims it "covers PUT-state paths" for a NUL id (the router answers `400`
  there); the stale "RED PHASE" prose of `get_room_state_lazy_restart_test.exs` (about l.266) is removed; 07-deployment "Room upgrades":
  a dead new-room process leaves the remaining old members uninvited (`200`, one WARNING, MINOR-6 of cycle 1); the sorted invite order is
  pinned by a test; I-1 (pass `before_start` into the restart branch) and a `safe_call/1` helper for the four try / rescue / catch
  wrappers are optional (recorded if done).
- Notes (no new id; the id line stays "unused ... `gj` onward"): `gg` (D18 / D19: degradation instead of failure, the node-wide limit is
  node-local; `ensure_room_member!/2` of the receipt / read-marker routes (protected.ex about l.2302 / l.2356) still starts a stopped
  room before the membership check: a pre-existing sibling primitive, to align with D16 later); `gi` (a legacy member WITHOUT any member
  event gets `403` for a STOPPED room since D16, because the DB membership read finds no `join`: D8 (a) residual); `fp` (the `/sync`
  member-state load is bounded by D19 + the 2 s timeout, still no byte budget).

19. **Security cycle 2 (HTTP real DB unless noted; each a separate test).**
    (a) (D18) A slice timeout (db hook forcing `57014`) for ONE of three joined rooms on an initial `/sync`: `200`; that room's
        `state` has the joined slice only (no invite / ban slot), the other two rooms the full slice; exactly ONE WARNING with the room id
        and the error class (no reason text); the same with a `DBConnection.ConnectionError` and with `full_state=true` / a garbage
        `since` (the `full_state_rooms` path).
    (b) (D18) A NON-timeout slice error (hook: a SQL error) on an initial `/sync` -> the handled `500` (fail-closed stays).
    (c) (D18, MINOR 3) `/members` and `/initialSync` with a `ConnectionError` and with a timeout -> `503 M_UNAVAILABLE` with the fixed
        text; never a degraded answer.
    (d) (D19) With `:member_slice_max_concurrency` 2 and a hook that BLOCKS slice reads: 3 concurrent readers -> two reads run, the
        third does not start (statement count): a `/sync` reader degrades its room (`200`, joined slice), a `/members` / `/initialSync`
        reader gets `503 M_UNAVAILABLE`; after the hook releases, a new read runs.
    (e) (D19) The counter is released after a success, an error, a timeout and a KILLED reading process (`Process.exit(pid, :kill)` while
        blocked): afterwards the limit admits N new concurrent reads (no leak); a single reader at the limit 1 is never refused.
    (f) (MINOR 2) The `/members` / `/initialSync` predecessor statement runs under `SET LOCAL statement_timeout` (source pin / statement
        capture), a forced timeout there -> the fixed `503`; or, if the dev chose the reword, the docs pin "the slice read" (recorded).
    (g) (MINOR 1) A never-member's `/members` and `/initialSync` on an archived room -> `403 M_FORBIDDEN`; an old member's -> `404
        M_NOT_FOUND` (AC17 (g) as corrected); the scope doc row carries "old members of an archived room: 404; never-members: 403, no
        existence signal".
    (h) (MINOR 4, MINOR 5, MINOR 7, docs suite) the words of D20: "two more statements per joined room", "room membership tiers",
        "60 per minute, burst 30", "3 concurrent per node", "node-local", "joined-only until the client's next initial or `full_state`
        sync" (security cycle 3, L-4; was "joined-only until the read succeeds"), "off-peak", "read-only
        role" (07-deployment / 08-concepts / scope doc as named in D18-D20); the `member_state_slice/2` `@doc` has no "ONE statement".
    (i) (MINOR 6) AC18 (c) counts statements: after the `429` no room statement ran.
    (j) The sorted invite order of the upgrade loop (state_key ascending) is pinned.

## Acceptance Tests

- `server/test/nebu/matrix/membership_state_http_test.exs` (new, `:integration`, through `Nebu.Web.Router`): AC1, AC2, AC3, AC5 (c)-(e),
  AC7, AC10, AC12.
- `server/test/nebu/matrix/membership_state_upgrade_http_test.exs` (new, `:integration`): AC6.
- `server/test/nebu/matrix/room/member_state_slice_db_test.exs` (new, `:integration`, `Room.DB` directly): AC4, AC5 (a), (b).
- `server/test/nebu/matrix/membership_state_concurrency_test.exs` (new, `:integration`, `async: false`, tagged `:concurrency`): AC8.
- `server/test/nebu/matrix/membership_state_unit_test.exs` (new, unit: fakes, source / AST pins): AC5 (f), AC9.
- `server/test/nebu/matrix/membership_state_model_docs_test.exs` (new): AC13, AC14, and the refutation of "`ge` onward".
- AC16 (a), (c), (d), (h)-(n) in `membership_state_http_test.exs`; AC16 (b), (e)-(g) in `membership_state_upgrade_http_test.exs`.
- AC17 (a)-(e), (h) in `membership_state_http_test.exs`; AC17 (f), (g) in `membership_state_upgrade_http_test.exs`; AC15 (f) in the
  three named unit suites; AC15 (g) through the older docs suites and `membership_state_model_docs_test.exs`.
- Re-pinned: the suites of AC15.

- Security cycle 1: AC18 (a) in the rate-limit tier unit suite (`server/test/nebu/web/rate_limit_tiers_test.exs`) and the config /
  compose test; AC18 (b)-(e), (g) in `membership_state_http_test.exs` (or a new `membership_state_security_test.exs`, the ATDD agent's
  choice, named in the Change Log); AC18 (f) in `membership_state_unit_test.exs`; AC18 (i), (j) in
  `membership_state_upgrade_http_test.exs`; AC18 (h), (k) in `membership_state_model_docs_test.exs`.

- Security cycle 2: AC19 (a)-(e), (g), (i) in `membership_state_http_test.exs` (or the security suite of cycle 1, as recorded); AC19 (f) in
  `membership_state_http_test.exs` / `membership_state_unit_test.exs`; AC19 (j) and the archived-room re-pin in
  `membership_state_upgrade_http_test.exs`; AC19 (h) in `membership_state_model_docs_test.exs`.

## E2E verification

`ui: false` (no Nebu UI code; Element is the client). One new feature `e2e/features/element/room/membership-state.feature` with steps
`e2e/step-definitions/element/membership-state.steps.ts` (users alex, marie, tom, kai of the global setup; reasons are plain texts of the
feature; the steps never print a token, a reason or message content), run on a FRESH, isolated stack built from THIS commit:

- **`@membership-state-api @regression`** (the guard, no UI selectors): alex creates a `public` room "membership-state-api" through the
  API; marie and tom join; alex invites kai; alex bans tom with the reason "e2e ban"; alex sends 25 messages; marie's INITIAL `/sync`
  (no `since`) lists in `rooms.join[room].state.events` kai as `invite` (sender alex) and tom as `ban` (sender alex, `reason` "e2e ban"),
  both with real event ids; marie's `GET /members?not_membership=leave&at=<her next_batch>` contains alex, marie (join), kai (invite),
  tom (ban); `?membership=ban` contains only tom; tom's and kai's `/members` -> `403 M_FORBIDDEN`; alex upgrades the room (`POST
  /upgrade`, `200`); marie's next `/sync` lists the new room in `rooms.invite` whose `invite_state` contains the invite event by alex;
  alex's `/members?membership=invite` on the new room contains marie.
- **`@membership-state-ui @regression @ui`**: marie logs in via Element Web (a fresh login: initial sync), navigates to
  "membership-state-api" (the old room, or the replacement room after the API scenario: the feature creates its own room
  "membership-state-ui" with the same setup, invite of kai and ban of tom, 25 messages), opens the room info / "People" panel: an
  "Invited" section lists kai; opens Room settings > "Roles & Permissions": the fieldset "Banned users" lists tom with "Reason: e2e ban".
  Asserted additionally SERVER-side: the server log shows `GET .../members?not_membership=leave&at=...` `200` for marie. VERIFIED in the
  Element 1.12.15 bundle (C9): `lazyLoadMembers` is always on, the member list loads `/members?not_membership=leave&at=<sync token>`
  once per room, the list shows joined then invited members under "Invited" (`member_list|invited_label`), "Banned users"
  (`room_settings|permissions|banned_users_section`) reads `room.getMembersWithMembership("ban")` with "Reason" (`ban_reason`).
  UNVERIFIED: the selectors of the room-info / People panel and of the settings dialog tab in Element 1.12.15 (accessible names of the
  header button, the "People" entry, the "Roles & Permissions" tab). If the first real run fails for a UI reason (the server log shows the
  `/members` `200` and the API scenario is green), tag the UI scenario `@known-failure` with a new row in `e2e/KNOWN-FAILURES.md` (next
  free K id: **K13** — K8 and K10 are retired paragraphs, K11 is reserved by the moderation plan, K12 by the redaction feature; the
  headers of `membership-state.feature` / `membership-state.steps.ts` name K13; cause: Element room-info / settings selectors
  unverified) and keep the API scenario as the guard; a server answer other than `200` on `/members` is a finding.

Run (the orchestrator; evidence, not a UI gate): 0. `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000;
`COMPOSE_PROJECT_NAME=nebu-oauth-e2e`. 1. **Run A (CI parity):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh
element`. Pass: every scenario of the default tag expression green (the two new ones, or the UI one moved to the known-failure list)
except the rows of `e2e/KNOWN-FAILURES.md`; then save the server log, count `RequestLogger` lines with status `500` (pass: zero) and with
path `/members` (record the statuses: only `200` / the expected `403`s); `docker compose -p nebu-oauth-e2e down -v --remove-orphans`. 2.
Logs: `_bmad-output/nebu/epics/oauth-broker/step-results/membership-state-model/e2e-run-a.log` and `e2e-run-a-server.log`; update the
"Status of the last complete run" line of `e2e/KNOWN-FAILURES.md`.

## Tasks

- [x] `Room.DB`: `member_state_slice/2` (D1, D4: the D3 order, normalised membership, both JSONB forms, filters and the cap in SQL) and
      `direct_invitees/1` (D9).
- [x] `EventDispatcher.Server`: `build_state_events/3` option `member_slice: :events | :joined` (D3) with the D8 fallbacks; the
      initial-`/sync` callers and `full_state_room/2` on `:events`; `get_room_members/2` for `/members` (D6 (d)); the `/initialSync` state
      (D7); the room resolution `ensure_room_without_lazy_create!/2` and the explicit `M_FORBIDDEN` without ids for both reads (D5, D6 (a));
      the fail-closed seam rule (D1).
- [x] `upgrade_room/2` step 6 through `write_invite_event/5` with the compensation, `is_direct`, `unforget_room/2`, `wake_invitee/2`, the
      value-free WARNING (D9).
- [x] `protected.ex`: `/members` query validation and response (D6 (b), (c)); `/initialSync` state rendering; `initial_sync_state_event/3`
      removed (D10).
- [x] `Http`: one public state-event renderer (with `room_id`) shared by `/sync`, `/members`, `/initialSync` (D10).
- [x] Tests (Acceptance Tests) incl. the re-pins of AC15 (Change Log, old -> new).
- [x] Docs AC13 / AC14 (scope doc incl. the `joined_members` correction, 07-deployment incl. Q-ms checked in a rolled-back transaction,
      CHANGELOG, follow-ups incl. the id line and the notes on `fh`, `gf`).
- [x] Test review: AC15 (f) re-pins, AC15 (g) kept docs words, AC17 (a)-(h) (AC17 (g) pins today's archived-room answers: no change
      to `get_messages` / `get_room_state/2` / `get_room_members/2` for archived rooms), the binding seams of D1 / D3 / D6 (d) / D9 / D10.
- [x] Oracle gate: the missing tests AC16 (a)-(n) and the Oracle labels of D3 (d), D4, D6, D7, D9, D10, D11, D13 in the scope doc (AC14).
- [x] E2E feature + steps (staged by ATDD); [ ] run A (orchestrator).
- [x] **Security cycle 1 (D14-D17, AC18, AC17 (h) changed):**
  - [x] `members_read` tier (`RateLimitTiers`, `runtime.exs`, `docker-compose.yml`, the boot warning, the charge first in both routes) (D14).
  - [x] `SET LOCAL statement_timeout = '2s'` for the slice, the `503` mapping, Q-ms2 (D15); MINOR-4 optional.
  - [x] the DB membership read before a stopped-room start (D16).
  - [x] MINOR-1, -3, -6, -7, -8 (D17, D9); MINOR-2 docs (06-runtime, 09-decisions); docs words of AC18 (k); notes on `gg`, `fp`, `gb`.
- [x] **Security cycle 2 (D18-D20, AC19, AC5 (e) / AC17 (g) / AC18 (k) / AC15 (c) changed):**
  - [x] per-room degradation on the `/sync` paths for timeout / ConnectionError / overflow, `503` for `/members` / `/initialSync` (D18).
  - [x] node-wide slice concurrency limit `:nebu, :member_slice_max_concurrency` (default 3), counter released on every exit (D19).
  - [x] predecessor pass under its own timeout or the D15 reword (MINOR 2); ConnectionError mapping (MINOR 3); docs / `@doc` / moduledoc
        words (MINOR 1, 4, 5, 7); AC18 (c) statement count (MINOR 6); INFO hygiene; notes on `gg`, `gi`, `fp`; the archived-room re-pin in
        the Change Log.

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (the two
  reads are SQL inline in `Room.DB`; the decisions stay in the dispatcher; no repository / service layer), ADR-019 / ADR-021 (plain
  in-process modules), ADR-020 (no new cross-domain call: the Admin part is `ge`; `Nebu.Admin` does not call the new read in this story),
  cluster-safety (no node-local cache of the slice: it is read from the database per request; the upgrade wake uses `:pg.get_members/1`;
  one process per room via `Horde.Registry`; no `:global`).
- **One rule for "the latest member event".** The slice uses `@sql_member_rank` / `@sql_membership_normalised` of `Room.DB` (reuse the
  module attributes; no second rank definition). A same-millisecond `join` + `ban` is a `ban` everywhere.
- **Fail closed.** For the real `Room.DB` a failing or missing slice read is a `500`, never a joined-only state (a client would drop the
  bans from its view and offer no Unban); the joined fallback exists only for test db modules (D1). The `direct_invitees/1` failure fails
  the upgrade before any invitation (D9).
- **Writers stay single.** No new writer: the upgrade's invite events go through `Room.Server.write_invite/5`; nothing in this story calls
  `emit_state_event_at/6` / `emit_state_event/5` or inserts an `m.room.member` event outside the room process (the state-writer-redaction
  source pin of the `emit_state_event_at/6` callers stays green). Never `GenServer.call` a room process from inside its own call.
- **Who sees what (D5).** Only joined users read the slice. Do not widen access (no `/members` for invitees, no peeking) and do not narrow
  the content (bans and reasons are state). Never log the slice, a `reason`, a `displayname` or a query value (No Sensitive Data in Logs
  Law); logs carry the room id and `db_error_class/1` only.
- **Fixed texts, explicit errcodes.** The `403` of both reads sets `errcode: "M_FORBIDDEN"` and the fixed text "You are not a member of
  this room" at the source (no caller / room id in the message); the two `400` texts of D6 are fixed.
- **Bounds.** The cap of D4 and the filters are applied in SQL (never "load all, filter in the BEAM"); one slice statement per joined room
  of an initial `/sync`, one per `/members` / `/initialSync`.
- **Element.** Element always lazy-loads members and calls `/members?not_membership=leave&at=<sync token>`; a slot from `/sync` wins over
  `/members` in the js-sdk, so `/sync` and `/members` must agree (one read rule). Do not reject unknown `at` values.
- **Binding signatures and seams (test review S-1, D-1): the suites' moduledocs are binding.** `member_state_slice(room_id, opts)`
  (`:membership`, `:not_membership`, `:other_cap`; ordered join, invite, ban, knock, leave, `state_key`; `content` `%{}` when
  unparseable; the `/* member_state_slice */` marker) through `messages_db_module()`; `get_room_status/1` and `direct_invitees/1`
  through `rooms_db_module()`; `build_state_events/4` with the literal `member_slice: :events` at the call sites; `get_room_members/2`
  (plain map `%{room_id, membership, not_membership}` -> `%Core.GetRoomStateResponse{state_events: ...}`); `Http.state_event_json/3`
  (`$synth_` only there); the upgrade failure seam `:room_manager` `db_module` `apply_member_change/4` with
  `require_pending_invitation`. Do NOT rename the AST-pinned functions: `initial_join_rooms` (two call sites), `full_state_room`,
  `get_room_state`, `get_room_members/2`, `fetch_delta_rooms`, the three summary callers, `insert_invitation_row`,
  `admin_add_room_member`, `wake_invitee`. Both `get_room_members/2` and `get_room_state/2` set `errcode: "M_FORBIDDEN"` and the fixed text
  at the source; the "set_room_state: ..." log text of `ensure_room_without_lazy_create!/2` is reworded for the read paths (cosmetic).
  Record the measured statement counts (baseline 54 since security cycle 1) and the three re-pinned unit suites (AC15 (f)) in the Change Log.
- **Previous story learnings** (state-writer-redaction, moderation-routes-atomic-ban, member-event-prev-content): real-DB tests for the
  read rule, the race and the fail-closed paths; deterministic gap tests through db hooks; `tick/0` only in own rooms (`fj`); sessions
  minted beyond the refresh lookahead; docs suites pin earlier texts: rewrite `fb` in the CLOSED style keeping the "Original item" and
  every note; the id line re-pin in all TEN docs suites (AC15 (a)); real fakes, never stubs; the e2e on a fresh isolated stack.

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/api.json` (`/rooms/{roomId}/members`, `/rooms/{roomId}/initialSync`,
  `/rooms/{roomId}/joined_members`, `/sync`), `client-server-api/index.html` ("Lazy-loading room members", `ClientEvent.unsigned`,
  `m.room.member`, "Room Upgrades" Server behaviour).
- Code: `server/lib/nebu/matrix/event_dispatcher/server.ex` l.2437-2638, l.3058-3304, l.4038-4110, l.4545-4720, l.5036-5130,
  l.5804-5977, l.6011-6202, l.7603-7830, l.8047; `server/lib/nebu/matrix/room/server.ex` l.57-58, l.160-200, l.434-500, l.613-624;
  `server/lib/nebu/matrix/room/db.ex` l.106-120, l.200-214, l.1053-1080, l.1473-1505, l.1611-1660, l.1740-1830, l.2044-2060;
  `server/lib/nebu/matrix/http.ex` l.155-296, l.355-392; `server/lib/nebu/web/router/protected.ex` l.1702-1777, l.2242-2270;
  `server/lib/pb/core.pb.ex` l.318-333; `server/priv/migrations/000001_init.up.sql` l.228.
- Element 1.12.15 (source maps, this session's scratchpad `element-bundle/`): element-web `MatrixClientPeg.ts` l.297-300;
  `structures/RoomView.tsx` l.1526-1540; `stores/MemberListStore.ts` l.70-185; `viewmodels/memberlist/MemberListViewModel.tsx` l.131-175;
  `settings/tabs/room/RolesRoomSettingsTab.tsx` l.74-120, l.366-390; matrix-js-sdk `client.ts` l.6928-6950, l.7085-7089;
  `models/room.ts` l.1048-1135; `models/room-state.ts` l.~790-830; `sync.ts` l.406; i18n `en_EN` (`member_list|invited_label`,
  `room_settings|permissions|banned_users_section`, `ban_reason`, `banned_by`).
- Stories: `moderation-routes-atomic-ban.md` ("Sizing and split" story 2, D7, D11), `sync-membership-partition.md` (D3, D4),
  `member-event-prev-content.md` (D1, D10, D11), `state-writer-redaction.md` (D6 M1 rule, D10 (a), AC15 (a)).
- Follow-ups: `fb`, `et`, `fl`, `fg`, `fi`, `fe`, `fp`, `fc`, `ex`, `ew`, `eu`, `ef`, `fq`, `fr`, `bf`, `es`, `fk` in
  `docs/stories/oauth-broker/follow-ups.md`.
- Conventions: `CLAUDE.md`, `.claude/rules/matrix-conventions.md` (crash / restart test), `skills/nebu-conventions/cluster-safety/`,
  `skills/nebu-conventions/no-domain-model/`, `skills/nebu-conventions/sql-placement/`, `skills/nebu-conventions/security-rules/`.

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev step, nebu-dev-story, pipeline step 4, cycle 0).

### Debug Log

- Starting point: the throwaway ATDD reference (`scratchpad/atdd/membership/`, diffs in `scratchpad/atdd/handoff-membership/`), read as a guide and
  rewritten piece by piece. Changed against the reference: the member read of `get_room_state/2` / `get_room_members/2` (`readable_room_state!/3`)
  resolves a room that is not running through the existing `ensure_room_without_lazy_create!/2` (D6 (a), the story's binding seam) instead of a second
  copy of the status read; its ERROR line is reworded ("room resolution: ..."; was "set_room_state: ..."); a running room still costs no status read
  (AC2 (i)). The D8 (a) legacy entry is added only for a member of the process set WITHOUT a captured join identity and without a slice row (the
  reference used "no slice row" alone, which under a `/members` filter would synthesize a join for a member of a legacy half state whose latest event
  the filter left out). The upgrade invitation (`invite_upgraded_member/4`) treats a unique violation whose latest membership is `invite` as already
  invited (an identical concurrent invite of Element's upgrade dialog; no compensation), as the invite path does; a failed compensation logs the
  existing half-invitation ERROR. No archived-room read (the S-5 correction: archived rooms answer as before, 404). Outdated comments of
  `build_state_events` / `attach_predecessors_to_state_events/2` / `get_room_state/2` (the `/members` caller) rewritten. Docs: the reference docs
  diff applied, then the `/members` row rewritten, the rows `ge`-`gi` completed with the story text (incl. `gi` (e)), the `fp` note completed, Q-ms
  rewritten with the D3 tie rank, a sentence in 08-concepts (rate-limit section).
- `server/lib` size: 425 insertions, 216 deletions (641 changed lines, `git diff --numstat`; 30 of the deletions are the replaced comment block of
  `build_joined_rooms/2`), below the ~650 stop line.
- Measured statement counts: initial `/sync` of 3 rooms 51 (`@baseline_initial_sync_statements` 48 -> 51, one slice statement per joined room, the
  expected delta); `/members` on a running room: 2 room-data statements (slice + predecessor), on a stopped room 3 (+ the status read);
  `/initialSync`: 1 slice + 1 predecessor statement for its state; summary / hierarchy / incremental `/sync`: 0 slice statements.
- **Q-ms SQL evidence** (the 07-deployment query verbatim, inside `BEGIN ... ROLLBACK` on the throwaway database `nebu-oauth-pg`, 2026-10-20):
  fixtures: `!qmsover:dev.local` with 10 001 users whose only member event is `leave`, `!qmsexact:dev.local` with 10 000 bans plus one user with a
  same-millisecond `join` + `ban` (the D3 rank makes the ban the latest). Listed: exactly the two rooms, `non_join_slots` 10001 each; after the ROLLBACK
  0 fixture rooms. The staged docs test runs the same SQL against its own fixtures (over / exact / joined / mixed), green.
- Runs (`MIX_BUILD_PATH=/tmp/nebu_build` in named build volumes, `--warnings-as-errors`):
  * Elixir 1.20: `mix compile` clean; the new suites (unit, slice DB, HTTP, upgrade, concurrency, docs) and `member_prev_content_http_test.exs`:
    178 tests green; every docs suite (30 files that read the docs): 730 tests green.
  * no-DB `mix test` (the `test-unit-elixir` job): 6414 passed, 7 skipped, 0 failures.
  * `mix test --include integration` on a FRESH throwaway database (own container and network, `regression_sync_load_test.exs` moved aside and
    restored): 10412 tests, 22 failures: RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 3, WarRoom 1, TemporaryCaptureManager 1,
    SsoLogin 1, LogStore.Retention 1. Each file re-run in isolation on this tree AND on a `git archive` copy of HEAD `bac58977` against the same
    database: identical results on both (RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 3, WarRoom 1, TemporaryCaptureManager 3,
    SsoLogin 1, LogStore.Retention 2): pre-existing, not caused by this story.
  * Elixir 1.19 (`elixir:1.19-alpine`): `mix compile --force --warnings-as-errors` without a warning in `lib/`; the new and changed suites plus
    `upgrade_room_test`, `upgrade_room_error_handling_test`, `membership_write_limits_http_test`: 537 tests, 0 failures; `matrix_client_compat_test`
    (66) and `moderation_routes_http_test` (133) green in isolation (a first combined run had `tick/0` timeouts in them: the sync tick family).
  * Test-name length (`namelen.py`, > 240): none.

### Completion Notes List

- **Kassandra narrow review of the GenServer gate (M-3 CLOSED; L-1, L-3', I-1, I-4 applied, 2026-10-20):** L-1 a caller whose acquire
  call times out casts `{:cancel, self()}` (one sender: after its `{:acquire, ...}`): the gate drops its queued entries and frees /
  demonitors every slot of that pid, so a late grant is not held by a keep-alive connection process; the comment is corrected. L-3' the
  `/sync` wait is ONE budget per process and response (`slice_wait_ms/1`, the deadline in the process dictionary, reset by
  `with_degraded_rooms_report/1`, spent at the first overflow): `full_state_rooms` reads its rooms in one process and no longer waits 1 s
  per room. I-1 a catch-all `handle_info/2` (debug). I-4 docs: "Three bounds", "a new member event refreshes only that member's slot"
  (07-deployment, scope doc, story D18 / AC19 (h), `gg`; the pinned prefix "joined-only until the client's next initial or `full_state`
  sync" is unchanged). Tests: the suspended-gate cancel test and the catch-all in `member_slice_gate_test.exs`; a `full_state=true` sync
  of 12 joined rooms with the gate (limit 1) held answers 200 in about the 1 s budget with every room degraded and ONE aggregated
  warning (`membership_state_gate_http_test.exs`). The throughput bar of the gate test is 60 % of the measured ideal (80 % when idle;
  measured 402-498 of 407-440 idle, 243 of 390 once while the integration job shared the CPUs).
- `server/lib` total (vs HEAD `bac58977`): 949 insertions, 272 deletions (1221 changed lines).
- Runs: gate / gate-http / docs / HTTP suites 133 green; no-DB unit run 6444 passed, 0 failures (a first run had the throughput bar
  failing under the parallel integration job: lowered, see above); fresh-DB integration 10441/10466: 25 failures: RoomsFallbackName 12,
  TraceMapNodeControls 2, WarRoom 1, TemporaryCapture 2, LogStore.Retention 2 (identical on a `git archive` copy of HEAD) and 6 docs
  Q-query tests (EventSizeLimitDocs 2, MembershipStateModelDocs 2, PowerLevelsDocs 1, StateWriterRedactionDocs 1) answering `42P01
  relation does not exist` in that run only (the migration of the fresh database coincided with a hex fetch failure; all four suites
  green alone on the same database, 146 tests); 1.19 `compile --force` clean, the changed suites + upgrade / limits 617 tests, 0
  failures; test names > 240: none.

- **Security cycle 3 (final, 2026-10-20, dev step):** M-3: `Nebu.Matrix.MemberSliceGate` rewritten as a supervised GenServer (child of
  `Nebu.Application` before Bandit; the ETS table, `init_table/0` and the polling / `reclaim_dead` scan are gone): exact admission over
  MONITORED holders, release by cast in the `after` and on `:DOWN`, a FIFO queue bounded at 4 x the limit with the caller's deadline as
  a gate timer (no polling), `wait_ms` 0 never queues, a gate that is down answers `:overflow`; same `run(fun, wait_ms)`, seam and env
  var; the boot warning also names a limit not below the pool size. L-3: `with_degraded_rooms_report/1` around `get_initial_sync/2` and
  `get_sync_delta/2` collects the degraded rooms (the room tasks report to the request process) and logs ONE WARNING per response (count,
  classes, at most 10 room ids); per room DEBUG. L-4 / MINOR-4/5 docs: the degradation label ("until the client's next initial or
  `full_state` sync, or a `/members` call (lazy loading); a new member event refreshes only that member's slot"), "what bounds `/sync`" names the slice only (the lenient
  predecessor pass is neither gated nor timed, note on `gg`), all 503 causes in the `/members` row, the killed-mid-query backend caveat,
  sizing guidance (07-deployment, docker-compose), the duplicated label inside the `/initialSync` row dropped; `RateLimitTiers`
  moduledoc table aligned; `gg` note (L-2 not done, residuals). MINOR-2: `regression_sync_load_test.exs` restored EXACTLY to HEAD.
  MINOR-6: `with_events_locked/1` in `member_state_slice_db_test.exs`. New tests: `member_slice_gate_test.exs` (N+k simultaneous
  readers at 3: exactly 3 run, 7 overflow; FIFO order within the deadline and never above the limit; a wait-0 probe succeeds while a
  slot is free and after a crowd of waiters; the waiter bound; a wait that succeeds after 100 ms and one that times out after ~200 ms;
  a killed holder frees its slot at once; throughput: 500 readers with 5 ms reads retrying for 1 s complete >= 80 % of the measured
  ideal) and `membership_state_gate_http_test.exs` (a 5-room parallel initial `/sync` at the default limit 3, slice reads slowed to
  300 ms: every room complete, no degradation).
- Gate numbers (security cycle 3): the throughput test completed 402-498 reads in 1 s against a measured ideal of 407-440 (3 slots x
  1000 ms / ~7 ms per 5 ms read); a single-attempt burst like the reviewer's simulation (`run/2`, wait 1000 ms, limit 3): 100 / 1000 /
  5000 simultaneous readers (5 ms) -> 15 / 18 / 30 served, the rest refused within 37 / 45 / 67 ms wall, max concurrency 3, a wait-0
  probe afterwards served (the cycle-2 polling gate: 305 of 600 slots at 1000 waiters, 9 at 5000, 5.9 s wall). The burst numbers are the
  4 x limit queue bound by design: a burst is refused fast instead of queueing.
- `server/lib` total after security cycle 3 (vs HEAD `bac58977`, `git diff --numstat`): 901 insertions, 272 deletions (1173).
- Security cycle 3 runs (`--warnings-as-errors`): 1.20 new / changed suites + docs suites 975 green; no-DB unit run 6442 passed, 0
  failures; fresh-DB integration 10441/10463: 22 failures, all known families, each re-run alone on this tree and on a `git archive`
  copy of HEAD with identical results (RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 2 (3 alone), TemporaryCapture 2
  (3 alone), WarRoom 1, SsoLogin 1, LogStore.Retention 1); no "served joined-only" warning in the full run; 1.19 `compile --force`
  clean, 23 changed suites + upgrade / limits: 614 tests, 0 failures; test names > 240: none, the story's suites <= 230.

- **Security cycle 2 (2026-10-20, dev step):** D18: `member_slice_events/4` takes `read: :sync | :request`; on the `/sync` paths
  (`initial_join_rooms` both paths, `full_state_room/2`; `build_state_events` default `read: :sync`) a slice timeout (`57014`), a
  `DBConnection.ConnectionError` (returned or raised: the rescue of `read_member_slice/4`) or a gate overflow serves that room with the
  joined slice and ONE value-free WARNING ("... were not read (<class>), the room is served joined-only"); `/members` and `/initialSync`
  (`read: :request`) raise the fixed 503 through ONE attribute helper (`member_list_unavailable/2`); every other class is the 500. The
  dead `reason == :timeout` clause is gone (`member_read_unavailable?/1`: 57014, ConnectionError, `:overflow`). D19: new plain module
  `Nebu.Matrix.MemberSliceGate` (one row per reader in a public ETS table created at boot by `Nebu.Application`, deleted in an `after`;
  the row of a KILLED reader is reclaimed by the next reader that finds the gate full; size-based, so a crash between steps cannot skew a
  counter); default 3, `:nebu, :member_slice_max_concurrency`, AND (coordinator decision, beyond the story's "no env var")
  `NEBU_MEMBER_SLICE_MAX_CONCURRENCY` in `runtime.exs` / `docker-compose.yml` with a value-free boot warning
  (`MemberSliceGate.warn_invalid_setting/0`); new unit suite `member_slice_gate_test.exs` (default, app key, runtime.exs mapping, boot
  warning, refuse / release / reclaim). **Deviation to review:** a `/sync` read WAITS up to 1 s for a free slot before it degrades (a
  `/members` / `/initialSync` read never waits): one initial `/sync` reads up to 5 rooms in parallel (`Task.async_stream`
  `max_concurrency: 5`), so with an immediate refusal an ordinary user with 4+ rooms would get randomly degraded rooms; the AC19 (d) test
  still sees the degraded room (its holders block longer). D20 / MINOR 2: `Room.DB.fetch_state_predecessors/2` `strict: true` (BEGIN, SET
  LOCAL 2 s, the lookup, COMMIT; `{:ok, map}` / `{:error, reason}`), used by `/members` and `/initialSync`
  (`fetch_state_predecessors_strict!/3`: 503 / 500 like the slice); `/sync` keeps the lenient one-statement lookup. Docs: 07-deployment
  (two more statements per joined room, what bounds `/sync`, the degradation label, Q-ms / Q-ms2 off-peak + read-only role, the dead new
  room of an upgrade), 08-concepts heading "room membership tiers", `RateLimitTiers` moduledoc, scope doc (`/sync` degradation label,
  the archived-room answers), CHANGELOG, notes on `fp`, `gg` (incl. `ensure_room_member!/2`), `gi` (legacy member 403 on a stopped room);
  the `ensure_room_without_lazy_create!` comment is one paragraph (no PUT-state claim). Not done (optional): I-1, the `safe_call/1` helper.
- `server/lib` total after security cycle 2 (vs HEAD `bac58977`, `git diff --numstat`, incl. the new `member_slice_gate.ex`): 800
  insertions, 264 deletions (1064 changed lines).
- Security cycle 2 runs (`--warnings-as-errors`): 1.20 the new and changed suites + docs suites 891 green (the 15 red tests of the
  ATDD step green); no-DB unit run 6435 passed, 0 failures; fresh-DB integration 10425/10455: 30 failures, all in known families and
  each re-run in isolation AND on a `git archive` copy of HEAD: ModerationFixCycle1Http 5 and MembershipWriteLimitsHttp 1 (`tick/0` /
  timing in the full run; green in isolation on both trees), AdminStaleRooms 1 (flaky: 4/4 and 3/4 on re-runs), RoomsFallbackName 12,
  AdminOidcLogin 3, TraceMapNodeControls 3, TemporaryCapture 3, SsoLogin 1, LogStore.Retention 1 (identical or worse on HEAD). No
  "served joined-only" warning appeared in the full run. `regression_sync_load_test.exs` (run separately) times out on this tree AND on
  HEAD (pre-existing in this environment); its setup now lifts the gate. 1.19 `compile --force` clean, 22 changed suites + upgrade /
  limits: 606 tests, 0 failures; test names > 240: none (the story's suites <= 230).

- **Security cycle 1 (2026-10-20, dev step):** D14 `members_read` tier (`RateLimitTiers.members_read/0`, default `{60, 30}`, the
  two env names in `runtime.exs` and `docker-compose.yml` (comment: "the five tiers"), the existing boot warning / `invalid_settings/0` cover
  it through `@env`; the charge wraps the WHOLE route body of `/members` and `/initialSync` (`with_membership_charge/3`), so it comes before
  the query validation and the room resolution; the initial `/sync` is not charged). D15 `Room.DB.member_state_slice/2` runs `SET LOCAL
  statement_timeout = '2s'` and the slice in ONE `Repo.transaction` (a failure rolls back with the reason); the dispatcher maps SQLSTATE
  `57014` (or `:timeout`) to `503 M_UNAVAILABLE` "The member list is temporarily unavailable, try again" with ONE value-free WARNING (room id,
  `postgres 57014`); the initial `/sync` of such a room answers that 503 as a whole. D16 `readable_room_state!/3` -> `start_readable_room!/3`
  -> `ensure_room_without_lazy_create!/3` with a `before_start` gate (`joined_before_start!/2`: `get_member_membership/2` through the rooms
  db seam; not `join` -> the fixed 403 without a start; a failing read -> handled 500; the system role is not gated). D17: MINOR-1 a
  `:timeout` exit after the lazy start is the same handled 503 (`room_unavailable!/0`); MINOR-3 a NUL byte in the id is the fixed 403 in
  `ensure_room_without_lazy_create!/3` before any read (covers the PUT-state paths too); MINOR-6 `invite_upgraded_members/4` (members in a
  sorted order) stops after the first `:room_unavailable` with ONE WARNING naming the number skipped (the dead member's row is taken back,
  its own line is DEBUG); other refusals stay per member; MINOR-7 `direct_invitees!/1` moved before the tombstone (a failing read writes
  nothing); MINOR-8 the banner "the member reads" above `get_room_members/2` / `readable_room_state!/3`; INFO-2 the D6 order has ONE
  definition (`Room.DB.member_slice_class/1`, also used by the dispatcher; the attribute and the dispatcher clauses removed), the 500 of
  the member reads is raised by `room_state_unavailable!/0` only (the 403 by `not_a_member!/0`). MINOR-4 (narrow columns first) NOT done:
  noted on `gg`. Docs: 06-runtime, 09-decisions (MINOR-2), 07-deployment (load bound, Q-ms2), 08-concepts (tier table row), scope doc
  rows, CHANGELOG, notes on `fp`, `gg`, `gb`.
- `server/lib` total after security cycle 1 (vs HEAD `bac58977`, `git diff --numstat`): 574 insertions, 244 deletions (818 changed lines).
- Measured statement counts after security cycle 1: initial `/sync` of 3 rooms 54 (51 + one `SET LOCAL` per joined room); `/members` on a
  running room: SET LOCAL + slice + predecessor (2 over room data); on a stopped room 4 over room data (+ status read + the caller's
  membership lookup).
- **Q-ms2 SQL evidence** (the 07-deployment query verbatim, `BEGIN ... ROLLBACK` on `nebu-oauth-pg`): a fixture room with 600 000 member
  events of 3 users (churn) is listed first with 600000, other rooms after it; after the ROLLBACK 0 fixture rows. The staged docs test runs
  the same SQL against its own fixtures.
- Security cycle 1 runs (`--warnings-as-errors`): 1.20 new / changed suites 211 green, docs suites 737 green; no-DB unit run 6427/6428
  (1 failure `rate_limit_take_all_test` AC1 (f), a `GenServer.stop` on_exit race of the known family, green in isolation: 13/13); fresh-DB
  integration 10415/10436: 21 failures, all known families (RoomsFallbackName 12, AdminOidcLogin 3, TraceMapNodeControls 3, WarRoom 1,
  TemporaryCapture 1, LogStore.Retention 1), each re-run in isolation and on a `git archive` copy of HEAD: the same or worse on HEAD
  (AdminOidcLogin green in isolation on this tree, 31/34 on HEAD); 1.19 `compile --force` clean, 21 changed suites + upgrade / limits /
  take_all suites: 606 tests, 0 failures; test-name length > 240: none.


- `Room.DB.member_state_slice/2` (ONE statement, marker `/* member_state_slice */`, the D3 order through `@sql_member_rank` /
  `@sql_membership_normalised` / `@sql_member_membership_raw`, filters `$2` / `$3` and the cap `$4` in SQL by a window rank, joined slots uncapped,
  `content` decoded from both JSONB forms, `@member_slice_other_cap 10_000`) and `Room.DB.direct_invitees/1` (ONE statement, the latest invite per
  user, `is_direct` a JSON `true`).
- `EventDispatcher.Server`: `build_state_events/4` (`member_slice: :events | :joined`, default `:joined`; `joined_member_events/1` is today's slice);
  `member_slice_events/3` through `messages_db_module()` (fail closed for the real `Room.DB`: a missing function or failing read is a handled 500 with
  a value-free ERROR; a TEST db module without the read gets the joined slice); the literal `member_slice: :events` in `initial_join_rooms` (both
  paths), `full_state_room/2`, `get_room_state/2`; `get_room_members/2` (plain map -> `%Core.GetRoomStateResponse{state_events: ...}`, the slice +
  ONE predecessor statement); `readable_room_state!/3` shared by both reads (explicit `M_FORBIDDEN`, fixed text, unknown room 403 without a row also
  for the system role); `fetch_delta_rooms/3` and the summary callers unchanged (`:joined`).
- Upgrade step 6: `direct_invitees!/1` (rooms db seam, 500 before the first invitation), `invite_upgraded_member/4`: plain `insert_invitation/3`
  (uncapped), `write_invite_event/5` (sender = upgrader, `not_before` 0), `unforget_room/2` + `wake_invitee/2` (`:pg.get_members/1`); a refusal /
  failure rejects the row again and logs ONE value-free WARNING (room id + `db_error_class/1`). The node-local wake and the `inspect` warning are gone.
- `Http.state_event_json/3`: the ONE renderer (`/sync` state with `nil`, `/members` and `/initialSync` with the room id); `$synth_` only there (D8 (a));
  `protected.ex`: `/members` validates `membership` / `not_membership` (the two fixed `400 M_INVALID_PARAM` texts, lists / maps / empty strings
  invalid) and calls `get_room_members/2`; `/initialSync` renders through the same function; `initial_sync_state_event/3` removed.
- **Fakes grep list** (`grep -rl "put_env(:event_dispatcher, :messages_db_module" test` without `def member_state_slice`): 42 suites inject a
  messages db fake WITHOUT the read and are served the joined slice (allowed for test doubles only, D1): admin/admin_create_room,
  admin_member_management, admin_oidc_login; matrix/event_dispatcher/admin_force_add_member, audit_member_ops, audit_room_ops, auto_join_join_rule,
  auto_join_opt_out, auto_join_rooms, auto_join_spaces, create_room_canonical_alias, create_room_creator_provisioning, create_room_initial_state,
  create_room_input_validation, create_room_invites, create_room_presets, create_room, get_event, get_messages, get_room_state_lazy_restart, handler,
  invite_caps, invite_user, join_room, leave_personal_room_guard, leave_room, personal_room, server_dedup, server_get_room_state_system,
  server_moderation_metadata, set_room_state, spaces_create_room, sync_membership_partition, sync, thread_relations, upgrade_room_error_handling,
  upgrade_room; matrix/matrix_room_routes, room_summary, room/moderation_fix_cycle1_unit, space_edit_audit, sync_membership_partition_http. The only
  doubles WITH the read are the story's own (`membership_state_unit_test.exs` SliceDB / FailingSliceDB / RaisingSliceDB, `Hooks.SliceDB`, which
  delegates to the real read). No fake was given a stub: no existing suite needed a change beyond the staged AC15 re-pins.
- E2E: feature and steps staged by ATDD, not run here (orchestrator, run A).

### File List

- `server/lib/nebu/matrix/room/db.ex`, `server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/matrix/http.ex`,
  `server/lib/nebu/web/router/protected.ex`
- `docs/matrix-api-scope.md`, `docs/architecture/07-deployment.md`, `docs/architecture/08-concepts.md`, `docs/stories/oauth-broker/follow-ups.md`,
  `CHANGELOG.md`, this story
- Tests (staged by ATDD, unchanged by the dev step): the suites of "Acceptance Tests" and AC15.

### Change Log

- 2026-10-20: story created (create-story, pipeline step 1). Scope: `fb` (state model for the initial `/sync`, `/members`,
  `/initialSync`; upgrade invite events), `fl` (c). Split out: the Admin part of `et` -> `ge`. New follow-ups `ge`-`gi`.
- 2026-10-20: Oracle gate (`step-results/membership-state-model/oracle-context.md`) applied: labels for D3 (d) (`limited: true` loses
  member changes, `fc`; the synthesized joined slot can overwrite the real join content, `gg`), D4 (the cap covers `/members` and
  `/initialSync`), D6 ("the spec text says 'or'", "400 for values outside the enum: Nebu choice"), D7 (constant `visibility` `private`,
  note on `gf`; full-state `state` may repeat `messages.chunk` events), D10 (`replaces_state` / `prev_sender`: Synapse-compatible
  extension), D11 (state minus the timeline slots, no predecessor), D13 (`bf` GET state labelled and pinned); D9: ignored inviters are
  suppressed on the sync side (verified, `ignored_inviters/1`), `m.invite_permission_config` is not applied (`fh` note, `gi` (d)),
  Element's client-side re-invite is the already-invited no-op; AC16 (a)-(m) = the 13 Oracle missing tests, (n) the `bf` pin. No new
  follow-up id (`ge`-`gi`, unused from `gj` onward).
- 2026-10-20: Test review (`step-results/membership-state-model/test-review-findings.md`, STORY gaps S-1..S-6, DEV-SIDE notes) applied:
  S-1 binding seams / signatures in D1, D3, D6 (d), D9, D10 and a Dev Notes bullet (`messages_db_module()` for the slice,
  `rooms_db_module()` for `get_room_status/1` / `direct_invitees/1`); S-2 AC15 (f) (`handler_test.exs`, `get_room_state_lazy_restart_test.exs`
  (4), `matrix_room_view_routes_test.exs`) and the decision that the system-role path answers `403` for an unknown room; S-3 D5 / AC10
  reworded (INFO+ nothing sensitive, DEBUG redactor pinned by AC17 (a), no names-only mask); S-4 AC4 (c) "response-bounded,
  index-served, ONE statement"; S-5 archived / upgraded old room answers like an active room (labelled non-goal, AC17 (g)); S-6 no rate
  tier change (note on `fp`); AC16 (d) tail, one JSON level required, docs-suite contract and the older scope-doc words (AC15 (g)), D8 (a)
  `""` / 0, the stopped-room start label (AC17 (h)); security under-pinning AC17 (b)-(f). No new follow-up id (`ge`-`gi`, unused from
  `gj` onward).
- 2026-10-20: correction of S-5 / AC17 (g) (ATDD finding: serving the old room would need `get_messages` to read archived rooms, i.e.
  `/messages` of every Admin-archived room would become `200`): a TRUE non-goal; the answers for archived / upgraded rooms stay as today
  (`/members`, `/initialSync`: `404 M_NOT_FOUND` "Room not found" for every caller; initial `/sync`: `200`, the old room in no section,
  the new room in `rooms.invite`), pinned by AC17 (g), labelled "known, unchanged: an archived room is not served to its members
  (`gi`)", note `gi` (e). No new id.
- 2026-10-20: dev step (cycle 0). Implementation as in the Dev Agent Record. **AC15 re-pins (old -> new), all staged by ATDD/test review, verified
  green, no assertion weakened:** (a) the id line "`ge` onward" -> "`gj` onward" in the TEN docs suites (create_room_invites, create_room_presets,
  event_size_limit, member_prev_content, membership_write_limits_cycle1, membership_write_limits, moderation_routes, sync_membership_partition,
  power_levels, state_writer_redaction); (b) `member_prev_content_http_test.exs`: `/members` and `/initialSync` state events: none of the
  predecessor keys, 0 predecessor statements -> the three keys on B's join (invite predecessor), ONE predecessor statement each; (c)
  `@baseline_initial_sync_statements` 48 -> 51 (measured 51); (d) `matrix_room_view_routes_test.exs` unknown room `403 or 404` -> green (now `403`),
  the `/members` shape test green; (e) candidates checked, green WITHOUT a change: `matrix_client_compat_test.exs` (incl. the `/initialSync`
  shape), `sync_*`, `direct_room_heroes*`, `upgrade_room_test.exs` (its fake registry is not reached by `write_invite_event/5`, which calls
  `Room.Server.write_invite/5` directly: the call exits, the row is compensated through the fake's no-op `reject_invitation/2`, the recorded
  `insert_invitation` calls stay as asserted), `upgrade_room_error_handling_test.exs`, `moderation_routes_http_test.exs` l.1048,
  `membership_write_limits_http_test.exs` l.767-810; (f) `handler_test.exs` l.116 / l.126: unknown room NOT_FOUND -> `403 M_FORBIDDEN` "You are not
  a member of this room" (+ the system-role test; fake `get_room_status/1`); `get_room_state_lazy_restart_test.exs` (4): two tests gained the
  `get_room_status/1` fake (started from the database, unchanged), the two ghost-room tests NOT_FOUND / message with the room id ->
  `permission_denied` / `M_FORBIDDEN` / the fixed text without the id; `matrix_room_view_routes_test.exs` l.163: "routed" -> routed AND `403
  M_FORBIDDEN` (a `get_room_status/1` fake, no Repo); (g) the older docs-suite words of the `/sync` and `/upgrade` rows kept (all docs suites green).
- 2026-10-20: Security cycle 1 (code review cycle 0 + Kassandra, `step-results/membership-state-model/code-review-findings.md`): D14 the
  `members_read` tier (60/min, burst 30, `NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN` / `_BURST`, charged first for `/members` and
  `/initialSync`, not for the initial `/sync`); D15 `SET LOCAL statement_timeout = '2s'` (timeout = `503 M_UNAVAILABLE`, fixed text),
  O(member events) cost, Q-ms2, availability coupling noted on `gg` / `fp`; D16 (L-1) no process start for a non-member (D6 (a), AC17
  (h) changed); D17 MINOR-1, -3, -6, -8, INFO-5 label; D9 MINOR-7 (`direct_invitees` before the tombstone, AC18 (j) replaces AC6 (e));
  AC18 (a)-(k); notes on `gg` (current-membership table, MINOR-4), `fp` (byte budget, tier), `gb` (GDPR, I-5). No new follow-up id
  (`ge`-`gi`, unused from `gj` onward).
- 2026-10-20: dev step, security cycle 1 (D14-D17, AC18): implementation as in the Completion Notes. Re-pins (staged by the ATDD agent,
  verified green, no assertion weakened): `member_prev_content_http_test.exs` `@baseline_initial_sync_statements` 51 -> 54 (measured 54);
  `member_state_slice_db_test.exs` AC4 (c) ONE statement -> SET LOCAL + ONE slice statement; `membership_state_http_test.exs` AC2 (i)
  stopped room 3 -> 4 room-data statements, AC17 (h) a never-member starts the stopped room -> 403 without a start (also invitee, banned);
  `membership_state_upgrade_http_test.exs` AC6 (d) kill case per member -> loop stops after the first `:room_unavailable` (ONE line, the
  skipped count), AC6 (e) "500 before the first invitation" -> AC18 (j) 500 with nothing written; `rate_limit_tiers_test.exs` the tier keys
  and env vars gain `members_read`; `get_room_state_lazy_restart_test.exs` header comments (MINOR-8). No new follow-up id.
- 2026-10-20: Security cycle 2 (`code-review-findings.md` "SECURITY CYCLE 2"): D18 per-room degradation of the `/sync` paths on slice
  timeout / `DBConnection.ConnectionError` / overflow (labelled "member state of this room is joined-only until the read succeeds;
  completeness gap, not a leak"; every other error stays fail-closed; `/members` / `/initialSync` keep the `503`), AC5 (e) amended; D19
  node-wide slice concurrency limit (`:nebu, :member_slice_max_concurrency`, default 3, node-local, counter released on success / error /
  timeout / kill); D20 MINOR 1 (AC17 (g) and the INFO-5 label corrected: old members of an archived room `404`, never-members `403`; the
  archived-room re-pin of `membership_state_upgrade_http_test.exs` (about l.300-312) `404` -> `403` recorded here), MINOR 2 (predecessor pass
  under its own timeout, or the D15 reword), MINOR 3 (ConnectionError like `57014`), MINOR 4 (baseline 51 -> 54, two statements per room),
  MINOR 5 ("60 per minute, burst 30", "room membership tiers"), MINOR 6, MINOR 7 (Q-ms2 off-peak, read-only role), INFO notes on `gg`,
  `gi`, `fp`; AC19 (a)-(j). No new follow-up id (`ge`-`gi`, unused from `gj` onward).
- 2026-10-20: dev step, security cycle 2 (D18-D20, AC19): implementation as in the Completion Notes. Re-pins (old -> new; staged by the
  ATDD agent unless noted, verified green, no assertion weakened): `membership_state_http_test.exs` the initial `/sync` slice timeout 503
  -> the degraded room (AC19 (a)), AC18 (c) + the statement count (AC19 (i)), `@ac18_words` "60" / "30" -> "60 per minute, burst 30";
  `membership_state_upgrade_http_test.exs` S-5 a never-member's `/members` / `/initialSync` on an archived room 404 -> 403 (old member
  404 unchanged, AC19 (g)), the sorted invite order (AC19 (j)); `member_state_slice_db_test.exs` the strict predecessor lookup; by the dev
  step: `regression_sync_load_test.exs` setup: no gate setting -> `:member_slice_max_concurrency` 1000 (restored on exit; the test measures
  sync throughput), new `member_slice_gate_test.exs`. No new follow-up id.
- 2026-10-20: dev step, security cycle 3 (final; Kassandra M-3 MEDIUM, L-3, L-4, code review MINOR-2/4/5/6): implementation as in the
  Completion Notes; D18 (aggregated WARNING, the new label) and D19 (the GenServer design) rewritten. Re-pins (old -> new):
  `membership_state_model_docs_test.exs` AC19 (h) "joined-only until the read succeeds" -> "joined-only until the client's next initial
  or `full_state` sync" (07-deployment and the scope-doc `/sync` row; the story AC19 (h) text follows); `regression_sync_load_test.exs`
  the cycle-2 setup lift of the gate (`:member_slice_max_concurrency` 1000) -> removed, the file is HEAD again;
  `member_state_slice_db_test.exs` the two inline lock-holder tasks -> `with_events_locked/1` (assertions unchanged);
  `member_slice_gate_test.exs` (dev step's own) the ETS-era gate test kept, the cycle-3 tests added; new
  `membership_state_gate_http_test.exs`. No staged test pinned the old ETS internals. No new follow-up id.
- 2026-10-20: Kassandra narrow review of the gate (M-3 CLOSED): L-1 (cancel after a call timeout), L-3' (one wait budget per
  response), I-1 (catch-all), I-4 (docs: "Three bounds", the member-event wording). Re-pins: none of the staged tests (the pinned prefix
  is unchanged); the dev step's own `member_slice_gate_test.exs` throughput bar 80 % -> 60 % of the measured ideal (CPU contention), new
  tests added there and in `membership_state_gate_http_test.exs`. No new follow-up id.

