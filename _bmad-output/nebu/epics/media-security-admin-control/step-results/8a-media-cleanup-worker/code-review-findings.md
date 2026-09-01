# Code Review — Story 8a-media-cleanup-worker (cycle 0)

**Verdict: APPROVE** with 1 MINOR + 2 INFO. No CRITICAL, no MAJOR.

## MINOR-1 — Reaper-path audit loses `uploader_user_id` (production divergence not caught by tests)

The real `Nebu.Media.StateMachine.transition/4` to `:hard_deleted` runs `@sql_update_state_hard_deleted`
(`state_machine.ex:136`), which sets `uploader_user_id = NULL, hard_deleted_at = now()` INSIDE the
transition itself — i.e. before the worker's own S3 delete step. The test `FakeStateMachine` does not
replicate this side effect, so no test surfaces it. Consequences:
- The worker's own `hard_deleted_at` UPDATE (`WHERE hard_deleted_at IS NULL`) becomes a 0-row no-op —
  harmless, value already correct.
- Fresh-candidate audits are fine (`uploader_user_id` captured from the pre-transition SELECT before
  the transition runs).
- **Reaper/completion-path audit entries record `uploader_user_id: nil`**, because the completion-query
  SELECT reads a column the PRIOR tick's transition already nulled.

Not an ADR-032 violation of the load-bearing invariant (storage_key/blob-orphan safety is untouched —
only an audit-metadata completeness gap on the rare crash-recovery path). AC7's literal wording implies
the worker's own UPDATE nulls both columns, but in practice `uploader_user_id` is already gone by then
via the transition's side effect.

**Fix options** (pick one):
(a) Drop `uploader_user_id` from the worker's own AC7 null-UPDATE (StateMachine already owns nulling it) —
    simplest, matches actual runtime behavior, and update AC7/Technical-Requirements doc comment to note
    this.
(b) For reaper-path candidates specifically, capture `uploader_user_id` before it's lost — not really
    fixable since it's already null by the time the reaper query runs (the prior tick's transition already
    cleared it) — so option (a) is the only real fix; a reaper audit entry will legitimately have
    `uploader_user_id: nil` regardless, since the source data is gone. Recommend option (a) alone:
    stop attempting a redundant `uploader_user_id` null-UPDATE in the worker (it's already null by the
    time the worker's own UPDATE would run for BOTH fresh and reaper paths, since `transition/4` always
    nulls it as part of entering `:hard_deleted`) and add a one-line comment noting that
    `uploader_user_id` is nulled by `StateMachine.transition/4`, not by this worker.

## INFO-1 — Same-tick reaper retry of an S3-failed fresh candidate (no action needed)

Because the completion pass runs after both fresh passes within one `perform/1`, a fresh row whose S3
delete fails is re-selected by the completion query in the SAME tick and retried immediately — not only
"next run" as AC8 phrases it. Harmless (idempotent), arguably an improvement. Documentation-only.

## INFO-2 — Test harness quality (no action needed)

Ordered `@event_log` for ADR-032 ordering (test 9), genuine two-row isolation (test 11), SQL-text-shape
invariant on FakeRepo call log (tests 14/15), dedicated `@known_actions` allowlist regression (test 13)
independent of pass-through coverage. Strong.

---
Per pipeline convention (MINOR-only findings, cycle_count < 3): auto-cycle back to dev-story for a fix
pass on MINOR-1 (option a: remove the redundant/misleading `uploader_user_id` null-UPDATE, add
clarifying comment). INFO-1/INFO-2 require no action.
