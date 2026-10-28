# ATDD report: story `cross-signing-upload-races` (follow-up `cq` (g), REQ-2026-007)

Worktree `open-chat-oauth` (branch feature/migrate-to-oauth2). No commit, no `git add`. `server/lib`, `server/priv/migrations`, `follow-ups.md` untouched.
Tests run only through `.oauth-ci/quick.sh` (premise code) and the throwaway copy `ref-cross-signing` with its own PG `atdd-cs-pg` (reference implementation + mutants).

## Files

| File | Tests | Premise code (today) | Reference impl |
|---|---|---|---|
| `server/test/nebu/matrix/cross_signing_upload_races_test.exs` (real DB, `@moduletag :integration`, `async: false`) | 37 | 19 red / 18 green pins | 37 green |
| `server/test/nebu/matrix/cross_signing_upload_races_docs_test.exs` (static, no DB) | 12 | 8 red / 4 green pins | 12 green |
| `server/test/nebu/matrix/sync_rejoin_range_scan_bound_docs_test.exs` (AMENDED, see below) | unchanged count | green | green |

Total new: 49 tests, 27 red, 22 green pins. Red set identical in two consecutive runs; reference implementation green 5 of 5 runs (DB file). Longest test name incl. describe: 184 chars (`namelen.py` clean, 0 compile warnings with `--include integration`).
Of the 19 red DB tests, 11 are behaviour-level through the HTTP handlers (no new function needed) and 8 are store-level tests of `lock_keys/1` (called through `apply/3`, so the file compiles before the function exists).

Amended older pin (deliberate, necessary): `sync_rejoin_range_scan_bound_docs_test.exs` pinned the item text `"(g) pre-existing first cross-signing upload race ..."` inside row `cq`. After the closure the row reads `(g) **CLOSED ...** **Original item:** pre-existing ...`, so the pin lost its `"(g) "` prefix (comment in the test). Without this edit that suite would fail as soon as the story closes (g).

## Technique

Barrier pattern of `user_deletion_lock_order_test.exs`: a holder session takes the `sync_global|<user>` advisory lock (or a row lock), the racers (HTTP requests via `T.device_signing_upload` / `keys/signatures/upload`, or the real `UserDeletion.delete_user_keys/3`) are started in Tasks, the test polls `pg_stat_activity` + `pg_blocking_pids` until every racer is blocked, then releases. No fixed sleep decides anything. I use a local `await_blocked!/3` with a RECURSIVE blocking chain: `E.await_blocked!/3` only follows two levels, and a row-lock queue is a chain (second updater waits for the first waiter, which waits for the holder: three levels with the erasure). Changed_pos draws are counted with `sync_global_pos_seq.last_value`.
Failing-read fault: `REVOKE SELECT` on `cross_signing_keys` and re-`GRANT SELECT (user_id, self_signing_key_json, user_signing_key_json)`, so the row lock (`FOR UPDATE`, needs UPDATE + `user_id`) and the advisory lock work and only the READ fails; plus an undecodable row (`master_key_json = 'not json'`: SQL succeeds, decode fails). Restored in `on_exit`.

## Scenario to test map

(`cross_signing_upload_races_test.exs` unless noted; R = red on premise code, G = green pin)

**Scenario 1, two concurrent first uploads (describe "scenario 1")**
- identical keys on two devices: both 200, ONE changed_pos draw (premise: 3 draws) R
- different keys, legacy callers: one 200, other 403 M_FORBIDDEN, stored = winner's (premise: both 200) R
- different keys, OAuth callers: one 200, other 401 m.oauth challenge, one pending uia row (premise: both 200) R
- NULL-master row is still a first upload, a stored master never is (non-goal) G
- store level, describe "lock_keys/1": exists/1 R; no row waits for the advisory lock then `{:ok, all-nil}` R; read AFTER the advisory lock sees the previous holder's commit R; row lock BEFORE advisory (1/2: waits for the row without holding the advisory lock; 2/2: waits for the advisory lock already holding the row, `FOR UPDATE NOWAIT` probe) R x2; `get_keys_for_update/1`, if kept, delegates (waits for the advisory lock too) R (vacuous if the dev removes it)

**Scenario 2, merge vs reset (describe "scenario 2")**
- reset of the self-signing key vs master signature, emulated reset tx (row lock, then `put_keys/2`) and real approved OAuth request: reset's keys stay, master signed R x2
- reset REPLACES the signed master: stored = reset's keys unsigned; emulated: failure entry `M_INVALID_SIGNATURE`; OAuth variant: either order is valid (the request decides in tx1, writes in tx2) so only the invariant is asserted R x2
- reset keeps the key id but changes the object: nothing stored for the stale object, failure entry (kills "object check dropped") R
- two concurrent merges (different signatures) both survive (lost update today) R
- plain merge adds the signature, keeps the other keys, moves neither `cross_signing_changed` nor `changed_pos`, draws no position G
- a different submitted object writes nothing, failure entry G

**Scenario 3, erasure guard (describe "scenario 3")** all G (the guard exists today)
- REAL erasure holds its locks (stalled on a locked `account_data` row), a first upload and a merge wait: 403 M_USER_DEACTIVATED, failure entry, no row
- first upload of a status-set user with a NULL-master row: 403, row fingerprint unchanged
- merge into stored keys of a status-set user: failure entry, row untouched

**Scenario 4, no deadlock (describe "scenario 4")**
- for kind in upload / merge / replace: writer queued on the advisory lock BEFORE the erasure starts: both finish (kills advisory-before-row in `lock_keys/1`). upload R (premise: the idempotent decision never waits for the advisory lock), merge G, replace G
- for kind in upload / merge / replace: erasure queued BEFORE the writer: both finish (kills a flipped `lock_user_writers/1`) G x3
- simulated writer in the documented order (uia row, cs row, advisory, read) G; simulated writer holding only the uia row, taking the cs row after the erasure queued (kills cs-before-uia in the erasure; a uia row must exist) G
- four operations (idempotent upload, merge, approved replacement, erasure) of one user released from a barrier, four rounds: all finish, none 5xx, no "deadlock" in the log G (probabilistic detector, the deterministic tests above carry the guarantee)
- docs file: `lock_user_writers/1` source order uia -> cs -> advisory G

**Scenario 5, failed read (describe "scenario 5")**
- upload of a user with stored keys (column fault): 500 M_UNKNOWN for identical and different keys, row fingerprint unchanged, no key material in the log G
- first upload of a user without a row: 500, no row created G
- merge (column fault): 500 or raise (the server answers 500), nothing stored, no key material (keys, key ids, signature) in the log R (premise: 200 with a failure entry)
- undecodable row: upload 500, nothing overwritten G; merge 500/raise, nothing stored G; `lock_keys/1` returns `{:error, _}` and the transaction stays usable R
- docs file: store has no `Logger.` call G; every log line of the cross-signing handlers interpolates only `error_kind(reason)` / `inspect(e.__struct__)` G

**Docs / source pins (`cross_signing_upload_races_docs_test.exs`)** R unless marked: (g) closure marker with date and status stays `open, non-gating`; original text verbatim after `**Original item:**`; closure names `lock_keys/1`, the order, first upload, INFO-3, merge base, 500, erasure, `persist_single/3`; items (a)-(f) intact and in order (the closed (f) sits behind (c)); `cq` one row, id line byte-identical (2680 bytes, same SHA-256 as the rejoin suite) G; 08-concepts "Lock order" paragraph names `lock_keys/1` and row -> advisory -> read and keeps the older erasure sentence; store defines `lock_keys/1` with a spec, moduledoc names it, "NOT protected here: the MERGE BASE" gone; step 4a comment in `user_deletion.ex` names `lock_keys/1` and the order; handlers (`do_persist_cross_signing/3`, `replace_with_approval/7`) call `lock_keys/1`, no `get_keys_for_update`, no unlocked `get_keys`.

## Reference implementation (throwaway, `reference-impl.diff`, never in `server/lib`)

`CrossSigningKeyStore.lock_keys/1` (row `FOR UPDATE`, advisory lock, then read; `{:error, _}` for any failure), `get_keys_for_update/1` delegates, `merge_signatures/4` (one transaction: `lock_keys/1`, find by key id in that read, repeated object check, merge, write all three columns), `persist_single/3` removed, handlers use `lock_keys/1`, early `find_key_object/2` pre-check REMOVED from the merge handler (see gap 3), comments/moduledoc, step 4a comment, 08-concepts sentence, `cq` (g) closure. The suites that touch it (oauth_account_cross_signing, oauth_account_review, oauth_account, compliance, signatures_upload, cross_signing, sync_token_per_device, rejoin/stream docs, client compat): 552 passed.

## Mutants

`mutation-results.txt`: 42 mutants (25 code, 17 docs/comment), 42 killed, 0 alive. Notable: advisory lock removed, advisory-before-row, read before the locks / between them, merge base read outside the transaction, repeated object check dropped, erasure guard dropped (merge and first upload separately), failed read swallowed (upload as first upload, merge as `:not_found`, `lock_keys` as all-nil, also for a decode failure), flipped erasure lock order (advisory first; cs before uia), replace path unlocked, upload on a row-lock-only read, merge setting the changed flag, log lines with key material. M11/M18 were ALIVE in the first batch (see assumption 4) and killed by the undecodable-row tests.

## Assumptions

1. Merge entry point: the tests drive the merge only through `POST /keys/signatures/upload`, never `merge_signatures/N`, so the dev is free to choose the successor signature (the ref impl uses `merge_signatures/4` with the submitted object; `/3` kept compatible).
2. `lock_keys/1` is public, arity 1, `{:ok, keys} | {:error, reason}`, called inside a transaction (the store tests wrap it in `Nebu.Repo.transaction/1`).
3. The in-process router re-raises a handler exception (no Cowboy), so the merge failure test accepts "500, or a raised `Plug.Conn.WrapperError`" (the server answers 500 for a raise); D5 itself says raise.
4. A SQL failure aborts the PostgreSQL transaction, so a swallowed read error in the same transaction still ends in a 500: the column-fault tests alone could not tell "error-aware" from "swallowed". Hence the undecodable-row tests (SQL succeeds, decode fails).
5. changed_pos draw counting reads `sync_global_pos_seq.last_value` around the race; nothing else draws from it in these tests (`async: false`). An upsert that conflicts draws twice (INSERT arm + DO UPDATE arm): premise shows 3 draws for two first uploads, the fix 1.
6. Scenario 3/4 use the real erasure; the "erasure holds its locks" state is produced by a held row lock on a LATER step (`account_data` rows are deleted after the locks of step 4a). The erased user's in-flight requests are authenticated before the erasure (legacy session primed with `whoami`, same technique as `user_deletion_late_writes_http_test.exs`).

## Questions and gaps found in the story

1. **Older docs pin breaks on closure** (fixed in this step, see above): `sync_rejoin_range_scan_bound_docs_test.exs` pinned the `(g) pre-existing ...` item text.
2. **`oauth_account_cross_signing_test.exs` lines 621-636** pin `get_keys_for_update/1` (exported; `{:ok, all-nil}` for an unknown user inside a transaction; `{:error, _}` for `"a\0b"` OUTSIDE a transaction). OQ3 allows "removed or delegates": if the dev REMOVES it, that test must be amended deliberately; delegating keeps it green (the ref impl delegates, 552 green).
3. **The early `find_key_object/2` pre-check contradicts scenario 5.** D4 says it "may stay as a cheap pre-check", but `find_key_object/2` reads with the error-blind `get_keys/1`: a failed read becomes "no key" and answers a failure entry of a 200 (reproduced with mutant M22) instead of the 500 that D5 and scenario 5 demand. The pre-check must go (the ref impl calls the locked merge directly) or become error-aware. Side effect to weigh for Kassandra: without the pre-check every cross-signing-miss key id (a device key is handled before) takes the row + advisory lock of the caller's own user (cross-user is `M_FORBIDDEN` before the store).
4. **The OAuth replacement is two transactions** (`do_persist_cross_signing/3` decides, `replace_with_approval/7` writes): with D2 the decision transaction holds row + advisory lock and commits BEFORE the write transaction, so another writer can run between them (the merge may even run between and then be overwritten by the reset). Premise 2 ("the replacement path is not racy") stays true because `replace_with_approval/7` re-reads under the lock, but the reset-vs-merge OAuth test can only assert the order-independent invariant. If a strictly atomic decide-and-replace was intended, the story should say so (it is not required by the scenarios).
5. **D4 also closes merge vs merge** (two concurrent merges lose one signature today). The story names only merge vs reset; I added a test (it is red today) because the cause is the same stale base. Worth a sentence in the story / follow-up closure.
6. **D7 "every scenario must FAIL on the current code" cannot hold literally**: scenario 3 (erasure guard) and the upload half of scenario 5 pin behaviour that is already correct (the upload read failure is already a 500; the erasure guard exists), and most of scenario 4 guards the ORDER against future mutations (it can only fail on a mutant). They are marked as pins. Reds exist for scenario 1, 2, the merge half of 5 and the idempotent-upload half of 4.
7. D3 (`replace_with_approval/7` on `lock_keys/1`) is not behaviourally observable (no live race, as the premise says); it is pinned by a source pin (no `get_keys_for_update` / unlocked `get_keys` in the two handlers) and by mutant M19 (also killed behaviourally in the OAuth reset test).
8. Log rule: the tests capture at the default test level (`:warning`). The debug request logger (`request_logger.ex`) logs a redacted request body; whether `PayloadRedactor` redacts cross-signing key objects was not examined (out of scope, D5 is about new lines).
9. The scenario 4 stress test is a probabilistic detector (it killed the cs-before-uia mutant once before the deterministic uia-row test existed); the deterministic tests are the guarantee.
10. After this step: `docker rm -fv nebu-oauth-pg` was run (fresh DB for the next run), `atdd-cs-pg` / `atdd-cs-net` removed.

## Fix pass (test review: 0 MAJOR, 9 MINOR, 8 INFO), 2026-10-28

Only the two new test files changed (plus this report, `mutation-results.txt`, `reference-impl.diff` unchanged in content: the reference implementation did not need a change). `oauth_account_cross_signing_test.exs` NOT touched (the dev amends it, D-A2).

**New totals: 52 tests, 29 red / 23 green pins on the premise code** (DB file 39: 20 red / 19 green; docs file 13: 9 red / 4 green). Same red set in two consecutive runs on a fresh `nebu-oauth-pg`. Reference implementation: 52/52 green in 4 runs (fresh DB, then the same DB 3 times; 0 compile warnings). Longest name 184 chars. **Mutants: 45, all killed** (27 code, 18 docs/source; was 42; new M28, M29, MX18).

| Finding | Applied |
|---|---|
| MINOR-1 | both requests of the scenario 5 upload pin run inside one capture (`status!/1` on the second answer too) |
| MINOR-2 | `capture_debug/1` (Logger level :debug + `capture_log(level: :debug)`, restored after) in the three log checks. Consequence: the existing `RequestLogger` prints the redacted request body of EVERY route at :debug, including the public key objects of an upload (existing infrastructure, not a new line). `refute_material!/2` therefore skips exactly those entries (`[status: ...]` / `{"status":...}` access and debug lines) and checks everything else (handler lines, crash reports). Worth a one-line note for Kassandra: key objects appear in the debug request log. New mutants M28/M29 (an INFO-level log line with the supplied keys / the key id) are caught only by the debug capture |
| MINOR-3 | `on_exit(&restore_master_read!/0)` registered first; REVOKE+GRANT in ONE `DO` block (atomic); `restore_master_read!/0` idempotent and also run in `setup_all`; `setup_all` asserts `current_database()` matches `nebu` / `nebu_test` / `nebu_ci` and refuses otherwise (the compose and CI databases are all named `nebu`, so the name check is only a coarse guard; the real protection is the atomic fault plus the restore in `setup_all`/`on_exit`) |
| MINOR-4 | docs test "do_persist_cross_signing/3: lock_keys and the first-upload put_keys sit in the SAME single Nebu.Repo.transaction fun" (exactly one `Nebu.Repo.transaction(`, `lock_keys(` before `put_keys(` inside its fun, comments ignored); mutant MX18 (the read in a transaction of its own) KILLED. A REAL split is racy to provoke, so MX18 is a source-level mutant; recorded in `mutation-results.txt` |
| MINOR-5 | `:first_upload` kind (fresh OAuth user WITHOUT a `cross_signing_keys` row) added to the scenario 4 matrix, both queue orders against the erasure (2 more DB tests, green pins on the premise code) |
| MINOR-6 | the `get_keys_for_update/1` test is an explicit conditional: present -> must delegate (waits for the advisory lock); removed -> `refute function_exported?` after asserting `lock_keys/1` exists (a removal without a replacement fails). Not silently vacuous any more |
| MINOR-7 | undecodable-row merge test: `{:raised, reason}` requires `Exception.message(reason) =~ "merge failed"`. Consequence: this test is now RED on the premise code (it crashes with a Jason decode error from the unlocked read), and green on the reference implementation |
| MINOR-8 | `seq/0` = `CASE WHEN is_called THEN last_value ELSE 0 END` everywhere |
| MINOR-9 | loosened: `function_source/2` takes a regex head (parameter names free), `lock_keys(` is matched as `\block_keys\(` (alias/import fine), `def lock_keys\(\w+\)` and `@spec lock_keys(.*) ::` instead of exact text, the `get_keys_for_update` / unlocked `get_keys(` refutes read the code with comment lines dropped. Kept: the contract (the handlers must not decide on a row-only or unlocked read; one transaction; the id-line SHA pin, which stays intentionally brittle: a later story that takes a follow-up id must amend this suite and the rejoin suite) |
| INFO-1 | `assert_lock_keys_defined!/0` (module loaded and `function_exported?(Store, :lock_keys, 1)`) in `lock_keys_task/1` and the two direct `lock_keys` tests, so the red store tests fail with "CrossSigningKeyStore.lock_keys/1 does not exist yet" instead of the misleading "did not wait for it" |
| INFO-3 | `mint_uia_row!/1` asserts `uia_count == 0` before and `== 1` after `Uia.mint_session/3`; the first simulated writer now also locks a real uia row |

INFO-2, 4-8 not applied (accepted as informational; INFO-2 is covered by the emulated variant, INFO-4/6 are non-goals).
Containers: `atdd-cs-pg` / `atdd-cs-net` and the shared `nebu-oauth-pg` removed again at the end (fresh DB for the next run).
