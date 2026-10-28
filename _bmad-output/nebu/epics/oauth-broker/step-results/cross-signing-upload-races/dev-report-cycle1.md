# Dev report, fix cycle 1: story `cross-signing-upload-races`, 2026-10-28

Input: `code-review-findings.md` (0 MAJOR, 4 MINOR) and the security review (APPROVED, 2 LOW, 4 INFO), with the orchestrator decisions 1-6. No commit, no `git add`. The ATDD test files are untouched.

## Changes per decision

1. **F-1 / MINOR-1: the signatures shape is validated in the handler.**
   - Where: `protected.ex` `merge_one_signature/3` + `valid_signatures_shape?/1`.
   - Rule: `signatures` must be a map (absent = `%{}`) and every per-signer value must be a map. Otherwise the answer is `:invalid` (failure entry `M_INVALID_SIGNATURE` in a 200), before ANY store call (device and cross-signing path).
   - New test file `server/test/nebu/matrix/cross_signing_signature_shape_test.exs` (integration, 14 tests):
     - 6 shapes (`null`, string, list, per-signer string, per-signer list, a second signer that is not a map) x {unknown key id, stored matching key id}.
     - Each asserts: 200, the failure entry, row fingerprint unchanged, no `[error]` entry, and neither the key id nor a unique marker from the submitted object in any log entry. Logs are captured at `:debug`; only the existing RequestLogger access/body lines are left out, like the ATDD suite.
     - Plus 2 controls: a valid map merges; an absent `signatures` is a valid empty merge.
2. **MINOR-3 / I-2: `signed_object` is required.**
   - `merge_signatures/4` has no default, the guard is `is_map(signed_object)`, and the `nil` clause of `same_object?/2` is gone, so no `/3` exists.
   - Amended old tests to pass the stored master object:
     - `user_deletion_late_writes_http_test.exs` (3 tests + moduledoc)
     - `sync_token_per_device_store_test.exs` (1 test + moduledoc)
3. **MINOR-2: the overstated "no cycle / harmless" statements are corrected.**
   - Where: store moduledoc (new paragraph "The absent-then-present window"), the `lock_keys/1` @doc, the `put_keys_no_flag/2` comment, the `user_deletion.ex` step 4a comment (also "(deadlock-free)" dropped from its heading), and 08-concepts (the older "cannot deadlock" became "do not deadlock (one narrow exception, below)", plus one sentence after the `lock_keys/1` sentence).
   - Window description: the merge's row lock finds an absent row, a first upload commits the row, an erasure locks that row and waits for the advisory lock, and the merge's write then waits for that row. PostgreSQL resolves the cycle with 40P01: the erasure fails closed, or the merge answers 500. It cannot be closed without advisory-first everywhere.
   - Recorded as accepted residual (1) in the `cq` (g) closure and in a new "Accepted residuals" section at the end of the story.
   - The docs-test pins stayed green, and no pin needed a change. The id line is untouched (SHA pin green).
   - **Correction to the cycle-0 report about MD1.** The redundant row lock in `put_keys_no_flag/2` is a repeat only outside that window. Inside it, the `SELECT ... FOR UPDATE` takes the row lock for the first time. But the upsert would take the same row lock right after, so removing the statement (MD1) does not remove the cycle. MD1 stays equivalent, but the reason "re-entrant, harmless" was wrong for that window.
4. **MINOR-4: stale references fixed.**
   - follow-ups.md row `au`: "**CLOSED by story cross-signing-upload-races (2026-10-28): ...** **Original item:** <original>". Gate cell `non-gating` -> `closed`. The `persist_single` and `compare-and-set` tokens are kept (adr_033_test:933 green).
   - ADR-033: FR16 still says `FOR UPDATE` and now names `lock_keys/1` (formerly `get_keys_for_update/1`); FR20 names `lock_keys/1`. The "Open:" list no longer lists (au); it now says "Closed: persist_single (au), by story ...".
   - 07-deployment: "`persist_single` compare-and-set (au)" removed from the list of open non-gating follow-ups. The orchestrator did not list this one; I did it for consistency, and the adr_033 pins are green.
   - Moduledocs: `user_deletion_lock_order_test.exs:7` names `lock_keys/1`; `user_deletion_late_writes_http_test.exs:9` and `sync_token_per_device_store_test.exs:13` name `merge_signatures/4`.
5. **I-1:** the store comment now says the handler answers M_FORBIDDEN for every user other than the caller, so only the caller's own row is merged and locked. The (g) closure wording is now "the object check (moved from the handler into the store, the submitted object is a required argument) made against the locked object".
6. **F-2:** accepted residual (2) in the (g) closure and the story: no cap on key ids per body; self-contention only; bounded by the 1 MB body limit. INFO-6: no change.

## Test results (fresh `nebu-oauth-pg` before each run)

| Run | Result |
|---|---|
| New + amended suites: `cross_signing_signature_shape`, `cross_signing_upload_races`, `_docs`, rejoin docs, `user_deletion_late_writes_http`, `sync_token_per_device_store`, `adr_033` | 218 passed |
| The 36 related files of cycle 0 except `matrix_client_compat` (which now include the shape test) | **797 passed** (cycle 0: 783, plus 14 new) |
| `matrix_client_compat` alone | 66 passed, 1 excluded |
| `.oauth-ci/unit_nodb.sh` (`--warnings-as-errors`) | first run 6702/6703: `RateLimitTakeAllTest` on_exit `GenServer.stop` race, a known flake in `.oauth-ci/README.md`, no DB, unrelated; re-run **6703 passed, 7 skipped, 0 failures** |

`matrix_client_compat` runs separately because of the known future-timestamp tick flake (see cycle 0).

## Mutants (`mutation-dev-cycle1.txt`; own fresh `mut-cs-pg` per mutant; 66 tests = races DB suite + docs suite + shape suite)

**15 killed, 0 alive. The unmutated baseline is 66/66.**
- **New:**
  - shape validation removed (C1_MS1, 9 failing);
  - per-signer check removed (C1_MS2, 3 failing: the stored-key-id cases);
  - validation bypassed (C1_MS3, 9);
  - object check always true (C1_M09, 2).
  - In MS1, the 3 unknown-key-id cases with a per-signer non-map survive. That is expected: without a matching key the store answers `:not_found` before the deep merge, so they cannot crash even without the check.
- **Re-run against the changed code, all killed:** M01, M02, M08b, M10, M11, M13, M16, M21, M22, M25b, MD2.
- At the end, `mut-cs-pg`, `mut-cs-net` and `nebu-oauth-pg` were removed.

## Files changed in this cycle

- `server/lib/nebu/web/router/protected.ex`
- `server/lib/nebu/matrix/cross_signing_key_store.ex`
- `server/lib/nebu/compliance/user_deletion.ex` (comment only)
- `server/test/nebu/matrix/cross_signing_signature_shape_test.exs` (new)
- `server/test/nebu/compliance/user_deletion_late_writes_http_test.exs`
- `server/test/nebu/matrix/sync_token_per_device_store_test.exs`
- `server/test/nebu/compliance/user_deletion_lock_order_test.exs` (moduledoc only)
- `docs/architecture/08-concepts.md`
- `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`
- `docs/architecture/07-deployment.md`
- `docs/stories/oauth-broker/follow-ups.md` (rows `au`, `cq` (g))
- `docs/stories/oauth-broker/cross-signing-upload-races.md` (residuals section appended)

## Residuals for review

- **Device-key path behaviour change:** the shape validation also applies to the device-key path. A malformed `signatures` value against a matching DEVICE key was a crash before (`deep_merge_sig_map/2` guards) and is now a failure entry. A per-signer `null` used to be tolerated (`|| %{}`) and is now `:invalid`, per the orchestrator rule "any per-signer value not a map".
- **The F-2 cap** is still open, as accepted.
