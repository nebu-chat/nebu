# Pre-dev test-review — 8b-orphan-detection-gdpr

**Reviewed:** `server/test/nebu/workers/media_orphan_detection_worker_test.exs` (9 tests, RED
phase, `Nebu.Workers.MediaOrphanDetectionWorker` does not exist yet).

## Verdict: CLEAN (0 MAJOR)

## AC/AT coverage mapping

| Story AT | Test(s) | Verdict |
|---|---|---|
| AT1 (detect unreferenced expired orphan) | Test 1 | covered |
| AT2 (exclude via content.url) | Test 2 | covered |
| AT3 (exclude via avatar_url / thumbnail_url) | Test 3 | covered (both sub-cases in one test body — acceptable, matches story's own "same shape as test 2" framing) |
| AT4 (exclude fresh/within-threshold rows) | Test 4 | covered |
| AT5 (zero StateMachine.transition calls, detection-only invariant) | Test 5 | covered — asserts `transition_calls() == []` after seeding 3 candidates, i.e. tests the invariant under real candidate load, not just the trivial zero-candidate case |
| AT6 (one audit entry per run, not per candidate) | Test 6 | covered — 3 candidates, asserts exactly 1 audit call with `candidate_count: 3` and all 3 media_ids present |
| AT7 (Logger route_template metadata + summary log) | Test 7 | covered — asserts `Logger.metadata()` post-`perform_job` (valid because `Oban.Testing.perform_job/2` runs `perform/1` synchronously in the SAME process, so per-process `Logger.metadata/1` state persists for inspection) AND that captured log output contains `candidate_count` |
| AT8 (idempotent repeated runs) | Test 8 | covered — 2 runs, asserts 2 independent audit entries with matching non-zero `candidate_count` |
| Technical-Requirements allowlist gotcha | Test 9 (dedicated, beyond the story's literal AT list, mirrors 8a's own `KnownActionsFakeRepo` precedent) | covered — fails TODAY for the real reason (`media_orphan_detection_run` absent from `@known_actions`), not a phantom red |

## Scope-safety check (detection-only invariant, load-bearing per story)

No test implies, requires, or would pass under an auto-delete/state-transition side effect.
Test 5 is a genuine negative-invariant test (asserts the call log is empty), not a
tautological no-op. No test description or comment claims/implies GDPR/DSGVO Art. 17
compliance — the moduledoc's own reference to that framing is explanatory (why the invariant
exists), not a compliance claim.

## Red-phase reasoning verified (not just asserted)

Actually ran `mix test test/nebu/workers/media_orphan_detection_worker_test.exs` inside the
`elixir:1.20-alpine` container (per `Makefile`'s `test-unit-elixir` invocation pattern):
`Result: 0/9 passed`. 8 failures are `Oban.Testing.build_job/3`'s `assert_valid_worker/1`
("Expected worker to be a module that implements the Oban.Worker behaviour") — the same
legitimate red-phase mechanism used throughout this epic (e.g.
`media_reserved_upload_cleanup_worker_test.exs`). The 9th (allowlist test) fails with the real,
distinct `{:error, :audit_unknown_action}` — confirms the allowlist gap is real, not a
red-herring. `git diff --stat server/lib/nebu/compliance/audit_writer.ex` confirms 0 lib/
changes were made in this ATDD pass (allowlist entry is dev-story's job, matching the 8a
precedent of leaving `@known_actions` untouched during ATDD).

## Non-blocking notes (not MAJOR, no action required before dev-story)

- Test 3 combines both AT3 sub-cases (avatar_url, thumbnail_url) into a single test body
  rather than two separate `test` blocks — a valid, common style choice in this epic's own
  test suites, not a coverage gap (both fields are independently asserted within the body).
- `candidate_media_ids` assertions use `in`/`refute ... in` membership checks rather than
  exact-list equality — intentionally robust against ordering, consistent with idiomatic style
  used elsewhere in this epic's worker tests.

## Recommendation

Proceed to dev-story. No fixes required before implementation begins.
