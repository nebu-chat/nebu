# Code Review — `fix-media-download-gzip-decompression` (cycle 0)

**Verdict: the production fix is correct.** All four ACs implemented as claimed, no correctness defect in the diff.

## MAJOR

**MAJOR-1 — 7 pre-existing, unrelated unit-test failures on the branch.** Not caused by this diff (independently verified: 245/252 in server/test/nebu/media/, the 3 RED tests flipped green, zero collateral damage). Root cause confirmed:
- `media_sync_shared_pipeline_test.exs:132-139` and `media_sync_state_transition_test.exs:138-145`: both define a private `put_sync/2` helper that builds `conn(:put, @sync_path, body)` against a route that's now POST-only (`web/router/media.ex:64`) → 404.
- `media_upload_verb_test.exs`: setup only fakes `:media_storage_module`, missing the `:media_db_module` fake that sibling `media_upload_test.exs` has (`Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)`) → falls through to the real, unstarted `Nebu.Repo`.

**User decision: fix both in this pipeline cycle** (expand dev-story cycle 1 to include these 3 surgical fixes alongside the MINOR items below).

## MINOR (being sent to dev-story cycle 1)

1. Uncaught `:zlib.gunzip/1` raise on a corrupt-gzip row bypasses `RequestLogger`/security-headers/error-envelope entirely (no `Plug.ErrorHandler` in this app) — wrap in try/rescue → `Logger.error` + `error(conn, 502, "M_UNKNOWN", ...)`, consistent with the module's other failure branches. (Verified: no plaintext-in-logs leak from the raw stacktrace.)
2. The code comment justifying "let it crash" is factually wrong — `Crypto.decrypt` already verified the AES-GCM tag before this point, so a gunzip failure can't be at-rest/in-transit corruption; it's a writer-side flag/payload desync. Fix the comment to say that.
3. `maybe_gunzip/2` has no fallback clause — `Map.get(row, :compressed, false)` or a catch-all clause, matching this module's established fail-open posture for other optional fields (e.g. `archived_at`).
4. `media_test_support.exs`'s moduledoc still documents the pre-000022 row shape (missing `compressed`, `state`, `storage_key`, `archived_at`) — update to match reality.
5. Add a Range-request regression test on a compressed row (`Range: bytes=0-99` → 206, correct slice of the *original* bytes, correct `content-range` denominator) — this was the specific subtle-risk concern from the original bug report; confirmed correct in this diff but currently unpinned by any test.
6+7. Add one lightweight non-integration test asserting `Nebu.Media.DB.to_map/1`'s column-position mapping includes `:compressed` correctly (a pure-function test, no live DB) — closes the gap that `make test-unit-elixir` currently can't catch a regression of the `@sql_lookup` SELECT list (AC4's real coverage is `:integration`-tagged only).
8. Add a thumbnail test for the legacy `/_matrix/media/v3/thumbnail/...` alias, matching AC1's dual-route coverage (currently only the v1 client thumbnail route is tested).

## Deferred (out of scope for this bug fix, noted for follow-up — not sent to dev-story)

9. Stale `pipeline-state.yaml` in the staged diff — being corrected directly by the pipeline orchestrator (this file), not a dev-story concern.
10. Per-request memory for compressed rows rises from stored (compressed) size to original size on download/thumbnail routes that carry no rate limit by design. Not a new DoS class (an uncompressed upload of the same size already costs this), but decouples attacker storage cost from server memory cost. Recommend a follow-up story: chunked/bounded inflate, ranged S3 reads, or a download rate-limit tier.

## INFO (no action required)

- `Storage.compress/1` has no documented inverse — a `Storage.decompress/2` next to it would be the natural single home for both copies of `maybe_gunzip/2` (this one and `MediaScanWorker`'s). ADR-018 tolerates duplication; the *missing inverse* is how this bug shipped.
- ADR-029 never states the read-path invariant (gunzip-on-serve) — worth adding at the arc42-update step.
- Local naming inversion in `fetch_and_decrypt/3`: `plaintext` bound to still-possibly-gzipped bytes, `bytes` to the actual plaintext — harmless, `serve_bytes/4`'s `plaintext` param is the one that's now accurate.
- No test asserts `Content-Type` is preserved / no `content-encoding: gzip` header is ever emitted — confirmed by reading the code that no such header exists anywhere, so no double-decompression risk, but the "mislabeled content type" half of the bug narrative is otherwise unguarded.
- 3-segment download clause (`/download/:server/:id/:file_name`) untested for compressed rows.
- Security posture *improves*: served bytes now equal what ClamAV scanned (previously the client got gzip while the scanner saw the original).
