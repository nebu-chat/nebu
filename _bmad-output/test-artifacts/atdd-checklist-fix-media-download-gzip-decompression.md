---
stepsCompleted: ['step-01-preflight-and-context', 'step-02-generation-mode', 'step-03-test-strategy', 'step-04-generate-tests', 'step-05-validate-and-complete']
lastStep: 'step-05-validate-and-complete'
lastSaved: '2026-08-26'
storyId: 'fix-media-download-gzip-decompression'
storyKey: 'fix-media-download-gzip-decompression'
storyFile: null
atddChecklistPath: '_bmad-output/test-artifacts/atdd-checklist-fix-media-download-gzip-decompression.md'
generatedTestFiles:
  - 'server/test/nebu/media/media_download_gzip_decompression_test.exs'
inputDocuments:
  - 'server/lib/nebu/media/storage.ex'
  - 'server/lib/nebu/media.ex'
  - 'server/lib/nebu/media/db.ex'
  - 'server/priv/migrations/000022_media_state_machine_foundation.up.sql'
  - 'server/lib/nebu/web/router/media.ex'
  - 'server/lib/nebu/web/router/client_v1_media.ex'
  - 'server/test/nebu/media/media_download_test.exs'
  - 'server/test/nebu/media/media_thumbnail_test.exs'
  - 'server/test/nebu/media/media_client_v1_routes_test.exs'
  - 'server/test/nebu/media/media_compression_test.exs'
  - 'server/test/nebu/media/media_db_lookup_for_scan_test.exs'
  - 'server/test/nebu/media/media_test_support.exs'
  - 'server/test/nebu/media/media_fakes.exs'
  - 'server/test/nebu/media/media_sync_shared_pipeline_test.exs'
---

# ATDD Checklist — Bug Fix: Media downloads corrupted for compressed-at-rest files

**Bug (no story file — bug-fix pipeline run):** `Nebu.Media.Storage.compress/1` (ADR-029
store-smaller-of-two) gzips plaintext before encryption at upload time when smaller; the
download/thumbnail path never gunzips it back out, so every compressed-at-rest object is
served still gzip-wrapped, mislabeled with the original Content-Type.

**Generated:** 2026-08-26
**TEA:** Master Test Architect
**Stack:** backend (Elixir/ExUnit — no browser-visible behavior, AI generation mode per
`step-02` — this is a pure HTTP/storage-layer bug, not admin-UI, so no Gherkin/Playwright
scenario applies)

---

## Test Inventory

| # | Test Name | File | Framework | AC | Pre-fix result |
|---|---|---|---|---|---|
| 1 | `AC1: download of a compressed-at-rest file` → `GET /_matrix/client/v1/media/download/:server_name/:media_id → 200 with the ORIGINAL bytes, not the gzipped stored form` | `media_download_gzip_decompression_test.exs` | ExUnit + fake seams (`MediaFakes.DB`/`.Storage`/`.Membership`) | AC1 | **FAIL** |
| 2 | `AC1: download of a compressed-at-rest file` → `GET /_matrix/media/v3/download/:server_name/:media_id (legacy alias) → same ORIGINAL-bytes contract` | `media_download_gzip_decompression_test.exs` | ExUnit + fake seams | AC1 | **FAIL** |
| 3 | `AC2: thumbnail of a compressed-at-rest file` → `GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id → 200 with the ORIGINAL image bytes, not the gzipped stored form` | `media_download_gzip_decompression_test.exs` | ExUnit + fake seams | AC2 | **FAIL** |
| 4 | `AC3: download of an UNCOMPRESSED file (non-regression)` → `GET download of a compressed: false row still returns the original bytes unmodified` | `media_download_gzip_decompression_test.exs` | ExUnit + fake seams | AC3 | PASS (already correct — regression guard) |
| 5 | `DBLookupCompressedKeyTest` → `lookup/2 ... includes :compressed == true for a row persisted with compressed: true` | `media_download_gzip_decompression_test.exs` | ExUnit, `:integration`, real Postgres | AC4 | **FAIL** |
| 6 | `DBLookupCompressedKeyTest` → `lookup/2 includes :compressed == false for a row persisted with compressed: false` | `media_download_gzip_decompression_test.exs` | ExUnit, `:integration`, real Postgres | AC4 | **FAIL** |

All 6 tests live in **one file**, `server/test/nebu/media/media_download_gzip_decompression_test.exs`,
mirroring the existing convention of bundling a cohesive bug's ACs into a single test module
(cf. `media_compression_test.exs`'s AC1-AC7). Tests 1-4 are `defmodule
Nebu.Web.MediaDownloadGzipDecompressionTest` (fake-seam, no DB, plain `mix test`). Tests 5-6
are a nested `DBLookupCompressedKeyTest` module tagged `:integration` (real `Nebu.Repo`,
`mix test --include integration`) — this split is required because AC4 is specifically about
the REAL SQL `@sql_lookup`, which no fake can expose (`MediaFakes.DB.lookup/2` just echoes
back whatever map a test hands it).

---

## AC Coverage Matrix

| AC | Description | Test(s) | Status |
|---|---|---|---|
| AC1 | Compressed-at-rest download (v1 client route + legacy v3 alias) serves ORIGINAL bytes, not `:zlib.gzip(original)` | Tests 1, 2 | Written, FAILS |
| AC2 | Thumbnail path also decompresses when the row is compressed-at-rest | Test 3 | Written, FAILS |
| AC3 | Uncompressed row (`compressed: false`) continues to round-trip correctly (non-regression guard) | Test 4 | Written, PASSES today (see note below) |
| AC4 | `Nebu.Media.DB.lookup/2`'s row map includes `:compressed` as a key | Tests 5, 6 | Written, FAILS |

### AC2 grounding note — thumbnails CAN be compressed-at-rest (not skipped)

Verified against the actual code, not assumed: `Nebu.Media.thumbnail/3` does **not** store or
fetch a separately-resized image. Per its own comment in `media.ex` ("Thumbnail generation via
libvips/Image is intentionally NOT used ... we serve the decrypted original inline"), it calls
the exact same `with_authorised_media/4` → `fetch_and_decrypt/3` path as `download/4`, against
the same `media_files` row (same `storage_key`, same `compressed` flag, same encrypted S3
object). There is no separate thumbnail storage anywhere in this codebase. So a row compressed
at upload time is compressed for **both** the download and the thumbnail route — AC2's test is
not a hypothetical, it exercises a real, reachable path through `serve_inline_image/4`. A test
was written, not skipped.

### AC3 note — why this test currently PASSES (expected, not a mistake)

Today's code never calls `:zlib.gunzip/1` at all, regardless of the `compressed` flag — the bug
is a total *absence* of decompression, not a wrong condition. So a `compressed: false` row
(bytes stored == original) already round-trips correctly by construction: `serve_bytes/4` /
`serve_inline_image/4` just echo the decrypted plaintext straight through. This test is a
**forward-looking regression guard**: once the fix adds a conditional `:zlib.gunzip/1` on
`row.compressed`, this test is what catches a bad implementation that gunzips *unconditionally*
(which would raise/corrupt every non-gzip-shaped file whose bytes don't happen to parse as
valid gzip framing). Mirrors the "correctly passing/non-regression" test pattern already used
elsewhere in this suite (e.g. `admin-media-nav-grouping`'s ATDD pass: 17 RED + 3 correctly
passing).

---

## How to Run the Tests

### Fake-seam tests (AC1-AC3) — plain `mix test`, no live DB required

```bash
cd server
mix test test/nebu/media/media_download_gzip_decompression_test.exs
```

Or via the project's standard unit-test container (`make test-unit-elixir` equivalent):
```bash
docker run --rm -v $(pwd):/workspace -w /workspace elixir:1.20-alpine \
  sh -c "cd server && mix local.hex --force && mix deps.get && mix test test/nebu/media/media_download_gzip_decompression_test.exs"
```

### Real-Postgres test (AC4) — `mix test --include integration`

Requires a live PostgreSQL reachable as `Nebu.Repo` (`NEBU_DB_URL` set before the app starts).
The dev stack's `postgres` service was started for this ATDD pass
(`docker compose up -d --wait postgres`, reusing the existing `nebu_postgres_data` volume,
already migrated to `schema_migrations.version = 34`, matching the latest file on disk,
`000034_media_config_scan_kill_switch.up.sql`).

**Caveat found during this pass:** a locally-installed native Postgres (Homebrew) was ALSO
bound to `127.0.0.1:5432` on the dev machine, silently swallowing connections intended for the
Docker Postgres (`role "nebu_app" does not exist` — the native instance's default `postgres`
role set, not Nebu's). Connecting through the Docker network (not the host port) sidesteps
this entirely and matches the Makefile's own `test-integration-elixir` pattern:

```bash
docker run --rm -v $(pwd):/workspace -w /workspace \
  --network=nebu_default \
  -e NEBU_DB_URL=postgresql://nebu_app:nebu_app_dev_pw@postgres:5432/nebu \
  elixir:1.19-alpine \
  sh -c "cd server && mix local.hex --force && mix deps.get && mix test test/nebu/media/media_download_gzip_decompression_test.exs --include integration --warnings-as-errors"
```

### Full media suite regression check (both modes run during this ATDD pass)

```bash
# fake-seam only
mix test test/nebu/media/ --warnings-as-errors
# => 242/252 passed, 10 failed: 3 are this bug's new RED tests (AC1 x2, AC2 x1),
#    7 are PRE-EXISTING unrelated failures (MediaUploadVerbTest x3, MediaSyncSharedPipelineTest x2,
#    MediaSyncStateTransitionTest x2 — untouched files, in-flight/incomplete other stories on
#    feature/advanced-media-management, confirmed via `git status` to be outside this change's diff)

# + integration, via docker/nebu_default
# => 321 tests, 9 failures: 5 are this bug's new RED tests (AC1 x2, AC2 x1, AC4 x2),
#    4 are the same pre-existing unrelated failures (order-dependent subset of the 7 above —
#    Application.env-seam test pollution across files, not something this ATDD pass introduced
#    or is in scope to fix)
```

---

## Pre-fix Failure Evidence

```
1) AC1: download of a compressed-at-rest file GET /_matrix/client/v1/media/download/:server_name/:media_id → 200 with the ORIGINAL bytes, not the gzipped stored form
   BUG REPRODUCED: the response body is the still-gzipped stored bytes (326 bytes) — the
   download path never calls :zlib.gunzip/1 on a compressed: true row

2) AC1: download of a compressed-at-rest file GET /_matrix/media/v3/download/:server_name/:media_id (legacy alias) → same ORIGINAL-bytes contract
   Refute with == failed, both sides are exactly equal
   code: refute conn.resp_body == gzipped
   left: <<31, 139, 8, 0, ...>>   (gzip magic bytes 0x1f 0x8b — the response IS raw gzip)

3) AC2: thumbnail of a compressed-at-rest file GET /_matrix/client/v1/media/thumbnail/:server_name/:media_id → 200 with the ORIGINAL image bytes, not the gzipped stored form
   BUG REPRODUCED: the thumbnail body is the still-gzipped stored bytes (53 bytes) —
   serve_inline_image/4 never gunzips a compressed: true row either

5) lookup/2 (the download/thumbnail-path lookup) includes :compressed == true for a row persisted with compressed: true
   Nebu.Media.DB.lookup/2's returned row is missing the :compressed key entirely —
   @sql_lookup's SELECT list does not include the `compressed` column
   code: assert Map.has_key?(row, :compressed)

6) lookup/2 includes :compressed == false for a row persisted with compressed: false
   Nebu.Media.DB.lookup/2's returned row is missing the :compressed key entirely —
   @sql_lookup's SELECT list does not include the `compressed` column
   code: assert Map.has_key?(row, :compressed)
```

Test 4 (AC3, `compressed: false` round-trip) passed as expected (see note above).

---

## Test Design Notes

### Why `Storage.compress/1` is called for real, not hand-rolled

Every AC1-AC3 fixture is run through the REAL `Nebu.Media.Storage.compress/1` (not a
simulated gzip), then a sanity `assert compressed? == true` (or `false` for AC3) BEFORE the
download assertion — same technique `media_compression_test.exs` already established. This
guarantees the fixture genuinely exercises the branch under test, rather than assuming gzip
would have picked a particular fixture.

### Why the AC4 value-check avoids `row.compressed` / `Map.get(row, :compressed)`

Elixir's compiler (OTP 29 / Elixir 1.20 set-theoretic type inference) statically traces
`Nebu.Media.DB.lookup/2` → `to_map/1`'s literal map-construction and infers its EXACT return
shape at compile time. Both `row.compressed` (dot access) and `Map.get(row, :compressed)`
against that inferred type produce a compile-time "unknown key" / "incompatible types" WARNING
today (confirmed by direct experiment during this pass) — which `--warnings-as-errors` (this
project's `make test-unit-elixir` gate) turns into a hard compile failure for the WHOLE test
suite, not just this file. The `Map.has_key?/2` assertion (a generic, non-type-narrowing call)
already fully proves AC4's literal requirement ("the returned row map includes compressed as
one of its keys") without tripping this; the follow-up value check routes through
`Enum.into(row, %{})[:compressed]` (loses the precise inferred shape on purpose) as a
defense-in-depth check once the key exists, without reintroducing the warning.

### `media_test_support.exs` change

`Nebu.Web.MediaTestSupport.media_row/1` (shared fake-row builder used by ~10 other media test
files) gained a `compressed: Keyword.get(opts, :compressed, false)` key. Default `false`
preserves every pre-existing caller's meaning unmodified — verified via the full
`test/nebu/media/` regression run above (no new failures attributable to this change).

### Pre-existing compile prerequisite (already applied, not part of this ATDD pass's diff)

`media_upload_test.exs:229` called an undefined `put_upload/2` (stale PUT→POST rename) that
blocked compilation of the whole `test/` tree; already fixed to `post_upload/2` before this
ATDD pass started (logged in `_bmad-output/nebu/pipeline-state.yaml` at `19:04Z`, prior to
`19:29Z` pipeline start) — confirmed present, not re-touched here.

---

## Definition of Done for this bug fix

- [ ] `Nebu.Media.DB.@sql_lookup` SELECTs `compressed`; `to_map/1`'s matching clause adds
      `compressed: compressed` to the returned row map (AC4)
- [ ] `Nebu.Media.fetch_and_decrypt/3` (or a caller-side wrapper) calls `:zlib.gunzip/1` on the
      decrypted plaintext when `row.compressed == true`, for BOTH `serve_bytes/4`
      (download) and `serve_inline_image/4` (thumbnail) call sites (AC1, AC2)
- [ ] `compressed: false` rows are left byte-for-byte untouched — no unconditional gunzip (AC3)
- [ ] All 6 tests in `media_download_gzip_decompression_test.exs` PASS (fake-seam AC1-AC3 via
      plain `mix test`; AC4 via `mix test --include integration` against a live Postgres)
- [ ] `mix test --warnings-as-errors` (full suite) has no NEW failures beyond the pre-existing,
      unrelated ones already present on `feature/advanced-media-management` before this fix
