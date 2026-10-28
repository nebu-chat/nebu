# Dev report, cycle 0: gdpr-erasure-global-data (follow-up `ck`, REQ-2026-005), 2026-10-27

Worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, HEAD `592cdf13`. Everything staged with `git add docs proto server` (26 files), nothing committed, `_bmad-output` not staged, story status unchanged (`ready`). Throwaway DB `nebu-oauth-pg` was recreated (`docker rm -fv`) and is now at migration 000055.

## 1. What was implemented

Started from `reference-impl.diff` (applied clean), then reviewed every hunk, changed what is listed in section 6, and added one lock-order fix plus its test.

| area | file | change |
|---|---|---|
| erasure | `server/lib/nebu/compliance/user_deletion.ex` | `erased_tables/0` (13 tables, one `@erased_tables` attribute drives both the deleting code and the guard); transaction: in-progress mark, signing key, encryption key, **row locks + `sync_global` advisory lock**, one `DELETE FROM <t> WHERE user_id = $1` per erased table, profile anonymisation (`Deleted User`, avatar NULL), `keys_deleted` + `anonymized_at = COALESCE(anonymized_at, now_ms)`; `{:ok, {:error, reason}}` unwrapped (D14, no `rollback/1`); moduledoc corrected (it claimed Ecto rolls back on a returned `{:error, _}`, which is wrong: it commits) |
| D10 | `account_data_store.ex`, `cross_signing_key_store.ex` | the INSERT became `INSERT ... SELECT ... WHERE NOT EXISTS (users row with deletion_status IS NOT NULL)`; `num_rows == 0` -> `{:error, :user_erased}` (rolls back, returns `{:error, :user_erased}`) |
| D5 | `session/pg_store/postgres.ex` | token upsert is `INSERT ... SELECT ... WHERE EXISTS (SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NULL FOR SHARE) ON CONFLICT ...`; 0 rows -> `{:ok, :skipped}`, cursor write skipped (no FK error), persist answers `:ok`; comments explain why `FOR SHARE` |
| D12 | `event_dispatcher/server.ex` | post-commit teardown also calls `Nebu.Matrix.end_all_user_devices/1` inside `guarded/2`; a returned `{:error, :unavailable}` is now logged as a warning with the reason atom only (the reference swallowed it silently) |
| D11 | `server/priv/migrations/000055_oauth_codes_erasure_delete.{up,down}.sql` | policy only: second branch of `oauth_codes_delete` (correlated `EXISTS` on `users.deletion_status IS NOT NULL`); down restores the 000041 policy; header comments extended (D11, "active user's code stays undeletable", "policy only") |
| docs | 06-runtime, 07-deployment (release note + sweep SQL), 08-concepts (inventory section, limitation (a) removed, new limitation (f)), runbook (step 5 row, verification COUNT queries, sweep section), `follow-ups.md` (`ck` closed in the pinned format with a longer closing text, `cj` (a) note, new row `cn`, id line intact: `unused: gm onward` untouched, `cn` named) | see section 6 for what I added over the reference |
| test (new, mine) | `server/test/nebu/compliance/user_deletion_lock_order_test.exs` | the lock-order proof of section 4 (1 test, integration) |

No staged test was changed. No staged test was wrong.

## 2. D10 decision: DONE here

One added predicate per store, no extra statement (the `sync_global` lock is already taken by the same transaction), no staged test broken, `user_deletion_late_writes_test.exs` kept and green (4 tests). The refusal is `{:error, :user_erased}`; the HTTP handlers already map any `{:error, reason}` to 500 `M_UNKNOWN` and log only the error KIND (`error_kind/1`), so nothing personal is logged (verified in `protected.ex` 1010-1020 and 2893-2905 / 3023-3040). A user without a `users` row stays writable. Also `nextval('sync_global_pos_seq')` is only evaluated for rows that pass the WHERE, so refused writes burn no stream position.

## 3. Inventory verified against the real schema

Method: parsed every `CREATE TABLE` / `ALTER TABLE ... ADD COLUMN` of `server/priv/migrations/*.up.sql` (all 55) for columns matching user / sender / inviter / invitee / `*_by` / actor / requester / approver / author / owner / recipient / creator / uploader / email / display / ip, read the full column lists of every table without a hit (`oauth_authz_requests`, `oauth_account_login_requests`, `bootstrap_draft`, `room_aliases`, `room_defaults`, `media_alerts`, `invalidated_tokens`, `oauth_signing_keys`, `media_scan_stats`, `media_storage_config`, `message_dead_letter`), grepped `server/lib` for writers of every dormant table, and checked the Oban worker args (media ids only). The schema guard test (pg_catalog scan, 11 tests) confirms it on the live DB.

Result: **the story's inventory is complete: the 13 erased tables + `devices` (teardown) and nothing beyond.** Details:
- Per-user tables classified in the story all exist with the stated columns; the 8 tables `push_rules`, `pushers`, `notifications`, `room_account_data`, `admin_sessions`, `message_buffer`, `message_dead_letter`, `role_overrides` have NO writer in `server/lib` (grep over `INSERT INTO|UPDATE|DELETE FROM|FROM|JOIN`), so they are dormant.
- The pre-login flow tables (`oauth_authz_requests`, `oauth_account_login_requests`) carry no user id (state hash, PKCE verifier ciphertext, nonce, binding hash), so they are not per-user.
- `oauth_clients.approved_by / rejected_by / revoked_by / created_from_ip` are admin decisions / registrant IP of a client registration, not user data (already retained in the support list and the docs).
- `oban_jobs.attempted_by` is a node name (the guard's `@not_user_data` list).
- No table has a per-user column that the story missed. Teardown tables (`devices`, `matrix_sessions`, `jwt_device_bindings`, `sessions`, `oauth_idp_refresh_leases`, `sync_tokens`, `sync_room_cursors`) stay as in the story (D12 adds the legacy `devices`).

## 4. Lock-order analysis (erasure vs the two writers vs the D5 guard), and one real deadlock found and fixed

Locks the erasure takes, in order: `users` row (mark_in_progress, `FOR NO KEY UPDATE` level), `user_keys` rows, **now** `uia_sessions` rows and the `cross_signing_keys` row (`FOR UPDATE`), then the advisory lock `sync_global|<user>`, then row locks of the deleted rows, then the `profiles` row, then the `users` row again (already held).

* **`AccountDataStore.put/3`**: advisory lock -> INSERT. Holds nothing else. The D10 predicate is a plain read of `users` (no row lock). No cycle in either direction: if the writer has the lock first, the erasure waits and then deletes what the writer committed; if the erasure has it first, the writer waits and, after the commit, its statement snapshot sees the new status and stores nothing.
* **`CrossSigningKeyStore.put_keys/2` called from the HTTP layer: REAL DEADLOCK in the reference ordering.** `protected.ex` `replace_with_approval/7` runs, in one transaction: `Uia.consume` (UPDATE of the `uia_sessions` row, row lock held to the end) -> `get_keys_for_update/1` (`cross_signing_keys` row `FOR UPDATE`) -> `put_keys/2` (advisory lock). The reference erasure took the advisory lock first and then `DELETE FROM cross_signing_keys` / `uia_sessions`: the erasure waits for a row the writer holds while the writer waits for the advisory lock held by the erasure. PostgreSQL's deadlock detector would abort one of them after `deadlock_timeout` (the erasure fails closed with an attempted audit, or the writer gets a 500); reproduced: with the pre-locks removed my new test fails with `{:error, :rollback}` (the erasure is the victim). (`do_persist_cross_signing`'s first-upload path only locks the `cross_signing_keys` row and then the advisory lock: same order, same fix.)
  Fix: `lock_user_writers/1` first takes `SELECT 1 FROM uia_sessions WHERE user_id = $1 FOR UPDATE` and `SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE`, THEN the advisory lock: the same order as the writer (uia -> cross-signing row -> advisory). The erasure now waits for such a writer's rows without holding the advisory lock, the writer takes the lock, commits, the erasure continues. The step sits after the two key UPDATEs (so the fakes' `"signing"` substring branch, which would also match `cross_signing_keys`, only affects statements after step 3; the staged `:delete_signing` failure test is unaffected). It still satisfies every staged pin (lock before the `account_data` / `cross_signing_keys` DELETEs and before the flip, failing-lock test: the lock is the last statement). Test: `user_deletion_lock_order_test.exs` (a writer holding the uia and cross-signing rows, erasure queued behind it, structural wait proof, both commit). Residual that cannot be fixed on the erasure side: rows INSERTED by a writer that is still uncommitted when the DELETE runs are invisible to it (the late-write window, limitation (f)).
* **D5 persist guard**: the persist transaction's FIRST statement is the token upsert, whose `FOR SHARE` on the `users` row is the only lock it takes before anything else; it holds no `sync_tokens`, advisory or other row lock at that point, and the erasure transaction never touches `sync_tokens` / `sync_room_cursors` (they are deleted post-commit by `destroy_session/1`). So the persist waits for the erasure at most, nothing waits for the persist: no cycle. `FOR SHARE` conflicts with the erasure's non-key `UPDATE` (a `FOR KEY SHARE` would not; mutant-proven by the ATDD suite) and does not conflict with other `FOR SHARE` holders. FK checks of other writers take `FOR KEY SHARE` on the `users` row, which the status UPDATE does not conflict with.
* **Device key writers** (`DeviceKeyStore`): autocommit single statements, no lock chains.
* **Cost note** (documented in the 07 release note): `FOR SHARE` is a row write (tuple header / possible multixact) on the `users` page for every initial sync.
* **Operator sweep (D8)**: plain DELETEs / UPDATEs in one transaction, no advisory lock; a writer for an erased user is refused (D10) so the sweep has no writer to cycle with.

## 5. Verification (all with `.oauth-ci/quick.sh` / `.oauth-ci/unit_nodb.sh`, `--warnings-as-errors`, `--include integration` for DB tests)

* The 10 new/amended files + my lock-order file + migration 000055 test, integration DB: user_deletion_test 25, global_data 33, concurrency 8, schema_guard 11, log 6, sweep 7, late_writes 4, docs 17, migration 9, sync_token_per_device_docs 16 (136 passed in one run), lock_order 1.
* `test/nebu/compliance` + `test/nebu/migration` + `test/nebu/matrix/session` + ALL 32 `*docs_test.exs` + account_data, cross_signing, device_keys, room_account_data (+ hardening), room_tags: 1327 passed (2 of 3 runs; the FIRST run had 1 failure that I did not capture and that did not reproduce in 2 further full runs and 4 more runs of the compliance set, all green, so a load flake outside the erasure area).
* sync_stream_position_{concurrency,dispatcher,http,store}, sync_token_per_device_{dispatcher,http,store}, legacy_logout_per_device, oauth_account_cross_signing, oauth_client_revocation (+ race), oauth_code_store, oauth_device_teardown, oauth_logout, oauth_revoke_semantics: 477 passed.
* Compliance dir + migration 000055 + oauth_logout, 4 consecutive runs: 200 passed each.
* Unit job (no DB, `--warnings-as-errors`), **Elixir 1.19-alpine: 6673 tests, 0 failures** (7 skipped). Elixir 1.20-alpine: 6665 / 6666, the 1 failure is `MemberSliceGateTest` "throughput sanity" (252 reads vs the 60 % bound of 279 under load; it passes alone: 13 passed), the known timing-flake family, unrelated.
* Mutation of my own change: removing the two row pre-locks makes `user_deletion_lock_order_test.exs` fail (erasure aborted by the deadlock detector); restored.
* `python3 .oauth-ci/namelen.py`: ok.

## 6. Deviations from the reference (and why)

1. **Lock order**: pre-locks of `uia_sessions` / `cross_signing_keys` rows before the advisory lock and the placement after the key steps (reference: advisory lock right after the mark, which deadlocks with `replace_with_approval/7`). New test.
2. **D12 teardown step** logs a warning with the reason atom when `end_all_user_devices/1` returns `{:error, :unavailable}` (the reference ignored the return value: a failed legacy-device deletion would have been invisible to the operator).
3. **`user_deletion.ex` documentation**: the moduledoc and an in-code comment claimed that Ecto rolls back when the function returns `{:error, _}`; that is exactly the false assumption behind G4. Both corrected; steps renumbered 4a/4b/4c; `unwrap_transaction/1` as a named private function instead of a rebinding of `tx_result`; comments in the style of the file (why, not what); step 5 notes the `COALESCE` meaning.
4. **`postgres.ex`**: the module comment above the upsert now explains the guard and the `FOR SHARE` choice; the `:skipped` comment also says "or has no `users` row" (behaviour change vs HEAD: a persist for a user id without a `users` row used to fail with an FK error and now skips silently and answers `:ok`; the next request falls back to an initial sync; fail-safe).
5. **Migration header** extended (D11, "active user's code stays undeletable", "policy only: no table, column, index, trigger or grant changes"); statements unchanged.
6. **Docs**: the 07-deployment release note was rewritten (the reference sentence "anonymises the profile and the legacy `devices` rows go with the sessions" was garbled): behaviour change, D10 refusal, the D5 `FOR SHARE` and its cost, migration 000055 (policy only, no table rewrite), rollback warning (with the old policy `DELETE FROM oauth_codes` silently deletes 0 unexpired rows, so revert code and migration together), rolling-deploy note (run the sweep after every node is on the new image), sweep. 08-concepts: the lock order sentence, `{:error, :user_erased}`, and a new limitation (f). `ck` row: the closing text also names D10, D12, migration 000055 and the residual (f). Reference docs otherwise kept (sweep SQL identical in 07 and the runbook, as the sweep test requires).
7. Everything else of the reference was kept after review (the `INSERT ... SELECT` form with explicit casts in the stores, the `:skipped` plumbing, the policy, the sweep).

## 7. Follow-up rows recorded

* `cn` (new, free id, id line updated, `unused: gm onward` intact): the documented `DELETE /api/v1/admin/users/{userId}` GDPR pipeline is not implemented in the Elixir server; the runbook still describes the old gateway steps; only the sentences that became wrong through this story were fixed.
* `ck` closed in the pinned format (`**CLOSED by story gdpr-erasure-global-data (2026-10-27): ...** ORIGINAL TEXT: ...`, status `closed`).
* `cj` (a): note that the erasure part is closed (D5); logout / device-deletion race stays the accepted residual.
* NO row for the residual "an in-flight request of the erased user can still write rows of tables without a guard (device keys, read receipts, profile, ...)": there is no free follow-up id left (the story's own analysis found `cn` the only free one), so it is recorded as limitation (f) in 08-concepts and in the `ck` closing text. The owner may want a row with a new id scheme if the window matters (tokens are dead after the teardown, window = one request, the sweep is re-runnable).

## 8. Notes for the next steps

* Code review: look at `lock_user_writers/1` (three statements, the comment explaining the order), the `INSERT ... SELECT WHERE NOT EXISTS` forms, and `unwrap_transaction/1`.
* The DB-error path of the erasure still audits `error: ":rollback"` (Postgrex fails the commit of an aborted transaction), so the attempted-audit does not carry the original error: pre-existing behaviour, unchanged, and arguably privacy-positive (D7).
* Security review: new SQL is parameterised; the only interpolated identifiers are the compile-time table names of `@erased_tables`; the policy of 000055 is correlated to the row's user and cannot delete an active user's code (test: the runtime role cannot, a `deletion_in_progress` user's code can).
* The throwaway DB `nebu-oauth-pg` holds rows of the test runs (random ids); `.oauth-ci/cleanup.sh` resets it.
