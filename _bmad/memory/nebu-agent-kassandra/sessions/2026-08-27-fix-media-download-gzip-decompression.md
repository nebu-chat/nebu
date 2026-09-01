# Session — `fix-media-download-gzip-decompression` (bug-fix pipeline, no story file)

**Date:** 2026-08-27
**Scope:** `git diff --staged` — `server/lib/nebu/media.ex` + `server/lib/nebu/media/db.ex`
(production); 5 test files + 3 pipeline artifacts (non-production).
Branch `feature/advanced-media-management`.

**Report:** `docs/stories/security-reports/fix-media-download-gzip-decompression-security-review-2026-08-27.md`

**Finding summary:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 3 LOW (+4 INFO) — **APPROVED / CLEAN**

The bug: `Nebu.Media.Storage.compress/1` (ADR-029 store-smaller-of-two) gzips plaintext before
encryption and records `media_files.compressed`, but the download/thumbnail path never read the flag
or gunzipped — serving raw gzip mislabeled with the original Content-Type. Fix adds `compressed` to
`@sql_lookup`/`to_map/1` and a `safe_maybe_gunzip/2` in `fetch_and_decrypt/3` (rescue → 502
M_UNKNOWN, logs media_id only).

## The three coordinator-flagged questions, answered

1. **Decompression bomb? No — and neither "new" nor "already inherent"; a third thing.** No bomb is
   possible: expansion is hard-capped at `max_upload_bytes` (body capped *before* compression), the
   compressed stream is server-produced (`compress/1` byte-size comparison; **no** `Content-Encoding`
   handling anywhere in `media.ex`), and the ciphertext is genuinely GCM-authenticated with the key in
   the DB, not the object store — so object-store-only compromise cannot substitute an attacker gzip.
   Absolute per-request heap ceiling **unchanged** (an incompressible 50 MB upload already cost that
   pre-fix). What *does* change: heap-per-request now tracks the ORIGINAL size while the S3 fetch
   tracks the COMPRESSED size → the S3 GET stops being the throughput bottleneck, so achievable
   concurrency for a given heap cost rises by ~the compression ratio, on the two routes with no
   RateLimit plug. Rated LOW = refinement of already-open epic-end M-1, not a new class.
2. **Can the rescue mask a security failure? No.** Body is one call to a total function whose only op
   is `:zlib.gunzip/1`; every crypto/access failure is upstream inside the `with`; `:zlib.gunzip/1`
   returns all-or-raises so no partial body can be served; `rescue` doesn't catch exit/throw. It is a
   net **improvement**: `RequestLogger` writes `operational_logs` from `register_before_send/2` and the
   app has no `use Plug.ErrorHandler`, so an uncaught raise = a request with NO operational-log row.
   Only residual is metrics-level (L-3).
3. **`to_map/1` defp→def bypass? No.** Pure list→map, no I/O/auth; and the gate is NOT in
   `DB.lookup/2` (it's `download_gate/1` + `Membership.member?/2` in `Nebu.Media`), and `lookup/2` is
   *already* `def` — so `to_map/1` grants strictly less than an existing public function. Same
   precedent as `parse_state/1` (assessed CLEAN in the 1c review).

**ClamAV claim VERIFIED, not taken on faith:** `MediaScanWorker` line 218 gunzips before
`scan_binary/1`, so the scanner always saw the true original; pre-fix the client got an inert gzip
envelope. The mismatch ran in the SAFE direction — there was never a "scanned clean, served something
else" window. Only two consumers of stored bytes exist app-wide, both gunzip.

## Findings (all LOW/advisory)

- **L-1** heap/S3 cost asymmetry on the un-rate-limited download+thumbnail routes → close M-1.
- **L-2** two silent fail-open-to-the-original-bug paths (`Map.get(row, :compressed, false)` default +
  `maybe_gunzip(bytes, _other)` catch-all) — dead today (`BOOLEAN NOT NULL DEFAULT false`, single
  `to_map/1` caller) but silent, no log line. Fail-open direction is SAFE for security (inert gzip),
  UNSAFE for silent regression.
- **L-3** 502 M_UNKNOWN now covers 4 distinct causes; an at-rest integrity/writer-invariant violation
  is indistinguishable from S3 flakiness in metrics, and the branch has zero test coverage (only
  untested new branch in the diff).

## Checks that came back clean (worth not re-deriving next time)

- **No GRANT gap — pattern #86 does not recur.** `000001_init.up.sql:672` is
  `GRANT … ON ALL TABLES IN SCHEMA public` (table-level), so widening a SELECT list on `media_files`
  never needs a new grant. Corroborated: `state`/`storage_key`/`archived_at` came from the same 000022
  `ALTER TABLE` and already work.
- **Range safe:** `maybe_send_ranged/2` uses `byte_size(plaintext)`, never `row.file_size` — no
  Content-Length/Content-Range desync possible in either direction. `file_size` was always the
  pre-compression size.
- **Stored-XSS (Epic-12 pattern) re-tested, intact:** `@blocked_upload_types` rejects html/xhtml/js/
  svg/swf at upload; `disposition_for/2` forces octet-stream+attachment outside `@safe_inline_types`;
  both serve paths emit `sandbox; default-src 'none'; script-src 'none'`.
- **Pattern #22 (fix wakes dead code) applied → clean:** `thumbnail/3` deliberately does no resizing
  (no libvips in Alpine), so no image-parsing library is newly exposed to previously-undecodable bytes.
- Gunzip is strictly after default-deny `download_gate/1` and after `Membership.member?/2`; both
  routers run OidcPlug; `member?(_, nil) -> false` → no anonymous reachability.
- Formatting-only hunks verified semantically inert; no new migration/route/audit action/secret/SQL
  interpolation; test changes are test-only with paired `on_exit` cleanup.

**Accepted risks this session:** none new.

**Follow-up:**
- L-2 and L-3 are one-line / one-test fixes — cheap, recommend folding into this pipeline cycle.
- M-1 (no per-IP rate limit on download/thumbnail) gains a second independent argument; still open
  from epic-end SEC Gate 2 (2026-07-20).
- **New conditional watch-flag (I-2):** `MediaScanWorker:227` releases UNSCANNED on ClamAV
  `:file_too_large`. Unreachable today (ClamAV `max_file_size_bytes` 100 MB > `max_upload_bytes`
  50 MB). If an operator raises `:media_max_upload_bytes` above the scanner ceiling, that band opens —
  and post-fix those never-scanned bytes are served INTACT where a compressible one was previously
  served as inert gzip. Clamp the upload limit to the scanner ceiling or refuse boot on mismatch.
- **Pre-existing asymmetry for a future story:** `thumbnail/3` picks its inline Content-Type via a bare
  `image_type?/1` prefix test (`media.ex:632`) instead of the `@safe_inline_types` allowlist the
  download path uses; CSP sandbox is the sole backstop. Align both paths on one allowlist.
