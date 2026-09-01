# Oracle Gate — 8c-media-archive-worker

matrix=true (false-positive, keyword-matched `_matrix/` in the story's own
Acceptance Test 6/7 prose, which merely references the pre-existing
`GET /_matrix/media/v3/download/...` endpoint path as test fixture context —
same false-positive class as 2e-reserved-upload-cleanup-cron's own classify
entry, 2026-07-14).

No wire-protocol MUST governs this story. The Matrix Client-Server spec has
no concept of storage tiers/buckets — `archived_at` and the archive-bucket
switch are entirely server-side implementation details of ADR-029's storage
layer. The download endpoint's request/response contract (status codes,
headers, body bytes) is completely unchanged by this story: AC11 explicitly
requires the download handler to behave byte-identically post-archive (same
200, same decrypted bytes, same headers) — the only thing that changes is
which internal bucket the server reads from before decrypting. Story 1c's
own download-gate state machine (:released allow-list, 404/451 mapping) is
untouched by this story; the archive-bucket switch runs strictly AFTER the
state gate already decided to serve.

No spec corrections needed. Proceeding without Matrix spec involvement.
