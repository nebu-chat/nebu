# Code Review — 8c-media-archive-worker (cycle 0, self-reviewed, no sub-agents per orchestrator instruction)

## Scope reviewed

- `server/lib/nebu/workers/media_archive_worker.ex` (NEW)
- `server/lib/nebu/media/db.ex` (UPDATE: `archived_at`/`storage_key` added to
  `@sql_lookup`/`to_map/1`; `candidates_for_archive/1`, `commit_archived/1` added)
- `server/lib/nebu/media/storage.ex` (UPDATE: `archive_bucket/0`, `put_object_copy/2`,
  `get_from_archive/1` added; `get/1`/`put/2`/`delete/1` unchanged)
- `server/lib/nebu/media.ex` (UPDATE: `fetch_and_decrypt/3` bucket switch)
- `server/lib/nebu/compliance/audit_writer.ex` (UPDATE: `media_archived` allowlisted)
- `server/config/config.exs` (cron entry + `:media_archive` config block)
- `server/config/runtime.exs` (`media_archive_bucket` env var)
- `server/test/nebu/workers/media_archive_worker_test.exs` (NEW, 16 tests)
- `server/test/nebu/media/media_download_gate_test.exs` (+2 tests, AC11)
- `server/test/nebu/media/media_test_support.exs` (`media_row/1` +`:archived_at`)
- `server/test/nebu/media/media_fakes.exs` (`Storage.get_from_archive/1`)

## Deviations from the story's own illustrative text (self-corrected, not escalated)

1. **`Nebu.Media.DB.lookup/2`'s `storage_key` was hardcoded to `media_id`, never
   reading the real column** — a pre-existing bug (present since before this story,
   confirmed via `git blame`-equivalent reasoning: the hardcode predates Story 11c's
   `compute_key/2`) that is silently harmless only under the DEFAULT
   `s3_key_prefix_template` ("{media_id}"). Story 11c's own moduledoc explicitly
   documents "Download (Story 1c) ... reads the already-persisted
   `media_files.storage_key` column" as a load-bearing invariant that was never
   actually true. Fixed in the same change that adds `archived_at` to this exact
   SELECT list/`to_map/1` (already in this story's own scope) — not a scope
   expansion, and required for AC11's bucket switch to read the correct key.
2. **`Storage.delete/1` already exists** (added by Story 8a) — the story's File List
   says to add it; not re-added, the existing function is reused unchanged for
   `archive_delete_from_primary: true`.
3. **Worker's DB access goes through `Nebu.Media.DB`/the `:media_db_module` seam**
   (`candidates_for_archive/1`, `commit_archived/1`), NOT a dedicated
   `:media_archive_repo_module` + raw SQL like Stories 8a/2e's own workers. This
   matches Story 4b's (`MediaScanWorker`) precedent instead, which the story's own
   Acceptance Tests text cites first, and matches the story's Technical
   Requirements' explicit instruction to add these two functions to `Nebu.Media.DB`.
4. **`Enum.reduce_while/3` (2e's halt-on-real-error convention), not `Enum.each/2`
   + per-row `rescue` (8a's swallow-and-continue convention)** — required so a
   failed S3 copy propagates `{:error, reason}` out of `perform/1` (AT8's explicit
   requirement, "the job returns `{:error, _}`, Oban retries") rather than being
   silently absorbed. The two cited worker precedents deliberately differ here;
   this story's own AT8 picks 2e's shape.
5. **The candidate/threshold SQL uses an already-resolved millisecond-epoch
   integer bound directly against `uploaded_at` (`uploaded_at < $1`)**, not the
   story's own illustrative `uploaded_at < NOW() - ($1 || ' days')::interval`.
   Confirmed empirically against the live schema
   (`server/priv/migrations/000001_init.up.sql:298`): `uploaded_at` is `BIGINT`
   (millisecond epoch, written via `System.system_time(:millisecond)` by
   `Nebu.Media.StateMachine.create/1`/`create_quarantined/1`), not a
   `TIMESTAMPTZ` — the story's literal SQL would not type-check. Mirrors Story
   2e's own `now_ms - ttl_ms` convention for the same column.

## Findings

None — 0 MAJOR/CRITICAL/MINOR. Verified directly against a live stack:

- `make redeploy`: server boots cleanly with the new `MediaArchiveWorker` cron
  entry validated by `Oban.Plugins.Cron` at boot (no crash-loop).
- Unit suite (`elixir:1.20-alpine`, `--warnings-as-errors`): 1905 passed, 2
  skipped, 579 excluded, 0 failed — includes all 16 new tests in this story
  (14 worker unit tests + 2 download-gate regression tests), 0 compiler warnings.
- Integration suite (`elixir:1.19-alpine`, `--include integration
  --warnings-as-errors`, fresh stack): 2486 tests, 35 failures, 3 skipped — all
  35 failures are in already-documented pre-existing categories for this epic
  (TraceMap/TraceMapNodeControls(+Contract)/WarRoom/TemporaryCaptureManager/
  ConfigController/SsoLogin/MatrixSso/AdminStaleRooms/LogStore.Retention/
  RegressionSyncLoad, plus the one already-known
  `Nebu.Workers.MediaScanWorkerTest` Agent-teardown flake — file untouched by
  this story, same recurring flake class documented at 4b/2e/5a/8a/6b). 0
  media-archive-related failures. Within the epic's established 18-42 baseline
  failure-count range.
- No new migration (per Dev Agent Guardrails — `archived_at`/`storage_key`
  already existed from Stories 1a/11c); `MigrationsGrantTest`/`release_test.exs`
  therefore untouched, correctly.
- `AuditWriter.@known_actions` allowlist regression test (test 15) confirms
  `"media_archived"` is registered.
- AC9's "never calls `StateMachine.transition`" invariant is pinned by a
  `FakeStateMachine` that `raise`s if ever called (test 14) — a clean run proves
  the worker never reaches it, not merely that no assertion caught it.

security_review: required per story frontmatter → proceeding to Kassandra.

## Addendum (found during Kassandra's security review, same session)

Kassandra found (and I fixed before the report was even finished) a real gap
in `archive_one/1`: the inner `case db().commit_archived(media_id) do` had no
clause for `{:error, reason}` — a genuinely reachable return value of
`Nebu.Media.DB.commit_archived/1`'s own `@spec`. Fixed by adding an explicit
`{:error, _reason} = error -> error` clause, propagating identically to a
copy failure (no audit, no primary delete, job-level error for Oban retry).
Added regression test 8b. Re-verified: unit 1906/0 (elixir 1.20,
warnings-as-errors), integration 2487/27 (elixir 1.19, fresh Postgres, 0
media/archive failures, all pre-existing baseline families +1 known
MediaScanWorkerTest Agent-teardown flake).
