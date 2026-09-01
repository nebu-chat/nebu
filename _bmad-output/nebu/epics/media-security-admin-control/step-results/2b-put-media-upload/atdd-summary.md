# ATDD — 2b-put-media-upload

New test file: `server/test/nebu/media/media_async_upload_test.exs` (21 tests).
Fake seams added to `server/test/nebu/media/media_fakes.exs`:
`MediaFakes.DB.lookup_reservation/2`, `MediaFakes.DB.persist_upload/1`,
`MediaFakes.StateMachine.transition/4`, `MediaFakes.ScanEnqueue.enqueue/1`.

## RED-phase result

`mix test test/nebu/media/media_async_upload_test.exs` → **4/21 passed, 17 failed**
(first run after fixing one `unquote`-outside-`quote` compile error in the
parameterized-state test loop — description string must not `unquote` a
variable already in scope at `for`-loop-expansion time, only the deferred
test body needs it).

All 17 genuine failures are `expected 200/403/409/413/400, got 404
{"errcode":"M_NOT_FOUND","error":"Unrecognized request"}` — the router's
`match _` catch-all, because `PUT /_matrix/media/v3/upload/:server_name/
:media_id` is not yet routed. This is the correct RED state per the story's
own guardrail: nothing about this failure indicates a broken test, only a
missing route (confirmed identical failure mode to the sibling stories'
ATDD runs, e.g. 2a's).

## Known caveat flagged for test-review

**2 of the 21 tests trivially pass right now for the WRONG reason, not
because the real implementation exists:**

  * `"PUT .../upload with an unknown media_id -> 404 M_NOT_FOUND"`
  * `"PUT .../upload with a reservation whose derived expiry has already
     elapsed -> 404 M_NOT_FOUND, checked live"`

Both assert `conn.status == 404` and `errcode == "M_NOT_FOUND"` — which is
EXACTLY what the router's catch-all also returns today, coincidentally. So
these 2 tests are not currently falsifiable proof that dev-story's real
`upload_async/3` handler produces the right behavior; they will keep passing
whether or not the real 404 path is implemented correctly, UNTIL a real
route exists to make them fail against a stub/misrouted-but-authenticated
request. This is a known, common ATDD false-positive-pass class (asserting
an error code that happens to match the default "not found" fallback) —
flagging it explicitly rather than silently treating "4/21 passed" as
partial progress. Recommend test-review confirm this is acceptable (it
mirrors the same shape sibling story test suites accept) or requests an
additional differentiating assertion (e.g. asserting on a response header
or body field only the real handler would set) if stricter proof is
desired.

## Design decisions made during ATDD (documented in the test file's moduledoc)

  * `Nebu.Media.DB.persist_upload/1` — a NEW fake/seam this ATDD pass
    introduced beyond the story's own literal File List, because AC8's
    persisted-field assertions (file_hash, compressed, content_type,
    filename, storage_key) need SOME observable write seam distinct from
    `StateMachine.transition/4` (whose only metadata channel is the
    `media_state_transitions` ledger, not the `media_files` row). The dev
    agent may rename this function, but some such DB write path is required.
  * `Nebu.Media.StateMachine.transition/4` fake added (previously only
    `create/1` was faked, from Story 2a).
  * `Nebu.Web.MediaFakes.ScanEnqueue` — new fake module for the Oban-less
    scan-enqueue seam (Oban is not yet a dependency; Story 4b introduces it).
  * Two wiring-verification tests added beyond the story's own 13 Acceptance
    Tests: mime_denylist (Story 9c) and StorageConfig.compute_key/2 (Story
    11c), per this story's role as the first caller of both previously-
    standalone units.

Full RED-phase log: `_bmad-output/nebu/epics/media-security-admin-control/
step-results/2b-put-media-upload/atdd-first-run.log`.
