---
story_id: 2c-sync-upload-shared-pipeline
title: "Async Upload Endpoints: Synchronous Upload via the Shared Pipeline"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

This is a **refactor story, not a new endpoint.** `/_matrix/media/v3/upload` (the
pre-existing, one-shot synchronous upload that predates this epic; **note:** the epic prose
calls this `POST`, but the actual route in `server/lib/nebu/web/router/media.ex` is wired as
`put "/v3/upload"` — this story does not change the HTTP method, it only refactors the handler
body behind it) currently has its own,
hand-rolled storage code path: `Nebu.Media.upload/1` → `store_upload/4` in
`server/lib/nebu/media.ex` inlines `Crypto.encrypt/3` directly, calls the storage boundary's
`.put/2` itself, and persists the row via a bespoke `Nebu.Media.DB.insert/1` SQL statement —
entirely independent of the `media_files` state machine (`Nebu.Media.StateMachine`, Story 1b)
and independent of whatever storage-pipeline function Story 2b introduces for the async
`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` flow (SHA-256 → Gzip → AES-256-GCM →
`Nebu.Media.Storage.put/2`, key-template `storage_key`, per ADR-029).

If sync upload keeps its own parallel implementation, this epic's entire raison d'être —
uniform quarantine → scan → release for **every** byte that enters Nebu, regardless of which
HTTP endpoint received it — has a hole in it. A sync upload today does not create a scannable
`media_files` row in the `:quarantined` state, does not go through `Nebu.Media.StateMachine`,
and would silently bypass the ClamAV scan pipeline (Story 3/4) and the download gate (Story 1c)
that this epic is building for the async path. This story closes that hole: the sync handler is
rewired to call the **same** underlying storage-pipeline function as the async PUT handler
(Story 2b) and the **same** `Nebu.Media.StateMachine` transition used there, so both flows are,
from the scan pipeline's point of view, indistinguishable. The only behavioral difference
between sync and async remains what the epic intends: sync upload lands directly in
`:quarantined` (bytes already present), skipping the `:reserved` state that only applies to the
two-step async flow.

No client-visible behavior changes. This is purely an internal seam consolidation to eliminate
encrypt/compress/S3-write duplication between two HTTP entry points that both end up writing the
same kind of object.

## User Story

As a Nebu operator relying on the malware-scan quarantine process, I want every upload —
whether it arrives via the classic one-shot `POST /_matrix/media/v3/upload` or the newer
two-step async flow — to go through the identical storage and state-machine pipeline, so that
no upload path can accidentally skip encryption, compression, or the scan quarantine gate.

As a Matrix client author who already integrated the classic sync upload endpoint (`PUT
/_matrix/media/v3/upload`), I want its request/response contract to remain byte-for-byte
unchanged, so that this internal refactor requires no client-side changes.

## Acceptance Criteria

1. **AC1 — Row created via `Nebu.Media.StateMachine`, not a separate code path**: The sync
   upload handler no longer calls `Nebu.Media.DB.insert/1` directly to create the `media_files`
   row. Row creation and the initial state transition happen exclusively through
   `Nebu.Media.StateMachine` (the module introduced in Story 1b), matching how the async path
   (Story 2b) creates/transitions its row.
2. **AC2 — Identical storage-pipeline function as 2b**: The sync handler calls the exact same
   storage-pipeline function that Story 2b's PUT handler calls for encrypt+compress+S3-write
   (SHA-256 of the raw received bytes → Gzip → AES-256-GCM → `Nebu.Media.Storage.put/2`, key
   from the Story 11c template). There is no second implementation of this sequence anywhere in
   `Nebu.Media`; `store_upload/4`'s current inline `Crypto.encrypt/3` + direct `storage_module().put/2`
   call is removed and replaced with a call into the shared function.
3. **AC3 — External API contract unchanged**: `PUT /_matrix/media/v3/upload`'s request
   shape (headers, body, `Content-Type` handling, size-limit behavior, blocked-content-type
   list), response shape (`200 {"content_uri": "mxc://<server>/<mediaId>"}`), and all existing
   error responses (`400 M_UNKNOWN`, `401 M_MISSING_TOKEN`/`M_UNKNOWN_TOKEN`,
   `413 M_TOO_LARGE`) are byte-for-byte unchanged. No client-visible regression.
4. **AC4 — Sync upload lands in `:quarantined`, not `:reserved`**: Because bytes are already
   present at request time (unlike the async `/create` step), the sync path's initial
   `Nebu.Media.StateMachine` transition goes straight to `:quarantined` and enqueues the same
   Oban scan job that Story 2b's PUT handler enqueues after a successful upload. The resulting
   row state after a sync upload is equivalent to the state of an async-uploaded row immediately
   after its `PUT` completes (both `:quarantined`, both scan-job-enqueued) — the only difference
   being the sync row never passed through `:reserved`.

## Acceptance Tests

1. **Regression — response contract preserved** (`server/test/nebu/media/media_upload_test.exs`):
   All existing tests in this file MUST continue to pass unmodified after the refactor:
   - `"authenticated PUT upload → 200 with mxc:// content_uri and file stored"`
   - `"PUT upload with NO Bearer token → 401 M_MISSING_TOKEN"`
   - `"PUT upload with a garbage Bearer token → 401 M_UNKNOWN_TOKEN"`
   - `"PUT upload exceeding the configured size limit → 413 M_TOO_LARGE"`
   - `"PUT upload with an EMPTY body → 400 M_UNKNOWN and nothing stored"`
   - `"PUT upload with application/json content-type → empty body rejected, not stored"`

   These tests inject fakes via `:media_storage_module`/`:media_storage_put_fun` — the
   `assert_received {:stored, _key, _stored_bytes}` / `refute_received` assertions on the
   storage boundary must keep passing, confirming the refactored handler still calls the
   storage boundary exactly once per successful upload and zero times on rejected uploads.

2. **New — shared storage-pipeline function is actually shared**
   (`server/test/nebu/media/media_sync_shared_pipeline_test.exs`, new file):
   - `"sync upload and async PUT both invoke Nebu.Media.Storage's put/2 with a Gzip+AES-256-GCM
     payload"` — inject a spy/fake for the shared pipeline function (or for
     `Nebu.Media.Storage.put/2` directly) and assert it is invoked with equivalent
     transformation for both a sync `PUT /_matrix/media/v3/upload` call and an async
     `POST /_matrix/media/v1/create` + `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`
     sequence given the same input bytes — same compression applied, same encryption scheme,
     same key-template shape for `storage_key`.
   - `"sync upload does not call Nebu.Media.DB.insert/1 directly"` — a code-path assertion
     (e.g. asserting the fake `Nebu.Media.DB` module's `insert/1` is never invoked, only
     `Nebu.Media.StateMachine`'s row-creation function is) — guards against a future regression
     re-introducing the duplicated code path.

3. **New — state-transition test**
   (`server/test/nebu/media/media_sync_state_transition_test.exs`, new file):
   - `"sync upload creates a media_files row directly in :quarantined and enqueues a scan job"` —
     asserts the row's `state` column is `:quarantined` immediately after a successful sync
     upload (never `:reserved`), and that a `media_state_transitions` entry exists recording
     the transition (actor_type matching the uploading user, per Story 1b).
   - `"sync-uploaded row's post-upload state is equivalent to an async row's post-PUT state"` —
     drives both flows with equivalent input and asserts both resulting rows are `:quarantined`
     with a scan job enqueued, differing only in that the async row additionally has a
     `:reserved → :quarantined` transition recorded (one extra row in
     `media_state_transitions`) while the sync row has a single transition into `:quarantined`.

## Technical Requirements

### The exact refactor

Today, `Nebu.Media.upload/1` in `server/lib/nebu/media.ex` calls `store_upload/4` (private),
which:

```elixir
defp store_upload(conn, user, content_type, body) do
  server = server_name()
  media_id = generate_media_id()
  key = :crypto.strong_rand_bytes(32)
  nonce = :crypto.strong_rand_bytes(12)
  ciphertext = Crypto.encrypt(body, key, nonce)
  storage_key = media_id

  with :ok <- storage_module().put(storage_key, ciphertext),
       :ok <- insert_media_row(media_id, server, content_type, byte_size(body), key, nonce, user) do
    send_json(conn, 200, %{"content_uri" => "mxc://#{server}/#{media_id}"})
  else
    _ -> error(conn, 500, "M_UNKNOWN", "Failed to store media file")
  end
end
```

This inlines encryption and calls the storage boundary directly, and `insert_media_row/7`
writes to `media_files` via `Nebu.Media.DB.insert/1` — a code path with no notion of `state`,
`:quarantined`, or `Nebu.Media.StateMachine`.

**Required change:** `store_upload/4` must be rewritten to:

1. Compute the SHA-256 of the raw received bytes (`body`), before any compression — matching
   Story 2b's requirement (hash on original bytes, not the compressed/encrypted form).
2. Call the **shared storage-pipeline function** introduced by Story 2b (the function that
   performs Gzip → AES-256-GCM → `Nebu.Media.Storage.put/2` using the Story 11c key template).
   This story does not re-specify that function's signature — it is defined by 2b; this story's
   job is to make the sync handler call it instead of duplicating the encrypt+put sequence
   inline. If 2b's function lives on `Nebu.Media.Storage` (e.g. a `store/2` or
   `encrypt_and_put/2`-shaped function per its own file list), reference that module/function
   directly — do not introduce a second wrapper.
3. Replace the row-creation call: instead of `insert_media_row/7` → `Nebu.Media.DB.insert/1`,
   call into `Nebu.Media.StateMachine` to create the row and land it in `:quarantined` in one
   step (mirroring how 2b's PUT handler transitions `:reserved → :quarantined`, except the sync
   path has no prior `:reserved` row to transition — it creates directly into `:quarantined`;
   confirm with 1b's actual API shape whether this is a single `create_quarantined/1`-style
   function or a `create/1` + `transition/3` pair).
4. Enqueue the same Oban scan job that 2b's PUT handler enqueues, using the same job module/args
   shape.
5. Remove the now-dead `insert_media_row/7` private function and the inline
   `Crypto.encrypt/3`/`storage_module().put/2` calls from `store_upload/4` once the shared path
   is wired in. Do not leave the old code path present-but-unused (dead code invites drift).
6. `Nebu.Media.DB.lookup/2` (used by `download`/`thumbnail`) reads the same `media_files`
   table this story writes into — if Story 1a's migration renames/adds columns
   (`storage_key`, `state`, etc.) that `Nebu.Media.DB`'s `@sql_lookup`/`to_map/1` do not yet
   know about, coordinate with 1a/1c so download keeps working against rows created by both
   the sync and async paths. This story does not own the download-side gating (that is 1c) but
   must not leave the row shape inconsistent between sync- and async-created rows.

### Explicitly out of scope for this story

- The download-side state gate (`:quarantined` → 451, etc.) — that is Story 1c, already landed
  as a dependency.
- The Oban scan worker itself — Story 4b.
- Any change to the async `/create` + PUT flow's own behavior — that is 2b's scope; this story
  only makes the sync path consume 2b's pipeline function, it does not modify 2b's handler.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/media.ex` | UPDATE | `store_upload/4` rewritten to call the shared storage-pipeline function (from 2b) and `Nebu.Media.StateMachine` (from 1b) instead of inline `Crypto.encrypt/3` + `storage_module().put/2` + `insert_media_row/7`; `insert_media_row/7` removed |
| `server/lib/nebu/media/db.ex` | UPDATE (if needed) | Only if 1a's `media_files` schema changes require `@sql_lookup`/`to_map/1` updates to stay consistent with rows created via `Nebu.Media.StateMachine`; coordinate with 1a/1c, do not duplicate state logic here |
| `server/test/nebu/media/media_upload_test.exs` | REGRESSION (no logic change expected) | All existing assertions must keep passing against the refactored handler |
| `server/test/nebu/media/media_sync_shared_pipeline_test.exs` | NEW | Asserts sync and async paths invoke the identical storage-pipeline function |
| `server/test/nebu/media/media_sync_state_transition_test.exs` | NEW | Asserts sync upload lands directly in `:quarantined` via `Nebu.Media.StateMachine` and enqueues a scan job |

## Dev Agent Guardrails

### Do Not Change

- **The external sync-upload API contract.** `PUT /_matrix/media/v3/upload`'s URL (including
  HTTP method — do not change `PUT` to `POST` to match the epic prose; the route as implemented
  is `PUT` and that is what existing clients call), required/
  optional headers, body handling (`Content-Type` defaulting, size-limit enforcement order,
  blocked-content-type list), and response shape (`200 {"content_uri": "mxc://..."}` plus all
  existing error codes/status pairs: `400 M_UNKNOWN`, `401 M_MISSING_TOKEN`, `401
  M_UNKNOWN_TOKEN`, `413 M_TOO_LARGE`) must remain backwards-compatible for existing clients.
  This is a pure internal refactor — if any of `media_upload_test.exs`'s existing assertions
  need to change to make this story pass, the refactor has gone out of scope; stop and
  reconsider the approach instead of "fixing" the test.
- Do not change the `upload` rate-limit tier or its wiring in `Nebu.Web.Router.Media`
  (`@upload_rate_limit`, 600/min burst 5) — unrelated to this story's storage-pipeline scope.
- Do not touch `Nebu.Media.Membership`, `Nebu.Media.SSRF`, `download/4`, `thumbnail/3`, or
  `preview_url/1` in `server/lib/nebu/media.ex` — only `upload/1`/`store_upload/4` and their
  direct helpers are in scope.
- Do not modify Story 2b's PUT handler or its storage-pipeline function signature to
  accommodate the sync path — if the signature genuinely does not fit both callers, that is a
  signal to raise it back to 2b/architecture rather than force a mismatched call shape here.

## Dependencies

- **2b-put-media-upload** — hard dependency. The shared storage-pipeline function
  (encrypt+compress+S3-write) this story reuses is introduced there; this story cannot start
  before it exists.
- **1a — Media State Machine Foundation (migration/schema)** — the `media_files` state column
  and related schema this story's rows must conform to.
- **1b — `Nebu.Media.StateMachine` module** — the module this story's row-creation call must go
  through instead of `Nebu.Media.DB.insert/1`.

## Dev Agent Record

**Implementation summary:**

- Extracted the ONE shared hash → gzip → AES-256-GCM → `Nebu.Media.Storage.put/2` →
  `db_module().persist_upload/1` sequence out of `store_and_quarantine/7` into a new private
  function, `encrypt_compress_and_store/5`, in `server/lib/nebu/media.ex`. Both the sync path
  (`store_upload/4` → `create_and_store/6`) and the async path (`store_and_quarantine/7`, Story
  2b) call this exact function — no second implementation of the sequence exists anywhere in
  `Nebu.Media` (AC2). `store_and_quarantine/7`'s own external behavior/return codes are
  unchanged — only its internals now delegate to the shared function; `state_machine_module()
  .transition/4` (the `:reserved -> :quarantined` move) stays in `store_and_quarantine/7` itself,
  since that transition is specific to the async flow and does not apply to sync.
- Added `Nebu.Media.StateMachine.create_quarantined/1` (`server/lib/nebu/media/state_machine.ex`),
  mirroring `create/1`'s genesis shape (same placeholder `content_type`/`file_size`/`aes_key_hex`/
  `nonce_hex`, same `{:ok, media_id} | {:error, :media_id_taken} | {:error, term()}` contract) but
  inserting directly into `state = 'quarantined'` with a SINGLE genesis
  `media_state_transitions` row (`from_state: NULL, to_state: 'quarantined'`). This is the only
  new function added to `state_machine.ex` — `create/1`, `transition/4`, `allowed?/2`, and
  `allowed_transitions/1` are untouched.
- Rewrote `store_upload/4` to: generate a `media_id` → call
  `state_machine_module().create_quarantined/1` (one-retry-on-collision, mirroring `do_create/3`'s
  existing convention for `create/1`) → call `encrypt_compress_and_store/5` (persists the real
  byte-derived fields — `storage_key`/`file_hash`/`compressed`/`content_type`/`aes_key_hex`/
  `nonce_hex`/`file_size` — onto the row `create_quarantined/1` just created, via the same
  `persist_upload/1` seam 2b's async path already uses) → `scan_enqueue_module().enqueue/1` → 200
  `{"content_uri" => ...}`. `insert_media_row/7` and the old inline `Crypto.encrypt/3` +
  `storage_module().put/2` call are removed entirely — no leftover dead code.
- `upload/1`'s validation order (blocked content-type → size limit → body read → empty-body
  check) and all its error responses are byte-for-byte unchanged (AC3) — only `store_upload/4`'s
  internals changed.
- No changes to `server/lib/nebu/media/db.ex` — `@sql_lookup`/`to_map/1` already handle the
  `:quarantined` state atom (landed in Story 1c/2b) and the row shape created by
  `create_quarantined/1` + `persist_upload/1` is identical to the async path's, so download/
  thumbnail need no changes.

**Deviations from the story's literal Technical Requirements text (both anticipated by the
story's own Dev Notes/CRITICAL DESIGN NOTE, not scope changes):**

- The shared function's name is `encrypt_compress_and_store/5`, not `store/2`/`encrypt_and_put/2`
  as speculatively named in the story text (the story explicitly left naming to the dev agent —
  "This story does not re-specify that function's signature").
- The shared function folds in `persist_upload/1` (not just S3-write), so `create_quarantined/1`
  itself only ever writes the genesis placeholder row (mirroring `create/1` exactly) — the real
  content fields are filled in by the SAME `persist_upload/1` call the async path uses, straight
  after `create_quarantined/1` returns. This keeps `create_quarantined/1`'s contract (and its own
  integration tests, which only ever pass `%{media_id:, server_name:, uploader_user_id:}`) an exact
  mirror of `create/1`, and avoids a second, sync-only variant of the persist step.

**Test results:**
- `mix compile --warnings-as-errors` — clean.
- `mix test` (unit, default exclude `:integration`) — 1800 passed, 4 skipped, 456 excluded, exit 0.
  `test/nebu/media/` alone: 191 passed, 2 skipped, 33 excluded (0 failures) — includes
  `media_upload_test.exs` (7/7, unmodified assertions), `media_async_upload_test.exs` (2b's suite,
  unaffected), `media_create_test.exs`, and the fakes-only portions of
  `media_sync_shared_pipeline_test.exs` / `media_sync_state_transition_test.exs`.
- `mix test --include integration test/nebu/media/` run against a live PostgreSQL (docker compose
  `postgres` service, schema already at migration version 25) via a disposable
  `elixir:1.19-alpine` container on the `nebu_default` network (mirrors the Makefile's
  `test-integration` target) — 226 tests, 0 failures, 2 skipped. This includes the 4
  `@describetag :integration` tests in `media_sync_state_transition_test.exs` that exercise
  `StateMachine.create_quarantined/1` against the real `media_files`/`media_state_transitions`
  tables (exactly one genesis row, `from_state IS NULL, to_state = 'quarantined'`) and the
  contrast test proving `create/1` + `transition/4` produces two rows.

### File List

| File | Change Type |
|---|---|
| `server/lib/nebu/media.ex` | UPDATE — `store_upload/4` rewritten (`create_and_store/6` helper added); new shared `encrypt_compress_and_store/5`; `store_and_quarantine/7` refactored to delegate to it; `insert_media_row/7` removed |
| `server/lib/nebu/media/state_machine.ex` | UPDATE — new `create_quarantined/1` genesis function added alongside `create/1` |
| `server/test/nebu/media/media_sync_shared_pipeline_test.exs` | CREATE (ATDD, unmodified) — now green |
| `server/test/nebu/media/media_sync_state_transition_test.exs` | CREATE (ATDD, unmodified) — now green (unit + integration groups) |
| `server/test/nebu/media/media_fakes.exs` | UPDATE (ATDD, unmodified) — no further changes needed |
| `server/test/nebu/media/media_upload_test.exs` | UPDATE (ATDD, unmodified) — 7/7 passing against the refactored handler |

### Change Log

- 2026-07-14 — Story implemented (dev-story, cycle 0): sync upload (`PUT
  /_matrix/media/v3/upload`) now shares its entire storage pipeline with the async PUT handler
  (Story 2b) via a single `encrypt_compress_and_store/5` function, and creates its `media_files`
  row directly in `:quarantined` via a new `StateMachine.create_quarantined/1` genesis function
  (exactly one `media_state_transitions` row, never composed from `create/1` + `transition/4`).
  All ATDD tests green (fakes-only + live-Postgres integration groups), full 1800-test unit suite
  green, `mix compile --warnings-as-errors` clean.
- 2026-07-14 — code-review cycle 1 fixes: MINOR-1 forward-carry comment added
  (orphaned :quarantined row on failure, deferred to lifecycle/reaper story), MINOR-2 resolved
  (kept `Nebu.Media.DB.insert/1` — option b, documented why: still exercised by the real
  `insert/1` from `test/nebu/media/media_files_state_backfill_test.exs`, an `:integration` test
  that seeds a pre-migration-shaped row to verify the migration's backfill/defaults; removing it
  would have broken that test, which this cycle is not permitted to touch).
