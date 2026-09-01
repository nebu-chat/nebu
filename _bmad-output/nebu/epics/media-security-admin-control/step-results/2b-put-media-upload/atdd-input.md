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

## User Story

As a Matrix client that has reserved an MXC URI via `POST /_matrix/media/v1/create`,
I want to `PUT` my file's bytes to that reservation and have the server validate,
store, and enqueue it for scanning, so that the upload only succeeds once, only for
the user who created the reservation, within the size limit, and the file enters
the quarantine → scan → release pipeline exactly like every other upload.

## Acceptance Criteria

1. **AC1 — `Content-Type` optional (v1.12+):** The handler MUST NOT require a
   `Content-Type` header. When absent, it defaults to `application/octet-stream` —
   matching the existing sync-upload handler's `base_content_type/1` fallback in
   `Nebu.Media`.
2. **AC2 — `filename` query parameter (optional):** When present, `?filename=...` MUST
   be persisted on the `media_files` row and used to derive the `Content-Disposition`
   header on subsequent downloads (same mechanism as the existing `disposition_for/2`
   in `Nebu.Media`, keyed off the persisted filename instead of the media id).
3. **AC3 — `403 M_FORBIDDEN` (ownership):** The PUT MUST come from the same user who
   created the reservation via `/create` (`row.uploader_user_id == conn.assigns.current_user`).
   This check applies **regardless of the row's current state** — even a
   fully-`:released` or `:infected` media id returns 403 for a mismatched user, not 404
   or 409.
4. **AC4 — `404 M_NOT_FOUND` (unknown or expired reservation):** Returned when
   `media_id` does not exist, was not created via `/create` (i.e. no matching row),
   or `unused_expires_at` has already elapsed. **`unused_expires_at` is not a persisted
   column** (2a computes it in-memory only, per its own code-review's forward-flagged
   INFO note) — it is derived live as `row.uploaded_at + unused_expires_ms() < now`
   (same config resolver 2a's `create/1` uses), never read from a row field. The expiry
   check is evaluated **live, in the PUT handler itself** — it must not depend on Story
   2e's cleanup cron having run yet (a request arriving 1ms after expiry, before the
   cron's next tick, must still see 404). Coordinator decision (2026-07-14): recomputing
   this derivation live on every read is safe and preferred over persisting a frozen
   timestamp — an upload-reservation TTL has no "compute once, freeze forever"
   irreversibility concern (unlike e.g. 11c's storage-key template), so it always
   respects the current config value. **Story 2e's cleanup cron must use this identical
   `uploaded_at + unused_expires_ms()` formula, not a `WHERE unused_expires_at < NOW()`
   column read — there is no such column.**
5. **AC5 — `409 M_CANNOT_OVERWRITE_MEDIA` (already uploaded / wrong state):** Returned
   when the row exists, ownership matches, and the reservation has not expired, but
   `state != :reserved`. This is **not idempotent** — a byte-identical retry of a PUT
   that already succeeded (row now `:quarantined` or later) still returns 409, never a
   cached 200.
6. **AC6 — `413 M_TOO_LARGE` (payload size):** Returned when the body exceeds the
   configured max upload size, checked **before** any bytes are written to storage —
   both via an early `Content-Length` pre-check and a running-total check during
   streamed body reads (mirrors `over_content_length?/2` and `read_full_body/3` in the
   existing `Nebu.Media` sync-upload path). This limit is independent of
   `Nebu.Media.ClamAV`'s separate `max_file_size_bytes` scan-skip threshold (Story 3) —
   the two are not the same config value and must not be conflated.
7. **AC7 — Validation order:** Ownership (AC3) and expiry (AC4, folded into the
   404 path) are pure reads and MUST be evaluated **before** the state guard (AC5) is
   evaluated for a state other than `:reserved`, which in turn is evaluated **before**
   the size check (AC6) and body read. Full order: lookup (404 if no row) → ownership
   (403) → expiry (404) → state guard (409) → size limit (413) → body read/store.
8. **AC8 — Happy path storage pipeline:** On a valid PUT to a non-expired,
   caller-owned, `:reserved` row within the size limit:
   - SHA-256 is computed over the **received original bytes**, before compression
     (`file_hash` column, Story 1a).
   - Compression runs per ADR-029: `:zlib.gzip/1` first; the smaller of
     `{gzip output, original}` is what proceeds to encryption; `media_files.compressed`
     records which branch was taken (Story 12's compression module is a dependency of
     this story, not built here).
   - The (possibly compressed) bytes are encrypted with `Nebu.Media.Crypto.encrypt/3`
     (AES-256-GCM) and written via `Nebu.Media.Storage.put/2` to S3/MinIO under the
     object key computed from the currently-active key template (Story 11c; until 11c
     lands, the flat `media_id`-as-key fallback already used by `Nebu.Media.DB` applies
     — this story must not hardcode an assumption that blocks 11c's future template).
   - **Only after the S3 write succeeds**, `storage_key`, `file_hash`, and `compressed`
     are persisted on the `media_files` row **and** the state transitions
     `:reserved → :quarantined` via `Nebu.Media.StateMachine`, in a single logical step
     (see Technical Requirements — ordering rationale, ADR-032).
   - An Oban scan job is enqueued (queue/worker contract owned by Story 4b; this story
     only needs to enqueue a job identifying the `media_id`, not implement the worker).
   - Response: `200 {}` (empty JSON object, per spec — no `content_uri` echo, the
     client already has it from `/create`).
9. **AC9 — Storage-write failure does not corrupt state:** If the S3 write fails, the
   row MUST remain in `:reserved` with `storage_key` still `NULL` — no partial
   transition, no partial `storage_key` write — so the client's retry of the same PUT
   is a normal, valid AC8 attempt, not a 409.

## Acceptance Tests

New test file: `server/test/nebu/media/media_async_upload_test.exs` (ExUnit, follows
the conventions of the existing `media_upload_test.exs` — `Plug.Test`/`Plug.Conn`,
`MediaFakes` boundary swaps via `Application.put_env(:nebu_http, ...)`, assertions on
`conn.status` + `S.json(conn)["errcode"]`).

1. `"PUT .../upload/:server/:media_id happy path → 200 {}, bytes stored, state
   transitions reserved to quarantined, scan job enqueued"` — seeds a `:reserved` row
   via the `MediaFakes.DB`/`StateMachine` fake, PUTs a body as the owning user, asserts:
   `conn.status == 200`, response body is `{}`, the storage fake received
   `{:stored, key, ciphertext}`, the state-machine fake recorded a
   `{:reserved, :quarantined}` transition for the media id, and an Oban job for that
   media id was enqueued (`Oban.Testing.assert_enqueued/2` against the test repo, or
   the injected Oban-enqueue fake if Story 4's worker module does not exist yet at
   review time).
2. `"PUT .../upload happy path → file_hash is SHA-256 of the ORIGINAL bytes, computed
   before compression"` — asserts the persisted `file_hash` matches
   `:crypto.hash(:sha256, original_body)`, not a hash of the compressed/encrypted bytes.
3. `"PUT .../upload happy path → Postgres row and S3 object agree (ADR-032
   consistency): storage_key is only persisted after Storage.put/2 succeeds"` —
   injects a storage-fake that fails once, asserts the row stays `:reserved` with
   `storage_key: nil` and no state-transition record was written; then succeeds on
   retry and asserts the AC8 happy path completes normally.
4. `"PUT .../upload from a DIFFERENT user than the one who created the reservation →
   403 M_FORBIDDEN, regardless of the reservation's current state"` — parameterized
   over `:reserved`, `:quarantined`, `:released`, `:infected` seed states, always 403
   for the mismatched user.
5. `"PUT .../upload with an unknown media_id → 404 M_NOT_FOUND"`.
6. `"PUT .../upload with a media_id whose unused_expires_at has already elapsed → 404
   M_NOT_FOUND, checked live (not dependent on the cleanup cron having run)"`.
7. `"PUT .../upload on a media_id already past :reserved (e.g. :quarantined) → 409
   M_CANNOT_OVERWRITE_MEDIA"`.
8. `"PUT .../upload retried with byte-identical body after a prior 200 success → still
   409 M_CANNOT_OVERWRITE_MEDIA (no idempotency exception)"`.
9. `"PUT .../upload exceeding max_upload_size_bytes (Content-Length pre-check) → 413
   M_TOO_LARGE, nothing stored"`.
10. `"PUT .../upload exceeding max_upload_size_bytes (streamed, no/incorrect
    Content-Length header) → 413 M_TOO_LARGE, nothing stored"`.
11. `"PUT .../upload without a Content-Type header → defaults to
    application/octet-stream, upload still succeeds (v1.12 optionality)"`.
12. `"PUT .../upload with ?filename=report.pdf → filename persisted and later reflected
    in the download handler's Content-Disposition"` (may be a thin integration
    assertion against the persisted row rather than a full download round-trip, if the
    download handler's filename-lookup wiring belongs to a different story slice).
13. `"Validation order: an ownership mismatch (403) is returned even when the
    reservation is ALSO expired, over-size, or in a terminal state"` — asserts 403 wins
    over 404/409/413 when multiple conditions are true simultaneously, per AC7's
    ordering.

## Technical Requirements

### Route

Add to `server/lib/nebu/web/router/media.ex`, alongside the existing `put "/v3/upload"`
route:

```elixir
put "/v3/upload/:server_name/:media_id" do
  conn = Nebu.Web.Plugs.RateLimit.call(conn, @upload_rate_limit)
  if conn.halted, do: conn, else: Media.upload_async(conn, server_name, media_id)
end
```

Reuses the same `@upload_rate_limit` tier as the synchronous route (Go-parity abuse
cap already established) — this endpoint is exactly as expensive per request.
`OidcPlug` already runs for the whole `Nebu.Web.Router.Media` pipeline, so
`conn.assigns.current_user` is available exactly as it is for every other media route.

### Handler — validation order (AC7)

New public function `Nebu.Media.upload_async/3` in `server/lib/nebu/media.ex`:

1. `db_module().lookup_reservation(server_name, media_id)` (new lookup, distinct from
   the existing `lookup/2` used by download/thumbnail — this one must return the
   `:reserved`-capable row including `uploader_user_id`, `state`, `uploaded_at`, even
   for non-`:reserved` states, since AC3/AC5 need to distinguish 403 from 409). On no
   row → 404 `M_NOT_FOUND`. **Note:** the row has no `unused_expires_at` field — expiry
   is derived (see step 3), not looked up.
2. Ownership: `row.uploader_user_id == conn.assigns.current_user` → else 403 `M_FORBIDDEN`.
3. Expiry: derive `row.uploaded_at + unused_expires_ms() < System.system_time(:millisecond)`
   → 404 `M_NOT_FOUND`. There is no persisted `unused_expires_at` column (see AC4) —
   `unused_expires_ms()` is the same private config resolver `Nebu.Media.create/1`
   already uses. Live check, no cron dependency (AC4).
4. State guard: `row.state == :reserved` → else 409 `M_CANNOT_OVERWRITE_MEDIA`.
5. Size limit (AC6): same `max_upload_bytes/0` config resolution as the existing
   sync-upload path — `Application.get_env(:nebu_http, :media_max_upload_bytes,
   @default_max_upload_bytes)`. **Forward-compat note:** Story 9a introduces
   `Nebu.Media.Config` (`media_config` DB table, ADR-027) as the eventual source of
   truth for `max_upload_size_bytes`; this story does **not** depend on 9a and must
   keep reading the existing app-env key so the two stories don't collide — a later
   story rewires `max_upload_bytes/0` to call `Nebu.Media.Config.get/0` with the
   app-env value as its `config.exs` fallback, not the other way around.
6. Body read via the existing chunked `read_full_body/2` pattern (bail as soon as the
   running total exceeds the limit — never buffers past `max_bytes` + one chunk).
7. On a successfully-read, non-empty body: run the shared persist/transition/enqueue
   seam (see below).

### Shared persist-transition-enqueue seam (for Story 2c)

Factor the "hash → compress → encrypt → S3 write → persist + transition → enqueue"
sequence into a single private function, e.g. `store_and_quarantine(row_or_media_id,
server, user, content_type, filename, body)`, callable from both `upload_async/3`
(this story) and — in Story 2c — the existing synchronous `upload/1`. Do not inline
this logic directly in `upload_async/3`'s body if it can't be trivially extracted;
Story 2c's entire scope is "call this same function," so the seam's shape decided here
is load-bearing for that story.

### Storage pipeline invocation (ADR-029, ADR-032)

Ordering inside the seam, and why:

1. Compute `file_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)` —
   over the **original** bytes, before any compression (AC8).
2. Compression (Story 12's module/function — dependency, not built here): gzip the
   body; keep gzip output only if smaller than the original; record which branch was
   taken.
3. Encrypt the (possibly compressed) bytes: `Nebu.Media.Crypto.encrypt/3` — fresh
   32-byte key + 12-byte nonce per file, same as the existing sync path.
4. Compute the storage key from the active key template (Story 11c dependency; flat
   `media_id` fallback until 11c lands, matching `Nebu.Media.DB`'s current
   `storage_key: media_id` placeholder).
5. **Write to S3 first:** `storage_module().put(storage_key, ciphertext)`. Only once
   this returns `:ok` do the next two steps run.
6. Persist `storage_key`, `file_hash`, `compressed`, `content_type`, `filename` (if
   given), key/nonce material, and transition `state: :reserved → :quarantined`
   through `Nebu.Media.StateMachine` (Story 1b's public API — this story does not
   reimplement the state machine, only calls it).
7. Enqueue the Oban scan job (queue/worker name from Story 4b) for the media id.

**Ordering rationale (mirrors ADR-032, in the create direction):** ADR-032 governs
delete-family operations and mandates "mark intent in Postgres before the S3 side-
effect" specifically so a crash never leaves Postgres claiming an object exists that
S3 doesn't have. For a **create**, the equivalent invariant is symmetric but inverted:
the S3 write must complete *before* Postgres claims (via `storage_key` + the
`:quarantined` transition) that stored bytes exist. A crash between step 5 and step 6
leaves the row `:reserved` with `storage_key` still `NULL` — the client simply retries
the PUT (AC9), and the orphaned S3 object (bytes written, but no row points at them
yet) is the same *accepted* failure mode ADR-032 prefers (orphaned blob, swept later)
over the *rejected* one (a DB row that lies about what exists in S3). Do not persist
`storage_key` before confirming the S3 write succeeded, and do not transition the state
before `storage_key` is set in the same logical step.

### Config sources

- `max_upload_size_bytes` → `Application.get_env(:nebu_http, :media_max_upload_bytes,
  @default_max_upload_bytes)` (existing key/pattern, see `Technical Requirements —
  Handler` above).
- Everything else this story touches is either a boundary module read from app env
  (`:media_storage_module`, `:media_db_module`, following the existing seam pattern in
  `Nebu.Media`) or a dependency of Stories 1b/4b/11c/12 that this story calls into but
  does not define.

## Dev Agent Guardrails

### Do Not Change

- `server/priv/migrations/` — the `media_files`/`media_state_transitions` schema is
  Story 1a's scope; this story only reads/writes existing columns, it does not add new
  ones (`file_hash`, `storage_key`, `compressed` already exist per 1a). **Coordinator-
  approved exception (2026-07-14):** a single narrow migration (`000025`) adding
  `media_files.filename TEXT` (nullable) IS in scope for this story — the original
  guardrail was written under the false assumption this column already existed (it does
  not, and AC2 depends on it); no clean workaround exists for filename (unlike
  `unused_expires_at`, which is derived live from `uploaded_at` instead — see AC4). Do
  not add any other columns or touch `media_state_transitions`.
- `Nebu.Media.StateMachine` itself — Story 1b's module. Call its public transition API;
  do not implement guard logic or `media_state_transitions` inserts directly in
  `Nebu.Media`.
- The Oban scan worker itself — Story 4b's scope. This story enqueues a job by
  media id; it does not process scans, call ClamAV, or handle scan results.
- The compression algorithm/module internals — Story 12's scope. This story is a
  *caller* of the compression step, per ADR-029's ordering (gzip before encrypt); do
  not reimplement or second-guess the gzip-vs-original size comparison here.
- The S3 key-template mechanism — Story 11c's scope. Use the flat `media_id` fallback
  key consistent with the current `Nebu.Media.DB` placeholder; do not hardcode a
  template scheme that would need rework when 11c lands.
- `Nebu.Media.Config` / `media_config` table — Story 9a's scope, not a dependency of
  this story. Keep reading `max_upload_size_bytes` from the existing app-env key.
- The existing synchronous `PUT /_matrix/media/v3/upload` route's external behavior —
  only refactor its *internals* to call the newly-extracted shared seam if that
  refactor is trivial and risk-free; the full consolidation (routing both paths through
  one seam end-to-end) is explicitly Story 2c's scope, not this one's.

### ADR-032 consistency ordering — critical

The **S3 write must be confirmed successful before Postgres is updated** with
`storage_key` and the `:reserved → :quarantined` transition. Writing `storage_key`
(or transitioning state) before/without a confirmed S3 write creates exactly the
dangling-reference failure mode ADR-032 identifies as the worse of the two possible
inconsistencies (a DB row claiming bytes exist in S3 that don't) — this would corrupt
every downstream consumer that trusts `storage_key IS NOT NULL` (the download handler,
future storage-usage counters, Story 6b/11b). On any S3 write failure, leave the row
untouched in `:reserved` with `storage_key: NULL` and return a server error to the
client (the client already knows to retry a PUT against an unexpired reservation).

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
