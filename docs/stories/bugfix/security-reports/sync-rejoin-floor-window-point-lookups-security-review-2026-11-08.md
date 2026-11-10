## Security Review — sync-rejoin-floor-window-point-lookups

**Diff scope:** FINAL staged tree (re-run after comment/doc-only changes; overwrites the earlier versions of this report). Migration 000063 (covering index `events_room_pos_ts_idx (room_id, room_pos) INCLUDE (origin_server_ts) WHERE room_pos IS NOT NULL`, up + down), a moduledoc-only change in `server/lib/nebu/matrix/room/db.ex` (`git diff HEAD -- server/lib`: the query text of `fetch_visible_events_in_range_segmented/5` is unchanged), and test changes (new floor-bound probe, migration test, adapted plan-shape tests in history_visibility / membership_partition / range_scan_bound), plus the story file.
**Date:** 2026-11-09 (file name keeps 2026-11-08 as the pipeline asked)
**Prescan:** `sec-candidates.md` had 0 candidates (523 added lines, 9 files; path trigger: the migration).

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/priv/migrations/000063_events_room_pos_covering_idx.up.sql:24-33 | Availability during deploy: a plain `CREATE INDEX` inside the single migration transaction takes a SHARE lock on `events`, so writes (messages, joins, state events) wait for the whole build on a large instance. Documented in an operator note with a `CONCURRENTLY` pre-create path and an INVALID-index check. | Operational only: follow the note (maintenance window or pre-create concurrently). Optionally repeat it in the release notes / upgrade guide. No code change needed. |

### Detail

**Finding #1 — SHARE lock on `events` during the index build** [LOW]
`Nebu.Release.migrate/0` runs each file in one transaction, so `CONCURRENTLY` cannot be used in the file. The build blocks INSERT/UPDATE/DELETE on `events` (reads continue) until every positioned event is indexed. Only an operator deploy triggers this; an attacker cannot. The note describes the effect correctly. It gives a manual `CREATE INDEX CONCURRENTLY IF NOT EXISTS` with the same definition (the file is then a no-op) and explains how to find and rebuild an INVALID index left by a failed concurrent build. The migration test checks that the documented manual statement matches the file. This is an operations / defence-in-depth item with no exploit path.

### Checked, no issue

- **Data integrity / exposure of the migration:** the up file has exactly one statement, `CREATE INDEX IF NOT EXISTS` (not unique, partial, same predicate as `events_room_pos_idx`). The down file is only `DROP INDEX IF EXISTS events_room_pos_ts_idx`. No DML, no GRANT/REVOKE, and no change to roles, RLS, views or existing indexes. The uniqueness pin `events_room_pos_idx` is untouched, and the test asserts it is still UNIQUE with no INCLUDE. Both files are idempotent. The rolled-back round-trip test asserts that down removes only this index. "Rolling-deploy safe" is accurate: old nodes ignore the index.
- **Authorization / visibility:** the index holds no new data. It stores `origin_server_ts` of rows already in `events`, the planner is the only way to reach it, and it cannot be selected from directly. Who can read what is still decided by the unchanged visibility predicates of the range read (history-visibility segments, membership gating). The query text is identical to HEAD, so no access-control logic changed and nothing new can leak.
- **Cost bound on the user-reachable gated rejoin `GET /sync` (availability):** before the fix, with global position statistics the planner could pick a room-only bitmap scan that reads the whole room, per device and per replay of the same `since` token. That is the amplification this story fixes. With the covering index the floor is an index-only scan of at most 64 entries (heap fetches only for pages that are not all-visible, also at most 64). `sync_rejoin_floor_bound_db_test.exs` checks the bound (rows of `events` read <= 64 per statement) on a hostile skew built from the real indexes only: one large room with a single timestamp so `events_room_id_ts_idx` deduplicates and stays small, and 400 small rooms. It covers stale statistics and a fresh ANALYZE, custom and generic plans, and planner switches off. The residual wording in the moduledoc and the migration header is honest. It says the bound is pinned by plan-shape tests and row probes and is not guaranteed for an arbitrary planner. It also names the remaining case (index-only scans not usable AND a smaller room-only index AND an inflated estimate can still give one read of the room per floor, the behaviour before the fix). This is not rated as a finding: the endpoint is authenticated and rate-limited, the worst case is the behaviour that already existed, not a new exposure, and the probe catches a regression in CI.
- **Injection:** the only interpolation in the tests is `SET LOCAL #{mode}` / `#{sw}` / `#{setting}` with module-attribute constants, plus generated test identifiers (`T.rand`). This is test code with no user input. Production SQL is unchanged.
- **Tests leave nothing behind:** the floor probe's hostile world (rooms, events, ANALYZE) runs in a privileged transaction that ends in `Postgrex.rollback` (the `{:error, …}` result is asserted). It creates no extra index. The side effects of the in-transaction ANALYZE on `pg_class` and the dead tuples are cleaned up by a `VACUUM ANALYZE events` in an `after` block. The migration DDL round trip is rolled back as well. The membership-partition bulk rows have an `on_exit` DELETE scoped by room and the `@bulk:test.local` sender. The telemetry handler is detached in `after`. DDL inside a transaction holds ACCESS EXCLUSIVE on `events` briefly, on the test DB only, and the tests are `async: false`.
- **Secrets / logs:** no Logger/IO output of tokens, credentials or message content in the diff. Test content is synthetic.
- Out of scope / not touched: routes, plugs, auth, crypto, cookies, body limits, templates.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 1 — advisory

**Verdict:** APPROVED
