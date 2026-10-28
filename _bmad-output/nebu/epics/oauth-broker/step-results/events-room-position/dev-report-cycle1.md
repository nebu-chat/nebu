# Dev report: events-room-position, fix cycle 1 (2026-10-26)

Input: `code-review-findings.md` (cycle 0: 0 MAJOR, 4 MINOR). I fixed R1-R4 and the INFO items I2, I3, I5, I6, I7 and I9. Only documentation, comments and one test tag changed: no SQL statement, no `lib/` code. Re-staged with `git add docs proto server`, then `git restore --staged docs/stories/oauth-broker/sync-stream-position.md`. Nothing committed. `follow-ups.md` and `sync-stream-position.md` were not touched.

## Changes per finding

| id | where | change |
|---|---|---|
| R1 | story D6, 000053 up header (new "BULK INSERTS" paragraph), 07-deployment paragraph (*Bulk inserts:*) | A bulk insert of many events of ONE room in ONE transaction or statement is O(n^2): the repeated updates of one `rooms` row cannot be pruned before the commit (about 11 s for 10 000, measured). No current writer does this. A future importer must insert in batches of at most about 1 000 events per room per transaction, committing between batches. It must NOT disable the trigger table-wide. The only safe variant is a session-scoped `session_replication_role = replica` plus explicit stamping (superuser only). |
| R2 | 07-deployment cost sentence; story D6 | Reworded: the holders are the archive / unarchive path and room write transactions. Their hold time is short but not bounded by `lock_timeout`, which only bounds their own waits. The insert itself has no lock timeout and fails only at the 15 s query timeout. |
| R3 | `membership_state_model_docs_test.exs` | Added `@tag timeout: 180_000` with a comment, so the 90 s statement bound is the bound that actually applies. The fixture comment mentions the raised test timeout. No assertion changed. |
| R4 | up header, 07-deployment | Added the 000051-style sentence: run the migration when no long transaction is open on `events` or `rooms`. Its no-op ALTERs and the trigger DDL still need a brief ACCESS EXCLUSIVE lock on both tables, and every new query queues behind it. |
| I2 | story D6 | Names `Nebu.Admin.DB.unarchive_room_atomic/1` and `Room.DB.check_room_status_for_update/1` as the other `FOR UPDATE` paths. Neither inserts an event, so there is no lock-order inversion. |
| I3 | up header | "ON CONFLICT DO NOTHING, or DO UPDATE, which also keeps the old row's room_pos, would still consume one". |
| I5 | 07-deployment (*Rolling deploy:*) | An OLD node's membership change still takes `FOR SHARE`. Two old-node transactions on the same room (only during a Horde handover) can deadlock. This is rare and self-healing: PostgreSQL aborts one side, it rolls back and the client retries. |
| I6 | up header, 07-deployment | "A deadlock abort of the migration is harmless: the whole file rolls back, re-run it." |
| I7 | story D6, 07-deployment | `rooms` is updated once per event. Watch `n_dead_tup` / `n_tup_hot_upd` of `rooms`, and consider `fillfactor` 70-80 if the xmin horizon is held back. |
| I9 | `docs/architecture/05-building-blocks.md` (after the search-vector trigger note) | Three quoted lines: the second trigger is `events_room_pos_trigger` (000053, an ADR-018 exception), with a pointer to the 07-deployment note. |

Not changed: I1, I4, I8 and I10 need no fix. I8 (story 2's down file should check that its own objects are gone, or the release note should say "revert in reverse order") is for story 2 / the coordinator.

## Test evidence

Both runs used the throwaway PG `nebu-oauth-pg`, still at 000053. The up file's SQL statements are unchanged; only its header changed.
- The 4 story files plus `membership_state_model_docs_test.exs` (Elixir 1.20, `--warnings-as-errors --include integration`): `Result: 100 passed` (49 + 51) in 13.5 s.
- Unit job `.oauth-ci/unit_nodb.sh 1.19-alpine` (full suite without a DB, `--warnings-as-errors`): `6593 tests, 0 failures, 7 skipped (4385 excluded)`. This includes every static docs test that reads `07-deployment.md` / `05-building-blocks.md`.

## Notes for the reviewer
- The new 07-deployment text sits inside the same paragraph that the docs test reads as the "000053 note", so the loose pins (ACCESS EXCLUSIVE, maintenance window, the three statements, no-op, indisvalid, down, sync-stream-position) still hold.
- Staged set: 11 files. These are the 10 from cycle 0 (`sync-stream-position.md` is no longer staged) plus `docs/architecture/05-building-blocks.md`. The D6 edits to the story file `events-room-position.md` are staged as well. `pipeline-state.yaml` stays unstaged.
