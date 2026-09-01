# Code Review — 2b-put-media-upload (cycle 0)

Reviewed by independent opus subagent against the actual staged diff (not self-review).

## AC verdict summary

ACs 1, 2, 3, 4, 5, 6, 7, and the ADR-032 ordering half of 8/9 are genuinely
satisfied by the real code (confirmed: ordering, expiry arithmetic, mime
normalization contract, compute_key default-template behavior, exact `{}`
response body, validation-order sequence, migration safety). Two defects
below affect AC8/AC9 robustness and a security parity gap with the sync
sibling.

## MAJOR findings

### MAJOR-1 — `persist_upload/1` and `transition/4` return values are
discarded; handler returns 200 even on a failed persist/transition (silent
data loss)

`server/lib/nebu/media.ex:401-419` — inside `store_and_quarantine/7`, after
the S3 write succeeds:
```elixir
case storage_module().put(storage_key, ciphertext) do
  :ok ->
    db_module().persist_upload(%{...})                          # return ignored
    state_machine_module().transition(media_id, :quarantined, {:system, nil})  # return ignored
    scan_enqueue_module().enqueue(media_id)
    send_json(conn, 200, %{})                                   # 200 unconditionally
```
Both calls can return `{:error, reason}` and the code ignores it, still
returning 200. Concrete failure: S3 write succeeds, `persist_upload/1`
fails (transient DB error) — row ends up `state: :quarantined` but
`storage_key: NULL`, `aes_key_hex: ''`, `file_size: 0` (2a's genesis
placeholders never overwritten). Client is told 200 and never retries (a
retry now 409s per AC5's non-idempotency) — the file is permanently
unretrievable. Contradicts AC8's "single logical step" requirement (no
transaction wraps persist+transition) and is inconsistent with the sync
sibling `store_upload/2`, which correctly gates on both writes via `with
:ok <- ..., :ok <- ... else 500`. Not covered by any test (fakes always
return success).

### MAJOR-2 — Async upload drops the hardcoded `@blocked_upload_types` XSS
blocklist that the sync path enforces (latent stored-XSS via thumbnail path)

`server/lib/nebu/media.ex:347-350` — `validate_and_store_async/4`'s
content-type gate checks only the admin-configured `mime_denylist_rejected?/1`
(default `""`, blocks nothing). It omits the sync path's hardcoded
`content_type in @blocked_upload_types` check (`text/html`,
`application/xhtml+xml`, `text/javascript`, `application/javascript`,
`image/svg+xml`, `application/x-shockwave-flash` — media.ex:45-49, the
classic stored-XSS content types). By default the async route accepts
content types the sync route deliberately blocks.

Concrete scenario: client PUTs an SVG with an embedded `<script>` via the
async route (`Content-Type: image/svg+xml`) — accepted, stored. The
download handler's `disposition_for/2` forces `attachment` for non-safe
types, but `thumbnail/3` does NOT: `image_type?/1` matches
`image/svg+xml`, so `serve_inline_image/4` serves it `inline` with
`content-type: image/svg+xml` — a browser renders it, executing the script
in the media origin.

Reachability caveat: requires the media to reach `:released` (scan/release
pipeline not landed yet, scan-enqueue is currently a no-op) — this is a
**latent** vulnerability that becomes live once the release pipeline lands,
not an immediately exploitable one today. Not covered by any test (only the
admin-mime_denylist case is tested).

## MINOR findings

- **MINOR-1** — No row lock between `lookup_reservation/2` and the later
  writes (TOCTOU): two concurrent PUTs could both pass the `:reserved`
  guard and both attempt `store_and_quarantine/7`. `transition/4`'s
  internal `SELECT ... FOR UPDATE` prevents both transitions succeeding,
  but nothing serializes the two S3 writes/persists — an unlucky interleave
  could leave the row's key/nonce mismatched against the stored ciphertext
  (GCM auth failure on download). Likely an accepted risk given how unusual
  concurrent-PUT-to-same-reservation behavior is, but worth recording.
- **MINOR-2** — No empty-body guard (`upload/1`'s F3 "empty body -> 400"
  behavior has no async-path equivalent) — a zero-byte PUT is accepted and
  stored, diverging from the sync sibling's stated intent.
- **MINOR-3** — `persist_upload`'s `UPDATE ... WHERE media_id = $1` doesn't
  also scope on `server_name` (harmless — `media_id` is the PK — but
  asymmetric with `lookup_reservation/2`'s two-column scope).

## INFO

- `ScanEnqueue` no-op module clearly documented as a Story-4b placeholder,
  guards input with `is_binary/1`.
- 500 `M_UNKNOWN` on S3 failure has no spec-mandated errcode, consistent
  with the sync path's existing convention.
- Boundary/seam pattern (`scan_enqueue_module/0`, new fakes) mirrors the
  established `Application.get_env` convention throughout `Nebu.Media`.
- No dead code; naming consistent with the sibling handler.

## Verdict

**2 MAJOR findings — surfaced to the caller for a decision per pipeline
policy, not auto-fixed.** MINOR findings will be handed to dev-story for
fixing once the MAJOR-finding decision is made (bundling this into the
same fix cycle rather than a separate round).

---

## Cycle 1 re-review (independent verification)

**Verdict: CLEAN — 0 MAJOR/CRITICAL remaining.** Both MAJOR fixes verified as real (not just claimed):
gating logic actually short-circuits on failure with no false-200 path, new tests genuinely exercise
both failure branches. MINOR-1 accepted-risk comment confirmed present in code (11 lines,
media.ex:308-318). MINOR-2 empty-body guard confirmed present + tested. MINOR-3 confirmed harmless,
no regression. AC7 validation order re-verified intact. Full test suite: 27/27 story tests green,
warnings-as-errors clean. One cosmetic INFO noted (moduledoc example slightly stale vs. actual call
site ordering) — not blocking, not actioned.
