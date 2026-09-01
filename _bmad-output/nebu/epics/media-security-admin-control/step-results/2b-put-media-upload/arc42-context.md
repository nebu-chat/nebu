## Summary

Story 2a introduced `POST /_matrix/media/v1/create`, which reserves an MXC URI and
creates a `media_files` row in state `:reserved` with `uploader_user_id` set. This story
implements the endpoint that actually receives the bytes for that reservation:
`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` (the async-upload companion of
the existing synchronous `PUT /_matrix/media/v3/upload`, Matrix `v1.7`+, fully part of
core spec since `v1.7` — no MSC/unstable-flag handling needed, per the epic's
architecture-preconditions note).

The endpoint validates the incoming PUT against the reservation (ownership, expiry,
current state, payload size) and, on success, runs the received bytes through the
existing storage pipeline (`Nebu.Media.Crypto` + `Nebu.Media.Storage`, AES-256-GCM
directly to S3/MinIO, no local disk step — Review 3 of the epic) with the compression
step from Story 12 (`:zlib.gzip/1` before encryption, never after, per ADR-029), then
persists `storage_key`/`file_hash`/`compressed` in Postgres and transitions the record
from `:reserved` to `:quarantined` via `Nebu.Media.StateMachine` (Story 1b), enqueuing
the async malware scan (Story 4).

This story also establishes the **shared persist-transition-enqueue seam** that Story
2c (synchronous upload) will call into afterwards — the two upload paths must not
duplicate the storage/transition/enqueue logic (per the epic's Story 2c dependency
note: "teilt den Persist-+-Transition-+-Enqueue-Seam").

## Dev Agent Record

### Scope Adaptation (pre-dev, coordinator decision 2026-07-14)

Pipeline dependency research (before ATDD) found the story's own AC2/AC4 depend on
two `media_files` columns that don't exist in any migration (`unused_expires_at`,
`filename`) — a gap this story's own "Do Not Change: migrations" guardrail didn't
anticipate. 2a's code-review had already flagged the `unused_expires_at` half of
this forward as an INFO note. Coordinator resolved the two gaps differently:

- **`unused_expires_at` → workaround, no migration.** Derive it live on every read as
  `row.uploaded_at + unused_expires_ms() < System.system_time(:millisecond)` (same
  config resolver `Nebu.Media.create/1` already uses), never persisted. Rationale:
  unlike 11c's storage-key template (where "compute once, freeze forever" matters
  because changing the derivation later would orphan already-written S3 objects), a
  reservation TTL has no irreversibility concern — recomputing against the current
  config value on every read is safe and arguably more correct (always respects the
  latest policy). **Story 2e's cleanup cron must use this identical formula**, not a
  `WHERE unused_expires_at < NOW()` column read (no such column exists).
- **`filename` → migration added.** No clean workaround exists (overloading the
  `scan_metadata` JSONB column, whose purpose is scan results, would be wrong), and
  this is a genuine oversight in the story's own guardrail rather than a deliberate
  constraint being worked around. Added `server/priv/migrations/000025_media_files_
  filename.{up,down}.sql`: `ALTER TABLE media_files ADD COLUMN filename TEXT;`
  (nullable). No new `GRANT` needed/added — `media_files` is already covered by
  migration `000001`'s blanket `GRANT ... ON ALL TABLES IN SCHEMA public TO
  nebu_app`, and `MigrationsGrantTest`'s `contains_create_table?/1` gate only
  requires a new GRANT block for migrations that `CREATE TABLE`, not `ALTER TABLE`.
- **Minor fix**: story text throughout previously said `row.uploader_id`; the actual
  column/field everywhere in the codebase (DB, `StateMachine.create/1`, test fakes)
  is `uploader_user_id` — corrected throughout this story file's AC3, Technical
  Requirements, and Dependencies sections.

Full research trail: `_bmad-output/nebu/epics/media-security-admin-control/
step-results/2b-put-media-upload/blocker-schema-gap.md`.

### Implementation Notes (dev-story, cycle 0)

Implemented exactly per this story's own (coordinator-corrected) Technical
Requirements — no further design deviations found necessary during dev-story:

- **`Nebu.Media.upload_async/3`** (`server/lib/nebu/media.ex`) — validation
  order exactly as specified: `db_module().lookup_reservation/2` (404) ->
  ownership (403) -> `reservation_expired?/1` derived-live check (404) ->
  state guard (409) -> `mime_denylist_rejected?/1` (400, Story 9c's own
  previously-undocumented call site, now wired) -> size limit (413) -> body
  read -> `store_and_quarantine/7`.
- **`store_and_quarantine/7`** (private, `Nebu.Media`) — the shared
  persist-transition-enqueue seam Story 2c will reuse: SHA-256 over the
  original body -> `Nebu.Media.Storage.compress/1` (Story 12, first real
  caller) -> `Crypto.encrypt/3` -> `Nebu.Media.StorageConfig.compute_key/2`
  (Story 11c, its only sanctioned call site — reads `get().s3_key_prefix_template`
  and `DateTime.utc_now()` at this call site, per 11c's own wiring
  instruction) -> `storage_module().put/2`. **Only on `:ok`** does
  `db_module().persist_upload/1` run, then
  `state_machine_module().transition(media_id, :quarantined, {:system, nil})`,
  then `scan_enqueue_module().enqueue(media_id)`. On S3 failure: `500
  M_UNKNOWN`, row untouched (AC9/ADR-032 — verified by the ADR-032
  consistency test's fail-then-retry assertion).
- **`Nebu.Media.DB.lookup_reservation/2`** and **`persist_upload/1`** added
  (`server/lib/nebu/media/db.ex`) — `lookup_reservation/2` is a plain SELECT
  returning `uploader_user_id`/`state`/`uploaded_at` for ANY state (reuses
  `parse_state/1`, already `@doc false`-public in the same module).
  `persist_upload/1` is a new `UPDATE media_files SET storage_key, file_hash,
  compressed, content_type, filename, aes_key_hex, nonce_hex, file_size
  WHERE media_id = $1` — distinct from `StateMachine.transition/4` per this
  story's own scope-adaptation note (transition/4's only metadata channel is
  the `media_state_transitions` ledger, not the `media_files` row).
- **`Nebu.Media.ScanEnqueue`** (new module, `server/lib/nebu/media/scan_enqueue.ex`)
  — production default for the new `:media_scan_enqueue_module` seam; a
  deliberate no-op (debug-logs the media_id, returns `:ok`) until Story 4b
  introduces Oban. No behavior change to the state machine — `:quarantined`
  rows sit ready for 4b's future worker exactly as designed.
- **Router**: added `put "/v3/upload/:server_name/:media_id"` to
  `server/lib/nebu/web/router/media.ex`, mirroring the existing `put
  "/v3/upload"` route's `@upload_rate_limit`/`RateLimit.call` pattern
  exactly.
- **`unused_expires_at`/`filename` schema gaps**: resolved exactly per the
  Scope Adaptation above (live derivation for expiry, migration `000025` for
  `filename`) — no further schema changes needed during implementation.

**Regression fix (unrelated to this story's own logic, required for a clean
gate):** `server/test/nebu/release_test.exs`'s `list_up_migrations/1` test
hardcodes the full list of expected migration version numbers (`1..24`) —
adding migration `000025` required extending that list to include `25`
(with an explanatory comment mirroring the existing per-migration comment
style in that test file). This is the same "extend the hardcoded migration
list" pattern noted as a general gotcha for any story that adds a migration
in this epic.

**Test results:**
- `mix test test/nebu/media/media_async_upload_test.exs` — 22/22 passed.
- `mix test --warnings-as-errors` (full suite) — 1791 passed, 4 skipped, 452
  excluded, exit 0.
- `mix compile --warnings-as-errors` — clean.

### File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media.ex` | UPDATE — `upload_async/3`, `store_and_quarantine/7`, `reservation_expired?/1`, `validate_and_store_async/4`, `scan_enqueue_module/0` resolver |
| `server/lib/nebu/media/db.ex` | UPDATE — `lookup_reservation/2`, `persist_upload/1` |
| `server/lib/nebu/media/scan_enqueue.ex` | CREATE — no-op scan-enqueue boundary (until Story 4b) |
| `server/lib/nebu/web/router/media.ex` | UPDATE — new `put "/v3/upload/:server_name/:media_id"` route |
| `server/priv/migrations/000025_media_files_filename.up.sql` / `.down.sql` | CREATE — coordinator-approved guardrail exception |
| `server/test/nebu/media/media_async_upload_test.exs` | CREATE/UPDATE — 27 tests (22 ATDD/test-review + 5 code-review cycle 1 fix tests) |
| `server/test/nebu/media/media_fakes.exs` | UPDATE — `MediaFakes.DB.lookup_reservation/2`/`persist_upload/1`, `MediaFakes.StateMachine.transition/4`, `MediaFakes.ScanEnqueue` |
| `server/test/nebu/release_test.exs` | UPDATE — extended hardcoded migration-version list to include `25` |

### Change Log

- 2026-07-14 — Story implemented (dev-story, cycle 0): async-upload endpoint
  wired end-to-end, including 3 previously-standalone dependency wirings
  (9c mime-denylist, 11c compute_key, 12 compress). All 22 story tests +
  full 1791-test unit suite green, warnings-as-errors clean.
- 2026-07-14 — Code-review fix cycle 1 (2 MAJOR + 2 MINOR addressed, coordinator
  decision "fix both"):
  - **MAJOR-1 fixed**: `store_and_quarantine/7`'s `:ok` branch now uses
    `with :ok <- persist_upload(...), {:ok, _} <- transition(...) ... else _
    -> 500` instead of discarding both return values — a persist/transition
    failure after a successful S3 write now surfaces a real 500, never a
    false-success 200. Added 2 tests (persist-fails, transition-fails).
  - **MAJOR-2 fixed**: `validate_and_store_async/4` now checks
    `content_type in @blocked_upload_types` FIRST (mirrors `upload/1`'s own
    ordering), in ADDITION to `mime_denylist_rejected?/1` — closes the
    latent stored-XSS gap where the async route silently accepted
    `image/svg+xml`/`text/html`/etc. that the sync route already blocks.
    Added 2 regression tests (svg, html) mirroring the sync path's existing
    `@blocked_upload_types` test.
  - **MINOR-2 folded in**: empty-body guard added to
    `validate_and_store_async/4` (`{:ok, "", conn} -> 400 M_UNKNOWN`),
    matching `upload/1`'s F3 behavior exactly. 1 test added.
  - **MINOR-1 documented as accepted risk, not fixed here**: the TOCTOU
    race (no row lock between `lookup_reservation/2` and the later writes)
    is noted in a code comment at `upload_async/3` — per coordinator
    decision, Story 2c's shared-pipeline consolidation is the more
    appropriate place to add real serialization across both upload paths.
  - **MINOR-3 — no fix needed** (`persist_upload`'s `media_id`-only
    `WHERE` scope is harmless since `media_id` is the PK, per the
    reviewer's own analysis).
  - Test suite: 27/27 story tests + full 1796-test unit suite green (up
    from 1791 — 5 new tests), warnings-as-errors clean.
