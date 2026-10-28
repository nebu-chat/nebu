---
story_id: member-event-prev-content
title: "State events carry unsigned.prev_content / prev_sender next to replaces_state (one batched predecessor lookup, D3 tie order for member slots) so Element marks an accepted DM invitation as a direct chat: closes follow-up ff and the e2e known failure K10"
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

# Story: `unsigned.prev_content` / `prev_sender` on state events, so an accepted DM is a DM in Element (follow-up `ff`, e2e K10)

As a Matrix user (Element Web) who accepts a direct-chat invitation, I want Element to file the room under "People" with the person who
invited me (my `m.direct` account data lists it), so that a DM I accepted is a DM and not an anonymous group room.
As a Matrix client developer, I want every state event Nebu delivers through `/sync`, `/messages` and `/event` to carry the spec's
`unsigned.prev_content` (and the de-facto `prev_sender` next to the existing `replaces_state`), consistently and computed in one place,
so that clients can render membership transitions (Element shows "rejected the invitation", "withdrew the invitation", "unbanned" instead
of "left") and rewind room state during back-pagination without guessing.

Follows `sync-membership-partition` (the invitee sees and accepts the invitation; the e2e scenario `@dm-invitee-ui` proved that the join
works but Element never writes `m.direct`, row K10) and the bugfix `unsigned-replaces-state` (the batched predecessor lookup that this
story widens; it does not add a second one). Closes `ff`; removes `@known-failure` K10.

## Premises verified (2026-10-19, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `54ecc9ed`)

### What Element Web 1.12.15 really does (verified in the bundle, not assumed)

Source: the Element Web image of the stopped dev container `nebu-oauth-dev-element-1` (`/usr/share/nginx/html/version` = `1.12.15`,
bundle directory `bundles/3c9ddd76fa48d1221fef/`). The chunks used below are byte-identical to the image (md5 `1471.js`
`f46000a14db5c7b6861a3738eddb87e4`, `7878.js` `7057b2a85aeb28623cd367e4aad48b98`, compared inside `docker run --rm --entrypoint sh
nebu-oauth-dev-element`). Offsets are byte offsets in the minified chunk; the webpack module path in brackets is the non-minified source
module the code belongs to. Re-check command: `python3 -c "s=open('<chunk>').read(); i=s.find('<needle>'); print(i, s[i:i+400])"`.

| # | Question | Verified code (chunk @offset [module]) |
|---|---|---|
| E1 | Which code writes the INVITEE's `m.direct` after an accept? | Exactly one path: `RoomView.updateDMState()` (`element-web-app.js` @714984 [concatenated into `./src/vector/app.tsx`]): `updateDMState(){const e=this.state.room;if((null==e?void 0:e.getMyMembership())!=se.O.Join)return;const t=null==e?void 0:e.getDMInviter();t&&oa.FZ(e.client,e.roomId,t)}`, where `oa=n("./src/Rooms.ts")` (@210176) and `Rooms.FZ` is `setDMRoom` (E5). |
| E2 | When does `updateDMState` run? | `updateRoomMembers` = lodash `debounce(() => { this.state.room && (this.updateDMState(), this.updateE2EStatus(this.state.room)) }, 500, {leading: true, trailing: true})` (@697254); its only caller is `onRoomStateUpdate` (@696974, `e.roomId === this.state.room?.roomId && this.updateRoomMembers()`), registered as `client.on(RoomStateEvent.Update, this.onRoomStateUpdate)` (@707752). `RoomState.setStateEvents` emits `RoomStateEvent.Update` after it applied a batch of state events (`1471.js` @~195100 [`matrix-js-sdk/src/models/room-state.ts`], `this.emit(f.Update,this)`). So: while the room view is open, every state update of the room (the join event of the invitee arriving through `/sync`) calls `updateDMState()`, the trailing call 500 ms later sees `getMyMembership() == "join"` even if the leading one did not. |
| E3 | What does `Room.getDMInviter()` read? | `1471.js` @218262 [`matrix-js-sdk/src/models/room.ts`]: `getDMInviter(){const e=this.getMember(this.myUserId);if(e)return e.getDMInviter();if(this.selfMembership===C.O.Invite){...heroes[0]...}}`: once joined, ONLY the own `RoomMember`. |
| E4 | What does `RoomMember.getDMInviter()` read? | `1471.js` @188119 [`matrix-js-sdk/src/models/room-member.ts`] (same code in `7878.js` @243264, the worker copy): `getDMInviter(){if(this.events.member){const e=this.events.member;let t=e.getContent(),i=e.getSender();if(t.membership===l.O.Join&&(t=e.getPrevContent(),i=e.getUnsigned().prev_sender),t.membership===l.O.Invite&&t.is_direct)return i}}`. For a JOIN member event it requires `unsigned.prev_content.membership == "invite"` AND `unsigned.prev_content.is_direct == true`, and returns `unsigned.prev_sender` (undefined -> nothing is written). `getPrevContent(){return this.getUnsigned().prev_content\|\|{}}` (@163374 [`models/event.ts`]), `getUnsigned(){return this.event.unsigned\|\|{}}` (@166778): ONLY `unsigned.prev_content` is read, never a top-level `prev_content`. |
| E5 | What does `setDMRoom` write? | `init.js` @112961 [`./src/Rooms.ts`]: `async function c(e,t,n){if(e.isGuest())return;const r=e.getAccountData(EventType.Direct),{filteredContent:a}=filterValidMDirect(r?.getContent()??{});for(const e in a)a[e]&&(a[e]=a[e].filter(e=>e!==t));n&&(a[n]\|\|(a[n]=[]),a[n].push(t)),await e.setAccountData(EventType.Direct,a)}`: `PUT /user/{me}/account_data/m.direct` with the room under the inviter. |
| E6 | Any OTHER writer of `m.direct`? | `setDMRoom` callers in the bundle: `./src/createRoom.ts` (@979604, `t.dmUserId&&await c.FZ(e,C,t.dmUserId)`: the CREATOR side, works today), `RoomView.updateDMState` (E1), `RoomListActions.tagRoom` to/from the DM tag (`init.js` @185372, `r.lA(...)` = `guessAndSetDMRoom`, manual) and the slash command `/converttodm` (@1232069, manual). The accept button (RoomPreviewBar) only reads `is_direct` for its wording (`isDMInvite()` @555098 reads the own invite event's `content.is_direct`). There is NO path that reads the stored `rooms.invite` stripped state after the join. |
| E7 | Is the join event the one in `events.member`? | `RoomMember.setMembershipEvent` (@186220) replaces `events.member` with every newer member event from `/sync` (timeline or state). `RoomState.setOutOfBandMember` (@197973) does NOT replace a member received through sync (`if(i&&!i.isOutOfBand())return`): the lazy-loading `/members` call after the join (`loadMembersIfJoined`) cannot overwrite it, so `/members` needs no `unsigned` for this fix. |
| E8 | Other readers of `prev_content` / `prev_sender` | `SyncAccumulator.getJSON` (@289586 [`matrix-js-sdk/src/sync-accumulator.ts`], the IndexedDB sync cache) rewinds the cached timeline to the state before it: `i.unsigned&&(i.unsigned.prev_content&&(i.content=i.unsigned.prev_content),i.unsigned.prev_sender&&(i.sender=i.unsigned.prev_sender))`; `RoomState.setStateEvents` fills `displayname` / `avatar_url` of a `leave` / `ban` from `getPrevContent()` (@194083); `getDirectionalContent()` uses `getPrevContent()` for events added to the START of a timeline (back-pagination of `/messages`). `unsigned.replaces_state` is read only by the devtools "explore room state" dialog (`init.js` @494768). A WRONG `prev_content` therefore corrupts the cached and the back-paginated state, a missing one only loses information: correctness of the predecessor matters more than coverage. |
| E9 | Timeline texts | `TextForEvent` for `m.room.member` (`init.js` @~144865, `h=e.getPrevContent()`): a JOIN after an invite still reads "joined" (the join case only compares `prev_content` for join -> join profile changes); a self-LEAVE after an invite reads "rejected the invitation", a leave by another user after an invite "withdrew the invitation", after a ban "unbanned", after a join "removed" / "left" (@146487). Today every Nebu decline reads "left". Visible effect, no functional dependency. |

**Verdict: the hypothesis of `ff` is CORRECT and is the whole root cause of K10.** After the accept, Element writes the invitee's `m.direct`
only through `RoomMember.getDMInviter()` on the invitee's own JOIN event, which needs `unsigned.prev_content = {"membership": "invite",
"is_direct": true}` and `unsigned.prev_sender = <inviter>`. Nebu sends neither (below). Nothing else is missing: the invite event already
carries `is_direct` (story create-room-invites-direct), the room view is open in the scenario (Element opens the room on accept). A user who
accepts from a room-list context menu without opening the room gets `m.direct` only when he opens the room (Element behaviour, not ours).

### What Nebu sends today

| Question | Verified state |
|---|---|
| `unsigned` of `/sync` timeline events | `Nebu.Matrix.Http.timeline_event_json/2` (http.ex l.182-209, shared by `rooms.join` and `rooms.leave`): `age` + `replaces_state` when `te.replaces_state != ""`. No `prev_content`, no `prev_sender`. |
| `unsigned` of `/sync` `rooms.join.*.state.events` | `build_joined_rooms/2` (http.ex l.211-305): `age` + `replaces_state`; no unsigned at all for an entry without identity (`event_id == ""`). |
| `/messages`, `/event`, `/relations` | `message_event/1` (http.ex l.320-355): `unsigned` = `%{"replaces_state" => id}` only for a state event with a predecessor (no `age`: a separate gap). |
| The predecessor lookup | ONE function: `Nebu.Matrix.Room.DB.fetch_replaces_state/1` (db.ex l.1290-1375): `UNNEST` of the slots + `LEFT JOIN LATERAL (... WHERE same slot AND (origin_server_ts, event_id) < (req.ts, req.event_id) ORDER BY origin_server_ts DESC, event_id DESC LIMIT 1)`, selects ONLY `e2.event_id`; on a DB error `%{}` + `Logger.warning` with the slot count. Callers (event_dispatcher/server.ex): `fetch_replaces_state_batch/2` (l.3057-3082, guards a Repo-less test), `event_maps_to_core_events/1` (l.3116-3141: `/messages` l.2977, relations l.7688, `/event` l.7726, `/sync` timelines l.4435, l.4465, l.5229) and `attach_replaces_state_to_state_events/2` (l.5529-5544, reached from `build_state_events(state, room_id, true)` only: initial sync l.4427 / l.4462, delta l.5251, `full_state` l.5163). One statement per room (sync) or per response (others). |
| Tie order of the lookup | `(origin_server_ts, event_id)` for EVERY slot. The partition and every latest-membership read use the D3 order of story sync-membership-partition, `origin_server_ts DESC, rank ASC, event_id DESC` with `rank(ban)=0 < leave=1 < invite=2 < knock=3 < join=4`, unknown / unparseable = 1 (`@sql_member_rank`, `@sql_member_membership_raw`, `@sql_membership_normalised`, db.ex l.1524-1560). For a same-millisecond pair of member events the two orders can DISAGREE: the partition reads `invite` as the latest while the lookup may call the join the successor. |
| `rooms.leave` timelines | `build_leave_room/3` (event_dispatcher/server.ex l.4900-4930): `Enum.map(events, &event_map_to_core_event/1)`, deliberately NO predecessor lookup (D6 of sync-membership-partition; pinned by `sync_membership_partition_http_test.exs` l.878 `Map.keys(member["unsigned"]) == ["age"]`). The entry already holds `latest` (L) and `previous` (P) with `event_id`, `sender`, `content`. |
| `rooms.invite` | `build_invite_rooms/1` (http.ex l.154-164) maps every stripped event to exactly `type`, `state_key`, `sender`, `content`; `Core.StrippedStateEvent` has no other field. Pinned (four keys) by `sync_membership_partition_http_test.exs` l.381, l.404. |
| Member event contents | `Room.Server.emit_membership_event/3` (room/server.ex l.635-668): join / leave by the user himself, content `%{"membership" => m}`, `origin_server_ts = now_ms()` (no `max(now, latest + 1)`). The invite event (`write_invitation!/4`, event_dispatcher l.2826-2860, `emit_state_event_at/6` l.7511) has `{"membership": "invite", "is_direct": true}` for a DM, stamped `max(now, not_before)`; createRoom stamps its chain up to about 70 ms AHEAD of the clock (`eu` F-4), so an invitee who joins inside that window gets a join event OLDER than the invite: its predecessor (any order) is not the invite, and `get_member_membership/2` reads `invite` as the latest. The decline writer `emit_decline_event/2` (l.6969) is stamped `now_ms()` too. |
| Synthesized member state | `build_state_events/3` (l.5346-5510) synthesizes the JOINED members with content `{"membership": "join"}` and the REAL `event_id` / `origin_server_ts` of the join (`member_identity`); the lookup anchors on that identity. Row-only invitations (`upgrade_room`) have no invite event (`fb`). |
| Redaction | Nebu has no redaction route (no `m.room.redaction` handling in `server/lib`): a predecessor's content is never redacted. When redaction is added, `prev_content` must be the REDACTED content (recorded in `fl`). |
| `/context/{eventId}` | NOT routed (no route in `protected.ex`, only the unused structs `Core.GetEventContextRequest` / `Core.ContextStateEvent`); `docs/matrix-api-scope.md` l.85 wrongly lists it as ✅. Out of scope (`fk`). |
| Logging | `Nebu.Web.Plugs.RequestLogger.PayloadRedactor` already treats a `prev_content` object like `content` (payload_redactor.ex l.298-303); the No Sensitive Data in Logs Law holds as long as no NEW log line carries a content. |
| Tests that pin the old shape | `matrix_client_compat_test.exs` describe "unsigned.replaces_state (bugfix unsigned-replaces-state)" (l.1555-2700): the oracle `db_replaces_state/5` (l.1679, `(ts, event_id)` order), exact `unsigned == %{"replaces_state" => topic1_id}` at l.2215 (`/messages`) and l.2238 (`/event`), the N+1 tests l.2416 / l.2515 (query count does not scale with the state count), the tie test l.2615 (non-member slot, unchanged by this story). `sync_membership_partition_http_test.exs` l.878 (leave timeline `unsigned` keys `["age"]`). |

### Spec (Matrix CS API v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html`)

- `UnsignedData.prev_content`: "The previous content for this event. This field is generated by the local homeserver, and is only returned if the
  event is a state event, and the client has permission to see the previous content. Changed in v1.2: Previously, this field was specified at the
  top level of returned events rather than in `unsigned`". So: in `unsigned`, only on state events, absent when there is none.
- `m.room.member`: "Previous membership can be retrieved from the `prev_content` object on an event. If not present, the user's previous
  membership must be assumed as `leave`." Today every client therefore reads an accepted invitation as `leave -> join` ("joined").
- `prev_sender` and `replaces_state` do NOT appear in the v1.18 text (grep of the whole local spec copy: 0 hits); they are de-facto
  Synapse fields. `replaces_state` already ships (bugfix unsigned-replaces-state); `prev_sender` is the field matrix-js-sdk reads (E4, E8). Both
  are additional `unsigned` keys, which clients that do not know them ignore.
- Stripped state (`rooms.invite`): "Stripped state events can only have the `sender`, `type`, `state_key` and `content` properties present." Unchanged.

### Sizing evidence (ONE story, smaller than rate-limits-join-invite-create-room)

- `server/lib`: `Room.DB` one function widened and renamed (about 40 lines of SQL / Elixir, no new statement); `core.pb.ex` + `proto/core.proto`
  two fields on two structs; `EventDispatcher.Server` the two attach points fill the new fields, `rooms.leave` gets ONE batched lookup for all
  its entries (about 50 lines); `Http` one shared helper used by the three renderers (about 30 lines); `Room.Server` join / leave stamping
  (about 30 lines); `emit_decline_event/2` stamping (about 10 lines). Estimate 200 lines in `server/lib`, no migration, no new route, no new
  dependency.
- Tests: one real-DB suite, one HTTP suite, one pure renderer unit suite, one docs suite; deliberate re-pins in two existing HTTP suites and the
  id line of five docs suites.
- Docs / e2e: scope doc, follow-ups, 06-runtime, CHANGELOG, KNOWN-FAILURES, the feature file tag + comment, the steps header.
- Split out (follow-ups): `/context` (not routed, `fk`); `unsigned.membership`, `age` on `/messages` / `/event`, `unsigned` on `/members` and
  `/initialSync`, the redaction rule (`fl`); the write-side stamping of the other member writers stays `eu` (note).

## Decisions

- **D1 (scope of the fields).** EVERY state event that is delivered through `/sync` (`rooms.join` state and timeline, `rooms.leave`
  timeline), `GET /rooms/{roomId}/messages`, `GET /rooms/{roomId}/event/{eventId}` and `GET .../relations/...` carries, when it has a
  predecessor at its `(room_id, type, state_key)` slot, the THREE keys `unsigned.replaces_state` (its `event_id`, unchanged meaning),
  `unsigned.prev_content` (its `content` as a JSON object) and `unsigned.prev_sender` (its `sender`), always together, never one without the
  others. Not only `m.room.member`: the lookup is per slot anyway, the extra columns cost nothing, and a client that rewinds state (E8) needs
  it for every type. Non-state events never carry them. `/members` and `/initialSync` keep their current shape (they carry no `replaces_state`
  either; `fl`). `/context` is not routed (`fk`).
- **D2 (no predecessor).** An event without a predecessor (the first event of its slot, `m.room.create`, a synthesized entry without identity
  `event_id == ""`) carries none of the three keys: absent, never `null`, never `{}`. A predecessor whose content is `{}` (or unparseable: it is
  decoded as `{}` like everywhere else, `decode_json_object/1`) DOES carry `"prev_content": {}`: absence means "no predecessor", nothing else.
- **D3 (ONE source of truth, the predecessor order).** `Room.DB.fetch_replaces_state/1` is RENAMED to `fetch_state_predecessors/1` (same
  slot tuples in, `%{event_id => %{event_id: pred_id, content: map, sender: sender}}` out, same `UNNEST` + `LEFT JOIN LATERAL`, same single
  statement, same `%{}` + warning on a DB error); the old name is removed (no alias, no second query). The order of a slot is the D3 order of
  story sync-membership-partition, applied to ALL slots: the predecessor of `X` is the row `P` of `X`'s slot with the largest key
  `(origin_server_ts, r, event_id)` that is strictly smaller than `X`'s key, where `r = 4 - rank(membership)` for `m.room.member` (so a
  same-millisecond `ban` is the LATEST, `join` the earliest, exactly the partition's `ORDER BY origin_server_ts DESC, rank ASC, event_id DESC`) and
  `r = 0` for every other type (which reduces to today's `(origin_server_ts, event_id)` order: the non-member tie test l.2615 stays green
  unchanged). `X`'s own `r` is read in the same statement from `X`'s row (`events` primary key) with the SAME SQL fragments
  (`@sql_member_membership_raw`, `@sql_membership_normalised`, `@sql_member_rank`; both JSONB forms; unknown = rank 1); a slot whose `event_id`
  has no row is ordered as an unknown membership (rank 1), which is the D3 rule for unknown values. No Elixir copy of the rank logic.
  **This order is a NEBU RULE, not a spec rule** (Oracle gate): the spec orders state by the room DAG / stream order, which Nebu does not
  have; the D3 key is the only total order Nebu has, and the partition already uses it. **Caveat (recorded on `eu` and `fc`):** a
  same-millisecond `invite` + `join` of one user makes the invite the SUCCESSOR of the join, so the invite carries `prev_content =
  {"membership": "join"}`: a join -> invite transition, which the spec's `m.room.member` table says "must never happen". D4 stops NEW ties
  of that kind for the join writer; legacy rows and the writers that stay with `eu` (the invite writer, kick / ban / unban, the personal room)
  can still produce them. Accepted (most restrictive is latest, the partition and the lookup agree); AC1 (b) pins and documents it.
- **D4 (strictly increasing member stamps on the invitee-side transitions).** The invite -> join transition is the one this story exists for,
  and createRoom stamps its invite events up to about 70 ms ahead of the clock (`eu` F-4). So the member events written in the user's own
  transitions are stamped `max(now_ms, latest member event ts of that slot + 1)`:
  (a) the JOIN (`Room.Server.handle_call({:join, ...})`): the ban check `check_not_banned/2` reads the latest member event through
  `latest_member_event/2` (D3 order, membership + `origin_server_ts`) INSTEAD of `get_member_membership/2`: the same single read returns the
  timestamp, so the join costs no extra query; the ban refusal and the fail-closed refusal on a read error are unchanged; a db module without
  `latest_member_event/2` (unit fakes) falls back to `get_member_membership/2` and `now_ms`; (b) the LEAVE of a member
  (`Room.Server.handle_call({:leave, ...})`): one indexed read (`latest_member_event/2`) inside the room process before the event write; a failed
  read stamps `now_ms` (the leave itself is never refused because of it, it was never gated); (c) the DECLINE (`emit_decline_event/2`): the same
  read, the same fallback. Kick / ban / unban (unrouted, `ex`), the invite writer, `create_personal_room` and the upgrade stay as they are:
  the write side of `eu` stays open for them (note on `eu`). Residual (recorded on `fc`): a join stamped `invite + 1` can be ahead of the clock
  by the invite's own lead, the same class as `fc` (d), never more than that lead + 1 ms.
  **Minor deviation (Oracle gate):** the CS API has no rule on how a server picks `origin_server_ts`; a member event stamped up to (invite lead
  + 1 ms) ahead of the wall clock is a minor, documented deviation from "the timestamp on the originating homeserver when this event was sent"
  (also recorded on `eu`), accepted because it keeps the slot order strict.
- **D5 (the transitions, as the client sees them).** With D3 + D4 the invitee's join after a DM invite carries `prev_content = {"membership":
  "invite", "is_direct": true}` and `prev_sender = <inviter>` (E4 satisfied); a decline carries the invite content and the inviter; a leave
  after a join carries `{"membership": "join"}` and the user; a re-invite after a leave carries `{"membership": "leave"}` (seen by members of
  the room; the invitee sees the stripped event only, D7); a re-join after a kick carries the kick's content and the KICKER as `prev_sender`.
- **D6 (`rooms.leave`).** The leave window gets the same three keys through ONE batched `fetch_state_predecessors/1` call for ALL new leave
  entries of the response (the slots of every state event of every leave timeline, across rooms: the function is already cross-room), not one
  per entry (`fg` (i) is not made worse). This replaces D6's "no replaces_state lookup" of sync-membership-partition DELIBERATELY (re-pin of
  `sync_membership_partition_http_test.exs` l.878: the leave event now has `age`, `replaces_state`, `prev_content`, `prev_sender`; a message
  keeps `["age"]`). The leave event `L` and its `previous` `P` are already known to the partition; the lookup is still used for them (one rule,
  one code path; the partition's `P` and the lookup agree because both use the D3 order, and a test pins it).
- **D7 (stripped state untouched).** `rooms.invite.*.invite_state.events` stay exactly four keys; `Core.StrippedStateEvent` gets no field.
- **D8 (privacy: "the client has permission to see the previous content"): a DOCUMENTED DEVIATION (`es`), NOT spec-equivalent.** The spec
  (Oracle gate) requires `prev_content` to be OMITTED when the viewer may not see the predecessor: under `history_visibility: joined` (or
  `invited`) a late joiner may not see a predecessor that was sent before he joined (resp. was invited), so the spec says the current state
  event he receives must NOT carry that predecessor's content. Nebu does not enforce `history_visibility` at all (`es`): today the same late
  joiner already receives the predecessor itself through `GET /messages` (a pre-existing deviation). This story does NOT add the visibility
  check: `prev_content` / `prev_sender` / `replaces_state` are delivered to whoever receives the event, which is spec-CONFORMANT under
  `history_visibility: shared` (the spec default when a room has no `m.room.history_visibility` event) and `world_readable`, and a known
  DEVIATION under `invited` / `joined`, the SAME deviation `es` already records for `/messages`, not a new one. Element's DM body sets
  `history_visibility: invited`: the invitee's join predecessor is the invite itself, which the invitee may see ("invited" includes the
  invite), so the DM case is conformant. The `es` row gets the BINDING note: when `history_visibility` is enforced, the three keys of an event
  whose predecessor is not visible to the viewer must be omitted (the predecessor lookup must then be filtered by the viewer's visibility, one
  statement still). AC7 pins both sides: the `shared` case (spec-allowed: the late joiner gets `prev_content`) and the `joined` case, labelled
  "pins known deviation es" (it must flip when `es` ships). The `rooms.leave` window: the predecessors are at or before the leave (the leave
  event's predecessor is the user's own join or invite): nothing after the membership ended is revealed. Member contents are `{"membership":
  ...}` (+ `is_direct` on invites): `prev_content` of a member event reveals no profile data. No new log line contains a content (the warning
  of D3 names the slot count only).
- **D9 (`prev_sender`, `replaces_state` are non-spec).** Kept: they are additional `unsigned` keys that the v1.18 text does not define, Synapse sends
  both and matrix-js-sdk needs `prev_sender` (E4). The scope doc says so explicitly.
- **D10 (the wire encoding inside Nebu).** `Core.Event` and `Core.SyncRoomStateEvent` get `prev_content: ""` (JSON text of the predecessor's
  content, `""` = no predecessor) and `prev_sender: ""`, documented in `proto/core.proto` like `replaces_state`. The renderers emit the three
  keys through ONE private helper in `Nebu.Matrix.Http` (used by `timeline_event_json/2`, the state block of `build_joined_rooms/2` and
  `message_event/1`) that adds them only when `replaces_state` is a non-empty binary AND `prev_content` is a non-empty binary that decodes to a
  JSON object AND `prev_sender` is a non-empty binary (else none of the three: an inconsistent struct never produces a partial triple, so an empty / `nil` `prev_sender` also yields none, never `"prev_sender" => ""`; `is_binary/1` guards as today). The helper also requires `is_state_event: true` for a `Core.Event` (AC3 (e)). The struct defaults of the two new fields are `""` (pinned).
- **D11 (N+1).** The number of statements of `/sync`, `/messages`, `/event` and `/relations` does not change for joined rooms (the lookup is the
  same statement with two more columns and one primary-key join per slot); the `rooms.leave` section adds exactly ONE statement per sync response
  when it has at least one leave entry with a state event, and zero otherwise. `EXPLAIN (ANALYZE, BUFFERS)` of the widened statement on a seeded DB
  (500 rooms, 20 member events each, 300 slots) shows no `Seq Scan` on `events` (index `events_room_state_idx` for the LATERAL, `events_pkey` for
  the own row); recorded in the Completion Notes. A Seq Scan is a blocker (rewrite the predicate, still no migration).
- **D12 (e2e).** After the fix, `@dm-invitee-ui` is a normal scenario of the default run: the `@known-failure` tag and the K10 comment are
  removed from `create-dm.feature`, the K10 row leaves `e2e/KNOWN-FAILURES.md` (with a short "K10 was a server gap" paragraph like the K8 one), the
  header of `dm.steps.ts` loses its `ff` / `@known-failure` instructions. The assertion of the step is NOT changed (it already asserts
  `m.direct[alex]` contains the room, polled 60 s): the verified facts say that is exactly what Element writes.

## Out of scope -> follow-ups (added to `follow-ups.md`; the id line says "unused: ... `fk` onward" and a grep of `docs/stories/oauth-broker/` finds `fk` only in that id line and in the rate-limits story's text about the id line, no row: the new ids are `fk`, `fl`)

- **`fk` — `GET /rooms/{roomId}/context/{eventId}` is not routed.** The scope doc lists it as ✅ (fixed by this story to ❌ "not routed, `fk`");
  only the structs `Core.GetEventContextRequest` / `Core.ContextStateEvent` exist. Element uses `/context` for permalinks and "jump to
  event"; when it is built, its events must go through `event_maps_to_core_events/1` (the predecessor fields of this story) and its `state`
  must follow the visibility rule of `es`. Source: this story (premise check).
- **`fl` — `unsigned` completeness leftovers.** (a) `unsigned.membership` (v1.11, "SHOULD populate wherever practical") is not sent anywhere;
  (b) `/messages`, `/event`, `/relations` carry no `unsigned.age`; (c) `/members` and `/initialSync` state events carry no `unsigned`
  (no `replaces_state` / `prev_content`; Element does not need it there, E7); (d) there is no redaction: when it is added, `prev_content` must be
  the REDACTED content of the predecessor (spec: redacted events stay redacted when requested later; for `m.room.member` only `membership`
  survives, plus `join_authorised_via_users_server` in room v11, so `is_direct` disappears from a redacted invite and a redacted DM invite no
  longer lets Element mark the DM after the join) and a redacted predecessor must not leak through `unsigned`; the redaction story must add a
  test that `prev_content` of the successor is the redacted form (AC1 (m) of this story is the guard: there is no redaction path today); (e) `unsigned.prev_content` sizes: a state
  event with a predecessor is delivered with up to twice its content size (bounded by the state content bounds of `ep`). Source: this story.
- Notes (no new id): `eu` (the write side for the other member writers), `es` (the binding visibility rule of D8), `fa`, `fb`, `fc`, `fg` (AC9).

## Acceptance Criteria

1. **The predecessor statement (real DB, `server/test/nebu/matrix/room/state_predecessors_db_test.exs`, `@moduletag :integration`, real
   `Nebu.Repo`, rows written through `Nebu.Matrix.Room.DB.insert_event/1`, random room / user ids).** `fetch_state_predecessors/1`:
   (a) invite (ts `t`, sender `@a`, content `{"membership": "invite", "is_direct": true}`) then join (ts `t + 1`, sender `@b`) of `@b`: the
   join's entry is `%{event_id: invite_id, content: %{"membership" => "invite", "is_direct" => true}, sender: "@a"}`; the invite has no entry;
   (b) the D3 tie: `join` and `ban` of one user in the SAME millisecond: the ban's predecessor is the join, the join's predecessor is the event
   before both (or absent); the same with `invite` + `join` in one millisecond: the invite's predecessor is the join (the test asserts it AND
   its comment documents this as the join -> invite transition the spec says "must never happen", the accepted D3 caveat recorded on `eu` /
   `fc`); and for each tie `get_member_membership/2` and `latest_member_events/2` read the member the lookup calls LAST (one order, pinned
   against both reads);
   (c) a non-member slot tie (two `m.room.topic` rows, same ts) is broken by `event_id` exactly as before (the larger id is the later);
   (d) the predecessor's content in BOTH JSONB forms (object, and the double-encoded JSONB string written by Postgrex) decodes to the same map; an
   unparseable string content decodes to `%{}` and, for a member slot, ranks as `leave`; (e) a slot whose `event_id` has no row in `events` is
   ordered as an unknown membership (rank 1) and returns the row before it; (f) ONE statement for 300 slots in 3 rooms (count `[:nebu, :repo,
   :query]` telemetry events: exactly 1), results identical to 300 single-slot calls; `[]` answers `%{}` without a statement; (g) a real DB error
   (dev's choice, recorded in the Completion Notes: e.g. `SET LOCAL statement_timeout` or a column renamed inside a transaction that is rolled
   back, on the connection the call uses) returns `%{}` and logs ONE warning whose text contains the slot count and NO content value (capture the log, assert the absence of the
   seeded content marker); (h) `EXPLAIN (ANALYZE, BUFFERS)` of the statement for 300 slots contains no `Seq Scan on events` (asserted on the plan
   text, and the plan recorded in the Completion Notes); (i) ban then leave by ANOTHER user (unban, sender != state_key): the leave's
   predecessor is the ban (content `{"membership": "ban"}`, sender = the banner); (j) invite then leave by another user (revocation, sender !=
   state_key): the leave's predecessor is the invite with `sender` = the inviter; (k) the same content set twice (topic `A`, then topic `A`
   again): the second event's predecessor is the first, with content `A` (no deduplication of identical contents); (l) a NON-state event of a
   state type (`m.room.topic` written with `state_key` NULL, the non-state send path) never gets a predecessor and never counts as one (a state
   topic after it has the EARLIER state topic as predecessor, not the non-state row); (m) redaction guard: `server/lib` contains no redaction
   path (a source pin that no code writes `m.room.redaction` or rewrites `events.content`); the test's comment points to `fl` (d): when
   redaction is added the predecessor content must be the redacted form, and this pin must be replaced by that test.
2. **Member stamps (D4).** (a) Unit (`server/test/nebu/matrix/room/server_member_stamp_test.exs`, fake db module that returns a latest member event
   with `origin_server_ts = now + 60_000`): the join event is stamped exactly `latest + 1`; with no latest event: `now`; a fake WITHOUT
   `latest_member_event/2` falls back to `get_member_membership/2` (`"ban"` still refuses, `:error` still refuses: fail closed) and `now`; the
   leave event is stamped `latest + 1` (a failing read: `now`, the leave succeeds). (b) HTTP real DB (in the AC4 suite): `createRoom` with
   `is_direct: true` and `invite: [B]`, then B joins IMMEDIATELY (no `tick/0`): B's join event `origin_server_ts` > the invite event's;
   `get_member_membership/2` reads `join`; the join's `unsigned.prev_content` is the invite content (AC4 (a)); a decline right after a createRoom
   invitation (no tick) is newer than the invite and carries the invite as its predecessor.
3. **The renderers (pure unit, `server/test/nebu/matrix/http_prev_content_test.exs`, no DB, `async: true`).** For `Core.Event` (timeline and
   `message_event/1`) and `Core.SyncRoomStateEvent`: (a) `replaces_state` + `prev_content` (`~s({"membership":"invite","is_direct":true})`) +
   `prev_sender` set -> `unsigned` has the three keys with `prev_content` as a decoded object (plus `age` where `age` is rendered today);
   (b) all three `""` -> none of the three keys (`unsigned` of a timeline event is exactly `%{"age" => _}`; `message_event/1` has no `unsigned`
   key at all, as today); (c) `prev_content = "{}"` -> `"prev_content" => %{}` present; (d) inconsistent structs (`replaces_state` set,
   `prev_content` `""`; `prev_content` not a JSON object; a `nil` field) -> none of the three keys, never `null`, never a partial triple;
   (e) a non-state event (`is_state_event: false`) never carries them even if the fields are set; (f) the stripped invite events of
   `sync_response/3` stay exactly `type`, `state_key`, `sender`, `content` when the source structs come from the same fixtures.
4. **`/sync` over HTTP (real stack, `server/test/nebu/matrix/member_prev_content_http_test.exs`, `@moduletag :integration`, `async: false`,
   `Nebu.Test.ServerName.pin!/1`, users provisioned with `T.provision_user!/1`, random localparts, the helpers of
   `sync_membership_partition_http_test.exs` copied (`defp`s): `snapshot!/2`, `sync/2`, `tick/0`, `make_room`, `invite!`, `join!`, `leave!`).**
   (a) THE DM CASE: A `createRoom` exactly as Element does for a DM with B (preset `trusted_private_chat`, `is_direct: true`, `invite: [B]`); B's
   incremental sync after the invitation shows the room in `rooms.invite` with four-key stripped events (no `unsigned`); B joins; B's next
   incremental sync has, in `rooms.join.<room>.timeline.events`, B's join event with `unsigned.prev_content == %{"membership" => "invite",
   "is_direct" => true}`, `unsigned.prev_sender == A`, `unsigned.replaces_state == <invite event id>` and `unsigned.age` (integer); a fresh
   INITIAL sync of B shows B's own member event (in `state` or `timeline`, wherever it lands) with the same three values; A's incremental sync
   shows the same on B's join. (b) Leave: B leaves: B's `rooms.leave.<room>.timeline` leave event has `prev_content == %{"membership" =>
   "join"}`, `prev_sender == B`, `replaces_state == <B's join id>`, and its `replaces_state` equals the `event_id` of the partition's `previous`
   (read with `latest_member_events/2`: one order); a message in that window has `unsigned` keys `["age"]`. (c) Re-invite: A re-invites B: B's
   `rooms.invite` stripped events are four keys; A's timeline shows the invite with `prev_content == %{"membership" => "leave"}`, `prev_sender ==
   B`. (d) Decline of a DM invitation: the leave event (A's view) carries the invite content with `is_direct` and `prev_sender == A`.
   (e) Generic state: a second `m.room.topic` carries `prev_content` = the first topic's content and `prev_sender` = its sender, in the `state` of
   an initial sync and in the `timeline` of an incremental one; `m.room.create` and the first topic carry none of the three keys; a plain
   `m.room.message` never carries them. (f) Every state event of every room of A's initial sync satisfies the oracle: the three keys are present
   iff the oracle (a test-local SQL with the D3 key, a COPY of the order, written independently from the production fragments) finds a
   predecessor, and then equal its `event_id` / content / sender. (g) Stripped state never carries `unsigned`, even when its source event HAS a
   predecessor: after (b) and (c) (B left, A re-invites B), every event of B's `rooms.invite.<room>.invite_state.events` (including B's own
   invite member event, whose source row has the leave as predecessor) has exactly the keys `type`, `state_key`, `sender`, `content`.
   (h) Two events of the SAME slot in ONE `rooms.leave` timeline (A changes the topic twice inside B's leave window, then B leaves): the second
   topic's predecessor is the first (same response, same batch), the first topic's predecessor is the topic before the window (or absent).
   (i) Revocation: A invites C, then A kicks / revokes C through the existing leave path where a revoke exists, else through
   `Room.DB.insert_event/1` of a leave with sender A (no revoke route: `fb`): in A's timeline the leave carries `prev_content.membership ==
   "invite"`, `prev_sender == A`, and `sender != state_key`.
5. **`/messages`, `/event`, `/relations` (same suite).** `GET /messages?dir=b` and `GET /event/{id}` of B's join (AC4 (a)) and of the second
   topic carry `unsigned == %{"replaces_state" => ..., "prev_content" => ..., "prev_sender" => ...}` (exactly these three keys: no `age`, the `fl`
   (b) gap); the first topic and messages carry no `unsigned`. DELIBERATE re-pin in `matrix_client_compat_test.exs`: l.2215 and l.2238 assert the
   three-key map (the old `%{"replaces_state" => topic1_id}` is replaced, not loosened to a key check), the oracle `db_replaces_state/5` uses the
   D3 key for `m.room.member` slots (the kick / rejoin and ban / unban tests keep their expectations: their writes are `tick`-separated).
6. **N+1 and statement counts (same suite + the existing ones).** The two N+1 tests of the replaces_state describe block (l.2416, l.2515) stay
   green unchanged (their bounds are not raised). New: (a) an incremental sync with 1 and with 5 NEW leave entries runs the predecessor statement
   exactly once in both cases (count telemetry events whose `:query` metadata matches the statement's marker comment, e.g. a leading
   `/* state_predecessors */` in the SQL: the dev adds the marker), and zero times when the leave section is empty; (b) the total statement count
   of an initial sync of a user in 3 joined rooms is the same before and after this story's change for the same data (measured in the test against
   a constant recorded from the current code: the dev records the baseline number in the Completion Notes before changing the lookup, and the
   assertion is `==`, not `<=`); (c) a join (`POST /join`) runs no more statements than before (same baseline method).
7. **Visibility (D8, same suite).** (a) **Spec-allowed case, `history_visibility: shared`** (the spec default; set explicitly by `PUT /state`
   so the test does not depend on the preset): a topic change BEFORE C joins: C's initial sync carries the current topic with `prev_content` = the
   old topic, `prev_sender`, `replaces_state`; this is conformant (a `shared` late joiner may see the old event). (b) **"pins known deviation
   es"** (the test name says so): the same under `history_visibility: joined`: C still receives `prev_content` of the old topic, AND
   `GET /messages?dir=b` returns the old topic event to C (the pre-existing `es` deviation that makes the field reveal nothing new); the test
   comment states that this assertion MUST flip (the three keys absent for C) when `es` enforces visibility. (c) The DM case under Element's
   `history_visibility: invited` (AC4 (a)) is conformant: the join's predecessor is the invite, which the invitee may see. (d) A user who is
   not a member gets `403` from `/messages` and the room is not in his `/sync` (nothing new reaches a non-member).
8. **Logs (source pin + capture, in the AC1 suite).** No `Logger` call added by this story interpolates a content, `prev_content` or a member
   content (a source scan of the changed functions for `content` in `Logger.*` arguments is NOT enough on its own: AC1 (g) captures the actual
   warning); the request-logger payload test `payload_redactor_test.exs` gets one case with a response-shaped body that has
   `unsigned.prev_content` with a message-like value and asserts it is redacted (if that is already covered by an existing case, the dev names
   it in the Completion Notes instead of adding one).
9. **Docs (`server/test/nebu/matrix/member_prev_content_docs_test.exs`, plus DELIBERATE re-pins).**
   (a) `docs/matrix-api-scope.md`: the `/sync` row says state events carry `unsigned.prev_content` / `prev_sender` / `replaces_state` (one batched
   lookup, the D3 tie order for member slots, absent without predecessor, `rooms.leave` included, `rooms.invite` stripped events unchanged); the
   `/messages` and `/event` rows say the same (no `age`, `fl`); the `/context` row is ❌ "not routed (follow-up `fk`)"; one sentence that
   `prev_sender` and `replaces_state` are Synapse-compatible extensions outside the v1.18 text.
   (b) `follow-ups.md`: the `ff` row is rewritten in the CLOSED style ("**CLOSED by story member-event-prev-content (date): ...**" + "Original
   item: ..." keeping the old text, so the words `prev_content`, `prev_sender`, `getDMInviter`, `m.direct` and the source `sync-membership-partition`
   stay: `sync_membership_partition_docs_test.exs` l.123 keeps passing unchanged); its status column `closed`. Notes "**Note
   (member-event-prev-content, date):**" on: `eu` (the member write side is closed for join / leave / decline by D4; kick / ban / unban, the
   invite writer, the personal room and PUT state stay open; the D3 caveat: a same-millisecond invite + join reads as join -> invite, a
   transition the spec forbids, still possible for legacy rows and those writers; the D4 stamp lead is a minor timestamp deviation), `es` (D8: the prev_content delivery under `invited` / `joined` is the same documented deviation as `/messages`; the BINDING rule: omit the three keys when the predecessor is not visible to the viewer, once visibility is enforced), `fa` (d) (the join's `prev_content` is the invite
   content as written: no `displayname`; unchanged), `fb` (the synthesized joined member state carries the predecessor of the REAL join event;
   a row-only invitation (upgrade) has no invite event, so a DM invitee in an UPGRADED room is not marked direct by Element after the join: stays
   with `fb`), `fc` (the predecessor is a slot property independent of the since-token anchor: an event that `fc` loses is still lost; the D4
   join stamp `invite + 1` can be ahead of the clock by the invite's lead: same class as `fc` (d); the D3 order is a Nebu rule instead of the
   spec's stream order, with the join -> invite tie caveat), `fg` (the `rooms.leave` window now has
   ONE predecessor statement per response, `fg` (i) is not made worse; (k) an unparseable member content is `prev_content: {}` and ranks as
   `leave`; (f) an Admin removal (self-leave) shows the user's own join as `prev_content`). New rows `fk`, `fl` (Out of scope). The id line:
   "`fk`-`fl`: member-event-prev-content" and "unused: ... `fm` onward".
   DELIBERATE re-pins (old -> new, each with a one-line comment naming this story): the id-line assertions `~r/unused:[^.]*\`fk\` onward/` in
   `create_room_presets_docs_test.exs`, `create_room_invites_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`,
   `sync_membership_partition_docs_test.exs`, `membership_write_limits_docs_test.exs` become `` `fm` onward `` (and the old `fk` onward is
   refuted in the new docs suite).
   (c) `docs/architecture/06-runtime.md` l.133-145: the "Key design facts" of the predecessor lookup name `fetch_state_predecessors/1`, the three
   keys, the D3 order for member slots, the leave-section batch, and replace "Nebu does not implement `prev_content`" with the D8 rule.
   (d) `CHANGELOG.md` `[Unreleased]` `### Fixed`: one entry ("State events carry `unsigned.prev_content` / `prev_sender`; Element marks an
   accepted DM invitation as a direct chat (follow-up `ff`)"), including the visible client effect (a declined invitation reads
   "rejected the invitation" instead of "left" in Element, E9).
   (e) e2e (no server test reads these files today; the docs suite pins them): `e2e/features/element/dm/create-dm.feature` scenario 3 has
   no `@known-failure` and no K10 comment (the stray blank comment lines around it are removed; the header comment says the DM is marked through
   the join's `prev_content` / `prev_sender`); `e2e/KNOWN-FAILURES.md` has no K10 table row and a paragraph "K10 was a server gap (follow-up
   `ff`, story member-event-prev-content)"; `e2e/step-definitions/element/dm.steps.ts` header and the comment at the `m.direct` poll no longer
   say "@known-failure" / "if it fails ONLY because"; the assertion code of that step is byte-identical (the docs suite pins the
   `toContain(dmRoomId)` poll line and the 60 s timeout).
10. **Regression.** `mix test` (unit) and `mix test --include integration` green on the branch; the existing suites
   `sync_membership_partition_http_test.exs`, `matrix_client_compat_test.exs`, `create_room_invites_http_test.exs`,
   `membership_write_limits_http_test.exs` pass with only the re-pins named in AC5 / AC9 / D6; `mix compile --warnings-as-errors`.

## Acceptance Tests

- `server/test/nebu/matrix/room/state_predecessors_db_test.exs` (new, `@moduletag :integration`, real `Nebu.Repo`): AC1 (a)-(m) (incl. the
  unban, revocation, same-content-twice, non-state-row and redaction-guard cases of the Oracle gate), AC8 (warning capture).
- `server/test/nebu/matrix/room/server_member_stamp_test.exs` (new, unit, fake db module through the existing `db_module()` seam): AC2 (a).
- `server/test/nebu/matrix/http_prev_content_test.exs` (new, pure unit): AC3.
- `server/test/nebu/matrix/member_prev_content_http_test.exs` (new, `@moduletag :integration`, real stack through `Nebu.Web.Router`): AC2 (b),
  AC4 (a)-(i) (incl. stripped state without `unsigned` after a re-invite, two same-slot events in one leave timeline, revocation), AC5 (new
  cases), AC6 (a)-(c), AC7 (a) `shared` (conformant) and (b) `joined` ("pins known deviation es").
- `server/test/nebu/matrix/member_prev_content_docs_test.exs` (new): AC9.
- Re-pinned: `matrix_client_compat_test.exs` (AC5), `sync_membership_partition_http_test.exs` l.878 (D6), the five docs suites (AC9 (b)),
  `payload_redactor_test.exs` (AC8, if a case is added).

**SQL-dependent behaviour MUST be pinned on the real DB** (the D3 key, both JSONB forms, the primary-key join, the one-statement property, the
plan): a fake that returns ready predecessors proves nothing about the SQL (a fake hid a real defect in an earlier story). The HTTP tests use
`tick/0` between membership changes EXCEPT where a test deliberately builds the no-tick case (AC2 (b)) or a same-millisecond tie through
`insert_event/1` (AC1 (b)). Note the pre-existing flake `fj` (`tick/0` waits for the newest event of all rooms; two suites insert
future-stamped events): do not add future-stamped events to the shared database outside a room the test owns and deletes; AC2 (a) uses a FAKE for
the `+60_000` case for exactly this reason.

## E2E verification

`ui: false` (no UI code changes), but this story exists to turn a red e2e scenario green, so the e2e runs are part of the Definition of Done.
All runs on a FRESH, isolated stack built from THIS commit (the e2e-ci script builds the server image when `NEBU_E2E_PREBUILT` is unset):

0. Preparation: `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000 (stop a stray `nebu-oauth-dev-*` container; never touch
   the shared `nebu` project); `COMPOSE_PROJECT_NAME=nebu-oauth-e2e` for all runs; `down -v` between the runs (fresh DB each time).
1. **Run T (the target, before the tag is removed it must be selected explicitly):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e
   NEBU_E2E_GREP='--grep @dm-invitee-ui --repeat-each 3' scripts/e2e-ci.sh element` after the tag removal (or with `NEBU_E2E_TAGS` including
   `@known-failure` before it). Pass: 3 of 3 green, the `m.direct` poll passes (record the time to green from the trace). Log:
   `_bmad-output/nebu/epics/oauth-broker/step-results/member-event-prev-content/e2e-run-t.log`. If it is NOT green: the trace's network log of
   the invitee's `/sync` after the accept must show the join event with `unsigned.prev_content` / `prev_sender`; if they are there and Element
   still writes no `m.direct`, STOP and report (the verified facts E1-E7 would be wrong for this run), do not weaken the assertion.
2. **Run A (CI parity, the regression gate):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e scripts/e2e-ci.sh element`. Pass: every scenario of the
   default tag expression green, now INCLUDING `@dm-invitee-ui`, except the remaining rows of `e2e/KNOWN-FAILURES.md` (K9 stays excluded).
   Log: `e2e-run-a.log` in the same directory. Particular attention: the Element timeline scenarios of rooms, Spaces and member lists (they
   now receive `prev_content`; a regression there means a wrong predecessor, D3).
3. Update the "Status of the last complete runs" line of `e2e/KNOWN-FAILURES.md` with run A's numbers.

## Tasks

- [x] `Room.DB.fetch_state_predecessors/1` (rename + widen, D3 order with the existing SQL fragments, marker comment, warning without content); remove `fetch_replaces_state/1`.
- [x] `core.pb.ex` + `proto/core.proto`: `prev_content`, `prev_sender` on `Core.Event` and `Core.SyncRoomStateEvent` (D10).
- [x] `EventDispatcher.Server`: `fetch_replaces_state_batch/2` -> the new function (same guards); `event_maps_to_core_events/1` and
      `attach_replaces_state_to_state_events/2` fill the three fields; `build_delta/5` builds the leave rooms and runs ONE batched lookup for all
      of them (D6); `emit_decline_event/2` stamping (D4 (c)).
- [x] `Room.Server`: `check_not_banned/2` on `latest_member_event/2` returning the latest ts; join / leave stamping (D4 (a), (b)).
- [x] `Nebu.Matrix.Http`: one helper for the three keys in the three renderers (D10); the moduledoc / function docs updated.
- [x] Tests (Acceptance Tests) and the re-pins; baseline statement counts recorded BEFORE the lookup change (AC6 (b), (c)).
- [x] `EXPLAIN (ANALYZE, BUFFERS)` on a seeded DB (Completion Notes).
- [x] Docs AC9 (scope doc, follow-ups, 06-runtime, CHANGELOG) and the e2e files (feature tag + comment, KNOWN-FAILURES, steps header).
- [x] E2E runs T and A with logs (orchestrator, 2026-10-19: run T = the DM scenarios x3 on a fresh stack: the invitee scenario with the m.direct assertion passed 3/3 (one API-scenario repeat died on a Chromium launch SIGSEGV: infrastructure); run A = the full element-web project on a fresh stack: 26 passed, 0 failed; logs e2e-runT.log / e2e-runA.log in step-results/member-event-prev-content/).

## DEV BRIEF: what the ATDD step pinned (red until the dev edits it)

Names and decisions pinned by the tests (details in the moduledocs of the five new suites):

- `Room.DB.fetch_state_predecessors/1` (the old `fetch_replaces_state/1` removed, no alias); the statement starts with the comment `/* state_predecessors */`; its warning interpolates ONLY the slot count and the SQLSTATE code (`reason.postgres.code`), never `inspect(reason)`, content, rows, params or sender.
- `Core.Event` / `Core.SyncRoomStateEvent`: `prev_content: ""`, `prev_sender: ""` (defaults pinned); documented in `proto/core.proto` (two `string prev_content` and two `string prev_sender` fields).
- The renderer rule of D10 (above), including `is_state_event: true`; `prev_content` rendered as the decoded object.
- D4: `Room.Server` join reads `latest_member_event/2` INSTEAD of `get_member_membership/2` (fallback for a db module without it); leave and decline are stamped `max(now, latest + 1)`; the join's `member_identity` keeps `{event_id, real_ts}`. Re-pinned existing tests: `join_room_test.exs` (3 tests), `matrix_http_state_key_test.exs`, `matrix_client_compat_test.exs`, `sync_membership_partition_http_test.exs` l.878, five docs suites (`fm` onward).
- `/initialSync` keeps its `state` block without the keys (its `messages.chunk` is a `/messages` page and carries them); `/members` runs no predecessor statement; statement counts of an initial sync (3 rooms) and of a join are pinned `==` to the recorded baseline (see `@baseline_*` in `member_prev_content_http_test.exs`).
- Do NOT write the literal `m.room.redaction` or `UPDATE events` anywhere in `server/lib`, comments included (AC1 (m) pin); do not keep `fetch_replaces_state/1`.

Docs / e2e edits that the pins require:

- `create-dm.feature`: the header comment names `prev_content` and `prev_sender`; no blank lines between comment lines (scenario 3 tag and K10 comment are already removed by the ATDD step).
- `e2e/KNOWN-FAILURES.md`: a paragraph "K10 was a server gap" naming `ff` and `member-event-prev-content` within 700 characters, and the stale "Status of the last complete runs" line (2026-10-15, 133 passed) replaced with the real run A numbers (not pinned by a test).
- `dm.steps.ts`: drop `@known-failure` and "if it fails ONLY because" in the header (lines 20-21) and in the comment near the `m.direct` poll; the poll lines stay byte-identical; keep the Element chunk names / offsets in a comment (E1-E8).
- Scope doc rows (`/sync`, `/messages`, `/event`, `/context` row with the cross and "not routed" `fk`, the Synapse-extension sentence); follow-ups (`ff` CLOSED style with "Original item" and status `closed`; notes on `eu`, `es`, `fa`, `fb`, `fc`, `fg`; new rows `fk`, `fl`; id line "`fk`-`fl`: member-event-prev-content", "unused: ... `fm` onward"); `06-runtime.md` (the "Key design facts" block: `fetch_state_predecessors/1`, the three keys, member-slot order, leave-section batch, the D8 rule with `es`; the block must keep the heading "Key design facts"); `CHANGELOG.md` `[Unreleased]` `### Fixed`.
- Completion Notes: the EXPLAIN (ANALYZE, BUFFERS) on the seeded 500-room database is the real D11 evidence (the test only pins "an index serves the read").

Validation hints: run the new suites alone AND the full `mix test --include integration` (the statement-count pins and the ordering of suites matter); the known flake `fj` (`tick/0`) can hit `sync_membership_partition_http_test.exs` next to other suites. The full suite was run on the ATDD reference twice, once on a fresh database and once without reset.

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018: the SQL stays inline
  in `Nebu.Matrix.Room.DB`, no repository / service module; ADR-019 / ADR-021: plain in-process modules, the `Core.*` structs are plain structs
  (`core.pb.ex` is hand-maintained, not generated: edit it and keep `proto/core.proto` as the documentation of the fields).
- **One lookup, not two.** Do NOT add a second query for content / sender next to the replaces_state one, and do NOT compute the rank in Elixir: the
  three fragments `@sql_member_membership_raw`, `@sql_membership_normalised`, `@sql_member_rank` are the single definition of the D3 order (they
  are module attributes in `Room.DB`; interpolate them like `@sql_latest_member_events` does). The own row of the requested event is joined by
  `events.event_id` (primary key). Keep `LEFT JOIN LATERAL ... ON true` + `LIMIT 1`; an index-friendly upper bound
  `e2.origin_server_ts <= req.origin_server_ts` in the LATERAL helps the planner use `events_room_state_idx`; check the plan (D11).
- **Leave section batch.** `build_delta/5` currently maps `build_leave_room/3` per entry. Keep `build_leave_room/3` building the raw maps, then
  convert ALL leave rooms' events with ONE call (collect the slots of every leave timeline, call the batch once, map back per room); keep the shape
  of `Core.SyncRoom` for leave rooms (`state_events: []`, `limited`, `prev_batch`). The initial sync has no `rooms.leave` (`fd`): nothing to do there.
- **Do not touch** `build_invite_rooms/1` / `Core.StrippedStateEvent` (D7), `dedup_member_state_events/2`, the partition rules, the `age`
  rendering, `build_state_events(..., false)` callers (`/members`, `/initialSync`, summaries, the space-hierarchy BFS: no extra statement there).
- **Thread aggregations** (`attach_thread_aggregations/3`, `thread_root_updates/3`) operate on `Core.Event` structs: they must preserve the new
  fields (struct update, not a rebuild); thread roots are non-state events.
- **Stamping (D4).** The join read already exists (`check_not_banned/2`); return the ts from it instead of adding a read. `emit_membership_event/3`
  gets a `not_before` argument (`max(now_ms, not_before)`); the join's `member_identity` keeps the REAL stamped ts (the synthesized state entry
  must anchor on the persisted identity, or its predecessor lookup is wrong). The ban check semantics (refuse `ban`, refuse on read error) are
  security-relevant: unchanged and re-tested.
- **Element facts are version-bound.** E1-E8 are verified for Element Web 1.12.15 (the e2e image). Keep the chunk names and offsets in a comment
  next to the e2e step (not in `server/lib`).
- **No Sensitive Data in Logs Law:** member contents are harmless, topic / name contents are not: never log a predecessor content, not even at
  debug level.
- **Previous story learnings:** fakes hid real SQL defects (real-DB tests for every SQL property); docs suites pin texts of earlier stories, so
  rewrite rows in the CLOSED style that keeps the pinned words; re-pins are deliberate and named in the Change Log (old -> new).

### References

- Element facts: the bundle chunks under `bundles/3c9ddd76fa48d1221fef/` of the image `nebu-oauth-dev-element` (table E1-E8).
- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` (UnsignedData, `m.room.member`, stripped state).
- Code: `server/lib/nebu/matrix/http.ex` l.154-355; `server/lib/nebu/matrix/room/db.ex` l.1290-1375, l.1524-1760;
  `server/lib/nebu/matrix/event_dispatcher/server.ex` l.2977, l.3057-3141, l.4427-4470, l.4900-4930, l.5117-5300, l.5346-5544, l.6969,
  l.7511, l.7688, l.7726; `server/lib/nebu/matrix/room/server.ex` l.318-385, l.582-668; `server/lib/pb/core.pb.ex` l.1-18, l.302-314;
  `proto/core.proto` l.195-215, l.450-462.
- Stories: `sync-membership-partition.md` (D3, D4, D6, the Element premise table), `rate-limits-join-invite-create-room.md` (format, e2e runs),
  the bugfix unsigned-replaces-state (`docs/architecture/06-runtime.md` l.133-145).
- Follow-ups: `ff`, `eu`, `es`, `fa`, `fb`, `fc`, `fg`, `fj` in `docs/stories/oauth-broker/follow-ups.md`; e2e `e2e/KNOWN-FAILURES.md` (K9, K10).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5 (dev-story run, 2026-10-19)

### Debug Log

- The throwaway reference implementation was a starting point only; the lib code was reviewed against the story and re-written where needed (clean doc comments, no Elixir copy of the rank logic, value-free warning, `put_predecessor/2` shared by the three attach points).
- First green run of the staged suites: 239 / 240; the one red test was the AC1 (g) source pin: a COMMENT in `db.ex` contained the literal `inspect(reason)` (the pin scans the function body incl. comments). Comment reworded.
- CI parity (Elixir 1.20): three of the staged test files produced compile / type warnings that fail `mix test --warnings-as-errors` (unused default arguments of `core_event/1`, `state_entry/1`, `string_form!/6`; constant conditionals for the `unquote`d `kind` in two generated tests of `http_prev_content_test.exs`). Fixed WITHOUT changing any assertion (see Deviations).
- The dev run was measured WITHOUT `regression_sync_load_test.exs` (moved aside for the full runs and restored afterwards, as the orchestrator instructed) and, for the clean full run, also without `room_summary_integration_test.exs` (see below); full-suite findings: see Completion Notes. Root cause of the repeated `tick/0` `:timeout` failures of `member_prev_content_http_test.exs` in two full runs (a monitor on the DB showed it): `room_summary_integration_test.exs:84` writes a `ban` member event 60 s AHEAD of the clock into a real room and never deletes it (follow-up `fj`), so every suite that calls `tick/0` within 60 s after it fails. Not a defect of this story; with that one file moved aside the full run is clean of this family.

### Completion Notes List

- Implemented D1-D12 / AC1-AC10. `server/lib` changes: `Room.DB.fetch_state_predecessors/1` (renamed + widened; one statement; D3 key `(origin_server_ts, r, event_id)` from the shared SQL fragments; leading `/* state_predecessors */`; warning = slot count + SQLSTATE code only; old name removed), `Core.Event` / `Core.SyncRoomStateEvent` `prev_content` / `prev_sender` (hand-edited `core.pb.ex` + `core.proto`), `EventDispatcher.Server` (`fetch_state_predecessors_batch/2`, `put_predecessor/2`, `attach_predecessors_to_state_events/2`, `attach_leave_predecessors/1` = ONE batch for all leave entries, `member_event_stamp/2` for the decline), `Room.Server` (`check_not_banned/2` on `latest_member_event/2` returning the ts, fallback to `get_member_membership/2`; join / leave stamped `max(now, latest + 1)`), `Nebu.Matrix.Http` (`put_predecessor_keys/2` shared by `timeline_event_json/2`, the join state block and `message_event/1`).
- Baseline statement counts (AC6 (b), (c)) are the pinned `@baseline_initial_sync_statements 45` and `@baseline_join_statements 11` of `member_prev_content_http_test.exs`: measured by the ATDD step on the unchanged code, and they hold `==` after the change (the join's two ban reads became one `latest_member_event` read that also yields the stamp: 11 before and after; the calibration form also passes in the full suite).
- AC8 (redaction of `unsigned.prev_content` in the request log): already covered by the new case in `payload_redactor_test.exs` (staged by the ATDD step, green); no further case added.
- AC1 (g) DB-error strategy (ATDD test): see `state_predecessors_db_test.exs`; the warning logs the slot count and `inspect(code)` of `reason.postgres.code` only.
- Tests run (isolated throwaway postgres, `elixir:1.20-alpine`): `http_prev_content_test` + `state_predecessors_db_test` + `server_member_stamp_test` 104 passed; `member_prev_content_http_test` 27 passed; `join_room_test` + `matrix_http_state_key_test` + `payload_redactor_test` 136 passed; the six docs suites 119 passed; `sync_membership_partition_http_test` 50 passed; `matrix_client_compat_test` 65 / 66 passed (+1 excluded; the `replaces_state` same-millisecond tie family flakes, a different test each run, green in the full suites); `test/nebu/matrix` alone 3015 / 3019 (SsoLogin, pair-cap concurrency, MatrixSso flakes and the `tick` family), full suite on a fresh DB 9104 / 9125 passed (failing names: RoomsFallbackName x11, TraceMapNodeControls x3, LogStore.Retention x1, TemporaryCaptureManager x2, WarRoom x1, AdminOidcLogin x3: all known flaky families, none touches this story). No-DB `mix compile --force --warnings-as-errors` and `mix test --warnings-as-errors` on `elixir:1.20-alpine`: 5924 passed, exit 0 (an earlier run showed one `RateLimitTakeAllTest` failure, a pre-existing race in its `on_exit`, a different test each time).
- EXPLAIN (ANALYZE, BUFFERS), seeded DB (500 rooms x 20 member events + 3 topic events each, ANALYZE run; 300 member slots in 150 rooms; test DB with the full-suite data on top). No Seq Scan: the lateral read uses `events_room_state_idx` (index condition on room, type, state_key and the `origin_server_ts` upper bound, an incremental sort on the D3 key above it) and the own-row rank read uses `events_pkey`:

```
Nested Loop Left Join  (cost=17.03..5120.26 rows=300 width=164) (actual time=0.132..1.641 rows=300 loops=1)
  Buffers: shared hit=3003
  ->  Function Scan on r0  (cost=0.01..3.01 rows=300 width=136) (actual time=0.086..0.118 rows=300 loops=1)
  ->  Limit  (cost=17.02..17.04 rows=1 width=144) (actual time=0.005..0.005 rows=1 loops=300)
        Buffers: shared hit=3003
        InitPlan 1 (returns $5)
          ->  Index Scan using events_pkey on events  (cost=0.41..8.47 rows=1 width=4) (actual time=0.001..0.001 rows=1 loops=300)
                Index Cond: (event_id = r0.event_id)
                Buffers: shared hit=1200
        ->  Incremental Sort  (cost=8.55..8.59 rows=2 width=144) (actual time=0.005..0.005 rows=1 loops=300)
              Sort Key: e2.origin_server_ts DESC, (CASE ... D3 rank ... END) DESC, e2.event_id DESC
              Presorted Key: e2.origin_server_ts
              Full-sort Groups: 300  Sort Method: quicksort  Average Memory: 25kB  Peak Memory: 25kB
              Buffers: shared hit=3003
              ->  Index Scan using events_room_state_idx on events e2  (cost=0.41..8.54 rows=1 width=144) (actual time=0.004..0.004 rows=2 loops=300)
                    Index Cond: ((room_id = r0.room_id) AND (event_type = r0.event_type) AND (state_key = r0.state_key) AND (origin_server_ts <= r0.origin_server_ts) AND (origin_server_ts <= r0.origin_server_ts))
                    Filter: (ROW(origin_server_ts, <D3 rank>, event_id) < ROW(r0.origin_server_ts, <own rank>, r0.event_id))
                    Rows Removed by Filter: 1
                    Buffers: shared hit=3000
Planning Time: 0.605 ms
Execution Time: 1.732 ms
```

  One slot: Execution Time 0.130 ms, 13 buffers, same plan shape.
  Worst case for one slot (review cycle 1, INFO-4): 50 000 events in ONE `m.room.topic` slot, the newest requested: `Index Scan using events_room_state_idx` (index condition incl. the `origin_server_ts <=` bound), an Incremental Sort presorted on `origin_server_ts` (1 full-sort group), `events_pkey` for the own rank (never executed for a non-member slot, a pk lookup for a member slot), 16 buffers in total (4 for the slot scan), Execution Time 0.210 ms, no Seq Scan.
- (done by the orchestrator, see the checked task above) E2E runs T and A were NOT done by the dev step (no e2e run was allowed): the last task box stays open. FOR THE ORCHESTRATOR: (1) the "Status of the last complete runs" line of `e2e/KNOWN-FAILURES.md` is still the 2026-10-15 text (133 passed, ...) and must be replaced with the real run A numbers after the e2e run (no test pins it); (2) the logs go to `_bmad-output/nebu/epics/oauth-broker/step-results/member-event-prev-content/e2e-run-t.log` / `e2e-run-a.log`.

### File List

- `server/lib/nebu/matrix/room/db.ex` (`fetch_replaces_state/1` removed; `fetch_state_predecessors/1` + `@sql_state_predecessors`)
- `server/lib/nebu/matrix/event_dispatcher/server.ex`
- `server/lib/nebu/matrix/room/server.ex`
- `server/lib/nebu/matrix/http.ex`
- `server/lib/pb/core.pb.ex`
- `proto/core.proto`
- `docs/matrix-api-scope.md`
- `docs/stories/oauth-broker/follow-ups.md`
- `docs/architecture/06-runtime.md`
- `CHANGELOG.md`
- `e2e/KNOWN-FAILURES.md`, `e2e/features/element/dm/create-dm.feature`, `e2e/step-definitions/element/dm.steps.ts`
- `server/test/nebu/matrix/http_prev_content_test.exs`, `server/test/nebu/matrix/room/state_predecessors_db_test.exs` (warning-only fixes, see Change Log)
- `server/test/nebu/matrix/room_summary_integration_test.exs` (orchestrator, review cycle 1: `ban!/3` registers an `on_exit` DELETE of its 60 s ahead-of-clock ban event, the `fj` root cause; returns `:ok`)
- `server/test/nebu/matrix/room/server_member_stamp_test.exs` (review cycle 1: pin that `Nebu.Matrix.Room.DB` exports `latest_member_event/2` and `get_member_membership/2`)
- review cycle 1 comment-only / docs edits: `server/test/nebu/matrix/matrix_client_compat_test.exs` (two comments name `fetch_state_predecessors`), the six docs suites (id line `fn` onward, see Change Log)
- `docs/stories/oauth-broker/member-event-prev-content.md` (this file)
- staged by the ATDD step (unchanged by the dev step): `server_member_stamp_test.exs`, `member_prev_content_http_test.exs`, `member_prev_content_docs_test.exs`, the re-pinned suites.

### Change Log

- 2026-10-19 (review cycle 1, 0 MAJOR / 3 MINOR, Kassandra CLEAN): (1) MINOR-2: `server_member_stamp_test.exs` pins that the production `Nebu.Matrix.Room.DB` exports `latest_member_event/2` and `get_member_membership/2` (no 3-way fallback in `check_not_banned/2`); (2) MINOR-3: `room_summary_integration_test.exs` (`ban!/3` cleans its ahead-of-clock ban event, `fj` root cause) is part of this story; the dev run was measured without `regression_sync_load_test.exs` (moved aside, restored for the commit); (3) INFO-1: `fetch_replaces_state?` renamed `fetch_predecessors?` and the stale comments reworded (`server.ex`, `matrix_client_compat_test.exs`: comments only); (4) INFO-5: scope doc: the `/relations` rows, a `/members` note and a new `/initialSync` row (state unchanged, `messages.chunk` carries the keys); (5) follow-ups: BINDING gate condition on `ex` (kick, ban and unban all stamped `max(now, latest + 1)` inside the room process, gate test with an invite 100 ms ahead), `ep` payload amplification (L-2), notes on `eu` / `fc` (chain lead not a hard bound), `fj` (fixed for `room_summary_integration_test`), new row `fm` (`RateLimitTakeAllTest` `on_exit` race); id line `fk`-`fl` + `fm`, unused from `fn` (DELIBERATE re-pin of the id-line assertion `fm` onward -> `fn` onward in the six docs suites: `create_room_presets_docs_test`, `create_room_invites_docs_test`, `membership_write_limits_cycle1_docs_test`, `sync_membership_partition_docs_test`, `membership_write_limits_docs_test`, `member_prev_content_docs_test`); (6) INFO-4: the 50 000-events-in-one-slot EXPLAIN is in the Completion Notes.
- 2026-10-19 (dev): implemented D1-D12 (see Completion Notes). Deviations: (1) the two staged test files `http_prev_content_test.exs` and `state_predecessors_db_test.exs` got warning-only edits (removed three unused `\\ []` defaults; `age_rendered?/1` is a boolean comparison and the `if` of the AC3 (b) test no longer matches on the literal `kind`) because Elixir 1.20 flagged them and the blocking CI job runs `mix test --warnings-as-errors`; no assertion changed; (2) `Room.Server` uses a `guarded_read/1` helper and `membership_unavailable/1` instead of the inline try / rescue of the old `check_not_banned/2` (same semantics: ban refuses, a failed read refuses, fail closed); (3) the status line of `e2e/KNOWN-FAILURES.md` is left for the orchestrator (needs the e2e run numbers).
- 2026-10-19 (Oracle gate, `step-results/member-event-prev-content/oracle-context.md`): D8 reworded as a documented DEVIATION (`es`), not
  spec-equivalence; AC7 split into the conformant `shared` case and the `joined` case "pins known deviation es"; D3 labelled a Nebu rule with
  the join -> invite tie caveat (notes on `eu` / `fc`); D4 minor timestamp-deviation note; `fl` (d) redaction rule (member redaction keeps only
  `membership`, `is_direct` disappears); missing tests added: AC1 (i)-(m) (unban, revocation, same content twice, non-state row of a state
  type, redaction guard), AC1 (b) documents the forbidden join -> invite tie, AC4 (g)-(i) (stripped state without `unsigned` after a
  re-invite, two same-slot events in one leave timeline, revocation). Ids `fk` / `fl` unchanged.
- 2026-10-19: story created (create-story; Element 1.12.15 bundle verified, hypothesis of `ff` confirmed, decisions D1-D12, follow-ups `fk`, `fl`).
