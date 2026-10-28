# Dev report, fix cycle 2: story `cross-signing-upload-races`, 2026-10-28

Input: the cycle 1 delta reviews, with 1 MINOR from the code review (MINOR-A) and 1 LOW from Kassandra (D-1). No commit, no `git add`. The ATDD test files are untouched.

## (a) Kassandra D-1: a malformed STORED `signatures` value no longer crashes the merge

- **`server/lib/nebu/matrix/cross_signing_key_store.ex` `deep_merge_signatures/2`.** It now merges `signature_map(stored)` with `signature_map(new)`.
  - `signature_map/1` keeps only the per-signer entries that are maps.
  - Anything that is not a map is treated as an empty map, so the old `old_map || %{}` pattern that let a binary through is gone.
  - The result is always a map of maps. A malformed stored part is dropped, so the row is "healed" by the merge.
- **`server/lib/nebu/web/router/protected.ex` `deep_merge_sig_map/2` (device-key path).** Same rule, through `sig_map/1`.
- **No change to the uploads.** `device_signing/upload` and `keys/upload` still store `signatures` as submitted; no new validation, no API change.
- **New tests**, in `server/test/nebu/matrix/cross_signing_signature_shape_test.exs` (extended, +6; longest name about 150 characters):
  - `master_key` / `self_signing_key` x stored `signatures` `"x"` / `{"@me": "x"}`. Each is stored through the user's own first upload, and the precondition asserts that the malformed value really is stored.
  - Device key x the same two shapes. Each is stored through `/keys/upload`, which stores it as is (precondition asserted).
  - Each test then sends a well-shaped `signatures/upload` with the matching object and asserts:
    - a 200 with `failures: %{}`;
    - the stored signatures equal exactly the new map (clean merge);
    - no `[error]` entry;
    - no key id, stored marker, new signature value or public key in any log entry captured at `:debug` (only the existing RequestLogger access/body lines are left out, as in the other suites).

## (b) Code review MINOR-A: the upload has the same window

- **The wrong sentence is replaced.** "The upload has no second row lock, so it is not affected." was removed from the store moduledoc. The replacement says:
  - A first upload has the same window when its row lock found no row and a row with a NULL master (a partial upload, e.g. only a self-signing key) is committed before it gets the advisory lock.
  - Its read then sees no master, so its `put_keys/2` upsert takes the row lock only after the advisory lock (advisory -> row) against an erasure that holds the row.
  - PostgreSQL resolves it the same way (`40P01`: the erasure fails closed, or the upload answers 500). This is pre-existing and accepted.
  - A row that already exists when `lock_keys/1` runs is held from the start, and a committed row WITH a master leads to no write, so neither case opens the window.
- **The other places did not make the false claim**, but they described the window for the merge only. Each now gets one sentence on the partial first upload:
  - 08-concepts (the "exception" sentence);
  - the `cq` (g) closure, residual (1);
  - the story's "Accepted residuals";
  - the `user_deletion.ex` step 4a comment.
- The docs-test pins are green, and the id line is byte-identical (SHA pin).

## Test results (fresh `nebu-oauth-pg` before each run)

| Run | Result |
|---|---|
| `cross_signing_signature_shape` + `cross_signing_upload_races` + `_docs` | 72 passed |
| The related files of cycles 0/1 without `matrix_client_compat` (now including the extended shape suite) | **803 passed** (cycle 1: 797, plus 6 new) |
| `matrix_client_compat` alone (separate because of the known tick flake) | 66 passed, 1 excluded |
| `.oauth-ci/unit_nodb.sh` (`--warnings-as-errors`) | **6703 passed, 7 skipped, 0 failures** |

## Mutants (`mutation-dev-cycle2.txt`; own fresh `mut-cs-pg` per mutant; 72 tests)

| Mutant | Change | Result |
|---|---|---|
| C2_MT1 | the store merge back to the old `Map.merge(Map.get(obj, "signatures", %{}), …, old_map \|\| %{})` | **killed**, 4 failing: both cross-signing keys x both shapes |
| C2_MT2 | the device-key merge back to the old behaviour | **killed**, 1 failing: device key, per-signer string |
| C1_MS1 | shape validation removed (re-run) | **killed**, 9 failing |
| baseline | unmutated | 72/72 |

For C2_MT2, the device `"x"` case passes even on the old code. That is correct: the old code already returned the new map when the stored value was not a map, so that case never crashed.

At the end, `mut-cs-pg`, `mut-cs-net` and `nebu-oauth-pg` were removed.

## Files changed in this cycle

- `server/lib/nebu/matrix/cross_signing_key_store.ex`
- `server/lib/nebu/web/router/protected.ex`
- `server/lib/nebu/compliance/user_deletion.ex` (comment only)
- `server/test/nebu/matrix/cross_signing_signature_shape_test.exs`
- `docs/architecture/08-concepts.md`
- `docs/stories/oauth-broker/follow-ups.md` (`cq` (g) residual (1))
- `docs/stories/oauth-broker/cross-signing-upload-races.md` (residuals)

## Residual for review

- **Malformed stored signatures persist until a merge.** The uploads still store a malformed `signatures` value as submitted (decided: no API change), so `/keys/query` serves it back as stored until the next merge drops it. It is public data of the user's own key and has no crash path any more.
