# Dev cycle 3 report: sync-wakeups-cluster-wide (3 MINOR + i1, no new behaviour), not committed

All runs below COMPLETED; `cleanup.sh` RAN after each (printed `cleaned`). Long suites NOT run (as instructed).

## Changes
- **i1** `server/lib/nebu/matrix/event_dispatcher/server.ex` (the only server/lib change this cycle, one string): the count-only warning now reads
  `sync: N joined room(s) with new events not resolvable in the room registry within 1000 ms or after the start attempt; the anchor is kept`.
- **m1** story D5: the shared-deadline exception is stated and accepted (a room Y first met after room X used up the second is started on its
  first `:noproc` without polling; Y's registration may be < 300 ms old, so "converged" does not hold for Y; rare; same residual as
  `full_state_rooms` / the initial sync, which have no bound). The "Rejected: starting BEFORE the bound" sentence now says "as the rule" and
  names the shared-deadline case as the one accepted start without polling. Same exception added to `docs/architecture/06-runtime.md` and the
  `/sync` row of `docs/matrix-api-scope.md`.
- **m2** story D5 "Latency and task budget": the budget is `timeout_ms + 10 s` (35 s at 25 s; 10 s for `timeout=0`, at most 3 builds); the
  per-room start cost (Horde `start_child`, `Room.Server.init/1` DB reads, `await_registry` up to 500 ms before `{:error, :registry_timeout}`);
  arithmetic 1 + 0.5 k s per build, k = 2 in all 6 builds: 6 x (1 + 1) + 25 = 37 s > 35 s => Task killed, request fails, no token persisted,
  client retries (timeout=0: 3 x 2 = 6 s of 10 s); accepted as rare. Same in 06-runtime.md and the scope doc. 06-runtime.md: "runs in the
  request process" -> "runs in a per-request sync Task". (The `bz` row's "request process" refers to the WRITER, left as is.)
- **m3** follow-ups.md: new row `bp` (free id, previously listed as "unused: bp"; now recorded on the id line next to `bz` / `be`: "`bz`, `be` and
  `bp`, formerly unused, are now the three rows after `fe`: ... cycles 0, 1 and 2"; the `unused:[^.]*`gm` onward` pins stay valid). Row text as
  requested (load_members error / build_init_state raising, ~1 request/s loop, 1 s poll + start attempt + crash report per build, before the
  story silently dropped; fix direction cap pinned syncs or drop after a non-transient start failure) | origin `sync-wakeups-cluster-wide (code
  review cycle 2)` | `open, non-gating`. The `fe` closure names it ("...: `bp`"). `sync_wakeups_cluster_docs_test.exs`: ONE test ADDED (row bp
  unique, 4 cells, open non-gating, key phrases, story name, fe names `bp`, `unused: bp,` gone, `gm` onward pin kept); nothing weakened.
- Story: Dev Agent Record (cycle 2 review bullet) and Change Log entry added. Status stays `ready`.

## Verification
1. quick.sh, fresh PG, `--warnings-as-errors`: the 3 story test files + `event_dispatcher/sync_membership_partition_test.exs` + the 5 sibling
   `fe` docs tests: **304 passed, 10 excluded (:cluster), 0 failures**.
2. Extra (because the shared id line and the scope `/sync` row were edited): all 28 `*docs_test.exs` under test/nebu: **443 passed, 8 excluded**;
   every test file that reads follow-ups.md / matrix-api-scope.md / 06-runtime.md (30 files, `adr_033_test.exs` left out: needs `_bmad-output`,
   known): **468 passed, 8 excluded, 0 failures**.

## Surprising
Nothing.
