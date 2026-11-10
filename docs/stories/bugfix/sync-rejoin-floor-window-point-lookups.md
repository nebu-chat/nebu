---
story: sync-rejoin-floor-window-point-lookups
epic: bugfix
status: ready
security_review: required
matrix: true
ui: false
---

# Bugfix — the time floor of the gated rejoin `/sync` range read is served by a covering index (migration 000063)

Found by the plan-stability spike (follow-up `I` of the `oauth-pages-redesign` flake triage): `SyncRejoinRangeScanBoundHttpTest` (scenarios 1, 2 / D6, 4) failed with
426 - 438 rows of `events` touched against a bound of "+10 over the small room" under some test orders. The story slug keeps the name of the first idea (64 point
lookups); see "Decision" for what was built and why.

## Problem

`Nebu.Matrix.Room.DB.fetch_visible_events_in_range_segmented/5` (the gated `/sync` range read of a room whose cursor base is an invitation / leave, or whose viewer changed
membership since the base) computes a time floor `rj_floor` = `min(origin_server_ts)` over the 64 positions `base - 63 .. base`, with an empty-window fallback over
`base + 1 .. min(base + 64, head)`. Both are range predicates, `room_id = $1 AND room_pos BETWEEN lo AND hi`.

The planner may serve such a range with a `Bitmap Heap Scan` on `events_room_id_ts_idx` using ONLY `room_id` as the index condition and the position range as a filter, which reads
every row of the room (404 rows removed by the filter to keep 10). It does so when the global `room_pos` statistics inflate the estimate for a low base (the position is per room,
the statistics are global, so the estimate for the range is hundreds of rows against 10 real ones) and `events_room_id_ts_idx` is much smaller than `events_room_pos_idx`
(B-tree deduplication of identical `(room_id, origin_server_ts)` keys versus a bloated unique position index). The documented bound ("holds whatever the planner picks", decision
D-A1 of story `sync-rejoin-range-scan-bound`) is therefore false for the floor window.

Impact: latent (cost only, no leak: the floor reads timestamps, the verdicts stay the visibility fragment's). A rejoin `/sync` with a low cursor on a small or medium server
dominated by one big room can read that room's whole history once per device and per replay of the same `since` token.

Two plan assertions of the test suite are over-specified in the same family: `HistoryVisibilityDbTest` AC10 (b) (single-event and search statements) and
`MembershipPartitionDbTest` D2 assert the NAME of an index (`events_room_state_idx`) for a room of three rows, where the planner may legitimately pick the other room-prefixed
index (the "whole room" is three rows, no bound is violated).

## Decision (owner, 2026-11-09): option 2, a covering index

The first fix idea, 64 point lookups on the unique key (`generate_series` + `LATERAL ... LIMIT 1`), was built and measured: it fixes the skew regime but REGRESSES the
stale-statistics regime. For a room the statistics do not know, `room_id = X` estimates about one row, as does the full unique key, so a room-only index ties with the unique
one and the smaller `events_room_id_ts_idx` wins: the planner ran a `Bitmap Heap Scan` on it 64 times (35 711 - 60 459 rows read by `SyncRejoinRangeScanBoundDbTest` D7 (1) in
the stale regime; the old range form 0 of 6 runs failed, the point lookups at least 2 of 8). No shape of the statement alone is robust in both regimes without a hint.

Chosen: **migration 000063, `events_room_pos_ts_idx ON events (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL`** (plain `CREATE INDEX IF NOT EXISTS`, the
runner applies a file in ONE transaction, same style as 000050 / 000051 / 000053; not unique, `events_room_pos_idx` stays the uniqueness pin; no existing index is dropped or
changed; the `down` file drops the new index only). The floor window is then an INDEX-ONLY scan of at most 64 entries (rows that are not all-visible yet fall back to a heap
fetch, also at most 64). The query text is UNCHANGED (the range form with its `OFFSET 0` fence): the point lookups measured equal on the covering index, so the simpler form stays.

Measured (rows of `events` read per floor, `pg_stat_xact`, custom and generic plan, window of 7 and of 64 events): covering index present, stale statistics and fresh
`ANALYZE`, both shapes: 7 / 64 rows (index-only scan, also with index-only scans switched off: plain index scan, same rows). Before the migration the range form read 436 - 438
rows in `SyncRejoinRangeScanBoundHttpTest` under the spike's bloat fixture (red), after it 3 of 3 runs green plus 6 further runs in the stale regime.

Residual (measured in a hostile rolled-back transaction, not asserted): with an additional smaller `room_id`-only index, a fresh `ANALYZE` and index-only scans switched off (or
most pages not all-visible), the planner can still pick a room-only bitmap: 500 rows once per floor, i.e. the behaviour before the migration. The migration removes the failure in
every regime with the real indexes (stale / fresh, custom / generic, with and without index-only scans: 0 of 12 floor probes above 64 rows, plus the HTTP bound test 3 of 3 and 9 further runs
between the floor tests), it cannot make the planner unable to choose another path.

**Accepted residual (owner decision 2026-11-09).** On a CHURNED table (most pages not all-visible: the covering index then costs like a plain index) with a fresh `ANALYZE` and the inflated
global `room_pos` estimate, the planner can still pick a room-only bitmap scan: ONE read of the whole room per floor (measured 500 rows in a rolled-back world, targeted suites, seed 1,
two runs), i.e. the behaviour before 000063. The migration fixes the observed failures (`SyncRejoinRangeScanBoundHttpTest` under the bloat fixture, the stale-statistics regime, the skew);
`SyncRejoinFloorBoundDbTest` asserts "at most 64 rows" with stale statistics and only "at most the room's rows" with fresh ones. No planner hint was added.

Write cost: one more index entry `(room_id, room_pos, origin_server_ts)` per positioned event.

## Acceptance criteria

```gherkin
Scenario: The floor window is served by the covering index
  Given a room with a gated rejoin range read whose cursor base is a leave / invite
  When the segmented range read computes its time floor
  Then every scan of events that carries the floor's position range carries it as an index condition (never as a filter over a room-only scan)
  And at most two position-index scans serve the floor window and its empty-window fallback, each over at most 64 positions

Scenario: The migration adds only the covering index
  Given the schema of migration 000062
  When migration 000063 is applied
  Then events has the non-unique partial index events_room_pos_ts_idx on (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL
  And events_room_pos_idx is untouched and no other statement is part of the migration
  And down removes exactly that index, up after down restores it, a second up is a no-op

Scenario: The bound test is green deterministically
  Given the index-size skew and the global position statistics of a full test run (ONE-timestamp bulk rows deleted again)
  When the floor is measured with stale and with fresh statistics, in both plan modes and without index-only or bitmap scans
  Then it reads at most 64 rows of events
  And a rejoin /sync of a large room with hidden history touches at most 10 rows more than the same room with 20 hidden events

Scenario: Plan assertions state a bound, not an index name
  Given a room of a few rows
  When the plan of the single-event / search statements and of latest_member_events is checked
  Then the assertion is "no Seq Scan, rows read of events bounded", not the name of one of two room-prefixed indexes
```

## Notes

- Result semantics: the statement text is unchanged, only an index is added, so the answer of every /sync is unchanged (the existing differential tests against the plain range read of
  `SyncRejoinRangeScanBoundDbTest` pin that). The Oracle step is therefore not re-run for the final shape (it ran for the point-lookup draft: no spec impact).
- Moduledoc D-A1 corrected: the bound is a property of the INDEX plus the statement shape, pinned by the plan-shape tests and the row probes, not a guarantee against an arbitrary planner.
- Operator note (in the migration header): the plain `CREATE INDEX` takes a SHARE lock on `events` (writes wait during the build), or pre-create it with `CREATE INDEX CONCURRENTLY`;
  the file is then a no-op.
- Merge note: the branch `feature/e2ee-client-support` renumbers its migrations after this one (owner decision), nothing to do here.
- Out of scope: `SyncRejoinRangeScanBoundDispatcherTest` D5 (`tick/0` timeout, fixed in c00382b7), the `hv_state` / `hv_mem_events` lookups (noted by the spike, production-unlikely).

## Follow-ups

- **Possible later story (option 3): a per-room floor structure.** Store (or derive from a per-room structure) the floor timestamp so that the rejoin read needs no room-prefixed scan at all; that
  removes the planner choice and with it the residual above. Not done here: larger design change.

- Operator note for a server with a LARGE `events` table: the plain `CREATE INDEX` in the migration holds a SHARE lock on `events` for the whole build (writes wait, reads continue). Pre-create it
  first: `CREATE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_ts_idx ON events (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL;` (outside a transaction), then check
  `indisvalid`; the migration is then a no-op. (`docs/stories/oauth-pages-redesign/follow-ups.md` is not edited by this run; this section and the migration header carry the note.)
- If the write cost of the extra index ever matters, `events_room_pos_idx` could be replaced by `UNIQUE (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL` in a later migration
  (one index instead of two); not done here: the owner said not to change existing indexes.
