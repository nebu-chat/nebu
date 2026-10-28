# Dev report: events-room-position, cycle 0 (2026-10-26)

Worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`. Staged with `git add docs proto server`, NOT committed.

## Files changed

| file | change |
|---|---|
| `server/priv/migrations/000053_events_room_position.up.sql` (new) | `rooms.event_pos BIGINT NOT NULL DEFAULT 0`, `events.room_pos BIGINT` (nullable), `CREATE UNIQUE INDEX IF NOT EXISTS events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL`, function `events_assign_room_pos()` (plpgsql, SECURITY INVOKER, D1 statement verbatim), `GRANT EXECUTE ... TO nebu_app`, `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER events_room_pos_trigger BEFORE INSERT ON events FOR EACH ROW`. DDL only, no BEGIN/COMMIT, idempotent. The header follows 000051/000052: story, columns, index, trigger semantics (no gaps; caveat for ON CONFLICT DO NOTHING; FK refusal for an unknown room unchanged), **ADR-018 EXCEPTION** paragraph (OQ1, second trigger after `events_search_vector_trigger`), no backfill and the D3 contract for story 2, OPERATOR NOTE (locks, maintenance window, the 3 manual pre-create statements, idempotence, `pg_index.indisvalid` check with drop and retry), OPERATOR NOTE (rollback: sync-stream-position first), grants. |
| `server/priv/migrations/000053_events_room_position.down.sql` (new) | trigger, then function, then index, then both columns (`IF EXISTS`, no CASCADE). |
| `server/lib/nebu/matrix/room/db.ex` | D2: `apply_member_change/4` now calls the existing `lock_active_room_for_update/1` (`FOR NO KEY UPDATE`, same archived refusal). `refuse_archived_room/1` and `@sql_room_status_for_share` are deleted (they were an exact duplicate apart from the lock mode). The comment above `@sql_room_status_for_no_key_update` now covers all room write transactions and explains why a share lock would deadlock with the trigger. |
| `docs/architecture/07-deployment.md` | one new paragraph right after the Migration 000051 note: "**Per-room event positions, migration 000053 (story events-room-position ...)**": what is added, the trigger semantics, the ADR-018 exception, no backfill, cost (D6), locks, maintenance window, the 3 manual statements, no-op except the trigger, the `indisvalid` hazard (check, drop and retry), rollback (sync-stream-position first). |
| `server/test/nebu/matrix/membership_state_model_docs_test.exs` | **existing test re-pinned deliberately** (Test list item 5), see below. Only the fixture INSERT got `timeout: :timer.seconds(90)` and a comment. No assertion changed. |

The new story test files are unchanged. No change to read paths, `/sync`, the since token or `follow-ups.md`. No new log line (nothing sensitive logged). No new dependency, no GenServer state (the counter is in PostgreSQL), so no crash/restart test is needed. Scenario 3 and the duplicate-id writer test cover the failure case: a writer that rolls back after drawing a position leaves no gap.

## Decisions

- **D2 via the existing helper** instead of switching the share-lock constant: there is now one archived-check helper with one lock mode. `apply_member_change/4`, `apply_power_levels_change/3` and `room_write_transaction/2` all lock the row first and insert last, so the lock-order inventory of D6 holds. `grep` shows no other `FOR SHARE` / `FOR KEY SHARE` on `rooms` in `lib/`.
- Names: function `events_assign_room_pos`, trigger `events_room_pos_trigger`. This sorts after the test's `a00_atdd_hold_*` stimulus trigger, as the ATDD report requires, and the two do not conflict with `events_search_vector_trigger` (different columns).
- `GRANT EXECUTE` is kept for explicitness. The header says that PostgreSQL does not check it when a trigger fires.
- The `indisvalid` hint names the exact query and says to use `DROP INDEX CONCURRENTLY` before retrying step 3.

## Test evidence

Throwaway PG `nebu-oauth-pg` was removed with `docker rm -f` and re-created. The migration ran 000001..000053 (the log shows `applying 000053_events_room_position.up.sql (version 53)`). hex.pm failed intermittently during `mix deps.get` ("Unknown package ... in lockfile"); those runs were simply retried, as in the ATDD report.

- **The 4 story files** (Elixir 1.20, `--warnings-as-errors --include integration`): `Result: 49 passed`, two consecutive runs, and a third run together with the amended docs test: `100 passed` (49 + 51).
- **Unit job** `.oauth-ci/unit_nodb.sh 1.19-alpine` (no DB, `--warnings-as-errors`): compiles clean, `6593 tests, 1 failure, 7 skipped (4385 excluded)`. The one failure is `MemberSliceGateTest` "FIFO order" (`[2, 1, 3, 4, 5, 6]`, a timing test, a known flaky family). The test change was made after this run; it touches only an `:integration` test (excluded in the unit job) and compiles clean under 1.20 `--warnings-as-errors`.
- **Full suite** (1.20, reused DB, `--include integration --warnings-as-errors`, every `*_test.exs` except the parked `regression_sync_load_test.exs`): `10857/10880 passed, 8 skipped, 89 excluded, 23 failed` in 801 s. The failures:
  - `RoomsFallbackNameTest` 12, `TraceMapNodeControlsTest` 3, `WarRoomTest` 1, `TemporaryCaptureManagerTest` 2, `AdminOidcLoginTest` 3, `LogStore.RetentionTest` 1: all known flaky families (`.oauth-ci/README.md`); the ATDD reference run had the same set.
  - `MembershipStateModelDocsTest` "07-deployment (b): the Q-ms SQL ..." 1: **caused by the trigger** (`DBConnection.ConnectionError tcp recv: closed`, the 15 s query timeout). Root cause and fix below. After the fix the file is green (51/51, the test takes about 11 s).
  - No `deadlock detected` / 40P01 anywhere in the log. There is one `membership change was rolled back (postgres 55P03)`, which also appears once in each of the earlier baseline logs (`sw-ci-integration.log`, `hv-ci-integration.log`): it comes from the deliberate lock-bound tests.

### Why an existing test had to be re-pinned (please review)

The Q-ms fixture inserts 10 001 to 20 002 events into each of 4 rooms inside ONE transaction. With the trigger, each insert updates the same `rooms` row. Within one transaction those updates walk the row's growing version chain (the old versions cannot be pruned before the commit), so the cost is roughly quadratic in the number of events per room per transaction. Measured on the same DB: the test alone takes **1.0 s with the trigger disabled and 10.9 s with it enabled**; under full-suite load the INSERT crossed the default 15 s query timeout. The test itself is not wrong. Its bulk fixture is simply far outside production shape: every real writer inserts one or a few events per transaction. The fix is a 90 s timeout on the fixture INSERT plus a comment naming this story. Other bulk fixtures put at most 3000 or 5000 rows into one room and passed unchanged.

## Notes for the reviewer

1. **Runtime consequence worth recording (D6 addendum, not in the story):** a bulk insert of many events into ONE room inside ONE transaction (a future import tool, a data migration that inserts per-room event batches) costs O(n^2) row-version walks on that room's `rooms` row: about 10 s per 10-20k events per room. Normal traffic (one event per statement or transaction) is unaffected. I did not change the story; the owner may want one line in D6, or a follow-up note for any future importer: batch per transaction, or disable the trigger and stamp explicitly.
2. `git add docs` also staged the previously untracked `docs/stories/oauth-broker/sync-stream-position.md` (story 2's file, content unchanged by me) as a side effect of the prescribed command. Unstage it if it should not land with this story.
3. Static pin `refute ~r/FROM rooms[^"]*FOR (KEY )?SHARE/` holds: the share-lock constant is gone, not just unused.
4. Throwaway DB `nebu-oauth-pg` is now at 000053 and polluted with test rows. During the timing measurement the trigger was briefly disabled and then re-enabled (`ALTER TABLE events ENABLE TRIGGER events_room_pos_trigger`), and the later 100-test run confirms it is active. `.oauth-ci/` itself was not touched. Logs are in the session scratchpad (`full.log`, `unit119.log`, `erp4-*.log`, `qms*.log`, `rerun.log`).
