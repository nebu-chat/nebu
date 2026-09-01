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
