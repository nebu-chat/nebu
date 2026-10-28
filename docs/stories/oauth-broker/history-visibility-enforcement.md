---
story_id: history-visibility-enforcement
title: "History visibility is enforced on every event read path: ONE SQL visibility fragment in Room.DB (the m.room.history_visibility and the viewer's membership at each event's position, the spec's four rules, the special rules for history-visibility events and the viewer's own member events, the most-restrictive same-millisecond rule) applied inside the existing statement of /messages, the initial and incremental /sync timeline, the incremental thread-root fetch, /event, /relations (parent and children), /search, the /initialSync messages and the unsigned predecessor lookup (prev_content omitted when the predecessor is not visible); fail closed; closes es"
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

# Story: history visibility enforcement (follow-up `es`)

As a member of a room whose history visibility is "Members only (since they were invited)" (`invited`) or "Members only (since they
joined)" (`joined`), I want users who are invited or join later NOT to see the messages that were sent before their invitation / join,
in Element's timeline, in search, through a permalink or a thread, so that the room setting does what it says.
As a Nebu operator (compliance: data minimisation), I want the server, not the client, to decide which events a member may read, by ONE
rule applied in SQL on every read path that serves events, failing closed, never logged, so that no path can forget the rule.
As a member of a `shared` room (the default of every preset and of every room without the setting), I want nothing to change.

Follows `create-room-presets-power-levels-topic` (the presets write `shared`, the premise of `es`), `sync-membership-partition` (the D3
tie order of member events, the leave window, the `es` note on re-joiners), `member-event-prev-content` (D8: the BINDING rule "omit the
three predecessor keys when the predecessor is not visible", the test that pins the deviation), `state-writer-redaction` (prune on read,
the fail-closed seam rule M1 for a real db module) and `membership-state-model` (the member SQL fragments, the event-based current
state, D5 "current state is not gated by `history_visibility`"). Closes `es`. **One pipeline run** (see "Sizing"); new follow-ups `gj`,
`gk`, `gl`.

## Premises verified (2026-10-20, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `5c852949`, read-only)

### Spec (Matrix v1.18, local copy `skills/nebu-agent-oracle/matrix-spec/v1.18/`)

| # | Premise | Verified text | Verdict |
|---|---|---|---|
| S1 | The four values and their meaning | `client-server-api/index.html` "Room History Visibility" (l.45389ff): "In all cases except `world_readable`, a user needs to join a room to view events in that room." `world_readable` "All events while this is the `m.room.history_visibility` value may be shared by any participating homeserver with any authenticated user, regardless of whether they have ever joined the room"; `shared` "Previous events are always accessible to newly joined members. All events in the room are accessible, even those sent when the member was not a part of the room"; `invited` "Events are accessible to newly joined members from the point they were invited onwards. Events stop being accessible when the member's state changes to something other than `invite` or `join`"; `joined` "... from the point they joined the room onwards. Events stop being accessible when the member's state changes to something other than `join`". | CORRECT. |
| S2 | Visibility is decided at the event's position | Same section: "These options are applied at the point an event is sent. Checks are performed with the state of the `m.room.history_visibility` event when the event in question is added to the DAG. This means clients cannot retrospectively choose to show or hide history to new users if the setting at that time was more restrictive." Server behaviour: "The rules governing whether a user is allowed to see an event depend on the state of the room at that event." | CORRECT. A change of the setting affects only LATER events. Nebu has no DAG: "the state at an event" is computed in the `(origin_server_ts, event_id)` order Nebu serves (D2, Oracle Q1). |
| S3 | The algorithm | "1. If the `history_visibility` was set to `world_readable`, allow. 2. If the user's `membership` was `join`, allow. 3. If `history_visibility` was set to `shared`, and the user joined the room at any point after the event was sent, allow. 4. If the user's `membership` was `invite`, and the `history_visibility` was set to `invited`, allow. 5. Otherwise, deny." | CORRECT. Every Nebu reader of events is CURRENTLY joined (C2), so rule 3 holds for every event a reader is offered: `shared` is "visible" for every Nebu reader (D3; also the re-joiner's gap, spec-allowed). |
| S4 | Default and unknown values | "By default if no `history_visibility` is set, or if the value is not understood, the visibility is assumed to be `shared`." Security considerations: "The default value for `history_visibility` is `shared` for backwards-compatibility reasons." | CORRECT. Legacy rooms without the event and any unknown / non-string / malformed value read as `shared` (D4; no validation on write today: follow-up `gj`). |
| S5 | `m.room.history_visibility` events themselves | "the user should be allowed to see the event if the `history_visibility` before or after the event would allow them to see it." | CORRECT (D5 (a)). |
| S6 | The user's own member events | "Likewise, for the user's own `m.room.member` events, the user should be allowed to see the event if their membership before or after the event would allow them to see it. (For example, a user can always see `m.room.member` events which set their membership to `join`, or which change their membership from `join` to any other value, even if `history_visibility` is `joined`.)" | CORRECT (D5 (b)). Other users' member events follow the ordinary rule. |
| S7 | Leavers | "After a user has left a room, they may see any events which they were allowed to see before they left the room, but no events received after they left." | CORRECT. Nebu: a leaver gets `403` on `/messages` / `/event` / `/relations` (unchanged, `fg` (b), now follow-up `gl` (a)); his `rooms.leave` window lies inside his joined interval (C6) and stays conformant. |
| S8 | `GET /rooms/{roomId}/event/{eventId}` | `api.json`: "You must have permission to retrieve this event e.g. by being a member in the room for this event." `404` "The event was not found or you do not have permission to read this event." | CORRECT: an invisible event is a `404`, indistinguishable from an unknown one (D7). |
| S9 | `GET /rooms/{roomId}/messages` | `from`: "If it is not provided, the homeserver shall return a list of messages from the first or last (per the value of the `dir` parameter) visible event in the room history for the requesting user." `end`: "If no further events are available (either because we have reached the start of the timeline, or because the user does not have permission to see any more events), this property is omitted from the response." `403` "You aren't a member of the room." | CORRECT: invisible events are skipped, the page is filled from visible events; when no visible event remains there is no `end` token (Nebu answers `"end": ""`, a labelled deviation from "omitted", D6). |
| S10 | `GET /relations` | `404` "The parent event was not found or the user does not have permission to read this event (it might be contained in history that is not accessible to the user)." | CORRECT: an invisible parent is `404`; the children are filtered by the same rule (D8). |
| S11 | `/context`, `/search`, `/threads` | `/context`: routed nowhere in Nebu (`fk`). `/search` (CS "Server Side Search"): "Only events that the user is allowed to see will be searched"; Security considerations: "The server MUST only return results that the user has permission to see"; the search covers the rooms the user "has been in, including those that they have left" (Oracle gate). `/threads`: "starts paginating from the most recent event visible to the user (as per history visibility rules)"; not routed in Nebu. | CORRECTED by the Oracle gate: per-result filtering of `/search` is a spec MUST (D9). Nebu searches only CURRENTLY joined rooms (the `room_members` gate, unchanged): labelled "search covers currently joined rooms only (spec: also left rooms; `gl`)". `/context` and `/threads` stay unrouted (notes on `fk`). |
| S12 | `unsigned.prev_content` | every ClientEvent schema: "only returned if the event is a state event, and the client has permission to see the previous content." | CORRECT: the BINDING `es` rule of member-event-prev-content D8 (D10). |
| S13 | Current state vs. events | `/join`: "After this call, the client is allowed to see all current state events in the room, and all subsequent events associated with the room until the user leaves the room." | CORRECT: the current state (`/sync` `state`, `/members`, `/initialSync` `state`) is NOT gated (membership-state-model D5 stays; D11). |
| S14 | `guest_access`, peeking | `world_readable` allows non-members (peeking, guests). Nebu has no guest accounts (`protected.ex` l.509-512 `is_guest` always false) and no peeking (`gf`). | Labelled (D12). |

### What Nebu does today (code)

| # | Question | Verified state |
|---|---|---|
| C1 | Where `history_visibility` / `guest_access` are used | `grep` over `server/lib`: written by the presets (`event_dispatcher/server.ex` l.1462-1474: `public_chat`, `private_chat`, `trusted_private_chat` ALL write `{"history_visibility": "shared"}`; `guest_access` `forbidden` / `can_join`), writable through `PUT /state` (the writable list l.4232-4233, level 100 by default, `room/power_level.ex` l.44), copied by the upgrade (`copy_plan/5` / `reduce_access_content/2` l.8931-8961: an oversized event is REDUCED, `history_visibility` falling back to `joined`), read ONLY by the room summary / hierarchy (`room_visible?/3` l.4783-4787, `history_visibility/1` l.4815-4821 default `shared`, `build_room_summary/3` l.4789-4805, `room_summary.ex` l.32-33). No content validation on `PUT /state` for the type (only name / topic / canonical alias are validated, l.4277-4281). **No read path filters events by it** (the gap of `es`). |
| C2 | Who may read events (the gates, unchanged by this story) | `/messages` `get_messages/2` l.3326-3361: `RoomSupervisor.lookup_room/1` (a stopped room is `404 "Room not found"`), then the process member set (`MapSet.member?(state.members, user_id)`, `403`). `/event` `get_event/2` l.9042-9076: the same two gates. `/relations` `get_relations/2` l.8980-9034: `room_registry_module().get_state/1` (`:noproc` -> `404`), member set, then `event_in_room?/2` (`room/db.ex` l.722-728, a DB failure reads as "absent"). `/initialSync` (`protected.ex` l.1716-1750): `get_room_state/2` (joined members only, membership-state-model D5) + `get_messages/2` (`limit: 20`). `/search` `search_messages/2` l.8452-8545 -> `Search.DB.search_messages/5` (`search/db.ex` l.16-80): rooms with a `room_members` row `left_at IS NULL` (the ROW, not the process set). `/sync`: the partition (join class) per room. Every reader of events is therefore CURRENTLY joined; leavers and invitees read no event page (their `rooms.leave` window / stripped `invite_state` aside). |
| C3 | The event reads that serve events to a member | (a) `Room.DB.fetch_events/4` (`room/db.ex` l.771-861, keyset on `(origin_server_ts, event_id)`, `limit + 1` to detect a next page; `/messages`, the initial `/sync` timeline `initial_join_rooms/2` l.5141 and its `:noproc` path l.5179, and so `/initialSync` `messages`); (b) `fetch_events_since/3` (l.643-689, `origin_server_ts > ts(anchor)`, oldest 20; the incremental `/sync` `fetch_delta_rooms/3` l.5975-5977; an `{:error, _}` drops the room SILENTLY, l.6044); (c) `fetch_event/2` (l.692-717; `/event` l.9062, the incremental thread-root fetch `thread_root_updates/3` l.9133-9161: the ROOT of a thread reply in the delta is fetched by id and prepended, whatever its age; the redaction writer's target check `room/server.ex` l.1302, a writer, not a read path); (d) `fetch_events_by_relation/5` (l.1168-1213; `/relations` l.9024 and `attach_thread_aggregations/3` l.9087-9123, whose `unsigned_relations` is NOT rendered today: `pb/core.pb.ex` l.12, comment l.9097-9099); (e) `Search.DB.search_messages/5`; (f) the leave window `leave_window_events/3` (l.2206-2230) via `build_leave_room/3` l.5623-5648; (g) the predecessor lookup `fetch_state_predecessors/1,2` (`@sql_state_predecessors` l.1990-2025, ONE statement for any number of slots, possibly of several rooms) called by `event_maps_to_core_events/1` (l.3526-3546: every `/messages`, `/event`, `/relations` and `/sync` timeline), `attach_leave_predecessors/1` (l.5656-5670) and `attach_predecessors_to_state_events/3` (l.6460-6470: the `/sync` state, `/members`, `/initialSync` `state`). No other client route serves events: `/context`, `/threads`, `/notifications`, `GET /state*` are not routed (`protected.ex` route list; `bf`, `fk`); `/sync` carries no `m.receipt` ephemeral events and no unread counts (`grep`: none); typing carries no content. |
| C4 | The order Nebu serves | `events` has NO depth / stream position (`000001_init.up.sql` l.211-223: `event_id`, `room_id`, `sender`, `event_type`, `content`, `origin_server_ts`, `signatures`, `state_key`, `search_vector`; `redacts` since 000051). `/messages` orders `(origin_server_ts, event_id)`; the incremental `/sync` `origin_server_ts`; member events among themselves the D3 order `origin_server_ts DESC, @sql_member_rank ASC, event_id DESC` (`room/db.ex` l.1611-1641). Indexes: `events_room_id_ts_idx (room_id, origin_server_ts)`, `events_room_state_idx (room_id, event_type, state_key, origin_server_ts DESC) WHERE state_key IS NOT NULL`. A non-state event of a state TYPE (sent through `/send`) is stored with `state_key` NULL (`get_room_name/1` doc l.1117-1131): it is never state. |
| C5 | How "membership at an event" can be read | The viewer's own member events of a room: `events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $viewer` (index-served, `events_room_state_idx`), normalised by `@sql_member_membership_raw` / `@sql_membership_normalised` (both JSONB forms; unknown -> `leave`) and ordered by `@sql_member_rank` (D3). `room_members` (`000001` l.199-205: PK `(room_id, user_id)`, `joined_at`, `left_at`; a re-join sets `joined_at` anew, `room/db.ex` l.54-57). Member event writes are fail-open in places (sync-membership-partition: "a re-join whose join event write failed", `window_start/2` l.5682-5685 uses `joined_at` for that reason); legacy members may have no member event at all (membership-state-model D8 (a)). |
| C6 | The leave window | `build_leave_room/3` l.5623-5648 + `window_start/2` / `window_end/1` l.5682-5688: events STRICTLY between `max(anchor, P = the join event, joined_at)` and `min(L = the leave event, left_at)`, only when the previous member event was `join`. Every such event lies inside the viewer's joined interval, so it is visible under EVERY `history_visibility` value (rule 2) and the strict bounds already exclude the same-millisecond boundary events (D2 (c)). |
| C7 | Thread aggregations / redactions | `attach_thread_aggregations/3`: `unsigned_relations` is computed but not rendered (C3 (d)). Redaction prune on read: `event_maps_to_core_events/1` -> `apply_redactions/1` (one `redactions_for/1` per call, fail closed, l.3548-3600); the redaction event is attached as `unsigned.redacted_because` to a redacted original, whoever may see the redaction itself. |
| C8 | Failure behaviour today | `get_messages/2` matches `{:ok, ...} =` (a DB error is a `MatchError`: an unhandled 500); `get_event/2` / `get_relations/2` raise `internal` with `inspect(reason)` in the MESSAGE (hidden by `Http.map_error/1` l.63-116, but against the log rule if logged); `search_messages/2` logs `inspect(reason)` (l.8538, a Postgrex error can echo the statement); the incremental `/sync` drops a room on `{:error, _}` (C3 (b)). `Http.map_error/1`: every `not_found` without errcode is `404 M_NOT_FOUND "Room not found"` (l.90-91): an unknown event on `/event` answers that body today. |
| C9 | Test fakes | 20 test files define their own `fetch_events/4` / `fetch_event/2` / `fetch_events_since/3` fakes, 2 a `search_messages/5` fake (`grep`); `Nebu.Matrix.Room.DBBehaviour` has callbacks for `fetch_events/4` (l.135), `fetch_events_since/3` (l.150), `fetch_events_by_relation` (l.320), `fetch_event/2` (l.358). |
| C10 | Tests that pin today's behaviour | `member_prev_content_http_test.exs` l.947-967 "history_visibility JOINED, pins known deviation es: C still gets prev_content AND /messages returns the old topic (MUST flip when es ships)"; l.930-945 (`shared`: the keys delivered) stays. Docs suites pinning words of the `es` row: `create_room_presets_docs_test.exs` l.64 ("history_visibility", "guest_access"), `member_prev_content_docs_test.exs` l.128 ("D8", "omit", "binding", "history_visibility") and l.194 (06-runtime "Key design facts": "history_visibility" and "`es`"), `sync_membership_partition_docs_test.exs` l.110 ("re-joined"). The id line of `follow-ups.md` ("unused: ... `gj` onward") is pinned by ELEVEN docs suites (C11). |
| C11 | The id line | `follow-ups.md` l.41: "... `ge`-`gi`: membership-state-model); unused: be, bp, `cq` (deliberately free) and `gj` onward". `grep` of `docs/`: `gj`, `gk`, `gl` appear in no row. Pinned (`~r/unused:[^.]*\`gj\` onward/`) by `create_room_invites_docs_test.exs` l.145, `create_room_presets_docs_test.exs` l.141, `event_size_limit_docs_test.exs` l.160, `member_prev_content_docs_test.exs` l.170, `membership_write_limits_cycle1_docs_test.exs` l.131, `membership_write_limits_docs_test.exs` l.252, `moderation_routes_docs_test.exs` l.449, `sync_membership_partition_docs_test.exs` l.145, `power_levels_docs_test.exs` l.411, `state_writer_redaction_docs_test.exs` l.410, `membership_state_model_docs_test.exs` l.521. |
| C12 | Element 1.12.15 | NOT re-verified in this story (no bundle extraction, no docker). Known from earlier stories: Element writes the setting with `PUT /rooms/{roomId}/state/m.room.history_visibility/` from Room settings > "Security & Privacy" > "Who can read history?" (options "Anyone" = `world_readable`, "Members only (since the point in time of selecting this option)" = `shared`, "Members only (since they were invited)" = `invited`, "Members only (since they joined)" = `joined`): **UNVERIFIED** labels and selectors for 1.12.15. Element paginates with `/messages?dir=b` from the `/sync` `prev_batch` and stops when `end` is absent. |

### Sizing

One story, one pipeline run, high: about 450-550 lines in `server/lib`: `Room.DB` (the visibility fragment, about 120 lines of SQL and
docs; four viewer-aware reads and the predecessor option, about 180), `Search.DB` (the fragment in both statements, about 20),
`EventDispatcher.Server` (the viewer passed through `get_messages`, the two initial-`/sync` paths, `fetch_delta_rooms`,
`thread_root_updates`, `get_event`, `get_relations`, `event_maps_to_core_events`, the three predecessor callers, the test-module seam,
the fail-closed mapping, about 180). No migration, no new route, no new audit action, no new statement on any path (the fragment
lives INSIDE the existing statements), no UI. **Split rule:** if the ATDD reference exceeds about 700 lines in `server/lib`, the dev stops
and reports; the orchestrator may then move `/search` (D9) into a story 2 under `es`, never a half-filtered path set: every path that
stays unfiltered is then listed in the scope doc as "not filtered yet (`es`)".

## Decisions

- **D1 (ONE visibility fragment in `Room.DB`; ADR-018).** The rule lives in ONE SQL definition in `Nebu.Matrix.Room.DB`: a module
  attribute `@sql_history_visibility` (a constant text, no value interpolated; every value a bound parameter; the leading marker
  comment `/* history_visibility */`, pinned by the statement counters and the source pins), built from the EXISTING member fragments
  (`@sql_member_membership_raw`, `@sql_membership_normalised`, `@sql_member_rank`; no second rank definition). It is a set of CTEs over
  the parameters `rooms` (`text[]`) and `viewer` (`text`) that yields, per room, (a) the visibility SEGMENTS (D2) and (b) the visibility
  of the SPECIAL events (D5); a consumer statement then decides "event `e` is visible to the viewer" by ONE predicate shape:
  `e` is a special event -> its D5 verdict; otherwise the D2 verdict of the segment that contains `e.origin_server_ts`. `Search.DB` uses
  the SAME text through `Room.DB.history_visibility_sql/0` (`@doc false`, interpolated at compile time into the two search statements;
  ONE definition, no copy; ADR-020 does not apply: one namespace). No cache, no table, no process state (cluster-safety: read per
  statement from committed events).
- **D2 (state at an event; Nebu has no DAG; the same-millisecond rule).** For a room R, the viewer V and a timestamp T:
  (a) `H(<T)` = the `history_visibility` of the latest `m.room.history_visibility` STATE event (`state_key = ''`; a row with `state_key`
  NULL, sent through `/send`, is never state and never counts, C4) with `origin_server_ts < T` (ties `event_id DESC`); `H(<=T)` the same
  with `<= T`; no such event, an unknown / non-string / missing / unparseable value -> `shared` (S4; both JSONB forms read like
  `@sql_member_membership_raw`). (b) `M(<T)` / `M(<=T)` = V's membership by his latest member event (`state_key = V`) with
  `origin_server_ts < T` / `<= T` in the D3 order, normalised (`fg` (k): unknown -> `leave`); none -> `none` (never a member). (c) An
  ORDINARY event at T is visible iff `allow(H(<T), M(<T))` AND `allow(H(<=T), M(<=T))` (the state just before and just after the
  millisecond; when no hv / member event of V lies at T the two coincide): an event in the same millisecond as V's join, leave, kick,
  ban or an hv change is judged most restrictively (the leave-window rule of sync-membership-partition, C6). **Labelled** "the state at
  an event is the state before it in the `(origin_server_ts, event_id)` order; an event in the same millisecond as a history-visibility
  change or a member event of the viewer is visible only if both the state before and after that millisecond allow it: Nebu rule (no
  DAG)". (d) `allow(h, m)` = `h = 'world_readable'` OR `h = 'shared'` OR `m = 'join'` OR (`m = 'invite'` AND `h = 'invited'`). `shared`
  is `allow` without condition because every reader is currently joined (S3 rule 3, C2): it covers the history before the first join AND
  the gap of a re-joiner (the `es` note, spec-allowed). `knock` and `ban` and `leave` and `none` allow only under `world_readable` /
  `shared`. (e) Segments: the distinct timestamps of the hv events of R and of V's member events (and the D4 synthetic join) are the
  BOUNDARIES; the open intervals between consecutive boundaries (and before the first / after the last) and the boundary points are the
  segments, each with its D2 (c) verdict; their number is O(hv events of R + member events of V in R) (D13).
  (f) **The timestamp invariant (Oracle gate; labelled, residual on `gk`).** D2 trusts the `origin_server_ts` order. The member
  writers stamp `max(now, not_before, latest member ts + 1)` (`room/server.ex` l.41, l.155, l.180, l.196) and the hv write path (the
  generic state writer `write_state/5`) stamps `max(now, not_before, latest slot ts + 1)` (`room/server.ex` l.32, l.312): an hv change
  and a member event are therefore never stamped before an earlier event of their slot. Messages (`/send`) are stamped with the clock of
  the node that runs the room process and are NOT clamped against the latest hv event: clock skew (a room that moves to another node, a
  Horde handoff) can stamp a message sent under `joined` before the hv change and so place it in the earlier `shared` segment (visible
  to later joiners). No writer clamp in this story; the outcome is pinned by a test (AC22 (12)). Labelled "visibility follows the
  `origin_server_ts` order: hv and member events are stamped after the latest event of their slot; a message stamped before an hv change
  (clock skew between nodes) is judged under the earlier setting: known Nebu invariant (`gk`)".
- **D3 (no sender exception, no creator exception).** The spec has none: a user's own messages were sent while he was joined (visible
  by rule 2). The createRoom chain (`m.room.create`, the creator's join, the levels, the preset events) lies BEFORE the room's first hv
  event, so it is `shared` and visible to every later member also in a room created with `joined` (spec-conformant; the same for the
  replacement room of an upgrade, whose copied hv event follows its create / join / levels / bans). Labelled "the events before a
  room's first history-visibility event are `shared` (spec default)".
- **D4 (legacy and fail-open member writes; labelled).** When V's `room_members` row of R has `left_at IS NULL` (the row the `/search`
  gate reads; the gates of C2 passed) and V's latest member event in R is NOT `join` (none at all: a legacy member, membership-state-model
  D8 (a); or a re-join whose join event write failed, C5), a SYNTHETIC `join` boundary at `room_members.joined_at` is added for the
  computation (the room process / row is authoritative for "joined now"; `window_start/2` uses `joined_at` for the same reason). Labelled
  "a joined member without a join event is treated as joined since `room_members.joined_at`: legacy / fail-open writes". A viewer with
  neither a member event nor a row (never reachable through the gates) sees only `world_readable` / `shared` events.
- **D5 (the special events, S5 / S6).** (a) An `m.room.history_visibility` STATE event X at T: visible iff, with `M` judged on both
  sides of T as in D2 (c), `allow(H(<T), M)` OR `allow(X's own value, M)` (the setting before OR after X). (b) A member event X of the
  VIEWER (`state_key = V`) at T: visible iff, with `H` judged on both sides as in D2 (c), `allow(H, V's membership before X)` OR
  `allow(H, X's own membership)` (before = the D3-latest member event of V strictly before X in the D3 order; none -> `none`): V always
  sees his own join, his own leave, a kick or a ban of himself, and under `invited` his invitation; under `joined` his invitation is
  hidden (spec example, S6). (c) Other users' member events and every other state event: ordinary (D2 (c)). (d) An event that is both
  (impossible: different types) needs no rule. (e) **Explicit outcomes (Oracle gate).** A re-joiner F of a `joined` room: the UNBAN
  event of F (`ban` -> `leave`, sent while F was out) is visible by D5 (b) only if `allow(H, ban)` or `allow(H, leave)`: hidden under
  `joined` and `invited` (`/event` `404`, absent from `/messages`); a RE-INVITE of F sent in the gap is hidden under `joined` (before
  `leave`, after `invite`: neither allows) and visible under `invited` (after `invite`), and under `invited` F then sees the gap events
  from that re-invite onward (`M = invite`).
- **D6 (`GET /rooms/{roomId}/messages` and the initial `/sync` timeline).** A new read `Room.DB.fetch_visible_events(room_id, viewer,
  direction, limit, from_token)` with the answer of `fetch_events/4` (`{:ok, events, next_batch, prev_batch}`): the keyset cursor and
  the order stay, the visibility is applied IN the statement, the `limit + 1` look-ahead counts VISIBLE events only, so a page is filled
  from visible events and `next_batch` is `""` when no visible event remains (S9). **`end` (test review STORY-1, decided: option A):** the
  router keeps emitting `"end": resp.next_batch` (pinned by `matrix_router_test.exs` l.737 and `matrix_client_compat_test.exs` l.2828;
  the LAST page of every room already answers `"end": ""` today): "no `end` token" means the key is absent OR `""`; a labelled
  deviation (spec: omitted). **Cost shape
  (BINDING):** the scan is DRIVEN by the visible segments (a `LATERAL` per visible segment over `events_room_id_ts_idx` with the cursor
  bound and `LIMIT limit + 1`, merged, ordered, limited), plus the visible special events of D5 inside the cursor bound; never "scan
  the room in order and filter", which would read the whole invisible history of a `joined` room on every backward page. Bound: at most
  (visible segments + 1) x (limit + 1) index rows per page. `get_messages/2` calls it with the caller id; the initial `/sync`
  (`initial_join_rooms/2`, both code paths) calls it with the syncing user (`limit` 20, `dir` `b`): a member who joined a `joined` room
  later gets a timeline that starts at his join; `/initialSync` `messages` inherit it. **`limited` (Oracle gate; RELAXED by test review
  STORY-4 (b), BINDING):** `limited` is computed from the VISIBLE events of the page as today (`length(events) >= 20`, NO look-ahead):
  `false` when fewer visible events than the limit exist; with EXACTLY 20 visible events it is `true` (as-is, pinned by the boundary pair
  19 / 20 / 21, AC23 (c)). A backward `/messages` page from any token that has no visible event before it returns an empty `chunk` with no
  `end` token (absent or `""`) and `start` = the input token; a page that has more visible events carries a non-empty `end` (positive
  control). The incremental `/sync` read `fetch_visible_events_since(room_id, viewer, last_event_id, limit)` (a nil / `""` anchor and an
  unknown anchor id read from the start, as `fetch_events_since/3` does) is segment-driven too: the OLDEST 20 VISIBLE events after the anchor (never "oldest 20, then
  filter", which would starve the room behind a gap of invisible events). A `from` / `to` token pointing into an invisible region (taken
  from another user's pagination or from the viewer's own token from before a leave) is accepted and never yields an invisible event, for
  `dir=b` and `dir=f`.
  Labelled "`/messages` skips the events the viewer may not see; when no visible event remains there is no `end` token (the key is absent or empty): Nebu answers `""`, spec: omitted" and "the `/sync` timeline is not `limited` when fewer visible events than the limit exist".
- **D7 (`GET /rooms/{roomId}/event/{eventId}` and the incremental thread roots).** `Room.DB.fetch_visible_event(event_id, room_id,
  viewer)` -> `{:ok, map}` | `{:error, :not_found}` | `{:error, reason}`: an existing but INVISIBLE event is `{:error, :not_found}`.
  **404 body (decided, Oracle suggestion; checked: no test pins the "Room not found" text for an unknown EVENT, only for unknown rooms;
  `redaction_http_test.exs` already pins `404 M_NOT_FOUND "Event not found"` for the redaction route, server.ex l.326):** an unknown
  event and an invisible event of a readable room both answer `404 M_NOT_FOUND "Event not found"` (errcode and fixed text set at the
  source), byte-identical (no existence oracle; S8); an unknown / stopped ROOM keeps `404 "Room not found"` (unchanged). The same for
  `/relations` (D8). The dispatcher messages `"event not found: #{event_id}"` (l.9013, l.9070) are replaced by the fixed text.
  `thread_root_updates/3` (the incremental `/sync`) fetches a thread ROOT through the same read with the syncing user: an invisible root is
  not prepended (it was a leak: the root of a reply in the delta was fetched whatever its age). The redaction WRITER's target check
  (`room/server.ex` l.1302) is unchanged (a writer; follow-up `gl` (c)).
- **D8 (`GET /relations`).** The parent check becomes "the parent is a VISIBLE event of the room" (`fetch_visible_event/3` or an
  equivalent EXISTS form of the fragment, one statement): an invisible parent answers exactly the unknown-parent `404 M_NOT_FOUND "Event not found"` (S10, D7). The children page is filled from
  visible children and `next_batch` is omitted when none remain. The children
  (`fetch_visible_events_by_relation(room_id, viewer, event_id, rel_type, limit, opts)`) are filtered by the same predicate in their
  statement (an EXISTS form is enough: the relation filter already bounds the scan). `attach_thread_aggregations/3` passes the viewer too
  (its children read becomes the visible read; nothing is rendered today, C7; no extra statement). `/relations` keeps its other rules.
- **D9 (`POST /search`).** Both statements of `Search.DB` get the fragment for the viewer (`$1`, the trusted session user, never the
  body) and ALL rooms of the existing `room_members` gate (`rooms` = the gate's room ids, in the same statement), and keep a result only
  when it is visible; ranking, `LIMIT` / `OFFSET`, the encrypted-room and redaction exclusions stay; `next_batch` / `total_count` keep their
  semantics over the filtered results. Cost: one segment computation per joined room of the viewer and one segment probe per matching row
  (the matching rows are scanned today already for the ranking). The `Logger.error(... inspect(reason))` of `search_messages/2` (C8)
  becomes a value-free ERROR line (`db_error_class/1`); the client answer stays the generic `500 M_UNKNOWN "Internal server error"`
  ("search failed" is the internal message, hidden by `Http.map_error/1`). The per-result filter is a spec MUST
  (S11). Left rooms are not searched (the gate is unchanged): labelled "search covers currently joined rooms only (spec: also left
  rooms; `gl`)". `order_by` is not read today (ranking order always); `count` (`total_count`) is computed over the FILTERED results;
  `events_before` / `events_after` stay empty (server.ex l.8524-8528).
- **D10 (`unsigned.prev_content` / `prev_sender` / `replaces_state`; the BINDING `es` rule of member-event-prev-content D8).** The
  predecessor lookup gets the viewer: `fetch_state_predecessors(slots, viewer: user_id)` (combinable with `strict: true`): the predecessor
  is computed EXACTLY as today (the latest earlier row of the slot, D3 order for member slots) and the three keys are attached only when
  THAT predecessor is visible to the viewer (D2 / D5); an invisible predecessor omits all three keys (never "the latest VISIBLE earlier
  row": that would invent a predecessor). Still ONE statement per call (the fragment over the slot rooms inside it). Every caller passes
  the viewer: `event_maps_to_core_events/2` (timeline, `/messages`, `/event`, `/relations`), `attach_leave_predecessors/2` (the leaver;
  his window predecessors), `attach_predecessors_to_state_events` (the `/sync` state, `/members`, `/initialSync` `state`: the CURRENT
  state is served, D11, but its `prev_content` is the PREVIOUS content and follows S12). The lenient lookup's failure keeps answering
  `%{}` (no keys: the conservative direction); the strict one keeps its `503` / `500` mapping. The test of C10 l.947 FLIPS (AC21 (b)).
  **Viewer nil / `""` (test review STORY-5, BINDING):** `fetch_state_predecessors(slots, viewer: nil | "")` (with or without `strict:
  true`) and `build_state_events(..., viewer: nil)` serve NO predecessor keys (fail closed: `%{}` / `{:ok, %{}}`), never the unfiltered
  statement; only a call WITHOUT the `viewer:` option keeps the old behaviour, and only internal (non-client) callers may use it; the
  dispatcher threads the viewer into every `build_state_events(..., true, ...)` caller. Labelled "`replaces_state` is omitted together with `prev_content` / `prev_sender` when the predecessor is not visible: Nebu choice (no id of an invisible event is served)"
  (`matrix_client_compat_test.exs` l.2370 stays green: its reader, the creator, sees the predecessor).
- **D11 (what is NOT gated; labelled).** (a) The current state (`/sync` `rooms.join.state`, `/members`, `/initialSync` `state`, the room
  summary / hierarchy) stays ungated (S13, membership-state-model D5): a member who joined a `joined` room sees the current topic, name,
  members and bans, but not the earlier events nor their contents through `prev_content`. Labelled "the current state is visible to every
  joined member; `history_visibility` gates events, not the current state". (b) `rooms.invite` stripped `invite_state` (unchanged). (c)
  The leave window (C6): NOT filtered in SQL (no change): by construction every event of it is visible (strictly inside the joined
  interval); pinned by a test (AC5 (f)) instead of a code change. (d) `unsigned.redacted_because` of a VISIBLE original whose redaction
  event is itself not visible to the viewer: served as today (the prune removes content; the attached redaction carries the redactor
  and the reason) and **labelled "a redacted event visible to the viewer carries its `redacted_because` even when the redaction event
  itself is outside the viewer's visible history: Nebu choice (Oracle Q8)"**.
- **D12 (`world_readable`, `guest_access`, peeking; labelled).** For members `world_readable` is visible like `shared`. Non-members keep
  `403` on every event read (no peeking, `gf`): labelled "`world_readable` rooms are not readable by non-members: no peeking (`gf`)".
  `guest_access` is stored and served (presets, `PUT /state`, the summary's `guest_can_join`) and has no effect: labelled "`guest_access`
  has no effect: Nebu has no guest accounts".
- **D13 (cost and bounds; as of security cycle 2).** The visibility adds no statement (the fragment is inside the existing
  statements); the request reads add ONE `SET LOCAL statement_timeout` each (security cycle 1, the AC13 pins); the `/sync` paths keep
  their recorded counts (`member_prev_content_http_test.exs` `@baseline_initial_sync_statements` 54 unchanged). The original cost
  claim ("O(hv events + member events) index rows, no statement timeout") was wrong for the first fragment (quadratic); the bounds that
  hold now are those of the amendment below. The operator query **Q-hv2** (07-deployment) lists the rooms with the most hv events and the
  (room, user) pairs with the most member events. EXPLAIN pins (AC10) prove the index use.
- **D13 amended (security cycle 1, BINDING decisions of `code-review-findings.md`, Kassandra HIGH #1 / MEDIUM #2).** The cost
  statement above was wrong: the first fragment was O(boundaries x hv events) per statement (correlated probes over materialised
  CTEs) and each candidate row scanned every segment. Now: (a) the fragment is O(B log B) (window functions and binary search, no
  CTE join whose plan depends on row estimates; 3 000 hv events in one room: a later joiner's backward page 5.2 s -> 46 ms); (b) a
  per-room cap of 256 `m.room.history_visibility` state events in the room-process writer (`429 M_LIMIT_EXCEEDED`, nothing written;
  seam `:nebu, :hv_event_cap`; security cycle 2, Kassandra N1: a change STRICTLY MORE RESTRICTIVE than the current setting
  (`world_readable` < `shared` < `invited` < `joined`, a stored unknown value counts as `shared`) passes the cap, so the cap never
  blocks tightening and adds at most 3 rows above it; a non-empty state key is no setting and is not capped; not counted: the
  createRoom chain, the preset event plus at most 64 `initial_state` entries, written before the room is reachable); (c) a PUT of `m.room.history_visibility`, `m.room.guest_access`, `m.room.join_rules` costs a
  `moderation` token; (d) the request reads (`/messages` incl. `/initialSync` messages, `/event`, `/relations`, `/search`) run under
  `SET LOCAL statement_timeout = '2s'` (the handled `500`): ONE `SET LOCAL` per such request, the AC13 counts move by exactly that
  (re-pinned, Change Log); NOT on `/sync`; (e) the incremental read computes nothing for a room without new events; a thread
  aggregation reads children only when `count_thread_children/2` > 0 (the AC13 counts of `/sync` do not move). Residuals on `gk`.
- **D14 (fail closed; the seam).** (a) For the REAL `Nebu.Matrix.Room.DB` / `Nebu.Matrix.Search.DB`, a failing filtered read is a
  handled error with a generic body and a value-free ERROR log (room id when there is one, `db_error_class/1`): `/messages`, `/event`,
  `/relations`, `/initialSync`, the initial `/sync`: `500 M_UNKNOWN` "Internal server error"; the incremental `/sync`: `503 M_UNAVAILABLE`
  (no since token persisted, the client retries with the same token; replaces the silent room drop of C3 (b), which let the global anchor
  pass the room's events; labelled "`M_UNAVAILABLE`: Nebu errcode, as elsewhere (`protected.ex`)": not a spec errcode, used by Nebu's
  existing `503` answers, `protected.ex` l.115, l.1824); `/search`: the generic `500 M_UNKNOWN "Internal server error"`. NEVER an unfiltered page and never a silently empty one. The
  `inspect(reason)` messages of `get_event/2` / `get_relations/2` (C8) are replaced by fixed texts. (b) **Test-module seam (BINDING):**
  the dispatcher reaches the new reads through `messages_db_module()` (and `search_db_module()`); a TEST db module that does not export
  the viewer-aware function falls back to its unfiltered function (the 20 fakes of C9 keep working); the real modules never fall back (a
  source pin: the fallback is guarded by `mod != Nebu.Matrix.Room.DB`, the M1 rule of state-writer-redaction). The `DBBehaviour` gains
  the four viewer-aware callbacks as `@optional_callbacks`. The unfiltered `fetch_events/4`, `fetch_events_since/3`, `fetch_event/2`,
  `fetch_events_by_relation/5` stay in `Room.DB` for internal callers (the redaction writer, tests) but have NO client-serving caller in
  `event_dispatcher/server.ex` (AST pin, AC11).
- **D15 (redactions, upgrades, bans, leavers: what changes and what not).** Redaction: the prune applies to every visible event as today
  (it only removes data); a redaction EVENT is an ordinary event under D2 (a viewer who may not see it does not get it in his timeline);
  D11 (d). Upgrade: the replacement room starts its own history with the copied hv (D3); the old room stays archived and unserved
  (`gi` (e), unchanged). Banned / kicked / left users: `403` on the event reads (C2, unchanged); a later re-join under `invited` /
  `joined` hides the gap (the ban / leave segments deny), under `shared` shows it (spec). Knock: no knock API (`fg` (d)); a `knock`
  membership denies outside `shared` / `world_readable`.
- **D16 (logs; No Sensitive Data in Logs Law).** No event content, no event id list, no hv value per viewer and no segment is logged at any
  level by the new code; an ERROR names the room id (or "search") and `db_error_class/1` only; the existing `RequestLogger` DEBUG redactor
  is unchanged (event contents of `/messages` responses are not request payloads).
- **D17 (docs).** Scope doc rows `/messages`, `/event`, `/relations` (three rows), `/search`, `/sync`, `/initialSync`, `PUT
  /state/{eventType}` (the hv note); `docs/architecture/06-runtime.md` (the D8 visibility rule of the predecessor lookup rewritten: "the
  keys are omitted when the predecessor is not visible to the viewer", keeping the words "history_visibility" and "`es`" pinned by
  `member_prev_content_docs_test.exs` l.194); `docs/architecture/07-deployment.md` (a new paragraph, Q-hv1, Q-hv2); `CHANGELOG.md`;
  `follow-ups.md` (AC14).

### Oracle questions (answered by the Oracle gate 2026-10-20: no WRONG decision; S11 corrected; labels, outcomes and 14 tests added, AC22)

- Q1 (S2, D2 (a)-(c)): Nebu has no DAG; "the state of the room at that event" is computed in the `(origin_server_ts, event_id)` order (the
  state BEFORE the event), member events in the D3 tie order; an event in the same millisecond as an hv change or a member event of the
  viewer is judged most restrictively (both sides must allow). Acceptable reading?
- Q2 (S3, D2 (d)): `shared` is "visible" for every reader because every Nebu reader is currently joined (rule 3: "joined at any point
  after the event"), including the gap of a re-joiner. Confirm.
- Q3 (S4, D2 (a)): no hv event, an unknown / non-string / malformed value -> `shared`; a row of the hv type with `state_key` NULL is ignored.
- Q4 (S5, S6, D5): hv events "before or after"; the viewer's own member events "before or after" (his invite hidden under `joined`); other
  users' member events ordinary. Confirm the per-side combination (the other dimension most restrictive).
- Q5 (D12): `world_readable` = `shared` for members; non-members `403` (no peeking, `gf`).
- Q6 (S8, S10, D7, D8): an invisible event on `/event` and an invisible parent on `/relations` answer the unknown-event `404` byte for
  byte; the children of a visible parent are filtered.
- Q7 (S12, D10): `prev_content` (and the two Synapse-compatible keys) omitted when THE predecessor is invisible, also on current-state
  events; never replaced by an older visible row.
- Q8 (D11 (d)): `unsigned.redacted_because` of a visible original whose redaction event is invisible to the viewer: serve (Nebu choice)
  or omit?
- Q9 (S13, D11 (a)): the current state is not gated (only events and `prev_content`).
- Q10 (D4): the synthetic join at `room_members.joined_at` for a currently joined member without a join event (legacy / a failed write).
- Q11 (S9, D6): `/messages` fills pages from visible events; no `end` token when no visible event remains (Nebu: `""`); the initial `/sync` timeline of
  a later joiner starts at his join (`limited` / `prev_batch` from the filtered page).
- Q12 (S11, D9): `/search` filters each result by the same rule (the spec has no explicit text; Synapse does).
- Q13 (D3): the createRoom chain before the first hv event is `shared` and visible to later joiners also in a room created `joined`.
- Q14 (D15): a re-joiner of a `joined` / `invited` room does not see the gap; of a `shared` room he does.

## Out of scope -> follow-ups (added to `follow-ups.md` by this story; the id line says "unused ... `gj` onward" and a grep of `docs/` finds `gj`-`gl` in no row: the new ids are `gj`, `gk`, `gl`; unused from `gm` onward)

- **`gj`** and **`gk`**: see `docs/stories/oauth-broker/follow-ups.md`: `gj` (the values were not validated on write) is CLOSED by
  security cycle 1 (`400 M_BAD_JSON` on PUT state and createRoom `initial_state`, the upgrade copy stays tolerant); `gk` is rewritten:
  the read cost is bounded since security cycle 1 (linear fragment, the cap with the tightening exemption of cycle 2, the moderation tier,
  the request statement timeout; residuals: uncapped member events, no timeout on `/sync`, the clock-skew clamp option).
- **`gl` — Visibility leftovers.** (a) Leavers cannot paginate their pre-leave history (`fg` (b)): with the fragment this is now a gate
  change (allow a leaver on `/messages` / `/event` / `/relations`; his post-leave events are denied by the leave segment; spec S7); (b)
  `unsigned.membership` (`fl` (a)) can be computed from the same segments (the viewer's membership at each event, one statement); (c) the
  redaction WRITER's target check reads the target unfiltered (`room/server.ex` l.1302): a moderator can redact an event outside his
  visible history (the spec has no rule; Synapse allows it); (d) when `unsigned_relations` (thread aggregations) is rendered, its `count`
  and `latest_event` must use the viewer-filtered children (this story passes the viewer already; the count read `count_thread_children/2`
  is not filtered) (note on `fk`); (e) `/search` covers currently joined rooms only (spec: also the rooms the user has left, up to his
  leave; with (a) the same fragment applies). Source: this story (S7, S11, D7, D8, D9, D11). Non-gating.
- Notes (no new id): `es` CLOSED; `fg` ((b) is now `gl` (a): a gate change only); `fk` (a future `/context` MUST use
  `Room.DB.history_visibility_sql/0` for `events_before` / `events_after` / `event` and its `state` follows D11 (a); the search
  `events_before` / `events_after` are EMPTY today (server.ex l.8524-8528): if they are ever filled, they go through the fragment; `/relations` has no pagination today (`from` ignored, `next_batch` always
  `""`): when it is built, it pages over the visible children); `fl` ((a) can use the segments, `gl` (b)); `gf` (peeking: `world_readable` is the place where the
  fragment would admit non-members; unchanged); `fc` (the incremental `/sync` no longer drops a room silently on a read failure: `503`,
  D14 (a); pre-existing, unchanged: the incremental `prev_batch` is the oldest delivered event id, not a `/messages` token:
  `Room.DB.decode_token/1` maps a non-`v1_` token to `:empty`, so `/messages?from=<that id>` returns the NEWEST page); `gb` (erasure: history visibility is not erasure; events stay stored and readable by members who could see them).

## Acceptance Criteria

Test files are named in "Acceptance Tests". "Real DB" = the real `Nebu.Repo`, `Room.Server` under `Horde`, `Room.DB`, `Search.DB`, through
`Nebu.Web.Router` where the AC says HTTP (`@moduletag :integration`, random users and rooms, sessions from the existing session helper,
every room an own room; `tick/0` between writes where the D2 order needs distinct milliseconds, `fj`). Message bodies are random
markers (`marker/1`); a "sees" assertion checks the event id AND the marker in the response body, a "does not see" assertion checks
that neither the event id nor the marker appears ANYWHERE in the raw response body. Fixture: room R created by A (`private_chat`), the
setting written by A through `PUT /state/m.room.history_visibility/` (A at 100).

1. **`joined` (HTTP real DB, D2, D6).** R with `joined`; A sends m1; A invites B; A sends m2 (B invited); B joins; A sends m3. (a) B's
   `GET /messages?dir=b&limit=100`: contains B's join and m3, NOT m1, NOT m2, NOT B's invite event (D5 (b)); contains the hv event (D5 (a):
   `shared` before it) and the createRoom chain before it (D3); no `end` token (absent or `""`). (b) B's initial `/sync`: `rooms.join[R].timeline` contains B's
   join and m3, not m1 / m2; `state` contains the current state (topic, members incl. A, B; D11 (a)). (c) A's `/messages` contains m1, m2,
   m3 (control). (d) With 30 messages m1..m30 before the invite and `limit=10` (test review STORY-2): B's first backward page STARTS with m3 and
   B's join; every page is filled with `limit` visible events (the createRoom chain and the hv events before the first restrictive
   setting are visible, D3, D5 (a)); `end` is non-empty while visible events remain and absent / `""` on the last page; the walk over all
   pages equals the single page with `limit=100`; none of m1..m30 appears; a forward page from the start (`dir=f`, no `from`) starts at
   `m.room.create` (S9).
2. **`invited` (HTTP real DB).** R with `invited`; A sends m1; A invites C; A sends m2; C joins; A sends m3. C's `/messages`: m2, m3,
   C's invite and join; NOT m1. C's initial `/sync` timeline: the same subset of the last 20.
3. **`shared` and no setting (HTTP real DB, D2 (d), D4).** (a) R with `shared` (and, separately, a room WITHOUT any hv event, inserted
   directly in an own room): the later joiner D sees m1, m2, m3 (no change). (b) `world_readable`: the same for members. (c) A room whose
   hv content is `{"history_visibility": "nonsense"}`, `{"history_visibility": 7}`, `{}` or a JSON-string content (direct inserts): read
   as `shared`. (d) A `/send` of an event with type `m.room.history_visibility` and content `{"history_visibility": "joined"}` (stored
   with `state_key` NULL) in a `shared` room changes nothing: the later joiner sees everything (C4, D2 (a)).
4. **Changes affect later events only (HTTP real DB, S2).** R `shared`; A sends m1; A sets `joined`; A sends m2; A sets `shared`; A sends m3;
   then E joins. E sees m1 and m3, NOT m2; E sees all three hv events (D5 (a)).
5. **Leavers, re-joiners, bans (HTTP real DB, D15, C6).** (a) R `joined`: F joins, A sends m1, F leaves, A sends m2, F re-joins, A sends
   m3: F's `/messages` contains m1 and m3, NOT m2; F's own join, leave and re-join events are visible (D5 (b)). (b) The same in a `shared`
   room: F sees m2 (S3 rule 3, Q14). (c) The same with a kick and with a ban + unban instead of the leave (A kicks / bans; F re-joins):
   the kick / ban event of F is visible to F, the gap is not. (d) The incremental `/sync` of F after his re-join (his since token from
   before the leave, `joined` room): `rooms.join[R].timeline` does NOT contain m2 (the `es` note on re-joiners). (e) A banned / left user
   gets `403` on `/messages`, `/event`, `/relations` (unchanged). (f) **Leave window (D11 (c)):** for F's leave in (a), the `rooms.leave`
   window of an incremental `/sync` equals the set the fragment deems visible to F for that interval (the test computes both; no window
   event is invisible), under `joined`, `invited` and `shared`.
6. **Same-millisecond and boundary rules (real DB, direct inserts in an own room with chosen timestamps, `on_exit` cleanup; D2 (c),
   D5).** (a) A message at the SAME `origin_server_ts` as G's join under `joined`: invisible to G; one ms later: visible. (b) A message at the
   same ms as G's leave (G re-joined later, `joined`): invisible. (c) A message at the same ms as an hv change `shared` -> `joined` (G
   joined later): invisible; at the same ms as `joined` -> `shared`: invisible (both sides must allow). (d) G's own invite under `invited`:
   visible; under `joined`: invisible; G's own leave under `joined`: visible. (e) An hv event `joined` -> `world_readable` written while G
   was not a member: visible to G after his join (S5); an hv event `joined` -> `invited` while G was not a member: invisible. (f) Two hv
   events in the same ms: the `event_id DESC` winner is the value after that ms (deterministic).
7. **D4 legacy / fail-open (real DB, direct inserts).** (a) A member of the process set with a `room_members` row (`left_at` NULL,
   `joined_at` = T0) and NO member event, room `joined`: he sees the events after T0 and not before. (b) A member whose latest member event is
   `leave` but whose row says joined since T1 (a failed re-join write simulated by a direct insert / delete): he sees the events after T1.
   (c) A row with `left_at` set and no join event: no synthetic join (the gates refuse him anyway; the fragment unit test shows `none`).
8. **`/event`, `/relations`, thread roots (HTTP real DB, D7, D8).** R `joined`, B joined after m1 (m1 has a thread reply t1 by A BEFORE B
   joined and a thread reply t2 by A AFTER B joined; m3 after the join has a reaction r3). (a) B's `GET /event/{m1}` -> `404 M_NOT_FOUND
   "Event not found"`, body byte-identical to `GET /event/{unknown id}` (D7); an unknown ROOM -> `404 "Room not found"` (unchanged);
   `GET /event/{m3}` -> `200`. (b) B's `GET /relations/{m1}` -> `404 M_NOT_FOUND "Event not found"` byte-identical to an unknown parent; `GET /relations/{m3}` -> `200`
   with r3. (c) B's incremental `/sync` that delivers t2: m1 (the root) is NOT prepended to the timeline, t2 is delivered (t2 itself is
   visible: sent after the join; its `m.relates_to` still names m1, which is not a leak of content). (d) A `/relations` parent visible but
   with children before and after the viewer's join (an hv change in between): only the visible children.
9. **`/search` (HTTP real DB, D9).** R `joined`: A sends a message with marker X before B joins and one with marker Y after. B searches X:
   no result; Y: one result; A searches X: one result. The `room_filter` variant the same. `next_batch` / `total_count` over the filtered
   results (with 12 matching events of which 5 visible and `limit` 3: two pages, 5 results in total, no duplicates).
10. **The fragment (real DB, `Room.DB` directly, D1, D2, D13).** (a) `Room.DB.history_visibility_sql/0` is the ONLY definition: every
    visibility-filtered statement in `Room.DB` and `Search.DB` contains the marker `/* history_visibility */` (source pin) and no second
    definition of `allow` exists (grep pin for `'invited'` outside the fragment in the two modules). (b) EXPLAIN (in a test transaction,
    with enough fixture rows that the planner prefers indexes, or `SET LOCAL enable_seqscan = off`): the segment inputs use
    `events_room_state_idx`, the `/messages` page uses `events_room_id_ts_idx` driven per segment (no full scan of the room for a backward
    page beyond the join of a `joined` room). (c) **Bounded scan:** in a `joined` room with 5 000 events before B's join (direct inserts)
    and 3 after, B's backward `/messages` pages read at most (segments + 1) x (limit + 1) rows: measured with `EXPLAIN (ANALYZE, BUFFERS)`
    rows or a `pg_stat_statements`-free proxy (the dev records the method); the page returns in one statement. (d) The per-statement
    parameters are bound (`$n`), the fragment text contains no interpolated value (source pin: the attribute is built from module
    attributes only).
11. **Source / AST pins (unit).** (a) In `event_dispatcher/server.ex` no client-serving function calls `fetch_events/4`,
    `fetch_events_since/3`, `fetch_event/2` or `fetch_events_by_relation/5` (the unfiltered reads) on `messages_db_module()` except through
    the D14 (b) test-module fallback helper; `get_messages`, `initial_join_rooms` (both paths), `fetch_delta_rooms`, `thread_root_updates`,
    `get_event`, `get_relations`, `attach_thread_aggregations` call the viewer-aware reads with the caller / syncing user. (b) Every call of
    `fetch_state_predecessors` in the dispatcher passes `viewer:`. (c) The fallback helper refuses to fall back for `Nebu.Matrix.Room.DB`
    and `Nebu.Matrix.Search.DB`. (d) `Search.DB` interpolates `Nebu.Matrix.Room.DB.history_visibility_sql()`; the membership subquery
    `left_at IS NULL` stays in both statements. (e) No `inspect(` in the new or touched error paths (`get_event`, `get_relations`,
    `search_messages`, the new reads).
12. **`prev_content` (HTTP real DB, D10; the BINDING `es` rule).** R `joined`: A sets topic T1, B joins, A sets topic T2. (a) B's initial
    `/sync`: the current topic event T2 (in `state` or timeline) carries NONE of `prev_content` / `prev_sender` / `replaces_state` (T1 is
    invisible to B); A's carries all three (control). (b) B's `/messages` and `/event/{T2}`: no predecessor keys; T1 is not in `/messages`.
    (c) A topic T3 set after T2: T3 carries the keys with T2 as predecessor for B (visible). (d) `/members` and `/initialSync` `state`: a
    member slot whose predecessor is invisible to the viewer (C's join after an invite that A sent before B joined, `joined`) carries no
    keys; with a visible predecessor it does. (e) Under `shared` everything as before (`member_prev_content_http_test.exs` l.930 stays
    green). (f) Never a predecessor other than the true one: with T0 (visible, before an hv change) and T1 (invisible) and T2, T2 has no
    keys (not T0's).
13. **Statement counts pinned (HTTP real DB, D13; amended by security cycle 1).** `member_prev_content_http_test.exs`
    `@baseline_initial_sync_statements` stays 54 (3 rooms). The CONTRACT counts on the shared fixture of the test review were `/messages` 5,
    `/event` 4, `/relations` 4, `/search` 3, `/members` 6 (+2 `SET LOCAL`), `/initialSync` 13 (+2), initial `/sync` 45 (+2), incremental
    `/sync` 48 (+2) (the `+2` are the existing member-slice / strict-predecessor timeouts). Since security cycle 1 the request reads run
    under ONE `SET LOCAL statement_timeout` each; the pins are `{statements, of them SET LOCAL}`: messages {6, 1}, event {5, 1},
    relations {5, 1}, search {4, 1}, initial_sync_room {14, 3}; members {6, 2}, initial `/sync` {45, 2}, incremental `/sync` {48, 2}
    unchanged. The same fixture in a `joined` room without thread roots / relations gives identical counts for `/messages`, `/event`,
    `/search`, `/members` (AC23 (h)).
14. **Docs (`server/test/nebu/matrix/history_visibility_docs_test.exs`, new; the words below are what the suite pins, test review
    STORY-8).** (a) `docs/matrix-api-scope.md`: each of the 8 enforcing rows (`/messages`, `/event`, the three `/relations` rows,
    `/search`, `/sync`, `/initialSync`) contains "history visibility enforced" (case-insensitive), both `invited` and `joined`, and the
    slug `history-visibility-enforcement`; the `/messages` row the `end` label of AC15; the `/event` row `404 M_NOT_FOUND` and "Event not
    found"; the three `/relations` rows "Event not found" and one of "invisible" / "not visible" / "may not see"; the `/search` row one of
    "per result" / "each result" / "every result" and "MUST"; the `/sync` row `503` and `M_UNAVAILABLE`; the `PUT /state` rows the four
    values and `gj`; the labels of AC15 verbatim (whitespace-normalised, case-sensitive). (b) `docs/architecture/07-deployment.md`: a new paragraph "**History visibility (story
    history-visibility-enforcement, follow-up `es`).**" (behaviour change, no migration; what members see now in `invited` / `joined`
    rooms, also in search, permalinks, threads; nothing changes for `shared` rooms, the preset default and every room without the
    setting; the current state stays visible; no backfill, no deletion: events stay stored; the operator query **Q-hv1** (the rooms
    whose CURRENT setting is `invited` or `joined`: the affected rooms) and **Q-hv2** (D13: the 20 rooms with the most hv events and the
    20 (room, user) pairs with the most member events), both read-only, run off-peak with a read-only role, checked in a rolled-back
    transaction with fixture rows). Pinned words: "behaviour change", "no migration", "no backfill", events stay stored / not deleted,
    "permalink", "thread", "preset", "current state", "read-only", "off-peak", "rolled-back transaction", "fixture rows", "20 rooms", "20
    (room, user) pairs". Q-hv1 and Q-hv2 are the first and the second ```sql block of the paragraph (exactly two, in that order), each ONE
    read-only statement (`SELECT` / `WITH`; Q-hv2 may start with `(SELECT`), no parameters, no psql meta-commands, executable by Postgrex
    as written with the app role; Q-hv1 returns room ids as string cells; Q-hv2 returns room ids, user ids and counts, at most 20 + 20
    rows. (c) `docs/architecture/06-runtime.md`: the D8 "Visibility rule" bullet of the predecessor lookup is
    rewritten (the keys are omitted when the predecessor is not visible to the viewer; it keeps "history_visibility" and "`es`"; the words
    "known deviation under `invited` / `joined`" are gone) and a short "History visibility" passage names the fragment, the read paths and
    the fail-closed rule. (d) `CHANGELOG.md` `[Unreleased]`: `### Security` (history visibility is enforced on every event read path; pinned words
    `/messages`, `/sync`, `/search`, `/event`, `/relations`, `es`, the slug, Q-hv1, Q-hv2, "behaviour change"), `### Changed` (the slug,
    "Event not found", `404`, `503`, `M_UNAVAILABLE`, "incremental /sync", "silent" / "silently": the room is no longer dropped
    silently). (e)
    `follow-ups.md`: `es` rewritten as **CLOSED by story history-visibility-enforcement (date)** KEEPING its "Original item" text and every
    note, so the pinned words stay (`create_room_presets_docs_test.exs`: "history_visibility", "guest_access"; `member_prev_content_docs_test.exs`:
    "D8", "omit", "binding", "history_visibility"; `sync_membership_partition_docs_test.exs`: "re-joined"); notes
    "**Note (history-visibility-enforcement, <date>):**" on `fg`, `fk`, `fl`, `gf`, `fc`, `gb` (the pinned words of those rows kept); new
    rows `gj`, `gk`, `gl` (pinned: the `es` row keeps 4 cells and its status contains "closed"; `gj` names `PUT
    /state/m.room.history_visibility`, `guest_access`, `400 M_BAD_JSON`; `gk` names Q-hv2, `origin_server_ts`, "statement timeout", AC22
    (12); `gl` has (a)-(e), `fg`, `unsigned.membership`, `count_thread_children`; the notes carry: `fg` -> `gl`, `fk` ->
    `Room.DB.history_visibility_sql/0` and `events_before`, `fl` -> "segment", `gf` -> `world_readable`, `fc` -> `503`, `gb` -> "not
    erasure"); the id line "`gj`-`gl`: history-visibility-enforcement" and "unused: ... `gm` onward". (f) The suite pins
    (a)-(e), the Q-hv1 / Q-hv2 SQL against fixture rows, and the absence of the removed phrases ("known deviation under `invited` /
    `joined`" in 06-runtime and in the `/messages` row; "`history_visibility` / `guest_access` are stored, not enforced" outside the
    "Original item" of `es`).
15. **Labels in the scope doc (part of AC14 (a), pinned verbatim by the docs suite).** "the state at an event is the state before it in the
    `(origin_server_ts, event_id)` order; an event in the same millisecond as a history-visibility change or a member event of the viewer
    is visible only if both the state before and after that millisecond allow it: Nebu rule (no DAG)"; "the events before a room's first
    history-visibility event are `shared` (spec default)"; "a joined member without a join event is treated as joined since
    `room_members.joined_at`: legacy / fail-open writes"; "`/messages` skips the events the viewer may not see; when no visible event remains there is no `end` token (the key is absent or empty): Nebu answers `""`, spec: omitted"; "the current state is visible to every joined member; `history_visibility` gates events, not the current
    state"; "a redacted event visible to the viewer carries its `redacted_because` even when the redaction event itself is outside the
    viewer's visible history: Nebu choice"; "`world_readable` rooms are not readable by non-members: no peeking (`gf`)"; "`guest_access` has
    no effect: Nebu has no guest accounts"; "a stored unknown `history_visibility` value (written before `gj` closed, or via the upgrade copy) is read as `shared` (spec
    default)" (re-pinned in security cycle 2, MINOR-2); "search covers currently joined rooms only (spec: also left rooms; `gl`)"; "`M_UNAVAILABLE`: Nebu errcode, as
    elsewhere (`protected.ex`)"; "visibility follows the `origin_server_ts` order: hv and member events are stamped after the latest
    event of their slot; a message stamped before an hv change (clock skew between nodes) is judged under the earlier setting: known
    Nebu invariant (`gk`)"; "the `/sync` timeline is not `limited` when fewer visible events than the limit exist"; "`replaces_state` is omitted together with `prev_content` / `prev_sender` when the predecessor is not visible: Nebu choice (no id of an invisible event is served)".
16. **Fail closed (real DB with db hooks, D14).** A failing filtered read (a hook that makes the statement fail, or a fake real-module
    stand-in) on `/messages`, `/event`, `/relations`, `/initialSync`, the initial `/sync` -> `500` with the generic body; on the incremental
    `/sync` -> `503 M_UNAVAILABLE` and the stored since token is unchanged (the next sync with the same token delivers the room's events
    once the read works); `/search` -> `500 M_UNKNOWN "Internal server error"` (the generic body; "search failed" is internal); each with exactly one value-free ERROR line (room id / "search" + error
    class); never a `200` with an unfiltered or a silently shortened page. (b) Unit: a TEST db module without the viewer-aware reads
    -> the unfiltered fallback (the old fakes stay green); the real `Room.DB` / `Search.DB` -> never the fallback.
17. **Concurrency (real DB, at least 30 rounds, `Task.async` with a barrier).** A's hv change `shared` -> `joined` races 10 concurrent
    `/messages` calls of a later joiner H and A's messages written before and after the change: every answer is `200`, no `500`, and
    (test review STORY-6, model-based) SAFETY: no answer contains a message that the rule, applied to the STORED rows (timestamps of the
    hv events, H's member events and the messages as committed), hides from H; LIVENESS: every message whose send reply preceded the
    request and that the rule shows to H is in the answer. Plus a sequential control (no race) with the expected visible set. A failure
    prints the round's sequence (ids and timestamps, no content); a round set in which no message fell before or after the change prints a
    WARNING line (no assert).
18. **Crash / restart (`.claude/rules/matrix-conventions.md`).** After the AC1 setup the room process is killed and restarted: B's
    `/messages`, initial `/sync` timeline, `/event/{m1}` and `/search` answers are identical (the rule is read from the database).
19. **Logs (real DB).** Across the suite (captured logs at all levels the suite enables, INFO and above at least): no message marker, no
    event id list, no segment and no hv value per viewer appears in a log line written by the new code; the ERROR lines of AC16 carry the
    room id / "search" and the error class only.
20. **Regression.** `mix compile --warnings-as-errors`; `mix test` and `mix test --include integration` green apart from the known flaky
    families (`fj`, `fm`, those listed in the state-writer-redaction / membership-state-model Debug Logs) and the re-pins of AC21.
21. **Deliberate re-pins (Change Log old -> new per test; the re-pin diff is reviewed before the verify step; never weaken an assertion;
    any OTHER needed change is a finding: stop and report).** **(a) The id-line assertion "`gj` onward" -> "`gm` onward" in the ELEVEN
    docs suites** `create_room_invites_docs_test.exs`, `create_room_presets_docs_test.exs`, `event_size_limit_docs_test.exs`,
    `member_prev_content_docs_test.exs`, `membership_write_limits_cycle1_docs_test.exs`, `membership_write_limits_docs_test.exs`,
    `moderation_routes_docs_test.exs`, `sync_membership_partition_docs_test.exs`, `power_levels_docs_test.exs`,
    `state_writer_redaction_docs_test.exs`, `membership_state_model_docs_test.exs` (each with a comment naming this story: "`gj`-`gl` are
    used by that story, the unused ids continue at `gm`"; EVERY new follow-up id forces this re-pin of all of them; the old "`gj` onward" is
    refuted by the new docs suite; a suite that pins the id line and is not in this list is a finding the dev records and re-pins the same
    way). (b) `member_prev_content_http_test.exs` l.947-967 FLIPS: renamed "history_visibility JOINED (es enforced): C gets no prev_content
    and /messages does not return the old topic"; the old-topic event is NOT in C's `/messages`, the current topic carries none of the three
    keys (was: the keys and the old topic; the deviation comment is replaced by the D10 reference). (c) `member_prev_content_docs_test.exs`
    l.178-196 (06-runtime "Key design facts"): stays green with the rewritten bullet (it keeps "history_visibility" and "`es`"); if an
    assertion names the deviation wording, re-pinned to the D10 wording. (d) Candidates the dev checks and records (old -> new or "green"):
    suites that create rooms with `initial_state` / `PUT /state` `history_visibility` `joined` / `invited` and then read history as a later
    joiner (`grep` of C10: `power_levels_http_test.exs`, `membership_state_http_test.exs`, `sync_membership_partition_http_test.exs`,
    `create_room_*_http_test.exs`, `matrix_client_compat_test.exs`, `room_summary_integration_test.exs`); unit suites whose fakes are
    reached through the new seam (expected green through the D14 (b) fallback); `handler_test.exs` / `get_event` / `get_relations` unit
    suites that assert the `inspect` message text (re-pinned to the fixed texts). Unchanged and green: `moderation_*`, `redaction_*`,
    `state_writer_*`, `membership_state_*` apart from the AC12 (d) slots they assert (recorded).

22. **Oracle missing tests (HTTP real DB unless noted; each a separate test; "hidden" = neither id nor marker in the raw body).**
    (1) (D5 (e)) `joined`: F is banned, unbanned and re-invited while out, then re-joins: his unban event and his re-invite are absent
        from his `/messages` and `/event` of each is `404 "Event not found"`; the same under `invited`: the re-invite IS visible and F sees
        the gap events from the re-invite onward (not before it).
    (2) (D6) Incremental `/sync` after F's re-join (`joined`) with 25 invisible gap events followed by 3 visible ones: the timeline holds
        the 3 (no starvation); `limited` false, no `prev_batch`; with 25 visible after the join: `limited` true with a non-empty `prev_batch` that is the oldest
        delivered event id (the existing convention, note on `fc`).
    (3) (D6) Initial `/sync` of a later joiner with fewer than 20 visible events (and more than 20 invisible ones): `limited` false; in a
        room where it is `limited` true, `/messages?dir=b&from=<prev_batch>` past the visible events returns an empty `chunk` without
        `end`.
    (4) (D8; reworded by test review STORY-3: `/relations` has no pagination, `from` ignored, `next_batch` always `""`) `/relations` with
        6 children of which 3 visible: the page is filled from visible children, `limit` counts visible children (`limit=2` -> 2 visible
        children), `dir=f` starts at the first visible child; `next_batch` pinned as-is (`""` / absent; flips when pagination ships, note
        on `fk`).
    (5) (D6) A `from` token taken from A's pagination inside B's invisible region, and B's own token from before his leave (`joined`):
        `dir=b` and `dir=f` never return an invisible event; `dir=f` from the invisible region reaches the first visible event.
    (6) (D9) `/search`: a room B has LEFT returns no result (pins the label "search covers currently joined rooms only"); ONE query
        over two rooms (one `joined`, one `shared`) returns exactly the visible results of both; `order_by` `rank` and `recent` give the
        same filtered set (`order_by` is not read); `count` equals the filtered total.
    (7) (D6) `/initialSync` `messages.chunk` of a later joiner in a `joined` room contains no pre-join message (`state` still the current
        state, D11 (a)).
    (8) (D11 (d)) A visible original redacted by a redaction that lies in F's gap: F gets the pruned original WITH `unsigned.redacted_because`
        (pins the label) and the redaction event itself is absent from F's `/messages`; a redaction sent after B's join that targets an
        event invisible to B is visible to B, and no content of the target appears in B's responses.
    (9) (D5) `GET /event` on a pre-join hv event (visible by D5 (a)) -> `200`; on the viewer's own invite under `joined` -> `404 "Event
        not found"`, byte-identical to an unknown event.
    (10) (S2) `world_readable` -> `joined`: a later joiner sees the events of the `world_readable` period and not those of the `joined`
         period before his join.
    (11) (D3, D15) Upgrade of a `joined` room: in the replacement room (copied `joined`) a later joiner sees only the create chain before
         the copied hv event and the events after his join; the old room stays unserved (`404`, `gi` (e)).
    (12) (D2 (f), real DB, direct insert) A message inserted with `origin_server_ts` one ms BEFORE the latest hv change `shared` ->
         `joined` (simulated skew): a later joiner SEES it (the documented outcome of the known invariant; the test comment names `gk`);
         an hv change written through `PUT /state` after a message with a future timestamp is stamped after the latest hv event of its
         slot only (pinned as a fact; no clamp asserted for messages).
    (13) (D6, `fg` (a)) An initial `/sync` with `filter={"room":{"timeline":{"limit":5}}}`: the filter is ignored (Nebu), the timeline
         holds up to 20 VISIBLE events (the limit counts visible events only).
    (14) (D6) AC1 (a) and AC5 (a) additionally: a backward page with `limit` below the number of visible events carries `end`, and the next
         page from it returns the remaining visible events and then no `end` (positive control of the omission rule).

23. **Test review additions (each a separate test; HTTP real DB unless noted).**
    (a) (MINOR-5/17, D12, STORY-10) In a `world_readable` room and in an `invited` room: a never-joined user, a leaver, a banned user and
        a pending invitee each get `403` on `/messages`, `/event`, `/relations`, `/initialSync`, and `/search` finds nothing for them
        (the marker is found for a member).
    (b) (MINOR-6, D10) `joined`: A sets T1, F joins, A sets T2 (predecessor T1 invisible to F), then T3 (predecessor T2 visible), F
        leaves: in F's incremental `/sync` `rooms.leave` window T2 carries none of the three keys, T3 carries them with T2.
    (c) (MINOR-7, D6) The `limited` boundary pair (as-is, no look-ahead): exactly 19 visible events in the initial `/sync` window ->
        `limited` false; 20 -> true; 21 -> true.
    (d) (MINOR-3, real DB) The double-encoded JSONB STRING form of the VIEWER's member events: a string-form `join` makes him a member from
        that ts, a string-form `leave` ends it, a string that is no JSON reads as `leave`.
    (e) (MINOR-4, real DB) Same-millisecond tie of the viewer's member events with event ids ordered OPPOSITE to the rank: `join` +
        `leave` and `join` + `ban` in one ms: the most restrictive wins regardless of the ids.
    (f) (MINOR-13) B's responses (the `/messages` page of a visible parent with hidden children; the incremental `/sync` with the thread
        reply of AC8 (c)) contain no `m.relations` (thread aggregations are not rendered; `gl` (d)).
    (g) (MINOR-16, STORY-5, real DB + unit) `fetch_state_predecessors(slots, viewer: nil)` and `viewer: ""` -> `%{}` (and `{:ok, %{}}`
        with `strict: true`): no keys; source pin: no dispatcher caller passes a nil viewer.
    (h) (MINOR-14, D13) The AC13 fixture shape in a `joined` room without thread roots / relations: `/messages`, `/event`, `/search`,
        `/members` run the same statement counts as in the `shared` room.

24. **Security cycle 1 / 2 (real DB; `history_visibility_security_cycle1_test.exs`, `history_visibility_cycle1_docs_test.exs`).** (a) Cap:
    a room holds at most 256 `m.room.history_visibility` state events (seam `:nebu, :hv_event_cap`); a write at the cap is
    `429 M_LIMIT_EXCEEDED` "This room has too many history visibility changes", nothing written, unless it is strictly more restrictive
    than the current setting (cycle 2: the cap never blocks tightening; at most 3 rows above the cap); other state types and a non-empty
    state key are not capped. (b) A PUT of `m.room.history_visibility`, `m.room.guest_access`, `m.room.join_rules` costs one `moderation`
    token. (c) 3 000 hv events in one room: page, since, single event and search far below the timeout (measured, printed). (d) The request
    reads (`/messages`, `/event`, `/relations`, `/search`) blocked longer than 2 s answer the generic `500` with one value-free ERROR line;
    `/initialSync` a handled error; the `/sync` waits and answers `200`. (e) The since read of a room without new events reads no
    visibility input (EXPLAIN ANALYZE). (f) A NUL in an event id, relation type, event type or `from` token is the unknown-event `404`,
    no ERROR line. (g) `POST /read_markers` refuses a hidden `m.fully_read` event like an unknown one. (h) `gj`: `400 M_BAD_JSON` for a
    `history_visibility` / `guest_access` value outside the enum (PUT state with the empty state key, createRoom `initial_state`); a
    non-empty state key is not validated; the upgrade copy stays tolerant. (i) A thread aggregation counts the children first and reads
    the visible latest child only when the count is > 0 (the AC13 `/sync` counts do not move). (j) The docs rows of the cycle.

## Acceptance Tests

- `server/test/nebu/matrix/history_visibility_http_test.exs` (new, `:integration`, through `Nebu.Web.Router`): AC1-AC5, AC8, AC9, AC12,
  AC13, AC18, AC19.
- `server/test/nebu/matrix/room/history_visibility_db_test.exs` (new, `:integration`, `Room.DB` / `Search.DB` directly, direct inserts in
  own rooms): AC6, AC7, AC10, AC5 (f) (the fragment side).
- `server/test/nebu/matrix/history_visibility_concurrency_test.exs` (new, `:integration`, `async: false`, tagged `:concurrency`): AC17.
- `server/test/nebu/matrix/history_visibility_unit_test.exs` (new, unit: fakes, source / AST pins): AC11, AC16 (b).
- AC16 (a) in `history_visibility_http_test.exs` (db hooks).
- Test review (AC23): (a)-(c), (f), (h) in `history_visibility_http_test.exs`; (d), (e), (g) (DB part) in
  `room/history_visibility_db_test.exs`; (g) (pin) in `history_visibility_unit_test.exs`.
- Oracle gate (AC22): (1)-(11), (13), (14) in `history_visibility_http_test.exs` ((11) may live in a new
  `history_visibility_upgrade_http_test.exs`, the ATDD agent's choice, named in the Change Log); (12) in
  `room/history_visibility_db_test.exs`; (6) may share the search fixtures with AC9.
- `server/test/nebu/matrix/history_visibility_docs_test.exs` (new): AC14, AC15, and the refutation of "`gj` onward".
- `server/test/nebu/matrix/history_visibility_security_cycle1_test.exs` (security cycles 1 / 2, `:integration`): AC24 (a)-(h).
- `server/test/nebu/matrix/history_visibility_cycle1_docs_test.exs` (security cycles 1 / 2): AC24 (j).
- Re-pinned: the suites of AC21.

## E2E verification

`ui: false` (no Nebu UI code; Element is the client). One new feature `e2e/features/element/room/history-visibility.feature` with steps
`e2e/step-definitions/element/history-visibility.steps.ts` (users alex, marie, tom, kai of the global setup; message bodies are random
markers of the feature; the steps never print a token or message content), run on a FRESH, isolated stack built from THIS commit:

- **`@history-visibility-api @regression`** (the guard, no UI selectors): alex creates three `private` rooms through the API and sets
  `m.room.history_visibility` to `joined` ("hv-joined"), `invited` ("hv-invited") and `shared` ("hv-shared"); in each alex sends
  "before-invite-<marker>", invites the later user (marie into hv-joined, tom into hv-invited, kai into hv-shared), sends
  "while-invited-<marker>", the user joins, alex sends "after-join-<marker>". Then: marie's `/messages?dir=b&limit=50` on hv-joined
  contains only after-join (and her join), tom's on hv-invited while-invited and after-join, kai's on hv-shared all three; marie's `GET
  /event/{before-invite}` -> `404`; marie's `POST /search` for the before-invite marker -> no result, alex's -> one result; marie's
  INITIAL `/sync` timeline of hv-joined contains no before-invite / while-invited event id.
- **`@history-visibility-ui @regression @ui`**: marie logs in via Element Web (fresh login), opens "hv-joined": the timeline shows the
  after-join text and NOT the before-invite / while-invited texts after scrolling to the top (the step scrolls up until Element stops
  paginating, bounded to 10 s); kai opens "hv-shared": the before-invite text is shown (positive control: Element paginates there).
  Asserted SERVER-side additionally: the server log shows marie's `GET .../messages?...dir=b` `200`. UNVERIFIED: Element 1.12.15's
  rendering at the start of a `joined` history (a "You can't see earlier messages" style notice is not asserted) and the timeline
  scroll selectors. If the first real run fails for a UI reason (the API scenario green, the server log shows the `/messages` `200`), tag
  the UI scenario `@known-failure` with a new row in `e2e/KNOWN-FAILURES.md` (next free K id: **K14** — K13 is the membership-state UI row,
  K12 is named by the redaction feature, K11 is reserved by the moderation plan, K8 and K10 are retired paragraphs; the headers of
  `history-visibility.feature` / `history-visibility.steps.ts` name K14; cause: Element timeline pagination / selectors unverified) and
  keep the API scenario as the guard; a server answer other than `200` on `/messages` for a member, or an invisible marker in any
  response, is a finding.

Run (the orchestrator; evidence, not a UI gate): 0. `docker ps` shows no other stack publishing 8008, 7070, 5556, 5432, 9000;
`COMPOSE_PROJECT_NAME=nebu-oauth-e2e`. 1. **Run A (CI parity):** `COMPOSE_PROJECT_NAME=nebu-oauth-e2e NEBU_E2E_KEEP=1 scripts/e2e-ci.sh
element`. Pass: every scenario of the default tag expression green (the two new ones, or the UI one moved to the known-failure list)
except the rows of `e2e/KNOWN-FAILURES.md`; then save the server log, count `RequestLogger` lines with status `500` (pass: zero) and with
path `/messages` (record the statuses); `docker compose -p nebu-oauth-e2e down -v --remove-orphans`. 2. Logs:
`_bmad-output/nebu/epics/oauth-broker/step-results/history-visibility-enforcement/e2e-run-a.log` and `e2e-run-a-server.log`; update the
"Status of the last complete run" line of `e2e/KNOWN-FAILURES.md`.

## Tasks

- [x] `Room.DB`: the fragment `@sql_history_visibility` + `history_visibility_sql/0` (D1, D2, D4, D5); `fetch_visible_events/5` with the
      segment-driven scan (D6), `fetch_visible_events_since/4`, `fetch_visible_event/3` (D7), `fetch_visible_events_by_relation/6` (D8);
      the `viewer:` option of `fetch_state_predecessors` (D10); `@optional_callbacks` in `DBBehaviour` (D14 (b)).
- [x] `Search.DB`: the fragment in both statements (D9).
- [x] `EventDispatcher.Server`: the viewer through `get_messages`, `initial_join_rooms` (both paths), `fetch_delta_rooms`,
      `thread_root_updates`, `get_event`, `get_relations`, `attach_thread_aggregations`, `event_maps_to_core_events/2`, the three
      predecessor callers (D6-D10); the test-module fallback helper and the fail-closed mapping incl. the incremental-`/sync` `503` (D14);
      the fixed texts instead of `inspect` (C8, D9).
- [x] Tests (Acceptance Tests) incl. the re-pins of AC21 (Change Log, old -> new).
- [x] Docs AC14 / AC15 (scope doc, 06-runtime, 07-deployment incl. Q-hv1 / Q-hv2 checked in a rolled-back transaction, CHANGELOG,
      follow-ups incl. the id line and the notes).
- [x] Oracle gate: the 14 tests of AC22; the labels added to AC15 (search scope, `M_UNAVAILABLE`, the timestamp invariant, `limited`);
      the `404 M_NOT_FOUND "Event not found"` body for `/event` / `/relations` (D7, D8); the segment-driven incremental read (D6); the
      notes on `fk`, `gk`, `gl` (e).
- [x] Test review: the decisions STORY-1 (`end` absent or `""`, option A), STORY-4 (`limited` as-is), STORY-5 (viewer nil / `""`
      fail closed); AC23 (a)-(h); the AC13 contract counts; the AC14 docs words; DEV-1..DEV-9 (Dev Notes).
- [x] E2E feature + steps (staged by ATDD); [ ] run A (orchestrator).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/`, `server/priv/migrations/` only inside the `nebu-pipeline` run. ADR-018 (the
  fragment and the reads are SQL inline in `Room.DB` / `Search.DB`; the decisions about WHO may read stay in the dispatcher; no repository
  / service layer, no `Visibility` query module: `skills/nebu-conventions/sql-placement` forbids SQL in a separate module), ADR-019 /
  ADR-021 (plain in-process modules), ADR-020 (no cross-domain call), cluster-safety (no node-local cache of visibility; one process per
  room via `Horde.Registry`; nothing new in `:pg`).
- **One rule, one place.** Every visibility decision comes from `@sql_history_visibility`; no Elixir re-implementation of `allow` (a
  post-filter in the BEAM is forbidden: it breaks the page / `limit` / `end` semantics and is the second definition that drifts). The
  member normalisation and the D3 tie order come from the existing module attributes.
- **Scan shape.** Page reads (D6, the incremental `/sync`) are DRIVEN by the visible segments; single-event, relation, predecessor and
  search checks use the EXISTS form. Never `ORDER BY ... LIMIT` over the room with the predicate as a filter for a backward page.
- **Fail closed.** A failing filtered read for the real modules: `500` / `503` (D14), never an unfiltered page, never a silent drop. Only
  test modules fall back.
- **Security-relevant parts (review focus).** (1) Authorisation: the gates of C2 are unchanged (joined members only; leavers `403`);
  the fragment only NARROWS what a joined member gets. (2) The SQL predicate: the D2 (c) both-sides rule, the `state_key = ''` rule for
  hv events (a `/send` of the hv type must never change visibility, AC3 (d)), the unknown -> `shared` rule, the synthetic join only for a
  row with `left_at IS NULL` (D4). (3) Time-of-join correctness: the viewer's member events in the D3 order; same-millisecond ties
  most restrictive. (4) Leavers / bans: the leave / ban segments deny; the gap of a re-joiner is hidden outside `shared`. (5) The room
  upgrade: the new room starts fresh (D3). (6) Redactions: prune unchanged; D11 (d) labelled. (7) Existence oracles: `/event` and
  `/relations` 404 bodies identical for unknown and invisible (AC8). (8) `prev_content`: the true predecessor or nothing (AC12 (f)).
- **Writers stay single, nothing is written.** This story writes no event and changes no writer; it does not touch `Room.Server`.
- **Logs.** Never log an event, an id list, a segment, an hv value per viewer or a search term; value-free ERROR lines only (D16).
- **Binding names and seams (the suites' moduledocs are binding).** `Room.DB.history_visibility_sql/0`, the marker
  `/* history_visibility */`, `fetch_visible_events/5`, `fetch_visible_events_since/4`, `fetch_visible_event/3`,
  `fetch_visible_events_by_relation/6`, `fetch_state_predecessors(slots, viewer: ...)`, reached through `messages_db_module()` /
  `search_db_module()`; `event_maps_to_core_events/2` (events, viewer). Do NOT rename the AST-pinned functions of earlier stories:
  `initial_join_rooms` (two call sites), `full_state_room`, `get_room_state`, `get_room_members/2`, `fetch_delta_rooms`,
  `build_leave_room`, `attach_leave_predecessors`, `thread_root_updates`, the summary callers, `insert_invitation_row`, `wake_invitee`.
- **Test review binding notes (DEV-1..DEV-9).** (1) The seam fallback only under the D14 (b) guard: `Code.ensure_loaded?(mod) and
  function_exported?(mod, fun, arity)` -> the viewer-aware call; else `mod != Nebu.Matrix.Room.DB` -> the unfiltered fallback; else the
  fail-closed `500` / `503`; never `function_exported?` without `Code.ensure_loaded?`. (2) Signatures: `fetch_visible_events(room,
  viewer, dir, limit, from)` -> `{:ok, events, next, prev}`; `fetch_visible_events_since(room, viewer, last_event_id, limit)` -> `{:ok,
  events}`; `fetch_visible_event(event_id, room, viewer)`; `fetch_visible_events_by_relation(room, viewer, event_id, rel_type, limit,
  opts)`; `fetch_state_predecessors(slots, viewer: v[, strict: true])`; event maps with exactly the keys `content`, `event_id`,
  `event_type`, `origin_server_ts`, `room_id`, `sender`, `state_key`; for old `/relations` doubles the fallback goes through
  `event_in_room?/2` and an unknown parent is `404 M_NOT_FOUND "Event not found"` too. (3) A nil / `""` viewer never selects the
  unfiltered predecessor statement. (4) Error logs reuse `db_error_class/1` (one ERROR line: class, room id or `search`, no marker / id
  / topic); the incremental-`/sync` failure raises through `Nebu.Matrix.Status.unavailable()` (`503 M_UNAVAILABLE "Core is temporarily
  unavailable"`), persists no since token; a thread-root read failure is a `503` too. (5) `limited` as-is (no look-ahead). (6) The
  fragment lives inside the existing statements (a page = ONE statement carrying `/* history_visibility */`; since / single / relations
  / predecessors / search each marked and parameter-bound; no room id or viewer in the SQL text); no `SET LOCAL` for the visibility itself (security cycle 1 adds ONE `SET LOCAL statement_timeout` per request read, AC13); `Search.DB`
  interpolates `Room.DB.history_visibility_sql()`, keeps `left_at IS NULL` in both statements, `sql_search_messages/0` stays public; the
  only `= 'invited'` occurrence is in `Room.DB` (none in `Search.DB`, none in the dispatcher). (7) Scan shape: the EXPLAIN pin (AC10)
  expects `events_room_id_ts_idx` + `events_room_state_idx`, no Seq Scan, at most (5 + 1) x (limit + 1) + 20 rows with 5 000 hidden
  events; `since` reads the OLDEST visible events. (8) `/messages` tokens from invisible regions never yield a hidden event (`dir=b` and
  `dir=f`); an empty page has no `end` token (absent or `""`) and `start` = the input token. (9) Docs: the AC15 labels verbatim, `es`
  CLOSED keeping "Original item" and all notes, the id line, Q-hv1 / Q-hv2 as the two sql blocks (AC14).
- **Previous story learnings** (membership-state-model, state-writer-redaction, member-event-prev-content): real-DB tests for the read
  rule and the fail-closed paths; deterministic boundary tests through direct inserts with chosen timestamps in own rooms; `tick/0` only
  in own rooms (`fj`); docs suites pin earlier texts: rewrite `es` in the CLOSED style keeping the "Original item" and every note; the
  id-line re-pin in all ELEVEN docs suites (AC21 (a)); real fakes, never stubs; the statement baselines are a contract (AC13); the e2e
  on a fresh isolated stack.

### References

- Spec: `skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html` "Room History Visibility" (l.45389ff, incl. "Server
  behaviour" and "Security considerations"); `client-server-api/api.json` (`/rooms/{roomId}/messages` `from` / `end` / `403`,
  `/rooms/{roomId}/event/{eventId}` `404`, `/v1/rooms/{roomId}/relations/{eventId}` `404`, `/rooms/{roomId}/context/{eventId}`,
  `/v1/rooms/{roomId}/threads`, `/search`, `/join` "all current state events", every `unsigned.prev_content` description).
- Code: `server/lib/nebu/matrix/event_dispatcher/server.ex` l.1462-1474, l.3326-3361, l.3437-3546, l.4232-4281, l.4783-4821,
  l.5125-5205, l.5623-5688, l.5895-6050, l.6460-6470, l.8452-8545, l.8931-8961, l.8980-9161; `server/lib/nebu/matrix/room/db.ex` l.54-57,
  l.643-861, l.1117-1213, l.1606-1641, l.1990-2105, l.2206-2230, l.2279-2320; `server/lib/nebu/matrix/search/db.ex` l.16-160;
  `server/lib/nebu/matrix/room/db_behaviour.ex` l.130-160, l.320, l.358; `server/lib/nebu/matrix/room/power_level.ex` l.44;
  `server/lib/nebu/matrix/room_summary.ex` l.32-33; `server/lib/nebu/matrix/http.ex` l.63-116; `server/lib/nebu/web/router/protected.ex`
  l.509-512, l.1660-1750, l.1888-1930, l.2263-2274, l.2444-2470; `server/lib/nebu/matrix/room/server.ex` l.1302;
  `server/priv/migrations/000001_init.up.sql` l.199-236.
- Stories: `member-event-prev-content.md` (D8), `sync-membership-partition.md` (D3, D6, the leave window), `state-writer-redaction.md` (D6,
  M1), `membership-state-model.md` (D1, D5, D8 (a), D15, D18), `create-room-presets-power-levels-topic.md` (presets).
- Follow-ups: `es`, `fg`, `fk`, `fl`, `ef`, `fc`, `fd`, `fe`, `gf`, `gg`, `gi`, `gb` in `docs/stories/oauth-broker/follow-ups.md`.
- Conventions: `CLAUDE.md`, `.claude/rules/matrix-conventions.md` (crash / restart test), `skills/nebu-conventions/cluster-safety/`,
  `skills/nebu-conventions/no-domain-model/`, `skills/nebu-conventions/sql-placement/`, `skills/nebu-conventions/security-rules/`.

## Dev Agent Record

### Agent Model Used

Claude Opus 5.5 (dev-story, pipeline step 4: cycle 0 and the security fix cycles 1 and 2).

### Debug Log

- Security cycle 1: the window-function rewrite of `hv_points` alone still took 3.4 s for 3 000 hv events: `hv_special` joined
  `hv_state` x `hv_points` with a nested loop (the planner estimates every CTE at a few rows). Rewritten without any join between
  large CTEs (a carry over the merged stream of boundaries and special events; `hv_allow` read by scalar subqueries; the predicate
  probes sorted arrays with `width_bucket`): 46 ms. An intermediate version that read the boundary state from per-room arrays
  per special event took 340 ms (array subscripts detoast the array per row: quadratic) and was dropped.

- First run: `room_id = ANY((SELECT rooms FROM hv_in))` is the ANY(subquery) form (`text = text[]`, SQLSTATE 42883): fixed with
  `ANY((SELECT rooms FROM hv_in)::text[])`.
- Full integration run (fresh DB): the source pin `state_predecessors_db_test.exs:498` failed after a refactor that moved the
  warning of `fetch_state_predecessors/1` into a helper; `/1` keeps its own body again (the viewer-aware lenient lookup has its
  own helper with the same value-free warning).
- Full run classification: `ModerationAtomicDbTest` (2, `tick/0` timeouts) and the `MemberSliceGateTest` FIFO timing test (unit
  run) are green in isolation; `AdminOidcLogin` (3), `LogStore.Retention` (2), `TraceMapNodeControls` (3), `RoomsFallbackName`
  (12), `TemporaryCaptureManager` (3) fail with the same counts on a `git archive` copy of HEAD against the same DB
  (pre-existing, DB state); `WarRoom` (1) green in isolation.

### Completion Notes List

- `Room.DB`: ONE fragment `@sql_history_visibility` (`history_visibility_sql/0`, `@doc false`) built from module attributes
  only (`@sql_hv_value_raw` + the existing member fragments); CTEs `hv_allow` (the only `= 'invited'` of the codebase),
  `hv_state`, `hv_mem_events`, `hv_mem` (D4 synthetic join at `room_members.joined_at` when `left_at IS NULL` and the latest
  member event is not `join`), `hv_points` (the state at each boundary; `lag` gives the "before" side), `hv_segments`,
  `hv_special` (D5); the consumer predicate `@sql_hv_visible` (also `history_visibility_predicate/0` for `Search.DB`). Every
  statement starts `WITH hv_in AS (...)` from bound parameters (marker `/* history_visibility */`, no value in the text).
  Reads: `fetch_visible_events/5` (segment-driven LATERAL per visible segment + the visible specials, `limit + 1` over visible
  events; shares `page_answer/3` with `fetch_events/4`), `fetch_visible_events_since/4` (oldest visible, same anchor rule),
  `fetch_visible_event/3`, `fetch_visible_events_by_relation/6`; `fetch_state_predecessors(slots, viewer:)`
  (`@sql_state_predecessors_visible`: the unchanged predecessor rows `@sql_state_predecessor_rows` + the predicate on the TRUE
  predecessor; nil / `""` viewer = no keys and no statement; no `viewer:` option = the old statement). A hv row with
  `state_key` NULL never counts, and the "special event" test is NULL-safe (a `/send` of the hv type stays an ordinary event).
- `Search.DB`: both statements interpolate the fragment (rooms = the `left_at IS NULL` gate rooms of `$1`; with a room filter
  only the filtered gate rooms) and the predicate; `left_at IS NULL` stays in both.
- Dispatcher: `viewer_read/3` (the D14 (b) seam: `Code.ensure_loaded?` + `function_exported?` -> viewer-aware; else
  `mod != Nebu.Matrix.Room.DB` -> the unfiltered fallback; else `{:error, :viewer_read_unavailable}` -> fail closed);
  `visible_page!/5`, `visible_since!/4`, `visible_event/3`, `visible_parent/3` (old doubles via `event_in_room?/2`),
  `visible_relations/6`; `history_read_failed!/3` (ONE ERROR line: room id + `db_error_class/1`; `500`, or the incremental
  `/sync` `503` via `Status.unavailable()`); `event_not_found!/0` (`404 M_NOT_FOUND "Event not found"` for unknown AND
  invisible events / parents). Wired: `get_messages`, `initial_join_rooms` (both paths), `fetch_delta_rooms` (the silent
  `{:error, _} -> []` drop is gone), `thread_root_updates` (an invisible root is not prepended; a failure is a `503`),
  `get_event`, `get_relations` (viewer = the TRUSTED stream identity, also for its member check), `attach_thread_aggregations`,
  `event_maps_to_core_events/2`, `attach_leave_predecessors/2`, `attach_predecessors_to_state_events/4` (+ the strict lookup);
  every `build_state_events(..., true, ...)` caller passes `viewer:`; `search_messages` logs value-free.
- No migration: the AC10 EXPLAIN pins pass with the existing `events_room_id_ts_idx` / `events_room_state_idx`.
- Q-hv1 / Q-hv2 SQL evidence: executed by `history_visibility_docs_test.exs` against fixture rows inside a rolled-back
  `Nebu.Repo.transaction` (Q-hv1 lists joined / invited / string-form joined / same-ms tie, not shared / world_readable / none /
  changed-back / unknown / NULL state key / string-form shared; Q-hv2 returns the 400 hv events and the 450 member events with
  their counts, at most 40 rows; the fixture rows are gone afterwards): green on Elixir 1.20 and 1.19.
- Fakes / doubles: the 20 old fakes reach the unfiltered reads through the seam (unchanged); `HistoryVisibilityTestSupport.Hooks`
  (`MessagesDB`, `SearchDB`) and the unit doubles (`OldDB`, `ViewerDB`, `NoParentDB`, `UnfilteredDB`) of the ATDD step.
- `server/lib`: +624 / -134 lines (comments and docs included), below the ~700 stop rule: `/search` stays in this story.
- Verification: new + changed suites and all 26 docs suites green on Elixir 1.20 and 1.19 (`--warnings-as-errors`, 595 tests);
  unit job (no DB) 6487 passed; full `--include integration` on a fresh DB: only the families above (classified); name-length
  check clean.

- **Security cycle 1 (2026-10-26):** decisions 1-7 implemented. (1) cap: `Room.Server.check_hv_cap/3` (count through the new
  `Room.DB.count_state_events/3`, refuses with `:hv_event_cap` -> `429 M_LIMIT_EXCEEDED` "This room has too many history
  visibility changes"; `Http.map_error/1` maps `resource_exhausted` + that errcode to 429); tier: `@moderation_state_types` in
  `protected.ex`; linear SQL (see Debug Log; `hv_seg_arr`, `hv_spec_arr`, `@sql_hv_join`, `history_visibility_join/0` for
  `Search.DB`); timeout: `Room.DB.with_read_timeout/1` + the dispatcher's `with_read_timeout/1` (a db module without it, e.g. a
  Repo-less double, runs the read as is). (2) thread aggregations: count first; since read: `hv_in.rooms` conditional on an
  EXISTS of a newer event; EXPLAIN ANALYZE of an empty-delta `fetch_visible_events_since` (50 hv events, viewer joined, anchor =
  the newest event): planning 1.2-3.0 ms, execution 0.65-0.85 ms, 0 rows of `events` read (pinned by a test); the anchor lookup
  error is `{:error, reason}` now (INFO-3, the 503). (3) NUL: `/event`, `/relations` (event id, rel type, event type) and a
  `/messages` `from` token naming a NUL id answer the unknown-event `404`, no ERROR line. (4) `POST /read_markers`:
  `EventDispatcher.Server.visible_event?/3`. (5) `gj`: `validate_access_content/2` (PUT state, empty state key) and
  `validate_initial_state_access_entry/1`; `gj` CLOSED. (6) clock skew stays a residual, the clamp option on `gk`. (7) docs:
  Q-hv1 wording, `gk` rewritten (exploits A / B, the bounds, the clamp), the stale comments (initial sync checkouts, "N+1 for
  MVP"), the "keep in sync" notes of the two predecessor warnings, the same-millisecond rationale sentence in the `/messages` row.
- Security cycle 1 tests: `history_visibility_security_cycle1_test.exs` (cap, tier, 3 000 hv events cost bound with printed times,
  the lock-based 57014 -> 500 with `/sync` unaffected, empty-delta EXPLAIN, NUL, read markers, `gj`), `history_visibility_cycle1_docs_test.exs`.
- Measured, 3 000 hv events in one room (EXPLAIN ANALYZE of the later joiner's backward page, limit 10): cycle 0 (staged
  version): execution 5 176 ms; security cycle 1: 46-48 ms (page 43 ms, since 43 ms, single 20 ms, search 23 ms wall clock).

- Verification, security cycle 1: new / changed suites + all docs suites + power-levels / read-markers / create-room http: 874/874 on
  Elixir 1.20 and 874/874 on 1.19 (`--warnings-as-errors`); unit job without DB (`unit_nodb.sh`) 6493 passed; fresh-DB full
  `--include integration` run: 10595/10621, the 26 failures all known families (RoomsFallbackName 12, TraceMapNodeControls 3,
  TemporaryCapture 3, LogStore.Retention 2, AdminStaleRooms 1: same counts on a `git archive` HEAD copy; WarRoom 1,
  LayoutsWarRoomIndicator 1: green in isolation; AdminOidcLogin 3: the admin user listing is truncated on the reused DB); name-length
  check clean.
- **Security cycle 2 (2026-10-26):** Kassandra N1: `check_hv_cap/4` lets a strictly more restrictive change pass the cap (a new
  `Room.DB.current_history_visibility/1`, read only at the cap; ranks world_readable 0 < shared 1 < invited 2 < joined 3, a stored
  unknown value = shared); MINOR-1 story text (AC13 pins, D13, Dev Notes, Out-of-scope, AC24, Acceptance Tests, model line, the
  AC13 describe renamed); MINOR-2 the label re-pinned; MINOR-3 `RoomAccountDataStore.event_in_room?/2` removed (no caller, no test);
  MINOR-4 the timeout test holds the lock until it is released explicitly (at most 30 s) and also covers `/relations` and
  `/initialSync`; MINOR-5 the cap test covers a non-empty state key; INFO-3 docs of `with_read_timeout/1`, `count_state_events/3`,
  `current_history_visibility/1` ("not part of DBBehaviour, guard"); INFO-7 tests (NUL in the `/relations` event type, upgrade copy
  tolerant of an unknown stored value, guest_access with a non-empty state key not validated); INFO-8 `/search` takes
  `with_read_timeout/1` from `search_db_module()` (`Search.DB.with_read_timeout/1` delegates).
- Verification, security cycle 2: new / changed suites + all docs suites + power-levels / read-markers / create-room /
  room-account-data / upgrade suites: 926/926 on Elixir 1.20 and 926/926 on 1.19 (`--warnings-as-errors`); unit job without DB 6493
  passed; fresh-DB full `--include integration` run: 10596/10626, the 30 failures: the families of cycle 1 (RoomsFallbackName 12,
  TraceMapNodeControls 3, TemporaryCapture 3, AdminOidcLogin 3, LogStore.Retention 2, AdminStaleRooms 1, WarRoom 2) plus
  MembershipPartitionDb EXPLAIN 1, Sweeper 1, RateLimitTakeAll 1 (all green in isolation) and SsoLogin 1 (fails the same on a `git
  archive` HEAD copy); name-length check clean (no test of this story above 230).

### File List

- `server/lib/nebu/matrix/room/db.ex`, `server/lib/nebu/matrix/room/db_behaviour.ex`, `server/lib/nebu/matrix/search/db.ex`,
  `server/lib/nebu/matrix/event_dispatcher/server.ex`
- `docs/matrix-api-scope.md`, `docs/architecture/06-runtime.md`, `docs/architecture/07-deployment.md`,
  `docs/stories/oauth-broker/follow-ups.md`, `CHANGELOG.md`, this story
- Tests (ATDD, unchanged by dev): the suites of "Acceptance Tests", the AC21 re-pins, the e2e feature + steps
- Security cycle 1: `server/lib/nebu/matrix/room/server.ex`, `server/lib/nebu/matrix/http.ex`, `server/lib/nebu/web/router/protected.ex`
  (plus the four files above); new tests `history_visibility_security_cycle1_test.exs`, `history_visibility_cycle1_docs_test.exs`;
  adapted `history_visibility_http_test.exs` (AC13 baseline, Change Log)

### Change Log

- 2026-10-20: story created (create-story, pipeline step 1), status `ready`.
- 2026-10-20: Oracle gate (`_bmad-output/nebu/epics/oauth-broker/step-results/history-visibility-enforcement/oracle-context.md`)
  applied: S11 corrected (`/search` visibility is a spec MUST) + label "search covers currently joined rooms only (spec: also left
  rooms; `gl`)" and `gl` (e); `fk` note (search `events_before` / `events_after` empty today, through the fragment if filled); D14
  `M_UNAVAILABLE` labelled as a Nebu errcode; D2 (f) the timestamp invariant (hv / member writes stamped after the latest slot event,
  messages not clamped) labelled + residual on `gk`, no writer clamp; D5 (e) unban / re-invite outcomes; D6 `limited` by visible
  count, empty page without `end`, segment-driven incremental read, tokens into invisible regions; D7 / D8 404 body unified to
  `404 M_NOT_FOUND "Event not found"` (no test pins the old text for events); AC15 labels; AC22 (14 tests); Tasks. Follow-up ids
  unchanged (`gj`-`gl`, unused from `gm`).
- 2026-10-21: test review (`.../history-visibility-enforcement/test-review-findings.md`) applied: STORY-1 option A (the router keeps
  `"end": ""`; the `end` label and AC1 (a) / (d) reworded: no `end` token = absent or `""`, labelled deviation); STORY-4 (b) `limited`
  relaxed (no look-ahead, exactly 20 -> `true`; label reworded) and (a) `prev_batch` = oldest delivered event id + note on `fc`;
  STORY-5 viewer nil / `""` fails closed (D10); STORY-2 AC1 (d); STORY-3 AC22 (4) (no `/relations` pagination; note on `fk`);
  STORY-6 AC17 model-based; `/search` failure body = generic `500 M_UNKNOWN`; STORY-7 contract counts in AC13; STORY-8 the docs words in
  AC14; STORY-9 the `replaces_state` label; STORY-10 `fetch_visible_events_since/4` signature and AC23 (a); AC23 (b)-(h); DEV-1..9 in
  Dev Notes; Tasks. No new follow-up id.
- 2026-10-26: dev-story (cycle 0): implementation, docs (AC14 / AC15), follow-ups `es` CLOSED, `gj`-`gl` added, notes on `fg`,
  `fk`, `fl`, `gf`, `fc`, `gb`, id line "unused ... `gm` onward". AC21 re-pins (staged by the ATDD step, reviewed, unchanged by
  dev): (a) the id-line assertion "`gj` onward" -> "`gm` onward" in the eleven docs suites (create_room_invites,
  create_room_presets, event_size_limit, member_prev_content, membership_write_limits_cycle1, membership_write_limits,
  moderation_routes, sync_membership_partition, power_levels, state_writer_redaction, membership_state_model; no other suite
  pins the id line: all 26 docs suites green); (b) `member_prev_content_http_test.exs` "history_visibility JOINED (es
  enforced)": the old topic is NOT in C's `/messages`, the current topic carries none of the three keys (was: the keys and the
  old topic); (c) `member_prev_content_docs_test.exs` 06-runtime facts: green with the rewritten bullet; (d) candidates
  (`power_levels_http`, `membership_state_http`, `sync_membership_partition_http`, `create_room_*_http`, `matrix_client_compat`,
  `room_summary_integration`, the get_event / get_relations unit suites incl. `thread_relations_test.exs`): green, no change.
- 2026-10-26: security cycle 1 (code-review-findings.md BINDING DECISIONS 1-7; Kassandra HIGH #1, MEDIUM #2, LOW #3-#5): cap,
  tier, linear fragment, request statement timeout, thread-aggregation order, conditional since inputs, NUL ids, read markers,
  `gj` validation (CLOSED), docs (`gk`, Q-hv1, D13 amended). Adaptation of a staged test (old -> new):
  `history_visibility_http_test.exs` AC13 `@baseline`: messages {5, 0} -> {6, 1}, event {4, 0} -> {5, 1}, relations {4, 0} -> {5, 1},
  search {3, 0} -> {4, 1}, initial_sync_room {13, 2} -> {14, 3} (exactly the ONE `SET LOCAL statement_timeout` of decision 1 (d) per
  request read; members, initial and incremental `/sync` unchanged). This contradicts "no `SET LOCAL` is added" of AC13: decision 1 (d)
  needs a statement to set the timeout, no other statement moved.
- 2026-10-26: security cycle 2 (`security-review-delta1-2026-10-26.md` N1, `code-review-delta1-findings.md` MINOR-1..6, INFO-1/3/7/8):
  the cap never blocks tightening; story text made consistent; deliberate re-pins (old -> new): `history_visibility_docs_test.exs`
  label "an unknown `history_visibility` value is read as `shared` (spec default; not validated on write, `gj`)" -> "a stored unknown
  `history_visibility` value (written before `gj` closed, or via the upgrade copy) is read as `shared` (spec default)";
  `history_visibility_http_test.exs` describe "AC13 - the statement counts are unchanged" -> "AC13 - pinned statement counts (security
  cycle 1: one SET LOCAL per request read)" (assertions unchanged); the cycle-1 cap test of `history_visibility_security_cycle1_test.exs`
  writes `world_readable` (weaker) instead of `invited` (tighter since N1) as the refused write.
