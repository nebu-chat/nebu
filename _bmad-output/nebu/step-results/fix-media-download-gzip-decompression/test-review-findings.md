# Test Review Report — `fix-media-download-gzip-decompression` (bug-fix pipeline, RED phase)

## Scope & Method

Reviewed the single staged test file `server/test/nebu/media/media_download_gzip_decompression_test.exs` (465 lines, 6 tests across 2 ExUnit modules) plus its staged support-file dependencies (`media_test_support.exs`, `media_fakes.exs`, `media_upload_test.exs`). Verified claims against the actual production source (`server/lib/nebu/media.ex`, `server/lib/nebu/media/storage.ex`, `server/lib/nebu/media/db.ex`, routers, migrations) and **actually executed the tests locally** rather than trusting the moduledoc's claims about RED status.

**Executed evidence** (`mix test test/nebu/media/media_download_gzip_decompression_test.exs`):
```
Result: 1/4 passed, 2 excluded
Failed: 3 tests
```
AC1 (both routes) and AC2 fail with the exact "BUG REPRODUCED"/byte-mismatch messages the moduledoc predicts; AC3 passes today (correct — it's a forward-looking regression guard); the 2 `:integration`-tagged AC4 tests are correctly excluded from a DB-less run. Also ran the full `test/nebu/media/` suite: `242/252 passed, 10 failed` — exactly matches the ATDD checklist's claim of 3 new RED tests + 7 pre-existing, unrelated failures in untouched files (`media_upload_verb_test.exs`, `media_sync_shared_pipeline_test.exs`, `media_sync_state_transition_test`). No collateral damage from this change.

## AC Coverage

| AC | Test(s) | Status |
|---|---|---|
| AC1 (download, v1 + legacy alias) | 2 tests | Present, confirmed RED |
| AC2 (thumbnail) | 1 test | Present, confirmed RED, reachability justified against real code |
| AC3 (uncompressed non-regression) | 1 test | Present, confirmed passes today (correct) |
| AC4 (`DB.lookup/2` exposes `:compressed`) | 2 tests, real-Postgres `DBLookupCompressedKeyTest` | Present, statically confirmed will fail |

All 4 ACs have coverage. No gaps.

## Findings

**No MAJOR findings.**

Every AC1/AC2 test does three things in sequence: `assert conn.status == 200`, then `refute conn.resp_body == gzipped` (explicit anti-tautology guard), then `assert conn.resp_body == original` (byte-for-byte equality against the real original). This correctly distinguishes "downloaded bytes equal original" from "any 200 response."

AC4's real-module requirement is honored: calls the real `Nebu.Media.DB.lookup/2` against a real `Nebu.Repo`, not a fake.

### MINOR
1. AC4 integration tests have no `on_exit` cleanup and rely on a compile-time `@run_id` — but this matches an existing sibling test file's established convention. Not requesting rework.
2. AC1's legacy-alias smoke test lacks custom failure messages — cosmetic only.

### INFO
- AC2 doesn't test the legacy thumbnail alias — defensible duplicate-coverage guard, both routes dispatch to the same handler.
- `media_upload_test.exs`'s PUT→POST rename is an unrelated pre-existing compile-blocker fix, not new ATDD work.
- No hard waits, no GenServer involved, no UI surface. Test isolation confirmed sound.

## Bottom line

Tests are well-targeted, non-tautological, and verified to be in the correct RED/GREEN state pre-fix. Safe to proceed to the dev/fix step.
