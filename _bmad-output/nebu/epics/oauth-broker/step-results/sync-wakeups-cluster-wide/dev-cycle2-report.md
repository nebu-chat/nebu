# Dev cycle 2 report: sync-wakeups-cluster-wide (revised D5), not committed

All verification runs listed below COMPLETED (none is in progress or unknown). `cleanup.sh` RAN at the end (printed `cleaned`).
No test was changed or weakened; no test bugs found. Work only in the open-chat-oauth worktree.

## Diff stat of server/lib
```
server/lib/nebu/matrix/event_dispatcher/server.ex | 84 +++++++++++++++++++----
server/lib/nebu/matrix/room/server.ex             | 10 ++-
2 files changed, 74 insertions(+), 20 deletions(-)
```
Whole tree (for context): pipeline-state.yaml 18 (not mine), docs/architecture/06-runtime.md 19 (1 line mine), docs/matrix-api-scope.md 2 (yours),
follow-ups.md 6 (fe row mine + your edits), sync_membership_partition_test.exs 283 (yours), test_helper.exs 6 (ATDD). Story + new test files untracked.

## What changed in event_dispatcher/server.ex this cycle
- `resolve_room_state/3` (phases `:first` / `:polling` / `:started`): on the FIRST `:noproc` it calls `room_dead?/1`
  (`rooms_db_module().get_room_status/1` via the existing `guarded_status_read/1`, plus the `Code.ensure_loaded?` / `function_exported?` check
  of `room_archived?/1`). `{:ok, "archived"}` or `{:error, :not_found}` => `throw(:sync_room_dead)`, no polling. A raising / exiting / other
  status read => NOT dead (never crashes the sync).
- Otherwise poll every 50 ms until the one 1 s deadline per build (per `fetch_delta_rooms/3` call, shared by its rooms). After the deadline:
  `Nebu.Matrix.Room.RoomSupervisor.start_room/1` ONCE (wrapped in the same guard, result ignored as in `full_state_rooms`), then `get_state`
  once more; a `:noproc` after that exits as before.
- Catch in `fetch_delta_rooms/3`: `:throw, :sync_room_dead` => dropped, NOT counted (anchor may advance), `Logger.debug` without ids;
  `:exit, {:noproc, _}` => counted unresolved (anchor kept, count-only warning).
- `build_state_events` stays inline in `fetch_delta_rooms/3` (AC9 (a)). Sleep only inside the per-request sync Task (`Task.async` in `sync_delta/2`).

## Verification runs (final code)
1. quick.sh, fresh PG: the 3 story test files + `event_dispatcher/sync_membership_partition_test.exs` (all D5 tests) + the 5 sibling `fe` docs
   tests + `membership_state_unit_test.exs` + `member_slice_gate_test.exs`: **341/342 passed, 10 excluded (:cluster)**.
   Failure: `Nebu.Matrix.MemberSliceGateTest` "throughput sanity: 500 readers (5 ms reads, retrying for 1 s) complete at least 60 % of the ideal
   number of reads of 3 slots (80 % when idle)" (268 reads, ideal 478). Also fails alone (12/13). 1 s timing test of the untouched gate module;
   host load average ~26 at that time; it did NOT fail in the 1.19 unit job.
2. `mix test test/nebu/matrix --include integration`, fresh PG: **4502/4504 passed, 2 skipped, 7 excluded**. Failures:
   - `Nebu.Web.RegressionSyncLoadTest` "200 concurrent /sync clients receive all 50 broadcast events with median latency <= 150ms (AC7)" (known;
     fails identically on HEAD sources, checked in cycle 0).
   - `Nebu.Web.SyncConcurrentTest` "50 concurrent /sync long-polls all receive a sent event within 500ms (AC2)": assertion "every concurrent /sync
     must return 200". NOT in the known list. Green alone 2/2; green in the cycle-0 and cycle-1 full runs; no D5 warning, sync error or pool error
     logged around it (all D5 "not resolvable" warnings come from the FakeDB D5 unit tests). Presumably load; cause NOT proven.
   - No tick/0 timeouts this run.
3. `.oauth-ci/cluster_test.sh` (Elixir 1.20): **6 passed, 12 excluded**.
4. `.oauth-ci/unit_nodb.sh 1.19-alpine` (--warnings-as-errors): **6545 tests, 0 failures, 7 skipped (4224 excluded)**.
5. `.oauth-ci/cleanup.sh`: ran at the end.

## Surprising / worth knowing
- `SyncConcurrentTest` failure above (unexplained; a second full run would settle it).
- When another room already spent the build's deadline, a non-dead room is started on its first `:noproc` without polling (consistent with
  the per-build bound of D5).
- Cost of a dead room: one `get_room_status` read per build, only when it has new events; idle dead rooms cost nothing.
- Story Dev Agent Record updated with cycle-2 implementation and verification bullets (no `.oauth-ci` path named). Status stays `ready`.
