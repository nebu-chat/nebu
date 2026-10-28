# Dev report, cycle 0: story `cross-signing-upload-races` (follow-up `cq` (g), REQ-2026-007), 2026-10-28

Worktree `open-chat-oauth` (branch feature/migrate-to-oauth2). No commit, no `git add`. The reference diff was used as a guide only. The production change is my own; it differs from the reference in the points listed under "Deviations".

## Files changed

| File | Change |
|---|---|
| `server/lib/nebu/matrix/cross_signing_key_store.ex` | New `lock_keys/1` with `@spec`. Order: row `FOR UPDATE`, then `sync_global\|` advisory lock, then the read. It returns `{:ok, keys}` or `{:error, reason}`, and a decode failure is rescued to `{:error, _}`. **`get_keys_for_update/1` removed** (D-A2). `merge_signatures/4` takes `signed_object` (default `nil`, so the existing `/3` callers in tests still work). It runs ONE transaction: `lock_keys/1`, find by key id in that read, a repeated object check (`same_object?/2`, ignores `signatures`/`unsigned`), deep-merge, then all three columns written from the locked read. A failed read or write rolls back and raises `"cross-signing signature merge failed"` (500). `persist_single/3` removed. **`find_key_object/2` removed** (it was the error-blind pre-check and had no caller left). `put_keys_no_flag/2` is now a plain step inside the merge transaction (`:ok \| :refused \| {:error, _}`, no nested transaction). It still repeats the row and advisory lock statements and keeps the erasure predicate. New moduledoc section, new docs and comments; the "NOT protected here: the MERGE BASE" comment is replaced. No Logger. |
| `server/lib/nebu/web/router/protected.ex` | `do_persist_cross_signing/3` and `replace_with_approval/7` call `CrossSigningKeyStore.lock_keys/1` (first upload still written in the same transaction; branch table, errors and logs unchanged). `merge_cross_signing_signature/4` calls `merge_signatures/4` directly with the submitted object and has no unlocked pre-check (D-A1). Comments updated. |
| `server/lib/nebu/compliance/user_deletion.ex` | Comment only: the step 4a comment names `lock_keys/1` and the order row -> advisory -> read. `lock_user_writers/1` is unchanged. |
| `docs/architecture/08-concepts.md` | In the erasure "*Lock order:*" paragraph, one new sentence after "Those three writers refuse ..." (placed there so "those three writers" still points at the right writers). It names `lock_keys/1` and row -> advisory -> read. The older erasure sentence is kept verbatim. |
| `docs/stories/oauth-broker/follow-ups.md` | Row `cq` (g) now reads `(g) **CLOSED by story cross-signing-upload-races (2026-10-28): ...** **Original item:** <original text verbatim, without the "(g) " label>`, the same style as (f). Items (a)-(f), the status `open, non-gating` and the id line are untouched (byte-identical, the SHA pin is green). No new id. |
| `server/test/nebu/oauth/oauth_account_cross_signing_test.exs` | The amended pin (D-A2): the `get_keys_for_update/1` test is now a `lock_keys/1` test with the same contract (`{:ok, keys}` / all-nil / `{:error, _}` for `"a\0b"`). It also has `refute function_exported?(..., :get_keys_for_update, 1)`. |

The ATDD test files were not modified. `mutation-dev-cycle0.txt` (mutant table) is in this directory.

## Test results

- Fresh `nebu-oauth-pg`, `--warnings-as-errors --include integration`: `cross_signing_upload_races_test.exs` + `cross_signing_upload_races_docs_test.exs` + `sync_rejoin_range_scan_bound_docs_test.exs` gave **61 passed, 0 failures**. All 52 new tests are green.
- Fresh DB, 36 related files together: `cross_signing*`, `user_deletion*`, `oauth_account*`, `signatures_upload`, `sync_token_per_device*`, rejoin and stream docs, `matrix_client_compat`, `oauth_legacy_coexistence`, `safari_account_reset`, `adr_033`, `device_keys`.
  - Combined: 838/849 (seed 559634: 844/849). The failures are all in `SyncTokenPerDeviceHttpTest`, all `:timeout` in `ModerationTestSupport.tick/0`.
  - Cause: `matrix_client_compat_test.exs:2685` inserts an event stamped `tied_ts + 10_000` (10 s in the future), and `tick/0` waits for it. This is the known tick/compat flake family in `.oauth-ci/README.md` and has nothing to do with this change.
  - Proof on fresh DBs, same seed: the 35 files without `matrix_client_compat` gave **783 passed**; `matrix_client_compat` alone gave **66 passed, 1 excluded**; `sync_token_per_device_http_test` alone gave **61 passed**. 783 + 66 = all 849.
- Unit job (`.oauth-ci/unit_nodb.sh`, the full suite without a DB, `--warnings-as-errors`, Elixir 1.20): **6703 passed, 7 skipped, 4732 excluded, 0 failures**.
- At the end `nebu-oauth-pg` was removed again (fresh DB for the next step). I created only `mut-cs-pg` / `mut-cs-net`, and both are removed.

## Mutants (against MY implementation)

Each mutant ran on its own fresh PG (`mut-cs-pg`, never `nebu-oauth-pg`), in a throwaway copy, on the DB suite + docs suite (52 tests). Driver: scratchpad `mut/driver.py`. **26 killed, 3 alive. All 3 are equivalent mutants (explained below).** Baseline unmutated: 52/52.

Killed:
- **lock_keys/1:** no advisory lock (M01, 7 failing), advisory before row (M02, 6), read before the locks (M03, 10), read between the locks (M04, 4), no row lock (M05, 4), SQL failure -> all-nil (M06, 1), decode failure -> all-nil (M27, 3).
- **Merge:** base read BEFORE `lock_keys/1` (M08b, 5), object check dropped (M09, 2), check compares signatures (M10, 4), read failure -> `:not_found` (M11, 1), merge without a transaction (MD2, 5), outer raise -> `:not_found` (M25b, the reference's M25, 2).
- **Erasure guard:** dropped in `put_keys_no_flag` (M13, 1), dropped in `put_keys` (M14, 2).
- **Changed flag:** merge sets `cross_signing_changed` (M15, 1).
- **Upload:** decides on `get_keys/1` (M16, 8), row lock only (M17, 6), read failure -> first upload (M18, 1).
- **Replace path:** reads unlocked (M19, 2).
- **Merge handler:** error-blind pre-check reintroduced (M22, 2).
- **Logging:** handler log line with the supplied keys (M28, 3).
- **Source pin:** decision read in a transaction of its own (MX18, 1).
- **Erasure order:** advisory first (M20, 7), cs before uia (M21, 3).

Alive, all equivalent in this structure:
- **M08:** `get_keys/1` read AFTER `lock_keys/1` inside the same transaction. It reads the same committed state under the held locks, so it is not stale. It is only error-blind, and a failing second read cannot be produced once the first read succeeded. The stale variant (read before the lock, M08b) is killed.
- **M25:** the merge-write `{:error, _}` swallowed as `:not_found` INSIDE the transaction. A failed SQL write aborts the PostgreSQL transaction, so the commit becomes `{:error, :rollback}` and the request still raises (ATDD assumption 4). The outer swallow (M25b) is killed.
- **MD1:** `put_keys_no_flag/2` without its repeated row and advisory lock statements. They are redundant by design ("re-entrant, harmless", D1), because `lock_keys/1` already holds both in the same transaction. They are kept as defence in depth.

Docs/source mutants MX01-MX17 were not re-run: they mutate the docs text and the pins are unchanged. MX18 was re-run (killed).

## Deviations from the story / reference

1. **`get_keys_for_update/1` removed, not delegating.** Both are allowed by D-A2. The ATDD conditional test takes the "removed" branch, and the old pin is amended to `lock_keys/1`.
2. **`find_key_object/2` removed from the store.** It had no caller after D-A1, and keeping it would leave a public error-blind "decide on this" helper. Nothing in `test/` used it.
3. **`put_keys_no_flag/2` has no nested transaction any more.** It returns `:ok | :refused | {:error, _}` to the single merge transaction, which does the rollback and raise in one place, instead of raising from inside a nested transaction. The response is the same (500, message `"cross-signing signature merge failed"`).
4. **`merge_signatures/4`'s `signed_object` defaults to `nil`** (no object check). This keeps the existing direct `/3` callers in `user_deletion_late_writes_http_test.exs` and `sync_token_per_device_store_test.exs` green. The only production caller (the handler) always passes the object.

## Residuals for reviewers / Kassandra

- **Lock cost on misses:** without the pre-check, every `signatures/upload` key id that is not a device key now takes the caller's own row lock and `sync_global|` advisory lock for one short transaction. Cross-user requests are still `M_FORBIDDEN` before the store. This adds one lock statement per key id, bounded by the request body, under the existing rate limits (ATDD gap 3).
- **Partial merge failure:** a raise in the merge, now also on a failed read (OQ2), aborts the whole `signatures/upload` request with a 500. Device-key merges of the same request that were already written stay written. This is the same as for a failed merge write before.
- **OAuth replacement:** still two transactions (D-A3). The write re-reads under `lock_keys/1`.
- **Debug request log:** the existing debug `RequestLogger` prints the redacted request body, including public key objects (ATDD Fix-pass MINOR-2 note). No new log line was added, and no log line in the store or handlers carries key material.
- **Unrelated flake:** the `tick/0` flake (`matrix_client_compat_test.exs` future-stamped event vs `SyncTokenPerDeviceHttpTest`) reproduces when both run in one invocation. It existed before this change; it may be worth a follow-up on the `fj` family.
