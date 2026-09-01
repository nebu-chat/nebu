# ATDD Summary — 4b-media-scan-worker

## Grounding corrections applied (verified against live tree, not the story's stale sketch)

- AC1/AC2 (Oban dep/schema/supervisor) already landed via Story 2e (a2498fda) — remaining
  work is only adding `media_scan: [limit: 10]` to the existing `queues:` list in config.exs.
- All app-env seams use `:nebu_http` namespace, not `:nebu`.
- Real enqueue call site is `Nebu.Media.ScanEnqueue.enqueue/1` (the `:media_scan_enqueue_module`
  seam already wired into `Nebu.Media`) — dev-story swaps its body for a real `Oban.insert/1`.
- `Nebu.Media.Crypto.decrypt/3` has no seam — worker calls it directly; `aes_key_hex`/`nonce_hex`
  are hex strings requiring `Base.decode16!/2` before use.
- Broadcast contract confirmed from real `download_stall.ex` code: topic `"media:#{media_id}"` on
  `Nebu.PubSub`, payload `{:media_state_transition, media_id, new_state}`.

## New/changed test files

- `server/test/nebu/workers/media_scan_worker_test.exs` (NEW) — 8 tests covering Acceptance
  Tests 1-8 (clean/infected/retry-then-clean/exhausted-retry-discard/all-three-broadcast/
  file_too_large-skip/no-op-invalid-transition/decrypt-decompress-order). Test-private
  Agent-backed fakes (FakeStateMachine/FakeClamAV/FakeDB/FakeStorage wrapper) mirroring
  `media_reserved_upload_cleanup_worker_test.exs`'s convention. All 8 RED: "Expected worker to
  be a module that implements the Oban.Worker behaviour" (module doesn't exist yet) — correct
  RED reason, confirmed via `mix test --exclude integration`.
- `server/test/nebu/media/scan_enqueue_test.exs` (NEW) — 1 real-Postgres integration test
  proving `ScanEnqueue.enqueue/1` inserts a real Oban job (`:media_scan` queue,
  `Nebu.Workers.MediaScanWorker`, `%{"media_id" => id}` args). Tagged `:integration`.
- `server/test/nebu/media/media_compression_test.exs` (MODIFIED) — un-skipped the 2
  `@tag :skip`/`flunk` tests left by Story 12, now real `Oban.Testing.perform_job/3`-driven
  round-trip tests against `Nebu.Workers.MediaScanWorker` + `Storage.compress/1`. Module
  changed `async: true` -> `async: false` (mixing pure + DB-backed tests); both new tests
  tagged `:integration`. Existing 7 pure-function tests confirmed still green.
- `server/test/nebu/media/media_fakes.exs` (MODIFIED) — added `DB.lookup_for_scan/1`,
  `DB.update_scan_metadata/2`, and a new `ClamAV` fake module (`:media_clamav_module` seam,
  the first seam introduced for ClamAV in this codebase).

## Verification run (mix test --exclude integration, these 3 files only)

`15 tests, 8 failures (3 excluded)` — 7 compression pure-function tests pass (no regression),
8 new worker tests fail for the correct RED reason, 3 new integration tests correctly excluded
from the fast unit run.

## Still needed in dev-story

- `Nebu.Workers.MediaScanWorker` (new module, `server/lib/nebu/workers/media_scan_worker.ex`)
- `Nebu.Media.DB.lookup_for_scan/1` + `update_scan_metadata/2` (production implementations)
- `Nebu.Media.ScanEnqueue.enqueue/1` — swap no-op body for real `Oban.insert/1`
- `config/config.exs` — add `media_scan: [limit: 10]` to the existing `queues:` list
- No new migration, no new mix.exs dep, no new supervisor child (all done by 2e).
