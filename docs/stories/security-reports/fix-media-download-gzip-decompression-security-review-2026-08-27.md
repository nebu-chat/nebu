# Security Review — `fix-media-download-gzip-decompression` (bug-fix pipeline, no story file)

**Reviewer:** Kassandra (nebu-agent-kassandra, `references/security-review.md`)
**Diff scope:** `git diff --staged` — `server/lib/nebu/media.ex`, `server/lib/nebu/media/db.ex` (production);
5 test files + 3 pipeline artifacts (non-production).
**Date:** 2026-08-27
**Branch:** `feature/advanced-media-management`

**Verdict: APPROVED / CLEAN** — 0 CRITICAL, 0 HIGH. Commit is not blocked.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| L-1 | LOW | `server/lib/nebu/media.ex:1073` + `server/lib/nebu/web/router/media.ex:86-96`, `server/lib/nebu/web/router/client_v1_media.ex:51-59` | Per-request heap on download/thumbnail now tracks the *original* size while the S3 fetch tracks the *compressed* size — decouples attacker storage/bandwidth cost from server memory cost on the two media routes that carry no rate-limit tier. Not a decompression bomb. | Add a download/thumbnail rate-limit tier mirroring `@upload_rate_limit`; and/or short-circuit on `row.file_size` before the S3 GET. Sharpens already-open epic-end M-1. |
| L-2 | LOW | `server/lib/nebu/media.ex:1073`, `:1112` | Two silent fail-open-to-the-original-bug paths (`Map.get(row, :compressed, false)` default + `maybe_gunzip(bytes, _other)` catch-all). Dead code today, but each silently restores the exact bug this fix closes, with **no log line**, if a future change drops the column or alters its type. | Add `Logger.warning` to the catch-all clause, or read `row.compressed` directly (loud `KeyError`) now that `to_map/1` always sets it and a unit test pins its position. |
| L-3 | LOW | `server/lib/nebu/media.ex:1076-1085` | The new 502 is the **fourth** distinct cause collapsed into an identical `502 M_UNKNOWN "Media storage unavailable"`. An at-rest integrity / writer-invariant violation is now indistinguishable from routine S3 flakiness in metrics; the single distinguishing signal (one `Logger.error` line) has no counter/alert and no test pinning it. | Emit a distinct marker or `media_integrity_mismatch` counter; add a regression test for the branch (currently the only untested new branch in the diff). |

**INFO (no action required):** I-1 … I-4 below.

---

## Detail

### L-1 — Compression-ratio cost asymmetry on the un-rate-limited download path [LOW]

**This is the coordinator's flagged question. My independent judgment: the decompression-bomb framing is wrong, but there is a real, smaller delta.**

Why it is **not** a bomb — four facts verified by construction, not assumption:

1. **The compressed stream is server-produced, never attacker-supplied.** `Nebu.Media.Storage.compress/1`
   (`storage.ex:114-122`) gzips the plaintext server-side and stores the gzip **only if
   `byte_size(gzipped) < byte_size(original)`**. The `compressed` boolean is derived purely from that
   byte-size comparison. Grep confirms **no `Content-Encoding` handling anywhere** in `media.ex` — no
   request header, in any form, influences the flag or the stored bytes.
2. **Expansion is hard-capped by the server's own upload cap.** `Nebu.Media.upload/1` caps the body
   *before* compression (`over_content_length?/2` + `read_full_body/3`, `media.ex:172-178`,
   `@default_max_upload_bytes` = 50 MB, `media.ex:55`). Gunzip output is therefore
   `≤ max_upload_bytes` **by construction** — the ratio is not attacker-choosable beyond that ceiling.
3. **The ciphertext is genuinely AEAD-authenticated.** `Crypto.decrypt/3` (`crypto.ex:33-45`) splits
   the trailing 16-byte tag and passes it to `:crypto.crypto_one_time_aead(:aes_256_gcm, …, false)`,
   mapping any non-binary result to `{:error, :decrypt_failed}`. The AES key and nonce live in
   `media_files` (`aes_key_hex`/`nonce_hex`), **not** in the object store. So a compromise of the
   object store alone — a genuinely separate trust domain (MinIO / Stackit ObjectStorage) — **cannot**
   substitute an attacker-chosen gzip stream. This is the load-bearing fact: had the tag not been
   verified, L-1 would have been a real unbounded bomb. It is verified.
4. **The absolute per-request ceiling is unchanged.** Pre-fix worst case was an *incompressible* 50 MB
   upload (`compressed = false`): ciphertext + plaintext ≈ 100 MB, and that path is byte-for-byte
   untouched by this diff. Post-fix, a compressible file peaks at roughly `|P| + 2·|S| ≲ 50 MB`. The
   fix does **not** raise the ceiling.

What **is** new — the honest delta: the *cost to the server per unit of heap* drops by the compression
ratio. To make the node allocate ~50 MB pre-fix, an attacker had to make it pull 50 MB from S3. Post-fix
the same 50 MB of heap costs a ~50 KB S3 GET (gzip of highly repetitive data reaches ~1000:1). The S3
fetch is no longer the throughput bottleneck, so the number of concurrent in-flight requests each
holding a full-size plaintext rises accordingly. This matters most on remote object storage (Stackit),
least on co-located MinIO.

Reachability is **bounded and authenticated** (see I-3): gunzip runs strictly after the default-deny
`download_gate/1` and after `Membership.member?/2`; both routers run `Nebu.Web.Plugs.OidcPlug`. But
`Membership` is the known "member of ANY room" fallback (`membership.ex:24-31`), so any authenticated
user in ≥ 1 room can drive this against their own uploaded media_id. `download`/`thumbnail` carry
**no** `RateLimit` plug — only `upload` and `preview_url` do (`router/media.ex:47-58, 64-99`).

Rated LOW, not MEDIUM: availability-only, requires standard credentials plus a prior upload, absolute
ceiling unchanged, and the missing rate limit is already logged as epic-end **M-1** (MEMORY, epic
`media-security-admin-control` SEC Gate 2, 2026-07-20). This finding is a *refinement* of M-1, not a
new class — and one more argument for closing it. The prior code review reached the same conclusion
independently (its deferred item #10); I re-derived it rather than adopt it, and agree.

**MEMORY pattern #225 re-verified and upheld.** The 2026-07-20 calibration note ("size ceiling applied
after in-memory decrypt+decompress is NOT a decompression bomb when compression is server-side over an
upload-bounded plaintext") was written for `MediaScanWorker`. Its reasoning transfers to the download
path unchanged, and every premise it rests on (server-side compression, upload-bounded plaintext, GCM
authentication, DB-held key) was re-checked against current code above rather than assumed.

### L-2 — Two silent fail-open paths back to the original bug [LOW]

`safe_maybe_gunzip(plaintext, Map.get(row, :compressed, false))` plus the
`maybe_gunzip(bytes, _other), do: bytes` catch-all give two routes to "serve the gzip bytes,
mislabeled" — i.e. *exactly* the bug being fixed — with no error and no log line.

Both are unreachable today, verified:
- `compressed BOOLEAN NOT NULL DEFAULT false` (`000022_media_state_machine_foundation.up.sql:31`) —
  `NULL` is impossible, and Postgrex maps `boolean` to `true`/`false`, so `_other` cannot match.
- `to_map/1` is the sole producer of the row map and always sets `:compressed`; it has exactly **one**
  caller (`db.ex:79`, `lookup/2`) — verified by grep, so no second SELECT list can reach it with a
  short row.

Note the direction: this fail-open serves an *inert gzip envelope*, which is the **safe** direction
security-wise (it is why the original bug was a data-corruption bug and not an exploitation bug) but
the **unsafe** direction for silent regression. The defensive clauses are the right call; they just
need to be audible.

### L-3 — Integrity failure indistinguishable from storage flakiness in metrics [LOW]

`502 M_UNKNOWN "Media storage unavailable"` is now returned for four semantically distinct causes:
S3/archive GET failure, `Base.decode16` failure on the key/nonce, AES-GCM tag mismatch, and gunzip
failure. The **client-facing** genericity is correct — no information leak, and I would flag any
attempt to differentiate it. The gap is server-side: an operator has no counter separating "the
`compressed` flag and the stored bytes disagree" (a writer-side invariant violation, possibly the
first symptom of an out-of-band `UPDATE media_files` or a future `encrypt_compress_and_store/5` bug)
from ordinary S3 noise. The one signal that exists — `Logger.error "…:zlib.gunzip/1 failed for
media_id=…"` — is accurate and PII-free, but unaggregated and, notably, **untested**: no test in
`media_download_gzip_decompression_test.exs` exercises the 502 branch (grep for `502`/`M_UNKNOWN`:
zero hits). It is the only new branch in the diff with no coverage.

---

## INFO

### I-1 — `Nebu.Media.DB.to_map/1` `defp` → `def` creates no bypass surface [INFO]

The coordinator's second flagged question. Verified CLEAN, on mechanism rather than on intent:

- `to_map/1` is a pure positional list → map conversion. No DB access, no I/O, no authorization
  decision, no side effect. It cannot be *reached* without already holding the full row — including
  `aes_key_hex` — at which point the caller has everything anyway.
- **The access-control gate does not live in `DB.lookup/2`.** `download_gate/1` and
  `Membership.member?/2` live in `Nebu.Media.with_authorised_media/4` (`media.ex:949-969`).
  `DB.lookup/2` performs *no* authorization and is **already** `def`. So `to_map/1` being public grants
  strictly **less** than an existing public function. There is nothing to bypass.
- No dynamic-dispatch path reaches it from request data: `db_module()` resolves from
  `Application.get_env`, not from any request field; there is no `apply/3` with a request-derived
  function name in the media path.
- Direct precedent: `parse_state/1` is already `def` + `@doc false` for the same test reason and was
  assessed CLEAN in the Story 1c review (MEMORY row, 2026-07-13: "parse_state/1 public @doc false = no
  exploitable surface").

Residual is ADR-020 hygiene only (widening a non-Public-API module's exports for test access),
mitigated by `@doc false` and an explicit "do not call this from other application code" comment.
Not a finding.

### I-2 — ClamAV "scanned bytes == served bytes" claim: VERIFIED, and the pre-fix mismatch was in the safe direction [INFO]

The coordinator asked me not to take the diff's claim at face value. Checked at the call site:
`Nebu.Workers.MediaScanWorker.do_scan_and_transition/3` (`media_scan_worker.ex:218`) calls
`maybe_gunzip(plaintext, row.compressed)` and passes the **result** to `clamav().scan_binary(bytes)`
on the next line. So the scanner has always seen the true original plaintext.

The claim is therefore correct — and, importantly, the pre-fix mismatch ran in the **safe** direction:
the scanner saw the real content while the client received an inert gzip envelope. There was never a
"scanned clean, served something else unscanned" window. The fix restores fidelity; it does not weaken
the scan gate. Only two consumers of stored media bytes exist app-wide (`Nebu.Media.fetch_and_decrypt/3`
and `MediaScanWorker`) — verified by grepping every `Crypto.decrypt` / `Storage.get` call site — and
both now gunzip. The admin detail view (`admin/media_live/detail.ex`) reads metadata only, never bytes.

**One conditional watch-flag, surfaced because it is precisely the kind of accidental mitigation this
fix removes.** `MediaScanWorker` line 227-228 releases a file **unscanned** when ClamAV reports
`:file_too_large`: `{:error, :file_too_large} -> release(media_id, %{skipped: "size_limit"})`. That
branch is currently **unreachable**: `Nebu.Media.ClamAV` `max_file_size_bytes` is 100 MB
(`config/config.exs:65`) while `max_upload_bytes` is 50 MB (`media.ex:55`), and the ClamAV ceiling is
checked against the already-decompressed bytes (`clamav.ex:149`). If an operator ever raises
`:media_max_upload_bytes` above the scanner ceiling without raising it too, that band opens — and
post-fix those never-scanned bytes are served **intact**, where a compressible one was previously
served as inert gzip. Recommend clamping the upload limit to the scanner ceiling, or refusing boot on
the mismatch.

### I-3 — Gunzip is correctly positioned behind the gate; no new pre-auth compute [INFO]

Re-verified the ordering rather than assuming it (this is what bounds L-1):
`with_authorised_media/4` → `download_gate(row.state)` → `Membership.member?/2` →
`fetch_and_decrypt/3` → S3 GET → decrypt → **gunzip**. `download_gate/1` remains allowlist-of-success
(`:released` the sole positive, catch-all denies, `media.ex:985-1021`), unchanged by this diff. Both
routers run `Nebu.Web.Plugs.OidcPlug` (`router/media.ex:60`; `client_v1_media.ex`, confirmed CLEAN in
the 2026-07-31 review), and `Membership.member?(_, nil)` returns `false`, so an unauthenticated caller
never reaches the new code. The new work is unreachable for non-`:released` media and for anonymous
callers.

### I-4 — The rescue is a net audit-completeness improvement; it cannot mask or misclassify a data-security failure [INFO]

The coordinator's third flagged question. Analysis of what the rescue can and cannot swallow:

- **Scope is tight.** `safe_maybe_gunzip/2`'s body is a single call to a **total** function
  (`maybe_gunzip/2` has clauses for `true`, `false`, and a catch-all), whose only operation is
  `:zlib.gunzip/1`. There is no second expression for `rescue _` to over-capture.
- **No partial data can be served.** `:zlib.gunzip/1` either returns the complete binary or raises;
  the rescue discards any intermediate state and returns `:error`. There is no path where a truncated
  or half-inflated body reaches `on_ok`.
- **It cannot mask a crypto or access-control failure.** Every such failure is *upstream* of the
  rescue, inside the `with` (S3 GET, `Base.decode16` on key/nonce, `Crypto.decrypt/3`), and is mapped
  by the pre-existing `else` block. A tampered ciphertext fails the GCM tag and never reaches
  `safe_maybe_gunzip/2`. The rescue's only reachable trigger is a writer-side flag/payload desync — as
  the diff's revised comment now correctly states. (The original comment's "at-rest corruption"
  justification was factually wrong; the correction is right, and I re-derived it independently from
  `crypto.ex` rather than accepting cycle 1's word.)
- **It does not swallow `exit`/`throw`** (`rescue` catches only raised errors) — so a supervisor-level
  fault still propagates normally.
- **Net improvement, verified:** `RequestLogger` writes its `operational_logs` row from
  `Plug.Conn.register_before_send/2` (`request_logger.ex:97`), and the application has **no**
  `use Plug.ErrorHandler` anywhere (grep: the only mention is a doc comment in `plugs/json_body.ex`).
  An uncaught raise inside `fetch_and_decrypt/3` would therefore have produced a request with **no
  operational-log row at all**. The rescue closes that observability/audit hole. The diff's claim on
  this point is accurate.
- **No content leak in logs** (MEMORY pattern #84, crash-report vector): the rescue deliberately drops
  the exception and stacktrace, and the caller logs only the server-generated `media_id` — never bytes,
  never the raw exception. Correct.

The only residual is the metrics-level misclassification captured as L-3 — not a masked security
failure.

---

## Additional checks performed (all clear, no finding)

- **Range / `Content-Length` desync.** `maybe_send_ranged/2` computes `total` from
  `byte_size(plaintext)` (`media.ex:1148`), never from `row.file_size` — so the fix cannot desync
  `Content-Length`/`Content-Range` from the body, and there is no response-truncation or
  request-smuggling surface in either direction. `file_size` was always the *pre-compression* size
  (`file_size: byte_size(body)`, `media.ex:514`); post-fix the served length matches it for the first
  time. Pre-fix, Range served a consistent-but-gzipped view.
- **No GRANT gap — MEMORY pattern #86 does not recur.** `000001_init.up.sql:672` is
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app` — **table-level**,
  so the widened `@sql_lookup` SELECT list needs no new grant. Independently corroborated:
  `state`, `storage_key` and `archived_at` were added by the *same* `ALTER TABLE` in 000022 and are
  already in the working SELECT list. Had the grant been column-level, `lookup/2` would fail →
  `{:error, :not_found}` → a silent site-wide 404 on all media; it is not.
- **Fix completeness across routes.** Both `Nebu.Web.Router.Media` (v3 legacy) and
  `Nebu.Web.Router.ClientV1Media` (authenticated v1) delegate to the same
  `Nebu.Media.download/2,3` / `thumbnail/3`, so the single-site fix covers all six routes. No
  byte-serving consumer was missed.
- **Stored-XSS re-check (Epic-12 pattern "Inline Content-Type echoed back with `inline` disposition").**
  This fix makes real bytes flow for compressible content types for the first time — and HTML/JS/SVG
  are precisely the highly-compressible class, so this pattern had to be re-tested, not inherited.
  Defenses verified intact: `@blocked_upload_types` rejects `text/html`, `application/xhtml+xml`,
  `text/javascript`, `application/javascript`, `image/svg+xml`, `application/x-shockwave-flash` at
  upload (`media.ex:169`); `disposition_for/2` forces `application/octet-stream` + `attachment` for
  anything outside `@safe_inline_types`; both `serve_bytes/4` and `serve_inline_image/4` emit
  `sandbox; default-src 'none'; script-src 'none'` CSP plus the global `nosniff`. Not a finding.
  *Pre-existing asymmetry noted for a future story (not introduced here):* `thumbnail/3` selects its
  inline Content-Type with a bare `image_type?/1` prefix test (`media.ex:632`) rather than the
  `@safe_inline_types` allowlist the download path uses — so any `image/*` subtype not on
  `@blocked_upload_types` is served inline on content-type prefix alone, with the CSP sandbox as the
  sole backstop. Worth aligning the two paths on one allowlist.
- **No image decoding newly reached.** `thumbnail/3` deliberately does **not** resize (no libvips in
  the Alpine container) — it serves the decrypted original inline. So the fix does not newly expose an
  image-parsing library to previously-undecodable bytes. MEMORY pattern #22 ("a fix that wakes up
  previously-dead code = new attack surface") was applied here and comes back clean.
- **Formatting-only changes confirmed semantically inert:** `state_machine_module().transition/4`
  argument list unchanged; `read_full_body/3` size guard unchanged; `lookup_reservation/2` and
  `candidates_for_archive/1` map shapes unchanged.
- **No new migration, no new route, no new audit action** (so no `AuditWriter.@known_actions` gap —
  MEMORY pattern), **no secret handling**, **no SQL string interpolation** (the widened `@sql_lookup`
  is a static heredoc with `$1`/`$2` binds).
- **Test-file changes are test-only.** Verb-assertion corrections, `compressed: false` default in
  `media_test_support.exs`, and three `Application.put_env(:nebu_http, :media_*_module, MediaFakes.*)`
  calls correctly paired with `on_exit` cleanup. No production seam widened, no fake reachable from
  production config.

---

## Summary

CRITICAL: 0 — commit not blocked
HIGH: 0 — commit not blocked
MEDIUM: 0
LOW: 3 — advisory (L-1 rolls into open epic-end M-1; L-2 and L-3 are cheap one-line/one-test fixes)
INFO: 4

**Verdict: APPROVED**

The fix is correct, minimal, positioned behind the existing default-deny gate, and — verified rather
than assumed — improves both content fidelity (served bytes now equal scanned bytes) and audit
completeness (a previously-uncaught raise would have skipped the `operational_logs` row entirely).
All three specifically-flagged concerns from the prior review cycles were re-derived from source and
resolve to LOW or INFO. Neither prior cycle's conclusion was adopted on trust; both held up on
re-check.

Answer to the flagged decompression-bomb question, stated plainly: **it is neither a new bomb nor
already-inherent — it is a third thing.** No bomb is possible, because expansion is hard-capped at
`max_upload_bytes` by construction and the compressed stream is server-produced under a GCM tag whose
key lives in the DB, not the object store. What the fix genuinely changes is the *cost asymmetry*:
heap per request now tracks the original size while the S3 fetch tracks the compressed size, on two
routes that carry no rate limit. That is L-1, LOW, and one more reason to close M-1.
