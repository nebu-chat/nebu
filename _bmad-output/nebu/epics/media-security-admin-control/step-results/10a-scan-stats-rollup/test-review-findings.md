# Pre-Dev Test-Review: 10a-scan-stats-rollup

**Result: CLEAN — 0 MAJOR findings.**

## Coverage

All 10 Acceptance Tests from the story are represented:

- `server/test/nebu/workers/media_scan_stats_rollup_worker_test.exs` — AT1-AT7
  (counts, avg/p95 duration, scan_failed exclusion, backlog_depth snapshot,
  hour-boundary exclusion, idempotent re-run, zero-activity hour).
- `server/test/nebu/admin/media_health_live_test.exs` — AT8-AT10 (rolling 24h
  throughput/error-rate render, empty state, non-admin access control).

## Pre-existing critical finding fixed before tests were written

The story's own Technical Requirements sketch a duration CTE that filters
`WHERE to_state = 'scanning'` BEFORE computing `LEAD(...) OVER (PARTITION BY
media_id ORDER BY inserted_at)`. Since SQL applies `WHERE` before window
functions run, this always narrows each media_id's partition down to its
`:scanning` rows alone — for the common single-attempt case there is only one
such row, so `LEAD` always returns `NULL` and every duration sample is
silently dropped. Verified empirically against a real Postgres: the draft
query returns `sample_count = 0` for every fixture. Fixed in
`Nebu.Workers.MediaScanStatsRollupWorker`'s actual SQL (see that module's own
moduledoc) by computing `LEAD` over the FULL unfiltered per-media_id sequence
first, filtering to scanning-starts / terminal-ends only in an outer step —
this also naturally excludes `:scan_failed` retry sequences from the duration
stats (AT3) without any special-casing.

## Isolation design (test-quality judgment calls, not story gaps)

- Worker tests use `on_exit` to remove every seeded row before the next test
  in the (`async: false`) module runs — the worker always aggregates "the
  most recently fully-elapsed real hour," so distinct tests would otherwise
  corrupt each other's counts in the same window.
- `backlog_depth` (AT4) is asserted as a DELTA against a freshly-measured
  baseline, not an absolute count — that query is deliberately live/unscoped
  (no `media_id`/time-window filter), so concurrent unrelated `:integration`
  tests may transiently hold their own `:quarantined`/`:scanning` rows.
- LiveView rolling-window tests (AT8/AT9) `DELETE FROM media_scan_stats`
  first to get a fully controlled precondition, since the `ORDER BY
  window_start DESC LIMIT N` reads have no per-test scoping mechanism
  available (unlike `MediaLive`'s `media_id`-scoped queries).

## Residual risk (documented, not blocking)

A narrow (~seconds-wide) flakiness window exists if a test run straddles a
real clock hour boundary between computing `current_target_hour/0` and the
worker's own internal call to the same function — consistent with the
timestamp-based testing tradeoffs this epic already accepts elsewhere (e.g.
`media_released_auto_delete_worker_test.exs`, `media_cleanup_worker_
integration_test.exs`'s backdating approach). Not treated as a MAJOR gap.
