# ADR-029: Storage-Key Schema & Compression Ordering

## Status

Accepted - 2026-07-06

Builds on: ADR-013 (MinIO Object Storage), ADR-032 (Persistence Consistency
Postgres ↔ S3). Part of: Epic `media-security-admin-control`, Stories 11 and 12.

## Context

Two related low-level storage decisions needed to be pinned down before Stories 11
(object storage target configuration) and 12 (compression at rest) could be built
consistently: what the S3 object key looks like, and in what order compression and
encryption are applied to the bytes.

## Decision

**Object-key schema:** keys are computed from an admin-configurable template with
placeholders `{media_id}` (mandatory — guarantees uniqueness), `{year}`/`{month}`/`{day}`
(upload date, UTC). There is deliberately **no `{room_id}` placeholder** — `media_files`
has no `room_id` column (see ADR-028's reserved query-time join instead). The key is
computed **once, at upload time**, from whichever template is active at that moment, and
persisted in `media_files.storage_key`. It is never recomputed on read — a later template
change affects only new uploads; existing objects remain findable under their original
key.

**Compression ordering:** `:zlib.gzip/1` runs **before** AES-256-GCM encryption, never
after — compressing already-encrypted (i.e. high-entropy) bytes yields no size benefit.
The smaller of {gzip output, original} is what gets encrypted and stored;
`media_files.compressed` records which branch was taken.

**No new state for archival** (Story 8c): archiving a file to the archive-tier bucket is
a storage-location change, not a lifecycle-state change. It is recorded as an
`archived_at` timestamp while the file remains `:released`.

## Consequences

### Positive
- A single, shared implementation in `Nebu.Media.Storage` handles key computation and
  compression for both the sync and async upload paths — no duplicated logic between
  endpoints (Stories 2b, 2c).
- Template changes are non-destructive: they never orphan already-stored objects.

### Negative / risks
- Because the key is computed once and persisted, a key-template bug discovered after
  significant upload volume cannot be retroactively fixed by simply changing the
  template — existing objects keep whatever key they were given. Accepted: this is the
  same trade-off as any content-addressed or path-templated storage scheme.
- Compression is skipped/reverted for already-compressed formats (most chat attachments:
  photos, videos, PDFs) — expected near-zero benefit there; real benefit is limited to
  text/log/uncompressed-office files (documented in the epic as an explicit
  expectation-setting note, not a defect).

### READ-Path Invariant: Decompression Before Serving

**Critical:** Any file marked `media_files.compressed = true` must be decompressed back to its
original form before being served to a client. The read path (`Nebu.Media.fetch_and_decrypt/3`,
`server/lib/nebu/media.ex`) checks this flag and unconditionally applies `:zlib.gunzip/1` to
the decrypted plaintext when `compressed` is true, rescuing corrupt-gzip errors into a 502
response (`Nebu.Media.safe_maybe_gunzip/2`). This ensures that:
- Clients never receive gzipped bytes mislabeled as the original content type.
- Both `/_matrix/client/v1/media/download` and `/_matrix/media/v3/download` (legacy alias) serve decompressed content.
- Thumbnail routes also apply the same decompression (covered by the shared `fetch_and_decrypt` path).

**Test coverage:** `server/test/nebu/media/media_download_gzip_decompression_test.exs` verifies
round-trip integrity and error handling for corrupted gzip payloads.

## Related

- Epic `media-security-admin-control`, Stories 8c, 11a–11c, 12.
- ADR-013 — MinIO as S3-Compatible Object Store.
- ADR-032 — Persistence Consistency Postgres ↔ S3.
