# Test Review Report — media-security-admin-control / 2c-sync-upload-shared-pipeline

**Scope**: `git diff --staged` (Elixir/ExUnit backend, `server/`)
**Files reviewed**:
- `server/test/nebu/media/media_fakes.exs` (modified)
- `server/test/nebu/media/media_upload_test.exs` (modified)
- `server/test/nebu/media/media_sync_shared_pipeline_test.exs` (new)
- `server/test/nebu/media/media_sync_state_transition_test.exs` (new)

## AC Traceability

| AC | Covered by | Verdict |
|---|---|---|
| AC1 (row via StateMachine, never `DB.insert/1`) | `media_sync_shared_pipeline_test.exs`, `media_sync_state_transition_test.exs` Group 1 | Covered |
| AC2 (identical storage-pipeline function as 2b) | `media_sync_shared_pipeline_test.exs` | Covered, with a discrimination gap — see MAJOR-1 |
| AC3 (external contract unchanged) | Pre-existing `media_upload_test.exs` regression suite (7 tests) | Covered, confirmed unmodified |
| AC4 (lands in `:quarantined`, single transition row, not `:reserved`) | `media_sync_state_transition_test.exs` Group 1 (fakes) + Group 2 (`@tag :integration`, real Postgres row-count/shape assertions + explicit two-row contrast test) | Covered, strongly discriminating |

## Specifically-requested verification: transition-row-count discrimination

**Not a gap.** `media_sync_state_transition_test.exs` Group 2 queries the real `media_state_transitions`
table and asserts `length(rows) == 1` plus exact `(from_state: nil, to_state: "quarantined",
actor_type: "system", actor_id: nil)` shape — not merely "final state is :quarantined." Paired
with a fourth test that drives `create/1` + `transition/4` directly and proves that composition
produces exactly two rows. Group 1 (fakes-only) independently reinforces this by refuting both
`{:state_machine_create_called, _}` and `{:transition_called, ...}` for the sync path.

## Findings

### MAJOR-1 — AC2's "no second implementation" claim is verified only by a behavioral proxy, not by call-identity
**File**: `server/test/nebu/media/media_sync_shared_pipeline_test.exs`, lines 178-252
**Failure scenario**: AC2 requires "there is no second implementation of this sequence anywhere in
`Nebu.Media`." The test's actual assertion is ciphertext-length equality (`byte_size(sync_ciphertext)
== byte_size(async_ciphertext)`) plus a lower-than-original-size check for gzip. A dev
implementation that does NOT route the sync path through a literal shared function, but instead
writes a second, hand-duplicated `hash -> gzip -> AES-256-GCM` sequence inline in `store_upload/4`
using the same algorithm/parameters (plausible — today's landed `store_and_quarantine/7` bundles
everything inline; there is no standalone extracted function on `Nebu.Media.Storage` yet), would
produce byte-identical-length ciphertext and pass this test while still violating "no second
implementation."
**Reviewer's own recommendation**: since dynamic/black-box tests structurally cannot prove absence
of duplicate code, treat this as a code-review-gate concern (verify at code-review time that
`store_upload/4` and `store_and_quarantine/7`/its extracted successor share one literal function
call, not parallel implementations) rather than a blocking pre-dev test gap.

### MINOR-1 — `:media_persist_upload_fun` spy wired but never asserted on
**Files**: `media_sync_shared_pipeline_test.exs` and `media_sync_state_transition_test.exs` (setup)
Both files configure a `:media_persist_upload_fun` spy but no test asserts on the received
`{:persisted, fields}` message. A stronger AC2 test would assert the persisted `file_hash` equals
SHA-256 of the raw pre-compression body. Not a blocker — low-cost unused instrumentation.

## Confirmed non-findings
- Regression suite (`media_upload_test.exs`) genuinely unmodified in assertions — only setup/fixture wiring changed.
- No Mox usage — function-backed-fake convention preserved.
- No hard waits/non-determinism.
- N/A: GenServer crash/restart, UI/Playwright (story is ui:false).
- Integration-tag hygiene correct (`@describetag :integration`, excluded from default `mix test`).

## Summary
0 blocking gaps in the specifically-flagged transition-row-count risk area. 1 MAJOR finding on
AC2's inherent inability to fully rule out a duplicated (not literally shared) pipeline
implementation via behavioral/black-box tests alone. 1 MINOR on unused spy instrumentation.

**PIPELINE STATUS: Stopped per coordinator instruction — pre-dev test-review MAJOR findings
require caller decision before proceeding to dev-story.**
