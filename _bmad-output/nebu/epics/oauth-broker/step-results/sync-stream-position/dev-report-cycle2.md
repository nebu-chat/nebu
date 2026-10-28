# Dev report: sync-stream-position, fix cycle 2 (2026-10-27, docs / tests only)

Input: `code-review-delta-cycle1.md` (0 MAJOR, 2 MINOR, 5 INFO). No production code changed. Staged with `git add docs proto server` (39 files), not committed, step-results not staged, story `status` still `ready`, the security report untouched.

## Fixed

| finding | change |
|---|---|
| MINOR-1 (CHECK constraints unpinned) | `server/test/nebu/migration/000054_sync_room_cursors_test.exs`: new integration test "class and prev_class accept only the three partition classes (a check violation otherwise); prev_class NULL is allowed". Valid pairs (`join`/NULL, `invite`/`leave`, `leave`/`invite`, `join`/`join`) insert; `bogus`, `none`, `JOIN` as `class` and `bogus` as `prev_class` each raise `Postgrex.Error` with `postgres.code == :check_violation`. The moduledoc "Not pinned" list no longer names the CHECK (now pinned; constraint names stay unpinned). No convergence DDL added: 000054 was never released and the throwaway DB already runs the CHECK version (as decided by the coordinator). |
| MINOR-2 (D4 / 06-runtime wording) | Story D4: "never part of a position range" + a fix-cycle-1 sentence: the range read applies to a joined room WITH a cursor row; a joined room WITHOUT one is read as an initial-sync room (segment-driven newest-20 page up to the head, `room_pos <= head OR room_pos IS NULL`, legacy events included, ts order), `limited` / `prev_batch` as D5. `06-runtime.md` and the `/sync` row of `matrix-api-scope.md`: the same case named. Checked before editing: no `*docs_test.exs` pins "exact range", "never part of an incremental range" or "never read incrementally". |
| INFO-5 (stale test title) | `event_dispatcher/sync_membership_partition_test.exs`: "... is unresolved: no error, the anchor is kept, ..." -> "... its cursor is kept (none), ..."; also the second anchor-vocabulary title in that file ("a row-only invitation does not move the anchor: ... the previous anchor is kept" -> "a row-only invitation is remembered by its cursor row (class invite) and never becomes the last event id", matching its amended assertions). |
| INFO-1..4 | no action (as instructed; INFO-4 concerns the security report, not touched). |

## Test evidence

- Migration file + `event_dispatcher/sync_membership_partition_test.exs` + every `*docs_test.exs` (Elixir 1.20, `--warnings-as-errors --include integration`, `nebu-oauth-pg`): **565/565**.
- Unit job (`.oauth-ci/unit_nodb.sh 1.19-alpine`): 6625 tests, 2 failures, 7 skipped, 4509 excluded (the new CHECK test is integration-tagged: +1 excluded). The 2 failures are timing tests unrelated to this docs/tests-only cycle: `MemberSliceGateTest` "simultaneous readers ... FIFO order within the deadline" and `Nebu.Web.Plugs.RateLimitTest` "injectable clock drives refill"; both files green on rerun (13/13, 4/4). No compile warning.
