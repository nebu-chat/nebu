## ATDD Summary — 2c-sync-upload-shared-pipeline

**Files created:**
- `server/test/nebu/media/media_sync_shared_pipeline_test.exs` (new)
- `server/test/nebu/media/media_sync_state_transition_test.exs` (new)

**Files edited (test-infrastructure upkeep only, no implementation code):**
- `server/test/nebu/media/media_fakes.exs` — added `Nebu.Web.MediaFakes.DB.insert/1` (spy stub, was previously absent) and `Nebu.Web.MediaFakes.StateMachine.create_quarantined/1` (spy stub for the not-yet-existing seam)
- `server/test/nebu/media/media_upload_test.exs` — pinned `:media_state_machine_module`/`:media_scan_enqueue_module` to the fakes in setup/on_exit, per the story's "IMPORTANT" note, so the file keeps working once the real refactor lands

**New RED tests and their failure reason (confirmed via `mix test`, 187/191 passed overall — the 4 failures below are exactly the new RED tests; nothing else regressed):**

1. `media_sync_shared_pipeline_test.exs`
   - `"sync upload and async PUT both invoke Nebu.Media.Storage's put/2 with a Gzip+AES-256-GCM payload of equivalent (same-length) transformation"` — AssertionError: `byte_size(sync_ciphertext) < byte_size(original_body)` fails (8016 >= 8000) — sync path doesn't gzip yet, still inline `Crypto.encrypt/3`.
   - `"sync upload does not call Nebu.Media.DB.insert/1 directly..."` — AssertionError: `refute_received {:db_insert_called, _row}` fails — `store_upload/4` still calls `insert_media_row/7` → `Nebu.Media.DB.insert/1`.

2. `media_sync_state_transition_test.exs`
   - `"sync upload creates its media_files row directly in :quarantined via create_quarantined/1 (never :reserved) and enqueues a scan job"` — AssertionError: `assert_received {:create_quarantined_called, ...}` times out — handler never calls the state machine at all today.
   - `"sync-uploaded row's post-upload seam shape is equivalent to an async row's post-PUT shape..."` — same cause, `assert_received {:create_quarantined_called, ...}` fails.
   - Plus a `describe "Nebu.Media.StateMachine.create_quarantined/1 (real Postgres)"` block (`@describetag :integration`, excluded from the default run, no live DB) with 4 tests that will RED with `UndefinedFunctionError: Nebu.Media.StateMachine.create_quarantined/1` once run against a live Postgres (`make test-integration`) — targets the CRITICAL DESIGN FINDING seam and asserts the exact single-row `(NULL -> quarantined)` shape, contrasted against a `create/1` + `transition/4` comparison test proving that path produces two rows.

**Regression confirmation:** all 6 pre-existing tests in `media_upload_test.exs`, all of `media_async_upload_test.exs`, and all of `media_create_test.exs` still pass unmodified after the fakes-infra changes.

## Design finding carried forward from Oracle gate (see oracle-context.md)

`Nebu.Media.StateMachine` needs a NEW single-step genesis function (`create_quarantined/1`,
mirroring `create/1`'s shape but `state='quarantined'` with a single `NULL -> quarantined`
audit row) — NOT `create/1` + `transition/4` composed together, because that would produce
TWO transition rows for the sync path, contradicting this story's own Acceptance Test #3
(sync row must have exactly ONE transition row; async row has two). Dev-story must implement
this new StateMachine function.
