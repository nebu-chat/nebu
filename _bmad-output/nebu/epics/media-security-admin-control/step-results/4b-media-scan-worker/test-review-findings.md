# Pre-dev Test-Review — 4b-media-scan-worker

## AC coverage matrix

| AC | Covered by | Notes |
|---|---|---|
| AC1 (Oban dep/schema/supervisor) | n/a | Already satisfied by Story 2e; not independently unit-testable; config-only remainder (media_scan queue entry) validated by ci-gate's real boot, matching 2e's own precedent. |
| AC2 (queue config) | n/a | Same as AC1. |
| AC3 (module + entry transition + no-op) | worker test 1 (entry transition), test 7 (no-op) | Covered. |
| AC4 (fetch/decrypt/decompress order+correctness) | worker test 8 | Covered — real Crypto round-trip, gunzip only when compressed:true, call-order asserted for storage_get before clamav_scan_binary. |
| AC5 (clean -> released + broadcast) | worker test 1 | Covered. |
| AC6 (infected -> infected + signature persisted + broadcast) | worker test 2 | Covered. |
| AC7 (file_too_large -> skip, not error) | worker test 6 | Covered. |
| AC8 (broadcast on every terminal outcome) | worker tests 1/2/4 individually + test 5 (table-driven, all 3 outcomes) | Covered, with a dedicated regression guard (test 5) matching the story's own Acceptance Test 5 intent. |
| AC9 (retry then discard after max_attempts) | worker test 3 (retry-then-clean), test 4 (exhausted-retry-discard) | Covered. |
| AC10 (state changes only via transition/4, never raw SQL) | Implicit by construction (worker's only DB touchpoint besides transition/4 is `update_scan_metadata/2`, a distinct seam that only ever receives a metadata map, never a state value) | See MINOR-1 below. |

## Findings

**MINOR-1 (AC10):** No dedicated regression test proves `Nebu.Media.DB.update_scan_metadata/2`'s
real production SQL touches only `scan_metadata`, never `state` — 2e's own worker test set a
precedent for this exact class of check ("cleanup never issues a raw UPDATE/DELETE on
media_files.state", asserted against a captured SQL log). This worker's test suite can't
reproduce that pattern directly because `update_scan_metadata/2` is fully seamed out in the
worker-level tests (FakeDB never sees real SQL text). Recommend dev-story add a small real-DB
test (`:integration`-tagged, mirroring `media_scan_failed_enum_value_test.exs`'s convention)
asserting `Nebu.Media.DB.update_scan_metadata/2`'s actual UPDATE statement only sets
`scan_metadata` and leaves `state` untouched. Not blocking — the invariant is true by
construction today (the worker has no code path to touch `state` outside `transition/4`), this
just closes the regression-guard gap for the future.

**No MAJOR or CRITICAL findings.**

## Non-findings (confirmed acceptable)

- `refute_receive {..}, 50` timing waits: standard ExUnit idiom for asserting absence of a
  message, matches existing codebase convention (e.g. `media_download_stall_test.exs`), not a
  flake risk since it only bounds a "nothing arrived" assertion, not a positive wait.
- Oban worker (not GenServer) — crash/restart semantics are Oban's own responsibility
  (Lifeline plugin rescues orphaned executing jobs; already configured by Story 2e). No
  redundant crash/restart test needed at this worker's level.
- No config-level unit test asserting the `queues:` list content — consistent with the epic's
  established convention (2e also relied on ci-gate's live boot to validate Oban config, not a
  unit test).

## Decision

0 MAJOR findings — proceeding directly to dev-story per pipeline auto-continue rule.
