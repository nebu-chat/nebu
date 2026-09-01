# Pre-Dev Test Review — 2b-put-media-upload

**Verdict: CLEAN — 0 MAJOR findings.** Every one of the 9 acceptance criteria
has at least one covering test. Proceeding to dev-story.

## AC Coverage Map

| AC | Covered | Test(s) |
|---|---|---|
| AC1 (Content-Type optional, defaults octet-stream) | Yes | "without a Content-Type header" |
| AC2 (filename persisted) | Yes | "?filename=report.pdf" + "NO ?filename= -> nil" |
| AC3 (403 ownership, any state) | Yes | parameterized over :reserved/:quarantined/:released/:infected (4 tests) |
| AC4 (404 unknown / expired, live check) | Yes (see caveat below) | "unknown media_id" + "derived expiry has already elapsed" |
| AC5 (409 wrong state / not idempotent) | Yes | "already past :reserved" + "retried with byte-identical body" |
| AC6 (413 size limit, pre-check + streamed) | Yes | Content-Length pre-check + streamed running-total |
| AC7 (validation order) | Yes | combined 403-wins test + NEW 409-before-413 isolation test (added during this review) |
| AC8 (happy-path storage pipeline: hash/compress/encrypt/S3/persist/transition/enqueue) | Yes | happy-path + file_hash/compression + storage-key-template wiring |
| AC9 (S3 failure leaves row untouched) | Yes | ADR-032 consistency test (fail-then-retry) |

## Findings

**MINOR — AC7 ordering was only partially proven before this review; fixed inline.**
The original combined test only proved ownership (403) wins over
expiry/state/size simultaneously — it did not isolate whether the state
guard (409) is checked before the size limit (413) for a correctly-owned,
non-expired request. Added a new test ("the state guard (409) is checked
BEFORE the size limit (413)...") during this review rather than deferring
it — closes the gap; test suite is now 22 tests, 18 RED / 4 pass (up from
21/17/4).

**MINOR (self-flagged by ATDD, independently confirmed) — 2 tests trivially
pass at RED phase for the wrong reason.** "unknown media_id -> 404" and
"expired reservation -> 404" both assert `conn.status == 404` /
`errcode == "M_NOT_FOUND"`, which is exactly what the router's generic
`match _` catch-all ALSO returns today (no route exists yet) — coincidence,
not proof of correct behavior. This is NOT a permanent test-quality defect:
once the real route/handler lands, these tests become fully meaningful (a
regression that wrongly returns e.g. 200 or 403 for an unknown/expired id
would correctly fail them). It is a normal, temporary characteristic of
ATDD for any endpoint whose error path happens to share a status/errcode
with the "route not found" fallback — same shape accepted in sibling
stories' ATDD runs this epic (e.g. 2a). Not blocking; noted for the record,
no action needed.

**INFO — `MediaFakes.DB.persist_upload/1` is a new seam invented during
ATDD, not literally named in the story's own File List.** The story's
Technical Requirements step 6 requires persisting `storage_key`/`file_hash`/
`compressed`/`content_type`/`filename`/key material "through
`Nebu.Media.StateMachine`" — but `transition/4`'s only metadata channel is
the `media_state_transitions` audit ledger (JSONB), not the `media_files`
row itself, so a distinct `media_files` UPDATE function is structurally
required for AC8's persisted-field assertions to be observable at all. The
test file's moduledoc documents this explicitly and gives the dev agent
latitude to rename the seam — this is a reasonable, load-bearing ATDD
design decision, not scope creep.

**INFO — the 2 wiring-verification tests (Story 9c's `mime_denylist_rejected?/1`,
Story 11c's `StorageConfig.compute_key/2`) are correctly in this story's
scope, not invented behavior.** Both dependencies' own Dev Agent Records
(9c's and 11c's, read during pre-ATDD dependency research) explicitly name
Story 2b as the first and designated caller with precise wiring
instructions — testing that the wiring actually happens is this story's
responsibility, not scope creep from a neighboring story.

**INFO — no hard waits, no non-deterministic assertions, no brittle
selectors.** All 22 tests are synchronous `Plug.Test`/`Plug.Conn` request/
response assertions plus `assert_received`/`refute_received` on
process-mailbox messages sent by injected fakes — the same pattern already
established by every sibling `media_*_test.exs` file in this codebase.

**INFO — no GenServer/crash-restart test needed.** This story introduces no
new GenServer or persistent process state.

**INFO — not a UI story (`ui: false`).** No Playwright/e2e Gherkin
requirement applies; this matches the established epic precedent (Story 2a,
same classification, ExUnit-only, no browser-level scenario added).

## Test regression check

All 22 tests in the new file compile and execute as expected: RED (18
genuine, correctly-failing-because-the-route-doesn't-exist-yet) / 4 passing
(2 legitimate 401-auth tests that never reach routing, 2 coincidental-404
tests per the caveat above). No existing test file was modified in a way
that could regress other suites — only additive fake seams in
`media_fakes.exs` (existing `lookup/2`, `count_pending_reservations/1`,
`create/1`, `can_upload?/1`, `get/put`, `fetch/1` seams are untouched).
