---
story_id: 12-gzip-compression-at-rest
title: "Gzip Compression at Rest (Store-Smaller-of-Two)"
epic: media-security-admin-control
status: done
security_review: not-needed
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
baseline_commit: 74b9d2c94d721359aa4cbdd46b59504c997754f1
---

## Summary

`Nebu.Media.Storage` currently moves opaque, already-encrypted bytes to and from S3/MinIO —
`get/1` and `put/2`, no compression anywhere (confirmed: no `gzip`/`zlib`/`compress` reference
exists anywhere in `server/lib` or `server/test` today). This story adds the one missing piece
of the storage pipeline: compressing the plaintext with `:zlib.gzip/1` **before** it reaches
`Nebu.Media.Crypto.encrypt/3`, per ADR-029's compression-before-encryption ordering, and only
keeping the compressed bytes when they are actually smaller than the original — the
**store-smaller-of-two** strategy.

ADR-029 gives the exact reasoning: compressing already-encrypted bytes is a no-op at best
(encrypted output is high-entropy ciphertext and does not compress), so compression must run
strictly before encryption; there is no CRIME/BREACH-style secret-length-oracle concern to
model here (that class of attack targets a live network responder repeatedly compressing
attacker-influenced *and* secret data in the same stream — a stored media blob compressed once
at upload time, with no attacker-observable timing/size oracle on retrieval, does not fit that
threat shape; the ADR states this explicitly and this story does not need to defend against it).

The counterpart to this story already exists: Story 4b's `Nebu.Workers.MediaScanWorker` ships
with `maybe_gunzip(bytes, compressed)` — `:zlib.gunzip/1` when `row.compressed == true`, a
passthrough otherwise — that already assumes a producer exists upstream. This story **is** that
producer. Per ADR-029's own framing ("a single, shared implementation in `Nebu.Media.Storage`
handles key computation and compression for both the sync and async upload paths"), the new
function lives in `Nebu.Media.Storage`, not a new module, alongside the key-template work of
Story 11.

## User Story

As the Nebu platform storing Matrix media in S3/MinIO,
I want the plaintext bytes gzip-compressed before encryption whenever that actually shrinks
them, and left uncompressed otherwise,
so that text/log/uncompressed-office attachments cost less to store, already-compressed
formats (photos, videos, PDFs) never get bigger or slower to handle, and every file — either
way — round-trips back to byte-identical content for scanning and download.

## Acceptance Criteria

1. **AC1 — New `Nebu.Media.Storage.compress/1`.** `server/lib/nebu/media/storage.ex` gains a
   public function `compress(original :: binary()) :: {binary(), boolean()}` that returns
   `{bytes_to_store, compressed?}`. No new module — ADR-029 explicitly assigns this to
   `Nebu.Media.Storage`, the same module Story 11 extends with key-template computation.
2. **AC2 — `:zlib.gzip/1`, OTP standard library only.** Compression uses `:zlib.gzip/1` exclusively
   — no new dependency (ADR-021, pure Elixir/OTP), no compression-level tuning, no custom
   dictionary or framing options (YAGNI, per the epic's own AC). The call is
   `:zlib.gzip(original)`, nothing more configurable.
3. **AC3 — Store-smaller-of-two, strict comparison.** `compress/1` computes
   `gzipped = :zlib.gzip(original)` and compares `byte_size(gzipped)` against
   `byte_size(original)`:
   - `byte_size(gzipped) < byte_size(original)` → returns `{gzipped, true}`.
   - `byte_size(gzipped) >= byte_size(original)` (gzip framing overhead makes it equal or
     larger — the expected outcome for already-compressed formats like JPEG/MP4, per the
     epic's "ehrliche Erwartungssteuerung" note) → returns `{original, false}`. A tie is treated
     as "not smaller" and keeps the original — never store the gzip variant when it doesn't
     strictly win.
   - Empty input (`original == ""`) is not special-cased: gzip's fixed header/trailer overhead
     means `byte_size(gzipped) > 0 = byte_size(original)`, so it falls out of the same
     `>=` branch as any other non-shrinking input — returns `{"", false}`.
4. **AC4 — Runs strictly before encryption, never after.** The call site is the upload pipeline
   in `Nebu.Media`'s shared persist-transition-enqueue seam (Story 2b's `store_and_quarantine`),
   inserted between step 1 (SHA-256 `file_hash` computed over the **original**, uncompressed
   bytes — already 2b's own ordering, unchanged by this story) and step 3
   (`Nebu.Media.Crypto.encrypt/3`). This story does not touch 2b's file — it only ships the
   `Storage.compress/1` function 2b's own Technical Requirements already document as "Story 12's
   module/function — dependency, not built here." Compression must never run on already-encrypted
   ciphertext; ADR-029's whole rationale collapses if that ordering is ever reversed.
5. **AC5 — `compressed?` is exactly what gets persisted.** The boolean `compress/1` returns is
   the same value the upload seam persists into `media_files.compressed` (column already exists
   per Story 1a, `BOOLEAN NOT NULL DEFAULT false`) — this story does not write to Postgres
   itself, it only produces the value 2b's seam persists.
6. **AC6 — Output is byte-compatible with 4b's `maybe_gunzip/2`, no custom framing.** When
   `compressed? == true`, the stored (pre-encryption) bytes are exactly `:zlib.gzip/1`'s
   standard gzip-format output — nothing wraps, truncates, or re-frames it — so that
   `Nebu.Workers.MediaScanWorker`'s existing `maybe_gunzip(bytes, true) -> :zlib.gunzip(bytes)`
   reconstructs the original plaintext without modification to that worker.
7. **AC7 — No data corruption, either branch, any file type.** For every input — highly
   compressible (text/JSON), incompressible (random bytes), and already-compressed formats
   (JPEG/MP4-shaped high-entropy binary) — the full round trip (`compress` → encrypt → store →
   retrieve → decrypt → `maybe_gunzip` when `compressed? == true`) reproduces the original bytes
   exactly, including for the `compressed? == false` branch where the "compression" step is a
   no-op passthrough.

## Acceptance Tests

New test file `server/test/nebu/media/media_compression_test.exs`
(`Nebu.Media.CompressionTest`, mirrors the plain-module test style of `Crypto`/`Storage`, not
the HTTP-handler `Nebu.Web.Media*Test` style — no `Plug.Conn`/router involved here).

1. `test "compress/1 on a highly-compressible JSON/text payload returns {gzipped, true} and the gzipped bytes are smaller than the original"`.
2. `test "compress/1 on incompressible random bytes returns {original, false} because gzip framing overhead makes the compressed form not smaller"`.
3. `test "compress/1 on an already-compressed-format-shaped payload (high-entropy binary standing in for JPEG/MP4) returns {original, false}, never grows what gets stored"`.
4. `test "compress/1 tie case: byte_size(gzipped) == byte_size(original) returns {original, false}, not the gzip variant"`.
5. `test "compress/1 on empty binary input returns {\"\", false}"`.
6. `test "round-trip byte-identity: compressed branch — :zlib.gunzip/1 applied to compress/1's gzipped output reconstructs the original bytes exactly"` — table-driven over several highly-compressible fixtures (repeated-text blob, JSON fixture, a larger synthetic log file).
7. `test "round-trip byte-identity: uncompressed branch — compress/1's returned bytes for an incompressible input equal the original input exactly, byte for byte"`.
8. `test "integration: Nebu.Workers.MediaScanWorker's maybe_gunzip/2 path correctly decompresses this story's compress/1 output"` — uses `Oban.Testing.perform_job/3` against `Nebu.Workers.MediaScanWorker` (Story 4b, a landed dependency): seeds a `:quarantined` row whose `storage_key` fake resolves to `Nebu.Media.Crypto.encrypt/3` applied to `Storage.compress/1`'s `{gzipped, true}` output, with `row.compressed: true`; asserts the fake `ClamAV.scan_binary/1` receives the exact original, pre-compression bytes — proving `compress/1`'s output is the exact inverse-compatible counterpart of the worker's existing `maybe_gunzip/2`, not just independently correct in isolation.
9. `test "integration: an incompressible upload (compressed: false) reaches ClamAV.scan_binary/1 unchanged, with no gunzip applied"` — same worker-driven setup as test 8, `row.compressed: false`, asserts `maybe_gunzip/2`'s passthrough branch is what actually runs (no accidental `:zlib.gunzip/1` call on non-gzipped bytes, which would raise).

## Technical Requirements

### Call site (exact, in an already-written dependency — Story 2b)

`server/lib/nebu/media.ex`, inside the shared `store_and_quarantine(...)` seam (2b's own
Technical Requirements, "Storage pipeline invocation" steps 1–3):

```elixir
# Step 1 (2b, unchanged by this story): hash the ORIGINAL bytes first.
file_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

# Step 2 (THIS STORY): compress before encrypting — ADR-029 ordering.
{bytes_to_encrypt, compressed?} = Nebu.Media.Storage.compress(body)

# Step 3 (2b, unchanged): encrypt whatever compress/1 decided to keep.
ciphertext = Nebu.Media.Crypto.encrypt(bytes_to_encrypt, key, nonce)
```

This story ships only `Nebu.Media.Storage.compress/1`; it does not modify `media.ex` — that
wiring is 2b's own file, already written to call into "Story 12's module/function" at exactly
this point.

### `Nebu.Media.Storage.compress/1` implementation shape

```elixir
defmodule Nebu.Media.Storage do
  # ...existing get/1, put/2 — opaque-bytes-mover, unchanged...

  @doc """
  Gzips `original` and returns whichever of {gzipped, original} is smaller,
  per ADR-029 (compression before encryption, store-smaller-of-two).
  Returns `{bytes_to_store, compressed?}`.
  """
  @spec compress(binary()) :: {binary(), boolean()}
  def compress(original) do
    gzipped = :zlib.gzip(original)

    if byte_size(gzipped) < byte_size(original) do
      {gzipped, true}
    else
      {original, false}
    end
  end
end
```

### Size-comparison logic

Strict `<`, not `<=` — a tie or a larger gzip output both fall to `{original, false}` (AC3).
No compression-level argument to `:zlib.gzip/1` — the default is used as-is (AC2, YAGNI).

### `compressed` column write

Not this story's concern beyond producing the correct boolean: `media_files.compressed`
already exists (`BOOLEAN NOT NULL DEFAULT false`, Story 1a) and is written by 2b's seam using
exactly the second element of `compress/1`'s return tuple.

### Decompression counterpart (already landed, Story 4b — read-only reference here)

```elixir
# Nebu.Workers.MediaScanWorker, already implemented in Story 4b:
defp maybe_gunzip(bytes, true), do: :zlib.gunzip(bytes)
defp maybe_gunzip(bytes, false), do: bytes
```

`compress/1`'s `true` branch must produce exactly what `:zlib.gunzip/1` expects — standard
gzip-format output from `:zlib.gzip/1`, nothing else — which is automatically satisfied by
calling `:zlib.gzip/1` directly with no wrapping.

## File List

| File | Change Type | Notes |
|---|---|---|
| `server/lib/nebu/media/storage.ex` | UPDATE | Add `compress/1` (AC1–AC3); `get/1`/`put/2` untouched |
| `server/test/nebu/media/media_compression_test.exs` | CREATE | Unit tests (AC1–AC3, AC5) + round-trip tests (AC6–AC7) + integration tests against `Nebu.Workers.MediaScanWorker` (AC6) |

## Dev Agent Guardrails

**Do Not Change:**

- Compression must run strictly **before** encryption, never after — do not add a
  post-encryption compression path anywhere, even experimentally. Compressing ciphertext is a
  no-op at best (high entropy, ADR-029) and reversing the order would silently defeat the whole
  point of this story.
- Do not introduce a different compression format, container, or framing (e.g. zstd, a custom
  header, `:zlib.compress/1`'s raw-deflate variant instead of gzip). The output must be
  byte-compatible with 4b's existing `maybe_gunzip/2`, which calls `:zlib.gunzip/1` — that only
  correctly reverses standard gzip-format output from `:zlib.gzip/1`. Any other format silently
  corrupts every download/scan of a compressed file.
- Do not add compression-level tuning, dictionaries, or other `:zlib` options — default
  `:zlib.gzip/1` only (epic's own AC: "kein Kompressions-Level-Tuning, Default-Level reicht,
  YAGNI").
- Do not modify `Nebu.Workers.MediaScanWorker` or its `maybe_gunzip/2` (Story 4b's scope) — this
  story is the producer side; 4b's consumer side is already correct and is verified here only
  via a read-only integration test, not edited.
- Do not modify `Nebu.Media.Crypto` or the SHA-256 hashing order in `Nebu.Media`'s upload seam
  (Story 2b's scope) — `file_hash` must remain computed over the **original**, pre-compression
  bytes; this story only inserts its own step between the existing hash step and the existing
  encrypt step, it does not move either of them.
- Do not add a new module for this — ADR-029 explicitly assigns compression to
  `Nebu.Media.Storage`, the same module Story 11 extends for key-template computation; keep the
  shared-implementation intent that ADR states ("no duplicated logic between endpoints, Stories
  2b/2c").
- `server/lib/`, `server/test/`, `server/priv/migrations/` are pipeline-protected per
  `CLAUDE.md` — do not hand-apply this story's code outside an active `nebu-pipeline` run.

## Dependencies

- **Depends on:**
  - **1a — `media_files` migration** — provides the `compressed BOOLEAN NOT NULL DEFAULT false`
    column this story's boolean return value is ultimately persisted into (by 2b's seam, not by
    this story directly).
  - **2b — `PUT` async upload endpoint** — the integration point: 2b's already-written
    `store_and_quarantine` seam calls `Nebu.Media.Storage.compress/1` at the exact point
    documented in Technical Requirements above, between its hash step and its encrypt step.
  - **4b — Async scan worker** — this story must stay byte-format-consistent with 4b's existing
    `maybe_gunzip/2` (`:zlib.gunzip/1` on `compressed: true`, passthrough otherwise); this
    story's Acceptance Tests include an integration test that drives `MediaScanWorker` directly
    to prove that consistency, rather than asserting it only in isolation.

## Dev Agent Record

### Implementation

Added `Nebu.Media.Storage.compress/1` in `server/lib/nebu/media/storage.ex`, exactly per the
story's Technical Requirements shape (AC1–AC3, AC6): `:zlib.gzip/1` the input, strict `<`
byte-size comparison, `{gzipped, true}` when strictly smaller, `{original, false}` otherwise
(covers the tie and empty-input cases naturally, no special-casing). `get/1`/`put/2` and the
module's `@moduledoc` were left untouched; no new module was created.

```elixir
@doc """
Gzips `original` and returns whichever of {gzipped, original} is smaller,
per ADR-029 (compression before encryption, store-smaller-of-two).
Returns `{bytes_to_store, compressed?}`.
"""
@spec compress(binary()) :: {binary(), boolean()}
def compress(original) do
  gzipped = :zlib.gzip(original)

  if byte_size(gzipped) < byte_size(original) do
    {gzipped, true}
  else
    {original, false}
  end
end
```

Verified `server/lib/nebu/media.ex` (Story 2b's file) does not yet exist in a form calling
`Storage.compress/1` — 2b has not landed in this tree yet, so no call-site wiring was
touched, per the story's own guardrail.

### Tests

- `server/test/nebu/media/media_compression_test.exs` (pre-staged by ATDD): 7/7 non-skipped
  unit/round-trip tests pass; the 2 tests blocked on Story 4b (`Nebu.Workers.MediaScanWorker`
  / `:oban`) remain `@tag :skip` with their `flunk/1` bodies, untouched.
- Full unit suite: 1636 passed, 4 skipped, 0 failed (baseline before this story's test file was
  1629 passed/2 skipped/0 failed; delta is exactly this story's 7 new green tests + 2 new
  skips). `mix compile --warnings-as-errors` clean.
