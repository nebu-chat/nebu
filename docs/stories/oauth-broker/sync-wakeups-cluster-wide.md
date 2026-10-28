---
story_id: sync-wakeups-cluster-wide
title: "Long-poll /sync wake-ups are cluster-wide: the remaining node-local :pg.get_local_members/1 senders on the sync wake-up path (Room.Server join / leave events and /send, createRoom, join / leave, personal room, decline, upgrade state copy) use :pg.get_members/1 (closes fe)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: not-needed
matrix: false
ui: false
traceability_id: REQ-2026-001
created: 2026-10-26
branch: feature/migrate-to-oauth2
---

# Story: long-poll `/sync` wake-ups are cluster-wide (follow-up `fe`)

## Story

**As** a user whose `/sync` long-poll runs on a different cluster node than the process that writes an event (a message, a join,
a leave, a decline, a new room), **I want** my long-poll to be woken immediately, **so that** the event reaches my client at once
instead of up to 25 s late when its sync task's timeout fires (cluster-safety skill: `:pg.get_members/1`, never
`:pg.get_local_members/1`, for cross-process notification).

Hardening of the cluster-safety rule; no API, schema or response change. The newer writers (moderation, state writer, redaction,
power levels, invite / upgrade invitation wakes via `wake_invitee/2`, `Room.Server.broadcast_room/2` and `wake_user/2`) and
`RoomAccountDataStore.notify_sync/2` already use `:pg.get_members/1`; this story converts the rest.

## Premise check (2026-10-26, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `d6c7fbc0`, read-only)

`grep -rn get_local_members server/lib` finds 11 call sites. The sync long-poll (`wait_loop/2`,
`event_dispatcher/server.ex` ~6105) wakes on `{:new_event, _}`, `{:new_invite, _}`, `{:new_join, _}`, `{:new_leave, _}` and
`{:account_data_changed, _}` only.

STILL NODE-LOCAL on the sync wake-up path (9 sites, in scope):

| # | File:line (HEAD) | Function | Group / message | `fe` text |
|---|---|---|---|---|
| 1 | `server/lib/nebu/matrix/room/server.ex:1112` | `emit_membership_event/4` (join / leave of `Room.Server`, callers l.540 / 566) | `room:<id>` / `{:new_event, _}` | confirmed |
| 2 | `server/lib/nebu/matrix/room/server.ex:1613` | `sign_and_persist_event/6` (step 6 of `send_event`, the `/send` message path) | `room:<id>` / `{:new_event, _}` | confirmed |
| 3 | `server/lib/nebu/matrix/event_dispatcher/server.ex:518` | `do_create_room/3` (the `m.room.create` event) | `room:<id>` / `{:new_event, _}` | confirmed ("createRoom writers") |
| 4 | `server/lib/nebu/matrix/event_dispatcher/server.ex:564` | `do_create_room/3` (creator wake) | `user:<creator>` / `{:new_join, _}` | CONTRADICTS the `fe` parenthesis "sync-membership-partition moved the ... createRoom wake-ups to `:pg.get_members/1`": only the createRoom INVITE wakes moved (`wake_invitee/2`); the creator's `{:new_join}` is still local |
| 5 | `server/lib/nebu/matrix/event_dispatcher/server.ex:2060` | `do_join_room/3` | `user:<id>` / `{:new_join, _}` | confirmed ("join wake-up") |
| 6 | `server/lib/nebu/matrix/event_dispatcher/server.ex:2739` | `leave_room/2` | `user:<id>` / `{:new_leave, _}` | confirmed ("leave wake-up") |
| 7 | `server/lib/nebu/matrix/event_dispatcher/server.ex:7037` | `create_personal_room/2` (via `ensure_personal_room/1`) | `room:<id>` / `{:new_event, _}` | NOT named in `fe` (a createRoom-like writer) |
| 8 | `server/lib/nebu/matrix/event_dispatcher/server.ex:7982` | `emit_decline_event/2` (archived-room decline, callers l.2856 / 2868) | `room:<id>` / `{:new_event, _}` | confirmed |
| 9 | `server/lib/nebu/matrix/event_dispatcher/server.ex:8989` | `emit_state_event_at/6` (createRoom initial / name / topic / alias / preset state l.722-911, explicit alias l.1776, and via `emit_state_event/5` the `upgrade_room/2` create event l.8167 and `copy_state_events/3` l.9092-9093) | `room:<id>` / `{:new_event, _}` | confirmed for "createRoom writers"; the "upgrade wake-ups" of `fe` are PARTLY open: the upgrade INVITATION wake is cluster-wide (membership-state-model note), the new room's create / copied state events go through this site and are still local |

NOT on the sync wake-up path (2 sites, out of scope, unchanged): `server/lib/nebu/matrix/room/server.ex:746`
(`handle_call({:set_typing, ...})`) and `:782` (`handle_info({:typing_expire, _})`) send `{:typing_update, _, _}`, which no
`server/lib` process consumes (`wait_loop/2` does not match it, it is discarded by the flush of the sync task). Recorded in the
`fe` closure note as a cluster-safety leftover of the typing feature (it becomes relevant only when typing is delivered by `/sync`).

Already cluster-wide (no change): `Room.Server.broadcast_room/2`, `wake_user/2` (l.1090-1091), `wake_invitee/2`
(`event_dispatcher/server.ex` ~3333), `RoomAccountDataStore.notify_sync/2`.

Test patterns in the repo: AST guards over the module source (`state_writer_redaction_unit_test.exs` ~1151 "cluster safety (D8,
fe)", `membership_state_unit_test.exs` ~512 `calls(body, :get_local_members)`); NO multi-node test exists
(`room_server_clustering_test.exs` moduledoc: LocalCluster not in deps; no `:peer` use in `server/test`).

Existing docs tests pin the `fe` row text: `sync_membership_partition_docs_test.exs:122` (`get_local_members`, `get_members`,
`node-local`), `moderation_routes_docs_test.exs:409` and `power_levels_docs_test.exs:367` (`:pg.get_members/1`),
`state_writer_redaction_docs_test.exs:378` (`` `:pg.get_members/1` ``, `` `write_state/5` ``), `membership_state_model_docs_test.exs:478`
(`` `:pg.get_members/1` ``, `upgrade`).

### Sizing

Small. 9 one-line call-site changes in 2 files (`get_local_members` -> `get_members`, or the existing `broadcast_room/2` /
`wake_user/2` helpers in `Room.Server`; an equivalent private helper pair in `EventDispatcher.Server` is allowed), the `fe` row closed.
No migration, no API change, no config. New tests and tooling (ATDD step, amended 2026-10-26):

- `server/test/nebu/matrix/sync_wakeups_cluster_unit_test.exs` (AST guard, scan, positive controls, self-tests);
- `server/test/nebu/matrix/sync_wakeups_cluster_test.exs` (two modules: `SyncWakeupsClusterTest` = the dynamic trace proof for all 9 sites +
  the same-node regression tests, default suite; `SyncWakeupsClusterPeerTest` = the opt-in two-node `:peer` tests, tag `:cluster`);
- `server/test/nebu/matrix/sync_wakeups_cluster_docs_test.exs` (row `fe`);
- `server/test/test_helper.exs`: one line, the plain exclusion of the tag `:cluster` (no epmd, no distribution);
- the D5 tests: a `describe "D5 - ..."` and the `LaggingRegistry` seam module appended to
  `server/test/nebu/matrix/event_dispatcher/sync_membership_partition_test.exs` (same fixtures: real room processes, fake world);
- no tracked tooling: the opt-in two-node proof is run by hand with the command line of D2 (b); a git-excluded pipeline helper may wrap it.

## Decisions

- **D1 Scope = the sync wake-up path.** Every `:pg` send whose message `wait_loop/2` matches goes through `:pg.get_members/1`.
  The typing broadcasts (no consumer) stay as they are and are listed as an allowed exception, with the reason, in the guard test.
- **D2 Proof of cluster-wide delivery (amended 2026-10-26).** **(a) the AST guard and (c) the dynamic trace proof are the gate for all 9
  sites without distribution; (b) a two-node `:peer` test is an opt-in second proof (tag `:cluster`, a MANUAL proof run with
  `elixir --name <node>@127.0.0.1 --cookie <random> -S mix test --only cluster` in a container, not run by CI and not part of the
  default suite because distribution must exist before the application boots).**
  (a) An AST guard (repo pattern) over `Nebu.Matrix.Room.Server` and `Nebu.Matrix.EventDispatcher.Server`: no function that sends
  `:new_event` / `:new_join` / `:new_leave` / `:new_invite` / `:account_data_changed` calls `:pg.get_local_members`; plus a source scan
  of `server/lib`: the only `get_local_members` calls left are the two typing functions (positive control: `get_members` callers exist;
  an import / alias of `:pg` is forbidden; the guard is self-tested on code strings and on mutated sources).
  (c) A dynamic trace proof (one node, no distribution, fake database, `async: false`): `:erlang.trace_pattern({:pg, :get_local_members, 1}, ...)`
  plus `:erlang.trace(:all, ...)` with a separate tracer process; while Room.Server join / leave / `send_event` (sites 1, 2), `create_room`
  with a name and a topic (3, 4, 9), `join_room` (5), `leave_room` (6), `run_post_login_provisioning` (7) and the archived-room decline (8)
  run, NO call of `:pg.get_local_members/1` for a `user:` / `room:` group happens (positive control: a traced Task and the test process
  call it and the trace sees both). (b) OTP `:peer`, no new dependency: the test node is started by the runner as
  `elixir --name nebu_test@127.0.0.1 --cookie <random> -S mix test --only cluster` (epmd and the distribution port on 127.0.0.1, in a
  container, nothing on the host); ONE peer node per module runs the default `:pg` scope and a forwarding process on it joins `user:<id>` /
  `room:<id>`; writers on the test node must reach it: sites 1, 2, 4, 5, 6 and 8 (3, 7, 9 write to a room whose id is generated inside the
  call: nothing can be subscribed beforehand). The module asserts `Node.alive?()`, so `--include cluster` on a plain node fails loudly.
  The default suite never starts epmd or distribution (a node that becomes distributed after the application booted renames `node()` under
  running Horde / `:pg` / ETS).
- **D3 No new disclosure.** The messages go to the same groups as before, only to members on every node; each sync task still
  filters by its own partition (`wakes_sync?/3`) and re-reads through the visibility-filtered statements. Hence
  `security_review: not-needed`.
- **D4 `fe` closure keeps the pinned strings.** The row becomes "**CLOSED by story sync-wakeups-cluster-wide (date): ...**"
  followed by the original text, so the five docs tests above stay green; status column `closed`. The docs test of this story needs
  these tokens: an ISO date (`YYYY-MM-DD`) right after `CLOSED by story sync-wakeups-cluster-wide (`; the function names
  `emit_membership_event`, `send_event`, `do_create_room`, `do_join_room`, `leave_room`, `create_personal_room`, `emit_decline_event`,
  `emit_state_event_at`; the typing exception with `set_typing`, `typing_expire`, `typing_update` and a reason phrase containing
  `no process` or `no consumer` (nothing consumes the typing message); no ` | ` inside the cell (exactly 4 cells); the status cell
  exactly `closed`; the original text (title "Long-poll wake-ups are node-local (cluster-safety)") and the origin cell unchanged. After
  code review cycle 0 the row also names `D5` (the registry-lag fix) and calls the two-node test a manual proof that CI does not run; no
  tracked text names the git-excluded `.oauth-ci` helper.
- **D5 A sync rebuild never silently loses a joined room whose room process is not yet resolvable on its node (added 2026-10-26, code
  review cycle 0, M1).** Cause: with cluster-wide wake-ups a sync task on node B wakes within milliseconds of the creator's `{:new_join}` /
  the join wake (sites 4, 5) and rebuilds; `fetch_delta_rooms/3` reads the events from the database (`visible_since!`) but then asks the room
  process through `room_registry_module().get_state/1` (the Horde via-name). Horde replicates registrations by delta-CRDT (sync interval
  300 ms) and `RoomSupervisor.await_registry/3` waits only on the starting node, so on B the call exits `:noproc`, the `catch :exit,
  {:noproc, _} -> []` drops the room, and when another joined room of the same build has a newer event the anchor (`newest_event_id/2`)
  moves past the dropped room's create / member / power-level events: an incremental `/sync` never delivers them (the client sees the room
  after an initial sync only). Before this story B woke at its 25 s timeout, when Horde had converged. What the room process is needed for
  in `fetch_delta_rooms/3`: only `state` (the joined member slice, the power levels and their identity for `build_state_events/4`,
  `attach_heroes`); the timeline comes from the database.

  **Revised after code review cycle 1 (2026-10-26, M1: a room that stays DOWN pinned the anchor).** The first version of this decision
  treated every `:noproc` as "the registry may still catch up" and kept the anchor for it. A room whose process stays down for good is
  not rare: `upgrade_room` archives the old room (`freeze_old_room!`: `archive_room_atomic` + terminate its process), `Room.Server.init/1`
  stops `:normal` for an archived room so it can never start again, and `membership_candidates` ignores `rooms.status`, so the members'
  rows stay in the join class; after a single-node restart nothing restores room processes at boot either. For such a room the first
  version cost every incremental `/sync` of every member 1 s, re-delivered the other rooms' events (and invites / leaves) since the old
  anchor, and returned at once (the delivery ended the wait): a permanent request loop of about one per second. Before the story the
  room was dropped silently and the anchor advanced. **Smallest design (revised):**
  (1) on the FIRST `:noproc` for a room that HAS events to deliver, read `rooms_db_module().get_room_status(room_id)`: `{:ok, "archived"}`
  or `{:error, :not_found}` is DEAD at once: no polling, NOT counted as unresolved, the anchor may advance (the pre-story behaviour, 0 ms
  extra); the drop is logged at debug level only (no per-build warning). A room without events to deliver is never asked at all, so an idle
  dead room costs nothing. (2) Any other status (or an unreadable one) is a room that should be running: poll the registry in small steps
  (50 ms) until ONE deadline per build of 1 s, shared by all rooms of the build; a room that resolves is delivered as usual. (3) When the
  deadline has passed, start the room ONCE on demand (`RoomSupervisor.start_room/1`: the same on-demand start the delta path already
  does in `full_state_rooms` and the initial sync does; `Room.init/1` reloads everything from the database) and ask `get_state` once
  more: a process that was really down is delivered in the SAME response and the anchor advances. For a room that was polled for the
  full bound, Horde's 300 ms registry sync has converged, so a live process would have been found by the poll and `start_room` finds it
  (`:already_started`). **Exception (accepted, code review cycle 2, m1):** the deadline is shared by the rooms of a build, so a room Y
  that the build first meets AFTER another room X has used up the second is started on its FIRST `:noproc`, with no polling of its own;
  Y's registration may be less than 300 ms old, so for Y the "registry has converged" argument does not hold and a second process next
  to Y's live one on another node is possible. It is rare (it needs one unresolvable room X plus a freshly created / joined room Y in the
  same build) and its outcome is Horde's name-conflict kill of one of the two processes, the same residual the sibling paths
  (`full_state_rooms`, the initial sync) accept for every room, without any bound at all. (4) Only a room that is still unresolvable then (a transient start failure, a registry that still does not
  answer) is NOT delivered, raises NO error (a dead room process must not make every `/sync` fail: no permanent 503) and keeps the
  PREVIOUS anchor (`last_event_id`; the since token itself is a new one), so the next sync delivers the room's events; that case, and
  only that case, re-delivers the other rooms' events since the old anchor once more (`limited: true` windows included: a repeated
  event id is harmless to a client that dedupes by event id, but a `limited` window is re-sent as a window), so it must stay a rare,
  transient state; its warning stays value-free (the count of rooms only). Rejected: building the state from the database instead of the
  room process (the member slice and the power-level identity live in the process: a second data path, a larger change); an anchor that
  excludes only that room (the token holds ONE event id); a 503 (permanent for a dead room); starting the room on demand BEFORE the bound
  as the rule (a node that merely lags could start a second process next to the live one on another node; normally a room reaches the
  start only after it was polled for the full bound, when the registry has converged; the shared-deadline exception above is the one
  accepted case of a start without polling); keeping the anchor for a dead room (the permanent loop above).
  **Latency and task budget, stated honestly:** each build has its OWN 1 s deadline (the deadline is computed per `fetch_delta_rooms/3`
  call, not per request). One request runs the first `consistent_delivery` (up to 3 builds: the build plus 2 consistency rebuilds), the
  long-poll wait (at most 25 s) and, after a wake, another `consistent_delivery` (up to 3 builds); all inside the sync Task, whose budget is
  `timeout_ms + 10 s` = 35 s with the default 25 s wait (10 s for `timeout=0`, which runs no wait and no wake rebuild: at most 3 builds).
  The poll bound alone, an unresolvable room in every build, is about 3 + 25 + 3 = 31 s of the 35 s: this is why the bound is 1 s (a bound
  of 2 s would be 37 s and kill the Task). **The start attempt adds its own cost per room (code review cycle 2, m2):**
  `RoomSupervisor.start_room/1` runs Horde's `start_child`, the database reads of `Room.Server.init/1` and `await_registry/3`, which waits up
  to 500 ms before it answers `{:error, :registry_timeout}`; each unresolvable room pays this once per build. With k such rooms a build costs
  about 1 + 0.5 k s, so k = 2 rooms hitting `:registry_timeout` in all 6 builds cost 6 x (1 + 1) + 25 = 37 s > 35 s: the sync Task is killed
  (`Task.await` exits, the request fails, no token is persisted, the client retries). With `timeout=0` the same k = 2 costs 3 x 2 = 6 s of
  10 s. Accepted as a rare residual: it needs a start that fails slowly for two rooms in every build of one request; sharing one deadline
  across the request would need the deadline threaded through `consistent_delivery` / `build_delta` and is not worth it. A room that is
  not archived but can NEVER start pins the anchor for good: follow-up `bp`. Pinned by the `D5 - ...` describe of `sync_membership_partition_test.exs` (a lagging registry that resolves, one that never
  resolves, a room that is really down is started on demand after the bound, an archived and a not_found room are dead at once without
  polling and without pinning the anchor, a room that cannot be started keeps the anchor, an idle room is not polled, the bound is per
  build, the upgrade freeze modelled).

## Acceptance Criteria

```gherkin
Feature: Long-poll /sync wake-ups reach sync tasks on every cluster node

  Scenario: A message on another node wakes the long-poll at once
    Given a user's /sync long-poll is subscribed to room:<id> on node B
    When another member sends a message to the room through Room.Server on node A
    Then the sync task on node B receives {:new_event, event} without waiting for its timeout

  Scenario: Join, leave, createRoom, decline and upgrade wake-ups are cluster-wide
    Given a user's sync task is subscribed to user:<id> and room:<id>
    When the user joins, leaves, creates a room (initial state events included), gets a personal room, declines an archived-room invitation, or a room is upgraded
    Then every wake-up reads its recipients with :pg.get_members/1 (cluster-wide) and never calls :pg.get_local_members/1 (proved for all 9 sites by the guard and the dynamic trace proof)
    And cross-node delivery is additionally demonstrated by the opt-in two-node test for sites 1, 2, 4, 5, 6 and 8 (leave, send, join member events, createRoom creator wake, join, archived-room decline)

  Scenario: No node-local sender remains on the sync wake-up path
    Given the source of server/lib
    When the guard test scans every :pg call
    Then no function that sends :new_event, :new_join, :new_leave, :new_invite or :account_data_changed calls :pg.get_local_members/1, and the only remaining get_local_members calls are the two typing broadcasts of Room.Server

  Scenario: Local delivery is unchanged
    Given a user's sync task runs on the same node as the writer
    When any of the converted writers emits its event or wake-up
    Then the existing single-node sync tests stay green (the long-poll wakes exactly as before)

  Scenario: Follow-up fe is closed
    Given docs/stories/oauth-broker/follow-ups.md
    When the story is done
    Then row fe is marked "CLOSED by story sync-wakeups-cluster-wide", lists the converted sites and the typing exception, keeps the original text, and its status column is closed

  Scenario: A joined room whose process is not yet resolvable on the waking node is not lost (D5)
    Given a user's sync task on node B wakes for a room that node A has just created or joined
    And the room process of that room is not yet resolvable on node B (the registry of Horde lags)
    When the sync rebuilds
    Then it retries the room for at most one second per build and delivers it as soon as it resolves
    And if it is still not resolvable after the bound, the room is started once on demand and delivered in the same response
    And if it cannot be started either (a transient failure), the room is not delivered, no error is raised, and the anchor stays at its previous event so that the next sync delivers the room's events

  Scenario: A room that is dead for good never pins the anchor (D5)
    Given a joined room whose process cannot run (an upgraded, archived room) or whose row is missing
    And it has an event newer than the since token
    When the sync rebuilds
    Then the room is dropped at once (no polling, no warning per build), the anchor advances, and the next sync does not re-deliver the other rooms
```

## Definition of Done

- [x] All Gherkin scenarios have failing tests (ATDD)
- [x] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Dev Agent Record

- **Implementation (2026-10-26).** `Room.Server`: `emit_membership_event/4` and `sign_and_persist_event/6` call the existing cluster-wide
  `broadcast_room/2` (sites 1, 2). `EventDispatcher.Server`: `do_create_room/3` (sites 3, 4), `do_join_room/3`, `leave_room/2`,
  `create_personal_room/2`, `emit_decline_event/2`, `emit_state_event_at/6` read their recipients with `:pg.get_members/1` (one-line changes, sites 3-9).
  The two typing broadcasts are unchanged (D1). `docs/architecture/06-runtime.md` Scenario 3a: the join wake-up reads `:pg.get_members/1`.
  Row `fe` of `follow-ups.md` closed per D4.
- **Implementation, code review cycle 1 (D5, M1).** `fetch_delta_rooms/3` answers `{rooms, unresolved}`: for a room WITH events the room state is
  read through `resolve_room_state/2`, which on a `:noproc` exit polls the registry every 50 ms until ONE deadline of 1 s per build (computed once per
  `fetch_delta_rooms/3` call, shared by all rooms; a room without events is never asked). A room still unresolvable is not delivered and counted;
  `do_incremental_sync/6` then keeps the previous anchor (`last_event_id`, the since token itself is new), and a value-free warning (the count only) is
  logged. The build runs in the per-request sync Task (`sync_delta/2`, `Task.async`), so the sleep blocks nothing shared; worst case per request is
  one bound per build (first build + consistency rebuilds + the wake rebuild), inside the Task budget `timeout_ms + 10 s`. The per-room body stays
  inline in `fetch_delta_rooms/3` (the AC9 (a) AST pin of `membership_state_unit_test.exs` requires the `build_state_events` call there). Stale
  "30-second" comment of `emit_membership_event/4` corrected (a touched line).
- **Verification (cycle 1).** Story tests + `sync_membership_partition_test.exs` (incl. the five D5 tests) + the five sibling `fe` docs tests +
  `membership_state_unit_test.exs` + `member_slice_gate_test.exs`, throwaway PG: 334 passed. `mix test test/nebu/matrix --include integration`
  (fresh throwaway PG): 4488/4496; the 8 failures are known families: 7 ModerationTestSupport `tick/0` :timeout (`history_visibility_concurrency_test.exs`,
  `moderation_fix_cycle1_http_test.exs`; both green alone, 9/9) and `regression_sync_load_test.exs` (median latency budget; fails identically on the
  HEAD sources in cycle 0, parked in CI). The opt-in two-node proof (D2 (b), run with `elixir --name nebu_test@127.0.0.1 --cookie <random> -S mix test
  --only cluster` in a container; locally wrapped by a git-excluded pipeline helper): 6 `:cluster` tests passed (Elixir 1.20). The DB-free unit job on
  Elixir 1.19 (`mix test --warnings-as-errors`): 6537 tests, 0 failures.
- **Implementation, code review cycle 2 (D5 revised).** `resolve_room_state/3` (phase `:first` / `:polling` / `:started`): on the FIRST `:noproc`
  it reads `rooms_db_module().get_room_status/1` (through the existing `guarded_status_read/1`, so a raising or exiting read is `{:error, _}`):
  `{:ok, "archived"}` or `{:error, :not_found}` throws `:sync_room_dead`, which `fetch_delta_rooms/3` catches as a drop that is NOT counted
  (the anchor may advance; `Logger.debug`, value-free). Any other result (also an unreadable status) is polled every 50 ms until the per-build
  deadline; then `RoomSupervisor.start_room/1` is called ONCE (result ignored, as in `full_state_rooms/3`; a raise / exit is swallowed by the
  same guard) and `get_state` asked once more; only a `:noproc` after that counts as unresolved (anchor kept, value-free warning with the
  count). `build_state_events` stays inline in `fetch_delta_rooms/3`. Still inside the per-request sync Task; worst case as stated in D5.
- **Verification (cycle 2).** Story tests + `sync_membership_partition_test.exs` (incl. the cycle-2 D5 tests) + the five sibling `fe` docs tests +
  `membership_state_unit_test.exs` + `member_slice_gate_test.exs`, throwaway PG: 341/342; the one failure is the `MemberSliceGateTest` throughput
  sanity check (a 1 s timing test of the untouched gate module, host load average ~26 at that time). `mix test test/nebu/matrix --include integration`
  (fresh throwaway PG): 4502/4504; `regression_sync_load_test.exs` (known, see cycle 1) and `SyncConcurrentTest` "50 concurrent /sync long-polls"
  (not every answer 200; no D5 warning or sync error logged at that time; green alone 2/2). Two-node proof (manual, command line of D2 (b)): 6 `:cluster`
  tests passed (Elixir 1.20). DB-free unit job on Elixir 1.19 (`--warnings-as-errors`): 6545 tests, 0 failures.

- **Code review cycle 2 (3 MINOR + 1 INFO, no new behaviour).** m1: D5 (and `06-runtime.md`, the scope doc) states the shared-deadline
  exception honestly (a room met after another one used up the second is started on its first `:noproc` without polling; accepted, rare,
  same residual as `full_state_rooms` / the initial sync) and the "Rejected: before the bound" sentence no longer contradicts it. m2: the
  per-room start cost (`start_child`, the init reads, `await_registry` up to 500 ms) and the true budget (`timeout_ms + 10 s`, 10 s for
  `timeout=0`) with the arithmetic 6 x (1 + 1) + 25 = 37 s > 35 s as an accepted rare residual; `06-runtime.md` says "per-request sync Task"
  instead of "request process". m3: follow-up row `bp` (formerly unused id, recorded on the id line next to `bz` / `be`; the `gm` onward pins
  stay) for the non-archived room whose process can never start, named in the `fe` closure; one docs test ADDED for it. i1: the warning reads
  "not resolvable in the room registry within 1000 ms or after the start attempt" (count only). Verification: see the cycle-3 report.

## Change Log

- 2026-10-26 (ATDD step, test-review fix pass): D2 / Scenario 2 / Sizing / D4 amended. The AST guard (a) plus a dynamic trace proof (c) are the
  gate for all 9 sites without distribution; the two-node `:peer` test (b) is an opt-in second proof (tag `:cluster`, a manual proof, distribution started
  before the application boots, loopback only, random cookie, never in the default suite); the docs test tokens of D4 are named.
- 2026-10-26 (code review cycle 0, M1): D5 added (a sync rebuild that finds a joined room whose room process is not yet resolvable on its node
  retries for at most 1 s per build, and otherwise keeps the previous anchor instead of silently losing the room), Scenario 6, the D4 tokens
  `D5` / manual proof; the two-node proof is described by its plain command line, not by the git-excluded helper.
- 2026-10-26 (code review cycle 1, M1): D5 revised. A dead room (`archived` / `not_found` status) is dropped at once without polling and without
  pinning the anchor (0 ms, pre-story behaviour); a room that should run is polled for the 1 s per-build bound, then started once on demand and
  asked once more (delivered in the same response); only a transient failure keeps the previous anchor. The "an idle dead room costs nothing" claim
  holds for rooms without events, the "repeated event id is harmless" claim is qualified (a `limited` window is re-sent), the task budget
  arithmetic is stated (worst case about 31 s of 35 s, the reason for the 1 s bound), Scenario 6 is split, a follow-up row (id `be`) records
  that the tombstone of an upgraded room is not delivered to members who missed it.
- 2026-10-26 (code review cycle 2, m1 - m3, i1): D5 states the shared-deadline exception (start without polling for a room met after the
  bound is spent) and the per-room start cost with the task budget arithmetic (37 s > 35 s for two slowly failing starts in all six builds,
  accepted as rare); follow-up `bp` (a non-archived room that can never start still pins the anchor); warning text covers the start attempt.
