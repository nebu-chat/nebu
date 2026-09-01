# Security Review — `4b-media-scan-worker`

- **Epic:** media-security-admin-control
- **Reviewer:** Kassandra (adversarial security review)
- **Date:** 2026-07-14
- **Story security_review flag:** required (new worker that decrypts and scans attacker-controlled
  file content; first real wiring of `Oban.insert/1` in this codebase — 2e's own Oban bootstrap
  never had an HTTP-reachable enqueue path)
- **Scope:** staged diff — `server/lib/nebu/workers/media_scan_worker.ex` (NEW),
  `server/lib/nebu/media/db.ex` (`lookup_for_scan/1`, `update_scan_metadata/2` added),
  `server/lib/nebu/media/scan_enqueue.ex` (no-op stub → real `Oban.insert/1`),
  `server/config/config.exs` (`media_scan` queue entry), `server/test/nebu/workers/
  media_scan_worker_test.exs` (NEW), `server/test/nebu/media/scan_enqueue_test.exs` (NEW),
  `server/test/nebu/media/media_db_scan_metadata_test.exs` (NEW), `server/test/nebu/media/
  media_compression_test.exs`, `server/test/nebu/media/media_fakes.exs`

## VERDICT

**0 CRITICAL — 0 HIGH.** Nothing in this diff blocks the pipeline.

**0 MEDIUM.** **2 LOW** (both forward-looking watch-flags, neither blocking). Several
INFO/positive findings below.

The headline new attack surface — `ScanEnqueue.enqueue/1` now performing a real `Oban.insert/1`
— is clean: `media_id` reaching this call site is always server-generated (128-bit random id,
Story 2a) and the call site itself is unchanged 2b-owned code behind existing auth; nothing
attacker-controlled reaches `Oban.insert/1`'s arguments. The worker's own entry point
(`perform/1`) reads `job.args["media_id"]`, but that job was itself only ever created by the
same trusted enqueue call — there is no HTTP-reachable path to fabricate an arbitrary job for
this worker (`Oban.Testing` in the test suite is test-only; production has zero routes that
insert into `oban_jobs` directly).

## What the story does (verified against code, not just the summary)

`Nebu.Workers.MediaScanWorker.perform/1`: transitions `:quarantined -> :scanning`
(`Nebu.Media.StateMachine.transition/4`, `{:system, nil}` actor — never
admin-impersonated); on rejection (any `{:error, reason}`, not just the documented
`{:invalid_transition, _, :scanning}` case, per this cycle's own MINOR-3 fix) drives the
same retry/discard path a mid-scan failure would; on success, fetches ciphertext via
`Storage.get/1`, hex-decodes `aes_key_hex`/`nonce_hex` (non-bang `Base.decode16/2` since this
cycle's MINOR-2 fix — a malformed value now folds into the retry/discard path instead of
raising), decrypts via `Nebu.Media.Crypto.decrypt/3`, conditionally `:zlib.gunzip/1`s, and
calls `Nebu.Media.ClamAV.scan_binary/1` — the pre-existing, already-reviewed scanner boundary
(`3-clamav-genserver-security-review-2026-07-13.md`) this worker is simply a new caller of.

## Adversarial trace — where an attacker's bytes actually flow

The ONLY genuinely attacker-controlled data this worker ever touches is the **decrypted
plaintext of a file the attacker themselves uploaded** — everything else (`media_id`, the
`aes_key_hex`/`nonce_hex`/`storage_key`/`compressed` row fields) is server-derived, written
exclusively by this codebase's own upload path, never attacker-suppliable at this layer.

### Decompression-bomb check (traced, not assumed)

`row.compressed: true` bytes are ALWAYS `Nebu.Media.Storage.compress/1`'s own output —
`:zlib.gzip/1` applied by the SERVER to the plaintext of an upload whose SIZE was already
capped by `Nebu.Media.upload_async/3`'s pre-compression `413 M_TOO_LARGE` check
(`server/lib/nebu/media.ex:170/175/395/403` — the cap applies to the raw request body, before
any compression happens). Since the gzip blob is the server's own compression of that
already-size-bounded plaintext, `:zlib.gunzip/1` in this worker can only ever reconstruct bytes
up to that same pre-existing cap — there is no attacker-controlled "crafted gzip" step where a
tiny attacker-supplied blob could expand to an unbounded size (the classic zip-bomb shape).
**Not a finding** — the amplification an attacker would need doesn't exist in this pipeline;
compression here is a round-trip of content whose size the server itself already bounded.

### ClamAV `max_file_size_bytes` vs. 2b's upload cap (LOW — F-1, forward-looking)

`ClamAV.scan_binary/1`'s own size guard operates on the POST-decompression byte count, while
`2b`'s `413` cap operates on the PRE-compression request body. If an operator ever configures
`Nebu.Media.ClamAV`'s `max_file_size_bytes` lower than `2b`'s own upload size cap, a legitimately
accepted (highly-compressible) upload could be held fully in this worker's process memory
(bounded by 2b's cap, not unbounded — see above) before `scan_binary/1` gracefully returns
`{:error, :file_too_large}` (AC7's skip path, not a crash). This is a bounded, graceful-
degradation cost, not a vulnerability, and it is an existing operational relationship between
two independently-configured limits from two different stories (2b, 3) that this story didn't
introduce and doesn't change — flagging only as a config-consistency watch-flag for whoever
owns the deployed values, same spirit as 2e's own F-2 forward-looking note.

### AC10 invariant — worker never issues raw SQL against `media_files.state`

Verified directly: the worker's only DB touchpoints are `db().lookup_for_scan/1` (a SELECT) and
`db().update_scan_metadata/2` (`UPDATE media_files SET scan_metadata = $2 WHERE media_id = $1`
— parameterized, touches `scan_metadata` only). All state changes go through
`StateMachine.transition/4`. This cycle's own dev-story added a real-Postgres regression test
(`media_db_scan_metadata_test.exs`) proving the production SQL never touches `state` — closing
the pre-dev test-review's MINOR-1 gap with a genuine DB-level assertion, not just a fake-level
one. **Positive finding.**

### SQL injection / parameterization

Both new `Nebu.Media.DB` functions (`lookup_for_scan/1`, `update_scan_metadata/2`) use
`Ecto.Adapters.SQL.query/3` with `$1`/`$2` placeholders exclusively — no string interpolation
into SQL anywhere in this diff. **Clean.**

### Metadata/log content — never the scanned bytes

`scan_error/4`'s `%{reason: inspect(reason)}` and `infect/2`'s `%{clamav_signature:,
scanned_at:}` metadata never include the scanned binary itself — consistent with `ClamAV`'s own
AC9 ("never log content") and this worker doesn't introduce a new content-logging path.
`inspect(reason)` values traced across all three failure sources (ClamAV error atoms, `Storage.get/1`'s
`ExAws`/S3 error shapes, `:invalid_hex`/`:not_found`) — none plausibly embed credentials or
other secrets. **Clean.**

### Duplicate/concurrent job safety

No `unique:` constraint is configured on `Oban.Worker`, so a client retry of the upload PUT
could in principle enqueue two scan jobs for the same `media_id`. Traced the guard table:
`scanning` is NOT a legal target from `scanning` itself (`@transitions.scanning` does not list
`:scanning`), so a second concurrent job's entry transition is correctly rejected as
`{:invalid_transition, :scanning, :scanning}` and this cycle's MINOR-3 fix means it's now
routed through the standard retry/discard path (previously it hit the exact no-op clause anyway
since `from` binds to `:scanning`, matching `{:invalid_transition, _from, :scanning}`) — either
way, harmless. **Clean, no data race or double-scan risk.**

### Authorization — no bypass surface

The worker only ever acts with the `{:system, nil}` actor (rejected by `StateMachine.transition/4`
itself if ever set to anything else, per 1b's own guard) — it cannot forge an admin-attributed
transition. It never reads any HTTP request context, never checks/needs a caller identity, and
has zero HTTP-reachable trigger surface of its own (only `ScanEnqueue.enqueue/1`, itself gated by
2b's existing, unchanged auth). **Clean.**

## Findings

**F-1 (LOW, forward-looking watch-flag):** ClamAV's `max_file_size_bytes` and 2b's upload-size
cap are independently configured; if the former is set lower than the latter, a compressible
upload can transiently occupy worker-process memory up to 2b's cap before being gracefully
skipped (AC7), not a crash. Recommend documenting the intended relationship between these two
config values (e.g., in the ClamAV/2b config docs) so an operator doesn't set them
inconsistently. Not blocking.

**F-2 (LOW, forward-looking watch-flag):** No `unique:` opt on `Oban.Worker` means a client PUT
retry can enqueue a second scan job for the same `media_id`; today this is harmless (guard-table
rejection, routed through the retry/discard path), but if a future story ever weakens the guard
table's `scanning -> scanning` restriction, this could silently change behavior. Purely a
watch-flag for that future change, not an issue in the current diff.

## Prior findings re-verified

- **3-clamav-genserver's F-1 (unbounded reply-buffer OOM, MEDIUM)** — confirmed still fixed
  (`@max_reply_bytes 65_536` guard present in `clamav.ex`, unrelated to and unaffected by this
  diff).
- **2e's F-1/F-2 (hard_deleted nulling)** — unrelated to this worker's code paths (this worker
  never transitions to `:hard_deleted`), not re-triggered by this diff.

## Conclusion

**APPROVED.** 0 CRITICAL/HIGH/MEDIUM, 2 LOW (both forward-looking, non-blocking). This story's
own code-review cycle (MINOR-2, MINOR-3) already hardened exactly the kind of defensive gaps
that would otherwise have been my own first two findings (raise-instead-of-tagged-error paths
that could bypass the AC9 dead-letter guarantee) — independently re-verified both fixes against
the current code and confirm they are genuinely closed, not just claimed.
